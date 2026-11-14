-- The plug-in's clientId (docs/protocol.md, "The job object"): a random string in the form of a UUID that the
-- plug-in makes up once per catalog and sends with every job, so that it can find that catalog's jobs on the
-- server again. It is not a Lightroom identifier. Pure Lua 5.1: the sources of randomness are passed in.
--
-- The generator is a Park-Miller "minimal standard" generator (multiplier 48271, modulus 2^31 - 1), exact in
-- Lua's double-precision numbers. Its seed mixes the time, the processor clock, a counter and the catalog path, so
-- two catalogs or two runs are very unlikely to get the same id; it only has to avoid collisions, not be secret.
local ClientId = {}

local MODULUS = 2147483647
local MULTIPLIER = 48271

local UUID_PATTERN = '^' .. string.rep('%x', 8) .. '%-' .. string.rep('%x', 4) .. '%-' .. string.rep('%x', 4)
    .. '%-' .. string.rep('%x', 4) .. '%-' .. string.rep('%x', 12) .. '$'

-- A number in [0, MODULUS) from a text (a simple polynomial hash).
function ClientId.hash(text)
    local h = 0
    text = tostring(text or '')
    for i = 1, #text do
        h = (h * 31 + text:byte(i)) % MODULUS
    end
    return h
end

-- A generator function returning numbers in [0, 1), seeded from the given numbers and texts.
function ClientId.newRandom(...)
    local seed = 0
    for i = 1, select('#', ...) do
        local part = select(i, ...)
        local value = type(part) == 'number' and math.floor(math.abs(part)) % MODULUS or ClientId.hash(part)
        seed = (seed * 131 + value) % MODULUS
    end
    if seed == 0 then
        seed = 1
    end
    local state = seed
    -- Warm up, so that close seeds drift apart.
    for _ = 1, 8 do
        state = (state * MULTIPLIER) % MODULUS
    end
    return function()
        state = (state * MULTIPLIER) % MODULUS
        return state / MODULUS
    end
end

-- A new id: 32 lower-case hex digits as 8-4-4-4-12, with the version and variant bits of a random UUID.
-- random: a function returning numbers in [0, 1).
function ClientId.generate(random)
    local digits = {}
    for i = 1, 32 do
        digits[i] = math.floor(random() * 16) % 16
    end
    digits[13] = 4 -- version 4
    digits[17] = 8 + digits[17] % 4 -- variant 10xx
    local hex = {}
    for i, digit in ipairs(digits) do
        hex[i] = string.format('%x', digit)
    end
    local text = table.concat(hex)
    return text:sub(1, 8) .. '-' .. text:sub(9, 12) .. '-' .. text:sub(13, 16) .. '-' .. text:sub(17, 20) .. '-'
        .. text:sub(21, 32)
end

-- True for a string this module could have made (any 8-4-4-4-12 hex string).
function ClientId.isValid(id)
    return type(id) == 'string' and id:match(UUID_PATTERN) ~= nil
end

return ClientId
