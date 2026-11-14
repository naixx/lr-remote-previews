-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local AutoSendPlan = require 'AutoSendPlan'

local CATALOG = 'C:\\Photos\\Main\\Main.lrcat'

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
    -- A catalog in which photos are added, looks that send every new photo at once, and restarts in between.
    it('sends every new photo once, in the look that finds it, across restarts, and nothing that was there before',
        function()
            local catalog = { 3, 10, 57 }
            local store, sent = {}, {}
            local function look(transient)
                local state = AutoSendPlan.load(store, CATALOG)
                local largest, found = 0, {}
                for _, id in ipairs(catalog) do
                    largest = math.max(largest, id)
                    if state and id > state.mark then
                        found[#found + 1] = id
                    end
                end
                table.sort(found)
                if not state then
                    AutoSendPlan.save(store, CATALOG, AutoSendPlan.prime(largest, 0))
                    return
                end
                local new, cutoff = AutoSendPlan.settle(state, found, transient or {}, largest, 0)
                for _, id in ipairs(found) do
                    if (cutoff == nil or id < cutoff) and not (transient or {})[id] then
                        sent[id] = (sent[id] or 0) + 1
                    end
                end
                AutoSendPlan.save(store, CATALOG, new)
            end
            look() -- first look: only the mark
            look()
            assert.are.same({}, sent)
            for _, id in ipairs({ 60, 61, 64 }) do
                catalog[#catalog + 1] = id
            end
            look() -- sent at once, all three
            assert.are.same({ [60] = 1, [61] = 1, [64] = 1 }, sent)
            for _, id in ipairs({ 70, 71 }) do
                catalog[#catalog + 1] = id
            end
            store = { [AutoSendPlan.KEY] = store[AutoSendPlan.KEY] } -- a restart: only the stored text survives
            look({ [70] = true }) -- 70 has no file record yet: it and 71 wait
            look() -- 70 and 71
            look()
            assert.are.same({ [60] = 1, [61] = 1, [64] = 1, [70] = 1, [71] = 1 }, sent)
        end)
end)

describe('AutoSendPlan.roundText', function()
    it('says in one line what a look did', function()
        assert.are.equal('sent 12 new photos: job 42 (added 10), job 43 (new, 2) (3 built already, 2 refused '
            .. '(not_found: 1, unknown_root: 1)); 5 left out (already have a smart preview: 3, videos: 1, other: 1); '
            .. '1 photo waits for a file record in the catalog database',
            AutoSendPlan.roundText({ sent = 12,
                jobs = { { id = 42, count = 10, added = true }, { id = 43, count = 2 } }, ready = 3,
                rejected = { not_found = 1, unknown_root = 1 },
                leftOut = { hasSmartPreview = 3, video = 1, other = 1 }, later = 1 }))
        assert.are.equal('sent 1 new photo: job 7 (new, 1)', AutoSendPlan.roundText({ sent = 1,
            jobs = { { id = 7, count = 1 } } }))
        assert.are.equal('sent nothing; 2 photos wait for a file record in the catalog database',
            AutoSendPlan.roundText({ later = 2 }))
        assert.are.equal('sent nothing; 1 left out (no file record in the catalog database after 3 rounds: 1)',
            AutoSendPlan.roundText({ leftOut = { gaveUp = 1, video = 0 } }))
        assert.are.equal('sent nothing; 30 not sent yet: Cannot reach the server.',
            AutoSendPlan.roundText({ unsent = 30, problem = 'Cannot reach the server.' }))
    end)
end)
