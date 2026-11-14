-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local RunSummary = require 'RunSummary'

describe('RunSummary', function()
    it('writes the outcomes, the server error codes and the skips', function()
        local summary = RunSummary.new(12)
        summary.sent = 8
        for _ = 1, 3 do
            summary:outcome('delivered')
        end
        summary:outcome('checkFailed')
        summary:outcome('failed', 'converter_failed')
        summary:outcome('failed', 'converter_timeout')
        summary:outcome('failed', 'converter_failed')
        summary:outcome('rejected', 'not_found')
        summary:skip('video')
        summary:skip('hasSmartPreview')
        summary:skip('hasSmartPreview')
        summary:skip('sameFile')
        assert.are.equal(table.concat({
            '12 photos selected, 8 sent to the server.',
            '',
            '    Smart previews placed and registered by Lightroom: 3',
            '    Discarded: the file did not pass the check: 1',
            '    The server could not build them: 3 (converter_failed: 2, converter_timeout: 1)',
            '    The server refused them: 1 (not_found: 1)',
            '',
            'Not sent (4):',
            '    videos: 1',
            '    already have a smart preview: 2',
            '    same file as another selected photo (virtual copies): 1',
            '',
            'See the log.',
        }, '\n'), summary:text({ logHint = 'See the log.' }))
        assert.are.equal(3, summary:count('delivered'))
        assert.are.equal(2, summary:count('hasSmartPreview'))
        assert.are.equal(0, summary:count('writeFailed'))
    end)

    it('starts with the reason a run stopped', function()
        local summary = RunSummary.new(1)
        assert.matches('^Cancelled%.', summary:text({ cancelled = true }))
        assert.matches('Cancelling on the server failed: HTTP 500',
            summary:text({ cancelled = true, cancelProblem = 'HTTP 500' }), 1, true)
        assert.matches('^Stopped: lost the server', summary:text({ aborted = 'lost the server' }))
        assert.matches('1 photo selected, 0 sent to the server.\n\nNothing to send.',
            summary:text({ stoppedBefore = 'Nothing to send.' }), 1, true)
    end)

    it('writes the question before sending', function()
        local summary = RunSummary.new(5)
        assert.are.equal('5 photos of the 5 selected will be sent to the server.', summary:plan(5))
        summary:skip('noMapping')
        assert.are.equal('1 photo of the 5 selected will be sent to the server.\n\nNot sent (1):\n'
            .. '    not under any local prefix of the path mappings: 1', summary:plan(1))
    end)

    it('writes one log line per photo', function()
        assert.are.equal('IMG_0001.ARW: delivered (DNG 1.7.0.0, C:\\x.dng)',
            RunSummary.photoLine('IMG_0001.ARW', 'delivered', 'DNG 1.7.0.0, C:\\x.dng'))
        assert.are.equal('MOV_0002.MP4: video (videos)', RunSummary.photoLine('MOV_0002.MP4', 'video'))
        assert.are.equal('IMG_0003.ARW: notDelivered (Not finished: the run stopped first)',
            RunSummary.photoLine('IMG_0003.ARW', 'notDelivered'))
    end)

    it('writes the summary of a fetch with its own header, headings and notes', function()
        local summary = RunSummary.new(6)
        summary:outcome('delivered')
        summary:outcome('pending')
        summary:outcome('absent')
        summary:outcome('rejected', 'not_found')
        summary:outcome('notInCache')
        summary:skip('hasSmartPreview')
        summary:skip('notInCatalog')
        assert.are.equal(table.concat({
            'Stopped. Placed ones stay.',
            '',
            '6 photo(s) selected, 4 looked up on the server.',
            '',
            '    Smart previews placed and registered by Lightroom: 1',
            '    Gone from the server\'s cache since it was looked up (fetch again): 1',
            '    The server refused them: 1 (not_found: 1)',
            '    Still being built on the server: 1',
            '    Not on the server (never sent, or the original changed since; send them again): 1',
            '',
            'Left out (2):',
            '    already have a smart preview: 1',
            '    built on the server, but not in this catalog (removed, or the path mappings changed): 1',
            '',
            'On the server: 3 queued.',
        }, '\n'), summary:text({ cancelled = true, cancelledText = 'Stopped. Placed ones stay.',
            header = '6 photo(s) selected, 4 looked up on the server.', skipHeading = 'Left out',
            notes = { 'On the server: 3 queued.' } }))
        assert.are.equal(1, summary:placed())
        assert.is_true(summary:troubled())
        assert.are.equal('1 placed, 1 downloads failed, 1 still being built, 1 not on the server, 1 refused',
            summary:shortText())
        assert.are.equal('nothing to place', RunSummary.new(0):shortText())
        assert.is_false(RunSummary.new(0):troubled())
    end)

    it('writes the text after sending', function()
        local summary = RunSummary.new(5)
        summary.sent = 4
        summary:outcome('rejected', 'not_found')
        summary:skip('video')
        assert.are.equal(table.concat({
            '4 photos were sent to the server (job 12). The server builds the smart previews in the background; '
                .. 'Lightroom does not have to stay open.',
            '',
            '    Built already (the server had them): 2',
            '    Refused by the server: 1 (not_found: 1)',
            '',
            'Fetch later.',
            '',
            'Not sent (1):',
            '    videos: 1',
            '',
            'See the log.',
        }, '\n'), summary:sendText({ jobIds = { 12 }, ready = 2, rejected = 1, fetchHint = 'Fetch later.',
            logHint = 'See the log.' }))
        local one = RunSummary.new(1)
        one.sent = 1
        assert.matches('^1 photo was sent to the server %(jobs 3, 4%)%.', one:sendText({ jobIds = { 3, 4 },
            failedParts = 'Part 3 failed.' }))
        assert.matches('\n\nPart 3 failed%.$', one:sendText({ jobIds = { 3, 4 }, failedParts = 'Part 3 failed.' }))
    end)

    it('asks for a dialog after a send only when something needs the user', function()
        local clean = RunSummary.new(3)
        clean.sent = 3
        assert.is_false(clean:sendNeedsAttention({ jobIds = { 7 }, ready = 2, rejected = 0 }))
        assert.is_true(clean:sendNeedsAttention({ jobIds = { 7 }, rejected = 1 }))
        assert.is_true(clean:sendNeedsAttention({ jobIds = { 7 }, failedParts = 'Part 2 failed.' }))
        local skipped = RunSummary.new(3)
        skipped:skip('video')
        assert.is_true(skipped:sendNeedsAttention({ jobIds = { 7 } }))
        assert.are.equal('3 photos sent to the server; their smart previews arrive by themselves',
            clean:sentNotice(true))
        local single = RunSummary.new(1)
        single.sent = 1
        assert.are.equal('1 photo sent to the server; fetch their smart previews with «Fetch ready smart previews» '
            .. 'when they are ready', single:sentNotice(false))
    end)
end)
