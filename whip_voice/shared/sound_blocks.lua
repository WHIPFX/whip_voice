-- The sound blocks, the building blocks of every sound recipe. A recipe is a list of these blocks, in order, each with
-- its settings. Any resource can make one (a phone call's sound, an intercom's, a radio's). It is data, never code: the
-- player's game (html/js/fx.js) builds the sound from these blocks and nothing else.
--
--   { { 'bandpass', hz = 1200, q = 0.7 }, { 'drive', k = 3 }, { 'gain', db = 2 } }
--
-- This file is the one list: which blocks exist, which settings each takes, and the safe range of every number. The
-- server checks recipes against it, and the page is sent it when it connects and checks again, so the two never
-- disagree. A setting left out takes the default; a number out of range is brought into it.
--
-- How a setting is written below:
--   { min, max, default }      a number
--   { 'a', 'b', ... }          one of these words (the first is the default)

SoundBlocks = {
    -- ---- level and tone ----
    gain      = { db = { -60, 24, 0 } },                                   -- louder or quieter
    lowpass   = { hz = { 20, 20000, 3000 }, q = { 0.1, 30, 0.7 } },        -- cut the highs above hz
    highpass  = { hz = { 20, 20000, 300 }, q = { 0.1, 30, 0.7 } },         -- cut the lows below hz
    bandpass  = { hz = { 20, 20000, 1200 }, q = { 0.1, 30, 0.7 } },        -- only a band around hz
    notch     = { hz = { 20, 20000, 1000 }, q = { 0.1, 30, 0.7 } },        -- take out a band around hz
    peak      = { hz = { 20, 20000, 1500 }, q = { 0.1, 30, 1 }, db = { -30, 30, 0 } },   -- boost or cut a band
    lowshelf  = { hz = { 20, 20000, 250 }, db = { -30, 30, 0 } },          -- the lows up or down
    highshelf = { hz = { 20, 20000, 4000 }, db = { -30, 30, 0 } },         -- the highs up or down
    band      = { low = { 20, 20000, 300 }, high = { 20, 20000, 3400 }, q = { 0.1, 30, 0.7 } },   -- keep low..high (a telephone: 300-3400)

    -- ---- grit ----
    drive     = { k = { 1, 50, 2.5 }, oversample = { 'none', '2x', '4x' } },   -- soft clipping: loud sound rounded off, harder the bigger k
    crush     = { steps = { 2, 256, 32 } },                                -- the sound rounded to this many steps: a digital edge
    compress  = { threshold = { -100, 0, -24 }, knee = { 0, 40, 6 }, ratio = { 1, 20, 4 },
                  attack = { 0, 1, 0.003 }, release = { 0, 1, 0.12 } },   -- loud and quiet squeezed together

    -- ---- things added to the sound ----
    noise     = { kind = { 'white', 'pink', 'brown' }, level = { 0, 0.3, 0.02 },
                  hz = { 20, 20000, 2500 }, q = { 0.1, 30, 0.7 } },        -- a hiss under the voice, only while they talk
    breakup   = { static = { 0, 1, 0.06 } },                               -- drops out more the weaker the line (its quality), static in the gaps
    beeps     = { up = { 0, 5000, 1250 }, down = { 0, 5000, 1900 }, down2 = { 0, 5000, 1450 },
                  level = { 0, 0.2, 0.05 } },                              -- a beep as they start and stop talking (0 Hz: that beep off)
    pan       = { to = { -1, 1, 0 } },                                     -- towards one ear: -1 left, 1 right
    hum       = { hz = { 20, 400, 50 }, level = { 0, 0.3, 0.02 } },        -- a mains hum under the voice (50 or 60 Hz), only while they talk

    -- ---- movement and space ----
    echo      = { time = { 0.02, 2, 0.25 }, feedback = { 0, 0.9, 0.35 }, mix = { 0, 1, 0.3 } },   -- repeats, `time` seconds apart, each quieter
    chorus    = { rate = { 0.05, 8, 1.2 }, depth = { 0, 0.02, 0.004 }, mix = { 0, 1, 0.5 } },     -- a second, wavering copy: thick, shimmering
    vibrato   = { rate = { 0.1, 12, 5 }, depth = { 0, 0.01, 0.002 } },                           -- the pitch wavers (a wobbly tape, a drone)
    tremolo   = { rate = { 0.1, 20, 5 }, depth = { 0, 1, 0.5 } },                                -- the loudness pulses
    ringmod   = { hz = { 1, 2000, 50 }, mix = { 0, 1, 1 } },                                     -- a robot, a dalek
    reverb    = { size = { 0.1, 4, 1.2 }, mix = { 0, 1, 0.25 } },          -- a room around the device; one for the whole line, never one per voice

    -- ---- whole sounds ----
    radio     = { static = { 0, 1, 0.06 }, distortion = { 0, 1.5, 1 } },   -- whip_voice's walkie-talkie, breaking up with distance
}

-- How big a recipe may be.
SoundLimits = {
    blocks = 24,     -- blocks in one recipe
    sources = 4,     -- blocks that make sound of their own (below) in one recipe
    depth = 8,       -- how deep the data may go (a recipe is a list of tables: 2)
    -- The blocks that make sound of their own (a noise, an oscillator, a room): they cost while a voice talks.
    sourceBlocks = { noise = true, breakup = true, radio = true, hum = true, chorus = true, vibrato = true,
                     tremolo = true, ringmod = true, reverb = true },
}
