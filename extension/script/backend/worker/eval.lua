-- backend/worker/eval.lua
--
-- Front door for evaluating expressions inside the debugged process.
-- The actual evaluation chunks (readonly/readwrite/verify) are loaded with
-- rdebug.load so they execute in the debuggee's address space with access to
-- its locals and upvalues; this module only selects which chunk to run.
-- `ffi_reflect` is additionally memoized because building its FFI bridge is
-- expensive and the debuggee's type universe does not change mid-session.

local rdebug = require('luadebug.visitor')
local luaver = require('backend.worker.luaver')

local readfile = package.readfile
if not readfile then
    function readfile(filename)
        local fullpath = assert(package.searchpath(filename, package.path))
        local f = assert(io.open(fullpath))
        local str = f:read('a')
        f:close()
        return str
    end
end

local eval_readwrite = assert(rdebug.load(readfile('backend.worker.eval.readwrite')))
local eval_readonly = assert(rdebug.load(readfile('backend.worker.eval.readonly')))
local eval_verify = assert(rdebug.load(readfile('backend.worker.eval.verify')))

local m = {}

---@param expression string Lua expression, may assign to locals/upvalues.
---@param frameId integer Stack depth the expression is evaluated at.
---@return boolean ok
---@return any ... Result values, or an error message.
function m.readwrite(expression, frameId)
    return rdebug.watch(eval_readwrite, expression, frameId)
end

---@param expression string Lua expression, evaluated without side effects.
---@param frameId integer Stack depth the expression is evaluated at.
---@return boolean ok
---@return any ... Result values, or an error message.
function m.readonly(expression, frameId)
    return rdebug.watch(eval_readonly, expression, frameId)
end

---@param expression string Lua expression to evaluate.
---@param level integer? Stack level for symbol resolution; callers may omit it.
---@param symbol table? Extra name bindings injected into the chunk.
---@return boolean ok
---@return any ... Result values, or an error message.
function m.eval(expression, level, symbol)
    return rdebug.eval(eval_readonly, expression, level, symbol)
end

---@param expression string Lua expression to syntax-check only.
---@return boolean ok
---@return any ... No values on success, or an error message.
function m.verify(expression)
    return rdebug.eval(eval_verify, expression, 0)
end

local function generate(name, init)
    m[name] = function(...)
        local f = init()
        m[name] = f
        return f(...)
    end
end

generate('ffi_reflect', function()
    if not luaver.isjit then
        return
    end
    local handler = assert(rdebug.load(readfile('backend.worker.eval.ffi_reflect')))
    local ok, fn = rdebug.watch(handler)
    if not ok then
        return
    end
    require('backend.event').on('terminated', function()
        rdebug.eval(fn, 'clean')
    end)
    return function(name, ...)
        local method = (name == 'member' or name == 'annotated_member') and 'watch' or 'eval'
        local res = table.pack(rdebug[method](fn, name, ...))
        if not res[1] then
            return
        end
        return table.unpack(res, 2)
    end
end)

return m
