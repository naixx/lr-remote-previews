-- A lock that lets only one task of the plug-in at a time fetch and place smart previews (a manual fetch, the
-- automatic fetch, or the automatic send while it talks to the server). It lives in a key-value
-- store that every script of the plug-in reaches (Lightroom's preferences for the plug-in), as the text
-- "<owner>|<expiry time>|<label>". The holder refreshes it while it works; a lock left behind by a task that
-- ended without releasing it (Lightroom closed in the middle of a fetch) expires Lease.TTL seconds after its last
-- refresh.
--
-- Lightroom runs the tasks of a plug-in one at a time and switches between them only where a task waits (network,
-- sleep, a dialog), so reading and writing the store with no wait in between cannot interleave with another task.
-- Pure Lua 5.1: the store and the clock (seconds) are passed in.
local Lease = {}

Lease.KEY = 'fetchLease'
Lease.TTL = 180 -- seconds a lock lasts without a refresh
Lease.REFRESH_AFTER = 30 -- a refresh writes the store only when the lock is at least this old

-- The lock in the store: { owner, expires, label }, or nil when there is none (or it is unreadable).
function Lease.read(store)
    local value = store[Lease.KEY]
    if type(value) ~= 'string' then
        return nil
    end
    local owner, expires, label = value:match('^([^|]+)|(%d+)|(.*)$')
    if not owner then
        return nil
    end
    return { owner = owner, expires = tonumber(expires), label = label }
end

local function write(store, owner, label, now)
    store[Lease.KEY] = owner .. '|' .. string.format('%d', math.floor(now + Lease.TTL)) .. '|' .. (label or '')
end

-- True while a lock is in force. A lock never lasts more than Lease.TTL seconds from now; one that claims to (the
-- computer's clock was set back, or the value is damaged) is taken as stale, so it cannot block fetching for long.
local function inForce(lock, now)
    return lock.expires > now and lock.expires <= now + Lease.TTL
end

-- Takes the lock for owner (a text without '|', unique per run) when it is free, expired or stale.
-- Returns true, or false plus the current holder { owner, expires, label }.
function Lease.acquire(store, owner, label, now)
    local current = Lease.read(store)
    if current and current.owner ~= owner and inForce(current, now) then
        return false, current
    end
    write(store, owner, label, now)
    return true
end

-- Keeps the lock alive. Returns true while owner holds it, false when it was lost (expired and taken by another
-- task, or released by someone else).
function Lease.refresh(store, owner, now)
    local current = Lease.read(store)
    if not current or current.owner ~= owner then
        return false
    end
    if current.expires - now <= Lease.TTL - Lease.REFRESH_AFTER then
        write(store, owner, current.label, now)
    end
    return true
end

-- Gives the lock up, if owner holds it.
function Lease.release(store, owner)
    local current = Lease.read(store)
    if current and current.owner == owner then
        store[Lease.KEY] = nil
    end
end

-- The message for a command that found the lock taken. holder: from Lease.acquire.
function Lease.busyText(holder, now)
    local minutes = math.max(1, math.ceil((holder.expires - now) / 60))
    local label = (holder.label ~= nil and holder.label ~= '') and holder.label or 'another task of this plug-in'
    return string.format('Smart previews are already being fetched by %s. Try again when it has finished.\n\n'
        .. 'If Lightroom was closed in the middle of a fetch, the lock it left frees itself within %d minute%s.',
        label, minutes, minutes == 1 and '' or 's')
end

return Lease
