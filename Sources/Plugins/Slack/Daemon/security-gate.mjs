// 보안 게이트 — 민감정보를 "달라"는 요청을 외부 분석 경로(번역·의미분석 LLM,
// 컨텍스트 수집, Jira, 첨부 추출)에 넘기기 전에 세우는 자리.
//
// 파일을 따로 판 이유 (2026-09-02):
// 게이트가 데몬 본문에 정규식 네 줄로 들어 있었고, 그 네 줄이 메시지 "전체"를 대상으로
// 서로 독립해서 매치했다. 그래서 3천 자짜리 업무 보고의 첫머리에 있는 "we need to
// consider" 와 맨 끝 URL 안의 "password" 가 만나 게이트가 섰다. 게이트가 서면 번역이
// 통째로 건너뛰어지므로(원문이 그대로 번역 자리에 들어간다), 오탐 하나가 곧바로
// "영어 본문이 번역되지 않았다"로 나타난다 — 라이언이 2026-09-02 에 지적한 그 화면이다.
//
// 실측(items.jsonl 1675건 전수):
//   옛 규칙   83건 차단 — 실제 자격증명·급여 요청은 그중 8건, 오탐 75건 (90%)
//   이 규칙    8건 차단 — 8건 전부 진짜 요청, 오탐 0건, 놓친 진짜 요청 0건
//
// 무엇을 바꿨는가. 셋이다.
//
// 1. 판정 단위를 메시지에서 "줄(또는 문장)"로 내렸다. 요청 동사와 민감 명사가 같은 줄에
//    있어야 한다. 3천 자를 사이에 둔 두 단어는 같은 문장이 아니다.
// 2. URL 을 지우고 본다. "password.must.company/app/passwords/view/..." 는 비밀번호를
//    달라는 말이 아니라 비밀번호 관리자 링크다. 오탐 6건이 여기서 나왔다.
// 3. 명사 목록에서 이 회사에서 다른 뜻으로 훨씬 자주 쓰이는 낱말을 뺐다. 크립토
//    회사에서 "token" 은 거의 언제나 코인이고 "secret" 은 대개 형용사다. 자격증명
//    문맥이 붙은 형태(access token, client secret, 인증 토큰)만 센다.
//    요청 동사에서도 list·need·want 를 뺐다 — "checklist", "we need to", "if you want"
//    처럼 요청이 아닌 용법이 압도적이었다.
//
// 게이트가 서면 슬랙에는 아무것도 내보내지 않는다. 알리는 것은 값을 만들지 않으면서
// 오탐일 때만 비용을 만든다 (2026-09-01 GlobalMPC X 계정 스레드 사고). 그 침묵 규칙은
// 호출부에 있고 여기서 바꾸지 않는다.

// 사람에게 "내놓으라"고 말하는 표현. 명사로도 쓰이는 낱말(list, need, want)은 넣지
// 않는다 — 넣으면 요청이 아닌 문장이 요청으로 읽힌다.
const REQUEST_RE = /(알려\s*주|보여\s*주|공유\s*(?:해|하)|보내\s*주|제공\s*(?:해|하)|공개\s*(?:해|하)|넘겨\s*주|내놔|달라|\b(?:give|show|share|send|provide|reveal|disclose|export|forward)\b|\btell\s+me\b)/gi;

const SALARY_RE = /(연봉|급여|월급|보상\s*정보|salary|salaries|payroll)/gi;

// token/secret 은 단독으로 세지 않는다. 자격증명을 뜻하는 형태일 때만 센다.
const CREDENTIAL_RE = /(api[ _-]?key|access[ _-]?key|secret[ _-]?key|client[ _-]?secret|shared[ _-]?secret|password|passwd|passphrase|private[ _-]?key|seed[ _-]?phrase|mnemonic|credentials?|(?:auth|access|bearer|api|refresh|session)[ _-]?tokens?|인증\s*정보|자격\s*증명|비밀\s*키|비밀번호|패스워드|인증\s*토큰|개인\s*키|시드\s*문구)/gi;

const INTERNAL_RE = /(보안\s*본부|보안\s*취약점|내부\s*보안|침투\s*(?:경로|방법)|익스플로잇|제로데이|유출\s*(?:정보|목록)|security\s*(?:vulnerability|incident|exploit)|zero[ -]?day|internal\s+security)/gi;

// URL·도메인은 사람이 쓴 문장이 아니다. 지운 자리는 공백으로 둬서 앞뒤 낱말이 붙지
// 않게 한다 (붙으면 없던 낱말이 생긴다).
const URL_RE = /<?https?:\/\/\S+>?|\b[\w.-]+\.(?:com|net|org|io|co|tech|life|app|so|dev|ai|xyz|me)\b\S*/gi;

// 요청 동사와 민감 명사가 이 글자 수 안에 함께 있어야 한다. 한 줄이 아주 길 때
// (붙여넣은 문단 한 덩어리) 양 끝이 우연히 만나는 것을 막는 자리다.
export const GATE_NEAR_CHARS = 80;

function hits(re, s) {
  const out = [];
  re.lastIndex = 0;
  let m;
  while ((m = re.exec(s))) {
    out.push(m.index);
    if (m.index === re.lastIndex) re.lastIndex++;
  }
  return out;
}

function near(a, b) {
  for (const x of a) for (const y of b) if (Math.abs(x - y) <= GATE_NEAR_CHARS) return true;
  return false;
}

// 줄바꿈으로 먼저 자르고, 한 줄 안에서도 문장 끝(. ? !)으로 한 번 더 자른다.
function segments(text) {
  return String(text || '').split(/\n|(?<=[.?!])\s+/);
}

// 걸리면 {kind, line}, 아니면 null. line 은 왜 섰는지를 원장에 남기기 위한 근거이며,
// 그 자체가 민감할 수 있으므로 호출부는 슬랙으로 내보내지 않는다.
export function securityGate(text) {
  for (const raw of segments(text)) {
    const line = raw.replace(URL_RE, ' ');
    const req = hits(REQUEST_RE, line);
    if (!req.length) continue;
    const kind = near(req, hits(SALARY_RE, line)) ? 'compensation'
      : near(req, hits(CREDENTIAL_RE, line)) ? 'credential'
        : near(req, hits(INTERNAL_RE, line)) ? 'internal-security'
          : null;
    if (kind) return { kind, line: raw.trim().slice(0, 200) };
  }
  return null;
}
