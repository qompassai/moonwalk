-- frontend/powershell.lua
--
-- Locates a PowerShell executable for the `attach by process name` path:
-- searches PATH for pwsh first, then Windows PowerShell, honoring PATHEXT.
-- Returns nil when neither is installed; the caller falls back to wmic.

local fs = require('bee.filesystem')

---@param s string Delimited string to split.
---@return table parts The non-empty fields.
local function split(s)
    local r = {}
    s:gsub('[^;]*', function(w)
        r[#r + 1] = w
    end)
    return r
end

local dirs = split(os.getenv('PATH') or '')
local exts = split(os.getenv('PATHEXT') or '')

---@param name string Executable name without extension.
---@return boolean found True when name exists in any PATH directory.
local function where(name)
    for _, dir in ipairs(dirs) do
        for _, ext in ipairs(exts) do
            if fs.exists(fs.path(dir) / (name .. ext)) then
                return true
            end
        end
    end
    return false
end

---@return string? name "pwsh" or "powershell", or nil when neither is found.
return function()
    for _, name in ipairs({ 'pwsh', 'powershell' }) do
        if where(name) then
            return name
        end
    end
    return nil
end
