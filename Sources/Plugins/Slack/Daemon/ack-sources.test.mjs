// 선응답이 어떤 소스에 대해 도는가 — ackSources. 두 가지로 돌릴 수 있다:
//   node --test ack-sources.test.mjs
//   node ack-sources.test.mjs "$PWD"      ← 이웃 시험들의 관행
// emoji-layer.decision.test.mjs 와 같은 방식이다. argv[2] 가 없으면 자기 위치를 쓴다.
//
// 왜 생겼나 (2026-09-02): acknowledgementOn 에
// ['mention', 'team', 'dm', 'broadcast'] 가 코드에 박혀 있었다. 리액션이 봇이 아니라
// 라이언 계정(xoxp)으로 나가는 구조라, 그가 불리지도 않은 그룹 DM 38개 방과 랜덤
// 채널의 남의 대화에 그의 이름으로 🔍 가 찍혔다. 원장 실측(actions-daemon.jsonl 의
// ack-emoji 195줄)으로 195건 중 78건(40%)이 그 자리였고, 🔍 로 바뀐 첫날 나간 30건으로
// 좁히면 20건(67%)이었다.
//
// 이 시험이 지키는 것은 이모지 하나가 아니다. acknowledgementOn 은 shouldAutoReply 의
// 첫 조건이고 그것이 postAcknowledgement 의 입구다. 그 함수 안에서 🔍 를 다는
// postEmojiReaction 과 근거 확보(ackEvidence · people-context · problem-frame ·
// 신규성 게이트)가 같이 돈다. 그래서 목록 하나가 "슬랙에 남는 흔적" 과 "모델 호출"
// 둘 다를 연다. 둘을 따로 막으면 이모지는 안 붙는데 값은 계속 나가는 상태가 된다.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const D = process.argv[2] || dirname(fileURLToPath(import.meta.url));
const DAEMON_FILE = join(D, 'slack-eyes-daemon.mjs');
const BUNDLED_POLICY = join(D, 'slack-ack-cost-policy.json');
const BUNDLED_REPLY = join(D, 'slack-reply-policy.json');

const DAEMON_SRC = readFileSync(DAEMON_FILE, 'utf8');

// 데몬은 최상위 스크립트라 import 하면 그대로 돌기 시작한다. 그래서 이웃 시험과 같이
// 함수 본문만 잘라 내 격리해서 부른다. 흉내낸 사본을 두지 않는 이유는 사본이 갈라져도
// 시험이 초록이기 때문이다 — 잘라 쓰면 데몬 쪽이 바뀌는 순간 여기서 깨진다.
function grabFn(name) {
  const i = DAEMON_SRC.indexOf(`function ${name}(`);
  assert.ok(i >= 0, `slack-eyes-daemon.mjs 에 function ${name} 이 없다`);
  let depth = 0;
  for (let k = DAEMON_SRC.indexOf('{', i); k < DAEMON_SRC.length; k++) {
    if (DAEMON_SRC[k] === '{') depth++;
    else if (DAEMON_SRC[k] === '}' && --depth === 0) return DAEMON_SRC.slice(i, k + 1);
  }
  throw new Error(`function ${name} 의 끝을 찾지 못했다`);
}

// 파일 경로는 전부 주입한다. ~/.condition-mate/slack-translate/ 는 도는 데몬이
// 메시지마다 읽는 운영 덮어쓰기 자리라, 시험이 거기 쓰면 정책이 그 자리에서 라이브가
// 된다. 임시 파일은 os.tmpdir() 에만 쓴다.
const NONE = join(tmpdir(), '__no_such_file_ack_sources__.json');

function daemonAckFns({
  bundledPolicy = BUNDLED_POLICY,
  overridePolicy = NONE,
  config = NONE,
  bundledReply = BUNDLED_REPLY,
  overrideReply = NONE,
} = {}) {
  const body = `
    ${grabFn('ackCostPolicy')}
    ${grabFn('ackSources')}
    ${grabFn('acknowledgementOn')}
    ${grabFn('replyPolicies')}
    ${grabFn('channelReplyPolicy')}
    ${grabFn('peopleReplyPolicy')}
    ${grabFn('shouldAutoReply')}
    return { ackSources, acknowledgementOn, shouldAutoReply, ackCostPolicy };
  `;
  // eslint-disable-next-line no-new-func
  return new Function(
    'readFileSync', 'BUNDLED_ACK_COST_POLICY_FILE', 'ACK_COST_POLICY_FILE', 'CONFIG_FILE',
    'BUNDLED_REPLY_POLICY_FILE', 'CHANNEL_POLICY_FILE', body,
  )(readFileSync, bundledPolicy, overridePolicy, config, bundledReply, overrideReply);
}

