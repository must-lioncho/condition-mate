# 로컬 세션 관리 정책서 (Session Lifecycle Policy)

작성일: 2026-06-24
대상: condition-manager (macOS 메뉴바 앱) + 내장 웹 대시보드
관련 문서: loop-status-design.md, bgm-management.md

## 1. 목적

Claude 데스크톱 앱의 "세션 보관(archive)"과 condition-manager 웹 대시보드의
"목표 완료(done)"를 하나의 동일한 생명주기 개념으로 통합한다.
두 시스템이 같은 작업 단위를 서로 다른 상태로 들고 있어 발생하는 불일치를 없앤다.

핵심 정의:
- 보관(archive)과 완료(done)는 같은 종착 상태의 두 표현이다.
- 한 쪽에서 종료시키면 다른 쪽도 같은 종료 상태가 되어야 한다.

## 2. 배경 사실 (검증 완료)

아래는 추측이 아니라 실제 파일을 읽어 확인한 사실이다.

### 2.1 세 개의 데이터 소스

첫째, Claude Code 트랜스크립트 로그.
- 경로: 사용자 홈의 .claude/projects/<프로젝트>/<cliSessionId>.jsonl
- 성격: append-only 메시지 로그. 한 줄당 한 레코드.
- 레코드 type 값의 전체 집합: ai-title, assistant, attachment, last-prompt,
  queue-operation, user.
- 중요: 이 파일에는 보관 여부를 나타내는 필드나 레코드가 존재하지 않는다.
  isArchived, archived 같은 구조화 필드가 전혀 없다.

둘째, Claude 데스크톱 앱의 세션 메타데이터.
- 경로: 사용자 홈의 Library/Application Support/Claude/claude-code-sessions/
  <workspace>/<window>/local_<id>.json
- 보관 상태가 실제로 저장되는 곳. top-level 키에 isArchived (true 또는 false)가 있다.
- 함께 들어있는 키: sessionId, cliSessionId, cwd, lastFocusedAt, createdAt,
  lastActivityAt, model, effort, isArchived, title, titleSource, permissionMode 등.
- 이 파일은 Claude 데스크톱 앱이 소유하고 갱신하는 비공개 상태 파일이다.

셋째, condition-manager 자체 데이터.
- 목표: 사용자 홈의 Library/Application Support/ConditionManager/review/goals.json
  (또는 CM_DATA_DIR 환경변수로 재정의된 경로).
- 일일 리뷰: 같은 review 폴더의 review-YYYY-MM-DD.json.
- 유효 상태 집합: backlog, in_progress, done (ReviewStore.swift 의 validStatuses).
- 부모 목표 파생 상태: 자식이 모두 done이면 done, 하나라도 in_progress이면 on_track,
  그 외에는 backlog (DashboardContent.swift).

### 2.2 조인 키 (가장 중요)

세 소스를 연결하는 키는 Claude Code 세션 식별자다.

- goals.json 의 각 목표는 sessionId 필드를 가진다.
- 이 값은 Claude 데스크톱 메타데이터의 cliSessionId 와 동일하다.
- 이 값은 동시에 트랜스크립트 파일명 <cliSessionId>.jsonl 과도 동일하다.
- 주의: 데스크톱 메타데이터의 sessionId 필드는 cliSessionId 와 다른 값이며
  (local_ 접두사가 붙은 내부 식별자), 조인에 사용하면 안 된다.
  반드시 cliSessionId 를 사용한다.

검증 사례:
- 데스크톱 메타데이터 local_4234a279...json 은 cliSessionId 가
  86f8437d-5dfa-48f5-90df-043f66010139 이고 isArchived 가 false 였다.
- goals.json 의 목표 8E51621F 는 sessionId 가
  86f8437d-5dfa-48f5-90df-043f66010139 이고 status 가 backlog 였다.
- 동일 세션인데 두 시스템 상태가 불일치한다. 이 정책이 해결하려는 바로 그 상황이다.

### 2.3 현재 동작 (정책 적용 전)

- condition-manager 는 Claude Code 의 세션 라이프사이클 훅(start, active, idle, end)을
  HTTP 엔드포인트 api/session/event 로 수신해 목표 상태를 자동 전환한다
  (cc-session-hook.sh, AppDelegate.swift, ReviewStore.recordSession).
- condition-manager 는 현재 Claude 데스크톱의 isArchived 필드를 읽거나 감시하지 않는다.
- 따라서 데스크톱에서 보관해도 웹 상태는 바뀌지 않는다. 이 정책이 그 연결을 추가한다.

