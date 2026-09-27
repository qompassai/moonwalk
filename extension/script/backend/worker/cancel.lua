-- backend/worker/cancel.lua
--
-- Cooperative cancellation for long-running worker requests. The DAP
-- `cancel` request names a request seq; the master broadcasts it here, and
-- long loops (variable expansion, completions, watch checks) poll
-- `m.check()` so they abort promptly instead of running to completion.
-- Cancellation is best-effort: a request already inside a single
-- uninterruptible runtime call (e.g. one rdebug.watch evaluation) finishes
-- that call, then aborts before doing more work.

local CANCELLED_SET_MAX = 64

local m = {}

---Unique token thrown by m.check() on cancellation; compare with ==.
m.CANCELLED = {}

---@type table<integer, boolean> Seqs cancelled while their request is in flight.
local cancelled = {}
local cancelled_count = 0
---@type integer? Seq of the request currently executing on this worker.
local current_seq = nil

---@param seq integer DAP request seq that was cancelled.
function m.note(seq)
    if type(seq) ~= 'number' then
        return
    end
    if not cancelled[seq] then
        if cancelled_count >= CANCELLED_SET_MAX then
            return
        end
        cancelled_count = cancelled_count + 1
    end
    cancelled[seq] = true
end

---@param seq integer DAP request seq now executing.
function m.begin(seq)
    current_seq = seq
end

function m.finish()
    if current_seq ~= nil then
        if cancelled[current_seq] then
            cancelled[current_seq] = nil
            cancelled_count = cancelled_count - 1
        end
        current_seq = nil
    end
end

---Poll point for long loops. Throws m.CANCELLED when aborted.
function m.check()
    if current_seq ~= nil and cancelled[current_seq] then
        cancelled[current_seq] = nil
        cancelled_count = cancelled_count - 1
        current_seq = nil
        error(m.CANCELLED, 0)
    end
end

---@return boolean cancelled True when the current request was cancelled.
function m.is_cancelled()
    return current_seq ~= nil and cancelled[current_seq] == true
end

return m
