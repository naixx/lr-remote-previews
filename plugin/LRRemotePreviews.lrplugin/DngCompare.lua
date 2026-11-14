-- Compares a smart preview that Lightroom built with the DNG the server built from the same raw file. The project
-- rests on the two being the same file (docs/research/smart-previews.md), so this is the check to repeat after an
-- update of Lightroom or of Adobe DNG Converter. Pure Lua 5.1: no Lightroom imports.
--
--   local report = DngCompare.compare(lightroomBytes, serverBytes)
--
-- What is compared:
--   * the raw image, which is the first SubIFD of IFD0: NewSubFileType, width, height, bits per sample,
--     compression, photometric interpretation, samples per pixel, planar configuration, tile size and the number
--     of tiles (or strips). A difference there is a different structure, the error case;
--   * every tile (or strip) of the raw image, byte for byte;
--   * DNGVersion, OriginalRawFileName and OriginalDefaultFinalSize. A difference there is an error too;
--   * reported without counting against the result, because two programs are expected to write them differently:
--     the software name and version, the dates, the document ids, dates and versions in the XMP packet, the small
--     thumbnail in IFD0, RawDataUniqueID and NewRawImageDigest;
--   * every other tag of IFD0 and of the raw image directory (file offsets and byte counts left out, the data they
--     point to is compared above). One that differs is listed as not expected; it does not change the verdict.
--
-- report = {
--   verdict    = 'identical' | 'tilesDiffer' | 'different' | 'unreadable',
--   reasons    = { text, ... },                     -- why the verdict is 'different' or 'unreadable'
--   sizes      = { lightroom = bytes, server = bytes },
--   software   = { lightroom = text | nil, server = text | nil },
--   identity   = { { name, lightroom, server, same }, ... },
--   structure  = { { name, lightroom, server, same }, ... },
--   parts      = { kind = 'tiles' | 'strips' | 'none', total, same, differing = { index, ... } } | nil,
--   expected   = { { name, same, detail }, ... },
--   unexpected = { name, ... },
-- }
local DngReader = require 'DngReader'

local DngCompare = {}

DngCompare.VERDICTS = {
    identical = 'identical image data',
    tilesDiffer = 'N of M tiles identical',
    different = 'different structure',
    unreadable = 'not compared',
}

-- Fields of the raw image directory that make its structure.
DngCompare.STRUCTURE = {
    { 0x00FE, 'NewSubFileType' },
    { 0x0100, 'width' },
    { 0x0101, 'height' },
    { 0x0102, 'bits per sample' },
    { 0x0103, 'compression' },
    { 0x0106, 'photometric interpretation' },
    { 0x0115, 'samples per pixel' },
    { 0x011C, 'planar configuration' },
    { 0x0142, 'tile width' },
    { 0x0143, 'tile length' },
}

-- Tags of IFD0 that two programs are expected to write differently, in the order they are reported.
DngCompare.EXPECTED = {
    { 0x0131, 'Software', true },
    { 0xC716, 'PreviewApplicationName', true },
    { 0xC717, 'PreviewApplicationVersion', true },
    { 0x0132, 'DateTime', true },
    { 0xC71B, 'PreviewDateTime', true },
    { 0x02BC, 'XMP' },
    { 0xC65D, 'RawDataUniqueID' },
    { 0xC7A7, 'NewRawImageDigest' },
}

-- XMP properties that differ between two programs: the tool, the dates, the document ids, the version.
DngCompare.XMP_VARYING = { 'xmp:CreatorTool', 'xmp:CreateDate', 'xmp:ModifyDate', 'xmp:MetadataDate',
    'xmpMM:DocumentID', 'xmpMM:OriginalDocumentID', 'xmpMM:InstanceID', 'crs:Version', 'tiff:Software' }

-- Offsets and byte counts: they differ whenever anything before the data does; the data itself is compared.
local POINTERS = { [0x0111] = true, [0x0117] = true, [0x0144] = true, [0x0145] = true, [0x014A] = true,
    [0x8769] = true, [0x8825] = true, [0x0201] = true, [0x0202] = true }

local IDENTITY_TAGS = { [DngReader.TAG_DNG_VERSION] = true, [DngReader.TAG_ORIGINAL_RAW_FILE_NAME] = true,
    [DngReader.TAG_ORIGINAL_DEFAULT_FINAL_SIZE] = true }

