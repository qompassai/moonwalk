-- Finds every test binary under the build tree and runs each one as a
-- subprocess; the process exits non-zero if any test fails, cannot run,
-- or if discovery finds nothing at all.
--
-- A green run with zero discovered tests is a broken build rule, not a
-- passing suite: fail closed on zero, and on fewer than the committed
-- per-OS minimum derived from compile/test/make.lua
-- (test_frida, test_delayload, test_symbol, test_thunk everywhere;
-- testwaitdll additionally on Windows). Override with the
-- MOONWALK_MIN_TESTS environment variable when the build legitimately
-- produces fewer (e.g. a missing optional submodule).

local fs = require('bee.filesystem')
local sp = require('bee.subprocess')
local platform_os = require('bee.platform').os

local COMMITTED_MIN_TESTS = {
    linux = 4,
    macos = 4,
    windows = 5,
}

local all_tests = {}
local function find_directory_test(dir)
    for file in fs.pairs(dir) do
        if fs.is_directory(file) then
            find_directory_test(file)
        else
            local filename = tostring(file:filename())
            local ext = file:extension()
            local name = tostring(filename)
            -- `test_*` binaries plus the `testwaitdll` helper: everything
            -- compile/test/make.lua builds as a test executable.
            local is_test = (name:find('test_', 1, true) or name:find('testwaitdll', 1, true))
                and (ext:find('.exe') or ext == '' or ext == nil)
            if is_test then
                table.insert(all_tests, tostring(file))
            end
        end
    end
end

find_directory_test('build')
-- Deterministic execution order keeps transcripts comparable.
table.sort(all_tests)

local min_tests = tonumber(os.getenv('MOONWALK_MIN_TESTS'))
    or COMMITTED_MIN_TESTS[platform_os]
    or 1

if #all_tests == 0 then
    io.stderr:write('interceptor: zero test binaries discovered under build/; refusing to pass an empty suite\n')
    os.exit(2)
end
if #all_tests < min_tests then
    io.stderr:write(
        ('interceptor: discovered %d test binaries, below the committed minimum %d for %s\n'):format(
            #all_tests,
            min_tests,
            platform_os
        )
    )
    os.exit(2)
end

local function run_tests()
    local res = true
    for i, test in ipairs(all_tests) do
        print(('%d/%d : %s'):format(i, #all_tests, test))
        local p, err = sp.spawn({
            test,
        })
        if not p then
            res = false
            print("can't run:", test, 'err:', err)
        else
            local ec = p:wait()
            if ec ~= 0 then
                print('test return not 0')
                res = false
            end
        end
    end
    return res
end

if not run_tests() then
    os.exit(1)
end
