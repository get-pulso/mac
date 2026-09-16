// Visual clock copied from IntroTiming.pacing in the macOS app.
// The canvas is a lightweight sketch, not a port of the Metal shader.
const KEYS = [
  [0, 0, 0], [1, 0.06, 0.15], [4, 1.75, 0.75],
  [4.25, 2.05, 1.3], [5.6, 3.15, 0.55], [5.95, 3.6, 1.1],
  [5.95 + (6.15 - 3.6) / 0.85, 6.15, 0.6],
];
const SCENE_DURATION = KEYS.at(-1)[0];

function clamp01(value) { return Math.min(1, Math.max(0, value)); }
function smooth(a, b, value) {
  const t = clamp01((value - a) / (b - a));
  return t * t * (3 - 2 * t);
}
function shaderTime(real) {
  if (real <= 0) return 0;
  if (real >= SCENE_DURATION) return 6.15;
  const index = KEYS.findIndex((key) => key[0] > real) - 1;
  const [ra, sa, va] = KEYS[index], [rb, sb, vb] = KEYS[index + 1];
  const h = rb - ra, t = (real - ra) / h, t2 = t * t, t3 = t2 * t;
  return Math.min(sb, Math.max(sa, (2*t3 - 3*t2 + 1)*sa + (t3 - 2*t2 + t)*h*va
    + (-2*t3 + 3*t2)*sb + (t3 - t2)*h*vb));
}
function realTimeForShader(target) {
  let low = 0, high = SCENE_DURATION;
  for (let i = 0; i < 32; i++) {
    const middle = (low + high) / 2;
    if (shaderTime(middle) < target) low = middle;
    else high = middle;
  }
  return (low + high) / 2;
}
function rayIntensity(shader) {
  return smooth(0.06, 1.65, shader) * (1 - smooth(2.1, 3.6, shader));
}

const TRACKS = {
  demo: {cue: 0, trim: 1},
  full: {cue: 1.0, trim: 1},
  dawn: {cue: 1.0, trim: 0.68},
  window: {cue: 3.95, trim: 0.8, peak: null},
  hope: {cue: realTimeForShader(4.35), trim: 0.66},
};
const elements = {
  canvas: document.querySelector('#rays'),
  stage: document.querySelector('#stage'),
  window: document.querySelector('#window'),
  wordmark: document.querySelector('#wordmark'),
  mark: document.querySelector('#mark'),
  name: document.querySelector('#name'),
  welcome: document.querySelector('#welcome'),
  continue: document.querySelector('#continue'),
  caption: document.querySelector('#stage-caption'),
  time: document.querySelector('#time'),
  fill: document.querySelector('#track-fill'),
  status: document.querySelector('#status'),
  volume: document.querySelector('#volume'),
  volumeValue: document.querySelector('#volume-value'),
  soundCue: document.querySelector('#sound-cue'),
  gatherCue: document.querySelector('#gather-cue'),
  riseCue: document.querySelector('#rise-cue'),
  riseEndCue: document.querySelector('#rise-end-cue'),
  windowStart: document.querySelector('#window-start'),
  windowStartValue: document.querySelector('#window-start-value'),
  windowAlignHint: document.querySelector('#window-align-hint'),
};
const decoded = Object.create(null);
decoded.demos = Object.create(null);
let audioContext;
let masterGain;
let mode = 'demo';
let selectedDemo = 'glass';
let active = [];
let animationFrame;
let generation = 0;
let userInteracted = false;

