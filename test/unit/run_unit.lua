-- test/unit/run_unit.lua
--
-- Pure-Lua unit test runner: no native modules, no adapter process, no
-- editor. Each `*_test.lua` file in this directory returns an array of
-- test tables: `{ id = '...', kind = 'validation'|'adversarial', fn = function(ctx) ... end }`.
--
-- Fail-closed: zero discovered test files, zero tests, or zero assertions
-- is a failure, never a pass. Exit 0 only when every test passes.
--
-- Usage: `lua test/unit/run_unit.lua` or `luamake lua test/unit/run_unit.lua`
-- from the repository root.

local script_dir = (debug.getinfo(1, 'S').source:match('^@(.*/)') or './')

-- Make the real extension modules importable for the tests under this dir.
-- `common.*` resolves to the real implementation; backend modules are
-- stubbed per-test-file (see test/unit/stubs/).
package.path = script_dir .. '?.lua;'
    .. script_dir .. '?/init.lua;'
    .. 'extension/script/?.lua;'
    .. 'extension/script/?/init.lua;'
    .. package.path

local test_files = {}
do
    -- Portable directory scan without native modules.
    local p = io.popen(('ls -1 %s'):format(script_dir))
    if p then
        for name in p:lines() do
            if name:match('_test%.lua$') then
                table.insert(test_files, name)
            end
        end
        p:close()
    end
end
table.sort(test_files)

if #test_files == 0 then
    io.stderr:write('run_unit: zero test files discovered; refusing to pass an empty suite\n')
    os.exit(2)
end

local total, passed, failed = 0, 0, 0
local assertions = 0
local by_kind = { validation = { 0, 0 }, adversarial = { 0, 0 } }
local failures = {}

for _, file in ipairs(test_files) do
    local chunk, err = loadfile(script_dir .. file)
    if not chunk then
        failed = failed + 1
        failures[#failures + 1] = file .. ': load error: ' .. tostring(err)
    else
        local ok, tests = pcall(chunk)
        if not ok or type(tests) ~= 'table' then
            failed = failed + 1
            failures[#failures + 1] = file .. ': did not return a test table'
        else
            for _, t in ipairs(tests) do
                total = total + 1
                local ctx = {
                    assertions = 0,
                    check = function(self, cond, msg)
                        self.assertions = self.assertions + 1
                        assertions = assertions + 1
                        if not cond then
                            error(msg or 'assertion failed', 2)
                        end
                    end,
                }
                local tok, terr = pcall(t.fn, ctx)
                local kind = t.kind == 'adversarial' and 'adversarial' or 'validation'
                if tok and ctx.assertions > 0 then
                    passed = passed + 1
                    by_kind[kind][1] = by_kind[kind][1] + 1
                    io.write(('[PASS] %s\n'):format(t.id))
                else
                    failed = failed + 1
                    by_kind[kind][2] = by_kind[kind][2] + 1
                    local reason = tok and 'zero assertions' or tostring(terr)
                    failures[#failures + 1] = t.id .. ': ' .. reason
                    io.write(('[FAIL] %s: %s\n'):format(t.id, reason))
                end
            end
        end
    end
end

io.write(
    ('\nunit: %d/%d passed, %d assertions, validation %d/%d, adversarial %d/%d\n'):format(
        passed,
        total,
        assertions,
        by_kind.validation[1],
        by_kind.validation[1] + by_kind.validation[2],
        by_kind.adversarial[1],
        by_kind.adversarial[1] + by_kind.adversarial[2]
    )
)
if failed > 0 then
    io.write('failures:\n')
    for _, f in ipairs(failures) do
        io.write('  - ' .. f .. '\n')
    end
    os.exit(1)
end
if total == 0 or assertions == 0 then
    io.stderr:write('run_unit: zero tests or zero assertions executed; failing closed\n')
    os.exit(2)
end
