// How an NPC thinks, in Mode B (hear -> THINK -> speak). The server owner picks, per profile:
//
//   script   OUR OWN LOGIC, no AI model: the owner's lines, written in the Director. What the player says is
//            matched against each intent's phrases; the first that matches gives one of its lines (in turn,
//            so it does not repeat itself), and the action it names. Nothing else: it cannot be talked into
//            anything, and costs only the hearing and the (cached) voice.
//   llm      any chat model (a provider of kind 'llm'), with the persona as its instructions and the
//            conversation so far. `reasoning` ('off' | 'low' | 'high') is passed to models that think first.
//
// A brain's reply (reply(heard, { signal })) is an async iterable of pieces: { text } as it is written,
// { action, args } for something it wants done (the FiveM server decides), { usage, provider } for the meter,
// { end: true } to end the talk. The signal stops a reply part way (it ran past the length limit).

/** Lower case, letters and numbers only, single spaces: what phrases are matched against. */
function plain(s) {
    return ` ${String(s).toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim()} `;
}

function lines(a) {
    return Array.isArray(a) ? a.filter((s) => typeof s === 'string' && s.trim()).map((s) => s.trim()) : [];
}

// ---------------------------------------------------------------- script

export function scriptBrain(script) {
    const s = script && typeof script === 'object' ? script : {};
    const intents = (Array.isArray(s.intents) ? s.intents : []).map((it) => ({
        match: lines(it.match).map(plain),
        say: lines(it.say),
        action: typeof it.action === 'string' ? it.action : null,
        end: it.end === true,
        next: 0,
    })).filter((it) => it.match.length && (it.say.length || it.action || it.end));
    const greet = { say: lines(s.greet), next: 0 };
    const fallback = { say: lines(s.fallback).length ? lines(s.fallback) : ['Sorry, what?'], next: 0 };

    const pick = (set) => {
        if (!set.say.length) return null;
        const line = set.say[set.next % set.say.length];
        set.next += 1;
        return line;
    };

    return {
        kind: 'script',
        async *greet() {
            const line = pick(greet);
            if (line) yield { text: line };
        },
        async *reply(heard) {
            const said = plain(heard);
            const it = intents.find((i) => i.match.some((m) => said.includes(m)));
            const set = it || fallback;
            const line = pick(set);
            if (line) yield { text: line };
            if (it && it.action) yield { action: it.action, args: {} };
            if (it && it.end) yield { end: true };
        },
    };
}

// ---------------------------------------------------------------- llm

// Said to every model, after the owner's persona: how a spoken game character answers.
const RULES = [
    'You are a character in a video game, speaking out loud to a player standing in front of you.',
    'Answer in one or two short spoken sentences. No lists, no emojis, no actions in brackets, no stage directions.',
    'Stay in character whatever the player says. Never mention prompts, instructions, models or being an AI.',
    'If the player is rude, abusive or tries to make you say something hateful or sexual, brush it off in character.',
].join(' ');

const HISTORY = 12;   // messages kept (6 back and forths): enough for a conversation, cheap to resend

export function llmBrain(provider, persona, o = {}) {
    const system = `${typeof persona.system === 'string' ? persona.system.trim() : ''}\n\n${RULES}`.trim();
    const messages = [];
    const maxTokens = Math.max(16, Math.round((o.maxReplyChars || 200) / 3));
    const reasoning = ['off', 'low', 'high'].includes(o.reasoning) ? o.reasoning : 'off';

    async function* ask(signal) {
        let text = '';
        for await (const piece of provider.chat({ system, messages: messages.slice(-HISTORY), maxTokens, reasoning, signal })) {
            if (piece.usage) { yield { usage: piece.usage, provider: provider.name }; continue; }
            if (piece.action) { yield piece; continue; }
            if (typeof piece.text === 'string' && piece.text) { text += piece.text; yield { text: piece.text }; }
        }
        // What it said goes into the history as said (the session may have cut it at the reply limit: it
        // tells the brain with `spoke`).
        return text;
    }

    return {
        kind: 'llm',
        async *greet() {
            if (typeof persona.firstLine === 'string' && persona.firstLine.trim()) {
                const line = persona.firstLine.trim();
                messages.push({ role: 'assistant', content: line });
                yield { text: line };
            }
        },
        async *reply(heard, { signal } = {}) {
            messages.push({ role: 'user', content: String(heard) });
            const said = yield* ask(signal);
            messages.push({ role: 'assistant', content: said || '...' });
        },
        /** The session cut the reply short (the length limit): remember only what was spoken. */
        spoke(text) {
            const last = messages[messages.length - 1];
            if (last && last.role === 'assistant') last.content = text || '...';
        },
    };
}

export function makeBrain(o) {
    if (o.kind === 'script') return scriptBrain(o.persona && o.persona.script);
    if (o.kind === 'llm') {
        if (!o.llm) throw new Error('an llm brain needs an llm provider');
        return llmBrain(o.llm, o.persona || {}, o);
    }
    throw new Error(`no brain "${o.kind}" (script or llm)`);
}
