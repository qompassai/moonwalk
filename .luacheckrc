-- .luacheckrc — moonwalk static lint configuration.
--
-- Every allowance below is adjudicated individually with a file:line
-- citation (post-stylua line numbers) and a reason. No blanket
-- `unused_args = false`, no global `ignore` patterns.

-- The codebase deliberately runs on Lua 5.1 (LuaJIT) and Lua 5.4:
-- `loadstring` is picked under an explicit `_VERSION == 'Lua 5.1'` guard
-- (extension/script/attach.lua:40, extension/script/launch.lua:13,
-- extension/script/backend/worker/eval/readonly.lua:19,
-- extension/script/backend/worker/eval/readwrite.lua:21,
-- extension/script/backend/worker/eval/verify.lua:12), while 5.4-only
-- syntax is avoided in shared code. `max` keeps both halves checkable.
std = 'max'

-- Intentional cross-module host global: set by the frontend entry point
-- (extension/script/frontend/main.lua:13 `WORKDIR = ...`) and by the
-- macOS inject test (test/inject/inject_macos.lua:74), read by
-- extension/script/frontend/process_inject.lua (lines 44, 168, 197,
-- 198) and extension/script/frontend/proxy.lua (lines 30, 32, 171,
-- 204). Declaring it here silences both the W111 sets and the W113
-- reads.
globals = {
    'WORKDIR',
}

-- The debugger host injects `package.readfile`; the module reads it at
-- extension/script/backend/worker/eval.lua:13 and falls back to a local
-- file-reading implementation when the host did not provide it (W143).
files['extension/script/backend/worker/eval.lua'] = {
    read_globals = { 'package.readfile' },
}

-- Vendored upstream file (LuaJIT FFI reflection helpers). Style is not
-- ours to fix; silence its characteristic warnings individually:
--   W212 unused args — FFI callback params (lines 251,254,262,269 `a`
--       /`refct`; 375 `s`; 499 `voidinfo`; 582 `floatinfo`)
--   W421 shadowing definition (lines 97,109 shadow `i` of line 83;
--       line 450 shadows `id` of line 445)
--   W431 shadowing upvalue `typeinfo` of line 34 (lines 444,614,623,
--       631,636,644,655,663,674,683)
--   W532 unbalanced assignment (line 354)
--   W542 empty if branch (line 507)
files['extension/script/backend/worker/eval/ffi_reflect.lua'] = {
    ignore = { '212', '421', '431', '532', '542' },
}

-- `dbg:setup_patch` intentionally replaces the process-global pcall,
-- xpcall, coroutine.resume and coroutine.wrap so errors and thread
-- switches surface as debugger events (see its docstring). W121 at
-- extension/script/debugger.lua:272 (`pcall`), :279 (`xpcall`); W122 at
-- :292 (`coroutine.resume`), :297 (`coroutine.wrap`).
files['extension/script/debugger.lua'] = {
    ignore = { '121', '122' },
}

-- The debug backend reroutes `print` into the log file:
-- extension/script/common/log.lua:106 `print = log.info` (W121).
files['extension/script/common/log.lua'] = {
    ignore = { '121' },
}

-- Session/socket objects define interface callbacks with colon syntax
-- (`on_data`, `on_close`, `on_connected`, `on_error`, `on_accepted`);
-- `self` is part of the interface but unused in the bodies:
-- extension/script/common/socket.lua:100,103,113,121,131 (W212).
files['extension/script/common/socket.lua'] = {
    ignore = { '212' },
}

-- Empty `elseif x == false then` branches are the intentional no-op arm
-- of a tri-state protocol: nil = closed/error, false = would-block
-- (nothing to do), otherwise data. W542 at
-- extension/script/common/net.lua:120,130,239 and
-- extension/script/backend/worker/undump.lua:80,244,443 (nil chunk
-- constants need no action in those branches).
files['extension/script/common/net.lua'] = {
    ignore = { '542' },
}
files['extension/script/backend/worker/undump.lua'] = {
    ignore = { '542' },
}

-- Intentional rebind: `local sourceDir = fs.path(sourceDir)` converts the
-- vararg string to a path object in place
-- (compile/copy.lua:44-45, W411). A rename to `source_path` would also
-- work and is left to the fix loop.
files['compile/copy.lua'] = {
    ignore = { '411' },
}

-- Overlong generated markdownDescription strings that cannot be wrapped
-- without changing emitted package.json content: W631 at
-- compile/common/package_json.lua:228 (145 cols) and :359 (136 cols).
files['compile/common/package_json.lua'] = {
    ignore = { '631' },
}

-- macOS-only test helper: `load_test(paths, arch)` parameter `arch`
-- intentionally shadows the upvalue `arch` from line 2
-- (test/load/test_macos.lua:29, W431); the parameter is the loop's
-- target architecture while the upvalue is the host architecture.
files['test/load/test_macos.lua'] = {
    ignore = { '431' },
}

-- docs/luadebug/** are `---@meta` API stubs mirroring the debugger host
-- interface: parameter names document the contract and are intentionally
-- unused (e.g. docs/luadebug/visitor.lua:54 `frame`,`index`; :273,283
-- varargs), and `redirect` in docs/luadebug/stdio.lua:12 is mutated with
-- method definitions but never accessed. W212 throughout, W241 for the
-- `redirect` table.
files['docs/luadebug/**'] = {
    ignore = { '212', '241' },
}
