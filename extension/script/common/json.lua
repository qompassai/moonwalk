-- common/json.lua
--
-- JSON provider behind `require('common.json')`.
--
-- The build (`compile/common/make.lua`, target `copy_json`) copies
-- `3rd/json.lua/json.lua` over this file into `publish/script/common/`,
-- so the packaged adapter uses the vendored copy directly. This shim
-- exists only so the module resolves identically in the raw source tree
-- (tests, tooling, editor-driven runs) without a build step: it loads the
-- vendored file by path relative to this file, so it works regardless of
-- the caller's `package.path`.
--
-- The vendored module returns its table; it sets no globals.

local info = debug.getinfo(1, 'S')
assert(info ~= nil and type(info.source) == 'string', 'common.json: cannot locate this file')
-- `@/repo/extension/script/common/json.lua` -> its directory.
local here = info.source:match('^@(.+/)[^/]+$')
assert(type(here) == 'string', 'common.json: unexpected source form')
-- `extension/script/common/` -> up three -> repo root -> `3rd/`.
local vendored = here .. '../../../3rd/json.lua/json.lua'
local chunk, load_err = loadfile(vendored)
assert(chunk ~= nil, 'common.json: cannot load vendored json: ' .. tostring(load_err))
return chunk()
