// emoji-layer.mjs — 선응답이 "글 대신 리액션 하나"로 끝내도 되는 자리를 판정한다.
//
// 왜 생겼나 (2026-08-29 실제 사고): 스레드에서 상대가 "Understood, thank you. I'll
// proceed with the required actions accordingly." 라고 닫는 말을 했는데, 선응답이
// 여기에 대고 "Cannot answer / Reason: Insufficient context / Needed: Share the
// reason and recommendation…" 3줄을 붙였다. 컨텍스트가 부족한 게 아니었다.
// 답할 것이 없는 메시지였다. 사람은 이런 자리에 이모지 하나를 단다.
//
// 2026-08-31 두 번째 사고: "Hi everyone, See you all at tea break soon." 라는
// 티타임 공지(5명 단체 멘션)에 "Answer: Inform team members about the upcoming
// tea break." 가 나갔다. 원문의 재진술이다. 이 레이어는 통과시켰는데, 통과시킨
// 이유가 "글로 답할 이유가 있어서"가 아니라 "어휘집 정규식에 안 걸려서"였다.
// 어휘집은 닫는 말(understood/thanks/진행하겠습니다)의 화이트리스트라, 닫는 말도
// 아니고 묻는 말도 아닌 메시지는 전부 글로 떨어진다. 축이 거꾸로였다 — 어휘집은
// "어느 이모지를 달지"를 정하는 자리이지 "글이냐 이모지냐"를 정하는 자리가 아니다.
// 그 질문에는 veto 가 이미 답하고 있다(묻는다·요청한다·막혀 있다).
// 그래서 단체 멘션에 한해 기본값을 뒤집었다 — isGroupAddress 와 quickVerdict 의
// group 분기를 보라. 나에게 직접 온 1:1 멘션은 예전 그대로 글이 기본이다.
//
// 그래서 이 레이어가 하는 일은 딱 둘이다.
//   1) 글을 만들기 전에 — 닫는 말이 분명하면 모델을 부르지 않고 이모지로 끝낸다.
//      (레이어 예산 20초와 모델 호출 서너 번이 통째로 절약된다.)
//   2) 글을 만든 뒤 "분석 불가"가 나왔을 때 — 그것을 그대로 내보내기 전에
//      스레드를 다시 보고 이모지로 끝낼 자리인지 모델에게 한 번 묻는다.
//      이모지도 아니라고 하면 그때만 "답변 불가" 3줄이 나간다.
//
// 이모지의 뜻은 표준이 없다. 팀마다 다르고, 잘못 달면 글보다 더 크게 어긋난다
// (✅ 는 "동의한다"가 아니라 "체크만 했다"이고, 🫡 는 👍 보다 강하다). 그래서 뜻은
// 코드가 아니라 slack-emoji-layer.json 에 적어 두고 그 파일을 정본으로 삼는다.
// 프롬프트에 실리는 설명과 결정적 판정에 쓰이는 정규식이 같은 파일에서 나온다 —
// 둘이 갈라지면 "판정은 A인데 모델에게는 B라고 설명하는" 상태가 된다.
//
// answer-context.mjs 와 같은 규칙: 키체인을 열지 않고, 슬랙을 부르지 않고,
// 어떤 함수도 예외를 밖으로 내지 않는다. 판정이 안 서면 null 을 돌려주고,
// null 은 언제나 "글로 답하라"는 뜻이다 (모르면 조용해지는 쪽이 아니라 원래
// 하던 대로 하는 쪽으로 넘어간다).

import { readFileSync } from 'node:fs';

// ── 어휘집 ───────────────────────────────────────────────────────────────────

const FALLBACK_CATALOG = {
  version: 0,
  veto: { maxChars: 240, patterns: ['[?？]'] },
  // 파일을 못 읽어도 최소한의 뜻 하나는 남는다 — 어휘집이 통째로 비면 이 레이어가
  // 조용히 사라지고, 그러면 "Cannot answer" 사고가 그대로 돌아온다.
  emojis: [{
    name: 'white_check_mark', char: '✅', label: '확인만 함',
    means: '체크는 했다는 뜻. 납득도 동의도 응원도 아니다.',
    use: '상대가 알렸고 내가 읽었다는 사실만 남기면 되는 자리.',
    auto: true,
    level0: true,
    match: '\\b(understood|noted|acknowledged|got it|thank you|thanks)\\b|(확인했습니다|알겠습니다|감사합니다)',
  }],
};

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}

