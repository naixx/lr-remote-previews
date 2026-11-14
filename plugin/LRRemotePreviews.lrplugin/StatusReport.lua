-- The texts of the status dialog: this catalog's jobs that still matter, how many smart previews wait to be
-- fetched, and the retry choices. The server part comes from ServerInfo.formatReport. Pure Lua 5.1.
local StatusReport = {}

StatusReport.MAX_JOBS = 10 -- job lines shown; the rest are counted

local function floor(x)
    return math.floor(x)
end

-- Days since 1970-01-01 of a date in the proleptic Gregorian calendar (H. Hinnant's days_from_civil).
local function daysFromCivil(year, month, day)
    year = month <= 2 and year - 1 or year
    local era = floor(year / 400)
    local yearOfEra = year - era * 400
    local monthIndex = (month + 9) % 12
    local dayOfYear = floor((153 * monthIndex + 2) / 5) + day - 1
    local dayOfEra = yearOfEra * 365 + floor(yearOfEra / 4) - floor(yearOfEra / 100) + dayOfYear
    return era * 146097 + dayOfEra - 719468
end

-- Seconds since 1970-01-01 UTC for a protocol time ('2026-11-14T09:30:00Z'), or nil.
function StatusReport.parseTime(text)
    if type(text) ~= 'string' then
        return nil
    end
    local y, mo, d, h, mi, s = text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$')
    if not y then
        return nil
    end
    return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60
        + tonumber(s)
end

-- How long ago a protocol time was, from now (seconds since 1970 UTC, as os.time() gives): 'just now',
-- '12 min ago', '3 h ago', '2 days ago'; nil when the time is unreadable.
function StatusReport.age(time, now)
    local seconds = StatusReport.parseTime(time)
    if not seconds then
        return nil
    end
    local delta = now - seconds
    if delta < 60 then
        return 'just now'
    elseif delta < 3600 then
        return floor(delta / 60) .. ' min ago'
    elseif delta < 2 * 86400 then
        return floor(delta / 3600) .. ' h ago'
    end
    return floor(delta / 86400) .. ' days ago'
end

-- One line per job: 'Job 12 "Lightroom selection", sent 3 h ago: ready 190, building 8, queued 300, failed 2'.
function StatusReport.jobLine(job, now)
    local counts = job.counts or {}
    local parts = { 'Job ' .. string.format('%d', job.id) }
    if job.label and job.label ~= '' then
        parts[1] = parts[1] .. ' "' .. job.label .. '"'
    end
    local age = StatusReport.age(job.created, now)
    if age then
        parts[1] = parts[1] .. ', sent ' .. age
    end
    local line = parts[1] .. string.format(': ready %d, building %d, queued %d, failed %d', counts.ready or 0,
        counts.building or 0, counts.queued or 0, counts.failed or 0)
    if job.state == 'cancelled' then
        line = line .. ' (cancelled)'
    end
    return line
end

-- The jobs part of the status dialog. context:
--   clientId (nil when this catalog never sent a job), jobs (FetchPlan.interesting), listed (number of this
--   catalog's jobs on the server), waiting (smart previews ready and not yet fetched by this catalog, or nil when
--   unknown), retentionDays (or nil), now (os.time()), problem (message when the jobs could not be read),
--   unregistered (smart previews the automatic fetch placed and Lightroom has not registered yet, or nil).
function StatusReport.jobsText(context)
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    if not context.clientId then
        add('This catalog has not sent any job to the server yet.')
        return table.concat(lines, '\n')
    end
    if context.problem then
        add('This catalog\'s jobs could not be read: ' .. context.problem)
        return table.concat(lines, '\n')
    end
    local retention = context.retentionDays
        and (' The server deletes a job ' .. context.retentionDays .. ' days after it finished.') or ''
    if #context.jobs == 0 then
        add('This catalog has ' .. (context.listed or 0) .. ' job(s) on the server, none with anything left to fetch, '
            .. 'build or retry.' .. retention)
    else
        add('This catalog\'s jobs on the server that still matter (' .. #context.jobs .. ' of '
            .. (context.listed or #context.jobs) .. '):' .. retention)
        for i, job in ipairs(context.jobs) do
            if i > StatusReport.MAX_JOBS then
                add('    ... and ' .. (#context.jobs - StatusReport.MAX_JOBS) .. ' more')
                break
            end
            add('    ' .. StatusReport.jobLine(job, context.now))
        end
    end
    add('')
    if context.waiting == nil then
        add('How many smart previews wait to be fetched is not known (the server could not be asked).')
    elseif context.waiting == 0 then
        add('No smart previews wait to be fetched.')
    else
        add(string.format('Up to %d smart preview%s ready on the server and not fetched by this catalog yet.',
            context.waiting, context.waiting == 1 and ' is' or 's are'))
    end
    if (context.unregistered or 0) > 0 then
        add(string.format('%d smart preview%s placed in the smart preview folder and not registered by Lightroom yet '
            .. '(the automatic fetch registers them with one call when no import is running).',
            context.unregistered, context.unregistered == 1 and ' is' or 's are'))
    end
    return table.concat(lines, '\n')
end

-- The jobs whose failed items can be retried (failed items, not cancelled), as popup items
-- { { title, value = job id }, ... }.
function StatusReport.retryChoices(jobs)
    local choices = {}
    for _, job in ipairs(jobs) do
        if (job.counts.failed or 0) > 0 and job.state ~= 'cancelled' then
            choices[#choices + 1] = {
                title = string.format('Job %d: %d failed', job.id, job.counts.failed),
                value = job.id,
            }
        end
    end
    return choices
end

-- The line after a retry. job: the job the server answered with. The server checks each retried file again as it
-- is now, so its answer may already show items as building, or failed again (a file that is gone).
function StatusReport.retryText(job)
    local counts = job.counts or {}
    return string.format('Job %d tried again: now queued %d, building %d, failed %d. Fetch later.', job.id,
        counts.queued or 0, counts.building or 0, counts.failed or 0)
end

return StatusReport
