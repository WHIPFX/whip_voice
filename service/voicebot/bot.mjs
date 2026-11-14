// whip_voice's voice bot: plays a recording INTO a voice line, as if someone on it were talking.
//
// One service speaks for every lore character (the Director's named NPCs): each call is a connection of its own to
// the voice room, so one character can be on many calls at once. The FiveM server (whip_voice) drives it over HTTP
// on 127.0.0.1 with a shared token, and signs each call's voice-room token itself, so this service holds no voice
// server secret.
//
//   POST   /calls               { id, url, token, audio?, allow, keep?, radio? }  join as that identity, get the recording (audio:
//                                                                   a link, or "file:<full path>"; none: one comes with
//                                                                   play), publish a muted 'voice' track -> { duration }
//                                                                   keep: a voice that stays (a lore character in the
//                                                                   world, whip_voice's world voices): many recordings,
//                                                                   kept until let go or 30 minutes unused
//                                                                   radio: a 'radio' track too (a world voice that can
//                                                                   go on a radio frequency), as a player's microphone
//   POST   /calls/:id/allow     { allow, radio? }                  who may hear it (identities), and who its radio
//                                                                   track; nobody else can
//   POST   /calls/:id/play      { audio? }                         plays it (or this recording instead, which stays
//                                                                   its recording) once someone allowed is listening; a
//                                                                   play while one is under way cuts that one off
//   GET    /calls/:id                                              { state, playedMs, duration }
//   DELETE /calls/:id                                              leave
//   GET    /health                                                 { ok, version, calls, max }
//
// LIKE A PLAYER'S VOICE (whip_voice/html/js/voice.js): the track is called 'voice', it allows nobody until the server
// says who, and it is muted except while it plays (the games mix a voice only while it is unmuted, as push-to-talk).
//
// RECORDINGS come only from the link starts in config.json (`audioLinks`, Fivemanage by default), a plain address
// after it, no redirects, or from an mp3/ogg/wav file on this machine that a FiveM resource ships ("file:<path>",
// whip_voice's "@resource/path"). Either way it is mp3, Ogg Vorbis, Ogg Opus or wav (DECODERS below). At most
// `maxBytes` and `maxSeconds`. Each one is read once and kept for the next call.
//
// config.json (written by whip_voice's setup wizard): listen, token, maxCalls, audioLinks, maxSeconds, maxBytes, and
// "agent" (optional): the AI NPCs (agent/index.mjs: its own requests under /agent, the same token). With no
// "agent", there are none and the service is the voice bot it always was.

import http from 'node:http';
import { readFileSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join, isAbsolute, basename } from 'node:path';
import { Room, RoomEvent, AudioSource, AudioFrame, AudioResampler, AudioResamplerQuality, LocalAudioTrack,
    TrackPublishOptions, TrackSource } from '@livekit/rtc-node';
import { FfiRequest, FfiResponse, livekitFfiRequest, SetTrackSubscriptionPermissionsRequest, ParticipantTrackPermission,
    LocalTrackMuteRequest } from '@livekit/rtc-ffi-bindings';
import audioType from 'audio-type';
import { AgentHost } from './agent/index.mjs';
import { concat } from './agent/audio.mjs';

const VERSION = '1.4.0';
const HERE = dirname(fileURLToPath(import.meta.url));
const RATE = 48000, FRAME = RATE / 100;          // 10 ms frames, mono, as the voice room's audio
// A RECORDING IS SENT AT RECORDING QUALITY. Left to LiveKit's default it went at a speech bitrate with DTX (which
// drops what it takes for silence: a breath, a soft word's end), and sounded thin next to the players (64 kbps,
// whip_voice config Quality.bitrateKbps). 96 kbps mono Opus is clean for a voice actor's or a TTS take; it costs
// only while a line plays. RED (a spare copy in the next packet) stays on against lost packets.
const AUDIO_KBPS = 96;
const PUBLISH = () => new TrackPublishOptions({ source: TrackSource.SOURCE_MICROPHONE,
    audioEncoding: { maxBitrate: BigInt(AUDIO_KBPS * 1000) }, dtx: false, red: true });
const LISTEN_WAIT_MS = 3000;                     // play once an allowed listener is subscribed, or after this
const JOIN_TIMEOUT_MS = 15000;
const BODY_MAX = 64 * 1024;

// ---------------------------------------------------------------- config

