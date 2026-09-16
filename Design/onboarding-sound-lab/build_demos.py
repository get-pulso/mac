"""Render local Firstlight sound studies from the two downloaded ElevenLabs clips.

The generated tones add a genuine harmonic change at the window cue and a
separate upward answer at the logo rise. This script keeps the studies
reproducible; it does not call a sound-generation API.
"""

from array import array
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import wave


ROOT = Path(__file__).parent
RATE = 48_000
LENGTH = 9.0
WINDOW = 4.25
RISE = 6.67
# The native logo reaches the header at shader 4.95, real time 7.319 s.
RISE_END = 7.32
FRAMES = round(RATE * LENGTH)
TWO_PI = 2 * math.pi


def read_audio(path):
    raw = subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(path), "-ar", str(RATE),
        "-ac", "2", "-f", "f32le", "pipe:1",
    ])
    samples = array("f")
    samples.frombytes(raw)
    if sys.byteorder != "little":
        samples.byteswap()
    return samples


def lowpass(source, cutoff):
    filtered = array("f", [0]) * len(source)
    weight = 1 - math.exp(-TWO_PI * cutoff / RATE)
    left = right = 0.0
    for frame in range(len(source) // 2):
        left += weight * (source[2 * frame] - left)
        right += weight * (source[2 * frame + 1] - right)
        filtered[2 * frame] = left
        filtered[2 * frame + 1] = right
    return filtered


def highpass(source, cutoff):
    lows = lowpass(source, cutoff)
    return array("f", (sample - low for sample, low in zip(source, lows)))


def notch(source, frequency, quality=7):
    angle = TWO_PI * frequency / RATE
    alpha = math.sin(angle) / (2 * quality)
    a0 = 1 + alpha
    b0, b1, b2 = 1 / a0, -2 * math.cos(angle) / a0, 1 / a0
    a1, a2 = b1, (1 - alpha) / a0
    output = array("f", [0]) * len(source)
    previous = [[0.0, 0.0, 0.0, 0.0] for _ in range(2)]
    for frame in range(len(source) // 2):
        for channel in range(2):
            index = frame * 2 + channel
            x = source[index]
            x1, x2, y1, y2 = previous[channel]
            y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[index] = y
            previous[channel] = [x, x1, y, y1]
    return output


def add_clip(output, source, at, gain, duration=None, rate=1, fade_in=0.1, fade_out=0.3):
    source_frames = len(source) // 2
    total = min(round((source_frames / RATE if duration is None else duration) * RATE),
                FRAMES - round(at * RATE))
    start = round(at * RATE)
    for index in range(total):
        position = index * rate
        integer = int(position)
        if integer + 1 >= source_frames:
            break
        fraction = position - integer
        t = index / RATE
        envelope = min(1, t / max(fade_in, 0.001),
                       (total / RATE - t) / max(fade_out, 0.001))
        level = gain * max(0, envelope)
        target = 2 * (start + index)
        source_index = 2 * integer
        output[target] += ((1 - fraction) * source[source_index] +
                           fraction * source[source_index + 2]) * level
        output[target + 1] += ((1 - fraction) * source[source_index + 1] +
                               fraction * source[source_index + 3]) * level


def add_tone(output, frequency, at, duration, gain, style="glass", attack=0.04,
             decay=1.0, pan=0):
    start = round(at * RATE)
    count = min(round(duration * RATE), FRAMES - start)
    left = math.sqrt((1 - pan) / 2)
    right = math.sqrt((1 + pan) / 2)
    phase = 0.0
    for index in range(count):
        t = index / RATE
        if style == "felt":
            envelope = (1 - math.exp(-t / max(attack, 0.001))) * math.exp(-t / decay)
            harmonics = (1.0, 0.23 * math.exp(-t / 0.5), 0.055 * math.exp(-t / 0.22))
        else:
            envelope = (1 - math.exp(-t / max(attack, 0.001))) * math.exp(-max(0, t - 0.3) / decay)
            harmonics = (1.0, 0.31, 0.08 * math.exp(-t / 0.8))
        # Slow pitch drift and slightly inharmonic upper partials keep the tone
        # near the bowed-glass texture without a sharp digital ping.
        phase += TWO_PI * frequency * (1 + 0.0007 * math.sin(TWO_PI * 0.62 * t)) / RATE
        sample = (harmonics[0] * math.sin(phase) +
                  harmonics[1] * math.sin(2.005 * phase) +
                  harmonics[2] * math.sin(3.012 * phase))
        sample *= gain * envelope
        target = 2 * (start + index)
        output[target] += sample * left
        output[target + 1] += sample * right


def add_bass(output, gain):
    """A rounded E-flat bass note with enough harmonics for laptop speakers."""
    start = round(WINDOW * RATE)
    count = round(1.8 * RATE)
    for index in range(count):
        t = index / RATE
        envelope = (1 - math.exp(-t / 0.026)) * math.exp(-t / 0.73)
        phase = TWO_PI * 77.78 * t
        sample = gain * envelope * (0.62 * math.sin(phase) +
                                    0.32 * math.sin(2 * phase) +
                                    0.16 * math.sin(3 * phase))
        target = 2 * (start + index)
        output[target] += sample * 0.71
        output[target + 1] += sample * 0.71


def add_ambient_808(output, gain):
    """Soft E-flat sub with a slow 808 pitch settle and audible laptop harmonics."""
    start = round(WINDOW * RATE)
    duration = 2.65
    count = round(duration * RATE)
    phase = 0.0
    for index in range(count):
        t = index / RATE
        frequency = 38.89 * (1 + 0.16 * math.exp(-t / 0.17))
        phase += TWO_PI * frequency / RATE
        fade_in = 1 - math.exp(-t / 0.055)
        fade_out = min(1, (duration - t) / 0.45)
        body = 0.67 * math.exp(-t / 1.25) + 0.33 * math.exp(-t / 2.2)
        envelope = fade_in * max(0, fade_out) * body
        # The 39 Hz fundamental gives headphone weight; the 78/117/156 Hz
        # overtones preserve the bass on built-in computer speakers.
        sample = gain * envelope * (0.85 * math.sin(phase) +
                                    0.58 * math.sin(2 * phase) +
                                    0.24 * math.sin(3 * phase) +
                                    0.10 * math.sin(4 * phase))
        target = 2 * (start + index)
        output[target] += sample * 0.71
        output[target + 1] += sample * 0.71


def add_logo_motif(output, first, second, style, gain):
    """A distinct note at lift-off, then a quieter answer at the settled logo."""
    add_tone(output, first, RISE, 0.9, gain, style,
             0.025 if style == "felt" else 0.055, 0.42, -0.1)
    add_tone(output, second, RISE_END, 1.45, gain * 0.27, style,
             0.04 if style == "felt" else 0.085, 0.78, 0.15)


def soft_room(output):
    dry = array("f", output)
    for delay, gain in [(0.12, 0.09), (0.23, 0.07), (0.37, 0.045)]:
        offset = round(delay * RATE)
        for frame in range(offset, FRAMES):
            target = 2 * frame
            source = 2 * (frame - offset)
            output[target] += dry[source + 1] * gain
            output[target + 1] += dry[source] * gain


def finish(output, target_rms=0.045):
    soft_room(output)
    # Compare versions at similar loudness while retaining each version's arc.
    active = output[2 * RATE:]
    rms = math.sqrt(sum(value * value for value in active) / len(active))
    peak = max(abs(value) for value in output)
    scale = min(target_rms / max(rms, 1e-8), 0.62 / max(peak, 1e-8))
    for frame in range(FRAMES):
        end_fade = min(1, (LENGTH - frame / RATE) / 0.55)
        level = scale * max(0, end_fade)
        output[2 * frame] *= level
        output[2 * frame + 1] *= level
    return rms, peak, scale


def write_waveform(output, name):
    colors = {"glass": "#d9b8f0", "felt": "#efd2bb", "airy": "#b9dbe5", "original": "#a29aaa"}
    width, height, bars = 600, 76, 150
    power = []
    for index in range(bars):
        first = (index * FRAMES) // bars
        last = ((index + 1) * FRAMES) // bars
        stride = 24
        values = (output[2 * frame] ** 2 + output[2 * frame + 1] ** 2
                  for frame in range(first, last, stride))
        count = max(1, (last - first + stride - 1) // stride)
        power.append(math.sqrt(sum(values) / (2 * count)))
    maximum = max(power) or 1
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img">',
             '<line x1="0" x2="600" y1="38" y2="38" stroke="#ffffff18"/>']
    for index, rms in enumerate(power):
        size = 3 + 28 * math.sqrt(rms / maximum)
        x = 2 + index * 4
        lines.append(f'<rect x="{x}" y="{(height-size)/2:.1f}" width="2.5" height="{size:.1f}" rx="1.25" fill="{colors[name]}" opacity="0.82"/>')
    for cue, color in [(WINDOW, "#efd0a7"), (RISE, "#c4d9ed"),
                       (RISE_END, "#c4d9ed88")]:
        x = cue / LENGTH * width
        lines.append(f'<line x1="{x:.1f}" x2="{x:.1f}" y1="4" y2="72" stroke="{color}" stroke-width="1.3" opacity="0.9"/>')
    lines.append('</svg>')
    suffix = "-ambient808" if name == "felt" else "-bass" if name != "original" else ""
    (ROOT / "audio" / "generated" / f"demo-{name}{suffix}.svg").write_text("\n".join(lines) + "\n")


def render(name, dawn, reveal):
    output = array("f", [0]) * (2 * FRAMES)
    if name == "original":
        add_clip(output, reveal, 1.0, 1.0, duration=7.95, fade_in=0.05, fade_out=0.55)
    else:
        # The downloaded dawn has an F-sharp line against the reveal's E-flat
        # harmony. Only its upper airy texture is used behind the first rays.
        add_clip(output, dawn, 1.0, 1.3, duration=3.25,
                 fade_in=0.4, fade_out=0.7)
        add_clip(output, reveal, 1.15, 1.12 if name == "glass" else 0.95,
                 duration=7.8, fade_in=0.25, fade_out=0.7)

        if name == "glass":
            add_tone(output, 392.0, WINDOW, 2.4, 0.092, "glass", 0.055, 1.15, -0.12)  # G4
            add_tone(output, 784.0, WINDOW + 0.06, 2.0, 0.033, "glass", 0.11, 0.9, 0.18)
            add_bass(output, 0.17)
            add_logo_motif(output, 698.46, 783.99, "glass", 0.052)  # F5 -> G5
        elif name == "felt":
            for frequency, gain, delay in [(311.13, 0.075, 0), (392.0, 0.085, 0.04),
                                           (466.16, 0.063, 0.08)]:  # Eb4, G4, Bb4
                add_tone(output, frequency, WINDOW + delay, 2.4, gain,
                         "felt", 0.013, 0.88, (delay - 0.04) * 3)
            add_ambient_808(output, 0.23)
            add_logo_motif(output, 587.33, 622.25, "felt", 0.07)  # D5 -> Eb5
        elif name == "airy":
            add_tone(output, 155.56, WINDOW, 2.5, 0.045, "glass", 0.1, 1.4, 0)  # Eb3
            add_tone(output, 392.0, WINDOW + 0.02, 2.5, 0.065,
                     "glass", 0.13, 1.25, -0.2)
            add_tone(output, 783.99, WINDOW + 0.1, 2.1, 0.055,
                     "glass", 0.12, 1.0, 0.24)
            add_bass(output, 0.15)
            add_logo_motif(output, 466.16, 622.25, "glass", 0.048)  # Bb4 -> Eb5
    rms, peak, scale = finish(output)
    write_waveform(output, name)
    with tempfile.TemporaryDirectory(prefix="firstlight-sound-") as folder:
        wav_path = Path(folder) / f"{name}.wav"
        pcm = array("h", (round(max(-1, min(1, value)) * 32767) for value in output))
        if sys.byteorder != "little":
            pcm.byteswap()
        with wave.open(str(wav_path), "wb") as wav:
            wav.setnchannels(2)
            wav.setsampwidth(2)
            wav.setframerate(RATE)
            wav.writeframes(pcm.tobytes())
        suffix = "-ambient808" if name == "felt" else "-bass" if name != "original" else ""
        destination = ROOT / "audio" / "generated" / f"demo-{name}{suffix}.m4a"
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(wav_path),
                        "-c:a", "aac", "-b:a", "256k", str(destination)], check=True)
    print(f"{name}: source RMS {rms:.4f}, peak {peak:.3f}, gain {scale:.2f}, {destination.stat().st_size} bytes")


def main():
    reveal = read_audio(ROOT / "audio" / "reveal-elevenlabs.m4a")
    dawn = read_audio(ROOT / "audio" / "dawn-elevenlabs.m4a")
    for _ in range(3):
        dawn = highpass(dawn, 1800)
    dawn = notch(notch(dawn, 740), 1480)
    for name in ("glass", "felt", "airy", "original"):
        render(name, dawn, reveal)


if __name__ == "__main__":
    main()
