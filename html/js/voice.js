// The connection to the voice server (LiveKit). The game (client/main.lua) tells this page what to do:
//   connect {url, token, quality, noiseSuppression, radioKbps, radioStatic, radioDistortion, sound}
//                                    join the voice room and publish the microphone (muted)
//   noiseSuppression {on}            the player switched background noise suppression (the microphone is taken again)
//   talk {on, radio}                 push-to-talk: open or close the microphone (radio: on the radio too)
//   allow {ids, kbps, radio}         who may hear this player normally, and on the radio (from the server)
//   hear {add, remove}               which voices to pick up (from the server), and the devices on speaker near
//                                    this player (speaker: true; see lines.js)
//   line {open, close, add, remove, q, via, level}
//                                    the voice lines this player hears: each line's sound, which voices to pick up on
//                                    it, their signal, where they come out (via: a device on speaker; none = their
//                                    own) and, picked up by a phone on speaker, how loud (lines.js)
//   pose {...}                       positions, for the 3D (audio.js)
//   volume {level} (the people around), radioVolume {level}, callVolume {level} (every other line)
//   disconnect
// and hears back through NUI callbacks: state {joined, speaking}, mic {state, detail},
// talkers {ids, live} (audio.js), disconnected {reason}.
//
// Nobody can hear this player until the server says who: the "allow nobody" list is sent before the microphone is
// published, then replaced by the server's list. This page only picks up voices on the server's lists.
//
// Two tracks: the microphone goes out twice, 'voice' (what people near you hear) and 'radio' (what your frequency
// hears, only while the radio key is held). Each listener is allowed only the tracks the server named for them, so
// someone on your frequency across the map gets your radio and never what you say normally.

'use strict';

