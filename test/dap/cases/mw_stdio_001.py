"""MW-STDIO-001 (adversarial): launch with `env.LD_PRELOAD` set.

The adapter must strip dynamic-linker injection variables from the
debuggee environment (see check_launch_args in frontend/proxy.lua): a
malicious launch.json could otherwise preload a hostile .so whose
constructors run before the debugger attaches. The launch must still
succeed, stdout must remain fully frame-decodable, and the session must
stay usable (threads answers).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import (  # noqa: E402
    assert_adapter_alive,
    assert_exactly_one_response,
    assert_stdout_only_frames,
)

CASE = {
    "id": "MW-STDIO-001",
    "kind": "adversarial",
    "layer": "stdio",
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

    # LD_PRELOAD points at a nonexistent .so on purpose: if the adapter
    # failed to strip it, the debuggee's dynamic linker would refuse to
    # start it and the launch would fail.
    resp = client.request("launch", {
        "request": "launch",
        "name": "harness",
        "type": "moonwalk",
        "program": ctx.fixture("loop.lua"),
        "console": "internalConsole",
        "stopOnEntry": False,
        "env": {
            "LD_PRELOAD": "/tmp/mw-harness-evil.so",
            "LD_LIBRARY_PATH": "/tmp/mw-harness-evil",
            "HARMLESS": "1",
        },
    }, deadline=20)
    assert resp.get("success") is True, \
        "launch with stripped env failed: %r" % (resp,)
    assert_exactly_one_response(client, seq_of(resp), "launch")
    assert_adapter_alive(client)

    # The debuggee must actually come up: the backend emits `initialized`
    # only after the debuggee connects. If LD_PRELOAD had survived into
    # the debuggee environment, the dynamic linker would have refused to
    # start it and this event would never arrive.
    ev = client.expect_event("initialized", deadline=20)
    assert ev.get("event") == "initialized"

    # Session still usable: threads answers exactly once.
    resp = client.request("threads", deadline=10)
    assert resp.get("success") is True, "threads failed: %r" % (resp,)
    assert_exactly_one_response(client, seq_of(resp), "threads")

    # stdout is fully frame-decodable despite the hostile env.
    assert_stdout_only_frames(client)

    end_session(ctx, client)
