# Firstlight: original ambient + synth bass picker

The active lab and native app contain only 02 Warm analog. The scene is the direct sum of:

1. The user's original `An_8-second_sound_cu_#3-1789585822225.mp3`, at its original
   speed and complete 16.08-second duration, with only its brief peak softened.
2. One continuous synthesizer bass. A quiet upper-bass layer grows before the
   window, and a deep centred F1 foundation peaks with the final reveal haptic.

The two quiet logo repeats were removed. There is no piano, sampled instrument
or new chord accompaniment.

## Original and the softened peak

Source: `audio/instruments/ambient-references/selected-ambient-1789585822225.mp3`

Original upload: `/Users/serafimcloud/Downloads/An_8-second_sound_cu_#3-1789585822225.mp3`

SHA-256: `ff62a09f1b4baecfa25f658efefdf9a4083e6afc34dd2d5ffabb5bee5403967e`

The highest sample amplitude occurs at 8.0564375 s. A smooth gain envelope
reduces this peak by 3 dB, reaching down from 100 ms before it and recovering by
160 ms afterwards. All source samples outside this 260 ms interval are unchanged.
No logo repeats are mixed or played. Older fragment files are unused.

## Bass design and timing

Warm analog uses a smoothly opening synthesized low end with upper harmonics
and a long release. It uses no piano samples. The other presets are historical.
The fundamental is F1, 43.6535 Hz, fitting the F/G texture of the source.
The bass's loudest 100 ms is centred at 4.905882 s, matching
`IntroPlayback.climaxAtReal = 4.25 - 0.5` through the fixed 4.25 / 5.56 audio
clock scale. This advances the unchanged bass stem by about 0.71 s, with no
shift to the source or animation. Warm analog's onset is around 2.85 s.
A shared 250 ms
RMS crest target of 0.063 makes comparisons about timbre and envelope.
Bass releases to silence by 7.90 s, leaving the original ambient tail.

The locally softened source is a 1x summand of every rendered WAV. There is no mix-bus
normalization, compressor, limiter or EQ. Reverb and filters apply only to the
synth bass. Full scenes are 24-bit WAV; browser copies are AAC. Comparison with
"Оригинал" plays the exact original MP3 bytes, with no additional layers.

## Picker

One native audio element plays every option. The original and selected scene
can be switched at the same playback position. "Нарастание и окно" seeks to
2.0 seconds for a shorter comparison. Each card plays the whole scene or just
its 6.6-second bass excerpt; the visual clock is offset appropriately for solo
playback. Downloads contain the selected full scene and the isolated bass.

The simplified animation retains the established preview clock scaling of
4.25 / 5.56; audio runs at 1x.

## Native application

Only `App/Resources/OnboardingSounds/arrival-02.m4a` is exported to the app.
Older saved selections fall back to 02. The sound and preview block was removed
from Settings. Replay onboarding in the menu-bar context menu still replays the
real onboarding without signing out.

`IntroPlayback` reads the AVAudioPlayer clock with the same 4.25 / 5.56 scale,
so the native window handoff remains at 5.56 seconds; the final reveal haptic
and the bass crest coincide at 4.905882 seconds. The source remains
at 1x speed. The full recording's natural tail continues after the visual
choreography; closing, skipping, interruption or another replay stops playback.
Reduce Motion and instant reopening do not start sound. Missing or undecodable
audio falls back to the existing silent visual clock.

System-audio muting was removed at the user's request. There is no capture
permission request, audio-input entitlement, tap, aggregate device or volume change.

## Reproduce

Use the existing `audio-requirements.txt` environment plus FFmpeg, then run
`python build_synth_picker.py`. NumPy/SciPy synthesize the basses; Spotify
Pedalboard provides reverb on their upper frequencies. No generation service is
required. `manifest.json` records source identity, all parameters, cue times,
the peak reduction and source reconstruction error. Run `verify_synth_picker.py`
in the same Python environment to verify the exports and native resource copies.

Older `compose_soft808.py` and `build_context.py` files are historical and do
not build the current lab. Verification results are in
`audio/synth-picker/verification.json`. Checks establish signal integrity and
playback logic; emotional quality remains a listening judgment.
