// Voices in 3D (Web Audio). Every voice this player hears runs through its own chain, plugged in only while its
// speaker holds push-to-talk (see setLive):
//
//   voice ─▶ filter ─▶ distance tone ─▶ 3D panner ─▶ each ear ─▶ volume ─▶ master ─▶ speakers
//            (walls, doorways, car cabins,  │
//             underwater: environment.lua)   └─▶ echo send ─▶ the room's echo (indoors)
//
// Position is decided on this player's machine whenever the game sends a pose (client/main.lua): the ears are the game
// camera, each voice sits at its speaker's head. Loudness is the distance between the two heads, not the camera.
// Full volume up close, silence exactly at the speaker's range.
//
// MUSIC (a world voice made with `music`: a speaker, a song; setSpace) is heard as sound from far off is, which a
// voice in a conversation must not be (it would lag):
//   it arrives late, by its distance at the speed of sound — and so, as it comes closer or goes away, it plays a
//     little faster and higher, or slower and lower: the Doppler effect, by the speed itself (setDelay);
//   the air takes its treble with distance while its bass carries (tone);
//   outdoors, the more of it you hear is its wash off everything around, the further off it is (the outdoor wash,
//     beside the room's echo indoors).
// GTA's axes are x east, y north, z up; Web Audio's are x right, y up, z towards the viewer: (x, y, z) is (x, z, -y).

'use strict';

