"""MW-LIFE-011 (adversarial): duplicate initialize.

The second `initialize` must be either rejected or idempotent -- either
way it gets exactly one correlated response, and the session that follows
(a launch) still works.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import assert_exactly_one_response  # noqa: E402

CASE = {
    "id": "MW-LIFE-011",
    "kind": "adversarial",
    "layer": "lifecycle",
    "platforms": ["linux"],
    "timeout_seconds": 90,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["single-response"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def run(ctx) -> None:
    client = ctx.new_client()
    init_session(ctx, client, CASE["timeout_seconds"])

    # Duplicate initialize: rejected ('error request') or idempotent --
    # both are acceptable, but exactly one correlated response is required.
    resp = client.request("initialize", {"adapterID": "mw-harness"}, deadline=15)
    assert resp.get("type") == "response" and resp.get("command") == "initialize", \
        "duplicate initialize got no correlated response: %r" % (resp,)
    assert_exactly_one_response(client, seq_of(resp), "initialize")

    # The session still works afterwards.
    launch_loop(ctx, client)
    end_session(ctx, client)
