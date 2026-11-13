// A pretend provider of any kind, for testing the agent with no account, no key and no cost: it hears a set
// line (or how long you spoke), replies with a set line (or "I heard you say ..."), and speaks with a tone.
//
//   { "driver": "fake", "kind": "stt",      "text": "can you tow my car", "delayMs": 50 }
//   { "driver": "fake", "kind": "llm",      "reply": "Sure thing. Two hundred bucks.", "delayMs": 5 }
//   { "driver": "fake", "kind": "tts",      "rate": 24000, "msPerChar": 60 }
//   { "driver": "fake", "kind": "realtime", "reply": "Yeah?", "delayMs": 50 }

import { EventEmitter } from 'node:events';
import { Vad } from '../vad.mjs';
import { LinearResampler } from '../audio.mjs';

export const NEEDS_KEY = false;
export function kindOf(spec) { return spec.kind; }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** A tone `ms` long: the fake voice. */
function tone(ms, rate, hz = 220) {
    const n = Math.round((ms / 1000) * rate);
    const out = new Int16Array(n);
    for (let i = 0; i < n; i++) out[i] = Math.round(Math.sin((2 * Math.PI * hz * i) / rate) * 8000);
    return out;
}

export function create(spec) {
    const delay = Math.max(0, Number(spec.delayMs) || 0);
    const terms = spec.terms && typeof spec.terms === 'object' ? spec.terms : {};

    if (spec.kind === 'stt') {
        return {
            inRate: 16000, terms,
            async transcribe(pcm, rate) {
                if (delay) await sleep(delay);
                const ms = Math.round((pcm.length / rate) * 1000);
                return { text: typeof spec.text === 'string' ? spec.text : `(${ms} ms of speech)`, usage: { audioInSec: pcm.length / rate } };
            },
        };
    }

    if (spec.kind === 'llm') {
        return {
            terms,
            async *chat({ system, messages, maxTokens, signal }) {
                const last = [...messages].reverse().find((m) => m.role === 'user');
                const reply = typeof spec.reply === 'string' ? spec.reply : `I heard you say: ${last ? last.content : 'nothing'}.`;
                const words = reply.split(/(\s+)/);
                let out = 0;
                for (const w of words) {
                    if (signal && signal.aborted) break;
                    if (delay) await sleep(delay);
                    out += 1;
                    if (maxTokens && out > maxTokens) break;
                    yield { text: w };
                }
                const inChars = system.length + messages.reduce((n, m) => n + m.content.length, 0);
                yield { usage: { inTokens: Math.ceil(inChars / 4), outTokens: Math.ceil(reply.length / 4) } };
            },
        };
    }

    if (spec.kind === 'tts') {
        const rate = Number(spec.rate) || 24000;
        const msPerChar = Number(spec.msPerChar) || 60;
        return {
            outRate: rate, terms,
            async *speak(text, { signal } = {}) {
                for (const word of text.split(/\s+/).filter(Boolean)) {
                    if (signal && signal.aborted) return;
                    if (delay) await sleep(delay);
                    yield tone(word.length * msPerChar, rate);
                    yield new Int16Array(Math.round(rate * 0.05));   // a gap between words
                }
            },
            usageOf(text) { return { chars: text.length }; },
        };
    }

    if (spec.kind === 'realtime') {
        return {
            inRate: 16000, outRate: 24000, terms,
            async open({ firstLine, signal } = {}) {
                const s = new EventEmitter();
                const vad = new Vad({ maxMs: 15000 });
                const up = new LinearResampler(16000, 48000);   // its sentence detector works at the room's frame size
                let buf = new Int16Array(0);
                let closed = false;
                const say = async (text) => {
                    if (delay) await sleep(delay);
                    if (closed) return;
                    s.emit('text', { who: 'npc', text });
                    s.emit('audio', tone(text.length * 60, 24000));
                };
                s.push = (pcm) => {
                    if (closed) return;
                    const more = up.push(pcm);
                    const all = new Int16Array(buf.length + more.length);
                    all.set(buf); all.set(more, buf.length);
                    let at = 0;
                    for (; at + 480 <= all.length; at += 480) {
                        const done = vad.push(all.slice(at, at + 480));
                        if (done) {
                            s.emit('text', { who: 'player', text: `(${done.frames.length * 10} ms of speech)` });
                            say(typeof spec.reply === 'string' ? spec.reply : 'Yeah? What do you want?');
                        }
                    }
                    buf = all.slice(at);
                };
                // The time a conversation is open is the session's to count (the same for every company that
                // bills by the minute); a driver reports only what else it is billed for.
                s.close = () => {
                    if (closed) return;
                    closed = true;
                    s.emit('end', 'closed');
                };
                if (signal) signal.addEventListener('abort', () => s.close(), { once: true });
                if (firstLine) setTimeout(() => say(firstLine), 0);
                return s;
            },
        };
    }

    throw new Error(`a fake provider must say its kind: stt, llm, tts or realtime (not "${spec.kind}")`);
}
