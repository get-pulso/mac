"""Ten Firstlight cues: downloaded ambient textures, piano resolution and soft 808.

Run with Python, audio-requirements.txt and ffmpeg. All timings are in seconds.
No model-generated music or third-party audio service is required. The shared
motif, score and sound parameters are explicit so we can revise one decision.
"""
from __future__ import annotations

import base64
from fractions import Fraction
from functools import lru_cache
import json
from pathlib import Path
import subprocess
import zipfile

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt, resample_poly
from pedalboard import Pedalboard, Reverb, Compressor, Chorus, HighpassFilter

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'audio' / 'soft808-compositions'
SR = 48_000
DURATION = 10.0
N = round(DURATION * SR)
REVEAL, RISE, ARRIVAL = 4.25, 6.671, 7.319
AMBIENT_START = .88
AMBIENT_TRIM = .35
AMBIENT_SOURCE_CREST = 5.56
AMBIENT_TEMPO = (AMBIENT_SOURCE_CREST-AMBIENT_TRIM)/(REVEAL-AMBIENT_START)
AMBIENT_FILE = 'selected-ambient-1789585822225.mp3'
TAU = 2 * np.pi

# Every variation stays in F and uses the same soft, gently saturated 808 voice.
# tuple: attack, hold, decay, initial pitch offset, glide decay, drive, harmonic2
PRESETS = [
    dict(id='01', title='Тёплый вдох', tag='Сбалансированный',
         description='Воздушная фактура постепенно открывается в светлый аккорд. Округлый 808 поддерживает раскрытие и отпускает.',
         bass=(.06,.30,1.35,24,.11,1.65,.18), motif=(60,62,65,67,69),
         chord=(53,57,60,67), room=.53, wet=.19, color=1450, pad=.025, piano=1., tail=1.),
    dict(id='02', title='Бархат', tag='Медленнее и мягче',
         description='Тёплое тягучее вступление и широкий мягкий вход баса. Аккорд остаётся близко, 808 дышит дольше.',
         bass=(.13,.46,1.65,11,.16,1.3,.16), motif=(60,62,65,67,69),
         chord=(53,57,60,65), room=.50, wet=.17, color=980, pad=.032, piano=.88, tail=1.12),
    dict(id='03', title='Первый свет', tag='Яснее кульминация',
         description='Прозрачное атмосферное начало раскрывается вверх. Чётче очерченный 808 и более открытый аккорд.',
         bass=(.045,.27,1.15,29,.085,1.85,.20), motif=(60,64,65,69,72),
         chord=(53,57,60,67), room=.56, wet=.21, color=2200, pad=.027, piano=1.06, tail=1.05),
    dict(id='04', title='Медленная волна', tag='Плавнее раскрытие',
         description='808 разворачивается широкой волной под протяжённым аккордом. Финальная фраза звучит выше и легче.',
         bass=(.18,.53,1.8,9,.20,1.4,.13), motif=(60,62,65,69,72),
         chord=(53,60,65,69), room=.62, wet=.23, color=1250, pad=.039, piano=.84, tail=1.25),
    dict(id='05', title='Тихая уверенность', tag='Короче и собраннее',
         description='Мягкий 808 ближе к исходному №05. Небольшой аккорд и тихий восходящий ответ без длинного басового хвоста.',
         bass=(.035,.22,1.05,35,.09,1.9,.20), motif=(60,62,65,67,69),
         chord=(53,57,60), room=.46, wet=.16, color=1500, pad=.020, piano=.90, tail=.90),
    dict(id='06', title='Воздух', tag='Больше пространства',
         description='Плотный мягкий низ в центре, прозрачный аккорд по краям. Мотив раскрывается выше и растворяется в общем пространстве.',
         bass=(.085,.38,1.42,16,.12,1.4,.12), motif=(67,69,72,74,77),
         chord=(53,60,65,69), room=.67, wet=.27, color=1750, pad=.028, piano=.80, tail=1.15),
    dict(id='07', title='Навстречу', tag='Теплее и плотнее',
         description='Тёплая атмосфера собирается в аккорд с ощутимыми обертонами мягкого 808. Тихий восходящий ответ в финале.',
         bass=(.065,.36,1.4,22,.13,1.8,.27), motif=(62,64,65,67,69),
         chord=(53,57,60,69), room=.52, wet=.19, color=1550, pad=.028, piano=.95, tail=1.),
    dict(id='08', title='Близко', tag='Камерный',
         description='Мягкая атмосферная подводка и близкий аккорд. Низ раскрывается вместе с окном и уступает место двум последним нотам.',
         bass=(.05,.24,1.18,12,.10,1.5,.18), motif=(60,62,65,67,69),
         chord=(53,57,60,65), room=.35, wet=.12, color=1300, pad=.018, piano=1.08, tail=.92),
    dict(id='09', title='Послесвечение', tag='Дольше светлый хвост',
         description='Протяжённое вступление, плавно оседающий бас и остающаяся гармония. Тихий ответ держит свет после подъёма логотипа.',
         bass=(.11,.42,1.60,18,.16,1.35,.15), motif=(60,62,65,69,72),
         chord=(53,57,60,67), room=.64, wet=.25, color=1450, pad=.032, piano=.87, tail=1.30),
    dict(id='10', title='Открытый горизонт', tag='Самое широкое раскрытие',
         description='Воздушное вступление раскрывается в глубокий округлый 808 и мажорный аккорд с секстой. Тихое движение вверх в финале.',
         bass=(.09,.50,1.62,20,.14,1.6,.21), motif=(60,64,65,69,74),
         chord=(53,57,60,62,67), room=.60, wet=.22, color=1850, pad=.036, piano=1.02, tail=1.16),
]


