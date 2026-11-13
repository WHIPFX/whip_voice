// The sound engine: recipes built from blocks (Web Audio). A sound recipe is data: a list of blocks, each with its
// settings (shared/sound_blocks.lua is the one list of blocks and their safe ranges; this page is sent it on
// connect). Any resource can send one (a phone call, an intercom, a radio) and this file is the only thing that turns it
// into sound. Nothing a recipe says is ever run as code.
//
//   VoiceFx.chain(c, recipe, { q })   ->  a chain: { input, connect(dest), plug(), unplug(), live(on),
//                                         setQ(q), set(type, settings), dispose(), parts, name }
//
// A chain is plugged in only while its voice is (audio.js / radio.js: while the speaker holds their key, and a moment
// after). Blocks that make sound of their own (a hiss, static) start at plug() and stop at unplug(), so a quiet voice
// costs nothing. live(on) is each press and release (beeps, the end of a dropout). setQ is the line's quality, 1 clear
// to 0 gone (the radio's signal), for blocks that follow it (breakup, radio).
//
// Checked here as well as on the server: an unknown block is skipped, every number is brought into its range, a
// setting left out takes its default, and a recipe is cut at SoundLimits' sizes. whip_voice's own recipes (the megaphone,
// the radio: `trusted`) are built as written, so they never wait for the list.

'use strict';

