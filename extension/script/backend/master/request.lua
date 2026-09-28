-- backend/master/request.lua
--
-- DAP request handlers for the master side: launch/attach, breakpoints,
-- threads, stack frames, and disassembly. Each handler translates the
-- editor's request into worker-thread commands via mgr and shapes the
-- response with the DAP wire keys the client expects.

local mgr = require('backend.master.mgr')
local response = require('backend.master.response')
local event = require('backend.master.event')
local ev = require('backend.event')
local utility = require('luadebug.utility')
local resolve_config = require('backend.master.resolve_config')
local childwatch = require('backend.master.childwatch')

local request = {}

local firstWorker = true
local state = 'none'
local config = {
    initialize = {},
    breakpoints = {},
    function_breakpoints = {},
    exception_breakpoints = {},
    instruction_breakpoints = {},
}

ev.on('close', function()
    state = 'none'
    event.terminated()
end)

local function checkThreadId(req, threadId)
    if type(threadId) ~= 'number' then
        response.error(req, 'No threadId')
        return
    end
    if not mgr.hasThread(threadId) then
        response.error(req, 'Not found thread [' .. threadId .. ']')
        return
    end
    return true
end

--- Returns `req.arguments` when it is a table; otherwise answers the
--- request with exactly one unsuccessful DAP response and returns nil.
--- Handlers must call this before dereferencing any argument: a malformed
--- request must never raise a Lua error inside the adapter.
---@param req table Incoming DAP request.
---@return table|nil args Validated arguments table.
local function checkArguments(req)
    if type(req.arguments) ~= 'table' then
        response.error(req, 'Missing or invalid `arguments`')
        return nil
    end
    return req.arguments
end

function request.initialize(req)
    firstWorker = true
    mgr.setClient(req.arguments)
    response.initialize(req)
    event.initialized()
    event.capabilities()
end

function request.attach(req)
    local ok, err = resolve_config(req.arguments)

    if not ok then
        response.error(req, err)

        return
    end

    response.success(req)
    state = 'initializing'
    mgr.setKeepSessionAlive(req.arguments.keepSessionAlive)
    config = {
        initialize = req.arguments,
        breakpoints = {},
        function_breakpoints = {},
        exception_breakpoints = {},
        instruction_breakpoints = {},
    }
end

function request.launch(req)
    request.attach(req)
    config.launch = true
end

local function tryStop(w)
    if firstWorker then
        if not not config.initialize.stopOnEntry then
            mgr.workerSend(w, {
                cmd = 'stop',
                reason = 'entry',
            })
            return
        end
    end
    if not not config.initialize.stopOnThreadEntry then
        mgr.workerSend(w, {
            cmd = 'stop',
            reason = 'entry',
        })
    end
end

local function initializeWorkerBreakpoints(w, source, breakpoints, content)
    mgr.workerSend(w, {
        cmd = 'setBreakpoints',
        source = source,
        breakpoints = breakpoints,
        content = content,
    })
end

local function jsonvalue(v)
    local json = require('common.json')
    if json.null == v then
        return
    end
    return v
end

local function initializeWorker(w)
    mgr.workerSend(w, {
        cmd = 'initializing',
        config = config.initialize,
    })
    for key, bp in pairs(config.breakpoints) do
        if type(key) == 'string' or (key >> 32) == w then
            initializeWorkerBreakpoints(w, bp[1], bp[2], bp[3])
        end
    end
    mgr.workerSend(w, {
        cmd = 'setFunctionBreakpoints',
        breakpoints = config.function_breakpoints,
    })
    mgr.workerSend(w, {
        cmd = 'setExceptionBreakpoints',
        arguments = config.exception_breakpoints,
    })
    mgr.workerSend(w, {
        cmd = 'setInstructionBreakpoints',
        breakpoints = config.instruction_breakpoints,
    })
    if firstWorker and config.launch then
        mgr.workerSend(w, {
            cmd = 'setSearchPath',
            path = jsonvalue(config.initialize.path),
            cpath = jsonvalue(config.initialize.cpath),
        })
    end
    tryStop(w)
    mgr.workerSend(w, {
        cmd = 'initialized',
    })
    firstWorker = false
end

ev.on('worker-ready', function(w)
    if state == 'initialized' then
        initializeWorker(w)
    end
end)

function request.configurationDone(req)
    response.success(req)
    state = 'initialized'
    for w in pairs(mgr.workers()) do
        initializeWorker(w)
    end
    mgr.initConfig(config)
