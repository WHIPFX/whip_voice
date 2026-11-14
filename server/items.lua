-- ============================================
-- whip_voice — the voice items: a megaphone, a radio and a speaker
-- ============================================
--
-- THE ITEMS BELONG TO "THE VOICE SYSTEM", not to this resource. A voice resource of the owner's own,
-- run instead of this one, registers these same keys, so a player's inventory means the same whichever
-- runs. The one running registers them — whip lets the first resource that registers a key own it.
--
-- What they DO here: server/megaphone.lua, server/radio.lua and server/speakers.lua.
--
-- Pictures: html/img/items/megaphone.png, radio.png and speaker.webp (whip finds them by the item's key; a .webp
-- of the same name would be used first). The megaphone in the hand is stream/prop_megaphone_01.ydr.

VoiceItems = {
    megaphone = {
        name   = 'Megaphone',
        desc   = 'Hold it up and shout: your voice carries much further. Use it again to put it away.',
        weight = 1.2,
        type   = 'tool',
        stack  = false,
        usable = true,
        prop   = 'prop_megaphone_01',        -- what it looks like dropped on the ground
    },
    radio = {
        name   = 'Radio',
        desc   = 'A walkie-talkie. Pick a channel from 100 to 999 and talk to everyone on it. Short range. Put it on speaker and the people around you hear it too.',
        weight = 0.4,
        type   = 'tool',
        stack  = false,
        usable = true,
        prop   = 'prop_cs_walkie_talkie',
    },
    speaker = {
        name   = 'Speaker',
        desc   = 'A portable speaker. Put it down anywhere, or on a car, give it a song and play it for everyone around. Behind it: the song, Play and Stop, Volume, Range, Pick up.',
        weight = 6.0,
        type   = 'tool',
        stack  = false,
        usable = true,
        prop   = (Config.Speaker and Config.Speaker.model) or 'ba_prop_battle_club_speaker_small',
    },
}

--- Declare the items to whip. Called from inside Whip.register, so again whenever whip_core restarts
--- (the same definition again changes nothing).
---@param core table exports.whip_core
function VoiceItems.register(core)
    for key, def in pairs(VoiceItems) do
        if type(def) == 'table' then
            local ok, why = core:RegisterItem(key, def)
            if not ok then print(('[whip_voice] could not register the %s item: %s'):format(key, tostring(why))) end
        end
    end
end
