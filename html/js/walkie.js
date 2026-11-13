// The radio on the screen: the 3D radio. Opened by using the radio item (client/walkie.lua): a 3D handheld radio
// slides up in the bottom right and the mouse (or a controller) works it. The radio itself is html/radio3d, kept as
// delivered bar the edits marked "whip". This file connects it to whip_voice:
//
//   the radio's controls ─▶ the game:  walkieSet {on, freq, power?} (power, the channel), walkieVolume {level
//                                      0-100}, walkiePtt {on} (the side bar), walkieSpeaker {on},
//                                      walkieClose (Esc, or B / Start on a pad), walkieError {detail}
//   the game ─▶ the radio:             walkieOpen {on, freq, speaker, min, max, volume 0-100, sounds, pad},
//                                      walkieState {on, freq, speaker}, walkieClose, talk {radio}
//                                      (the radio key: TX lights), walkieInput {pad} (the device changed)
//                                      and walkiePad {cmd, down, rep} (a controller's press, padPress)
//   this page's radio voices ─▶ the radio: RX and the signal bars (radio.js, 'whip:radioRx')
//
// The radio only asks: power, the channel and the speaker go to the server, which answers with the real state
// (walkieState); a refused change is put back quietly. The channel is the frequency. A run of channel changes is sent
// once, when it stops.
//
// Built when it opens: the 3D (three.js and the model) is only loaded then. Put away, it is hidden once out of
// sight, and let go of after FREE_AFTER_MS (free()).

const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'whip_voice';
const post = (name, data) => fetch('https://' + RES + '/' + name, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data || {}),
}).then((r) => r.json()).catch(() => null);

const canvas = document.getElementById('walkie');
const SEND_AFTER_MS = 300;       // the knob dragged through channels: sent once, when it stops
const FREE_AFTER_MS = 30000;     // put away this long: the 3D radio is let go of (free)
const BEEPS_KEY = 'whip_voice:radioBeeps';

let radio = null;                // the RadioUI, while built
let building = null;             // its build, while under way
let shown = false;               // open on the screen (as the game says)
let sendTimer = null;
let freeTimer = null;
let rx = { on: false, q: 0 };    // this player's radio receiving (radio.js)
let tx = false;                  // talking on the radio (the key or the bar: the game's word)
// The game's word on the radio, applied whenever the radio is built. The player's own changes that
// the server never answers (the volume, a channel picked while off) are written here as they happen.
const game = { power: false, channel: 100, speaker: false, volume: 8, min: 100, max: 999, sounds: true };

function takeGame(m) {
    if (Number(m.min) > 0) game.min = Number(m.min);
    if (Number(m.max) > 0) game.max = Number(m.max);
    if ('on' in m) game.power = m.on === true;
    if (Number(m.freq) > 0) game.channel = Math.min(game.max, Math.max(game.min, Math.round(Number(m.freq))));
    if ('speaker' in m) game.speaker = m.speaker === true;
    if (Number.isFinite(Number(m.volume))) game.volume = Math.max(0, Math.min(10, Math.round(Number(m.volume) / 10)));
    if ('sounds' in m) game.sounds = m.sounds !== false;
}

/** Show the game's word on the radio, quietly (no events back, no sounds), changing only what differs
 *  — so the boot animation, a channel being typed, or the knob being turned is never interrupted. */
function apply() {
    if (!radio) return;
    const s = radio.state;
    if (s.power !== game.power) radio.setPower(game.power, { silent: true, instant: true });
    if (!sendTimer && s.channel !== game.channel) radio.setChannel(game.channel, { silent: true });
    if (s.volume !== game.volume) radio.setVolume(game.volume, { silent: true });
    if (s.speaker !== game.speaker) radio.setSpeaker(game.speaker, { silent: true });
    showRx();
}

function showRx() {
    if (!radio) return;
    radio.setReceiving(rx.on, '');
    radio.setSignal(rx.on ? Math.max(1, Math.ceil(rx.q * 4)) : 4);
}

function sendSoon() {
    clearTimeout(sendTimer);
    sendTimer = setTimeout(sendNow, SEND_AFTER_MS);
}

function sendNow() {
    if (!sendTimer || !radio) return;
    clearTimeout(sendTimer);
    sendTimer = null;
    const { power, channel } = radio.state;
    if (!power) game.channel = channel;          // kept on the PC only: no answer will come
    post('walkieSet', { on: power, freq: channel });
}