end

local breakpointID = 0
local function genBreakpointID()
    breakpointID = breakpointID + 1
    return breakpointID
end

local function skipBOM(s)
    if not s then
        return
    end
    if s:sub(1, 3) == '\xEF\xBB\xBF' then
        s = s:sub(4)
    end
    if s:sub(1, 1) == '#' then
        local pos = s:find('\n', 2)
        if pos then
            s = s:sub(pos + 1)
        end
    end
    return s
end

local function isValidPath(path)
    local prefix = path:match('^(%a+):')
    return not (prefix and #prefix > 1)
end

function request.setBreakpoints(req)
    local args = checkArguments(req)
    if not args then
        return
    end
    if type(args.source) ~= 'table' then
        response.error(req, 'Missing or invalid `source`')
        return
    end
    if type(args.source.path) ~= 'string' and type(args.source.sourceReference) ~= 'number' then
        response.error(req, 'Missing source `path` or `sourceReference`')
        return
    end
    -- `breakpoints` is optional per DAP: absent means "clear all".
    local breakpoints = args.breakpoints
    if breakpoints == nil then
        breakpoints = {}
    elseif type(breakpoints) ~= 'table' then
        response.error(req, 'Invalid `breakpoints`: expected an array')
        return
    end
    local invalidPath = type(args.source.path) == 'string' and not isValidPath(args.source.path)
    -- Validate the reference arithmetic inputs before answering: the
    -- request must produce exactly one response, success or error.
    if args.source.sourceReference and (type(args.source.sourceReference) ~= 'number' or math.type(args.source.sourceReference) ~= 'integer') then
        response.error(req, 'Invalid `sourceReference`: expected an integer')
        return
    end
    for _, bp in ipairs(breakpoints) do
        if type(bp) ~= 'table' then
            response.error(req, 'Invalid `breakpoints`: expected an array of objects')
            return
        end
        bp.column = nil
        bp.endColumn = nil
        bp.id = genBreakpointID()
        bp.verified = false
        bp.message = invalidPath and ('Does not support path: `%s`'):format(args.source.path)
            or 'Wait verify. (The source file is not loaded.)'
    end
    response.success(req, {
        breakpoints = breakpoints,
    })
    if invalidPath then
        return
    end
    local content = skipBOM(args.sourceContent)
    if args.source.sourceReference then
        local sourceReference = args.source.sourceReference
        local w = sourceReference >> 32
        args.source.sourceReference = args.source.sourceReference & 0xFFFFFFFF
        config.breakpoints[sourceReference] = {
            args.source,
            breakpoints,
            content,
        }
        if state == 'initialized' then
            initializeWorkerBreakpoints(w, args.source, breakpoints, content)
        end
    else
        --TODO: should path matching ignore case?
        config.breakpoints[args.source.path] = {
            args.source,
            breakpoints,
            content,
        }
        if state == 'initialized' then
            for w in pairs(mgr.workers()) do
                initializeWorkerBreakpoints(w, args.source, breakpoints, content)
            end
        end
    end
end

function request.setFunctionBreakpoints(req)
    local args = req.arguments
    for _, bp in ipairs(args.breakpoints) do
        bp.id = genBreakpointID()
        bp.verified = false
        bp.message = 'Wait verify.'
    end
    response.success(req, {
        breakpoints = args.breakpoints,
    })
    config.function_breakpoints = args.breakpoints
    if state == 'initialized' then
        mgr.workerBroadcast({
            cmd = 'setFunctionBreakpoints',
            breakpoints = args.breakpoints,
        })
    end
end

function request.setInstructionBreakpoints(req)
    local args = req.arguments
    for _, bp in ipairs(args.breakpoints) do
        bp.id = genBreakpointID()
        bp.verified = false
        bp.message = 'Wait verify.'
    end
    response.success(req, { breakpoints = args.breakpoints })
    config.instruction_breakpoints = {}
    for _, bp in ipairs(args.breakpoints) do
        local ref = bp.instructionReference
        if type(ref) == 'string' then
            local threadId, rest = ref:match('^inst_(%d+)x(.+)$')
            threadId = tonumber(threadId)
            if threadId and rest then
                bp.instructionReference = rest
                config.instruction_breakpoints[#config.instruction_breakpoints + 1] = bp
            end
        end
    end
    if state == 'initialized' then
        for w in pairs(mgr.workers()) do
            mgr.workerSend(w, {
                cmd = 'setInstructionBreakpoints',
                breakpoints = config.instruction_breakpoints,
            })
        end
    end
end

function request.setExceptionBreakpoints(req)
    local args = req.arguments
    local breakpoints = {}
    local filter = {}
    local function addExceptionBreakpoint(opt)
        local id = genBreakpointID()
        breakpoints[#breakpoints + 1] = {
            id = id,
            verified = false,
            message = 'Wait verify.',
        }
        filter[#filter + 1] = {
            id = id,
            filterId = opt.filterId,
            condition = opt.condition,
        }
    end
    for _, filterId in ipairs(args.filters) do
        addExceptionBreakpoint({
            filterId = filterId,
        })
    end
    if args.filterOptions then
        for _, opt in ipairs(args.filterOptions) do
            addExceptionBreakpoint(opt)
        end
    end
    response.success(req, {
        breakpoints = breakpoints,
    })
    config.exception_breakpoints = filter
    if state == 'initialized' then
        mgr.workerBroadcast({
            cmd = 'setExceptionBreakpoints',
            arguments = filter,
        })
    end
end

function request.stackTrace(req)
    local args = req.arguments
    local threadId = args.threadId
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'stackTrace',
        command = req.command,
        seq = req.seq,
        startFrame = args.startFrame,
        levels = args.levels,
    })
