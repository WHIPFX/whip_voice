-- Voice lines: a line is a set of players who hear each other wherever they are, through a sound recipe (data:
-- shared/sound_blocks.lua). The resource that opens one owns it. whip_phone's calls are lines it opens; each radio
-- frequency is a line whip_voice opens for itself ('radio:<freq>').
--
--   track      'voice' (what they say with the talk key: a call) or 'radio' (the radio key)
--   recipe     how it sounds at the far end (html/js/fx.js builds it)
--   quality    { clear, range }: heard worse with distance, nothing past range (the radio's); none: q 1
--   sameWorld  only members in the same routing bucket hear each other (the radio); a call: anywhere
--   members    [src] = { speaker, muted }: on speaker, the people near their device hear the line too;
--              muted, the line does not hear them (the people near still do)
--
-- Membership is not presence: a member stays a member by server id until they leave, log out or disconnect, and links
-- nobody while not in voice. `minMembers` counts members, never presence. A member may be a voice bot ('bot:<n>',
-- server/bots.lua): it only talks, and leaves when it has finished.
--
-- Privacy: the server alone decides who is on a line; each talker's game allows exactly those listeners. Leaving,
-- muting and a speaker turned off take effect at once (Hearing.now).

Lines = {
    byId = {},       -- [lineId] = line
    byKey = {},      -- [key] = lineId: whip_voice's own shared lines ('radio:123')
    ofPlayer = {},   -- [src] = { [lineId] = true }
}

local RESOURCE = GetCurrentResourceName()
local startTag = nil   -- per start of whip_voice: a line id from before a restart never matches a new one
local count = 0

local function newId()
    if not startTag then startTag = (Voice and Voice.randomId and Voice.randomId() or tostring(os.time())):sub(1, 8) end
    count = count + 1
    return startTag .. '-' .. count
end

local function clamp(n, lo, hi, def)
    n = tonumber(n)
    if not n or n ~= n then return def end
    return math.max(lo, math.min(hi, n))
end

--- A callback, later, in a thread of its own; a throw is printed, never passed on.
local function later(fn, ...)
    if fn == nil then return end
    local args = table.pack(...)
    CreateThread(function()
        local ok, err = pcall(fn, table.unpack(args, 1, args.n))
        if not ok then print(('^1[whip_voice] a line\'s callback failed: %s^0'):format(tostring(err))) end
    end)
end

local function memberCount(line)
    local n = 0
    for _ in pairs(line.members) do n = n + 1 end
    return n
end

--- Open a line. Answers its id, or false and why. (The exports, step 4, check what another resource
--- sends before it gets here.)
---@param owner string   the resource it belongs to
---@param spec table     { members?, track, recipe, quality?, sameWorld?, speakerRange?, margin?, hold?,
---                        pickup?, minMembers?, rx?, own?, key?, onEnd?, onLeave? }
function Lines.open(owner, spec)
    if type(spec) ~= 'table' then return false, 'a line is a table' end
    local id = newId()
    local Q = type(spec.quality) == 'table' and spec.quality or nil
    local line = {
        id = id, owner = owner, key = spec.key, order = count,
        token = (Voice and Voice.randomId and Voice.randomId()) or id,   -- what players' games call it
        track = spec.track == 'radio' and 'radio' or 'voice',
        recipe = type(spec.recipe) == 'table' and spec.recipe or {},
        own = spec.own == true,                -- whip_voice's own recipe (the radio): built as written
        rx = spec.rx == true,                  -- a radio frequency: the 3D radio's RX lamp, the radio's volume
        quality = Q and { clear = clamp(Q.clear, 0, 100000, 500), range = clamp(Q.range, 1, 100000, 1500) } or nil,
        sameWorld = spec.sameWorld == true,
        speakerRange = clamp(spec.speakerRange, 1, 30, 8),
        margin = clamp(spec.margin, 0, 15, 3),         -- connected this far ahead of speakerRange
        hold = clamp(spec.hold, 0, 3000, 1000),        -- and held this long past it
        pickup = spec.pickup == true,
        minMembers = math.floor(clamp(spec.minMembers, 1, 64, 2)),
        members = {},
        onEnd = spec.onEnd, onLeave = spec.onLeave,
    }
    local q = line.quality
    if q and q.range <= q.clear then q.range = q.clear + 1 end
    Lines.byId[id] = line
    if line.key then Lines.byKey[line.key] = id end
    for _, src in ipairs(type(spec.members) == 'table' and spec.members or {}) do Lines.join(id, src) end
    if Hearing then Hearing.wake() end
    return id
end

--- whip_voice's own shared line for `key` (a radio frequency): the one already open, or a new one.
function Lines.shared(key, makeSpec)
    local id = Lines.byKey[key]
    if id and Lines.byId[id] then return id end
    local spec = makeSpec()
    spec.key, spec.own = key, true
    return Lines.open(RESOURCE, spec)
end

--- Close a line: everyone on it lets go at once. `why` reaches its onEnd (not when its owner stopped:
--- `quiet`).
function Lines.close(id, why, quiet)
    local line = Lines.byId[id]
    if not line then return false, 'no such line' end
    Lines.byId[id] = nil
    if line.key and Lines.byKey[line.key] == id then Lines.byKey[line.key] = nil end
    local bots = {}
    for src in pairs(line.members) do
        local mine = Lines.ofPlayer[src]
        if mine then mine[id] = nil; if not next(mine) then Lines.ofPlayer[src] = nil end end
        if VoiceBots and VoiceBots.byKey[src] then bots[#bots + 1] = src end
    end
    line.members = {}
    -- A voice bot on it (server/bots.lua) goes with it.
    for _, key in ipairs(bots) do VoiceBots.remove(key, 'lineClosed') end
    if Hearing then Hearing.now() end
    if not quiet then later(line.onEnd, id, why or 'closed') end
    return true
end

--- Put a player on a line.
function Lines.join(id, src)
    local line = Lines.byId[id]
    if not line then return false, 'no such line' end
    src = tonumber(src)
    if not src then return false, 'not a player' end
    if not line.members[src] then
        line.members[src] = { speaker = false, muted = false }
        Lines.ofPlayer[src] = Lines.ofPlayer[src] or {}
        Lines.ofPlayer[src][id] = true
    end
    if Hearing then Hearing.wake() end
    return true
end

--- Take a player off a line (at once). Fewer than its minMembers left: the line closes.
function Lines.leave(id, src, why)
    local line = Lines.byId[id]
    if not line or not line.members[src] then return false, 'not on that line' end
    line.members[src] = nil
    local mine = Lines.ofPlayer[src]
    if mine then mine[id] = nil; if not next(mine) then Lines.ofPlayer[src] = nil end end
    later(line.onLeave, id, src, why or 'removed')
    if memberCount(line) < line.minMembers then
        Lines.close(id, 'empty')
    elseif Hearing then
        Hearing.now()
    end
    return true
end

--- A member's device on speaker, or not. Off takes effect at once.
function Lines.setSpeaker(id, src, on)
    local line = Lines.byId[id]
    local m = line and line.members[src]
    if not m then return false, 'not on that line' end
    on = on == true
    if m.speaker == on then return true end
    m.speaker = on
    if Hearing then if on then Hearing.wake() else Hearing.now() end end
    return true
end

--- A member muted on a line (the line does not hear them; the people near still do), or not. On takes
--- effect at once.
function Lines.setMuted(id, src, on)
    local line = Lines.byId[id]
    local m = line and line.members[src]
    if not m then return false, 'not on that line' end
    on = on == true
    if m.muted == on then return true end
    m.muted = on
    if Hearing then if on then Hearing.now() else Hearing.wake() end end
    return true
end

--- A line's sound changed (a checked recipe): everyone hearing it is told of the line again, and their
--- page builds its voices again in place.
function Lines.setRecipe(id, recipe)
    local line = Lines.byId[id]
    if not line then return false, 'no such line' end
    line.recipe = type(recipe) == 'table' and recipe or {}
    if Hearing then Hearing.reopen(id) end
    return true
end

--- Off every line (they left, logged out, or whip_core was lost).
function Lines.leaveAll(src, why)
    local mine = Lines.ofPlayer[src]
    if not mine then return end
    local ids = {}
    for id in pairs(mine) do ids[#ids + 1] = id end   -- (leaving changes the table being walked)
    for _, id in ipairs(ids) do Lines.leave(id, src, why) end
end

--- The lines a resource owns (for its stop: step 4), and everything, for /voicestatus.
function Lines.ownedBy(owner)
    local ids = {}
    for id, line in pairs(Lines.byId) do if line.owner == owner then ids[#ids + 1] = id end end
    return ids
end

-- ---- Leaving, as players do --------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    Lines.leaveAll(source, 'left')
end)

-- Logging out takes a player off every line: a line ignores routing buckets (the character screen's
-- own bucket would not silence it), and the next character must not inherit the last one's call.
AddEventHandler('whip_core:player:logout', function(e)
    if type(e) == 'table' and e.source then Lines.leaveAll(e.source, 'logout') end
end)