// 정책도 사람도 채널도 막지 않는 항목. 소스 하나만 갈아 끼워 쓴다 — 이 시험이 재는
// 것은 소스 축 하나이고, 사람·채널 축은 slack-reply-policy.json 이 따로 정한다.
const item = (source) => ({
  source, authorId: 'U03GRE909MJ_OTHER', channel: 'C_NOT_IN_POLICY', channelName: 'some-channel',
});

// ── 사전 확인 — 정본이 JSON 이고 코드에 박혀 있지 않다 ──────────────────────

test('사전 확인 — 번들 정책이 ackSources: ["mention"] 을 든다', () => {
  const o = JSON.parse(readFileSync(BUNDLED_POLICY, 'utf8'));
  assert.deepEqual(o.ackSources, ['mention']);
  assert.match(o._ackSources_doc, /40%/);
});

test('사전 확인 — acknowledgementOn 에 소스 목록이 박혀 있지 않다', () => {
  const fn = grabFn('acknowledgementOn');
  assert.equal(/'team'|'broadcast'/.test(fn), false, `아직 코드에 박혀 있다:\n${fn}`);
  assert.match(fn, /ackSources\(\)\.includes\(source \|\| ''\)/);
});

// 수집은 이 건에서 건드리지 않았다(지시서 D-5). dm·broadcast 는 계속 수집되고 번역되어
// 대시보드에 뜬다 — 달라지는 것은 슬랙에 흔적을 안 남긴다는 것 하나다.
test('사전 확인 — 수집 목록(activityPoll)은 네 소스를 그대로 든다', () => {
  assert.match(DAEMON_SRC, /const kinds = \['mention', 'team', 'dm', 'broadcast'\]\.filter\(sourceOn\);/);
});

// ── T1~T5 — 기본값에서 무엇이 도는가 ────────────────────────────────────────

test('T1 mention 이면 선응답이 돈다', () => {
  const f = daemonAckFns();
  assert.deepEqual(f.ackSources(), ['mention']);
  assert.equal(f.acknowledgementOn('mention'), true);
  assert.equal(f.shouldAutoReply(item('mention')), true);
});

test('T2 dm 이면 돌지 않는다', () => {
  const f = daemonAckFns();
  assert.equal(f.acknowledgementOn('dm'), false);
  assert.equal(f.shouldAutoReply(item('dm')), false);
});

test('T3 broadcast 면 돌지 않는다', () => {
  const f = daemonAckFns();
  assert.equal(f.acknowledgementOn('broadcast'), false);
  assert.equal(f.shouldAutoReply(item('broadcast')), false);
});

test('T4 team 이면 돌지 않는다', () => {
  const f = daemonAckFns();
  assert.equal(f.acknowledgementOn('team'), false);
  assert.equal(f.shouldAutoReply(item('team')), false);
});

test('T5 eyes(=source 없음)·later 는 예전과 같이 돌지 않는다', () => {
  const f = daemonAckFns();
  for (const s of [undefined, '', null, 'eyes', 'later']) {
    assert.equal(f.acknowledgementOn(s), false, `${String(s)} 가 통과했다`);
  }
  assert.equal(f.shouldAutoReply({ authorId: 'U1', channel: 'C1' }), false);
  assert.equal(f.shouldAutoReply(item('later')), false);
  // 항목 자체가 없는 경우도 예전 그대로 false 다.
  assert.equal(f.shouldAutoReply(undefined), false);
});

// ── T6 — 정본이 JSON 이라는 것 ──────────────────────────────────────────────

