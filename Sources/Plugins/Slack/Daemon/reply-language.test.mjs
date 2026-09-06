// 수신자 언어 — 판정과 검사. 사용법은 이웃한 send-layer.test.mjs 와 같다:
//   node reply-language.test.mjs "$PWD"
//
// 고정값(fixture)은 2026-08-31 야샬 건의 실제 원장에서 그대로 가져왔다. 지어낸 문장으로
// 임계값을 맞추면 통과하는 것은 테스트뿐이다.
const D = process.argv[2];
const { decideReplyLanguage, languageViolation, rosterIsDecisive, countryLanguage,
  hangulRatio, foreignSegments, untranslatedSegments } = await import(`${D}/reply-language.mjs`);

let pass = 0, fail = 0;
const t = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  ok ? pass++ : fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `\n        got  ${JSON.stringify(got)}\n        want ${JSON.stringify(want)}`}`);
};

// people-roster.json 에 실제로 들어 있는 세 사람.
const YASHAL = { replyLanguage: 'en', country: 'Pakistan', location: 'Karachi',
  evidence: 'slack-profile' };
const KOREAN = { replyLanguage: 'ko', country: 'Republic of Korea', location: 'Seoul',
  evidence: 'slack-profile' };
const UNKNOWN = { replyLanguage: 'en', country: '', location: '',
  evidence: 'no-country-evidence-default-en' };

// 야샬이 실제로 쓴 메시지와, 라이언 이름으로 실제로 나간 답변.
const YASHAL_MSG = '@Lion cho (조중현,Cho Chung Hyun) @Ho Young Yang (양호영) More info:\n\n'
  + '[Joined Today (8/31)] Akash Deshmukh — Crypto GTM / Growth Owner\n'
  + '• In charge of Global MPC overall growth strategy, target, channel, and campaign KPIs';
const KOREAN_THREAD = '@Lion cho (조중현,Cho Chung Hyun)\nIR-DECK 팀원 반영과 관련하여 마케팅 담당자 '
  + 'CMO 배치를 요청받았습니다.\n현재 저희가 확보한 팀원에는 관련 포지션이 없습니다.';
const SENT_BODY = '야샬(Yashal Nawaid) 님이 당일(8/31) 조인한 Akash Deshmukh(크로스 마케팅/Crypto '
  + 'GTM·Growth Owner)과 9월 1일 조인하는 Al Rizqi(Web3 Brand Marketing 및 인도네시아/SEA Owner)의 '
  + '상세 담당 업무와 프로필 정보를 추가 공유한 내용입니다.';

// ---------- 명부 근거 ----------
t('slack-profile 은 판정 근거다', rosterIsDecisive(YASHAL), true);
t('근거 없는 기본값 en 은 판정 근거가 아니다', rosterIsDecisive(UNKNOWN), false);
t('명부에 없는 사람', rosterIsDecisive(null), false);
t('한국 프로필 → ko', countryLanguage('Republic of Korea', 'Seoul'), 'ko');
t('파키스탄 프로필 → en', countryLanguage('Pakistan', 'Karachi'), 'en');

// ---------- 판정 순서 (2026-08-31 라이언 결정: 명부 우선, 근거 있을 때만) ----------
t('야샬 — 한국어 스레드 한가운데서도 영어',
  decideReplyLanguage({ rosterEntry: YASHAL, text: YASHAL_MSG, thread: KOREAN_THREAD }),
  { lang: 'en', basis: 'roster:slack-profile' });

t('야샬이 한국어를 섞어 써도 사람 고정이 이긴다 — 이것이 "고정" 의 뜻이다',
  decideReplyLanguage({ rosterEntry: YASHAL, text: '안녕하세요 확인 부탁드립니다', thread: '' }),
  { lang: 'en', basis: 'roster:slack-profile' });

t('한국 사람이 영어로 써도 한국어로 나간다',
  decideReplyLanguage({ rosterEntry: KOREAN, text: 'Could you please review this deck today', thread: '' }),
  { lang: 'ko', basis: 'roster:slack-profile' });

t('프로필이 비어 있으면 원문을 본다 — 근거 없는 기본값 en 이 한국 사람을 덮지 않는다',
  decideReplyLanguage({ rosterEntry: UNKNOWN, text: KOREAN_THREAD, thread: '' }),
  { lang: 'ko', basis: 'message' });

t('프로필도 원문도 못 정하면 스레드',
  decideReplyLanguage({ rosterEntry: UNKNOWN, text: '👀 +1', thread: KOREAN_THREAD }),
  { lang: 'ko', basis: 'thread' });

t('아무것도 없으면 명부 기본값',
  decideReplyLanguage({ rosterEntry: UNKNOWN, text: '+1', thread: '' }),
  { lang: 'en', basis: 'roster-default:no-country-evidence-default-en' });

t('명부 자체가 없으면 en',
  decideReplyLanguage({ rosterEntry: null, text: '+1', thread: '' }),
  { lang: 'en', basis: 'default' });

// ---------- 출력 검사 ----------
// 이것이 야샬 건에서 없었던 자리다. 판정은 en 으로 맞게 섰고, 아래 본문이 그대로 나갔다.
t('실제로 나간 한국어 본문은 en 에서 막힌다',
  languageViolation(SENT_BODY, 'en'), `LANGUAGE_MISMATCH:ko-in-en:${hangulRatio(SENT_BODY).toFixed(2)}`);

t('영어 본문은 en 에서 통과',
  languageViolation('Akash owns Crypto GTM and Al Rizqi owns SEA brand marketing from Sep 1.', 'en'), null);

t('영어 본문이 한국 이름을 병기해도 통과 — 고유명사는 원래 표기를 지킨다',
  languageViolation('Ho Young Yang (양호영) will forward the two profiles to the IR-DECK team today.', 'en'), null);

t('한국어 본문은 ko 에서 통과', languageViolation(SENT_BODY, 'ko'), null);

t('ko 인데 영어 문장만 나가면 막힌다',
  languageViolation('Akash owns Crypto GTM and Al Rizqi owns SEA brand marketing.', 'ko'),
  'LANGUAGE_MISMATCH:en-in-ko');

t('빈 본문은 검사하지 않는다', languageViolation('', 'en'), null);

// ---------- 줄 단위 미번역 검사 ----------
// 2026-09-02 라이언이 지적한 그 메시지를 줄여 온 것이다. 영어 본문 + 한국어 인용이
// 한 덩어리로 붙어 있어, 메시지 전체 한글 비율만 보던 옛 검사는 이것을 통과시켰다.
const MIXED = [
  'I think from a business standpoint it might be a good idea to still try to appeal.',
  'The handle had more than 146k followers already last time I checked.',
  '',
  '[인용] to @Yashal Nawaid (야샬) we need to buy x twitter follow of this,',
  '해당 계정이 다음과 같은 특징을 갖추고 있다면 더 좋을 것입니다:',
  '1. 다른 Web3 KOL이나 유명 플랫폼에서 팔로우하고 있는 계정이어야 합니다.',
  '-target date: today',
  '-password: https://password.must.company/app/passwords/view/ff809002',
].join('\n');

t('번역됐어야 하는 줄만 골라낸다 — 한국어 줄과 목록·URL 줄은 빠진다',
  foreignSegments(MIXED).length, 3);

t('영어 본문을 그대로 돌려주면 잡힌다 (전체 한글 비율은 5%를 넘는다)',
  untranslatedSegments(MIXED, MIXED).length, 3);

t('영어 본문을 번역하고 한국어 인용을 그대로 두면 통과',
  untranslatedSegments(MIXED, [
    '사업 관점에서는 여전히 이의를 제기하고 되찾아 보는 편이 좋다고 생각합니다.',
    '제가 마지막으로 확인했을 때 그 핸들은 이미 팔로워가 146k 명을 넘었습니다.',
    '[인용] @Yashal Nawaid (야샬) 님께, 이 계정의 X 트위터 팔로우를 사야 합니다,',
    '해당 계정이 다음과 같은 특징을 갖추고 있다면 더 좋을 것입니다:',
  ].join('\n')), []);

t('원문이 통째로 한국어면 검사할 줄이 없다',
  foreignSegments('오늘 회의 정리했습니다.\n내일 다시 확인하겠습니다.'), []);

t('코드 블록 안의 영어는 번역 대상이 아니다',
  foreignSegments('```\nconst a = readFileSync(path, "utf8");\nreturn a.trim();\n```'), []);

t('목표 언어가 한국어가 아니면 이 검사는 돌지 않는다',
  foreignSegments(MIXED, 'en'), []);

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