end

function request.scopes(req)
    local args = req.arguments
    if type(args.frameId) ~= 'number' then
        response.error(req, 'No frameId')
        return
    end

    local threadId = args.frameId >> 24
    local frameId = args.frameId & 0x00FFFFFF
    if not checkThreadId(req, threadId) then
        return
    end

    mgr.workerSend(threadId, {
        cmd = 'scopes',
        command = req.command,
        seq = req.seq,
        frameId = frameId,
    })
end

function request.variables(req)
    local args = checkArguments(req)
    if not args then
        return
    end
    local variablesReference = args.variablesReference
    if type(variablesReference) ~= 'number' or math.type(variablesReference) ~= 'integer' then
        response.error(req, 'Invalid `variablesReference`: expected an integer')
        return
    end
    local threadId = variablesReference >> 24
    local valueId = variablesReference & 0x00FFFFFF
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'variables',
        command = req.command,
        seq = req.seq,
        valueId = valueId,
        filter = args.filter,
        start = args.start,
        count = args.count,
    })
end

function request.evaluate(req)
    local args = req.arguments
    if type(args.frameId) ~= 'number' then
        response.error(req, 'Please pause to evaluate expressions')
        return
    end
    if type(args.expression) ~= 'string' then
        response.error(req, 'Error expression')
        return
    end
    local threadId = args.frameId >> 24
    local frameId = args.frameId & 0x00FFFFFF
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'evaluate',
        command = req.command,
        seq = req.seq,
        frameId = frameId,
        context = args.context,
        expression = args.expression,
    })
end

function request.threads(req)
    response.threads(req, mgr.threads())
end

function request.disconnect(req)
    response.success(req)
    local args = req.arguments
    if args.terminateDebuggee == nil then
        args.terminateDebuggee = not not config.launch
    end
    if args.terminateDebuggee and not args.suspendDebuggee then
        -- Terminating kill: route workers through the same bounded
        -- exitWorker/exitAck drain handshake natural exit uses, so
        -- in-flight output events reach the frontend before the process
        -- dies. A plain `disconnect` detaches the workers instead.
        mgr.workerBroadcast({
            cmd = 'disconnect',
            terminate = true,
        })
    else
        mgr.workerBroadcast({
            cmd = 'disconnect',
        })
    end
    if args.suspendDebuggee then
        mgr.workerBroadcast({
            cmd = 'suspend',
        })
    elseif args.terminateDebuggee then
        -- Flush the success response before exiting: the socket send is
        -- buffered, and os.exit() would discard it, leaving the client
        -- hanging on a disconnect that will never be answered.
        mgr.flushClient()
        -- Reap unattached children BEFORE os.exit: exiting here bypasses
        -- mgr.update()'s end-of-loop cleanup, which would orphan a child
        -- stuck at its debugger wait gate.
        childwatch.cleanup()
        -- Bounded drain, then exit: pumps worker traffic until every
        -- worker completes the exit handshake (fd redirect drained,
        -- socket flushed, `terminated` emitted) instead of os.exit()ing
        -- over in-flight events. A wedged debuggee only costs the drain
        -- bound; the process exits anyway.
        mgr.terminate_drain_and_exit()
    end
    return true
