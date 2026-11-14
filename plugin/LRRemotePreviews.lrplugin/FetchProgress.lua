-- The progress bar of the automatic fetch (since plug-in 0.8.3). Pure Lua 5.1.
--
-- With plug-in 0.8.2 the user closed Lightroom in the middle of the fetch in one go, because nothing on the screen said
-- that anything was still going on. So while the automatic fetch has at least THRESHOLD smart previews to bring in
-- (received and not yet placed, or still being built on the server), one bar shows it, with real numbers, advancing per
-- file dealt with: «836 of 1384 fetched», with «; 184 still being built on the server» while the server builds, or «;
-- the server does not answer (next try at 21:58)». It ends when nothing is left to bring in; while the server still
-- builds, it stays and says so. A trickle of a few files shows no bar. While the fetch waits for an import, the caption
-- says what it waits for and counts down to the latest moment it waits (since 0.8.5; 0.8.4 gave that moment as a time
-- of day, which looked stuck): «Waiting for Lightroom to add photos: fetching in 0:25 if no more come; ...», «Waiting
-- for the first photos of Lightroom's import: at most 4:12 more; ...», «Waiting for Lightroom's previews of the import
-- (600 of 1384): fetching when they stop, at most 14:35 more; ...».
--
--   local state = FetchProgress.new()
--   local action, caption, done, total = FetchProgress.step(state, facts)
--     facts: { waiting = nil, or what the fetch waits for: { kind = 'photos' | 'firstPhoto' | 'previews',
--                untilAt = the latest moment (os.time), now = os.time(), count, total (previews) }, ready = received
--              and not placed, coming = still being built,
--              dealt = files dealt with so far in this session (placed or left out), failed = of those, left out,
--              nextTry = 'HH:MM' while the server does not answer }
--     action: 'start' (show the bar), 'update', 'finish' (end it), or nil (no bar)
local FetchProgress = {}

FetchProgress.TITLE = 'LRRP: smart previews'
FetchProgress.THRESHOLD = 20 -- smart previews to bring in before a bar is shown

function FetchProgress.new()
    return { shown = false }
end

-- '4:12': the time left until the latest moment of a wait.
function FetchProgress.left(untilAt, now)
    if type(untilAt) ~= 'number' or type(now) ~= 'number' then
        return '?'
    end
    local seconds = math.max(0, math.floor(untilAt - now + 0.5))
    return string.format('%d:%02d', math.floor(seconds / 60), seconds % 60)
end

local function waitingText(waiting)
    local left = FetchProgress.left(waiting.untilAt, waiting.now)
    if waiting.kind == 'firstPhoto' then
        return 'Waiting for the first photos of Lightroom\'s import: at most ' .. left .. ' more'
    elseif waiting.kind == 'previews' then
        return string.format('Waiting for Lightroom\'s previews of the import (%d of %d): fetching when they stop, '
            .. 'at most %s more', waiting.count or 0, waiting.total or 0, left)
    end
    return 'Waiting for Lightroom to add photos: fetching in ' .. left .. ' if no more come'
end

local function caption(facts, done, total, failed)
    if facts.waiting then
        return string.format('%s; %d ready on the server, %d being built', waitingText(facts.waiting),
            facts.ready or 0, facts.coming or 0)
    end
    local text = string.format('%d of %d fetched', done, total)
    if failed > 0 then
        text = text .. string.format(' (%d could not be placed)', failed)
    end
    if facts.nextTry then
        return text .. '; the server does not answer (next try at ' .. facts.nextTry .. ')'
    end
    if (facts.coming or 0) > 0 then
        text = text .. string.format('; %d still being built on the server', facts.coming)
    end
    return text
end

function FetchProgress.step(state, facts)
    local left = (facts.ready or 0) + (facts.coming or 0)
    local dealt, failed = facts.dealt or 0, facts.failed or 0
    if not state.shown then
        if left < FetchProgress.THRESHOLD then
            return nil
        end
        state.shown, state.base, state.baseFailed = true, dealt, failed
        local done = 0
        return 'start', caption(facts, done, done + left, 0), done, done + left
    end
    local done, failedHere = dealt - state.base, failed - state.baseFailed
    local total = done + left
    if left == 0 then
        state.shown = false
        return 'finish', caption(facts, done, total, failedHere), done, total
    end
    return 'update', caption(facts, done, total, failedHere), done, total
end

return FetchProgress