-- Names of tags that may show up in the list of unexpected differences.
local NAMES = {
    [0x00FE] = 'NewSubFileType', [0x0100] = 'ImageWidth', [0x0101] = 'ImageLength', [0x0102] = 'BitsPerSample',
    [0x0103] = 'Compression', [0x0106] = 'PhotometricInterpretation', [0x010F] = 'Make', [0x0110] = 'Model',
    [0x0112] = 'Orientation', [0x0115] = 'SamplesPerPixel', [0x011C] = 'PlanarConfiguration',
    [0x0142] = 'TileWidth', [0x0143] = 'TileLength', [0xC613] = 'DNGBackwardVersion',
    [0xC614] = 'UniqueCameraModel', [0xC61A] = 'BlackLevel', [0xC61D] = 'WhiteLevel', [0xC61F] = 'DefaultCropOrigin',
    [0xC620] = 'DefaultCropSize', [0xC621] = 'ColorMatrix1', [0xC622] = 'ColorMatrix2',
    [0xC627] = 'AnalogBalance', [0xC628] = 'AsShotNeutral', [0xC62A] = 'BaselineExposure',
    [0xC62B] = 'BaselineNoise', [0xC62C] = 'BaselineSharpness', [0xC62E] = 'LinearResponseLimit',
    [0xC630] = 'LensInfo', [0xC634] = 'DNGPrivateData', [0xC65A] = 'CalibrationIlluminant1',
    [0xC65B] = 'CalibrationIlluminant2', [0xC6F8] = 'ProfileName', [0xC6F9] = 'ProfileHueSatMapDims',
    [0xC6FA] = 'ProfileHueSatMapData1', [0xC6FB] = 'ProfileHueSatMapData2', [0xC6FD] = 'ProfileEmbedPolicy',
    [0xC6FE] = 'ProfileCopyright', [0xC714] = 'ForwardMatrix1', [0xC715] = 'ForwardMatrix2',
    [0xC718] = 'PreviewSettingsName', [0xC719] = 'PreviewSettingsDigest', [0xC71A] = 'PreviewColorSpace',
    [0xC725] = 'ProfileLookTableDims', [0xC726] = 'ProfileLookTableData', [0xC740] = 'OpcodeList1',
    [0xC741] = 'OpcodeList2', [0xC74E] = 'OpcodeList3', [0xC761] = 'NoiseProfile',
    [0xC792] = 'OriginalBestQualityFinalSize', [0xC793] = 'OriginalDefaultCropSize',
    [0xCD49] = 'JXLDistance', [0xCD4A] = 'JXLEffort', [0xCD4B] = 'JXLDecodeSpeed',
}

local EXPECTED_TAGS = {}
for _, row in ipairs(DngCompare.EXPECTED) do
    EXPECTED_TAGS[row[1]] = true
end
local STRUCTURE_TAGS = {}
for _, row in ipairs(DngCompare.STRUCTURE) do
    STRUCTURE_TAGS[row[1]] = true
end

function DngCompare.tagName(tag)
    return NAMES[tag] or string.format('tag 0x%04X', tag)
end

-- The XMP packet without the properties that are expected to differ, and without the white space XML ignores
-- (between elements, before the end of a tag; the rest collapsed to single spaces).
function DngCompare.normalizeXmp(xmp)
    xmp = xmp:gsub('%z', '')
    for _, element in ipairs({ 'xmpMM:History', 'xmpMM:DerivedFrom' }) do
        xmp = xmp:gsub('<' .. element .. '[^>]*/>', ''):gsub('<' .. element .. '[^>]*>.-</' .. element .. '>', '')
    end
    for _, name in ipairs(DngCompare.XMP_VARYING) do
        xmp = xmp:gsub('%s' .. name .. '%s*=%s*"[^"]*"', ''):gsub('<' .. name .. '>.-</' .. name .. '>', '')
    end
    xmp = xmp:gsub('%s+', ' '):gsub('>%s+<', '><'):gsub('%s+(/?>)', '%1')
    return (xmp:gsub('^ ', ''):gsub(' $', ''))
end

local function numbersText(parsed, entry)
    if not entry then
        return '(none)'
    end
    local numbers = DngReader.numbers(parsed, entry)
    if not numbers then
        return '(not a number)'
    end
    return table.concat(numbers, ' ')
end

