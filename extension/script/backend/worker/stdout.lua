-- backend/worker/stdout.lua
--
-- Forwards one captured stdout chunk from the debuggee to the editor as a
-- DAP `output` event. ANSI SGR color codes in the text are re-based onto the
-- currently active style so colors survive chunked delivery: each chunk is
-- prefixed with the escape sequence that reproduces the style state left
-- behind by the previous chunk.

local source = require('backend.worker.source')
local ev = require('backend.event')

local foreground
local background
local bright
local underline
local negative

local function split(str)
    local r = {}
    str:gsub('[^;]+', function(w)
        r[#r + 1] = tonumber(w)
    end)
    return r
end

local function vtmode(text)
    local vt = {}
    if foreground then
        vt[#vt + 1] = foreground
    end
    if background then
        vt[#vt + 1] = background
    end
    if bright then
        vt[#vt + 1] = '1'
    end
    if underline then
        vt[#vt + 1] = '4'
    end
    if negative then
        vt[#vt + 1] = '7'
    end
    for vtstr in text:gmatch('\x1b%[([0-9;]+)m') do
        local codes = split(vtstr)
        local n = 1
        while n <= #codes do
            local code = codes[n]
            if code == 0 then
                -- SGR 0: reset all attributes
                foreground = nil
                background = nil
                bright = nil
                underline = nil
                negative = nil
            elseif code == 1 then
                -- SGR 1: bright/bold on
                bright = true
            elseif code == 4 then
                -- SGR 4: underline on
                underline = true
            elseif code == 24 then
                -- SGR 24: underline off
                underline = false
            elseif code == 7 then
                -- SGR 7: reverse video on
                negative = true
            elseif code == 27 then
                -- SGR 27: reverse video off
                negative = false
            elseif (code >= 30 and code <= 37) or (code >= 90 and code <= 97) then
                -- SGR 30-37/90-97: foreground color
                foreground = tostring(code)
            elseif (code >= 40 and code <= 47) or (code >= 100 and code <= 107) then
                -- SGR 40-47/100-107: background color
                background = tostring(code)
            elseif code == 39 then
                -- SGR 39: default foreground
                foreground = nil
            elseif code == 38 then
                -- SGR 38: extended foreground color (takes 2 more params)
                if n + 2 <= #codes then
                    foreground = codes[n] .. ';' .. codes[n + 1] .. ';' .. codes[n + 2]
                    n = n + 2
                end
            elseif code == 48 then
                -- SGR 48: extended background color (takes 2 more params)
                if n + 2 <= #codes then
                    background = codes[n] .. ';' .. codes[n + 1] .. ';' .. codes[n + 2]
                    n = n + 2
                end
            end
            n = n + 1
        end
    end
    if #vt > 0 then
        return '\x1b[' .. table.concat(vt, ';') .. 'm' .. text
    end
    return text
end

---@param message string Raw stdout text from the debuggee.
---@param info table Debug info of the frame that produced the output.
return function(message, info)
    local src = source.create(info.source)
    if source.valid(src) then
        ev.emit('output', {
            category = 'stdout',
            output = vtmode(message),
            source = {
                name = src.name,
                path = src.path,
                sourceReference = src.sourceReference,
            },
            line = source.line(src, info.currentline),
        })
    else
        ev.emit('output', {
            category = 'stdout',
            output = vtmode(message),
        })
    end
end
