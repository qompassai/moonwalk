-- backend/worker/childwatch_install.lua
--
-- Runs inside the debugged process (loaded via rdebug.load). Wraps
-- `os.execute` and `io.popen` so that child processes started as Lua
-- interpreters are born debuggable: the wrapper rewrites their command
-- line to preload the moonwalk bootstrap (`launch.lua`) pointed at a
-- per-child rendezvous address.
--
-- Arguments: launchLuaPath (string), addrSeed (string), tmpDir (string).
--
-- Spawn reporting (2026-09-27 redesign): the wrapper appends one record
-- per Lua child to `<tmp>/luadbg_<seed>_spawns` BEFORE invoking the real
-- (blocking) call. This chunk runs in the debuggee's pristine Lua state
-- (via rdebug.eval) where `bee` is unavailable, so a plain file is the
-- only out-of-band path: the master thread -- the only thread that stays
-- live while the debuggee is blocked inside os.execute -- polls that file
-- on every tick and forwards each record to the frontend, which fires the
-- `startDebugging` reverse request. The worker announces the log path to
-- the master (it has bee and a worker->master channel); the master never
-- guesses it. An earlier design tried a process-shared bee.channel, but
-- the channel is invisible from this state (`require('bee.channel')`
-- fails here), so no push could ever arrive.
--
-- The old design recorded spawns in `__moonwalk_child_spawns` for the
-- worker to poll from its update hook; that could never work, because the
-- worker's code runs on the debuggee's own thread (driven by debug hooks)
-- and no hooks fire while the debuggee sits inside os.execute's C call.
--
-- Orphan handling: the wrapper creates (pure Lua, no shell tricks)
-- `<tmp>/luadbg_<seed>_c<n>.pid` as a claim token at spawn time. The
-- child's own backend deletes that file when a DAP client initializes
-- ("claimed": somebody owns this child, do not kill it); the `os.execute`
-- wrapper deletes it once the child exits. At parent session end, cleanup
-- scans /proc for live processes whose command line still carries the
-- child's unique `luadbg_<seed>_c<n>` bootstrap marker and reaps those
-- whose claim token survives. Discovery by cmdline marker (not by a
-- recorded PID) means a stale token can never turn into a signal to a
-- recycled PID. `io.popen` handles cannot be hooked, so their tokens live
-- until claim or session end.
--
-- Limits, all deliberate:
-- * Only commands whose first token looks like a Lua interpreter
--   (`lua`, `lua5.x`, `luajit`, with optional path prefix) are rewritten.
--   Everything else passes through untouched.
-- * Shell quoting follows POSIX single-quote rules; on Windows (detected
--   via package.config) double quotes are used. Exotic shells may still
--   misquote -- best-effort, documented. Windows spawns are reported but
--   never reaped (cleanup is POSIX-only).
-- * The child starts its own full backend listening on its address; the
--   editor must honor the `startDebugging` reverse request for the new
--   session to attach. Without that, the child waits at its debugger wait
--   gate until the parent session ends and reaps it.

local launchLuaPath, addrSeed, tmpDir = ...
assert(type(launchLuaPath) == 'string', 'launchLuaPath must be a string')
assert(type(addrSeed) == 'string', 'addrSeed must be a string')
assert(type(tmpDir) == 'string', 'tmpDir must be a string')

if rawget(_G, '__moonwalk_childwatch') then
    return true
end
rawset(_G, '__moonwalk_childwatch', true)

local is_windows = package.config:sub(1, 1) == '\\'

-- Spawn log: one `\t`-separated record per line
-- (`address \t pidfile \t command`), backslash-escaped. Pure Lua: this
-- state has no bee, so the master polls this file instead of a channel.
-- The worker announces the path to the master; the master never guesses.
local spawn_log_path = tmpDir .. '/luadbg_' .. addrSeed .. '_spawns'

---@param s string Field value to make line-safe.
---@return string escaped
local function esc(s)
    return (s:gsub('\\', '\\\\'):gsub('\n', '\\n'):gsub('\t', '\\t'))
end

