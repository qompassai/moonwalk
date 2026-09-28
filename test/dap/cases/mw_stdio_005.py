"""MW-STDIO-005 (validation): setBreakpoints with a valid request succeeds.

A well-formed setBreakpoints (source with a string path, breakpoints as
an array of objects) gets exactly one successful response whose body
carries a breakpoints list. Absent `breakpoints` would mean "clear all"
per DAP; here the list is present and must round-trip.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import assert_exactly_one_response  # noqa: E402

CASE = {
    "id": "MW-STDIO-005",
    "kind": "validation",
    "layer": "stdio",
    "platforms": ["linux"],
    "timeout_seconds": 90,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["stdout-frames", "single-response", "clean-shutdown"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def run(ctx) -> None:
    client = ctx.new_client()
    init_session(ctx, client, CASE["timeout_seconds"])
    launch_loop(ctx, client)

    program = ctx.fixture("breakme.lua")
    resp = client.request("setBreakpoints", {
        "source": {"name": "breakme.lua", "path": program},
        "breakpoints": [{"line": 3}, {"line": 5, "condition": "x > 1"}],
    }, deadline=15)
    assert resp.get("success") is True, "setBreakpoints failed: %r" % (resp,)
    assert_exactly_one_response(client, seq_of(resp), "setBreakpoints")
    body = resp.get("body") or {}
    assert isinstance(body.get("breakpoints"), list), (
        "setBreakpoints body missing breakpoints list: %r" % (resp,))

    end_session(ctx, client)
