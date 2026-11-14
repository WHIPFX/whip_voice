-- ============================================
-- whip_voice — the way round, outdoors
-- ============================================
--
-- Outdoors the map has no rooms and doorways. So when a voice's straight line to the listener is blocked (a building's
-- corner, a walled yard with one way in), whip_voice finds the way the sound really goes on a grid of the open ground:
-- 2 m squares, each a point at head height above its ground, joined to its eight neighbours where nothing stands between
-- them (a ray each, kept a minute). The shortest way through them, pulled straight to the corner it bends round, is how
-- far the sound travels; how sharply it bends there decides the muffle (Acoustics.around); and that corner is where it
-- seems to come from.
--
-- A WAY, ONCE FOUND, IS FOLLOWED: it keeps a point beside its corner that can be seen from a good way round (its
-- anchor), and each pass the corner is found again from where the listener now stands, along the line from the anchor
-- on (Ways.follow: a few rays). So walking about, the bend changes a little at each step and so does the sound, and no
-- search is needed until the listener can no longer see the anchor.
--
-- A search spends rays out of a budget the caller hands it each pass, and squares out of a quota; when either runs out
-- it pauses, and the next pass carries on where it stopped (every ray's answer is kept, too).
--
--   local s = Ways.start(from, to, own, maxLen)
--   Ways.step(s, budget, quota) -> way | false (no way within maxLen) | nil (not done yet: step it again next pass)
--   Ways.follow(way, from, to, own, budget) -> { len, at, d, turns } | false (from no longer sees the way) | nil (no rays)
--     from, to   {x, y, z}: the listener's head, the voice
--     own        the voice's own object (a speaker's prop: a ray to its middle ends inside it), or nil
--     maxLen     metres: a way longer than this cannot be heard, so it is not looked for
--     budget     { left = rays it may spend }; what it spent is taken off
--   len  metres the sound travels   at  {x, y, z} the corner it is heard from   d  metres more than the straight line
--   turns  degrees it bends at each corner

Ways = {}

local CELL = 2.0            -- metres per square
local ABOVE = 1.5           -- a square's point: this high above its ground
local CLIMB = 2.0           -- neighbours further apart in height than this are not joined (a wall top, a cliff)
local MAX_SQUARES = 2000    -- squares one search looks at, at most (over as many passes as it takes)
local EXPAND_RAYS = 24      -- rays one square's look round can take (eight joins and their grounds)
local KEEP_MS = 60000       -- what a ray found is kept this long (props, gates and doors come and go)
local BAND = 6.0            -- a square's ground is looked for again by a search starting this much higher or lower
local MAX_KEPT = 20000      -- answers kept; past this they are all forgotten and found again
local EDGE_STEPS = 6        -- halvings to find a corner (to 1/64 of the line it is on)

local probe                 -- probe(from, to, flags) -> answered, hit, pos, entity (client/environment.lua)
function Ways.setProbe(fn) probe = fn end

local grounds = {}   -- [square] = { z = its ground (false: none found), top = where the ray down began, at = when }
local joins = {}     -- [square * 4 + direction] = { open, at }
local kept = 0

local OFF = 50000
local function keyOf(cx, cy) return (cx + OFF) * 100000 + (cy + OFF) end

local function len(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function pointOf(cx, cy, z) return { (cx + 0.5) * CELL, (cy + 0.5) * CELL, z + ABOVE } end

-- The eight neighbours: { dx, dy, join direction, kept under the neighbour }. Each join is kept once, under the square
-- it goes forward from (directions 0..3: east, north, north-east, north-west).
local NEIGHBOURS = {
    { 1, 0, 0, false }, { 0, 1, 1, false }, { 1, 1, 2, false }, { -1, 1, 3, false },
    { -1, 0, 0, true }, { 0, -1, 1, true }, { -1, -1, 2, true }, { 1, -1, 3, true },
}

local function spend(budget)
    if budget.left < 1 then return false end
    budget.left = budget.left - 1
    return true
end

--- A square's ground: its height, false for none (inside a building's block, no map loaded), nil when unknown and no
--- rays are left. Looked for straight down from `top`: a roof lower than that is the ground there.
local function groundOf(cx, cy, top, budget, now)
    local k = keyOf(cx, cy)
    local g = grounds[k]
    if g and now - g.at < KEEP_MS and math.abs(g.top - top) < BAND then return g.z end
    if not spend(budget) then return nil end
    local x, y = (cx + 0.5) * CELL, (cy + 0.5) * CELL
    local answered, hit, pos = probe({ x, y, top }, { x, y, top - 12.0 }, 1)
    if not answered then return nil end
    if not g then kept = kept + 1 end
    grounds[k] = { z = (hit and pos) and pos.z or false, top = top, at = now }
    return grounds[k].z
end

