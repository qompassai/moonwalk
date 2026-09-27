-- backend/worker/stepintargets.lua
--
-- DAP `stepInTargets` provider. Reads the current source line of the
-- paused frame and extracts the call expressions on it, so the editor can
-- offer "step into which call?" when a line holds several. This is purely
-- syntactic (Lua patterns, no full parse): it finds `name(` / `name.method(`
-- / `obj:method(` shapes and reports each distinct callee once, in source
-- order. Best-effort by design -- a callee split across lines or built at
-- runtime is not listed, and stepping into a chosen target degrades to a
-- plain step-in (see worker.lua CMD.stepIn).

local rdebug = require('luadebug.visitor')

local TARGET_MAX = 16
local LINE_SCAN_MAX = 4096

local info = {}

---@param path string Server-side source path.
---@param lineno integer 1-based line number.
---@return string? line Raw line text, or nil when unreadable.
local function read_line(path, lineno)
    local f = io.open(path, 'r')
    if not f then
        return nil
    end
    local line
    for i = 1, math.min(lineno, LINE_SCAN_MAX) do
        line = f:read('l')
        if line == nil then
            break
        end
    end
    f:close()
    if lineno > LINE_SCAN_MAX then
        return nil
    end
    return line
end

---@param text string Chunk text that is not backed by a file.
---@param lineno integer 1-based line number.
---@return string? line Raw line text, or nil.
local function text_line(text, lineno)
    local pos = 1
    for i = 1, lineno do
        local eol = text:find('\n', pos, true)
        if i == lineno then
            return text:sub(pos, eol and (eol - 1) or #text)
        end
        if not eol then
            return nil
        end
        pos = eol + 1
    end
    return nil
end

---@param source string Raw chunk identifier from debug info.
---@param lineno integer Current line in debuggee coordinates.
---@return string? line Raw line text, or nil when it cannot be recovered.
local function current_line_text(source, lineno)
    local h = source:sub(1, 1)
    if h == '@' then
        return read_line(source:sub(2), lineno)
    elseif h == '=' then
        return nil
    end
    -- Inline chunk: either `--@path:line\n...` or raw text.
    local content = source:match('^--@[^:]+:%d+\n(.*)$')
    if content then
        -- The `--@path:line` header occupies debuggee line 1, so content
        -- line 1 is debuggee line 2 (cf. source.line: editor = current +
        -- startline - 2). A currentline of 1 (the header itself) yields nil.
        return text_line(content, lineno - 1)
    end
    return text_line(source, lineno)
end

---@param line string Raw source line text.
---@return table targets DAP StepInTarget list ({id=integer, label=string}).
local function parse_targets(line)
    local seen = {}
    local targets = {}
    -- Strip line comments and string literals so `foo(` inside them does
    -- not become a phantom target. Deliberately shallow.
    local code = line:gsub('%-%-.*$', '')
    code = code:gsub([["(.-)"]], '""')
    code = code:gsub([['(.-)']], "''")
    for callee in code:gmatch('([%a_][%w_%.%:]*)%s*%(') do
        if not seen[callee] and #targets < TARGET_MAX then
            seen[callee] = true
            targets[#targets + 1] = {
                id = #targets + 1,
                label = callee,
            }
        end
    end
    return targets
end

local m = {}

---@param depth integer Worker-local stack level of the paused frame.
---@return table targets DAP StepInTarget list, possibly empty.
function m.targets(depth)
    if not rdebug.getinfo(depth, 'Sl', info) then
        return {}
    end
    if info.what == 'C' then
        return {}
    end
    local line = current_line_text(info.source, info.currentline)
    if not line then
        return {}
    end
    return parse_targets(line)
end

return m
