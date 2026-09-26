-- backend/worker/source.lua
--
-- Registry mapping every chunk the debuggee loads to the source identity the
-- editor understands. File chunks map to client paths (via the filesystem
-- translation layer, honoring skipFiles/sourceMaps); inline or generated
-- chunks get a CRC-32 content hash as a numeric sourceReference. Results are
-- pooled so each unique source emits exactly one `loadedSource` event.

local fs = require('backend.worker.filesystem')
local ev = require('backend.event')
local crc32 = require('backend.worker.crc32')

local sourcePool = {}
local codePool = {}
local knownClientPath = {}
local skipFiles = {}
local sourceMaps = {}
local workspaceFolder = nil
local sourceUtf8 = true

-- Unbounded growth guard: every distinct chunk the debuggee loads lands in
-- these pools, so a debuggee that generates code in a loop would otherwise
-- pin memory for the whole session. Past the cap the oldest entries are
-- evicted FIFO-style; lookups for evicted entries simply miss.
local SOURCE_POOL_MAX = 4096
local CODE_POOL_MAX = 4096

local sourceOrder = {}
local codeOrder = {}
local sourceHead = 1
local sourceTail = 0
local codeHead = 1
local codeTail = 0
local sourceCount = 0
local codeCount = 0

-- Re-pack a FIFO once its head index has run far ahead: popping nils the
-- head slot, so without this the backing table's index range (and the
-- array part Lua reserves for it) would grow without bound.
local ORDER_COMPACT_AT = 65536

