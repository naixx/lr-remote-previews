-- Builds small synthetic TIFF/DNG files for the specs (not a spec itself: busted runs *_spec.lua only).
--
--   TestDng.make({ order = 'MM', name = 'IMG_0001.ARW', width = 6000, height = 4000 })
--   TestDng.tiff('II', { { tag = 0x0100, type = 4, count = 1, data = TestDng.u32('II', 6000) } })
local TestDng = {}

function TestDng.u16(order, value)
    local lo, hi = value % 256, math.floor(value / 256) % 256
    if order == 'II' then
        return string.char(lo, hi)
    end
    return string.char(hi, lo)
end

function TestDng.u32(order, value)
    local bytes = {}
    for i = 1, 4 do
        bytes[i] = value % 256
        value = math.floor(value / 256)
    end
    if order == 'II' then
        return string.char(bytes[1], bytes[2], bytes[3], bytes[4])
    end
    return string.char(bytes[4], bytes[3], bytes[2], bytes[1])
end

-- A TIFF with one IFD right after the header. entries: { { tag, type, count, data }, ... } in tag order; data
-- holds all values already in the file's byte order. Values longer than 4 bytes go after the IFD. tail is
-- appended at the end (padding, image data).
function TestDng.tiff(order, entries, tail)
    local u16, u32 = TestDng.u16, TestDng.u32
    local ifdOffset = 8
    local dataOffset = ifdOffset + 2 + #entries * 12 + 4
    local ifd, data = { u16(order, #entries) }, {}
    for _, entry in ipairs(entries) do
        local value
        if #entry.data <= 4 then
            value = entry.data .. string.rep('\0', 4 - #entry.data)
        else
            value = u32(order, dataOffset)
            data[#data + 1] = entry.data
            dataOffset = dataOffset + #entry.data
        end
        ifd[#ifd + 1] = u16(order, entry.tag) .. u16(order, entry.type) .. u32(order, entry.count) .. value
    end
    ifd[#ifd + 1] = u32(order, 0) -- no next IFD
    return order .. u16(order, 42) .. u32(order, ifdOffset) .. table.concat(ifd) .. table.concat(data) .. (tail or '')
end

-- A DNG-like TIFF. options: order ('II'), name (OriginalRawFileName, NUL added; nil = no tag), nameType (1),
-- width/height (OriginalDefaultFinalSize; nil = no tag), sizeType (4 = LONG, 3 = SHORT), version
-- ({ 1, 7, 0, 0 }; false = no DNGVersion tag), tail.
function TestDng.make(options)
    local order = options.order or 'II'
    local entries = {
        { tag = 0x0100, type = 4, count = 1, data = TestDng.u32(order, 256) }, -- ImageWidth, to be skipped
        { tag = 0x0101, type = 3, count = 1, data = TestDng.u16(order, 171) }, -- ImageLength, to be skipped
    }
    if options.version ~= false then
        local v = options.version or { 1, 7, 0, 0 }
        entries[#entries + 1] = { tag = 0xC612, type = 1, count = 4, data = string.char(v[1], v[2], v[3], v[4]) }
    end
    if options.name then
        local text = options.name .. '\0'
        entries[#entries + 1] = { tag = 0xC68B, type = options.nameType or 1, count = #text, data = text }
    end
    if options.width then
        local sizeType = options.sizeType or 4
        local encode = sizeType == 3 and TestDng.u16 or TestDng.u32
        entries[#entries + 1] = { tag = 0xC791, type = sizeType, count = 2,
            data = encode(order, options.width) .. encode(order, options.height) }
    end
    return TestDng.tiff(order, entries, options.tail)
end

-- An entry of a full DNG: TestDng.entry(order, tag, type, values) with values a list of numbers (types 1, 3, 4, 5
-- and 10, rationals as pairs) or a string (types 1, 2 and 7, used as is).
function TestDng.entry(order, tag, fieldType, values)
    if type(values) == 'string' then
        return { tag = tag, type = fieldType, count = #values, data = values }
    end
    local encode = ({ [1] = string.char, [3] = TestDng.u16 })[fieldType]
    local chunks = {}
    for i, value in ipairs(values) do
        if fieldType == 1 then
            chunks[i] = string.char(value)
        elseif encode then
            chunks[i] = encode(order, value)
        else
            chunks[i] = TestDng.u32(order, value % 4294967296)
        end
    end
    local count = #values
    if fieldType == 5 or fieldType == 10 then
        count = count / 2
    end
    return { tag = tag, type = fieldType, count = count, data = table.concat(chunks) }
end

local function fullFile(order, options, tileBase)
    local u16, u32, entry = TestDng.u16, TestDng.u32, TestDng.entry
    local parts, size = {}, 8
    local function put(blob)
        if size % 2 == 1 then
            parts[#parts + 1] = '\0'
            size = size + 1
        end
        local at = size
        parts[#parts + 1] = blob
        size = size + #blob
        return at
    end
    local function directory(entries)
        table.sort(entries, function(a, b)
            return a.tag < b.tag
        end)
        local fields = {}
        for i, e in ipairs(entries) do
            local value = e.data
            if #value > 4 then
                value = u32(order, put(e.data))
            else
                value = value .. string.rep('\0', 4 - #value)
            end
            fields[i] = u16(order, e.tag) .. u16(order, e.type) .. u32(order, e.count) .. value
        end
        return put(u16(order, #entries) .. table.concat(fields) .. u32(order, 0))
    end

    local tiles = options.tiles
    local offsets, counts, at = {}, {}, tileBase
    for i, tile in ipairs(tiles) do
        offsets[i], counts[i] = at, #tile
        at = at + #tile
    end
    local thumbnail = options.thumbnail or string.rep('T', 64)
    local thumbnailAt = put(thumbnail)

    local raw = {
        entry(order, 0x00FE, 4, { 0 }),
        entry(order, 0x0100, 4, { options.imageWidth or 2560 }),
        entry(order, 0x0101, 4, { options.imageLength or 1707 }),
        entry(order, 0x0102, 3, options.bits or { 16, 16, 16 }),
        entry(order, 0x0103, 3, { options.compression or 52546 }),
        entry(order, 0x0106, 3, { 34892 }),
        entry(order, 0x0115, 3, { options.samples or 3 }),
        entry(order, 0x011C, 3, { 1 }),
    }
    if options.layout == 'strips' then
        raw[#raw + 1] = entry(order, 0x0111, 4, offsets)
        raw[#raw + 1] = entry(order, 0x0117, 4, counts)
    else
        raw[#raw + 1] = entry(order, 0x0142, 3, { options.tileWidth or 368 })
        raw[#raw + 1] = entry(order, 0x0143, 3, { options.tileLength or 432 })
        raw[#raw + 1] = entry(order, 0x0144, 4, offsets)
        raw[#raw + 1] = entry(order, 0x0145, 4, counts)
    end
    for _, extra in ipairs(options.extraRaw or {}) do
        raw[#raw + 1] = extra
    end
    local rawAt = directory(raw)

    local v = options.version or { 1, 7, 0, 0 }
    local ifd0 = {
        entry(order, 0x00FE, 4, { 1 }),
        entry(order, 0x0100, 4, { 256 }),
        entry(order, 0x0101, 4, { 171 }),
        entry(order, 0x0103, 3, { 7 }),
        entry(order, 0x0111, 4, { thumbnailAt }),
        entry(order, 0x0117, 4, { #thumbnail }),
        entry(order, 0x0131, 2, (options.software or 'Adobe Photoshop Lightroom Classic 15.6 (Windows)') .. '\0'),
        entry(order, 0x0132, 2, (options.dateTime or '2026:11:14 09:30:00') .. '\0'),
        entry(order, 0x02BC, 1, options.xmp or '<x:xmpmeta><rdf:Description xmp:CreatorTool="Lightroom" '
            .. 'xmpMM:DocumentID="xmp.did:1111" crs:HasSettings="False"/></x:xmpmeta>'),
        entry(order, 0xC612, 1, v),
        entry(order, 0xC65D, 1, options.uniqueId or string.rep('\1', 16)),
        entry(order, 0xC68B, 2, (options.name or 'IMG_0001.ARW') .. '\0'),
        entry(order, 0xC791, 4, { options.width or 6000, options.height or 4000 }),
        entry(order, 0xC7A7, 1, options.digest or string.rep('\2', 16)),
    }
    if not options.noRaw then
        ifd0[#ifd0 + 1] = entry(order, 0x014A, 4, { rawAt })
    end
    for _, extra in ipairs(options.extraIfd0 or {}) do
        ifd0[#ifd0 + 1] = extra
    end
    local ifd0At = directory(ifd0)
    local tilesStart = size
    local header = order .. u16(order, 42) .. u32(order, ifd0At)
    return header .. table.concat(parts) .. table.concat(tiles), tilesStart
end

-- A smart-preview-like DNG: IFD0 (a thumbnail in one strip, Software, DateTime, XMP, DNGVersion, RawDataUniqueID,
-- OriginalRawFileName, OriginalDefaultFinalSize, NewRawImageDigest, SubIFDs) and the raw image directory (the first
-- SubIFD) with its tiles, laid out as header | thumbnail | raw directory | IFD0 | tiles, so that cutting the end of
-- the file cuts the tiles. options: order ('II'), tiles (list of strings, required), layout ('tiles' | 'strips'),
-- tileWidth, tileLength, imageWidth, imageLength, compression, bits (list), samples, name, width, height, version,
-- software, dateTime, xmp, thumbnail, uniqueId, digest, noRaw, extraIfd0 / extraRaw (lists of TestDng.entry
-- results, which must use the same order).
function TestDng.full(options)
    local order = options.order or 'II'
    local _, tilesStart = fullFile(order, options, 0)
    return (fullFile(order, options, tilesStart))
end

return TestDng
