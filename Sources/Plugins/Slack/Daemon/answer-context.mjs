// answer-context.mjs — 선응답(ack)이 답을 만들 때 쓰는 추가 컨텍스트 레이어들.
//
// 왜 생겼나: 예전 선응답은 "같은 스레드 + Jira" 두 가지만 보고 답했다. 그래서
// 스레드 안에 이미 노션 문서가 공유돼 있는데도 "관련 문서가 있나요?"라는 질문에
// "문서를 확인해 보겠습니다" 같은 원론적인 답이 나갔다 (2026-08-29 실제 사고:
// Company document Singapore 링크를 스레드에 붙여 놓고도 상대가 "Do we have any
// documents for MPC?"라고 다시 물었고, 봇은 그 문서를 읽지 않은 채 "확인하겠다"고
// 답했다). 사람은 모바일에서 링크를 열지 않는 일이 흔하다. 그러면 답하는 쪽이
// 그 문서를 대신 읽고 "이미 공유한 그것으로 충분한지"까지 말해 줘야 한다.
//
// 그리고 문서를 읽는 것만으로는 부족한 경우가 바로 이어서 드러났다. 같은 스레드에서
// "Bolor Geo SG 서류는 있는데 MPC SG 서류가 없다"는 말이 오갔는데, 둘은 같은 법인의
// 다른 이름이었다. 문서를 아무리 잘 읽어도 그 대응표가 없으면 "없는 서류"를 찾으러
// 간다. 그래서 이름 대응이 첫 번째 레이어다.
//
// 레이어는 다섯이다. 앞의 넷은 근거를 늘리고, 마지막 하나는 그 근거를 이 사람에게
// 실어 보내도 되는지를 정한다.
//   glossary  같은 대상을 부르는 다른 이름 — 조직만 아는 사실이라 파일로 둔다.
//   notion    스레드에 공유된 노션 페이지 본문 — Notion API로 읽는다. 사설 페이지는
//             외부 크롤러(gsk)가 로그인 벽에 막혀 못 읽으므로 이 경로가 유일하다.
//   research  이 일을 하려면 원래 무엇이 필요한지 — 공개 웹(genspark). 우리 사실이
//             아니라 "공개 자료 기준"이라는 라벨이 붙은 채로만 프롬프트에 실린다.
//   related   같은 주제를 다룬 다른 스레드 — Slack search.messages.
//   access    위 넷의 반출 가부 — 사람별 권한 등급.
//
// 이 모듈은 키체인을 직접 열지 않는다 (media-extract.mjs 와 같은 규칙). 토큰과
// slack 호출기는 전부 opts 로 들어온다. 그리고 어떤 함수도 예외를 밖으로 내지
// 않는다 — 레이어 하나가 실패해도 선응답은 나가야 한다. 실패는 문자열로 돌려서
// 프롬프트에 "조회 실패"로 남는다. 조용히 빈 값이 되면 모델이 "확인했는데 없었다"로
// 읽는다.

import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const clip = (s, max) => {
  const t = String(s || '');
  return t.length > max ? `${t.slice(0, max)}…(이하 생략)` : t;
};

// ── 1) access — 권한 등급 ────────────────────────────────────────────────────
//
// 등급은 "이 사람이 이 도메인에서 어디까지 볼 수 있는가" 하나만 뜻한다.
// 일반 등급은 1~3이고, 특정 도메인의 운영을 맡은 사람은 그 도메인에 한해 더 높은
// 등급을 갖는다 (예: Global MPC 운영자는 globalmpc 9 — 그 도메인 정보는 전부).
// 도메인이 다르면 등급도 따라오지 않는다. globalmpc 9인 사람도 다른 도메인에서는
// 자기 기본 등급이다.
//
// 주의: 이 등급은 "추가 컨텍스트 레이어"에만 적용된다. 자격증명·급여·내부 보안
// 정보를 달라는 요청은 등급과 무관하게 데몬의 securityGate 가 먼저 차단한다.
// 9등급이어도 슬랙 봇이 API 키를 뱉는 경로는 만들지 않는다.
const FALLBACK_POLICY = {
  version: 1,
  defaultLevel: 2,
  // 각 근거가 요구하는 최소 등급.
  sourceMinLevel: {
    // 스레드에 이미 공유된 문서는 그 사람이 이미 볼 수 있는 것이다 — 새 노출이 아니다.
    'notion-shared': 1,
    // 공개 웹은 누구나 볼 수 있다.
    research: 1,
    jira: 3,
    // 다른 스레드는 그 사람이 속하지 않은 대화일 수 있다.
    related: 5,
  },
  domains: [],
  people: {},
};

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}

