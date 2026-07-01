# 스프린트 기능 구현 설계서

`sprint-policy.md`(개념)를 실제 코드로 옮기는 설계. 지라 스크럼 모델을 이 앱의 골/뷰 구조에 맞춰 단순화한다.

## 확정된 결정 사항

- 기간 설정: 시작일 + 기간 프리셋(1일·2일·3일·1주·2주·1달) 중 선택 → 종료일 자동 계산
- 뷰 구조: 뷰 전환 드롭다운에 "스프린트" 항목 1개만 추가하고, 그 안에서 활성 스프린트를 선택
- 배정 단위: 골 1개는 스프린트 1개에만 속함. 자식 골은 부모의 스프린트를 자동 상속
- 아카이브: 스프린트를 아카이브(완료)하면 미완료 골은 백로그(sprint=0)로 되돌림

## 데이터 모델

### Goal 확장 (ReviewStore.swift)

- 필드 추가: sprint(정수, 기본 0). 0은 미배정 = 백로그를 뜻함
- 기존 관용 디코더 패턴을 그대로 따른다: CodingKeys에 sprint 추가, init(from:)에서 decodeIfPresent로 읽고 없으면 0
- 유효 스프린트(effective sprint)는 읽는 쪽에서 계산한다. 최상위 골은 자신의 sprint 값을, 자식 골은 부모의 sprint 값을 따른다. 저장은 최상위 골에만 의미가 있다

### Sprint 신규 모델 (sprints.json)

골과 분리된 별도 파일에 스프린트 정의를 저장한다. 필드는 다음과 같다.

- number: 고유·불변 번호. seq처럼 한 번 부여하면 재배정/재사용하지 않는다
- name: 표시 이름. 기본값은 "스프린트 N"
- goalText: 이 스프린트가 끝났을 때 완성될 결과물 정의(선택). 정책서의 "완성 단위" 원칙을 반영
- startAt: 시작 일시(미정이면 비움)
- durationKind: 기간 프리셋 문자열. 1d, 2d, 3d, 1w, 2w, 1m 중 하나
- endAt: 종료 일시. startAt과 durationKind에서 자동 계산하되 저장해 둔다
- state: active 또는 archived
- createdAt: 생성 시각

여러 개의 active 스프린트가 동시에 존재할 수 있다. 화면에는 그중 하나만 선택해 보여준다. archived는 선택 목록에서 빠지고 아카이브 화면에서만 열람한다.

## 저장 계층 (ReviewStore)

- goals.json과 동일한 안전장치(로드 성공 여부 가드, 빈 배열 덮어쓰기 방지 백업)를 sprints.json에도 적용
- 메서드: createSprint, updateSprint(이름·결과물·시작일·기간), archiveSprint, deleteSprint, setGoalSprint
- nextSprintNumber는 nextSeq와 동일한 패턴(현재 최대 + 1)
- 기간 계산: endAt = startAt에 durationKind만큼 더한 값. 일 단위(1d/2d/3d)와 주 단위(1w/2w)는 일수 가산, 1m은 Calendar로 한 달 가산
- archiveSprint는 해당 스프린트에 속한 골 중 완료가 아닌 것을 sprint=0으로 되돌린 뒤 state를 archived로 바꾼다
- setGoalSprint는 최상위 골에만 적용한다. 자식 골 id가 들어오면 무시하거나 그 부모에 적용한다. 지정한 번호가 존재하지 않으면(0 제외) 거부

## API (AppDelegate.handlePost)

기존 /api/goal/* 라우터에 다음을 추가한다.

- /api/sprint/create: 이름·기간·시작일을 받아 새 스프린트 생성
- /api/sprint/update: number와 변경할 속성(이름·결과물·시작일·기간)을 받아 갱신
- /api/sprint/archive: number를 받아 아카이브 처리(미완료 골 백로그 복귀 포함)
- /api/sprint/delete: number를 받아 삭제(소속 골은 sprint=0으로)
- /api/goal/sprint: 골 id와 sprint 번호(0=해제)를 받아 배정

reviewJSON 확장:

- 각 골 객체에 sprint 값을 추가한다
- 최상위에 sprints 배열을 추가한다(각 스프린트의 모든 필드를 epoch 초로 직렬화)

## 프론트엔드 (DashboardContent.swift)

### 뷰 전환 바

- 기본 뷰(목록·그룹·테이블·일정·프리뷰) 항목 라벨에 기본 뷰임을 나타내는 표식을 붙인다(예: 라벨 앞에 구분 기호)
- "스프린트" 항목 하나를 드롭다운에 추가한다(사용자가 만든 뷰)

### 스프린트 컨트롤 영역

- 뷰 바 아래에 "스프린트 만들기" 버튼을 둔다. 누르면 스프린트가 생성되고 스프린트 뷰로 전환된다
- 스프린트 뷰일 때만 보이는 영역: 활성 스프린트 선택 드롭다운, 선택된 스프린트의 메타 편집(이름·결과물·시작일 입력·기간 프리셋 선택), 자동 계산된 종료일과 D-day 표시, 아카이브 버튼, 아카이브 열람 버튼

### 골 행

- 각 골 행의 부모# 입력 옆에 스프# 숫자 입력칸을 추가한다(부모#와 동일한 입력 패턴 재사용)
- 최상위 골에만 입력칸을 노출한다. 자식 골은 부모에게서 상속한 스프린트 번호를 흐리게 읽기 전용으로 표시한다
- setSprintByNumber: 입력한 숫자를 /api/goal/sprint로 전송. 빈 값이면 해제(0)

### 스프린트 뷰 렌더링

- 선택된 스프린트의 헤더(이름·결과물·기간 태그·시작~종료·D-day)
- 그 스프린트에 속한 골들을 상태별 칼럼(대기·진행·완료)으로 배치한 보드
- 골 배정 자체는 목록·그룹·테이블 뷰의 스프# 입력으로 수행한다(스프린트 뷰는 보는 화면)
- 기존 상태 필터와 완료 컷오프는 스프린트 뷰에도 동일하게 적용

### 아카이브 화면

- 별도 HTTP 라우트 대신 스프린트 뷰 내부의 모드 전환으로 구현한다
- 아카이브 열람 모드: archived 스프린트 목록과 각 스프린트의 골을 읽기 전용으로 표시. 활성으로 되돌리는 동작(선택) 포함

## 구현 단계

1. 백엔드: Goal.sprint 필드, Sprint 모델, sprints.json 저장 계층, API 엔드포인트, reviewJSON 확장
2. 프론트 데이터 연결: sprints 파싱, effSprint 헬퍼, 스프# 입력과 setSprintByNumber
3. 스프린트 뷰: 뷰 항목과 기본 뷰 표식, 만들기 버튼, 선택 드롭다운과 메타 편집기, 보드 렌더링
4. 아카이브: 아카이브/복원 동작과 아카이브 열람 모드

각 단계마다 swift build로 컴파일을 확인한다.
