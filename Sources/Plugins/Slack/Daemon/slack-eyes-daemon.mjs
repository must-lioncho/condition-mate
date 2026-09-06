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
// 멘션·DM 에 나가는 선응답(ack)의 포맷은 버전으로 관리한다 (alignment-engine.mjs).
// v2 가 기본이고 config.json {"replyFormat":"v1"} 로 옛 포맷으로 되돌린다 —
// v2 는 맨 위 한 줄에 한두 단어로 "이렇게 이해했다 / 이렇게 결정될 것 같다"를 놓고
// 그 아래 의미 분석과 예상 의사결정 두 칸만 보낸다. 근거 레이어는 그대로 다 돈다.
// 같은 스레드에 답이 여러 번 나가면 상대는 어느 것이 지금 답인지 알 수 없다. 그래서
// 새 답을 올린 뒤 그 스레드의 이전 답을 chat.delete 로 지우고(24시간 이내의 것만),
// 지운 내용은 ack-threads.json 에 쌓아 다음 답의 <prior> 로 넘긴다 — 스레드에는
// 항상 마지막 한 개만 남고 내용은 축적된다.
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
// 프로세스가 살아 있다고 소켓이 살아 있는 것은 아니다 — 죽은 WebSocket이 close를
// 안 보내면 하트비트는 계속 나가면서 이벤트만 0건이 된다. 그래서 socket:'connected'
// 대신 프레임 수신(frameAt)으로 판정하고, 무수신이 길면 스스로 다시 개통한다
// (socketStale/rotateSocket 참고).
//
// 멀티모달: 메시지에 붙은 이미지·PDF·영상·링크는 media-extract.mjs(별도 소유자의
// 파일)가 텍스트와 비전 파트로 바꿔 주고, 데몬은 그것을 번역 프롬프트의
// <attachments> 와 items.jsonl 의 optional media[] 에 싣는다. 그 파일이 없거나
// 로드에 실패하면 첨부는 이름·링크만 남고 나머지는 예전과 똑같이 동작한다 —
// 첨부 처리 하나 때문에 슬랙 수집 전체가 멈추는 쪽이 훨씬 큰 손해다.
// 첨부만 있고 본문이 빈 메시지도 더는 버리지 않는다 (예전엔 empty-text로 버렸다).
//
// Zero npm dependencies — Node 22 native fetch + WebSocket.

import { execFileSync, execFile } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractionPrompt, parseExtraction, renderReply, evidenceRequestLevel,
  replyFormat, LATEST_REPLY_FORMAT, ackSendGate, ACK_MIN_CONFIDENCE,
  resolveChannel, ACK_FALLBACK_LEDGER,
  slackBrief, stripFrames } from './alignment-engine.mjs';
import { sensitiveContext } from './send-layer.mjs';
import { noteFileName, renderNote, writeNote } from './ack-note.mjs';
// 수신자 언어 규칙은 이 파일이 아니라 reply-language.mjs 한 곳에 있다. 여기서 다시
// 판정하지 않는다 — 2026-08-31 야샬 건 전에는 같은 규칙의 사본이 세 곳에 있었다.
import { hangulRatio, hasEnglishSentence, countryLanguage, decideReplyLanguage,
  languageViolation, languageRetryRule, foreignSegments,
  untranslatedSegments } from './reply-language.mjs';
// 민감정보 요청 게이트. 규칙과 실측 근거는 그 파일에 있고 여기서 다시 판정하지 않는다.
import { securityGate } from './security-gate.mjs';

// ---------------------------------------------------------------- config

const DATA_DIR = process.env.CM_DATA_DIR || join(homedir(), '.condition-mate');
const OUT_DIR = join(DATA_DIR, 'slack-translate');
const ITEMS_FILE = join(OUT_DIR, 'items.jsonl');
const DISABLED_FILE = join(DATA_DIR, 'slack-translate-disabled');
const CONFIG_FILE = join(OUT_DIR, 'config.json');
// 데몬 액션 로그 — 앱의 actions.jsonl과 같은 스키마의 짝 파일. 대시보드 디버그
// 패널이 두 파일을 at 기준으로 병합해 한 타임라인으로 보여준다. 파일을 나눈
// 이유는 앱(Swift)이 seek+write로 append해 O_APPEND 원자성이 없기 때문 —
// 한 파일에 두 프로세스가 쓰면 줄이 겹쳐 깨진다.
const ACTIONS_FILE = join(OUT_DIR, 'actions-daemon.jsonl');
// 알림 폴링 커서 — 이 시각 이후의 메시지만 수집한다 (데몬 소유).
const CURSOR_FILE = join(OUT_DIR, 'poll-cursor.json');
const PEOPLE_ROSTER_FILE = join(OUT_DIR, 'people-roster.json');
// 데몬이 어느 슬랙 계정으로 붙어 있는지 — auth.test 결과를 디스크에 남긴 것.
// 이것이 없으면 items.jsonl 만 보고는 autoBy 가 "라이언 본인" 인지 "남" 인지
// 가를 수 없다. 오프라인 도구(Scripts/slack-backlog-close.mjs)가 토큰 없이
// 자기 id 를 알아야 해서, 매번 auth.test 를 다시 부르는 대신 여기에 캐시한다.
// 토큰은 절대 여기 들어가지 않는다 — user_id/user/team 이름뿐이다.
const SELF_FILE = join(OUT_DIR, 'self.json');
// 스레드별 선응답 원장 — 그 스레드에 지금 떠 있는 우리 답변의 ts 와, 지운 답변의
// 내용이다. 같은 스레드에 답이 여러 개 쌓이면 상대는 어느 것이 지금 답인지 알 수
// 없다 ("더 보완했습니다" 가 세 개 나란히 있는 상태). 그래서 새 답을 올린 뒤 이전
// 답을 지우고, 지운 내용은 다음 답의 <prior> 로 넘겨 축적한다.
const ACK_THREADS_FILE = join(OUT_DIR, 'ack-threads.json');
// 하루가 지난 답변은 지우지 않는다 — 상대가 이미 읽고 그것을 근거로 움직였을 수 있다.
const ACK_SUPERSEDE_WINDOW_SEC = 24 * 3600;
// 프롬프트에 싣는 이전 답변 수와 원장 보관 기간.
const ACK_PRIOR_MAX = 3;
const ACK_THREAD_TTL_SEC = 7 * 86400;
const CHANNEL_POLICY_FILE = join(OUT_DIR, 'channel-policy.json');
const BUNDLED_REPLY_POLICY_FILE = join(dirname(fileURLToPath(import.meta.url)), 'slack-reply-policy.json');
// 선응답이 어떤 근거를 조회해도 되는지의 사람별 등급. 번들 정책 위에 운영 정책을
// 덮어쓴다 (채널 응답 정책과 같은 두 겹 구조).
const BUNDLED_PERMISSION_POLICY_FILE = join(dirname(fileURLToPath(import.meta.url)), 'slack-permission-policy.json');
const PERMISSION_POLICY_FILE = join(OUT_DIR, 'permission-policy.json');
// 자동 응답을 아예 만들지 않는 자리(인사·보상·법무·의료). 응답 정책이 채널 ID
// 거부 목록이라 어제 만들어진 그룹 DM 을 담을 수 없다 — 그래서 자리가 아니라
// 주제로 판정한다. 번들 위에 운영 파일을 덮어쓰는 두 겹 구조는 같다.
const BUNDLED_SENSITIVE_POLICY_FILE = join(dirname(fileURLToPath(import.meta.url)), 'slack-sensitive-policy.json');
const SENSITIVE_POLICY_FILE = join(OUT_DIR, 'sensitive-policy.json');
const SENSITIVE_POLICY_FILES = [BUNDLED_SENSITIVE_POLICY_FILE, SENSITIVE_POLICY_FILE];
// 같은 대상을 부르는 다른 이름의 대응표 (Bolor Geo SG = MPC SG 처럼). 스레드에도
// Jira에도 없고 조직만 아는 사실이라 별도 파일로 둔다.
const BUNDLED_GLOSSARY_FILE = join(dirname(fileURLToPath(import.meta.url)), 'slack-glossary.json');
const GLOSSARY_FILE = join(OUT_DIR, 'glossary.json');
// 글 대신 리액션 하나로 끝내도 되는 자리에서 쓸 이모지의 뜻. 이모지는 표준 의미가
// 없어 팀마다 다르므로 이 파일이 정본이다 (✅ 는 동의가 아니라 "체크만 했다").
const BUNDLED_EMOJI_LAYER_FILE = join(dirname(fileURLToPath(import.meta.url)), 'slack-emoji-layer.json');
const EMOJI_LAYER_FILE = join(OUT_DIR, 'emoji-layer.json');
// 축 1(커뮤니케이션 코스트)·축 2(문제 정의) 에이전트의 런타임 페르소나와 등급표.
// 위의 네 정책 파일과 같은 두 겹이다 — 번들이 정본이고 운영 수정은 OUT_DIR 로 덮어쓴다.
// 두 축을 한 파일에 두지 않는 이유는 두 축이 서로의 판정을 바꾸지 않기 때문이다
// (docs/slack-ack-two-axis-design.md §1). 한 파일에 두면 한 축을 고칠 때 다른 축이
// 함께 더러워지고 소유자도 둘이 된다.
const BUNDLED_ACK_COST_POLICY_FILE = join(dirname(fileURLToPath(import.meta.url)), 'slack-ack-cost-policy.json');
const ACK_COST_POLICY_FILE = join(OUT_DIR, 'ack-cost-policy.json');
const BUNDLED_FRAMING_POLICY_FILE = join(dirname(fileURLToPath(import.meta.url)), 'slack-problem-framing-policy.json');
const FRAMING_POLICY_FILE = join(OUT_DIR, 'problem-framing-policy.json');
// 슬랙에 나가지 않는 전부가 여기 MD 한 장으로 남는다. items.jsonl·ack-threads.json·
// media-cache/ 와 같은 자리, 같은 관행 (docs §7-3).
const ACK_NOTE_DIR = join(OUT_DIR, 'ack-notes');

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

// ---- 처리완료로 읽지 않는 리액션 -------------------------------------------
// 위의 "트리거가 아니면 누군가 처리한 것" 규칙은 2026-09-02 에 통째로 뒤집혔다.
// 처음에는 예외가 하나였다 — 🔍(보는 중)처럼 "지금 읽고 있다" 를 뜻하는 이모지는
// 트리거도 아니지만 해결도 아니다. 지금은 그 예외가 규칙이다: 어떤 리액션도 항목을
// 닫지 않는다. 아래 resolvesPolicy 가 그 자리다.
//
// 왜 필요한가 (2026-09-02 사고): 그룹 DM 의 1785자 설명에 강등 표식으로 ✅ 가 나갔고,
// 그 ✅ 가 곧바로 resolvingReaction 에 걸려 의사결정이 필요한 항목이 미처리에서
// 사라졌다. 이모지만 🔍 로 바꾸고 이 규칙을 그대로 두면 같은 일이 이름만 바꿔 다시
// 일어난다 — 데몬이 자기가 단 🔍 를 남이 처리한 신호로 되읽는다.
//
// 이름은 어휘집(slack-emoji-layer.json)의 resolves:false 한 줄에서만 온다. 코드에
// 박지 않는 것은 emoji-layer.mjs 가 이미 정해 둔 규칙이다 — 이모지의 뜻은 그 파일이
// 정본이다. 다만 여기 함수들은 동기이고 emoji-layer 모듈이 로드되기 전(수집 경로 ·
// 소켓 이벤트)에도 돌기 때문에 모듈을 부르지 않고 JSON 을 직접 읽는다.
//
// 2026-09-02 라이언 결정으로 이 규칙 위에 축이 하나 더 생겼다 — resolvesPolicy.
// "어떤 리액션도 항목을 닫지 않는다. 미처리는 손으로 닫는다." 행마다 resolves:false
// 를 적는 것으로는 이 결정이 구현되지 않는다: 아래 nonResolvingEmojiNames 는 어휘집에
// 이름이 적힌 행만 알고, 어휘집에 없는 이름은 예전 규칙대로 항목을 닫는다. items.jsonl
// 1,793건 실측으로 트리거를 뺀 리액션 이름 89종 중 어휘집에 있는 것이 8종이고 나머지
// 81종 1,481건이 전부 그 경로로 닫고 있었다. 그래서 행 단위 값이 아니라 파일 단위
// 값이 필요했다.
//
// 2026-09-06 에 그 결정이 한 번 더 좁혀졌다 — 값이 셋이 됐다. 09-02 판은 리액션에 의한
// 자동 처리완료를 통째로 껐는데, 그날 막으려던 사고는 그것의 부분집합이었다. items.jsonl
// 2,004줄 실측: 자동 처리완료 1,083건 중 데몬이 자기가 단 이모지에 걸려 닫은 것이 155건
// (14.3%)이고, 라이언이 슬랙에서 손으로 단 것이 557건(51.4%), 남이 단 것이 371건(34.3%)
// 이다. 155건짜리 부분집합을 막으려고 1,083건 전부를 껐고 대체 경로는 없었다. 그래서
// 'self' 가 생겼다 — 라이언 본인이 단 것만 닫되, 그중에서도 이 데몬이 그 항목에 단
// 이모지는 빼고 닫는다.
//
// 두 조건이 다 필요하다. slack() 의 기본 토큰이 USER_TOKEN(xoxp)이고 postEmojiReaction
// 이 그 기본값으로 reactions.add 를 부르므로, 데몬이 단 것도 소켓에는 e.user === MY_USER
// 로 되돌아온다. MY_USER 조건만 걸면 09-02 사고가 그대로 재현된다.
const RESOLVES_POLICIES = ['none', 'self', 'catalog'];

// 어휘집 두 겹에서 이 축이 쓰는 필드만 뽑는다. 키마다 따로 이긴다 — emojis 는
// 예전 그대로 "비어 있지 않은 배열을 가진 마지막 파일" 이 통째로 이기고(병합하면
// 운영 파일에서 지운 항목이 번들에 남아 "지웠는데 아직 도는" 상태가 된다),
// resolvesPolicy 는 그 키를 실제로 적어 둔 마지막 파일이 이긴다. 문서 하나를 통째로
// 바꿔치기하지 않는 이유는, 정책만 적은 운영 오버라이드가 번들의 emojis 를 통째로
// 날려 버리는 일을 막기 위해서다.
function emojiLayerResolveFields() {
  let rows = null;
  let policy = null;
  let readOk = false;
  for (const f of [BUNDLED_EMOJI_LAYER_FILE, EMOJI_LAYER_FILE]) {
    try {
      const j = JSON.parse(readFileSync(f, 'utf8'));
      readOk = true;
      if (Array.isArray(j?.emojis) && j.emojis.length) rows = j.emojis;
      if (typeof j?.resolvesPolicy === 'string') policy = j.resolvesPolicy;
    } catch {}
  }
  return { rows, policy, readOk };
}

// 지금 어떤 리액션이 항목을 닫는가. 'none' = 아무것도 안 닫는다, 'self' = 라이언 본인이
// 단 것만 닫되 이 데몬이 그 항목에 단 이모지는 뺀다(2026-09-06), 'catalog' = 예전
// 동작(행 단위 resolves 가 정하고 어휘집에 없는 이름은 닫는다).
//
// 세 갈래의 바닥값이 서로 다른 것이 의도다. 'self' 가 늘어도 바닥값 두 줄은 한 글자도
// 바뀌지 않는다 — 키 없음은 여전히 'catalog' 이고 못 읽음·모르는 값은 여전히 'none' 이다.
//  - 키가 아예 없는 옛 어휘집 → 'catalog'. 이 축을 모르던 파일은 예전과 똑같이 돌아야
//    한다. 여기서 none 으로 떨어뜨리면 이 코드를 옛 어휘집에 얹는 순간 동작이 말없이
//    바뀐다.
//  - 파일을 못 읽었거나 모르는 값이 적혀 있다 → 'none'(fail-closed). 앞선 판은 이
//    자리에서 "오늘의 동작 유지" 를 골랐는데, 그 선택은 라이언이 방금 금지한 해악을
//    조용히 되살린다. 항목이 쌓이는 것은 눈에 보이고 손으로 되돌릴 수 있지만,
//    의사결정이 필요한 항목이 사라지는 것은 둘 다 아니다. 조용하지 않게 한 번 남긴다.
let resolvesPolicyValue = null;
let resolvesPolicyAt = 0;
let resolvesPolicyFallbackLogged = false;
function resolvesPolicy() {
  if (resolvesPolicyValue && Date.now() - resolvesPolicyAt < 60_000) return resolvesPolicyValue;
  const { policy, readOk } = emojiLayerResolveFields();
  let v = 'catalog';
  let why = '';
  if (!readOk) { v = 'none'; why = '어휘집 두 겹을 모두 읽지 못했다'; }
  else if (policy === null) v = 'catalog';                  // 이 축을 모르는 옛 어휘집
  else if (RESOLVES_POLICIES.includes(policy)) v = policy;
  else { v = 'none'; why = `모르는 값 "${policy}" 이 적혀 있다`; }
  if (why && !resolvesPolicyFallbackLogged) {
    resolvesPolicyFallbackLogged = true;
    log(`resolvesPolicy: ${why} → none 으로 닫는다 (리액션에 의한 자동 처리완료 전면 중지)`);
  }
  resolvesPolicyValue = v;
  resolvesPolicyAt = Date.now();
  return v;
}

let nonResolvingNames = null;
let nonResolvingAt = 0;
function nonResolvingEmojiNames() {
  if (nonResolvingNames && Date.now() - nonResolvingAt < 60_000) return nonResolvingNames;
  const names = new Set();
  for (const e of emojiLayerResolveFields().rows || []) {
    if (e && e.resolves === false && e.name) names.add(String(e.name));
  }
  nonResolvingNames = names;
  nonResolvingAt = Date.now();
  return names;
}

// 이 항목에 "우리가" 단 이모지 집합. 'self' 에서 자기 이모지를 되읽지 않기 위한 것이다.
//
// ackEmoji 는 스칼라라 갈아치워진다 — 데몬이 ✅ 를 달았다가 나중에 🔍 로 바꾸면 최신
// 하나만 남고, 예전에 우리가 단 ✅ 가 뒤늦게 이벤트로 돌아오면 필터를 통과해 항목을
// 닫는다(실제로 ackSupersededAt 을 가진 항목이 2건 있다). 그래서 ackEmojis 배열을 따로
// 누적하고 여기서 "배열 ∪ 스칼라" 로 읽는다.
//
// 배열이 아니라 합집합인 이유는 하위 호환이다. ackEmojis 가 없는 옛 레코드(2026-09-06
// 실측으로 ackEmoji 를 가진 항목 295건이 전부 그렇다)도 스칼라 하나가 들어간 집합이
// 되므로 읽는 쪽이 멈추지 않는다. ackEmoji 를 배열로 바꾸지 않은 것도 같은 이유다 —
// 대시보드(SlackTranslateContent.swift:759)가 그 스칼라를 문자열로 읽고 있다.
function ourAckEmojis(item) {
  const s = new Set();
  for (const n of item?.ackEmojis || []) s.add(baseEmoji(n));
  if (item?.ackEmoji) s.add(baseEmoji(item.ackEmoji));   // 옛 레코드 하위 호환
  return s;
}

// 이 리액션이 "누군가 이미 처리했다" 로 읽히는가. 정책이 none 이면 무엇이 붙었든
// 아니다 — 어휘집에 이름이 없는 이모지까지 여기서 함께 막힌다. 이 한 줄이 라이언의
// 결정이 실제로 구현되는 자리이고, 아래 두 함수와 resolvingReaction 을 부르는 세
// 경로(수집 · reconcile · 소켓)가 전부 여기를 지난다.
//
// 2026-09-06 에 입력이 넓어졌다. 'self' 는 이름만으로 판정할 수 없어서 누가 달았는지
// (ctx.by)와 어느 항목에 달렸는지(ctx.item)가 있어야 한다. 조건을 호출부로 흩뿌리지
// 않고 문 하나를 넓힌 것은 SLKST-8 이 이 셋을 유일한 문으로 계약하기 때문이다 —
// 호출부에 if 를 하나 더 두면 자동 처리완료 경로 셋 중 하나가 반드시 문을 우회한다.
//
// 'none' 과 'catalog' 아래의 동작은 ctx 가 있든 없든 예전과 바이트 단위로 같다.
function isResolvingEmoji(name, ctx) {
  const policy = resolvesPolicy();
  if (policy === 'none') return false;
  if (isTriggerEmoji(name)) return false;
  if (policy === 'self') {
    // fail-closed. ctx 가 없거나(수집 경로처럼 항목이 아직 없다) MY_USER 가 아직
    // null 이면(auth.test 전에 도착한 이벤트) 닫지 않는다. 여기서 "모르면 닫는다" 로
    // 떨어뜨리면 09-02 사고의 방향으로 실패한다.
    if (!ctx || !ctx.by || !ctx.item || !MY_USER) return false;
    if (ctx.by !== MY_USER) return false;
    // 우리가 그 항목에 단 이모지는 우리 것이다. 이 한 줄이 없으면 데몬의 리액션이
    // xoxp 로 나가는 탓에 MY_USER 조건을 그대로 통과한다 — 그것이 09-02 사고다.
    if (ourAckEmojis(ctx.item).has(baseEmoji(name))) return false;
  }
  return !nonResolvingEmojiNames().has(baseEmoji(name));   // 행 단위 값은 계속 존중된다
}

// 메시지 리액션 목록(reactions.get·conversations.history의 msg.reactions)에서
// 처리완료로 읽히는 첫 리액션. 없으면 null.
//
// by 를 고르는 규칙이 2026-09-06 에 바뀌었다. 예전에는 users[0] — 첫 사람 — 만 봤고,
// 여러 사람이 같은 이모지를 달았을 때 라이언이 첫 번째가 아니면 'self' 가 그를 놓친다.
// 'catalog' 에서는 by 가 판정에 안 쓰이고 기록(autoBy)에만 쓰이므로 이 식을 공통으로
// 써도 닫히고 안 닫히고가 갈리지 않는다 — 기록되는 사람이 "아무나 한 명" 에서 "라이언이
// 있으면 라이언" 으로 바뀔 뿐이고, 그쪽이 autoByMe 의 뜻에 더 맞는다.
function resolvingReaction(reactions, ctx) {
  for (const r of reactions || []) {
    const users = r.users || [];
    const by = (MY_USER && users.includes(MY_USER)) ? MY_USER : users[0];
    if (isResolvingEmoji(r.name, { by, item: ctx?.item })) return { name: baseEmoji(r.name), by };
  }
  return null;
}

