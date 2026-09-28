"""MW-LIFE-010 (adversarial): request before initialize.

A `threads` request arriving before any `initialize` must get an error
response ('not initialized'), and the adapter process must stay alive --
a later `initialize` still works.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import (  # noqa: E402
    assert_adapter_alive,
    assert_exactly_one_response,
    assert_unsuccessful_response,
)
from client import DAPClient  # noqa: E402

CASE = {
    "id": "MW-LIFE-010",
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
    adapter = ctx.require_adapter()
    client.spawn_adapter(adapter)
    client.set_case_deadline(CASE["timeout_seconds"] - 10)

    # threads before initialize: exactly one error response.
    resp = client.request("threads", deadline=10)
    assert_unsuccessful_response(resp, "threads", r"not initialized")
    assert_exactly_one_response(client, seq_of(resp), "threads")

    # Process still alive and functional: initialize works now.
    assert_adapter_alive(client)
    resp = client.request("initialize", {"adapterID": "mw-harness"}, deadline=15)
    assert resp.get("success") is True, "initialize after early request failed"
    assert_exactly_one_response(client, seq_of(resp), "initialize")

    end_session(ctx, client)
