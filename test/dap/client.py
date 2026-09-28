#!/usr/bin/env python3
"""Black-box DAP client for the moonwalk adapter conformance harness.

Transport-agnostic (stdio pipes or TCP socket), byte-accurate
``Content-Length`` framing, strict stdout verification.

Framing facts (from ``extension/script/common/protocol.lua``):
  * frame      = ``Content-Length: <bytes>\\r\\n\\r\\n`` + JSON payload
  * FRAME_MAX  = 16 MiB  -- larger declared lengths are rejected at the header
  * HEADER_MAX = 8 KiB   -- no ``\\r\\n\\r\\n`` in the first 8 KiB: not DAP
  * malformed framing never throws on the adapter side; garbage is skipped

On the *client* side we are deliberately strict: stdout must contain only
valid DAP frames. Any byte that cannot be part of a frame is recorded as a
framing violation (the parser resyncs and keeps going so one bad stretch
does not hide later frames).

Stdlib only. Timeouts everywhere; a timeout raises :class:`DAPTimeout`,
which the case runner records as FAIL.
"""

from __future__ import annotations

import collections
import json
import os
import re
import select
import signal
import socket
import subprocess
import threading
import time

FRAME_MAX = 16 * 1024 * 1024
HEADER_MAX = 8192
_HEADER_PREFIX = b"Content-Length: "
_SEPARATOR = b"\r\n\r\n"


class DAPError(Exception):
    """Base class for harness-side DAP failures."""


class DAPTimeout(DAPError):
    """A deadline expired. The runner records this as FAIL, never BLOCKED."""


class AdapterDied(DAPError):
    """The adapter process exited (or was never reachable) mid-case."""


class BlockedCase(Exception):
    """Raised by cases when the environment cannot run them (e.g. no binary).

    The runner records this as BLOCKED -- never a pass, never a fail.
    """


def encode_frame(message: dict) -> bytes:
    """Encode one DAP message with byte-accurate Content-Length framing."""
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return _HEADER_PREFIX + str(len(payload)).encode("ascii") + _SEPARATOR + payload


class StrictFrameParser:
    """Incremental, byte-accurate DAP frame parser with violation tracking.

    ``feed()`` returns a list of complete payload byte-strings. Anything on
    the wire that is not a well-formed frame is appended to
    :attr:`violations` (human-readable) and skipped, resyncing at the next
    plausible header start. The parser never raises on adversarial input.
    """

    def __init__(self) -> None:
        self._buf = bytearray()
        self.violations: list[str] = []
        self.frames_seen = 0
        self.bytes_seen = 0

    def feed(self, data: bytes) -> list[bytes]:
        self._buf += data
        self.bytes_seen += len(data)
        out: list[bytes] = []
        while True:
            if not self._buf:
                return out
            if not self._buf.startswith(_HEADER_PREFIX):
                # Not at a header boundary: find the next plausible start.
                nxt = self._buf.find(_HEADER_PREFIX)
                if nxt == -1:
                    # Keep a tail that could become a prefix once more
                    # bytes arrive; anything older is garbage.
                    keep = min(len(self._buf), len(_HEADER_PREFIX) - 1)
                    dropped = bytes(self._buf[: len(self._buf) - keep])
                    if dropped:
                        self.violations.append(
                            "non-frame bytes on stdout: %r" % (dropped[:64],)
                        )
                    del self._buf[: len(self._buf) - keep]
                    return out
                dropped = bytes(self._buf[:nxt])
                self.violations.append(
                    "non-frame bytes on stdout before header: %r" % (dropped[:64],)
                )
                del self._buf[:nxt]
                continue
            sep = self._buf.find(_SEPARATOR)
            if sep == -1:
                if len(self._buf) > HEADER_MAX:
                    self.violations.append(
                        "header exceeded %d bytes without separator; dropped"
                        % HEADER_MAX
                    )
                    del self._buf[:]
                return out
            raw_len = bytes(self._buf[len(_HEADER_PREFIX) : sep])
            try:
                length = int(raw_len.decode("ascii"))
                length_ok = raw_len.decode("ascii").strip() == str(length)
            except (ValueError, UnicodeDecodeError):
                length_ok = False
                length = -1
            if not length_ok or length < 1 or length > FRAME_MAX:
                self.violations.append(
                    "bad Content-Length %r; frame dropped" % (raw_len[:32],)
                )
                # Skip past this separator and resync; a later valid frame
                # in the same read must not be lost with the garbage.
                del self._buf[: sep + len(_SEPARATOR)]
                continue
            body_start = sep + len(_SEPARATOR)
            if len(self._buf) < body_start + length:
                return out  # fragmented: wait for more bytes
            payload = bytes(self._buf[body_start : body_start + length])
            del self._buf[: body_start + length]
            self.frames_seen += 1
            out.append(payload)
        # unreachable


