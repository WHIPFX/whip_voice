-- Talking to the voice server (LiveKit). The FiveM server manages it over its HTTP API: it makes the room everyone
-- joins and removes players who leave. It never carries audio; players' games send their voices straight to the
-- voice server.
--
--   VoiceServer.call(method, body, cb)   one API call; cb(ok, reply | why)
--   VoiceServer.token(claims, ttl)       a signed token (server/token.lua)
--   VoiceServer.check(cb)                is the voice server there, and do our keys work?
--
-- Settings, all in server.cfg (see config.lua):
--   whip_voice_url      where players' games connect:  wss://<this server's IP>, or wss://voice.your-domain.com
--   whip_voice_key      the API key                    (from install.ps1)
--   whip_voice_secret   the API secret                 (from install.ps1)
--   whip_voice_api      where this server reaches it   (default http://127.0.0.1:7880; set it only if the voice
--                       server runs somewhere else)

VoiceServer = {}

local API =GetConvar('whip_voice_api', 'http://127.0.0.1:7880'):gsub('/+$', '')

--- The players' address, the API address, and whether the key and secret are set.
function VoiceServer.settings()
    return {
        url    = GetConvar('whip_voice_url', ''),
        api    = API,
        key    = GetConvar('whip_voice_key', '') ~= '',
        secret = #GetConvar('whip_voice_secret', ''),
    }
end

--- A signed token, or nil when the key or secret is missing from server.cfg.
---@param claims table  { sub = identity, video = { grants } }
---@param ttl number    seconds
---@return string|nil
function VoiceServer.token(claims, ttl)
    local ok, token = pcall(VoiceToken.sign, claims, ttl)
    if ok and type(token) == 'string' and token ~= '' then return token end
    if not ok then print(('[whip_voice] could not sign a token: %s'):format(tostring(token))) end
    return nil
end

-- One admin token per room, reused until a minute before it runs out (they last ten minutes).
local _admin = {}   -- [room or ''] = { token, untilAt }

local function adminToken(room)
    local k = room or ''
    local cached = _admin[k]
    if cached and os.time() < cached.untilAt - 60 then return cached.token end
    local token = VoiceServer.token({ video = { roomAdmin = true, roomCreate = true, roomList = true, room = room } }, 600)
    if token then _admin[k] = { token = token, untilAt = os.time() + 600 } end
    return token
end

--- What an HTTP failure means, in words a server owner can act on.
local function explain(status, text)
    if status == 0 then
        return ('the voice server is not answering at %s — is the "LiveKit" Windows service running?'):format(API)
    elseif status == 401 then
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
        cb(false, 'whip_voice_key / whip_voice_secret are not set in server.cfg')
        return
    end
    -- An empty Lua table would encode as "[]"; the API wants an object.
    local payload = (body and next(body)) and json.encode(body) or '{}'
    PerformHttpRequest(API .. '/twirp/livekit.RoomService/' .. method, function(status, text)
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
    local s = VoiceServer.settings()
    if s.url == '' then return cb(false, 'whip_voice_url is not set in server.cfg (see whip_voice\\config.lua)') end
    if not s.url:match('^wss://') then return cb(false, ('whip_voice_url must start with wss:// (players\' games only allow secure connections), not "%s"'):format(s.url)) end
    if not s.key then return cb(false, 'whip_voice_key is not set in server.cfg') end
    if s.secret < 32 then return cb(false, 'whip_voice_secret is missing or too short (the installer makes a 48-character one)') end
    VoiceServer.call('ListRooms', nil, function(ok, reply)
        if ok then cb(true, ('voice server OK (players connect to %s)'):format(s.url)) else cb(false, reply) end
    end)
end