## 3. 상태 매핑 규칙

보관과 완료의 대응을 다음과 같이 고정한다.

- Claude 데스크톱 isArchived 가 true 인 세션은 웹에서 done 으로 본다.
- 웹에서 done 으로 표시된, 세션이 연결된 목표는 Claude 데스크톱에서 보관(archived) 대상이다.
- isArchived 가 false 인 세션은 보관 신호로 간주하지 않는다. 단, 웹의 done 을
  자동으로 backlog 로 되돌리지는 않는다 (4.3 충돌 규칙 참조).

## 4. 정책

### 4.1 정책 1 — 데스크톱 보관에서 웹 완료로 (앱에서 웹으로)

목표: 사용자가 Claude 데스크톱 앱에서 세션을 보관 처리하면, 그 세션에 연결된
웹 대시보드 목표가 자동으로 완료(done)가 된다.

동작 절차:
- condition-manager 가 claude-code-sessions 디렉토리를 파일 감시(FSEvents 또는
  DispatchSource 기반)한다.
- cwd 가 현재 프로젝트 경로와 일치하는 local_<id>.json 만 대상으로 한다.
- 어떤 파일의 isArchived 가 false 에서 true 로 바뀌면 다음을 수행한다.
  - 그 파일의 cliSessionId 를 읽는다.
  - goals.json 에서 sessionId 가 그 cliSessionId 와 같은 목표를 찾는다.
  - 찾은 목표의 status 를 done 으로 설정하고 저장한다.
  - 대응 목표가 없으면 아무 것도 하지 않고 무시한다.

성격: 이 방향은 읽기 전용 감시이므로 안전하다. Claude 데스크톱 파일을 수정하지 않는다.
견고하게 구현 가능하다.

설계 결정 사항(미정):
- 부분 매칭 정책. 자식 목표만 세션에 연결된 경우, 그 자식만 done 으로 할지
  부모까지 파생 규칙으로 done 처리할지 결정 필요. 권고: 자식만 done 으로 두고
  부모는 기존 파생 규칙(모든 자식 done 시 done)에 맡긴다.

### 4.2 정책 2 — 웹 완료에서 데스크톱 보관 및 사라짐으로 (웹에서 앱으로)

목표: 사용자가 웹 대시보드에서 목표를 완료 처리하면, 그 목표는 활성 목록에서
사라지고 가능하면 Claude 데스크톱에서도 보관 처리된다.

오해 교정 (반드시 명시):
- "jsonl 에 업데이트한다"는 것은 보관 처리에 사용할 수 없다. 트랜스크립트 jsonl 은
  append-only 메시지 로그이며 보관 상태 필드가 없다. 여기에 무엇을 써도
  Claude 데스크톱의 보관 상태는 바뀌지 않는다.
- 보관 상태를 실제로 바꾸려면 메타데이터 local_<id>.json 의 isArchived 를
  true 로 써야 한다.

동작 절차:
- 사용자가 웹에서 완료 버튼을 누르면 api/goal/status 경로로 목표 status 를
  done 으로 바꾼다. 이 부분은 이미 구현되어 있고 안전하며 신뢰할 수 있다.
- done 이 된 목표는 웹 활성 목록에서 숨긴다 (별도 완료 보관함 또는 비표시).
  이 동작도 condition-manager 자체 데이터 안에서 일어나므로 신뢰할 수 있다.
- (베스트 에포트) 목표에 sessionId 가 연결되어 있으면, 대응하는
  local_<id>.json 의 isArchived 를 true 로 기록 시도한다.

베스트 에포트로 한정하는 이유 (위험 요소):
- local_<id>.json 은 Claude 데스크톱 앱이 소유하는 비공개 상태 파일이다.
  공개 API 가 아니며 형식이 예고 없이 바뀔 수 있다.
- 앱이 세션 상태를 메모리에 들고 있다가 파일을 덮어쓸 수 있어, 외부 쓰기가
  경쟁 상태(race)로 사라질 수 있다.
- 앱이 파일 변경을 실시간으로 다시 읽는다는 보장이 없다. 보관 표시가
  앱 재시작 또는 새로고침 후에만 반영될 수 있다.

