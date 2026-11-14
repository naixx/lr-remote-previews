-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local Json = require 'Json'
local ServerInfo = require 'ServerInfo'

-- The example from the server contract.
local CONTRACT = [[
{"name": "LR Remote Previews", "version": "0.1.0", "api": 1, "auth": "token",
 "converter": {"installed": false,
               "path": "C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe",
               "version": null},
 "roots": [{"id": "archive", "label": "Archive", "available": true}],
 "capabilities": {"extensions": [".arw", ".cr2"], "previewLongEdge": 2560}}
]]

local function decoded(text)
    return Json.decode(text)
end

describe('ServerInfo.normalize', function()
    it('accepts the contract example', function()
        assert.are.same({
            name = 'LR Remote Previews',
            version = '0.1.0',
            api = 1,
            apiSupported = true,
            auth = 'token',
            converter = {
                installed = false,
                path = 'C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe',
            },
            roots = { { id = 'archive', label = 'Archive', available = true } },
            capabilities = { extensions = { '.arw', '.cr2' }, previewLongEdge = 2560, appendItems = false },
        }, ServerInfo.normalize(decoded(CONTRACT)))
    end)

    it('fills in defaults for optional fields', function()
        local info = ServerInfo.normalize({ name = 'LR Remote Previews', version = '0.1.0', api = 1 })
        assert.are.equal('unknown', info.auth)
        assert.are.same({ installed = false }, info.converter)
        assert.are.same({}, info.roots)
        assert.are.same({ extensions = {}, appendItems = false }, info.capabilities)
    end)

    it('defaults a root label to its id and availability to false', function()
        local info = ServerInfo.normalize(decoded('{"name": "x", "version": "1", "api": 1, "roots": [{"id": "a"}]}'))
        assert.are.same({ { id = 'a', label = 'a', available = false } }, info.roots)
    end)

    it('lower-cases extensions and ignores unknown fields', function()
        local info = ServerInfo.normalize(decoded(
            '{"name": "x", "version": "1", "api": 1, "future": {"a": 1}, "capabilities": {"extensions": [".NEF"]}}'))
        assert.are.same({ '.nef' }, info.capabilities.extensions)
        assert.is_nil(info.future)
    end)

    it('reads the most items per job', function()
        local info = ServerInfo.normalize(decoded(
            '{"name": "x", "version": "0.2.0", "api": 1, "capabilities": {"maxItemsPerJob": 5000}}'))
        assert.are.equal(5000, info.capabilities.maxItemsPerJob)
        assert.is_nil(ServerInfo.normalize(decoded(
            '{"name": "x", "version": "1", "api": 1, "capabilities": {"maxItemsPerJob": "many"}}')))
    end)

    it('reads how long the server keeps finished jobs', function()
        local info = ServerInfo.normalize(decoded(
            '{"name": "x", "version": "0.3.0", "api": 1, "capabilities": {"jobRetentionDays": 30}}'))
        assert.are.equal(30, info.capabilities.jobRetentionDays)
        assert.is_nil(ServerInfo.normalize(decoded('{"name": "x", "version": "0.2.0", "api": 1}'))
            .capabilities.jobRetentionDays)
        assert.is_nil(ServerInfo.normalize(decoded(
            '{"name": "x", "version": "1", "api": 1, "capabilities": {"jobRetentionDays": "30"}}')))
    end)

    it('flags an API version it does not speak', function()
        local info = ServerInfo.normalize({ name = 'x', version = '9', api = 2 })
        assert.is_false(info.apiSupported)
    end)

    it('rejects missing or mistyped fields with a message naming the field', function()
        local cases = {
            { '{"version": "1", "api": 1}', 'name' },
            { '{"name": "", "version": "1", "api": 1}', 'name' },
            { '{"name": "x", "api": 1}', 'version' },
            { '{"name": "x", "version": "1", "api": "1"}', 'api' },
            { '{"name": "x", "version": "1"}', 'api' },
            { '{"name": "x", "version": "1", "api": 1, "auth": 5}', 'auth' },
            { '{"name": "x", "version": "1", "api": 1, "converter": "yes"}', 'converter' },
            { '{"name": "x", "version": "1", "api": 1, "converter": {"installed": "yes"}}', 'converter.installed' },
            { '{"name": "x", "version": "1", "api": 1, "roots": {"id": "a"}}', 'roots' },
            { '{"name": "x", "version": "1", "api": 1, "roots": [{"label": "A"}]}', 'roots%[1%]%.id' },
            { '{"name": "x", "version": "1", "api": 1, "roots": ["a"]}', 'roots%[1%]' },
            { '{"name": "x", "version": "1", "api": 1, "roots": [{"id": "a", "available": 1}]}', 'available' },
            { '{"name": "x", "version": "1", "api": 1, "capabilities": {"extensions": [1]}}', 'extensions' },
            { '{"name": "x", "version": "1", "api": 1, "capabilities": {"previewLongEdge": "2560"}}', 'LongEdge' },
        }
        for _, case in ipairs(cases) do
            local info, message = ServerInfo.normalize(decoded(case[1]))
            assert.is_nil(info)
            assert.matches(case[2], message)
        end
    end)

    it('rejects something that is not an object', function()
        assert.is_nil(ServerInfo.normalize(nil))
        assert.is_nil(ServerInfo.normalize('text'))
        assert.is_nil(ServerInfo.normalize(decoded('[1, 2]')))
    end)
end)