// 번들 정책 + 운영 정책(대시보드가 쓰는 파일)을 이 순서로 덮어쓴다.
// 사람 항목은 통째로 교체한다 — 부분 병합은 "어느 값이 이겼는지" 를 알 수 없게 만든다.
function loadPolicy(policyFiles = []) {
  let policy = { ...FALLBACK_POLICY };
  for (const f of policyFiles) {
    const obj = readJson(f);
    if (!obj) continue;
    policy = {
      ...policy,
      ...obj,
      sourceMinLevel: { ...policy.sourceMinLevel, ...(obj.sourceMinLevel || {}) },
      domains: obj.domains || policy.domains,
      people: { ...policy.people, ...(obj.people || {}) },
    };
  }
  return policy;
}

function detectDomain(policy, haystack) {
  for (const d of policy.domains || []) {
    if (!d?.match) continue;
    let re;
    try { re = new RegExp(d.match, 'i'); } catch { continue; }
    if (re.test(haystack)) return d;
  }
  return null;
}

// 결정적이고 설명 가능한 판정 하나를 돌려준다. reason 은 그대로 act() 로그에 남아
// "왜 이 근거가 빠졌는지" 를 나중에 되짚을 수 있게 한다.
export function resolveAccess({ userId, text = '', ctx = '', policyFiles = [], messageOnly = true } = {}) {
  const policy = loadPolicy(policyFiles);
  // 2026-08-31 사고. 도메인 판정이 `메시지 + 채널컨텍스트`를 한 덩어리로 봤다.
  // 채널 최근 대화는 스레드가 아니고 날짜가 넘어가면 화제가 통째로 바뀐다 — Piyush 건에서
  // 사흘 전 다른 프로젝트 이야기가 이 메시지의 도메인을 정한 경로가 이것이다. 도메인이
  // 바뀌면 권한 등급이 바뀌고, 등급이 바뀌면 어느 근거를 조회할지가 바뀐다. 그래서
  // 기본값은 메시지 안의 일치만 인정한다 (glossaryContext 의 messageOnly 와 같은 규칙).
  // 컨텍스트까지 보려면 부르는 쪽이 messageOnly:false 로 그 선택을 명시해야 한다.
  const domain = detectDomain(policy, messageOnly ? String(text || '') : `${text}\n${ctx}`);
  const person = (userId && policy.people?.[userId]) || null;
  const base = Number(person?.default ?? policy.defaultLevel ?? 2);
  const level = domain && person?.levels?.[domain.key] !== undefined
    ? Number(person.levels[domain.key]) : base;
  const min = policy.sourceMinLevel || {};
  const sources = {};
  const withheld = [];
  // 근거 종류를 여기에 배열로 박아 두었더니, 정책 파일에 sourceMinLevel 한 줄을 더해도
  // access.sources 에는 나타나지 않았다 (2026-08-31, people-directory 를 더하다 드러남).
  // 정책이 정본이니 정책의 키를 그대로 돈다. 아래 넷은 FALLBACK_POLICY 에 언제나
  // 들어 있으므로 이 변경으로 빠지는 키는 없다 — 늘어나기만 한다.
  for (const key of Object.keys(min).length ? Object.keys(min)
    : ['notion-shared', 'research', 'jira', 'related']) {
    const need = Number(min[key] ?? 1);
    const ok = level >= need;
    sources[key] = ok;
    if (!ok) withheld.push(`${key}(필요 ${need})`);
  }
  return {
    level,
    domain: domain?.key || 'general',
    domainLabel: domain?.label || '일반',
    person: person?.name || null,
    sources,
    withheld,
    reason: `${person?.name || userId || 'unknown'} · ${domain?.label || '일반'} 등급 ${level}`
      + (withheld.length ? ` · 제외 ${withheld.join(',')}` : ''),
  };
}

