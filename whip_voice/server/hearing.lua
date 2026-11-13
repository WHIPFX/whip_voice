-- Deciding who hears whom, four times a second. The server's half of every conversation: it works out who may hear
-- whom (server/audibility.lua) and tells both ends. It never touches audio.
--
--   to the listener:  whip_voice:client:hear  { add = {{ id, src, range, fx }}, remove = { id } }
--                     voices to pick up (id is the voice identity, src the player whose head it comes from, range how
--                     far it carries, fx its effect: 'megaphone' or none), and the devices on speaker near them
--                     ({ id, src, range, speaker = true }, one per member and line)
--   to the listener:  whip_voice:client:line { open = {{ line, track, recipe, own, rx }}, close = { line },
--                                              add = {{ id, line, q, via, level }}, remove = {{ id, line }},
--                                              q = {{ id, line, q }}, via = {{ id, line, via }}, level = {{ id, line, level }} }
--                     the lines they hear (a radio frequency, a call): each line once before its first voice, and let
--                     go of when nothing comes from it; the voices on it with their signal (q, 1 clear to 0); voices
--                     coming out of a device on speaker near them (via: that node's id in the hear list) or picked up
--                     by one (level). No server id: a line member across the map learns nothing about who a voice is.
--   to the speaker:   whip_voice:client:allow { id, ... }, kbps, { id, ... }
--                     the whole list of listeners who may hear them (every time it changes), the quality to send at
--                     when the crowd hearing them is big (nil = normal), and who may hear their radio. Allowed per
--                     track: a frequency member far away gets the radio and never what they say normally.
--
-- Both ends, on purpose: every voice starts out allowing nobody, and the voice server will not let a listener pick up a
-- voice its owner has not allowed, so a modified game that ignores the hear list still hears nobody the server did not
-- name.
--
-- Runs only while it has work: from two players connected until fewer than two. A change that must take effect at
-- once (leaving a line, a mute, a speaker turned off) runs a pass there and then (Hearing.now).

Hearing = {}

local TICK_MS = 250
local state = {}          -- Audibility's memory between passes
local sentAllow = {}      -- [speaker src] = the allow list last sent, as a sorted string
local sentKbps = {}       -- [speaker src] = the crowd quality last sent (nil = normal)
local sentRadio = {}      -- [speaker src] = the radio allow list last sent, as a sorted string
local nodeIds = {}        -- [node key] = the id its listeners know it by (kept to let go of it after it went)
local opened = {}         -- [listener src] = { [lineId] = true }: the lines their page has been told of
local tokens = {}         -- [lineId] = its token (kept to let go of it after the line closed)
local running = false

local function idOf(src)
    local p = Voice.players[src]
    if p then return p.identity end
    return VoiceBots and VoiceBots.identityOf(src) or nil   -- a voice bot on a line (server/bots.lua)
end

--- Everyone connected, loaded and in the world, as the rule wants them.
local function snapshot()
    local list = {}
    for src, p in pairs(Voice.players) do
        if p.joined and Voice.loaded[src] then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                -- Down by whip_core's own word (Voice.dead, from its died / revived events), never the
                -- player's bag: their client can write that (audit 11, SEC-2).
                local dead = Voice.dead[src] == true
                list[#list + 1] = {
                    src = src, bucket = GetPlayerRoutingBucket(src), x = c.x, y = c.y, z = c.z,
                    range = Voice.rangeOf(src),
                    speaks = p.speaking and (Config.DeadCanTalk or not dead),
                }
            end
        end
    end
    return list
end

--- The identities of these players, sorted, and as one string for comparing with what was sent.
local function idsOf(list)
    local ids = {}
    for _, l in ipairs(list or {}) do
        local id = idOf(l)
        if id then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids, table.concat(ids, ',')
end

--- The voice track's listeners: the people near (proximity) and everyone hearing them on a voice line
--- (a call, someone picked up by a phone on speaker), once each.
local function voiceListeners(near, onLines)
    if not onLines then return near end
    local seen, out = {}, {}
    for _, l in ipairs(near or {}) do if not seen[l] then seen[l] = true; out[#out + 1] = l end end
    for _, l in ipairs(onLines) do if not seen[l] then seen[l] = true; out[#out + 1] = l end end
    return out
end

local function sendAllows()
    local lists = Audibility.allowLists(state)
    local onLines = Audibility.lineAllowLists(state)
    local radio, voice = onLines.radio or {}, onLines.voice or {}
    local speakers = {}
    for s in pairs(lists) do speakers[s] = true end
    for s in pairs(voice) do speakers[s] = true end
    for s in pairs(radio) do speakers[s] = true end
    for s in pairs(sentAllow) do speakers[s] = true end
    for s in pairs(sentRadio) do speakers[s] = true end
    for s in pairs(speakers) do
        local ids, key = idsOf(voiceListeners(lists[s], voice[s]))
        local rids, rkey = idsOf(radio[s])
        -- (The crowd is the people near: a call adds one listener, never a crowd.)
        local kbps = Audibility.crowdKbps(#(lists[s] or {}), sentKbps[s])
        if key ~= (sentAllow[s] or '') or rkey ~= (sentRadio[s] or '') or kbps ~= sentKbps[s] then
            sentAllow[s] = key ~= '' and key or nil
            sentRadio[s] = rkey ~= '' and rkey or nil
            sentKbps[s] = kbps
            if Voice.players[s] then
                TriggerClientEvent('whip_voice:client:allow', s, ids, kbps, rids)
            elseif VoiceBots and VoiceBots.byKey[s] then
                VoiceBots.allow(s, ids)   -- a bot's list goes to the voice bot service (it has no game)
            end
        end
    end
end

--- A device on speaker, as the hear list names it: its owner's identity and its line's token (one per
--- member and line). Remembered, so it can be let go of after the line or the owner went.
local function nodeIdOf(key)
    if nodeIds[key] then return nodeIds[key] end
    local N = state.nodes and state.nodes[key]
    local line = N and Lines.byId[N.line]
    local id = N and idOf(N.owner)
    if not (id and line) then return nil end
    nodeIds[key] = 'spk:' .. id .. ':' .. line.token
    return nodeIds[key]
end

--- A line, as a listener's page is told of it (once, before its first voice).
local function openOf(lineId)
    local line = Lines.byId[lineId]
    if not line then return nil end
    tokens[lineId] = line.token
    return { line = line.token, track = line.track, recipe = line.recipe, own = line.own or nil, rx = line.rx or nil }
end

--- Every line's changes, to each listener they concern: the lines first (opened before their first
--- voice), the voices let go of, the new ones, what changed, then the lines nothing comes from any more.
local function sendLines(A, R, C, V, Lv)
    local listeners = {}
    for _, diffs in ipairs({ A, R, C, V, Lv }) do
        for _, byL in pairs(diffs) do for l in pairs(byL) do listeners[l] = true end end
    end
    for l in pairs(opened) do listeners[l] = true end
    for l in pairs(listeners) do
        local msg = { open = {}, close = {}, add = {}, remove = {}, q = {}, via = {}, level = {} }
        local any = false
        -- The lines this listener hears anything from now (any track).
        local using = {}
        for _, routes in pairs(state.routes or {}) do
            for _, r in pairs(routes[l] or {}) do if r.line then using[r.line] = true end end
        end
        local mine = opened[l]
        for lineId in pairs(using) do
            if not (mine and mine[lineId]) then
                local o = openOf(lineId)
                if o then
                    mine = mine or {}; opened[l] = mine
                    mine[lineId] = true
                    msg.open[#msg.open + 1] = o
                    any = true
                end
            end
        end
        for track in pairs(A) do
            -- Out before in: a voice that moved to another line (another sound) is let go, then picked up.
            for _, r in ipairs(R[track][l] or {}) do
                local id, tok = idOf(r[1]), tokens[r[2]]
                if id and tok then msg.remove[#msg.remove + 1] = { id = id, line = tok }; any = true end
            end
            for _, a in ipairs(A[track][l] or {}) do
                local id, tok = idOf(a[1]), tokens[a[4]]
                if id and tok then
                    msg.add[#msg.add + 1] = { id = id, line = tok, q = a[2], via = a[3] and nodeIdOf(a[3]) or nil, level = a[5] }
                    any = true
                end
            end
            local routes = state.routes and state.routes[track] and state.routes[track][l] or {}
            for s, q in pairs(C[track][l] or {}) do
                local id, r = idOf(s), routes[s]
                if id and r then msg.q[#msg.q + 1] = { id = id, line = tokens[r.line], q = q }; any = true end
            end
            for s, via in pairs(V[track][l] or {}) do
                local id, r = idOf(s), routes[s]
                if id and r then msg.via[#msg.via + 1] = { id = id, line = tokens[r.line], via = via and nodeIdOf(via) or false }; any = true end
            end
            for s, lv in pairs(Lv[track][l] or {}) do
                local id, r = idOf(s), routes[s]
                if id and r then msg.level[#msg.level + 1] = { id = id, line = tokens[r.line], level = lv }; any = true end
            end
        end
        -- Lines nothing comes from any more: let go of (after their last voice went).
        for lineId in pairs(mine or {}) do
            if not using[lineId] then
                mine[lineId] = nil
                if tokens[lineId] then msg.close[#msg.close + 1] = tokens[lineId]; any = true end
            end
        end
        if mine and not next(mine) then opened[l] = nil end
        if any and Voice.players[l] then TriggerClientEvent('whip_voice:client:line', l, msg) end
    end
    -- The tokens of lines nobody is told of any more are forgotten.
    for lineId in pairs(tokens) do
        if not Lines.byId[lineId] then
            local anyone = false
            for _, set in pairs(opened) do if set[lineId] then anyone = true break end end
            if not anyone then tokens[lineId] = nil end
        end
    end
end

local function entry(s)
    -- A world voice (server/bots.lua: a lore character): heard from its entity, by its network id.
    local w = VoiceBots and VoiceBots.worldEntry(s)
    if w then return w end
    return { id = idOf(s), src = s, range = Voice.rangeOf(s), fx = Voice.fxOf(s) }
end

local function nodeEntry(key)
    local N = state.nodes[key]
    return { id = nodeIdOf(key), src = N.owner, range = N.range, speaker = true }
end

local function tick()
    local players, now = snapshot(), GetGameTimer()
    -- World voices (server/bots.lua: a lore character at its ped) are heard by proximity like players, as
    -- speakers only. Only this pass: never a listener, never on a line, never picking up a phone on speaker.
    local everyone = VoiceBots and VoiceBots.inWorld(players) or players
    local adds, removes = Audibility.step(everyone, state, now)
    local lines = Lines and Lines.byId or {}
    -- Devices on speaker are picked up like voices (server/audibility.lua nodeStep).
    local spkAdds, spkRemoves = Audibility.nodeStep(players, lines, state, now)
    local listeners = {}
    for l in pairs(adds) do listeners[l] = true end
    for l in pairs(removes) do listeners[l] = true end
    for l in pairs(spkAdds) do listeners[l] = true end
    for l in pairs(spkRemoves) do listeners[l] = true end
    for l in pairs(listeners) do
        local msg = { add = {}, remove = {} }
        for _, s in ipairs(adds[l] or {}) do
            local e = entry(s)
            if e.id then msg.add[#msg.add + 1] = e end
        end
        for _, key in ipairs(spkAdds[l] or {}) do
            local e = nodeEntry(key)
            if e.id then msg.add[#msg.add + 1] = e end
        end
        -- (A player who LEFT is never here: Hearing.drop let everyone go of them the moment they did.)
        for _, s in ipairs(removes[l] or {}) do
            local id = idOf(s)
            if id then msg.remove[#msg.remove + 1] = id end
        end
        for _, key in ipairs(spkRemoves[l] or {}) do
            local id = nodeIdOf(key)
            if id then msg.remove[#msg.remove + 1] = id end
        end
        if Voice.players[l] and (#msg.add > 0 or #msg.remove > 0) then
            TriggerClientEvent('whip_voice:client:hear', l, msg)
        end
    end
    -- The node ids nobody is near any more are forgotten.
    for key in pairs(nodeIds) do
        local used = state.nodes and state.nodes[key]
        if not used then
            local anyone = false
            for _, set in pairs(state.spk or {}) do if set[key] then anyone = true break end end
            if not anyone then nodeIds[key] = nil end
        end
    end
    -- The lines: who each member hears, by how far apart they are where a line says so, and what comes
    -- out of the devices on speaker. AFTER the hear list, so a node is there before the voices that
    -- come out of it.
    -- Voice bots (server/bots.lua) talk on lines only: they join this pass and no other.
    Audibility.lineStep(VoiceBots and next(VoiceBots.byKey) and VoiceBots.talkers(players) or players, lines, state, now)
    Audibility.pickupStep(players, lines, state, now)
    sendLines(Audibility.lineRoutes(state))
    sendAllows()
end

local function connectedCount()
    local n = 0
    for src, p in pairs(Voice.players) do if p.joined and Voice.loaded[src] then n = n + 1 end end
    return n
end

--- Is there anyone to connect: two players, or one and a voice bot (a lore character's call).
local function anyoneToConnect()
    local n = connectedCount()
    return n >= 2 or (n >= 1 and VoiceBots ~= nil and next(VoiceBots.byKey) ~= nil)
end

--- One pass, caught: an error is printed (the first five, then every hundredth) and the next pass runs. Uncaught, it
--- ended the loop with `running` still true, so nothing woke it again and voice stopped updating for the whole server
--- until whip_voice restarted (audit 20, VOX-1).
local tickFails = 0
local function safeTick()
    local ok, err = pcall(tick)
    if ok then return end
    tickFails = tickFails + 1
    if tickFails <= 5 or tickFails % 100 == 0 then
        print(('^1[whip_voice] a hearing pass failed (failure %d; it keeps running): %s^0'):format(tickFails, tostring(err)))
    end
end

--- Start the loop if there is anyone to connect. Called when someone joins or loads in.
function Hearing.wake()
    if running or not anyoneToConnect() then return end
    running = true
    CreateThread(function()
        while running do
            safeTick()
            local more = true
            local okAsk, any = pcall(anyoneToConnect)
            if okAsk and not any then more = false end
            if not more then
                -- Nobody left to connect: one last pass so the last player lets go of everyone.
                safeTick()
                break
            end
            Wait(TICK_MS)
        end
        running = false
    end)
end

--- A pass now, for a change that must not wait for the next one (a line closed or left, a mute, a speaker turned off):
--- who hears whom is worked out and both ends are told, this frame. ONCE A FRAME however many changes asked for it: a
--- batch (whip_core lost, every radio member and line member leaving one by one) ran one whole-server pass per member,
--- all in one frame (audit 20, VOX-3).
local nowDue = false
function Hearing.now()
    if next(Voice.players) == nil or nowDue then return end
    nowDue = true
    SetTimeout(0, function()
        nowDue = false
        if next(Voice.players) == nil then return end
        safeTick()
        Hearing.wake()
    end)
end

--- A line's sound changed: everyone hearing it is told of it again (its new recipe), at once.
function Hearing.reopen(lineId)
    for _, set in pairs(opened) do set[lineId] = nil end
    Hearing.now()
end

--- A player left or got a new identity: everyone hearing them lets go now, not on the next pass.
function Hearing.drop(src, identity)
    for l, set in pairs(state.hears or {}) do
        if set[src] then
            set[src] = nil
            if l ~= src and Voice.players[l] then
                TriggerClientEvent('whip_voice:client:hear', l, { add = {}, remove = { identity } })
            end
        end
    end
    if state.hears then state.hears[src] = nil end
    if state.dist then state.dist[src] = nil end
    -- ...and on every line: their own device, or one on speaker (state.routes holds both, so each
    -- listener is told once). Routes FIRST: most of them are the very tables of state.links
    -- (audibility.lua lineRoutes), so clearing state.links first would leave nothing to tell.
    for _, routes in pairs(state.routes or {}) do
        for l, set in pairs(routes) do
            local r = set[src]
            if r then
                set[src] = nil
                local tok = r.line and (tokens[r.line] or (Lines.byId[r.line] and Lines.byId[r.line].token))
                if l ~= src and Voice.players[l] and tok then
                    TriggerClientEvent('whip_voice:client:line', l, { open = {}, close = {}, add = {}, q = {}, via = {}, level = {},
                        remove = { { id = identity, line = tok } } })
                end
            end
        end
        routes[src] = nil
    end
    -- Their page starts again from nothing (a new identity is a new page): every line is told again.
    opened[src] = nil
    for _, set in pairs(state.pickTo or {}) do set[src] = nil end
    if state.pickTo then state.pickTo[src] = nil end
    for _, links in pairs(state.links or {}) do
        for _, set in pairs(links) do set[src] = nil end
        links[src] = nil
    end
    -- ...and their devices on speaker: everyone near one lets go of it (under the old identity). What
    -- came out of them is moved on the next pass — to another node, back to the listener's own device,
    -- or to this same player's under their new identity (via false: "from nowhere", so the next pass
    -- always says where).
    local mine = {}
    for key, N in pairs(state.nodes or {}) do if N.owner == src then mine[key] = true end end
    for key, id in pairs(nodeIds) do
        if id:sub(1, 4 + #identity + 1) == 'spk:' .. identity .. ':' then mine[key] = true end
    end
    for _, routes in pairs(state.routes or {}) do
        for _, set in pairs(routes) do
            for _, r in pairs(set) do if r.via and mine[r.via] then r.via = false end end
        end
    end
    for l, set in pairs(state.spk or {}) do
        for key in pairs(mine) do
            if set[key] then
                set[key] = nil
                if state.spkDist and state.spkDist[l] then state.spkDist[l][key] = nil end
                local id = nodeIds[key] or ('spk:' .. identity)
                if l ~= src and Voice.players[l] then
                    TriggerClientEvent('whip_voice:client:hear', l, { add = {}, remove = { id } })
                end
            end
        end
    end
    for key in pairs(mine) do
        nodeIds[key] = nil
        if state.nodes then state.nodes[key] = nil end
    end
    if state.spk then state.spk[src] = nil end
    if state.spkDist then state.spkDist[src] = nil end
    sentAllow[src], sentKbps[src], sentRadio[src] = nil, nil, nil
    sendAllows()
end

--- A speaker changed range, or put a megaphone up or down: everyone connected to them hears the new
--- edge (and the new sound) at once. Anyone the longer range now reaches is connected on the next pass.
function Hearing.rangeChanged(src)
    local e = entry(src)
    if not e.id then return end
    for l, set in pairs(state.hears or {}) do
        if set[src] and Voice.players[l] then
            TriggerClientEvent('whip_voice:client:hear', l, { add = { e }, remove = {} })
        end
    end
end

--- For /voicestatus: how many voices each player is connected to.
function Hearing.summary()
    local out = {}
    for l, set in pairs(state.hears or {}) do
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        out[l] = n
    end
    return out, running
end
