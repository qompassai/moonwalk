-- breakme.lua: function calls with a `-- BREAK` marker line.
--
-- Breakpoint cases locate the marker `-- BREAK` below and set a breakpoint
-- on its line number (line 7). The program then calls into `add`, so a
-- working session stops there with a visible stack.
local function add(a, b)
    local s = a + b -- BREAK
    return s
end

local x = add(40, 2)
print('result', x)
