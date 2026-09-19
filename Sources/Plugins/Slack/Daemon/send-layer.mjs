// 발신 레이어 (send layer) — 분석 레이어의 산출물이 그대로 wire 에 닿는 것을 막는다.
//
// alignment-engine.mjs 가 "무엇을 알아냈는가"를 소유한다면 이 파일은 "그것을 내보내도
// 되는가"를 소유한다. 두 자리가 한 파일에 섞여 있었기 때문에 2026-08-31 사고가 났다.

import { readFileSync } from 'node:fs';

// ---- 발신 레이어 (send layer) ------------------------------------------------
//
// 2026-08-31, 같은 날 두 번째 사고. Maryam 이 Hamilton Ude 에게 올린 PIP 통지 스레드
// (C0BTB21Q8LF) 에, 라이언 이름으로 이 네 줄이 나갔다.
//
//   Purpose: … / Intent · request_assistance: … / Define problem: … / Alignment: NO
//
// 이 네 줄은 사람에게 보내는 문장이 아니라 **추출 스키마의 필드 이름**이다. v1 렌더러가
// analysis 레코드를 필드마다 `<필드명>: <값>` 으로 직렬화해 그대로 wire 에 실었다. 즉
// 분석 레이어의 산출물이 발신 레이어를 거치지 않고 나갔고, 이 파일에는 그 둘을 가르는
// 자리가 애초에 없었다. renderAcknowledgement 는 작성자가 아니라 직렬화기다.
//
// 같은 날 13:35 에 들어온 ackSendGate 는 이것을 막지 못한다. 실측했다 — 나간 본문을
// 그대로 넣고 confidence 0.8 을 주면 send=true 가 나온다. 확신도 충분하고 문서 레이어도
// 실패하지 않았기 때문이다. 즉 **데몬을 재기동해도 이 사고는 다시 난다.**
//
// 포맷을 v2 로 올려도 막히지 않는다. v2 는 필드명을 지웠을 뿐, (a) 상대가 방금 쓴 말을
// 되돌려 주는 `*What this means*` 와 (b) 이 건에서는 틀린 답이었던
// `Likely decision: 편집 가능한 URL 을 공유한다` 를 그대로 내보낸다 — 1분 뒤 Maryam 이
// "URL 은 필요 없다"고 정정한 바로 그 답을, 대표 이름으로, PIP 스레드에 먼저 박는다.
//
// 그래서 발신 레이어에 결정적인 검사 두 개를 세운다. 모델이 "보내도 되겠다"고 정하는
// 자리가 아니라, 코드가 읽어 막는 자리다.
//
//   1. 분석 스캐폴딩이 wire 에 닿으면 막는다 (어느 렌더러가 만들었든, 모델이 직접
//      뱉었든 상관없이 — 이 검사는 인스턴스가 아니라 부류를 잡는다).
//   2. 보내면 안 되는 자리에서는 아예 만들지 않는다 (인사·징계·보상·법무).
//
// 되풀이(상대의 말을 그대로 다시 말하는 것)는 **막지 않고 재기만 한다.** 실측에서
// 사고 본문 0.33 / v2 0.26 / 정답 0.00 / 정상 답변 0.11 로, 좋은 것과 나쁜 것이 갈리기는
// 하지만 임계값을 안전하게 놓을 만큼 떨어져 있지 않다. 여기서 막으면 게이트가 아니라
// 스위치가 된다. 값을 원장에 남겨 근거가 쌓인 뒤에 임계값을 정한다.

// 추출 스키마의 필드 라벨. 이 문자열이 줄 앞에 오면 그 줄은 사람에게 쓴 문장이 아니라
// 내부 레코드다. v1 렌더러와 legacy 프롬프트가 쓰는 라벨을 한국어·영어 양쪽으로 모은다.
export const SCAFFOLD_LABELS = [
  'Naming', 'Purpose', 'Background', 'Intent', 'Define problem',
  'Expected problem definition', 'Original problem definition', 'Alignment',
  'Internal evidence', 'Shared document check', 'Requirements (public sources)',
  'Sufficiency', 'Expected bottleneck',
  '이름 정리', '목적', '배경', '의도', '문제 정의', '예상 문제 정의', '원래 문제 정의',
  '부합 여부', '내부 자료 확인', '공유 문서 확인', '필요 요건(공개 자료 기준)',
  '필요 요건', '충분성', '예상 병목',
];

// 자동 응답임을 스스로 선언하는 첫 줄. 신뢰를 얻지 못하고 뒤를 읽지 않을 이유만 준다.
// v1 의 고정 첫 줄이고, 이것이 붙어 있으면 그 글은 v1 직렬화 산출물이다.
const SELF_DECLARATION_RE = new RegExp(
  'this\\s+is\\s+an\\s+automated\\s+agent\\s+response'
  + '|에이전트\\s*자동\\s*응답입니다', 'i');

const escapeRe = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// 줄 앞의 `라벨:` 또는 `라벨 · 무엇:` 만 잡는다. 문장 중간의 같은 단어는 잡지 않는다 —
// "the purpose of this change is…" 는 멀쩡한 문장이고 막을 이유가 없다.
const SCAFFOLD_RE = new RegExp(
  '^[ \\t]*[*_]{0,2}(' + SCAFFOLD_LABELS.map(escapeRe).join('|') + ')[*_]{0,2}[ \\t]*(?:·[^:\\n]{0,40})?:',
  'gmu');

