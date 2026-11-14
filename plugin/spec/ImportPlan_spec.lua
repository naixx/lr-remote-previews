-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local ImportPlan = require 'ImportPlan'

-- The record of a test catalog whose last import used «Add» and «Embedded & Sidecar» (Lightroom Classic 15.6).
local function recorded(changes)
    local variables = {
        AgImportDialog_importBehavior = 'refInPlace',
        AgImportDialog_previewBuildQuality = 'bthm',
        AgImportDialog_generateDNGProxies = '0',
        AgImportDialog_doCopyToBackupFolder = '0',
        AgImportDialog_crSettingsID = '<none>',
        AgImportDialog_metadataPresetID = '<none>',
        AgImportDialog_ignoreSuspectedDuplicates = '0',
        AgImportDialog_importServiceProvider = 'com.adobe.ag.import.file',
        AgImportDialog_suppressImportDialog = '1',
    }
    for name, value in pairs(changes or {}) do
        if value == false then
            variables[name] = nil
        else
            variables[name] = value
        end
    end
    return { variables = variables, mark = 50540, duplicates = {} }
end

describe('ImportPlan.judge', function()
    it('allows «Add» without a second copy and says what Lightroom will do', function()
        local verdict = ImportPlan.judge(recorded())
        assert.is_true(verdict.ok)
        assert.are.equal('refInPlace', verdict.behavior)
        assert.are.equal('bthm', verdict.previewCode)
        assert.are.equal('Embedded & Sidecar', verdict.previewName)
        assert.is_false(verdict.smartPreviews)
        assert.are.same({}, verdict.presets)
        assert.are.equal('com.adobe.ag.import.file', verdict.extras.AgImportDialog_importServiceProvider)
        verdict = ImportPlan.judge(recorded({ AgImportDialog_previewBuildQuality = 'sbig',
            AgImportDialog_generateDNGProxies = '1', AgImportDialog_crSettingsID = 'ABC',
            AgImportDialog_metadataPresetID = 'DEF', AgImportDialog_doCopyToBackupFolder = false }))
        assert.is_true(verdict.ok)
        assert.is_nil(verdict.previewName)
        assert.is_true(verdict.smartPreviews)
        assert.are.same({ 'a develop preset', 'a metadata preset' }, verdict.presets)
    end)

    it('refuses what it cannot read or check', function()
        local cases = {
            { ImportPlan.judge(nil, 'No working sqlite3 tool was found.'), 'cannot read how the previous import' },
            { ImportPlan.judge({ variables = {}, mark = 3, duplicates = {} }), 'no record of a previous import' },
            { ImportPlan.judge(recorded({ AgImportDialog_importBehavior = false })), 'no record of a previous import' },
            { ImportPlan.judge({ variables = recorded().variables, duplicates = {} }), 'photo ids' },
            { ImportPlan.judge({ variables = recorded().variables, mark = 1,
                duplicates = { 'AgImportDialog_importBehavior' } }), 'two different values' },
            { ImportPlan.judge(recorded({ AgImportDialog_previewBuildQuality = false })), 'incomplete' },
            { ImportPlan.judge(recorded({ AgImportDialog_generateDNGProxies = 'maybe' })), 'incomplete' },
            { ImportPlan.judge(recorded({ AgImportDialog_generateDNGProxies = false })), 'incomplete' },
        }
        for _, case in ipairs(cases) do
            assert.is_false(case[1].ok)
            assert.is_truthy(case[1].refusal:find(case[2], 1, true), case[1].refusal)
        end
        assert.is_truthy(ImportPlan.judge(nil, 'No working sqlite3 tool').refusal:find('No working sqlite3 tool', 1,
            true))
    end)

    it('refuses an import that would copy or move files, or make a second copy', function()
        local verdict = ImportPlan.judge(recorded({ AgImportDialog_importBehavior = 'copy' }))
        assert.is_false(verdict.ok)
        assert.matches('was not «Add» %(Lightroom\'s setting: «copy»%)', verdict.refusal)
        assert.matches('File > Import Photos and Video', verdict.refusal)
        for _, value in ipairs({ '1', 'true', 'yes' }) do
            verdict = ImportPlan.judge(recorded({ AgImportDialog_doCopyToBackupFolder = value }))
            assert.is_false(verdict.ok)
            assert.matches('second copy', verdict.refusal)
        end
    end)
end)

