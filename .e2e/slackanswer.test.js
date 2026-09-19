// E2E for 선응답(ack)의 컨텍스트 레이어 — 용어집 · 공유 문서 · 공개 웹 리서치 ·
// 다른 스레드 · 권한 등급. slackmedia.test.js 와 같은 방식으로 slack-eyes-daemon.mjs 에서
// 진짜 함수를 떼어내 돌리고, answer-context.mjs 는 실제 모듈을 그대로 import 한다.
//
// 이 시험이 지키려는 것 (2026-08-29 실제 사고 두 건):
//   1) 스레드에 노션 문서를 붙여 놓고도 "문서 확인해 보겠다"고 답한 건
//      → 공유 문서가 프롬프트에 실리는가
//   2) "Bolor Geo SG 서류는 있는데 MPC SG 서류가 없다" — 둘은 같은 법인이었다
//      → 용어집이 그 대비를 잡아내는가 (이게 첫 레이어여야 한다)
// 그리고 레이어가 늘어난 만큼 무너지지 않는지도 본다: 하나가 실패해도 선응답은 나가고,
// 권한으로 빠진 근거는 빈 값이 아니라 "withheld" 로 남는다.
const { readFileSync } = require('node:fs');

const DAEMON_DIR = __dirname + '/../Sources/Plugins/Slack/Daemon/';
const SRC = readFileSync(DAEMON_DIR + 'slack-eyes-daemon.mjs', 'utf8');

