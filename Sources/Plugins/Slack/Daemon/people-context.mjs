// people-context.mjs — 축 0. 답을 만들기 전에 "이 대화에 나온 사람이 누구인지"를 먼저 조회한다.
//
// 왜 생겼나: 2026-08-31 #tf-mpc-dev 에서 양호영이 "IR-DECK 팀에 CMO 로 배치할 사람을
// 추천해 달라, 필요정보는 이름·국적·연차·최종학위·전공·링크드인" 이라고 물었고, 야샬이
// "Akash Deshmukh 와 Al Rizqi 가 크립토 마케팅 신규 입사자" 라고 답했다. 그때 봇이 낸
// 선응답은 스레드에 이미 적혀 있는 말을 다시 정리한 것이 전부였다 — 그 두 사람이 누구인지
// 우리 로스터를 한 번도 열어 보지 않았다. 사람 이름이 나온 자리에서 그 사람을 조회하지
// 않으면, 뒤에 오는 어떤 판단도 이름 문자열 위에서만 돈다.
//
// 그래서 이 층은 답을 만들지 않는다. 조회만 한다. 조회한 것과 조회하지 못한 것을 그대로
// 늘어놓고, 그 목록이 슬랙 메시지 한 개(=메시지 1)로 먼저 나간 뒤에 의사결정 서포트(축 1)가
// 별개 메시지로 나간다. 한 메시지 안의 두 블록이 아니라 메시지 둘인 이유는, 근거를 늘어놓는
// 행위와 답하는 행위가 다른 일이고 받는 사람이 그 둘을 구별해 볼 수 있어야 해서다
// (축 2 F3 을 별개 메시지로 낸 것과 같은 규칙).
//
// 규칙은 answer-context.mjs · media-extract.mjs 와 같다.
//   - 키체인을 직접 열지 않는다. 슬랙 호출기 `slack` 은 opts 로 들어온다.
//   - 어떤 함수도 예외를 밖으로 내지 않는다. 층 하나가 실패해도 선응답은 나가야 한다.
//   - 실패는 조용한 빈 값이 아니라 "조회 실패 — <사유>" 문자열로 남는다. 조용히 비면
//     모델도 사람도 "확인했는데 없었다"로 읽는다. 그것이 이 층이 막으려는 바로 그 오류다.
//
// 반출 규칙 하나만 더. 프로필에서 뽑는 필드는 허용목록 방식이다. 차단목록이 아니다 —
// 워크스페이스 커스텀 필드는 사람이 관리자 화면에서 계속 늘리고, 차단목록으로 두면 새로
// 생긴 민감 필드가 기본으로 새어 나간다. 실제로 이 워크스페이스에는 Phone·Gmail·KakaoID·
// Emergency Contact 1·2·Apple store email 이 커스텀 필드로 들어 있다.

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// ── 워크스페이스 커스텀 프로필 필드 ─────────────────────────────────────────
//
// team.profile.get 으로 실제 정의를 읽어 확인한 id 들이다(2026-08-31). id 를 코드에
// 박아 두는 이유는 users.profile.get 이 라벨을 주지 않고 id 로만 값을 주기 때문이다.
// 라벨로 찾으려면 사람마다 team.profile.get 을 한 번 더 불러야 하고, 그 라벨은 관리자가
// 언제든 바꾼다 — 그러면 이름이 바뀐 날 조용히 값이 사라진다. id 는 바뀌지 않는다.
const FIELD = {
  organization: 'Xf03U7G742EB',
  division: 'Xf03VBPZ6A80',
  department: 'Xf03UK49T7B7',
  departmentProject: 'Xf06GWMRDN6N',
  title: 'Xf03UN099H8B',
  startDate: 'Xf05GJRK7CUW',
  // 같은 라벨(Country)로 정의된 필드가 둘이다. 하나로 합칠 권한이 이 데몬에 없으므로
  // 둘 다 읽고 먼저 값이 있는 쪽을 쓴다.
  country1: 'Xf07D4RZMGKB',
  country2: 'Xf03UQGVEDMJ',
  location: 'Xf0879S4LRDE',
  city: 'Xf03V0MY0BPT',
  linkedin: 'Xf0A50H16FMY',
};

// 이 워크스페이스에 실제로 존재하는 민감 필드. 아래 목록은 "쓰지 않는다"를 코드로
// 적어 두려고 남긴 것이고, 판정에는 쓰이지 않는다 — 판정은 위 FIELD 허용목록 하나뿐이다.
// 목록에 없는 필드는 새로 생겨도 자동으로 빠진다.
export const NEVER_EXPORT = Object.freeze([
  // Working Status. 첫 드라이런에서 이 값이 "고용형태 Probation" 으로 메시지 1 에
  // 그대로 실렸다. 프로필에 적혀 있다는 것과 그 사람이 있는 프로젝트 채널에 봇이 다시
  // 적어도 된다는 것은 다른 말이다 — 수습 여부는 본인이 그 자리에 앉아 있는데 제3자가
  // 공표할 값이 아니다. 허용목록에서 뺐으므로 enrichPerson 의 반환 객체에 담기지 않고,
  // 담기지 않으므로 슬랙·MD·프롬프트 어느 쪽으로도 새어 나갈 경로가 없다.
  'Xf05E101BB16', // Working Status (Probation 등 고용형태)
  'Xf03KPCRAR3Q', // Phone
  'Xf070QN26WG5', // Gmail
  'Xf08JNGW89UP', // KakaoID
  'Xf0APLP5KGTX', // Emergency Contact 1
  'Xf0AQ33DSA49', // Emergency Contact 2
  'Xf0A2RP400MC', // Apple store email
  'Xf03JWSA1H0W', // Name Recording (음성 파일)
  'profile.email',
]);

const CACHE_VERSION = 1;
const CACHE_NAME = 'people-directory.json';

