"""Put the selected soft 808 into the complete Firstlight arrival.

The bass is the actual audition 05 WAV. The harmony is arranged around its F1
root: an open F/C/G expectation, F major add9 at the native window cue, then
a quieter C-to-D answer as the logo rises. Source texture is transposed to F.
"""

import base64
import json
from pathlib import Path
import subprocess
import wave

import numpy as np

from build_basses import SR, TAU, band, edge_fades, read_audio, stereo

ROOT = Path(__file__).parent
OUT = ROOT / "audio" / "context"
DURATION = 10.0
WINDOW = 4.25
RISE = 6.671
RISE_END = 7.319
N = round(SR * DURATION)


def smooth(a, b, t):
    u = np.clip((t - a) / (b - a), 0, 1)
    return u * u * (3 - 2 * u)


def place(target, source, at, gain=1):
    start = round(at * SR)
    count = min(len(source), len(target) - start)
    target[start:start + count] += source[:count] * gain


def voice(frequency, duration, attack, decay, release, felt=False, pan=0):
    t = np.arange(round(duration * SR)) / SR
    p = TAU * frequency * t + 0.016 * np.sin(TAU * 0.61 * t)
    brightness = np.exp(-t / 0.25) if felt else np.exp(-t / 2.4)
    tone = np.sin(p) + 0.19 * brightness * np.sin(2.002 * p) + 0.045 * brightness ** 2 * np.sin(3.004 * p)
    env = smooth(0, attack, t) * np.exp(-np.maximum(0, t - attack) / decay)
    env *= 1 - smooth(duration - release, duration, t)
    tone *= env
    return np.column_stack([tone * np.sqrt((1 - pan) / 2), tone * np.sqrt((1 + pan) / 2)])


def room(x):
    # Dense, short stereo room on the musical layers. Bass stays centered/dry.
    rng = np.random.default_rng(80805)
    t = np.arange(round(1.9 * SR)) / SR
    ir = band(rng.normal(size=(len(t), 2)), 230, 4200)
    ir *= (np.exp(-t / 0.33) * smooth(0.023, 0.044, t))[:, None]
    ir /= np.sqrt(np.sum(ir ** 2, axis=0))
    length = 1 << (len(x) + len(ir) - 2).bit_length()
    wet = np.fft.irfft(np.fft.rfft(x, length, axis=0) * np.fft.rfft(ir, length, axis=0), length, axis=0)[:len(x)]
    return x + 0.24 * wet


def crest(x, span=0.12):
    width = round(span * SR)
    start = max(range(0, len(x) - width, round(0.005 * SR)),
                key=lambda i: np.mean(x[i:i + width] ** 2))
    return (start + width / 2) / SR, float(np.sqrt(np.mean(x[start:start + width] ** 2)))


def write_wav(path, x):
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(2)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(np.round(x * 32767).astype('<i2').tobytes())


