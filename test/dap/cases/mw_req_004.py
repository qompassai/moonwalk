"""MW-REQ-004 (adversarial): restart with `arguments` absent entirely.

`request.restart` reads `req.arguments.arguments`; with no arguments table
at all this indexes nil. The adapter must answer exactly one unsuccessful
response instead of throwing.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, malformed_roundtrip  # noqa: E402

CASE = {
    "id": "MW-REQ-004",
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
    malformed_roundtrip(ctx, client, "restart", None)
    end_session(ctx, client)