function setStatus(message) { elements.status.textContent = message; }
function setMode(next) {
  mode = next;
  document.querySelectorAll('[data-mode]').forEach((button) => {
    const selected = button.dataset.mode === mode;
    button.classList.toggle('active', selected);
    button.setAttribute('aria-pressed', String(selected));
  });
  elements.soundCue.style.left = (100 * (mode === 'stems' ? TRACKS.dawn.cue : 1.0) / SCENE_DURATION) + '%';
}
function loadedTracks() {
  if (mode === 'demo') return decoded.demos[selectedDemo] ? [{name: 'demo', buffer: decoded.demos[selectedDemo]}] : [];
  const names = mode === 'full' ? ['full'] : ['dawn', 'window', 'hope'];
  return names.filter((name) => decoded[name]).map((name) => ({name, buffer: decoded[name]}));
}
function selectDemo(name) {
  selectedDemo = name;
  document.querySelectorAll('[data-demo-card]').forEach((card) => {
    const selected = card.dataset.demoCard === name;
    card.classList.toggle('selected', selected);
    card.querySelector('[data-demo]').setAttribute('aria-pressed', String(selected));
  });
  setMode('demo');
}
function ensureAudioContext() {
  if (!audioContext) {
    audioContext = new AudioContext();
    masterGain = audioContext.createGain();
    masterGain.gain.value = Number(elements.volume.value) / 100;
    masterGain.connect(audioContext.destination);
  }
  return audioContext;
}
async function readyAudio() {
  ensureAudioContext();
  await audioContext.resume();
  return audioContext;
}
function stopPlayback() {
  generation++;
  if (animationFrame) cancelAnimationFrame(animationFrame);
  animationFrame = undefined;
  for (const item of active) {
    item.source.onended = null;
    try { item.source.stop(); } catch { /* already ended */ }
    item.source.disconnect();
    item.gain.disconnect();
  }
  active = [];
}
function seconds(value) { return value.toFixed(2).replace('.', ',') + ' с'; }
function strongestMoment(buffer) {
  const rate = buffer.sampleRate;
  const channels = Array.from({length: buffer.numberOfChannels}, (_, index) => buffer.getChannelData(index));
  const sampleStride = Math.max(1, Math.floor(rate / 1000));
  const windowFrames = Math.max(1, Math.round(rate * 0.18));
  const stepFrames = Math.max(1, Math.round(rate * 0.03));
  let bestPower = -1, bestTime = 0;
  for (let start = 0; start < buffer.length; start += stepFrames) {
    let sum = 0, count = 0;
    const end = Math.min(buffer.length, start + windowFrames);
    for (let frame = start; frame < end; frame += sampleStride) {
      for (const channel of channels) sum += channel[frame] * channel[frame];
      count += channels.length;
    }
    const power = sum / Math.max(1, count);
    if (power > bestPower) {
      bestPower = power;
      bestTime = ((start + end) / 2) / rate;
    }
  }
  return bestTime;
}
function updateWindowAlignment(auto = false) {
  const track = TRACKS.window;
  elements.windowStart.value = String(Math.round(track.cue * 100 / 5) * 5);
  elements.windowStartValue.textContent = seconds(track.cue);
  if (track.peak === null) {
    elements.windowAlignHint.textContent = 'Можно подвинуть вручную после загрузки.';
    return;
  }
  const placedPeak = track.cue + track.peak;
  elements.windowAlignHint.textContent = (auto ? 'Найденный пик: ' : 'Пик после сдвига: ') +
    seconds(track.peak) + ' в файле → ' + seconds(placedPeak) + ' в сцене' +
    (auto && Math.abs(placedPeak - 4.25) > 0.04 ? '. Двигайте вручную.' : '.');
}
async function importFile(name, file) {
  if (!file) return;
  userInteracted = true;
  stopPlayback();
  const token = generation;
  setStatus('Открываю ' + file.name + '…');
  try {
    const context = await readyAudio();
    const buffer = await context.decodeAudioData(await file.arrayBuffer());
    if (token !== generation) return;
    decoded[name] = buffer;
    if (name === 'window') {
      TRACKS.window.trim = 0.8;
      TRACKS.window.peak = strongestMoment(buffer);
      TRACKS.window.cue = Math.round(Math.max(0, 4.25 - TRACKS.window.peak) * 20) / 20;
      updateWindowAlignment(true);
    }
    if (name === 'dawn') TRACKS.dawn.trim = 0.68;
    document.querySelector('#name-' + name).textContent =
      file.name + ' · ' + buffer.duration.toFixed(1).replace('.', ',') + ' с';
    setMode(name === 'full' ? 'full' : 'stems');
    setStatus('Загружено: ' + file.name);
  } catch (error) {
    setStatus('Не удалось открыть звук: ' + error.message);
  }
}
async function preloadBundled() {
  const bundled = window.BUNDLED_AUDIO;
  if (!bundled) return;
  setStatus('Открываю скачанные звуки…');
  try {
    const context = ensureAudioContext();
    async function decode(entry) {
      const binary = atob(entry.data);
      const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
      return context.decodeAudioData(bytes.buffer);
    }
    const demoNames = Object.keys(bundled.demos || {});
    const [dawn, full, ...demos] = await Promise.all([
      decode(bundled.dawn), decode(bundled.full),
      ...demoNames.map((name) => decode(bundled.demos[name])),
    ]);
    demoNames.forEach((name, index) => { decoded.demos[name] = demos[index]; });
    if (!decoded.dawn) {
      decoded.dawn = dawn;
      TRACKS.dawn.trim = 0.18;
      document.querySelector('#name-dawn').textContent = 'Скачано · ' + seconds(dawn.duration);
    }
    if (!decoded.full) {
      decoded.full = full;
      document.querySelector('#name-full').textContent = 'Скачано · полный дубль · ' + seconds(full.duration);
    }
    if (!decoded.window) {
      decoded.window = full;
      TRACKS.window.trim = 1;
      TRACKS.window.peak = strongestMoment(full);
      TRACKS.window.cue = Math.round(Math.max(0, 4.25 - TRACKS.window.peak) * 20) / 20;
      document.querySelector('#name-window').textContent = 'Из полного дубля · ' + seconds(full.duration);
      updateWindowAlignment(true);
    }
    if (!userInteracted) {
      setMode('demo');
      setStatus('Четыре демо готовы · выберите вариант');
    } else if (mode === 'demo') {
      setStatus('Демо готовы · выберите вариант');
    }
  } catch (error) {
    if (!userInteracted) setStatus('Не удалось открыть скачанные звуки: ' + error.message);
  }
}
function scheduleTrack(name, buffer, startAt, delay) {
  const cue = startAt + delay;
  const remaining = mode === 'full' ? SCENE_DURATION - TRACKS.full.cue : SCENE_DURATION - TRACKS[name].cue;
  const length = Math.min(buffer.duration, remaining);
  if (length <= 0) return;
  const source = audioContext.createBufferSource();
  const gain = audioContext.createGain();
  const trim = TRACKS[name].trim;
  const level = trim;
  const fadeIn = Math.min(0.1, length / 4);
  const fadeOut = Math.min(0.4, length / 4);
  source.buffer = buffer;
  gain.gain.setValueAtTime(0, cue);
  gain.gain.linearRampToValueAtTime(level, cue + fadeIn);
  gain.gain.setValueAtTime(level, cue + length - fadeOut);
  gain.gain.linearRampToValueAtTime(0, cue + length);
  source.connect(gain).connect(masterGain);
  const item = {source, gain, ended: false};
  source.onended = () => {
    item.ended = true;
    if (active.length && active.every((entry) => entry.ended) && !animationFrame) {
      setStatus('Прослушано');
    }
  };
  source.start(cue, 0, length);
  active.push(item);
}
async function playScene() {
  stopPlayback();
  const token = generation;
  const tracks = loadedTracks();
  if (!tracks.length) { setStatus('Сначала загрузите WAV или MP3'); return; }
  try {
    await readyAudio();
    if (token !== generation) return;
    const lead = 0.05;
    const startAudio = audioContext.currentTime + lead;
    const startVisual = performance.now() + lead * 1000;
    for (const {name, buffer} of tracks) scheduleTrack(name, buffer, startAudio, TRACKS[name].cue);
    setStatus(mode === 'demo' ? 'Демо «' + document.querySelector('[data-demo-card="' + selectedDemo + '"] strong').textContent + '» с анимацией' :
      mode === 'full' ? 'Полный звук с анимацией' : 'Слои с анимацией: ' + tracks.length + '/3');
    function tick() {
      if (token !== generation) return;
      const real = Math.min(SCENE_DURATION, Math.max(0, (performance.now() - startVisual) / 1000));
      setFrame(real);
      if (real < SCENE_DURATION) animationFrame = requestAnimationFrame(tick);
      else { animationFrame = undefined; setStatus('Сцена завершена'); }
    }
    tick();
  } catch (error) { setStatus('Звук недоступен: ' + error.message); }
}
async function playSound() {
  stopPlayback();
  const token = generation;
  const tracks = loadedTracks();
  if (!tracks.length) { setStatus('Сначала загрузите WAV или MP3'); return; }
  try {
    await readyAudio();
    if (token !== generation) return;
    const firstCue = Math.min(...tracks.map(({name}) => TRACKS[name].cue));
    const startAudio = audioContext.currentTime + 0.05;
    for (const {name, buffer} of tracks) {
      scheduleTrack(name, buffer, startAudio, TRACKS[name].cue - firstCue);
    }
    setFrame(5.95);
    setStatus(mode === 'demo' ? 'Звучит выбранное демо' : mode === 'full' ? 'Звучит полный дубль' : 'Звучат слои: ' + tracks.length + '/3');
  } catch (error) { setStatus('Звук недоступен: ' + error.message); }
}

