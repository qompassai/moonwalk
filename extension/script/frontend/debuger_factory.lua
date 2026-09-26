-- frontend/debuger_factory.lua
--
-- Builds the debuggee process (or the terminal-launch description the editor
-- runs itself): locates the right Lua runtime for the OS/arch matrix,
-- assembles the `dofile[[...]] DBG[[...]]` bootstrap command line, and
-- optionally injects the debugger DLL into an already-running process.

local fs = require('bee.filesystem')
local sp = require('bee.subprocess')
local platform_os = require('frontend.platform_os')
local process_inject = require('frontend.process_inject')

local useWSL = false
local useUtf8 = false

local function initialize(args)
    useWSL = args.useWSL
    useUtf8 = args.sourceCoding == 'utf8'
end

local function towsl(s)
    if not useWSL or not s:match('^%a:') then
        return s
    end
    return s:gsub('\\', '/'):gsub('^(%a):', function(c)
        return '/mnt/' .. c:lower()
    end)
end

local function getLuaVersion(args)
    -- The launch config comes from the editor as untyped JSON; a
    -- non-string luaVersion must not reach string operations below.
    if type(args.luaVersion) == 'string' then
        return args.luaVersion
    end
    return 'lua54'
end

local function is64BitWindows()
    -- https://docs.microsoft.com/en-us/archive/blogs/david.wang/howto-detect-process-bitness
    return os.getenv('PROCESSOR_ARCHITECTURE') == 'AMD64'
        or os.getenv('PROCESSOR_ARCHITEW6432') == 'AMD64'
end

local function isArm64Macos()
    local f <close> = assert(io.popen('uname -v', 'r'))
    if f:read('l'):match('RELEASE_ARM64') then
        return true
    end
end

local PLATFORM = {
    ['windows-x86'] = 'win32-ia32',
    ['windows-x86_64'] = 'win32-x64',
    ['linux-x86_64'] = 'linux-x64',
    ['linux-arm64'] = 'linux-arm64',
    ['android-arm64'] = 'linux-arm64',
    ['macos-x86_64'] = 'darwin-x64',
    ['macos-arm64'] = 'darwin-arm64',
}

---@param args table Launch configuration.
---@param dbg table Extension directory path (bee.filesystem path object).
---@return table? luaexe Runtime path, or nil with an error message.
---@return string? err Human-readable reason when no runtime was found.
local function getLuaExe(args, dbg)
    local OS = platform_os()
    local ARCH = args.luaArch
    if OS == 'windows' then
        ARCH = ARCH or 'x86_64'
        if ARCH == 'x86_64' and not is64BitWindows() then
            ARCH = 'x86'
        end
    elseif OS == 'linux' then
        ARCH = ARCH or 'x86_64'
    elseif OS == 'macos' then
        if isArm64Macos() then
            ARCH = ARCH or 'x86_64'
            if ARCH == 'x86' then
                ARCH = 'x86_64'
            end
        else
            ARCH = 'x86_64'
        end
    elseif OS == 'android' then
        ARCH = 'arm64'
    end
    local platform = PLATFORM[OS .. '-' .. ARCH]
    if not platform then
        return nil,
            ('No runtime (OS: %s, ARCH: %s) is found, '):format(OS, ARCH)
                .. 'you need to compile it yourself.'
    end
    local version = getLuaVersion(args)
    local luaexe = dbg / 'runtime' / platform / version / (OS == 'windows' and 'lua.exe' or 'lua')
    if fs.exists(luaexe) then
        return luaexe
    end
    return nil, ('No runtime (%s) is found, you need to compile it yourself.'):format(luaexe)
end

local function bootstrapOption(option, luaexe, args)
    option.cwd = (type(args.cwd) == 'string') and args.cwd or luaexe:parent_path():string()
    if type(args.env) == 'table' then
        option.env = args.env
    end
end

---@param address string|integer Backend rendezvous address.
---@return string? clean Printable address for the bootstrap command.
---@return string? err Reason when the address is not a valid endpoint.
local function check_ipv4(ip)
    local a, b, c, d = ip:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    for _, octet in ipairs({ a, b, c, d }) do
        local n = tonumber(octet)
        if n == nil or n > 255 then
            return false
        end
    end
    return a ~= nil
end

---@param port string Candidate port digits.
---@return boolean valid True for a usable TCP port.
local function check_port(port)
    local n = tonumber(port)
    return n ~= nil and n >= 1 and n <= 65535
