-- ============================================
-- whip_voice — /voicecheck: is voice set up right, seen from the game
-- ============================================
--
-- For admins in game (the `command` permission) and the server console (txAdmin's Live Console). The
-- machine's half — the services, the ports, DNS, the certificate — is service\check.ps1 ("Check voice
-- server.bat" on the server machine). This is what only the game can see:
--
--   1. the voice system   is whip_voice the one running (not another voice resource)?
--   2. server.cfg         the three lines, and whether the voice server takes our key
--   3. the address        https://<voice address> answers from here, certificate and all
--   4. every player       connected? over UDP (good) or TCP (UDP is blocked)? with a microphone? and can
--                         their game read whip_voice_secret (server.cfg set it with setr: every player has it)?
--   5. the voice bot      set up, running, and taking our token? (lore characters' calls)
--
-- Each answer in plain words, and what to do about it.

VoiceCheck = {}

local RESOURCE = GetCurrentResourceName()
local ASK_MS = 4000
local SETUP = 'on the server machine, double-click whip_voice\\service\\Setup voice server.bat'
local CHECK = 'on the server machine, double-click whip_voice\\service\\Check voice server.bat: it names the broken piece'

local asks = {}        -- [nonce] = { [src] = answer } while players are being asked
local lastNonce = 0

--- A player's answer (client/main.lua). Only for a question still open, and only once each.
function VoiceCheck.answer(src, nonce, transport, rtt, secretSeen, joined, why)
    local a = asks[nonce]
    if not a or a[src] then return end
    -- Their game's words go to the console: one line, no colour codes, so it cannot print a line of its
    -- own that looks like the check's (audit 13, SEC-4)
    why = (tostring(why or ''):gsub('%c', ' '):gsub('%^%d', ''))
    a[src] = { transport = transport, rtt = rtt, secretSeen = secretSeen, joined = joined, why = why }
end

--- Wait for a callback-style answer, at most `ms`. Answers what it was given, or nil.
local function await(ms, start)
    local p, done = promise.new(), false
    start(function(...) if not done then done = true; p:resolve(table.pack(...)) end end)
    SetTimeout(ms, function() if not done then done = true; p:resolve(nil) end end)
    local r = Citizen.Await(p)
    if r then return table.unpack(r, 1, r.n) end
    return nil
end

--- Run every check, saying each line through `say(text, tone)` (tone: 'ok', 'bad', 'warn', 'fix', 'head').
function VoiceCheck.run(say)
    local problems = 0
    local function good(t) say('OK    ' .. t, 'ok') end
    local function bad(t, fix) problems = problems + 1; say('FAIL  ' .. t, 'bad'); if fix then say('      Fix: ' .. fix, 'fix') end end
    local function warn(t, fix) say('WARN  ' .. t, 'warn'); if fix then say('      Fix: ' .. fix, 'fix') end end

    say('whip_voice: checking voice from the game\'s side', 'head')

    -- 1. The voice system.
    local v = Whip.call('GetVoiceSystem')
    if type(v) == 'table' and v.resource ~= RESOURCE then
        bad(('%s is the voice system, so whip_voice is off'):format(tostring(v.resource)),
            ('take "ensure %s" out of server.cfg and restart the server (only one voice system can run)'):format(tostring(v.resource)))
        say(('%d thing(s) to fix.'):format(problems), 'head')
        return
    elseif type(v) ~= 'table' then
        bad('whip_voice is not registered as the voice system', 'restart whip_voice (and check whip_core is running)')
    else
        good('whip_voice is the voice system')
    end

    -- 2. server.cfg, and the voice server taking our key.
    local s = VoiceServer.settings()
    local ok, why = await(15000, function(done) VoiceServer.check(done) end)
    if ok == nil then bad('the voice server did not answer within 15 seconds', CHECK)
    elseif ok then good(why)
    else bad(why, SETUP .. ' (it prints the server.cfg lines and checks the rest)') end

    -- 3. The players' address, from here. Players already connected through it prove it works for them better than
    -- this server's own request can: FiveM for GTAV Enhanced's server (its own HTTP code, not Legacy's curl) got a
    -- 400 from the address where Legacy, browsers and every player's game got LiveKit's "OK" (25 Oct 2026). With
    -- players connected it is right, and this server's own failure is only a note.
    local host = tostring(s.url or ''):match('^wss://([^/:]+)')
    if host then
        local status, body, _, errorData = await(12000, function(done)
            PerformHttpRequest('https://' .. host .. '/?whipcheck=1', function(st, text, hdrs, err) done(st, text, hdrs, err) end,
                'GET', '', { ['Accept'] = 'text/plain' })
        end)
        local connected = 0
        for _, p in pairs(Voice.players) do if p.joined then connected = connected + 1 end end
        if status == 200 and tostring(body or ''):match('^%s*OK%s*$') then
            good(('https://%s answers from the voice server, with a valid certificate'):format(host))
        else
            -- What it said (an error answer's words come as errorData, not the body), on one line.
            local said = tostring(body or errorData or ''):gsub('%c', ' '):gsub('%^%d', ''):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''):sub(1, 100)
            local what = (status == nil or status == 0)
                and ('https://%s cannot be reached from this server'):format(host)
                or ('https://%s answered this server %s'):format(host, tostring(status))
            if said ~= '' then what = what .. ' ("' .. said .. '")' end
            if connected > 0 then
                good(('https://%s works: %d player(s) connected through it'):format(host, connected))
                say(('      (Note: %s. FiveM for GTAV Enhanced\'s server does that; players are not affected.)'):format(what), 'fix')
            elseif status == nil or status == 0 then
                bad(what .. ' (no answer, or no valid certificate)', CHECK)
            else
                bad(what .. ', which is not the voice server', 'its HTTPS site must pass it to 127.0.0.1:7880: ' .. SETUP)
            end
        end
    end

    -- 4. Every player's game.
    local players = Whip.call('GetPlayers', { light = true })
    local list = {}
    for src in pairs(type(players) == 'table' and players or {}) do
        src = tonumber(src)
        if src and GetPlayerName(src) then list[#list + 1] = src end
    end
    if #list == 0 then
        warn('no players are in game to ask: join (or have someone join), then run /voicecheck again')
    else
        lastNonce = lastNonce + 1
        local nonce = lastNonce
        asks[nonce] = {}
        for _, src in ipairs(list) do TriggerClientEvent('whip_voice:client:probe', src, nonce) end
        Wait(ASK_MS)
        local answers = asks[nonce]
        asks[nonce] = nil

        local udp, tcp, unknown, silent, leaked, nomic = {}, {}, {}, {}, 0, {}
        for _, src in ipairs(list) do
            local a = answers[src]
            local name = ('%s (id %d)'):format(GetPlayerName(src) or '?', src)
            if not a then
                silent[#silent + 1] = name
            else
                if a.secretSeen then leaked = leaked + 1 end
                if not a.joined then
                    bad(('%s is not connected to voice: %s'):format(name, a.why ~= '' and a.why or 'no reason given'),
                        'if it is everyone, ' .. CHECK .. '; if it is only them, their game may block the microphone or the connection')
                elseif a.why ~= '' then
                    -- Connected (they hear) without a microphone: how they connect cannot be read without one.
                    nomic[#nomic + 1] = ('%s: %s'):format(name, a.why)
                elseif a.transport == 'udp' then udp[#udp + 1] = ('%s %d ms'):format(name, a.rtt or 0)
                elseif a.transport == 'tcp' or a.transport == 'relay' then tcp[#tcp + 1] = name
                else unknown[#unknown + 1] = name end
            end
        end
        if #udp > 0 then good(('%d connected over UDP, the best way: %s'):format(#udp, table.concat(udp, ', '))) end
        if #tcp > 0 then
            if #udp == 0 then
                bad(('%d connected, all over TCP: UDP 7882-7893 is not getting through to the server'):format(#tcp),
                    'allow UDP 7882-7893 inbound in your HOST\'s firewall (its website\'s control panel); ' .. CHECK .. ' for the Windows side')
            else
                warn(('%d connected over TCP, not UDP: %s. Their own network blocks UDP (voice works, but can stutter)')
                    :format(#tcp, table.concat(tcp, ', ')))
            end
        end
        if #unknown > 0 then warn(('%d connected, but their game could not say how: %s'):format(#unknown, table.concat(unknown, ', '))) end
        if #nomic > 0 then
            warn(('%d can hear but not talk: %s'):format(#nomic, table.concat(nomic, '; ')),
                'FiveM\'s microphone box takes the mouse only with the F8 console open: they open F8 and click Allow '
                .. '(refused earlier: they allow it in FiveM\'s settings and reconnect)')
        end
        if #silent > 0 then warn(('%d did not answer (still loading in?): %s'):format(#silent, table.concat(silent, ', '))) end
        if leaked > 0 then
            bad(('%d player(s) can read whip_voice_secret: server.cfg sets it with setr (or sets), which sends it to every player')
                :format(leaked),
                'change that line to plain "set", restart the server, then make a new secret: run the setup with -NewKeys and copy the new lines it prints into server.cfg')
        elseif #list > 0 and next(answers) ~= nil then
            good('no player\'s game can read the secret')
        end
    end

    -- 5. The voice bot (lore characters' calls). No token in server.cfg: a bot that answers (refusing us) is
    -- installed, and only this server.cfg's line is missing.
    local botUrl = GetConvar('whip_voicebot_url', 'http://127.0.0.1:7899'):gsub('/+$', '')
    if GetConvar('whip_voicebot_token', '') == '' then
        local status = await(4000, function(done)
            PerformHttpRequest(botUrl .. '/health', function(st) done(st) end, 'GET', '', { Accept = 'application/json' })
        end)
        if status == 401 then
            bad('the voice bot is running, but this server.cfg has no whip_voicebot_token line: lore characters cannot phone players',
                SETUP .. ' (it keeps every key and token) and copy the whip_voicebot_token line it prints at the end into this server.cfg')
        else
            bad('the voice bot is not installed: lore characters cannot phone players',
                SETUP .. ' (it installs it), then copy the whip_voicebot_token line it prints into server.cfg')
        end
    else
        local status, body = await(6000, function(done)
            PerformHttpRequest(botUrl .. '/health', function(st, text) done(st, text) end, 'GET', '',
                { Authorization = 'Bearer ' .. GetConvar('whip_voicebot_token', '') })
        end)
        local okH, h = pcall(json.decode, body or '')
        if status == 200 and okH and type(h) == 'table' and h.ok then
            good(('the voice bot is running (version %s, %d of %d calls in use)'):format(tostring(h.version), tonumber(h.calls) or 0, tonumber(h.max) or 0))
        elseif status == 401 then
            bad('the voice bot refused whip_voicebot_token', 'run the setup again and copy the whip_voicebot_token line it prints into server.cfg (replacing the old one)')
        else
            bad('the voice bot service did not answer', CHECK .. ' (its "whip-voicebot" service must be running)')
        end
    end

    if problems == 0 then say('Everything checked is right.', 'head')
    else say(('%d thing(s) to fix, top to bottom (an early one often causes the later ones).'):format(problems), 'head') end
end

--- Their game's answer: declared in Whip.register (server/main.lua), only while whip_voice is the voice system.
function VoiceCheck.register(core)
    core:SecureEvent('whip_voice:server:probe', {
        rateLimit = 500, burst = 3, whileDead = true,
        params = {
            {'nonce', 'id', 1, 2147483647},
            {'transport', 'enum', { 'udp', 'tcp', 'relay', 'none', 'unknown' }},
            {'rtt', 'int', 0, 60000},
            {'secretSeen', 'bool'},
            {'joined', 'bool'},
            {'why', 'string', 160, ''},     -- empty: connected, with a microphone (nothing wrong)
        },
    }, function(source, _, nonce, transport, rtt, secretSeen, joined, why)
        VoiceCheck.answer(source, nonce, transport, rtt, secretSeen, joined, why)
    end)
end

local TONE = { ok = '^2', bad = '^1', warn = '^3', fix = '^7', head = '^5' }

-- /voicecheck — for the server console, and whip.devtools with developer mode on (Whip.command's dev gate; its own
-- thread, so the check may wait).
Whip.command('voicecheck', { dev = true, whileDead = true }, function(source)
    VoiceCheck.run(function(text, tone)
        if source == 0 then
            print('[whip_voice] ' .. text)
        else
            TriggerClientEvent('chat:addMessage', source, { args = { (TONE[tone] or '^7') .. '[voice]^7 ' .. text } })
        end
    end)
end)
