-- When an import counts as over for the automatic fetch (since plug-in 0.8.3). Pure Lua 5.1.
--
-- Seen with plug-in 0.8.2: Lightroom's own task «Fetching Initial Previews» (it reads the embedded previews from the
-- originals, over the same link from the NAS) went on for about 3.5 minutes after the last photo was added (1384
-- photos, 0.34 s per photo), and the user took the end of that task for the end of the import. So the fetch in one go
-- waits for it: the import is over when no new photo has come for the quiet time of the automatic send (WatchMode) AND
-- the number of the import's photos with a preview better than the 160-pixel placeholder has stopped growing for
-- QUIET_SECONDS (or all of them have one). The plug-in cannot see Lightroom's tasks; it reads the preview index:
-- <catalog name> Previews.lrdata/previews.db next to the catalog, table Pyramid (uuid = the file UUID, the same value
-- as AgLibraryFile.id_global; quality 'thumbnail' for the placeholder, then 'embedded', 'standard', 'final',
-- 'bigThumbnail'), with sqlite3, read-only, every READ_SECONDS. At most LIMIT_SECONDS after the photos stopped (a
-- preview task the user cancelled, photos that never get a preview) the fetch begins anyway; when the index cannot be
-- read, or no photo of the import is known (after a restart), at once, as before 0.8.3.
--
--   local state = PreviewWatch.new()
--   PreviewWatch.photosOver(state, now)                 -- the photos stopped coming
--   if PreviewWatch.readDue(state, now) then PreviewWatch.observe(state, count, total, now, problem) end
--   local over, why = PreviewWatch.over(state, now)     -- why: 'all', 'stable', 'limit', 'unreadable', 'none'
local PreviewWatch = {}

PreviewWatch.READ_SECONDS = 10 -- between two reads of the preview index
PreviewWatch.QUIET_SECONDS = 30 -- the count has not grown for this long: Lightroom's preview task is over
PreviewWatch.LIMIT_SECONDS = 15 * 60 -- after the photos stopped, the fetch begins anyway
PreviewWatch.CHUNK = 500 -- file UUIDs per SELECT

function PreviewWatch.new()
    return {}
end

function PreviewWatch.reset(state)
    for key in pairs(state) do
        state[key] = nil
    end
end

function PreviewWatch.photosOver(state, now)
    if not state.photosOverAt then
        state.photosOverAt = now
    end
end

function PreviewWatch.readDue(state, now)
    return state.photosOverAt ~= nil and not state.unreadable
        and (state.readAt == nil or now - state.readAt >= PreviewWatch.READ_SECONDS)
end

-- One read: count of the import's photos with a better preview, total of them; count nil plus problem: not readable.
function PreviewWatch.observe(state, count, total, now, problem)
    state.readAt = now
    if count == nil then
        state.unreadable = tostring(problem or 'no answer')
        return
    end
    if state.count == nil or count > state.count then
        state.grewAt = now
    end
    state.count, state.total = count, total
end

-- Whether the import is over for the fetch, and why.
function PreviewWatch.over(state, now)
    if not state.photosOverAt then
        return false
    end
    if state.unreadable then
        return true, 'unreadable'
    end
    if state.count == nil then
        return false
    end
    if (state.total or 0) == 0 then
        return true, 'none'
    end
    if state.count >= state.total then
        return true, 'all'
    end
    if now - state.grewAt >= PreviewWatch.QUIET_SECONDS then
        return true, 'stable'
    end
    if now - state.photosOverAt >= PreviewWatch.LIMIT_SECONDS then
        return true, 'limit'
    end
    return false
end

-- A line for the log saying why the import counts as over.
function PreviewWatch.text(state, why, now)
    local seen = string.format('%d of %d photos of the import have a preview', state.count or 0, state.total or 0)
    if why == 'all' then
        return seen
    elseif why == 'stable' then
        return string.format('%s; none new for %d s', seen, now - state.grewAt)
    elseif why == 'limit' then
        return string.format('%s; still more to come after %d minutes, fetching anyway', seen,
            math.floor((now - state.photosOverAt) / 60))
    elseif why == 'none' then
        return 'no photo of the import is known to this session (a restart); not waiting for previews'
    end
    return 'the preview index cannot be read (' .. tostring(state.unreadable) .. '); not waiting for previews'
end

-- The preview index of a catalog: 'D:\Photos\Main.lrcat' -> 'D:\Photos\Main Previews.lrdata\previews.db'.
function PreviewWatch.indexPath(catalogPath)
    local folder, file = tostring(catalogPath or ''):match('^(.*[/\\])([^/\\]+)$')
    if not folder then
        return nil
    end
    local separator = folder:sub(-1)
    return folder .. file:gsub('%.[Ll][Rr][Cc][Aa][Tt]$', '') .. ' Previews.lrdata' .. separator .. 'previews.db'
end

-- The SELECTs that count, among these file UUIDs, those with a pyramid better than the placeholder: one per CHUNK
-- UUIDs; malformed UUIDs are left out (only hex digits and dashes pass). Returns the statements and the number of UUIDs
-- they ask about.
function PreviewWatch.countSql(uuids)
    local valid, statements = {}, {}
    for _, uuid in ipairs(uuids or {}) do
        if type(uuid) == 'string' and uuid:match('^[%x%-]+$') and #uuid <= 64 then
            valid[#valid + 1] = "'" .. uuid .. "'"
        end
    end
    for first = 1, #valid, PreviewWatch.CHUNK do
        local chunk = {}
        for i = first, math.min(first + PreviewWatch.CHUNK - 1, #valid) do
            chunk[#chunk + 1] = valid[i]
        end
        statements[#statements + 1] = "SELECT count(DISTINCT uuid) FROM Pyramid WHERE NOT quality = 'thumbnail' "
            .. 'AND uuid IN (' .. table.concat(chunk, ',') .. ');'
    end
    return statements, #valid
end

-- The number sqlite3 printed for one of those SELECTs, or nil.
function PreviewWatch.parseCount(text)
    local n = tostring(text or ''):match('^%s*(%d+)%s*$')
    return n and tonumber(n) or nil
end

return PreviewWatch