describe('ImportPlan texts of the dialog', function()
    it('shows the settings, with a warning for smart previews', function()
        local text = ImportPlan.dialogText('Z:\\2026\\2026.06.20 - shoot', ImportPlan.judge(recorded()))
        assert.are.equal(table.concat({
            'Lightroom will import Z:\\2026\\2026.06.20 - shoot with the settings of the previous import in this '
                .. 'catalog, without showing its dialog:',
            '    Add: the files stay where they are; only references to them are added to the catalog.',
            '    Previews: Embedded & Sidecar.',
            '    Build Smart Previews: off.',
            '',
            'Whether it takes sub-folders, and what it does with files that are in the catalog already, is up to '
                .. 'Lightroom. The plug-in changes no file and writes nothing to the catalog itself.',
        }, '\n'), text)
        local lines = ImportPlan.settingsLines(ImportPlan.judge(recorded({ AgImportDialog_previewBuildQuality = 'sbig',
            AgImportDialog_generateDNGProxies = '1', AgImportDialog_crSettingsID = 'ABC' })))
        assert.matches('Lightroom builds its own, reading the originals %(its setting «sbig»', lines[2])
        assert.matches('^    Build Smart Previews: ON%.', lines[3])
        assert.are.equal('    Also applied, as in the previous import: a develop preset (catalog settings only; '
            .. 'files are not changed).', lines[4])
    end)

    it('logs every setting read, sorted', function()
        local text = ImportPlan.settingsLogText(ImportPlan.judge(recorded()))
        assert.matches('^AgImportDialog_crSettingsID=<none>, AgImportDialog_doCopyToBackupFolder=0, ', text)
        assert.is_truthy(text:find('AgImportDialog_importBehavior=refInPlace', 1, true))
    end)
end)

describe('ImportPlan.sendAvailability', function()
    local mappings = { { localPrefix = 'Z:\\', rootId = 'archive' } }

    it('needs a server URL, a path mapping and the folder under it', function()
        assert.is_true(ImportPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, mappings, 'Z:\\2026'))
        assert.is_true(ImportPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, mappings, 'Z:\\'))
        local ok, why = ImportPlan.sendAvailability({ serverUrl = '' }, mappings, 'Z:\\2026')
        assert.is_false(ok)
        assert.matches('No server', why)
        ok, why = ImportPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, {}, 'Z:\\2026')
        assert.is_false(ok)
        assert.matches('No path mapping', why)
        ok, why = ImportPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, mappings, 'C:\\Photos')
        assert.is_false(ok)
        assert.matches('under none of the path mappings', why)
    end)
end)

