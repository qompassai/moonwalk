"""MW-CI-003 (validation): build.yml runs a test step AFTER the build step
and BEFORE any packaging/publishing step.

Shipping artifacts that were never tested is a release defect. This case
parses the ordered steps of build.yml, classifies each as build / test /
publish, and asserts at least one test step sits strictly between the last
build step and the first publish step.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _yamlish

CASE = {
    "id": "MW-CI-003",
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


def _classify(step_text: str) -> str | None:
    # `release` only counts as a publish step when it is not the `-mode
    # release` build flag.
    if re.search(r"vsce|ovsx|publish|(?<!-mode )\brelease\b", step_text):
        return "publish"
    if "test" in step_text:
        return "test"
    if any(k in step_text for k in ("luamake", "cmake", "make", "build", "compile")):
        return "build"
    return None


def run(ctx) -> None:
    path = os.path.join(ctx.repo_root, ".github", "workflows", "build.yml")
    with open(path) as f:
        doc = _yamlish.parse(f.read())
    steps = _yamlish.workflow_steps(doc)
    assert steps, "build.yml has no steps"

    kinds = [_classify(_yamlish.step_text(s)) for s in steps]
    build_idx = [i for i, k in enumerate(kinds) if k == "build"]
    test_idx = [i for i, k in enumerate(kinds) if k == "test"]
    publish_idx = [i for i, k in enumerate(kinds) if k == "publish"]
    assert build_idx, "no build step found in build.yml"
    assert test_idx, "no test step found in build.yml"

    last_build = max(build_idx)
    gated_tests = [i for i in test_idx if i > last_build]
    assert gated_tests, (
        "no test step runs AFTER the build step (build=%d, tests=%s)"
        % (last_build, test_idx))
    if publish_idx:
        first_publish = min(publish_idx)
        assert any(i < first_publish for i in gated_tests), (
            "no test step runs BEFORE the first packaging/publishing step "
            "(first publish=%d, tests=%s)" % (first_publish, test_idx))
