-- frontend/proxy.lua
--
-- DAP message router between the editor and the debug backend. It answers
-- `initialize` itself (from common.capabilities), turns `launch`/`attach`
-- into a spawned or injected debuggee plus a backend connection, and then
-- shuttles every other message both ways. `update()` is the per-frame pump
-- called from main.lua.

local socket = require('common.socket')
local log = require('common.log')
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

-- The debuggee process handle for the active session, when the frontend
-- spawned it (internalConsole launches). Held so the child is reaped on
-- session teardown; otherwise a finished debuggee lingers as a zombie.
-- (Upstream lua-debug 2.3.0 prints "may become a zombie process" and exits
-- without reaping.) Terminal launches are spawned by the client, and
-- attach paths spawn nothing, so neither sets this.
local debuggee = nil

-- Bounded reap: poll for exit, then kill a stuck child and reap it. Never
-- blocks adapter shutdown forever on a hung debuggee.
local REAP_TIMEOUT_MS = 2000
local REAP_POLL_MS = 50

-- Signal numbers for the reap escalation ladder.
local SIGTERM = 15
local SIGKILL = 9
-- How long to wait after SIGTERM before escalating to SIGKILL.
local KILL_ESCALATION_MS = 1000

local function reap_debuggee()
    local proc = debuggee
    debuggee = nil

    if proc == nil then
        return
    end

    local waited = 0

    while proc:is_running() and waited < REAP_TIMEOUT_MS do
        net.update(REAP_POLL_MS)
        waited = waited + REAP_POLL_MS
    end

    if proc:is_running() then
        proc:kill(SIGTERM)
        -- Bounded escalation: if the child ignores SIGTERM, SIGKILL it.
        -- Without this, proc:wait() below blocks forever on a
        -- TERM-trapping child, hanging adapter shutdown.
        waited = 0
        while proc:is_running() and waited < KILL_ESCALATION_MS do
            net.update(REAP_POLL_MS)
            waited = waited + REAP_POLL_MS
        end
        if proc:is_running() then
            proc:kill(SIGKILL)
        end
    end

    proc:wait()
end

-- Sequence counter for frontend-to-client reverse requests. DAP clients
-- correlate responses by request_seq, so these must be unique.
local reverse_seq = 0

-- runInTerminal request seqs still awaiting the client's response.
---@type table<integer, boolean>
local pending_terminal = {}

-- True once a `terminated` event has been forwarded to the client for the
-- current session. The backend is supposed to send it when the debuggee
-- ends, but if the backend connection drops first (or the backend dies
-- without sending it), the frontend synthesizes one on close so the
-- client's debug session always ends cleanly instead of hanging.
local terminated_forwarded = false

