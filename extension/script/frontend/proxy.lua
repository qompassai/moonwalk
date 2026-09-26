-- frontend/proxy.lua
--
-- DAP message router between the editor and the debug backend. It answers
-- `initialize` itself (from common.capabilities), turns `launch`/`attach`
-- into a spawned or injected debuggee plus a backend connection, and then
-- shuttles every other message both ways. `update()` is the per-frame pump
-- called from main.lua.

local socket = require('common.socket')
local net = require('common.net')
local debuger_factory = require('frontend.debuger_factory')
local fs = require('bee.filesystem')
local sp = require('bee.subprocess')
local platform_os = require('frontend.platform_os')
local process_inject = require('frontend.process_inject')
local server
local client
local initReq
local m = {}

---@param pid integer Target process id.
---@return string address Backend unix-socket rendezvous address.
local function getUnixAddress(pid)
    return ('@$tmp/luadbg_%s'):format(pid)
end

---@param pid integer Target process id.
---@param luaVersion string Lua version tag the backend should report.
local function ipc_send_luaversion(pid, luaVersion)
    fs.create_directories(WORKDIR / 'tmp')
    local ipc = require('common.ipc')
    -- The version hint is best-effort: a validation or IO failure here
    -- must not fail the attach.
    local fd = ipc(WORKDIR:string(), pid, 'luaVersion', 'w')
    if not fd then
        return
    end
    fd:write(luaVersion)
    fd:close()
end

---@param address any Candidate `address` config value.
---@return boolean valid True for a supported endpoint form.
local function valid_address(address)
    if type(address) ~= 'string' or address == '' or address:find('%c') then
        return false
    end
    return address:sub(1, 1) == '@'
        or address:match('^%d+%.%d+%.%d+%.%d+:%d+$') ~= nil
        or address:match('^%[[%x:]+%]:%d+$') ~= nil
end

---@param pkg table DAP attach/launch request.
---@return table? args Validated launch configuration.
---@return string? err Reason when the arguments are unusable.
local function check_launch_args(pkg)
    -- The launch configuration arrives as untyped JSON; every field used
    -- below in string formatting, pattern matching, or arithmetic is
    -- validated here so a hostile editor (or a malformed config) gets a
    -- DAP error response instead of crashing the adapter.
    local args = pkg.arguments
    if type(args) ~= 'table' then
        return nil, 'missing `arguments`.'
    end
    if args.request ~= 'launch' and args.request ~= 'attach' then
        return nil, ('invalid `request`: %s'):format(tostring(args.request))
    end
    if args.processId ~= nil then
        local pid = args.processId
        if type(pid) ~= 'number' or pid <= 0 or pid ~= math.floor(pid) then
            return nil, ('invalid `processId`: %s'):format(tostring(pid))
        end
    end
    for _, key in ipairs({ 'luaVersion', 'address', 'runtimeExecutable', 'inject', 'console' }) do
        if args[key] ~= nil and type(args[key]) ~= 'string' then
            return nil, ('invalid `%s`: expected a string, got %s'):format(key, type(args[key]))
        end
    end
    if args.address ~= nil and not valid_address(args.address) then
        return nil, ('invalid `address`: %s'):format(args.address)
    end
    return args
end

---@param req table DAP initialize request being answered.
local function response_initialize(req)
    client.sendmsg({
        type = 'response',
        seq = 0,
        command = 'initialize',
        request_seq = req.seq,
        success = true,
        body = require('common.capabilities'),
    })
end

---@param req table DAP request being failed.
---@param msg string Human-readable failure reason.
local function response_error(req, msg)
    client.sendmsg({
        type = 'response',
        seq = 0,
        command = req.command,
        request_seq = req.seq,
        success = false,
        message = msg,
    })
end

---@param args table `runInTerminal` arguments built by debuger_factory.
local function request_runinterminal(args)
    client.sendmsg({
        type = 'request',
        seq = 0,
        command = 'runInTerminal',
        arguments = args,
    })
end

---@param pkg table DAP attach request.
---@param pid integer Target process id.
---@return boolean ok
---@return string? err Reason when the injection failed.
local function attach_process(pkg, pid)
    local args = pkg.arguments
    if type(args.luaVersion) == 'string' and args.luaVersion:match('^lua%-') then
        ipc_send_luaversion(pid, args.luaVersion)
    end
    local ok, errmsg = process_inject.inject(pid, 'attach', args)
    if not ok then
        return false, errmsg
    end

    server = socket('connect:' .. getUnixAddress(pid))
    server.sendmsg(initReq)
    server.sendmsg(pkg)
    return true
end

---@param pkg table DAP attach request.
---@param args table Launch configuration (`address`, `client`).
local function attach_tcp(pkg, args)
    server = socket((args.client and 'connect:' or 'listen:') .. args.address)
    server.sendmsg(initReq)
    server.sendmsg(pkg)
end

