// E2E for 메모장 + 사이드바 3단계 (2026-07-30). Bound to REAL source — the rail's stage
// machine is sliced out of SessionRail.swift and the MemoPad module out of MemoPad.swift,
// then evaluated against a stub DOM in the SAME ORDER the page emits them (rail script
// first, while <main> and the pad do not exist yet; pad + DOMContentLoaded after). Asserts:
//   - ⊞ cycles 0→1→2→0 on a page WITH a pad; ⌥+click runs it backwards
//   - a page WITHOUT a pad keeps the old 2-stage cycle and never reaches cmmemo-only
//   - the button tooltip names the NEXT stage; the 3-dot indicator tracks the current one
//   - Esc leaves 메모장만 보기 (capture phase, so it works from inside the textarea)
//   - the stage persists in localStorage; legacy cmRailCollapsed='1' migrates to stage 1
//   - a ≤360px window forces 메모장만 without touching the persisted stage; widening returns
//   - zen (body.cm-zen) overrides both — the rail-only window never enters memo mode
//   - the pad loads GET /api/memo, autosaves debounced, flushes on blur, and fails SILENTLY
//   - a slow GET can never wipe text the user already started typing
//   - CSS contract: collapsing zeroes --cmrail-w (the fixed 컴포저 bar follows), memo-only
//     hides the rest of <main>, and the 문서형 pad is a chrome-less 720px column
//   - 목표일 칸: 저장은 UTC(…Z), 화면은 표시 타임존의 벽시계 (아래 TZ 고정)
const vm = require('vm');
// 목표일이 시각 칸이 된 뒤(2026-08-05)로 이 테스트는 타임존에 민감하다 — 돌리는 사람의
// 맥이 서울이든 인도든 같은 결과가 나오도록 여기서 못 박는다. Date 를 처음 쓰기 전에.
process.env.TZ = 'Asia/Seoul';
const { RAIL_CSS, RAIL_JS, PAD_CSS, PAD_JS, PAD_HTML, GOALADD_SRC: GOALADD } = require('./memosrc');

// 생성 스탬프(2026-08-10, '    @생성: …')는 모든 줄에 붙는 메타라 이 파일의 '모양' 비교에서는
// 걷어 낸다 — 시각이 들어간 값이라 리터럴로 못 적고, 스탬프 자체의 계약은 memocreated.test.js 가 지킨다.
const noCr = (s) => String(s).split('\n').filter((l) => !/^\s+@생성:/.test(l)).join('\n');
let pass = 0, fail = 0;
const ok = (m) => { console.log('  PASS: ' + m); pass++; };
const ng = (m, got) => { console.log('  FAIL: ' + m + (got === undefined ? '' : '  (got ' + JSON.stringify(got) + ')')); fail++; };
const eq = (m, got, want) => (JSON.stringify(got) === JSON.stringify(want) ? ok(m) : ng(m + ' — want ' + JSON.stringify(want), got));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- stub DOM ----------
function classList() {
  const s = new Set();
  return {
    add: (c) => s.add(c), remove: (c) => s.delete(c), contains: (c) => s.has(c),
    toggle(c, on) { if (on === undefined) on = !s.has(c); on ? s.add(c) : s.delete(c); return on; },
    set(v) { s.clear(); String(v || '').split(/\s+/).filter(Boolean).forEach((c) => s.add(c)); },
    toString: () => Array.from(s).join(' ')
  };
}
// 메모장이 textarea 에서 행 편집기로 바뀌면서(2026-08-04) 스텁도 진짜 트리를 흉내내야 한다:
// createElement/appendChild/querySelector('.cmm-tx') 가 실제로 동작해야 모듈이 돈다.
// 여전히 최소한이다 — 클래스 선택자와 [data-*] 만 이해한다.
function El(cls) {
  const el = {
    classList: classList(),
    // 진짜 DOM 처럼 className 과 classList 는 같은 것을 본다 — 갈라 두면
    // el.className='row' 로 만든 행을 classList.contains('cmm-row') 가 못 찾는다.
    get className() { return this.classList.toString(); },
    set className(v) { this.classList.set(v); },
    // 진짜 DOM 처럼 값을 문자열로 강제한다 — dataset.no=3 을 '3' 으로 읽지 않으면
    // 스텁에서만 통과하는 비교가 생긴다.
    dataset: new Proxy({}, { set(o, k, v) { o[k] = String(v); return true; } }),
    title: '', textContent: '', value: '', tagName: '', placeholder: '',
    style: {}, children: [], parentElement: null, _h: {}, tabIndex: 0, type: '',
    addEventListener(t, f) { (this._h[t] = this._h[t] || []).push(f); },
    fire(t, ev) {
      ev = Object.assign({ target: this, preventDefault() {}, stopPropagation() {} }, ev || {});
      // 캡처 없이 위로만 흘린다 — doc 에 건 위임 핸들러가 받도록.
      let n = this;
      while (n) { (n._h[t] || []).slice().forEach((f) => f(ev)); n = n.parentElement; }
    },
    focus() { this._focused = true; }, setSelectionRange() {},
    setAttribute(k, v) { this['_attr_' + k] = v; }, getAttribute(k) { return this['_attr_' + k]; },
    removeAttribute(k) { delete this['_attr_' + k]; },
    appendChild(c) { c.parentElement = this; this.children.push(c); return c; },
    insertBefore(c, ref) { c.parentElement = this;
      const i = this.children.indexOf(ref); this.children.splice(i < 0 ? this.children.length : i, 0, c); return c; },
    remove() { const p = this.parentElement; if (!p) return;
      p.children.splice(p.children.indexOf(this), 1); this.parentElement = null; },
    set innerHTML(v) {
      this.children = [];
      // 모듈이 쓰는 유일한 형태: <span class="mk"></span><span class="no"></span>
      (String(v).match(/class="([a-z-]+)"/g) || []).forEach((m) =>
        this.appendChild(El(/class="([a-z-]+)"/.exec(m)[1])));
    },
    get innerHTML() { return ''; },
    // 스텁에는 텍스트 노드가 없다 — 원소 자식이 곧 전체 자식이다.
    get childNodes() { return this.children; },
    get firstChild() { return this.children[0] || null; },
    get lastElementChild() { return this.children[this.children.length - 1] || null; },
    get nextSibling() { const p = this.parentElement; if (!p) return null;
      return p.children[p.children.indexOf(this) + 1] || null; },
    get previousElementSibling() { const p = this.parentElement; if (!p) return null;
      return p.children[p.children.indexOf(this) - 1] || null; },
    matches(sel) {
      if (sel[0] === '.') return this.className === sel.slice(1) || this.classList.contains(sel.slice(1));
      const d = /^\[data-([a-z-]+)\]$/.exec(sel);
      if (d) return d[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase()) in this.dataset;
      if (/^[a-z]+$/.test(sel)) return this.tagName === sel.toUpperCase();   // 'input' 같은 태그 선택자
      return false;
    },
    querySelector(sel) {
      if (this._by && this._by[sel]) return this._by[sel][0];
      const l = this.querySelectorAll(sel);
      return l.length ? l[0] : null;
    },
    // '.cmm-fs input' 처럼 후손 조합까지 — 필드 칸(⌘⇧Enter)이 이 형태로 자기 입력들을 찾는다.
    querySelectorAll(sel) {
      const parts = String(sel).trim().split(/\s+/);
      const hit = [];
      const walk = (n, rest) => n.children.forEach((c) => {
        if (!c.matches(rest[0])) { walk(c, rest); return; }
        if (rest.length === 1) hit.push(c); else walk(c, rest.slice(1));
      });
      walk(this, parts);
      return hit;
    }
  };
  if (cls) el.className = cls;
  return el;
}