// 항목에 기록해 둔 리액션 이름 배열(다중집합 — 같은 이모지를 여러 사람이 달 수
// 있다)에서 처리완료로 읽히는 첫 이름. 옛 항목엔 reactions 필드가 없다(= 없음).
// 이름은 옛 이름 그대로 둔다 — 부르는 자리가 이 한 곳이고, 이름을 바꾸면 이 파일과
// 원장·문서에 남은 "firstNonTrigger" 라는 말이 서로 다른 것을 가리키게 된다.
//
// 이 함수는 이름 배열만 받는다 — item.reactions 는 이름 다중집합이고 누가 달았는지를
// 저장하지 않는다. 그래서 'self' 아래에서는 ctx.by 를 만들 수 없어 위 fail-closed 규칙에
// 걸려 언제나 null 이다. 그것은 결함이 아니라 의도이고, 그렇기 때문에 reaction_removed
// 가드가 'self' 에서 이 함수에 기대면 안 된다 — !null 이 항상 참이 되어 리액션 하나 뗄
// 때마다 예전에 자동 처리완료된 항목이 전부 다시 열린다. 그 자리는 autoEmoji/autoBy 로
// 판정한다(아래 소켓 핸들러).
function firstNonTrigger(names) {
  for (const n of names || []) if (isResolvingEmoji(n)) return baseEmoji(n);
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

// ---------------------------------------------------------------- 채널 구독
// 멘션·DM·@here 어디에도 걸리지 않는 채널 메시지를 외부 명령에 넘기는 경로다.
// 번역 파이프라인을 타지 않는다 — 봇이 쏘는 알림(GitHub PR 등)을 번역해 봐야
// 모델 비용만 나가고 대시보드에는 사람이 볼 일 없는 항목만 쌓이기 때문이다.
// #hero 수집과 같은 급의 독립 경로이며, 정책은 전부 호출되는 쪽이 갖는다.
// 이 데몬은 "구독한 채널에 메시지가 왔다"만 알려 준다.
//
// config.json 예:
//   "channelSubs": [
//     { "channel": "C0BRKAMHEE5", "label": "matchhire-pr",
//       "exec": "/Users/…/scripts/on-slack-message.sh" }
//   ]
//
// 넘기는 것: 메시지 JSON 한 줄을 stdin 으로. 환경변수로 SLACK_USER_TOKEN 을 함께
// 준다 — 받는 쪽이 리액션을 달려면 토큰이 필요한데, 스크립트마다 키체인을 다시
// 읽게 하면 토큰에 손대는 주체만 늘어난다. 토큰은 이미 이 프로세스가 들고 있다.
function channelSubs() {
  try {
    const cfg = JSON.parse(readFileSync(CONFIG_FILE, 'utf8'));
    return Array.isArray(cfg.channelSubs) ? cfg.channelSubs : [];
  } catch {
    return [];
  }
}

// 한 메시지당 한 번만 디스패치한다. 슬랙은 같은 이벤트를 재전송할 수 있고
// 재연결 직후에는 특히 흔하다. 승인처럼 되돌리기 어려운 일을 시키는 경로라
// 중복 실행을 데몬 쪽에서 먼저 막는다.
const subDispatched = new Set();

function dispatchChannelSub(e) {
  const sub = channelSubs().find((x) => x && x.channel === e.channel && x.exec);
  if (!sub) return;
  const id = `${e.channel}:${e.ts}`;
  if (subDispatched.has(id)) return;
  subDispatched.add(id);
  if (subDispatched.size > 2000) subDispatched.clear();

  const label = sub.label || 'channelsub';
  const payload = JSON.stringify({
    channel: e.channel,
    ts: e.ts,
    text: typeof e.text === 'string' ? e.text : '',
    user: e.user || '',
    bot_id: e.bot_id || '',
    subtype: e.subtype || '',
    attachments: e.attachments || [],
    blocks: e.blocks || [],
    label,
  });

  // 구독 원장 — 디스패치했다는 사실은 받는 쪽 성패와 무관하게 남긴다.
  try {
    mkdirSync(OUT_DIR, { recursive: true });
    appendFileSync(join(OUT_DIR, 'channel-subs.jsonl'), payload + '\n');
  } catch {}

  const t0 = Date.now();
  log(`channelsub ${label}: dispatch ${id} -> ${sub.exec}`);
  const child = execFile(
    sub.exec,
    [],
    {
      env: { ...process.env, PATH: TOOL_PATH, SLACK_USER_TOKEN: USER_TOKEN || '' },
      timeout: 15 * 60_000,
      maxBuffer: 8 * 1024 * 1024,
    },
    (err, stdout, stderr) => {
      const ms = Date.now() - t0;
      if (err) {
        log(`channelsub ${label}: FAIL ${id} (${ms}ms)`, err.message, String(stderr || '').slice(0, 400));
        act(`channelsub.${label}`, { id, ok: false, ms, error: err.message });
      } else {
        log(`channelsub ${label}: ok ${id} (${ms}ms)`, String(stdout || '').trim().slice(0, 200));
        act(`channelsub.${label}`, { id, ok: true, ms });
      }
    },
  );
  try {
    child.stdin.end(payload);
  } catch (err) {
    log(`channelsub ${label}: stdin write fail`, err.message);
  }
}

// PATH for spawned tools (launchd gives a bare PATH; claude lives in ~/.local/bin etc.)
const TOOL_PATH = [
  join(homedir(), '.local', 'bin'),
  '/opt/homebrew/bin',
  '/usr/local/bin',
  process.env.PATH || '/usr/bin:/bin',
].join(':');

const log = (...a) => console.log(new Date().toISOString(), ...a);

// 액션 로그 한 줄 (ACTIONS_FILE 헤더 참고). 앱의 SlackActionLog.log와 같은 필드 —
// {at, action, id, ok, ms, error, detail} + by:'daemon'. 수집·번역처럼 앱 밖에서
// 일어나는 일도 대시보드 액션 로그에 소요시간과 함께 남는다. 실패해도 파이프라인을
// 멈추지 않는다 (로그가 본업을 방해하면 안 된다).
// 모델 단가표 (USD / 1M tokens). 앱은 원장 행의 cost_usd 만 읽고 스스로 가격을
// 계산하지 않으므로, 비용을 아는 유일한 자리가 여기다. 이 표가 없으면 이 루프의
// 비용은 화면에서 영원히 0 으로 남는다 (실제로 그랬다 — 원장 8118행 중 비용이
// 붙은 행이 0 이었다). 단가가 바뀌면 여기만 고친다.
// prefix 일치로 찾는다 — 'claude-haiku-4-5-20251001' 같은 날짜 붙은 id 도 잡기 위해서다.
const MODEL_PRICES = [
  ['gemini-flash-lite', { in: 0.10, out: 0.40 }],
  ['gemini-flash', { in: 0.30, out: 2.50 }],
  ['claude-haiku-4-5', { in: 1.00, out: 5.00 }],
];

// 모르는 모델은 0 이 아니라 null 을 돌려준다. 0 을 쓰면 "공짜로 돌았다"와
// "단가를 모른다"가 화면에서 같은 모양이 되고, 그 둘은 완전히 다른 말이다.
function modelCostUSD(model, input, output) {
  const id = String(model || '');
  const hit = MODEL_PRICES.find(([prefix]) => id.startsWith(prefix));
  if (!hit) return null;
  const [, p] = hit;
  return (Number(input || 0) / 1e6) * p.in + (Number(output || 0) / 1e6) * p.out;
}

function act(action, { id = '', ok = true, ms = 0, error = '', detail = '',
  input_tokens, output_tokens, total_tokens, model } = {}) {
  try {
    mkdirSync(OUT_DIR, { recursive: true });
    appendFileSync(
      ACTIONS_FILE,
      JSON.stringify({
        at: Math.floor(Date.now() / 1000),
        action,
        id,
        ok,
        ms: Math.round(ms),
        error: String(error || '').slice(0, 300),
        detail: String(detail || '').slice(0, 300),
        by: 'daemon',
        ...(Number(total_tokens || 0) > 0 ? {
          input_tokens: Number(input_tokens || 0), output_tokens: Number(output_tokens || 0),
          total_tokens: Number(total_tokens || 0), model: String(model || ''),
          // 단가를 아는 모델일 때만 붙인다. 키가 아예 없는 것과 0 인 것이 다르게 읽히도록.
          ...(modelCostUSD(model, input_tokens, output_tokens) === null ? {}
            : { cost_usd: modelCostUSD(model, input_tokens, output_tokens) }),
        } : {}),
      }) + '\n',
    );
  } catch {}
}

function keychain(service, account = '') {
  try {
    const args = ['find-generic-password', '-w', '-s', service];
    if (account) args.push('-a', account);
    return execFileSync('security', args, {
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
  socket: 'starting', // starting | connecting | connected | stale(조용히 죽어 재개통 중) | disabled
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
  // 소켓이 "조용히 죽는" 경우를 앱에 드러내기 위한 값들 (아래 socketStale 참고).
  frameAt: 0, // 소켓에서 마지막으로 무언가(hello·이벤트·disconnect) 받은 시각
  rotations: 0, // 조용한 소켓을 감지해 다시 개통한 횟수
  idleLimit: 0, // 이 데몬이 쓰는 무수신 상한(초) — 앱이 자기 백스톱을 이보다 늦게 잡는다
  // "고쳤다"와 "고친 것이 돈다"가 갈라지는 것을 화면에서 보이게 하는 두 값 (codeWatchdog 참고).
  codeAt: 0, // 내가 로드한 파일들의 최신 mtime — 디스크가 이보다 새로우면 나는 옛 코드다
  codeStale: false, // 디스크가 더 새롭다는 것을 감지했는가 (감지하면 스스로 종료한다)
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

// 액션 로그에는 실패한 호출만 남긴다 — 성공까지 남기면 30초 폴링·reconcile이
// 매일 수천 줄을 찍어 사람이 읽을 수 없는 로그가 된다. 앱 쪽(SlackTranslateStore)
// 은 사용자가 누른 액션에서만 호출하므로 전건을 남긴다.
async function slack(method, params = {}, token = USER_TOKEN) {
  const t0 = Date.now();
  // 본문은 남기지 않는다 — 채널/ts 좌표만 (앱 쪽 api.* 로그와 같은 규칙).
  const target = [params.channel, params.timestamp || params.ts || params.thread_ts]
    .filter(Boolean).join(':');
  const fail = (error) => act(`api.${method}`, { ok: false, ms: Date.now() - t0, error, detail: target });
  const body = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) body.set(k, String(v));
  let res;
  try {
    res = await fetch(`https://slack.com/api/${method}`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body,
    });
  } catch (e) {
    fail(e.message || 'network');
    throw e;
  }
  // 네트워크가 슬랙을 막으면 200 JSON이 아니라 프록시 차단 페이지(HTML)나 4xx가
  // 온다 — res.json()이 던지는 SyntaxError로 두면 원인을 알 수 없으니 번역한다.
  let json;
  try {
    json = await res.json();
  } catch {
    fail(`HTTP ${res.status} — non-JSON`);
    throw new Error(`HTTP ${res.status} — 슬랙 대신 JSON이 아닌 응답 (프록시·방화벽 차단으로 보임)`);
  }
  if (!json.ok) {
    fail(json.error);
    throw new Error(`slack ${method}: ${json.error}`);
  }
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
  let resolved = false;
  try {
    const info = await slack('conversations.info', { channel: id });
    const c = info.channel;
    // DM은 채널명이 없다 — 상대가 누구인지가 유일하게 쓸모 있는 라벨이다.
    // (그룹 DM의 mpdm-… 원문은 읽기 어려워 사람 이름만 남긴다.)
    if (c.is_im) name = `DM · ${await userName(c.user)}`;
    else if (c.is_mpim) name = `그룹 DM · ${(c.name || '').replace(/^mpdm-|-\d+$/g, '').replaceAll('--', ', ')}`;
    else name = `#${c.name || id}`;
    resolved = true;
  } catch (e) {
    log('channelName fail', id, e.message);
  }
  // 실패는 캐시하지 않는다. 예전에는 rate limit이나 일시 오류로 한 번 실패하면
  // 그 채널은 프로세스가 죽을 때까지 영원히 ID로 남았다 (채널명 자리에 C… 2건).
  if (resolved) channelNames.set(id, name);
  return name;
}

// 봇은 users.info로 안 나온다 (B…로 시작하는 bot_id는 다른 네임스페이스다).
// bots.info를 따로 불러야 이름이 나오고, 그 스코프가 없으면 조용히 ID로 남는다.
async function botName(id) {
  try {
    const info = await slack('bots.info', { bot: id });
    return info.bot?.name || info.bot?.app_id || '';
  } catch (e) {
    log('botName fail', id, e.message);
    return '';
  }
}

async function userName(id) {
  if (!id) return '';
  if (userNames.has(id)) return userNames.get(id);
  let name = id;
  let resolved = false;
  if (/^B[A-Z0-9]+$/.test(id)) {
    // 봇 ID — users.info는 user_not_found만 돌려준다. 곧장 bots.info로 간다.
    const b = await botName(id);
    if (b) { name = b; resolved = true; }
  } else {
    try {
      const info = await slack('users.info', { user: id });
      name = info.user.profile.display_name || info.user.real_name || info.user.name || id;
      resolved = true;
    } catch (e) {
      log('userName fail', id, e.message);
    }
  }
  // 실패를 캐시하면 일시 오류가 영구 오류가 된다 (원시 ID가 그대로 남은 10건의
  // 일부가 이 경로다). 성공한 것만 캐시한다.
  if (resolved) userNames.set(id, name);
  return name;
}

// ---- 이모지 shortcode → 실제 문자 -------------------------------------------
// 대시보드는 항목 본문을 esc()한 평문 그대로 <div class="ko">에 넣는다
// (SlackTranslateContent.swift:1774) — 마크다운도 shortcode도 렌더링하지 않는다.
// 그래서 :tada:를 문자로 바꾸는 일은 데몬이 해야 한다. 안 하면 원문 237건에
// 남고 모델이 그대로 옮겨 적어 번역문 226건까지 따라간다 (전수 조사 수치).
// 새 패키지를 못 쓰므로 표를 직접 둔다. 코퍼스에 실제로 나온 표준 코드 118종을
// 전부 덮고, 흔한 것을 더 넣었다. 커스텀 이모지(:li:, :ez_clap: 등)는 유니코드
// 대응이 없으므로 이름 그대로 남긴다 — 지우면 무슨 뜻이었는지도 사라진다.
const EMOJI = {
  saluting_face: '🫡', 'man-bowing': '🙇‍♂️', 'woman-bowing': '🙇‍♀️', bow: '🙇',
  white_check_mark: '✅', heavy_check_mark: '✔️', ballot_box_with_check: '☑️',
  raised_hands: '🙌', clap: '👏', pray: '🙏', handshake: '🤝', muscle: '💪',
  sparkles: '✨', tada: '🎉', confetti_ball: '🎊', trophy: '🏆', crown: '👑',
  point_right: '👉', point_left: '👈', point_up: '☝️', point_down: '👇',
  arrow_right: '➡️', arrow_left: '⬅️', arrow_up: '⬆️', arrow_down: '⬇️',
  arrows_counterclockwise: '🔄', repeat: '🔁', recycle: '♻️',
  loudspeaker: '📢', mega: '📣', bell: '🔔', speech_balloon: '💬', thought_balloon: '💭',
  green_heart: '💚', yellow_heart: '💛', blue_heart: '💙', purple_heart: '💜',
  white_heart: '🤍', black_heart: '🖤', orange_heart: '🧡', heart: '❤️', broken_heart: '💔',
  eyes: '👀', x: '❌', o: '⭕', heavy_multiplication_x: '✖️',
  rocket: '🚀', fire: '🔥', boom: '💥', zap: '⚡', star: '⭐', star2: '🌟', dizzy: '💫',
  chipmunk: '🐿️', bee: '🐝', honey_pot: '🍯', black_cat: '🐈‍⬛', cat: '🐱', dog: '🐶',
  seedling: '🌱', herb: '🌿', bouquet: '💐', cherry_blossom: '🌸', four_leaf_clover: '🍀',
  slightly_smiling_face: '🙂', blush: '😊', smile: '😄', smiley: '😃', grin: '😁',
  laughing: '😆', joy: '😂', rolling_on_the_floor_laughing: '🤣', sweat_smile: '😅',
  wink: '😉', sunglasses: '😎', nerd_face: '🤓', thinking_face: '🤔', shushing_face: '🤫',
  no_mouth: '😶', relieved: '😌', sob: '😭', cry: '😢', disappointed: '😞',
  partying_face: '🥳', heart_eyes: '😍', robot_face: '🤖', ghost: '👻',
  wave: '👋', '+1': '👍', thumbsup: '👍', '-1': '👎', thumbsdown: '👎', ok_hand: '👌',
  raised_hand: '✋', v: '✌️', fist: '✊', pick: '⛏️', hammer_and_wrench: '🛠️', wrench: '🔧',
  gear: '⚙️', bug: '🐛', computer: '💻', keyboard: '⌨️', iphone: '📱',
  pushpin: '📌', round_pushpin: '📍', paperclip: '📎', link: '🔗', bookmark: '🔖',
  memo: '📝', pencil2: '✏️', lower_left_ballpoint_pen: '🖊️', book: '📖', books: '📚',
  newspaper: '📰', clipboard: '📋', page_facing_up: '📄', file_folder: '📁', package: '📦',
  chart_with_upwards_trend: '📈', chart_with_downwards_trend: '📉', bar_chart: '📊',
  moneybag: '💰', money_with_wings: '💸', credit_card: '💳', dollar: '💵',
  date: '📅', calendar: '📆', spiral_calendar_pad: '🗓️', stopwatch: '⏱️',
  alarm_clock: '⏰', hourglass_flowing_sand: '⏳', clock3: '🕒',
  email: '✉️', 'e-mail': '✉️', envelope_with_arrow: '📩', incoming_envelope: '📨',
  inbox_tray: '📥', outbox_tray: '📤', telephone_receiver: '📞',
  lock: '🔒', closed_lock_with_key: '🔐', unlock: '🔓', key: '🔑', shield: '🛡️',
  warning: '⚠️', rotating_light: '🚨', alert: '🚨', exclamation: '❗',
  heavy_exclamation_mark: '❗', bangbang: '‼️', question: '❓', bulb: '💡',
  mag: '🔍', dart: '🎯', sports_medal: '🏅', medal: '🎖️', mortar_board: '🎓',
  movie_camera: '🎥', clapper: '🎬', studio_microphone: '🎙️', microphone: '🎤',
  video_game: '🎮', headphones: '🎧', tv: '📺', camera: '📷',
  earth_africa: '🌍', earth_americas: '🌎', earth_asia: '🌏', globe_with_meridians: '🌐',
  ocean: '🌊', sunny: '☀️', cloud: '☁️', rainbow: '🌈', snowflake: '❄️',
  house: '🏠', office: '🏢', busts_in_silhouette: '👥', bust_in_silhouette: '👤',
  airplane: '✈️', car: '🚗', ship: '🚢', construction: '🚧',
  coffee: '☕', beer: '🍺', cake: '🍰', pizza: '🍕', gift: '🎁', balloon: '🎈',
  red_circle: '🔴', large_blue_circle: '🔵', green_circle: '🟢', yellow_circle: '🟡',
  large_yellow_circle: '🟡', white_circle: '⚪', black_circle: '⚫', orange_circle: '🟠',
  small_red_triangle: '🔺', small_red_triangle_down: '🔻', 'ok': '🆗', '100': '💯',
  kr: '🇰🇷', jp: '🇯🇵', cn: '🇨🇳', us: '🇺🇸', gb: '🇬🇧',
  'flag-kr': '🇰🇷', 'flag-jp': '🇯🇵', 'flag-us': '🇺🇸', 'flag-in': '🇮🇳',
  'flag-pk': '🇵🇰', 'flag-ke': '🇰🇪', 'flag-ph': '🇵🇭', 'flag-vn': '🇻🇳',
  'flag-id': '🇮🇩', 'flag-gb': '🇬🇧', 'flag-sg': '🇸🇬',
};

// 워크스페이스 커스텀 이모지 — 상당수가 표준 이모지의 별칭(alias:tada)이라
// 한 번만 받아 두면 :green-heart: 같은 것이 💚로 풀린다. emoji:read 스코프가
// 없으면 조용히 비활성(표준 표만 쓴다). 한 번 실패하면 다시 시도하지 않는다.
// 프로미스를 캐시한다 — 맵을 캐시하면 첫 호출이 응답을 기다리는 동안 뒤따라온
// 메시지들이 빈 맵을 보고 지나간다 (수집은 동시에 여러 건이 돈다).
let emojiAliasP = null;
function loadEmojiAliases() {
  if (!emojiAliasP) {
    emojiAliasP = (async () => {
      const map = new Map();
      try {
        const res = await slack('emoji.list');
        for (const [name, val] of Object.entries(res.emoji || {})) {
          if (typeof val === 'string' && val.startsWith('alias:')) map.set(name, val.slice(6));
        }
        log(`emoji.list: 커스텀 별칭 ${map.size}건 로드`);
      } catch (e) {
        log('emoji.list 없음 — 표준 이모지 표만 사용:', e.message);
      }
      return map;
    })();
  }
  return emojiAliasP;
}

// :shortcode: → 문자. 별칭은 3단계까지만 따라간다 (순환 별칭 방어).
async function renderEmoji(t) {
  if (!t.includes(':')) return t;
  // Slack이 붙이는 피부색 수정자는 텍스트에서 아무 의미가 없다 (코퍼스 45건).
  t = t.replace(/:skin-tone-\d+:/g, '');
  const codes = [...t.matchAll(/:([a-z0-9_+'-]+):/gi)].map((m) => m[1]);
  if (!codes.length) return t;
  const alias = await loadEmojiAliases();
  for (const raw of new Set(codes)) {
    let name = raw.toLowerCase();
    for (let i = 0; i < 3 && !EMOJI[name] && alias.has(name); i++) name = alias.get(name).toLowerCase();
    const ch = EMOJI[name];
    if (ch) t = t.replaceAll(`:${raw}:`, ch);
  }
  return t;
}

// ---- Slack 마크업 평문 노출 --------------------------------------------------
// *굵게*는 코퍼스 229건으로 인용(11건)·표(5건)보다 훨씬 흔하고, 대부분 제목처럼
// 구조를 나르는 자리다(*Plan:*, *현황 및 대안 (기획 단계):*). 평문 렌더링에서는
// 별표가 그대로 보이므로 구분자만 떼어낸다.
// ~취소선~은 건드리지 않는다 — 코퍼스 8건을 전부 열어 보니 대부분 취소선이 아니라
// 근사값 표기였다(~100x higher, 가능시 2~, 3.60B, not ~). 구분자를 떼면 2건을
// 고치는 대신 최소 2건을 망가뜨린다. 밑줄(_)과 백틱도 같은 이유로 그대로 둔다
// (식별자·코드에 정상적으로 들어간다).
const BOLD_RE = /(?<![*\w])\*(?![\s*])([^*\n]{1,200}?)(?<![\s*])\*(?![*\w])/g;
function stripSlackMarkup(t) {
  // 여는 *는 영숫자·별표 뒤에 오면 안 되고 바로 뒤에 공백이 와도 안 된다. 닫는 *는
  // 바로 앞에 공백이 없어야 하고 뒤에 영숫자가 붙어도 안 된다. 곱셈(2*3)과
  // 글롭(*.js, **/*)이 걸리지 않으면서 한국어 조사가 붙은 *팀 OKR*가 는 잡히는 조건.
  // 줄 안의 별표 개수가 홀수면 그 줄은 통째로 건드리지 않는다 — 짝이 안 맞는 줄에서
  // 정규식이 엉뚱한 두 별표를 짝지어 글자를 먹는 사고를 막는 가장 싼 방벽이다
  // (실측: 이 가드로 1258줄 중 6개 라인만 보수적으로 남고, *…* 잔존 231→29줄).
  return t
    .split('\n')
    .map((ln) => ((ln.match(/\*/g) || []).length % 2 ? ln : ln.replace(BOLD_RE, '$1')))
    .join('\n');
}

// ---- <url|표시텍스트> 처리 ---------------------------------------------------
// 예전 규칙은 무조건 "표시텍스트 (URL)"로 폈다. 슬랙은 긴 URL을 화면용으로
// app.notion.com/p/… 처럼 줄여 보내는데, 그러면 잘린 표시와 전체 URL이 나란히
// 붙어 같은 것을 두 번 적은 꼴이 된다 (코퍼스 267건, 그중 …로 잘린 것 72건 —
// 그 72건은 사람도 모델도 무슨 문서인지 알 수 없다).
// 표시텍스트가 URL의 축약형이면 URL만 남긴다. 그러면 messageUrls/collectRefs가
// 그 URL을 참조로 주워 media-extract의 링크 해석 경로로 넘어간다 — 제목·요지는
// 거기서 나오는 것이 맞다 (사설 호스트는 모듈이 skipped-private-host로 거른다).
function isUrlEcho(label, url) {
  const l = String(label || '').trim();
  if (!l) return true;
  if (/^(…|\.\.\.)|(…|\.\.\.)$/.test(l)) return true; // 잘린 표시
  const bare = l.replace(/[…]|\.\.\./g, '').replace(/^https?:\/\//, '').trim();
  if (!bare) return true;
  if (/\s/.test(bare)) return false; // 공백이 있으면 사람이 쓴 제목이다
  const u = url.replace(/^https?:\/\//, '');
  return u.startsWith(bare) || bare.startsWith(u) || u.includes(bare);
}

// Slack markup → readable text: <@U…> mentions, <#C…|name> channels,
// <url|label> links, :shortcode: 이모지, *굵게*, &amp;/&lt;/&gt; entities.
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
  t = t.replace(/<([^|>]+)\|([^>]+)>/g, (m, url, label) =>
    isUrlEcho(label, url) ? url : `${label} (${url})`);
  t = t.replace(/<([^>]+)>/g, '$1');
  t = t.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>');
  t = stripSlackMarkup(t);
  return renderEmoji(t);
}

// ------------------------------------------------- 첨부·인용 파싱 (멀티모달 입력)

// 슬랙 메시지의 "본문"은 msg.text 하나가 아니다. 이미지·PDF만 올린 메시지는 text가
// 비어 있고, 다른 메시지를 공유하거나 링크가 펼쳐지면 그 내용은 attachments에,
// 서식 있는 인용(>)은 blocks의 rich_text_quote에 들어온다. 데몬은 오랫동안 msg.text
// 하나만 봤고(이 파일에 files·url_private·mimetype 이라는 문자열이 아예 없었다) 그
// 결과 첨부만 있는 메시지는 버려졌고 공유된 인용문은 번역 대상에 들어가지도 않았다.
// 아래 함수들이 그 세 곳을 한 문자열로 모은다. 파일 내용을 실제로 여는 일(OCR·PDF·
// 프레임 추출)은 여기서 하지 않는다 — media-extract.mjs 소관이고 이 파일은 호출만 한다.

const FILE_LABEL = { image: '이미지', pdf: 'PDF', video: '영상', audio: '오디오', unknown: '파일' };

// mimetype/확장자로 대략의 종류만 정한다. 모듈이 있으면 evidence.type이 이기고,
// 이 값은 모듈이 없을 때 items에 남길 표시용으로만 쓰인다.
function refType(mime, name) {
  const m = String(mime || '').toLowerCase();
  const n = String(name || '').toLowerCase();
  if (m.startsWith('image/')) return 'image';
  if (m.startsWith('video/')) return 'video';
  if (m.startsWith('audio/')) return 'audio';
  if (m === 'application/pdf' || n.endsWith('.pdf')) return 'pdf';
  return 'unknown';
}

// 메시지 안의 링크. 모듈의 collectRefs와 목적이 겹치지만 이쪽은 "이 메시지를 버릴
// 것인가"를 정하는 수집 판정용이라 모듈이 없어도 반드시 동작해야 한다.
function messageUrls(msg) {
  const bag = [String(msg.text || '')];
  for (const a of msg.attachments || []) {
    bag.push(a.title_link || '', a.from_url || '', a.original_url || '', a.text || '', a.fallback || '');
  }
  const out = new Set();
  for (const s of bag) {
    for (const u of String(s).match(/https?:\/\/[^\s<>|"']+/g) || []) out.add(u.replace(/[>|,.)\]]+$/, ''));
  }
  return [...out];
}

// 모듈이 없을 때 쓰는 최소 참조 수집 — 계약(collectRefs)과 같은 모양을 만든다.
// {kind:'file', url, mimetype, name, size} / {kind:'link', url}.
function localRefs(msg) {
  const refs = [];
  for (const f of msg.files || []) {
    refs.push({
      kind: 'file',
      url: f.url_private || f.permalink || '',
      mimetype: f.mimetype || '',
      name: f.name || f.title || '',
      size: f.size || 0,
    });
  }
  for (const u of messageUrls(msg)) refs.push({ kind: 'link', url: u });
  return refs;
}

// 본문이 비어도 버리면 안 되는 메시지인가 — 파일·공유/펼침·서식 블록·링크가 하나라도
// 있으면 그것이 곧 메시지다. 셋 다 없을 때만 예전처럼 버린다.
function hasAttachmentOrLink(msg) {
  if ((msg.files || []).length) return true;
  if ((msg.attachments || []).length) return true;
  if (blockExtras(msg).length) return true;
  return messageUrls(msg).length > 0;
}

// 중복 제거용 싱크. blocks는 msg.text를 그대로 다시 담고 있는 경우가 많고(rich_text)
// attachments의 fallback은 title+text의 중복인 경우가 많다 — 그대로 이어 붙이면
// 같은 문장이 세 번 들어간 프롬프트가 된다.
function extraSink(body) {
  const out = [];
  return {
    out,
    push(label, s) {
      const t = String(s || '').trim();
      if (!t) return;
      if (body.includes(t)) return;
      if (out.some((o) => o.text === t || o.text.includes(t))) return;
      out.push({ label, text: t });
    },
  };
}

// rich_text 계열 elements 트리를 한 문자열로 편다 (text 조각과 링크 URL만).
function richTextOf(node) {
  if (!node) return '';
  if (Array.isArray(node)) return node.map(richTextOf).join('');
  if (typeof node !== 'object') return '';
  if (typeof node.text === 'string') return node.text;
  if (typeof node.url === 'string' && !node.elements) return node.url;
  return richTextOf(node.elements);
}

// blocks에서 본문에 없는 조각만 꺼낸다 — 인용 블록, 봇 카드 본문, 이미지 블록 캡션.
function blockExtras(msg) {
  const sink = extraSink(String(msg.text || ''));
  const walk = (n, d) => {
    if (!n || d > 8) return;
    if (Array.isArray(n)) {
      for (const x of n) walk(x, d + 1);
      return;
    }
    if (typeof n !== 'object') return;
    if (n.type === 'rich_text_quote') sink.push('인용', richTextOf(n.elements));
    else if (n.type === 'section') sink.push('첨부', n.text?.text || richTextOf(n.fields));
    else if (n.type === 'header') sink.push('첨부', n.text?.text);
    else if (n.type === 'context') sink.push('첨부', (n.elements || []).map((e) => e?.text || '').join(' '));
    else if (n.type === 'image') sink.push('이미지', n.title?.text || n.alt_text);
    walk(n.elements, d + 1);
  };
  walk(msg.blocks || [], 0);
  return sink.out;
}

// attachments = 메시지 공유(is_msg_unfurl)·링크 펼침(og:title/description)·봇 카드.
// 어느 쪽이든 사람이 읽는 문장이라 번역 대상인데 지금까지 통째로 빠져 있었다
// ("인용 블록이 번역되지 않는다"는 지적의 실제 원인).
function attachmentExtras(msg) {
  const sink = extraSink(String(msg.text || ''));
  for (const a of msg.attachments || []) {
    const quoted = !!(a.is_msg_unfurl || a.author_id || a.message_blocks);
    const label = quoted ? '인용' : '첨부';
    const head = [a.author_name || a.author_subname, a.title || a.service_name].filter(Boolean).join(' · ');
    if (head) sink.push(label, head);
    if (a.pretext) sink.push(label, a.pretext);
    if (a.text) sink.push(label, a.text);
    else if (a.fallback) sink.push(label, a.fallback);
    for (const f of a.fields || []) sink.push(label, [f?.title, f?.value].filter(Boolean).join(': '));
    // 공유된 원본 메시지의 블록 — a.text가 잘려 오는 경우가 있어 여기까지 본다.
    for (const mb of a.message_blocks || []) sink.push('인용', richTextOf(mb?.message?.blocks));
  }
  return sink.out;
}

// 번역·분석에 들어가는 "원문" 한 덩어리 = 본문 + blocks 인용 + attachments 공유/펼침
// + 파일 목록. 파일은 이름만이라도 남겨야 첨부뿐인 메시지가 대시보드에서 빈 줄로
// 보이지 않는다 (파일 내용에서 뽑은 근거는 media 필드와 프롬프트의 <attachments>로 간다).
const EXTRA_MAX = 1200; // 조각 하나가 프롬프트를 통째로 밀어내지 않게
async function composeSource(msg) {
  const parts = [];
  const body = (await cleanText(msg.text)).trim();
  if (body) parts.push(body);
  for (const e of [...blockExtras(msg), ...attachmentExtras(msg)]) {
    let t = (await cleanText(e.text)).trim();
    if (!t) continue;
    if (t.length > EXTRA_MAX) t = t.slice(0, EXTRA_MAX) + '…';
    parts.push(`[${e.label}] ${t}`);
  }
  for (const f of msg.files || []) {
    const name = f.name || f.title || '(이름 없음)';
    parts.push(`[${FILE_LABEL[refType(f.mimetype, name)]}] ${name}${f.mimetype ? ` (${f.mimetype})` : ''}`);
  }
  return parts.join('\n');
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

// evidence = media-extract가 첨부에서 뽑아낸 근거 배열(없으면 빈 배열 = 예전과 동일).
// 첨부 근거는 <message>가 아니라 <attachments>로 따로 넣는다 — 1단계 번역문은
// 대시보드에서 원문(textEn)과 나란히 놓이므로, 원문에 없던 문장이 번역문에 끼면
// 두 칸이 어긋나 보인다. 첨부 내용은 2·3단계(의미·의사결정)의 재료로만 쓴다.
// extraRules = 재시도할 때만 붙는 교정 지시 (무엇을 어겼는지 모델에게 직접 말한다).
function translatePrompt(text, ctx, lang, evidence = [], extraRules = []) {
  const name = LANGS[lang] || LANGS.ko;
  const ev = evidenceLines(evidence);
  const hasInline = inlineParts(evidence).length > 0;
  return [
    `다음 슬랙 메시지를 세 단계로 처리하라. 목표 언어: ${name}.`,
    '',
    '[1단계 — 번역]',
    `- 목표는 하나다. 출력의 모든 문장이 ${name}여야 한다.`,
    '- 메시지 전체를 한 언어로 뭉뚱그려 판정하지 마라. 슬랙 메시지는 한 덩어리 안에',
    '  여러 언어가 섞인다 — 영어로 쓴 본문 아래 한국어 인용이 붙거나, 한국어 보고',
    '  아래 같은 내용의 영어판이 붙는다. 판정은 문단(빈 줄로 나뉜 덩어리) 단위로 한다.',
    `- 문단마다 따로 본다. 그 문단이 ${name}가 아니면 ${name}로 번역하고, 이미 ${name}면`,
    '  손대지 말고 그대로 옮겨 적는다. 한 메시지 안에서 어떤 문단은 번역되고 어떤',
    '  문단은 그대로인 결과가 정상이다.',
    `- 메시지의 다른 부분이 이미 ${name}라는 것은, ${name}가 아닌 문단을 건너뛸 이유가`,
    '  전혀 되지 않는다. 이것이 지금까지 가장 자주 어긴 규칙이다.',
    '- 언어 판정에서 다음은 반드시 제외한다: 사람 이름과 괄호 안 표기, @멘션, 채널명,',
    '  이모지 코드(:saluting_face: 등), URL, 코드 블록, 제품명·회사명·티커 같은 고유명사.',
    '  이런 요소에 다른 언어 글자가 섞여 있어도 판정에 반영하지 마라.',
    '- 판정은 서술 문장(주어와 동사가 있는 실제 문장)만 보고 한다.',
    '- 판정이 애매하면 번역하는 쪽을 택하라.',
    '- URL, 고유명사(제품명·티커 등)는 번역하지 말고 유지.',
    '- ```로 둘러싼 코드 블록과 `인라인 코드`는 번역하지 말고 한 글자도 바꾸지 말고',
    '  그대로 옮겨 적어라. 안의 주석도 번역하지 마라 — 실행되는 코드라 번역하면 깨진다.',
    '- ">"로 시작하는 인용 줄, [인용]·[첨부]·[이미지]·[파일] 표시가 붙은 줄도 모두',
    '  번역 대상이다. 인용이거나 남이 쓴 말이라는 이유로 건너뛰지 마라.',
    '- 그 표시(">", "[인용]" 등)와 줄 구조는 그대로 두고 안의 문장만 목표 언어로 바꾼다.',
    '- 번역 결과에 언어 판정 과정이나 근거를 적지 마라. 결과 문장만 출력한다.',
    '- 이모지 문자(🎉 🙌 등)는 그대로 두고 번역하지 마라. ":이름:" 형태로 남아 있는',
    '  것은 이 워크스페이스의 커스텀 이모지다 — 그것도 그대로 옮겨 적는다.',
    `- 어떤 줄이 원문과 글자 그대로 같아도 되는 경우는 오직 그 줄이 이미 ${name}일 때뿐이다.`,
    '  영어 문장이 하나라도 원문 그대로 출력에 남아 있으면 그것은 실패다.',
    '- 1단계는 번역이지 요약이 아니다. 원문의 모든 줄을 빠짐없이 옮겨라 —',
    '  출력이 원문보다 짧아지면 안 된다. 줄 수와 순서도 원문을 따른다.',
    '- "번역이 필요 없습니다", "원문을 그대로 출력합니다" 같은 설명 문장은 절대 쓰지 마라.',
    '  그렇게 판단했으면 그 말 대신 원문 자체를 출력하라. 판단을 적는 것은 번역이 아니다.',
    '',
    '[2단계 — 의미 분석]',
    '- 줄바꿈 후 정확히 ===MEANING=== 한 줄을 출력.',
    '- <context>(같은 스레드/채널의 최근 대화)를 참고해, 이 메시지가 무슨 일에',
    `  대한 이야기이고 실제로 무엇을 말하려는/요구하는 것인지 ${name}로 1~3문장 설명.`,
    '- 표면 번역만으로 알기 어려운 함의·톤(급함, 불만, 단순 공유 등)이 있으면 짚어라.',
    '- 컨텍스트가 부족해 의미를 확정할 수 없으면 첫 줄을 "컨텍스트 부족:"으로',
    '  시작하고, 무엇을 확인해야 의미가 확정되는지(어떤 스레드·문서·사람) 적어라.',
    ...(ev.length
      ? [
          '- <attachments>는 이 메시지에 붙은 이미지·PDF·영상·링크에서 뽑아낸 내용이다.',
          '  1단계 번역문에는 넣지 말고, 의미와 의사결정의 근거로 삼아라.',
          `  첨부 안에 수신자가 꼭 읽어야 할 문장이 있으면 ${name}로 옮겨 요약해 주어라.`,
          '  첨부에 "추출 실패"만 있으면 그 사실을 근거 부족으로 취급하라.',
        ]
      : []),
    ...(hasInline
      ? ['- 첨부 이미지가 이 요청에 함께 실려 있다. 직접 보고 판단하라 (텍스트 추출본보다 우선).']
      : []),
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
    ...(extraRules.length ? ['', '[직전 시도의 오류 — 이번에는 반드시 고칠 것]', ...extraRules] : []),
    '',
    '<context>',
    ctx || '(수집된 컨텍스트 없음)',
    '</context>',
    ...(ev.length ? ['', '<attachments>', ...ev, '</attachments>'] : []),
    '',
    '<message>',
    text,
    '</message>',
  ].join('\n');
}

// 마커를 관대하게 찾는다. 정확히 ===MEANING===을 요구하면 모델이 **MEANING**,
// === MEANING ===, ==MEANING== 처럼 조금만 다르게 써도 못 찾고, 그러면 응답 전체가
// 번역으로 들어가 의미·의사결정이 통째로 비어 버린다 (전수 조사: error 없는
// 1235건 중 84건이 이 결손). 그래서 (1) 정확 일치를 먼저 보고 (2) 없으면 줄 단위로
// 장식 문자를 걷어낸 뒤 이름만 비교한다.
// 줄 전체가 마커일 때만 인정한다 — 본문 안에 "MEANING"이라는 단어가 나왔다고
// 거기서 자르면 번역문이 잘려 나간다.
// 마커로 인정할 이름들. "결정"이나 "2단계"처럼 본문에 홀로 나올 수 있는 낱말은
// 넣지 않는다 — 마커로 오인하면 그 뒤 번역문이 통째로 잘려 나간다.
const MARKER_WORDS = {
  meaning: ['MEANING', '의미', '의미분석', '2단계의미분석', '의미분석2단계'],
  decision: ['DECISION', '의사결정', '의사결정선택지', '3단계의사결정', '3단계의사결정선택지'],
};

function findMarker(text, kind) {
  const exact = text.indexOf(`===${kind.toUpperCase()}===`);
  if (exact >= 0) return { start: exact, end: exact + kind.length + 6 };
  const words = MARKER_WORDS[kind];
  const lines = text.split('\n');
  let pos = 0;
  for (const ln of lines) {
    // 장식(=, *, #, -, _, >, 공백, 콜론)을 걷어낸 알맹이가 마커 이름과 같은가.
    const bare = ln.replace(/[=*#_\-—–·\s:>[\]()]/g, '').toUpperCase();
    if (bare && words.includes(bare)) return { start: pos, end: pos + ln.length + 1 };
    pos += ln.length + 1;
  }
  return null;
}

// Split one LLM response into {ko, meaning, decision}. 마커가 아예 없으면 예전처럼
// 전체를 번역으로 본다 (옛 모델 출력·잘린 응답 호환).
function splitSections(out) {
  if (!out) return { ko: null, meaning: '', decision: '' };
  let rest = out;
  let meaning = '';
  let decision = '';
  const d = findMarker(rest, 'decision');
  if (d) {
    decision = rest.slice(d.end).trim();
    rest = rest.slice(0, d.start);
  }
  const m = findMarker(rest, 'meaning');
  if (m) {
    meaning = rest.slice(m.end).trim();
    rest = rest.slice(0, m.start);
  }
  return { ko: rest.trim(), meaning, decision };
}

// 메시지 하나를 좌표로 가져온다. conversations.history는 스레드 답글을 안 돌려주므로
// 못 찾으면 conversations.replies로 한 번 더 본다 (ts 파라미터는 스레드 안의 어떤
// 메시지든 받는다). processMessage와 퍼머링크 인용이 같은 절차를 쓴다.
async function fetchMessage(channel, ts) {
  const hist = await slack('conversations.history', { channel, latest: ts, inclusive: 'true', limit: 1 })
    .catch(() => null);
  let msg = hist?.messages?.[0];
  if (msg && msg.ts === ts) return msg;
  const reps = await slack('conversations.replies', { channel, ts, limit: 1 }).catch(() => null);
  msg = reps?.messages?.find((m) => m.ts === ts);
  return msg || null;
}

// ---- 퍼머링크로 붙여넣은 인용 ------------------------------------------------
// 이 팀이 실제로 다른 메시지를 인용하는 주된 방법은 ">" 블록(11건)이 아니라
// 퍼머링크 붙여넣기다(42건, 약 4배). 링크만 있으면 원문이 없는 것과 같아서
// 모델이 "컨텍스트 부족"으로 답한다. 그래서 좌표를 풀어 원 메시지를 읽어 온다.
// 재귀는 하지 않는다 — 인용 안의 인용을 따라가면 대화 하나가 무한히 커진다.
const PERMALINK_RE = /https?:\/\/[a-z0-9.-]+\.slack\.com\/archives\/([A-Z0-9]+)\/p(\d{10})(\d{6})(\?[^\s)\]]*)?/gi;
const QUOTE_MAX = 3; // 한 메시지에서 따라갈 인용 상한
const QUOTE_TEXT_MAX = 700;

function permalinkRefs(text) {
  const out = [];
  const seenTs = new Set();
  for (const m of String(text || '').matchAll(PERMALINK_RE)) {
    const ts = `${m[2]}.${m[3]}`;
    const key = `${m[1]}:${ts}`;
    if (seenTs.has(key)) continue;
    seenTs.add(key);
    const threadTs = /thread_ts=([\d.]+)/.exec(m[4] || '')?.[1];
    out.push({ channel: m[1], ts, threadTs: threadTs || undefined });
    if (out.length >= QUOTE_MAX) break;
  }
  return out;
}

// 인용된 원 메시지를 "인용된 메시지 — #채널 작성자: 내용" 줄로 만든다.
// 슬랙으로 나가는 것은 읽기(conversations.*)뿐이다. 실패는 그 인용만 건너뛴다.
async function quotedContext(msg) {
  const refs = permalinkRefs(msg?.text || '');
  if (!refs.length) return [];
  const lines = [];
  for (const ref of refs) {
    try {
      const q = await fetchMessage(ref.channel, ref.ts);
      if (!q) continue;
      // depth 1 — 여기서 composeSource는 쓰되 그 안의 퍼머링크는 다시 따라가지 않는다.
      let body = (await composeSource(q)).replace(/\s*\n\s*/g, ' ').trim();
      if (!body) continue;
      if (body.length > QUOTE_TEXT_MAX) body = body.slice(0, QUOTE_TEXT_MAX) + '…';
      const who = await userName(q.user || q.bot_id);
      const where = await channelName(ref.channel);
      lines.push(`[인용된 메시지 · ${where}] ${who}: ${body}`);
    } catch (e) {
      log('퍼머링크 인용 수집 실패:', ref.channel, ref.ts, e.message);
    }
  }
  return lines;
}

// 2차 의미 분석용 컨텍스트 수집 — 대상 메시지가 스레드 안이면 그 스레드의
// 답글들을, 아니면 채널의 직전 메시지들을 모아 "작성자: 내용" 줄로 만든다.
// msg를 주면 본문에 붙여넣은 슬랙 퍼머링크의 원 메시지도 앞에 실린다.
// 실패해도 파이프라인은 계속 (컨텍스트 없이 번역·분석).
// 컨텍스트 안의 세 구간을 가르는 표식. 문자열로 두는 이유는 이 결과가 프롬프트에도
// 그대로 실리고 코드가 다시 잘라 보기도 하기 때문이다 — 두 벌로 두면 갈라진다.
const CTX_THREAD_MARK = '[Slack thread context — same topic]';
const CTX_CHANNEL_MARK = '[Slack recent channel context';
const CTX_AFTER_MARK = '[--- 이 메시지 이후 스레드에 올라온 말 ---]';

// 스레드 답글만 잘라낸다. 채널 최근 메시지는 스레드가 아니고 날짜가 넘어가면 화제가
// 통째로 바뀐다 — 그것을 근거로 삼은 것이 2026-08-31 첫 사고의 경로다 (설계 §5-2).
// 스레드가 아니면 빈 문자열이다. 없는 것을 빈 것으로 돌려주는 쪽이, 있는 것처럼
// 섞어 주는 쪽보다 뒤에서 고장 났을 때 원인을 찾기 쉽다.
function threadOnlyContext(ctx) {
  const s = String(ctx || '');
  const i = s.indexOf(CTX_THREAD_MARK);
  if (i < 0) return '';
  const body = s.slice(i + CTX_THREAD_MARK.length);
  const j = body.indexOf(CTX_CHANNEL_MARK);
  return (j < 0 ? body : body.slice(0, j)).replace(CTX_AFTER_MARK, '').trim();
}

// 그 메시지 뒤에 스레드에 올라온 말만.
function threadAfterContext(ctx) {
  const s = String(ctx || '');
  const i = s.indexOf(CTX_AFTER_MARK);
  return i < 0 ? '' : s.slice(i + CTX_AFTER_MARK.length).trim();
}

async function gatherContext(channel, ts, threadTs, msg = null) {
  const lines = [];
  if (msg) {
    try {
      lines.push(...(await quotedContext(msg)));
    } catch (e) {
      log('quotedContext 실패:', e.message);
    }
  }
  try {
    let msgs;
    if (threadTs && threadTs !== ts) {
      lines.push(CTX_THREAD_MARK);
      const res = await slack('conversations.replies', { channel, ts: threadTs, limit: 30 });
      msgs = (res.messages || []).filter((m) => m.ts !== ts).slice(-12);
    } else {
      // 채널 최근 대화는 날짜가 넘어가거나 화제가 섞이면 원래 문제 정의의 근거가
      // 아니다. 모델이 스레드로 오인하지 않게 출처의 한계를 명시한다.
      lines.push(`${CTX_CHANNEL_MARK} — may contain mixed topics; not a thread]`);
      const res = await slack('conversations.history', { channel, latest: ts, limit: 8 });
      msgs = (res.messages || []).filter((m) => m.ts !== ts).reverse();
    }
    let afterMarked = false;
    for (const m of msgs) {
      // 본문이 빈 첨부·인용 메시지도 컨텍스트다. msg.text만 보면 스레드에서
      // 이미지·공유 메시지가 통째로 빠져 "컨텍스트 부족" 판정만 늘어난다.
      const body = (await composeSource(m)).replace(/\s*\n\s*/g, ' ').trim();
      if (!body) continue;
      // 이 메시지 뒤에 스레드에 올라온 말은 따로 표시한다. 신규성 게이트가 가장 먼저
      // 보는 것이 여기다 — 물음이 던져진 뒤 사람이 이미 답을 했는데 우리가 그 답을
      // 되풀이한 것이 2026-08-31 Maryam 건이다. 표시가 없으면 그 구간을 코드가
      // 따로 볼 방법이 없고, 스레드가 길수록 재진술이 희석돼 게이트가 무뎌진다.
      if (!afterMarked && Number(m.ts) > Number(ts)) {
        lines.push(CTX_AFTER_MARK);
        afterMarked = true;
      }
      const line = `${await userName(m.user || m.bot_id)}: ${body}`;
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
    return normalizeModel(JSON.parse(readFileSync(CONFIG_FILE, 'utf8')).model);
  } catch {}
  // Default = 1초 번역 (Gemini Flash-Lite, 무료 키) — user request 2026-07-23.
  // Key missing → translate() falls back to CLI Haiku silently.
  return 'gemini-flash-lite';
}

// 구버전은 API 모델 id 자체를 config에 저장하기도 했다. 선택 UI의 안정된 제품 id로
// 올려 주고, 알 수 없는/빈 값은 제품 기본값으로 복구한다. 유효한 사용자 선택은 보존한다.
function normalizeModel(model) {
  const aliases = {
    'gemini-2.5-flash-lite': 'gemini-flash-lite',
    'gemini-flash-lite-latest': 'gemini-flash-lite',
    'gemini-2.5-flash': 'gemini-flash',
    'gemini-flash-latest': 'gemini-flash',
  };
  const m = aliases[String(model || '')] || String(model || '');
  return m === 'auto' || m === 'haiku' || m === 'haiku-api' || GEMINI_MODELS[m]
    ? m : 'gemini-flash-lite';
}

// 키체인 조회는 한 번만. 번역과 첨부 추출 양쪽이 필요로 하므로 한 곳에 모았다.
// 값은 이 프로세스 안에만 있고 로그·파일·오류 메시지 어디에도 나가지 않는다
// (나갈 뻔한 문자열은 scrubSecrets가 한 번 더 지운다).
function ensureKeys() {
  if (geminiKey === undefined) geminiKey = keychain('cm-gemini-api-key');
  if (anthropicKey === undefined) anthropicKey = keychain('cm-anthropic-api-key');
}

// 첨부 추출에 쓸 Gemini 모델 — 사용자가 고른 모델을 따르되, 고른 것이 Gemini가
// 아니면(haiku·auto) 비전이 되는 기본값으로 간다. 모듈이 키가 없으면 추출을
// 스스로 건너뛰므로 여기서 키 유무를 따로 분기하지 않는다.
function extractModel() {
  return GEMINI_MODELS[currentModel()] || 'gemini-flash-latest';
}

// inline = [{mimeType, dataB64}] — 첨부 이미지/프레임을 모델에 그대로 보낸다.
// 텍스트 파트 하나뿐이던 구조에 파트를 더하는 것이라, 첨부가 없으면 요청 본문은
// 예전과 한 글자도 다르지 않다.
async function translateGemini(apiModel, prompt, inline = []) {
  const parts = [{ text: prompt }];
  for (const p of inline) parts.push({ inlineData: { mimeType: p.mimeType, data: p.dataB64 } });
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${apiModel}:generateContent`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': geminiKey },
      body: JSON.stringify({
        contents: [{ parts }],
        generationConfig: { temperature: 0.2 },
      }),
      signal: AbortSignal.timeout(20_000),
    },
  );
  if (!res.ok) throw new Error(`gemini ${apiModel}: HTTP ${res.status}`);
  const json = await res.json();
  const u = json.usageMetadata || {};
  act('model.usage', { id: '', detail: apiModel, input_tokens: Number(u.promptTokenCount || 0),
    output_tokens: Number(u.candidatesTokenCount || 0), total_tokens: Number(u.totalTokenCount || 0),
    model: apiModel });
  const out = (json.candidates?.[0]?.content?.parts || []).map((p) => p.text || '').join('').trim();
  if (!out) throw new Error(`gemini ${apiModel}: empty response`);
  return out;
}

// Anthropic Messages API direct (billed separately from the Claude subscription
// — usage-based via Console API key). Same Haiku model as the CLI path but no
// process-startup cost: ~1-2s instead of 5-15s.
// Anthropic Messages API가 인라인으로 받는 것은 image 블록(base64)뿐이다. 그 밖의
// mimetype(PDF 원본·영상 프레임 컨테이너 등)은 여기서 버리고 추출 텍스트만 쓴다 —
// 지원하지 않는 블록을 하나라도 실으면 요청 전체가 400으로 떨어져 번역이 0건이 된다.
const ANTHROPIC_IMAGE = /^image\/(jpeg|png|gif|webp)$/;

async function translateAnthropicAPI(prompt, inline = []) {
  const blocks = [];
  for (const p of inline) {
    if (!ANTHROPIC_IMAGE.test(String(p.mimeType || '').toLowerCase())) continue;
    blocks.push({ type: 'image', source: { type: 'base64', media_type: p.mimeType, data: p.dataB64 } });
  }
  // 이미지가 없으면 content는 예전 그대로 문자열 하나 (요청 모양 무변경).
  const content = blocks.length ? [...blocks, { type: 'text', text: prompt }] : prompt;
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
      messages: [{ role: 'user', content }],
    }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`anthropic api: HTTP ${res.status}`);
  const json = await res.json();
  const u = json.usage || {};
  act('model.usage', { id: '', detail: 'claude-haiku-4-5', input_tokens: Number(u.input_tokens || 0),
    output_tokens: Number(u.output_tokens || 0),
    total_tokens: Number(u.input_tokens || 0) + Number(u.output_tokens || 0), model: 'claude-haiku-4-5' });
  const out = (json.content || [])
    .filter((b) => b.type === 'text')
    .map((b) => b.text)
    .join('')
    .trim();
  if (!out) throw new Error('anthropic api: empty response');
  return out;
}

// Claude CLI 경로는 프롬프트가 argv 문자열 하나라 인라인 첨부를 실을 길이 없다.
// 첨부는 추출 텍스트(프롬프트의 <attachments>)로만 반영된다 — 비전을 못 쓰는
// 백엔드를 골라도 기능이 깨지지 않고 근거만 덜 풍부해지는 지점이다.
function translateClaude(prompt) {
  return new Promise((resolve) => {
    execFile(
      'claude',
      ['--model', 'claude-haiku-4-5-20251001', '--output-format', 'json', '-p', prompt],
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
        } else {
          try {
            const envelope = JSON.parse(stdout);
            const u = envelope.usage || {};
            const input = Number(u.input_tokens || 0) + Number(u.cache_creation_input_tokens || 0)
              + Number(u.cache_read_input_tokens || 0);
            const output = Number(u.output_tokens || 0);
            act('model.usage', { id: '', detail: 'claude-haiku-4-5-20251001', input_tokens: input,
              output_tokens: output, total_tokens: input + output, model: 'claude-haiku-4-5-20251001' });
            resolve(String(envelope.result || '').trim() || null);
          } catch (e) {
            log('translate fail (claude envelope):', e.message);
            resolve(null);
          }
        }
      },
    );
  });
}

// Returns {ko, meaning, decision, model, lang} — ko null when every route
// failed. A selected Gemini model that errors (bad key, quota, network) silently
// falls back to Claude so items never stall on a misconfigured model
// (no-user-facing-failure). ctx = gatherContext() 결과 (의미 분석 재료).
// 인라인 첨부가 붙은 요청이 거절되면(모델이 비전을 지원하지 않거나 본문이 너무 큼)
// 같은 프롬프트를 텍스트만으로 한 번 더 보낸다. 모델 선택은 사용자의 것이고, 그
// 선택이 비전 미지원이라는 이유로 번역 자체가 실패해서는 안 된다.
async function withInlineFallback(call, inline, label) {
  if (!inline.length) return call([]);
  try {
    return await call(inline);
  } catch (e) {
    log(`${label}: 인라인 첨부 ${inline.length}건 거절됨 (${e.message}) — 추출 텍스트만으로 재시도`);
    return call([]);
  }
}

// 프롬프트 하나를 선택된 백엔드로 보낸다. 실패하면 예전과 같은 순서로 내려간다
// (Gemini/Anthropic → Claude CLI). 반환 {out, model}.
async function callModel(prompt, inline) {
  ensureKeys();
  let choice = currentModel();
  if (choice === 'auto') {
    choice = geminiKey ? 'gemini-flash-lite' : anthropicKey ? 'haiku-api' : 'haiku';
  }
  if (GEMINI_MODELS[choice] && geminiKey) {
    try {
      const out = await withInlineFallback(
        (parts) => translateGemini(GEMINI_MODELS[choice], prompt, parts), inline, choice);
      return { out, model: choice };
    } catch (e) {
      log(`translate fail (${choice}): ${e.message} — falling back to claude CLI`);
    }
  } else if (choice === 'haiku-api' && anthropicKey) {
    try {
      const out = await withInlineFallback(
        (parts) => translateAnthropicAPI(prompt, parts), inline, 'haiku-api');
      return { out, model: 'haiku-api' };
    } catch (e) {
      log(`translate fail (haiku-api): ${e.message} — falling back to claude CLI`);
    }
  } else if (choice !== 'haiku') {
    log(`model ${choice} selected but its keychain key is missing — using claude CLI`);
  }
  return { out: await translateClaude(prompt), model: 'haiku' };
}

// 멘션·DM처럼 답을 기대하는 메시지에는 본 처리가 끝나기 전에 짧은 선응답을 보낸다.
// 목적→한 단어 의도→한 줄 해석→두 선택지와 현재 추천 순서로, 상대가 "읽고 있는지"와
// "어떻게 이해했는지"를 즉시 검증할 수 있게 한다. 👀/Later는 개인 수집 동작이라 답하지 않는다.
//
// 어떤 소스에 대해 이것이 도는지는 코드가 아니라 slack-ack-cost-policy.json 의
// ackSources 가 정한다. 2026-09-02 까지는 ['mention','team','dm','broadcast'] 가
// 여기 박혀 있었고, 리액션이 봇이 아니라 라이언 계정(xoxp)으로 나가는 구조라
// 그가 불리지도 않은 그룹 DM 38개 방과 랜덤 채널의 남의 대화에 그의 이름으로 🔍 가
// 찍혔다 — 실측으로 리액션 195건 중 78건(40%), 🔍 로 바뀐 첫날의 30건 중 20건(67%).
// 목록을 JSON 으로 옮긴 것은 이 저장소가 이미 "뜻의 정본은 코드가 아니라 JSON" 을
// 규칙으로 삼기 때문이고, 되돌리는 값이 JSON 한 줄이라 좁게 시작할 수 있기 때문이다.
// 수집(sourceOn)은 이 값과 무관하다 — dm·broadcast 는 계속 쌓이고 번역되어 대시보드에
// 뜬다. 달라지는 것은 슬랙에 흔적을 남기지 않는다는 것 하나다.
//
// 정책을 못 읽으면 ['mention'] 로 떨어진다. 바닥값을 넓은 쪽으로 두지 않은 이유는
// 하나다 — 정책 파일을 못 읽었다는 것이 "다 달아도 된다" 는 뜻이 아니고, 여기서
// 틀리면 그 값이 남의 스레드에 라이언의 이름으로 남는다. 빈 배열은 넓히지 않고
// 그대로 지킨다. 그것은 못 읽은 것이 아니라 아무 데도 달지 말라고 적은 것이다.
function ackSources() {
  const raw = ackCostPolicy().ackSources;
  if (!Array.isArray(raw)) return ['mention'];
  return raw.filter((s) => typeof s === 'string' && s);
}

function acknowledgementOn(source) {
  if (!ackSources().includes(source || '')) return false;
  try {
    const cfg = JSON.parse(readFileSync(CONFIG_FILE, 'utf8'));
    return cfg.acknowledgements !== false;
  } catch { return true; }
}

// 자동응답 정책은 채널 ID를 정본으로 삼는다. 표시 이름은 사람이 읽고 정책을
// 복구할 때 쓰는 보조키일 뿐이다. 별도 파일로 override할 수 있어 Notion에서
// 검증한 정책을 코드 변경 없이 반영할 수 있다.
function replyPolicies() {
  let bundled = {};
  let operational = {};
  try { bundled = JSON.parse(readFileSync(BUNDLED_REPLY_POLICY_FILE, 'utf8')); } catch {}
  try { operational = JSON.parse(readFileSync(CHANNEL_POLICY_FILE, 'utf8')); } catch {}
  return {
    channels: { ...(bundled.channels || {}), ...(operational.channels || {}) },
    people: { ...(bundled.people || {}), ...(operational.people || {}) },
  };
}

function channelReplyPolicy(channel, name = '') {
  const external = replyPolicies().channels;
  const normalized = String(name).replace(/^#/, '').toLowerCase();
  const row = external[channel] || Object.values(external).find((x) => String(x?.name || '').replace(/^#/, '').toLowerCase() === normalized)
    ;
  return row || { name: normalized, mode: 'reply', reason: '기본 응답 정책' };
}

function peopleReplyPolicy(userId) {
  const external = replyPolicies().people;
  return external[userId]
    || { mode: 'reply', reason: '기본 사람 응답 정책' };
}

function shouldAutoReply(item) {
  return acknowledgementOn(item?.source)
    && peopleReplyPolicy(item?.authorId).mode === 'reply'
    && channelReplyPolicy(item?.channel, item?.channelName).mode === 'reply';
}

const PROFILE_FIELD_IDS = {
  github: 'Xf070LFXU8MC', country: ['Xf07D4RZMGKB', 'Xf03UQGVEDMJ'], location: 'Xf0879S4LRDE',
};

function readPeopleRoster() {
  try { return JSON.parse(readFileSync(PEOPLE_ROSTER_FILE, 'utf8')); } catch { return { version: 1, people: {} }; }
}

// auth.test 결과를 self.json 으로 남긴다. 쓰기가 실패해도 데몬은 계속 돈다 —
// 이 파일은 오프라인 도구의 편의일 뿐이고, 없다고 수집·번역이 막히지는 않는다.
function writeSelf(auth) {
  try {
    mkdirSync(OUT_DIR, { recursive: true });
    const tmp = `${SELF_FILE}.tmp`;
    const rec = {
      userId: auth?.user_id || '',
      user: auth?.user || '',
      team: auth?.team || '',
      at: Math.floor(Date.now() / 1000),
    };
    writeFileSync(tmp, JSON.stringify(rec) + '\n');
    renameSync(tmp, SELF_FILE);
  } catch (e) { log('self.json write fail', e.message); }
}

function writePeopleRoster(roster) {
  try {
    mkdirSync(OUT_DIR, { recursive: true });
    const tmp = `${PEOPLE_ROSTER_FILE}.tmp`;
    writeFileSync(tmp, JSON.stringify(roster, null, 2) + '\n');
    renameSync(tmp, PEOPLE_ROSTER_FILE);
  } catch (e) { log('people roster write fail', e.message); }
}

// 명부 항목을 돌려준다 — 언어 문자열이 아니라 근거까지 붙은 레코드다. 어느 것을
// 우선할지는 reply-language.mjs 가 정하므로, 여기서는 "무엇을 알고 있는가"만 낸다.
async function rosterEntry(userId) {
  if (!userId) return null;
  const roster = readPeopleRoster();
  const cached = roster.people?.[userId];
  if (cached?.replyLanguage && Date.now() - Number(cached.checkedAt || 0) < 7 * 86400_000) return cached;
  try {
    const res = await slack('users.profile.get', { user: userId });
    const fields = res.profile?.fields || {};
    const github = String(fields[PROFILE_FIELD_IDS.github]?.value || '').trim();
    const country = PROFILE_FIELD_IDS.country.map((id) => fields[id]?.value).find(Boolean) || '';
    const location = String(fields[PROFILE_FIELD_IDS.location]?.value || '').trim();
    let githubLocation = '';
    if (!country && !location && github) {
      const handle = github.replace(/^https?:\/\/(www\.)?github\.com\//i, '').split(/[/?#]/)[0];
      if (handle) {
        const gh = await fetch(`https://api.github.com/users/${encodeURIComponent(handle)}`, {
          headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'condition-mate-slack-roster' },
          signal: AbortSignal.timeout(4_000),
        });
        if (gh.ok) githubLocation = String((await gh.json()).location || '');
      }
    }
    const replyLanguage = countryLanguage(country, location || githubLocation);
    const entry = { replyLanguage, country, location, github, githubLocation,
      evidence: country || location ? 'slack-profile' : githubLocation ? 'github-public-profile' : 'no-country-evidence-default-en',
      checkedAt: Date.now() };
    roster.people ||= {};
    roster.people[userId] = entry;
    writePeopleRoster(roster);
    return entry;
  } catch (e) {
    log('people roster lookup fail', userId, e.message);
    return cached || null;
  }
}

// 수신자 언어. 규칙은 reply-language.mjs 에 있고 여기서는 재료만 모은다 — 명부 항목,
// 원문, 그리고 스레드(채널 최근 메시지는 스레드가 아니므로 threadOnlyContext 로 거른다).
// 돌려주는 것은 {lang, basis} 이고 basis 는 원장에 남는다.
async function replyLanguage(text, authorId, ctx = '') {
  return decideReplyLanguage({
    rosterEntry: await rosterEntry(authorId),
    text,
    thread: threadOnlyContext(ctx),
  });
}

// 가장 먼저 적용되는 보안 레이어. 민감정보를 달라는 요청은 context/Jira/첨부/LLM
// 어느 쪽에도 넘기지 않는다. 규칙은 security-gate.mjs 한 곳에 있다 — 여기 있던 정규식
// 네 줄은 메시지 전체를 대상으로 서로 독립해서 매치해서, 3천 자 떨어진 두 낱말이 만나도
// 게이트가 섰다. 게이트가 서면 번역이 통째로 건너뛰어지므로 오탐 하나가 곧바로 "영어
// 본문이 번역되지 않았다"가 된다 (2026-09-02 라이언 지적). 전수 1675건에서 옛 규칙은
// 83건을 막고 그중 75건이 오탐이었다.
// 게이트가 걸리면 슬랙으로 아무것도 내보내지 않는다. 이 함수가 내는 문장은 대시보드
// 카드에만 쓰는 내부 사유이고, 수신자는 이것을 보지 않는다.
//
// 예전에는 여기서 만든 문장을 스레드에 그대로 올렸다. 그것이 2026-09-01 에 사고가 됐다.
// GlobalMPC X 계정 복구 스레드에 "checklist" 의 list 와 "token-sale" 의 token 이 함께
// 들어 있었다는 이유만으로 게이트가 서서, 자격증명을 달라고 한 적이 없는 사람에게
// "승인된 경로를 이용하라" 는 훈계가 나갔다. 오탐 하나가 곧바로 커뮤니케이션 코스트가
// 됐고, 스레드를 읽는 모든 사람이 그것을 해석하는 비용을 치렀다.
//
// 게이트의 값은 민감정보를 외부 분석 경로로 넘기지 않는 데 있지, 차단됐다고 알리는 데
// 있지 않다. 알림은 값을 만들지 않으면서 오탐일 때만 비용을 만든다. 그래서 침묵이 기본값이다.
function securityBlockedNote(gate) {
  const label = gate?.kind === 'compensation' ? '급여·보상 정보'
    : gate?.kind === 'credential' ? '자격증명·비밀 키'
      : '내부 보안 정보';
  return `보안 게이트: ${label} 요청으로 분류되어 외부 분석 경로를 시작하지 않았고, 슬랙에는 아무것도 보내지 않았습니다.`;
}

const LEVEL1_DESTINATIONS = {
  homepage: 'https://must.company/',
  helpMust: 'https://mustcompany.slack.com/archives/C08TNSWJHJ9',
  surviveAI: 'https://mustcompany.slack.com/archives/C093L3Y8UM6',
  companyNotion: 'https://www.notion.so/mustfintech/Company-Information-dd7eb788c1034ae29ef55bff1aa0bfe7?pvs=4',
};

// Level 1은 판단이나 분석이 필요 없는 고정 안내다. 목록에 정확히 맞는 경우만
// 라우팅하고, 조금이라도 해석이 필요한 질문은 Level 2로 보낸다.
function levelOneRoute(text) {
  const t = String(text || '');
  const asksWhere = /(어디|알려\s*주|링크|주소|홈페이지|채널|where|link|url|website|homepage|channel|how\s+do\s+i|how\s+can\s+i)/i.test(t);
  if (!asksWhere) return null;
  if (/(회사|must).{0,12}(홈페이지|웹사이트|website|homepage)|(홈페이지|웹사이트|website|homepage).{0,12}(회사|must)/i.test(t)) {
    return { key: 'homepage', url: LEVEL1_DESTINATIONS.homepage };
  }
  if (/(지출\s*결의|비용\s*(?:처리|승인|신청)|payment\s*request|expense\s*(?:request|approval|claim|reimbursement))/i.test(t)) {
    return { key: 'help-must', url: LEVEL1_DESTINATIONS.helpMust };
  }
  if (/(ai.{0,12}(성장|학습|공부|배우|grow|growth|learn)|(?:성장|학습|공부).{0,12}ai)/i.test(t)) {
    return { key: 'survive-ai', url: LEVEL1_DESTINATIONS.surviveAI };
  }
  if (/(notion|노션).{0,20}(회사|company|product|프로덕트)|(회사|company|product|프로덕트).{0,20}(notion|노션)/i.test(t)) {
    return { key: 'company-notion', url: LEVEL1_DESTINATIONS.companyNotion };
  }
  return null;
}

// 여기서 언어를 다시 판정하지 않는다 — 판정 규칙은 reply-language.mjs 한 곳에만 있다.
function routingReply(text, route, language) {
  const english = language !== 'ko';
  const labels = english
    ? { homepage: 'MUST Company website', 'help-must': '#help-must for expense/payment requests',
        'survive-ai': '#survive-ai for AI growth and learning', 'company-notion': 'the company Notion page' }
    : { homepage: 'MUST Company 홈페이지', 'help-must': '지출결의·결제 요청용 #help-must',
        'survive-ai': 'AI 성장·학습용 #survive-ai', 'company-notion': '회사 Notion 페이지' };
  return english ? `You can use ${labels[route.key]} here: ${route.url}`
    : `${labels[route.key]}는 여기입니다: ${route.url}`;
}

async function postLevelOneRoute(item, route) {
  if (!shouldAutoReply(item) || !item.authorId || item.authorId === MY_USER) return;
  const { lang, basis } = await replyLanguage(item.textEn, item.authorId);
  const body = routingReply(item.textEn, route, lang);
  const res = await slack('chat.postMessage', {
    channel: item.channel, thread_ts: item.threadTs || item.ts,
    text: `<@${item.authorId}> ${body}`,
  });
  rewriteItem(item.id, { ackTs: res.ts || Math.floor(Date.now() / 1000), ackAt: Math.floor(Date.now() / 1000),
    ackLang: lang, ackLangBasis: basis, ackBody: body });
  act('route.level1', { id: item.id, detail: `단순 라우팅 · ${route.key} · ${lang}` });
}

function jiraPlainText(node, out = [], depth = 0) {
  if (!node || depth > 12 || out.join('').length > 5000) return out;
  if (typeof node === 'string') { out.push(node); return out; }
  if (Array.isArray(node)) { for (const x of node) jiraPlainText(x, out, depth + 1); return out; }
  if (typeof node !== 'object') return out;
  if (typeof node.text === 'string') out.push(node.text);
  if (Array.isArray(node.content)) jiraPlainText(node.content, out, depth + 1);
  return out;
}

function jiraInstance() {
  try {
    const obj = JSON.parse(readFileSync(join(DATA_DIR, 'integrations.json'), 'utf8'));
    const row = (obj.instances || []).find((x) => x?.credId === 'jira-token' && x?.fields?.site && x?.fields?.email);
    if (!row) return null;
    const service = `cm-jira-token-${row.key}`;
    const token = keychain(service);
    if (!token) return { error: `Jira 연결 ${row.label || row.key}에 API 토큰이 없음` };
    return {
      site: String(row.fields.site).replace(/\/+$/, ''), email: String(row.fields.email),
      token, label: row.label || row.key,
    };
  } catch { return null; }
}

const JIRA_STOP = new Set(['this','that','with','from','have','will','your','about','into','what','when','where','which','그리고','대한','위한','있는','하는','합니다','내용','확인','관련']);

function jiraSearchTerms(text) {
  const cleaned = String(text || '')
    .replace(/https?:\/\/\S+/g, ' ').replace(/<[^>]+>/g, ' ').replace(/\([^)]*\)/g, ' ');
  const words = cleaned.match(/[A-Za-z][A-Za-z0-9_-]{3,}|[가-힣]{2,}/g) || [];
  return [...new Set(words.map((w) => w.toLowerCase()).filter((w) => !JIRA_STOP.has(w)))].slice(0, 3);
}

async function jiraProblemContext(text, ctx) {
  const inst = jiraInstance();
  if (!inst) return '[Jira lookup] unavailable — configured Jira instance not found';
  if (inst.error) return `[Jira lookup] unavailable — ${inst.error}`;
  const auth = Buffer.from(`${inst.email}:${inst.token}`).toString('base64');
  const headers = { Authorization: `Basic ${auth}`, Accept: 'application/json' };
  const explicit = [...new Set(`${text}\n${ctx}`.match(/\b[A-Z][A-Z0-9]{1,9}-\d+\b/g) || [])].slice(0, 3);
  try {
    let issues = [];
    if (explicit.length) {
      const rows = await Promise.all(explicit.map(async (key) => {
        const res = await fetch(`${inst.site}/rest/api/3/issue/${encodeURIComponent(key)}?fields=summary,description,status`,
          { headers, signal: AbortSignal.timeout(6_000) });
        return res.ok ? res.json() : null;
      }));
      issues = rows.filter(Boolean);
    } else {
      const terms = jiraSearchTerms(text);
      if (!terms.length) return `[Jira lookup · ${inst.label}] no searchable terms in message`;
      const jql = terms.map((w) => `text ~ "${w.replace(/["\\]/g, '')}"`).join(' AND ');
      const u = new URL(`${inst.site}/rest/api/3/search/jql`);
      u.searchParams.set('jql', `(${jql}) ORDER BY updated DESC`);
      u.searchParams.set('maxResults', '3');
      u.searchParams.set('fields', 'summary,description,status');
      const res = await fetch(u, { headers, signal: AbortSignal.timeout(7_000) });
      if (!res.ok) return `[Jira lookup · ${inst.label}] search failed (HTTP ${res.status})`;
      issues = (await res.json()).issues || [];
    }
    if (!issues.length) return `[Jira lookup · ${inst.label}] no matching issue content`;
    const rows = issues.map((x) => {
      const desc = jiraPlainText(x?.fields?.description).join(' ').replace(/\s+/g, ' ').trim().slice(0, 900);
      return `${x.key}: ${x?.fields?.summary || '(no summary)'}${desc ? ` — ${desc}` : ' — description is empty'}`;
    });
    return `[Jira lookup · ${inst.label}]\n${rows.join('\n')}`;
  } catch (e) {
    return `[Jira lookup · ${inst.label}] unavailable — ${String(e?.name === 'TimeoutError' ? 'timeout' : e?.message || e).slice(0, 120)}`;
  }
}

// Notion 통합 토큰 — Jira와 같은 인스턴스 규칙(integrations.json 의 행 + 키체인
// cm-notion-token-<key>). 키체인을 여는 것은 이 데몬뿐이고, 모듈에는 값만 넘긴다.
function notionInstance() {
  try {
    const obj = JSON.parse(readFileSync(join(DATA_DIR, 'integrations.json'), 'utf8'));
    const row = (obj.instances || []).find((x) => x?.credId === 'notion-token');
    if (!row) return null;
    const token = row.keychainService
      ? keychain(row.keychainService, row.keychainAccount || '')
      : ((row.key ? keychain(`cm-notion-token-${row.key}`) : null) || keychain('cm-notion-token'));
    return token ? { token, label: row.label || row.key || 'notion' } : { error: '노션 통합 토큰이 키체인에 없음' };
  } catch { return null; }
}

// ---- 선응답 컨텍스트 레이어 모듈 (answer-context.mjs) ------------------------
// media-extract 와 같은 규칙: 별도 파일이고, 없으면 선응답은 예전대로(스레드+Jira)
// 계속 나간다. 정적 import 하나 때문에 데몬 전체가 안 뜨는 일을 만들지 않는다.
let ansMod = null;
let ansModAt = 0;

async function answerContextModule() {
  if (ansMod) return ansMod;
  if (Date.now() - ansModAt < 60_000) return null;
  ansModAt = Date.now();
  try {
    const m = await import('./answer-context.mjs');
    if (typeof m.resolveAccess !== 'function' || typeof m.notionContext !== 'function') {
      throw new Error('resolveAccess/notionContext를 내보내지 않음');
    }
    ansMod = m;
    log('answer-context 로드됨 — 문서·리서치·다른 스레드 레이어 활성');
  } catch (e) {
    ansMod = null;
    log('answer-context 없음 — 선응답은 스레드+Jira만 사용:', String(e?.message || e).split('\n')[0]);
  }
  return ansMod;
}

// ---- 용어집 동기화 (노션이 정본) -------------------------------------------
// 사람은 노션 프로덕트 페이지에 이름 대응을 쓰고, 데몬이 30분마다 내려받아
// glossary.json 에 캐시한다. 레포의 번들 JSON 은 토큰이 없을 때의 씨앗일 뿐이다.
// 페이지 주소는 config.json 의 glossaryPage 로 바꿀 수 있다 (대시보드가 쓰는 파일 —
// 페이지를 옮겼다고 앱을 다시 빌드하게 만들지 않는다).
function glossaryPage() {
  try {
    const c = JSON.parse(readFileSync(CONFIG_FILE, 'utf8')).glossaryPage;
    if (c && String(c).trim()) return String(c).trim();
  } catch {}
  try {
    const b = JSON.parse(readFileSync(BUNDLED_GLOSSARY_FILE, 'utf8')).notionPage;
    if (b && String(b).trim()) return String(b).trim();
  } catch {}
  return '';
}

async function glossarySync() {
  const mod = await answerContextModule();
  if (!mod || typeof mod.syncGlossaryFromNotion !== 'function') return;
  const page = glossaryPage();
  if (!page) return; // 아직 노션 페이지를 만들지 않았다 — 번들 씨앗으로 계속 돈다
  const inst = notionInstance();
  const r = await mod.syncGlossaryFromNotion({
    token: inst?.token || null, page, outFile: GLOSSARY_FILE,
  }).catch((e) => ({ ok: false, error: String(e?.message || e).slice(0, 80) }));
  if (r.ok && r.changed) {
    log(`용어집 동기화 — 노션에서 ${r.count}건 내려받음`);
    act('glossary.sync', { detail: `노션에서 ${r.count}건 갱신` });
  } else if (!r.ok) {
    // 실패해도 기존 캐시로 계속 돈다. 다만 왜 안 내려왔는지는 남긴다.
    log('용어집 동기화 실패:', r.error);
    act('glossary.sync', { ok: false, error: r.error });
  }
}

// ---- 축 0 — 사람 조회 (people-context.mjs) ----------------------------------
// answer-context · emoji-layer 와 같은 규칙: 별도 파일, 동적 import, 없으면 축 0 은
// 통째로 꺼지고 나머지는 예전 그대로 돈다.
let peopleMod = null;
let peopleModAt = 0;

async function peopleContextModule() {
  if (peopleMod) return peopleMod;
  if (Date.now() - peopleModAt < 60_000) return null;
  peopleModAt = Date.now();
  try {
    const m = await import('./people-context.mjs');
    if (typeof m.peopleContext !== 'function' || typeof m.renderContextMessage !== 'function') {
      throw new Error('peopleContext/renderContextMessage를 내보내지 않음');
    }
    peopleMod = m;
    log('people-context 로드됨 — 축 0(사람 조회)이 축 1보다 먼저 나간다');
  } catch (e) {
    peopleMod = null;
    log('people-context 없음 — 축 0 없이 예전대로 답한다:', String(e?.message || e).split('\n')[0]);
  }
  return peopleMod;
}

// 노션 HR DB 는 아직 정해진 데이터베이스가 없다. id 를 코드에 박지 않는다 — 박으면
// 그것이 정본이 되고, 틀린 DB 를 조회한 결과가 사람 이력으로 나간다. 비어 있으면
// 축 0 의 조회처에 "노션 HR DB 미설정" 이 그대로 나가는 것이 맞다.
function hrDatabaseId() {
  try {
    const c = JSON.parse(readFileSync(CONFIG_FILE, 'utf8')).hrDatabaseId;
    if (c && String(c).trim()) return String(c).trim();
  } catch {}
  return null;
}

// 디렉터리 갱신은 선응답 경로 밖에서만 한다. users.list 는 4페이지·3993명이고 전체
// 조회에 6초 걸린다(2026-08-31 실측). 선응답 안에서 부르면 20초 예산의 3분의 1을
// 사람 목록 내려받는 데 쓰게 된다. 그래서 glossarySync 와 같은 30분 주기에 얹되,
// 실제 조회는 TTL 6시간이 지났을 때만 한다.
const PEOPLE_DIR_TTL_MS = 6 * 60 * 60_000;
let peopleDirError = '';

async function peopleDirectorySync() {
  const mod = await peopleContextModule();
  if (!mod) return;
  const cache = mod.directoryCache({ dir: OUT_DIR });
  if (cache && Date.now() - Number(cache.fetchedAt || 0) < PEOPLE_DIR_TTL_MS) return;
  const r = await mod.refreshDirectory({ slack, dir: OUT_DIR, log })
    .catch((e) => ({ ok: false, error: String(e?.message || e).slice(0, 80) }));
  if (r.ok) {
    peopleDirError = '';
    act('people.directory', { detail: `슬랙 사용자 ${r.count}명 · ${r.pages}페이지` });
  } else {
    // 갱신에 실패해도 기존 캐시로 계속 돈다. 다만 실패 사실은 축 0 의 조회처에
    // 그대로 실린다 — 조용히 빈 값이 되면 "디렉터리에 없는 사람"과 "조회를 못 한 것"이
    // 구별되지 않고, 그 둘을 섞는 것이 이 층이 막으려는 오류다.
    peopleDirError = String(r.error || '알 수 없음');
    log('사람 디렉터리 갱신 실패:', peopleDirError);
    act('people.directory', { ok: false, error: peopleDirError });
  }
}

const ACK_LAYER_BUDGET_MS = 20_000; // 레이어 전체 마감. 넘으면 모인 것만으로 답한다.

// 선응답이 쓸 근거를 한 번에 모은다. 절대 던지지 않고, 못 모은 것은 그 사유가
// 문자열로 남는다 — 조용히 비면 모델이 "확인했지만 없었다"로 읽는다.
async function ackEvidence(item, ctx, media = null) {
  const mod = await answerContextModule();
  const jiraOnly = async () => ({
    access: null,
    jira: await jiraProblemContext(item.textEn, ctx),
    notion: '', research: '', related: '', glossary: '', people: '', peopleCtx: null,
  });
  if (!mod) return jiraOnly();

  const access = mod.resolveAccess({
    userId: item.authorId, text: item.textEn, ctx,
    policyFiles: [BUNDLED_PERMISSION_POLICY_FILE, PERMISSION_POLICY_FILE],
  });
  const held = (kind) => mod.withheldNote(kind, access);
  const notion = notionInstance();
  ensureKeys();
  // 용어집은 파일 두 개를 읽는 게 전부라 예산 밖에서 먼저 끝낸다. 그리고 이 레이어가
  // 가장 먼저 작동해야 한다 — 이름을 잘못 짚으면 뒤의 모든 근거가 엉뚱한 것을 가리킨다.
  let glossary = '';
  try {
    glossary = mod.glossaryContext({
      text: item.textEn, ctx, level: access.level,
      files: [BUNDLED_GLOSSARY_FILE, GLOSSARY_FILE],
    });
  } catch (e) {
    glossary = `[용어집] 읽기 실패 — ${String(e?.message || e).slice(0, 80)}`;
  }

  const jiraP = access.sources.jira
    ? jiraProblemContext(item.textEn, ctx) : Promise.resolve(held('Jira lookup'));
  const notionP = access.sources['notion-shared']
    ? mod.notionContext({
        text: item.textEn, ctx,
        token: notion?.token || null,
        timeoutMs: 6_000,
      })
    : Promise.resolve(held('Notion lookup'));
  const researchP = access.sources.research
    ? mod.researchContext({
        text: item.textEn, ctx,
        // 질의 생성은 가장 싼 모델 한 번. 실패하면 검색 자체를 건너뛴다.
        ask: (prompt) => callModel(prompt, []).then((r) => r?.out || ''),
        timeoutMs: 12_000, log,
      })
    : Promise.resolve(held('Web research'));

  // ── 축 0 — 사람 조회 ──────────────────────────────────────────────────────
  // 이 층에 넘기는 컨텍스트는 스레드까지다. 채널 최근 대화는 넣지 않는다 — 날짜가
  // 넘어가면 화제가 통째로 바뀌고, 그러면 이 메시지와 아무 상관 없는 사람의 이력이
  // 조회되어 나간다 (2026-08-31 Piyush 건에서 도메인 판정이 같은 이유로 틀렸다).
  const peopleMod2 = await peopleContextModule();
  const peopleP = (peopleMod2 && access.sources['people-directory'] !== false)
    ? peopleMod2.peopleContext({
        slack, text: item.textEn, ctx: threadOnlyContext(ctx),
        cache: peopleMod2.directoryCache({ dir: OUT_DIR }),
        // 작성자 자신과 이 봇은 후보에서 뺀다. 자기 프로필을 조회해 돌려주는 것은
        // 근거가 아니라 잡음이다.
        selfIds: [MY_USER, item.authorId].filter(Boolean),
        notionHrDbId: hrDatabaseId(),
        directoryError: peopleDirError,
        timeoutMs: 1_500, log,
      })
    : Promise.resolve(peopleMod2 ? held('사람 조회') : '');

  const budget = new Promise((resolve) => {
    const t = setTimeout(() => resolve('__ack-layer-timeout__'), ACK_LAYER_BUDGET_MS);
    t.unref?.();
  });
  const settle = (p, label) => Promise.race([p.catch((e) => `[${label}] 실패 — ${scrubSecrets(String(e?.message || e)).slice(0, 100)}`), budget])
    .then((v) => (v === '__ack-layer-timeout__' ? `[${label}] 시간 초과 — 이번 응답에서는 조회하지 못함` : v));

  const [jira, notionCtx, research, peopleRaw] = await Promise.all([
    settle(jiraP, 'Jira lookup'), settle(notionP, 'Notion lookup'), settle(researchP, 'Web research'),
    settle(peopleP, '사람 조회'),
  ]);
  // settle 은 실패·시간 초과를 문자열로 돌려준다. 축 0 만 구조체를 쓰므로 여기서
  // 갈라 놓는다 — 구조체가 없으면 메시지 1 은 나가지 않고, 사유 문자열은 프롬프트와
  // MD 에 그대로 남는다.
  const peopleCtx = (peopleRaw && typeof peopleRaw === 'object') ? peopleRaw : null;
  const people = peopleCtx ? peopleCtx.promptText : String(peopleRaw || '');

  // 다른 스레드 탐색은 "지금 여기에 근거가 없을 때"만 한다 — 사용자가 정한 순서
  // (스레드 → Jira/문서 → 그래도 없으면 다른 스레드)를 그대로 따르고, 매번 돌면
  // 검색 호출만 늘고 근거는 중복된다.
  const thin = !/^\[Notion 문서/m.test(notionCtx) && !/^[A-Z][A-Z0-9]*-\d+:/m.test(jira);
  let related = '';
  if (!access.sources.related) related = held('Slack 다른 스레드');
  else if (!thin) related = '[Slack 다른 스레드] 스레드·문서에 이미 근거가 있어 조회하지 않음';
  else related = await settle(mod.relatedThreadContext({
    text: item.textEn, slack, channel: item.channel, threadTs: item.threadTs, ts: item.ts, log,
  }), 'Slack 다른 스레드');

  const attachments = (media?.evidence || []).slice(0, 12).map((e) => {
    const head = `[${e?.type || 'attachment'}${e?.ref?.name ? ` ${e.ref.name}` : ''}]`;
    const body = scrubSecrets(String(e?.text || e?.error || '')).trim().slice(0, 1800);
    return body ? `${head}\n${body}` : '';
  }).filter(Boolean).join('\n\n').slice(0, 8000);
  return { access, glossary, jira, notion: notionCtx, research, related, attachments, people, peopleCtx };
}

// ---- 이모지 레이어 (emoji-layer.mjs) ----------------------------------------
// answer-context 와 같은 규칙: 별도 파일, 동적 import, 없으면 선응답은 예전대로
// 전부 글로 나간다.
let emojiMod = null;
let emojiModAt = 0;

async function emojiLayerModule() {
  if (emojiMod) return emojiMod;
  if (Date.now() - emojiModAt < 60_000) return null;
  emojiModAt = Date.now();
  try {
    const m = await import('./emoji-layer.mjs');
    if (typeof m.responseGrade !== 'function' || typeof m.loadCatalog !== 'function') {
      throw new Error('responseGrade/loadCatalog를 내보내지 않음');
    }
    emojiMod = m;
    log('emoji-layer 로드됨 — 축 1 기본값은 R1(리액션 하나)이고 글은 예외다');
  } catch (e) {
    emojiMod = null;
    log('emoji-layer 없음 — 선응답은 전부 글로 나간다:', String(e?.message || e).split('\n')[0]);
  }
  return emojiMod;
}

function emojiCatalog(mod) {
  return mod.loadCatalog([BUNDLED_EMOJI_LAYER_FILE, EMOJI_LAYER_FILE]);
}

// 어휘집이 무엇을 적어 두었든, 이 데몬의 수집 트리거(👀·🔖·📌)는 절대 달지 않는다.
// 달면 reaction_added(MY_USER) 가 그대로 재수집/재트리거로 돌아와 같은 항목이
// 미처리로 되살아난다 — 어휘집 쪽에도 auto:false 로 적어 두었지만, 운영 파일로
// 덮어쓸 수 있는 값 하나에 루프 여부를 걸어 두지는 않는다.
function emojiSafeToPost(name) {
  return Boolean(name) && !isTriggerEmoji(name);
}

// 리액션 하나로 선응답을 끝낸다. 성공하면 true — 호출부는 그때 글을 만들지 않는다.
// patch 는 이 리액션과 같은 한 번의 rewrite 로 실릴 항목 필드다. 등급 기록을 따로
// 쓰면 3.9MB 짜리 items.jsonl 을 두 번 읽고 두 번 쓰게 되고, 그만큼 겹칠 창이 넓어진다.
// 원장에 남기는 decision 한 조각. 사고를 실측할 때 원장 ack-emoji 158줄을 사유
// 문자열로 분류해야 했는데(전수 중 근거 있는 것은 26건뿐이었다), 그때 사유는 사람이
// 읽는 문장이라 분류가 손일이었다. 판정값을 그대로 실어 두면 같은 감사가 grep 한
// 줄이 된다. 값이 없는 옛 판정(모델 판정 pick 등)은 '미표기' 로 남긴다 — 빈칸으로
// 두면 "판정이 unknown 이었다" 와 "판정 자체가 없었다" 가 원장에서 같은 모양이 된다.
//
// items.jsonl 에는 넣지 않았다. 그 파일에는 이미 `decision` 이라는 필드가 있고(이
// 파일 :16 의 ===DECISION=== 마커, 1748줄 중 1691줄이 갖고 있다) 뜻이 전혀 다르다 —
// 그쪽은 모델이 만든 "3단계 의사결정 선택지" 본문이다. 같은 이름을 다른 뜻으로 덮으면
// 대시보드가 선택지 자리에 'needed' 세 글자를 그린다. 이 축을 나중에 항목에도 남겨야
// 하면 이름은 `ackDecision` 이어야 하고, 그때도 선택 항목으로 넣어야 한다.
function decisionTag(verdict) {
  return `판정 ${verdict?.decision || '미표기'}`;
}

// ackEmojis 에 이름 하나를 중복 없이 더한 새 배열. 원본을 고치지 않는 것은 실패했을 때
// 되돌릴 이전 값이 필요하기 때문이다.
function withAckEmoji(item, name) {
  const prev = Array.isArray(item?.ackEmojis) ? item.ackEmojis : (item?.ackEmoji ? [item.ackEmoji] : []);
  const n = baseEmoji(name);
  return prev.map(baseEmoji).includes(n) ? prev.slice() : [...prev, n];
}

async function postEmojiReaction(item, verdict, patch = {}) {
  if (!emojiSafeToPost(verdict?.emoji)) {
    log(`emoji 레이어: :${verdict?.emoji}: 는 수집 트리거라 달지 않는다 — 글로 답한다`);
    return false;
  }
  // ---- 쓰기 순서가 뒤집히면 회귀다 (2026-09-06) ------------------------------
  // 예전에는 reactions.add 를 먼저 하고 ackEmoji 를 그 뒤에 적었다. 그 await 이 풀리기
  // 전에 우리가 방금 단 그 리액션의 reaction_added 가 소켓으로 돌아오고, 그 시점에
  // 핸들러가 읽는 항목에는 ackEmoji 가 아직 없다. 그러면 resolvesPolicy 'self' 의
  // "우리가 단 이모지" 집합이 비어 있어 필터를 통과하고, 데몬이 자기 이모지로 항목을
  // 닫는 2026-09-02 사고가 그대로 재현된다.
  //
  // 그래서 낙관적으로 먼저 적고 실패하면 되돌린다. 디스크 쓰기 하나로 충분한 근거:
  //  - rewriteItem 은 readFileSync → writeFileSync(tmp) → renameSync 로 동기다.
  //    반환한 시점에 값이 이미 디스크에 있다.
  //  - loadItems 는 호출마다 파일을 다시 읽는다. 캐시가 없으므로 소켓 핸들러가 보는
  //    것은 언제나 최신 디스크 상태다.
  //  - node 는 단일 스레드이고 rewriteItem 이 동기라 그 사이에 이벤트가 끼지 못한다.
  // 인메모리 Set 을 대신 두지 않은 이유도 여기 있다. 데몬 재시작이 09-04 부터 하루
  // 23~27회인데, 디스크에 있는 값은 재시작을 넘어 살아남고 Set 은 그 창에서 뚫린다.
  //
  // 누적의 바닥은 호출부가 들고 온 item 이 아니라 디스크의 현재 줄이다. 그 객체는
  // 파이프라인 앞단에서 읽은 것이라, 그 사이에 이 항목에 이모지를 한 번 더 달았으면
  // 옛 값을 들고 있고 그것으로 누적하면 먼저 단 이름이 집합에서 조용히 빠진다.
  // 바로 그 빠짐이 'self' 에서 자기 이모지를 되읽는 구멍이 된다. 아래 rewriteItem 이
  // 어차피 파일을 통째로 읽으므로 여기서 한 번 더 읽는 값은 같은 자릿수다.
  const onDisk = loadItems().find((o) => o.id === item.id) || item;
  const prevAckEmoji = onDisk.ackEmoji;
  const prevAckEmojis = Array.isArray(onDisk.ackEmojis) ? onDisk.ackEmojis.slice() : undefined;
  rewriteItem(item.id, { ackEmoji: verdict.emoji, ackEmojis: withAckEmoji(onDisk, verdict.emoji) });
  try {
    await slack('reactions.add', {
      channel: item.channel,
      timestamp: item.ts,
      name: verdict.emoji,
    });
  } catch (e) {
    const msg = String(e?.message || e);
    // 이미 달려 있으면 목적은 이미 이뤄진 것이다 — 글로 덮지 않는다. 선기록은 그대로
    // 참이므로(그 이모지가 실제로 그 메시지에 달려 있다) 되돌리지 않는다.
    if (/already_reacted/.test(msg)) {
      rewriteItem(item.id, { ackAt: Math.floor(Date.now() / 1000), requestLevel: 0, ...patch });
      act('ack-emoji', { id: item.id, detail: `이미 :${verdict.emoji}: 가 달려 있음 · ${decisionTag(verdict)}` });
      return true;
    }
    // 이름이 틀렸거나 권한이 없으면 이 메시지에 아무 응답도 남지 않는다 — 글로 돌아간다.
    // 슬랙에 아무것도 안 달렸으므로 이벤트도 안 오고, 선기록을 되돌리는 것이 안전하다.
    // 되돌리지 않으면 "우리가 달지도 않은 이모지" 가 영구히 제외 집합에 남는다.
    rewriteItem(item.id, { ackEmoji: prevAckEmoji, ackEmojis: prevAckEmojis });
    log(`emoji 레이어 실패(:${verdict.emoji}:) — 글로 답한다:`, scrubSecrets(msg).slice(0, 100));
    act('ack-emoji', { id: item.id, ok: false, error: msg.slice(0, 120),
      detail: `:${verdict.emoji}: 실패 → 글로 대체 · ${decisionTag(verdict)}` });
    return false;
  }
  rewriteItem(item.id, { ackAt: Math.floor(Date.now() / 1000), requestLevel: 0, ...patch });
  act('ack-emoji', { id: item.id,
    detail: `선응답을 :${verdict.emoji}: 로 대체 · ${decisionTag(verdict)} · ${verdict.reason || verdict.kind || ''}` });
  return true;
}

// 근거를 못 찾았다는 판정. 문자열이 아니라 표식으로 돌려주는 이유는, 이 결과가
// 곧바로 슬랙에 나가는 문장이 아니라 "이모지 레이어에 한 번 더 물어보라"는 신호이기
// 때문이다. 빈 문자열('')과도 구별해야 한다 — 그쪽은 모델이 아무것도 못 낸 경우다.
const ACK_NO_BASIS = Symbol('ack-no-basis');

// noBasisText 는 지웠다. "답변 불가 / 이유: 컨텍스트 부족 / 필요: …" 세 줄도 라벨
// 틀이고, 상대에게는 우리 사정일 뿐이다 (설계 §3). 근거를 못 찾았으면 그것을 알리는
// 것이 아니라 R1 로 내려가 리액션 하나로 끝낸다.

// ---- 응답 포맷 버전과 스레드 원장 ---------------------------------------------
// 포맷 값은 원장(ackFormat)에만 남는다 — 렌더러는 하나다 (alignment-engine.mjs).
// config.json {"replyFormat":"v1"|"v2"|"v3"} 의 옛 값도 그대로 읽힌다. 데몬은 메시지마다 읽으므로
// 되돌리는 데 재시작이 필요 없다 — 새 포맷이 나쁘면 그 자리에서 v1 로 돌린다.
// 확신 하한은 규칙 파일에서 고친다 — 상수를 고치려고 앱을 다시 빌드해야 하면
// 아무도 안 고치고, 그러면 게이트가 상황에 맞지 않아도 그대로 남는다.
// config.json {"ackConfidenceMin": 0.8}. 0 이하나 1 초과는 무시하고 기본값을 쓴다.
function ackConfidenceMin() {
  try {
    const v = Number(JSON.parse(readFileSync(CONFIG_FILE, 'utf8')).ackConfidenceMin);
    return Number.isFinite(v) && v > 0 && v <= 1 ? v : ACK_MIN_CONFIDENCE;
  } catch { return ACK_MIN_CONFIDENCE; }
}

function replyFormatVersion() {
  try { return replyFormat(JSON.parse(readFileSync(CONFIG_FILE, 'utf8')).replyFormat); }
  catch { return LATEST_REPLY_FORMAT; }
}

function readAckThreads() {
  try { return JSON.parse(readFileSync(ACK_THREADS_FILE, 'utf8')); } catch { return { version: 1, threads: {} }; }
}

function writeAckThreads(state) {
  try {
    mkdirSync(OUT_DIR, { recursive: true });
    const tmp = `${ACK_THREADS_FILE}.tmp`;
    writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
    renameSync(tmp, ACK_THREADS_FILE);
  } catch (e) { log('ack 스레드 원장 쓰기 실패', e.message); }
}

function ackThreadKey(item) {
  return `${item.channel}:${item.threadTs || item.ts}`;
}

// 지운 답변을 다음 프롬프트에 그대로 넘긴다. 지우기만 하고 넘기지 않으면 "더
// 보완했습니다" 가 매번 처음부터 다시 쓰여 앞에서 확인한 것이 사라진다.
function priorAckText(entry) {
  const rows = (entry?.history || []).slice(-ACK_PRIOR_MAX);
  if (!rows.length) return '';
  return rows.map((row, i) =>
    `[이전 답변 ${i + 1}]\n${String(row?.body || '').trim()}`).join('\n\n').slice(0, 4000);
}

function pruneAckThreads(state, now) {
  const kept = {};
  for (const [key, entry] of Object.entries(state.threads || {})) {
    if (now - Number(entry?.at || 0) <= ACK_THREAD_TTL_SEC) kept[key] = entry;
  }
  return { version: 1, threads: kept };
}

// 새 답을 올린 뒤에 이전 답을 지운다 — 순서가 반대면 삭제와 게시 사이에 스레드가
// 비고, 그 사이에 상대가 스레드를 열면 답이 사라진 것으로 보인다.
async function supersedePriorAcks(item, body, ts) {
  const now = Math.floor(Date.now() / 1000);
  const state = readAckThreads();
  const key = ackThreadKey(item);
  const entry = state.threads?.[key] || { posts: [], history: [] };
  let removed = 0;
  for (const post of entry.posts || []) {
    if (!post?.ts || post.ts === ts) continue;
    if (now - Number(post.at || 0) > ACK_SUPERSEDE_WINDOW_SEC) continue;
    try {
      await slack('chat.delete', { channel: item.channel, ts: post.ts });
      removed++;
      if (post.itemId) rewriteItem(post.itemId, { ackSupersededAt: now });
    } catch (e) {
      // 지우지 못해도 새 답은 이미 나갔다. 실패한 ts 를 원장에 계속 들고 있으면
      // 매번 같은 호출이 실패하므로 여기서 놓아 준다 (사유는 로그에 남는다).
      log('이전 선응답 삭제 실패:', String(e?.message || e).slice(0, 80));
    }
  }
  state.threads ||= {};
  state.threads[key] = {
    at: now,
    posts: [{ ts, itemId: item.id, at: now }],
    history: [...(entry.history || []), { at: now, body }].slice(-ACK_PRIOR_MAX),
  };
  writeAckThreads(pruneAckThreads(state, now));
  return removed;
}

// ---- 축 1·축 2 정책 --------------------------------------------------------
// slack-emoji-layer.json 과 같은 두 겹: 번들 JSON 이 정본이고 운영 수정은 OUT_DIR 의
// 파일로 덮어쓴다. 파일을 하나도 못 읽어도 각 모듈 안의 폴백으로 계속 돈다 — 정책
// 파일이 사라졌다고 판정이 조용히 달라지기 시작하면 그것이 가장 나쁜 고장이다.
function ackCostPolicy() {
  let policy = {};
  for (const f of [BUNDLED_ACK_COST_POLICY_FILE, ACK_COST_POLICY_FILE]) {
    try {
      const o = JSON.parse(readFileSync(f, 'utf8'));
      if (!o || typeof o !== 'object') continue;
      policy = { ...policy, ...o,
        output: { ...(policy.output || {}), ...(o.output || {}) },
        noveltyGate: { ...(policy.noveltyGate || {}), ...(o.noveltyGate || {}) } };
    } catch { /* 없으면 다음 파일 */ }
  }
  return policy;
}

// ---- 신규성 게이트 (novelty-gate.mjs) ---------------------------------------
// 이 데몬의 신규성 판정기는 하나뿐이어야 한다. 축 1의 발신 게이트는 alignment-engine
// 을 거쳐 이 모듈을 쓰고, 아래 F2 취소도 같은 모듈의 novelTokens 를 그대로 부른다.
// 취소 전용 판정기를 따로 만들지 않은 이유가 이것이다 — 판정기가 둘이 되면 "스레드에
// 없는 것" 의 뜻이 자리마다 갈라지고, 그러면 한쪽에서 막힌 글이 다른 쪽에서 통과한다.
let noveltyMod = null;
let noveltyModAt = 0;

async function noveltyGateModule() {
  if (noveltyMod) return noveltyMod;
  if (Date.now() - noveltyModAt < 60_000) return null;
  noveltyModAt = Date.now();
  try {
    const m = await import('./novelty-gate.mjs');
    if (typeof m.novelTokens !== 'function') throw new Error('novelTokens를 내보내지 않음');
    noveltyMod = m;
  } catch (e) {
    // 못 읽으면 취소하지 않는다. 모르면 예전 동작(F2 강등 유지)으로 남는 쪽이 맞다 —
    // 취소는 글을 내보내는 방향이고, 판정기가 없을 때 기본값이 발신이면 안 된다.
    noveltyMod = null;
    log('novelty-gate 없음 — F2 강등 취소는 하지 않는다:', String(e?.message || e).split('\n')[0]);
  }
  return noveltyMod;
}

// 축 0 이 스레드에 없는 사실을 하나라도 가져왔는가. 가져왔으면 F2("이미 답이 나와
// 있다")는 더 이상 맞는 판정이 아니다 — 축 2는 스레드만 보고 판정하는데, 축 0 은 바로
// 그 스레드 밖(슬랙 사용자 디렉터리)에서 값을 읽어 온 참이기 때문이다. 첫 드라이런에서
// 축 0 이 "Akash 의 실제 직책" 과 "Al Rizqi 는 계정이 없다" 를 찾아냈는데도 축 2가
// "새로운 게 없다" 며 메시지 2를 통째로 막았다. 그 구조를 여기서 끊는다.
//
// 무엇을 재는지에 주의한다. 렌더된 메시지 1 이 아니라 noveltyProbe 가 모아 준 조회값만
// 잰다. 메시지 1 을 그대로 넣던 판에서는 취소가 무조건 참이었다 — 근거로 찍힌 새 토큰
// 여덟 개가 전부 고정 서두("컨텍스트 매니지먼트 에이전트입니다 …")였고, 그 문장은 어느
// 스레드에도 없으므로 조회 결과가 0건인 날에도 여덟 개가 나온다. 취소 규칙이 있으나
// 마나 한 상태였다(설계 §11-9-1 무력화).
async function axis0CancelsF2(pc, source) {
  if (!pc) return { cancelled: false, tokens: [] };
  const nov = await noveltyGateModule();
  if (!nov) return { cancelled: false, tokens: [] };
  const pmod = await peopleContextModule();
  // 탐침이 없는 옛 people-context 면 취소하지 않는다. 모르면 예전 동작(F2 강등 유지)이
  // 맞다 — 취소는 글을 내보내는 방향이고, 판정 재료가 없을 때 기본값이 발신이면 안 된다.
  if (typeof pmod?.noveltyProbe !== 'function') return { cancelled: false, tokens: [] };
  try {
    const probe = pmod.noveltyProbe(pc).trim();
    if (!probe) return { cancelled: false, tokens: [] };
    const tokens = nov.novelTokens(probe, String(source || ''));
    return { cancelled: tokens.length > 0, tokens };
  } catch (e) {
    log('F2 취소 판정 실패:', String(e?.message || e).slice(0, 80));
    return { cancelled: false, tokens: [] };
  }
}

// ---- 축 2 모듈 (problem-frame.mjs) ------------------------------------------
// answer-context · emoji-layer 와 같은 규칙: 별도 파일, 동적 import, 없으면 축 2 없이
// 예전대로 돈다.
let frameMod = null;
let frameModAt = 0;

async function problemFrameModule() {
  if (frameMod) return frameMod;
  if (Date.now() - frameModAt < 60_000) return null;
  frameModAt = Date.now();
  try {
    const m = await import('./problem-frame.mjs');
    if (typeof m.frameVerdict !== 'function' || typeof m.frameResearch !== 'function') {
      throw new Error('frameVerdict/frameResearch를 내보내지 않음');
    }
    frameMod = m;
    log('problem-frame 로드됨 — 축 2(문제 정의) 활성');
  } catch (e) {
    frameMod = null;
    log('problem-frame 없음 — 축 2 없이 돈다:', String(e?.message || e).split('\n')[0]);
  }
  return frameMod;
}

// 축 2 를 한 번 돌린다. F3 이면 gsk 로 공개 웹 자료까지 가져온다. 조회에 실패하면
// 지적만 따로 내보내지 않고 침묵한다 — 근거 없는 훈수는 그 자체로 커뮤니케이션
// 코스트다 (설계 §8). 이 함수는 절대 던지지 않는다.
async function problemFrame(item, thread) {
  const mod = await problemFrameModule();
  if (!mod) return { grade: 'F0', why: 'problem-frame 없음', reframe: [], research: null };
  const policy = mod.loadFramingPolicy([BUNDLED_FRAMING_POLICY_FILE, FRAMING_POLICY_FILE]);
  // 축 2의 모델 호출에도 마감을 건다. 다른 레이어(근거 20초·축 1 추출 15초)와 같은
  // 수준이다 — 축 2가 늦어서 축 1의 응답이 늦어지면 순서가 뒤집힌 것이다. 마감을
  // 넘기면 F0, 즉 축 2는 아무것도 하지 않는다.
  const budget = new Promise((resolve) => {
    const t = setTimeout(() => resolve({ grade: 'F0', why: '축 2 시간 초과', reframe: [], query: '' }), 15_000);
    t.unref?.();
  });
  const frame = await Promise.race([mod.frameVerdict({
    text: item.textEn, thread, policy, log,
    ask: (prompt) => callModel(prompt, []).then((r) => r?.out || ''),
  }), budget]).catch(() => ({ grade: 'F0', why: '판정 실패', reframe: [], query: '' }));
  if (frame.grade !== 'F3') return { ...frame, research: null, policy };
  const sec = Number(policy?.research?.timeoutSec) > 0 ? Number(policy.research.timeoutSec) : 20;
  const research = await mod.frameResearch({
    query: frame.query, timeoutMs: sec * 1000,
    maxResults: Number(policy?.research?.maxResults) || 5, log,
  }).catch(() => ({ ok: false, reason: 'THREW', rows: [], query: frame.query }));
  return { ...frame, research, policy, mod };
}

// ---- MD 노트 ----------------------------------------------------------------
// 디스크에 남기고 같은 파일을 스레드에 올린다. 받는 사람은 이 맥 바깥에 있어서
// 저장소 경로도 127.0.0.1 대시보드도 도달하지 않는다 — 스레드 파일만 도달한다.
//
// files.upload 는 폐기됐다. getUploadURLExternal 로 업로드 주소를 받고, 그 주소에
// 본문을 올린 뒤, completeUploadExternal 로 스레드에 붙인다. 스코프(files:write)는
// cm-slack-user-token 에 이미 들어 있다 — 새 권한을 요구하지 않는다.
//
// 실패하면 디스크에는 남기고 슬랙에는 파일이 없는 채로 둔다. 본문에 "자세한 내용은
// 첨부 참고" 같은 줄을 애초에 붙이지 않는 이유가 이것이다: 있지도 않은 파일을
// 가리키지 않으려면 가리키는 문장 자체를 만들지 않는 것이 가장 확실하고, 그런
// 이음말은 설계 §7-1 이 금지한 소음이기도 하다. 파일은 스레드에 그대로 붙으므로
// 그 존재를 문장으로 다시 알릴 이유가 없다.
async function uploadAckNote(item, fileName, body) {
  try {
    const bytes = Buffer.byteLength(body, 'utf8');
    const up = await slack('files.getUploadURLExternal', { filename: fileName, length: bytes });
    if (!up?.upload_url || !up?.file_id) throw new Error('업로드 주소를 받지 못함');
    const put = await fetch(up.upload_url, {
      method: 'POST', body, headers: { 'Content-Type': 'text/markdown; charset=utf-8' },
      signal: AbortSignal.timeout(15_000),
    });
    if (!put.ok) throw new Error(`업로드 HTTP ${put.status}`);
    await slack('files.completeUploadExternal', {
      files: JSON.stringify([{ id: up.file_id, title: fileName }]),
      channel_id: item.channel,
      thread_ts: item.threadTs || item.ts,
    });
    return true;
  } catch (e) {
    log('ack MD 업로드 실패 — 디스크에만 남는다:', scrubSecrets(String(e?.message || e)).slice(0, 120));
    return false;
  }
}

// 슬랙에 나가지 않은 전부를 MD 한 장으로 만들어 디스크에 쓰고, 스레드에 올린다.
// 업로드 성공 여부를 돌려준다 — 원장에 남겨 "파일이 갔는가"를 나중에 되짚는다.
// 두 벌을 만든다. 디스크에는 전부 담고, 스레드에는 이 스레드 사람들이 원래 볼 수 있는
// 것만 올린다 (ack-note.mjs 의 audience 주석 참조). 올리는 쪽은 scrubSecrets 를 한 번 더
// 거친다 — 근거 문자열에 토큰이 섞여 들어오는 경로가 하나라도 있으면 그것이 파일로
// 슬랙에 올라가는 것은 로그에 찍히는 것보다 나쁘다.
async function emitAckNote(item, note) {
  const fileName = noteFileName(item.channel, item.ts);
  const disk = writeNote(ACK_NOTE_DIR, fileName, renderNote({ ...note, audience: 'disk' }));
  if (!disk.ok) log('ack MD 디스크 기록 실패:', disk.error);
  const uploaded = await uploadAckNote(item, fileName,
    scrubSecrets(renderNote({ ...note, audience: 'thread' })));
  return { fileName, uploaded, onDisk: disk.ok };
}

// ---- 축 1 — 글을 만들고 게이트에 건다 ----------------------------------------
//
// 옛 legacyPrompt 는 지웠다. `void legacyPrompt;` 로 죽여 둔 채 80 줄을 남겨 놓았는데,
// 그 안에 "에이전트 자동 응답입니다" 와 목적·의도·부합 여부 라벨 틀의 정본이 그대로
// 적혀 있었다. 안 도는 코드가 옛 틀의 정본처럼 남아 있으면 다음 사람이 그것을 보고
// 되살린다 — 실제로 2026-08-31 사고의 본문이 이 틀 그대로였다.
async function acknowledgementText({ text, ctx, thread = '', threadAfter = '', jiraCtx, extra,
  language, format = LATEST_REPLY_FORMAT, prior = '', noRequestSignal = null, requestLevel = 2,
  persona = '', sendContext = {}, noveltyOverlapMax } = {}) {
  // 한 번 부르고, 결정된 언어를 어겼으면 규칙을 프롬프트 맨 끝에 얹어 한 번 더 부른다.
  // 두 번째도 어기면 발신하지 않는다 — 야샬 건처럼 상대가 못 읽는 글을 라이언 이름으로
  // 내보내는 것보다 아무것도 안 내보내는 쪽이 낫다.
  const askModel = async (retryRule) => {
    const prompt = extractionPrompt({ text, context: ctx, jira: jiraCtx, extra, language,
      format, prior, persona, retryRule });
    const timeout = new Promise((resolve) => {
      const timer = setTimeout(() => resolve(null), 15_000);
      timer.unref?.();
    });
    const result = await Promise.race([callModel(prompt, []), timeout]);
    return parseExtraction(result?.out);
  };

  let analysis = await askModel('');
  // adds 가 비면 모델 스스로 "스레드에 더하는 것이 없다"고 말한 것이다. 설계 §2 —
  // 그 한 줄이 비면 자동으로 R1 로 내려간다. 게이트까지 가기 전에 여기서 끝난다.
  if (analysis && analysis.has_basis !== false
    && analysis.adds !== undefined && !String(analysis.adds).trim()) {
    return { downgrade: 'R1', reason: 'NO_ADDS_LINE', analysis };
  }
  let rendered = renderReply(analysis);
  if (!rendered) return ACK_NO_BASIS;

  // 결정된 언어를 실제로 지켰는가. 모델에게 다시 묻지 않고 코드가 읽는다.
  let violation = languageViolation(rendered, language);
  let languageRetried = false;
  if (violation) {
    languageRetried = true;
    const retryAnalysis = await askModel(languageRetryRule(language));
    const retryRendered = renderReply(retryAnalysis);
    const retryViolation = retryRendered ? languageViolation(retryRendered, language) : violation;
    if (retryRendered && !retryViolation) {
      analysis = retryAnalysis;
      rendered = retryRendered;
      violation = null;
    } else {
      violation = retryViolation || violation;
    }
  }
  if (violation) {
    return { blocked: true, analysis,
      gate: { send: false, reasons: [violation], languageRetried, language } };
  }
  // 글이 만들어졌다고 나가는 것이 아니다. 확신·근거 상태·스캐폴딩 누출·발신 금지
  // 자리·신규성을 코드가 한 번 더 읽는다. 게이트는 글이 완성된 뒤에 선다 — 완성된
  // 글 자체를 봐야 알 수 있는 것들이기 때문이다.
  const gate = ackSendGate({
    analysis, extra, jira: jiraCtx, body: rendered, minConfidence: ackConfidenceMin(),
    requestLevel, noRequestSignal,
    // 자리를 게이트에 넘긴다. 이 세 값이 확신 산정의 필수 입력이다 — 넘기지 않으면
    // 채널이 해석되지 않고, 해석되지 않으면 확신이 0 이 되어 아무것도 나가지 않는다.
    channelId: sendContext.channelId || '', channelName: sendContext.channelName || '',
    channelProject: sendContext.channelProject ?? null,
    sourceText: text, context: ctx,
    files: sendContext.files || [], sensitivePolicyFiles: SENSITIVE_POLICY_FILES,
    // 신규성은 스레드와 원문 양쪽에 대고 잰다. 스레드가 없는 채널 멘션에서도 "상대가
    // 방금 쓴 말의 재진술"은 잡혀야 하기 때문이다. 채널 최근 대화는 넣지 않는다 —
    // 화제가 섞여 있어 우연한 중복으로 멀쩡한 답을 막는다.
    thread: `${thread}\n${text}`, threadAfter, noveltyOverlapMax,
  });
  if (!gate.send) return { blocked: true, gate, analysis };
  return { body: rendered, analysis, gate, languageRetried };
}

// 못 보낸 것이 어디로 갔는지를 한 줄로 남긴다. 이 파일이 "게이트가 막았는데 그래서
// 어떻게 됐나" 의 유일한 답이다. 기록에 실패해도 차단 판정은 그대로다 — 원장을 못
// 쓴 것이 발신 사유가 될 수는 없다.
function recordAckFallback(item, gate, route) {
  try {
    mkdirSync(dirname(ACK_FALLBACK_LEDGER), { recursive: true });
    appendFileSync(ACK_FALLBACK_LEDGER, JSON.stringify({
      at: Math.floor(Date.now() / 1000),
      id: item.id, channel: item.channel, channelName: item.channelName || '',
      permalink: item.permalink || '', author: item.author || '',
      route: route.route, target: route.target, why: route.why,
      reasons: gate.reasons || [],
      confidence: gate.confidence ?? null, effectiveConfidence: gate.effectiveConfidence ?? null,
      channelTier: gate.channel?.tier || null, channelFolder: gate.channel?.folder || null,
      text: String(item.textEn || '').slice(0, 600),
    }) + '\n');
  } catch (e) {
    log('행선지 원장 기록 실패:', String(e?.message || e).slice(0, 100));
  }
}

async function postAcknowledgement(item, ctx) {
  if (!shouldAutoReply(item) || !item.authorId || item.authorId === MY_USER) return;
  const thread = threadOnlyContext(ctx);
  const threadAfter = threadAfterContext(ctx);
  const now = () => Math.floor(Date.now() / 1000);

  // ── 축 1 — 응답 등급 ───────────────────────────────────────────────────────
  // 바닥값은 R1(리액션 하나)이고 글은 예외다. 예전에는 이 자리가 "이모지로 끝내도
  // 되는가"를 물었고 판정이 안 서면 글이었다 — 축이 거꾸로였다 (설계 §4).
  //
  // emoji-layer 를 통째로 못 읽었을 때만 R2 로 시작한다. 그때는 리액션을 달 이모지
  // 이름조차 알 수 없어서 R1 을 실행할 방법이 없다. 모르면 조용해지는 쪽이 아니라
  // 원래 하던 대로 하는 쪽으로 넘어가는 이 코드베이스의 규칙이 여기서도 같다.
  const emo = await emojiLayerModule();
  // decision 도 여기서 기본값을 준다. emoji-layer 를 못 읽었다는 것은 판정을 못 했다는
  // 뜻이지 판정이 not-needed 라는 뜻이 아니다 — 원장에서 둘이 같은 모양이 되면 안 된다.
  let grade = { grade: 'R2', emoji: null, decision: 'unknown', reason: 'emoji-layer 없음 — 예전대로 글로 답한다' };
  if (emo && typeof emo.responseGrade === 'function') {
    try { grade = emo.responseGrade({ text: item.textEn, catalog: emojiCatalog(emo), source: item.source }); }
    catch (e) { log('축 1 등급 판정 실패:', String(e?.message || e).slice(0, 80)); }
  }

  if (grade.grade === 'R0') {
    rewriteItem(item.id, { ackGrade: 'R0', ackGradeReason: String(grade.reason || '').slice(0, 300) });
    act('ack.grade', { id: item.id, detail: `R0 · 발신 없음 · ${grade.reason || ''}` });
    return;
  }

  // R1 이면 리액션 하나로 끝난다. 근거 레이어 20초와 모델 호출 서너 번을 쓰지 않는다.
  if (grade.grade === 'R1') {
    const patch = { ackGrade: 'R1', ackGradeReason: String(grade.reason || '').slice(0, 300) };
    if (grade.emoji && await postEmojiReaction(item, grade, patch)) return;
    // 리액션을 달지 못했다고 글로 넘어가지 않는다. 등급이 R1 이라는 것은 "이 메시지는
    // 글을 받을 자격이 없다"는 판정이고, 리액션 실패는 그 판정을 뒤집지 않는다.
    // 예전 코드는 여기서 글로 대체했고, 그것이 티타임 공지에 재진술이 나간 경로 중
    // 하나였다. 대신 왜 아무것도 안 남았는지를 원장에 적는다.
    rewriteItem(item.id, { ...patch, ackBlockedAt: now(), ackBlockedReasons: ['R1_REACTION_FAILED'] });
    act('ack.blocked', { id: item.id, detail: `R1 · 리액션을 달지 못해 아무 응답도 남지 않음 · ${grade.reason || ''}` });
    return;
  }

  // ── R2 이상 후보 ──────────────────────────────────────────────────────────
  // 여기부터는 "글이 될 수도 있다"일 뿐이다. 신규성 게이트를 통과해야 실제로 글이 된다.
  let noRequestSignal = null;
  if (emo) {
    try { noRequestSignal = emo.vetoReason(item.textEn, emojiCatalog(emo)) === null; }
    catch { noRequestSignal = null; }
  }

  // item.textEn 은 이름과 달리 번역본이 아니라 원문(composeSource 의 결과)이다.
  // 번역은 textKo 에만 있다. 스레드 컨텍스트를 함께 넘겨 프로필 국가로 떨어지는
  // 경로를 마지막으로 미룬다 (설계 §7-2).
  // 수신자 언어는 여기서 한 번 정해지고, 이 아래로는 아무도 다시 정하지 않는다.
  // basis 는 "왜 그 언어였나" 를 원장에 남긴다 (roster:slack-profile / message / thread …).
  const { lang: language, basis: languageBasis } = await replyLanguage(item.textEn, item.authorId, ctx);
  const langPatch = { ackLang: language, ackLangBasis: languageBasis };
  const media = await (item.mediaPromise || Promise.resolve(null));
  const ev = await ackEvidence(item, ctx, media).catch((e) => {
    log('ack evidence 실패:', scrubSecrets(String(e?.message || e)).slice(0, 120));
    return { access: null, jira: '[Jira lookup] unavailable', notion: '', research: '', related: '' };
  });
  // 근거 깊이는 원장에만 남는 내부 값이다. 나가는 글의 모양을 정하지 않는다 (설계 §5-1).
  const requestLevel = evidenceRequestLevel(ev, { hasAttachment: (media?.evidence || []).length > 0 });
  // ── 축 0 등급 ─────────────────────────────────────────────────────────────
  // C0 은 "이 대화에서 조회된 사람이 하나도 없다"이고, 그때는 메시지를 내지 않는다.
  // 아무도 해석하지 못했는데 "못 찾았습니다"를 내보내는 것은 그 자체가 커뮤니케이션
  // 코스트다 — 이 층은 그 코스트를 줄이려고 만든 것이지 늘리려고 만든 것이 아니다.
  const pc = ev.peopleCtx || null;
  const ctxGrade = pc?.grade || 'C0';
  const ctxResolved = pc?.rows?.length || 0;
  const ctxUnresolved = pc?.unresolved?.length || 0;
  const format = replyFormatVersion();
  const prior = priorAckText(readAckThreads().threads?.[ackThreadKey(item)]);
  const files = (media?.evidence || []).concat(item.files || []);

  // 발신 금지 자리는 글을 만들기도 전에 끝낸다. 판정이 결정적이라 모델이 필요 없고,
  // 근거 레이어 20초와 모델 호출 서너 번을 쓰지 않는다. 게이트 안에서도 같은 함수를
  // 다시 부른다 — 규칙은 하나이고, 자리만 둘이다(싸게 먼저, 안전하게 다시).
  const sens = sensitiveContext({
    channelName: item.channelName || '', text: item.textEn, context: ctx,
    files, policyFiles: SENSITIVE_POLICY_FILES,
  });
  if (sens.domain) {
    act('ack.blocked', { id: item.id,
      detail: `발신 차단 · SENSITIVE_CONTEXT:${sens.domain} · ${sens.where} "${sens.hit}" · ${sens.label}` });
    rewriteItem(item.id, { requestLevel, ackGrade: grade.grade, ackBlockedAt: now(),
      ackGradeReason: `발신 금지 자리(${sens.domain})`,
      ackBlockedReasons: [`SENSITIVE_CONTEXT:${sens.domain}`] });
    log(`ack 차단 ${item.id}: SENSITIVE_CONTEXT:${sens.domain} (${sens.where}="${sens.hit}")`);
    return;
  }

  const policy = ackCostPolicy();

  // ── 메시지 1 본문을 축 2보다 먼저 만든다 ─────────────────────────────────
  // 아래 F2 취소는 이제 이 본문이 아니라 조회값(noveltyProbe)을 본다. 그래도 렌더를
  // 여기 남겨 둔 이유는 축 2가 어떻게 나오든 만드는 값이 같아야 하기 때문이다 — 판정
  // 뒤로 옮기면 F2 가 걸린 경로와 안 걸린 경로에서 다른 본문이 만들어질 자리가 생긴다.
  // 만드는 자리이지 내보내는 자리가 아니다 — 발신은 여전히 축 1이 실제로 나가는 것이
  // 확정된 뒤에만 한다.
  let ctxBody = '';
  if (ctxGrade !== 'C0') {
    const pmod = await peopleContextModule();
    try {
      ctxBody = pmod ? pmod.renderContextMessage(pc, {
        maxLines: Number(policy?.contextMessage?.maxLines) || 12,
        maxChars: Number(policy?.contextMessage?.maxChars) || 1200,
      }) : '';
    } catch (e) {
      log('축 0 렌더 실패:', String(e?.message || e).slice(0, 100));
    }
  }

  // ── 축 2 — 문제 정의 ──────────────────────────────────────────────────────
  // 축 1이 R2 이상 후보일 때만 돌린다. 아무것도 묻지 않은 메시지에는 고쳐 세울
  // 물음의 모양이 없고, 그 자리에서 모델을 한 번 더 부르는 것은 값만 든다.
  const frame = await problemFrame(item, thread).catch(() => null);
  const frameGrade = frame?.grade || 'F0';
  let frameReason = String(frame?.why || '').slice(0, 300);

  // 두 축이 만나는 단 한 지점: F2 는 축 1을 R1 로 강등한다 (설계 §1).
  //
  // 단 하나의 예외를 여기에 둔다. 축 2는 스레드만 보고 "이미 답이 나와 있다"고
  // 판정하는데, 축 0 은 바로 그 스레드에 없는 것 — 슬랙 사용자 디렉터리 — 을 읽어 온
  // 참이다. 첫 드라이런에서 축 0 이 Akash 의 실제 직책과 "Al Rizqi 는 계정이 아예
  // 없다" 를 찾아냈는데도 축 2가 "새로운 게 없다" 며 메시지 2를 통째로 막았다. 축 0 이
  // 신규성을 만들어 냈는데 축 2가 그 입을 막는 구조라 여기서 끊는다.
  //
  // 취소는 F2 에만 걸린다. F3 도, 아래의 다른 R1 강등 사유(NO_ADDS_LINE · 확신 부족 ·
  // 신규성 없음 · 발신 금지 자리)도 이 예외를 타지 않는다 — 그 사유들은 축 0 이 무엇을
  // 찾아왔는지와 무관하게 그대로 성립한다.
  if (frameGrade === 'F2') {
    const cancel = await axis0CancelsF2(pc, `${thread}\n${item.textEn}\n${threadAfter}`);
    if (cancel.cancelled) {
      frameReason = `${frameReason} (축 0 으로 취소됨)`.slice(0, 300);
      act('ack.frame', { id: item.id,
        detail: `F2 강등 취소 · 축 0 이 스레드에 없는 사실 ${cancel.tokens.length}개를 가져옴 · ${cancel.tokens.join(', ')}`.slice(0, 300) });
    } else {
      const patch = { requestLevel, ackGrade: 'R1', frameGrade, frameReason,
        ackGradeReason: `F2 강등 · 이미 답이 나와 있음 — ${frameReason}` };
      if (grade.emoji && await postEmojiReaction(item, grade, patch)) return;
      rewriteItem(item.id, { ...patch, ...langPatch, ackBlockedAt: now(), ackBlockedReasons: ['F2_ALREADY_ANSWERED'] });
      act('ack.blocked', { id: item.id, detail: `F2 강등 · 리액션도 달지 못함 · ${frameReason}` });
      return;
    }
  }
  const out = await acknowledgementText({
    text: item.textEn, ctx, thread, threadAfter, jiraCtx: ev.jira, extra: ev, language,
    format, prior, noRequestSignal, requestLevel,
    persona: policy.persona || '',
    // 가정 한 줄은 더 이상 축 1의 글에 붙지 않는다 (alignment-engine renderReply 주석).
    // 범위가 모호하면 밝히고 보내는 것이 아니라 보내지 않는다. 가정은 MD 노트로 간다.
    sendContext: { channelId: item.channel, channelName: item.channelName, files },
    noveltyOverlapMax: Number(policy?.noveltyGate?.overlapMax) || undefined,
  });

  // 등급을 못 올린 자리는 전부 R1 로 내려온다. 왜 글이 안 나갔는지가 보이지 않으면
  // "왜 답이 없지" 가 다시 사람의 일이 된다 (설계 §6).
  const demote = async (reasonCode, detail) => {
    const patch = { requestLevel, ackGrade: 'R1', frameGrade, frameReason, ...langPatch,
      ackGradeReason: `${grade.grade} 후보 → R1 강등 · ${detail}`.slice(0, 300) };
    act('ack.grade', { id: item.id, detail: `R1 강등 · ${reasonCode} · ${detail}`.slice(0, 300) });
    if (grade.emoji && await postEmojiReaction(item, grade, patch)) return;
    rewriteItem(item.id, { ...patch, ...langPatch, ackBlockedAt: now(), ackBlockedReasons: [reasonCode] });
    act('ack.blocked', { id: item.id, detail: `R1 강등 후 리액션도 달지 못함 · ${reasonCode}` });
  };

  if (out && out.downgrade === 'R1') {
    await demote('NO_ADDS_LINE', '모델이 무엇을 더하는지 한 줄을 대지 못함');
    return;
  }
  if (out && out.blocked) {
    const g = out.gate || {};
    const reasons = (g.reasons || []).join(',') || 'unknown';
    act('ack.blocked', { id: item.id,
      detail: `발신 차단 · ${reasons}`
        + `${g.confidence == null ? '' : ` · 확신 ${g.confidence}`}`
        + `${(g.failedLayers || []).length ? ` · 조회실패 ${g.failedLayers.join(',')}` : ''}`
        + `${(g.scaffold || []).length ? ` · 스캐폴딩 ${g.scaffold.join(',')}` : ''}`
        + `${g.sensitive ? ` · 금지자리 ${g.sensitive}(${g.sensitiveWhere})` : ''}`
        + `${g.novelty ? ` · 신규성 ${g.novelty.novel ? '있음' : '없음'}(${g.novelty.overlap})` : ''}`
        + `${g.echo == null ? '' : ` · 되풀이 ${g.echo}`}` });
    // 신규성으로 막힌 것은 침묵이 아니라 R1 이다 — Maryam 건에서 나갔어야 할 것이
    // 리액션 하나였다. 나머지 사유(확신 부족·근거 조회 실패·누출)는 예전처럼 침묵한다.
    if (reasons.includes('NO_NOVELTY')) {
      await demote('NO_NOVELTY', `스레드에 이미 있음 · 중복 ${g.novelty?.overlap ?? '?'}`);
      return;
    }
    // 막다른 길을 만들지 않는다. 게이트가 돌려준 행선지를 원장 두 곳에 남긴다 —
    // 아이템 줄(대시보드가 읽는다)과 행선지 원장(사람이 읽는다). 여기서 새 슬랙 발신
    // 경로를 열지 않는다. 차단을 고치려고 새 발신구를 만드는 것은 같은 사고를 다른
    // 문으로 다시 내는 것이다.
    const route = g.fallbackRoute || null;
    if (route) recordAckFallback(item, g, route);
    rewriteItem(item.id, { requestLevel, ackGrade: grade.grade, frameGrade, frameReason, ...langPatch,
      ackGradeReason: `발신 차단 · ${reasons}`.slice(0, 300),
      ackBlockedAt: now(), ackBlockedReasons: g.reasons || [],
      ackFallbackRoute: route?.route, ackFallbackTarget: route?.target });
    log(`ack 차단 ${item.id}: ${reasons}${route ? ` → ${route.route} ${route.target}` : ''}`);
    return;
  }

  // 근거를 못 찾았을 때. 예전에는 "답변 불가 / 이유 / 필요" 3줄을 내보냈는데, 그것도
  // 라벨 틀이고 상대에게는 우리 사정일 뿐이다 (설계 §3). 이제는 스레드를 같이 놓고
  // 이모지를 한 번 더 고르고, 그것도 안 되면 등급 판정이 들려 준 이모지로 끝낸다.
  if (out === ACK_NO_BASIS) {
    let pick = null;
    if (emo) {
      pick = await emo.modelVerdict({
        text: item.textEn, ctx, catalog: emojiCatalog(emo),
        ask: (prompt) => callModel(prompt, []).then((r) => r?.out || ''), log,
      }).catch(() => null);
    }
    const patch = { requestLevel, ackGrade: 'R1', frameGrade, frameReason,
      ackGradeReason: `${grade.grade} 후보 → R1 강등 · 근거를 찾지 못함` };
    if (pick && await postEmojiReaction(item, pick, patch)) return;
    await demote('NO_BASIS', '근거를 찾지 못함');
    return;
  }
  if (!out || !out.body) return;

  // ── 슬랙 두 줄 · 280자 / 나머지는 MD ─────────────────────────────────────
  const limits = { maxLines: Number(policy?.output?.maxLines) || undefined,
    maxChars: Number(policy?.output?.maxChars) || undefined };
  const brief = slackBrief(out.body, limits);
  const depth = ['R2', 'R3', 'R4'].includes(String(out.analysis?.depth || '').toUpperCase())
    ? String(out.analysis.depth).toUpperCase() : grade.grade;
  const note = {
    channel: item.channel, channelName: item.channelName, ts: item.ts, permalink: item.permalink,
    author: item.author, grade: depth, gradeReason: String(out.analysis?.adds || '').slice(0, 300),
    frameGrade, frameReason, requestLevel, language,
    message: item.textEn, sent: brief.text, overflow: brief.overflow,
    // 가정 한 줄은 슬랙이 아니라 여기로 온다. 나가는 글에서 뺐다고 사실을 버리지
    // 않는다 — 되짚을 때 "무엇을 가정하고 이 글을 지었나" 가 필요하다.
    detail: [String(out.analysis?.detail || ''),
      String(out.analysis?.assumption || '').trim()
        ? `가정: ${String(out.analysis.assumption).trim()}` : '']
      .filter(Boolean).join('\n\n'),
    evidence: { context: ctx, notion: ev.notion, jira: ev.jira, related: ev.related,
      glossary: ev.glossary, attachments: ev.attachments },
    research: ev.research, novelty: out.gate?.novelty || null,
    people: ev.people || '', ctxGrade,
  };

  // 첫 문장 하나조차 상한을 넘으면 슬랙에 내보낼 한 줄이 없다. 잘라 붙이지 않는다 —
  // 잘린 문장을 슬랙에 남기는 것은 요약이 아니라 훼손이다 (설계 §7-1). 전문은 MD 로
  // 남기고 슬랙은 비운다.
  if (!brief.text) {
    await emitAckNote(item, note);
    rewriteItem(item.id, { requestLevel, ackGrade: depth, frameGrade, frameReason, ...langPatch,
      ackNoteFile: noteFileName(item.channel, item.ts),
      ackGradeReason: '한 문장도 상한에 들어가지 않아 전문만 MD 로 남김',
      ackBlockedAt: now(), ackBlockedReasons: ['NO_BRIEF_LINE'] });
    act('ack.blocked', { id: item.id, detail: '발신 차단 · NO_BRIEF_LINE · 전문은 MD 로 남김' });
    return;
  }

  // ── 메시지 1 — 컨텍스트 매니지먼트 (축 0) ────────────────────────────────
  //
  // 축 1이 실제로 나가는 것이 확정된 뒤에야 만든다. R1 강등·발신 차단·NO_BRIEF_LINE
  // 으로 끝나는 자리는 전부 위에서 return 했으므로 여기까지 온 건 반드시 축 1과 짝이
  // 된다 — 근거만 덩그러니 남고 답은 없는 자리를 만들지 않는다.
  //
  // 이 메시지는 ackSendGate 를 타지 않는다. 모델이 지은 글이 아니라 조회 결과를 그대로
  // 늘어놓은 템플릿이라 확신도·신규성·에코 비율이라는 값 자체가 정의되지 않는다.
  // 대신 세 관문을 탄다. ① resolveAccess 의 people-directory 등급 — ackEvidence 에서
  // 이미 걸러 등급이 모자라면 peopleCtx 가 아예 없다. ② sensitiveContext — 위에서 채널·
  // 원문·컨텍스트에 대고 한 번 걸렀고, 여기서 렌더된 본문에 대고 한 번 더 건다.
  // ③ people-context.mjs 의 필드 허용목록 — Phone·Gmail·이메일 따위는 애초에 반환되지
  // 않으므로 본문에 실릴 경로가 없다.
  //
  // 멘션을 붙이지 않는다. 같은 스레드에 알림을 두 번 만들지 않기 위해서다 — 알림은
  // 답이 있는 메시지 2 하나로 충분하다.
  //
  // **자리 규칙은 이 경로에도 건다.** 이 메시지는 위의 세 관문을 타지만 채널 해석은
  // 타지 않았고, 그래서 DM 에도 사람 조회 결과가 그대로 나갔다. 확신·신규성이 정의되지
  // 않는 것은 맞지만 "이 대화가 어느 프로젝트의 일인가" 는 이 메시지에도 정의된다.
  // 해석되지 않는 자리(DM·그룹 DM·이름 없음)에서는 이 메시지도 나가지 않는다.
  let ctxTs = '';
  const ctxChannel = resolveChannel({ channelId: item.channel, channelName: item.channelName || '' });
  if (ctxGrade !== 'C0' && ctxChannel.tier === 'unresolved') {
    act('ack.context', { id: item.id, ok: false,
      detail: `발신 차단 · UNRESOLVED_CHANNEL:${ctxChannel.why} · ${ctxGrade}` });
  } else if (ctxGrade !== 'C0') {
    // 본문은 축 2보다 앞에서 이미 만들어 두었다(F2 취소가 그것을 근거로 쓴다).
    // 여기서 다시 렌더하지 않는다 — 같은 값을 두 번 만들면 두 값이 갈라질 자리가 생기고,
    // 그러면 "취소 근거로 쓴 본문" 과 "실제로 나간 본문" 이 달라진다.
    const body = ctxBody;
    const bodySens = body ? sensitiveContext({
      channelName: item.channelName || '', text: body, files,
      policyFiles: SENSITIVE_POLICY_FILES,
    }) : { domain: null };
    if (body && bodySens.domain) {
      act('ack.context', { id: item.id, ok: false,
        detail: `발신 차단 · SENSITIVE_CONTEXT:${bodySens.domain} · ${ctxGrade}` });
    } else if (body) {
      // 메시지 1 발신 실패는 메시지 2를 막지 않는다. 조회 결과가 못 나간 것은
      // 답이 못 나갈 이유가 아니다 — 로그와 원장에만 남긴다.
      try {
        const cres = await slack('chat.postMessage', {
          channel: item.channel, thread_ts: item.threadTs || item.ts, text: body,
        });
        ctxTs = cres.ts || '';
      } catch (e) {
        log('축 0 메시지 발신 실패 — 축 1은 그대로 나간다:', scrubSecrets(String(e?.message || e)).slice(0, 120));
        act('ack.context', { id: item.id, ok: false, error: String(e?.message || e).slice(0, 120) });
      }
    }
  }

  const res = await slack('chat.postMessage', {
    channel: item.channel,
    thread_ts: item.threadTs || item.ts,
    text: `<@${item.authorId}> ${brief.text}`,
  });
  // MD 는 본문이 나간 뒤에 올린다. 업로드가 실패해도 본문은 파일을 가리키지 않으므로
  // 있지도 않은 파일을 가리키는 상태가 생기지 않는다.
  const emitted = brief.overflow || note.detail || ev.research
    ? await emitAckNote(item, note) : { fileName: undefined, uploaded: false, onDisk: false };
  rewriteItem(item.id, {
    ackTs: res.ts || now(), ackAt: now(), ackFormat: format, requestLevel,
    ackGrade: depth, ackGradeReason: String(out.analysis?.adds || '').slice(0, 300),
    frameGrade, frameReason, ...langPatch,
    // 실제로 나간 본문. 여기 없으면 대시보드 발신 탭이 빈 화면이 된다 —
    // ack-threads.json 에도 남지만 그 파일은 스레드별 최신본만 들고 있다.
    ackBody: `${brief.text}`.slice(0, 2400),
    ackLangRetried: out.languageRetried ? true : undefined,
    // 축 0. 새로 더한 네 필드는 전부 선택 항목이다 — 이 필드가 없는 옛 줄을 읽는 쪽이
    // 멈추지 않도록 값이 없으면 undefined 로 두고, rewriteItem 이 그 키를 지운다.
    ctxGrade: ctxGrade === 'C0' ? undefined : ctxGrade,
    ctxResolved: ctxResolved || undefined,
    ctxUnresolved: ctxUnresolved || undefined,
    ctxTs: ctxTs || undefined,
    ackNoteFile: emitted.onDisk ? emitted.fileName : undefined,
    ackNoteUploaded: emitted.uploaded ? true : undefined,
  });
  // 원장 detail 에는 세 기호를 다 적는다 (설계 §9 — 이 데몬의 등급 체계는 이제 다섯이다).
  // 숫자만 적으면 나중에 "그때 무엇을 조회했고 무엇을 못 했는지"가 어디에도 없다.
  if (ctxResolved || ctxUnresolved) {
    act('ack.context', { id: item.id,
      detail: `${depth}/${frameGrade}/${ctxGrade} · 해석 ${ctxResolved}명 · 미해석 ${ctxUnresolved}명`
        + `${ctxTs ? '' : ' · 메시지 미발신'}`
        + `${(pc?.sources || []).length ? ` · ${pc.sources.map((s) => `${s.name} ${s.state}`).join(' · ')}` : ''}`.slice(0, 300) });
  }
  const superseded = res.ts ? await supersedePriorAcks(item, brief.text, res.ts) : 0;
  // 어떤 근거를 실었고 무엇이 권한으로 빠졌는지가 로그에 남아야 나중에 되짚을 수 있다.
  const used = [
    /^\[Notion 문서/m.test(ev.notion || '') ? '문서' : null,
    /^[A-Z][A-Z0-9]*-\d+:/m.test(ev.jira || '') ? 'Jira' : null,
    /^\[다른 스레드/m.test(ev.related || '') ? '다른스레드' : null,
    /질의:/.test(ev.research || '') ? '리서치' : null,
  ].filter(Boolean);
  // 통과한 건의 overlap 도 남긴다. 막힌 건(ack.blocked)에만 남기면 임계값을 다시 정할 때
  // 정작 필요한 쪽 — 통과한 쪽 — 의 값이 어디에도 없다. 2026-08-31 조사에서 실측 표본이
  // 사실상 2건까지 줄어든 이유가 그것이다. 값이 없으면(스레드 미제공 등) 조각을 생략한다.
  const overlap = out.gate?.novelty?.overlap;
  act('ack', { id: item.id,
    detail: `선응답 전송 · ${depth}/${frameGrade} · ${format} · 근거 ${used.length ? used.join('+') : '스레드만'}`
      + `${overlap == null ? '' : ` · 신규성 ${overlap}`}`
      + `${out.analysis?.adds ? ` · 더한 것: ${String(out.analysis.adds).slice(0, 60)}` : ''}`
      + `${emitted.fileName ? ` · MD ${emitted.uploaded ? '업로드' : '디스크만'}` : ''}`
      + `${superseded ? ` · 이전 답변 ${superseded}건 대체` : ''}${ev.access ? ` · ${ev.access.reason}` : ''}` });

  // ── 축 2 — F3 별개 메시지 ────────────────────────────────────────────────
  await postProblemFrame(item, frame, { thread, threadAfter, axis1: brief.text, note });
}

// F3 은 축 1과 별개의 메시지를 낸다. 답하는 행위와 물음을 고쳐 세우는 행위는 다른
// 일이고, 받는 사람이 그 둘을 구별해 볼 수 있어야 한다 (설계 §1).
//
// 조회 실패·시간 초과·빈손이면 침묵한다. 지적만 따로 내보내지 않는다 — 근거 없는
// 훈수는 그 자체로 커뮤니케이션 코스트다 (설계 §8). 이때도 축 1의 응답은 이미 나갔다.
async function postProblemFrame(item, frame, { thread = '', threadAfter = '', axis1 = '', note = null } = {}) {
  if (!frame || frame.grade !== 'F3' || !frame.mod) return;
  if (!frame.research?.ok) {
    act('ack.frame', { id: item.id,
      detail: `F3 이지만 침묵 · 조회 ${frame.research?.reason || 'NONE'} · 근거 없는 지적은 내보내지 않는다` });
    return;
  }
  const line = frame.mod.frameSlackLine(frame);
  const body = stripFrames(line);
  if (!body) return;
  // 축 1이 이미 같은 지적을 했으면 침묵한다 — F3 메시지도 같은 신규성 게이트를 통과해야
  // 한다 (설계 §8 표의 마지막 줄).
  const gate = ackSendGate({
    // 자리를 같이 넘긴다. 넘기지 않으면 채널이 해석되지 않아 확신이 0 이 되고 F3 이
    // 통째로 사라진다 — 이 메시지도 축 1과 같은 자리에서 같은 규칙으로 판정한다.
    analysis: { confidence: 1, adds: line }, body,
    channelId: item.channel, channelName: item.channelName || '',
    sourceText: item.textEn, context: note?.evidence?.context || '',
    thread: `${thread}\n${item.textEn}\n${axis1}`, threadAfter,
  });
  if (!gate.send) {
    act('ack.frame', { id: item.id, detail: `F3 침묵 · ${(gate.reasons || []).join(',')}` });
    return;
  }
  const brief = slackBrief(body);
  if (!brief.text) return;
  const res = await slack('chat.postMessage', {
    channel: item.channel, thread_ts: item.threadTs || item.ts,
    text: `<@${item.authorId}> ${brief.text}`,
  }).catch((e) => {
    log('F3 발신 실패:', scrubSecrets(String(e?.message || e)).slice(0, 100));
    return null;
  });
  if (!res) return;
  // 세 줄 규격 전문과 조회한 자료 전문·출처 URL 은 전부 MD 로 간다. 슬랙 본문에는
  // 한 줄도 쓰지 않는다 — 자료를 본문에 풀어놓는 순간 이번에 지적된 것과 같은 실패다.
  const policyLines = frame.policy?.f3Format?.lines;
  const emitted = await emitAckNote(item, {
    ...(note || { channel: item.channel, ts: item.ts }),
    grade: 'F3-note', frameGrade: 'F3', sent: brief.text, overflow: '',
    detail: frame.mod.frameNoteBody(frame, frame.research, policyLines),
    research: '',
  });
  act('ack.frame', { id: item.id,
    detail: `F3 발신 · 자료 ${frame.research.rows.length}건 · MD ${emitted.uploaded ? '업로드' : '디스크만'}` });
}

// ---- 산출물 검사 (QC) --------------------------------------------------------
// 전수 조사에서 드러난 세 가지 고장을 산출물에서 직접 잡는다.
//   untranslated  영어 원문인데 번역이 안 되고 원문이 그대로 돌아왔다 (89건, 7.1%)
//   meta-refusal  번역 자리에 "번역하지 않겠다"는 설명이 들어왔다 (1건이지만 그 1건이
//                 원문 4300자를 123자로 날렸다 — 번역 실패가 원문 소실이 되면 안 된다)
//   shrunk/lost   번역 자리에 요약이 들어와 원문보다 크게 짧아졌다 (0.35 미만 9건,
//                 0.2 미만 3건)
//   markers-missing  ===MEANING===/===DECISION===을 못 찾아 의미·의사결정이 빔 (84건)
const META_REFUSAL_RE =
  /(번역\s*(단계\s*없이|이?\s*필요\s*(없|하지)|하지\s*않|을?\s*생략)|원문을?\s*그대로\s*(출력|유지|반환)|번역\s*없이|already\s+in\s+(korean|the\s+target)|no\s+translation\s+(is\s+)?(needed|required))/i;

// hangulRatio / hasEnglishSentence 는 reply-language.mjs 에서 가져다 쓴다. 여기 있던
// 정의를 지운 이유는 같은 판정이 두 벌이 되지 않게 하기 위해서다 — 번역 QC(qcNotes)와
// 수신자 언어 판정이 서로 다른 잣대를 쓰기 시작하면 어느 쪽이 맞는지 알 수 없어진다.

function qcNotes(text, r, lang) {
  if (!r.ko) return ['no-output'];
  const notes = [];
  const en = String(text || '').trim();
  const ko = r.ko.trim();
  if (!r.meaning || !r.decision) notes.push('markers-missing');
  if (META_REFUSAL_RE.test(ko.slice(0, 400))) notes.push('meta-refusal');
  if (en.length >= 300 && ko.length < en.length * 0.2) notes.push('lost');
  else if (en.length >= 300 && ko.length < en.length * 0.35) notes.push('shrunk');
  // 원문 유지가 타당한 경우(이미 한국어·이름/URL만)를 빼고, 영어 문장인데 그대로면 고장.
  //
  // 판정 단위가 메시지가 아니라 줄이다 (2026-09-02). 예전에는 메시지 전체의 한글 비율만
  // 봐서, 영어 본문에 한국어 인용이 붙은 메시지는 한글이 5%를 넘는다는 이유로 통과했다.
  // 본문이 한 글자도 안 바뀐 채 번역 자리에 들어간 항목이 코퍼스에 33건 있었고 전부
  // 사유 없이 지나갔다. 이제 번역됐어야 하는 줄의 절반 이상이 그대로 남아 있으면 잡는다.
  const stale = untranslatedSegments(en, ko, lang);
  const owed = foreignSegments(en, lang);
  if (owed.length && stale.length >= owed.length / 2) notes.push('untranslated');
  return notes;
}

// 어느 시도가 더 나은가 — 심각한 결함일수록 크게 깎고, 의미/의사결정이 있으면 더한다.
function qcScore(r, notes) {
  let s = 0;
  for (const n of notes) {
    s -= { 'no-output': 200, 'meta-refusal': 100, lost: 80, untranslated: 40, shrunk: 20, 'markers-missing': 10 }[n] || 5;
  }
  if (r.meaning) s += 5;
  if (r.decision) s += 5;
  return s;
}

// stale = 직전 시도가 건너뛴 줄들. 무엇을 어겼는지 말할 때 그 줄을 그대로 보여 주는
// 것이 "번역하라"를 한 번 더 쓰는 것보다 잘 지켜진다 — 모델이 메시지 전체를 다시
// 판정하지 않고 그 줄만 고치면 되기 때문이다.
function retryRules(notes, name, stale = []) {
  const out = [];
  if (notes.includes('untranslated')) {
    out.push(`- 직전 시도는 아래 줄들을 ${name}로 바꾸지 않고 원문 그대로 돌려주었다.`
      + ` 이 줄들은 ${name}가 아니다. 이번에는 반드시 ${name}로 번역하라.`
      + ' 메시지의 다른 부분이 이미 한국어라는 것은 이 줄을 건너뛸 이유가 되지 않는다.');
    for (const l of stale.slice(0, 8)) out.push(`  · ${l.slice(0, 160)}`);
  }
  if (notes.includes('meta-refusal'))
    out.push('- 직전 시도는 번역 대신 "번역하지 않겠다"는 설명을 적었다. 설명을 쓰지 말고 결과만 출력하라.');
  if (notes.includes('lost') || notes.includes('shrunk'))
    out.push('- 직전 시도는 원문보다 훨씬 짧은 요약을 내놓았다. 요약하지 말고 원문의 모든 줄을 옮겨라.');
  if (notes.includes('markers-missing'))
    out.push('- 직전 시도는 ===MEANING=== / ===DECISION=== 마커를 빠뜨렸다. 두 줄을 정확히 그대로 출력하라.');
  return out;
}

// Returns {ko, meaning, decision, model, lang, ms, note} — ko null when every route
// failed. A selected Gemini model that errors (bad key, quota, network) silently
// falls back to Claude so items never stall on a misconfigured model
// (no-user-facing-failure). ctx = gatherContext() 결과 (의미 분석 재료).
// note = QC가 붙인 사유(쉼표 결합). 정상이면 undefined.
async function translate(text, ctx = '', evidence = []) {
  const t0 = Date.now();
  const lang = targetLang();
  const name = LANGS[lang] || LANGS.ko;
  const inline = inlineParts(evidence);
  const run = async (rules) => {
    const { out, model } = await callModel(translatePrompt(text, ctx, lang, evidence, rules), inline);
    return { r: splitSections(out), model };
  };

  let { r, model } = await run([]);
  let notes = qcNotes(text, r, lang);
  if (notes.length && notes[0] !== 'no-output') {
    // 재시도는 딱 한 번. 무엇을 어겼는지 적어 주면 대개 그 시도에서 고쳐진다.
    // 두 번 이상 돌리면 실패한 항목 하나가 파이프라인을 오래 잡아먹는다.
    log(`translate QC ${notes.join(',')} — 1회 재시도`);
    try {
      const second = await run(retryRules(notes, name, untranslatedSegments(text, r.ko, lang)));
      const n2 = qcNotes(text, second.r, lang);
      if (qcScore(second.r, n2) > qcScore(r, notes)) {
        r = second.r;
        model = second.model;
        notes = n2;
        notes.push('retried');
      } else {
        notes.push('retry-no-better');
      }
    } catch (e) {
      log('translate 재시도 실패:', e.message);
    }
  }

  // 마지막 방어 — 번역 자리가 여전히 "번역이 아닌 것"이면 그것을 채택하지 않고
  // 원문을 그대로 둔다. 번역 실패는 번역이 없는 것으로 끝나야 하고, 원문이
  // 사라지는 것으로 끝나서는 안 된다 (실제로 4300자가 123자로 사라진 적이 있다).
  if (r.ko && (notes.includes('meta-refusal') || notes.includes('lost'))) {
    r = { ...r, ko: String(text || '') };
    notes.push('kept-original');
  }

  return {
    ...r,
    model,
    lang,
    ms: Date.now() - t0,
    note: notes.length ? notes.join(',').slice(0, 120) : undefined,
  };
}

// ------------------------------------------------ media-extract 모듈 (첨부 근거)

// 첨부에서 실제로 텍스트·프레임을 뽑는 일은 별도 파일(media-extract.mjs)의 소유다.
// 이 데몬은 계약된 두 함수(collectRefs/extractEvidence)만 호출한다.
// import를 정적으로 쓰지 않는 이유: 그 파일은 이 데몬과 따로 배포될 수 있고, 없으면
// 정적 import 하나 때문에 데몬 전체가 뜨지 않는다. 그래서 실패를 정상 경로로 다루고
// 60초 간격으로 다시 시도한다 — 파일이 나중에 생기면 재시작 없이 붙는다.
const MEDIA_CACHE_DIR = join(OUT_DIR, 'media-cache');
const MEDIA_TIMEOUT_MS = 90_000; // 모듈에 넘기는 마감
const MEDIA_HARD_MS = MEDIA_TIMEOUT_MS + 30_000; // 데몬 쪽 이중 마감 (아래 주석)
const MEDIA_TEXT_MAX = 4000; // items.jsonl 한 줄이 커지면 rewriteItem이 파일을 통째로 다시 쓴다
const EVIDENCE_TOTAL_MAX = 6000; // 프롬프트에 싣는 근거 총량
const INLINE_MAX_PARTS = 6;
const INLINE_MAX_B64 = 6_000_000;

let mediaMod = null;
let mediaModAt = 0;

async function mediaModule() {
  if (mediaMod) return mediaMod;
  if (Date.now() - mediaModAt < 60_000) return null;
  mediaModAt = Date.now();
  try {
    const m = await import('./media-extract.mjs');
    if (typeof m.collectRefs !== 'function' || typeof m.extractEvidence !== 'function') {
      throw new Error('collectRefs/extractEvidence를 내보내지 않음');
    }
    mediaMod = m;
    log('media-extract 로드됨 — 첨부 근거 추출 활성');
  } catch (e) {
    mediaMod = null;
    // 파일이 아직 없는 것도 정상 상태다. 60초에 한 줄만 남는다.
    log('media-extract 없음 — 첨부는 이름·링크만 사용:', String(e?.message || e).split('\n')[0]);
  }
  return mediaMod;
}

// 키가 로그·items.jsonl·오류 메시지로 새는 경로를 원천 차단한다. 모듈이 만든 문자열은
// 남의 코드가 만든 것이라 믿지 않고, 파일에 적히기 전에 여기서 한 번 지운다 —
// 한 번 적힌 키는 되돌릴 수 없다.
function scrubSecrets(s) {
  if (s === undefined || s === null) return s;
  let t = String(s);
  for (const k of [geminiKey, anthropicKey, USER_TOKEN, APP_TOKEN]) {
    if (k && k.length > 8) t = t.split(k).join('[redacted]');
  }
  return t
    .replace(/\bxox[abeprs]-[A-Za-z0-9-]{8,}/g, '[redacted]')
    .replace(/\bAIza[0-9A-Za-z_-]{10,}/g, '[redacted]')
    .replace(/\bsk-ant-[A-Za-z0-9_-]{10,}/g, '[redacted]');
}

// 첨부 근거 추출 한 번. 절대 예외를 밖으로 내지 않는다 — 첨부 하나가 실패해서
// 메시지 수집 전체가 깨지는 것이 이 기능에서 가장 피해야 할 실패 모드다.
// 반환 {evidence, notes, refs}.
async function mediaEvidence(msg, id) {
  const mod = await mediaModule();
  let refs = [];
  try {
    refs = (mod ? mod.collectRefs(msg) : localRefs(msg)) || [];
  } catch (e) {
    log(`media collectRefs ${id} 실패:`, scrubSecrets(e?.message));
    refs = localRefs(msg);
  }
  if (!refs.length || !mod) return { evidence: [], notes: mod ? [] : ['extractor-unavailable'], refs };
  ensureKeys();
  try {
    mkdirSync(MEDIA_CACHE_DIR, { recursive: true });
  } catch {}
  const opts = {
    // 자격증명은 opts로만 건넨다 (모듈은 키체인을 직접 열지 않는다).
    slackToken: USER_TOKEN,
    geminiKey: geminiKey || null,
    geminiModel: extractModel(),
    cacheDir: MEDIA_CACHE_DIR,
    timeoutMs: MEDIA_TIMEOUT_MS,
  };
  const t0 = Date.now();
  try {
    // 계약상 extractEvidence는 던지지 않지만 남의 파일이므로 믿지 않는다. 그리고
    // 영상 프레임 추출처럼 오래 걸리는 경로가 번역을 영원히 막지 않도록 데몬 쪽에도
    // 마감을 둔다 (모듈의 timeoutMs와 별개인 이중 안전장치 — 모듈이 마감을 안 지켜도
    // 이 메시지의 번역은 반드시 진행된다).
    let timer;
    const res = await Promise.race([
      mod.extractEvidence(refs, opts),
      new Promise((r) => {
        timer = setTimeout(() => r({ evidence: [], notes: ['daemon-timeout'] }), MEDIA_HARD_MS);
        timer.unref?.();
      }),
    ]);
    clearTimeout(timer);
    const evidence = Array.isArray(res?.evidence) ? res.evidence : [];
    act('media', { id, ms: Date.now() - t0, detail: `참조 ${refs.length}건 · 근거 ${evidence.length}건` });
    return { evidence, notes: Array.isArray(res?.notes) ? res.notes : [], refs };
  } catch (e) {
    const m = scrubSecrets(e?.message || String(e));
    log(`media extract ${id} 실패:`, m);
    act('media', { id, ok: false, ms: Date.now() - t0, error: m });
    return { evidence: [], notes: ['extract-failed'], refs };
  }
}

// items.jsonl에 남길 media 행 하나. 계약된 여섯 필드만 옮기고 값은 잘라서 넣는다.
function mediaRow(row) {
  const out = {};
  for (const k of ['type', 'name', 'url', 'method', 'text', 'error']) {
    const v = row[k];
    if (v === undefined || v === null || v === '') continue;
    let s = scrubSecrets(String(v));
    if (k === 'text' && s.length > MEDIA_TEXT_MAX) s = s.slice(0, MEDIA_TEXT_MAX) + '…';
    if (k === 'error' && s.length > 300) s = s.slice(0, 300);
    out[k] = s;
  }
  return out;
}

// evidence → items의 media 배열. inline(base64 원본)은 절대 넣지 않는다 — 한 줄이
// 수 MB가 되면 read-modify-rename인 rewriteItem이 매번 그 크기로 파일을 다시 쓴다.
// 근거가 하나도 없을 때는 파일 첨부만 "무엇이 붙어 있었는지"로 남긴다. 링크는
// 이미 textEn 안에 그대로 있으므로 남기지 않는다 (거의 모든 항목에 붙어 무의미해진다).
function mediaRows(evidence, refs) {
  const rows = [];
  for (const e of evidence || []) {
    rows.push(mediaRow({
      type: e?.type || refType(e?.ref?.mimetype, e?.ref?.name),
      name: e?.ref?.name,
      url: e?.ref?.url,
      method: e?.method,
      text: e?.text,
      error: e?.error,
    }));
  }
  if (!rows.length) {
    for (const r of refs || []) {
      if (r?.kind !== 'file') continue;
      rows.push(mediaRow({
        type: refType(r.mimetype, r.name),
        name: r.name,
        url: r.url,
        error: 'extractor-unavailable',
      }));
    }
  }
  return rows.slice(0, 20);
}

// 프롬프트의 <attachments>에 들어갈 줄들. 총량 상한을 넘으면 자른다.
function evidenceLines(evidence) {
  const lines = [];
  let used = 0;
  for (const e of evidence || []) {
    const head = `[${e?.type || 'unknown'}${e?.ref?.name ? ` ${e.ref.name}` : ''}${e?.method ? ` · ${e.method}` : ''}]`;
    let t = scrubSecrets(String(e?.text || '')).trim();
    if (!t) {
      if (e?.error) lines.push(`${head} 추출 실패: ${scrubSecrets(String(e.error)).slice(0, 200)}`);
      continue;
    }
    if (used + t.length > EVIDENCE_TOTAL_MAX) t = t.slice(0, Math.max(0, EVIDENCE_TOTAL_MAX - used)) + '…';
    used += t.length;
    lines.push(`${head}\n${t}`);
    if (used >= EVIDENCE_TOTAL_MAX) break;
  }
  return lines;
}

// 비전 모델에 직접 넘길 파트. 개수와 총 바이트에 상한을 둔다 — 요청 본문이 커지면
// 번역이 느려지거나 API가 통째로 거절한다. 이미지 몇 장을 빼고 번역이 되는 편이
// 이미지 하나 때문에 번역이 0건이 되는 것보다 낫다.
function inlineParts(evidence) {
  const out = [];
  let bytes = 0;
  for (const e of evidence || []) {
    for (const p of e?.inline || []) {
      if (out.length >= INLINE_MAX_PARTS) return out;
      const mimeType = String(p?.mimeType || '');
      const dataB64 = String(p?.dataB64 || '');
      if (!mimeType || !dataB64) continue;
      if (bytes + dataB64.length > INLINE_MAX_B64) continue;
      bytes += dataB64.length;
      out.push({ mimeType, dataB64 });
    }
  }
  return out;
}

// ---------------------------------------------------------------- state

const seen = new Set(); // "channel:ts" ids already recorded
const pendingAtBoot = []; // items saved without a translation (daemon died mid-run)
const loomRetryAtBoot = []; // Loom이 처리 중이어서 첨부 근거를 다시 읽어야 하는 items

function needsTranslationRetry(o) {
  if (!o || !String(o.textEn || '').trim()) return false;
  return o.pending === true
    || (o.error === 'translate-failed' && !String(o.textKo || '').trim());
}

function loadState() {
  if (!existsSync(ITEMS_FILE)) return;
  for (const line of readFileSync(ITEMS_FILE, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const o = JSON.parse(line);
      seen.add(o.id);
      // 1차 호출이 실패한 줄도 다시 잡는다. 예전 코드는 pending만 잡은 뒤 실패 시
      // pending을 지워, UI의 “재시작 시 재시도” 안내와 달리 빈 번역이 영구 고착됐다.
      if (needsTranslationRetry(o)) pendingAtBoot.push(o);
      const recent = Number(o.reactedAt || o.translatedAt || 0) > Math.floor(Date.now() / 1000) - 2 * 86400;
      const oldFailedLoom = recent && hasLoomRef(o.media) && (o.media || []).some((m) =>
        /loom\.com\/share\//i.test(String(m?.url || '')) && loomMediaLooksPending(m));
      if (o.mediaPending === 'loom' || oldFailedLoom) loomRetryAtBoot.push(o);
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

// Loom은 녹화 직후 수 분 동안 지연 안내 페이지만 보일 수 있다. 그 한 번의 실패로
// 내용을 확정하지 않고, 1·2·5·10·20분(이후 20분) 간격으로 최대 8회 재확인한다.
// 상태를 item에 함께 기록하므로 데몬이 재시작돼도 큐가 사라지지 않는다.
const LOOM_RETRY_DELAYS_MS = [60_000, 120_000, 300_000, 600_000, 1_200_000];
const LOOM_RETRY_MAX = 8;
const loomRetryTimers = new Map();

function hasLoomRef(refs) {
  return (refs || []).some((r) => /(?:^|\.)loom\.com\/share\//i.test(String(r?.url || '').replace(/^https?:\/\//, '')));
}

function loomMediaLooksPending(row) {
  const text = String(row?.text || '');
  return !!row?.error || !text.trim() ||
    /(loom is running a bit slower than usual|시스템 지연|서비스 로딩 속도가 지연|video (?:is )?still processing|영상 처리 중)/i.test(text);
}

function loomEvidenceReady(media) {
  return (media?.evidence || []).some((e) =>
    /loom\.com\/share\//i.test(String(e?.ref?.url || '')) && !loomMediaLooksPending(e));
}

function scheduleLoomRetry(item, attempt = 0) {
  if (!item?.id || attempt >= LOOM_RETRY_MAX || loomRetryTimers.has(item.id)) return;
  const delay = LOOM_RETRY_DELAYS_MS[Math.min(attempt, LOOM_RETRY_DELAYS_MS.length - 1)];
  const persistedAt = Number(item.mediaRetryAt || 0) * 1000;
  const wait = persistedAt > Date.now() ? persistedAt - Date.now() : delay;
  const retryAt = Math.floor((Date.now() + wait) / 1000);
  rewriteItem(item.id, { mediaPending: 'loom', mediaAttempts: attempt, mediaRetryAt: retryAt });
  const timer = setTimeout(() => {
    loomRetryTimers.delete(item.id);
    retryLoomItem({ ...item, mediaAttempts: attempt }).catch((e) => {
      log(`loom retry ${item.id} 실패:`, scrubSecrets(e?.message || e));
      scheduleLoomRetry(item, attempt + 1);
    });
  }, Math.max(1_000, wait));
  timer.unref?.();
  loomRetryTimers.set(item.id, timer);
  log(`loom retry 예약 ${item.id}: ${Math.round(wait / 1000)}초 후 (${attempt + 1}/${LOOM_RETRY_MAX})`);
}

async function retryLoomItem(item) {
  const attempt = Number(item.mediaAttempts || 0) + 1;
  const msg = await fetchMessage(item.channel, item.ts);
  if (!msg) throw new Error('message-not-found');
  const media = await mediaEvidence(msg, item.id);
  if (!loomEvidenceReady(media)) {
    if (attempt >= LOOM_RETRY_MAX) {
      rewriteItem(item.id, { mediaPending: undefined, mediaAttempts: attempt,
        mediaRetryAt: undefined, mediaError: 'loom-retry-exhausted' });
      act('media.retry', { id: item.id, ok: false, detail: `Loom ${attempt}회 후에도 준비되지 않음` });
      return;
    }
    scheduleLoomRetry({ ...item, mediaAttempts: attempt, mediaRetryAt: 0 }, attempt);
    return;
  }
  const ctx = await gatherContext(item.channel, item.ts, item.threadTs, msg);
  const textEn = item.textEn || await composeSource(msg);
  const tr = await translate(textEn, ctx, media.evidence);
  const rows = mediaRows(media.evidence, media.refs);
  rewriteItem(item.id, {
    textKo: tr.ko || item.textKo || '', meaning: tr.meaning || item.meaning,
    decision: tr.decision || item.decision, lang: tr.ko ? tr.lang : item.lang,
    model: tr.ko ? tr.model : item.model, trMs: tr.ko ? tr.ms : item.trMs,
    media: rows.length ? rows : item.media, mediaAt: Math.floor(Date.now() / 1000),
    mediaPending: undefined, mediaAttempts: attempt, mediaRetryAt: undefined,
    mediaError: undefined, translatedAt: Math.floor(Date.now() / 1000),
  });
  act('media.retry', { id: item.id, ms: tr.ms, detail: `Loom 준비 완료 · ${attempt}회차` });
  log(`loom retry 완료 ${item.id}: ${attempt}회차에 내용 확보`);
}

// ---------------------------------------------------------------- pipeline

// source: undefined = 👀 리액션 트리거, 'mention' = 나를 직접 멘션, 'team' = 내
// 유저그룹(팀) 멘션, 'later' = Slack 'Save for later' 저장. 멘션·later류는
// 이모지 없음 — 처리완료의 슬랙 리액션 동기화·reconcile 대상에서 제외된다.
async function processMessage(channel, ts, reactedAt, emoji, source) {
  const id = `${channel}:${ts}`;
  if (seen.has(id)) return;
  seen.add(id); // reserve immediately — concurrent event + catch-up dedupe

  const t0 = Date.now();
  try {
    const msg = await fetchMessage(channel, ts);
    if (!msg) {
      log(`skip ${id}: message not found (deleted?)`);
      act('collect', { id, ok: false, ms: Date.now() - t0, error: 'message-not-found' });
      return;
    }
    // 본문·blocks 인용·attachments 공유/펼침·파일 목록을 한 덩어리로 모은다.
    // 예전에는 msg.text 하나만 봤고, 그래서 인용문이 번역 대상에서 빠졌다.
    let textEn = await composeSource(msg);
    const attached = hasAttachmentOrLink(msg);
    if (!textEn.trim() && !attached) {
      // 본문도 첨부도 링크도 없을 때만 버린다. 첨부만 있는 메시지를 버리던 예전
      // 조건이 바로 "이미지만 올라온 메시지가 대시보드에 안 뜬다"의 원인이었다.
      log(`skip ${id}: empty text (본문·첨부·링크 모두 없음)`);
      act('collect', { id, ok: false, ms: Date.now() - t0, error: 'empty-text',
        detail: '본문·첨부·링크 모두 없음' });
      return;
    }
    // 첨부는 있는데 옮겨 적을 문장이 하나도 없는 경우(캡션 없는 카드 등) —
    // 빈 원문으로 두면 대시보드에 빈 줄이 뜬다.
    if (!textEn.trim()) textEn = '[첨부만 있는 메시지]';
    // Kick context collection + the (slow) translation FIRST so they overlap
    // the metadata fetches. 컨텍스트(스레드/채널 최근 대화)는 2차 의미 분석 재료.
    // 첨부 근거는 번역 프롬프트에 들어가야 하니 번역보다 앞서야 하지만, 컨텍스트
    // 수집과는 서로 독립이라 둘을 나란히 돌린다.
    // 보안 게이트가 context/Jira/첨부/LLM보다 먼저다. 차단 요청은 원문과 분류만
    // 로컬 item에 남기고 외부 분석 경로를 하나도 시작하지 않는다.
    const security = securityGate(textEn);
    const route = security ? null : levelOneRoute(textEn);
    // 보안 차단은 난이도가 아니라 별도 게이트다. 요청 레벨은 답을 위해 실제로 사용한
    // 컨텍스트 깊이를 뜻한다. 일반 요청은 L2로 시작하고 근거 수집 후 L3/L4로 확정된다.
    const requestLevel = route ? 1 : security ? 2 : 2;
    const shortcut = security || route;
    const emptyMedia = { evidence: [], notes: shortcut ? [security ? 'security-blocked' : 'level1-routed'] : [], refs: [] };
    const contextP = shortcut ? Promise.resolve(security
      ? '[security-blocked before context collection]' : '[level1-routed before context collection]')
      : gatherContext(channel, ts, msg.thread_ts, msg);
    const mediaP = shortcut ? Promise.resolve(emptyMedia) : mediaEvidence(msg, id);
    const koP = shortcut
      ? Promise.resolve({
          tr: {
            ko: textEn,
            meaning: security ? securityBlockedNote(security) : routingReply(textEn, route),
            decision: security
              ? '보안 게이트에서 차단됨 — 슬랙에는 아무것도 보내지 않았습니다. 필요하면 사람이 직접 답합니다.'
              : `확정된 경로로 즉시 안내 · ${route.key}`,
            model: security ? 'security-gate' : 'level1-router',
            lang: hasEnglishSentence(textEn) ? 'en' : 'ko', ms: 0,
          },
          media: emptyMedia,
        })
      : (async () => {
          const [ctx, media] = await Promise.all([contextP, mediaP]);
          return { tr: await translate(textEn, ctx, media.evidence), media };
        })();
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
    // item: null 은 의도된 null 이다. 수집 시점에는 항목이 아직 존재하지 않으므로
    // isResolvingEmoji 의 fail-closed 규칙(!ctx.item → false)에 걸려 'self' 아래에서는
    // 여기서 아무것도 닫히지 않는다. 특례 분기를 두지 않은 것이 그것이다 — 규칙 하나가
    // 두 자리를 덮어야 문이 하나로 남는다. 뜻으로도 맞는다: 이미 ✅ 가 달린 메시지에
    // 라이언이 👀 를 다시 달아 수집시키는 것은 "다시 보겠다" 이고, 수집 순간에 곧바로
    // 닫으면 그 👀 가 무의미해진다. 2026-09-06 에 되살리려는 라이언 손 557건은 전부
    // 수집 이후에 달린 리액션이라 이 결정이 목표를 깎지 않는다.
    const resolved = source ? resolvingReaction(msg.reactions, { item: null }) : null;
    const [chName, author, permalink] = await Promise.all([
      channelName(channel),
      // 봇 메시지는 이벤트에 bot_profile.name/username이 실려 온다 — API를 한 번
      // 덜 부르고 확실하다. 없을 때만 userName()이 bots.info까지 따라간다
      // (예전에는 여기서 B09KPG9FYBB 같은 원시 ID가 그대로 작성자로 남았다).
      msg.bot_profile?.name || msg.username || userName(msg.user || msg.bot_id),
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
      // 수신자에게는 노출하지 않고 Condition Mate 내부에서만 응답 여부를 추적한다.
      autoReplyPolicy: peopleReplyPolicy(msg.user).mode !== 'reply'
        ? 'no-reply-person' : channelReplyPolicy(channel, chName).mode,
      // 런타임에서만 쓰는 약속이다. JSON.stringify 시 Promise는 빈 객체가 되므로
      // append 직전에는 별도 item을 만들어 저장한다.
      textEn,
      textKo: '',
      pending: true,
      requestLevel,
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
      // 누른 사람이 나인지 — autoByMeFlag 주석 참고. 여기는 append 경로라
      // rewriteItem 의 undefined 제거를 안 타므로, JSON.stringify 가 undefined
      // 키를 통째로 빼 준다는 성질에 그대로 기댄다.
      autoByMe: resolved ? autoByMeFlag(resolved.by) : undefined,
    }; // done-state lives in app-owned done.json, not here
    const runtimeItem = { ...item, mediaPromise: mediaP };
    appendFileSync(ITEMS_FILE, JSON.stringify(item) + '\n');
    log(`listed ${id} from ${chName} by ${author}: ${textEn.slice(0, 60)}…`);
    // 수집 완료 = 화면에 원문이 뜬 시점. 번역은 아직 진행 중이라 별도 줄로 남는다.
    act('collect', { id, ms: Date.now() - t0,
      detail: `${chName} ${author} · ${source ? `@${source}` : `:${emoji || EMOJIS[0]}:`}` });
    if (resolved) {
      log(`auto-done ${id}: 수집 시점에 이미 :${resolved.name}: 리액션이 달려 있음`);
      markDone(id);
    }
    // 선응답은 첨부 추출을 기다리지 않는다. 컨텍스트만 모이면 별도로 전송하고,
    // 실패해도 번역/수집 파이프라인에는 영향을 주지 않는다.
    //
    // 보안 게이트가 선 항목은 이 분기에 들어오지 않는다 — 침묵이 그 게이트의 응답이다.
    // 게이트는 정규식이라 오탐이 나고, 오탐일 때 나가는 훈계는 받은 사람이 해석해야 하는
    // 비용이 된다. 차단은 원장에만 남기고 스레드에는 흔적을 만들지 않는다.
    if (security) {
      act('security.block', { id, detail: `민감정보 요청 차단 · ${security.kind} · 무응답` });
    } else if (shouldAutoReply(item)) {
      const post = route ? postLevelOneRoute(item, route)
        : contextP.then((ctx) => postAcknowledgement(runtimeItem, ctx));
      Promise.resolve(post).catch((e) => log(`ack ${id} 실패:`, scrubSecrets(e?.message || e)));
    }
    const { tr, media } = await koP;
    // 첨부 근거는 번역과 같은 한 번의 rewrite로 실린다 — 줄을 두 번 고치면
    // read-modify-rename을 두 번 하게 되고 그만큼 겹칠 창이 넓어진다.
    const rows = media.refs.length ? mediaRows(media.evidence, media.refs) : [];
    const loomPending = hasLoomRef(media.refs) && !loomEvidenceReady(media);
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
      // 번역 산출물 검사(QC)가 남긴 사유. 정상이면 키가 생기지 않는 optional 필드다.
      // 결손을 조용히 삼키지 않고 어디에서 무엇이 틀어졌는지 셀 수 있게 남긴다.
      trNote: tr.note || undefined,
      securityBlocked: security ? true : undefined,
      securityKind: security?.kind || undefined,
      requestRoute: route?.key || undefined,
      // 첨부가 있었던 항목에만 붙는 optional 필드. 없으면 키 자체가 생기지 않아
      // (rewriteItem이 undefined 키를 지운다) 옛 줄·텍스트 전용 줄의 모양은 그대로다.
      media: rows.length ? rows : undefined,
      mediaAt: rows.length ? Math.floor(Date.now() / 1000) : undefined,
      mediaPending: loomPending ? 'loom' : undefined,
      mediaAttempts: loomPending ? 0 : undefined,
    });
    if (loomPending) scheduleLoomRetry({ ...item, media: rows }, 0);
    log(`saved ${id} [${tr.model} ${(tr.ms / 1000).toFixed(1)}s]${rows.length ? ` +첨부 ${rows.length}건` : ''}${tr.ko ? '' : ' (translation FAILED, saved original)'}`);
    // 번역 1건 = 1줄. ms는 LLM 호출에 실제로 걸린 시간(항목 배지와 같은 값)이다.
    act('translate', { id, ok: !!tr.ko, ms: tr.ms,
      error: tr.ko ? '' : 'translate-failed',
      detail: `${tr.model}${tr.ko ? ` · ${tr.ko.length}자` : ' · 원문만 저장'}` });
    ping('ok', source === 'mention' ? '@멘션 번역' : source === 'team' ? '@팀멘션 번역'
      : source === 'later' ? '📌 Later 번역' : '👀 번역',
      `${chName} ${author} 메시지 번역 저장`);
  } catch (e) {
    seen.delete(id); // allow retry on next catch-up
    log(`process ${id} error:`, e.message);
    act('collect', { id, ok: false, ms: Date.now() - t0, error: e.message });
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
  let newest = 0; // 폴링이 새로 주운 메시지 중 가장 최근 — 소켓 교차검증의 증거
  for (const conv of convs) {
    try {
      const res = await slack('conversations.history', {
        channel: conv.id,
        oldest: String(since),
        limit: 30,
      });
      scanned++;
      const msgs = res.messages || [];
      for (const m of msgs) {
        if (!(await considerMessage(conv, m, since, kinds))) continue;
        found++;
        newest = Math.max(newest, Math.floor(Number(m.ts) || 0));
      }
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
          if (!(await considerMessage(conv, m, since, kinds))) continue;
          found++;
          newest = Math.max(newest, Math.floor(Number(m.ts) || 0));
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
  // 실시간 구독이 살아 있었다면(realtimeAt>0) 폴링이 그보다 새 메시지를 주울 일이
  // 없다 — 주웠다면 소켓이 그 이벤트를 못 받았다는 뜻이다. 무수신 상한을 기다리지
  // 않고 다음 워치독 틱에서 바로 재개통한다 (socketStale 참고).
  if (newest && health.realtimeAt && newest > health.realtimeAt) {
    missedRealtimeAt = newest;
    log(`실시간이 놓친 메시지를 폴링이 주움 (ts ${newest} > realtimeAt ${health.realtimeAt}) — 소켓 재개통 예정`);
  }
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
// 자동 처리완료를 누른 사람이 나(=데몬이 붙어 있는 계정)인지. autoBy 하나만으로는
// 대시보드가 "AI가 처리한 것" 과 "내가 슬랙에서 직접 이모지 단 것" 을 가를 수 없어
// 둘이 한 덩어리로 숨겨졌다. 여기서 미리 판정해 두는 이유는, 읽는 쪽이 자기 슬랙
// id 를 알 방법이 없기 때문이다 — items.jsonl 만 봐서는 어느 id 가 나인지 모른다.
//
// 세 값을 구분한다. true=내가, false=남이, undefined=모름(누가 눌렀는지 기록이
// 없거나 아직 auth.test 전). undefined 를 false 로 뭉개면 옛 레코드가 전부
// "남이 처리" 로 보이므로, 여기서는 필드를 아예 쓰지 않는 쪽을 택한다.
function autoByMeFlag(by) {
  if (!by || !MY_USER) return undefined;
  return by === MY_USER;
}

async function autoResolve(id, emoji, by) {
  const t0 = Date.now();
  try {
    if (loadDone()[id]) return; // 이미 처리완료 (수동이든 자동이든) — 건드리지 않음
    rewriteItem(id, {
      autoDone: true,
      autoEmoji: baseEmoji(emoji),
      autoBy: by || undefined,
      autoByMe: autoByMeFlag(by),
    });
    const ok = await markDone(id);
    log(`auto-done ${id}: :${baseEmoji(emoji)}: 리액션 감지 → 처리완료${ok ? '' : ' (app not running — reconcile가 재시도)'}`);
    act('auto.done', { id, ok, ms: Date.now() - t0,
      error: ok ? '' : 'app-not-running',
      detail: `:${baseEmoji(emoji)}: 리액션 감지 → 처리완료` });
    if (ok) ping('ok', '이모지로 해결됨', `:${baseEmoji(emoji)}: 리액션 감지 — 자동 처리완료`);
  } catch (e) {
    log(`autoResolve ${id} error:`, e.message);
    act('auto.done', { id, ok: false, ms: Date.now() - t0, error: e.message });
  }
}

// 마지막 비트리거 리액션이 사라졌다 → 자동 해결 취소. autoDone이 아닌 항목
// (사용자가 직접 처리완료한 항목)은 손대지 않는다.
async function autoUnresolve(id, item) {
  const t0 = Date.now();
  try {
    if (!item?.autoDone) return;
    rewriteItem(id, {
      autoDone: undefined, autoEmoji: undefined, autoBy: undefined, autoByMe: undefined,
    });
    const ok = await setDoneRemote(id, false);
    log(`auto-undone ${id}: 비트리거 리액션이 모두 사라짐 → 미처리 복귀${ok ? '' : ' (app not running)'}`);
    act('auto.undone', { id, ok, ms: Date.now() - t0,
      error: ok ? '' : 'app-not-running',
      detail: '비트리거 리액션이 모두 사라짐 → 미처리 복귀' });
  } catch (e) {
    log(`autoUnresolve ${id} error:`, e.message);
    act('auto.undone', { id, ok: false, ms: Date.now() - t0, error: e.message });
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
  const t0 = Date.now();
  try {
    // autoDone 표식도 함께 지운다 — 남의 리액션으로 자동 처리완료된 항목에 👀를
    // 다시 달면 "다시 보겠다"는 뜻이므로 미처리로 돌아와야 하는데, 표식이 남으면
    // 대시보드가 계속 숨기고 reconcile이 다시 처리완료로 되돌린다.
    rewriteItem(id, {
      triggeredAt: at || Math.floor(Date.now() / 1000),
      autoDone: undefined, autoEmoji: undefined, autoBy: undefined, autoByMe: undefined,
      ...patch,
    });
    const ok = await setDoneRemote(id, false);
    log(`retrigger ${id} → 미처리 복귀${ok ? '' : ' (app not running — done.json 갱신 실패)'}`);
    act('retrigger', { id, ok, ms: Date.now() - t0,
      error: ok ? '' : 'app-not-running',
      detail: '트리거 재발생 → 미처리 맨 위로 복귀' });
    if (ok) ping('ok', '트리거 재발생', '기존 항목을 미처리 맨 위로 복귀');
  } catch (e) {
    log(`retrigger ${id} error:`, e.message);
    act('retrigger', { id, ok: false, ms: Date.now() - t0, error: e.message });
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
      // ctx 에 항목을 넘겨 'self' 도 같은 문을 지나게 한다. by 는 resolvingReaction 이
      // r.users 에서 고른다 — MY_USER 가 목록 중간에 있어도 잡는다.
      // 이 경로는 2026-09-06 현재 reactions.get 이 2,018회 전수 실패해 죽어 있다(별건
      // 카드 2026-09-06-0202-condition-mate-reactions-get-failure). 그 호출은 이번
      // 범위가 아니고, 살아났을 때 올바르게 돌도록 문만 맞춰 둔다.
      const resolved = hasTrigger && still ? null : resolvingReaction(reactions, { item: o });
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
      // QC가 사유를 남긴 결과(요약·메타 문장·미번역)로 이미 있는 번역을 덮지 않는다.
      // 백필의 목적은 비어 있는 의미·의사결정을 채우는 것이지 번역을 바꾸는 게 아니다.
      textKo: tr.note ? o.textKo : tr.ko || o.textKo,
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

// ---- 조용히 죽는 소켓 --------------------------------------------------------
// WebSocket이 죽어도 close/error가 안 오는 경우가 있다 (경로가 사라진 half-open,
// 프록시가 조용히 끊음). 그러면 프로세스는 멀쩡히 살아 30초 하트비트를 계속 보내고
// socket:'connected'도 그대로라, 앱은 정상으로 보이는데 이벤트는 0건이 된다
// (2026-08-16: realtimeAt이 40분 낡은 채 socket:'connected', 그 사이 👀 제거 26건이
// 데몬 로그에 하나도 안 남았다. kickstart 하자마자 2건이 밀려 들어왔다).
//
// 그래서 "붙어 있다"를 믿지 않고 프레임 수신으로 판정한다:
//   1) 무수신 상한 — 어떤 프레임도 SOCKET_IDLE_LIMIT_MS 동안 안 오면 다시 개통한다.
//      슬랙은 조용한 워크스페이스에서 앱 레벨 프레임을 안 보내고 Node의 기본
//      WebSocket은 ping 프레임을 JS로 올려주지 않는다 — 즉 "조용함"만으로는 죽은
//      소켓과 한가한 워크스페이스를 구분할 수 없다. 그래서 판별하려 들지 말고 그냥
//      다시 개통한다. Socket Mode는 원래 서버가 주기적으로 재연결을 요구하는
//      프로토콜이라 재개통은 정상 동작이고, 비용은 apps.connections.open 1회다.
//      부수 효과로 hello 프레임이 오므로 frameAt이 항상 이 주기 안에서 갱신된다 —
//      앱은 그 사실에 기대어 "frameAt이 너무 낡음 = 데몬의 자가 복구가 안 돌고 있음"
//      이라는 백스톱을 안전하게 걸 수 있다.
//   2) 폴링 교차검증 — 실시간 구독이 있는데(realtimeAt>0) 폴링이 realtimeAt보다 새
//      메시지를 주웠다면, 그건 소켓이 그 이벤트를 못 받았다는 직접 증거다. 상한을
//      기다리지 않고 바로 개통한다.
// 두 경로 모두 30분 catch-up보다 훨씬 빠르고, 개통 직후 catch-up을 한 번 돌려
// 눈감고 있던 구간을 즉시 메운다.
const SOCKET_IDLE_LIMIT_MS = 10 * 60_000; // 프레임 무수신 상한
const SOCKET_CHECK_MS = 30_000; // 판정 주기 (하트비트와 같은 리듬)
const SOCKET_ROTATE_GAP_MS = 10 * 60_000; // 재개통 최소 간격 (재개통 폭주 방지)
// 재개통해도 소켓이 안 붙는 상태가 이어지면 프로세스째 갈아엎는다 — undici가 물린
// 경우처럼 같은 프로세스 안에서는 못 고치는 것들이 있다. launchd가 10초 뒤 되살린다.
const SOCKET_MAX_FAILURES = 6;

let lastFrameAt = Date.now(); // 마지막 프레임 수신 (ms)
let lastRotateAt = 0;
let missedRealtimeAt = 0; // 폴링이 잡은, 실시간이 놓친 메시지의 ts (교차검증 증거)
let wsGen = 0; // 소켓 세대 — 버린 소켓의 뒤늦은 onclose가 새 연결을 또 만들지 않게
let catchUpAfterOpen = false;

// 지금 소켓이 죽은 것으로 봐야 하는가. 사유 문자열(빈 문자열 = 정상).
function socketStale(nowMs) {
  if (health.socket !== 'connected') return ''; // 붙는 중이면 기존 백오프에 맡긴다
  // 실시간 이벤트를 한 번도 못 받은 워크스페이스(구독 없음)는 폴링이 정상 경로다 —
  // 그쪽 수집을 소켓이 놓친 증거로 읽으면 영원히 재개통만 하게 된다.
  if (health.realtimeAt && missedRealtimeAt > health.realtimeAt) {
    return '폴링이 실시간에 안 온 메시지를 주움';
  }
  const idle = nowMs - lastFrameAt;
  if (idle >= SOCKET_IDLE_LIMIT_MS) return `${Math.round(idle / 60_000)}분간 프레임 무수신`;
  return '';
}

function markFrame() {
  lastFrameAt = Date.now();
  health.frameAt = Math.floor(lastFrameAt / 1000); // 30초 주기 보고에 실려 나간다
}

// 소켓을 버리고 다시 개통한다. 기존 소켓의 콜백은 세대 검사로 무력화되므로 close가
// 영영 안 와도(=이 문제의 원인) 연결이 하나만 남는다.
function rotateSocket(why) {
  const now = Date.now();
  if (now - lastRotateAt < SOCKET_ROTATE_GAP_MS) return false;
  lastRotateAt = now;
  missedRealtimeAt = 0;
  health.rotations++;
  wsGen++; // 지금 소켓은 이 시점부터 남의 것 — 콜백이 와도 무시된다
  log(`소켓 재개통 (${why})`);
  setHealth({ socket: 'stale' }); // 즉시 보고 — 앱 칩이 '재연결 중'으로 내려간다
  try {
    ws?.close();
  } catch {}
  ws = null;
  backoff = 1;
  catchUpAfterOpen = true; // 눈감고 있던 구간은 30분 주기를 기다리지 않고 바로 메운다
  markFrame(); // 다음 판정은 새 소켓 기준으로
  connect();
  return true;
}

function socketWatchdog() {
  if (existsSync(DISABLED_FILE)) return;
  const why = socketStale(Date.now());
  if (why) rotateSocket(why);
}

async function connect() {
  const gen = ++wsGen; // 이 호출이 만드는 소켓의 세대
  if (existsSync(DISABLED_FILE)) {
    log('disabled file present — idling');
    setHealth({ socket: 'disabled' });
    setTimeout(connect, 60_000);
    return;
  }
  try {
    const open = await slack('apps.connections.open', {}, APP_TOKEN);
    if (gen !== wsGen) return; // 기다리는 사이 재개통됐다 — 이 소켓은 버린다
    ws = new WebSocket(open.url);
    ws.onopen = () => {
      if (gen !== wsGen) return;
      backoff = 1;
      markFrame();
      log('socket connected');
      ping('ok', '소켓 연결', '슬랙 실시간 수신 대기 중');
      // 붙었다 = 네트워크도 토큰도 정상 — 앱이 띄운 안내를 내릴 근거.
      setHealth({ socket: 'connected', failures: 0, netError: '', authError: '' });
      if (catchUpAfterOpen) {
        catchUpAfterOpen = false;
        // 재개통 = 그 직전까지 이벤트를 놓쳤을 수 있다는 뜻. 30분 주기를 기다리지
        // 않고 지금 훑는다 (reactions.list 몇 콜 — reconcile은 무거워 주기에 맡긴다).
        catchUp().catch((e) => log('재개통 catch-up 오류:', e.message));
      }
    };
    ws.onmessage = (ev) => {
      if (gen !== wsGen) return;
      // 어떤 프레임이든 = 소켓이 살아 있다는 유일한 증거 (Node 기본 WebSocket은
      // ping 프레임을 JS로 올려주지 않는다). 30초 보고에 실려 앱까지 간다.
      markFrame();
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
            // 기록은 무엇이 붙었든 남기고, 처리완료로 넘기는 것만 가른다. 이 자리가
            // resolvingReaction 을 부르지 않고 autoResolve 를 직접 부르기 때문에,
            // 위 두 함수만 고치면 실제로 도는 경로에는 예외가 적용되지 않는다 —
            // 데몬이 스스로 단 🔍 가 소켓으로 되돌아와 항목을 지운다.
            // ctx 로 넘기는 it 은 rewriteItem 이전에 읽은 것이라 ackEmoji/ackEmojis 가
            // 그대로 들어 있다. postEmojiReaction 이 reactions.add 보다 먼저 그 값을
            // 적어 두므로, 우리가 방금 단 이모지의 이벤트가 여기 도착했을 때도 항목에는
            // 이미 그 이름이 있다.
            if (isResolvingEmoji(e.reaction, { by: e.user, item: it })) autoResolve(id, e.reaction, e.user);
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
            // 정책이 none 이면 firstNonTrigger 가 언제나 null 이라 이 조건이 항상
            // 참이 된다. 그대로 두면 리액션을 하나 떼는 것만으로 예전에 자동
            // 처리완료된 항목이 전부 미처리로 돌아오는데, 그것은 라이언이 정한 것이
            // 아니다. none 아래에서는 되돌릴 자동 해결 자체가 새로 생기지 않으므로
            // 취소 경로를 통째로 건너뛴다 — 옛 autoDone 항목을 소급해서 다시 열지도
            // 않는다(원장의 auto.done 867건은 그대로 둔다).
            //
            // self 도 같은 함정을 밟는다. item.reactions 는 이름 다중집합만 저장하고
            // 누가 달았는지를 저장하지 않아서, self 아래의 firstNonTrigger 는 ctx.by 를
            // 만들 수 없어 언제나 null 이다. 그래서 "무엇이 남았는가" 가 아니라 "닫은
            // 그것이 떼어졌는가" 로 판정한다 — 항목을 닫은 이모지와 사람은 autoResolve
            // 가 autoEmoji·autoBy 로 이미 적어 두었으므로 남은 목록을 추측할 필요가
            // 없다. autoBy 가 없는 옛 레코드는 되돌리지 않는다(fail-closed 의 뜻이
            // 여기서는 "지금 상태를 유지" 다 — 무더기 재개방이 이 자리의 해악이다).
            const pol = resolvesPolicy();
            if (pol === 'self') {
              if (it.autoDone && it.autoBy && e.user === it.autoBy
                  && baseEmoji(e.reaction) === baseEmoji(it.autoEmoji)) autoUnresolve(id, it);
            } else if (pol !== 'none' && !firstNonTrigger(left)) autoUnresolve(id, it);
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
      // 구독 채널 새 메시지 → 외부 명령 디스패치. 봇이 쏜 알림이 주 대상이므로
      // 사람 메시지 기준을 그대로 쓰면 안 된다. 두 가지를 따로 푼다.
      //   1) e.user 를 요구하지 않는다 — 앱 메시지는 user 없이 bot_id 만 온다.
      //   2) isRealMessage 만으로 거르지 않는다 — 들어오는 웹훅류는 subtype 이
      //      'bot_message' 로 오고, 그러면 isRealMessage 가 false 라 이 경로가
      //      영원히 안 돈다. 아무 로그도 남기지 않고 조용히 죽는 종류의 실패다.
      // 편집·삭제·입퇴장(message_changed 등)은 아래 조건에서 계속 제외된다.
      const subOk =
        isRealMessage(e) || e.subtype === 'bot_message' || (!e.subtype && e.bot_id);
      if (e?.type === 'message' && subOk && sourceOn('channelsub')) {
        try {
          dispatchChannelSub(e);
        } catch (err) {
          log('channelsub dispatch error:', err.message);
        }
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
      if (gen !== wsGen) return; // 이미 재개통된 소켓의 뒤늦은 close — 무시
      log(`socket closed — reconnect in ${backoff}s`);
      setHealth({ socket: 'connecting' });
      setTimeout(connect, backoff * 1000);
      backoff = Math.min(backoff * 2, 60);
    };
    ws.onerror = (e) => log('socket error:', e.message || 'unknown');
  } catch (e) {
    if (gen !== wsGen) return;
    log(`connect failed (${e.message}) — retry in ${backoff}s`);
    health.failures++;
    classifyFailure(e);
    setHealth({ socket: 'connecting' });
    postHealth(); // failures/원인이 바뀌었을 수 있다 — 앱이 안내 여부를 다시 판단
    // 토큰 문제가 아닌데도 계속 못 붙으면 프로세스 안에서 고칠 수 있는 상태가
    // 아닐 수 있다 (fetch/undici가 물린 경우). 원인을 남기고 죽어 launchd가 깨끗한
    // 프로세스로 되살리게 한다 — 하트비트는 계속 나가고 있어 앱의 90초 워치독은
    // 이 상황을 못 잡는다.
    if (health.failures >= SOCKET_MAX_FAILURES && !health.authError) {
      log(`연결 실패 ${health.failures}회 — 프로세스를 재시작한다 (launchd)`);
      postHealth().finally(() => process.exit(1));
      return;
    }
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
  writeSelf(auth);
  // 데몬이 언제 뜨고 다시 떴는지 — 액션 로그가 갑자기 조용해진 구간을 설명한다.
  act('daemon.start', { detail: `pid ${process.pid} · ${auth.user}@${auth.team}` });
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
  for (const o of loomRetryAtBoot) {
    scheduleLoomRetry(o, Number(o.mediaAttempts || 0));
  }
  catchUp()
    .then(starsCatchUp)
    .then(reconcileRemoved)
    .then(backfillDecisions)
    .catch((e) => log('catch-up error:', e.message));
  // #hero 수집 — 첫 실행은 채널 전체 백필, 이후엔 커서 이후만.
  heroSync().catch((e) => log('hero sync error:', e.message));
  // 용어집 — 노션이 정본이다. 기동 때 한 번, 그다음은 아래 30분 주기에 얹는다.
  glossarySync().catch((e) => log('용어집 동기화 오류:', e.message));
  // 사람 디렉터리 — 축 0 이 읽는 캐시. 기동 때 한 번, 그다음은 아래 30분 주기에 얹되
  // 실제 조회는 TTL 6시간이 지났을 때만 한다 (users.list 는 4페이지·6초짜리 호출이다).
  peopleDirectorySync().catch((e) => log('사람 디렉터리 동기화 오류:', e.message));
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
        .then(glossarySync)
        .then(peopleDirectorySync)
        .catch((e) => log('catch-up error:', e.message)),
    30 * 60_000,
  );
  // 살아있음 보고 — 앱은 이게 90초 끊기면 데몬이 죽은 것으로 보고 스스로 되살린다.
  health.idleLimit = Math.round(SOCKET_IDLE_LIMIT_MS / 1000); // 앱 백스톱의 기준값
  health.codeAt = CODE_AT_BOOT; // 지금 도는 코드가 언제 것인지 — 화면이 이 값으로 드리프트를 보여 준다
  postHealth();
  setInterval(postHealth, 30_000);
  // 디스크의 코드가 나보다 새로우면 스스로 물러난다 (codeWatchdog 참고).
  setInterval(codeWatchdog, 30_000);
  // 소켓이 조용히 죽었는지 — 프로세스가 살아 있어도 이건 따로 봐야 한다.
  setInterval(socketWatchdog, SOCKET_CHECK_MS);
}

// ---- 코드 워치독 ------------------------------------------------------------
//
// 2026-08-31 사고. 이 데몬 프로세스는 8월 30일 17:26에 뜬 것이었는데, 8월 31일
// 13:39에 설치된 새 코드는 디스크에만 있었다. 21시간 동안 "고쳤다"와 "고친 것이
// 돈다"가 갈라져 있었고 슬랙에 나간 답은 계속 옛 코드의 것이었다. 사람은 그걸 모른 채
// 화면을 보고 0점을 줬다 — 채점된 코드는 그가 방금 고친 코드가 아니었다.
//
// 이 구멍을 아무도 안 보고 있었다. launchd KeepAlive는 프로세스가 죽었을 때만 살리고,
// 앱의 SlackHealth 워치독은 하트비트가 90초 끊겼을 때만 kickstart한다. 파일이 바뀐 것은
// 죽은 것도 조용한 것도 아니므로 둘 다 지나친다. 그래서 여기서 본다.
//
// 방식은 가장 단순한 것으로 한다 — 내가 로드한 파일이 디스크에서 더 새로워졌으면
// 스스로 나간다. launchd가 10초 뒤 새 코드로 띄운다. 이렇게 하면 누가 파일을 갈아
// 끼웠는지(build-app.sh·apply-update.sh·손으로 복사)와 무관하게 동작한다.
//
// 재시작이 공짜는 아니다(소켓 재개통, 캐치업 한 번). 그래서 기동 후 60초 안에는 보지
// 않고, 나가기 전에 사유를 원장과 하트비트에 반드시 남긴다 — 이 파일의 규칙이다.
const CODE_DIR = dirname(fileURLToPath(import.meta.url));
const CODE_FILES = [
  process.argv[1] || '',
  ...['alignment-engine.mjs', 'emoji-layer.mjs', 'answer-context.mjs', 'media-extract.mjs',
    'slack-emoji-layer.json', 'slack-reply-policy.json', 'slack-permission-policy.json',
  ].map((f) => join(CODE_DIR, f)),
].filter(Boolean);

function codeMtime() {
  let newest = 0;
  for (const f of CODE_FILES) {
    try { newest = Math.max(newest, Math.floor(statSync(f).mtimeMs / 1000)); } catch {}
  }
  return newest;
}

const CODE_AT_BOOT = codeMtime();

async function codeWatchdog() {
  if (Math.floor(Date.now() / 1000) - health.startedAt < 60) return;
  const disk = codeMtime();
  if (!disk || disk <= CODE_AT_BOOT) return;
  health.codeStale = true;
  health.codeAt = disk;
  log(`코드가 바뀌었다 (로드 ${CODE_AT_BOOT} → 디스크 ${disk}) — 새 코드로 다시 뜨기 위해 종료한다`);
  act('restart.code', { detail: `코드 변경 감지 → 자진 종료 (로드 ${CODE_AT_BOOT}, 디스크 ${disk})` });
  await postHealth();
  process.exit(0);
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
