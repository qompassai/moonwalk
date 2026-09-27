-- backend/master/mgr.lua
--
-- Master-side thread and client bookkeeping: owns the DAP client connection,
-- the worker-thread registry, and the broadcast fan-out used to push events
-- (output, breakpoints, stop notifications) to every worker thread.

local ev = require('backend.event')
local thread = require('bee.thread')
local stdio = require('luadebug.stdio')
local channel = require('bee.channel')
local log = require('common.log')

local redirect = {}
local mgr = {}
local socket
local seq = 0
local initialized = false
local masterThread
local client = {}
local maxThreadId = 0
local threadChannel = {}
local threadCatalog = {}
local threadStatus = {}
local threadName = {}
local terminateDebuggeeCallback
local quit = false

-- Forward declaration: defined further below, but mgr.exitWorker (above it
-- in the file) needs it for the last-worker drain. Without this the name
-- would resolve to a nil global inside exitWorker.
local update_redirect

-- True once `terminated` has been emitted for this session. The exit
-- handshake in mgr.exitWorker emits it before releasing the worker; the
-- update-loop tail emits it on every other shutdown path. The guard keeps
-- the two from doubling it.
local terminated_sent = false

local function sendTerminatedOnce()
    if terminated_sent then
        return
    end
    terminated_sent = true
    require('backend.master.event').terminated()
end

mgr.keepSessionAlive = false

function mgr.setKeepSessionAlive(enabled)
    mgr.keepSessionAlive = not not enabled
end

local function genThreadId()
    maxThreadId = maxThreadId + 1
    return maxThreadId
end

local function event_close()
    if not initialized then
        return
    end
    mgr.workerBroadcast({
        cmd = 'terminated',
    })
    ev.emit('close')
    initialized = false
    seq = 0
    terminated_sent = false
end

function mgr.newSeq()
    seq = seq + 1
    return seq
end

function mgr.init(io)
    socket = io
    --socket.debug(true)
    masterThread = assert(channel.query('DbgMaster'))
    socket.event_close(event_close)
    -- Child-process auto-attach: the master owns the spawn-log poll
    -- (see backend/master/childwatch.lua); per-session state is reset
    -- here, before any worker can announce a log.
    require('backend.master.childwatch').init()
    return true
end

local function lst2map(t)
    local r = {}
    for _, v in ipairs(t) do
        r[v] = true
    end
    return r
end

function mgr.initConfig(config)
    if redirect.stdout then
        redirect.stdout:close()
        redirect.stdout = nil
    end
    if redirect.stderr then
        redirect.stderr:close()
        redirect.stderr = nil
    end
    local outputCapture = lst2map(config.initialize.outputCapture)
    if outputCapture.stdout then
        redirect.stdout = stdio.redirect('stdout')
    end
    if outputCapture.stderr then
        redirect.stderr = stdio.redirect('stderr')
    end
end

function mgr.clientSend(pkg)
    if not initialized then
        return
    end
    socket.sendmsg(pkg)
end

---Pump the client socket once to flush buffered sends. Call before os.exit()
---when a response must reach the client: the send is buffered, and exiting
---without pumping discards it.
function mgr.flushClient()
    if not initialized then
        return
    end
    -- Multiple pumps: the first moves the message to the OS buffer, the
    -- second ensures it is handed off. Cheap and bounded.
    socket.update(0)
    socket.update(0)
end

function mgr.workerSend(w, msg)
    return threadChannel[w]:push(msg)
end

function mgr.workerBroadcast(msg)
    for _, chan in pairs(threadChannel) do
        chan:push(msg)
    end
end

function mgr.workerBroadcastExclude(exclude, msg)
    for w, chan in pairs(threadChannel) do
        if w ~= exclude then
            chan:push(msg)
        end
    end
end

function mgr.setThreadName(w, name)
    threadName[w] = name
end

function mgr.workers()
    return threadChannel
end

function mgr.threads()
    local t = {}
    for threadId, status in pairs(threadStatus) do
        if status == 'connect' then
            t[#t + 1] = {
                name = (threadName[threadId] or 'Thread (${id})'):gsub('%$%{([^}]*)%}', {
                    id = threadId,
                }),
                id = threadId,
            }
        end
    end
    table.sort(t, function(a, b)
        return a.name < b.name
    end)
    return t