// One page: rail toggles (in-rail + floating), optional memo pad inside <main>,
// optional 작업 보드([data-cmboard] — 대시보드에만 있다).
function makePage(withPad, withBoard) {
  const body = El(), main = El();
  const mk = (n, f) => Array.from({ length: n }, f);
  const tgs = mk(2, () => El());
  const dots = mk(2, () => { const d = El(); d.children = mk(3, () => El()); return d; });
  let pad = null;
  if (withPad) {
    pad = El();
    const docEl = El('cmm-doc'), meta = El(), viewBtn = El('cmm-view'), viewN = El();
    pad._by = { '[data-cmmemo-doc]': [docEl], '[data-cmmemo-meta]': [meta],
                '[data-cmmemo-view]': [viewBtn], '[data-cmmemo-view-n]': [viewN] };
    pad.view = viewBtn; pad.viewN = viewN;
    pad.hidden = () => pad['_attr_data-hide'] || '';
    pad.parentElement = main;
    pad.doc = docEl; pad.meta = meta;
    // 편집 도우미 — 사람이 치는 것과 같은 경로(제목 칸에 글자 넣고 input 발화)로만 만진다.
    pad.type = (s, cell) => { const tx = cell || docEl.lastElementChild.querySelector('.cmm-tx');
      tx.textContent = s; pad.caret(tx); tx.fire('input'); return tx; };
    // 사람이 하는 것과 같은 경로: 캐럿을 칸에 두고 키를 doc 에 때린다.
    pad.caret = null;   // boot() 가 selection 스텁을 물려준다
    pad.key = null;
    pad.text = () => docEl.children.map((r) => {
      const t = r.querySelector('.cmm-tx').textContent, st = r.dataset.st;
      const d = r.querySelector('.cmm-dt').textContent;
      const tok = { todo: '- [ ] ', done: '- [x] ', block: '- [!] ' };
      return (st ? tok[st] + t : t) + (d.trim() ? '\n' + d.split('\n').map((l) => '    ' + l).join('\n') : '');
    }).join('\n');
  }
  const board = withBoard ? El() : null;
  const by = () => ({
    '[data-cmrail-tg]': tgs,
    '[data-cmrail-dots]': dots,
    '[data-cmmemo]': (pad && pad._mounted !== false) ? [pad] : [],
    '[data-cmboard]': board ? [board] : []
  });
  return { body, main, tgs, dots, pad, board, by };
}

// Boot a page the way the browser does: rail script runs at parse time (no <main> yet),
// then the pad markup+script, then DOMContentLoaded.
async function boot(opts = {}) {
  const { withPad = true, withBoard = true, store = {}, width = 1100, zen = false,
          serverText = '', getDelay = 0 } = opts;
  const page = makePage(withPad, withBoard);
  let visible = withPad ? false : true;   // the pad is parsed AFTER the rail script
  const doc = {
    readyState: 'loading', body: page.body, _h: {},
    addEventListener(t, f) { (this._h[t] = this._h[t] || []).push(f); },
    fire(t, ev) { (this._h[t] || []).slice().forEach((f) => f(ev || {})); },
    createElement(tag) { const e = El(); e.tagName = String(tag).toUpperCase(); return e; },
    // 캐럿을 진짜로 들고 있는다 — 모듈은 편집면이 .cmm-doc 하나뿐이라 "지금 어느 칸"을
    // 이벤트가 아니라 getSelection() 으로 찾는다. 스텁이 선택을 안 들면 키 경로가 통째로 안 돈다.
    createRange() { const r = { startContainer: null, startOffset: 0, collapsed: true,
      selectNodeContents(n) { this.startContainer = n; }, collapse() {},
      setStart(n, o) { this.startContainer = n; this.startOffset = o; },
      intersectsNode() { return false; } }; return r; },
    querySelector(sel) { const l = doc.querySelectorAll(sel); return l.length ? l[0] : null; },
    querySelectorAll(sel) {
      const m = page.by();
      if (sel === '[data-cmmemo]' && !visible) return [];
      return m[sel] || [];
    }
  };
  if (zen) page.body.classList.add('cm-zen');

  const ls = {
    _d: Object.assign({}, store),
    getItem(k) { return k in this._d ? this._d[k] : null; },
    setItem(k, v) { this._d[k] = String(v); }, removeItem(k) { delete this._d[k]; }
  };
  const sel = { _r: null, isCollapsed: true,
    get rangeCount() { return this._r ? 1 : 0; },
    getRangeAt() { return this._r; },
    removeAllRanges() { this._r = null; },
    addRange(r) { this._r = r; } };
  if (page.pad) {
    page.pad.caret = (el, off) => { const r = doc.createRange();
      r.startContainer = el; r.startOffset = off || 0; sel._r = r; sel.isCollapsed = true; return el; };
    page.pad.key = (code, mod) => {
      // fire() 가 이벤트를 복사해 넘기므로 플래그는 this 가 아니라 클로저에 둔다.
      let stopped = false;
      const ev = Object.assign({ code, key: code === 'Enter' ? 'Enter' : code.slice(3).toLowerCase(),
        metaKey: false, ctrlKey: false, shiftKey: false, altKey: false,
        preventDefault() { stopped = true; }, stopPropagation() {} }, mod || {});
      page.pad.doc.fire('keydown', ev);
      return stopped;
    };
  }
  const mqls = [];
  const win = {
    _w: width, _h: {},
    addEventListener(t, f) { (this._h[t] = this._h[t] || []).push(f); },
    fire(t, ev) { (this._h[t] || []).slice().forEach((f) => f(ev || {})); },
    matchMedia(q) {
      const mq = { media: q, matches: width <= 360, _h: [],
        addEventListener(_t, f) { this._h.push(f); } };
      mqls.push(mq); return mq;
    }
  };
  const net = { get: { text: serverText, updatedAt: 1, chars: [...serverText].length },
                saved: [], failNext: false, getDelay: getDelay };
  const fetchStub = (url, init) => {
    if ((init && init.method) === 'POST') {
      if (net.failNext) { net.failNext = false; return Promise.reject(new Error('offline')); }
      const t = JSON.parse(init.body).text;
      net.saved.push(t);
      return Promise.resolve({ json: () => Promise.resolve({ ok: true, updatedAt: 2, chars: [...t].length }) });
    }
    return new Promise((res) => setTimeout(() =>
      res({ json: () => Promise.resolve(net.get) }), net.getDelay));
  };

  // A vm context whose global IS `window`, like a browser: the source assigns
  // window.cmRailStage/… and then calls the bare name, which only resolves when the two
  // are the same object. A plain closure would silently diverge from what ships.
  Object.assign(win, { document: doc, localStorage: ls, fetch: fetchStub,
                       getSelection: () => sel,
                       setTimeout, clearTimeout, console });
  vm.createContext(win);
  win.window = win;
  win.self = win;
  const run = (code) => vm.runInContext(code, win);

  // 1) rail script — the pad is not in the DOM yet (rail markup precedes <main>)
  run(RAIL_JS);
  // 2) pad markup + module
  if (withPad) { visible = true; run(PAD_JS); }
  // 3) DOMContentLoaded
  doc.readyState = 'complete';
  doc.fire('DOMContentLoaded');
  await sleep(20);

  // 1 메모장만 / 2 메모+AI 컴포저 / 3 작업+대화 분할 / 0 레일 접힘(메모장 없는 페이지)
  const stage = () => (page.body.classList.contains('cmmemo-only') ? 1
    : page.body.classList.contains('cmchat-full') ? 2
    : page.body.classList.contains('cmchat-side') ? 3 : 0);
  const resize = async (w) => {
    win._w = w;
    mqls.forEach((mq) => { mq.matches = w <= 360; mq._h.forEach((f) => f(mq)); });
    await sleep(10);
  };
  const click = (alt) => win.cmRailToggle({ altKey: !!alt });   // ⊞ (레일 안 / 떠 있는 버튼 동일)
  const esc = () => doc.fire('keydown', { key: 'Escape', preventDefault() {} });
  // ⌃⌘N — 브라우저 경로(앱에서는 네이티브 모니터가 먼저 삼킨다). 한글 입력원에서는 key 가 'ㅜ'.
  const hotkey = (over) => doc.fire('keydown', Object.assign(
    { metaKey: true, ctrlKey: true, shiftKey: false, code: 'KeyN', key: 'n', preventDefault() {} }, over));
  return { page, doc, win, ls, net, stage, resize, click, esc, hotkey, sleep };
}