따라서 정책 2 의 진실 원천(source of truth)은 condition-manager 의 goals.json 이며,
데스크톱 보관 쓰기는 실패해도 사용자 흐름을 막지 않는 부가 동작으로 취급한다.
데스크톱 쓰기를 시도할 경우 다음을 지킨다.
- 쓰기 직전 파일을 다시 읽어 cliSessionId 가 여전히 일치하는지 확인한다.
- isArchived 한 필드만 바꾸고 나머지 키는 원본 그대로 보존해 다시 쓴다.
- 쓰기 실패나 형식 불일치 시 조용히 포기하고 웹 완료 상태는 유지한다.

### 4.3 충돌 규칙 (양방향 동기화 안전장치)

양방향 동기화는 무한 루프와 상태 깜빡임 위험이 있으므로 다음을 따른다.

- 종료 상태는 단방향으로만 전파한다. backlog 또는 in_progress 에서 done 으로,
  그리고 false 에서 true 로만 전파한다. 그 반대(되돌리기)는 자동 전파하지 않는다.
- 데스크톱 isArchived 가 true 에서 false 로 풀려도 웹 done 을 자동으로
  되돌리지 않는다. 되돌리기는 사용자가 웹에서 명시적으로 한다.
- 정책 1 의 감시가 발생시킨 goals.json 변경이 정책 2 의 데스크톱 쓰기를
  다시 트리거하지 않도록, 변경 출처를 구분하는 표시(예: 마지막 동기화 출처)를
  두어 같은 전이를 두 번 처리하지 않는다.
- 같은 전이는 멱등(idempotent)하게 처리한다. 이미 done 인 목표를 다시 done 으로
  만드는 신호는 무시한다.

### 4.4 정책 3 — 번호 스탬프 워커 (수동 싱크 보조)

목표: 정책 1, 2 의 자동 동기화에 의존하지 않고도, 사람이 Claude 데스크톱 세션과
웹 목표를 눈으로 매칭해 직접 보관/완료할 수 있도록, 양쪽에 같은 번호를 보이게 한다.
이 정책은 자동 보관 동기화(정책 1)보다 먼저, 단독으로 도입한다.

번호의 정의:
- 번호는 목표의 기존 seq 필드를 그대로 쓴다. 새 식별자를 만들지 않는다.
- 표시 형식은 제목 맨 앞의 대괄호 정수다. 예: seq 가 22 인 목표는 [22] 로 표시한다.
- 검증 사례: 목표 seq 22, sessionId 86f8437d 는 데스크톱 세션
  cliSessionId 86f8437d 와 짝이며, 이 세션 제목을 [22] 로 시작하게 만든다.

적용 범위 (결정됨):
- 데스크톱 세션 제목에만 스탬프한다. 웹 목표 제목은 건드리지 않는다.
  웹 대시보드는 이미 seq 를 알고 있으므로 필요 시 표시 규칙만 따로 둔다.
- 따라서 이 워커가 쓰는 대상은 오직 local_<id>.json 의 title 필드다.

워커 동작 절차:
- 주기적으로(타이머 기반) 실행한다.
- goals.json 에서 sessionId 가 채워진 목표만 대상으로 한다.
- 각 목표에 대해 claude-code-sessions 아래에서 cliSessionId 가 그 sessionId 와
  같고 cwd 가 현재 프로젝트인 local_<id>.json 을 찾는다.
- 그 파일의 title 을 읽어 다음 멱등 규칙으로 prefix 를 맞춘다.
  - 제목 맨 앞에 대괄호 정수 패턴이 없으면 [seq] 와 공백을 붙인다.
  - 맨 앞 대괄호 정수가 현재 seq 와 같으면 아무 것도 하지 않는다.
  - 맨 앞 대괄호 정수가 다른 값이면 그 부분만 [seq] 로 교체한다.
  - 절대로 [22] [22] 처럼 중복으로 덧붙이지 않는다.
- title 한 필드만 바꾸고 나머지 키는 원본 그대로 보존해 다시 쓴다.

재스탬프가 필요한 이유:
- 데스크톱 메타데이터의 titleSource 값이 모두 auto 로 관찰되었다. 즉 Claude 앱이
  제목을 AI 로 자동 생성하고 갱신한다.
- 따라서 앱이 제목을 다시 생성하면 우리가 붙인 [seq] 가 사라질 수 있다.
- 워커가 주기적으로 다시 확인해 prefix 를 복원한다. 이 때문에 일회성 쓰기가 아니라
  주기 실행 워커여야 한다.
- 부작용: 앱의 제목 재생성과 워커 재스탬프 사이에 잠깐 [seq] 가 보였다 사라지는
  깜빡임이 생길 수 있다. 이는 감수한다.

