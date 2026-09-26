-- launch.lua
--
-- Debuggee-side bootstrap: runs as `lua -e 'dofile[[...]] DBG[[...]]'` inside
-- the target process. Loads debugger.lua, then waits for the `DBG` rendezvous
-- argument, which carries the backend address (or a pid for the unix-socket
-- form), an optional `ansi` marker, and the Lua version tag.

local src = debug.getinfo(1, 'S').source:sub(2)
local path = src:match('(.+)[/\\][%w_.-]+$'):match('(.+)[/\\][%w_.-]+$')

---@param filename string Absolute path of debugger.lua to load and run.
local function dofile(filename)
    local load = _VERSION == 'Lua 5.1' and loadstring or load
    local f = assert(io.open(filename))
    local str = f:read('*a')
    f:close()
    return assert(load(str, '=(debugger.lua)'))(filename)
end
local dbg = dofile(path .. '/script/debugger.lua')

---@param str string Rendezvous argument: address/pid, optional ansi, lua version.
dbg:set_wait('DBG', function(str)
    local params = {}
    str:gsub('[^/]+', function(w)
        params[#params + 1] = w
    end)

    local cfg
    if not params[1]:match('^%d+$') then
        local client, address = params[1]:match('^([sc]):(.*)$')
        cfg = { address = address, client = (client == 'c') }
    else
        local pid = params[1]
        cfg = { address = ('@$tmp/luadbg_%s'):format(pid) }
    end
    if params[2] == 'ansi' then
        cfg.ansi = true
        if params[3] then
            cfg.luaVersion = params[3]
        end
    else
        if params[2] then
            cfg.luaVersion = params[2]
        end
    end
    dbg:start(cfg)
end)