// 권한으로 빠진 근거는 빈 값이 아니라 이 문구로 채운다. 모델이 "확인했지만 없었다"로
// 오해하지 않도록 조회하지 않았다는 사실을 명시한다.
export function withheldNote(kind, access) {
  return `[${kind}] withheld — 요청자 권한 등급 ${access.level}(${access.domainLabel})에서는 이 근거를 조회하지 않는다`;
}

// ── 1.5) glossary — 같은 대상을 부르는 다른 이름 ─────────────────────────────
//
// 2026-08-29 사고의 진짜 원인은 문서를 안 읽은 것이 아니었다. "Bolor Geo SG" 서류는
// 있는데 "MPC SG" 서류가 없다고 서로 이야기했고, 둘이 같은 법인이라는 사실을 양쪽
// 다 그 자리에서 떠올리지 못했다. 이 종류의 혼선은 스레드에도 Jira에도 공개 웹에도
// 없다 — 조직이 확정해 둔 이름 대응표에만 있다. 그래서 별도 레이어로 둔다.
//
// 특히 값이 큰 경우: 한 메시지 안에 같은 대상의 서로 다른 이름이 함께 나오고,
// 그것을 대비(A는 있는데 B는 없다)로 쓰고 있을 때. 그때는 답의 첫머리에서 "그 둘은
// 같은 대상" 이라고 먼저 정정해야 뒤의 모든 판단이 어긋나지 않는다.
function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function aliasHits(haystack, names) {
  const hits = [];
  for (const n of names) {
    if (!n) continue;
    // 영문은 단어 경계로, 한글은 경계 개념이 없어 부분일치로 본다.
    const re = /^[\x20-\x7f]+$/.test(n)
      ? new RegExp(`(?<![A-Za-z0-9])${escapeRe(n).replace(/\s+/g, '\\s+')}(?![A-Za-z0-9])`, 'i')
      : new RegExp(escapeRe(n).replace(/\s+/g, '\\s*'), 'i');
    if (re.test(haystack)) hits.push(n);
  }
  // "Bolor Geo SG" 하나가 적혔을 뿐인데 별칭 "Bolor Geo" 도 같이 걸린다. 그대로
  // 두면 이름 하나를 두 이름으로 세어 "지금 두 이름을 섞어 쓰고 있다"고 오판한다.
  return hits.filter((h) => !hits.some((o) => o !== h && o.toLowerCase().includes(h.toLowerCase())));
}

export function glossaryContext({ text = '', ctx = '', level = 9, files = [], messageOnly = true } = {}) {
  let terms = [];
  for (const f of files) {
    const obj = readJson(f);
    if (Array.isArray(obj?.terms)) terms = [...terms, ...obj.terms];
  }
  if (!terms.length) return '[용어집] 등록된 이름 대응이 없음';
  // 메시지를 먼저 본다 — 지금 이 문장 안에서 두 이름이 대비되고 있는지가 핵심이다.
  const msg = String(text || '');
  const all = `${msg}\n${ctx}`;
  const rows = [];
  for (const t of terms) {
    if (Number(t?.minLevel ?? 1) > level) continue;
    const names = [t.canonical, ...(t.aliases || [])].filter(Boolean);
    const inMsg = aliasHits(msg, names);
    // 2026-08-31 사고: 이 메시지에는 없고 채널 컨텍스트에만 있던 이름이 걸렸다.
    // Piyush 의 MatchHire DM 에 "Naming: Bolor Geo SG Pte. Ltd." 가 붙어 나갔는데,
    // 그 이름은 사흘 전 같은 DM 에 라이언이 붙여 넣은 전혀 다른 프로젝트 이야기에만
    // 있었다. 용어집은 "지금 이 메시지가 같은 대상을 두 이름으로 쓰고 있을 때"
    // 그것부터 바로잡는 층이다 — 이 파일 위쪽 주석이 적어 둔 그 용도다. 그래서
    // 기본값은 메시지 안의 일치만 인정한다. 컨텍스트까지 보려면 messageOnly:false 로
    // 부르는 쪽이 그 선택을 명시해야 한다.
    const hits = inMsg.length ? inMsg : (messageOnly ? [] : aliasHits(all, names));
    if (!hits.length) continue;
    const conflicting = inMsg.length >= 2;
    // 별칭을 한 줄에 `A = B = C = …` 로 늘어놓으면 모델이 그 줄을 통째로 베껴서
    // "A, B, C, D, E, F 는 같은 대상입니다" 같은 답이 나간다 (2026-08-30 재실행에서
    // 확인). 그래서 이 대화에 실제로 나온 이름만 따로 앞세우고, 나머지 별칭은
    // 참고용이라고 못 박아 뒤로 뺀다.
    const used = hits.length ? hits : names.slice(0, 2);
    const rest = names.filter((n) => !used.includes(n));
    const row = [`- 정본: ${t.canonical} — 아래 이름은 모두 같은 대상이다.`,
      `  이 대화에 나온 이름: ${used.map((n) => `"${n}"`).join(', ')} ← 답에는 이 이름만 쓴다`];
    if (conflicting) {
      row.push('  ※ 지금 이 메시지가 이 둘을 서로 다른 것처럼 쓰고 있다. 같은 대상임을 먼저 바로잡아야 한다.');
    }
    if (rest.length) row.push(`  다른 별칭(참고용 — 답에 나열하지 말 것): ${rest.join(', ')}`);
    if (t.note) row.push(`  설명: ${t.note}`);
    rows.push(row.join('\n'));
    if (rows.length >= 4) break;
  }
  if (!rows.length) return '[용어집] 이 대화에 해당하는 이름 대응 없음';
  return `[용어집 · 조직이 확정한 이름 대응]\n${rows.join('\n')}`;
}

