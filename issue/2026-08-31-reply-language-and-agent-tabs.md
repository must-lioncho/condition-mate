# 2026-08-31 — 답변 언어가 상대를 안 따라간 것, 그리고 카드 한 덩어리

라이언이 스크린샷 두 장과 함께 지시한 건이다. 증거는 `issue/assets/` 에 복사해 두었다.

- `assets/2026-08-31-slack-yashal-korean-reply.png` — 실제로 슬랙에 나간 답변
- `assets/2026-08-31-dashboard-card-one-blob.png` — 대시보드 카드 (미처리 226 / 전체 1557)

## 1. 무슨 일이 있었나 — 언어 판정은 맞았고, 모델이 안 지켰다

야샬(Yashal Nawaid, `U0BKH9ACC23`)의 영어 메시지에 대해 라이언 계정으로 나간 답변이
머리줄만 영어이고 본문 전체가 한국어였다.

원장으로 확인한 사실:

- `people-roster.json` 의 `U0BKH9ACC23` 은 `replyLanguage: "en"` (Pakistan / Karachi,
  근거 `slack-profile`). 판정 자체는 맞았다.
- 원문이 영어이므로 `replyLanguage()` 의 1순위(원문)에서도 `en` 이 나온다.
- 나간 글의 머리줄이 `Read as: …` / `This is an agent answer for now.` 였다. 이 두 줄은
  렌더러가 `input.language === 'ko'` 로 갈라 찍는다. 영어로 찍혔다는 것은 파이프라인에
  `language = 'en'` 이 실제로 흘렀다는 뜻이다.
- 그런데 `meaning_label`, `meaning`, `options[].action`, `likely_reason` 이 전부 한국어였다.
  이 값들은 모델이 쓴다. 프롬프트에는
  `Write descriptive fields in English.` 한 줄이 있었을 뿐이고, 그 아래로 `<context>`,
  `<prior>`(직전 한국어 답변), 스레드 부모 메시지(양호영, 한국어)가 전부 한국어로 깔려 있었다.
  Gemini Flash-Lite 가 지시 한 줄이 아니라 주변 언어를 따라갔다.

즉 **판정 버그가 아니라 강제 부재다.** 결정된 언어를 출력이 실제로 지켰는지 확인하는
자리가 어디에도 없다.

### 나간 것은 이미 지운 렌더러였다

원장의 `ackFormat: "v2"`. `/Applications/ConditionMate.app` 은 14:33 빌드이고 v2 렌더러를
싣고 있다. 작업 트리(`Sources/Plugins/Slack/Daemon/alignment-engine.mjs`)는 이미 v3 로
바뀌어 v1·v2 렌더러를 지웠지만 **커밋도 빌드도 되지 않았다.** 사고는 14:47 에 났다.
v3 는 `meaning`/`decision` 을 슬랙으로 내보내지 않으므로 이 사고의 모양 자체는 v3 를
배포하면 사라진다. 다만 `reply` 필드의 언어를 강제하는 자리가 없는 것은 v3 도 같다.

## 2. 언어 판정 규칙이 지금 몇 곳에 있나

정본은 `slack-eyes-daemon.mjs` 의 `replyLanguage(text, authorId, ctx)` 하나다.
순서는 원문 → 스레드 → 명부(`rosterLanguage` → `countryLanguage`).

같은 규칙의 사본이 두 곳 더 있다. 둘 다 `language` 가 없을 때를 대비한 폴백이다.

- `securityBlockedReply()` — `hasEnglishSentence(text) && hangulRatio(text) < 0.25`
- `routingReply()` — 같은 식

호출부는 항상 `language` 를 넘기고 있으므로 이 폴백은 지금은 안 돈다. 그래도 규칙이
세 곳에 적혀 있는 상태이므로 지워서 한 곳으로 만든다.

## 3. 대시보드 카드 — 세 산출물이 한 덩어리로 나온다

카드 본문은 `Sources/Plugins/Slack/SlackTranslateContent.swift` 의 `render()` 안
`itemHTML` 하나가 통째로 찍는다 (원문 → 영어본 → 첨부 → `의미 분석` → `의사결정` → 내 답장).
탭도 없고 스레드 묶음도 없다.

레코드에 이미 있는 것 (`items.jsonl` 최근 500건 기준):

| 필드 | 뜻 |
| --- | --- |
| `textEn` / `textKo` | 원문 / 번역 |
| `meaning`, `decision` | 컨텍스트 에이전트 산출 |
| `lang`, `model`, `trMs` | 번역 목표 언어(=대시보드 셀렉트), 모델, 소요 |
| `threadTs` | 스레드 묶음 키 (500건 중 269건) |
| `ackAt`, `ackTs`, `ackFormat`, `ackGrade` | 발신 성공 |
| `ackBlockedAt`, `ackBlockedReasons` | 발신 차단과 사유 코드 |
| `ackSupersededAt` | 나중 답변으로 대체됨 |
| `securityBlocked`, `securityKind` | 보안 게이트 차단 |
| `autoReplyPolicy` | 애초에 자동응답 대상이 아님 |

레코드에 **없는 것** — 탭을 채우려면 데몬이 추가로 남겨야 한다:

- `ackLang` — 실제로 어느 언어로 나갔는가. (`lang` 은 번역 목표 언어이지 발신 언어가 아니다.)
- `ackBody` — 실제로 나간 본문. 지금은 `ack-threads.json` 의 `history[]` 에만 있고 대시보드는 읽지 않는다.
- `ackNoRequestAt` / `adds` 빈 값으로 침묵한 건의 기록.

## 4. 어디를 고치는가

