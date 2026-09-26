-- extension/script/attach.lua
--
-- Entry point for the inject-into-process attach flow.
--
-- Called as `attach.lua <extension-root> <pid>` inside a freshly injected
-- Lua state that may not be fully initialized yet: when any core global is
-- missing we bail out with `'wait initialized'` so the native injector
-- retries later instead of crashing the target. Once the state is usable we
-- load the debugger client, start it against a per-pid unix socket, and
-- report the debuggee's Lua version so the right runtime binary is picked.

local path, pid = ...

if
    _VERSION == nil
    or type == nil
    or assert == nil
    or tostring == nil
    or error == nil
    or dofile == nil
    or io == nil
    or os == nil
    or debug == nil
    or package == nil
    or string == nil
then
    return 'wait initialized'
end

local is_luajit = tostring(assert):match('builtin') ~= nil
if is_luajit and jit == nil then
    return 'wait initialized'
end

--- Loads a chunk from `filename` naming it `(debugger.lua)` in
--- tracebacks; picks `loadstring` on 5.1 where `load` takes a function.
---@param filename string Absolute path of the chunk to load.
---@return any ... Whatever the loaded chunk returns.
local function dofile(filename)
    local load = _VERSION == 'Lua 5.1' and loadstring or load
    local f = assert(io.open(filename))
    local str = f:read('*a')
    f:close()
    return assert(load(str, '=(debugger.lua)'))(filename)
end

--- Reads the debuggee's Lua version string via the per-pid IPC file.
---@return string|nil version e.g. "Lua 5.4", or nil when unavailable.
local function get_lua_version()
    local ipc = dofile(path .. '/script/common/ipc.lua')
    local fd = ipc(path, pid, 'luaVersion')
    if not fd then
        return
    end
    local result = fd:read('a')
    fd:close()
    return result
end

local dbg = dofile(path .. '/script/debugger.lua')
dbg:start({
    address = ('@$tmp/luadbg_%s'):format(pid),
    luaVersion = get_lua_version(),
})
dbg:event('wait')
return 'ok'
