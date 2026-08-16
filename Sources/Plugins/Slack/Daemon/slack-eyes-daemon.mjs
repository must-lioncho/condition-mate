#!/usr/bin/env node
// slack-eyes-daemon.mjs — Slack 👀(:eyes:) reaction → translation pipeline.
//
// Real-time: connects to Slack via Socket Mode (WebSocket, no public URL needed)
// and listens for reaction_added events by the authed user. When the reaction is
// :eyes: on a message, fetches the message text, translates it into the user's
// 목표 언어 (config.json {"lang": "ko"|…}, default 한국어 — already-in-target
// messages are passed through untranslated), and appends the result to
//   <data>/slack-translate/items.jsonl
// which the Condition Mate dashboard renders (원문+번역+슬랙 링크).
// The same LLM call runs 2차 의미 분석: the daemon first COLLECTS context (same
// thread replies, or the channel's recent messages) and the model explains what
// the message actually means/asks in that context after a ===MEANING=== marker
// (item.meaning) — starting with "컨텍스트 부족:" when even that context is not
// enough — then emits 의사결정 선택지 (1: 추천+이유 / 2: 대안) after a
// ===DECISION=== marker, stored as the item's `decision` field.
//
// Catch-up: on startup, reactions.list backfills 👀 items reacted while the
// daemon was down.
//
// 알림류(슬랙 Activity에 뜨는 것들): 다른 사람이 나를 <@MY_USER>로 멘션한 메시지
// (item.source='mention'), 내가 속한 유저그룹을 <!subteam^…>으로 부른 메시지
// ('team'), DM/그룹DM으로 온 메시지('dm'), 내가 있는 채널의 @here/@channel
// ('broadcast')가 같은 파이프라인으로 items.jsonl에 올라온다 (트리거 이모지 없음 —
// 처리완료 시 슬랙 리액션 동기화는 앱이 건너뛴다).
//
// 이 알림류는 두 경로로 들어온다 — 둘 다 켜 두는 것이 설계다:
//   1) 실시간 (Socket Mode message 이벤트) — 즉시. 스레드 답글까지 완전히 커버.
//      Slack 앱 설정 > Event Subscriptions > "Subscribe to events on behalf of
//      users"에 message.channels / message.groups / message.im / message.mpim을
//      추가해야 온다 (스코프 *:history는 이미 있음). 구독이 없으면 이 경로는
//      영원히 조용하다 — 그래서 2)가 있다.
//   2) 폴링 (activityPoll) — users.conversations로 내가 속한 대화를 훑고
//      conversations.history(oldest=커서)로 새 메시지를 직접 검사한다. 앱 설정을
//      건드리지 않아도 동작하며, 데몬이 꺼져 있던 동안 놓친 것도 복구한다.
//      한계: history는 스레드 답글을 돌려주지 않아, 최근 메시지에 매달린 스레드만
//      (latest_reply > 커서) 추가로 확인한다. 오래된 스레드의 새 답글은 1)이 필요.
//      커서는 <data>/slack-translate/poll-cursor.json — 처음 켤 때는 "지금"으로
//      잡아 과거를 백필하지 않는다 (user request 2026-07-29).
//
// Later: 🔖(:bookmark:)/📌(:pushpin:) 리액션을 단 메시지는 later:true로 수집돼
// 대시보드의 📌 Later 섹션에 묶인다 (config.json {"laterEmojis":[...]}로 변경).
// 👀와 완전히 같은 리액션 파이프라인 — 이미 수집된 항목이면 플래그만 달고, 새
// 메시지면 그 이모지를 트리거로 수집한다. 리액션 제거 = later 해제(그 이모지로
// 수집된 항목이면 👀와 동일하게 자동 처리완료).
// 주의: Slack의 네이티브 'Later(나중을 위해 저장)' 버튼은 API로 관측 불가 —
// star_added 이벤트는 더 이상 발생하지 않고 stars.list도 새 저장을 반영하지
// 않으며 Later API는 비공개다 (docs.slack.dev/reference/methods/stars.list,
// 2026-07-24 확인). 그래서 리액션이 트리거다. 레거시 star 경로(star_added/
// star_removed + stars.list catch-up, source:'later')는 만약을 위해 남겨둔다 —
// 백필은 저장 60일 이내만, 저장 해제 시 자동 처리완료.
//
// 수집 기준 토글: 대시보드 체크박스 → config.json {"sources":{"eyes":…,
// "mention":…,"team":…,"dm":…,"broadcast":…,"later":…}} — 데몬은 이벤트마다 읽으므로
// 재시작이 필요 없다.
// 해제된 소스는 앞으로 수집되지 않을 뿐, 이미 수집된 항목은 그대로 남는다.
// (구버전 {"mentions": false}는 mention 소스 off로 해석한다.)
//
// Slack→dashboard done sync: removing the trigger emoji in Slack marks the item
// 처리완료 — realtime via reaction_removed, plus a reconcile pass (boot + every
// catch-up) that reactions.get-verifies open items. Done is written through the
// app's POST /api/slack/done with sync:false so the app does NOT mirror the
// removal back to Slack (no loop; done.json stays app-owned).
//
// 재트리거: 이미 수집된 메시지에 트리거 리액션을 다시 달면(👀 제거 → 자동
// 처리완료 → 다시 👀) 새 항목을 만들지 않고 기존 항목의 item.triggeredAt을 그
// 시각으로 갱신하고 처리완료를 해제한다 (retrigger()). 대시보드 정렬 기준이
// triggeredAt(없으면 reactedAt) 내림차순이라 그 항목이 미처리 맨 위로 온다.
// 멘션으로 수집된 항목에 👀를 달면 item.emoji가 그때 붙고, 이후로는 👀 항목과
// 동일하게 처리완료↔리액션 동기화·reconcile 대상이 된다.
//
// Tokens (keychain):
//   cm-slack-app-token   xapp-… (Socket Mode, scope connections:write)
//   cm-slack-user-token  xoxp-… (daemon needs: reactions:read, *:history, *:read.
//     The APP reuses the same token for 처리완료↔👀 mirror-back and thread replies,
//     which additionally need reactions:write + chat:write — without reactions:write
//     the dashboard's 처리완료 cannot remove the 👀 in Slack (missing_scope).
//
// Off switch (cron-page pattern): <data>/slack-translate-disabled — when the
// file exists the daemon idles (WS closed) and re-checks every 60s. KeepAlive
// launchd agent stays loaded; the file is the on/off toggle.
//
// Health heartbeat: half of this feature lives OUTSIDE the app, so the app can't
// see it die. Every 30s (and on every state change) the daemon POSTs its state to
// the app's /api/slack/health — pid, socket(starting/connecting/connected/disabled),
// consecutive connect failures, and the failure split into netError (프록시·방화벽·
// IP 차단) vs authError (토큰). It also posts once before exiting on a fatal or a
// missing token, so a daemon that launchd restarts every 10s still tells the app
// WHY. The app (Sources/Plugins/Slack/SlackHealth.swift) treats 90s of silence as dead and
// kickstarts this agent itself; it only bothers the user for the states restarting
// can't fix. Keep the pre-exit postHealth() calls — without them the app sees only
// silence and retries forever.
//
// Zero npm dependencies — Node 22 native fetch + WebSocket.

import { execFileSync, execFile } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// ---------------------------------------------------------------- config

const DATA_DIR = process.env.CM_DATA_DIR || join(homedir(), '.condition-mate');
const OUT_DIR = join(DATA_DIR, 'slack-translate');
const ITEMS_FILE = join(OUT_DIR, 'items.jsonl');
const DISABLED_FILE = join(DATA_DIR, 'slack-translate-disabled');
const CONFIG_FILE = join(OUT_DIR, 'config.json');
// 알림 폴링 커서 — 이 시각 이후의 메시지만 수집한다 (데몬 소유).
const CURSOR_FILE = join(OUT_DIR, 'poll-cursor.json');

// Reaction names that trigger translation. Override via config.json {"emojis": [...]}.
let EMOJIS = ['eyes'];

// Reaction names that trigger translation AND put the item in the 📌 Later
// bucket (item.later). Override via config.json {"laterEmojis": [...]}.
let LATER_EMOJIS = ['bookmark', 'pushpin'];

// ---- 트리거가 아닌 리액션 = "누군가 이미 처리했다" 신호 -------------------
// 트리거 집합 = EMOJIS ∪ LATER_EMOJIS. config.json을 바꾸면 자동으로 따라간다
// (두 배열은 부팅 시 config에서 덮어써진다). 이 집합에 없는 이모지가 메시지에
// 하나라도 붙어 있으면, 누가 달았는지와 무관하게 그 항목은 해결된 것으로 보고
// 자동 처리완료한다 — 이미 끝난 스레드가 미처리에 남아 커뮤니케이션 비용이 되는
// 것을 막는다.
function isTriggerEmoji(name) {
  const n = baseEmoji(name);
  return EMOJIS.includes(n) || LATER_EMOJIS.includes(n);
}

// 슬랙은 스킨톤·별칭을 "+1::skin-tone-3"처럼 붙여 보낸다 — 첫 "::" 앞이 이름.
function baseEmoji(name) {
  return String(name || '').split('::')[0];
}

// 메시지 리액션 목록(reactions.get·conversations.history의 msg.reactions)에서
// 트리거가 아닌 첫 리액션. 없으면 null.
function resolvingReaction(reactions) {
  for (const r of reactions || []) {
    if (!isTriggerEmoji(r.name)) return { name: baseEmoji(r.name), by: (r.users || [])[0] };
  }
  return null;
}

// 항목에 기록해 둔 리액션 이름 배열(다중집합 — 같은 이모지를 여러 사람이 달 수
// 있다)에서 트리거가 아닌 첫 이름. 옛 항목엔 reactions 필드가 없다(= 없음).
function firstNonTrigger(names) {
  for (const n of names || []) if (!isTriggerEmoji(n)) return baseEmoji(n);
  return null;
}

// 수집 기준 체크박스 상태 — 대시보드가 config.json {"sources":{…}}에 쓰고, 여기서
// 이벤트마다 읽는다 (파일이 작아 비용 무시 가능, 재시작 불필요). 기본 전부 on.
// kind: 'eyes'(👀 리액션) | 'mention'(나를 직접 멘션) | 'team'(내 유저그룹 멘션)
//     | 'dm'(DM·그룹DM 새 메시지) | 'broadcast'(@here/@channel) | 'later'(저장)
function sourceOn(kind) {
  try {
    const cfg = JSON.parse(readFileSync(CONFIG_FILE, 'utf8'));
    if (kind === 'mention' && cfg.mentions === false) return false; // 구버전 플래그
    if (cfg.sources && cfg.sources[kind] === false) return false;
  } catch {}
  return true;
}

// PATH for spawned tools (launchd gives a bare PATH; claude lives in ~/.local/bin etc.)
const TOOL_PATH = [
  join(homedir(), '.local', 'bin'),
  '/opt/homebrew/bin',
  '/usr/local/bin',
  process.env.PATH || '/usr/bin:/bin',
].join(':');