function drawRays(shader) {
  const canvas = elements.canvas;
  const ratio = Math.min(2, window.devicePixelRatio || 1);
  const width = canvas.clientWidth, height = canvas.clientHeight;
  if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  const light = rayIntensity(shader);
  if (light < 0.001) return;
  const cx = width / 2, cy = height / 2;
  const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, width * 0.46);
  glow.addColorStop(0, 'rgba(235, 199, 255, ' + (0.37 * light) + ')');
  glow.addColorStop(0.45, 'rgba(151, 86, 210, ' + (0.12 * light) + ')');
  glow.addColorStop(1, 'rgba(85, 43, 145, 0)');
  ctx.fillStyle = glow;
  ctx.fillRect(0, 0, width, height);
  for (let i = 0; i < 11; i++) {
    const angle = -2.9 + i * 0.43 + Math.sin(shader * 1.5 + i * 2.1) * 0.035;
    const distance = Math.max(width, height) * (0.64 + (i % 3) * 0.13);
    const spread = 0.035 + (i % 4) * 0.018;
    const gradient = ctx.createLinearGradient(cx, cy, cx + Math.cos(angle) * distance, cy + Math.sin(angle) * distance);
    gradient.addColorStop(0, 'rgba(245, 220, 255, ' + (0.25 * light) + ')');
    gradient.addColorStop(0.5, 'rgba(186, 113, 245, ' + (0.07 * light) + ')');
    gradient.addColorStop(1, 'rgba(136, 77, 211, 0)');
    ctx.fillStyle = gradient;
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + Math.cos(angle - spread) * distance, cy + Math.sin(angle - spread) * distance);
    ctx.lineTo(cx + Math.cos(angle + spread) * distance, cy + Math.sin(angle + spread) * distance);
    ctx.closePath();
    ctx.fill();
  }
}
function setFrame(real) {
  const shader = shaderTime(real);
  elements.time.textContent = '0:' + String(Math.floor(real)).padStart(2, '0');
  elements.fill.style.width = (100 * real / SCENE_DURATION) + '%';
  elements.window.style.opacity = smooth(1.65, 2.3, shader);
  elements.mark.style.opacity = smooth(2.82, 3.58, shader);
  const name = smooth(3.7, 4.25, shader);
  elements.name.style.opacity = name;
  elements.name.style.transform = 'translateX(' + Math.round(-12 * (1 - name)) + 'px)';
  const rise = smooth(4.35, 4.95, shader);
  elements.wordmark.style.top = (50 - 37 * rise) + '%';
  elements.wordmark.style.transform = 'translate(-50%, -50%) scale(' + (1 - 0.44 * rise) + ')';
  const welcome = smooth(5, 5.3, shader);
  elements.welcome.style.opacity = welcome;
  elements.welcome.style.transform = 'translateY(' + (12 * (1 - welcome)) + 'px)';
  elements.continue.style.opacity = smooth(5.78, 6.15, shader);
  elements.caption.textContent = shader < 0.06 ? 'Свет ещё не появился' :
    shader < 2.05 ? 'Свет появляется' : shader < 3.6 ? 'Свет собирается в знак' :
      shader < 4.25 ? 'Появляется название' : 'Welcome';
  drawRays(shader);
}

