-- test/unit/stubs/luadebug/utility.lua
local utility = {}
function utility.closewindow()
    return false
end
function utility.closeprocess()
    utility.__closed = true
end
return utility
