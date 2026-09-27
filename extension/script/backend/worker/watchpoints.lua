-- backend/worker/watchpoints.lua
--
-- Software data breakpoints ("watchpoints"). Real hardware watchpoints
-- need CPU debug registers; instead, while any watch is armed the worker
-- runs with a per-line step hook (see worker.lua event.step) and
-- re-evaluates each watched expression with the read-only evaluator.
-- A watch fires when its rendered value changes between two checks.
--
-- Semantics and limits (all deliberate):
-- * At most DATA_WATCH_MAX watches; extras are dropped by the master.
-- * Expressions are re-evaluated at frame 0 on every line event. A
--   dataId naming a frame-local only resolves while that frame is the
--   current one; evaluation failures never fire, they keep the old value.
-- * Change detection compares the bounded rendered text
--   (variables.createText), i.e. what the user sees in the variables
--   pane. Deep mutations that do not change the rendered summary do not
--   fire -- documented, not a bug.
-- * A fired watch reports a value change, which is inherently a write,
--   so this mechanism satisfies DAP accessType "write" as well as
--   "readWrite". It can never satisfy "read": reads leave no observable
--   change for polling to see.
-- * Baselines are taken when the watch list is installed (the client
--   normally sends setDataBreakpoints while paused). If the list arrives
--   while running, the first line check baselines silently.

local eval = require('backend.worker.eval')
local variables = require('backend.worker.variables')
local cancel = require('backend.worker.cancel')

local DATA_WATCH_MAX = 16

local m = {}

---@type table[] Armed watches: {id=integer, expression=string, last=string?}.
local watches = {}

---@param value any Debuggee refvalue from the read-only evaluator.
---@return string fingerprint Bounded rendered text for change comparison.
local function fingerprint(value)
    local text = variables.createText(value, 'watch')
    if type(text) ~= 'string' then
        return '?'
    end
    return text
end

---@param watch table Watch record to (re-)baseline.
---@return boolean ok True when the expression evaluated cleanly.
local function baseline(watch)
    local res = table.pack(eval.readonly(watch.expression, 0))
    if not res[1] then
        return false
    end
    watch.last = fingerprint(res[2])
    return true
end

---@param breakpoints table[] DAP DataBreakpoint list ({dataId=string}).
function m.set(breakpoints)
    watches = {}
    if type(breakpoints) ~= 'table' then
        return
    end
    for i = 1, math.min(#breakpoints, DATA_WATCH_MAX) do
        cancel.check()
        local bp = breakpoints[i]
        if type(bp) == 'table' and type(bp.dataId) == 'string' and bp.dataId ~= '' then
            local watch = {
                id = i,
                expression = bp.dataId,
                last = nil,
            }
            -- Best-effort: while paused this captures the live value; while
            -- running the evaluator cannot run, so check() baselines lazily.
            baseline(watch)
            watches[#watches + 1] = watch
        end
    end
end

function m.clear()
    watches = {}
end

---@return boolean armed True when at least one watch is installed.
function m.has()
    return #watches > 0
end

---@return integer count
function m.count()
    return #watches
end

---Re-evaluate every watch; call only from the line hook while paused or
-- stepping. Updates baselines for watches that never had one.
-- Deliberately NOT a cancellation poll point: this runs inside the C
-- line hook, and throwing across it is unsafe. The loop is bounded
-- (DATA_WATCH_MAX evaluations) so it cannot hang cancellation anyway.
---@return table? hit Watch whose value changed, or nil.
function m.check()
    for _, watch in ipairs(watches) do
        local res = table.pack(eval.readonly(watch.expression, 0))
        if res[1] then
            local current = fingerprint(res[2])
            if watch.last == nil then
                watch.last = current
            elseif watch.last ~= current then
                watch.last = current
                return watch
            end
        end
        -- Evaluation failure: keep the old baseline, never fire.
    end
    return nil
end

return m
