# whip_voice

WHIP's voice: players talk in 3D, muffled through walls and heard from the doorway or window between them, with
phone calls, the radio and the megaphone on the same voice. It runs on a voice server of its own (LiveKit), so calls
and the radio are private.

- **Needs:** whip_core. The voice server is built in: whip_voice downloads it on its first start and runs it on the
  same machine as your FiveM server, with no domain name, certificate or keys to set up. Two things to do (WHIP's
  txAdmin recipe does the first): `add_unsafe_child_process_permission whip_voice` in server.cfg, above
  `ensure whip_voice`, and the voice ports open inbound, UDP 7882-7893 and TCP 7881, as you did 30120
  (`service\Open voice ports.bat` for Windows Firewall).
- **Your own voice server** instead (another machine, a domain name, LiveKit Cloud): `whip_voice_url` in server.cfg;
  on Windows, `service\Setup voice server.bat` sets one up.
- **Setting up:** [docs/SETUP.md](docs/SETUP.md), step by step.
- **Checking it:** `/voicecheck` (an admin in developer mode, or the server console) says what is wrong and how to
  fix it. WHIP's setup report says which voice system is running.