end

function request.terminate(req)
    response.success(req)
    if utility.closewindow() then
        return
    end
    --TODO:
    --  The debugger activation masks SIGINT, which prevents closeprocess
    --  from working, so disconnect the debugger before calling closeprocess.
    --  Ideally the debugger and SIGINT would stop conflicting.
    --
    mgr.workerBroadcast({
        cmd = 'disconnect',
    })
    -- The terminate callback kills this process, bypassing mgr.update()'s
    -- end-of-loop cleanup: reap unattached children up front.
    childwatch.cleanup()
    mgr.setTerminateDebuggeeCallback(function()
        utility.closeprocess()
    end)
    return true
end

function request.restart(req)
    -- `restart` takes no required arguments: a missing `arguments` table
    -- (or a missing nested launch configuration) restarts with the current
    -- session configuration instead of crashing on a nil index.
    local args = req.arguments
    local launchArgs = type(args) == 'table' and args.arguments or nil
    response.success(req)
    mgr.workerBroadcast({
        cmd = 'disconnect',
    })
    mgr.setTerminateDebuggeeCallback(function()
        if launchArgs then
            config.initialize = launchArgs
        end
        -- The old session's unattached children can never proceed past
        -- their wait gate; reap them before the new session starts.
        childwatch.cleanup()
        for w in pairs(mgr.workers()) do
            initializeWorker(w)
        end
        mgr.initConfig(config)
    end)
end

function request.terminateThreads(req)
    local args = checkArguments(req)
    if not args then
        return
    end
    if type(args.threadIds) ~= 'table' then
        response.error(req, 'Invalid `threadIds`: expected an array')
        return
    end
    -- Validate every id before touching the worker channels: an unknown
    -- thread id would index a nil channel and kill the adapter.
    for _, threadId in ipairs(args.threadIds) do
        if not checkThreadId(req, threadId) then
            return
        end
    end
    response.success(req)
    for _, w in ipairs(args.threadIds) do
        mgr.workerSend(w, {
            cmd = 'disconnect',
        })
    end
end

function request.pause(req)
    local args = req.arguments
    local threadId = args.threadId
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'stop',
        reason = 'pause',
    })
    response.success(req)
end

function request.continue(req)
    mgr.workerBroadcast({
        cmd = 'run',
    })
    response.success(req, {
        allThreadsContinued = true,
    })
end

function request.next(req)
    local args = req.arguments
    local threadId = args.threadId
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'stepOver',
    })
    mgr.workerBroadcastExclude(threadId, {
        cmd = 'run',
    })
    event.continued({
        allThreadsContinued = true,
    })
    response.success(req)
end

function request.stepOut(req)
    local args = req.arguments
    local threadId = args.threadId
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'stepOut',
    })
    mgr.workerBroadcastExclude(threadId, {
        cmd = 'run',
    })
    event.continued({
        allThreadsContinued = true,
    })
    response.success(req)
end

function request.stepIn(req)
    local args = req.arguments
    local threadId = args.threadId
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'stepIn',
    })
    mgr.workerBroadcastExclude(threadId, {
        cmd = 'run',
    })
    event.continued({
        allThreadsContinued = true,
    })
    response.success(req)
end

function request.source(req)
    local args = req.arguments
    local threadId = args.sourceReference >> 32
    local sourceReference = args.sourceReference & 0xFFFFFFFF
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'source',
        command = req.command,
        seq = req.seq,
        sourceReference = sourceReference,
    })
end

function request.exceptionInfo(req)
    local args = req.arguments
    local threadId = args.threadId
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'exceptionInfo',
        command = req.command,
        seq = req.seq,
    })
end

function request.setVariable(req)
    local args = req.arguments
    local threadId = args.variablesReference >> 24
    local valueId = args.variablesReference & 0x00FFFFFF
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'setVariable',
        command = req.command,
        seq = req.seq,
        valueId = valueId,
        name = args.name,
        value = args.value,
    })
end

function request.setExpression(req)
    local args = req.arguments
    local threadId = args.frameId >> 24
    local frameId = args.frameId & 0x00FFFFFF
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'setExpression',
        command = req.command,
        seq = req.seq,
        frameId = frameId,
        expression = args.expression,
        value = args.value,
    })
