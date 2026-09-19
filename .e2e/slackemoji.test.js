// E2E for 이모지 레이어 — 선응답이 글 대신 리액션 하나로 끝내는 자리의 판정.
// slackanswer.test.js 와 같은 방식으로 slack-eyes-daemon.mjs 에서 진짜 함수를 떼어내
// 돌리고, emoji-layer.mjs 와 slack-emoji-layer.json 은 실제 파일을 그대로 쓴다.
//
// 이 시험이 지키려는 것 (2026-08-29 실제 사고):
//   스레드에서 상대가 "Understood, thank you. I'll proceed with the required actions
//   accordingly." 라고 닫는 말을 했는데 선응답이 거기에 "Cannot answer / Reason:
//   Insufficient context / Needed: …" 3줄을 붙였다. 컨텍스트가 부족한 게 아니라
//   애초에 답할 것이 없는 메시지였다.
// 그래서 셋을 본다.
//   1) 그 문장이 이모지로 떨어지는가, 그리고 어느 이모지인가 (🫡 — 이해 + 실행 약속)
//   2) 반대로 답을 기다리는 메시지가 이모지로 새지 않는가 (이쪽이 더 큰 사고다 —
//      묻는 사람에게 이모지만 달면 무시로 읽힌다)
//   3) 👀 가 절대 자동으로 달리지 않는가 (이 데몬 자신의 수집 트리거라 되돌아온다)
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

