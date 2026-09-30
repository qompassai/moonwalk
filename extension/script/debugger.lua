-- extension/script/debugger.lua
--
-- Client-side debugger handle used by the launch/attach entry points.
--
-- Resolves the prebuilt `luadebug` native module for the host platform and
-- Lua version, loads it, and exposes `start`/`attach`/`event` on the
-- returned `dbg` object. `setup_patch` monkey-patches the global
-- `pcall`/`xpcall`/`coroutine` functions so Lua-raised errors and thread
-- switches are reported as debugger events without modifying Lua itself.
-- When a debugger is already registered (nested attach), a no-op facade
-- is returned instead so the second load is harmless.

local self_source = ...

if not self_source then
    local source = debug.getinfo(1, 'S').source
    if source:sub(1, 1) == '@' then
        local filepath = source:sub(2)
        self_source = filepath
    end
end

local is_windows = package.config:sub(1, 1) == '\\'
local root = self_source:match('(.+)[/][^/]+$'):match('(.+)[/][^/]+$')

--- Debug-hint registry (vendored `std._debug`, see `script/std/README.md`).
--- Loaded with `dofile` on an absolute path because the host process's
--- `package.path` is not under our control at this point. Every runtime
--- argument check below consults `_debug.argcheck` before asserting.
local _debug = dofile(root .. '/script/std/_debug.lua')

--- Applies `MOONWALK_DEBUG` to the hint registry: `'safe'` enables every
--- runtime check, `'fast'` disables them, unset (or `'default'`) keeps the
--- upstream defaults. Anything else is a configuration error.
local function apply_debug_env()
    local mode = os.getenv('MOONWALK_DEBUG')
    if mode == 'safe' then
        _debug(true)
    elseif mode == 'fast' then
        _debug(false)
    elseif mode == nil or mode == '' or mode == 'default' then
        _debug()
    else
        error("bad MOONWALK_DEBUG (expected 'safe', 'fast' or 'default', got '" .. mode .. "')")
    end
end

apply_debug_env()

if debug.getregistry()['moonwalk'] then
    local dbg = debug.getregistry()['moonwalk']
    local empty = { root = dbg.root }
    function empty:init()
        return self
    end

    function empty:start()
        return self
    end

    function empty:attach()
        return self
    end

    function empty:event(what, ...)
        if what == 'setThreadName' then
            dbg:event(what, ...)
        end
        return self
    end

    function empty:set_wait()
        return self
    end

    function empty:set_coroutine_parent(co, parent)
        dbg:set_coroutine_parent(co, parent)
        return self
    end

    function empty:setup_patch()
        return self
    end

    return empty
end

--- Runs `uname` to identify the host OS/arch triple, e.g. "linux-x64".
---
--- Only reached when neither `cfg.platform` nor `MOONWALK_PLATFORM` pins
--- the platform explicitly.
---@return string platform_name
local function detect_host_platform()
    local function shell(command)
        --NOTICE: io.popen may not be thread-safe
        local f = assert(io.popen(command, 'r'))
        local r = f:read('*l')
        f:close()
        return r:lower()
    end
    local platform_name
    local function detect_windows()
        if os.getenv('PROCESSOR_ARCHITECTURE') == 'AMD64' then
            platform_name = 'win32-x64'
        else
            platform_name = 'win32-ia32'
        end
    end
    local function detect_linux()
        local machine = shell('uname -m')
        if machine == 'x86_64' or machine == 'amd64' then
            platform_name = 'linux-x64'
        elseif machine == 'aarch64' then
            platform_name = 'linux-arm64'
        else
            error('unknown ARCH')
        end
    end
    local function detect_android()
        platform_name = 'linux-arm64'
    end
    local function detect_macos()
        if shell('uname -m') == 'arm64' then
            platform_name = 'darwin-arm64'
        else
            platform_name = 'darwin-x64'
        end
    end
    local function detect_bsd()
        local machine = shell('uname -m')
        if machine == 'x86_64' or machine == 'amd64' then
            platform_name = 'bsd-x64'
        else
            error('unknown ARCH')
        end
    end
    if is_windows then
        detect_windows()
    else
        local name = shell('uname -s')
        if name == 'linux' then
            if shell('uname -o') == 'android' then
                detect_android()
            else
                detect_linux()
            end
        elseif name == 'darwin' then
            detect_macos()
        elseif name == 'netbsd' or name == 'freebsd' then
            detect_bsd()
        else
            error('unknown OS')
        end
    end
    assert(type(platform_name) == 'string')
    return platform_name
