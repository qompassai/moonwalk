-- backend/worker/traceback.lua
--
-- Builds human-readable stack traces for the exception breakpoint path.
-- `traceback` walks the debuggee stack from the error site, resolves each
-- frame's function name (global lookup first, then debug info), and maps
-- internal source paths to the client-visible form via source.lua.

local rdebug = require('luadebug.visitor')
local hookmgr = require('luadebug.hookmgr')
local source = require('backend.worker.source')
local luaver = require('backend.worker.luaver')

local info = {}

-- Maximum source text kept in a frame label; longer sources are truncated
-- so one giant eval chunk cannot blow up the trace output.
local SHORT_SRC_MAXLEN = 60

---@param source_str string Raw source identifier ('@path', '=name', or chunk text).
---@param maxlen integer? Maximum label length.
---@return string label Short human-readable source label.
local function shortsrc(source_str, maxlen)
    maxlen = maxlen or SHORT_SRC_MAXLEN
    local type = source_str:sub(1, 1)
    if type == '=' then
        if #source_str <= maxlen then
            return source_str:sub(2)
        else
            return source_str:sub(2, maxlen)
        end
    elseif type == '@' then
        if #source_str <= maxlen then
            return source_str:sub(2)
        else
            return '...' .. source_str:sub(#source_str - maxlen + 5)
        end
    else
        local nl = source_str:find('\n')
        maxlen = maxlen - 15
        if #source_str < maxlen and nl == nil then
            return ('[string "%s"]'):format(source_str)
        else
            local n = #source_str
            if nl ~= nil then
                n = nl - 1
            end
            if n > maxlen then
                n = maxlen
            end
            return ('[string "%s..."]'):format(source_str:sub(1, n))
        end
    end
end

local function shortpath(path)
    local clientpath = source.clientPath(path)
    if clientpath:sub(1, 2) == './' and #clientpath > 2 then
        clientpath = clientpath:sub(3)
    end
    return shortsrc('@' .. clientpath)
end

local function getshortsrc(src)
    if src.sourceReference then
        local code = source.getCode(src.sourceReference)
        return shortsrc(code)
    elseif src.path then
        return shortpath(src.path)
    elseif src.skippath then
        return shortpath(src.skippath)
    elseif info.source:sub(1, 1) == '=' then
        return shortsrc(info.source)
    else
        -- Unreachable in practice: create() only yields sources starting
        -- with '@', '=', or inline '--@path:line' chunks, all handled above.
        return '<unknown>'
    end
end

-- Maximum table-nesting levels searched when resolving a function name;
-- keeps the global scan from wandering the whole object graph.
local FIND_FIELD_DEPTH_MAX = 2
-- Maximum hash entries scanned per table while resolving a function name.
local FIND_FIELD_SCAN_MAX = 5000

local function findfield(t, f, level)
    if level == 0 then
        return
    end
    local loct = rdebug.tablehashv(t, 0, FIND_FIELD_SCAN_MAX)
    for i = 1, #loct, 2 do
        local key, value = loct[i], loct[i + 1]
        local key_type, key_value = rdebug.value(key)
        if key_type == 'string' then
            if not (level == FIND_FIELD_DEPTH_MAX and key_value == '_G') then
                if rdebug.equal(value, f) then
                    return key_value
                end
                if rdebug.type(value) == 'table' then
                    local res = findfield(value, f, level - 1)
                    if res then
                        return key_value .. '.' .. res
                    end
                end
            end
        end
    end
end

local function pushglobalfuncname(f)
    if f ~= nil then
        return findfield(rdebug._G, f, FIND_FIELD_DEPTH_MAX)
    end
end

local function pushfuncname(f)
    local funcname = pushglobalfuncname(f)
    if funcname then
        return ("function '%s'"):format(funcname)
    elseif info.namewhat ~= '' then
        return ("%s '%s'"):format(info.namewhat, info.name)
    elseif info.what == 'main' then
        return 'main chunk'
    elseif info.what ~= 'C' then
        local src = source.create(info.source)
        return ('function <%s:%d>'):format(getshortsrc(src), source.line(src, info.linedefined))
    else
        return '?'
    end
end

local function getwhere(message)
    local f, l = message:find(':[-%d]+: ')
    if f and l then
        local where_path = message:sub(1, f - 1)
        local where_line = tonumber(message:sub(f + 1, l - 2))
        local where_src = source.create('@' .. where_path)
        message = message:sub(l + 1)
        return message, where_src, where_line
    end
    return message
end

-- Maximum stack levels walked while locating the first Lua frame; bounds
-- the scan even if the C stack is pathologically deep.
local STACK_SCAN_MAX = 10000

local function findfirstlua(message)
    local depth = 0
    while true do
        assert(depth <= STACK_SCAN_MAX)
        if not rdebug.getinfo(depth, 'Sl', info) then
            return -1
        end
        if info.what ~= 'C' then
            return depth, message
        end
        depth = depth + 1
    end
end

local function replacewhere(flags, error)
    local errormessage = rdebug.tostring(error)
    if flags[1] == 'syntax' then
        return findfirstlua(errormessage)
    end
    local message, where_src, where_line = getwhere(errormessage)
    if not where_src then
        return findfirstlua(message)
    end
    local depth = 0
    while true do
        assert(depth <= STACK_SCAN_MAX)
        if not rdebug.getinfo(depth, 'Sl', info) then
            return findfirstlua(message)
        end
        if info.what ~= 'C' then
            local src = source.create(info.source)
            if src == where_src and where_line == info.currentline then
                return depth,
                    ('%s:%d: %s'):format(
                        getshortsrc(where_src),
                        source.line(src, where_line),
                        message
                    )
            end
        end
        depth = depth + 1
    end
end

-- Frames shown before the trace is elided with a "(skipping N levels)" note.
local TRACE_FRAME_LIMIT = 21
-- Frames kept at the tail of an elided trace.
local TRACE_TAIL_KEEP = 10

local function traceback(flags, error)
    local s = {}
    local level, message = replacewhere(flags, error)
    if level < 0 then
        return -1
    end
    s[#s + 1] = 'stack traceback:'
    local last = hookmgr.stacklevel()
    local n1 = ((last - level) > TRACE_FRAME_LIMIT) and TRACE_TAIL_KEEP or -1
    local opt = luaver.LUAVERSION >= 52 and 'Slntf' or 'Slnf'
    local depth = level
    while rdebug.getinfo(depth, opt, info) do
        depth = depth + 1
        n1 = n1 - 1
        if n1 == 1 then
            local n = last - TRACE_TAIL_KEEP - depth
            s[#s + 1] = ('\n\t...\t(skipping %d levels)'):format(n)
            depth = last - TRACE_TAIL_KEEP
        else
            local src = source.create(info.source)
            s[#s + 1] = ('\n\t%s:'):format(getshortsrc(src))
            if info.currentline > 0 then
                s[#s + 1] = ('%d:'):format(source.line(src, info.currentline))
            end
            s[#s + 1] = ' in '
            s[#s + 1] = pushfuncname(info.func)
            if info.istailcall then
                s[#s + 1] = '\n\t(...tail calls...)'
            end
        end
    end
    return level, message, table.concat(s)
end

return {
    traceback = traceback,
    pushglobalfuncname = pushglobalfuncname,
}