def main():
    OUT.mkdir(exist_ok=True)
    music = np.zeros((N, 2))
    bass_stem = np.zeros_like(music)

    # Dawn: retain only the downloaded clip's airy texture.
    dawn = band(read_audio(ROOT / 'audio/dawn-elevenlabs.m4a'), 2400, 7000)
    dawn = edge_fades(dawn[:round(3.5 * SR)], 0.9, 0.85)
    dawn *= 0.0045 / max(crest(dawn)[1], 1e-9)
    place(music, dawn, 1.0)

    # Sparse open harmony grows with the light, with no major third yet.
    for frequency, at, gain, pan in [(174.614, 1.05, 0.027, -0.15),
                                    (261.626, 1.3, 0.032, 0.15),
                                    (391.995, 2.25, 0.027, -0.08)]:
        sound = voice(frequency, 4.55-at, 1.15, 9, 0.55, pan=pan)
        local_t = np.arange(len(sound)) / SR + at
        sound *= (0.3 + 0.7 * smooth(1.0, 4.1, local_t))[:, None]
        place(music, sound, at, gain)

    # Familiar downloaded bowed texture, shifted from Eb/Bb to F/C.
    raw = subprocess.check_output([
        'ffmpeg', '-v', 'error', '-i', str(ROOT / 'audio/reveal-elevenlabs.m4a'),
        '-af', 'rubberband=pitch=1.1224620483', '-ar', str(SR), '-ac', '2',
        '-f', 'f32le', 'pipe:1',
    ])
    bed = np.frombuffer(raw, dtype='<f4').reshape(-1, 2).astype(float)
    bed = band(bed, 320, 2100)
    bed *= 0.030 / max(crest(bed)[1], 1e-9)
    bed_t = np.arange(len(bed)) / SR + 1.0
    bed *= (smooth(1.0, 2.5, bed_t) * (0.22 + 0.78*smooth(4.08, 4.42, bed_t))
            * (1-smooth(5.55, 8.75, bed_t)))[:, None]
    place(music, bed, 1.0)

    # The reveal opens a new register and clear major harmony.
    # F3 / C4 / F4 / A4 / C5 / G5, with the major third prominent.
    voicing = [(174.614, .024, -.25), (261.626, .026, .21),
               (349.228, .024, -.12), (440.0, .064, .08),
               (523.251, .032, -.30), (783.991, .019, .32)]
    for i, (frequency, gain, pan) in enumerate(voicing):
        place(music, voice(frequency, 4.25, .075 + i*.009, 1.45, 1.65, pan=pan),
              WINDOW + i*.008, gain)
    # A small G-to-A lift makes the harmonic arrival audible as a gesture.
    place(music, voice(391.995, .5, .09, .3, .24, felt=True, pan=-.08), 3.96, .012)
    place(music, voice(440.0, 2.05, .055, .78, .8, felt=True, pan=.10), WINDOW+.035, .043)
    # Keep one light upper ninth after the low foundation has receded.
    place(music, voice(783.991, 5.55, .28, 2.8, 1.75, pan=.22), WINDOW+.10, .012)

    bass = read_audio(ROOT / 'audio/basses/bass-05.wav')
    bass_peak, _ = crest(bass, .12)
    bass_at = WINDOW + .02 - bass_peak
    place(bass_stem, bass, bass_at, .70)

    # The final answer rises a whole step, with the second note quieter.
    place(music, voice(523.251, 2.25, .045, .64, .9, felt=True, pan=-.1), RISE, .042)
    place(music, voice(587.330, 2.6, .075, 1.00, 1.1, felt=True, pan=.13), RISE_END, .020)
    music = room(music)
    music = edge_fades(music, .03, .75)
    mix = music + bass_stem
    # One common gain preserves the bass-to-harmony relationship and arc.
    gain = min(1.0, .72 / np.abs(mix).max())
    mix *= gain
    music *= gain
    bass_stem *= gain
    write_wav(OUT/'firstlight-hope-808.wav', mix)
    write_wav(OUT/'firstlight-hope-808-music.wav', music)
    write_wav(OUT/'firstlight-hope-808-bass.wav', bass_stem)
    dest = OUT/'firstlight-hope-808.m4a'
    subprocess.run(['ffmpeg','-y','-v','error','-i',str(OUT/'firstlight-hope-808.wav'),
                    '-c:a','aac','-b:a','256k',str(dest)],check=True)
    entry = {'id':'scene', 'title':'Мягкий 808 · полная сцена', 'duration':DURATION,
             'audio':'audio/context/firstlight-hope-808.m4a',
             'wav':'audio/context/firstlight-hope-808.wav',
             'bassId':'05', 'window':WINDOW, 'rise':RISE, 'riseEnd':RISE_END,
             'bassStart':round(bass_at,4), 'bassCrest':round(bass_at+bass_peak,4),
             'data':base64.b64encode(dest.read_bytes()).decode('ascii')}
    (ROOT/'context-audio.js').write_text('// Generated by build_context.py.\nwindow.SCENE_TRACK = '+json.dumps(entry,ensure_ascii=False)+';\n')
    audit = {k:v for k,v in entry.items() if k!='data'}
    audit['peak'] = round(float(np.abs(mix).max()),5)
    audit['mixCrest'] = round(crest(mix)[0],3)
    audit['harmony'] = 'F open fifth and ninth -> F major add9 -> C5/D5 answer'
    (OUT/'manifest.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(audit,ensure_ascii=False,indent=2))


if __name__ == '__main__':
    main()
