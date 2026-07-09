# tests

Condition Manager의 테스트/프로토타입 아티팩트를 한곳에 모은 인덱스입니다. 세 부류가 있고, 물리적 위치가 다른 것은 각각의 제약 때문입니다.

## 1. prototypes/ — 느슨한 디자인 목업 (정적 HTML)

앱이 서빙하지 않는 순수 기획/디자인 프로토타입입니다. 브라우저로 직접 열어 봅니다. 어떤 런타임 코드도 이 파일들을 로드하지 않습니다.

- automation-level-test.html
- equipment-test.html — 장비/숙련도 기획 (참조: Core/EquipmentStore.swift, Dashboard/EquipmentContent.swift)
- goal-number-search-test.html — 목표 검색의 '검색' 버튼을 goal 번호 즉시 조회(상태 무관: 완료·릴리즈·보관·취소 포함)로 재정의하는 기획 + 상태별 '다시 열기' 액션 매핑 시뮬레이터 (AI검색=기존 findOnly 큐 파이프라인은 별도 버튼으로 분리; 참조: Dashboard/DashboardContent.swift gaSearch/goalSearchFind, Core/ReviewStore.swift setStatus/setArchived/restoreRelease)
- jira-integration-test.html
- mute-ux-test.html
- nss-monitor-testpage.html
- place-shift-test.html
- queue-noti-test.html
- rain-summon-test.html — 장비 페이지 폭우 소환 시 캐릭터 폭우 오버레이(먹구름+빗줄기) 애니메이션 시뮬레이터 (목 API로 소환 성공/XP 부족/폭우 강제 종료/디렉터 자동 시작의 폴링 감지 재현, 시간 배속; 참조: Dashboard/EquipmentContent.swift rainfx, AppDelegate.swift equipmentJSON()의 rain 필드)
- slack-integration-test.html
- sprint-lifecycle-test.html — 스프린트 완료·복원·채번·완료로그 편집 정책 시뮬레이터 (AS-IS/TO-BE 나란히 비교, 케이스 1~7 자동 시나리오; 케이스7=완료 로그 ▸토글/제목클릭 편집 분리 + 기간(시작~완료) 기록; 참조: Core/ReviewStore.swift completeSprint/restoreRelease/nextReleaseCode/cleanupSprints/updateRelease)
- timebase-test.html
- weekly-report-test.html — 주간 보고 개선 기획 (메신저=임팩트만 + 링크→부서/부모별 상세, Diff·정체 태그로 어뷰징 감지)

## 2. 앱에 서빙되는 테스트 페이지 (컴파일된 Swift)

이 페이지들은 앱 바이너리에 컴파일되어 로컬 대시보드 서버가 라우트로 서빙합니다. SwiftPM은 타겟 경로(Sources/ConditionManager) 밖의 소스를 컴파일하지 못하므로, 소스 파일 자체는 tests/로 옮길 수 없고 Sources 아래에 남아 있어야 합니다. 실행 중인 앱에서 아래 경로로 접속해 확인합니다.

- 라우트 /lounge-break-test — Dashboard/LoungeBreakTestContent.swift (라운지 브레이크 기획 프로토타입)
- 라우트 /session-continue-test — Dashboard/SessionContinueTestContent.swift (세션 이어가기 A안 디테일 목업)
- 라우트 /bgm-timeline-test — Dashboard/BGMTimelineTestContent.swift (BGM 타임라인 테스트)
- 라우트 /bgm-plan — Dashboard/BGMPlanContent.swift (전략3 플랜 맵 시각화; 테스트 겸 실사용)

이들을 물리적으로 tests/에 두려면 컴파일 문자열 대신 디스크의 HTML을 런타임에 읽어 서빙하도록 바꿔야 하는데, 그러면 배포 시 tests/ 디렉터리 동봉 의존이 생깁니다. 필요하면 별도로 논의합니다.

## 3. .e2e/ — 자동화 E2E 하네스 (Node/Playwright)

리포지토리 루트의 .e2e/에 그대로 둡니다. 이 테스트들은 자신을 루트 직속으로 가정한 상대경로(예: __dirname + '/../Sources/...', ../Scripts/...)를 사용하므로, tests/ 아래로 옮기면 모든 경로가 깨집니다. 실행은 .e2e/ 안에서 npm test로 합니다.
