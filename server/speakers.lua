-- ============================================
-- whip_voice — the speaker (an item)
-- ============================================
--
-- A speaker a player puts down: Use the item, then place it exactly with whip's placer (PlaceObject: the wheel turns
-- it, the arrows raise it) on the ground, a table, or a car's roof or bed, where it rides the car. Behind it, a prompt
-- (client/speakers.lua): the song (a link, Config.Speaker.links only), Play / Stop, Volume, Range, Pick up. Anyone
-- standing at it can use it, as anyone could a real one.
--
-- It plays as the Director's speakers do: a world voice of whip_voice's own, the voice bot playing the song on a loop,
-- heard from the speaker by everyone near, through walls the way a voice is, and as MUSIC (html/js/audio.js setSpace):
-- from far off it comes late and loses its treble, and on a passing car it rises and falls in pitch (the Doppler
-- effect). The voice bot plays the song; players never download it.
--
-- What it looks like: a prop set (whip_core ShowPropSet), each game's own copy, attached to the car for one on a car.
-- Its song, volume and range go with the item (its metadata): picked up and put down again, it is as it was.
--
-- A RESTART GIVES THEM BACK (this resource's KVP keeps what is out): every speaker out goes back to whoever put it
-- down, as the item with its song, volume and range, now or at their next login (restore, below). One whose car goes
-- (deleted, put away) is put down as an item where the car last was. The item is never lost or doubled: it leaves the
-- pockets (saved) before the speaker is kept, and the speaker is let go of before the item is given back.

Speakers = { byId = {} }

local core = exports.whip_core
local RESOURCE = GetCurrentResourceName()
local S = Config.Speaker or {}
local MODEL = S.model or 'ba_prop_battle_club_speaker_small'
local LINKS = S.links or { 'https://r2.fivemanage.com/' }
local MAX_PER = math.max(1, math.floor(tonumber(S.maxPerPlayer) or 3))
local MAX_ALL = math.max(1, math.floor(tonumber(S.maxPlaced) or 64))
local RANGE_MIN, RANGE_MAX = 5, math.max(5, math.min(300, math.floor(tonumber(S.maxRange) or 100)))
local KVP = 'whip_voice_speakers'
local REACH = 3.5           -- metres from a speaker to use it (from the player, server-side: a little slack)
local PLACE_REACH = 12.0    -- metres from the player a speaker may be put (the placer reaches 10 m from the camera)
local CAR_SLACK = 5.0       -- a car's speaker is told from the car's middle: its length more
local PENDING_S = 300       -- seconds a Use waits for the speaker to be put down
local CAR_GONE_MS = 10000   -- a car missing this long has gone: its speaker drops where it last was

local pending = {}          -- [source] = { addr, uid, at, charId, bucket }: a Use waiting to be put down
local nextId = 0

local function say(fmt, ...) print(('[whip_voice] speakers: ' .. fmt):format(...)) end

local function volumeOf(v) return math.max(0, math.min(200, math.floor(tonumber(v) or tonumber(S.volume) or 100))) end
local function rangeOf(v) return math.max(RANGE_MIN, math.min(RANGE_MAX, math.floor(tonumber(v) or tonumber(S.range) or 30))) end

--- Why a song's link is not played, or nil: the links the owner allows (Config.Speaker.links), a file's address,
--- an mp3, ogg or wav.
function Speakers.linkProblem(url)
    if type(url) ~= 'string' or url == '' then return 'Give it a song\'s link' end
    if #url > 255 then return 'A link is at most 255 characters' end
    for _, start in ipairs(LINKS) do
        if type(start) == 'string' and start ~= '' and url:sub(1, #start) == start then
            local rest = url:sub(#start + 1)
            if rest == '' or not rest:match('^[%w%-%._/]+$') or rest:find('..', 1, true) then return 'That link is not a song\'s address' end
            local ext = (rest:match('%.(%w+)$') or ''):lower()
            if ext ~= 'mp3' and ext ~= 'ogg' and ext ~= 'wav' then return 'A song is an .mp3, .ogg or .wav link' end
            return nil
        end
    end
    return ('Only links starting with %s are played'):format(table.concat(LINKS, ' or '))
end

-- ============================================
-- Keeping them
-- ============================================

--- Every speaker, written to this resource's KVP (what survives a restart).
local function save()
    local list = {}
    for _, s in pairs(Speakers.byId) do
        list[#list + 1] = { model = s.model, coords = s.coords, rot = s.rot, onCar = s.car ~= nil or nil, last = s.lastAt,
                            link = s.link, volume = s.volume, range = s.range, owner = s.owner, bucket = s.bucket }
    end
    SetResourceKvp(KVP, json.encode(list))
end

--- What every player's game is told of the speakers (client/speakers.lua: the prompts behind them).
local function views()
    local out = {}
    for id, s in pairs(Speakers.byId) do
        out[#out + 1] = { id = id, model = s.model, coords = s.coords, rot = s.rot, net = s.car and s.car.net or nil,
                          offset = s.car and s.car.offset or nil, carRot = s.car and s.car.rot or nil,
                          song = s.link and s.link:match('([^/]+)$') or nil,
                          playing = s.playing == true, volume = s.volume, range = s.range }
    end
    return out
end

local function broadcast() TriggerClientEvent('whip_voice:client:speakers', -1, views()) end

local function vec(t) return vector3(t[1] + 0.0, t[2] + 0.0, t[3] + 0.0) end

--- Its prop for everyone (a prop set of one; on a car, attached to it), seen from as far as it can be heard
--- (Config.Speaker.drawDistance: past its model's own 100 m and whip's usual 150 m).
local DRAW = math.max(1, math.min(500, math.floor(tonumber(S.drawDistance) or 300)))
local function show(s)
    local prop = { model = s.model, coords = vec(s.coords), rot = vec(s.rot), drawDistance = DRAW }
    if s.car then
        prop.attach, prop.attachOffset, prop.attachRot = { net = s.car.net }, vec(s.car.offset), vec(s.car.rot)
    end
    local ok, why = core:ShowPropSet('speaker:' .. s.id, { props = { prop } })
    if not ok then say('could not show speaker %d: %s', s.id, tostring(why)) end
end

local function hide(s) pcall(function() core:HidePropSet('speaker:' .. s.id) end) end

--- Where it is now: its spot, or its car's middle (nil while the car is not there).
local function whereNow(s)
    if not s.car then return vec(s.coords) end
    local ent = NetworkGetEntityFromNetworkId(s.car.net)
    if ent == 0 or not DoesEntityExist(ent) then return nil end
    local c = GetEntityCoords(ent)
    s.lastAt = { c.x, c.y, c.z }
    return c
end

local function near(source, s)
    local at = whereNow(s)
    if not at then return false end
    local ped = GetPlayerPed(source)
    if ped == 0 then return false end
    return #(GetEntityCoords(ped) - at) <= REACH + (s.car and CAR_SLACK or 0.0)
end

local function countOf(charId)
    local n = 0
    for _, s in pairs(Speakers.byId) do if s.owner == charId then n = n + 1 end end
    return n
end

local function total()
    local n = 0
    for _ in pairs(Speakers.byId) do n = n + 1 end
    return n
end

-- ============================================
-- Playing
-- ============================================

--- Where its sound comes from, as a world voice takes it: its spot and model, or the spot on its car.
local function placeOf(s)
    if s.car then return { netId = s.car.net, offset = vec(s.car.offset), model = s.model } end
    return { coords = vec(s.coords), model = s.model }
end

--- Its volume as a sound recipe (whip_voice's gain block), or false at 100 %.
local function soundOf(s)
    local v = s.volume / 100
    if v == 1 then return false end
    return { { 'gain', db = v > 0.001 and 20 * math.log(v, 10) or -60 } }
end

--- Its world voice let go of (the song with it).
local function silence(s)
    s.playing = false
    if s.key then
        local key = s.key
        s.key = nil
        VoiceBots.remove(key, 'removed')
    end
end

--- Play its song, on a loop. WAITS (the voice bot is asked). true, or false and why.
local function play(s)
    if not s.link then return false, 'Give it a song first' end
    if not s.key then
        local key, why = VoiceBots.createWorld(RESOURCE, { name = 'Speaker', at = placeOf(s), range = s.range,
                                                           bucket = s.bucket, music = true })
        if not key then return false, tostring(why) end
        if not Speakers.byId[s.id] then VoiceBots.remove(key, 'removed') return false, 'That speaker is gone' end
        s.key = key
    end
    VoiceBots.setWorldSound(s.key, soundOf(s))
    local id, key = s.id, s.key
    local d, why = VoiceBots.say(s.key, s.link, function(_, how)
        -- (A new song on it, 'cut', is still playing.)
        local cur = Speakers.byId[id]
        if how ~= 'cut' and cur and cur.key == key and cur.playing then
            cur.playing = false
            broadcast()
        end
    end, { loop = true, music = true, fadeIn = 600 })
    if not d then return false, tostring(why) end
    s.playing = true
    return true
end

-- ============================================
-- Putting one down, and the prompt's asks
-- ============================================

--- The item used: they put it down next (client/speakers.lua runs the placer, then placeSpeaker).
local function use(source, player, slotData, addr)
    if countOf(player.charId) >= MAX_PER then
        return false, ('You have %d speakers out already'):format(MAX_PER)
    end
    if total() >= MAX_ALL then return false, 'There are too many speakers out' end
    local md = type(slotData) == 'table' and slotData.metadata or nil
    pending[source] = { addr = addr, uid = type(md) == 'table' and md.uid or nil, at = os.time(), charId = player.charId,
                        bucket = GetPlayerRoutingBucket(source) }
    TriggerClientEvent('whip_voice:client:placeSpeaker', source, MODEL)
    return false   -- kept until it is put down
end

--- Put down where the placer said (on a car: `net` and where on it). true, or false and why (the player is told).
local function place(source, x, y, z, rx, ry, rz, net, ox, oy, oz, orx, ory, orz)
    local p = pending[source]
    pending[source] = nil
    if not p or os.time() - p.at > PENDING_S then return false, 'Use the speaker again' end
    local ped = GetPlayerPed(source)
    local me = GetEntityCoords(ped)
    local spot = vector3(x, y, z)
    if #(me - spot) > PLACE_REACH then return false, 'Too far away' end
    local car = nil
    if net > 0 then
        local ent = NetworkGetEntityFromNetworkId(net)
        if ent == 0 or not DoesEntityExist(ent) or GetEntityType(ent) ~= 2 then return false, 'That car is gone' end
        if #(GetEntityCoords(ent) - me) > PLACE_REACH + CAR_SLACK then return false, 'Too far from the car' end
        if math.sqrt(ox * ox + oy * oy + oz * oz) > 6.0 then return false, 'Not on that car' end
        car = { net = net, offset = { ox, oy, oz }, rot = { orx, ory, orz } }
    end
    if countOf(p.charId) >= MAX_PER then return false, ('You have %d speakers out already'):format(MAX_PER) end
    if total() >= MAX_ALL then return false, 'There are too many speakers out' end
    -- The very speaker they used, still where it was.
    local item = core:GetItemAt(p.addr)
    if type(item) ~= 'table' or item.item ~= 'speaker' then return false, 'The speaker is not where it was' end
    local md = type(item.metadata) == 'table' and item.metadata or {}
    if p.uid ~= nil and md.uid ~= p.uid then return false, 'The speaker is not where it was' end
    local taken, twhy = core:StoreTake(p.addr, 1, 'put down as a speaker')
    if not taken then return false, twhy or 'Could not take the speaker' end
    -- The item's going is written before the speaker is kept: never both, whatever stops the server.
    pcall(function() core:SavePlayer(source) end)
    nextId = nextId + 1
    local s = { id = nextId, model = MODEL, coords = { x, y, z }, rot = { rx, ry, rz }, car = car, lastAt = { x, y, z },
                link = Speakers.linkProblem(md.speakerLink) == nil and md.speakerLink or nil,
                volume = volumeOf(md.speakerVolume), range = rangeOf(md.speakerRange), owner = p.charId,
                bucket = p.bucket, playing = false }
    Speakers.byId[s.id] = s
    show(s)
    save()
    broadcast()
    if car then Speakers.watchCars() end
    return true
end

--- Pick it up: the song stops, the prop goes, and the item comes back with its song, volume and range.
local function pickUp(source, s)
    silence(s)
    hide(s)
    Speakers.byId[s.id] = nil
    save()
    broadcast()
    local where, why = core:AddItem(source, 'speaker', 1,
        { speakerLink = s.link, speakerVolume = s.volume, speakerRange = s.range }, 'picked up a speaker')
    if not where then
        -- (Never lost: back where it was.)
        Speakers.byId[s.id] = s
        show(s)
        save()
        broadcast()
        return false, tostring(why)
    end
    return true
end

--- One of the prompt's asks (client/speakers.lua). true, or false and why.
local function act(source, id, what, value)
    local s = Speakers.byId[id]
    if not s then return false, 'That speaker is gone' end
    if not near(source, s) then return false, 'Too far from the speaker' end
    if what == 'pickup' then return pickUp(source, s) end
    if what == 'link' then
        local url = value:match('^%s*(.-)%s*$')
        local bad = Speakers.linkProblem(url)
        if bad then return false, bad end
        s.link = url
        save()
        if s.playing then
            CreateThread(function()
                local ok, why = play(s)
                if not ok then core:NotifyPlayer(source, 'The speaker could not play it: ' .. why, 'error') end
                broadcast()
            end)
        end
        broadcast()
        return true
    end
    if what == 'play' then
        if not s.link then return false, 'Give it a song first' end
        s.playing = true
        broadcast()
        CreateThread(function()
            local ok, why = play(s)
            if not ok then
                s.playing = false
                core:NotifyPlayer(source, 'The speaker could not play it: ' .. why, 'error')
            end
            broadcast()
        end)
        return true
    end
    if what == 'stop' then
        if not s.playing then return true end
        s.playing = false
        broadcast()
        if s.key then
            local key = s.key
            CreateThread(function() VoiceBots.stop(key, 1200) end)
        end
        return true
    end
    if what == 'volume' then
        local n = tonumber(value)
        if not n then return false, 'Type a volume, 0 to 200' end
        s.volume = volumeOf(n)
        if s.key then VoiceBots.setWorldSound(s.key, soundOf(s)) end
        save()
        broadcast()
        return true
    end
    if what == 'range' then
        local n = tonumber(value)
        if not n then return false, ('Type a range, %d to %d'):format(RANGE_MIN, RANGE_MAX) end
        s.range = rangeOf(n)
        if s.key then VoiceBots.setWorldRange(s.key, s.range) end
        save()
        broadcast()
        return true
    end
    return false, 'Unknown'
end

-- ============================================
-- Cars that go, restarts
-- ============================================

--- A speaker on the ground where `at` is: an item there, with its song, volume and range. true, or false and why.
local function dropAt(s, at, reason)
    local ok, why = core:CreateGroundItem({ item = 'speaker', amount = 1, coords = vec(at),
        metadata = { speakerLink = s.link, speakerVolume = s.volume, speakerRange = s.range }, reason = reason })
    if not ok then say('could not put speaker %s down as an item: %s', tostring(s.id), tostring(why)) end
    return ok ~= false and ok ~= nil, why
end

local watching = false

--- Speakers on cars, watched every few seconds while there are any: a car gone for good (deleted, put away) drops
--- its speaker where it last was, as an item. Their last places are kept for a restart.
function Speakers.watchCars()
    if watching then return end
    watching = true
    CreateThread(function()
        local missing = {}
        while true do
            local any, moved = false, false
            local now = GetGameTimer()
            for id, s in pairs(Speakers.byId) do
                if s.car then
                    any = true
                    local before = s.lastAt
                    if whereNow(s) then
                        missing[id] = nil
                        -- (Kept for a restart once it has gone somewhere: not every few seconds for a parked car.)
                        local a, b = before, s.lastAt
                        if not a or (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 > 25 then moved = true else s.lastAt = a end
                    else
                        missing[id] = missing[id] or now
                        if now - missing[id] >= CAR_GONE_MS then
                            missing[id] = nil
                            silence(s)
                            hide(s)
                            Speakers.byId[id] = nil
                            save()
                            broadcast()
                            dropAt(s, s.lastAt, 'its car went')
                        end
                    end
                end
            end
            if moved then save() end
            if not any then break end
            Wait(5000)
        end
        watching = false
    end)
end

local restored = false

--- Once a start: the speakers that were out go BACK TO WHOEVER PUT THEM DOWN (Josh, 14 Nov 2026), on the ground or on a
--- car, with their song, volume and range: into their pockets now if they are on, else at their next login (whip's
--- GiveOnLogin, which puts it at their feet when their pockets are full). One whose owner whip cannot find is put down
--- as an item where it was. Each is crossed off the kept list before it is given, so a stop in the middle can never
--- give one twice.
local function restore()
    if restored then return end
    restored = true
    local raw = GetResourceKvpString(KVP)
    local ok, list = pcall(json.decode, raw or '[]')
    if not ok or type(list) ~= 'table' then return end
    local back, dropped = 0, 0
    local left = {}
    for i, r in ipairs(list) do left[i] = r end
    for _, r in ipairs(list) do
        table.remove(left, 1)
        SetResourceKvp(KVP, json.encode(left))
        if type(r) == 'table' and type(r.coords) == 'table' then
            local s = { link = Speakers.linkProblem(r.link) == nil and r.link or nil, volume = volumeOf(r.volume),
                        range = rangeOf(r.range) }
            local owner = math.tointeger(tonumber(r.owner))
            local given, why = false, 'no owner'
            if owner then
                local okG, g, w = pcall(function()
                    return core:GiveOnLogin({ charId = owner }, 'speaker', 1,
                        { speakerLink = s.link, speakerVolume = s.volume, speakerRange = s.range },
                        'their speaker, back after a restart')
                end)
                given, why = okG and g and true or false, tostring(okG and w or g)
            end
            if given then
                back = back + 1
            else
                say('speaker of character %s could not go back to them (%s): put down where it was', tostring(owner), tostring(why))
                dropAt(s, type(r.last) == 'table' and r.last or r.coords, 'its owner could not be found after a restart')
                dropped = dropped + 1
            end
        end
    end
    save()
    if back > 0 or dropped > 0 then say('%d speaker(s) back to their owners; %d put down as items', back, dropped) end
end

-- ============================================
-- Declared to whip (again whenever whip_core restarts)
-- ============================================

function Speakers.register()
    restore()
    -- (whip_core restarting took their props with it.)
    for _, s in pairs(Speakers.byId) do show(s) end

    core:RegisterUseHandler('speaker', use)

    -- Put down where the placer said. The numbers are clamped to the map; on a car, net > 0 and where on it.
    core:SecureEvent('whip_voice:server:placeSpeaker', {
        rateLimit = 500, burst = 2,
        params = {
            { 'x', 'number', -20000, 20000 }, { 'y', 'number', -20000, 20000 }, { 'z', 'number', -500, 3000 },
            { 'rx', 'number', -360, 360 }, { 'ry', 'number', -360, 360 }, { 'rz', 'number', -360, 360 },
            { 'net', 'int', 0, 65535, 0 },
            { 'ox', 'number', -10, 10, 0 }, { 'oy', 'number', -10, 10, 0 }, { 'oz', 'number', -10, 10, 0 },
            { 'orx', 'number', -360, 360, 0 }, { 'ory', 'number', -360, 360, 0 }, { 'orz', 'number', -360, 360, 0 },
        },
    }, function(source, _, ...) return place(source, ...) end)

    -- The prompt behind one: its song, Play, Stop, Volume, Range, Pick up.
    core:SecureEvent('whip_voice:server:speaker', {
        rateLimit = 250, burst = 4,
        params = { { 'id', 'id' }, { 'what', 'enum', { 'link', 'play', 'stop', 'volume', 'range', 'pickup' } },
                   { 'value', 'string', 255, '' } },
    }, function(source, _, id, what, value) return act(source, id, what, value) end)

    -- Every speaker, for a game that has just started (client/speakers.lua).
    core:SecureCallback('whip_voice:speakers', { rateLimit = 2000, burst = 3, whileDead = true },
        function() return views() end)

    broadcast()
    if next(Speakers.byId) then Speakers.watchCars() end
end

AddEventHandler('playerDropped', function() pending[source] = nil end)

-- A character loading: every speaker, sent to its game for their prompts. Its game's own ask as it starts
-- (client/speakers.lua) comes before any character, and whip refuses a player with none, so the speakers already out
-- had no prompts for anyone who came in after they were put down: one left out over a restart was a prop nobody
-- could use (Josh, 14 Nov 2026).
AddEventHandler('whip_core:player:loaded', function(e)
    if type(e) == 'table' and e.source then TriggerClientEvent('whip_voice:client:speakers', e.source, views()) end
end)
