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
end)
