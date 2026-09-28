"""MW-ATTACH-002 (adversarial): attach with a non-boolean `client` flag.

`client` selects the TCP direction (connect vs listen) and must be an
explicit boolean; a string like `"yes"` is a config typo. The adapter must
answer an explicit type error -- exactly one unsuccessful response whose
message names the problem -- and stay alive.
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

CASE = {
    "id": "MW-ATTACH-002",
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

    resp = client.request("attach", {
        "request": "attach",
        "name": "harness",
        "type": "moonwalk",
        "address": "127.0.0.1:19999",
        "client": "yes",
    }, deadline=15)
    # Explicit type error: the message must say what is wrong.
    assert_unsuccessful_response(resp, "attach", r"boolean|client")
    assert_exactly_one_response(client, seq_of(resp), "attach")

    assert_adapter_alive(client)
    end_session(ctx, client)
