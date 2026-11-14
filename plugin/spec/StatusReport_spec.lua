-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local StatusReport = require 'StatusReport'

local NOW = 1794648600 -- 2026-11-14T09:30:00Z

local function job(id, state, counts, extra)
    local all = { total = 0, queued = 0, building = 0, ready = 0, failed = 0, rejected = 0, cancelled = 0 }
    for key, value in pairs(counts or {}) do
        all[key] = value
    end
    local result = { id = id, state = state, counts = all, label = 'Lightroom selection',
        created = '2026-11-14T06:30:00Z' }
    for key, value in pairs(extra or {}) do
        result[key] = value
    end
    return result
end

describe('StatusReport times', function()
    it('reads protocol times as seconds since 1970 UTC', function()
        assert.are.equal(1794648600, StatusReport.parseTime('2026-11-14T09:30:00Z'))
        assert.are.equal(0, StatusReport.parseTime('1970-01-01T00:00:00Z'))
        assert.are.equal(951868799, StatusReport.parseTime('2000-02-29T23:59:59Z'))
        assert.are.equal(1709251200, StatusReport.parseTime('2024-03-01T00:00:00Z'))
        for _, bad in ipairs({ '2026-11-14 09:30:00', '2026-11-14T09:30:00+01:00', '2026-11-14T09:30:00.5Z', 5 }) do
            assert.is_nil(StatusReport.parseTime(bad))
        end
    end)

    it('says how long ago', function()
        assert.are.equal('just now', StatusReport.age('2026-11-14T09:29:30Z', NOW))
        assert.are.equal('12 min ago', StatusReport.age('2026-11-14T09:18:00Z', NOW))
        assert.are.equal('3 h ago', StatusReport.age('2026-11-14T06:30:00Z', NOW))
        assert.are.equal('47 h ago', StatusReport.age('2026-11-12T10:30:00Z', NOW))
        assert.are.equal('5 days ago', StatusReport.age('2026-11-09T09:30:00Z', NOW))
        assert.is_nil(StatusReport.age(nil, NOW))
    end)
end)

describe('StatusReport texts', function()
    it('writes one line per job with the four counts', function()
        assert.are.equal('Job 12 "Lightroom selection", sent 3 h ago: ready 190, building 8, queued 300, failed 2',
            StatusReport.jobLine(job(12, 'active', { ready = 190, building = 8, queued = 300, failed = 2 }), NOW))
        assert.are.equal('Job 3: ready 0, building 0, queued 0, failed 0 (cancelled)',
            StatusReport.jobLine({ id = 3, state = 'cancelled', counts = {} }, NOW))
    end)

    it('describes the jobs part for each case', function()
        assert.matches('has not sent any job', StatusReport.jobsText({ jobs = {}, now = NOW }))
        assert.matches('could not be read: HTTP 500', StatusReport.jobsText({ clientId = 'x', problem = 'HTTP 500',
            jobs = {}, now = NOW }))
        local none = StatusReport.jobsText({ clientId = 'x', jobs = {}, listed = 4, waiting = 0, now = NOW,
            retentionDays = 30 })
        assert.matches('has 4 job%(s%) on the server, none with anything left', none)
        assert.matches('deletes a job 30 days after it finished', none)
        assert.matches('No smart previews wait to be fetched%.', none)
        local some = StatusReport.jobsText({ clientId = 'x', jobs = { job(12, 'active', { ready = 5 }),
            job(11, 'done', { failed = 1 }) }, listed = 3, waiting = 5, now = NOW })
        assert.matches('still matter %(2 of 3%):', some)
        assert.matches('\n    Job 12 ', some)
        assert.matches('\n    Job 11 ', some)
        assert.matches('Up to 5 smart previews are ready on the server and not fetched by this catalog yet%.', some)
        assert.matches('Up to 1 smart preview is ready', StatusReport.jobsText({ clientId = 'x', jobs = {},
            waiting = 1, now = NOW }))
        assert.matches('is not known', StatusReport.jobsText({ clientId = 'x', jobs = {}, now = NOW }))
        assert.matches('600 smart previews are placed in the smart preview folder and not registered by Lightroom yet',
            StatusReport.jobsText({ clientId = 'x', jobs = {}, waiting = 0, unregistered = 600, now = NOW }))
        assert.is_nil(StatusReport.jobsText({ clientId = 'x', jobs = {}, waiting = 0, unregistered = 0, now = NOW })
            :find('not registered', 1, true))
    end)

    it('shows at most MAX_JOBS jobs and counts the rest', function()
        local many = {}
        for i = 1, StatusReport.MAX_JOBS + 3 do
            many[i] = job(100 - i, 'active', { queued = 1 })
        end
        local text = StatusReport.jobsText({ clientId = 'x', jobs = many, waiting = 0, now = NOW })
        assert.matches('%.%.%. and 3 more', text)
        local lines = 0
        for _ in text:gmatch('\n    Job ') do
            lines = lines + 1
        end
        assert.are.equal(StatusReport.MAX_JOBS, lines)
    end)

    it('offers the jobs with failed items that are not cancelled for a retry', function()
        assert.are.same({ { title = 'Job 11: 2 failed', value = 11 } }, StatusReport.retryChoices({
            job(12, 'active', { ready = 5 }),
            job(11, 'done', { failed = 2 }),
            job(10, 'cancelled', { failed = 1 }),
        }))
    end)

    it('words the answer to a retry, whatever state the server already reports', function()
        -- It fits the 80 characters of the line under the Retry button.
        local text = StatusReport.retryText(job(11, 'active', { queued = 1, building = 1 }))
        assert.are.equal('Job 11 tried again: now queued 1, building 1, failed 0. Fetch later.', text)
        assert.is_true(#StatusReport.retryText(job(123456, 'active', { queued = 4999, building = 16 })) <= 80)
        assert.matches('now queued 0, building 0, failed 1', StatusReport.retryText(job(11, 'done', { failed = 1 })))
    end)
end)
