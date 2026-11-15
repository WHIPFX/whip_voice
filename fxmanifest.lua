fx_version 'cerulean'
game 'gta5'

name 'whip_voice'
author 'Whippy'
description 'Voice chat on a voice server of its own: voices placed in 3D, and voice effects'
version '0.3.0'
whip_updates 'WHIPFX/whip_voice'   -- whip_core checks this repository's releases for a newer version

-- HOW IT WORKS: each player's game sends their microphone to a voice server (LiveKit), which passes it on to
-- the players near them. This FiveM server never carries audio; it decides who may hear whom. The voice server
-- is BUILT IN (server/builtin.js runs it on this machine: nothing to set up but the voice ports), or your own
-- (whip_voice_url in server.cfg: LiveKit Cloud, or LiveKit on another machine). bin\ (the built-in one's
-- downloads) and service\ are never sent to players.

shared_script '@whip_core/lib/satellite.lua'
shared_script 'config.lua'
shared_script 'shared/sound_blocks.lua'   -- the building blocks of a sound recipe, and their limits

server_scripts {
    'server/builtin.lua',       -- the built-in voice server, the Lua side: how it stands, and the relay's event
    'server/builtin.js',        -- the built-in voice server: runs LiveKit (and the voice bot), relays players' signalling
    'server/token.lua',         -- voice server tokens and random voice identities (signed in Lua: SHA-256 written out)
    'server/voice_server.lua',  -- the voice server's room API
    'server/players.lua',       -- who is connected to voice
    'server/audibility.lua',    -- the who-hears-whom rule (pure, no FiveM in it)
    'server/hearing.lua',       -- applying the rule four times a second
    'server/lines.lua',         -- voice lines: players who hear each other wherever they are (radio frequencies, calls)
    'server/lines_api.lua',     -- voice lines for other resources: OpenLine and the rest (exports)
    'server/bots.lua',          -- voice bots: a recording played into a line (the voice bot service, service\voicebot)
    'server/items.lua',         -- the megaphone, radio and speaker items
    'server/megaphone.lua',     -- the megaphone: 3x the range, a bullhorn sound
    'server/radio.lua',         -- the radio: frequencies, and who is on which
    'server/speakers.lua',      -- the speaker: put down anywhere (a car too), a song played from it
    'server/check.lua',         -- /voicecheck: is voice set up right, seen from the game
    'server/main.lua',
}

client_scripts {
    'client/acoustics.lua',     -- how a voice travels: the rules (pure)
    'client/ways.lua',          -- the way round outdoors: the open ground as a grid, the shortest way through it
    'client/environment.lua',   -- reading the world for them: rooms, doorways, doors, cars, water
    'client/main.lua',
    'client/megaphone.lua',     -- the megaphone item: its emote, and when it ends
    'client/radio.lua',         -- the radio item: on/off and frequency, the talk emote
    'client/walkie.lua',        -- the radio item's 3D radio on the screen
    'client/speakers.lua',      -- the speaker item: putting it down, the prompt behind it
    'client/debug.lua',         -- /voicedebug
}

-- The page that carries the voices (in the player's game; the only thing it shows is the 3D radio).
ui_page 'html/index.html'

-- Only THIS resource's page may call its NUI callbacks.
nui_callback_strict_mode 'true'

-- Every file listed by hand: a file missing from this list 404s inside the page.
files {
    'html/index.html',
    'html/js/audio.js',
    'html/js/fx.js',            -- the sound engine: recipes built from blocks
    'html/js/lines.js',         -- voices on a line (a radio frequency, a call)
    'html/js/radio.js',
    'html/js/relay.js',         -- the built-in voice server's signalling, through the game
    'html/js/voice.js',
    'html/js/walkie.js',
    'html/js/vendor/livekit-client.umd.js',
    -- Its licence and notices go wherever it goes (Apache 2.0, and the MIT and BSD parts built into it).
    'html/js/vendor/livekit-client.LICENSE.txt',
    'html/js/vendor/livekit-client.NOTICE.txt',
    -- The 3D radio (3D Clanker's module) and three.js r170, which draws it.
    'html/radio3d/radio.js',
    'html/radio3d/lcd.js',
    'html/radio3d/radio.glb',
    'html/radio3d/lib/build/three.module.min.js',
    'html/radio3d/lib/LICENSE',     -- three.js's MIT licence: the files from its examples folder carry no header
    'html/radio3d/lib/examples/jsm/controls/OrbitControls.js',
    'html/radio3d/lib/examples/jsm/environments/RoomEnvironment.js',
    'html/radio3d/lib/examples/jsm/loaders/GLTFLoader.js',
    'html/radio3d/lib/examples/jsm/utils/BufferGeometryUtils.js',
    'html/img/items/*.webp',    -- the items' pictures in the inventory (megaphone, radio)
    'html/img/items/*.png',
}

-- stream/prop_megaphone_01.ydr: the megaphone in the hand (whippy_megaphone's model, the "HUSH PA-30"),
-- in place of GTA's own everywhere it is used. FiveM streams a resource's stream/ folder by itself.

dependency 'whip_core'
whip_requires '1.0'   -- the whip_core it is built for: the setup report flags an older one

lua54 'yes'
