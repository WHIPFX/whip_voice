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
--- whether it hit, and where.
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
    local status, hit, pos = GetShapeTestResult(h)
    if status ~= 2 then return false, false, nil end
    return true, isHit(hit), pos
end

--- Line of sight between two heads: the world and objects (1 + 16), not people or cars. No answer
--- from the game keeps the last one.
local function blocked(id, from, to)
    local answered, hit = probe(from, to, 1 + 16)
    if answered then probes[id] = hit end
    return probes[id] == true
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
---@param speakers table    [identity] = { ped, head = {x,y,z}, range = metres } — the voices to work out now
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

    for id, s in pairs(speakers) do
        local S = describe(s.ped, s.head)
        learn(S)
        -- A LINE-OF-SIGHT CHECK ONLY WHERE THE ROOM MAP CANNOT ANSWER: both outdoors, or a building
        -- involved that has no room map. Where every building involved has one, the doorways decide.
        local mapped = (L.int ~= 0 or S.int ~= 0)
            and (L.int == 0 or interiors[L.int]) and (S.int == 0 or interiors[S.int])
        local isBlocked = false
        if E.walls ~= false and not mapped then isBlocked = blocked(id, me.head, s.head) end
        local ints = {}
        if L.int ~= 0 then ints[L.int] = interiors[L.int] or nil end
        if S.int ~= 0 then ints[S.int] = interiors[S.int] or nil end
        local a = Acoustics.voice(L, S, ints, doorOpen, isBlocked, Acoustics.slope(s.range, Config.FullVolumeWithin), via[id], pass)
        out.v[id], via[id] = a, a.via
    end
    for id in pairs(probes) do if not heard[id] then probes[id] = nil end end
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
