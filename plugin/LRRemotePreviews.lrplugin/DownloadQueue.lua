-- Downloads several smart previews at the same time and hands every finished download over for checking and
-- placing strictly one at a time, and only in the task that owns the queue. Pure Lua 5.1: everything that touches
-- Lightroom or the network is passed in (env), so it runs in unit tests, where coroutines stand in for tasks.
--
--   local queue = DownloadQueue.new(env, { concurrency = 4 })
--   queue:add(task)               -- task: a table; env.download(task) fetches it
--   queue:pump(isCanceled)        -- owner: places what has arrived; call it while waiting for other things
--   queue:drain(isCanceled)       -- owner: waits until everything added is placed (true) or cancelled (false)
--   queue:stop()                  -- no further downloads or placing; returns the tasks that were not placed
--
-- env:
--   download(task) -> data | nil, problem   runs in a download task (in the owner when concurrency is 1)
--   deliver(task, data, problem)            runs only in the owner, inside pump/drain, never two at once
--   startTask(fn)                           runs fn as a separate task (LrTasks.startAsyncTask)
--   sleep(seconds)                          waits and lets other tasks run (LrTasks.sleep)
--   pcall(fn, ...)                          optional: a pcall that allows waiting inside fn (LrTasks.pcall)
--   log(format, ...)                        optional
-- options:
--   concurrency  downloads at the same time (default 4). 1 downloads in the owner itself, one file after the
--                other, without any extra task (the way version 0.2.0 worked)
--   step         seconds between two looks while waiting (default 0.1)
--   buffer       finished downloads kept before the download tasks wait for the owner (default 2 * concurrency)
-- If a download task cannot be started, the queue falls back to downloading in the owner.
local DownloadQueue = {}
DownloadQueue.__index = DownloadQueue

function DownloadQueue.new(env, options)
    options = options or {}
    local concurrency = math.max(1, math.floor(tonumber(options.concurrency) or 4))
    return setmetatable({
        env = env,
        concurrency = concurrency,
        step = options.step or 0.1,
        buffer = options.buffer or 2 * concurrency,
        inline = concurrency <= 1,
        pending = {}, nextPending = 1, -- tasks not started yet
        finished = {}, nextFinished = 1, -- { task, data, problem } waiting to be placed (false once placed)
        inFlight = {}, inFlightCount = 0, -- tasks being downloaded
        order = {}, -- task -> the number it was added with
        workers = 0, -- download tasks alive
        stopped = false,
        delivering = false,
        added = 0,
        delivered = 0,
        maxInFlight = 0,
    }, DownloadQueue)
end

local function log(self, ...)
    if self.env.log then
        self.env.log(...)
    end
end

local function protect(self, fn, ...)
    return (self.env.pcall or pcall)(fn, ...)
end

function DownloadQueue:pendingCount()
    return #self.pending - self.nextPending + 1
end

function DownloadQueue:finishedCount()
    return #self.finished - self.nextFinished + 1
end

-- True when everything added has been placed (or the queue was stopped and nothing is left).
function DownloadQueue:isIdle()
    return self:pendingCount() == 0 and self:finishedCount() == 0 and self.inFlightCount == 0
end

local function takePending(self)
    if self.nextPending > #self.pending then
        return nil
    end
    local task = self.pending[self.nextPending]
    self.nextPending = self.nextPending + 1
    return task
end

local function download(self, task)
    self.inFlight[task] = true
    self.inFlightCount = self.inFlightCount + 1
    if self.inFlightCount > self.maxInFlight then
        self.maxInFlight = self.inFlightCount
    end
    local ok, data, problem = protect(self, self.env.download, task)
    self.inFlight[task] = nil
    self.inFlightCount = self.inFlightCount - 1
    if not ok then
        return nil, { message = 'the download stopped with an error: ' .. tostring(data) }
    end
    return data, problem
end

