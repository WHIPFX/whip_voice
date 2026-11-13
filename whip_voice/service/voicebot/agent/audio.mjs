// The AI NPC agent's audio plumbing: everything is mono 16-bit samples (Int16Array). The voice room speaks
// 48 kHz in 10 ms frames; each provider names the rate it takes and gives.

export const ROOM_RATE = 48000;
export const ROOM_FRAME = ROOM_RATE / 100;   // 10 ms

/** Join chunks into one array. */
export function concat(chunks) {
    const total = chunks.reduce((n, c) => n + c.length, 0);
    const out = new Int16Array(total);
    let at = 0;
    for (const c of chunks) { out.set(c, at); at += c.length; }
    return out;
}

/**
 * A changer of sample rate that keeps its place between pushes (a provider's audio arrives in pieces).
 * Linear, with a running average in front when it goes down so a 48 kHz voice does not fold over into
 * 16 kHz. Good enough for speech to text and for a passable voice; the service hands the agent the voice
 * room's own (better) one instead, through the same three calls.
 */
export class LinearResampler {
    constructor(from, to) {
        this.from = from;
        this.to = to;
        this.step = from / to;      // input samples per output sample
        this.pos = 0;               // where the next output falls, in input samples from the start of `prev`
        this.prev = 0;              // the last input sample of the previous push
        this.avg = Math.max(1, Math.round(this.step));   // the average's width when going down
        this.hist = [];
    }

    smooth(x) {
        if (this.avg <= 1) return x;
        this.hist.push(x);
        if (this.hist.length > this.avg) this.hist.shift();
        let s = 0;
        for (const v of this.hist) s += v;
        return s / this.hist.length;
    }

    push(pcm) {
        if (this.from === this.to) return Int16Array.from(pcm);
        const src = new Float32Array(pcm.length + 1);
        src[0] = this.prev;
        for (let i = 0; i < pcm.length; i++) src[i + 1] = this.smooth(pcm[i]);
        const out = [];
        // src[0] is the previous push's last sample, src[k] the input's k-1th: an output at position p lies
        // between src[floor(p)] and src[floor(p) + 1].
        while (this.pos + 1 < src.length) {
            const i = Math.floor(this.pos);
            const f = this.pos - i;
            out.push(Math.round(src[i] + (src[i + 1] - src[i]) * f));
            this.pos += this.step;
        }
        this.pos -= src.length - 1;
        this.prev = src[src.length - 1];
        return Int16Array.from(out, (v) => Math.max(-32768, Math.min(32767, v)));
    }

    flush() { return new Int16Array(0); }
    close() {}
}

/** Audio in pieces of any size out as exact 10 ms frames (the last padded with silence on flush). */
export class Framer {
    constructor(frame = ROOM_FRAME) {
        this.frame = frame;
        this.buf = new Int16Array(0);
    }

    push(pcm) {
        const all = this.buf.length ? concat([this.buf, pcm]) : pcm;
        const frames = [];
        let at = 0;
        // Copies (slice), never views: the voice room reads a frame's buffer from its start.
        for (; at + this.frame <= all.length; at += this.frame) frames.push(all.slice(at, at + this.frame));
        this.buf = all.slice(at);
        return frames;
    }

    flush() {
        if (!this.buf.length) return [];
        const last = new Int16Array(this.frame);
        last.set(this.buf);
        this.buf = new Int16Array(0);
        return [last];
    }
}

/** Loudness of a frame in dB below full scale (-Infinity for digital silence). */
export function dbfs(frame) {
    let sum = 0;
    for (let i = 0; i < frame.length; i++) sum += frame[i] * frame[i];
    if (!sum) return -Infinity;
    return 20 * Math.log10(Math.sqrt(sum / frame.length) / 32768);
}

/** A WAV file of mono 16-bit samples (what a speech-to-text service is sent, and test clips). */
export function wav(pcm, rate) {
    const data = Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength);
    const head = Buffer.alloc(44);
    head.write('RIFF', 0);
    head.writeUInt32LE(36 + data.length, 4);
    head.write('WAVE', 8);
    head.write('fmt ', 12);
    head.writeUInt32LE(16, 16);
    head.writeUInt16LE(1, 20);          // PCM
    head.writeUInt16LE(1, 22);          // mono
    head.writeUInt32LE(rate, 24);
    head.writeUInt32LE(rate * 2, 28);
    head.writeUInt16LE(2, 32);
    head.writeUInt16LE(16, 34);
    head.write('data', 36);
    head.writeUInt32LE(data.length, 40);
    return Buffer.concat([head, data]);
}
