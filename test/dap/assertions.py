#!/usr/bin/env python3
"""Invariant checkers for moonwalk DAP conformance cases.

Each checker raises :class:`AssertionError` with a precise message on
violation, and returns normally when the invariant holds. They operate on
a :class:`test.dap.client.DAPClient` after (or during) a session, plus the
raw captured bytes.

Enforced invariants (from the harness contract):
  1. stdout carries only valid DAP frames
  2. every accepted request gets exactly one correlated response
  3. no duplicate ``terminated`` events
  4. unknown commands -> unsuccessful responses, never crashes
  5. invalid arguments -> unsuccessful responses, no tracebacks
  6. no process or socket remains after the case
"""

from __future__ import annotations

import os
import re

try:
    from .client import DAPClient, descendants
except ImportError:
    # Loaded as a top-level module (the harness runner puts test/dap on
    # sys.path and imports this file directly, so there is no parent
    # package for a relative import).
    from client import DAPClient, descendants

# Lua / Python / native crash markers that must never appear on stderr.
_TRACEBACK_MARKERS = (
    b"stack traceback",          # Lua debug.traceback
    b"Traceback (most recent call last)",  # Python
    b"panic:",                   # Go / LuaJIT-style panics
    b"Segmentation fault",
    b"Assertion failed",
    b"lua: ",                    # bare lua interpreter errors on stderr
)


def assert_stdout_only_frames(client: DAPClient) -> None:
    """Invariant 1: every byte on stdout is part of a valid DAP frame."""
    violations = client.framing_violations()
    if violations:
        raise AssertionError(
            "stdout contained non-frame bytes (%d violations); first: %s"
            % (len(violations), violations[0])
        )
    if client.decode_violations:
        raise AssertionError(
            "stdout contained undecodable frame payloads (%d); first: %s"
            % (len(client.decode_violations), client.decode_violations[0])
        )
    if client._parser.frames_seen == 0 and len(client.stdout_bytes) > 0:
        raise AssertionError(
            "stdout had %d bytes but zero complete frames decoded"
            % len(client.stdout_bytes)
        )


def assert_exactly_one_response(client: DAPClient, seq: int, command: str) -> dict:
    """Invariant 2: the request ``seq`` got exactly one correlated response.

    Returns the response. Fails on duplicates, late extras, or absence.
    (Absence surfaces as DAPTimeout from request(); this covers the
    bookkeeping side: no duplicate/late/unknown responses for the seq.)
    """
    first = client._responses.get(seq)
    if first is None:
        raise AssertionError(
            "no correlated response recorded for request %r (seq %d)" % (command, seq)
        )
    dups = [m for m in client.duplicate_responses if m.get("request_seq") == seq]
    if dups:
        raise AssertionError(
            "duplicate responses for request %r (seq %d): %d extra"
            % (command, seq, len(dups))
        )
    late = [m for m in client.late_responses if m.get("request_seq") == seq]
    if late:
        raise AssertionError(
            "late extra response for request %r (seq %d)" % (command, seq)
        )
    return first


def assert_no_duplicate_terminated(client: DAPClient, exactly_one: bool = False) -> int:
    """Invariant 3: the client saw at most one ``terminated`` event.

    With ``exactly_one=True`` also require one (synthesized-or-real).
    Returns the count observed.
    """
    n = client.terminated_event_count()
    if n > 1:
        raise AssertionError("duplicate terminated events: saw %d" % n)
    if exactly_one and n != 1:
        raise AssertionError("expected exactly one terminated event, saw %d" % n)
    return n


def assert_unsuccessful_response(response: dict, command: str,
                                 message_match: str | None = None) -> dict:
    """Invariants 4/5: unknown commands and invalid arguments must produce
    exactly one response with ``success == false`` -- not a crash, not a
    hang, not a success."""
    if response.get("type") != "response" or response.get("command") != command:
        raise AssertionError(
            "expected a response to %r, got: %r" % (command, response)
        )
    if response.get("success") is not False:
        raise AssertionError(
            "expected unsuccessful response to %r, got success=%r (message=%r)"
            % (command, response.get("success"), response.get("message"))
        )
    if message_match is not None:
        msg = str(response.get("message") or "")
        if not re.search(message_match, msg, re.IGNORECASE):
            raise AssertionError(
                "error message %r does not match %r" % (msg, message_match)
            )
    return response


def assert_no_tracebacks(stderr_bytes: bytes) -> None:
    """Invariant 5b: invalid input must not surface as a traceback/crash."""
    for marker in _TRACEBACK_MARKERS:
        if marker in stderr_bytes:
            idx = stderr_bytes.find(marker)
            context = stderr_bytes[max(0, idx - 120): idx + 300]
            raise AssertionError(
                "traceback/crash marker %r on stderr near: %r"
                % (marker, context[:200])
            )


def assert_no_lingering_sockets(since: float, extra_dirs: list[str] | None = None) -> None:
    """Invariant 6b: no ``luadbg_*`` rendezvous socket files created during
    the case may remain. (Abstract-namespace sockets leave no files; the
    filesystem ones must be cleaned up -- cf. cleanup_stale_sockets.)"""
    dirs = ["/tmp"]
    tmpdir = os.environ.get("TMPDIR")
    if tmpdir and tmpdir not in dirs:
        dirs.append(tmpdir)
    if extra_dirs:
        dirs.extend(extra_dirs)
    leftovers = []
    for d in dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for name in names:
            if not name.startswith("luadbg_"):
                continue
            path = os.path.join(d, name)
            try:
                if os.path.getmtime(path) >= since:
                    leftovers.append(path)
            except OSError:
                continue
    if leftovers:
        raise AssertionError(
            "rendezvous socket files left behind: %s" % ", ".join(leftovers)
        )


def assert_clean_shutdown(client: DAPClient, case_start_mtime: float) -> None:
    """Invariant 6: no process or socket remains after the case."""
    client.assert_no_children()
    assert_no_lingering_sockets(case_start_mtime)


def assert_adapter_alive(client: DAPClient) -> None:
    """The adapter process is still running (did not crash)."""
    proc = client._proc
    if proc is None or proc.poll() is not None:
        raise AssertionError(
            "adapter process is not alive (exit code %s)"
            % (proc.poll() if proc else None)
        )
