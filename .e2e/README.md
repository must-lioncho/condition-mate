# Dashboard E2E

Headless behaviour checks for the dashboard logic embedded in
`Sources/ConditionMate/Dashboard/DashboardContent.swift`. Each test extracts the
*real* functions from the Swift source (so tests cannot drift from what ships) and
exercises them in Node, with Playwright/Chromium where a DOM is needed.

```sh
npm i            # installs playwright
npx playwright install chromium
npm test         # ime + source + tier + seq + ontrack
npm run test:slack        # 슬랙 전부 (데몬 7종 + 브라우저·Swift 4종)
npm run test:slackdaemon  # 슬랙 데몬만 — 브라우저 없이 1초대, media/defects/compat/degrade/pipe/answer/emoji
```

`slack*.test.js` 중 데몬 쪽 7종은 `Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs` 에서
실제 함수를 떼어내(또는 데몬을 통째로 import 해) 돌린다. `slackcompat.test.js` 와
`slackdefects.test.js` 의 실측 항목은 `~/.condition-mate/slack-translate/items.jsonl` 을
**읽고 사본에만** 쓰며, 그 파일이 없는 환경에서는 건너뛰고 그 사실을 출력한다.

| File | Covers |
| --- | --- |
| `ime.test.js` / `source.test.js` | Korean IME composition — Enter must not leak the trailing syllable as a duplicate goal |
| `tier.test.js` | Activity-log tier smoothing (10-min carry-forward, neighbor agreement) |
| `seq.test.js` | Stable `goal-NN` numbers — immutable across drag-and-drop reorder |
| `ontrack.test.js` | Derived parent "on track" rollup from child task status |
| `slackretrig.test.js` | Slack 번역함 재트리거 — 👀를 다시 달면 기존 항목이 미처리 맨 위로 (triggeredAt 정렬) |
| `memostage.test.js` | 메모장 + 사이드바 3단계 — ⊞ 순환(0→1→2)·⌥역방향·Esc 복귀, 단계 영속/구키 마이그레이션, 좁은 창(≤360px) 강제 메모장, zen 가드, 메모 자동저장(디바운스·blur flush·조용한 실패). `SessionRail.swift`/`MemoPad.swift` 원본을 잘라 vm 컨텍스트(= 브라우저처럼 window가 전역)에서 실행 |
| `slackhealth.test.js` | Slack 데몬 자가 진단·자가 복구 — 자동 복구 중엔 조용, 사용자만 풀 수 있는 상태(차단·토큰·복구 실패)에만 안내. `SlackHealth.swift`를 실제로 컴파일해 판정을 돌린다 |
| `memosave.test.js` | 메모장 저장 신뢰 — 판번호(base) 왕복, 판 어긋남 시 합집합 병합(어느 쪽 글도 안 버림), 포커스 새로고침, 로컬 초안 복구, 로드 전 타이핑이 서버 글을 안 덮음. 실제 Chromium + MemoStore.save(base:) 규칙의 in-page /api/memo |
| `memoultra.test.js` | 메모장 초집중(2026-08-13 구조 교체) — 초집중에서는 행 편집기가 내려가고 지금 덩어리 하나만 담는 textarea 하나가 남는다. 첫 줄=제목·나머지=상세로 즉시 행에 반영(왕복 항등), 빈 덩어리에 쓰기 시작하면 날짜·시각 머리글 자동, 한글 조합 중에는 끼어들지 않음, ↑↓ 는 첫/마지막 줄에서만 앞뒤 덩어리(마지막에서 ↓ = 새 덩어리), 나가면 행 편집기 그대로 복귀. 기본 모드 규칙은 불변 |
| `memogoalno.test.js` | 메모장 골번호 + 골부모 트리 — 체크리스트 줄이 보드와 같은 번호 공간에서 골번호를 받고(`POST /api/memo/seq` → `ReviewStore.reserveSeqs`, seq-floor 영속) `@골: N` 으로 왕복, `@부모: M` 칸 + 트리 정렬(자식이 부모 아래·3단 들여쓰기·표시만), 채번 전 위치 번호 폴백. parse/pnum 은 실제로 돌려 본다 |
| `zenflap.test.js` | Zen 창 시작/중단 펄럭임 방지 — 낙관적 클릭 래치(cmChPendWant)가 스테일 `/api/session/state` 폴의 반대 상태·이전 시계·이전 모드를 무시하고, 서버 확인(또는 8초 만료) 시 해제. 시나리오는 `zenflap.scenario.md` |
| `slackextract.test.js` | Slack 번역함 ⋮ 세션 추출 — 세션이 없는 항목엔 단순 추출·컨텍스트 공유하기 두 갈래, 연결된 항목엔 세션 이어가기 하나. 컨텍스트 공유하기는 목표를 받아야 시작하고, goal-add 로 `slackCtx=1`·`preset=slack`·짧은 제목을 넘기며 첫 턴 초안 맨 앞에 `[목표]` 를 박는다 |
| `slackmedia.test.js` | Slack 데몬 첨부 근거 파이프라인 — 본문이 비어도 파일·링크·attachments 가 있으면 수집하고 셋 다 없으면 예전처럼 버린다. 텍스트 전용 메시지의 원문 조립과 첨부 없는 Gemini/Anthropic 요청 본문은 예전과 완전히 동일(기존 경로 무변경), 첨부 근거가 없으면 프롬프트에 `<attachments>` 자체가 안 생김, 비전 거절 시 추출 텍스트만으로 재시도, 키(gemini/anthropic/slack)가 media 행·프롬프트 어디에도 안 남음, media 행엔 계약된 필드만 남고 base64 원본은 절대 안 들어감 |
| `slackdefects.test.js` | 번역 품질 결함 8종(A~H) — A 이모지 shortcode 해석(커스텀 별칭·skin-tone·순환 별칭·12:30 오인 금지), B `*굵게*` 제거(한국어 조사 O, 곱셈·글롭 X), C "표시텍스트 (URL)" 중복 제거, D 미번역 감지 후 재시도, E 모델의 번역 거부에서 원문 보존(kept-original), F `===MEANING===` 마커 변형 관대 파싱, G 퍼머링크 원 메시지 인용(depth 1·3건 상한), H 봇 이름 조회와 실패 캐시 금지. 실 코퍼스가 있으면 실측까지 하고, 없으면 그 항목만 skip |
| `slackcompat.test.js` | `items.jsonl` 하위 호환 — 실 코퍼스 **사본**에 실제 `rewriteItem` 을 돌린다(원본은 읽고 복사만, 끝에 크기·수정시각으로 무변경 확인). 새 필드(media/mediaAt/trNote)는 전부 선택 항목이라 없는 옛 줄과 있는 새 줄이 한 파일에 섞여 살고, 읽는 쪽은 기본값으로 넘어간다. 패치는 대상 한 줄만 바꾸고(append 아님) 나머지는 바이트 단위로 그대로, undefined 패치는 키를 만들지 않는다. 코퍼스가 없는 환경에서는 통째로 skip |
| `slackdegrade.test.js` | `media-extract.mjs` 유무에 따른 degrade — 모듈이 없거나·던지거나·export 가 계약과 달라도 데몬은 죽지 않고 텍스트 전용으로 내려앉는다(첨부는 이름·링크만). 모듈 예외 메시지에 섞인 토큰은 로그에 찍히기 전에 가려진다. 데몬 소스를 임시 디렉터리로 복사해 실제로 동적 import 하므로 경로 해석까지 진짜로 돈다 — 앱 번들에 이 모듈이 빠졌던 배포 결함이 크래시 없이 드러난 경로가 여기다 |
| `slackpipe.test.js` | 원문 정리 파이프라인 통합 — 쪼갠 함수가 아니라 데몬을 통째로 import 해 실제 `cleanText`/`composeSource` 경로에서 A(이모지)·B(마크업)·C(URL 중복) 가 한 번에 적용되는지, 같은 규칙이 인용(attachments) 경로에도 적용되는지 본다. 슬랙 토큰이 없어 `users.info`·`emoji.list` 가 전부 실패하는 상태(= `emoji:read` 스코프 없음)에서도 나머지가 다 돌아야 한다 |
| `slackanswer.test.js` | 선응답 컨텍스트 레이어 — 용어집·공유 문서(Notion)·공개 웹 리서치·다른 스레드·권한 등급. 레이어 하나가 터지거나 마감을 넘겨도 선응답은 나가고, 등급으로 빠진 근거는 빈 값이 아니라 `withheld` 로 프롬프트에 남는다 |
| `slackemoji.test.js` | 이모지 레이어 — 글 대신 리액션 하나로 끝내는 자리의 판정. "Understood, thank you. I'll proceed…" 가 🫡 로 떨어지고(예전엔 여기에 `Cannot answer` 3줄이 붙었다), 묻거나 요청하거나 막혀 있는 메시지는 이모지로 새지 않으며, 이 데몬 자신의 수집 트리거(👀·📌·🔖)는 어휘집을 덮어써도 봇이 달지 않는다. 이모지의 뜻은 `slack-emoji-layer.json` 이 정본 — ✅ 는 동의가 아니라 '체크만 했다' 다 |
| `memoloop.test.js` | 메모장 루프 — 보기 콤보의 '루프 종료' 가 완료 줄에 `@루프: <코드>` 스탬프(왕복 항등), 스탬프 줄은 기본(현재 루프)에서 CSS 로만 감춤, '이전 루프 포함' 은 완료 체크와 다른 축, 상태 개수는 현재 루프만, 루프 번호=보드 스프린트/릴리즈 코드와 한 일련번호(현재=열린 스프린트 26-38 · 이전=최신 릴리즈 26-37, 보드 없으면 숫자 폴백 #N), 종료=⌘Z 한 단계, 완료에서 벗어나면 스탬프 해제, 미완료 줄 밑 `@루프` 는 상세로 보존. 릴리즈 컷의 서버측 수확(스탬프+릴리즈 notes)은 `../Scripts/e2e-memo-loop.sh` |

| `devicecron.test.js` | 크론 페이지 '이 디바이스 등록' 탭 — launchd/crontab 스캔 결과의 표시와 필터. 상태 우선순위(꺼짐 > 미로드 = plist만 있고 launchd에 없음 > 오류 = 마지막 종료 코드 != 0 > 동작 중/대기), 사람 이름이 앞·reverse-DNS 라벨은 보조 줄, 프로젝트 칩과 자동 생성되는 프로젝트 셀렉트, 보기 필터(동작 중만/문제만/전체 × 프로젝트)와 '숨김 N개' 안내가 활성 탭 것만 쓰는지, '자세히'가 target=_blank 없이 앱 창 안에서 열리는지. `AppDelegate.cronPage` 의 실제 JS를 잘라 돌린다 |

Backend (real HTTP server, isolated data dir) E2E lives in `../Scripts/e2e-goal-*.sh`.

## 시각 확인 (memo-stub)

`memostub.js` 는 `memosrc.js` 로 뽑은 **실제** 레일/메모장 CSS·JS 를 `/goal-add` 모양의 페이지에
얹어 8933 포트로 띄운다(메모 API 는 인메모리). 앱을 실행하지 않고 3단계 전환·문서형 레이아웃·
좁은 창(≤360px) 접힘을 브라우저에서 눈으로 확인할 때 쓴다 — 앱 포트는 절대 빌려 쓰지 않는다.

```sh
node .e2e/memostub.js     # → http://127.0.0.1:8933  (또는 .claude/launch.json 의 memo-stub)
```
