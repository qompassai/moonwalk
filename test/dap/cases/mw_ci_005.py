"""MW-CI-005 (validation): release.yml publishes only on version tags,
from the extension directory.

Publication must be tag-gated (no accidental releases from branch
pushes), must run from `extension/` where the build generates
`package.json` (the old workflow used a nonexistent `publish/`
directory), and must not hide failures with `continue-on-error`.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _yamlish

CASE = {
    "id": "MW-CI-005",
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
    path = os.path.join(ctx.repo_root, ".github", "workflows", "release.yml")
    assert os.path.isfile(path), "release.yml missing: %s" % path
    with open(path) as f:
        doc = _yamlish.parse(f.read())

    on = doc.get("on")
    assert isinstance(on, dict), "'on:' section missing or not a mapping"
    push = on.get("push")
    assert isinstance(push, dict), "'on.push' section missing"
    tags = push.get("tags")
    assert isinstance(tags, list) and tags, "'on.push.tags' is empty or not a list"
    assert any("v" in t for t in tags), (
        "release.yml is not tag-gated; tags=%r" % (tags,))

    steps = _yamlish.workflow_steps(doc)
    assert steps, "release.yml has no steps"
    publish_steps = [s for s in steps
                     if "vsce publish" in _yamlish.step_text(s)
                     or "ovsx publish" in _yamlish.step_text(s)]
    assert publish_steps, "no vsce/ovsx publish steps found in release.yml"
    for s in publish_steps:
        assert s.get("continue-on-error") is not True, (
            "publish step hides failures with continue-on-error")
        assert s.get("working-directory") == "extension", (
            "publish step runs from %r, not extension/"
            % (s.get("working-directory"),))
