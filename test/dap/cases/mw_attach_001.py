"""MW-ATTACH-001 (adversarial): attach with no selector.

An attach request carrying neither `processId`, `processName`, nor
`address`/`client` selects nothing. The adapter must answer a validation
error BEFORE spawning anything: exactly one unsuccessful response, no new
child processes, adapter stays alive.
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
    "id": "MW-ATTACH-001",
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
    before = set(client.child_pids())

    resp = client.request("attach", {
        "request": "attach",
        "name": "harness",
        "type": "moonwalk",
    }, deadline=15)
    assert_unsuccessful_response(resp, "attach")
    assert_exactly_one_response(client, seq_of(resp), "attach")

    # Nothing was spawned for the selector-less attach.
    after = set(client.child_pids())
    assert after <= before, \
        "attach with no selector spawned processes: %s" % sorted(after - before)

    assert_adapter_alive(client)
    end_session(ctx, client)
