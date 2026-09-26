-- common/ipc.lua
--
-- Opens a per-process IPC rendezvous file under `<root>/tmp`.
--
-- The attach flow uses these files so the debugger host and the injected
-- debuggee can exchange small bootstrap facts (e.g. the debuggee's Lua
-- version) without a socket. The file name shape `ipc_<pid>_<name>` is a
-- fixed convention shared with the native launcher. Every parameter shapes
-- a filesystem path, and `pid`/`name` can carry launch-config values, so
-- they are validated here and failures return `(nil, err)` instead of
-- asserting: an assertion failure in this sink would crash the adapter.

---@param root string Extension install root; IPC files live in `<root>/tmp`.
---@param pid integer|string Debuggee process id scoping the file name.
---@param name string Channel name, e.g. "luaVersion".
---@param mode? string io.open mode; nil reads.
---@return file*|nil handle Open handle, or nil when the file does not exist.
---@return string|nil err Human-readable reason when the open failed.
local function open_ipc(root, pid, name, mode)
    if type(root) ~= 'string' or root == '' then
        return nil, 'ipc root must be a non-empty string.'
    end
    local pid_ok = false
    if type(pid) == 'number' then
        pid_ok = pid > 0 and pid == math.floor(pid)
    elseif type(pid) == 'string' then
        pid_ok = pid:match('^%d+$') ~= nil
    end
    if not pid_ok then
        return nil, ('ipc pid must be a positive integer, got %s.'):format(tostring(pid))
    end
    -- The channel name becomes part of the file name: allow only
    -- filename-safe characters so it cannot escape `<root>/tmp`.
    if type(name) ~= 'string' or name == '' or name:find('[^%w_%-.]') then
        return nil, ('ipc channel name is not safe: %s.'):format(tostring(name))
    end
    if mode ~= nil and (type(mode) ~= 'string' or mode == '' or mode:find('%c')) then
        return nil, ('ipc mode is not valid: %s.'):format(tostring(mode))
    end
    return io.open(root .. '/tmp/ipc_' .. pid .. '_' .. name, mode)
end

return open_ipc
