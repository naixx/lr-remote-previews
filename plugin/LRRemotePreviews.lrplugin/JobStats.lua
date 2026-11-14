-- Times and counts per job of the automatic path, for the log lines to measure with: for each photo the time from
-- first seen in the catalog to sent, for each smart preview the time from the server's «ready» (as this side saw it) to
-- placed and to registered, and per job the totals. Pure Lua 5.1.
local JobStats = {}

JobStats.KINDS = {
    { 'sent', 'sent', 'first seen in the catalog -> sent' },
    { 'placed', 'placed', 'ready -> placed' },
    { 'registered', 'registered', 'ready -> registered' },
}

function JobStats.new()
    return { jobs = {} }
end

local function job(stats, jobId)
    local key = string.format('%d', jobId)
    stats.jobs[key] = stats.jobs[key] or { samples = { sent = {}, placed = {}, registered = {} }, failed = 0 }
    return stats.jobs[key]
end

-- Records one photo of a job: kind 'sent' | 'placed' | 'registered' with the seconds it took (nil: not measured).
function JobStats.add(stats, jobId, kind, seconds)
    local list = job(stats, jobId).samples[kind]
    list[#list + 1] = type(seconds) == 'number' and seconds or false
end

-- Records a photo of a job that did not make it (left out after it was ready, download or write failed).
function JobStats.fail(stats, jobId)
    local entry = job(stats, jobId)
    entry.failed = entry.failed + 1
end

function JobStats.count(stats, jobId, kind)
    local entry = stats.jobs[string.format('%d', jobId)]
    return entry and #entry.samples[kind] or 0
end

-- '1.2 s', '14 s'; '?' for nil.
function JobStats.seconds(value)
    if type(value) ~= 'number' then
        return '?'
    end
    if value < 10 then
        return string.format('%.1f s', value)
    end
    return string.format('%d s', math.floor(value + 0.5))
end

local seconds = JobStats.seconds

-- 'median 1.2 s, max 3.4 s' for the measured samples, or nil when none was measured.
function JobStats.spread(samples)
    local values = {}
    for _, value in ipairs(samples) do
        if value then
            values[#values + 1] = value
        end
    end
    if #values == 0 then
        return nil
    end
    table.sort(values)
    local middle = math.floor((#values + 1) / 2)
    local median = #values % 2 == 1 and values[middle] or (values[middle] + values[middle + 1]) / 2
    return 'median ' .. seconds(median) .. ', max ' .. seconds(values[#values])
end

-- The totals line of a job: 'job 12 «label»: 449 sent (first seen in the catalog -> sent: median 2.0 s, max 4.0 s),
-- 449 placed (ready -> placed: ...), 449 registered (...), 0 failed'.
function JobStats.summary(stats, jobId, label)
    local entry = job(stats, jobId)
    local parts = {}
    for _, kind in ipairs(JobStats.KINDS) do
        local samples = entry.samples[kind[1]]
        local spread = JobStats.spread(samples)
        parts[#parts + 1] = #samples .. ' ' .. kind[2] .. (spread and (' (' .. kind[3] .. ': ' .. spread .. ')') or '')
    end
    parts[#parts + 1] = entry.failed .. ' failed'
    return string.format('job %d%s: %s', jobId, label and (' «' .. label .. '»') or '', table.concat(parts, ', '))
end

-- Forgets a job.
function JobStats.forget(stats, jobId)
    stats.jobs[string.format('%d', jobId)] = nil
end

return JobStats
