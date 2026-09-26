-- extension/script/bootstrap.lua
--
-- Entry point for the standalone debugger frontend process.
--
-- Derives the extension root from `package.cpath`, points `package.path`
-- at the bundled scripts, honors a single `-e <expr>` command-line
-- expression (evaluated before startup), drops empty arguments, then hands
-- control to `frontend/main.lua` with the remaining arguments.

local root
do
    local pattern = '[/][^/]+'
    root = package.cpath:match('(.+)' .. pattern .. pattern .. '$')
end
package.path = root .. '/script/?.lua'

for i = 1, #arg do
    if arg[i] == '-e' then
        local expr = assert(arg[i + 1], "'-e' needs argument")
        assert(load(expr, '=(command line)'))()
        table.remove(arg, i + 1)
        table.remove(arg, i)
        break
    end
end

for i = #arg, 1, -1 do
    if arg[i] == '' then
        table.remove(arg, i)
    end
end

local func = assert(loadfile(root .. '/script/frontend/main.lua'))
func(arg[1])