const clip = (s, max) => {
  const t = String(s == null ? '' : s);
  return t.length > max ? `${t.slice(0, max)}…` : t;
};
const err = (e) => clip(String(e?.message || e).split('\n')[0], 100);

// ── 1) 디렉터리 캐시 ────────────────────────────────────────────────────────
//
// users.list 는 4페이지·3993명이고 전체 조회에 4~5초 걸린다(2026-08-31 실측).
// 선응답 경로에서 매번 부를 수 있는 값이 아니다. 그래서 파일 캐시를 두고, 갱신은
// 데몬의 30분 주기 작업에 얹는다(glossarySync 와 같은 자리). 선응답은 캐시만 읽는다.
export function directoryCachePath(dir) {
  return join(String(dir || '.'), CACHE_NAME);
}

export function directoryCache({ dir } = {}) {
  try {
    const path = directoryCachePath(dir);
    if (!existsSync(path)) return null;
    const obj = JSON.parse(readFileSync(path, 'utf8'));
    if (!obj || typeof obj !== 'object' || !obj.people) return null;
    return {
      version: Number(obj.version) || CACHE_VERSION,
      fetchedAt: Number(obj.fetchedAt) || 0,
      count: Number(obj.count) || Object.keys(obj.people).length,
      people: obj.people,
    };
  } catch {
    return null;
  }
}

// items.jsonl 과 같은 임시 파일 후 rename. 중간에 죽어도 반쯤 쓰인 캐시가 남지 않는다 —
// 반쯤 쓰인 JSON 은 다음 부팅에서 파싱 실패가 되고, 그러면 조회 결과가 통째로 사라진다.
function writeCache(dir, payload) {
  mkdirSync(dir, { recursive: true });
  const path = directoryCachePath(dir);
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(payload));
  renameSync(tmp, path);
  return path;
}

// unref 하지 않는다. 데몬은 소켓이 있어 어느 쪽이든 살아 있지만, 짧게 살다 끝나는
// 호출자(드라이런 하네스)에서는 unref 된 타이머가 이벤트 루프를 붙잡지 못해 페이지
// 사이 대기 중에 프로세스가 그냥 끝난다 — 실제로 그렇게 죽었다. 대기는 길어야 몇 초다.
const sleep = (ms) => new Promise((r) => { setTimeout(r, ms); });

// users.list 커서 페이지네이션 전체. 실패하면 던지지 않고 { ok:false } 를 돌려주며
// 기존 캐시는 손대지 않는다 — 낡은 캐시가 없는 캐시보다 낫다. 두 페이지째에서 죽었을 때
// 반쪽짜리 디렉터리로 덮어쓰면 "디렉터리에 없음"이 거짓말이 된다.
export async function refreshDirectory({ slack, dir, log = () => {}, pageDelayMs = 1200 } = {}) {
  if (typeof slack !== 'function') return { ok: false, error: '슬랙 호출기가 없음' };
  try {
    const people = {};
    let cursor = '';
    let pages = 0;
    for (;;) {
      const res = await slack('users.list', { limit: 1000, ...(cursor ? { cursor } : {}) });
      for (const u of res.members || []) {
        if (!u?.id) continue;
        people[u.id] = {
          id: u.id,
          realName: String(u.profile?.real_name || u.real_name || '').trim(),
          displayName: String(u.profile?.display_name || u.name || '').trim(),
          title: String(u.profile?.title || '').trim(),
          tz: String(u.tz || '').trim(),
          deleted: Boolean(u.deleted),
          isBot: Boolean(u.is_bot),
        };
      }
      pages += 1;
      cursor = res.response_metadata?.next_cursor || '';
      if (!cursor) break;
      if (pages > 20) break; // 커서가 안 끝나는 사고를 무한 루프로 만들지 않는다
      // 레이트리밋(users.list 는 Tier 2). 페이지 사이를 1초 이상 쉰다.
      await sleep(pageDelayMs);
    }
    const count = Object.keys(people).length;
    if (!count) return { ok: false, error: 'users.list 가 0명을 돌려줌' };
    const path = writeCache(dir, { version: CACHE_VERSION, fetchedAt: Date.now(), count, people });
    log(`사람 디렉터리 갱신 — ${pages}페이지 ${count}명`);
    return { ok: true, count, pages, path };
  } catch (e) {
    return { ok: false, error: err(e) };
  }
}

// ── 2) 이름 해석 ────────────────────────────────────────────────────────────
//
// 부분 문자열 매칭은 틀린다. `amani` 로 substring 을 걸면 Balasubramani ·
// Chirag kamani · Messaoui Amani15 가 함께 걸린다(2026-08-31 실측). 그래서 토큰 단위
// 경계 매칭만 쓰고, 연속 토큰 두 개 이상이 맞아야 후보로 본다. 한 토큰만으로는
// 매칭하지 않는다 — 3993명 디렉터리에서 first name 하나는 거의 언제나 여러 명이다.
const TOKEN_RE = /[\p{L}\p{N}]+/gu;

function tokens(s) {
  return String(s || '').toLowerCase().match(TOKEN_RE) || [];
}

// 괄호 안은 한글 표기·별칭이라 이름 토큰에서 뗀다. "Amani Kanu (아마니)" 의 토큰은
// [amani, kanu] 다. 떼지 않으면 "아마니" 한 토큰이 남아 한글 본문에서 단독 매칭된다.
function nameTokens(name) {
  return tokens(String(name || '').replace(/[([][^)\]]*[)\]]/g, ' '))
    .filter((t) => t.length >= 2);
}

function bigrams(arr) {
  const out = [];
  for (let i = 0; i + 1 < arr.length; i += 1) out.push(`${arr[i]} ${arr[i + 1]}`);
  return out;
}