const log = (...a) => console.log(new Date().toISOString(), ...a);

function keychain(service) {
  try {
    return execFileSync('security', ['find-generic-password', '-w', '-s', service], {
      encoding: 'utf8',
    }).trim();
  } catch {
    return null;
  }
}

// Best-effort liveness report to the app's 워커 상태 row (cron-page pattern:
// resolve the dynamic dashboard port from <data>/dashboard.port, POST
// /api/worker/ping). Silently no-ops when the app isn't running.
async function ping(status, why, effect) {
  try {
    const port = readFileSync(join(DATA_DIR, 'dashboard.port'), 'utf8').replace(/\D/g, '');
    if (!port) return;
    await fetch(`http://127.0.0.1:${port}/api/worker/ping`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: 'slack-eyes', status, why, effect }),
      signal: AbortSignal.timeout(3000),
    });
  } catch {}
}

// ---------------------------------------------------------------- health
// 사용자는 앱 화면만 본다 — 앱 밖에서 이 데몬이 살아 있는지, 슬랙 API에 닿는지,
// 토큰이 유효한지는 알 방법이 없다. 그래서 30초마다(+상태가 바뀔 때마다) 앱에
// 보고한다. 앱(SlackHealth.swift)은 이 보고가 90초 끊기면 데몬이 죽은 것으로 보고
// launchctl kickstart로 스스로 되살리며, 되살려도 안 되거나 원인이 네트워크 차단·
// 토큰 만료면 그때 사용자에게 안내한다.
const health = {
  pid: process.pid,
  startedAt: Math.floor(Date.now() / 1000),
  socket: 'starting', // starting | connecting | connected | disabled
  failures: 0, // 연속 연결 실패 횟수 (2회 이상 + netError → 앱이 '차단'으로 안내)
  netError: '', // slack.com에 닿지 못한 마지막 이유 (네트워크·VPN·방화벽)
  authError: '', // 슬랙이 토큰을 거부한 마지막 이유
  node: process.execPath, // 앱이 plist를 복구할 때 쓸 실제 경로 (추측 금지)
  script: process.argv[1] || '',
  // 알림(멘션·DM·@here) 수집 경로 상태 — 페이지가 "실시간 / 폴링만"을 구분해
  // 보여주고, 실시간이 꺼져 있으면 Event Subscriptions 설정을 안내한다.
  realtimeAt: 0, // 마지막으로 message 이벤트를 받은 시각 (0 = 한 번도 못 받음 = 구독 없음)
  pollAt: 0, // 마지막 폴링 완료 시각
  pollConvs: 0, // 훑은 대화 수
  pollFound: 0, // 마지막 폴링이 새로 수집한 건수
  pollLimited: false, // 슬랙 rate limit에 걸려 중간에 끊겼는지
  pollError: '', // 대화 목록 자체가 실패한 사유 (보통 토큰 스코프 부족)
};

async function postHealth() {
  try {
    const port = readFileSync(join(DATA_DIR, 'dashboard.port'), 'utf8').replace(/\D/g, '');
    if (!port) return;
    await fetch(`http://127.0.0.1:${port}/api/slack/health`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(health),
      signal: AbortSignal.timeout(3000),
    });
  } catch {}
}

// 값이 실제로 바뀐 경우에만 즉시 보고한다 (30초 주기 보고와 별개로 전이는 바로).
function setHealth(patch) {
  let changed = false;
  for (const [k, v] of Object.entries(patch)) {
    if (health[k] !== v) {
      health[k] = v;
      changed = true;
    }
  }
  if (changed) postHealth();
}

// 실패를 앱이 사용자에게 설명할 수 있는 두 갈래로 나눈다: 슬랙에 아예 닿지 못함
// (회사망·VPN·방화벽·프록시 차단) vs 슬랙이 토큰을 거부함(재발급 필요).
function classifyFailure(e) {
  const m = String((e && e.message) || e);
  if (/invalid_auth|not_authed|token_revoked|token_expired|account_inactive|missing_scope|invalid_token/.test(m)) {
    health.authError = m.replace(/^slack \S+: /, '');
  } else {
    health.netError = m;
  }
}

// ---------------------------------------------------------------- slack api

let USER_TOKEN = null;
let APP_TOKEN = null;

async function slack(method, params = {}, token = USER_TOKEN) {
  const body = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) body.set(k, String(v));
  const res = await fetch(`https://slack.com/api/${method}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
  });
  // 네트워크가 슬랙을 막으면 200 JSON이 아니라 프록시 차단 페이지(HTML)나 4xx가
  // 온다 — res.json()이 던지는 SyntaxError로 두면 원인을 알 수 없으니 번역한다.
  let json;
  try {
    json = await res.json();
  } catch {
    throw new Error(`HTTP ${res.status} — 슬랙 대신 JSON이 아닌 응답 (프록시·방화벽 차단으로 보임)`);
  }
  if (!json.ok) throw new Error(`slack ${method}: ${json.error}`);
  return json;
}

// caches
const channelNames = new Map(); // id -> #name
const userNames = new Map(); // id -> display name
const usergroupNames = new Map(); // id -> @handle
let usergroupsLoaded = false;

async function usergroupName(id) {
  if (!usergroupsLoaded) {
    usergroupsLoaded = true; // one list call covers every group; don't retry per-id
    try {
      const info = await slack('usergroups.list');
      for (const g of info.usergroups || [])
        usergroupNames.set(g.id, `@${g.handle || g.name || g.id}`);
    } catch (e) {
      log('usergroups.list fail', e.message);
    }
  }
  return usergroupNames.get(id) || `@${id}`;
}

async function channelName(id) {
  if (channelNames.has(id)) return channelNames.get(id);
  let name = id;
  try {
    const info = await slack('conversations.info', { channel: id });
    const c = info.channel;
    // DM은 채널명이 없다 — 상대가 누구인지가 유일하게 쓸모 있는 라벨이다.
    // (그룹 DM의 mpdm-… 원문은 읽기 어려워 사람 이름만 남긴다.)
    if (c.is_im) name = `DM · ${await userName(c.user)}`;
    else if (c.is_mpim) name = `그룹 DM · ${(c.name || '').replace(/^mpdm-|-\d+$/g, '').replaceAll('--', ', ')}`;
    else name = `#${c.name || id}`;
  } catch (e) {
    log('channelName fail', id, e.message);
  }
  channelNames.set(id, name);
  return name;
}

async function userName(id) {
  if (!id) return '';
  if (userNames.has(id)) return userNames.get(id);
  let name = id;
  try {
    const info = await slack('users.info', { user: id });
    name = info.user.profile.display_name || info.user.real_name || info.user.name || id;
  } catch (e) {
    log('userName fail', id, e.message);
  }
  userNames.set(id, name);
  return name;
}

