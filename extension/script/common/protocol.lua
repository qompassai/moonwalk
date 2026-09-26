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
--- (frame complete, header incomplete, or body incomplete) or consumes the
--- parsed header bytes off `s.bytes`, strictly shrinking the input.
---
--- Malformed framing never throws: zero/negative/non-integer/oversized
--- lengths and non-DAP bytes reset the reassembly state (dropping the
--- garbage) and return nil, so one bad frame cannot kill the adapter or
--- latch a bogus `length` that pins memory.
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
            -- Not a DAP frame: drop the garbage instead of latching it.
            s.bytes = ''
            s.length = nil
            return
        end
        s.bytes = s.bytes:sub(pos + 4)
        s.length = length
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
            return msg
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
