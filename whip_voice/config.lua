-- whip_voice settings. Voice chat through your own voice server (LiveKit), with voices placed in 3D where each player
-- stands, and voice effects.
--
-- Set up: double-click whip_voice\service\Setup voice server.bat on your server machine (guide: whip_voice\docs\SETUP.md).
-- Check it with "Check voice server.bat" next to it, and /voicecheck in game (admins) or in the server console.
--
-- The connection to the voice server is not in this file: it lives in server.cfg because it holds a secret, and this
-- file is sent to every player. The setup writes these lines for you:
--
--     set whip_voice_url    "wss://<your server's IP>"     (or wss://voice.your-domain.com, set up with -Domain)
--     set whip_voice_key    "whip..."
--     set whip_voice_secret "..."
--
-- Use plain `set`, never `setr`: `setr` would send the secret to every player.

Config = {}

-- ---- Talking ----------------------------------------------------------------------------------

-- The push-to-talk key. Players can change it in GTA's own Settings > Key Bindings > FiveM.
Config.PushToTalkKey = 'N'

-- How far each voice level carries, in metres. The Z key cycles through them (it is whip_core's
-- voice-range key). Voices fade smoothly to silence at the edge rather than cutting out.
Config.Ranges = {
    whisper = 3.0,
    normal  = 8.0,
    shout   = 20.0,
}

-- Within this many metres a voice is at full volume: right in your face. Further out it gets
-- steadily quieter over the WHOLE of the speaker's range, all the way to silence at its edge: someone
-- shouting 20 m away starts faint and grows louder the whole way as they walk up to you. (Never more
-- than 15% of a range, so a whisper's 3 m fades from half a metre.)
Config.FullVolumeWithin = 1.0

-- How much quieter someone on your left is in your RIGHT ear (and the other way round), on top of
-- the 3D, in decibels: 0 = the 3D alone, 6 = a firm left and right, 12 = strong. Someone straight
-- ahead or behind is the same in both ears either way.
Config.SideSeparation = 6

-- Can a dead (downed) player talk? They can always hear.
Config.DeadCanTalk = false

-- The most voices one player is connected to at once: the nearest this many people within earshot.
-- It only matters in a crowd bigger than this — anywhere else everyone near you is connected anyway.
-- Only the ones talking cost anything, on the voice server and on the player's PC. Lower it if the
-- voice server struggles at big events. (This box, measured 29 Sep 2026: people listening x people
-- talking at once up to about 4,000 is comfortable — 50 x 50 is fine, 200 x 50 is not.)
Config.MaxVoices = 100

-- ---- The megaphone (an item) ------------------------------------------------------------------
--
-- Use it: the player holds a megaphone up and their voice carries further, with a bullhorn sound.
-- Use it again to put it away.
Config.Megaphone = {
    rangeMultiplier = 6,   -- how many times further the voice carries (normal 8 m becomes 48 m)
}

-- ---- The radio (an item: a walkie-talkie) -----------------------------------------------------
--
-- Use it and a 3D radio comes up in the corner of the screen: power, a channel (the frequency), volume,
-- and a speaker button. While it is on, hold the radio key to talk to everyone on the same frequency.
-- Clear up close; further away it starts cutting out (a burst of static in each gap), rarely at first
-- and more and more often, garbled, then fades away to nothing. People standing next to you still hear
-- you speak into it. On speaker, the people near you hear what comes out of your radio too.
Config.Radio = {
    PushToTalkKey = 'CAPITAL',   -- Caps Lock by default; players change it in GTA's Settings > Key Bindings > FiveM
    clearWithin   = 500,         -- metres apart: perfectly clear up to here
    maxRange      = 1500,        -- metres apart: breaking up from clearWithin, faded to nothing here
    minFrequency  = 100,
    maxFrequency  = 999,
    bitrateKbps   = 24,          -- a radio's sound is narrow, so this is plenty
    holdEmote     = 'walkie',    -- played while it is up on the screen (in the hand, held as the phone is); '' for none
    talkEmote     = 'radio',     -- played while talking on it (hand to the shoulder mic); '' for none
    staticVolume  = 0.06,        -- how loud the static is when the voice cuts out: 0 none, 1 very loud
    distortion    = 1.0,         -- how garbled a weak signal sounds as it breaks up: 0 clean, 1 normal, 1.5 the most
    speakerRange  = 8,           -- metres: how far the people around you hear your radio on speaker (8 = a normal voice)
    uiSounds      = true,        -- the 3D radio's key and power beeps; false for none (the talk beeps stay)
}

-- ---- The world around the voice --------------------------------------------------------------
--
-- Voices travel like GTA's own sounds: through the doorways and windows between rooms. Yell inside a
-- house and the people in there hear you normally, while someone outside hears you muffled — from the
-- door or window nearest them, not through the wall. Each can be switched off.
Config.Environment = {
    rooms    = true,   -- muffled through closed doors and windows, clearer through open doorways
    walls    = true,   -- muffled by a wall or building between two people outdoors
    cars     = true,   -- muffled between the inside and outside of a closed car (windows up, roof on)
    water    = true,   -- underwater sounds underwater
    echo     = true,   -- rooms echo by their size: a bathroom, a bedroom, a hall, a warehouse
    headphone3D = true, -- true: full 3D, made for headphones. false: plain left/right panning. Try false
                        -- if voices sound hollow or boxy to you.
}

-- How much quieter a voice gets through each thing in its way, in decibels. 6 is about half as
-- loud; 20 is faint. Raise a number to muffle more.
Config.Muffle = {
    doorway = 3,    -- an open doorway or open door
    door    = 12,   -- a closed door
    window  = 12,   -- a window (the glass lets a little more treble through than a door)
    wall    = 14,   -- a wall or building in the way outdoors
    car     = 9,    -- a closed car's body
}

-- ---- Sound quality ----------------------------------------------------------------------------
--
-- The bitrate matches Discord's voice quality. The microphone's only clean-up is background noise.
Config.Quality = {
    -- How much sound data each voice uses while talking (Discord uses 64). Silence costs almost
    -- nothing whatever this is. Higher = clearer; 32 is fine for voice, above 96 is wasted.
    bitrateKbps = 64,

    -- Microphone clean-up, done by the player's own game (true = on):
    noiseSuppression = true,    -- removes fans, keyboards and background hum (on: Josh, 27 Oct 2026). Only the
                                -- default: each player can switch it off in the pause menu's Server Settings
                                -- ("Background noise suppression").
    autoGain         = false,   -- evens out quiet and loud talkers (off: Josh, 29 Sep 2026)
    echoCancellation = false,   -- off: it cannot remove our 3D voices anyway, and it muddies the sound

    -- Resends a copy of each piece of voice, so a lost packet does not become a gap. Costs about
    -- 20 ms of extra delay. Worth turning on if players complain of choppy voices.
    packetLossProtection = false,

    -- Send nothing at all while the push-to-talk key is up. A quiet microphone otherwise sends a tiny
    -- "silence" packet about five times a second to everyone connected to it. Turning this on saves
    -- that (about a tenth of the voice server's work with 200 players in one spot, next to nothing in
    -- normal play), but the first word of a press usually arrives 20-40 ms later. Off: speed first.
    silentWhenQuiet = false,
}

-- CROWD QUALITY. The more people hear someone at once, the less sound data their voice uses, so a
-- big crowd does not swamp the voice server's connection. Anyone heard by fewer people keeps the
-- full quality above. Each line: from this many listeners, this quality (kbps). Quality comes back
-- once the crowd has thinned a few below the line. Delete the lines to never lower it.
-- (24 kbps is still clear speech, about good-phone quality.)
Config.CrowdQuality = {
    { listeners = 40, bitrateKbps = 40 },
    { listeners = 80, bitrateKbps = 24 },
}

-- ---- The voice bot (lore characters phoning players) -------------------------------------------

-- A lore character's call (whip_phone's Call card) plays a recording into the call through the voice
-- bot service: one service on this machine for every character, set up by "Setup voice server.bat"
-- (its voice bot step). Its two server.cfg lines are written by the setup:
--
--     set whip_voicebot_url   "http://127.0.0.1:7899"
--     set whip_voicebot_token "..."              (plain set: it is a secret)
--
-- How many calls it plays at once is the service's own setting (service\voicebot\config.json, maxCalls,
-- 30 by default). A call past that waits this many seconds for a free one, then the card's "Couldn't call".
Config.VoiceBot = {
    WaitSeconds = 5,
}
