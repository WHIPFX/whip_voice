// What the AI NPCs cost, as they go: each provider's use priced from the owner's config (prices change, so they
// are the owner's to keep right; the /whip page comes filled with the day it was written's), totalled per day.
//
// A provider's `price` (any it does not use can be left out), in US dollars:
//   audioInMinute    a minute of a player's voice heard         (speech to text)
//   audioOutMinute   a minute of the NPC's voice made           (some realtime companies)
//   perKChars        1,000 characters spoken                    (text to speech)
//   inTokensM        a million tokens sent to a model           (thinking)
//   outTokensM       a million tokens a model writes            (thinking)
//   sessionMinute    a minute a realtime conversation is open   (all-in-one companies that bill by the minute)
//
// The service's own DAILY CAP (`dailyUsd`) is a backstop: once a day's spend reaches it, no new conversation
// starts and none speaks again until midnight (the FiveM side keeps its own, lower, cap on the /whip page).

export function costOf(price, usage) {
    const p = price || {}, u = usage || {};
    const n = (v) => (Number.isFinite(v) ? v : 0);
    return n(u.audioInSec) / 60 * n(p.audioInMinute)
        + n(u.audioOutSec) / 60 * n(p.audioOutMinute)
        + n(u.chars) / 1000 * n(p.perKChars)
        + n(u.inTokens) / 1e6 * n(p.inTokensM)
        + n(u.outTokens) / 1e6 * n(p.outTokensM)
        + n(u.sessionSec) / 60 * n(p.sessionMinute);
}

function dayOf(ms) {
    const d = new Date(ms);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export class Meter {
    constructor({ dailyUsd = 0, now = Date.now } = {}) {
        this.dailyUsd = Number(dailyUsd) > 0 ? Number(dailyUsd) : 0;   // 0: no cap here
        this.now = now;
        this.day = dayOf(now());
        this.usd = 0;
        this.byProvider = {};
    }

    roll() {
        const today = dayOf(this.now());
        if (today !== this.day) { this.day = today; this.usd = 0; this.byProvider = {}; }
    }

    /** A provider's use: priced, added to today, and the cost returned. */
    add(provider, usage) {
        this.roll();
        const usd = costOf(provider && provider.price, usage);
        const name = (provider && provider.name) || '?';
        const b = this.byProvider[name] || (this.byProvider[name] = { usd: 0, usage: {} });
        b.usd += usd;
        for (const [k, v] of Object.entries(usage || {})) if (Number.isFinite(v)) b.usage[k] = (b.usage[k] || 0) + v;
        this.usd += usd;
        return usd;
    }

    /** Today's spend has reached the cap. */
    over() {
        this.roll();
        return this.dailyUsd > 0 && this.usd >= this.dailyUsd;
    }

    today() {
        this.roll();
        return { day: this.day, usd: this.usd, cap: this.dailyUsd || null, byProvider: this.byProvider };
    }
}