window.VoiceAudio = (() => {
    const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'whip_voice';
    const post = (name, data) => fetch('https://' + RES + '/' + name, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data || {}),
    }).catch(() => {});

    let ctx = null;
    let master = null;
    let lineOut = null;          // lines (calls, the radio): their own volumes, not the voice volume (see context)
    const voices = new Map();    // identity -> { source, filter, occ, panner, gain, send, analyser, buf, range, at, path, talking, loudAt }

    const wa = (x, y, z) => [x, z, -y];

    // The room's echo: one echo for everything this player hears, picked by client/environment.lua from the room's
    // size. Two echo units, so a change of room crossfades. Made from decaying noise, no sound files.
    const ECHO = {
        small: { decay: 0.35, pre: 0.004, wet: 0.22 },   // a bathroom, a cupboard: short and bright
        room:  { decay: 0.6,  pre: 0.010, wet: 0.16 },   // a bedroom, a kitchen
        // A big lounge, a shop floor: as a room. 1.2 s at 0.20 was far too much echo (13 Nov 2026).
        hall:  { decay: 0.6,  pre: 0.010, wet: 0.16 },
        large: { decay: 2.2,  pre: 0.030, wet: 0.26 },   // a warehouse, a garage, a hangar
    };
    let echoIn = null;
    const echo = [];             // two { conv, out, wired, offTimer }
    let echoLive = 0;            // which of the two is sounding
    let echoNow = null;          // the preset sounding now (null = none)
    let sendLevel = 0;           // how much of each voice goes into the echo now
    const echoCache = {};
    // The outdoor wash: music outdoors, off the buildings and the ground around (one unit, plugged in only while some
    // music is). Longer and duller than a room, after a gap; how much of a song goes in grows with its distance (wash).
    ECHO.outside = { decay: 1.6, pre: 0.045, wet: 0 };
    const WASH = 0.3;            // a song's wash at full volume (close up); far off it outweighs the song itself
    let washIn = null, washConv = null, washWired = false, washTimer = null;

    // How far off music sounds: the speed of sound, and how fast its delay may change (the Doppler effect's size).
    const SOUND_SPEED = 343;     // metres a second
    const DOPPLER_MAX = 0.15;    // seconds of delay a second: at most 15% faster or slower (about 185 km/h)
    const DELAY_JUMP = 0.08;     // a change bigger than this at once (27 m: a teleport, a new place) is not slid
    const DELAY_MAX = 1.9;       // seconds (650 m, past any range)

    // THE SOUND SETTINGS from config.lua (connect `sound`, see setSound).
    let hrtf = true;             // Config.Environment.headphone3D
    let sideDb = 6;              // Config.SideSeparation (see aim)

    /** The one audio context, made on first use and woken if the browser put it to sleep. */
    function context() {
        if (!ctx) {
            ctx = new AudioContext({ latencyHint: 'interactive', sampleRate: 48000 });
            master = ctx.createGain();
            // A LIMITER LAST: a player who turns voices up (/voicevolume, up to 200%) or several people
            // shouting at once must not crackle. It only acts on peaks near full scale.
            const limiter = ctx.createDynamicsCompressor();
            limiter.threshold.value = -3;
            limiter.knee.value = 3;
            limiter.ratio.value = 20;
            limiter.attack.value = 0.002;
            limiter.release.value = 0.15;
            master.connect(limiter);
            limiter.connect(ctx.destination);
            // Lines (calls, the radio) beside the people around: each has its own volume (lines.js, radio.js), so
            // the voice volume ("how loud people are") leaves them alone. The same limiter at the end.
            lineOut = ctx.createGain();
            lineOut.connect(limiter);
            echoIn = ctx.createGain();
            washIn = ctx.createGain();
            washConv = ctx.createConvolver();
            washConv.connect(master);
            for (let i = 0; i < 2; i++) {
                const conv = ctx.createConvolver();
                const out = ctx.createGain();
                out.gain.value = 0;
                conv.connect(out);                 // fed from echoIn only while it sounds (wireUnit)
                out.connect(master);
                echo.push({ conv, out, wired: false, offTimer: null });
            }
        }
        if (ctx.state !== 'running') ctx.resume().catch(() => {});
        return ctx;
    }

    /** A made echo: stereo noise dying away to -60 dB over `decay` seconds, after a short gap, a
     *  little duller the bigger the room. */
    function impulse(name) {
        if (echoCache[name]) return echoCache[name];
        const p = ECHO[name];
        const rate = ctx.sampleRate;
        const pre = Math.floor(p.pre * rate);
        const len = pre + Math.floor(p.decay * 1.1 * rate);
        const buf = ctx.createBuffer(2, len, rate);
        const dull = Math.min(0.9, 0.25 + p.decay * 0.2);
        for (let ch = 0; ch < 2; ch++) {
            const d = buf.getChannelData(ch);
            let y = 0;
            for (let i = pre; i < len; i++) {
                const t = (i - pre) / rate;
                const x = (Math.random() * 2 - 1) * Math.pow(10, (-3 * t) / p.decay);
                y += (1 - dull) * (x - y);
                d[i] = y;
            }
        }
        echoCache[name] = buf;
        return buf;
    }

    /** The outdoor wash, plugged in only while this player is outdoors and some music is plugged in (it is as heavy as
     *  a room's echo); unplugged once its tail has died away. */
    function wireWash() {
        if (!ctx) return;
        let want = false;
        if (!echoNow) for (const v of voices.values()) if (v.music && v.plugged) { want = true; break; }
        clearTimeout(washTimer);
        washTimer = null;
        if (want === washWired) return;
        if (want) {
            if (!washConv.buffer) washConv.buffer = impulse('outside');
            washIn.connect(washConv);
            washWired = true;
        } else {
            washTimer = setTimeout(() => {
                washTimer = null;
                try { washIn.disconnect(washConv); } catch (_) { /* not connected */ }
                washWired = false;
            }, 2500);
        }
    }

    /** How much of a song goes into the outdoor wash: falling far slower than the song itself, so close up it is mostly
     *  the song and far off mostly its wash. None indoors (the room's echo has it). */
    const washOf = (v) => (echoNow ? 0 : WASH * Math.sqrt(v.loud));

    // An echo unit only runs while it sounds (they are the heaviest part of the mix): one fading out is unplugged once
    // faded, both are unplugged outdoors, and one is plugged back in when wanted.
    const ECHO_OFF_MS = 1500;

    function wireUnit(u, on) {
        clearTimeout(u.offTimer);
        u.offTimer = null;
        if (on === u.wired) return;
        u.wired = on;
        if (on) echoIn.connect(u.conv);
        else { try { echoIn.disconnect(u.conv); } catch (_) { /* not connected */ } }
    }

    /** The echo of the room this player stands in (`name`), or none. Crossfaded. */
    function setEcho(name) {
        if (!ctx) return;
        const want = name && ECHO[name] ? name : null;
        if (want === echoNow) return;
        echoNow = want;
        const t = ctx.currentTime;
        const next = echo[1 - echoLive], last = echo[echoLive];
        if (want) {
            wireUnit(next, true);
            next.conv.buffer = impulse(want);
            next.out.gain.setTargetAtTime(1, t, 0.15);
            echoLive = 1 - echoLive;
        }
        last.out.gain.setTargetAtTime(0, t, 0.15);
        clearTimeout(last.offTimer);
        last.offTimer = setTimeout(() => { last.offTimer = null; if (last !== echo[echoLive] || !echoNow) wireUnit(last, false); }, ECHO_OFF_MS);
        sendLevel = want ? ECHO[want].wet : 0;
        for (const v of voices.values()) {
            v.send.gain.setTargetAtTime(sendLevel * v.loud, t, 0.15);
            if (v.wash) v.wash.gain.setTargetAtTime(washOf(v), t, 0.15);
        }
        wireWash();
    }

    // How close a voice must be for full volume (Config.FullVolumeWithin, sent with `connect`)...
    let fullWithin = 1.0;
    // ...and at most this share of its range (a whisper's whole range is only 3 m). The same rule is in
    // client/acoustics.lua (Acoustics.slope), which chooses between doorways by it.
    const FULL_SHARE = 0.15;
    // How far below full a voice has dropped by the time it reaches the edge of its range.
    const EDGE_DB = -30;

    /** Full volume only right up close, then a fade that sounds steady over the whole range, reaching silence exactly
     *  at its edge. The fade is steady in decibels, not volume (ears hear loudness on a log scale): every metre takes
     *  off the same number of decibels, down to EDGE_DB at the edge, and the last stretch closes smoothly to zero.
     *  A voice with a full-volume circle of its own (`own`: a lore character's line with a Bonus range) is at full
     *  volume out to it, then fades over what is left of its range. */
    function fade(d, range, own) {
        const full = own > 0 ? Math.min(own, range - 1) : Math.min(fullWithin, range * FULL_SHARE);
        if (d <= full) return 1;
        if (d >= range) return 0;
        const t = (d - full) / (range - full);
        return Math.pow(10, (EDGE_DB * t) / 20) * (1 - Math.pow(t, 6));
    }

    function setFullWithin(m) {
        if (Number(m) > 0) fullWithin = Number(m);
    }

    // Distance is more than loudness: the lows (close-up warmth) fall steadily to -6 dB at the edge of the speaker's
    // range, and the top gets softer further off (to -6 dB at the edge, most in the far half). Both scale with the
    // speaker's whole range.
    const BASS_HZ = 250, TOP_HZ = 4000;
    const bassDbAt = (t) => -6 * t;
    const topDbAt = (t) => -6 * Math.pow(t, 1.5);

    /** Set a voice's distance tone (d metres away). In half-decibel steps, set straight rather than
     *  glided: a glided filter setting makes the browser work the filter out again for every sample. */
    function tone(v, d) {
        // (With a full-volume circle of its own, it sounds close out to it too: the tone changes over the rest.)
        const near = v.full > 0 ? Math.min(v.full, (v.range || 8) - 1) : 0;
        const t = Math.max(0, Math.min(1, (d - near) / ((v.range || 8) - near)));
        // Music: the air's own, by the metre, whatever its range: the treble goes (6 dB by 40 m, 15 by 100), the bass
        // carries (a concert heard from down the road is its bass).
        const b = v.music ? 0 : Math.round(bassDbAt(t) * 2) / 2 || 0;      // (|| 0: never -0)
        const top = Math.round((v.music ? -Math.min(15, Math.max(0, d - near) * 0.15) : topDbAt(t)) * 2) / 2 || 0;
        if (b !== v.bassDb) { v.bassDb = b; v.bass.gain.value = b; }
        if (top !== v.topDb) { v.topDb = top; v.top.gain.value = top; }
    }

    /** The sound settings from config.lua (connect): { headphone3D, sideDb }. */
    function setSound(o) {
        if (!o || typeof o !== 'object') return;
        hrtf = o.headphone3D !== false;
        sideDb = Number.isFinite(Number(o.sideDb)) ? Math.max(0, Math.min(20, Number(o.sideDb))) : 6;
        for (const v of voices.values()) {
            v.panner.panningModel = hrtf ? 'HRTF' : 'equalpower';
            setHrtfFix(v);
            if (v.plugged && v.head && lastPose) aim(v, lastPose);
        }
    }

    // The 3D's own tone, taken back out: Chrome's HRTF lifts 160-250 Hz by about 5 dB and dulls the top by 3-4 dB on
    // average, so voices sound boomy. These two filters, before the panner, bring that average to within about 1 dB of
    // flat and leave each direction's own cues alone. Plain stereo (headphone3D off) needs none (gain 0).
    const HRTF_FIX = [
        { type: 'peaking', hz: 210, q: 0.4, db: -6.5 },
        { type: 'highshelf', hz: 7000, q: 0.7, db: 2.5 },
    ];
    function setHrtfFix(v) {
        v.fix.forEach((f, i) => { f.gain.value = hrtf ? HRTF_FIX[i].db : 0; });
    }

    // A voice is only mixed while its speaker holds push-to-talk. Everyone near stays connected, but the chain below
    // (filter, 3D, volume, echo, talking meter) is plugged in only while they are live and for TAIL_MS after they let
    // go, as the last of their voice is still arriving. voice.js says when: LiveKit tells every listener the instant
    // a speaker presses or releases the key, before their first sound.
    const TAIL_MS = 1000;

    /** A voice near this player. `source` is their track's sound: voice.js's track hub plays the track and hands the
     *  same source to every use of it, so this chain only taps it. */
    function add(id, source, range, live) {
        remove(id);
        context();
        build(id, source, range, false);
        if (live) setLive(id, true);
    }

    /** A radio on speaker near this player (radio.js plays what comes out of it into `node`): heard like a voice at its
     *  owner's head, with no track of its own. Live while a voice comes out of it (radio.js says so, with setLive).
     *  Never counted as someone talking. */
    function addInput(id, node, range) {
        remove(id);
        context();
        build(id, node, range, true);
    }

    function build(id, source, range, input) {
        const c = ctx;
        // WHAT IS IN THE WAY (walls, doors, windows, cars, water): a treble cut and a volume cut, set
        // by the environment (client/environment.lua via pose `e`). Open and untouched to begin with.
        const filter = c.createBiquadFilter();
        filter.type = 'lowpass';
        filter.frequency.value = 22000;
        filter.Q.value = 0.7;
        const occ = c.createGain();
        // The distance tone (see tone): less close-up warmth, a softer top, the further away.
        const bass = biquad(c, 'lowshelf', BASS_HZ, 0.7);
        bass.gain.value = 0;
        const top = biquad(c, 'highshelf', TOP_HZ, 0.7);
        top.gain.value = 0;
        // The HRTF's own tone taken back out (HRTF_FIX), just before the panner; the echo send stays on `top`.
        const fix = HRTF_FIX.map((f) => biquad(c, f.type, f.hz, f.q));
        const panner = c.createPanner();
        panner.panningModel = hrtf ? 'HRTF' : 'equalpower';   // HRTF: proper 3D for headphones
        panner.distanceModel = 'linear';
        panner.rolloffFactor = 0;            // loudness is ours (fade above), direction is the panner's
        // Each ear's own volume after the 3D, for a firmer left and right (see aim).
        const split = c.createChannelSplitter(2);
        const earL = c.createGain(), earR = c.createGain();
        const ears = c.createChannelMerger(2);
        const gain = c.createGain();
        gain.gain.value = 0;                 // silent until the first pose places it
        // Into the room's echo: as much of the voice as the room takes (sendLevel), faded with the
        // voice itself, so its echo is as far away as it is. Silent until the first pose too.
        const send = c.createGain();
        send.gain.value = 0;
        const analyser = c.createAnalyser();
        analyser.fftSize = 512;

        filter.connect(occ);
        occ.connect(bass);
        bass.connect(top);
        top.connect(fix[0]);
        fix[0].connect(fix[1]);
        fix[1].connect(panner);
        panner.connect(split);
        split.connect(earL, 0);
        split.connect(earR, 1);
        earL.connect(ears, 0, 0);
        earR.connect(ears, 0, 1);
        ears.connect(gain);
        gain.connect(master);
        top.connect(send);
        send.connect(echoIn);

        const v = { source, filter, occ, bass, top, fix, panner, earL, earR, gain, send, analyser, buf: new Float32Array(analyser.fftSize),
            range: range || 8, at: null, path: null, head: null, talking: false, loudAt: 0, loud: 0, bassDb: 0, topDb: 0,
            live: false, plugged: false, unplugTimer: null, fx: null, input: !!input,
            music: false, delay: null, wash: null, poseAt: 0 };   // (music: setSpace)
        setHrtfFix(v);
        voices.set(id, v);
    }

    // ---- Voice effects
    // A speaker's effect goes between their voice and the muffle filter, so walls still muffle a megaphone. Built only
    // while on; the server says which (hear lists: `fx`, a built-in recipe's name). The sound is html/js/fx.js's.

    function biquad(c, type, hz, q) {
        const f = c.createBiquadFilter();
        f.type = type;
        f.frequency.value = hz;
        f.Q.value = q;
        return f;
    }

    /** Where a voice's sound goes in first: its effect, or straight to the muffle filter. */
    const into = (v) => (v.fx ? v.fx.input : v.filter);
    /** Where its source is plugged: music's delay (always joined to `into`), else `into` itself. */
    const inlet = (v) => v.delay || into(v);

    /** A speaker's effect on or off (null): a built-in recipe's name ('megaphone'), or a recipe of its own (a world
     *  voice's sound, SetWorldVoiceSound: a speaker's). Swapped in place, even mid-sentence; the same one again
     *  changes nothing. */
    function setFx(id, fx) {
        const v = voices.get(id);
        if (!v) return;
        const recipe = Array.isArray(fx) && fx.length > 0;
        const want = recipe ? 'r:' + JSON.stringify(fx) : (fx && VoiceFx.has(fx) ? fx : null);
        if ((v.fx ? v.fx.key : null) === want) return;
        // (Music's delay stays joined to whatever comes after it; a voice's source is plugged straight in.)
        const feed = v.delay || (v.plugged ? v.source : null);
        if (feed) { try { feed.disconnect(into(v)); } catch (_) { /* not connected */ } }
        if (v.fx) v.fx.dispose();
        v.fx = !want ? null : recipe ? VoiceFx.chain(context(), fx) : VoiceFx.named(context(), want);
        if (v.fx) v.fx.key = want;
        if (v.fx) {
            v.fx.connect(v.filter);
            if (v.plugged) { v.fx.plug(); if (v.live) v.fx.live(true); }
        }
        if (feed) feed.connect(into(v));
    }

    /** Heard as music (a world voice made with `music`: a speaker, a song) or as a voice: music arrives late by its
     *  distance (so the Doppler effect), loses treble to the air while its bass carries, and washes outdoors. A voice
     *  in a conversation has none of it (it would lag). The same again changes nothing. */
    function setSpace(id, on) {
        const v = voices.get(id);
        if (!v || v.music === !!on) return;
        const c = context();
        v.music = !!on;
        if (v.music) {
            v.delay = c.createDelay(DELAY_MAX + 0.1);
            v.delay.delayTime.value = v.head && lastPose ? Math.min(DELAY_MAX, distanceOf(v, lastPose) / SOUND_SPEED) : 0;
            v.delay.connect(into(v));
            if (v.plugged) {
                try { v.source.disconnect(into(v)); } catch (_) { /* not connected */ }
                v.source.connect(v.delay);
            }
            v.wash = c.createGain();
            v.wash.gain.value = v.plugged ? washOf(v) : 0;
            v.top.connect(v.wash);
            v.wash.connect(washIn);
        } else {
            if (v.plugged) {
                try { v.source.disconnect(v.delay); } catch (_) { /* not connected */ }
                v.source.connect(into(v));
            }
            try { v.delay.disconnect(); v.top.disconnect(v.wash); v.wash.disconnect(); } catch (_) { /* already */ }
            v.delay = null;
            v.wash = null;
        }
        v.bassDb = v.topDb = null;     // (the tone is worked out again at the next pose)
        wireWash();
    }

    /** Music's delay: its distance at the speed of sound. Slid to the new distance over the time to the next pose, so
     *  while it changes the song plays a little faster (coming closer) or slower (going away), by just the speed: the
     *  Doppler effect. Never slid faster than DOPPLER_MAX; a jump (a teleport, a new place) is made at once. */
    function setDelay(v, d, t) {
        const p = v.delay.delayTime;
        const want = Math.min(DELAY_MAX, d / SOUND_SPEED);
        const was = p.value;
        const gap = v.poseAt > 0 ? Math.max(0.02, Math.min(0.3, t - v.poseAt)) : 0.05;
        v.poseAt = t;
        p.cancelScheduledValues(t);
        if (Math.abs(want - was) > DELAY_JUMP) { p.setValueAtTime(want, t); return; }
        p.setValueAtTime(was, t);
        p.linearRampToValueAtTime(want, t + Math.max(gap, Math.abs(want - was) / DOPPLER_MAX));
    }

    /** Plug a voice's chain in: put it where it was last seen first, so its first word is in place. */
    function plugIn(v) {
        if (v.plugged) return;
        v.plugged = true;
        const t = ctx.currentTime;
        if (v.head && lastPose) { const d = distanceOf(v, lastPose); v.loud = fade(d, v.range, v.full); tone(v, d); } else v.loud = 0;
        v.gain.gain.cancelScheduledValues(t);
        v.gain.gain.setValueAtTime(v.loud, t);
        v.send.gain.cancelScheduledValues(t);
        v.send.gain.setValueAtTime(sendLevel * v.loud, t);
        if (v.wash) {
            v.wash.gain.cancelScheduledValues(t);
            v.wash.gain.setValueAtTime(washOf(v), t);
            // (Its delay as it stands now, not slid there from where it was last heard.)
            v.delay.delayTime.cancelScheduledValues(t);
            v.delay.delayTime.setValueAtTime(v.head && lastPose ? Math.min(DELAY_MAX, distanceOf(v, lastPose) / SOUND_SPEED) : 0, t);
            v.poseAt = 0;
        }
        if (v.head && lastPose) aim(v, lastPose);
        if (v.fx) v.fx.plug();
        v.source.connect(inlet(v));
        v.source.connect(v.analyser);
        if (v.music) wireWash();
    }

    function unplug(v) {
        if (!v.plugged) return;
        v.plugged = false;
        try { v.source.disconnect(inlet(v)); v.source.disconnect(v.analyser); } catch (_) { /* already */ }
        if (v.fx) v.fx.unplug();
        v.talking = false;
        if (v.music) wireWash();
    }

    /** The speaker pressed (true) or let go of (false) push-to-talk. */
    function setLive(id, on) {
        const v = voices.get(id);
        if (!v || v.live === !!on) return;
        v.live = !!on;
        clearTimeout(v.unplugTimer);
        v.unplugTimer = null;
        if (on) {
            plugIn(v);
        } else {
            v.unplugTimer = setTimeout(() => { v.unplugTimer = null; if (!v.live) { unplug(v); reportTalkers(); } }, TAIL_MS);
        }
        if (v.fx) v.fx.live(v.live);      // an effect's beeps, its dropouts' end
        reportTalkers();
    }

    function remove(id) {
        const v = voices.get(id);
        if (!v) return;
        clearTimeout(v.unplugTimer);
        const wasTalking = v.talking || v.live;
        // The source is shared (the track hub's, or a radio's speaker node): only this voice's own taps
        // on it are cut, never everything it feeds.
        unplug(v);
        try { v.gain.disconnect(); v.send.disconnect(); } catch (_) { /* already gone */ }
        if (v.delay) { try { v.delay.disconnect(); v.wash.disconnect(); } catch (_) { /* already gone */ } }
        if (v.fx) v.fx.dispose();
        voices.delete(id);
        if (v.music) wireWash();
        if (wasTalking) reportTalkers();
    }

    /** A voice's range, and its own full-volume circle (`full`: a world voice's, or none: the usual). */
    function setRange(id, range, full) {
        const v = voices.get(id);
        if (!v) return;
        if (range > 0) v.range = range;
        v.full = Number(full) > 0 ? Number(full) : 0;
    }

    function clear() {
        for (const id of [...voices.keys()]) remove(id);
    }

    /** How voices travel right now (client/environment.lua), a few times a second:
     *  e = { rv = the room's echo or false, v = { [identity]: { g dB, f Hz, at [x,y,z]?, p metres? } } }.
     *  Only the voices worked out this time are in `v`; a missing voice stays as it was. Nothing in the way = g 0, f 22000. */
    function environment(e) {
        if (!ctx || !e) return;
        const t = ctx.currentTime;
        setEcho(e.rv || null);
        const list = e.v || {};
        for (const id of Object.keys(list)) {
            const v = voices.get(id);
            if (!v) continue;
            const a = list[id];
            const hz = a && a.f > 0 ? Math.min(22000, a.f) : 22000;
            const g = a && a.g < 0 ? Math.pow(10, a.g / 20) : 1;
            // Glided over about half a second: walking round a corner dulls the sound smoothly, never in steps.
            v.filter.frequency.setTargetAtTime(hz, t, 0.15);
            v.occ.gain.setTargetAtTime(g, t, 0.15);
            // Heard from the doorway it comes out of, over the longer way round.
            v.at = a && Array.isArray(a.at) ? a.at : null;
            v.path = a && a.p > 0 ? a.p : null;
        }
    }

    let lastPose = null;   // the camera and head of the last pose, for a voice plugged in between poses

    /** Put a voice where it is, as seen from the camera. */
    function place(panner, x, y, z) {
        if (panner.positionX) {
            panner.positionX.value = x;
            panner.positionY.value = y;
            panner.positionZ.value = z;
        } else {
            panner.setPosition(x, y, z);
        }
    }

    /** A pose from the game: c = camera [x, y, z, pitch, yaw], h = this player's head [x, y, z],
     *  s = { [identity]: [x, y, z] } each heard speaker's head (missing = not near enough to see),
     *  and sometimes e (see environment).
     *
     *  The ears never move: Web Audio's listener stays at the origin and every voice is placed relative to the camera,
     *  then set straight. Moving the listener smoothly makes Chromium work out every voice's direction per sample
     *  instead of per block, which cuts the voices the page can mix from about 150 to about 60. */
    function pose(m) {
        if (!ctx || !m || !m.c) return;
        if (m.e) environment(m.e);
        const t = ctx.currentTime;
        const [x, y, z, pitchDeg, yawDeg] = m.c;
        const pitch = pitchDeg * Math.PI / 180, yaw = yawDeg * Math.PI / 180;
        // The camera's forward, up and right, in Web Audio's axes.
        const f = wa(-Math.sin(yaw) * Math.cos(pitch), Math.cos(yaw) * Math.cos(pitch), Math.sin(pitch));
        const u = wa(Math.sin(yaw) * Math.sin(pitch), -Math.cos(yaw) * Math.sin(pitch), Math.cos(pitch));
        const r = [f[1] * u[2] - f[2] * u[1], f[2] * u[0] - f[0] * u[2], f[0] * u[1] - f[1] * u[0]];
        lastPose = { p: wa(x, y, z), f, u, r, h: m.h || [x, y, z] };
        // `all: false` is a lighter pose carrying only some heads (the others are unchanged). A head of `false` (or
        // missing from a full pose) is a speaker this game cannot place: silent.
        const full = m.all !== false;
        for (const [id, v] of voices) {
            const head = m.s && m.s[id];
            if (head) v.head = head;
            else if (full || head === false) v.head = null;
            else continue;
            if (!v.plugged) continue;               // quiet: remembered, not mixed
            if (!v.head) {
                v.loud = 0;
                v.gain.gain.setTargetAtTime(0, t, 0.05);
                v.send.gain.setTargetAtTime(0, t, 0.05);
                continue;
            }
            aim(v, lastPose);
            const d = distanceOf(v, lastPose);
            v.loud = fade(d, v.range, v.full);
            tone(v, d);
            v.gain.gain.setTargetAtTime(v.loud, t, 0.05);
            v.send.gain.setTargetAtTime(sendLevel * v.loud, t, 0.05);
            if (v.delay) {
                setDelay(v, d, t);
                v.wash.gain.setTargetAtTime(washOf(v), t, 0.05);
            }
        }
    }

    /** Point a voice's 3D at where it comes from (the doorway, when it is coming out of one).
     *
     *  Firmer left and right (Config.SideSeparation): a head only shadows high notes, so the far ear is also turned
     *  down, by up to sideDb for someone straight to one side, nothing straight ahead or behind. */
    function aim(v, P) {
        const from = v.at || v.head;
        const q = wa(from[0], from[1], from[2]);
        const d = [q[0] - P.p[0], q[1] - P.p[1], q[2] - P.p[2]];
        const right = d[0] * P.r[0] + d[1] * P.r[1] + d[2] * P.r[2];
        const ahead = d[0] * P.f[0] + d[1] * P.f[1] + d[2] * P.f[2];
        place(v.panner,
            right,
            d[0] * P.u[0] + d[1] * P.u[1] + d[2] * P.u[2],           // up
            -ahead);                                                  // ahead is -z
        const flat = Math.hypot(right, ahead);
        const side = hrtf && flat > 0.05 ? right / flat : 0;          // -1 hard left .. 1 hard right
        const far = Math.pow(10, (-sideDb * Math.abs(side)) / 20);
        const t = ctx.currentTime;
        v.earL.gain.setTargetAtTime(side > 0 ? far : 1, t, 0.05);
        v.earR.gain.setTargetAtTime(side < 0 ? far : 1, t, 0.05);
    }

    /** How far a voice travels to this player: head to head, or the way round via a doorway. */
    function distanceOf(v, P) {
        const h = P.h, head = v.head;
        return v.path || Math.hypot(head[0] - h[0], head[1] - h[1], head[2] - h[2]);
    }

    function volume(level) {
        context();
        master.gain.setTargetAtTime(Math.max(0, Math.min(2, Number(level) || 0)), ctx.currentTime, 0.1);
    }

    // Who is talking, ten times a second: the game moves their mouths (client/main.lua). Only voices plugged in are
    // measured, only changes are sent, and a short hold stops the list flickering between words.
    //   ids   talking: sound is coming out (the mouths)
    //   live  holding push-to-talk (the game follows these closely: positions, walls)
    function reportTalkers() {
        const ids = [], live = [];
        for (const [id, v] of voices) {
            if (v.talking && !v.input) ids.push(id);     // a radio on speaker moves nobody's mouth
            if (v.live) live.push(id);
        }
        post('talkers', { ids, live });
    }
    setInterval(() => {
        if (!voices.size) return;
        const now = performance.now();
        let changed = false;
        for (const v of voices.values()) {
            if (!v.plugged) continue;
            v.analyser.getFloatTimeDomainData(v.buf);
            let s = 0;
            for (let i = 0; i < v.buf.length; i++) s += v.buf[i] * v.buf[i];
            if (Math.sqrt(s / v.buf.length) > 0.012) v.loudAt = now;
            const talking = now - v.loudAt < 300;
            if (talking !== v.talking) { v.talking = talking; changed = true; }
        }
        if (changed) reportTalkers();
    }, 100);

    return { add, addInput, remove, setLive, setRange, setFx, setSpace, clear, pose, volume, context, setFullWithin,
        ids: () => [...voices.keys()], has: (id) => voices.has(id),
        // The people around's mix (after the voice volume, before the limiter).
        output: () => { context(); return master; },
        // Where lines (lines.js) and the radio's own beeps (radio.js) go: their own volumes, then the limiter.
        lineOutput: () => { context(); return lineOut; },
        setSound,
        _voices: voices, _fade: fade, _echo: () => echoNow, _echoWired: () => echo.some((u) => u.wired),
        _echoUnits: () => echo.map((u) => ({ wired: u.wired, len: u.conv.buffer ? u.conv.buffer.length : 0 })) };
})();
