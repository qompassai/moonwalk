---@meta

---
---@class LuaDebugHookmgr
---A hook manager living in the debugger VM. In principle it could be
---implemented entirely in Lua on top of the visitor API, but hook management
---is the one part of luadebug where performance mattered enough to move it
---into C++.
---
local hookmgr = {}

---
---@param callback fun(name:string,...):boolean|nil
---Initializes hookmgr and registers a callback invoked whenever an event
---fires. Events can be raised by rdebug.probe/rdebug.event or by hookmgr's
---own built-in internal events.
---* `newproto` proto is a function prototype; fires whenever the debugger
---  encounters a new one. The return value tells the debugger whether this
---  proto contains breakpoints, and the debugger then calls
---  hookmgr.break_add or hookmgr.break_del automatically.
---* `bp` fires when a proto with breakpoints runs; the handler checks
---  whether the line number matches.
---* `step` fires when the step condition is satisfied.
---* `funcbp` fires on every function entry. Enable with
---  hookmgr.funcbp_open.
---* `update` fires periodically. Enable with hookmgr.update_open.
---* `exception` fires on every non-memory error. Enable with
---  hookmgr.exception_open. Requires patch support.
---* `thread` fires on every thread entry/exit. Enable with
---  hookmgr.thread_open. Requires patch support.
---
function hookmgr.init(callback) end

---
---@param co thread
---Sets co as the coroutine currently being debugged.
---
function hookmgr.sethost(co) end

---
---@return thread
---Returns the coroutine currently being debugged.
---
function hookmgr.gethost() end

---
---@param co thread
---Refreshes the hookmask of the given coroutine. (Lua does not update it
---for you.)
---
function hookmgr.updatehookmask(co) end

---
---@return integer
---Returns the current stack level.
---
function hookmgr.stacklevel() end

---
---@param proto lightuserdata
---Marks proto as containing breakpoints.
---
function hookmgr.break_add(proto) end

---
---@param proto lightuserdata
---Marks proto as having no breakpoints.
---
function hookmgr.break_del(proto) end

---
---@param enable boolean
---Enables the `bp` event.
---
function hookmgr.break_open(enable) end

---
---Disables the `bp` event for this function call only.
---
function hookmgr.break_closeline() end

---
---@param enable boolean
---Enables the `funcbp` event.
---
function hookmgr.funcbp_open(enable) end

---
---Steps into the next call.
---
function hookmgr.step_in() end

---
---Steps out of the current call.
---
function hookmgr.step_out() end

---
---Steps over the next call.
---
function hookmgr.step_over() end

---
---Cancels the pending `step_in/step_out/step_over` state.
---
function hookmgr.step_cancel() end

---
---@param enable boolean
---Enables the `update` event.
---
function hookmgr.update_open(enable) end

---
---@param enable boolean
---Enables the `exception` event.
---
function hookmgr.exception_open(enable) end

---
---@param enable boolean
---Enables the `thread` event.
---
function hookmgr.thread_open(enable) end

---
---@param co thread
---@return thread
---Returns the coroutine that resumed co (its caller).
---
function hookmgr.coroutine_from(co) end

return hookmgr
