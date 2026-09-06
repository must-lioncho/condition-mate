# 루프 엔지니어링 — 이름 변경과 화면 개편 제안

작성: 2026-08-23 · 브랜치 `feat/dashboard-value-pipeline`
대상: `/orchestration` 페이지와 그 뒤의 재구성 코드
참조 모델: `/Users/lioncho/Work/departtment_service/projects/org-globalmpc/globalmpc-marketing/agent-ops/`
(`LOOP_DIAGRAM.md`, `LOOP_ENGINEERING.md`, `loop_engineering.py`, `PIPELINE.md`, `HUMAN_BOTTLENECK.md`, `BACKLOG_RULES.md`, `loop_engineering_history.jsonl`, `00_NOW.md`)

이 문서는 제안서다. Swift 소스는 한 줄도 고치지 않았다.

## 한 눈에 (원시인 버전)

이름 바꾸는 것은 작다. 파일 9개, 줄 30개다. 부수는 것 없다.
화면은 크다. 지금 화면은 병목을 28개 말한다. 28개는 0개와 같다.
사람이 병목이다. 97퍼센트. 에이전트 12시간 일할 때 사람 393시간 기다리게 했다.
새로 잰 것이 있다. 서브에이전트 속 기록이 디스크에 있다. 문서는 없다고 적혀 있다. 틀렸다.
루프 정의는 있다. 에이전트 프롬프트 안에만 있다. 이벤트를 적는 곳이 없다. 그래서 그림을 못 그린다.
할 것. 병목 한 줄과 대기 큐부터. 프로젝트 카드 28개는 그대로 아래 둔다.

---

## 0. 조사한 것과 근거

이 제안의 모든 수치는 오늘 이 맥에서 직접 잰 것이다.

- 실행 중인 앱의 실제 피드: `GET http://127.0.0.1:57797/api/orchestration` (포트는 `~/.condition-mate/dashboard.port`).
  응답 29,433바이트. `scannedAt` 2026-08-23T14:29:32Z.
- 세션 트랜스크립트 원본: `~/.claude/projects` 아래 811개 파일, 합계 690MB.
- 앱 대시보드 데이터: `GET /data.json` — goal 815건.
- 에이전트 실행 원장: `~/.condition-mate/ledger/agent-update-log.jsonl` 49줄.
- 빌드 기준선: `swift build` → `Build complete!` (변경 전 상태에서 통과 확인).

---

## 1. 지금 화면이 실패하는 지점 — 왜 병목이 안 보이는가

사용자의 말은 "병목이 어디인지도, 어떻게 푸는지도 모르겠다"였다. 코드와 실제 피드를 보면 그 말이 정확하다.

### 1-1. 병목을 28번 말한다

`orchestrationJSON()`(`Sources/ConditionMate/AppDelegate.swift:5125`)은 프로젝트마다 판정 사다리를 돌려 `verdict` 를 하나씩 붙인다(`AppDelegate.swift:5324-5365`). 오늘 실측 결과는 프로젝트 28곳, 판정 28개다. 내역은 끊긴 홉 3, 진입점 8, 파트 13, 측정 불가 3, 없음 1이다.

판정은 프로젝트 안에서만 사다리를 탄다. 프로젝트 사이에는 순위가 없다. 정렬은 `dead → runs → 이름` 순(`AppDelegate.swift:5390-5397`)이라 "가장 비싼 병목"이 아니라 "끊긴 홉이 있는 것"이 위로 온다. 화면 어디에도 "지금 제일 아픈 것 하나"가 없다.

참조 모델에는 그 하나가 있다. `LOOP_ENGINEERING.md` 는 첫 줄이 "사람이 병목이다. 95.4퍼센트."다. 숫자 하나, 문장 하나다.

### 1-2. 목록의 절반 이상이 지금 존재하지 않는 폴더다

28곳 중 17곳이 `gone:true`, 즉 이미 사라진 작업 폴더다. 5곳은 실행 기록이 0이다. 화면을 열면 눈에 먼저 들어오는 것이 `condition-manager`, `globalmpc-webapp`, `MPC` 같은 과거 경로들이고, 지금 손댈 수 있는 저장소는 10곳뿐이다.

### 1-3. 가장 큰 숫자가 위임의 절반만 덮는다

요약 카드의 "위임에 쓴 시간 3.7h"(`OrchestrationContent.swift:154`)는 `done` 홉만 더한 값이다. 실측 홉 84건의 내역은 완료 37, 백그라운드 42, 끊김 5, 결과없음 0이다. 즉 위임의 50퍼센트가 시간 합계에서 통째로 빠져 있다. 화면은 그 사실을 주석으로 설명하지만(`OrchestrationContent.swift:172-173`), 설명이 붙은 숫자는 여전히 반쪽이다.

### 1-4. 어떤 행도 누를 수 없다

`routeRow()`(`OrchestrationContent.swift:186-208`)와 `verdictHtml()`(`:178-184`)가 만드는 것은 전부 텍스트다. 링크도 버튼도 없다. 병목을 읽은 뒤 할 수 있는 일이 화면에 하나도 없다. `projCard()` 의 `onclick` 은 아코디언 펼치기뿐이다(`:270-275`).

### 1-5. 시간축이 없다

`payload` 에 `scannedAt` 하나만 있다(`AppDelegate.swift:5424`). 어제보다 나아졌는지 나빠졌는지 알 방법이 없다. 참조 모델은 `loop_engineering_history.jsonl` 에 매 실행 한 줄을 append 한다(`loop_engineering.py:290-294`). 이 앱에는 그에 해당하는 파일이 없다.

---

## 2. 사용자가 묻지 않았지만 답해야 하는 질문 — Condition Mate 에 정의된 루프가 있는가

### 답: 있다. 그런데 두 군데가 비어 있어서 그림을 그릴 수 없다.

**있는 것 하나 — L1부터 L9까지의 단계 정의.** 오늘 만들어진 에이전트 정의 `.claude/agents/lion-condition-mate-po-loop-engineering.md` 안에 "The Condition Mate loop, stage by stage" 절이 있고, 거기 아홉 칸이 이름·담당·완료조건·경보 임계와 함께 적혀 있다. 요약하면 L1 목표 접수(사람), L2 수용 기준 확정(PO), L3 제안과 지시서(`lion-condition-mate-pm`), L4 위임 발행(사람), L5 실행(워커), L6 검증(`lion-condition-mate-worker-qa`), L7 보안 게이트(`lion-condition-mate-pm-security`), L8 반영(사람+구현 에이전트), L9 되먹임(PO)이다.

**있는 것 둘 — goal 상태 기계.** `Sources/ConditionMate/Core/ReviewStore.swift:542` 에 `backlog / in_progress / waiting / stopped / cancelled / done` 여섯 상태가 이미 구현되어 있다. 그중 `waiting`(응답 대기)은 `waitingSince`(`ReviewStore.swift:29`)와 `waitKind`(`:35`, permission 또는 decision)를 함께 들고 있다. 이것은 참조 모델의 `APPROVALS.md` 승인 큐와 정확히 같은 자리이며, **이미 계측되어 있고 지금 이 순간에도 값이 들어 있다.** 실측: goal 815건 중 `waiting` 2건이며 체류가 각각 81분과 1분이다(`seq 961 에이전트 관리 시스템`, `seq 963 루프 엔지니어링 PO 및 다이어그램`).

**비어 있는 것 하나 — 단계 이벤트 원장이 없다.** 참조 모델에는 `pipeline_events.jsonl` 이 있고 각 칸의 담당이 칸을 끝낼 때 한 줄을 적는다(`PIPELINE.md` 3장). Condition Mate 에는 이에 해당하는 파일이 없다. 그래서 L1..L9 중 어느 칸에 무엇이 서 있는지를 아무도 기록하지 않는다. 오늘 디스크에서 유도할 수 있는 칸은 L4(위임 발행, 트랜스크립트의 Task 호출)와 L5(실행, 결과 줄)와 L8(반영, git 커밋) 정도이고, L2·L3·L6·L7·L9 는 흔적이 아예 없다.

**비어 있는 것 둘 — 정의가 코드도 문서도 아닌 프롬프트 안에만 있다.** 아홉 칸이 에이전트 `.md` 한 개 안에만 존재한다. `docs/` 아래에도, SPEC 에도, Swift 에도 없다. 프롬프트는 에이전트가 읽을 때만 존재하는 정의라, 화면이 참조할 수 없고 QA 가 회귀로 잡을 수도 없다.

### 결론

정의 없는 루프 그림은 아무것도 아닌 것의 그림이라는 지적은 맞다. 다만 이 저장소의 상태는 "정의가 없다"가 아니라 **"정의는 있는데 계측이 없고, 그 정의가 프롬프트 안에만 있다"** 이다. 그래서 첫 산출물은 루프를 새로 정의하는 일이 아니라 다음 둘이다.

