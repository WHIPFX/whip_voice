-- Voice lines for other resources (the exports). Any resource can use whip_voice without any of its code: whip_phone's
-- calls are lines it opens; an intercom, a dispatch line, a bugged room are lines too. The resource owns its lines and
-- whip_voice closes them when it stops. A line's sound is a recipe sent as data (blocks from shared/sound_blocks.lua),
-- checked here and built in each listener's game (html/js/fx.js). Server side only: only a server decides who is on a line.
--
--   local lineId = exports.whip_voice:OpenLine({
--       members  = { callerSrc, calleeSrc },
--       track    = 'voice',              -- 'voice' (the talk key) or 'radio' (the radio key)
--       recipe   = Config.CallSound,     -- a list of blocks, or the name of a sound (RegisterSound)
--       speakerRange = 8,                -- 1-30 m: how far a member's device on speaker carries
--       pickup   = true,                 -- on speaker, the people near the device are heard too
--       quality  = nil,                  -- { clear = 500, range = 1500 }: worse with distance, gone past range
--       sameWorld = false,               -- only members in the same routing bucket hear each other
--       minMembers = 2,                  -- fewer members than this and the line closes by itself
--       onEnd    = function(lineId, why) end,         -- closed by whip_voice ('empty')
--       onLeave  = function(lineId, src, why) end,    -- a member gone ('left', 'logout', 'removed')
--   })
--   CloseLine(lineId)   AddLineMember(lineId, src)   RemoveLineMember(lineId, src)
--   SetLineSpeaker(lineId, src, on)   SetLineMuted(lineId, src, on)   SetLineRecipe(lineId, recipe)
--   GetLine(lineId)   RegisterSound(name, recipe)   IsVoiceReady(src)
--
-- Every export answers its value (or true), or false and why. A line's id is the owner's handle; games are only told a
-- random token. A member is a player with a character loaded; not being in voice yet is fine, they are linked once they are.
--
-- A member's device on speaker plays the line to everyone within its speakerRange (connected 3 m further, held 1 s
-- past it); with pickup, the far side hears everyone within their own voice range of it.

local RESOURCE = GetCurrentResourceName()
local MAX_MEMBERS = 32       -- on one line
local MAX_LINES = 500        -- open at once, per resource
local sounds = {}            -- ['<owner>:<name>'] = a checked recipe

local function isFuncRef(v) return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil end
local function callable(v) return type(v) == 'function' or isFuncRef(v) end

