# whip_voice: voice lines (for other resources)

Your resource can use whip_voice's voice without any of your code going into whip_voice. A **line** is a set of
players who hear each other wherever they are, through a sound you choose. whip_phone's calls are lines it opens;
an intercom, a dispatch channel or a bugged room would be lines too. whip_voice's own radio frequencies are lines.

Everything here is **server side**. Only a server decides who is on a line, so a modified game can't join one or
listen in.

**One way in.** Call these through whip_core, never whip_voice by name: `Whip.voice('OpenLine', spec)` (from
`@whip_core/lib/satellite.lua`) calls the voice system that is running, and answers `false, why` when none is.
`Whip.voiceSystem()` says which one, and its `features` (what it can do).

## The short version

```lua
-- A call between two players, sounding like a phone:
local lineId, why = Whip.voice('OpenLine', {
    members = { callerSrc, calleeSrc },
    recipe  = {
        { 'band', low = 300, high = 3400 },          -- the telephone band
        { 'compress', threshold = -24, ratio = 4 },
        { 'noise', kind = 'pink', level = 0.008 },
    },
    pickup  = true,                                   -- on speaker, the people near the phone are heard too
    onLeave = function(lineId, src, why) end,         -- a member went (left, logged out)
    onEnd   = function(lineId, why) end,              -- the line closed by itself ('empty')
})
if not lineId then print('no call: ' .. why) end

Whip.voice('SetLineSpeaker', lineId, calleeSrc, true)   -- the callee's phone on speaker
Whip.voice('SetLineMuted', lineId, callerSrc, true)     -- the far side stops hearing the caller
Whip.voice('CloseLine', lineId)                         -- hang up
```

(`exports.whip_voice:OpenLine(...)` still works, but only while whip_voice is the one running.)

## How a line sounds and works

- **Push to talk, as always.** A `voice` line carries what each member says with their normal talk key; the people
  around them still hear them as usual. A `radio` line carries the radio key instead (what whip_voice's radio uses).
- **From their own device.** Each member hears the others in both ears, through your recipe, at their own volume.
- **On speaker** (`SetLineSpeaker`), the line also comes out of that member's device in 3D, for the people standing
  near: walls, doors and distance apply. It is not louder for its owner.
- **Speaker both ways** (`pickup = true`): the people near a member's device on speaker are heard by the line's
  other members too, as a speakerphone's microphone would hear them:
  - only within their own voice range of the device (a whisper from 3 m) and never further than its `speakerRange`;
  - quieter the further from it they stand;
  - by the nearest of the line's devices, if they stand near two.
- **Muted** (`SetLineMuted`): the line doesn't hear that member, nor anyone near their device. The people around
  them still hear them.
- **Downed members** stay on and hear, but can't talk (whip_voice's rule: `Config.DeadCanTalk`). A downed member's
  device on speaker keeps playing.
- **Across worlds:** members hear each other in any routing bucket, unless you open the line with `sameWorld = true`.
- **With distance** (`quality = { clear = 500, range = 1500 }`): clear up to `clear` metres apart, breaking up beyond,
  gone past `range`. Without it, a line is clear wherever its members are.
- **Two lines between the same two players** on the same track (a call and an intercom): they hear each other once,
  through the line already in use (or the oldest), never twice through two sounds.

**The real reach of a speaker.** Tell your players: a device on speaker plays the line to everyone within its
`speakerRange`, and a modified game can be connected up to 3 m further, for a second after they step away. With
`pickup`, the line's members are sent the voices of the people near it for as long as they stand there.

## The exports

Every export answers its value (or `true`), or `false` and a reason, never `nil`.