// 토큰마다 그 토큰이 어떤 자리에 있는지를 함께 돌려준다.
//   ''        — 본문에 그냥 적힌 낱말. 조회 대상이다.
//   'mention' — `@` 로 시작한 이름 안. 읽는 사람이 슬랙에서 눌러 프로필을 볼 수 있다.
//   'speaker' — 스레드 줄머리의 발화자 라벨(`이름: 본문`). 말한 사람이지 이야기된 사람이 아니다.
//
// 왜 <@U…> 정규식 하나로 끝내지 않는가: 데몬의 cleanText 가 <@U…> 를 이미
// `@표시이름` 으로 바꿔 놓는다(slack-eyes-daemon.mjs cleanText). 그래서 이 층에
// 들어오는 본문에는 원시 멘션이 남아 있지 않다 — items.jsonl 의 textEn 을 훑어
// `<@U` 는 0건이었다(2026-08-31 실측). 원시 형태만 보고 멘션을 가려내면 이 규칙은
// 운영 경로에서 아무 일도 하지 않는다. 그래서 `@` 뒤에 공백 하나로 이어지는 낱말들을
// 같은 멘션 이름으로 묶는다. 구분자가 공백 하나가 아니면 이름이 거기서 끝난 것으로
// 본다 — "@Ho Young Yang (양호영)" 의 괄호 앞에서 끊겨야 "양호영" 이 이름 토큰으로
// 딸려 들어가지 않는다.
//
// 발화자 라벨도 같은 이유로 뺀다. gatherContext 는 스레드를 `${userName}: ${본문}` 한
// 줄씩으로 접는다(slack-eyes-daemon.mjs). 이 라벨을 평문 이름으로 세면 스레드에 말을
// 보탠 사람이 전원 조회 대상이 된다 — 첫 드라이런에서 야샬이 후보로 올라온 실제 경로가
// 멘션이 아니라 이 라벨이었다. 말한 사람은 스레드에 그 자리로 이미 있어서 누를 수 있고,
// 이 층이 더하는 값은 누를 수 없는 것을 조회해 주는 것 하나뿐이다.
const SPEAKER_LABEL_RE = /^([^\n:]{1,60}):[ \t]/;

function tokenRoles(s) {
  const text = String(s || '');
  // 줄머리 발화자 라벨이 차지하는 글자 범위를 먼저 잡아 둔다.
  const labels = [];
  let lineStart = 0;
  for (const line of text.split('\n')) {
    const m = SPEAKER_LABEL_RE.exec(line);
    if (m) labels.push([lineStart, lineStart + m[1].length]);
    lineStart += line.length + 1;
  }
  const inLabel = (i) => labels.some(([a, b]) => i >= a && i < b);

  const re = new RegExp(TOKEN_RE.source, 'gu');
  const seq = [];
  const kind = [];
  let inMention = false;
  let prevEnd = -1;
  let m;
  while ((m = re.exec(text)) !== null) {
    const start = m.index;
    if (text[start - 1] === '@') inMention = true;
    else if (inMention && text.slice(prevEnd, start) !== ' ') inMention = false;
    seq.push(m[0].toLowerCase());
    kind.push(inMention ? 'mention' : (inLabel(start) ? 'speaker' : ''));
    prevEnd = start + m[0].length;
  }
  return { seq, kind };
}

// 사람 이름처럼 보이지만 디렉터리에 없는 것을 잡는 자리. 대문자로 시작하는 두 낱말이
// 이어진 곳만 본다. 여기서 걸리는 잡음은 대부분 역할·직책 낱말이라(Growth Owner,
// Brand Marketing) 아래 목록으로 뺀다. 목록이 길어지는 것은 감수한다 — 반대로 하면
// (=이름 후보를 좁게 잡으면) "Al Rizqi 는 디렉터리에 없다" 가 통째로 사라지고, 그
// 한 줄이 이 층 전체의 값어치다.
const NOT_A_NAME = new Set([
  'the', 'this', 'that', 'these', 'those', 'we', 'you', 'they', 'it', 'he', 'she', 'i',
  'and', 'or', 'but', 'for', 'with', 'from', 'about', 'more', 'info', 'new', 'also',
  'can', 'will', 'would', 'should', 'could', 'may', 'please', 'thanks', 'thank',
  'today', 'tomorrow', 'yesterday', 'joined', 'joining', 'join', 'hire', 'hires',
  'crypto', 'web3', 'brand', 'growth', 'owner', 'lead', 'leader', 'head', 'manager',
  'marketing', 'sales', 'product', 'project', 'team', 'teams', 'global', 'strategy',
  'campaign', 'community', 'content', 'execution', 'responsible', 'charge', 'overall',
  'target', 'channel', 'partner', 'user', 'users', 'analysis', 'performance', 'business',
  'company', 'group', 'meeting', 'update', 'updates', 'note', 'notes', 'deck', 'week',
  'month', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
  'localization', 'education', 'educational', 'messaging', 'tone', 'manner',
]);

// 대문자 시작 + 나머지 소문자인 낱말만 이름 조각으로 본다. GTM · MPC · SEA · KOL 같은
// 전부 대문자 약어와 Web3 처럼 숫자가 섞인 낱말은 이름이 아니다.
const NAME_WORD_RE = /^[A-Z][a-z]{1,}$/;

// 두 낱말 사이가 공백 하나일 때만 이어진 이름으로 본다. 구분자를 뭉뚱그려 나누면
// 괄호나 줄바꿈을 건너뛴 쌍이 생긴다 — "…Cho Chung Hyun)\nAkash Deshmukh" 에서
// "Hyun Akash" 가 이름 후보로 잡혔다. 이름은 구두점을 넘어가지 않는다.
function capitalizedPairs(text) {
  const out = [];
  const re = /([A-Za-z][A-Za-z']*) ([A-Za-z][A-Za-z']*)/g;
  const s = String(text || '');
  let m;
  while ((m = re.exec(s)) !== null) {
    // 겹치는 쌍(A B, B C)을 모두 보려면 한 칸씩 되감아야 한다.
    re.lastIndex = m.index + m[1].length + 1;
    const [, a, b] = m;
    if (!NAME_WORD_RE.test(a) || !NAME_WORD_RE.test(b)) continue;
    if (NOT_A_NAME.has(a.toLowerCase()) || NOT_A_NAME.has(b.toLowerCase())) continue;
    out.push(`${a} ${b}`);
  }
  return out;
}

