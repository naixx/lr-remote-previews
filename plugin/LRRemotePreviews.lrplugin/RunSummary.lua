-- Counts what happened to every selected photo in one run of "Build smart previews on the server", and writes
-- the summary dialog's text and the per-photo log lines. Pure Lua 5.1: no Lightroom imports.
local RunSummary = {}
RunSummary.__index = RunSummary

-- Photos left out before anything was sent, in the order listed.
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
}

-- What happened to the photos that were sent, in the order listed.
RunSummary.OUTCOMES = {
    { 'delivered', 'Smart previews placed and registered by Lightroom' },
    { 'deliveredOther', 'Placed, but Lightroom did not answer "existed"' },
    { 'destinationExists', 'A smart preview file was already there (left alone)' },
    { 'checkFailed', 'Discarded: the file did not pass the check' },
    { 'downloadFailed', 'Download failed' },
    { 'writeFailed', 'Could not be written into the smart preview folder' },
    { 'failed', 'The server could not build them' },
    { 'rejected', 'The server refused them' },
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

-- The summary dialog's text. context: { cancelled = bool, aborted = message | nil, logHint = text,
-- cancelProblem = message | nil, stoppedBefore = message | nil }.
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
        add('Cancelled. The job was cancelled on the server; files already placed stay.')
        if context.cancelProblem then
            add('Cancelling on the server failed: ' .. context.cancelProblem)
        end
        add('')
    end

    add(plural(self.selected, 'photo', 'photos') .. ' selected, ' .. self.sent .. ' sent to the server.')

    local outcomeLines = {}
    for _, pair in ipairs(RunSummary.OUTCOMES) do
        local n = self.outcomes[pair[1]]
        if n and n > 0 then
            outcomeLines[#outcomeLines + 1] = '    ' .. pair[2] .. ': ' .. n .. codesText(self.codes[pair[1]])
        end
    end
    if #outcomeLines > 0 then
        add('')
        for _, line in ipairs(outcomeLines) do
            add(line)
        end
    end

    local skipped, skipLines = self:skipLines()
    if skipped > 0 then
        add('')
        add('Not sent (' .. skipped .. '):')
        for _, line in ipairs(skipLines) do
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

-- One log line for a photo: 'IMG_0001.ARW: delivered (DNG 1.7.0.0) -> <path>'.
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

return RunSummary
