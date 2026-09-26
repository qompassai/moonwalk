-- backend/bootstrap.lua
--
-- Entry point for the debugger backend. The backend has two roles: a single
-- master thread that speaks DAP to the editor, and one worker thread per
-- debugged Lua state. `start` boots both for a fresh session; `attach` joins
-- an already-running master when the debuggee shows up late.

local thread = require('bee.thread')
local channel = require('bee.channel')

local m = {}

local function hasMaster()
    return channel.query('DbgMaster') ~= nil
end

local function initMaster(rootpath, address)
    if hasMaster() then
        return
    end
    -- The create call only registers the channel name so late workers can
    -- attach; the handle itself is owned by the spawned master thread.
    channel.create('DbgMaster')
    thread.create(([[
        local rootpath = %q
        package.path = rootpath.."/script/?.lua"
        local log = require "common.log"
        log.file = rootpath.."/master.log"
        local ok, err = xpcall(function()
            local socket = require "common.socket"(%q)
            local master = require "backend.master.mgr"
            master.init(socket)
            master.update()
        end, debug.traceback)
        if not ok then
            log.error("ERROR:" .. err)
        end
    ]]):format(rootpath, address))
end

local function startWorker(rootpath)
    local log = require('common.log')
    log.file = rootpath .. '/worker.log'
    require('backend.worker')
end

---@param rootpath string Absolute path of the extension script root.
---@param address string Address the master socket listens on.
function m.start(rootpath, address)
    initMaster(rootpath, address)
    startWorker(rootpath)
end

---@param rootpath string Absolute path of the extension script root.
function m.attach(rootpath)
    if hasMaster() then
        startWorker(rootpath)
    end
end

return m
