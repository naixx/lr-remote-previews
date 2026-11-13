-- Reads the few tags of a DNG file that tell which photo it was made from. Pure Lua 5.1: no Lightroom imports,
-- no bit library (Lightroom's Lua has none), so it runs in unit tests.
--
--   DngReader.read(bytes) --> { byteOrder = 'II' | 'MM', dngVersion = '1.7.0.0' | nil,
--                               originalRawFileName = 'IMG_0001.ARW' | nil,
--                               originalWidth = 6000 | nil, originalHeight = 4000 | nil }
--
-- A DNG is a TIFF file; the tags read here sit in its first image file directory (IFD0):
--   DNGVersion               0xC612, 4 BYTEs
--   OriginalRawFileName      0xC68B, ASCII or BYTE (the DNG specification allows both), NUL-terminated
--   OriginalDefaultFinalSize 0xC791, 2 SHORTs or LONGs: width, height of the original's default final size
-- Both byte orders ('II' little-endian, 'MM' big-endian) are read. Returns nil plus a message for anything that
-- is not a well-formed TIFF, or when one of these tags has a type or count the specification does not allow.
local DngReader = {}

DngReader.TAG_DNG_VERSION = 0xC612
DngReader.TAG_ORIGINAL_RAW_FILE_NAME = 0xC68B
DngReader.TAG_ORIGINAL_DEFAULT_FINAL_SIZE = 0xC791

local TYPE_BYTE, TYPE_ASCII, TYPE_SHORT, TYPE_LONG, TYPE_UNDEFINED = 1, 2, 3, 4, 7
-- Bytes per value of every TIFF 6.0 field type.
local TYPE_SIZES = { 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8 }
local MAX_ENTRIES = 4096
local MAX_NAME_LENGTH = 4096

local function reader(data, littleEndian)
    local function u16(pos)
        local a, b = data:byte(pos, pos + 1)
        if not b then
            return nil
        end
        if littleEndian then
            return a + b * 256
        end
        return a * 256 + b
    end
    local function u32(pos)
        local a, b, c, d = data:byte(pos, pos + 3)
        if not d then
            return nil
        end
        if littleEndian then
            return a + b * 256 + c * 65536 + d * 16777216
        end
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    return u16, u32
end

-- Text of an ASCII/BYTE value: everything before the first NUL.
local function text(data, pos, count)
    local value = data:sub(pos, pos + count - 1)
    local nul = value:find('\0', 1, true)
    if nul then
        value = value:sub(1, nul - 1)
    end
    return value
end

-- Reads IFD0 of the TIFF/DNG in the string data. See the header for the result.
function DngReader.read(data)
    if type(data) ~= 'string' or #data < 8 then
        return nil, 'too short for a TIFF header'
    end
    local order = data:sub(1, 2)
    if order ~= 'II' and order ~= 'MM' then
        return nil, 'no TIFF byte order mark'
    end
    local u16, u32 = reader(data, order == 'II')
    if u16(3) ~= 42 then
        return nil, 'not a TIFF file (the magic number is not 42)'
    end
    local ifdOffset = u32(5)
    if ifdOffset < 8 or ifdOffset + 2 > #data then
        return nil, 'the first IFD lies outside the file'
    end
    local count = u16(ifdOffset + 1)
    if count == 0 or count > MAX_ENTRIES or ifdOffset + 2 + count * 12 > #data then
        return nil, 'the first IFD is empty or truncated'
    end

    local result = { byteOrder = order }
    for i = 0, count - 1 do
        local entry = ifdOffset + 2 + i * 12 + 1 -- 1-based position of the 12-byte entry
        local tag, fieldType, valueCount = u16(entry), u16(entry + 2), u32(entry + 4)
        if tag == DngReader.TAG_DNG_VERSION or tag == DngReader.TAG_ORIGINAL_RAW_FILE_NAME
            or tag == DngReader.TAG_ORIGINAL_DEFAULT_FINAL_SIZE then
            local size = TYPE_SIZES[fieldType]
            local name = string.format('tag 0x%04X', tag)
            if not size then
                return nil, name .. ' has an unknown field type ' .. fieldType
            end
            local total = size * valueCount
            local pos = entry + 8 -- values of up to 4 bytes sit in the entry itself
            if total > 4 then
                pos = u32(entry + 8) + 1
            end
            if valueCount == 0 or pos + total - 1 > #data then
                return nil, name .. ' points outside the file'
            end

            if tag == DngReader.TAG_DNG_VERSION then
                if fieldType ~= TYPE_BYTE or valueCount ~= 4 then
                    return nil, 'DNGVersion is not 4 bytes'
                end
                result.dngVersion = string.format('%d.%d.%d.%d', data:byte(pos, pos + 3))
            elseif tag == DngReader.TAG_ORIGINAL_RAW_FILE_NAME then
                if fieldType ~= TYPE_ASCII and fieldType ~= TYPE_BYTE and fieldType ~= TYPE_UNDEFINED then
                    return nil, 'OriginalRawFileName is not text'
                end
                if valueCount > MAX_NAME_LENGTH then
                    return nil, 'OriginalRawFileName is too long'
                end
                result.originalRawFileName = text(data, pos, valueCount)
            else
                if (fieldType ~= TYPE_SHORT and fieldType ~= TYPE_LONG) or valueCount ~= 2 then
                    return nil, 'OriginalDefaultFinalSize is not two SHORT or LONG values'
                end
                local read = fieldType == TYPE_SHORT and u16 or u32
                result.originalWidth, result.originalHeight = read(pos), read(pos + size)
            end
        end
    end
    return result
end

return DngReader
