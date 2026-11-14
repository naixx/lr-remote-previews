-- The progress bar of the automatic fetch (since plug-in 0.8.3). Pure Lua 5.1.
--
-- With plug-in 0.8.2 the user closed Lightroom in the middle of the fetch in one go, because nothing on the screen said
-- that anything was still going on. So while the automatic fetch has at least THRESHOLD smart previews to bring in
-- (received and not yet placed, or still being built on the server), one bar shows it, with real numbers, advancing per
-- file dealt with: during an import «Waiting for Lightroom's import to end: 600 ready on the server, 784 being built»,
-- then «836 of 1384 fetched», with «; 184 still being built on the server» while the server builds, or «; the server
-- does not answer (next try at 21:58)». It ends when nothing is left to bring in; while the server still builds, it
-- stays and says so. A trickle of a few files shows no bar.
--
--   local state = FetchProgress.new()
--   local action, caption, done, total = FetchProgress.step(state, facts)
--     facts: { waiting = an import is in progress, ready = received and not placed, coming = still being built,
--              dealt = files dealt with so far in this session (placed or left out), failed = of those, left out,
--              nextTry = 'HH:MM' while the server does not answer }
--     action: 'start' (show the bar), 'update', 'finish' (end it), or nil (no bar)
local FetchProgress = {}

FetchProgress.TITLE = 'LRRP: smart previews'
FetchProgress.THRESHOLD = 20 -- smart previews to bring in before a bar is shown

function FetchProgress.new()
    return { shown = false }
end

local function caption(facts, done, total, failed)
    if facts.waiting then
        return string.format('Waiting for Lightroom\'s import to end: %d ready on the server, %d being built',
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
