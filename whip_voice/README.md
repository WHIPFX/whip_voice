# whip_voice

whip's voice: players talk in 3D, muffled through walls and heard from the doorway or window between them, with
phone calls, the radio and the megaphone on the same voice. It runs on a voice server of its own (LiveKit), so calls
and the radio are private.

- **Needs:** whip_core, and a voice server on your Windows server machine. This is the one whip resource that is not
  drop-in: one double-click on its setup wizard installs the voice server and writes the lines server.cfg needs, with
  nothing to answer and no domain name needed. About 10 minutes.
- **Setting up:** [docs/SETUP.md](docs/SETUP.md), step by step.
- **Checking it:** `/voicecheck` (an admin in developer mode, or the server console) says what is wrong and how to
  fix it. whip's setup report says which voice system is running.
