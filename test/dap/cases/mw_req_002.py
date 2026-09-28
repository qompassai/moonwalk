"""MW-REQ-002 (adversarial): setBreakpoints with mistyped `source` and
`breakpoints` (strings instead of table/array).

Wrong JSON types for structured fields must produce exactly one
unsuccessful response, not a throw.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, malformed_roundtrip  # noqa: E402

CASE = {
    "id": "MW-REQ-002",
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
    malformed_roundtrip(ctx, client, "setBreakpoints",
                        {"source": "not-a-table", "breakpoints": "nope"})
    end_session(ctx, client)
