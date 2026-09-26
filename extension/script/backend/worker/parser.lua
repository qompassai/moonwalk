-- backend/worker/parser.lua
--
-- Builds the line maps the worker uses to verify breakpoints: for every
-- function prototype it records which source lines actually hold executable
-- code (`activelines`) and which source lines each prototype spans
-- (`definelines`), then snaps every line to the next executable one. It
-- works from `string.dump` output parsed by undump.lua, so no debug hooks
-- are needed -- only the chunk text.

local undump = require('backend.worker.undump')

local version

---@param proto table Undumped function prototype.
---@param abs table Map of pc -> absolute line for -128 anchors.
---@param currentline integer Running line number.
---@param pc integer 0-based program counter.
---@return integer line Resolved absolute line number.
local function nextline(proto, abs, currentline, pc)
    local line = proto.lineinfo[pc]
    if line == -128 then
        return assert(abs[pc - 1])
    else
        return currentline + line
    end
end

---@param proto table Undumped function prototype.
---@return table activelines Set of executable line numbers.
local function getactivelines(proto)
    assert(version ~= nil)
    local l = {}
    if version >= 0x54 then
        local currentline = proto.linedefined
        local abs = {}
        for _, line in ipairs(proto.abslineinfo) do
            abs[line.pc] = line.line
        end
        local start = 1
        if proto.is_vararg > 0 then
            local OP_VARARGPREP = version >= 0x55 and 83 or 81
            assert(proto.code[1] & 0x7F == OP_VARARGPREP)
            currentline = nextline(proto, abs, currentline, 1)
            start = 2
        end
        for pc = start, #proto.lineinfo do
            currentline = nextline(proto, abs, currentline, pc)
            l[currentline] = true
        end
    else
        for _, line in ipairs(proto.lineinfo) do
            l[line] = true
        end
    end
    return l
end

local function calclineinfo(proto, lineinfo, si)
    local activelines = getactivelines(proto)
    local startLn = proto.linedefined
    local endLn = proto.lastlinedefined
    local key = startLn .. '-' .. endLn
    if endLn == 0 then
        startLn = 1
        for l in pairs(activelines) do
            endLn = math.max(endLn, l)
        end
    end
    for l in pairs(activelines) do
        si.activelines[l] = true
    end
    for l = startLn, endLn do
        si.definelines[l] = key
    end
    lineinfo[key] = activelines
    for i = 1, proto.sizep do
        calclineinfo(proto.p[i], lineinfo, si)
    end
end

local function nextActiveLine(si, line)
    local defines = si.definelines
    local actives = si.activelines
    local fn = defines[line]
    while actives[line] ~= true do
        if fn ~= defines[line] then
            return
        end
        line = line + 1
    end
    return line
end

local function normalize(lineinfo, si)
    local maxline = 0
    for l in pairs(si.definelines) do
        maxline = math.max(maxline, l)
    end
    for i = 1, maxline do
        lineinfo[i] = nextActiveLine(si, i)
    end
end

---@param content string Lua chunk text to analyze.
---@return table? lineinfo Map of line -> next executable line, or nil when
--- the chunk does not compile.
return function(content)
    local f, err = load(content)
    if not f then
        local log = require('common.log')
        log.error('ERROR:' .. err)
        return
    end
    local bin = string.dump(f)
    local cl, v = undump(bin)
    version = v
    local si = { activelines = {}, definelines = {} }
    local lineinfo = {}
    calclineinfo(cl.f, lineinfo, si)
    normalize(lineinfo, si)
    return lineinfo
end
