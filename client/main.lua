-- whip_voice client: push-to-talk and the HUD light, connecting to the voice server when a character loads, passing the
-- server's hear/allow lists to the page (html/js/voice.js), and feeding it the camera and heard players' heads (audio.js).

local talking = false   -- transmitting right now (a key is down, or its short tail is running)
local onRadio = false   -- ...and on the radio
local TAIL_MS = 200     -- the mic stays open this long after a key comes up: the last word survives
-- The two talk keys. `open`: down, or in its tail. `gen` is bumped on every press, so an old release's
-- tail cannot end a new press.
local keys = {
    voice = { down = false, open = false, gen = 0 },
    radio = { down = false, open = false, gen = 0 },
}

-- The radio as client/radio.lua keeps it (the server's word): on, to a frequency, or off; on speaker.
RadioState = { on = false, freq = nil, speaker = false }

local wantVoice = false  -- a character is loaded: we should be connected
local connecting = false -- asking the server for a pass
local joining = false    -- the page is joining the voice server with it
local joinGen = 0        -- bumped per join, so an old join's give-up timer cannot end a new one
local JOIN_WAIT_MS = 20000
local joined = false     -- in the voice room
local lastError = nil    -- why the last join failed or the connection went, for /voicecheck
local heard = {}         -- [identity] = server id of the player that voice belongs to, or { ent = netId } (a world voice)
local heardRange = {}    -- [identity] = how far that voice carries (metres), from the server
local talkers = {}       -- [identity] = true while the page hears them talking
local anyTalkers = false
local live = {}          -- [identity] = true while that speaker holds push-to-talk (the page says)
local anyLive = false
local pedOf = {}         -- [identity] = the ped that voice comes from, as last found (nil = not in this game)
local envCache = {}      -- [identity] = how that voice travels, as last worked out
local envAt = {}         -- [identity] = when that was (nil = at the next chance)

-- World voices talking here, for other resources (a lore character's subtitle waits for its line to be heard):
-- [netId] = true while sound comes out of that entity's voice; each change is the local event
-- whip_voice:entityTalking (netId, on).
local talkingEnts = {}
local function sayEntsTalking()
    local now = {}
    for id in pairs(talkers) do
        local s = heard[id]
        if type(s) == 'table' and s.ent then now[s.ent] = true end
    end
    for ent in pairs(now) do if not talkingEnts[ent] then TriggerEvent('whip_voice:entityTalking', ent, true) end end
    for ent in pairs(talkingEnts) do if not now[ent] then TriggerEvent('whip_voice:entityTalking', ent, false) end end
    talkingEnts = now
end

--- Does this game hear the world voice of the entity with this network id, and is sound coming out of it now?
---     local hears, talking = exports.whip_voice:HearsEntity(netId)
exports('HearsEntity', function(netId)
    netId = tonumber(netId)
    for _, s in pairs(heard) do
        if type(s) == 'table' and s.ent == netId then return true, talkingEnts[netId] == true end
    end
    return false, false
end)

--- Forget everything about the voices heard (the connection dropped).
local function forgetVoices()
    heard, heardRange, talkers, anyTalkers = {}, {}, {}, false
    live, anyLive = {}, false
    envCache, envAt = {}, {}
    pedOf = {}
    VoicePeds = pedOf
    sayEntsTalking()
end

-- ---- The HUD, the mic -------------------------------------------------------------------------

--- Tell the HUD and the page how the player is talking now, if that changed. Either key opens the
--- microphone for the people near; the radio key also puts them on the radio — while it is on.
local function applyTalk()
    local radio = keys.radio.open and RadioState.on == true
    local on = keys.voice.open or radio
    if on == talking and radio == onRadio then return end
    local radioChanged = radio ~= onRadio
    talking, onRadio = on, radio
    Whip.call('SetVoiceTalking', on, radio and 'radio' or nil)    -- the HUD: blue, or orange with a radio
    SendNUIMessage({ action = 'talk', on = on, radio = radio })   -- the page opens or closes the microphone
    if radioChanged and WalkieTalking then WalkieTalking(radio) end   -- the hand to the shoulder mic (radio.lua)
end

--- The radio went on or off (client/radio.lua): talking on it starts or stops with it.
function VoiceTalkRefresh() applyTalk() end

local function canTalk()
    if not Config.DeadCanTalk and Whip.call('IsPlayerDead') == true then return false end
    return true
end

local function press(which)
    local k = keys[which]
    k.down = true
    k.gen = k.gen + 1
    if canTalk() then
        k.open = true
        applyTalk()
    end
end

local function release(which)
    local k = keys[which]
    k.down = false
    local gen = k.gen
    SetTimeout(TAIL_MS, function()
        if gen == k.gen and not k.down then
            k.open = false
            applyTalk()
        end
    end)
end

--- Dying or logging out mid-sentence ends the sentence, on both keys.
local function stopTalking()
    for _, k in pairs(keys) do
        k.down, k.open = false, false
        k.gen = k.gen + 1
    end
    applyTalk()
end

-- Push-to-talk: a real FiveM key binding, changeable in GTA's Settings > Key Bindings > FiveM. Config.PushToTalkKey is
-- only the default. Not guarded by IsGameInputFree on purpose: talking changes nothing in the world, so a player must be
-- able to speak while aiming or placing. FiveM already stops key bindings while a text box has the keyboard.
RegisterCommand('+whip_voice_talk', function() press('voice') end, false)

-- The release half. Required even if it did nothing: without it FiveM hands `-whip_voice_talk` to
-- the chat as typed text (see whip_autos/client/main.lua for that story).
RegisterCommand('-whip_voice_talk', function() release('voice') end, false)

RegisterKeyMapping('+whip_voice_talk', 'Voice: push to talk', 'keyboard', Config.PushToTalkKey or 'N')

-- The radio's key: the same, for talking on the radio (Caps Lock unless config.lua or the player says otherwise). It
-- does nothing while the radio is off. The people near still hear you too.
RegisterCommand('+whip_voice_radio', function() press('radio') end, false)
RegisterCommand('-whip_voice_radio', function() release('radio') end, false)

RegisterKeyMapping('+whip_voice_radio', 'Voice: radio push to talk', 'keyboard',
    (Config.Radio and Config.Radio.PushToTalkKey) or 'CAPITAL')

-- On a controller: LB + A talks, LB + X talks on the radio, unless the player moved them (the pause menu's
-- Controller screen). Both work over menus and screens, as the keys do.
Whip.register(function()
    for _, a in ipairs({
        { 'talk',  { label = 'Talk (hold)',  command = '+whip_voice_talk',  menus = true, slot = 'lb_a' } },
        { 'radio', { label = 'Radio (hold)', command = '+whip_voice_radio', menus = true, slot = 'lb_x' } },
    }) do
        local ok, why = exports.whip_core:RegisterPadAction(a[1], a[2])
        if not ok then print(('[whip_voice] no %s on the controller: %s'):format(a[1], tostring(why))) end
    end
end)

--- The on-screen radio's own push to talk (client/walkie.lua) works like the key. `now`: let go without the tail,
--- for a refused press or a radio gone off.
function VoiceRadioBar(down, now)
    if down then
        press('radio')
    elseif now then
        local k = keys.radio
        k.down, k.open = false, false
        k.gen = k.gen + 1
        applyTalk()
    else
        release('radio')
    end
end

--- Talking on the radio right now (the bar or the key, while the radio is on).
function VoiceOnRadio() return onRadio end

-- FiveM's own voice chat: on Legacy its built-in voice (Mumble) runs by default on the same N key. Off while
-- whip_voice is connected, back on if it stops. On Enhanced it is off unless the server turns it on.
local function builtInVoice(on)
    if MumbleSetActive then pcall(MumbleSetActive, on) end
end

-- ---- Connecting -------------------------------------------------------------------------------

-- Background noise suppression: the player's game takes fans, keyboards and hum out of their microphone before it is
-- sent. On unless Config.Quality.noiseSuppression says otherwise; each player can switch it off in the pause menu's
-- Server Settings. Kept on this PC only while it differs from the server's default.
local NOISE_KVP = 'whip_voice:noiseSuppression'

local function noiseDefault() return (Config.Quality or {}).noiseSuppression ~= false end

local function noiseSuppression()
    local saved = GetResourceKvpString(NOISE_KVP)
    if saved == 'on' then return true elseif saved == 'off' then return false end
    return noiseDefault()
end

local function sendRange()
    local name = Whip.call('GetVoiceName')
    if type(name) == 'string' then TriggerServerEvent('whip_voice:server:setRange', name:lower()) end
end

local connectLater

local toldOff = false

--- Ask the server for a pass and join. Nothing happens while a join is already on its way.
local function connect()
    if connecting or joining or not wantVoice then return end
    -- Another voice resource is the voice system: this one stays off, and FiveM's own
    -- voice is left as it is (whip_core client/voice_system.lua).
    local v = Whip.call('GetVoiceSystem')
    if type(v) == 'table' and v.resource ~= GetCurrentResourceName() then
        if not toldOff then print(('[whip_voice] %s is the voice system: whip_voice stays off'):format(tostring(v.resource))) end
        toldOff = true
        return
    end
    connecting = true
    CreateThread(function()
        local data, why = Whip.call('Callback', 'whip_voice:token')
        connecting = false
        if type(data) ~= 'table' or not data.token then
            lastError = 'the server gave no pass into voice: ' .. tostring(why or data)
            print('[whip_voice] could not join voice: ' .. tostring(why or data) .. ' (trying again in 10-15 s)')
            connectLater(10000)
            return
        end
        joining = true      -- until the page says how it went (state / disconnected)
        joinGen = joinGen + 1
        local gen = joinGen
        SendNUIMessage({ action = 'connect', url = data.url, token = data.token, quality = Config.Quality,
            noiseSuppression = noiseSuppression(), fullWithin = Config.FullVolumeWithin, radioKbps = Config.Radio and Config.Radio.bitrateKbps,
            -- (The radio's static and distortion travel in its frequencies' sound recipe: server/radio.lua.)
            sound = { headphone3D = (Config.Environment or {}).headphone3D ~= false, sideDb = Config.SideSeparation },
            -- What a sound recipe may be made of (shared/sound_blocks.lua): the page checks with it.
            blocks = SoundBlocks, blockLimits = SoundLimits })
        -- The page never answered (it should within seconds): stop waiting and try again.
        SetTimeout(JOIN_WAIT_MS, function()
            if joining and gen == joinGen then
                joining = false
                print('[whip_voice] the voice page did not answer; trying again')
                connectLater(0)
            end
        end)
    end)
end

-- Not everyone at once: when the voice server blips or a resource restarts, every game wants to rejoin together, so
-- each waits its own random 0-5 s.
local SPREAD_MS = 5000
math.randomseed(GetGameTimer() * 7 + GetPlayerServerId(PlayerId()))

--- Join after `afterMs` plus the random spread — unless already in (or on the way in) by then.
connectLater = function(afterMs)
    SetTimeout((afterMs or 0) + math.random(0, SPREAD_MS), function()
        if wantVoice and not joined then connect() end
    end)
end

-- A character loaded: join now (one player loading in is no crowd). Already in — a character
-- change, or whip_core restarting and loading everyone again — stays in.
AddEventHandler('whip_core:player:loaded', function()
    wantVoice = true
    if not joined then connect() end
end)

-- whip_voice (re)started on the server: join its new room.
RegisterNetEvent('whip_voice:client:reconnect', function()
    if wantVoice then connectLater(0) end
end)

-- Started while a character is already loaded (whip_voice restarted: every player at once).
Whip.register(function()
    if Whip.call('IsPlayerLoaded') == true and not joined then
        wantVoice = true
        connectLater(0)
    end
end)

-- How loud the people around are (each player's own choice): /voicevolume 150 makes everyone 150% as loud, 50 half;
-- 100 is normal, 0 mutes. Calls and the radio have their own volumes. Kept on this PC (KVP). The page limits peaks.

local VOLUME_KVP = 'whip_voice:volume'
local volume = math.floor(math.max(0, math.min(200, tonumber(GetResourceKvpString(VOLUME_KVP) or '') or 100)))

local function applyVolume()
    SendNUIMessage({ action = 'volume', level = volume / 100 })
end

--- Set and keep it (the command, and the pause menu's Server Settings).
local function setVolume(n)
    volume = math.floor(math.max(0, math.min(200, tonumber(n) or volume)) + 0.5)
    SetResourceKvp(VOLUME_KVP, tostring(volume))
    applyVolume()
end

RegisterCommand('voicevolume', function(_, args)
    local n = tonumber(args[1] or '')
    if not n then
        Whip.call('Notify', ('Voice volume (the people around you) is %d%%. Type /voicevolume and a number from 0 to 200 to change it (100 is normal).'):format(volume), 'info', 6000)
        return
    end
    setVolume(n)
    Whip.call('Notify', ('Voice volume: %d%%'):format(volume), 'success')
end, false)

-- THE PAUSE MENU'S SERVER SETTINGS (whip_core client/player_prefs.lua; Josh, 10 Oct 2026): the same volume as
-- /voicevolume, on a slider. The value stays this resource's (its KVP); the page reads and changes it through here.
Whip.playerSetting({
    key = 'voice.volume', group = 'Chat & voice', type = 'slider', label = 'Voice volume',
    help = 'How loud the people around you are. 100% is normal; 0% mutes them. Phone calls and the radio have their own.',
    min = 0, max = 200, step = 5, unit = '%', default = 100,
    get = function() return volume end,
    set = function(n) setVolume(n) end,
})

-- How loud phone calls are (each player's own choice): every line but the radio. whip_phone's Settings > Sounds reads
-- and changes this one setting through GetPlayerSetting / SetPlayerSetting. Kept on this PC.

local CALL_KVP = 'whip_voice:callVolume'
local callVolume = math.floor(math.max(0, math.min(100, tonumber(GetResourceKvpString(CALL_KVP) or '') or 100)))

local function applyCallVolume()
    SendNUIMessage({ action = 'callVolume', level = callVolume / 100 })
end

Whip.playerSetting({
    key = 'voice.callVolume', group = 'Chat & voice', type = 'slider', label = 'Phone call volume',
    help = 'How loud the other side of a phone call is. The phone\'s Settings > Sounds changes it too.',
    min = 0, max = 100, step = 5, unit = '%', default = 100,
    get = function() return callVolume end,
    set = function(n)
        callVolume = math.floor(math.max(0, math.min(100, tonumber(n) or callVolume)) + 0.5)
        SetResourceKvp(CALL_KVP, tostring(callVolume))
        applyCallVolume()
    end,
})

-- Background noise suppression (above), as a switch. A change applies at once: the page takes the microphone
-- again with it, without leaving voice.
Whip.playerSetting({
    key = 'voice.noiseSuppression', group = 'Chat & voice', type = 'toggle', label = 'Background noise suppression',
    help = 'Takes fans, keyboards and background hum out of your microphone before anyone hears it. Switch it off if it cuts into your voice.',
    default = noiseDefault(),
    get = noiseSuppression,
    set = function(on)
        if on == noiseDefault() then DeleteResourceKvp(NOISE_KVP) else SetResourceKvp(NOISE_KVP, on and 'on' or 'off') end
        SendNUIMessage({ action = 'noiseSuppression', on = on })
    end,
})

AddEventHandler('whip_core:player:loaded', function()
    -- Loaded rather than at start: the chat resource may start after this one.
    TriggerEvent('chat:addSuggestion', '/voicevolume', 'How loud other players\' voices are', {
        { name = 'percent', help = '0 to 200 (100 is normal, 0 mutes everyone)' },
    })
end)

-- ---- What the page says -----------------------------------------------------------------------

RegisterNUICallback('state', function(d, cb)
    joined = d.joined == true
    joining = false
    TriggerServerEvent('whip_voice:server:state', joined, d.speaking == true)
    if joined then
        lastError = nil
        builtInVoice(false)
        sendRange()
        applyVolume()
        applyCallVolume()
        if WalkieJoined then WalkieJoined() end   -- the radio's volume (client/radio.lua)
    end
    cb('ok')
end)

-- THE BUILT-IN VOICE SERVER'S SIGNALLING (html/js/relay.js, server/builtin.js). The page cannot open a connection to
-- it (players' games only open secure ones), so each message goes page -> here -> the server, which passes it to the
-- voice server, and its answers come back the same way. Items arrive in order, in batches: { sock, op, data }.
RegisterNUICallback('sig', function(d, cb)
    if type(d) == 'table' and type(d.items) == 'table' then
        for _, it in ipairs(d.items) do
            if type(it) == 'table' and type(it[1]) == 'number' and type(it[2]) == 'string' then
                TriggerServerEvent('whip_voice:server:sig', it[1], it[2], type(it[3]) == 'string' and it[3] or '')
            end
        end
    end
    cb('ok')
end)

RegisterNetEvent('whip_voice:client:sig', function(sock, op, data)
    SendNUIMessage({ action = 'sig', sock = sock, op = op, data = data })
end)

RegisterNUICallback('disconnected', function(d, cb)
    joined, joining = false, false
    forgetVoices()
    lastError = tostring(d.reason)
    print('[whip_voice] voice connection lost: ' .. tostring(d.reason) .. ' (reconnecting in 3-8 s)')
    connectLater(3000)
    cb('ok')
end)

-- /voicecheck (server/check.lua): the server asks every game whether it is connected, over UDP (good) or TCP (UDP
-- blocked), and whether it can read whip_voice_secret (only if server.cfg sets it with setr, which sends it to every
-- player).
local probes = {}   -- [nonce] = { secretSeen } while the page is asked

local function answerProbe(nonce, transport, rtt, secretSeen, isJoined, why)
    TriggerServerEvent('whip_voice:server:probe', nonce, transport, math.floor(tonumber(rtt) or 0), secretSeen == true,
        isJoined == true, tostring(why or ''):sub(1, 150))
end

RegisterNetEvent('whip_voice:client:probe', function(nonce)
    nonce = math.tointeger(tonumber(nonce))
    if not nonce or nonce < 1 then return end
    local secretSeen = GetConvar('whip_voice_secret', '') ~= ''
    if not joined then
        answerProbe(nonce, 'none', 0, secretSeen, false, lastError or (joining and 'still joining') or 'not connected')
        return
    end
    probes[nonce] = { secretSeen = secretSeen }
    SendNUIMessage({ action = 'probe', nonce = nonce })
    SetTimeout(3000, function()
        local p = probes[nonce]
        if p then probes[nonce] = nil; answerProbe(nonce, 'unknown', 0, p.secretSeen, true, 'the voice page did not answer') end
    end)
end)

-- Connected without a microphone (they hear, but cannot talk), in /voicecheck's words.
local MIC_WHY = {
    none = 'no microphone yet', asking = 'no microphone: FiveM\'s permission box is still waiting for an answer',
    denied = 'no microphone: access was refused', ended = 'no microphone: it stopped (unplugged?)',
    error = 'no microphone: it could not be sent',
}

RegisterNUICallback('probe', function(d, cb)
    local nonce = math.tointeger(tonumber(d.nonce))
    local p = nonce and probes[nonce]
    if nonce and p then
        probes[nonce] = nil
        local t = d.transport
        if t ~= 'udp' and t ~= 'tcp' and t ~= 'relay' then t = 'unknown' end
        answerProbe(nonce, t, d.rtt, p.secretSeen, true, d.mic ~= 'granted' and (MIC_WHY[d.mic] or MIC_WHY.none) or '')
    end
    cb('ok')
end)

RegisterNUICallback('mic', function(d, cb)
    if d.state == 'waiting' then
        -- FiveM's "allow the microphone" box has had no answer. It only takes the mouse with the F8 console open
        -- (Legacy and Enhanced alike), which players rarely guess.
        Whip.call('Notify', 'Voice: FiveM is asking to use your microphone. Open the F8 console, then click Allow in its box. You can hear voice meanwhile.', 'info')
        print('[whip_voice] the microphone permission box has had no answer for 15 s')
    elseif d.state == 'denied' then
        Whip.call('Notify', 'Voice: no microphone access, so you can hear but not talk. Allow the microphone for this server in FiveM and reconnect.', 'error')
        print('[whip_voice] microphone refused: ' .. tostring(d.detail))
    elseif d.state == 'ended' or d.state == 'error' then
        Whip.call('Notify', 'Voice: your microphone stopped (' .. tostring(d.detail) .. ')', 'error')
    end
    cb('ok')
end)

-- The page says who is talking (sound coming out: the mouths) and who is LIVE (holding push-to-talk:
-- followed closely by the pose loop below).
RegisterNUICallback('talkers', function(d, cb)
    local now = {}
    for _, id in ipairs(type(d.ids) == 'table' and d.ids or {}) do now[id] = true end
    talkers = now
    anyTalkers = next(now) ~= nil
    sayEntsTalking()
    local nowLive = {}
    for _, id in ipairs(type(d.live) == 'table' and d.live or {}) do
        nowLive[id] = true
        -- Just pressed the key: how their voice travels is worked out on the next beat, not in up to
        -- a second.
        if not live[id] then envAt[id] = nil end
    end
    live = nowLive
    anyLive = next(nowLive) ~= nil
    cb('ok')
end)

-- ---- What the server says ---------------------------------------------------------------------

local poseRunning = false
local startPose

RegisterNetEvent('whip_voice:client:hear', function(msg)
    if type(msg) ~= 'table' then return end
    -- A player's voice comes from their server id; a world voice (a lore character, server/bots.lua) from an
    -- entity's network id.
    for _, e in ipairs(msg.add or {}) do heard[e.id] = e.ent and { ent = e.ent } or e.src; heardRange[e.id] = e.range end
    for _, id in ipairs(msg.remove or {}) do
        heard[id], heardRange[id], talkers[id], live[id] = nil, nil, nil, nil
        pedOf[id], envCache[id], envAt[id] = nil, nil, nil
    end
    anyTalkers, anyLive = next(talkers) ~= nil, next(live) ~= nil
    if msg.remove and #msg.remove > 0 then sayEntsTalking() end
    SendNUIMessage({ action = 'hear', add = msg.add or {}, remove = msg.remove or {} })
    startPose()
end)

-- Who may hear this player, and — when a big crowd does — the lower quality to send at (crowd
-- quality, config.lua; nil = the normal quality).
RegisterNetEvent('whip_voice:client:allow', function(ids, kbps, radioIds)
    SendNUIMessage({ action = 'allow', ids = type(ids) == 'table' and ids or {}, kbps = tonumber(kbps),
        radio = type(radioIds) == 'table' and radioIds or {} })
end)

-- The voice lines this player hears (a radio frequency, a call), their voices and signal go straight to the page
-- (html/js/lines.js), not in 3D. Voices coming out of a device on speaker (via) come out of that device, which is in
-- the hear list as a voice of its own ('spk:' ids, at its owner's head), so 3D, walls and distance apply to it.
RegisterNetEvent('whip_voice:client:line', function(msg)
    if type(msg) ~= 'table' then return end
    SendNUIMessage({ action = 'line', open = msg.open or {}, close = msg.close or {}, add = msg.add or {},
        remove = msg.remove or {}, q = msg.q or {}, via = msg.via or {}, level = msg.level or {} })
end)

-- The range key (Z, whip_core's): the server decides who hears whom by it.
AddEventHandler('whip_core:voice:rangeChanged', function(e)
    if joined and type(e) == 'table' and type(e.name) == 'string' then
        TriggerServerEvent('whip_voice:server:setRange', e.name:lower())
    end
end)

-- Positions, for the 3D: runs only while there is someone to hear. Live voices (holding push-to-talk) get their heads
-- 30 times a second and how their voice travels five times a second; quiet ones four and once a second. The page
-- remembers both.

local HEAD_BONE = 31086
local BEAT_MS = 33               -- the loop's beat
local ALL_EVERY_MS = 250         -- every heard head, the quiet ones too
local ENV_LIVE_MS = 200          -- how a live voice travels (walls, doorways, cars, water); the room's echo
local ENV_QUIET_MS = 1000        -- how a quiet voice travels, ready for when they speak
local FACE_EVERY_MS = 500
local lastFace, lastAll, lastEcho = 0, 0, 0
local facing = {}         -- [ped] = true while its mouth is moving

RequestAnimDict('mp_facial')
RequestAnimDict('facials@gen_male@variations@normal')

--- Move a talking player's mouth, and let it rest when they stop.
local function faces(now, speakers)
    if now - lastFace < FACE_EVERY_MS then return end
    lastFace = now
    local talkingPeds = {}
    for id in pairs(talkers) do
        local ped = speakers[id]
        if ped then talkingPeds[ped] = true end
    end
    if talking then talkingPeds[PlayerPedId()] = true end
    if HasAnimDictLoaded('mp_facial') then
        for ped in pairs(talkingPeds) do
            if IsEntityAPed(ped) then PlayFacialAnim(ped, 'mic_chatter', 'mp_facial') end
        end
    end
    if HasAnimDictLoaded('facials@gen_male@variations@normal') then
        for ped in pairs(facing) do
            -- (A world voice may come from something that is not a ped: as above)
            if not talkingPeds[ped] and DoesEntityExist(ped) and IsEntityAPed(ped) then
                PlayFacialAnim(ped, 'mood_normal_1', 'facials@gen_male@variations@normal')
            end
        end
    end
    facing = talkingPeds
end

--- The ped a heard player's voice comes from, or nil when this game has not got them (out of scope). A world
--- voice's ({ ent = netId }): that entity, while this game has it.
local function pedFor(src)
    if type(src) == 'table' then
        if not src.ent or not NetworkDoesNetworkIdExist(src.ent) then return nil end
        local ent = NetworkGetEntityFromNetworkId(src.ent)
        if ent == 0 or not DoesEntityExist(ent) then return nil end
        return ent
    end
    local player = Whip.playerIndex(src)
    if not player then return nil end
    local ped = GetPlayerPed(player)
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    return ped
end

-- How each voice travels (walls, doorways, cars, water, the room's echo) is worked out by client/environment.lua, not
-- on every beat; only the voices due are worked out and sent.
VoiceEnv = nil    -- how every heard voice travels, as last worked out, for /voicedebug
VoicePeds = pedOf -- [identity] = the ped that voice comes from, for /voicedebug

startPose = function()
    if poseRunning or next(heard) == nil then return end
    poseRunning = true
    CreateThread(function()
        while next(heard) ~= nil do
            local now = GetGameTimer()
            local all = now - lastAll >= ALL_EVERY_MS
            if all or anyLive or anyTalkers or talking then
                if all then lastAll = now end
                local cam, rot = GetFinalRenderedCamCoord(), GetFinalRenderedCamRot(2)
                local myPed = PlayerPedId()
                local me = GetPedBoneCoords(myPed, HEAD_BONE, 0.0, 0.0, 0.0)
                local where, due = {}, {}
                for id, src in pairs(heard) do
                    -- Every head on the quarter-second beat; between, only the live and the talking.
                    if all or live[id] or talkers[id] then
                        local ped = pedFor(src)
                        pedOf[id] = ped
                        if ped then
                            -- (A world voice may come from something that is not a ped: its middle, a little up.)
                            local h = IsEntityAPed(ped) and GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
                                or GetOffsetFromEntityInWorldCoords(ped, 0.0, 0.0, 0.5)
                            where[id] = { h.x, h.y, h.z }
                            local every = live[id] and ENV_LIVE_MS or ENV_QUIET_MS
                            if not envAt[id] or now - envAt[id] >= every then
                                due[id] = { ped = ped, head = where[id], range = heardRange[id] }
                            end
                        else
                            where[id] = false            -- this game cannot place them: silent
                        end
                    end
                end
                -- all = false: only some heads are in this pose; the page keeps the others.
                local msg = { action = 'pose', c = { cam.x, cam.y, cam.z, rot.x, rot.z }, h = { me.x, me.y, me.z }, s = where, all = all }
                -- The room's echo follows this player five times a second, with or without a voice due.
                if next(due) ~= nil or now - lastEcho >= ENV_LIVE_MS then
                    lastEcho = now
                    local ok, env = pcall(Environment.update, { ped = myPed, head = { me.x, me.y, me.z } }, due, heard)
                    if ok and env then
                        local v = {}
                        for id, a in pairs(env.v) do
                            envCache[id], envAt[id] = a, now
                            v[id] = { g = a.g, f = a.f, at = a.at, p = a.p }
                        end
                        msg.e = { rv = env.rv or false, v = v }
                        VoiceEnv = { rv = env.rv, v = envCache }
                    elseif not ok then
                        print('[whip_voice] environment: ' .. tostring(env))
                    end
                end
                SendNUIMessage(msg)
                faces(now, pedOf)
            end
            Wait(BEAT_MS)
        end
        poseRunning = false
    end)
end

-- ---- Endings ------------------------------------------------------------------------------------

-- Dying or logging out mid-sentence ends the sentence.
AddEventHandler('whip_core:player:died', function()
    if not Config.DeadCanTalk then stopTalking() end
end)
-- Logged out, nobody to join as until a character loads: the connection is kept, but one that drops is not asked for
-- again from the character screen, where the server refuses every ask. whip_core:player:loaded wants voice again.
AddEventHandler('whip_core:player:logout', function()
    wantVoice = false
    stopTalking()
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    builtInVoice(true)   -- never leave the server with no voice at all
end)
