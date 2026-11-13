-- ============================================
-- whip_voice — the radio, the player's side
-- ============================================
--
-- The server says whether the radio is on, on which frequency, and whether it is on speaker
-- (server/radio.lua); this keeps that (RadioState, which the radio key in client/main.lua reads),
-- plays the hand-to-the-shoulder-mic emote while talking on it, and remembers the player's last
-- frequency and radio volume on this PC. The radio on the screen: client/walkie.lua and html/js/walkie.js.

local R = Config.Radio or {}
local MIN, MAX = tonumber(R.minFrequency) or 100, tonumber(R.maxFrequency) or 999
local FREQ_KVP, VOLUME_KVP = 'whip_voice:radioFreq', 'whip_voice:radioVolume'

local function clampFreq(f)
    f = math.tointeger(tonumber(f))
    if not f or f < MIN or f > MAX then return nil end
    return f
end

--- The frequency the walkie shows when it is off: the last one used on this PC.
RadioLastFreq = clampFreq(GetResourceKvpString(FREQ_KVP)) or MIN
--- The radio's volume on this PC, 0 to 100.
RadioVolume = math.floor(math.max(0, math.min(100, tonumber(GetResourceKvpString(VOLUME_KVP) or '') or 80)))

--- A channel picked while the radio is off: nothing to ask the server, only kept on this PC (shown
--- next time, and used when it is turned on).
function RadioRemember(freq)
    local f = clampFreq(freq)
    if not f or f == RadioLastFreq then return end
    RadioLastFreq = f
    SetResourceKvp(FREQ_KVP, tostring(f))
end

--- Set and keep the radio's volume (its knob).
function RadioSetVolume(level)
    RadioVolume = math.floor(math.max(0, math.min(100, tonumber(level) or RadioVolume)) + 0.5)
    SetResourceKvp(VOLUME_KVP, tostring(RadioVolume))
    SendNUIMessage({ action = 'radioVolume', level = RadioVolume / 100 })
end

-- THE PAUSE MENU'S SERVER SETTINGS (whip_core client/player_prefs.lua; Josh, 10 Oct 2026): the knob's volume on a
-- slider too. The value stays this resource's; the page reads and changes it through here.
Whip.playerSetting({
    key = 'voice.radioVolume', group = 'Chat & voice', type = 'slider', label = 'Radio volume',
    help = 'How loud the walkie radio is. Its own knob changes it too.',
    -- steps of 10, the knob's own (walkie.js shows tenths): a 75 here would play at 75 with the knob reading 80
    min = 0, max = 100, step = 10, unit = '%', default = 80,
    get = function() return RadioVolume end,
    set = function(n) RadioSetVolume(n) end,
})

--- Joined the voice server (client/main.lua): the page gets the radio's volume.
function WalkieJoined()
    SendNUIMessage({ action = 'radioVolume', level = RadioVolume / 100 })
end

-- THE SERVER'S WORD on the radio: on to a frequency, or off (turned off, the radio lost, logged out),
-- and on speaker or not. Also its answer to a change it refused: the radio on the screen puts it back.
RegisterNetEvent('whip_voice:client:radioState', function(s)
    if type(s) ~= 'table' then return end
    RadioState.on = s.on == true
    RadioState.freq = RadioState.on and clampFreq(s.freq) or nil
    RadioState.speaker = RadioState.on and s.speaker == true
    if RadioState.freq then
        RadioLastFreq = RadioState.freq
        SetResourceKvp(FREQ_KVP, tostring(RadioState.freq))
    end
    SendNUIMessage({ action = 'walkieState', on = RadioState.on, freq = RadioState.freq or RadioLastFreq,
        speaker = RadioState.speaker })
    if WalkieRadioChanged then WalkieRadioChanged() end   -- the radio's side bar let go of if it went off
    VoiceTalkRefresh()                       -- talking on it stops if it went off
end)

-- THE HAND TO THE SHOULDER MIC while talking on the radio (Config.Radio.talkEmote) — unless the player
-- is already in an emote (sitting, a megaphone...), which is left alone. Stopped only if it is ours.
local emoteMine = false

function WalkieTalking(on)
    local emote = R.talkEmote
    if type(emote) ~= 'string' or emote == '' then return end
    if on then
        if Whip.call('IsEmoting') then return end
        emoteMine = Whip.call('PlayEmote', emote) == true
    elseif emoteMine then
        emoteMine = false
        if Whip.call('IsEmoting') == emote then Whip.call('CancelEmote') end
    end
end
