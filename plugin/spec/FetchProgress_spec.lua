-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local FetchProgress = require 'FetchProgress'

describe('FetchProgress', function()
    it('shows a bar from the import on, counts every file, and ends when nothing is left', function()
        local state = FetchProgress.new()
        local photos = { kind = 'photos', untilText = '21:50' }
        assert.is_nil(FetchProgress.step(state, { waiting = photos, ready = 0, coming = 5, dealt = 0 })) -- a trickle
        local action, caption, done, total = FetchProgress.step(state, { waiting = photos, ready = 600, coming = 784,
            dealt = 10 })
        assert.are.equal('start', action)
        assert.are.equal('Waiting while Lightroom adds photos, until 21:50 if no more come: 600 ready on the server, '
            .. '784 being built', caption)
        action, caption = FetchProgress.step(state, { waiting = { kind = 'firstPhoto', untilText = '21:47' },
            ready = 600, coming = 784, dealt = 10 })
        assert.are.equal('update', action)
        assert.are.equal('Waiting for the photos of Lightroom\'s import, at the latest until 21:47: 600 ready on the '
            .. 'server, 784 being built', caption)
        action, caption = FetchProgress.step(state, { waiting = { kind = 'previews', untilText = '22:05', count = 600,
            total = 1384 }, ready = 1384, coming = 0, dealt = 10 })
        assert.are.equal('update', action)
        assert.are.equal('Waiting for Lightroom\'s previews of the import (600 of 1384), at the latest until 22:05: '
            .. '1384 ready on the server, 0 being built', caption)
        assert.are.same({ 0, 1384 }, { done, total })
        action, caption, done, total = FetchProgress.step(state, { ready = 548, coming = 0, dealt = 846 })
        assert.are.equal('update', action)
        assert.are.equal('836 of 1384 fetched', caption)
        assert.are.same({ 836, 1384 }, { done, total })
        action, caption = FetchProgress.step(state, { ready = 0, coming = 0, dealt = 1394, failed = 2 })
        assert.are.equal('finish', action)
        assert.are.equal('1384 of 1384 fetched (2 could not be placed)', caption)
        assert.is_nil(FetchProgress.step(state, { ready = 3, coming = 0, dealt = 1394 })) -- a trickle afterwards
    end)

    it('stays while the server builds, and says so; says when the server does not answer', function()
        local state = FetchProgress.new()
        assert.are.equal('start', (FetchProgress.step(state, { ready = 30, coming = 0, dealt = 0 })))
        local action, caption = FetchProgress.step(state, { ready = 0, coming = 184, dealt = 1200 })
        assert.are.equal('update', action)
        assert.are.equal('1200 of 1384 fetched; 184 still being built on the server', caption)
        action, caption = FetchProgress.step(state, { ready = 100, coming = 84, dealt = 1200, nextTry = '21:58' })
        assert.are.equal('update', action)
        assert.are.equal('1200 of 1384 fetched; the server does not answer (next try at 21:58)', caption)
        assert.are.equal('finish', (FetchProgress.step(state, { ready = 0, coming = 0, dealt = 1384 })))
    end)

    it('after a restart with files left over: «N of M fetched» at once, the files already in place counted', function()
        local state = FetchProgress.new()
        -- the job's 1384 ready items received; 836 of them are found in place in the next step
        local action, caption = FetchProgress.step(state, { ready = 1384, coming = 0, dealt = 0 })
        assert.are.equal('start', action)
        assert.are.equal('0 of 1384 fetched', caption)
        action, caption = FetchProgress.step(state, { ready = 548, coming = 0, dealt = 836 })
        assert.are.equal('update', action)
        assert.are.equal('836 of 1384 fetched', caption)
    end)

    it('a new batch after a finished one gets a new bar counted from zero', function()
        local state = FetchProgress.new()
        FetchProgress.step(state, { ready = 50, dealt = 0 })
        FetchProgress.step(state, { ready = 0, dealt = 50 })
        local action, caption = FetchProgress.step(state, { ready = 25, coming = 5, dealt = 50 })
        assert.are.equal('start', action)
        assert.are.equal('0 of 30 fetched; 5 still being built on the server', caption)
    end)
end)
