// Voices on a line (Web Audio). A line (server/lines.lua) is a set of players who hear each other wherever they are: a
// radio frequency, a phone call, anything a resource opens. The server tells this page each line once (token, track,
// sound recipe) and then the voices on it (voice.js). Not in 3D: a line voice comes out of this player's own device:
//
//   voice ─▶ the line's sound (html/js/fx.js: its recipe) ─▶ level ─▶ the line's bus ─▶ [limiter] ─▶ the mix
//
// or, when the server routes it through someone's device on speaker near this player (`via`), out of that device:
// into its node here (speakerNode), which audio.js places in 3D at its owner's head (addInput). This player's own
// volume for that line does not touch it. `level` is a voice picked up by a device on speaker: quieter the further
// from it the talker stands.
//
// A safety limiter ends every line whose recipe came from another resource, since data can't be trusted to be gentle
// on ears. whip_voice's own lines (the radio) are built as written.
//
// Radio frequencies (`rx`): their bus follows the radio's volume knob, and they light the 3D radio's RX lamp and
// signal bars ('whip:radioRx', html/js/walkie.js), never a call. Their beeps are in their recipe (fx.js 'beeps').
//
// A line voice is only plugged in while its talker holds their key (setLive), plus a moment after.

'use strict';

window.VoiceLines = (() => {
    const lines = new Map();      // token -> { token, track, recipe, own, rx, bus, limit, trim }
    const voices = new Map();     // 'token/identity' -> { token, id, source, chain, out, q, via, pick, live, plugged, unplugTimer }
    const speakers = new Map();   // a device on speaker's id ('spk:...') -> { node, live: Set of voice keys, gone }
    const TAIL_MS = 1000;
    let rxLevel = 1;              // the radio's volume (the walkie), for radio frequencies
    let callLevel = 1;            // the player's call volume ("Phone call volume"), for every other line

    const keyOf = (token, id) => token + '/' + id;
    function ctx() { return VoiceAudio.context(); }

    // ---- lines ---------------------------------------------------------------------------------

    /** A line, as the server says it is. Told again (a new recipe), the voices on it are built again. */
    function open(l) {
        if (!l || typeof l.line !== 'string') return;
        const had = lines.get(l.line);
        const recipe = Array.isArray(l.recipe) ? l.recipe : [];
        if (had) {
            if (JSON.stringify(had.recipe) === JSON.stringify(recipe)) return;
            had.recipe = recipe;
            for (const v of [...voices.values()]) if (v.token === l.line) rebuild(v);
            return;
        }
        lines.set(l.line, { token: l.line, track: l.track === 'radio' ? 'radio' : 'voice', recipe, own: l.own === true,
            rx: l.rx === true, bus: null, limit: null, trim: null });
    }

    /** The line's bus into the mix: its volume (the radio's, else the call volume), then (someone else's recipe)
     *  the safety limiter. Lines go beside the people around (VoiceAudio.lineOutput): the voice volume is theirs. */
    function busOf(line) {
        if (line.bus) return line.bus;
        const c = ctx();
        line.bus = c.createGain();
        line.bus.gain.value = line.rx ? rxLevel : callLevel;
        if (line.own) {
            line.bus.connect(VoiceAudio.lineOutput());
        } else {
            // A hard ceiling a little under full scale. Chromium's compressor turns its output up by its
            // own make-up gain (1 / full-range gain ^ 0.6); the trim takes that back off, so a recipe
            // that stays under the ceiling sounds exactly as it was written.
            const thr = -6, ratio = 20;
            line.limit = c.createDynamicsCompressor();
            line.limit.threshold.value = thr;
            line.limit.knee.value = 0;
            line.limit.ratio.value = ratio;
            line.limit.attack.value = 0.002;
            line.limit.release.value = 0.1;
            line.trim = c.createGain();
            line.trim.gain.value = 1 / Math.pow(1 / Math.pow(10, (thr - thr / ratio) / 20), 0.6);
            line.bus.connect(line.limit);
            line.limit.connect(line.trim);
            line.trim.connect(VoiceAudio.lineOutput());
        }
        return line.bus;
    }

    /** Let go of a line: its voices (voice.js lets go of their tracks first) and its bus. */
    function close(token) {
        for (const v of [...voices.values()]) if (v.token === token) remove(token, v.id);
        const line = lines.get(token);
        if (!line) return;
        for (const n of [line.bus, line.limit, line.trim]) { if (n) { try { n.disconnect(); } catch (_) { /* gone */ } } }
        lines.delete(token);
        reportRx();
    }

    const trackOf = (token) => { const l = lines.get(token); return l ? l.track : null; };

    // ---- devices on speaker ------------------------------------------------------------------

    /** What comes out of a device on speaker goes in here; audio.js picks it up (addInput) and places
     *  it. Made on first use, kept while anything might come out of it. */
    function speakerNode(id) {
        let s = speakers.get(id);
        if (!s) {
            s = { node: ctx().createGain(), live: new Set(), gone: false };
            speakers.set(id, s);
        }
        s.gone = false;
        return s.node;
    }

    /** Whether a voice is coming out of that device right now. */
    function speakerLive(id) {
        const s = speakers.get(id);
        return !!(s && s.live.size);
    }

    /** A voice started or stopped coming out of a device on speaker: the device is live in audio.js while
     *  any is (it then follows its own short tail, as a voice does). */
    function markSpeaker(spk, key, on) {
        const s = speakers.get(spk);
        if (!s) return;
        const was = s.live.size > 0;
        if (on) s.live.add(key); else s.live.delete(key);
        const now = s.live.size > 0;
        if (now !== was) VoiceAudio.setLive(spk, now);
    }

    /** Let go of a device on speaker that left the hear list — now, or once the last voice still coming
     *  out of it has moved on (the server moves them on its next pass: setVia, remove). */
    function forgetSpeaker(spk) {
        const s = speakers.get(spk);
        if (!s) return;
        for (const v of voices.values()) if (v.via === spk) { s.gone = true; return; }
        speakers.delete(spk);
    }

    /** A voice stopped coming out of `spk`: if that device already left the hear list, it goes now. */
    function leftSpeaker(spk) {
        const s = spk && speakers.get(spk);
        if (s && s.gone) forgetSpeaker(spk);
    }

    // ---- RX: this player's own radio receiving (for the radio on the screen) ----
    let rxSent = { on: false, q: 0 };
    function reportRx() {
        let on = false, q = 0;
        for (const v of voices.values()) {
            const line = lines.get(v.token);
            if (line && line.rx && v.live && !v.via) { on = true; q = Math.max(q, v.q); }
        }
        if (on === rxSent.on && q === rxSent.q) return;
        rxSent = { on, q };
        try { window.dispatchEvent(new CustomEvent('whip:radioRx', { detail: { on, q } })); } catch (_) { /* nobody listening */ }
    }

    // ---- voices --------------------------------------------------------------------------------

    /** Where a line voice comes out: this player's own device (the line's bus), or a device on speaker. */
    function dest(v) {
        if (v.via) return speakerNode(v.via);
        const line = lines.get(v.token);
        return line ? busOf(line) : null;
    }

    /** The chain for a voice, from its line's recipe (and the parts the headless tests read). */
    function build(v) {
        const line = lines.get(v.token);
        const c = ctx();
        v.chain = VoiceFx.chain(c, line ? line.recipe : [], { q: v.q, name: v.token, trusted: !!(line && line.own) });
        for (const k of ['lowCut', 'highCut', 'drive', 'makeUp', 'gate', 'level', 'staticBand', 'staticGain']) v[k] = v.chain.parts[k];
        v.chain.connect(v.out);
    }

    /** A voice on a line. `source` is their track's sound, from voice.js's track hub: this chain only
     *  taps it. */
    function add(token, id, source, q, via, pick) {
        remove(token, id);
        if (!lines.has(token)) return null;
        const c = ctx();
        const v = { key: keyOf(token, id), token, id, source, chain: null, out: c.createGain(),
            q: typeof q === 'number' ? q : 1, via: via || null, pick: typeof pick === 'number' ? pick : 1,
            live: false, plugged: false, unplugTimer: null };
        Object.defineProperty(v, 'drops', { get: () => (v.chain.parts.state ? v.chain.parts.state.drops : 0) });
        v.out.gain.value = v.pick;
        build(v);
        const d = dest(v);
        if (d) v.out.connect(d);
        voices.set(v.key, v);
        return v;
    }

    /** Its line's sound changed: built again in place (plugged back in if it was). */
    function rebuild(v) {
        const was = v.plugged;
        if (was) unplug(v);
        v.chain.dispose();
        build(v);
        if (was) { plugIn(v); if (v.live) v.chain.live(true); }
    }

    function plugIn(v) {
        if (v.plugged) return;
        v.plugged = true;
        v.source.connect(v.chain.input);
        v.chain.plug();
    }

    function unplug(v) {
        if (!v.plugged) return;
        v.plugged = false;
        try { v.source.disconnect(v.chain.input); } catch (_) { /* already */ }
        v.chain.unplug();
    }

    /** The talker pressed (true) or let go of (false) their key. */
    function setLive(token, id, on) {
        const v = voices.get(keyOf(token, id));
        if (!v || v.live === !!on) return;
        v.live = !!on;
        clearTimeout(v.unplugTimer);
        v.unplugTimer = null;
        if (on) {
            plugIn(v);
            if (v.via) markSpeaker(v.via, v.key, true);   // the device on speaker comes on first, then any beep
            v.chain.live(true);
        } else {
            v.chain.live(false);                          // a beep; no dropout (or its static) still to come
            if (v.via) markSpeaker(v.via, v.key, false);
            v.unplugTimer = setTimeout(() => { v.unplugTimer = null; if (!v.live) unplug(v); }, TAIL_MS);
        }
        reportRx();
    }

    /** The server's signal for this voice changed (0 to 1). */
    function setQuality(token, id, q) {
        const v = voices.get(keyOf(token, id));
        if (!v || typeof q !== 'number') return;
        v.q = Math.max(0, Math.min(1, q));
        v.chain.setQ(v.q);
        if (v.live) reportRx();
    }

    /** Where it comes out changed: this player's own device (null), or a device on speaker. Moved in
     *  place, even mid-sentence. */
    function setVia(token, id, via) {
        const v = voices.get(keyOf(token, id));
        if (!v) return;
        via = via || null;
        if (v.via === via) return;
        try { v.out.disconnect(); } catch (_) { /* not connected */ }
        if (v.live && v.via) markSpeaker(v.via, v.key, false);
        const was = v.via;
        v.via = via;
        const d = dest(v);
        if (d) v.out.connect(d);
        if (v.live && v.via) markSpeaker(v.via, v.key, true);
        leftSpeaker(was);
        reportRx();
    }

    /** A picked-up talker moved nearer or further from the device: their level, gliding. */
    function setLevel(token, id, level) {
        const v = voices.get(keyOf(token, id));
        if (!v || typeof level !== 'number') return;
        v.pick = Math.max(0, Math.min(1, level));
        v.out.gain.setTargetAtTime(v.pick, ctx().currentTime, 0.08);
    }

    function remove(token, id) {
        const v = voices.get(keyOf(token, id));
        if (!v) return;
        clearTimeout(v.unplugTimer);
        unplug(v);
        if (v.live && v.via) markSpeaker(v.via, v.key, false);
        v.chain.dispose();
        try { v.out.disconnect(); } catch (_) { /* gone */ }
        voices.delete(v.key);
        leftSpeaker(v.via);
        if (v.live) reportRx();
    }

    function clear() {
        for (const v of [...voices.values()]) remove(v.token, v.id);
        for (const token of [...lines.keys()]) close(token);
        speakers.clear();
    }

    /** The radio's volume (0 to 1), from the walkie: every radio frequency's bus. */
    function setRxVolume(level) {
        rxLevel = Math.max(0, Math.min(1, Number(level) || 0));
        for (const line of lines.values()) {
            if (line.rx && line.bus) line.bus.gain.setTargetAtTime(rxLevel, ctx().currentTime, 0.05);
        }
    }

    /** The call volume (0 to 1), the player's own: every line but the radio's. */
    function setCallVolume(level) {
        callLevel = Math.max(0, Math.min(1, Number(level) || 0));
        for (const line of lines.values()) {
            if (!line.rx && line.bus) line.bus.gain.setTargetAtTime(callLevel, ctx().currentTime, 0.05);
        }
    }

    return { open, close, trackOf, add, remove, setLive, setQuality, setVia, setLevel, clear, setRxVolume, setCallVolume,
        speakerNode, speakerLive, forgetSpeaker, keyOf,
        ids: () => [...voices.keys()], has: (token, id) => voices.has(keyOf(token, id)),
        _lines: lines, _voices: voices, _speakers: speakers,
        _bus: (token) => { const l = lines.get(token); return l && l.bus ? l.bus.gain.value : null; } };
})();
