// decision 축 — 의사결정이 필요한 자리에 ✅ 를 달지 않는다. 두 가지로 돌릴 수 있다:
//   node --test emoji-layer.decision.test.mjs
//   node emoji-layer.decision.test.mjs "$PWD"      ← 이웃 시험들의 관행
// 이웃 시험(send-layer.test.mjs 등)은 argv[2] 로 폴더를 받는 자체 러너라 node --test
// 로는 돌지 않는다. 이 파일은 둘 다 받는다 — argv[2] 가 없으면 자기 위치를 쓴다.
//
// 왜 생겼나 (2026-09-02 실제 사고): 그룹 DM C0BU7LC0QSH 에서 Amani 가 귀국이 8/24
// 대신 8/31 이 된 사유를 1785자로 설명했다. 원장에 남은 여섯 줄이 이렇다 —
//   ack.grade   R1 강등 · NO_BASIS · 근거를 찾지 못함
//   ack-emoji   선응답을 :white_check_mark: 로 대체 · 길다(1785자 > 240)
//   auto.done   :white_check_mark: 리액션 감지 → 처리완료
// 즉 ✅ 는 "확인했다" 의 결과가 아니라 "글을 못 썼다" 의 결과였고, 리액션이 라이언
// 계정(xoxp)으로 나가는 탓에 동료는 그것을 라이언의 승인으로 읽었다. 그리고 그 ✅ 가
// 곧바로 항목을 처리완료로 만들어 의사결정이 필요한 글이 미처리에서 사라졌다.
// 해악이 둘이라 시험도 둘이다 — 어느 이모지가 나가는가(T1~T3·T5)와 그것이 항목을
// 지우는가(T4).
//
// 고정값은 지어내지 않았다. T1 은 정규화 후 정확히 1785자이고(원장에 찍힌 그 숫자),
// T3 은 Amani 가 그 정정 대화에서 실제로 친 문장 그대로다.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const D = process.argv[2] || dirname(fileURLToPath(import.meta.url));
const CATALOG_FILE = join(D, 'slack-emoji-layer.json');
const DAEMON_FILE = join(D, 'slack-eyes-daemon.mjs');

const {
  loadCatalog, responseGrade, nonResolvingEmojis, pendingEmojiRow, normalizeText, withoutRosterLines,
} = await import(`${D}/emoji-layer.mjs`);

const CATALOG = loadCatalog([CATALOG_FILE]);

// ── 고정값 ───────────────────────────────────────────────────────────────────

// §1-1 의 그 메시지. 원문을 그대로 옮길 수 없어(사적인 내용이다) 같은 모양으로 다시
// 썼다: 물음표 없음, 멘션 1개, 정규화 후 1785자. 세 값이 그 판정을 만든 전부이고,
// 아래 첫 시험이 1785 를 직접 검사하므로 이 셋 중 하나라도 흔들리면 바로 드러난다.
const LONG_1785 = `@Lion cho I want to give you the full picture of why my return landed on August 31 instead of August 24 as we had planned, and what I was doing during that week so that nothing about it stays unclear.
The original plan was to fly back on the 24th. Two days before that date the airline moved my connecting flight, and the new routing would have put me in transit for close to thirty hours with an overnight layover that I could not book a room for. I decided to take the later departure rather than arrive unable to work for the following two days.
During that week I did not stop working. I finished the handover notes for the onboarding flow and left them in the shared folder. I reviewed the three pull requests that were waiting on me and left comments on each one. I also sat with the local team for two afternoons to walk through the deployment steps, because they had been running them from memory and I wanted the steps written down before I left.
On the family side, my mother had a scheduled procedure on the 26th and I stayed until she was discharged on the 29th. That is the part I did not put in the channel earlier, and I should have. I kept it short in my earlier message because I did not want to make the thread about me, but leaving it out made the delay look unexplained.
I have already moved my remaining tasks forward to cover the lost days. The onboarding flow is back on the original date. The reporting work slipped by two days and I have written the new dates into the tracker so the change is visible to everyone rather than sitting in my head.
I am telling you all of this now so that the record is complete and so that the team can plan around the real dates rather than around an assumption. I will keep the tracker current from now on for any date change.`;

// §1-2 의 마지막 줄. Amani 가 "그 초록 체크가 승인으로 읽힌다" 고 정정한 그 문장이고,
// 옛 판정은 이 문장에도 ✅ 를 달았다 (원장 1788347855, 사유 "바닥값 R1").
const BARE_FLOOR = "it will be helpful so that people don't get confuse between you approving and your AI Agent reacting to a message";

// ── T1 — 의사결정이 필요한 긴 글 ────────────────────────────────────────────

test('T1 고정값이 사고 당시와 같은 모양인가 (1785자 · 물음표 없음)', () => {
  assert.equal(normalizeText(withoutRosterLines(LONG_1785, CATALOG)).length, 1785);
  assert.equal(/[?？]/.test(LONG_1785), false);
});

test('T1 1785자 · 물음표 없음 → decision needed, ✅ 가 아니다', () => {
  const g = responseGrade({ text: LONG_1785, catalog: CATALOG });
  assert.equal(g.decision, 'needed');
  assert.notEqual(g.emoji, 'white_check_mark');
  assert.equal(g.emoji, 'mag');
  // 등급은 바뀌지 않았다. 바뀐 것은 등급에 실려 나가는 이모지뿐이다.
  assert.equal(g.grade, 'R2');
  assert.match(g.reason, /길다\(1785자 > 240\)/);
});

// ── T2 — 닫는 말 ────────────────────────────────────────────────────────────

test('T2 닫는 말 → decision not-needed, ✅ 또는 🫡', () => {
  const g = responseGrade({ text: "Understood, thank you. I'll proceed accordingly.", catalog: CATALOG });
  assert.equal(g.decision, 'not-needed');
  assert.ok(['white_check_mark', 'saluting_face'].includes(g.emoji), `got ${g.emoji}`);
  assert.equal(g.grade, 'R1');
});

// ── T3 — 아무 신호도 없는 평서문 ────────────────────────────────────────────

test('T3 바닥값 → decision unknown, ✅ 가 아니다', () => {
  const g = responseGrade({ text: BARE_FLOOR, catalog: CATALOG });
  assert.equal(g.decision, 'unknown');
  assert.notEqual(g.emoji, 'white_check_mark');
  assert.equal(g.emoji, 'mag');
  assert.equal(g.grade, 'R1');
});

test('T3 단체 수신도 같다 — 분류가 안 된 것은 의사결정이 필요 없는 것이 아니다', () => {
  const g = responseGrade({ text: `@a @b @c ${BARE_FLOOR}`, catalog: CATALOG });
  assert.equal(g.decision, 'unknown');
  assert.notEqual(g.emoji, 'white_check_mark');
});

// ── 축이 하나 늘었을 뿐 등급은 그대로다 ─────────────────────────────────────

test('R0 은 그대로 R0 이고 이모지도 그대로 null 이다', () => {
  const g = responseGrade({ text: '   ', catalog: CATALOG });
  assert.equal(g.grade, 'R0');
  assert.equal(g.emoji, null);
});

test('무거운 어휘(👌 승인)는 등급 R1 · 표식 ✅ 로 예전 그대로다', () => {
  const g = responseGrade({ text: 'Approved, go ahead.', catalog: CATALOG });
  assert.equal(g.grade, 'R1');
  assert.equal(g.emoji, 'white_check_mark');
  assert.equal(g.decision, 'not-needed');
});

// ── 하위 호환 — decision·resolves·pendingEmoji 를 모르는 옛 어휘집 ──────────

test('판 2 어휘집(새 축 없음)에서도 던지지 않고 옛 동작으로 내려간다', () => {
  const old = {
    version: 2,
    veto: { maxChars: 240, patterns: ['[?？]'] },
    emojis: [{
      name: 'white_check_mark', char: '✅', label: '확인만 함', means: '체크만 했다',
      use: '읽었다는 사실만 남기는 자리', auto: true, level0: true,
      match: '\\b(understood|noted|thanks)\\b',
    }],
  };
  assert.deepEqual(nonResolvingEmojis(old), []);
  assert.equal(pendingEmojiRow(old), null);
  const g = responseGrade({ text: BARE_FLOOR, catalog: old });
  assert.equal(g.grade, 'R1');
  assert.equal(g.emoji, 'white_check_mark');   // 보는 중 행이 없으면 옛 동작이다
  assert.equal(g.decision, 'unknown');
  assert.match(g.reason, /보는 중 이모지\(미지정\)가 어휘집에 없어/);
});

test('레이어는 어떤 경로에서도 null 이모지를 돌려주지 않는다 (R0 제외)', () => {
  for (const s of [LONG_1785, BARE_FLOOR, 'Understood, thanks', 'Approved, go ahead.', 'can you check this']) {
    const g = responseGrade({ text: s, catalog: CATALOG });
    assert.ok(g.emoji, `null emoji for: ${s.slice(0, 30)}`);
    assert.ok(['needed', 'not-needed', 'unknown'].includes(g.decision), `bad decision ${g.decision}`);
  }
});

