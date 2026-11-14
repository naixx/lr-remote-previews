-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local PreviewWatch = require 'PreviewWatch'
local SqliteCommand = require 'SqliteCommand'

-- Feeds readings every READ_SECONDS from t0 until over; counts(t) gives the count at t. Returns the time and the why.
local function run(t0, total, counts)
    local state = PreviewWatch.new()
    PreviewWatch.photosOver(state, t0)
    for t = t0, t0 + 2 * PreviewWatch.LIMIT_SECONDS do
        if PreviewWatch.readDue(state, t) then
            PreviewWatch.observe(state, counts(t), total, t)
        end
        local over, why = PreviewWatch.over(state, t)
        if over then
            return t, why, state
        end
    end
end

describe('PreviewWatch', function()
    it('waits while Lightroom\'s preview task adds previews, and ends when it stopped for QUIET_SECONDS', function()
        -- 1384 photos, the task 3 photos a second, 600 done when the photos stopped coming: done 261 s later
        local at, why, state = run(1000, 1384, function(t)
            return math.min(1300, 600 + math.floor((t - 1000) * 3))
        end)
        -- 1300 reached at 1234 (seen at the read of 1240); none new for 30 s: the read at 1270
        assert.are.equal('stable', why)
        assert.are.equal(1270, at)
        assert.are.equal('1300 of 1384 photos of the import have a preview; none new for 30 s',
            PreviewWatch.text(state, why, at))
    end)

    it('ends at once when every photo has a preview', function()
        local at, why = run(1000, 50, function(t)
            return t >= 1020 and 50 or 49
        end)
        assert.are.equal('all', why)
        assert.are.equal(1020, at)
    end)

    it('does not wait for ever: a preview task that crawls ends at the limit', function()
        local at, why, state = run(1000, 1000, function(t)
            return math.floor((t - 1000) / 20) -- one preview every 20 s: never quiet for 30 s
        end)
        assert.are.equal('limit', why)
        assert.are.equal(1000 + PreviewWatch.LIMIT_SECONDS, at)
        assert.matches('still more to come after 15 minutes, fetching anyway', PreviewWatch.text(state, why, at))
    end)

    it('an index it cannot read, or no photo known, ends the wait at once (the rule before 0.8.3)', function()
        local state = PreviewWatch.new()
        assert.is_false(PreviewWatch.over(state, 5)) -- the photos still come
        assert.is_false(PreviewWatch.readDue(state, 5))
        PreviewWatch.photosOver(state, 10)
        assert.is_false(PreviewWatch.over(state, 10)) -- not read yet
        PreviewWatch.observe(state, nil, nil, 10, 'database is locked')
        local over, why = PreviewWatch.over(state, 10)
        assert.is_true(over)
        assert.are.equal('unreadable', why)
        assert.matches('cannot be read %(database is locked%)', PreviewWatch.text(state, why, 10))
        assert.is_false(PreviewWatch.readDue(state, 30))
        local none = PreviewWatch.new()
        PreviewWatch.photosOver(none, 10)
        PreviewWatch.observe(none, 0, 0, 10)
        assert.are.equal('none', select(2, PreviewWatch.over(none, 10)))
        PreviewWatch.reset(none)
        assert.is_nil(none.photosOverAt)
    end)

    it('names the index next to the catalog', function()
        assert.are.equal('D:\\Photos\\Main Catalog Previews.lrdata\\previews.db',
            PreviewWatch.indexPath('D:\\Photos\\Main Catalog.lrcat'))
        assert.are.equal('/Users/x/Pictures/Lightroom/Cat Previews.lrdata/previews.db',
            PreviewWatch.indexPath('/Users/x/Pictures/Lightroom/Cat.LRCAT'))
        assert.is_nil(PreviewWatch.indexPath('nofolder.lrcat'))
    end)

    it('counts in chunks, leaves out malformed UUIDs, and passes the read-only script check', function()
        local uuids = { 'A1B2C3D4-0000-4AAA-8BBB-000000000001', "x'); DROP TABLE Pyramid; --", 'not a uuid' }
        for i = 1, PreviewWatch.CHUNK + 3 do
            uuids[#uuids + 1] = string.format('%08X-F11E-4AAA-8BBB-%012X', i, i)
        end
        local statements, total = PreviewWatch.countSql(uuids)
        assert.are.equal(PreviewWatch.CHUNK + 4, total)
        assert.are.equal(2, #statements)
        assert.matches("^SELECT count%(DISTINCT uuid%) FROM Pyramid WHERE NOT quality = 'thumbnail' AND uuid IN "
            .. "%('A1B2C3D4%-0000%-4AAA%-8BBB%-000000000001',", statements[1])
        assert.is_nil(statements[1]:find('DROP', 1, true))
        for _, sql in ipairs(statements) do
            assert.is_truthy(SqliteCommand.previewScript('D:\\Photos\\Main Previews.lrdata\\previews.db', sql))
            assert.is_nil(SqliteCommand.readScript('D:\\x.lrcat', sql)) -- the catalog's check refuses dashes
        end
        assert.are.same({}, (PreviewWatch.countSql({})))
        assert.are.equal(1383, PreviewWatch.parseCount('1383\n'))
        assert.is_nil(PreviewWatch.parseCount('Error: no such table: Pyramid'))
    end)
end)
