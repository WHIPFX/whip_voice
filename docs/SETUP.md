# Setting up whip_voice

whip_voice is WHIP's voice: voices through rooms, doorways and windows, full call and radio sounds, calls and radio
a modified game cannot listen in on, and lore characters phoning players (the voice bot). It brings its own voice
server (LiveKit) and runs it on the same machine as your FiveM server, so there is nothing to install: one line in
server.cfg and the voice ports open, and it works.

## What you need

- **FXServer on Windows or Linux** (64-bit), on a machine whose ports you can open: a VPS, a dedicated server, or
  your own PC. Rented FiveM hosting with only a control panel works if your host lets you open the voice ports (some
  sell extra ports); if it can't, use [a voice server of your own](#your-own-voice-server) somewhere else.
- **This line in server.cfg**, above `ensure whip_voice` (WHIP's txAdmin recipe writes it for you):

  ```
  add_unsafe_child_process_permission whip_voice
  ```

  FXServer lets a resource start a program only with this line, and the voice server is a program. ("Unsafe" is
  FXServer's word for any resource allowed to. whip_voice starts the voice server and the voice bot, and Windows' own
  `tar` and PowerShell to unpack them and read the firewall: nothing else.) Without it the console says so, with the
  line to add.
- **The voice ports open, inbound** (below). Players' games send their voices to them, as they join through 30120.

Nothing else: no domain name, no certificate, no service to install, no keys to copy. The signalling (who joins,
who hears whom) goes through your FiveM server's own connection with each player; only the voices themselves go to
the voice ports.

## Opening the voice ports

```
UDP 7882 to 7893   voices
TCP 7881           voices, when a player's network blocks UDP
```

- **Windows Firewall.** The first time the voice server starts, Windows may ask whether to let `livekit-server.exe`
  through: click **Allow** (on a server, tick **Public** networks too). Or double-click
  **`whip_voice\service\Open voice ports.bat`**: it asks for administrator rights and opens the ports. On a server
  nobody is logged into, that is the way, as no box comes up there. If someone clicked **Cancel**, Windows blocks the
  voice server whatever the ports say: `Open voice ports.bat` takes the block away too. When the FiveM server itself
  runs as administrator, whip_voice opens the ports at start by itself. Nothing to restart either way.
- **Your host's firewall.** Some hosts have one of their own, in their website's control panel: OVH (the IP's
  *Firewall*, only if you switched it on), Hetzner Cloud (*Firewalls*), AWS (*Security groups*), Azure (*Networking
  > Inbound port rules*), Google Cloud (*VPC network > Firewall*). Allow the ports there as you did 30120. No
  firewall in your panel? Nothing to do.
- **At home, behind a router:** forward them to this machine, as you did 30120.
- **Linux** with ufw: `ufw allow 7882:7893/udp` and `ufw allow 7881/tcp`.

## The first start

whip_voice downloads the voice server (LiveKit, about 20 MB) into `whip_voice\bin` and checks it is the genuine file
(its published checksum). Then it starts it, with new random keys every time (they are never written to disk), and
opens the voice room. The console says each step:

```
[whip_voice] built-in voice server: downloading LiveKit 1.13.7, the voice server (once, about 20 MB)...
[whip_voice] built-in voice server: LiveKit 1.13.7 is running. Players' games send voices to UDP 7882-7893 ...
[whip_voice] voice room whipvoice-6fd35ef1 open
[whip_voice] voice bot: running (lore characters can phone players)
```

The voice bot comes in the background: its own copy of Node.js and its packages (about 100 MB in all, also checked),
then it starts. Voice works meanwhile. The voice server and the bot start and stop with the FiveM server; one that
stops by itself is started again.

Later starts download nothing. Updating whip_voice by replacing its folder takes `bin` with it, so the next start
downloads them again. `whip_voice\bin\logs` keeps the voice server's and the bot's logs.

The first time each player joins, FiveM asks them to allow the microphone. Its box takes the mouse only with the
**F8 console** open: they press F8, click **Allow**, and close F8. Until they do, they hear everyone but can't talk;
after 15 seconds whip_voice tells them how, and `/voicecheck` lists them as "can hear but not talk".

## Checking it

An admin types **`/voicecheck`** in game (developer mode on), or `voicecheck` in the server console (txAdmin's Live
Console). It checks the voice server, Windows Firewall, and asks every player's game how it connected: over UDP is
right; everyone over TCP means UDP is shut somewhere; nobody connected means the ports are. `voicestatus` in the
console shows who is connected and what each player picks up.

## Settings

All optional, in server.cfg (with plain `set`), before `ensure whip_voice`:

| Setting | What it is | Default |
|---|---|---|
| `whip_voice_udp` | the UDP ports for voices: one (`7882`) or a range | `7882-7893` |
| `whip_voice_tcp` | the TCP port for players whose network blocks UDP | `7881` |
| `whip_voice_ip` | the public IPv4 players' games send voices to | found by asking the internet |
| `whip_voice_api` | where the voice server listens for this FiveM server, on this machine only | `http://127.0.0.1:7880` |
| `whip_voice_bot` | `false`: no voice bot (lore characters can't phone players) | on |
| `whip_voicebot_url` | where the voice bot listens, on this machine only | `http://127.0.0.1:7899` |

The voice bot's own settings (how many calls at once, which sites recordings may come from, how long and big they may
be) are in `whip_voice\config.lua`, `Config.VoiceBot`.

**Two FiveM servers on one machine** (a Legacy one and an Enhanced one, say) each run a voice server of their own,
so the second needs other ports, open as well:

```
set whip_voice_udp    "7982-7993"
set whip_voice_tcp    "7981"
set whip_voice_api    "http://127.0.0.1:7980"
set whip_voicebot_url "http://127.0.0.1:7999"
```

Changed the ports? Open those instead: `"Open voice ports.bat" -Udp 7982-7993 -Tcp 7981` from a command prompt in
`whip_voice\service`.

## What the problems mean

| It says | What it means | What to do |
|---|---|---|
| FXServer lets a resource start programs only when server.cfg allows it | server.cfg has no `add_unsafe_child_process_permission whip_voice` | Add the line above `ensure whip_voice`, and restart the server |
| Windows Firewall BLOCKS the voice server | Someone clicked Cancel when Windows asked about `livekit-server.exe` | Double-click `whip_voice\service\Open voice ports.bat` |
| Windows Firewall: the voice ports are not open yet / does not let voices in | No rule lets them in yet | Click Allow when Windows asks, or double-click `Open voice ports.bat` |
| all players connect over TCP | UDP 7882-7893 isn't getting through | Allow UDP 7882-7893 inbound in your host's firewall (and Windows Firewall, above) |
| (everyone) is not connected to voice | The voice ports are shut | Open UDP 7882-7893 and TCP 7881, in Windows Firewall and your host's |
| some players connect over TCP | Their own network blocks UDP | Nothing on your side; voice works but may stutter for them |
| something already answers on 127.0.0.1:7880 | Another program holds the port: another FiveM server's whip_voice on this machine, say | Give this one other ports (Settings), or stop that program |
| ... does not match its published checksum / answered 403 / could not unpack | The download was cut off or changed on the way, or this machine can't reach github.com | Restart whip_voice to try again; the machine needs HTTPS to github.com (and nodejs.org and registry.npmjs.org, for the bot) |
| the voice server stopped five times in a row | It can't run: often a port another program holds | `whip_voice\bin\logs\livekit.log` says why; free the port or change it (Settings) |
| the voice bot: its packages could not be installed | This machine can't reach registry.npmjs.org | `whip_voice\bin\logs\voicebot-install.log` says why; restart whip_voice to try again |
| *name* is the voice system, so whip_voice is off | Another voice resource started first, and only one can run | Take its `ensure` out of server.cfg and restart the server |
| FiveM's own voice (Mumble) is on | Legacy's built-in voice runs, and players talk on it (same N key) until whip_voice connects them | Add `set mumble_disableServer true` to server.cfg (WHIP's Legacy recipe writes it) and restart the server |
| can hear but not talk | That player's game has no microphone: FiveM's box unanswered, or refused | They open F8 and click Allow in the box; refused earlier, they allow it in FiveM's settings and reconnect |
| A Phone Call card: "only links starting with ... are accepted" | The recording is not on Fivemanage | Put the file in a resource and use `@resource/file.ogg` (below), upload it to Fivemanage, or add the site to `Config.VoiceBot.audioLinks` |
| A Phone Call card: "there is no ..." / "cannot be read" | The `@resource/...` file is not where it says | Check the path inside the resource |
| A Phone Call card: "not a recording this can read" | The recording is not mp3, ogg (Vorbis or Opus) or wav: an m4a or FLAC file, say | Save it as ogg or mp3 and use that |

**Recordings in a resource** (a story you sell or share, say): put the mp3/ogg/wav files in the resource, like
`my_story/audio/irwin_intro.ogg`, and name them `@my_story/audio/irwin_intro.ogg` in a Phone Call card (or
`/lorecall @my_story/audio/irwin_intro.ogg` to try one). Don't list them in `files {}`: the voice bot reads them on
the server, so players never download them. Up to 2 minutes and 15 MB each (`Config.VoiceBot`).

## FiveM for GTAV Enhanced

whip_voice works the same, with these differences:

- FiveM's own voice there is new, and off unless server.cfg turns it on (`voice_internal`, or `voice_external_connect`
  for a separate voice server). Leave both out: only one voice system. `/voicecheck` can't see them, and
  `mumble_disableServer`, which turns Legacy's off, does nothing here.
- FiveM's microphone box works as on Legacy: it takes the mouse only with the **F8 console** open (above).

## Your own voice server

Instead of the built-in one: LiveKit Cloud, or LiveKit on a machine of its own (for rented hosting that can't open
the voice ports, say). With `whip_voice_url` in server.cfg, whip_voice connects players there and the built-in voice
server stays off (no `add_unsafe_child_process_permission` line needed). Players' games then connect to it directly,
so it needs a secure address: `wss://` with a valid certificate. LiveKit Cloud has one; for a LiveKit of your own,
follow LiveKit's self-hosting guide (docs.livekit.io).

These lines in server.cfg, with plain `set` (never `setr`: it would send the secret to every player):

```
set whip_voice_url    "wss://your-project.livekit.cloud"
set whip_voice_key    "API..."
set whip_voice_secret "..."
set whip_voice_api    "https://your-project.livekit.cloud"     (where this FiveM server reaches its API)
```

Restart the FiveM server, then run `/voicecheck`.

### The voice bot

The voice bot plays a lore character's recorded line into a call (the Director's **Phone Call** card). With your own
voice server it is yours to run, on the FiveM server's machine (it reads `@resource/...` recordings from there).
Without it, voice works and lore characters can't phone.

