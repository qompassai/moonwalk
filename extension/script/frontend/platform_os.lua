-- frontend/platform_os.lua
--
-- Answers "which OS are we debugging for?": normally the host OS, but under
-- WSL the debuggee sees Linux even though the adapter runs on Windows.
-- Calling the module returns the current answer; init() recomputes it from
-- the launch configuration.

local platform = require('bee.platform')

local m = {
    os = platform.os,
}

---@param args table Launch configuration; `useWSL` selects the WSL mapping.
function m.init(args)
    if platform.os == 'windows' and args.useWSL then
        m.os = 'linux'
        args.useWSL = true
        return
    end
    m.os = platform.os
    args.useWSL = nil
end

return setmetatable(m, {
    __call = function()
        return m.os
    end,
})
