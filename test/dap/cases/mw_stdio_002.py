"""MW-STDIO-002 (adversarial): stale-socket cleanup warning path.

The adapter removes stale /tmp/luadbg_* rendezvous sockets at startup
(cleanup_stale_sockets in frontend/proxy.lua). This case plants stale
sockets -- one old-style `luadbg_<pid>` for a dead pid, one new-style
`luadbg_<32 hex>` with an old mtime -- then spawns the adapter. The
cleanup path must not corrupt the DAP stream: stdout stays fully
frame-decodable and the session stays usable.

Files created here are removed afterwards; only paths this case created
are ever touched.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import end_session, init_session, seq_of  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from assertions import assert_exactly_one_response, assert_stdout_only_frames  # noqa: E402

CASE = {
    "id": "MW-STDIO-002",
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

_TMP = os.environ.get("TMPDIR", "/tmp")


def _plant_stale_sockets() -> list[str]:
    # Dead pid far outside any plausible range; /proc/<pid> must not exist.
    dead_pid = 2 ** 22 + 7
    assert not os.path.exists("/proc/%d" % dead_pid)
    paths = [
        os.path.join(_TMP, "luadbg_%d" % dead_pid),
        os.path.join(_TMP, "luadbg_%s" % ("ab" * 16)),
    ]
    for p in paths:
        with open(p, "w") as f:
            f.write("mw-harness stale socket probe")
        # new-style entries are stale when older than one hour
        old = time.time() - 7200
        os.utime(p, (old, old))
    return paths


def run(ctx) -> None:
    planted = _plant_stale_sockets()
    client = ctx.new_client()
    try:
        init_session(ctx, client, CASE["timeout_seconds"])

        # Session usable straight through the cleanup path.
        resp = client.request("threads", deadline=10)
        assert_exactly_one_response(client, seq_of(resp), "threads")

        assert_stdout_only_frames(client)
        end_session(ctx, client)
    finally:
        for p in planted:
            try:
                os.unlink(p)
            except OSError:
                pass