local function textOf(parsed, entry)
    if not entry then
        return nil
    end
    return DngReader.text(parsed, entry)
end

-- The bytes of all parts of a directory's image data, or nil plus a message.
local function imageBytes(parsed, directory)
    local parts, problem = DngReader.imageParts(parsed, directory)
    if not parts then
        return nil, problem
    end
    local chunks = {}
    for i = 1, #parts.offsets do
        chunks[i] = DngReader.partBytes(parsed, parts, i)
    end
    return table.concat(chunks)
end

local function sizeText(info)
    if info.originalWidth and info.originalHeight then
        return string.format('%dx%d', info.originalWidth, info.originalHeight)
    end
    return '(none)'
end

-- Compares the identity tags (DngReader.read of both files).
local function compareIdentity(report, lightroomInfo, serverInfo)
    local rows = {
        { 'DNGVersion', lightroomInfo.dngVersion or '(none)', serverInfo.dngVersion or '(none)' },
        { 'OriginalRawFileName', lightroomInfo.originalRawFileName or '(none)',
            serverInfo.originalRawFileName or '(none)' },
        { 'OriginalDefaultFinalSize', sizeText(lightroomInfo), sizeText(serverInfo) },
    }
    for _, row in ipairs(rows) do
        local same = row[2] == row[3]
        report.identity[#report.identity + 1] = { name = row[1], lightroom = row[2], server = row[3], same = same }
        if not same then
            report.reasons[#report.reasons + 1] = string.format('%s is %s in Lightroom\'s file and %s in the '
                .. 'server\'s', row[1], row[2], row[3])
        end
    end
end

-- Compares the structure and every part of the raw image. Returns false when a file could not be read.
local function compareRawImage(report, a, b)
    for _, field in ipairs(DngCompare.STRUCTURE) do
        local lightroom, server = numbersText(a, a.raw.byTag[field[1]]), numbersText(b, b.raw.byTag[field[1]])
        local same = lightroom == server
        report.structure[#report.structure + 1] = { name = field[2], lightroom = lightroom, server = server,
            same = same }
        if not same then
            report.reasons[#report.reasons + 1] = string.format('the raw image\'s %s is %s in Lightroom\'s file and '
                .. '%s in the server\'s', field[2], lightroom, server)
        end
    end
    local partsA, problemA = DngReader.imageParts(a, a.raw)
    local partsB, problemB = DngReader.imageParts(b, b.raw)
    if not partsA or not partsB then
        if problemA then
            report.reasons[#report.reasons + 1] = 'Lightroom\'s file: ' .. problemA
        end
        if problemB then
            report.reasons[#report.reasons + 1] = 'the server\'s file: ' .. problemB
        end
        return false
    end
    local layoutA, layoutB = partsA.kind .. ' ' .. #partsA.offsets, partsB.kind .. ' ' .. #partsB.offsets
    report.structure[#report.structure + 1] = { name = 'layout', lightroom = layoutA, server = layoutB,
        same = layoutA == layoutB }
    if layoutA ~= layoutB then
        report.reasons[#report.reasons + 1] = string.format('the raw image is stored as %s in Lightroom\'s file and '
            .. 'as %s in the server\'s', layoutA, layoutB)
        return true
    end
    if #partsA.offsets == 0 then
        report.reasons[#report.reasons + 1] = 'the raw image has no tiles or strips'
        return true
    end
    local parts = { kind = partsA.kind, total = #partsA.offsets, same = 0, differing = {} }
    for i = 1, parts.total do
        if DngReader.partBytes(a, partsA, i) == DngReader.partBytes(b, partsB, i) then
            parts.same = parts.same + 1
        else
            parts.differing[#parts.differing + 1] = i
        end
    end
    report.parts = parts
    return true
end

-- The expected differences of IFD0, the thumbnail included.
local function compareExpected(report, a, b)
    for _, row in ipairs(DngCompare.EXPECTED) do
        local tag, name, isText = row[1], row[2], row[3]
        local entryA, entryB = a.ifd0.byTag[tag], b.ifd0.byTag[tag]
        if entryA or entryB then
            local same = entryA ~= nil and entryB ~= nil and DngReader.sameValue(a, entryA, b, entryB)
            local detail
            if tag == 0x02BC and not same and entryA and entryB then
                local xmpSame = DngCompare.normalizeXmp(DngReader.bytes(a, entryA))
                    == DngCompare.normalizeXmp(DngReader.bytes(b, entryB))
                if xmpSame then
                    detail = 'only in ids, dates and software versions'
                else
                    detail = 'also in other properties'
                    report.unexpected[#report.unexpected + 1] = 'XMP (other properties than ids, dates and versions)'
                end
            elseif isText and not same then
                detail = string.format('"%s" / "%s"', textOf(a, entryA) or '(none)', textOf(b, entryB) or '(none)')
            elseif not same and (not entryA or not entryB) then
                detail = entryA and 'only in Lightroom\'s file' or 'only in the server\'s file'
            end
            report.expected[#report.expected + 1] = { name = name, same = same, detail = detail }
        end
    end
    local thumbA, problemA = imageBytes(a, a.ifd0)
    local thumbB, problemB = imageBytes(b, b.ifd0)
    if not thumbA or not thumbB then
        if problemA then
            report.reasons[#report.reasons + 1] = 'Lightroom\'s file, thumbnail: ' .. problemA
        end
        if problemB then
            report.reasons[#report.reasons + 1] = 'the server\'s file, thumbnail: ' .. problemB
        end
        return false
    end
    local same = thumbA == thumbB
    report.expected[#report.expected + 1] = { name = 'thumbnail', same = same,
        detail = (not same) and string.format('%d and %d bytes', #thumbA, #thumbB) or nil }
    return true
end

-- Every other tag of one directory of both files.
local function compareOthers(report, a, b, directoryA, directoryB, isRaw)
    local tags, seen = {}, {}
    for _, directory in ipairs({ directoryA, directoryB }) do
        for _, entry in ipairs(directory.entries) do
            if not seen[entry.tag] then
                seen[entry.tag] = true
                tags[#tags + 1] = entry.tag
            end
        end
    end
    table.sort(tags)
    for _, tag in ipairs(tags) do
        local skip = POINTERS[tag] or (isRaw and STRUCTURE_TAGS[tag])
            or (not isRaw and (EXPECTED_TAGS[tag] or IDENTITY_TAGS[tag]))
        if not skip then
            local entryA, entryB = directoryA.byTag[tag], directoryB.byTag[tag]
            if not (entryA and entryB and DngReader.sameValue(a, entryA, b, entryB)) then
                local where = isRaw and ' (raw image)' or ''
                report.unexpected[#report.unexpected + 1] = DngCompare.tagName(tag) .. where
            end
        end
    end
end

-- See the header. lightroomBytes, serverBytes: the two files' contents.
function DngCompare.compare(lightroomBytes, serverBytes)
    local report = {
        reasons = {}, identity = {}, structure = {}, expected = {}, unexpected = {},
        sizes = { lightroom = type(lightroomBytes) == 'string' and #lightroomBytes or 0,
            server = type(serverBytes) == 'string' and #serverBytes or 0 },
        software = {},
    }
    local a, problemA = DngReader.parse(lightroomBytes)
    local b, problemB = DngReader.parse(serverBytes)
    local infoA, infoProblemA = DngReader.read(lightroomBytes)
    local infoB, infoProblemB = DngReader.read(serverBytes)
    problemA, problemB = problemA or infoProblemA, problemB or infoProblemB
    if not a or not b or not infoA or not infoB then
        report.verdict = 'unreadable'
        if problemA then
            report.reasons[#report.reasons + 1] = 'Lightroom\'s smart preview is not a readable DNG: ' .. problemA
        end
        if problemB then
            report.reasons[#report.reasons + 1] = 'the server\'s file is not a readable DNG: ' .. problemB
        end
        return report
    end
    report.software.lightroom = textOf(a, a.ifd0.byTag[0x0131])
    report.software.server = textOf(b, b.ifd0.byTag[0x0131])

    compareIdentity(report, infoA, infoB)
    local readable = compareExpected(report, a, b)
    compareOthers(report, a, b, a.ifd0, b.ifd0, false)
    if not a.raw or not b.raw then
        if a.rawProblem then
            report.reasons[#report.reasons + 1] = 'Lightroom\'s file: ' .. a.rawProblem
        end
        if b.rawProblem then
            report.reasons[#report.reasons + 1] = 'the server\'s file: ' .. b.rawProblem
        end
        report.verdict = readable and 'different' or 'unreadable'
        return report
    end
    readable = compareRawImage(report, a, b) and readable
    compareOthers(report, a, b, a.raw, b.raw, true)

    if not readable then
        report.verdict = 'unreadable'
    elseif #report.reasons > 0 then
        report.verdict = 'different'
    elseif report.parts.same == report.parts.total then
        report.verdict = 'identical'
    else
        report.verdict = 'tilesDiffer'
    end
    return report
end

-- Texts ---------------------------------------------------------------------------------------------------------

local function plural(n, one, many)
    return n .. ' ' .. (n == 1 and one or many)
end

local function indexList(indices, limit)
    limit = limit or 10
    local shown = {}
    for i = 1, math.min(#indices, limit) do
        shown[i] = tostring(indices[i])
    end
    local text = table.concat(shown, ', ')
    if #indices > limit then
        text = text .. ', ...'
    end
    return text
end

-- The verdict in one line, the way the dialog and the log start.
function DngCompare.verdictLine(report)
    local parts = report.parts
    local unit = parts and (parts.kind == 'strips' and 'strip' or 'tile') or 'tile'
    if report.verdict == 'identical' then
        return string.format('Identical image data: all %s of the raw image are byte-identical.',
            plural(parts.total, unit, unit .. 's'))
    elseif report.verdict == 'tilesDiffer' then
        local differing = #parts.differing
        return string.format('%d of %d %ss identical: the raw image has the same structure, but %s (%s %s) %s.',
            parts.same, parts.total, unit, plural(differing, unit, unit .. 's'), differing == 1 and unit or unit .. 's',
            indexList(parts.differing), differing == 1 and 'differs' or 'differ')
    elseif report.verdict == 'different' then
        return 'Different structure: ' .. table.concat(report.reasons, '; ') .. '.'
    end
    return 'Not compared: ' .. table.concat(report.reasons, '; ') .. '.'
end

-- The dialog style for a report: different or unreadable files are an error; differing tiles, and identical image
-- data with unexpected tag differences, a warning.
function DngCompare.style(report)
    if report.verdict == 'different' or report.verdict == 'unreadable' then
        return 'critical'
    end
    if report.verdict == 'tilesDiffer' or #report.unexpected > 0 then
        return 'warning'
    end
    return 'info'
end

-- The details below the verdict line.
function DngCompare.detailLines(report)
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    add(string.format('File sizes: %d bytes (Lightroom), %d bytes (server).', report.sizes.lightroom,
        report.sizes.server))
    if #report.identity > 0 then
        local allSame, values, differing = true, {}, {}
        for _, row in ipairs(report.identity) do
            allSame = allSame and row.same
            values[#values + 1] = row.lightroom
            if not row.same then
                differing[#differing + 1] = string.format('    %s: %s (Lightroom) / %s (server)', row.name,
                    row.lightroom, row.server)
            end
        end
        if allSame then
            add('DNGVersion, original file name and original size: the same (' .. table.concat(values, ', ') .. ').')
        else
            add('DNGVersion, original file name and original size differ:')
            for _, line in ipairs(differing) do
                add(line)
            end
        end
    end
    if #report.structure > 0 then
        local same, differing = {}, {}
        for _, row in ipairs(report.structure) do
            if row.same then
                if row.lightroom ~= '(none)' then
                    same[#same + 1] = row.name .. ' ' .. row.lightroom
                end
            else
                differing[#differing + 1] = string.format('    %s: %s (Lightroom) / %s (server)', row.name,
                    row.lightroom, row.server)
            end
        end
        if #differing == 0 then
            add('Raw image, the same in both: ' .. table.concat(same, ', ') .. '.')
        else
            add('Raw image, what differs:')
            for _, line in ipairs(differing) do
                add(line)
            end
        end
    end
    if #report.expected > 0 then
        add('Expected to differ between two programs (not counted):')
        for _, row in ipairs(report.expected) do
            local state = row.same and 'the same' or 'differs'
            add('    ' .. row.name .. ': ' .. state .. (row.detail and (' (' .. row.detail .. ')') or ''))
        end
    end
    if #report.unexpected > 0 then
        add('Other tags that differ (not expected; worth a look): ' .. table.concat(report.unexpected, ', ') .. '.')
    elseif report.verdict ~= 'unreadable' and #report.identity > 0 then
        add('No other tag differs.')
    end
    return lines
end

return DngCompare