def smooth(a, b, t):
    x = np.clip((t-a)/(b-a), 0, 1)
    return x*x*(3-2*x)


def stereo(x):
    return np.column_stack((x, x)) if x.ndim == 1 else x


def filt(x, freq, kind='lowpass', order=2):
    return sosfilt(butter(order, freq, btype=kind, fs=SR, output='sos'), x, axis=0)


def crest_rms(x, width=.25):
    step, window = round(.025*SR), round(width*SR)
    return max(np.sqrt(np.mean(x[i:i+window]**2)) for i in range(0, len(x)-window+1, step))


def level(x, rms):
    return x * (rms/max(crest_rms(x), 1e-8))


def put(bus, clip, at):
    start = round(at*SR)
    length = min(len(clip), len(bus)-start)
    if length > 0:
        bus[start:start+length] += stereo(clip[:length])


def process(x, effects):
    return Pedalboard(effects)(x.T.astype(np.float32), SR).T.astype(np.float64)


@lru_cache(maxsize=48)
def piano_source(midi):
    roots = {53: '016', 61: '020', 69: '024', 77: '028'}
    root = min(roots, key=lambda note: abs(note-midi))
    x, source_sr = sf.read(ROOT / 'audio' / 'instruments' / f'Player_dyn1_rr1_{roots[root]}.wav')
    # Resample the sample for pitch, keeping the acoustic decay and hammer body.
    ratio = Fraction(SR/source_sr * 2**((root-midi)/12)).limit_denominator(4096)
    x = resample_poly(stereo(x), ratio.numerator, ratio.denominator, axis=0)
    x = filt(x, 110, 'highpass')
    return x


def piano_note(midi, length, gain, color, pan=0, attack=.028):
    source = piano_source(midi)
    x = np.zeros((round(length*SR), 2))
    n = min(len(x), len(source))
    x[:n] = source[:n]
    # Felt-like softening, still a sampled piano, not a sinusoidal imitation.
    x = filt(x, color)
    t = np.arange(len(x))/SR
    x *= (smooth(0, attack, t) * (1-smooth(max(.2,length-.7), length, t)))[:,None]
    x = level(x, gain)
    mid = x.mean(axis=1)
    side = (x[:,0]-x[:,1])*.20
    x = np.column_stack((mid*(1-pan*.25)+side, mid*(1+pan*.25)-side))
    return x


