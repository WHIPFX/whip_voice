// The AI NPC agent, inside the voice bot service: the providers (agent/providers/), the conversations
// (agent/session.mjs), what they cost (agent/meter.mjs), and the FiveM server's way in (HTTP, the voice bot's
// own token, 127.0.0.1 only). The FiveM side (whip_talk) decides everything about WHO and WHEN; this only does
// what it is asked, within the limits in config.json.
//
//   GET    /agent/providers                   { providers: [{ name, kind, driver, ready, why, terms }], drivers }
//   GET    /agent/usage                       today's spend { day, usd, cap, byProvider }
//   POST   /agent/reload                      the keys file and providers read again (no restart for a new key)
//   POST   /agent/sessions                    start a conversation (below)        -> { ok, terms }
//   POST   /agent/sessions/:id/hear           { speaker, text }  a player's line as text (tests; typed lines)
//   POST   /agent/sessions/:id/say            { text }           the NPC says this line as it is
//   DELETE /agent/sessions/:id                end it
//   GET    /agent/events?after=N&wait=MS      what happened since event N, waiting up to MS for something
//
// POST /agent/sessions { id, npc, mode: 'A'|'B', speakers: [identity], brain: 'script'|'llm', reasoning,
//   stt, llm, tts, realtime (provider names), voice, persona: { system, firstLine, script }, limits, record }
//   `terms` in the answer: what the providers' companies ask of players (the strictest of them), which the
//   FiveM side has made sure of before it starts one.
//
// config.json "agent": { maxSessions, dailyUsd, keysFile, recordDir, providers: { name: { driver, ... } } }.
// The KEYS FILE is JSON { "elevenlabs": "<key>", ... }: read here, given to the providers, never sent back,
// logged or written anywhere.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { makeProvider, describe, driverNames } from './providers/index.mjs';
import { Session, LIMITS } from './session.mjs';
import { Meter } from './meter.mjs';
import { ROOM_RATE, concat, wav } from './audio.mjs';

const ID = /^[A-Za-z0-9_-]{1,64}$/;
const IDENT = (s) => typeof s === 'string' && s.length > 0 && s.length <= 128;
const EVENTS_KEPT = 1000;
const TICK_MS = 100;
const LIMIT_RANGE = {
    maxUtteranceMs: [1000, 30000], maxReplyChars: [20, 1000], maxSessionMs: [10000, 3600000], idleEndMs: [5000, 600000],
};

function str(v, max) { return typeof v === 'string' && v.length <= max ? v : null; }

/** The strictest of the providers' terms: the highest minimum age, every notice. */
function termsOf(providers) {
    const t = { minAge: 0, notices: [] };
    for (const p of providers) {
        const pt = p.terms || {};
        if (Number(pt.minAge) > t.minAge) t.minAge = Number(pt.minAge);
        if (typeof pt.notice === 'string' && !t.notices.includes(pt.notice)) t.notices.push(pt.notice);
    }
    return t;
}

export class AgentHost {
    /**
     * @param {object} cfg       config.json's "agent" section
     * @param {object} o         { makeResampler, now, log, readKeys }: the service's (tests pass their own)
     */
    constructor(cfg, o = {}) {
        this.cfg = cfg || {};
        this.makeResampler = o.makeResampler;
        this.now = o.now || Date.now;
        this.log = o.log || ((s) => console.log(`[voicebot] agent: ${s}`));
        this.readKeys = o.readKeys || ((path) => JSON.parse(readFileSync(path, 'utf8')));
        this.maxSessions = Math.max(1, Math.min(200, Number(this.cfg.maxSessions) || 20));
        this.recordDir = typeof this.cfg.recordDir === 'string' && isAbsolute(this.cfg.recordDir) ? this.cfg.recordDir : null;
        this.meter = new Meter({ dailyUsd: this.cfg.dailyUsd, now: this.now });
        this.sessions = new Map();
        this.events = [];
        this.seq = 0;
        this.waiters = new Set();
        this.load();
        this.timer = setInterval(() => this.tick(), TICK_MS);
        if (this.timer.unref) this.timer.unref();
    }

