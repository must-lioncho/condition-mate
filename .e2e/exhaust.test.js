// E2E for the sports-car exhaust ambient layer (recorded-loop version), bound to the REAL source
// (BGMPlayerContent.swift). Extracts the exhaust blocks (profiles, buildExhaust, voice management,
// applyExhaust, saveState + init restore) and asserts against a stub Web Audio graph + stub fetch:
//   1) profile table maps brand × drive mode to the whitelisted /exhaust-audio/ keys
//   2) buildExhaust wires the gated bus dry→masterGain and wet→convolver, gate starts closed
//   3) applyExhaust gates to playback: only (car selected && 세기>0 && playing) opens the gate
//   4) voice management: fetch+decode once per key (cached), loop=true into the bus, selection
//      change swaps the voice, a load finishing after the selection changed is dropped
//   5) saveState persists exhaust{type,drive,level}; restore validates (rejects unknown car/mode,
//      including 'highway' left over from the synthesized v1)
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/BGMPlayerContent.swift', 'utf8');
function slice(from, to) { const a = SRC.indexOf(from); const b = SRC.indexOf(to, a); if (a < 0 || b < 0) throw new Error('extract ' + from); return SRC.slice(a, b); }

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// ---------- stub Web Audio ----------
function mkParam(v) {
  return { value: v, cancelScheduledValues() {}, setValueAtTime(x) { this.value = x; },
    setTargetAtTime(x) { this.target = x; } };
}
function mkCtx() {
  const created = [];
  function node(kind) {
    const n = { kind, conns: [], gain: mkParam(1), buffer: null, loop: false, started: [], stopped: 0,
      connect(to) { n.conns.push(to); }, disconnect() { n.disconnected = true; },
      start(t, off) { n.started.push([t || 0, off || 0]); }, stop() { n.stopped++; } };
    created.push(n); return n;
  }
  return { currentTime: 0, created,
    createGain: () => node('gain'), createBufferSource: () => node('bufsrc'),
    decodeAudioData: async ab => ({ kind: 'decoded', from: ab, duration: 10 }) };
}

// ---------- extract the real source ----------
const CODE =
  // stubs the sliced code closes over (declared in un-sliced regions of the real file)
  'const STORE_KEY = "cm.bgm.state";\n' +
  'let ctx = null, masterGain = null, convolver = null;\n' +
  'let current = "hall"; const PRESETS = { hall: {} };\n' +
  'const RAIN = { none: {}, calm: {}, shower: {}, storm: {} };\n' +
  'let rainType = "none";\n' +
  'const audioEl = __audioEl; const $ = __dom; const fetch = __fetch;\n' +
  'function setPresetControls() {}\n' +
  slice('// ---------- exhaust profiles', '// ---------- mode') +
  slice('let exhBus, exhLevel', 'let ambLFOs') +
  slice('// The exhaust bus: recorded loops', '// Occasional cheer/applause swell') +
  slice('// Gate the exhaust loop', '// Main music') +
  slice('function saveState(){', 'function fmt(') +
  'function __restore(){ try{ ' + slice('const st = JSON.parse(localStorage.getItem(STORE_KEY)', '}catch(e){') + ' }catch(e){} }\n' +
  '__expose({ buildExhaust, applyExhaust, exhEnsureVoice, exhStopVoice, saveState, __restore,\n' +
  '  EXHAUST, EXH_DRIVE,\n' +
  '  setCtx(c, m, cv) { ctx = c; masterGain = m; convolver = cv; },\n' +
  '  get type() { return exhType; }, set type(v) { exhType = v; },\n' +
  '  get drive() { return exhDrive; }, set drive(v) { exhDrive = v; },\n' +
  '  nodes() { return { exhBus, exhLevel, exhDry, exhWet }; },\n' +
  '  voice() { return { src: exhSrc, key: exhSrcKey }; } });\n';

const fetches = [];
let pending = null;   // when set, the next fetch parks until pending.resolve()
global.__fetch = url => {
  fetches.push(url);
  const resp = { ok: true, arrayBuffer: async () => 'AB:' + url };
  if (pending) { const p = pending; pending = null; return new Promise(res => { p.release = () => res(resp); }); }
  return Promise.resolve(resp);
};
const dom = { exh: { value: '40' }, rain: { value: '50' }, amb: { value: '45' }, vol: { value: '100' }, music: { value: '100' } };
global.__audioEl = { paused: true };
global.__dom = id => dom[id] || (dom[id] = { value: '0' });
global.localStorage = { saved: null, getItem: () => null, setItem: (k, v) => { global.localStorage.saved = v; } };
let api = null;
global.__expose = x => { api = x; };
eval(CODE);
const tick = () => new Promise(r => setImmediate(r));

