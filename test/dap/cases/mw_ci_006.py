"""MW-CI-006 (validation): build.yml wires the P0 DAP conformance gate.

The black-box DAP harness only protects the tree if CI actually runs it.
This case asserts build.yml contains a step invoking `test/dap/run.py`
(the P0 suite), so the harness cannot silently rot out of the pipeline.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _yamlish

CASE = {
    "id": "MW-CI-006",
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
    dap_steps = [s for s in steps if "test/dap/run.py" in _yamlish.step_text(s)]
    assert dap_steps, "build.yml never runs test/dap/run.py"
    assert any("--suite p0" in _yamlish.step_text(s) for s in dap_steps), (
        "no build.yml step runs the P0 DAP suite")
