# Porting Guide

If you plan to use your own Lua build rather than the one supplied by the debugger, keep the following points in mind.

## Coroutine Support

If you need to debug code inside coroutines, your Lua build must be able to emit the `THREAD` debug event. For implementation details, refer to the Lua build included with the debugger (search for `THREAD`).

Alternatively, you can emit this event yourself from Lua without modifying Lua itself. For example:

```lua
local rdebug = require "luadebug"

local rawcoroutineresume = coroutine.resume
local rawcoroutinewrap   = coroutine.wrap
local rawcoroutineclose  = coroutine.close

local function coreturn(co, ...)
    rdebug.event("thread", co, 1)
    return ...
end

local function cocall(co, f, ...)
    -- TODO: Handle errors thrown by f.
    rdebug.event("thread", co, 0)
    return coreturn(co, f(...))
end

function coroutine.resume(co, ...)
    return cocall(co, rawcoroutineresume, co, ...)
end

function coroutine.wrap(f)
    -- TODO: coroutine.wrap may internally call coroutine.close;
    -- it cannot be hooked here.
    local wf = rawcoroutinewrap(f)
    local _, co = debug.getupvalue(wf, 1)
    return function(...)
        return cocall(co, wf, ...)
    end
end

function coroutine.close(co)
    return cocall(co, rawcoroutineclose, co)
end
```

## Error Support

If you need to catch errors thrown by Lua, your Lua build must be able to emit the `EXCEPTION` debug event. For implementation details, refer to the Lua build included with the debugger (search for `EXCEPTION`).

Alternatively, you can emit this event yourself from Lua without modifying Lua itself. For example:

```lua
local rdebug = require "luadebug"

local rawxpcall = xpcall

function pcall(f, ...)
    return rawxpcall(f,
        function(msg)
            rdebug.event("exception", msg, 2 --[[LUA_ERRRUN]])
            return msg
        end,
    ...)
end

function xpcall(f, msgh, ...)
    return rawxpcall(f,
        function(msg)
            rdebug.event("exception", msg, 22 --[[LUA_ERRRUN]])
            return msgh and msgh(msg) or msg
        end,
    ...)
end
```

## Recompile `luadebug` With Your Lua Build

`luadebug` references Lua's non-public `lstate.h` header. If you have modified it in your Lua build, you will need to recompile `luadebug`.

## `update` Optimization

By default, the debugger installs a count hook when there are no breakpoints so it has an opportunity to respond to GUI requests, such as adding a new breakpoint or pausing execution. However, this also affects runtime efficiency when the debugger has no breakpoints.

You can disable this behavior and have Lua emit `update` events at an appropriate interval instead. This reduces the debugger's performance impact to a minimum - almost negligible.

The `update` event affects only the responsiveness of GUI operations during debugging, generally new breakpoints and pause requests. An interval of no more than 0.2 seconds is usually sufficient.

To disable the default behavior, use the `autoUpdate` event.