// 번들 어휘집 + 운영 어휘집을 이 순서로 덮어쓴다. emojis 는 병합하지 않고 통째로
// 교체한다 — 이모지 목록을 부분 병합하면 "지웠는데 아직 달리는" 항목이 생긴다.
export function loadCatalog(files = []) {
  let cat = FALLBACK_CATALOG;
  for (const f of files) {
    const obj = readJson(f);
    if (!Array.isArray(obj?.emojis) || !obj.emojis.length) continue;
    cat = { ...cat, ...obj, veto: { ...cat.veto, ...(obj.veto || {}) } };
  }
  return cat;
}

// 자동으로 달아도 되는 항목만. name 은 슬랙 리액션 이름(콜론 없이)이다.
export function autoEmojis(catalog) {
  return (catalog?.emojis || []).filter((e) => e?.auto && e?.name);
}

// L0는 승인·동의 판단이 아니다. 메시지를 읽었다는 확인 또는 상대가 이미 이해하고
// 실행하겠다고 닫은 말을 인지하는 리액션만 허용한다. 나머지는 auto=true 여도
// 텍스트 응답 레벨(L1~L4)로 넘긴다.
export function levelZeroEmojis(catalog) {
  return autoEmojis(catalog).filter((e) => e?.level0 === true);
}

// ── 보는 중 이모지 ───────────────────────────────────────────────────────────
//
// 이름은 어휘집의 pendingEmoji 한 줄에서만 온다. 코드에 박지 않는 이유는 이 선택이
// 아직 확정이 아니기 때문이다 — 2026-09-02 배치는 🔍(mag) 로 정했지만, 뜻이 같은
// 다른 이모지로 바뀔 수 있고 그때 앱을 다시 빌드해야 한다면 아무도 안 고친다.
// 이 파일이 이모지 뜻의 정본이라는 위 규칙(:27-31)이 새 축에도 그대로 적용된다.
export function pendingEmojiRow(catalog) {
  const name = String(catalog?.pendingEmoji || '').trim();
  if (!name) return null;
  return (catalog?.emojis || []).find((e) => e?.name === name && e?.auto) || null;
}

// 달려 있어도 그 항목을 처리완료로 만들지 않는 이름들. 데몬의 resolvingReaction ·
// firstNonTrigger 가 이 목록을 건너뛴다. 여기서 내보내는 이유는 하나다 — 같은
// 지식을 데몬에도 적으면 두 곳이 갈라지고, 갈라지면 🔍 를 달자마자 의사결정이
// 필요한 항목이 미처리에서 사라진다(2026-09-02 사고의 세 번째 해악).
export function nonResolvingEmojis(catalog) {
  return (catalog?.emojis || [])
    .filter((e) => e?.resolves === false && e?.name)
    .map((e) => String(e.name));
}

// 모델에게 보여 줄 어휘집. 뜻과 쓰는 자리를 그대로 싣는다 — 이모지 이름만 주면
// 모델이 자기가 아는 일반적인 뜻(✅ = 동의)으로 읽어 버린다.
export function catalogText(catalog) {
  const rows = levelZeroEmojis(catalog).map((e) =>
    `- ${e.name} (${e.char || ''}) · ${e.label || ''} — ${e.means || ''} 쓰는 자리: ${e.use || ''}`);
  return rows.length ? rows.join('\n') : '(자동으로 달 수 있는 이모지가 없음)';
}

