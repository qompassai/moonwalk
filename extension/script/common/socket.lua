-- common/socket.lua
--
-- DAP session over `common.net`: parses a `mode:address` endpoint, owns one
-- logical session (reconnecting in `connect` mode, single-accepted-client
-- in `listen` mode), and buffers reads/writes across reconnects.
--
-- Wire code: restyle conservatively, never change connection or framing
-- behavior. Address shapes (`connect:`/`listen:`, `@$tmp` unix sockets,
-- IPv4, `[IPv6]`) are shared with the native launcher and VS Code side.

local net = require('common.net')
local proto = require('common.protocol')
local log = require('common.log')

-- closeall pumps the event loop with a zero timeout until every handle
-- reports closed; a stuck handle must not hang shutdown forever.
local CLOSEALL_PUMP_MAX = 30000

---@class SocketEndpoint
---@field protocol string "unix" | "tcp" | "tcp6".
---@field address string Socket path or IP; port lives in `port` for TCP.
---@field port integer|nil TCP port.
---@field mode string "connect" | "listen".

--- Parses `"<mode>:<address>"` into a SocketEndpoint.
---
--- Address forms: `@$tmp/<name>` (abstract/temp-dir unix socket, `$tmp`
--- expands to the OS temp directory), `1.2.3.4:5678`, `[::1]:5678`.
---@param param string Endpoint string, e.g. "listen:@$tmp/luadbg_1234".
---@return SocketEndpoint endpoint
local function parse_address(param)
    assert(type(param) == 'string')
    local mode, address = param:match('^([a-z]+):(.*)')
    assert(mode ~= nil and address ~= nil)
    if address:sub(1, 1) == '@' then
        local fs = require('bee.filesystem')
        -- `$tmp` keeps the abstract socket path short; strip the trailing
        -- separator so the join below never doubles it.
        address = address:gsub('%$tmp', (fs.temp_directory_path():string():gsub('([/\\])$', '')))
        return {
            protocol = 'unix',
            address = address:sub(2),
            mode = mode,
        }
    end
    local ipv4, port = address:match('(%d+%.%d+%.%d+%.%d+):(%d+)')
    if ipv4 then
        return {
            protocol = 'tcp',
            address = ipv4,
            port = tonumber(port),
            mode = mode,
        }
    end
    local ipv6, ipv6_port = address:match('%[([%d:a-fA-F]+)%]:(%d+)')
    if ipv6 then
        return {
            protocol = 'tcp6',
            address = ipv6,
            port = tonumber(ipv6_port),
            mode = mode,
        }
    end
    error('Invalid address.')
end

---@class DapSocket
---@field event_close fun(f: fun()) Register the on-close callback.
---@field debug fun(v: boolean) Toggle wire-frame logging.
---@field sendmsg fun(pkg: table) Frame and queue one DAP message.
---@field recvmsg fun(): table|nil Decode one buffered DAP message, if any.
---@field update fun(timeout: number|nil) Pump the event loop once.
---@field closeall fun():boolean,string? Shut down the session and listener,
---pumping (bounded) for close.

--- Creates a DAP session for `param` (`"connect:..."` or `"listen:..."`).
---
--- In `connect` mode the session auto-reconnects on error; outbound bytes
--- written before the connection is up are buffered and flushed on connect.
--- In `listen` mode only the first accepted client becomes the session.
---@param param string Endpoint string, e.g. "connect:127.0.0.1:4278".
---@return DapSocket|nil session The session, or nil for an unknown mode.
return function(param)
    local target = parse_address(param)
    local stat = {}
    local readbuf = ''
    local writebuf = ''
    local server = nil
    local session = nil
    local closefunc = function() end
    local m = {}

    local function cleanup()
        session = nil
        readbuf = ''
        writebuf = ''
        stat = { debug = stat.debug }
        closefunc()
    end

    local function init_session(new_session)
        if session then
            return
        end
        session = new_session
        function session:on_data(data)
            readbuf = readbuf .. data
        end
        function session:on_close()
            cleanup()
        end
        return true
    end

    if target.mode == 'connect' then
        local function try_connect()
            local s = net.connect(target.protocol, target.address, target.port)
            if s then
                function s:on_connected()
                    local ok = init_session(s)
                    assert(ok)
                    if writebuf ~= '' then
                        s:write(writebuf)
                        writebuf = ''
                    end
                end
                function s:on_error()
                    try_connect()
                end
            else
                net.async(try_connect)
            end
        end
        try_connect()
    elseif target.mode == 'listen' then
        server = assert(net.listen(target.protocol, target.address, target.port))
        function server:on_accepted(new_s)
            return init_session(new_s)
        end
    else
        return
    end

    function m.event_close(f)
        closefunc = f
    end

    function m.debug(v)
        stat.debug = v
    end

    function m.sendmsg(pkg)
        local data = proto.send(pkg, stat)
        if session == nil then
            writebuf = writebuf .. data
            return
        end
        session:write(data)
    end

    function m.recvmsg()
        local data = readbuf
        readbuf = ''
        return proto.recv(data, stat)
    end

    function m.update(timeout)
        net.update(timeout)
    end

    ---Shut down the session and listener, pumping until every handle reports
    ---closed. Gives up after CLOSEALL_PUMP_MAX zero-timeout pumps with a
    ---warning instead of hanging forever on a stuck handle.
    ---@return boolean ok
    ---@return string? err Present when the wait gave up.
    function m.closeall()
        local fds = {}
        if target.mode == 'connect' then
            if session == nil then
                return true
            end
            session:close()
            fds[1] = session
        elseif target.mode == 'listen' then
            fds[1] = server
            if session ~= nil then
                session:close()
                fds[2] = session
            end
            server:close()
        end
        local function is_finish()
            for _, fd in ipairs(fds) do
                if not fd:is_closed() then
                    return false
                end
            end
            return true
        end
        for _ = 1, CLOSEALL_PUMP_MAX do
            if is_finish() then
                return true
            end
            net.update(0)
        end
        log.warn(
            ('closeall: handles did not close after %d pumps; giving up'):format(CLOSEALL_PUMP_MAX)
        )
        return false, 'closeall timed out waiting for handles to close'
    end

    return m
end