1. 아홉 칸 정의를 에이전트 프롬프트에서 꺼내 `docs/loop-engineering.md` 로 옮기고, 프롬프트는 그 문서를 참조하게 한다. 정의가 두 벌이 되면 끊김 판정 자체가 무의미해진다(`BACKLOG_RULES.md` 11장, `PIPELINE.md` 5장의 같은 원칙).
2. 아홉 칸 중 **오늘 증거가 있는 칸만** 화면에 세우고, 증거가 없는 칸은 빈칸이 아니라 "여기는 완료를 기록하는 곳이 없다"고 적는다. 이 앱의 기존 원칙(`OrchestrationContent.swift:15-17`, `docs/orchestration-routes.md` "재지 못하는 것")과 같은 규칙이다.

---

## 3. 조사 중 나온 큰 발견 두 개 — 제안의 전제가 바뀐다

### 3-1. 핸드오프 비용은 측정할 수 있다. 문서와 화면이 틀렸다

`docs/orchestration-routes.md:94-97` 은 이렇게 적고 있다. "서브에이전트의 내부 턴은 세션 트랜스크립트에 한 줄도 남지 않는다. 전체 892개 파일에서 0건이다." 화면도 같은 말을 한다(`OrchestrationContent.swift:166-171`). 에이전트 정의도 같은 말을 반복한다(`.claude/agents/lion-condition-mate-po-loop-engineering.md`, "What you cannot measure here").

**디스크를 직접 세어 보니 사실이 아니다.**

- 서브에이전트 트랜스크립트 폴더 47개, 트랜스크립트 101개, 메타 101개가 `~/.claude/projects/<slug>/<sessionId>/subagents/` 아래에 있다.
- `isSidechain:true` 줄이 전체 8,197줄이다.
- 그 안에 서브에이전트 내부 어시스턴트 턴 5,081회, 내부 도구 호출 2,865회가 기록되어 있다.
- 내부 벽시계 시간 합계는 53,100초, 약 14.8시간이다. 화면이 지금 말하는 3.7시간의 네 배다.
- 각 `agent-<id>.meta.json` 은 `{"agentType":...,"description":...,"toolUseId":...,"spawnDepth":...}` 를 담는다. **`toolUseId` 가 `OrchestrationScan.Hop.uid` 와 정확히 같은 키다.** 실측 조인율은 위임 96건 중 91건, 95퍼센트다.

왜 지금까지 못 봤는가. `OrchestrationScan.hops()` 는 `AgentInventory.sessionDirs()` 가 준 폴더를 한 겹만 훑고 `pathExtension == "jsonl"` 로 거른다(`OrchestrationScan.swift:43-47`). `subagents/` 하위 폴더로 내려가지 않는다. 스캔 범위의 문제이지 증거의 부재가 아니었다.

파급 효과가 셋이다.

- **백그라운드 위임 42건의 소요시간이 복구된다.** 부모 쪽 결과 줄은 영수증일 뿐이지만, 자식 트랜스크립트의 첫 줄과 마지막 줄이 실제 시작과 끝이다.
- **중첩 위임 12건이 새로 보인다.** `spawnDepth:2` 가 12건이다. 지금 화면의 위임 총계 84건은 최상위만 센 것이고, 실제 위임은 96건이다.
- **재캐기 비용을 셀 수 있다.** 받은 쪽이 첫 산출을 내기 전에 부른 Read/Grep 호출 수가 곧 "앞 홉이 이미 알던 것을 다시 캐는 비용"이다.

문서·화면·에이전트 정의 세 곳의 "0건" 주장은 같은 변경에서 함께 고쳐야 한다. 안 고치면 다음 사람이 또 없는 것으로 취급한다.

### 3-2. 사람 대기는 이미 잴 수 있고, 재 보면 압도적이다

최상위 트랜스크립트에서 "어시스턴트의 마지막 출력 → 다음 사람 프롬프트"의 간격을 재면 그것이 사람 대기다. 사람 프롬프트는 `type:"user"` 이면서 `tool_result` 를 담지 않는 줄로 구분된다.

2026-08-01 이후 파일 735개 기준 실측이다.

- 사람 턴 1,106회.
- 중앙값 202초, 75분위 734초, 90분위 2,725초.
- 5분 초과 457회, 30분 초과 141회, 4시간 초과 48회.
- 합계는 상한을 어디에 두느냐로 갈린다. 상한 없음 1,304.5시간, 4시간 상한 393.4시간, 1시간 상한 251.5시간.

같은 기간의 에이전트 가동은 서브에이전트 내부 시간으로 12.1시간이다(2026-08-01 이후 시작된 트랜스크립트 86건, 내부 턴 4,392회, 도구 호출 2,510회).

4시간 상한 기준 **사람 병목 지수 = 393.4 / (393.4 + 12.1) = 97.0퍼센트**다.

이 숫자의 한계는 참조 모델의 `HUMAN_BOTTLENECK.md` 2장과 똑같다. 잠자는 시간이 대기로 잡히고, 사람이 워커 자리에서 일한 시간과 결정을 기다린 시간이 분리되지 않는다. 화면에 지수를 적을 때 이 두 가지를 반드시 함께 적어야 한다.

### 3-3. 부수적으로 확인된 데이터 결함 — `trackedSeconds` 는 못 쓴다

goal 의 `trackedSeconds` 를 에이전트 가동 시간으로 쓰면 안 된다. 최근 7일 완료 goal 50건의 합이 6,072시간으로 나온다. 상위를 보면 `seq 130 주보상패키지 지급` 1,270시간, `seq 1 MPC정리` 1,244시간이다. 세션이 붙지 않은 수동 goal 이 `in_progress` 로 몇 주씩 놓여 있던 값이다. 중앙값은 0.22시간이다. 어느 방향을 택하든 이 필드를 가동 시간의 근거로 쓰면 화면이 거짓말을 한다.

---

## 4. ASK 1 — 이름 변경 계획

"오케스트레이션"을 "루프 엔지니어링"(Loop Engineering)으로 바꾼다.

### 4-1. 바뀌는 사용자 노출 문자열 전부

파일과 줄, 그리고 바꿀 값이다.

- `Sources/ConditionMate/Dashboard/OrchestrationContent.swift:24` — `<title>오케스트레이션</title>` → `<title>루프 엔지니어링</title>`
- 같은 파일 `:112` — `<h1>오케스트레이션</h1>` → `<h1>루프 엔지니어링</h1>`. 같은 줄의 `.sub` 설명문("프로젝트마다 어떤 위임 라우트가 실제로 돌았고…")은 5장에서 화면을 바꿀 때 함께 다시 쓴다. 이름 변경 단계에서는 건드리지 않는다.
- 같은 파일 `:145` — `오케스트레이션 기록을 불러오지 못했습니다` → `루프 기록을 불러오지 못했습니다`
- 같은 파일 `:300` — `오케스트레이션 흔적을 찾지 못했습니다 — 위임(Task) 기록, …` → `루프 흔적을 찾지 못했습니다 — 위임(Task) 기록, …`
- 같은 파일 `:327` — 푸터의 `측정 정의는 docs/orchestration-routes.md 에 적혀 있습니다` → `측정 정의는 docs/loop-engineering.md 에 적혀 있습니다`
- `Sources/ConditionMate/Dashboard/SessionRail.swift:458` — 레일 라벨 `오케스트레이션` → `루프 엔지니어링`. 자세한 것은 4-4.
- `Sources/ConditionMate/Dashboard/AgentsContent.swift:25` — `<title>에이전트 · 오케스트레이션</title>` → `<title>에이전트 · 루프 엔지니어링</title>`
- `docs/orchestration-routes.md` 의 `:1` 제목, `:3`, `:10`, `:12`, `:22`, `:78` 본문. 파일 이름 변경은 4-3에서 다룬다.

**바꾸지 않는 사용자 노출 문자열 둘.** 둘 다 같은 단어를 쓰지만 다른 뜻이다.

- `Sources/ConditionMate/Core/EquipmentStore.swift:28` — 장비 사다리의 등급 라벨 `"팀 오케스트레이션"`. 이것은 사용자의 자동화 성숙도 눈금이지 이 페이지의 이름이 아니다. 바꾸면 기존 사용자의 등급 라벨이 이유 없이 바뀐다.
- `Sources/ConditionMate/Dashboard/EquipmentContent.swift:209` — `teamlead 오케스트레이션` 설명문. 위와 같은 이유.

`SessionRail.swift:457` 의 `title` 속성("프로젝트별로 어떤 위임 라우트가 실제로 돌았고 어디서 막히는지 봅니다")에는 문제의 단어가 없다. 화면 개편이 끝난 뒤 새 화면이 답하는 질문으로 다시 쓰는 것이 맞고, 이름 변경 단계에서는 그대로 둔다.

