-- Moonwalk (lua-debug) test entry point.
-- On macOS it runs the inject/waitdll harnesses first, then the
-- interceptor that executes every built test binary.
local platform_os = require('bee.platform').os

if platform_os == 'macos' then
    require('test.load.test_macos')
    require('test.inject.inject_macos')
    require('test.waitdll')
end

require('test.interceptor')