// 나갈 글에 남아 있는 분석 스캐폴딩을 전부 돌려준다. 빈 배열이면 깨끗한 것이다.
export function scaffoldLeaks(body) {
  const text = String(body || '');
  const hits = new Set();
  for (const m of text.matchAll(SCAFFOLD_RE)) hits.add(m[1]);
  if (SELF_DECLARATION_RE.test(text)) hits.add('automated-agent-declaration');
  return [...hits];
}

// ---- 발신 금지 자리 ----------------------------------------------------------
//
// 사고가 하필 PIP 스레드에서 난 것은 우연이 아니다. 이 경로의 응답 정책은 **거부 목록**
// 이고, 등록된 것이 채널 하나(chat-random-global)와 사람 하나뿐이다. 나머지 전부는
// 기본값이 `reply` 다. 어제 만들어진 PIP 그룹 DM 도, 채널 ID 를 미리 알 수 없으므로
// 목록에 들어갈 방법이 없었다. 그래서 자리(채널 ID)가 아니라 **주제**로 판정한다.
//
// 판정 근거는 채널 이름 + 그 메시지 본문 + 첨부 파일 이름이다. 모델을 부르지 않는다.
export function sensitiveContext({ channelName = '', text = '', context = '', files = [], policyFiles = [] } = {}) {
  let policy = null;
  for (const path of policyFiles) {
    try { policy = JSON.parse(readFileSync(path, 'utf8')); } catch { /* 없으면 다음 파일 */ }
  }
  if (!policy || !policy.domains) return { domain: null, hit: null, where: null };

  const fileNames = (Array.isArray(files) ? files : [])
    .map((f) => String(f?.name || f?.title || f || '')).join('\n');
  // 자리를 넓게 본다. 용어집에서는 채널 컨텍스트를 근거로 승격한 것이 바로 8/31 첫
  // 사고의 원인이었지만, 여기서는 방향이 반대다 — 이 검사는 발신을 막기만 하므로
  // 컨텍스트를 넣어서 생기는 오류는 "안 보냈어야 할 것을 안 보냄"이 아니라
  // "보내도 됐을 것을 안 보냄" 쪽으로만 난다. Hamilton 의 메시지 본문에는 PIP 라는
  // 문자열이 한 번도 없다. 그 자리가 PIP 스레드라는 사실은 컨텍스트에만 있었다.
  const fields = [
    ['channel', String(channelName || '')],
    ['message', String(text || '')],
    ['attachment', fileNames],
    ['context', String(context || '')],
  ];

  for (const [domain, row] of Object.entries(policy.domains)) {
    const except = (row.except || []).map((p) => new RegExp(p, 'giu'));
    const tests = [
      ...(row.patterns || []).map((p) => new RegExp(p, 'gu')),
      ...(row.patternsI || []).map((p) => new RegExp(p, 'giu')),
    ];
    for (const [where, value] of fields) {
      if (!value) continue;
      // except 는 필드 전체를 면제하지 않는다. 매치된 그 자리가 예외 표현 안에
      // 들어 있을 때만 그 매치를 버린다 — "pip install" 한 줄 때문에 같은 메시지의
      // "PIP notice" 까지 통과시키면 예외가 구멍이 된다.
      const spans = [];
      for (const re of except) for (const m of value.matchAll(re)) spans.push([m.index, m.index + m[0].length]);
      for (const re of tests) {
        for (const m of value.matchAll(re)) {
          const covered = spans.some(([a, b]) => m.index >= a && m.index < b);
          if (covered) continue;
          return { domain, hit: m[0].slice(0, 60), where, label: row.label || domain, why: row.why || '' };
        }
      }
    }
  }
  return { domain: null, hit: null, where: null };
}

// ---- 되풀이 비율 (측정만, 차단하지 않음) --------------------------------------
const ECHO_STOP = new Set(('a an the and or but if then that this these those is are was were be been being'
  + ' do does did to of in on at by for with from as it its i you he she they we my your his her their our'
  + ' me him them us not no yes so than there here what which who whom when where why how all any both each'
  + ' few more most other some such only own same too very can will just should now would could may might'
  + ' must shall about into over under again further once because while during before after above below up'
  + ' down out off').split(/\s+/));

const echoTokens = (s) => String(s || '')
  .replace(/<@[^>]+>/g, ' ').replace(/https?:\/\/\S+/g, ' ')
  .toLowerCase().split(/[^\p{L}\p{N}]+/u)
  .filter((w) => w.length > 1 && !ECHO_STOP.has(w));

// 나갈 글의 내용어 중 몇 할이 상대가 이미 쓴 말인가. 1 에 가까울수록 새 정보가 없다.
export function echoRatio(body, source) {
  const b = new Set(echoTokens(body));
  if (!b.size) return null;
  const s = new Set(echoTokens(source));
  let shared = 0;
  for (const w of b) if (s.has(w)) shared += 1;
  return Number((shared / b.size).toFixed(3));
}
