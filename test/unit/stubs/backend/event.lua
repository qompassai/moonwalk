-- test/unit/stubs/backend/event.lua
local ev = {}
ev.__handlers = {}
function ev.on(name, fn)
    ev.__handlers[name] = ev.__handlers[name] or {}
    ev.__handlers[name][#ev.__handlers[name] + 1] = fn
end
function ev.emit(name, ...)
    for _, fn in ipairs(ev.__handlers[name] or {}) do
        fn(...)
    end
end
return ev