# ---------------------------------------------------------------------------
# /proc helpers (Linux-first, no psutil)
# ---------------------------------------------------------------------------
#
# ASSUMPTIONS (documented loudly, per harness policy):
#  * Linux with /proc mounted. Every helper degrades to "unknown" (empty)
#    elsewhere instead of guessing.
#  * We only ever inspect the process tree we spawned (descendants of the
#    adapter PID). We never signal or attach to anything outside it.


def _read_proc_file(pid: int, name: str) -> bytes | None:
    try:
        with open("/proc/%d/%s" % (pid, name), "rb") as f:
            return f.read()
    except OSError:
        return None


def _ppid_of(pid: int) -> int | None:
    stat = _read_proc_file(pid, "stat")
    if not stat:
        return None
    # comm may contain spaces/parens; ppid is the 4th field after the
    # closing paren of comm.
    try:
        after = stat.split(b")", 1)[1].split()
        return int(after[2 - 1])  # state, ppid -> index 1
    except (IndexError, ValueError):
        return None


def proc_cmdline(pid: int) -> str:
    raw = _read_proc_file(pid, "cmdline")
    if raw is None:
        return ""
    return raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()


def proc_state(pid: int) -> str:
    """Single-letter process state from /proc/<pid>/stat ('' if gone)."""
    stat = _read_proc_file(pid, "stat")
    if not stat:
        return ""
    try:
        return stat.split(b")", 1)[1].split()[0].decode("ascii")
    except (IndexError, UnicodeDecodeError):
        return ""


def is_zombie(pid: int) -> bool:
    return proc_state(pid) == "Z"


def descendants(root_pid: int) -> list[int]:
    """All live descendant PIDs of ``root_pid`` (children, grandchildren...).

    Reads /proc directly. Returns [] on non-Linux or when /proc is missing.
    """
    if not os.path.isdir("/proc/1"):
        return []
    ppid_of: dict[int, int] = {}
    try:
        entries = os.listdir("/proc")
    except OSError:
        return []
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == root_pid:
            continue
        ppid = _ppid_of(pid)
        if ppid is not None:
            ppid_of[pid] = ppid
    # Walk up from every process; keep those that pass through root_pid.
    found: list[int] = []
    for pid in ppid_of:
        p = pid
        seen = set()
        while p in ppid_of and p not in seen:
            seen.add(p)
            p = ppid_of[p]
            if p == root_pid:
                found.append(pid)
                break
    return sorted(found)


def process_tree_text(root_pid: int) -> str:
    """Best-effort textual tree rooted at ``root_pid`` (for artifacts)."""
    lines = ["process tree rooted at %d (reader: pid %d)" % (root_pid, os.getpid())]
    kids = descendants(root_pid)
    if not kids:
        lines.append("<no descendants>")
        return "\n".join(lines) + "\n"
    for pid in kids:
        lines.append(
            "pid=%d ppid=%s state=%s zombie=%s cmd=%s"
            % (
                pid,
                _ppid_of(pid),
                proc_state(pid) or "?",
                is_zombie(pid),
                proc_cmdline(pid)[:160],
            )
        )
    return "\n".join(lines) + "\n"