### 4-2. 코드 식별자 — 항목별 권고와 이유

- **`OrchestrationContent` → `LoopEngineeringContent`.** 바꾼다. 호출부가 `AppDelegate.swift:70` 한 곳뿐이다. 파일도 `Sources/ConditionMate/Dashboard/LoopEngineeringContent.swift` 로 `git mv` 한다. SPM 은 `Sources/ConditionMate` 를 통째로 잡으므로 `Package.swift` 수정이 필요 없다(파일 목록을 열거하지 않는다).
- **`OrchestrationScan` → `LoopScan`.** 바꾼다. 호출부가 `AppDelegate.swift:5129` 한 곳뿐이다. `LoopEngineeringScan` 이 아니라 `LoopScan` 인 이유는, 5장에서 이 타입이 서브에이전트 트랜스크립트까지 읽게 되면 "위임 홉 재구성기"라는 역할 이름이 도메인 이름보다 정확해지기 때문이다. 파일도 `Sources/ConditionMate/Core/LoopScan.swift` 로 `git mv`.
- **`OrchestrationScan.swift:13` 의 `OrchestrationFeed`.** 이 타입은 디스크에 존재하지 않는다. 실제 병합은 `AppDelegate.orchestrationJSON()` 이 한다. 이름을 바꾸는 김에 주석에서 실존하는 이름으로 고친다.
- **`orchestrationJSON()` → `loopEngineeringJSON()`.** 바꾼다. 호출부가 `AppDelegate.swift:140` 한 곳뿐이다.
- **`window.CM_PAGE='orch'` → `'loop'`, `data-nav="orch"` → `data-nav="loop"`, `cmNav('orch')` → `cmNav('loop')`.** 바꾼다. 근거는 어디에도 저장되지 않는다는 점이다. `CM_PAGE` 사용처는 전부 확인했고(`AppDelegate.swift:2932`, `OrchestrationContent.swift:109`, `SessionRail.swift:3240-3242`, `:3279`, `:3282`, `:3286`, `AgentsContent.swift:112`, `GoalAddContent.swift:414`, `EquipmentContent.swift:157`), `localStorage` 나 `sessionStorage` 에 담기는 값이 아니다. 레일이 저장하는 것은 `cmStage`, `cmChMode`, `cmChPomoMin` 뿐이다(`SessionRail.swift:669`, `:715`, `:926`, `:930`). 즉 브라우저를 새로 고쳐도 남아 있을 값이 아니라 순수 런타임 값이다.
- **`AgentInventory`, `DeviceCronScanner`.** 바꾸지 않는다. 둘 다 도메인 이름이 아니라 자기 일의 이름이다(에이전트 인벤토리, 장치 크론 스캐너). 이 페이지 말고도 `/agents` 페이지가 `AgentInventory` 를 쓴다. 대신 그 안의 한국어 주석 중 "오케스트레이션 화면"이라고 부르는 곳은 새 이름으로 고친다: `AgentInventory.swift:10`, `:70`, `:77`, `:80`, `DeviceCronScanner.swift:27`, `:72`.

### 4-3. URL — 이것만 유일하게 되돌릴 수 없는 결정이다

**전체 호출부(저장소 전량 grep + `.e2e` 포함).**

- `/orchestration` 페이지 경로: `AppDelegate.swift:70`(라우트), `SessionRail.swift:3286`(`location.href`), `DashboardServer.swift:458`(GET 페이지 허용목록), 주석 다수, `docs/orchestration-routes.md:3`.
- `/api/orchestration`: `AppDelegate.swift:139`(라우트), `OrchestrationContent.swift:142`(`fetch`), `DashboardServer.swift:408`(GET API 허용목록).
- **저장소 밖의 유일한 소비자:** `.claude/agents/lion-condition-mate-po-loop-engineering.md`. 이 에이전트 정의는 "The app's own feed … `GET /api/orchestration`" 이라고 경로를 하드코딩해 두었고, 응답 필드까지 열거하고 있다. 살아 있는 에이전트다.
- **`.e2e` 테스트에는 참조가 0건이다.** `grep -rn -E "orchestration|orch" .e2e/` 결과 `.e2e/devicecron.test.js:7`, `:96` 두 줄뿐이며 둘 다 한국어 주석 안의 "오케스트레이션"이라는 단어이지 경로가 아니다.

**권고.**

경로를 `/loop-engineering` 과 `/api/loop-engineering` 으로 바꾼다. 그리고 **페이지 경로에만 리다이렉트를 남기고, API 경로에는 별칭을 남기지 않는다.** 이유가 셋이다.

첫째, 북마크와 열어 둔 탭은 실재하는 위험이다. `/orchestration` 을 치면 404가 뜨는 것은 사용자에게 기능이 사라진 것으로 보인다. 302 한 줄이면 막을 수 있고 유지 비용이 사실상 없다.

둘째, API 는 소비자가 정확히 둘이고 둘 다 이 저장소 안에 있다. 하나는 같은 커밋에서 고치는 페이지 자신의 `fetch` 이고, 다른 하나는 같은 커밋에서 고치는 에이전트 정의 파일이다. 버전 없는 로컬 전용 API 에 영구 별칭을 남기면, 다음 사람이 어느 쪽이 진짜인지 몰라 둘 다 유지하게 된다.

셋째, 별칭을 남기지 않으면 에이전트 정의를 반드시 같은 커밋에서 고치게 된다. 남기면 안 고치고 넘어가고, 문서와 코드가 갈라진다.

**구체적 변경.**

- `DashboardServer.swift:408` 의 `path.hasPrefix("/api/orchestration")` → `path.hasPrefix("/api/loop-engineering")`.
- `DashboardServer.swift:458` 의 `path.hasPrefix("/orchestration")` → `path.hasPrefix("/loop-engineering")` 로 바꾸고, `|| path.hasPrefix("/orchestration")` 를 **남긴다**(리다이렉트 페이지를 서빙해야 하므로 허용목록에 있어야 한다).
- `AppDelegate.swift:70` 위에 한 줄을 먼저 둔다. `/orchestration` 이면 `<meta http-equiv="refresh" content="0;url=/loop-engineering">` 만 담은 최소 HTML 을 돌려준다. 서버 헬퍼가 이미 200 고정이므로(`DashboardServer.swift:459-461`) 302 상태코드보다 meta refresh 가 변경 폭이 작다. 그다음 줄에서 `/loop-engineering` 이 `LoopEngineeringContent.html()` 을 돌려준다. **더 구체적인 경로가 위에 와야 한다** — `hasPrefix` 매칭이라 순서가 곧 우선순위다.
- `.claude/agents/lion-condition-mate-po-loop-engineering.md` 의 `GET /api/orchestration`, `Sources/ConditionMate/Core/OrchestrationScan.swift`, `Sources/ConditionMate/Core/AgentInventory.swift`, `orchestrationJSON()`, `docs/orchestration-routes.md` 언급을 모두 새 이름으로 고친다. 같은 파일의 "A naming note you must carry" 절은 이름 변경이 끝났으므로 통째로 지운다.

**문서 파일 이름.** `docs/orchestration-routes.md` → `docs/loop-engineering.md` 로 `git mv` 한다(히스토리 보존). 참조는 여섯 줄뿐이다: `OrchestrationContent.swift:327`, 위 에이전트 정의 3곳, 문서 자신의 제목. 이 제안서 `docs/loop-engineering-proposal.md` 와 이름이 비슷하므로, 새 문서 첫 줄에 "이 문서는 측정 정의다. 개편 제안은 `docs/loop-engineering-proposal.md` 에 있다"를 적어 둔다.

### 4-4. 레일 라벨 — 실제 폭을 계산했다

**먼저 사실 정정.** `SessionRail.swift:85` 의 주석은 컬럼을 68px라고 적었지만 라벨이 실제로 쓸 수 있는 폭은 68px가 아니다.

계산은 이렇다. `.cmrail{width:240px}`(`:27`) → `.cmrail-nav{margin:0 8px}`(`:66`)로 224px → `padding:6px` 좌우로 212px → 3열에 `gap:4px` 두 개이므로 열 하나는 `(212-8)/3 = 68px` → `.cmrail-item{padding:9px 4px}`(`:68`)로 텍스트 상자는 **60px**.

`오케스트레이션` 은 7자다(8자가 아니다). `루프 엔지니어링` 은 한글 7자에 공백 1개다.

`.cmr-lbl.wrap2`(`:88`)는 `white-space:normal; word-break:break-all; font-size:10.5px; letter-spacing:-.02em` 이다. Apple SD Gothic Neo 에서 한글 한 글자의 진행폭은 대략 폰트 크기와 같으므로 글자당 약 10.29px다. 60px에는 5글자가 들어간다.

