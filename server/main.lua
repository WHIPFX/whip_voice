-- ============================================
-- whip_voice — server
-- ============================================
--
-- Start-up (a fresh voice room each time), what players' games may ask for, and /voicestatus.
-- The rest: server/players.lua (who is connected), server/audibility.lua (the rule),
-- server/hearing.lua (applying it), server/voice_server.lua (the voice server's API).

local core = exports.whip_core

local function say(line) print('[whip_voice] ' .. line) end

-- ONE LINE AT START: either "voice server OK" or exactly what is wrong and where to fix it. Then a
-- fresh room for this start of whip_voice — players from before a restart must not linger in the old
-- one — and the old rooms are closed. The built-in voice server: each time it (re)starts and answers
-- (server/builtin.js says so), as a voice server that started again has no rooms.
local function openRoom()
    VoiceServer.check(function(ok, why)
        say(why)
        if not ok then return end
        local id = Voice.randomId()
        Voice.room = 'whipvoice-' .. (id and id:sub(1, 8) or tostring(os.time()))
        -- Voice bots in the room before (the voice server started again by itself) are in a room that is gone: they
        -- go, and their owners are told ('failed').
        if VoiceBots then VoiceBots.removeAll('failed') end
        VoiceServer.call('ListRooms', nil, function(listed, reply)
            if not listed or type(reply.rooms) ~= 'table' then return end
            for _, r in ipairs(reply.rooms) do
                if type(r.name) == 'string' and r.name:find('^whipvoice%-') and r.name ~= Voice.room then
                    VoiceServer.call('DeleteRoom', { room = r.name })
                end
            end
        end)
        VoiceServer.call('CreateRoom', { name = Voice.room, empty_timeout = 600, departure_timeout = 60 }, function(created, err)
            if not created then return say('could not open the voice room: ' .. tostring(err)) end
            say('voice room ' .. Voice.room .. ' open')
            -- Players already in game (whip_voice was restarted): join the new room.
            TriggerClientEvent('whip_voice:client:reconnect', -1)
        end)
    end)
end

if VoiceBuiltin.on then VoiceBuiltin.whenReady(openRoom) else CreateThread(openRoom) end

--- Everything declared to whip_core, again whenever it restarts (lib/satellite.lua).
local function RegisterWithWhip()
    -- THE VOICE SYSTEM, first (whip_core server/voice_system.lua). A server runs one: this, or a voice
    -- resource of the owner's own. Another one already running: this one stays off —
    -- no items, no voice room passes — and says so, rather than two fighting over every player's voice.
    local isVoice, notWhy = core:RegisterVoiceSystem({
        label = 'whip_voice (advanced)',
        features = { lines = true, speaker = true, pickup = true, quality = true, sounds = 'full' },
    })
    if not isVoice then
        say('NOT STARTED: ' .. tostring(notWhy) .. ' (stop the other voice resource, or this one)')
        return
    end

    -- The built-in voice server (no whip_voice_url in server.cfg): the relay's event, and starting it (server/builtin.lua).
    VoiceBuiltin.register(core)

    -- A loaded player's pass into the voice room. whileDead: the dead still listen.
    core:SecureCallback('whip_voice:token', { rateLimit = 2000, burst = 3, whileDead = true },
        function(source) return Voice.issueToken(source) end)

    -- Their game reports: in the room or not, and whether the microphone is live.
    core:SecureEvent('whip_voice:server:state', {
        rateLimit = 250, burst = 6, whileDead = true,
        params = { {'joined', 'bool'}, {'speaking', 'bool'} },
    }, function(source, _, joined, speaking) Voice.setState(source, joined, speaking) end)

    -- The range key (Z, whip_core's). An enum, so only the three real ranges get through.
    core:SecureEvent('whip_voice:server:setRange', {
        rateLimit = 150, burst = 6, whileDead = true,
        params = { {'range', 'enum', { 'whisper', 'normal', 'shout' }} },
    }, function(source, _, range) Voice.setRange(source, range) end)

    -- /voicecheck: each player's game answers how it is connected (server/check.lua).
    VoiceCheck.register(core)

    -- The megaphone and the radio (server/items.lua).
    VoiceItems.register(core)

    -- The megaphone: use it to hold it up, again to put it down (server/megaphone.lua).
    core:RegisterUseHandler('megaphone', function(source) return Megaphone.use(source) end)
    -- Their game says it went down some other way: the emote ended (X, a car, a weapon, a fall).
    core:SecureEvent('whip_voice:server:megaphoneDown', { rateLimit = 250, burst = 4, whileDead = true },
        function(source) Megaphone.set(source, false) end)

    -- The radio: use it to open the 3D radio; that turns it on (to a frequency) or off, and its
    -- speaker on or off (server/radio.lua). 'id' refuses anything but a whole number in range, never
    -- rounds it. Refused here (too fast, bad values): the radio is told how it really stands.
    --
    -- NOT WHILE DOWN (Josh, 16 Oct 2026: "you shouldn't be able to use it, speak to it, or change settings whilst
    -- dead, but you can still hear people"). These took a dead player (whileDead); now whip refuses them, as it
    -- refuses using the item (which opens the radio), and the radio is told how it stands. A radio left on stays on
    -- and plays — on speaker too — and its owner cannot talk on it (Config.DeadCanTalk; server/hearing.lua).
    core:RegisterUseHandler('radio', function(source) return Radio.use(source) end)
    local R = Config.Radio or {}
    core:SecureEvent('whip_voice:server:radio', {
        rateLimit = 150, burst = 8,
        params = { {'on', 'bool'}, {'freq', 'id', tonumber(R.minFrequency) or 100, tonumber(R.maxFrequency) or 999} },
        onReject = function(source) Radio.tell(source) end,
    }, function(source, _, on, freq) return Radio.set(source, on, freq) end)
    core:SecureEvent('whip_voice:server:radioSpeaker', {
        rateLimit = 250, burst = 4,
        params = { {'on', 'bool'} },
        onReject = function(source) Radio.tell(source) end,
    }, function(source, _, on) return Radio.setSpeaker(source, on) end)

    Voice.seedLoaded()
end

Whip.register(RegisterWithWhip)

-- /voicestatus — for the server console, and whip.devtools with developer mode on (Whip.command's dev gate).
Whip.command('voicestatus', { dev = true, whileDead = true }, function(source)
    local function reply(line)
        if source == 0 then say(line)
        else TriggerClientEvent('chat:addMessage', source, { args = { '^5[voice]^0 ' .. line } }) end
    end

    local s = VoiceServer.settings()
    if s.builtin then
        local b = VoiceBuiltin.state
        reply(('the built-in voice server: %s (LiveKit %s); players\' games send voices to %s'):format(
            tostring(b.phase), tostring(b.version or '?'), VoiceBuiltin.ports()))
        reply(('the voice bot: %s%s'):format(tostring(b.bot.phase), b.bot.why and (' (' .. tostring(b.bot.why) .. ')') or ''))
    else
        reply(('players connect to: %s'):format(s.url ~= '' and s.url or '(whip_voice_url not set)'))
    end
    reply(('this server reaches it at: %s'):format(s.api))
    reply(('room: %s'):format(Voice.room or '(not open)'))
    VoiceServer.check(function(ok, why)
        reply(why)
        if not ok then return end
        local hears, running = Hearing.summary()
        local n = 0
        for src, p in pairs(Voice.players) do
            n = n + 1
            reply(('  %s (id %d): %s, mic %s, range %s, picking up %d voice(s)'):format(
                GetPlayerName(src) or '?', src, p.joined and 'in the room' or 'connecting',
                p.speaking and 'live' or 'off', p.range, hears[src] or 0))
        end
        reply(('%d connected to voice; who-hears-whom is %s'):format(n, running and 'running' or 'idle (needs two players)'))
    end)
end)
