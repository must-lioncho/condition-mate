// 축 0 — 신규성 탐침과 메시지 1 렌더. 사용법은 이웃한 send-layer.test.mjs ·
// reply-language.test.mjs 와 같다:
//   node people-context.test.mjs "$PWD"
//
// 왜 생겼나 (2026-08-31): F2 강등 취소가 조건 없이 참이었다. 취소 근거로 원장과
// 드라이런에 찍힌 "스레드에 없는 새 사실 8개" 가 전부 메시지 1 의 고정 서두였다 —
// 컨텍스트/매니지먼트/에이전트입니다/아래는/조회한/것과/조회하지/못한. 서두는 언제나
// 같은 문장이라 어느 스레드에도 없고, 그래서 조회 결과가 0건인 날에도 여덟 개가 나온다.
// "축 0 이 새 사실을 가져왔을 때만 F2 를 되돌린다"(설계 §11-9-1)가 무력화된 상태였다.
//
// 그래서 이 파일의 핵심은 마지막 절의 반증 시험이다. 취소가 일어나는 것만 확인하면
// 무조건 참인 판정도 통과한다. 취소가 *일어나지 않는* 경우를 하나 보여야 조건부라는
// 증거가 된다.
//
// 고정값은 2026-08-31 #tf-mpc-dev 1788164273.559049 의 실제 원문·스레드·프로필 조회
// 결과에서 그대로 가져왔다. 지어낸 문장으로는 이 결함이 재현되지 않는다.
const D = process.argv[2];
const { peopleContext, noveltyProbe, renderContextMessage } = await import(`${D}/people-context.mjs`);
const { novelTokens } = await import(`${D}/novelty-gate.mjs`);

let pass = 0, fail = 0;
const t = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  ok ? pass++ : fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `\n        got  ${JSON.stringify(got)}\n        want ${JSON.stringify(want)}`}`);
};

// ---------- 고정값 ----------
const person = (id, realName, extra = {}) => ({
  id, realName, displayName: realName, title: '', tz: '', deleted: false, isBot: false, ...extra,
});

// 슬랙 사용자 디렉터리 캐시. 실제 캐시는 3993명이고 그 수가 미해석 표시("3993명 중
// 0건")에 그대로 실리므로 count 도 실측값으로 둔다.
const CACHE = {
  version: 1,
  fetchedAt: Date.now(),
  count: 3993,
  people: {
    U0BTDHR4VJ6: person('U0BTDHR4VJ6', 'Akash Deshmukh',
      { title: 'Crypto Business Go-To-Market (GTM) Owner', tz: 'Asia/Kolkata' }),
    U0BKH9ACC23: person('U0BKH9ACC23', 'Yashal Nawaid (야샬)'),
    U08JA6KNXMM: person('U08JA6KNXMM', 'Ho Young Yang (양호영)'),
    U01LIONCHO0: person('U01LIONCHO0', 'Lion cho (조중현,Cho Chung Hyun)'),
  },
};

// users.profile.get. 실측대로 커스텀 필드는 하나도 채워져 있지 않다 — 국적·입사일·
// 링크드인이 전부 비어 있는 것이 이 사람의 실제 프로필이다.
const slack = async (method, params) => {
  if (method !== 'users.profile.get') throw new Error(`시험에서 부르지 않는 메서드: ${method}`);
  const p = CACHE.people[params.user];
  return { profile: { real_name: p.realName, display_name: p.displayName, title: p.title, fields: {} } };
};

const TEXT = `@Lion cho (조중현,Cho Chung Hyun)
IR-DECK 팀원 반영과 관련하여 마케팅 담당자 CMO 배치를 요청받았습니다.
현재 저희가 확보한 팀원에는 관련 포지션이 없습니다.
추천해주실 분이 있을지 문의드립니다.

• 필요정보
이름:
국적:
연차:
최종학위:
전공:
링크드인:

