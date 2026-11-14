-- The decisions and texts of «Add a folder without previews...» (version 0.5.0): whether the photos can be sent
-- afterwards, the batches, what the answer of one write to the catalog means, the counts, the confirmation and the
-- summary, and the log lines with their timings. Pure Lua 5.1: no Lightroom imports.
--
-- The photos are added with catalog:addPhoto inside catalog:withWriteAccessDo, in batches. What the SDK documents
-- (Lightroom Classic SDK, LrCatalog):
-- * addPhoto "must be called from within a withWriteAccessDo or withProlongedWriteAccessDo gate"; it returns the photo
--   that was added, and throws an error when the path does not exist or the file's format is not supported. What it
--   does with a file that is in the catalog already is not documented, so that is looked up before.
-- * withWriteAccessDo: "If an error is thrown during the function, any changes made to the database are rolled back."
--   LrTasks.yield() may be called inside. With a table { timeout = seconds } it waits that long for write access and
--   returns "executed" or "aborted" ("func will have been ignored"); "queued" only with asynchronous = true, which is
--   not used here. Without the table it throws when write access is not free at once.
-- So every addPhoto is called through LrTasks.pcall inside the write, so that one file Lightroom refuses does not roll
-- back the batch. When an error leaves the write anyway, the batch is rolled back and its files are tried again, one
-- write per file. A write that did not run (aborted, or failed before the function ran) is tried again a few times,
-- then the run stops.
local PathMap = require 'PathMap'

local AddPlan = {}

AddPlan.BATCH_SIZE = 50 -- files per write
AddPlan.WRITE_TIMEOUT = 30 -- seconds a write waits for write access to the catalog
AddPlan.MAX_WAITS = 3 -- writes in a row that may not run (aborted) before the run stops
AddPlan.WAIT_PAUSE = 2 -- seconds between two tries of a write that did not run
AddPlan.MAX_REASONS = 5 -- refused or failed files named in the summary
AddPlan.ACTION_NAME = 'Add photos without previews' -- the name of each write in Lightroom's Edit > Undo list
AddPlan.JOB_LABEL = 'Lightroom folder (added without previews)'
AddPlan.LOG_PREFIX = 'add folder: '

-- Files left out while listing (FolderListing.SKIPS), in the order listed.
AddPlan.SKIPS = {
    { 'pairedJpeg', 'JPEG files next to a raw file of the same name (part of that photo, as in Lightroom\'s import)' },
    { 'notPhoto', 'other files (not a photo type chosen)' },
    { 'hidden', 'hidden files (names starting with a dot)' },
}

-- What happened to the files that were to be added, in the order listed.
AddPlan.OUTCOMES = {
    { 'added', 'Added to the catalog' },
    { 'alreadyInCatalog', 'Already in the catalog (left alone)' },
    { 'notSupported', 'Not added: Lightroom does not support the file' },
    { 'failed', 'Not added: Lightroom reported an error' },
    { 'notAdded', 'Not added: the run stopped first' },
}

local SKIP_TEXT, OUTCOME_TEXT = {}, {}
for _, pair in ipairs(AddPlan.SKIPS) do
    SKIP_TEXT[pair[1]] = pair[2]
end
for _, pair in ipairs(AddPlan.OUTCOMES) do
    OUTCOME_TEXT[pair[1]] = pair[2]
end

local function plural(n, one, many)
    return n .. ' ' .. (n == 1 and one or many)
end

-- Seconds as text: '0.19 s', '12.3 s', '125 s'.
function AddPlan.seconds(value)
    value = tonumber(value) or 0
    if value < 0 then
        value = 0
    end
    if value < 10 then
        return string.format('%.2f s', value)
    elseif value < 100 then
        return string.format('%.1f s', value)
    end
    return string.format('%d s', math.floor(value + 0.5))
end

local function perItem(seconds, count)
    if not count or count == 0 then
        return nil
    end
    return string.format('%.3f s', (tonumber(seconds) or 0) / count)
end

