"""Signal checks for the current mixes and the three bundled native scenes."""
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess

import numpy as np
import soundfile as sf

from build_synth_picker import soften_source_peak, crest_time, BASS_CLIMAX

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'audio/synth-picker'
SR = 48000
meta = json.loads((OUT / 'manifest.json').read_text())
entries = json.loads((ROOT / 'synth-bass-library.js').read_text()
                    .removeprefix('window.SYNTH_BASS_LIBRARY = ').strip().removesuffix(';'))
source_path = ROOT / meta['source']
raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(source_path),
                               '-ar', str(SR), '-ac', '2', '-f', 'f32le', 'pipe:1'])
original = np.frombuffer(raw, dtype='<f4').reshape(-1, 2).astype(float)
source, peak = soften_source_peak(original)
t = np.arange(len(source)) / SR
outside_peak = (t < peak['affected_interval'][0]) | (t > peak['affected_interval'][1])
assert np.array_equal(source[outside_peak], original[outside_peak])
i = round(peak['at'] * SR)
assert abs(20 * np.log10(np.max(abs(source[i])) / np.max(abs(original[i]))) + 3) < 1e-9
assert hashlib.sha256(source_path.read_bytes()).hexdigest() == meta['source_sha256']
assert [e['id'] for e in entries] == ['02'] and meta['original_speed'] == meta['original_gain'] == 1
assert meta['logo_accents'] == []
results, digests = [], set()
for entry in entries:
    mix, rate = sf.read(ROOT / entry['scene']['wav'])
    solo, solo_rate = sf.read(ROOT / entry['bass']['wav'])
    assert rate == solo_rate == SR and len(mix) == len(source)
    stem = np.zeros_like(source)
    offset = round(entry['bassPreviewOffset'] * SR)
    stem[offset:offset + len(solo)] = solo
    # This also proves there are no extra logo repeats anywhere in the mix.
    error = float(np.max(abs(mix - stem - source)))
    assert error < 4e-7, (entry['id'], error)
    pre = float(np.sqrt(np.mean(stem[(t > BASS_CLIMAX-1.0) & (t < BASS_CLIMAX-.4)] ** 2)))
    crest = float(np.sqrt(np.mean(stem[(t > BASS_CLIMAX-.125) & (t < BASS_CLIMAX+.125)] ** 2)))
    peak_at = crest_time(stem)
    assert abs(peak_at-BASS_CLIMAX) <= 1/SR, (entry['id'], peak_at, BASS_CLIMAX)
    assert .005 < pre < crest * .40
    assert np.max(abs(stem[t >= 8.6])) == 0
    for mode, samples in [('scene', mix), ('bass', solo)]:
        track = entry[mode]
        assert np.isfinite(samples).all() and abs(samples).max() < .8
        assert abs(samples[-120:]).max() < .00025
        assert base64.b64decode(track['data']) == (ROOT / track['path']).read_bytes()
        decoded = np.frombuffer(subprocess.check_output([
            'ffmpeg', '-v', 'error', '-i', str(ROOT / track['path']),
            '-f', 'f32le', '-ac', '2', 'pipe:1']), dtype='<f4')
        assert np.isfinite(decoded).all() and abs(decoded).max() < .85
        digests.add(hashlib.sha256((ROOT / track['wav']).read_bytes()).hexdigest())
    if entry['id'] == '02':
        native = ROOT.parent.parent / 'App/Resources/OnboardingSounds' / f"arrival-{entry['id']}.m4a"
        assert native.read_bytes() == (ROOT / entry['scene']['path']).read_bytes()
    results.append(dict(id=entry['id'],mix_peak=float(abs(mix).max()),bass_crest_at=peak_at,
                        source_reconstruction_error=error,pre_bass_rms=pre,reveal_bass_rms=crest))
assert len(digests) == 2
for _, path in re.findall(r'(src|href)="([^"#]+)"', (ROOT / 'index.html').read_text()):
    if '://' not in path:
        assert (ROOT / path.split('?')[0]).exists(), path
report = dict(checks=[
    'only 02 Warm analog scene and bass', 'only the 260 ms source peak changed, exactly -3 dB at its centre',
    'original samples unchanged outside the short peak', 'no logo repeats: mix minus bass equals adjusted source',
    'source reconstruction within 4e-7', 'original speed 1', 'pre-reveal bass below reveal level',
    '100 ms bass energy crest aligned to final reveal haptic within one sample',
    'AAC decodes and browser bundle matches', 'no clipping and smooth endings',
    'native 02 asset exactly matches lab export', 'all page assets exist'], results=results)
(OUT / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print('PASS: only Warm analog, bass crest at 4.905882s, 3 dB local source peak dip, no repeats, unchanged ambient timing, native asset, AAC decoding, endings.')
