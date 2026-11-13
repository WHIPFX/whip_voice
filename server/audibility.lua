-- Who can hear whom: the rule, with no FiveM in it. Players in, decisions out; server/hearing.lua feeds it and sends
-- the results.
--
-- A listener hears a speaker when they share a routing bucket, are not the same player, the speaker can speak (mic
-- live; alive, unless Config.DeadCanTalk) and is within voice range plus a margin. At most the nearest CAP speakers
-- per listener.
--
-- Subscribed early: connecting a voice takes a moment, so it happens MARGIN metres before the voice can be heard
-- (further for someone closing in fast). The fade to silence at the exact range is done on the listener's machine
-- (html/js/audio.js), so a modified game could hear up to MARGIN metres past the range.
-- Slow to let go: a connected voice stays until its speaker has been beyond range + MARGIN for HOLD_MS.
-- Keeps its place in a crowd: with more than CAP in earshot, a connected voice keeps its place unless a newcomer is
-- STAY metres closer, so voices do not flicker.
-- Only neighbours are compared: the map is cut into squares a little bigger than the furthest voice reach, and each
-- listener looks at their own square, the eight around it and anyone still connected.

Audibility = {
    MARGIN  = 15.0,    -- metres connected ahead of the range
    LEAD    = 1.0,     -- seconds of closing speed added to that (fast cars)
    HOLD_MS = 3000,    -- how long past the edge before letting go
    CAP     = tonumber(Config and Config.MaxVoices) or 16,   -- most voices one listener is connected to (config.lua)
    STAY    = 3.0,     -- in a crowd over CAP, metres closer a newcomer must be to take a connected voice's place
    AHEAD   = 40.0,    -- the squares also cover this many metres more, for cars closing in fast
}