sync @Yashal Nawaid (야샬)`;

const THREAD = `Yashal Nawaid (야샬): @Lion cho (조중현,Cho Chung Hyun) Akash Deshmukh and Al Rizqi are new hires for crypto marketing. We can also consider one of them
Ho Young Yang (양호영): @Lion cho (조중현,Cho Chung Hyun) 이대로 전달하도록하겠습니다.`;

const pc = await peopleContext({
  slack, text: TEXT, ctx: THREAD, cache: CACHE,
  selfIds: ['U01LIONCHO0', 'U08JA6KNXMM'], timeoutMs: 3000,
});

// 데몬의 axis0CancelsF2 규칙을 그대로 다시 적는다. 판정기는 novelty-gate 하나뿐이고,
// 취소 조건은 "새 토큰이 하나라도 있는가" 하나다.
const cancels = (probe, source) => {
  const tokens = probe.trim() ? novelTokens(probe, source) : [];
  return { cancelled: tokens.length > 0, tokens };
};

// ---------- 조회가 되긴 했는가 (고정값이 살아 있는지 확인) ----------
t('Akash 는 해석되고 Al Rizqi 는 해석되지 않는다',
  [pc.rows.map((r) => r.name), pc.unresolved.map((u) => u.name)],
  [['Akash Deshmukh'], ['Al Rizqi']]);

// ---------- 탐침에 무엇이 담기는가 ----------
const probe = noveltyProbe(pc);

t('탐침에 고정 서두가 없다', /컨텍스트 매니지먼트|에이전트입니다|조회한 것과/.test(probe), false);
t('탐침에 항목 이름(라벨)이 없다', /직책|국적|입사일|연차|링크드인|미조회|미입력|근거 없음/.test(probe), false);
t('탐침에 조회처 문장이 없다', /슬랙 사용자 디렉터리|노션 HR DB|슬랙 디렉터리/.test(probe), false);
t('탐침에 값이 없는 항목은 아예 빠진다 — 국적 대신 딸려 온 타임존도 사실이 아니다',
  /Asia\/Kolkata/.test(probe), false);
t('탐침에 조회된 값과 미해석 이름은 담긴다',
  [probe.includes('Akash Deshmukh'),
    probe.includes('Crypto Business Go-To-Market (GTM) Owner'),
    probe.includes('Al Rizqi'), probe.includes('3993명 중 0건')],
  [true, true, true, true]);

// ---------- 결함 재현: 렌더 본문을 넣으면 서두가 근거가 된다 ----------
// 이 줄은 "고쳤다" 의 근거다. 같은 판정기에 렌더 본문을 넣으면 예전 결과가 그대로
// 재현되고, 탐침을 넣으면 재현되지 않는다. 둘의 차이가 입력뿐임을 여기서 보인다.
const SOURCE = `${THREAD}\n${TEXT}`;
const rendered = renderContextMessage(pc, {});
t('옛 입력(렌더 본문)은 서두 단어를 새 사실로 돌려준다 — 이것이 결함이었다',
  novelTokens(rendered, SOURCE).includes('컨텍스트'), true);
t('새 입력(탐침)은 서두 단어를 하나도 돌려주지 않는다',
  cancels(probe, SOURCE).tokens.some((x) => ['컨텍스트', '매니지먼트', '에이전트입니다', '아래는', '조회한', '것과', '조회하지', '못한'].includes(x)),
  false);

// ---------- 취소가 일어나는 쪽 ----------
const hit = cancels(probe, SOURCE);
t('스레드에 없는 조회값이 있으면 F2 는 취소된다', hit.cancelled, true);
console.log(`        근거 토큰: ${hit.tokens.join(', ')}`);

// ---------- 반증: 취소가 일어나지 않는 쪽 ----------
//
// 조회해 온 값이 스레드에 이미 전부 들어 있는 경우다. 이때 축 0 은 스레드 밖에서
// 아무것도 가져오지 못한 것이고, "이미 답이 나와 있다"(F2)는 그대로 맞는 판정이다.
// 취소가 여기서도 일어나면 그 규칙은 조건이 아니라 상수다.
const SOURCE_KNOWS_ALL = `${THREAD}
Yashal Nawaid (야샬): Akash Deshmukh 는 Crypto Business Go-To-Market (GTM) Owner 입니다.
Ho Young Yang (양호영): Al Rizqi 는 슬랙에 계정이 없습니다 — 3993명 중 0건 으로 나옵니다.`;
const miss = cancels(probe, SOURCE_KNOWS_ALL);
t('조회값이 스레드에 이미 다 있으면 새 토큰은 0개', miss.tokens, []);
t('그러면 F2 는 취소되지 않는다 — 취소는 조건부다', miss.cancelled, false);

// ---------- 메시지 1 — 같은 말을 두 번 하지 않는다 ----------
const line = rendered.split('\n').find((l) => l.trim().startsWith('미조회')) || '';
t('사람 줄에 이미 미입력으로 적힌 항목은 미조회 줄에서 빠진다',
  /국적|연차|링크드인/.test(line), false);
t('인라인에 아예 나타나지 않는 항목만 미조회 줄에 남는다', line.trim(), '미조회 최종학위/전공');
t('미입력 표시 자체는 사람 줄에 그대로 남는다',
  [/국적 미입력/.test(rendered), /연차 근거 없음/.test(rendered), /링크드인 미입력/.test(rendered)],
  [true, true, true]);

// ---------- 빈 입력 ----------
t('pc 가 없으면 빈 문자열 — 취소하지 않는다', noveltyProbe(null), '');
t('조회 결과가 하나도 없으면 빈 문자열',
  noveltyProbe({ grade: 'C0', rows: [], unresolved: [] }), '');

console.log(`\n${pass} pass · ${fail} fail`);
process.exit(fail ? 1 : 0);
