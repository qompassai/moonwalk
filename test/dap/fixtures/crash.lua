-- crash.lua: debuggee that dies via error().
--
-- Used by lifecycle cases: the backend should surface the failure and the
-- session must still end with exactly one `terminated` event.
local function boom()
    error('intentional crash for MW-LIFE-003')
end

boom()