def soft808(p):
    attack, hold, decay, glide, glide_time, drive, h2 = p['bass']
    length = 4.35
    t = np.arange(round(length*SR))/SR
    frequency = 43.653528929 + glide*np.exp(-t/glide_time)
    phase = TAU*np.cumsum(frequency)/SR
    x = .72*np.tanh(drive*np.sin(phase)) + h2*np.sin(2*phase) + .07*np.sin(3*phase)
    env = np.sin(np.minimum(t/attack,1)*np.pi/2)**2
    env *= np.exp(-np.maximum(0,t-attack-hold)/decay)
    env *= 1-smooth(2.9, length-.04, t)
    x = filt(filt(x*env, 20, 'highpass'), 700)
    x *= smooth(0,.006,t)*(1-smooth(length-.16,length,t))
    # A common audition level makes differences about shape and tone.
    return stereo(level(x, .205))


def continuous_pad(p):
    t = np.arange(N)/SR
    # The same oscillators continue through the reveal. The suspended G resolves
    # to A, while C remains a common tone. F appears in the low register at reveal.
    resolution = smooth(REVEAL-.10, REVEAL+.24, t)
    amp = np.interp(t, [0,.85,1.5,3.8,4.25,4.65,5.8,6.67,7.32,8.5,9.95,10],
                    [0,0,.16,.45,1,.92,.7,.58,.48,.28,0,0])
    amp *= smooth(.85,1.65,t)*(1-smooth(8.2,9.95,t))
    voices = [(60,60,.75), (67,69,.53), (74,74,.24), (53,53,.53)]
    pad = np.zeros((N,2))
    for index,(before,after,weight) in enumerate(voices):
        note = before+(after-before)*resolution
        frequency = 440*2**((note-69)/12)
        voice_amp = amp*(resolution if index==3 else 1)
        for channel,detune in enumerate([-.0020,.0020]):
            phase = TAU*np.cumsum(frequency*(1+detune))/SR + index*.67
            wave = np.sin(phase)+.14*np.sin(2*phase)+.035*np.sin(3*phase)
            wave *= 1+.012*np.sin(TAU*.31*t+channel*.8+index)
            pad[:,channel] += wave*voice_amp*weight
    pad = level(filt(pad,1700),p['pad'])
    return process(pad,[Chorus(rate_hz=.19,depth=.08,centre_delay_ms=8,feedback=.015,mix=.08)])


@lru_cache(maxsize=1)
def ambient_material():
    """Use only the newly selected MP3, preserving its F/G texture and pitch.

    Its actual duration is 16.08 s despite the eight-second filename. The
    strongest 400 ms body is centred at 5.56 s. Trim only the quiet lead-in and
    time-compress with Rubber Band so that this body arrives at the window.
    Keep its continuous release underneath the logo movement.
    """
    directory = ROOT/'audio'/'instruments'/'ambient-references'
    data = subprocess.check_output([
        'ffmpeg','-v','error','-i',str(directory/AMBIENT_FILE),'-af',
        f'atrim=start={AMBIENT_TRIM},asetpts=PTS-STARTPTS,rubberband=tempo={AMBIENT_TEMPO:.12f}',
        '-ar',str(SR),'-ac','2','-f','f32le','pipe:1',
    ])
    body=np.frombuffer(data,dtype='<f4').reshape(-1,2).astype(np.float64)
    # Retain the source's high air and middle body, clear only the deep bass.
    body=filt(filt(body,120,'highpass'),6800)
    # Time stretching changes the envelope slightly. Align its rendered 400 ms
    # crest as well as the nominal source marker; remove only quiet lead-in.
    width,step=round(.4*SR),round(.01*SR)
    energy=[np.mean(body[i:i+width]**2) for i in range(0,len(body)-width,step)]
    peak=int(np.argmax(energy))*step+width//2
    advance=peak-round((REVEAL-AMBIENT_START)*SR)
    if advance>=0:
        body=body[advance:]
    else:
        body=np.pad(body,((-advance,0),(0,0)))
    return level(body,.053),advance/SR