// ── 메시지 정규화 ────────────────────────────────────────────────────────────
//
// 슬랙 원문에는 <@U…> 멘션, <http…|라벨> 링크, 그리고 "Cc: @A @B" 처럼 사람만
// 나열한 줄이 섞여 있다. 이것들을 그대로 두면 길이 상한에 걸리고, 멘션 안의
// 사람 이름이 veto 정규식(예: "why")에 우연히 걸린다.
export function normalizeText(text) {
  return String(text || '')
    .replace(/<@[UWB][A-Z0-9]*(\|[^>]*)?>/g, ' ')       // 사람 멘션
    .replace(/<#C[A-Z0-9]*(\|[^>]*)?>/g, ' ')            // 채널
    .replace(/<!(here|channel|everyone)>/g, ' ')         // @here 류
    .replace(/<(https?:[^>|]+)(\|[^>]*)?>/g, ' ')        // 링크
    .replace(/https?:\/\/\S+/g, ' ')                     // 맨 URL
    .replace(/^\s*(cc|참조)\s*[:：].*$/gim, ' ')          // Cc: 줄 통째로
    .replace(/:[a-z0-9_+-]+:/g, ' ')                     // :emoji: 코드
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{2,}/g, '\n')
    .trim();
}

// ── 누구에게 온 메시지인가 ───────────────────────────────────────────────────
//
// 슬랙 멘션은 두 모양으로 들어온다. 실시간 이벤트의 원문은 <@U…> 마크업이지만,
// 수집된 item.textEn 은 이미 사람이 읽는 평문 "@Lion cho (조중현,…)" 이다.
// 둘 다 세지 않으면 같은 메시지가 경로에 따라 다르게 판정된다.
const SLACK_MENTION_RE = /<@[UWB][A-Z0-9]*(?:\|[^>]*)?>/g;
const PLAIN_MENTION_RE = /(?:^|\s)@(?=\S)/g;
const BROADCAST_RE = /<!(?:here|channel|everyone)>|<!subteam\^[A-Z0-9]+(?:\|[^>]*)?>/i;

export function mentionCount(text) {
  const t = String(text || '');
  return (t.match(SLACK_MENTION_RE) || []).length + (t.match(PLAIN_MENTION_RE) || []).length;
}

// 단체로 온 것인가. @here·@channel·유저그룹이거나, 사람을 셋 이상 한 번에 부른 것.
// 셋인 이유는 둘까지는 "너와 나" 대화일 수 있어서다 — 셋부터는 특정인에게 답을
// 요구하는 자리가 아니라 알리는 자리로 본다.
export function isGroupAddress(text, source = '') {
  if (['team', 'broadcast'].includes(String(source || ''))) return true;
  const t = String(text || '');
  if (BROADCAST_RE.test(t)) return true;
  return mentionCount(t) >= 3;
}

// 사람만 나열한 줄(“teamSync: @A @B @C”)은 내용이 아니라 수신자 명단이다. 길이
// 상한에만 이것을 걷어낸 값을 쓴다 — 패턴 veto 는 원문 그대로 본다. 명단을 지우다
// 물음·요청 문장을 같이 지우면 답을 기다리는 사람에게 이모지가 나간다.
// 이번 티타임 메시지는 명단 때문에 정규화 후 205자였다. 상한 240자를 우연히 넘지
// 않았을 뿐, 사람이 두 명만 더 있었으면 "짧은 인사"가 길이로 막혔을 것이다.
// 지우는 조건이 둘인 이유: 멘션이 둘 이상이라는 것만으로는 명단이 아니다.
// "@A @B can you check this?" 도 멘션이 둘이다. 그 줄을 지우면 물음이 사라지고,
// 물음이 사라지면 답을 기다리는 사람에게 이모지가 나간다 — 이 레이어가 낼 수 있는
// 가장 큰 사고다. 그래서 물음·요청 신호가 없는 줄만 명단으로 본다.
export function withoutRosterLines(text, catalog = null) {
  const cat = catalog || FALLBACK_CATALOG;
  return String(text || '')
    .split('\n')
    .filter((line) => mentionCount(line) < 2 || patternVeto(line, cat) !== null)
    .join('\n');
}

