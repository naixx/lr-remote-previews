-- Puts one downloaded smart preview DNG into the catalog's smart preview store, following the safety rules
-- (decision record 0005, docs/protocol.md "What a client must do with a delivered file"):
--   1. the length must equal the server's result.size;
--   2. the DNG itself must name the photo's file as its original (OriginalRawFileName, case-insensitive) and,
--      when both sides know it, record the photo's pixel size (OriginalDefaultFinalSize, either orientation);
--   3. it is written under a temporary name in the destination folder and then renamed;
--   4. an existing file is never replaced;
--   5. then Lightroom is asked to register it with photo:buildSmartPreview(), which answers 'existed'.
-- Pure Lua 5.1: the file system and Lightroom are passed in (fs), so it runs in unit tests.
local DngReader = require 'DngReader'

local Delivery = {}

local function sameName(a, b)
    return type(a) == 'string' and type(b) == 'string' and a:lower() == b:lower()
end

local function sizeText(width, height)
    return string.format('%dx%d', width, height)
end

-- Checks a downloaded file. result: the item's result from the server ({ size, ... }); expected:
-- { fileName, width, height } of the photo (width/height nil when unknown).
-- Returns { dngVersion, originalName, originalWidth, originalHeight, dimensionsChecked }, or nil plus a reason.
function Delivery.verify(body, result, expected)
    if type(body) ~= 'string' then
        return nil, 'no file content'
    end
    if type(result) ~= 'table' or type(result.size) ~= 'number' then
        return nil, 'the server gave no file size'
    end
    if #body ~= result.size then
        return nil, string.format('the file has %d bytes, the server announced %d', #body, result.size)
    end
    local dng, err = DngReader.read(body)
    if not dng then
        return nil, 'not a readable DNG (' .. err .. ')'
    end
    if not dng.dngVersion then
        return nil, 'the file has no DNGVersion tag'
    end
    if not dng.originalRawFileName or dng.originalRawFileName == '' then
        return nil, 'the DNG records no original file name'
    end
    if not sameName(dng.originalRawFileName, expected.fileName) then
        return nil, string.format('the DNG was made from "%s", not from "%s"', dng.originalRawFileName,
            tostring(expected.fileName))
    end
    local checked = false
    if dng.originalWidth and dng.originalHeight and expected.width and expected.height then
        local w, h = dng.originalWidth, dng.originalHeight
        if not ((w == expected.width and h == expected.height) or (w == expected.height and h == expected.width)) then
            return nil, string.format('the DNG records an original size of %s, the photo is %s', sizeText(w, h),
                sizeText(expected.width, expected.height))
        end
        checked = true
    end
    return {
        dngVersion = dng.dngVersion,
        originalName = dng.originalRawFileName,
        originalWidth = dng.originalWidth,
        originalHeight = dng.originalHeight,
        dimensionsChecked = checked,
    }
end

-- Folder and file name of a path; either slash separates.
function Delivery.splitPath(path)
    local folder, separator, name = path:match('^(.*)([/\\])([^/\\]+)$')
    return folder, name, separator
end

-- Writes body to dest through a temporary file next to it. tempTag makes the temporary name unique, e.g.
-- 'lrrp-1731577800-17' gives <dest>.lrrp-1731577800-17.tmp.
-- fs: { exists(path) -> truthy, makeFolder(path) -> ok, err, writeFile(path, data) -> ok, err,
--       move(from, to), delete(path) }. Success of move is judged by looking at the files afterwards.
-- Returns 'placed', or 'destinationExists', or 'writeFailed' plus a message.
function Delivery.place(dest, body, fs, tempTag)
    local folder, name, separator = Delivery.splitPath(dest)
    if not folder then
        return 'writeFailed', 'not a file path: ' .. tostring(dest)
    end
    if fs.exists(dest) then
        return 'destinationExists'
    end
    if not fs.exists(folder) then
        local ok, err = fs.makeFolder(folder)
        if not ok or not fs.exists(folder) then
            return 'writeFailed', 'cannot create the folder ' .. folder .. ': ' .. tostring(err)
        end
    end
    local temp = folder .. separator .. name .. '.' .. tempTag .. '.tmp'
    if fs.exists(temp) then
        return 'writeFailed', 'the temporary file already exists: ' .. temp
    end
    local written, writeError = fs.writeFile(temp, body)
    if not written then
        fs.delete(temp)
        return 'writeFailed', 'cannot write ' .. temp .. ': ' .. tostring(writeError)
    end
    if fs.exists(dest) then
        fs.delete(temp)
        return 'destinationExists'
    end
    local _, moveError = fs.move(temp, dest)
    if not fs.exists(dest) or fs.exists(temp) then
        if fs.exists(temp) then
            fs.delete(temp)
        end
        if fs.exists(dest) then
            return 'destinationExists'
        end
        return 'writeFailed', 'cannot rename ' .. temp .. ' to ' .. name .. ': ' .. tostring(moveError)
    end
    return 'placed'
end

-- The whole delivery of one photo. target: { fileName, width, height, dest }; fs as for Delivery.place plus
-- buildSmartPreview() -> ok, answer (ok false when it raised an error; answer is then the error).
-- Returns an outcome and a detail text:
--   'delivered'          placed, and Lightroom answered 'existed'
--   'deliveredOther'     placed, and Lightroom answered something else (the detail says what)
--   'destinationExists'  a file was already there; nothing written
--   'checkFailed'        the file failed a check and was discarded (never written)
--   'writeFailed'        it could not be written or renamed
function Delivery.deliver(target, result, body, fs, tempTag)
    local facts, reason = Delivery.verify(body, result, target)
    if not facts then
        return 'checkFailed', reason
    end
    local placed, placeError = Delivery.place(target.dest, body, fs, tempTag)
    if placed ~= 'placed' then
        return placed, placeError or target.dest
    end
    local sizeNote = facts.dimensionsChecked and '' or ', original size not checked'
    local ok, answer = fs.buildSmartPreview()
    if ok and answer == 'existed' then
        return 'delivered', 'DNG ' .. facts.dngVersion .. sizeNote
    end
    local said = ok and ("Lightroom answered '" .. tostring(answer) .. "'")
        or ('buildSmartPreview raised an error: ' .. tostring(answer))
    return 'deliveredOther', said .. sizeNote
end

return Delivery
