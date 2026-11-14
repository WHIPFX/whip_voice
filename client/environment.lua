-- ============================================
-- whip_voice — reading the world a voice travels through
-- ============================================
--
-- Gathers what client/acoustics.lua needs, from the game: which building and room each player is in,
-- the rooms and doorways of every interior (MLOs included), whether those doors are open, walls in
-- the way outdoors, closed car cabins, and heads underwater.
--
--   Environment.update(meHead, speakers) -> { rv = echo preset or nil, v = { [identity] = answer } }
--
-- Called from the pose loop (client/main.lua) five times a second at most, and only while someone is
-- heard, with the voices due: live ones five times a second, quiet ones once. Interiors are read once
-- each and kept; doors are looked at only on the paths in use.

Environment = {}

-- The muffle strengths from config.lua.
for k, db in pairs(Config.Muffle or {}) do
    if Acoustics.COST[k] then Acoustics.COST[k].db = db end
end
if Config.Muffle and Config.Muffle.car then Acoustics.COST.cars.db = Config.Muffle.car * 1.8 end
local megaCar = tonumber(Config.Megaphone and Config.Megaphone.carMuffle)
if megaCar then Acoustics.COST.carLoud.db, Acoustics.COST.carsLoud.db = megaCar, megaCar * 1.8 end

