#!/usr/bin/env node
// ack-dryrun.mjs — 선응답 두 축을 실제 데이터로 돌려 보되, 슬랙에는 한 글자도
// 내보내지 않는다.
//
// 왜 필요한가: 이 데몬의 판정은 전부 실제 코퍼스 위에서만 드러난다. 이름 매칭이
// 맞는지, 메시지 1 에 없는 것이 채워지지 않았는지, 등급 셋이 어떻게 붙는지는
// 코드를 읽어서는 알 수 없고 돌려 봐야 안다. 그런데 데몬을 그냥 돌리면 그 결과가
// 실제 스레드로 나간다. 그래서 발신만 뺀 같은 경로가 따로 필요하다.
//
// 발신 차단은 "안 부르면 된다"로 두지 않았다. 아래 slack() 은 chat.postMessage ·
// files.completeUploadExternal · reactions.add 같은 쓰기 메서드에 닿는 순간 예외로
// 죽는다. 실수로 발신 경로가 이어지면 조용히 나가는 것이 아니라 하네스가 멈춘다.
//
// 사용법:
//   node Scripts/ack-dryrun.mjs <channel>:<ts> [--out <dir>]
//
// 산출물: docs/dryrun/<channel>-<ts>.md

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = dirname(HERE);
const DAEMON_DIR = join(REPO, 'Sources', 'Plugins', 'Slack', 'Daemon');
const OUT_DIR = join(homedir(), '.condition-mate', 'slack-translate');
const ITEMS_FILE = join(OUT_DIR, 'items.jsonl');

const args = process.argv.slice(2);
const target = args.find((a) => !a.startsWith('--')) || '';
const outIdx = args.indexOf('--out');
const outDir = outIdx >= 0 ? args[outIdx + 1] : join(REPO, 'docs', 'dryrun');
if (!/^[^:]+:[\d.]+$/.test(target)) {
  console.error('사용법: node Scripts/ack-dryrun.mjs <channel>:<ts> [--out <dir>]');
  process.exit(2);
}
const [CHANNEL, TS] = target.split(':');

// ── 슬랙 — 읽기만 ───────────────────────────────────────────────────────────
const WRITE_METHODS = /^(chat\.|reactions\.|files\.|conversations\.(create|invite|archive)|pins\.|assistant\.)/;
const token = (() => {
  try {
    return execFileSync('security', ['find-generic-password', '-w', '-s', 'cm-slack-user-token'],
      { encoding: 'utf8' }).trim();
  } catch { return ''; }
})();
if (!token) { console.error('cm-slack-user-token 을 키체인에서 찾지 못했다.'); process.exit(3); }

let apiCalls = 0;
async function slack(method, params = {}) {
  if (WRITE_METHODS.test(method)) {
    throw new Error(`드라이런에서 발신 메서드 호출: ${method} — 이 경로는 막혀 있다`);
  }
  apiCalls += 1;
  const body = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) body.set(k, String(v));
  const res = await fetch(`https://slack.com/api/${method}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  const json = await res.json();
  if (!json.ok) throw new Error(`slack ${method}: ${json.error}`);
  return json;
}

// ── 모델 — 데몬의 기본 경로(Gemini)만 쓴다 ──────────────────────────────────
// 키는 키체인에서만 읽고 이 프로세스 밖으로 나가지 않는다. 산출물에도 로그에도
// 키가 실릴 자리는 없다 — 오류 메시지는 HTTP 상태만 담는다.
const geminiKey = (() => {
  try {
    return execFileSync('security', ['find-generic-password', '-w', '-s', 'cm-gemini-api-key'],
      { encoding: 'utf8' }).trim();
  } catch { return ''; }
})();

async function callModel(prompt) {
  if (!geminiKey) return { out: '', model: 'none', error: 'cm-gemini-api-key 없음' };
  const cfgModel = (() => {
    try { return JSON.parse(readFileSync(join(OUT_DIR, 'config.json'), 'utf8')).model; } catch { return ''; }
  })();
  const apiModel = cfgModel === 'gemini-flash' ? 'gemini-flash-latest' : 'gemini-flash-lite-latest';
  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${apiModel}:generateContent`,
      { method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': geminiKey },
        body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], generationConfig: { temperature: 0.2 } }),
        signal: AbortSignal.timeout(30_000) });
    if (!res.ok) return { out: '', model: apiModel, error: `HTTP ${res.status}` };
    const json = await res.json();
    const out = (json.candidates?.[0]?.content?.parts || []).map((p) => p.text || '').join('').trim();
    return { out, model: apiModel };
  } catch (e) {
    return { out: '', model: apiModel, error: String(e?.message || e).slice(0, 120) };
  }
}