def kill_tree(root_pid: int, grace: float = 2.0) -> list[int]:
    """SIGTERM then SIGKILL every descendant of ``root_pid``.

    Only ever touches the caller's own spawned tree. Returns the PIDs that
    were signaled. Never raises on a PID that already exited.
    """
    signaled: list[int] = []
    for pid in descendants(root_pid):
        try:
            os.kill(pid, signal.SIGTERM)
            signaled.append(pid)
        except (ProcessLookupError, PermissionError):
            continue
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        if not [p for p in signaled if not is_zombie(p) and proc_state(p)]:
            break
        time.sleep(0.05)
    for pid in signaled:
        if proc_state(pid) and not is_zombie(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                continue
    return signaled


# ---------------------------------------------------------------------------
# DAP client
# ---------------------------------------------------------------------------


class DAPClient:
    """Black-box DAP client speaking to a spawned adapter process.

    Usage::

        client = DAPClient()
        client.spawn_adapter(adapter_path, transport="stdio")
        resp = client.request("initialize", {"adapterID": "harness"})
        client.expect_event("initialized", deadline=10)
        ...
        client.close()

    All blocking calls take a per-call ``deadline`` (seconds) and also
    honor the whole-case deadline set via :meth:`set_case_deadline`.
    """

    def __init__(self) -> None:
        self._seq = 0
        # RLock: _dispatch_payload/_log/_pump_reverse nest lock acquisition
        # on the same thread (reader thread logs while holding the lock;
        # _wait_for holds the condition while _pump_reverse answers).
        self._lock = threading.RLock()
        self._cond = threading.Condition(self._lock)
        self._parser = StrictFrameParser()
        self._proc: subprocess.Popen | None = None
        self._sock: socket.socket | None = None
        self._transport = "stdio"
        self._reader: threading.Thread | None = None
        self._stderr_reader: threading.Thread | None = None
        self._stop = False

        # Raw wire capture: every stdout byte BEFORE parsing, stderr separate.
        self.stdout_bytes = bytearray()
        self.stderr_bytes = bytearray()
        self.decode_violations: list[str] = []  # payloads that were not JSON objects

        # Message routing.
        self._pending: dict[int, dict] = {}  # seq -> {"event": threading.Event, "response": dict|None}
        self._responses: dict[int, dict] = {}  # seq -> first response (late/duplicate tracking)
        self._completed_seqs: set[int] = set()  # waiters that timed out and were reaped
        self.duplicate_responses: list[dict] = []
        self.late_responses: list[dict] = []
        self.unknown_responses: list[dict] = []
        self._events: collections.deque = collections.deque()
        self._reverse: collections.deque = collections.deque()  # reverse requests awaiting handling
        self.reverse_requests: list[dict] = []  # every reverse request ever seen
        self._reverse_handlers: dict[str, object] = {}
        self._default_reverse_handler = None
        self._reverse_pending_deadline = 30.0  # bounded lifetime for unhandled reverse requests

        # Transcript: one entry per notable occurrence, in order.
        self.transcript: list[dict] = []
        self._t0 = time.monotonic()

        self._case_deadline: float | None = None  # monotonic timestamp
        self._exit_code: int | None = None
        self.adapter_pid: int | None = None
        self._launch_program: str | None = None  # for kill_debuggee classification

    # -- transcript ------------------------------------------------------
    def _log(self, direction: str, kind: str, message: object) -> None:
        entry = {
            "t": round(time.monotonic() - self._t0, 3),
            "dir": direction,  # "->" client-to-adapter, "<-" adapter-to-client, "==" internal
            "kind": kind,
            "message": message,
        }
        with self._lock:
            self.transcript.append(entry)
            self._cond.notify_all()

    # -- deadlines -------------------------------------------------------
    def set_case_deadline(self, seconds: float) -> None:
        """Whole-case deadline; every blocking call also honors this."""
        self._case_deadline = time.monotonic() + seconds

    def _time_left(self, deadline: float | None) -> float:
        now = time.monotonic()
        left = float("inf") if deadline is None else deadline
        if self._case_deadline is not None:
            left = min(left, self._case_deadline - now)
        if left <= 0:
            raise DAPTimeout("case deadline exceeded")
        return left

    # -- spawning --------------------------------------------------------
    def spawn_adapter(
        self,
        adapter_path: str,
        transport: str = "stdio",
        port: int | None = None,
        args: tuple[str, ...] = (),
        env: dict | None = None,
        cwd: str | None = None,
    ) -> "DAPClient":
        """Spawn the adapter binary.

        stdio: ``adapter`` speaks DAP on stdin/stdout.
        tcp:   ``adapter <port>`` listens on 127.0.0.1:<port>
               (see ``extension/script/frontend/main.lua``); we connect.
        """
        assert transport in ("stdio", "tcp"), transport
        self._transport = transport
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        if transport == "stdio":
            self._proc = subprocess.Popen(
                [adapter_path, *args],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0,
                env=full_env,
                cwd=cwd,
            )
            self.adapter_pid = self._proc.pid
            self._log("==", "spawn", {"transport": "stdio", "pid": self.adapter_pid,
                                      "argv": [adapter_path, *args]})
        else:
            assert port is not None, "tcp transport needs a port"
            self._proc = subprocess.Popen(
                [adapter_path, str(port), *args],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0,
                env=full_env,
                cwd=cwd,
            )
            self.adapter_pid = self._proc.pid
            # Connect with retries: the adapter needs a moment to listen.
            last_err = None
            for _ in range(100):
                if self._proc.poll() is not None:
                    raise AdapterDied("adapter exited during TCP startup")
                try:
                    self._sock = socket.create_connection(("127.0.0.1", port), timeout=2.0)
                    break
                except OSError as e:
                    last_err = e
                    time.sleep(0.05)
            else:
                raise AdapterDied("could not connect to adapter TCP port: %s" % last_err)
            self._log("==", "spawn", {"transport": "tcp", "pid": self.adapter_pid,
                                      "port": port})
        self._stop = False
        self._reader = threading.Thread(target=self._read_loop, daemon=True,
                                        name="dap-stdout-reader")
        self._reader.start()
        self._stderr_reader = threading.Thread(target=self._stderr_loop, daemon=True,
                                               name="dap-stderr-reader")
        self._stderr_reader.start()
        return self

    # -- transport I/O ---------------------------------------------------
    def _read_chunk(self) -> bytes | None:
        """One raw chunk from the adapter, or None on EOF/closed."""
        if self._transport == "stdio":
            assert self._proc is not None and self._proc.stdout is not None
            try:
                chunk = self._proc.stdout.read(65536)
            except (OSError, ValueError):
                return None
            return chunk if chunk else None
        else:
            assert self._sock is not None
            try:
                chunk = self._sock.recv(65536)
            except OSError:
                return None
            return chunk if chunk else None

    def _read_loop(self) -> None:
        while not self._stop:
            chunk = self._read_chunk()
            if chunk is None:
                with self._lock:
                    self._cond.notify_all()
                break
            # Capture raw bytes BEFORE parsing -- always.
            with self._lock:
                self.stdout_bytes += chunk
            try:
                payloads = self._parser.feed(chunk)
            except Exception as e:  # parser must never raise; belt and braces
                with self._lock:
                    self._parser.violations.append("parser raised: %r" % (e,))
                continue
            for payload in payloads:
                self._dispatch_payload(payload)

    def _stderr_loop(self) -> None:
        if self._proc is None or self._proc.stderr is None:
            return
        while not self._stop:
            try:
                chunk = self._proc.stderr.read(65536)
            except (OSError, ValueError):
                break
            if not chunk:
                break
            with self._lock:
                self.stderr_bytes += chunk

    def _dispatch_payload(self, payload: bytes) -> None:
        try:
            msg = json.loads(payload.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            with self._lock:
                self.decode_violations.append("payload is not valid JSON: %r (%s)"
                                              % (payload[:80], e))
            self._log("<-", "decode-violation", repr(payload[:80]))
            return
        if not isinstance(msg, dict) or "type" not in msg:
            with self._lock:
                self.decode_violations.append("payload is not a DAP message object: %r"
                                              % (payload[:80],))
            self._log("<-", "decode-violation", repr(payload[:80]))
            return
        mtype = msg.get("type")
        with self._lock:
            if mtype == "response":
                rseq = msg.get("request_seq")
                waiter = self._pending.get(rseq) if isinstance(rseq, int) else None
                if waiter is not None and waiter["response"] is None:
                    waiter["response"] = msg
                    self._responses[rseq] = msg
                    self._log("<-", "response", msg)
                    self._cond.notify_all()
                elif rseq in self._responses:
                    # Duplicate: second response for an already-answered seq.
                    self.duplicate_responses.append(msg)
                    self._log("<-", "duplicate-response", msg)
                    self._cond.notify_all()
                elif isinstance(rseq, int) and rseq in self._completed_seqs:
                    # Waiter timed out and was reaped: late response.
                    self.late_responses.append(msg)
                    self._log("<-", "late-response", msg)
                    self._cond.notify_all()
                elif isinstance(rseq, int) and rseq in self._pending:
                    # Defensive: pending but already answered (should not happen).
                    self.late_responses.append(msg)
                    self._log("<-", "late-response", msg)
                    self._cond.notify_all()
                else:
                    # request_seq matches nothing we ever sent.
                    self.unknown_responses.append(msg)
                    self._log("<-", "wrong-seq-response", msg)
                    self._cond.notify_all()
            elif mtype == "event":
                self._events.append(msg)
                self._log("<-", "event", msg)
                self._cond.notify_all()
            elif mtype == "request":
                # Reverse request from the adapter (runInTerminal, startDebugging).
                self.reverse_requests.append(
                    {"at": round(time.monotonic() - self._t0, 3), "message": msg})
                self._log("<-", "reverse-request", msg)
                self._cond.notify_all()
                self._reverse.append(msg)
            else:
                self.decode_violations.append("unknown message type %r" % (mtype,))
                self._log("<-", "decode-violation", msg)

    def _pump_reverse(self) -> None:
        """Answer queued reverse requests via registered handlers.

        Called on every blocking wait so reverse requests are answered
        promptly. Unhandled reverse requests older than the bounded pending
        lifetime are answered with a failure instead of hanging the adapter.
        """
        while self._reverse:
            msg = self._reverse.popleft()
            handler = self._reverse_handlers.get(msg.get("command"),
                                                 self._default_reverse_handler)
            answered = False
            if handler is not None:
                try:
                    success, body = handler(msg.get("arguments") or {})
                    self._answer_reverse(msg, bool(success), body or {})
                    answered = True
                except Exception as e:
                    self._log("==", "reverse-handler-error",
                              {"command": msg.get("command"), "error": repr(e)})
            if not answered:
                age = time.monotonic() - self._t0 - next(
                    (r["at"] for r in self.reverse_requests
                     if r["message"] is msg), 0)
                if age >= self._reverse_pending_deadline:
                    self._answer_reverse(msg, False,
                                         {"error": "harness: no handler; bounded pending lifetime expired"})
                else:
                    # Not yet expired and no handler: requeue, try later.
                    self._reverse.appendleft(msg)
                    break

    def _answer_reverse(self, req: dict, success: bool, body: dict) -> None:
        resp = {
            "type": "response",
            "seq": self._next_seq(),
            "command": req.get("command"),
            "request_seq": req.get("seq"),
            "success": success,
        }
        if body:
            resp["body"] = body
        self.send(resp)
        self._log("->", "reverse-response", resp)

    def on_reverse_request(self, command: str, handler) -> None:
        """Register ``handler(arguments) -> (success: bool, body: dict)``."""
        self._reverse_handlers[command] = handler

    def set_default_reverse_handler(self, handler) -> None:
        self._default_reverse_handler = handler

    # -- sending ---------------------------------------------------------
    def _next_seq(self) -> int:
        with self._lock:
            self._seq += 1
            return self._seq

    def _write(self, data: bytes) -> None:
        if self._transport == "stdio":
            assert self._proc is not None and self._proc.stdin is not None
            try:
                self._proc.stdin.write(data)
                self._proc.stdin.flush()
            except (OSError, ValueError, BrokenPipeError) as e:
                raise AdapterDied("stdin write failed: %s" % e)
        else:
            assert self._sock is not None
            try:
                self._sock.sendall(data)
            except OSError as e:
                raise AdapterDied("tcp write failed: %s" % e)

    def send(self, message: dict) -> int:
        """Send one DAP message (framed). Returns the assigned seq."""
        if "seq" not in message:
            message["seq"] = self._next_seq()
        if "type" not in message:
            message["type"] = "request"
        self._write(encode_frame(message))
        self._log("->", "send", message)
        return message["seq"]

    def send_raw(self, data: bytes) -> None:
        """Write arbitrary bytes to the adapter: fragmented/coalesced/garbage.

        Use with :func:`encode_frame` slices to test reassembly, e.g.::

            frame = encode_frame({...})
            client.send_raw(frame[:7])
            time.sleep(0.1)
            client.send_raw(frame[7:])
        """
        self._write(data)
        self._log("->", "send-raw", {"bytes": len(data), "head": repr(data[:48])})

    # -- receiving -------------------------------------------------------
    def _check_alive(self) -> None:
        if self._proc is not None and self._proc.poll() is not None and not self._pending:
            # Process gone and nobody is waiting: surface on next blocking call.
            pass

    def _wait_for(self, predicate, deadline: float | None, what: str):
        """Wait until predicate() is truthy or the deadline expires."""
        end = time.monotonic() + self._time_left(deadline)
        with self._cond:
            while True:
                self._pump_reverse()
                result = predicate()
                if result:
                    return result
                if self._proc is not None and self._proc.poll() is not None:
                    # Adapter died while waiting: drain first, then report.
                    self._pump_reverse()
                    result = predicate()
                    if result:
                        return result
                    raise AdapterDied(
                        "%s: adapter exited (code %s) before responding"
                        % (what, self._proc.poll()))
                now = time.monotonic()
                remaining = end - now
                if self._case_deadline is not None:
                    remaining = min(remaining, self._case_deadline - now)
                if remaining <= 0:
                    raise DAPTimeout("%s: deadline expired" % what)
                self._cond.wait(timeout=min(remaining, 0.2))

    def request(self, command: str, arguments: dict | None = None,
                deadline: float | None = 10.0) -> dict:
        """Send a request and wait for its correlated response.

        Handles the response life-cycle: success/fail delivered to the
        caller; absent -> :class:`DAPTimeout`; duplicate/late/wrong-seq
        responses are recorded on the client (never crash the waiter).
        """
        seq = self._next_seq()
        msg: dict = {"type": "request", "seq": seq, "command": command}
        if arguments is not None:
            msg["arguments"] = arguments
        waiter = {"event": threading.Event(), "response": None}
        with self._lock:
            self._pending[seq] = waiter
        try:
            self._write(encode_frame(msg))
            self._log("->", "request", msg)

            def got_it():
                return waiter["response"]

            resp = self._wait_for(got_it, deadline,
                                  "request %r (seq %d)" % (command, seq))
            return resp
        finally:
            with self._lock:
                self._pending.pop(seq, None)
                self._completed_seqs.add(seq)

    def recv(self, deadline: float | None = 10.0) -> dict:
        """Return the next non-response message (event or reverse request)."""
        def got_it():
            if self._events:
                return ("event", self._events.popleft())
            # reverse requests are auto-answered by _pump_reverse; expose
            # them here too if still queued.
            if self._reverse:
                return ("reverse", self._reverse.popleft())
            return None
        kind, msg = self._wait_for(got_it, deadline, "recv")
        return msg

    def expect_event(self, name: str, deadline: float | None = 10.0) -> dict:
        """Wait for the next event named ``name``; other events are kept."""
        def got_it():
            for _ in range(len(self._events)):
                msg = self._events.popleft()
                if msg.get("event") == name:
                    return msg
                self._events.append(msg)  # keep ordering for the rest
            return None
        return self._wait_for(got_it, deadline, "event %r" % name)

    def drain_events(self, name: str | None = None) -> list[dict]:
        """Pop all currently queued events (optionally filtered by name)."""
        with self._lock:
            if name is None:
                out = list(self._events)
                self._events.clear()
                return out
            out = [m for m in self._events if m.get("event") == name]
            self._events = collections.deque(
                m for m in self._events if m.get("event") != name)
            return out

    # -- teardown --------------------------------------------------------
    def close_stdin(self) -> None:
        """Close the client-to-adapter channel (EOF for the adapter)."""
        self._log("==", "close-stdin", {"transport": self._transport})
        if self._transport == "stdio":
            if self._proc is not None and self._proc.stdin is not None:
                try:
                    self._proc.stdin.close()
                except OSError:
                    pass
        else:
            if self._sock is not None:
                try:
                    self._sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

    def wait_exit(self, timeout: float = 15.0) -> int | None:
        """Wait for the adapter process to exit; return its exit code."""
        if self._proc is None:
            return self._exit_code
        try:
            self._exit_code = self._proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise DAPTimeout("adapter did not exit within %.1fs" % timeout)
        self._log("==", "adapter-exit", {"code": self._exit_code})
        return self._exit_code

    def kill(self) -> None:
        """Kill the whole spawned tree (adapter + descendants)."""
        self._log("==", "kill", {"pid": self.adapter_pid})
        self._stop = True
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self.adapter_pid is not None:
            kill_tree(self.adapter_pid)
            if self._proc is not None:
                try:
                    self._proc.kill()
                except OSError:
                    pass
        if self._proc is not None:
            try:
                self._proc.wait(timeout=5)
            except (subprocess.TimeoutExpired, OSError):
                pass

    def close(self) -> None:
        """Graceful close: EOF, brief wait, then kill leftovers."""
        try:
            self.close_stdin()
        finally:
            self._stop = True
        if self._proc is not None and self._proc.poll() is None:
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.kill()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    # -- child management --------------------------------------------------
    def child_pids(self) -> list[int]:
        """Live descendant PIDs of the adapter (never touches others)."""
        if self.adapter_pid is None:
            return []
        return [p for p in descendants(self.adapter_pid)
                if proc_state(p) and not is_zombie(p)]

    def kill_backend(self, grace: float = 2.0) -> list[int]:
        """SIGTERM/SIGKILL backend processes in our own spawned tree.

        Classification (documented heuristic): direct children of the
        adapter that do NOT look like the launched debuggee program are
        treated as backend processes. Only PIDs under our adapter are
        ever signaled.
        """
        if self.adapter_pid is None:
            return []
        me = os.getpid()
        killed = []
        for pid in descendants(self.adapter_pid):
            if pid == me:
                continue
            cmd = proc_cmdline(pid)
            if self._launch_program and self._launch_program in cmd:
                continue  # that's the debuggee, not the backend
            try:
                os.kill(pid, signal.SIGTERM)
                killed.append(pid)
            except (ProcessLookupError, PermissionError):
                continue
        self._log("==", "kill-backend", {"pids": killed})
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and any(
                proc_state(p) and not is_zombie(p) for p in killed):
            time.sleep(0.05)
        for pid in killed:
            if proc_state(pid) and not is_zombie(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    continue
        return killed

    def kill_debuggee(self, grace: float = 2.0) -> list[int]:
        """SIGTERM/SIGKILL the debuggee process in our own spawned tree.

        Classification (documented heuristic): descendants whose command
        line contains the launched program path recorded via
        :meth:`note_launch_program`. Falls back to "all descendants" only
        when no program was recorded -- still strictly within our tree.
        """
        if self.adapter_pid is None:
            return []
        me = os.getpid()
        targets = []
        for pid in descendants(self.adapter_pid):
            if pid == me:
                continue
            cmd = proc_cmdline(pid)
            if self._launch_program:
                if self._launch_program in cmd:
                    targets.append(pid)
            else:
                targets.append(pid)
        killed = []
        for pid in targets:
            try:
                os.kill(pid, signal.SIGTERM)
                killed.append(pid)
            except (ProcessLookupError, PermissionError):
                continue
        self._log("==", "kill-debuggee", {"pids": killed})
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and any(
                proc_state(p) and not is_zombie(p) for p in killed):
            time.sleep(0.05)
        for pid in killed:
            if proc_state(pid) and not is_zombie(pid):
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    continue
        return killed

    def note_launch_program(self, program: str) -> None:
        """Record the debuggee program path for kill_debuggee()."""
        self._launch_program = program

    def assert_no_children(self) -> None:
        """Fail if any descendant process of the adapter still exists.

        Zombies count: the adapter is responsible for reaping its debuggee
        (see the reap_debuggee discussion in frontend/proxy.lua).
        """
        if self.adapter_pid is None:
            return
        remaining = descendants(self.adapter_pid)
        if remaining:
            detail = "; ".join(
                "pid=%d zombie=%s cmd=%s" % (p, is_zombie(p), proc_cmdline(p)[:120])
                for p in remaining
            )
            raise AssertionError("child processes remain: %s" % detail)

    # -- transcript ------------------------------------------------------
    _PID_RE = re.compile(r"\bpid[=:\s#]*(\d+)\b", re.IGNORECASE)
    _NUM_RE = re.compile(r"(?<![\w.])(\d{4,})(?![\w.])")

    def normalized_transcript(self, extra_map: dict[str, str] | None = None) -> list[dict]:
        """Transcript with volatile values replaced.

        Replaces: our adapter/backend/debuggee PIDs -> ``<PID>``; TCP ports
        -> ``<PORT>``; /tmp paths -> ``<TMP>``; timestamps and other long
        numbers -> ``<NUM>``. Deterministic for a fixed seed.
        """
        mapping: dict[str, str] = {}
        if self.adapter_pid:
            mapping[str(self.adapter_pid)] = "<PID>"
        for pid in descendants(self.adapter_pid or -1):
            mapping[str(pid)] = "<PID>"
        if extra_map:
            mapping.update(extra_map)

        def norm(obj):
            if isinstance(obj, str):
                s = obj
                for k, v in mapping.items():
                    s = s.replace(k, v)
                s = re.sub(r"/tmp/[^\s\"']*", "<TMP>", s)
                s = re.sub(r"\b\d{1,3}(?:\.\d{1,3}){3}:\d+\b", "<PORT>", s)
                s = re.sub(r"\b20\d\d-\d\d-\d\d[T ]\d\d:\d\d:\d\d[^\s\"']*",
                           "<TS>", s)
                return s
            if isinstance(obj, dict):
                return {k: norm(v) for k, v in obj.items()}
            if isinstance(obj, (list, tuple)):
                return [norm(v) for v in obj]
            return obj

        with self._lock:
            return [norm(e) for e in self.transcript]

    def framing_violations(self) -> list[str]:
        with self._lock:
            return list(self._parser.violations)

    def terminated_event_count(self) -> int:
        with self._lock:
            return sum(1 for e in self.transcript
                       if e["kind"] == "event"
                       and isinstance(e["message"], dict)
                       and e["message"].get("event") == "terminated")
