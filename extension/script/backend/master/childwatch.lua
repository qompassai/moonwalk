-- backend/master/childwatch.lua
--
-- Master-side half of child-process auto-attach (launch
-- `autoAttachChildProcesses`).
--
-- DESIGN (2026-09-27 redesign of the original poll-based watcher):
--
-- The debuggee-side wrappers (backend/worker/childwatch_install.lua)
-- append one record per spawned Lua child to
-- `<tmp>/luadbg_<seed>_spawns` BEFORE invoking the real (blocking)
-- os.execute/io.popen. A file is the only out-of-band path: the install
-- chunk runs in the debuggee's pristine Lua state (via rdebug.eval),
-- where `bee` is unavailable -- an earlier bee.channel design failed
-- exactly there, the chunk's `require('bee.channel')` finding nothing.
-- This module polls the log on every master tick (`poll`, called from
-- mgr.update_once) and forwards each new record to the frontend as a
-- `moonwalkChildSpawned` event, which the proxy turns into a
-- `startDebugging` reverse request. The worker announces the log path
-- over the existing worker->master channel (`eventChildWatchLog`); the
-- master never guesses it. At session end, `cleanup` (called from
-- mgr.update's tail and the request.disconnect/terminate/restart paths)
-- reaps spawned children nobody attached to.
--
-- Why the worker cannot do this: the worker is not a separate thread. Its
-- code runs on the debuggee's own thread, driven by debug hooks, and no
-- hooks fire while the debuggee sits inside os.execute's C call -- so a
-- worker-side poll never runs during exactly the window that matters.
-- The master thread is the only execution context that stays live during
-- the block, but it runs a separate Lua state and cannot read the
-- debuggee's globals, so there is nothing for it to poll. The spawn
-- record must therefore be written out-of-band before the blocking call.
--
-- Rejected alternatives:
-- * Poll the debuggee state from the master thread: impossible, separate
--   Lua states (see above).
-- * Replace the blocking spawn with an async spawn plus a completion
--   notification: os.execute's contract is synchronous -- debuggees branch
--   on its exit status -- so faking an immediate return changes
--   debuggee-visible behavior. Rejected.
-- * A process-shared bee.channel for the records: invisible from the
--   chunk's pristine state (`require('bee.channel')` fails there), so no
--   push could ever arrive. Rejected after a live failure proved it.
--
-- Orphan handling: every spawn creates `<tmp>/luadbg_<seed>_c<n>.pid` as a
-- claim token (pure Lua, in the debuggee-side wrapper). The child's own
-- backend deletes that token when a DAP client initializes ("claimed":
-- somebody owns this child, do not kill it); the `os.execute` wrapper
-- deletes it once the child exits. `cleanup` reaps every still-unclaimed
-- child whose token survives by scanning /proc for live processes whose
-- command line carries the child's unique `luadbg_<seed>_c<n>` bootstrap
-- marker. Discovery by cmdline marker -- not by a recorded PID -- means a
-- stale token can never turn into a signal to a recycled PID. Windows and
-- non-/proc platforms skip the scan (documented best-effort).

local log = require('common.log')
local mgr = require('backend.master.mgr')

local m = {}

---Upper bound on tracked spawns; beyond this the oldest record is dropped
---(its claim token is left for the normal claim/cleanup path).
local SPAWNS_MAX = 4096
---Upper bound on registered spawn logs (one per worker that opted in).
local SPAWN_LOGS_MAX = 64
---Bytes of /proc/<pid>/cmdline read for the ownership check.
local CMDLINE_READ_MAX = 4096
---Bounded SIGTERM grace before escalating to SIGKILL.
local SIGTERM_WAIT_MS = 500
local SIGTERM_POLL_MS = 50

---@class ChildSpawnRecord
---@field address string Child backend rendezvous address.
---@field command string|nil Original command line (display only, never trusted).
---@field pidfile string|nil Claim-token path; nil when the token create failed.
---@field seed string Address seed, embedded in the child's command line.

---@class SpawnLog
---@field path string Spawn-log file path.
---@field offset integer Bytes already consumed.

---@type SpawnLog[]
local spawn_logs = {}
---@type ChildSpawnRecord[]
local spawns = {}
---Set once cleanup() has run: session end can arrive through several
---paths (disconnect, terminate, restart, master loop exit); reaping twice
---must be a no-op.
local cleaned = false

local function is_windows()
    return package.config:sub(1, 1) == '\\'
end

---Registers a spawn-log file for polling. Called from the
---`eventChildWatchLog` worker->master message; the worker announces the
---path, the master never guesses it. Idempotent.
---@param path string Absolute spawn-log path.
function m.set_log(path)
    if type(path) ~= 'string' or path == '' then
        return
    end
    for _, entry in ipairs(spawn_logs) do
        if entry.path == path then
            return
        end
    end
    if #spawn_logs >= SPAWN_LOGS_MAX then
        log.warn('childwatch: too many spawn logs; ignoring ' .. path)
        return
    end
    spawn_logs[#spawn_logs + 1] = { path = path, offset = 0 }
end

---Resets per-session state. Called once from mgr.init.
function m.init()
    spawn_logs = {}
    spawns = {}
    cleaned = false
end

---@param s string Escaped field value from the spawn log.
---@return string unescaped
local function unesc(s)
    return (s:gsub('\\(.)', { n = '\n', t = '\t', ['\\'] = '\\' }))
end

---@param line string One complete spawn-log line.
---@return ChildSpawnRecord? rec
local function parse_line(line)
    local address, pidfile, command = line:match('^([^\t]*)\t([^\t]*)\t(.*)$')
    if not address or address == '' then
        return nil
    end
    address, pidfile, command = unesc(address), unesc(pidfile), unesc(command)
    -- Strict shape: only our own addresses become startDebugging events.
    local seed = address:match('^@%$tmp/luadbg_(%x+)_c%d+$')
    if not seed then
        return nil
    end
    if pidfile == '' then
        pidfile = nil
    end
    if command == '' then
        command = nil
    end
    return { address = address, command = command, pidfile = pidfile, seed = seed }
end

---@param entry SpawnLog
local function poll_log(entry)
    local f = io.open(entry.path, 'rb')
    if not f then
        return
    end
    f:seek('set', entry.offset)
    local tail = f:read('*a') or ''
    f:close()
    -- Only lines terminated by `\n`: the writer closes after each line, so
    -- a trailing fragment is a partial write, retried next tick.
    local last_nl = tail:match('.*\n()')
    if not last_nl then
        return
    end
    entry.offset = entry.offset + last_nl - 1
    for line in tail:sub(1, last_nl - 1):gmatch('[^\n]+') do
        local rec = parse_line(line)
        if rec then
            if #spawns >= SPAWNS_MAX then
                log.warn('childwatch: spawn registry full; dropping oldest')
                table.remove(spawns, 1)
            end
            spawns[#spawns + 1] = rec
            mgr.clientSend({
                type = 'event',
                seq = mgr.newSeq(),
                event = 'moonwalkChildSpawned',
                body = {
                    address = rec.address,
                    command = rec.command,
                },
            })
        else
            log.warn('childwatch: ignoring malformed spawn-log line')
        end
    end
end

---Polls registered spawn logs and forwards new records to the frontend.
---Called on every master tick: the debuggee thread may be blocked inside
---os.execute, which is exactly why this lives here and not in the worker.
function m.poll()
    for _, entry in ipairs(spawn_logs) do
        local ok, err = pcall(poll_log, entry)
        if not ok then
            log.warn(('childwatch: spawn-log poll failed: %s'):format(tostring(err)))
        end
    end
end

---@param seed string Address seed from the spawn record.
---@param child_index string The `_c<n>` suffix from the spawn address.
---@return string[] pids Live PIDs whose command line carries our marker.
local function find_child_pids(seed, child_index)
    local pids = {}
    local ok, fs = pcall(require, 'bee.filesystem')
    if not (ok and fs) then
        return pids
    end
    -- The marker is embedded in the child's DBG bootstrap argument, so
    -- matching it proves ownership: a stale claim token can never turn
    -- into a signal to a recycled PID.
    local marker = ('luadbg_%s_c%s'):format(seed, child_index)
    local ok_scan, err = pcall(function()
        for path in fs.pairs(fs.path('/proc')) do
            local name = path:filename():string()
            if name:match('^%d+$') then
                local f = io.open(('/proc/%s/cmdline'):format(name), 'rb')
                if f then
                    local blob = f:read(CMDLINE_READ_MAX)
                    f:close()
                    if type(blob) == 'string' and blob:find(marker, 1, true) then
                        pids[#pids + 1] = name
                    end
                end
            end
        end
    end)
    if not ok_scan then
        log.warn(('childwatch: /proc scan failed: %s'):format(tostring(err)))
    end
    return pids
end

---@param pid string Validated numeric PID.
---@return boolean alive
local function process_alive(pid)
    -- `kill -0` is the portable POSIX liveness probe. os.execute's return
    -- shape differs by Lua version (true in 5.4, 0 in 5.1-5.3); the PID is
    -- `%d+`-validated, so no shell injection is possible.
    local res = os.execute(('kill -0 %s >/dev/null 2>&1'):format(pid))
    return res == true or res == 0
end

---@param pid string Validated numeric PID.
local function terminate_pid(pid)
    os.execute(('kill -TERM %s >/dev/null 2>&1'):format(pid))
    -- Bounded escalation, mirroring the frontend's reap_debuggee: a child
    -- ignoring SIGTERM must not stall session shutdown.
    local thread = require('bee.thread')
    local waited_ms = 0
    while waited_ms < SIGTERM_WAIT_MS and process_alive(pid) do
        thread.sleep(SIGTERM_POLL_MS)
        waited_ms = waited_ms + SIGTERM_POLL_MS
    end
    if process_alive(pid) then
        os.execute(('kill -KILL %s >/dev/null 2>&1'):format(pid))
    end
end

---@param rec ChildSpawnRecord
local function reap_one(rec)
    local pidfile = rec.pidfile
    if not pidfile then
        return
    end
    -- No claim token: the child was claimed on attach (its backend deleted
    -- the token on DAP initialize), or its os.execute wrapper removed it
    -- after a clean exit. Nothing to do either way.
    local token = io.open(pidfile, 'r')
    if not token then
        return
    end
    token:close()
    -- A surviving token means "unclaimed": find the live child by its
    -- unique cmdline marker and reap it. A crashed child matches nothing
    -- and is simply untokened below.
    local child_index = rec.address:match('_c(%d+)$')
    if child_index then
        for _, pid in ipairs(find_child_pids(rec.seed, child_index)) do
            if process_alive(pid) then
                log.warn(('childwatch: reaping unattached child PID %s'):format(pid))
                terminate_pid(pid)
            end
        end
    end
    os.remove(pidfile)
end

---Kills every spawned child that nobody attached to. Called at session end
---from request.disconnect / request.terminate / request.restart (which
---kill this process via os.exit/closeprocess, bypassing the master loop's
---tail) and from mgr.update()'s tail (normal debuggee end, detach); the
---first call wins. A child still waiting at its debugger wait gate can
---never proceed once this session is gone, so leaving it would orphan it
---forever. Children claimed by an attach (claim token deleted by the
---child's own backend on DAP initialize) are owned by their own session
---and are left alone.
function m.cleanup()
    if cleaned then
        return
    end
    cleaned = true
    if is_windows() then
        -- No /proc scan on Windows; tokens are left for the OS temp
        -- cleaner. Nothing to reap.
        spawns = {}
        return
    end
    for _, rec in ipairs(spawns) do
        -- One bad record must not skip the rest; the error is logged.
        local ok, err = xpcall(reap_one, debug.traceback, rec)
        if not ok then
            log.error(('childwatch: cleanup failed: %s'):format(tostring(err)))
        end
    end
    spawns = {}
end

return m
