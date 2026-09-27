-- backend/worker/completions.lua
--
-- DAP `completions` provider. Collects candidate names visible at the
-- paused frame -- locals, upvalues, then globals -- filters them by the
-- editor's prefix, and returns a bounded, deterministically sorted item
-- list. Everything is read-only; a failing debuggee lookup degrades to
-- fewer candidates, never to an error.

local rdebug = require('luadebug.visitor')
local cancel = require('backend.worker.cancel')

local COMPLETION_MAX = 200
local SLOT_SCAN_MAX = 4096
local GLOBAL_SCAN_MAX = 2048

local info = {}

---@param depth integer Worker-local stack level.
---@return table funcs Function value of the frame, or empty table.
local function frame_func(depth)
    if rdebug.getinfo(depth, 'f', info) then
        return info.func
    end
    return nil
end

---@param set table<string, boolean> Accumulator for candidate names.
---@param depth integer Worker-local stack level.
local function collect_locals(set, depth)
    local i = 1
    while i <= SLOT_SCAN_MAX do
        if (i % 64) == 0 then
            cancel.check()
        end
        local name = rdebug.getlocalv(depth, i)
        if name == nil then
            return
        end
        if name ~= '(temporary)' and name ~= '(*temporary)' and name ~= '(C temporary)' then
            set[name] = true
        end
        i = i + 1
    end
end

---@param set table<string, boolean> Accumulator for candidate names.
---@param func any Function value of the frame.
local function collect_upvalues(set, func)
    if func == nil then
        return
    end
    local i = 1
    while i <= SLOT_SCAN_MAX do
        if (i % 64) == 0 then
            cancel.check()
        end
        local name = rdebug.getupvaluev(func, i)
        if name == nil then
            return
        end
        if name ~= '_ENV' then
            set[name] = true
        end
        i = i + 1
    end
end

---@param set table<string, boolean> Accumulator for candidate names.
---@param env any Environment table (_ENV or _G).
local function collect_globals(set, env)
    if env == nil then
        return
    end
    -- Single bounded call, mirroring variables.lua's tablehash use; the
    -- index-window semantics of repeated calls are not established, so
    -- paging is deliberately not attempted here.
    local loct = rdebug.tablehash(env, 0, GLOBAL_SCAN_MAX)
    if not loct then
        return
    end
    for i = 1, #loct, 3 do
        cancel.check()
        local ktype, kvalue = rdebug.value(loct[i])
        if ktype == 'string' and type(kvalue) == 'string' then
            set[kvalue] = true
        end
    end
end

---@param depth integer Worker-local stack level.
---@return any Environment table for global-name completion.
local function frame_env(depth)
    local func = frame_func(depth)
    if func ~= nil then
        local name, value = rdebug.getupvaluev(func, 1)
        if name == '_ENV' then
            return value
        end
    end
    return rdebug._G
end

local m = {}

---@param depth integer Worker-local stack level.
---@param text string Prefix typed by the user.
---@return table targets DAP CompletionItem list.
function m.complete(depth, text)
    text = type(text) == 'string' and text or ''
    local set = {}
    collect_locals(set, depth)
    collect_upvalues(set, frame_func(depth))
    collect_globals(set, frame_env(depth))
    local names = {}
    for name in pairs(set) do
        if name:sub(1, #text) == text then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local targets = {}
    for i = 1, math.min(#names, COMPLETION_MAX) do
        targets[#targets + 1] = {
            label = names[i],
        }
    end
    return targets
end

return m