function loadConfig() {
    const path = process.env.WHIP_VOICEBOT_CONFIG || join(HERE, 'config.json');
    let c;
    try { c = JSON.parse(readFileSync(path, 'utf8')); } catch (e) {
        console.error(`[voicebot] cannot read ${path}: ${e.message}`);
        process.exit(1);
    }
    const [host, port] = String(c.listen || '127.0.0.1:7899').split(':');
    if (host !== '127.0.0.1' && host !== 'localhost') {
        console.error('[voicebot] listen must be on 127.0.0.1: only the FiveM server on this machine may drive it');
        process.exit(1);
    }
    if (typeof c.token !== 'string' || c.token.length < 24) {
        console.error('[voicebot] config.json needs a token of 24 characters or more (the setup wizard makes one)');
        process.exit(1);
    }
    const links = (Array.isArray(c.audioLinks) ? c.audioLinks : ['https://r2.fivemanage.com/'])
        .filter((s) => typeof s === 'string' && /^https:\/\/[A-Za-z0-9-]+\.[A-Za-z0-9.-]+(:\d{1,5})?\/[A-Za-z0-9\-._/]*$/.test(s));
    return {
        host, port: Number(port) || 7899, token: c.token,
        maxCalls: Math.max(1, Math.min(200, Number(c.maxCalls) || 30)),
        audioLinks: links,
        maxSeconds: Math.max(1, Math.min(600, Number(c.maxSeconds) || 120)),
        maxBytes: Math.max(64 * 1024, Math.min(64 * 1024 * 1024, Number(c.maxBytes) || 15 * 1024 * 1024)),
        cacheBytes: Math.max(0, Number(c.cacheBytes) || 200 * 1024 * 1024),
        agent: c.agent && typeof c.agent === 'object' ? c.agent : null,
    };
}
const CFG = loadConfig();

/**
 * The voice room's own sample-rate changer (better than the agent's plain one), behind the agent's three calls:
 * pieces of any size in, fed to it 10 ms at a time.
 */
function roomResampler(from, to) {
    if (from === to) return { push: (p) => Int16Array.from(p), flush: () => new Int16Array(0), close() {} };
    const rs = new AudioResampler(from, to, 1, AudioResamplerQuality.HIGH);
    const step = Math.max(1, Math.round(from / 100));
    let carry = new Int16Array(0);
    const out = (frames) => concat(frames.map((f) => Int16Array.from(f.data)));
    return {
        push(pcm) {
            const all = carry.length ? concat([carry, pcm]) : pcm;
            const frames = [];
            let at = 0;
            // Copies (slice), never views: see toPcm.
            for (; at + step <= all.length; at += step) {
                const part = all.slice(at, at + step);
                frames.push(...rs.push(new AudioFrame(part, from, 1, part.length)));
            }
            carry = all.slice(at);
            return out(frames);
        },
        flush() {
            const frames = [];
            if (carry.length) {
                const part = carry;
                carry = new Int16Array(0);
                frames.push(...rs.push(new AudioFrame(part, from, 1, part.length)));
            }
            frames.push(...rs.flush());
            return out(frames);
        },
        close() { rs.close(); },
    };
}

const agent = CFG.agent ? new AgentHost(CFG.agent, { makeResampler: roomResampler }) : null;

// ---------------------------------------------------------------- the native calls rtc-node does not wrap yet

function ffi(message) {
    return FfiResponse.fromBinary(livekitFfiRequest(new FfiRequest({ message }).toBinary())).message.value;
}

/** Who may hear this call's track: exactly these identities (everyone else is refused by the voice server). */
function setAllowed(call, identities, radio) {
    const sid = call.pub && call.pub.sid;
    if (!sid || !call.room.localParticipant) return;
    // Each identity: the voice track if it is on `identities`, the radio track if on `radio` (as a player's page does).
    const rsid = call.radioPub && call.radioPub.sid;
    const tracks = new Map();
    for (const id of identities) tracks.set(id, [sid]);
    if (rsid) for (const id of radio || []) tracks.set(id, [...(tracks.get(id) || []), rsid]);
    ffi({ case: 'setTrackSubscriptionPermissions', value: new SetTrackSubscriptionPermissionsRequest({
        localParticipantHandle: call.room.localParticipant.ffi_handle.handle,
        allParticipantsAllowed: false,
        permissions: [...tracks].map(([id, sids]) => new ParticipantTrackPermission({ participantIdentity: id, allowAll: false, allowedTrackSids: sids })),
    }) });
}

