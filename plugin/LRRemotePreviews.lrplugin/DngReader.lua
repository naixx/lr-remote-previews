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
--
-- For comparing two DNGs (DngCompare) it also reads the structure the image data sits in:
--
--   DngReader.parse(bytes) --> { byteOrder, ifd0 = <directory>, raw = <directory> | nil, rawProblem = text | nil }
--   <directory> = { offset, entries = { <entry>, ... } (file order), byTag = { [tag] = <entry> } }
--   <entry>     = { tag, type, count, size (bytes of the value), pos (1-based position of the value) }
--
-- The raw image is the first SubIFD (tag 0x014A) of IFD0, as in the smart previews Lightroom and Adobe DNG
-- Converter write. DngReader.numbers, .text, .bytes, .sameValue read entries; DngReader.imageParts gives the
-- tiles (or strips) of a directory, checked to lie inside the file.
local DngReader = {}

DngReader.TAG_DNG_VERSION = 0xC612
DngReader.TAG_ORIGINAL_RAW_FILE_NAME = 0xC68B
DngReader.TAG_ORIGINAL_DEFAULT_FINAL_SIZE = 0xC791
DngReader.TAG_SUB_IFDS = 0x014A
DngReader.TAG_STRIP_OFFSETS = 0x0111
DngReader.TAG_STRIP_BYTE_COUNTS = 0x0117
DngReader.TAG_TILE_OFFSETS = 0x0144
DngReader.TAG_TILE_BYTE_COUNTS = 0x0145

local TYPE_BYTE, TYPE_ASCII, TYPE_SHORT, TYPE_LONG, TYPE_UNDEFINED = 1, 2, 3, 4, 7
local TYPE_SBYTE, TYPE_SSHORT, TYPE_SLONG, TYPE_RATIONAL, TYPE_SRATIONAL, TYPE_IFD = 6, 8, 9, 5, 10, 13
-- Bytes per value of every TIFF 6.0 field type, and IFD (13) from the TIFF technical notes.
local TYPE_SIZES = { 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4 }
-- Bytes of each number inside a value whose order depends on the byte order (rationals: each half).
local SWAP_UNITS = { [3] = 2, [4] = 4, [5] = 4, [8] = 2, [9] = 4, [10] = 4, [11] = 4, [12] = 8, [13] = 4 }
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

-- Structure ----------------------------------------------------------------------------------------------------

