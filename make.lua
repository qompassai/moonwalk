-- Moonwalk (lua-debug) build entry point, driven by luamake.
-- Dispatches to the platform-specific make module, or to the test make
-- module when luamake runs with its test flag.
local lm = require('luamake')

require('compile.common.detect_platform')
require('compile.common.config')

if lm.test then
    require('compile.test.make')
    return
end

require('compile.common.make')

if lm.os == 'windows' then
    require('compile.windows.make')
elseif lm.os == 'macos' then
    require('compile.macos.make')
else
    require('compile.linux.make')
end