end

--- Resolves the absolute path of the `luadebug` native module for the
--- configured (or detected) platform and Lua version.
---@param cfg table Client config; `cfg.platform`, `cfg.luaVersion` optional.
---@return string luadebug_path Absolute path to luadebug.dll/.so.
local function detect_luadebug_path(cfg)
    if _debug.argcheck then
        assert(type(cfg) == 'table')
    end
    local platform_name = cfg.platform or os.getenv('MOONWALK_PLATFORM')
    if not platform_name then
        platform_name = detect_host_platform()
    end

    local runtime_subdir = '/runtime/' .. platform_name
    if cfg.luaVersion then
        runtime_subdir = runtime_subdir .. '/' .. cfg.luaVersion
    elseif _VERSION == 'Lua 5.5' then
        runtime_subdir = runtime_subdir .. '/lua55'
    elseif _VERSION == 'Lua 5.4' then
        runtime_subdir = runtime_subdir .. '/lua54'
    elseif _VERSION == 'Lua 5.3' then
        runtime_subdir = runtime_subdir .. '/lua53'
    elseif _VERSION == 'Lua 5.2' then
        runtime_subdir = runtime_subdir .. '/lua52'
    elseif _VERSION == 'Lua 5.1' then
        if tostring(assert):match('builtin') ~= nil then
            runtime_subdir = runtime_subdir .. '/luajit'
            jit.off()
        else
            runtime_subdir = runtime_subdir .. '/lua51'
        end
    else
        error(_VERSION .. ' is not supported.')
    end

    local ext = is_windows and 'dll' or 'so'
    return root .. runtime_subdir .. '/luadebug.' .. ext
end

---@class Moonwalk
---@field root string Extension root, UTF-8 on Windows unless `cfg.ansi`.
---@field address string|nil DAP endpoint address from the client config.
---@field rdebug table The loaded luadebug native module.

--- Loads the native module into `dbg` and publishes the resolved paths to it.
---@param dbg Moonwalk Debugger handle to initialize.
---@param cfg table|string Client config, or a bare address string.
local function init_debugger(dbg, cfg)
    if type(cfg) == 'string' then
        cfg = { address = cfg }
    end
    if _debug.argcheck then
        assert(type(cfg) == 'table')
    end

    local luadebug_path = os.getenv('MOONWALK_CORE')
    local update_env = false
    if not luadebug_path then
        luadebug_path = detect_luadebug_path(cfg)
        update_env = true
    end
    if is_windows then
        assert(package.loadlib(luadebug_path, 'init'))(cfg.luaapi)
    end

    ---@type Moonwalk
    dbg.rdebug = assert(package.loadlib(luadebug_path, 'luaopen_luadebug'))()
    if not os.getenv('MOONWALK_PATH') then
        dbg.rdebug.setenv('MOONWALK_PATH', self_source)
    end
    if update_env then
        dbg.rdebug.setenv('MOONWALK_CORE', luadebug_path)
    end

    local function utf8(s)
        if cfg.ansi and is_windows then
            return dbg.rdebug.a2u(s)
        end
        return s
    end
    dbg.root = utf8(root)
    dbg.address = cfg.address and utf8(cfg.address) or nil
end

local dbg = {}