// ── veto — 이모지로 끝내면 안 되는 자리 ──────────────────────────────────────
//
// 이모지가 틀리는 방식은 두 가지고 무게가 다르다. 뜻이 조금 어긋나는 것은 작고,
// 답을 기다리는 사람에게 이모지만 다는 것은 크다 — 그건 무시로 읽힌다. 그래서
// 판정은 한쪽으로 기울여 둔다: 조금이라도 물음·요청·문제 신호가 있으면 글이다.
// 패턴만 본다. 길이는 보지 않는다 — 길이 판정이 명단 제거를 부르고 명단 제거가 다시
// 패턴 판정을 부르므로, 둘을 갈라 두지 않으면 서로를 부르며 돈다.
export function patternVeto(text, catalog) {
  const t = normalizeText(text);
  for (const p of catalog?.veto?.patterns || []) {
    let re;
    try { re = new RegExp(p, 'i'); } catch { continue; }
    const m = t.match(re);
    if (m) return `물음·요청 신호("${String(m[0]).slice(0, 30)}")`;
  }
  return null;
}

export function vetoReason(text, catalog) {
  const cat = catalog || FALLBACK_CATALOG;
  const max = Number(cat?.veto?.maxChars || 240);
  // 길이는 수신자 명단을 뺀 본문으로 잰다. 명단은 내용이 아니라 수신자다.
  const body = normalizeText(withoutRosterLines(text, cat));
  if (body.length > max) return `길다(${body.length}자 > ${max})`;
  // 패턴은 원문 그대로 본다. 지운 줄에 신호가 있었을 가능성을 남기지 않는다.
  return patternVeto(text, cat);
}

// ── 1) 결정적 판정 — 모델 없이 ───────────────────────────────────────────────
//
// 어휘집에 적힌 순서대로 본다. 먼저 적힌 것이 더 좁은 뜻이고(🙇 잘 부탁 → 🙏 기원
// → 👌 승인 → 🫡 존중 → 👍 동의 → ✅ 확인), 마지막 ✅ 가 가장 넓다. 좁은 것부터
// 보지 않으면 "잘 부탁드립니다. 감사합니다." 가 ✅ 로 떨어진다.
//
// 성립 조건은 둘 다다: 어휘집 정규식에 걸릴 것, 그리고 veto 에 안 걸릴 것.
// 하나만으로는 부족하다 — "감사합니다. 그런데 이건 언제 될까요?" 는 앞은 걸리고
// 뒤는 물음이다.
//
// ⚠️ 2026-08-31 이후 이 함수는 **데몬의 경로에 없다.** 데몬이 부르는 것은 아래
// responseGrade 이고, 이것은 그 앞선 판이다. 두 함수는 1:1 멘션에서 판정이 갈린다 —
// 여기서는 null(글)이고 responseGrade 에서는 R1(리액션)이다. 그것이 축을 뒤집은
// 내용 그 자체다. 여기를 고쳐도 나가는 응답은 한 글자도 달라지지 않으므로, 판정을
// 바꾸려면 responseGrade 를 고쳐라. 지우지 않은 이유는 하나뿐이다: 이 함수의 단계별
// 판정(무거운 뜻 먼저, 넓은 뜻 나중)이 responseGrade 의 근거이고, 그 근거를 검사하는
// 시험이 붙어 있다.
export function quickVerdict({ text = '', catalog = null, source = '' } = {}) {
  const cat = catalog || FALLBACK_CATALOG;
  const t = normalizeText(text);
  if (!t) return null;
  const veto = vetoReason(text, cat);
  if (veto) return null;
  // 한 문장에 "잘 부탁드립니다. 감사합니다"처럼 텍스트 판단 신호와 넓은 확인
  // 신호가 함께 있으면 뒤의 감사합니다만 보고 ✅를 달면 안 된다. L0가 아닌 의미가
  // 하나라도 잡히면 전체 메시지를 L1~L4로 넘긴다.
  for (const e of autoEmojis(cat).filter((x) => x?.level0 !== true)) {
    if (!e.match) continue;
    try { if (new RegExp(e.match, 'i').test(t)) return null; } catch {}
  }
  for (const e of levelZeroEmojis(cat)) {
    if (!e.match) continue;
    let re;
    try { re = new RegExp(e.match, 'i'); } catch { continue; }
    const m = t.match(re);
    if (!m) continue;
    return { emoji: e.name, char: e.char || '', kind: 'quick', label: e.label || '',
      reason: `어휘집 일치 "${String(m[0]).slice(0, 24)}" → :${e.name}: (${e.label || ''})` };
  }

  // 여기까지 왔다는 것은 "닫는 말도 아니고 묻는 말도 아니다" 이다. 예전에는 이 자리가
  // 무조건 글이었고, 그래서 티타임 공지에 원문을 재진술한 답이 나갔다.
  //
  // 단체로 온 메시지는 기본값을 뒤집는다. 셋 이상을 한 번에 부르면서 아무것도 묻지
  // 않는 것은 알리는 자리이고, 알리는 자리에서 사람이 하는 것은 리액션 하나다.
  // 나에게 직접 온 1:1 은 뒤집지 않는다 — 거기서 침묵하면 무시로 읽힌다.
  if (!isGroupAddress(text, source)) return null;
  // 비L0 어휘(👌 승인·👍 동의 등)가 걸렸으면 위에서 이미 글로 넘어갔다. 뜻이 무거운
  // 이모지를 단체 자리에 자동으로 다는 것은 이 완화의 범위가 아니다.
  const fallback = levelZeroEmojis(cat).find((e) => e.name === 'white_check_mark')
    || levelZeroEmojis(cat)[0];
  if (!fallback) return null;
  return { emoji: fallback.name, char: fallback.char || '', kind: 'group', label: fallback.label || '',
    reason: `단체 수신(멘션 ${mentionCount(text)}) · 물음·요청 신호 없음 → :${fallback.name}: (${fallback.label || ''})` };
}

