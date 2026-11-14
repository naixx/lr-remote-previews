-- Counts what happened to every photo in one run of a command (send, fetch), and writes the dialog texts, the short
-- notices and the per-photo log lines. Pure Lua 5.1: no Lightroom imports.
local RunSummary = {}
RunSummary.__index = RunSummary

-- Photos left out before anything was sent or looked up, in the order listed.
RunSummary.SKIPS = {
    { 'video', 'videos' },
    { 'noPath', 'no file path in the catalog' },
    { 'hasSmartPreview', 'already have a smart preview' },
    { 'unsupportedFormat', 'a file type the server does not take' },
    { 'noMapping', 'not under any local prefix of the path mappings' },
    { 'rootUnavailable', 'their server root is missing or not available' },
    { 'sameFile', 'same file as another selected photo (virtual copies)' },
    { 'noLocalId', 'Lightroom gave no catalog id' },
    { 'noFileId', 'not found in the catalog database' },
    { 'fileIdMismatch', 'the catalog database names a different file' },
    { 'notInCatalog', 'built on the server, but not in this catalog (removed, or the path mappings changed)' },
    { 'badPath', 'built on the server, but the path cannot be mapped to this computer' },
}

-- What happened to the photos that were sent or looked up, in the order listed.
RunSummary.OUTCOMES = {
    { 'delivered', 'Smart previews placed and registered by Lightroom' },
    { 'deliveredOther', 'Placed, but Lightroom did not answer "existed"' },
    { 'placed', 'Placed; registered with Lightroom once no import is running' },
    { 'destinationExists', 'A smart preview file was already there (left alone)' },
    { 'checkFailed', 'Discarded: the file did not pass the check' },
    { 'downloadFailed', 'Download failed' },
    { 'notInCache', 'Gone from the server\'s cache since it was looked up (fetch again)' },
    { 'writeFailed', 'Could not be written into the smart preview folder' },
    { 'failed', 'The server could not build them' },
    { 'rejected', 'The server refused them' },
    { 'pending', 'Still being built on the server' },
    { 'absent', 'Not on the server (never sent, or the original changed since; send them again)' },
    { 'cancelled', 'Cancelled on the server' },
    { 'notDelivered', 'Not finished: the run stopped first' },
}

local SKIP_TEXT, OUTCOME_TEXT = {}, {}
for _, pair in ipairs(RunSummary.SKIPS) do
    SKIP_TEXT[pair[1]] = pair[2]
end
for _, pair in ipairs(RunSummary.OUTCOMES) do
    OUTCOME_TEXT[pair[1]] = pair[2]
end

function RunSummary.new(selected)
    return setmetatable({ selected = selected or 0, sent = 0, skips = {}, outcomes = {}, codes = {} }, RunSummary)
end

function RunSummary:skip(reason)
    self.skips[reason] = (self.skips[reason] or 0) + 1
end

-- Records the outcome of one sent photo; code (optional) is the server's error.code for 'failed'/'rejected'.
function RunSummary:outcome(key, code)
    self.outcomes[key] = (self.outcomes[key] or 0) + 1
    if code then
        self.codes[key] = self.codes[key] or {}
        self.codes[key][code] = (self.codes[key][code] or 0) + 1
    end
end

function RunSummary:count(key)
    return self.outcomes[key] or self.skips[key] or 0
end

-- Placed smart previews (Lightroom answered 'existed' or something else, or registration still to come).
function RunSummary:placed()
    return self:count('delivered') + self:count('deliveredOther') + self:count('placed')
end

-- True when something went wrong that the user should look at.
function RunSummary:troubled()
    return self:count('checkFailed') + self:count('writeFailed') + self:count('downloadFailed')
        + self:count('deliveredOther') + self:count('notInCache') > 0
end

local function plural(n, one, many)
    return n .. ' ' .. (n == 1 and one or many)
end

