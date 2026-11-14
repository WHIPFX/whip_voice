-- Voice bots: a recording heard on a line as if someone on it were talking. A lore character phoning a player is a
-- call line whose other end is a bot: the voice bot service (installed by the setup wizard) joins the voice room under
-- an identity of its own and plays a recording into the line, so a phone on speaker and the people near it work as for
-- any call.
--
-- A bot is a line member keyed 'bot:<n>' that only talks: never a listener, never heard by the people near anyone,
-- never picked up by a speakerphone. server/hearing.lua gives bots to the line pass only; its allow list goes to the
-- service instead of a player's game.
--
--   exports.whip_voice:CreateVoiceBot({ name, audio })        -> botKey, durationMs | false, why  (WAITS)
--       audio: a recording's link (the voice bot's accepted sites, Fivemanage by default), or an mp3/ogg/wav file a
--       started resource ships, "@my_story/audio/line.ogg" (never downloaded by players)
--   exports.whip_voice:PutVoiceBotOnLine(botKey, lineId)       -> true | false, why
--   exports.whip_voice:PlayVoiceBot(botKey, onDone)            -> durationMs | false, why  (WAITS)
--       onDone(botKey, why): 'done' (played to the end), 'removed', 'lineClosed', 'failed'
--   exports.whip_voice:RemoveVoiceBot(botKey)                  -> true
--   exports.whip_voice:VoiceBotStatus()                        -> { ok, calls, max, version } | false, why  (WAITS)
--
-- Create before the phone rings (the recording is fetched and checked then), put it on the line once answered, play.
-- A bot belongs to the resource that made it and goes when that resource stops.
--
-- A world voice is a bot heard in the world, from an entity (a lore character's ped), as a player's voice is: within
-- its range, at the ped's head, through walls and rooms and cars, with its mouth moving. It only talks. It stays (one
-- connection, any number of recordings) until let go:
--
--   exports.whip_voice:CreateWorldVoice({ name, at = { netId = n }, range })   -> key | false, why   (WAITS)
--   exports.whip_voice:PlayWorldVoice(key, audio, onDone)                         -> durationMs | false, why  (WAITS)
--       a new line while one plays cuts it off (onDone 'cut'); else onDone(key, 'done' | 'removed' | 'failed')
--   exports.whip_voice:MoveWorldVoice(key, { netId = n })                        -> true | false, why
--   exports.whip_voice:SetWorldVoiceRange(key, range, fullWithin)                -> true | false, why
--       how far it carries (2-300 m), and how far out it is still at full volume (nil: the usual, a metre)
--   exports.whip_voice:RemoveWorldVoice(key)                                      -> true
--
-- server.cfg: whip_voicebot_token (set, never setr: a shared secret with the service), whip_voicebot_url
-- (default http://127.0.0.1:7899). The setup wizard writes both.

VoiceBots = { byKey = {} }

local RESOURCE = GetCurrentResourceName()
local count = 0

local function say(fmt, ...) print(('[whip_voice] voice bot: ' .. fmt):format(...)) end

local function serviceUrl() return (GetConvar('whip_voicebot_url', 'http://127.0.0.1:7899'):gsub('/+$', '')) end
local function serviceToken() return GetConvar('whip_voicebot_token', '') end

--- The voice room's address for the service, on this machine (the API's, as ws://).
local function roomUrl()
    local api = GetConvar('whip_voice_api', 'http://127.0.0.1:7880'):gsub('/+$', '')
    return (api:gsub('^http', 'ws'))
end

--- A request to the service: status, the answer's table (or nil). Only inside a thread or handler (it waits).
local function request(method, path, body)
    local token = serviceToken()
    if token == '' then return 0, { ok = false, error = 'whip_voicebot_token is not set in server.cfg (the setup wizard writes it)' } end
    local p = promise.new()
    PerformHttpRequest(serviceUrl() .. path, function(status, text)
        local ok, data = pcall(json.decode, text or '')
        p:resolve({ status, ok and type(data) == 'table' and data or nil })
    end, method, body and json.encode(body) or '', { ['Content-Type'] = 'application/json', Authorization = 'Bearer ' .. token })
    local r = Citizen.Await(p)
    return r[1], r[2]
end

--- The same, sent and not waited for (an allow list, a removal).
local function send(method, path, body)
    local token = serviceToken()
    if token == '' then return end
    PerformHttpRequest(serviceUrl() .. path, function() end, method, body and json.encode(body) or '',
        { ['Content-Type'] = 'application/json', Authorization = 'Bearer ' .. token })
end

local function why(status, data)
    if status == 0 then return (data and data.error) or 'the voice bot service is not running (whip_voice setup: the voice bot step)' end
    return (data and data.error) or ('the voice bot service answered ' .. tostring(status))
end

-- ============================================
-- For server/hearing.lua and server/lines.lua
-- ============================================

function VoiceBots.count()
    local n = 0
    for _ in pairs(VoiceBots.byKey) do n = n + 1 end
    return n
end

--- The bots on lines, as the line pass reads talkers: no position, no bucket, never a listener.
function VoiceBots.talkers(players)
    local out = {}
    for i = 1, #players do out[i] = players[i] end
    for key, b in pairs(VoiceBots.byKey) do
        if b.lineId then
            out[#out + 1] = { src = key, bot = true, speaks = true, bucket = -1, x = 0.0, y = 0.0, z = 0.0, range = 0 }
        end
    end
    return out
end

--- Everyone the proximity pass works with: the players, and every world voice where its entity is now (a speaker
--- only: `bot`, so it never listens). A world voice whose entity is not there (despawned, out of scope of the
--- server) is left out, and everyone hearing it lets go as of a player gone.
function VoiceBots.inWorld(players)
    local out
    for key, b in pairs(VoiceBots.byKey) do
        local w = b.world
        local ent = w and w.netId and NetworkGetEntityFromNetworkId(w.netId) or 0
        if ent ~= 0 and DoesEntityExist(ent) then
            if not out then out = {}; for i = 1, #players do out[i] = players[i] end end
            local c = GetEntityCoords(ent)
            out[#out + 1] = { src = key, bot = true, speaks = true, bucket = GetEntityRoutingBucket(ent),
                              x = c.x, y = c.y, z = c.z, range = w.range }
        end
    end
    return out or players
end

--- A world voice as a listener's game is told of it: where it comes from (the entity's network id), how far it
--- carries, and how far out it is still at full volume (`full`, only when set: html/js/audio.js fade). nil for a bot
--- that is not one.
function VoiceBots.worldEntry(key)
    local b = VoiceBots.byKey[key]
    if not (b and b.world) then return nil end
    return { id = b.identity, ent = b.world.netId, range = b.world.range, full = b.world.full }
end

--- The identity a bot is heard by, or nil.
function VoiceBots.identityOf(key)
    local b = VoiceBots.byKey[key]
    return b and b.identity or nil
end

--- Who may hear a bot now (identities): told to the service (hearing.lua sends only changes).
function VoiceBots.allow(key, identities)
    local b = VoiceBots.byKey[key]
    if not b then return end
    send('POST', '/calls/' .. b.identity .. '/allow', { allow = identities })
end

--- Let go of a bot: off its line, out of the voice room, its owner told why.
function VoiceBots.remove(key, reason)
    local b = VoiceBots.byKey[key]
    if not b then return end
    VoiceBots.byKey[key] = nil
    -- Its owner hears why, in a thread of its own. Its line's end (it closes when the bot leaves it, just below) is
    -- told at the same moment, in no set order: an owner that tells the two apart waits a moment on the line's.
    if b.onDone then
        local fn, r = b.onDone, reason or 'removed'
        b.onDone = nil
        CreateThread(function()
            local ok, err = pcall(fn, key, r)
            if not ok then say('^1%s\'s onDone failed: %s^0', b.owner, tostring(err)) end
        end)
    end
    -- Off its line as any member leaves it (too few left and the line closes: a call ends).
    if b.lineId and Lines.byId[b.lineId] and Lines.byId[b.lineId].members[key] then Lines.leave(b.lineId, key, reason or 'removed') end
    if Hearing then Hearing.drop(key, b.identity) end
    send('DELETE', '/calls/' .. b.identity)
end

-- ============================================
-- What the exports do
-- ============================================

--- A recording a resource ships, "@my_story/audio/line.ogg": the file's full path for the voice bot (which reads
--- it: Lua's LoadResourceFile stops at the first zero byte, and audio has them). nil and why when it is not one.
function VoiceBots.resourceFile(audio)
    local res, path = audio:match('^@([%w_%-%.]+)/([%w%-%._/]+)$')
    if not res or path:find('..', 1, true) then return nil, 'a resource\'s recording is "@resource/folder/file.ogg"' end
    local ext = (path:match('%.(%w+)$') or ''):lower()
    if ext ~= 'mp3' and ext ~= 'ogg' and ext ~= 'wav' then return nil, 'only mp3, ogg and wav files are played' end
    if GetResourceState(res) ~= 'started' then return nil, ('the resource %s is not started'):format(res) end
    local root = GetResourcePath(res)
    if type(root) ~= 'string' or root == '' then return nil, ('the resource %s has no folder'):format(res) end
    return (root:gsub('[\\/]+$', '')) .. '/' .. path
end

--- A recording as the voice bot service takes it: a link as it is, a resource's file as "file:<full path>". nil and
--- why when it is neither.
function VoiceBots.audioOf(audio)
    if type(audio) ~= 'string' or audio == '' or #audio > 255 then return nil, 'audio is a recording\'s link, or "@resource/file.ogg"' end
    if audio:sub(1, 1) == '@' then
        local file, fwhy = VoiceBots.resourceFile(audio)
        if not file then return nil, fwhy end
        return 'file:' .. file
    end
    return audio
end

--- Join the voice room and get the recording ready. Answers botKey, durationMs, or nil and why.
--- spec.world = { netId, range }: a world voice (no recording yet: each play brings one).
function VoiceBots.create(owner, spec)
    if not Voice.room then return nil, 'voice is still starting' end
    local name = type(spec.name) == 'string' and spec.name:sub(1, 80) or 'Caller'
    local audio, awhy
    if not spec.world then
        audio, awhy = VoiceBots.audioOf(spec.audio)
        if not audio then return nil, awhy end
    end
    local identity = Voice.randomId()
    if not identity then return nil, 'could not make an identity' end
    -- Like a player's pass, but it may only talk: a microphone, nothing to hear, no data.
    local token = VoiceToken.sign({ sub = identity, name = name, video = {
        room = Voice.room, roomJoin = true, canPublish = true, canPublishSources = { 'microphone' },
        canSubscribe = false, canPublishData = false } }, 600)
    if not token then return nil, 'server.cfg has no whip_voice_key / whip_voice_secret' end
    local ok, rwhy = Voice.ensureRoom()
    if not ok then return nil, rwhy end
    -- Past the service's cap the call waits its turn, a few seconds at most.
    local deadline = GetGameTimer() + math.floor((tonumber(Config.VoiceBot and Config.VoiceBot.WaitSeconds) or 5) * 1000)
    local status, data
    repeat
        status, data = request('POST', '/calls', { id = identity, url = roomUrl(), token = token, audio = audio, allow = {},
                                                   keep = spec.world ~= nil })
        if status ~= 429 then break end
        Wait(500)
    until GetGameTimer() > deadline
    if status ~= 200 or not (data and data.ok) then
        return nil, status == 429 and 'every voice bot line is in use' or why(status, data)
    end
    count = count + 1
    local key = 'bot:' .. count
    VoiceBots.byKey[key] = { key = key, identity = identity, name = name, owner = owner, duration = tonumber(data.duration) or 0,
                             made = GetGameTimer(), world = spec.world, plays = 0 }
    -- A world voice is heard by proximity: the pass must be running (one player and a bot is enough).
    if spec.world and Hearing then Hearing.wake() end
    return key, VoiceBots.byKey[key].duration
end

--- A world voice says a recording: fetched and played by the service, at the entity. Answers its length;
--- onDone(key, 'done' | 'cut' | 'removed' | 'failed') hears when it ended. The voice stays for the next one.
function VoiceBots.say(key, audio, onDone)
    local b = VoiceBots.byKey[key]
    if not (b and b.world) then return nil, 'no such world voice' end
    local a, awhy = VoiceBots.audioOf(audio)
    if not a then return nil, awhy end
    -- A line still playing is cut off: its owner hears so (the new one has the voice now).
    if b.onDone then
        local fn = b.onDone
        b.onDone = nil
        CreateThread(function() pcall(fn, key, 'cut') end)
    end
    b.plays = b.plays + 1
    local mine = b.plays
    local status, data = request('POST', '/calls/' .. b.identity .. '/play', { audio = a })
    if status ~= 200 or not (data and data.ok) then return nil, why(status, data) end
    local duration = tonumber(data.duration) or 0
    -- Another line asked for meanwhile (the request waits on the service), or the voice gone: this one is over as it
    -- starts, and its owner hears so. Kept only while it is still the voice's last.
    if VoiceBots.byKey[key] ~= b or b.plays ~= mine then
        local how = VoiceBots.byKey[key] ~= b and 'removed' or 'cut'
        if onDone then CreateThread(function() pcall(onDone, key, how) end) end
        return duration
    end
    b.onDone = onDone
    -- Asked how far it got until it is done (it waits up to 3 s for a listener first, then plays).
    CreateThread(function()
        local limit = GetGameTimer() + duration + 15000
        Wait(math.max(300, duration))
        while VoiceBots.byKey[key] == b and b.plays == mine and GetGameTimer() < limit do
            local s, d = request('GET', '/calls/' .. b.identity)
            local state = s == 200 and d and d.state or 'gone'
            if state ~= 'playing' then break end
            Wait(300)
        end
        if VoiceBots.byKey[key] == b and b.plays == mine and b.onDone then
            local fn = b.onDone
            b.onDone = nil
            local ok, err = pcall(fn, key, 'done')
            if not ok then say('^1%s\'s onDone failed: %s^0', b.owner, tostring(err)) end
        end
    end)
    return duration
end

--- Put a bot on a line (its members hear it from now; it plays when told).
function VoiceBots.join(key, lineId)
    local b = VoiceBots.byKey[key]
    if not b then return false, 'no such voice bot' end
    local line = Lines.byId[lineId]
    if not line then return false, 'no such line' end
    if b.lineId and b.lineId ~= lineId then return false, 'it is on another line' end
    b.lineId = lineId
    line.members[key] = { speaker = false, muted = false }
    Lines.ofPlayer[key] = Lines.ofPlayer[key] or {}
    Lines.ofPlayer[key][lineId] = true
    if Hearing then Hearing.wake() end
    return true
end

--- Play it. Answers its length; onDone hears when it has finished (or why it stopped).
function VoiceBots.play(key, onDone)
    local b = VoiceBots.byKey[key]
    if not b then return nil, 'no such voice bot' end
    b.onDone = onDone
    local status, data = request('POST', '/calls/' .. b.identity .. '/play')
    if status ~= 200 then
        VoiceBots.remove(key, 'failed')
        return nil, why(status, data)
    end
    -- Asked how far it got until it is done: it waits up to 3 s for its listener first, then plays.
    CreateThread(function()
        local limit = GetGameTimer() + b.duration + 15000
        Wait(math.max(500, b.duration))
        while VoiceBots.byKey[key] == b and GetGameTimer() < limit do
            local s, d = request('GET', '/calls/' .. b.identity)
            local state = s == 200 and d and d.state or 'gone'
            if state == 'done' or state == 'gone' then break end
            Wait(500)
        end
        if VoiceBots.byKey[key] == b then VoiceBots.remove(key, 'done') end
    end)
    return b.duration
end

-- ============================================
-- Exports
-- ============================================

local function isFuncRef(v) return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil end

local function mine(owner, key)
    local b = type(key) == 'string' and VoiceBots.byKey[key] or nil
    if not b then return nil, 'no such voice bot (gone?)' end
    if b.owner ~= owner then return nil, 'that voice bot is not yours' end
    return b
end

exports('CreateVoiceBot', function(spec)
    local owner = GetInvokingResource()
    if not owner or owner == RESOURCE then return false, 'call it from another resource' end
    if type(spec) ~= 'table' or isFuncRef(spec) then return false, 'a voice bot is { name, audio }' end
    local key, d = VoiceBots.create(owner, { name = rawget(spec, 'name'), audio = rawget(spec, 'audio') })
    if not key then return false, d end
    return key, d
end)

exports('PutVoiceBotOnLine', function(key, lineId)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    local line = type(lineId) == 'string' and Lines.byId[lineId] or nil
    if not line or line.owner ~= owner then return false, 'no such line of yours' end
    return VoiceBots.join(key, lineId)
end)

exports('PlayVoiceBot', function(key, onDone)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    ---@cast owner -nil   -- the bot's owner, so a resource
    if onDone ~= nil and type(onDone) ~= 'function' and not isFuncRef(onDone) then return false, 'onDone is a function' end
    local cb = onDone and function(...) if GetResourceState(owner) == 'started' then onDone(...) end end or nil
    local d, pw = VoiceBots.play(key, cb)
    if not d then return false, pw end
    return d
end)

exports('RemoveVoiceBot', function(key)
    local owner = GetInvokingResource()
    if type(key) ~= 'string' or not VoiceBots.byKey[key] then return true end
    local b, w = mine(owner, key)
    if not b then return false, w end
    VoiceBots.remove(key, 'removed')
    return true
end)

-- ---- World voices --------------------------------------------------------------------------------

local WORLD_MAX_RANGE = 300.0   -- a lore character's line with its card's Bonus range (250 m) on its own 50

--- A world voice's range (2 to WORLD_MAX_RANGE m), and its full-volume circle (nil: the usual; else up to its range).
local function reachOf(range, full)
    range = math.max(2.0, math.min(WORLD_MAX_RANGE, tonumber(range) or 12.0))
    full = tonumber(full)
    full = full and full > 0 and math.min(full, range) or nil
    return range, full
end

--- `at` as a world voice takes it: { netId } of an entity that exists now. nil and why.
local function worldAt(at, range, full)
    if type(at) ~= 'table' or isFuncRef(at) then return nil, 'at is { netId = n } (the entity the voice comes from)' end
    local netId = math.tointeger(tonumber(rawget(at, 'netId')))
    if not netId or netId <= 0 then return nil, 'at is { netId = n } (the entity the voice comes from)' end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent == 0 or not DoesEntityExist(ent) then return nil, 'no entity with that netId' end
    range, full = reachOf(range, full)
    return { netId = netId, range = range, full = full }
end

exports('CreateWorldVoice', function(spec)
    local owner = GetInvokingResource()
    if not owner or owner == RESOURCE then return false, 'call it from another resource' end
    if type(spec) ~= 'table' or isFuncRef(spec) then return false, 'a world voice is { name, at = { netId }, range }' end
    local world, w = worldAt(rawget(spec, 'at'), rawget(spec, 'range'))
    if not world then return false, w end
    local key, d = VoiceBots.create(owner, { name = rawget(spec, 'name'), world = world })
    if not key then return false, d end
    return key
end)

exports('PlayWorldVoice', function(key, audio, onDone)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    ---@cast owner -nil   -- the bot's owner, so a resource
    if not b.world then return false, 'that voice bot is on a line, not in the world (PlayVoiceBot)' end
    if onDone ~= nil and type(onDone) ~= 'function' and not isFuncRef(onDone) then return false, 'onDone is a function' end
    local cb = onDone and function(...) if GetResourceState(owner) == 'started' then onDone(...) end end or nil
    local d, pw = VoiceBots.say(key, audio, cb)
    if not d then return false, pw end
    return d
end)

exports('MoveWorldVoice', function(key, at)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    if not b.world then return false, 'that voice bot is on a line, not in the world' end
    local world, ww = worldAt(at, b.world.range, b.world.full)
    if not world then return false, ww end
    b.world = world
    return true
end)

exports('SetWorldVoiceRange', function(key, range, full)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    if not b.world then return false, 'that voice bot is on a line, not in the world' end
    if tonumber(range) == nil then return false, 'range is a number of metres' end
    b.world.range, b.world.full = reachOf(range, full)
    -- (Those hearing it now: the new edge at once. Those it now reaches: the next pass connects them.)
    if Hearing and Hearing.rangeChanged then Hearing.rangeChanged(key) end
    return true
end)

exports('RemoveWorldVoice', function(key)
    local owner = GetInvokingResource()
    if type(key) ~= 'string' or not VoiceBots.byKey[key] then return true end
    local b, w = mine(owner, key)
    if not b then return false, w end
    VoiceBots.remove(key, 'removed')
    return true
end)

exports('VoiceBotStatus', function()
    local status, data = request('GET', '/health')
    if status ~= 200 or not data then return false, why(status, data) end
    return data
end)

-- A resource stopping: its bots go (no callbacks: its functions are gone). whip_voice stopping: all of them.
AddEventHandler('onResourceStop', function(res)
    for key, b in pairs(VoiceBots.byKey) do
        if res == RESOURCE or b.owner == res then
            b.onDone = nil
            VoiceBots.remove(key, 'removed')
        end
    end
end)