-- Whether the photos can be sent to the server afterwards. settings: { serverUrl }, mappings: Settings.mappings(),
-- folders: the chosen folders. Returns true, or false plus the reason (a sentence for the dialog).
function AddPlan.sendAvailability(settings, mappings, folders)
    if type(settings.serverUrl) ~= 'string' or settings.serverUrl == '' then
        return false, 'No server is set up (File > Plug-in Manager > LR Remote Previews).'
    end
    if #mappings == 0 then
        return false, 'No path mapping is set up (File > Plug-in Manager > LR Remote Previews).'
    end
    for _, folder in ipairs(folders) do
        if PathMap.map(folder .. '/x', mappings) then
            return true
        end
    end
    return false, 'The folder is under none of the path mappings, so the server cannot read these files.'
end

-- Splits a list into batches of at most size.
function AddPlan.batches(list, size)
    size = size or AddPlan.BATCH_SIZE
    local result, current = {}, {}
    for _, value in ipairs(list) do
        current[#current + 1] = value
        if #current == size then
            result[#result + 1] = current
            current = {}
        end
    end
    if #current > 0 then
        result[#result + 1] = current
    end
    return result
end

-- The text of an error without the place in a script that Lua puts in front ('[string "x"]:12: ', 'C:\\a\\b.lua:12: '),
-- for the summary; the log keeps the whole text.
function AddPlan.errorText(err)
    local text = tostring(err)
    text = text:gsub('^%[string ".-"%]:%d+: ', '')
    text = text:gsub('^[^\n]-%.lua:%d+: ', '')
    return text
end

-- 'notSupported' when the text of addPhoto's error speaks of support or format, otherwise 'failed'. The texts
-- Lightroom uses are not documented; the full text is logged either way.
function AddPlan.failureKind(message)
    local text = tostring(message or ''):lower()
    if text:find('support', 1, true) or text:find('format', 1, true) then
        return 'notSupported'
    end
    return 'failed'
end

-- What one write means. ok, value: what LrTasks.pcall around withWriteAccessDo returned; ran: whether the function
-- inside started; results: what it recorded per file (index -> { outcome, ... }); count: the files of the write.
-- Returns 'done' (the results stand; a file without a result gets one of outcome 'failed'), 'rolledBack' (an error
-- left the function: nothing of the write stands; value is the error) or 'notRun' (the function never ran: aborted
-- after the timeout, or the write failed before it; nothing was changed), plus a text for the log.
function AddPlan.writeResult(ok, value, ran, results, count)
    if not ran then
        if ok then
            return 'notRun', 'write access to the catalog not given (' .. tostring(value) .. ')'
        end
        return 'notRun', 'the write failed before it started: ' .. tostring(value)
    end
    if not ok then
        return 'rolledBack', 'an error ended the write, so Lightroom rolled it back: ' .. tostring(value)
    end
    for i = 1, count do
        if results[i] == nil then
            results[i] = { outcome = 'failed', detail = 'no result was recorded for this file' }
        end
    end
    return 'done', tostring(value)
end

-- The counts of one run --------------------------------------------------------------------------------------------

local Run = {}
Run.__index = Run

-- A run: counts per skip and outcome, the first refused or failed files, the times (seconds).
function AddPlan.newRun()
    return setmetatable({ skips = {}, outcomes = {}, reasons = {}, skippedFolders = 0, listed = 0, problems = 0,
        times = {} }, Run)
end

function Run:skip(reason, n)
    self.skips[reason] = (self.skips[reason] or 0) + (n or 1)
end

-- Records the outcome of one file; for 'notSupported' and 'failed' the first AddPlan.MAX_REASONS are kept with
-- their reason.
function Run:outcome(key, name, detail)
    self.outcomes[key] = (self.outcomes[key] or 0) + 1
    if (key == 'notSupported' or key == 'failed') and #self.reasons < AddPlan.MAX_REASONS then
        self.reasons[#self.reasons + 1] = tostring(name) .. ': ' .. tostring(detail or 'no reason given')
    end
end

function Run:count(key)
    return self.outcomes[key] or self.skips[key] or 0
end

-- True when something went wrong that the user should look at.
function Run:troubled()
    return self:count('notSupported') + self:count('failed') + self:count('notAdded') + self.problems > 0
end

-- Texts ------------------------------------------------------------------------------------------------------------

-- The folders as one text: 'Z:\\2026\\shoot (with its sub-folders)', several on their own lines.
function AddPlan.folderText(folders, recursive)
    local suffix = recursive and ' (with sub-folders)' or ' (without sub-folders)'
    if #folders == 1 then
        return folders[1] .. suffix
    end
    local lines = { plural(#folders, 'folder', 'folders') .. suffix .. ':' }
    for _, folder in ipairs(folders) do
        lines[#lines + 1] = '    ' .. folder
    end
    return table.concat(lines, '\n')
end

local function skipLines(run)
    local lines = {}
    for _, pair in ipairs(AddPlan.SKIPS) do
        local n = run.skips[pair[1]]
        if n and n > 0 then
            lines[#lines + 1] = '    ' .. pair[2] .. ': ' .. n
        end
    end
    if run.skippedFolders > 0 then
        lines[#lines + 1] = '    folders not looked into (hidden, Lightroom data, NAS system folders): '
            .. run.skippedFolders
    end
    if run.problems > 0 then
        lines[#lines + 1] = '    folders that could not be read: ' .. run.problems
    end
    return lines
end

-- What the files are: 'camera raw files (the server's list)', with ' and other photo formats ...'.
function AddPlan.kindText(otherFormats, rawSource)
    local text = 'camera raw files (' .. (rawSource == 'server' and 'the types the server takes'
        or 'a built-in list of raw types') .. ')'
    if otherFormats then
        text = text .. ' and JPEG, TIFF, PNG, HEIC and PSD files'
    end
    return text
end

-- The question before adding. context: { folders, recursive, otherFormats, rawSource, toAdd = n, send = bool,
-- sendProblem = message (why they cannot be sent, known before adding) | nil }.
function AddPlan.planText(run, context)
    local lines = {
        string.format('%s will be added to the catalog from %s.', plural(context.toAdd, 'file', 'files'),
            AddPlan.folderText(context.folders, context.recursive)),
        '',
        'Looked for: ' .. AddPlan.kindText(context.otherFormats, context.rawSource) .. '.',
        'Lightroom is not asked for any preview. No file on disk is changed.',
    }
    if context.send and context.sendProblem then
        lines[#lines + 1] = 'The added photos cannot be sent to the server afterwards: ' .. context.sendProblem
    elseif context.send then
        lines[#lines + 1] = 'Afterwards the added photos are sent to the server.'
    end
    local already = run:count('alreadyInCatalog')
    local skipped = skipLines(run)
    if already > 0 or #skipped > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'Left out:'
        if already > 0 then
            lines[#lines + 1] = '    already in the catalog: ' .. already
        end
        for _, line in ipairs(skipped) do
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, '\n')
end

-- The summary dialog's text. context:
--   folders, recursive; cancelled = bool; stopped = message (the run stopped: no write access);
--   times = { listing, checking, adding, sending } (seconds, each optional);
--   sendText = text (what the send did) | nil; logHint = text.
function AddPlan.summaryText(run, context)
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    if context.stopped then
        add('Stopped: ' .. context.stopped)
        add('')
    elseif context.cancelled then
        add('Cancelled. The photos added before that stay in the catalog.')
        add('')
    end
    add('From ' .. AddPlan.folderText(context.folders, context.recursive) .. ':')
    local any = false
    for _, pair in ipairs(AddPlan.OUTCOMES) do
        local n = run.outcomes[pair[1]]
        if n and n > 0 then
            add('    ' .. pair[2] .. ': ' .. n)
            any = true
        end
    end
    if not any then
        add('    Nothing to add.')
    end
    if #run.reasons > 0 then
        add('')
        add('Refused or failed (the first ' .. #run.reasons .. '):')
        for _, reason in ipairs(run.reasons) do
            add('    ' .. reason)
        end
    end
    local skipped = skipLines(run)
    if #skipped > 0 then
        add('')
        add('Left out while listing:')
        for _, line in ipairs(skipped) do
            add(line)
        end
    end

    local times = context.times or {}
    local parts = {}
    if times.listing then
        parts[#parts + 1] = 'listing ' .. AddPlan.seconds(times.listing)
    end
    if times.checking then
        parts[#parts + 1] = 'looking them up in the catalog ' .. AddPlan.seconds(times.checking)
    end
    if times.adding then
        local added = run:count('added')
        local each = perItem(times.adding, added)
        parts[#parts + 1] = 'adding ' .. AddPlan.seconds(times.adding) .. (each and (' (' .. each .. ' per photo)')
            or '')
    end
    if times.sending then
        parts[#parts + 1] = 'sending ' .. AddPlan.seconds(times.sending)
    end
    if #parts > 0 then
        add('')
        add('Times: ' .. table.concat(parts, ', ') .. '.')
    end

    if context.sendText then
        add('')
        add(context.sendText)
    end
    if run:count('added') > 0 then
        add('')
        add('Lightroom lists the photos in the Library\'s Folders panel, under the folder they are in. To take them '
            .. 'out of the catalog again, select them and choose Photo > Remove Photos, then «Remove from Lightroom» '
            .. '(never «Delete from Disk»): the files on disk are not touched.')
    end
    if context.logHint then
        add('')
        add(context.logHint)
    end
    return table.concat(lines, '\n')
end

-- Log lines --------------------------------------------------------------------------------------------------------

-- One log line for a file: 'add folder: Z:\\2026\\IMG_0001.ARW: added (0.19 s)'.
function AddPlan.fileLine(path, key, detail)
    local line = AddPlan.LOG_PREFIX .. tostring(path) .. ': ' .. key
    local text = OUTCOME_TEXT[key] or SKIP_TEXT[key]
    if detail and detail ~= '' then
        line = line .. ' (' .. tostring(detail) .. ')'
    elseif text then
        line = line .. ' (' .. text .. ')'
    end
    return line
end

local function countsText(counts)
    local parts = {}
    for _, pair in ipairs(AddPlan.OUTCOMES) do
        local n = counts[pair[1]]
        if n and n > 0 then
            parts[#parts + 1] = n .. ' ' .. pair[1]
        end
    end
    return #parts > 0 and table.concat(parts, ', ') or 'nothing'
end

-- The log line of one write. info: { index, total (batches), files, counts = { [outcome] = n }, seconds (the whole
-- write), inside (seconds inside the write's function), tries (writes it took, when more than one), single = bool
-- (a file tried on its own after a rollback) }.
function AddPlan.writeLine(info)
    local what = info.single and 'retry of one file' or string.format('batch %d of %d', info.index, info.total)
    local line = string.format('%s%s: %s: %s; %s in all', AddPlan.LOG_PREFIX, what, plural(info.files, 'file', 'files'),
        countsText(info.counts or {}), AddPlan.seconds(info.seconds))
    if info.inside then
        line = line .. string.format(', %s inside the write (%s per file), %s waiting for and finishing it',
            AddPlan.seconds(info.inside), perItem(info.inside, info.files) or '-',
            AddPlan.seconds((info.seconds or 0) - info.inside))
    end
    if info.tries and info.tries > 1 then
        line = line .. ', ' .. info.tries .. ' tries'
    end
    return line
end

-- The log line after the last write: 'add folder: adding: 500 files in 10 writes: 480 added, ...; 98.2 s, 0.196 s per
-- file, 0.205 s per added photo'. counts: { [outcome] = n } of the files that were to be added.
function AddPlan.totalLine(counts, files, writes, seconds)
    local added = counts.added or 0
    local line = string.format('%sadding: %s in %s: %s; %s', AddPlan.LOG_PREFIX, plural(files, 'file', 'files'),
        plural(writes, 'write', 'writes'), countsText(counts), AddPlan.seconds(seconds))
    local perFile, perAdded = perItem(seconds, files), perItem(seconds, added)
    if perFile then
        line = line .. ', ' .. perFile .. ' per file'
    end
    if perAdded then
        line = line .. ', ' .. perAdded .. ' per added photo'
    end
    return line
end

return AddPlan
