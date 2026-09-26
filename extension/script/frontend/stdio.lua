-- frontend/stdio.lua
--
-- DAP transport over the adapter's own stdin/stdout: binary mode on Windows
-- (so the protocol framing bytes survive), unbuffered on both ends. `peek`
-- makes reads non-blocking; an empty read yields "" so the pump keeps
-- spinning instead of stalling on EOF.

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

---@return string chunk Bytes currently available, or "" when none are.
local function recv()
    local n = peek(STDIN)
    if n == nil or n == 0 then
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
    return proto.recv(recv(), stat)
end

return m
