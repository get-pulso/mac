"""Original ambient + one synth bass, with only the source's brief peak reduced.

No piano, sampled instruments, harmonic accompaniment or logo repeats.
The brief original peak is reduced by 3 dB; all other source samples are kept.
"""
import base64
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt
from pedalboard import Pedalboard, Reverb

ROOT = Path(__file__).resolve().parent
OUT = ROOT/'audio'/'synth-picker'
SOURCE = ROOT/'audio/instruments/ambient-references/selected-ambient-1789585822225.mp3'
SR = 48_000
TAU = 2*np.pi
F1 = 43.653528929
WINDOW = 5.56
# Match IntroPlayback.climaxAtReal (4.25 - 0.5 pacing seconds).
# Keep the original/visual clocks fixed; move only the synthesized bass stem.
VISUAL_SCALE = 4.25/WINDOW
BASS_CLIMAX = (4.25-.5)/VISUAL_SCALE
LOGO_START = 6.671/(4.25/5.56)
LOGO_END = 7.319/(4.25/5.56)
BASS_START = 2.0
BASS_END = 8.6

# A continuous synth voice carries anticipation into the bloom. The variations
# change synthesis and spectral motion, not merely level or instrument samples.
PRESETS = [
    dict(id='01',title='Мягкий 808',tag='Округлый · тёплый',kind='808',
         description='Тихое напряжение заранее, затем округлое раскрытие с мягким скольжением вниз.',
         lead=1.55,attack=.14,decay=1.18,drive=1.7,h2=.20,width=.12,room=.22),
    dict(id='02',title='Тёплый аналог',tag='Густой · плавный',kind='analog',
         description='Тёплый синт медленно открывает фильтр. На окне появляется глубокое основание и мягкие обертоны.',
         lead=2.0,attack=.27,decay=1.45,drive=1.4,h2=.30,width=.30,room=.27),
    dict(id='03',title='Глубокая волна',tag='Низкий · спокойный',kind='sub',
         description='Глубокий ровный низ поднимается одной волной и долго выдыхает. Самый гладкий тембр.',
         lead=2.35,attack=.33,decay=1.65,drive=1.15,h2=.14,width=.08,room=.18),
    dict(id='04',title='Широкий синт',tag='Объёмный · окружающий',kind='wide',
         description='Нарастающий широкий гул собирается в плотный центр. По краям остаётся мягкое стереодвижение.',
         lead=2.25,attack=.23,decay=1.48,drive=1.3,h2=.26,width=.75,room=.36),
    dict(id='05',title='Бархатный FM',tag='Текучий · электронный',kind='fm',
         description='Обертоны постепенно меняют форму и открываются в момент окна. Гладкий электронный бас с живой фактурой.',
         lead=1.9,attack=.20,decay=1.33,drive=1.15,h2=.18,width=.30,room=.30),
    dict(id='06',title='Тёплое давление',tag='Плотный · насыщенный',kind='saturated',
         description='Плотная низкая масса с мягким насыщением. Нарастание слышно заранее, раскрытие ощущается весомее.',
         lead=1.7,attack=.18,decay=1.2,drive=2.1,h2=.36,width=.20,room=.22),
    dict(id='07',title='Раскрытие',tag='Воздушный · светлеющий',kind='open',
         description='Закрытый низ постепенно набирает светлые верхние обертоны. На окне тембр раскрывается и затем оседает.',
         lead=2.4,attack=.26,decay=1.42,drive=1.25,h2=.24,width=.50,room=.35),
    dict(id='08',title='Дыхание',tag='Мягкий · воздушный',kind='breath',
         description='Лёгкая синтезаторная дымка нарастает над мягким сабом. На появлении окна низ становится ближе и плотнее.',
         lead=2.5,attack=.31,decay=1.6,drive=1.25,h2=.17,width=.60,room=.38),
    dict(id='09',title='Низкий шёлк',tag='Гладкий · подвижный',kind='phase',
         description='Плавное движение внутри тембра, глубокий центр и тонкий перелив по краям. Мягкий длинный спад.',
         lead=2.1,attack=.22,decay=1.48,drive=1.35,h2=.21,width=.55,room=.31),
    dict(id='10',title='Длинный прилив',tag='Протяжённый · ambient',kind='tide',
         description='Самая длинная подводка к окну. Большая плавная волна раскрывается целиком и растворяется до подъёма логотипа.',
         lead=2.65,attack=.40,decay=1.8,drive=1.2,h2=.23,width=.65,room=.42),
]


def smooth(a,b,t):
    v=np.clip((t-a)/(b-a),0,1)
    return v*v*(3-2*v)


def filter_audio(x,hz,kind='lowpass',order=2):
    return sosfilt(butter(order,hz,btype=kind,fs=SR,output='sos'),x,axis=0)


def crest_rms(x,span=.25):
    n,step=round(span*SR),round(.025*SR)
    return max(np.sqrt(np.mean(x[i:i+n]**2)) for i in range(0,len(x)-n+1,step))


