// E2E for Slack 번역함 재트리거 ordering — 👀를 제거했다가 다시 달면 그 항목이
// 새 항목이 아니라 "기존 항목이 미처리 맨 위로" 돌아와야 한다. Bound to REAL
// source: pulls trigAt() out of SlackTranslateContent.swift and retrigger() /
// rewriteItem() out of the daemon (slack-eyes-daemon.mjs), then runs them against
// a temp items.jsonl + a stub app endpoint. Asserts:
//   - 정렬 기준 = 트리거 발생 시각(triggeredAt, 없으면 reactedAt) 내림차순
//   - retrigger가 items.jsonl의 그 줄만 패치하고(append 아님) 다른 줄은 그대로
//   - retrigger가 POST /api/slack/done {done:false, sync:false} 를 보낸다
//     (sync:false = 슬랙에 다시 미러하지 않음 → 이벤트 루프 방지)
//   - 멘션 항목에 👀를 달면 emoji가 붙어 이후 리액션 동기화 대상이 된다
//   - 페이지가 시간 표시·정렬 모두 trigAt 기준을 쓴다
const fs = require('fs');
const os = require('os');
const path = require('path');

const PAGE = fs.readFileSync(__dirname + '/../Sources/Slack/SlackTranslateContent.swift', 'utf8');
const DAEMON = fs.readFileSync(__dirname + '/../Sources/Slack/Daemon/slack-eyes-daemon.mjs', 'utf8');

// 소스에서 함수 하나를 통째로 떼어낸다. 기본값 파라미터(patch = {})가 있어도
// 본문 여는 중괄호를 찾도록 파라미터 괄호를 먼저 건너뛰고, async 접두사도 살린다.
function fn(src, name, label) {
  let start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name + ' in ' + label);
  if (src.slice(start - 6, start) === 'async ') start -= 6;
  let paren = 0;
  let i = src.indexOf('(', start);
  for (; i < src.length; i++) {
    if (src[i] === '(') paren++;
    else if (src[i] === ')') { paren--; if (paren === 0) break; }
  }
  let depth = 0;
  for (let k = src.indexOf('{', i); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

let fails = 0;
const ok = (cond, msg) => { console.log((cond ? '  ok   ' : '  FAIL ') + msg); if (!cond) fails++; };

// ---------------------------------------------------------------- 1. 정렬 기준
eval(fn(PAGE, 'trigAt', 'page'));

// 최초 수집은 오래됐지만 방금 👀를 다시 단 항목(b)이 맨 위여야 한다.
const a = { id: 'C1:1', reactedAt: 2000 };
const b = { id: 'C1:2', reactedAt: 1000, triggeredAt: 3000 };
const c = { id: 'C1:3', reactedAt: 1500 };
const sorted = [a, b, c].slice().sort((x, y) => trigAt(y) - trigAt(x)).map(i => i.id);
ok(JSON.stringify(sorted) === JSON.stringify(['C1:2', 'C1:1', 'C1:3']),
  '재트리거된 항목이 맨 위 (triggeredAt 기준 내림차순): ' + sorted.join(' > '));
ok(trigAt({ reactedAt: 7 }) === 7, 'triggeredAt 없으면 reactedAt으로 폴백 (기존 항목 호환)');
ok(trigAt({}) === 0, '둘 다 없으면 0 (정렬 중 NaN 금지)');

// 페이지가 실제로 그 기준을 쓰는지 — 정렬·시간 표시 모두.
ok(/sort\(\(a,b\)=>trigAt\(b\)-trigAt\(a\)\)/.test(PAGE), '목록 정렬이 trigAt을 쓴다');
ok(/when\(trigAt\(it\)\)/.test(PAGE), '항목 시간 표시가 trigAt을 쓴다 (정렬과 같은 값)');
ok(/const noEmoji = !it\.emoji && !!it\.source/.test(PAGE),
  '멘션 항목이라도 emoji가 붙었으면 처리완료 라벨이 리액션 제거를 안내한다');

// ---------------------------------------------------------------- 2. 데몬 retrigger
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'slackretrig-'));
const ITEMS_FILE = path.join(dir, 'items.jsonl');
const rows = [
  { id: 'C1:1', reactedAt: 2000, emoji: 'eyes', textEn: 'first' },
  { id: 'C1:2', reactedAt: 1000, emoji: 'eyes', textEn: 'second' },
  { id: 'C1:3', reactedAt: 1500, source: 'mention', textEn: 'mention' },
];
fs.writeFileSync(ITEMS_FILE, rows.map(r => JSON.stringify(r)).join('\n') + '\n');

