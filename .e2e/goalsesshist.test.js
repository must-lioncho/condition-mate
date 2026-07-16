// E2E for the goal-add INLINE session view's PRIOR-HISTORY load (gsLoadHistory), bound to the
// REAL source (GoalAddContent.swift). Entering a resume session view fetches
// /api/goal/session/history and renders the past turns ABOVE the live area — so previous
// content is visible on open, before (and without) resuming the session. Asserts:
//   1) the fetched messages render as .su (user) / .sa (assistant) bubbles in gsLive
//   2) a leading note + a trailing "여기서부터 이어집니다" separator frame the history
//   3) a past assistant cm-question block renders as body text only (no interactive card)
//   4) an empty history renders nothing (no note, no separator)
//   5) it runs at most once per view (histLoaded guard)
const fs = require('fs');
const GA = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/GoalAddContent.swift', 'utf8');
const test = require('node:test');
const assert = require('node:assert');

function fn(src, name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0;
  for (let k = src.indexOf('{', start); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

function node(tag) {
  const n = {
    tag, children: [], className: '', textContent: '', style: {}, onclick: null,
    classList: { add(c){ if(!n.className.split(' ').includes(c)) n.className=(n.className+' '+c).trim(); },
      contains(c){ return n.className.split(' ').includes(c); } },
    addEventListener() {},
    appendChild(ch) { n.children.push(ch); return ch; },
    insertBefore(ch, ref) { const i = ref ? n.children.indexOf(ref) : -1;
      if (i < 0) n.children.unshift(ch); else n.children.splice(i, 0, ch); return ch; },
    get firstChild() { return n.children[0] || null; }
  };
  let html = '';
  Object.defineProperty(n, 'innerHTML', { get(){ return html; }, set(v){ html = v; n.children = []; } });
  return n;
}

// Collect all descendants (any depth) whose className includes `c`, in document order.
function byClass(root, c) {
  const out = [];
  const walk = m => { for (const ch of m.children) { if ((ch.className || '').split(' ').includes(c)) out.push(ch); walk(ch); } };
  walk(root); return out;
}

function boot(historyPayload) {
  const env = { fetches: [] };
  const els = {};
  global.$ = id => (els[id] = els[id] || node('div'));
  global.document = {
    createElement: t => node(t),
    createDocumentFragment: () => node('frag'),
    body: node('body'), addEventListener() {}, removeEventListener() {}
  };
  global.window = { marked: {}, innerHeight: 800, scrollY: 0, scrollTo() {} };
  global.md = t => '<md>' + t + '</md>';
  global.gsScroll = () => {};
  global.gsImgView = () => {};
  global._gs = { seq: 503, histLoaded: false };
  global.fetch = (url) => { env.fetches.push(url);
    return Promise.resolve({ json: () => Promise.resolve(historyPayload) }); };
  for (const name of ['loadMarked', 'gsExtractQ', 'gsLoadHistory'])
    eval.call(global, 'global.' + name + ' = ' + fn(GA, name));
  env.live = global.$('gsLive');
  return env;
}
const tick = () => new Promise(r => setTimeout(r, 0));

test('gsLoadHistory renders prior turns, framed by a note + separator', async () => {
  const env = boot({ source: 'chat', messages: [
    { role: 'user', text: '첫번째 지시', images: [] },
    { role: 'assistant', text: '작업 계획입니다', images: [] },
    { role: 'user', text: '사진 첨부', images: ['/chat-img/a.png'] },
  ]});
  global.gsLoadHistory(503);
  await tick();

  const note = byClass(env.live, 'shist-note');
  const users = byClass(env.live, 'su');
  const asts = byClass(env.live, 'sa');
  const sep = byClass(env.live, 'shist-sep');
  const imgs = byClass(env.live, 'satt');

  assert.strictEqual(note.length, 1, 'one leading history note');
  assert.strictEqual(users.length, 2, 'two user bubbles');
  assert.strictEqual(asts.length, 1, 'one assistant bubble');
  assert.strictEqual(sep.length, 1, 'one trailing separator');
  assert.strictEqual(users[0].textContent, '첫번째 지시');
  assert.strictEqual(asts[0].innerHTML, '<md>작업 계획입니다</md>', 'assistant rendered via markdown');
  assert.strictEqual(imgs.length, 1, 'user image thumbnail wrapper rendered');
  assert.match(sep[0].innerHTML, /여기서부터 이어집니다/);
  assert.strictEqual(env.fetches[0], '/api/goal/session/history?seq=503');
});

test('past cm-question renders as body text only (no interactive card)', async () => {
  const q = '컨텍스트 한 줄\n```cm-question\n{"q":[{"ask":"무엇?","opts":[{"label":"A"},{"label":"B"}]}]}\n```';
  const env = boot({ source: 'chat', messages: [ { role: 'assistant', text: q, images: [] } ]});
  global.gsLoadHistory(503);
  await tick();
  const asts = byClass(env.live, 'sa');
  const cards = byClass(env.live, 'qcard');
  assert.strictEqual(cards.length, 0, 'no interactive question card in history');
  assert.strictEqual(asts.length, 1);
  assert.strictEqual(asts[0].innerHTML, '<md>컨텍스트 한 줄</md>', 'only the clean body, not the raw JSON block');
});

test('empty history renders nothing', async () => {
  const env = boot({ source: 'none', messages: [] });
  global.gsLoadHistory(503);
  await tick();
  assert.strictEqual(env.live.children.length, 0, 'no note/separator when there is nothing to show');
});

test('history loads at most once per view (histLoaded guard)', async () => {
  const env = boot({ source: 'chat', messages: [ { role: 'user', text: 'x', images: [] } ]});
  global.gsLoadHistory(503);
  global.gsLoadHistory(503);
  await tick();
  assert.strictEqual(env.fetches.length, 1, 'second call is a no-op');
});
