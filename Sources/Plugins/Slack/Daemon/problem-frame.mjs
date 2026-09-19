// problem-frame.mjs — 축 2. 물음의 모양을 본다.
//
// answer-context.mjs · emoji-layer.mjs 와 같은 규칙: 별도 파일이고 동적 import 이며,
// 이 파일이 없거나 터지면 데몬은 축 2 없이 예전대로 돈다. 정적 import 하나 때문에
// 데몬 전체가 안 뜨는 일을 만들지 않는다. 키체인을 열지 않고, 슬랙을 부르지 않고,
// 어떤 함수도 예외를 밖으로 내지 않는다.
//
// 이 축은 답하지 않는다 (설계 §1). 답의 옳고 그름을 보지 않고 물음의 모양만 본다.
//   F0 정상 · F1 범위 모호 · F2 이미 답이 나와 있다 · F3 질문이 잘못 세워졌다
// F0·F1·F2 는 아무것도 내보내지 않는다. F2 는 축 1을 R1 로 강등한다. F3 만 축 1과
// 별개의 메시지를 낸다.
//
// F3 이 특별한 이유 (설계 §8): 지적만 하고 끝내지 않는다. 공개 웹 자료를 실제로
// 조회해서 상대가 문제를 제대로 세울 재료를 함께 준다. 조회에 실패하면 — gsk 가
// 없거나, 시간 초과이거나, 쓸 만한 자료를 못 가져왔거나 — 지적만 따로 내보내지 않고
// 침묵한다. **근거 없는 훈수는 그 자체로 커뮤니케이션 코스트다.** 침묵이 기본값이고,
// 이때도 축 1의 리액션은 평소대로 나간다.

import { execFile } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const clean = (v) => String(v || '').replace(/\s+/g, ' ').trim();
const clip = (s, n) => (String(s || '').length > n ? String(s).slice(0, n) + '…' : String(s || ''));

// ── 정책 ─────────────────────────────────────────────────────────────────────
//
// slack-emoji-layer.json 과 같은 두 겹: 번들 JSON 이 정본이고 운영 수정은
// ~/.condition-mate/slack-translate/problem-framing-policy.json 으로 덮어쓴다.
// 파일을 하나도 못 읽어도 아래 폴백으로 계속 돈다 — 정책 파일이 사라졌다고 축 2가
// 조용히 다른 판정을 하기 시작하면 그것이 가장 나쁜 고장이다.
const FALLBACK_POLICY = {
  version: 0,
  persona: '나는 물음의 모양을 보는 에이전트다. 답하지 않는다. 이 물음이 제대로 세워졌는지, '
    + '이미 답이 나와 있는지, 실제로 걸려 있는 것이 다른 데 있는지만 본다.',
  grades: [
    { key: 'F0', label: '정상', action: '아무것도 하지 않는다' },
    { key: 'F1', label: '범위가 모호하다', action: '축 1의 글 안에 가정 한 줄을 밝힌다' },
    { key: 'F2', label: '이미 답이 나와 있다', action: '축 1을 R1 로 강등한다', demotesAxis1To: 'R1' },
    { key: 'F3', label: '질문이 잘못 세워졌다', action: '별개의 메시지 하나' },
  ],
  f3Format: { maxLines: 3, lines: ['무엇을 물었는가', '실제로 걸려 있는 것은 무엇인가', '대신 물을 만한 물음 하나'] },
  research: { onlyForGrades: ['F3'], tool: 'gsk', timeoutSec: 20, maxResults: 5, onFailure: 'silent' },
  output: { maxLines: 2, maxChars: 280 },
};

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}

export function loadFramingPolicy(files = []) {
  let policy = FALLBACK_POLICY;
  for (const f of files) {
    const obj = readJson(f);
    if (!obj || typeof obj !== 'object') continue;
    policy = {
      ...policy, ...obj,
      f3Format: { ...policy.f3Format, ...(obj.f3Format || {}) },
      research: { ...policy.research, ...(obj.research || {}) },
      output: { ...policy.output, ...(obj.output || {}) },
    };
  }
  return policy;
}

export const FRAME_GRADES = ['F0', 'F1', 'F2', 'F3'];

