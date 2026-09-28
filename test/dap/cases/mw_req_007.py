"""MW-REQ-007 (validation): restart with well-formed arguments succeeds.

`restart` takes an optional nested launch configuration at
`arguments.arguments`; a well-formed one is accepted and answered with
exactly one successful response, and the session stays usable
afterwards. (MW-REQ-004 covers the adversarial side: absent arguments.)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import assert_exactly_one_response  # noqa: E402

CASE = {
    "id": "MW-REQ-007",
    "kind": "validation",
    "layer": "protocol",
    "platforms": ["linux"],
    "timeout_seconds": 90,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["single-response", "clean-shutdown"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def run(ctx) -> None:
    client = ctx.new_client()
    init_session(ctx, client, CASE["timeout_seconds"])
    launch_loop(ctx, client)

    program = ctx.fixture("loop.lua")
    resp = client.request("restart", {
        "arguments": {
            "request": "launch",
            "name": "harness",
            "type": "moonwalk",
            "program": program,
            "console": "internalConsole",
            "stopOnEntry": False,
        },
    }, deadline=20)
    assert resp.get("success") is True, "restart failed: %r" % (resp,)
    assert_exactly_one_response(client, seq_of(resp), "restart")

    alive = client.request("threads", deadline=10)
    assert alive.get("success") is True, (
        "adapter stopped answering after restart: %r" % (alive,))
    assert_exactly_one_response(client, seq_of(alive), "threads")

    end_session(ctx, client)
