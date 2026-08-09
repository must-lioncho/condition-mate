# Dashboard E2E

Headless behaviour checks for the dashboard logic embedded in
`Sources/ConditionManager/Dashboard/DashboardContent.swift`. Each test extracts the
*real* functions from the Swift source (so tests cannot drift from what ships) and
exercises them in Node, with Playwright/Chromium where a DOM is needed.

```sh
npm i            # installs playwright
npx playwright install chromium
npm test         # ime + source + tier + seq + ontrack
```

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
| `memogoalno.test.js` | 메모장 골번호 + 골부모 트리 — 체크리스트 줄이 보드와 같은 번호 공간에서 골번호를 받고(`POST /api/memo/seq` → `ReviewStore.reserveSeqs`, seq-floor 영속) `@골: N` 으로 왕복, `@부모: M` 칸 + 트리 정렬(자식이 부모 아래·3단 들여쓰기·표시만), 채번 전 위치 번호 폴백. parse/pnum 은 실제로 돌려 본다 |
| `zenflap.test.js` | Zen 창 시작/중단 펄럭임 방지 — 낙관적 클릭 래치(cmChPendWant)가 스테일 `/api/session/state` 폴의 반대 상태·이전 시계·이전 모드를 무시하고, 서버 확인(또는 8초 만료) 시 해제. 시나리오는 `zenflap.scenario.md` |
| `memoloop.test.js` | 메모장 루프 — 보기 콤보의 '루프 종료' 가 완료 줄에 `@루프: <코드>` 스탬프(왕복 항등), 스탬프 줄은 기본(현재 루프)에서 CSS 로만 감춤, '이전 루프 포함' 은 완료 체크와 다른 축, 상태 개수는 현재 루프만, 루프 번호=보드 스프린트/릴리즈 코드와 한 일련번호(현재=열린 스프린트 26-38 · 이전=최신 릴리즈 26-37, 보드 없으면 숫자 폴백 #N), 종료=⌘Z 한 단계, 완료에서 벗어나면 스탬프 해제, 미완료 줄 밑 `@루프` 는 상세로 보존. 릴리즈 컷의 서버측 수확(스탬프+릴리즈 notes)은 `../Scripts/e2e-memo-loop.sh` |

Backend (real HTTP server, isolated data dir) E2E lives in `../Scripts/e2e-goal-*.sh`.

## 시각 확인 (memo-stub)

`memostub.js` 는 `memosrc.js` 로 뽑은 **실제** 레일/메모장 CSS·JS 를 `/goal-add` 모양의 페이지에
얹어 8933 포트로 띄운다(메모 API 는 인메모리). 앱을 실행하지 않고 3단계 전환·문서형 레이아웃·
좁은 창(≤360px) 접힘을 브라우저에서 눈으로 확인할 때 쓴다 — 앱 포트는 절대 빌려 쓰지 않는다.

```sh
node .e2e/memostub.js     # → http://127.0.0.1:8933  (또는 .claude/launch.json 의 memo-stub)
```
