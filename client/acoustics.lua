-- How a voice travels (the rules, with no FiveM in them): descriptions of the listener, the speaker and the buildings
-- around them in, one answer out. client/environment.lua reads the game world and feeds it.
--
-- Like GTA, a voice takes the cheapest way through the map's rooms and doorways (portals) from the speaker's room to
-- the listener's, and every doorway, closed door or window on the way muffles it. It is heard from the doorway it came
-- out of, not through the wall. Where the map knows no rooms, a line-of-sight check decides: a wall between two heads
-- muffles.
--
-- The answer for one voice:
--   g    dB added (0 = untouched, negative = quieter)
--   f    Hz, where the muffle filter starts cutting treble (22000 = open)
--   at   {x, y, z} where the voice seems to come from, or nil for the speaker's own head
--   p    metres the sound travels (via the doorway), or nil for straight
--   via  the opening it is heard from (kept for next time, never sent to the page)
--   why  a few words for /voicedebug

Acoustics = {}

-- How much each thing in the way takes off (dB) and where it starts cutting treble (Hz).
-- Overridden by Config.Muffle (config.lua) where set.
Acoustics.COST = {
    doorway  = { db = 3,  hz = 9000 },   -- an open doorway or an open door
    door     = { db = 12, hz = 900  },   -- a closed door
    window   = { db = 12, hz = 1100 },   -- a window: as muffled as a closed door, a little brighter (glass)
    wall     = { db = 14, hz = 800  },   -- a wall with no known way round (line of sight blocked)
    building = { db = 22, hz = 450  },   -- inside a building the map knows nothing about, you outside
    car      = { db = 9,  hz = 1300 },   -- one of you in a closed car
    cars     = { db = 16, hz = 850  },   -- each in a different closed car
    underwaterListener = { db = 8,  hz = 500 },   -- your head underwater: everyone sounds far off
    underwaterSpeaker  = { db = 18, hz = 350 },   -- theirs underwater, yours not: a gurgle
}

local OPEN_HZ = 22000
local MAX_DB = 45          -- beyond this, it is silent anyway
local STACK = 0.8          -- each extra obstacle lowers the cutoff a little further
local STICKY = 1.5         -- dB head start for the opening a voice already comes through

-- ---- Rotations: interiors store rooms and doorways relative to themselves ---------------------------

--- Rotate v by the unit quaternion q = {x, y, z, w}.
function Acoustics.rotate(q, v)
    local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
    -- t = 2 * cross(q.xyz, v); v' = v + w * t + cross(q.xyz, t)
    local tx = 2 * (qy * v[3] - qz * v[2])
    local ty = 2 * (qz * v[1] - qx * v[3])
    local tz = 2 * (qx * v[2] - qy * v[1])
    return {
        v[1] + qw * tx + (qy * tz - qz * ty),
        v[2] + qw * ty + (qz * tx - qx * tz),
        v[3] + qw * tz + (qx * ty - qy * tx),
    }
end

function Acoustics.conj(q) return { -q[1], -q[2], -q[3], q[4] } end

--- Interior-relative -> world. `conv` is 1 (the rotation as given) or -1 (its conjugate): which one a
--- game build stores is worked out by Acoustics.calibrate, never assumed.
function Acoustics.toWorld(interior, v, conv)
    local q = conv == -1 and Acoustics.conj(interior.rot) or interior.rot
    local r = Acoustics.rotate(q, v)
    return { interior.pos[1] + r[1], interior.pos[2] + r[2], interior.pos[3] + r[3] }
end

function Acoustics.toLocal(interior, w, conv)
    local q = conv == -1 and interior.rot or Acoustics.conj(interior.rot)
    return Acoustics.rotate(q, { w[1] - interior.pos[1], w[2] - interior.pos[2], w[3] - interior.pos[3] })
end

local function inBox(p, box, pad)
    pad = pad or 0.75
    return p[1] >= box[1] - pad and p[1] <= box[4] + pad
       and p[2] >= box[2] - pad and p[2] <= box[5] + pad
       and p[3] >= box[3] - pad and p[3] <= box[6] + pad
end

--- Which way round is the rotation? Someone known to stand in `room` must land inside that room's box when their world
--- position is taken back into the interior. Answers 1, -1, or nil for "not sure yet" (asked again later). In a room
--- that sits evenly around the interior's centre both rotations can fit, so it waits for a spot that tells them apart.
function Acoustics.calibrate(interior, room, world)
    local box = interior.rooms[room] and interior.rooms[room].box
    if not box then return nil end
    local la, lb = Acoustics.toLocal(interior, world, 1), Acoustics.toLocal(interior, world, -1)
    local a, b = inBox(la, box), inBox(lb, box)
    if a and b then
        local dx, dy, dz = la[1] - lb[1], la[2] - lb[2], la[3] - lb[3]
        return (dx * dx + dy * dy + dz * dz) < 0.25 and 1 or nil
    end
    if a then return 1 end
    if b then return -1 end
    return nil
