-- Talking to the voice server (LiveKit). The FiveM server manages it over its HTTP API: it makes the room everyone
-- joins and removes players who leave. It never carries audio; players' games send their voices straight to the
-- voice server.
--
--   VoiceServer.call(method, body, cb)   one API call; cb(ok, reply | why)
--   VoiceServer.token(claims, ttl)       a signed token (server/token.lua)
--   VoiceServer.credentials()            the key and secret tokens are signed with ('' when there are none yet)
--   VoiceServer.playerUrl()              where players' games are told to connect
--   VoiceServer.check(cb)                is the voice server there, and do our keys work?
--
-- TWO WAYS (docs/SETUP.md):
--   THE BUILT-IN VOICE SERVER (no whip_voice_url in server.cfg): whip_voice runs LiveKit itself, with keys of its own
--   (server/builtin.js, server/builtin.lua). Nothing to set up but the voice ports.
--   YOUR OWN VOICE SERVER: these in server.cfg (the setup wizard, service\install.ps1, writes them):
--     whip_voice_url      where players' games connect:  wss://<this server's IP>, or wss://voice.your-domain.com
--     whip_voice_key      the API key
--     whip_voice_secret   the API secret
--     whip_voice_api      where this server reaches it   (default http://127.0.0.1:7880; set it only if the voice
--                         server runs somewhere else)

VoiceServer = {}

local OWN_API = GetConvar('whip_voice_api', 'http://127.0.0.1:7880'):gsub('/+$', '')

--- Where this server reaches the voice server's API.
local function api()
    if VoiceBuiltin.on then return VoiceBuiltin.state.api or OWN_API end
    return OWN_API
end

--- The key and secret tokens are signed with: the built-in voice server's, or server.cfg's.
---@return string key
---@return string secret
function VoiceServer.credentials()
    if VoiceBuiltin.on then
        local s = VoiceBuiltin.state
        return type(s.key) == 'string' and s.key or '', type(s.secret) == 'string' and s.secret or ''
    end
    return GetConvar('whip_voice_key', ''), GetConvar('whip_voice_secret', '')
end

--- Where players' games are told to connect.
---@return string
function VoiceServer.playerUrl()
    if VoiceBuiltin.on then return VoiceBuiltin.URL end
    return GetConvar('whip_voice_url', '')
end

--- Which way, the players' address, the API address, and whether the key and secret are set.
function VoiceServer.settings()
    local key, secret = VoiceServer.credentials()
    return {
        builtin = VoiceBuiltin.on,
        url     = VoiceServer.playerUrl(),
        api     = api(),
        key     = key ~= '',
        secret  = #secret,
    }
end

--- A signed token, or nil when there is no key or secret yet.
---@param claims table  { sub = identity, video = { grants } }
---@param ttl number    seconds
---@return string|nil
function VoiceServer.token(claims, ttl)
    local ok, token = pcall(VoiceToken.sign, claims, ttl)
    if ok and type(token) == 'string' and token ~= '' then return token end
    if not ok then print(('[whip_voice] could not sign a token: %s'):format(tostring(token))) end
    return nil
end

-- One admin token per room, reused until a minute before it runs out (they last ten minutes), or until the key
-- changes (the built-in voice server has new keys every time whip_voice starts).
local _admin = {}   -- [room or ''] = { token, untilAt, key }

local function adminToken(room)
    local k = room or ''
    local key = VoiceServer.credentials()
    local cached = _admin[k]
    if cached and cached.key == key and os.time() < cached.untilAt - 60 then return cached.token end
    local token = VoiceServer.token({ video = { roomAdmin = true, roomCreate = true, roomList = true, room = room } }, 600)
    if token then _admin[k] = { token = token, untilAt = os.time() + 600, key = key } end
    return token
end

--- What an HTTP failure means, in words a server owner can act on.
local function explain(status, text)
    if status == 0 then
        if VoiceBuiltin.on then
            return VoiceBuiltin.why()
                or ('the built-in voice server is not answering at %s (whip_voice/bin/logs/livekit.log says why)'):format(api())
        end
        return ('the voice server is not answering at %s — is the "LiveKit" Windows service running?'):format(api())
    elseif status == 401 then
        if VoiceBuiltin.on then return 'the built-in voice server refused our key: restart whip_voice' end
        return 'the voice server refused our key — whip_voice_key / whip_voice_secret in server.cfg do not match C:\\LiveKit\\config.yaml'
    end
    local ok, body = pcall(json.decode, text or '')
    local msg = (ok and type(body) == 'table' and (body.msg or body.code)) or tostring(text or '')
    return ('the voice server answered %s: %s'):format(tostring(status), msg:sub(1, 200))
end

--- Call the voice server's room API.
---@param method string  RoomService method: CreateRoom, DeleteRoom, ListRooms, ListParticipants, ...
---@param body table|nil the request (snake_case field names)
---@param cb fun(ok: boolean, reply: table|string)|nil  reply is the decoded answer, or why it failed
function VoiceServer.call(method, body, cb)
    cb = cb or function() end
    local token = adminToken(body and body.room)
    if not token then
        if VoiceBuiltin.on then cb(false, VoiceBuiltin.why() or 'the built-in voice server has no keys yet')
        else cb(false, 'whip_voice_key / whip_voice_secret are not set in server.cfg') end
        return
    end
    -- An empty Lua table would encode as "[]"; the API wants an object.
    local payload = (body and next(body)) and json.encode(body) or '{}'
    PerformHttpRequest(api() .. '/twirp/livekit.RoomService/' .. method, function(status, text)
        if status == 200 then
            local ok, reply = pcall(json.decode, text or '{}')
            cb(true, ok and type(reply) == 'table' and reply or {})
        else
            cb(false, explain(status, text))
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json', ['Authorization'] = 'Bearer ' .. token })
end

--- Is everything in place? cb(ok, why) — why is the one line to print.
function VoiceServer.check(cb)
    if VoiceBuiltin.on then
        if not VoiceBuiltin.ready() then return cb(false, VoiceBuiltin.why()) end
        return VoiceServer.call('ListRooms', nil, function(ok, reply)
            if not ok then return cb(false, reply) end
            cb(true, ('built-in voice server OK (LiveKit %s; players\' games send voices to %s)')
                :format(tostring(VoiceBuiltin.state.version), VoiceBuiltin.ports()))
        end)
    end
    local s = VoiceServer.settings()
    if s.url == '' then return cb(false, 'whip_voice_url is not set in server.cfg (see whip_voice\\config.lua)') end
    if not s.url:match('^wss://') then return cb(false, ('whip_voice_url must start with wss:// (players\' games only allow secure connections), not "%s"'):format(s.url)) end
    if not s.key then return cb(false, 'whip_voice_key is not set in server.cfg') end
    if s.secret < 32 then return cb(false, 'whip_voice_secret is missing or too short (the installer makes a 48-character one)') end
    VoiceServer.call('ListRooms', nil, function(ok, reply)
        if ok then cb(true, ('voice server OK (players connect to %s)'):format(s.url)) else cb(false, reply) end
    end)
end
