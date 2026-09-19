// novelty-gate.mjs — "이 글이 스레드에 아직 없는 무엇을 더하는가" 를 결정적으로 잰다.
//
// 왜 생겼나 (2026-08-31 사고): Maryam 이 스레드에서 "첨부 PDF 를 받아 서명해서 여기
// 다시 올려 주면 된다" 고 이미 명확히 안내했다. 거기에 라이언 계정으로 자동 응답이
// 나갔고, 그 본문은 "Instruct Hamilton Ude to download the attached PDF, add a
// signature, and send the signed copy back in the channel." 였다. 바로 위 메시지의
// 재진술이다. 스레드에 새 사실을 한 톨도 넣지 않았고, 읽는 사람 셋의 주의를 한 번씩
// 가져갔다. 답변 품질의 문제가 아니라 발신 여부의 문제다.
//
// 그래서 설계(§1)가 정한 승격 규칙은 하나다 — 한 등급 올라가려면 *스레드에 아직 없는
// 무엇을 더하는지*를 이름으로 댈 수 있어야 한다. 대지 못하면 그 자리(R1)에 머문다.
//
// 이 모듈이 코드로 재는 것은 그중 결정적으로 잴 수 있는 부분뿐이다: 후보 글의 내용어
// 중 몇 할이 이미 스레드에 있는가. 애매한 부분("무엇을 더하는가")은 모델이 한 줄로
// 대고, 그 한 줄이 비면 호출부가 자동으로 R1 로 내린다. 판정을 통째로 모델에게 맡기지
// 않는 이유는 이 사고에서 모델이 "그것이 가벼운 일정 공유"라는 것까지 정확히 알고도
// 글을 썼기 때문이다 — 알고 있는 것과 안 쓰는 것은 다른 일이다.
//
// send-layer.mjs 의 echoRatio 와 겹쳐 보이지만 재는 것이 다르다. 그쪽은 "상대가 방금
// 쓴 말"(원문 한 건)과의 되풀이 비율을 측정만 하고 차단하지 않는다. 여기는 스레드
// 전체 — 특히 그 물음 뒤에 나온 메시지 — 와 견주고, 어형을 접두사로 맞춰 본다.
// "sign / signed / signature" 가 토큰으로는 셋이지만 사람에게는 한 말이기 때문이다.
// 그 어형 처리가 없으면 Maryam 건의 중복도가 임계값 아래로 떨어져 그대로 나간다.

const clean = (v) => String(v || '').replace(/\s+/g, ' ').trim();

// 내용어만 남긴다. 멘션·URL·이모지 코드는 내용이 아니라 배관이다.
const STOP = new Set(('a an the and or but if then that this these those is are was were be been being am'
  + ' do does did done to of in on at by for with from as it its i you he she they we my your his her their'
  + ' our me him them us not no yes so than there here what which who whom when where why how all any both'
  + ' each few more most other some such only own same too very can will just should now would could may'
  + ' might must shall about into over under again further once because while during before after above'
  + ' below up down out off please kindly thanks thank hi hello hey ok okay let know need want get got make'
  + ' take see back also still already'
  + ' 그리고 그러나 하지만 그래서 이것 저것 그것 여기 거기 저기 이거 그거 저거 있습니다 없습니다 합니다'
  + ' 입니다 합니다만 해서 하고 하는 하지 되는 되어 되고 것을 것이 것은 대한 위한 관련 그럼 네 예 아니오'
  ).split(/\s+/).filter(Boolean));

// 어형을 접두사로 맞추기 위한 최소 길이. 3자 이하(SG·KYC·PIP)는 접두사 매칭을 하면
// 서로 다른 약어가 뭉개지므로 정확히 같을 때만 같은 말로 본다.
const PREFIX_MIN = 4;