// ── 1) 등급 판정 ─────────────────────────────────────────────────────────────
//
// persona 는 프롬프트 첫머리에 그대로 실린다. 모델에게 자기 범위를 못박는 선언이지
// 나가는 글의 서두가 아니다 — 그 둘을 헷갈리면 정형 서두를 지우고 다시 만드는 꼴이
// 된다 (설계 §2·§3).
function framePrompt(policy, { text, thread }) {
  const f3 = policy.f3Format?.lines || FALLBACK_POLICY.f3Format.lines;
  return [
    policy.persona || FALLBACK_POLICY.persona,
    '',
    '아래 Slack 메시지의 물음이 어떤 모양인지 판정하라. 답을 쓰지 마라.',
    '',
    'F0 = 물음이 제대로 세워졌다. 고칠 것이 없다.',
    'F1 = 물음의 범위가 모호하다. 무엇까지를 묻는지가 정해지지 않았다.',
    'F2 = 이 물음의 답이 <thread> 에 이미 나와 있다. 되풀이할 자리다.',
    'F3 = 물음 자체가 잘못 세워졌다. 답을 주어도 상대가 원하는 곳에 닿지 못한다.',
    '',
    'F3 은 아주 드물다. 물음이 어렵거나 답하기 귀찮다고 F3 이 아니다. 상대가 묻는 것과',
    '실제로 걸려 있는 것이 다른 데 있을 때만 F3 이다. 확신이 서지 않으면 F0 이다.',
    '',
    `F3 일 때만 reframe 에 정확히 세 줄을 쓴다: (1) ${f3[0]} (2) ${f3[1]} (3) ${f3[2]}.`,
    '답을 쓰지 마라. 세 번째 줄은 물음 하나여야 하고 그 물음에 대한 답을 붙이지 마라.',
    'query 에는 그 물음을 뒷받침할 공개 웹 자료를 찾을 영어 검색어 한 줄을 쓴다.',
    '- 회사명, 사람 이름, 내부 코드명, URL, 계좌·토큰 같은 식별자는 절대 넣지 마라.',
    '- 일반적인 절차·요건을 찾는 질의로 일반화하라.',
    '',
    'Markdown 펜스 없이 JSON 객체 하나만 출력하라.',
    'Schema: {"grade":"F0","why":"","reframe":["","",""],"query":""}',
    '',
    '<thread>', clip(thread || '(앞선 대화 없음)', 3000), '</thread>',
    '',
    '<message>', clip(text || '', 1500), '</message>',
  ].join('\n');
}

export function parseFrame(raw) {
  const source = String(raw || '').trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  let obj;
  try { obj = JSON.parse(source); } catch { return null; }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return null;
  const grade = FRAME_GRADES.includes(String(obj.grade || '').toUpperCase())
    ? String(obj.grade).toUpperCase() : null;
  if (!grade) return null;
  const reframe = (Array.isArray(obj.reframe) ? obj.reframe : []).map(clean).filter(Boolean).slice(0, 3);
  return { grade, why: clean(obj.why), reframe, query: clean(obj.query).slice(0, 160) };
}

// 판정이 안 서면 F0 이다 — 축 2는 아무것도 안 하는 것이 기본값이다.
export async function frameVerdict({ text = '', thread = '', ask = null, policy = null, log = () => {} } = {}) {
  const pol = policy || FALLBACK_POLICY;
  if (typeof ask !== 'function') return { grade: 'F0', why: '판정기 없음', reframe: [], query: '' };
  let out = '';
  try {
    out = await ask(framePrompt(pol, { text, thread }));
  } catch (e) {
    log?.('축 2 판정 실패:', String(e?.message || e).slice(0, 80));
    return { grade: 'F0', why: '판정 실패', reframe: [], query: '' };
  }
  const parsed = parseFrame(out);
  if (!parsed) return { grade: 'F0', why: '판정 파싱 실패', reframe: [], query: '' };
  // F3 인데 세 줄을 못 냈으면 F3 이 아니다. 규격을 못 채운 F3 을 그대로 내보내면
  // "지적은 했는데 무엇을 대신 물어야 하는지는 없는" 메시지가 된다.
  if (parsed.grade === 'F3' && parsed.reframe.length < 3) {
    return { ...parsed, grade: 'F0', why: `${parsed.why || ''} (세 줄 규격 미달로 F0)`.trim() };
  }
  return parsed;
}

// ── 2) gsk 조회 ──────────────────────────────────────────────────────────────
//
// launchd 로 뜬 데몬의 PATH 에는 ~/.local/bin 이 없다. 이름만 넘기면 조용히
// "실행 파일 없음" 이 되고 축 2가 통째로 사라지므로 절대경로를 찾아 쓴다
// (answer-context.mjs 의 researchContext 와 같은 목록·같은 이유).
const GSK_CANDIDATES = [
  join(homedir(), '.local', 'bin', 'gsk'), '/opt/homebrew/bin/gsk', '/usr/local/bin/gsk', '/usr/bin/gsk',
];

