-- ============================================
-- whip_voice — the speaker (an item), in the player's game
-- ============================================
--
-- Using the item runs whip's placer (PlaceObject: where you look, the wheel turns it, the arrows raise it, on a car
-- too) and sends where it went (server/speakers.lua puts it down). Behind every speaker, a prompt: the song (a link,
-- typed in a dialog), Play / Stop, Volume and Range (typed into the prompt), Pick up.
--
-- ONE PROMPT PER SPEAKER, ON ITS BACK, a sign that faces out of its back (not one that turns to the player). A speaker
-- on a car: the prompt rides THE CAR by its network id (whip's riding prompts follow it as it moves, streams out and
-- back), at the speaker's spot on the car plus its back, turning with the car. One on the ground: a fixed sign behind
-- it. Nothing is looked for in the world: where each speaker is comes from the server, so the prompt is where it is
-- whether or not this game has made its prop yet. (Not whip's model prompts: those are for props fixed in the map, and
-- stay where they first found a prop.)
--
-- Its back is its model's -y face (+y is a prop's front in GTA, as whip's prop prompts read it), and the placer
-- starts it facing the way the player faces, so its back is towards them as they put it down.

local S = Config.Speaker or {}
local MODEL = S.model or 'ba_prop_battle_club_speaker_small'
local GROUP = 'whip_voice_speakers'
local list = {}          -- [id] = what the server says of it (server/speakers.lua views)
local mounted = {}       -- [id] = where its prompt was put (a key), while it is up

-- ---- Putting one down ----------------------------------------------------------------------------

RegisterNetEvent('whip_voice:client:placeSpeaker', function(model)
    CreateThread(function()
        local spot, why = Whip.core:PlaceObject(model, { label = 'Speaker', vehicles = true })
        if not spot then
            if why ~= 'cancelled' then print('[whip_voice] the speaker was not put down: ' .. tostring(why)) end
            return
        end
        local o, r = spot.offset or vector3(0.0, 0.0, 0.0), spot.offsetRot or vector3(0.0, 0.0, 0.0)
        TriggerServerEvent('whip_voice:server:placeSpeaker', spot.coords.x, spot.coords.y, spot.coords.z,
            spot.rot.x, spot.rot.y, spot.rot.z, spot.netId or 0, o.x, o.y, o.z, r.x, r.y, r.z)
    end)
end)

-- ---- Where its prompt goes -----------------------------------------------------------------------

