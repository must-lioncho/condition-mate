// 수신자 언어 — 판정과 검사를 한 곳에 모은 파일.
//
// 왜 파일을 따로 팠는가 (2026-08-31 야샬 건):
// 야샬(Pakistan/Karachi)의 영어 메시지에 라이언 이름으로 나간 답변이, 머리줄만 영어이고
// 본문 전체가 한국어였다. 원장을 보면 판정 자체는 맞았다 — 명부의 replyLanguage 가 en
// 이었고 파이프라인에도 en 이 흘렀다(머리줄이 영어로 찍힌 것이 그 증거다). 틀린 것은
// 판정이 아니라 강제였다. 프롬프트에 `Write descriptive fields in English.` 한 줄이
// 있었을 뿐이고, 그 아래로 스레드 부모(한국어)·직전 답변(한국어)이 깔려 있었다.
// Gemini Flash-Lite 는 지시 한 줄이 아니라 주변 언어를 따라갔다.
//
// 그래서 이 파일이 두 가지를 함께 소유한다. 결정하는 자리와, 그 결정을 출력이 실제로
// 지켰는지 보는 자리다. 둘이 떨어져 있으면 규칙은 한 곳에 있어도 지켜지는지는 아무도
// 안 본다.
//
// 규칙은 여기 한 벌만 있다. 프롬프트는 이 값을 받아 쓸 뿐 스스로 판정하지 않고,
// 데몬의 다른 곳에도 사본을 두지 않는다.

// ---- 글자 판정 ---------------------------------------------------------------
//
// 데몬이 들고 있던 것을 여기로 옮겼다. 번역 QC(qcNotes)도 같은 함수를 쓰므로 데몬은
// 이 파일에서 가져다 쓴다 — 정의가 두 벌이 되면 언제고 갈라진다.

export function hangulRatio(s) {
  const letters = String(s || '').replace(/[^\p{L}]/gu, '');
  if (!letters) return 0;
  return (letters.match(/[가-힣]/g) || []).length / letters.length;
}

// 영어 서술 문장이 있는가 — 알파벳 단어가 넷 이상 이어지면 문장으로 본다.
// (이름·URL·목록만 있는 원문은 원문 유지가 맞으므로 여기서 걸러야 한다.)
export function hasEnglishSentence(s) {
  return /[A-Za-z][A-Za-z']{1,}(?:\s+[A-Za-z][A-Za-z']{1,}){3,}/.test(String(s || ''));
}

// 한 언어라고 부를 만한 최소 비중. 원문·스레드에서 "이 글은 한국어다"를 정할 때 쓴다.
export const HANGUL_IS_KOREAN = 0.25;

// ---- 줄 단위 미번역 검사 --------------------------------------------------------
//
// 왜 줄 단위인가 (2026-09-02 라이언 지적):
// 슬랙 메시지 하나가 통째로 한 언어인 경우가 오히려 드물다. 영어로 쓴 본문 아래 한국어
// 인용이 붙고, 한국어 보고 아래 같은 내용의 영어판이 붙는다. 그런데 번역 QC 는 메시지
// 전체의 한글 비율만 봤다 — 한글이 5% 만 넘으면 "이미 한국어" 로 통과시켰고, 그래서
// 영어 본문이 한 글자도 안 바뀐 채로 번역 자리에 들어갔다. 코퍼스 1675 건 중 33 건이
// 이 구멍으로 빠져나갔고 어느 것에도 사유(note)가 남아 있지 않았다.
//
// 그래서 판정을 줄로 내린다. "이 메시지는 무슨 언어인가" 가 아니라 "이 줄은 목표 언어가
// 아닌가, 그런데 출력에 그대로 남아 있는가" 를 묻는다.

