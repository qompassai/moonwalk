---@meta

---
---@class LuaDebug
---Manages the debugger VM inside the debug target.
---
local rdebug = {}

---@param script string
---@param init function | nil
---Starts the debugger VM and executes the code in `script`.
---`init` is optional and may be a C function without upvalues.
---It will be passed as the first argument when executing `script`.
---
function rdebug.start(script, init) end

---
---Shuts down and clears the debugger VM.
---
function rdebug.clear() end

---
---@param name string
---@vararg any
---@return boolean | nil
---Triggers an event in the debugger VM.
---This function waits until the debugger VM has finished processing the event
---before returning.
---
---If the operation fails, or if the returned value is not a boolean, this
---function returns `nil`. Otherwise, it returns the boolean value returned by
---the event handler.
---
function rdebug.event(name, ...) end

---
---@param str string
---@return string
---Converts a string's encoding from ANSI to UTF-8.
---
function rdebug.a2u(str) end

---
---@param name string
---@param value string
---Sets an environment variable that can be retrieved with `os.getenv()`,
---provided that the setter and getter use the same C runtime (CRT).
---
function rdebug.setenv(name, value) end

return rdebug
