-- backend/worker/childwatch.lua
--
-- Opt-in child-process auto-attach (see `autoAttachChildProcesses` in the
-- launch config). When enabled, the worker installs wrappers for
-- `os.execute` / `io.popen` in the debuggee (see childwatch_install.lua).
-- Commands that look like Lua interpreters get Moonwalk's launch bootstrap
-- prepended, so the child starts its own backend on a private address.
--
-- Spawn reporting is file-based, not poll-based (2026-09-27 redesign):
-- the debuggee-side wrapper appends each spawn to
-- `<tmp>/luadbg_<seed>_spawns` before the blocking call, and the MASTER
-- thread polls that file on every tick (see backend/master/childwatch.lua).
-- A file is the only out-of-band path: the install chunk runs in the
-- debuggee's pristine Lua state (via rdebug.eval), where `bee` is
-- unavailable -- an earlier bee.channel design failed exactly here, the
-- chunk's `require('bee.channel')` finding nothing. The worker used to
-- poll a `__moonwalk_child_spawns` debuggee global from its update hook,
-- but that could never fire while the debuggee was blocked inside
-- os.execute: worker code runs on the debuggee's own thread, driven by
-- debug hooks, and no hooks fire inside os.execute's C call. The master
-- thread is the only execution context that stays live during the block,
-- but it runs a separate Lua state and cannot read the debuggee's
-- globals -- so there is nothing for it to poll. The record must be
-- written out-of-band before the blocking call; that is what the install
-- chunk does. The worker announces the log path to the master over the
-- existing worker->master channel; the master never guesses it.
--
-- Only Lua children launched through those two APIs are seen. A child
-- whose backend nobody attaches to waits at its debugger wait gate until
-- the parent session ends, which reaps it (see the master module).

local rdebug = require('luadebug.visitor')
local log = require('common.log')

-- The install chunk runs in the debuggee; load its source the same way
-- backend/worker/eval.lua loads its chunks (package.readfile or fallback).
local readfile = package.readfile
if not readfile then
    function readfile(filename)
        local fullpath = assert(package.searchpath(filename, package.path))
        local f = assert(io.open(fullpath))
        local str = f:read('a')
        f:close()
        return str
    end
end
local install_src = readfile('backend.worker.childwatch_install')

local m = {}

local installed = false
---Per-worker random seed for child socket names. WorkerIdent (the thread
---id) is not unique across adapter processes, so a random seed is used;
---the `_c<n>` suffix keeps these names out of the stale-socket sweeps.
---Also embedded in each child's command line so session-end cleanup can
---prove a PID is really ours before signaling it.
local addr_seed = nil

local install_chunk = nil

---@return string hex 16 random bytes as hex, for socket name seeds.
local function random_hex()
    local f = io.open('/dev/urandom', 'rb')
    if f then
        local bytes = f:read(16)
        f:close()
        if bytes and #bytes == 16 then
            return (bytes:gsub('.', function(c)
                return ('%02x'):format(c:byte())
            end))
        end
    end
    -- Fallback: not cryptographic, but unique enough with time + clock.
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))
    local parts = {}
    for _ = 1, 16 do
        parts[#parts + 1] = ('%02x'):format(math.random(0, 255))
    end
    return table.concat(parts)
end

local function chunks()
    if not install_chunk then
        install_chunk = assert(rdebug.load(install_src))
    end
end

---Resolves the temp directory the same way common/socket.lua expands
---`$tmp` in rendezvous addresses, so the debuggee-side PID files land
---next to the abstract-socket names they belong to.
---@return string tmpdir Absolute temp dir, no trailing separator.
local function temp_dir()
    local ok, fs = pcall(require, 'bee.filesystem')
    if ok and fs then
        local dir = fs.temp_directory_path():string()
        if type(dir) == 'string' and #dir > 0 then
            return (dir:gsub('([/\\])$', ''))
        end
    end
    return os.getenv('TMPDIR') or os.getenv('TEMP') or os.getenv('TMP') or '/tmp'
end

---Installs the debuggee-side wrappers. No-op unless the launch config
---opted in; safe to call repeatedly (the chunk guards with a flag).
---@param enabled boolean launch `autoAttachChildProcesses`.
---@param launch_lua_path string Absolute path of moonwalk's launch.lua.
---@return string|nil spawn_log_path Announced once, on the installing tick,
---so the caller can tell the master where the spawn log lives; nil after
---that (or when disabled/install failed).
function m.ensure_installed(enabled, launch_lua_path)
    if not enabled or installed then
        return nil
    end
    if type(launch_lua_path) ~= 'string' then
        log.warn('childwatch: cannot locate launch.lua; child auto-attach disabled')
        return nil
    end
    chunks()
    if not addr_seed then
        addr_seed = random_hex()
    end
    -- rdebug.eval(chunk, ...) calls the chunk with the given arguments.
    local ok, err = rdebug.eval(install_chunk, launch_lua_path, addr_seed, temp_dir())
    if ok then
        installed = true
        -- The install chunk (pristine debuggee state, no bee) can only
        -- report spawns by appending to this file, so the master polls it.
        -- Announced to the master by the caller; never guessed.
        return temp_dir() .. '/luadbg_' .. addr_seed .. '_spawns'
    else
        log.warn(('childwatch: install failed: %s'):format(tostring(err)))
    end
    return nil
end

---Deletes this process's spawn claim token, if it has one. Called when the
---worker finishes DAP initialization: a token that survives to the parent
---session's end means "nobody attached", so removing it here marks this
---child "claimed" (owned by its own session; the parent must not reap it).
---No-op for normal sessions: the address pattern only matches auto-attach
---child addresses (`..._c<n>`).
function m.claim()
    local registry = debug.getregistry()
    local dbg_address = registry and registry['moonwalk.dbg_address']
    if type(dbg_address) ~= 'string' then
        return
    end
    local seed, index = dbg_address:match('^s:@%$tmp/luadbg_(%x+)_c(%d+)$')
    if not seed then
        return
    end
    os.remove(('%s/luadbg_%s_c%s.pid'):format(temp_dir(), seed, index))
end

return m
