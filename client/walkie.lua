-- The radio on the screen (the 3D radio). Using the radio item opens it (server/radio.lua): a 3D handheld radio comes
-- up in the bottom right (html/js/walkie.js) and the mouse works it: the right knob is power (click) and volume (drag
-- or scroll), the middle one the channel (100-999), the bar on its side push to talk, the button on top the speaker.
-- The player stands still while it is open; Esc puts it away. The radio keeps working after.
--
-- A controller works it too: while it is open whip's pad reader (Whip.padScreen) sends presses to the page
-- (walkiePad):
--   D-pad up / down     the channel (held, it runs; ten at a time once it has run a while)
--   D-pad left / right  the volume
--   A                   power (the volume knob's click)
--   RB, held            push to talk (the side bar)
--   X                   the speaker
--   Y                   key beeps on / off (MENU)
--   B or Start          put it away
-- LB + X still talks on the radio (whip's combo). On a pad the mouse cursor goes; the mouse moving brings it back.
--
-- The radio only asks: power, the channel and the speaker go to the server, which answers with the radio's state
-- (client/radio.lua passes it on as walkieState).

local open = false
local barDown = false   -- push to talk held on the radio's side bar

-- HELD OFF WHILE IT IS UP, on whip's one control loop (BlockControls; whip_core sweeps it if this resource
-- stops): the player stands still with a pad as with the keyboard (whose keys the focus already takes),
-- and the pad's buttons do nothing in the world — enter a car (Y), reload (B), the phone and the
-- character wheel (D-pad), the car's radio station and headlights (D-pad), its cinematic camera (B).
-- Start / Esc (199, 200) too: they are the radio's (B or Start puts it away).
local BLOCK = { groups = { 'move', 'combat', 'driving', 'vehicleCombat', 'weaponWheel', 'radio' },
    controls = { 19, 20, 23, 27, 45, 47, 48, 74, 80, 199, 200 } }
local blockWarned = false

-- The pad. The BLOCK above is held with the mouse too, so the reader holds nothing of its own. RB's
-- release is sent (the side bar is held), and lets go if the hand goes to the mouse.
local screen = Whip.padScreen({
    buttons  = { 'up', 'down', 'left', 'right', 'a', 'rb', 'x', 'y', 'b', 'menu' },
    stick    = false,
    releases = { rb = true },
    block    = false,
    onButton = function(cmd, down, rep)
        SendNUIMessage({ action = 'walkiePad', cmd = cmd == 'menu' and 'b' or cmd, down = down, rep = rep })
    end,
    onDevice = function(pad) SendNUIMessage({ action = 'walkieInput', pad = pad }) end,
})

-- IN HAND WHILE IT IS UP (Config.Radio.holdEmote), as the phone is. A drawn gun is put away first. An emote the
-- player was already in (sitting, leaning...) is left alone, and only ours is stopped: one that ended or changed
-- some other way stays as it is. Refused (in a car), it stays up with nothing in the hand.
local held = nil   -- the emote we started

local function takeOut()
    local emote = (Config.Radio or {}).holdEmote
    if type(emote) ~= 'string' or emote == '' or Whip.core:IsEmoting() then return end
    Whip.core:FreeHands()
    -- FreeHands waits for the holster: the radio put away meanwhile gets no radio in the hand afterwards.
    if not open then return end
    if Whip.core:PlayEmote(emote) == true then held = emote end
end

local function putBack()
    if held and Whip.core:IsEmoting() == held then Whip.core:CancelEmote() end
    held = nil
end

local function close()
    if not open then return end
    open = false
    if barDown then
        barDown = false
        VoiceRadioBar(false)
    end
    putBack()
    screen:close()
    Whip.core:UnblockControls('whip_voice_walkie')
    Whip.core:SetUIOpen(false, 'walkie')
    SendNUIMessage({ action = 'walkieClose' })
end

RegisterNetEvent('whip_voice:client:walkie', function(s)
    if open then close() return end
    if type(s) ~= 'table' then return end
    -- Used from the inventory: the inventory makes way (the radio is not drawn over it).
    if Whip.core:IsInventoryOpen() == true then Whip.core:CloseInventory() end
    open = true
    Whip.core:SetUIOpen(true, 'walkie')       -- whip's HUD and prompts make way
    local blocked, why = Whip.core:BlockControls('whip_voice_walkie', BLOCK)
    if blocked ~= true and not blockWarned and GetResourceState('whip_core') == 'started' then
        blockWarned = true
        print(('^3[whip_voice] the radio could not hold the controls off: %s^7'):format(tostring(why)))
    end
    -- Opened on a pad: no cursor from the start (none flashes up and goes again).
    local pad = screen:open()
    local R = Config.Radio or {}
    SendNUIMessage({ action = 'walkieOpen', on = s.on == true, freq = s.freq or RadioLastFreq,
        speaker = s.speaker == true, min = s.min, max = s.max, volume = RadioVolume,
        sounds = R.uiSounds ~= false, pad = pad })
    takeOut()   -- last: it can wait on a holster, and the radio is up by then
end)

-- Power or a new channel. Power, either way, and anything while it is on: asked of the server, which
-- checks the radio and the frequency and answers. (Power always: on then off faster than the server
-- answers must still end off.) A channel picked while off: only kept on this PC. Off either way, the
-- channel it shows is kept, so it comes back to it.
RegisterNUICallback('walkieSet', function(d, cb)
    local freq = math.tointeger(tonumber(d.freq))
    if freq then
        if d.on ~= true then RadioRemember(freq) end
        if d.on == true or d.power == true or RadioState.on then
            TriggerServerEvent('whip_voice:server:radio', d.on == true, freq)
        end
    end
    cb('ok')
end)

RegisterNUICallback('walkieVolume', function(d, cb)
    RadioSetVolume(d.level)
    cb('ok')
end)

-- The side bar: push to talk, like the radio key. The answer says whether it is talking on the radio
-- now (no: the radio is not on yet, or the player cannot talk) so the radio can let go of its TX.
-- REFUSED, THE BAR IS LET GO OF AT ONCE: the radio drops its TX without a release (its own pointer-up
-- then sends nothing), so a bar left down here would start transmitting the moment the radio came on.
RegisterNUICallback('walkiePtt', function(d, cb)
    if d.on == true then
        if open and not barDown then
            barDown = true
            VoiceRadioBar(true)
            if VoiceOnRadio() ~= true then
                barDown = false
                VoiceRadioBar(false, true)
            end
        end
    elseif barDown then
        barDown = false
        VoiceRadioBar(false)
    end
    cb({ tx = VoiceOnRadio() == true })
end)

--- The radio's state changed (client/radio.lua). Gone off with the bar held (dropped, refused, turned
--- off): let go of — the radio cleared its TX quietly, so no release will come.
function WalkieRadioChanged()
    if barDown and not RadioState.on then
        barDown = false
        VoiceRadioBar(false, true)
    end
end

-- The speaker button: asked of the server (only while the radio is on).
RegisterNUICallback('walkieSpeaker', function(d, cb)
    TriggerServerEvent('whip_voice:server:radioSpeaker', d.on == true)
    cb('ok')
end)

RegisterNUICallback('walkieClose', function(_, cb)
    close()
    cb('ok')
end)

-- The 3D radio could not be built (no WebGL, a file missing): said, and put away.
RegisterNUICallback('walkieError', function(d, cb)
    print('[whip_voice] the radio on the screen could not load: ' .. tostring(d.detail))
    Whip.core:Notify('The radio could not be shown on your screen (F8 says why).', 'error')
    close()
    cb('ok')
end)

-- Dying or logging out with it open: put away.
AddEventHandler('whip_core:player:died', close)
AddEventHandler('whip_core:player:logout', close)

-- (Stopping with it open: Whip.padScreen gives the focus back.) The radio in the hand goes with it: the emote is
-- whip_core's, so it would stay.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then putBack() end
end)
