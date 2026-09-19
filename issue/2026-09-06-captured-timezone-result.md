# 이슈 목록 캡처 시각 타임존 수정

원인: 목록의 `when(c)`가 `capturedKey` 문자열을 잘라 표시해 사용자 타임존을 무시했다.

변경: WorkQueueTimestamp가 오프셋을 존중해 UTC 순간으로 파싱하고 API에 capturedUTC를 제공한다. 목록은 CMTimeFilter.isoDisp로 사용자 타임존에 변환한다. 정렬도 UTC 순간 기준이다. 날짜만 있는 기록은 날짜로 유지한다.

옛 오프셋 없는 카드에는 기존 큐 작성 지역인 Asia/Kolkata를 적용한다. 이는 기존 WorkQueueSessionStore의 로컬 해석과 실제 카드/실행 환경에 근거한다. 표시 설정을 바꿔도 원본 순간은 바뀌지 않는다. 앱 자체 저장 포매터는 이미 UTC이며 유지했다. 외부 작성 큐 카드는 읽기 전용이고 파일 수정/마이그레이션은 0건이다.

검증:
- node .e2e/timezone.test.js: 37 통과
- node .e2e/issues.test.js: 203 통과
- 실제 Swift 파서를 standalone으로 실행: 10 assertions 통과
- swift test --filter WorkQueueTimestampTests: 기존 BoredomRotationTests의 Testing 모듈이 현재 CLI 툴체인에 없어 실행 불가. 동일 파싱 사례는 standalone으로 검증했다.
- 릴리즈 빌드 성공, /Applications/ConditionMate.app 갱신 및 재실행 완료.
- Playwright로 실행 앱의 실제 cmCondSetTz 설정 저장/페이지 리로드/목록 DOM 검증: 4회 통과. 원래 설정 복원.
- 실제 카드 2026-09-06-2300-entry-agent-null-po-assignment:
  원본 2026-09-06T23:00:00+05:30 → API 2026-09-06T17:30:00Z.
  KST 26-09-07 02:30 → IST 26-09-06 23:00 → UTC 26-09-06 17:30 → KST 26-09-07 02:30.

빌드 스크립트는 기존 설정에 따라 ad-hoc 서명을 사용했다(ConditionMate Dev 인증서 없음). 다른 작업자의 변경은 편집하거나 커밋하지 않았다.
