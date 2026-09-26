-- backend/worker/eval/verify.lua
--
-- Runs inside the debugged process (loaded via rdebug.load). Its only job is
-- to syntax-check a candidate expression: if the chunk fails to compile, the
-- error message propagates back to the worker, which marks the breakpoint
-- condition unverified. The expression is never executed here.

local source = ...

local _load
if _VERSION == 'Lua 5.1' then
    _load = loadstring
else
    _load = load
end

assert(_load('return ' .. source, '=(EVAL)'))
