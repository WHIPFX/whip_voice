-- ============================================
-- whip_voice — the speaker (an item), in the player's game
-- ============================================
--
-- Using the item runs whip's placer (PlaceObject: where you look, the wheel turns it, the arrows raise it, on a car
-- too) and sends where it went (server/speakers.lua puts it down). Behind every speaker, a prompt: the song (a link,
-- typed in a dialog), Play / Stop, Volume and Range (typed into the prompt), Pick up.
--
-- One action for every speaker: on the speaker's model wherever it stands (whip's model prompts), offered only on the
-- ones that are speakers (another prop of the same model, a club's, gets nothing). Behind = its back, the side away
-- from whoever put it down (the placer starts it facing the way they face).

local SPEAKER_KEY = 'speakers'
local S = Config.Speaker or {}
local MODEL = S.model or 'ba_prop_battle_club_speaker_small'
local list = {}          -- [id] = what the server says of it (server/speakers.lua views)

-- ---- Putting one down ----------------------------------------------------------------------------

RegisterNetEvent('whip_voice:client:placeSpeaker', function(model)
    CreateThread(function()
        local spot, why = Whip.call('PlaceObject', model, { label = 'Speaker', vehicles = true, reach = 4.0 })
        if not spot then
            if why ~= 'cancelled' then print('[whip_voice] the speaker was not put down: ' .. tostring(why)) end
            return
        end
        local o, r = spot.offset or vector3(0.0, 0.0, 0.0), spot.offsetRot or vector3(0.0, 0.0, 0.0)
        TriggerServerEvent('whip_voice:server:placeSpeaker', spot.coords.x, spot.coords.y, spot.coords.z,
            spot.rot.x, spot.rot.y, spot.rot.z, spot.netId or 0, o.x, o.y, o.z, r.x, r.y, r.z)
    end)
end)

-- ---- Which speaker a prop is ---------------------------------------------------------------------

--- The speaker this object is (this game's copy of its prop), or nil: on a car, the one riding that car at that spot;
--- on the ground, the one at that spot.
local function speakerOf(obj)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    local at = GetEntityCoords(obj)
    local car = GetEntityAttachedTo(obj)
    for _, v in pairs(list) do
        if v.net then
            if car ~= 0 and NetworkDoesNetworkIdExist(v.net) and NetworkGetEntityFromNetworkId(v.net) == car then
                local o = v.offset
                local want = GetOffsetFromEntityInWorldCoords(car, o[1] + 0.0, o[2] + 0.0, o[3] + 0.0)
                if #(at - want) < 1.0 then return v end
            end
        elseif car == 0 then
            local c = v.coords
            if #(at - vector3(c[1] + 0.0, c[2] + 0.0, c[3] + 0.0)) < 0.75 then return v end
        end
    end
    return nil
end

local function send(ctx, what, value)
    local v = speakerOf(ctx.entity)
    if not v then return ctx.refuse('That speaker is gone') end
    TriggerServerEvent('whip_voice:server:speaker', v.id, what, value or '')
end

-- ---- The prompt behind it ------------------------------------------------------------------------

local mounted = false

local function mount()
    -- Behind it: its model's back face (-y in its own frame), a little out, halfway up.
    local hash = GetHashKey(MODEL)
    local lo, hi = vector3(-0.3, -0.3, 0.0), vector3(0.3, 0.3, 0.8)
    if IsModelInCdimage(hash) then
        local a, b = GetModelDimensions(hash)
        if a and b then lo, hi = a, b end
    end
    local back = vector3((lo.x + hi.x) / 2, lo.y - 0.12, (lo.z + hi.z) / 2)
    local ok, why = Whip.call('AddAction', {
        id = SPEAKER_KEY,
        at = { model = MODEL, offset = back },
        label = function(ctx)
            local v = speakerOf(ctx.entity)
            if not v then return 'Speaker' end
            return v.playing and ('Speaker  ·  ' .. (v.song or 'playing')) or 'Speaker'
        end,
        icon = 'power',
        reach = 2.0,
        canInteract = function(ctx) return speakerOf(ctx.entity) ~= nil end,
        options = {
            {
                id = 'song', icon = 'pin',
                label = function(ctx)
                    local v = speakerOf(ctx.entity)
                    return (v and v.song) and ('Song: ' .. v.song) or 'Song link'
                end,
                onSelect = function(ctx)
                    local v = speakerOf(ctx.entity)
                    if not v then return ctx.refuse('That speaker is gone') end
                    local links = S.links or { 'https://r2.fivemanage.com/' }
                    local answer = Whip.call('Input', 'Speaker', {
                        { label = 'Song link', type = 'text', required = true,
                          placeholder = tostring(links[1]) .. '.../song.mp3' },
                    })
                    if type(answer) ~= 'table' or type(answer[1]) ~= 'string' then return end
                    TriggerServerEvent('whip_voice:server:speaker', v.id, 'link', answer[1])
                end,
            },
            {
                id = 'play', icon = 'power',
                label = function(ctx)
                    local v = speakerOf(ctx.entity)
                    return (v and v.playing) and 'Stop' or 'Play'
                end,
                onSelect = function(ctx)
                    local v = speakerOf(ctx.entity)
                    if not v then return ctx.refuse('That speaker is gone') end
                    if not v.playing and not v.song then return ctx.refuse('Give it a song first') end
                    send(ctx, v.playing and 'stop' or 'play')
                end,
            },
            {
                id = 'volume', icon = 'talk',
                label = function(ctx)
                    if ctx.typed then return 'Volume  ' .. ctx.typed .. ' %' end
                    local v = speakerOf(ctx.entity)
                    return 'Volume  ' .. tostring(v and v.volume or 100) .. ' %'
                end,
                onSelect = function(ctx)
                    ctx.beginInput({ max = 3, onSubmit = function(text) send(ctx, 'volume', text) end })
                end,
            },
            {
                id = 'range', icon = 'target',
                label = function(ctx)
                    if ctx.typed then return 'Range  ' .. ctx.typed .. ' m' end
                    local v = speakerOf(ctx.entity)
                    return 'Range  ' .. tostring(v and v.range or 30) .. ' m'
                end,
                onSelect = function(ctx)
                    ctx.beginInput({ max = 3, onSubmit = function(text) send(ctx, 'range', text) end })
                end,
            },
            {
                id = 'pickup', icon = 'pickup', label = 'Pick up', holdMs = 600,
                onSelect = function(ctx) send(ctx, 'pickup') end,
            },
        },
    })
    if not ok then print('[whip_voice] the speaker prompt could not be added: ' .. tostring(why)) end
    mounted = ok == true or ok ~= false
end

-- ---- What the server says ------------------------------------------------------------------------

local function take(views)
    local now = {}
    for _, v in ipairs(type(views) == 'table' and views or {}) do
        if type(v) == 'table' and v.id then now[v.id] = v end
    end
    list = now
    -- The prompt is up only while there are speakers to use (one model action, offered on the speakers only).
    if next(list) and not mounted then mount()
    elseif not next(list) and mounted then
        Whip.call('RemoveAction', SPEAKER_KEY)
        mounted = false
    end
end

RegisterNetEvent('whip_voice:client:speakers', take)

-- A game just started (or whip_voice / whip_core did): every speaker, and the prompt again (whip_core's actions went
-- with it if it restarted).
Whip.register(function()
    mounted = false
    CreateThread(function()
        local views = Whip.call('Callback', 'whip_voice:speakers')
        if type(views) == 'table' then take(views) end
    end)
end)