/** Muted (silent, as a player off their talk key) or not. */
function setMuted(call, mute) {
    // Both tracks together: what it says goes out on the radio too while it is on a frequency (its radio track's
    // listeners are only the people on it).
    for (const t of [call.track, call.radioTrack]) {
        if (t) ffi({ case: 'localTrackMute', value: new LocalTrackMuteRequest({ trackHandle: t.ffi_handle.handle, mute }) });
    }
}

// ---------------------------------------------------------------- recordings

const cache = new Map();   // url -> { pcm: Int16Array (48 kHz mono), duration } (most recently used last)
let cacheBytes = 0;
const fetching = new Map(); // url -> Promise (one download for many calls at once)

function linkProblem(url) {
    if (typeof url !== 'string' || url.length > 255) return 'not a recording link';
    const start = CFG.audioLinks.find((s) => url.startsWith(s));
    if (!start) return 'only links starting with ' + CFG.audioLinks.join(' or ') + ' are accepted';
    const rest = url.slice(start.length);
    if (!rest || !/^[A-Za-z0-9\-._/]+$/.test(rest) || rest.includes('..')) return 'not a recording\'s address';
    return null;
}

async function download(url) {
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), 15000);
    try {
        const res = await fetch(url, { redirect: 'error', signal: ctl.signal });
        if (!res.ok) throw new Error(`the recording answered ${res.status}`);
        const len = Number(res.headers.get('content-length'));
        if (len && len > CFG.maxBytes) throw new Error(`the recording is over ${Math.round(CFG.maxBytes / 1048576)} MB`);
        const chunks = [];
        let got = 0;
        for await (const chunk of res.body) {
            got += chunk.length;
            if (got > CFG.maxBytes) throw new Error(`the recording is over ${Math.round(CFG.maxBytes / 1048576)} MB`);
            chunks.push(chunk);
        }
        return Buffer.concat(chunks);
    } finally {
        clearTimeout(timer);
    }
}

// THE FORMATS a recording may be in, each with its own decoder, loaded the first time one is needed. Only these four:
// @audio/decode, which reads every format there is, also brought in GPL decoders (AAC, AC-3, DTS) for formats no
// recording here needs. (The MP3 one, mpg123-decoder, says MIT but is libmpg123, LGPL-2.1, built to WebAssembly.)
// audio-type tells the four apart by their first bytes; its 'oga' is Ogg Vorbis (Ogg Opus is 'opus').
const DECODERS = {
    mp3: () => import('@audio/decode-mp3'),
    oga: () => import('@audio/decode-vorbis'),
    opus: () => import('@audio/decode-opus'),
    wav: () => import('@audio/decode-wav'),
};

async function decode(bytes) {
    // A copy, as its own ArrayBuffer: audio-type reads `.buffer` from the start, and a Node Buffer is often a view
    // into a bigger shared one.
    const data = new Uint8Array(bytes);
    const load = DECODERS[audioType(data)];
    if (!load) throw new Error('not a recording this can read (mp3, ogg or wav)');
    return (await load()).default(data);
}

/** The recording as 48 kHz mono 16-bit samples. */
async function toPcm(bytes) {
    const { channelData, sampleRate, samplesDecoded } = await decode(bytes);
    if (!channelData || !channelData.length || !sampleRate) throw new Error('not a recording this can read');
    // A decoder's buffers can run past what it decoded: only the decoded samples count.
    const n = Math.min(channelData[0].length, samplesDecoded ?? Infinity);
    if (n / sampleRate > CFG.maxSeconds) throw new Error(`the recording is over ${CFG.maxSeconds} seconds`);
    const mono = new Int16Array(n);
    for (let i = 0; i < n; i++) {
        let s = 0;
        for (const ch of channelData) s += ch[i];
        s /= channelData.length;
        mono[i] = Math.max(-32768, Math.min(32767, Math.round(s * 32767)));
    }
    if (sampleRate === RATE) return mono;
    const rs = new AudioResampler(sampleRate, RATE, 1, AudioResamplerQuality.HIGH);
    const out = [];
    const step = Math.max(1, Math.round(sampleRate / 100));
    try {
        for (let i = 0; i < n; i += step) {
            // A COPY (slice), never a view (subarray): an AudioFrame reads its array's buffer from the start, so a
            // view would hand it the first 10 ms every time (right length, a buzz at 100 Hz steps).
            const part = mono.slice(i, Math.min(n, i + step));
            for (const f of rs.push(new AudioFrame(part, sampleRate, 1, part.length))) out.push(Int16Array.from(f.data));
        }
        for (const f of rs.flush()) out.push(Int16Array.from(f.data));
    } finally {
        rs.close();
    }
    const total = out.reduce((a, d) => a + d.length, 0);
    const pcm = new Int16Array(total);
    let at = 0;
    for (const d of out) { pcm.set(d, at); at += d.length; }
    return pcm;
}