export function resolveGsk(hint) {
  if (hint && hint.includes('/') && existsSync(hint)) return hint;
  return GSK_CANDIDATES.find((p) => existsSync(p)) || null;
}

// gsk 의 --timeout 기본값은 1800000ms(30분)다. 그대로 두면 데몬이 그 호출에 30분
// 매달린다. CLI 쪽에 밀리초로 명시하고 execFile 쪽에도 별도로 걸어 두 겹으로 막는다 —
// CLI 가 자기 타임아웃을 무시해도 프로세스가 죽는다.
function runGsk(gskPath, args, timeoutMs) {
  return new Promise((resolve) => {
    execFile(gskPath, args, { timeout: timeoutMs, killSignal: 'SIGKILL', encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 },
      (err, stdout) => resolve({ ok: !err, stdout: String(stdout || ''), err }));
  });
}

// 성공하면 { ok:true, rows:[{title,snippet,url}], query }. 실패·빈손이면 ok:false 와
// 사유. 호출부는 ok:false 를 보면 침묵한다 — 사유를 슬랙에 싣지 않는다.
export async function frameResearch({ query = '', gskPath = null, timeoutMs = 20_000, maxResults = 5, log = () => {} } = {}) {
  const q = clean(query);
  if (!q || /^none$/i.test(q)) return { ok: false, reason: 'NO_QUERY', rows: [], query: q };
  const gsk = resolveGsk(gskPath);
  if (!gsk) return { ok: false, reason: 'NO_GSK', rows: [], query: q };
  const r = await runGsk(gsk, ['search', q, '--output', 'json', '--timeout', String(timeoutMs)], timeoutMs + 4_000);
  if (!r.ok) {
    log?.('축 2 gsk 조회 실패:', String(r.err?.message || r.err || '').slice(0, 80));
    return { ok: false, reason: 'GSK_FAILED', rows: [], query: q };
  }
  const i = r.stdout.indexOf('{');
  if (i < 0) return { ok: false, reason: 'NO_JSON', rows: [], query: q };
  let json;
  try { json = JSON.parse(r.stdout.slice(i)); } catch { return { ok: false, reason: 'BAD_JSON', rows: [], query: q }; }
  if (json?.status === 'error') return { ok: false, reason: 'GSK_ERROR', rows: [], query: q };
  const rows = (json?.data?.organic_results || []).slice(0, Math.max(1, Number(maxResults) || 5))
    .map((x) => ({
      title: clean(x?.title), snippet: clip(clean(x?.snippet), 300), url: clean(x?.link || x?.url),
    }))
    .filter((x) => x.title && x.url);
  if (!rows.length) return { ok: false, reason: 'EMPTY', rows: [], query: q };
  return { ok: true, reason: '', rows, query: q };
}

// ── 3) 산출 ──────────────────────────────────────────────────────────────────

// 슬랙에 나가는 것은 세 번째 줄 — 대신 물을 물음 하나 — 뿐이다 (설계 §8).
// 가져온 자료 전문·출처 URL·왜 원래 물음이 어긋났는지의 설명은 한 줄도 여기 오지
// 않는다. 자료를 슬랙 본문에 풀어놓는 순간 이번에 지적된 것과 같은 실패다.
export function frameSlackLine(frame) {
  const rows = (frame?.reframe || []).map(clean).filter(Boolean);
  return rows.length >= 3 ? rows[2] : (rows[rows.length - 1] || '');
}

// MD 로 가는 전문. 세 줄 규격 그대로와, 조회한 자료를 출처까지 함께 적는다.
export function frameNoteBody(frame, research, labels = null) {
  const rows = labels || FALLBACK_POLICY.f3Format.lines;
  const three = (frame?.reframe || []).map(clean);
  const lines = [];
  if (three.length) {
    lines.push('### 물음 다시 세우기', '');
    three.forEach((s, i) => lines.push(`${i + 1}. **${rows[i] || ''}** — ${s}`));
    lines.push('');
  }
  if (clean(frame?.why)) lines.push('### 왜 F3 인가', '', clean(frame.why), '');
  if (research?.ok) {
    lines.push(`### 조회한 공개 자료 (질의: ${research.query})`, '',
      '공개 웹 자료이며 우리 회사의 확정 사실이 아니다.', '');
    for (const row of research.rows) lines.push(`- [${row.title}](${row.url}) — ${row.snippet}`);
    lines.push('');
  }
  return lines.join('\n').trim();
}

export default { loadFramingPolicy, FRAME_GRADES, frameVerdict, parseFrame, frameResearch,
  resolveGsk, frameSlackLine, frameNoteBody };
