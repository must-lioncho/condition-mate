// Deterministic execution-alignment gate for Slack acknowledgements.
// The model extracts facts; this module, not the model, owns the YES/NO verdict.
//
// 발신 가부는 이 파일이 아니라 send-layer.mjs 가 소유한다. 분석 레이어의 산출물이
// 그대로 wire 에 닿은 것이 2026-08-31 PIP 스레드 사고였다 (docs 참조).
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { scaffoldLeaks, sensitiveContext, echoRatio } from './send-layer.mjs';
import { noveltyVerdict, NOVELTY_OVERLAP_MAX } from './novelty-gate.mjs';

// 영어의 that 은 지시어이기도 하고 접속사이기도 하다. "I got an understanding that we
// want to…" 의 that 은 가리키는 대상이 없는 접속사인데, 이것까지 미해결 참조로 세면
// 영어 문장 거의 전부가 Alignment NO 가 되고 "that 이 가리키는 대상을 식별할 수 없다"는
// 엉뚱한 사유가 붙는다 (2026-08-30 재실행에서 실제로 나왔다). 뒤에 주어가 오는 that 은
// 접속사로 보고 뺀다. 지시어 용법("that document", 문장 끝의 that)은 그대로 잡힌다.
const THAT_AS_CONJUNCTION = '(?!\\s+(?:we|you|i|they|he|she|it|there|the|a|an|is|are|was|were|will|would|can|could|should|may|might|must|has|have|had|do|does|did)\\b)';
const VAGUE_REFERENCE_RE = new RegExp(
  '\\b(?:all\\s+)?\\d+\\s+(?:rows?|items?|entries?|tasks?)\\b'
  + '|\\b(?:this|these|those|the\\s+(?:rows?|items?|entries?|tasks?))\\b'
  + `|\\bthat\\b${THAT_AS_CONJUNCTION}`
  + '|(?:해당|위|아래|저|그)\\s*(?:항목|행|내용|문서|것)', 'giu');

const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();

// ---- 응답 포맷 버전 ----------------------------------------------------------
// v1 = 정렬 판정 보고서. `Purpose:` `Answer:` `Alignment:` 처럼 추출 스키마의 필드
//      이름을 그대로 줄 앞에 붙여 직렬화했다. 2026-08-31 Maryam PIP 스레드 사고에서
//      실제로 나간 것이 이 포맷이다.
// v2 = `Read as: *…* · Likely decision: *…*` 머리줄과 "이 답은 에이전트 답변입니다"
//      한 줄을 얹고 그 아래 두 칸을 놓았다. 라벨을 줄였을 뿐, 상대가 방금 쓴 말을
//      되돌려 주는 자리는 그대로 남아 있었다.
// v3 = 라벨 없는 문장뿐. 서두도 머리줄도 칸도 없다. 근거를 밝혀야 하면 문장 안에서
//      밝힌다 (설계 §3).
//
// **v1·v2 렌더러는 지웠다.** 앞선 판은 "되돌릴 자리가 없으면 포맷 변경은 도박"이라고
// 적고 v1 을 남겨 두었는데, 남겨 둔 그 코드가 사고 당일 실제로 돌아 라이언 이름으로
// 나갔다. 되돌릴 자리로 남긴 것이 아니라 되살아날 자리로 남은 것이다. 값 자체는
// 목록에 남긴다 — 원장(ackFormat)과 config.json 에 이미 "v1"/"v2" 가 적혀 있고,
// 그것을 모르는 값으로 만들면 옛 설정이 읽히지 않는다. 어느 값이 오든 렌더러는
// 하나다.
export const REPLY_FORMATS = ['v1', 'v2', 'v3'];
export const LATEST_REPLY_FORMAT = 'v3';

export function replyFormat(value) {
  return REPLY_FORMATS.includes(value) ? value : LATEST_REPLY_FORMAT;
}

// ---- 추출 계약 (축 1 — 커뮤니케이션 코스트 에이전트) --------------------------
//
// 정본 페르소나와 등급표는 slack-ack-cost-policy.json 에 있고, 호출부가 그 파일을
// 읽어 persona 로 넘긴다. 여기 적힌 문자열은 그 파일을 하나도 못 읽었을 때의 폴백이다.
//
// persona 는 프롬프트 첫머리에만 실린다. **모델에게 자기 범위를 못박는 선언이지
// 나가는 글의 서두가 아니다.** 그 둘을 헷갈리면 정형 서두를 지우고 다시 만드는 꼴이
// 된다 (설계 §2·§3).
export const ACK_PERSONA_FALLBACK =
  '나는 응답의 분량을 깎는 에이전트다. 답을 쓰는 것이 내 일이 아니라, 이 메시지가 글을 받을 '
  + '자격이 있는지 판정하는 것이 내 일이다. 기본값은 리액션 하나이고 글은 예외다.';

// 옛 계약(V1_FIELDS·V2_FIELDS)은 지웠다. 라벨이 붙은 칸을 스물몇 개 주면 모델은 빈 칸을
// 남기지 않으려고 이미 아는 말을 다시 적는다. Maryam 건의 `Purpose:` 줄이 정확히 그렇게
// 만들어졌다 — 칸이 있으니까 채운 것이다. 그래서 칸을 없앴다.
const V3_FIELDS = [
  'adds: one short line naming what your reply puts into the thread that is NOT already there. '
    + 'If the thread, the shared documents or the message itself already says it, return an empty string. '
    + 'An empty string is the CORRECT answer whenever you would only be restating what someone already wrote — '
    + 'a restatement is not an answer, it is a cost taken from every reader of this thread.',
  'reply: the answer itself as one to three plain sentences. No labels, no headings, no numbered options. '
    + 'Never open with a greeting, an apology, "checking on this", "will get back to you" or "see the details below". '
    + 'Never say that you are an agent or that this is automated. '
    + 'If you must show what the answer rests on, say it inside the sentence rather than on a separate labelled line. '
    + 'Leave it empty when <adds> is empty.',
  'depth: R2 R3 or R4. R2 = one sentence adding a single fact the thread does not have. '
    + 'R3 = two to five sentences, the answer plus what it rests on. '
    + 'R4 = only when the other side explicitly asked us for analysis or a judgement. '
    + 'When unsure return R2 — the shorter grade is the safer one here.',
  'detail: everything that did not fit in <reply> — the evidence you used, the reasoning, what you checked and what '
    + 'you could not check. This never goes to Slack; it goes to a markdown note. Write it freely and completely.',
  'assumption: one line naming the assumption you had to make because the request left its scope open. '
    + 'Empty when the scope was clear.',
  'has_basis: false only when nothing in the evidence lets you say anything useful about this message.',
  'confidence: 0 to 1 — how sure you are that this reply is correct AND answers what was actually asked. '
    + 'Judge it on the evidence you were given, not on how fluent the reply reads. Below 0.8 the reply is not sent, '
    + 'so returning a low number is the correct action when the evidence is thin — never inflate it.',
  '<prior> holds the agent answers already sent in this thread. They are being deleted and replaced by this one, '
    + 'so carry forward whatever still holds and state the current reading in full — never write "as mentioned above".',
  'Schema: {"has_basis":true,"confidence":0.0,"adds":"","reply":"","depth":"R2","detail":"","assumption":""}',
];

