"""MW-STDIO-006 (validation): TCP transport happy path.

The adapter also speaks DAP over TCP (`adapter <port>` listens on
127.0.0.1; see extension/script/frontend/main.lua). initialize ->
threads -> disconnect over a socket must behave exactly like stdio:
exactly one successful response per request, frame-decodable stream,
clean shutdown.
"""

import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import (  # noqa: E402
    assert_clean_shutdown,
    assert_exactly_one_response,
    assert_no_tracebacks,
    assert_stdout_only_frames,
)

CASE = {
    "id": "MW-STDIO-006",
    "kind": "validation",
    "layer": "stdio",
    "platforms": ["linux"],
    "timeout_seconds": 90,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": True,
    "needs_admin": False,
    "invariants": ["stdout-frames", "single-response", "clean-shutdown"],
    "owners": ["pax"],
    "suites": ["p1"],
}


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


def run(ctx) -> None:
    client = ctx.new_client()
    adapter = ctx.require_adapter()
    client.spawn_adapter(adapter, transport="tcp", port=_free_port())
    client.set_case_deadline(CASE["timeout_seconds"] - 10)

    init = client.request("initialize", {"adapterID": "mw-harness",
                                         "pathFormat": "path"}, deadline=15)
    assert init.get("success") is True, "initialize failed: %r" % (init,)
    assert_exactly_one_response(client, seq_of(init), "initialize")

    threads = client.request("threads", deadline=15)
    assert threads.get("success") is True, "threads failed: %r" % (threads,)
    assert_exactly_one_response(client, seq_of(threads), "threads")

    disc = client.request("disconnect", {"terminateDebuggee": True}, deadline=15)
    assert disc is not None, "no response to disconnect"
    assert_exactly_one_response(client, seq_of(disc), "disconnect")

    code = client.wait_exit(timeout=15)
    assert code is not None, "adapter did not exit after disconnect"

    assert_stdout_only_frames(client)
    assert_no_tracebacks(bytes(client.stderr_bytes))
    assert_clean_shutdown(client, ctx.start_wall)
