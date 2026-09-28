-- test/unit/stubs/backend/master/event.lua
local event = {}
event.__fired = {}
function event.initialized()
    event.__fired[#event.__fired + 1] = 'initialized'
end
function event.capabilities()
    event.__fired[#event.__fired + 1] = 'capabilities'
end
function event.terminated()
    event.__fired[#event.__fired + 1] = 'terminated'
end
function event.continued(body)
    event.__fired[#event.__fired + 1] = 'continued'
end
return event
