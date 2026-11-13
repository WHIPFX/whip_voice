// ============================================
// whip_voice — the radio's own sounds and volume (Web Audio)
// ============================================
//
// EVERY RADIO FREQUENCY IS A VOICE LINE (server/radio.lua, 7 Oct 2026): the voices on it, how they
// break up with distance, the static and the talk beeps they make are the line's — html/js/lines.js
// plays them, through the radio's sound recipe (html/js/fx.js: its 'radio' and 'beeps' blocks). Voices
// out of a radio on speaker near this player come out of that radio (lines.js speakerNode). What is
// left here is this player's OWN radio:
//
//   the talk beeps for their own presses (one short beep as they start talking on the radio, the
//   two-tone roger beep as they stop: the 3D radio's own, Josh, 4 Oct 2026) — off while the 3D radio
//   is on their screen, which beeps for them itself (setOwnBeeps, html/js/walkie.js);
//   the radio's volume knob (the walkie): this player's own radio frequencies and these beeps.

'use strict';

window.VoiceRadio = (() => {
    let bus = null;                // the radio's volume, into the mix (this player's own beeps)
    let radioLevel = 1;
    let clicks = 0;                // (dev) how many of this player's own beeps were made, for the tests

    function ctx() { return VoiceAudio.context(); }

    function out() {
        if (!bus) {
            bus = ctx().createGain();
            bus.gain.value = radioLevel;
            bus.connect(VoiceAudio.lineOutput());
        }
        return bus;
    }

    /** This player's own talk beeps: 'up' as they start talking on the radio (the 3D radio's "txon"),
     *  'down' as they stop (the two-tone roger beep, its "txoff"). */
    function click(kind) {
        const into = out(), c = ctx();
        clicks += 1;
        if (kind === 'up') {
            VoiceFx.beep(c, into, 1250, 0.05, 0);
        } else {
            VoiceFx.beep(c, into, 1900, 0.06, 0);
            VoiceFx.beep(c, into, 1450, 0.06, 0.07);
        }
    }

    // This player's own talk beeps, off while the 3D radio is on their screen and beeping for them
    // (html/js/walkie.js): otherwise every press would beep twice.
    let ownBeeps = true;
    function setOwnBeeps(on) { ownBeeps = on !== false; }

    /** This player's radio volume (0 to 1), from the walkie: their own beeps and their frequencies. */
    function volume(level) {
        radioLevel = Math.max(0, Math.min(1, Number(level) || 0));
        if (bus) bus.gain.setTargetAtTime(radioLevel, ctx().currentTime, 0.05);
        VoiceLines.setRxVolume(radioLevel);
    }

    const RC = VoiceFx.curves;
    return { click, volume, setOwnBeeps, ownBeeps: () => ownBeeps,
        _clicks: () => clicks, _volume: () => (bus ? bus.gain.value : radioLevel),
        _levels: { voiceLevel: RC.voiceLevel, dropoutChance: RC.dropoutChance } };
})();
