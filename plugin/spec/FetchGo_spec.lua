-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local FetchGo = require 'FetchGo'

describe('FetchGo', function()
    it('downloads nothing while an import is in progress, then fetches in one go and ends when idle', function()
        local state = FetchGo.new()
        assert.is_nil(FetchGo.step(state, false, true, 0, 0)) -- no import: fetch as things come
        assert.are.equal('begin', FetchGo.step(state, true, true, 10, 0))
        for t = 11, 200 do
            assert.are.equal('hold', FetchGo.step(state, true, false, t, 0))
        end
        assert.are.equal('start', FetchGo.step(state, false, false, 300, 600))
        assert.are.equal(600, state.go.ready)
        assert.is_nil(FetchGo.step(state, false, false, 301, 0)) -- still downloading
        FetchGo.count(state, 'placed', 3 * 1048576)
        FetchGo.count(state, 'placed', 1048576)
        FetchGo.count(state, 'again', 0)
        FetchGo.count(state, 'left', 1048576)
        assert.are.equal('finish', FetchGo.step(state, false, true, 310, 0))
        assert.is_nil(state.go)
        assert.are.equal('2 placed, 1 left out, 1 to be tried again later; 5.0 MB in 10.0 s (0.50 MB/s)',
            FetchGo.totals(state.last))
        assert.is_nil(FetchGo.step(state, false, true, 311, 0)) -- afterwards: as things come again
        FetchGo.count(state, 'placed', 1) -- outside a fetch in one go: not counted
        assert.are.equal(2, state.last.placed)
    end)

    it('many ready at once outside an import (a restart with files left over) make a fetch in one go', function()
        local state = FetchGo.new()
        assert.are.equal('start', FetchGo.begin(state, 100, 1384))
        assert.is_nil(FetchGo.begin(state, 101, 5)) -- one is running
        FetchGo.count(state, 'placed', 1000)
        assert.are.equal('finish', FetchGo.step(state, false, true, 160, 0))
        assert.are.equal(1, state.last.placed)
        assert.are.equal('begin', FetchGo.step(state, true, true, 200, 0))
        assert.is_nil(FetchGo.begin(state, 201, 50)) -- not during an import
    end)

    it('a job while no import is in progress is fetched as it finishes, with no fetch in one go', function()
        local state = FetchGo.new()
        for t = 1, 50 do
            assert.is_nil(FetchGo.step(state, false, t % 2 == 0, t, 0))
        end
        assert.is_nil(state.go)
    end)
end)