// ── T4 — 보는 중 이모지는 항목을 처리완료로 만들지 않는다 ───────────────────
//
// slack-eyes-daemon.mjs 는 아무것도 export 하지 않고 마지막 줄에서 main() 을 부른다.
// import 하면 데몬이 뜬다. 그래서 판정 함수 넷의 원문을 파일에서 그대로 잘라내
// 격리된 스코프에서 돌린다. 원문을 자르므로 "시험용으로 다시 쓴 로직" 이 아니고,
// 함수 이름이나 모양이 바뀌면 여기서 먼저 깨진다.
const DAEMON_SRC = readFileSync(DAEMON_FILE, 'utf8');

function grabFn(name) {
  let i = DAEMON_SRC.indexOf(`function ${name}(`);
  assert.ok(i >= 0, `slack-eyes-daemon.mjs 에 function ${name} 이 없다`);
  // async 를 떼고 자르면 await 이 들어 있는 함수가 문법 오류가 된다.
  if (DAEMON_SRC.slice(i - 6, i) === 'async ') i -= 6;
  // 먼저 매개변수 목록을 괄호로 건너뛴다. 기본값에 `patch = {}` 같은 객체가 있으면
  // 중괄호가 그 자리에서 열리고 닫혀, 곧바로 중괄호를 세면 시그니처 한 줄만 잘린다
  // (2026-09-06 에 postEmojiReaction 을 자르다 실제로 그렇게 됐다).
  let paren = 0;
  let k = DAEMON_SRC.indexOf('(', i);
  for (; k < DAEMON_SRC.length; k++) {
    if (DAEMON_SRC[k] === '(') paren++;
    else if (DAEMON_SRC[k] === ')' && --paren === 0) break;
  }
  let depth = 0;
  for (k = DAEMON_SRC.indexOf('{', k); k < DAEMON_SRC.length; k++) {
    if (DAEMON_SRC[k] === '{') depth++;
    else if (DAEMON_SRC[k] === '}' && --depth === 0) return DAEMON_SRC.slice(i, k + 1);
  }
  throw new Error(`function ${name} 의 끝을 찾지 못했다`);
}

// 잘라낸 함수가 기대는 모듈 스코프 값. 데몬이 실제로 무엇을 선언해 두었는지 먼저
// 확인하고 같은 값을 준다 — 확인 없이 흉내만 내면 데몬 쪽 선언이 사라져도 시험은
// 통과한다.
// const 선언도 원문에서 그대로 잘라 온다 — 손으로 옮겨 적으면 데몬 쪽 값이 바뀌어도
// 시험은 옛 값으로 계속 통과한다.
function grabLine(prefix) {
  const m = DAEMON_SRC.match(new RegExp(`^${prefix}[^\\n]*$`, 'm'));
  assert.ok(m, `slack-eyes-daemon.mjs 에 "${prefix}" 로 시작하는 줄이 없다`);
  return m[0];
}