- `오케스트레이션`: `break-all` 로 5+2 → `오케스트레` / `이션`. 지금 그대로다.
- `루프 엔지니어링` 을 **지금의 `break-all` 그대로** 두면 탐욕적 줄바꿈이 공백을 무시하고 채운다. 누적 폭은 루 10.29, 프 20.58, 공백 약 23.8, 엔 34.1, 지 44.4, 니 54.7이고 어(64.9)에서 넘친다. 결과는 `루프 엔지니` / `어링` 이다. 지금보다 더 나쁘다.
- `word-break:keep-all` 로 바꾸면 한글은 단어 안에서 끊기지 않고 공백에서만 끊긴다. 결과는 `루프` / `엔지니어링` 이다. 둘째 줄은 5글자 약 51.5px로 60px 안에 들어간다.

**권고: 라벨은 `루프 엔지니어링` 그대로 쓰고, `SessionRail.swift:88` 의 `word-break:break-all` 을 `word-break:keep-all` 로 바꾼다.** 그러면 두 줄이 되되 의미 단위로 끊긴다.

이 변경이 안전한 근거: `wrap2` 클래스는 저장소 전체에서 정의 1곳(`:88`)과 사용 1곳(`:458`)뿐이다. 다른 라벨에 영향이 없다.

**택하지 않은 대안 둘.**

- `루프` 만 쓰기. 한 줄에 들어가고 격자 높이가 줄어든다. 하지만 "엔지니어링"이 이름의 절반이고, 이름을 바꾸는 목적 자체가 "이것은 도구 모음이 아니라 계측·개선 활동"이라고 말하는 것이다. 줄여 쓰면 그 말이 사라진다. 좁은 창에서 이 항목만 다른 항목과 높이가 달라 보이는 문제도 이미 지금 발생하고 있는 것이라 새로 생기는 손해가 아니다.
- `루프엔지니어링`(공백 제거). 7자라 `break-all` 로 `루프엔지니` / `어링` 이 된다. `keep-all` 로도 끊을 곳이 없어 강제로 넘치거나 잘린다. 공백을 없애면 `keep-all` 이 쓸 수 있는 유일한 줄바꿈 기회를 스스로 없애는 셈이다.

### 4-5. 작업 순서 — 중간에 빌드가 깨지지 않게

각 단계 끝에서 `swift build` 가 통과한다. 단계 사이에 커밋해도 되고 한 커밋으로 묶어도 된다.

1. **문자열만.** 4-1의 한국어 노출 문자열과 주석을 고친다. 식별자·경로는 손대지 않는다. 컴파일 영향 없음. 빌드 통과.
2. **문서 이동.** `git mv docs/orchestration-routes.md docs/loop-engineering.md`. 문서 안의 이름을 고치고, `OrchestrationContent.swift:327` 푸터의 경로 문자열을 고친다. 빌드 통과.
3. **타입 이름.** `git mv` 로 파일 두 개를 옮기고 `OrchestrationContent` → `LoopEngineeringContent`, `OrchestrationScan` → `LoopScan` 을 정의와 호출부에서 **같은 편집으로** 바꾼다. 호출부가 각각 한 곳(`AppDelegate.swift:70`, `:5129`)이라 부분 적용으로 깨질 여지가 거의 없다. 빌드 통과.
4. **메서드 이름.** `orchestrationJSON()` → `loopEngineeringJSON()` 을 정의(`AppDelegate.swift:5125`)와 호출부(`:140`)에서 같이 바꾼다. 빌드 통과.
5. **경로.** 서버 허용목록(`DashboardServer.swift:408`, `:458`), 라우트(`AppDelegate.swift:70`, `:139`), 페이지 `fetch`(`OrchestrationContent.swift:142`), 레일 이동(`SessionRail.swift:3286`)을 한 번에 바꾼다. **부분 적용하면 화면은 뜨는데 데이터가 안 오는 상태가 되므로 이 다섯 곳은 반드시 한 편집이다.** 같은 편집에서 `/orchestration` 리다이렉트를 넣는다. 빌드 통과.
6. **`CM_PAGE` 와 `data-nav`.** `'orch'` → `'loop'` 를 `OrchestrationContent`(이제 `LoopEngineeringContent`)`:109` 와 `SessionRail.swift:3242`, `:3286`, `:457` 에서 한 번에 바꾼다. 부분 적용하면 레일 하이라이트가 안 켜진다. 빌드 통과.
7. **레일 라벨과 CSS.** `SessionRail.swift:458` 라벨과 `:88` 의 `keep-all`, 그리고 `:85` 주석의 68px 기술을 60px로 정정한다. 빌드 통과.
8. **에이전트 정의.** `.claude/agents/lion-condition-mate-po-loop-engineering.md` 의 경로·타입·문서 이름을 고치고 "A naming note you must carry" 절을 삭제한다. 3-1의 "핸드오프 측정 불가" 주장도 같이 정정한다(5장 참조).

### 4-6. 갱신해야 하는 `.e2e` 테스트

**이름 변경 때문에 깨지는 테스트는 없다.** 경로 참조가 0건이기 때문이다.

다만 레일 격자를 읽는 테스트 두 개가 **이번 변경과 무관하게 이미 실패하고 있다.** 실제로 돌려 확인했다.

- `.e2e/plan.test.js` — `node plan.test.js` 결과 4건 FAIL. `nav has 9 items` 가 got=8 로 실패한다. 정규식이 `<span class="cmr-lbl">` 로 고정돼 있어(`plan.test.js:48`) `class="cmr-lbl wrap2"` 인 아홉 번째 항목을 못 잡는다. 기대값도 `['chat','skills','cron','delegate','team','work','memo','tbd2','tbd3']` 로 낡았다. 실제는 `['chat','skills','cron','delegate','team','work','slack','agents','orch']` 다.
- `.e2e/memofocus.test.js` — `node memofocus.test.js` 결과 5건 FAIL. 존재하지 않는 `data-nav="memo"` 를 찾는다.

둘 다 `package.json` 의 `test` 스크립트에 들어 있지 않아 기본 실행에서 빠져 있다. 이름 변경 작업에서 해야 할 일은 다음과 같다.

- `plan.test.js:48` 의 정규식을 `class="(cmr-lbl[^"]*)"` 로 넓혀 `wrap2` 항목도 잡게 한다. 이것을 안 고치면 라벨 변경이 테스트에 잡히지 않는다.
- `plan.test.js:51-55` 의 기대값을 현행으로 맞추고, 아홉 번째를 `loop` / `루프 엔지니어링` 으로 둔다.
- `plan.test.js:55` 의 `미정 slots are inert` 검사는 `미정` 슬롯이 없어졌으므로 삭제하거나 "격자에 `off` 항목이 없다"로 뒤집는다.
- `memofocus.test.js` 의 격자 블록(`:32-38`)은 사라진 메뉴를 검사하므로 이름 변경 작업 범위 밖이다. 별건으로 정리한다.

---

## 5. ASK 2 — 화면 개편, 세 방향

세 방향은 **첫 3초에 답하는 질문이 서로 다르다.** 같은 배치의 스킨 셋이 아니다.

방향 A는 "루프의 어느 칸에서 멈췄나"에 답한다. 축이 단계다.
방향 B는 "지금 누구 차례이고 얼마나 서 있나"에 답한다. 축이 대기다.
방향 C는 "위임 한 건이 어디서 시간을 흘리나"에 답한다. 축이 홉 내부다.

### 방향 A — 루프 보드 (단계 축)

**한 문장 약속.** 화면을 열면 아홉 칸 중 지금 몇 건이 어느 칸에 서 있는지, 그리고 어느 칸이 임계를 넘겼는지를 3초에 안다.

