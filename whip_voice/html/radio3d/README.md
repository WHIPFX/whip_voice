# 3D handheld radio for the radio UI (2026-10-05)

An enhanced version of GTA's `prop_cs_hand_radio`, rebuilt as a high-quality 3D model with a working segment LCD
and working controls. It is a self-contained web module: drop `html/` into a NUI page, size a `<canvas>` with CSS
(bottom-right in game) and drive it with the API below. Not hooked to FiveM or the framework yet.

- `html/bench.html`: the test bench (mock in-game view + a panel that plays the game). Serve the folder and open it:
  `python -m http.server 8777` in `html/`, then http://127.0.0.1:8777/bench.html (modules don't load from `file://`).
- `html/radio_nui.html`: minimal NUI host page with an **example** message bridge (adapt the names to the framework).
- `html/radio.js` (`RadioUI`), `html/lcd.js` (LCD renderer), `html/radio.glb` (model, 409 KB, 13.9k triangles),
  `html/lib/` (three.js r170, vendored so NUI needs no internet).

## Controls (on the model)

| Part | Does |
|---|---|
| Volume knob (top right) | click: power on / off · drag or scroll: volume 0-10 (right / up = louder). While the radio is off, the power symbol under it pulses green with a halo and the tooltip reads "Power on (click)"; while on, the symbol is backlit like the keys |
| Channel knob (top middle) | click: next channel · drag or scroll: channel (right / up = higher) |
| Printed marks under the knobs | `▼ CH ▲` and `− ⏻ 🔈 +` (minus, power, speaker, plus) with a two-way arrow: what each dial does and which way is up. Part of the knob's hit area (hover, click, drag and scroll act on the knob) |
| Sides (pose) | the radio faces you flat. Move the pointer past its left, right or top edge and that side turns toward you (pivoting on that edge, so the side opens under the pointer); move back and it turns flat. The pose holds while a control is held or dragged |
| Side bar (left) | hold: push to talk (TX) |
| Button below it (☀) | backlight boost for 8 s |
| ▲ / ▼ CH keys | channel up / down |
| Digits, then # ENT | jump to a channel (e.g. 4 2 0 #) · ✱ CLR clears |
| MENU | key beeps on / off |
| Speaker button (top left, grey, printed `🔊 SPK` under it) | speaker on / off: nearby players hear the radio, like a phone on speaker; it is not louder for you. While on, the button glows green and `SPK` shows on the LCD; toggling flashes `SPK ON` / `SPKOFF`. The printed label is part of its hit area |

When off, the LCD is dimmed and the keys do nothing (a dull click). Power-on runs an all-segments test, shows the
boot logo (`WHIP`, option `bootLogo`), then the channel. The top LED is red while transmitting, green while
receiving. Key beeps, power chirps and the roger beep come from WebAudio after the first click.

## API

```js
import { RadioUI } from './radio.js';
const radio = new RadioUI(canvas, { modelUrl: './radio.glb' });
await radio.init();
```

Options (all optional): `modelUrl` (`.glb`, or a `.json` holding the GLB as base64 for hosts that won't serve .glb; see
`glb_to_b64json.py`), `minChannel` (100), `maxChannel` (999), `channel` (100), `volume` (6), `power` (false),
`channelNames` ({}), `frequency` (ch => string; default: the channel is the frequency, 420 → `420.000`, shown with
MHz on the LCD), `sounds` (true), `keyboard` (false, bench shortcuts), `idle` (true, gentle sway), `layout`
('corner' | 'inspect'), `look` (true: the side turns above), `powerHint` (true: the pulsing power symbol), `blit` ('auto'),
`pixelRatio`, `bootLogo` ('WHIP').

Game → radio:

| Call | Effect |
|---|---|
| `setPower(on, {silent, instant})` / `togglePower()` | power; `instant` skips the boot animation |
| `setChannel(n, {silent})` / `channelUp()` / `channelDown()` | channel (wraps in the range) |
| `setVolume(v, {silent})` | 0-10 |
| `setChannelNames({100: 'POLICE', ...})` | names shown instead of `CH-100` (6 characters max on the LCD) |
| `setChannelRange(min, max)` | channel range |
| `setReceiving(on, name)` | RX icon + green LED; `name` (up to 10 chars) shows on the bottom line, e.g. the caller |
| `setTransmitting(on, {silent})` | TX from a game keybind; `silent` = no `ptt` event echoed back |
| `setSignal(0-4)` / `setBattery(0-4)` | LCD icons |
| `setLight(on, {silent})` | backlight boost (8 s) |
| `setSpeaker(on, {silent})` | speaker mode (nearby players hear the radio); `silent` = no event, sound or LCD message (state restore) |
| `open()` / `close()` | slide in / out (promise); nothing is drawn while closed |
| `setLayout('corner' or 'inspect')` | in-game framing or orbit view |
| `getState()` | `{ power, channel, channelName, frequency, volume, tx, rx, rxName, signal, battery, light, speaker, beeps, entry }` |
| `partScreenPosition(name)` | client-px centre of a part (tooltips, tests) |
| `dispose()` | remove listeners, free WebGL |