// 언어 지시. 2026-08-31 야샬 건에서 이것은 프롬프트 두 번째 줄에 한 줄로만 있었고,
// 그 아래로 한국어 근거가 수천 자 깔리자 Gemini Flash-Lite 가 지시가 아니라 주변
// 언어를 따라갔다. 그래서 두 가지를 바꿨다. 무엇을 어겼는지 못박아 쓰고, 프롬프트의
// 맨 앞과 **맨 뒤** 두 자리에 놓는다 — 맨 뒤가 실제로 지켜지는 자리다.
//
// 이 함수는 언어를 판정하지 않는다. 판정은 reply-language.mjs 한 곳에 있고 여기는
// 그 결과를 받아 쓸 뿐이다.
function languageRule(language) {
  const name = language === 'ko' ? 'Korean (한국어)' : 'English';
  const other = language === 'ko' ? 'English' : 'Korean';
  return `LANGUAGE — the recipient's language has already been decided and it is ${name}. `
    + `Write <reply>, <adds> and <assumption> in ${name}, every sentence of them. `
    + `The thread, the evidence and the earlier replies below may be in ${other}; that does NOT `
    + `change the language you write in. Proper nouns keep their original spelling; nothing else does.`;
}

export function extractionPrompt({ text, context, jira, extra = {}, language = 'en',
  format = LATEST_REPLY_FORMAT, prior = '', persona = '', retryRule = '' } = {}) {
  void format; // 포맷 값은 원장에만 남는다 — 렌더러는 하나다.
  return [
    persona || ACK_PERSONA_FALLBACK,
    '',
    'Read the Slack message and the evidence, then decide whether this message has earned prose at all.',
    languageRule(language),
    'Return one JSON object only, without Markdown fences.',
    'Never invent a link, an object, an owner, a deadline, a timezone or an acceptance criterion.',
    'Evidence marked withheld, unavailable or timed out was NOT read. Do not claim you checked it and do not lean on it.',
    'Apply <glossary> before every other source — a wrong name makes every later fact point at the wrong object. '
      + 'State any name correspondence inside a sentence, never as a separate labelled line.',
    '<context> may be recent channel messages rather than this thread. Channel messages are not evidence for what this '
      + 'thread is about; only lines under a thread marker are.',
    ...V3_FIELDS,
    '<prior>', prior || '', '</prior>',
    '<glossary>', extra.glossary || '', '</glossary>',
    '<people>', extra.people || '', '</people>',
    '<context>', context || '', '</context>',
    '<documents>', extra.notion || '', '</documents>',
    '<jira>', jira || '', '</jira>',
    '<related>', extra.related || '', '</related>',
    '<research>', extra.research || '', '</research>',
    '<attachments>', extra.attachments || '', '</attachments>',
    '<message>', text || '', '</message>',
    // 근거를 다 읽은 직후, 답을 쓰기 직전 자리. 위에 깔린 다른 언어를 방금 읽은
    // 상태에서 이 줄을 읽게 된다. retryRule 은 한 번 어긴 뒤에만 실린다.
    '',
    languageRule(language),
    ...(retryRule ? ['', String(retryRule)] : []),
  ].join('\n');
}

