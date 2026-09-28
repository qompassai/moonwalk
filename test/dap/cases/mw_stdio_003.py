"""MW-STDIO-003 (validation): extension/script/frontend/proxy.lua contains
no bare `print(` calls.

In stdio mode the adapter's stdout is the DAP channel: every byte must be
part of a `Content-Length`-framed message. This is a static invariant
check: diagnostics must go through the log module (which redirects to
the log file) or the DAP `output` event -- never `print`.

The check strips Lua comments and string literals first, so mentions of
`print` in comments (like the "Never `print()` here" warning) do not
false-positive; only real call expressions count.
"""

import os
import re

CASE = {
    "id": "MW-STDIO-003",
    "kind": "validation",
    "layer": "stdio",
    "platforms": ["linux", "windows", "macos"],
    "timeout_seconds": 30,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": ["stdout-frames"],
    "owners": ["pax"],
    "suites": ["p0"],
}

_PRINT_CALL_RE = re.compile(r"(?<![\w.])print\s*\(")


def _strip_comments_and_strings(src: str) -> list[str]:
    """Remove `--` comments and string literals, keeping line numbers."""
    out_lines = []
    i, n = 0, len(src)
    line_buf: list[str] = []
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == "--":
            # comment to end of line (long-bracket comments are not used
            # for code in this file; a `--[[` here would be stripped as a
            # line comment, which is conservative for this check)
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            while i < n and src[i] != quote:
                if src[i] == "\\":
                    i += 1
                i += 1
            i += 1  # closing quote
            line_buf.append('""')
            continue
        if two == "[[":
            j = src.find("]]", i + 2)
            i = n if j == -1 else j + 2
            line_buf.append('""')
            continue
        if c == "\n":
            out_lines.append("".join(line_buf))
            line_buf = []
            i += 1
            continue
        line_buf.append(c)
        i += 1
    out_lines.append("".join(line_buf))
    return out_lines


def run(ctx) -> None:
    path = os.path.join(ctx.repo_root, "extension", "script",
                        "frontend", "proxy.lua")
    assert os.path.isfile(path), "proxy.lua missing"
    with open(path) as f:
        src = f.read()
    offenders = []
    for lineno, line in enumerate(_strip_comments_and_strings(src), start=1):
        if _PRINT_CALL_RE.search(line):
            offenders.append("line %d: %s" % (lineno, line.strip()[:100]))
    assert not offenders, (
        "bare print() call(s) write unframed bytes to the DAP stdout channel: %s"
        % "; ".join(offenders))