end

-- ---- Paths through the doorways ------------------------------------------------------------------

--- What a portal costs to pass right now.
local function portalCost(p, doorOpen)
    if p.kind == 'door' then
        if doorOpen and doorOpen(p) then return Acoustics.COST.doorway, 'open door' end
        return Acoustics.COST.door, 'closed door'
    elseif p.kind == 'window' then
        return Acoustics.COST.window, 'window'
    end
    return Acoustics.COST.doorway, 'doorway'
end

--- The cheapest way from room `a` to room `b` of one interior (room 0 is outside it).
--- `pick` (optional) scores a portal that leads OUT of the interior, so the exit nearest the other
--- person is preferred. Answers { db, hz, n, portals = {...}, kinds = {...} } or nil.
function Acoustics.route(interior, a, b, doorOpen, pick)
    if a == b then return { db = 0, hz = OPEN_HZ, n = 0, portals = {}, kinds = {} } end
    local best, prev, done = { [a] = 0 }, {}, {}
    while true do
        local room, low = nil, math.huge
        for r, d in pairs(best) do if not done[r] and d < low then room, low = r, d end end
        if room == nil then return nil end
        if room == b then break end
        done[room] = true
        for _, p in ipairs(interior.portals) do
            if p.kind ~= 'mirror' then
                local other = (p.from == room and p.to) or (p.to == room and p.from) or nil
                if other and not done[other] then
                    local c = portalCost(p, doorOpen)
                    local extra = (other == b and b == 0 and pick) and pick(p) or 0
                    local d = low + c.db + extra
                    if best[other] == nil or d < best[other] then best[other] = d; prev[other] = p end
                end
            end
        end
    end
    local out = { db = 0, hz = OPEN_HZ, n = 0, portals = {}, kinds = {} }
    local room = b
    while room ~= a do
        local p = prev[room]
        local c, kind = portalCost(p, doorOpen)
        out.db = out.db + c.db
        out.hz = math.min(out.hz, c.hz)
        out.n = out.n + 1
        table.insert(out.portals, 1, p)
        table.insert(out.kinds, 1, kind)
        room = (p.from == room) and p.to or p.from
    end
    return out
end

-- ---- One voice -------------------------------------------------------------------------------------