--- The furthest a normal voice carries (config.lua's Config.Ranges): what the squares are cut for. Asked each pass, so a
--- range changed in the settings counts at once. 20 m when there is no config (the tests).
function Audibility.normalReach()
    local m = 0
    for _, r in pairs(Config and Config.Ranges or {}) do
        r = tonumber(r)
        if r and r > m then m = r end
    end
    return m > 0 and m or 20.0
end

-- One number per square (and routing bucket), for looking squares up quickly.
local function square(bucket, gx, gy)
    return (bucket * 4096 + (gx + 2048)) * 4096 + (gy + 2048)
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Put the k smallest keys at the front (in no particular order), moving srcs and vals with them.
--- Picks the nearest k without sorting everyone (quickselect).
local function nearestFirst(keys, srcs, vals, n, k)
    local lo, hi = 1, n
    while lo < hi do
        local pivot = keys[(lo + hi) // 2]
        local i, j = lo, hi
        while i <= j do
            while keys[i] < pivot do i = i + 1 end
            while keys[j] > pivot do j = j - 1 end
            if i <= j then
                keys[i], keys[j] = keys[j], keys[i]
                srcs[i], srcs[j] = srcs[j], srcs[i]
                vals[i], vals[j] = vals[j], vals[i]
                i, j = i + 1, j - 1
            end
        end
        if k <= j then hi = j elseif k >= i then lo = i else return end
    end
end

--- One pass.
---@param players table[] { src, bucket, x, y, z, range (metres), speaks (bool) } — everyone connected
---@param state table     kept between passes: { hears = {}, dist = {}, at = nil } (start with {}).
---                       hears[listener][speaker] = true while in reach, or the time (ms) the speaker
---                       went out of reach while being held.
---@param now number      milliseconds
---@return table adds     [listener] = { speaker, ... } newly connected
---@return table removes  [listener] = { speaker, ... } no longer connected
function Audibility.step(players, state, now)
    state.hears = state.hears or {}
    state.dist = state.dist or {}
    local dt = state.at and math.max(0.05, (now - state.at) / 1000) or nil
    state.at = now

    local adds, removes = {}, {}
    local present, bySrc = {}, {}
    -- The squares are cut for a normal voice (Config.Ranges, the furthest of them). The few that carry further (a
    -- megaphone, a lore line's Bonus range) are looked at apart, by every listener, as `far`.
    local gridReach = Audibility.normalReach()
    local reach, far = 0, {}
    for _, P in ipairs(players) do
        present[P.src], bySrc[P.src] = true, P
        if P.speaks then
            if P.range > gridReach then far[#far + 1] = P
            elseif P.range > reach then reach = P.range end
        end
    end

    -- The squares: the furthest a normal voice reaches this pass, plus the margin, plus room for fast cars.
    local size = reach + Audibility.MARGIN + Audibility.AHEAD
    local grid = {}
    for _, P in ipairs(players) do
        if P.speaks and P.range <= gridReach then
            local k = square(P.bucket, math.floor(P.x / size), math.floor(P.y / size))
            local cell = grid[k]
            if not cell then cell = {}; grid[k] = cell end
            cell[#cell + 1] = P
        end
    end

    local CAP, STAY, MARGIN, LEAD, HOLD = Audibility.CAP, Audibility.STAY, Audibility.MARGIN, Audibility.LEAD, Audibility.HOLD_MS
    -- Who is near the listener being worked out, in three lists kept side by side (reused for every
    -- listener: a crowd makes tens of thousands of these a pass, so nothing new is made per pair).
    local nearSrc, nearKey, nearVal = {}, {}, {}
    for _, L in ipairs(players) do
        -- A world voice (a bot: a lore character) only talks; it never hears anyone.
        if L.bot then goto nextListener end
        local had = state.hears[L.src] or {}
        local prevDist = state.dist[L.src] or {}
        local nextDist = {}
        local mark = {}   -- stamped on each speaker looked at, so nobody is looked at twice
        local n = 0

        local function consider(S)
            if S.seenBy == mark then return end
            S.seenBy = mark
            if S.src == L.src or S.bucket ~= L.bucket or not S.speaks then return end
            local d = dist(L, S)
            nextDist[S.src] = d
            local closing = 0.0
            if dt and prevDist[S.src] then closing = math.max(0.0, (prevDist[S.src] - d) / dt) end
            local cur = had[S.src]
            local val               -- true = in reach; a number = held since that time
            if d <= S.range + MARGIN + closing * LEAD then
                val = true
            elseif cur then
                if d <= S.range + MARGIN then
                    val = true
                else
                    local since = cur == true and now or cur
                    if now - since < HOLD then val = since end
                end
            end
            if val then
                n = n + 1
                -- How near, for the CAP: one already connected counts STAY metres nearer.
                nearSrc[n], nearKey[n], nearVal[n] = S.src, cur and d - STAY or d, val
            end
        end

        local gx, gy = math.floor(L.x / size), math.floor(L.y / size)
        for x = gx - 1, gx + 1 do
            for y = gy - 1, gy + 1 do
                local cell = grid[square(L.bucket, x, y)]
                if cell then for i = 1, #cell do consider(cell[i]) end end
            end
        end
        -- The voices that carry further than a square: each looked at by every listener (there are only ever a few)
        for i = 1, #far do consider(far[i]) end
        -- Anyone still connected is looked at wherever they are (driving off: held for HOLD_MS).
        for s in pairs(had) do
            local S = bySrc[s]
            if S then consider(S) end
        end

        -- More in earshot than CAP: the nearest, connected ones first by STAY metres.
        if n > CAP then nearestFirst(nearKey, nearSrc, nearVal, n, CAP) end
        local now_ = {}
        for i = 1, math.min(n, CAP) do now_[nearSrc[i]] = nearVal[i] end

        for s in pairs(now_) do
            if not had[s] then adds[L.src] = adds[L.src] or {}; table.insert(adds[L.src], s) end
        end
        for s in pairs(had) do
            if not now_[s] then removes[L.src] = removes[L.src] or {}; table.insert(removes[L.src], s) end
        end
        state.hears[L.src] = now_
        state.dist[L.src] = nextDist
        ::nextListener::
    end

    -- A listener who is no longer in the list at all (left, logged out, lost their connection)
    -- keeps nothing.
    for l, had in pairs(state.hears) do
        if not present[l] then
            state.hears[l] = nil
            state.dist[l] = nil
            local gone = {}
            for s in pairs(had) do gone[#gone + 1] = s end
            if #gone > 0 then removes[l] = gone end
        end
    end
    return adds, removes
end

-- Voice lines
-- A line (server/lines.lua) is a set of players who hear each other wherever they are, through a sound recipe (a radio
-- frequency, a phone call). Members hear each other on the line's track, 'radio' or 'voice', from their own device.
-- Line links do not count against CAP.
-- A line with a quality (the radio: Config.Radio clearWithin / maxRange) is heard worse the further apart its members
-- are: a signal q from 1 (up to `clear`) down to 0 at `range`; past it, nothing. Such a link is held `hold` ms past
-- the range. A line without one (a call) is q 1 wherever they are.
-- One route per (track, listener, talker): a pair on two lines of the same track is linked through one of them, one
-- where the talker is not muted (the one already in use, else the oldest).
--
-- A line view, as these functions read it (server/lines.lua keeps them):
--   { id, order, track, quality = { clear, range } | nil, sameWorld, speakerRange, margin, hold,
--     members = { [src] = { speaker = bool, muted = bool } } }

--- Signal quality at `d` metres: 1 up to `clear`, 0 at `range`, in steps of 0.05 (only real changes
--- are sent).
function Audibility.signal(d, clear, range)
    if d <= clear then return 1 end
    if d >= range then return 0 end
    local q = 1 - (d - clear) / (range - clear)
    return math.floor(q * 20 + 0.5) / 20
end

--- The lines as a list, oldest first (the one-route rule must decide the same way every pass).
local function inOrder(lines)
    local list = {}
    for _, line in pairs(lines or {}) do list[#list + 1] = line end
    table.sort(list, function(a, b) return a.order < b.order end)
    return list
end

--- One pass of every line: who each member hears on it, and how well.
---@param players table[] as Audibility.step's (speaks: mic live and allowed to talk)
---@param lines table     [id] = a line view (above)
---@param state table     kept between passes — the same table as Audibility.step's (keeps state.links)
---@param now number      milliseconds
function Audibility.lineStep(players, lines, state, now)
    local bySrc = {}
    for _, P in ipairs(players) do bySrc[P.src] = P end
    local old = state.links or {}
    local links = {}       -- [track][listener][talker] = { q, outSince, line }
    for _, line in ipairs(inOrder(lines)) do
        local track = line.track
        local oldT = old[track] or {}
        local T = links[track]
        if not T then T = {}; links[track] = T end
        local here = {}
        for src, m in pairs(line.members) do
            local P = bySrc[src]
            if P then here[#here + 1] = { P = P, m = m } end
        end
        local Q = line.quality
        for _, l in ipairs(here) do
            local L = l.P
            local had = oldT[L.src] or {}
            -- A voice bot (P.bot: server/bots.lua) only talks: never a listener; no position, so no distance or
            -- world rule applies to it.
            for _, s in ipairs(here) do
                local S = s.P
                if S ~= L and not L.bot and S.speaks and not s.m.muted and (S.bot or not line.sameWorld or S.bucket == L.bucket) then
                    local cur = had[S.src]
                    local link
                    if Q and not S.bot then
                        local d = dist(L, S)
                        if d <= Q.range then
                            link = { q = Audibility.signal(d, Q.clear, Q.range) }
                        elseif cur and cur.line == line.id then
                            local since = cur.outSince or now
                            if now - since < line.hold then link = { q = 0, outSince = since } end
                        end
                    else
                        link = { q = 1 }
                    end
                    if link then
                        link.line = line.id
                        local mine = T[L.src]
                        if not mine then mine = {}; T[L.src] = mine end
                        local prev = mine[S.src]
                        -- (Oldest first: a later line takes the pair only when it is the one in use.)
                        if not prev or (cur and cur.line == line.id and prev.line ~= line.id) then mine[S.src] = link end
                    end
                end
            end
        end
    end
    state.links = links
end

-- A device on speaker
-- A member's device on speaker plays what it receives on that line out loud, so people near it hear it too. Each is a
-- node, one per (member, line). For each listener near one: the node itself, picked up like a voice at its owner's
-- head, connected within the line's speakerRange + margin and held `hold` past it; and who comes out of it: everyone
-- that member hears on that line, at their signal.
-- A dead owner's device keeps playing. Never twice: someone heard from the listener's own device on that track is
-- heard there only. Between two nodes carrying the same voice: one the listener can hear, then the one it already came
-- out of, else the nearest. A talker never hears themselves out of someone else's device.
-- Only neighbours are compared: a square grid as big as the furthest node reach (speakerRange is at most 30 m).

--- The key of a node: its owner and its line.
local function nodeKey(owner, lineId) return tostring(owner) .. '/' .. tostring(lineId) end
Audibility.nodeKey = nodeKey

--- One pass of the devices on speaker: which ones each listener is near.
---@param players table[]  as Audibility.step's
---@param lines table      [id] = a line view
---@param state table      the same table as Audibility.step's (keeps state.spk, state.spkDist, state.nodes)
---@param now number       milliseconds
---@return table adds      [listener] = { nodeKey, ... } newly near
---@return table removes   [listener] = { nodeKey, ... } no longer
function Audibility.nodeStep(players, lines, state, now)
    local old = state.spk or {}
    local bySrc = {}
    for _, P in ipairs(players) do bySrc[P.src] = P end

    local nodes, reach = {}, 1
    for _, line in pairs(lines or {}) do
        for src, m in pairs(line.members) do
            if m.speaker and bySrc[src] then
                local key = nodeKey(src, line.id)
                local r = line.speakerRange + line.margin
                nodes[key] = { owner = src, line = line.id, track = line.track, range = line.speakerRange,
                               reach = r, hold = line.hold }
                if r > reach then reach = r end
            end
        end
    end

    local near, dists = {}, {}
    if next(nodes) then
        -- Every player in their square (listeners: whoever stands near a node, talking or not).
        local grid = {}
        for _, P in ipairs(players) do
            local k = square(P.bucket, math.floor(P.x / reach), math.floor(P.y / reach))
            local cell = grid[k]
            if not cell then cell = {}; grid[k] = cell end
            cell[#cell + 1] = P
        end
        -- Who was near each node last pass (held ones are looked at wherever they are now).
        local heldBy = {}
        for l, set in pairs(old) do
            for key in pairs(set) do
                local list = heldBy[key]
                if not list then list = {}; heldBy[key] = list end
                list[#list + 1] = l
            end
        end
        for key, N in pairs(nodes) do
            local A = bySrc[N.owner]
            local seen = {}
            local function consider(L)
                if seen[L.src] then return end
                seen[L.src] = true
                if L.src == N.owner or L.bucket ~= A.bucket then return end
                local d = dist(L, A)
                local cur = old[L.src] and old[L.src][key]
                local val            -- true = near; a number = held since that time
                if d <= N.reach then
                    val = true
                elseif cur then
                    local since = cur == true and now or cur
                    if now - since < N.hold then val = since end
                end
                if val then
                    near[L.src] = near[L.src] or {}
                    near[L.src][key] = val
                    dists[L.src] = dists[L.src] or {}
                    dists[L.src][key] = d
                end
            end
            local gx, gy = math.floor(A.x / reach), math.floor(A.y / reach)
            for x = gx - 1, gx + 1 do
                for y = gy - 1, gy + 1 do
                    local cell = grid[square(A.bucket, x, y)]
                    if cell then for i = 1, #cell do consider(cell[i]) end end
                end
            end
            for _, l in ipairs(heldBy[key] or {}) do
                local L = bySrc[l]
                if L then consider(L) end
            end
        end
    end

    local adds, removes = {}, {}
    for l, set in pairs(near) do
        local had = old[l] or {}
        for key in pairs(set) do
            if not had[key] then adds[l] = adds[l] or {}; table.insert(adds[l], key) end
        end
    end
    for l, had in pairs(old) do
        local set = near[l] or {}
        for key in pairs(had) do
            if not set[key] then removes[l] = removes[l] or {}; table.insert(removes[l], key) end
        end
    end
    state.spk, state.spkDist, state.nodes = near, dists, nodes
    return adds, removes
end

-- Speaker pickup: speaker works both ways
-- On a line that picks up (`pickup`: a phone's), people near a member's device on speaker are heard by the line's
-- other members too, when they talk with their normal key within their own voice range of the device (never further
-- than its speakerRange). Quieter the further from the device (a level in steps of 0.1). Someone near two devices on
-- the same line is picked up by the nearest. A member muted on the line mutes their device's pickup. Subscribed
-- PICK_MARGIN metres early, held PICK_HOLD past it (silent).

Audibility.PICK_MARGIN = 2.0
Audibility.PICK_HOLD = 1000

--- One pass of the pickup. Run after nodeStep (it reads state.nodes).
---@param players table[]  as Audibility.step's
---@param lines table      [id] = a line view (pickup = true to pick up)
---@param state table      the same table as the others (keeps state.pick, state.pickTo)
---@param now number       milliseconds
function Audibility.pickupStep(players, lines, state, now)
    local nodes, old = state.nodes or {}, state.pick or {}
    local bySrc = {}
    for _, P in ipairs(players) do bySrc[P.src] = P end
    local M = Audibility.PICK_MARGIN
    local pick = {}            -- [lineId][talker] = { key, d, level, since }
    local size = 30 + M        -- the furthest a pickup can reach (speakerRange is at most 30 m)
    local grid
    for key, N in pairs(nodes) do
        local line = lines and lines[N.line]
        local owner = line and line.members[N.owner]
        if line and line.pickup and owner and not owner.muted then
            if not grid then
                grid = {}
                for _, P in ipairs(players) do
                    if P.speaks then
                        local k = square(P.bucket, math.floor(P.x / size), math.floor(P.y / size))
                        local cell = grid[k]
                        if not cell then cell = {}; grid[k] = cell end
                        cell[#cell + 1] = P
                    end
                end
            end
            local A = bySrc[N.owner]
            local was = old[line.id] or {}
            local mine = pick[line.id]
            local function consider(T)
                if T.src == A.src or T.bucket ~= A.bucket or line.members[T.src] then return end
                local reach = math.min(T.range, N.range)
                local d = dist(T, A)
                local cur = was[T.src]
                local val
                if d <= reach + M then
                    val = { d = d }
                elseif cur and cur.key == key then
                    local since = cur.since or now
                    if now - since < Audibility.PICK_HOLD then val = { d = d, since = since } end
                end
                if not val then return end
                if not mine then mine = {}; pick[line.id] = mine end
                local P = mine[T.src]
                if P and P.d <= d then return end                   -- nearer to another of the line's devices
                val.key = key
                val.level = d <= reach and math.max(0.1, math.floor((1 - d / reach) * 10 + 0.5) / 10) or 0
                mine[T.src] = val
            end
            local gx, gy = math.floor(A.x / size), math.floor(A.y / size)
            for x = gx - 1, gx + 1 do
                for y = gy - 1, gy + 1 do
                    local cell = grid[square(A.bucket, x, y)]
                    if cell then for i = 1, #cell do consider(cell[i]) end end
                end
            end
            -- Held ones wherever they are now (walked off fast): silent until the hold runs out.
            for t, cur in pairs(was) do
                if cur.key == key and bySrc[t] and bySrc[t].speaks then consider(bySrc[t]) end
            end
        end
    end
    -- Who hears each one: every other member of that line who is here (oldest line first, if two lines
    -- pick up the same person for the same listener).
    local pickTo = {}          -- [listener][talker] = { line, key, level }
    for _, line in ipairs(inOrder(lines)) do
        local set = pick[line.id]
        if set then
            for t, P in pairs(set) do
                local holder = nodes[P.key] and nodes[P.key].owner
                for l in pairs(line.members) do
                    if bySrc[l] and l ~= holder and l ~= t then
                        local to = pickTo[l]
                        if not to then to = {}; pickTo[l] = to end
                        if not to[t] then to[t] = { line = line.id, key = P.key, level = P.level } end
                    end
                end
            end
        end
    end
    state.pick, state.pickTo = pick, pickTo
end

--- Everything each listener hears on each track, and from where: their own device (state.links), a node near them
--- (state.spk), and on the voice track people picked up by a device on speaker (state.pickTo). Run after the steps.
--- The diffs are what the listener's page is told.
---@param state table   the same table as the others (reads state.links, state.spk, state.nodes; keeps state.routes)
---@return table adds      [track][listener] = { { talker, q, via, line }, ... } (via = a node key, or nil)
---@return table removes   [track][listener] = { { talker, line }, ... }
---@return table changed   [track][listener] = { [talker] = q }
---@return table rerouted  [track][listener] = { [talker] = via or false }   heard from somewhere else now
---@return table leveled   [track][listener] = { [talker] = level }   a picked-up talker nearer or further
function Audibility.lineRoutes(state)
    local links, spk, dists, nodes = state.links or {}, state.spk or {}, state.spkDist or {}, state.nodes or {}
    local oldAll = state.routes or {}
    local routesAll = {}
    local A, R, C, V, Lv = {}, {}, {}, {}, {}
    local tracks = {}
    for t in pairs(links) do tracks[t] = true end
    for t in pairs(oldAll) do tracks[t] = true end
    if state.pickTo and next(state.pickTo) then tracks.voice = true end
    for track in pairs(tracks) do
        local direct, old = links[track] or {}, oldAll[track] or {}
        local routes = {}
        -- A listener near no node hears exactly what their own device receives: the same table (no
        -- copy). The usual case, and the only one while nobody has a speaker on.
        for l, set in pairs(direct) do routes[l] = set end
        local bestVia, bestD, bestHeard, bestLink = {}, {}, {}, {}
        for l, set in pairs(spk) do
            local own, was = direct[l] or {}, old[l] or {}
            local any = false
            for key in pairs(set) do
                local N = nodes[key]
                if N and N.track == track then
                    local d = dists[l] and dists[l][key] or math.huge
                    for s, link in pairs(direct[N.owner] or {}) do
                        if link.line == N.line and s ~= l and not own[s] then
                            -- Heard: close enough to hear, and the device still receives them (not only held).
                            local heard = d <= N.range and link.q > 0
                            local b = bestVia[s]
                            local keep = was[s] and was[s].via
                            local take
                            if not b then take = true
                            elseif heard ~= bestHeard[s] then take = heard
                            elseif key == keep then take = true
                            elseif b == keep then take = false
                            else take = d < bestD[s] end
                            if take then bestVia[s], bestD[s], bestHeard[s], bestLink[s] = key, d, heard, link end
                            any = true
                        end
                    end
                end
            end
            if any then
                local mine = {}
                for s, link in pairs(own) do mine[s] = link end
                for s, key in pairs(bestVia) do mine[s] = { q = bestLink[s].q, via = key, line = bestLink[s].line } end
                routes[l] = mine
                for s in pairs(bestVia) do bestVia[s], bestD[s], bestHeard[s], bestLink[s] = nil, nil, nil, nil end
            end
        end
        -- The people picked up by a device on speaker, on the voice track — for a listener who does not
        -- already hear them through a line (their own device, or a node near them, wins).
        if track == 'voice' then
            for l, set in pairs(state.pickTo or {}) do
                local mine, copied = routes[l], false
                for t, p in pairs(set) do
                    if not (mine and mine[t]) then
                        if not copied then
                            local m2 = {}
                            for s, r in pairs(mine or {}) do m2[s] = r end   -- (never the link table itself)
                            mine, copied = m2, true
                            routes[l] = mine
                        end
                        mine[t] = { q = 1, line = p.line, level = p.level, pick = p.key }
                    end
                end
            end
        end

        local adds, removes, changed, rerouted, leveled = {}, {}, {}, {}, {}
        for l, mine in pairs(routes) do
            local had = old[l] or {}
            for s, r in pairs(mine) do
                local was = had[s]
                if not was or was.line ~= r.line then
                    -- New, or through another line now (another recipe): out, then in again.
                    if was then removes[l] = removes[l] or {}; table.insert(removes[l], { s, was.line }) end
                    adds[l] = adds[l] or {}
                    table.insert(adds[l], { s, r.q, r.via, r.line, r.level })
                else
                    if was.q ~= r.q then changed[l] = changed[l] or {}; changed[l][s] = r.q end
                    if was.via ~= r.via then rerouted[l] = rerouted[l] or {}; rerouted[l][s] = r.via or false end
                    if was.level ~= r.level then leveled[l] = leveled[l] or {}; leveled[l][s] = r.level or 1 end
                end
            end
        end
        for l, had in pairs(old) do
            local mine = routes[l] or {}
            for s, was in pairs(had) do
                if not mine[s] then removes[l] = removes[l] or {}; table.insert(removes[l], { s, was.line }) end
            end
        end
        routesAll[track] = routes
        A[track], R[track], C[track], V[track], Lv[track] = adds, removes, changed, rerouted, leveled
    end
    state.routes = routesAll
    return A, R, C, V, Lv
end

--- Who may hear each talker on each track through a line: everyone who hears them on one — on their
--- own device or out of a node. [track][talker] = { listener, ... }
function Audibility.lineAllowLists(state)
    local out = {}
    for track, routes in pairs(state.routes or state.links or {}) do
        local T = {}
        out[track] = T
        for l, set in pairs(routes) do
            for s in pairs(set) do
                T[s] = T[s] or {}
                table.insert(T[s], l)
            end
        end
    end
    return out
end

-- How far a crowd must thin below a CrowdQuality line before the quality comes back up.
Audibility.CROWD_BACK = 5

--- Crowd quality (Config.CrowdQuality): the bitrate a speaker heard by `count` listeners should use, or nil for their
--- normal quality. `current` is kept until the crowd has thinned CROWD_BACK below its line.
function Audibility.crowdKbps(count, current)
    local want
    for _, line in ipairs(Config and Config.CrowdQuality or {}) do
        local n, kbps = tonumber(line.listeners), tonumber(line.bitrateKbps)
        if n and kbps then
            local holds = count >= n or (current == kbps and count >= n - Audibility.CROWD_BACK)
            if holds and (not want or kbps < want) then want = kbps end
        end
    end
    return want
end

--- Who may hear each speaker: the inverse of state.hears. [speaker] = { listener, ... }
function Audibility.allowLists(state)
    local out = {}
    for l, set in pairs(state.hears or {}) do
        for s in pairs(set) do
            out[s] = out[s] or {}
            table.insert(out[s], l)
        end
    end
    return out
end