def ambient_intro(p):
    bed=np.zeros((N,2))
    body,_=ambient_material()
    put(bed,body,AMBIENT_START)
    t=np.arange(N)/SR
    # The source supplies the whole arc, including its natural decay, with no
    # source replacement or crossfade at the climax. All presets share this bed.
    return bed*(smooth(AMBIENT_START,1.25,t)*(1-smooth(8.4,9.95,t)))[:,None]


def compose(p, bass):
    piano = np.zeros((N,2))
    motif = p['motif']
    events = []
    times = (1.62,2.935,REVEAL,RISE,ARRIVAL)
    gains = (.020,.027,.052,.030,.022)
    lengths = (4.2,3.7,4.2,3.2,2.65)
    for i,(note,at,gain,length) in enumerate(zip(motif,times,gains,lengths)):
        if i < 2:
            continue  # The opening now belongs to the continuous ambient bed.
        put(piano,piano_note(note,length,gain*p['piano']*(p['tail'] if i>2 else 1),
                             p['color']*.90,pan=(i-2)*.12,attack=.055 if i==2 else .028),at)
        events.append(dict(at=at,midi=note,role='motif',rms=gain*p['piano']))
    # Voicing arrives with the window. Slight finger
    # spread is 12 ms, never a separate delayed chord or an extra impact.
    for index,note in enumerate(p['chord']):
        at=REVEAL + index*.012
        gain=.021/np.sqrt(len(p['chord'])/4)
        put(piano,piano_note(note,4.4,gain*p['piano'],p['color']*.80,
                             pan=(index-1.5)*.12,attack=.065),at)
        events.append(dict(at=at,midi=note,role='chord',rms=gain*p['piano']))

    pad = continuous_pad(p)
    t = np.arange(N)/SR
    # The selected source already holds F/G. A quiet supporting pad contributes
    # A/C at reveal, opening that suspended texture into F major add9.
    pad *= (.08+.55*smooth(3.65,4.6,t))[:,None]
    atmosphere = ambient_intro(p)
    bass_bus = np.zeros((N,2))
    # Begin the rounded attack just before the window opens. The piano resolves
    # at 4.25 s while the bass continues to bloom through the reveal.
    bass_at = REVEAL-p['bass'][0]*.55
    put(bass_bus,bass*(.155/.205),bass_at)
    shared = piano+pad+atmosphere
    # The source already has its own space; avoid washing it in a second room.
    send = piano+pad+atmosphere*.12 + filt(bass_bus,190,'highpass')*.11
    room = process(send,[Reverb(room_size=p['room'],damping=.68,wet_level=p['wet'],dry_level=0,width=.82)])
    room = filt(room,210,'highpass')
    mix = shared+bass_bus+room
    mix = process(mix,[HighpassFilter(cutoff_frequency_hz=19),
                       Compressor(threshold_db=-15,ratio=1.45,attack_ms=55,release_ms=250)])
    t = np.arange(N)/SR
    mix *= (smooth(0,.08,t)*(1-smooth(8.55,9.99,t)))[:,None]
    gain = min(.165/crest_rms(mix), .80/np.max(np.abs(mix)))
    mix *= gain
    return mix,dict(motif=events,opening=dict(type='selected_mp3_full_arc',start=AMBIENT_START,
                    sources=[AMBIENT_FILE],body_transpose_semitones=0,
                    source_trim=AMBIENT_TRIM,source_crest=AMBIENT_SOURCE_CREST,
                    body_tempo=AMBIENT_TEMPO,rendered_alignment_trim=ambient_material()[1],
                    mapped_crest=REVEAL,fade_out=[8.4,9.95]),
                    bass_start=bass_at,root_hz=43.653528929,
                    bass_parameters=dict(zip(['attack','hold','decay','glide_hz','glide_decay','drive','second_harmonic'],p['bass'])),
                    master_gain=gain,peak=float(np.max(np.abs(mix))),
                    crest_rms=float(crest_rms(mix)),room=p['room'],wet=p['wet'])


