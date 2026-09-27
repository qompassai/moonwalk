-- moonwalk/hooks.lua
--
-- Lua scripting / event-hook API for the debugger session. User code (see
-- moonwalk/user.lua) registers callbacks for debugger lifecycle events:
--
--     local hooks = require('moonwalk.hooks')
--
--     -- Example 1: log every breakpoint hit with its location.
--     hooks.on('breakpoint', function(info)
--         print(('moonwalk: hit breakpoint at %s:%d'):format(info.source, info.line))
--     end)
--
--     -- Example 2: announce abnormal stops.
--     hooks.on('pause', function(stop)
--         if stop.reason == 'exception' then
--             print('moonwalk: stopped on exception: ' .. tostring(stop.text))
--         end
--     end)
--
-- Events: 'breakpoint'  {source=string, line=integer}
--         'pause'       {reason=string, ...}  (the DAP stopped-event body)
--         'terminate'   {}
--         'output'      {category=string, output=string}
--
-- Safety: at most HOOK_MAX callbacks per event; every callback runs inside
-- pcall, so a failing hook is logged and skipped -- it can never break the
-- debugger's control flow or swallow a stop.

local log = require('common.log')

local HOOK_MAX = 16

local VALID_EVENTS = {
    breakpoint = true,
    pause = true,
    terminate = true,
    output = true,
}

local m = {}

---@type table<string, function[]> Registered callbacks per event.
local registry = {}

---@param event string One of 'breakpoint', 'pause', 'terminate', 'output'.
---@param fn function Callback invoked as fn(info).
---@return boolean ok False on unknown event, bad callback, or full registry.
function m.on(event, fn)
    if not VALID_EVENTS[event] then
        return false
    end
    if type(fn) ~= 'function' then
        return false
    end
    local list = registry[event]
    if not list then
        list = {}
        registry[event] = list
    end
    if #list >= HOOK_MAX then
        log.error('moonwalk.hooks: too many handlers for event ' .. event)
        return false
    end
    list[#list + 1] = fn
    return true
end

--- One-shot flag for the user init file (see moonwalk/user.lua).
local user_loaded = false

---Fire an event. Cheap no-op when nothing is registered.
---@param event string
---@param info table Event payload (never nil).
function m.emit(event, info)
    if not user_loaded then
        user_loaded = true
        require('moonwalk.user').load_once()
    end
    local list = registry[event]
    if not list or #list == 0 then
        return
    end
    -- Snapshot: a handler that registers/unregisters during emit must not
    -- disturb this dispatch.
    local snapshot = {}
    for i, fn in ipairs(list) do
        snapshot[i] = fn
    end
    for _, fn in ipairs(snapshot) do
        local ok, err = pcall(fn, info)
        if not ok then
            log.error('moonwalk.hooks: handler for ' .. event .. ' failed: ' .. tostring(err))
        end
    end
end

return m