local E = Config.Environment or {}
local here = 0         -- the interior this player was in at the last pass (for /voicedebug)
local interiors = {}   -- [interior id] = the room map (acoustics.lua's shape), or false when unreadable
local doors = {}       -- [portal] = { open, at }
local probes = {}      -- [identity] = the last line-of-sight answer for that voice (true = blocked)
local via = {}         -- [identity] = the opening that voice came through last pass (so it does not flick)
local DOOR_RECHECK_MS = 500

-- The room-and-doorway natives are FiveM's own (ns CFX). Not every build of FiveM may have them; without
-- them voices fall back to line of sight.
local HAS_ROOMS = GetInteriorPortalCount ~= nil and GetInteriorRoomCount ~= nil
    and GetInteriorRoomIndexByHash ~= nil and GetInteriorPortalCornerPosition ~= nil

--- Read one interior's rooms and doorways (once).
local function readInterior(id)
    local known = interiors[id]
    if known ~= nil then return known or nil end
    if not HAS_ROOMS then interiors[id] = false; return nil end
    local ok, built = pcall(function()
        local px, py, pz = GetInteriorPosition(id)
        local qx, qy, qz, qw = GetInteriorRotation(id)
        local I = { pos = { px, py, pz }, rot = { qx, qy, qz, qw }, conv = nil, rooms = {}, portals = {} }
        for r = 0, GetInteriorRoomCount(id) - 1 do
            local a, b, c, d, e, f = GetInteriorRoomExtents(id, r)
            I.rooms[r] = { box = { math.min(a, d), math.min(b, e), math.min(c, f), math.max(a, d), math.max(b, e), math.max(c, f) } }
        end
        for p = 0, GetInteriorPortalCount(id) - 1 do
            local from, to = GetInteriorPortalRoomFrom(id, p), GetInteriorPortalRoomTo(id, p)
            local sx, sy, sz, lowest = 0.0, 0.0, 0.0, math.huge
            for corner = 0, 3 do
                local x, y, z = GetInteriorPortalCornerPosition(id, p, corner)
                sx, sy, sz = sx + x, sy + y, sz + z
                if z < lowest then lowest = z end
            end
            local kind
            if (GetInteriorPortalFlag(id, p) & 4) ~= 0 then
                kind = 'mirror'                      -- a mirror is drawn as a portal; nothing passes
            else
                -- A WINDOW is an opening whose bottom edge sits well above the floor of its room (a door
                -- starts at the floor). Decided by shape first, because a window's glass pane can be
                -- attached to its portal just as a door is.
                local room = I.rooms[from ~= 0 and from or to]
                local floor = room and room.box[3] or lowest
                if lowest - floor > 0.6 then
                    kind = 'window'
                elseif GetInteriorPortalEntityCount(id, p) > 0 then
                    kind = 'door'
                else
                    kind = 'doorway'
                end
            end
            local list = {}
            if kind == 'door' then
                for e = 0, GetInteriorPortalEntityCount(id, p) - 1 do
                    list[#list + 1] = { hash = GetInteriorPortalEntityArchetype(id, p, e), pos = { GetInteriorPortalEntityPosition(id, p, e) } }
                end
            end
            I.portals[#I.portals + 1] = { index = p, from = from, to = to, kind = kind,
                center = { sx / 4, sy / 4, sz / 4 }, doors = list }
        end
        return I
    end)
    if not ok then print(('[whip_voice] could not read interior %s: %s'):format(tostring(id), tostring(built))) end
    interiors[id] = ok and built or false
    return interiors[id] or nil
end

--- Is this doorway's door open? Asks the game's own door state (the open ratio of the nearest door of
--- that model), a few times a second at most. Unknown rotation or no answer = closed.
local function doorOpen(p)
    if not p.doors or #p.doors == 0 or not p.interior or not p.interior.conv then return false end
    local now = GetGameTimer()
    local c = doors[p]
    if c and now - c.at < DOOR_RECHECK_MS then return c.open end
    local open = false
    for _, d in ipairs(p.doors) do
        local w = Acoustics.toWorld(p.interior, d.pos, p.interior.conv)
        local ok, _, ratio = pcall(GetStateOfClosestDoorOfType, d.hash, w[1], w[2], w[3])
        if ok and type(ratio) == 'number' and math.abs(ratio) > 0.08 then open = true; break end
    end
    doors[p] = { open = open, at = now }
    return open
end

--- Windows up, roof on, doors shut: a closed cabin.
local OPEN_CLASSES = { [8] = true, [13] = true, [14] = true, [21] = true }   -- bikes, cycles, boats, trains
local function cabinClosed(veh)
    if veh == 0 or OPEN_CLASSES[GetVehicleClass(veh)] then return false end
    if not DoesVehicleHaveRoof(veh) then return false end
    if IsVehicleAConvertible(veh, false) and GetConvertibleRoofState(veh) ~= 0 then return false end
    for w = 0, 1 do                                   -- the front windows (down or broken = open)
        if not IsVehicleWindowIntact(veh, w) then return false end
    end
    for d = 0, 3 do
        if GetVehicleDoorAngleRatio(veh, d) > 0.1 then return false end
    end
    return true
end

--- Which building and room a ped is in, and the rest of what the rules need.
local function describe(ped, pos)
    local int, room = 0, 0
    if E.rooms ~= false and HAS_ROOMS then
        int = GetInteriorFromEntity(ped)
        if int ~= 0 then
            local key = GetRoomKeyFromEntity(ped)
            room = key ~= 0 and GetInteriorRoomIndexByHash(int, key) or -1
            -- Room 0 is the interior's own "outside"; -1 is not in a room at all.
            if room <= 0 then int, room = 0, 0 end
        end
    end
    local veh = GetVehiclePedIsIn(ped, false)
    return {
        int = int, room = room, pos = pos, veh = veh,
        cabin = E.cars ~= false and veh ~= 0 and cabinClosed(veh) or false,
        water = E.water ~= false and IsPedSwimmingUnderWater(ped) or false,
    }
end

--- Did a finished probe hit something? (FiveM hands `hit` back as 1/0 on some builds and true/false
--- on others: either counts.)
local function isHit(hit) return hit == 1 or hit == true end

--- One ray from `from` to `to`, ignoring this player's own ped. Answers: whether the game answered,
--- whether it hit, where, and what it hit.
---
--- ANSWERED IN THE SAME CALL, NOT LATER. These rays used to be started without waiting and read on a
--- later pass, 200-500 ms on — and by then the game had thrown every answer away (Josh saw it on
--- /voicedebug, 29 Sep 2026), so walls outdoors never muffled anyone. (Everywhere else whip reads a
--- ray's answer at once or on the very next frame.) A short ray answered at once is cheap: one per
--- talking voice, five times a second.
local startProbe = StartExpensiveSynchronousShapeTestLosProbe or StartShapeTestLosProbe
local function probe(from, to, flags)
    local h = startProbe(from[1], from[2], from[3], to[1], to[2], to[3], flags, PlayerPedId(), 7)
    if not h or h == 0 then return false, false, nil end
    local status, hit, pos, _, ent = GetShapeTestResult(h)
    if status ~= 2 then return false, false, nil end
    return true, isHit(hit), pos, ent
end

--- Is a ray clear? Answered, and nothing hit, or only the voice's own object.
---
--- THE VOICE'S OWN OBJECT IS NOT IN THE WAY. A speaker's sound comes from the middle of its prop, so the ray ends inside
--- it and always hits it first: every speaker heard outdoors was muffled as if behind a wall (Josh, 14 Nov 2026). Its
--- own object hit first means nothing stood between.
local function clearRay(answered, hit, ent, own)
    return answered and (not hit or (own ~= nil and own ~= 0 and ent == own))
end

local function far(a, b, metres)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return dx * dx + dy * dy + dz * dz > metres * metres
end

local function length(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- THE WAY ROUND. Outdoors, one ray between two heads used to decide it, and anything touching that line muffled the
-- voice as a building's wall does: a post, a low wall in an open car park, as if behind closed doors; and a speaker in
-- the next yard, heard through its gateway, went from muffled to clear and back as you crossed the gateway's line
-- (Josh, 14 Nov 2026). Sound goes round and over things, and how much it is muffled grows with how sharply it bends
-- round them, from nothing. So a blocked line follows the way round:
--   1. the way found before, while the listener still sees it (Ways.follow: its corner found again from where they
--      now stand, so walking about changes the sound a little at each step);
--   2. else close round what the line hit (a post, a crate, a low wall): beside it either side, or over it, near first;
--   3. else further round, the way the sound really goes through the open ground (client/ways.lua): round a building's
--      corner, out of a yard through its gateway. One search a pass, carried on over passes.
-- The muffle is by the way's bends (Acoustics.around), and its length is what the fade goes by; a long way round loses
-- to the sound through the wall (Acoustics.voice takes the louder). No way round at all: through the wall, as before.
local ROUND_STEPS = { 0.3, 1.0, 3.0 }   -- metres out from where the line hit, nearest first
local STILL = 0.15                      -- neither end moved more than this (metres): the last answer stands, no rays
local CLOSE_RAYS = 48                   -- rays a pass may spend following ways and looking close round things
local SEARCH_RAYS = 64                  -- rays a pass may spend on the one search further round
local SEARCH_SQUARES = 120              -- squares a pass's search may look at (client/ways.lua)
local SEARCH_FROM = 3.0                 -- a search going on is started again when the listener has moved this far
-- A KEPT WAY IS ONLY FOR NEAR WHERE IT WAS FOUND. Followed for as long as its corner could be seen, it was kept from
-- the far side of the voice: walk past a gap and back, and the sound still went out to the corner left behind and
-- back again (152 degrees, from the wrong side), flicking to clear and back each time the straight line grazed a post
-- (Josh, 14 Nov 2026). So it is forgotten once the voice is in sight, followed only within KEEP_MOVE of where it was
-- found, and never when it bends back on itself (SHARP): past those it is looked for again from where the listener is.
local KEEP_MOVE = 5.0                   -- metres from where a way was found that it is still followed
local SHARP = 120                       -- degrees of bend past which a followed way is looked for again
-- MUSIC IS HEARD BY TWO WAYS AT ONCE (Josh, 14 Nov 2026: one way can come from one direction only, so when the best way
-- moved to another gap the sound jumped from behind to in front). Round a real corner, music also takes the best way
-- through ANOTHER opening (a search that keeps clear of the first way's corner), and the page plays both from their
-- own corners, each as loud as its own length and bends make it (html/js/audio.js): walking on, one fades up as the
-- other fades down, as real sound does. A voice in a conversation keeps one way.
local APART = 4.0                       -- metres: the second way's corner at least this far from the first's
local SECOND_BEND = 30                  -- degrees: a first way bending less (round a post) has no second worth one
local rounds = {}                       -- [identity] = { way, wayTo, wayFrom, search, last, lastFrom, lastTo, settled }
local closeRays = { left = CLOSE_RAYS }

Ways.setProbe(probe)

--- A way close round from `from` to `to`, past `hitAt` (where the straight line hit): its anchor (a point beside or
--- over what is in the way that both see), false when there is none close by, nil when this pass has no rays left.
local function wayRound(from, to, hitAt, own)
    local dx, dy, dz = to[1] - from[1], to[2] - from[2], to[3] - from[3]
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d < 0.01 then return false end
    local ux, uy, uz = dx / d, dy / d, dz / d
    -- Sideways: level, square to the line (a line straight up or down: any level way).
    local flat = math.sqrt(ux * ux + uy * uy)
    local sx, sy = 1.0, 0.0
    if flat > 0.01 then sx, sy = -uy / flat, ux / flat end
    -- From just in front of what it hit, on this side.
    local bx, by, bz = hitAt.x - ux * 0.25, hitAt.y - uy * 0.25, hitAt.z - uz * 0.25
    local function point(side, step)
        if side == 1 then return { bx + sx * step, by + sy * step, bz } end
        if side == 2 then return { bx - sx * step, by - sy * step, bz } end
        return { bx, by, bz + step }
    end
    -- Does the sound get from `from` to `to` by w? nil: no rays left.
    local function via(w)
        if closeRays.left < 2 then return nil end
        closeRays.left = closeRays.left - 1
        local a1, h1, _, e1 = probe(from, w, 1 + 16)
        if not clearRay(a1, h1, e1, own) then return false end
        closeRays.left = closeRays.left - 1
        local a2, h2, _, e2 = probe(w, to, 1 + 16)
        return clearRay(a2, h2, e2, own) and true or false
    end
    for _, step in ipairs(ROUND_STEPS) do
        for side = 1, 3 do
            local w = point(side, step)
            local got = via(w)
            if got == nil then return nil end
            if got then return w end
        end
    end
    return false
end

--- Line of sight between two heads: the world and objects (1 + 16), not people or cars. false: clear. A table: the
--- line is blocked but there is a way round, { turns = degrees at each bend, d = metres it adds, len = metres it is,
--- at = the corner it is heard from } (Ways.follow). true: blocked, no way round. No answer from the game keeps the
--- last one.
--- `range`: the voice's, the longest way worth looking for; `pass`: this pass's { searched, search = rays }.
local function lineOf(id, from, to, own, range, pass)
    local answered, hit, pos, ent = probe(from, to, 1 + 16)
    if not answered then return probes[id] or false end
    if clearRay(answered, hit, ent, own) then
        probes[id] = false
        -- In sight: the way kept from before is done with. Out of sight again, it is looked for from there.
        local was = rounds[id]
        if was then was.way, was.settled, was.way2, was.settled2, was.none2, was.prev = nil, false, nil, false, nil, nil end
        return false
    end
    local r = rounds[id]
    if not r then
        r = {}
        rounds[id] = r
    end
    local function answer(a, settled)
        r.last, r.lastFrom, r.lastTo, r.settled = a, from, to, settled
        probes[id] = a
        return a
    end
    -- Nobody moved: as it was.
    if r.settled and r.last ~= nil and not far(r.lastFrom, from, STILL) and not far(r.lastTo, to, STILL) then
        probes[id] = r.last
        return r.last
    end
    -- 1. The way found before: while the voice is where it was, the listener near where it was found and still seeing
    -- it, and it does not bend back on itself (else it is looked for again below; one that does stands only while
    -- nothing better is found).
    local sharp = nil
    if r.way and not far(r.wayTo, to, STILL) and not far(r.wayFrom, from, KEEP_MOVE) then
        local f = Ways.follow(r.way, from, to, own, closeRays)
        if f == nil then return answer(r.last or true, false) end   -- (no rays left this pass)
        if f then
            local bend = 0
            for _, t in ipairs(f.turns) do bend = bend + t end
            if bend <= SHARP then return answer(f, true) end
            sharp = f
        end
    end
    -- (The way given up: music may still hear by it, through the opening it leaves: secondWay.)
    if r.way then r.prev = { way = r.way, to = r.wayTo } end
    r.way = nil
    -- 2. Close round what the line hit.
    local w = nil
    if pos then w = wayRound(from, to, pos, own) end
    if w == nil and pos then return answer(sharp or r.last or true, false) end   -- (no rays left this pass)
    if w then
        r.way, r.wayTo, r.wayFrom = { anchor = w, toward = to }, to, from
        local f = Ways.follow(r.way, from, to, own, closeRays)
        if f then return answer(f, true) end
        r.way = nil
    end
    -- 3. Further round: the search, carried on a pass at a time (one voice's a pass).
    if r.search and (far(r.search.from, from, SEARCH_FROM) or far(r.search.to, to, STILL)) then r.search = nil end
    if not pass.searched then
        pass.searched = true
        r.search = r.search or Ways.start(from, to, own, range)
        local found = Ways.step(r.search, pass.search, SEARCH_SQUARES)
        if found ~= nil then
            r.search = nil
            if not found then return answer(true, true) end          -- no way round within reach: the wall
            r.way, r.wayTo, r.wayFrom = found, to, from
            local f = Ways.follow(found, from, to, own, pass.search)
            if f then return answer(f, true) end
            if f == false then r.way = nil end
        end
    end
    return answer(sharp or r.last or true, false)
end

local function bendOf(f)
    local b = 0
    for _, t in ipairs(f.turns or {}) do b = b + t end
    return b
end

local function flatFar(a, b, metres)
    local dx, dy = a[1] - b[1], a[2] - b[2]
    return dx * dx + dy * dy > metres * metres
end

--- A music voice's SECOND way round (above: MUSIC IS HEARD BY TWO WAYS AT ONCE), given its first (lineOf's answer):
--- the best way through another opening, kept and followed by the first's rules, or nil when there is none worth one
--- (the first bends round no real corner, its corner is right by either end, no other way within reach).
local function secondWay(id, from, to, own, range, pass, first)
    local r = rounds[id]
    if not r then return nil end
    local c1 = first.at
    if not c1 or bendOf(first) < SECOND_BEND then
        r.way2, r.none2, r.last2, r.settled2 = nil, nil, nil, false
        return nil
    end
    -- Nobody moved: as it was.
    if r.settled2 and not far(r.last2From, from, STILL) and not far(r.last2To, to, STILL) then return r.last2 end
    local function answer2(f, settled)
        r.last2, r.last2From, r.last2To, r.settled2 = f, from, to, settled
        return f
    end
    -- The second way found before: by the first's rules, and still through another opening than the first's corner.
    if r.way2 and not far(r.way2To, to, STILL) and not far(r.way2From, from, KEEP_MOVE) then
        local f = Ways.follow(r.way2, from, to, own, closeRays)
        if f == nil then return answer2(r.last2, false) end            -- (no rays left this pass)
        if f and f.at and flatFar(f.at, c1, APART) then return answer2(f, true) end
    end
    r.way2 = nil
    -- THE FIRST WAY JUST MOVED TO ANOTHER OPENING: the way it gave up, through the opening it left, is the second at once,
    -- so the sound fades from one to the other rather than jumping while a search runs.
    local p = r.prev
    r.prev = nil
    if p and not far(p.to, to, STILL) then
        local f = Ways.follow(p.way, from, to, own, closeRays)
        if f and f.at and flatFar(f.at, c1, APART) then
            r.way2, r.way2To, r.way2From = p.way, to, from
            return answer2(f, true)
        end
    end
    -- None lately from about here, round this same first corner: none, without looking again.
    local n = r.none2
    if n and not far(n.from, from, KEEP_MOVE) and not far(n.to, to, STILL) and not flatFar(n.c1, c1, APART) then
        return answer2(nil, true)
    end
    -- The first corner right by the voice: no other opening is worth one. (Right by the listener, the search leaves
    -- its corner by another way: ways.lua avoided.)
    if not flatFar(c1, to, APART) then return answer2(nil, true) end
    -- The search, through anywhere but the first's corner: the pass's one search, when no other voice had it.
    local s = r.search2
    if s and (far(s.from, from, SEARCH_FROM) or far(s.to, to, STILL) or flatFar(s.avoid[1], c1, APART)) then s = nil end
    r.search2 = s
    if pass.searched then return answer2(r.last2, false) end
    pass.searched = true
    s = s or Ways.start(from, to, own, range, { { c1[1], c1[2], APART } })
    r.search2 = s
    local found = Ways.step(s, pass.search, SEARCH_SQUARES)
    if found == nil then return answer2(r.last2, false) end            -- (goes on next pass)
    r.search2 = nil
    if not found then
        r.none2 = { from = from, to = to, c1 = c1 }
        return answer2(nil, true)
    end
    r.way2, r.way2To, r.way2From = found, to, from
    local f = Ways.follow(found, from, to, own, pass.search)
    if f and f.at and flatFar(f.at, c1, APART) then return answer2(f, true) end
    r.way2 = nil
    return answer2(nil, true)
end

local function learn(d)
    if d.int == 0 then return end
    local I = readInterior(d.int)
    if I and I.conv == nil then
        I.conv = Acoustics.calibrate(I, d.room, d.pos)
        if I.conv then for _, p in ipairs(I.portals) do p.interior = I end end
    end
end

--- Everything for one pass.
---@param me table          { ped, head = {x,y,z} }
---@param speakers table    [identity] = { ped, head = {x,y,z}, range = metres, loud = through a megaphone,
---                         mu = music (a second way round: secondWay) } — the
---                         voices to work out now
---@param heard table|nil   [identity] = anything, for every voice still heard (what is kept for the
---                         others: their line-of-sight check, the opening they came through). Default:
---                         the speakers.
function Environment.update(me, speakers, heard)
    heard = heard or speakers
    local L = describe(me.ped, me.head)
    learn(L)
    here = L.int
    local out = { rv = nil, v = {} }
    if E.echo ~= false and not L.water then out.rv = Acoustics.reverbFor(interiors[L.int] or nil, L.room) end
    local pass = {}   -- shared by every voice below: the way-finding search is done once (acoustics.lua)
    -- This pass's rays for the ways round outdoors: close round things, and the one search further round.
    closeRays.left = CLOSE_RAYS
    local outside = { searched = false, search = { left = SEARCH_RAYS } }
    local indoors = { searched = true }   -- (a building with no room map: close round things only)

    for id, s in pairs(speakers) do
        local S = describe(s.ped, s.head)
        S.loud = s.loud == true
        learn(S)
        -- A LINE-OF-SIGHT CHECK ONLY WHERE THE ROOM MAP CANNOT ANSWER: both outdoors, or a building
        -- involved that has no room map. Where every building involved has one, the doorways decide.
        local mapped = (L.int ~= 0 or S.int ~= 0)
            and (L.int == 0 or interiors[L.int]) and (S.int == 0 or interiors[S.int])
        local isBlocked = false
        if E.walls ~= false and not mapped then
            local open = L.int == 0 and S.int == 0
            isBlocked = lineOf(id, me.head, s.head, s.ped, s.range, open and outside or indoors)
            -- Music round a corner outdoors: its second way too, heard at the same time.
            if s.mu and open and type(isBlocked) == 'table' then
                isBlocked.second = secondWay(id, me.head, s.head, s.ped, s.range, outside, isBlocked)
            end
        end
        local ints = {}
        if L.int ~= 0 then ints[L.int] = interiors[L.int] or nil end
        if S.int ~= 0 then ints[S.int] = interiors[S.int] or nil end
        local a = Acoustics.voice(L, S, ints, doorOpen, isBlocked, Acoustics.slope(s.range, Config.FullVolumeWithin), via[id], pass)
        out.v[id], via[id] = a, a.via
    end
    for id in pairs(probes) do if not heard[id] then probes[id] = nil end end
    for id in pairs(rounds) do if not heard[id] then rounds[id] = nil end end
    for id in pairs(via) do if not heard[id] then via[id] = nil end end
    return out
end

--- For /voicedebug: what is known about an interior.
function Environment.interior(id) return interiors[id] or nil end

--- For /voicedebug with nobody to hear: read the building this player stands in (and work out which
--- way it faces) without touching anything the voice passes use.
function Environment.locate(me)
    local L = describe(me.ped, me.head)
    learn(L)
    here = L.int
end

--- For /voicedebug: every opening of the building this player stood in at the last pass, in the world:
--- { { kind, at = {x,y,z}, open }, ... }, or nil (outside, not read, or its rotation not worked out yet).
function Environment.openingsHere()
    local I = here and here ~= 0 and interiors[here] or nil
    if not I or not I.conv then return nil end
    local out = {}
    for _, p in ipairs(I.portals) do
        -- Written out, not `kind == 'door' and doorOpen(p) or nil`: a CLOSED door answers false,
        -- and `false or nil` is nil — the view would never say "closed".
        local open = nil
        if p.kind == 'door' then open = doorOpen(p) == true end
        out[#out + 1] = { kind = p.kind, at = Acoustics.toWorld(I, p.center, I.conv), open = open, to = p.to, from = p.from }
    end
    return out
end