local function dist(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function muffle()
    return { db = 0, hz = OPEN_HZ, n = 0, why = {} }
end

local function add(m, cost, why)
    if not cost then return end
    m.db = m.db + cost.db
    m.hz = math.min(m.hz, cost.hz)
    m.n = m.n + 1
    if why then m.why[#m.why + 1] = why end
end

local function addRoute(m, r)
    if not r then return end
    m.db = m.db + r.db
    m.hz = math.min(m.hz, r.hz)
    m.n = m.n + r.n
    for _, k in ipairs(r.kinds) do m.why[#m.why + 1] = k end
end

--- Where a portal is in the world, if this interior's rotation is known.
local function portalAt(interior, p)
    if not interior or not interior.conv or not p or not p.center then return nil end
    return Acoustics.toWorld(interior, p.center, interior.conv)
end

--- A scorer for the ways out of a building: each metre between the opening and the other person costs what it costs
--- in loudness, the voice's own fade (html/js/audio.js), `slope` dB per metre. The opening that is loudest where they
--- stand wins: a window beside you beats a door round the corner.
local function nearest(interior, pos, slope)
    if not interior or not interior.conv then return nil end
    return function(p)
        local w = portalAt(interior, p)
        return w and dist(w, pos) * slope or 0
    end
end

--- dB per metre of a voice's fade, for a speaker with this range (a steady fade to -30 dB between the full-volume
--- circle and the edge; html/js/audio.js). Used only to choose between openings. The circle is
--- Config.FullVolumeWithin, but at most FULL_SHARE of the range, as on the page.
local FULL_SHARE = 0.15
function Acoustics.slope(range, fullWithin)
    range = tonumber(range) or 8
    local full = math.min(tonumber(fullWithin) or 1, range * FULL_SHARE)
    return 30 / math.max(1, range - full)
end

-- ---- The whole journey ------------------------------------------------------------------------------

-- A way that costs more than this cannot be heard at any range (the fade uses up its range by 36 dB of distance, and
-- past MAX_DB of muffle it is silent anyway). The search goes no further, which keeps it small in big buildings.
local HOPELESS = 36 + MAX_DB

-- A place is one room of one building, or 'out': outside every building.
local function place(int, room)
    if int == 0 or room == 0 then return 'out' end
    return int .. ':' .. room
end

--- One building's openings, in the world. Openings do not move, so this is worked out once per
--- building (again only if its rotation is worked out differently).
local function openingsOf(id, I)
    local g = I.openings
    if g and g.conv == I.conv then return g end
    g = { conv = I.conv, list = {} }
    for _, p in ipairs(I.portals) do
        if p.kind ~= 'mirror' and p.center then
            g.list[#g.list + 1] = { p = p, at = Acoustics.toWorld(I, p.center, I.conv), a = place(id, p.from), b = place(id, p.to) }
        end
    end
    I.openings = g
    return g
end

--- The openings of these buildings as one map, joined outside: nodes, and which nodes each place has.
local function mapOf(ids, interiors)
    local m = { nodes = {}, byPlace = {}, index = {} }
    for _, id in ipairs(ids) do
        for _, n in ipairs(openingsOf(id, interiors[id]).list) do
            local i = #m.nodes + 1
            m.nodes[i] = n
            m.index[n.p] = i
            m.byPlace[n.a] = m.byPlace[n.a] or {}
            table.insert(m.byPlace[n.a], i)
            if n.b ~= n.a then
                m.byPlace[n.b] = m.byPlace[n.b] or {}
                table.insert(m.byPlace[n.b], i)
            end
        end
    end
    return m
end

-- A binary heap of (cost, node), in two arrays: the search takes the cheapest next.
local function heapPush(hc, hi, c, i)
    local n = #hc + 1
    hc[n], hi[n] = c, i
    while n > 1 do
        local up = n // 2
        if hc[up] <= hc[n] then break end
        hc[up], hc[n], hi[up], hi[n] = hc[n], hc[up], hi[n], hi[up]
        n = up
    end
end

local function heapPop(hc, hi)
    local n = #hc
    if n == 0 then return nil end
    local c, i = hc[1], hi[1]
    hc[1], hi[1] = hc[n], hi[n]
    hc[n], hi[n] = nil, nil
    n = n - 1
    local k = 1
    while true do
        local l, r, m = k * 2, k * 2 + 1, k
        if l <= n and hc[l] < hc[m] then m = l end
        if r <= n and hc[r] < hc[m] then m = r end
        if m == k then break end
        hc[m], hc[k], hi[m], hi[k] = hc[k], hc[m], hi[k], hi[m]
        k = m
    end
    return c, i
end

--- Outward from the listener, once: what it costs to carry sound from each opening to the listener's head. The cost
--- of a way is the same in either direction, so one search from the listener serves every speaker.
---   d[i]     that cost, in dB
---   next[i]  the next opening towards the listener (0 = straight to the listener)
---   seeds    the openings the listener can reach directly (usually every opening of their room)
local function outward(m, from, seeds, slope, doorOpen)
    local d, nxt, done = {}, {}, {}
    local hc, hi = {}, {}
    local cut = false
    for _, i in ipairs(seeds) do
        local n = m.nodes[i]
        local c = slope * dist(from, n.at) + portalCost(n.p, doorOpen).db
        if c > HOPELESS then cut = true
        elseif d[i] == nil or c < d[i] then d[i], nxt[i] = c, 0; heapPush(hc, hi, c, i) end
    end
    while true do
        local c, u = heapPop(hc, hi)
        if not c or not u then break end
        if not done[u] then
            done[u] = true
            local nu = m.nodes[u]
            for side = 1, (nu.b ~= nu.a) and 2 or 1 do
                for _, j in ipairs(m.byPlace[side == 1 and nu.a or nu.b]) do
                    if not done[j] then
                        local nj = m.nodes[j]
                        local cj = c + slope * dist(nu.at, nj.at) + portalCost(nj.p, doorOpen).db
                        if cj > HOPELESS then cut = true
                        elseif d[j] == nil or cj < d[j] then d[j], nxt[j] = cj, u; heapPush(hc, hi, cj, j) end
                    end
                end
            end
        end
    end
    return { d = d, next = nxt, cut = cut }
end

--- The best way from a speaker into a search's answer: the opening on the speaker's side that makes
--- the whole journey cheapest.
local function arrive(m, s, S, startPlace, slope)
    local best, bi = math.huge, nil
    for _, i in ipairs(m.byPlace[startPlace] or {}) do
        local di = s.d[i]
        if di then
            local t = di + slope * dist(S.pos, m.nodes[i].at)
            if t < best then best, bi = t, i end
        end
    end
    return best, bi
end

--- The whole journey: the way through the doorways and windows that arrives loudest at the listener.
--- Every metre from the speaker's head, through each opening in turn, to the listener's head costs `slope` dB, and
--- every opening costs its own dB. The cheapest total is the loudest at the listener's ears, and the voice is heard
--- from the last opening before the listener. Openings are nodes; from one you can go on to any opening of either room
--- it joins. Every building involved must know its rotation (Acoustics.calibrate); otherwise nil, and the caller uses
--- the room-by-room route.
--- `keep` is the opening chosen last time; it wins ties by sticky dB so a voice does not flick between two near-equal
--- windows.
--- `pass` (optional) is a table the caller keeps for one round of voices: the search out from the listener is done
--- once per range and set of buildings, and every speaker is read off it.
---@return table|nil { db, hz, n, kinds = {...}, last = {x,y,z}, via = portal, length = metres }
function Acoustics.through(L, S, interiors, doorOpen, slope, keep, pass)
    local li, si = L.int or 0, S.int or 0
    local ids = {}
    for _, id in ipairs({ li, si }) do
        if id ~= 0 and ids[#ids] ~= id then
            local I = interiors[id]
            if not I or not I.conv then return nil end
            ids[#ids + 1] = id
        end
    end
    pass = pass or {}
    local key = slope .. '|' .. table.concat(ids, ',')
    local m = pass['map|' .. key] or mapOf(ids, interiors)
    pass['map|' .. key] = m
    local startPlace, goalPlace = place(si, S.room), place(li, L.room)

    local s = pass[key] or outward(m, L.pos, m.byPlace[goalPlace] or {}, slope, doorOpen)
    pass[key] = s
    local best, bi = arrive(m, s, S, startPlace, slope)

    -- The opening used last time wins unless another is clearly (STICKY dB) better: the best way that
    -- reaches the listener through it is found by a search that starts from it alone.
    if keep and bi then
        local root = bi
        while s.next[root] ~= 0 do root = s.next[root] end
        local ki = m.index[keep]
        local kn = ki and m.nodes[ki]
        if ki ~= root and kn and (kn.a == goalPlace or kn.b == goalPlace) then
            local sk = pass[key .. '|' .. ki] or outward(m, L.pos, { ki }, slope, doorOpen)
            pass[key .. '|' .. ki] = sk
            local kb, kbi = arrive(m, sk, S, startPlace, slope)
            if kbi and kb - STICKY <= best then s, best, bi = sk, kb, kbi end
        end
    end

    -- Every way round is too long or too muffled to hear: silent. (No way round at all: nil, and the
    -- caller falls back to the room-by-room route.)
    if (bi and best > HOPELESS) or (not bi and s.cut) then
        return { db = MAX_DB, hz = Acoustics.COST.building.hz, n = 1, kinds = { 'too far round' }, length = 1e4 }
    end
    if not bi then return nil end

    local out = { db = 0, hz = OPEN_HZ, n = 0, kinds = {}, length = 0 }
    local from, i = S.pos, bi
    while i ~= 0 do
        local n = m.nodes[i]
        local c, kind = portalCost(n.p, doorOpen)
        out.db = out.db + c.db
        out.hz = math.min(out.hz, c.hz)
        out.n = out.n + 1
        out.kinds[#out.kinds + 1] = kind
        out.length = out.length + dist(from, n.at)
        out.last, out.via = n.at, n.p
        from, i = n.at, s.next[i]
    end
    out.length = out.length + dist(from, L.pos)
    return out
end

--- How one speaker sounds to one listener.
---@param L table   { int, room, pos = {x,y,z}, veh, cabin (closed car), water }
---@param S table   the same, for the speaker
---@param interiors table  [int] = { pos, rot, conv, rooms = {[i] = {box}}, portals = {{from, to, kind, center}} }
---@param doorOpen fun(p: table): boolean|nil
---@param blocked boolean|nil  line of sight between the two heads is blocked (outdoors / unknown rooms)
---@param slope number|nil  dB per metre of the speaker's fade (Acoustics.slope), for choosing openings
---@param keep table|nil  the opening this voice came through last time (the answer's `via`)
---@param pass table|nil  shared by every voice of one update, so the search is done once (see through)
function Acoustics.voice(L, S, interiors, doorOpen, blocked, slope, keep, pass)
    slope = slope or Acoustics.slope(8, 3)
    local m = muffle()
    local at, p, via = nil, nil, nil
    local li, si = L.int or 0, S.int or 0
    local LI, SI = interiors[li], interiors[si]

    -- THE WHOLE JOURNEY FIRST, wherever the buildings' positions are known: the loudest way through
    -- the openings, heard from the last one before the listener (Acoustics.through).
    local inside = li ~= 0 or si ~= 0
    local sameRoom = li ~= 0 and li == si and L.room == S.room
    local j = inside and not sameRoom and Acoustics.through(L, S, interiors, doorOpen, slope, keep, pass) or nil
    if j then
        addRoute(m, j)
        at, p, via = j.last, j.length, j.via
    elseif sameRoom then
        -- Same room: nothing in the way.
    elseif li ~= 0 and li == si then
        -- The same building.
        if L.room ~= S.room then
            local r = LI and Acoustics.route(LI, S.room, L.room, doorOpen)
            if r then
                addRoute(m, r)
                at = portalAt(LI, r.portals[#r.portals])        -- the doorway into the listener's room
            elseif blocked then
                add(m, Acoustics.COST.wall, 'wall')
            end
        end
    elseif si ~= 0 and li == 0 then
        -- The speaker is inside, the listener outside: out through the nearest way out.
        local r = SI and Acoustics.route(SI, S.room, 0, doorOpen, nearest(SI, L.pos, slope))
        if r then addRoute(m, r); at = portalAt(SI, r.portals[#r.portals])
        else add(m, blocked and Acoustics.COST.building or Acoustics.COST.doorway, 'inside a building') end
    elseif li ~= 0 and si == 0 then
        -- The listener is inside, the speaker outside: in through the way in nearest them. The route
        -- runs from the listener's room outwards, so its FIRST opening is the one on the listener's side.
        local r = LI and Acoustics.route(LI, L.room, 0, doorOpen, nearest(LI, S.pos, slope))
        if r then addRoute(m, r); at = portalAt(LI, r.portals[1])
        else add(m, blocked and Acoustics.COST.building or Acoustics.COST.doorway, 'you are inside') end
    elseif li ~= 0 and si ~= 0 then
        -- Two different buildings: out of theirs, into yours.
        local out = SI and Acoustics.route(SI, S.room, 0, doorOpen, nearest(SI, L.pos, slope))
        local inn = LI and Acoustics.route(LI, L.room, 0, doorOpen, nearest(LI, S.pos, slope))
        if out then addRoute(m, out) else add(m, Acoustics.COST.building, 'their building') end
        if inn then addRoute(m, inn); at = portalAt(LI, inn.portals[1])
        else add(m, Acoustics.COST.building, 'your building') end
    elseif blocked then
        -- Both outside, something solid between the two heads.
        add(m, Acoustics.COST.wall, 'wall')
    end
    if at and not p then p = dist(S.pos, at) + dist(at, L.pos) end

    -- Cars: muffled between inside and outside a closed car; clear inside the same car.
    if not (L.veh and L.veh ~= 0 and L.veh == S.veh) then
        local closed = (L.cabin and 1 or 0) + (S.cabin and 1 or 0)
        if closed == 1 then add(m, Acoustics.COST.car, 'car')
        elseif closed == 2 then add(m, Acoustics.COST.cars, 'two cars') end
    end

    -- Water.
    if L.water then add(m, Acoustics.COST.underwaterListener, 'you are underwater')
    elseif S.water then add(m, Acoustics.COST.underwaterSpeaker, 'they are underwater') end

    local hz = m.hz
    if m.n > 1 then hz = hz * (STACK ^ (m.n - 1)) end
    return {
        g = -math.min(m.db, MAX_DB),
        f = m.n > 0 and math.max(200, math.floor(hz)) or OPEN_HZ,
        at = at,
        p = p,
        via = via,     -- stays in Lua (client/main.lua copies only g, f, at, p to the page)
        why = #m.why > 0 and table.concat(m.why, ' + ') or 'clear',
    }
end

--- The echo of the room the listener stands in, from its size: nil outside or unknown.
---@return string|nil preset 'small' | 'room' | 'hall' | 'large'
function Acoustics.reverbFor(interior, room)
    if not interior or not room or room <= 0 then return nil end
    local r = interior.rooms[room]
    if not r or not r.box then return nil end
    local b = r.box
    local vol = math.abs((b[4] - b[1]) * (b[5] - b[2]) * (b[6] - b[3]))
    if vol < 35 then return 'small' end      -- a bathroom, a cupboard
    if vol < 180 then return 'room' end      -- a bedroom, a kitchen
    if vol < 900 then return 'hall' end      -- a big lounge, a shop floor
    return 'large'                           -- a warehouse, a garage, a hangar
end
