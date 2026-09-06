# 슬랙에 남긴 리액션이 컨디션 메이트에 반영되지 않는 구조적 원인 판정 — 작업지시서

- id: 2026-09-06-0132-condition-mate-slack-reaction-sync
- 트랙: BEST · 규모 P2 · 레벨 L1
- 트랙 카드: /Users/lioncho/Work/lion_work/organization/lion/lion-work-queue/inbox/2026-09-06-0132-condition-mate-slack-reaction-sync.md
- 작성: lion-condition-mate PO 자리 (이 세션), 2026-09-06
- 완성 조건: 구조 원인 판정. 코드 수정·배포는 이번 범위 밖이다.

## 원문

> 컨디션 메이트 이용이
> 디렉터 에이전트 위임하고
> https://mustcompany.slack.com/archives/D03GL66BWBX/p1788514852453719
> [스크린샷 첨부] 이거 같은 경우는 이미 벌써 내가 이모지를 슬랙에서 남겼거든 근데 여전히 슬랙 컨디션 어플리케이션에서는 여전히 이게 체크가 안되어 있어 그래서 이게 뭔가 서로 동기화되는 느낌이 지금 없어 소켓이 끊긴 건지 뭔지 모르겠지만 구조적인 원인이 무엇이고 내가 볼 때 구조적 원인은 소케들을 제대로 사용 안 한 걸로 보이거든

첨부 스크린샷: 컨디션 메이트 "Slack 번역" 화면. DM·멘션 카드가 9/4 15:39~19:11 시각으로 쌓여 있고, 라이언이 슬랙 본체에서 이미 리액션을 남긴 메시지가 이 화면에서는 여전히 미처리로 남아 있다.

## 무엇을 판정하는가

라이언의 가설은 "소켓을 제대로 안 썼다" 다. 이 지시서는 그 가설을 참/거짓으로 가른다. 가르는 축이 셋이다.

1. **소켓이 실제로 살아 있는가.** `slack-eyes-daemon.mjs` 는 Socket Mode(`apps.connections.open` + WebSocket)를 쓰고, 조용히 죽은 소켓을 잡으려고 `socketStale`/`rotateSocket` 워치독까지 들고 있다. 프로세스가 도는 것과 소켓이 사는 것은 다르므로 `health`(`frameAt`, `realtimeAt`)와 데몬 로그의 실제 프레임 수신을 본다.
2. **`reaction_added` 를 구독하고 처리하는 경로가 있는가.** 있다면 그 이벤트가 항목 상태까지 도달하는가.
3. **도달해도 항목을 닫지 않게 되어 있는가.** `Sources/Plugins/Slack/Daemon/slack-emoji-layer.json` 의 `resolvesPolicy` 가 이 축이다. 2026-09-02 에 이 값이 `none` 으로 정해졌고, 그 뜻은 "어떤 리액션도 항목을 닫지 않는다. 미처리는 손으로 닫는다" 다.

세 축은 서로 배타적이지 않다. 하나가 참이어도 나머지를 확인해야 화면에서 본 현상 전체가 설명된다.

## 왜 이 세 축인가 — 문제의 번역

라이언이 본 것은 "슬랙에 이모지를 남겼는데 앱에서 체크가 안 된다" 이고, 그가 읽은 원인은 "전송로가 끊겼다(소켓)" 다. 그런데 이 코드베이스에는 **전송로와 정책이 갈려 있다.** 이벤트가 도착하는 것과 그 이벤트가 항목을 닫는 것이 다른 자리에서 결정된다.

그래서 이 요구를 "소켓 진단" 으로 번역하면 절반만 답하게 된다. 소켓이 멀쩡한데도 같은 화면이 나오는 경로가 코드에 실재하기 때문이다 — 2026-09-02 에 라이언 본인이 그렇게 만들라고 지시했고, 그 결정이 `resolvesPolicy: "none"` 한 줄로 구현되어 있다. 그 경우 이것은 고장이 아니라 **결정과 기대가 갈라진 것**이고, 고칠 대상은 코드가 아니라 그 결정 또는 화면의 표현이다.

