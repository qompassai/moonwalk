"""MW-CI-008 (validation): build.yml uploads failure artifacts.

A red CI run with no artifacts is undebuggable from the outside. This
case asserts build.yml uploads failure artifacts (the `artifacts/`
directory the DAP harness writes) when the run fails.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _yamlish

CASE = {
    "id": "MW-CI-008",
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


def run(ctx) -> None:
    path = os.path.join(ctx.repo_root, ".github", "workflows", "build.yml")
    assert os.path.isfile(path), "build.yml missing: %s" % path
    with open(path) as f:
        doc = _yamlish.parse(f.read())

    steps = _yamlish.workflow_steps(doc)
    assert steps, "build.yml has no steps"
    upload_steps = [s for s in steps
                    if "upload-artifact" in _yamlish.step_text(s)]
    assert upload_steps, "build.yml never uploads failure artifacts"
    assert any(s.get("if") == "failure()" for s in upload_steps), (
        "artifact upload is not conditioned on failure()")