// 디렉터리 한 벌에서 "연속 토큰 2개" 색인을 만든다. 3993명 × 이름 두 벌이라 매번
// 만들어도 수십 ms 지만, 같은 캐시로 여러 번 부를 때를 위해 캐시 객체에 붙여 둔다.
function nameIndex(cache) {
  if (cache.__index) return cache.__index;
  const index = new Map(); // "amani kanu" -> [person, …]
  // alias 는 괄호 안까지 포함한 전체 토큰의 연속쌍이다. 해석에는 쓰지 않고, "이름처럼
  // 보이는데 디렉터리에 없다" 목록에서 빼는 데만 쓴다. 이 워크스페이스의 표시 이름은
  // "Lion cho (조중현,Cho Chung Hyun)" 처럼 괄호 안에 로마자 표기를 함께 담는 일이
  // 흔해서, 괄호를 뗀 색인만 두면 그 표기가 통째로 "모르는 사람"으로 올라온다.
  const alias = new Set();
  for (const p of Object.values(cache.people || {})) {
    if (!p) continue;
    for (const n of [p.realName, p.displayName]) {
      for (const g of bigrams(tokens(n).filter((t) => t.length >= 2))) alias.add(g);
    }
    if (p.isBot) continue;
    const keys = new Set();
    for (const n of [p.realName, p.displayName]) {
      for (const g of bigrams(nameTokens(n))) keys.add(g);
    }
    for (const k of keys) {
      if (!index.has(k)) index.set(k, []);
      index.get(k).push(p);
    }
  }
  index.__alias = alias;
  try { Object.defineProperty(cache, '__index', { value: index, enumerable: false }); }
  catch { /* 얼려 둔 캐시면 색인만 다시 만든다 — 정확도에는 영향이 없다 */ }
  return index;
}

const MAX_PEOPLE = 5;

// text 는 이 메시지, ctx 는 같은 스레드다. 채널 최근 대화는 넣지 않는다 — 날짜가 넘어가면
// 화제가 통째로 바뀌고, 그러면 이 메시지와 아무 상관 없는 사람이 조회되어 나간다
// (glossaryContext · resolveAccess 의 messageOnly 가 같은 이유로 생겼다).
export function resolveNames({ text = '', ctx = '', cache = null, selfIds = [] } = {}) {
  const empty = { resolved: [], unresolved: [], mentioned: [] };
  try {
    if (!cache || !cache.people) return empty;
    const skip = new Set((selfIds || []).filter(Boolean));
    const index = nameIndex(cache);
    const haystacks = [String(text || ''), String(ctx || '')];
    const picked = new Map(); // id -> row (조회 대상)
    const mentioned = new Map(); // id -> row (멘션으로만 나온 사람 — 조회하지 않는다)
    const matchedPairs = new Set();

    // (a) 멘션은 조회 대상이 아니다.
    //
    // 첫 드라이런에서 야샬이 후보로 올라왔다. 그는 원문 마지막 줄 "sync @Yashal Nawaid"
    // 에서 참조로 걸린 사람이지 이야기의 대상이 아니었고, 그의 프로필을 봇이 줄 세워
    // 다시 적는 것은 더한 것이 없다. 멘션은 읽는 사람이 슬랙에서 눌러 프로필을 볼 수
    // 있기 때문이다. 평문 이름은 누를 수 없다 — 이 층이 더하는 값은 "누를 수 없는 것을
    // 조회해 준다" 하나뿐이므로, 누를 수 있는 것은 조회하지 않는다.
    //
    // 다만 목록에서 지우지는 않는다. 무엇을 일부러 조회하지 않았는지가 어디에도 남지
    // 않으면 나중에 "왜 이 사람은 안 봤지" 가 다시 사람의 일이 된다. mentioned 로만
    // 돌려주고, 이 값은 원장과 MD 에만 실린다(메시지 1 에는 싣지 않는다).
    const noteMention = (id, why = 'mention') => {
      if (!id || skip.has(id)) return;
      const p = cache.people[id];
      if (!p || p.isBot) return;
      if (!mentioned.has(id)) mentioned.set(id, { ...p, why });
    };

    // (a-1) 원시 <@Uxxx> 형태. 정제 전 본문을 그대로 받는 호출자를 위해 남겨 둔다.
    for (const hay of haystacks) {
      for (const m of String(hay).matchAll(/<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/g)) noteMention(m[1]);
    }

    // (b) 평문 이름 — 연속 토큰 2개 경계 매칭.
    for (const hay of haystacks) {
      const { seq, kind } = tokenRoles(hay);
      const pairs = bigrams(seq);
      for (let i = 0; i < pairs.length; i += 1) {
        const g = pairs[i];
        const hits = index.get(g);
        if (!hits || !hits.length) continue;
        matchedPairs.add(g);
        // (a-2) cleanText 가 남긴 `@이름` 형태와 스레드 발화자 라벨. 두 토큰이 모두 같은
        // 자리에 있을 때만 그 자리로 본다. 같은 사람이 다른 자리에서 평문으로도 나오면
        // 그 자리에서 후보가 된다 — 한 번 멘션됐다는 이유로 평문 매칭을 지우지 않는다.
        if (kind[i] && kind[i] === kind[i + 1]) {
          for (const p of hits) noteMention(p.id, kind[i]);
          continue;
        }
        const live = hits.filter((p) => !p.deleted && !skip.has(p.id));
        const dead = hits.filter((p) => p.deleted && !skip.has(p.id));
        // 활성이 비활성보다 앞선다. 같은 이름으로 퇴사자 계정이 남아 있는 경우가 있고
        // (Amani Kanu 는 비활성 U0543HX8U5N 이 따로 있다) 그때 퇴사자를 골라 내보내면
        // 그 자체가 틀린 답이다.
        const chosen = live.length ? live : dead;
        if (!chosen.length) continue;
        const head = chosen[0];
        if (picked.has(head.id)) continue;
        picked.set(head.id, {
          ...head,
          via: 'name',
          // 활성이 둘 이상이면 하나로 고르지 않는다. 동명이인이라는 사실 자체가 조회
          // 결과이고, 그것을 감추고 하나를 고르면 틀린 사람의 이력이 나간다.
          ambiguousWith: live.length > 1 ? live.slice(1).map((p) => p.id)
            : (live.length === 1 && dead.length ? dead.map((p) => p.id) : []),
          ambiguousDeletedOnly: live.length === 1 && dead.length > 0,
        });
      }
      if (picked.size >= MAX_PEOPLE) break;
    }

    // (c) 해석되지 않은 이름. 이 목록을 버리면 이 층 전체가 실패다 — "Al Rizqi 는
    // 슬랙 디렉터리 3993명 중 0건" 이 나오는 자리가 여기다.
    const unresolved = [];
    for (const hay of haystacks) {
      for (const pair of capitalizedPairs(hay)) {
        const key = tokens(pair).join(' ');
        if (matchedPairs.has(key)) continue;
        if (index.has(key)) continue;
        if (index.__alias?.has(key)) continue;
        if (unresolved.some((u) => tokens(u).join(' ') === key)) continue;
        unresolved.push(pair);
      }
    }

    const resolved = [...picked.values()].slice(0, MAX_PEOPLE).map((p) => ({
      id: p.id,
      realName: p.realName,
      displayName: p.displayName,
      title: p.title,
      tz: p.tz,
      deleted: p.deleted,
      via: p.via,
      ambiguousWith: p.ambiguousWith || [],
      ambiguousDeletedOnly: Boolean(p.ambiguousDeletedOnly),
    }));
    // 평문으로도 나와서 후보가 된 사람은 멘션 목록에서 뺀다. 같은 사람이 양쪽에
    // 있으면 "조회했다"와 "조회하지 않았다"가 한 줄씩 나가서 서로를 부정한다.
    const mentionedOut = [...mentioned.values()]
      .filter((p) => !picked.has(p.id))
      .slice(0, MAX_PEOPLE)
      .map((p) => ({ id: p.id, name: p.realName || p.displayName || p.id, why: p.why || 'mention' }));
    return { resolved, unresolved: unresolved.slice(0, MAX_PEOPLE), mentioned: mentionedOut };
  } catch {
    return empty;
  }
}

