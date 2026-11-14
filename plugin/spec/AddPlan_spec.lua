-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local AddPlan = require 'AddPlan'

local MAPPINGS = { { localPrefix = 'Z:\\', rootId = 'archive' } }

describe('AddPlan.sendAvailability', function()
    it('needs a server URL, a path mapping and a folder under it', function()
        assert.is_true(AddPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, MAPPINGS, { 'Z:\\2026' }))
        assert.is_true(AddPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, MAPPINGS, { 'z:/2026/x' }))
        assert.is_true(AddPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, MAPPINGS,
            { 'C:\\Photos', 'Z:\\' }))
        local ok, why = AddPlan.sendAvailability({ serverUrl = '' }, MAPPINGS, { 'Z:\\2026' })
        assert.is_false(ok)
        assert.matches('No server is set up', why)
        ok, why = AddPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, {}, { 'Z:\\2026' })
        assert.is_false(ok)
        assert.matches('No path mapping', why)
        ok, why = AddPlan.sendAvailability({ serverUrl = 'http://nas.local:8787' }, MAPPINGS, { 'C:\\Photos' })
        assert.is_false(ok)
        assert.matches('under none of the path mappings', why)
    end)
end)

describe('AddPlan.batches', function()
    it('splits in order, the last batch smaller', function()
        assert.are.same({ { 1, 2 }, { 3, 4 }, { 5 } }, AddPlan.batches({ 1, 2, 3, 4, 5 }, 2))
        assert.are.same({}, AddPlan.batches({}, 2))
        local many = {}
        for i = 1, AddPlan.BATCH_SIZE + 1 do
            many[i] = i
        end
        local batches = AddPlan.batches(many)
        assert.are.equal(2, #batches)
        assert.are.equal(AddPlan.BATCH_SIZE, #batches[1])
    end)
end)

describe('AddPlan.failureKind', function()
    it('tells a file Lightroom does not support from other errors by the text', function()
        assert.are.equal('notSupported', AddPlan.failureKind('The file format is not supported'))
        assert.are.equal('notSupported', AddPlan.failureKind('Unsupported file'))
        assert.are.equal('failed', AddPlan.failureKind('The file could not be read'))
        assert.are.equal('failed', AddPlan.failureKind(nil))
        assert.are.equal('failed', AddPlan.failureKind({}))
    end)
end)

describe('AddPlan.errorText', function()
    it('drops the place in a script in front of an error', function()
        assert.are.equal('The file format is not supported',
            AddPlan.errorText('[string "AddFolder.lua"]:12: The file format is not supported'))
        assert.are.equal('Could not read the file Z:\\a.arw',
            AddPlan.errorText('C:\\Plug-ins\\X.lrplugin\\PhotoAdder.lua:45: Could not read the file Z:\\a.arw'))
        assert.are.equal('plain text: 12: kept', AddPlan.errorText('plain text: 12: kept'))
        assert.are.equal('nil', AddPlan.errorText(nil))
    end)
end)

describe('AddPlan.writeResult', function()
    it('lets the results of an executed write stand, and fills a missing one', function()
        local results = { { outcome = 'added' } }
        local kind = AddPlan.writeResult(true, 'executed', true, results, 2)
        assert.are.equal('done', kind)
        assert.are.equal('added', results[1].outcome)
        assert.are.equal('failed', results[2].outcome)
        assert.matches('no result', results[2].detail)
    end)

    it('takes an error that left the function as a rollback', function()
        local kind, text = AddPlan.writeResult(false, 'boom', true, { { outcome = 'added' } }, 1)
        assert.are.equal('rolledBack', kind)
        assert.matches('rolled it back: boom', text)
    end)

    it('takes a write whose function never ran as not run, also when it failed', function()
        local kind, text = AddPlan.writeResult(true, 'aborted', false, {}, 3)
        assert.are.equal('notRun', kind)
        assert.matches('%(aborted%)', text)
        kind, text = AddPlan.writeResult(false, 'blocked by another write access call', false, {}, 3)
        assert.are.equal('notRun', kind)
        assert.matches('failed before it started: blocked', text)
        assert.are.equal('notRun', (AddPlan.writeResult(true, nil, false, {}, 1)))
        assert.are.equal('notRun', (AddPlan.writeResult(true, 'queued', false, {}, 1)))
    end)
end)

describe('AddPlan run and texts', function()
    local function sampleRun()
        local run = AddPlan.newRun()
        run:skip('pairedJpeg', 2)
        run:skip('notPhoto')
        run.skippedFolders = 1
        for _ = 1, 3 do
            run:outcome('added', 'IMG.ARW')
        end
        run:outcome('alreadyInCatalog', 'OLD.ARW')
        run:outcome('notSupported', 'NEW.XYZ', 'The file format is not supported')
        run:outcome('failed', 'BAD.ARW', 'could not be read')
        return run
    end

    it('counts, and keeps the first reasons only', function()
        local run = sampleRun()
        assert.are.equal(3, run:count('added'))
        assert.are.equal(2, run:count('pairedJpeg'))
        assert.are.equal(0, run:count('notAdded'))
        assert.is_true(run:troubled())
        for i = 1, AddPlan.MAX_REASONS + 2 do
            run:outcome('failed', 'F' .. i, 'x')
        end
        assert.are.equal(AddPlan.MAX_REASONS, #run.reasons)
        assert.are.equal('NEW.XYZ: The file format is not supported', run.reasons[1])
        local quiet = AddPlan.newRun()
        quiet:outcome('added', 'A.ARW')
        quiet:outcome('alreadyInCatalog', 'B.ARW')
        assert.is_false(quiet:troubled())
        quiet.problems = 1
        assert.is_true(quiet:troubled())
    end)

    it('asks before adding', function()
        local run = AddPlan.newRun()
        run:outcome('alreadyInCatalog', 'OLD.ARW')
        run:skip('pairedJpeg')
        local text = AddPlan.planText(run, { folders = { 'Z:\\2026\\shoot' }, recursive = true, otherFormats = true,
            rawSource = 'server', toAdd = 12, send = true })
        assert.are.equal(table.concat({
            '12 files will be added to the catalog from Z:\\2026\\shoot (with sub-folders).',
            '',
            'Looked for: camera raw files (the types the server takes) and JPEG, TIFF, PNG, HEIC and PSD files.',
            'Lightroom is not asked for any preview. No file on disk is changed.',
            'Afterwards the added photos are sent to the server.',
            '',
            'Left out:',
            '    already in the catalog: 1',
            '    JPEG files next to a raw file of the same name (part of that photo, as in Lightroom\'s import): 1',
        }, '\n'), text)
        text = AddPlan.planText(AddPlan.newRun(), { folders = { 'Z:\\a', 'Z:\\b' }, recursive = false,
            rawSource = 'built-in', toAdd = 1 })
        assert.matches('^1 file will be added to the catalog from 2 folders %(without sub%-folders%):\n    Z:\\a\n    '
            .. 'Z:\\b%.', text)
        assert.matches('camera raw files %(a built%-in list of raw types%)%.', text)
        assert.is_nil(text:find('Left out', 1, true))
        assert.is_nil(text:find('sent to the server', 1, true))
        text = AddPlan.planText(AddPlan.newRun(), { folders = { 'Z:\\a' }, recursive = false, rawSource = 'server',
            toAdd = 2, send = true, sendProblem = 'Adobe DNG Converter is not installed on the server.' })
        assert.matches('\nThe added photos cannot be sent to the server afterwards: Adobe DNG Converter is not '
            .. 'installed on the server%.', text)
        assert.is_nil(text:find('Afterwards the added photos are sent', 1, true))
    end)

    it('sums the run up', function()
        local text = AddPlan.summaryText(sampleRun(), { folders = { 'Z:\\2026' }, recursive = true,
            times = { listing = 1.234, checking = 0.5, adding = 0.6, sending = 12.34 }, sendText = 'SENT',
            logHint = 'LOG' })
        assert.are.equal(table.concat({
            'From Z:\\2026 (with sub-folders):',
            '    Added to the catalog: 3',
            '    Already in the catalog (left alone): 1',
            '    Not added: Lightroom does not support the file: 1',
            '    Not added: Lightroom reported an error: 1',
            '',
            'Refused or failed (the first 2):',
            '    NEW.XYZ: The file format is not supported',
            '    BAD.ARW: could not be read',
            '',
            'Left out while listing:',
            '    JPEG files next to a raw file of the same name (part of that photo, as in Lightroom\'s import): 2',
            '    other files (not a photo type chosen): 1',
            '    folders not looked into (hidden, Lightroom data, NAS system folders): 1',
            '',
            'Times: listing 1.23 s, looking them up in the catalog 0.50 s, adding 0.60 s (0.200 s per photo), sending '
                .. '12.3 s.',
            '',
            'SENT',
            '',
            'Lightroom lists the photos in the Library\'s Folders panel, under the folder they are in. To take them '
                .. 'out of the catalog again, select them and choose Photo > Remove Photos, then «Remove from '
                .. 'Lightroom» (never «Delete from Disk»): the files on disk are not touched.',
            '',
            'LOG',
        }, '\n'), text)
    end)

    it('says when the run stopped or was cancelled, and when there was nothing to add', function()
        local run = AddPlan.newRun()
        run:outcome('alreadyInCatalog', 'A.ARW')
        local text = AddPlan.summaryText(run, { folders = { 'Z:\\2026' }, recursive = false })
        assert.are.equal('From Z:\\2026 (without sub-folders):\n    Already in the catalog (left alone): 1', text)
        text = AddPlan.summaryText(AddPlan.newRun(), { folders = { 'Z:\\2026' }, recursive = false })
        assert.are.equal('From Z:\\2026 (without sub-folders):\n    Nothing to add.', text)
        run = AddPlan.newRun()
        run:outcome('added', 'A.ARW')
        run:outcome('notAdded', 'B.ARW')
        text = AddPlan.summaryText(run, { folders = { 'Z:\\2026' }, cancelled = true })
        assert.matches('^Cancelled%. The photos added before that stay in the catalog%.\n\n', text)
        assert.matches('Not added: the run stopped first: 1', text)
        text = AddPlan.summaryText(run, { folders = { 'Z:\\2026' }, cancelled = true, stopped = 'no write access' })
        assert.matches('^Stopped: no write access\n\n', text)
        assert.is_nil(text:find('Cancelled', 1, true))
    end)

    it('writes the log lines with their timings', function()
        assert.are.equal('add folder: Z:\\a\\IMG_0001.ARW: added (0.19 s)',
            AddPlan.fileLine('Z:\\a\\IMG_0001.ARW', 'added', AddPlan.seconds(0.19)))
        assert.are.equal('add folder: Z:\\a\\IMG_0001.JPG: pairedJpeg (JPEG files next to a raw file of the same name '
            .. '(part of that photo, as in Lightroom\'s import))',
            AddPlan.fileLine('Z:\\a\\IMG_0001.JPG', 'pairedJpeg'))
        assert.are.equal('add folder: batch 2 of 3: 50 files: 48 added, 2 failed; 10.0 s in all, 9.50 s inside the '
            .. 'write (0.190 s per file), 0.50 s waiting for and finishing it, 2 tries',
            AddPlan.writeLine({ index = 2, total = 3, files = 50, counts = { added = 48, failed = 2 }, seconds = 10,
                inside = 9.5, tries = 2 }))
        assert.are.equal('add folder: retry of one file: 1 file: nothing; 0.10 s in all',
            AddPlan.writeLine({ single = true, files = 1, seconds = 0.1, tries = 1 }))
        assert.are.equal('add folder: adding: 5 files in 2 writes: 4 added, 1 alreadyInCatalog; 1.00 s, 0.200 s per '
            .. 'file, 0.250 s per added photo', AddPlan.totalLine({ alreadyInCatalog = 1, added = 4 }, 5, 2, 1))
        assert.are.equal('add folder: adding: 0 files in 0 writes: nothing; 0.00 s', AddPlan.totalLine({}, 0, 0, 0))
    end)

    it('formats seconds', function()
        assert.are.equal('0.00 s', AddPlan.seconds(nil))
        assert.are.equal('0.00 s', AddPlan.seconds(-1))
        assert.are.equal('9.99 s', AddPlan.seconds(9.99))
        assert.are.equal('42.0 s', AddPlan.seconds(42))
        assert.are.equal('125 s', AddPlan.seconds(124.6))
    end)
end)
