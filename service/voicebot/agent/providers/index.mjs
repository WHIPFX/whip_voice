// The provider plug-ins. Every AI company is one DRIVER file here; nothing else in the agent knows any of them.
// The server owner's config names providers (a driver, its model, which key) and the agent turns each into one
// of four kinds, each with one job:
//
//   stt       transcribe(pcm, rate) -> { text, usage }                 a finished sentence of a player's voice to text
//   llm       chat({ system, messages, maxTokens, reasoning, signal })  the NPC's reply, as it is written:
//               -> async iterable of { text } ... { usage }
//   tts       speak(text, { voice, signal })                           the NPC's voice, as it is made:
//               -> async iterable of Int16Array (at .outRate) ... then .usageOf(text)
//   realtime  open({ system, voice, firstLine, signal }) -> session    Mode A: hears, thinks and speaks in one:
//               session.push(pcm at .inRate); events 'audio' (Int16Array at .outRate), 'text' { who, text },
//               'usage', 'end'; close()
//
// A driver also says what its company's terms ask of players (`terms`: { minAge, notice }), so the FiveM side
// can ask for it, and how its use is measured (`usage`: audio seconds, characters, tokens, session seconds),
// which the meter prices from the owner's config. KEYS: read from the keys file by name, handed to the driver,
// and never listed, logged or sent anywhere but to the company they belong to.

import * as fake from './fake.mjs';

const DRIVERS = new Map([
    ['fake', fake],
]);

export const KINDS = ['stt', 'llm', 'tts', 'realtime'];

/** The drivers this service has. */
export function driverNames() { return [...DRIVERS.keys()]; }

/** Add a driver (the real ones register themselves from their own files; tests add their own). */
export function addDriver(name, mod) { DRIVERS.set(name, mod); }

/**
 * One provider from the owner's config: { driver, kind?, key?, model?, url?, voice?, price?, ... }.
 * Never throws: a provider that cannot work comes back { ready: false, why }.
 */
export function makeProvider(name, spec, keys) {
    const base = { name, kind: null, ready: false, why: null, price: {}, terms: {} };
    if (!spec || typeof spec !== 'object') return { ...base, why: 'not a provider' };
    const mod = DRIVERS.get(spec.driver);
    if (!mod) return { ...base, why: `no driver "${spec.driver}" (this service has: ${driverNames().join(', ')})` };
    const kind = mod.kindOf ? mod.kindOf(spec) : mod.KIND;
    if (!KINDS.includes(kind)) return { ...base, why: `the ${spec.driver} driver cannot be a "${spec.kind}"` };
    let key;
    if (mod.NEEDS_KEY) {
        key = typeof spec.key === 'string' ? keys[spec.key] : undefined;
        if (typeof key !== 'string' || !key) return { ...base, kind, why: `no key "${spec.key || '(none named)'}" in the keys file` };
    }
    try {
        const p = mod.create(spec, key);
        return Object.assign(p, {
            name, kind, ready: true, why: null,
            driver: spec.driver,
            price: spec.price && typeof spec.price === 'object' ? spec.price : {},
            terms: p.terms || mod.TERMS || {},
        });
    } catch (e) {
        return { ...base, kind, why: e.message };
    }
}

/** What a provider may be shown as (the FiveM side's list, the /whip page): never its key or settings. */
export function describe(p) {
    return { name: p.name, kind: p.kind, driver: p.driver || null, ready: p.ready, why: p.why, terms: p.terms || {} };
}