// ── 3) 한 사람 상세 ─────────────────────────────────────────────────────────
//
// users.list 의 profile.fields 는 항상 null 이다(실측). 커스텀 필드를 보려면 사람마다
// users.profile.get 을 따로 불러야 한다. 그래서 이 호출은 해석된 사람 수만큼만 돈다.
export async function enrichPerson({ slack, id, timeoutMs = 1500 } = {}) {
  if (typeof slack !== 'function') return { id, error: '조회 실패 — 슬랙 호출기가 없음' };
  try {
    const timeout = new Promise((resolve) => {
      const t = setTimeout(() => resolve('__timeout__'), timeoutMs);
      t.unref?.();
    });
    const res = await Promise.race([slack('users.profile.get', { user: id }), timeout]);
    if (res === '__timeout__') return { id, error: `조회 실패 — ${timeoutMs}ms 안에 응답 없음` };
    const p = res?.profile || {};
    const f = p.fields || {};
    const v = (key) => {
      const raw = f[FIELD[key]]?.value;
      const s = String(raw == null ? '' : raw).trim();
      return s || '';
    };
    // 허용목록. 여기 없는 필드는 반환 객체에 담기지 않는다 — 담기지 않으면 새어 나갈
    // 경로 자체가 없다. profile.email 은 이 객체를 만들 때 아예 읽지 않는다.
    return {
      id,
      realName: String(p.real_name || '').trim(),
      displayName: String(p.display_name || '').trim(),
      title: String(p.title || '').trim() || v('title'),
      organization: v('organization'),
      division: v('division'),
      department: v('department'),
      departmentProject: v('departmentProject'),
      startDate: v('startDate'),
      country: v('country1') || v('country2'),
      location: v('location'),
      city: v('city'),
      linkedin: v('linkedin'),
      fieldCount: Object.keys(f).length,
    };
  } catch (e) {
    return { id, error: `조회 실패 — ${err(e)}` };
  }
}

// ── 4) 요청 항목 ────────────────────────────────────────────────────────────
//
// "필요정보: 이름/국적/연차/최종학위/전공/링크드인" 처럼 상대가 항목을 적어 보낸 자리를
// 읽는다. 적지 않았으면 기본 항목만 본다. 이 목록이 있어야 "무엇을 못 채웠는지"를
// 말할 수 있고, 그것이 이 층이 내는 값의 절반이다.
const REQUEST_FIELDS = [
  { key: 'name', label: '이름', re: /이름|full\s*name|\bname\b/i, source: 'slack' },
  { key: 'country', label: '국적', re: /국적|nationality|country/i, source: 'slack' },
  { key: 'years', label: '연차', re: /연차|경력|years?\s+of\s+experience|yoe/i, source: 'slack' },
  { key: 'degree', label: '최종학위', re: /최종\s*학위|학위|degree|mba|education/i, source: 'none' },
  { key: 'major', label: '전공', re: /전공|major/i, source: 'none' },
  { key: 'linkedin', label: '링크드인', re: /링크드인|linked\s*-?\s*in/i, source: 'slack' },
  { key: 'title', label: '직책', re: /직책|직함|포지션|position|title|role/i, source: 'slack' },
  { key: 'department', label: '부서', re: /부서|소속|department|team/i, source: 'slack' },
];