describe('ServerInfo.fromHttpResponse', function()
    it('returns the info for a 200 answer', function()
        local info, problem = ServerInfo.fromHttpResponse(CONTRACT, 200, nil, true)
        assert.is_nil(problem)
        assert.are.equal('0.1.0', info.version)
        assert.are.equal('archive', info.roots[1].id)
    end)

    it('accepts the status as a string', function()
        assert.is_not_nil(ServerInfo.fromHttpResponse(CONTRACT, '200', nil, false))
    end)

    it('reports a network error as unreachable', function()
        local info, problem = ServerInfo.fromHttpResponse(nil, nil, 'cannotConnectToHost', false)
        assert.is_nil(info)
        assert.are.equal('unreachable', problem.kind)
        assert.matches('cannotConnectToHost', problem.message)
        assert.are.equal('unreachable', select(2, ServerInfo.fromHttpResponse(nil, nil, nil, false)).kind)
    end)

    it('reports 401 with the server detail when a token was sent', function()
        local info, problem = ServerInfo.fromHttpResponse('{"detail": "Invalid token"}', 401, nil, true)
        assert.is_nil(info)
        assert.are.equal('unauthorized', problem.kind)
        assert.are.equal(401, problem.status)
        assert.matches('did not accept', problem.message)
        assert.matches('Invalid token', problem.message)
    end)

    it('asks for a token on 401 when none was sent', function()
        local _, problem = ServerInfo.fromHttpResponse('{"detail": "Missing token"}', 401, nil, false)
        assert.are.equal('unauthorized', problem.kind)
        assert.matches('needs an access token', problem.message)
    end)

    it('copes with a 401 whose body is not JSON', function()
        local _, problem = ServerInfo.fromHttpResponse('<html>401</html>', 401, nil, true)
        assert.are.equal('unauthorized', problem.kind)
        local _, empty = ServerInfo.fromHttpResponse(nil, 401, nil, true)
        assert.are.equal('unauthorized', empty.kind)
    end)

    it('reports other HTTP errors', function()
        local _, problem = ServerInfo.fromHttpResponse('{"detail": "boom"}', 500, nil, true)
        assert.are.equal('http', problem.kind)
        assert.are.equal(500, problem.status)
        assert.matches('500', problem.message)
        assert.matches('boom', problem.message)
        local _, notFound = ServerInfo.fromHttpResponse('Not Found', 404, nil, true)
        assert.are.equal('http', notFound.kind)
        assert.matches('LR Remote Previews server', notFound.message)
    end)

    it('reports an answer that is not JSON', function()
        local _, problem = ServerInfo.fromHttpResponse('<html>router login</html>', 200, nil, false)
        assert.are.equal('badJson', problem.kind)
        assert.matches("(unexpected character '<' at line 1 col 1)", problem.message, 1, true)
        assert.is_nil(problem.message:find('Json.lua', 1, true))
        assert.are.equal('badJson', select(2, ServerInfo.fromHttpResponse('', 200, nil, false)).kind)
        assert.are.equal('badJson', select(2, ServerInfo.fromHttpResponse('  \n', 200, nil, false)).kind)
    end)

    it('reports JSON that is not an info document', function()
        local _, problem = ServerInfo.fromHttpResponse('{"name": 1}', 200, nil, false)
        assert.are.equal('badInfo', problem.kind)
        assert.matches('name', problem.message)
    end)
end)

