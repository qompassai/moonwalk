"""MW-LIFE-002 (adversarial): backend closes without `terminated`.

The debuggee is SIGKILLed mid-session, so the backend dies without
emitting `terminated`. The frontend must synthesize exactly one (see
forward_terminated_once in frontend/proxy.lua), then exit -- the client
must see the session end exactly once, not zero times and not twice.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import init_session, launch_loop  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import (  # noqa: E402
    assert_clean_shutdown,
    assert_no_duplicate_terminated,
    assert_no_tracebacks,
    assert_stdout_only_frames,
)

CASE = {
    "id": "MW-LIFE-002",
    "kind": "adversarial",
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
    launch_loop(ctx, client)

    # Wait for the debuggee child to exist, then kill it immediately --
    # before it can exit on its own (which would produce a natural
    # `terminated` and weaken the case).
    deadline = time.monotonic() + 10
    kids: list[int] = []
    while time.monotonic() < deadline:
        if client.terminated_event_count():
            raise AssertionError(
                "debuggee exited naturally before it could be killed; "
                "case cannot exercise the synthesize path")
        kids = client.child_pids()
        if kids:
            break
        time.sleep(0.05)
    assert kids, "no debuggee child appeared within 10s of launch"
    killed = client.kill_debuggee()
    assert killed, "kill_debuggee found no target: %s" % kids

    # Exactly one `terminated` -- the synthesized one.
    ev = client.expect_event("terminated", deadline=20)
    assert ev.get("event") == "terminated"
    time.sleep(1.0)  # let a duplicate arrive if the adapter emits one
    client.drain_events()

    # The frontend exits once the backend connection closes.
    client.wait_exit(timeout=15)

    assert_no_duplicate_terminated(client, exactly_one=True)
    assert_stdout_only_frames(client)
    assert_no_tracebacks(bytes(client.stderr_bytes))
    assert_clean_shutdown(client, ctx.start_wall)
