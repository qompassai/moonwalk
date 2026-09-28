"""MW-CI-001 (validation): build.yml triggers on `main` for push AND pull_request.

A workflow that does not trigger on the default branch silently skips CI
for the branch that matters. This case parses .github/workflows/build.yml
and asserts both trigger sections list `main`.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _yamlish

CASE = {
    "id": "MW-CI-001",
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

    on = doc.get("on")
    assert isinstance(on, dict), "'on:' section missing or not a mapping"
    for trigger in ("push", "pull_request"):
        section = on.get(trigger)
        assert isinstance(section, dict), "'on.%s' section missing" % trigger
        branches = section.get("branches")
        assert isinstance(branches, list) and branches, (
            "'on.%s.branches' is empty or not a list" % trigger)
        assert "main" in branches, (
            "build.yml does not trigger on `main` for %s; branches=%r"
            % (trigger, branches))