describe('ServerInfo request helpers', function()
    it('normalises the server URL', function()
        assert.are.equal('http://nas.local:8787', ServerInfo.baseUrl('  http://nas.local:8787/  '))
        assert.are.equal('https://example.org/lrrp', ServerInfo.baseUrl('https://example.org/lrrp//'))
        assert.are.equal('HTTP://NAS:8787', ServerInfo.baseUrl('HTTP://NAS:8787'))
        assert.are.equal('http://nas.local:8787/api/v1/info', ServerInfo.infoUrl('http://nas.local:8787/'))
    end)

    it('rejects a missing or malformed server URL', function()
        local cases = { nil, '', '   ', 'nas.local:8787', 'ftp://nas', 'http://', 'http:///x', 'http://nas local',
            'http://nas/?a=1', 'http://nas/#top' }
        for i = 1, 10 do
            local url, message = ServerInfo.infoUrl(cases[i])
            assert.is_nil(url)
            assert.is_string(message)
        end
    end)

    it('adds a bearer token only when one is set', function()
        local accept = { field = 'Accept', value = 'application/json' }
        assert.are.same({ accept }, ServerInfo.requestHeaders(nil))
        assert.are.same({ accept }, ServerInfo.requestHeaders('   '))
        assert.are.same({ accept, { field = 'Authorization', value = 'Bearer s3cret' } },
            ServerInfo.requestHeaders(' s3cret '))
    end)
end)

describe('ServerInfo text', function()
    local info = ServerInfo.normalize(decoded(CONTRACT))

    it('summarises the server in one line', function()
        assert.are.equal('LR Remote Previews 0.1.0, converter not installed, 1 root', ServerInfo.summary(info))
    end)

    it('writes the status report', function()
        local text = ServerInfo.formatReport(info, { serverUrl = ' http://nas.local:8787/ ' })
        assert.matches('LR Remote Previews 0.1.0', text, 1, true)
        assert.matches('Address: http://nas.local:8787', text, 1, true)
        assert.matches('Access: access token required', text, 1, true)
        assert.matches('Adobe DNG Converter: not installed', text, 1, true)
        assert.matches('Converter path: C:\\Program Files', text, 1, true)
        assert.matches('archive (Archive): available', text, 1, true)
        assert.is_nil(text:find('Path mapping', 1, true))
    end)

    it('shows an installed converter with its version', function()
        local installed = ServerInfo.normalize({ name = 'x', version = '1', api = 1,
            converter = { installed = true, version = '17.0' } })
        assert.matches('Adobe DNG Converter: installed, version 17.0', ServerInfo.formatReport(installed), 1, true)
    end)

    it('says whether the mapped root is on the server', function()
        local found = ServerInfo.formatReport(info, { localPrefix = 'Z:\\', rootId = 'archive' })
        assert.matches('Path mapping: Z:\\ -> archive (available)', found, 1, true)
        local missing = ServerInfo.formatReport(info, { localPrefix = 'Z:\\', rootId = 'other' })
        assert.matches('(not on this server)', missing, 1, true)
    end)

    it('lists every path mapping with the state of its root', function()
        local offline = ServerInfo.normalize({ name = 'x', version = '1', api = 1,
            roots = { { id = 'archive', available = true }, { id = 'offline', available = false } } })
        local text = ServerInfo.formatReport(offline, { mappings = {
            { localPrefix = 'Z:\\', rootId = 'archive' },
            { localPrefix = 'Y:\\', rootId = 'offline' },
            { localPrefix = '/Volumes/P', rootId = 'gone' },
        } })
        assert.matches('Path mapping: Z:\\ -> archive (available)\n'
            .. 'Path mapping: Y:\\ -> offline (on this server but not available)\n'
            .. 'Path mapping: /Volumes/P -> gone (not on this server)', text, 1, true)
        assert.is_nil(ServerInfo.formatReport(offline, { mappings = {} }):find('Path mapping', 1, true))
    end)

    it('warns about an API version it does not speak', function()
        local newer = ServerInfo.normalize({ name = 'x', version = '9', api = 2 })
        assert.matches('this plug-in speaks API 1', ServerInfo.formatReport(newer), 1, true)
        assert.matches('Roots: none', ServerInfo.formatReport(newer), 1, true)
    end)

    it('names each problem kind briefly', function()
        assert.are.equal('server not reachable', ServerInfo.shortProblem({ kind = 'unreachable' }))
        assert.are.equal('HTTP error 500', ServerInfo.shortProblem({ kind = 'http', status = 500 }))
    end)
end)
