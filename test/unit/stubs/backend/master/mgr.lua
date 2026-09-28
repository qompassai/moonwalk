-- test/unit/stubs/backend/master/mgr.lua
--
-- Minimal stub of backend.master.mgr for request-handler unit tests.
-- Records every client/worker message instead of sending it; the test
-- file drives thread membership via `mgr.__threads`.

local mgr = {}

mgr.__threads = { [1] = true }
mgr.__client = {}
mgr.__worker = {}
mgr.__broadcast = {}
mgr.__terminate_cb = nil
mgr.__terminated = false
local seq = 0

function mgr.hasThread(threadId)
    return mgr.__threads[threadId] == true
end

function mgr.threads()
    local out = {}
    for id, _ in pairs(mgr.__threads) do
        out[#out + 1] = { id = id, name = 'thread ' .. id }
    end
    return out
end

function mgr.newSeq()
    seq = seq + 1
    return seq
end

function mgr.clientSend(msg)
    mgr.__client[#mgr.__client + 1] = msg
end

function mgr.workerSend(w, msg)
    mgr.__worker[#mgr.__worker + 1] = { thread = w, msg = msg }
end

function mgr.workerBroadcast(msg)
    mgr.__broadcast[#mgr.__broadcast + 1] = msg
end

function mgr.workerBroadcastExclude(exclude, msg)
    mgr.__broadcast[#mgr.__broadcast + 1] = { exclude = exclude, msg = msg }
end

function mgr.workers()
    local out = {}
    for id, _ in pairs(mgr.__threads) do
        out[id] = true
    end
    return out
end

function mgr.setClient(args)
    mgr.__setClient = args
end

function mgr.setKeepSessionAlive(v)
    mgr.__keepAlive = v
end

function mgr.flushClient() end

function mgr.setTerminateDebuggeeCallback(cb)
    mgr.__terminate_cb = cb
end

function mgr.terminate_drain_and_exit()
    mgr.__terminated = true
end

function mgr.initConfig(config)
    mgr.__initConfig = config
end

-- Test helpers ----------------------------------------------------------

function mgr.__reset()
    mgr.__threads = { [1] = true }
    mgr.__client = {}
    mgr.__worker = {}
    mgr.__broadcast = {}
    mgr.__terminate_cb = nil
    mgr.__terminated = false
    seq = 0
end

function mgr.__responses()
    return mgr.__client
end

function mgr.__last_response()
    return mgr.__client[#mgr.__client]
end

return mgr
