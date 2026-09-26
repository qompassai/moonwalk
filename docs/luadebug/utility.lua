---@meta

---
---@class LuaDebugUtility
---
local utility = {}

---
--- * Behavior on Windows
---  1. Posts a WM_QUIT message to the main thread.
--- * Behavior elsewhere
---  1. Does nothing
---
function utility.closewindow() end

---
--- Sends a SIGINT signal.
---
function utility.closeprocess() end

return utility