local function workerLoop(self)
    while not self.stopped do
        if self:finishedCount() >= self.buffer then
            self.env.sleep(self.step) -- the owner is behind; do not pile up files in memory
        else
            local task = takePending(self)
            if task == nil then
                return
            end
            local data, problem = download(self, task)
            if self.stopped then
                return
            end
            self.finished[#self.finished + 1] = { task = task, data = data, problem = problem }
        end
    end
end

local function runWorker(self)
    local ok, err = protect(self, workerLoop, self)
    self.workers = self.workers - 1
    if not ok then
        log(self, 'a download task stopped with an error: %s', tostring(err))
    end
end

-- Starts download tasks while there is work no running task is about to take.
local function startWorkers(self)
    while not self.inline and not self.stopped and self.workers < self.concurrency
        and self:pendingCount() > self.workers - self.inFlightCount do
        self.workers = self.workers + 1
        local ok, err = protect(self, self.env.startTask, function()
            runWorker(self)
        end)
        if not ok then
            self.workers = self.workers - 1
            self.inline = true
            log(self, 'cannot start a download task (%s); downloading one file at a time instead', tostring(err))
        end
    end
end

-- Adds a task (a table, added once). Returns false when the queue was stopped.
function DownloadQueue:add(task)
    if self.stopped then
        return false
    end
    self.added = self.added + 1
    self.order[task] = self.added
    self.pending[#self.pending + 1] = task
    startWorkers(self)
    return true
end

local function deliverOne(self, task, data, problem)
    self.env.deliver(task, data, problem)
    self.delivered = self.delivered + 1
end

local function pumpBody(self, isCanceled)
    local progressed = false
    local function canceled()
        return self.stopped or (isCanceled ~= nil and isCanceled())
    end
    startWorkers(self)
    while not canceled() and self:finishedCount() > 0 do
        local done = self.finished[self.nextFinished]
        self.finished[self.nextFinished] = false
        self.nextFinished = self.nextFinished + 1
        deliverOne(self, done.task, done.data, done.problem)
        progressed = true
    end
    if self.inline and not canceled() then
        local task = takePending(self)
        if task then
            local data, problem = download(self, task)
            if not canceled() then
                deliverOne(self, task, data, problem)
            else
                self.finished[#self.finished + 1] = { task = task, data = data, problem = problem }
            end
            progressed = true
        end
    end
    -- Download tasks that ended while their file was still counted as in flight cannot happen with a protected
    -- download; should it happen anyway, report those files instead of waiting for them forever.
    if not self.inline and self.workers == 0 and self:pendingCount() == 0 and self.inFlightCount > 0 then
        for task in pairs(self.inFlight) do
            self.inFlight[task] = nil
            self.finished[#self.finished + 1] = { task = task,
                problem = { message = 'the download task ended without an answer' } }
        end
        self.inFlightCount = 0
        progressed = true
    end
    startWorkers(self)
    return progressed
end

-- Owner only: places every download that has arrived, one at a time (with concurrency 1: downloads and places
-- the next file). Returns true when something happened. A call while another pump is placing does nothing.
function DownloadQueue:pump(isCanceled)
    if self.delivering then
        return false
    end
    self.delivering = true
    local ok, result = protect(self, pumpBody, self, isCanceled)
    self.delivering = false
    if not ok then
        error(result, 0)
    end
    return result
end

-- Owner only: pumps and waits until everything added has been placed. Returns true then, or false as soon as
-- isCanceled() says so (call stop() afterwards to learn what was not placed).
function DownloadQueue:drain(isCanceled)
    while true do
        local progressed = self:pump(isCanceled)
        if isCanceled and isCanceled() then
            return false
        end
        if self:isIdle() then
            return true
        end
        if not progressed then
            self.env.sleep(self.step)
        end
    end
end

-- Stops the queue: nothing further is downloaded or placed, downloads in flight are discarded when they arrive.
-- Returns the tasks that were not placed, in the order they were added.
function DownloadQueue:stop()
    self.stopped = true
    local left = {}
    for i = self.nextPending, #self.pending do
        left[#left + 1] = self.pending[i]
    end
    self.nextPending = #self.pending + 1
    for i = self.nextFinished, #self.finished do
        if self.finished[i] then
            left[#left + 1] = self.finished[i].task
            self.finished[i] = false
        end
    end
    self.nextFinished = #self.finished + 1
    for task in pairs(self.inFlight) do
        left[#left + 1] = task
    end
    table.sort(left, function(a, b)
        return self.order[a] < self.order[b]
    end)
    return left
end

return DownloadQueue
