// When a player starts and stops talking: their audio cut into SENTENCES, so a provider is only ever sent what
// was said to the NPC, never an open microphone (and a provider that bills by the second is not paying for
// silence). By loudness against the room's own background, frame by frame (10 ms).
//
// A sentence starts after START_MS of voice (with PRE_MS before it kept, so the first sound is not clipped),
// and ends after END_MS of quiet. Shorter than MIN_MS is a cough, not a sentence. Longer than the session's
// limit is cut there (and the rest is a sentence of its own).

import { dbfs } from './audio.mjs';

const START_MS = 60, END_MS = 600, MIN_MS = 300, PRE_MS = 200;
const OVER_FLOOR_DB = 12;      // voice is this much louder than the background...
const ABSOLUTE_DB = -50;       // ...and at least this loud (a muted microphone sends digital silence)
// The background: the quietest moment (10 ms) of the last 3 s, reached at once going down and at RISE_DB a
// second going up. Speech has quiet moments between its sounds, so it never becomes the background; a steady
// fan or hiss has none, so it does, a few seconds after it starts (rather than one sentence that never ends).
// Slowly up, so the first thing heard after a muted microphone (nothing but digital silence before it) is
// not taken for the background.
const BUCKET_MS = 100, BUCKETS = 30, RISE_DB = 3;

export class Vad {
    /**
     * @param {{ rate?: number, frameMs?: number, maxMs?: number }} o
     */
    constructor(o = {}) {
        this.frameMs = o.frameMs || 10;
        this.maxFrames = Math.round((o.maxMs || 15000) / this.frameMs);
        this.startFrames = Math.round(START_MS / this.frameMs);
        this.endFrames = Math.round(END_MS / this.frameMs);
        this.minFrames = Math.round(MIN_MS / this.frameMs);
        this.preFrames = Math.round(PRE_MS / this.frameMs);
        this.bucketFrames = Math.round(BUCKET_MS / this.frameMs);
        this.buckets = [];      // the quietest 10 ms of each past 100 ms, newest last
        this.bucket = [];       // this 100 ms so far
        this.floor = -60;
        this.reset();
    }

    /** The background follows the quietest recent moment (digital silence does not count: no microphone). */
    follow(db) {
        if (db === -Infinity) return;
        this.bucket.push(db);
        if (this.bucket.length < this.bucketFrames) return;
        this.buckets.push(Math.min(...this.bucket));
        this.bucket = [];
        if (this.buckets.length > BUCKETS) this.buckets.shift();
        const target = Math.min(...this.buckets);
        this.floor = target < this.floor ? target : Math.min(target, this.floor + RISE_DB * BUCKET_MS / 1000);
    }

    reset() {
        this.talking = false;
        this.loud = 0;          // voice frames in a row, before a sentence starts
        this.quiet = 0;         // quiet frames in a row, inside one
        this.frames = [];       // the sentence so far (or the pre-roll, before it)
    }

    /** True while a sentence is under way. */
    get speaking() { return this.talking; }

    /**
     * One 10 ms frame in. Out: null, or a finished sentence { frames, cut } (cut: it hit the length limit).
     * @param {Int16Array} frame
     */
    push(frame) {
        const db = dbfs(frame);
        const voice = db > Math.max(this.floor + OVER_FLOOR_DB, ABSOLUTE_DB);
        this.follow(db);
        if (!this.talking) {
            this.frames.push(frame);
            if (this.frames.length > this.preFrames + this.startFrames) this.frames.shift();
            this.loud = voice ? this.loud + 1 : 0;
            if (this.loud >= this.startFrames) { this.talking = true; this.quiet = 0; }
            return null;
        }
        this.frames.push(frame);
        this.quiet = voice ? 0 : this.quiet + 1;
        if (this.frames.length >= this.maxFrames) {
            const frames = this.frames;
            this.reset();
            return { frames, cut: true };
        }
        if (this.quiet >= this.endFrames) {
            // The quiet tail goes, but for 100 ms (a sentence's last sound fades).
            const keep = this.frames.length - this.quiet + Math.round(100 / this.frameMs);
            const frames = this.frames.slice(0, Math.max(0, keep));
            this.reset();
            if (frames.length - this.preFrames < this.minFrames) return null;   // a cough
            return { frames, cut: false };
        }
        return null;
    }
}
