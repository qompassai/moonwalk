-- common/base64.lua
--
-- Small self-contained base64 codec (no external dependencies).
--
-- Used by the backend to ferry binary variable data (e.g. memory slices)
-- through JSON DAP messages. Pure functions; behavior is defined by
-- RFC 4648.

local string_char = string.char
local string_byte = string.byte
local table_concat = table.concat
local pairs = pairs

local encoder = {}
local decoder = {}
for index, char in pairs({
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
    'g',
    'h',
    'i',
    'j',
    'k',
    'l',
    'm',
    'n',
    'o',
    'p',
    'q',
    'r',
    's',
    't',
    'u',
    'v',
    'w',
    'x',
    'y',
    'z',
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '+',
    '/',
}) do
    local sextet = index - 1
    local charcode = string_byte(char)
    encoder[sextet] = charcode
    decoder[charcode] = sextet
end

--- Encodes `data` to base64 with `=` padding.
---@param data string Raw bytes to encode.
---@return string encoded Base64 text.
local function encode(data)
    assert(type(data) == 'string')

    local chunks = {}
    local chunk_index = 1
    local tail_size = #data % 3
    for i = 1, #data - tail_size, 3 do
        local a, b, c = string_byte(data, i, i + 2)
        local v = a * 0x10000 + b * 0x100 + c
        chunks[chunk_index] = string_char(
            encoder[(v >> 18) & 0x3f],
            encoder[(v >> 12) & 0x3f],
            encoder[(v >> 6) & 0x3f],
            encoder[v & 0x3f]
        )
        chunk_index = chunk_index + 1
    end
    if tail_size == 2 then
        local a, b = string_byte(data, -2, -1)
        local v = a * 0x10000 + b * 0x100
        chunks[chunk_index] = string_char(
            encoder[(v >> 18) & 0x3f],
            encoder[(v >> 12) & 0x3f],
            encoder[(v >> 6) & 0x3f],
            61 --[[ "=" ]]
        )
    elseif tail_size == 1 then
        local v = string_byte(data, -1) * 0x10000
        chunks[chunk_index] = string_char(
            encoder[(v >> 18) & 0x3f],
            encoder[(v >> 12) & 0x3f],
            61, --[[ "=" ]]
            61 --[[ "=" ]]
        )
    end
    return table_concat(chunks)
end

--- Decodes base64 `data` back to raw bytes.
---@param data string Base64 text, optionally `=`-padded.
---@return string decoded Raw bytes.
local function decode(data)
    assert(type(data) == 'string')

    local chunks = {}
    local chunk_index = 1
    for i = 1, #data - 4, 4 do
        local a, b, c, d = string_byte(data, i, i + 3)
        local v = decoder[a] * 0x40000 + decoder[b] * 0x1000 + decoder[c] * 0x40 + decoder[d]
        chunks[chunk_index] = string_char(v >> 16, (v >> 8) & 0xFF, v & 0xFF)
        chunk_index = chunk_index + 1
    end
    local a, b, c, d = string_byte(data, -4, -1)
    if
        c == 61 --[[ "=" ]]
    then
        local v = (decoder[a] * 0x4) + (decoder[b] >> 4)
        chunks[chunk_index] = string_char(v)
    elseif
        d == 61 --[[ "=" ]]
    then
        local v = decoder[a] * 0x400 + decoder[b] * 0x10 + (decoder[c] >> 2)
        chunks[chunk_index] = string_char(v >> 8, v & 0xFF)
    elseif a ~= nil then
        local v = decoder[a] * 0x40000 + decoder[b] * 0x1000 + decoder[c] * 0x40 + decoder[d]
        chunks[chunk_index] = string_char(v >> 16, (v >> 8) & 0xFF, v & 0xFF)
    end
    return table_concat(chunks)
end

return {
    encode = encode,
    decode = decode,
}