end

function mgr.hasThread(w)
    return threadChannel[w] ~= nil
end

function mgr.initWorker(WorkerIdent)
    local workerChannel = ('DbgWorker(%s)'):format(WorkerIdent)
    local threadId = genThreadId()
    threadChannel[threadId] = assert(channel.query(workerChannel))
    threadCatalog[WorkerIdent] = threadId
    threadStatus[threadId] = 'disconnect'
    threadName[threadId] = nil
    ev.emit('worker-ready', threadId)
end

function mgr.setThreadStatus(threadId, status)
    threadStatus[threadId] = status
    if terminateDebuggeeCallback and status == 'disconnect' then
        for _, s in pairs(threadStatus) do
            if s == 'connect' then
                return
            end
        end
        terminateDebuggeeCallback()
    end
end

-- Timestamp (os.clock) when terminate was requested, or nil. If workers
-- are stopped at breakpoints they never process the disconnect broadcast,
-- so the terminate callback never fires. This bounds the wait: after
-- TERMINATE_TIMEOUT seconds, the master forces shutdown.
local terminate_requested_at = nil
local TERMINATE_TIMEOUT = 5.0

function mgr.setTerminateDebuggeeCallback(callback)
    for _, s in pairs(threadStatus) do
        if s == 'connect' then
            terminateDebuggeeCallback = callback
            terminate_requested_at = os.clock()
            return
        end
    end
    callback()
end

---Check if a pending terminate has timed out. Called from the main loop.
---@return boolean timed_out True if terminate was requested and timed out.
function mgr.checkTerminateTimeout()
    if terminate_requested_at and terminateDebuggeeCallback then
        if os.clock() - terminate_requested_at > TERMINATE_TIMEOUT then
            return true
        end
    end
    return false
end

function mgr.exitWorker(w)
    local workerChannel = threadChannel[w]
    threadChannel[w] = nil
    for WorkerIdent, threadId in pairs(threadCatalog) do
        if threadId == w then
            threadCatalog[WorkerIdent] = nil
        end
    end
    threadStatus[w] = nil
    threadName[w] = nil
    local last = next(threadChannel) == nil
    if last then
        -- Last worker: drain the fd-level output redirect too, so raw
        -- writes made just before exit are not lost either.
        update_redirect()
    end
    -- The exiting worker is blocked in event.exit waiting for `exitAck`.
    -- Everything it queued ahead of `exitWorker` was popped (FIFO) and
    -- forwarded, so flush the socket first: the ack then truly means the
    -- frontend has everything, and process exit can no longer lose
    -- trailing events in the termination race.
    mgr.flushClient()
    if workerChannel then
        workerChannel:push({ cmd = 'exitAck' })
    end
    if last and not mgr.keepSessionAlive then
        sendTerminatedOnce()
        mgr.flushClient()
        quit = true
    end
end

function update_redirect()
    if redirect.stderr then
        local res = redirect.stderr:read(redirect.stderr:peek())
        if res then
            local event = require('backend.master.event')
            event.output({
                category = 'stderr',
                output = res,
            })
        end
    end
    if redirect.stdout then
        local res = redirect.stdout:read(redirect.stdout:peek())
        if res then
            local event = require('backend.master.event')
            event.output({
                category = 'stdout',
                output = res,
            })
        end
    end
end

-- Pop and dispatch pending worker->master messages. Shared by the main
-- update loop and the terminating-disconnect drain: both must forward
-- in-flight worker traffic (output events especially) before the process
-- goes away. Each call dispatches at most WORKER_MESSAGE_BATCH_MAX, so a
-- flooding worker cannot starve the socket pump below; backlogs drain
-- across repeated calls.
local WORKER_MESSAGE_BATCH_MAX = 256

local function pump_worker_messages()
    local threadCMD = require('backend.master.threads')
    for _ = 1, WORKER_MESSAGE_BATCH_MAX do
        local ok, w, cmd, msg = masterThread:pop()
        if not ok then
            break
        end
        if threadCMD[cmd] then
            threadCMD[cmd](threadCatalog[w] or w, msg)
        end
    end
end