// 용어집의 정본은 노션의 프로덕트 페이지다. 이름은 계속 늘고 바뀌는데 레포 안의
// JSON 을 정본으로 두면 이름 하나 추가할 때마다 빌드를 해야 하고, 그러면 아무도
// 추가하지 않는다 — 이름 혼동이 처음 생긴 이유가 바로 그것이다(적어 둘 곳이 없었다).
// 그래서 사람은 노션에 쓰고, 데몬이 주기적으로 내려받아 운영 파일에 캐시한다.
// 번들 JSON 은 토큰이 없거나 노션이 죽었을 때의 씨앗으로만 남는다.
//
// 노션 페이지에서 읽는 줄의 모양 (불릿 하나가 용어 하나):
//   정본이름 = 별칭 = 별칭 — 설명문 (level 3)
// `=` 로 이름을 늘어놓고, `—` 뒤가 설명이다. 등급은 생략하면 1(누구나)이다.
const GLOSSARY_LINE_SEP = /\s+[—–]\s+|\s+--\s+/;

export function parseGlossaryLines(lines) {
  const terms = [];
  for (const raw of lines) {
    const line = String(raw || '').replace(/^[-*•\s]+/, '').trim();
    if (!line || !line.includes('=')) continue;
    const [namePart, ...noteParts] = line.split(GLOSSARY_LINE_SEP);
    let note = noteParts.join(' — ').trim();
    let minLevel = 1;
    const lv = note.match(/\(\s*(?:level|레벨)\s*(\d+)\s*\)\s*$/i);
    if (lv) { minLevel = Number(lv[1]); note = note.slice(0, lv.index).trim(); }
    const names = namePart.split('=').map((x) => x.trim()).filter(Boolean);
    if (names.length < 2) continue;   // 이름이 하나뿐이면 대응표가 아니다
    terms.push({ canonical: names[0], aliases: names.slice(1), note, minLevel });
  }
  return terms;
}