**배치.** 상단에 L1..L9 아홉 칸을 가로로 세우고 칸마다 현재 체류 건수와 담당을 적는다. 임계를 넘긴 칸에 붉은 화살표를 세운다. 그 아래에 선택된 칸의 아이템 목록이 체류 시간과 함께 나오고, 각 행에 그 칸의 담당이 할 수 있는 동작 버튼이 붙는다. 맨 아래에 증거가 없는 칸을 명시한다.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 루프 엔지니어링              [프로젝트 전체 ▾]  [7일 ▾]   [새로고침] │
├──────────────────────────────────────────────────────────────────────┤
│   L1    L2    L3    L4    L5    L6    L7    L8    L9                 │
│  목표  수용  지시  위임  실행  검증  보안  반영  되먹임               │
│ ┌───┐┌───┐┌───┐┌───┐┌───┐┌───┐┌───┐┌───┐┌───┐                        │
│ │ 2 ││ ? ││ ? ││ 5 ││ 3 ││ ? ││ ? ││ 1 ││ 0 │  ← 지금 서 있는 건수  │
│ └───┘└───┘└───┘└───┘└───┘└───┘└───┘└───┘└───┘                        │
│  사람   PO    PM   사람  워커   QA   보안  사람   PO   ← 칸 주인      │
│                     ▲                                                 │
│                  STALLED 81분 / 임계 30분                             │
├──────────────────────────────────────────────────────────────────────┤
│ L4 위임 발행 에 서 있는 것                        체류    임계  판정  │
│ ────────────────────────────────────────────────────────────────────│
│ seq 961  에이전트 관리 시스템                     81분   30분  STALLED│
│          [세션 열기]  [위임 발행]  [보류]                             │
│ seq 963  루프 엔지니어링 PO 및 다이어그램          1분   30분  정상   │
│          [세션 열기]  [위임 발행]  [보류]                             │
├──────────────────────────────────────────────────────────────────────┤
│ 물음표 4칸은 증거가 없다.                                             │
│ L2 수용 기준·L3 지시서·L6 검증·L7 보안은 완료를 적는 곳이 아직 없다. │
│ 일을 안 한 것과 안 적은 것을 이 계측기는 구분하지 못한다.             │
└──────────────────────────────────────────────────────────────────────┘
```

**필요한 데이터와 지금 있는지 여부.**

- L4 위임 발행, L5 실행: **있다.** `LoopScan` 의 홉(위임 시각, 결과 시각, 네 가지 끝맺음)이 그대로 이 두 칸이다.
- L1 목표 접수: **있다.** `ReviewStore` goal 의 생성과 `status`.
- L8 반영: **부분적으로 있다.** git 커밋으로 유도할 수 있으나 어느 goal 의 반영인지 잇는 키가 없다. 커밋 메시지에 goal 번호를 넣는 규약이 필요하다.
- L2 수용 기준, L3 지시서, L6 검증, L7 보안 게이트, L9 되먹임: **없다. 새 계측이 필요하다.** 이 다섯 칸은 사람이나 에이전트가 "끝냈다"고 적는 곳이 디스크 어디에도 없다. 참조 모델의 `pipeline_events.jsonl` 에 해당하는 파일을 만들고, 각 칸의 담당(대부분 에이전트)이 자기 칸을 끝낼 때 한 줄을 append 해야 한다. 최소 필드는 `item`(goal seq), `stage`(L1..L9), `at`, `by`, `result`(통과/반려/건너뜀), `note` 다. `~/.condition-mate/ledger/agent-update-log.jsonl` 이 이미 append-only 원장으로 존재하므로 그 옆에 `loop-events.jsonl` 을 두는 것이 자연스럽다.
- **정직하게 말하면 아홉 칸 중 다섯 칸이 오늘 빈칸이다.** 그림은 그려지지만 절반이 물음표다.

**사용자가 무엇을 하는가.** L4 행의 `[위임 발행]` 은 그 goal 의 세션으로 이동해 PM 이 만든 지시서를 붙인 상태로 연다. `[세션 열기]` 는 트랜스크립트 뷰(`/transcript`)로 간다. `[보류]` 는 goal 상태를 `stopped` 로 바꿔 대기 큐에서 뺀다. L5 행의 끊긴 홉에는 `[세션 새로 열기]` 가 붙는다 — 실측 5건 중 4건이 정의 파일은 이미 있었는데 세션이 시작할 때 못 읽어서 실패한 경우였기 때문이다(`AppDelegate.swift:5330-5341`).

**빌드 규모.** 큼. 새 원장 파일 형식과 쓰기 지점, 그것을 쓰는 규칙을 에이전트 정의 여러 개에 심는 일이 코드보다 크다. 손대는 파일: `Sources/ConditionMate/Core/LoopEvents.swift`(신규), `Sources/ConditionMate/Core/LoopScan.swift`, `Sources/ConditionMate/AppDelegate.swift`, `Sources/ConditionMate/Dashboard/LoopEngineeringContent.swift`, `docs/loop-engineering.md`, `.claude/agents/` 아래 최소 4개.

**정직한 실패 방식.** 원장에 아무도 안 적으면 아홉 칸 중 다섯 칸이 영원히 0으로 남고, 화면은 "일이 안 돈다"고 말한다. 실제로는 기록이 없는 것이다. 참조 모델이 2026-08-22 에 정확히 이 함정에 빠졌고 `LOOP_DIAGRAM.md` 4장에 그 사고를 적어 두었다. Condition Mate 는 그보다 조건이 나쁘다 — 담당의 다섯 중 넷이 에이전트인데, 에이전트에게 원장 쓰기를 시키는 규칙은 지금 원장 한 개(`agent-update-log.jsonl`)에 대해서만 존재하고 그마저 마지막 기록이 2026-08-21이며 두 에이전트(`manager-qa`, `manager-pm`)만 쓰고 있다. 즉 이미 이름이 바뀐 에이전트들은 아무도 안 적고 있다.

### 방향 B — 병목 한 줄과 대기 큐 (대기 축)

**한 문장 약속.** 화면을 열면 이 맥의 병목이 사람인지 에이전트인지를 숫자 하나로 알고, 그 아래 첫 세 줄에서 지금 누구 차례인 무엇이 몇 분째 서 있는지를 안다.

**배치.** 최상단에 사람 병목 지수 하나와 막대. 그 아래 한 줄로 분자와 분모. 다음 블록이 이 화면의 심장인 "지금 열려 있는 대기"로, 체류 내림차순 정렬에 임계와 STALLED 판정이 붙고 행마다 동작 버튼이 있다. 그 아래 액터별 가동/대기. 그 아래 추세 한 줄. 기존 프로젝트 카드 28개는 접힌 채 맨 아래로 내려간다.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 루프 엔지니어링                                            [새로고침] │
├──────────────────────────────────────────────────────────────────────┤
│  사람 병목 지수                                                       │
│   97.0%  ███████████████████░                                         │
│   사람 대기 393.4h / 전체 405.5h · 4시간 상한 적용 · 잠자는 시간 포함  │
│   사람 턴 1,106회 · 중앙값 3분 · 30분 초과 141회 · 4시간 초과 48회    │
├──────────────────────────────────────────────────────────────────────┤
│ 지금 열려 있는 대기                          담당   체류   임계  판정 │
│ ────────────────────────────────────────────────────────────────────│
│ seq 961  에이전트 관리 시스템                사람   81분  30분 STALLED│
│    막은 것: 하위 목표 3건                                             │
│    [세션 열기]  [진행으로]  [보류]                                    │
│ ────────────────────────────────────────────────────────────────────│
│ seq 963  루프 엔지니어링 PO 및 다이어그램     사람    1분  30분 정상  │
│    막은 것: 없음                                                      │
│    [세션 열기]  [진행으로]  [보류]                                    │
│ ────────────────────────────────────────────────────────────────────│
│ globalmpc-legal  expert-legal-sg             워커    1일    —   끊김  │
│    정의 없음 · 그때 디스크에도 없었음                                 │
│    [파트 만들기]  [세션 새로 열기]                                    │
│ ────────────────────────────────────────────────────────────────────│
│ lion-condition-mate  qa-agent 워커           워커     —     —  미등록 │
│    launchd 에 안 걸려 있음 — 사람 없이 시작하는 부품이 없다           │
│    [등록 방법 보기]                                                   │
├──────────────────────────────────────────────────────────────────────┤
│ 액터별 가동 / 대기                            가동     대기   대기비중│
│  사람                                            —   393.4h     100% │
│  워커(서브에이전트 내부)                     12.1h      0.4h       3% │
│  PO · PM · QA · 보안                             —        —  기록 없음│
├──────────────────────────────────────────────────────────────────────┤
│ 추세   97.0%  ←  ―  ←  ―        loop-history.jsonl 1줄 (오늘 개시)   │
├──────────────────────────────────────────────────────────────────────┤
│ ▸ 프로젝트별 라우트 28곳 (끊김 3 · 진입점 8)              [펼치기]    │
└──────────────────────────────────────────────────────────────────────┘
```

**필요한 데이터와 지금 있는지 여부.**

