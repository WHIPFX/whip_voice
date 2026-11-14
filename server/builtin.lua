-- ============================================
-- whip_voice — the built-in voice server, the Lua side
-- ============================================
--
-- With no whip_voice_url in server.cfg, whip_voice runs its own voice server on this machine: server/builtin.js
-- downloads LiveKit, starts it with new random keys every start, and carries players' signalling to it (their games
-- only open secure connections, which is what needed a certificate). This file starts it, keeps how it stands, and
-- takes the relay's messages from players' games.
--
--   VoiceBuiltin.on                  true when the built-in voice server is the one (no whip_voice_url)
--   VoiceBuiltin.state               how it stands (server/builtin.js): phase, why, key, secret, api, udp, tcp, bot...
--   VoiceBuiltin.ready()             LiveKit is running and answering
--   VoiceBuiltin.why()               while not ready: why, in words
--   VoiceBuiltin.whenReady(fn)       fn() each time LiveKit (re)starts and answers (a fresh voice room each time)
--   VoiceBuiltin.register(core)      from Whip.register, once whip_voice is the voice system: the relay's event, and start
--
-- The keys come by local event from server/builtin.js: any resource on this server could read server.cfg's keys too,
-- and no player's game ever sees them.

VoiceBuiltin = {
    on = GetConvar('whip_voice_url', '') == '',
    state = { phase = 'off', bot = { phase = 'off' } },
}

-- The address players' games are told to connect to. Nothing there: html/js/relay.js takes every connection to it
-- and carries it through the game and this server instead.
VoiceBuiltin.URL = 'wss://whip-voice.invalid'

local readyFns = {}
local lastGen = 0
local lastBotGen = 0
local firewallWaiters = {}
local lastFirewallN = 0

AddEventHandler('whip_voice:builtin:state', function(s)
    if type(s) ~= 'table' then return end
    if type(s.bot) ~= 'table' then s.bot = { phase = 'off' } end
    VoiceBuiltin.state = s
    local gen = tonumber(s.gen) or 0
    if s.phase == 'ready' and gen ~= lastGen then
        lastGen = gen
        for _, fn in ipairs(readyFns) do fn() end
    end
    -- The voice bot started again by itself (it stopped): it has none of its calls any more, so the bots here go, and
    -- their owners are told ('failed'). Its first start had none to lose.
    local botGen = tonumber(s.bot.gen) or 0
    if botGen > 0 and botGen ~= lastBotGen then
        if lastBotGen > 0 and VoiceBots then VoiceBots.removeAll('failed') end
        lastBotGen = botGen
    end
    local fwN = tonumber(s.firewallN) or 0
    if fwN ~= lastFirewallN then
        lastFirewallN = fwN
        local waiters = firewallWaiters
        firewallWaiters = {}
        for _, done in ipairs(waiters) do done(s.firewall) end
    end
end)

--- Windows Firewall read afresh, never changed (service/firewall.ps1, through server/builtin.js): done(firewall)
--- with { on, open, blocked, ... }, or done(nil) on Linux or when it could not be read.
---@param done fun(firewall: table|nil)
function VoiceBuiltin.checkFirewall(done)
    firewallWaiters[#firewallWaiters + 1] = done
    TriggerEvent('whip_voice:builtin:firewall')
end

function VoiceBuiltin.ready()
    return VoiceBuiltin.on and VoiceBuiltin.state.phase == 'ready'
end

local WHY = {
    off = 'the built-in voice server has not started (is whip_voice the voice system? whip_core running?)',
    starting = 'the built-in voice server is starting',
    downloading = 'the built-in voice server is being downloaded (the first start only)',
}

function VoiceBuiltin.why()
    local s = VoiceBuiltin.state
    if s.phase == 'ready' then return nil end
    if s.phase == 'failed' then return 'the built-in voice server could not run: ' .. tostring(s.why) end
    if s.phase == 'restarting' then return 'the built-in voice server stopped and is starting again: ' .. tostring(s.why) end
    return WHY[s.phase] or tostring(s.why or s.phase)
end

--- "UDP 7882-7893 (TCP 7881 when UDP is blocked)": the ports players' games send voices to.
function VoiceBuiltin.ports()
    local s = VoiceBuiltin.state
    return ('UDP %s (TCP %s when UDP is blocked)'):format(tostring(s.udp or '7882-7893'), tostring(s.tcp or '7881'))
end

function VoiceBuiltin.whenReady(fn)
    readyFns[#readyFns + 1] = fn
end

--- The voice bot's address and token, or nil while it is not running.
---@return string|nil url
---@return string|nil token
function VoiceBuiltin.bot()
    local b = VoiceBuiltin.state.bot
    if b.phase == 'ready' and b.url and b.token then return b.url, b.token end
    return nil, nil
end

--- Why the voice bot is not running, in words.
---@return string
function VoiceBuiltin.botWhy()
    local b = VoiceBuiltin.state.bot
    if b.phase == 'ready' then return 'the voice bot is running' end
    if b.phase == 'off' then return 'the voice bot is ' .. tostring(b.why or 'not started') end
    if b.phase == 'installing' then return 'the voice bot is still being set up (the first start downloads it)' end
    return 'the voice bot is not running: ' .. tostring(b.why or b.phase)
end

-- ---- Starting it, and the relay ----------------------------------------------------------------

-- A piece of signalling is cut to this many characters (server/builtin.js and html/js/relay.js cut at the same).
local CHUNK = 12000

function VoiceBuiltin.register(core)
    if not VoiceBuiltin.on then return end

    -- A player's game passing one piece of its signalling to the voice server (html/js/relay.js). Not tied to a loaded
    -- character: the voice connection stays up at the character screen, and it must keep answering the voice
    -- server's pings there. The voice server itself checks every connection's token, which only a loaded player gets
    -- (whip_voice:token). Busy only while joining and as voices come and go nearby, so the limit is generous.
    core:SecureEvent('whip_voice:server:sig', {
        rateLimit = 20, burst = 200, whileDead = true, requirePlayer = false, sheet = 'light',
        params = {
            {'sock', 'id', 1, 2147483647},
            {'op', 'enum', { 'open', 'more', 'data', 'close' }},
            {'data', 'string', CHUNK, ''},
            {'seq', 'id', 1, 2147483647},      -- each piece one up from the last on its connection: none may be lost
        },
    }, function(source, _, sock, op, data, seq)
        TriggerEvent('whip_voice:relay:fromGame', source, sock, op, data, seq)
    end)

    -- The voice bot's settings (config.lua) go with the start: server/builtin.js writes them into the bot's config.
    local b = Config.VoiceBot or {}
    TriggerEvent('whip_voice:builtin:start', {
        bot = { maxCalls = b.maxCalls, audioLinks = b.audioLinks, maxSeconds = b.maxSeconds, maxMB = b.maxMB },
    })
end
