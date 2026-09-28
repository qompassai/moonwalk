"""Shared helpers for black-box DAP cases (not a case itself).

File name starts with underscore so run.py skips it during discovery.
"""

from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(_HERE))

from assertions import (  # noqa: E402
    assert_clean_shutdown,
    assert_exactly_one_response,
    assert_no_tracebacks,
    assert_stdout_only_frames,
    assert_unsuccessful_response,
)
from client import DAPClient  # noqa: E402


def seq_of(resp: dict) -> int:
    seq = resp.get("request_seq")
    assert isinstance(seq, int), "response has no integer request_seq: %r" % (resp,)
    return seq


def init_session(ctx, client: DAPClient, timeout_seconds: float,
                 transport: str = "stdio", port: int | None = None) -> str:
    """Spawn the adapter and run initialize. Returns the adapter path.

    Raises ctx.blocked(...) when no adapter binary exists -- the runner
    records BLOCKED, never a fake pass.
    """
    adapter = ctx.require_adapter()
    client.spawn_adapter(adapter, transport=transport, port=port)
    client.set_case_deadline(timeout_seconds - 10)
    resp = client.request("initialize", {"adapterID": "mw-harness",
                                         "pathFormat": "path"}, deadline=15)
    assert resp.get("success") is True, "initialize failed: %r" % (resp,)
    assert_exactly_one_response(client, seq_of(resp), "initialize")
    return adapter


def launch_loop(ctx, client: DAPClient, extra_args: dict | None = None) -> dict:
    """Launch fixtures/loop.lua on the internal console."""
    program = ctx.fixture("loop.lua")
    client.note_launch_program(program)
    arguments = {
        "request": "launch",
        "name": "harness",
        "type": "moonwalk",
        "program": program,
        "console": "internalConsole",
        "stopOnEntry": False,
    }
    if extra_args:
        arguments.update(extra_args)
    resp = client.request("launch", arguments, deadline=20)
    assert resp.get("success") is True, "launch failed: %r" % (resp,)
    assert_exactly_one_response(client, seq_of(resp), "launch")
    return resp


def launch_crash(ctx, client: DAPClient) -> dict:
    """Launch fixtures/crash.lua (dies via error())."""
    program = ctx.fixture("crash.lua")
    client.note_launch_program(program)
    resp = client.request("launch", {
        "request": "launch",
        "name": "harness",
        "type": "moonwalk",
        "program": program,
        "console": "internalConsole",
        "stopOnEntry": False,
    }, deadline=20)
    assert resp.get("success") is True, "launch failed: %r" % (resp,)
    assert_exactly_one_response(client, seq_of(resp), "launch")
    return resp


def malformed_roundtrip(ctx, client: DAPClient, command: str,
                        arguments: dict | None,
                        message_match: str | None = None) -> None:
    """Send one malformed request and assert the adversarial contract.

    Exactly one unsuccessful response (never a crash, never a hang), and
    the adapter still answers a subsequent `threads` request.
    """
    resp = client.request(command, arguments, deadline=15)
    assert_unsuccessful_response(resp, command, message_match)
    assert_exactly_one_response(client, seq_of(resp), command)
    alive = client.request("threads", deadline=10)
    assert alive.get("success") is True, (
        "adapter stopped answering after malformed %r: %r" % (command, alive))
    assert_exactly_one_response(client, seq_of(alive), "threads")


def end_session(ctx, client: DAPClient) -> None:
    """Best-effort graceful teardown + full invariant sweep."""
    try:
        # A response -- successful or 'error request' when nothing was
        # launched -- proves the adapter is still pumping; either is fine.
        client.request("disconnect", {"terminateDebuggee": True}, deadline=15)
    except Exception:
        pass
    try:
        client.wait_exit(timeout=15)
    except Exception:
        client.kill()
        raise
    assert_stdout_only_frames(client)
    assert_no_tracebacks(bytes(client.stderr_bytes))
    assert_clean_shutdown(client, ctx.start_wall)