- **사람 대기: 있다. 새 계측 필요 없다.** 3-2에서 실측한 방식 그대로다. 최상위 트랜스크립트에서 "어시스턴트 마지막 출력 → 다음 사람 프롬프트"의 간격을 잰다. 사람 프롬프트는 `type:"user"` 이면서 `"tool_result"` 를 담지 않는 줄이다. 실측 1,106회. `LoopScan.forEachLine` 의 바이트 스캔 방식(`OrchestrationScan.swift:154-176`)을 그대로 재사용하면 되고, 표식만 추가하면 된다.
- **에이전트 가동: 있다. 단, 스캔 범위를 넓혀야 한다.** 3-1의 서브에이전트 트랜스크립트다. `LoopScan` 이 `subagents/` 하위 폴더로 내려가고, `agent-<id>.meta.json` 의 `toolUseId` 로 홉과 잇는다. 조인율 95퍼센트를 실측했다. **새로 기록할 것은 없다. 이미 디스크에 있는 것을 안 읽고 있을 뿐이다.**
- **사람 결정 대기 큐: 있다. 이미 계측되어 있다.** `ReviewStore.Goal.status == "waiting"` 과 `waitingSince`(`ReviewStore.swift:29`)와 `waitKind`(`:35`)가 그대로 체류 시간과 대기 종류다. 지금 이 순간 2건이 들어 있다.
- **"막은 것": 부분적으로 있다.** goal 의 `parent` 와 `links` 필드로 하위 목표 수는 셀 수 있다. 참조 모델의 `APPROVALS.md` 처럼 사람이 손으로 적은 "차단 대상" 수준의 서술은 없다.
- **끊긴 홉·미등록 워커: 있다.** 지금 화면이 이미 계산한다(`AppDelegate.swift:5324-5350`). 프로젝트 카드에 묻혀 있는 것을 하나의 대기 큐로 끌어올리는 것뿐이다.
- **PO·PM·QA·보안의 가동: 없다.** 방향 A와 같은 이유다. 이 화면에서는 0으로 그리지 않고 "기록 없음"이라고 적는다.
- **추세: 없다. 파일 하나를 새로 만들어야 한다.** `~/.condition-mate/ledger/loop-history.jsonl` 에 조회마다가 아니라 하루 몇 번 정해진 시각에 한 줄 append. 참조 모델의 `loop_engineering_history.jsonl` 과 같은 스키마를 쓴다.
- **`trackedSeconds` 는 쓰지 않는다.** 3-3의 이유다.

**사용자가 무엇을 하는가.** 대기 큐의 각 행이 그 대기를 실제로 푸는 동작을 하나씩 갖는다. 사람 응답 대기 행은 `[세션 열기]` 로 그 goal 의 세션으로 가고 `[진행으로]` 로 `POST /api/goal/status` 를 쳐서 `in_progress` 로 돌린다. 끊긴 홉 행은 `[세션 새로 열기]` 가 원인 안내를 띄운다. 미등록 워커 행은 `launchctl` 등록 방법을 띄운다. **누른 결과가 다음 조회에서 그 행이 사라지는 것으로 확인된다** — 이것이 화면이 살아 있다는 증거다.

**빌드 규모.** 중간. 손대는 파일: `Sources/ConditionMate/Core/LoopScan.swift`(사람 간격 계측 + `subagents/` 하강), `Sources/ConditionMate/AppDelegate.swift`(`loopEngineeringJSON()` 에 `bottleneck`·`openWaits`·`actors` 세 블록 추가), `Sources/ConditionMate/Dashboard/LoopEngineeringContent.swift`(상단 3블록 신규, 기존 프로젝트 목록은 접기), `Sources/ConditionMate/Core/LoopHistory.swift`(신규, 작음), `docs/loop-engineering.md`, `docs/specs/SPEC.md`. 기존 프로젝트 카드 코드는 그대로 두고 아래로 내리기만 한다.

**정직한 실패 방식.** 97퍼센트는 밤잠을 센 숫자다. 사람이 상시 대기 인력이 아니라는 사실을 화면이 크게 적지 않으면, 이 숫자는 "너 때문이야"라는 말로 읽히고 사용자가 화면을 안 열게 된다. 참조 모델의 `HUMAN_BOTTLENECK.md` 는 이 위험을 알고 "95퍼센트는 과장이다. 자는 시간도 셌다"를 한 눈에 섹션 안에 넣었다. 둘째 위험은 대기 큐가 짧다는 것이다. 지금 `waiting` goal 이 2건뿐이라 표가 허전해 보일 수 있다. 끊긴 홉과 미등록 워커를 같은 큐에 넣는 이유가 그것인데, 성격이 다른 것을 한 줄에 섞으면 "이 표는 무엇의 목록인가"가 흐려질 위험도 같이 진다.

### 방향 C — 핸드오프 해부 (홉 내부 축)

**한 문장 약속.** 화면을 열면 지금까지 가장 비쌌던 위임이 무엇이고, 그 위임의 시간이 맥락을 다시 캐는 데 갔는지 실제 산출에 갔는지를 3초에 안다.

