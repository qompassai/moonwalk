"""MW-LIFE-003 (validation): natural `terminated`, then close.

The debuggee dies via error() (fixtures/crash.lua), the backend emits a
natural `terminated`, and then the client goes away (stdin closed). The
close path must not emit a second `terminated`: the client sees exactly
one.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import init_session, launch_crash  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import (  # noqa: E402
    assert_clean_shutdown,
    assert_no_duplicate_terminated,
    assert_no_tracebacks,
    assert_stdout_only_frames,
)

CASE = {
    "id": "MW-LIFE-003",
    "kind": "validation",
    "layer": "lifecycle",
    "platforms": ["linux"],
    "timeout_seconds": 120,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["single-terminated", "clean-shutdown"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def run(ctx) -> None:
    client = ctx.new_client()
    init_session(ctx, client, CASE["timeout_seconds"])
    launch_crash(ctx, client)

    # Natural death: the backend reports it.
    ev = client.expect_event("terminated", deadline=20)
    assert ev.get("event") == "terminated"

    # Now the client goes away without disconnect.
    client.close_stdin()
    client.wait_exit(timeout=15)
    time.sleep(1.0)  # let a duplicate arrive if the adapter emits one
    client.drain_events()

    assert_no_duplicate_terminated(client, exactly_one=True)
    assert_stdout_only_frames(client)
    assert_no_tracebacks(bytes(client.stderr_bytes))
    assert_clean_shutdown(client, ctx.start_wall)
