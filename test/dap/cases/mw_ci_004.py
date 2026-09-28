"""MW-CI-004 (validation): no `continue-on-error: true` on any
publish/release step in any workflow.

`continue-on-error: true` on a publish step turns a failed release into a
silent one. This is a static shape assertion: the workflow files must
match the documented safe shape (failures are always loud).
green build -- the pipeline reports success while no artifact shipped (or
worse, a partial one did). This case scans every .github/workflows/*.yml
and fails if any publish/release-like step carries that flag.
"""

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _yamlish

CASE = {
    "id": "MW-CI-004",
    "kind": "validation",
    "layer": "ci",
    "platforms": ["linux", "windows", "macos"],
    "timeout_seconds": 30,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": [],
    "owners": ["pax"],
    "suites": ["p0"],
}


def _is_publish_step(step: dict) -> bool:
    text = _yamlish.step_text(step)
    # Same rule as MW-CI-003: `-mode release` is a build flag, not a release.
    return bool(re.search(r"publish|(?<!-mode )\brelease\b", text))


def run(ctx) -> None:
    pattern = os.path.join(ctx.repo_root, ".github", "workflows", "*.yml")
    files = sorted(glob.glob(pattern))
    assert files, "no workflow files found"
    offenders = []
    for path in files:
        with open(path) as f:
            doc = _yamlish.parse(f.read())
        for step in _yamlish.workflow_steps(doc):
            if not _is_publish_step(step):
                continue
            coe = str(step.get("continue-on-error", "")).strip().lower()
            if coe == "true":
                offenders.append("%s: %s" % (
                    os.path.basename(path),
                    _yamlish.step_text(step)[:80]))
    assert not offenders, (
        "continue-on-error: true on publish/release step(s): %s"
        % "; ".join(offenders))
