#!/usr/bin/env python3
"""Case runner for the moonwalk DAP conformance harness.

Each case is a module in ``test/dap/cases/`` exposing::

    CASE = {
        "id": "MW-XXX-000",
        "kind": "validation" | "adversarial",
        "layer": "ci" | "runtime" | "stdio" | "protocol" | "lifecycle" | ...,
        "platforms": ["linux", ...],
        "timeout_seconds": 60,
        "destructive": False,
        "needs_ptrace": False,
        "needs_network": False,
        "needs_admin": False,
        "invariants": ["stdout-frames", ...],
        "owners": ["pax"],
    }

    def run(ctx) -> None: ...   # raise AssertionError on failure

Statuses: PASS / FAIL / BLOCKED / ERROR.
  * FAIL     -- AssertionError or DAPTimeout (a timeout is a FAIL).
  * BLOCKED  -- case raised ctx.blocked(reason); environment cannot run it.
               Never counts as a pass. Never faked.
  * ERROR    -- any other unexpected exception.

Exit code: non-zero if any FAIL or ERROR. BLOCKED alone does not fail the
run, but the summary marks it loudly: BLOCKED is not a pass.

On FAIL/ERROR an artifact directory is written:
  artifacts/<case-id>/<seed>/
    command.txt  environment.txt  transcript.jsonl  stdout.bin  stderr.txt
    adapter-exit.json  process-tree.txt  fixture.lua  reproduction.sh

Usage:
  python3 test/dap/run.py [--case ID]... [--seed N] [--list]
                          [--allow-destructive] [--artifacts-dir DIR]

Determinism: default seed is 1. PR runs use the fixed seed; nightly runs
rotate it (see test/dap/corpus/README.md).
"""

from __future__ import annotations

import argparse
import glob
import importlib.util
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO_ROOT, "test", "dap"))

from client import (  # noqa: E402
    AdapterDied,
    BlockedCase,
    DAPClient,
    DAPTimeout,
    descendants,
    process_tree_text,
)

CASES_DIR = os.path.join(REPO_ROOT, "test", "dap", "cases")
FIXTURES_DIR = os.path.join(REPO_ROOT, "test", "dap", "fixtures")

REQUIRED_CASE_KEYS = (
    "id", "kind", "layer", "platforms", "timeout_seconds", "destructive",
    "needs_ptrace", "needs_network", "needs_admin", "invariants", "owners",
)

# ---------------------------------------------------------------------------
# Adapter discovery
# ---------------------------------------------------------------------------
#
# ASSUMPTION (loud): the moonwalk adapter is a single native binary produced
# by the repo build. We probe, in order:
#   1. <repo>/build/bin/moonwalk
#   2. <repo>/build/moonwalk
#   3. <repo>/publish/**/moonwalk*   (vsce/ovsx packaging trees)
# The first executable regular file wins. If the build ever renames the
# binary or splits it per-platform, this probe must be updated -- a miss
# BLOCKS every black-box case rather than faking a pass.


def find_adapter(repo_root: str = REPO_ROOT) -> str | None:
    candidates = [
        os.path.join(repo_root, "build", "bin", "moonwalk"),
        os.path.join(repo_root, "build", "moonwalk"),
    ]
    probed = list(candidates)
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    for path in sorted(glob.glob(os.path.join(repo_root, "publish", "**", "moonwalk*"),
                                 recursive=True)):
        probed.append(path)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    find_adapter.last_probed = probed  # type: ignore[attr-defined]
    return None


find_adapter.last_probed = []  # type: ignore[attr-defined]


def require_adapter(ctx: "CaseCtx") -> str:
    """Return the adapter path or raise BlockedCase (never fake a pass)."""
    path = find_adapter(ctx.repo_root)
    if path is None:
        probed = getattr(find_adapter, "last_probed", [])
        raise BlockedCase(
            "no adapter binary found; probed: %s. "
            "Build the repo first (see find_adapter() assumption in run.py)."
            % ", ".join(probed)
        )
    return path


# ---------------------------------------------------------------------------
# Case context
# ---------------------------------------------------------------------------