---@param pkg table DAP attach request.
local function proxy_attach(pkg)
    local args = pkg.arguments
    platform_os.init(args)
    if args.processId then
        local ok, errmsg = attach_process(pkg, args.processId)
        if not ok then
            response_error(pkg, ('Cannot attach process `%d`. %s'):format(args.processId, errmsg))
        end
        return
    end
    if args.processName then
        local pids = require('frontend.query_process')(args.processName)
        if #pids == 0 then
            response_error(pkg, ('Cannot found process `%s`.'):format(args.processName))
            return
        elseif #pids > 1 then
            response_error(pkg, ('There are %d processes `%s`.'):format(#pids, args.processName))
            return
        end
        local ok, errmsg = attach_process(pkg, pids[1])
        if not ok then
            response_error(
                pkg,
                ('Cannot attach process `%s` `%d`. %s'):format(args.processName, pids[1], errmsg)
            )
        end
        return
    end
    attach_tcp(pkg, args)
end

---@param args table Launch configuration.
---@param pid integer? Backend process id for the unix-socket rendezvous.
---@return table server Backend connection.
---@return string|integer address Rendezvous address handed to the debuggee.
local function create_server(args, pid)
    local s, address
    if args.address ~= nil then
        s = socket((args.client and 'connect:' or 'listen:') .. args.address)
        address = (args.client and 's:' or 'c:') .. args.address
    else
        pid = pid or sp.get_id()
        s = socket('connect:' .. getUnixAddress(pid))
        address = pid
    end
    return s, address
end

---@param pkg table DAP launch request.
---@return boolean? started True when the terminal launch was requested.
local function proxy_launch_terminal(pkg)
    local args = pkg.arguments
    if args.runtimeExecutable then
        if args.inject ~= 'none' then
            --TODO: support inject's integratedTerminal/externalTerminal
            response_error(pkg, '`inject` is not supported in `' .. args.console .. '`.')
            return
        end
        server = create_server(args)
        local arguments, err = debuger_factory.create_process_in_terminal(initReq, args)
        if not arguments then
            response_error(pkg, err)
            return
        end
        request_runinterminal(arguments)
        return true
    else
        local address
        server, address = create_server(args)
        local arguments, err =
            debuger_factory.create_luaexe_in_terminal(initReq, args, WORKDIR, address)
        if not arguments then
            response_error(pkg, err)
            return
        end
        request_runinterminal(arguments)
        return true
    end
end

---@param pkg table DAP launch request.
---@return boolean? started True when the console launch was requested.
local function proxy_launch_console(pkg)
    local args = pkg.arguments
    if args.runtimeExecutable then
        if args.inject == 'none' and args.address == nil then
            response_error(pkg, '`runtimeExecutable` need specify `inject` or `address`.')
            return
        end
        local process, err = debuger_factory.create_process_in_console(args, function(process)
            local address
            server, address = create_server(args, process:get_id())
            local tagged = type(args.luaVersion) == 'string' and args.luaVersion:match('^lua%-')
            if type(address) == 'number' and tagged then
                ipc_send_luaversion(address, args.luaVersion)
            end
        end)
        if not process then
            response_error(pkg, err)
            return
        end
    else
        local address
        server, address = create_server(args)
        local ok, err = debuger_factory.create_luaexe_in_console(args, WORKDIR, address)
        if not ok then
            response_error(pkg, err)
            return
        end
    end
    return true
end

---@param pkg table DAP launch request.
local function proxy_launch(pkg)
    local args = pkg.arguments
    platform_os.init(args)
    if args.runtimeExecutable and args.inject ~= 'none' then
        args.console = 'internalConsole'
    end
    if args.console == 'integratedTerminal' or args.console == 'externalTerminal' then
        if not proxy_launch_terminal(pkg) then
            return
        end
    else
        if not proxy_launch_console(pkg) then
            return
        end
    end
    server.sendmsg(initReq)
    server.sendmsg(pkg)
end

---@param pkg table DAP attach/launch request.
local function proxy_start(pkg)
    local args, err = check_launch_args(pkg)
    if not args then
        response_error(pkg, err)
        return
    end
    if args.request == 'attach' then
        proxy_attach(pkg)
    elseif args.request == 'launch' then
        proxy_launch(pkg)
    end
end

---@param pkg table DAP message traveling editor -> backend.
local function send(pkg)
    if server then
        if pkg.type == 'response' and pkg.command == 'runInTerminal' then
            return
        end
        server.sendmsg(pkg)
    elseif not initReq then
        if pkg.type == 'request' and pkg.command == 'initialize' then
            pkg.__norepl = true
            initReq = pkg
            response_initialize(pkg)
        else
            response_error(pkg, 'not initialized')
        end
    else
        if pkg.type == 'request' then
            if pkg.command == 'attach' or pkg.command == 'launch' then
                proxy_start(pkg)
            else
                response_error(pkg, 'error request')
            end
        end
    end
end

--- Pump one frame of traffic in both directions; backend close ends the process.
function m.update()
    net.update(10)
    if server then
        server.event_close(function()
            os.exit(0, true)
        end)
        while true do
            local pkg = server.recvmsg()
            if pkg then
                client.sendmsg(pkg)
            else
                break
            end
        end
    end
    while true do
        local pkg = client.recvmsg()
        if pkg then
            send(pkg)
        else
            break
        end
    end
end

---@param io table DAP transport (socket or stdio module).
function m.init(io)
    client = io
end

return m
