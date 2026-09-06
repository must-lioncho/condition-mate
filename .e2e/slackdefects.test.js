// E2E for 번역 품질 결함 8종(A~H) — slack-eyes-daemon.mjs 에서 진짜 함수를 떼어내 돌린다.
//   A 이모지 shortcode 가 문자로 안 풀림      → renderEmoji (커스텀 별칭·skin-tone·순환 별칭)
//   B Slack 마크업 *굵게* 가 그대로 남음      → stripSlackMarkup (조사·곱셈·글롭 구분)
//   C "표시텍스트 (URL)" 중복, 표시가 잘림    → isUrlEcho / cleanText
//   D 영어 원문이 번역 안 된 채 그대로 돌아옴 → qcNotes(untranslated) + 재시도
//   E 모델이 번역을 거부하고 원문을 날림      → meta-refusal / lost / kept-original
//   F ===MEANING=== 마커 결손으로 의미·결정 빔 → findMarker / splitSections 관대화
//   G 퍼머링크로 인용한 원 메시지를 안 읽음   → permalinkRefs / quotedContext
//   H 봇 작성자가 원시 ID로 남고 실패가 캐시됨 → botName / userName
// 코퍼스 실측이 필요한 항목은 ~/.condition-mate/slack-translate/items.jsonl 을 읽되,
// 없으면 그 항목만 건너뛴다(단위 검사는 그대로 돈다). 실 데이터에는 쓰지 않는다.
const { readFileSync } = require('node:fs');
const { homedir } = require('node:os');
const { join } = require('node:path');

const DAEMON_DIR = __dirname + '/../Sources/Plugins/Slack/Daemon/';
// hangulRatio·hasEnglishSentence 는 2026-08-31 에 reply-language.mjs 로 옮겼다 — 수신자
// 언어 판정과 번역 QC 가 서로 다른 잣대를 쓰지 않게 하기 위해서다. 여기서는 두 파일을
// 이어 붙여 예전처럼 이름으로 떼어낸다 (`export ` 는 함수 추출을 막으므로 지운다).
const SRC = readFileSync(DAEMON_DIR + 'slack-eyes-daemon.mjs', 'utf8')
  + '\n' + readFileSync(DAEMON_DIR + 'reply-language.mjs', 'utf8').replace(/^export /gm, '');

function fn(name) {
  let s = SRC.indexOf('function ' + name + '(');
  if (s < 0) throw new Error('no fn ' + name);
  if (SRC.slice(s - 6, s) === 'async ') s -= 6;
  let p = 0, i = SRC.indexOf('(', s);
  for (; i < SRC.length; i++) { if (SRC[i] === '(') p++; else if (SRC[i] === ')') { p--; if (!p) break; } }
  let d = 0;
  for (let k = SRC.indexOf('{', i); k < SRC.length; k++) { if (SRC[k] === '{') d++; else if (SRC[k] === '}') { d--; if (!d) return SRC.slice(s, k + 1); } }
  throw new Error('unbalanced ' + name);
}
function cnst(name) {
  const s = SRC.indexOf('\nconst ' + name + ' =') + 1;
  if (s <= 0) throw new Error('no const ' + name);
  let d = 0;
  for (let k = s; k < SRC.length; k++) {
    const c = SRC[k];
    if ('{[('.includes(c)) d++; else if ('}])'.includes(c)) d--; else if (c === ';' && !d) return SRC.slice(s, k + 1);
  }
  throw new Error('unterminated ' + name);
}
// 정규식 리터럴 안의 괄호는 괄호 세기를 망가뜨린다 — 한 줄짜리 const는 줄로 뜬다.
function line(name) {
  const re = new RegExp('^const ' + name + ' =.*$', 'm');
  const m = re.exec(SRC);
  if (!m) throw new Error('no line const ' + name);
  return m[0];
}
let fails = 0;
const ok = (c, m, extra) => { console.log((c ? '  ok   ' : '  FAIL ') + m + (extra ? '  ' + extra : '')); if (!c) fails++; };
const skip = (m) => console.log('  skip ' + m);
const build = (pre, fns, ctx) => {
  const body = [...pre, ...fns.map(fn)].join('\n') + `\nreturn { ${fns.join(', ')} };`;
  return new Function(...Object.keys(ctx), body)(...Object.values(ctx));
};

