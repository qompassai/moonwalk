"""MW-STDIO-004 (validation): happy-path stdio session.

initialize -> launch fixtures/loop.lua -> threads -> disconnect. Every
request gets exactly one successful response, stdout stays fully
frame-decodable, and the adapter shuts down cleanly with no children left.
This is the baseline every adversarial case is measured against.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, launch_loop, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import assert_exactly_one_response  # noqa: E402

CASE = {
    "id": "MW-STDIO-004",
    "kind": "validation",
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
    launch_loop(ctx, client)

    threads = client.request("threads", deadline=15)
    assert threads.get("success") is True, "threads failed: %r" % (threads,)
    assert_exactly_one_response(client, seq_of(threads), "threads")
    body = threads.get("body") or {}
    assert isinstance(body.get("threads"), list), (
        "threads body missing thread list: %r" % (threads,))

    end_session(ctx, client)