end

function request.loadedSources(req)
    response.success(req, {
        sources = {},
    })
    mgr.workerBroadcast({
        cmd = 'loadedSources',
    })
end

function request.restartFrame(req)
    local args = req.arguments
    local threadId = args.frameId >> 24
    local frameId = args.frameId & 0x00FFFFFF
    if not checkThreadId(req, threadId) then
        return
    end
    response.success(req)
    mgr.workerSend(threadId, {
        cmd = 'restartFrame',
        frameId = frameId,
    })
end

function request.readMemory(req)
    local args = checkArguments(req)
    if not args then
        return
    end
    local memoryReference = args.memoryReference
    if type(memoryReference) ~= 'string' then
        response.error(req, 'Error memoryReference')
        return
    end
    local threadId, refId = memoryReference:match('memory_(%d+)x(%d+)')
    threadId = tonumber(threadId)
    refId = tonumber(refId)
    if not threadId or not refId then
        response.error(req, 'Error memoryReference')
        return
    end
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'readMemory',
        command = req.command,
        seq = req.seq,
        memoryReference = refId,
        offset = args.offset,
        count = args.count,
    })
end

function request.writeMemory(req)
    local args = checkArguments(req)
    if not args then
        return
    end
    local memoryReference = args.memoryReference
    if type(memoryReference) ~= 'string' then
        response.error(req, 'Error memoryReference')
        return
    end
    local threadId, refId = memoryReference:match('memory_(%d+)x(%d+)')
    threadId = tonumber(threadId)
    refId = tonumber(refId)
    if not threadId or not refId then
        response.error(req, 'Error memoryReference')
        return
    end
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'writeMemory',
        command = req.command,
        seq = req.seq,
        memoryReference = refId,
        offset = args.offset,
        data = args.data,
        allowPartial = args.allowPartial,
    })
end

function request.disassemble(req)
    local args = checkArguments(req)
    if not args then
        return
    end
    local memoryReference = args.memoryReference
    if type(memoryReference) ~= 'string' then
        response.error(req, 'Invalid memoryReference')
        return
    end
    -- inst_<threadId>x<rest> (from instructionPointerReference)
    local threadId, refId = memoryReference:match('inst_(%d+)x(.+)$')
    if not refId then
        -- memory_<threadId>x<refId> (from variable with memoryReference)
        threadId, refId = memoryReference:match('memory_(%d+)x(%d+)')
    end
    threadId = tonumber(threadId)
    if not threadId or not refId then
        response.error(req, 'Invalid memoryReference')
        return
    end
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'disassemble',
        command = req.command,
        seq = req.seq,
        refId = refId,
        offset = args.offset,
        instructionOffset = args.instructionOffset,
        instructionCount = args.instructionCount,
        resolveSymbols = args.resolveSymbols,
    })
end

function request.customRequestShowIntegerAsDec(req)
    response.success(req)
    mgr.workerBroadcast({
        cmd = 'customRequestShowIntegerAsDec',
    })
end

function request.customRequestShowIntegerAsHex(req)
    response.success(req)
    mgr.workerBroadcast({
        cmd = 'customRequestShowIntegerAsHex',
    })
end

-- Lowest-numbered live worker, for requests that are not addressed to a
-- specific thread (modules, breakpointLocations). Deterministic; in a
-- multi-debuggee session this reports the first debuggee -- documented,
-- not silent.
---@return integer? threadId
local function firstThreadId()
    local best
    for threadId in pairs(mgr.workers()) do
        if best == nil or threadId < best then
            best = threadId
        end
    end
    return best
end

function request.completions(req)
    local args = req.arguments or {}
    local threadId, frameId
    if type(args.frameId) == 'number' then
        threadId = args.frameId >> 24
        frameId = args.frameId & 0x00FFFFFF
    else
        threadId = firstThreadId()
        frameId = 0
    end
    if not checkThreadId(req, threadId) then
        return
    end
    if type(args.text) ~= 'string' then
        response.error(req, 'No completion text')
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'completions',
        command = req.command,
        seq = req.seq,
        frameId = frameId,
        text = args.text,
    })
end

function request.modules(req)
    local threadId = firstThreadId()
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'modules',
        command = req.command,
        seq = req.seq,
    })
end