// 노션 페이지 하나를 읽어 용어집 JSON 으로 만들어 저장한다. 실패하면 기존 캐시를
// 건드리지 않는다 — 노션이 잠깐 죽었다고 어제까지 알던 이름 대응이 사라지면 안 된다.
export async function syncGlossaryFromNotion({ token, page, outFile, timeoutMs = 8000 } = {}) {
  if (!token) return { ok: false, error: '노션 통합 토큰 없음' };
  if (!page) return { ok: false, error: '용어집 노션 페이지가 지정되지 않음' };
  const id = notionPageRefs(page)[0]?.id || (/^[0-9a-f-]{32,36}$/i.test(String(page).trim()) ? dashed(String(page).trim()) : null);
  if (!id) return { ok: false, error: `페이지 주소에서 id 를 못 읽음: ${String(page).slice(0, 60)}` };
  let lines = [];
  try {
    const top = await notionApi(`blocks/${id}/children?page_size=100`, token, timeoutMs);
    const out = [];
    blockLines(top.results, 0, out, 20_000);
    // 토글·열 안에 적는 사람이 있다. 한 단계만 더 편다 (읽기 경로와 같은 규칙).
    for (const k of (top.results || []).filter((b) => b?.has_children && b.type !== 'child_page').slice(0, 8)) {
      try {
        const sub = await notionApi(`blocks/${k.id}/children?page_size=60`, token, timeoutMs);
        blockLines(sub.results, 0, out, 20_000);
      } catch { /* 하위 하나 실패는 무시 */ }
    }
    lines = out;
  } catch (e) {
    return { ok: false, error: e.status === 404 || e.status === 403
      ? '페이지에 통합(Integration)이 연결돼 있지 않음'
      : `조회 실패 (${e.status ? `HTTP ${e.status}` : String(e?.message || e).slice(0, 60)})` };
  }
  const terms = parseGlossaryLines(lines);
  // 0건 저장은 금지다. 사람이 페이지 형식을 잠깐 흐트러뜨린 순간 용어집이 통째로
  // 비는 것이 이 동기화에서 가장 나쁜 실패다.
  if (!terms.length) return { ok: false, error: '페이지에서 읽어낸 용어가 0건 — 기존 캐시를 유지한다' };
  const body = { version: 1, syncedAt: new Date().toISOString(), source: String(page), terms };
  try {
    const prev = readFileSync(outFile, 'utf8');
    if (JSON.parse(prev)?.terms && JSON.stringify(JSON.parse(prev).terms) === JSON.stringify(terms)) {
      return { ok: true, count: terms.length, changed: false };
    }
  } catch { /* 캐시가 없거나 깨졌으면 그냥 쓴다 */ }
  try {
    writeFileSync(`${outFile}.tmp`, `${JSON.stringify(body, null, 2)}\n`);
    renameSync(`${outFile}.tmp`, outFile);
  } catch (e) {
    return { ok: false, error: `저장 실패 — ${String(e?.message || e).slice(0, 60)}` };
  }
  return { ok: true, count: terms.length, changed: true };
}

// ── 2) notion — 스레드에 공유된 문서 ─────────────────────────────────────────

const NOTION_URL_RE = /https?:\/\/(?:[a-z0-9-]+\.)*notion\.(?:so|com)\/[^\s<>|)"'\]]+/gi;
const HEX32_RE = /[0-9a-f]{32}/gi;
const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