def waveform(x,path):
    levels=np.array([np.sqrt(np.mean(part**2)) for part in np.array_split(x,160)])
    levels/=max(levels.max(),1e-9)
    svg=['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 64">']
    for i,value in enumerate(levels):
        height=1.5+48*value**.65
        svg.append(f'<rect x="{i*4}" y="{(64-height)/2:.2f}" width="2" height="{height:.2f}" rx="1" fill="#d0b1ed"/>')
    # The same timeline as the scene. Marks are evidence of alignment, not
    # an invented waveform; bar heights come from the exported PCM.
    for seconds in (REVEAL,RISE,ARRIVAL):
        x=seconds/DURATION*640
        svg.append(f'<path d="M{x:.1f} 3V61" stroke="#eed4b2" stroke-opacity=".44" stroke-width="1"/>')
    svg.append('</svg>')
    path.write_text(''.join(svg))


def export(x,stem):
    wav=OUT/f'{stem}.wav'
    m4a=OUT/f'{stem}.m4a'
    sf.write(wav,x,SR,subtype='PCM_24')
    subprocess.run(['ffmpeg','-v','error','-y','-i',str(wav),'-c:a','aac','-b:a','192k','-movflags','+faststart',str(m4a)],check=True)
    return dict(wav=str(wav.relative_to(ROOT)),m4a=str(m4a.relative_to(ROOT)),
                duration=len(x)/SR,data=base64.b64encode(m4a.read_bytes()).decode())


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    entries=[]
    manifest=[]
    for p in PRESETS:
        bass=soft808(p)
        mix,score=compose(p,bass)
        stem=f"soft808-{p['id']}"
        wave=OUT/f'{stem}.svg'
        waveform(mix,wave)
        entry=dict(id=p['id'],title=p['title'],description=p['description'],tag=p['tag'],
                   waveform=str(wave.relative_to(ROOT)),scene=export(mix,stem),bass=export(bass,f'{stem}-bass'))
        entries.append(entry)
        public={**entry,'scene':{k:v for k,v in entry['scene'].items() if k!='data'},
                'bass':{k:v for k,v in entry['bass'].items() if k!='data'},'score':score}
        manifest.append(public)
        print(f"{p['id']} {p['title']}: peak {score['peak']:.3f}, RMS {score['crest_rms']:.3f}",flush=True)
    (ROOT/'composition-library.js').write_text('window.COMPOSITION_LIBRARY = '+json.dumps(entries,ensure_ascii=False)+';\n')
    metadata=dict(duration=DURATION,sample_rate=SR,timing=dict(window=REVEAL,logo_start=RISE,logo_end=ARRIVAL),
                  provenance='Locally arranged: user-selected An_8-second_sound_cu_#3-1789585822225.mp3, VSCO 2 CE piano (CC0), synthesized soft 808 and pad, Spotify Pedalboard effects.',
                  presets=manifest)
    (OUT/'manifest.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n')
    with zipfile.ZipFile(OUT/'firstlight-soft808-10.zip','w',zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(OUT.glob('*.wav')):
            archive.write(path,path.name)
        archive.write(OUT/'manifest.json','manifest.json')
        archive.write(ROOT/'SOUND_DESIGN.md','SOUND_DESIGN.md')
    print('Finished: 10 full cues + 10 solo 808 auditions.',flush=True)


if __name__=='__main__':
    main()