window.VoiceFx = (() => {
    let schema = null;                      // SoundBlocks (connect), or null before
    let limits = { blocks: 24, sources: 4 };
    // The blocks that make sound of their own (SoundLimits.sourceBlocks, from connect).
    let SOURCES = { noise: true, breakup: true, radio: true, hum: true, chorus: true, vibrato: true, tremolo: true, ringmod: true, reverb: true };

    /** The block list and the limits, from the server (connect). */
    function setSchema(blocks, lim) {
        if (blocks && typeof blocks === 'object') schema = blocks;
        if (lim && typeof lim === 'object') {
            const b = Number(lim.blocks), s = Number(lim.sources);
            if (b > 0) limits.blocks = b;
            if (s >= 0) limits.sources = s;
            if (lim.sourceBlocks && typeof lim.sourceBlocks === 'object') SOURCES = Object.assign({}, lim.sourceBlocks);
        }
    }

    const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));

    /** A recipe as it will be built: a list of { type, ...settings }, known blocks only, every setting
     *  present and in range. Blocks may come as { type = 'x' } or as Lua's { 'x', ... } (which arrives
     *  as { "1": "x" }). */
    function check(recipe) {
        const list = Array.isArray(recipe) ? recipe : [];
        const out = [];
        let sources = 0;
        for (const raw of list) {
            if (out.length >= limits.blocks) break;
            if (!raw || typeof raw !== 'object') continue;
            const type = typeof raw.type === 'string' ? raw.type : raw[1] !== undefined ? raw[1] : raw[0];
            const spec = schema && isBlock(type) && Object.prototype.hasOwnProperty.call(schema, type) ? schema[type] : null;
            if (!spec) continue;
            if (SOURCES[type]) { if (sources >= limits.sources) continue; sources += 1; }
            const b = { type };
            for (const key of Object.keys(spec)) {
                const s = spec[key];
                if (!Array.isArray(s) || !s.length) continue;
                if (typeof s[0] === 'number') {
                    const n = Number(raw[key]);
                    b[key] = Number.isFinite(n) ? clamp(n, s[0], s[1]) : s[2];
                } else {
                    b[key] = s.includes(raw[key]) ? raw[key] : s[0];
                }
            }
            out.push(b);
        }
        return out;
    }

    // ---- small parts ----------------------------------------------------------------------------------

    function biquad(c, type, hz, q) {
        const f = c.createBiquadFilter();
        f.type = type;
        f.frequency.value = hz;
        f.Q.value = q;
        return f;
    }

    /** A soft clip: loud peaks rounded off rather than cut, harder the bigger `k` (peak-normalised:
     *  quiet sound comes out up to k times louder; follow it with a gain to bring it back). */
    function softClip(k) {
        const n = 1024, curve = new Float32Array(n), norm = Math.tanh(k);
        for (let i = 0; i < n; i++) { const x = (i / (n - 1)) * 2 - 1; curve[i] = Math.tanh(k * x) / norm; }
        return curve;
    }

    /** Rounded to `steps` steps between -1 and 1: a gritty, digital edge. */
    function crushCurve(steps) {
        const n = 4096, curve = new Float32Array(n);
        for (let i = 0; i < n; i++) { const x = (i / (n - 1)) * 2 - 1; curve[i] = Math.round(x * steps) / steps; }
        return curve;
    }

    // Noise, made here (no sound files): 2 s, looped, kept per kind.
    const noiseBufs = new Map();
    function noise(c, kind) {
        const key = kind || 'white';
        if (noiseBufs.has(key)) return noiseBufs.get(key);
        const len = c.sampleRate * 2, buf = c.createBuffer(1, len, c.sampleRate), d = buf.getChannelData(0);
        if (key === 'white') {
            for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
        } else {
            let b0 = 0, b1 = 0, b2 = 0, last = 0, peak = 0;
            for (let i = 0; i < len; i++) {
                const w = Math.random() * 2 - 1;
                if (key === 'pink') {            // Paul Kellet's economy pink
                    b0 = 0.99765 * b0 + w * 0.0990460;
                    b1 = 0.96300 * b1 + w * 0.2965164;
                    b2 = 0.57000 * b2 + w * 1.0526913;
                    d[i] = b0 + b1 + b2 + w * 0.1848;
                } else {                         // brown: wandering, deep
                    last = (last + 0.02 * w) / 1.02;
                    d[i] = last;
                }
                peak = Math.max(peak, Math.abs(d[i]));
            }
            if (peak > 0) for (let i = 0; i < len; i++) d[i] /= peak;
        }
        noiseBufs.set(key, buf);
        return buf;
    }

    /** One beep: a square wave through a 3.2 kHz low-pass, 4 ms in, held, 10 ms out (the 3D radio's own,
     *  html/radio3d/radio.js #beep). */
    let beeps = 0;     // (dev) how many beeps were made, for the tests
    function beep(c, into, hz, dur, at, level) {
        beeps += 1;
        const t = c.currentTime + at, v = level === undefined ? 0.05 : level;
        const o = c.createOscillator(), g = c.createGain(), lp = c.createBiquadFilter();
        lp.type = 'lowpass';
        lp.frequency.value = 3200;
        o.type = 'square';
        o.frequency.setValueAtTime(hz, t);
        g.gain.setValueAtTime(0, t);
        g.gain.linearRampToValueAtTime(v, t + 0.004);
        g.gain.setValueAtTime(v, t + dur - 0.01);
        g.gain.linearRampToValueAtTime(0, t + dur);
        o.connect(lp); lp.connect(g); g.connect(into);
        o.start(t); o.stop(t + dur + 0.02);
    }

    // ---- the radio's curves (tuned by ear in game, 29 Sep - 4 Oct 2026; moved here from radio.js) ----
    //
    //   q 0.8 and up   clean radio, no static
    //   0.8 to 0.15    the voice dips and starts breaking up, each gap filled with static; what gets
    //                  through is garbled, more the weaker it gets
    //   0.15 to 0      the voice fades away, still breaking up
    //   0              silence (the end of the range)
    const CLEAR = 0.8;
    const FADE = 0.15;
    const STATIC_FULL = 0.3;       // the static's level at static 1 (the first version's "REALLY loud")
    const RC = {
        CLEAR, FADE, STATIC_FULL,
        voiceLevel: (q) => (q >= CLEAR ? 1 : q <= 0 ? 0 : q < FADE ? 0.35 * q / FADE : 0.35 + 0.65 * (q - FADE) / (CLEAR - FADE)),
        // How garbled, 0 (clear) to 1 (fading away) at distortion 1; at most 1.5.
        garbleOf: (q, distortion) => Math.min(1.5, distortion * (q >= CLEAR ? 0 : q < FADE ? 1 : Math.sqrt((CLEAR - q) / (CLEAR - FADE)))),
        driveOf: (q, g) => 1.5 + (1 - q) * 4 + 12 * g,
        crushOf: (g) => (g <= 0 ? 0 : Math.max(4, Math.round(48 - 40 * g))),
        lowCutOf: (g) => 300 + 400 * g,
        highCutOf: (g) => 3000 - 1200 * g,
        makeUpOf: (g) => 1 + 0.6 * g,
        // Dropouts, per 100 ms: rare while the signal is fair, rising steeply towards the end.
        dropoutChance: (q) => (q >= CLEAR || q <= 0 ? 0 : 0.01 + 0.5 * Math.pow((CLEAR - q) / CLEAR, 3)),
    };

    /** The radio's drive: quiet sound passes at its own level, the peaks are clipped — harder the
     *  bigger `k` (divided by k, not tanh(k), so a weak signal's dip is not cancelled). With `steps`,
     *  also rounded to that many steps between silence and the clip (the crush). */
    function driveCurve(k, steps) {
        const n = 4096, curve = new Float32Array(n), step = steps ? 1 / (k * steps) : 0;
        for (let i = 0; i < n; i++) {
            const x = (i / (n - 1)) * 2 - 1, y = Math.tanh(k * x) / k;
            curve[i] = step ? Math.round(y / step) * step : y;
        }
        return curve;
    }

    /** BREAKING UP: now and then the sound drops out for a moment, more often the weaker the line, and
     *  static fills exactly that gap (the voice closes and the static opens at the same instant, and
     *  the static never plays over the voice: Josh, 29 Sep 2026). `st` is the block's state. */
    function dropouts(c, st) {
        clearInterval(st.dropTimer);
        st.dropTimer = setInterval(() => {
            if (!st.plugged || !st.live) return;
            if (Math.random() >= RC.dropoutChance(st.q)) return;
            const t = c.currentTime + Math.random() * 0.08;
            const len = 0.04 + Math.random() * 0.21;
            st.gate.gain.setValueAtTime(0, t);
            st.gate.gain.setValueAtTime(1, t + len);
            st.staticGain.gain.setValueAtTime(st.staticLevel, t);
            st.staticGain.gain.setValueAtTime(0, t + len);
            st.drops += 1;
        }, 100);
    }

    /** Any dropout under way or still to come stops: the sound open and the static off, at once. */
    function settle(c, st) {
        const t = c.currentTime;
        st.gate.gain.cancelScheduledValues(t);
        st.gate.gain.setValueAtTime(1, t);
        st.staticGain.gain.cancelScheduledValues(t);
        st.staticGain.gain.setValueAtTime(0, t);
    }

    /** The static's own path: noise, made here, through a band, behind a gate that only opens in a gap. */
    function staticPath(c, st) {
        st.staticBand = biquad(c, 'bandpass', 2500, 0.7);
        st.staticGain = c.createGain();
        st.staticGain.gain.value = 0;
        st.staticBand.connect(st.staticGain);
    }
    function startHiss(c, st) {
        st.hiss = c.createBufferSource();
        st.hiss.buffer = noise(c, 'white');
        st.hiss.loop = true;
        st.hiss.connect(st.staticBand);
        st.hiss.start(0, Math.random() * 2);
    }
    function stopHiss(st) {
        if (st.hiss) { try { st.hiss.stop(); st.hiss.disconnect(); } catch (_) { /* gone */ } st.hiss = null; }
    }

    /** A room's echo, made here (no sound files): `size` seconds of decaying noise, kept per size. */
    const rooms = new Map();
    function room(c, size) {
        const key = Math.round(size * 10) / 10 + '@' + c.sampleRate;
        if (rooms.has(key)) return rooms.get(key);
        const len = Math.max(1, Math.round(c.sampleRate * size)), buf = c.createBuffer(2, len, c.sampleRate);
        for (let ch = 0; ch < 2; ch++) {
            const d = buf.getChannelData(ch);
            for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3) * 0.5;
        }
        rooms.set(key, buf);
        return buf;
    }

    /** An oscillator that runs only while its voice is plugged in (made at plug, stopped at unplug). */
    function lfoOf(c, hz, into, type) {
        let o = null;
        return {
            start() {
                if (o) return;
                o = c.createOscillator();
                o.type = type || 'sine';
                o.frequency.value = hz;
                o.connect(into);
                o.start();
            },
            stop() { if (o) { try { o.stop(); o.disconnect(); } catch (_) { /* gone */ } o = null; } },
        };
    }

    /** A second copy of the voice through a short delay whose length wavers (chorus: mixed with the
     *  voice; vibrato: the copy alone, so the pitch wavers). */
    function mover(c, p, alone) {
        const input = c.createGain(), out = c.createGain(), delay = c.createDelay(0.1), wet = c.createGain(), swing = c.createGain();
        delay.delayTime.value = Math.max(alone ? 0 : 0.015, p.depth + 0.002);   // never swung below nothing
        swing.gain.value = p.depth;
        wet.gain.value = alone ? 1 : p.mix;
        if (!alone) input.connect(out);
        input.connect(delay); delay.connect(wet); wet.connect(out); swing.connect(delay.delayTime);
        const lfo = lfoOf(c, p.rate, swing);
        return { input, outs: [out], nodes: [input, out, delay, wet, swing], plug: () => lfo.start(), unplug: () => lfo.stop() };
    }

    // ---- the blocks ---------------------------------------------------------------------------------
    //
    // A block: { input, outs: [nodes that go on to the next block, or the chain's end], nodes: [all its
    // nodes], plug?(), unplug?(), live?(on, dest), setQ?(q), set?(settings), parts? }.

    const one = (node, nodes) => ({ input: node, outs: [node], nodes: nodes || [node] });
    const filterBlock = (type) => (c, p) => {
        const f = biquad(c, type, p.hz, p.q !== undefined ? p.q : 0.7);
        if (p.db !== undefined) f.gain.value = p.db;
        return one(f);
    };

    const FACTORY = {
        gain: (c, p) => { const g = c.createGain(); g.gain.value = Math.pow(10, p.db / 20); return one(g); },
        lowpass: filterBlock('lowpass'),
        highpass: filterBlock('highpass'),
        bandpass: filterBlock('bandpass'),
        notch: filterBlock('notch'),
        peak: filterBlock('peaking'),
        lowshelf: filterBlock('lowshelf'),
        highshelf: filterBlock('highshelf'),
        band: (c, p) => {
            const lo = biquad(c, 'highpass', p.low, p.q), hi = biquad(c, 'lowpass', p.high, p.q);
            lo.connect(hi);
            return { input: lo, outs: [hi], nodes: [lo, hi] };
        },
        drive: (c, p) => {
            const w = c.createWaveShaper();
            w.curve = softClip(p.k);
            w.oversample = p.oversample || 'none';
            return one(w);
        },
        crush: (c, p) => { const w = c.createWaveShaper(); w.curve = crushCurve(p.steps); return one(w); },
        compress: (c, p) => {
            const k = c.createDynamicsCompressor();
            k.threshold.value = p.threshold;
            k.knee.value = p.knee;
            k.ratio.value = p.ratio;
            k.attack.value = p.attack;
            k.release.value = p.release;
            return one(k);
        },
        pan: (c, p) => { const s = c.createStereoPanner(); s.pan.value = p.to; return one(s); },

        // A hiss under the voice: the voice passes, the noise is added, only while plugged in.
        noise: (c, p) => {
            const sum = c.createGain(), band = biquad(c, 'bandpass', p.hz, p.q), level = c.createGain();
            level.gain.value = p.level;
            band.connect(level); level.connect(sum);
            let src = null;
            return {
                input: sum, outs: [sum], nodes: [sum, band, level],
                plug() {
                    if (src) return;
                    src = c.createBufferSource();
                    src.buffer = noise(c, p.kind);
                    src.loop = true;
                    src.connect(band);
                    src.start(0, Math.random() * 2);
                },
                unplug() { if (src) { try { src.stop(); src.disconnect(); } catch (_) { /* gone */ } src = null; } },
            };
        },

        // A mains hum (and its two harmonics) under the voice, only while plugged in.
        hum: (c, p) => {
            const sum = c.createGain(), level = c.createGain();
            level.gain.value = p.level;
            level.connect(sum);
            const parts = [[1, 1], [2, 0.35], [3, 0.12]].map(([h, g]) => {
                const gain = c.createGain();
                gain.gain.value = g;
                gain.connect(level);
                return { gain, lfo: lfoOf(c, p.hz * h, gain) };
            });
            return {
                input: sum, outs: [sum], nodes: [sum, level, ...parts.map((x) => x.gain)],
                plug() { for (const x of parts) x.lfo.start(); },
                unplug() { for (const x of parts) x.lfo.stop(); },
            };
        },

        // Repeats `time` apart, each `feedback` as loud as the last, mixed under the voice.
        echo: (c, p) => {
            const input = c.createGain(), out = c.createGain(), wet = c.createGain(), delay = c.createDelay(2.0), fb = c.createGain();
            delay.delayTime.value = p.time;
            fb.gain.value = p.feedback;
            wet.gain.value = p.mix;
            input.connect(out); input.connect(delay); delay.connect(fb); fb.connect(delay); delay.connect(wet); wet.connect(out);
            return { input, outs: [out], nodes: [input, out, wet, delay, fb] };
        },
        chorus: (c, p) => mover(c, p, false),
        vibrato: (c, p) => mover(c, p, true),

        // The loudness pulses: 1 - depth/2, give or take depth/2, `rate` times a second.
        tremolo: (c, p) => {
            const g = c.createGain(), swing = c.createGain();
            g.gain.value = 1 - p.depth / 2;
            swing.gain.value = p.depth / 2;
            swing.connect(g.gain);
            const lfo = lfoOf(c, p.rate, swing);
            return { input: g, outs: [g], nodes: [g, swing], plug: () => lfo.start(), unplug: () => lfo.stop() };
        },

        // The voice times a sine (a robot, a dalek), mixed with the voice itself.
        ringmod: (c, p) => {
            const input = c.createGain(), out = c.createGain(), ring = c.createGain(), dry = c.createGain(), wet = c.createGain();
            ring.gain.value = 0;                 // the oscillator is its whole gain: voice x sin
            dry.gain.value = 1 - p.mix;
            wet.gain.value = p.mix;
            input.connect(dry); dry.connect(out); input.connect(ring); ring.connect(wet); wet.connect(out);
            const lfo = lfoOf(c, p.hz, ring.gain);
            return { input, outs: [out], nodes: [input, out, ring, dry, wet], plug: () => lfo.start(), unplug: () => lfo.stop() };
        },

        // A room around the device. ONLY WHILE THE VOICE TALKS (made at plug, let go of at unplug): a
        // line costs one room per voice talking on it, never one per voice on it.
        reverb: (c, p) => {
            const input = c.createGain(), out = c.createGain(), wet = c.createGain();
            wet.gain.value = p.mix;
            input.connect(out); wet.connect(out);
            let conv = null;
            return {
                input, outs: [out], nodes: [input, out, wet],
                plug() {
                    if (conv) return;
                    conv = c.createConvolver();
                    conv.buffer = room(c, p.size);
                    input.connect(conv); conv.connect(wet);
                },
                unplug() {
                    if (!conv) return;
                    try { input.disconnect(conv); conv.disconnect(); } catch (_) { /* gone */ }
                    conv = null;
                },
            };
        },

        // Dropouts by the line's quality, static in the gaps (the radio's breaking up, on its own).
        breakup: (c, p, env) => {
            const st = { q: env.q, plugged: false, live: false, drops: 0, hiss: null, dropTimer: null,
                staticLevel: p.static * STATIC_FULL, gate: c.createGain() };
            staticPath(c, st);
            return {
                input: st.gate, outs: [st.gate, st.staticGain], nodes: [st.gate, st.staticBand, st.staticGain], parts: { state: st },
                plug() { st.plugged = true; startHiss(c, st); dropouts(c, st); },
                unplug() { st.plugged = false; clearInterval(st.dropTimer); st.dropTimer = null; stopHiss(st); settle(c, st); },
                live(on) { st.live = on; if (!on && st.plugged) settle(c, st); },
                setQ(q) { st.q = q; },
            };
        },

        // A beep as they start talking, two as they stop. No sound path of its own.
        beeps: (c, p) => {
            const pass = c.createGain();
            return {
                input: pass, outs: [pass], nodes: [pass],
                live(on, dest) {
                    if (!dest) return;
                    if (on) { if (p.up > 0) beep(c, dest, p.up, 0.05, 0, p.level); return; }
                    if (p.down > 0) beep(c, dest, p.down, 0.06, 0, p.level);
                    if (p.down2 > 0) beep(c, dest, p.down2, 0.06, 0.07, p.level);
                },
            };
        },

        // WHIP_VOICE'S WALKIE-TALKIE (moved here from radio.js, 7 Oct 2026, unchanged):
        //
        //   voice ─▶ band ─▶ mid peak ─▶ drive + crush ─▶ make-up ─▶ dropouts ─▶ level ────┐
        //   static (made here) ─▶ band ─▶ static gate ───────────────────────────────────┴─▶ out
        //
        // GARBLED AS IT BREAKS UP (Josh, 29 Sep 2026), from the first dropouts on, three things
        // together so it holds for a loud microphone and a quiet one alike (no pitch: Josh):
        //   band   the sound narrows (300-3000 Hz clear, to 700-1800 Hz)
        //   drive  loud sound is clipped harder
        //   crush  rounded to fewer steps: a gritty, digital edge
        radio: (c, p, env) => {
            const st = { q: env.q, plugged: false, live: false, drops: 0, hiss: null, dropTimer: null,
                staticLevel: p.static * STATIC_FULL, distortion: p.distortion };
            const g = RC.garbleOf(st.q, st.distortion);
            st.lowCut = biquad(c, 'highpass', RC.lowCutOf(g), 0.7);
            st.highCut = biquad(c, 'lowpass', RC.highCutOf(g), 0.7);
            st.mid = biquad(c, 'peaking', 1500, 1.0);
            st.mid.gain.value = 4;
            st.drive = c.createWaveShaper();
            st.drive.curve = driveCurve(RC.driveOf(st.q, g), RC.crushOf(g));
            st.makeUp = c.createGain();
            st.makeUp.gain.value = RC.makeUpOf(g);
            st.gate = c.createGain();
            st.level = c.createGain();
            st.level.gain.value = 0;
            st.lowCut.connect(st.highCut); st.highCut.connect(st.mid); st.mid.connect(st.drive);
            st.drive.connect(st.makeUp); st.makeUp.connect(st.gate); st.gate.connect(st.level);
            staticPath(c, st);
            /** The sound to its signal, gliding (only while plugged in). */
            const shape = () => {
                if (!st.plugged) return;
                const t = c.currentTime, gg = RC.garbleOf(st.q, st.distortion);
                st.level.gain.setTargetAtTime(RC.voiceLevel(st.q), t, 0.08);
                st.lowCut.frequency.setTargetAtTime(RC.lowCutOf(gg), t, 0.1);
                st.highCut.frequency.setTargetAtTime(RC.highCutOf(gg), t, 0.1);
                st.makeUp.gain.setTargetAtTime(RC.makeUpOf(gg), t, 0.08);
                st.drive.curve = driveCurve(RC.driveOf(st.q, gg), RC.crushOf(gg));
            };
            return {
                input: st.lowCut, outs: [st.level, st.staticGain],
                nodes: [st.lowCut, st.highCut, st.mid, st.drive, st.makeUp, st.gate, st.level, st.staticBand, st.staticGain],
                parts: { lowCut: st.lowCut, highCut: st.highCut, drive: st.drive, makeUp: st.makeUp, gate: st.gate,
                    level: st.level, staticBand: st.staticBand, staticGain: st.staticGain, state: st },
                plug() { st.plugged = true; startHiss(c, st); shape(); dropouts(c, st); },
                unplug() {
                    st.plugged = false;
                    clearInterval(st.dropTimer);
                    st.dropTimer = null;
                    stopHiss(st);
                    const t = c.currentTime;
                    st.level.gain.cancelScheduledValues(t);
                    st.level.gain.setValueAtTime(0, t);
                    settle(c, st);
                },
                // Pressed again inside the tail (still plugged in): back to its signal; let go: no dropout
                // (or its static) still to come.
                live(on) { st.live = on; if (on) shape(); else if (st.plugged) settle(c, st); },
                setQ(q) { st.q = q; shape(); },
                set(s) {
                    if (s.static !== undefined) { st.staticLevel = s.static * STATIC_FULL; if (st.plugged) settle(c, st); }
                    if (s.distortion !== undefined) { st.distortion = s.distortion; shape(); }
                },
            };
        },
    };

    /** One of the blocks above (its own entry: never something every object has, like 'constructor'). */
    function isBlock(type) { return typeof type === 'string' && Object.prototype.hasOwnProperty.call(FACTORY, type); }

    // ---- chains -------------------------------------------------------------------------------------

    /** Build `recipe` (checked first). The voice goes into `input`; connect(dest) says where the end goes. */
    function chain(c, recipe, opts) {
        // Every recipe is checked against the server's list (a setting left out takes its default). Before
        // connect has sent the list, whip_voice's own (the radio, the megaphone: `trusted`) are built as
        // written, and nothing else at all.
        const steps = schema ? check(recipe)
            : opts && opts.trusted ? (Array.isArray(recipe) ? recipe : []).filter((b) => b && isBlock(b.type)) : [];
        let q = opts && typeof opts.q === 'number' ? clamp(opts.q, 0, 1) : 1;
        // Built at the line's quality from the start (a weak radio voice's first word is already weak).
        const blocks = steps.map((p) => FACTORY[p.type](c, p, { q }));
        if (!blocks.length) blocks.push(one(c.createGain()));      // nothing to do: straight through
        for (let i = 0; i < blocks.length - 1; i++) for (const o of blocks[i].outs) o.connect(blocks[i + 1].input);
        const last = blocks[blocks.length - 1];
        let dest = null, plugged = false;
        const parts = {};
        for (const b of blocks) if (b.parts) Object.assign(parts, b.parts);
        const ch = {
            name: opts && opts.name || null,
            input: blocks[0].input,
            parts,
            steps,
            connect(to) {
                ch.disconnect();
                dest = to || null;
                if (dest) for (const o of last.outs) o.connect(dest);
            },
            disconnect() {
                if (!dest) return;
                for (const o of last.outs) { try { o.disconnect(dest); } catch (_) { /* not connected */ } }
                dest = null;
            },
            plug() { if (plugged) return; plugged = true; for (const b of blocks) if (b.plug) b.plug(); },
            unplug() { if (!plugged) return; plugged = false; for (const b of blocks) if (b.unplug) b.unplug(); },
            live(on) { for (const b of blocks) if (b.live) b.live(!!on, dest); },
            setQ(v) { if (typeof v !== 'number') return; q = clamp(v, 0, 1); for (const b of blocks) if (b.setQ) b.setQ(q); },
            set(type, s) { for (let i = 0; i < blocks.length; i++) if (steps[i] && steps[i].type === type && blocks[i].set) blocks[i].set(s || {}); },
            dispose() {
                ch.unplug();
                ch.disconnect();
                for (const b of blocks) for (const n of b.nodes) { try { n.disconnect(); } catch (_) { /* gone */ } }
            },
        };
        return ch;
    }

    // ---- built-in recipes ---------------------------------------------------------------------------
    //
    // THE MEGAPHONE (moved here from audio.js, 7 Oct 2026, unchanged): a bullhorn on a movie set. No
    // lows, no highs, a honk in the middle, driven into a little distortion and squeezed flat. THE DRIVE
    // AND THE SQUEEZE ADD GRIT, NOT LOUDNESS: a soft clip turns quiet sound up by about its own k, and
    // Chromium's compressor adds its own make-up gain (1 / full-range gain ^ 0.6, about x3.5 here), so
    // the output is turned back down by both — then left a little louder (x2), the honk making it sound
    // louder still. Its reach is its range, not a blast in the ears of everyone next to it.
    const MEGA = { k: 2.5, threshold: -24, ratio: 4 };
    const megaMakeUp = Math.pow(1 / Math.pow(10, (MEGA.threshold - MEGA.threshold / MEGA.ratio) / 20), 0.6);
    const BUILT_IN = {
        megaphone: [
            { type: 'highpass', hz: 500, q: 0.7 },
            { type: 'lowpass', hz: 3800, q: 0.7 },
            { type: 'peak', hz: 1800, q: 1.2, db: 6 },
            { type: 'drive', k: MEGA.k, oversample: '2x' },
            { type: 'compress', threshold: MEGA.threshold, knee: 6, ratio: MEGA.ratio, attack: 0.003, release: 0.12 },
            { type: 'gain', db: 20 * Math.log10((Math.tanh(MEGA.k) / MEGA.k) / megaMakeUp * 2) },
        ],
    };

    /** A built-in recipe's chain by name (the megaphone), or null. */
    function named(c, name, opts) {
        const r = BUILT_IN[name];
        return r ? chain(c, r, Object.assign({}, opts, { name, trusted: true })) : null;
    }

    return { setSchema, check, chain, named, has: (name) => !!BUILT_IN[name], beep, curves: RC,
        _builtIn: BUILT_IN, _schema: () => schema, _limits: () => Object.assign({}, limits), _beeps: () => beeps };
})();