class CaseCtx:
    """Per-case context handed to ``run(ctx)``."""

    def __init__(self, case_id: str, seed: int, artifacts_root: str):
        self.case_id = case_id
        self.seed = seed
        self.rng = random.Random("%s:%d" % (case_id, seed))
        self.repo_root = REPO_ROOT
        self.fixtures_dir = FIXTURES_DIR
        self.workdir = tempfile.mkdtemp(prefix="mw-%s-" % case_id.lower())
        self.artifacts_root = artifacts_root
        self.clients: list[DAPClient] = []
        self.fixture_used: str | None = None
        self.start_wall = time.time()
        self._killed_by_runner = False

    # -- helpers ------------------------------------------------------
    def blocked(self, reason: str) -> BlockedCase:
        return BlockedCase(reason)

    def require_adapter(self) -> str:
        return require_adapter(self)

    def new_client(self) -> DAPClient:
        client = DAPClient()
        self.clients.append(client)
        return client

    def fixture(self, name: str) -> str:
        """Copy a fixture into the case workdir; returns the workdir path."""
        src = os.path.join(self.fixtures_dir, name)
        if not os.path.isfile(src):
            raise AssertionError("fixture %r not found in %s" % (name, self.fixtures_dir))
        dst = os.path.join(self.workdir, name)
        shutil.copyfile(src, dst)
        self.fixture_used = dst
        return dst

    def cleanup(self) -> None:
        for client in self.clients:
            try:
                client.close()
            except Exception:
                pass
        shutil.rmtree(self.workdir, ignore_errors=True)

    def abort(self) -> None:
        """Runner timeout path: kill everything this case spawned."""
        self._killed_by_runner = True
        for client in self.clients:
            try:
                client.kill()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Case loading
# ---------------------------------------------------------------------------


