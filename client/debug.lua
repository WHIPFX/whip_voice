-- ============================================
-- whip_voice — /voicedebug (admins)
-- ============================================
--
-- Shows, above every player and world voice you can hear (a lore character, each speaker playing a song),
-- what that voice is going through right now: how many dB quieter, where the treble is cut, and why
-- ("closed door", "doorway + window", "car", "clear"). A yellow line runs to the doorway the voice is
-- coming out of. And your own room's echo, bottom left.
--
-- And every OPENING of the building you stand in, where it is, labelled with what whip_voice thinks it
-- is: door (open / closed), window, doorway, mirror. For checking an MLO's doors and windows are read
-- the way they should be.
--
-- For checking the room-and-doorway rules in a real building. Draws every frame, but only while it is
-- switched on.

local on = false

-- Opening colours: door orange, window cyan, doorway green, mirror grey.
local KIND_COLOUR = {
    door    = { 255, 150, 40 },
    window  = { 80, 200, 255 },
    doorway = { 120, 255, 120 },
    mirror  = { 150, 150, 150 },
}
local OPENING_RANGE = 25.0
local lastLocate = 0

local function text3d(x, y, z, line, r, g, b)
    SetDrawOrigin(x, y, z, 0)
    SetTextScale(0.0, 0.3)
    SetTextFont(4)
    SetTextCentre(true)
    SetTextOutline()
    SetTextColour(r or 255, g or 255, b or 255, 230)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(line)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function text2d(x, y, line)
    SetTextScale(0.0, 0.32)
    SetTextFont(4)
    SetTextOutline()
    SetTextColour(255, 255, 255, 230)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(line)
    EndTextCommandDisplayText(x, y)
end

RegisterCommand('voicedebug', function()
    CreateThread(function()
        if not on and not Whip.call('Callback', 'whip_core:devtools:checkAccess') then return end
        on = not on
        print('[whip_voice] voice debug ' .. (on and 'on' or 'off'))
        while on do
            local env = VoiceEnv
            if env then
                for id, a in pairs(env.v or {}) do
                    -- Where the voice comes from: a ped's head, followed every frame; anything else (a speaker's
                    -- middle, a fixed spot) where the voice loop last placed it, marked with a small pink ball.
                    local ped = VoicePeds and VoicePeds[id]
                    local x, y, z, thing = nil, nil, nil, false
                    if ped and DoesEntityExist(ped) and IsEntityAPed(ped) then
                        local h = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)
                        x, y, z = h.x, h.y, h.z
                    else
                        local w = VoiceAt and VoiceAt[id]
                        if w then x, y, z, thing = w[1], w[2], w[3], true end
                    end
                    if x then
                        local clear = a.g == 0
                        if thing then
                            DrawMarker(28, x, y, z, 0, 0, 0, 0, 0, 0, 0.1, 0.1, 0.1, 255, 90, 200, 200, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                        end
                        text3d(x, y, z + 0.45, ('%s  %+d dB  %s Hz'):format(a.why or '?', math.floor(a.g + 0.5),
                            a.f >= 22000 and 'open' or tostring(a.f)), clear and 140 or 255, clear and 255 or 200, clear and 140 or 90)
                        if a.at then
                            DrawLine(x, y, z, a.at[1], a.at[2], a.at[3], 255, 220, 60, 200)
                            DrawMarker(28, a.at[1], a.at[2], a.at[3], 0, 0, 0, 0, 0, 0, 0.15, 0.15, 0.15, 255, 220, 60, 160, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                        end
                    end
                end
                text2d(0.015, 0.72, 'voice echo here: ' .. tostring(env.rv or 'none'))
            else
                text2d(0.015, 0.72, 'voice: nobody in range yet')
            end

            -- The openings of the building you are in. Read twice a second even with nobody to hear,
            -- so an MLO can be checked alone.
            local me = GetEntityCoords(PlayerPedId())
            local now = GetGameTimer()
            if now - lastLocate > 500 then
                lastLocate = now
                local h = GetPedBoneCoords(PlayerPedId(), 31086, 0.0, 0.0, 0.0)
                pcall(Environment.locate, { ped = PlayerPedId(), head = { h.x, h.y, h.z } })
            end
            local openings = Environment.openingsHere()
            if openings then
                local counts = { door = 0, window = 0, doorway = 0, mirror = 0 }
                for _, o in ipairs(openings) do
                    counts[o.kind] = (counts[o.kind] or 0) + 1
                    local a = o.at
                    local dx, dy, dz = a[1] - me.x, a[2] - me.y, a[3] - me.z
                    if dx * dx + dy * dy + dz * dz < OPENING_RANGE * OPENING_RANGE then
                        local c = KIND_COLOUR[o.kind] or { 255, 255, 255 }
                        DrawMarker(28, a[1], a[2], a[3], 0, 0, 0, 0, 0, 0, 0.12, 0.12, 0.12, c[1], c[2], c[3], 180, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
                        local label = o.kind
                        if o.kind == 'door' then label = o.open and 'door (open)' or 'door (closed)' end
                        if o.to == 0 or o.from == 0 then label = label .. ', to outside' end
                        text3d(a[1], a[2], a[3] + 0.25, label, c[1], c[2], c[3])
                    end
                end
                text2d(0.015, 0.75, ('this building: %d doors, %d windows, %d doorways, %d mirrors'):format(
                    counts.door, counts.window, counts.doorway, counts.mirror))
            elseif GetInteriorFromEntity(PlayerPedId()) ~= 0 then
                text2d(0.015, 0.75, 'this building: still working out which way it faces - walk into another room')
            end
            Wait(0)
        end
    end)
end, false)
