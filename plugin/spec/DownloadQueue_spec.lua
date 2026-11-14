-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local DownloadQueue = require 'DownloadQueue'

-- A pcall that lets the function wait (yield) inside it, as LrTasks.pcall does in Lightroom. Lua 5.1's own pcall
-- cannot be yielded across.
local function copcall(f, ...)
    local co = coroutine.create(f)
    local results = { coroutine.resume(co, ...) }
    while true do
        if not results[1] then
            return false, results[2]
        end
        if coroutine.status(co) == 'dead' then
            return unpack(results, 1, table.maxn(results))
        end
        results = { coroutine.resume(co, coroutine.yield(unpack(results, 2, table.maxn(results)))) }
    end
end

-- A small cooperative world standing in for Lightroom's tasks: every task is a coroutine; waiting (sleep, a
-- download in flight, a buildSmartPreview call) yields; run() resumes the tasks in turn until all have ended.
-- The task that owns the queue is called 'owner'.
local function newWorld()
    local world = { tasks = {}, current = nil, inFlight = 0, maxInFlight = 0, placed = {}, delivering = false,
        overlaps = 0, startCalls = 0, wrongTask = 0, downloadsInOwner = 0, maxWaiting = 0 }
    function world.spawn(name, fn)
        world.tasks[#world.tasks + 1] = { name = name, co = coroutine.create(fn) }
    end
    function world.run()
        for _ = 1, 100000 do
            local alive = 0
            for _, task in ipairs(world.tasks) do
                if coroutine.status(task.co) ~= 'dead' then
                    alive = alive + 1
                    world.current = task.name
                    local ok, err = coroutine.resume(task.co)
                    world.current = nil
                    if not ok then
                        error(task.name .. ': ' .. tostring(err), 0)
                    end
                end
            end
            if world.queue then
                world.maxWaiting = math.max(world.maxWaiting, world.queue:finishedCount())
            end
            if alive == 0 then
                return
            end
        end
        error('the tasks did not finish')
    end
    function world.env(overrides)
        local env = {
            startTask = function(fn)
                world.startCalls = world.startCalls + 1
                world.spawn('download ' .. world.startCalls, fn)
            end,
            sleep = function()
                coroutine.yield()
            end,
            pcall = copcall,
            download = function(task)
                if world.current == 'owner' then
                    world.downloadsInOwner = world.downloadsInOwner + 1
                end
                world.inFlight = world.inFlight + 1
                world.maxInFlight = math.max(world.maxInFlight, world.inFlight)
                for _ = 1, task.delay or 3 do
                    coroutine.yield()
                end
                world.inFlight = world.inFlight - 1
                if task.raise then
                    error('connection reset')
                end
                if task.fail then
                    return nil, { message = 'HTTP 500' }
                end
                return 'data ' .. task.id
            end,
            deliver = function(task, data, problem)
                if world.current ~= 'owner' then
                    world.wrongTask = world.wrongTask + 1
                end
                if world.delivering then
                    world.overlaps = world.overlaps + 1
                end
                world.delivering = true
                for _ = 1, task.placeDelay or 1 do
                    coroutine.yield() -- like buildSmartPreview: other tasks run meanwhile
                end
                world.placed[#world.placed + 1] = { id = task.id, data = data, problem = problem }
                world.delivering = false
            end,
        }
        for key, value in pairs(overrides or {}) do
            env[key] = value
        end
        return env
    end
    return world
end

local function tasks(n, extra)
    local list = {}
    for i = 1, n do
        list[i] = { id = i }
        for key, value in pairs(extra or {}) do
            list[i][key] = value
        end
    end
    return list
end

local function placedIds(world)
    local ids = {}
    for i, placed in ipairs(world.placed) do
        ids[i] = placed.id
    end
    table.sort(ids)
    return ids
end

local function range(n)
    local list = {}
    for i = 1, n do
        list[i] = i
    end
    return list
end

-- Runs the owner: adds the tasks and drains the queue. Returns the queue and drain's result.
local function runOwner(world, env, options, list, isCanceled)
    local queue = DownloadQueue.new(env, options)
    world.queue = queue
    local result
    world.spawn('owner', function()
        for _, task in ipairs(list) do
            queue:add(task)
        end
        result = queue:drain(isCanceled)
        world.left = queue:stop()
    end)
    world.run()
    return queue, result
end

describe('DownloadQueue', function()
    it('downloads up to the given number at once and places one at a time, only in the owner', function()
        local world = newWorld()
        local queue, finished = runOwner(world, world.env(), { concurrency = 4 }, tasks(10))
        assert.is_true(finished)
        assert.are.same(range(10), placedIds(world))
        assert.are.equal(4, world.maxInFlight)
        assert.are.equal(4, queue.maxInFlight)
        assert.are.equal(0, world.overlaps)
        assert.are.equal(0, world.wrongTask)
        assert.are.equal(0, world.downloadsInOwner)
        assert.are.equal(4, world.startCalls)
        assert.are.equal(10, queue.delivered)
        assert.are.same({}, world.left)
    end)

    it('starts no more download tasks than there are files', function()
        local world = newWorld()
        runOwner(world, world.env(), { concurrency = 4 }, tasks(2))
        assert.are.equal(2, world.startCalls)
        assert.are.same({ 1, 2 }, placedIds(world))
    end)

    it('with concurrency 1 downloads in the owner, one after the other, without starting a task', function()
        local world = newWorld()
        local env = world.env({ startTask = function()
            error('no task should be started')
        end })
        local _, finished = runOwner(world, env, { concurrency = 1 }, tasks(5))
        assert.is_true(finished)
        assert.are.same(range(5), placedIds(world))
        assert.are.equal(1, world.maxInFlight)
        assert.are.equal(5, world.downloadsInOwner)
        assert.are.equal(0, world.overlaps)
    end)

    it('keeps the files waiting for the owner bounded when placing is slow', function()
        local world = newWorld()
        local _, finished = runOwner(world, world.env(), { concurrency = 3, buffer = 2 },
            tasks(20, { delay = 1, placeDelay = 6 }))
        assert.is_true(finished)
        assert.are.equal(20, #world.placed)
        assert.is_true(world.maxWaiting <= 2 + 3, 'waiting: ' .. world.maxWaiting)
    end)

    it('hands a failed download over with its problem, and turns a raised error into one', function()
        local world = newWorld()
        local list = tasks(3)
        list[2].fail = true
        list[3].raise = true
        runOwner(world, world.env(), { concurrency = 2 }, list)
        local byId = {}
        for _, placed in ipairs(world.placed) do
            byId[placed.id] = placed
        end
        assert.are.equal('data 1', byId[1].data)
        assert.is_nil(byId[2].data)
        assert.are.equal('HTTP 500', byId[2].problem.message)
        assert.is_nil(byId[3].data)
        assert.matches('connection reset', byId[3].problem.message)
        assert.are.equal(0, world.inFlight)
    end)

    it('stops on a cancel: drain says so, stop lists what was not placed, late downloads are dropped', function()
        local world = newWorld()
        local queue, finished = runOwner(world, world.env(), { concurrency = 4 }, tasks(12), function()
            return #world.placed >= 3
        end)
        assert.is_false(finished)
        assert.are.equal(3, #world.placed)
        assert.are.equal(9, #world.left)
        local all = placedIds(world)
        for _, task in ipairs(world.left) do
            all[#all + 1] = task.id
        end
        table.sort(all)
        assert.are.same(range(12), all)
        for i = 2, #world.left do
            assert.is_true(world.left[i - 1].id < world.left[i].id)
        end
        assert.are.equal(0, world.inFlight) -- the downloads in flight ended, and nothing was placed after the cancel
        assert.is_false(queue:add({ id = 99 }))
    end)

    it('falls back to downloading in the owner when a download task cannot be started', function()
        local world = newWorld()
        local logs = {}
        local env = world.env({
            startTask = function()
                error('no tasks today')
            end,
            log = function(...)
                logs[#logs + 1] = string.format(...)
            end,
        })
        local _, finished = runOwner(world, env, { concurrency = 4 }, tasks(4))
        assert.is_true(finished)
        assert.are.same(range(4), placedIds(world))
        assert.are.equal(4, world.downloadsInOwner)
        assert.matches('no tasks today', logs[1])
    end)

    it('takes files added while it is being pumped, as the build command adds them while polling', function()
        local world = newWorld()
        local queue = DownloadQueue.new(world.env(), { concurrency = 2 })
        local finished
        world.spawn('owner', function()
            queue:add({ id = 1 })
            queue:add({ id = 2 })
            for _ = 1, 5 do
                queue:pump()
                coroutine.yield()
            end
            queue:add({ id = 3 })
            queue:add({ id = 4 })
            queue:add({ id = 5 })
            finished = queue:drain()
        end)
        world.run()
        assert.is_true(finished)
        assert.are.same(range(5), placedIds(world))
        assert.are.equal(0, world.overlaps)
    end)

    it('ignores a pump from inside a delivery, so placing never nests', function()
        local world = newWorld()
        local queue
        local nested = {}
        local env = world.env()
        local deliver = env.deliver
        env.deliver = function(task, data, problem)
            nested[#nested + 1] = queue:pump()
            deliver(task, data, problem)
        end
        queue = DownloadQueue.new(env, { concurrency = 2 })
        world.spawn('owner', function()
            for _, task in ipairs(tasks(3)) do
                queue:add(task)
            end
            queue:drain()
        end)
        world.run()
        assert.are.same({ false, false, false }, nested)
        assert.are.equal(3, #world.placed)
    end)

    it('passes an error raised while placing on to the owner and can be pumped again', function()
        local world = newWorld()
        local env = world.env()
        local deliver = env.deliver
        local raised = false
        env.deliver = function(task, data, problem)
            if task.id == 1 and not raised then
                raised = true
                error('disk on fire')
            end
            deliver(task, data, problem)
        end
        local queue = DownloadQueue.new(env, { concurrency = 1 })
        local first, second
        world.spawn('owner', function()
            queue:add({ id = 1 })
            queue:add({ id = 2 })
            first = { copcall(queue.drain, queue) }
            second = queue:drain()
        end)
        world.run()
        assert.is_false(first[1])
        assert.matches('disk on fire', first[2])
        assert.is_true(second)
        assert.are.same({ 2 }, placedIds(world))
    end)

    it('lists every task when stopped before anything ran', function()
        local world = newWorld()
        local queue = DownloadQueue.new(world.env({ startTask = function() end }), { concurrency = 2 })
        local list = tasks(3)
        for _, task in ipairs(list) do
            queue:add(task)
        end
        assert.are.same(list, queue:stop())
        assert.is_true(queue:isIdle())
    end)
end)
