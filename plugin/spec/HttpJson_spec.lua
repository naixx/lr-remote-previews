-- Find the plug-in's modules relative to this file, whatever the current directory.
local here = debug.getinfo(1, 'S').source:match('^@(.-)[^/\\]*$') or ''
package.path = here .. '../LRRemotePreviews.lrplugin/?.lua;' .. package.path

local HttpJson = require 'HttpJson'

describe('HttpJson.headers', function()
    it('adds the content type for a JSON body and the token when set', function()
        local accept = { field = 'Accept', value = 'application/json' }
        local json = { field = 'Content-Type', value = 'application/json' }
        assert.are.same({ accept }, HttpJson.headers(nil))
        assert.are.same({ accept, json }, HttpJson.headers('  ', true))
        assert.are.same({ accept, json, { field = 'Authorization', value = 'Bearer t0k' } },
            HttpJson.headers(' t0k ', true))
    end)
end)

describe('HttpJson.errorInfo', function()
    it('reads detail and code', function()
        assert.are.same({ detail = 'No converter', code = 'converter_not_installed' },
            HttpJson.errorInfo('{"detail": "No converter", "code": "converter_not_installed"}'))
        assert.are.same({ detail = 'x' }, HttpJson.errorInfo('{"detail": "x"}'))
        assert.are.same({}, HttpJson.errorInfo('<html>'))
        assert.are.same({}, HttpJson.errorInfo(nil))
        assert.are.equal(303, #HttpJson.errorInfo('{"detail": "' .. string.rep('a', 400) .. '"}').detail)
    end)
end)

describe('HttpJson.problem', function()
    it('accepts 2xx answers', function()
        assert.is_nil(HttpJson.problem('{}', 200))
        assert.is_nil(HttpJson.problem('{}', '201'))
        assert.is_nil(HttpJson.problem('{}', nil))
    end)

    it('classifies failures', function()
        assert.are.equal('unreachable', HttpJson.problem(nil, nil, 'cannotConnectToHost').kind)
        assert.are.equal('unreachable', HttpJson.problem(nil, nil, nil).kind)
        local token = HttpJson.problem('{"detail": "Invalid token"}', 401, nil, true)
        assert.are.equal('unauthorized', token.kind)
        assert.matches('did not accept', token.message)
        assert.matches('Invalid token', token.message)
        assert.matches('needs an access token', HttpJson.problem('', 401, nil, false).message)
        local conflict = HttpJson.problem('{"detail": "No converter", "code": "converter_not_installed"}', 409)
        assert.are.same({ kind = 'http', status = 409, code = 'converter_not_installed',
            message = 'The server answered HTTP 409. Server says: No converter' }, conflict)
    end)
end)

describe('HttpJson.decode', function()
    it('returns the decoded object and the status', function()
        local decoded, status = HttpJson.decode('{"job": {"id": 7}}', 201)
        assert.are.same({ job = { id = 7 } }, decoded)
        assert.are.equal(201, status)
    end)

    it('reports bodies that are not a JSON object', function()
        for _, body in ipairs({ '', '  ', '<html>', '[1, 2]', '"text"' }) do
            local decoded, problem = HttpJson.decode(body, 200)
            assert.is_nil(decoded)
            assert.are.equal('badJson', problem.kind)
        end
        local _, problem = HttpJson.decode('{"a": 1', 200)
        assert.is_nil(problem.message:find('Json.lua', 1, true))
    end)

    it('passes HTTP problems through', function()
        local decoded, problem = HttpJson.decode('{"detail": "Not Found"}', 404)
        assert.is_nil(decoded)
        assert.are.equal(404, problem.status)
    end)
end)
