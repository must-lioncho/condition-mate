# Goal 상태 모델 확장과 루프 작동 설계 고민

## 1. 이 문서의 목적

여러 에이전트를 동시에 굴릴 때 "지금 무엇이 사람의 결정을 기다리는지", "무엇을 루프가 집어가도 되는지"를 상태값만으로 구분하기 위한 설계 메모다. 최종 목표는 **대기 상태의 goal만 자동으로 집어가 실행하는 루프**를 안전하게 돌리는 것이다. 취소된 것과 잠시 중지한 것은 루프가 절대 건드리지 않아야 한다.

이 문서는 구현 전 단계의 고민 정리이며, 실제 코드 변경 지점과 미결정 사항을 함께 기록한다.

## 2. 현재 상태 (변경 전)

goal의 상태는 세 가지뿐이다. 정의는 `Sources/ConditionManager/Core/ReviewStore.swift`에 있다.

- `backlog` (대기): 아직 시작하지 않음. 기본값.
- `in_progress` (진행): 진행 중. 이때 `startedAt`이 채워져 라이브 세션 시간이 흐른다.
- `done` (완료): 종료.

상태 전이는 두 경로로 일어난다.

첫째, 수동 경로다. 대시보드에서 버튼을 누르면 `/api/goal/status`로 들어와 `ReviewStore.setStatus`가 처리한다. `in_progress`로 들어갈 때 `startedAt`을 찍고, 빠져나올 때 경과 시간을 `trackedSeconds`에 적립한다.

둘째, 자동 경로다. Claude Code 세션 훅(`Scripts/cc-session-hook.sh`)이 `/api/session/event`로 이벤트를 보내면 `ReviewStore.recordSession`이 처리한다. 매핑은 다음과 같다.

- `start` (SessionStart): goal 생성/보장, backlog 유지.
- `active` (UserPromptSubmit): in_progress 진입, 시계 시작.
- `idle` (Stop): 시간 적립 후 backlog 복귀.
- `end` (SessionEnd): 시간 적립 후 done.

## 3. 문제 정의

현재 세 상태로는 다음을 표현하지 못한다.

첫째, 사람의 의사결정을 기다리는 중인지 알 수 없다. 에이전트가 여러 개 돌 때 어떤 것이 멈춰서 입력을 기다리는지, 어떤 것이 실제로 일하는 중인지 `in_progress` 하나로는 구분되지 않는다. 결과적으로 사용자는 모든 진행 항목을 일일이 들여다봐야 어느 것이 자기 응답을 기다리는지 알게 된다.

둘째, "잠시 중지"와 "취소"와 "아직 시작 안 함"이 모두 backlog 한 칸에 섞인다. 루프가 backlog를 집어가도록 만들면, 사용자가 의도적으로 멈춰둔 항목이나 폐기한 항목까지 다시 끌려 들어간다.

셋째, 루프 입장에서 "집어가도 되는 것"의 정의가 모호하다. 자동 실행을 안전하게 하려면 집어가도 되는 상태와 절대 건드리면 안 되는 상태가 명시적으로 갈려 있어야 한다.

## 4. 제안하는 상태 모델

기존 세 개에 세 개를 더해 여섯 개로 확장한다. 상태 키는 영어로, 화면 라벨은 한국어로 둔다. backlog가 이미 "대기"라는 라벨을 쓰므로, 새로 추가하는 의사결정 대기는 라벨 충돌을 피해 "응답 대기"로 부른다.

- `backlog` (대기): 루프가 집어갈 수 있는 큐 후보. 아직 시작 전이거나, 한 턴이 끝나 다시 큐로 돌아온 상태.
- `in_progress` (진행): 에이전트가 실제로 작업 중. `startedAt` 활성.
- `waiting` (응답 대기): 진행 중이었으나 사람의 의사결정/입력을 기다리며 멈춰 있는 상태. 여러 에이전트 중 사용자의 주의가 필요한 것을 한눈에 골라내기 위한 핵심 상태.
- `done` (완료): 정상 종료. 종착 상태.
- `stopped` (중지): 취소는 아니지만 잠시 멈춰둔 상태. 사용자가 의도적으로 보류한 것이며, 루프는 건드리지 않는다. 사용자가 재개하면 backlog로 돌아간다.
- `cancelled` (취소): 폐기. 루프가 영구적으로 무시한다. 필요 시 사용자가 수동으로 되살릴 수 있다.

## 5. 루프 적격성 규칙

루프는 주기적으로 goal 목록을 훑어, 적격 상태인 것만 집어 실행으로 전환한다. 상태별 루프 동작은 다음과 같이 정의한다.