| 할 일 | 파일 |
| --- | --- |
| 판정 규칙 한 곳으로 (`securityBlockedReply`·`routingReply` 폴백 삭제) | `Daemon/slack-eyes-daemon.mjs` |
| 결정된 언어를 출력이 지켰는지 결정적으로 검사 → 1회 재생성 → 그래도 어기면 차단·사유 기록 | `Daemon/alignment-engine.mjs` (검사기) + `slack-eyes-daemon.mjs` (호출) |
| 프롬프트의 언어 지시를 한 줄에서 못박는 자리로 | `Daemon/alignment-engine.mjs` `extractionPrompt` |
| `ackLang`·`ackBody`·침묵 사유를 레코드에 남김 | `Daemon/slack-eyes-daemon.mjs` |
| 카드 상단 탭 3개 + 스레드 묶음 | `SlackTranslateContent.swift` |
| v3 배포 (지금 트리는 미커밋·미빌드) | `Scripts/build-app.sh` |

## 5. 라이언이 정한 것 (2026-08-31)

- 수신자 언어는 **명부 우선, 단 근거가 있을 때만**. 프로필 국가·GitHub 로 근거가 실제로
  있는 사람은 그 언어로 고정하고, 근거가 없는 사람만 원문 → 스레드 순으로 본다.
  근거 없이 기본값 `en` 이 박힌 항목까지 우선하면 프로필이 빈 한국 사람에게 영어가
  나가므로, `rosterIsDecisive()` 가 그 둘을 가른다.
- v3 배포는 **고친 뒤 한 번에**.

## 6. 한 것

| 무엇 | 어디 |
| --- | --- |
| 판정·검사 규칙을 한 파일로 신설 | `Daemon/reply-language.mjs` (신규) |
| 데몬의 사본 셋 제거 (`hangulRatio`·`hasEnglishSentence`·`countryLanguage`·`replyLanguage` 및 `routingReply`/`securityBlockedReply` 폴백) | `Daemon/slack-eyes-daemon.mjs` |
| 언어 지시를 프롬프트 맨 앞과 **맨 뒤** 두 자리에 못박음 | `Daemon/alignment-engine.mjs` |
| 출력 언어 검사 → 1회 재생성 → 그래도 어기면 발신 차단(`LANGUAGE_MISMATCH`) | `Daemon/slack-eyes-daemon.mjs` |
| `ackLang`·`ackLangBasis`·`ackBody`·`ackLangRetried` 를 레코드에 남김 | `Daemon/slack-eyes-daemon.mjs` |
| 카드 상단 탭 3개(의사결정 기본) + 스레드 묶기 토글 | `SlackTranslateContent.swift` |
| `reply-language.mjs` 를 앱 번들 복사 목록에 추가 (정적 import — 빠지면 데몬이 안 뜬다) | `Scripts/build-app.sh` |
| 시험 | `Daemon/reply-language.test.mjs`(18), `.e2e/slacktabs.test.js`(23) |

### 임계값은 실측으로 정했다

`KOREAN_IN_ENGLISH_MAX = 0.15`. 근거는 `ack-threads.json` 과 `replies.json` 의 실제 본문이다.
야샬 건에 나간 한국어 본문이 0.575 / 0.561, 영어로 나간 정상 답장이 0.000(4건),
한국어 정상 답장이 0.925. 0.00 과 0.56 사이가 비어 있어 0.15 에 여유가 있고, 영어 답변이
한국 사람 이름을 병기하는 것은 통과한다.

### 배포

`./Scripts/build-app.sh` 로 빌드·설치·재기동까지 끝냈다. `/Applications/ConditionMate.app`
의 `LATEST_REPLY_FORMAT` 이 `v3` 이고 `reply-language.mjs` 가 번들에 실렸다. 데몬은
`socket connected` 로 다시 붙었다.

## 7. 남은 것 — 내 변경 밖의 사실

**명부에 3명뿐이다.** 코퍼스의 발신자 85명 중 `people-roster.json` 에 항목이 있는 사람은
Yashal, 그리고 India·Korea 각 1명, 모두 3명이다. 그래서 오늘 기준으로 "명부 우선"이
실제로 갈리는 사람은 3명이고 나머지 82명은 여전히 원문 언어로 정해진다. 새 순서에서는
답할 때마다 명부를 먼저 조회하므로 답이 나간 사람부터 하나씩 채워지고(7일 캐시),
그만큼 사람 고정도 하나씩 켜진다. 85명을 미리 채우려면 `users.profile.get` 을 85번
부르면 되지만 그것은 이 건의 범위가 아니라 따로 정할 일이다.

**`people-context.mjs` 가 앱 번들에 없다.** 배포 직후 데몬 로그에
`people-context 없음 — 축 0 없이 예전대로 답한다` 가 찍힌다. 트리에는 파일이 있고
`Scripts/build-app.sh` 의 복사 목록에만 빠져 있다. 동적 import 라 데몬이 죽지는 않고
축 0 만 조용히 꺼진 상태다. 앞선 미커밋 작업의 배포 누락이고 내 변경과 무관해서
손대지 않았다 — 켤지는 라이언이 정한다.

**`.e2e/slackanswer.test.js` 가 깨져 있다.** `ackEvidence` 안에서 부르는
`peopleContextModule` 을 추출 목록에 넣지 않아 `ReferenceError` 로 죽는다. 이것도 앞선
미커밋 작업의 것이고, `test:slack` 이 `&&` 사슬이라 이 파일에서 멎으면 뒤의
`slackalignment`·`slackemoji` 가 안 돈다. 두 파일은 따로 돌려 통과를 확인했다.