const posted = [];
const logs = [];
const ctx = {
  ITEMS_FILE,
  readFileSync: fs.readFileSync,
  writeFileSync: fs.writeFileSync,
  renameSync: fs.renameSync,
  log: (...m) => logs.push(m.join(' ')),
  ping: () => {},
  setDoneRemote: async (id, done) => { posted.push({ id, done }); return true; },
};
const load = () => fs.readFileSync(ITEMS_FILE, 'utf8').trim().split('\n').map(JSON.parse);

// 실제 소스에서 두 함수만 떼어내 스텁 컨텍스트에 바인딩한다.
const body = fn(DAEMON, 'rewriteItem', 'daemon') + '\n' + fn(DAEMON, 'retrigger', 'daemon')
  + '\nreturn { rewriteItem, retrigger };';
const { retrigger } = new Function(...Object.keys(ctx), body)(...Object.values(ctx));

(async () => {
  await retrigger('C1:2', 9000, { emoji: 'eyes' });
  let items = load();
  ok(items.length === 3, 'retrigger는 줄을 추가하지 않는다 (새 항목 생성 금지): ' + items.length + '줄');
  const patched = items.find(i => i.id === 'C1:2');
  ok(patched.triggeredAt === 9000, 'triggeredAt이 트리거 발생 시각으로 갱신됐다');
  ok(patched.reactedAt === 1000 && patched.textEn === 'second',
    '기존 필드(최초 수집 시각·본문)는 보존된다');
  ok(items.find(i => i.id === 'C1:1').triggeredAt === undefined, '다른 줄은 건드리지 않는다');
  ok(posted.length === 1 && posted[0].id === 'C1:2' && posted[0].done === false,
    '처리완료 해제를 앱에 알린다 (done:false)');

  // 정렬 재확인 — 방금 재트리거된 항목이 실제로 맨 위.
  const top = load().slice().sort((x, y) => trigAt(y) - trigAt(x))[0];
  ok(top.id === 'C1:2', '재트리거 직후 그 항목이 미처리 목록 맨 위: ' + top.id);

  // 멘션 항목에 👀 → emoji가 붙는다 (이후 처리완료 시 리액션 동기화 대상).
  await retrigger('C1:3', 9500, { emoji: 'eyes' });
  const mention = load().find(i => i.id === 'C1:3');
  ok(mention.emoji === 'eyes' && mention.source === 'mention',
    '멘션 항목에 👀를 달면 emoji가 붙고 source는 유지된다');

  // 루프 가드 — 데몬이 보내는 done 갱신은 슬랙으로 다시 미러되면 안 된다.
  ok(/JSON\.stringify\(\{ id, done, sync: false \}\)/.test(DAEMON),
    'setDoneRemote는 sync:false로 POST한다 (슬랙 미러백 없음 → 이벤트 루프 방지)');
  // 이미 수집된 메시지의 리액션은 새 항목이 아니라 재트리거로 간다.
  ok(/if \(seen\.has\(id\)\) retrigger\(id, at, \{ emoji: e\.reaction \}\)/.test(DAEMON),
    '👀 reaction_added: 이미 수집된 id면 processMessage 대신 retrigger');
  ok(/if \(seen\.has\(id\)\) retrigger\(id, at, \{ later: true \}\)/.test(DAEMON),
    '🔖/📌 reaction_added: 이미 수집된 id면 retrigger + later 플래그');
  // reconcile은 열린 항목 전부를 훑되(비트리거 리액션 검사 때문), 이모지 사라짐
  // 감지는 emoji가 붙은 항목·옛 👀 항목에만 적용한다 — 👀가 붙은 멘션 항목 포함.
  ok(/const open = loadItems\(\)\.filter\(\(o\) => !done\[o\.id\]\)/.test(DAEMON),
    'reconcile은 열린 항목 전부를 훑는다 (멘션·DM도 비트리거 리액션 검사 대상)');
  ok(/const hasTrigger = !!o\.emoji \|\| !o\.source/.test(DAEMON),
    '이모지 사라짐 감지 대상 = emoji가 있거나 멘션이 아닌 항목');
  ok(/if \(hasTrigger && !still\)/.test(DAEMON),
    '멘션류(트리거 이모지 없음)는 이모지 사라짐으로 오판해 처리완료되지 않는다');

  fs.rmSync(dir, { recursive: true, force: true });
  console.log(fails ? `\n${fails} FAILED` : '\nall passed');
  process.exit(fails ? 1 : 0);
})();