// Slack markup → readable text: <@U…> mentions, <#C…|name> channels,
// <url|label> links, &amp;/&lt;/&gt; entities.
async function cleanText(raw) {
  let t = raw || '';
  const mentions = [...t.matchAll(/<@([A-Z0-9]+)>/g)].map((m) => m[1]);
  for (const id of new Set(mentions)) t = t.replaceAll(`<@${id}>`, `@${await userName(id)}`);
  t = t.replace(/<!subteam\^[A-Z0-9]+\|@?([^>]+)>/g, '@$1');
  const groups = [...t.matchAll(/<!subteam\^([A-Z0-9]+)>/g)].map((m) => m[1]);
  for (const id of new Set(groups)) t = t.replaceAll(`<!subteam^${id}>`, await usergroupName(id));
  t = t.replace(/<!(here|channel|everyone)(\|[^>]*)?>/g, '@$1');
  t = t.replace(/<#[A-Z0-9]+\|([^>]+)>/g, '#$1');
  const chans = [...t.matchAll(/<#([A-Z0-9]+)>/g)].map((m) => m[1]);
  for (const id of new Set(chans)) t = t.replaceAll(`<#${id}>`, await channelName(id));
  t = t.replace(/<([^|>]+)\|([^>]+)>/g, '$2 ($1)');
  t = t.replace(/<([^>]+)>/g, '$1');
  return t.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>');
}

// ---------------------------------------------------------------- translation

// 번역 목표 언어 — 대시보드 셀렉트가 config.json {"lang": …}에 쓰고, 여기서
// 호출마다 읽는다 (모델 선택과 동일 패턴 — 데몬 재시작 불필요). 기본 한국어.
const LANGS = {
  ko: '한국어',
  en: '영어(English)',
  vi: '베트남어(Tiếng Việt)',
  ja: '일본어(日本語)',
  zh: '중국어(简体中文)',
};

function targetLang() {
  try {
    const l = JSON.parse(readFileSync(CONFIG_FILE, 'utf8')).lang;
    if (LANGS[l]) return l;
  } catch {}
  return 'ko';
}

function translatePrompt(text, ctx, lang) {
  const name = LANGS[lang] || LANGS.ko;
  return [
    `다음 슬랙 메시지를 세 단계로 처리하라. 목표 언어: ${name}.`,
    '',
    '[1단계 — 번역]',
    '- 먼저 메시지의 "서술 문장"이 어떤 언어인지 판정하라. 판정 대상에서 다음은',
    '  반드시 제외한다: 사람 이름과 괄호 안 표기, @멘션, 채널명, 이모지 코드',
    '  (:saluting_face: 등), URL, 코드 블록, 제품명·회사명·티커 같은 고유명사.',
    '  이런 요소에 다른 언어 글자가 섞여 있어도 언어 판정에 반영하지 마라.',
    '- 판정은 서술 문장(주어와 동사가 있는 실제 문장)만 보고 한다. 서술 문장이',
    '  둘 이상이면 그 문장들의 다수 언어를 메시지 언어로 본다.',
    `- 판정 결과가 ${name}가 아니면 메시지 전체를 자연스러운 ${name}로 번역해 출력.`,
    `- 판정 결과가 ${name}일 때만 번역하지 말고 원문을 그대로 출력한다. 이름이나`,
    `  멘션에 ${name} 글자가 섞였다는 이유만으로는 절대 이 경우에 해당하지 않는다.`,
    '- 판정이 애매하면 번역하는 쪽을 택하라.',
    '- 코드 블록, URL, 고유명사(제품명·티커 등)는 번역하지 말고 유지.',
    '- 번역 결과에 언어 판정 과정이나 근거를 적지 마라. 결과 문장만 출력한다.',
    '',
    '[2단계 — 의미 분석]',
    '- 줄바꿈 후 정확히 ===MEANING=== 한 줄을 출력.',
    '- <context>(같은 스레드/채널의 최근 대화)를 참고해, 이 메시지가 무슨 일에',
    `  대한 이야기이고 실제로 무엇을 말하려는/요구하는 것인지 ${name}로 1~3문장 설명.`,
    '- 표면 번역만으로 알기 어려운 함의·톤(급함, 불만, 단순 공유 등)이 있으면 짚어라.',
    '- 컨텍스트가 부족해 의미를 확정할 수 없으면 첫 줄을 "컨텍스트 부족:"으로',
    '  시작하고, 무엇을 확인해야 의미가 확정되는지(어떤 스레드·문서·사람) 적어라.',
    '',
    '[3단계 — 의사결정 선택지]',
    '- 줄바꿈 후 정확히 ===DECISION=== 한 줄을 출력.',
    `- 그 아래에 수신자(나)가 취할 수 있는 대응 선택지를 ${name}로 정확히 2개 출력:`,
    '1) <가장 합리적인 대응> — 추천 이유: <한 문장>',
    '2) <현실적인 대안>',
    '- 각 선택지는 한두 줄로 간결하게. 단순 공지/FYI라 결정할 게 없으면',
    '  1)은 "확인만 하고 처리완료"로 하고 이유를 붙여라.',
    '',
    '위 형식 외의 설명·머리말·마크다운 헤더는 절대 붙이지 마라.',
    '',
    '<context>',
    ctx || '(수집된 컨텍스트 없음)',
    '</context>',
    '',
    '<message>',
    text,
    '</message>',
  ].join('\n');
}

// Split one LLM response into {ko, meaning, decision} on the ===MEANING=== /
// ===DECISION=== markers. Markers missing (old model output, truncation) →
// whole text is the translation.
function splitSections(out) {
  if (!out) return { ko: null, meaning: '', decision: '' };
  let rest = out;
  let meaning = '';
  let decision = '';
  const di = rest.indexOf('===DECISION===');
  if (di >= 0) {
    decision = rest.slice(di + '===DECISION==='.length).trim();
    rest = rest.slice(0, di);
  }
  const mi = rest.indexOf('===MEANING===');
  if (mi >= 0) {
    meaning = rest.slice(mi + '===MEANING==='.length).trim();
    rest = rest.slice(0, mi);
  }
  return { ko: rest.trim(), meaning, decision };
}

// 2차 의미 분석용 컨텍스트 수집 — 대상 메시지가 스레드 안이면 그 스레드의
// 답글들을, 아니면 채널의 직전 메시지들을 모아 "작성자: 내용" 줄로 만든다.
// 실패해도 파이프라인은 계속 (컨텍스트 없이 번역·분석).
async function gatherContext(channel, ts, threadTs) {
  const lines = [];
  try {
    let msgs;
    if (threadTs && threadTs !== ts) {
      const res = await slack('conversations.replies', { channel, ts: threadTs, limit: 30 });
      msgs = (res.messages || []).filter((m) => m.ts !== ts).slice(-12);
    } else {
      const res = await slack('conversations.history', { channel, latest: ts, limit: 8 });
      msgs = (res.messages || []).filter((m) => m.ts !== ts).reverse();
    }
    for (const m of msgs) {
      if (typeof m.text !== 'string' || !m.text.trim()) continue;
      const line = `${await userName(m.user || m.bot_id)}: ${await cleanText(m.text)}`;
      lines.push(line.length > 300 ? line.slice(0, 300) + '…' : line);
    }
  } catch (e) {
    log('context fetch fail:', e.message);
  }
  let out = lines.join('\n');
  if (out.length > 2500) out = out.slice(-2500);
  return out;
}

// Model selection — config.json {"model": "auto"|"gemini-flash-lite"|"gemini-flash"|"haiku"},
// written by the dashboard (/api/slack/config), read here PER CALL so switching
// needs no daemon restart. "auto" = fastest available: Gemini Flash-Lite (~1s via
// direct REST, keychain cm-gemini-api-key) when the key exists, else Claude CLI.
// `-latest` aliases: fixed-version names (gemini-2.5-flash-lite) can 404 as
// Google rotates models per key; the alias always resolves (verified 2026-07-23).
const GEMINI_MODELS = {
  'gemini-flash-lite': 'gemini-flash-lite-latest',
  'gemini-flash': 'gemini-flash-latest',
};
let geminiKey; // undefined = not looked up yet, null = missing
let anthropicKey; // keychain cm-anthropic-api-key — direct API, no CLI startup cost

function currentModel() {
  try {
    const m = JSON.parse(readFileSync(CONFIG_FILE, 'utf8')).model;
    if (m === 'auto' || m === 'haiku' || m === 'haiku-api' || GEMINI_MODELS[m]) return m;
  } catch {}
  // Default = 1초 번역 (Gemini Flash-Lite, 무료 키) — user request 2026-07-23.
  // Key missing → translate() falls back to CLI Haiku silently.
  return 'gemini-flash-lite';
}

async function translateGemini(apiModel, prompt) {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${apiModel}:generateContent`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': geminiKey },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0.2 },
      }),
      signal: AbortSignal.timeout(20_000),
    },
  );
  if (!res.ok) throw new Error(`gemini ${apiModel}: HTTP ${res.status}`);
  const json = await res.json();
  const out = (json.candidates?.[0]?.content?.parts || []).map((p) => p.text || '').join('').trim();
  if (!out) throw new Error(`gemini ${apiModel}: empty response`);
  return out;
}

// Anthropic Messages API direct (billed separately from the Claude subscription
// — usage-based via Console API key). Same Haiku model as the CLI path but no
// process-startup cost: ~1-2s instead of 5-15s.
async function translateAnthropicAPI(prompt) {
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': anthropicKey,
      'anthropic-version': '2023-06-01',
    },
    body: JSON.stringify({
      model: 'claude-haiku-4-5',
      max_tokens: 4096,
      messages: [{ role: 'user', content: prompt }],
    }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`anthropic api: HTTP ${res.status}`);
  const json = await res.json();
  const out = (json.content || [])
    .filter((b) => b.type === 'text')
    .map((b) => b.text)
    .join('')
    .trim();
  if (!out) throw new Error('anthropic api: empty response');
  return out;
}

function translateClaude(prompt) {
  return new Promise((resolve) => {
    execFile(
      'claude',
      ['--model', 'claude-haiku-4-5-20251001', '-p', prompt],
      {
        encoding: 'utf8',
        timeout: 120_000,
        cwd: OUT_DIR,
        env: { ...process.env, PATH: TOOL_PATH, CM_SUPPRESS_SESSION_GOAL: '1' },
      },
      (err, stdout) => {
        if (err) {
          log('translate fail (claude):', err.message.split('\n')[0]);
          resolve(null);
        } else resolve(stdout.trim());
      },
    );
  });
}

// Returns {ko, meaning, decision, model, lang} — ko null when every route
// failed. A selected Gemini model that errors (bad key, quota, network) silently
// falls back to Claude so items never stall on a misconfigured model
// (no-user-facing-failure). ctx = gatherContext() 결과 (의미 분석 재료).
async function translate(text, ctx = '') {
  const t0 = Date.now();
  const lang = targetLang();
  const prompt = translatePrompt(text, ctx, lang);
  const timed = (r) => ({ ...r, lang, ms: Date.now() - t0 }); // 번역 소요 (디버그 표시용)
  if (geminiKey === undefined) geminiKey = keychain('cm-gemini-api-key');
  if (anthropicKey === undefined) anthropicKey = keychain('cm-anthropic-api-key');
  let choice = currentModel();
  if (choice === 'auto') {
    choice = geminiKey ? 'gemini-flash-lite' : anthropicKey ? 'haiku-api' : 'haiku';
  }
  if (GEMINI_MODELS[choice] && geminiKey) {
    try {
      return timed({ ...splitSections(await translateGemini(GEMINI_MODELS[choice], prompt)), model: choice });
    } catch (e) {
      log(`translate fail (${choice}): ${e.message} — falling back to claude CLI`);
    }
  } else if (choice === 'haiku-api' && anthropicKey) {
    try {
      return timed({ ...splitSections(await translateAnthropicAPI(prompt)), model: 'haiku-api' });
    } catch (e) {
      log(`translate fail (haiku-api): ${e.message} — falling back to claude CLI`);
    }
  } else if (choice !== 'haiku') {
    log(`model ${choice} selected but its keychain key is missing — using claude CLI`);
  }
  return timed({ ...splitSections(await translateClaude(prompt)), model: 'haiku' });
}

// ---------------------------------------------------------------- state

const seen = new Set(); // "channel:ts" ids already recorded
const pendingAtBoot = []; // items saved without a translation (daemon died mid-run)

function loadState() {
  if (!existsSync(ITEMS_FILE)) return;
  for (const line of readFileSync(ITEMS_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const o = JSON.parse(line);
      seen.add(o.id);
      if (o.pending) pendingAtBoot.push(o);
    } catch {}
  }
  log(`state: ${seen.size} items already recorded, ${pendingAtBoot.length} pending`);
}

// Patch one item line in place. The daemon is the ONLY writer of items.jsonl
// (the app owns done.json), so read-modify-rename is race-free on our side.
function rewriteItem(id, patch) {
  const lines = readFileSync(ITEMS_FILE, 'utf8').split('\n');
  const out = lines.map((line) => {
    if (!line.trim()) return line;
    try {
      const o = JSON.parse(line);
      if (o.id !== id) return line;
      const merged = { ...o, ...patch };
      for (const k of Object.keys(merged)) if (merged[k] === undefined) delete merged[k];
      return JSON.stringify(merged);
    } catch {
      return line;
    }
  });
  const tmp = ITEMS_FILE + '.tmp';
  writeFileSync(tmp, out.join('\n'));
  renameSync(tmp, ITEMS_FILE);
}

// ---------------------------------------------------------------- pipeline

// source: undefined = 👀 리액션 트리거, 'mention' = 나를 직접 멘션, 'team' = 내
// 유저그룹(팀) 멘션, 'later' = Slack 'Save for later' 저장. 멘션·later류는
// 이모지 없음 — 처리완료의 슬랙 리액션 동기화·reconcile 대상에서 제외된다.
async function processMessage(channel, ts, reactedAt, emoji, source) {
  const id = `${channel}:${ts}`;
  if (seen.has(id)) return;
  seen.add(id); // reserve immediately — concurrent event + catch-up dedupe

  try {
    const hist = await slack('conversations.history', {
      channel,
      latest: ts,
      inclusive: 'true',
      limit: 1,
    });
    let msg = hist.messages?.[0];
    if (!msg || msg.ts !== ts) {
      // Thread replies are invisible to conversations.history — fall back to
      // conversations.replies (its ts param accepts any message in the thread).
      const reps = await slack('conversations.replies', { channel, ts, limit: 1 }).catch(() => null);
      msg = reps?.messages?.find((m) => m.ts === ts);
    }
    if (!msg) {
      log(`skip ${id}: message not found (deleted?)`);
      return;
    }
    const textEn = await cleanText(msg.text);
    if (!textEn.trim()) {
      log(`skip ${id}: empty text (file/attachment only?)`);
      return;
    }
    // Kick context collection + the (slow) translation FIRST so they overlap
    // the metadata fetches. 컨텍스트(스레드/채널 최근 대화)는 2차 의미 분석 재료.
    const koP = gatherContext(channel, ts, msg.thread_ts).then((ctx) => translate(textEn, ctx));
    // 수집 시점의 리액션 — 트리거가 아닌 게 이미 붙어 있으면 누군가 처리한
    // 메시지다. 미처리로 띄우지 않고 처음부터 자동 처리완료 상태로 만든다.
    const reactionNames = [];
    for (const r of msg.reactions || []) {
      for (let i = 0; i < Math.max(1, (r.users || []).length); i++) reactionNames.push(baseEmoji(r.name));
    }
    // 단, 내가 직접 트리거 이모지를 달아 수집된 항목(source 없음)은 예외 — 남이
    // 단 다른 리액션이 이미 있어도 자동 처리완료하지 않는다. 내가 방금 👀를 단 건
    // "내가 볼 것"이라는 명시적 의사표시라, 남의 🙌 때문에 미처리에서 사라지면
    // 달아도 목록에 안 나타나는 걸로 보인다 (실제 혼동, 2026-08-16).
    const resolved = source ? resolvingReaction(msg.reactions) : null;
    const [chName, author, permalink] = await Promise.all([
      channelName(channel),
      userName(msg.user || msg.bot_id),
      slack('chat.getPermalink', { channel, message_ts: ts })
        .then((r) => r.permalink)
        .catch(() => ''),
    ]);
    // Phase 1 — append immediately so the dashboard shows the original within ~2s
    // ("번역 중…" badge); phase 2 patches the same line when the translation lands.
    const item = {
      id,
      channel,
      channelName: chName,
      ts,
      // Thread root for replies from the dashboard (chat.postMessage thread_ts
      // must be the PARENT ts when the reacted message is itself a thread reply).
      threadTs: msg.thread_ts || undefined,
      // Which trigger emoji fired — 처리완료 removes exactly this reaction.
      // 멘션류(source 있음) 항목은 이모지 트리거가 없으므로 emoji를 아예 쓰지 않는다.
      emoji: source ? undefined : emoji || EMOJIS[0],
      source: source || undefined,
      // 📌 Later 버킷 — 🔖/📌 리액션 트리거이거나 (레거시) star 저장으로 수집된 항목.
      later: source === 'later' || (emoji && LATER_EMOJIS.includes(emoji)) ? true : undefined,
      author,
      // Slack user id of the author — dashboard replies prepend <@id> so the
      // author gets notified. Bot messages have no user id (mention skipped).
      authorId: msg.user || undefined,
      textEn,
      textKo: '',
      pending: true,
      permalink,
      reactedAt: reactedAt || Math.floor(Date.now() / 1000),
      // 이 메시지에 현재 달려 있는 리액션 이름들 (다중집합). reaction_added/
      // removed로 갱신되며, 트리거가 아닌 게 남아 있는지 판별하는 근거다.
      reactions: reactionNames.length ? reactionNames : undefined,
      // 이모지로 자동 해결됨 — 사용자가 직접 누른 처리완료(done.json만 바뀜)와
      // 구분하기 위한 별도 필드. 리액션이 사라지면 이 항목만 미처리로 되돌린다.
      autoDone: resolved ? true : undefined,
      autoEmoji: resolved ? resolved.name : undefined,
      autoBy: resolved ? resolved.by : undefined,
    }; // done-state lives in app-owned done.json, not here
    appendFileSync(ITEMS_FILE, JSON.stringify(item) + '\n');
    log(`listed ${id} from ${chName} by ${author}: ${textEn.slice(0, 60)}…`);
    if (resolved) {
      log(`auto-done ${id}: 수집 시점에 이미 :${resolved.name}: 리액션이 달려 있음`);
      markDone(id);
    }
    const tr = await koP;
    rewriteItem(id, {
      textKo: tr.ko || '',
      meaning: tr.meaning || undefined,
      decision: tr.decision || undefined,
      lang: tr.ko ? tr.lang : undefined,
      model: tr.ko ? tr.model : undefined,
      trMs: tr.ko ? tr.ms : undefined,
      pending: undefined,
      error: tr.ko ? undefined : 'translate-failed',
      translatedAt: Math.floor(Date.now() / 1000),
    });
    log(`saved ${id} [${tr.model} ${(tr.ms / 1000).toFixed(1)}s]${tr.ko ? '' : ' (translation FAILED, saved original)'}`);
    ping('ok', source === 'mention' ? '@멘션 번역' : source === 'team' ? '@팀멘션 번역'
      : source === 'later' ? '📌 Later 번역' : '👀 번역',
      `${chName} ${author} 메시지 번역 저장`);
  } catch (e) {
    seen.delete(id); // allow retry on next catch-up
    log(`process ${id} error:`, e.message);
  }
}

let MY_USER = null;

// 내가 속한 유저그룹(팀) ID 집합 — <!subteam^ID> 멘션이 "내 팀 멘션"인지 판별.
// 부팅 시 + 30분 catch-up마다 갱신 (팀 가입/탈퇴 반영). usergroups:read 필요 —
// 스코프가 없으면 빈 집합으로 남아 팀 멘션 수집만 조용히 비활성화된다.
let myGroups = new Set();

async function loadMyGroups() {
  try {
    const res = await slack('usergroups.list', { include_users: 'true' });
    myGroups = new Set(
      (res.usergroups || []).filter((g) => (g.users || []).includes(MY_USER)).map((g) => g.id),
    );
    log(`my usergroups: ${myGroups.size ? [...myGroups].join(', ') : '(none)'}`);
  } catch (e) {
    log('usergroups.list fail (팀 멘션 감지 비활성):', e.message);
  }
}

// ---------------------------------------------------------------- 알림 판별

// 이 메시지가 나에게 오는 알림인가, 온다면 어떤 종류인가.
// 우선순위: 직접 멘션 > 팀 멘션 > DM > @here/@channel — 하나의 메시지는 가장
// 강한 종류 하나로만 수집된다 (DM 안의 직접 멘션은 'mention'). 반환 null = 알림 아님.
// 실시간 경로와 폴링 경로가 같은 판별을 쓰도록 한 곳에 둔다.
function mentionKind(text, isDM) {
  if (typeof text !== 'string') return null;
  if (MY_USER && text.includes(`<@${MY_USER}>`)) return 'mention';
  if ([...text.matchAll(/<!subteam\^([A-Z0-9]+)/g)].some((m) => myGroups.has(m[1]))) return 'team';
  if (isDM) return 'dm';
  if (/<!(here|channel|everyone)(\||>)/.test(text)) return 'broadcast';
  return null;
}

// 본문이 있는 실메시지인가 — 편집/삭제/입퇴장 같은 subtype은 알림이 아니다.
// thread_broadcast/file_share는 본문이 있는 실메시지라 포함한다 (실시간 경로와 동일).
function isRealMessage(m) {
  return !m.subtype || m.subtype === 'thread_broadcast' || m.subtype === 'file_share';
}

// ---------------------------------------------------------------- 알림 폴링

// Socket Mode의 message 이벤트 구독이 없어도 멘션·DM·@here가 페이지에 뜨도록 하는
// 두 번째 경로 (헤더 주석 참고). 내가 속한 대화를 훑어 커서 이후의 새 메시지를
// 직접 검사한다. 실시간 경로가 살아 있으면 seen 중복 방지로 조용히 아무것도 안 한다.
const POLL_MIN_MS = 90_000; // 대화가 적어도 이보다 자주 돌지는 않는다
const POLL_PER_CONV_MS = 3000; // 대화 1개당 3초 → 슬랙 rate limit(분당 ~20) 아래로 유지
const CURSOR_MAX_LAG = 6 * 3600; // 오래 꺼져 있었어도 최근 6시간까지만 소급
const CONV_CACHE_MS = 15 * 60_000;
const THREADS_PER_CONV = 3; // 대화당 확인할 활성 스레드 상한

let convCache = { at: 0, list: [] };
let pollBackoff = 1; // rate limit에 걸리면 다음 주기를 2배씩 늘린다 (최대 30분)
let pollTimer = null;

function loadCursor() {
  try {
    const v = JSON.parse(readFileSync(CURSOR_FILE, 'utf8')).since;
    if (Number.isFinite(v) && v > 0) return v;
  } catch {}
  return null;
}

function saveCursor(since) {
  try {
    writeFileSync(CURSOR_FILE, JSON.stringify({ since }));
  } catch (e) {
    log('cursor save fail:', e.message);
  }
}

// 내가 속한 대화 목록 (채널·비공개채널·DM·그룹DM). 15분 캐시 — 대화 가입/탈퇴는
// 이 주기로 반영되면 충분하고, 폴링마다 목록을 다시 받으면 호출만 낭비된다.
async function myConversations() {
  if (convCache.list.length && Date.now() - convCache.at < CONV_CACHE_MS) return convCache.list;
  const out = [];
  let cursor;
  for (let page = 0; page < 10; page++) {
    const res = await slack('users.conversations', {
      types: 'public_channel,private_channel,im,mpim',
      exclude_archived: 'true',
      limit: 200,
      cursor,
    });
    for (const c of res.channels || []) out.push({ id: c.id, dm: !!(c.is_im || c.is_mpim) });
    cursor = res.response_metadata?.next_cursor;
    if (!cursor) break;
  }
  convCache = { at: Date.now(), list: out };
  return out;
}

// 한 메시지를 검사해 알림이면 수집한다. 반환 true = 새로 수집함.
async function considerMessage(conv, m, since, kinds) {
  if (!m.ts || Number(m.ts) <= since) return false;
  if (!isRealMessage(m)) return false;
  if (!m.user || m.user === MY_USER) return false; // 내가 쓴 것·봇 메시지는 알림이 아니다
  if (seen.has(`${conv.id}:${m.ts}`)) return false;
  const kind = mentionKind(m.text, conv.dm);
  if (!kind || !kinds.includes(kind)) return false;
  log(`poll: ${kind} in ${conv.id}`);
  await processMessage(conv.id, m.ts, Math.floor(Number(m.ts)), null, kind);
  return true;
}

// 한 번의 폴링 — 커서 이후 모든 대화의 새 메시지 + 최근 활성 스레드의 새 답글.
// 실패(권한 없는 대화 등)는 그 대화만 건너뛴다. rate limit이면 즉시 중단하고
// 커서를 진전시키지 않는다 — 다음 주기에 같은 구간을 다시 훑는다.
async function activityPoll() {
  if (existsSync(DISABLED_FILE)) return; // 수집 OFF 토글 — 소켓과 같은 기준
  const kinds = ['mention', 'team', 'dm', 'broadcast'].filter(sourceOn);
  if (!kinds.length) return;
  const now = Math.floor(Date.now() / 1000);
  let since = loadCursor();
  if (since == null) {
    // 최초 실행 — 과거는 백필하지 않는다. 지금부터가 시작점.
    saveCursor(now);
    log(`알림 폴링 시작 — 커서를 지금(${now})으로 설정, 과거 백필 없음`);
    return;
  }
  if (now - since > CURSOR_MAX_LAG) {
    log(`커서가 ${Math.round((now - since) / 3600)}시간 뒤처짐 — 최근 6시간으로 잘라 재개`);
    since = now - CURSOR_MAX_LAG;
  }
  // 대화 목록부터 실패하면(토큰에 channels:read·im:read 등이 없을 때) 폴링 자체가
  // 성립하지 않는다 — 조용히 죽지 않도록 사유를 health에 남기고 다음 주기에 재시도.
  let convs;
  try {
    convs = await myConversations();
  } catch (e) {
    setHealth({ pollError: e.message, pollAt: now });
    log('폴링: 대화 목록 실패 —', e.message);
    return;
  }
  let found = 0;
  let scanned = 0;
  let limited = false;
  for (const conv of convs) {
    try {
      const res = await slack('conversations.history', {
        channel: conv.id,
        oldest: String(since),
        limit: 30,
      });
      scanned++;
      const msgs = res.messages || [];
      for (const m of msgs) if (await considerMessage(conv, m, since, kinds)) found++;
      // history는 스레드 답글을 돌려주지 않는다 — 커서 이후에 답글이 달린 스레드만
      // 골라 replies로 확인한다 (대화당 상한 THREADS_PER_CONV).
      const hot = msgs
        .filter((m) => m.thread_ts && Number(m.latest_reply || 0) > since)
        .slice(0, THREADS_PER_CONV);
      for (const root of hot) {
        const rep = await slack('conversations.replies', {
          channel: conv.id,
          ts: root.thread_ts,
          oldest: String(since),
          limit: 30,
        });
        for (const m of rep.messages || []) {
          if (await considerMessage(conv, m, since, kinds)) found++;
        }
      }
    } catch (e) {
      // 슬랙은 보통 {ok:false,error:'ratelimited'}를 주지만 본문 없는 429도 온다.
      if (/ratelimited|rate_limited|too_many|HTTP 429/.test(e.message)) {
        limited = true;
        log(`폴링 rate limit — ${scanned}/${convs.length} 대화까지만 훑고 중단`);
        break;
      }
      // not_in_channel·missing_scope 등은 그 대화만 건너뛴다 (조용히).
    }
  }
  if (limited) {
    pollBackoff = Math.min(pollBackoff * 2, 20);
  } else {
    pollBackoff = 1;
    saveCursor(now); // 끝까지 훑었을 때만 커서를 전진시킨다
  }
  setHealth({ pollAt: now, pollConvs: scanned, pollFound: found, pollLimited: limited, pollError: '' });
  if (found) {
    log(`폴링: ${scanned}개 대화에서 ${found}건 새로 수집`);
    ping('ok', '알림 폴링', `${found}건 수집 (멘션·DM·전체호출)`);
  }
}

// 다음 폴링 예약 — 주기는 대화 수에 비례해 늘려 슬랙 rate limit 아래로 유지한다
// (대화 40개면 약 2분, 200개면 10분). rate limit에 걸린 뒤에는 백오프까지 곱한다.
function schedulePoll() {
  clearTimeout(pollTimer);
  const n = convCache.list.length || 30;
  let delay = Math.max(POLL_MIN_MS, n * POLL_PER_CONV_MS) * pollBackoff;
  // 실시간 경로가 살아 있으면(최근 15분 내 message 이벤트) 폴링은 안전망일 뿐이다
  // — 주기를 4배로 늘려 슬랙 API 호출을 아낀다. 구독이 꺼지면 자동으로 되돌아온다.
  const nowSec = Math.floor(Date.now() / 1000);
  if (health.realtimeAt && nowSec - health.realtimeAt < 900) delay *= 4;
  pollTimer = setTimeout(() => {
    activityPoll()
      .catch((e) => log('알림 폴링 오류:', e.message))
      .finally(schedulePoll);
  }, delay);
}

async function catchUp() {
  if (!sourceOn('eyes') && !sourceOn('later')) {
    log('catch-up skipped (👀·📌 소스 모두 해제됨)');
    return;
  }
  log('catch-up: scanning reactions.list…');
  let cursor;
  let found = 0;
  for (let page = 0; page < 5; page++) {
    const res = await slack('reactions.list', { limit: 100, cursor });
    for (const item of res.items || []) {
      if (item.type !== 'message') continue;
      const m = item.message;
      // 👀류(eyes 소스)와 🔖/📌(later 소스)를 한 스캔에서 처리 — 소스별 게이트.
      const hit = (m.reactions || []).find(
        (r) =>
          ((EMOJIS.includes(r.name) && sourceOn('eyes')) ||
            (LATER_EMOJIS.includes(r.name) && sourceOn('later'))) &&
          (r.users || []).includes(MY_USER),
      );
      if (hit && !seen.has(`${item.channel}:${m.ts}`)) {
        found++;
        await processMessage(item.channel, m.ts, null, hit.name);
      }
    }
    cursor = res.response_metadata?.next_cursor;
    if (!cursor) break;
  }
  log(`catch-up done (${found} new)`);
}

// Later catch-up — stars.list(저장한 항목 목록)로 데몬이 죽어 있는 동안의
// 저장/해제를 맞춘다. stars:read 스코프가 없으면 한 번만 로그하고 이후 조용히
// 건너뛴다 (실시간 star 이벤트도 못 받으므로 Later 수집은 사실상 off).
let starsScopeMissing = false;

// 백필 컷오프 — 최초 실행 시 몇 년치 옛 저장 목록(수백 건)이 통째로 번역·수집돼
// 미처리를 뒤덮는 것을 막는다. 저장한 시점(date_create) 기준 최근 60일만 새로
// 수집한다. 이미 수집된 항목의 플래그 동기화(starred set)는 전체 목록 기준.
const STARS_BACKFILL_MAX_AGE = 60 * 86400;

async function starsCatchUp() {
  if (starsScopeMissing || !sourceOn('later')) return;
  const starred = new Set();
  let complete = true; // 목록을 끝까지 읽었는지 — 해제 반영은 완전한 목록에서만
  let skipped = 0;
  try {
    let cursor;
    for (let page = 0; ; page++) {
      const res = await slack('stars.list', { limit: 100, cursor });
      for (const item of res.items || []) {
        if (item.type !== 'message' || !item.message?.ts) continue;
        const id = `${item.channel}:${item.message.ts}`;
        starred.add(id);
        if (seen.has(id)) continue;
        const age = Date.now() / 1000 - Number(item.date_create || 0);
        if (item.date_create && age > STARS_BACKFILL_MAX_AGE) { skipped++; continue; }
        await processMessage(item.channel, item.message.ts, Number(item.date_create) || null, null, 'later');
      }
      cursor = res.response_metadata?.next_cursor;
      if (!cursor) break;
      if (page >= 4) { complete = false; break; } // 5페이지(500건) 상한
    }
    if (skipped) log(`stars catch-up: ${skipped}건은 저장한 지 60일이 지나 백필 생략`);
  } catch (e) {
    if (/missing_scope|not_allowed_token_type/.test(e.message)) {
      starsScopeMissing = true;
      log('stars.list unavailable — Later 수집 비활성 (user token에 stars:read 스코프 필요):', e.message);
    } else log('stars catch-up error:', e.message);
    return;
  }
  for (const o of loadItems()) {
    if (!o.later && starred.has(o.id)) {
      log(`stars catch-up: ${o.id} 저장됨 → later`);
      rewriteItem(o.id, { later: true });
    } else if (o.later && o.source === 'later' && complete && !starred.has(o.id)) {
      // 해제 반영은 star로 수집된 항목(source:'later')만 — 🔖/📌 리액션으로 later가
      // 된 항목은 star 목록에 없는 게 정상이라 여기서 건드리면 플래그가 풀려버린다.
      log(`stars catch-up: ${o.id} 저장 해제됨 → later 해제`);
      rewriteItem(o.id, { later: undefined });
      await markDone(o.id); // 저장으로만 수집된 항목은 done
    }
  }
}

// ---------------------------------------------------------------- done sync

// Set an item's 처리완료 state through the app (done.json stays app-owned).
// sync:false tells the app NOT to mirror the state back to Slack — the emoji is
// already in the desired state there, and skipping the mirror is what prevents
// an event loop. Returns false when the app isn't running; the next reconcile
// (done=true) or the user's next trigger (done=false) retries.
async function setDoneRemote(id, done) {
  try {
    const port = readFileSync(join(DATA_DIR, 'dashboard.port'), 'utf8').replace(/\D/g, '');
    if (!port) return false;
    const res = await fetch(`http://127.0.0.1:${port}/api/slack/done`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id, done, sync: false }),
      signal: AbortSignal.timeout(3000),
    });
    return res.ok;
  } catch {
    return false;
  }
}