따라서 이 일의 문제는 "소켓이 끊겼는지 본다" 가 아니라 **"화면에 남은 미처리가 전송 실패인지, 정책상 의도인지, 아니면 커버리지 한계인지를 실측으로 가르는 것"** 이다. 셋의 처방이 전부 다르다 — 전송 실패면 데몬을 고치고, 의도면 라이언의 결정을 다시 받고, 커버리지 한계면 범위를 넓힌다.

넷째 후보도 같이 본다. `reconcileRemoved()` 가 열린 항목의 **최신 30건만** 훑는다(`open.slice(-30)`). 화면의 항목은 9/4 것이고 백로그가 30건을 넘으면 원리적으로 검사 대상 밖이다. 이것은 정책도 소켓도 아닌 세 번째 종류의 원인이다.

## 근거로 삼는 자리

- `Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs` — 소켓 개통·워치독·`reaction_added`/`reaction_removed` 처리·`reconcileRemoved()`·`resolvesPolicy()`
- `Sources/Plugins/Slack/Daemon/slack-emoji-layer.json` — `resolvesPolicy`, 행별 `resolves`
- `Sources/Plugins/Slack/SlackTranslateStore.swift` — `done.json` 소유자, `/api/slack/done`, `/api/slack/reaction`
- `Sources/Plugins/Slack/SlackTranslateContent.swift` — 화면이 처리완료를 그리는 규칙
- `Sources/Plugins/Slack/SlackHealth.swift` — 앱이 데몬 생사를 판정하는 자리
- 실측: `~/.condition-mate/slack-translate/` 의 `items.jsonl`·`done.json`·`health.json`·`config.json`, 데몬 로그, `launchctl list`
- 배포본 대조: `/Applications/ConditionMate.app/Contents/Resources/` — 도는 것은 소스가 아니라 번들 사본이다
- 문서: `docs/slack-socket-mode-plan.md`, `docs/slack-ack-two-axis-design.md`, `docs/slack-context-analysis-levels.md`, `issue/2026-09-01-slack-미처리-상태축.md`

## 이번에 하지 않는 것

- 코드를 고쳐 배포하지 않는다. 고칠 방향을 적는 것까지가 원인 판정의 일부다.
- 슬랙이나 외부로 아무것도 발신하지 않는다.
- 데몬을 재시작하거나 `resolvesPolicy` 값을 바꾸지 않는다. 값을 바꾸는 것은 라이언의 결정이다.

## 가정 (L1 — 묻지 않고 정하고 진행한 것)

- 라이언이 말한 "이모지" 는 트리거 이모지(👀/🔖/📌) 제거가 아니라 **일반 리액션 추가**를 뜻한다고 본다. 스크린샷 항목이 DM·멘션이라 트리거 이모지가 원래 없기 때문이다.
- "체크가 안 되어 있다" 는 화면의 처리완료 표시를 뜻한다고 본다.
- 완성은 판정 문서 하나다. 수정 PR 은 만들지 않는다.

## 1초 요약

요구 — 이미 슬랙에서 이모지를 남겼는데 컨디션 메이트에서는 여전히 체크가 안 되어 있다, 구조적 원인이 무엇이고 소켓을 제대로 안 쓴 것 아니냐.
문제 — 화면에 남은 미처리가 소켓 전송 실패인지, 2026-09-02 `resolvesPolicy:none` 결정대로의 의도된 동작인지, `reconcile` 최신 30건 상한이 만든 커버리지 구멍인지를 실측으로 가르는 것. 셋은 처방이 전부 다르다.
완성 — 세 후보 각각에 대해 로그·데이터 실측 근거가 붙은 참/거짓 판정이 나오고, 라이언의 소켓 가설이 맞았는지 틀렸는지가 명시되며, 고칠 방향이 원인별로 적힌 문서가 issue/ 아래에 남는다.
