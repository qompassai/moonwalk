-- backend/worker/filesystem.lua
--
-- Path translation layer between the editor (client paths) and the debuggee
-- (server paths). Handles the platform matrix: Windows vs POSIX separators,
-- WSL remapping, UTF-8 vs ANSI encoding, and case-insensitive comparison on
-- Windows/macOS. All comparisons go through the normalize helpers so the
-- rest of the backend never deals with raw platform paths.

local fs = require('bee.filesystem')
local sys = require('bee.sys')
local has_windows, windows = pcall(require, 'bee.windows')
local ev = require('backend.event')
local u2a = has_windows and windows.u2a or function(...)
    return ...
end
local a2u = has_windows and windows.a2u or function(...)
    return ...
end

local isWindows = package.config:sub(1, 1) == '\\'
local sourceFormat = isWindows and 'path' or 'linuxpath'
local pathFormat = 'path'
local useWSL = false
local useUtf8 = false

local function towsl(s)
    if not useWSL or not s:match('^%a:') then
        return s
    end
    return s:gsub('\\', '/'):gsub('^(%a):', function(c)
        return '/mnt/' .. c:lower()
    end)
end

local function nativepath(s)
    if not useWSL and not useUtf8 then
        return u2a(s)
    end
    return towsl(s)
end

ev.on('initializing', function(config)
    sourceFormat = config.sourceFormat or (isWindows and 'path' or 'linuxpath')
    pathFormat = config.pathFormat or 'path'
    useWSL = config.useWSL
    useUtf8 = config.sourceCoding == 'utf8'
end)

local function normalize_posix(p)
    local stack = {}
    p:gsub('[^/]*', function(w)
        if #w > 0 or #stack == 0 then
            if w == '..' and #stack ~= 0 and stack[#stack] ~= '..' then
                stack[#stack] = nil
            elseif w ~= '.' then
                stack[#stack + 1] = w
            end
        end
    end)
    return stack
end

local function normalize_win32(p)
    local stack = {}
    p:gsub('[^/\\]*', function(w)
        if #w > 0 or #stack == 0 then
            if w == '..' and #stack ~= 0 and stack[#stack] ~= '..' then
                stack[#stack] = nil
            elseif w ~= '.' then
                stack[#stack + 1] = w
            end
        end
    end)
    return stack
end

local m = {}

---@param s string WSL-style path.
---@return string path The equivalent Windows path, or s unchanged.
function m.fromwsl(s)
    if sourceFormat == 'string' then
        return s
    end
    if not useWSL or not s:match('^/mnt/%a') then
        return s
    end
    return s:gsub('^/mnt/(%a)', '%1:')
end

---@param s string Server-side source path.
---@return string path Canonical form for source comparison.
function m.source_native(s)
    return sourceFormat == 'path' and s:lower() or s
end

---@param s string Client-side path.
---@return string path Canonical form for client comparison.
function m.path_native(s)
    return pathFormat == 'path' and s:lower() or s
end

local function is_absolute(path)
    if sourceFormat == 'path' then
        return path:match('^%a:') ~= nil
    else
        return path:sub(1, 1) == '/'
    end
end

local function fs_absolute(path)
    if is_absolute(path) then
        return path
    end
    return fs.current_path():string() .. '/' .. path
end

---@param path string Server-side source path, absolute or relative.
---@return string path Normalized absolute path with forward slashes.
function m.source_normalize(path)
    if sourceFormat == 'string' then
        return path
    end
    local normalize = sourceFormat == 'path' and normalize_win32 or normalize_posix
    return table.concat(normalize(fs_absolute(path)), '/')
end

---@param path string Client-side path.
---@return string path Normalized path with forward slashes.
function m.path_normalize(path)
    local normalize = pathFormat == 'path' and normalize_win32 or normalize_posix
    return table.concat(normalize(path), '/')
end

---@param path string Absolute path to relativize.
---@param base string Absolute base path.
---@return string path `path` relative to `base`, or absolute when the
--- roots differ on Windows.
function m.path_relative(path, base)
    local normalize = pathFormat == 'path' and normalize_win32 or normalize_posix
    local equal = pathFormat == 'path'
            and function(a, b)
                return a:lower() == b:lower()
            end
        or function(a, b)
            return a == b
        end
    local rpath = normalize(path)
    local rbase = normalize(base)
    if pathFormat == 'path' and not equal(rpath[1], rbase[1]) then
        return table.concat(rpath, '/')
    end
    while #rpath > 0 and #rbase > 0 and equal(rpath[1], rbase[1]) do
        table.remove(rpath, 1)
        table.remove(rbase, 1)
    end
    if #rpath == 0 and #rbase == 0 then
        return './'
    end
    local s = {}
    for _ in ipairs(rbase) do
        s[#s + 1] = '..'
    end
    if #s == 0 then
        s[#s + 1] = '.'
    end
    for _, e in ipairs(rpath) do
        s[#s + 1] = e
    end
    return table.concat(s, '/')
end

---@param path string Client-side path.
---@return string name The final path component.
function m.path_filename(path)
    local normalize = pathFormat == 'path' and normalize_win32 or normalize_posix
    local paths = normalize(path)
    return paths[#paths]
end

---@return string path Absolute path of the debuggee executable.
function m.program_path()
    return sys.exe_path():string()
end

m.nativepath = nativepath
m.a2u = a2u

return m
