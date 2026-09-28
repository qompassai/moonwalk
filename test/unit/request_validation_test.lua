-- test/unit/request_validation_test.lua
--
-- Request-argument validation tests against the REAL
-- `backend/master/request.lua`, with the transport-adjacent modules
-- stubbed (test/unit/stubs/): every malformed request must produce exactly
-- one unsuccessful DAP response and leave the adapter usable, never a Lua
-- error. Covers the MW-REQ oracles without needing a built adapter.
--
-- Returns an array of `{ id, kind, fn }` for test/unit/run_unit.lua.

local script_dir = (debug.getinfo(1, 'S').source:match('^@(.*/)') or './')
-- Stubs win over the real tree for backend modules; the real request.lua
-- and response.lua are exercised.
package.path = script_dir .. 'stubs/?.lua;' .. package.path

local mgr = require('backend.master.mgr')
local request = require('backend.master.request')

local function fresh()
    mgr.__reset()
    package.loaded['backend.master.request'] = nil
    -- NOTE: request.lua keeps module-local `state`/`config`; reloading per
    -- test is unnecessary because none of these tests depend on prior
    -- state, and `state` starts at 'none' in every fresh process run.
    return require('backend.master.request')
end

local function req(command, seq, arguments)
    return { type = 'request', seq = seq, command = command, arguments = arguments }
end

local function last_response()
    local r = mgr.__last_response()
    assert(r ~= nil, 'expected a response to have been sent')
    return r
end

