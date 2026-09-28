-- common/protocol.lua
--
-- DAP wire framing: `Content-Length` header parsing and JSON body
-- encoding/decoding.
--
-- Wire code: restyle conservatively, never change what goes on the wire.
-- The `'Content-Length: '` prefix, the `\r\n\r\n` separator, and the JSON
-- payload shape are protocol constants; only comments may be edited.

local json = require('common.json')

local m = {}

-- A single DAP message is normally a few KB; 16MB is already pathological
-- (a 100MB `evaluate` result would stall the adapter pump with zero
-- backpressure). Anything bigger is rejected at the header so the
-- reassembly buffer can never grow without bound.
local FRAME_MAX = 16 * 1024 * 1024

-- A valid header is ~25 bytes; without the `\r\n\r\n` separator in the
-- first 8KB the peer is not speaking DAP and the bytes are dropped.
local HEADER_MAX = 8192

--- Feeds `bytes` into the reassembly state `s` and returns one complete
--- payload when a full frame has arrived, or nil when more data is needed.
---
--- The `while true` loop always terminates: every iteration either returns
--- (frame complete, header incomplete, or body incomplete) or strictly
--- shrinks `s.bytes` -- by consuming a parsed header, or by dropping a
--- garbage prefix that precedes a valid header start.
---
--- Malformed framing never throws: zero/negative/non-integer/oversized
--- lengths and non-DAP bytes are dropped and return nil. A garbage prefix
--- before a valid header is skipped -- the header is kept, not eaten with
--- the garbage -- so one bad chunk cannot wedge the stream: the next valid
--- frame still decodes, and no bogus `length` is ever latched.
---@param s table Reassembly state; mutated in place (`bytes`, `length`).
---@param bytes string Newly arrived raw bytes; nil means "drain only".
---@return string|nil payload One complete JSON payload, if available.
local function recv(s, bytes)
    bytes = bytes or ''
    s.bytes = s.bytes and (s.bytes .. bytes) or bytes
    while true do
        if s.length then
            if s.length <= #s.bytes then
                local res = s.bytes:sub(1, s.length)
                s.bytes = s.bytes:sub(s.length + 1)
                s.length = nil
                return res
            end
            return
        end
        -- A DAP header can only start at byte 1, so when the buffer does
        -- not start with one, scan for a header start later in the buffer
        -- and drop the garbage before it. Without this, a single
        -- non-terminated garbage prefix makes the following valid header
        -- fail the prefix check: the old code then skipped past that
        -- header's separator, eating a good header as garbage, and every
        -- later frame wedged the same way (recovery only via the 8 KiB
        -- header cap). Dropping bytes before a found header start is safe:
        -- they can never become a valid header. With no header start in
        -- the buffer, either more bytes are still arriving (wait) or the
        -- peer is not speaking DAP (drop at the cap, as before).
        if s.bytes:sub(1, 16) ~= 'Content-Length: ' then
            local hdr = s.bytes:find('Content-Length: ', 2, true)
            if hdr then
                s.bytes = s.bytes:sub(hdr)
            elseif #s.bytes > HEADER_MAX then
                s.bytes = ''
                return
            else
                return
            end
        end
        local pos = s.bytes:find('\r\n\r\n', 1, true)
        if not pos then
            if #s.bytes > HEADER_MAX then
                s.bytes = ''
            end
            return
        end
        local length = tonumber(s.bytes:sub(17, pos - 1))
        if
            pos <= 15
            or s.bytes:sub(1, 16) ~= 'Content-Length: '
            or not length
            or length < 1
            or length ~= math.floor(length)
            or length > FRAME_MAX
        then
            -- Not a DAP frame: skip past the bad separator and rescan, so
            -- valid frames already sitting in the same read are not lost
            -- with the garbage. The loop always terminates: each pass
            -- strictly shrinks s.bytes. (The garbage pre-scan above
            -- guarantees the `Content-Length: ` prefix here, so the
            -- prefix/pos checks below are defensive; only a malformed
            -- length can still reach this branch.)
            s.bytes = s.bytes:sub(pos + 4)
            s.length = nil
        else
            s.bytes = s.bytes:sub(pos + 4)
            s.length = length
        end
    end
end

--- Decodes one DAP message from `bytes` appended to `stat`'s buffer.
---
--- A body that is not valid JSON is dropped (nil) instead of throwing:
--- a corrupt frame must not kill the adapter.
---@param bytes string Raw bytes just read from the transport.
---@param stat table Per-connection state; carries the reassembly buffer.
---@return table|nil message Decoded DAP message, or nil if incomplete.
function m.recv(bytes, stat)
    local pkg = recv(stat, bytes)
    if pkg then
        if stat.debug then
            print('[recv]', pkg)
        end
        local ok, msg = pcall(json.decode, pkg)
        if ok then
            -- A DAP message is always a JSON object. A bare number, bool,
            -- or null decodes fine but is not a message; proxy.send()
            -- indexes pkg.type, so letting one through is a one-frame
            -- remote DoS of the whole session. Drop it here.
            if type(msg) == 'table' then
                return msg
            end
            if stat.debug then
                print('[recv] dropped non-table JSON frame')
            end
            return nil
        end
        if stat.debug then
            print('[recv] dropped malformed JSON frame')
        end
    end
end

--- Encodes a DAP message into a wire frame ready to write to the transport.
---@param cmd table DAP message (request/response/event).
---@param stat table Per-connection state; `debug` enables frame logging.
---@return string frame `Content-Length`-framed JSON payload.
function m.send(cmd, stat)
    local pkg = json.encode(cmd)
    if stat.debug then
        print('[send]', pkg)
    end
    return ('Content-Length: %d\r\n\r\n%s'):format(#pkg, pkg)
end

return m