test('T6 운영 덮어쓰기로 dm 을 열면 코드 수정 없이 dm 이 돈다', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ack-sources-'));
  try {
    const f0 = join(dir, 'ack-cost-policy.json');
    writeFileSync(f0, JSON.stringify({ ackSources: ['mention', 'dm'] }));
    const f = daemonAckFns({ overridePolicy: f0 });
    assert.deepEqual(f.ackSources(), ['mention', 'dm']);
    assert.equal(f.acknowledgementOn('dm'), true);
    assert.equal(f.shouldAutoReply(item('dm')), true);
    // 열지 않은 것은 그대로 닫혀 있다 — 덮어쓰기가 배열을 통째로 갈아 끼운다.
    assert.equal(f.acknowledgementOn('broadcast'), false);
    assert.equal(f.acknowledgementOn('team'), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('T6 정책을 아예 못 읽으면 mention 만 돈다 (바닥값이 좁은 쪽이다)', () => {
  const f = daemonAckFns({ bundledPolicy: NONE, overridePolicy: NONE });
  assert.deepEqual(f.ackCostPolicy(), {});
  assert.deepEqual(f.ackSources(), ['mention']);
  assert.equal(f.acknowledgementOn('mention'), true);
  for (const s of ['dm', 'broadcast', 'team']) assert.equal(f.acknowledgementOn(s), false);
});

test('T6 값이 배열이 아니면 mention 만 돈다', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ack-sources-'));
  try {
    for (const bad of ['mention', 7, null, { mention: true }]) {
      const f0 = join(dir, 'ack-cost-policy.json');
      writeFileSync(f0, JSON.stringify({ ackSources: bad }));
      const f = daemonAckFns({ overridePolicy: f0 });
      assert.deepEqual(f.ackSources(), ['mention'], `ackSources=${JSON.stringify(bad)}`);
      assert.equal(f.acknowledgementOn('dm'), false);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// 빈 배열은 넓히지 않는다. 못 읽은 것과 "아무 데도 달지 마라" 를 구별해야 하고,
// 둘 중 넓은 쪽으로 잘못 읽으면 그 값이 남의 스레드에 라이언 이름으로 남는다.
test('T6 빈 배열은 mention 으로 넓히지 않고 그대로 지킨다', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ack-sources-'));
  try {
    const f0 = join(dir, 'ack-cost-policy.json');
    writeFileSync(f0, JSON.stringify({ ackSources: [] }));
    const f = daemonAckFns({ overridePolicy: f0 });
    assert.deepEqual(f.ackSources(), []);
    for (const s of ['mention', 'dm', 'broadcast', 'team']) {
      assert.equal(f.acknowledgementOn(s), false);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── T7 — 기존 전체 off 토글이 그대로 이긴다 ────────────────────────────────

test('T7 acknowledgements: false 는 ackSources 와 무관하게 전부 막는다', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ack-sources-'));
  try {
    const cfg = join(dir, 'config.json');
    writeFileSync(cfg, JSON.stringify({ acknowledgements: false }));
    const wide = join(dir, 'ack-cost-policy.json');
    writeFileSync(wide, JSON.stringify({ ackSources: ['mention', 'team', 'dm', 'broadcast'] }));
    const f = daemonAckFns({ config: cfg, overridePolicy: wide });
    assert.deepEqual(f.ackSources(), ['mention', 'team', 'dm', 'broadcast']);
    for (const s of ['mention', 'team', 'dm', 'broadcast']) {
      assert.equal(f.acknowledgementOn(s), false, `${s} 가 전체 off 를 뚫었다`);
    }
    assert.equal(f.shouldAutoReply(item('mention')), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('T7 acknowledgements 키가 없거나 true 면 예전 그대로 켜져 있다', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ack-sources-'));
  try {
    for (const cfgObj of [{}, { acknowledgements: true }, { emojis: ['eyes'] }]) {
      const cfg = join(dir, 'config.json');
      writeFileSync(cfg, JSON.stringify(cfgObj));
      const f = daemonAckFns({ config: cfg });
      assert.equal(f.acknowledgementOn('mention'), true, JSON.stringify(cfgObj));
      assert.equal(f.acknowledgementOn('dm'), false);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// 사람·채널 축은 이 건에서 안 건드렸다. 소스가 통과해도 그 둘이 막으면 여전히 막힌다.
test('사람·채널 no-reply 정책은 mention 이어도 그대로 이긴다', () => {
  const f = daemonAckFns();
  assert.equal(f.shouldAutoReply({ ...item('mention'), authorId: 'U03H8P77THN' }), false);
  assert.equal(f.shouldAutoReply({ ...item('mention'), channel: 'C03GJV11UTV' }), false);
});
