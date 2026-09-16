// All previews use one media element. Rendered mixes contain only the original,
// one selected synth bass, and a local 3 dB reduction of the original's peak.
const $ = selector => document.querySelector(selector);
const audio = $('#source-audio');
const original = window.ORIGINAL_AUDIO;
const library = window.SYNTH_BASS_LIBRARY || [];
const byId = new Map(library.map(entry => [entry.id, entry]));
const cards = new Map();
const urls = new Map();
const status = $('#now-status');
let selectedId = '02';
try {
  const saved = localStorage.getItem('firstlight-synth-bass');
  if (byId.has(saved)) selectedId = saved;
} catch (_) {}
let current = null;
let frame;
let request = 0;
audio.playbackRate = 1;
audio.volume = 1;
audio.loop = false;

function time(value) {
  return (Number.isFinite(value) ? value : 0).toFixed(1).replace('.', ',') + ' с';
}
function node(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}
function button(label, className, handler) {
  const el = node('button', className, label);
  el.type = 'button';
  el.addEventListener('click', handler);
  return el;
}
function makeCard(entry) {
  const card = node('article', 'bass-card');
  card.dataset.preset = entry.id;
  const top = node('div', 'card-top');
  top.append(node('span', 'number', entry.id), node('span', 'kind', entry.tag));
  const title = node('h3', '', entry.title);
  title.id = 'synth-title-' + entry.id;
  card.setAttribute('aria-labelledby', title.id);
  const wave = node('div', 'wave');
  const image = node('img');
  image.src = entry.waveform;
  image.alt = '';
  wave.append(image);
  const scene = button('▶ Вся сцена', 'listen', () => {
    play(entry.id, 'scene');
    $('.context-preview').scrollIntoView({
      behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth',
      block: 'start'
    });
  });
  const solo = button('Бас отдельно', 'solo', () => play(entry.id, 'bass'));
  const actions = node('div', 'card-actions');
  actions.append(scene, solo);
  const links = node('div', 'card-downloads');
  for (const [mode, label] of [['scene','Сцена WAV ↓'],['bass','Бас WAV ↓']]) {
    const a = node('a', '', label);
    a.href = entry[mode].wav;
    a.download = 'firstlight-synth-' + entry.id + (mode === 'bass' ? '-bass' : '') + '.wav';
    a.setAttribute('aria-label', 'Скачать ' + (mode === 'bass' ? 'бас' : 'сцену') + ' ' + entry.id + ': ' + entry.title);
    links.append(a);
  }
  card.append(top, title, node('p', '', entry.description), wave, actions, links);
  $('#bass-grid').append(card);
  cards.set(entry.id, {card, scene, bass:solo});
}
function select(id) {
  selectedId = id;
  try { localStorage.setItem('firstlight-synth-bass', id); } catch (_) {}
  const entry = byId.get(id);
  $('#mix-download').href = entry.scene.wav;
  $('#mix-download').download = 'firstlight-synth-' + id + '.wav';
  for (const [key, parts] of cards) parts.card.classList.toggle('selected', key === id);
}
function trackURL(id, mode) {
  const key = mode === 'original' ? 'original' : id + ':' + mode;
  if (!urls.has(key)) {
    const entry = mode === 'original' ? original : byId.get(id)[mode];
    const bytes = Uint8Array.from(atob(entry.data), c => c.charCodeAt(0));
    urls.set(key, URL.createObjectURL(new Blob([bytes], {type:entry.mime})));
  }
  return urls.get(key);
}
function setTrack(id, mode) {
  audio.pause();
  current = {id, mode};
  audio.src = trackURL(id, mode);
  audio.playbackRate = 1;
  $('#current-sound').textContent = mode === 'original' ? 'ОРИГИНАЛ · ТОЛЬКО ТВОЙ MP3'
    : id + ' / ' + byId.get(id).title.toUpperCase() + (mode === 'bass' ? ' · БАС ОТДЕЛЬНО' : ' · ВСЯ СЦЕНА');
}
function sync() {
  if (frame) cancelAnimationFrame(frame);
  frame = undefined;
  const playing = !audio.paused && !audio.ended;
  const fullPlaying = playing && current?.mode === 'scene';
  $('#scene-play').textContent = fullPlaying ? 'Ⅱ Пауза' : '▶ Вся сцена';
  $('#scene-play').setAttribute('aria-pressed', String(fullPlaying));
  $('#scene-original').setAttribute('aria-pressed', String(playing && current?.mode === 'original'));
  $('#scene-original').textContent = current?.mode === 'original' ? 'Вернуться к варианту' : 'Сравнить с оригиналом';
  $('#stop').disabled = audio.paused && audio.currentTime === 0;
  const duration = current?.mode === 'bass' ? byId.get(current.id).bass.duration : original.duration;
  status.textContent = time(audio.currentTime) + ' / ' + time(audio.duration || duration);
  const offset = current?.mode === 'bass' ? byId.get(current.id).bassPreviewOffset : 0;
  window.ArrivalScene?.render(audio.currentTime + offset);
  for (const [id, parts] of cards) {
    const matching = current?.id === id;
    parts.card.classList.toggle('playing', playing && matching && current.mode !== 'original');
    for (const mode of ['scene','bass']) {
      const active = playing && matching && current.mode === mode;
      parts[mode].textContent = active ? 'Ⅱ Пауза' : mode === 'scene' ? '▶ Вся сцена' : 'Бас отдельно';
      parts[mode].setAttribute('aria-pressed', String(active));
      parts[mode].setAttribute('aria-label', (active ? 'Пауза' : mode === 'scene' ? 'Слушать сцену' : 'Слушать бас') + ' ' + id + ': ' + byId.get(id).title);
    }
  }
  if (playing) frame = requestAnimationFrame(sync);
}
async function play(id = selectedId, mode = 'scene', offset) {
  if (!byId.has(id)) return;
  const token = ++request;
  select(id);
  const same = current?.id === id && current.mode === mode;
  if (same && !audio.paused && !audio.ended && offset === undefined) {
    audio.pause();
    return;
  }
  if (!same) setTrack(id, mode);
  if (offset !== undefined) audio.currentTime = offset;
  else if (audio.ended) audio.currentTime = 0;
  try {
    await audio.play();
    if (token === request) sync();
  } catch (error) {
    if (token !== request || error.name === 'AbortError') return;
    status.textContent = 'Не удалось воспроизвести. Попробуй ещё раз или скачай WAV.';
  }
}
function stop() {
  request++;
  audio.pause();
  audio.currentTime = 0;
  sync();
  window.ArrivalScene?.render(0);
}
for (const entry of library) makeCard(entry);
if (library.length === 1 && byId.has('02')) {
  select(selectedId);
  setTrack(selectedId, 'scene');
} else {
  status.textContent = 'Не удалось загрузить варианты. Обнови страницу.';
}
$('#scene-play').addEventListener('click', () => play(selectedId, 'scene'));
$('#scene-climax').addEventListener('click', () => play(selectedId, 'scene', 2.0));
$('#scene-original').addEventListener('click', () => {
  const mode = current?.mode === 'original' ? 'scene' : 'original';
  const at = current?.mode === 'bass' ? 0 : audio.currentTime;
  play(selectedId, mode, at);
});
$('#scene-restart').addEventListener('click', () => play(selectedId, current?.mode || 'scene', 0));
$('#stop').addEventListener('click', stop);
for (const event of ['play','pause','ended','timeupdate','seeked','loadedmetadata']) {
  audio.addEventListener(event, sync);
}
audio.addEventListener('error', () => {
  if (frame) cancelAnimationFrame(frame);
  frame = undefined;
  status.textContent = 'Не удалось открыть звук. Скачай WAV или оригинальный MP3.';
});
window.addEventListener('pagehide', () => { request++; audio.pause(); });
if (current) sync();