function markDone(id) {
  return setDoneRemote(id, true);
}

// ---- 이모지 자동 해결 -------------------------------------------------------
// 트리거가 아닌 리액션이 붙은 항목을 처리완료로 넘긴다. 상태 자체는 기존 수동
// 처리완료와 같은 done.json 흐름을 쓰고(앱 소유), 항목 쪽에는 autoDone 표식만
// 남긴다 — 이 표식이 있어야만 리액션이 사라졌을 때 미처리로 되돌린다(수동으로
// 처리완료한 항목은 절대 되돌리지 않는다).
async function autoResolve(id, emoji, by) {
  try {
    if (loadDone()[id]) return; // 이미 처리완료 (수동이든 자동이든) — 건드리지 않음
    rewriteItem(id, { autoDone: true, autoEmoji: baseEmoji(emoji), autoBy: by || undefined });
    const ok = await markDone(id);
    log(`auto-done ${id}: :${baseEmoji(emoji)}: 리액션 감지 → 처리완료${ok ? '' : ' (app not running — reconcile가 재시도)'}`);
    if (ok) ping('ok', '이모지로 해결됨', `:${baseEmoji(emoji)}: 리액션 감지 — 자동 처리완료`);
  } catch (e) {
    log(`autoResolve ${id} error:`, e.message);
  }
}