---Forward a `terminated` event to the DAP client, at most once per session.
---Every `terminated` the frontend emits — a backend event from the pump or
---the close drain, or the synthesized fallback — goes through here. The
---backend is supposed to emit it exactly once, but its close path can emit
---a second one (backend/master/request.lua's `ev.on('close')` is not
---covered by the master's sendTerminatedOnce guard); without this choke
---point the frontend would pass both through and the client would see the
---session end twice. A duplicate is dropped, never forwarded.
---@param pkg table DAP `terminated` event to forward.
---@return boolean forwarded True when this call forwarded the event.
local function forward_terminated_once(pkg)
    if terminated_forwarded then
        return false
    end
    terminated_forwarded = true
    -- pcall: the client may already be gone on the close path; a failed
    -- send must not take the teardown down with it.
    pcall(client.sendmsg, pkg)
    return true
end

-- True once the backend has acknowledged `disconnect`. In the detach case
-- (`terminateDebuggee: false`) the backend stays alive with the debuggee,
-- so the frontend must tear itself down instead of waiting for a backend
-- close that will never come; otherwise every detach leaks the adapter.
local disconnect_acked = false

-- True when the in-flight `disconnect` terminates the debuggee. A
-- terminating disconnect must NOT take the `disconnect_acked` early exit:
-- the backend drains in-flight output and emits `terminated` before it
-- closes, and the frontend has to stay alive to forward those. Defaults
-- to the backend's rule (`terminateDebuggee` defaults to true for launch).
local disconnect_terminate = true

---@param pid integer Target process id.
---@return string address Backend unix-socket rendezvous address.
local function getUnixAddress(pid)
    return ('@$tmp/luadbg_%s'):format(pid)
end

---Remove stale `/tmp/luadbg_*` rendezvous sockets left by crashed sessions.
---Old-style `luadbg_<pid>` is stale when `/proc/<pid>` is gone.
---New-style `luadbg_<hex>` is stale when older than one hour.
---Uses bee.filesystem only (no shell); best-effort, never fails startup.
local function cleanup_stale_sockets()
    local ok, err = pcall(function()
        local fs = require('bee.filesystem')
        if platform_os() == 'windows' then
            return
        end
        local tmpdir = fs.path(fs.temp_directory_path():string():gsub('([/\\])$', ''))
        local now = os.time()
        for path in fs.pairs(tmpdir) do
            local name = path:filename():string()
            local pid = name:match('^luadbg_(%d+)$')
            if pid then
                -- Old style: PID gone => stale.
                if not fs.exists(fs.path('/proc') / pid) then
                    fs.remove(path)
                end
            else
                local hex = name:match('^luadbg_(%x+)$')
                if hex and #hex == 32 then
                    -- New style: older than 1h => stale.
                    local mtime = fs.last_write_time(path)
                    if mtime and (now - mtime) > 3600 then
                        fs.remove(path)
                    end
                end
            end
        end
    end)
    if not ok then
        -- Never `print()` here: stdout is the DAP channel in stdio mode,
        -- and unframed bytes corrupt the protocol stream. The log module
        -- (required above) already redirects stray prints to the log file.
        log.warn('stale socket cleanup failed: ' .. tostring(err))
    end
end

---Generate a cryptographically random hex string for socket names.
---@param nbytes integer Number of random bytes (hex length is 2x).
---@return string hex Hex-encoded random bytes.
local function random_hex(nbytes)
    local f = io.open('/dev/urandom', 'rb')
    if f then
        local bytes = f:read(nbytes)
        f:close()
        if bytes and #bytes == nbytes then
            return (bytes:gsub('.', function(c)
                return ('%02x'):format(c:byte())
            end))
        end
    end
    -- Fallback: pid + time + math.random (not cryptographic, but better
    -- than fully predictable). /dev/urandom should always exist on Linux.
    local parts = {}
    for _ = 1, nbytes do
        parts[#parts + 1] = ('%02x'):format(math.random(0, 255))
    end
    return table.concat(parts)
end

---Generate an unpredictable rendezvous socket address for launch.
---The frontend creates the name and passes it to the backend via spawn
---params, so both sides agree without the name being predictable.
---Prevents a local attacker from pre-binding the socket to harvest
---launch configuration secrets.
---@return string address Randomized unix-socket rendezvous address.
local function getRandomUnixAddress()
    return ('@$tmp/luadbg_%s'):format(random_hex(16))
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
    -- A launch without a program (and without a runtimeExecutable to run
    -- instead) would silently start a dead session; fail fast with a
    -- diagnostic instead.
    if
        args.request == 'launch'
        and args.runtimeExecutable == nil
        and type(args.program) ~= 'string'
    then
        return nil, 'missing `program` for launch.'
    end
    -- Strip dynamic-linker env vars that allow arbitrary code to run in
    -- the debuggee before the Lua bootstrap (and before the debugger
    -- attaches). A malicious workspace launch.json could set LD_PRELOAD
    -- to a hostile .so; its constructor would run at exec time, invisible
    -- to the debug session. These are stripped, not rejected: legitimate
    -- uses are rare, and a loud log line beats a silent session break.
    if type(args.env) == 'table' then
        for _, key in ipairs({
            'LD_PRELOAD',
            'LD_LIBRARY_PATH',
            'DYLD_INSERT_LIBRARIES',
            'DYLD_LIBRARY_PATH',
        }) do
            if args.env[key] ~= nil then
                -- Diagnostics go to the log file (stderr-safe), never to
                -- stdout: in stdio mode stdout carries only DAP frames.
                log.warn(('stripped `%s` from launch env: dynamic-linker injection blocked'):format(key))
                args.env[key] = nil
            end
        end
    end
    -- An empty program, or an absolute path that does not exist, is a
    -- certain launch failure; the backend would otherwise report success
    -- and wedge. (Relative paths are resolved against the debuggee cwd at
    -- spawn time, so they cannot be checked here.)
    if args.request == 'launch' and type(args.program) == 'string' then
        if args.program == '' then
            return nil, '`program` is empty.'
        end
        if args.program:sub(1, 1) == '/' then
            local f = io.open(args.program, 'r')
            if f then
                f:close()
            else
                return nil, ('`program` does not exist: %s'):format(args.program)
            end
        end
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
    -- Opt-in child-process auto-attach: the backend wraps os.execute /
    -- io.popen in the debuggee and fires `startDebugging` reverse requests
    -- for Lua children. Must be an explicit boolean; anything else is a
    -- config typo, not a silent opt-in.
    if args.autoAttachChildProcesses ~= nil and type(args.autoAttachChildProcesses) ~= 'boolean' then
        return nil, ('invalid `autoAttachChildProcesses`: expected a boolean, got %s'):format(
            type(args.autoAttachChildProcesses)
        )
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
---@param args table runInTerminal arguments for the client.
---@param launch_pkg table The original DAP launch request to answer on failure.
local function request_runinterminal(args, launch_pkg)
    reverse_seq = reverse_seq + 1
    -- Remember the launch request so a terminal failure (or timeout) can
    -- answer it instead of leaving the client hanging forever.
    pending_terminal[reverse_seq] = {
        pkg = launch_pkg,
        sent_at = os.time(),
    }
    client.sendmsg({
        type = 'request',
        seq = reverse_seq,
        command = 'runInTerminal',
        arguments = args,
    })
end

-- Seconds before an unanswered runInTerminal is treated as failed.
local TERMINAL_TIMEOUT = 30

---Ask the editor to open a debug session for a debuggee-spawned Lua
-- child (see backend/worker/childwatch.lua). The child already runs its
-- own backend listening on `spawn.address`, so the new session attaches
-- to it; nothing is spawned here. Best-effort: editors that do not honor
-- the `startDebugging` reverse request leave the child running under its
-- own backend with no session attached.
---@param spawn table {address=string, command=string, threadId=integer}.
local function request_start_debugging(spawn)
    reverse_seq = reverse_seq + 1
    client.sendmsg({
        type = 'request',
        seq = reverse_seq,
        command = 'startDebugging',
        arguments = {
            request = 'attach',
            configuration = {
                request = 'attach',
                -- The debug-type id is client-specific (whatever the user
                -- registered this adapter as); 'lua' is the conventional
                -- default and clients remap as needed.
                type = 'lua',
                name = ('(child) %s'):format(spawn.command),
                address = spawn.address,
                client = true,
            },
        },
    })
end

---Answer timed-out runInTerminal requests with a launch error and tear down.
local function reap_terminal_timeouts()
    local now = os.time()
    for seq, pending in pairs(pending_terminal) do
        if now - pending.sent_at >= TERMINAL_TIMEOUT then
            pending_terminal[seq] = nil
            response_error(pending.pkg, '`runInTerminal` timed out: client did not respond within 30s.')
            if server then
                server.closeall()
                server = nil
            end
            os.exit(0, true)
        end
    end
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
        -- Randomized name prevents a local attacker from pre-binding the
        -- predictable socket to harvest launch secrets. The frontend
        -- generates the full address and passes it to the backend via
        -- spawn params (role 's:' = backend listens, frontend connects).
        -- (Attach still uses getUnixAddress(pid); it requires the injector
        -- to already have code execution in the target.)
        local sock_addr = getRandomUnixAddress()
        s = socket('connect:' .. sock_addr)
        address = 's:' .. sock_addr
    end
    return s, address
end

---@param pkg table DAP launch request.
---@return boolean? started True when the terminal launch was requested.
local function proxy_launch_terminal(pkg)
    local args = pkg.arguments
    -- The client must support runInTerminal; without the capability the
    -- reverse request goes nowhere and the launch hangs forever.
    if not (initReq and initReq.arguments and initReq.arguments.supportsRunInTerminalRequest) then
        response_error(pkg, 'Client does not support `runInTerminal`.')
        return
    end
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
        request_runinterminal(arguments, pkg)
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
        request_runinterminal(arguments, pkg)
        return true
    end
end

---@param pkg table DAP launch request.
---@return boolean? started True when the console launch was requested.
local function proxy_launch_console(pkg)
    local args = pkg.arguments
    if args.runtimeExecutable then
        -- Diver (and other clients) may supply `runtimeExecutable` (an
        -- external Lua interpreter) without `inject` or `address`, meaning
        -- "run the program with this interpreter under the debugger".
        -- Route it through the normal bootstrap path by treating the
        -- runtime as the Lua executable; the debuggee connects back via
        -- the socket rendezvous. Without this, a nil `inject` falls into
        -- the injection path and fails with "Inject (use nil) is not
        -- supported."
        if args.inject == nil and args.address == nil then
            args.luaexe = args.runtimeExecutable
            args.runtimeExecutable = nil
        elseif args.inject == 'none' and args.address == nil then
            response_error(pkg, '`runtimeExecutable` need specify `inject` or `address`.')
            return
        end
    end
    if args.runtimeExecutable then
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
        debuggee = process
    else
        local address
        server, address = create_server(args)
        local process, err = debuger_factory.create_luaexe_in_console(args, WORKDIR, address)
        if not process then
            response_error(pkg, err)
            return
        end
        debuggee = process
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
    -- New session: the previous session's `terminated`/`disconnect` state
    -- must not leak into this one, or a fresh debuggee's normal end would
    -- be swallowed.
    terminated_forwarded = false
    disconnect_acked = false
    disconnect_terminate = args.request ~= 'attach'
    if args.request == 'attach' then
        proxy_attach(pkg)
    elseif args.request == 'launch' then
        proxy_launch(pkg)
    end
end

---@param pkg table DAP message traveling editor -> backend.
local function send(pkg)
    if server then
        if pkg.type == 'request' and pkg.command == 'disconnect' then
            -- Remember whether this disconnect terminates: the acked
            -- early exit below is detach-only. An explicit
            -- `terminateDebuggee: false` detaches; anything else (true
            -- or absent) terminates, and the frontend must wait for the
            -- backend's close so the drain's `terminated` is forwarded.
            local td = pkg.arguments and pkg.arguments.terminateDebuggee
            if td ~= nil then
                disconnect_terminate = td
            end
        end
        if pkg.type == 'response' and pkg.command == 'runInTerminal' then
            local seq = pkg.request_seq

            local pending = pending_terminal[seq]
            if pending then
                pending_terminal[seq] = nil

                if not pkg.success then
                    -- The client could not start the terminal: the backend
                    -- is waiting for a debuggee that will never connect.
                    -- Answer the launch request (the client has been
                    -- hanging on it), then tear down instead of spinning.
                    response_error(pending.pkg, '`runInTerminal` failed: client reported success:false.')
                    if server then
                        server.closeall()
                        server = nil
                    end
                    os.exit(0, true)
                end
            end

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
            -- The backend is gone. Drain any final messages it managed to
            -- send (like `terminated`) before the FIN, forwarding each to
            -- the client so nothing is lost in the close race.
            while true do
                local pkg = server.recvmsg()
                if not pkg then
                    break
                end
                if pkg.type == 'event' and pkg.event == 'terminated' then
                    forward_terminated_once(pkg)
                else
                    pcall(client.sendmsg, pkg)
                end
            end
            -- If the backend died without a `terminated` event, synthesize
            -- one: the DAP client must see the session end, otherwise it
            -- hangs waiting for a debuggee that will never report back.
            if not terminated_forwarded then
                reverse_seq = reverse_seq + 1
                forward_terminated_once({
                    type = 'event',
                    seq = reverse_seq,
                    event = 'terminated',
                })
            end
            -- Reap the debuggee (if the frontend spawned one) before the
            -- process goes away, so a finished child never becomes a zombie.
            reap_debuggee()
            os.exit(0, true)
        end)
        while true do
            local pkg = server.recvmsg()
            if pkg then
                if
                    pkg.type == 'response'
                    and pkg.command == 'disconnect'
                    and pkg.success
                then
                    disconnect_acked = true
                end
                -- Backend-internal child-spawn notification: turn it into
                -- a `startDebugging` reverse request instead of forwarding
                -- an unknown event to the editor.
                if pkg.type == 'event' and pkg.event == 'moonwalkChildSpawned' then
                    if type(pkg.body) == 'table' and type(pkg.body.address) == 'string' then
                        request_start_debugging(pkg.body)
                    end
                elseif pkg.type == 'event' and pkg.event == 'terminated' then
                    -- Single choke point: a duplicate backend `terminated`
                    -- is dropped here instead of reaching the client twice.
                    forward_terminated_once(pkg)
                else
                    client.sendmsg(pkg)
                end
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
    reap_terminal_timeouts()

    -- Detach case: the debug session is over but the backend (and the
    -- detached debuggee) live on. The frontend must exit now; the debuggee
    -- is disowned (not killed, not reaped) so init reparents and reaps it.
    -- Without this, every `terminateDebuggee: false` disconnect leaks the
    -- full adapter stack. A terminating disconnect skips this: the backend
    -- drains and closes on its own, and `event_close` above forwards the
    -- final messages (including `terminated`) before exiting.
    if disconnect_acked and not disconnect_terminate then
        debuggee = nil
        if server then
            server.closeall()
            server = nil
        end
        os.exit(0, true)
    end
end

---@param io table DAP transport (socket or stdio module).
function m.init(io)
    client = io
    cleanup_stale_sockets()
end

--- Shut down cleanly: close the backend connection (if any) and reap a
--- spawned debuggee so it never becomes a zombie. Called when the client
--- transport reports EOF (the DAP client went away without `disconnect`).
--- Does not exit the process; the caller decides.
function m.shutdown()
    if server then
        server.closeall()
        server = nil
    end
    reap_debuggee()
end

return m
