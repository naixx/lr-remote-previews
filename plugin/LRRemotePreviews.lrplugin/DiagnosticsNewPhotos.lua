-- Help > Plug-in Extras > Diagnostics: new photos for the automatic send.
-- Shows what the automatic send would see now (AutoSend.lua, since version 0.8.0 one read of the catalog through
-- sqlite3: CatalogRead): its mark, the photos above it with their folder, import and smart preview state, the import
-- records above it, and how long the read took. So what the catalog does not document can be checked in Lightroom:
-- that photos added by an import get larger catalog ids than every photo before them, and that the read sees them while
-- Lightroom imports. Read-only: it sends nothing, writes nothing and does not move the automatic send's mark. The
-- result goes to a dialog and the log.
local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'

local AutoSend = require 'AutoSend'
local AutoSendPlan = require 'AutoSendPlan'
local CatalogRead = require 'CatalogRead'
local Log = require 'Log'
local Settings = require 'Settings'

local TITLE = 'New photos for the automatic send'
local SHOWN = 10

local function photoLine(photo)
    if photo.incomplete then
        return string.format('    %d  (its file, folder or root row is not in the catalog database yet)', photo.id)
    end
    return string.format('    %d  %s  import %s  %s%s  %s', photo.id, tostring(photo.fileName),
        photo.importId > 0 and string.format('%d', photo.importId) or '-',
        photo.hasSmartPreview and 'has a smart preview' or 'no smart preview',
        photo.virtualCopy and ', virtual copy' or '', tostring(photo.path))
end

local function run()
    local catalog = LrApplication.activeCatalog()
    local catalogPath = catalog:getPath()
    local store = LrPrefs.prefsForPlugin()
    local state = AutoSendPlan.load(store, catalogPath)
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    if state then
        add(string.format('The automatic send has dealt with every photo up to catalog id %d (the largest id it has '
            .. 'seen: %d).', state.mark, state.seen))
    else
        add('The automatic send is not watching this catalog yet (it is off, or has not had its first look).')
    end
    local tool, toolProblem = AutoSend.tool(Settings.read(store))
    if not tool then
        add('sqlite3: ' .. toolProblem)
    else
        local started = AutoSend.clock()
        local marks = AutoSend.read(tool, catalogPath, CatalogRead.markSql())
        local mark = state and state.mark or (marks and marks.mark and math.max(0, marks.mark - SHOWN)) or 0
        local parsed, err = AutoSend.read(tool, catalogPath, CatalogRead.newSql(mark))
        local took = AutoSend.clock() - started
        if not parsed then
            add('Reading the catalog failed: ' .. tostring(err))
        else
            if marks and marks.mark then
                add(string.format('The largest catalog id of photos and imports: %d.', marks.mark))
            end
            add(string.format('Photos above catalog id %d: %d (both reads took %.2f s).', mark, #parsed.photos, took))
            for i = #parsed.photos, math.max(1, #parsed.photos - SHOWN + 1), -1 do
                add(photoLine(parsed.photos[i]))
            end
            if #parsed.imports > 0 then
                add('Import records above that id:')
                for _, import in ipairs(parsed.imports) do
                    add(string.format('    %d  %s', import.id, import.date))
                end
            end
        end
    end
    local text = table.concat(lines, '\n')
    Log.info('diagnostics, new photos:\n%s', text)
    LrDialogs.message(TITLE, text, 'info')
end

LrTasks.startAsyncTask(function()
    local ok, err = LrTasks.pcall(run)
    if not ok then
        Log.error('diagnostics, new photos: unexpected error: %s', tostring(err))
        LrDialogs.message(TITLE, 'Unexpected error: ' .. tostring(err), 'critical')
    end
end)