// 마지막 비트리거 리액션이 사라졌다 → 자동 해결 취소. autoDone이 아닌 항목
// (사용자가 직접 처리완료한 항목)은 손대지 않는다.
async function autoUnresolve(id, item) {
  try {
    if (!item?.autoDone) return;
    rewriteItem(id, { autoDone: undefined, autoEmoji: undefined, autoBy: undefined });
    const ok = await setDoneRemote(id, false);
    log(`auto-undone ${id}: 비트리거 리액션이 모두 사라짐 → 미처리 복귀${ok ? '' : ' (app not running)'}`);
  } catch (e) {
    log(`autoUnresolve ${id} error:`, e.message);
  }
}

// 항목의 reactions 다중집합 갱신 — 이벤트 하나당 한 개 추가/제거.
function patchReactions(item, name, add) {
  const list = (item?.reactions || []).slice();
  const n = baseEmoji(name);
  if (add) list.push(n);
  else {
    const i = list.indexOf(n);
    if (i >= 0) list.splice(i, 1);
  }
  return list;
}

// 이미 수집된 항목에 트리거가 다시 발생했을 때(👀를 제거했다가 다시 달기 등):
// 목록 순서의 기준인 triggeredAt을 지금으로 갱신하고 처리완료를 해제한다 —
// "다시 봐 달라"는 뜻이므로 미처리 맨 위로 돌아와야 한다. 대시보드는
// triggeredAt(없으면 reactedAt) 내림차순으로 정렬한다. 호출부는 await하지 않으므로
// 여기서 다 삼킨다 (실패해도 다음 트리거에서 다시 시도된다).
async function retrigger(id, at, patch = {}) {
  try {
    // autoDone 표식도 함께 지운다 — 남의 리액션으로 자동 처리완료된 항목에 👀를
    // 다시 달면 "다시 보겠다"는 뜻이므로 미처리로 돌아와야 하는데, 표식이 남으면
    // 대시보드가 계속 숨기고 reconcile이 다시 처리완료로 되돌린다.
    rewriteItem(id, {
      triggeredAt: at || Math.floor(Date.now() / 1000),
      autoDone: undefined, autoEmoji: undefined, autoBy: undefined,
      ...patch,
    });
    const ok = await setDoneRemote(id, false);
    log(`retrigger ${id} → 미처리 복귀${ok ? '' : ' (app not running — done.json 갱신 실패)'}`);
    if (ok) ping('ok', '트리거 재발생', '기존 항목을 미처리 맨 위로 복귀');
  } catch (e) {
    log(`retrigger ${id} error:`, e.message);
  }
}

