-- Text for the plug-in's own dialogs. Pure Lua 5.1.
--
-- An LrView static_text without a width grows to its longest line, so a long text made a dialog as wide as the screen.
-- TextWrap.wrap breaks the text into lines of at most WIDTH characters at spaces (a static_text shows each line of its
-- title on a line of its own). It keeps the text's line breaks and blank lines, and the indentation of a line, which
-- its continuation lines get too. keep: strings (a folder, a path) that are not broken at their spaces. A line is
-- longer than the limit only when it is one word (or one kept string) that is longer; it then stands alone, without the
-- indentation. Characters are counted as UTF-8 characters, not bytes.
--
-- TextWrap.shortPath shortens a path for a message (the beginning and the end stay); the full path goes to the log.
local TextWrap = {}

TextWrap.WIDTH = 90 -- characters per line in the plug-in's dialogs

local GLUE = '\1' -- stands for a space that must not break while the text is wrapped

-- The number of UTF-8 characters in s.
function TextWrap.length(s)
    return select(2, s:gsub('[^\128-\191]', ''))
end

local length = TextWrap.length

local function glue(text, keep)
    for _, piece in ipairs(keep or {}) do
        if type(piece) == 'string' and piece:find(' ', 1, true) then
            local glued = piece:gsub(' ', GLUE)
            local out, from = {}, 1
            while true do
                local i, j = text:find(piece, from, true)
                if not i then
                    break
                end
                out[#out + 1] = text:sub(from, i - 1)
                out[#out + 1] = glued
                from = j + 1
            end
            out[#out + 1] = text:sub(from)
            text = table.concat(out)
        end
    end
    return text
end

local function wrapLine(line, width, out)
    if length(line) <= width then
        out[#out + 1] = line
        return
    end
    local indent, rest = line:match('^(%s*)(.-)%s*$')
    local current, size
    local function start(word)
        if length(indent) + length(word) <= width then
            current, size = indent .. word, length(indent) + length(word)
        else
            current, size = word, length(word) -- one word longer than the line: alone, without the indentation
        end
    end
    for word in rest:gmatch('%S+') do
        if current == nil then
            start(word)
        elseif size + 1 + length(word) <= width then
            current, size = current .. ' ' .. word, size + 1 + length(word)
        else
            out[#out + 1] = current
            start(word)
        end
    end
    out[#out + 1] = current or ''
end

-- text broken into lines of at most width (default WIDTH) characters; keep: strings not to break (optional).
function TextWrap.wrap(text, width, keep)
    width = width or TextWrap.WIDTH
    local out = {}
    local glued = glue(tostring(text or ''), keep)
    for line in (glued .. '\n'):gmatch('(.-)\r?\n') do
        wrapLine(line, width, out)
    end
    return (table.concat(out, '\n'):gsub(GLUE, ' '))
end

-- path shortened to at most max characters (default 60) by leaving out folders in the middle:
-- 'C:\Users\someone\AppData\Local\Temp\x\report.txt' -> 'C:\…\Temp\x\report.txt'. The last part stays whole.
function TextWrap.shortPath(path, max)
    path = tostring(path or '')
    max = max or 60
    if length(path) <= max then
        return path
    end
    local separator = path:match('[/\\]') or '\\'
    local parts = {}
    for part in path:gmatch('[^/\\]+') do
        parts[#parts + 1] = part
    end
    local lead = path:match('^[/\\]+') or ''
    local head = lead .. (parts[1] or '')
    local tail = parts[#parts] or path
    local i = #parts - 1
    while i > 1 and length(head) + length(tail) + length(parts[i]) + 5 <= max do
        tail = parts[i] .. separator .. tail
        i = i - 1
    end
    if #parts <= 1 then
        return path
    end
    return head .. separator .. '…' .. separator .. tail
end

return TextWrap