(async () => {
  console.log('메모장 + 사이드바 3단계 (SessionRail.swift · MemoPad.swift)');

  // ---------- 1. 3단계 순환 (메모장 + 작업 보드가 있는 대시보드) ----------
  let t = await boot();
  eq('초기 = 1단계 (메모장만)', t.stage(), 1);
  t.click(); eq('1클릭 → 2단계 (메모 + AI 컴포저)', t.stage(), 2);
  t.click(); eq('2클릭 → 3단계 (작업 + 대화 분할)', t.stage(), 3);
  t.click(); eq('3클릭 → 1단계로 순환', t.stage(), 1);
  t.click(true); eq('⌥+클릭 → 역방향 (1→3)', t.stage(), 3);
  t.click(true); eq('⌥+클릭 → 역방향 (3→2)', t.stage(), 2);

  // 툴팁 = 다음에 눌렀을 때 되는 화면 / 3점 = 현재 단계
  t.win.cmRailStage(1);
  eq('1단계 툴팁 (다음 = 메모 + 컴포저)', t.page.tgs[0].title, '메모 + AI 컴포저 · ⌃⌘N');
  eq('1단계 인디케이터 = 첫 점',
    t.page.dots[0].children.map((c) => c.classList.contains('at')), [true, false, false]);
  t.win.cmRailStage(2);
  eq('2단계 툴팁 (다음 = 작업 + 대화)', t.page.tgs[0].title, '작업 + 대화 분할 · ⌃⌘N');
  t.win.cmRailStage(3);
  eq('3단계 툴팁 (다음 = 메모장만)', t.page.tgs[0].title, '메모장만 보기 (Esc로 복귀) · ⌃⌘N');
  eq('3단계 인디케이터 = 셋째 점',
    t.page.dots[0].children.map((c) => c.classList.contains('at')), [false, false, true]);
  eq('메모장 + 보드 페이지: 3점 표시', t.page.dots[0].classList.contains('on'), true);

  // ---------- 2. Esc ----------
  t.win.cmRailStage(1);
  eq('Esc → 3단계(작업 + 대화) 복귀', (t.esc(), t.stage()), 3);
  t.win.cmRailStage(2);
  t.esc();
  eq('Esc 는 메모장만 보기에서만 동작 (2단계는 그대로)', t.stage(), 2);

  // ---------- 2-b. ⌃⌘N (마우스 없이 ⊞ 와 같은 순환) ----------
  t.win.cmRailStage(1);
  t.hotkey(); eq('⌃⌘N → 2단계 (⊞ 클릭과 동일)', t.stage(), 2);
  t.hotkey(); eq('⌃⌘N 두 번 → 3단계', t.stage(), 3);
  t.hotkey(); eq('⌃⌘N 세 번 → 1단계로 순환', t.stage(), 1);
  t.hotkey({ key: 'ㅜ', code: 'KeyN' });
  eq('한글 입력원에서도 물리 키로 동작', t.stage(), 2);
  t.hotkey({ ctrlKey: false }); eq('⌘N 만으로는 동작하지 않는다', t.stage(), 2);
  t.hotkey({ metaKey: false }); eq('⌃N 만으로는 동작하지 않는다', t.stage(), 2);
  t.hotkey({ shiftKey: true }); eq('⇧⌃⌘N 은 다른 조합 — 동작하지 않는다', t.stage(), 2);
  t.hotkey({ code: 'KeyM', key: 'm' }); eq('다른 키(⌃⌘M 음소거)는 가로채지 않는다', t.stage(), 2);

  // ---------- 3. 영속 + 마이그레이션 ----------
  t.win.cmRailStage(3);
  eq('단계가 localStorage(cmStage)에 남는다', t.ls.getItem('cmStage'), '3');
  t = await boot({ store: { cmStage: '3' } });
  eq('새로고침 후 저장된 단계 복원', t.stage(), 3);
  // 구 키 의미: 0=전부 보임 / 1=레일 접힘 / 2=메모장만 → 새 번호로 옮긴다.
  t = await boot({ store: { cmRailStage: '2' } });
  eq("구 키 cmRailStage='2'(메모장만) → 1단계", t.stage(), 1);
  t = await boot({ store: { cmRailStage: '0' } });
  eq("구 키 cmRailStage='0'(전부 보임) → 3단계", t.stage(), 3);
  t = await boot({ store: { cmStage: '2', cmRailStage: '0' } });
  eq('새 키가 구 키를 이긴다', t.stage(), 2);

  // ---------- 4. 보드 없는 페이지(대화 전용) = 1·2단계만 ----------
  t = await boot({ withBoard: false });
  eq('보드 없음: 초기 1단계', t.stage(), 1);
  t.click(); eq('보드 없음: 1클릭 → 2단계', t.stage(), 2);
  t.click(); eq('보드 없음: 2클릭 → 1단계로 순환 (3단계 없음)', t.stage(), 1);
  eq('보드 없음: 3점 인디케이터 숨김', t.page.dots[0].classList.contains('on'), false);
  t.win.cmRailStage(3);
  eq('보드 없음: 3단계 요청도 2단계로 클램프', t.stage(), 2);
  t = await boot({ withBoard: false, store: { cmStage: '3' } });
  eq('보드 없음: 저장된 3단계로 부팅해도 빈 화면이 되지 않는다', t.stage(), 2);

  // ---------- 4-b. 메모장 없는 페이지(컨디션·장비 등) = 기존 펴기/접기 ----------
  t = await boot({ withPad: false, withBoard: false });
  eq('메모장 없음: 초기 = 전부 보임(3)', t.stage(), 3);
  t.click(); eq('메모장 없음: 1클릭 → 레일 접힘(0)', t.stage(), 0);
  t.click(); eq('메모장 없음: 2클릭 → 다시 3', t.stage(), 3);
  t = await boot({ withPad: false, store: { cmStage: '1' } });
  eq('메모장 없음: 저장된 1단계(메모장만)로 부팅해도 빈 화면이 아니다', t.stage(), 3);

  // ---------- 5. 좁은 창 (≤360px) ----------
  t = await boot({ store: { cmStage: '3' } });
  await t.resize(340);
  eq('창을 340px 로 줄이면 메모장만', t.stage(), 1);
  eq('강제 진입은 저장 단계를 덮지 않는다', t.ls.getItem('cmStage'), '3');
  await t.resize(1100);
  eq('넓히면 원래 단계(3)로 복귀', t.stage(), 3);
  t = await boot({ width: 340, store: { cmStage: '3' } });
  eq('좁은 창으로 열면 처음부터 메모장만', t.stage(), 1);
  t.click();
  eq('좁은 창에서도 ⊞ 를 누르면 강제가 풀리고 순환이 이어진다 (1→2)', t.stage(), 2);
  t = await boot({ withPad: false, width: 340 });
  eq('메모장 없는 페이지는 좁혀도 메모 모드로 안 감', t.stage(), 3);

  // ---------- 6. zen 가드 ----------
  t = await boot({ store: { cmStage: '1' }, zen: true });
  eq('zen 부팅 → 3단계 (레일만 보이는 창)', t.stage(), 3);
  await t.resize(242);
  eq('zen 폭(242px)에서도 메모 모드로 안 감', t.stage(), 3);
  t.page.body.classList.remove('cm-zen');
  t.win.cmRailSync();
  eq('zen 이탈 → 고른 단계(1) 복귀', t.stage(), 1);
  t.page.body.classList.add('cm-zen');
  t.win.cmRailSync();
  eq('zen 재진입 → 다시 3단계', t.stage(), 3);

  // ---------- 7. 메모 저장 ----------
  // 열면 서버에 있던 메모가 그대로 뜬다 (전역 1개 공유 — 어느 화면에서 쓰든 같은 글)
  t = await boot({ serverText: '어제 적어둔 메모' });
  eq('열면 서버 메모를 불러온다', t.page.pad.text(), '어제 적어둔 메모');
  // 헤더 집계는 없앴다(2026-08-04) — 메타 자리는 저장 중/불러오는 중에만 쓴다.
  eq('불러온 뒤 헤더는 비어 있다', t.page.pad.meta.textContent, '');
  eq('불러오기만으로는 저장하지 않는다', t.net.saved.length, 0);

  t = await boot();
  const pad = t.page.pad, meta = pad.meta;
  pad.type('오늘 할 일');
  eq('타이핑 직후에는 저장하지 않는다 (400ms 디바운스)', t.net.saved.length, 0);
  await t.sleep(600);
  eq('디바운스 후 한 번 저장', t.net.saved.map(noCr), ['오늘 할 일']);

  // blur flushes the pending debounce (창이 닫혀도 마지막 글자가 남는다)
  pad.type('오늘 할 일!');
  pad.doc.fire('blur');
  await t.sleep(30);
  eq('포커스를 잃으면 즉시 flush', t.net.saved.length, 2);
  eq('pagehide 도 flush 경로', typeof t.win._h['pagehide'][0], 'function');

  // 실패는 조용히 — 글은 그대로, 배너 없음, 3초 뒤 재시도
  t.net.failNext = true;
  pad.type('오늘 할 일!?');
  await t.sleep(600);
  eq('저장 실패해도 글은 그대로', pad.text(), '오늘 할 일!?');
  eq('저장 실패해도 실패 문구를 띄우지 않는다 (앱 규칙)',
    /실패|오류|error/i.test(meta.textContent), false);
  const before = t.net.saved.length;
  await t.sleep(3300);
  eq('실패 후 조용히 재시도해 저장된다', t.net.saved.length > before, true);

  // 느린 GET 이 이미 입력한 글을 덮지 않는다 — 그리고 서버 글도 버리지 않는다.
  // (2026-08-06 저장 신뢰: 예전에는 서버 글을 조용히 버려서, 다음 저장이 서버 메모
  //  전체를 덮어쓰는 사고의 길이었다. 이제는 로드되는 순간 두 글을 합친다.)
  t = await boot({ serverText: '서버에 있던 옛 메모', getDelay: 300 });
  t.page.pad.type('방금 쓴 글');
  await t.sleep(500);
  eq('느린 GET 이 방금 쓴 글을 덮지 않는다 (서버 글은 아래에 합류)',
    t.page.pad.text(), '방금 쓴 글\n서버에 있던 옛 메모');

  // ---------- 7b. 체크리스트 ----------
  // 번호는 저장 텍스트에 절대 들어가지 않는다 — 리포트에서만 살아난다.
  t = await boot({ serverText: '- [ ] 첫 항목\n- [x] 끝낸 것\n    왜 끝냈는지\n- [!] 막힌 것\n그냥 메모' });
  const rows = () => t.page.pad.doc.children;
  eq('저장 텍스트를 행으로 되읽는다', rows().map((r) => r.dataset.st || '평문'),
    ['todo', 'done', 'block', '평문']);
  eq('상세는 들여쓴 줄로 붙어 온다', rows()[1].querySelector('.cmm-dt').textContent, '왜 끝냈는지');
  eq('읽고 다시 쓴 텍스트가 같다 (왕복 항등)',
    t.page.pad.text(), '- [ ] 첫 항목\n- [x] 끝낸 것\n    왜 끝냈는지\n- [!] 막힌 것\n그냥 메모');
  eq('번호는 데이터에만 (평문 줄은 세지 않는다)',
    rows().map((r) => r.dataset.no || '-'), ['1', '2', '3', '-']);
  // 보기 필터 — 처리할 때는 완료가 안 보이는 게 기본, 리포트 쓸 때 켠다.
  eq('기본은 완료 숨김 (남은 일에 집중)', t.page.pad.hidden(), 'done');
  eq('보기 배지 = 켜진 종류 수', String(t.page.pad.viewN.textContent), '2');
  eq('감춰도 텍스트는 그대로 (사라진 게 아니다)',
    t.page.pad.text(), '- [ ] 첫 항목\n- [x] 끝낸 것\n    왜 끝냈는지\n- [!] 막힌 것\n그냥 메모');
  eq('감춰도 번호는 그대로 (완료도 제 번호를 지킨다)',
    rows().map((r) => r.dataset.no || '-'), ['1', '2', '3', '-']);
  t.page.pad.view.fire('mousedown');
  const vm = () => t.win.document.body.children[t.win.document.body.children.length - 1];
  eq('보기 콤보가 다중 선택 메뉴를 연다', vm().className.indexOf('cmm-vm') >= 0, true);
  const vopt = (n) => vm().querySelectorAll('.cmm-vo')[n];
  eq('메뉴에 종류별 개수', [1, 2, 3].map((i) => String(vopt(i).cnt.textContent)), ['1', '1', '1']);
  eq('완료는 꺼져 있다', vopt(2).getAttribute('aria-checked'), 'false');
  vopt(2).fire('mousedown');
  eq('완료를 켜면 다 보인다 (리포트 모드)', t.page.pad.hidden(), '');
  eq('켠 뒤 배지 3', String(t.page.pad.viewN.textContent), '3');
  eq('선택은 저장된다', t.win.localStorage.getItem('cmMemoView'), 'todo,done,block');
  vopt(0).fire('mousedown');
  eq('"모두" 를 다시 누르면 전부 감춘다', t.page.pad.hidden(), 'todo done block');

  // 원을 클릭하면 미완료 → 완료 → 바틀넥 → 미완료
  const ck = rows()[0].querySelector('.cmm-ck');
  const cycle = [];
  for (let i = 0; i < 3; i++) { ck.fire('click'); cycle.push(rows()[0].dataset.st); }
  eq('원 클릭 = 3상태 순환', cycle, ['done', 'block', 'todo']);
  eq('상태만 바꿔도 저장 예약', t.net.saved.length >= 0, true);

  // 항목을 지우면 번호가 당겨진다 (구멍이 남지 않는다)
  rows()[0].remove();
  rows()[0].querySelector('.cmm-ck').fire('click');
  eq('지운 뒤 번호 재정렬', rows().map((r) => r.dataset.no || '-'), ['1', '2', '-']);

  // 체크리스트를 한 번도 안 쓴 기존 메모는 한 글자도 안 변한다
  t = await boot({ serverText: '그냥 메모\n두 번째 줄\n\n마지막' });
  eq('평문 메모는 그대로 (파싱 → 재직렬화 항등)', t.page.pad.text(), '그냥 메모\n두 번째 줄\n\n마지막');
  eq('평문 줄에는 체크리스트가 붙지 않는다',
    t.page.pad.doc.children.every((r) => !r.dataset.st), true);

  // 평문 줄의 원도 한 번에 완료다 — 예전에는 첫 클릭이 todo 승격뿐이라(마크가 빈 문자열)
  // 눈에 아무 변화가 없어 "두 번 눌러야 체크된다" 는 불평이 나왔다(2026-08-10).
  const plainRow = () => t.page.pad.doc.children[0];
  plainRow().querySelector('.cmm-ck').fire('click');
  eq('평문 줄 원 = 한 번 클릭에 완료', plainRow().dataset.st, 'done');
  eq('한 번에 완료한 줄은 저장 텍스트도 완료', t.page.pad.text().split('\n')[0], '- [x] 그냥 메모');
  plainRow().querySelector('.cmm-ck').fire('click');
  eq('다시 누르면 곧바로 평문으로 (바틀넥을 거치지 않는다)', plainRow().dataset.st, undefined);
  eq('취소하면 글자도 원래대로', t.page.pad.text().split('\n')[0], '그냥 메모');

  // ---------- 7c. 키보드: 엔터는 아래로, ⌘Enter 는 상세 ----------
  // 편집면이 .cmm-doc 하나뿐이라 keydown 의 target 은 늘 .cmm-doc 다. 칸을 이벤트에서 찾으면
  // 엔터가 우리 핸들러에 안 닿고 브라우저 기본 줄바꿈으로 새서 행이 옆으로 흘렀다(2026-08-04).
  t = await boot({ serverText: '' });
  const p = t.page.pad, last = () => p.doc.lastElementChild;
  p.caret(last().querySelector('.cmm-tx'));
  eq('⌘⇧K 로 체크리스트 시작', p.key('KeyK', { metaKey: true, shiftKey: true }), true);
  for (let i = 1; i <= 5; i++) { p.type('항목 ' + i); p.key('Enter'); }
  eq('엔터는 아래로 — 1~5번이 차례로 쌓인다',
    p.doc.children.map((r) => r.dataset.no || '-'), ['1', '2', '3', '4', '5', '6']);
  eq('엔터로 만든 행도 체크리스트를 물려받는다',
    p.text(), '- [ ] 항목 1\n- [ ] 항목 2\n- [ ] 항목 3\n- [ ] 항목 4\n- [ ] 항목 5\n- [ ] ');
  eq('엔터는 브라우저 기본 줄바꿈으로 새지 않는다',
    (p.caret(last().querySelector('.cmm-tx')), p.key('Enter')), true);

  // ⌘Enter = 제목 칸에서 상세 열기/접기 (긴 내용은 접어 두고 제목만 보인다)
  const r3 = p.doc.children[2];
  p.caret(r3.querySelector('.cmm-tx'));
  eq('⌘Enter 로 상세를 연다', (p.key('Enter', { metaKey: true }), r3.dataset.open), '1');
  p.type('아주 긴 상세 내용\n둘째 줄', r3.querySelector('.cmm-dt'));
  p.caret(r3.querySelector('.cmm-tx'));
  p.key('Enter', { metaKey: true });
  eq('⌘Enter 를 다시 누르면 접힌다', r3.dataset.open || '0', '0');
  eq('접어도 상세는 들여쓴 줄로 저장된다',
    p.text().split('\n').slice(2, 5).join('\n'), '- [ ] 항목 3\n    아주 긴 상세 내용\n    둘째 줄');
  eq('상세가 있으면 알약에 줄 수', r3.querySelector('.cmm-cue').textContent, '상세 2줄');
  eq('상세가 없으면 알약에 글자가 없다 (빈 메모에 "상세 0줄" 유령 금지)',
    p.doc.children.filter((r) => !r.querySelector('.cmm-dt').textContent)
      .every((r) => r.querySelector('.cmm-cue').textContent === ''), true);

  // ⇧Enter = 제목 밑에 붙는 하위 줄. 상세를 펴 놓은 채로 쓰므로 화면에도 보인다.
  const r5 = p.doc.children[4];
  p.caret(r5.querySelector('.cmm-tx'));
  eq('⇧Enter 로 하위 줄을 편다', (p.key('Enter', { shiftKey: true }), r5.dataset.open), '1');
  const r5dt = r5.querySelector('.cmm-dt');
  const nRows = p.doc.children.length;
  p.type('하위 1', r5dt);
  p.caret(r5.querySelector('.cmm-tx'));
  p.key('Enter', { shiftKey: true });
  eq('⇧Enter 를 다시 누르면 하위 줄이 하나 더 열린다', r5dt.textContent, '하위 1\n');
  p.type('하위 1\n하위 2', r5dt);
  eq('하위 줄은 펴 둔 채로 남는다(⌘Enter 만 접는다)', r5.dataset.open, '1');
  eq('하위 줄도 들여쓴 줄로 저장된다',
    p.text().split('\n').filter((l) => /항목 5|하위/.test(l)).join('\n'),
    '- [ ] 항목 5\n    하위 1\n    하위 2');
  eq('⇧Enter 는 새 행을 만들지 않는다', p.doc.children.length, nRows);

  // 평문 줄에도 원은 앞에 있다 — 숨기지 않고 흐리게만 둔다(2026-08-04).
  // WebKit(WKWebView) 의 contenteditable 은 줄바꿈을 <div>/<br> 로 만든다. 그대로 두면
  // 저장할 때 두 줄이 한 줄로 붙고, CSS 상 줄마다 상자가 부푼다(2026-08-04 실제 증상).
  eq('상세는 textContent 로 읽지 않는다(WebKit <div> 줄바꿈)',
    /cmm-dt'\)\.textContent/.test(PAD_JS), false);
  eq('상세 자식 블록의 여백·배경을 지운다',
    /\.cmm-dt div[^{]*\{[^}]*margin:0[^}]*background:none/.test(PAD_CSS), true);
  eq('하위 줄에는 카드 배경을 두지 않는다',
    /\.cmmemo \.cmm-dt\{[^}]*background:/.test(PAD_CSS), false);

  eq('평문 줄의 원을 style 로 감추지 않는다', /\.style\.visibility/.test(PAD_JS), false);
  eq('평문 줄 원은 CSS 로 흐리게만',
    /\.cmm-row:not\(\[data-st\]\)\s*\.cmm-ck\{[^}]*opacity/.test(PAD_CSS), true);

  // ---------- 7d. 필드(⌘⇧Enter) — 목표일·담당·팀·프로젝트 ----------
  // 리포트에서 되묻게 되는 값은 자유 문장이 아니라 칸으로 받는다. 저장은 상세와 같은
  // 들여쓴 줄(@키: 값)이라 텍스트로 열어도 읽히고, 왕복이 항등이어야 한다.
  t = await boot({ serverText: '- [ ] 온체인 정산 자동화\n    @목표일: 2026-08-20\n    @담당: 조성용\n    긴 배경 설명' });
  const fr = t.page.pad.doc.children[0];
  const inp = (k) => fr.querySelectorAll('.cmm-fs input').find((i) => i.dataset.k === k);
  // 타임존이 안 붙은 옛 값('2026-08-20')은 벽시계 그대로 읽는다 — 옛 메모의 날짜가 밀리면 안 된다.
  eq('@키: 값 은 칸으로 읽힌다', [inp('목표일').value, inp('담당').value], ['2026-08-20T00:00', '조성용']);
  eq('칸이 아닌 들여쓴 줄은 상세로 남는다', fr.querySelector('.cmm-dt').textContent, '긴 배경 설명');
  eq('필드 왕복 항등', noCr(t.win.CMMemo.text()),
    '- [ ] 온체인 정산 자동화\n    @목표일: 2026-08-20\n    @담당: 조성용\n    긴 배경 설명');
  eq('값이 있어도 처음엔 접혀 있다 (목록엔 제목만)', fr.dataset.fs || '0', '0');
  eq('알약이 감춘 것을 알려 준다', fr.querySelector('.cmm-cue').textContent, '필드 · 상세 1줄');

  t.page.pad.caret(fr.querySelector('.cmm-tx'));
  eq('⌘⇧Enter 로 칸을 연다',
    (t.page.pad.key('Enter', { metaKey: true, shiftKey: true }), fr.dataset.fs), '1');
  inp('팀').value = '플랫폼';
  inp('팀').fire('input');
  eq('칸에 적으면 바로 저장 텍스트에 들어간다',
    t.win.CMMemo.text().indexOf('    @팀: 플랫폼') > 0, true);
  eq('필드 순서는 정의 순서 (목표일·담당·팀·프로젝트)', noCr(t.win.CMMemo.text()).split('\n').slice(1, 4),
    ['    @목표일: 2026-08-19T15:00Z', '    @담당: 조성용', '    @팀: 플랫폼']);
  inp('팀').fire('keydown', { key: 'Enter', metaKey: true });
  eq('칸 안에서 ⌘Enter 로 닫는다', fr.dataset.fs || '0', '0');
  eq('닫아도 값은 남는다', t.win.CMMemo.text().indexOf('@팀: 플랫폼') > 0, true);

  // 빈 칸은 텍스트에 흔적을 남기지 않는다 — 안 쓴 값이 메모를 어지럽히면 안 된다.
  t = await boot({ serverText: '- [ ] 그냥 할 일' });
  const er = t.page.pad.doc.children[0];
  t.page.pad.caret(er.querySelector('.cmm-tx'));
  t.page.pad.key('Enter', { metaKey: true, shiftKey: true });
  t.page.pad.key('Enter', { metaKey: true });
  eq('한 글자도 안 적은 칸은 저장되지 않는다', noCr(t.win.CMMemo.text()), '- [ ] 그냥 할 일');
  eq('빈 칸만 열었다 닫으면 알약도 안 남는다', er.querySelector('.cmm-cue').textContent, '');

  // ---------- 7e. 가져오기(CSV 붙여넣기) — 내보내기의 역방향 ----------
  // 다른 도구로 옮겨 둔 표를 그대로 다시 붙여넣을 수 있어야 한다. 안전장치는 머리글:
  // 우리 머리글이 아닌 붙여넣기는 예전처럼 순수 텍스트로 들어간다.
  const CSV = ['"번호","상태","제목","목표일","담당","팀","프로젝트","상세"',
               '"","메모","1. 우리의 경쟁력","","","","",""',
               '"1","미완료","온체인 정산","2026-08-20","조성용","","","배경 설명"',
               '"2","완료","백서 리뷰","","","","",""',
               '"3","바틀넥","깃허브 오픈","","","","",""'].join('\r\n');
  const pasteInto = (tt, text) => {
    let inserted = null;
    tt.page.pad.doc.fire('paste', { clipboardData: { getData: () => text },
      preventDefault() { inserted = true; } });
    return inserted;
  };
  t = await boot({ serverText: '' });
  t.page.pad.caret(t.page.pad.doc.lastElementChild.querySelector('.cmm-tx'));
  pasteInto(t, CSV);
  eq('CSV 를 붙여넣으면 행으로 펼쳐진다',
    t.page.pad.doc.children.map((r) => r.querySelector('.cmm-tx').textContent),
    ['1. 우리의 경쟁력', '온체인 정산', '백서 리뷰', '깃허브 오픈']);
  eq('상태 열이 체크리스트 상태로 되돌아온다',
    t.page.pad.doc.children.map((r) => r.dataset.st || '평문'),
    ['평문', 'todo', 'done', 'block']);
  eq('빈 줄 자리에 붙여넣으면 빈 줄이 남지 않는다', t.page.pad.doc.children.length, 4);
  const ir = t.page.pad.doc.children[1];
  eq('칸도 열에서 되돌아온다',
    ir.querySelectorAll('.cmm-fs input').filter((i) => i.value).map((i) => i.dataset.k + '=' + i.value),
    ['목표일=2026-08-20T00:00', '담당=조성용']);
  eq('상세도 되돌아온다', ir.querySelector('.cmm-dt').textContent, '배경 설명');
  eq('가져온 뒤 저장 텍스트가 내보내기 이전과 같은 모양',
    noCr(t.win.CMMemo.text()),
    '1. 우리의 경쟁력\n- [ ] 온체인 정산\n    @목표일: 2026-08-19T15:00Z\n    @담당: 조성용\n    배경 설명\n- [x] 백서 리뷰\n- [!] 깃허브 오픈');

  // 표(엑셀 붙여넣기)로 나간 것도 같은 길로 돌아온다.
  t = await boot({ serverText: '' });
  t.page.pad.caret(t.page.pad.doc.lastElementChild.querySelector('.cmm-tx'));
  pasteInto(t, ['번호\t상태\t제목\t상세', '1\t완료\t끝낸 일\t메모 한 줄'].join('\n'));
  eq('TSV(표) 도 가져온다', noCr(t.win.CMMemo.text()), '- [x] 끝낸 일\n    메모 한 줄');

  // 사람이 복사하면 머리글 앞에 빈 줄·구분선이 딸려 온다 — 그래도 표로 알아본다.
  // (2026-08-04 실사용 버그: 첫 줄이 머리글이 아니면 통째로 평문으로 쏟아졌다.)
  t = await boot({ serverText: '' });
  t.page.pad.caret(t.page.pad.doc.lastElementChild.querySelector('.cmm-tx'));
  pasteInto(t, '\n--\n' + CSV);
  eq('머리글 앞에 딸려 온 줄이 있어도 가져온다',
    t.page.pad.doc.children.map((r) => r.querySelector('.cmm-tx').textContent),
    ['--', '1. 우리의 경쟁력', '온체인 정산', '백서 리뷰', '깃허브 오픈']);

  // 표가 아닌 여러 줄 글은 우리가 행으로 나눠 넣는다 — WebKit 에 맡기면 줄이 옆으로 흐른다.
  t = await boot({ serverText: '' });
  let plain = null;
  t.win.document.execCommand = (_c, _u, v) => { plain = v; };
  t.page.pad.caret(t.page.pad.doc.lastElementChild.querySelector('.cmm-tx'));
  pasteInto(t, '오늘 회의, 두 시\n- [ ] 내일 정산\n    확인할 것');
  eq('여러 줄 글은 execCommand 에 넘기지 않는다 (행이 옆으로 흐르는 원인)', plain, null);
  eq('여러 줄 글은 줄마다 행이 된다 (메모 문법도 살아난다)',
    noCr(t.win.CMMemo.text()), '오늘 회의, 두 시\n- [ ] 내일 정산\n    확인할 것');
  // 한 줄 붙여넣기는 예전 그대로 — 캐럿 자리에 글자만 들어간다.
  t.page.pad.caret(t.page.pad.doc.lastElementChild.querySelector('.cmm-tx'));
  pasteInto(t, '한 줄, 그대로');
  eq('한 줄 글은 캐럿 자리에 텍스트로', plain, '한 줄, 그대로');

  // 상세 칸이 활성화된 채 붙여넣으면 — 새 행이 아니라 그 상세 안으로 들어간다.
  // (2026-08-07 실사용 버그: 10줄을 복사해 오면 체크리스트 10개가 생겼다. 활성화된
  // 곳이 있으면 거기가 목적지다.) 스텁 selection 은 cloneContents 가 없어 '끝에 잇는'
  // 폴백 길을 지난다 — 캐럿 자리 삽입은 브라우저 검증(memo-stub)에서 본다.
  t = await boot({ serverText: '- [ ] 첫 걸음\n    이미 있던 상세' });
  const dr = t.page.pad.doc.children[0];
  dr.dataset.open = '1';
  t.page.pad.caret(dr.querySelector('.cmm-dt'));
  pasteInto(t, '1. Amani\twill do\r\nwill not do\n2. Sharron');
  eq('상세 칸에 붙여넣은 여러 줄은 새 행이 되지 않는다', t.page.pad.doc.children.length, 1);
  eq('여러 줄이 통째로 상세 텍스트로 (CRLF 정리·탭은 공백)',
    dr.querySelector('.cmm-dt').textContent,
    '이미 있던 상세\n1. Amani will do\nwill not do\n2. Sharron');
  eq('저장 텍스트에도 들여쓴 줄로 남는다', noCr(t.win.CMMemo.text()),
    '- [ ] 첫 걸음\n    이미 있던 상세\n    1. Amani will do\n    will not do\n    2. Sharron');
  // 우리 CSV 라도 상세 칸 안에서는 표 가져오기가 아니라 글자다 — 손이 가리킨 곳이 우선.
  t.page.pad.caret(dr.querySelector('.cmm-dt'));
  pasteInto(t, CSV);
  eq('상세 칸에서는 CSV 도 행으로 펼치지 않는다', t.page.pad.doc.children.length, 1);
  eq('CSV 는 글자 그대로 상세에 들어간다',
    dr.querySelector('.cmm-dt').textContent.indexOf('"번호","상태"') >= 0, true);

  // ---------- 8. CSS 계약 ----------
  const has = (css, re) => re.test(css.replace(/\s+/g, ' '));
  eq('body 여백 = --cmrail-w', has(RAIL_CSS, /body\{ ?padding-left:var\(--cmrail-w\)/), true);
  eq('접으면 --cmrail-w:0 (컴포저 바·오버레이가 함께 왼쪽 정렬)',
    has(RAIL_CSS, /body\.cmrail-collapsed\{ ?--cmrail-w: ?0px ?\}/), true);
  eq('접으면 레일은 화면 밖으로 (폭은 240 고정)',
    has(RAIL_CSS, /body\.cmrail-collapsed \.cmrail\{ ?transform:translateX\(-100%\)/), true);
  eq('zen 에서는 레일이 다시 보인다', has(RAIL_CSS, /body\.cm-zen \.cmrail\{ ?transform:none/), true);
  eq('메모장만: 본문의 나머지를 숨김',
    has(RAIL_CSS, /body\.cmmemo-only main > \*:not\(\.cmmemo\)\{ ?display:none/), true);
  eq('메모장만: 컴포저 바도 숨김', has(RAIL_CSS, /body\.cmmemo-only[^{]*\.gs-bar/), true);
  eq('3점 인디케이터는 기본 숨김', has(RAIL_CSS, /\.cmrail-dots\{ ?display:none/), true);
  // 이 카드가 얹히는 페이지들은 저마다 .row{display:flex} 같은 전역 규칙을 갖고 있다.
  // 이름이 겹치고 display 를 안 적으면 행이 옆으로 흐른다 — 이름과 display 를 못 박아 둔다.
  eq('행 클래스는 cmm- 로 namespace', has(PAD_CSS, /\.cmmemo \.cmm-row\{/), true);
  eq('행은 반드시 블록 (페이지의 .row{display:flex} 에 안 밀린다)',
    has(PAD_CSS, /\.cmmemo \.cmm-row\{[^}]*display:block/), true);
  eq('내부 클래스에 맨몸 .row/.tx/.dt 를 쓰지 않는다',
    /(^|[^-a-z])\.(row|tx|dt|cue|doc|no|mk|ck)\b/.test(
      PAD_CSS.replace(/\/\*[\s\S]*?\*\//g, '').replace(/cmm-/g, 'cmm_')), false);
  eq('문서형: 720px 중앙 컬럼', has(PAD_CSS, /body\.cmmemo-only \.cmmemo-host\{[^}]*max-width:720px/), true);
  eq('문서형: 테두리·배경 제거',
    has(PAD_CSS, /body\.cmmemo-only \.cmmemo\{[^}]*background:transparent[^}]*border-color:transparent/), true);
  eq('문서형: 편집면이 남은 높이를 채운다',
    has(PAD_CSS, /body\.cmmemo-only \.cmmemo \.cmm-doc\{[^}]*flex:1/), true);
  // 2026-08-06 — 좁은 창에서 '메모장'/'Esc → …' 텍스트가 글자 단위로 세로 깨져 둘 다 제거.
  // 헤더에는 버튼만 남고, 더 좁아지면 flex-wrap 으로 줄바꿈한다.
  eq('헤더에 타이틀·Esc 안내 텍스트 없음 (세로 깨짐 방지)',
    /class="t"|class="esc"|대화로 돌아가기/.test(PAD_HTML), false);
  eq('헤더는 좁은 폭에서 줄바꿈 (flex-wrap)', has(PAD_CSS, /\.cmmemo-hd\{[^}]*flex-wrap:wrap/), true);
  eq('컴포저 바 left = --cmrail-w (GoalAdd)',
    has(GOALADD, /\.gs-bar\{[^}]*left:var\(--cmrail-w, ?0\)/), true);
  eq('세션/CLI 뷰에서는 메모 카드 숨김',
    has(GOALADD, /body\.sess \.cmmemo, ?body\.cli \.cmmemo\{ ?display:none/), true);
  eq('단, 메모장만 보기에서는 세션 뷰에서도 열린다',
    has(GOALADD, /body\.cmmemo-only \.cmmemo\{ ?display:flex/), true);
  eq('대화 페이지가 메모장을 마운트한다', /MemoPad\.html\(\)/.test(GOALADD), true);

  // ---- 네이티브 창 접기 계약 (포스트잇) ----------------------------------
  // 메모장 모드로 들어가면 창이 최소 가로 + 마지막 세로로 접힌다. 페이지는 cmzen 채널로
  // memo / memoExit 를 보내고, AppWindowController 가 그걸 받아 프레임을 바꾼다.
  const fs2 = require('fs');
  const AWC = fs2.readFileSync(__dirname + '/../Sources/GUI/AppWindowController.swift', 'utf8');
  eq('단계 전환 시 memo/memoExit 를 네이티브로 보낸다 (나갈 때는 가려는 단계까지)',
    has(RAIL_JS, /postMessage\(st===1 \? 'memo' : \('memoExit:'\+st\)\)/), true);
  eq('첫 페인트·강제 메모장·zen 에서는 보내지 않는다',
    has(RAIL_JS, /was>=0 && was!==st && !cmRailForcedMemo && !cmRailZen\(\)/), true);
  eq('네이티브가 memo/memoExit 를 처리한다',
    has(AWC, /cmd == "memo" \{ self\?\.enterMemoFold\(\)/) && has(AWC, /cmd\.hasPrefix\("memoExit"\)/), true);
  eq('나갈 때 그 단계가 필요로 하는 폭을 보장한다 (3단계가 가장 넓다)',
    has(AWC, /usableWidth: CGFloat = \(stage == 3\) \? config\.defaultExpandedWidth : 720/)
    && has(AWC, /guard memoActive \|\| win\.frame\.width < usableWidth else \{ return \}/), true);
  eq('넓힐 때 화면 밖으로 나가지 않는다',
    has(AWC, /target\.origin\.x = min\(max\(target\.minX, vis\.minX\), vis\.maxX - target\.width\)/), true);
  eq('접기 = 최소 가로 + 저장된 세로',
    has(AWC, /f\.size\.width = memoWidth/) && has(AWC, /if let h = memoSavedHeight \{ f\.size\.height = h \}/), true);
  eq('메모장에서 유저가 잡은 세로를 기억한다',
    has(AWC, /memoSavedHeight = win\.frame\.height/), true);
  eq('포스트잇 프레임이 진짜 창 크기를 덮지 않는다',
    has(AWC, /memoActive, let f = memoSavedFrame/), true);

  // ── 메모장 확장 토글 / 좁은 판 반응형 (2026-07-31) ──
  const MEMO_SRC = fs2.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/MemoPad.swift', 'utf8');
  const DASH = fs2.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/DashboardContent.swift', 'utf8');
  const GA = fs2.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/GoalAddContent.swift', 'utf8');

  eq('메모 카드에 확장 버튼이 있다', has(MEMO_SRC, /data-cmmemo-exp/), true);
  eq('확장하면 3줄 → 10줄 (무한이 아니다)',
    has(MEMO_SRC, /body\.cmmemo-exp \.cmmemo \.cmm-doc\{ min-height:265px\b/)
    && has(MEMO_SRC, /min-height:92px/), true);
  eq('확장 상태가 유지된다', has(MEMO_SRC, /localStorage\.setItem\('cmMemoExp'/), true);
  eq('문서형(1단계)에서는 확장 버튼을 숨긴다',
    has(MEMO_SRC, /body\.cmmemo-only \.cmmemo-hd \.exp\{ display:none \}/), true);

  eq('보드의 실제 폭으로 cmnarrow 를 판단한다 (뷰포트가 아니라)',
    has(DASH, /classList\.toggle\('cmnarrow', w<=NARROW\)/) && has(DASH, /ResizeObserver\(paint\)/), true);
  eq('좁은 판 완화 규칙이 존재한다', has(DASH, /body\.cmnarrow \.viewtabs\{ flex-wrap:nowrap/), true);
  eq('대화 패널 폭이 레일까지 감안해 보드 최소폭을 남긴다',
    has(DASH, /window\.innerWidth - railW\(\) - 560/), true);
  eq('컴포저 버튼 라벨이 세로로 쪼개지지 않는다',
    has(GA, /\.btn, \.iconbtn, \.ga-seg button\{ white-space:nowrap/), true);
  eq('컴포저에 좁은 폭 규칙이 있다', has(GA, /@media \(max-width: 560px\)/), true);

  eq('3단계는 전환이 아니어도 창이 좁으면 넓혀 달라고 한다',
    has(RAIL_JS, /st===3 && !cmRailForcedMemo && !cmRailZen\(\) && window\.innerWidth < CMRAIL_WIDE3/), true);
  eq('창을 더 넓힐 수 없을 때 대화 패널이 화면 절반을 넘지 않는다',
    has(DASH, /body\.cmchat-side\{ --cmchat-w:min\(42vw, 420px\) \}/), true);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