local function update_once()
    -- If terminate was requested but workers are stuck (stopped at
    -- breakpoints, never processing disconnect), force shutdown after
    -- the timeout instead of leaking the session.
    if mgr.checkTerminateTimeout() then
        terminate_requested_at = nil
        local cb = terminateDebuggeeCallback
        terminateDebuggeeCallback = nil
        if cb then
            cb()
        end
        quit = true
        return false
    end
    pump_worker_messages()
    -- Out-of-band child-spawn reports: the debuggee thread may be blocked
    -- inside os.execute, so these never travel the worker path. The master
    -- thread is the only context that stays live during the block.
    require('backend.master.childwatch').poll()
    update_redirect()
    socket.update(0)
    local req = socket.recvmsg()
    if not req then
        return true
    end
    if req.type == 'request' then
        -- TODO
        local request = require('backend.master.request')
        if not initialized then
            if req.command == 'initialize' then
                initialized = true
                request.initialize(req)
            else
                local response = require('backend.master.response')
                response.error(req, ('`%s` not yet implemented.(birth)'):format(req.command))
            end
        else
            local f = request[req.command]
            if f and req.command ~= 'initialize' then
                if f(req) then
                    return true
                end
            else
                local response = require('backend.master.response')
                response.error(req, ('`%s` not yet implemented.(idle)'):format(req.command))
            end
        end
    end
    return false
end

function mgr.update()
    while not quit do
        if update_once() then
            thread.sleep(10)
        end
    end
    -- Reap spawned Lua children nobody attached to: a child still waiting
    -- at its debugger wait gate can never proceed once this session is
    -- gone, so leaving it would orphan it forever. Claimed children
    -- (attached sessions) are owned elsewhere and are left alone.
    require('backend.master.childwatch').cleanup()
    -- The exit handshake may already have emitted `terminated` (and
    -- flushed it) before releasing the last worker; every other shutdown
    -- path lands here with it still unsent.
    sendTerminatedOnce()
    -- Flush before close: output events queued behind `terminated` must
    -- reach the frontend, otherwise final program output is silently lost
    -- in the termination race.
    mgr.flushClient()
    socket.closeall()
    channel.destroy('DbgMaster')
end

-- Bound for the terminating-disconnect drain: the master keeps pumping
-- worker traffic until every worker completes the exitWorker/exitAck
-- handshake or the bound expires. Poll-counted, not os.clock: os.clock
-- measures CPU time and barely advances across thread.sleep. Matches the
-- worker's EXIT_DRAIN bound so a worker wedged in native code delays
-- disconnect by at most ~5s before the process exits anyway.
local TERMINATE_DRAIN_POLL_MAX = 500
local TERMINATE_DRAIN_POLL_MS = 10

---Run the bounded exit drain for a terminating disconnect, then exit the
---process. Reuses the natural-exit handshake: each worker pushes
---`exitWorker` and waits for `exitAck`; mgr.exitWorker drains the fd
---redirect, flushes the socket, acks, and emits `terminated`. A worker
---wedged in native code never answers, so the bound expires and the
---process exits anyway (logged). Never returns.
function mgr.terminate_drain_and_exit()
    -- A stale terminate callback (e.g. from request.terminate) must not
    -- fire mid-drain and os.exit() ahead of the handshake.
    terminateDebuggeeCallback = nil
    terminate_requested_at = nil
    local polls = 0
    while next(threadChannel) ~= nil and polls < TERMINATE_DRAIN_POLL_MAX do
        pump_worker_messages()
        -- Drain fd-level output written just before the kill, then push
        -- everything buffered toward the frontend.
        update_redirect()
        socket.update(0)
        polls = polls + 1
        thread.sleep(TERMINATE_DRAIN_POLL_MS)
    end
    if next(threadChannel) ~= nil then
        log.warn(
            'disconnect: exit-drain bound expired with workers still '
                .. 'attached; exiting anyway'
        )
    else
        log.info('disconnect: exit drain complete; exiting')
    end
    -- Deterministic terminal ordering even on expiry: push any last
    -- worker messages and fd output, emit `terminated` exactly once
    -- (guarded; the natural handshake path may have sent it already),
    -- and flush before the process goes away.
    pump_worker_messages()
    update_redirect()
    sendTerminatedOnce()
    mgr.flushClient()
    os.exit(true, true)
end

function mgr.setClient(c)
    client = c
end

function mgr.getClient()
    return client
end

return mgr