const DEFAULT_REQUEST = ['title', 'department', 'country', 'years', 'linkedin'];

export function requestedFields(text = '') {
  const t = String(text || '');
  const hit = REQUEST_FIELDS.filter((f) => f.re.test(t)).map((f) => f.key);
  return hit.length ? hit : DEFAULT_REQUEST.slice();
}

// ── 5) 연차 ─────────────────────────────────────────────────────────────────
//
// Start Date 가 있을 때만 계산한다. profile 의 updated 타임스탬프를 입사일로 쓰지
// 않는다 — 그것은 프로필을 마지막으로 고친 시각이고, 어제 프로필을 고친 10년차가
// 0년차로 나간다.
export function tenure(startDate, now = new Date()) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(startDate || '').trim());
  if (!m) return null;
  const start = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  if (Number.isNaN(start.getTime()) || start > now) return null;
  let months = (now.getFullYear() - start.getFullYear()) * 12 + (now.getMonth() - start.getMonth());
  if (now.getDate() < start.getDate()) months -= 1;
  if (months < 0) months = 0;
  const y = Math.floor(months / 12);
  const mo = months % 12;
  return y ? `${y}년${mo ? ` ${mo}개월` : ''}` : `${mo}개월`;
}

// ── 6) 묶기 ─────────────────────────────────────────────────────────────────
export async function peopleContext({
  slack, text = '', ctx = '', cache = null, selfIds = [],
  notionHrDbId = null, timeoutMs = 1500, now = new Date(), log = () => {},
  directoryError = '',
} = {}) {
  const base = {
    grade: 'C0', rows: [], unresolved: [], mentioned: [], sources: [], promptText: '',
    requested: [], missingEverywhere: [],
  };
  try {
    const requested = requestedFields(text);
    const noSource = REQUEST_FIELDS.filter((f) => requested.includes(f.key) && f.source === 'none')
      .map((f) => f.label);

    const dirState = cache
      ? `조회 ${cache.count}명 중 %RESOLVED%명 해석`
      : (directoryError ? `조회 실패 — ${clip(directoryError, 60)}` : '캐시 없음 — 아직 조회하지 않음');

    const { resolved, unresolved, mentioned } = resolveNames({ text, ctx, cache, selfIds });

    const rows = [];
    for (const p of resolved) {
      const det = await enrichPerson({ slack, id: p.id, timeoutMs });
      const name = p.realName || p.displayName || p.id;
      const status = p.deleted ? '비활성' : '활성';
      const lines = [];
      const missing = [];
      // facts 는 조회로 실제 얻은 값만 담는다. 라벨("직책")도, 미입력 표시도, 우리가
      // 지어 붙인 문장도 담지 않는다. lines 에서 값을 도로 파내는 방법을 쓰지 않은
      // 이유가 이것이다 — 값과 라벨이 한 문자열로 붙은 뒤에는 어디까지가 조회한 것인지
      // 다시 가를 방법이 없고, 가르려고 만든 정규식은 라벨이 하나 늘 때마다 조용히
      // 틀린다. 값이 있는 자리에서 값을 그대로 옆에 적어 두는 쪽이 싸고 안 틀린다.
      const facts = [];
      // 사람 줄 안에 이미 "미입력 / 근거 없음" 으로 적힌 항목. 이 이름을 아래 미조회
      // 줄에서 뺀다 — 같은 말을 두 줄에 걸쳐 두 번 하는 자리였다.
      const inlineMissing = [];
      if (det.error) {
        lines.push(`상세 ${det.error}`);
        for (const key of requested) {
          const f = REQUEST_FIELDS.find((x) => x.key === key);
          if (f && f.key !== 'name') missing.push(f.label);
        }
      } else {
        const has = (s) => Boolean(s && String(s).trim());
        const want = (k) => requested.includes(k);
        const fact = (v) => { const s = String(v == null ? '' : v).trim(); if (s) facts.push(s); };
        const title = det.title || p.title;
        if (has(title)) { lines.push(`직책 ${title}`); fact(title); }
        else if (want('title')) missing.push('직책');
        const dept = det.departmentProject || det.department || det.division || det.organization;
        if (has(dept)) { lines.push(`부서 ${dept}`); fact(dept); }
        else if (want('department')) missing.push('부서');
        // tz 를 국적으로 쓰지 않는다. 타임존은 지금 어디서 일하는지에 가깝고 국적이
        // 아니다 — Akash 는 Asia/Kolkata 지만 그것으로 인도 국적이라고 적으면 그것이
        // 바로 이 층이 막으려던 "없는 것을 있는 것처럼" 이다.
        //
        // 같은 이유로 타임존은 facts 에도 담지 않는다. 국적을 조회하려다 못 얻은
        // 자리이므로 그 항목에서 얻은 값은 0 이다. 여기서 타임존을 신규성 근거로
        // 세면 "국적을 알아냈다" 로 새는 값이 F2 취소의 근거가 된다.
        if (has(det.country)) { lines.push(`국적 ${det.country}`); fact(det.country); }
        else if (has(p.tz)) { lines.push(`국적 미입력 (타임존 ${p.tz})`); inlineMissing.push('국적'); if (want('country')) missing.push('국적'); }
        else { lines.push('국적 미입력'); inlineMissing.push('국적'); if (want('country')) missing.push('국적'); }
        if (has(det.location) || has(det.city)) {
          lines.push(`근무지 ${det.location || det.city}`);
          fact(det.location || det.city);
        }
        if (has(det.startDate)) {
          const t = tenure(det.startDate, now);
          lines.push(`입사일 ${det.startDate}${t ? ` (${t})` : ''}`);
          fact(det.startDate);
          fact(t);
        } else {
          lines.push('입사일 미입력 · 연차 근거 없음');
          inlineMissing.push('연차');
          if (want('years')) missing.push('연차');
        }
        if (has(det.linkedin)) { lines.push(`링크드인 ${det.linkedin}`); fact(det.linkedin); }
        else { lines.push('링크드인 미입력'); inlineMissing.push('링크드인'); if (want('linkedin')) missing.push('링크드인'); }
        for (const label of noSource) if (!missing.includes(label)) missing.push(label);
      }
      const notes = [];
      if (p.ambiguousWith.length) {
        notes.push(p.ambiguousDeletedOnly
          ? `같은 이름의 비활성 계정 ${p.ambiguousWith.length}건 있음`
          : `같은 이름의 활성 계정이 ${p.ambiguousWith.length + 1}명 — 동일인 확정 못 함`);
      }
      rows.push({ name, id: p.id, status, lines, missing, notes, facts, inlineMissing,
        ambiguous: p.ambiguousWith.length });
    }

    const unresolvedRows = unresolved.map((n) => ({
      name: n,
      where: '슬랙 디렉터리',
      result: cache ? `${cache.count}명 중 0건` : '0건 (캐시 없음)',
    }));

    const sources = [
      { name: '슬랙 사용자 디렉터리', state: dirState.replace('%RESOLVED%', String(rows.length)) },
      { name: '노션 HR DB', state: notionHrDbId ? '미구현 — DB id 는 있으나 이 판에서는 조회하지 않음' : '미설정' },
      { name: '스레드', state: `이름 후보 ${rows.length + unresolvedRows.length}건 추출` },
    ];
    if (noSource.length) {
      sources.push({ name: noSource.join('/'), state: '어느 출처에도 없음' });
    }

    const grade = rows.length === 0 ? 'C0'
      : (rows.some((r) => r.missing.length) || unresolvedRows.length ? 'C1' : 'C2');

    const pc = {
      grade, rows, unresolved: unresolvedRows, mentioned: mentioned || [], sources,
      requested: requested.map((k) => REQUEST_FIELDS.find((f) => f.key === k)?.label || k),
      missingEverywhere: noSource,
      promptText: '',
    };
    pc.promptText = renderPromptText(pc);
    return pc;
  } catch (e) {
    log(`사람 조회 실패: ${err(e)}`);
    return { ...base, sources: [{ name: '슬랙 사용자 디렉터리', state: `조회 실패 — ${err(e)}` }],
      promptText: `[사람 조회] 조회 실패 — ${err(e)}` };
  }
}

