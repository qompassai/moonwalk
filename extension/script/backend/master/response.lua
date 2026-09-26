-- backend/master/response.lua
--
-- Constructors for the DAP responses the master thread sends to the editor.
-- Every table key here is wire protocol ('type', 'command', 'request_seq',
-- 'success', ...): never rename them, only the human-language strings
-- inside may change.

local mgr = require('backend.master.mgr')

local response = {}

---@param req table The incoming DAP request being answered.
---@param msg string Human-readable failure reason.
function response.error(req, msg)
    mgr.clientSend({
        type = 'response',
        seq = mgr.newSeq(),
        command = req.command,
        request_seq = req.seq,
        success = false,
        message = msg,
    })
end

---@param req table The incoming DAP request being answered.
---@param body table? DAP response body.
function response.success(req, body)
    mgr.clientSend({
        type = 'response',
        seq = mgr.newSeq(),
        command = req.command,
        request_seq = req.seq,
        success = true,
        body = body,
    })
end

---@param req table The incoming DAP `initialize` request.
function response.initialize(req)
    if req.__norepl then
        mgr.newSeq()
        return
    end
    mgr.clientSend({
        type = 'response',
        seq = mgr.newSeq(),
        command = req.command,
        request_seq = req.seq,
        success = true,
        body = require('common.capabilities'),
    })
end

---@param req table The incoming DAP `threads` request.
---@param threads table List of `{ id = integer, name = string }`.
function response.threads(req, threads)
    mgr.clientSend({
        type = 'response',
        seq = mgr.newSeq(),
        command = req.command,
        request_seq = req.seq,
        success = true,
        body = {
            threads = threads,
        },
    })
end

return response