// ── 1.5) 축 1 — 응답 등급 R0~R4 ──────────────────────────────────────────────
//
// 2026-08-31 확정 (docs/slack-ack-two-axis-design.md §1·§4). 위의 quickVerdict 는
// "이모지로 끝내도 되는 자리인가"를 물었고, 그래서 판정이 안 서면 null — 즉 글이었다.
// 축이 거꾸로였다. 물어야 할 것은 "이 메시지가 글을 받을 자격이 있는가"이고,
// **바닥값은 R1(리액션 하나)** 이다. 판정이 서지 않으면 R1 이다. 모르면 이모지다.
//
// 그래서 veto 의 뜻도 바뀐다. 예전에는 "글로 보내라"였고 지금은 **"R2 이상 후보"** 다.
// 후보가 된 뒤에도 신규성 게이트(novelty-gate.mjs)를 통과해야 실제로 글이 된다.
// Maryam 건이 옛 구조에서 물음표 하나로 곧장 글이 됐던 자리이고, 새 구조에서는
// 후보에 올랐다가 신규성 게이트에서 떨어진다.
//
// 어휘집은 "어느 이모지를 달지"만 정한다. "글이냐 이모지냐"를 정하는 자리가 아니다.
//
// 위 quickVerdict 의 주석은 1:1 멘션에서는 기본값을 뒤집지 않는다고 적어 두었는데,
// 이 함수는 뒤집는다. 그 주석이 틀렸다는 뜻이 아니라 판정의 축이 달라진 것이다 —
// 1:1 에서 침묵하면 무시로 읽힌다는 지적은 **무응답(R0)** 에 대한 것이고, R1 은
// 무응답이 아니라 리액션이 달리는 응답이다. 사람이 실제로 하는 것이 그것이다.
export const RESPONSE_GRADES = ['R0', 'R1', 'R2', 'R3', 'R4'];

// 강등 대비용 이모지. R2 후보로 올라갔다가 신규성 게이트에서 떨어지는 경로가 있으므로,
// 등급이 무엇이든 "그래서 무엇을 달 것인가"는 언제나 정해져 있어야 한다. 없으면 그
// 메시지에는 아무 응답도 남지 않는다.
function fallbackEmoji(cat) {
  return levelZeroEmojis(cat).find((e) => e.name === 'white_check_mark') || levelZeroEmojis(cat)[0] || null;
}

function matchLevelZero(t, cat) {
  for (const e of levelZeroEmojis(cat)) {
    if (!e.match) continue;
    let re;
    try { re = new RegExp(e.match, 'i'); } catch { continue; }
    const m = t.match(re);
    if (m) return { row: e, hit: String(m[0]).slice(0, 24) };
  }
  return null;
}