(() => {
    const LK = window.LivekitClient;
    // LiveKit's own console lines: warnings and errors only. At its default it also prints "webrtc stats" every 30 s
    // while connected, which F8 shows as "[object Object]".
    try { LK.setLogLevel('warn'); } catch (e) { /* an older client without it */ }
    const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'whip_voice';
    const post = (name, data) => fetch('https://' + RES + '/' + name, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data || {}),
    }).catch(() => {});
    const VOICE = 'voice', RADIO = 'radio';   // the two tracks' names

    let room = null;
    let mic = null;            // the microphone, heard normally
    let radioMic = null;       // the same microphone, on the radio (a copy, muted separately)
    let voicePub = null, radioPub = null;
    let micStream = null;
    let micState = 'none';     // 'asking' (FiveM's permission box is up), 'granted', 'denied', 'ended', 'error'
    // THE MICROPHONE'S CLEAN-UP, done by Chromium before it is sent. Echo cancellation and auto volume are the
    // server's (Config.Quality); background noise suppression is each player's own (the pause menu's Server Settings).
    let micOpts = { echoCancellation: false, autoGainControl: false };
    let noise = true;          // background noise suppression wanted
    let micNoise = null;       // ...and as the microphone in use was taken
    const micConstraints = () => ({ ...micOpts, noiseSuppression: noise, channelCount: 1 });
    let talking = false;       // either key held
    let radioKey = false;      // the radio key held
    let allow = [], allowRadio = [];
    const hear = new Map();    // identity -> { src, range, fx, speaker }   voices near this player (and devices on speaker)
    const lineVoices = new Map();   // 'token/identity' -> { token, id, q, via, level }   voices on a line

    // WHO MAY HEAR WHICH TRACK, per listener. Until both tracks are out (their ids known) nobody.
    function applyAllow() {
        if (!room) return;
        const v = voicePub && voicePub.trackSid, r = radioPub && radioPub.trackSid;
        const by = new Map();
        if (v) for (const id of allow) by.set(id, [v]);
        if (r) for (const id of allowRadio) by.set(id, (by.get(id) || []).concat(r));
        room.localParticipant.setTrackSubscriptionPermissions(false,
            [...by.entries()].map(([id, sids]) => ({ participantIdentity: id, allowAll: false, allowedTrackSids: sids })));
    }

    // CROWD QUALITY: when a big crowd hears this player, the server asks for a lower quality (sent with
    // `allow`); the microphone's sending rate is changed on the spot — no reconnect, the voice just
    // carries on at the new rate. Back to the normal quality when the crowd thins. (The normal voice
    // only: the radio has its own low rate.)
    let baseKbps = 64;       // Config.Quality.bitrateKbps
    let radioKbps = 24;      // Config.Radio.bitrateKbps
    let crowdKbps = null;    // the server's crowd quality, or null
    let sentBps = null;      // what the microphone is set to now

    async function applyBitrate() {
        const sender = mic && mic.sender;
        if (!sender) return;                     // not sending yet: applied once published
        const bps = Math.round((crowdKbps || baseKbps) * 1000);
        if (bps === sentBps) return;
        const p = sender.getParameters();
        if (!p.encodings || !p.encodings.length) return;
        p.encodings[0].maxBitrate = bps;
        try { await sender.setParameters(p); sentBps = bps; } catch (_) { /* tried again on the next change */ }
    }

    /** A speaker's track by name ('voice' or 'radio'). */
    function publicationOf(id, name) {
        const p = room && room.remoteParticipants.get(id);
        if (!p) return null;
        for (const pub of p.audioTrackPublications.values()) if (pub.trackName === name) return pub;
        return null;
    }

    function pickUp(id, name) {
        const pub = publicationOf(id, name);
        if (pub && !pub.isSubscribed) pub.setSubscribed(true);
    }

    // ---- THE TRACK HUB ----------------------------------------------------------------------------
    //
    // ONE SUBSCRIPTION PER SPEAKER'S TRACK, HOWEVER MANY USES IT HAS HERE (7 Oct 2026, for voice
    // lines: someone near this player can also be on a call with them, one 'voice' track heard two
    // ways). The hub subscribes while anything here wants the track, plays it once — the muted
    // element Chromium needs to feed a voice into Web Audio at all (crbug 933677), its source, and a
    // silent drain that keeps the sound flowing while no chain is plugged in (unpulled, it would pile
    // up in the browser's buffer and play late) — and hands the one source to each use.
    //
    // A use is { add(source, live), remove(), live(on) }: the hub calls add when the track arrives
    // (or at once, when it is already here), live on each push-to-talk edge, remove when the track goes
    // or the use is given up. Nothing outside the hub subscribes or lets go.
    const tracks = new Map();   // 'identity/name' -> { id, name, uses: Map(key -> use), track, el, source, drain }
    const keyOf = (id, name) => id + '/' + name;
    const holder = document.createElement('div');   // the muted <audio> elements
    holder.style.display = 'none';
    document.body.appendChild(holder);

    /** Play an arrived track once, for every use of it. */
    function media(t, track) {
        const c = VoiceAudio.context();
        const el = track.attach();
        el.muted = true;
        el.volume = 0;
        holder.appendChild(el);
        el.play().catch(() => {});
        const source = c.createMediaStreamSource(new MediaStream([track.mediaStreamTrack]));
        const drain = c.createGain();
        drain.gain.value = 0;
        source.connect(drain);
        drain.connect(c.destination);
        t.track = track; t.el = el; t.source = source; t.drain = drain;
    }

    /** Stop playing it (every use has been told to remove first). */
    function unmedia(t) {
        if (t.source) { try { t.source.disconnect(); } catch (_) { /* gone */ } }
        if (t.drain) { try { t.drain.disconnect(); } catch (_) { /* gone */ } }
        if (t.el) {
            try { t.track.detach(t.el); } catch (_) { /* gone */ }
            t.el.srcObject = null;
            t.el.remove();
        }
        t.track = t.el = t.source = t.drain = null;
    }

    /** Every use of the track is told it went (it may come back: the uses still want it). */
    function dropMedia(t) {
        for (const use of t.uses.values()) use.remove();
        unmedia(t);
    }

    /** `key` wants this speaker's track. Asking again with the same key changes nothing (a use reads
     *  what it needs when the track arrives). */
    function want(id, name, key, use) {
        const k = keyOf(id, name);
        let t = tracks.get(k);
        if (!t) { t = { id, name, uses: new Map(), track: null, el: null, source: null, drain: null }; tracks.set(k, t); }
        if (!t.uses.has(key)) {
            t.uses.set(key, use);
            if (t.source) { const pub = publicationOf(id, name); use.add(t.source, !!pub && !pub.isMuted); }
        }
        pickUp(id, name);
    }

    /** `key` no longer wants it: that use goes, and with the last use the subscription too. */
    function unwant(id, name, key) {
        const k = keyOf(id, name);
        const t = tracks.get(k);
        if (!t || !t.uses.has(key)) return;
        const use = t.uses.get(key);
        t.uses.delete(key);
        use.remove();
        if (t.uses.size > 0) return;
        unmedia(t);
        tracks.delete(k);
        const pub = publicationOf(id, name);
        if (pub && pub.isSubscribed) pub.setSubscribed(false);
    }

    /** A voice near this player (the hear list), on the normal 3D chain. */
    function hearUse(id) {
        return {
            add: (source, on) => {
                const h = hear.get(id);
                VoiceAudio.add(id, source, h ? h.range : 8, on);
                if (h && h.full) VoiceAudio.setRange(id, h.range, h.full);   // (a world voice's own full-volume circle)
                VoiceAudio.setFx(id, h ? h.fx : null);
            },
            remove: () => VoiceAudio.remove(id),
            live: (on) => VoiceAudio.setLive(id, on),
        };
    }

    /** A voice on a line (the line list), on that line's chain (lines.js). */
    function lineUse(token, id) {
        const key = VoiceLines.keyOf(token, id);
        return {
            add: (source, on) => {
                const e = lineVoices.get(key);
                VoiceLines.add(token, id, source, e ? e.q : 1, e ? e.via : null, e ? e.level : 1);
                if (on) VoiceLines.setLive(token, id, true);
            },
            remove: () => VoiceLines.remove(token, id),
            live: (on) => VoiceLines.setLive(token, id, on),
        };
    }

    function stopMic() {
        micState = 'none';
        if (micStream) for (const t of micStream.getTracks()) t.stop();
        if (radioMic && radioMic.mediaStreamTrack) radioMic.mediaStreamTrack.stop();
        micStream = null;
        mic = null;
        radioMic = null;
        voicePub = null;
        radioPub = null;
        sentBps = null;
    }

    function forgetAll() {
        for (const t of tracks.values()) dropMedia(t);
        tracks.clear();
        hear.clear();
        lineVoices.clear();
        allow = [];
        allowRadio = [];
        crowdKbps = null;
        VoiceAudio.clear();
        VoiceLines.clear();
    }

    async function disconnect() {
        const r = room;
        room = null;
        forgetAll();
        stopMic();
        if (r) { try { await r.disconnect(); } catch (_) { /* gone already */ } }
    }

    async function connect(m) {
        await disconnect();
        const q = m.quality || {};
        micOpts = { echoCancellation: !!q.echoCancellation, autoGainControl: q.autoGain !== false };
        noise = m.noiseSuppression !== false;
        baseKbps = Number(q.bitrateKbps) || 64;
        radioKbps = Number(m.radioKbps) || 24;
        VoiceFx.setSchema(m.blocks, m.blockLimits);      // what a sound recipe may be made of
        silentWhenQuiet = q.silentWhenQuiet === true;
        VoiceAudio.setFullWithin(m.fullWithin);
        VoiceAudio.setSound(m.sound);
        const r = new LK.Room({ adaptiveStream: false, dynacast: false, webAudioMix: false });
        room = r;

        const wanted = (pub, participant) => {
            const t = tracks.get(keyOf(participant.identity, pub.trackName));
            return t && t.uses.size > 0 ? t : null;
        };
        r.on(LK.RoomEvent.TrackPublished, (pub, participant) => {
            if (pub.kind === 'audio' && wanted(pub, participant)) pub.setSubscribed(true);
        });
        r.on(LK.RoomEvent.TrackSubscribed, (track, pub, participant) => {
            const t = track.kind === 'audio' ? wanted(pub, participant) : null;
            if (!t) { pub.setSubscribed(false); return; }      // not ours to hear
            if (t.track === track && t.source) return;          // (told twice)
            if (t.source) dropMedia(t);                          // a new copy of the track: the old one goes
            media(t, track);
            for (const use of t.uses.values()) use.add(t.source, !pub.isMuted);
        });
        // PUSH-TO-TALK, AS THE VOICE SERVER TELLS IT: a speaker's microphone is muted until they press
        // the key. Their voice is only mixed while they are live (audio.js / radio.js setLive).
        const live = (pub, participant, on) => {
            if (participant === r.localParticipant || pub.kind !== 'audio') return;
            const t = wanted(pub, participant);
            if (t && t.source) for (const use of t.uses.values()) use.live(on);
        };
        r.on(LK.RoomEvent.TrackUnmuted, (pub, participant) => live(pub, participant, true));
        r.on(LK.RoomEvent.TrackMuted, (pub, participant) => live(pub, participant, false));
        // Gone for now (the speaker stopped allowing this player, a reconnect): every use hears it went,
        // and the hub keeps wanting it, so it comes back the moment it is allowed again.
        r.on(LK.RoomEvent.TrackUnsubscribed, (track, pub, participant) => {
            const t = tracks.get(keyOf(participant.identity, pub.trackName));
            if (t) dropMedia(t);
        });
        r.on(LK.RoomEvent.ParticipantDisconnected, (participant) => {
            for (const t of tracks.values()) if (t.id === participant.identity) dropMedia(t);
        });
        r.on(LK.RoomEvent.Reconnected, () => {
            applyAllow();
            for (const t of tracks.values()) if (t.uses.size > 0) pickUp(t.id, t.name);
            sentBps = null;                  // the microphone may have been sent anew: set its rate again
            applyBitrate();
            if (silentWhenQuiet) { setUpstream(mic, talking); setUpstream(radioMic, radioKey); }
        });
        r.on(LK.RoomEvent.Disconnected, (reason) => {
            if (room !== r) return;          // an old room we already left
            room = null;
            forgetAll();
            stopMic();
            post('state', { joined: false, speaking: false });
            post('disconnected', { reason: String(reason) });
        });

        try {
            await r.connect(m.url, m.token, { autoSubscribe: false });
        } catch (e) {
            if (room === r) room = null;
            post('disconnected', { reason: 'could not reach the voice server: ' + (e && e.message || e) });
            return;
        }
        if (room !== r) return;              // replaced while connecting
        applyAllow();                        // nobody, until the server names who
        VoiceAudio.context();                // wake the audio now, not on the first voice
        post('state', { joined: true, speaking: false });

        // THE MICROPHONE. FiveM asks the player once; refusing still leaves them able to listen. A box left
        // unanswered never settles the request (it takes the mouse only with the F8 console open): after a while
        // the player is told how, and /voicecheck says so.
        micState = 'asking';
        const asked = setTimeout(() => { if (room === r && micState === 'asking') post('mic', { state: 'waiting' }); }, 15000);
        try {
            micNoise = noise;
            micStream = await navigator.mediaDevices.getUserMedia({ audio: micConstraints() });
        } catch (e) {
            clearTimeout(asked);
            if (room === r) micState = 'denied';
            post('mic', { state: 'denied', detail: (e && e.name) + ': ' + (e && e.message) });
            return;
        }
        clearTimeout(asked);
        if (room !== r) { stopMic(); return; }
        const track = micStream.getAudioTracks()[0];
        watchEnded(track, r);
        mic = new LK.LocalAudioTrack(track, undefined, true);
        radioMic = new LK.LocalAudioTrack(track.clone(), undefined, true);
        await mic.mute();                    // silent until push-to-talk
        await radioMic.mute();
        try {
            voicePub = await r.localParticipant.publishTrack(mic, {
                name: VOICE,
                source: LK.Track.Source.Microphone,
                dtx: true,                                        // silence costs almost nothing
                red: !!q.packetLossProtection,
                audioPreset: { maxBitrate: Math.round(baseKbps * 1000) },
            });
        } catch (e) {
            micState = 'error';
            post('mic', { state: 'error', detail: 'could not send the microphone: ' + (e && e.message || e) });
            return;
        }
        try {
            radioPub = await r.localParticipant.publishTrack(radioMic, {
                name: RADIO,
                source: LK.Track.Source.Microphone,
                dtx: true,
                red: false,
                audioPreset: { maxBitrate: Math.round(radioKbps * 1000) },
            });
        } catch (e) {
            radioPub = null;                 // the radio will not send; normal voice still works
        }
        applyAllow();                        // now with the tracks' ids
        sentBps = Math.round(baseKbps * 1000);
        applyBitrate();                      // a crowd quality that arrived before the microphone did
        if (talking) await mic.unmute(); else if (silentWhenQuiet) await setUpstream(mic, false);
        if (radioKey) await radioMic.unmute(); else if (silentWhenQuiet) await setUpstream(radioMic, false);
        micState = 'granted';
        post('mic', { state: 'granted', detail: track.label || '' });
        post('state', { joined: true, speaking: true });
        queueSwap();                         // noise suppression switched while the microphone was being asked for
    }

    /** The microphone unplugged or taken by another program (not one this page stopped: that says nothing). */
    function watchEnded(track, r) {
        track.addEventListener('ended', () => {
            if (room !== r || !micStream || micStream.getAudioTracks()[0] !== track) return;
            micState = 'ended';
            post('mic', { state: 'ended', detail: 'the microphone was unplugged or taken' });
        });
    }

    // NOISE SUPPRESSION SWITCHED MID-GAME (the pause menu's Server Settings). Chromium cannot change a live
    // microphone's clean-up (applyConstraints refuses), so the microphone is taken again with the new setting and put
    // in place of the old on both tracks: no rejoin, push-to-talk and the bitrate carry on as they were. FiveM
    // remembers the player's yes to the microphone, so no box comes up again. One swap at a time; a switch made
    // during one is caught up after.
    let micSwap = Promise.resolve();
    const queueSwap = () => { micSwap = micSwap.then(swapMic, swapMic); };

    async function swapMic() {
        const r = room, m0 = mic, rm0 = radioMic;
        if (!r || !m0 || !rm0 || micState !== 'granted' || micNoise === noise) return;   // a join takes it as it is
        const want = noise;
        // LET GO FIRST. While any track of the microphone still runs (the radio's copy too), Chromium 144+ answers a
        // new ask with the microphone already open, clean-up and all (tested 27 Oct 2026: Chrome 152 does, 103
        // does not). The player is silent for as long as the ask takes.
        if (micStream) for (const t of micStream.getTracks()) t.stop();
        if (rm0.mediaStreamTrack) rm0.mediaStreamTrack.stop();
        let stream;
        try {
            stream = await navigator.mediaDevices.getUserMedia({ audio: micConstraints() });
        } catch (e) {
            if (room === r && mic === m0) {
                micState = 'error';
                post('mic', { state: 'error', detail: 'could not take the microphone again: ' + (e && e.name) + ': ' + (e && e.message) });
            }
            return;
        }
        const track = stream.getAudioTracks()[0];
        if (room !== r || mic !== m0) { track.stop(); return; }    // left voice meanwhile
        const radioTrack = track.clone();
        micStream = stream;
        micNoise = want;
        watchEnded(track, r);
        try {
            await m0.replaceTrack(track, true);
            await rm0.replaceTrack(radioTrack, true);
        } catch (_) { /* unpublished meanwhile: the next join takes the microphone afresh */ }
        if (rm0.mediaStreamTrack !== radioTrack) radioTrack.stop();
        if (room !== r || mic !== m0) { track.stop(); radioTrack.stop(); }   // left voice during the swap
    }

    // NOTHING SENT WHILE THE KEY IS UP (Config.Quality.silentWhenQuiet, off by default). Muted, the
    // microphone still sends a tiny "silence" packet about five times a second to everyone connected
    // to it. With the setting on, sending is switched off while the key is up and back on at the press
    // (no renegotiation). Measured 29 Sep 2026 (private voice server, press to sound, 10 presses each):
    // off median 65 ms, on median 93 ms; taking the microphone off the connection instead was worse
    // (114-128 ms). The saving: about a tenth of the voice server's work at the biggest crowds.
    let silentWhenQuiet = false;

    function setUpstream(t, on) {
        const sender = t && t.sender;
        if (!sender) return Promise.resolve();
        const p = sender.getParameters();
        if (!p.encodings || !p.encodings.length || p.encodings[0].active === on) return Promise.resolve();
        p.encodings[0].active = on;
        return sender.setParameters(p).catch(() => {});
    }

    function open(t, on) {
        if (!t) return;
        if (on) {
            if (silentWhenQuiet) setUpstream(t, true);
            t.unmute();
        } else {
            t.mute();
            if (silentWhenQuiet) setUpstream(t, false);
        }
    }

    /** Push-to-talk. `on`: either key held (the people near you hear you); `radioOn`: the radio key
     *  (your frequency hears you too). The radio beeps for this player as well — unless the 3D radio is
     *  on their screen, which beeps itself (radio.js setOwnBeeps). */
    function setTalk(on, radioOn) {
        talking = !!on;
        const wantRadio = talking && !!radioOn;
        const clicked = wantRadio !== radioKey;
        radioKey = wantRadio;
        open(mic, talking);
        open(radioMic, radioKey);
        if (clicked && radioPub && VoiceRadio.ownBeeps()) VoiceRadio.click(radioKey ? 'up' : 'down');
    }

    function onHear(m) {
        for (const e of m.add || []) {
            if (!e || !e.id) continue;
            if (e.speaker) {
                // A device on speaker: no track to pick up — what comes out of it is played into its
                // node by lines.js, and placed in 3D like a voice from here on.
                hear.set(e.id, { src: e.src, range: e.range, fx: null, speaker: true });
                if (VoiceAudio.has(e.id)) VoiceAudio.setRange(e.id, e.range);
                else VoiceAudio.addInput(e.id, VoiceLines.speakerNode(e.id), e.range);
                if (VoiceLines.speakerLive(e.id)) VoiceAudio.setLive(e.id, true);
                continue;
            }
            hear.set(e.id, { src: e.src, range: e.range, fx: e.fx || null, full: e.full || 0 });
            VoiceAudio.setRange(e.id, e.range, e.full);
            VoiceAudio.setFx(e.id, e.fx || null);      // the megaphone, or none
            want(e.id, VOICE, 'hear', hearUse(e.id));
        }
        for (const id of m.remove || []) {
            const h = hear.get(id);
            hear.delete(id);
            if (h && h.speaker) {
                VoiceAudio.remove(id);
                VoiceLines.forgetSpeaker(id);
            } else {
                unwant(id, VOICE, 'hear');
            }
        }
    }

    /** Let go of one voice on a line (its use of the talker's track first). */
    function dropLineVoice(token, id) {
        const key = VoiceLines.keyOf(token, id);
        if (!lineVoices.has(key)) return;
        lineVoices.delete(key);
        const track = VoiceLines.trackOf(token);
        if (track) unwant(id, track, 'line:' + token);
        VoiceLines.remove(token, id);
    }

    // Lua's lists can arrive as objects ({"1": ...}) when empty or sparse: read either.
    const list = (x) => (Array.isArray(x) ? x : x && typeof x === 'object' ? Object.values(x) : []);

    function onLine(m) {
        // The lines first (each told before its first voice), then out before in (a voice moved to
        // another line, another sound), then what changed, then the lines nothing comes from any more.
        for (const l of list(m.open)) VoiceLines.open(l);
        for (const e of list(m.remove)) if (e && e.id && e.line) dropLineVoice(e.line, e.id);
        for (const e of list(m.add)) {
            if (!e || !e.id || !e.line) continue;
            const track = VoiceLines.trackOf(e.line);
            if (!track) continue;                                  // a line never told of: not ours to hear
            const key = VoiceLines.keyOf(e.line, e.id);
            lineVoices.set(key, { token: e.line, id: e.id, q: e.q, via: e.via || null, level: typeof e.level === 'number' ? e.level : 1 });
            VoiceLines.setQuality(e.line, e.id, e.q);
            VoiceLines.setVia(e.line, e.id, e.via || null);       // (only if it is already playing)
            want(e.id, track === 'radio' ? RADIO : VOICE, 'line:' + e.line, lineUse(e.line, e.id));
        }
        for (const e of list(m.q)) {
            const r = e && lineVoices.get(VoiceLines.keyOf(e.line, e.id));
            if (r) { r.q = e.q; VoiceLines.setQuality(e.line, e.id, e.q); }
        }
        // Heard from somewhere else now: their own device, or another device on speaker.
        for (const e of list(m.via)) {
            const r = e && lineVoices.get(VoiceLines.keyOf(e.line, e.id));
            if (r) { r.via = e.via || null; VoiceLines.setVia(e.line, e.id, r.via); }
        }
        for (const e of list(m.level)) {
            const r = e && lineVoices.get(VoiceLines.keyOf(e.line, e.id));
            if (r) { r.level = e.level; VoiceLines.setLevel(e.line, e.id, e.level); }
        }
        for (const token of list(m.close)) {
            for (const r of [...lineVoices.values()]) if (r.token === token) dropLineVoice(token, r.id);
            VoiceLines.close(token);
        }
    }

    // A press or release missed (a reconnect in between) is put right within a quarter of a second.
    setInterval(() => {
        if (!room) return;
        for (const t of tracks.values()) {
            if (!t.source) continue;
            const pub = publicationOf(t.id, t.name);
            if (pub) for (const use of t.uses.values()) use.live(!pub.isMuted);
        }
    }, 250);

    // /VOICECHECK (server/check.lua): how this game reaches the voice server. UDP is the good way; TCP means
    // UDP is blocked somewhere (the host's firewall, if it is everyone), and voice can stutter. Read from the
    // microphone's own connection, as the go/no-go test read it.
    async function probe(nonce) {
        let transport = 'unknown', rtt = 0;
        try {
            const report = mic && mic.getRTCStatsReport ? await mic.getRTCStatsReport() : null;
            if (report) {
                let pair = null;
                report.forEach((s) => { if (s.type === 'transport' && s.selectedCandidatePairId) pair = report.get(s.selectedCandidatePairId); });
                if (!pair) report.forEach((s) => { if (s.type === 'candidate-pair' && s.nominated && s.state === 'succeeded') pair = s; });
                const local = pair ? report.get(pair.localCandidateId) : null;
                if (local) transport = local.candidateType === 'relay' ? 'relay' : (local.protocol === 'udp' || local.protocol === 'tcp') ? local.protocol : 'unknown';
                if (pair && pair.currentRoundTripTime !== undefined) rtt = Math.round(pair.currentRoundTripTime * 1000);
            }
        } catch (e) { /* unknown */ }
        post('probe', { nonce, transport, rtt, mic: micState });
    }

    window.addEventListener('message', (event) => {
        const m = event.data || {};
        switch (m.action) {
            case 'probe': probe(m.nonce); break;
            case 'connect': connect(m); break;
            case 'disconnect': disconnect(); break;
            case 'noiseSuppression': noise = m.on !== false; queueSwap(); break;
            case 'talk': setTalk(!!m.on, !!m.radio); break;
            case 'allow':
                allow = Array.isArray(m.ids) ? m.ids : [];
                allowRadio = Array.isArray(m.radio) ? m.radio : [];
                applyAllow();
                crowdKbps = Number(m.kbps) > 0 ? Number(m.kbps) : null;
                applyBitrate();
                break;
            case 'hear': onHear(m); break;
            case 'line': onLine(m); break;
            case 'pose': VoiceAudio.pose(m); break;
            case 'volume': VoiceAudio.volume(m.level); break;
            case 'radioVolume': VoiceRadio.volume(m.level); break;
            case 'callVolume': VoiceLines.setCallVolume(m.level); break;
        }
    });

    // For the headless tests (dev only): read the state without reaching into the closure.
    window.__whipVoice = () => ({ joined: !!room, publishing: !!mic, talking, radioKey, allow: allow.slice(),
        allowRadio: allowRadio.slice(), hear: [...hear.keys()], lines: [...lineVoices.keys()],
        voices: [...VoiceAudio._voices.keys()], lineVoices: VoiceLines.ids(), radioTrack: !!radioPub,
        tracks: [...tracks.values()].map((t) => ({ key: keyOf(t.id, t.name), uses: [...t.uses.keys()], playing: !!t.source })),
        maxBitrate: mic && mic.sender ? (mic.sender.getParameters().encodings || [{}])[0].maxBitrate : null,
        micState, voiceSid: voicePub ? voicePub.trackSid : null,
        // What Chromium applied to the microphone each track sends now (not what was asked for).
        noise: mic && mic.mediaStreamTrack ? mic.mediaStreamTrack.getSettings().noiseSuppression : null,
        radioNoise: radioMic && radioMic.mediaStreamTrack ? radioMic.mediaStreamTrack.getSettings().noiseSuppression : null,
        micLive: mic && mic.mediaStreamTrack ? mic.mediaStreamTrack.readyState : null,
        radioLive: radioMic && radioMic.mediaStreamTrack ? radioMic.mediaStreamTrack.readyState : null });
    // (dev) how much this player's microphone has sent ('voice' or 'radio'): bytes and packets so far.
    window.__whipVoiceSent = async (which) => {
        const t = which === RADIO ? radioMic : mic;
        let out = { bytes: 0, packets: 0 };
        if (t && t.sender) (await t.sender.getStats()).forEach((s) => { if (s.type === 'outbound-rtp') out = { bytes: s.bytesSent, packets: s.packetsSent }; });
        return out;
    };
})();
