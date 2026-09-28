# Vendored `std._debug`

Debug-hint registry vendored from [lua-stdlib/_debug](https://github.com/lua-stdlib/_debug)
(MIT, Copyright (C) 2002-2026 std._debug authors).

- `_debug.lua` is upstream `lib/std/_debug/init.lua`, byte-identical.
- `_debug/version.lua` is what upstream's Makefile generates
  (`return "Debug hints library / git"`).

Loaded by `extension/script/debugger.lua` via `dofile` (the debuggee's
`package.path` is not under our control there); also requireable as
`std._debug` from any adapter script once `package.path` includes
`<root>/script/?.lua`, since `.` in the module name maps to the directory
separator. `MOONWALK_DEBUG=safe|fast|default` selects the hint mode.