// 모델 프롬프트에 실릴 문자열. 다른 층들과 같은 모양이다 — 대괄호 머리표 하나에
// 내용이 이어진다. 여기서 라벨 틀을 새로 만들지 않는다.
function renderPromptText(pc) {
  if (!pc.rows.length && !pc.unresolved.length) {
    return '[사람 조회] 이 대화에서 조회할 사람 이름을 찾지 못함';
  }
  const out = ['[사람 조회 · 슬랙 사용자 디렉터리에서 실제로 읽은 값]'];
  for (const r of pc.rows) {
    out.push(`- ${r.name} (${r.status}, ${r.id}): ${r.lines.join(' · ')}`);
    for (const n of r.notes || []) out.push(`  ※ ${n}`);
    if (r.missing.length) out.push(`  못 채운 항목: ${r.missing.join(', ')}`);
  }
  for (const u of pc.unresolved) out.push(`- ${u.name}: ${u.where} ${u.result} — 우리 로스터에 없는 사람이다`);
  // 일부러 조회하지 않은 사람. 이 줄이 없으면 "왜 이 사람은 안 봤지" 가 나중에 다시
  // 사람의 일이 된다. 프로필 값은 한 글자도 싣지 않는다 — 이름만 적는다.
  const byWhy = (why) => (pc.mentioned || []).filter((m) => m.why === why).map((m) => m.name);
  const mentions = byWhy('mention');
  const speakers = byWhy('speaker');
  if (mentions.length) {
    out.push(`- 멘션으로 걸린 사람(조회하지 않음 — 슬랙에서 눌러 프로필을 볼 수 있다): ${mentions.join(', ')}`);
  }
  if (speakers.length) {
    out.push(`- 이 스레드에서 말한 사람(조회하지 않음 — 이야기의 대상이 아니다): ${speakers.join(', ')}`);
  }
  out.push(`조회처: ${pc.sources.map((s) => `${s.name} ${s.state}`).join(' · ')}`);
  out.push('위 값은 조회 결과다. 여기 없는 항목은 조회하지 못한 것이므로 추측해서 채우지 말고,'
    + ' 필요하면 "확인되지 않음"이라고 쓴다.');
  return out.join('\n');
}

// ── 7) 슬랙 메시지 1 ────────────────────────────────────────────────────────
//
// 이 함수는 모델을 부르지 않는다. 순수 템플릿 렌더다. 메시지 1의 모든 줄은 조회
// 결과이거나 미조회 표시여야 하고, 모델이 문장을 지으면 그 보장이 사라진다.
const HEAD = '컨텍스트 매니지먼트 에이전트입니다. 아래는 조회한 것과 조회하지 못한 것입니다.';

