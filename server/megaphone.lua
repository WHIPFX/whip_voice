-- ============================================
-- whip_voice — the megaphone item
-- ============================================
--
-- Use it and the player holds a megaphone up (whip_core's `megaphone` emote): their voice carries
-- Config.Megaphone.rangeMultiplier times as far and sounds like a bullhorn (html/js/audio.js). Use it
-- again — or let the emote end any other way: X, getting in a car, drawing a weapon, a fall — and it
-- goes down.
--
-- THE SERVER DECIDES. The longer range and the sound go out with everyone's hear lists
-- (server/hearing.lua), so a player's game cannot give itself a megaphone. It could keep one up after
-- its emote ends by never saying so — which gets it no more than the item it owns already gives.

Megaphone = {
    on = {},   -- [src] = true while their megaphone is up
}

--- How many times further a megaphone voice carries (config.lua).
function Megaphone.multiplier()
    return tonumber(Config.Megaphone and Config.Megaphone.rangeMultiplier) or 6
end

--- Up or down. Everyone who can hear them hears the change at once, and their game is told (it plays
--- or stops the emote).
---@param src number
---@param on boolean
function Megaphone.set(src, on)
    on = on == true
    if (Megaphone.on[src] == true) == on then return end
    Megaphone.on[src] = on or nil
    if Hearing then Hearing.rangeChanged(src) end
    TriggerClientEvent('whip_voice:client:megaphone', src, on)
end

--- The item's use: up if it is down, down if it is up. The item is kept (false).
function Megaphone.use(source)
    Megaphone.set(source, not Megaphone.on[source])
    return false
end

-- DOWN when the last one leaves their pockets (dropped, given, stored), when they die or log out.
AddEventHandler('whip_core:item:removed', function(e)
    if type(e) == 'table' and e.item == 'megaphone' and (tonumber(e.count) or 0) <= 0 then Megaphone.set(e.source, false) end
end)
AddEventHandler('whip_core:player:died', function(e)
    if type(e) == 'table' and e.source then Megaphone.set(e.source, false) end
end)
AddEventHandler('whip_core:player:logout', function(e)
    if type(e) == 'table' and e.source then Megaphone.set(e.source, false) end
end)

-- Gone: forgotten.
AddEventHandler('playerDropped', function()
    Megaphone.on[source] = nil
end)