local function codesText(codes)
    local keys = {}
    for code in pairs(codes or {}) do
        keys[#keys + 1] = code
    end
    if #keys == 0 then
        return ''
    end
    table.sort(keys)
    for i, code in ipairs(keys) do
        keys[i] = code .. ': ' .. codes[code]
    end
    return ' (' .. table.concat(keys, ', ') .. ')'
end

-- The number of photos left out and one indented line per reason.
function RunSummary:skipLines()
    local skipped, lines = 0, {}
    for _, pair in ipairs(RunSummary.SKIPS) do
        local n = self.skips[pair[1]]
        if n and n > 0 then
            skipped = skipped + n
            lines[#lines + 1] = '    ' .. pair[2] .. ': ' .. n
        end
    end
    return skipped, lines
end

-- One indented line per outcome that happened, with the server's error codes.
function RunSummary:outcomeLines()
    local lines = {}
    for _, pair in ipairs(RunSummary.OUTCOMES) do
        local n = self.outcomes[pair[1]]
        if n and n > 0 then
            lines[#lines + 1] = '    ' .. pair[2] .. ': ' .. n .. codesText(self.codes[pair[1]])
        end
    end
    return lines
end

-- The question before sending: how many photos go to the server and why the others do not.
function RunSummary:plan(toSend)
    local lines = { string.format('%s of the %s selected will be sent to the server.',
        plural(toSend, 'photo', 'photos'), self.selected) }
    local skipped, skipLines = self:skipLines()
    if skipped > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'Not sent (' .. skipped .. '):'
        for _, line in ipairs(skipLines) do
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, '\n')
end

-- The summary dialog's text. context:
--   cancelled = bool, cancelledText = text (default: the job was cancelled on the server), cancelProblem = message,
--   aborted = message, header = text (default 'N photos selected, M sent to the server.'),
--   skipHeading = text (default 'Not sent'), notes = { line, ... } (after the skips), stoppedBefore = message,
--   logHint = text.
function RunSummary:text(context)
    context = context or {}
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end

    if context.aborted then
        add('Stopped: ' .. context.aborted)
        add('')
    elseif context.cancelled then
        add(context.cancelledText or 'Cancelled. The job was cancelled on the server; files already placed stay.')
        if context.cancelProblem then
            add('Cancelling on the server failed: ' .. context.cancelProblem)
        end
        add('')
    end

    add(context.header
        or (plural(self.selected, 'photo', 'photos') .. ' selected, ' .. self.sent .. ' sent to the server.'))

    local outcomeLines = self:outcomeLines()
    if #outcomeLines > 0 then
        add('')
        for _, line in ipairs(outcomeLines) do
            add(line)
        end
    end

    local skipped, skipLines = self:skipLines()
    if skipped > 0 then
        add('')
        add((context.skipHeading or 'Not sent') .. ' (' .. skipped .. '):')
        for _, line in ipairs(skipLines) do
            add(line)
        end
    end

    if context.notes and #context.notes > 0 then
        add('')
        for _, line in ipairs(context.notes) do
            add(line)
        end
    end
    if context.stoppedBefore then
        add('')
        add(context.stoppedBefore)
    end
    if context.logHint then
        add('')
        add(context.logHint)
    end
    return table.concat(lines, '\n')
end

-- The text after «Build smart previews on the server». context: { jobIds = { n, ... }, ready = n (items the server
-- had built already), rejected = n (with codes recorded as outcome 'rejected'), failedParts = message | nil (some
-- jobs could not be created), fetchHint = text, logHint = text }.
function RunSummary:sendText(context)
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    local jobs = context.jobIds or {}
    local jobText = #jobs == 1 and ('job ' .. jobs[1]) or ('jobs ' .. table.concat(jobs, ', '))
    add(string.format('%s sent to the server (%s). The server builds the smart previews in the background; '
        .. 'Lightroom does not have to stay open.', plural(self.sent, 'photo was', 'photos were'), jobText))
    local details = {}
    if (context.ready or 0) > 0 then
        details[#details + 1] = '    Built already (the server had them): ' .. context.ready
    end
    if (context.rejected or 0) > 0 then
        details[#details + 1] = '    Refused by the server: ' .. context.rejected .. codesText(self.codes.rejected)
    end
    if #details > 0 then
        add('')
        for _, line in ipairs(details) do
            add(line)
        end
    end
    if context.failedParts then
        add('')
        add(context.failedParts)
    end
    if context.fetchHint then
        add('')
        add(context.fetchHint)
    end
    local skipped, skipLines = self:skipLines()
    if skipped > 0 then
        add('')
        add('Not sent (' .. skipped .. '):')
        for _, line in ipairs(skipLines) do
            add(line)
        end
    end
    if context.logHint then
        add('')
        add(context.logHint)
    end
    return table.concat(lines, '\n')
end

-- True when a send left something the user should see in a dialog: photos left out, refused by the server, or a part
-- not sent. context: as for sendText.
function RunSummary:sendNeedsAttention(context)
    local skipped = self:skipLines()
    return skipped > 0 or (context.rejected or 0) > 0 or context.failedParts ~= nil
end

-- The short notice after a send that needs no dialog. autoFetch: whether the automatic fetch is on.
function RunSummary:sentNotice(autoFetch)
    return plural(self.sent, 'photo', 'photos') .. ' sent to the server; '
        .. (autoFetch and 'their smart previews arrive by themselves'
            or 'fetch their smart previews with «Fetch ready smart previews» when they are ready')
end

-- One log line for a photo: 'IMG_0001.ARW: delivered (DNG 1.7.0.0, <path>)' (Pipeline.place puts the path into the
-- detail).
function RunSummary.photoLine(fileName, key, detail)
    local line = tostring(fileName) .. ': ' .. key
    local text = SKIP_TEXT[key] or OUTCOME_TEXT[key]
    if detail and detail ~= '' then
        line = line .. ' (' .. tostring(detail) .. ')'
    elseif text then
        line = line .. ' (' .. text .. ')'
    end
    return line
end

-- One line for the log of the automatic fetch: '3 placed, 1 still being built, 2 failed downloads'.
function RunSummary:shortText()
    local parts = {}
    local function part(n, text)
        if n > 0 then
            parts[#parts + 1] = n .. ' ' .. text
        end
    end
    part(self:placed(), 'placed')
    part(self:count('destinationExists'), 'already there')
    part(self:count('checkFailed'), 'discarded by the check')
    part(self:count('downloadFailed') + self:count('notInCache'), 'downloads failed')
    part(self:count('writeFailed'), 'writes failed')
    part(self:count('pending'), 'still being built')
    part(self:count('absent'), 'not on the server')
    part(self:count('rejected'), 'refused')
    part(self:count('notDelivered'), 'not finished')
    if #parts == 0 then
        return 'nothing to place'
    end
    return table.concat(parts, ', ')
end

return RunSummary
