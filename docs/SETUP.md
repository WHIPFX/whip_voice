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
| something already answers on 127.0.0.1:7880 | Another voice server is there: the setup wizard's "LiveKit" service, say | Use it (keep the wizard's lines in server.cfg), uninstall it (`"Setup voice server.bat" -Uninstall`), or give the built-in one other ports (Settings) |
| ... does not match its published checksum / answered 403 / could not unpack | The download was cut off or changed on the way, or this machine can't reach github.com | Restart whip_voice to try again; the machine needs HTTPS to github.com (and nodejs.org and registry.npmjs.org, for the bot) |
| the voice server stopped five times in a row | It can't run: often a port another program holds | `whip_voice\bin\logs\livekit.log` says why; free the port or change it (Settings) |
| the voice bot: its packages could not be installed | This machine can't reach registry.npmjs.org | `whip_voice\bin\logs\voicebot-install.log` says why; restart whip_voice to try again |
| *name* is the voice system, so whip_voice is off | Another voice resource started first, and only one can run | Take its `ensure` out of server.cfg and restart the server |
| can hear but not talk | That player's game has no microphone: FiveM's box unanswered, or refused | They open F8 and click Allow in the box; refused earlier, they allow it in FiveM's settings and reconnect |
| A Phone Call card: "only links starting with ... are accepted" | The recording is not on Fivemanage | Put the file in a resource and use `@resource/file.ogg` (below), upload it to Fivemanage, or add the site to `Config.VoiceBot.audioLinks` |
| A Phone Call card: "there is no ..." / "cannot be read" | The `@resource/...` file is not where it says | Check the path inside the resource |

**Recordings in a resource** (a story you sell or share, say): put the mp3/ogg/wav files in the resource, like
`my_story/audio/irwin_intro.ogg`, and name them `@my_story/audio/irwin_intro.ogg` in a Phone Call card (or
`/lorecall @my_story/audio/irwin_intro.ogg` to try one). Don't list them in `files {}`: the voice bot reads them on
the server, so players never download them. Up to 2 minutes and 15 MB each (`Config.VoiceBot`).

## FiveM for GTAV Enhanced

whip_voice works the same, with these differences:

- FiveM's own voice there is new, and off unless server.cfg turns it on (`voice_internal`). Don't turn it on next
  to whip_voice: only one voice system.
- FiveM's microphone box works as on Legacy: it takes the mouse only with the **F8 console** open (above).

## Your own voice server

Instead of the built-in one: a voice server on another machine, players connecting to a domain name, LiveKit Cloud,
or rented hosting that can't open the voice ports. With `whip_voice_url` in server.cfg, whip_voice connects players
there and the built-in voice server stays off (no `add_unsafe_child_process_permission` line needed). Players' games
then connect to it directly, so it needs a secure address: `wss://` with a valid certificate.

**Any LiveKit server** (LiveKit Cloud, or one you run yourself): these lines in server.cfg, with plain `set` (never
`setr`: it would send the secret to every player):

```
set whip_voice_url    "wss://your-project.livekit.cloud"
set whip_voice_key    "API..."
set whip_voice_secret "..."
set whip_voice_api    "https://your-project.livekit.cloud"     (where this FiveM server reaches its API)
```

The voice bot is then yours to run too (`service\voicebot`, with `whip_voicebot_url` and `whip_voicebot_token`).

**On a Windows server of your own, the setup wizard** sets up LiveKit, an HTTPS front door (Caddy) with a free
certificate for your server's address, and the voice bot, as Windows services, and writes the lines into server.cfg.
It takes one double-click and about 10 minutes:

### What you need

**A Windows server you can log into as an administrator.** A VPS or a dedicated server (OVH, Hetzner, Contabo, ...)
running Windows. Rented FiveM hosting that only gives you a control panel can't run it: the voice server is its own
program that has to be installed on the machine.

That's all. Players' games connect to your server's own address, with a free certificate for that address that the
wizard sets up, so you need no domain name. The wizard downloads and sets up everything else: the voice server
(LiveKit), the HTTPS front door (Caddy), NSSM (which runs them as Windows services), and Node.js and the packages
for the voice bot. It checks each download against a checksum written into whip_voice, and uses none that doesn't
match.

### The setup, step by step

