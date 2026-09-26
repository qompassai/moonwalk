-- backend/worker/eval/readonly.lua
--
-- Runs inside the debugged process (loaded via rdebug.load) to evaluate a
-- read-only expression (watch/hover) at a given stack level. It snapshots the
-- target frame's upvalues and locals, rebinds them as upvalues of a freshly
-- compiled wrapper, and calls it -- so the expression sees the same names the
-- paused code sees without mutating any debuggee state.

local source, level, symbol = ...
level = (level or 0) + 2

-- Realistic ceiling; Lua itself caps upvalues at 255 and locals near 200,
-- so hitting this means the debuggee's debug info is corrupt.
local SLOT_SCAN_MAX = 4096

local _load
local _unpack
if _VERSION == 'Lua 5.1' then
    _load = loadstring
    _unpack = unpack
else
    _load = load
    _unpack = table.unpack
end

local f = assert(debug.getinfo(level, 'f').func, "can't find function")
local args_name = {}
local args_value = {}
local env
do
    local i = 1
    while true do
        local name, value = debug.getupvalue(f, i)
        if name == nil then
            break
        end
        assert(i <= SLOT_SCAN_MAX)
        if #name > 0 then
            if name == '_ENV' then
                env = value
            else
                args_name[#args_name + 1] = name
                args_value[name] = value
            end
        end
        i = i + 1
    end
end
if not env and getfenv then
    env = getfenv(f)
end
do
    local i = 1
    while true do
        local name, value = debug.getlocal(level, i)
        if name == nil then
            break
        end
        assert(i <= SLOT_SCAN_MAX)
        -- 40 is '(': skip compiler-internal temporaries like "(for index)".
        if name:byte() ~= 40 then
            args_name[#args_name + 1] = name
            args_value[name] = value
        end
        i = i + 1
    end
end

if symbol then
    for name, value in pairs(symbol) do
        args_name[#args_name + 1] = name
        args_value[name] = value
    end
end

local full_source
if #args_name > 0 then
    full_source = ([[
local $ARGS
return function(...)
return $SOURCE
end]]):gsub('%$(%w+)', {
        ARGS = table.concat(args_name, ','),
        SOURCE = source,
    })
else
    full_source = ([[
return function(...)
return $SOURCE
end]]):gsub('%$(%w+)', {
        SOURCE = source,
    })
end
-- Watch/hover expressions are auto-evaluated by the editor on every stop,
-- so the wrapper runs under two guards:
--
-- 1. Sandbox: the debuggee's privileged globals (`os`, `io`, `debug`,
--    `dofile`, `load`, ...) are unreachable, and any global write fails
--    loudly instead of mutating debuggee state. Plain variable/field
--    access and safe calls (`string`/`table`/`math`/...) keep working:
--    locals and upvalues are rebound as wrapper upvalues above, and the
--    remaining globals fall through to the real environment.
-- 2. Step budget: `while true do end` (or any long loop) aborts past
--    EVAL_STEP_MAX VM instructions with a clean error instead of hanging
--    the debuggee worker. The previous hook is restored afterwards, and
--    coroutines the expression spawns get the same hook (new threads do
--    not inherit it).
local EVAL_STEP_MAX = 1000000
local EVAL_HOOK_EVERY = 10000

local SANDBOX_DENY = {
    _G = true,
    os = true,
    io = true,
    debug = true,
    dofile = true,
    load = true,
    loadstring = true,
    loadfile = true,
    collectgarbage = true,
    getfenv = true,
    setfenv = true,
    require = true,
    package = true,
    module = true,
    newproxy = true,
}

local budget_active = false
local budget_remaining = 0

local function budget_hook()
    if not budget_active then
        return
    end
    budget_remaining = budget_remaining - EVAL_HOOK_EVERY
    if budget_remaining <= 0 then
        error('watch expression exceeded its step budget', 0)
    end
end

-- Coroutines spawned by the expression get the budget hook too; without
-- this a `while true` smuggled into `coroutine.create`/`wrap` would dodge
-- the budget because new threads start hookless.
local sandbox_coroutine = setmetatable({}, {
    __index = function(_, key)
        local real = coroutine[key]
        if key == 'create' then
            return function(fn)
                local co = real(fn)
                if budget_active then
                    debug.sethook(co, budget_hook, '', EVAL_HOOK_EVERY)
                end
                return co
            end
        end
        if key == 'wrap' then
            return function(fn)
                local wf = real(fn)
                local _, co = debug.getupvalue(wf, 1)
                if budget_active and co then
                    debug.sethook(co, budget_hook, '', EVAL_HOOK_EVERY)
                end
                return wf
            end
        end
        return real
    end,
})

---@param base table Debuggee environment to sandbox.
---@return table env Sandboxed environment for the wrapper chunk.
local function sandbox_env(base)
    return setmetatable({}, {
        __index = function(_, key)
            if SANDBOX_DENY[key] then
                return nil
            end
            if key == 'coroutine' then
                return sandbox_coroutine
            end
            return base[key]
        end,
        __newindex = function(_, key)
            error(
                ("watch expression is read-only: cannot assign global '%s'"):format(tostring(key)),
                2
            )
        end,
    })
end

---@param func function Compiled wrapper with rebound upvalues.
---@param vargs table Positional varargs for the wrapper.
---@return any ... The wrapper's return values.
local function call_with_budget(func, vargs)
    local prev_hook, prev_mask, prev_count = debug.gethook()
    budget_remaining = EVAL_STEP_MAX
    budget_active = true
    debug.sethook(budget_hook, '', EVAL_HOOK_EVERY)
    local results = table.pack(pcall(func, _unpack(vargs)))
    budget_active = false
    if prev_hook then
        debug.sethook(prev_hook, prev_mask, prev_count)
    else
        debug.sethook()
    end
    if not results[1] then
        error(results[2], 0)
    end
    return _unpack(results, 2, results.n)
end

local sandbox = sandbox_env(env or _G)
local compiled = assert(_load(full_source, '=(EVAL)', 't', sandbox))
if setfenv then
    setfenv(compiled, sandbox)
end
local func = compiled()
do
    local i = 1
    while true do
        local name = debug.getupvalue(func, i)
        if name == nil then
            break
        end
        assert(i <= SLOT_SCAN_MAX)
        if name ~= '_ENV' then
            debug.setupvalue(func, i, args_value[name])
        end
        i = i + 1
    end
end
local vararg, v = debug.getlocal(level, -1)
local vargs = {}
if vararg then
    vargs[1] = v
    local i = 2
    while true do
        vararg, v = debug.getlocal(level, -i)
        if vararg then
            vargs[i] = v
        else
            break
        end
        assert(i <= SLOT_SCAN_MAX)
        i = i + 1
    end
end
return call_with_budget(func, vargs)
