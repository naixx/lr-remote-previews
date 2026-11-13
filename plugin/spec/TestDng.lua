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

return TestDng
