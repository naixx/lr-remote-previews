-- Adds files to the catalog for «Add a folder without previews...»: catalog:addPhoto, in batches, each batch inside one
-- catalog:withWriteAccessDo. It never asks Lightroom for a preview of any kind (no buildSmartPreview, no thumbnail or
-- preview request); what Lightroom does by itself afterwards is Lightroom's. It never opens, changes, moves or deletes
-- a file. The decisions (batches, what the answer of a write means, the texts) are AddPlan's, whose header quotes what
-- the SDK documents; this file connects them to the SDK. Must run inside an LrTasks task.
local LrDate = import 'LrDate'
local LrTasks = import 'LrTasks'

local AddPlan = require 'AddPlan'
local Log = require 'Log'
local PhotoAccess = require 'PhotoAccess'

local PhotoAdder = {}

-- The time in seconds, for the log's timings. LrDate.currentTime() counts seconds (since 2001); that it has a
-- fraction of a second is assumed, not verified.
function PhotoAdder.now()
    local ok, value = LrTasks.pcall(LrDate.currentTime)
    if ok and type(value) == 'number' then
        return value
    end
    return os.time()
end

local now = PhotoAdder.now

-- One write: files inside one withWriteAccessDo. lookFirst: look each file up in the catalog before adding it (when
-- the files are tried again: a write that did not seem to run may still have run). onFile(i) after each file.
-- Returns kind ('done' | 'rolledBack' | 'notRun'), a text, the results (index -> { outcome, photo, detail, seconds }),
-- the seconds of the whole write and the seconds inside its function.
local function write(catalog, files, lookFirst, onFile)
    local results, ran, inside = {}, false, nil
    local started = now()
    local ok, value = LrTasks.pcall(function()
        return catalog:withWriteAccessDo(AddPlan.ACTION_NAME, function()
            ran = true
            local entered = now()
            for i, file in ipairs(files) do
                local fileStarted = now()
                local existing = lookFirst and PhotoAccess.findByPath(catalog, file.path) or nil
                if existing then
                    results[i] = { outcome = 'alreadyInCatalog', photo = existing, detail = 'found when tried again' }
                else
                    -- LrTasks.pcall, not pcall: addPhoto may wait inside (the SDK lets the function yield), and a
                    -- plain pcall cannot be waited across. An error caught here does not leave the write, so the
                    -- other files of the batch are kept.
                    local added, photo = LrTasks.pcall(function()
                        return catalog:addPhoto(file.path)
                    end)
                    if added and photo ~= nil then
                        results[i] = { outcome = 'added', photo = photo }
                    elseif added then
                        results[i] = { outcome = 'failed', detail = 'Lightroom gave no photo back' }
                    else
                        results[i] = { outcome = AddPlan.failureKind(photo), detail = tostring(photo) }
                    end
                end
                results[i].seconds = now() - fileStarted
                onFile(i)
                LrTasks.yield()
            end
            inside = now() - entered
        end, { timeout = AddPlan.WRITE_TIMEOUT })
    end)
    local kind, text = AddPlan.writeResult(ok, value, ran, results, #files)
    return kind, text, results, now() - started, inside
end

-- A write tried again while it does not run, at most AddPlan.MAX_WAITS times. Returns what write returns plus the
-- number of tries; kind 'stopped' when it never ran.
local function writeWithWaits(catalog, files, lookFirst, onFile)
    local tries = 0
    while true do
        tries = tries + 1
        local kind, text, results, seconds, inside = write(catalog, files, lookFirst or tries > 1, onFile)
        if kind ~= 'notRun' then
            return kind, text, results, seconds, inside, tries
        end
        Log.warn('%swrite of %d file(s), try %d of %d: %s', AddPlan.LOG_PREFIX, #files, tries, AddPlan.MAX_WAITS,
            text)
        if tries >= AddPlan.MAX_WAITS then
            return 'stopped', text, nil, seconds, nil, tries
        end
        LrTasks.sleep(AddPlan.WAIT_PAUSE)
    end
end

-- Records the results of a write that stands: in run, total (counts per outcome of this run's adding), the log, and
-- the list of added photos. Returns the counts of this write.
local function record(run, total, files, results, added)
    local counts = {}
    for i, file in ipairs(files) do
        local result = results[i]
        counts[result.outcome] = (counts[result.outcome] or 0) + 1
        total[result.outcome] = (total[result.outcome] or 0) + 1
        run:outcome(result.outcome, file.name, result.detail and AddPlan.errorText(result.detail))
        local detail = AddPlan.seconds(result.seconds)
        if result.detail then
            detail = result.detail .. ', ' .. detail
        end
        Log.info('%s', AddPlan.fileLine(file.path, result.outcome, detail))
        if result.outcome == 'added' then
            added[#added + 1] = result.photo
        end
    end
    return counts
end

local function notAdded(run, total, files, from)
    for i = from, #files do
        run:outcome('notAdded', files[i].name)
        total.notAdded = (total.notAdded or 0) + 1
        Log.info('%s', AddPlan.fileLine(files[i].path, 'notAdded'))
    end
end

-- Adds files ({ path, name }, in order) to the catalog. run: AddPlan.newRun(). ui: { caption, portion, isCanceled }
-- (Pipeline.progressUi); cancel is honoured between writes. onWritten(photos) (optional) is called with the photos
-- each write added, right after it.
-- Returns { added = { LrPhoto, ... }, cancelled = bool, stopped = message | nil, seconds = total, writes = n }.
function PhotoAdder.addAll(catalog, files, run, ui, onWritten)
    local batches = AddPlan.batches(files, AddPlan.BATCH_SIZE)
    local outcome = { added = {}, cancelled = false, stopped = nil, seconds = 0, writes = 0 }
    local total = {}
    local started = now()
    local done = 0
    local function progress(name)
        return function(i)
            ui.portion(done + i, #files)
            ui.caption(string.format('Adding %d of %d (%s)', done + i, #files, name(i)))
        end
    end
    local function stop(text, from)
        outcome.stopped = 'Lightroom did not give the plug-in write access to the catalog (' .. text .. '; '
            .. AddPlan.MAX_WAITS .. ' tries of up to ' .. AddPlan.WRITE_TIMEOUT .. ' s each). Run the command again '
            .. 'on the same folder: the files added so far are left alone.'
        notAdded(run, total, files, from)
    end
    for index, batch in ipairs(batches) do
        if ui.isCanceled() then
            outcome.cancelled = true
            notAdded(run, total, files, done + 1)
            break
        end
        local kind, text, results, seconds, inside, tries = writeWithWaits(catalog, batch, false, progress(function(i)
            return batch[i].name
        end))
        outcome.writes = outcome.writes + tries
        if kind == 'stopped' then
            stop(text, done + 1)
            break
        end
        local before = #outcome.added
        if kind == 'done' then
            local counts = record(run, total, batch, results, outcome.added)
            Log.info('%s', AddPlan.writeLine({ index = index, total = #batches, files = #batch, counts = counts,
                seconds = seconds, inside = inside, tries = tries }))
        else
            -- Rolled back: nothing of this write stands. Each file is tried again in a write of its own, looked up
            -- first.
            Log.warn('%sbatch %d of %d: %s; trying its %d file(s) one at a time', AddPlan.LOG_PREFIX, index, #batches,
                text, #batch)
            for i, file in ipairs(batch) do
                local singleKind, singleText, singleResults, singleSeconds, singleInside, singleTries =
                    writeWithWaits(catalog, { file }, true, progress(function()
                        return file.name
                    end))
                outcome.writes = outcome.writes + singleTries
                if singleKind == 'stopped' then
                    stop(singleText, done + i)
                    break
                end
                if singleKind == 'rolledBack' then
                    singleResults = { { outcome = AddPlan.failureKind(singleText), detail = singleText,
                        seconds = singleSeconds } }
                end
                local counts = record(run, total, { file }, singleResults, outcome.added)
                Log.info('%s', AddPlan.writeLine({ single = true, files = 1, counts = counts, seconds = singleSeconds,
                    inside = singleInside, tries = singleTries }))
            end
        end
        done = done + #batch
        if onWritten and #outcome.added > before then
            local photos = {}
            for i = before + 1, #outcome.added do
                photos[#photos + 1] = outcome.added[i]
            end
            onWritten(photos)
        end
        if outcome.stopped then
            break
        end
    end
    outcome.seconds = now() - started
    Log.info('%s', AddPlan.totalLine(total, #files, outcome.writes, outcome.seconds))
    return outcome
end

return PhotoAdder
