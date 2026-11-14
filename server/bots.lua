-- Voice bots: a recording heard on a line as if someone on it were talking. A lore character phoning a player is a
-- call line whose other end is a bot: the voice bot service (the built-in voice server's, or the setup wizard's) joins the voice room under
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
--   exports.whip_voice:CreateWorldVoice({ name, at, range, bucket })   -> key | false, why   (WAITS)
--       at: where it comes from. One place, or a list of up to 32 (a room full of speakers: one sound, heard from
--       every one of them, in step). A place is { netId = n } (an entity, followed as it moves) or
--       { coords = vector3, model = hash|name } (a fixed spot; with the model of the object standing there, that
--       object's walls and room are used, as each game finds its own copy of it). bucket: the routing bucket of
--       fixed spots (default 0).
--   exports.whip_voice:PlayWorldVoice(key, audio, onDone, opts)                   -> durationMs | false, why  (WAITS)
--       a new line while one plays cuts it off (onDone 'cut'); else onDone(key, 'done' | 'stopped' | 'removed' | 'failed')
--       opts: { loop = true (until StopWorldVoice), music = true (a song: the voice bot's musicSeconds / musicBytes,
--       not a line's limits), fadeIn = ms (from silence at its start) }
--   exports.whip_voice:StopWorldVoice(key, fadeMs)                               -> true | false, why
--       stops what it plays, at once or faded down over fadeMs first (onDone 'stopped')
--   exports.whip_voice:SetWorldVoiceSound(key, recipe | false)                   -> true | false, why
--       how it sounds to everyone hearing it: a sound recipe (shared/sound_blocks.lua: a cheap speaker, a robot), or
--       false for its plain voice. A megaphone up sounds as a megaphone instead.
--   exports.whip_voice:MoveWorldVoice(key, at)                                    -> true | false, why
--   exports.whip_voice:SetWorldVoiceRange(key, range, fullWithin)                -> true | false, why
--       how far it carries (2-300 m), and how far out it is still at full volume (nil: the usual, a metre)
--   exports.whip_voice:SetWorldVoiceMegaphone(key, on)                            -> true | false, why
--       a megaphone up (Config.Megaphone: its range times rangeMultiplier, the bullhorn sound), or down
--   exports.whip_voice:SetWorldVoiceRadio(key, frequency | false)                  -> true | false, why
--       on a radio frequency (as a player's radio item: everyone on it hears what it says, breaking up with distance
--       from its entity), or off it. The people near it still hear it in the world.
--   exports.whip_voice:RemoveWorldVoice(key)                                      -> true
--
-- The built-in voice server (server/builtin.js) sets up and starts the service itself, with a token of its own. With
-- your own voice server, server.cfg: whip_voicebot_token (set, never setr: a shared secret with the service),
-- whip_voicebot_url (default http://127.0.0.1:7899). The setup wizard writes both.

VoiceBots = { byKey = {} }

local RESOURCE = GetCurrentResourceName()
local count = 0

local function say(fmt, ...) print(('[whip_voice] voice bot: ' .. fmt):format(...)) end

-- The built-in voice server's bot (server/builtin.js starts it, with a token of its own every start), or the setup
-- wizard's (server.cfg).
local function serviceUrl()
    if VoiceBuiltin.on then return (VoiceBuiltin.bot()) or 'http://127.0.0.1:7899' end
    return (GetConvar('whip_voicebot_url', 'http://127.0.0.1:7899'):gsub('/+$', ''))
end
local function serviceToken()
    if VoiceBuiltin.on then
        local url, token = VoiceBuiltin.bot()
        return url and token or ''
    end
    return GetConvar('whip_voicebot_token', '')
end

--- Why there is no voice bot to ask, in words.
local function noBot()
    if VoiceBuiltin.on then return VoiceBuiltin.botWhy() end
    return 'whip_voicebot_token is not set in server.cfg (the setup wizard writes it)'
end

--- The voice room's address for the service, on this machine (the API's, as ws://).
local function roomUrl()
    local api = VoiceServer.settings().api
    return (api:gsub('^http', 'ws'))
end

--- A request to the service: status, the answer's table (or nil). Only inside a thread or handler (it waits).
local function request(method, path, body)
    local token = serviceToken()
    if token == '' then return 0, { ok = false, error = noBot() } end
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
    if status == 0 then
        return (data and data.error) or (VoiceBuiltin.on and VoiceBuiltin.botWhy())
            or 'the voice bot service is not running (whip_voice setup: the voice bot step)'
    end
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

--- The bots on lines, as the line pass reads talkers: never a listener. A call's bot is nowhere (no distance, no world
--- rule); a world voice on a radio frequency talks from its entity (`placed`), so the radio breaks up with distance
--- and only its own world hears it, as for a player. One whose entity is not there (despawned, out of the server's
--- scope) is nowhere to talk from: off the air until it is back, never heard everywhere.
--- Where a world voice's places are now: { x, y, z, bucket } for each that is there (an entity despawned or out of the
--- server's scope is left out; a fixed spot is always there).
local function placesNow(w)
    local out = {}
    for _, p in ipairs(w.points) do
        if p.netId then
            local ent = NetworkGetEntityFromNetworkId(p.netId)
            if ent ~= 0 and DoesEntityExist(ent) then
                local c = GetEntityCoords(ent)
                out[#out + 1] = { x = c.x, y = c.y, z = c.z, bucket = GetEntityRoutingBucket(ent) }
            end
        else
            out[#out + 1] = { x = p.x, y = p.y, z = p.z, bucket = w.bucket or 0 }
        end
    end
    return out
end

--- The one point who hears it is worked out from: the middle of its places, and how far the furthest place is from
--- it (added to its range, so everyone near any of them is connected; each game then hears each place by its own
--- distance). nil when none of its places is there.
local function middleOf(w)
    local pts = placesNow(w)
    if #pts == 0 then return nil end
    if #pts == 1 then return pts[1], 0 end
    local x, y, z = 0.0, 0.0, 0.0
    for _, p in ipairs(pts) do x, y, z = x + p.x, y + p.y, z + p.z end
    x, y, z = x / #pts, y / #pts, z / #pts
    local spread = 0.0
    for _, p in ipairs(pts) do
        local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2 + (p.z - z) ^ 2)
        if d > spread then spread = d end
    end
    return { x = x, y = y, z = z, bucket = pts[1].bucket }, spread
end

function VoiceBots.talkers(players)
    local out = {}
    for i = 1, #players do out[i] = players[i] end
    for key, b in pairs(VoiceBots.byKey) do
        if b.lineId then
            local t = { src = key, bot = true, speaks = true, bucket = -1, x = 0.0, y = 0.0, z = 0.0, range = 0 }
            if b.world then
                local m = middleOf(b.world)
                if m then
                    t.placed, t.bucket, t.x, t.y, t.z = true, m.bucket, m.x, m.y, m.z
                    out[#out + 1] = t
                end
            else
                out[#out + 1] = t
            end
        end
    end
    return out
end

--- How far a world voice carries now: its range, times the megaphone's while one is up.
local function worldRange(w)
    if w.megaphone and Megaphone then return w.range * Megaphone.multiplier() end
    return w.range
end

--- Everyone the proximity pass works with: the players, and every world voice where it is now (a speaker only: `bot`,
--- so it never listens). A world voice none of whose places is there (its entity despawned, out of scope of the
--- server) is left out, and everyone hearing it lets go as of a player gone.
function VoiceBots.inWorld(players)
    local out
    for key, b in pairs(VoiceBots.byKey) do
        local w = b.world
        local m, spread = nil, 0
        if w then m, spread = middleOf(w) end
        if m then
            if not out then out = {}; for i = 1, #players do out[i] = players[i] end end
            out[#out + 1] = { src = key, bot = true, speaks = true, bucket = m.bucket,
                              x = m.x, y = m.y, z = m.z, range = worldRange(w) + spread }
        end
    end
    return out or players
end

--- How a world voice sounds: the megaphone while one is up, else its own recipe (SetWorldVoiceSound), else plain.
local function fxOf(w)
    if w.megaphone then return 'megaphone' end
    return w.sound
end

--- A world voice as a listener's game is told of it: where it comes from (`ent`, one entity's network id; or `pts`,
--- its places: { ent = netId, off?, model? } — `off` a spot on that entity, where an object of `model` rides it — or
--- { at = { x, y, z }, model }), how far it carries, how far out it is still at full volume (`full`, only when set:
--- html/js/audio.js fade), its sound (`fx`: 'megaphone' or a recipe), and `mu` when it is music (heard as from far off:
--- late by its distance, the Doppler effect, the air's treble; html/js/audio.js setSpace). nil for a bot that is not one.
function VoiceBots.worldEntry(key)
    local b = VoiceBots.byKey[key]
    if not (b and b.world) then return nil end
    local w = b.world
    local e = { id = b.identity, range = worldRange(w), full = w.full, fx = fxOf(w), mu = w.music or nil }
    if #w.points == 1 and w.points[1].netId and not w.points[1].off then
        e.ent = w.points[1].netId
    else
        e.pts = {}
        for i, p in ipairs(w.points) do
            if p.netId then e.pts[i] = { ent = p.netId, off = p.off, model = p.off and p.model or nil }
            else e.pts[i] = { at = { p.x, p.y, p.z }, model = p.model } end
        end
    end
    return e
end

--- The identity a bot is heard by, or nil.
function VoiceBots.identityOf(key)
    local b = VoiceBots.byKey[key]
    return b and b.identity or nil
end

--- Who may hear a bot now (identities), and who its radio track (a world voice on a frequency): told to the service
--- (hearing.lua sends only changes).
function VoiceBots.allow(key, identities, radio)
    local b = VoiceBots.byKey[key]
    if not b then return end
    send('POST', '/calls/' .. b.identity .. '/allow', { allow = identities, radio = radio or {} })
end

--- Let go of every bot (their voice room or the voice bot service is gone: they are in neither any more).
function VoiceBots.removeAll(reason)
    local keys = {}
    for key in pairs(VoiceBots.byKey) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do VoiceBots.remove(key, reason) end
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
    if not token then return nil, VoiceBuiltin.on and (VoiceBuiltin.why() or 'no voice keys yet') or 'server.cfg has no whip_voice_key / whip_voice_secret' end
    local ok, rwhy = Voice.ensureRoom()
    if not ok then return nil, rwhy end
    -- Past the service's cap the call waits its turn, a few seconds at most.
    local deadline = GetGameTimer() + math.floor((tonumber(Config.VoiceBot and Config.VoiceBot.WaitSeconds) or 5) * 1000)
    local status, data
    repeat
        -- A world voice can go on a radio frequency: it sends a 'radio' track too, as a player's microphone does.
        status, data = request('POST', '/calls', { id = identity, url = roomUrl(), token = token, audio = audio, allow = {},
                                                   keep = spec.world ~= nil, radio = spec.world ~= nil })
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

--- A world voice says a recording: fetched and played by the service, at its places. Answers its length;
--- onDone(key, 'done' | 'stopped' | 'cut' | 'removed' | 'failed') hears when it ended. The voice stays for the next one.
--- opts: { loop (until stopped), music (a song's limits, not a line's), fadeIn (ms) }.
function VoiceBots.say(key, audio, onDone, opts)
    opts = type(opts) == 'table' and opts or {}
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
    b.stopping = nil
    local mine = b.plays
    local loop = opts.loop == true
    local status, data = request('POST', '/calls/' .. b.identity .. '/play', { audio = a, loop = loop or nil,
        music = opts.music == true or nil, fadeIn = math.max(0, math.min(30000, math.floor(tonumber(opts.fadeIn) or 0))) })
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
    -- Asked how far it got until it is done (it waits up to 3 s for a listener first, then plays). A loop plays until
    -- it is stopped, so it is asked about with no end in sight, and less often (a song is long).
    CreateThread(function()
        local limit = loop and math.huge or (GetGameTimer() + duration + 15000)
        local every = (loop or duration > 30000) and 1000 or 300
        Wait(loop and 1000 or math.max(300, duration))
        while VoiceBots.byKey[key] == b and b.plays == mine and GetGameTimer() < limit do
            local s, d = request('GET', '/calls/' .. b.identity)
            local state = s == 200 and d and d.state or 'gone'
            if state ~= 'playing' then break end
            Wait(every)
        end
        if VoiceBots.byKey[key] == b and b.plays == mine and b.onDone then
            local fn = b.onDone
            b.onDone = nil
            local ok, err = pcall(fn, key, b.stopping and 'stopped' or 'done')
            if not ok then say('^1%s\'s onDone failed: %s^0', b.owner, tostring(err)) end
        end
    end)
    return duration
end

--- Stop what a world voice plays: at once, or faded down over fadeMs (the service fades it, so everyone hearing it
--- hears the same fade). Its onDone hears 'stopped'. true, or false and why.
function VoiceBots.stop(key, fadeMs)
    local b = VoiceBots.byKey[key]
    if not (b and b.world) then return false, 'no such world voice' end
    if not b.onDone then return true end   -- nothing playing
    b.stopping = true
    local status, data = request('POST', '/calls/' .. b.identity .. '/stop',
        { fade = math.max(0, math.min(30000, math.floor(tonumber(fadeMs) or 0))) })
    if status == 404 and not (data and data.error == 'no such call') then
        b.stopping = nil
        return false, 'the voice bot is older than 1.5.0 and cannot stop a recording: run the voice setup again'
    end
    if status ~= 200 then b.stopping = nil; return false, why(status, data) end
    return true
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

--- A world voice on a radio frequency (server/radio.lua's line for it), off the one it was on; freq nil: off the radio.
function VoiceBots.setRadio(key, freq)
    local b = VoiceBots.byKey[key]
    if not (b and b.world) then return false, 'no such world voice' end
    if freq ~= nil and b.radio == freq then return true end
    if freq ~= nil then
        local okF, fwhy = Radio.validFrequency(freq)
        if not okF then return false, fwhy end
    end
    if b.lineId then
        local was = b.lineId
        b.lineId, b.radio = nil, nil
        if Lines.byId[was] and Lines.byId[was].members[key] then Lines.leave(was, key, 'off') end
    end
    if freq == nil then return true end
    local ok, jwhy = VoiceBots.join(key, Radio.lineFor(freq))
    if not ok then return false, jwhy end
    b.radio = freq
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

local MAX_PLACES = 32   -- places one world voice comes from (a room or a stage full of speakers)
local AT_HELP = 'at is { netId = n, offset?, model? }, { coords = vector3, model? }, or a list of them'
local MAX_OFFSET = 10.0 -- metres a place may be from the entity it rides

--- A number from a vector3 or a table, by name or by place: { x, y, z } and { x = .., y = .., z = .. } both.
local function coordOf(c, name, i)
    local ok, v = pcall(function() return c[name] or c[i] end)
    v = ok and tonumber(v) or nil
    return v and v == v and math.abs(v) < 1e6 and v or nil
end

local function modelOf(model)
    if type(model) == 'string' then return model ~= '' and #model <= 64 and GetHashKey(model) or nil end
    return math.tointeger(tonumber(model))
end

--- One place as a world voice keeps it: { netId } of an entity that exists now — with `off`, a spot on it (an offset
--- in its own frame, where an object of `model` rides it: a speaker on a car's roof) — or { x, y, z, model } (a fixed
--- spot, with the model of the object standing there, or none). nil and why.
local function placeOf(p)
    if type(p) ~= 'table' or isFuncRef(p) then return nil, AT_HELP end
    local netId = rawget(p, 'netId')
    if netId ~= nil then
        netId = math.tointeger(tonumber(netId))
        if not netId or netId <= 0 then return nil, AT_HELP end
        local ent = NetworkGetEntityFromNetworkId(netId)
        if ent == 0 or not DoesEntityExist(ent) then return nil, 'no entity with that netId' end
        local o = rawget(p, 'offset')
        if o == nil then return { netId = netId } end
        if not (type(o) == 'vector3' or (type(o) == 'table' and not isFuncRef(o))) then return nil, 'offset is a vector3' end
        local ox, oy, oz = coordOf(o, 'x', 1), coordOf(o, 'y', 2), coordOf(o, 'z', 3)
        if not (ox and oy and oz) or math.sqrt(ox * ox + oy * oy + oz * oz) > MAX_OFFSET then
            return nil, ('offset is a vector3 within %d m of the entity'):format(MAX_OFFSET)
        end
        return { netId = netId, off = { ox + 0.0, oy + 0.0, oz + 0.0 }, model = modelOf(rawget(p, 'model')) }
    end
    local c = rawget(p, 'coords')
    local isVec = type(c) == 'vector3' or type(c) == 'vector4'
    if not (isVec or (type(c) == 'table' and not isFuncRef(c))) then return nil, AT_HELP end
    local x, y, z = coordOf(c, 'x', 1), coordOf(c, 'y', 2), coordOf(c, 'z', 3)
    if not (x and y and z) then return nil, 'coords is a vector3 (x, y, z)' end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0, model = modelOf(rawget(p, 'model')) }
end

--- `at` as a world voice takes it: one place, or a list of up to MAX_PLACES. A list of its places, or nil and why.
local function placesOf(at)
    if type(at) ~= 'table' or isFuncRef(at) then return nil, AT_HELP end
    if rawget(at, 'netId') ~= nil or rawget(at, 'coords') ~= nil then
        local one, why = placeOf(at)
        if not one then return nil, why end
        return { one }
    end
    local n = #at
    if n == 0 then return nil, AT_HELP end
    if n > MAX_PLACES then return nil, ('at most %d places'):format(MAX_PLACES) end
    local out = {}
    for i = 1, n do
        local p, why = placeOf(rawget(at, i))
        if not p then return nil, ('place %d: %s'):format(i, tostring(why)) end
        out[i] = p
    end
    return out
end

--- A world voice's place in the world: its places, how far it carries and its full-volume circle, and the routing
--- bucket of its fixed spots. nil and why.
local function worldAt(at, range, full, bucket)
    local points, why = placesOf(at)
    if not points then return nil, why end
    range, full = reachOf(range, full)
    return { points = points, range = range, full = full, bucket = math.tointeger(tonumber(bucket)) or 0 }
end

--- A world voice for `owner`: { name, at, range, bucket, music }. Its key, or nil and why. The CreateWorldVoice export,
--- and whip_voice's own speakers (server/speakers.lua), which may not call its exports.
function VoiceBots.createWorld(owner, spec)
    local world, w = worldAt(rawget(spec, 'at'), rawget(spec, 'range'), nil, rawget(spec, 'bucket'))
    if not world then return nil, w end
    world.music = rawget(spec, 'music') == true or nil
    return VoiceBots.create(owner, { name = rawget(spec, 'name'), world = world })
end

--- The same rules as the exports below, for whip_voice's own world voices (server/speakers.lua).
function VoiceBots.setWorldRange(key, range, full)
    local b = VoiceBots.byKey[key]
    if not (b and b.world) then return false, 'no such world voice' end
    b.world.range, b.world.full = reachOf(range, full)
    if Hearing and Hearing.rangeChanged then Hearing.rangeChanged(key) end
    return true
end

function VoiceBots.setWorldSound(key, recipe)
    local b = VoiceBots.byKey[key]
    if not (b and b.world) then return false, 'no such world voice' end
    if recipe == false or recipe == nil then
        b.world.sound = nil
    else
        local r, why = Lines.checkRecipe(recipe)
        if not r then return false, why end
        b.world.sound = #r > 0 and r or nil
    end
    if Hearing then Hearing.rangeChanged(key) end
    return true
end

exports('CreateWorldVoice', function(spec)
    local owner = GetInvokingResource()
    if not owner or owner == RESOURCE then return false, 'call it from another resource' end
    if type(spec) ~= 'table' or isFuncRef(spec) then return false, 'a world voice is { name, at, range, bucket, music }' end
    local key, d = VoiceBots.createWorld(owner, spec)
    if not key then return false, d end
    return key
end)

exports('PlayWorldVoice', function(key, audio, onDone, opts)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    ---@cast owner -nil   -- the bot's owner, so a resource
    if not b.world then return false, 'that voice bot is on a line, not in the world (PlayVoiceBot)' end
    if onDone ~= nil and type(onDone) ~= 'function' and not isFuncRef(onDone) then return false, 'onDone is a function' end
    local o = {}
    if type(opts) == 'table' and not isFuncRef(opts) then
        o.loop, o.music, o.fadeIn = rawget(opts, 'loop') == true, rawget(opts, 'music') == true, tonumber(rawget(opts, 'fadeIn'))
    end
    local cb = onDone and function(...) if GetResourceState(owner) == 'started' then onDone(...) end end or nil
    local d, pw = VoiceBots.say(key, audio, cb, o)
    if not d then return false, pw end
    return d
end)

exports('StopWorldVoice', function(key, fadeMs)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    if not b.world then return false, 'that voice bot is on a line, not in the world' end
    return VoiceBots.stop(key, fadeMs)
end)

exports('SetWorldVoiceSound', function(key, recipe)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    if not b.world then return false, 'that voice bot is on a line, not in the world' end
    -- (Everyone hearing it hears the new sound at once.)
    return VoiceBots.setWorldSound(key, recipe)
end)

exports('MoveWorldVoice', function(key, at)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    if not b.world then return false, 'that voice bot is on a line, not in the world' end
    local points, ww = placesOf(at)
    if not points then return false, ww end
    b.world.points = points   -- (moving keeps its range, megaphone, sound and bucket)
    if Hearing then Hearing.rangeChanged(key) end
    return true
end)

exports('SetWorldVoiceRange', function(key, range, full)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    if not b.world then return false, 'that voice bot is on a line, not in the world' end
    if tonumber(range) == nil then return false, 'range is a number of metres' end
    -- (Those hearing it now: the new edge at once. Those it now reaches: the next pass connects them.)
    return VoiceBots.setWorldRange(key, range, full)
end)

exports('SetWorldVoiceMegaphone', function(key, on)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    if not b.world then return false, 'that voice bot is on a line, not in the world' end
    on = on == true
    if (b.world.megaphone == true) == on then return true end
    b.world.megaphone = on or nil
    -- Everyone hearing it hears the change at once; who is in reach now is worked out on the next pass.
    if Hearing then Hearing.rangeChanged(key); Hearing.wake() end
    return true
end)

exports('SetWorldVoiceRadio', function(key, freq)
    local owner = GetInvokingResource()
    local b, w = mine(owner, key)
    if not b then return false, w end
    if not b.world then return false, 'that voice bot is on a line, not in the world (a call bot has its line)' end
    if freq == false or freq == nil then return VoiceBots.setRadio(key, nil) end
    local f = math.tointeger(tonumber(freq))
    if not f then return false, 'a frequency is a whole number' end
    return VoiceBots.setRadio(key, f)
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
