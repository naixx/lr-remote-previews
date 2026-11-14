-- «Check the server against Lightroom»: which photo can be checked, what to do with the server's answers, and the
-- text of the result. Pure Lua 5.1: no Lightroom imports. The command (CheckServer.lua) reads the photo and the two
-- files; DngCompare compares them.
local DngCompare = require 'DngCompare'
local Jobs = require 'Jobs'
local Selection = require 'Selection'

local CompatCheck = {}

CompatCheck.LABEL = 'Compatibility check'
CompatCheck.SELECT_ONE = 'Select exactly one raw photo that has a smart preview built by Lightroom itself.'
CompatCheck.HOW_TO_BUILD = 'Let Lightroom build one first: select the photo, choose Library > Previews > Build Smart '
    .. 'Previews, wait until it is done, then run this check again. The check never builds, changes or deletes a '
    .. 'smart preview itself.'
CompatCheck.SETTINGS_HINT = 'File > Plug-in Manager > LR Remote Previews'

-- The photo to check. photo: PhotoAccess.describe's table; options as for Selection.classify (extensions,
-- mappings, availableRoots). Returns { rootId, relativePath } when it can be checked, or nil plus a message.
function CompatCheck.target(photo, options)
    local name = tostring(photo.fileName or '?')
    if photo.isVideo then
        return nil, name .. ' is a video. ' .. CompatCheck.SELECT_ONE
    end
    if type(photo.path) ~= 'string' or photo.path == '' then
        return nil, 'Lightroom gives no file path for ' .. name .. '.'
    end
    if type(photo.smartPreviewPath) ~= 'string' or photo.smartPreviewPath == '' then
        return nil, name .. ' has no smart preview. ' .. CompatCheck.HOW_TO_BUILD
    end
    -- The same checks as for sending, except that this photo must have a smart preview: a copy without it, and
    -- not as a virtual copy (the file is what counts).
    local copy = {}
    for key, value in pairs(photo) do
        copy[key] = value
    end
    copy.smartPreviewPath, copy.isVirtualCopy = nil, false
    local sorted = Selection.classify({ copy }, options)
    if #sorted.eligible == 1 then
        return { rootId = copy.rootId, relativePath = copy.relativePath }
    end
    local skipped = sorted.skipped[1]
    if skipped.reason == 'unsupportedFormat' then
        return nil, string.format('The server does not take %s files (it takes %s), so it cannot build %s.',
            tostring(skipped.detail), table.concat(options.extensions or {}, ', '), name)
    elseif skipped.reason == 'noMapping' then
        return nil, string.format('%s is not under any local prefix of the path mappings (%s). Set them in %s.', name,
            tostring(skipped.detail), CompatCheck.SETTINGS_HINT)
    elseif skipped.reason == 'rootUnavailable' then
        return nil, string.format('%s is in the server root "%s", which the server does not list as available.',
            name, tostring(skipped.detail))
    end
    return nil, name .. ' cannot be checked (' .. tostring(skipped.reason) .. ').'
end

local function errorText(item)
    local code = (item.error and item.error.code) or 'unknown'
    local message = item.error and item.error.message
    return code .. (message and (': ' .. message) or '')
end

local function usableResult(result)
    return type(result) == 'table' and type(result.size) == 'number'
end

-- What to do after the lookup. answer: the lookup answer for the photo ({ state, error, result }); converterInstalled:
-- info.converter.installed. Returns { action = 'download', result } when the server has the file, { action = 'build' }
-- when a one-item job has to build it, or nil plus a message.
function CompatCheck.afterLookup(answer, converterInstalled)
    if type(answer) ~= 'table' then
        return nil, 'The server did not answer for this photo.'
    end
    if answer.state == 'ready' then
        if not usableResult(answer.result) or not Jobs.isCacheKey(answer.result.key) then
            return nil, 'The server says the file is ready but does not name it properly.'
        end
        return { action = 'download', result = answer.result }
    elseif answer.state == 'rejected' then
        return nil, 'The server refused the photo (' .. errorText(answer) .. ').'
    end
    if not converterInstalled then
        return nil, 'The server does not have this photo built, and it cannot build it: Adobe DNG Converter is not '
            .. 'installed there.'
    end
    return { action = 'build' }
end

-- What to do with the item of the one-item job once it is final (Jobs.normalizeItem). Returns
-- { action = 'download', result, itemId }, or nil plus a message.
function CompatCheck.afterJob(item)
    if type(item) ~= 'table' then
        return nil, 'The server never finished the job.'
    end
    if item.state == 'ready' then
        if not usableResult(item.result) then
            return nil, 'The server says the file is ready but gives no file size.'
        end
        return { action = 'download', result = item.result, itemId = item.id }
    elseif item.state == 'failed' then
        return nil, 'The server could not build the photo (' .. errorText(item) .. ').'
    elseif item.state == 'rejected' then
        return nil, 'The server refused the photo (' .. errorText(item) .. ').'
    end
    return nil, 'The job was cancelled on the server.'
end

-- True when a Software tag names Adobe DNG Converter, which means the smart preview in the catalog was probably
-- delivered by this plug-in rather than built by Lightroom.
function CompatCheck.madeByConverter(software)
    return type(software) == 'string' and software:lower():find('dng converter', 1, true) ~= nil
end

-- The dialog style: DngCompare's, and at least a warning when the catalog's smart preview was not Lightroom's.
function CompatCheck.style(report)
    local style = DngCompare.style(report)
    if style == 'info' and CompatCheck.madeByConverter(report.software.lightroom) then
        return 'warning'
    end
    return style
end

-- The text of the result. context: { fileName, lightroomVersion, serverName, serverVersion, converterVersion,
-- built (true when the server built the file for this check, false when it had it already) }.
function CompatCheck.text(report, context)
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    add(DngCompare.verdictLine(report))
    add('')
    add('Photo: ' .. tostring(context.fileName))
    add(string.format('Lightroom: %s; its smart preview names "%s" as its software.',
        context.lightroomVersion and ('version ' .. context.lightroomVersion) or 'version unknown',
        report.software.lightroom or 'nothing'))
    add(string.format('Server: %s %s with Adobe DNG Converter %s; its file names "%s" as its software (%s).',
        tostring(context.serverName or 'LR Remote Previews'), tostring(context.serverVersion or '?'),
        context.converterVersion or '(version unknown)', report.software.server or 'nothing',
        context.built and 'built for this check' or 'it was in the server\'s cache'))
    if CompatCheck.madeByConverter(report.software.lightroom) then
        add('')
        add('The smart preview in the catalog was written by Adobe DNG Converter, so it was probably delivered from '
            .. 'the server rather than built by Lightroom, and this check says nothing about Lightroom. Discard it '
            .. '(Library > Previews > Discard Smart Previews), let Lightroom build it again, then check again.')
    end
    add('')
    for _, line in ipairs(DngCompare.detailLines(report)) do
        add(line)
    end
    if report.verdict == 'tilesDiffer' then
        add('')
        add('This has been seen before: of 7 photos compared during development (Lightroom Classic 15.6, Adobe DNG '
            .. 'Converter 17.2), 6 were fully identical and one had 27 of 28 identical tiles. The structure is the '
            .. 'same; not every tile is byte-identical to Lightroom\'s.')
    elseif report.verdict == 'different' then
        add('')
        add('The server does not make the file Lightroom makes. Do not rely on its smart previews until this is '
            .. 'understood.')
    end
    return table.concat(lines, '\n')
end

return CompatCheck