---@param order table FIFO being compacted.
---@param head integer Read position into `order`.
---@param tail integer Write position into `order`.
---@return table order
---@return integer head
---@return integer tail
local function compact_order(order, head, tail)
    local fresh = {}
    for i = head, tail do
        fresh[#fresh + 1] = order[i]
    end
    return fresh, 1, #fresh
end

---@param pool table Pool losing its oldest entry.
---@param order table FIFO of pool keys in insertion order.
---@param head integer Read position into `order`.
---@param tail integer Write position into `order`.
---@param count integer Live entry count of `pool`.
---@return integer head
---@return integer count
local function evict_oldest(pool, order, head, tail, count)
    while head <= tail do
        local key = order[head]
        order[head] = nil
        head = head + 1
        if pool[key] ~= nil then
            pool[key] = nil
            return head, count - 1
        end
    end
    return head, count
end

local function evict_source()
    sourceHead, sourceCount =
        evict_oldest(sourcePool, sourceOrder, sourceHead, sourceTail, sourceCount)
    if sourceHead > ORDER_COMPACT_AT then
        sourceOrder, sourceHead, sourceTail = compact_order(sourceOrder, sourceHead, sourceTail)
    end
end

local function evict_code()
    while codeHead <= codeTail do
        local ref = codeOrder[codeHead]
        codeOrder[codeHead] = nil
        codeHead = codeHead + 1
        local code = codePool[ref]
        if code ~= nil then
            codePool[ref] = nil
            codeCount = codeCount - 1
            -- Mirror m.removeCode: the sourcePool entry keyed by this
            -- chunk's text goes with it so the two pools stay consistent.
            if sourcePool[code] then
                sourcePool[code] = nil
                sourceCount = sourceCount - 1
            end
            if codeHead > ORDER_COMPACT_AT then
                codeOrder, codeHead, codeTail = compact_order(codeOrder, codeHead, codeTail)
            end
            return
        end
    end
end

local function makeSkipFile(pattern)
    pattern = pattern:gsub('%$%{([^}]*)%}', {
        exe = fs.program_path(),
    })
    local normalized = fs.source_native(fs.source_normalize(pattern))
    local escaped = normalized:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '.*')
    skipFiles[#skipFiles + 1] = ('^%s$'):format(escaped)
end

ev.on('initializing', function(config)
    workspaceFolder = config.workspaceFolder
    sourceUtf8 = config.sourceCoding == 'utf8'
    skipFiles = {}
    sourceMaps = {}
    if config.skipFiles then
        for _, pattern in ipairs(config.skipFiles) do
            makeSkipFile(pattern)
        end
    end
    if config.sourceMaps then
        for _, pattern in ipairs(config.sourceMaps) do
            local sm = {}
            local normalized = fs.source_native(fs.source_normalize(pattern[1]))
            sm[1] = ('^%s$'):format(normalized:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'))
            if sm[1]:find('%*') then
                sm[1] = sm[1]:gsub('%*', '().*')
            end
            sm[2] = fs.path_normalize(pattern[2])
            sourceMaps[#sourceMaps + 1] = sm
        end
    end
end)

ev.on('terminated', function()
    skipFiles = {}
    sourceMaps = {}
    workspaceFolder = nil
    -- Session-owned pools: drop everything so a long-lived worker does not
    -- carry the previous session's sources into the next one.
    sourcePool = {}
    codePool = {}
    sourceOrder = {}
    codeOrder = {}
    sourceHead = 1
    sourceTail = 0
    codeHead = 1
    codeTail = 0
    sourceCount = 0
    codeCount = 0
end)

local function glob_match(pattern, target)
    return target:match(pattern) ~= nil
end

local function glob_replace(pattern, path, nativePath)
    local res = table.pack(nativePath:match(pattern[1]))
    if res[1] == nil then
        return false
    end
    local sz = res[1]
    -- Function-form replacement: a `%` in the mapped path must stay
    -- literal instead of being read as a gsub capture reference.
    return pattern[2]:gsub('%*', function()
        return path:sub(sz)
    end)
end

local function convert_path(p)
    p = fs.fromwsl(p)
    local native = fs.path_native(fs.path_normalize(p))
    if knownClientPath[native] then
        p = knownClientPath[native]
        knownClientPath[native] = nil
    end
    return p
end

local function serverPathToClientPath(p)
    if not sourceUtf8 then
        p = fs.a2u(p)
    end
    local skip = false
    local path = fs.source_normalize(p)
    local nativePath = fs.source_native(path)
    for _, pattern in ipairs(skipFiles) do
        if glob_match(pattern, nativePath) then
            skip = true
            break
        end
    end
    for _, pattern in ipairs(sourceMaps) do
        local res = glob_replace(pattern, path, nativePath)
        if res then
            return skip, convert_path(res)
        end
    end
    -- TODO: decide whether sources with no mapping should be hidden from the
    -- editor instead of being passed through with their server path.
    return skip, convert_path(fs.source_normalize(p))
end

local function codeReference(s)
    local hash = crc32(s)
    while codePool[hash] do
        if codePool[hash] == s then
            return hash
        end
        hash = hash + 1
    end
    if codeCount >= CODE_POOL_MAX then
        evict_code()
    end
    codePool[hash] = s
    codeTail = codeTail + 1
    codeOrder[codeTail] = hash
    codeCount = codeCount + 1
    return hash
end

local function splitline(source)
    local path, line, content = source:match('^--@([^:]+):(%d+)\n(.*)$')
    if path and line and content then
        return path, tonumber(line), content
    end
    return source:sub(2)
end

local function create(source)
    local h = source:sub(1, 1)
    if h == '@' then
        local serverPath = source:sub(2)
        local skip, clientPath = serverPathToClientPath(serverPath)
        if skip then
            return {
                skippath = clientPath,
            }
        end
        return {
            path = clientPath,
            protos = {},
        }
    elseif h == '=' then
        -- Named non-file chunks (e.g. "=(EVAL)"): no file identity exists.
        return {}
    else
        local serverPath, line, content = splitline(source)
        if serverPath and line and content then
            local skip, clientPath = serverPathToClientPath(serverPath)
            if skip then
                return {
                    skippath = clientPath,
                }
            end
            return {
                path = clientPath,
                protos = {},
                startline = line,
                content = content,
            }
        end
        return {
            sourceReference = codeReference(source),
            protos = {},
        }
    end
end

local m = {}

---@param source string Raw chunk identifier from debug info ('@path', '=name', or text).
---@return table src Pooled source record; emits `loadedSource` on first sight.
function m.create(source)
    local src = sourcePool[source]
    if src then
        return src
    end
    if sourceCount >= SOURCE_POOL_MAX then
        evict_source()
    end
    local newSource = create(source)
    sourcePool[source] = newSource
    sourceTail = sourceTail + 1
    sourceOrder[sourceTail] = source
    sourceCount = sourceCount + 1
    ev.emit('loadedSource', 'new', newSource)
    return newSource
end

---@param clientsrc table Source record as the editor addressed it.
---@return table? sources Matching pooled sources, or nil when unknown yet.
function m.c2s(clientsrc)
    -- TODO: avoid the full pool scan by indexing sourcePool on the normalized
    -- client path at create() time.
    if clientsrc.sourceReference then
        local ref = clientsrc.sourceReference
        for _, source in pairs(sourcePool) do
            if source.sourceReference == ref then
                return { source }
            end
        end
    else
        local results = {}
        local nativepath = fs.path_native(fs.path_normalize(clientsrc.path))
        for _, source in pairs(sourcePool) do
            if
                source.path
                and not source.sourceReference
                and fs.path_native(fs.path_normalize(source.path)) == nativepath
            then
                source.path = clientsrc.path
                results[#results + 1] = source
            end
        end
        if #results == 0 then
            knownClientPath[nativepath] = clientsrc.path
            return
        end
        return results
    end
end

---@param s table Source record.
---@return boolean valid True when the editor can open it (path or reference).
function m.valid(s)
    return s.path ~= nil or s.sourceReference ~= nil
end

---@param s table Source record.
---@return table? dap DAP source object, or nil for non-openable sources.
function m.output(s)
    if s.sourceReference ~= nil then
        return {
            name = '<Memory>',
            sourceReference = s.sourceReference,
        }
    elseif s.path ~= nil then
        return {
            name = fs.path_filename(s.path),
            path = fs.path_normalize(s.path),
        }
    end
end

---@param s table Source record.
---@param currentline integer Line in debuggee coordinates.
---@return integer line Line in editor coordinates.
function m.line(s, currentline)
    if s.startline then
        return currentline + s.startline - 2
    end
    return currentline
end

---@param ref integer CRC-32 source reference.
---@return string? code Chunk text, or nil when evicted.
function m.getCode(ref)
    return codePool[ref]
end

---@param ref integer CRC-32 source reference to evict.
function m.removeCode(ref)
    local code = codePool[ref]
    if code == nil then
        return
    end
    if sourcePool[code] then
        sourcePool[code] = nil
        sourceCount = sourceCount - 1
    end
    codePool[ref] = nil
    codeCount = codeCount - 1
end

---@param p string Absolute server path.
---@return string path Editor-visible path, relative to the workspace when known.
function m.clientPath(p)
    if workspaceFolder then
        return fs.path_relative(p, workspaceFolder)
    end
    return fs.path_normalize(p)
end

function m.all_loaded()
    for _, source in pairs(sourcePool) do
        ev.emit('loadedSource', 'new', source)
    end
end

return m
