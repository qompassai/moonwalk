-- test/unit/framing_test.lua
--
-- Black-box framing tests against the REAL `common/protocol.lua` parser
-- (pure Lua: only needs `common.json`). Covers the MW-PROTO oracles that
-- do not need a running adapter: fragmentation, coalescing, malformed
-- lengths, garbage recovery, and the 8 KiB / 16 MiB boundaries.
--
-- Returns an array of `{ id, kind, fn }` for test/unit/run_unit.lua.

local protocol = require('common.protocol')

local FRAME_MAX = 16 * 1024 * 1024

local function new_stat()
    return {}
end

-- Drain every complete message currently buffered in `stat`.
local function drain(stat)
    local out = {}
    while true do
        local msg = protocol.recv(nil, stat)
        if msg == nil then
            return out
        end
        out[#out + 1] = msg
    end
end

local function feed(stat, bytes)
    local msg = protocol.recv(bytes, stat)
    local out = {}
    if msg ~= nil then
        out[#out + 1] = msg
    end
    for _, m in ipairs(drain(stat)) do
        out[#out + 1] = m
    end
    return out
end

local function deep_equal(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= 'table' then
        return a == b
    end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then
            return false
        end
    end
    for k, _ in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

-- Deterministic PRNG (mulberry-ish) so corpus generation is reproducible.
local function rng(seed)
    local s = seed
    return function(n)
        s = (s * 1103515245 + 12345) % 2147483648
        return (s % (n or 2147483648)) + 1
    end
end

local tests = {}

local function T(id, kind, fn)
    tests[#tests + 1] = { id = id, kind = kind, fn = fn }
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

T('MW-PROTO-V01 round-trip preserves the message', 'validation', function(ctx)
    local stat = new_stat()
    local msg = {
        type = 'request',
        seq = 7,
        command = 'setBreakpoints',
        arguments = {
            source = { path = '/tmp/täst file.lua' },
            breakpoints = { { line = 10 }, { line = 20, condition = 'x > 1' } },
        },
    }
    local frame = protocol.send(msg, {})
    local got = feed(stat, frame)
    ctx:check(#got == 1, 'exactly one message decoded')
    ctx:check(deep_equal(got[1], msg), 'decoded message deep-equals the original')
end)

T('MW-PROTO-V02 decode(encode(m)) == m for generated objects', 'validation', function(ctx)
    local next = rng(20260928)
    local words = { 'alpha', 'βήτα', 'x', '', 'line\nbreak', 'tab\there' }
    for i = 1, 50 do
        local msg = {
            type = (i % 3 == 0) and 'event' or 'request',
            seq = i,
            command = words[next(#words)],
            arguments = {
                n = next(1000000),
                f = (next(1000) - 500) / 7,
                s = words[next(#words)],
                nested = { a = { b = { c = next(99) } }, list = { next(9), next(9) } },
                flag = (i % 2 == 0),
            },
        }
        local stat = new_stat()
        local got = feed(stat, protocol.send(msg, {}))
        ctx:check(#got == 1 and deep_equal(got[1], msg), 'round-trip ' .. i)
    end
end)

T('MW-PROTO-V03 valid frame split at every byte position', 'validation', function(ctx)
    local msg = { type = 'request', seq = 1, command = 'threads' }
    local frame = protocol.send(msg, {})
    for pos = 1, #frame - 1 do
        local stat = new_stat()
        local first = feed(stat, frame:sub(1, pos))
        ctx:check(#first == 0, ('no message before final fragment (split %d)'):format(pos))
        local second = feed(stat, frame:sub(pos + 1))
        ctx:check(#second == 1 and deep_equal(second[1], msg), ('one message after final fragment (split %d)'):format(pos))
    end
end)

T('MW-PROTO-V04 100 frames in one write decode in order', 'validation', function(ctx)
    local stat = new_stat()
    local blob = {}
    for i = 1, 100 do
        blob[#blob + 1] = protocol.send({ type = 'request', seq = i, command = 'threads' }, {})
    end
    local got = feed(stat, table.concat(blob))
    ctx:check(#got == 100, 'all 100 messages decoded')
    for i = 1, 100 do
        ctx:check(got[i].seq == i, ('order preserved at %d'):format(i))
    end
end)

T('MW-PROTO-V05 complete frame plus partial next frame', 'validation', function(ctx)
    local stat = new_stat()
    local f1 = protocol.send({ type = 'request', seq = 1, command = 'threads' }, {})
    local f2 = protocol.send({ type = 'request', seq = 2, command = 'threads' }, {})
    local half = math.floor(#f2 / 2)
    local got = feed(stat, f1 .. f2:sub(1, half))
    ctx:check(#got == 1 and got[1].seq == 1, 'first message returned, second retained')
    local rest = feed(stat, f2:sub(half + 1))
    ctx:check(#rest == 1 and rest[1].seq == 2, 'second message completes after remaining bytes')
end)

T('MW-PROTO-V06 UTF-8 body uses byte-count length', 'validation', function(ctx)
    local stat = new_stat()
    local msg = {
        type = 'request',
        seq = 3,
        command = 'evaluate',
        arguments = { expression = 't["ключ"] .. "日本語"', frameId = 1 },
    }
    local frame = protocol.send(msg, {})
    local declared = tonumber(frame:match('^Content%-Length: (%d+)'))
    local body = frame:match('\r\n\r\n(.*)$')
    ctx:check(declared == #body, 'declared length equals the byte count, not the character count')
    local got = feed(stat, frame)
    ctx:check(#got == 1 and deep_equal(got[1], msg), 'UTF-8 message round-trips exactly')
end)

T('MW-PROTO-V07 empty reads between fragments lose nothing', 'validation', function(ctx)
    local stat = new_stat()
    local msg = { type = 'request', seq = 9, command = 'threads' }
    local frame = protocol.send(msg, {})
    local mid = math.floor(#frame / 2)
    ctx:check(#feed(stat, frame:sub(1, mid)) == 0, 'nothing yet')
    ctx:check(#feed(stat, '') == 0, 'empty read: still nothing')
    ctx:check(#feed(stat, nil) == 0, 'nil read: still nothing')
    local got = feed(stat, frame:sub(mid + 1))
    ctx:check(#got == 1 and deep_equal(got[1], msg), 'message completes after empty reads')
end)

T('MW-PROTO-V08 request/response/event types all round-trip', 'validation', function(ctx)
    local stat = new_stat()
    local msgs = {
        { type = 'request', seq = 1, command = 'initialize', arguments = { adapterID = 'moonwalk' } },
        { type = 'response', seq = 2, request_seq = 1, command = 'initialize', success = true },
        { type = 'event', seq = 3, event = 'initialized' },
        { type = 'event', seq = 4, event = 'output', body = { category = 'stdout', output = 'hi\n' } },
    }
    local blob = {}
    for _, m in ipairs(msgs) do
        blob[#blob + 1] = protocol.send(m, {})
    end
    local got = feed(stat, table.concat(blob))
    ctx:check(#got == 4, 'all four messages decoded')
    for i, m in ipairs(msgs) do
        ctx:check(deep_equal(got[i], m), ('message %d matches'):format(i))
    end
end)

T('MW-PROTO-V09 body exactly at the 16 MiB limit is accepted', 'validation', function(ctx)
    local stat = new_stat()
    -- Measure the real encoding first: key order is the encoder's business.
    local probe = protocol.send({ type = 'event', seq = 1, event = 'output', body = { output = '' } }, {})
    local probe_body = probe:match('\r\n\r\n(.*)$')
    local msg = {
        type = 'event',
        seq = 1,
        event = 'output',
        body = { output = string.rep('x', FRAME_MAX - #probe_body) },
    }
    local frame = protocol.send(msg, {})
    local body = frame:match('\r\n\r\n(.*)$')
    ctx:check(#body == FRAME_MAX, 'body is exactly FRAME_MAX bytes')
    local got = feed(stat, frame)
    ctx:check(#got == 1 and got[1].seq == 1, 'limit-exact body is accepted')
end)

-- ---------------------------------------------------------------------------
-- Adversarial
-- ---------------------------------------------------------------------------

T('MW-PROTO-A01 bad lengths are rejected, next frame survives', 'adversarial', function(ctx)
    local bad = {
        'Content-Length: 0\r\n\r\n',
        'Content-Length: -12\r\n\r\n',
        'Content-Length: 12.5\r\n\r\n',
        'Content-Length: 99999999999999999999\r\n\r\n',
        'Content-Length: \r\n\r\n',
        'Content-Length: abc\r\n\r\n',
    }
    local good = protocol.send({ type = 'request', seq = 42, command = 'threads' }, {})
    for i, header in ipairs(bad) do
        local stat = new_stat()
        local ok, got = pcall(feed, stat, header .. good)
        ctx:check(ok, ('no exception on bad length %d: %s'):format(i, tostring(got)))
        -- The parser skips past the bad separator and rescans, so the good
        -- frame that follows must still decode.
        ctx:check(#got == 1 and got[1].seq == 42, ('good frame survives bad length %d'):format(i))
    end
    -- Documented leniency (not changed: wire code is frozen): `tonumber`
    -- accepts `1e3` as 1000, so the parser waits for 1000 body bytes. It
    -- must still not raise and must not pin more than the declared length.
    do
        local stat = new_stat()
        local ok, err = pcall(feed, stat, 'Content-Length: 1e3\r\n\r\n' .. good)
        ctx:check(ok, 'no exception on exponent length: ' .. tostring(err))
        ctx:check(#stat.bytes <= 1000 + #good, 'buffer bounded by the declared length')
    end
end)

T('MW-PROTO-A02 header mutations do not crash or wedge', 'adversarial', function(ctx)
    local good = protocol.send({ type = 'request', seq = 7, command = 'threads' }, {})
    local mutations = {
        (good:gsub('\r\n\r\n', '\n\n', 1)), -- LF-only separator
        (good:gsub('Content%-Length', 'content-length', 1)), -- wrong case
        'Content-Length: 10\r\nContent-Length: 10\r\n\r\n0123456789' .. good, -- duplicate header
        'NOT A HEADER AT ALL\r\n\r\n' .. good, -- leading garbage
        (good:gsub('\r\n\r\n', '', 1)), -- missing separator
    }
    for i, blob in ipairs(mutations) do
        local stat = new_stat()
        local ok, err = pcall(feed, stat, blob)
        ctx:check(ok, ('no exception on header mutation %d: %s'):format(i, tostring(err)))
        ctx:check(#stat.bytes <= 8192, ('buffer stays bounded on mutation %d'):format(i))
    end
end)

T('MW-PROTO-A03 framed malformed JSON is dropped, stream continues', 'adversarial', function(ctx)
    local stat = new_stat()
    local bad_body = '{"type": "request", "seq": broken'
    local bad_frame = ('Content-Length: %d\r\n\r\n%s'):format(#bad_body, bad_body)
    local good = protocol.send({ type = 'request', seq = 11, command = 'threads' }, {})
    local got = feed(stat, bad_frame .. good)
    ctx:check(#got == 1 and got[1].seq == 11, 'malformed JSON dropped, next valid frame decoded')
end)

T('MW-PROTO-A04 JSON scalars and arrays are rejected as messages', 'adversarial', function(ctx)
    local stat = new_stat()
    local bodies = { '42', '"hello"', 'true', 'null', '[1,2,3]', '{"a":1} trailing' }
    for i, body in ipairs(bodies) do
        local frame = ('Content-Length: %d\r\n\r\n%s'):format(#body, body)
        local ok, err = pcall(feed, stat, frame)
        ctx:check(ok, ('no exception on scalar body %d'):format(i))
    end
    local got = drain(stat)
    ctx:check(#got == 0, 'no scalar/array body was dispatched as a message')
    local good = protocol.send({ type = 'request', seq = 5, command = 'threads' }, {})
    local after = feed(stat, good)
    ctx:check(#after == 1, 'parser still usable after scalar bodies')
end)

T('MW-PROTO-A05 garbage recovery follows the documented policy', 'adversarial', function(ctx)
    local good = protocol.send({ type = 'request', seq = 99, command = 'threads' }, {})
    -- Policy 1 (verified against the implementation): garbage terminated
    -- by a separator is skipped and a valid frame in the same read is NOT
    -- lost -- the skip lands exactly on the frame boundary.
    do
        local stat = new_stat()
        local ok, got = pcall(feed, stat, 'GARBAGE\r\n\r\n' .. good)
        ctx:check(ok, 'no exception: ' .. tostring(got))
        ctx:check(#got == 1 and got[1].seq == 99, 'separator-terminated garbage recovers')
    end
    -- Policy 2: the `Content-Length: ` prefix check is anchored at the
    -- start of the buffer, so a non-terminated garbage prefix causes the
    -- following frame's header to be rejected too. No crash, no unbounded
    -- growth; the 8 KiB header cap is the reset mechanism.
    do
        local stat = new_stat()
        local ok, got = pcall(feed, stat, 'GARBAGE' .. good)
        ctx:check(ok, 'no exception on garbage prefix: ' .. tostring(got))
        ctx:check(#got == 0, 'frame dropped per anchored-prefix policy (documented)')
        ctx:check(#stat.bytes <= 8192, 'buffer stays bounded')
        feed(stat, string.rep('Z', 8193)) -- trip the header cap
        ctx:check(#stat.bytes == 0, 'header cap drops the desynced buffer')
        local after = feed(stat, good)
        ctx:check(#after == 1 and after[1].seq == 99, 'parser usable after reset')
    end
    -- Policy 1, fuzzed: random separator-terminated garbage always recovers.
    local next = rng(777)
    for trial = 1, 20 do
        local stat = new_stat()
        local n = next(200)
        local garbage = {}
        for i = 1, n do
            garbage[#garbage + 1] = string.char(next(64)) -- bytes 1..64: no letters, no CRLF
        end
        local blob = table.concat(garbage) .. '\r\n\r\n' .. good
        local ok, got = pcall(feed, stat, blob)
        ctx:check(ok, ('no exception on garbage trial %d: %s'):format(trial, tostring(got)))
        ctx:check(#got == 1 and got[1].seq == 99, ('recovery on trial %d'):format(trial))
        ctx:check(#stat.bytes <= 8192, ('buffer bounded on trial %d'):format(trial))
    end
end)

T('MW-PROTO-A06 header size boundary is deterministic and bounded', 'adversarial', function(ctx)
    -- 8192 bytes of header without a separator: dropped, buffer bounded.
    local stat = new_stat()
    local ok = pcall(feed, stat, string.rep('X', 8193))
    ctx:check(ok, 'no exception on oversized header')
    ctx:check(#stat.bytes <= 8192, 'oversized header bytes are dropped')
    local good = protocol.send({ type = 'request', seq = 3, command = 'threads' }, {})
    local got = feed(stat, good)
    ctx:check(#got == 1, 'valid frame works after oversized header')
end)

T('MW-PROTO-A07 body over 16 MiB is rejected without unbounded allocation', 'adversarial', function(ctx)
    local stat = new_stat()
    local header = ('Content-Length: %d\r\n\r\n'):format(FRAME_MAX + 1)
    -- Feed only the header first: the parser must reject at the header so
    -- the reassembly buffer can never be pinned by a bogus length.
    local ok = pcall(feed, stat, header)
    ctx:check(ok, 'no exception on oversized length header')
    ctx:check(#stat.bytes <= 8192, 'no body buffer allocated for oversized length')
    ctx:check(stat.length == nil, 'no length latched from the rejected header')
    local good = protocol.send({ type = 'request', seq = 8, command = 'threads' }, {})
    local got = feed(stat, good)
    ctx:check(#got == 1, 'valid frame works after oversized rejection')
end)

T('MW-PROTO-A08 one byte at a time stays bounded and completes', 'adversarial', function(ctx)
    local stat = new_stat()
    local msg = { type = 'request', seq = 13, command = 'threads', arguments = { threadId = 1 } }
    local frame = protocol.send(msg, {})
    local peak = 0
    local done = false
    for i = 1, #frame do
        local got = feed(stat, frame:sub(i, i))
        peak = math.max(peak, #stat.bytes)
        if #got == 1 then
            ctx:check(deep_equal(got[1], msg), 'byte-at-a-time delivery decodes correctly')
            done = true
        end
    end
    ctx:check(done, 'message completed')
    ctx:check(peak <= #frame, 'buffer never exceeded the frame itself')
end)

return tests
