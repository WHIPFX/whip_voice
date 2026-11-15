# whip_voice

3D voice chat for [WHIP](https://github.com/WHIPFX/txAdmin-recipe). Players hear each other from where they stand,
muffled through walls and closed doors, and from the doorway or window between them. Phone calls, the radio and the
megaphone all run on the same voice.

whip_voice runs its own voice server alongside your FiveM server, so there's nothing else to install.

## Features

- **3D voices.** Each voice comes from the player's head and fades with distance. Players switch between whisper,
  normal and shout.
- **Rooms, walls and cars.** Voices carry through open doorways and are muffled by closed doors, windows, walls,
  closed cars and water. Rooms echo by their size. Outdoors, sound goes round corners and over low walls.
- **Phone calls.** Calls carry the phone's sound. On speaker, everyone near the phone takes part.
- **Radio.** A walkie-talkie item with a 3D radio on screen. Players on the same frequency hear each other, with
  static as they get further apart.
- **Megaphone.** An item that carries the voice six times as far, with a bullhorn sound.
- **Speaker.** An item that plays a song for everyone around, put down anywhere or on a car. Music is heard as from far
  off: it comes late and loses its treble with distance, and a speaker on a passing car rises and falls in pitch.
- **Private.** The server decides who hears whom. A modified game can't listen in on calls or radio frequencies.
- **Characters that talk.** WHIP's Director can have its characters phone players and speak in the world.

## Requirements

- WHIP's `whip_core`.
- FXServer on Windows or Linux (64-bit): FiveM Legacy (artifact 38435 or newer) or GTA V Enhanced.
- The voice ports open inbound: **UDP 7882-7893** and **TCP 7881**. On rented game hosting, your host must allow
  extra ports.

## Installation

WHIP's [txAdmin recipe](https://github.com/WHIPFX/txAdmin-recipe) installs and configures whip_voice. To install it
by hand, put `whip_voice` in your `resources` folder and add these lines to `server.cfg` after `ensure whip_core`:

```cfg
add_unsafe_child_process_permission whip_voice
ensure whip_voice
```

The permission line lets whip_voice start its voice server and voice bot, which run as separate programs.

### Opening the voice ports

- **Windows Firewall:** when Windows asks whether to allow `livekit-server.exe`, click **Allow** (on a server, include
  public networks). Otherwise, or if you clicked **Cancel**, run `whip_voice/service/Open voice ports.bat`.
- **Your host's firewall:** allow the ports in your host's control panel, as you did for 30120.
- **Behind a router:** forward the ports to the server.
- **Linux with ufw:** `ufw allow 7882:7893/udp` and `ufw allow 7881/tcp`.

On first start, whip_voice downloads [LiveKit](https://livekit.io) (about 20 MB) into `whip_voice/bin`, verifies its
checksum and starts it. The voice bot, which plays characters' recorded lines, installs in the background (about
100 MB). The voice server starts and stops with your FiveM server.

## For players

| Key | Action |
| --- | --- |
| **N** | Push to talk |
| **Z** | Switch between whisper, normal and shout |
| **Caps Lock** | Talk on the radio |

Players can rebind these in **Settings > Key Bindings > FiveM**.

On first join, FiveM asks for microphone access. Its prompt only takes the mouse while the **F8** console is open:
press F8, click **Allow**, then close F8.

## Checking it

`/voicecheck` (in game, for admins in developer mode) or `voicecheck` (in the server console) checks the voice
server, the firewall and every player's connection, and says what to fix. `voicestatus` lists who is connected.
[docs/SETUP.md](docs/SETUP.md) explains each message.

## Configuration

`config.lua` sets the keys, voice ranges, the radio and megaphone, how much walls, doors and cars muffle, and sound
quality. Ports, a fixed public address and the voice bot are set in `server.cfg`; see
[docs/SETUP.md](docs/SETUP.md#settings).

## Using your own voice server

To use LiveKit Cloud or LiveKit on another machine, set `whip_voice_url` and its keys in `server.cfg`; the built-in
voice server then stays off. See [docs/SETUP.md](docs/SETUP.md#your-own-voice-server).

## For developers

Other resources can open voice lines (an intercom, a dispatch channel), give them a sound, and play recordings into
them or from NPCs. See [docs/LINES.md](docs/LINES.md).

## License

whip_voice is licensed under the GNU LGPL 3.0; see `COPYING.LESSER`, and `COPYING` for the GPL 3.0 it builds on.
`NOTICE.md` says what the licence doesn't cover; `whip_core`'s `NOTICE.md` is the full list. The LiveKit server it
downloads is licensed under Apache 2.0.