function dashed(id) {
  const h = String(id).replace(/-/g, '');
  if (h.length !== 32) return String(id);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// 노션 URL 은 제목-해시 꼴이라 페이지 id 가 경로 끝에 붙는다. 쿼리스트링에도
// 32자리 hex 가 들어올 수 있으므로(예: ?p=…) 쿼리를 먼저 떼고 마지막 것을 쓴다.
export function notionPageRefs(text) {
  const out = [];
  const seen = new Set();
  for (const m of String(text || '').matchAll(NOTION_URL_RE)) {
    const url = m[0].replace(/[),.;:!?'"]+$/, '');
    const path = url.split(/[?#]/)[0];
    const uuid = path.match(UUID_RE)?.[0];
    const hex = path.match(HEX32_RE);
    const id = uuid || (hex && hex[hex.length - 1]);
    if (!id) continue;
    const key = dashed(id);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ url, id: key });
    if (out.length >= 3) break;
  }
  return out;
}

async function notionApi(path, token, timeoutMs) {
  const res = await fetch(`https://api.notion.com/v1/${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Notion-Version': '2022-06-28',
      Accept: 'application/json',
    },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) {
    const err = new Error(`HTTP ${res.status}`);
    err.status = res.status;
    throw err;
  }
  return res.json();
}

function richText(node) {
  if (!Array.isArray(node)) return '';
  return node.map((r) => r?.plain_text || '').join('');
}

// 블록을 사람이 읽는 줄로 편다. 하위 문서(child_page)는 본문 대신 제목만 싣는다 —
// "이 문서 아래 무엇이 더 있는가" 가 서류 충분성 판단의 핵심이라 제목만으로도 값이 있고,
// 전부 펼치면 프롬프트가 터진다.
function blockLines(blocks, depth, out, cap) {
  for (const b of blocks || []) {
    if (out.join('\n').length > cap) return out;
    const t = b?.type;
    if (!t) continue;
    const pad = '  '.repeat(depth);
    if (t === 'child_page') { out.push(`${pad}- [하위 문서] ${b.child_page?.title || '(제목 없음)'}`); continue; }
    if (t === 'child_database') { out.push(`${pad}- [하위 데이터베이스] ${b.child_database?.title || '(제목 없음)'}`); continue; }
    if (t === 'file' || t === 'pdf' || t === 'image') {
      const name = richText(b[t]?.caption) || b[t]?.name || b[t]?.external?.url || '(첨부)';
      out.push(`${pad}- [첨부파일] ${name}`);
      continue;
    }
    const text = richText(b[t]?.rich_text);
    if (!text.trim()) continue;
    const mark = t === 'to_do' ? (b.to_do?.checked ? '[x] ' : '[ ] ') : '';
    out.push(`${pad}${t.startsWith('heading') ? '## ' : '- '}${mark}${text}`);
  }
  return out;
}

async function pageText({ id, token, timeoutMs, cap }) {
  let title = '';
  try {
    const page = await notionApi(`pages/${id}`, token, timeoutMs);
    const props = page?.properties || {};
    const titleProp = Object.values(props).find((p) => p?.type === 'title');
    title = richText(titleProp?.title) || '';
  } catch (e) {
    if (e.status === 404 || e.status === 403) {
      return { error: '접근 권한 없음 — 노션에서 해당 페이지에 통합(Integration)을 연결해야 읽을 수 있다' };
    }
    // 데이터베이스 id 일 수도 있다. 본문 조회로 계속 간다.
  }
  const lines = [];
  try {
    const top = await notionApi(`blocks/${id}/children?page_size=80`, token, timeoutMs);
    blockLines(top.results, 0, lines, cap);
    // 한 단계만 더 편다. 토글/열/목록 안에 본문이 들어 있는 문서가 흔하다.
    const kids = (top.results || []).filter((b) => b?.has_children && b.type !== 'child_page' && b.type !== 'child_database').slice(0, 6);
    for (const k of kids) {
      if (lines.join('\n').length > cap) break;
      try {
        const sub = await notionApi(`blocks/${k.id}/children?page_size=40`, token, timeoutMs);
        blockLines(sub.results, 1, lines, cap);
      } catch { /* 하위 하나 실패는 무시 */ }
    }
  } catch (e) {
    if (e.status === 404 || e.status === 403) {
      return { error: '접근 권한 없음 — 노션에서 해당 페이지에 통합(Integration)을 연결해야 읽을 수 있다' };
    }
    return { error: `조회 실패 (${e.status ? `HTTP ${e.status}` : String(e?.name === 'TimeoutError' ? '타임아웃' : e?.message || e).slice(0, 80)})` };
  }
  return { title, body: clip(lines.join('\n'), cap) };
}

// 스레드(메시지 + 앞선 대화)에 공유된 노션 페이지를 실제로 읽어 온다.
// 반환은 항상 문자열 — 못 읽었으면 왜 못 읽었는지가 그 자리에 남는다.
export async function notionContext({ text = '', ctx = '', token = null, timeoutMs = 6000, cap = 4000 } = {}) {
  const refs = notionPageRefs(`${text}\n${ctx}`);
  if (!refs.length) return '[Notion lookup] 스레드에 공유된 노션 링크가 없음';
  if (!token) {
    return `[Notion lookup] unavailable — 노션 통합 토큰이 없음 (대시보드 연동 > Notion 통합 토큰 등록 필요). 스레드에 공유된 링크: ${refs.map((r) => r.url).join(' ')}`;
  }
  const per = Math.max(1500, Math.floor(cap / refs.length));
  const parts = [];
  for (const ref of refs) {
    const r = await pageText({ id: ref.id, token, timeoutMs, cap: per }).catch((e) => ({ error: String(e?.message || e).slice(0, 80) }));
    if (r.error) { parts.push(`[Notion 문서 · 스레드에 공유됨] ${ref.url}\n(읽지 못함: ${r.error})`); continue; }
    parts.push(`[Notion 문서 · 스레드에 공유됨] "${r.title || '(제목 없음)'}" ${ref.url}\n${r.body || '(본문이 비어 있음)'}`);
  }
  return parts.join('\n\n');
}

// ── 3) research — 이 일에 원래 무엇이 필요한가 (공개 웹) ─────────────────────

// 검색어는 밖으로 나간다. 회사 내부 고유명사·사람 이름·URL·숫자 나열을 그대로
// 실어 보내지 않도록 모델에게 "일반화된 질의"를 만들게 하고, 그마저 실패하면
// 검색 자체를 건너뛴다 (내부 문장을 그대로 검색창에 넣는 폴백은 두지 않는다).
const QUERY_PROMPT = [
  '아래 Slack 메시지가 요구하는 일을 실제로 처리하려면 무엇이 필요한지 알아보려 한다.',
  '공개 웹에서 그 요건을 찾을 영어 검색어 한 줄만 출력하라.',
  '- 회사명, 사람 이름, 내부 코드명, URL, 계좌·토큰 같은 식별자는 절대 넣지 마라.',
  '- 일반적인 절차·요건을 찾는 질의로 일반화하라 (예: 특정 회사 대신 "corporate bank account in Singapore").',
  '- 이 메시지가 외부 요건 조사와 무관하면 NONE 한 단어만 출력하라.',
  '- 설명, 따옴표, 접두어 없이 질의 문자열만 출력하라.',
].join('\n');

// launchd 로 뜬 데몬의 PATH 에는 ~/.local/bin 이 없다. 이름만 넘기면 조용히
// "실행 파일 없음" 이 되고 리서치 레이어가 통째로 사라지므로 절대경로를 찾아 쓴다.
const GSK_CANDIDATES = [
  join(homedir(), '.local', 'bin', 'gsk'), '/opt/homebrew/bin/gsk', '/usr/local/bin/gsk', '/usr/bin/gsk',
];
function resolveGsk(hint) {
  if (hint && hint.includes('/') && existsSync(hint)) return hint;
  return GSK_CANDIDATES.find((p) => existsSync(p)) || null;
}

function runGsk(gskPath, args, timeoutMs) {
  return new Promise((resolve) => {
    execFile(gskPath, args, { timeout: timeoutMs, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 },
      (err, stdout) => resolve({ ok: !err, stdout: String(stdout || ''), err }));
  });
}

export async function researchContext({ text = '', ctx = '', ask = null, gskPath = null, timeoutMs = 12000, cap = 1400, log = () => {} } = {}) {
  if (typeof ask !== 'function') return '[Web research] unavailable — 질의 생성기가 없음';
  const gsk = resolveGsk(gskPath);
  if (!gsk) return '[Web research] unavailable — gsk CLI 를 찾지 못함';
  let query = '';
  try {
    const r = await ask([QUERY_PROMPT, '', '<message>', clip(text, 1200), '</message>',
      '', '<context>', clip(ctx, 800), '</context>'].join('\n'));
    query = String(r || '').trim().split('\n')[0].replace(/^["'`]|["'`]$/g, '').slice(0, 160);
  } catch (e) {
    log?.('research query 생성 실패:', String(e?.message || e).slice(0, 80));
  }
  if (!query || /^none$/i.test(query)) return '[Web research] 외부 요건 조사가 필요한 요청이 아님';
  const r = await runGsk(gsk, ['search', query, '--output', 'json', '--timeout', String(timeoutMs)], timeoutMs + 4000);
  if (!r.ok) return `[Web research · genspark] 검색 실패 (질의: ${query})`;
  const i = r.stdout.indexOf('{');
  if (i < 0) return `[Web research · genspark] 응답에 JSON 없음 (질의: ${query})`;
  let json;
  try { json = JSON.parse(r.stdout.slice(i)); } catch { return `[Web research · genspark] 응답 파싱 실패 (질의: ${query})`; }
  if (json?.status === 'error') return `[Web research · genspark] ${String(json.message || 'unknown').split('\n')[0].slice(0, 120)}`;
  const rows = (json?.data?.organic_results || []).slice(0, 5)
    .map((x) => `- ${String(x.title || '').trim()} — ${String(x.snippet || '').replace(/\s+/g, ' ').trim()} — ${String(x.link || x.url || '').trim()}`)
    .filter((s) => s.length > 6);
  if (!rows.length) return `[Web research · genspark] 결과 없음 (질의: ${query})`;
  return clip(`[Web research · genspark · 공개 웹 자료이며 우리 회사의 확정 사실이 아님]\n질의: ${query}\n${rows.join('\n')}`, cap);
}

// ── 4) related — 다른 스레드 ─────────────────────────────────────────────────

const SEARCH_STOP = new Set(['this', 'that', 'with', 'from', 'have', 'will', 'your', 'about', 'into',
  'what', 'when', 'where', 'which', 'then', 'they', 'them', 'some', 'more', 'please', 'thanks',
  'thank', 'sharing', 'share', 'shared', 'reason', 'would', 'could', 'should', 'there', 'here',
  'need', 'want', 'know', 'make', 'take', 'like', 'much', 'many', 'also', 'else', 'been', 'does',
  '그리고', '대한', '위한', '있는', '하는', '합니다', '내용', '확인', '관련', '감사합니다', '있나요', '주세요']);

// 다른 스레드를 찾을 때 값이 있는 것은 고유명사다. MPC·SG·KYC 같은 약어는 세 글자
// 이하라 일반 단어 규칙(4자 이상)에 걸려 통째로 빠졌었다 — 정작 그 약어가 스레드를
// 특정하는 유일한 단어다. 그래서 약어 > 고유명사 > 나머지 순으로 고른다.
export function searchTerms(text, max = 4) {
  const cleaned = String(text || '')
    .replace(/https?:\/\/\S+/g, ' ').replace(/<[^>]+>/g, ' ');
  const acronyms = (cleaned.match(/\b[A-Z]{2,6}\b/g) || []);
  const proper = (cleaned.match(/\b[A-Z][a-z]{2,}\b/g) || []);
  const rest = (cleaned.match(/[A-Za-z][A-Za-z0-9_-]{3,}|[가-힣]{2,}/g) || []);
  const out = [];
  const seen = new Set();
  for (const w of [...acronyms, ...proper, ...rest]) {
    const k = w.toLowerCase();
    if (seen.has(k) || SEARCH_STOP.has(k)) continue;
    seen.add(k);
    out.push(w);
    if (out.length >= max) break;
  }
  return out;
}

// slack 은 데몬의 호출기를 그대로 받는다 (이 모듈은 토큰을 모른다).
// search.messages 는 user token 의 search:read 스코프를 요구한다 — 없으면 그 사실이
// 문자열로 돌아가고, 선응답은 나머지 근거로 계속 만들어진다.
export async function relatedThreadContext({ text = '', slack = null, channel = '', threadTs = '', ts = '', cap = 1200, log = () => {} } = {}) {
  if (typeof slack !== 'function') return '[Slack 다른 스레드] unavailable — 검색기를 받지 못함';
  const terms = searchTerms(text);
  if (terms.length < 2) return '[Slack 다른 스레드] 검색할 만한 고유 단어가 부족함';
  let res;
  try {
    res = await slack('search.messages', { query: terms.join(' '), count: 10, sort: 'score' });
  } catch (e) {
    const msg = String(e?.message || e);
    if (/missing_scope|not_allowed_token_type/.test(msg)) {
      return '[Slack 다른 스레드] unavailable — user token 에 search:read 권한이 없음';
    }
    log?.('related thread 검색 실패:', msg.slice(0, 100));
    return `[Slack 다른 스레드] 검색 실패 — ${msg.slice(0, 80)}`;
  }
  const here = String(threadTs || ts || '');
  const rows = [];
  for (const m of res?.messages?.matches || []) {
    // 지금 이 스레드/이 메시지는 이미 <context> 에 있다. 다시 실으면 근거가 중복되고
    // 모델이 "여러 곳에서 확인됨" 으로 잘못 읽는다.
    if (m?.channel?.id === channel && (m.ts === here || String(m.permalink || '').includes(here))) continue;
    const body = String(m.text || '').replace(/\s+/g, ' ').trim();
    if (!body) continue;
    rows.push(`[다른 스레드 · #${m?.channel?.name || m?.channel?.id || '?'}] ${m?.username || m?.user || '?'}: ${clip(body, 220)}${m.permalink ? ` (${m.permalink})` : ''}`);
    if (rows.length >= 4) break;
  }
  if (!rows.length) return `[Slack 다른 스레드] 관련 내용 없음 (검색어: ${terms.join(' ')})`;
  return clip(`[Slack 다른 스레드 · 검색어 ${terms.join(' ')}]\n${rows.join('\n')}`, cap);
}

export default { resolveAccess, withheldNote, glossaryContext, parseGlossaryLines, syncGlossaryFromNotion, notionContext, notionPageRefs, researchContext, relatedThreadContext, searchTerms };
