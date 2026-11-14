-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local ImportPlan = require 'ImportPlan'
local ServerInfo = require 'ServerInfo'
local StatusReport = require 'StatusReport'
local TextWrap = require 'TextWrap'

local function lines(text)
    local list = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
        list[#list + 1] = line
    end
    return list
end

-- Every line fits, or is one word on its own.
local function fits(text, width)
    for _, line in ipairs(lines(text)) do
        if TextWrap.length(line) > width and line:find(' ', 1, true) then
            return false, line
        end
    end
    return true
end

local LONG = 'The plug-in\'s automatic send (the same setting as in the Plug-in Manager) sends new raw photos to the '
    .. 'server in the background, round by round, while Lightroom imports.'

describe('TextWrap', function()
    it('leaves short lines, line breaks and blank lines as they are', function()
        local text = 'One line.\n\n    Indented: short.\nLast line.'
        assert.are.equal(text, TextWrap.wrap(text, 90))
        assert.are.equal('', TextWrap.wrap('', 90))
    end)

    it('breaks a long line at spaces into lines of at most the width, losing no word', function()
        local wrapped = TextWrap.wrap(LONG, 40)
        assert.is_true(#lines(wrapped) > 2)
        for _, line in ipairs(lines(wrapped)) do
            assert.is_true(TextWrap.length(line) <= 40, line)
        end
        assert.are.equal(LONG, (wrapped:gsub('\n', ' ')))
        assert.are.same({ 'aaa bbb', 'ccc' }, lines(TextWrap.wrap('aaa bbb ccc', 7)))
    end)

    it('gives continuation lines the indentation of their line', function()
        local wrapped = lines(TextWrap.wrap('    Build Smart Previews: ON. Lightroom builds them itself, reading every '
            .. 'original over the network.', 40))
        assert.is_true(#wrapped >= 3)
        for _, line in ipairs(wrapped) do
            assert.are.equal('    ', line:sub(1, 4))
            assert.are_not.equal(' ', line:sub(5, 5))
        end
    end)

    it('does not break a kept path at its spaces', function()
        local folder = 'D:\\Photos\\2026\\2026.06.20 - wedding of the year'
        local text = 'Lightroom will import ' .. folder .. ' with the settings of the previous import.'
        local plain = TextWrap.wrap(text, 40)
        local kept = TextWrap.wrap(text, 40, { folder })
        assert.is_nil(plain:find(folder, 1, true))
        assert.is_truthy(kept:find(folder, 1, true))
        assert.is_true((fits(kept:gsub(folder:gsub('[%p]', '%%%0'), 'X'), 40)))
    end)

    it('puts a word longer than the line on a line of its own; every other line fits', function()
        local path = 'C:\\Users\\someone\\AppData\\Local\\Temp\\LRRemotePreviews\\'
            .. 'a-very-long-file-name-without-spaces.txt'
        local wrapped = lines(TextWrap.wrap('    The report was written to ' .. path .. ' just now, have a look.', 40))
        local alone = 0
        for _, line in ipairs(wrapped) do
            if line == path then
                alone = alone + 1
            else
                assert.is_true(TextWrap.length(line) <= 40, line)
            end
        end
        assert.are.equal(1, alone)
    end)

    it('counts characters, not bytes', function()
        assert.are.equal(3, TextWrap.length('«a»'))
        local text = string.rep('«é» ', 20)
        for _, line in ipairs(lines(TextWrap.wrap(text, 12))) do
            assert.is_true(TextWrap.length(line) <= 12)
            assert.is_true(#line > 12) -- more bytes than characters: counted as characters
        end
    end)

    it('wraps the import confirmation and the status report to the dialog width', function()
        local folder = 'Z:\\Archive\\2026\\2026.06.20 - a shoot with a rather long folder name, as people write them'
        local verdict = { ok = true, previewCode = 'bthm', smartPreviews = true, presets = { 'develop settings',
            'a metadata preset' } }
        local confirmation = TextWrap.wrap(ImportPlan.dialogText(folder, verdict), TextWrap.WIDTH, { folder })
        assert.is_true(fits(confirmation:gsub(folder:gsub('[%p]', '%%%0'), 'X'), TextWrap.WIDTH))
        assert.is_truthy(confirmation:find(folder, 1, true))
        assert.is_true(fits(TextWrap.wrap(ImportPlan.autoSendNote(nil)), TextWrap.WIDTH))
        local info = { name = 'LR Remote Previews', version = '0.6.0', api = 1, apiSupported = true, auth = 'token',
            converter = { installed = true, version = '17.2', path = 'C:\\Program Files\\Adobe\\Adobe DNG Converter\\'
                .. 'Adobe DNG Converter.exe' }, roots = { { id = 'archive', label = 'Archive', available = true } } }
        local report = ServerInfo.formatReport(info, { serverUrl = 'http://nas.example:8787',
            mappings = { { localPrefix = 'Z:\\', rootId = 'archive' } } }) .. '\n\n'
            .. StatusReport.jobsText({ clientId = 'c', jobs = {}, now = 0, listed = 0, waiting = 3, unregistered = 12 })
        assert.is_true(fits(TextWrap.wrap(report), TextWrap.WIDTH))
    end)

    it('shortens a long path in the middle and keeps its end', function()
        assert.are.equal('C:\\short\\path.txt', TextWrap.shortPath('C:\\short\\path.txt', 60))
        local long = 'C:\\Users\\someone\\AppData\\Local\\Temp\\LRRemotePreviews\\run-12\\smart-preview-report.txt'
        local short = TextWrap.shortPath(long, 50)
        assert.is_true(TextWrap.length(short) <= 50, short)
        assert.are.equal('C:\\…\\', short:sub(1, 7)) -- … is three bytes
        assert.are.equal('run-12\\smart-preview-report.txt', short:sub(-31))
        assert.are.equal('/usr/…/sqlite3', TextWrap.shortPath('/usr/local/very/deep/folder/' .. string.rep('x', 40)
            .. '/sqlite3', 20))
        assert.are.equal('//nas/…/file.dng', TextWrap.shortPath('//nas/photos/one/two/three/four/file.dng', 18))
    end)
end)