function wire(r) {
    r.addEventListener('power', (e) => {
        clearTimeout(sendTimer);
        sendTimer = null;
        if (!e.detail.on) game.channel = r.state.channel;     // turned off: it comes back to this channel
        // `power`: always asked of the server — on then off faster than it answers must end off.
        post('walkieSet', { on: !!e.detail.on, freq: r.state.channel, power: true });
    });
    r.addEventListener('channel', () => sendSoon());
    r.addEventListener('volume', (e) => {
        game.volume = e.detail.volume;           // kept on the PC only: no answer will come
        post('walkieVolume', { level: e.detail.volume * 10 });
    });
    r.addEventListener('ptt', async (e) => {
        const on = !!e.detail.active;
        const reply = await post('walkiePtt', { on });
        // Not talking after all (the radio went off, or the player cannot talk): TX goes out.
        if (on && reply && reply.tx === false && radio) radio.setTransmitting(false, { silent: true });
    });
    r.addEventListener('speaker', (e) => post('walkieSpeaker', { on: !!e.detail.on }));
    r.addEventListener('setting', (e) => {
        try { localStorage.setItem(BEEPS_KEY, e.detail.beeps ? '1' : '0'); } catch (_) { /* not kept */ }
        ownBeeps();
    });
}

function beepsOff() {
    if (radio) return radio.state.beeps === false;
    try { return localStorage.getItem(BEEPS_KEY) === '0'; } catch (_) { return false; }
}

// WHO BEEPS FOR THIS PLAYER'S OWN TALKING (the radio's talk beeps: radio.js). While the 3D radio is on
// the screen it beeps itself — at once, on its side bar — so radio.js does not (or every press would
// beep twice); with its sounds off in config.lua, radio.js does. Put away: radio.js again, a moment
// later — a press let go of as it is put away has its roger beep from the 3D radio, not twice. The
// radio's MENU key (beeps off) quiets them either way.
let ownBeepsTimer = null;
function ownBeeps() {
    clearTimeout(ownBeepsTimer);
    ownBeepsTimer = null;
    if (!window.VoiceRadio) return;
    const quiet = beepsOff();
    if (shown && radio) VoiceRadio.setOwnBeeps(!game.sounds && !quiet);
    else ownBeepsTimer = setTimeout(() => { ownBeepsTimer = null; VoiceRadio.setOwnBeeps(!quiet); }, 400);
}

/** PUT AWAY FOR A WHILE, IT IS LET GO OF (7 Oct 2026, Josh: no performance thrown away). Put away, the
 *  module's loop stops by itself (radio3d/radio.js #loop, whip's fix: it ran 60 a second for good), but
 *  the model, its textures, its lighting and its drawing area stay in video memory (~40-55 MB).
 *  dispose() gives that back, with the WebGL context. Opened again within FREE_AFTER_MS it is still
 *  there and slides straight in; after that it is built again, as on the first open. Everything the
 *  game set (power, channel, volume, speaker) is in `game`, and the beeps setting in localStorage, so
 *  the new one comes back the same. */
function free() {
    clearTimeout(freeTimer);
    freeTimer = null;
    if (shown || !radio) return;
    const r = radio;
    radio = null;
    building = null;
    try { r.dispose(); } catch (_) { /* gone either way */ }
}

function freeLater() {
    clearTimeout(freeTimer);
    freeTimer = radio && !shown ? setTimeout(free, FREE_AFTER_MS) : null;
}

/** Load three.js and the model (the code is loaded once; the radio itself again after free()). Kept
 *  hidden until it has slid out of sight, so its first open slides in like every other. */
function build() {
    if (radio) return Promise.resolve(radio);
    if (building) return building;
    building = (async () => {
        const { RadioUI } = await import('../radio3d/radio.js');
        const r = new RadioUI(canvas, {
            modelUrl: 'radio3d/radio.glb', minChannel: game.min, maxChannel: game.max,
            channel: game.channel, volume: game.volume, sounds: game.sounds,
        });
        try {
            await r.init();
        } catch (e) {
            try { r.dispose(); } catch (_) { /* half built */ }
            throw e;
        }
        try { const b = localStorage.getItem(BEEPS_KEY); if (b !== null) r.state.beeps = b === '1'; } catch (_) { /* not kept */ }
        await r.close();                 // out of sight first (unseen: the canvas is hidden till open)
        wire(r);
        radio = r;
        return r;
    })();
    building.catch((e) => {
        building = null;
        post('walkieError', { detail: String((e && e.message) || e) });
    });
    return building;
}