/** A recording kept by `key`: the cached one, or `load()` decoded once (for every call that asks meanwhile). */
async function remembered(key, load) {
    const hit = cache.get(key);
    if (hit) { cache.delete(key); cache.set(key, hit); return hit; }
    if (fetching.has(key)) return fetching.get(key);
    const p = (async () => {
        const pcm = await toPcm(await load());
        const rec = { pcm, duration: Math.round((pcm.length / RATE) * 1000) };
        cache.set(key, rec);
        cacheBytes += pcm.byteLength;
        for (const [k, v] of cache) {
            if (cacheBytes <= CFG.cacheBytes || k === key) break;
            cache.delete(k);
            cacheBytes -= v.pcm.byteLength;
        }
        return rec;
    })();
    fetching.set(key, p);
    try { return await p; } finally { fetching.delete(key); }
}

// A FILE ON THIS MACHINE: an audio file a FiveM resource ships ("@my_story/audio/line.ogg", which whip_voice turns
// into the file's full path). Only whip_voice can ask (the token), and only for an mp3, ogg or wav file.
const AUDIO_FILE = /\.(mp3|ogg|wav)$/i;

function fileProblem(path) {
    if (typeof path !== 'string' || path.length > 1024 || !isAbsolute(path)) return 'not a recording file';
    if (path.split(/[\\/]/).includes('..')) return 'not a recording file';
    if (!AUDIO_FILE.test(path)) return 'only mp3, ogg and wav files are played';
    return null;
}

async function fileRecording(path) {
    const bad = fileProblem(path);
    if (bad) throw new Error(bad);
    let st;
    try { st = await stat(path); } catch (e) {
        throw new Error(e.code === 'ENOENT' ? `there is no ${basename(path)}` : `${basename(path)} cannot be read (${e.code})`);
    }
    if (!st.isFile()) throw new Error(`${basename(path)} is not a file`);
    if (st.size > CFG.maxBytes) throw new Error(`the recording is over ${Math.round(CFG.maxBytes / 1048576)} MB`);
    // Changed on disk (same name, new take): decoded again.
    return remembered(`file:${path}#${st.size}-${st.mtimeMs}`, () => readFile(path));
}

/** A call's recording: "file:<full path>" (a resource's file), else a link. */
async function recording(audio) {
    if (typeof audio === 'string' && audio.startsWith('file:')) return fileRecording(audio.slice(5));
    const bad = linkProblem(audio);
    if (bad) throw new Error(bad);
    return remembered(audio, () => download(audio));
}

// ---------------------------------------------------------------- calls

const calls = new Map();   // id -> { id, room, source, track, pub, rec, state, allow, heard, playedMs, made, used, keep, gen }
const KEEP_IDLE_MS = 30 * 60000;   // a voice that stays goes after this long with nothing played

async function leave(call, why) {
    if (calls.get(call.id) === call) calls.delete(call.id);
    call.state = call.state === 'done' ? 'done' : 'gone';
    call.stop = true;
    try { await call.room.disconnect(); } catch (_) { /* gone already */ }
    if (why) console.log(`[voicebot] call ${call.id} ended: ${why}`);
}

async function startCall(b) {
    const call = { id: b.id, room: new Room(), state: 'joining', allow: b.allow, radioAllow: [], heard: false, playedMs: 0,
        made: Date.now(), used: Date.now(), keep: b.keep === true, gen: 0, rec: null };
    calls.set(call.id, call);
    try {
        const join = call.room.connect(b.url, b.token, { autoSubscribe: false, dynacast: false });
        const [rec] = await Promise.all([
            b.audio == null ? Promise.resolve(null) : recording(b.audio),
            Promise.race([join, new Promise((_, no) => setTimeout(() => no(new Error('the voice room did not answer')), JOIN_TIMEOUT_MS))]),
        ]);
        if (call.stop) throw new Error('ended while joining');
        call.rec = rec;
        call.source = new AudioSource(RATE, 1);
        call.track = LocalAudioTrack.createAudioTrack('voice', call.source);
        call.pub = await call.room.localParticipant.publishTrack(call.track, PUBLISH());
        if (b.radio) {
            // The same sound, as a second track: its listeners are the people on the radio frequency it is on.
            call.radioTrack = LocalAudioTrack.createAudioTrack('radio', call.source);
            call.radioPub = await call.room.localParticipant.publishTrack(call.radioTrack, PUBLISH());
        }
        setMuted(call, true);
        setAllowed(call, call.allow, call.radioAllow);
        call.room.on(RoomEvent.LocalTrackSubscribed, () => { call.heard = true; });
        call.room.on(RoomEvent.Disconnected, () => { if (calls.get(call.id) === call) leave(call, 'the voice room let go'); });
        call.state = 'ready';
        return { ok: true, duration: rec ? rec.duration : 0 };
    } catch (e) {
        await leave(call, null);
        throw e;
    }
}