-- Reads the directory at offset (0-based). name is used in messages ('IFD0'). Every entry's value must lie inside
-- the file; an entry of a type this reader does not know keeps only its 4-byte value field.
local function readDirectory(data, u16, u32, offset, name)
    if type(offset) ~= 'number' or offset < 8 or offset + 2 > #data then
        return nil, name .. ' lies outside the file'
    end
    local count = u16(offset + 1)
    if count == 0 or count > MAX_ENTRIES or offset + 2 + count * 12 > #data then
        return nil, name .. ' is empty or truncated'
    end
    local directory = { offset = offset, entries = {}, byTag = {} }
    for i = 0, count - 1 do
        local at = offset + 2 + i * 12 + 1
        local entry = { tag = u16(at), type = u16(at + 2), count = u32(at + 4) }
        local unit = TYPE_SIZES[entry.type]
        if unit then
            entry.size = unit * entry.count
            entry.pos = at + 8
            if entry.size > 4 then
                entry.pos = u32(at + 8) + 1
            end
            if entry.pos + entry.size - 1 > #data then
                return nil, string.format('tag 0x%04X of %s points outside the file', entry.tag, name)
            end
        else
            entry.size, entry.pos = 4, at + 8
        end
        directory.entries[#directory.entries + 1] = entry
        if directory.byTag[entry.tag] == nil then
            directory.byTag[entry.tag] = entry
        end
    end
    return directory
end

-- See the header. Returns nil plus a message when the header or IFD0 cannot be read; a missing or unreadable raw
-- image directory is reported in rawProblem instead (raw is nil then).
function DngReader.parse(data)
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
    local ifd0, problem = readDirectory(data, u16, u32, u32(5), 'IFD0')
    if not ifd0 then
        return nil, problem
    end
    local parsed = { byteOrder = order, data = data, u16 = u16, u32 = u32, ifd0 = ifd0 }
    local subIfds = ifd0.byTag[DngReader.TAG_SUB_IFDS]
    local offsets = subIfds and DngReader.numbers(parsed, subIfds)
    if not offsets or #offsets == 0 then
        parsed.rawProblem = 'no raw image directory (IFD0 has no SubIFDs)'
    else
        parsed.raw, parsed.rawProblem = readDirectory(data, u16, u32, offsets[1], 'the raw image directory')
    end
    return parsed
end

-- The values of an entry of an integer type (BYTE, SHORT, LONG, IFD and their signed forms) as a list of numbers,
-- or nil for other types.
local INTEGER_TYPES = { [TYPE_BYTE] = true, [TYPE_SHORT] = true, [TYPE_LONG] = true, [TYPE_IFD] = true,
    [TYPE_SBYTE] = true, [TYPE_SSHORT] = true, [TYPE_SLONG] = true }

function DngReader.numbers(parsed, entry)
    local unit = TYPE_SIZES[entry.type]
    if not INTEGER_TYPES[entry.type] then
        return nil
    end
    local values = {}
    for i = 0, entry.count - 1 do
        local pos = entry.pos + i * unit
        local value
        if unit == 1 then
            value = parsed.data:byte(pos)
        elseif unit == 2 then
            value = parsed.u16(pos)
        else
            value = parsed.u32(pos)
        end
        if entry.type == TYPE_SBYTE and value >= 128 then
            value = value - 256
        elseif entry.type == TYPE_SSHORT and value >= 32768 then
            value = value - 65536
        elseif entry.type == TYPE_SLONG and value >= 2147483648 then
            value = value - 4294967296
        end
        values[#values + 1] = value
    end
    return values
end

-- The raw bytes of an entry's value.
function DngReader.bytes(parsed, entry)
    return parsed.data:sub(entry.pos, entry.pos + entry.size - 1)
end

-- The text of an ASCII (or BYTE) entry up to the first NUL.
function DngReader.text(parsed, entry)
    return text(parsed.data, entry.pos, entry.size)
end

-- A form of an entry's value that does not depend on the byte order: numbers of more than one byte are written
-- little-endian, and rationals as decimal fractions (so 35/100 and 7/20 are the same value).
local function canonical(parsed, entry)
    if entry.type == TYPE_RATIONAL or entry.type == TYPE_SRATIONAL then
        local values = {}
        for i = 0, entry.count - 1 do
            local num, den = parsed.u32(entry.pos + i * 8), parsed.u32(entry.pos + i * 8 + 4)
            if entry.type == TYPE_SRATIONAL then
                num = num >= 2147483648 and num - 4294967296 or num
                den = den >= 2147483648 and den - 4294967296 or den
            end
            values[#values + 1] = den == 0 and 'nan' or string.format('%.17g', num / den)
        end
        return entry.type .. ':' .. table.concat(values, ' ')
    end
    local bytes = DngReader.bytes(parsed, entry)
    local unit = SWAP_UNITS[entry.type]
    if unit and parsed.byteOrder == 'MM' and TYPE_SIZES[entry.type] then
        bytes = bytes:gsub(string.rep('.', unit), function(chunk)
            return chunk:reverse()
        end)
    end
    return entry.type .. ':' .. entry.count .. ':' .. bytes
end

-- True when two entries (of two parsed files, possibly of different byte orders) hold the same value. Integer
-- values of different types (a width as SHORT in one file and LONG in the other) count as the same.
function DngReader.sameValue(a, entryA, b, entryB)
    if entryA.type ~= entryB.type or entryA.count ~= entryB.count then
        local numbersA, numbersB = DngReader.numbers(a, entryA), DngReader.numbers(b, entryB)
        return numbersA ~= nil and numbersB ~= nil and table.concat(numbersA, ' ') == table.concat(numbersB, ' ')
    end
    if a.byteOrder == b.byteOrder and DngReader.bytes(a, entryA) == DngReader.bytes(b, entryB) then
        return true
    end
    if a.byteOrder == b.byteOrder and entryA.type ~= TYPE_RATIONAL and entryA.type ~= TYPE_SRATIONAL then
        return false
    end
    return canonical(a, entryA) == canonical(b, entryB)
end

-- The image data of a directory: { kind = 'tiles' | 'strips' | 'none', offsets = { ... }, counts = { ... } },
-- 0-based offsets, every part checked to lie inside the file. Returns nil plus a message otherwise.
function DngReader.imageParts(parsed, directory)
    local kind, offsetsEntry, countsEntry = 'tiles', directory.byTag[DngReader.TAG_TILE_OFFSETS],
        directory.byTag[DngReader.TAG_TILE_BYTE_COUNTS]
    if not offsetsEntry then
        kind, offsetsEntry, countsEntry = 'strips', directory.byTag[DngReader.TAG_STRIP_OFFSETS],
            directory.byTag[DngReader.TAG_STRIP_BYTE_COUNTS]
    end
    if not offsetsEntry then
        return { kind = 'none', offsets = {}, counts = {} }
    end
    local offsets = DngReader.numbers(parsed, offsetsEntry)
    local counts = countsEntry and DngReader.numbers(parsed, countsEntry)
    if not offsets or not counts or #offsets ~= #counts then
        return nil, 'the ' .. kind .. ' have no matching offsets and byte counts'
    end
    local single = kind == 'tiles' and 'tile' or 'strip'
    for i = 1, #offsets do
        if offsets[i] < 0 or counts[i] < 0 or offsets[i] + counts[i] > #parsed.data then
            return nil, string.format('%s %d of %d lies outside the file (is the file truncated?)', single, i, #offsets)
        end
    end
    return { kind = kind, offsets = offsets, counts = counts }
end

-- The bytes of part i (1-based) of what DngReader.imageParts returned.
function DngReader.partBytes(parsed, parts, i)
    local offset = parts.offsets[i]
    return parsed.data:sub(offset + 1, offset + parts.counts[i])
end

return DngReader
