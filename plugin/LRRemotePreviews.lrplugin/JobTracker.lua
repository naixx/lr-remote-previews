-- Follows the items of one job as their states arrive (docs/protocol.md, "Polling"). Pure Lua 5.1.
--
--   local tracker = JobTracker.new({ '1', '2', '3' })
--   for _, item in ipairs(tracker:apply(page.items)) do ... end  -- items that just became final
--   GET .../items?since=<tracker.since>
--
-- The tracker keeps the largest seq it has seen (tracker.since). An item counts once: the first time its ref
-- arrives in a final state it is returned by apply(); later copies of that ref are ignored, so the items of the
-- POST answer and of polling may overlap. Refs that were not requested are counted in tracker.unknown.
local Jobs = require 'Jobs'

local JobTracker = {}
JobTracker.__index = JobTracker

function JobTracker.new(refs)
    local self = setmetatable({ since = 0, total = 0, final = 0, unknown = 0, states = {}, itemIds = {} }, JobTracker)
    for _, ref in ipairs(refs) do
        if self.states[ref] == nil then
            self.states[ref] = 'sent'
            self.total = self.total + 1
        end
    end
    return self
end

-- Takes item objects (as Jobs.normalizeItem returns them). Returns the items that reached a final state for
-- the first time, in the order given.
function JobTracker:apply(items)
    local newlyFinal = {}
    for _, item in ipairs(items or {}) do
        if item.seq > self.since then
            self.since = item.seq
        end
        local current = self.states[item.ref]
        if current == nil then
            self.unknown = self.unknown + 1
        elseif not Jobs.FINAL[current] then
            self.states[item.ref] = item.state
            self.itemIds[item.ref] = item.id
            if Jobs.FINAL[item.state] then
                self.final = self.final + 1
                newlyFinal[#newlyFinal + 1] = item
            end
        end
    end
    return newlyFinal
end

function JobTracker:isComplete()
    return self.final >= self.total
end

-- The number of items per last known state ('sent' = nothing heard yet).
function JobTracker:counts()
    local counts = {}
    for _, state in pairs(self.states) do
        counts[state] = (counts[state] or 0) + 1
    end
    return counts
end

-- The refs that have not reached a final state.
function JobTracker:openRefs()
    local refs = {}
    for ref, state in pairs(self.states) do
        if not Jobs.FINAL[state] then
            refs[#refs + 1] = ref
        end
    end
    table.sort(refs)
    return refs
end

return JobTracker
