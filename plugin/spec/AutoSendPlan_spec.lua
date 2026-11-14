-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local AutoSendPlan = require 'AutoSendPlan'

local CATALOG = 'C:\\Photos\\Main\\Main.lrcat'
local IMPORT = 160795

-- The run of plug-in 0.8.0 (Lightroom Classic 15.6, 1384 photos, image ids 163566-164949 given out at once): in id
-- order, runs of photos that were sent and runs that were missed, because their rows became visible after the mark
-- had passed them.
local SENT = { { 163566, 163573 }, { 163666, 163677 }, { 163766, 163772 }, { 163868, 163950 }, { 163987, 164392 },
    { 164488, 164498 }, { 164603, 164615 }, { 164761, 164833 }, { 164916, 164949 } }
local MISSED = { { 163574, 163665 }, { 163678, 163765 }, { 163773, 163867 }, { 163951, 163986 }, { 164393, 164487 },
    { 164499, 164602 }, { 164616, 164760 }, { 164834, 164915 } }

local function ids(ranges)
    local list = {}
    for _, range in ipairs(ranges) do
        for id = range[1], range[2] do
            list[#list + 1] = id
        end
    end
    return list
end

-- A catalog in which rows become visible look by look (show), and looks that "send" every photo they take.
local function makeRun(mark)
    local run = { state = AutoSendPlan.prime(mark, 0), sent = {}, unlinked = 0, visible = {}, linked = {} }
    function run.look(now, importRunning)
        local photos = {}
        for id in pairs(run.visible) do
            if id > run.state.mark then
                photos[#photos + 1] = { id = id, importId = run.linked[id] and IMPORT or 0 }
            end
        end
        local result = AutoSendPlan.sort(run.state, photos, importRunning ~= false, now)
        local taken = {}
        for _, photo in ipairs(result.take) do
            run.sent[photo.id] = (run.sent[photo.id] or 0) + 1
            if photo.importId == 0 then
                run.unlinked = run.unlinked + 1
            end
            taken[#taken + 1] = photo.id
        end
        AutoSendPlan.handle(run.state, taken)
        local list = {}
        for i, photo in ipairs(photos) do
            list[i] = photo.id
        end
        AutoSendPlan.advance(run.state, list, now)
        return result
    end
    function run.show(list, linked)
        for _, id in ipairs(list) do
            run.visible[id] = true
            if linked then
                run.linked[id] = true
            end
        end
    end
    return run
end

local function count(map)
    local n, twice = 0, 0
    for _, times in pairs(map) do
        n = n + 1
        if times > 1 then
            twice = twice + 1
        end
    end
    return n, twice
end

describe('AutoSendPlan state', function()
    it('is kept per catalog, with the handled photos as ranges, and survives a reload', function()
        local store = {}
        assert.is_nil(AutoSendPlan.load(store, CATALOG))
        local state = AutoSendPlan.prime(100, 1000)
        AutoSendPlan.handle(state, { 101, 102, 103, 107 })
        state.waiting[105] = { tries = 2, since = 980 }
        state.newAt = 990
        assert.is_true(AutoSendPlan.save(store, CATALOG, state))
        AutoSendPlan.save(store, 'C:\\Photos\\Other\\Other.lrcat', AutoSendPlan.prime(5, 900))
        assert.matches('"handled":%[%[101,103%],%[107,107%]%]', store[AutoSendPlan.KEY])
        local loaded = AutoSendPlan.load(store, 'c:/photos/main/MAIN.LRCAT')
        assert.are.same({ [101] = true, [102] = true, [103] = true, [107] = true }, loaded.handled)
        assert.are.same({ [105] = { tries = 2, since = 980 } }, loaded.waiting)
        assert.are.equal(100, loaded.mark)
        assert.are.equal(990, loaded.newAt)
        assert.are.same({}, AutoSendPlan.load(store, 'C:\\Photos\\Other\\Other.lrcat').handled)
        AutoSendPlan.forget(store)
        assert.is_nil(AutoSendPlan.load(store, CATALOG))
    end)

    it('ignores what it cannot read, and takes a state of 0.8.0 as it is', function()
        assert.is_nil(AutoSendPlan.load({ [AutoSendPlan.KEY] = '{oops' }, CATALOG))
        assert.is_nil(AutoSendPlan.load({ [AutoSendPlan.KEY] = '{"c:/photos/main/main.lrcat": {"mark": -1}}' },
            CATALOG))
        local old = AutoSendPlan.load({ [AutoSendPlan.KEY] =
            '{"c:/photos/main/main.lrcat": {"mark": 164949, "seen": 164949, "blocked": 3, "tries": 1}}' }, CATALOG)
        assert.are.equal(164949, old.mark)
        assert.are.same({}, old.handled)
        assert.are.same({}, old.waiting)
        local bad = AutoSendPlan.load({ [AutoSendPlan.KEY] = '{"c:/photos/main/main.lrcat": {"mark": 7, '
            .. '"handled": [[9, 8], [5, 9], "x"], "waiting": {"3": [1, 5], "12": "y", "13": [2, 50]}}}' }, CATALOG)
        assert.are.same({ [8] = true, [9] = true }, bad.handled)
        assert.are.same({ [13] = { tries = 2, since = 50 } }, bad.waiting)
        assert.is_false(AutoSendPlan.save({}, nil, AutoSendPlan.prime(1, 1)))
    end)
end)

describe('AutoSendPlan file types of the server', function()
    it('remembers the types the server took, to leave out other files without asking it', function()
        local store = {}
        assert.is_nil(AutoSendPlan.knownExtensions(store))
        AutoSendPlan.rememberExtensions(store, { '.arw', '.cr2' })
        assert.are.same({ '.arw', '.cr2' }, AutoSendPlan.knownExtensions(store))
        AutoSendPlan.rememberExtensions(store, {})
        assert.are.same({ '.arw', '.cr2' }, AutoSendPlan.knownExtensions(store))
        assert.is_nil(AutoSendPlan.knownExtensions({ [AutoSendPlan.EXTENSIONS_KEY] = '{oops' }))
        assert.is_nil(AutoSendPlan.knownExtensions({ [AutoSendPlan.EXTENSIONS_KEY] = '[1, 2]' }))
        assert.is_nil(AutoSendPlan.knownExtensions({ [AutoSendPlan.EXTENSIONS_KEY] = '[]' }))
    end)
end)

describe('AutoSendPlan with rows that become visible out of order', function()
    it('sends every photo of the 0.8.0 run once, although the missed runs became visible after the others', function()
        local run = makeRun(163565)
        local now = 0
        -- the runs that were sent, look by look as in the run, then the runs that 0.8.0 missed
        for _, range in ipairs(SENT) do
            run.show(ids({ range }), true)
            now = now + 22
            run.look(now)
        end
        for _, range in ipairs(MISSED) do
            run.show(ids({ range }), true)
            now = now + 22
            run.look(now)
        end
        local sent, twice = count(run.sent)
        assert.are.equal(1384, sent)
        assert.are.equal(0, twice)
        assert.are.equal(163565, run.state.mark) -- kept low while photos came in
        -- quiet for MARK_QUIET: the mark moves up to the last photo, and the handled set empties
        run.look(now + AutoSendPlan.MARK_QUIET)
        assert.are.equal(164949, run.state.mark)
        assert.are.same({}, run.state.handled)
    end)

    it('keeps up with several places of the block advancing at once, links coming a look later', function()
        local run = makeRun(163565)
        local lanes, perLook, first, last = 8, 25, 163566, 164949
        local laneSize = math.ceil((last - first + 1) / lanes)
        local nextOf, now, pendingLinks = {}, 0, {}
        for lane = 1, lanes do
            nextOf[lane] = first + (lane - 1) * laneSize
        end
        local remaining = last - first + 1
        while remaining > 0 or #pendingLinks > 0 do
            -- the links of the rows that appeared in the previous look arrive now
            run.show(pendingLinks, true)
            pendingLinks = {}
            for lane = lanes, 1, -1 do -- the top of the block first, as Lightroom did
                local stop = math.min(first + lane * laneSize - 1, last)
                for _ = 1, perLook do
                    if nextOf[lane] <= stop then
                        run.show({ nextOf[lane] }, false)
                        pendingLinks[#pendingLinks + 1] = nextOf[lane]
                        nextOf[lane] = nextOf[lane] + 1
                        remaining = remaining - 1
                    end
                end
            end
            now = now + 24
            run.look(now)
            assert.are.equal(163565, run.state.mark)
        end
        run.look(now + 24)
        local sent, twice = count(run.sent)
        assert.are.equal(1384, sent)
        assert.are.equal(0, twice)
        assert.are.equal(0, run.unlinked) -- every photo went with its import (one job)
    end)
end)

describe('AutoSendPlan waiting', function()
    it('lets a photo without its import link wait while an import is in progress, then sends it', function()
        local run = makeRun(100)
        run.show({ 101, 102 }, false)
        local result = run.look(10)
        assert.are.equal(2, result.new)
        assert.are.equal(2, result.waiting)
        assert.is_nil(run.sent[101])
        run.show({ 102 }, true) -- its link has come
        run.look(13)
        assert.are.equal(1, run.sent[102])
        for t = 16, 97, 3 do -- looks every 3 s: still waiting
            run.look(t)
        end
        assert.is_nil(run.sent[101])
        run.look(10 + AutoSendPlan.LINK_SECONDS) -- no link after LINK_SECONDS: sent as a photo of no import
        assert.are.equal(1, run.sent[101])
        assert.are.equal(1, run.unlinked)
        -- with no import record above the mark it does not wait
        local quiet = makeRun(200)
        quiet.show({ 201 }, false)
        quiet.look(10, false)
        assert.are.equal(1, quiet.sent[201])
    end)

    it('lets a photo without its rows wait, then leaves it out; others go ahead meanwhile', function()
        local state = AutoSendPlan.prime(100, 0)
        local photos = { { id = 101, incomplete = true }, { id = 102, importId = 5 } }
        local result = AutoSendPlan.sort(state, photos, true, 10)
        assert.are.equal(1, #result.take)
        assert.are.equal(102, result.take[1].id)
        assert.are.equal(1, result.waiting)
        AutoSendPlan.handle(state, { 102 })
        assert.is_false(AutoSendPlan.advance(state, { 101, 102 }, 10 + AutoSendPlan.MARK_QUIET))
        result = AutoSendPlan.sort(state, photos, true, 20)
        assert.are.same({}, result.take)
        assert.are.equal(0, result.new)
        result = AutoSendPlan.sort(state, photos, true, 30) -- MAX_TRIES looks, but not ROWS_SECONDS yet
        assert.are.same({}, result.gaveUp)
        result = AutoSendPlan.sort(state, photos, true, 10 + AutoSendPlan.ROWS_SECONDS)
        assert.are.same({ 101 }, result.gaveUp)
        AutoSendPlan.handle(state, result.gaveUp)
        assert.is_true(AutoSendPlan.advance(state, { 101, 102 }, 30 + AutoSendPlan.MARK_QUIET))
        assert.are.equal(102, state.mark)
    end)
end)

describe('AutoSendPlan.advance', function()
    it('never moves the mark past a visible photo that was not dealt with, nor while photos keep coming', function()
        local state = AutoSendPlan.prime(100, 0)
        local photos = { { id = 101, importId = 1 }, { id = 102, importId = 1 }, { id = 103, importId = 1 } }
        AutoSendPlan.sort(state, photos, false, 50)
        AutoSendPlan.handle(state, { 101, 103 }) -- 102 could not be sent (the server did not answer)
        assert.is_false(AutoSendPlan.advance(state, { 101, 102, 103 }, 100))
        assert.is_true(AutoSendPlan.advance(state, { 101, 102, 103 }, 50 + AutoSendPlan.MARK_QUIET))
        assert.are.equal(101, state.mark)
        assert.are.same({ [103] = true }, state.handled)
        AutoSendPlan.handle(state, { 102 })
        assert.is_true(AutoSendPlan.advance(state, { 102, 103 }, 50 + AutoSendPlan.MARK_QUIET))
        assert.are.equal(103, state.mark)
    end)

    it('counts a photo as new once per session', function()
        local state = AutoSendPlan.prime(100, 0)
        assert.are.equal(1, AutoSendPlan.sort(state, { { id = 101, importId = 1 } }, false, 1).new)
        assert.are.equal(0, AutoSendPlan.sort(state, { { id = 101, importId = 1 } }, false, 2).new)
        assert.are.equal(1, state.newAt)
    end)
end)

describe('AutoSendPlan.roundText', function()
    it('says in one line what a look did', function()
        assert.are.equal('sent 12 new photos: job 42 (added 10), job 43 (new, 2) (3 built already, 2 refused '
            .. '(not_found: 1, unknown_root: 1)); 5 left out (already have a smart preview: 3, videos: 1, other: 1); '
            .. '1 photo waits for its file record or import link in the catalog database',
            AutoSendPlan.roundText({ sent = 12,
                jobs = { { id = 42, count = 10, added = true }, { id = 43, count = 2 } }, ready = 3,
                rejected = { not_found = 1, unknown_root = 1 },
                leftOut = { hasSmartPreview = 3, video = 1, other = 1 }, later = 1 }))
        assert.are.equal('sent 1 new photo: job 7 (new, 1)', AutoSendPlan.roundText({ sent = 1,
            jobs = { { id = 7, count = 1 } } }))
        assert.are.equal('sent nothing; 2 photos wait for their file record or import link in the catalog database',
            AutoSendPlan.roundText({ later = 2 }))
        assert.are.equal('sent nothing; 1 left out (no file record in the catalog database after 3 looks: 1)',
            AutoSendPlan.roundText({ leftOut = { gaveUp = 1, video = 0 } }))
        assert.are.equal('sent nothing; 30 not sent yet: Cannot reach the server.',
            AutoSendPlan.roundText({ unsent = 30, problem = 'Cannot reach the server.' }))
    end)
end)