--- Is a square joined to one of its neighbours? true, false, or nil when unknown and no rays are left. The ray goes
--- FROM the square being looked round (reached from the listener, so in the open) to the neighbour, so a wall between
--- is met from its outside.
local function joined(cx, cy, nb, top, budget, now)
    local ox, oy = cx, cy
    if nb[4] then ox, oy = cx + nb[1], cy + nb[2] end
    local k = keyOf(ox, oy) * 4 + nb[3]
    local j = joins[k]
    if j and now - j.at < KEEP_MS then return j.open end
    local za = groundOf(cx, cy, top, budget, now)
    if za == nil then return nil end
    local zb = groundOf(cx + nb[1], cy + nb[2], top, budget, now)
    if zb == nil then return nil end
    local open = false
    if za and zb and math.abs(za - zb) <= CLIMB then
        if not spend(budget) then return nil end
        local answered, hit = probe(pointOf(cx, cy, za), pointOf(cx + nb[1], cy + nb[2], zb), 1 + 16)
        if not answered then return nil end
        open = not hit
    end
    if not j then kept = kept + 1 end
    joins[k] = { open = open, at = now }
    return open
end

--- Does `p` see `q`? (The voice's own object in the way does not count.) nil when no rays are left.
local function sees(p, q, own, budget)
    if not spend(budget) then return nil end
    local answered, hit, _, ent = probe(p, q, 1 + 16)
    if not answered then return nil end
    return not hit or (own ~= nil and own ~= 0 and ent == own)
end

--- The furthest point along p -> q that `eye` sees (it sees p), by halving. nil when no rays are left.
local function edgeOf(eye, p, q, own, budget)
    if budget.left < EDGE_STEPS then return nil end
    local lo, hi = 0.0, 1.0
    for _ = 1, EDGE_STEPS do
        local mid = (lo + hi) / 2
        if sees(eye, { p[1] + (q[1] - p[1]) * mid, p[2] + (q[2] - p[2]) * mid, p[3] + (q[3] - p[3]) * mid }, own, budget) then
            lo = mid
        else
            hi = mid
        end
    end
    return { p[1] + (q[1] - p[1]) * lo, p[2] + (q[2] - p[2]) * lo, p[3] + (q[3] - p[3]) * lo }
end

--- Where a way goes from where the listener now stands: the corner found again along the line from its anchor on, the
--- way's length, how much longer than the straight line, its bends. false when `from` no longer sees the anchor (the
--- way is no good from here); nil when no rays are left.
---@param way table  { anchor, toward, rest = { len, after, turns } | nil } (Ways.step, or environment.lua's close look)
function Ways.follow(way, from, to, own, budget)
    if budget.left < EDGE_STEPS + 1 then return nil end
    local seen = sees(from, way.anchor, nil, budget)
    if seen == nil then return nil end
    if not seen then return false end
    local ownE = nil                   -- (the line ends inside the voice's own object only when it runs to the voice)
    if not way.rest then ownE = own end
    local c = edgeOf(from, way.anchor, way.toward, ownE, budget)
    if not c then return nil end
    local total, turns
    if way.rest then
        -- Bends further on: from the corner to the way's next point, then the rest as it was found.
        total = len(from, c) + len(c, way.toward) + way.rest.len
        turns = { Acoustics.turn(from, c, way.rest.after) }
        for _, t in ipairs(way.rest.turns) do turns[#turns + 1] = t end
    else
        total = len(from, c) + len(c, to)
        turns = { Acoustics.turn(from, c, to) }
    end
    return { len = total, at = c, d = math.max(0, total - len(from, to)), turns = turns }
end

-- A small binary heap of squares by their estimate.
local function push(hf, hk, f, k)
    local i = #hf + 1
    hf[i], hk[i] = f, k
    while i > 1 do
        local up = i // 2
        if hf[up] <= hf[i] then break end
        hf[up], hf[i], hk[up], hk[i] = hf[i], hf[up], hk[i], hk[up]
        i = up
    end
end

local function pop(hf, hk)
    local f, k = hf[1], hk[1]
    local n = #hf
    hf[1], hk[1] = hf[n], hk[n]
    hf[n], hk[n] = nil, nil
    n = n - 1
    local i = 1
    while true do
        local l, r, s = i * 2, i * 2 + 1, i
        if l <= n and hf[l] < hf[s] then s = l end
        if r <= n and hf[r] < hf[s] then s = r end
        if s == i then break end
        hf[s], hf[i], hk[s], hk[i] = hf[i], hf[s], hk[i], hk[s]
        i = s
    end
    return f, k
end

--- The squares a point reaches: those of the four nearest it it can see, { { cx, cy, point, metres } ... }; nil when
--- no rays are left.
local function attach(p, top, own, budget, now)
    local x0, y0 = math.floor(p[1] / CELL - 0.5), math.floor(p[2] / CELL - 0.5)
    local out = {}
    for i = 0, 1 do
        for j = 0, 1 do
            local cx, cy = x0 + i, y0 + j
            local z = groundOf(cx, cy, top, budget, now)
            if z == nil then return nil end
            if z then
                local q = pointOf(cx, cy, z)
                local s = sees(p, q, own, budget)
                if s == nil then return nil end
                if s then out[#out + 1] = { cx, cy, q, len(p, q) } end
            end
        end
    end
    return out
end

--- A new search for the way from `from` to `to`.
function Ways.start(from, to, own, maxLen)
    return { from = from, to = to, own = own, maxLen = tonumber(maxLen) or 40,
             top = math.max(from[3], to[3]) + 2.0, stage = 'attach' }
end

--- Carry a search on: answers the way found, false for none within reach, nil for not done yet.
function Ways.step(s, budget, quota)
    if not probe then return false end
    local now = GetGameTimer()
    if kept > MAX_KEPT then grounds, joins, kept = {}, {}, 0 end
    local from, to = s.from, s.to

    if s.stage == 'attach' then
        local starts = attach(from, s.top, nil, budget, now)
        if not starts then return nil end
        local ends = attach(to, s.top, s.own, budget, now)
        if not ends then return nil end
        if #starts == 0 or #ends == 0 then return false end
        s.goal = {}   -- [square] = metres from it to `to`
        for _, e in ipairs(ends) do s.goal[keyOf(e[1], e[2])] = e[4] end
        s.g, s.parent, s.sq, s.closed = {}, {}, {}, {}
        s.hf, s.hk = {}, {}
        s.best, s.looked = math.huge, 0
        for _, st in ipairs(starts) do
            local k = keyOf(st[1], st[2])
            if not s.g[k] or st[4] < s.g[k] then
                s.g[k], s.parent[k], s.sq[k] = st[4], false, st
                push(s.hf, s.hk, st[4] + len(st[3], to), k)
            end
        end
        s.stage = 'search'
    end

    if s.stage == 'search' then
        -- The shortest way from `from`'s squares to `to`'s (A*: metres so far + the straight line still to go).
        local g, sq, closed, goal, hf, hk = s.g, s.sq, s.closed, s.goal, s.hf, s.hk
        local done = 0
        while true do
            if #hf == 0 or hf[1] >= s.best or hf[1] > s.maxLen or s.looked >= MAX_SQUARES then break end
            if done >= quota or budget.left < EXPAND_RAYS then return nil end   -- carried on next pass
            local _, k = pop(hf, hk)
            if not closed[k] then
                closed[k] = true
                s.looked, done = s.looked + 1, done + 1
                local c = sq[k]
                local gk = g[k]
                if goal[k] and gk + goal[k] < s.best then s.best, s.bestK = gk + goal[k], k end
                for _, nb in ipairs(NEIGHBOURS) do
                    local nx, ny = c[1] + nb[1], c[2] + nb[2]
                    local nk = keyOf(nx, ny)
                    if not closed[nk] then
                        local open = joined(c[1], c[2], nb, s.top, budget, now)
                        -- (A join kept from an earlier search whose square's ground has since been looked for again
                        -- and not found: not joined.)
                        local gz = open and grounds[nk] and grounds[nk].z
                        if gz then
                            local q = pointOf(nx, ny, gz)
                            local ng = gk + len(c[3], q)
                            if not g[nk] or ng < g[nk] then
                                g[nk], s.parent[nk], sq[nk] = ng, k, { nx, ny, q }
                                push(hf, hk, ng + len(q, to), nk)
                            end
                        end
                    end
                end
            end
        end
        if not s.bestK then return false end
        s.path = {}
        local k = s.bestK
        while k do
            table.insert(s.path, 1, sq[k][3])
            k = s.parent[k]
        end
        s.stage = 'pull'
    end

    -- Pulled straight: the furthest square `from` sees (what a point sees along a way is nearly always where the way
    -- starts, so a halving search) is the anchor; from it on, the nearest square `to` sees.
    local path, m = s.path, #s.path
    if budget.left < 2 * math.ceil(math.log(m + 1, 2)) + EDGE_STEPS then return nil end
    local lo, hi = 1, m
    while lo < hi do
        local mid = (lo + hi + 1) // 2
        if sees(from, path[mid], nil, budget) then lo = mid else hi = mid - 1 end
    end
    local a = lo
    lo, hi = a, m
    while lo < hi do
        local mid = (lo + hi) // 2
        if sees(to, path[mid], s.own, budget) then hi = mid else lo = mid + 1 end
    end
    local b = lo
    if b == a then
        -- One bend: both see square a, and `to` sees all the line from it on to `to`.
        return { anchor = path[a], toward = to }
    end
    -- More: the corner is on the way out of square a; the rest is as found, to where `to` starts seeing (its own
    -- corner, found once).
    local c2 = edgeOf(to, path[b], path[b - 1], s.own, budget) or path[b]
    local rest = 0
    for i = a + 1, b - 2 do rest = rest + len(path[i], path[i + 1]) end
    if b - 1 > a then rest = rest + len(path[b - 1], c2) else rest = rest + len(path[a + 1], c2) end
    rest = rest + len(c2, to)
    return { anchor = path[a], toward = path[a + 1],
             rest = { len = rest, after = c2, turns = { Acoustics.turn(path[a + 1], c2, to) } } }
end