--- Its back, in its own frame: the middle of its -y face, a little out, halfway up (from the model's box).
local back = nil
local function backOf()
    if back then return back end
    local lo, hi = vector3(-0.3, -0.3, 0.0), vector3(0.3, 0.3, 0.8)
    local hash = GetHashKey(MODEL)
    if IsModelInCdimage(hash) then
        local a, b = GetModelDimensions(hash)
        if a and b then lo, hi = a, b end
    end
    back = vector3((lo.x + hi.x) / 2, lo.y - 0.1, (lo.z + hi.z) / 2)
    return back
end

--- (x, y) turned by a heading, as the game turns an entity's own frame.
local function turned(x, y, deg)
    local r = math.rad(deg)
    return x * math.cos(r) - y * math.sin(r), x * math.sin(r) + y * math.cos(r)
end

--- Its prompt's `at`: on a car, riding the car by its network id at the speaker's spot on it plus its back, a sign
--- facing out of its back as the car turns; on the ground, a fixed sign behind it.
local function anchorOf(v)
    local b = backOf()
    if v.net then
        local yaw = tonumber(v.carRot and v.carRot[3]) or 0.0
        local bx, by = turned(b.x, b.y, yaw)
        return { netId = v.net, offset = vector3(v.offset[1] + bx, v.offset[2] + by, v.offset[3] + b.z),
                 heading = (yaw + 180.0) % 360.0 }
    end
    local h = tonumber(v.rot and v.rot[3]) or 0.0
    local bx, by = turned(b.x, b.y, h)
    return { coords = vector3(v.coords[1] + bx, v.coords[2] + by, v.coords[3] + b.z), heading = (h + 180.0) % 360.0 }
end

--- What decides where its prompt is: put up again only when this changes (the rest is read live from `list`).
local function whereKey(v)
    if v.net then
        return ('car %d %.2f %.2f %.2f %.1f'):format(v.net, v.offset[1], v.offset[2], v.offset[3],
            tonumber(v.carRot and v.carRot[3]) or 0.0)
    end
    return ('at %.2f %.2f %.2f %.1f'):format(v.coords[1], v.coords[2], v.coords[3], tonumber(v.rot and v.rot[3]) or 0.0)
end

-- ---- The prompt behind it ------------------------------------------------------------------------

local function send(id, what, value)
    TriggerServerEvent('whip_voice:server:speaker', id, what, value or '')
end

local function actionFor(v)
    local id = v.id
    local function cur() return list[id] end
    return {
        id = 'speaker:' .. id,
        group = GROUP,
        at = anchorOf(v),
        label = function()
            local c = cur()
            if c and c.playing then return 'Speaker  ·  ' .. (c.song or 'playing') end
            return 'Speaker'
        end,
        icon = 'power',
        reach = 2.0,
        options = {
            {
                id = 'song', icon = 'pin',
                label = function()
                    local c = cur()
                    return (c and c.song) and ('Song: ' .. c.song) or 'Song link'
                end,
                onSelect = function(ctx)
                    if not cur() then return ctx.refuse('That speaker is gone') end
                    local links = S.links or { 'https://r2.fivemanage.com/' }
                    -- Typed into the prompt as its volume is (a capsule on a keyboard, where a link pastes; the
                    -- on-screen keyboard on a pad), as text: a link is not a number. The server checks it.
                    ctx.beginInput({
                        numeric = false, max = 255, title = 'Song link',
                        placeholder = tostring(links[1]) .. '.../song.mp3',
                        onSubmit = function(text)
                            text = tostring(text or ''):match('^%s*(.-)%s*$')
                            if text ~= '' then send(id, 'link', text) end
                        end,
                    })
                end,
            },
            {
                id = 'play', icon = 'power',
                label = function()
                    local c = cur()
                    return (c and c.playing) and 'Stop' or 'Play'
                end,
                onSelect = function(ctx)
                    local c = cur()
                    if not c then return ctx.refuse('That speaker is gone') end
                    if not c.playing and not c.song then return ctx.refuse('Give it a song first') end
                    send(id, c.playing and 'stop' or 'play')
                end,
            },
            {
                id = 'volume', icon = 'talk',
                label = function(ctx)
                    if ctx.typed then return 'Volume  ' .. ctx.typed .. ' %' end
                    local c = cur()
                    return 'Volume  ' .. tostring(c and c.volume or 100) .. ' %'
                end,
                onSelect = function(ctx)
                    ctx.beginInput({ max = 3, onSubmit = function(text) send(id, 'volume', text) end })
                end,
            },
            {
                id = 'range', icon = 'target',
                label = function(ctx)
                    if ctx.typed then return 'Range  ' .. ctx.typed .. ' m' end
                    local c = cur()
                    return 'Range  ' .. tostring(c and c.range or 30) .. ' m'
                end,
                onSelect = function(ctx)
                    ctx.beginInput({ max = 3, onSubmit = function(text) send(id, 'range', text) end })
                end,
            },
            {
                id = 'pickup', icon = 'pickup', label = 'Pick up', holdMs = 600,
                onSelect = function() send(id, 'pickup') end,
            },
        },
    }
end

-- ---- What the server says ------------------------------------------------------------------------

--- The speakers as they are now: a prompt put up for each new one (or one that moved to another car or spot), and
--- taken down for each gone.
local function take(views)
    local now = {}
    for _, v in ipairs(type(views) == 'table' and views or {}) do
        if type(v) == 'table' and v.id then now[v.id] = v end
    end
    list = now
    for id in pairs(mounted) do
        if not now[id] then
            Whip.core:RemoveAction('speaker:' .. id)
            mounted[id] = nil
        end
    end
    for id, v in pairs(now) do
        local key = whereKey(v)
        if mounted[id] ~= key then
            local ok, why = Whip.core:AddAction(actionFor(v))
            if ok then mounted[id] = key
            else print(('[whip_voice] speaker %d\'s prompt could not be put up: %s'):format(id, tostring(why))) end
        end
    end
end

RegisterNetEvent('whip_voice:client:speakers', take)

-- A game just started (or whip_voice / whip_core did): every speaker, and their prompts again (whip_core's actions
-- went with it if it restarted).
Whip.register(function()
    mounted = {}
    CreateThread(function()
        local views = Whip.core:Callback('whip_voice:speakers')
        if type(views) == 'table' then take(views) end
    end)
end)