- `backlog`: 루프가 집어가는 유일한 상태. 동시 실행 한도 안에서 in_progress로 전환하고 에이전트를 띄운다.
- `in_progress`: 이미 실행 중이므로 건너뛴다. 중복 실행 금지.
- `waiting`: 루프가 자동으로 재개하지 않는다. 사람의 결정이 선행되어야 하므로 화면에 부각만 하고 큐로는 넣지 않는다.
- `done`: 종착 상태. 건너뛴다.
- `stopped`: 의도적 보류. 건너뛴다. 사용자가 재개하기 전까지 루프 대상에서 제외.
- `cancelled`: 폐기. 영구적으로 건너뛴다.

핵심 원칙은 한 문장으로 정리된다. 루프는 오직 `backlog`만 집어가고, `stopped`와 `cancelled`는 절대 집어가지 않으며, `waiting`은 사람에게 넘긴다.

추가로 루프는 동시 실행 한도를 지켜야 한다. 현재 대시보드는 동시 `in_progress` 개수로 에너지/에이전트 입력을 게이팅하고 있으므로, 루프도 같은 한도를 참조해 무한정 띄우지 않게 한다.

## 6. 상태 전이 설계

전이는 자동(세션 훅)과 수동(대시보드 버튼)으로 나뉜다.

자동 전이는 다음과 같이 정한다.

- backlog 에서 루프 또는 세션 active 이벤트가 들어오면 in_progress 로 간다.
- in_progress 에서 사람의 입력을 기다리는 신호가 오면 waiting 으로 간다.
- waiting 에서 사람이 응답해 다시 작업이 시작되면 in_progress 로 돌아온다.
- in_progress 에서 한 턴이 끝나면(idle) backlog 로 돌아와 다음 루프 차례를 기다린다.
- in_progress 또는 waiting 에서 세션이 닫히면(end) done 으로 간다.

수동 전이는 다음과 같이 정한다.

- 어떤 비종착 상태에서든 사용자가 중지를 누르면 stopped 로 간다.
- stopped 에서 사용자가 재개를 누르면 backlog 로 돌아간다.
- 어떤 상태에서든 사용자가 취소를 누르면 cancelled 로 간다.
- cancelled 에서 사용자가 되살리면 backlog 로 돌아간다.

시간 적립 규칙은 다음 원칙을 따른다. in_progress 에서 빠져나가는 모든 전이(idle, end, stopped, cancelled)는 그 시점까지의 경과 시간을 `trackedSeconds`에 적립하고 `startedAt`을 비운다. waiting 진입 시 시간 처리는 미결정 사항으로 8장에 둔다.

## 7. 신호 출처와 코드 변경 지점

### 7.1 응답 대기(waiting) 신호의 출처

waiting 을 자동으로 잡으려면 "Claude가 사용자 입력을 기다리기 시작했다"는 신호가 필요하다. Claude Code의 Notification 훅 계열 이벤트가 이 목적에 부합한다. 현재 훅 스크립트는 Stop 을 idle 로만 매핑하므로, 입력 대기 신호를 새 이벤트(예: `wait`)로 추가해 보내도록 `Scripts/cc-session-hook.sh`를 확장한다. 자동 신호가 어렵거나 불완전한 경우를 대비해, 대시보드에서 수동으로 waiting 을 지정할 수 있는 버튼도 함께 둔다.

### 7.2 ReviewStore 변경

`Sources/ConditionManager/Core/ReviewStore.swift`의 `validStatuses` 집합에 `waiting`, `stopped`, `cancelled`를 추가한다. `setStatus`는 in_progress 이탈 시 시간 적립 로직을 stopped 와 cancelled 에도 동일하게 적용한다. `recordSession`에는 `wait` 케이스를 추가해 status 를 waiting 으로 두고, 다시 active 가 오면 in_progress 로 되돌린다.

### 7.3 라우팅 변경

`Sources/ConditionManager/AppDelegate.swift`의 `/api/session/event` 처리에서 새 이벤트 문자열을 그대로 통과시키면 되므로 큰 변경은 없다. 수동 중지/취소는 기존 `/api/goal/status` 경로가 status 문자열을 받으므로 새 상태 키만 허용되면 자동으로 동작한다.

### 7.4 대시보드 변경

`Sources/ConditionManager/Dashboard/DashboardContent.swift`에서 상태 버튼 묶음과 필터에 새 상태를 반영한다. 현재 상태 버튼은 대기/진행/완료 세 개이고 필터도 세 개의 토글로 되어 있으므로, 응답 대기/중지/취소를 추가하고 색상과 라벨을 정의한다. 부모 goal의 롤업 상태 계산(derivedStatus)도 새 상태를 어떻게 집계할지 정해야 한다. 특히 응답 대기 자식이 있을 때 부모를 어떻게 표시할지 규칙이 필요하다.

### 7.5 루프 구동 주체

