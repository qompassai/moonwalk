-- test/run.lua
--
-- Single project entry point for the Moonwalk test program.
--
-- Stages:
--   unit    pure-Lua tests (framing, request validation) -- runs anywhere
--   native  C/C++ test binaries via test/interceptor.lua (needs luamake build)
--   dap     black-box DAP conformance via test/dap/run.py (needs python3;
--           binary-needing cases report BLOCKED without a built adapter)
--   fuzz    libFuzzer targets (needs a sanitizer build; smoke only)
--
-- Usage: `lua test/run.lua [unit|native|dap|fuzz]` from the repo root.
-- Exit 0 only when every executed stage passes; BLOCKED stages are
-- reported but do not fail the run (CI runs each stage separately and
-- requires its own toolchain).

local function have(cmd)
    local p = io.popen('command -v ' .. cmd .. ' 2>/dev/null')
    if not p then
        return false
    end
    local out = p:read('*l')
    p:close()
    return out ~= nil and out ~= ''
end

local lua_bin = (arg and arg[-1]) or 'lua'

local stages = {
    {
        name = 'unit',
        cmd = ('%s test/unit/run_unit.lua'):format(lua_bin),
        needs = nil,
    },
    {
        name = 'native',
        cmd = 'luamake lua test.lua',
        needs = 'luamake',
    },
    {
        name = 'dap',
        cmd = 'python3 test/dap/run.py',
        needs = 'python3',
    },
    {
        name = 'fuzz',
        cmd = 'ls build/fuzz/*_fuzz 2>/dev/null',
        needs = 'built fuzz targets under build/fuzz/',
    },
}

local only = arg and arg[1] or nil
local failures, blocked = 0, 0

for _, stage in ipairs(stages) do
    if not only or only == stage.name then
        io.write(('=== stage: %s ===\n'):format(stage.name))
        local missing = stage.needs and not have(stage.needs:match('^%S+'))
        if missing then
            io.write(('BLOCKED: %s unavailable\n'):format(stage.needs))
            blocked = blocked + 1
        else
            local a, b, c = os.execute(stage.cmd)
            local passed
            if type(a) == 'number' then
                passed = (a == 0) -- Lua 5.1 os.execute returns the status code
            elseif a == true then
                passed = (b == nil or c == 0) -- Lua 5.2+ returns ok, kind, code
            else
                passed = false
            end
            if passed then
                io.write(('stage %s: PASS\n'):format(stage.name))
            else
                io.write(('stage %s: FAIL\n'):format(stage.name))
                failures = failures + 1
            end
        end
    end
end

io.write(('\nrun.lua: %d failed, %d blocked\n'):format(failures, blocked))
if failures > 0 then
    os.exit(1)
end
