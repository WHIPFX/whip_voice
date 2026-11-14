-- The radio item (a walkie-talkie). Use it and the 3D radio opens on the player's screen (client/walkie.lua,
-- html/js/walkie.js): power, a channel from 100 to 999 (the channel is the frequency), volume, and the speaker. While it
-- is on, everyone on the same frequency hears them when they hold the radio key: clearly up close, breaking up further
-- away, then fading to nothing (html/js/fx.js's 'radio' block).
--
-- Each frequency is a voice line (server/lines.lua): 'radio:<freq>', made when its first radio tunes in and gone with
-- its last, on the radio track, breaking up with distance (Config.Radio clearWithin / maxRange), heard only in the same
-- world. This file is the radio item around it.
--
-- On speaker (the button on top), what the radio receives plays out loud for the people near it, like a phone on
-- speaker. One way only: a walkie sends only while its holder presses the key (no pickup).
--
-- The server decides who is on which frequency and whose radio is on speaker: it only happens with a radio in the
-- player's pockets and a real frequency. The dead stay on and can hear; they cannot talk.

Radio = {
    members = {},    -- [src] = frequency, while their radio is on
    speakers = {},   -- [src] = true while their radio is on speaker
}

local function bounds()
    local R = Config.Radio or {}
    return tonumber(R.minFrequency) or 100, tonumber(R.maxFrequency) or 999
end

--- The frequency's line: how a radio sounds and carries, from config.lua.
local function lineSpec()
    local R = Config.Radio or {}
    return {
        track = 'radio', rx = true, sameWorld = true, pickup = false, minMembers = 1,
        quality = { clear = tonumber(R.clearWithin) or 500, range = tonumber(R.maxRange) or 1500 },
        speakerRange = tonumber(R.speakerRange) or 8,
        -- A radio on speaker is connected as early, and held as long, as a voice (server/audibility.lua).
        margin = Audibility.MARGIN, hold = Audibility.HOLD_MS,
        -- Its sound (html/js/fx.js): the walkie, then its talk beeps on every press and release.
        recipe = { { type = 'radio', static = tonumber(R.staticVolume) or 0.06, distortion = tonumber(R.distortion) or 1 },
                   { type = 'beeps' } },
    }
end

local function lineOf(freq) return Lines.shared('radio:' .. tostring(freq), lineSpec) end
--- Is this a frequency a radio can be on? true, or false and why.
function Radio.validFrequency(freq)
    local lo, hi = bounds()
    if math.type(freq) ~= 'integer' or freq < lo or freq > hi then
        return false, ('a frequency is a whole number from %d to %d'):format(lo, hi)
    end
    return true
end

--- A frequency's line, made if nobody is on it yet: for a world voice going on the radio (server/bots.lua). Check the
--- frequency first (Radio.validFrequency).
function Radio.lineFor(freq)
    return lineOf(freq)
end

local function leaveFreq(src, freq, why)
    local id = freq and Lines.byKey['radio:' .. tostring(freq)]
    if id then Lines.leave(id, src, why or 'off') end
end

--- Tell the player's game how their radio stands (the radio on the screen shows it). Also the answer
--- to a change whip refused before it got here (too fast, bad values: server/main.lua onReject), so
--- the radio never shows something it is not.
local function tell(src)
    TriggerClientEvent('whip_voice:client:radioState', src,
        { on = Radio.members[src] ~= nil, freq = Radio.members[src], speaker = Radio.speakers[src] == true })
end
Radio.tell = tell

--- On, tuned to `freq`, or off (the speaker goes off with it).
---@return boolean ok
---@return string|nil why
function Radio.set(src, on, freq)
    local was = Radio.members[src]
    if on then
        if exports.whip_core:HasItem(src, 'radio') ~= true then
            Radio.members[src], Radio.speakers[src] = nil, nil
            leaveFreq(src, was)
            tell(src)
            return false, 'You have no radio'
        end
        local min, max = bounds()
        freq = math.tointeger(tonumber(freq))
        if not freq or freq < min or freq > max then
            tell(src)                                   -- the radio shows what it really is again
            return false, 'That is not a frequency'
        end
        if was ~= freq then leaveFreq(src, was, 'retuned') end
        Radio.members[src] = freq
        local id = lineOf(freq)
        Lines.join(id, src)
        -- On speaker, still on speaker on the new frequency.
        if Radio.speakers[src] then Lines.setSpeaker(id, src, true) end
    else
        if was == nil then return true end
        Radio.members[src], Radio.speakers[src] = nil, nil
        leaveFreq(src, was)
    end
    tell(src)
    if Hearing then Hearing.wake() end
    return true
end

--- The speaker on or off. Only while the radio is on: a radio that is off has nothing to play.
---@return boolean ok
---@return string|nil why
function Radio.setSpeaker(src, on)
    on = on == true
    if on and Radio.members[src] == nil then
        tell(src)
        return false, 'The radio is off'
    end
    Radio.speakers[src] = on or nil
    local id = Radio.members[src] and Lines.byKey['radio:' .. tostring(Radio.members[src])]
    if id then Lines.setSpeaker(id, src, on) end
    tell(src)
    if Hearing then Hearing.wake() end
    return true
end

--- The item's use: open the radio, showing how it stands. The item is kept (false).
function Radio.use(source)
    local min, max = bounds()
    TriggerClientEvent('whip_voice:client:walkie', source,
        { on = Radio.members[source] ~= nil, freq = Radio.members[source], speaker = Radio.speakers[source] == true,
          min = min, max = max })
    return false
end

-- OFF when the last radio leaves their pockets (dropped, given, stored), or they log out.
AddEventHandler('whip_core:item:removed', function(e)
    if type(e) == 'table' and e.item == 'radio' and (tonumber(e.count) or 0) <= 0 then Radio.set(e.source, false) end
end)
AddEventHandler('whip_core:player:logout', function(e)
    if type(e) == 'table' and e.source then Radio.set(e.source, false) end
end)

-- Gone: forgotten (their lines let go of them by themselves: server/lines.lua).
AddEventHandler('playerDropped', function()
    Radio.members[source], Radio.speakers[source] = nil, nil
end)
