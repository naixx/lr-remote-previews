-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local AutoSendPlan = require 'AutoSendPlan'

local CATALOG = 'C:\\Photos\\Main\\Main.lrcat'

local function photos(ids)
    local list = {}
    for i, id in ipairs(ids) do
        list[i] = { localIdentifier = id, name = 'P' .. tostring(id) }
    end
    return list
end

local function idOf(photo)
    return photo.localIdentifier
end

local function ids(entries)
    local list = {}
    for i, entry in ipairs(entries) do
        list[i] = entry.id
    end
    return list
end

describe('AutoSendPlan state', function()
    it('is kept per catalog and survives a reload', function()
        local store = {}
        assert.is_nil(AutoSendPlan.load(store, CATALOG))
        assert.is_true(AutoSendPlan.save(store, CATALOG, { mark = 120, seen = 130, blocked = 125, tries = 1,
            looked = 1000 }))
        AutoSendPlan.save(store, 'C:\\Photos\\Other\\Other.lrcat', AutoSendPlan.prime(5, 900))
        assert.are.same({ mark = 120, seen = 130, blocked = 125, tries = 1, looked = 1000 },
            AutoSendPlan.load(store, 'c:/photos/main/MAIN.LRCAT'))
        assert.are.same({ mark = 5, seen = 5, looked = 900 },
            AutoSendPlan.load(store, 'C:\\Photos\\Other\\Other.lrcat'))
        AutoSendPlan.forget(store)
        assert.is_nil(AutoSendPlan.load(store, CATALOG))
        assert.is_nil(store[AutoSendPlan.KEY])
    end)

    it('ignores what it cannot read', function()
        assert.is_nil(AutoSendPlan.load({ [AutoSendPlan.KEY] = '{oops' }, CATALOG))
        assert.is_nil(AutoSendPlan.load({ [AutoSendPlan.KEY] = '{"c:/photos/main/main.lrcat": {"mark": -1}}' },
            CATALOG))
        assert.are.same({ mark = 7, seen = 7 }, AutoSendPlan.load({ [AutoSendPlan.KEY] =
            '{"c:/photos/main/main.lrcat": {"mark": 7, "seen": 3, "tries": "x"}}' }, CATALOG))
        assert.is_false(AutoSendPlan.save({}, nil, { mark = 1, seen = 1 }))
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

describe('AutoSendPlan.scan', function()
    it('keeps the photos above the mark in id order, with the largest id and the count', function()
        local found, maxId, count = AutoSendPlan.scan(photos({ 5, 210, 3, 205, 'x', 0, 208 }), idOf, 200)
        assert.are.same({ 205, 208, 210 }, ids(found))
        assert.are.equal(210, maxId)
        assert.are.equal(7, count)
        local none, largest = AutoSendPlan.scan(photos({ 5, 9 }), idOf, math.huge)
        assert.are.same({}, none)
        assert.are.equal(9, largest)
        assert.are.equal(0, select(2, AutoSendPlan.scan({}, idOf, 0)))
    end)

    it('yields while it goes and gives up when asked to stop', function()
        local list = {}
        for i = 1, 1200 do
            list[i] = { localIdentifier = i }
        end
        local yields = 0
        local found = AutoSendPlan.scan(list, idOf, 1000, { yield = function()
            yields = yields + 1
        end })
        assert.are.equal(200, #found)
        assert.are.equal(2, yields)
        local stopped, why = AutoSendPlan.scan(list, idOf, 0, { shouldStop = function()
            return true
        end })
        assert.is_nil(stopped)
        assert.are.equal('stopped', why)
    end)
end)

describe('AutoSendPlan.pick', function()
    it('takes only photos seen in an earlier round, at most the limit', function()
        local state = { mark = 100, seen = 104 }
        local found = AutoSendPlan.scan(photos({ 101, 102, 103, 104, 105, 107 }), idOf, 100)
        local picked = AutoSendPlan.pick(state, found, 3)
        assert.are.same({ 101, 102, 103 }, ids(picked.photos))
        assert.is_true(picked.more)
        assert.are.equal(2, picked.waiting)
        assert.are.equal(107, picked.seen)
        picked = AutoSendPlan.pick(state, found, 10)
        assert.are.same({ 101, 102, 103, 104 }, ids(picked.photos))
        assert.is_false(picked.more)
        local limited = AutoSendPlan.limit(picked, 2)
        assert.are.same({ 101, 102 }, ids(limited.photos))
        assert.is_true(limited.more)
        assert.are.equal(picked, AutoSendPlan.limit(picked, nil))
    end)
end)

describe('AutoSendPlan.settle', function()
    it('moves the mark past every photo of the round', function()
        local state, cutoff, gaveUp = AutoSendPlan.settle({ mark = 100, seen = 110 }, { 101, 104, 108 }, {}, 112, 50)
        assert.are.same({ mark = 108, seen = 112, looked = 50 }, state)
        assert.is_nil(cutoff)
        assert.are.same({}, gaveUp)
    end)

    it('stops at the first photo without a file record, and gives up on it after a few rounds', function()
        local state = { mark = 100, seen = 110 }
        local round = { 101, 104, 108 }
        local new, cutoff = AutoSendPlan.settle(state, round, { [104] = true, [108] = true }, 110, 1)
        assert.are.equal(101, new.mark)
        assert.are.equal(104, cutoff)
        assert.are.equal(104, new.blocked)
        assert.are.equal(1, new.tries)
        new, cutoff = AutoSendPlan.settle(new, { 104, 108 }, { [104] = true }, 110, 2)
        assert.are.equal(101, new.mark)
        assert.are.equal(104, cutoff)
        assert.are.equal(2, new.tries)
        local gaveUp
        new, cutoff, gaveUp = AutoSendPlan.settle(new, { 104, 108 }, { [104] = true }, 110, 3)
        assert.are.equal(108, new.mark)
        assert.is_nil(cutoff)
        assert.are.same({ 104 }, gaveUp)
        assert.is_nil(new.blocked)
        assert.is_nil(new.tries)
        -- another photo blocking starts counting from one
        new = AutoSendPlan.settle({ mark = 100, seen = 110, blocked = 104, tries = 2 }, { 105 }, { [105] = true }, 110)
        assert.are.equal(1, new.tries)
    end)
end)

describe('AutoSendPlan rounds', function()
    -- A catalog in which photos are added, rounds that send what the plan allows, and restarts in between.
    it('sends every new photo once, across rounds and restarts, and nothing that was there before', function()
        local catalog = { 3, 10, 57 }
        local store, sent = {}, {}
        local function round(transient)
            local state = AutoSendPlan.load(store, CATALOG)
            local found, maxId = AutoSendPlan.scan(photos(catalog), idOf, state and state.mark or math.huge)
            if not state then
                AutoSendPlan.save(store, CATALOG, AutoSendPlan.prime(maxId, 0))
                return
            end
            local picked = AutoSendPlan.pick(state, found, 2)
            local roundIds = ids(picked.photos)
            local new, cutoff = AutoSendPlan.settle(state, roundIds, transient or {}, picked.seen, 0)
            for _, id in ipairs(roundIds) do
                if cutoff == nil or id < cutoff then
                    sent[id] = (sent[id] or 0) + 1
                end
            end
            AutoSendPlan.save(store, CATALOG, new)
        end
        round() -- first round: only the mark
        round()
        assert.are.same({}, sent)
        for _, id in ipairs({ 60, 61, 64, 70, 71 }) do
            catalog[#catalog + 1] = id
        end
        round() -- seen for the first time
        assert.are.same({}, sent)
        round() -- 60 and 61 (the limit is 2)
        store = { [AutoSendPlan.KEY] = store[AutoSendPlan.KEY] } -- a restart: only the stored text survives
        round({ [70] = true }) -- 64; 70 has no file record yet
        round() -- 70 and 71
        round()
        round()
        assert.are.same({ [60] = 1, [61] = 1, [64] = 1, [70] = 1, [71] = 1 }, sent)
    end)
end)

describe('AutoSendPlan.windowHours', function()
    it('looks back from the last change, within bounds', function()
        assert.are.equal(24, AutoSendPlan.windowHours(nil, 100))
        assert.are.equal(24, AutoSendPlan.windowHours({ mark = 1 }, 100))
        assert.are.equal(1, AutoSendPlan.windowHours({ looked = 100 }, 100))
        assert.are.equal(3, AutoSendPlan.windowHours({ looked = 0 }, 3601))
        assert.are.equal(AutoSendPlan.MAX_WINDOW_HOURS, AutoSendPlan.windowHours({ looked = 0 }, 3600 * 24 * 365))
    end)
end)

describe('AutoSendPlan.roundText', function()
    it('says in one line what a round did', function()
        assert.are.equal('sent 12 new photos as job 42 (3 built already, 2 refused (not_found: 1, unknown_root: 1)); '
            .. '5 left out (already have a smart preview: 3, videos: 1, other: 1); 1 photo waits for a file record '
            .. 'in the catalog database; more next round',
            AutoSendPlan.roundText({ sent = 12, jobId = 42, ready = 3, rejected = { not_found = 1, unknown_root = 1 },
                leftOut = { hasSmartPreview = 3, video = 1, other = 1 }, later = 1, more = true }))
        assert.are.equal('sent 1 new photo as job 7', AutoSendPlan.roundText({ sent = 1, jobId = 7 }))
        assert.are.equal('sent nothing; 2 photos just added, taken next round', AutoSendPlan.roundText({ waiting = 2 }))
        assert.are.equal('sent nothing; 2 photos wait for a file record in the catalog database',
            AutoSendPlan.roundText({ later = 2 }))
        assert.are.equal('sent nothing; 1 left out (no file record in the catalog database after 3 rounds: 1)',
            AutoSendPlan.roundText({ leftOut = { gaveUp = 1, video = 0 } }))
    end)
end)