// 2026-09-02 현재 이 함수가 고를 수 있는 행은 👌 ok_hand 와 👍 +1 둘뿐이고 둘 다
// approval:true 다. 즉 아래 responseGrade 의 접힘 해제 경로(approval:false 인 행을 자기
// 자신으로 내보내는 갈래)는 **살아 있으나 주인이 없다.** 죽은 코드가 아니라 실측의 결과다 —
// 🙏 pray 와 🙇 man-bowing 이 그 자리의 후보였는데, 3개월 clean 3,174건에서 정밀도가
// 각각 0.00(표본 2)·0.07(표본 14) 로 채택선(0.70·표본 8)에 못 미쳐 어휘집에서 auto:false 로
// 내려갔다. 그래서 지우지 않는다: 어휘집 한 줄이 auto:true 로 바뀌는 순간 이 갈래가 다시
// 주인을 갖고, 그때 코드를 새로 짜야 한다면 그 채택선이 코드 수정을 요구하는 문이 된다.
function matchHeavy(t, cat) {
  for (const e of autoEmojis(cat).filter((x) => x?.level0 !== true)) {
    if (!e.match) continue;
    try { if (new RegExp(e.match, 'i').test(t)) return e; } catch {}
  }
  return null;
}

// ── 축 3 — decision (2026-09-02) ─────────────────────────────────────────────
//
// 등급(R0~R2)은 "글을 받을 자격이 있는가"이고, decision 은 "라이언의 판단을
// 기다리는가"다. 두 축이 갈리는 자리가 사고의 자리였다: Amani 의 1785자 설명은
// R2 후보였다가 근거를 못 찾아 R1 으로 내려왔고, 그때 달린 이모지가 ✅ 였다.
// ✅ 는 "확인했다"의 결과가 아니라 "글을 못 썼다"의 결과로 나갔고, 리액션이
// 라이언 계정(xoxp)으로 나가는 탓에 동료는 그것을 라이언의 승인으로 읽었다.
//
// 그래서 ✅ 는 더 이상 바닥값이 아니다. **양성 근거가 있을 때만 ✅ 다.**
//   not-needed — 어휘집이 실제로 물었다 (닫는 말·동의·승인 어휘) → 그 어휘의 이모지
//   needed     — veto 가 걸렸다 (묻는다·요청한다·막혀 있다·길다)  → 보는 중
//   unknown    — 아무것도 안 잡혔다 (바닥값 R1 · 단체 수신)        → 보는 중
//
// "분류가 안 됐다"와 "의사결정이 필요 없다"는 다른 상태다. 원장 전수 158건 중 근거가
// 있었던 것은 21건(13%)뿐이었고, 근거 없는 137건이 전부 ✅ 로 나갔다. unknown 을
// ✅ 가 아니라 보는 중으로 보내는 것이 이 축의 전부다.
//
// 등급은 한 글자도 바뀌지 않는다 — 바뀌는 것은 등급에 실려 나가는 이모지뿐이다.
// 모델을 새로 부르지 않는다. 세 갈래가 이미 계산해 둔 값(veto 여부·어휘집 일치
// 여부)에서 그대로 나오므로 토큰도 지연도 늘지 않는다.
export function responseGrade({ text = '', catalog = null, source = '' } = {}) {
  const cat = catalog || FALLBACK_CATALOG;
  const t = normalizeText(text);
  const back = fallbackEmoji(cat);
  const pend = pendingEmojiRow(cat);
  const wrap = (grade, row, reason, decision) => ({
    grade,
    emoji: row?.name || null,
    char: row?.char || '',
    label: row?.label || '',
    reason,
    decision,
  });

  // 어휘집에 보는 중 행이 없으면 옛 동작(✅)으로 내려간다. 여기서 null 을 돌려주면
  // 그 메시지에는 아무 응답도 남지 않는다 — 잘못된 이모지보다 무응답이 더 크게
  // 어긋난다. 대신 왜 대체됐는지를 사유 문자열에 실어 원장에서 보이게 한다.
  const pendRow = pend || back;
  const pendNote = pend ? ''
    : ` · 보는 중 이모지(${cat?.pendingEmoji || '미지정'})가 어휘집에 없어 :${back?.name || 'none'}: 로 대체`;

  // 옮겨 적을 문장이 하나도 없으면 리액션조차 소음이다. 여기만 이모지가 null 인 채로
  // 남는다 — R0 은 애초에 아무것도 달지 않는 등급이라 들려 보낼 것이 없다.
  if (!t) return wrap('R0', null, '옮겨 적을 문장이 없음', 'unknown');

  const veto = vetoReason(text, cat);
  if (veto) {
    // R2 이상 후보. 실제로 글이 될지는 신규성 게이트가 정한다. 강등될 때 달 이모지를
    // 함께 들려 보낸다 — 그 강등 경로가 이번 사고의 경로다(원장 158건 중 60건).
    return wrap('R2', pendRow, `${veto} → R2 이상 후보 (신규성 게이트 통과 시 글)${pendNote}`, 'needed');
  }

  // 뜻이 무거운 이모지(👌 승인·👍 동의)는 자동으로 달지 않는다. 잘못 달면 글보다
  // 크게 어긋나기 때문이다 — 등급은 R1 로 두고 표식만 넓은 ✅ 로 바꾼다.
  // decision 은 not-needed 다: 어휘집이 실제로 물었다는 것 자체가 양성 근거이고,
  // 걸린 어휘가 승인·동의·기원처럼 대화를 닫는 말이다.
  //
  // 2026-09-02 판 2 — 여기서 접는 기준이 "무겁다" 한 덩어리였는데, 실제로 위험한 것은
  // 무거움이 아니라 승인·동의의 뜻을 갖는가다. 🙏 는 heavy 라서 어휘집이 정확히
  // 골라낸 뒤에도 구조적으로 절대 슬랙에 나갈 수 없었다. 가르는 값은 코드가 아니라
  // 어휘집의 approval 키에 적는다 — 이 파일이 이모지 뜻의 정본이라는 위 규칙(:27-31)
  // 을 새 축에도 그대로 적용한다.
  const heavy = matchHeavy(t, cat);
  if (heavy) {
    // 접지 않는 것은 어휘집이 approval:false 라고 명시했을 때뿐이다. 키가 없으면
    // 접는다 — 새 행을 생각 없이 추가했을 때 라이언 계정으로 승인이 나가는 쪽이
    // 아니라 ✅ 가 나가는 쪽으로 떨어져야 한다. 옛 어휘집도 이 경로로 오늘과 같다.
    const fold = heavy.approval !== false;
    const row = fold ? back : heavy;
    const note = fold ? ' (승인 뜻이라 :white_check_mark: 로 접음)' : '';
    return wrap('R1', row, `어휘집 "${heavy.label || heavy.name}" 일치 · 물음·요청 신호 없음 → :${row?.name}:${note}`, 'not-needed');
  }

  const low = matchLevelZero(t, cat);
  if (low) return wrap('R1', low.row, `어휘집 일치 "${low.hit}" → :${low.row.name}: (${low.row.label || ''})`, 'not-needed');

  // 여기까지 왔다는 것은 "닫는 말도 아니고 묻는 말도 아니다" 이다. 옛 구조에서 이
  // 자리가 무조건 글이었고, 그래서 티타임 공지에 원문을 재진술한 답이 나갔다.
  // 지금은 R1 이되 ✅ 가 아니다 — 이 자리에서 나간 ✅ 두 건이 하필 "그 초록 체크는
  // 승인이 아니다" 라고 정정하던 대화였다.
  const group = isGroupAddress(text, source);
  return wrap('R1', pendRow,
    (group ? `단체 수신(멘션 ${mentionCount(text)}) · 물음·요청 신호 없음 → :${pendRow?.name}:`
      : `물음·요청 신호 없음 · 승격 근거 없음 → :${pendRow?.name}: (바닥값 R1)`) + pendNote,
    'unknown');
}