function request.cancel(req)
    local args = req.arguments or {}
    -- DAP cancel carries requestId (the seq to abort) and/or progressId.
    -- Progress reporting is not implemented, so progressId is acknowledged
    -- and ignored.
    if type(args.requestId) == 'number' then
        mgr.workerBroadcast({
            cmd = 'cancel',
            requestId = args.requestId,
        })
    end
    response.success(req)
end

function request.dataBreakpointInfo(req)
    local args = req.arguments or {}
    if type(args.variablesReference) ~= 'number' then
        response.error(req, 'No variablesReference')
        return
    end
    if type(args.name) ~= 'string' then
        response.error(req, 'No variable name')
        return
    end
    local threadId = args.variablesReference >> 24
    local valueId = args.variablesReference & 0x00FFFFFF
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'dataBreakpointInfo',
        command = req.command,
        seq = req.seq,
        valueId = valueId,
        name = args.name,
    })
end

-- Hard cap: software watchpoints re-evaluate every expression on each
-- line event, so the list must stay small.
local DATA_BREAKPOINT_MAX = 16

function request.setDataBreakpoints(req)
    local args = req.arguments or {}
    -- `wire` goes to the workers (only dataId is honored); `answered` is
    -- the DAP Breakpoint list. Conditional data breakpoints fail
    -- verification loudly instead of arming a watch that ignores them.
    -- accessType `write` is accepted because a detected value change IS
    -- a write; `read` is rejected loudly because software polling
    -- cannot observe reads (a read never changes the watched value).
    local wire = {}
    local answered = {}
    if type(args.breakpoints) == 'table' then
        for i = 1, math.min(#args.breakpoints, DATA_BREAKPOINT_MAX) do
            local bp = args.breakpoints[i]
            if type(bp) == 'table' then
                local verified = type(bp.dataId) == 'string' and bp.dataId ~= ''
                local message
                if not verified then
                    message = 'Data breakpoint needs a dataId.'
                elseif bp.condition ~= nil or bp.hitCondition ~= nil then
                    verified = false
                    message = 'Conditional data breakpoints are not supported.'
                elseif bp.accessType ~= nil
                    and bp.accessType ~= 'readWrite'
                    and bp.accessType ~= 'write' then
                    verified = false
                    if bp.accessType == 'read' then
                        -- WHY: watchpoints are software polling. The worker
                        -- re-evaluates the expression on line events and
                        -- fires only when the rendered value CHANGES -- and
                        -- a change is inherently a write. A read never
                        -- alters the value, so polling cannot ever observe
                        -- one. Silently downgrading read->write would arm a
                        -- watch that fires on behavior the user did not ask
                        -- to trap, so read fails loudly and stays failed.
                        message = 'accessType `read` is not supported: '
                            .. 'software watchpoints poll for value changes '
                            .. 'and cannot observe reads.'
                    else
                        message = ('accessType `%s` is not supported.'):format(
                            tostring(bp.accessType)
                        )
                    end
                end
                if verified then
                    wire[#wire + 1] = { dataId = bp.dataId }
                end
                answered[#answered + 1] = {
                    verified = verified,
                    message = message,
                }
            end
        end
    end
    response.success(req, {
        breakpoints = answered,
    })
    mgr.workerBroadcast({
        cmd = 'setDataBreakpoints',
        breakpoints = wire,
    })
end

function request.stepInTargets(req)
    local args = req.arguments or {}
    if type(args.frameId) ~= 'number' then
        response.error(req, 'No frameId')
        return
    end
    local threadId = args.frameId >> 24
    local frameId = args.frameId & 0x00FFFFFF
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'stepInTargets',
        command = req.command,
        seq = req.seq,
        frameId = frameId,
    })
end

function request.breakpointLocations(req)
    local args = req.arguments or {}
    if type(args.source) ~= 'table' then
        response.error(req, 'No source')
        return
    end
    if type(args.line) ~= 'number' then
        response.error(req, 'No line')
        return
    end
    local threadId = firstThreadId()
    if not checkThreadId(req, threadId) then
        return
    end
    mgr.workerSend(threadId, {
        cmd = 'breakpointLocations',
        command = req.command,
        seq = req.seq,
        source = args.source,
        line = args.line,
        endLine = args.endLine,
    })
end

--function print(...v)
--    local t = {}
--    for i = 1, #v do
--        t[i] = tostring(v[i])
--    end
--    event.output {
--        category = 'stdout',
--        output = table.concat(t, '\t')..'\n',
--    }
--end

return request