async function copyPrompt(button) {
  const content = document.querySelector('#' + button.dataset.copy).textContent;
  let copied = false;
  try {
    await navigator.clipboard.writeText(content);
    copied = true;
  } catch {
    const field = document.createElement('textarea');
    field.value = content;
    document.body.append(field);
    field.select();
    copied = document.execCommand('copy');
    field.remove();
  }
  const original = button.textContent;
  button.textContent = copied ? 'Скопировано' : 'Выделите текст';
  setTimeout(() => { button.textContent = original; }, 1500);
}

for (const name of Object.keys(TRACKS)) {
  if (name === 'demo') continue;
  document.querySelector('#file-' + name).addEventListener('change', (event) => {
    importFile(name, event.target.files?.[0]);
  });
}
document.querySelectorAll('[data-demo]').forEach((button) => {
  button.addEventListener('click', () => {
    userInteracted = true;
    selectDemo(button.dataset.demo);
    playScene();
  });
});
document.querySelectorAll('[data-mode]').forEach((button) => {
  button.addEventListener('click', () => {
    userInteracted = true;
    stopPlayback();
    setMode(button.dataset.mode);
    setStatus(loadedTracks().length ? 'Готово к прослушиванию' : 'Загрузите звук для этого режима');
  });
});
document.querySelectorAll('[data-copy]').forEach((button) => {
  button.addEventListener('click', () => copyPrompt(button));
});
document.querySelector('#play-scene').addEventListener('click', playScene);
document.querySelector('#play-sound').addEventListener('click', playSound);
document.querySelector('#stop').addEventListener('click', () => {
  stopPlayback();
  setStatus('Остановлено');
  setFrame(5.95);
});
elements.volume.addEventListener('input', () => {
  elements.volumeValue.textContent = elements.volume.value + '%';
  if (audioContext) masterGain.gain.setTargetAtTime(Number(elements.volume.value) / 100, audioContext.currentTime, 0.03);
});
elements.windowStart.addEventListener('input', () => {
  userInteracted = true;
  stopPlayback();
  TRACKS.window.cue = Number(elements.windowStart.value) / 100;
  updateWindowAlignment();
  setStatus(decoded.window ? 'Начало слоя «Окно»: ' + seconds(TRACKS.window.cue) : 'Загрузите звук для слоя «Окно»');
});
elements.stage.addEventListener('dragover', (event) => {
  event.preventDefault();
  elements.stage.classList.add('drag-over');
});
elements.stage.addEventListener('dragleave', () => elements.stage.classList.remove('drag-over'));
elements.stage.addEventListener('drop', (event) => {
  event.preventDefault();
  elements.stage.classList.remove('drag-over');
  importFile('full', event.dataTransfer.files?.[0]);
});
window.addEventListener('resize', () => {
  if (!animationFrame) setFrame(5.95);
});
elements.soundCue.style.left = (100 * TRACKS.full.cue / SCENE_DURATION) + '%';
elements.gatherCue.style.left = (100 * 4.25 / SCENE_DURATION) + '%';
elements.riseCue.style.left = (100 * TRACKS.hope.cue / SCENE_DURATION) + '%';
elements.riseCue.title = 'Логотип поднимается: ' + TRACKS.hope.cue.toFixed(2).replace('.', ',') + ' с';
elements.riseEndCue.style.left = (100 * realTimeForShader(4.95) / SCENE_DURATION) + '%';
updateWindowAlignment();
setFrame(5.95);
preloadBundled();