// 요청 난이도와 열람 권한은 별개다. 여기의 레벨은 답을 만들기 위해 실제로 사용한
// 컨텍스트의 깊이다: 현재 스레드만=L2, 공개 웹=L3, 공개 웹+내부 자료=L4.
//
// **이 값은 원장에 남는 내부 값일 뿐이고, 나가는 글의 모양을 정하지 않는다** (설계 §5-1).
// 옛 구조에서는 이 값이 그대로 렌더러의 분기였다. 첨부가 하나만 있어도 hasInternal 이
// 참이 되어 레벨 4가 되고, 레벨 4 렌더러는 직답 줄을 내지 않고 보고서 포맷을 강제했다 —
// 근거를 많이 모을수록 글이 길어지고 답은 사라지는 구조였다. 그 연결을 끊었으므로
// 여기서 4가 나오는 것은 이제 "근거를 많이 봤다"는 기록일 뿐이다.
export function evidenceRequestLevel(extra = {}, { hasAttachment = false } = {}) {
  const research = clean(extra.research);
  const hasResearch = /^\[Web research · genspark · 공개 웹 자료/m.test(research)
    && /https?:\/\//i.test(research);
  const hasInternal = /^\[Notion 문서/m.test(clean(extra.notion))
    || /^[A-Z][A-Z0-9]*-\d+:/m.test(clean(extra.jira))
    || /^\[다른 스레드/m.test(clean(extra.related))
    || hasAttachment;
  if (hasInternal) return 4;
  if (hasResearch) return 3;
  return 2;
}

export function parseExtraction(raw) {
  const source = String(raw || '').trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
  try {
    const value = JSON.parse(source);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

function evidenceCorpus(input) {
  return [input.context, input.jira, input.extra?.glossary, input.extra?.notion,
    input.extra?.related, input.extra?.research, input.extra?.attachments].map(clean).filter(Boolean).join('\n');
}

function validResolution(ref, corpus) {
  if (!ref || ref.resolved !== true) return false;
  const quote = clean(ref.evidence);
  const phrase = clean(ref.phrase);
  if (quote.length < 8 || !corpus.includes(quote)) return false;
  if (quote.toLowerCase() === phrase.toLowerCase()) return false;
  // Resolution must add an identifier/location, not simply restate “the 10 rows”.
  return /https?:\/\/|notion|database|table|page|표|문서|페이지|데이터베이스|\b[A-Z][A-Z0-9]{1,9}-\d+\b|(?:^|[,;])\s*\d+[.)]/i.test(quote);
}

export function alignmentVerdict(analysis, input) {
  if (!analysis || analysis.has_basis === false) {
    return { aligned: false, noBasis: true, reasons: ['NO_BASIS'] };
  }
  const corpus = evidenceCorpus(input);
  const refs = Array.isArray(analysis.unresolved_references) ? analysis.unresolved_references : [];
  const reasons = [];
  const vague = [...clean(input.text).matchAll(VAGUE_REFERENCE_RE)].map((m) => clean(m[0]));
  for (const phrase of vague) {
    const row = refs.find((r) => clean(r?.phrase).toLowerCase() === phrase.toLowerCase());
    if (!validResolution(row, corpus)) reasons.push(`NO_UNRESOLVED_SCOPE:${phrase}`);
  }
  for (const ref of refs) if (!validResolution(ref, corpus)) {
    const reason = `NO_UNRESOLVED_SCOPE:${clean(ref?.phrase) || 'unknown'}`;
    if (!reasons.includes(reason)) reasons.push(reason);
  }
  if (!clean(analysis.deliverable)) reasons.push('NO_MISSING_DELIVERABLE');
  if (!clean(analysis.target)) reasons.push('NO_MISSING_TARGET');
  if (!clean(analysis.owner)) reasons.push('NO_MISSING_OWNER');
  return { aligned: reasons.length === 0, noBasis: false, reasons };
}

// ---- 렌더러 — 라벨 없는 문장뿐 ------------------------------------------------
//
// 옛 렌더러 둘(renderAcknowledgement / renderAcknowledgementV2)은 지웠다. 둘 다
// 작성자가 아니라 직렬화기였다 — analysis 레코드를 필드마다 `<필드명>: <값>` 으로
// 늘어놓았고, 그래서 2026-08-31 Maryam PIP 스레드에 `Purpose:` `Answer:` 두 줄이
// 라이언 이름으로 나갔다. 여기 있는 것은 모델이 쓴 문장을 다듬어 내보낼 뿐이고,
// 스키마의 필드 이름은 한 글자도 wire 에 닿지 않는다.
//
// 근거 깊이(evidenceRequestLevel)는 이제 이 자리에 오지 않는다. 옛 구조에서는
// 첨부가 하나만 있어도 레벨 4가 되고, 레벨 4 렌더러는 직답 줄을 내지 않았다 —
// 근거를 모을수록 답이 사라지는 구조였다 (설계 §5-1). 근거 깊이는 원장에 남는
// 내부 값일 뿐이며 나가는 글의 모양을 한 톨도 바꾸지 않는다.

// 모델이 라벨을 뱉었을 때 그 라벨만 걷어낸다. 내용까지 버리지 않는 이유는, 모델이
// 계약을 어겼다는 사실이 상대가 답을 못 받을 이유는 아니기 때문이다. 라벨이 실제로
// wire 에 닿았는지는 send-layer.mjs 의 scaffoldLeaks 가 게이트에서 다시 본다.
const LABEL_LINE_RE = new RegExp(
  '^[ \\t]*[*_]{0,2}(?:Purpose|Answer|Naming|Intent|Alignment|Background|Define\\s+problem'
  + '|Expected\\s+problem\\s+definition|Original\\s+problem\\s+definition|Internal\\s+evidence'
  + '|Shared\\s+document\\s+check|Requirements[^:\\n]{0,24}|Sufficiency|Recommendation'
  + '|Expected\\s+bottleneck|What\\s+this\\s+means|Likely\\s+decision|Read\\s+as'
  + '|목적|답변|이름\\s*정리|의도|부합\\s*여부|배경|문제\\s*정의|예상\\s*문제\\s*정의'
  + '|원래\\s*문제\\s*정의|내부\\s*자료\\s*확인|공유\\s*문서\\s*확인|필요\\s*요건[^:\\n]{0,20}'
  + '|충분성|추천|예상\\s*병목|의미\\s*분석|예상\\s*의사결정|이렇게\\s*이해했습니다|예상\\s*결정)'
  + '[*_]{0,2}[ \\t]*(?:·[^:\\n]{0,40})?:[ \\t]*', 'gmu');

// 정형 서두와 머리줄. 줄을 통째로 지운다 — 이 줄들은 읽는 사람이 아니라 쓰는 쪽의
// 사정을 적은 것이고, 라벨만 떼어내면 `*결과 공유* · Likely decision: *확인 종결*`
// 처럼 라벨이 문장 가운데 남는다. 머리줄에는 남길 내용이 애초에 없다.
const PREAMBLE_RE = new RegExp(
  '^.*(?:this\\s+is\\s+an\\s+automated\\s+agent\\s+response'
  + '|this\\s+is\\s+an\\s+agent\\s+answer\\s+for\\s+now'
  + '|에이전트\\s*자동\\s*응답입니다'
  + '|이\\s*답은\\s*에이전트\\s*답변입니다'
  + '|read\\s+as\\s*:'
  + '|likely\\s+decision\\s*:'
  + '|이렇게\\s*이해했습니다\\s*:'
  + '|예상\\s*결정\\s*:).*$', 'gim');

// 이음말. 문장이 아니라 소음이다 (설계 §7-1). 인사·사과·"확인 중입니다"·
// "곧 회신드리겠습니다"·"자세한 내용은 아래를 참고하세요" 부류를 문장 단위로 버린다.
const FILLER_SENTENCE_RE = new RegExp(
  '^(?:hi|hello|hey|dear)\\b'
  + '|^(?:thanks|thank\\s+you)\\b'
  + '|\\bsorry\\b|\\bapologies\\b'
  + '|\\b(?:checking|looking)\\s+(?:on|into)\\s+(?:this|it)\\b'
  + '|\\bwill\\s+(?:get\\s+back|follow\\s+up|revert|update\\s+you)\\b'
  + '|\\b(?:see|refer\\s+to)\\s+(?:the\\s+)?(?:details?\\s+)?below\\b'
  + '|\\blet\\s+me\\s+know\\s+if\\b'
  + '|\\bhope\\s+(?:this|that)\\s+helps\\b'
  + '|\\bfeel\\s+free\\s+to\\b'
  + '|^안녕하[세십]'
  + '|^(?:감사합니다|고맙습니다)'
  + '|죄송|사과드'
  + '|(?:확인|검토)\\s*중\\s*(?:입니다|이에요|이며|이고|임|에\\s*있)'
  + '|확인\\s*하고\\s*있'
  + '|곧\\s*(?:회신|답변|안내)'
  + '|자세한\\s*(?:내용|사항)은'
  + '|아래를?\\s*참고'
  + '|궁금한\\s*점이?\\s*있으?[시면]'
  + '|도움이\\s*되었으면', 'i');

// 문장으로 자른다. 한국어는 마침표를 안 찍고 줄로 끊는 일이 많아 줄바꿈도 경계로 본다.
export function splitSentences(text) {
  return String(text || '')
    .split('\n')
    .flatMap((line) => line.split(/(?<=[.!?。！？])\s+/))
    .map((s) => s.trim())
    .filter(Boolean);
}

// 라벨·서두·이음말을 걷어낸 문장들. 남는 것이 없으면 빈 문자열이다.
export function stripFrames(text) {
  const noPreamble = String(text || '').replace(PREAMBLE_RE, '');
  const noLabels = noPreamble.replace(LABEL_LINE_RE, '');
  return splitSentences(noLabels).filter((s) => !FILLER_SENTENCE_RE.test(s)).join(' ').trim();
}

// ---- 슬랙 상한 ---------------------------------------------------------------
//
// 두 줄 · 280자. 넘으면 잘라 내지 않는다 — 넘친다는 것은 요약이 안 됐다는 뜻이므로
// 들어가는 문장만 남기고 나머지는 통째로 MD 로 간다. 잘린 문장을 슬랙에 남기는 것은
// 요약이 아니라 훼손이다 (설계 §7-1).
export const SLACK_ACK_MAX_LINES = 2;
export const SLACK_ACK_MAX_CHARS = 280;

const charLen = (s) => Array.from(String(s || '')).length;

export function slackBrief(body, { maxLines = SLACK_ACK_MAX_LINES, maxChars = SLACK_ACK_MAX_CHARS } = {}) {
  const cleaned = stripFrames(body);
  if (!cleaned) return { text: '', overflow: clean(body), trimmed: Boolean(clean(body)) };
  const sentences = splitSentences(cleaned);
  const kept = [];
  let used = 0;
  for (const s of sentences) {
    if (kept.length >= maxLines) break;
    const cost = charLen(s) + (kept.length ? 1 : 0);
    if (used + cost > maxChars) break;
    kept.push(s);
    used += cost;
  }
  // 첫 문장 하나조차 상한을 넘으면 슬랙에 내보낼 한 줄이 없다. 여기서 잘라 붙이면
  // 문장이 끊긴 채 남으므로, 본문은 통째로 MD 로 보내고 빈 문자열을 돌려준다.
  // 그때 무엇을 할지(침묵할지)는 호출부가 정한다.
  const overflow = sentences.slice(kept.length).join(' ');
  return { text: kept.join(' '), overflow, trimmed: Boolean(overflow) };
}

// 나가는 글은 모델이 쓴 문장뿐이다. 여기서 하는 일은 고르는 것과 다듬는 것이지
// 조립하는 것이 아니다.
export function renderReply(analysis, input = {}) {
  if (!analysis || analysis.has_basis === false) return null;
  // adds 가 비면 이 글은 스레드에 아무것도 더하지 않는다고 모델 스스로 말한 것이다.
  // 그 자리에서 끝낸다 — 신규성 게이트가 다시 보지만, 만들지 않는 편이 싸다.
  if (analysis.adds !== undefined && !clean(analysis.adds)) return null;
  const body = stripFrames(clean(analysis.reply || analysis.response || analysis.intent_summary));
  if (!body) return null;
  // 가정 한 줄은 더 이상 나가는 글에 붙지 않는다. 2026-09-02 사고의 마지막 문장이
  // 이 자리에서 만들어졌다 — "Assumed the user is Danny seeking confirmation…".
  // 범위가 모호하면 밝히고 보내는 것이 아니라 보내지 않는 것이 맞다. 가정 문장은
  // MD 노트로만 가고, 게이트의 HEDGED_BODY 가 같은 부류를 한 번 더 잡는다.
  void input;
  return body;
}

// ---- 발신 게이트 -------------------------------------------------------------
//
// 2026-08-31 사고. Piyush 의 DM(D09TD0LF942)에 "두 비전 중 어떻게 보느냐"는 질문이
// 왔는데, 노션 통합 토큰이 키체인에 없어 스레드에 공유된 노션 문서를 한 줄도 읽지
// 못한 상태에서 답이 그대로 나갔다. 나간 글에는 조회 실패 사실이
// "Internal evidence: Notion lookup is unavailable due to missing integration token."
// 이라는 문장으로 실려 있었다. 근거를 못 읽었으면 그 사실을 상대에게 알리는 것이
// 아니라 아예 발신하지 않는 것이 맞다 — 라이언이 정한 규칙은 두 줄이다.
//   1. 확신 80% 미만이면 나가지 않는다.
//   2. 근거 조회가 실패한 상태에서는 나가지 않는다.
//
// 게이트는 결정적이다. 모델이 "보내도 되겠다"고 판단하는 자리가 아니라, 모델이 돌려준
// 값과 근거 레이어의 실제 상태를 코드가 읽어 막는 자리다. 막힌 것은 조용히 사라지지
// 않고 원장에 사유와 함께 남는다.
// 2026-08-31 두 번째 사고. 티타임 공지("See you all at tea break soon.")에
// "Answer: Inform team members about the upcoming tea break." 가 나갔다. 위의 게이트는
// 셋 다 통과했다 — 확신도 높았고, 근거 조회도 실패하지 않았고, 새는 것도 없었다.
// 모델은 그것이 "가벼운 일정 공유"라는 것까지 정확히 알고 있었다.
//
// 즉 이 게이트는 "답할 수 있는가"만 묻고 있었다. 셋 다 실패했을 때만 막는 조건이다.
// 빠진 것은 "답할 값이 있는가"다. 성공했는데 쓸모없는 글이 나가는 경로가 열려 있었고,
// 시스템이 침묵할 수 있는 유일한 문은 분석 실패(NO_BASIS) 하나뿐이었다.
//
// 그래서 네 번째 조건을 넣는다. 두 사실이 겹치는 자리다.
//   - requestLevel 2 = 근거 레이어(문서·Jira·다른 스레드·리서치)가 한 줄도 기여하지 않았다.
//   - noRequestSignal = 상대가 묻지도, 요청하지도, 막혀 있다고도 하지 않았다.
// 둘이 겹치면 이 글이 원문에 없던 것을 담을 방법이 구조적으로 없다. 남는 것은 재진술뿐이다.
// 판정은 여기서도 결정적이다 — noRequestSignal 은 emoji-layer 의 vetoReason 이 돌려준
// 사실이고, 모델의 의견이 아니다.
export const ACK_MIN_CONFIDENCE = 0.8;

// 조회가 "실패"한 상태. 권한 등급으로 일부러 뺀 것(withheld)과 애초에 조회할 것이
// 없던 것(스레드에 링크가 없음)은 실패가 아니다 — 그것까지 실패로 세면 거의 모든
// 메시지가 막혀서 게이트가 아니라 스위치가 된다.
const EVIDENCE_FAILURE_RE = new RegExp(
  'unavailable'
  + '|missing\\s+integration\\s+token'
  + '|integration\\s+token'
  + '|읽지\\s*못함'
  + '|토큰이?\\s*없음'
  + '|조회\\s*(?:에\\s*)?실패'
  + '|lookup\\s+failed'
  + '|시간\\s*초과'
  + '|timed?\\s*out', 'i');

const EVIDENCE_NOT_APPLICABLE_RE = new RegExp(
  'withheld'
  + '|조회하지\\s*않음'
  + '|노션\\s*링크가\\s*없음'
  + '|등록된\\s*이름\\s*대응이\\s*없음'
  + '|해당하는\\s*이름\\s*대응\\s*없음', 'i');

// 실패했을 때 발신을 막는 레이어. 문서(documents)는 상대가 이 스레드에 직접 붙인
// 근거다 — 그것을 못 읽고 답하는 것이 이번 사고의 본체이므로 여기만 차단 대상이다.
// jira·research·related 는 평소에도 권한이나 무관함으로 자주 비므로 차단하지 않고,
// 대신 아래 누출 검사가 그 실패 문구가 글에 실려 나가는 것을 막는다.
const BLOCKING_LAYERS = ['documents'];

export function evidenceFailures(extra = {}, jira = '') {
  const rows = {
    documents: extra.notion,
    jira,
    related: extra.related,
    research: extra.research,
    glossary: extra.glossary,
    attachments: extra.attachments,
  };
  const failed = [];
  for (const [layer, value] of Object.entries(rows)) {
    const s = clean(value);
    if (!s) continue;
    if (EVIDENCE_NOT_APPLICABLE_RE.test(s)) continue;
    if (EVIDENCE_FAILURE_RE.test(s)) failed.push(layer);
  }
  return failed;
}

// 근거 레이어의 실패 문구가 완성된 글에 그대로 실려 나간 것이 이번 사고의 눈에 보이는
// 증상이었다. 레이어별 차단과 별개로, 나갈 글 자체를 한 번 더 읽어 내부 사정이
// 새어 나가면 막는다. 새 레이어가 늘어도 이 검사는 그대로 적용된다.
const LEAK_RE = new RegExp(
  'integration\\s+token'
  + '|api\\s+key'
  + '|notion\\s+lookup'
  + '|jira\\s+lookup'
  + '|lookup\\s+is\\s+unavailable'
  + '|통합\\s*토큰'
  + '|키체인'
  + '|조회\\s*(?:에\\s*)?실패', 'i');

// ---- 채널 해석 · 확신 산정의 필수 입력 ---------------------------------------
//
// 2026-09-02 사고. Danny 의 DM(D0BTN09CX6Z)에 "MPC 컴플라이언스 문서를 만들어야 하는
// 것이 맞냐"는 물음이 왔고, 라이언 이름으로 이 글이 나갔다.
//
//   "Yes, you need to create the compliance documents for MPC as mentioned in the earlier
//    message regarding team resource management. Assumed the user is Danny seeking
//    confirmation on the task assigned in the recent channel context."
//
// 이 글은 그때의 게이트를 전부 통과했다. 확신은 높았고, 근거 조회는 실패하지 않았고,
// 새는 것도 없었고, 신규성도 있었다. 게이트가 잡지 못한 것은 셋이다.
//
//   1. 자리를 몰랐다. 이 대화가 어느 프로젝트의 일인지 코드가 한 번도 묻지 않았다.
//      channelName 은 그때까지 sensitiveContext() 에만 쓰였고 확신 산정에는 들어가지
//      않았다. 확신은 모델의 자가 신고값 하나였다.
//   2. 화제가 섞인 것을 알면서 그것을 근거로 삼았다. 컨텍스트 헤더에
//      "[Slack recent channel context — may contain mixed topics; not a thread]" 가
//      붙어 있었고, 나간 글은 그 안의 다른 화제를 "the earlier message" 로 가리켰다.
//   3. 용어를 밖에서 해석했다. 요청자 등급 판정에는 'Global MPC 등급 2' 가 이미
//      쓰였는데, 같은 건의 리서치 질의는 'multi-party computation technology' 였다.
//
// 그래서 확신을 하나의 값이 아니라 곱으로 바꾼다.
//
//   effective = analysis.confidence × channelFactor × contextFactor
//
// 채널을 소속 폴더로 해석하지 못하면 channelFactor 가 0 이고, 곱이 0 이므로 임계값
// 0.8 을 넘을 방법이 정의상 없다. 규칙을 하나 더 얹은 것이 아니라 확신의 정의를
// 바꾼 것이다. 표는 slack-outbound-gate.json 에 있다.

const OUTBOUND_GATE_DEFAULT = {
  confidence: { channel: { registry: 1, named: 0.9, unresolved: 0 }, context: { thread: 1, mixedTopic: 0.85 } },
  channels: {},
  namePrefixes: [],
  ambiguousTerms: [],
};

// 번들 옆의 정본과, 앱을 다시 빌드하지 않고 늘릴 수 있는 런타임 파일. 뒤가 앞을 덮는다.
export const OUTBOUND_GATE_FILES = [
  fileURLToPath(new URL('./slack-outbound-gate.json', import.meta.url)),
  join(homedir(), '.condition-mate', 'slack-translate', 'outbound-gate.json'),
];

let outboundGateCache = null;
export function outboundGatePolicy() {
  if (outboundGateCache) return outboundGateCache;
  const merged = { ...OUTBOUND_GATE_DEFAULT, channels: {}, namePrefixes: [], ambiguousTerms: [] };
  for (const path of OUTBOUND_GATE_FILES) {
    let row = null;
    try { row = JSON.parse(readFileSync(path, 'utf8')); } catch { continue; }
    if (!row || typeof row !== 'object') continue;
    merged.confidence = {
      channel: { ...merged.confidence.channel, ...(row.confidence?.channel || {}) },
      context: { ...merged.confidence.context, ...(row.confidence?.context || {}) },
    };
    Object.assign(merged.channels, row.channels || {});
    if (Array.isArray(row.namePrefixes)) merged.namePrefixes = row.namePrefixes.concat(merged.namePrefixes);
    if (Array.isArray(row.ambiguousTerms)) merged.ambiguousTerms = row.ambiguousTerms.concat(merged.ambiguousTerms);
  }
  outboundGateCache = merged;
  return merged;
}

// 표를 고친 뒤 같은 프로세스에서 다시 읽게 하는 자리. 테스트와 데몬의 설정 재적재용.
export function resetOutboundGatePolicy() { outboundGateCache = null; }

// DM 은 사람의 자리이지 프로젝트의 자리가 아니다. 담당 폴더가 없고, 그래서 이 글이
// 어느 일에 대한 것인지 코드가 확인할 방법이 없다. 사고가 난 자리가 정확히 여기다.
// (#mpdm-… 은 슬랙이 다자간 DM 에 붙이는 채널 이름이라 # 로 시작하지만 DM 이다.)
const DM_CHANNEL_RE = /^(?:dm(?:\s|·|$)|그룹\s*dm|#?mpdm-)/i;
const NAMED_CHANNEL_RE = /^#[\p{L}\p{N}][\p{L}\p{N}._-]*$/u;

const normalizeName = (s) => clean(s).replace(/^#+/, '').toLowerCase();

// 채널 ID → 채널 이름 → 소속 프로젝트 폴더. 사슬이 어디서 끊겼는지를 tier 로 돌려준다.
export function resolveChannel({ channelId = '', channelName = '', channelProject = null } = {}) {
  const id = clean(channelId);
  const name = clean(channelName);
  const given = clean(channelProject);
  if (given) return { tier: 'registry', id, name: name || id, folder: given, via: 'caller' };

  const policy = outboundGatePolicy();
  const byId = id ? policy.channels?.[id] : null;
  if (byId?.folder) return { tier: 'registry', id, name: byId.name || name || id, folder: byId.folder, via: `id:${id}` };

  const key = normalizeName(name);
  if (key) {
    for (const [rowId, row] of Object.entries(policy.channels || {})) {
      if (row?.folder && normalizeName(row.name) === key) {
        return { tier: 'registry', id: id || rowId, name: row.name, folder: row.folder, via: `name:${row.name}` };
      }
    }
  }

  // DM 판정은 접두 규칙보다 먼저 선다. 위의 등록표에 명시적으로 적힌 DM 만 폴더를
  // 가질 수 있고, 그 밖의 DM 은 어떤 규칙으로도 폴더에 닿지 않는다.
  if (!name) return { tier: 'unresolved', id, name: '', folder: null, why: 'no-name' };
  if (DM_CHANNEL_RE.test(name)) return { tier: 'unresolved', id, name, folder: null, why: 'dm' };

  for (const row of policy.namePrefixes || []) {
    const prefix = normalizeName(row?.prefix);
    if (!prefix || !row?.folder) continue;
    if (key.startsWith(prefix)) {
      return { tier: 'registry', id, name, folder: row.folder, via: `prefix:${row.prefix}` };
    }
  }

  if (NAMED_CHANNEL_RE.test(name)) {
    return { tier: 'named', id, name, folder: null, why: 'no-folder-row' };
  }
  return { tier: 'unresolved', id, name, folder: null, why: 'not-a-channel-name' };
}

// 근거가 스레드인가, 화제가 섞인 채널 최근 대화인가. 표식 문자열은 데몬의
// gatherContext 가 붙이는 것과 같은 것이고, 여기서는 읽기만 한다.
export function contextProvenance(context = '') {
  const s = String(context || '');
  const thread = /\[Slack thread context/i.test(s);
  const mixed = /\[Slack recent channel context/i.test(s);
  return { thread, mixed, mixedTopicOnly: mixed && !thread };
}

// 화제가 섞인 것을 알면서 그 안의 다른 화제를 가리키는 문장. 나간 글의
// "as mentioned in the earlier message" 가 이것이다.
const PRIOR_REF_RE = new RegExp(
  'as\\s+mentioned'
  + '|mentioned\\s+(?:above|earlier|before)'
  + '|the\\s+(?:earlier|previous|above|last)\\s+message'
  + '|in\\s+the\\s+recent\\s+channel\\s+context'
  + '|per\\s+the\\s+(?:earlier|previous)'
  + '|위\\s*(?:의\\s*)?메시지|앞선?\\s*메시지|위에서\\s*(?:말|언급)', 'i');

// 유보(헤지) 표현. 헤지는 커뮤니케이션 코스트를 줄이지 않는다 — 확인을 상대에게
// 떠넘겨 오히려 늘린다. 반쯤 확신한 글은 나가는 것이 아니라 서지 않는 것이 맞다.
const HEDGE_RE = new RegExp(
  '\\bassum(?:e|ed|ing|ption)\\b'
  + '|\\bi\\s+(?:believe|think|assume|guess|suppose)\\b'
  + '|\\bpresumably\\b'
  + '|\\bif\\s+i\\s+understand\\b'
  + '|\\bplease\\s+(?:verify|confirm|double[-\\s]?check)\\b'
  + '|\\b(?:may|might)\\s+not\\s+be\\s+(?:accurate|correct|right)\\b'
  + '|\\bnot\\s+(?:entirely\\s+|fully\\s+|100%\\s+)?(?:sure|certain)\\b'
  + '|\\bcorrect\\?\\s*$'
  + '|아마도|추정(?:됩니다|된다|컨대)|가정(?:하|한|합|컨대)'
  + '|확실하지\\s*않|정확하지\\s*않을\\s*수|틀릴\\s*수\\s*있|아닐\\s*수\\s*있'
  + '|확인\\s*(?:해\\s*주시기\\s*)?부탁|확인\\s*(?:해\\s*)?바랍|맞는지\\s*확인', 'i');

export function hedgeHits(body) {
  const m = HEDGE_RE.exec(clean(body));
  return m ? [m[0].trim()] : [];
}

const escapeRe = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// 조직 안에서만 뜻이 정해지는 약어. 용어집이 실제로 그 이름을 해석해 주지 않았는데
// 그 약어가 나갈 글에 실려 있으면, 그 글은 밖의 뜻으로 쓰였을 수 있다. 2026-09-02
// 건에서 'MPC' 가 Multi-Party Computation 으로 읽힌 자리다.
export function unresolvedTerms(body, glossary = '') {
  const text = String(body || '');
  if (!text) return [];
  const g = clean(glossary);
  const glossaryUsable = Boolean(g) && !EVIDENCE_NOT_APPLICABLE_RE.test(g) && !EVIDENCE_FAILURE_RE.test(g);
  const hits = [];
  for (const row of outboundGatePolicy().ambiguousTerms || []) {
    const term = clean(typeof row === 'string' ? row : row?.term);
    if (!term) continue;
    const bounded = new RegExp(`(?:^|[^\\p{L}\\p{N}])${escapeRe(term)}(?![\\p{L}\\p{N}])`, 'u');
    if (!bounded.test(text)) continue;
    const okWhen = (typeof row === 'object' && Array.isArray(row.okWhen)) ? row.okWhen : [];
    if (okWhen.some((p) => new RegExp(escapeRe(p), 'iu').test(text))) continue;
    if (glossaryUsable && new RegExp(escapeRe(term), 'iu').test(g)) continue;
    hits.push(term);
  }
  return hits;
}

// ---- 못 보낼 때 갈 곳 ---------------------------------------------------------
//
// 막다른 길을 만들면 사람이 규칙을 우회한다. 차단은 침묵이 아니라 방향 전환이어야
// 하므로, 차단 판정은 반드시 행선지를 같이 돌려준다. 행선지는 셋뿐이다.
//
//   escalate-to-ryan  사람이 봐야만 정해지는 것. 자동으로 어디로도 보내지 않는다.
//   route-to-folder   이 채널의 담당 폴더가 있다. 그 폴더의 세션이 받는다.
//   queue             아무도 깨우지 않고 원장에만 담는다.
//
// 실제 배달은 파일 한 줄이다. 새 슬랙 발신 경로를 여기서 만들지 않는다 — 차단을
// 고치려고 새 발신 경로를 여는 것은 같은 사고를 다른 문으로 다시 내는 것이다.
export const ACK_FALLBACK_LEDGER =
  join(homedir(), '.condition-mate', 'slack-translate', 'ack-fallback.jsonl');

const ESCALATE_REASON_RE = /^(?:SENSITIVE_CONTEXT|INTERNAL_STATE_LEAK|ANALYSIS_SCAFFOLD_LEAK|SECURITY)/;
const ASKED_RE = /[?？]|\bplease\b|\bcould\s+you\b|\bcan\s+you\b|부탁|해\s*주세요|알려\s*주/i;

export function fallbackRouteFor({ reasons = [], channel = null, sourceText = '' } = {}) {
  if (!reasons.length) return null;
  if (reasons.some((r) => ESCALATE_REASON_RE.test(String(r)))) {
    return { route: 'escalate-to-ryan', target: ACK_FALLBACK_LEDGER,
      why: '사람의 신분·보상·보안이 걸린 자리다 — 자동으로 다른 곳에 넘기지 않는다' };
  }
  if (channel?.folder) {
    return { route: 'route-to-folder', target: channel.folder,
      why: '이 채널의 담당 폴더가 등록표에 있다' };
  }
  if (ASKED_RE.test(String(sourceText || ''))) {
    return { route: 'escalate-to-ryan', target: ACK_FALLBACK_LEDGER,
      why: '상대가 물었는데 답할 자리를 정할 수 없다 — 물음을 버리지 않는다' };
  }
  return { route: 'queue', target: ACK_FALLBACK_LEDGER,
    why: '묻지 않았고 담당 폴더도 없다 — 원장에만 담고 아무도 깨우지 않는다' };
}

// 하나의 판정을 돌려준다. send 가 false 면 어떤 경우에도 발신하지 않는다.
// reasons 는 그대로 원장에 남아 "왜 안 나갔는지" 를 나중에 되짚는 근거가 된다.
export function ackSendGate({ analysis, extra = {}, jira = '', body = '', minConfidence = ACK_MIN_CONFIDENCE,
  requestLevel = null, noRequestSignal = null,
  channelId = '', channelName = '', channelProject = null,
  sourceText = '', context = '', files = [], sensitivePolicyFiles = [],
  thread = null, threadAfter = '', noveltyOverlapMax = NOVELTY_OVERLAP_MAX } = {}) {
  const reasons = [];
  const min = Number.isFinite(Number(minConfidence)) ? Number(minConfidence) : ACK_MIN_CONFIDENCE;

  // 0) 자리. 채널 ID → 채널 이름 → 소속 프로젝트 폴더. 이 사슬이 어디서 끊겼는지가
  //    아래 확신 산정에 그대로 곱해진다. 별도의 규칙을 하나 더 얹는 것이 아니라,
  //    자리를 모르는 상태에서는 확신이라는 말이 성립하지 않게 만드는 자리다.
  const channel = resolveChannel({ channelId, channelName, channelProject });
  const provenance = contextProvenance(context);
  const weights = outboundGatePolicy().confidence;
  const factors = {
    channel: Number(weights?.channel?.[channel.tier] ?? 0),
    context: provenance.mixedTopicOnly
      ? Number(weights?.context?.mixedTopic ?? 0.85)
      : Number(weights?.context?.thread ?? 1),
  };
  if (channel.tier === 'unresolved') reasons.push(`UNRESOLVED_CHANNEL:${channel.why}`);

  // 1) 확신. 모델의 자가 신고값 하나가 아니라 곱이다. 값이 없으면 "80% 이상이라는
  //    근거가 없는 것"이므로 막는다. 낮게 부르는 것이 옳은 행동이라고 계약에 적어
  //    두었으므로, 빈 값은 겸손이 아니라 미준수다.
  const raw = analysis?.confidence;
  const conf = typeof raw === 'number' ? raw : Number(raw);
  const effective = Number.isFinite(conf)
    ? Number((conf * factors.channel * factors.context).toFixed(3))
    : null;
  if (!Number.isFinite(conf)) reasons.push('NO_CONFIDENCE');
  else if (effective < min) {
    reasons.push(`LOW_CONFIDENCE:${effective.toFixed(2)}<${min}`
      + `(self ${conf.toFixed(2)}*ch ${factors.channel}[${channel.tier}]*ctx ${factors.context})`);
  }

  // 2) 근거 조회 실패.
  const failed = evidenceFailures(extra, jira);
  for (const layer of failed) {
    if (BLOCKING_LAYERS.includes(layer)) reasons.push(`EVIDENCE_LOOKUP_FAILED:${layer}`);
  }

  // 3) 내부 사정 누출.
  if (LEAK_RE.test(clean(body))) reasons.push('INTERNAL_STATE_LEAK');

  // 4) 정보 증분. true 로 명시됐을 때만 막는다 — 이모지 레이어가 없거나 판정을 못 하면
  //    null 이 오고, 그때는 예전처럼 나간다. 모르면 조용해지는 쪽이 아니라 원래 하던
  //    대로 하는 쪽으로 넘어가는 것이 이 코드베이스의 규칙이다.
  const level = Number(requestLevel);
  if (noRequestSignal === true && Number.isFinite(level) && level <= 2) {
    reasons.push('NO_INFORMATION_GAIN');
  }

  // 5) 분석 스캐폴딩 누출. 추출 스키마의 필드 라벨이 wire 에 닿으면 막는다. 어느
  //    렌더러가 만들었는지, 모델이 직접 뱉었는지를 따지지 않는다 — 인스턴스가 아니라
  //    부류를 잡는 자리다. v1 렌더러의 출력은 정의상 전부 여기서 걸린다.
  const scaffold = scaffoldLeaks(body);
  for (const label of scaffold) reasons.push(`ANALYSIS_SCAFFOLD_LEAK:${label}`);

  // 6) 발신해서는 안 되는 자리. 사람의 신분·보상·분쟁·건강이 걸린 스레드에서는 글의
  //    품질과 무관하게 기계가 먼저 말하지 않는다. 응답 정책이 채널 ID 거부 목록이라
  //    어제 만들어진 그룹 DM 을 담을 수 없었던 것이 이번 사고의 자리 쪽 원인이다.
  const sensitive = sensitiveContext({
    channelName, text: sourceText, context, files, policyFiles: sensitivePolicyFiles,
  });
  if (sensitive.domain) reasons.push(`SENSITIVE_CONTEXT:${sensitive.domain}`);

  // 7) 신규성. 축 1이 한 등급 올라가려면 스레드에 아직 없는 무엇을 더하는지를 이름으로
  //    댈 수 있어야 한다 (설계 §1). 후보 글의 실질이 이미 스레드에 있으면 — 특히 그
  //    물음 뒤에 나온 메시지에 있으면 — 발신하지 않는다. Maryam 건이 정확히 그 자리다.
  //
  //    thread 를 넘기지 않으면(null) 이 항목은 서지 않는다. 이모지 레이어나 컨텍스트가
  //    없을 때 조용해지는 쪽이 아니라 원래 하던 대로 하는 쪽으로 넘어가는 것이 이
  //    코드베이스의 규칙이고, 위 4)번 항목과 같은 규칙이다.
  //
  //    아래 echo 값(send-layer.mjs)과 겹쳐 보이지만 재는 것이 다르다. echo 는 원문 한
  //    건과의 되풀이 비율을 측정만 하고, 이 항목은 스레드 전체·이후 메시지와 견주며
  //    어형까지 맞춰 보고 실제로 막는다.
  let novelty = null;
  if (thread !== null && thread !== undefined) {
    novelty = noveltyVerdict({
      body, thread, after: threadAfter, adds: analysis?.adds, overlapMax: noveltyOverlapMax,
    });
    if (!novelty.novel) {
      reasons.push(`NO_NOVELTY:${novelty.reason}`
        + `${novelty.overlap === null ? '' : `:${novelty.overlap}`}`);
    }
  }

  // 8) 유보(헤지) 표현. 반쯤 확신한 글은 밝히고 보내는 것이 아니라 서지 않는 것이
  //    맞다. 헤지는 확인하는 일을 상대에게 넘기므로 코스트를 줄이지 않고 늘린다.
  const hedges = hedgeHits(body);
  if (hedges.length) reasons.push(`HEDGED_BODY:${hedges[0]}`);

  // 9) 섞인 화제를 근거로 가리켰다. 코드가 "화제가 섞여 있다" 고 스스로 적어 둔
  //    컨텍스트를 근거로 "앞선 메시지에서 말한 대로" 라고 쓰면, 그 앞선 메시지가
  //    이 물음의 것이라는 보장이 아무 데도 없다. 2026-09-02 건이 정확히 그 모양이다.
  if (provenance.mixedTopicOnly && PRIOR_REF_RE.test(clean(body))) reasons.push('MIXED_TOPIC_REFERENCE');

  // 10) 밖에서 해석된 조직 약어. 용어집이 그 이름을 해석해 주지 않았는데 그 약어가
  //     글에 실려 있으면, 그 글은 공개 웹의 뜻으로 쓰였을 수 있다.
  const terms = unresolvedTerms(body, extra.glossary);
  for (const t of terms) reasons.push(`TERM_UNRESOLVED:${t}`);

  return {
    send: reasons.length === 0,
    reasons,
    confidence: Number.isFinite(conf) ? conf : null,
    // 실제로 임계값과 견준 값. 원장에는 자가 신고값과 이 값을 같이 남긴다 — 둘이
    // 갈라진 폭이 곧 "자리를 몰라서 깎인 양" 이다.
    effectiveConfidence: effective,
    confidenceFactors: factors,
    channel,
    contextProvenance: provenance,
    hedges,
    terms,
    failedLayers: failed,
    novelty,
    scaffold,
    sensitive: sensitive.domain || null,
    sensitiveHit: sensitive.hit || null,
    sensitiveWhere: sensitive.where || null,
    // 차단하지 않는다. 값만 남겨 임계값의 근거를 모은다 (send-layer.mjs 주석 참조).
    echo: sourceText ? echoRatio(body, sourceText) : null,
    // 막다른 길을 만들지 않는다. 차단은 침묵이 아니라 방향 전환이다.
    fallbackRoute: fallbackRouteFor({ reasons, channel, sourceText }),
  };
}
