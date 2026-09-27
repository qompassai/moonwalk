-- moonwalk/formatters.lua
--
-- User-extensible value formatters. The worker consults this registry when
-- rendering a variable (see backend/worker/variables.lua); the first
-- formatter whose predicate accepts the value wins, otherwise the builtin
-- rendering is used unchanged.
--
-- Usage (in your moonwalk init file, see moonwalk/user.lua):
--
--     local formatters = require('moonwalk.formatters')
--
--     -- Example 1: render epoch integers as ISO-8601 dates. The predicate
--     -- narrows to plausible timestamps so ordinary counters keep the
--     -- default rendering.
--     formatters.register(
--         function(value, vtype)
--             local is_int = vtype == 'integer' or vtype == 'number'
--             return is_int and value > 946684800 and value < 4102444800
--         end,
--         function(value)
--             return os.date('!%Y-%m-%dT%H:%M:%SZ', math.floor(value))
--         end
--     )
--
--     -- Example 2: squeeze long strings to a head/tail summary. The worker
--     -- passes the raw string; the renderer just returns text.
--     formatters.register(
--         function(value, vtype)
--             return vtype == 'string' and #value > 120
--         end,
--         function(value)
--             return ('"%s...%s" (%d chars)'):format(value:sub(1, 60), value:sub(-20), #value)
--         end
--     )
--
-- Safety: at most FORMATTER_MAX registrations; predicate and renderer run
-- inside pcall, so a broken formatter degrades to "no match" and is logged,
-- never fatal. Rendered text is truncated to RENDER_MAXLEN chars.

local log = require('common.log')

local FORMATTER_MAX = 32
local RENDER_MAXLEN = 512

local m = {}

---@type table[] Registrations: {predicate=function, renderer=function}.
local registry = {}

---@param predicate fun(value: any, vtype: string, context: string): boolean
---@param renderer fun(value: any, vtype: string, context: string): string
---@return boolean ok False when the registry is full or args are invalid.
function m.register(predicate, renderer)
    if type(predicate) ~= 'function' or type(renderer) ~= 'function' then
        return false
    end
    if #registry >= FORMATTER_MAX then
        log.error('moonwalk.formatters: registry full, ignoring registration')
        return false
    end
    registry[#registry + 1] = {
        predicate = predicate,
        renderer = renderer,
    }
    return true
end

---@return integer count
function m.count()
    return #registry
end

-- Load the user's init file (if any) on first use so registrations made
-- there are visible before the first variable is rendered.
local user_loaded = false
local function ensure_user()
    if not user_loaded then
        user_loaded = true
        require('moonwalk.user').load_once()
    end
end

---Try the registry for a custom rendering.
---@param value any Raw Lua value (string/number/boolean/table ref).
---@param vtype string Value type name as seen by the worker.
---@param context string Render context ('variables', 'watch', ...).
---@return string? text Custom rendering, or nil when nothing matched.
function m.format(value, vtype, context)
    ensure_user()
    if #registry == 0 then
        return nil
    end
    for _, entry in ipairs(registry) do
        local ok, matched = pcall(entry.predicate, value, vtype, context)
        if ok and matched then
            local rok, rendered = pcall(entry.renderer, value, vtype, context)
            if rok and type(rendered) == 'string' then
                if #rendered > RENDER_MAXLEN then
                    rendered = rendered:sub(1, RENDER_MAXLEN) .. '...'
                end
                return rendered
            end
            if not rok then
                log.error('moonwalk.formatters: renderer failed: ' .. tostring(rendered))
            end
            return nil
        elseif not ok then
            log.error('moonwalk.formatters: predicate failed: ' .. tostring(matched))
        end
    end
    return nil
end

return m