**배치.** 상단에 위임 총계와 내부 턴·도구 호출·내부 시간. 그 아래 위임을 비싼 순으로 세우고, 각 행이 폭포 막대다. 지시문 크기, 받은 쪽이 첫 산출 전에 부른 Read/Grep 횟수, 실제 출력 토큰이 한 줄에 이어진다. 맨 아래에 중첩 위임.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 루프 엔지니어링 · 핸드오프 해부                            [새로고침] │
├──────────────────────────────────────────────────────────────────────┤
│ 위임 96건 (최상위 84 · 중첩 12) · 내부 트랜스크립트 조인 91건 (95%)   │
│ 내부 턴 5,081회 · 내부 도구 호출 2,865회 · 내부 시간 14.8h            │
├──────────────────────────────────────────────────────────────────────┤
│ 비싼 위임 순                                                          │
│ ────────────────────────────────────────────────────────────────────│
│ manager-pm   부모 goal 자동분류 기능 제안                    4,162초  │
│   지시문 3KB                                                          │
│   맥락 재캐기 ████████████░░░░░░░░   도구 26회 중 18회 Read/Grep      │
│   실제 산출  ░░░░░░░░░░░░████████    출력 27,288 토큰                 │
│   턴 59회 · 입력 2,086,080 토큰                                       │
│   [트랜스크립트 열기]  [지시문 보강]  [에이전트 교체]                 │
│ ────────────────────────────────────────────────────────────────────│
│ agent-architect  Agent naming taxonomy + rename              2,087초  │
│   맥락 재캐기 ██████████████░░░░░░   도구 57회                        │
│   턴 127회 · 입력 17,556,802 토큰 · 출력 4,777 토큰                   │
│   [트랜스크립트 열기]  [지시문 보강]  [에이전트 교체]                 │
│ ────────────────────────────────────────────────────────────────────│
│ general-purpose  Build orchestration menu + page             1,584초  │
│   턴 193회 · 도구 84회 · 입력 28,005,992 토큰 · 출력 2,827 토큰       │
├──────────────────────────────────────────────────────────────────────┤
│ 에이전트 종류별                       건수    내부시간   턴    도구   │
│  general-purpose                        61      8.7h  3,166  1,812   │
│  manager-pm                              6      2.3h    335    175   │
│  Explore                                15      0.7h    606    353   │
├──────────────────────────────────────────────────────────────────────┤
│ 중첩 위임 12건 — 에이전트가 에이전트를 부른 것. 지금 화면에 없다.     │
└──────────────────────────────────────────────────────────────────────┘
```

**필요한 데이터와 지금 있는지 여부.**

- **전부 있다. 새 계측이 필요 없다.** 3-1에서 실측한 그대로다. 위 표의 모든 숫자는 이미 이 조사에서 디스크에서 뽑은 실제 값이다.
- 필요한 코드 변경은 하나다. `LoopScan` 이 `~/.claude/projects/<slug>/<sessionId>/subagents/` 로 내려가 `agent-<id>.jsonl` 과 `agent-<id>.meta.json` 을 읽고, `meta.toolUseId` 로 홉에 붙인다.
- **"맥락 재캐기" 지표만 정의를 새로 정해야 한다.** 제안: 서브에이전트의 첫 어시스턴트 텍스트 출력이 나오기 전까지의 Read/Grep/Glob 호출 수를 재캐기로 센다. 이것은 계측이 아니라 판정 규칙이라 `docs/loop-engineering.md` 에 적어야 하고, 적기 전에는 화면에 띄우면 안 된다.
- **못 재는 것 하나는 남는다.** 그 Read/Grep 중 몇 번이 "앞 홉이 이미 알던 것"이었는지는 알 수 없다. 두 홉이 같은 파일을 봤는지는 셀 수 있지만, 앞 홉이 그 내용을 지시문에 실어 줄 수 있었는지는 판단이다. 화면은 "재캐기 후보"라고 적어야지 "낭비"라고 적으면 안 된다.

**사용자가 무엇을 하는가.** `[지시문 보강]` 은 그 위임의 지시문과 받은 쪽이 처음 읽은 파일 목록을 나란히 보여 준다 — 다음 지시문에 무엇을 미리 실어야 하는지가 그 대조에서 나온다. `[에이전트 교체]` 는 기존 판정 원장(`AgentVerdicts`, `AgentInventory.swift:289`)에 `replace` 를 기록한다. `[트랜스크립트 열기]` 는 서브에이전트 `.jsonl` 을 연다.

**빌드 규모.** 중간에서 큼. 손대는 파일: `Sources/ConditionMate/Core/LoopScan.swift`(하강과 조인, 내부 집계), `Sources/ConditionMate/AppDelegate.swift`, `Sources/ConditionMate/Dashboard/LoopEngineeringContent.swift`(폭포 막대는 새 시각 요소라 CSS 가 새로 든다), `docs/loop-engineering.md`. 성능 주의: 서브에이전트 파일이 개당 300~450KB이고 101개다. 지금의 파일 단위 캐시(`OrchestrationScan.swift:70-77`)를 그대로 적용하면 된다.

**정직한 실패 방식.** **이 방향은 잘 만들어도 틀린 곳을 겨눈다.** 같은 창(2026-08-01 이후)에서 에이전트 내부 가동이 12.1시간일 때 사람 대기가 393.4시간이다. 30배 차이다. 위임 한 건의 내부 효율을 20퍼센트 개선해도 전체 처리량은 거의 안 움직인다. 아름다운 계측기를 만들어 놓고 병목이 아닌 축을 정밀하게 재게 된다. 두 번째 위험은 조인율 95퍼센트가 앞으로 유지된다는 보장이 없다는 것이다. `subagents/` 폴더는 최근 Claude Code 판본이 만들기 시작한 것으로 보이고(파일 47개 폴더가 전부 2026-08-19 이후), 형식이 바뀌면 화면의 주력 숫자가 통째로 사라진다.

---

## 6. 권고 — 방향 B, 그리고 그 1단계

### 권고: 방향 B를 택한다.

이유가 넷이다.

**첫째, 사용자가 말한 문제에 직접 답한다.** "병목이 어디인지 모르겠다"의 답은 숫자 하나여야 한다. 방향 B의 첫 줄이 그것이다. 방향 A의 첫 줄은 아홉 칸 격자이고, 방향 C의 첫 줄은 위임 목록이다. 둘 다 여전히 읽어서 판단해야 한다.

**둘째, 측정된 병목이 실제로 사람이다.** 사람 대기 393.4시간 대 에이전트 가동 12.1시간이다. 방향 C는 12.1시간 쪽을 정밀하게 재는 화면이다.

**셋째, 새 계측 없이 서는 유일한 방향이다.** 방향 A는 다섯 칸이 빈 채로 출발하고, 그 다섯 칸을 채우려면 여러 에이전트 정의에 원장 쓰기 규칙을 심어야 한다. 그 규칙이 이 저장소에서 지켜지지 않고 있다는 증거가 이미 있다 — `agent-update-log.jsonl` 은 마지막 기록이 2026-08-21이고 지금 이름의 에이전트는 아무도 안 적고 있다. 방향 B의 세 축(사람 대기, 에이전트 가동, 결정 대기 큐)은 전부 오늘 디스크에 있다.

**넷째, 되돌리기 쉽다.** 기존 프로젝트 카드 28개를 지우지 않고 아래로 접어 내린다. 새 상단 블록이 쓸모없다고 판명되면 그 블록만 걷어내면 지금 화면으로 돌아온다.

### 명시적으로 하지 않는 것

- L1..L9 루프 보드를 이번에 만들지 않는다. 다섯 칸이 비어 있어서다.
- `pipeline_events.jsonl` 에 해당하는 단계 이벤트 원장을 이번에 도입하지 않는다.
- 핸드오프 폭포 막대를 이번에 만들지 않는다. 다만 그 데이터원(서브에이전트 트랜스크립트)은 1단계에서 읽기 시작한다 — 에이전트 가동 시간이 거기서 나오기 때문이다.
- `trackedSeconds` 를 어떤 숫자에도 쓰지 않는다.

### 1단계 조각 — 이것만으로도 "병목이 보인다"가 성립한다

**넣는 것 셋.**

1. **상단 병목 밴드.** 사람 병목 지수 하나, 막대 하나, 분자·분모 한 줄, 한계 한 줄("4시간 상한 · 잠자는 시간 포함 · 사람이 워커로 일한 시간과 결정을 기다린 시간이 분리되지 않아 실제보다 높다").
2. **"지금 열려 있는 대기" 표.** 체류 내림차순. 세 종류를 한 표에 담는다 — `waiting` goal(사람), 끊긴 홉(워커), 미등록 예약 워커(진입점). 각 행에 임계와 STALLED 판정, 그리고 동작 버튼 하나 이상.
3. **`~/.condition-mate/ledger/loop-history.jsonl` 개시.** 하루 몇 번 정해진 시각에 한 줄 append. 지수 하나가 추세가 되는 유일한 길이다. 이 파일은 절대 덮어쓰지 않는다.

**1단계에서 빼는 것.**

- 액터별 가동/대기 표. 담당 다섯 중 넷이 "기록 없음"이라 표가 거의 비어 보인다. 2단계로 미룬다.
- 추세 그래프. 1단계에서는 append 만 하고 화면에는 최근 3개 값을 텍스트로만 적는다.
- 프로젝트별 라우트 28곳. 지금 코드 그대로 두되 기본 접힘으로 내린다.

**1단계만으로 성립하는 이유.** 지금 사용자가 화면을 열면 판정 28개를 읽어야 한다. 1단계 후에는 첫 화면에 숫자 하나와 STALLED 행 몇 개가 있고, 그 행마다 누를 것이 있다. "병목이 어디냐"와 "그래서 뭘 하냐"가 둘 다 첫 화면에서 답해진다. 나머지는 정밀도이지 존재 여부가 아니다.

---

## 7. SPEC 편집 — 지금 이 페이지는 SPEC 에 한 줄도 없다

`docs/specs/SPEC.md` 를 전량 확인했다. 항목 54개, 접두어는 `EP-`(18), `WINLIFE-`(12), `DASH-`(9), `BGMACT-`(8), `WIDGET-`(3), `LOG-`(2), `BGMDBG-`(2), `DOC-`(1)이다. **`/orchestration` 페이지와 `/api/orchestration` 에 대한 SPEC 항목은 하나도 없다.** 즉 이 페이지는 회귀 보호가 전혀 없는 상태로 존재해 왔다.

그러므로 이번 작업의 SPEC 편집은 "기존 항목 수정"이 아니라 "새 페이지 등재"다.

**편집 1 — 페이지 색인에 한 행 추가.** `docs/specs/SPEC.md:23` 의 "Page index" 표 맨 아래(`| P7. Cross-cutting: logging | LOG- | Core/AppLog.swift |` 다음)에 다음을 추가한다.

`| P8. App window — 루프 엔지니어링 페이지 | LOOP- | Dashboard/LoopEngineeringContent.swift, Core/LoopScan.swift, AppDelegate.loopEngineeringJSON() |`

**편집 2 — `## P8. 루프 엔지니어링` 절 신설.** `## P7` 절 뒤, `## OPEN QUESTIONS`(현재 `:1481`) 앞에 넣는다. 항목은 다음 넷이다. 앞의 셋은 이름 변경 단계에서, 넷째는 화면 개편 1단계에서 등재한다.

- **LOOP-1 — 레일 아홉 번째 슬롯은 `/loop-engineering` 으로 간다.**
  EN: The rail's ninth nav item is labeled `루프 엔지니어링`, carries `data-nav="loop"`, and navigates to `/loop-engineering`. The page sets `window.CM_PAGE='loop'` so `cmNavReflect()` highlights that slot. The label wraps to two lines as `루프` / `엔지니어링` because `.cmr-lbl.wrap2` uses `word-break:keep-all` — it must NOT break mid-word.
  KO: 레일 아홉 번째 항목의 라벨은 `루프 엔지니어링` 이고 `data-nav="loop"` 이며 `/loop-engineering` 으로 이동한다. 페이지는 `window.CM_PAGE='loop'` 를 세워 `cmNavReflect()` 가 그 슬롯을 켜게 한다. 라벨은 `루프` / `엔지니어링` 두 줄로 끊긴다 — `.cmr-lbl.wrap2` 가 `word-break:keep-all` 이기 때문이며, 단어 중간에서 끊기면 회귀다.

- **LOOP-2 — 옛 경로 `/orchestration` 은 404가 아니라 `/loop-engineering` 으로 보낸다.**
  EN: `GET /orchestration` returns 200 with a redirect document pointing at `/loop-engineering`; it must be matched BEFORE the `/loop-engineering` prefix in `AppDelegate.page`. `GET /api/orchestration` is gone and returns 404 — the only in-repo caller (`.claude/agents/lion-condition-mate-po-loop-engineering.md`) was updated in the same change.
  KO: `GET /orchestration` 은 404가 아니라 200으로 `/loop-engineering` 리다이렉트 문서를 돌려준다. `AppDelegate.page` 에서 `/loop-engineering` 보다 **먼저** 매칭돼야 한다. `GET /api/orchestration` 은 없어지고 404다 — 저장소 안의 유일한 호출자인 위 에이전트 정의를 같은 변경에서 고쳤다.