test('T4 사전 확인 — 데몬이 캐시 변수와 트리거 기본값을 그대로 갖고 있다', () => {
  assert.match(DAEMON_SRC, /let nonResolvingNames = null;/);
  assert.match(DAEMON_SRC, /let nonResolvingAt = 0;/);
  assert.match(DAEMON_SRC, /let resolvesPolicyValue = null;/);
  assert.match(DAEMON_SRC, /let resolvesPolicyAt = 0;/);
  assert.match(DAEMON_SRC, /let resolvesPolicyFallbackLogged = false;/);
  assert.match(DAEMON_SRC, /let EMOJIS = \['eyes'\];/);
  assert.match(DAEMON_SRC, /let LATER_EMOJIS = \['bookmark', 'pushpin'\];/);
  // 정책 값을 코드에 박지 않았는가 — 어느 갈래를 고를지는 JSON 이 정한다.
  assert.match(DAEMON_SRC, /let MY_USER = null;/);
  // 2026-09-06 에 값이 셋이 됐다 — 'self' 가 늘었다. 이 단언이 재는 것은 "정책 값을
  // 코드에 박지 않았는가" 가 아니라 "코드가 아는 값이 무엇인가" 다. 어느 갈래를 고를지는
  // 여전히 JSON 이 정한다(아래 catalogWith 시험들이 그것을 잰다).
  assert.deepEqual(JSON.parse(grabLine('const RESOLVES_POLICIES')
    .replace(/^const RESOLVES_POLICIES = /, '').replace(/;$/, '').replace(/'/g, '"')),
  ['none', 'self', 'catalog']);
});

function daemonEmojiFns(bundled = CATALOG_FILE, override = join(D, '__no_such_override__.json')) {
  const logs = [];
  const body = `
    const EMOJIS = ['eyes'];
    const LATER_EMOJIS = ['bookmark', 'pushpin'];
    let nonResolvingNames = null;
    let nonResolvingAt = 0;
    let resolvesPolicyValue = null;
    let resolvesPolicyAt = 0;
    let resolvesPolicyFallbackLogged = false;
    ${grabLine('let MY_USER')}
    ${grabLine('const RESOLVES_POLICIES')}
    ${grabFn('baseEmoji')}
    ${grabFn('isTriggerEmoji')}
    ${grabFn('emojiLayerResolveFields')}
    ${grabFn('resolvesPolicy')}
    ${grabFn('nonResolvingEmojiNames')}
    ${grabFn('ourAckEmojis')}
    ${grabFn('isResolvingEmoji')}
    ${grabFn('resolvingReaction')}
    ${grabFn('firstNonTrigger')}
    ${grabFn('emojiSafeToPost')}
    ${grabFn('withAckEmoji')}
    // MY_USER 는 데몬에서 auth.test 가 늦게 채운다(:4759). 시험은 그 시점을 흉내내야
    // 하므로 값을 밖에서 넣고 뺄 수 있어야 한다 — 기본은 데몬과 같은 null 이다.
    return { resolvingReaction, firstNonTrigger, isResolvingEmoji, nonResolvingEmojiNames,
             resolvesPolicy, emojiSafeToPost, ourAckEmojis, withAckEmoji, logs,
             setMyUser: (u) => { MY_USER = u; }, getMyUser: () => MY_USER };
  `;
  // eslint-disable-next-line no-new-func
  return new Function('readFileSync', 'BUNDLED_EMOJI_LAYER_FILE', 'EMOJI_LAYER_FILE', 'log', 'logs', body)(
    readFileSync, bundled, override, (...a) => logs.push(a.join(' ')), logs);
}

// 정책 스위치가 정말 스위치인지 재려면 어휘집 두 벌이 필요하다. 번들을 복사해 값만
// 바꿔 tmpdir 에 쓴다 — ~/.condition-mate/slack-translate/ 는 도는 데몬이 읽는 운영
// 자리라 시험이 거기 쓰면 그 순간 정책이 라이브가 된다(T5 와 같은 이유).
function catalogWith(mutate) {
  const dir = mkdtempSync(join(tmpdir(), 'emoji-policy-'));
  const doc = JSON.parse(readFileSync(CATALOG_FILE, 'utf8'));
  mutate(doc);
  const file = join(dir, 'slack-emoji-layer.json');
  writeFileSync(file, JSON.stringify(doc));
  return { file, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test('T4 resolvingReaction 이 🔍 를 처리완료로 읽지 않는다', () => {
  const f = daemonEmojiFns();
  assert.equal(f.resolvingReaction([{ name: 'mag', users: ['U1'] }]), null);
  assert.equal(f.firstNonTrigger(['mag']), null);
});

// 여기부터가 2026-09-02 라이언 결정이다: "어떤 리액션도 항목을 닫지 않는다. 미처리는
// 손으로 닫는다. 리액션은 봤다는 표시일 뿐이고 미처리 목록에서 항목을 빼는 권한은
// 사람 손에만 있다." 아래 두 시험은 그 전 계약(✅·👍 는 닫는다)을 지키고 있던 것이고,
// 계약이 바뀌었으므로 방향을 뒤집는다. 옛 계약은 사라지지 않고 resolvesPolicy:catalog
// 아래로 옮겨 갔다 — 바로 뒤 두 시험이 그것을 계속 지킨다.

// 2026-09-06 에 이 시험을 고쳤다. 깨진 이유는 계약이 아니라 **점유**를 재고 있었기
// 때문이다 — 번들 값이 오늘 무엇인가를 단언하고 있었고 그 값이 'none' 에서 'self' 로
// 바뀌었다. 그래서 값 단언을 새 점유로 고치고, "닫지 않는다" 를 self 의 계약으로 다시
// 썼다: 남이 단 것과 우리가 단 것은 여전히 안 닫고, 라이언이 자기 손으로 단 것만 닫는다.
test('T4 남이 단 ✅ 도 👍 도 항목을 닫지 않는다 (2026-09-06 · resolvesPolicy:self)', () => {
  const f = daemonEmojiFns();
  assert.equal(f.resolvesPolicy(), 'self');
  f.setMyUser('UME');
  const item = { id: 'C1:1', ackEmoji: 'mag' };
  // 남이 달았다 — 이름이 무엇이든 닫지 않는다.
  assert.equal(f.resolvingReaction([{ name: 'white_check_mark', users: ['U1'] }], { item }), null);
  assert.equal(f.isResolvingEmoji('+1', { by: 'U1', item }), false);
  assert.equal(f.isResolvingEmoji('+1::skin-tone-3', { by: 'U1', item }), false);
  // 이름만 아는 자리(firstNonTrigger)는 누가 달았는지를 모르므로 self 에서 언제나 null 이다.
  assert.equal(f.firstNonTrigger(['+1']), null);
  assert.equal(f.firstNonTrigger(['+1::skin-tone-3']), null);
  // 트리거는 여전히 트리거다 — 이 결정이 트리거 규칙을 건드리지 않았다.
  assert.equal(f.resolvingReaction([{ name: 'eyes', users: ['UME'] }], { item }), null);
  assert.equal(f.firstNonTrigger(['bookmark']), null);
  // 행 단위 resolves:false 도 self 아래에서 계속 산다 — 번들은 전 행이 false 다.
  assert.equal(f.isResolvingEmoji('mag', { by: 'UME', item: { id: 'C1:2' } }), false);
});

test('T4 🔍 뒤에 진짜 해결 리액션이 붙어도 항목은 열려 있다 (예전에는 뒤의 것을 잡아 닫았다)', () => {
  const f = daemonEmojiFns();
  assert.equal(f.resolvingReaction([{ name: 'mag', users: ['U9'] }, { name: '+1', users: ['U2'] }]), null);
  assert.equal(f.firstNonTrigger(['mag', 'white_check_mark']), null);
});

// 결정 직전의 어휘집을 그대로 되살린 합성본이다 — 정책은 catalog 이고 resolves:false
// 는 🔍 한 행에만 있다. 두 축을 함께 되돌려야 옛 계약을 진짜로 재는 것이 된다:
// 정책만 catalog 로 놓으면 전 행이 false 라 여전히 아무것도 안 닫혀서, 시험이
// 통과해도 스위치가 도는 것인지 행이 막는 것인지 구별되지 않는다.
function legacyCatalog() {
  return catalogWith((d) => {
    d.resolvesPolicy = 'catalog';
    d.emojis = d.emojis.map((e) => (e.name === 'mag' ? e : { ...e, resolves: undefined }));
  });
}

test('T4 정책이 catalog 이면 옛 계약 그대로다 — ✅·👍 가 닫고 🔍 는 안 닫는다', () => {
  const c = legacyCatalog();
  try {
    const f = daemonEmojiFns(c.file);
    assert.equal(f.resolvesPolicy(), 'catalog');
    assert.deepEqual(f.nonResolvingEmojiNames(), new Set(['mag']));
    assert.deepEqual(f.resolvingReaction([{ name: 'white_check_mark', users: ['U1'] }]),
      { name: 'white_check_mark', by: 'U1' });
    assert.equal(f.firstNonTrigger(['+1::skin-tone-3']), '+1');
    // 행 단위 resolves 는 catalog 아래에서 여전히 산다.
    assert.equal(f.resolvingReaction([{ name: 'mag', users: ['U1'] }]), null);
    assert.equal(f.resolvingReaction([{ name: 'eyes', users: ['U1'] }]), null);
  } finally { c.cleanup(); }
});

test('T4 정책이 catalog 이면 🔍 뒤의 ✅ 를 잡는다 (스위치가 실제로 스위치인지)', () => {
  const c = legacyCatalog();
  try {
    const f = daemonEmojiFns(c.file);
    assert.deepEqual(f.resolvingReaction([{ name: 'mag', users: ['U9'] }, { name: '+1', users: ['U2'] }]),
      { name: '+1', by: 'U2' });
    assert.equal(f.firstNonTrigger(['mag', 'white_check_mark']), 'white_check_mark');
  } finally { c.cleanup(); }
});

// 이 시험이 이 배치의 존재 이유다. 행마다 resolves:false 를 적는 것으로는 어휘집에
// 이름이 없는 이모지를 못 덮는다 — items.jsonl 1,793건에서 트리거를 뺀 리액션 이름
// 89종 중 어휘집에 있는 것은 8종뿐이고, 나머지 81종 1,481건(ez_clap 160 · mustheart 81
// · heart 80 · flag-pk 67 · green-heart 64 · tada 62 · joy 57 …)이 전부 항목을 닫고
// 있었다. tada 는 그 81종 중 하나이고 어휘집에 한 번도 적힌 적이 없다.
test('T4 어휘집에 없는 이름(tada)은 none 에서 안 닫고 catalog 에서는 닫는다', () => {
  const now = daemonEmojiFns();
  assert.equal(now.nonResolvingEmojiNames().has('tada'), false);   // 행이 없다는 사실 자체를 먼저 고정
  assert.equal(now.resolvingReaction([{ name: 'tada', users: ['U1'] }]), null);
  assert.equal(now.firstNonTrigger(['ez_clap']), null);

  const c = catalogWith((d) => { d.resolvesPolicy = 'catalog'; });
  try {
    const f = daemonEmojiFns(c.file);
    assert.deepEqual(f.resolvingReaction([{ name: 'tada', users: ['U1'] }]), { name: 'tada', by: 'U1' });
    assert.equal(f.firstNonTrigger(['ez_clap']), 'ez_clap');
  } finally { c.cleanup(); }
});

// 방향이 바뀐 자리다. 앞선 판은 여기서 "오늘의 동작 유지" 를 골라 어휘집을 못 읽으면
// 자동 처리완료를 되살렸다. 그것은 라이언이 방금 금지한 해악을 말없이 되돌리는 길이고,
// 파일 하나를 못 읽은 것을 아무도 모르는 채로 사고가 재발한다. 항목이 쌓이는 것은
// 눈에 보이고 손으로 되돌릴 수 있지만 의사결정이 필요한 항목이 사라지는 것은 둘 다 아니다.
test('T4 어휘집을 못 읽으면 none 으로 닫는다 (fail-closed — 조용히 자동 처리완료를 되살리지 않는다)', () => {
  const f = daemonEmojiFns(join(D, '__no_such_bundle__.json'), join(D, '__no_such_override__.json'));
  assert.equal(f.resolvesPolicy(), 'none');
  assert.deepEqual(f.nonResolvingEmojiNames(), new Set());
  assert.equal(f.resolvingReaction([{ name: 'mag', users: ['U1'] }]), null);
  assert.equal(f.resolvingReaction([{ name: 'white_check_mark', users: ['U1'] }]), null);
  assert.equal(f.firstNonTrigger(['tada']), null);
  // 조용하지 않다 — 그러나 한 번만 남긴다(이벤트마다 부르는 함수라 매번 찍으면 로그가 잠긴다).
  f.resolvesPolicy(); f.resolvesPolicy();
  assert.equal(f.logs.length, 1);
  assert.match(f.logs[0], /resolvesPolicy: .*none 으로 닫는다/);
});

test('T4 resolvesPolicy 키가 없는 옛 어휘집은 catalog 로 읽는다 (하위 호환)', () => {
  const c = catalogWith((d) => { delete d.resolvesPolicy; });
  try {
    const f = daemonEmojiFns(c.file);
    assert.equal(f.resolvesPolicy(), 'catalog');
    assert.equal(f.logs.length, 0);   // 키가 없는 것은 결함이 아니다 — 경고를 찍지 않는다
    assert.deepEqual(f.resolvingReaction([{ name: 'tada', users: ['U1'] }]), { name: 'tada', by: 'U1' });
  } finally { c.cleanup(); }
});

test('T4 모르는 정책 값이 적혀 있으면 none 으로 닫는다 (오타는 안전한 쪽으로 떨어진다)', () => {
  const c = catalogWith((d) => { d.resolvesPolicy = 'nOne'; });
  try {
    const f = daemonEmojiFns(c.file);
    assert.equal(f.resolvesPolicy(), 'none');
    assert.equal(f.logs.length, 1);
    assert.match(f.logs[0], /모르는 값 "nOne"/);
  } finally { c.cleanup(); }
});

// SLKST-8 의 트리거 거부는 이 축과 무관하다. 👀 를 달면 reaction_added 가 재수집으로
// 되돌아와 같은 항목이 무한히 돈다 — 정책이 none 이든 catalog 이든 코드가 거부한다.
// 2026-09-06: 앞선 판은 번들의 오늘 값이 'none' 이라는 것에 기대어 첫 갈래를 번들
// 그대로 돌렸다. 번들이 'self' 가 되면서 그 기대가 깨졌는데, 이 시험이 재려던 것은
// 정책이 아니라 트리거 거부다. 그래서 세 정책을 전부 명시적으로 만들어 돌린다 —
// 번들이 어느 값이 되든 다시 깨지지 않는다.
test('T4 emojiSafeToPost 는 정책과 무관하게 트리거를 계속 거부한다 (SLKST-8)', () => {
  for (const [label, cat] of [['none', 'none'], ['self', 'self'], ['catalog', 'catalog']]) {
    const c = catalogWith((d) => { d.resolvesPolicy = cat; });
    try {
      const f = daemonEmojiFns(c.file);
      assert.equal(f.resolvesPolicy(), cat, label);
      assert.equal(f.emojiSafeToPost('eyes'), false, label);
      assert.equal(f.emojiSafeToPost('bookmark'), false, label);
      assert.equal(f.emojiSafeToPost('pushpin'), false, label);
      assert.equal(f.emojiSafeToPost('mag'), true, label);
      assert.equal(f.emojiSafeToPost(''), false, label);
    } finally { c.cleanup(); }
  }
});

// 리액션 제거 경로. 정책이 none 이면 firstNonTrigger 가 언제나 null 이라 옛 조건이
// 항상 참이 되고, 비트리거 리액션 하나만 떼도 예전에 자동 처리완료된 항목이 전부
// 미처리로 되살아난다. 아무도 그것을 시키지 않았다.
// 2026-09-06 에 이 단언을 다시 썼다. 깨진 이유는 가드 자체를 바꿨기 때문이고 그것은
// 의도한 것이다 — self 에서도 firstNonTrigger 는 언제나 null 이라(이름 다중집합에는
// 누가 달았는지가 없다) 옛 조건을 그대로 두면 리액션 하나 뗄 때마다 예전에 자동
// 처리완료된 항목이 전부 다시 열린다. **정규식을 느슨하게 지우지 않았다** — 무더기
// 재개방을 막는 자리가 여기다.
test('T4 리액션 제거가 옛 autoDone 을 무더기로 되살리지 않는다 (가드 원문)', () => {
  // none: 예전 그대로 — 취소 경로를 통째로 건너뛴다.
  assert.match(DAEMON_SRC,
    /\} else if \(pol !== 'none' && !firstNonTrigger\(left\)\) autoUnresolve\(id, it\);/);
  // self: "무엇이 남았는가" 가 아니라 "닫은 그것이 떼어졌는가" 로 판정한다. 세 조건이
  // 전부 있어야 한다 — autoDone · autoBy 일치 · autoEmoji 일치.
  assert.match(DAEMON_SRC,
    /if \(pol === 'self'\) \{\s*\n\s*if \(it\.autoDone && it\.autoBy && e\.user === it\.autoBy\s*\n\s*&& baseEmoji\(e\.reaction\) === baseEmoji\(it\.autoEmoji\)\) autoUnresolve\(id, it\);/);
  // firstNonTrigger 가 self 갈래에 남아 있으면 안 된다 — 남아 있으면 !null 이 항상 참이다.
  const selfBranch = DAEMON_SRC.slice(DAEMON_SRC.indexOf("if (pol === 'self')"),
    DAEMON_SRC.indexOf("} else if (pol !== 'none'"));
  assert.doesNotMatch(selfBranch, /firstNonTrigger/);
});

// 2026-09-06: 번들 값이 'none' 에서 'self' 로 바뀌었다. 행 단위 resolves:false 는 지우지
// 않았다 — self 아래에서도 그 값은 계속 존중되고(라이언이 손으로 달아도 그 이름은 안
// 닫는다) _axis_doc 이 "모든 행에 resolves:false 를 명시해 두었다" 고 적은 것도 참으로 남는다.
test('T4 번들 어휘집은 두 축이 어긋나지 않는다 — 정책 self · 모든 행 resolves:false', () => {
  const raw = JSON.parse(readFileSync(CATALOG_FILE, 'utf8'));
  assert.equal(raw.resolvesPolicy, 'self');
  assert.ok(raw._resolvesPolicy_doc);
  // SLKST-9 — 산문이 코드와 같은 것을 말하는가. 값이 셋이라고 적혀 있고 현재 값이 적혀 있다.
  assert.match(raw._resolvesPolicy_doc, /값은 셋이다/);
  assert.match(raw._resolvesPolicy_doc, /지금 값은 self 다/);
  assert.doesNotMatch(raw._axis_doc, /지금 값은 none/);
  assert.match(raw._axis_doc, /지금 값은 self 다/);
  for (const e of raw.emojis) assert.equal(e.resolves, false, `${e.name} 행에 resolves:false 가 없다`);
});

// ── T5 — 이름은 JSON 에만 있다 ──────────────────────────────────────────────
//
// 라이언이 결정 카드에서 🔍 말고 다른 것을 고르면 JSON 한 줄만 바뀐다. 그것이 정말
// 한 줄인지 확인하는 시험이다 — 코드에 이름을 박아 두면 여기서 걸린다.
// 임시 파일은 os.tmpdir() 에만 쓴다. ~/.condition-mate/slack-translate/ 는 도는 데몬이
// 메시지마다 읽는 운영 덮어쓰기 자리라, 시험이 거기 쓰면 정책이 그 자리에서 라이브가 된다.

test('T5 pendingEmoji 이름을 JSON 에서 바꾸면 코드 수정 없이 따라간다', () => {
  const dir = mkdtempSync(join(tmpdir(), 'emoji-decision-'));
  try {
    const swapped = JSON.parse(readFileSync(CATALOG_FILE, 'utf8'));
    swapped.pendingEmoji = 'telescope';
    // 이 시험이 재는 것은 "이름이 JSON 에서만 온다" 이지 정책이 아니다. 그런데 행
    // 단위 resolves 가 실제로 도는지는 정책이 catalog 일 때만 보이므로, 결정 이전의
    // 두 축을 여기서도 되살려 놓고 잰다 (위 legacyCatalog 와 같은 이유).
    swapped.resolvesPolicy = 'catalog';
    swapped.emojis = swapped.emojis.map((e) => (e.name === 'mag'
      ? { ...e, name: 'telescope', char: '🔭' } : { ...e, resolves: undefined }));
    const f = join(dir, 'emoji-layer.json');
    writeFileSync(f, JSON.stringify(swapped));

    // 1) 레이어 — 세 갈래 모두 새 이름을 든다.
    const cat = loadCatalog([CATALOG_FILE, f]);
    assert.equal(pendingEmojiRow(cat).name, 'telescope');
    assert.equal(responseGrade({ text: BARE_FLOOR, catalog: cat }).emoji, 'telescope');
    assert.equal(responseGrade({ text: LONG_1785, catalog: cat }).emoji, 'telescope');
    assert.deepEqual(nonResolvingEmojis(cat), ['telescope']);

    // 2) 데몬 — 처리완료 예외도 같은 한 줄을 따라간다. 운영 파일이 통째로 이기므로
    //    옛 이름 mag 는 다시 처리완료로 읽힌다 (loadCatalog 와 같은 교체 규칙).
    const dfn = daemonEmojiFns(CATALOG_FILE, f);
    assert.equal(dfn.resolvingReaction([{ name: 'telescope', users: ['U1'] }]), null);
    assert.deepEqual(dfn.resolvingReaction([{ name: 'mag', users: ['U1'] }]), { name: 'mag', by: 'U1' });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('T5 pendingEmoji 가 가리키는 행이 없으면 ✅ 로 내려가고 사유에 그렇게 적힌다', () => {
  const cat = loadCatalog([CATALOG_FILE]);
  const broken = { ...cat, pendingEmoji: 'no_such_emoji' };
  const g = responseGrade({ text: BARE_FLOOR, catalog: broken });
  assert.equal(g.emoji, 'white_check_mark');   // null 이 아니다 — null 이면 아무 응답도 안 남는다
  assert.equal(g.decision, 'unknown');
  assert.match(g.reason, /보는 중 이모지\(no_such_emoji\)가 어휘집에 없어/);
});

// ── 어휘집이 실제로 그렇게 적혀 있는가 ──────────────────────────────────────

test('번들 어휘집의 mag 행이 규약대로다', () => {
  const row = CATALOG.emojis.find((e) => e.name === 'mag');
  assert.ok(row, 'slack-emoji-layer.json 에 mag 행이 없다');
  assert.equal(row.auto, true);
  assert.equal(row.level0, true);
  assert.equal(row.resolves, false);
  assert.equal(row.decision, 'needed');
  assert.equal(row.match, undefined);           // 어휘 일치로 골라지는 행이 아니다
  // 2026-09-02 결정으로 전 행이 resolves:false 다. 🔍 만 특별한 것이 아니라 🔍 도
  // 그 안에 있는 것이 지금 상태다.
  assert.deepEqual(nonResolvingEmojis(CATALOG), CATALOG.emojis.map((e) => e.name));
  assert.ok(nonResolvingEmojis(CATALOG).includes('mag'));
});

test('👀 는 여전히 auto:false 다 — 수집 트리거를 자동으로 달면 루프가 돈다', () => {
  const eyes = CATALOG.emojis.find((e) => e.name === 'eyes');
  assert.equal(eyes.auto, false);
  assert.ok(eyes.autoNote);
  assert.notEqual(CATALOG.pendingEmoji, 'eyes');
});

// ── T6 — approval 축 (2026-09-02 판 3) ───────────────────────────────────────
//
// 여기 오기 전까지 heavy 는 "뜻이 무겁다" 한 덩어리였고, 일치하면 무조건 ✅ 로 접혔다.
// 그래서 어휘집이 🙏 자리라고 정확히 판정한 뒤에도 🙏 는 구조적으로 슬랙에 나갈 수
// 없었다. 위험한 것은 무거움이 아니라 승인·동의의 뜻을 갖는가이므로 축을 그것으로
// 다시 그었다. 위의 ':104' 가드 시험(👌 → ✅)은 그대로 통과해야 한다 — 깨지면 축을
// 잘못 그은 것이다.
//
// 판 3 에서 시험의 대상을 둘로 갈랐다. **축**(어느 쪽으로 접히는가)은 아래 합성 어휘집에
// 대고 재고, **점유**(오늘 어느 행이 그 축의 어느 칸에 있는가)는 번들 어휘집에 대고 잰다.
// 갈라 둔 이유는 판 2 의 시험이 축을 번들 어휘집에 대고 쟀기 때문이다 — 그때는 🙏·🙇 가
// approval:false + auto:true 였으므로 그것으로 접힘 해제를 시험할 수 있었는데, 실측에서
// 두 행이 채택선(정밀도 0.70·표본 8)에 못 미쳐 auto:false 로 내려가자 축 시험 셋이
// 한꺼번에 깨졌다. 축은 한 글자도 안 바뀌었는데 시험이 깨졌다면 그것은 축을 잰 것이
// 아니라 점유를 잰 것이다. 합성 어휘집은 어휘집의 점유가 어떻게 바뀌어도 축이 계속
// 시험된다.

// 축 시험용 합성 어휘집. 실제 슬랙에 나가지 않으므로 이름이 슬랙에 있는지는 상관없고,
// 번들의 행과 헷갈리지 않게 synthetic_ 접두어를 붙였다. 정규식은 본문에 우연히 나올 수
// 없는 토큰으로 두어 다른 행과 겹치지 않게 했다.
const AXIS_CATALOG = {
  version: 99,
  pendingEmoji: 'mag',
  veto: { maxChars: 240, patterns: ['[?？]'] },
  emojis: [
    { name: 'synthetic_unfold', char: '🅰', label: '승인 뜻 없는 무거운 행',
      means: '접힘이 풀리는 칸', use: '축 시험용',
      auto: true, approval: false, decision: 'not-needed', match: 'AXISUNFOLD' },
    { name: 'synthetic_fold', char: '🅱', label: '승인 뜻 있는 무거운 행',
      means: '접히는 칸', use: '축 시험용',
      auto: true, approval: true, decision: 'not-needed', match: 'AXISFOLD' },
    // approval 을 아예 안 적은 행. 부호 방향을 가르는 유일한 칸이다 (아래 시험의 주석).
    { name: 'synthetic_silent', char: '🅾', label: 'approval 을 안 적은 무거운 행',
      means: '키가 없는 칸', use: '축 시험용',
      auto: true, decision: 'not-needed', match: 'AXISSILENT' },
    { name: 'white_check_mark', char: '✅', label: '확인만 함', means: '체크만 했다',
      use: '읽었다는 사실만 남기는 자리', auto: true, level0: true, match: 'AXISLOW' },
    { name: 'mag', char: '🔍', label: '보는 중', means: '살펴보고 있다', use: '판단이 필요한 자리',
      auto: true, level0: true, resolves: false, decision: 'needed' },
  ],
};

test('T6 축 — approval:false 인 무거운 행은 자기 자신으로 나간다 (접힘 해제)', () => {
  const g = responseGrade({ text: 'AXISUNFOLD', catalog: AXIS_CATALOG });
  assert.equal(g.emoji, 'synthetic_unfold');
  assert.equal(g.grade, 'R1');
  assert.equal(g.decision, 'not-needed');
  assert.doesNotMatch(g.reason, /접음/);
});

test('T6 축 — approval:true 인 무거운 행은 ✅ 로 접힌다', () => {
  const g = responseGrade({ text: 'AXISFOLD', catalog: AXIS_CATALOG });
  assert.equal(g.emoji, 'white_check_mark');
  assert.equal(g.grade, 'R1');
  assert.equal(g.decision, 'not-needed');
  assert.match(g.reason, /승인 뜻이라 :white_check_mark: 로 접음/);
});

test('T6 축 — approval 을 안 적은 무거운 행도 ✅ 로 접힌다 (부호 방향)', () => {
  // 세 칸 중 이 칸 하나만 부호를 가른다. 판정을 heavy.approval !== false 에서
  // === true 로 뒤집으면 false 칸과 true 칸은 결과가 같고, **키가 없는 이 칸만**
  // 접힘에서 접힘 해제로 넘어간다. 즉 새 행을 approval 없이 추가했을 때 그것이
  // 라이언 계정(xoxp)으로 그대로 나가는 상태가 되고, 그 방향의 실패가 승인 오독이다.
  // 모르면 접는 쪽이 안전한 쪽이라 여기서 접혀야 한다.
  const g = responseGrade({ text: 'AXISSILENT', catalog: AXIS_CATALOG });
  assert.equal(g.emoji, 'white_check_mark');
  assert.match(g.reason, /승인 뜻이라 :white_check_mark: 로 접음/);
});

test('T6 축 — approval 을 통째로 모르는 옛 어휘집에서는 세 칸이 전부 ✅ 로 접힌다', () => {
  // 하위 호환. approval 키가 생기기 전의 어휘집이 이 경로로 온다.
  const stripped = {
    ...AXIS_CATALOG,
    emojis: AXIS_CATALOG.emojis.map(({ approval, ...rest }) => rest),   // eslint-disable-line no-unused-vars
  };
  assert.equal(stripped.emojis.some((e) => 'approval' in e), false);
  for (const s of ['AXISUNFOLD', 'AXISFOLD', 'AXISSILENT']) {
    const g = responseGrade({ text: s, catalog: stripped });
    assert.equal(g.emoji, 'white_check_mark', `got ${g.emoji} for: ${s}`);
    assert.equal(g.decision, 'not-needed');
  }
});

test('T6 축 — auto:false 로 내린 행은 무거운 행에서 아예 빠진다 (접힘 이전의 문제)', () => {
  // 채택선에 못 미친 행을 내리는 방법이 approval 을 고치는 것이 아니라 auto 를 내리는
  // 것임을 고정한다. 두 축을 섞으면 "나갈 자격이 없다" 를 "승인 뜻이 있다" 로 적게 된다.
  const downed = {
    ...AXIS_CATALOG,
    emojis: AXIS_CATALOG.emojis.map((e) => (e.name === 'synthetic_unfold' ? { ...e, auto: false } : e)),
  };
  const g = responseGrade({ text: 'AXISUNFOLD', catalog: downed });
  assert.notEqual(g.emoji, 'synthetic_unfold');
  assert.equal(g.emoji, 'mag');              // 무거운 행도 level0 도 아니면 바닥값이다
  assert.equal(g.decision, 'unknown');
  // approval 값은 그대로 남아 있다 — 내린 것은 자격이지 뜻이 아니다.
  assert.equal(downed.emojis.find((e) => e.name === 'synthetic_unfold').approval, false);
});

// ── T6 점유 — 오늘 번들 어휘집이 그 축의 어느 칸에 무엇을 두었는가 ─────────────

test('T6 점유 — 승인 뜻이 있는 어휘(👌 승인·👍 동의)는 여전히 ✅ 로 접힌다', () => {
  for (const s of ['Approved, go ahead.', 'Sounds good to me.', '승인합니다']) {
    const g = responseGrade({ text: s, catalog: CATALOG });
    assert.equal(g.emoji, 'white_check_mark', `got ${g.emoji} for: ${s}`);
    assert.equal(g.grade, 'R1');
    assert.equal(g.decision, 'not-needed');
    assert.match(g.reason, /승인 뜻이라 :white_check_mark: 로 접음/);
  }
});

test('T6 점유 — 👌·👍 는 auto:true · approval:true 다', () => {
  for (const name of ['ok_hand', '+1']) {
    const row = CATALOG.emojis.find((e) => e.name === name);
    assert.ok(row, `${name} 행이 없다`);
    assert.equal(row.auto, true, `${name} 의 auto`);
    assert.equal(row.approval, true, `${name} 의 approval`);
  }
});

test('T6 점유 — 🙏·🙇 는 auto:false 다 (채택선 미달) · approval:false 는 그대로 남는다', () => {
  // 3개월 clean 3,174건 실측: pray 정밀도 0.00(표본 2) · man-bowing 0.07(표본 14).
  // 채택선은 0.70 이고 표본 하한은 8 이다. 뜻은 정본으로 남기고 자동으로는 달지 않는다.
  for (const [name, prec] of [['pray', /0\.00/], ['man-bowing', /0\.07/]]) {
    const row = CATALOG.emojis.find((e) => e.name === name);
    assert.ok(row, `${name} 행이 없다`);
    assert.equal(row.auto, false, `${name} 이 auto:true 로 되돌아왔다 — 채택선을 먼저 넘겨라`);
    assert.equal(row.approval, false, `${name} 의 approval 은 남아 있어야 한다 (다른 축이다)`);
    assert.ok(row.means, `${name} 의 뜻이 지워졌다 — 내린 것은 자격이지 뜻이 아니다`);
    assert.match(row.autoNote, prec, `${name} 의 autoNote 에 실측 정밀도가 없다`);
    assert.match(row.autoNote, /0\.70/, `${name} 의 autoNote 에 채택선이 없다`);
  }
});

test('T6 점유 — 🙏·🙇 는 이제 자기 자신으로 나가지 않는다', () => {
  // 위 auto:false 의 실제 결과. 이 자리에서 나가던 🙇 14건 · 🙏 2건이 사라진다.
  for (const s of ['Good luck! Hope it goes well.', '화이팅! 잘 되기를 응원합니다', '잘 부탁드립니다']) {
    const g = responseGrade({ text: s, catalog: CATALOG });
    assert.ok(!['pray', 'man-bowing'].includes(g.emoji), `got ${g.emoji} for: ${s}`);
  }
});

test('T6 점유 — 오늘 approval:false + auto:true 인 행은 하나도 없다 (축은 살아 있고 자리가 비었다)', () => {
  // 이것이 지금 상태의 전부다. 접힘 해제 경로는 위 합성 어휘집 시험이 지키고 있고,
  // 번들에서는 그 칸이 비어 있다 — 실측의 결과이지 축이 없어진 것이 아니다.
  // 나중에 누가 이 칸을 채우려면 정밀도 0.70·표본 8 을 먼저 넘겨야 한다.
  const occupants = CATALOG.emojis.filter((e) => e.auto === true && e.level0 !== true && e.approval === false);
  assert.deepEqual(occupants.map((e) => e.name), []);
});

test('T6 점유 — 어휘집의 무거운 행은 approval 을 하나도 빠짐없이 적어 두었다', () => {
  // 안 적어도 안전한 쪽(접힘)으로 떨어지지만, 그러면 왜 접히는지가 파일에 안 남는다.
  const heavy = CATALOG.emojis.filter((e) => e.auto === true && e.level0 !== true && e.match);
  assert.deepEqual(heavy.map((e) => e.name), ['ok_hand', '+1']);
  for (const e of heavy) assert.equal(typeof e.approval, 'boolean', `${e.name} 에 approval 이 없다`);
  assert.ok(CATALOG._approval_doc, '_approval_doc 이 없다 — 축의 뜻이 파일에 안 남는다');
});

// ── T7 — 어휘집의 사실 교정 (2026-09-02 3개월 실측) ─────────────────────────

test('T7 🙇 행의 이름은 man-bowing 이다 — bow 는 실측 0건이라 남아 있으면 안 된다', () => {
  assert.equal(CATALOG.emojis.some((e) => e.name === 'bow'), false);
  const row = CATALOG.emojis.find((e) => e.name === 'man-bowing');
  assert.ok(row, 'man-bowing 행이 없다');
  assert.equal(row.char, '🙇‍♂️');
  assert.match(row.autoNote, /invalid_name/);
});

test('T7 🙌 는 "잘 안 쓴다" 가 아니다 — 뜻은 적되 auto 는 false 로 남는다', () => {
  const row = CATALOG.emojis.find((e) => e.name === 'raised_hands');
  assert.equal(row.auto, false);            // 정밀도 0.06 — 채택선 0.70 에 한참 못 미친다
  assert.doesNotMatch(row.means, /잘 안 쓴다/);
  assert.match(row.means, /환호/);
  assert.notEqual(row.use, '-');
  assert.match(row.autoNote, /0\.06/);
});

// ── T8 — resolvesPolicy 'self' (2026-09-06) ─────────────────────────────────
//
// 09-02 판은 리액션에 의한 자동 처리완료를 통째로 껐고, 그것이 막으려던 사고는 그것의
// 부분집합이었다. items.jsonl 2,004줄 실측: 자동 처리완료 1,083건 = 데몬 자기 이모지
// 155(14.3%) · 라이언 손 557(51.4%) · 남 371(34.3%). 'self' 는 155 를 계속 막고 557 을
// 되살리고 371 은 계속 열어 둔다.
//
// 이 묶음이 재는 것은 두 조건의 논리곱이다 — 라이언이 달았는가, 그리고 그것이 우리가
// 그 항목에 단 이모지가 아닌가. 앞의 것만 걸면 09-02 사고가 그대로 재현된다: 데몬의
// 리액션은 라이언 토큰(xoxp)으로 나가므로 자기 ack 이모지가 MY_USER 로 되돌아온다.

const MY = 'U_LION';
// 어휘집에 이름이 없는 이모지를 쓴다. 번들은 전 행이 resolves:false 라, 어휘집에 있는
// 이름으로 재면 행 단위 값이 먼저 막아서 self 의 두 조건이 도는지 안 도는지 안 보인다.
const OUTSIDER = 'tada';

function selfFns() {
  const f = daemonEmojiFns();
  assert.equal(f.resolvesPolicy(), 'self');
  f.setMyUser(MY);
  return f;
}

test('T8-1 데몬이 단 ack 이모지가 MY_USER 로 되돌아와도 항목을 닫지 않는다 (09-02 사고)', () => {
  const f = selfFns();
  // 스칼라만 있는 옛 레코드
  assert.equal(f.isResolvingEmoji(OUTSIDER, { by: MY, item: { id: 'C:1', ackEmoji: OUTSIDER } }), false);
  // 누적 배열
  assert.equal(f.isResolvingEmoji(OUTSIDER, { by: MY, item: { id: 'C:2', ackEmojis: [OUTSIDER] } }), false);
  // 갈아치워진 뒤 — 최신 스칼라는 다른 것이고 옛 이름은 배열에만 남아 있다.
  // ackEmoji 가 스칼라라 갈아치워지는 것이 ackEmojis 를 더한 이유다(ackSupersededAt 2건).
  assert.equal(f.isResolvingEmoji(OUTSIDER, {
    by: MY, item: { id: 'C:3', ackEmoji: 'mag', ackEmojis: [OUTSIDER, 'mag'] },
  }), false);
  // 스킨톤·별칭이 붙어 돌아와도 같은 이름이다.
  assert.equal(f.isResolvingEmoji(`${OUTSIDER}::skin-tone-3`, {
    by: MY, item: { id: 'C:4', ackEmoji: OUTSIDER },
  }), false);
  // resolvingReaction 도 같은 문을 지난다.
  assert.equal(f.resolvingReaction([{ name: OUTSIDER, users: [MY] }],
    { item: { id: 'C:5', ackEmoji: OUTSIDER } }), null);
});

test('T8-2 MY_USER 가 손으로 단 다른 이름은 항목을 닫는다 (557건 경로를 되살린 자리)', () => {
  const f = selfFns();
  const item = { id: 'C:6', ackEmoji: 'mag', ackEmojis: ['mag'] };
  assert.equal(f.isResolvingEmoji(OUTSIDER, { by: MY, item }), true);
  assert.deepEqual(f.resolvingReaction([{ name: OUTSIDER, users: [MY] }], { item }),
    { name: OUTSIDER, by: MY });
  // ack 이모지를 한 번도 안 단 항목도 같다.
  assert.equal(f.isResolvingEmoji(OUTSIDER, { by: MY, item: { id: 'C:7' } }), true);
  // 다만 행 단위 resolves:false 는 self 아래에서도 이긴다 — 🔍 는 라이언이 달아도 안 닫는다.
  assert.equal(f.isResolvingEmoji('mag', { by: MY, item: { id: 'C:8' } }), false);
  // 트리거도 그대로다.
  assert.equal(f.isResolvingEmoji('eyes', { by: MY, item: { id: 'C:9' } }), false);
});

test('T8-3 남이 단 리액션은 무엇이든 항목을 닫지 않는다 (371건은 계속 열려 있다)', () => {
  const f = selfFns();
  const item = { id: 'C:10' };
  assert.equal(f.isResolvingEmoji(OUTSIDER, { by: 'U_OTHER', item }), false);
  assert.equal(f.isResolvingEmoji('white_check_mark', { by: 'U_OTHER', item }), false);
  assert.equal(f.resolvingReaction([{ name: OUTSIDER, users: ['U_OTHER'] }], { item }), null);
  // 여럿이 달았고 그 안에 라이언이 있으면 라이언을 고른다 — users[0] 만 보면 놓친다
  // (reconcile 의 by 선택 규칙, §2-5d). 그 경로는 reactions.get 이 전수 실패라 오늘은
  // 죽어 있지만, 살아났을 때 올바르게 돌도록 문을 맞춰 둔 것이다.
  assert.deepEqual(f.resolvingReaction([{ name: OUTSIDER, users: ['U_OTHER', MY, 'U_THIRD'] }], { item }),
    { name: OUTSIDER, by: MY });
});

test('T8-4 ctx 가 없거나 item 이 없거나 MY_USER 가 null 이면 닫지 않는다 (fail-closed)', () => {
  const f = selfFns();
  assert.equal(f.isResolvingEmoji(OUTSIDER), false);                                  // ctx 없음
  assert.equal(f.isResolvingEmoji(OUTSIDER, {}), false);                              // by·item 없음
  assert.equal(f.isResolvingEmoji(OUTSIDER, { by: MY }), false);                      // item 없음
  assert.equal(f.isResolvingEmoji(OUTSIDER, { item: { id: 'C:11' } }), false);         // by 없음
  assert.equal(f.resolvingReaction([{ name: OUTSIDER, users: [] }], { item: { id: 'C:12' } }), null);

  // auth.test 전에 도착한 이벤트. MY_USER 가 아직 null 이면 무엇도 닫지 않는다.
  const g = daemonEmojiFns();
  assert.equal(g.getMyUser(), null);
  assert.equal(g.isResolvingEmoji(OUTSIDER, { by: MY, item: { id: 'C:13' } }), false);

  // 수집 경로(§2-5a)가 특례 없이 이 규칙 하나로 덮인다. 항목이 아직 없으므로 item 은
  // 의도된 null 이고, 그래서 self 아래에서 수집 시점에는 아무것도 닫히지 않는다.
  assert.match(DAEMON_SRC, /resolvingReaction\(msg\.reactions, \{ item: null \}\)/);
  assert.equal(f.resolvingReaction([{ name: OUTSIDER, users: [MY] }], { item: null }), null);
  // reconcile 은 반대로 항목을 넘긴다 — 같은 문, 다른 입력.
  assert.match(DAEMON_SRC, /resolvingReaction\(reactions, \{ item: o \}\)/);
});

// ── T8-5 경합 — 이번 배치에서 가장 값나가는 시험 ──────────────────────────────
//
// postEmojiReaction 이 reactions.add 를 먼저 하고 ackEmoji 를 나중에 적으면, 그 await 이
// 풀리기 전에 우리가 방금 단 리액션의 reaction_added 가 소켓으로 돌아온다. 그 시점에
// 디스크의 항목에는 ackEmoji 가 없고, 그러면 "우리가 단 이모지" 집합이 비어 self 의
// 필터를 통과한다 — 09-02 사고가 그대로 재현된다.
//
// 그래서 아래는 postEmojiReaction 원문을 잘라 실제로 돌린다. slack() 은 가짜이고,
// reactions.add 가 불린 그 순간에 소켓 핸들러가 하는 일 — 디스크를 다시 읽어
// isResolvingEmoji 에 묻는 것 — 을 그대로 한다. 쓰기 순서를 되돌리면 이 시험은 반드시
// 실패한다(2026-09-06 에 실제로 뒤집어 확인했다).
//
// 인메모리 Set 이 아니라 디스크로 막은 근거도 여기 같이 있다: rewriteItem 은
// readFileSync → writeFileSync → renameSync 로 동기이고 loadItems 에는 캐시가 없다.
test('T8-5 우리가 방금 단 이모지의 reaction_added 가 와도 항목을 닫지 않는다 (쓰기 순서 경합)', async () => {
  const logs = [];
  const acts = [];
  const calls = [];
  const disk = { id: 'C:RACE', channel: 'C', ts: '1.0' };
  const seen = [];        // 소켓이 그 순간에 내린 판정들

  const rewriteItem = (id, patch) => {
    assert.equal(id, disk.id);
    const merged = { ...disk, ...patch };
    for (const k of Object.keys(merged)) if (merged[k] === undefined) delete merged[k];
    for (const k of Object.keys(disk)) delete disk[k];
    Object.assign(disk, merged);
  };

  const body = `
    const EMOJIS = ['eyes'];
    const LATER_EMOJIS = ['bookmark', 'pushpin'];
    let nonResolvingNames = null;
    let nonResolvingAt = 0;
    let resolvesPolicyValue = null;
    let resolvesPolicyAt = 0;
    let resolvesPolicyFallbackLogged = false;
    ${grabLine('const RESOLVES_POLICIES')}
    let MY_USER = ${JSON.stringify(MY)};
    ${grabFn('baseEmoji')}
    ${grabFn('isTriggerEmoji')}
    ${grabFn('emojiLayerResolveFields')}
    ${grabFn('resolvesPolicy')}
    ${grabFn('nonResolvingEmojiNames')}
    ${grabFn('ourAckEmojis')}
    ${grabFn('isResolvingEmoji')}
    ${grabFn('emojiSafeToPost')}
    ${grabFn('decisionTag')}
    ${grabFn('withAckEmoji')}
    ${grabFn('postEmojiReaction')}
    // 소켓 핸들러가 하는 일 그대로 — 디스크를 다시 읽어(loadItems 에 캐시가 없다) 문에 묻는다.
    const slack = async (method, args) => {
      calls.push([method, args]);
      if (method === 'reactions.add') {
        const onDisk = readDisk();
        socketSaw(isResolvingEmoji(args.name, { by: MY_USER, item: onDisk }));
      }
      if (fail) throw new Error(fail);
      return { ok: true };
    };
    return { postEmojiReaction, isResolvingEmoji, resolvesPolicy };
  `;
  const make = (fail) => new Function(
    'readFileSync', 'BUNDLED_EMOJI_LAYER_FILE', 'EMOJI_LAYER_FILE', 'log',
    'rewriteItem', 'act', 'scrubSecrets', 'calls', 'readDisk', 'socketSaw', 'fail', 'loadItems', body)(
    readFileSync, CATALOG_FILE, join(D, '__no_such_override__.json'),
    (...a) => logs.push(a.join(' ')), rewriteItem, (k, r) => acts.push([k, r]), (x) => x,
    calls, () => ({ ...disk }), (v) => seen.push(v), fail, () => [{ ...disk }]);

  const f = make(null);
  assert.equal(f.resolvesPolicy(), 'self');
  // 어휘집에 없는 이름을 쓴다 — 행 단위 resolves:false 가 먼저 막으면 경합이 안 보인다.
  assert.equal(f.isResolvingEmoji(OUTSIDER, { by: MY, item: { id: 'C:RACE' } }), true,
    '이 이름은 원래라면 닫힌다 — 그래야 아래 false 가 ackEmoji 선기록 덕분임이 증명된다');

  const ok = await f.postEmojiReaction({ ...disk }, { emoji: OUTSIDER, decision: 'not-needed' });
  assert.equal(ok, true);
  assert.deepEqual(calls.map((c) => c[0]), ['reactions.add']);
  // 핵심 단언. reactions.add 가 도는 그 순간에 디스크에 ackEmoji 가 이미 있었는가.
  assert.deepEqual(seen, [false],
    'reactions.add 시점에 항목이 스스로 닫혔다 — ackEmoji 를 add 뒤에 적고 있다(순서를 되돌렸다)');
  assert.equal(disk.ackEmoji, OUTSIDER);
  assert.deepEqual(disk.ackEmojis, [OUTSIDER]);
  assert.ok(disk.ackAt > 0);
  assert.equal(disk.requestLevel, 0);
});

test('T8-5 reactions.add 가 실패하면 선기록을 되돌린다 (달지도 않은 이모지를 제외 집합에 남기지 않는다)', async () => {
  const logs = [];
  const acts = [];
  const calls = [];
  const seen = [];
  const disk = { id: 'C:FAIL', channel: 'C', ts: '1.0', ackEmoji: 'mag', ackEmojis: ['mag'] };
  const rewriteItem = (id, patch) => {
    const merged = { ...disk, ...patch };
    for (const k of Object.keys(merged)) if (merged[k] === undefined) delete merged[k];
    for (const k of Object.keys(disk)) delete disk[k];
    Object.assign(disk, merged);
  };
  const body = `
    const EMOJIS = ['eyes'];
    const LATER_EMOJIS = ['bookmark', 'pushpin'];
    let nonResolvingNames = null; let nonResolvingAt = 0;
    let resolvesPolicyValue = null; let resolvesPolicyAt = 0;
    let resolvesPolicyFallbackLogged = false;
    ${grabLine('const RESOLVES_POLICIES')}
    let MY_USER = ${JSON.stringify(MY)};
    ${grabFn('baseEmoji')}
    ${grabFn('isTriggerEmoji')}
    ${grabFn('emojiLayerResolveFields')}
    ${grabFn('resolvesPolicy')}
    ${grabFn('nonResolvingEmojiNames')}
    ${grabFn('ourAckEmojis')}
    ${grabFn('isResolvingEmoji')}
    ${grabFn('emojiSafeToPost')}
    ${grabFn('decisionTag')}
    ${grabFn('withAckEmoji')}
    ${grabFn('postEmojiReaction')}
    const slack = async (method, args) => { calls.push([method, args]); throw new Error(fail); };
    return { postEmojiReaction };
  `;
  const make = (fail) => new Function(
    'readFileSync', 'BUNDLED_EMOJI_LAYER_FILE', 'EMOJI_LAYER_FILE', 'log',
    'rewriteItem', 'act', 'scrubSecrets', 'calls', 'fail', 'loadItems', body)(
    readFileSync, CATALOG_FILE, join(D, '__no_such_override__.json'),
    (...a) => logs.push(a.join(' ')), rewriteItem, (k, r) => acts.push([k, r]), (x) => x, calls, fail,
    () => [{ ...disk }]);

  // 진짜 실패 — 슬랙에 아무것도 안 달렸으므로 선기록을 지운다.
  const ok = await make('invalid_name').postEmojiReaction({ ...disk }, { emoji: OUTSIDER, decision: 'unknown' });
  assert.equal(ok, false);
  assert.equal(disk.ackEmoji, 'mag');
  assert.deepEqual(disk.ackEmojis, ['mag']);
  assert.equal(seen.length, 0);

  // already_reacted — 그 이모지는 실제로 달려 있다. 선기록이 그대로 참이므로 되돌리지 않는다.
  // 일부러 **낡은** 항목 객체를 넘긴다(ack 필드가 없다). 데몬이 누적의 바닥으로 디스크의
  // 현재 줄을 읽지 않고 넘어온 객체를 쓰면 여기서 ackEmojis 가 ['mag', OUTSIDER] 가 아니라
  // [OUTSIDER] 가 되고, 먼저 단 mag 가 제외 집합에서 조용히 빠진다.
  const stale = { id: 'C:FAIL', channel: 'C', ts: '1.0' };
  const ok2 = await make('already_reacted').postEmojiReaction(stale, { emoji: OUTSIDER, decision: 'unknown' });
  assert.equal(ok2, true);
  assert.equal(disk.ackEmoji, OUTSIDER);
  assert.deepEqual(disk.ackEmojis, ['mag', OUTSIDER]);
  assert.equal(disk.requestLevel, 0);
});

// ── T8-6 리액션 제거 — 무더기 재개방이 이 자리의 해악이다 ────────────────────
//
// item.reactions 는 이름 다중집합만 저장하고 누가 달았는지를 저장하지 않는다. 그래서
// self 아래의 firstNonTrigger 는 ctx.by 를 만들 수 없어 언제나 null 이고, 옛 조건
// !firstNonTrigger(left) 를 그대로 두면 항상 참이 되어 리액션 하나 뗄 때마다 예전에
// 자동 처리완료된 항목이 전부 다시 열린다. 아래는 데몬 원문의 가드를 그대로 잘라 돌린다.
function removedGuard() {
  const start = DAEMON_SRC.indexOf('const pol = resolvesPolicy();');
  assert.ok(start >= 0, '데몬에 reaction_removed 가드가 없다');
  const tail = DAEMON_SRC.indexOf("} else if (pol !== 'none'", start);
  assert.ok(tail > start, '데몬 가드에 none 갈래가 없다');
  const end = DAEMON_SRC.indexOf('autoUnresolve(id, it);', tail) + 'autoUnresolve(id, it);'.length;
  const src = DAEMON_SRC.slice(start, end);
  return (policy, it, e, left) => {
    const called = [];
    // eslint-disable-next-line no-new-func
    new Function('resolvesPolicy', 'firstNonTrigger', 'baseEmoji', 'autoUnresolve', 'id', 'it', 'e', 'left', src)(
      () => policy,
      // self 아래에서 이름만으로는 판정할 수 없다는 사실 그대로 — 언제나 null 이다.
      () => (policy === 'self' ? null : (left[0] || null)),
      (n) => String(n || '').split('::')[0],
      (id, item) => called.push(id), it.id, it, e, left);
    return called;
  };
}

test('T8-6 self 에서 리액션 제거가 옛 autoDone 항목을 무더기로 되살리지 않는다', () => {
  const g = removedGuard();
  // 옛 레코드 — autoBy 가 없다. 되돌리지 않는다(fail-closed 의 뜻이 여기서는 "유지" 다).
  assert.deepEqual(g('self', { id: 'C:20', autoDone: true, autoEmoji: 'tada' },
    { user: MY, reaction: 'tada' }, []), []);
  // 남이 뗐다 — 닫은 사람이 아니다.
  assert.deepEqual(g('self', { id: 'C:21', autoDone: true, autoEmoji: 'tada', autoBy: MY },
    { user: 'U_OTHER', reaction: 'tada' }, []), []);
  // 닫은 그 사람이 다른 이모지를 뗐다 — 항목을 닫은 것은 그것이 아니다.
  assert.deepEqual(g('self', { id: 'C:22', autoDone: true, autoEmoji: 'tada', autoBy: MY },
    { user: MY, reaction: 'heart' }, []), []);
  // 손으로 처리완료한 항목은 autoDone 이 아니다 — 절대 되돌리지 않는다.
  assert.deepEqual(g('self', { id: 'C:23', autoEmoji: 'tada', autoBy: MY },
    { user: MY, reaction: 'tada' }, []), []);
  // 남은 리액션이 하나도 없어도 위 넷은 그대로 안 열린다 — "무엇이 남았는가" 로 재지 않는다.
  assert.deepEqual(g('self', { id: 'C:24', autoDone: true },
    { user: MY, reaction: 'tada' }, []), []);
});

test('T8-6 닫은 그 이모지를 그 사람이 떼면 미처리로 돌아온다', () => {
  const g = removedGuard();
  assert.deepEqual(g('self', { id: 'C:25', autoDone: true, autoEmoji: 'tada', autoBy: MY },
    { user: MY, reaction: 'tada' }, ['heart']), ['C:25']);
  // 스킨톤이 붙어 돌아와도 같은 이름이다.
  assert.deepEqual(g('self', { id: 'C:26', autoDone: true, autoEmoji: '+1', autoBy: MY },
    { user: MY, reaction: '+1::skin-tone-3' }, []), ['C:26']);
});

test('T8-6 none 과 catalog 아래의 가드는 글자 단위로 예전 그대로다', () => {
  const g = removedGuard();
  // none — 취소 경로를 통째로 건너뛴다.
  assert.deepEqual(g('none', { id: 'C:27', autoDone: true, autoEmoji: 'tada', autoBy: MY },
    { user: MY, reaction: 'tada' }, []), []);
  // catalog — 남은 것이 없으면 되돌리고, 남아 있으면 안 되돌린다.
  assert.deepEqual(g('catalog', { id: 'C:28', autoDone: true }, { user: MY, reaction: 'tada' }, []), ['C:28']);
  assert.deepEqual(g('catalog', { id: 'C:29', autoDone: true }, { user: MY, reaction: 'tada' }, ['heart']), []);
});

// ── 권장 시험 — 하위 호환과 누적 ────────────────────────────────────────────

test('T8 ourAckEmojis 는 ackEmojis 가 없는 옛 레코드를 ackEmoji 하나로 읽는다 (하위 호환)', () => {
  const f = daemonEmojiFns();
  // 2026-09-06 실측: ackEmoji 를 가진 295건 전부가 ackEmojis 없는 옛 모양이다.
  assert.deepEqual(f.ourAckEmojis({ ackEmoji: 'white_check_mark' }), new Set(['white_check_mark']));
  assert.deepEqual(f.ourAckEmojis({ ackEmoji: 'mag::skin-tone-2' }), new Set(['mag']));
  // 필드가 아예 없어도 읽는 쪽이 멈추지 않는다 — 빈 집합이다.
  assert.deepEqual(f.ourAckEmojis({}), new Set());
  assert.deepEqual(f.ourAckEmojis(null), new Set());
  assert.deepEqual(f.ourAckEmojis(undefined), new Set());
  // 배열 ∪ 스칼라. 갈아치워진 뒤에도 옛 이름이 남는다(ackSupersededAt 2건).
  assert.deepEqual(f.ourAckEmojis({ ackEmoji: 'mag', ackEmojis: ['white_check_mark'] }),
    new Set(['white_check_mark', 'mag']));
});

test('T8 withAckEmoji 는 중복 없이 누적하고 옛 스칼라를 씨앗으로 삼는다', () => {
  const f = daemonEmojiFns();
  assert.deepEqual(f.withAckEmoji({}, 'mag'), ['mag']);
  // ackEmojis 가 없는 옛 레코드 — 스칼라 하나가 배열의 첫 값이 된다.
  assert.deepEqual(f.withAckEmoji({ ackEmoji: 'white_check_mark' }, 'mag'), ['white_check_mark', 'mag']);
  assert.deepEqual(f.withAckEmoji({ ackEmojis: ['mag'] }, 'mag'), ['mag']);
  assert.deepEqual(f.withAckEmoji({ ackEmojis: ['mag'] }, 'mag::skin-tone-3'), ['mag']);
  // 원본을 고치지 않는다 — 실패했을 때 되돌릴 이전 값이 필요하다.
  const item = { ackEmojis: ['mag'] };
  f.withAckEmoji(item, 'tada');
  assert.deepEqual(item.ackEmojis, ['mag']);
});