// 코드 블록과 인라인 코드는 번역 대상이 아니다 (프롬프트가 그대로 옮기라고 지시한다).
// 그것이 출력에 그대로 있는 것은 정상이므로 검사에서 뺀다.
function stripCode(s) {
  return String(s || '').replace(/```[\s\S]*?```/g, ' ').replace(/`[^`\n]*`/g, ' ');
}

// 언어 판정에서 빼야 하는 것들. 프롬프트가 모델에게 빼라고 지시하는 것과 같은 목록이다
// — 검사가 다른 잣대를 쓰면 모델이 지킨 것을 검사가 어겼다고 하게 된다.
// 짧은 줄일수록 이것이 결정적이다: "@Yashal Nawaid (야샬) we need to buy this" 는 이름
// 병기 두 글자 때문에 한글 비율이 0.08 로 올라가 영어 문장이 아닌 것으로 읽혔다.
function stripNames(s) {
  return String(s || '')
    .replace(/\([^)]*\)/g, ' ') // 괄호 안 표기 — 이름의 한글 병기가 여기 들어온다
    .replace(/^\s*\[[^\]]{1,12}\]/, ' ') // 줄머리의 [인용]·[첨부]·[이미지] 표시
    .replace(/:[a-z0-9_+-]+:/gi, ' '); // 슬랙 이모지 코드
}

// 목표 언어가 한국어일 때, 번역됐어야 하는 줄들. 이름·URL·짧은 목록 줄은 hasEnglishSentence
// 가 걸러 준다 (알파벳 낱말 넷 이상이 이어져야 문장으로 본다).
export function foreignSegments(source, lang = 'ko') {
  if (lang !== 'ko') return [];
  return stripCode(source).split('\n')
    .map((l) => l.trim())
    .filter((l) => {
      if (l.length < 12) return false;
      const bare = stripNames(l);
      return hangulRatio(bare) < 0.05 && hasEnglishSentence(bare);
    });
}

// 그중 출력에 글자 그대로 남아 있는 줄. 돌려주는 배열이 비어 있지 않으면 번역이 그 줄을
// 건너뛴 것이다.
export function untranslatedSegments(source, output, lang = 'ko') {
  const out = String(output || '');
  return foreignSegments(source, lang).filter((l) => out.includes(l));
}

// ---- 명부 (사람별 고정 언어) --------------------------------------------------

// 프로필의 국가·지역에서 언어를 정한다. 한국이라는 근거가 있을 때만 ko 이고,
// 나머지는 en 이다. 근거가 아예 없을 때 en 이 나오는 것은 판정이 아니라 기본값이므로,
// 호출부는 evidence 를 함께 보고 그것을 "판정된 것"으로 취급하지 않는다.
export function countryLanguage(country, location) {
  const evidence = `${country || ''} ${location || ''}`.toLowerCase();
  return /(south korea|republic of korea|대한민국|한국|seoul|서울)/i.test(evidence) ? 'ko' : 'en';
}

// 명부 항목이 실제 근거를 담고 있는가. 라이언이 2026-08-31 에 정한 것은 "명부 우선,
// 단 근거가 있을 때만" 이다. 근거 없이 기본값 en 이 박힌 항목까지 우선하면, 프로필이
// 빈 한국 사람에게 영어가 나가는 사고가 그 자리에서 새로 생긴다.
export const ROSTER_HARD_EVIDENCE = ['slack-profile', 'github-public-profile'];

export function rosterIsDecisive(entry) {
  return Boolean(entry
    && (entry.replyLanguage === 'ko' || entry.replyLanguage === 'en')
    && ROSTER_HARD_EVIDENCE.includes(entry.evidence));
}

// ---- 판정 ---------------------------------------------------------------------
//
// 순서가 곧 근거의 세기다. 2026-08-31 라이언 결정으로 명부가 맨 앞에 온다.
//
//   1. 명부 — 근거가 있는 사람은 그 사람의 언어로 고정한다. 한국어 스레드에서 야샬이
//      영어로 쓰든 한국어를 섞어 쓰든 영어로 나간다. 사람이 바뀌지 않는 한 답변 언어도
//      바뀌지 않는다는 것이 이 순서의 뜻이다.
//   2. 원문 — 명부에 근거가 없을 때 지금 이 사람이 실제로 쓴 글자를 본다.
//   3. 스레드 답글 — 이 대화가 어느 언어로 굴러가고 있는가. 채널 최근 메시지는
//      스레드가 아니므로 호출부가 넘기지 않는다(threadOnlyContext).
//   4. 그래도 못 정하면 명부의 기본값, 끝내 없으면 en.
//
// 번역본을 덧붙이거나 두 언어를 함께 내보내지 않는다. 돌려주는 basis 는 원장에 남아
// "왜 그 언어로 나갔는가"를 나중에 되짚는 근거가 된다.
export function decideReplyLanguage({ rosterEntry = null, text = '', thread = '' } = {}) {
  if (rosterIsDecisive(rosterEntry)) {
    return { lang: rosterEntry.replyLanguage, basis: `roster:${rosterEntry.evidence}` };
  }
  const t = String(text || '');
  if (hangulRatio(t) >= HANGUL_IS_KOREAN) return { lang: 'ko', basis: 'message' };
  if (hasEnglishSentence(t)) return { lang: 'en', basis: 'message' };
  const th = String(thread || '');
  if (th) {
    if (hangulRatio(th) >= HANGUL_IS_KOREAN) return { lang: 'ko', basis: 'thread' };
    if (hasEnglishSentence(th)) return { lang: 'en', basis: 'thread' };
  }
  const fallback = rosterEntry?.replyLanguage;
  if (fallback === 'ko' || fallback === 'en') {
    return { lang: fallback, basis: `roster-default:${rosterEntry?.evidence || 'unknown'}` };
  }
  return { lang: 'en', basis: 'default' };
}

// ---- 검사 ---------------------------------------------------------------------
//
// 결정된 언어를 나갈 글이 실제로 지켰는가. 모델이 계약을 어겼는지를 코드가 읽는
// 자리이며, 모델에게 다시 묻지 않는다.
//
// 임계값 0.15 는 실측으로 정했다 (2026-08-31, ack-threads.json + replies.json):
//   야샬 건에 실제로 나간 한국어 본문   0.575 / 0.561
//   영어로 나간 정상 답장               0.000 (4건)
//   한국어로 나간 정상 답장             0.925
// 사이가 0.00 과 0.56 으로 벌어져 있다. 0.15 는 영어 답변이 한국 사람 이름을 한둘
// 병기하는 것("Ho Young Yang (양호영) will …")은 통과시키고, 본문이 한국어로 넘어간
// 것은 전부 잡는 자리다. 값을 좁히려면 표본을 더 쌓은 뒤에 한다 — 지금 표본으로
// 소수점을 더 깎으면 임계값을 또 지어내는 것이 된다.
export const KOREAN_IN_ENGLISH_MAX = 0.15;

// 위반이면 사유 코드, 아니면 null. 코드는 그대로 원장(ackBlockedReasons)에 남는다.
export function languageViolation(body, lang) {
  const s = String(body || '').trim();
  if (!s) return null;
  if (lang === 'en') {
    const ratio = hangulRatio(s);
    if (ratio >= KOREAN_IN_ENGLISH_MAX) return `LANGUAGE_MISMATCH:ko-in-en:${ratio.toFixed(2)}`;
    return null;
  }
  if (lang === 'ko') {
    if (hangulRatio(s) < 0.05 && hasEnglishSentence(s)) return 'LANGUAGE_MISMATCH:en-in-ko';
    return null;
  }
  return null;
}

// 모델이 한 번 어겼을 때 다시 부를 프롬프트에 얹는 줄. 지시를 프롬프트 맨 끝에 두는
// 것이 앞머리에 두는 것보다 지켜진다 — 야샬 건에서 어긴 그 한 줄은 프롬프트 두 번째
// 줄에 있었고, 그 아래로 한국어 근거가 수천 자 깔려 있었다.
export function languageRetryRule(lang) {
  const name = lang === 'ko' ? 'Korean (한국어)' : 'English';
  const other = lang === 'ko' ? 'English' : 'Korean';
  return `LANGUAGE — your previous answer broke this rule and was rejected. Every sentence you write `
    + `MUST be in ${name}. The evidence, the thread and the earlier replies above are in ${other}; `
    + `that does NOT change the language you write in. Proper nouns may keep their original spelling; `
    + `nothing else may.`;
}
