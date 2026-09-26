-- backend/event.lua
--
-- Tiny synchronous pub/sub bus for in-thread notifications such as
-- 'initializing' and 'terminated'. The master thread and every worker thread
-- require this module separately, so each thread gets its own isolated bus;
-- nothing here crosses thread boundaries (that is what bee.channel is for).

local _events = {}
local ev = {}

---@param name string Event name.
---@param ... any Arguments forwarded to every listener.
function ev.emit(name, ...)
    local event = _events[name]
    if event then
        for i = 1, #event do
            event[i](...)
        end
    end
end

---@param name string Event name.
---@param f function Listener to register.
function ev.on(name, f)
    local event = _events[name]
    if event then
        event[#event + 1] = f
    else
        _events[name] = { f }
    end
end

-- Listener lists only grow through `ev.on`; long sessions that register
-- per-request handlers would pin them forever. Removal scans at most
-- `EV_OFF_SCAN_MAX` entries and drops the event's table once it is empty.
-- The scan is bounded rather than asserted: `ev.on` places no cap on
-- registrations, so a long list is reachable through the public API and an
-- assertion here could crash the backend. Entries past the bound are left
-- in place and reported as not removed.
local EV_OFF_SCAN_MAX = 1024

---@param name string Event name.
---@param f function Listener to remove.
---@return boolean removed True when the listener was found and removed.
function ev.off(name, f)
    local event = _events[name]
    if not event then
        return false
    end
    local count = #event
    local limit = count < EV_OFF_SCAN_MAX and count or EV_OFF_SCAN_MAX
    for i = 1, limit do
        if event[i] == f then
            table.remove(event, i)
            if #event == 0 then
                _events[name] = nil
            end
            return true
        end
    end
    return false
end

return ev