    /** The keys file and the providers, (re)read. */
    load() {
        let keys = {};
        const path = this.cfg.keysFile;
        if (typeof path === 'string' && path) {
            try {
                const k = this.readKeys(path);
                if (k && typeof k === 'object') keys = k;
            } catch (e) {
                // Never the file's contents: only that it could not be read, and why in general terms.
                this.log(`the keys file could not be read (${e.code || 'not JSON'}): providers that need a key are off`);
            }
        }
        this.providers = new Map();
        const specs = this.cfg.providers && typeof this.cfg.providers === 'object' ? this.cfg.providers : {};
        for (const [name, spec] of Object.entries(specs)) {
            if (!ID.test(name)) { this.log(`provider "${name.slice(0, 40)}": a name is letters, numbers, - and _`); continue; }
            const p = makeProvider(name, spec, keys);
            this.providers.set(name, p);
            if (!p.ready) this.log(`provider ${name} is off: ${p.why}`);
        }
        keys = null;
        this.log(`${[...this.providers.values()].filter((p) => p.ready).length} of ${this.providers.size} providers ready`);
    }

    push(type, data) {
        this.seq += 1;
        this.events.push({ seq: this.seq, type, ...data });
        if (this.events.length > EVENTS_KEPT) this.events.splice(0, this.events.length - EVENTS_KEPT);
        for (const w of this.waiters) w();
    }

    tick() {
        for (const s of this.sessions.values()) {
            s.tick();
            if (!s.room) this.pump(s);
        }
    }

    /**
     * A conversation with no voice room yet plays out here, at real time, into its recording (when it asked
     * for one): how a test hears the NPC before the voice room is wired up.
     */
    pump(s) {
        const now = this.now();
        if (s.pumpAt == null) s.pumpAt = now;
        while (s.pumpAt <= now) {
            const f = s.takeFrame();
            if (f && s.recording) s.recording.push(f);
            s.pumpAt += 10;
        }
    }

    provider(name, kind) {
        if (name == null || name === '') return { error: `no ${kind} provider named` };
        const p = this.providers.get(name);
        if (!p) return { error: `no provider "${String(name).slice(0, 64)}"` };
        if (p.kind !== kind) return { error: `${name} is a ${p.kind} provider, not ${kind}` };
        if (!p.ready) return { error: `${name} is off: ${p.why}` };
        return { p };
    }

    /** Start a conversation. { ok, terms } or { ok: false, status, error }. */
    async start(b) {
        const no = (status, error) => ({ ok: false, status, error });
        if (!ID.test(b.id || '')) return no(400, 'id');
        if (this.sessions.has(b.id)) return no(409, 'that conversation is already going');
        if (this.sessions.size >= this.maxSessions) return no(429, `busy: ${this.maxSessions} conversations at once`);
        if (this.meter.over()) return no(429, 'the daily spending cap was reached');
        const mode = b.mode === 'A' ? 'A' : b.mode === 'B' ? 'B' : null;
        if (!mode) return no(400, 'mode is A or B');
        const speakers = Array.isArray(b.speakers) && b.speakers.length <= 16 && b.speakers.every(IDENT) ? b.speakers : null;
        if (!speakers) return no(400, 'speakers');
        const persona = b.persona && typeof b.persona === 'object' ? b.persona : {};
        if (persona.system != null && str(persona.system, 4000) == null) return no(400, 'persona.system: text, up to 4,000 characters');
        if (persona.firstLine != null && str(persona.firstLine, 300) == null) return no(400, 'persona.firstLine: text, up to 300 characters');
        const brain = mode === 'A' ? null : b.brain === 'llm' ? 'llm' : b.brain === 'script' ? 'script' : null;
        if (mode === 'B' && !brain) return no(400, 'brain is script or llm');

        const want = mode === 'A' ? [['realtime', b.realtime]]
            : [['stt', b.stt], ['tts', b.tts], ...(brain === 'llm' ? [['llm', b.llm]] : [])];
        const providers = {};
        for (const [kind, name] of want) {
            const r = this.provider(name, kind);
            if (r.error) return no(422, r.error);
            providers[kind] = r.p;
        }
        const limits = { ...LIMITS };
        for (const [k, [lo, hi]] of Object.entries(LIMIT_RANGE)) {
            const v = b.limits && Number(b.limits[k]);
            if (Number.isFinite(v)) limits[k] = Math.max(lo, Math.min(hi, v));
        }

        const s = new Session({
            id: b.id, npc: str(b.npc, 64) || '', mode, speakers, voice: str(b.voice, 128),
            persona: { system: persona.system || '', firstLine: persona.firstLine || '', script: persona.script },
            brain, reasoning: b.reasoning, providers, limits, meter: this.meter, now: this.now,
            makeResampler: this.makeResampler,
            emit: (type, data) => {
                this.push(type, data);
                if (type === 'ended') this.finish(s);
            },
        });
        if (b.record === true && this.recordDir) s.recording = [];
        this.sessions.set(s.id, s);
        try {
            await s.start();
        } catch (e) {
            this.sessions.delete(s.id);
            s.close(`could not start: ${e.message}`);
            return no(502, `could not start: ${e.message}`);
        }
        return { ok: true, terms: termsOf(Object.values(providers)) };
    }

