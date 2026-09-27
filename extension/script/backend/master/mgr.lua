-- backend/master/mgr.lua
--
-- Master-side thread and client bookkeeping: owns the DAP client connection,
-- the worker-thread registry, and the broadcast fan-out used to push events
-- (output, breakpoints, stop notifications) to every worker thread.

local ev = require('backend.event')
local thread = require('bee.thread')
local stdio = require('luadebug.stdio')
local channel = require('bee.channel')

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
    threadChannel[w] = nil
    for WorkerIdent, threadId in pairs(threadCatalog) do
        if threadId == w then
            threadCatalog[WorkerIdent] = nil
        end
    end
    threadStatus[w] = nil
    threadName[w] = nil
    if not mgr.keepSessionAlive and next(threadChannel) == nil then
        quit = true
    end
end

local function update_redirect()
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
    local threadCMD = require('backend.master.threads')
    while true do
        local ok, w, cmd, msg = masterThread:pop()
        if not ok then
            break
        end
        if threadCMD[cmd] then
            threadCMD[cmd](threadCatalog[w] or w, msg)
        end
    end
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
    local event = require('backend.master.event')
    event.terminated()
    -- Flush before close: output events queued behind `terminated` must
    -- reach the frontend, otherwise final program output is silently lost
    -- in the termination race.
    mgr.flushClient()
    socket.closeall()
    channel.destroy('DbgMaster')
end

function mgr.setClient(c)
    client = c
end

function mgr.getClient()
    return client
end

return mgr
