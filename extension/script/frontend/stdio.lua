-- frontend/stdio.lua
--
-- DAP transport over the adapter's own stdin/stdout: binary mode on Windows
-- (so the protocol framing bytes survive), unbuffered on both ends. `peek`
-- makes reads non-blocking; an empty read yields "" so the pump keeps
-- spinning when no data is available yet. A closed stdin (client gone
-- without `disconnect`) is detected via poll() in the C++ layer and
-- surfaces as EOF: the adapter shuts down instead of spinning forever.

local subprocess = require('bee.subprocess')
local platform = require('bee.platform')
local proto = require('common.protocol')
local STDIN = io.stdin
local STDOUT = io.stdout
local peek = subprocess.peek
if platform.os == 'windows' then
    local windows = require('bee.windows')
    windows.filemode(STDIN, 'b')
    windows.filemode(STDOUT, 'b')
end
STDIN:setvbuf('no')
STDOUT:setvbuf('no')

---@param v string Framed bytes to write.
local function send(v)
    STDOUT:write(v)
end

-- True once the stdin writer closed. peek() returns nil on EOF (the
-- C++ layer distinguishes it from "no data yet" via poll()); without
-- this the adapter spins forever when the DAP client goes away without
-- sending `disconnect`.
local eof = false

---@return string|nil chunk Bytes available, "" when none yet, nil on EOF.
local function recv()
    if eof then
        return nil
    end
    local n = peek(STDIN)
    if n == nil then
        eof = true
        return nil
    end
    if n == 0 then
        return ''
    end
    return STDIN:read(n)
end

local m = {}
local stat = {}

---@param v boolean Enable protocol debug tracing.
function m.debug(v)
    stat.debug = v
end

---@param pkg table DAP message to frame and send.
function m.sendmsg(pkg)
    send(proto.send(pkg, stat))
end

---@return table? pkg Next received DAP message, or nil when incomplete.
function m.recvmsg()
    local chunk = recv()
    if chunk == nil then
        return nil
    end
    return proto.recv(chunk, stat)
end

---@return boolean eof True once the stdin writer closed (EOF).
function m.eof()
    return eof
end

return m
