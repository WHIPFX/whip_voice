# Setting up whip_voice

whip_voice is whip's voice: voices through rooms, doorways and windows, full call and radio sounds, calls and radio
a modified game cannot listen in on, and lore characters phoning players (with the voice bot, a step in the
wizard). Setting it up is one double-click: the wizard runs start to finish by itself, in about 10 minutes.

## What you need

**A Windows server you can log into as an administrator.** A VPS or a dedicated server (OVH, Hetzner, Contabo, ...)
running Windows. Rented FiveM hosting that only gives you a control panel can't run it: the voice server is its own
program that has to be installed on the machine.

That's all. Players' games connect to your server's own address, with a free certificate for that address that the
wizard sets up, so you need no domain name. The wizard downloads and sets up everything else (the voice server,
LiveKit, and the HTTPS front door, Caddy), and checks every download is the genuine file.

## The setup, step by step

1. On the server machine, open your resources folder, then `whip_voice\service` (inside `[whip]` if whip is there).
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
   and the voice bot's token, and they go before the line that starts whip_voice (`ensure [whip]` or
   `ensure whip_voice`). Older `whip_voice_...` lines are replaced, and `setr sv_mumble true` is turned off:
   whip_voice doesn't use it, and on, any player's game can listen to any Mumble channel. When there is no
   server.cfg above `resources`, it prints the lines and puts them on your clipboard instead: paste them into your
   server.cfg after `ensure whip_core`, with `ensure whip_voice` under them.
4. **Restart your FiveM server** (txAdmin > Restart). Done.

The first time each player joins, FiveM asks them to allow the microphone. Its box takes the mouse only with the
**F8 console** open: they press F8, click **Allow**, and close F8. Until they do, they hear everyone but can't talk;
after 15 seconds whip_voice tells them how, and `/voicecheck` lists them as "can hear but not talk".

## A domain name instead

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

## Two servers, or FiveM for GTAV Enhanced

**Two FiveM servers on one machine** (a Legacy one and an Enhanced one, say) share one voice server. Run the setup
from each one's `whip_voice\service`: the second run keeps the same keys and voice server, and writes the same lines
into its own server.cfg. Each server makes a voice room of its own every time it starts, so their players never mix.

**On FiveM for GTAV Enhanced** whip_voice works the same, with these differences:

- FiveM's own voice there is new, and off unless server.cfg turns it on (`voice_internal`). Don't turn it on next
  to whip_voice: only one voice system.
- FiveM's microphone box works as on Legacy: it takes the mouse only with the **F8 console** open (below).

## Checking it

- **On the server machine:** double-click **`Check voice server.bat`**. It changes nothing. It checks the
  services, the ports, the voice address (a domain's DNS record too), the certificate and when it runs out, and
  your server.cfg, and says what to fix.
- **In game:** an admin types **`/voicecheck`** (or type `voicecheck` in txAdmin's Live Console). It checks
  from the game's side: the keys, the secure address, and asks every player's game how it connected.

## What the problems mean

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

## Later

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
