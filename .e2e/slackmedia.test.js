// E2E for Slack 데몬의 첨부 근거 파이프라인 — 수집 판정 · 원문 조립 · 프롬프트 조립 ·
// 백엔드 요청 모양 · items 의 media 행. slackretrig.test.js 와 같은 방식으로
// slack-eyes-daemon.mjs 에서 진짜 함수를 떼어내 돌린다(스텁은 fetch 와 cleanText 뿐).
// 검증 대상:
//   - 본문이 비어도 파일·링크·attachments 가 있으면 살리고, 셋 다 없으면 예전처럼 버린다
//   - 텍스트 전용 메시지의 원문 조립은 예전과 한 글자도 다르지 않다 (기존 경로 무변경)
//   - 첨부 근거가 없으면 프롬프트에 <attachments> 섹션 자체가 생기지 않는다
//   - 첨부가 없으면 Gemini/Anthropic 요청 본문이 예전과 완전히 동일하다
//   - 비전을 거절하는 백엔드에서는 추출 텍스트만으로 재시도한다
//   - 키(gemini/anthropic/slack)가 media 행에도 프롬프트에도 남지 않는다
//   - media 행에는 계약된 필드만 남고 base64 원본은 절대 들어가지 않는다
const { readFileSync, writeFileSync, renameSync } = require('node:fs');

const SRC = readFileSync(__dirname + '/../Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs', 'utf8');

// 소스에서 함수 하나를 통째로 떼어낸다 — 기본값 파라미터가 있어도 본문 여는 중괄호를
// 찾도록 파라미터 괄호를 먼저 건너뛰고, async 접두사도 살린다.
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
function cnst(name) {
  const start = SRC.indexOf('\nconst ' + name + ' =') + 1;
  if (start <= 0) throw new Error('no const ' + name);
  let d = 0;
  for (let k = start; k < SRC.length; k++) {
    const c = SRC[k];
    if ('{[('.includes(c)) d++;
    else if ('}])'.includes(c)) d--;
    else if (c === ';' && d === 0) return SRC.slice(start, k + 1);
  }
  throw new Error('unterminated const ' + name);
}

const consts = ['FILE_LABEL', 'EXTRA_MAX', 'MEDIA_TEXT_MAX', 'EVIDENCE_TOTAL_MAX',
  'INLINE_MAX_PARTS', 'INLINE_MAX_B64', 'ANTHROPIC_IMAGE', 'LANGS'];
const fns = ['refType', 'messageUrls', 'localRefs', 'hasAttachmentOrLink', 'extraSink', 'richTextOf',
  'blockExtras', 'attachmentExtras', 'composeSource', 'scrubSecrets', 'mediaRow', 'mediaRows',
  'evidenceLines', 'inlineParts', 'translatePrompt', 'translateGemini', 'translateAnthropicAPI',
  'withInlineFallback', 'rewriteItem'];

let captured = null;
// 아래 토큰은 전부 가짜다 — 키체인을 읽지 않고, 유출 검사에서 찾을 표적으로만 쓴다.
const ctx = {
  // cleanText 스텁 — 실제 구현은 슬랙 API로 이름을 조회하므로 여기선 통과만 시킨다.
  cleanText: async (raw) => String(raw || '').replaceAll('&amp;', '&'),
  log: () => {},
  // 데몬이 번역 응답의 토큰 사용량을 act('model.usage')로 남기게 되면서 이 스텁이
  // 없으면 translateGemini/translateAnthropicAPI 시험이 ReferenceError 로 죽는다.
  act: () => {},
  geminiKey: 'AIzaTESTKEY0000000000000000',
  anthropicKey: 'sk-ant-TESTKEY0000000000',
  USER_TOKEN: 'xoxp-1111-2222-TESTUSERTOKEN',
  APP_TOKEN: 'xapp-1-TESTAPPTOKEN000',
  ITEMS_FILE: '',
  readFileSync, writeFileSync, renameSync,
  fetch: async (url, init) => {
    captured = { url, body: JSON.parse(init.body) };
    return { ok: true, status: 200, json: async () => ({ candidates: [{ content: { parts: [{ text: 'OUT' }] } }], content: [{ type: 'text', text: 'OUT' }] }) };
  },
};
const body = [...consts.map(cnst), ...fns.map(fn)].join('\n')
  + `\nreturn { ${fns.join(', ')} };`;
const D = new Function(...Object.keys(ctx), body)(...Object.values(ctx));

let fails = 0;
const ok = (c, m, extra) => { console.log((c ? '  ok   ' : '  FAIL ') + m + (extra ? '  ' + extra : '')); if (!c) fails++; };

