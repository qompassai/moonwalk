"""MW-REQ-003 (adversarial): variables with a non-numeric
`variablesReference` (string instead of number).

The reference is bit-split (`>> 24`) on the backend; a string must be
rejected with exactly one unsuccessful response, not a throw.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, malformed_roundtrip  # noqa: E402

CASE = {
    "id": "MW-REQ-003",
    "kind": "adversarial",
    "layer": "protocol",
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
    launch_loop(ctx, client)
    malformed_roundtrip(ctx, client, "variables",
                        {"variablesReference": "string-not-number"})
    end_session(ctx, client)