def crest_time(x,span=.10):
    """Centre of the loudest 100 ms, long enough to include several sub cycles."""
    n=round(span*SR)
    energy=np.r_[0,np.cumsum(np.mean(x*x,axis=1))]
    return (int(np.argmax(energy[n:]-energy[:-n]))+n/2)/SR


def align_bass(bass):
    before=crest_time(bass)
    advance=round((before-BASS_CLIMAX)*SR)
    assert advance>0 and np.max(abs(bass[:advance]))==0
    aligned=np.zeros_like(bass)
    aligned[:-advance]=bass[advance:]
    return aligned,dict(previous_crest=before,advance_seconds=advance/SR,
                        crest=crest_time(aligned),target=BASS_CLIMAX)


def source_audio():
    raw=subprocess.check_output(['ffmpeg','-v','error','-i',str(SOURCE),'-ar',str(SR),'-ac','2','-f','f32le','pipe:1'])
    return np.frombuffer(raw,dtype='<f4').reshape(-1,2).astype(np.float64)


def soften_source_peak(source):
    peak=int(np.argmax(np.max(np.abs(source),axis=1)))
    at=peak/SR
    t=np.arange(len(source))/SR
    reduction=smooth(at-.10,at-.025,t)*(1-smooth(at+.035,at+.16,t))
    gain=1-(1-10**(-3/20))*reduction
    adjusted=source*gain[:,None]
    info=dict(at=at,reduction_db=3,affected_interval=[at-.10,at+.16],
              original_peak=float(np.max(abs(source))),adjusted_peak_at_cue=float(np.max(abs(adjusted[peak]))))
    return adjusted,info


def synth_bass(p,length):
    t=np.arange(length)/SR
    onset=WINDOW-p['lead']
    before=smooth(onset,WINDOW-.12,t)
    bloom=smooth(WINDOW-p['attack'],WINDOW+.025,t)
    decay=np.exp(-np.maximum(0,t-WINDOW-.10)/p['decay'])
    release=1-smooth(7.2,BASS_END,t)
    # Pre-reveal energy lives in upper bass harmonics. A continuous core enters
    # smoothly with the window, so no kick, double hit or instrumental attack.
    core_env=(.12*before+.88*bloom)*decay*release
    body_env=(.43*before+.57*bloom)*decay*release
    local=np.maximum(0,t-(WINDOW-p['attack']))
    glide=np.where(t>=WINDOW-p['attack'],np.exp(-local/.14),0)
    frequency=F1+(8 if p['kind']=='808' else 0)*glide
    phase=TAU*np.cumsum(frequency)/SR
    sub=np.sin(phase)
    mid=np.sin(2*phase)
    opening=smooth(WINDOW-.75,WINDOW+.08,t)
    if p['kind']=='808':
        core=.75*np.tanh(p['drive']*sub)
        body=.20*mid+.065*np.sin(3*phase)
    elif p['kind']=='analog':
        core=np.tanh(1.3*sub)
        body=.34*mid+.16*opening*np.sin(3*phase)+.045*opening*np.sin(4*phase)
    elif p['kind']=='sub':
        core=sub
        body=.15*mid+.055*np.sin(3*phase)
    elif p['kind']=='wide':
        core=np.tanh(1.25*sub)
        body=.28*mid+.13*opening*np.sin(3*phase)+.065*np.sin(4*phase)
    elif p['kind']=='fm':
        index=.16+.70*opening
        core=.85*sub+.15*np.sin(phase+index*np.sin(2*phase))
        body=.24*np.sin(2*phase+(.1+.55*opening)*np.sin(phase))
    elif p['kind']=='saturated':
        core=.78*np.tanh(p['drive']*sub)
        body=.32*mid+.11*opening*np.sin(3*phase)+.04*np.sin(5*phase)
    elif p['kind']=='open':
        core=sub
        body=.23*mid+.18*opening*np.sin(4*phase)+.075*opening*np.sin(6*phase)
    elif p['kind']=='breath':
        core=np.tanh(1.25*sub)
        body=.18*mid+.06*np.sin(3*phase)
    elif p['kind']=='phase':
        core=.85*sub+.15*np.sin(phase+.3*opening*np.sin(phase))
        body=.26*np.sin(2*phase+.25*np.sin(TAU*.35*t))+.08*np.sin(3*phase)
    else:
        core=sub
        body=.25*mid+.12*opening*np.sin(3*phase)+.065*opening*np.sin(4*phase)
    mono=core*core_env+body*body_env
    result=np.column_stack((mono,mono))
    # Stereo lives above the fundamental; the weight below 70 Hz stays centred.
    for channel,cents in enumerate([-.055,.055]):
        detuned=2*phase*(1+cents/12)
        motion=.15*p['width']*np.sin(detuned+.04*np.sin(TAU*.4*t+channel))*body_env
        result[:,channel]+=motion
    if p['kind'] in ['breath','tide']:
        rng=np.random.default_rng(8080+int(p['id']))
        air=filter_audio(filter_audio(rng.normal(size=(length,2)),140,'highpass'),750)
        air/=max(np.std(air),1e-8)
        result+=air*(.011*before*decay*release)[:,None]
    result=filter_audio(filter_audio(result,22,'highpass'),1100)
    send=filter_audio(result,180,'highpass')
    wet=Pedalboard([Reverb(room_size=.63,damping=.75,wet_level=p['room'],dry_level=0,width=.85)])(send.T.astype(np.float32),SR).T
    result+=filter_audio(wet,160,'highpass')
    result*=((1-smooth(8.15,BASS_END,t))*smooth(onset,onset+.06,t))[:,None]
    # Same crest level for honest comparison; the uploaded background is 1x.
    result*=.063/max(crest_rms(result),1e-9)
    return result