| Export | What it does |
|---|---|
| `OpenLine(spec)` | Opens a line you own. Answers its id (a string), or `false, why`. |
| `CloseLine(lineId)` | Closes it: everyone on it stops hearing at once. Closing one that is gone already is fine. |
| `AddLineMember(lineId, src)` / `RemoveLineMember(lineId, src)` | Puts a player on or off it. |
| `SetLineSpeaker(lineId, src, on)` | That member's device out loud, or not. |
| `SetLineMuted(lineId, src, on)` | The line stops hearing that member, or hears them again. |
| `SetLineRecipe(lineId, recipe)` | Changes the sound while it is open (everyone hearing it is told at once). |
| `GetLine(lineId)` | `{ id, track, members = { [src] = { speaker, muted } }, pickup, sameWorld, speakerRange, minMembers }`. |
| `RegisterSound(name, recipe)` | Keeps a recipe by name: `'<your resource>:<name>'`. Use it as `recipe = 'name'` (yours) or the full name (anyone's). |
| `IsVoiceReady(src)` | `true` when they are connected to voice with a microphone; else `false, 'not connected to voice'` or `'no microphone'`. |

**`OpenLine` spec:**

| Field | Default | |
|---|---|---|
| `members` | none | Server ids. Each must have a character loaded. At most 32. |
| `track` | `'voice'` | `'voice'` (the talk key) or `'radio'` (the radio key). |
| `recipe` | none (the plain voice) | A list of blocks (below), or a sound's name. |
| `speakerRange` | 8 | Metres a member's device on speaker carries, 1 to 30. |
| `pickup` | false | On speaker, the people near the device are heard too. |
| `quality` | none | `{ clear = metres, range = metres }`: breaks up with distance. |
| `sameWorld` | false | Only members in the same routing bucket hear each other. |
| `minMembers` | 2 | Fewer members than this and the line closes by itself (`onEnd`, `'empty'`). |
| `onEnd(lineId, why)` | none | The line closed by itself. Not called when you close it, or when your resource stops. |
| `onLeave(lineId, src, why)` | none | A member went: `'left'`, `'logout'`, `'removed'`. |

**Owning lines:**
- Only your resource can change or close your lines. When it stops, they close (no callbacks), and its sounds go.
- At most 500 lines open per resource.
- Callbacks run in a thread of their own, only while your resource still runs. An error inside one is printed and
  goes no further.
- **Members leave by themselves** when they disconnect or log out; you hear it in `onLeave`.
  A member who is momentarily not in voice (reconnecting) stays a member: they simply hear nothing until they are back.

**When whip_voice restarts,** every line is gone. Handle it in your resource:

```lua
AddEventHandler('onResourceStop', function(res) if res == 'whip_voice' then --[[ forget your line ids ]] end end)
AddEventHandler('onResourceStart', function(res) if res == 'whip_voice' then --[[ open them again, if you want ]] end end)
```

Use `GetResourceState('whip_voice') == 'started'` before calling, and call under `pcall`, if your resource must
work without whip_voice (a server may run another voice system).

## Voice bots: a recording on a line

Requires the voice bot, which the built-in voice server sets up (`/voicecheck` shows whether it runs). A voice bot is
a recording heard on one of your lines as if someone on it were talking:
whip_phone's Phone Call card is one, a lore character phoning a player. To the players' games it is one more voice on
the line, so the line's recipe, a device on speaker and the people near it work as for anyone. It only talks: it never
hears the line, and nobody near anyone hears it except through a member's device.

| Export | What it does |
|---|---|
| `CreateVoiceBot({ name, audio })` | Joins the voice room and gets the recording ready. `audio`: an mp3/ogg/wav file a started resource ships, `"@my_story/audio/line.ogg"` (players never download it), or a link to one on a site the bot accepts (Fivemanage unless the server added more). WAITS. Answers `botKey, durationMs`, or `false, why` (the bot's own words for a refused one). |
| `PutVoiceBotOnLine(botKey, lineId)` | Puts it on one of your lines. It counts as a member (`minMembers`). |
| `PlayVoiceBot(botKey, onDone)` | Plays it once. WAITS a moment. `onDone(botKey, why)`: `'done'` (to the end), `'removed'`, `'lineClosed'`, `'failed'`. |
| `RemoveVoiceBot(botKey)` | Lets it go (off its line, out of the room). Gone already is fine. |
| `VoiceBotStatus()` | `{ ok, version, calls, max }`, or `false, why`. WAITS. |

- Make it before you need it (a phone: before it rings), so the recording is fetched and checked by then.
- A bot is yours: only your resource can use it, and it goes when your resource stops (no `onDone` then).
- When it finishes it leaves the line, and a line with too few members closes. `onDone` and that `onEnd` are told
  at the same moment, in no set order: wait a moment in `onEnd` if you need to tell the two apart.
- At most 30 bots run at once (`Config.VoiceBot.maxCalls`), world voices included. Past that, `CreateVoiceBot` waits
  up to `Config.VoiceBot.WaitSeconds` (5) for a free one, then returns `false, 'every voice bot line is in use'`.
- If the voice server or the voice bot restarts, every bot is removed and its `onDone` receives `'failed'`. When
  whip_voice itself restarts, bots are removed without `onDone`.

## World voices

A world voice plays recordings from an entity, usually an NPC, or from fixed spots, and is heard like a player's
voice: from where it is, within its range, through walls and doorways. It only talks. The Director's lore characters
and speakers use it.

| Export | Returns | Description |
|---|---|---|
| `CreateWorldVoice({ name, at, range, bucket, music })` | `key` | Creates a voice where `at` says. `range` is 2–300 m, default 12. `bucket` is the routing bucket of fixed spots (default 0). `music = true` makes it heard as music (below). WAITS. |
| `PlayWorldVoice(key, audio, onDone, opts)` | `durationMs` | Plays a recording (`audio` as in `CreateVoiceBot`), cutting off one already playing. WAITS while it loads. |
| `StopWorldVoice(key, fadeMs)` | `true` | Stops what it plays, at once or faded down over `fadeMs` (up to 30000). |
| `MoveWorldVoice(key, at)` | `true` | Moves it, keeping its settings. |
| `SetWorldVoiceRange(key, range, fullWithin)` | `true` | Sets how far it carries (2–300 m) and how far it stays at full volume. |
| `SetWorldVoiceSound(key, recipe)` | `true` | How it sounds to everyone hearing it: a recipe (below), or `false` for its plain sound. |
| `SetWorldVoiceMegaphone(key, on)` | `true` | Raises or lowers a megaphone, as the megaphone item does. It sounds like the megaphone while it is up, whatever its own sound. |
| `SetWorldVoiceRadio(key, frequency)` | `true` | Puts it on a radio frequency (100–999), or takes it off with `false`. |
| `RemoveWorldVoice(key)` | `true` | Removes it. |
| `GetPlayerRadio(source)` | `frequency` or `false` | The frequency a player's radio is on, or `false` while it is off. |

Each returns `false, reason` on failure. `onDone(key, reason)` receives `'done'`, `'stopped'`, `'cut'`, `'removed'` or
`'failed'`.

`at` is one place or a list of up to 32. A list is one sound heard from every place at once, in step: a room full of
speakers. Each player hears each place by their own distance to it, and the places add up as real speakers do, by
their power: two alike are 3 dB louder than one, not twice as loud, and next to one of them you hear mostly that one.

| A place | Comes from |
|---|---|
| `{ netId = n }` | An entity, followed as it moves. |
| `{ netId = n, offset = vector3(x, y, z), model = 'prop_speaker_06' }` | A spot on an entity, in its own frame (up to 10 m from it): a speaker on a car's roof. With `model`, the sound comes out of the object of that model riding there. |
| `{ coords = vector3(x, y, z), model = 'prop_speaker_06' }` | A fixed spot. With `model`, each player's game finds its own copy of the object standing there, so the object's walls and room are used. |

A world voice made with `music = true` is heard as sound from far off is, which a voice in a conversation must not be:
it arrives late by its distance at the speed of sound, so as it comes closer or goes away it plays a little faster
and higher, or slower and lower (the Doppler effect, by the speed itself: a car passing at 110 km/h about a semitone
and a half); the air takes its treble with distance while its bass carries; and outdoors, the further off it is, the
more of what you hear is its echo off everything around. Round a corner outdoors it is heard by two ways at once, the
best way round and the best through another opening, each from its own corner and as loud as its own length and bends
make it: walking past a row of alleys, one fades up as the other fades down, and where it seems to come from slides to
a new corner rather than jumping. The Director's speakers and the speaker item are music.

`opts` for `PlayWorldVoice`: `loop = true` plays it over and over until `StopWorldVoice`; `music = true` lets it be a
song, up to the voice bot's `musicSeconds` and `musicBytes` (10 minutes and 40 MB unless its config.json says
otherwise) rather than a line's two minutes; `fadeIn = ms` brings it up from silence.

- The voice is silent, on the radio too, while none of its places exists on the server. After respawning an NPC, call
  `MoveWorldVoice`.
- On a frequency it is heard like a player's radio: by players on that frequency in its routing bucket, fading with
  distance.
- It belongs to the resource that created it and is removed when that resource stops.
- Songs, loops, fades and `StopWorldVoice` need voice bot 1.5.0 or newer. An older bot answers `StopWorldVoice` by
  saying to run the voice setup again.

```lua
-- A dispatcher heard at the desk and on radio channel 100. These exports wait, so call them in a thread.
CreateThread(function()
    local voice = Whip.voice('CreateWorldVoice', { name = 'Dispatch', at = { netId = NetworkGetNetworkIdFromEntity(ped) }, range = 8 })
    if not voice then return end
    Whip.voice('SetWorldVoiceRadio', voice, 100)
    Whip.voice('PlayWorldVoice', voice, '@my_story/audio/all_units.ogg')
end)
```

```lua
-- Two speakers on a club's walls playing one song on a loop, sounding like cheap speakers, faded out at closing time.
CreateThread(function()
    local club = Whip.voice('CreateWorldVoice', { name = 'Club', range = 40, at = {
        { coords = vector3(-1386.9, -614.3, 31.8), model = 'prop_speaker_06' },
        { coords = vector3(-1380.2, -627.1, 31.8), model = 'prop_speaker_06' },
    } })
    if not club then return end
    Whip.voice('SetWorldVoiceSound', club, { { 'highpass', hz = 120 }, { 'lowpass', hz = 9000 }, { 'peak', hz = 1800, db = 3 } })
    Whip.voice('PlayWorldVoice', club, 'https://r2.fivemanage.com/your-id/night.mp3', nil, { loop = true, music = true, fadeIn = 2000 })
end)
-- Later: Whip.voice('StopWorldVoice', club, 3000)
```

## Recipes: sound as data

A recipe is a list of blocks, in order. Each block is a table with its name first (or `type = 'name'`) and its
settings. A setting you leave out takes its default; a number out of range is brought into it. An unknown block,
a setting that isn't a number, or a word that isn't one of the choices is **refused**, saying which.

```lua
{ { 'band', low = 300, high = 3400 }, { 'drive', k = 1.5 }, { 'gain', db = -2 } }
```

**Limits:** at most 24 blocks, and at most 4 that make sound of their own (noise, hum, breakup, radio, chorus,
vibrato, tremolo, ringmod, reverb). Every line made from your recipe ends in a safety limiter, so nothing you send
can be painfully loud.

The one list of blocks and their ranges is `whip_voice/shared/sound_blocks.lua`. Every setting is written there as
`{ min, max, default }`, or a list of words whose first is the default.

| Block | Settings | What it does |
|---|---|---|
| `gain` | `db` (-60..24) | Louder or quieter. |
| `lowpass` / `highpass` | `hz`, `q` | Cuts the highs above, or the lows below, `hz`. |
| `bandpass` / `notch` | `hz`, `q` | Keeps only, or takes out, a band around `hz`. |
| `peak` | `hz`, `q`, `db` (-30..30) | Boosts or cuts a band. |
| `lowshelf` / `highshelf` | `hz`, `db` | The lows or the highs up or down. |
| `band` | `low`, `high`, `q` | Keeps `low`..`high` (a telephone: 300-3400). |
| `drive` | `k` (1..50), `oversample` (`none`, `2x`, `4x`) | Soft clipping: loud sound rounded off, harder the bigger `k`. It turns quiet sound up too, so follow it with a `gain`. |
| `crush` | `steps` (2..256) | Rounds the sound to that many steps: a digital edge. |
| `compress` | `threshold`, `knee`, `ratio`, `attack`, `release` | Loud and quiet squeezed together. |
| `noise` | `kind` (`white`, `pink`, `brown`), `level` (0..0.3), `hz`, `q` | A hiss under the voice, only while they talk. |
| `hum` | `hz` (20..400), `level` (0..0.3) | A mains hum (50 or 60 Hz) under the voice, only while they talk. |
| `breakup` | `static` (0..1) | Drops out more the weaker the line's quality, static in every gap. |
| `beeps` | `up`, `down`, `down2` (Hz; 0 = that beep off), `level` | A beep as they start talking, two as they stop. |
| `pan` | `to` (-1..1) | Towards one ear. |
| `echo` | `time` (0.02..2 s), `feedback` (0..0.9), `mix` | Repeats, `time` apart, each `feedback` as loud as the last. |
| `chorus` | `rate`, `depth`, `mix` | A second, wavering copy: thick, shimmering. |
| `vibrato` | `rate`, `depth` | The pitch wavers. |
| `tremolo` | `rate`, `depth` | The loudness pulses. |
| `ringmod` | `hz`, `mix` | A robot, a dalek. |
| `reverb` | `size` (0.1..4 s), `mix` | A room around the device, only while they talk. |
| `radio` | `static`, `distortion` | whip_voice's walkie-talkie, breaking up with the line's quality. |

## Examples

**An intercom** between a door and whoever is inside the building (the door's player presses a button):

```lua
local intercom = exports.whip_voice:OpenLine({
    members = { visitorSrc, residentSrc },
    recipe = { { 'band', low = 400, high = 3000 }, { 'drive', k = 2 }, { 'gain', db = -3 },
               { 'reverb', size = 0.4, mix = 0.15 } },
    minMembers = 2,
    onLeave = function(id) exports.whip_voice:CloseLine(id) end,
})
```

**A dispatch line** for every on-duty officer, heard on the radio key with distance not mattering:

```lua
local dispatch = exports.whip_voice:OpenLine({ track = 'radio', minMembers = 1,
    recipe = { { 'radio', static = 0 }, { 'beeps' } } })
exports.whip_voice:AddLineMember(dispatch, officerSrc)        -- as each one clocks on
exports.whip_voice:RemoveLineMember(dispatch, officerSrc)     -- and off
```

A line with `minMembers = 1` closes with its last member: open it again for the next one to clock on (an
`AddLineMember` on a closed line answers `false, 'no such line (closed?)'`).
