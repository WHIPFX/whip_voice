-- ============================================
-- whip_voice — who is connected to voice
-- ============================================
--
-- A player's game joins the voice server with a token from here, under a RANDOM identity: every
-- participant in the voice room can see every identity in it, so an identity must say nothing about
-- who the player is (no server id, no name). Only this file knows which identity is which player.
--
--   Voice.room                     the voice room this start of whip_voice uses
--   Voice.players[src]             { identity, joined, speaking, range }
--   Voice.sourceOf[identity]       the player behind an identity
--   Voice.loaded[src]              true while a character is loaded (character select = not)
--   Voice.dead[src]                true while whip_core has that character down (its own state, from
--                                  its died / revived events — never the client-writable player bag)
--
-- A new identity every time a player asks for a token (a reconnect, a whip_voice restart): the old
-- one is thrown out of the room, so nothing from before lingers.

Voice = {
    room     = nil,
    players  = {},
    sourceOf = {},
    loaded   = {},
    dead     = {},
}

--- A random id nobody can guess (server/token.lua), or nil if making one failed.
function Voice.randomId()
    local ok, id = pcall(VoiceToken.randomId)
    return ok and type(id) == 'string' and id or nil
end

--- Wait for an async voice server call. Only inside a thread or an event handler (it yields).
local function await(fn)
    local p = promise.new()
    fn(function(...) p:resolve({ ... }) end)
    return table.unpack(Citizen.Await(p))
end

--- Make sure the room exists (the voice server closes an empty room after a while, and it will not
--- make one itself). Asking to create a room that exists just answers it, so this is always safe.
---@return boolean ok
---@return string|nil why
function Voice.ensureRoom()
    if not Voice.room then return false, 'voice is still starting' end
    local ok, why = await(function(done)
        VoiceServer.call('CreateRoom', { name = Voice.room, empty_timeout = 600, departure_timeout = 60 }, done)
    end)
    if not ok then return false, why end
    return true
end

--- Put a player out of the room and forget them (they left, or asked for a fresh identity).
function Voice.forget(src)
    local p = Voice.players[src]
    if not p then return end
    Voice.players[src] = nil
    Voice.sourceOf[p.identity] = nil
    if Hearing then Hearing.drop(src, p.identity) end
    if Voice.room then VoiceServer.call('RemoveParticipant', { room = Voice.room, identity = p.identity }) end
end

--- whip_voice:token — a loaded player's pass into the voice room.
---@return table|boolean reply { url, token } or false
---@return string|nil why
function Voice.issueToken(src)
    local ok, why = Voice.ensureRoom()
    if not ok then return false, 'Voice is unavailable: ' .. tostring(why) end
    -- Still here? ensureRoom waited on the voice server, and a player who dropped meanwhile was forgotten by the drop:
    -- an entry written now was a ghost nothing removed (audit 20, VOX-4)
    if not GetPlayerName(src) then return false, 'They left' end
    local identity = Voice.randomId()
    if not identity then return false, 'Voice is unavailable (no voice identity could be made)' end

    local old = Voice.players[src]
    local range = old and old.range or 'normal'
    Voice.forget(src)

    local token = VoiceServer.token({
        sub = identity,
        video = {
            roomJoin = true, room = Voice.room,
            canPublish = true, canPublishSources = { 'microphone' },   -- a microphone and nothing else
            canPublishData = false,                                    -- no data messages
            -- A player may subscribe, but only to voices whose owner has allowed them — and every
            -- voice starts allowing nobody (see server/hearing.lua and html/js/voice.js).
            canSubscribe = true,
        },
    }, 120)
    if not token then return false, 'Voice is not set up on this server (whip_voice_key / whip_voice_secret)' end

    Voice.players[src] = { identity = identity, joined = false, speaking = false, range = range }
    Voice.sourceOf[identity] = src
    return { url = GetConvar('whip_voice_url', ''), token = token }
end

--- The player's game says how its connection stands: in the room, and whether its mic is live
--- (a player who refused the microphone can still listen).
function Voice.setState(src, joined, speaking)
    local p = Voice.players[src]
    if not p then return false end
    p.joined, p.speaking = joined == true, speaking == true
    if Hearing then Hearing.wake() end
    return true
end

--- The range key (Z). Pushed to everyone who can hear this player at once.
function Voice.setRange(src, range)
    local p = Voice.players[src]
    if not p or not Config.Ranges[range] then return false end
    p.range = range
    if Hearing then Hearing.rangeChanged(src) end
    return true
end

--- The metres a player's voice carries right now: their range (Z), times the megaphone's while one is up.
function Voice.rangeOf(src)
    local p = Voice.players[src]
    local range = Config.Ranges[p and p.range or 'normal'] or 8.0
    if Megaphone and Megaphone.on[src] then range = range * Megaphone.multiplier() end
    return range
end

--- The effect on a player's voice right now (html/js/audio.js), or nil for none.
function Voice.fxOf(src)
    if Megaphone and Megaphone.on[src] then return 'megaphone' end
    return nil
end

-- ---- Loaded, logged out, gone ------------------------------------------------------------------

AddEventHandler('whip_core:player:loaded', function(e)
    if type(e) == 'table' and e.source then
        Voice.loaded[e.source] = true
        -- a character that logged out down loads in down
        Voice.dead[e.source] = (type(e.player) == 'table' and e.player.isDead == true) or nil
        if Hearing then Hearing.wake() end
    end
end)

-- Logging out keeps the voice connection (the character select screen is a different routing
-- bucket, which already silences them), but they are nobody to hear until a character loads.
AddEventHandler('whip_core:player:logout', function(e)
    if type(e) == 'table' and e.source then Voice.loaded[e.source], Voice.dead[e.source] = nil, nil end
end)

-- DOWN, BY WHIP_CORE'S WORD (audit 11, SEC-2). Config.DeadCanTalk = false used to read the player's
-- own whipDead bag, which their client can write: with Sentinel switched off (a supported setting) a
-- modified game set it false and its downed player was heard by everyone around. whip_core's died /
-- revived events are its own state, and the only places a player goes down or comes back.
AddEventHandler('whip_core:player:died', function(e)
    if type(e) == 'table' and e.source then Voice.dead[e.source] = true end
end)
AddEventHandler('whip_core:player:revived', function(e)
    if type(e) == 'table' and e.source then Voice.dead[e.source] = nil end
end)

AddEventHandler('playerDropped', function()
    local src = source
    Voice.loaded[src], Voice.dead[src] = nil, nil
    Voice.forget(src)
end)

--- Who is loaded right now, and who of them is down, for a whip_voice (re)start mid-session (and
--- whip_core's: its events stopped while it was gone, so the down list is read afresh).
function Voice.seedLoaded()
    local players = Whip.call('GetPlayers', { light = true })
    if type(players) ~= 'table' then return end
    Voice.dead = {}
    for src, p in pairs(players) do
        src = tonumber(src) or src
        Voice.loaded[src] = true
        if type(p) == 'table' and p.isDead == true then Voice.dead[src] = true end
    end
end