// ── 2) 모델 판정 — "분석 불가"가 나온 뒤 ─────────────────────────────────────
//
// 여기 오는 메시지는 이미 글 선응답이 한 번 실패한 것이다. 그러니 물어볼 것은
// "무엇을 답할까"가 아니라 "이건 애초에 답할 것이 있는 메시지인가"다. 그리고
// 스레드를 반드시 같이 준다 — 같은 스레드에서 내가 방금 지시를 내렸고 상대가
// "Understood" 라고 답한 것이라면, 그 메시지 하나만 봐서는 판단할 수 없다.
const PICK_PROMPT = [
  '아래 Slack 메시지에 글로 답할 것이 있는지, 아니면 리액션 이모지 하나로 끝내는 것이 맞는지 판정하라.',
  '',
  '판정 규칙:',
  '- 이 메시지는 방금 "컨텍스트가 부족해 분석할 수 없다"는 판정을 받았다. 그러나 컨텍스트가 부족한 것과 애초에 답할 것이 없는 것은 다르다.',
  '- <context>는 같은 스레드의 앞선 대화다. 앞에서 내가 무언가를 알리거나 지시했고 이 메시지가 그것을 받아들이는 말(understood, noted, 알겠습니다, 확인했습니다, 진행하겠습니다)이면, 답할 것이 없는 것이다 — 이모지로 끝낸다.',
  '- 반대로 상대가 무언가를 묻거나, 요청하거나, 막혀 있다고 말하거나, 결정을 기다리고 있으면 반드시 TEXT 로 판정하라. 답을 기다리는 사람에게 이모지만 달면 무시로 읽힌다.',
  '- 판단이 서지 않으면 TEXT 로 판정하라.',
  '',
  '이모지의 뜻은 아래 목록에 적힌 것이 정본이다. 네가 일반적으로 아는 뜻이 아니라 이 설명대로 골라라.',
].join('\n');