// done.json is app-owned (writes) but readable here — used to skip already-done
// items so reconcile/backfill only touch open ones.
function loadDone() {
  try {
    return JSON.parse(readFileSync(join(OUT_DIR, 'done.json'), 'utf8')) || {};
  } catch {
    return {};
  }
}

function loadItems() {
  const items = [];
  if (!existsSync(ITEMS_FILE)) return items;
  for (const line of readFileSync(ITEMS_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      items.push(JSON.parse(line));
    } catch {}
  }
  return items;
}

// Reconcile pass — realtime reaction_removed covers the normal case; this covers
// removals made while the daemon or app was down. For each OPEN item, ask Slack
// (reactions.get) whether my trigger emoji is still on the message; gone (or the
// message itself deleted) → 처리완료. Bounded to the newest 30 open items so a
// long backlog can't stall the loop.
async function reconcileRemoved() {
  const done = loadDone();
  // 멘션류 항목(source 있음)은 트리거 이모지가 원래 없다 — reactions.get으로
  // 검사하면 전부 "이모지 사라짐"으로 오판해 자동 처리완료돼 버리므로 제외한다.
  // 단, 나중에 👀를 직접 단 멘션 항목(emoji 있음)은 검사 대상이다. emoji 필드가
  // 생기기 전의 옛 👀 항목(source 없음)도 계속 포함된다.
  // 열린 항목 전부를 훑는다 — 멘션·DM·팀·전체호출 항목(source 있고 emoji 없음)도
  // 포함된다. 이들은 트리거 이모지 검사 대상은 아니지만(아래 hasTrigger 게이트),
  // "트리거가 아닌 리액션 = 이미 처리됨" 검사는 똑같이 받아야 한다 — 사용자가 가장
  // 많이 보는 항목이 바로 이쪽이기 때문이다. reactions.get 호출 수는 종전과 같은
  // 최신 30건 상한으로 묶어 rate limit 예산을 그대로 유지한다.
  const open = loadItems().filter((o) => !done[o.id]);
  let marked = 0;
  let auto = 0;
  for (const o of open.slice(-30)) {
    // 트리거 이모지 검사 대상 = 👀/🔖/📌로 수집된 항목(emoji 있음) 또는 emoji 필드
    // 이전의 옛 항목(source 없음). 멘션류는 원래 이모지가 없어 제외 — 검사하면
    // 전부 "사라짐"으로 오판한다.
    const hasTrigger = !!o.emoji || !o.source;
    try {
      const res = await slack('reactions.get', { channel: o.channel, timestamp: o.ts, full: 'true' });
      const reactions = res.message?.reactions || [];
      const emoji = o.emoji || EMOJIS[0];
      const still = reactions.some((r) => baseEmoji(r.name) === emoji && (r.users || []).includes(MY_USER));
      if (hasTrigger && !still) {
        if (await markDone(o.id)) {
          marked++;
          log(`reconcile: ${o.id} emoji removed in Slack → 처리완료`);
        }
        continue;
      }
      // 트리거가 아닌 리액션이 붙어 있으면(누가 달았든) 이미 해결된 메시지다.
      // 단 내 트리거 이모지가 아직 붙어 있는 항목은 건드리지 않는다 — 수집 시점과
      // 같은 이유로, 내가 들고 있는 항목이 남의 리액션 때문에 사라지면 안 된다.
      const resolved = hasTrigger && still ? null : resolvingReaction(reactions);
      const names = [];
      for (const r of reactions) {
        for (let i = 0; i < Math.max(1, (r.users || []).length); i++) names.push(baseEmoji(r.name));
      }
      if (resolved) {
        rewriteItem(o.id, { reactions: names });
        await autoResolve(o.id, resolved.name, resolved.by);
        auto++;
      } else if (JSON.stringify(names) !== JSON.stringify(o.reactions || [])) {
        rewriteItem(o.id, { reactions: names.length ? names : undefined });
      }
    } catch (e) {
      if (hasTrigger && /message_not_found/.test(e.message) && (await markDone(o.id))) {
        marked++;
        log(`reconcile: ${o.id} message deleted → 처리완료`);
      } else if (!/message_not_found/.test(e.message)) {
        log(`reconcile ${o.id} error:`, e.message);
      }
    }
  }
  if (marked) ping('ok', '이모지 제거 감지', `${marked}건 자동 처리완료`);
  if (auto) log(`reconcile: 비트리거 리액션으로 ${auto}건 자동 처리완료`);
}

// Backfill 의미 분석 + 의사결정 선택지 for open items translated before those
// features existed. Bounded per boot; done items are left alone.
async function backfillDecisions() {
  const done = loadDone();
  const targets = loadItems()
    .filter((o) => !done[o.id] && !o.pending && o.textEn && (!o.decision || !o.meaning))
    .slice(-10);
  for (const o of targets) {
    log(`backfilling meaning/decision for ${o.id}`);
    const ctx = await gatherContext(o.channel, o.ts, o.threadTs);
    const tr = await translate(o.textEn, ctx);
    if (!tr.decision && !tr.meaning) continue;
    rewriteItem(o.id, {
      textKo: tr.ko || o.textKo,
      meaning: tr.meaning || o.meaning,
      decision: tr.decision || o.decision,
      lang: tr.ko ? tr.lang : undefined,
      model: tr.model,
    });
    log(`backfilled ${o.id}`);
  }
}

// ---------------------------------------------------------------- socket mode

let ws = null;
let backoff = 1;