local function expect_unsuccessful(ctx, command)
    local r = last_response()
    ctx:check(r.type == 'response', 'response has DAP type')
    ctx:check(r.command == command, 'response correlates to the request command')
    ctx:check(r.success == false, 'response is unsuccessful')
    ctx:check(type(r.message) == 'string' and #r.message > 0, 'diagnostic message present')
end

local function expect_success(ctx, command)
    local r = last_response()
    ctx:check(r.type == 'response', 'response has DAP type')
    ctx:check(r.command == command, 'response correlates to the request command')
    ctx:check(r.success == true, 'response is successful')
end

local tests = {}

local function T(id, kind, fn)
    tests[#tests + 1] = { id = id, kind = kind, fn = fn }
end

-- ---------------------------------------------------------------------------
-- Validation: well-formed requests keep working exactly as before.
-- ---------------------------------------------------------------------------

T('MW-REQ-V01 setBreakpoints valid request succeeds', 'validation', function(ctx)
    local request = fresh()
    request.setBreakpoints(req('setBreakpoints', 1, {
        source = { path = '/tmp/a.lua' },
        breakpoints = { { line = 10 }, { line = 20 } },
    }))
    expect_success(ctx, 'setBreakpoints')
    local body = last_response().body
    ctx:check(#body.breakpoints == 2, 'both breakpoints echoed')
    ctx:check(body.breakpoints[1].id ~= nil, 'breakpoint id assigned')
    ctx:check(body.breakpoints[1].verified == false, 'breakpoint marked unverified')
end)

T('MW-REQ-V02 setBreakpoints empty list clears (success)', 'validation', function(ctx)
    local request = fresh()
    request.setBreakpoints(req('setBreakpoints', 2, {
        source = { path = '/tmp/a.lua' },
        breakpoints = {},
    }))
    expect_success(ctx, 'setBreakpoints')
    ctx:check(#last_response().body.breakpoints == 0, 'empty list echoed back')
end)

T('MW-REQ-V03 setBreakpoints without breakpoints key defaults to clear', 'validation', function(ctx)
    local request = fresh()
    request.setBreakpoints(req('setBreakpoints', 3, {
        source = { path = '/tmp/a.lua' },
    }))
    expect_success(ctx, 'setBreakpoints')
    ctx:check(#last_response().body.breakpoints == 0, 'absent breakpoints treated as empty')
end)

T('MW-REQ-V04 setBreakpoints tolerates unknown extra fields', 'validation', function(ctx)
    local request = fresh()
    request.setBreakpoints(req('setBreakpoints', 4, {
        source = { path = '/tmp/a.lua', name = 'a.lua' },
        breakpoints = { { line = 1 } },
        sourceModified = false,
        futureField = { nested = true },
    }))
    expect_success(ctx, 'setBreakpoints')
end)

T('MW-REQ-V05 variables with a valid reference is forwarded', 'validation', function(ctx)
    local request = fresh()
    local ref = (1 << 24) | 7 -- thread 1, value 7
    request.variables(req('variables', 5, { variablesReference = ref }))
    -- No immediate response: the worker answers asynchronously, echoing
    -- the request seq. The master must only forward.
    ctx:check(#mgr.__responses() == 0, 'no premature response; the worker answers later')
    ctx:check(#mgr.__worker == 1, 'one worker message sent')
    ctx:check(mgr.__worker[1].thread == 1, 'routed to the right thread')
    ctx:check(mgr.__worker[1].msg.cmd == 'variables', 'worker command is variables')
    ctx:check(mgr.__worker[1].msg.valueId == 7, 'value id extracted')
    ctx:check(mgr.__worker[1].msg.seq == 5, 'request seq echoed for correlation')
end)

T('MW-REQ-V06 restart with nested arguments succeeds', 'validation', function(ctx)
    local request = fresh()
    request.restart(req('restart', 6, { arguments = { program = '/tmp/a.lua' } }))
    expect_success(ctx, 'restart')
    ctx:check(#mgr.__broadcast == 1, 'workers told to disconnect')
    ctx:check(mgr.__terminate_cb ~= nil, 'restart callback registered')
end)

T('MW-REQ-V07 restart with no arguments takes the default path', 'validation', function(ctx)
    local request = fresh()
    request.restart(req('restart', 7, nil))
    expect_success(ctx, 'restart')
    ctx:check(mgr.__terminate_cb ~= nil, 'restart callback registered without arguments')
end)

T('MW-REQ-V08 terminateThreads with valid ids succeeds', 'validation', function(ctx)
    local request = fresh()
    request.terminateThreads(req('terminateThreads', 8, { threadIds = { 1 } }))
    expect_success(ctx, 'terminateThreads')
    ctx:check(#mgr.__worker == 1, 'disconnect sent to the thread')
    ctx:check(mgr.__worker[1].msg.cmd == 'disconnect', 'worker command is disconnect')
end)

T('MW-REQ-V09 readMemory with a valid reference is forwarded', 'validation', function(ctx)
    local request = fresh()
    request.readMemory(req('readMemory', 9, {
        memoryReference = 'memory_1x7',
        offset = 0,
        count = 16,
    }))
    -- No immediate response: the worker answers asynchronously.
    ctx:check(#mgr.__responses() == 0, 'no premature response; the worker answers later')
    ctx:check(#mgr.__worker == 1, 'one worker message sent')
    ctx:check(mgr.__worker[1].msg.memoryReference == 7, 'reference id extracted')
    ctx:check(mgr.__worker[1].msg.count == 16, 'count passed through')
    ctx:check(mgr.__worker[1].msg.seq == 9, 'request seq echoed for correlation')
end)

-- ---------------------------------------------------------------------------
-- Adversarial: malformed requests get one unsuccessful response, no crash,
-- and the adapter keeps answering afterwards.
-- ---------------------------------------------------------------------------

T('MW-REQ-A01 setBreakpoints without arguments, adapter survives', 'adversarial', function(ctx)
    local request = fresh()
    local ok, err = pcall(request.setBreakpoints, req('setBreakpoints', 1, nil))
    ctx:check(ok, 'no Lua error raised: ' .. tostring(err))
    expect_unsuccessful(ctx, 'setBreakpoints')
    -- The same adapter process answers the next valid request.
    local ok2, err2 = pcall(request.threads, req('threads', 2, nil))
    ctx:check(ok2, 'adapter still dispatches: ' .. tostring(err2))
    expect_success(ctx, 'threads')
end)

T('MW-REQ-A02 setBreakpoints with non-table source', 'adversarial', function(ctx)
    local request = fresh()
    for _, source in ipairs({ 'path.lua', 42, true }) do
        local ok, err = pcall(request.setBreakpoints, req('setBreakpoints', 1, {
            source = source,
            breakpoints = {},
        }))
        ctx:check(ok, 'no Lua error for source=' .. tostring(source) .. ': ' .. tostring(err))
        expect_unsuccessful(ctx, 'setBreakpoints')
    end
end)

T('MW-REQ-A03 setBreakpoints with bad breakpoints/source identity', 'adversarial', function(ctx)
    local request = fresh()
    local bads = {
        { source = { path = '/tmp/a.lua' }, breakpoints = 'line 10' },
        { source = { path = '/tmp/a.lua' }, breakpoints = { 'line 10' } },
        { source = {}, breakpoints = {} },
        { source = { path = 42 }, breakpoints = {} },
    }
    for i, arguments in ipairs(bads) do
        local ok, err = pcall(request.setBreakpoints, req('setBreakpoints', i, arguments))
        ctx:check(ok, ('no Lua error on bad case %d: %s'):format(i, tostring(err)))
        expect_unsuccessful(ctx, 'setBreakpoints')
    end
end)

T('MW-REQ-A04 variables with invalid references', 'adversarial', function(ctx)
    local request = fresh()
    -- Explicit count loop: ipairs would stop at the leading nil.
    local bads = { '1x7', 1.5, true, {}, 0x1FFFFFFFF }
    do
        local ok, err = pcall(request.variables, req('variables', 0, nil))
        ctx:check(ok, 'no Lua error on absent arguments: ' .. tostring(err))
        expect_unsuccessful(ctx, 'variables')
    end
    for i = 1, #bads do
        local ref = bads[i]
        local ok, err = pcall(request.variables, req('variables', i, { variablesReference = ref }))
        ctx:check(ok, ('no Lua error on bad reference %d: %s'):format(i, tostring(err)))
        expect_unsuccessful(ctx, 'variables')
    end
    -- Unknown-but-well-typed thread: deterministic error, no crash.
    local ok, err = pcall(request.variables, req('variables', 99, { variablesReference = (999 << 24) | 1 }))
    ctx:check(ok, 'no Lua error on unknown thread: ' .. tostring(err))
    expect_unsuccessful(ctx, 'variables')
end)

T('MW-REQ-A05 restart with non-table arguments takes the safe default', 'adversarial', function(ctx)
    local request = fresh()
    local ok, err = pcall(request.restart, req('restart', 1, 'oops'))
    ctx:check(ok, 'no Lua error: ' .. tostring(err))
    expect_success(ctx, 'restart')
    ctx:check(mgr.__terminate_cb ~= nil, 'restart still armed with default config')
end)

T('MW-REQ-A06 terminateThreads with bad threadIds', 'adversarial', function(ctx)
    local request = fresh()
    -- Explicit count loop: ipairs would stop at the leading nil.
    local bads = { '1', 42, {}, { 1, 'two' }, { 999 } }
    do
        local ok, err = pcall(request.terminateThreads, req('terminateThreads', 0, nil))
        ctx:check(ok, 'no Lua error on absent arguments: ' .. tostring(err))
        ctx:check(last_response().success == false, 'absent arguments rejected')
    end
    for i = 1, #bads do
        local threadIds = bads[i]
        local ok, err = pcall(request.terminateThreads, req('terminateThreads', i, { threadIds = threadIds }))
        ctx:check(ok, ('no Lua error on bad threadIds %d: %s'):format(i, tostring(err)))
        local r = last_response()
        if type(threadIds) == 'table' and #threadIds == 0 then
            ctx:check(r.success == true, 'empty threadIds array succeeds')
        else
            ctx:check(r.success == false, ('bad threadIds %d rejected'):format(i))
        end
    end
    -- In particular the unknown thread id must not index a nil channel.
    ctx:check(#mgr.__worker == 0, 'no worker message sent for rejected ids')
end)

T('MW-REQ-A07 readMemory with bad memoryReference', 'adversarial', function(ctx)
    local request = fresh()
    -- Explicit count loop: ipairs would stop at the leading nil.
    local bads = { 42, true, {}, 'memory_ax7', 'bogus', '' }
    do
        local ok, err = pcall(request.readMemory, req('readMemory', 0, nil))
        ctx:check(ok, 'no Lua error on absent arguments: ' .. tostring(err))
        expect_unsuccessful(ctx, 'readMemory')
    end
    for i = 1, #bads do
        local ref = bads[i]
        local ok, err = pcall(request.readMemory, req('readMemory', i, { memoryReference = ref }))
        ctx:check(ok, ('no Lua error on bad reference %d: %s'):format(i, tostring(err)))
        expect_unsuccessful(ctx, 'readMemory')
    end
    ctx:check(#mgr.__worker == 0, 'nothing forwarded for rejected references')
end)

T('MW-REQ-A08 exactly one response per malformed request', 'adversarial', function(ctx)
    local request = fresh()
    local malformed = {
        { 'setBreakpoints', { source = 'x' } },
        { 'variables', { variablesReference = 'x' } },
        { 'terminateThreads', { threadIds = 'x' } },
        { 'readMemory', { memoryReference = 1 } },
    }
    for i, case in ipairs(malformed) do
        mgr.__reset()
        local ok, err = pcall(request[case[1]], req(case[1], i, case[2]))
        ctx:check(ok, ('no Lua error for %s: %s'):format(case[1], tostring(err)))
        ctx:check(#mgr.__responses() == 1, ('exactly one response for %s'):format(case[1]))
        local r = last_response()
        ctx:check(r.request_seq == i, 'response correlates to the request seq')
    end
end)

T('MW-REQ-A09 writeMemory with a malformed reference', 'adversarial', function(ctx)
    local request = fresh()
    local bad = {
        { memoryReference = 'memory_nope' }, -- wrong shape
        { memoryReference = 'memory_99x1' }, -- unknown thread
        { memoryReference = 7 }, -- not a string at all
    }
    for i, args in ipairs(bad) do
        local ok, err = pcall(request.writeMemory, req('writeMemory', 200 + i, args))
        ctx:check(ok, ('no exception on writeMemory case %d: %s'):format(i, tostring(err)))
        local r = last_response()
        ctx:check(r ~= nil and r.success == false, ('writeMemory case %d answered unsuccessful'):format(i))
    end
    ctx:check(#mgr.__worker == 0, 'nothing forwarded to any worker')
end)

T('MW-REQ-A10 disassemble with a malformed reference', 'adversarial', function(ctx)
    local request = fresh()
    local bad = {
        { memoryReference = 'inst_nope' }, -- wrong shape
        { memoryReference = 'inst_99xABC' }, -- unknown thread
        { memoryReference = 123 }, -- not a string at all
    }
    for i, args in ipairs(bad) do
        local ok, err = pcall(request.disassemble, req('disassemble', 300 + i, args))
        ctx:check(ok, ('no exception on disassemble case %d: %s'):format(i, tostring(err)))
        local r = last_response()
        ctx:check(r ~= nil and r.success == false, ('disassemble case %d answered unsuccessful'):format(i))
    end
    ctx:check(#mgr.__worker == 0, 'nothing forwarded to any worker')
end)

return tests