루프 자체는 두 가지 방식이 가능하다. 하나는 앱 내부에 주기 스캐너를 두어 backlog 를 집어 실행으로 전환하는 방식이고, 다른 하나는 외부에서(예: Claude Code의 루프 실행) 대시보드 API를 폴링하며 backlog 목록을 가져와 처리하는 방식이다. 어느 쪽이든 적격성 규칙(5장)과 동시 실행 한도는 동일하게 적용한다. 외부 폴링 방식을 쓰려면 backlog 목록만 추려 반환하는 조회 API가 있으면 편하다.

## 8. 결정 사항 (확정)

다음은 구현 전 합의로 확정된 항목이다.

첫째, waiting 상태의 시간 적립은 대기 시간을 제외한다. waiting 진입 시 적립을 끊고 시계를 멈추며, 대기 시간은 trackedSeconds 에 절대 더하지 않는다. 재개(active) 시 새 활성 윈도를 시작한다. 이 부분은 이미 구현되어 있다(waitingSince 필드, 화면 전용 카운트다운). 참고로 idle 이벤트도 backlog 가 아니라 waiting 으로 매핑된다(Stop 역시 사람에게 제어를 넘긴 상태이므로). 자세한 내용은 waiting-signal-policy.md 를 따른다.

둘째, 종착 상태의 화면 취급은 cancelled 만 숨긴다. done 은 기존 완료 필터 흐름을 그대로 유지하고, cancelled 는 기본 화면에서 숨기되 별도의 취소 토글로 노출한다. stopped 는 waiting 과 마찬가지로 항상 표시한다(사용자가 재개하려면 보여야 한다).

셋째, waiting 신호 신뢰성은 이미 해결되어 있다. Notification 훅 푸시와 transcript 기반 풀 감지(detectWaitingSessions)를 함께 두는 다층 구조가 구현돼 있으므로 이번 작업 범위에서 제외한다.

넷째, 루프 전환 직후 공백 구간은 유예 후 자동 회수로 처리한다. 다만 이 처리는 루프 구동 주체의 책임이며(이번 범위 밖), 루프를 붙일 때 backlog→in_progress 전환 후 일정 시간 내 세션이 붙지 않으면 backlog 로 되돌리는 안전망을 둔다. 기존 detectWaitingSessions 의 풀 기반 안전망과 같은 결의 보호 장치다.

다섯째, 취소/중지의 되돌리기는 모두 유지한다. cancelled/stopped 에서 backlog 로 복귀할 때 trackedSeconds 와 sessionId/transcriptPath 를 그대로 보존한다. 현재 setStatus 가 in_progress 이탈 시 시간만 적립하고 나머지를 건드리지 않으므로 추가 코드 없이 충족된다.

## 9. 구현 현황

이번 작업에서 적용된 변경은 다음과 같다(루프 구동 자체는 외부 담당, 이번 범위는 상태와 API까지).

ReviewStore 의 validStatuses 에 stopped, cancelled 를 추가했다. setStatus 는 기존 in_progress 이탈 분기가 시간 적립과 waitingSince 정리, 연결 보존을 그대로 처리하므로 추가 변경이 필요 없었다. recordSession 에는 보호 가드를 넣어, 상태가 stopped 또는 cancelled 인 goal 은 세션 훅이 라벨과 transcript 만 갱신하고 status 나 시간은 절대 건드리지 않게 했다. 이로써 사용자가 보류하거나 폐기한 goal 을 세션 이벤트가 다시 큐로 끌어오는 일이 없다.

대시보드는 leaf goal 의 상태 위젯을 여섯 개 상태(대기, 진행, 응답 대기, 중지, 취소, 완료)를 담은 콤보박스(select)로 교체했다. 부모 goal 은 종전대로 자식에서 계산한 롤업 상태를 표시한다. 필터 막대에는 취소 토글을 추가했고, cancelled 는 기본 숨김, stopped 는 항상 표시로 두었다.

외부 루프용 조회 엔드포인트로 GET /api/loop/queue 를 추가했다. 응답은 backlog 인 leaf goal 만 seq 순으로 담은 worklist 이며, in_progress/waiting/stopped/cancelled/done 과 부모 goal 은 모두 제외된다. 루프는 이 큐의 항목을 집어 POST /api/goal/status 로 in_progress 로 바꾸고 작업을 진행한 뒤, 완료 시 done, 보류 시 stopped, 폐기 시 cancelled 로 전이시키면 된다.

## 10. 남은 작업 (루프 구동)

상태와 API가 준비되었으므로, 다음 단계는 실제 루프 구동 주체를 붙이는 것이다. 외부 폴링 방식(예: Claude Code 루프)이 /api/loop/queue 를 주기적으로 읽어 동시 실행 한도 안에서 항목을 집어 실행한다. 이때 9장 넷째 항목의 유예-회수 안전망과 동시 실행 한도(현재 대시보드의 active parent 기반 게이팅과 정합)를 함께 구현한다.