async function connect() {
  if (existsSync(DISABLED_FILE)) {
    log('disabled file present — idling');
    setHealth({ socket: 'disabled' });
    setTimeout(connect, 60_000);
    return;
  }
  try {
    const open = await slack('apps.connections.open', {}, APP_TOKEN);
    ws = new WebSocket(open.url);
    ws.onopen = () => {
      backoff = 1;
      log('socket connected');
      ping('ok', '소켓 연결', '슬랙 실시간 수신 대기 중');
      // 붙었다 = 네트워크도 토큰도 정상 — 앱이 띄운 안내를 내릴 근거.
      setHealth({ socket: 'connected', failures: 0, netError: '', authError: '' });
    };
    ws.onmessage = (ev) => {
      let env;
      try {
        env = JSON.parse(ev.data);
      } catch {
        return;
      }
      if (env.envelope_id) ws.send(JSON.stringify({ envelope_id: env.envelope_id })); // ack ≤3s
      if (env.type === 'disconnect') {
        log('server asked disconnect:', env.reason);
        ws.close();
        return;
      }
      if (env.type !== 'events_api') return;
      const e = env.payload?.event;
      if (e?.type === 'reaction_added' && e.user === MY_USER && e.item?.type === 'message') {
        const at = Math.floor(Number(e.event_ts) || 0);
        const id = `${e.item.channel}:${e.item.ts}`;
        if (EMOJIS.includes(e.reaction) && sourceOn('eyes')) {
          log(`👀 reaction_added in ${e.item.channel}`);
          // 이미 수집된 항목에 👀를 다시 달았다 = 재트리거 (제거→처리완료 뒤
          // 다시 보겠다는 뜻). 새 항목이 아니라 기존 항목을 미처리로 되살린다.
          if (seen.has(id)) retrigger(id, at, { emoji: e.reaction });
          else processMessage(e.item.channel, e.item.ts, at, e.reaction);
        } else if (LATER_EMOJIS.includes(e.reaction) && sourceOn('later')) {
          // 🔖/📌 리액션 → Later 버킷. 이미 수집된 항목(👀 등)이면 플래그만 달고
          // 재트리거로 취급한다 — 트리거 이모지(item.emoji)는 처음 수집한 것을 유지.
          log(`📌 later reaction_added ${id}`);
          if (seen.has(id)) retrigger(id, at, { later: true });
          else processMessage(e.item.channel, e.item.ts, at, e.reaction);
        }
      }
      // 트리거가 아닌 리액션이 붙었다 → 누군가 이미 처리한 메시지. 누가 달았는지는
      // 상관없다(MY_USER 조건 없음). 이미 수집된 항목만 대상 — 새 항목을 만들지는
      // 않는다(수집 기준은 기존 그대로).
      if (e?.type === 'reaction_added' && e.item?.type === 'message' && !isTriggerEmoji(e.reaction)) {
        const id = `${e.item.channel}:${e.item.ts}`;
        if (seen.has(id)) {
          const it = loadItems().find((o) => o.id === id);
          if (it) {
            rewriteItem(id, { reactions: patchReactions(it, e.reaction, true) });
            autoResolve(id, e.reaction, e.user);
          }
        }
      }
      // 트리거가 아닌 리액션이 제거됐다 → 마지막 하나였다면 미처리로 복귀
      // (autoDone 항목만 — 수동 처리완료는 그대로 둔다).
      if (e?.type === 'reaction_removed' && e.item?.type === 'message' && !isTriggerEmoji(e.reaction)) {
        const id = `${e.item.channel}:${e.item.ts}`;
        if (seen.has(id)) {
          const it = loadItems().find((o) => o.id === id);
          if (it) {
            const left = patchReactions(it, e.reaction, false);
            rewriteItem(id, { reactions: left.length ? left : undefined });
            if (!firstNonTrigger(left)) autoUnresolve(id, it);
          }
        }
      }
      // 알림류(멘션·팀멘션·DM·@here) 새 메시지 → 같은 번역 파이프라인. 판별은
      // 폴링 경로와 공유하는 mentionKind() 한 곳에서 한다. 편집/삭제 등 subtype
      // 이벤트와 내가 쓴 메시지는 제외.
      // (Slack 앱의 Event Subscriptions에 message.* user 이벤트 구독이 있어야 수신됨 —
      //  없으면 이 블록은 영원히 안 돌고 폴링(activityPoll)이 대신 잡는다.)
      // #hero 채널 새 메시지 → 칭찬 수집기. 번역 파이프라인과 별개 경로이므로
      // 아래 알림 판별(멘션·DM 등)보다 먼저, 독립적으로 처리한다. 내가 쓴 칭찬도
      // 수집 대상이라 MY_USER 제외가 없다.
      if (e?.type === 'message' && e.channel === HERO_CHANNEL && typeof e.text === 'string') {
        log(`hero: 실시간 메시지 ${e.ts}`);
        heroCollect(e)
          .then(heroAiDrain)
          .then(() => setHeroCursor(e.ts))
          .catch((err) => log('hero realtime error:', err.message));
      }
      if (
        e?.type === 'message' &&
        isRealMessage(e) &&
        e.user &&
        e.user !== MY_USER &&
        typeof e.text === 'string'
      ) {
        // message 이벤트가 실제로 도착했다 = 구독이 살아 있다. 첫 수신만 즉시
        // 보고하고(페이지의 '실시간' 표시), 이후엔 30초 주기 보고에 맡긴다.
        const nowSec = Math.floor(Date.now() / 1000);
        if (!health.realtimeAt) setHealth({ realtimeAt: nowSec });
        else health.realtimeAt = nowSec;
        const isDM = e.channel_type === 'im' || e.channel_type === 'mpim';
        const kind = mentionKind(e.text, isDM);
        if (kind && sourceOn(kind)) {
          log(`realtime ${kind} message in ${e.channel}`);
          processMessage(e.channel, e.ts, Math.floor(Number(e.ts) || 0), null, kind);
        }
      }
      // Slack 'Save for later'(북마크) → 📌 Later 버킷. star_added/star_removed는
      // Slack 앱에 사용자 이벤트 구독 + stars:read 스코프가 있어야 수신된다 —
      // 미구독이면 이벤트가 안 올 뿐 무해 (catch-up의 stars.list도 같은 스코프).
      if (
        (e?.type === 'star_added' || e?.type === 'star_removed') &&
        e.user === MY_USER &&
        e.item?.type === 'message'
      ) {
        const id = `${e.item.channel}:${e.item.ts}`;
        if (e.type === 'star_added' && sourceOn('later')) {
          log(`📌 star_added ${id}`);
          if (seen.has(id)) retrigger(id, Math.floor(Number(e.event_ts) || 0), { later: true });
          else processMessage(e.item.channel, e.item.ts, Math.floor(Number(e.event_ts) || 0), null, 'later');
        } else if (e.type === 'star_removed' && seen.has(id)) {
          log(`star_removed ${id} → later 해제`);
          rewriteItem(id, { later: undefined });
          // 저장 때문에만 수집된 항목(source:'later')은 저장 해제 = 목록에서 뺀다는
          // 뜻 — 👀 제거 시 자동 처리완료와 같은 의미론으로 done 처리한다.
          const it = loadItems().find((o) => o.id === id);
          if (it?.source === 'later') markDone(id);
        }
      }
      // Slack에서 이모지를 직접 제거 → 대시보드 자동 처리완료. The dashboard's own
      // 처리완료-check also lands here (its reactions.remove is issued as me) but
      // markDone is idempotent and sends sync:false, so nothing loops.
      if (
        e?.type === 'reaction_removed' &&
        EMOJIS.includes(e.reaction) &&
        e.user === MY_USER &&
        e.item?.type === 'message'
      ) {
        const id = `${e.item.channel}:${e.item.ts}`;
        if (seen.has(id)) {
          log(`reaction_removed ${id} → 처리완료`);
          markDone(id).then((ok) => {
            if (ok) ping('ok', '이모지 제거 감지', '항목 자동 처리완료');
            else log(`markDone ${id} failed (app not running?) — reconcile will retry`);
          });
        }
      }
      // 🔖/📌 리액션 제거 → later 해제. 그 이모지가 이 항목의 수집 트리거였다면
      // 👀 제거와 동일한 의미론으로 자동 처리완료까지 간다.
      if (
        e?.type === 'reaction_removed' &&
        LATER_EMOJIS.includes(e.reaction) &&
        e.user === MY_USER &&
        e.item?.type === 'message'
      ) {
        const id = `${e.item.channel}:${e.item.ts}`;
        if (seen.has(id)) {
          const it = loadItems().find((o) => o.id === id);
          log(`later reaction_removed ${id} → later 해제${it?.emoji === e.reaction ? ' + 처리완료' : ''}`);
          rewriteItem(id, { later: undefined });
          if (it?.emoji === e.reaction) markDone(id);
        }
      }
      // periodic disabled check piggybacks on traffic
      if (existsSync(DISABLED_FILE)) {
        log('disabled file appeared — closing socket');
        ws.close();
      }
    };
    ws.onclose = () => {
      log(`socket closed — reconnect in ${backoff}s`);
      setHealth({ socket: 'connecting' });
      setTimeout(connect, backoff * 1000);
      backoff = Math.min(backoff * 2, 60);
    };
    ws.onerror = (e) => log('socket error:', e.message || 'unknown');
  } catch (e) {
    log(`connect failed (${e.message}) — retry in ${backoff}s`);
    health.failures++;
    classifyFailure(e);
    setHealth({ socket: 'connecting' });
    postHealth(); // failures/원인이 바뀌었을 수 있다 — 앱이 안내 여부를 다시 판단
    setTimeout(connect, backoff * 1000);
    backoff = Math.min(backoff * 2, 60);
  }
}

// ---------------------------------------------------------------- #hero

// 팀 칭찬 채널(#hero) 수집기. 👀 번역 파이프라인과 완전히 분리된 별도 모듈이다 —
// items.jsonl을 건드리지 않고 <data>/hero/slack.jsonl에만 append한다.
//
// 소유권: 이 파일은 데몬만 쓴다(append + 같은 라인 patch). 앱(HeroStore.swift)은
// 읽기만 하고, /hero 스킬이 쓰는 heroes.db와 머지해서 Hero 탭에 보여준다.
//
// 파싱: 스킬의 표준 포맷을 정규식으로 먼저 시도하고(무료·즉시), 실패한 메시지만
// AI로 1회 구조화한 뒤 결과를 라인에 캐시한다 — 같은 메시지에 두 번 묻지 않는다.
// 둘 다 실패하면 parsed:null로 두고 원문 카드로만 노출한다(조용히).

const HERO_CHANNEL = process.env.CM_HERO_CHANNEL || 'C084315S2F2';
const HERO_DIR = join(DATA_DIR, 'hero');
const HERO_FILE = join(HERO_DIR, 'slack.jsonl');
const HERO_CURSOR = join(HERO_DIR, 'cursor.json');
// 한 번의 실행에서 AI 폴백을 돌릴 최대 건수. 수년치 백필이 한 번에 수백 콜을
// 때리지 않도록 하는 상한 — 남은 건은 다음 캐치업(30분)에서 이어서 처리한다.
const HERO_AI_MAX = Number(process.env.CM_HERO_AI_MAX || 60);

const heroSeen = new Set(); // ts already appended
let heroTeamUrl = ''; // auth.test().url — permalink 조립용

function heroLoadState() {
  if (!existsSync(HERO_FILE)) return;
  for (const line of readFileSync(HERO_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      heroSeen.add(JSON.parse(line).ts);
    } catch {}
  }
  log(`hero: ${heroSeen.size} messages already collected`);
}

function heroAppend(o) {
  mkdirSync(HERO_DIR, { recursive: true });
  appendFileSync(HERO_FILE, JSON.stringify(o) + '\n');
  heroSeen.add(o.ts);
}

// items.jsonl의 rewriteItem과 같은 read-modify-rename. 데몬이 유일한 writer라
// 우리 쪽에서는 경합이 없다.
function heroRewrite(ts, patch) {
  if (!existsSync(HERO_FILE)) return;
  const out = readFileSync(HERO_FILE, 'utf8')
    .split('\n')
    .map((line) => {
      if (!line.trim()) return line;
      try {
        const o = JSON.parse(line);
        if (o.ts !== ts) return line;
        const merged = { ...o, ...patch };
        for (const k of Object.keys(merged)) if (merged[k] === undefined) delete merged[k];
        return JSON.stringify(merged);
      } catch {
        return line;
      }
    });
  const tmp = HERO_FILE + '.tmp';
  writeFileSync(tmp, out.join('\n'));
  renameSync(tmp, HERO_FILE);
}

function heroCursor() {
  try {
    return JSON.parse(readFileSync(HERO_CURSOR, 'utf8')).latest || null;
  } catch {
    return null;
  }
}

function setHeroCursor(latest) {
  mkdirSync(HERO_DIR, { recursive: true });
  writeFileSync(HERO_CURSOR, JSON.stringify({ latest }));
}

function heroPermalink(ts) {
  if (!heroTeamUrl) return '';
  return `${heroTeamUrl.replace(/\/$/, '')}/archives/${HERO_CHANNEL}/p${String(ts).replace('.', '')}`;
}

// 표준 포맷 파서 — 스킬(hero SKILL.md / hero_db.py)의 출력 모양을 그대로 읽는다:
//   [N] @Nominee Name (한글 표기)
//   skill-name (lvN) / 상세 이유 / next todo: 다음 한 걸음 (next level: 선택)
// 줄바꿈 없이 한 줄로 붙여 쓴 변형도 받는다. 못 읽으면 null.
function heroParseRegex(text) {
  const t = (text || '').replace(/\r/g, '').trim();
  if (!t) return null;
  const head = t.match(/\[(\d+)\]\s*@?\s*([^\n(]+?)\s*(?:\(([^)\n]*)\))?\s*(?:\n|$)/);
  if (!head) return null;
  const rest = t.slice(head.index + head[0].length).trim();
  const body = rest.match(
    /^(.+?)\s*\(\s*lv\s*(\d+)\s*\)\s*\/\s*([\s\S]*?)\s*\/\s*next\s*todo\s*:\s*([\s\S]+)$/i,
  );
  if (!body) return null;
  let nextTodo = body[4].trim();
  let nextLevel = '';
  const nl = nextTodo.match(/\(\s*next\s*level\s*:\s*([\s\S]*?)\s*\)\s*$/i);
  if (nl) {
    nextLevel = nl[1].trim();
    nextTodo = nextTodo.slice(0, nl.index).trim();
  }
  return {
    entryNo: Number(head[1]),
    nominee: head[2].trim(),
    nominee_korean: (head[3] || '').trim(),
    skill: body[1].trim(),
    level: Number(body[2]),
    reason: body[3].trim(),
    next_todo: nextTodo,
    next_level_goal: nextLevel,
  };
}

// 모델 라우팅은 번역 경로와 동일(gemini 키 → anthropic 키 → claude CLI)하되,
// 번역용 섹션 분리 대신 원문 텍스트를 그대로 돌려준다.
async function heroAsk(prompt) {
  if (geminiKey === undefined) geminiKey = keychain('cm-gemini-api-key');
  if (anthropicKey === undefined) anthropicKey = keychain('cm-anthropic-api-key');
  let choice = currentModel();
  if (choice === 'auto') choice = geminiKey ? 'gemini-flash-lite' : anthropicKey ? 'haiku-api' : 'haiku';
  if (GEMINI_MODELS[choice] && geminiKey) {
    try {
      return await translateGemini(GEMINI_MODELS[choice], prompt);
    } catch (e) {
      log(`hero ai fail (${choice}): ${e.message} — claude CLI로 폴백`);
    }
  } else if (choice === 'haiku-api' && anthropicKey) {
    try {
      return await translateAnthropicAPI(prompt);
    } catch (e) {
      log(`hero ai fail (haiku-api): ${e.message} — claude CLI로 폴백`);
    }
  }
  return await translateClaude(prompt);
}

