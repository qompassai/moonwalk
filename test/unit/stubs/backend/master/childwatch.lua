-- test/unit/stubs/backend/master/childwatch.lua
local childwatch = {}
childwatch.__cleanups = 0
function childwatch.cleanup()
    childwatch.__cleanups = childwatch.__cleanups + 1
end
return childwatch