// ── 코퍼스에서 스레드를 만든다 ──────────────────────────────────────────────
function loadThread() {
  const rows = [];
  for (const line of readFileSync(ITEMS_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try { rows.push(JSON.parse(line)); } catch { /* 깨진 줄은 건너뛴다 */ }
  }
  const item = rows.find((o) => o.channel === CHANNEL && o.ts === TS);
  if (!item) throw new Error(`items.jsonl 에 ${CHANNEL}:${TS} 가 없다`);
  const root = item.threadTs || item.ts;
  const thread = rows
    .filter((o) => o.channel === CHANNEL && (o.ts === root || o.threadTs === root))
    .sort((a, b) => Number(a.ts) - Number(b.ts));
  return { item, thread };
}

const { item, thread } = loadThread();
// 데몬의 gatherContext 는 스레드를 이 모양으로 접는다. 여기서도 같은 모양을 쓴다 —
// 축 0 이 보는 것이 실제 운영에서 보는 것과 달라지면 드라이런의 값어치가 없다.
const threadText = thread
  .filter((o) => o.ts !== item.ts)
  .map((o) => `${o.author || o.authorId}: ${o.textEn || ''}`).join('\n');

// ── 모듈 ────────────────────────────────────────────────────────────────────
const people = await import(join(DAEMON_DIR, 'people-context.mjs'));
const align = await import(join(DAEMON_DIR, 'alignment-engine.mjs'));
const emoji = await import(join(DAEMON_DIR, 'emoji-layer.mjs'));
const answer = await import(join(DAEMON_DIR, 'answer-context.mjs'));
const frameMod = await import(join(DAEMON_DIR, 'problem-frame.mjs'));
const novelty = await import(join(DAEMON_DIR, 'novelty-gate.mjs'));
const note = await import(join(DAEMON_DIR, 'ack-note.mjs'));

const P = (n) => join(DAEMON_DIR, n);
const SENSITIVE_FILES = [P('slack-sensitive-policy.json'), join(OUT_DIR, 'sensitive-policy.json')];

// 이 워크스페이스의 나(=토큰 주인). 축 0 후보에서 자기 자신을 뺄 때 쓴다.
const me = await slack('auth.test').then((r) => r.user_id).catch(() => '');

// ── 축 1 등급 ───────────────────────────────────────────────────────────────
const catalog = emoji.loadCatalog([P('slack-emoji-layer.json'), join(OUT_DIR, 'emoji-layer.json')]);
let grade = { grade: 'R2', reason: 'emoji-layer 없음' };
try { grade = emoji.responseGrade({ text: item.textEn, catalog, source: item.source }); } catch { /* 기본값 유지 */ }

// ── 축 0 — 실제 슬랙 조회 ───────────────────────────────────────────────────
const access = answer.resolveAccess({
  userId: item.authorId, text: item.textEn, ctx: threadText,
  policyFiles: [P('slack-permission-policy.json'), join(OUT_DIR, 'permission-policy.json')],
});
let cache = people.directoryCache({ dir: OUT_DIR });
let dirNote = '';
if (!cache || Date.now() - Number(cache.fetchedAt || 0) > 6 * 60 * 60_000) {
  const r = await people.refreshDirectory({ slack, dir: OUT_DIR, log: (...a) => console.error(...a) });
  if (!r.ok) dirNote = r.error;
  cache = people.directoryCache({ dir: OUT_DIR });
}
const pc = access.sources['people-directory'] === false
  ? null
  : await people.peopleContext({
      slack, text: item.textEn, ctx: threadText, cache,
      selfIds: [me, item.authorId].filter(Boolean),
      notionHrDbId: (() => {
        try { return JSON.parse(readFileSync(join(OUT_DIR, 'config.json'), 'utf8')).hrDatabaseId || null; }
        catch { return null; }
      })(),
      directoryError: dirNote, timeoutMs: 3_000, log: (...a) => console.error(...a),
    });
const message1 = pc && pc.grade !== 'C0' ? people.renderContextMessage(pc, {}) : '';

// ── 축 2 — 문제 정의 ────────────────────────────────────────────────────────
const framePolicy = frameMod.loadFramingPolicy([P('slack-problem-framing-policy.json'),
  join(OUT_DIR, 'problem-framing-policy.json')]);
const frame = await frameMod.frameVerdict({
  text: item.textEn, thread: threadText, policy: framePolicy,
  ask: (p) => callModel(p).then((r) => r.out), log: (...a) => console.error(...a),
}).catch(() => null);

// ── F2 강등 취소 ────────────────────────────────────────────────────────────
// 축 2는 스레드만 보고 "이미 답이 나와 있다"고 판정하는데, 축 0 은 바로 그 스레드에
// 없는 것을 읽어 온 참이다. 데몬의 axis0CancelsF2 와 같은 판정기(novelty-gate.mjs)를
// 같은 입력으로 부른다 — 하네스가 자기 판정기를 따로 두면 드라이런과 운영이 갈라진다.
// 데몬과 같이 렌더된 메시지 1 이 아니라 noveltyProbe(조회로 얻은 값만)를 넣는다.
// 메시지 1 을 넣던 판에서는 근거 토큰 여덟 개가 전부 고정 서두라 취소가 언제나 참이었다.
const f2Probe = typeof people.noveltyProbe === 'function' ? people.noveltyProbe(pc) : '';
const f2Tokens = (frame?.grade === 'F2' && f2Probe.trim())
  ? novelty.novelTokens(f2Probe, `${threadText}\n${item.textEn}`) : [];
const f2Cancelled = f2Tokens.length > 0;

// ── 축 1 — 글 ──────────────────────────────────────────────────────────────
const extra = {
  glossary: answer.glossaryContext({ text: item.textEn, ctx: threadText, level: access.level,
    files: [P('slack-glossary.json'), join(OUT_DIR, 'glossary.json')] }),
  notion: '', research: '', related: '', attachments: '',
  people: pc ? pc.promptText : '',
};
const prompt = align.extractionPrompt({
  text: item.textEn, context: threadText, jira: '', extra,
  language: /[가-힣]/.test(item.textEn || '') ? 'ko' : 'en',
});
const model = await callModel(prompt);
const analysis = align.parseExtraction(model.out);
const rendered = align.renderReply(analysis, { withAssumption: frame?.grade === 'F1' });
const gate = rendered ? align.ackSendGate({
  analysis, extra, jira: '', body: rendered,
  requestLevel: align.evidenceRequestLevel(extra), noRequestSignal: null,
  channelName: item.channelName || '', sourceText: item.textEn, context: threadText,
  files: item.files || [], sensitivePolicyFiles: SENSITIVE_FILES,
  thread: `${threadText}\n${item.textEn}`, threadAfter: '',
}) : null;
const brief = rendered ? align.slackBrief(rendered) : { text: '', overflow: '' };
const message2 = gate?.send && brief.text ? `<@${item.authorId}> ${brief.text}` : '';

// 데몬의 게이트를 그대로 다시 적는다. 메시지 1 은 축 1 이 실제로 나갈 때만 나간다 —
// R0/R1, F2 강등, 발신 차단, NO_BRIEF_LINE 이면 근거만 덩그러니 남는 자리가 되므로
// 아무것도 내보내지 않는다. 하네스가 이 규칙을 빼먹으면 "메시지 1 이 나간다"는
// 산출물이 실제 운영과 달라지고, 그러면 드라이런을 볼 이유가 없어진다.
const axis1Blocked = ['R0', 'R1'].includes(grade.grade) ? `축 1 등급 ${grade.grade}`
  : (frame?.grade === 'F2' && !f2Cancelled) ? 'F2 강등 — 이미 답이 나와 있음'
  : !rendered ? '근거를 찾지 못함(NO_BASIS)'
  : !gate?.send ? `발신 차단 ${(gate?.reasons || []).join(',')}`
  : !brief.text ? 'NO_BRIEF_LINE'
  : '';
const wouldSend1 = Boolean(message1) && !axis1Blocked;

// ── MD ──────────────────────────────────────────────────────────────────────
const noteBody = note.renderNote({
  channel: item.channel, channelName: item.channelName, ts: item.ts, permalink: item.permalink,
  author: item.author, grade: grade.grade, gradeReason: String(analysis?.adds || ''),
  frameGrade: frame?.grade || 'F0',
  frameReason: `${String(frame?.why || '')}${f2Cancelled ? ' (축 0 으로 취소됨)' : ''}`,
  ctxGrade: pc?.grade || 'C0', people: pc?.promptText || '',
  message: item.textEn, sent: brief.text, overflow: brief.overflow,
  detail: String(analysis?.detail || ''),
  evidence: { context: threadText, glossary: extra.glossary },
  audience: 'disk',
});

const fence = (s) => '```\n' + String(s || '(없음)').replace(/```/g, '``​`') + '\n```';
const md = [
  `# 드라이런 · ${item.channelName || CHANNEL} · ${TS}`,
  '',
  `- 실행: ${new Date().toISOString()}`,
  `- 작성자: ${item.author || item.authorId}`,
  `- 슬랙 API 읽기 호출 ${apiCalls}회 · 발신 0회 (발신 메서드는 하네스에서 차단)`,
  `- 모델: ${model.model}${model.error ? ` (실패: ${model.error})` : ''}`,
  '',
  '## ① 입력 원문',
  fence(item.textEn),
  '## ① 스레드',
  fence(threadText),
  '## ② 메시지 1 — 컨텍스트 매니지먼트 (축 0)',
  `실제 발신 여부: **${wouldSend1 ? '나간다' : '나가지 않는다'}**`
    + `${axis1Blocked ? ` — 축 1 이 나가지 않으므로(${axis1Blocked}) 메시지 1 도 나가지 않는다. 아래는 렌더 결과일 뿐이다.` : ''}`,
  message1 ? fence(message1) : '(렌더 없음 — 축 0 등급 C0 이거나 축 0 이 꺼져 있다)',
  '## ③ 메시지 2 — 의사결정 서포트 (축 1)',
  message2 && !axis1Blocked ? fence(message2)
    : `(발신 없음 — ${axis1Blocked || (gate ? (gate.reasons || []).join(',') || '알 수 없음' : '글이 만들어지지 않음')})`,
  '## ④ 등급 셋',
  `- 축 1 응답 등급 R: **${grade.grade}** — ${grade.reason || ''}`,
  `- 축 2 문제 정의 등급 F: **${frame?.grade || 'F0'}** — ${frame?.why || '(판정 없음)'}`
    + `${f2Cancelled ? ` · **F2 강등 취소** — 축 0 이 스레드에 없는 사실 ${f2Tokens.length}개를 가져옴: ${f2Tokens.join(', ')}` : ''}`,
  `- 축 0 사람 조회 등급 C: **${pc?.grade || 'C0'}** — 해석 ${pc?.rows?.length || 0}명 · 미해석 ${pc?.unresolved?.length || 0}명`,
  `- 발신 게이트: ${gate ? (gate.send ? '통과' : `차단 ${(gate.reasons || []).join(',')}`) : '(글 없음)'}`
    + `${gate?.confidence == null ? '' : ` · 확신 ${gate.confidence}`}`
    + `${gate?.novelty ? ` · 신규성 ${gate.novelty.novel ? '있음' : '없음'}(${gate.novelty.overlap})` : ''}`,
  `- 권한: ${access.reason}`,
  '',
  '## ⑤ 조회처별 상태',
  ...(pc?.sources || []).map((s) => `- ${s.name}: ${s.state}`),
  ...(pc?.rows || []).map((r) => `- ${r.name} (${r.id}): ${r.lines.join(' · ')}`
    + `${r.missing.length ? ` · 미조회 ${r.missing.join('/')}` : ''}`),
  ...(pc?.unresolved || []).map((u) => `- ${u.name}: ${u.where} ${u.result}`),
  ...(pc?.mentioned || []).map((m) => `- ${m.name} (${m.id}): 조회하지 않음 — `
    + `${m.why === 'speaker' ? '스레드 발화자 라벨(말한 사람이지 이야기된 사람이 아니다)' : '멘션(슬랙에서 눌러 프로필을 볼 수 있다)'}`),
  '',
  '## ⑥ MD 첨부 본문',
  fence(noteBody),
].join('\n');

mkdirSync(outDir, { recursive: true });
const path = join(outDir, `${CHANNEL}-${TS}.md`);
writeFileSync(path, md.endsWith('\n') ? md : `${md}\n`);
console.log(path);
if (!existsSync(path)) process.exit(1);
