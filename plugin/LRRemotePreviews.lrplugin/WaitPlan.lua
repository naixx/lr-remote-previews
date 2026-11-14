-- The waiting requests of the automatic fetch (docs/protocol.md, GET /api/v1/jobs/{id}/items, "Waiting for a
-- change"): how long to ask the server to wait, the timeout to give LrHttp, and what each answer means. Pure Lua 5.1.
--
-- For every pending job the automatic fetch keeps one request open: GET .../items?since=<largest seq>&state=ready&
-- wait=<seconds>. The server answers as soon as an item of the job becomes ready (or one is added ready), and
-- otherwise after the wait with no items, which is the normal case, not an error: the plug-in then asks again at once.
-- A server without capabilities.maxWaitSeconds (before server 0.6.0) answers at once; then the plug-in asks at the
-- interval of the settings, as version 0.7.0 did, never in a loop.
--
-- LrHttp: "timeout: The length of time (in seconds) to wait during each phase of the connection before canceling the
-- request" (Lightroom SDK reference for LrHttp.get; the error code of a request that ran out of time is "timedOut").
-- Waiting for the server's answer is such a phase, so the timeout given to LrHttp must be longer than the wait. The
-- plug-in asks for at most MAX_WAIT seconds and gives LrHttp the wait plus TIMEOUT_MARGIN. Should a waiting request
-- still end with "timedOut" (an LrHttp that cuts it shorter than asked), the wait is halved for the rest of the
-- session, down to MIN_WAIT, instead of counting the server as not answering.
local WaitPlan = {}

WaitPlan.MAX_WAIT = 25
WaitPlan.MIN_WAIT = 5
WaitPlan.TIMEOUT_MARGIN = 30
WaitPlan.PLAIN_TIMEOUT = 15 -- the timeout of a request that does not wait

-- The seconds to ask the server to wait, or nil when it cannot wait (no maxWaitSeconds). shortened: how many times
-- a waiting request ran out of time on this side.
function WaitPlan.wait(maxWaitSeconds, shortened)
    if type(maxWaitSeconds) ~= 'number' or maxWaitSeconds < 1 then
        return nil
    end
    local wait = math.min(math.floor(maxWaitSeconds), WaitPlan.MAX_WAIT)
    for _ = 1, shortened or 0 do
        wait = math.floor(wait / 2)
    end
    return math.max(math.min(WaitPlan.MIN_WAIT, math.floor(maxWaitSeconds)), wait)
end

-- The timeout for LrHttp: the wait plus TIMEOUT_MARGIN, or PLAIN_TIMEOUT for a request that does not wait.
function WaitPlan.timeout(wait)
    if not wait then
        return WaitPlan.PLAIN_TIMEOUT
    end
    return wait + WaitPlan.TIMEOUT_MARGIN
end

-- What an answer means. page: { job = { state, seq }, items = { { seq, state, ... } }, more }; since: what was asked.
-- Returns { since = the new largest seq, ready = { items in state ready }, active = the job is active,
--           drained = nothing more to read now (more is false) }.
function WaitPlan.answer(page, since)
    local result = { since = since or 0, ready = {}, active = page.job.state == 'active', drained = not page.more }
    for _, item in ipairs(page.items or {}) do
        if item.seq > result.since then
            result.since = item.seq
        end
        if item.state == 'ready' then
            result.ready[#result.ready + 1] = item
        end
    end
    return result
end

-- The job needs nothing more from this side: it is not active (done or cancelled), the last answer had nothing more
-- to read, and no item received from it is still open (to be downloaded, placed or tried again).
function WaitPlan.done(answer, open)
    return answer ~= nil and not answer.active and answer.drained and (open or 0) == 0
end

-- What a failed request means. problem: { kind, status, code, timedOut }; waited: the wait asked for (nil: none).
--   'gone'     the server no longer knows the job (404): stop following it
--   'shorten'  a waiting request ran out of time on this side (LrHttp's "timedOut"): wait less, ask again
--   'failed'   anything else (no answer, an error answer, a rejected token): back off
function WaitPlan.failure(problem, waited)
    problem = problem or {}
    if problem.status == 404 then
        return 'gone'
    end
    if problem.timedOut and waited then
        return 'shorten'
    end
    return 'failed'
end

WaitPlan.EARLY = 1 -- an empty answer to a waiting request sooner than this (seconds) came before the wait was over
WaitPlan.EARLY_PAUSE = 5

-- Seconds to sleep before the next request of a job after an answer. waits: the server can wait; interval: the slow
-- interval of the settings; elapsed: how long the request took. Items or more to read: at once. Nothing new: at once
-- when the server waits (it holds the next request), else after the interval. An empty answer that came back at once
-- although the server was asked to wait (a server that is shutting down answers its waiting requests that way) is
-- followed by a short pause, so that nothing ever asks in a tight loop; the next request then meets the server gone,
-- and the back-off applies.
function WaitPlan.pause(answer, waits, interval, elapsed)
    if #answer.ready > 0 or not answer.drained then
        return 0
    end
    if waits then
        if elapsed ~= nil and elapsed < WaitPlan.EARLY then
            return WaitPlan.EARLY_PAUSE
        end
        return 0
    end
    return interval
end

return WaitPlan
