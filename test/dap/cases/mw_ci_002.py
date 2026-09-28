"""MW-CI-002 (adversarial): test/interceptor.lua fails non-zero when zero
test binaries are discovered.

A green run with zero discovered tests is a broken build rule, not a
passing suite. This case asserts the source contains an explicit
zero-count guard that exits non-zero (it does not execute the script --
it verifies the fail-closed guard exists and is wired to a non-zero exit).
"""

import os
import re
import sys

CASE = {
    "id": "MW-CI-002",
    "kind": "adversarial",
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

_ZERO_GUARD_RE = re.compile(r"if\s+#\w+\s*==\s*0\s+then")
_EXIT_NONZERO_RE = re.compile(r"os\.exit\(\s*([1-9]\d*)\s*\)")


def run(ctx) -> None:
    path = os.path.join(ctx.repo_root, "test", "interceptor.lua")
    assert os.path.isfile(path), "test/interceptor.lua missing"
    with open(path) as f:
        src = f.read()

    m = _ZERO_GUARD_RE.search(src)
    assert m, "no explicit zero-count guard (`if #<tests> == 0 then`) found"
    # The guard body must exit non-zero: find the first os.exit after it.
    tail = src[m.end():]
    m2 = _EXIT_NONZERO_RE.search(tail)
    assert m2, "zero-count guard does not exit non-zero"
    # And the guard must come before the test-running loop, not after.
    assert src.find("if #") < src.find("run_tests"), \
        "zero-count guard must precede test execution"