(async () => {
const EL = await import(DAEMON_DIR + 'emoji-layer.mjs');
const CAT = EL.loadCatalog([DAEMON_DIR + 'slack-emoji-layer.json']);
const pick = (t) => EL.quickVerdict({ text: t, catalog: CAT })?.emoji || null;

// ------------------------------------------------------------ 1. 어휘집 자체
console.log('\n[1] 어휘집');
ok(CAT.version >= 1 && CAT.emojis.length >= 6, '번들 어휘집이 읽힌다 (폴백이 아니다)', `v${CAT.version}/${CAT.emojis.length}개`);

// 사용자가 뜻을 확정해 준 여덟 개가 전부 들어 있어야 한다. 하나라도 빠지면 그 뜻은
// 코드 어디에도 없는 것이 되고, 모델이 자기가 아는 일반적인 뜻으로 대신 읽는다.
// 2026-09-02: bow 🙇 → man-bowing 🙇‍♂️ 로 이름을 교정했다. 3개월 실측에서 bow 는 0건이고
// man-bowing 이 43건이다. 이름이 틀리면 reactions.add 가 invalid_name 으로 실패한다.
for (const [name, ch] of [['white_check_mark', '✅'], ['saluting_face', '🫡'], ['+1', '👍'],
  ['eyes', '👀'], ['ok_hand', '👌'], ['raised_hands', '🙌'], ['pray', '🙏'], ['man-bowing', '🙇‍♂️']]) {
  const e = CAT.emojis.find((x) => x.name === name);
  ok(Boolean(e && e.means && e.char === ch), `${ch} ${name} 의 뜻이 어휘집에 적혀 있다`, e ? '' : '없음');
}

// 뜻은 있으나 자동으로는 달지 않는 다섯 — 이유가 함께 적혀 있어야 나중에 되짚을 수 있다.
// 2026-09-02 에 🙏 pray 와 🙇 man-bowing 이 여기 합류했다. 뜻을 몰라서가 아니라 자리를
// 못 찾아서다 — 3개월 clean 3,174건 실측 정밀도가 0.00(표본 2) · 0.07(표본 14) 이고
// 채택선은 0.70 · 표본 8 이다. 뜻은 어휘집에 정본으로 남아 있고 auto 만 내렸다.
for (const name of ['eyes', 'raised_hands', 'heavy_check_mark', 'pray', 'man-bowing']) {
  const e = CAT.emojis.find((x) => x.name === name);
  ok(e && e.auto === false && Boolean(e.autoNote), `${name} 은 auto:false 이고 사유가 적혀 있다`);
}
// 2026-09-02: 여섯 → 일곱(보는 중 🔍 이 늘어서) → 다섯(🙏·🙇 이 채택선 미달로 내려가서)
// → 넷(🫡 의 뜻이 바뀌어 이 축을 떠나서).
// 남은 넷은 ✅ · 🔍 (L0 둘) 과 👌 · 👍 (승인 뜻이라 ✅ 로 접히는 둘) 이다.
ok(EL.autoEmojis(CAT).length === 4, '자동으로 달 수 있는 것은 네 개', String(EL.autoEmojis(CAT).length));
// 접힘 해제 칸(approval:false + auto:true)이 비어 있다는 사실 자체를 고정한다. 축은 살아
// 있고 오늘 그 자리에 주인이 없을 뿐이다 — 채우려면 위 채택선을 먼저 넘겨야 한다.
ok(EL.autoEmojis(CAT).filter((e) => e.level0 !== true && e.approval === false).length === 0,
  'approval:false 이면서 auto:true 인 행은 없다 (축은 살아 있고 자리가 비었다)');
ok(EL.levelZeroEmojis(CAT).map((e) => e.name).join(',') === 'white_check_mark,mag',
  'L0는 ✅ 와 보는 중 🔍 둘이다 — 🫡 는 2026-09-02 뜻 변경으로 이 축을 떠났다');
// 🫡 가 이 축을 떠난 것은 정밀도 때문이 아니라 뜻이 바뀌었기 때문이다. 이제 이것은
// "이 글은 라이언이 아니라 에이전트가 썼다" 는 발신 표시이고, 들어온 글에 다는 리액션이
// 아니다(claude-home/slack-layers/layer-2-attribution.md). 그래서 정밀도가 올라도 되살리면
// 안 된다 — 되살리면 뜻 두 개가 한 이모지에 얹히고, 9/2 에 동료가 ✅ 를 두고 채널에서
// "그건 자동 승인이 아니다" 를 대신 설명해야 했던 일이 🫡 로 반복된다.
ok(!EL.autoEmojis(CAT).some((e) => e.name === 'saluting_face'),
  '🫡 는 자동으로 달지 않는다 (발신 표시 축으로 옮겨갔다)');
ok(!CAT.emojis.find((e) => e.name === 'saluting_face')?.match,
  '🫡 행에는 판정 정규식이 없다 — 남겨 두면 auto 를 켜는 순간 옛 뜻으로 발화한다');

// 보는 중은 판정 정규식을 갖지 않는 유일한 auto 항목이다. 정규식을 주면 어휘 일치로도
// 뽑히게 되고, 그러면 "✅ 는 양성 근거가 있을 때만" 이라는 규칙의 반대편이 열린다.
ok(CAT.pendingEmoji === 'mag', '보는 중 이모지의 이름은 어휘집이 정한다 (코드가 아니라)');
const magRow = CAT.emojis.find((e) => e.name === 'mag');
ok(Boolean(magRow) && !magRow.match, ':mag: 는 판정 정규식이 없다 — decision 축으로만 뽑힌다');
ok(magRow?.resolves === false, ':mag: 는 항목을 처리완료로 만들지 않는다');
ok(magRow?.decision === 'needed', ':mag: 는 의사결정이 필요한 자리의 이모지다');

for (const e of EL.autoEmojis(CAT).filter((x) => x.match)) {
  let compiles = true;
  try { new RegExp(e.match, 'i'); } catch { compiles = false; }
  ok(compiles && Boolean(e.match), `:${e.name}: 의 판정 정규식이 컴파일된다`);
}
const vocab = EL.catalogText(CAT);
ok(/체크만 했다/.test(vocab) && /살펴보고 있다/.test(vocab)
  && !/eyes/.test(vocab) && !/saluting_face/.test(vocab),
  '모델에게 주는 어휘집에 뜻이 실리고, auto:false 인 것은 빠진다 (🫡 도 이제 빠진다)');

// ------------------------------------------ 2. 사고 당시의 실제 문장 (핵심 회귀)
console.log('\n[2] 2026-08-29 사고 문장');
const INCIDENT = "Understood, thank you. I'll proceed with the required actions accordingly.\n"
  + 'Cc: <@U01ELMA> Mr. <@U01LION>';
// 2026-09-02 전에는 이 문장이 🫡 로 떨어졌다. 🫡 가 축을 떠난 뒤에는 ✅ 다 —
// 이 회귀 시험이 지키는 것은 "어느 이모지냐" 가 아니라 "이모지로 떨어지느냐" 이고,
// 그것(답변 불가 3줄이 나가지 않는다)은 그대로 지켜진다.
ok(pick(INCIDENT) === 'white_check_mark',
  '"Understood… I\'ll proceed…" 는 이모지로 떨어진다 — 답변 불가 3줄이 아니다',
  String(pick(INCIDENT)));
ok(!EL.vetoReason(INCIDENT, CAT),
  '"the required actions" 의 required 를 요청 신호로 오판하지 않는다',
  String(EL.vetoReason(INCIDENT, CAT)));
ok(!/U01ELMA|Cc:/.test(EL.normalizeText(INCIDENT)),
  '멘션과 Cc: 줄은 판정 전에 걷힌다 — 사람 이름이 정규식에 우연히 걸리면 안 된다');

// --------------------------------------------------- 3. 뜻이 다른 것은 다르게
console.log('\n[3] 뜻 구분');
const cases = [
  ['Understood, thank you.', 'white_check_mark', '수신 확인만 — 동의도 응원도 아니다'],
  ['Noted.', 'white_check_mark', '수신 확인만'],
  ['확인했습니다. 감사합니다.', 'white_check_mark', '한국어 수신 확인'],
  ['넵', 'white_check_mark', '한 글자 수신 확인'],
  // 2026-09-02 이전에는 🫡 였다. 🫡 가 축을 떠나면서 이 문장들을 받을 L0 행이 없어졌고,
  // null 은 "글로 답하라" 는 뜻이다. 실측(코퍼스 3,174건)에서 이 자리는 대부분 🔍 로 간다.
  ['진행하겠습니다.', null, '실행 약속 — 🫡 가 축을 떠나 받을 L0 행이 없다'],
  ['Will do.', null, '실행 약속 — 🫡 가 축을 떠나 받을 L0 행이 없다'],
  ['Sounds good.', null, '동의는 텍스트 레벨로 넘긴다'],
  ['좋습니다, 그렇게 진행하시죠.', null, '한국어 동의도 텍스트 레벨로 넘긴다'],
  ['Approved. Go ahead.', null, '승인은 컨텍스트가 필요하므로 텍스트 레벨로 넘긴다'],
  ['승인합니다.', null, '한국어 승인도 텍스트 레벨로 넘긴다'],
  ['잘 부탁드립니다.', null, '부탁은 텍스트 레벨로 넘긴다'],
  ['Good luck!', null, '기원도 L0 자동 반응으로 처리하지 않는다'],
  ['화이팅! 잘 되길 바랍니다.', null, '한국어 기원도 텍스트 레벨로 넘긴다'],
];
for (const [text, want, why] of cases) {
  const got = pick(text);
  ok(got === want, `"${text.slice(0, 32)}" → :${want}: (${why})`, got === want ? '' : `got ${got}`);
}

// 좁은 뜻이 넓은 뜻보다 먼저 잡혀야 한다. ✅ 는 가장 넓어서 마지막이다.
//
// 2026-09-02 판 3 — 이 한 줄의 기대값이 null 에서 white_check_mark 로 바뀌었다. 왜 바뀌었는지를
// 남긴다. quickVerdict 의 "좁은 뜻 먼저" 가드는 `autoEmojis(cat).filter(level0 !== true)` 를
// 돈다. 즉 **자동으로 달 자격이 있는 행만** 좁은 뜻으로 센다. 🙇 man-bowing 이 채택선 미달로
// auto:false 가 되면서 그 가드에서 빠졌고, 그래서 뒤의 "감사합니다" 가 ✅ 를 가져간다.
// 자격(auto)과 뜻(match)은 다른 축인데 이 가드가 둘을 하나로 읽고 있다.
//
// 그럼에도 지금 고치지 않는 이유는 **quickVerdict 가 아무 데서도 안 불리기 때문**이다.
// 데몬은 responseGrade 와 modelVerdict 만 부르고(slack-eyes-daemon.mjs:2482·2672), 이 함수의
// 유일한 호출부는 이 시험 파일이다(emoji-layer.mjs:213 의 ⚠️ 주석이 같은 말을 한다).
// 즉 이 변화는 슬랙에 한 글자도 닿지 않는다. responseGrade 쪽 같은 문장의 착지는 실측으로
// 확인했다 — 접힘 시절(옛 동작)에도 이 문장은 ✅ 였다(🙇 가 heavy 로 잡혀 ✅ 로 접혔다).
// 그러니 나가는 동작 기준으로는 회귀가 아니다.
//
// 남은 결정: 이 가드를 `match` 가 있고 level0 이 아닌 행 전부로 넓힐 것인가(자격과 뜻을
// 분리). 넓히는 쪽이 보수적이다 — 그 문장에서 라이언이 실제로 쓴 것은 3개월 clean 표본
// 14건에서 🫡 7 · ✅ 4 이고 ✅ 는 다수가 아니다. PO 판단 대기 중이며 이 배치의 범위가 아니다.
ok(pick('잘 부탁드립니다. 감사합니다.') === 'white_check_mark',
  '"잘 부탁 + 감사합니다" 는 ✅ 로 떨어진다 — 🙇 가 auto:false 라 좁은 뜻 가드에서 빠졌다',
  String(pick('잘 부탁드립니다. 감사합니다.')));
ok(pick("Thanks! I'll handle it.") === 'white_check_mark',
  '"Thanks + I\'ll handle it" 은 이제 ✅ 다 — 🫡 가 축을 떠나 감사 어휘만 남는다');

// ------------------------------------ 4. 답을 기다리는 메시지는 새지 않는다 (더 큰 사고)
console.log('\n[4] veto — 글로 답해야 하는 것');
const mustText = [
  ['Understood. But when will the card be issued?', '뒤에 물음이 붙었다'],
  ['확인했습니다. 그런데 언제 처리되나요?', '한국어 물음'],
  ['Thanks. Could you share the document?', '요청'],
  ['감사합니다. 확인 부탁드립니다.', '확인 부탁 — 잘 부탁과 다르다'],
  ['Noted. We need the ACRA profile before Friday.', '상대가 무엇을 필요로 한다'],
  ['Got it. I am blocked on the bank approval.', '막혀 있다'],
  ['알겠습니다. 그런데 로그인이 안 됩니다.', '문제 보고'],
  ['Understood. Waiting for your reply.', '답을 기다린다'],
  ['Thank you for the detailed explanation of the settlement flow. I went through every '
    + 'step and I think the deduction order is different from what we agreed last month, '
    + 'so I will write up the exact numbers and share them with the finance team today.', '길다 — 닫는 말이 아니다'],
];
for (const [text, why] of mustText) {
  const got = pick(text);
  ok(got === null, `"${text.slice(0, 40)}…" 은 글로 답한다 (${why})`, got ? `샜다: ${got}` : '');
}
ok(pick('') === null && pick('   ') === null, '빈 메시지는 판정하지 않는다');
ok(pick('<@U01LION> <https://example.com|link>') === null,
  '멘션과 링크만 남은 메시지는 판정하지 않는다 — 정규식에 걸릴 본문이 없다');

// --------------------------------------------------- 5. 모델 판정 결과의 착지
console.log('\n[5] 모델 판정 파싱');
const parses = [
  ['white_check_mark', 'white_check_mark', '이름 그대로'],
  [':white_check_mark:', 'white_check_mark', '콜론이 붙어도'],
  [':saluting_face:', null, '🫡 는 모델이 골라도 받지 않는다 — 발신 표시 축으로 옮겨갔다'],
  ['+1', null, '동의는 모델이 골라도 L0로 받지 않는다'],
  ['  OK_HAND \n설명이 붙었다', null, '승인은 모델이 골라도 L0로 받지 않는다'],
  ['TEXT', null, 'TEXT 는 글로 답하라는 뜻'],
  ['text', null, '소문자 text 도 같다'],
  ['eyes', null, 'auto:false 인 것은 모델이 골라도 받지 않는다'],
  ['heavy_check_mark', null, 'auto:false 인 것은 모델이 골라도 받지 않는다'],
  ['sparkles', null, '어휘집에 없는 이름은 버린다 — 슬랙에서 invalid_name 이 된다'],
  ['', null, '빈 응답'],
  [null, null, 'null 응답'],
];
for (const [out, want, why] of parses) {
  const got = EL.parsePick(out, CAT)?.emoji ?? null;
  ok(got === want, `parsePick(${JSON.stringify(out)}) → ${want} (${why})`, got === want ? '' : `got ${got}`);
}

// modelVerdict 는 절대 던지지 않는다 — 이 레이어가 터지면 "답변 불가" 3줄이 대신 나가야지
// 선응답 자체가 사라지면 안 된다.
const boom = await EL.modelVerdict({ text: 'Understood', ctx: '', catalog: CAT,
  ask: () => { throw new Error('model down'); }, log: () => {} });
ok(boom === null, '모델이 터지면 null — 예외를 밖으로 내지 않는다');
const noAsk = await EL.modelVerdict({ text: 'Understood', ctx: '', catalog: CAT });
ok(noAsk === null, 'ask 가 없으면 null');
const good = await EL.modelVerdict({ text: 'Understood', ctx: 'Lion cho: start the 1:1 here',
  catalog: CAT, ask: async (p) => { ok(/emoji-vocabulary/.test(p) && /<context>/.test(p),
    '모델 프롬프트에 어휘집과 스레드가 함께 실린다'); return 'white_check_mark'; } });
ok(good?.emoji === 'white_check_mark' && good.kind === 'model', '모델 판정이 그대로 착지한다');

// ------------------------------------------- 6. 수집 트리거는 절대 달지 않는다
console.log('\n[6] 트리거 이모지 안전장치');
const guard = new Function('EMOJIS', 'LATER_EMOJIS', `
  ${fn('baseEmoji')} ${fn('isTriggerEmoji')} ${fn('emojiSafeToPost')}
  return emojiSafeToPost;`)(['eyes'], ['bookmark', 'pushpin']);
ok(guard('eyes') === false, '👀 는 이 데몬의 수집 트리거라 봇이 달지 않는다 (달면 되돌아온다)');
ok(guard('bookmark') === false && guard('pushpin') === false, '📌/🔖 Later 트리거도 달지 않는다');
// 이 방어선은 auto 와 무관하게 이름만 본다. 그래서 auto:false 로 내려간 🙏·🙇 도 계속
// 검사한다 — 어휘집 한 줄로 auto 가 다시 열리는 날 이 줄이 먼저 돌고 있어야 한다.
ok(guard('white_check_mark') && guard('saluting_face') && guard('+1') && guard('ok_hand')
  && guard('pray') && guard('man-bowing'), '어휘집이 뜻을 적어 둔 여섯 개는 전부 통과한다');
ok(guard('') === false && guard(null) === false, '이름이 없으면 달지 않는다');
// 어휘집을 운영 파일로 덮어써 eyes 를 auto:true 로 되돌려도 이 방어선이 남아야 한다.
for (const e of EL.autoEmojis(CAT)) ok(guard(e.name), `어휘집 auto 항목 :${e.name}: 이 트리거와 겹치지 않는다`);

// ------------------------------------------------- 7. 데몬 배선 (문자열 검사)
console.log('\n[7] 데몬 배선');
const post = fn('postAcknowledgement');
// 2026-08-31 두 축 구조: quickVerdict("이모지로 끝내도 되는가")가 아니라
// responseGrade("이 메시지가 글을 받을 자격이 있는가")가 먼저 돈다. 바닥값은 R1 이다.
ok(/responseGrade/.test(post) && post.indexOf('responseGrade') < post.indexOf('ackEvidence'),
  '등급 판정이 근거 레이어(20초 예산)보다 먼저 돈다 — R1 이면 모델을 쓰지 않는다');
ok(/ACK_NO_BASIS/.test(post) && /modelVerdict/.test(post),
  '"근거 없음" 판정은 곧바로 나가지 않고 이모지 레이어에 한 번 더 묻는다');
const ackText = fn('acknowledgementText');
ok(/ACK_NO_BASIS/.test(ackText) && !/Cannot answer/.test(ackText),
  'acknowledgementText 는 3줄 문장이 아니라 표식을 돌려준다');
// "답변 불가 / 이유 / 필요" 3줄은 통째로 지웠다 — 그것도 라벨 틀이고 상대에게는 우리
// 사정일 뿐이다 (docs/slack-ack-two-axis-design.md §3). 근거를 못 찾으면 R1 로 내려간다.
ok(!/Cannot answer\\n|답변 불가\\n/.test(SRC), '"답변 불가" 3줄을 만드는 코드가 데몬에 없다 (주석의 언급만 남는다)');
ok(/demote\(/.test(post), '등급을 못 올린 자리는 침묵이 아니라 R1(리액션)으로 내려간다');
// 모듈이 번들에서 빠지는 것은 이 저장소의 실제 실패 모드다 (media-extract 2026-08-28,
// answer-context 도 같은 이유로 build-app.sh 에 줄이 있다). 빠졌을 때 선응답이
// 사라지는 게 아니라 예전처럼 전부 글로 나가야 한다.
ok(/if \(emo\)/.test(post) && (post.match(/if \(emo\)/g) || []).length >= 2,
  '이모지 모듈이 없으면(=null) 두 자리 모두 건너뛰고 글 선응답으로 간다');
const build = readFileSync(__dirname + '/../Scripts/build-app.sh', 'utf8');
ok(/emoji-layer\.mjs/.test(build) && /slack-emoji-layer\.json/.test(build),
  'build-app.sh 가 모듈과 어휘집을 앱 번들에 함께 싣는다 — 배치 때문에 기능이 사라지지 않게');

const react = fn('postEmojiReaction');
ok(/reactions\.add/.test(react) && /already_reacted/.test(react),
  '리액션을 달고, 이미 달려 있으면 글로 덮지 않는다');
ok(/return false/.test(react), '리액션이 실패하면 false — 호출부가 글로 되돌아간다');
ok(/ackEmoji/.test(react), '어떤 이모지로 끝냈는지 항목에 남는다');
ok(/requestLevel:\s*0/.test(react), '이모지로 끝낸 항목은 L0로 기록한다');

// ── 2026-08-31 두 번째 사고: 단체 공지에 원문 재진술이 나갔다 ────────────────
// "Hi everyone, See you all at tea break soon." + 5명 단체 멘션에
// "Answer: Inform team members about the upcoming tea break." 가 나갔다.
// 이 레이어가 통과시킨 이유는 "글로 답할 이유가 있어서" 가 아니라 "어휘집 정규식에
// 안 걸려서" 였다 — 닫는 말의 화이트리스트라 닫는 말도 묻는 말도 아닌 것은 다 글이었다.
// 그래서 단체 수신에 한해 기본값을 뒤집었다. 아래가 그 경계를 지킨다.
const ROSTER = 'teamSync: @Lion cho (조중현,Cho Chung Hyun) @İsmail Görkem Kara (이스마일) '
  + '@K M Mahmudul Hasan (마흐무둘) @Nadir Ali ( 나디르 알리 ) @Muhammad Salman Khanzada (سلمان)';
const REAL = 'Hi everyone,\nSee you all at tea break soon. \u{1FAE1}\n\n' + ROSTER;

ok(EL.mentionCount(REAL) === 5, '평문 멘션(@Name)도 센다 — 수집된 item.textEn 은 <@U…> 가 아니다');
ok(EL.isGroupAddress(REAL, 'mention') === true, '3인 이상 동시 호명은 단체 수신이다');
ok(EL.isGroupAddress('Lion, quick one', 'mention') === false, '1:1 은 단체가 아니다');
ok(EL.isGroupAddress('<!here> heads up', 'mention') === true, '@here 는 단체다');

// 명단 줄이 길이 상한을 먹어 버리는 문제. 이번 건은 정규화 후 197자로 상한 240자를
// 우연히 넘지 않았을 뿐이다 — 사람이 둘만 더 있었으면 "짧은 인사" 가 길이로 막혔다.
ok(EL.normalizeText(EL.withoutRosterLines(REAL)).length < 60,
  '길이 판정에서 수신자 명단은 내용으로 세지 않는다');
ok(EL.withoutRosterLines('@A @B can you check this?').includes('can you check'),
  '명단 제거가 문장을 지우면 안 된다 — 물음이 사라지면 이모지가 나간다');

const gv = (t, src = 'mention') => EL.quickVerdict({ text: t, catalog: CAT, source: src });
ok(gv(REAL)?.emoji === 'white_check_mark', '이번 사고 메시지는 ✅ 하나로 끝난다 (글이 아니다)');
ok(gv(REAL)?.kind === 'group', '그 판정의 근거가 어휘집 일치가 아니라 단체 수신임이 남는다');
for (const [why, t] of [
  ['질문', 'Hi all, can you send me the report?\n\n' + ROSTER],
  ['요청', 'Team, please review the PRD today.\n\n' + ROSTER],
  ['막힘', 'We are blocked on the API key.\n\n' + ROSTER],
  ['장애', 'Heads up everyone, the payment server is down.\n\n' + ROSTER],
  ['긴급', 'URGENT: all hands please join now.\n\n' + ROSTER],
  ['한국어 요청', '내일 자료 공유 부탁드립니다.\n\n' + ROSTER],
  ['승인처럼 뜻이 무거운 말', 'Approved, go ahead.\n\n' + ROSTER],
]) ok(gv(t) === null, `단체여도 ${why} 신호가 있으면 글로 간다 — 답을 기다리는 사람에게 이모지는 무시로 읽힌다`);
ok(gv('Good morning Lion!') === null, '1:1 잡담은 뒤집지 않는다 (거기서 침묵하면 무시로 읽힌다)');

console.log(fails ? `\n${fails} FAILED` : '\n모두 통과');
process.exit(fails ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