- **LOOP-3 — `GET /api/loop-engineering` 페이로드 계약.**
  EN: Returns `totals`, `projects[]`, `harness[]`, `scannedAt`. Each project carries exactly one `verdict {cat, num, text}` chosen by the fixed ladder documented in `docs/loop-engineering.md`: dead hop, entry point, termination condition, part, unmeasurable, none. A project with no parts, no hops, no teams and no workers is NOT emitted.
  KO: `totals`, `projects[]`, `harness[]`, `scannedAt` 을 돌려준다. 프로젝트마다 `verdict {cat, num, text}` 가 정확히 하나이며 `docs/loop-engineering.md` 의 고정 사다리(끊긴 홉 → 진입점 → 종료 조건 → 파트 → 측정 불가 → 없음)로 고른다. 파트·홉·팀·워커가 모두 없는 프로젝트는 싣지 않는다.

- **LOOP-4 — 화면 개편 1단계에서 등재. 병목 밴드와 열려 있는 대기.**
  EN: The page's first screen shows one human-bottleneck percentage with its numerator, denominator and stated limits, then an "open waits" table sorted by dwell descending. Every row carries a threshold, a STALLED/정상 verdict, and at least one action. A resolved wait must disappear from the table on the next load. The 28 project cards render collapsed below it.
  KO: 첫 화면은 사람 병목 지수 하나를 분자·분모·한계와 함께 보이고, 그 아래 체류 내림차순의 "지금 열려 있는 대기" 표를 보인다. 모든 행에 임계와 STALLED/정상 판정과 동작 하나 이상이 붙는다. 해소된 대기는 다음 조회에서 표에서 사라져야 한다. 프로젝트 카드 28개는 그 아래에 접힌 채로 그린다.

**편집 3 — 측정 정의 문서의 사실 정정.** `docs/loop-engineering.md`(이름 변경 후)의 "재지 못하는 것" 절에서 "핸드오프 비용은 이 맥에서 측정할 수 없다 … 전체 892개 파일에서 0건이다"를 삭제하고 다음으로 교체한다. "서브에이전트의 내부 턴은 `~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.jsonl` 에 남는다. 2026-08-23 실측으로 트랜스크립트 101개, 내부 턴 5,081회, 내부 도구 호출 2,865회, 내부 벽시계 시간 14.8시간이다. `agent-<id>.meta.json` 의 `toolUseId` 가 위임의 `tool_use` 아이디와 같아 위임 96건 중 91건(95퍼센트)이 조인된다. 여전히 재지 못하는 것은 그 내부 도구 호출 중 몇 번이 앞 홉이 이미 알던 것을 다시 캔 것인지의 판정이다." 같은 정정을 `.claude/agents/lion-condition-mate-po-loop-engineering.md` 의 "What you cannot measure here" 절과, 화면의 `이 화면이 재지 못하는 것` 안내문(`OrchestrationContent.swift:166-171`)에도 적용한다.

---

## 8. 작업 계획 — 순서와 게이트

**1단계. 이름 변경.** 담당: 구현 에이전트. 4-5의 여덟 단계를 순서대로. 산출물은 `swift build` 통과와 SPEC 의 LOOP-1·LOOP-2·LOOP-3 등재다.
게이트: `lion-condition-mate-worker-qa` 가 LOOP-1·LOOP-2·LOOP-3 에 대해 PASS. 특히 옛 경로가 404가 아닌지, 레일 라벨이 `루프` / `엔지니어링` 으로 끊기는지, `/api/orchestration` 이 실제로 404가 되었는지.

**2단계. `.e2e` 격자 테스트 복구.** 담당: 구현 에이전트. 4-6의 `plan.test.js` 세 곳. `memofocus.test.js` 는 별건으로 분리.
게이트: `node plan.test.js` 전체 PASS.

**3단계. 스캔 범위 확장.** 담당: 구현 에이전트. `LoopScan` 이 `subagents/` 로 내려가 `meta.toolUseId` 로 조인하고, 백그라운드 위임의 소요시간을 자식 트랜스크립트의 첫/끝 시각으로 복구하며, 중첩 위임 12건을 센다.
게이트: `/api/loop-engineering` 의 `totals.hours` 가 3.7에서 12시간대로 오르고 `totals.runs` 가 84에서 96으로 오르는 것을 QA 가 확인. 오르지 않으면 조인이 안 된 것이다.

**4단계. 화면 개편 1단계.** 담당: 구현 에이전트. 6장의 세 블록. SPEC 에 LOOP-4 등재.
게이트: `lion-condition-mate-worker-qa` 가 LOOP-4 PASS. 특히 "해소된 대기가 다음 조회에서 사라진다"를 실제로 goal 하나를 `waiting` 에서 `in_progress` 로 돌려 확인.

**5단계. 문서 정정 반영.** 담당: `lion-condition-mate-po-loop-engineering`. 7장 편집 3. 이 에이전트가 측정 정의의 소유자이므로 여기서 한다.
게이트: 문서와 화면 안내문과 에이전트 정의 세 곳이 같은 말을 하는지 대조.

---

## 9. 열린 질문 — 착수 전에 사용자가 정해야 하는 것

**Q1. 사람 대기의 상한을 몇 시간으로 둘 것인가.** 상한 없음이면 지수가 99.1퍼센트, 4시간이면 97.0퍼센트, 1시간이면 96.0퍼센트다. 상한은 "사람은 상시 대기 인력이 아니다"를 숫자에 반영하는 유일한 손잡이인데, 어디로 두든 자의적이다. 기본값을 4시간으로 제안하되 화면에 상한을 명시하는 것을 권한다. 이것은 지수의 크기 자체를 바꾸는 결정이라 임의로 정하지 않겠다.

**Q2. "지금 열려 있는 대기" 표에 세 종류를 같이 담을 것인가.** 사람 응답 대기(goal `waiting`), 끊긴 홉, 미등록 예약 워커는 성격이 다르다. 한 표에 담으면 "지금 막힌 것 전부"라는 하나의 목록이 생기고, 나누면 각 표가 무엇인지는 또렷하지만 첫 화면에 표가 세 개가 된다. 참조 모델은 열려 있는 대기와 승인 큐를 나눠 두었다. 지금 goal `waiting` 이 2건뿐이라 나누면 표 하나가 두 줄이 된다.

**Q3. `/api/orchestration` 별칭을 정말 안 남길 것인가.** 4-3에서 안 남기기를 권했다. 근거는 저장소 안 호출자가 둘뿐이고 둘 다 같은 커밋에서 고친다는 것이다. 다만 사용자가 개인적으로 만든 스크립트나 다른 워크스페이스의 에이전트가 이 경로를 부르고 있다면 조용히 깨진다. 그런 소비자가 있는지는 이 저장소 안에서 확인할 방법이 없다.

**Q4. 루프 정의를 문서로 옮기는 것을 이번 범위에 넣을 것인가.** 2장에서 L1..L9 가 에이전트 프롬프트 안에만 있다고 확인했다. 옮기는 것 자체는 작지만, 옮기는 순간 그것이 이 워크스페이스의 공식 루프 정의가 되고 앞으로 칸을 늘리거나 줄이는 권한이 `lion-condition-mate-po-loop-engineering` 한 곳으로 고정된다. 조직적 결정이라 PM 이 단독으로 정할 일이 아니다.

**Q5. `trackedSeconds` 의 오염을 이번에 고칠 것인가.** 3-3에서 최근 7일 완료 goal 50건의 합이 6,072시간으로 나오는 것을 확인했다. 이 제안의 어느 방향도 이 필드를 쓰지 않으므로 이번 작업에는 지장이 없다. 다만 대시보드의 다른 화면이 이 값을 쓰고 있다면 그쪽은 이미 틀린 숫자를 보이고 있는 것이다. 별건으로 다룰지 여기서 같이 볼지를 정해야 한다.

---

## 한 눈에 (원시인 버전, 다시)

이름 바꾸기는 작다. 파일 9개다. 테스트 안 깨진다. URL 은 옛 주소에 이정표만 남긴다.
라벨은 `루프 엔지니어링` 그대로 쓴다. CSS 한 글자 고치면 `루프` / `엔지니어링` 으로 예쁘게 끊긴다.
화면은 방향 B로 간다. 숫자 하나, 대기 표 하나, 버튼.
사람이 병목이다. 97퍼센트. 에이전트 12시간, 사람 393시간.
문서가 틀렸다. 서브에이전트 속 기록 101개가 디스크에 있다. 없다고 적혀 있었다.
루프 아홉 칸은 정의만 있고 적는 곳이 없다. 그래서 이번엔 안 그린다.
사용자가 정할 것 5개. 특히 대기 상한 몇 시간으로 할지.
