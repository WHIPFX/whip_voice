# whip_voice: licence notice

Copyright (c) 2026 Whippy

whip_voice is part of WHIP. Its code is licensed under the GNU Lesser General Public License 3.0 (`COPYING.LESSER`),
with the GPL 3.0 it builds on in `COPYING`. The licence covers WHIP's own code: not the WHIP name and logo, not the
Rockstar Games material (the game's names, data and files), and not the third-party parts, which keep their own
licences.

Third-party parts in this resource:

- three.js (threejs.org) with its GLTFLoader, OrbitControls, RoomEnvironment and BufferGeometryUtils, in
  `html/radio3d/lib/`, MIT: `html/radio3d/lib/LICENSE`.
- The LiveKit JavaScript client 2.22.3 (`html/js/vendor/livekit-client.umd.js`), Apache 2.0:
  `html/js/vendor/livekit-client.LICENSE.txt`, with the notices of everything built into it in
  `html/js/vendor/livekit-client.NOTICE.txt`.
- Downloaded when the server first starts, not shipped here: the LiveKit server (Apache 2.0) and Node.js (MIT, with
  the licences of its own parts in its download).
- Installed by the setup wizard, not shipped here: the voice bot's npm packages (`service/voicebot/package-lock.json`),
  each under its own licence: MIT, Apache 2.0, BSD, ISC, and the LGPL 3.0 for codec-parser. The MP3 decoder's
  mpg123-decoder says MIT, but it is built from mpg123, which is under the LGPL 2.1.

whip_core's `NOTICE.md` is the full notice for WHIP: the WHIP name and logo, the Rockstar Games material, and every
third-party part, each with its licence.