// 모델이 무엇을 돌려주든(설명, 콜론, 대문자, 따옴표) 어휘집에 있는 이름 하나로만
// 착지시킨다. 목록에 없는 이름은 버린다 — 슬랙에 없는 이모지를 달면 invalid_name
// 으로 실패하고, 그러면 이 메시지에는 아무 응답도 남지 않는다.
export function parsePick(out, catalog) {
  const raw = String(out || '').trim().split('\n')[0].replace(/[`"'*]/g, '').trim();
  const token = raw.replace(/^:|:$/g, '').trim().toLowerCase();
  if (!token || /^text$/i.test(token)) return null;
  for (const e of levelZeroEmojis(catalog)) {
    const n = String(e.name).toLowerCase();
    // "+1" 은 정규식 특수문자라 포함 검사로 본다.
    if (token === n || raw.includes(`:${e.name}:`) || (e.char && raw.includes(e.char))) {
      return { emoji: e.name, char: e.char || '', label: e.label || '' };
    }
  }
  return null;
}

export async function modelVerdict({ text = '', ctx = '', catalog = null, ask = null, log = () => {} } = {}) {
  const cat = catalog || FALLBACK_CATALOG;
  if (typeof ask !== 'function') return null;
  if (!levelZeroEmojis(cat).length) return null;
  const prompt = [
    PICK_PROMPT,
    '',
    '<emoji-vocabulary>',
    catalogText(cat),
    '</emoji-vocabulary>',
    '',
    '<context>', String(ctx || '(앞선 대화 없음)').slice(0, 3000), '</context>',
    '',
    '<message>', String(text || '').slice(0, 1200), '</message>',
    '',
    '이모지 이름 하나만 출력하라 (예: white_check_mark). 글로 답해야 하면 TEXT 한 단어만 출력하라. 설명·따옴표·접두어를 붙이지 마라.',
  ].join('\n');
  let out = '';
  try {
    out = await ask(prompt);
  } catch (e) {
    log?.('emoji 판정 실패:', String(e?.message || e).slice(0, 80));
    return null;
  }
  const pick = parsePick(out, cat);
  if (!pick) return null;
  return { ...pick, kind: 'model', reason: `모델 판정 → :${pick.emoji}: (${pick.label})` };
}

export default { loadCatalog, autoEmojis, levelZeroEmojis, catalogText, normalizeText, vetoReason,
  patternVeto, quickVerdict, responseGrade, RESPONSE_GRADES, parsePick, modelVerdict,
  mentionCount, isGroupAddress, withoutRosterLines, pendingEmojiRow, nonResolvingEmojis };
