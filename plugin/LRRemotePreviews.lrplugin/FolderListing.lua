-- The files of the folders chosen for «Add a folder without previews...», and which of them are added. Pure Lua 5.1:
-- the file system is passed in (env), so this runs in unit tests. Listing never opens a file: it only reads folder
-- listings (in Lightroom LrFileUtils.files and LrFileUtils.directoryEntries).
--
-- Rules:
-- * Camera raw files are added; other photo formats (JPEG, TIFF, PNG, HEIC, PSD) only when asked for.
-- * A JPEG next to a raw file of the same name (the same folder, the base name compared without regard to case) is
--   left out and counted as paired: Lightroom's own import treats such a JPEG as part of the raw photo (with its
--   default setting), not as a photo of its own. The raw file decides, whether or not it is in the catalog already.
-- * Files whose name starts with a dot are left out (hidden files, and the "._" files macOS leaves on network shares).
-- * Folders that are never looked into (the folders chosen are always looked into): names starting with a dot,
--   Lightroom's data folders ("*.lrdata": previews and smart previews of a catalog, whose DNGs must never be added as
--   photos), and folders NAS systems keep for themselves ("@eaDir" with Synology's thumbnails, "#recycle",
--   "#snapshot", "@Recycle", "@Recently-Snapshot").
-- * Every file is listed once, also when the chosen folders overlap; the files are sorted by folder, then by name,
--   so that a run is repeatable.
local PathMap = require 'PathMap'

local FolderListing = {}

-- The camera raw extensions the server accepts (RAW_EXTENSIONS in server/src/lrrp/converter.py), used when the server
-- does not answer.
FolderListing.RAW_EXTENSIONS = { '.3fr', '.arw', '.cr2', '.cr3', '.crw', '.dng', '.erf', '.iiq', '.kdc', '.mos',
    '.mrw', '.nef', '.nrw', '.orf', '.pef', '.raf', '.rw2', '.rwl', '.sr2', '.srf', '.srw', '.x3f' }

-- Other photo formats, added only when asked for.
FolderListing.OTHER_EXTENSIONS = { '.jpg', '.jpeg', '.tif', '.tiff', '.png', '.heic', '.heif', '.psd' }

-- A JPEG with one of these extensions next to a raw file of the same name is left out.
FolderListing.JPEG_EXTENSIONS = { ['.jpg'] = true, ['.jpeg'] = true }

-- Folders never looked into, by name in lower case (besides names starting with a dot and ending with ".lrdata").
FolderListing.SYSTEM_FOLDERS = { ['@eadir'] = true, ['#recycle'] = true, ['#snapshot'] = true, ['@recycle'] = true,
    ['@recently-snapshot'] = true }

-- Folders deeper than this below a chosen folder are not looked into (a guard against links that loop).
FolderListing.MAX_DEPTH = 32

-- Why files are left out, in the order listed.
FolderListing.SKIPS = { 'pairedJpeg', 'notPhoto', 'hidden' }

local function isWindowsPath(path)
    return path:match('^%a:') ~= nil or path:match('^[/\\][/\\]') ~= nil
end

-- The folder and the name of a path: 'Z:\\2026\\IMG_0001.ARW' -> 'Z:\\2026', 'IMG_0001.ARW'. Windows paths accept
-- both slash kinds; other paths split at '/' only. A path without a separator has the folder ''.
function FolderListing.split(path)
    local pattern = isWindowsPath(path) and '^(.*)[/\\]([^/\\]*)$' or '^(.*)/([^/]*)$'
    local folder, name = path:match(pattern)
    if not folder then
        return '', path
    end
    return folder, name
end

-- The extension of a file name in lower case with the dot ('.arw'), or nil ('README', '.hidden').
function FolderListing.extension(name)
    local extension = name:match('.(%.[^.]+)$')
    return extension and extension:lower() or nil
end

-- Why a folder is not looked into, or nil when it is.
function FolderListing.folderSkip(name)
    local lower = name:lower()
    if lower:sub(1, 1) == '.' then
        return 'hidden folder'
    end
    if lower:match('%.lrdata$') then
        return 'Lightroom data folder'
    end
    if FolderListing.SYSTEM_FOLDERS[lower] then
        return 'NAS system folder'
    end
    return nil
end

-- A child of a folder as a path: entries that are already paths stay as they are.
local function childPath(folder, entry)
    if entry:find(isWindowsPath(folder) and '[/\\]' or '/') then
        return entry
    end
    local separator = isWindowsPath(folder) and '\\' or '/'
    if folder:sub(-1) == separator or folder:sub(-1) == '/' then
        return folder .. entry
    end
    return folder .. separator .. entry
end

local function sortedPaths(paths)
    table.sort(paths, function(a, b)
        local ka, kb = PathMap.fileKey(a) or a, PathMap.fileKey(b) or b
        if ka ~= kb then
            return ka < kb
        end
        return a < b
    end)
    return paths
end

