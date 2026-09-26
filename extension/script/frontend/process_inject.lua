-- frontend/process_inject.lua
--
-- Attaches the debugger to an already-running process by loading the
-- launcher shared library into it: gdb/lldb script the dlopen on
-- Linux/macOS, a privileged helper does it on macOS (`hook` mode), and the
-- `inject` C module does it on Windows. All entry points return
-- `(true)` or `(false, err)`.

local fs = require('bee.filesystem')
local sp = require('bee.subprocess')
local arch = require('bee.platform').Arch
local platform_os = require('frontend.platform_os')()

local _M = {}

local macos = 'macos'
local windows = 'windows'
local entry_launch = 'launch'

---@param process userdata|integer Process handle or pid to inspect.
---@return boolean rosetta True when the process runs under Rosetta 2.
local function macos_check_rosetta_process(process)
    local rosetta_runtime = '/usr/libexec/rosetta/runtime'
    if not fs.exists(rosetta_runtime) then
        return false
    end
    local p = sp.spawn({
        '/usr/bin/fuser',
        rosetta_runtime,
        stdout = true,
        stderr = true, -- for skip  fuser output
    })
    if not p then
        return false
    end
    local l = p.stdout:read('a')
    return l:find(tostring(process)) ~= nil
end

---@param entry any Candidate entry symbol.
---@return string? err Reason when `entry` is not an expected symbol.
local function check_entry(entry)
    if entry ~= 'launch' and entry ~= 'attach' then
        return ('Invalid entry: %s'):format(tostring(entry))
    end
end

---@param pid any Candidate process id.
---@return string? clean Printable pid.
---@return string? err Reason when `pid` is not a positive integer.
local function check_pid(pid)
    if type(pid) == 'number' and pid > 0 and pid == math.floor(pid) then
        return tostring(pid)
    end
    return nil, ('Invalid pid: %s'):format(tostring(pid))
end

---@param s string Raw path for a C "..." literal (gdb/lldb `-ex`).
---@return string? escaped Literal content, or nil when unrepresentable.
local function c_escape(s)
    -- NUL/newline/control bytes cannot be represented in the debugger's
    -- command language; reject rather than smuggling them through.
    if s:find('%c') then
        return nil
    end
    return s:gsub('\\', '\\\\'):gsub('"', '\\"')
end

---@param s string Shell argument.
---@return string quoted `s` as one POSIX shell word.
local function shell_quote(s)
    -- Single-quote the word; each embedded ' becomes '\'' (close the
    -- quotes, add an escaped quote, reopen them).
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

---@param s string Raw string.
---@return string escaped `s` safe inside an AppleScript "..." literal.
local function applescript_escape(s)
    return s:gsub('\\', '\\\\'):gsub('"', '\\"')
end

---@param injectdll string? Explicit launcher path; defaults to bin/launcher.so.
---@return string? path Usable launcher path, or nil with an error message.
---@return string? err Reason when the launcher file is missing.
function _M.check_injectdll(injectdll)
    injectdll = injectdll or (WORKDIR / 'bin' / 'launcher.so'):string()
    if not fs.exists(injectdll) then
        return nil, 'Not found launcher.so.'
    end
    return injectdll
end

---@param pid integer Target process id.
---@param entry string Symbol to call after dlopen ("launch" or "attach").
---@param injectdll string? Explicit launcher path.
---@param gdb_path string? gdb executable, defaults to "gdb".
---@return boolean ok
---@return string? err Reason on failure.
function _M.gdb_inject(pid, entry, injectdll, gdb_path)
    local err
    injectdll, err = _M.check_injectdll(injectdll)
    if not injectdll then
        return false, err
    end
    local entryErr = check_entry(entry)
    if entryErr then
        return false, entryErr
    end
    local dll = c_escape(injectdll)
    if not dll then
        return false, 'injectdll path contains control characters.'
    end
    gdb_path = gdb_path or 'gdb'
    local pre_launcher = entry == entry_launch
            and {
                '-ex',
                'break main',
                '-ex',
                'c',
            }
        or {}

    local launcher = {
        '-ex',
        -- 6 = RTDL_NOW|RTDL_LOCAL macos
        -- 2 = RTDL_NOW linux
        ('set $luadbg_h = (void*)dlopen("%s", %d)'):format(dll, platform_os == macos and 6 or 2),
        '-ex',
        -- The entry symbol is resolved through dlsym with a quoted name so
        -- it is never interpolated raw into the gdb command language.
        ('call ((void(*)())dlsym($luadbg_h, "%s"))()'):format(entry),
        '-ex',
        'quit',
    }

    local p
    p, err = sp.spawn({
        gdb_path,
        '-p',
        tostring(pid),
        '--batch',
        pre_launcher,
        launcher,
        stdout = true,
        stderr = true,
    })
    if not p then
        return false, 'Spawn gdb failed:' .. err
    end
    if p:wait() ~= 0 then
        return false, 'stdout:' .. p.stdout:read('a') .. '\nstderr:' .. p.stderr:read('a')
    end
    return true
end