def waveform(x,path):
    levels=np.array([np.sqrt(np.mean(c*c)) for c in np.array_split(x,150)])
    levels/=max(levels.max(),1e-9)
    svg=['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 56">']
    for i,v in enumerate(levels):
        h=1.5+45*v**.65
        svg.append(f'<rect x="{i*4}" y="{(56-h)/2:.2f}" width="2" height="{h:.2f}" rx="1" fill="#d0b1ed"/>')
    x=(BASS_CLIMAX-BASS_START)/(BASS_END-BASS_START)*600
    svg.append(f'<path d="M{x:.2f} 2V54" stroke="#efcfaa" stroke-opacity=".7"/>')
    svg.append('</svg>');path.write_text(''.join(svg))


def export(x,name):
    wav=OUT/f'{name}.wav';aac=OUT/f'{name}.m4a'
    sf.write(wav,x,SR,subtype='PCM_24')
    subprocess.run(['ffmpeg','-v','error','-y','-i',str(wav),'-c:a','aac','-b:a','192k','-movflags','+faststart',str(aac)],check=True)
    return dict(wav=str(wav.relative_to(ROOT)),path=str(aac.relative_to(ROOT)),mime='audio/mp4',
                duration=len(x)/SR,data=base64.b64encode(aac.read_bytes()).decode())


def main():
    OUT.mkdir(exist_ok=True,parents=True)
    original=source_audio();source,peak_info=soften_source_peak(original)
    entries=[];details=[]
    for p in [preset for preset in PRESETS if preset['id']=='02']:
        bass,alignment=align_bass(synth_bass(p,len(source)))
        # Deliberately no mix-bus EQ, compressor, limiter, gain or time change.
        mix=source+bass
        assert np.max(abs(mix))<.9
        solo=bass[round(BASS_START*SR):round(BASS_END*SR)]
        stem='synth-'+p['id'];wave=OUT/f'{stem}.svg';waveform(solo,wave)
        entry=dict(id=p['id'],title=p['title'],tag=p['tag'],description=p['description'],
                   waveform=str(wave.relative_to(ROOT)),scene=export(mix,stem),bass=export(solo,stem+'-bass'),
                   bassPreviewOffset=BASS_START)
        entries.append(entry)
        dry={k:v for k,v in entry.items() if k not in ['scene','bass']}
        for mode in ['scene','bass']:dry[mode]={k:v for k,v in entry[mode].items() if k!='data'}
        dry['synthesis']=p
        dry['alignment']=alignment
        # Proof that the background was preserved as a direct 1x summand.
        dry['source_reconstruction_error']=float(np.max(np.abs((mix-bass)-source)))
        dry['peak']=float(np.max(abs(mix)))
        dry['bass_crest_rms']=float(crest_rms(bass))
        details.append(dry)
        print(f"{p['id']} {p['title']}: bass crest {alignment['crest']:.6f}s, advance {alignment['advance_seconds']:.3f}s",flush=True)
    (ROOT/'synth-bass-library.js').write_text('window.SYNTH_BASS_LIBRARY = '+json.dumps(entries,ensure_ascii=False)+';\n')
    meta=dict(source=str(SOURCE.relative_to(ROOT)),source_sha256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              original_speed=1,original_gain=1,duration=len(source)/SR,
              timing=dict(window=WINDOW,bass_climax=BASS_CLIMAX,visual_scale=VISUAL_SCALE,
                          logo_start=LOGO_START,logo_end=LOGO_END),
              peak_reduction=peak_info,logo_accents=[],variants=details)
    (OUT/'manifest.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n')
    native=ROOT.parent.parent/'App'/'Resources'/'OnboardingSounds'
    native.mkdir(parents=True,exist_ok=True)
    for variant in ['02']:
        (native/f'arrival-{variant}.m4a').write_bytes((OUT/f'synth-{variant}.m4a').read_bytes())
    for removed in ['04','10']:
        (native/f'arrival-{removed}.m4a').unlink(missing_ok=True)
    print('Done: only 02 Warm analog; bass crest aligned to final reveal haptic.',flush=True)


if __name__=='__main__':main()
