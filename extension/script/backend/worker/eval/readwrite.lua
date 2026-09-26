-- backend/worker/eval/readwrite.lua
--
-- Runs inside the debugged process (loaded via rdebug.load) to evaluate a
-- REPL expression that may assign to locals and upvalues. Like readonly.lua
-- it rebinds the target frame's names as upvalues of a wrapper, but the
-- wrapper additionally returns an update list describing which slots changed;
-- the tail of this chunk writes those values back with debug.setlocal /
-- debug.setupvalue so the debuggee actually observes the assignment.

local source, level = ...
level = (level or 0) + 2

-- Realistic ceiling; Lua itself caps upvalues at 255 and locals near 200,
-- so hitting this means the debuggee's debug info is corrupt.
local SLOT_SCAN_MAX = 4096

local _load
local _pack
local _unpack
if _VERSION == 'Lua 5.1' then
    _load = loadstring
    _pack = function(...)
        local t = { ... }
        t.n = select('#', ...)
        return t
    end
    _unpack = unpack
else
    _load = load
    _pack = table.pack
    _unpack = table.unpack
end

local f = assert(debug.getinfo(level, 'f').func, "can't find function")
local args_name = {}
local args_value = {}
local updates = {}
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
                updates[#updates + 1] = ("{'u',name=%q,idx=%d,val=%s}"):format(name, i, name)
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
            updates[#updates + 1] = ("{'l',name=%q,idx=%d,val=%s}"):format(name, i, name)
        end
        i = i + 1
    end
end

local full_source
if #args_name > 0 then
    full_source = ([[
local $ARGS
return function(...)
$SOURCE
end,
function()
return {$UPDATES}
end
]]):gsub('%$(%w+)', {
        ARGS = table.concat(args_name, ','),
        SOURCE = source,
        UPDATES = table.concat(updates, ','),
    })
else
    full_source = ([[
return function(...)
$SOURCE
end,
function()
return {$UPDATES}
end
]]):gsub('%$(%w+)', {
        SOURCE = source,
        UPDATES = table.concat(updates, ','),
    })
end

local compiled = env and assert(_load(full_source, '=(EVAL)', 't', env))
    or assert(_load(full_source, '=(EVAL)'))
if env and setfenv then
    setfenv(compiled, env)
end
local func, update = compiled()
local found = {}
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
        found[name] = true
        i = i + 1
    end
end
local rets
do
    local vararg, v = debug.getlocal(level, -1)
    if vararg then
        local vargs = { v }
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
        rets = _pack(func(_unpack(vargs)))
    else
        rets = _pack(func())
    end
end
for _, info in ipairs(update()) do
    if found[info.name] then
        if info[1] == 'l' then
            debug.setlocal(level, info.idx, info.val)
        else
            debug.setupvalue(f, info.idx, info.val)
        end
    end
end
return _unpack(rets)