1. On the server machine, open your resources folder, then `whip_voice\service` (inside a `[whip]` folder if your resources have one).
2. Double-click **`Setup voice server.bat`**. Windows asks whether to let it make changes: say **Yes**.
3. Let it run. There is nothing to answer; it says what it does at each step:

   **The voice address.** It works out your server's public address and makes that the voice address:
   `wss://` and the address. Players' games connect to it directly.

   **Your host's firewall.** Some hosts have a firewall of their own, in their website's control panel. If
   yours does, allow these **inbound** there (the wizard opens Windows' own firewall by itself):

   ```
   TCP 80 and 443     the secure address, and getting and renewing its certificate
   TCP 7881           voice (the fallback)
   UDP 7882 to 7893   voice
   ```

   Where to find it: OVH (the IP's *Firewall*, only if you switched it on), Hetzner Cloud (*Firewalls*),
   AWS (*Security groups*), Azure (*Networking > Inbound port rules*), Google Cloud (*VPC network >
   Firewall*). No firewall in your panel? Nothing to do. The wizard does not wait here: if a port is still shut,
   the check at the end says so, and the certificate comes as soon as it is open.

   **Caddy and LiveKit.** The wizard installs them as Windows services that start with Windows, and opens
   their ports in the Windows firewall. If your machine already runs Caddy, it adds your voice address to it. If
   it already runs this version of LiveKit, nothing is downloaded. Caddy gets the certificate for your server's
   address from Let's Encrypt. It lasts about 6 days, and Caddy renews it by itself every few days, for as long as
   ports 80 and 443 stay open.

   **The voice bot.** It lets a lore character phone a player and play a recorded line into the call (the
   Director's **Phone Call** card). The wizard sets it up: its own copy of Node.js (checked like every download)
   in `C:\LiveKit\voicebot`, and a Windows service, "whip_voice voice bot". It listens on this machine only, so no
   ports are opened. One bot plays for every lore character, up to 30 calls at once.

   Run again, the wizard leaves alone whatever is already installed and the same, and only restarts a service
   when something about it changed (a restart drops voice for a few seconds).

   **The check.** It waits for the certificate, then checks every piece and tells you what is right.

   **server.cfg.** It writes whip_voice's lines into the server.cfg of your server (the one in the folder above
   `resources`) and keeps the old file beside it as a backup. The lines are the voice address, the key, the secret
   and the voice bot's token, and they go before the line that starts whip_voice (`ensure whip_voice`, or
   the `ensure` of a folder it is in). Older `whip_voice_...` lines are replaced, and `setr sv_mumble true` is turned off:
   whip_voice doesn't use it, and on, any player's game can listen to any Mumble channel. When there is no
   server.cfg above `resources`, it prints the lines and puts them on your clipboard instead: paste them into your
   server.cfg after `ensure whip_core`, with `ensure whip_voice` under them.
4. **Restart your FiveM server** (txAdmin > Restart). Done.

### A domain name instead

Players can connect to a name, like `voice.myserver.com`, instead of your server's address. You need a domain you
own (about $10 a year, from GoDaddy, Namecheap, Cloudflare, ...). Its certificate lasts about 3 months rather than 6
days, and the voice address stays the same if your server ever moves to a new address.

1. In `whip_voice\service`, click the folder's address bar, type `cmd` and press Enter. In the black window, type
   `"Setup voice server.bat" -Domain voice.myserver.com` (your own domain) and press Enter.
2. The wizard shows you a DNS record to add where you bought your domain, then waits until it works (usually a few
   minutes) and carries on by itself:

   ```
   Type:  A
   Name:  voice
   Value: 203.0.113.10        (your server's address: the wizard works it out)
   ```

   - **GoDaddy:** My Products > your domain > DNS > Add New Record.
   - **Namecheap:** Domain List > Manage > Advanced DNS > Add New Record (A Record; Host = `voice`).
   - **Cloudflare:** DNS > Records > Add record. **Click the orange cloud so it turns grey ("DNS only").**
     Cloudflare's proxy can't carry voice.
3. The rest is the same as above, and it updates server.cfg with the new voice address. Restart your FiveM server.

Once a domain is set up, running the setup again keeps it. To go back to your server's address, run
`"Setup voice server.bat" -UseIp` the same way.

### Two FiveM servers on one machine

Two FiveM servers on one machine (a Legacy one and an Enhanced one, say) share one voice server. Run the setup
from each one's `whip_voice\service`: the second run keeps the same keys and voice server, and writes the same lines
into its own server.cfg. Each server makes a voice room of its own every time it starts, so their players never mix.

### Checking it

- **On the server machine:** double-click **`Check voice server.bat`**. It changes nothing. It checks the
  services, the ports, the voice address (a domain's DNS record too), the certificate and when it runs out, and
  your server.cfg, and says what to fix.
- **In game:** an admin types **`/voicecheck`** (or type `voicecheck` in txAdmin's Live Console). It checks
  from the game's side: the keys, the secure address, and asks every player's game how it connected.

### What the problems mean

| It says | What it means | What to do |
|---|---|---|
| the voice address is ..., but the internet sees this server as ... | Your server's address changed (a new server, or your host gave it a new address) | Run the setup again: it moves the voice address and updates server.cfg. Then restart the FiveM server |
| `https://...` does not answer properly | Usually no certificate yet: ports 80/443 are closed in your host's firewall (or, for a domain, its DNS record isn't ready) | Open TCP 80 and 443 in your host's panel (or fix the DNS), then run the check again |
| the certificate runs out in ... hour(s) and Caddy has not renewed it | Caddy can't renew it, usually because ports 80/443 are closed in your host's firewall. When it runs out, players can't connect to voice | Open TCP 80 and 443; Caddy's log (`C:\Caddy\logs\caddy.log`) says why |
| this Caddy is ...; certificates for an IP address are known to work from ... | The Caddy already on your machine is older | If the check finds no certificate, update Caddy (caddyserver.com) and run the setup again |
| (a domain) does not exist on the internet yet / points at another address | The DNS record is missing, wrong, or still on its way | Add or fix the A record; wait a few minutes; check again |
| (a domain) goes through Cloudflare's proxy | The record has the orange cloud | In Cloudflare, click it so it is grey ("DNS only") |
| TCP 80 / 443 is held by another program | Another web server (IIS, Apache, nginx) is using the ports Caddy needs | Stop it, or keep it and run the setup with `-SkipCaddy` (then point that web server's HTTPS at `127.0.0.1:7880`, with WebSockets on) |
| all players connect over TCP | UDP 7882-7893 isn't getting through | Allow UDP 7882-7893 inbound in your host's firewall |
| some players connect over TCP | Their own network blocks UDP | Nothing on your side; voice works but may stutter for them |
| players can read whip_voice_secret | server.cfg sets it with `setr` (or `sets`), which sends it to everyone | Run the setup with `-NewKeys` (it writes new lines, with plain `set`, into server.cfg), then restart |
| the key does not match / refused our key | server.cfg and the voice server have different keys | Run the setup again: it writes the right lines into server.cfg. Then restart |
| *name* is the voice system, so whip_voice is off | Another voice resource started first, and only one can run | Take its `ensure` out of server.cfg and restart the server |
| the LiveKit / caddy service is stopped | A service didn't start | Services (Win+R, `services.msc`) > "LiveKit voice server" or "caddy" > Start; the setup again if it won't |
| can hear but not talk | That player's game has no microphone: FiveM's box unanswered, or refused | They open F8 and click Allow in the box; refused earlier, they allow it in FiveM's settings and reconnect |
| sv_mumble is on | FiveM's own Mumble voice is switched on: whip_voice doesn't use it, and on, any player's game can listen to any Mumble channel | Put `#` in front of it |
| the voice bot is not installed | An older setup ran, or its step failed (the setup said why) | Run the setup again (it writes the bot's `whip_voicebot_token` line into server.cfg) |
| the voice bot service did not answer / is stopped | Its service didn't start | Services > "whip_voice voice bot" > Start; its log is `C:\LiveKit\voicebot\logs\voicebot.log` |
| the voice bot refused whip_voicebot_token | server.cfg and the bot have different tokens | Run the setup again: it writes the bot's line into server.cfg |
| the voice bot is running, but this server.cfg has no whip_voicebot_token line | The bot is set up; this server.cfg never got its line | Run the setup from this server's `whip_voice\service`: it writes the line into its server.cfg |
| A Phone Call card: "only links starting with ... are accepted" | The recording is not on Fivemanage | Put the file in a resource and use `@resource/file.ogg` (below), upload it to Fivemanage, or add the other site (below) |
| A Phone Call card: "there is no ..." / "cannot be read" | The `@resource/...` file is not where it says, or Windows will not let the bot read it | Check the path inside the resource; the resources folder must be readable by "Users" (it is by default) |

### Later

- **Run the setup again** whenever you like: it keeps your keys and skips what is already done. Run it when your
  server's address changes: the voice address moves with it, and server.cfg is updated.
- **New keys** (if your secret was ever seen, pasted or shared): run `"Setup voice server.bat" -NewKeys` (as for a
  domain, above), then restart the FiveM server. It writes the new lines into server.cfg, and makes the voice bot a
  new token too. A second server on the machine: run it from that one's `whip_voice\service` as well, without
  `-NewKeys`.
- **Recordings in a resource** (a story you sell or share, say): put the mp3/ogg/wav files in the resource, like
  `my_story/audio/irwin_intro.ogg`, and name them `@my_story/audio/irwin_intro.ogg` in a Phone Call card (or
  `/lorecall @my_story/audio/irwin_intro.ogg` to try one). Don't list them in `files {}`: the voice bot reads them on
  the server, so players never download them. Up to 2 minutes and 15 MB each.
- **Recordings from another site** than Fivemanage: open `C:\LiveKit\voicebot\config.json` (as administrator) and
  add the site's start to `audioLinks`, like `"https://cdn.example.com/"`. Then restart the "whip_voice voice bot"
  service. Only add sites you trust: the bot downloads whatever a Phone Call card links to there.
- **Uninstall:** `Setup voice server.bat -Uninstall` removes the LiveKit and voice bot services and the firewall
  rules (`C:\LiveKit` and Caddy are left for you to delete).
- **Never share** `C:\LiveKit\config.yaml`, `C:\LiveKit\voicebot\config.json`, or the `whip_voice_secret` and
  `whip_voicebot_token` lines: with them, anyone can use your voice server.