--- Starts a debug session against `cfg.address` (connect or listen mode).
---@param cfg table Client config; `cfg.client == true` selects connect mode.
---@return Moonwalk self
function dbg:start(cfg)
    init_debugger(self, cfg)

    self.rdebug.start(([[
        local rootpath = %q
        package.path = rootpath.."/script/?.lua"
        require "backend.bootstrap". start(rootpath, %q..%q)
    ]]):format(self.root, cfg.client == true and 'connect:' or 'listen:', dbg.address))
    return self
end

--- Attaches to an already-running process (no listen/connect handshake).
---@param cfg table|nil Client config.
---@return Moonwalk self
function dbg:attach(cfg)
    init_debugger(self, cfg or {})

    self.rdebug.start(([[
        local rootpath = %q
        package.path = rootpath..'/script/?.lua'
        require 'backend.bootstrap'. attach(rootpath)
    ]]):format(self.root))
    return self
end

--- Clears the native debugger state.
function dbg:stop()
    self.rdebug.clear()
end

--- Forwards a debugger event to the native module.
---@param ... any Event name followed by event arguments.
---@return Moonwalk self
function dbg:event(...)
    self.rdebug.event(...)
    return self
end

--- Installs a one-shot global `name` that forwards to `f` then emits `wait`.
---@param name string Global name to install.
---@param f function Callback invoked with the wait arguments.
---@return Moonwalk self
function dbg:set_wait(name, f)
    _G[name] = function(...)
        _G[name] = nil
        f(...)
        self:event('wait')
    end
    return self
end

--- Set once `setup_patch` replaces the globals; a second call returns `self`
--- without stacking another event layer on the patched functions.
local patch_applied = false

--- Assigns co's parent coroutine; the stack view splices the parent's
--- frames after co's. A nil parent clears the assignment.
---@param co thread Child coroutine in the debug target.
---@param parent thread|nil Parent coroutine in the debug target, or nil.
---@return Moonwalk self
function dbg:set_coroutine_parent(co, parent)
    self:event('setCoroutineParent', co, parent)
    return self
end

--- Patches global `pcall`/`xpcall`/`coroutine` so errors and thread
--- switches surface as debugger events. Idempotent per process.
---@return Moonwalk self
function dbg:setup_patch()
    -- A second call must not wrap the already-patched globals: that would
    -- stack another event layer on every error and thread switch.
    if patch_applied then
        return self
    end
    patch_applied = true
    local ERREVENT_ERRRUN = 0x02
    local raw_xpcall = xpcall
    function pcall(f, ...)
        return raw_xpcall(f, function(msg)
            self:event('exception', msg, ERREVENT_ERRRUN, 3)
            return msg
        end, ...)
    end

    function xpcall(f, msgh, ...)
        return raw_xpcall(f, function(msg)
            self:event('exception', msg, ERREVENT_ERRRUN, 3)
            return msgh and msgh(msg) or msg
        end, ...)
    end

    local raw_coroutine_resume = coroutine.resume
    local raw_coroutine_wrap = coroutine.wrap
    local function coro_return(co, ...)
        self:event('thread', co, 1)
        return ...
    end
    function coroutine.resume(co, ...)
        self:event('thread', co, 0)
        return coro_return(co, raw_coroutine_resume(co, ...))
    end

    function coroutine.wrap(f)
        local wf = raw_coroutine_wrap(f)
        local _, co = debug.getupvalue(wf, 1)
        return function(...)
            self:event('thread', co, 0)
            return coro_return(co, wf(...))
        end
    end

    -- A closed coroutine has ended too; without this its parent links
    -- would linger after close.
    local raw_coroutine_close = coroutine.close
    if raw_coroutine_close then
        function coroutine.close(co)
            local ok, err = raw_coroutine_close(co)
            self:event('thread', co, 1)
            return ok, err
        end
    end

    return self
end

debug.getregistry()['moonwalk'] = dbg

return dbg
