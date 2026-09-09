---@meta

---
---@class LuaDebugStdio
---Intercepts output from the debug target.
---
local stdio = {}

---
---@class LuaDebugRedirect
---
local redirect = {}

---
---@param n integer | nil
---@return string
---Reads `n` bytes of data.
---If `n` is not provided, reads until the end of the stream.
---
function redirect:read(n) end

---
---@return integer
---Returns the number of bytes currently available to read.
---
function redirect:peek() end

---
---Closes the redirection stream.
---
function redirect:close() end

---
---@param iotype string
---@return LuaDebugRedirect
---Redirects the debug target's stdout or stderr stream.
---
function stdio.redirect(iotype) end

---
---@param enable boolean
---Enables the `print` event.
---Each time the debug target calls `print`, a `print` event is triggered.
---The event handler's return value determines whether that `print` call
---should be ignored.
---
function stdio.open_print(enable) end

---
---@param enable boolean
---Enables the `iowrite` event.
---Each time the debug target calls `io.write` or `io.stdout:write`,
---an `iowrite` event is triggered.
---The event handler's return value determines whether that write operation
---should be ignored.
---
function stdio.open_iowrite(enable) end

return stdio