-- Lists the files of the folders. roots: the chosen folders. env:
--   files(folder) -> list of paths of the files in it, or nil plus a message;
--   entries(folder) -> list of paths of its files and folders, or nil plus a message (asked only when recursive);
--   step() (optional) -> true to stop; called once per folder (Lightroom: yield, and the progress's cancel).
-- options: { recursive = bool }.
-- Returns { files = { path, ... } (each once, not sorted), folders = number looked into,
--           skippedFolders = { { path, reason }, ... }, problems = { { path, message }, ... }, stopped = bool }.
-- A sub-folder is an entry that is not among the folder's files.
function FolderListing.walk(roots, env, options)
    options = options or {}
    local result = { files = {}, folders = 0, skippedFolders = {}, problems = {}, stopped = false }
    local seenFiles, seenFolders = {}, {}
    local stack = {}
    for i = #roots, 1, -1 do
        stack[#stack + 1] = { path = roots[i], depth = 0 }
    end
    while #stack > 0 do
        local folder = table.remove(stack)
        local key = PathMap.fileKey(folder.path)
        if key and not seenFolders[key] then
            seenFolders[key] = true
            if env.step and env.step() then
                result.stopped = true
                return result
            end
            result.folders = result.folders + 1
            local files, filesProblem = env.files(folder.path)
            if not files then
                result.problems[#result.problems + 1] = { path = folder.path, message = tostring(filesProblem) }
                files = {}
            end
            local isFile = {}
            for _, entry in ipairs(files) do
                local path = childPath(folder.path, entry)
                local fileKey = PathMap.fileKey(path)
                isFile[fileKey] = true
                if not seenFiles[fileKey] then
                    seenFiles[fileKey] = true
                    result.files[#result.files + 1] = path
                end
            end
            if options.recursive then
                local entries, entriesProblem = env.entries(folder.path)
                if not entries then
                    result.problems[#result.problems + 1] = { path = folder.path, message = tostring(entriesProblem) }
                    entries = {}
                end
                local subfolders = {}
                for _, entry in ipairs(entries) do
                    local path = childPath(folder.path, entry)
                    if not isFile[PathMap.fileKey(path)] then
                        subfolders[#subfolders + 1] = path
                    end
                end
                local deeper = {}
                for _, path in ipairs(sortedPaths(subfolders)) do
                    local _, name = FolderListing.split(path)
                    local reason = FolderListing.folderSkip(name)
                    if not reason and folder.depth + 1 > FolderListing.MAX_DEPTH then
                        reason = 'more than ' .. FolderListing.MAX_DEPTH .. ' levels deep'
                    end
                    if reason then
                        result.skippedFolders[#result.skippedFolders + 1] = { path = path, reason = reason }
                    else
                        deeper[#deeper + 1] = path
                    end
                end
                for i = #deeper, 1, -1 do
                    stack[#stack + 1] = { path = deeper[i], depth = folder.depth + 1 }
                end
            end
        end
    end
    return result
end

local function set(list)
    local result = {}
    for _, value in ipairs(list or {}) do
        result[value:lower()] = true
    end
    return result
end

-- Decides which files are added. files: paths (from FolderListing.walk). options: { rawExtensions = { '.arw', ... },
-- otherExtensions = { '.jpg', ... } or nil (raw files only) }.
-- Returns { candidates = { { path, folder, name, extension, kind = 'raw' | 'other' }, ... },
--           skipped = { { path, name, reason, detail }, ... }, counts = { [reason] = n } },
-- both lists sorted by folder, then by name (without regard to case for Windows paths). Reasons: FolderListing.SKIPS.
function FolderListing.classify(files, options)
    local raw, other = set(options.rawExtensions), set(options.otherExtensions)
    local described, rawNames = {}, {}
    for _, path in ipairs(files) do
        local folder, name = FolderListing.split(path)
        local extension = FolderListing.extension(name)
        local file = { path = path, folder = folder, name = name, extension = extension,
            folderKey = PathMap.fileKey(folder ~= '' and folder or '.') or folder,
            nameKey = name:lower() }
        file.base = extension and name:sub(1, #name - #extension):lower() or name:lower()
        described[#described + 1] = file
        if extension and raw[extension] and name:sub(1, 1) ~= '.' then
            local pairKey = file.folderKey .. '\0' .. file.base
            rawNames[pairKey] = rawNames[pairKey] or name
        end
    end
    table.sort(described, function(a, b)
        if a.folderKey ~= b.folderKey then
            return a.folderKey < b.folderKey
        end
        if a.nameKey ~= b.nameKey then
            return a.nameKey < b.nameKey
        end
        return a.path < b.path
    end)

    local result = { candidates = {}, skipped = {}, counts = {} }
    local function skip(file, reason, detail)
        result.skipped[#result.skipped + 1] = { path = file.path, name = file.name, reason = reason, detail = detail }
        result.counts[reason] = (result.counts[reason] or 0) + 1
    end
    for _, file in ipairs(described) do
        local extension = file.extension
        if file.name:sub(1, 1) == '.' then
            skip(file, 'hidden')
        elseif extension and raw[extension] then
            result.candidates[#result.candidates + 1] = { path = file.path, folder = file.folder, name = file.name,
                extension = extension, kind = 'raw' }
        elseif extension and other[extension] then
            local pairedWith = FolderListing.JPEG_EXTENSIONS[extension]
                and rawNames[file.folderKey .. '\0' .. file.base]
            if pairedWith then
                skip(file, 'pairedJpeg', pairedWith)
            else
                result.candidates[#result.candidates + 1] = { path = file.path, folder = file.folder,
                    name = file.name, extension = extension, kind = 'other' }
            end
        else
            skip(file, 'notPhoto', extension or '(no extension)')
        end
    end
    return result
end

return FolderListing
