--- Validate and complete a debug configuration.
---
--- Mutates `config` in place (fills defaults, normalizes fields).
--- Returns true on success, or nil plus an error message when the
--- configuration is unusable; callers must turn the error into a DAP
--- error response instead of spawning anything.
---
--- @param config table Raw configuration table, mutated in place.
--- @return boolean|nil ok True when the configuration is usable.
--- @return string? err Human-readable reason when it is not.
local function resolve_config(config)
    -- Apply common defaults.
    config.type = 'lua'

    if config.request ~= 'attach' then
        config.request = 'launch'
    end

    if type(config.name) ~= 'string' then
        config.name = 'Not specified'
    end

    if type(config.cwd) ~= 'string' then
        if type(config.workspaceFolder) == 'string' then
            config.cwd = config.workspaceFolder
        end
    end

    if type(config.stopOnEntry) ~= 'boolean' then
        config.stopOnEntry = true
    end

    if type(config.stopOnThreadEntry) ~= 'boolean' then
        config.stopOnThreadEntry = false
    end

    if type(config.keepSessionAlive) ~= 'boolean' then
        config.keepSessionAlive = false
    end

    if type(config.luaVersion) ~= 'string' then
        config.luaVersion = 'lua54'
    end

    if type(config.console) ~= 'string' then
        config.console = 'internalConsole'
    end

    if type(config.sourceCoding) ~= 'string' then
        config.sourceCoding = 'utf8'
    end

    if type(config.outputCapture) ~= 'table' then
        if config.console == 'internalConsole' then
            config.outputCapture = {
                'print',
                'io.write',
                'stdout',
                'stderr',
            }
        else
            config.outputCapture = {}
        end
    end

    if type(config.pathFormat) ~= 'string' then
        if config.useWSL then
            config.pathFormat = 'path'
        else
            ---@NOTICE The backend cannot determine the frontend operating system,
            ---@NOTICE so it assumes it is the same as the backend operating system.
            local platform = require('bee.platform')

            if platform.os == 'windows' or platform.os == 'macos' then
                config.pathFormat = 'path'
            else
                config.pathFormat = 'linuxpath'
            end
        end
    end

    -- Validate sourceMaps. An invalid entry is a configuration error, not
    -- a crash: the caller turns this into a DAP error response before any
    -- debuggee is spawned.
    if type(config.sourceMaps) == 'table' then
        for _, sourceMap in ipairs(config.sourceMaps) do
            if type(sourceMap) ~= 'table' or #sourceMap ~= 2 then
                return nil, 'Invalid sourceMaps: each entry must be a [source, target] pair.'
            end
        end
    else
        config.sourceMaps = nil
    end

    -- Apply the default client mode.
    if type(config.address) == 'string' and type(config.client) ~= 'boolean' then
        config.client = true
    end

    -- Apply the default configuration.variables value. The backend cannot read
    -- VS Code settings, so an empty table is used instead. Both levels are
    -- defaulted: variables.lua dereferences config.configuration.variables,
    -- so a bare `configuration = {}` must not leave variables as nil.
    if type(config.configuration) ~= 'table' then
        config.configuration = {
            variables = {},
        }
    elseif type(config.configuration.variables) ~= 'table' then
        config.configuration.variables = {}
    end

    return true
end

return resolve_config