function fn(name) {
  let start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  if (SRC.slice(start - 6, start) === 'async ') start -= 6;
  let paren = 0, i = SRC.indexOf('(', start);
  for (; i < SRC.length; i++) { if (SRC[i] === '(') paren++; else if (SRC[i] === ')') { paren--; if (!paren) break; } }
  let d = 0;
  for (let k = SRC.indexOf('{', i); k < SRC.length; k++) {
    if (SRC[k] === '{') d++; else if (SRC[k] === '}') { d--; if (!d) return SRC.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

let fails = 0;
const ok = (c, m, extra) => { console.log((c ? '  ok   ' : '  FAIL ') + m + (extra ? '  ' + extra : '')); if (!c) fails++; };

// 데몬의 마감 타이머는 unref 되어 있다 (운영에서는 폴링 루프가 이벤트 루프를 잡고
// 있으므로 정상). 이 시험은 그 루프가 없어 타이머가 뜨기 전에 node 가 끝나 버리므로
// keepalive 를 하나 걸어 둔다.
const keepalive = setInterval(() => {}, 50);

(async () => {
const AC = await import(DAEMON_DIR + 'answer-context.mjs');
const POLICY = [DAEMON_DIR + 'slack-permission-policy.json'];
const GLOSSARY = [DAEMON_DIR + 'slack-glossary.json'];

// 사고 당시의 실제 문장 (사람 이름·링크는 그대로 두되 시험 안에서만 쓴다).
const SHAROON = 'U041F5CDH7T';
const MSG = 'Yes! it has documents related to Bolor Geo SG but not MPC SG. '
  + 'I got an understanding that we want to create a corporate credit card for MPC SG not Bolor Geo SG.';
const CTX = '[Slack thread context — same topic]\n'
  + 'Lion cho: https://app.notion.com/p/mustcompany/Company-document-Singpaore-3c49c2703c3f80b5a276d06a55007546?source=copy_link\n'
  + 'Sharoon Raza: Do we have any documents for MPC?';

// --------------------------------------------------------------- 1. 권한 등급
const a9 = AC.resolveAccess({ userId: SHAROON, text: MSG, ctx: CTX, policyFiles: POLICY });
ok(a9.level === 9 && a9.domain === 'globalmpc', 'Global MPC 담당자는 그 도메인에서 9등급', `${a9.domain}/${a9.level}`);
ok(Object.values(a9.sources).every(Boolean) && a9.withheld.length === 0, '9등급은 네 근거를 모두 조회한다');

const aOther = AC.resolveAccess({ userId: SHAROON, text: 'BGM 재생이 안 됩니다', ctx: '', policyFiles: POLICY });
ok(aOther.level === 2 && aOther.domain === 'general', '도메인이 다르면 높은 등급이 따라오지 않는다', `${aOther.domain}/${aOther.level}`);

const aNew = AC.resolveAccess({ userId: 'UNOBODY', text: MSG, ctx: CTX, policyFiles: POLICY });
ok(aNew.level === 2 && aNew.sources['notion-shared'] && aNew.sources.research,
  '명부에 없는 사람도 기본 2등급 — 이미 공유된 문서와 공개 웹은 본다');
ok(!aNew.sources.jira && !aNew.sources.related, '기본 등급은 Jira·다른 스레드를 조회하지 않는다', aNew.withheld.join(','));
ok(AC.withheldNote('Jira lookup', aNew).includes('withheld'), '빠진 근거는 빈 값이 아니라 withheld 문구로 남는다');

// --------------------------------------------------------------- 2. 용어집
const gConflict = AC.glossaryContext({ text: MSG, ctx: CTX, files: GLOSSARY });
ok(gConflict.includes('같은 대상이다'), '스레드에 나온 이름의 대응이 실린다');
ok(gConflict.includes('※'), '한 메시지가 같은 대상을 두 이름으로 대비하면 그 사실을 표시한다');
ok(gConflict.includes('Bolor Geo SG') && gConflict.includes('MPC SG'), '대비된 두 이름을 그대로 짚는다');

const gSingle = AC.glossaryContext({ text: 'Do we have any documents for Bolor Geo SG?', files: GLOSSARY });
ok(gSingle.includes('같은 대상이다') && !gSingle.includes('※'),
  '이름 하나만 쓰였으면 별칭 중복(Bolor Geo/Bolor Geo SG) 때문에 오탐하지 않는다');
ok(AC.glossaryContext({ text: 'Where is the homepage?', files: GLOSSARY }).includes('해당하는 이름 대응 없음'),
  '무관한 메시지에는 용어집이 끼어들지 않는다');
ok(AC.glossaryContext({ text: MSG, files: [] }).includes('등록된 이름 대응이 없음'),
  '용어집 파일이 없어도 터지지 않는다');
ok(!AC.glossaryContext({ text: MSG, level: 0, files: GLOSSARY }).includes('Bolor Geo SG Pte'),
  '등급이 모자라면 그 용어는 실리지 않는다');

// --------------------------------------------------------------- 2.5 노션 동기화
// 사람이 노션 불릿에 적는 줄 → 용어집 항목. 이 왕복이 깨지면 이름을 아무리 적어도
// 데몬이 못 읽는다.
const parsed = AC.parseGlossaryLines([
  '- Bolor Geo SG Pte. Ltd. = Bolor Geo SG = MPC SG — 같은 싱가폴 법인이다.',
  '• ACME Corp = 에이크미 — 등급 있는 줄 (level 5)',
  '- 이름이 하나뿐이면 대응표가 아니다',
  '',
  '설명 없이 이름만 = Alias',
]);
ok(parsed.length === 3, '이름이 둘 이상인 줄만 용어가 된다', String(parsed.length));
ok(parsed[0].canonical === 'Bolor Geo SG Pte. Ltd.' && parsed[0].aliases.join(',') === 'Bolor Geo SG,MPC SG',
  '첫 이름이 정본, 나머지가 별칭', JSON.stringify(parsed[0].aliases));
ok(parsed[0].note.includes('싱가폴 법인') && parsed[0].minLevel === 1, '설명은 — 뒤, 등급을 안 적으면 1');
ok(parsed[1].minLevel === 5 && !parsed[1].note.includes('level'), '(level N) 은 등급으로 떼어 내고 설명에 남기지 않는다', parsed[1].note);
ok(parsed[2].note === '', '설명이 없어도 용어로 성립한다');

const round = AC.glossaryContext({ text: 'Bolor Geo SG 랑 MPC SG 차이가 뭐죠', level: 9, files: [] });
ok(round.includes('등록된 이름 대응이 없음'), '파일이 없으면 오탐 없이 없다고 말한다');

const noTok = await AC.syncGlossaryFromNotion({ token: null, page: 'https://notion.so/x' });
ok(!noTok.ok && noTok.error.includes('토큰'), '토큰이 없으면 동기화하지 않고 사유를 남긴다');
const noPage = await AC.syncGlossaryFromNotion({ token: 't', page: '' });
ok(!noPage.ok && noPage.error.includes('페이지'), '페이지를 안 정했으면 동기화하지 않는다 (씨앗으로 계속 돈다)');
const badId = await AC.syncGlossaryFromNotion({ token: 't', page: 'https://example.com/not-notion' });
ok(!badId.ok && badId.error.includes('id'), '노션 주소가 아니면 id 를 못 읽었다고 말한다');

// --------------------------------------------------------------- 3. 노션 링크
const refs = AC.notionPageRefs(CTX);
ok(refs.length === 1 && refs[0].id === '3c49c270-3c3f-80b5-a276-d06a55007546',
  '노션 URL 에서 페이지 id 를 뽑는다 (쿼리스트링 제외)', JSON.stringify(refs));
ok(AC.notionPageRefs('https://example.com/x').length === 0, '노션이 아닌 링크는 줍지 않는다');
const noToken = await AC.notionContext({ text: MSG, ctx: CTX, token: null });
ok(noToken.includes('토큰이 없음') && noToken.includes('notion.com'),
  '토큰이 없으면 조용히 비우지 않고 사유와 링크를 남긴다');
ok((await AC.notionContext({ text: '문서 없음', ctx: '' })).includes('노션 링크가 없음'),
  '링크가 없을 때와 못 읽을 때를 구분해 말한다');

// --------------------------------------------------------------- 4. 검색어
const terms = AC.searchTerms(MSG);
ok(terms.includes('MPC') && terms.includes('SG'), '세 글자 이하 약어(MPC·SG)가 검색어에서 빠지지 않는다', terms.join(','));
ok(!terms.some((t) => ['thank', 'sharing', 'reason'].includes(t.toLowerCase())),
  '스레드를 특정하지 못하는 일반 단어는 검색어에서 뺀다', terms.join(','));

// --------------------------------------------------------------- 5. 다른 스레드
const sameThreadOnly = async () => ({ messages: { matches: [
  { channel: { id: 'CX', name: 'here' }, ts: '999.9', username: 'me', text: '지금 이 스레드', permalink: 'https://x/p999' },
] } });
ok((await AC.relatedThreadContext({ text: MSG, slack: sameThreadOnly, channel: 'CX', threadTs: '999.9' })).includes('관련 내용 없음'),
  '지금 이 스레드는 다른 스레드 근거로 다시 싣지 않는다');
const found = await AC.relatedThreadContext({
  text: MSG, channel: 'CX', threadTs: '999.9',
  slack: async () => ({ messages: { matches: [
    { channel: { id: 'C1', name: 'finance' }, ts: '111.1', username: 'kim', text: 'MPC docs are in the Singapore folder', permalink: 'https://x/p111' },
  ] } }),
});
ok(found.includes('#finance') && found.includes('Singapore folder'), '다른 채널의 스레드는 출처와 함께 싣는다');
const noScope = await AC.relatedThreadContext({
  text: MSG, slack: async () => { throw new Error('slack search.messages: missing_scope'); },
});
ok(noScope.includes('search:read'), '검색 스코프가 없으면 그 사실을 그대로 말한다 (조용히 실패하지 않는다)', noScope);

// --------------------------------------------------------------- 6. 리서치
ok((await AC.researchContext({ text: MSG, ask: async () => 'NONE' })).includes('필요한 요청이 아님'),
  '외부 요건 조사가 필요 없으면 검색 자체를 하지 않는다');
ok((await AC.researchContext({ text: MSG, ask: async () => { throw new Error('model down'); } })).includes('필요한 요청이 아님'),
  '질의 생성이 실패하면 내부 문장을 그대로 검색창에 넣지 않고 건너뛴다');
ok((await AC.researchContext({ text: MSG, ask: null })).includes('unavailable'), 'ask 가 없으면 unavailable 로 남는다');

// --------------------------------------------------------------- 7. ackEvidence
const stubMod = {
  resolveAccess: AC.resolveAccess, withheldNote: AC.withheldNote, glossaryContext: AC.glossaryContext,
  notionContext: async () => '[Notion 문서 · 스레드에 공유됨] "Company document" (본문)',
  researchContext: async () => '[Web research · genspark] 질의: x\n- a — b',
  relatedThreadContext: async () => '[다른 스레드 · #finance] kim: ...',
};
const base = {
  BUNDLED_PERMISSION_POLICY_FILE: POLICY[0], PERMISSION_POLICY_FILE: '/nonexistent.json',
  BUNDLED_GLOSSARY_FILE: GLOSSARY[0], GLOSSARY_FILE: '/nonexistent.json',
  ACK_LAYER_BUDGET_MS: 400,
  notionInstance: () => ({ token: 'secret-notion-token' }),
  ensureKeys: () => {}, log: () => {}, scrubSecrets: (s) => String(s),
  callModel: async () => ({ out: 'q' }), slack: async () => ({ messages: { matches: [] } }),
  jiraProblemContext: async () => 'CM-12: 원래 문제',
};
const build = (over = {}) => {
  const c = { ...base, ...over };
  return new Function(...Object.keys(c), fn('ackEvidence') + '\nreturn ackEvidence;')(...Object.values(c));
};
const item = { textEn: MSG, authorId: SHAROON, channel: 'CX', ts: '9.9', threadTs: '9.9' };

const evNoMod = await build({ answerContextModule: async () => null })(item, CTX);
ok(evNoMod.jira === 'CM-12: 원래 문제' && evNoMod.notion === '' && evNoMod.access === null,
  '모듈이 없으면 선응답은 예전 경로(스레드+Jira) 그대로 — 데몬이 죽지 않는다');

const ev = await build({ answerContextModule: async () => stubMod })(item, CTX);
ok(ev.glossary.includes('※'), '용어집이 가장 먼저, 파일 읽기만으로 실린다');
ok(ev.notion.includes('Notion 문서') && ev.research.includes('genspark'), '문서·리서치 근거가 함께 실린다');
ok(ev.related.includes('이미 근거가 있어 조회하지 않음'),
  '스레드·문서에 근거가 있으면 다른 스레드는 조회하지 않는다 (사용자가 정한 순서)');
ok(ev.access.level === 9, '권한 판정이 결과에 남아 로그로 되짚을 수 있다');

const evThin = await build({
  answerContextModule: async () => ({ ...stubMod, notionContext: async () => '[Notion lookup] 스레드에 공유된 노션 링크가 없음' }),
  jiraProblemContext: async () => '[Jira lookup · x] no matching issue content',
})(item, CTX);
ok(evThin.related.includes('#finance'), '스레드에도 문서에도 Jira에도 없을 때만 다른 스레드를 찾는다');

const evBoom = await build({
  answerContextModule: async () => ({ ...stubMod, notionContext: async () => { throw new Error('notion 500'); } }),
})(item, CTX);
ok(evBoom.notion.includes('실패') && evBoom.research.includes('genspark'),
  '레이어 하나가 터져도 나머지 근거는 살아남는다', evBoom.notion);

const evSlow = await build({
  answerContextModule: async () => ({ ...stubMod, researchContext: () => new Promise(() => {}) }),
})(item, CTX);
ok(evSlow.research.includes('시간 초과') && evSlow.notion.includes('Notion 문서'),
  '한 레이어가 마감을 넘겨도 선응답은 모인 근거로 나간다');

const evLow = await build({ answerContextModule: async () => stubMod })({ ...item, authorId: 'UNOBODY' }, CTX);
ok(evLow.jira.includes('withheld') && evLow.related.includes('withheld'),
  '등급이 낮으면 Jira·다른 스레드는 조회하지 않고 withheld 로 남는다');
ok(evLow.notion.includes('Notion 문서'), '이미 공유된 문서는 등급과 무관하게 읽는다 (새 노출이 아니다)');

// --------------------------------------------------------------- 8. 프롬프트
let captured = '';
// acknowledgementText 는 "근거를 못 찾았다" 를 문장이 아니라 표식(ACK_NO_BASIS)으로
// 돌려준다 — 그 문장이 곧바로 슬랙에 나가지 않고 이모지 레이어를 한 번 더 거치기
// 때문이다 (2026-08-29, slackemoji.test.js). 떼어낸 함수에도 같은 표식을 넣어 준다.
const ACK_NO_BASIS = Symbol('ack-no-basis');
const ALIGN = await import(DAEMON_DIR + 'alignment-engine.mjs');
// ackSendGate·ackConfidenceMin 은 2026-08-31 에 acknowledgementText 안으로 들어왔는데
// 이 주입 스코프가 따라가지 않아 그날부터 이 파일이 ReferenceError 로 죽어 있었다
// (아래 단정 전부가 안 돌고 있었다). 떼어낸 함수가 참조하는 것은 전부 여기 있어야 한다.
// 2026-08-31 두 축 구조: acknowledgementText 는 이름 붙은 인자 하나를 받고,
// 문자열이 아니라 판정이 담긴 객체를 돌려준다.
const ackFn = (callModel) => new Function('callModel', 'ACK_NO_BASIS',
  'extractionPrompt', 'parseExtraction', 'renderReply', 'ackSendGate', 'ackConfidenceMin',
  'SENSITIVE_POLICY_FILES', 'LATEST_REPLY_FORMAT',
  fn('acknowledgementText') + '\nreturn acknowledgementText;')(
  callModel, ACK_NO_BASIS, ALIGN.extractionPrompt, ALIGN.parseExtraction, ALIGN.renderReply,
  ALIGN.ackSendGate, () => 0.8, [], ALIGN.LATEST_REPLY_FORMAT);
const ackText = ackFn(
  async (p) => { captured = p; return { out: JSON.stringify({
    has_basis: true, confidence: 0.95, adds: '두 이름이 같은 법인이라는 사실',
    reply: 'Bolor Geo SG 와 MPC SG 는 같은 법인이라 서류가 빠진 것이 아닙니다.',
    depth: 'R2', detail: '용어집 근거',
  }) }; });
const out = await ackText({ text: MSG, ctx: CTX, thread: CTX, jiraCtx: 'CM-12: 원래 문제',
  extra: { glossary: 'G-BLOCK', notion: 'N-BLOCK', research: 'R-BLOCK', related: 'T-BLOCK' },
  language: 'ko' });
for (const [tag, val] of [['glossary', 'G-BLOCK'], ['documents', 'N-BLOCK'], ['research', 'R-BLOCK'], ['related', 'T-BLOCK']]) {
  ok(captured.includes(`<${tag}>`) && captured.includes(val), `프롬프트에 <${tag}> 근거가 그대로 실린다`);
}
ok(captured.indexOf('<glossary>') < captured.indexOf('<context>'), '용어집이 다른 근거보다 앞에 온다');
ok(out.body === 'Bolor Geo SG 와 MPC SG 는 같은 법인이라 서류가 빠진 것이 아닙니다.',
  '모델이 쓴 문장이 라벨 없이 그대로 나간다', JSON.stringify(out.body));
for (const gone of ['이름 정리:', '목적:', '부합 여부:', 'Purpose:', 'Answer:']) {
  ok(!String(out.body).includes(gone), `나가는 글에 ${gone} 라벨이 없다`);
}

const refusal = ackFn(
  async () => ({ out: JSON.stringify({ has_basis: false }) }));
ok((await refusal({ text: MSG, ctx: CTX, language: 'ko' })) === ACK_NO_BASIS,
  '근거 없음 JSON이면 문장이 아니라 표식을 돌려준다 — 무엇을 할지는 호출부가 정한다');

// adds 가 비면 스레드에 더하는 것이 없다고 모델 스스로 말한 것이다 → R1 강등.
const noAdds = ackFn(
  async () => ({ out: JSON.stringify({ has_basis: true, confidence: 0.99, adds: '', reply: '무언가' }) }));
ok((await noAdds({ text: MSG, ctx: CTX, language: 'ko' })).downgrade === 'R1',
  '무엇을 더하는지 대지 못하면 R1 로 내려간다');

// 신규성 게이트: 스레드에 이미 있는 말을 되풀이하면 막힌다 (2026-08-31 Maryam 건).
const echo = ackFn(
  async () => ({ out: JSON.stringify({ has_basis: true, confidence: 0.95, adds: '서류 상태',
    reply: 'It has documents related to Bolor Geo SG but not MPC SG, and we want a corporate credit card for MPC SG.' }) }));
const blocked = await echo({ text: MSG, ctx: CTX, thread: MSG, language: 'ko' });
ok(blocked.blocked === true && blocked.gate.reasons.some((r) => r.startsWith('NO_NOVELTY')),
  '스레드에 이미 있는 말은 발신되지 않는다', JSON.stringify(blocked.gate?.reasons));

// that 은 지시어이면서 접속사다. 접속사 that 까지 미해결 참조로 세면 영어 문장 거의
// 전부가 Alignment NO 가 되고 "that 이 가리키는 대상을 식별할 수 없다"는 엉뚱한 사유가
// 붙는다 (2026-08-30 재실행에서 실제로 나왔다).
const vague = (t) => ALIGN.alignmentVerdict(
  { has_basis: true, confidence: 0.95, deliverable: 'd', target: 't', owner: 'o', unresolved_references: [] },
  { text: t, context: '', jira: '', extra: {} },
).reasons.some((r) => r.startsWith('NO_UNRESOLVED_SCOPE'));
ok(!vague('I got an understanding that we want to create a card'), '접속사 that 은 미해결 참조가 아니다');
ok(vague('Please update that document'), '지시어 that 은 그대로 잡힌다');
ok(vague('Can you check that'), '문장 끝의 that 도 그대로 잡힌다');
ok(vague('Fix all 10 rows'), '수량 표현은 예전대로 잡힌다');

// 용어집 줄을 통째로 베껴 "A, B, C, D, E, F 는 같은 대상입니다" 로 나가지 않게,
// 이 대화에 실제로 나온 이름만 앞세우고 나머지는 참고용이라고 못 박는다.
const gShape = AC.glossaryContext({ text: MSG, ctx: CTX, files: GLOSSARY });
ok(gShape.includes('이 대화에 나온 이름'), '이 대화에 나온 이름을 따로 앞세운다');
ok(gShape.includes('참고용'), '나머지 별칭은 참고용이라고 표시한다');
ok(gShape.indexOf('이 대화에 나온 이름') < gShape.indexOf('참고용'), '쓸 이름이 참고용 별칭보다 앞에 온다');

// --------------------------------------------------------------- 9. v3 포맷
// 2026-08-31 확정 (docs/slack-ack-two-axis-design.md §3·§7): 나가는 것은 라벨 없는
// 문장뿐이고, 두 줄·280자를 넘으면 잘라 내지 않고 넘친 만큼을 MD 로 보낸다.
let v3prompt = '';
const v3Text = ackFn(async (p) => { v3prompt = p; return { out: JSON.stringify({
  has_basis: true, confidence: 0.95, adds: '원천징수세액이 장부에 아직 반영되지 않았다는 사실',
  reply: '8월분 원천징수세액은 아직 재무 장부에 반영되지 않았습니다.',
  depth: 'R2', detail: '전문은 여기에' }) }; });
const v3 = await v3Text({ text: MSG, ctx: CTX, thread: '', extra: { glossary: 'G-BLOCK' },
  language: 'ko', prior: '[이전 답변 1]\n앞서 보낸 답', persona: 'PERSONA-BLOCK' });
ok(v3.body === '8월분 원천징수세액은 아직 재무 장부에 반영되지 않았습니다.',
  '나가는 것은 모델이 쓴 문장 하나뿐이다', JSON.stringify(v3.body));
for (const gone of ['이렇게 이해했습니다', '에이전트 답변입니다', '*의미 분석*', '*예상 의사결정*',
  '부합 여부', '필요 요건', '충분성', '이름 정리', '문제 정의']) {
  ok(!v3.body.includes(gone), `나가는 글에 ${gone} 가 없다`);
}
ok(v3prompt.startsWith('PERSONA-BLOCK'),
  '페르소나는 프롬프트 첫머리에만 실린다 — 나가는 글의 서두가 아니다');
ok(v3prompt.includes('<prior>') && v3prompt.includes('앞서 보낸 답'),
  '지운 이전 답변이 다음 프롬프트에 실려 내용이 축적된다');
ok(v3prompt.includes('G-BLOCK'), '근거 레이어는 그대로 프롬프트에 실린다');

// 상한: 두 줄 · 280자. 넘치면 잘라 내지 않고 나머지를 통째로 넘긴다.
const longBody = Array.from({ length: 12 }, (_, i) =>
  `문장 ${i + 1} 은 서로 다른 사실을 담고 있어 요약으로 합칠 수 없는 내용입니다.`).join(' ');
const brief = ALIGN.slackBrief(longBody);
ok([...brief.text].length <= 280, '슬랙 본문은 280자를 넘지 않는다', [...brief.text].length + '자');
ok(brief.overflow.length > 0, '넘친 문장은 버려지지 않고 MD 쪽으로 넘어간다');
ok(!brief.text.endsWith('…'), '문장을 잘라 붙이지 않는다');
ok(ALIGN.stripFrames('Hi. 확인 중입니다. 등기부는 3월 12일에 제출되었습니다.')
  === '등기부는 3월 12일에 제출되었습니다.', '인사와 이음말은 문장 단위로 버려진다',
  JSON.stringify(ALIGN.stripFrames('Hi. 확인 중입니다. 등기부는 3월 12일에 제출되었습니다.')));

ok(ALIGN.renderReply({ has_basis: false }, { language: 'ko' }) === null,
  '근거가 없으면 아무것도 만들지 않는다 (이모지 레이어로 넘어간다)');
ok(ALIGN.replyFormat('v1') === 'v1' && ALIGN.replyFormat('v9') === ALIGN.LATEST_REPLY_FORMAT,
  '옛 설정값은 그대로 읽히고, 모르는 값은 최신 포맷으로 떨어진다');

// --------------------------------------------------------------- 10. 스레드 대체
// 한 스레드에 답이 쌓이면 상대는 어느 것이 지금 답인지 알 수 없다. 새 답을 올린 뒤
// 이전 답을 지우고, 지운 내용은 원장에 축적한다.
const mkSupersede = (state, slackImpl) => {
  const store = { value: state };
  const patched = [];
  const fnBody = fn('ackThreadKey') + '\n' + fn('pruneAckThreads') + '\n' + fn('priorAckText') + '\n'
    + fn('supersedePriorAcks') + '\nreturn { supersedePriorAcks, priorAckText };';
  const api = new Function('readAckThreads', 'writeAckThreads', 'slack', 'rewriteItem', 'log',
    'ACK_SUPERSEDE_WINDOW_SEC', 'ACK_PRIOR_MAX', 'ACK_THREAD_TTL_SEC', fnBody)(
    () => JSON.parse(JSON.stringify(store.value)),
    (next) => { store.value = next; },
    slackImpl,
    (id, patch) => patched.push([id, patch]),
    () => {},
    24 * 3600, 3, 7 * 86400);
  return { api, store, patched };
};

const now = Math.floor(Date.now() / 1000);
const threadState = { version: 1, threads: { 'CX:9.9': {
  at: now - 600, posts: [{ ts: '111.1', itemId: 'old-1', at: now - 600 }],
  history: [{ at: now - 600, body: '앞서 보낸 답' }],
} } };
const del = [];
const S1 = mkSupersede(threadState, async (method, params) => { del.push([method, params.ts]); return { ok: true }; });
const removed = await S1.api.supersedePriorAcks({ channel: 'CX', ts: '9.9', threadTs: '9.9', id: 'new-1' }, '새 답', '222.2');
ok(removed === 1 && del[0][0] === 'chat.delete' && del[0][1] === '111.1', '이전 답변은 슬랙에서 지운다');
ok(S1.patched[0][0] === 'old-1' && S1.patched[0][1].ackSupersededAt, '대체된 항목에 표시가 남는다');
const after = S1.store.value.threads['CX:9.9'];
ok(after.posts.length === 1 && after.posts[0].ts === '222.2', '스레드에는 마지막 한 개만 남는다');
ok(after.history.length === 2 && S1.api.priorAckText(after).includes('앞서 보낸 답')
  && S1.api.priorAckText(after).includes('새 답'), '지운 내용은 원장에 축적된다');

const oldState = { version: 1, threads: { 'CX:9.9': {
  at: now - 30 * 3600, posts: [{ ts: '111.1', itemId: 'old-1', at: now - 30 * 3600 }], history: [],
} } };
const del2 = [];
const S2 = mkSupersede(oldState, async (m, p) => { del2.push(p.ts); return { ok: true }; });
ok((await S2.api.supersedePriorAcks({ channel: 'CX', ts: '9.9', id: 'new-2' }, 'x', '333.3')) === 0 && !del2.length,
  '하루가 지난 답변은 지우지 않는다 — 상대가 이미 그것을 보고 움직였을 수 있다');

const S3 = mkSupersede(JSON.parse(JSON.stringify(threadState)), async () => { throw new Error('cant_delete_message'); });
ok((await S3.api.supersedePriorAcks({ channel: 'CX', ts: '9.9', id: 'new-3' }, 'y', '444.4')) === 0
  && S3.store.value.threads['CX:9.9'].posts[0].ts === '444.4',
  '삭제가 실패해도 새 답은 이미 나갔고 원장은 앞으로 나아간다');

const tooLong = ackFn(
  async () => ({ out: 'x'.repeat(2100) }));
ok((await tooLong(MSG, CTX, '', {}, 'ko')) === ACK_NO_BASIS, 'JSON이 아닌 자유형 출력은 판정에 쓰지 않는다');

clearInterval(keepalive);
console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
})();