--- A recipe as whip_voice keeps it: { { type = 'band', low = 300, high = 3400 }, ... }, every setting
--- present and in range — or nil and why. Walked with rawget only (a function reference throws when
--- indexed). Lua's { 'band', low = 300 } is read as well as { type = 'band', ... }.
function Lines.checkRecipe(recipe)
    if type(recipe) ~= 'table' or isFuncRef(recipe) then return nil, 'a recipe is a list of blocks' end
    local n = #recipe
    if n > SoundLimits.blocks then return nil, ('at most %d blocks'):format(SoundLimits.blocks) end
    local out, sources = {}, 0
    for i = 1, n do
        local b = rawget(recipe, i)
        if type(b) ~= 'table' or isFuncRef(b) then return nil, ('block %d is not a table'):format(i) end
        local name = rawget(b, 'type')
        if name == nil then name = rawget(b, 1) end
        local spec = type(name) == 'string' and rawget(SoundBlocks, name) or nil
        if not spec then return nil, ('block %d: there is no block called %s'):format(i, tostring(name)) end
        if SoundLimits.sourceBlocks[name] then
            sources = sources + 1
            if sources > SoundLimits.sources then
                local names = {}
                for blockName in pairs(SoundLimits.sourceBlocks) do names[#names + 1] = blockName end
                table.sort(names)
                return nil, ('at most %d blocks that make sound of their own (%s)'):format(SoundLimits.sources, table.concat(names, ', '))
            end
        end
        local block = { type = name }
        for key, s in pairs(spec) do
            local v = rawget(b, key)
            if type(s[1]) == 'number' then
                if v == nil then
                    block[key] = s[3]
                else
                    local num = tonumber(v)
                    if not num or num ~= num then return nil, ('block %d (%s): %s is a number'):format(i, name, key) end
                    block[key] = math.max(s[1], math.min(s[2], num))
                end
            else
                if v == nil then
                    block[key] = s[1]
                else
                    local known = false
                    for _, w in ipairs(s) do if w == v then known = true break end end
                    if not known then return nil, ('block %d (%s): %s is one of %s'):format(i, name, key, table.concat(s, ', ')) end
                    block[key] = v
                end
            end
        end
        out[#out + 1] = block
    end
    return out
end

--- A recipe, or a sound's name: the owner's own ('ring' = '<owner>:ring'), or another's in full.
local function recipeOf(owner, r)
    if type(r) == 'string' then
        local s = sounds[r] or sounds[owner .. ':' .. r]
        if not s then return nil, 'there is no sound called ' .. r end
        return s
    end
    if r == nil then return {} end
    return Lines.checkRecipe(r)
end

--- A player whip_core has a character loaded for (its own record, not whip_voice's: whip_voice may have
--- just started and not know yet).
local function loaded(src)
    src = tonumber(src)
    if not src or GetPlayerName(src) == nil then return false end
    local ok, p = pcall(function() return exports.whip_core:GetPlayer(src) end)
    return ok and p ~= nil
end

--- The owner's line, or false and why.
local function mine(owner, lineId)
    local line = type(lineId) == 'string' and Lines.byId[lineId] or nil
    if not line then return false, 'no such line (closed?)' end
    if line.owner ~= owner then return false, 'that line is not yours' end
    return line
end

--- A callback from another resource, run only while that resource still runs.
local function ownerCallback(owner, fn)
    if fn == nil then return nil end
    return function(...)
        if GetResourceState(owner) ~= 'started' then return end
        fn(...)
    end
end

local function owned(owner)
    local n = 0
    for _, line in pairs(Lines.byId) do if line.owner == owner then n = n + 1 end end
    return n
end

-- ---- The exports (each reads its caller first, before anything else) -----------------------------

exports('OpenLine', function(spec)
    local owner = GetInvokingResource()
    if not owner or owner == RESOURCE then return false, 'call it from another resource' end
    if type(spec) ~= 'table' or isFuncRef(spec) then return false, 'a line is a table: { members, recipe, ... }' end
    local track = rawget(spec, 'track')
    if track ~= nil and track ~= 'voice' and track ~= 'radio' then return false, "track is 'voice' or 'radio'" end
    local recipe, why = recipeOf(owner, rawget(spec, 'recipe'))
    if not recipe then return false, 'recipe: ' .. why end
    local onEnd, onLeave = rawget(spec, 'onEnd'), rawget(spec, 'onLeave')
    if onEnd ~= nil and not callable(onEnd) then return false, 'onEnd is a function' end
    if onLeave ~= nil and not callable(onLeave) then return false, 'onLeave is a function' end
    local list = rawget(spec, 'members')
    if list ~= nil and (type(list) ~= 'table' or isFuncRef(list)) then return false, 'members is a list of server ids' end
    local members = {}
    for i = 1, list and #list or 0 do
        local src = tonumber(rawget(list, i))
        if not loaded(src) then return false, ('member %s is not a player with a character loaded'):format(tostring(rawget(list, i))) end
        members[#members + 1] = src
    end
    if #members > MAX_MEMBERS then return false, ('at most %d members'):format(MAX_MEMBERS) end
    if owned(owner) >= MAX_LINES then return false, ('at most %d lines open at once'):format(MAX_LINES) end
    local Q = rawget(spec, 'quality')
    if Q ~= nil and (type(Q) ~= 'table' or isFuncRef(Q) or not tonumber(rawget(Q, 'clear')) or not tonumber(rawget(Q, 'range'))) then
        return false, 'quality is { clear = metres, range = metres }'
    end
    return Lines.open(owner, {
        members = members, track = track or 'voice', recipe = recipe,
        quality = Q and { clear = tonumber(rawget(Q, 'clear')), range = tonumber(rawget(Q, 'range')) } or nil,
        sameWorld = rawget(spec, 'sameWorld') == true, pickup = rawget(spec, 'pickup') == true,
        speakerRange = tonumber(rawget(spec, 'speakerRange')) or 8,
        minMembers = tonumber(rawget(spec, 'minMembers')) or 2,
        -- (Another resource's speaker reaches 3 m past its range and is held 1 s: never the radio's 15 m.)
        margin = 3, hold = 1000,
        onEnd = ownerCallback(owner, onEnd), onLeave = ownerCallback(owner, onLeave),
    })
end)

exports('CloseLine', function(lineId)
    local owner = GetInvokingResource()
    if not owner then return false, 'call it from another resource' end
    if type(lineId) == 'string' and not Lines.byId[lineId] then return true end   -- closed already: nothing to do
    local line, why = mine(owner, lineId)
    if not line then return false, why end
    return Lines.close(lineId, 'closed', true)
end)

exports('AddLineMember', function(lineId, src)
    local owner = GetInvokingResource()
    if not owner then return false, 'call it from another resource' end
    local line, why = mine(owner, lineId)
    if not line then return false, why end
    src = tonumber(src)
    if not loaded(src) then return false, 'not a player with a character loaded' end
    if not line.members[src] then
        local n = 0
        for _ in pairs(line.members) do n = n + 1 end
        if n >= MAX_MEMBERS then return false, ('at most %d members'):format(MAX_MEMBERS) end
    end
    return Lines.join(lineId, src)
end)

exports('RemoveLineMember', function(lineId, src)
    local owner = GetInvokingResource()
    if not owner then return false, 'call it from another resource' end
    local line, why = mine(owner, lineId)
    if not line then return false, why end
    src = tonumber(src)
    if not (src and line.members[src]) then return true end   -- not on it: nothing to do
    return Lines.leave(lineId, src, 'removed')
end)

exports('SetLineSpeaker', function(lineId, src, on)
    local owner = GetInvokingResource()
    if not owner then return false, 'call it from another resource' end
    local line, why = mine(owner, lineId)
    if not line then return false, why end
    return Lines.setSpeaker(lineId, tonumber(src), on == true)
end)

exports('SetLineMuted', function(lineId, src, on)
    local owner = GetInvokingResource()
    if not owner then return false, 'call it from another resource' end
    local line, why = mine(owner, lineId)
    if not line then return false, why end
    return Lines.setMuted(lineId, tonumber(src), on == true)
end)

exports('SetLineRecipe', function(lineId, recipe)
    local owner = GetInvokingResource()
    if not owner then return false, 'call it from another resource' end
    local line, why = mine(owner, lineId)
    if not line then return false, why end
    local r, rwhy = recipeOf(owner, recipe)
    if not r then return false, 'recipe: ' .. rwhy end
    return Lines.setRecipe(lineId, r)
end)

exports('GetLine', function(lineId)
    local owner = GetInvokingResource()
    if not owner then return false, 'call it from another resource' end
    local line, why = mine(owner, lineId)
    if not line then return false, why end
    local members = {}
    for src, m in pairs(line.members) do members[src] = { speaker = m.speaker, muted = m.muted } end
    return { id = line.id, track = line.track, members = members, pickup = line.pickup, sameWorld = line.sameWorld,
             speakerRange = line.speakerRange, minMembers = line.minMembers }
end)

exports('RegisterSound', function(name, recipe)
    local owner = GetInvokingResource()
    if not owner then return false, 'call it from another resource' end
    if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or #name > 32 then return false, 'a sound\'s name is letters, digits, - and _' end
    local r, why = Lines.checkRecipe(recipe)
    if not r then return false, 'recipe: ' .. why end
    sounds[owner .. ':' .. name] = r
    return owner .. ':' .. name
end)

exports('IsVoiceReady', function(src)
    local p = Voice.players[tonumber(src) or -1]
    if not p or not p.joined then return false, 'not connected to voice' end
    if not p.speaking then return false, 'no microphone' end
    return true
end)

-- A resource stopping: its lines close (no callbacks: its functions are gone), its sounds go.
AddEventHandler('onResourceStop', function(res)
    if res == RESOURCE then return end
    for _, id in ipairs(Lines.ownedBy(res)) do Lines.close(id, 'ownerStopped', true) end
    for key in pairs(sounds) do
        if key:sub(1, #res + 1) == res .. ':' then sounds[key] = nil end
    end
end)