end

local function checkAddress(address)
    if type(address) == 'number' then
        -- Generated rendezvous: a pid, always a positive integer.
        if address > 0 and address == math.floor(address) then
            return tostring(address)
        end
    elseif type(address) == 'string' then
        -- External address, already prefixed with its transport role
        -- ('c:' connect or 's:' listen). The remainder must be a supported
        -- endpoint form: unix socket path, IPv4:port, or [IPv6]:port.
        -- Anything else is rejected rather than interpolated into Lua code.
        local role, rest = address:match('^([cs]):(.*)$')
        if role and rest then
            local ok = false
            if rest:sub(1, 1) == '@' then
                ok = #rest > 1 and rest:find('%c') == nil
            else
                local ip, port = rest:match('^([^:]+):(%d+)$')
                local ip6, port6 = rest:match('^%[([%x:]*%x[%x:]*)%]:(%d+)$')
                if ip and check_ipv4(ip) and check_port(port) then
                    ok = true
                elseif ip6 and check_port(port6) then
                    ok = true
                end
            end
            if ok then
                return address
            end
        end
    end
    return nil, ('Invalid backend address: %s'):format(tostring(address))
end

---@param c table Command argv being built.
---@param luaexe table Runtime path (bee.filesystem path object).
---@param args table Launch configuration.
---@param address string|integer Backend rendezvous address.
---@param dbg table Extension directory path.
---@return boolean ok
---@return string? err Reason when the address is not a valid endpoint.
local function bootstrapMakeExe(c, luaexe, args, address, dbg)
    local cleanAddress, addrErr = checkAddress(address)
    if not cleanAddress then
        return false, addrErr
    end
    c[#c + 1] = towsl(luaexe:string())
    c[#c + 1] = '-e'
    local params = {}
    params[#params + 1] = cleanAddress
    if not useUtf8 then
        params[#params + 1] = 'ansi'
    end
    local luaVersion = getLuaVersion(args)
    if luaVersion:match('^lua%-') then
        params[#params + 1] = luaVersion
    end
    -- %q renders proper Lua string literals: no [[...]] long brackets
    -- whose terminator a hostile address could smuggle in, so the old
    -- bash [[ -> " rewrite is unnecessary.
    local script = ('dofile(%q) DBG(%q)'):format(
        (dbg / 'script' / 'launch.lua'):string(),
        table.concat(params, '/')
    )
    c[#c + 1] = script
    return true
end

local function bootstrapMakeArgs(c, args)
    if type(args.arg0) == 'string' then
        c[#c + 1] = args.arg0
    elseif type(args.arg0) == 'table' then
        for _, v in ipairs(args.arg0) do
            if type(v) == 'string' then
                c[#c + 1] = v
            end
        end
    end

    c[#c + 1] = (type(args.program) == 'string') and towsl(args.program) or '.lua'

    if type(args.arg) == 'string' then
        c[#c + 1] = args.arg
    elseif type(args.arg) == 'table' then
        for _, v in ipairs(args.arg) do
            if type(v) == 'string' then
                c[#c + 1] = v
            end
        end
    end
end

---@param args table Launch configuration.
---@param dbg table Extension directory path.
---@return table? luaexe Runtime path, or nil with an error message.
---@return string? err Human-readable reason when no runtime was found.
local function checkLuaExe(args, dbg)
    if type(args.luaexe) == 'string' then
        local luaexe = fs.path(args.luaexe)
        if not args.luaexe:find(package.config:sub(1, 1), 1, true) then
            return luaexe
        end
        if fs.exists(luaexe) then
            return luaexe
        end
        if platform_os() == 'windows' and luaexe:equal_extension('') then
            luaexe = fs.path(luaexe):replace_extension('exe')
            if fs.exists(luaexe) then
                return luaexe
            end
        end
        return nil, ('No file `%s`.'):format(args.luaexe)
    end
    return getLuaExe(args, dbg)
end

---@param _ any Unused (kept for a uniform factory signature).
---@param args table Launch configuration.
---@param dbg table Extension directory path.
---@param address string Backend rendezvous address.
---@return table? option `runInTerminal` arguments for the editor.
---@return string? err Human-readable reason on failure.
local function create_luaexe_in_terminal(_, args, dbg, address)
    initialize(args)
    local luaexe, err = checkLuaExe(args, dbg)
    if not luaexe then
        return nil, err
    end
    local option = {
        kind = (args.console == 'integratedTerminal') and 'integrated' or 'external',
        title = args.name,
        args = {},
        --TODO: support argsCanBeInterpretedByShell
    }
    if useWSL then
        option.args[1] = 'wsl'
    end
    bootstrapOption(option, luaexe, args)
    local ok, errmsg = bootstrapMakeExe(option.args, luaexe, args, address, dbg)
    if not ok then
        return nil, errmsg
    end
    bootstrapMakeArgs(option.args, args)
    return option
end

---@param args table Launch configuration.
---@param dbg table Extension directory path.
---@param address string Backend rendezvous address.
---@return table? process Spawned process, or nil with an error message.
---@return string? err Human-readable reason on failure.
local function create_luaexe_in_console(args, dbg, address)
    initialize(args)
    local luaexe, err = checkLuaExe(args, dbg)
    if not luaexe then
        return nil, err
    end
    local option = {
        console = 'hide',
        searchPath = true,
    }
    if useWSL then
        local SystemRoot = (os.getenv('SystemRoot')) or 'C:\\WINDOWS'
        option[1] = SystemRoot .. '\\sysnative\\wsl.exe'
    end
    bootstrapOption(option, luaexe, args)
    local ok, errmsg = bootstrapMakeExe(option, luaexe, args, address, dbg)
    if not ok then
        return nil, errmsg
    end
    bootstrapMakeArgs(option, args)
    return sp.spawn(option)
end

---@param args table Launch configuration.
---@param callback function? Receives the suspended process before it resumes.
---@return table? process Spawned process, or nil with an error message.
---@return string? err Human-readable reason on failure.
local function create_process_in_console(args, callback)
    local need_resume = platform_os() == 'windows'
    initialize(args)
    local process, err = sp.spawn({
        args.runtimeExecutable,
        args.runtimeArgs,
        env = args.env,
        console = 'new',
        cwd = args.cwd or fs.path(args.runtimeExecutable):parent_path(),
        suspended = true,
        searchPath = true,
    })
    if not process then
        return nil, err
    end
    if args.inject ~= 'none' then
        local ok, errmsg = process_inject.inject(process, 'launch', args)
        if not ok then
            -- The child is spawned but injection failed: never leave it
            -- behind. Kill it if it is still running, then always reap it
            -- with wait() so no zombie (or suspended-forever child on
            -- Windows) lingers; the caller still sees the injection error.
            local already_exited = not process:is_running()
            if not already_exited then
                process:kill()
            end
            process:wait()
            if already_exited then
                return nil, 'process is already exited:\n' .. errmsg
            end
            return nil, errmsg
        end
    end
    if callback then
        callback(process)
    end
    if need_resume then
        process:resume()
    end
    return process
end

---@param client table DAP client handle (for capability probing).
---@param args table Launch configuration.
---@return table option `runInTerminal` arguments for the editor.
local function create_process_in_terminal(client, args)
    initialize(args)
    local arguments = {}
    if useWSL then
        arguments[#arguments + 1] = 'wsl'
    end
    arguments[#arguments + 1] = args.runtimeExecutable
    if type(args.runtimeArgs) == 'string' then
        arguments[#arguments + 1] = args.runtimeArgs
    elseif type(args.runtimeArgs) == 'table' then
        for _, v in ipairs(args.runtimeArgs) do
            arguments[#arguments + 1] = v
        end
    end
    local option = {
        kind = (args.console == 'integratedTerminal') and 'integrated' or 'external',
        title = args.name,
        env = args.env,
        cwd = args.cwd or fs.path(args.runtimeExecutable):parent_path(),
        args = arguments,
        -- The initialize request may carry no `arguments`; read the flag
        -- defensively so a bare initialize cannot crash the launch.
        argsCanBeInterpretedByShell = client ~= nil
            and client.arguments ~= nil
            and client.arguments.supportsArgsCanBeInterpretedByShell
            and type(args.runtimeArgs) == 'string',
    }
    return option
end

return {
    create_luaexe_in_console = create_luaexe_in_console,
    create_luaexe_in_terminal = create_luaexe_in_terminal,
    create_process_in_console = create_process_in_console,
    create_process_in_terminal = create_process_in_terminal,
}
