# LCARS interface audio

These interaction clips are the same canonical *Star Trek* computer effects
used by Torplex and sourced from [TrekCore's audio archive](https://www.trekcore.com/audio/).
`intrepid-key.mp3` is derived from a Voyager-era hail effect. AMPS omits
both Torplex bridge-ambience tracks by design; it never plays a background hum.

`search.mp3` is the original AudioArray Refresh/resampling cue. Scroll, pan,
slider, and drag gestures share one quietly looping scanning voice (0.06 gain
versus 0.2 for buttons). Movement extends the current playback rather than
retriggering it. Drag release or 180 ms of scroll/slider inactivity fades it out
over 80 ms. Mute, window blur, and app cleanup stop it immediately. Ordinary
buttons retain their distinct original cues; automatic graph updates stay silent.

Star Trek and related audio remain the property of CBS Studios Inc. / Paramount.
They are retained for Alex's permitted private LCARS interfaces and are not
offered under AMPS's source-code license.