Radio → game: `RadioUI` is an `EventTarget`; `e.detail` carries the data.

| Event | detail |
|---|---|
| `power` | `{ on }` |
| `channel` | `{ channel, name, frequency }` |
| `volume` | `{ volume }` |
| `ptt` | `{ active, channel }` (press and release of the side bar) |
| `speaker` | `{ on, channel }` (from the top button: while `on`, the framework plays this radio's audio to nearby players; the owner's volume is unchanged) |
| `light` | `{ on }` |
| `setting` | `{ beeps }` |
| `key` | `{ key, ignored? }` (every key press, `ignored` when the radio is off) |
| `hover` | `{ part, label }` (for a tooltip) |
| `change` | the full state after any user change |
| `ready` | state once loaded |

## Notes for the NUI integration

- **Transparent WebGL in FiveM's browser** accumulates alpha (open issue citizenfx/fivem#3707). Inside NUI the module
  renders off-screen and copies each frame to a 2D canvas (`blit: 'auto'`), which composes correctly; `blit: false`
  forces direct WebGL. Untested in game so far: check this first.
- Size and place the canvas with CSS only; the module follows it (ResizeObserver). In the corner layout the canvas
  bottom edge sits 1 cm under the last key row and the speaker grille runs off it, as if held up from below; keep the
  canvas flush with the screen bottom. Leave some canvas width either side of the radio (the bench uses aspect 0.58):
  the side turns swing the sides out there.
- The side turns follow the pointer anywhere on the page (a `pointermove` listener on `window`), measured against
  the radio's flat pose so a turn never chases the pointer. Far from the radio it stays flat. `look: false` turns it off.
- Rendering is on demand (only while something changes) plus a 30 fps idle sway; `idle: false` stops the sway.
  `close()` stops drawing entirely.
- Mouse input needs NUI focus (`SetNuiFocus(true, true)`) while the radio is open. Pointer events, touch and the
  scroll wheel are handled on the canvas; `body:not(.open) #radio { pointer-events: none }` in `radio_nui.html` lets
  clicks through while it is closed.
- Set `sounds: false` if the framework plays its own radio sounds.
- The model's embedded textures are decoded from memory (`createImageBitmap`), never through `blob:`/`data:` URLs, so
  the module also runs on pages with a strict Content-Security-Policy (the browser preview has one).

## Model

`radio.glb`: Y up, metres, body 6.2 × 3.6 × 15 cm, origin at the body centre, front facing +Z. Interactive parts are
separate nodes with glTF extras `role` (`key` / `knob` / `button`) and `action`: `key_0`-`key_9`, `key_up`,
`key_down`, `key_menu`, `key_star`, `key_hash`, `knob_volume`, `knob_channel`, `btn_ptt`, `btn_side`, `btn_speaker` (action `speaker`, was the emergency button);
plus `screen` (LCD plane, UV 0-1), `screen_glass`, `led`. Key labels: one atlas texture with a glow map (keypad
backlight). `knob_channel_label` / `knob_volume_label` / `btn_speaker_label` (role `label`): the printed marks on the rounded top-front
edge (alpha-blended decal strips; the power symbol is a smoked window lit by the mark's emissive map, and the volume mark's
extras `power_mm` / `atlas_mm` place the halo). Rising values turn a knob's front face to the right, toward the `+` / `▲` end of its mark.

Source (rebuild): `E:\GTA V Prop Modifications\work\radio_ui`
- `make_key_atlas.py` (key labels), `make_dial_marks.py` (dial marks + power-symbol glow) → `radio_build.py` in Blender 5.1
  via MCP: `build(); export_glb(); preview()`.
- `web/` (module + bench, the source of truth), then `sync_web.py [preview_dir]` copies it here (bench.html with the
  vendored three.js, radio.js, lcd.js, radio.glb) and optionally into a browser-preview folder (radio.json).
- `cdp_test.py [web] [quick|top]` (headless Chrome test with real input, aiming like a person; run it with
  tools\pyenv's python).
- `glb_to_b64json.py` (copy next to this README): GLB → `{"glb": base64}` JSON, the form the browser preview loads
  (`python glb_to_b64json.py radio.glb radio.json`, then `modelUrl: './radio.json'`).