describe('ImportPlan paths', function()
    it('tells whether a folder of the catalog is the chosen one or below it', function()
        assert.is_true(ImportPlan.isUnder('Z:/2026/2026.06.20 - shoot/', 'Z:\\2026\\2026.06.20 - shoot'))
        assert.is_true(ImportPlan.isUnder('z:/2026/2026.06.20 - SHOOT/sub/', 'Z:\\2026\\2026.06.20 - shoot\\'))
        assert.is_false(ImportPlan.isUnder('Z:/2026/2026.06.20 - shoot2/', 'Z:\\2026\\2026.06.20 - shoot'))
        assert.is_false(ImportPlan.isUnder('Z:/2026/', 'Z:\\2026\\2026.06.20 - shoot'))
        assert.is_true(ImportPlan.isUnder('Z:/2026/', 'Z:\\'))
        assert.is_true(ImportPlan.isUnder('//nas.local/photos/a/', '\\\\nas.local\\photos'))
        assert.is_false(ImportPlan.isUnder('/Volumes/photos/a/', '/Volumes/Photos'))
        assert.is_false(ImportPlan.isUnder(nil, 'Z:\\'))
    end)

    it('gives a photo\'s path the way the SDK spells it', function()
        assert.are.equal('Z:\\2026\\shoot\\IMG_0001.ARW',
            ImportPlan.photoPath({ folder = 'Z:/2026/shoot/', name = 'IMG_0001.ARW' }))
        assert.are.equal('\\\\nas.local\\photos\\a.arw',
            ImportPlan.photoPath({ folder = '//nas.local/photos/', name = 'a.arw' }))
        assert.are.equal('/Volumes/Photos/a.arw', ImportPlan.photoPath({ folder = '/Volumes/Photos/', name = 'a.arw' }))
    end)

    it('splits the new photos into those under the folder and the rest', function()
        local under, elsewhere = ImportPlan.underFolder({ { id = 1, folder = 'Z:/a/' }, { id = 2, folder = 'Z:/b/' },
            { id = 3, folder = 'Z:/a/c/' } }, 'Z:\\a')
        assert.are.same({ 1, 3 }, { under[1].id, under[2].id })
        assert.are.equal(2, #under)
        assert.are.equal(1, elsewhere)
    end)
end)

describe('ImportPlan watch', function()
    it('takes the import as finished when the count has not changed for SETTLED_SECONDS', function()
        local watch = ImportPlan.newWatch(100)
        assert.are.equal('waiting', ImportPlan.observe(watch, 0, 0, 103))
        assert.are.equal('waiting', ImportPlan.observe(watch, 5, 1, 106))
        assert.are.equal('waiting', ImportPlan.observe(watch, 10, 1, 109))
        assert.are.equal('waiting', ImportPlan.observe(watch, 10, 1, 109 + ImportPlan.SETTLED_SECONDS - 1))
        assert.are.equal('settled', ImportPlan.observe(watch, 10, 1, 109 + ImportPlan.SETTLED_SECONDS))
        assert.are.equal(106, watch.first)
        assert.are.equal(109, watch.last)
        assert.are.equal(10, watch.count)
        assert.are.equal(5, watch.polls)
        assert.are.equal(1, watch.imports)
    end)

    it('gives up when no photo appears, or after the overall limit', function()
        local watch = ImportPlan.newWatch(0)
        assert.are.equal('waiting', ImportPlan.observe(watch, 0, 1, ImportPlan.NO_PHOTO_SECONDS - 1))
        assert.are.equal('noPhotos', ImportPlan.observe(watch, 0, 1, ImportPlan.NO_PHOTO_SECONDS))
        watch = ImportPlan.newWatch(0)
        local t, count = 0, 0
        local state
        repeat
            t, count = t + ImportPlan.POLL_SECONDS, count + 1
            state = ImportPlan.observe(watch, count, 1, t)
        until state ~= 'waiting'
        assert.are.equal('timeLimit', state)
        assert.is_true(t >= ImportPlan.LIMIT_SECONDS)
    end)

    it('stops after MAX_POLL_FAILURES failed reads in a row, and never settles on a failed read', function()
        local watch = ImportPlan.newWatch(0)
        assert.are.equal('waiting', ImportPlan.observe(watch, 3, 0, 3))
        for i = 1, ImportPlan.MAX_POLL_FAILURES - 1 do
            assert.are.equal('waiting', ImportPlan.pollFailed(watch, 3 + i * 30))
        end
        assert.are.equal('settled', ImportPlan.observe(watch, 3, 0, 200))
        watch = ImportPlan.newWatch(0)
        ImportPlan.observe(watch, 3, 0, 3)
        for _ = 1, ImportPlan.MAX_POLL_FAILURES - 1 do
            ImportPlan.pollFailed(watch, 10)
        end
        assert.are.equal('pollFailed', ImportPlan.pollFailed(watch, 11))
    end)

    it('sends after a finished import or the time limit only', function()
        assert.is_true(ImportPlan.sendsAfter('settled'))
        assert.is_true(ImportPlan.sendsAfter('timeLimit'))
        for _, outcome in ipairs({ 'cancelled', 'noPhotos', 'pollFailed' }) do
            assert.is_false(ImportPlan.sendsAfter(outcome))
        end
    end)
end)

describe('ImportPlan summary and log lines', function()
    local function finished()
        local watch = ImportPlan.newWatch(10)
        ImportPlan.observe(watch, 2, 1, 13.5)
        ImportPlan.observe(watch, 120, 1, 40)
        ImportPlan.observe(watch, 120, 1, 60)
        return watch
    end

    it('sums the run up', function()
        local text = ImportPlan.summaryText({ folder = 'Z:\\2026\\shoot', outcome = 'settled', watch = finished(),
            sidecars = 118, elsewhere = 3, times = { trigger = 0.04, waited = 50, sending = 4.2 }, sendText = 'SENT',
            logHint = 'LOG' })
        assert.are.equal(table.concat({
            'Z:\\2026\\shoot:',
            '',
            'Lightroom imported 120 photos from this folder. No new one came for 20 seconds, so the plug-in took the '
                .. 'import as finished.',
            'Of them with a sidecar recorded (for example a JPEG next to the raw file): 118.',
            'Meanwhile 3 photos were added to other folders; they were not counted.',
            '',
            'Times: starting the import 0.04 s, first photo after 3.50 s, last after 30.0 s, waited 50.0 s, sending '
                .. '4.20 s.',
            '',
            'SENT',
            '',
            'Lightroom lists the photos in the Library\'s Folders panel. To take them out of the catalog again, select '
                .. 'them and choose Photo > Remove Photos, then «Remove from Lightroom» (never «Delete from Disk»): '
                .. 'the files on disk are not touched.',
            '',
            'LOG',
        }, '\n'), text)
    end)

    it('says why the waiting ended', function()
        local none = ImportPlan.newWatch(0)
        assert.matches('^No photo of this folder appeared in the catalog within 5 minutes',
            ImportPlan.outcomeText('noPhotos', none))
        assert.matches('^The plug%-in stopped waiting after 4 hours, with 120 photos',
            ImportPlan.outcomeText('timeLimit', finished()))
        assert.matches('failed 5 times in a row %(database is locked%)',
            ImportPlan.outcomeText('pollFailed', finished(), 'database is locked'))
        assert.matches('^You stopped the waiting%. Lightroom goes on with its import by itself; 120 photos',
            ImportPlan.outcomeText('cancelled', finished()))
        local text = ImportPlan.summaryText({ folder = 'Z:\\a', outcome = 'noPhotos', watch = none })
        assert.is_nil(text:find('Remove Photos', 1, true))
        assert.is_nil(text:find('Times:', 1, true))
    end)

    it('writes the log lines', function()
        assert.are.equal('import folder: poll 5 at 15.2 s: 120 photos under the folder (+40), 0 elsewhere, '
            .. '1 import record, read in 0.21 s', ImportPlan.pollLine({ poll = 5, at = 15.2, count = 120, before = 80,
                elsewhere = 0, imports = 1, read = 0.21 }))
        assert.are.equal('import folder: poll 1 at 3.00 s: 0 photos under the folder (+0), 2 elsewhere, '
            .. '0 import records, read in 0.10 s', ImportPlan.pollLine({ poll = 1, at = 3, count = 0, elsewhere = 2,
                read = 0.1 }))
        assert.are.equal('import folder: imported Z:\\2026\\IMG_0001.ARW (catalog id 50478, sidecar JPG)',
            ImportPlan.photoLine({ id = 50478, folder = 'Z:/2026/', name = 'IMG_0001.ARW', sidecars = 'JPG' }))
        assert.are.equal('import folder: imported Z:\\2026\\IMG_0002.ARW (catalog id 50479)',
            ImportPlan.photoLine({ id = 50479, folder = 'Z:/2026/', name = 'IMG_0002.ARW', sidecars = '' }))
        assert.are.equal('Lightroom is importing: 1 photo so far', ImportPlan.caption(1))
        assert.are.equal('125 s', ImportPlan.seconds(124.6))
        assert.are.equal('0.00 s', ImportPlan.seconds(-2))
    end)
end)
