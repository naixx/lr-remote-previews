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
        assert.are.equal(50540, verdict.mark)
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
            'Whether it takes sub-folders is up to Lightroom. The plug-in changes no file and writes nothing to the '
                .. 'catalog itself; it starts the import and is done.',
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

describe('ImportPlan and the automatic send', function()
    local mappings = { { localPrefix = 'Z:\\', rootId = 'archive' } }

    it('says why the server could not take the photos of the folder', function()
        assert.is_nil(ImportPlan.sendProblem({ serverUrl = 'http://nas.local:8787' }, mappings, 'Z:\\2026'))
        assert.is_nil(ImportPlan.sendProblem({ serverUrl = 'http://nas.local:8787' }, mappings, 'Z:\\'))
        assert.matches('No server', ImportPlan.sendProblem({ serverUrl = '' }, mappings, 'Z:\\2026'))
        assert.matches('No path mapping', ImportPlan.sendProblem({ serverUrl = 'http://nas.local:8787' }, {}, 'Z:\\a'))
        assert.matches('under none of the path mappings',
            ImportPlan.sendProblem({ serverUrl = 'http://nas.local:8787' }, mappings, 'C:\\Photos'))
    end)

    it('explains the checkbox, or names the problem', function()
        assert.matches('^The plug%-in\'s automatic send %(the same setting as in the Plug%-in Manager%) sends new raw '
            .. 'photos', ImportPlan.autoSendNote(nil))
        assert.matches('Off: send them later with «Build smart previews on the server»%.$',
            ImportPlan.autoSendNote(nil))
        assert.are.equal('No server is set up.', ImportPlan.autoSendNote('No server is set up.'))
    end)

    it('gives the short notice after the trigger', function()
        assert.are.equal('Lightroom is importing 2026.06.20 - shoot; the automatic send sends the new photos',
            ImportPlan.bezelText('Z:\\2026\\2026.06.20 - shoot', true))
        assert.are.equal('Lightroom is importing shoot', ImportPlan.bezelText('/Volumes/Photos/shoot/', false))
        assert.are.equal('0.16 s', ImportPlan.seconds(0.16))
        assert.are.equal('125 s', ImportPlan.seconds(124.6))
        assert.are.equal('0.00 s', ImportPlan.seconds(-1))
    end)
end)