/** Play its recording. Another play while this one is under way cuts it off (its `gen` moves on).
 *  ONE FEEDS THE SOURCE AT A TIME. The cut one's queued audio is dropped at once (clearQueue), and the new one
 *  starts when the cut one has stopped feeding: two captureFrame loops on one source at once is the RtcError
 *  "InvalidState - failed to capture frame", which ended the call, so the new line never played (Josh, 27 Oct:
 *  aiming at Dundee while he was still talking). */
async function play(call) {
    const gen = ++call.gen;
    const cut = () => call.stop || call.gen !== gen;
    call.state = 'playing';
    call.playedMs = 0;
    call.used = Date.now();
    const before = call.feeding;
    let fed;
    call.feeding = new Promise((r) => { fed = r; });
    try {
        if (before) {
            try { call.source.clearQueue(); } catch (_) { /* nothing queued */ }
            await before;
        }
        if (cut()) return;
        const until = Date.now() + LISTEN_WAIT_MS;
        while (!call.heard && !cut() && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
        if (cut()) return;
        setMuted(call, false);
        const pcm = call.rec.pcm;
        for (let i = 0; i < pcm.length && !cut(); i += FRAME) {
            // A copy of each 10 ms (see toPcm: a view would send the recording's first 10 ms over and over); the
            // last one padded with silence.
            const data = new Int16Array(FRAME);
            data.set(pcm.subarray(i, Math.min(pcm.length, i + FRAME)));
            await call.source.captureFrame(new AudioFrame(data, RATE, 1, FRAME));
            call.playedMs = Math.round(((i + FRAME) / RATE) * 1000);
        }
        if (!cut()) await call.source.waitForPlayout();
        if (!cut()) { setMuted(call, true); call.state = 'done'; call.used = Date.now(); }
    } finally {
        fed();
        if (call.feeding && gen === call.gen) call.feeding = null;
    }
}

// Nothing is left behind: a call nobody ended goes after its recording's length and three minutes more; a voice
// that stays, after KEEP_IDLE_MS with nothing played.
setInterval(() => {
    const now = Date.now();
    for (const call of calls.values()) {
        if (call.keep) { if (call.state !== 'playing' && now - call.used > KEEP_IDLE_MS) leave(call, 'left over'); continue; }
        const life = (call.rec ? call.rec.duration : 0) + 180000;
        if (now - call.made > life) leave(call, 'left over');
    }
}, 10000).unref();

// ---------------------------------------------------------------- HTTP (127.0.0.1 only)

const TOKEN = Buffer.from('Bearer ' + CFG.token);

function authorised(req) {
    const got = Buffer.from(String(req.headers.authorization || ''));
    return got.length === TOKEN.length && timingSafeEqual(got, TOKEN);
}

function send(res, code, body) {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body));
}

function readBody(req) {
    return new Promise((ok, no) => {
        let size = 0;
        const parts = [];
        req.on('data', (c) => {
            size += c.length;
            if (size > BODY_MAX) { no(new Error('too big')); req.destroy(); return; }
            parts.push(c);
        });
        req.on('end', () => {
            if (!size) return ok({});
            try { ok(JSON.parse(Buffer.concat(parts).toString('utf8'))); } catch (_) { no(new Error('not JSON')); }
        });
        req.on('error', no);
    });
}

const ID = /^[A-Za-z0-9_-]{1,64}$/;
const IDENT = (s) => typeof s === 'string' && s.length > 0 && s.length <= 128;
function allowList(a) {
    if (!Array.isArray(a) || a.length > 64 || !a.every(IDENT)) return null;
    return [...new Set(a)];
}