async function open() {
    shown = true;
    clearTimeout(freeTimer);
    freeTimer = null;
    document.body.classList.add('walkie-open');
    let r;
    try { r = await build(); } catch (_) { return; }      // walkieError has said why
    if (!shown) { freeLater(); return; }                    // put away while it was loading
    apply();
    r.setTransmitting(tx, { silent: true });
    document.body.classList.add('walkie-shown');
    r.open();
    ownBeeps();
}

function close() {
    shown = false;
    document.body.classList.remove('walkie-open');
    sendNow();                           // a channel still waiting to be sent goes now
    if (radio) {
        // (lets go of its side bar too). HIDDEN ONCE IT HAS SLID AWAY: a blank canvas most of the
        // screen tall was otherwise left on the page, and drawn with it, for the rest of the session.
        radio.close().then(() => { if (!shown) document.body.classList.remove('walkie-shown'); });
    }
    freeLater();
    ownBeeps();
}

// ---- A CONTROLLER (Josh, 9 Oct 2026; audit 11 CLI-2) -------------------------------------------------------------
// The browser cannot read a gamepad inside FiveM, so client/walkie.lua reads the pad and sends its presses here
// (walkiePad), and they work the radio the way the mouse does: radio.press / radio.turn (the module's whip edits) go
// through the same code as a click and the scroll wheel, sounds and events and all.
//   D-pad up / down: the channel (held: it runs, ten at a time once it has run a while) · left / right: the volume
//   A: power (the volume knob's click) · RB held: talk (the side bar) · X: the speaker · Y: key beeps (MENU)
//   B or Start: put it away
const FAST_AFTER = 8;            // held this many repeats, the channel runs ten at a time
const TAP_MS = 120;              // a pressed key is let go of after this (so it is seen to move)

function tap(part) {
    radio.press(part, true);
    setTimeout(() => { if (radio) radio.press(part, false); }, TAP_MS);
}

function padPress(m) {
    if (!radio || !shown) return;
    switch (m.cmd) {
        case 'up': case 'down': {
            const step = Number(m.rep) >= FAST_AFTER ? 10 : 1;
            radio.turn('knob_channel', m.cmd === 'up' ? step : -step);
            break;
        }
        case 'left': case 'right': radio.turn('knob_volume', m.cmd === 'right' ? 1 : -1); break;
        case 'a': radio.press('knob_volume'); break;
        case 'rb': radio.press('btn_ptt', m.down !== false); break;
        case 'x': tap('btn_speaker'); break;
        case 'y': tap('key_menu'); break;
        case 'b': post('walkieClose'); break;
    }
}

// The radio's beeps setting from last time, before it is ever opened.
if (window.VoiceRadio) VoiceRadio.setOwnBeeps(!beepsOff());

window.addEventListener('message', (event) => {
    const m = event.data || {};
    switch (m.action) {
        case 'walkieOpen': takeGame(m); document.body.classList.toggle('walkie-pad', m.pad === true); open(); break;
        case 'walkieState': takeGame(m); apply(); break;
        case 'walkieClose': close(); break;
        case 'walkieInput': document.body.classList.toggle('walkie-pad', m.pad === true); break;   // the pad's hints
        case 'walkiePad': padPress(m); break;
        case 'talk':
            tx = !!m.radio;
            // Only while it is on the screen: put away, it makes no sound of its own.
            if (radio && shown) radio.setTransmitting(tx, { silent: true });
            break;
    }
});

window.addEventListener('whip:radioRx', (e) => {
    rx = { on: !!(e.detail && e.detail.on), q: Number(e.detail && e.detail.q) || 0 };
    showRx();
});

document.addEventListener('keydown', (e) => {
    if (shown && e.key === 'Escape') { e.preventDefault(); post('walkieClose'); }
});

// For the headless tests (dev only): read the state without reaching into the module.
window.__whipWalkie = () => ({ radio, shown, game: { ...game }, rx: { ...rx }, tx, pending: !!sendTimer });
