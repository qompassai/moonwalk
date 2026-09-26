-- backend/master/event.lua
--
-- Constructors for the DAP events the master thread sends to the editor.
-- Every table key here is wire protocol ('type', 'event', 'body', ...): never
-- rename them, only the human-language strings inside may change.

local mgr = require('backend.master.mgr')
local event = {}

function event.initialized()
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'initialized',
    })
end

function event.capabilities()
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'capabilities',
        body = {
            capabilities = require('common.capabilities'),
        },
    })
end

---@param body table DAP event body.
function event.stopped(body)
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'stopped',
        body = body,
    })
end

---@param body table DAP event body.
function event.breakpoint(body)
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'breakpoint',
        body = body,
    })
end

---@param body table DAP event body.
function event.output(body)
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'output',
        body = body,
    })
end

function event.terminated()
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'terminated',
        body = {
            restart = false,
        },
    })
end

---@param body table DAP event body.
function event.loadedSource(body)
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'loadedSource',
        body = body,
    })
end

---@param body table DAP event body.
function event.thread(body)
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'thread',
        body = body,
    })
end

---@param body table DAP event body.
function event.invalidated(body)
    if not mgr.getClient().supportsInvalidatedEvent then
        return
    end
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'invalidated',
        body = body,
    })
end

---@param body table DAP event body.
function event.continued(body)
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'continued',
        body = body,
    })
end

---@param body table DAP event body.
function event.memory(body)
    mgr.clientSend({
        type = 'event',
        seq = mgr.newSeq(),
        event = 'memory',
        body = body,
    })
end

return event
