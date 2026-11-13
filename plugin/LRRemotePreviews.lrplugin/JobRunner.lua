-- The polling loop of one job, with everything that touches Lightroom or the network passed in, so it is pure
-- Lua 5.1 and runs in unit tests.
--
--   local result = JobRunner.run(env, tracker, initialItems, options)
--
-- env (all functions):
--   fetchItems(since) -> page { job, items, more } | nil, problem { message, fatal }
--   handle(item)      called once for every item that reached a final state (download, check, place ...)
--   isCanceled()      -> true when the user cancelled
--   sleep(seconds)
--   cancelJob()       -> true | nil, problem; called once when the user cancelled
--   progress(tracker) after every change
--   log(format, ...)
-- initialItems: the items of the POST answer; they are applied before the first poll.
-- Result: { completed = true } | { cancelled = true, cancelProblem = problem | nil } | { aborted = message }.
--
-- Polling waits options.minDelay seconds after a poll that brought changes, and multiplies the wait by
-- options.factor (up to options.maxDelay) after one that did not; it asks again at once when the server says
-- there is more. The wait is spent in steps of options.step seconds so that a cancel is noticed quickly.
local JobRunner = {}

JobRunner.DEFAULTS = {
    minDelay = 1,
    maxDelay = 5,
    factor = 1.5,
    step = 0.25,
    maxFailures = 10, -- polls in a row that fail before giving up
    maxIdleDone = 3, -- polls in a row with a finished job, no news and items still open, before giving up
}

function JobRunner.nextDelay(current, changed, options)
    options = options or JobRunner.DEFAULTS
    if changed then
        return options.minDelay
    end
    return math.min(options.maxDelay, math.max(options.minDelay, (current or 0) * options.factor))
end

local function withDefaults(options)
    local merged = {}
    for key, value in pairs(JobRunner.DEFAULTS) do
        merged[key] = value
    end
    for key, value in pairs(options or {}) do
        merged[key] = value
    end
    return merged
end

function JobRunner.run(env, tracker, initialItems, options)
    options = withDefaults(options)

    local function cancel()
        env.log('cancelled by the user; cancelling the job on the server')
        local ok, problem = env.cancelJob()
        return { cancelled = true, cancelProblem = (not ok) and problem or nil }
    end

    -- Handles the items that just became final; false when the user cancelled in between.
    local function handleAll(items)
        for _, item in ipairs(items) do
            if env.isCanceled() then
                return false
            end
            env.handle(item)
            env.progress(tracker)
        end
        return true
    end

    -- Waits; true when the user cancelled meanwhile.
    local function wait(seconds)
        if env.isCanceled() then
            return true
        end
        local waited = 0
        while waited < seconds do
            env.sleep(options.step)
            waited = waited + options.step
            if env.isCanceled() then
                return true
            end
        end
        return false
    end

    if not handleAll(tracker:apply(initialItems)) then
        return cancel()
    end
    env.progress(tracker)

    local delay, failures, idleDone = options.minDelay, 0, 0
    while not tracker:isComplete() do
        if wait(delay) then
            return cancel()
        end
        local page, problem = env.fetchItems(tracker.since)
        if page then
            failures = 0
            local items = page.items or {}
            if not handleAll(tracker:apply(items)) then
                return cancel()
            end
            env.progress(tracker)
            local changed = #items > 0
            local jobState = page.job and page.job.state
            if not changed and not page.more and jobState and jobState ~= 'active' and not tracker:isComplete() then
                idleDone = idleDone + 1
                if idleDone >= options.maxIdleDone then
                    return { aborted = string.format('The server says the job is %s, but %d item(s) never reached '
                        .. 'a final state.', jobState, tracker.total - tracker.final) }
                end
            else
                idleDone = 0
            end
            if page.more and changed then
                delay = 0
            else
                delay = JobRunner.nextDelay(delay, changed, options)
            end
        else
            failures = failures + 1
            env.log('polling failed (%d in a row): %s', failures, tostring(problem and problem.message))
            if (problem and problem.fatal) or failures >= options.maxFailures then
                return { aborted = (problem and problem.message) or 'Polling the server failed.' }
            end
            delay = JobRunner.nextDelay(delay, false, options)
        end
    end
    return { completed = true }
end

return JobRunner
