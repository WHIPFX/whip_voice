-- whip_voice settings. Voice chat through a voice server (LiveKit), with voices placed in 3D where each player stands,
-- and voice effects. The guide: whip_voice\docs\SETUP.md. Check it with /voicecheck in game (admins) or in the server
-- console.
--
-- THE VOICE SERVER IS BUILT IN: whip_voice downloads LiveKit on its first start and runs it on this machine, with
-- nothing to set up but the voice ports, which players' games send their voices to. Open these inbound, as you did 30120:
--
--     UDP 7882-7893, and TCP 7881 (used when a player's network blocks UDP)
--
-- On Windows, double-click whip_voice\service\Open voice ports.bat for Windows Firewall; your host may have a firewall
-- of its own in its control panel. Other ports, or a fixed public address, go in server.cfg (whip_voice_udp,
-- whip_voice_tcp, whip_voice_ip: docs/SETUP.md).
--
-- YOUR OWN VOICE SERVER instead (another machine, a domain name, LiveKit Cloud): its connection is not in this file
-- either. It lives in server.cfg because it holds a secret, and this file is sent to every player. The setup wizard
-- (service\Setup voice server.bat) writes these lines for you:
--
--     set whip_voice_url    "wss://<your server's IP>"     (or wss://voice.your-domain.com, set up with -Domain)
--     set whip_voice_key    "whip..."
--     set whip_voice_secret "..."
--
-- Use plain `set`, never `setr`: `setr` would send the secret to every player. With whip_voice_url set, the built-in
-- voice server stays off.

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
    carMuffle = 4,         -- dB a closed car takes off a megaphone voice (a normal one: Config.Muffle.car). A bullhorn
                           -- is loud, so it gets through, dulled; each in a different car takes off 1.8 times this.
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

-- ---- The speaker (an item) --------------------------------------------------------------------
--
-- Use it and put it down exactly where you want it: on the ground, a table, or a car's roof, where it
-- rides the car (the mouse wheel turns it, the arrow keys raise and lower it). Behind it: Song link
-- (paste the song's link), Play / Stop, Volume, Range, Pick up. Everyone near hears it, as music:
-- from far off it comes late and loses its treble, and on a passing car it rises and falls in pitch.
-- Its song, volume and range stay with the item when it is picked up.
Config.Speaker = {
    model        = 'ba_prop_battle_club_speaker_small',   -- what it looks like
    links        = { 'https://r2.fivemanage.com/' },       -- the only links it plays: where your songs are uploaded
    volume       = 100,   -- a new speaker's volume, % (0-200)
    range        = 30,    -- a new speaker's range, metres
    maxRange     = 300,   -- the furthest a player may set one to carry, metres (300 at most)
    maxPerPlayer = 3,     -- speakers one character may have out at once
    maxPlaced    = 64,    -- speakers out on the whole server at once
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
    wall    = 14,   -- a wall or building in the way outdoors, with no way round it
    around  = 6,    -- outdoors, the sound bending round a corner (a right angle) to reach you: less for a smaller
                    -- bend (a post is about 1, a corner just passed 2 to 4), a little more for a U-turn; each corner
                    -- on its way adds its own. How far round it goes is the distance's own fade, not this.
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
-- bot: one small program on this machine for every character. The built-in voice server sets it up
-- and starts it by itself, in the background on its first start (its own Node.js and packages, about
-- 100 MB in whip_voice\bin). `set whip_voice_bot false` in server.cfg leaves it out.
--
-- With your own voice server, "Setup voice server.bat" installs it as a Windows service and writes its
-- two server.cfg lines (whip_voicebot_url, whip_voicebot_token); its settings are then its own
-- (C:\LiveKit\voicebot\config.json), not the ones below.
Config.VoiceBot = {
    WaitSeconds = 5,   -- a call past maxCalls waits this many seconds for a free one, then the card's "Couldn't call"

    -- The built-in voice bot's settings (restart whip_voice after a change):
    maxCalls   = 30,                                -- calls it plays at once
    audioLinks = { 'https://r2.fivemanage.com/' },  -- the sites recordings may come from (the start of their links).
                                                    -- Only sites you trust: it downloads whatever a card links to there.
                                                    -- Files a resource ships ('@my_story/audio/line.ogg') always work.
    maxSeconds = 120,                               -- the longest recording, in seconds
    maxMB      = 15,                                -- the biggest recording file, in MB
}
