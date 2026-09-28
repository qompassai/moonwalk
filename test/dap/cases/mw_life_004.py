"""MW-LIFE-004 (validation): graceful disconnect ends the session.

After initialize and launch, a `disconnect` with terminateDebuggee gets
exactly one response and the adapter process exits within a bound --
no hang, no orphaned debuggee, no zombie children. (MW-LIFE-001 covers
the abnormal path: the client vanishing without disconnect.)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import init_session, launch_loop, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import (  # noqa: E402
    assert_clean_shutdown,
    assert_exactly_one_response,
    assert_no_tracebacks,
    assert_stdout_only_frames,
)

CASE = {
    "id": "MW-LIFE-004",
    "kind": "validation",
    "layer": "lifecycle",
    "platforms": ["linux"],
    "timeout_seconds": 90,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["stdout-frames", "single-response", "clean-shutdown"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def run(ctx) -> None:
    client = ctx.new_client()
    init_session(ctx, client, CASE["timeout_seconds"])
    launch_loop(ctx, client)

    resp = client.request("disconnect", {"terminateDebuggee": True}, deadline=15)
    assert resp is not None, "no response to disconnect"
    assert_exactly_one_response(client, seq_of(resp), "disconnect")

    code = client.wait_exit(timeout=15)
    assert code is not None, "adapter did not exit after disconnect"

    assert_stdout_only_frames(client)
    assert_no_tracebacks(bytes(client.stderr_bytes))
    assert_clean_shutdown(client, ctx.start_wall)
