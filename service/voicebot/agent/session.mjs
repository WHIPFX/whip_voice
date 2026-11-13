// One conversation with one NPC: the players the FiveM server has put in it talk, the NPC answers.
//
//   Mode B   each player's voice -> sentences (vad.mjs) -> TEXT (an stt provider) -> the BRAIN (brains.mjs:
//            the owner's script, or a chat model) -> sentence by sentence to VOICE (a tts provider) -> out.
//            The first sentence is spoken while the model is still writing the next.
//   Mode A   each player's voice -> a REALTIME provider (it hears, thinks and speaks) -> out.
//
// Out is a queue of 10 ms frames at the voice room's rate; whoever plays it (the voice room, a test) takes
// them at its own pace (takeFrame). Nothing here knows the voice room, the FiveM server or any company.
//
// Limits, every conversation: a sentence longer than maxUtteranceMs is cut; a reply longer than
// maxReplyChars is cut at a word (and the model told to stop: no paying for words nobody hears); a
// conversation ends after maxSessionMs, or idleEndMs with nobody talking; the meter's daily cap stops it.
// One sentence is answered at a time: one said while the NPC is still answering waits (the latest only).
//
// Events (emit(type, data)): started, heard { speaker, text, cut, ms }, reply { text, cut, timing },
// speaking { on }, action { action, args }, usage { provider, usage, usd }, refused { why }, ended { why, usd }.

import { ROOM_RATE, ROOM_FRAME, Framer, concat, LinearResampler } from './audio.mjs';
import { Vad } from './vad.mjs';
import { makeBrain } from './brains.mjs';