---@param pid integer Target process id.
---@param entry string Symbol to call after dlopen ("launch" or "attach").
---@param injectdll string? Explicit launcher path.
---@param lldb_path string? lldb executable, defaults to "lldb".
---@return boolean ok
---@return string? err Reason on failure.
function _M.lldb_inject(pid, entry, injectdll, lldb_path)
    local err
    injectdll, err = _M.check_injectdll(injectdll)
    if not injectdll then
        return false, err
    end
    local entryErr = check_entry(entry)
    if entryErr then
        return false, entryErr
    end
    local dll = c_escape(injectdll)
    if not dll then
        return false, 'injectdll path contains control characters.'
    end
    lldb_path = lldb_path or 'lldb'
    local pre_launcher = entry == entry_launch
            and {
                '-o',
                'breakpoint set -n main',
                '-o',
                'c',
            }
        or {}

    local launcher = {
        '-o',
        -- 6 = RTDL_NOW|RTDL_LOCAL macos
        -- 2 = RTDL_NOW linux
        ('expression void *$luadbg_h = (void*)dlopen("%s", %d)'):format(
            dll,
            platform_os == macos and 6 or 2
        ),
        '-o',
        -- The entry symbol is resolved through dlsym with a quoted name so
        -- it is never interpolated raw into the lldb command language.
        ('expression ((void(*)())dlsym($luadbg_h, "%s"))()'):format(entry),
        '-o',
        'quit',
    }

    local p
    p, err = sp.spawn({
        lldb_path,
        '-p',
        tostring(pid),
        '--batch',
        pre_launcher,
        launcher,
        stdout = true,
        stderr = true,
    })
    if not p then
        return false, 'Spawn lldb failed:' .. err
    end
    if p:wait() ~= 0 then
        return false, 'stdout:' .. p.stdout:read('a') .. '\nstderr:' .. p.stderr:read('a')
    end
    return true
end

---@param process integer Target process id.
---@param entry string Symbol to call after dlopen ("launch" or "attach").
---@param injectdll string? Explicit launcher path.
---@return boolean ok
---@return string? err Reason on failure.
function _M.macos_inject(process, entry, injectdll)
    local err
    injectdll, err = _M.check_injectdll(injectdll)
    if not injectdll then
        return false, err
    end
    -- Privileged use: validate pid and entry before building the admin
    -- shell command.
    local pid, pidErr = check_pid(process)
    if not pid then
        return false, pidErr
    end
    local entryErr = check_entry(entry)
    if entryErr then
        return false, entryErr
    end
    local helper = (WORKDIR / 'bin' / 'process_inject_helper'):string()
    -- Every word is shell-quoted as its own argument, then the complete
    -- command is AppleScript-escaped into the `do shell script` literal:
    -- two separate quoting layers for two separate languages.
    local cmd = table.concat({
        shell_quote(helper),
        shell_quote(pid),
        shell_quote(injectdll),
        shell_quote(entry),
    }, ' ')
    local p
    p, err = sp.spawn({
        '/usr/bin/osascript',
        '-e',
        ('do shell script "%s" with administrator privileges with prompt "lua-debug"'):format(
            applescript_escape(cmd)
        ),
        stderr = true,
    })
    if not p then
        return false, 'Spawn osascript failed:' .. err
    end
    if p:wait() ~= 0 then
        return false, p.stderr:read('a')
    end
    return true
end

---@param process userdata Target process handle.
---@param entry string Symbol to call after injection ("launch" or "attach").
---@return boolean ok
---@return string? err Reason on failure.
function _M.windows_inject(process, entry)
    local inject = require('inject')
    if
        not inject.injectdll(
            process,
            (WORKDIR / 'bin' / 'launcher.x86.dll'):string(),
            (WORKDIR / 'bin' / 'launcher.x64.dll'):string(),
            entry
        )
    then
        return false, 'injectdll failed.'
    end
    return true
end

---@param process userdata|integer Process handle or pid.
---@param entry string "launch" or "attach".
---@param args table Launch configuration (`inject`, `inject_executable`).
---@return boolean ok
---@return string? err Reason on failure.
function _M.inject(process, entry, args)
    if platform_os ~= windows and type(process) == 'userdata' then
        process = process:get_id()
    end
    if args.inject == 'gdb' then
        return _M.gdb_inject(process, entry, nil, args.inject_executable)
    elseif args.inject == 'lldb' then
        return _M.lldb_inject(process, entry, nil, args.inject_executable)
    elseif args.inject == 'hook' then
        if platform_os == macos then
            local is_launch = entry == entry_launch
            local is_rosetta = arch == 'arm64' and macos_check_rosetta_process(process)
            local force_lldb = is_launch or is_rosetta
            if force_lldb then
                local reason = is_launch and entry or 'rosetta'
                return false, 'force use lldb when ' .. reason .. ', please try lldb inject.'
            end
            local ok, err = _M.macos_inject(process, entry)
            if not ok then
                return false, err .. '\nretry or try lldb inject.'
            end
            return true
        elseif platform_os == windows then
            return _M.windows_inject(process, entry)
        else
            return false,
                ('Inject (use %s) is not supported in %s.'):format(args.inject, platform_os)
        end
    else
        return false, ('Inject (use %s) is not supported.'):format(args.inject)
    end
end

return _M
