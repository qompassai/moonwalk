-- backend/worker/modules.lua
--
-- DAP `modules` provider. Enumerates `package.loaded` in the debuggee and
-- reports each loaded module with a stable numeric id. Versions are
-- best-effort: when the module table carries a string `_VERSION` field it
-- is reported, otherwise the version is omitted. Read-only; never executes
-- debuggee code.

local rdebug = require('luadebug.visitor')
local cancel = require('backend.worker.cancel')

local MODULE_SCAN_MAX = 512

local m = {}

---@return table modules DAP Module list, sorted by name.
function m.list()
    local modules = {}
    local pkg = rdebug.fieldv(rdebug._G, 'package')
    if pkg == nil then
        return modules
    end
    local loaded = rdebug.fieldv(pkg, 'loaded')
    if loaded == nil then
        return modules
    end
    -- Single bounded call, mirroring variables.lua's tablehash use; the
    -- index-window semantics of repeated calls are not established, so
    -- paging is deliberately not attempted here.
    local loct = rdebug.tablehash(loaded, 0, MODULE_SCAN_MAX)
    if loct then
        for i = 1, #loct, 3 do
            cancel.check()
            local ktype, kvalue = rdebug.value(loct[i])
            if ktype == 'string' and type(kvalue) == 'string' then
                local mod = {
                    name = kvalue,
                }
                -- loct[i + 1] is the module refvalue; fieldv works on it
                -- directly, while rdebug.value would unwrap it.
                if rdebug.type(loct[i + 1]) == 'table' then
                    local ver = rdebug.fieldv(loct[i + 1], '_VERSION')
                    if ver ~= nil then
                        local vtype, vvalue = rdebug.value(ver)
                        if vtype == 'string' and type(vvalue) == 'string' then
                            mod.version = vvalue
                        end
                    end
                end
                modules[#modules + 1] = mod
            end
            if #modules >= MODULE_SCAN_MAX then
                break
            end
        end
    end
    table.sort(modules, function(a, b)
        return a.name < b.name
    end)
    for i, mod in ipairs(modules) do
        mod.id = i
    end
    return modules
end

return m
