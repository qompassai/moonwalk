"""MW-CI-007 (validation): build.yml runs the Lua unit test suite.

The pure-Lua tests (DAP framing, request validation) are the fastest
signal in the program; CI must run them via `test/unit/run_unit.lua`
so a regression there fails the build.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _yamlish

CASE = {
    "id": "MW-CI-007",
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
    unit_steps = [s for s in steps
                  if "test/unit/run_unit.lua" in _yamlish.step_text(s)]
    assert unit_steps, "build.yml never runs test/unit/run_unit.lua"
