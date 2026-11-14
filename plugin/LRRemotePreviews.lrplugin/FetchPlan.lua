-- «Everything this catalog sent»: which of the catalog's jobs on the server have to be read, and what to remember
-- about each job afterwards, so that the next fetch does not read again what was dealt with. Pure Lua 5.1.
--
-- A job record (CatalogState) is { since, doneSeq }:
--   since    every ready item of the job with seq <= since has an outcome that needs no second attempt;
--            the next fetch asks for GET .../items?since=<since>&state=ready only.
--   doneSeq  the job's seq when it was no longer active and nothing was left to fetch from it. While the job's
--            seq stays the same it is not read again; a retry of its failed items changes the seq (and makes the
--            job active), so it is read again.
-- Item seqs only change with a state change and a ready item stays ready (docs/protocol.md), so every item that
-- becomes ready later has a seq above everything read now.
local FetchPlan = {}

-- Outcomes after which a photo needs nothing more from this job. Anything else (a download or write that failed, a
-- file that is still being built, a run that stopped first) is tried again by the next fetch.
FetchPlan.FINAL = {
    delivered = true, deliveredOther = true, destinationExists = true, checkFailed = true,
    absent = true, rejected = true,
    video = true, noPath = true, hasSmartPreview = true, unsupportedFormat = true, noMapping = true,
    noLocalId = true, noFileId = true, fileIdMismatch = true,
    notInCatalog = true, badPath = true,
}

function FetchPlan.isFinal(outcome)
    return FetchPlan.FINAL[outcome] == true
end

local function idText(id)
    return string.format('%d', id)
end

-- Decides which jobs to read. jobs: the server's list (Jobs.parseJobList); records: CatalogState.jobs();
-- clientId: this catalog's. Jobs with another clientId are ignored (a server that does not filter by clientId).
-- Returns
--   { read = { { job, since }, ... },      jobs with ready items that may not have been dealt with
--     done = n,                            jobs fully dealt with earlier (not read)
--     waiting = n,                         active jobs with nothing ready yet (not read)
--     foreign = n,                         jobs of other clients in the answer
--     records = { [id] = record } }        the records to keep: those of the listed jobs (the server deleted the
--                                          others), with jobs that ended with nothing ready marked done
function FetchPlan.plan(jobs, records, clientId)
    local plan = { read = {}, done = 0, waiting = 0, foreign = 0, records = {} }
    for _, job in ipairs(jobs) do
        if job.clientId ~= clientId then
            plan.foreign = plan.foreign + 1
        else
            local id = idText(job.id)
            local record = records[id]
            local active = job.state == 'active'
            if record then
                plan.records[id] = record
            end
            if record and not active and record.doneSeq ~= nil and record.doneSeq == job.seq then
                plan.done = plan.done + 1
            elseif (job.counts.ready or 0) == 0 then
                if active then
                    plan.waiting = plan.waiting + 1
                else
                    plan.done = plan.done + 1
                    if job.seq ~= nil then
                        plan.records[id] = { since = record and record.since or 0, doneSeq = job.seq }
                    end
                end
            else
                plan.read[#plan.read + 1] = { job = job, since = record and record.since or 0 }
            end
        end
    end
    return plan
end

-- The record of a job after its ready items were read and dealt with.
-- job: as listed before reading; since: what was asked for; items: the ready items read ({ seq, ... }), complete
-- (every page); outcomeOf(item): the outcome of that item in this run. Returns { since, doneSeq }.
function FetchPlan.advance(job, since, items, outcomeOf)
    local firstOpen, highest = nil, since
    for _, item in ipairs(items) do
        if item.seq > highest then
            highest = item.seq
        end
        if not FetchPlan.isFinal(outcomeOf(item)) and (firstOpen == nil or item.seq < firstOpen) then
            firstOpen = item.seq
        end
    end
    if firstOpen then
        return { since = math.max(since, firstOpen - 1) }
    end
    local record = { since = highest }
    if job.state ~= 'active' and job.seq ~= nil then
        record.doneSeq = job.seq
    end
    return record
end

-- The jobs worth showing in the status dialog: active ones, ones not fully fetched, and ones with failed items,
-- in the server's order (newest first). Same arguments as FetchPlan.plan; jobs of other clients are left out.
function FetchPlan.interesting(jobs, records, clientId)
    local list = {}
    for _, job in ipairs(jobs) do
        if job.clientId == clientId then
            local record = records[idText(job.id)]
            local done = record and record.doneSeq ~= nil and record.doneSeq == job.seq
            if job.state == 'active' or (job.counts.failed or 0) > 0
                or (not done and (job.counts.ready or 0) > 0) then
                list[#list + 1] = job
            end
        end
    end
    return list
end

return FetchPlan
