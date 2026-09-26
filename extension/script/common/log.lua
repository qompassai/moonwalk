-- common/log.lua
--
-- Tiny leveled file logger used by the debugger backend and frontend.
--
-- Levels are `trace < debug < info < warn < error < fatal`; messages below
-- `log.level` are dropped. Set `log.file` to a path to start writing,
-- `log.root` to shorten source paths in the output. Requiring this module
-- redirects the global `print` to `log.info` so stray prints land in the
-- log file instead of the DAP channel.

local log = {}

log.file = nil
log.level = 'trace'

local modes = {
    'trace',
    'debug',
    'info',
    'warn',
    'error',
    'fatal',
}

local levels = {}

-- Anchor wall-clock time to the monotonic clock so log timestamps stay
-- consistent even if the system clock jumps mid-session.
local origin = os.time() - os.clock()

---@param fmt string os.date format; `{ms}` expands to milliseconds.
---@return string timestamp Formatted local timestamp.
local function os_date(fmt)
    local seconds, fraction = math.modf(origin + os.clock())
    local date = os.date(fmt, seconds)
    ---@cast date string
    return date:gsub('{ms}', ('%03d'):format(math.floor(fraction * 1000)))
end

---@param x number Value to round.
---@param increment number|nil Round to multiples of this; defaults to 1.
---@return number rounded
local function round(x, increment)
    increment = increment or 1
    x = x / increment
    return (x > 0 and math.floor(x + 0.5) or math.ceil(x - 0.5)) * increment
end

--- Renders varargs as a space-joined string; floats are rounded to two
--- decimals so float noise does not spam the log.
---@param ... any Values to stringify.
---@return string rendered
local function packstring(...)
    local rendered = {}
    for i = 1, select('#', ...) do
        local x = select(i, ...)
        if math.type(x) == 'float' then
            x = round(x, 0.01)
        end
        rendered[#rendered + 1] = tostring(x)
    end
    return table.concat(rendered, ' ')
end

---@param info table debug.getinfo result with `source`/`short_src`.
---@return string path Source path relative to `log.root` when possible.
local function filename(info)
    local s = info.source
    if log.root and s:sub(1, 1) == '@' then
        s = s:gsub('\\', '/')
        if log.root == s:sub(2, 1 + #log.root) then
            return s:sub(3 + #log.root)
        end
    end
    return info.short_src
end

if log.root then
    log.root = log.root:gsub('\\', '/')
end

for i, name in ipairs(modes) do
    levels[name] = i
    log[name] = function(...)
        if i < levels[log.level] then
            return
        end
        if not log.file then
            return
        end
        local info = debug.getinfo(2, 'Sl')
        local msg = ('[%s][%s:%3d][%-5s]%s\n'):format(
            os_date('%Y-%m-%d %H:%M:%S:{ms}'),
            filename(info),
            info.currentline,
            name:upper(),
            packstring(...)
        )
        local fp = assert(io.open(log.file, 'a'))
        fp:write(msg)
        fp:close()
    end
end

log.print = print
print = log.info

return log
