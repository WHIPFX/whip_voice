-- ============================================
-- whip_voice — the megaphone, the player's side
-- ============================================
--
-- The server says up or down (server/megaphone.lua). Up plays whip_core's `megaphone` emote (the
-- megaphone in hand, upper body, so the player can walk). When the emote ends any other way — X,
-- getting in a car, drawing a weapon, a fall — this tells the server, so the voice goes back to normal
-- with it. Watched four times a second, and only while the megaphone is up.

local up = false
local WATCH_MS = 250

RegisterNetEvent('whip_voice:client:megaphone', function(on)
    if on then
        if up then return end
        local ok, why = Whip.call('PlayEmote', 'megaphone')
        if ok ~= true then
            -- Can't hold it up right now (in a car, armed, falling...): the server puts it down again.
            TriggerServerEvent('whip_voice:server:megaphoneDown')
            Whip.call('Notify', type(why) == 'string' and why or 'You can\'t use the megaphone right now', 'error')
            return
        end
        up = true
        CreateThread(function()
            while up do
                Wait(WATCH_MS)
                if up and Whip.call('IsEmoting') ~= 'megaphone' then
                    up = false
                    TriggerServerEvent('whip_voice:server:megaphoneDown')
                end
            end
        end)
    else
        if not up then return end
        up = false
        if Whip.call('IsEmoting') == 'megaphone' then Whip.call('CancelEmote') end
    end
end)

-- whip_voice stopping: the megaphone goes down with it (the emote is whip_core's, so it would stay).
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and up and Whip.call('IsEmoting') == 'megaphone' then Whip.call('CancelEmote') end
end)
