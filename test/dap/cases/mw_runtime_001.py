"""MW-RUNTIME-001 (validation): the public `luaVersion` enum in
compile/common/package_json.lua matches the documented support matrix:
it contains neither `lua55` nor `lua-latest`.

The README forbids claiming Lua 5.5 support until it is implemented and
tested; the generated package.json is the public surface where such a
claim would ship.

The launch-configuration schema is a public contract: every enum value
must map to a real, supported runtime. `lua55` (no such release) and
`lua-latest` (unpinned, non-reproducible) must never appear as selectable
versions. This case extracts the enum and asserts both are absent while
the enum itself is non-empty (so the check cannot pass vacuously).
"""

import os
import re

CASE = {
    "id": "MW-RUNTIME-001",
    "kind": "validation",
    "layer": "runtime",
    "platforms": ["linux", "windows", "macos"],
    "timeout_seconds": 30,
    "destructive": False,
    "needs_ptrace": False,
    "needs_network": False,
    "needs_admin": False,
    "invariants": [],
    "owners": ["pax"],
    "suites": ["p0"],
}

_BANNED = ("lua55", "lua-latest")


def _extract_luaversion_enum(src: str) -> list[str]:
    i = src.find("luaVersion")
    assert i != -1, "luaVersion not found in package_json.lua"
    # The first `enum = { ... }` after the luaVersion attribute is its enum.
    m = re.search(r"enum\s*=\s*\{(.*?)\}", src[i:i + 2000], re.DOTALL)
    assert m, "luaVersion enum not found"
    return re.findall(r"'([^']+)'", m.group(1))


def run(ctx) -> None:
    path = os.path.join(ctx.repo_root, "compile", "common", "package_json.lua")
    assert os.path.isfile(path), "package_json.lua missing"
    with open(path) as f:
        src = f.read()
    enum = _extract_luaversion_enum(src)
    assert enum, "luaVersion enum is empty (check would pass vacuously)"
    for banned in _BANNED:
        assert banned not in enum, (
            "banned luaVersion %r present in public enum %r" % (banned, enum))