(async () => {

// ---------------------------------------------------------------- 1. 수집 판정
const plain = { text: 'hello there' };
const imageOnly = { text: '', files: [{ id: 'F1', name: 'shot.png', mimetype: 'image/png', url_private: 'https://files.slack.com/x/shot.png', size: 1234 }] };
const linkOnly = { text: 'https://example.com/a' };
const attachOnly = { text: '', attachments: [{ title: 'Design doc', text: 'Please review by Friday' }] };
const nothing = { text: '   ' };
const quoted = {
  text: '> 이건 인용입니다\n확인 부탁',
  blocks: [{ type: 'rich_text', elements: [{ type: 'rich_text_quote', elements: [{ type: 'text', text: '이건 인용입니다' }] }] }],
};
const shared = {
  text: '',
  attachments: [{
    is_msg_unfurl: true, author_name: 'Kim', text: 'We need the invoice by 3pm',
    fallback: 'Kim: We need the invoice by 3pm',
    message_blocks: [{ message: { blocks: [{ type: 'rich_text', elements: [{ type: 'rich_text_section', elements: [{ type: 'text', text: 'We need the invoice by 3pm' }] }] }] } }],
  }],
};

ok(D.hasAttachmentOrLink(imageOnly), '파일만 있는 메시지 = 살린다');
ok(D.hasAttachmentOrLink(linkOnly), '링크만 있는 메시지 = 살린다');
ok(D.hasAttachmentOrLink(attachOnly), 'attachments만 있는 메시지 = 살린다');
ok(!D.hasAttachmentOrLink(nothing), '본문·첨부·링크 전부 없음 = 예전처럼 버린다');
ok(!D.hasAttachmentOrLink({}), '필드 자체가 없는 메시지에서도 안 터진다');

// ---------------------------------------------------------------- 2. 원문 조립
const cs = async (m) => (await D.composeSource(m));
ok(await cs(plain) === 'hello there', '텍스트 전용 메시지의 원문은 예전과 동일 (변화 없음)');
ok((await cs(imageOnly)) === '[이미지] shot.png (image/png)', '이미지 전용 → 파일 표시가 원문에 남는다', await cs(imageOnly));
const q = await cs(quoted);
ok(q === '> 이건 인용입니다\n확인 부탁', '인용이 본문에 이미 있으면 중복해 붙이지 않는다', JSON.stringify(q));
const sh = await cs(shared);
ok(sh.includes('[인용] Kim') && sh.includes('[인용] We need the invoice by 3pm'),
  '공유된 메시지(attachments)가 원문에 인용으로 들어온다', JSON.stringify(sh));
ok(!sh.includes('Kim: We need the invoice by 3pm'), 'fallback 중복은 걸러진다');
const ao = await cs(attachOnly);
ok(ao.includes('[첨부] Design doc') && ao.includes('[첨부] Please review by Friday'),
  'attachments 제목·본문이 번역 대상 원문에 들어온다', JSON.stringify(ao));

// ---------------------------------------------------------------- 3. 프롬프트
const p0 = D.translatePrompt('hello', 'ctx', 'ko');
ok(!p0.includes('<attachments>'), '첨부 근거가 없으면 프롬프트에 <attachments> 자체가 없다');
ok(p0.includes('코드 블록'), '코드 블록 보존 지시가 프롬프트에 있다');
ok(p0.includes('"[인용]"') || p0.includes('[인용]'), '인용 줄도 번역하라는 지시가 있다');
const ev = [{ ref: { name: 'a.pdf' }, type: 'pdf', method: 'pdftotext', text: '분기 매출 12억' },
  { ref: { name: 'b.png' }, type: 'image', method: 'gemini-vision', text: '차트: 3월 급감', inline: [{ mimeType: 'image/png', dataB64: 'QUJD' }] },
  { ref: { name: 'c.mp4' }, type: 'video', error: 'ffmpeg timeout' }];
const p1 = D.translatePrompt('hello', 'ctx', 'ko', ev);
ok(p1.includes('<attachments>') && p1.includes('분기 매출 12억') && p1.includes('차트: 3월 급감'),
  '첨부 근거가 <attachments>로 들어간다');
ok(p1.includes('추출 실패: ffmpeg timeout'), '추출 실패도 근거로 명시된다');
ok(p1.includes('첨부 이미지가 이 요청에 함께 실려 있다'), '인라인 이미지가 있으면 모델에게 알린다');
// 지시문 안에도 <attachments>라는 낱말이 나오므로 실제 섹션은 마지막 등장으로 본다.
ok(p1.lastIndexOf('<attachments>') > p1.indexOf('</context>')
  && p1.indexOf('</attachments>') < p1.indexOf('<message>'), '<attachments> 섹션은 <context>와 <message> 사이');

// ---------------------------------------------------------------- 4. 인라인 파트
const inline = D.inlineParts(ev);
ok(inline.length === 1 && inline[0].mimeType === 'image/png', 'inline 파트를 evidence에서 뽑는다');
const many = Array.from({ length: 20 }, () => ({ inline: [{ mimeType: 'image/png', dataB64: 'A'.repeat(10) }] }));
ok(D.inlineParts(many).length === 6, '인라인 파트 개수 상한 6');
ok(D.inlineParts([{ inline: [{ mimeType: 'image/png', dataB64: 'A'.repeat(7_000_000) }] }]).length === 0,
  '총 바이트 상한을 넘는 파트는 버린다 (요청 거절 방지)');
ok(D.inlineParts([]).length === 0 && D.inlineParts(undefined).length === 0, 'evidence가 비어도 안 터진다');

// ---------------------------------------------------------------- 5. 백엔드 요청 모양
await D.translateGemini('gemini-flash-latest', 'PROMPT', []);
ok(JSON.stringify(captured.body.contents) === JSON.stringify([{ parts: [{ text: 'PROMPT' }] }]),
  '첨부가 없으면 Gemini 요청 본문은 예전과 완전히 동일');
await D.translateGemini('gemini-flash-latest', 'PROMPT', inline);
ok(captured.body.contents[0].parts.length === 2 && captured.body.contents[0].parts[1].inlineData.mimeType === 'image/png',
  'Gemini에 inlineData 파트가 추가된다');
await D.translateAnthropicAPI('PROMPT', []);
ok(captured.body.messages[0].content === 'PROMPT', '첨부가 없으면 Anthropic 요청도 예전 그대로 (문자열)');
await D.translateAnthropicAPI('PROMPT', [{ mimeType: 'image/png', dataB64: 'QUJD' }, { mimeType: 'application/pdf', dataB64: 'ZZZ' }]);
const ac = captured.body.messages[0].content;
ok(Array.isArray(ac) && ac.length === 2 && ac[0].type === 'image' && ac[1].type === 'text',
  'Anthropic은 image 블록만 싣는다 (PDF 등 미지원 타입은 버린다)', JSON.stringify(ac.map(b => b.type)));

// 비전 미지원 백엔드 폴백 — 인라인을 붙이면 던지는 호출을 텍스트 전용으로 재시도.
let calls = 0;
const out = await D.withInlineFallback(async (parts) => {
  calls++;
  if (parts.length) throw new Error('HTTP 400 unsupported modality');
  return 'TEXT-ONLY-OK';
}, inline, 'test-model');
ok(calls === 2 && out === 'TEXT-ONLY-OK', '비전 거절 시 추출 텍스트만으로 재시도해 성공한다');

// ---------------------------------------------------------------- 6. 키 유출 차단
const leaky = [{ ref: { name: 'x', url: 'https://files.slack.com/x?t=xoxp-1111-2222-TESTUSERTOKEN' }, type: 'image',
  text: 'key=AIzaTESTKEY0000000000000000 and sk-ant-TESTKEY0000000000', error: 'auth failed for xoxp-1111-2222-TESTUSERTOKEN' }];
const rowsLeak = D.mediaRows(leaky, []);
const dumped = JSON.stringify(rowsLeak) + D.translatePrompt('t', '', 'ko', leaky);
for (const k of ['AIzaTESTKEY0000000000000000', 'sk-ant-TESTKEY0000000000', 'xoxp-1111-2222-TESTUSERTOKEN', 'xapp-1-TESTAPPTOKEN000']) {
  ok(!dumped.includes(k), `키가 media 행·프롬프트 어디에도 남지 않는다 (${k.slice(0, 8)}…)`);
}

// ---------------------------------------------------------------- 7. media 행
const rows = D.mediaRows([{ ref: { name: 'a.pdf', url: 'u' }, type: 'pdf', method: 'pdftotext', text: 'x'.repeat(9000), inline: [{ mimeType: 'image/png', dataB64: 'B'.repeat(5000) }] }], []);
ok(rows[0].text.length === 4001, 'media.text는 4000자로 자른다', String(rows[0].text.length));
ok(!('inline' in rows[0]) && !JSON.stringify(rows).includes('BBBB'), 'media 행에 base64 원본이 절대 들어가지 않는다');
ok(Object.keys(rows[0]).sort().join(',') === 'method,name,text,type,url', '계약된 필드만 남는다', Object.keys(rows[0]).join(','));
const noMod = D.mediaRows([], D.localRefs(imageOnly));
ok(noMod.length === 1 && noMod[0].error === 'extractor-unavailable' && noMod[0].type === 'image',
  '모듈이 없으면 파일 첨부만 흔적으로 남는다', JSON.stringify(noMod));
ok(D.mediaRows([], D.localRefs(linkOnly)).length === 0, '링크만 있는 메시지는 media 행을 만들지 않는다 (본문에 이미 있음)');

console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
})();
