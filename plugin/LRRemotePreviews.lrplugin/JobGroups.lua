-- Which job the automatic send puts new photos into. Pure Lua 5.1: the store (Lightroom's preferences for the plug-in)
-- and the clock are passed in.
--
-- One Lightroom import is one job (docs/protocol.md, POST /api/v1/jobs/{id}/items): the first photos of an import
-- create the job, labelled with the import's local time and its folder ("Lightroom import 2026-11-14 15:15, shoot");
-- later photos of the same import are added to it, also after a restart of Lightroom. When the job would hold more than
-- the server's maxItemsPerJob, the rest goes into a new job ("... (part 2)"). Photos that belong to no import record
-- are sent per round as one job, as before. Against a server without capabilities.appendItems (before server 0.6.0)
-- every round creates new jobs, still one per import.
--
-- Remembered per catalog under JobGroups.KEY (one JSON text, keyed by the catalog path as CatalogState does it):
--   { ["106106"] = { job = 12, count = 449, label = "Lightroom import ...", part = 1, at = <os.time()> } }
-- An entry is forgotten MAX_AGE_DAYS after it last changed, like a pending job.
local Json = require 'Json'
local PathMap = require 'PathMap'

local JobGroups = {}

JobGroups.KEY = 'importJobs'
JobGroups.MAX_AGE_DAYS = 7
JobGroups.ROUND_LABEL = 'Lightroom import (automatic)'
JobGroups.MAX_LABEL = 100 -- characters (docs/protocol.md: label at most 100)

local function isCount(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value)
end

local function loadAll(store)
    local text = store[JobGroups.KEY]
    if type(text) ~= 'string' or text == '' then
        return {}
    end
    local ok, decoded = pcall(Json.decode, text)
    if not ok or type(decoded) ~= 'table' then
        return {}
    end
    return decoded
end

-- The groups of this catalog: { [import id text] = { job, count, label, part, at } }; malformed or old entries are
-- dropped (old ones only when now is given).
function JobGroups.load(store, catalogPath, now)
    local key = PathMap.fileKey(catalogPath)
    local raw = key and loadAll(store)[key]
    local groups = {}
    local oldest = now and (now - JobGroups.MAX_AGE_DAYS * 86400) or nil
    for id, entry in pairs(type(raw) == 'table' and raw or {}) do
        if type(id) == 'string' and id:match('^%d+$') and type(entry) == 'table' and isCount(entry.job)
            and entry.job > 0 and isCount(entry.count) and type(entry.label) == 'string' and isCount(entry.at)
            and (oldest == nil or entry.at >= oldest) then
            groups[id] = { job = entry.job, count = entry.count, label = entry.label,
                part = isCount(entry.part) and math.max(1, entry.part) or 1, at = entry.at }
        end
    end
    return groups
end

-- Stores the groups of this catalog; other catalogs' groups are kept.
function JobGroups.save(store, catalogPath, groups)
    local key = PathMap.fileKey(catalogPath)
    if not key then
        return false
    end
    local all = loadAll(store)
    all[key] = next(groups) ~= nil and groups or nil
    store[JobGroups.KEY] = Json.encode(all)
    return true
end

-- At most max characters of a UTF-8 text (never cuts a character in two).
function JobGroups.cut(text, max)
    local count, stop = 0, 0
    for position, char in text:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
        count = count + 1
        if count > max then
            break
        end
        stop = position + #char - 1
    end
    return text:sub(1, stop)
end

-- The label of an import's job: its local time ("2026-11-14T15:15:56.060+01:00" gives "2026-11-14 15:15", nothing
-- when the date has another form) and the folder's name; part > 1 adds " (part n)".
function JobGroups.label(importDate, folderName, part)
    local day, time = tostring(importDate or ''):match('^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)')
    local text = 'Lightroom import'
    if day then
        text = text .. ' ' .. day .. ' ' .. time
    end
    if type(folderName) == 'string' and folderName ~= '' then
        text = text .. ', ' .. folderName
    end
    local suffix = (part or 1) > 1 and string.format(' (part %d)', part) or ''
    return JobGroups.cut(text, JobGroups.MAX_LABEL - #suffix) .. suffix
end

-- The base label with " (part n)" for part > 1 (a stored label never carries the suffix).
function JobGroups.partLabel(label, part)
    local suffix = (part or 1) > 1 and string.format(' (part %d)', part) or ''
    return JobGroups.cut(label, JobGroups.MAX_LABEL - #suffix) .. suffix
end

-- The common folder of a list of folders as the catalog spells them ("Z:/2026/a/" and "Z:/2026/b/" give "Z:/2026/").
local function commonFolder(folders)
    local common
    for _, folder in ipairs(folders) do
        if common == nil then
            common = folder
        else
            local i = 0
            while i < #common and i < #folder and common:sub(i + 1, i + 1) == folder:sub(i + 1, i + 1) do
                i = i + 1
            end
            common = common:sub(1, i):match('^(.*[/\\])') or ''
        end
    end
    return common
end

local function chunk(list, first, size)
    local part = {}
    for i = first, math.min(#list, first + size - 1) do
        part[#part + 1] = list[i]
    end
    return part
end

-- Splits photos into the batches of one round. photos: the photos to send ({ id, importId, folder, ... }, ascending
-- id); groups: JobGroups.load(); imports: { [import id] = date } of the import records read; folderName(folder) ->
-- the name for a label; options: { maxItems = n (nil: no limit), append = bool (the server can add items) }.
-- Returns the batches in the order to send them:
--   { { key = '106106' | nil (no import), importId, base (label without the part), label, part,
--       jobId = n | nil, photos = { ... } }, ... }
-- jobId is the job to add the photos to; nil means a new job. The photos of one import that do not fit the room left
-- in its job (maxItems - count) go into new jobs of at most maxItems photos, each with the next part number. Without
-- append, every round's photos of an import go into new jobs, numbered on from the import's last part.
function JobGroups.plan(photos, groups, imports, folderName, options)
    local maxItems = options.maxItems
    local order, byKey = {}, {}
    for _, photo in ipairs(photos) do
        local key = (photo.importId or 0) > 0 and string.format('%d', photo.importId) or ''
        if not byKey[key] then
            byKey[key] = {}
            order[#order + 1] = key
        end
        local list = byKey[key]
        list[#list + 1] = photo
    end
    local batches = {}
    for _, key in ipairs(order) do
        local list = byKey[key]
        local group = key ~= '' and groups[key] or nil
        local base, part
        if key == '' then
            base, part = JobGroups.ROUND_LABEL, 0
        elseif group then
            base, part = group.label, group.part
        else
            local folders = {}
            for _, photo in ipairs(list) do
                folders[#folders + 1] = photo.folder or ''
            end
            base, part = JobGroups.label(imports[tonumber(key)], folderName(commonFolder(folders)), 1), 0
        end
        local importKey = key ~= '' and key or nil
        local importId = importKey and tonumber(importKey) or nil
        local first = 1
        if group and options.append then
            local room = maxItems and (maxItems - group.count) or #list
            if room > 0 then
                local here = chunk(list, 1, room)
                batches[#batches + 1] = { key = importKey, importId = importId, base = base,
                    label = JobGroups.partLabel(base, part), part = part, jobId = group.job, photos = here }
                first = #here + 1
            end
        end
        while first <= #list do
            part = part + 1
            local here = chunk(list, first, maxItems or #list)
            batches[#batches + 1] = { key = importKey, importId = importId, base = base,
                label = JobGroups.partLabel(base, part), part = part, photos = here }
            first = first + #here
        end
    end
    return batches
end

-- What to do when adding items to a job failed (problem: { status, code } from HttpJson): 'newJob' when the job cannot
-- take them (too_many_items, job_cancelled, the job is gone, a ref it already has), 'stop' otherwise (the server is not
-- reachable or answered with another error: the round ends and the photos are sent by a later round).
function JobGroups.afterAppendFailure(problem)
    problem = problem or {}
    if problem.code == 'too_many_items' or problem.status == 413 or problem.code == 'job_cancelled'
        or problem.code == 'duplicate_ref' or problem.status == 404 then
        return 'newJob'
    end
    return 'stop'
end

-- Records a job just created for an import (key) with count photos.
function JobGroups.created(groups, key, jobId, count, label, part, now)
    if key then
        groups[key] = { job = jobId, count = count, label = label, part = part, at = now }
    end
end

-- Records count photos added to the job of an import.
function JobGroups.added(groups, key, count, now)
    local group = key and groups[key]
    if group then
        group.count = group.count + count
        group.at = now
    end
end

return JobGroups