// A sentence is done at . ! ? or … (and a closing quote or bracket after it), before a space or the end.
const SENTENCE_END = /[.!?…]["')\]]?(?=\s|$)/;
const SILENCE = new Int16Array(ROOM_FRAME);
const GAP_MS = 100;      // a player's audio this late: their microphone went quiet (push to talk let go)
const QUIET_MS = 300;    // the NPC has nothing to play this long: it has stopped speaking

export const LIMITS = { maxUtteranceMs: 15000, maxReplyChars: 200, maxSessionMs: 600000, idleEndMs: 30000 };

export class Session {
    /**
     * @param {object} o
     *   id, npc, mode ('A' | 'B'), speakers (identities who may talk to it), voice, persona { system, firstLine,
     *   script }, brain ('script' | 'llm'), reasoning, providers { stt, llm, tts, realtime }, limits, meter,
     *   emit(type, data), makeResampler(from, to) -> { push, flush, close }, now()
     */
    constructor(o) {
        this.id = o.id;
        this.npc = o.npc || '';
        this.mode = o.mode === 'A' ? 'A' : 'B';
        this.speakers = new Set(o.speakers || []);
        this.voice = o.voice || null;
        this.persona = o.persona || {};
        this.p = o.providers || {};
        this.limits = { ...LIMITS, ...(o.limits || {}) };
        this.meter = o.meter;
        this.emitTo = o.emit || (() => {});
        this.makeResampler = o.makeResampler || ((a, b) => new LinearResampler(a, b));
        this.now = o.now || Date.now;
        this.brainKind = o.brain || 'script';
        this.reasoning = o.reasoning || 'off';

        this.out = [];               // frames for the room
        this.emptySince = null;      // when the out queue last ran dry
        this.listening = new Map();  // speaker -> { vad, last }
        this.busy = false;           // a sentence is being answered
        this.waiting = null;         // the latest sentence said meanwhile
        this.speaking = false;
        this.endAfterSpeech = false;
        this.closed = false;
        this.usd = 0;
        this.abort = new AbortController();
        this.started = this.now();
        this.lastTalk = this.started;
        this.billedTo = this.started;    // Mode A: the open time counted so far
    }

    emit(type, data = {}) { this.emitTo(type, { session: this.id, ...data }); }

    use(provider, usage) {
        if (!provider || !usage) return;
        const usd = this.meter ? this.meter.add(provider, usage) : 0;
        this.usd += usd;
        this.emit('usage', { provider: provider.name, usage, usd });
    }

    async start() {
        if (this.mode === 'A') await this.startRealtime();
        else {
            this.brain = makeBrain({ kind: this.brainKind, persona: this.persona, llm: this.p.llm,
                maxReplyChars: this.limits.maxReplyChars, reasoning: this.reasoning });
            this.busy = true;
            this.respond(this.brain.greet(), this.now(), new AbortController())
                .catch((e) => this.emit('refused', { why: `greeting: ${e.message}` }))
                .finally(() => this.next());
        }
        this.emit('started', { mode: this.mode, brain: this.mode === 'B' ? this.brainKind : null });
    }

    // ------------------------------------------------------------ in: the players

    /** A 10 ms frame of a player's voice, from the room (anyone the server did not put in it is ignored). */
    hear(speaker, frame) {
        if (this.closed || !this.speakers.has(speaker)) return;
        const now = this.now();
        let l = this.listening.get(speaker);
        if (!l) { l = { vad: new Vad({ maxMs: this.limits.maxUtteranceMs }), last: now }; this.listening.set(speaker, l); }
        l.last = now;
        if (this.mode === 'A') {
            if (!this.rt) return;   // still connecting to the provider
            this.rt.push(this.rtIn.push(frame));
            if (l.vad.push(frame) || l.vad.speaking) this.lastTalk = now;
            return;
        }
        const done = l.vad.push(frame);
        if (l.vad.speaking) this.lastTalk = now;
        if (done) {
            this.lastTalk = now;
            this.queue({ speaker, frames: done.frames, cut: done.cut });
        }
    }

    /** A player's sentence as text (a test, or a typed line): skips the hearing. */
    hearText(speaker, text) {
        if (this.closed || this.mode === 'A') return false;
        this.lastTalk = this.now();
        this.queue({ speaker, text: String(text) });
        return true;
    }

    /** The NPC says this line as it is (the FiveM server's own line: a scripted moment, a test). */
    say(text) {
        if (this.closed || this.mode === 'A') return false;
        this.queue({ say: String(text) });
        return true;
    }

    queue(turn) {
        if (this.busy) { this.waiting = turn; return; }
        this.busy = true;
        this.answer(turn).catch((e) => this.emit('refused', { why: e.message })).finally(() => this.next());
    }

    next() {
        this.busy = false;
        const t = this.waiting;
        this.waiting = null;
        if (t && !this.closed) this.queue(t);
    }

    /** Called about every 100 ms by the host: microphones gone quiet, the conversation's time, the cap. */
    tick() {
        if (this.closed) return;
        const now = this.now();
        for (const [speaker, l] of this.listening) {
            // Push to talk let go mid-sentence: the room sends nothing, so the quiet is filled in to end it.
            if (!l.vad.speaking || now - l.last < GAP_MS) continue;
            const frames = Math.min(100, Math.floor((now - l.last) / 10));
            for (let i = 0; i < frames && l.vad.speaking; i++) {
                // Mode A: the provider hears the quiet too, or it would wait for the end of a sentence forever.
                if (this.mode === 'A' && this.rt) this.rt.push(this.rtIn.push(SILENCE));
                const done = l.vad.push(SILENCE);
                if (done && this.mode === 'B') this.queue({ speaker, frames: done.frames, cut: done.cut });
            }
            l.last = now;
        }
        if (this.mode === 'A' && this.p.realtime) {
            this.use(this.p.realtime, { sessionSec: (now - this.billedTo) / 1000 });
            this.billedTo = now;
        }
        if (this.meter && this.meter.over()) return this.close('the daily spending cap was reached');
        if (now - this.started > this.limits.maxSessionMs) return this.close('the conversation reached its time limit');
        const quiet = !this.busy && !this.speaking && !this.out.length;
        if (quiet && now - this.lastTalk > this.limits.idleEndMs) return this.close('nobody talked');
    }

    // ------------------------------------------------------------ Mode B: hear, think, speak

    async answer(turn) {
        if (this.meter && this.meter.over()) { this.emit('refused', { why: 'the daily spending cap was reached' }); return; }
        const t0 = this.now();
        if (turn.say != null) {
            await this.respond((async function* line() { yield { text: turn.say }; })(), t0, null);
            return;
        }
        let heard = turn.text;
        if (heard == null) {
            const stt = this.p.stt;
            const rate = stt.inRate || 16000;
            const rs = this.makeResampler(ROOM_RATE, rate);
            let pcm;
            try { pcm = concat([rs.push(concat(turn.frames)), rs.flush()]); } finally { rs.close(); }
            const r = await stt.transcribe(pcm, rate, { signal: this.abort.signal });
            this.use(stt, r.usage);
            heard = String(r.text || '').trim();
        }
        if (this.closed) return;
        this.emit('heard', { speaker: turn.speaker, text: heard, cut: !!turn.cut, ms: this.now() - t0 });
        if (!heard) return;
        const stop = new AbortController();
        this.abort.signal.addEventListener('abort', () => stop.abort(), { once: true });
        await this.respond(this.brain.reply(heard, { signal: stop.signal }), t0, stop);
    }

    /** A brain's reply spoken, sentence by sentence as it is written, held to the reply limit. */
    async respond(pieces, t0, stop) {
        const max = this.limits.maxReplyChars;
        let spoken = '', pending = '', cut = false, end = false;
        let firstText = null, firstAudio = null;
        let voice = Promise.resolve();
        const say = (text) => {
            const s = text.trim();
            if (!s) return;
            spoken += (spoken ? ' ' : '') + s;
            voice = voice.then(() => this.speak(s, () => { if (firstAudio == null) firstAudio = this.now() - t0; }));
        };
        for await (const piece of pieces) {
            if (this.closed) break;
            if (piece.usage) { this.use(this.p.llm, piece.usage); continue; }
            if (piece.action) { this.emit('action', { action: piece.action, args: piece.args || {} }); continue; }
            if (piece.end) { end = true; continue; }
            if (typeof piece.text !== 'string' || cut) continue;
            if (firstText == null) firstText = this.now() - t0;
            pending += piece.text;
            let m;
            while ((m = pending.match(SENTENCE_END))) {
                const at = m.index + m[0].length;
                const sentence = pending.slice(0, at);
                if (spoken.length + sentence.length > max) break;
                say(sentence);
                pending = pending.slice(at);
            }
            if (spoken.length + pending.trim().length > max) {
                // Too long: what fits, cut at a word, and the brain told to stop writing.
                const room = Math.max(0, max - spoken.length - 1);
                const fit = pending.slice(0, room);
                const word = fit.lastIndexOf(' ');
                say(word > 0 ? fit.slice(0, word) : fit);
                pending = '';
                cut = true;
                if (stop) stop.abort();
            }
        }
        if (!cut && pending.trim()) say(pending);
        await voice;
        if (cut && this.brain && this.brain.spoke) this.brain.spoke(spoken);
        if (!this.closed && spoken) {
            this.emit('reply', { text: spoken, cut, timing: { firstTextMs: firstText, firstAudioMs: firstAudio, totalMs: this.now() - t0 } });
        }
        if (end) this.endAfterSpeech = true;
    }

    /** One sentence to voice, into the out queue. */
    async speak(text, onFirst) {
        if (this.closed) return;
        const tts = this.p.tts;
        const rs = this.makeResampler(tts.outRate, ROOM_RATE);
        const framer = new Framer(ROOM_FRAME);
        let first = true;
        const put = (frames) => {
            if (!frames.length) return;
            if (first) { first = false; onFirst(); this.setSpeaking(true); }
            for (const f of frames) this.out.push(f);
        };
        try {
            for await (const chunk of tts.speak(text, { voice: this.voice, signal: this.abort.signal })) {
                if (this.closed) return;
                put(framer.push(rs.push(chunk)));
            }
            put(framer.push(rs.flush()));
            put(framer.flush());
        } finally {
            rs.close();
        }
        this.use(tts, tts.usageOf ? tts.usageOf(text) : { chars: text.length });
    }

    // ------------------------------------------------------------ Mode A: one realtime provider

    async startRealtime() {
        const rt = this.p.realtime;
        this.rtIn = this.makeResampler(ROOM_RATE, rt.inRate || 16000);
        this.rtOut = this.makeResampler(rt.outRate || 24000, ROOM_RATE);
        this.rtFramer = new Framer(ROOM_FRAME);
        this.rt = await rt.open({ system: this.persona.system || '', voice: this.voice, firstLine: this.persona.firstLine || '',
            signal: this.abort.signal });
        this.rt.on('audio', (pcm) => {
            if (this.closed) return;
            const frames = this.rtFramer.push(this.rtOut.push(pcm));
            if (frames.length) this.setSpeaking(true);
            for (const f of frames) this.out.push(f);
        });
        this.rt.on('text', (t) => {
            if (this.closed || !t || typeof t.text !== 'string') return;
            if (t.who === 'npc') this.emit('reply', { text: t.text, cut: false, timing: null });
            else this.emit('heard', { speaker: null, text: t.text, cut: false, ms: null });
        });
        this.rt.on('usage', (u) => this.use(rt, u));
        this.rt.on('action', (a) => { if (a && typeof a.action === 'string') this.emit('action', { action: a.action, args: a.args || {} }); });
        this.rt.on('end', (why) => this.close(`the provider ended it (${why})`));
    }

    // ------------------------------------------------------------ out

    setSpeaking(on) {
        if (this.speaking === on) return;
        this.speaking = on;
        this.emit('speaking', { on });
    }

    /**
     * The next 10 ms of the NPC's voice, or null (nothing to say just now). Speaking ends after QUIET_MS with
     * nothing to play and nothing being worked out (a realtime company's audio arrives in bursts: the mouth
     * does not flap shut between them).
     */
    takeFrame() {
        const f = this.out.shift();
        if (f) { this.emptySince = null; return f; }
        const now = this.now();
        if (this.emptySince == null) this.emptySince = now;
        if (this.speaking && !this.busy && now - this.emptySince >= QUIET_MS) this.setSpeaking(false);
        if (this.endAfterSpeech && !this.busy && !this.speaking) this.close('the NPC ended the conversation');
        return null;
    }

    close(why) {
        if (this.closed) return;
        if (this.mode === 'A' && this.p.realtime) {
            this.use(this.p.realtime, { sessionSec: (this.now() - this.billedTo) / 1000 });
            this.billedTo = this.now();
        }
        this.closed = true;
        this.abort.abort();
        if (this.rt) { try { this.rt.close(); } catch (_) { /* gone */ } }
        for (const r of [this.rtIn, this.rtOut]) if (r) r.close();
        this.out = [];
        if (this.speaking) { this.speaking = false; this.emit('speaking', { on: false }); }
        this.emit('ended', { why, usd: this.usd });
    }
}