(async () => {
  // 1) profile table → whitelisted keys
  check('lambo files', api.EXHAUST.lambo.files, { idle: 'lambo-idle', city: 'lambo-city' });
  check('porsche files', api.EXHAUST.porsche.files, { idle: 'porsche-idle', city: 'porsche-city' });
  check('valid drive modes (highway dropped)', Object.keys(api.EXH_DRIVE), ['idle', 'city']);

  // 2) bus wiring: gated, dry→masterGain, wet→convolver
  const ctx = mkCtx(), master = { kind: 'master', conns: [] }, conv = { kind: 'convolver', conns: [] };
  api.setCtx(ctx, master, conv);
  api.buildExhaust();
  const N = api.nodes();
  check('gate starts closed', N.exhLevel.gain.value, 0);
  check('bus feeds the gate', N.exhBus.conns.includes(N.exhLevel), true);
  check('gate splits dry+wet', [N.exhLevel.conns.includes(N.exhDry), N.exhLevel.conns.includes(N.exhWet)], [true, true]);
  check('dry → masterGain (전체볼륨/뮤트 상속)', N.exhDry.conns.includes(master), true);
  check('wet → convolver (공간 리버브 공유)', N.exhWet.conns.includes(conv), true);

  // 3) playback gating
  global.__audioEl.paused = false;
  api.type = 'none'; api.applyExhaust(); await tick();
  check('none stays silent while playing', [N.exhLevel.gain.target, api.voice().src], [0, null]);
  api.type = 'lambo'; api.drive = 'city'; api.applyExhaust(); await tick();
  check('lambo+city+playing opens gate to 세기', N.exhLevel.gain.target, 0.4);
  global.__audioEl.paused = true; api.applyExhaust(); await tick();
  check('pause closes the gate (voice keeps looping)', [N.exhLevel.gain.target, !!api.voice().src], [0, true]);
  global.__audioEl.paused = false; dom.exh.value = '0'; api.applyExhaust(); await tick();
  check('세기 0 keeps the gate closed', N.exhLevel.gain.target, 0);
  dom.exh.value = '40';

  // 4) voice management
  let v = api.voice();
  check('voice fetched from whitelisted endpoint', fetches[0], '/exhaust-audio/lambo-city');
  check('voice loops into the bus', [v.key, v.src.loop, v.src.conns.includes(N.exhBus), v.src.started.length], ['lambo-city', true, true, 1]);
  const prev = v.src, nFetches = fetches.length;
  api.drive = 'idle'; api.applyExhaust(); await tick();
  v = api.voice();
  check('drive switch swaps the voice', [v.key, prev.stopped >= 1, v.src !== prev], ['lambo-idle', true, true]);
  api.drive = 'city'; api.applyExhaust(); await tick();
  check('decoded buffers are cached (no refetch)', fetches.length, nFetches + 1);   // idle fetched once; city reused
  // a load finishing after the selection changed must not start a voice
  pending = {};
  const parked = pending;
  api.type = 'porsche'; api.applyExhaust();            // parks on fetch
  await tick();
  api.type = 'none'; api.applyExhaust(); await tick(); // selection changes while load is in flight
  if (parked.release) parked.release();
  await tick(); await tick();
  check('stale load is dropped after 없음', api.voice().src, null);

  // 5) persistence round-trip + restore validation
  api.type = 'porsche'; api.drive = 'idle'; dom.exh.value = '70';
  api.saveState();
  const saved = JSON.parse(global.localStorage.saved);
  check('saveState persists exhaust', saved.exhaust, { type: 'porsche', drive: 'idle', level: 70 });
  api.type = 'none'; api.drive = 'city'; dom.exh.value = '40';
  global.localStorage.getItem = () => JSON.stringify({ preset: 'hall', exhaust: { type: 'porsche', drive: 'idle', level: 70 } });
  api.__restore();
  check('restore rebuilds exhaust state', [api.type, api.drive, dom.exh.value], ['porsche', 'idle', 70]);
  api.type = 'none'; api.drive = 'city';
  global.localStorage.getItem = () => JSON.stringify({ exhaust: { type: 'lambo', drive: 'highway', level: 30 } });
  api.__restore();
  check('restore rejects stale v1 highway mode', [api.type, api.drive], ['lambo', 'city']);
  global.localStorage.getItem = () => JSON.stringify({ exhaust: { type: 'ferrari', drive: 'city', level: 30 } });
  api.type = 'none';
  api.__restore();
  check('restore rejects unknown car', api.type, 'none');

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})();