export function contentTokens(text) {
  return clean(String(text || '')
    .replace(/<@[UWB][A-Z0-9]*(?:\|[^>]*)?>/g, ' ')
    .replace(/<#C[A-Z0-9]*(?:\|[^>]*)?>/g, ' ')
    .replace(/<!(?:here|channel|everyone)>/g, ' ')
    .replace(/<(https?:[^>|]+)(?:\|[^>]*)?>/g, ' ')
    .replace(/https?:\/\/\S+/g, ' ')
    .replace(/:[a-z0-9_+-]+:/g, ' '))
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((w) => w && w.length > 1 && !STOP.has(w));
}

// 한 토큰이 이미 스레드에 있는가. 영문은 접두사 4자로 어형을 맞추고(sign / signed /
// signature), 한글은 조사가 뒤에 붙는 언어라 마찬가지로 앞에서 맞춘다(서명 / 서명해서).
// 숫자는 정확히 같을 때만 같은 것으로 본다 — "10건"과 "12건"이 같아지면 안 된다.
function seenIn(token, pool) {
  if (pool.has(token)) return true;
  if (/\d/.test(token)) return false;
  if (token.length < PREFIX_MIN) return false;
  for (const other of pool) {
    if (other.length < PREFIX_MIN || /\d/.test(other)) continue;
    const short = token.length <= other.length ? token : other;
    const long = token.length <= other.length ? other : token;
    if (long.startsWith(short)) return true;
  }
  return false;
}

// 후보 글의 내용어 중 몇 할이 이미 스레드에 있는가. 1 에 가까울수록 새 정보가 없다.
// 토큰이 너무 적으면(두 개 미만) 비율이 의미를 갖지 못하므로 null 을 돌려준다.
export function overlapRatio(body, source) {
  const b = contentTokens(body);
  if (b.length < 2) return null;
  const pool = new Set(contentTokens(source));
  if (!pool.size) return 0;
  let shared = 0;
  const seen = new Set();
  for (const t of b) {
    if (seen.has(t)) continue;
    seen.add(t);
    if (seenIn(t, pool)) shared += 1;
  }
  return Number((shared / seen.size).toFixed(3));
}

// 스레드에 없는 내용어. 원장에 남겨 "무엇이 새 것이라고 봤는지" 를 되짚는다.
export function novelTokens(body, source, max = 8) {
  const pool = new Set(contentTokens(source));
  const out = [];
  const seen = new Set();
  for (const t of contentTokens(body)) {
    if (seen.has(t)) continue;
    seen.add(t);
    if (!seenIn(t, pool)) out.push(t);
    if (out.length >= max) break;
  }
  return out;
}

// 임계값. 2026-08-31 전수 조사로 정했다 — 앞선 판의 0.7 은 사고 한 건과 정상 답변
// 한 건 사이에서 고른 값이었고, 그 사실을 여기 적어 두었었다.
//
// 근거는 이것이 전부다. 과거 ack 72건 중 본문이 남아 있는 48건을 이 모듈로 전수 계산했다
// (median 0.255 · p90 0.635 · max 0.818). 사고 본문은 같은 파이프라인에서 0.833 이 재현됐다.
//   1. 사고 본문이 0.833 이므로 상한은 0.83 이다.
//   2. 오늘의 출력 포맷(stripFrames 적용 후)으로 다시 재면 0.7 은 0.66 / 0.667 / 0.688
//      세 건을 통과시킨다. 그 셋의 전문을 읽어 셋 다 새 사실이 0 임을 확인했다. 0.65 는
//      셋을 다 막는다. 측정된 차이가 한 방향만 가리킨다.
//   3. 0.65 에서 막혀서 아까울 글은 48건 중 0건이다.
//   4. 비용이 대칭이 아니다 — 오탐이면 이모지 하나가 나가고, 미탐이면 라이언 이름으로
//      되풀이가 나간다.
//
// 분포가 갈라지는 자리는 없다. 최대 간격 0.081 은 몬테카를로 20만 회에서 p=0.291 로
// 표본 부족과 구분되지 않는다. 48건 중 새 사실을 하나라도 더한 ack 은 0건이라 정답
// 라벨이 없고, 42건은 scaffoldLeaks 로 이미 죽는 옛 포맷이라 오늘 파이프라인 기준
// 실측 표본은 사실상 2건이다. 즉 이 값은 "재서 나온 값"이지 "갈라지는 자리"가 아니다.
//
// 운영 중에는 slack-ack-cost-policy.json 의 noveltyGate.overlapMax 가 이 값을 덮어쓴다.
// 여기 숫자는 그 파일을 못 읽었을 때의 폴백이므로 둘을 따로 두지 않는다.
export const NOVELTY_OVERLAP_MAX = 0.65;

// 하나의 판정을 돌려준다. novel=false 면 이 글은 스레드에 새 것을 넣지 않는다.
//
// after 는 그 메시지 뒤에 스레드에 올라온 말이다. 사고가 난 자리가 정확히 여기다 —
// 물음이 던져진 뒤 사람이 이미 답을 했고, 우리가 그 답을 되풀이했다. 그래서 뒤에 나온
// 말만으로도 중복도가 임계값을 넘으면 전체 비율과 무관하게 떨어뜨린다. 앞부분까지
// 섞으면 스레드가 길수록 분모가 커져 재진술이 희석된다.
export function noveltyVerdict({ body = '', thread = '', after = '', adds = '',
  overlapMax = NOVELTY_OVERLAP_MAX } = {}) {
  const text = clean(body);
  if (!text) return { novel: false, reason: 'EMPTY_BODY', overlap: null, afterOverlap: null, novelTokens: [] };

  // 모델이 "무엇을 더하는가" 한 줄을 대지 못하면 그 자리에서 끝이다. 설계 §2 —
  // 그 한 줄이 비면 자동으로 R1 로 내려간다. 코드가 재기 전에 이것부터 본다.
  if (adds !== null && adds !== undefined && !clean(adds)) {
    return { novel: false, reason: 'NO_ADDS_LINE', overlap: null, afterOverlap: null, novelTokens: [] };
  }

  const overlap = overlapRatio(text, thread);
  const afterOverlap = clean(after) ? overlapRatio(text, after) : null;
  const tokens = novelTokens(text, `${thread}\n${after}`);
  const max = Number.isFinite(Number(overlapMax)) ? Number(overlapMax) : NOVELTY_OVERLAP_MAX;

  if (afterOverlap !== null && afterOverlap >= max) {
    return { novel: false, reason: 'ALREADY_ANSWERED_AFTER', overlap, afterOverlap, novelTokens: tokens };
  }
  if (overlap !== null && overlap >= max) {
    return { novel: false, reason: 'ALREADY_IN_THREAD', overlap, afterOverlap, novelTokens: tokens };
  }
  return { novel: true, reason: '', overlap, afterOverlap, novelTokens: tokens };
}

export default { contentTokens, overlapRatio, novelTokens, noveltyVerdict, NOVELTY_OVERLAP_MAX };
