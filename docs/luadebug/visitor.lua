---@meta

---
---@class refvalue
---A reference to one value in the debug target.
---

---
---@alias light-refvalue refvalue | string | number | integer | boolean | nil
---A value in the debug target that is immediate doubles as a direct value
---here; anything else is a reference to it.
---

---
---@class LuaDebugVisitor
---APIs in the debugger VM for reading and mutating the debug target's data
---and state.
---
---To avoid perturbing the debug target, luadebug holds its objects as little
---as possible: the visitor only records the path used to reach an object,
---and re-resolves that path each time the debugger VM needs the object.
---That is slower than holding the object directly, so every visitor
---accessor comes in two variants, for example getlocal and getlocalv.
---Accessors without the v suffix always return a userdata holding the
---object's path, resolving it on every access. Accessors with the v suffix
---copy values that can cross the VM boundary (number/integer/string/boolean
---and friends) into the debugger VM and return them directly; non-copyable
---values still come back as path-holding userdata.
---
---For read-only access the v accessors suffice and are faster; the non-v
---accessors are only needed when you intend to mutate the object.
---
local visitor = {}

---
---@type refvalue
---The global table. Equivalent to _G.
---
visitor._G = nil

---
---@type refvalue
---The registry. Equivalent to debug.getregistry().
---
visitor._REGISTRY = nil

---
---@param frame integer
---@param index integer
---@return string | nil
---@return refvalue
---A local variable. Equivalent to debug.getlocal(frame, index).
---
function visitor.getlocal(frame, index) end

---
---@param frame integer
---@param index integer
---@return string | nil
---@return light-refvalue
---A local variable. Equivalent to debug.getlocal(frame, index).
---
function visitor.getlocalv(frame, index) end

---
---@param f refvalue
---@param index integer
---@return string | nil
---@return light-refvalue
---An upvalue. Equivalent to debug.getupvalue(f, index).
---
function visitor.getupvalue(f, index) end

---
---@param f refvalue
---@param index integer
---@return string | nil
---@return light-refvalue
---An upvalue. Equivalent to debug.getupvalue(f, index).
---
function visitor.getupvaluev(f, index) end

---
---@param value refvalue
---@return refvalue
---The metatable. Equivalent to debug.getmetatable(value).
---
function visitor.getmetatable(value) end

---
---@param value refvalue
---@return light-refvalue
---The metatable. Equivalent to debug.getmetatable(value).
---
function visitor.getmetatablev(value) end

---
---@param ud refvalue
---@param index integer | nil
---@return refvalue
---The user value. Equivalent to debug.getuservalue(ud, index).
---
function visitor.getuservalue(ud, index) end

---
---@param ud refvalue
---@param index integer | nil
---@return light-refvalue
---The user value. Equivalent to debug.getuservalue(ud, index).
---
function visitor.getuservaluev(ud, index) end

---
---@param t any
---@param key string
---@return refvalue
---Reads a table field; the key must be a string. Equivalent to t[key].
---
function visitor.field(t, key) end

---
---@param t any
---@param key string
---@return light-refvalue
---Reads a table field; the key must be a string. Equivalent to t[key].
---
function visitor.fieldv(t, key) end

---
---@param t any
---@param i? integer
---@param j? integer
---@return refvalue
---Returns the array part of the table from i to j as a flat array. For
---tablearray each element is a value/value(ref) pair; for tablearrayv each
---element is the value itself.
---
function visitor.tablearray(t, i, j) end

---
---@param t any
---@param i? integer
---@param j? integer
---@return light-refvalue
---Returns the array part of the table from i to j as a flat array. For
---tablearray each element is a value/value(ref) pair; for tablearrayv each
---element is the value itself.
---
function visitor.tablearrayv(t, i, j) end

---
---@param t any
---@param i? integer
---@param j? integer
---@return refvalue[]
---Returns the hash part of the table from i to j as a flat array. For
---tablehash each entry is a key/value/value(ref) triple; for tablehashv
---each entry is a key/value pair.
---
function visitor.tablehash(t, i, j) end

---
---@param t any
---@param i? integer
---@param j? integer
---@return light-refvalue[]
---Returns the hash part of the table from i to j as a flat array. For
---tablehash each entry is a key/value/value(ref) triple; for tablehashv
---each entry is a key/value pair.
---
function visitor.tablehashv(t, i, j) end

---
---@param t any
---@return integer
---@return integer
---Returns the array-part and hash-part sizes of the table.
---
function visitor.tablesize(t) end

---
---@param ud refvalue
---@param offset integer
---@param count integer
---@return string | nil
---Reads count bytes of userdata memory starting at offset.
---
function visitor.udread(ud, offset, count) end

---
---@param ud refvalue
---@param offset integer
---@param data string
---@param allowPartial boolean
---@return integer | boolean
---Writes data into userdata memory starting at offset; allowPartial permits
---a short write.
---
function visitor.udwrite(ud, offset, data, allowPartial) end

---
---@param v refvalue | light-refvalue
---@return string
---Returns the type of the value v refers to; differs slightly from type(v).
---  * If type(v) == "number", returns math.type(v); on targets below 5.3
---    returns "float".
---  * LUA_TLIGHTUSERDATA returns "lightuserdata".
---  * LUA_TNONE returns "unknown".
---  * A C function returns "c function".
---  * Everything else returns type(v).
---
function visitor.type(v) end

---
---@param v refvalue | light-refvalue
---@return string
---@return string | number | integer | boolean | nil
---Copies the value v refers to into the debugger VM; values that cannot be
---copied come back as a "lua_topointer(v)"-style string.
---
function visitor.value(v) end

---
---@param a refvalue | light-refvalue
---@param b refvalue | light-refvalue
---@return boolean
---Returns whether the values a and b refer to are equal.
---
function visitor.equal(a, b) end

---
---@param v refvalue | light-refvalue
---@return string
---Converts the value v refers to into a string.
---
function visitor.tostring(v) end

---
---@param v refvalue
---@param new light-refvalue
---@return boolean
---Assigns new's value to the value v refers to; returns whether it
---succeeded.
---
function visitor.assign(v, new) end

---
---@param frame integer | refvalue
---@param what string
---@param result table | nil
---@return table
---Returns a table of information about a function, filling and returning
---result when given. Equivalent to debug.getinfo(frame, what).
---
function visitor.getinfo(frame, what, result) end

---
---@param script string
---@return refvalue
---Loads script as a function inside the debug target and keeps it in the
---registry.
---
function visitor.load(script) end

---
---@param f any
---@vararg any
---@return boolean
---@return ...
---Calls f; on success the first return is true followed by registry
---references to f's results, on failure false and the error reason.
---
function visitor.watch(f, ...) end

---
---@param f any
---@vararg any
---@return boolean
---@return string | number | integer | boolean | nil
---Calls f; on success the first return is true followed by the first result
---passed through `visitor.value`, on failure false and the error reason.
---
function visitor.eval(f, ...) end

---
---Drops every reference created by visitor.watch.
---
function visitor.cleanwatch() end

---
---@param co refvalue
---@return string
---Returns "invalid" unless co is a thread, in which case it returns
---coroutine.status(co).
---
function visitor.costatus(co) end

---
---@return integer
---Equivalent to `collectgarbage "count"`.
---
function visitor.gccount() end

---@class visitor.cfunctioninfo
---@field tostring string
---@field file_name string
---@field function_name string
---@field module_name string
---@field line_number string

---
---Tries to resolve a C function into its concrete symbol.
---@param fun refvalue
---@return visitor.cfunctioninfo?
---
function visitor.cfunctioninfo(fun) end

return visitor