def load_cases() -> list[tuple[str, dict, object]]:
    modules = []
    for fname in sorted(os.listdir(CASES_DIR)):
        if not fname.endswith(".py") or fname.startswith("_"):
            continue
        if fname == "__init__.py":
            continue
        path = os.path.join(CASES_DIR, fname)
        modname = "mwcase_" + fname[:-3]
        spec = importlib.util.spec_from_file_location(modname, path)
        if spec is None or spec.loader is None:
            raise RuntimeError("cannot load case file %s" % path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        case = getattr(mod, "CASE", None)
        run = getattr(mod, "run", None)
        if not isinstance(case, dict) or not callable(run):
            raise RuntimeError("case %s must expose CASE dict and run(ctx)" % fname)
        missing = [k for k in REQUIRED_CASE_KEYS if k not in case]
        if missing:
            raise RuntimeError("case %s CASE missing keys: %s" % (fname, missing))
        modules.append((fname, case, run))
    modules.sort(key=lambda m: m[1]["id"])
    # Duplicate ids are a harness bug, not a case result.
    ids = [c["id"] for _, c, _ in modules]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        raise RuntimeError("duplicate case ids: %s" % sorted(dupes))
    return modules


# ---------------------------------------------------------------------------
# Artifacts
# ---------------------------------------------------------------------------


def write_artifacts(ctx: CaseCtx, case_id: str, seed: int, status: str,
                    error_text: str) -> str:
    root = os.path.join(ctx.artifacts_root, case_id, str(seed))
    os.makedirs(root, exist_ok=True)

    with open(os.path.join(root, "command.txt"), "w") as f:
        f.write("python3 test/dap/run.py --case %s --seed %d\n" % (case_id, seed))

    try:
        git_sha = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT,
            capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        git_sha = "unknown"
    with open(os.path.join(root, "environment.txt"), "w") as f:
        f.write("python: %s\n" % sys.version.replace("\n", " "))
        f.write("platform: %s\n" % sys.platform)
        f.write("cwd: %s\n" % os.getcwd())
        f.write("repo: %s\n" % REPO_ROOT)
        f.write("git_sha: %s\n" % git_sha)
        f.write("case: %s status: %s seed: %d\n" % (case_id, status, seed))
        f.write("killed_by_runner: %s\n" % ctx._killed_by_runner)

    transcript_lines = []
    for client in ctx.clients:
        try:
            transcript_lines.extend(client.normalized_transcript())
        except Exception as e:
            transcript_lines.append({"kind": "artifact-error",
                                     "message": repr(e)})
    if error_text:
        transcript_lines.append({"t": -1, "dir": "==", "kind": "case-error",
                                 "message": error_text})
    with open(os.path.join(root, "transcript.jsonl"), "w") as f:
        for entry in transcript_lines:
            f.write(json.dumps(entry, default=str) + "\n")

    for i, client in enumerate(ctx.clients):
        suffix = "" if len(ctx.clients) == 1 else "-%d" % i
        with open(os.path.join(root, "stdout%s.bin" % suffix), "wb") as f:
            f.write(bytes(client.stdout_bytes))
        with open(os.path.join(root, "stderr%s.txt" % suffix), "w",
                   errors="replace") as f:
            f.write(bytes(client.stderr_bytes).decode("utf-8", "replace"))
        with open(os.path.join(root, "framing-violations%s.txt" % suffix), "w") as f:
            for v in client.framing_violations():
                f.write(v + "\n")
            for v in client.decode_violations:
                f.write("decode: " + v + "\n")

    exit_info = {"clients": []}
    for client in ctx.clients:
        proc = client._proc
        exit_info["clients"].append({
            "adapter_pid": client.adapter_pid,
            "returncode": proc.poll() if proc else None,
            "stdout_bytes": len(client.stdout_bytes),
            "stderr_bytes": len(client.stderr_bytes),
        })
    with open(os.path.join(root, "adapter-exit.json"), "w") as f:
        json.dump(exit_info, f, indent=2)

    with open(os.path.join(root, "process-tree.txt"), "w") as f:
        for client in ctx.clients:
            if client.adapter_pid:
                f.write(process_tree_text(client.adapter_pid))
            else:
                f.write("no adapter spawned\n")

    if ctx.fixture_used and os.path.isfile(ctx.fixture_used):
        shutil.copyfile(ctx.fixture_used, os.path.join(root, "fixture.lua"))
    else:
        with open(os.path.join(root, "fixture.lua"), "w") as f:
            f.write("-- no fixture used by this case\n")

    with open(os.path.join(root, "reproduction.sh"), "w") as f:
        f.write("#!/bin/sh\n")
        f.write("# Reproduce %s (seed %d) -- status was %s\n" % (case_id, seed, status))
        f.write('cd "%s"\n' % REPO_ROOT)
        f.write("python3 test/dap/run.py --case %s --seed %d\n" % (case_id, seed))
    os.chmod(os.path.join(root, "reproduction.sh"), 0o755)
    return root


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------


def run_one(fname: str, case: dict, run_fn, seed: int, artifacts_root: str,
            allow_destructive: bool) -> tuple[str, str, str]:
    """Returns (status, detail, artifact_dir)."""
    case_id = case["id"]
    if sys.platform not in case["platforms"]:
        return ("BLOCKED",
                "platform %s not in %s" % (sys.platform, case["platforms"]), "")
    if case["destructive"] and not allow_destructive:
        return ("BLOCKED", "destructive case needs --allow-destructive", "")

    ctx = CaseCtx(case_id, seed, artifacts_root)
    timeout = float(case["timeout_seconds"])
    outcome: dict = {}

    def target():
        try:
            run_fn(ctx)
            outcome["status"] = "PASS"
            outcome["detail"] = ""
        except BlockedCase as e:
            outcome["status"] = "BLOCKED"
            outcome["detail"] = str(e)
        except (AssertionError, DAPTimeout, AdapterDied) as e:
            outcome["status"] = "FAIL"
            outcome["detail"] = "%s: %s" % (type(e).__name__, e)
            outcome["tb"] = traceback.format_exc()
        except Exception as e:  # noqa: BLE001 -- ERROR bucket is intentional
            outcome["status"] = "ERROR"
            outcome["detail"] = "%s: %s" % (type(e).__name__, e)
            outcome["tb"] = traceback.format_exc()

    thread = threading.Thread(target=target, daemon=True,
                              name="case-%s" % case_id)
    thread.start()
    thread.join(timeout)
    artifact_dir = ""
    if thread.is_alive():
        # Case timeout: a timeout is a FAIL. Kill the spawned tree so a
        # hung adapter cannot poison later cases, then collect artifacts.
        ctx.abort()
        thread.join(5)
        outcome["status"] = "FAIL"
        outcome["detail"] = "DAPTimeout: case exceeded timeout_seconds=%s" % timeout
        outcome["tb"] = "case thread did not finish within its timeout"
    status = outcome.get("status", "ERROR")
    detail = outcome.get("detail", "case produced no outcome")
    if status in ("FAIL", "ERROR"):
        error_text = detail + "\n" + outcome.get("tb", "")
        artifact_dir = write_artifacts(ctx, case_id, seed, status, error_text)
    try:
        ctx.cleanup()
    except Exception:
        pass
    return (status, detail, artifact_dir)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="moonwalk DAP conformance runner")
    parser.add_argument("--case", action="append", default=[],
                        help="run only this case id (repeatable)")
    parser.add_argument("--suite", action="append", default=[],
                        help="run only cases in this suite (repeatable); "
                             "suites are declared per-case (p0 = static, "
                             "no binary needed)")
    parser.add_argument("--seed", type=int, default=1,
                        help="deterministic seed (default 1)")
    parser.add_argument("--list", action="store_true",
                        help="list cases and exit")
    parser.add_argument("--allow-destructive", action="store_true")
    parser.add_argument("--artifacts-dir", default=os.path.join(REPO_ROOT, "artifacts"),
                        help="artifact root (default ./artifacts)")
    args = parser.parse_args(argv)

    try:
        modules = load_cases()
    except RuntimeError as e:
        print("harness error: %s" % e, file=sys.stderr)
        return 2

    if args.list:
        for fname, case, _ in modules:
            print("%-14s %-11s %-9s timeout=%-4s destructive=%-5s platforms=%s" % (
                case["id"], case["kind"], case["layer"],
                case["timeout_seconds"], case["destructive"],
                ",".join(case["platforms"])))
            print("    owners=%s invariants=%s" % (
                ",".join(case["owners"]), ",".join(case["invariants"])))
        return 0

    selected = [m for m in modules
                if (not args.case or m[1]["id"] in args.case)
                and (not args.suite
                     or set(args.suite) & set(m[1].get("suites", [])))]
    if args.case:
        wanted = set(args.case)
        found = {m[1]["id"] for m in modules}
        missing = wanted - found
        if missing:
            print("unknown case ids: %s" % sorted(missing), file=sys.stderr)
            return 2
    if args.suite:
        known = {s for _, c, _ in modules for s in c.get("suites", [])}
        missing = set(args.suite) - known
        if missing:
            print("unknown suites: %s" % sorted(missing), file=sys.stderr)
            return 2
    if not selected:
        print("no cases selected", file=sys.stderr)
        return 2

    print("moonwalk DAP conformance: %d case(s), seed=%d" % (len(selected), args.seed))
    results: list[tuple[str, str, str, str]] = []
    for fname, case, run_fn in selected:
        print("  [....] %s (%s)" % (case["id"], case["kind"]), flush=True)
        status, detail, artifact_dir = run_one(
            fname, case, run_fn, args.seed, args.artifacts_dir,
            args.allow_destructive)
        results.append((case["id"], status, detail, artifact_dir))
        marker = {"PASS": "PASS", "FAIL": "FAIL",
                  "BLOCKED": "BLOCKED", "ERROR": "ERROR"}[status]
        print("  [%s] %s %s" % (marker, case["id"],
                                ("-- " + detail) if detail else ""), flush=True)
        if artifact_dir:
            print("         artifacts: %s" % artifact_dir, flush=True)

    counts = {"PASS": 0, "FAIL": 0, "BLOCKED": 0, "ERROR": 0}
    for _, status, _, _ in results:
        counts[status] += 1
    print("summary: %d PASS, %d FAIL, %d BLOCKED, %d ERROR"
          % (counts["PASS"], counts["FAIL"], counts["BLOCKED"], counts["ERROR"]))
    if counts["BLOCKED"]:
        print("note: BLOCKED is not a pass -- those cases did not run.")
    if counts["FAIL"] or counts["ERROR"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
