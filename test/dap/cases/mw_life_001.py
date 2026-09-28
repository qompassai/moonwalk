"""MW-LIFE-001 (validation): close stdin after initialize.

The client going away without `disconnect` surfaces as EOF on the stdio
transport (see frontend/stdio.lua). The adapter must shut down within a
bound -- no infinite spin -- leaving no child processes behind.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import init_session  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import (  # noqa: E402
    assert_clean_shutdown,
    assert_no_tracebacks,
    assert_stdout_only_frames,
)

CASE = {
    "id": "MW-LIFE-001",
    "kind": "validation",
    "layer": "lifecycle",
    "platforms": ["linux"],
    "timeout_seconds": 60,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["stdout-frames", "clean-shutdown"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def run(ctx) -> None:
    client = ctx.new_client()
    init_session(ctx, client, CASE["timeout_seconds"])

    client.close_stdin()
    # Bounded exit: wait_exit raises DAPTimeout (a FAIL) past the deadline.
    code = client.wait_exit(timeout=15)
    assert code is not None, "adapter exit code unknown"

    assert_stdout_only_frames(client)
    assert_no_tracebacks(bytes(client.stderr_bytes))
    assert_clean_shutdown(client, ctx.start_wall)