const server = http.createServer(async (req, res) => {
    try {
        if (!authorised(req)) return send(res, 401, { ok: false, error: 'not authorised' });
        const url = new URL(req.url, 'http://local');
        const parts = url.pathname.split('/').filter(Boolean);
        if (req.method === 'GET' && url.pathname === '/health') {
            return send(res, 200, { ok: true, version: VERSION, calls: calls.size, max: CFG.maxCalls,
                agent: agent ? { conversations: agent.sessions.size, max: agent.maxSessions } : null });
        }
        if (parts[0] === 'agent') {
            if (!agent) return send(res, 404, { ok: false, error: 'the AI NPCs are not set up (config.json has no "agent")' });
            return await agent.handle(req, res, url, parts, readBody, send);
        }
        if (parts[0] !== 'calls') return send(res, 404, { ok: false, error: 'no such request' });

        if (req.method === 'POST' && parts.length === 1) {
            const b = await readBody(req);
            if (!ID.test(b.id || '')) return send(res, 400, { ok: false, error: 'id' });
            if (typeof b.url !== 'string' || !/^wss?:\/\//.test(b.url)) return send(res, 400, { ok: false, error: 'url' });
            if (typeof b.token !== 'string' || b.token.length > 4096) return send(res, 400, { ok: false, error: 'token' });
            const allow = allowList(b.allow || []);
            if (!allow) return send(res, 400, { ok: false, error: 'allow' });
            if (calls.has(b.id)) return send(res, 409, { ok: false, error: 'that call is already up' });
            if (calls.size >= CFG.maxCalls) return send(res, 429, { ok: false, error: 'busy', max: CFG.maxCalls });
            if (b.audio != null && typeof b.audio !== 'string') return send(res, 400, { ok: false, error: 'audio' });
            try {
                return send(res, 200, await startCall({ id: b.id, url: b.url, token: b.token, audio: b.audio, allow, keep: b.keep === true,
                    radio: b.radio === true }));
            } catch (e) {
                return send(res, 422, { ok: false, error: e.message });
            }
        }

        const call = calls.get(parts[1]);
        if (!call) return send(res, 404, { ok: false, error: 'no such call' });
        if (req.method === 'GET' && parts.length === 2) {
            return send(res, 200, { ok: true, state: call.state, playedMs: call.playedMs, duration: call.rec ? call.rec.duration : null });
        }
        if (req.method === 'DELETE' && parts.length === 2) {
            await leave(call, null);
            return send(res, 200, { ok: true });
        }
        if (req.method === 'POST' && parts[2] === 'allow') {
            const b = await readBody(req);
            const allow = allowList(b.allow);
            const radio = allowList(b.radio || []);
            if (!allow || !radio) return send(res, 400, { ok: false, error: 'allow' });
            call.allow = allow;
            call.radioAllow = radio;
            if (call.state !== 'joining') setAllowed(call, allow, radio);
            return send(res, 200, { ok: true });
        }
        if (req.method === 'POST' && parts[2] === 'play') {
            const b = await readBody(req);
            // A call plays its recording once; a voice that stays plays as often as it is asked, any recording.
            const again = call.keep && (call.state === 'done' || call.state === 'playing');
            if (call.state !== 'ready' && !again) return send(res, 409, { ok: false, error: `the call is ${call.state}` });
            if (b.audio != null) {
                if (typeof b.audio !== 'string') return send(res, 400, { ok: false, error: 'audio' });
                try { call.rec = await recording(b.audio); } catch (e) { return send(res, 422, { ok: false, error: e.message }); }
                if (call.stop) return send(res, 409, { ok: false, error: 'the call ended' });
            }
            if (!call.rec) return send(res, 409, { ok: false, error: 'nothing to play: no recording yet' });
            play(call).catch((e) => {
                console.log(`[voicebot] call ${call.id} could not play: ${e.message}`);
                // A voice that stays (a lore character's) stays for its next line; a call has nothing more to do.
                if (call.keep && !call.stop) { setMuted(call, true); call.state = 'done'; call.used = Date.now(); }
                else leave(call, null);
            });
            return send(res, 200, { ok: true, duration: call.rec.duration });
        }
        return send(res, 404, { ok: false, error: 'no such request' });
    } catch (e) {
        return send(res, 500, { ok: false, error: e.message });
    }
});

server.listen(CFG.port, CFG.host, () => {
    console.log(`[voicebot] ${VERSION} listening on ${CFG.host}:${CFG.port}, at most ${CFG.maxCalls} calls, recordings from ${CFG.audioLinks.join(', ') || '(none)'}`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, async () => {
        if (agent) agent.stop();
        for (const call of [...calls.values()]) await leave(call, null);
        process.exit(0);
    });
}
