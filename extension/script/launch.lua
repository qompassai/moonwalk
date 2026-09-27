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

-- Maximum DBG marker segments: at most `ansi` and one lua-version tag
-- follow the address.
local DBG_MARKER_COUNT_MAX = 2

---Check whether a DBG remainder still looks like an address
---(`<role>:<endpoint>` or a bare pid). Guards the tail parsing below
---against addresses that legitimately end in an `ansi`- or
---`lua-...`-looking path segment.
---@param s string Candidate address remainder.
---@return boolean ok True when the remainder is a plausible address.
local function looks_like_address(s)
    return s:match('^[sc]:.+') ~= nil or s:match('^%d+$') ~= nil
end

---Split a DBG rendezvous argument into address, ansi flag, and lua version.
---
---Wire format: `<address>[/ansi][/lua-<version>]`. The address itself may
---contain `/` (unix socket paths like `@$tmp/luadbg_<hex>`), so the old
---split-on-`/` parse corrupted it. Parsing starts at the tail instead: at
---most two trailing segments are the `ansi` / version markers, and
---everything before them is the address. A marker is only consumed when
---the remainder still looks like an address.
---@param str string Raw DBG argument from the launch bootstrap.
---@return string address Rendezvous address (role-prefixed) or legacy pid.
---@return boolean ansi True when the `ansi` marker was present.
---@return string|nil luaVersion Lua version tag, when present.
local function parse_dbg(str)
    assert(type(str) == 'string')
    local address, ansi, luaVersion = str, false, nil
    for _ = 1, DBG_MARKER_COUNT_MAX do
        local tail = address:match('/([^/]+)$')
        if tail == nil then
            break
        end
        local rest = address:sub(1, -(#tail + 2))
        if not looks_like_address(rest) then
            break
        end
        if tail == 'ansi' then
            ansi = true
            address = rest
        elseif tail:match('^lua%-[%w.]+$') then
            luaVersion = tail
            address = rest
        else
            break
        end
    end
    return address, ansi, luaVersion
end

---@param str string Rendezvous argument: address/pid, optional ansi, lua version.
dbg:set_wait('DBG', function(str)
    local address, ansi, luaVersion = parse_dbg(str)
    -- Stash the rendezvous address where the worker can see it (same Lua
    -- state): a child spawned with auto-attach derives its claim-token
    -- path from it (see backend/worker/childwatch.lua), so the parent
    -- session's cleanup can tell "attached" from "orphaned".
    debug.getregistry()['moonwalk.dbg_address'] = address
    local cfg
    if address:match('^%d+$') then
        -- Legacy pid form: the bootstrap rebuilds the rendezvous name.
        cfg = { address = ('@$tmp/luadbg_%s'):format(address) }
    else
        local client, endpoint = address:match('^([sc]):(.*)$')
        assert(client ~= nil and endpoint ~= nil and endpoint ~= '')
        cfg = { address = endpoint, client = (client == 'c') }
    end
    if ansi then
        cfg.ansi = true
    end
    -- Assigning nil removes the key, so this is a no-op when absent.
    cfg.luaVersion = luaVersion
    dbg:start(cfg)
end)
