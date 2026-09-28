"""MW-LIFE-012 (adversarial): unknown command before AND after launch.

An unknown command must yield exactly one error response each time --
before launch (frontend: 'error request') and after launch (backend:
'`<cmd>` not yet implemented'). The adapter stays alive throughout.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import (  # noqa: E402
    assert_adapter_alive,
    assert_exactly_one_response,
    assert_unsuccessful_response,
)

CASE = {
    "id": "MW-LIFE-012",
    "kind": "adversarial",
    "layer": "lifecycle",
    "platforms": ["linux"],
    "timeout_seconds": 90,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["single-response", "no-crash-on-invalid-input"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def run(ctx) -> None:
    client = ctx.new_client()
    init_session(ctx, client, CASE["timeout_seconds"])

    # Before launch: the frontend rejects it.
    resp = client.request("frobnicate", {"x": 1}, deadline=10)
    assert_unsuccessful_response(resp, "frobnicate")
    assert_exactly_one_response(client, seq_of(resp), "frobnicate")
    assert_adapter_alive(client)

    launch_loop(ctx, client)

    # After launch: the backend rejects it.
    resp = client.request("frobnicate", {"x": 1}, deadline=10)
    assert_unsuccessful_response(resp, "frobnicate", r"not .*implemented|error request")
    assert_exactly_one_response(client, seq_of(resp), "frobnicate")

    # Still answering.
    resp = client.request("threads", deadline=10)
    assert resp.get("success") is True
    assert_exactly_one_response(client, seq_of(resp), "threads")

    end_session(ctx, client)