1. Install Node.js 22 (nodejs.org). Copy `whip_voice\service\voicebot` to a folder of its own and run
   `npm ci --omit=dev` in it.
2. Beside `bot.mjs`, make `config.json` with a random token of 24 characters or more:

   ```json
   { "listen": "127.0.0.1:7899", "token": "<random letters and digits>" }
   ```

   Optional: `maxCalls` (30), `audioLinks` (`["https://r2.fivemanage.com/"]`: the sites recordings may come from;
   only sites you trust), `maxSeconds` (120) and `maxBytes` (15 MB).
3. Start it with `node bot.mjs` and keep it running (as a Windows service with NSSM, or with systemd on Linux).
4. In server.cfg, with plain `set`: `set whip_voicebot_token "<the same token>"`, and `whip_voicebot_url` if it
   listens somewhere other than `http://127.0.0.1:7899`.

### What the problems mean

The ports, players and Phone Call rows [above](#what-the-problems-mean) apply here too, for your voice server's ports.

| It says | What it means | What to do |
|---|---|---|
| the voice server is not answering / did not answer | `whip_voice_api` is wrong, or the voice server is down | Check `whip_voice_api` and that the voice server runs |
| `https://...` cannot be reached / is not the voice server | `whip_voice_url` has no valid certificate, or its HTTPS site doesn't pass it to LiveKit | Fix the address or its certificate; the HTTPS site passes everything to LiveKit's port 7880, with WebSockets on |
| refused our key | `whip_voice_key` / `whip_voice_secret` aren't one of the voice server's key pairs | Copy them again from the voice server, then restart |
| players can read whip_voice_secret | server.cfg sets it with `setr` (or `sets`), which sends it to everyone | Change it to plain `set`, make a new key and secret on the voice server, put them in server.cfg, restart |
| no voice bot answers | No voice bot runs | Set one up (above), if you want lore characters to phone |
| the voice bot refused whip_voicebot_token / has no whip_voicebot_token line | server.cfg and the bot's `config.json` have different tokens | Make `whip_voicebot_token` the token in `config.json`, then restart |

**Never share** the `whip_voice_secret` and `whip_voicebot_token` lines, or the bot's `config.json`: with them,
anyone can use your voice server.