위험 (정책 2 와 동일하게 적용):
- local_<id>.json 은 Claude 데스크톱 앱의 비공개 상태 파일이다. 형식이 예고 없이
  바뀔 수 있고, 앱이 메모리 상태로 파일을 덮어쓸 수 있으며, 변경을 실시간으로
  다시 읽는다는 보장이 없다(앱 새로고침 또는 재시작 후 반영될 수 있음).
- 쓰기 실패나 형식 불일치 시 조용히 건너뛰고 다음 주기에 다시 시도한다.

미해결 결정 사항(정책 3 한정):
- titleSource 를 비-auto 값으로 바꿔 앱의 제목 재생성을 멈추게 할지 여부.
  그렇게 하면 깜빡임이 없어지지만, titleSource 의 허용 값을 추정에 의존해야 하므로
  더 위험하다. 기본은 titleSource 를 건드리지 않고 재스탬프로 처리한다.
- 목표의 세션 연결이 해제되거나 목표가 삭제될 때 데스크톱 제목의 [seq] prefix 를
  떼어낼지 여부. 기본은 적극적으로 떼지 않는다.

## 5. 영향받는 구성요소

- 새 파일 감시 컴포넌트: claude-code-sessions 디렉토리에서 cwd 가 일치하는
  local_<id>.json 의 isArchived 전이를 감지한다. (정책 1)
- ReviewStore: cliSessionId 로 목표를 조회하는 함수, done 전이 함수,
  동기화 출처 표시 필드가 필요하다. (정책 1, 정책 2, 충돌 규칙)
- DashboardContent: 완료된 목표를 활성 목록에서 숨기고 완료 보관함으로
  보내는 표시 규칙. (정책 2)
- AppDelegate 라우팅: 기존 api/goal/status 를 재사용한다. 새 엔드포인트는
  필요하지 않다. 데스크톱 보관 쓰기는 status 완료 처리 핸들러 안에서
  베스트 에포트로 호출한다. (정책 2)

## 6. 도입 순서 (결정됨)

- 먼저 정책 3(번호 스탬프 워커)을 단독으로 도입한다. 데스크톱 세션 제목에만
  [seq] 를 스탬프하고, 사람이 양쪽 번호를 보고 수동으로 보관/완료한다.
- 정책 1(데스크톱 보관에서 웹 완료로, 읽기 전용 감시)은 안전하지만 이번 범위에서
  보류한다. 추후 도입한다.
- 정책 2(웹에서 데스크톱 보관 쓰기)는 위험이 가장 크므로 가장 나중에, 별도 결정으로
  도입한다.

## 7. 미해결 결정 사항

다음 항목은 구현 착수 전에 사용자 확인이 필요하다.

- 정책 2 에서 데스크톱 보관 쓰기를 실제로 시도할지, 아니면 웹 완료와 활성
  목록 숨김까지만 하고 데스크톱은 건드리지 않을지. 안전을 우선하면 후자다.
- 완료된 목표를 영구 숨김할지, 별도 완료 보관함 화면에서 다시 볼 수 있게 할지.
- 세션이 연결되지 않은(sessionId 가 빈) 목표의 완료 흐름. 이 경우 정책 2 의
  데스크톱 쓰기는 자연히 건너뛴다.
- 파일 감시 주기와 디바운스 정책. 메타데이터 파일은 앱이 자주 갱신하므로
  isArchived 전이만 필터링해 불필요한 처리를 막아야 한다.

## 8. 요약

- 보관과 완료를 같은 종착 상태로 정의한다.
- 조인 키는 goal.sessionId 와 데스크톱 cliSessionId 의 일치다.
- 정책 1(앱에서 웹)은 읽기 전용 감시로 견고하게 구현 가능하다.
- 정책 2(웹에서 앱)에서 jsonl 은 보관 저장소가 아니다. 진실 원천은 goals.json 이고,
  데스크톱 isArchived 쓰기는 위험을 동반한 베스트 에포트 부가 동작이다.
- 종료 상태는 단방향으로만 전파하고, 되돌리기는 사용자가 명시적으로 한다.
- 1차 도입은 정책 3 이다. 주기 워커가 데스크톱 세션 제목에만 [seq] 를 멱등하게
  스탬프하고(titleSource 가 auto 라 재스탬프 필요), 사람이 양쪽 번호를 보고
  수동으로 보관/완료한다.