// 실 코퍼스는 개발 기계에만 있다 — 없으면 null 로 두고 실측 항목만 건너뛴다.
const CORPUS_FILE = join(homedir(), '.condition-mate/slack-translate/items.jsonl');
let CORPUS = null;
try {
  CORPUS = readFileSync(CORPUS_FILE, 'utf8')
    .split('\n').filter((l) => l.trim()).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
} catch { CORPUS = null; }
console.log(CORPUS ? `(코퍼스 ${CORPUS.length}줄로 실측한다)` : '(코퍼스 없음 — 실측 항목은 건너뛴다)');

(async () => {

console.log('== 번역 기본값·실패 복구 ==');
{
  const D = build([cnst('GEMINI_MODELS')], ['normalizeModel', 'needsTranslationRetry'], {});
  ok(D.normalizeModel(undefined) === 'gemini-flash-lite', '설정이 없으면 Gemini Flash-Lite');
  ok(D.normalizeModel('gemini-2.5-flash-lite') === 'gemini-flash-lite', '구버전 모델 id 마이그레이션');
  ok(D.normalizeModel('haiku') === 'haiku', '유효한 사용자 선택은 보존');
  ok(D.normalizeModel('broken-value') === 'gemini-flash-lite', '손상된 모델 값은 기본값으로 복구');
  ok(D.needsTranslationRetry({ textEn:'hello', pending:true }), '중단된 pending 항목 재시도');
  ok(D.needsTranslationRetry({ textEn:'hello', textKo:'', error:'translate-failed' }), '실패 후 빈 번역 항목 재시도');
  ok(!D.needsTranslationRetry({ textEn:'hello', textKo:'안녕', error:'translate-failed' }), '번역이 있으면 덮어쓰지 않음');
}

console.log('== A. 이모지 shortcode ==');
{
  const alias = [['green-heart', 'green_heart'], ['fire-emoji', 'fire'], ['loopa', 'loopb'], ['loopb', 'loopa']];
  const pre = [cnst('EMOJI'),
    'const __alias = new Map(' + JSON.stringify(alias) + ');',
    'function loadEmojiAliases(){ return Promise.resolve(__alias); }'];
  const D = build(pre, ['renderEmoji'], { log: () => {} });
  ok(await D.renderEmoji('배포 완료 :tada: :white_check_mark:') === '배포 완료 🎉 ✅', '표준 shortcode → 문자');
  ok(await D.renderEmoji(':man-bowing::skin-tone-2: 감사합니다') === '🙇‍♂️ 감사합니다', 'skin-tone 수정자는 제거');
  ok(await D.renderEmoji('고생 :green-heart:') === '고생 💚', '커스텀 별칭이 표준으로 풀린다');
  ok(await D.renderEmoji('x :loopa: y') === 'x :loopa: y', '순환 별칭에서 무한루프에 빠지지 않는다');
  ok(await D.renderEmoji('팀 :li: 확인') === '팀 :li: 확인', '유니코드 대응이 없는 커스텀은 이름 그대로 남긴다');
  ok(await D.renderEmoji('12:30 회의') === '12:30 회의', '시각 표기(12:30)를 이모지로 오인하지 않는다');
  if (!CORPUS) skip('코퍼스 실측: shortcode 해석률');
  else {
    let before = 0, after = 0, lb = 0, la = 0;
    for (const o of CORPUS) {
      const t = String(o.textEn || '');
      const b = t.match(/:[a-z0-9_+-]+:/gi) || [];
      before += b.length; if (b.length) lb++;
      const a = (await D.renderEmoji(t)).match(/:[a-z0-9_+-]+:/gi) || [];
      after += a.length; if (a.length) la++;
    }
    ok(before > 0 && after < before * 0.1,
      `코퍼스 실측: shortcode ${before}건 → ${after}건 (${before ? ((1 - after / before) * 100).toFixed(1) : 0}% 해석), 남은 줄 ${lb} → ${la}`);
  }
}

console.log('== B. Slack 마크업 ==');
{
  const D = build([line('BOLD_RE')], ['stripSlackMarkup'], {});
  ok(D.stripSlackMarkup('*Summary*') === 'Summary', '단독 굵게');
  ok(D.stripSlackMarkup('*팀 OKR*가 취합되었습니다') === '팀 OKR가 취합되었습니다', '한국어 조사가 붙어도 처리 (예전 규칙은 놓쳤다)');
  ok(D.stripSlackMarkup('a *bold* b') === 'a bold b', '문장 중간');
  ok(D.stripSlackMarkup('2*3*4 = 24') === '2*3*4 = 24', '곱셈은 건드리지 않는다');
  ok(D.stripSlackMarkup('rm **/*.js') === 'rm **/*.js', '글롭은 건드리지 않는다');
  ok(D.stripSlackMarkup('a * b * c') === 'a * b * c', '공백에 둘러싸인 별표는 건드리지 않는다');
  ok(D.stripSlackMarkup('R*isk:*') === 'R*isk:*', '원본이 이미 깨진 짝(w*hich…*)은 손대지 않는다');
  ok(D.stripSlackMarkup('*열림 only') === '*열림 only', '짝이 안 맞는 홀수 별표 줄은 통째로 보존');
  ok(D.stripSlackMarkup('*A*\n*B*') === 'A\nB', '여러 줄 각각 처리');
  ok(D.stripSlackMarkup('~취소선~ 유지') === '~취소선~ 유지', '~는 건드리지 않는다 (코퍼스 8건 중 대부분이 근사값 표기)');
  if (!CORPUS) skip('코퍼스 실측: *…* 잔존율');
  else {
    let bl = 0, af = 0;
    for (const o of CORPUS) {
      const t = String(o.textEn || '');
      if (/\*[^*\n]+\*/.test(t)) bl++;
      if (/\*[^*\n]+\*/.test(D.stripSlackMarkup(t))) af++;
    }
    ok(bl > 0 && af < bl * 0.2, `코퍼스 실측: *…* 남은 줄 ${bl} → ${af}`);
  }
}

console.log('== C. "표시텍스트 (URL)" 중복 ==');
{
  const ctx = {
    log: () => {}, userName: async (i) => 'U:' + i, channelName: async (i) => '#' + i,
    usergroupName: async (i) => '@' + i, renderEmoji: async (t) => t,
  };
  const D = build([line('BOLD_RE')], ['isUrlEcho', 'stripSlackMarkup', 'cleanText'], ctx);
  ok(await D.cleanText('보세요 <https://app.notion.com/p/d94a707d0208|app.notion.com/p/…>')
    === '보세요 https://app.notion.com/p/d94a707d0208', '축약 표시는 버리고 전체 URL만 남긴다');
  ok(await D.cleanText('<https://app.notion.com/p/d94|QA 테스트 케이스 트래커>')
    === 'QA 테스트 케이스 트래커 (https://app.notion.com/p/d94)', '사람이 쓴 제목은 URL과 함께 남긴다');
  ok(await D.cleanText('<https://x.com/a|…>') === 'https://x.com/a', '표시가 …뿐이면 URL만');
  ok(await D.cleanText('<mailto:a@b.com|a@b.com>') === 'mailto:a@b.com', '표시와 값이 같으면 하나만');
  if (!CORPUS) skip('코퍼스 실측: 잘린 표시+URL 중복 되짚기');
  else {
    // 이미 저장된 옛 줄에서 "잘린 표시 (URL)" 자리를 찾아 슬랙 원형 <URL|표시> 로 되돌린 뒤
    // 지금 규칙에 다시 통과시킨다. 코퍼스는 계속 늘어나므로 건수를 상수로 박아 두면
    // 며칠 만에 깨진다 — 세어서 보고하고, 합격 판정은 규칙에 대고 한다.
    const ECHO = /([^\s(]+(?:…|\.\.\.))\s*\((https?:\/\/[^)\s]+)\)/g;
    let found = 0, left = 0;
    for (const o of CORPUS) {
      for (const m of String(o.textEn || '').matchAll(ECHO)) {
        found++;
        if (await D.cleanText(`<${m[2]}|${m[1]}>`) !== m[2]) left++;
      }
    }
    ok(found > 0 && left === 0,
      `코퍼스 실측: 옛 줄의 잘린 표시+URL 중복 ${found}건을 지금 규칙에 다시 통과시키면 남는 것 ${left}건`);
  }
}

console.log('== F. 마커 파싱 관대화 ==');
{
  const D = build([cnst('MARKER_WORDS')], ['findMarker', 'splitSections'], {});
  const variants = [
    ['===MEANING===', '===DECISION==='],
    ['=== MEANING ===', '=== DECISION ==='],
    ['**MEANING**', '**DECISION**'],
    ['## MEANING', '## DECISION'],
    ['==의미==', '==의사결정=='],
    ['[2단계 — 의미 분석]', '[3단계 — 의사결정]'],
  ];
  for (const [m, d] of variants) {
    const r = D.splitSections(`번역문\n${m}\n의미문\n${d}\n결정문`);
    ok(r.ko === '번역문' && r.meaning === '의미문' && r.decision === '결정문', `마커 변형 인식: ${m} / ${d}`);
  }
  const plain = D.splitSections('마커가 아예 없는 응답');
  ok(plain.ko === '마커가 아예 없는 응답' && !plain.meaning, '마커가 없으면 예전처럼 전체가 번역 (옛 동작 유지)');
  const inline = D.splitSections('본문에 DECISION 이라는 낱말이 문장 안에 있다\n===MEANING===\nm');
  ok(inline.ko.includes('DECISION 이라는 낱말'), '본문 속 낱말은 마커로 오인하지 않는다 (줄 전체일 때만)');
  ok(D.splitSections('').ko === null, '빈 응답은 ko=null');
}

console.log('== D/E. 산출물 검사와 원문 보존 ==');
{
  const ctx = { log: () => {} };
  const D = build([cnst('META_REFUSAL_RE')], ['hangulRatio', 'hasEnglishSentence', 'qcNotes', 'qcScore', 'retryRules'], ctx);
  const long = 'We need the final invoice by Friday because the vendor requires it. '.repeat(8);
  ok(D.qcNotes(long, { ko: long, meaning: 'm', decision: 'd' }, 'ko').includes('untranslated'),
    'D: 영어 원문이 그대로 돌아오면 untranslated');
  ok(!D.qcNotes('안녕하세요 확인 부탁드립니다', { ko: '안녕하세요 확인 부탁드립니다', meaning: 'm', decision: 'd' }, 'ko').includes('untranslated'),
    'D: 원문이 한국어면 원문 유지가 정상 (345건을 건드리지 않는다)');
  ok(!D.qcNotes('https://a.b/c\n@Ben\nAWS', { ko: 'https://a.b/c\n@Ben\nAWS', meaning: 'm', decision: 'd' }, 'ko').includes('untranslated'),
    'D: URL·이름·목록뿐이면 원문 유지가 정상');
  const meta = { ko: '현재 입력된 슬랙 메시지는 모두 한국어로 작성되어 있으므로 번역 단계 없이 원문을 그대로 출력합니다.', meaning: 'm', decision: 'd' };
  ok(D.qcNotes(long, meta, 'ko').includes('meta-refusal'), 'E: "번역 단계 없이 원문을 그대로 출력합니다" → meta-refusal');
  ok(D.qcNotes('x'.repeat(1000), { ko: 'y'.repeat(100), meaning: 'm', decision: 'd' }, 'ko').includes('lost'),
    'E: 원문의 20% 미만으로 줄면 lost');
  ok(D.qcNotes('x'.repeat(1000), { ko: 'y'.repeat(300), meaning: 'm', decision: 'd' }, 'ko').includes('shrunk'),
    'E: 20~35%면 shrunk (재시도만)');
  ok(!D.qcNotes('x'.repeat(1000), { ko: 'y'.repeat(600), meaning: 'm', decision: 'd' }, 'ko').length,
    'E: 정상 길이는 아무 사유도 안 붙는다');
  ok(D.qcNotes('t', { ko: 'k', meaning: '', decision: '' }, 'ko').includes('markers-missing'), 'F: 의미/결정이 비면 markers-missing');
  ok(D.qcNotes('t', { ko: null }, 'ko')[0] === 'no-output', '출력이 없으면 no-output');
  ok(D.qcScore({}, ['meta-refusal']) < D.qcScore({}, ['shrunk']), '심각한 결함일수록 점수가 낮다');
  ok(D.retryRules(['untranslated'], '한국어').length === 1, '재시도 지시가 사유별로 만들어진다');
}

console.log('== D/E. translate() 통합 — 재시도와 최종 방어 ==');
{
  const calls = [];
  let plan = [];
  const ctx = {
    log: () => {},
    targetLang: () => 'ko',
    callModel: async (prompt) => { calls.push(prompt); return { out: plan.shift(), model: 'stub' }; },
    inlineParts: () => [],
    evidenceLines: () => [],
  };
  const D = build([cnst('LANGS'), cnst('MARKER_WORDS'), cnst('META_REFUSAL_RE')],
    ['findMarker', 'splitSections', 'hangulRatio', 'hasEnglishSentence', 'qcNotes', 'qcScore', 'retryRules', 'translatePrompt', 'translate'], ctx);

  const en = 'We need the final invoice by Friday because the vendor requires it right now. '.repeat(6);
  // 1) 첫 시도 미번역 → 재시도에서 성공
  plan = [`${en}\n===MEANING===\nm\n===DECISION===\nd`, `송장이 필요합니다. ${'문장 '.repeat(60)}\n===MEANING===\nm\n===DECISION===\nd`];
  let r = await D.translate(en, '');
  ok(calls.length === 2, 'untranslated면 정확히 1회 재시도한다');
  ok(calls[1].includes('직전 시도의 오류'), '재시도 프롬프트에 교정 지시가 붙는다');
  ok(r.ko.startsWith('송장이 필요합니다') && r.note.includes('retried'), '더 나은 재시도 결과를 채택하고 사유를 남긴다');

  // 2) 두 번 다 메타 문장 → 원문 보존 (원문 소실 금지)
  calls.length = 0;
  const refusal = '이 메시지는 모두 한국어로 작성되어 있으므로 번역 단계 없이 원문을 그대로 출력합니다.';
  plan = [`${refusal}\n===MEANING===\nm\n===DECISION===\nd`, `${refusal}\n===MEANING===\nm\n===DECISION===\nd`];
  r = await D.translate(en, '');
  ok(r.ko === en, 'E: 두 번 다 메타 문장이면 번역 자리에 원문을 그대로 둔다 (4300자 → 123자 소실 재발 방지)');
  ok(r.note.includes('kept-original'), 'E: 원문 보존 사실을 사유로 남긴다');

  // 3) 정상 응답은 사유가 붙지 않는다
  calls.length = 0;
  plan = [`정상 번역문입니다.\n===MEANING===\nm\n===DECISION===\nd`];
  r = await D.translate('short english text here now', '');
  ok(calls.length === 1 && r.note === undefined, '정상이면 재시도도 사유도 없다 (기존 경로 무변경)');
  ok(r.ko === '정상 번역문입니다.' && r.meaning === 'm' && r.decision === 'd', '정상 결과가 그대로 나온다');

  // 4) 마커 결손 → 재시도로 채움
  calls.length = 0;
  plan = ['마커 없는 응답', '번역문\n===MEANING===\n의미\n===DECISION===\n결정'];
  r = await D.translate('short english text here now', '');
  ok(r.meaning === '의미' && r.decision === '결정' && r.note.includes('retried'), 'F: 마커 결손도 재시도로 복구된다');
}

console.log('== G. 퍼머링크 원격 인용 ==');
{
  const fetched = [];
  const ctx = {
    log: () => {},
    fetchMessage: async (ch, ts) => { fetched.push(ch + ':' + ts); return ch === 'CDEAD' ? null : { text: 'quoted body ' + ts, user: 'U1' }; },
    composeSource: async (m) => m.text,
    userName: async () => 'Kim',
    channelName: async () => '#general',
  };
  const D = build([line('PERMALINK_RE'), line('QUOTE_MAX'), line('QUOTE_TEXT_MAX')], ['permalinkRefs', 'quotedContext'], ctx);
  const refs = D.permalinkRefs('보세요 https://mustcompany.slack.com/archives/C0123ABC/p1787000000123456');
  ok(refs.length === 1 && refs[0].channel === 'C0123ABC' && refs[0].ts === '1787000000.123456',
    'p<TS> 를 채널+ts 좌표로 푼다', JSON.stringify(refs));
  ok(D.permalinkRefs('https://a.slack.com/archives/C1/p1787000000123456?thread_ts=1786999999.000100&cid=C1')[0].threadTs === '1786999999.000100',
    'thread_ts 쿼리도 읽는다');
  ok(D.permalinkRefs('x https://a.slack.com/archives/C1/p1787000000123456 y https://a.slack.com/archives/C1/p1787000000123456').length === 1,
    '같은 링크가 두 번 나와도 한 번만');
  ok(D.permalinkRefs(Array.from({ length: 9 }, (_, i) => `https://a.slack.com/archives/C${i}/p178700000012345${i}`).join(' ')).length === 3,
    '따라갈 인용은 3건까지 (대화가 무한히 커지지 않게)');
  ok(D.permalinkRefs('그냥 https://example.com/a 링크').length === 0, '슬랙 퍼머링크가 아니면 잡지 않는다');
  const lines = await D.quotedContext({ text: 'https://a.slack.com/archives/C7/p1787000000123456' });
  ok(lines.length === 1 && lines[0].startsWith('[인용된 메시지 · #general] Kim: quoted body'),
    '원 메시지를 읽어 컨텍스트 줄로 만든다', JSON.stringify(lines));
  ok((await D.quotedContext({ text: 'https://a.slack.com/archives/CDEAD/p1787000000123456' })).length === 0,
    '원 메시지를 못 찾으면 그 인용만 건너뛴다');
  const deep = await D.quotedContext({ text: 'https://a.slack.com/archives/C7/p1787000000123456' });
  ok(fetched.filter((f) => f.startsWith('C7')).length === 2 && deep.length === 1,
    '인용 안의 인용을 다시 따라가지 않는다 (depth 1)');
}

console.log('== H. 봇 작성자 이름 / 실패 캐시 ==');
{
  const userNames = new Map();
  let fail = true;
  const ctx = {
    log: () => {}, userNames,
    slack: async (m, p) => {
      if (m === 'bots.info') return { bot: { name: 'Jira' } };
      if (fail) throw new Error('user_not_found');
      return { user: { profile: { display_name: '조중현' }, name: 'lion' } };
    },
  };
  const D = build([], ['botName', 'userName'], ctx);
  ok(await D.userName('B09KPG9FYBB') === 'Jira', '봇 ID는 bots.info로 이름을 얻는다 (원시 ID 10건의 원인)');
  ok(await D.userName('U1') === 'U1', '조회 실패면 일단 ID를 돌려준다');
  ok(!userNames.has('U1'), '실패는 캐시하지 않는다 — 일시 오류가 영구 오류가 되면 안 된다');
  fail = false;
  ok(await D.userName('U1') === '조중현', '다음 호출에서 정상적으로 이름이 붙는다');
  ok(userNames.get('U1') === '조중현', '성공은 캐시한다');
}

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
})();
