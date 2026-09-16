"""Render ten isolated bass auditions, WAV downloads and a file:// audio bundle.

Requires numpy and ffmpeg. No piano, reveal bed or logo notes are included.
The first three sounds use the user's heavy-bass reference; the other seven
are distinct synthesis studies. Selection happens in the lab, not here.
"""

import base64
import json
from pathlib import Path
import subprocess
import wave
import zipfile

import numpy as np


ROOT = Path(__file__).parent
OUT = ROOT / "audio" / "basses"
SR = 48_000
TAU = 2 * np.pi


def read_audio(path):
    raw = subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(path), "-ar", str(SR),
        "-ac", "2", "-f", "f32le", "pipe:1",
    ])
    return np.frombuffer(raw, dtype="<f4").reshape(-1, 2).astype(np.float64)


def stereo(x):
    return np.column_stack([x, x]) if x.ndim == 1 else x.copy()


def band(x, low=0, high=0):
    """Smooth offline filter, followed by final fades to remove edge artifacts."""
    x = stereo(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    response = np.ones_like(f)
    if low:
        response *= (f / low) ** 4 / (1 + (f / low) ** 4)
    if high:
        response /= np.sqrt(1 + (f / high) ** 8)
    return np.fft.irfft(np.fft.rfft(x, axis=0) * response[:, None], n=len(x), axis=0)


def edge_fades(x, attack=0.04, release=0.5):
    x = stereo(x)
    a, r = round(attack * SR), round(release * SR)
    x[:a] *= np.sin(np.linspace(0, np.pi / 2, a))[:, None] ** 2
    x[-r:] *= np.sin(np.linspace(np.pi / 2, 0, r))[:, None] ** 2
    return x


def envelope(t, attack, hold, decay, release=0.55):
    rise = np.sin(np.minimum(t / attack, 1) * np.pi / 2) ** 2
    tail = np.exp(-np.maximum(0, t - attack - hold) / decay)
    end = np.sin(np.minimum((t[-1] - t) / release, 1) * np.pi / 2) ** 2
    return rise * tail * end


def phase(frequency):
    return TAU * np.cumsum(frequency) / SR


def reference_slice(source, first, last, rate=1):
    segment = source[round(first * SR):round(last * SR)]
    positions = np.arange(0, len(segment) - 1, rate)
    return np.column_stack([np.interp(positions, np.arange(len(segment)), segment[:, c]) for c in (0, 1)])


def saw_body(t, frequency, offset=0, harmonics=20):
    return sum(np.sin(TAU * frequency * n * t + offset * n) / n ** 1.18
               for n in range(2, harmonics + 1))


def studies(source):
    yield "01", "Бас из твоего файла", "Фрагмент тяжёлого баса, который ты прислал.", "Твой MP3", edge_fades(reference_slice(source, 2.7, 6.3), 0.12, 0.4)
    yield "02", "Тот же, ниже", "Более низкий, медленный и тягучий.", "Твой MP3 · ниже", edge_fades(reference_slice(source, 2.7, 6.0, 2 ** (-5 / 12)), 0.16, 0.6)
    saturated = reference_slice(source, 2.7, 6.0)
    saturated = 0.45 * saturated + 0.65 * np.tanh(4.2 * saturated)
    yield "03", "Тот же, плотнее", "Шершавый низ с более заметным верхом баса.", "Твой MP3 · перегруз", edge_fades(band(saturated, 22, 850), 0.09, 0.5)

    t = np.arange(round(3.6 * SR)) / SR
    p = TAU * 41.2 * t
    sub = np.sin(p) + 0.18 * np.sin(2 * p) + 0.045 * np.sin(3 * p)
    sub *= envelope(t, 0.22, 0.55, 1.25)
    yield "04", "Глубокий саб", "Гладкое низкое давление с длинным затуханием.", "Саб", stereo(sub)

    t = np.arange(round(3.4 * SR)) / SR
    p = phase(43.65 + 35 * np.exp(-t / 0.09))
    sub = np.sin(p)
    tone = 0.72 * np.tanh(1.9 * sub) + 0.2 * np.sin(2 * p) + 0.07 * np.sin(3 * p)
    tone *= envelope(t, 0.035, 0.22, 1.05)
    yield "05", "Мягкий 808", "Низ слегка скользит вниз и долго держится.", "808", stereo(tone)

    t = np.arange(round(2.9 * SR)) / SR
    p = phase(46.25 + 18 * np.exp(-t / 0.07))
    wave_in = np.sin(p) + 0.3 * np.sin(2 * p + 0.2)
    tone = np.tanh(3.8 * wave_in + 0.13) - np.tanh(0.13)
    tone = band(tone, 23, 650)
    tone *= envelope(t, 0.025, 0.25, 0.85)[:, None]
    yield "06", "Жирный 808", "Плотный, с ощутимым перегрузом и коротким хвостом.", "808 · перегруз", tone

    t = np.arange(round(3.8 * SR)) / SR
    p = TAU * 55 * t + 0.013 * np.sin(TAU * 0.8 * t)
    tone = np.sin(p) + 0.5 * np.sin(2 * p) + 0.18 * np.sin(3 * p) + 0.11 * np.sin(4 * p)
    tone = np.tanh(1.3 * tone)
    tone = band(tone, 25, 360) * envelope(t, 0.3, 0.7, 1.05)[:, None]
    yield "07", "Тёплый аналоговый", "Округлый гул с тёплой серединой и мягким входом.", "Аналоговый", tone

    t = np.arange(round(4.0 * SR)) / SR
    fundamental = 0.9 * np.sin(TAU * 49 * t)
    left = fundamental + 0.85 * saw_body(t, 48.7) + 0.6 * saw_body(t, 49.3, 0.18)
    right = fundamental + 0.6 * saw_body(t, 48.7, 0.18) + 0.85 * saw_body(t, 49.3)
    reese = band(np.tanh(1.5 * np.column_stack([left, right])), 24, 580)
    reese *= envelope(t, 0.16, 0.8, 1.1)[:, None]
    yield "08", "Широкий Reese", "Густой, слегка рычащий бас с широкими краями.", "Reese", reese

    t = np.arange(round(4.1 * SR)) / SR
    rng = np.random.default_rng(16092026)
    rumble = band(rng.normal(size=(len(t), 2)), 30, 155)
    rumble /= np.std(rumble)
    grit = band(rng.normal(size=(len(t), 2)), 110, 350)
    grit /= np.std(grit)
    p = phase(40 + 9 * np.exp(-t / 0.9))
    core = stereo(np.sin(p) + 0.24 * np.sin(2 * p))
    tone = np.tanh(0.55 * rumble + 0.85 * core + 0.08 * grit)
    tone *= envelope(t, 0.34, 0.6, 1.1)[:, None]
    yield "09", "Киношный гул", "Тяжёлая низкая масса с неровной, живой фактурой.", "Гул", tone

    t = np.arange(round(3.9 * SR)) / SR
    p = phase(34 + 61 * np.exp(-t / 0.67))
    tone = np.tanh(1.7 * (np.sin(p) + 0.3 * np.sin(2 * p))) + 0.08 * np.sin(3 * p)
    tone *= envelope(t, 0.055, 0.35, 1.3)
    yield "10", "Падающий бас", "Длинное плавное скольжение из баса в глубокий саб.", "Скольжение", stereo(tone)


def normalize(x):
    x = edge_fades(band(x, 19), 0.008, 0.16)
    x -= x.mean(axis=0)
    x = edge_fades(x, 0.008, 0.16)
    window, step = round(0.25 * SR), round(0.025 * SR)
    crest_rms = max(float(np.sqrt(np.mean(x[i:i + window] ** 2)))
                    for i in range(0, len(x) - window, step))
    scale = min(0.22 / crest_rms, 0.78 / np.max(np.abs(x)))
    return x * scale


def waveform(x, path, color):
    width, height, count = 480, 64, 120
    chunks = np.array_split(x, count)
    levels = np.array([np.sqrt(np.mean(chunk ** 2)) for chunk in chunks])
    levels /= max(levels.max(), 1e-9)
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}">']
    for i, level in enumerate(levels):
        h = 2 + 52 * level ** 0.65
        lines.append(f'<rect x="{i * 4}" y="{(height-h)/2:.2f}" width="2.5" height="{h:.2f}" rx="1.25" fill="{color}"/>')
    lines.append('</svg>')
    path.write_text('\n'.join(lines))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = read_audio(ROOT / "audio" / "bass-reference-elevenlabs.mp3")
    entries, audit = [], []
    for number, title, description, kind, raw in studies(source):
        x = normalize(raw)
        stem = f"bass-{number}"
        wav_path, m4a_path = OUT / f"{stem}.wav", OUT / f"{stem}.m4a"
        with wave.open(str(wav_path), "wb") as f:
            f.setnchannels(2)
            f.setsampwidth(2)
            f.setframerate(SR)
            f.writeframes(np.round(x * 32767).astype('<i2').tobytes())
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(wav_path),
                        "-c:a", "aac", "-b:a", "256k", str(m4a_path)], check=True)
        waveform(x, OUT / f"{stem}.svg", "#dcc2a6" if int(number) <= 3 else "#baa5d4")
        entry = {"id": number, "title": title, "description": description,
                 "kind": kind, "duration": round(len(x) / SR, 3),
                 "waveform": f"audio/basses/{stem}.svg", "wav": f"audio/basses/{stem}.wav",
                 "audio": f"audio/basses/{stem}.m4a"}
        entries.append({**entry, "data": base64.b64encode(m4a_path.read_bytes()).decode('ascii')})
        audit.append({**entry, "peak": round(float(np.max(np.abs(x))), 5),
                      "rms": round(float(np.sqrt(np.mean(x ** 2))), 5)})
        print(number, title, f'{len(x)/SR:.2f}s', f'peak={np.max(np.abs(x)):.3f}', flush=True)
    (ROOT / "bass-library.js").write_text('// Embedded audio for local file playback. Generated by build_basses.py.\nwindow.BASS_LIBRARY = ' + json.dumps(entries, ensure_ascii=False) + ';\n')
    (OUT / "manifest.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2) + '\n')
    with zipfile.ZipFile(OUT / "firstlight-10-basses.zip", 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for e in entries:
            z.write(ROOT / e['wav'], f"bass-{e['id']}.wav")
    print('Ten isolated bass files, waveforms, bundle and WAV archive are ready.')


if __name__ == '__main__':
    main()