function personBlock(r) {
  const lines = [`• ${r.name} (${r.status}) — ${r.lines[0] || '조회된 항목 없음'}`];
  const rest = r.lines.slice(1);
  // 이어지는 값은 두 줄까지 접어 넣는다. 한 줄에 다 붙이면 슬랙에서 가로로 흘러
  // 모바일에서 읽히지 않고, 한 값마다 한 줄이면 사람 하나가 화면을 다 먹는다.
  let cur = '';
  for (const piece of rest) {
    if (!cur) { cur = piece; continue; }
    if (`${cur} · ${piece}`.length > 90) { lines.push(`  ${cur}`); cur = piece; }
    else cur = `${cur} · ${piece}`;
  }
  if (cur) lines.push(`  ${cur}`);
  for (const n of r.notes || []) lines.push(`  ※ ${n}`);
  // 사람 줄에 이미 "국적 미입력 · 입사일 미입력 · 연차 근거 없음 · 링크드인 미입력" 이
  // 적혀 있는데 바로 다음 줄에 "미조회 국적/연차/링크드인" 을 또 적으면 같은 말을 두 번
  // 하는 것이다. 읽는 사람은 두 줄을 대조해 보고 나서야 둘이 같다는 것을 안다. 여기
  // 남길 것은 위에 아예 나타나지 않는 항목 — 최종학위·전공처럼 슬랙 프로필에 필드
  // 자체가 없어 줄로 적을 수조차 없는 것 — 뿐이다.
  const shown = new Set(r.inlineMissing || []);
  const unshown = (r.missing || []).filter((m) => !shown.has(m));
  if (unshown.length) lines.push(`  미조회 ${unshown.join('/')}`);
  return lines;
}

export function renderContextMessage(pc, { maxLines = 12, maxChars = 1200 } = {}) {
  try {
    if (!pc || (!pc.rows?.length && !pc.unresolved?.length)) return '';
    const blocks = [
      ...(pc.rows || []).map(personBlock),
      ...(pc.unresolved || []).map((u) => [`• ${u.name} — ${u.where} ${u.result} (계정 없음)`]),
    ];
    const foot = `조회처: ${(pc.sources || []).map((s) => `${s.name} ${s.state}`).join(' · ')}`;
    const assemble = (n) => {
      const kept = blocks.slice(0, n).flat();
      const dropped = blocks.length - n;
      return [HEAD, '', ...kept, '',
        foot + (dropped > 0 ? ` · 외 ${dropped}명은 MD 파일에` : '')].join('\n');
    };
    // 상한을 넘으면 문장 중간을 자르지 않는다. 사람 단위로 뒤를 떨어뜨리고 몇 명이
    // 빠졌는지를 마지막 줄에 적는다 — 잘린 문장을 슬랙에 남기는 것은 요약이 아니라
    // 훼손이다(설계 §7-1, slackBrief 와 같은 규칙).
    let n = blocks.length;
    for (; n > 1; n -= 1) {
      const body = assemble(n);
      if (body.split('\n').length <= maxLines && body.length <= maxChars) return body;
    }
    return assemble(1);
  } catch {
    return '';
  }
}

// ── 8) 신규성 탐침 ──────────────────────────────────────────────────────────
//
// F2 강등 취소("축 0 이 스레드에 없는 사실을 가져왔는가")를 잴 때 novelty-gate 에
// 넣을 문자열이다. 신규성 판정기는 여전히 하나뿐이고(novelty-gate.mjs), 여기서 정하는
// 것은 그 판정기에 무엇을 먹일지뿐이다.
//
// 왜 렌더된 메시지 1 을 넣지 않는가: 넣었더니 취소가 무조건 참이 됐다. 근거로 찍힌
// "스레드에 없는 새 토큰" 8개가 전부 고정 서두였다 — 컨텍스트/매니지먼트/에이전트입니다/
// 아래는/조회한/것과/조회하지/못한. 서두는 언제나 같은 문장이니 스레드에 있을 리가 없고,
// 그래서 조회 결과가 0건인 날에도 여덟 개가 나온다. 그것은 판정이 아니라 상수다.
//
// 왜 렌더에서 틀을 빼는 방식(정규식으로 머리글·라벨을 지우는 방식)을 쓰지 않는가:
// 한 판을 그렇게 만들어 돌려 봤더니 남은 근거가 business·go·asia·kolkata·3993·0건
// 이었다. "Go-To-Market" 이 하이픈에서 쪼개져 go 가 남고, 국적 대신 딸려 온 타임존이
// 사실로 세어졌다. 빼는 목록은 라벨이 하나 늘 때마다 조용히 새고, 샌 것이 곧 취소
// 근거가 된다. 그래서 빼는 대신 더한다 — 조회해서 값을 얻은 그 자리에서 값만 모은다.
//
// 담는 것: 해석된 사람의 이름과 실제로 값이 있던 항목(직책·부서·국적·근무지·입사일·
// 연차·링크드인), 동명이인 건수, 그리고 미해석 이름과 그 0건 표시. 미해석 이름은
// 사실로 친다 — "우리 로스터에 없다" 는 스레드에서는 알 수 없던 것이다.
// 담지 않는 것: 고정 서두, 라벨, 조회처 문장, 미입력 표시. 전부 우리가 쓰는 말이지
// 조회한 값이 아니다.
export function noveltyProbe(pc) {
  if (!pc || typeof pc !== 'object') return '';
  const out = [];
  const push = (v) => { const s = String(v == null ? '' : v).trim(); if (s) out.push(s); };
  for (const r of pc.rows || []) {
    push(r.name);
    for (const f of r.facts || []) push(f);
    // 동명이인은 값이 아니라 건수로만 남는 사실이라 여기만 우리 낱말을 하나 쓴다.
    // 이 자리를 비우면 "같은 이름이 셋" 이라는 조회 결과가 통째로 사라진다.
    if (r.ambiguous) push(`동명이인 ${r.ambiguous}건`);
  }
  for (const u of pc.unresolved || []) push(`${u.name || ''} ${u.result || ''}`);
  return out.join('\n');
}

export default {
  directoryCache, directoryCachePath, refreshDirectory, resolveNames,
  enrichPerson, peopleContext, renderContextMessage, requestedFields, tenure,
  noveltyProbe, NEVER_EXPORT,
};