---@param address string Child rendezvous address.
---@param pidfile string Claim-token path.
---@param command string Original command line (display only).
local function report_spawn(address, pidfile, command)
    local f = io.open(spawn_log_path, 'a')
    if not f then
        return
    end
    -- One write + close per spawn: the master only processes lines
    -- terminated by `\n`, so a partial write is simply retried next tick.
    f:write(esc(address) .. '\t' .. esc(pidfile) .. '\t' .. esc(command) .. '\n')
    f:close()
end

---@param s string Shell argument to quote.
---@return string quoted
local function shell_quote(s)
    if is_windows then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

---@param cmd string Shell command line.
---@return string token Original first token, quotes preserved.
---@return string rest Remainder of the command line after the token.
---@return boolean is_lua True when the token names a Lua interpreter.
local function split_interp(cmd)
    local token, rest
    local first = cmd:sub(1, 1)
    if first == '"' or first == "'" then
        local close = cmd:find(first, 2, true)
        if not close then
            return nil, nil, false
        end
        -- Keep the original quoting: re-emitting a bare path with spaces
        -- would break the command.
        token = cmd:sub(1, close)
        rest = cmd:sub(close + 1)
    else
        local s, e = cmd:find('^%s*(%S+)')
        if not s then
            return nil, nil, false
        end
        token = cmd:sub(s, e)
        rest = cmd:sub(e + 1)
    end
    -- Match the interpreter name on the unquoted basename for the Lua
    -- test, but emit the original token text.
    local bare = token:gsub('^["\']', ''):gsub('["\']$', '')
    local base = bare:match('([^/\\]+)$') or bare
    local is_lua = base:match('^luajit') ~= nil
        or base:match('^lua5') ~= nil
        or base:match('^lua[%d%.]*$') ~= nil
    return token, rest, is_lua
end

local spawn_count = 0

---@param cmd string Original shell command line.
---@return string newcmd Rewritten command, or the original when untouched.
---@return string|nil pidfile Claim-token path for Lua spawns, else nil.
local function maybe_rewrite(cmd)
    if type(cmd) ~= 'string' then
        return cmd, nil
    end
    local token, rest, is_lua = split_interp(cmd)
    if not is_lua then
        return cmd, nil
    end
    spawn_count = spawn_count + 1
    local childAddr = ('@$tmp/luadbg_%s_c%d'):format(addrSeed, spawn_count)
    -- Same bootstrap shape the frontend builds: dofile(launch.lua) DBG('s:<addr>').
    local bootstrap = ("dofile(%q) DBG('s:%s')"):format(launchLuaPath, childAddr)
    local newcmd = ('%s -e %s%s'):format(token, shell_quote(bootstrap), rest)
    -- The command line itself is left structurally untouched (no `exec`
    -- tricks: those would drop trailing `;`-separated user commands, and
    -- `VAR=val { ...; }` is a syntax error in dash). The claim token is a
    -- pure-Lua file create; discovery happens via /proc at cleanup.
    local pidfile = ('%s/luadbg_%s_c%d.pid'):format(tmpDir, addrSeed, spawn_count)
    do
        local f = io.open(pidfile, 'w')
        if f then
            f:close()
        end
    end
    -- Report BEFORE the blocking call: once os.execute is entered, this
    -- thread runs no more Lua until the child exits.
    report_spawn(childAddr, pidfile, cmd)
    return newcmd, pidfile
end

local os_execute = os.execute
if type(os_execute) == 'function' then
    os.execute = function(cmd, ...)
        local newcmd, pidfile = maybe_rewrite(cmd)
        local results = table.pack(os_execute(newcmd, ...))
        -- os.execute waited for the child, so it has exited: drop the claim
        -- token. Already gone when the child was attached (claimed on DAP
        -- initialize).
        if pidfile then
            os.remove(pidfile)
        end
        return table.unpack(results, 1, results.n)
    end
end

local io_popen = io.popen
if type(io_popen) == 'function' then
    io.popen = function(cmd, mode)
        local newcmd = maybe_rewrite(cmd)
        return io_popen(newcmd, mode)
    end
end

return true
