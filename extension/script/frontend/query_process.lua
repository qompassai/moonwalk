-- frontend/query_process.lua
--
-- Lists process ids by executable name for "attach by process name": one
-- platform command per OS, chosen at load time. The PowerShell listing has
-- three header lines to skip; wmic has one.

local platform = require('bee.platform')
local COMMAND
local SKIP = 0
if platform.os == 'windows' then
    local pwsh = require('frontend.powershell')()
    if pwsh then
        COMMAND = pwsh
            .. ' -NoProfile -Command '
            .. '"Get-CimInstance Win32_Process | Select-Object Name,ProcessId"'
        SKIP = 3
    else
        COMMAND = 'wmic process get name,processid'
        SKIP = 1
    end
elseif platform.os == 'linux' then
    COMMAND = 'ps axww -o comm=,pid='
elseif platform.os == 'macos' then
    COMMAND = 'ps axww -o comm=,pid= -c'
else
    error('Unsupported OS:' .. platform.os)
end

---@param n string Executable name to match.
---@return table pids Process ids whose name equals n.
return function(n)
    local res = {}
    local f = assert(io.popen(COMMAND))
    for _ = 1, SKIP do
        f:read('l')
    end
    for line in f:lines() do
        local name, processid = line:match('^([^%s].*[^%s])%s+(%d+)%s*$')
        if n == name then
            res[#res + 1] = tonumber(processid)
        end
    end
    return res
end