const HERO_AI_PROMPT = `You are parsing one Slack message from a team praise ("hero") channel.
Extract the praise into JSON. Reply with ONLY the JSON object, no code fence, no commentary.

Schema:
{"nominee":"person being praised","nominee_korean":"korean rendering or empty",
 "skill":"the skill praised","level":<integer 1-10>,"reason":"the detailed reason",
 "next_todo":"the immediate next step","next_level_goal":"longer-term goal or empty",
 "confidence":<0-1>}

Rules:
- If the message is NOT a praise nomination (chit-chat, a link, an emoji, an announcement),
  reply exactly: NONE
- Never invent a reason or a next step. If a field is absent, use an empty string.
- Keep the original wording of reason / next_todo; do not translate or summarize.

Message:
`;

async function heroParseAI(text) {
  const out = await heroAsk(HERO_AI_PROMPT + text);
  if (!out) return null;
  const s = out.trim();
  if (/^NONE\b/i.test(s)) return { none: true };
  const m = s.match(/\{[\s\S]*\}/);
  if (!m) return null;
  try {
    const o = JSON.parse(m[0]);
    if (!o.nominee) return { none: true };
    return {
      nominee: String(o.nominee || '').trim(),
      nominee_korean: String(o.nominee_korean || '').trim(),
      skill: String(o.skill || '').trim(),
      level: Number(o.level) || 1,
      reason: String(o.reason || '').trim(),
      next_todo: String(o.next_todo || '').trim(),
      next_level_goal: String(o.next_level_goal || '').trim(),
      confidence: Number(o.confidence) || 0,
    };
  } catch {
    return null;
  }
}

// 메시지 하나를 수집한다. 정규식으로 읽히면 즉시 확정, 아니면 aiPending으로
// 남겨두고 heroAiDrain()이 뒤에서 채운다 (목록은 먼저 뜨고 구조가 나중에 붙는다).
async function heroCollect(msg) {
  if (!msg?.ts || heroSeen.has(msg.ts)) return;
  if (msg.subtype && msg.subtype !== 'thread_broadcast') return; // join/leave/파일 등 제외
  const text = await cleanText(msg.text || '');
  if (!text.trim()) return;
  const parsed = heroParseRegex(text);
  heroAppend({
    ts: msg.ts,
    threadTs: msg.thread_ts && msg.thread_ts !== msg.ts ? msg.thread_ts : undefined,
    at: Math.floor(Number(msg.ts) || 0),
    user: msg.user || '',
    nominator: msg.user ? await userName(msg.user) : '',
    permalink: heroPermalink(msg.ts),
    text,
    parsed: parsed || undefined,
    parsedBy: parsed ? 'regex' : undefined,
    aiPending: parsed ? undefined : true,
  });
}

// aiPending 라인을 순차로(동시성 1) 구조화한다. 상한(HERO_AI_MAX)에 걸리면 남은
// 건은 다음 캐치업에서 이어서 한다.
async function heroAiDrain() {
  if (!existsSync(HERO_FILE)) return;
  const pending = [];
  for (const line of readFileSync(HERO_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const o = JSON.parse(line);
      if (o.aiPending) pending.push(o);
    } catch {}
  }
  if (!pending.length) return;
  const batch = pending.slice(0, HERO_AI_MAX);
  log(`hero: AI 구조화 ${batch.length}건 (대기 ${pending.length}건)`);
  let ok = 0;
  for (const o of batch) {
    let r = null;
    try {
      r = await heroParseAI(o.text);
    } catch (e) {
      log('hero ai error:', e.message);
    }
    if (r === null) continue; // 호출 자체 실패 — aiPending 유지, 다음 회차 재시도
    if (r.none) {
      heroRewrite(o.ts, { aiPending: undefined, parsedBy: 'none' }); // 칭찬 글이 아님
    } else {
      heroRewrite(o.ts, { parsed: r, parsedBy: 'ai', aiPending: undefined });
      ok++;
    }
  }
  log(`hero: AI 구조화 완료 ${ok}건`);
  if (pending.length > batch.length) log(`hero: ${pending.length - batch.length}건은 다음 캐치업에서 계속`);
}

// 커서가 없으면 채널 전체 백필, 있으면 그 이후만. 스레드 답글도 함께 읽는다
// (칭찬 보강 코멘트가 스레드에 달리는 경우가 있다).
async function heroSync() {
  const cursorTs = heroCursor();
  const full = !cursorTs;
  log(full ? 'hero: 첫 실행 — 채널 전체 백필' : `hero: ${cursorTs} 이후 캐치업`);
  let latest = cursorTs || '0';
  let got = 0;
  try {
    let page = 0;
    let cursor;
    for (;;) {
      const res = await slack('conversations.history', {
        channel: HERO_CHANNEL,
        limit: 200,
        oldest: cursorTs || undefined,
        cursor,
      });
      for (const m of res.messages || []) {
        await heroCollect(m);
        got++;
        if (Number(m.ts) > Number(latest)) latest = m.ts;
        if (m.reply_count) {
          try {
            const rep = await slack('conversations.replies', { channel: HERO_CHANNEL, ts: m.ts, limit: 100 });
            for (const r of rep.messages || []) {
              if (r.ts === m.ts) continue;
              await heroCollect(r);
              if (Number(r.ts) > Number(latest)) latest = r.ts;
            }
          } catch (e) {
            log('hero replies fail', m.ts, e.message);
          }
        }
      }
      cursor = res.response_metadata?.next_cursor;
      if (!cursor || !res.has_more) break;
      if (++page >= 50) {
        log('hero: 50페이지 상한 도달 — 다음 회차에서 계속');
        break;
      }
    }
  } catch (e) {
    // not_in_channel / missing_scope 등은 조용히 넘어간다 — 커서를 옮기지 않아
    // 다음 회차에 그대로 재시도된다.
    log('hero sync error:', e.message);
    return;
  }
  if (latest !== '0') setHeroCursor(latest);
  log(`hero: ${got}건 조회, 총 ${heroSeen.size}건 수집됨`);
  await heroAiDrain();
}

// ---------------------------------------------------------------- main

async function main() {
  APP_TOKEN = keychain('cm-slack-app-token');
  USER_TOKEN = keychain('cm-slack-user-token');
  if (!APP_TOKEN || !USER_TOKEN) {
    console.error(
      'missing keychain tokens: cm-slack-app-token (xapp-…) / cm-slack-user-token (xoxp-…)',
    );
    await ping('error', '토큰 없음', '키체인 cm-slack-app-token / cm-slack-user-token 등록 필요');
    // 재시작으로는 절대 낫지 않는 상태 — 앱이 자동 복구 대신 토큰 안내를 띄우도록
    // 마지막 상태로 남긴다 (아래 exit로 하트비트는 여기서 끊긴다).
    health.authError = '키체인에 토큰이 없습니다 (cm-slack-app-token / cm-slack-user-token)';
    await postHealth();
    process.exit(78); // EX_CONFIG — launchd throttles restarts
  }
  mkdirSync(OUT_DIR, { recursive: true });
  if (existsSync(CONFIG_FILE)) {
    try {
      const cfg = JSON.parse(readFileSync(CONFIG_FILE, 'utf8'));
      if (Array.isArray(cfg.emojis) && cfg.emojis.length) EMOJIS = cfg.emojis;
      if (Array.isArray(cfg.laterEmojis) && cfg.laterEmojis.length) LATER_EMOJIS = cfg.laterEmojis;
    } catch {}
  }
  log(`emojis: ${EMOJIS.join(', ')} · later emojis: ${LATER_EMOJIS.join(', ')} · sources: `
    + ['eyes', 'mention', 'team', 'dm', 'broadcast', 'later']
      .map((k) => `${k}=${sourceOn(k)}`).join(' '));

  const auth = await slack('auth.test');
  MY_USER = auth.user_id;
  heroTeamUrl = auth.url || '';
  log(`authed as ${auth.user} (${MY_USER}) in ${auth.team}`);
  await loadMyGroups(); // 팀 멘션 판별용 — 이후 30분 주기로 갱신

  loadState();
  heroLoadState();
  // 백필 단독 실행 모드 — 소켓 없이 #hero 전체만 긁고 끝낸다 (첫 도입/재백필용).
  if (process.env.CM_HERO_BACKFILL === '1') {
    await heroSync();
    process.exit(0);
  }
  await connect(); // realtime first — catch-up fills the gap behind it
  // Items appended but never translated (daemon died mid-run, or a previous
  // translate failed): finish them now, oldest first.
  for (const o of pendingAtBoot) {
    log(`retrying pending translation ${o.id}`);
    const ctx = await gatherContext(o.channel, o.ts, o.threadTs);
    const tr = await translate(o.textEn, ctx);
    rewriteItem(o.id, {
      textKo: tr.ko || '',
      meaning: tr.meaning || undefined,
      decision: tr.decision || undefined,
      lang: tr.ko ? tr.lang : undefined,
      model: tr.ko ? tr.model : undefined,
      trMs: tr.ko ? tr.ms : undefined,
      pending: undefined,
      error: tr.ko ? undefined : 'translate-failed',
      translatedAt: Math.floor(Date.now() / 1000),
    });
    log(`saved ${o.id}${tr.ko ? '' : ' (translation FAILED again)'}`);
  }
  catchUp()
    .then(starsCatchUp)
    .then(reconcileRemoved)
    .then(backfillDecisions)
    .catch((e) => log('catch-up error:', e.message));
  // #hero 수집 — 첫 실행은 채널 전체 백필, 이후엔 커서 이후만.
  heroSync().catch((e) => log('hero sync error:', e.message));
  // 알림(멘션·DM·전체호출) 폴링 — 첫 실행은 커서만 "지금"으로 잡고 끝난다(백필 없음).
  activityPoll()
    .catch((e) => log('알림 폴링 오류:', e.message))
    .finally(schedulePoll);
  setInterval(
    () =>
      loadMyGroups()
        .then(catchUp)
        .then(starsCatchUp)
        .then(reconcileRemoved)
        .then(heroSync)
        .catch((e) => log('catch-up error:', e.message)),
    30 * 60_000,
  );
  // 살아있음 보고 — 앱은 이게 90초 끊기면 데몬이 죽은 것으로 보고 스스로 되살린다.
  postHealth();
  setInterval(postHealth, 30_000);
}

main().catch(async (e) => {
  console.error('fatal:', e);
  // 죽더라도 원인은 남긴다. 부팅 중 죽으면 프로세스마다 카운터가 초기화되므로
  // (launchd가 10초마다 되살린다) 여기서 확정 실패로 올려 앱이 '일시적 끊김'으로
  // 오해하지 않게 한다.
  health.failures = Math.max(health.failures + 1, 2);
  classifyFailure(e);
  await postHealth();
  process.exit(1);
});