    finish(s) {
        if (this.sessions.get(s.id) === s) this.sessions.delete(s.id);
        if (s.recording && s.recording.length && this.recordDir) {
            try {
                mkdirSync(this.recordDir, { recursive: true });
                const file = join(this.recordDir, `${s.id}.wav`);
                writeFileSync(file, wav(concat(s.recording), ROOM_RATE));
                this.push('recorded', { session: s.id, file });
            } catch (e) {
                this.log(`conversation ${s.id}: its recording could not be written (${e.code || e.message})`);
            }
        }
        s.recording = null;
    }

    /** Events after `after`, waiting up to `wait` ms for one. */
    async eventsAfter(after, wait) {
        const pick = () => this.events.filter((e) => e.seq > after);
        let got = pick();
        if (!got.length && wait > 0) {
            await new Promise((resolve) => {
                const done = () => { this.waiters.delete(done); clearTimeout(t); resolve(); };
                const t = setTimeout(done, wait);
                this.waiters.add(done);
            });
            got = pick();
        }
        return { seq: this.seq, events: got };
    }

    /**
     * One HTTP request under /agent (the caller has checked the token). Answers through send(res, code, body).
     */
    async handle(req, res, url, parts, readBody, send) {
        const m = req.method;
        if (m === 'GET' && parts[1] === 'providers' && parts.length === 2) {
            return send(res, 200, { ok: true, providers: [...this.providers.values()].map(describe), drivers: driverNames() });
        }
        if (m === 'GET' && parts[1] === 'usage' && parts.length === 2) return send(res, 200, { ok: true, ...this.meter.today() });
        if (m === 'POST' && parts[1] === 'reload' && parts.length === 2) {
            this.load();
            return send(res, 200, { ok: true, providers: [...this.providers.values()].map(describe) });
        }
        if (m === 'GET' && parts[1] === 'events' && parts.length === 2) {
            const after = Math.max(0, Number(url.searchParams.get('after')) || 0);
            const wait = Math.max(0, Math.min(25000, Number(url.searchParams.get('wait')) || 0));
            return send(res, 200, { ok: true, ...(await this.eventsAfter(after, wait)) });
        }
        if (parts[1] !== 'sessions') return send(res, 404, { ok: false, error: 'no such request' });
        if (m === 'POST' && parts.length === 2) {
            const r = await this.start(await readBody(req));
            return send(res, r.ok ? 200 : r.status, r.ok ? { ok: true, terms: r.terms } : { ok: false, error: r.error });
        }
        const s = this.sessions.get(parts[2]);
        if (!s) return send(res, 404, { ok: false, error: 'no such conversation' });
        if (m === 'DELETE' && parts.length === 3) {
            s.close('ended by the server');
            return send(res, 200, { ok: true, usd: s.usd });
        }
        if (m === 'POST' && parts[3] === 'hear' && parts.length === 4) {
            const b = await readBody(req);
            const text = str(b.text, 1000);
            if (text == null || !IDENT(b.speaker)) return send(res, 400, { ok: false, error: 'speaker and text' });
            if (!s.speakers.has(b.speaker)) return send(res, 403, { ok: false, error: 'that speaker is not in this conversation' });
            return send(res, s.hearText(b.speaker, text) ? 200 : 409, { ok: true });
        }
        if (m === 'POST' && parts[3] === 'say' && parts.length === 4) {
            const text = str((await readBody(req)).text, 1000);
            if (!text) return send(res, 400, { ok: false, error: 'text' });
            return send(res, s.say(text) ? 200 : 409, { ok: true });
        }
        return send(res, 404, { ok: false, error: 'no such request' });
    }

    /** Every conversation ended (the service stopping). */
    stop() {
        clearInterval(this.timer);
        for (const s of [...this.sessions.values()]) s.close('the service stopped');
    }
}
