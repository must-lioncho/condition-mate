# Condition Mate PO 계약 변경

날짜: 2026-09-06

범용 제품 PO가 없어 `lion-condition-mate-po`를 프로젝트 스캐폴더로 추가했다.
기존 루프 전문 PO와 PM에는 범용 PO 문서 세트를 먼저 읽는 역할 경계를 추가했다.

정본: [lion-condition-mate-po](../.claude/agents/lion-condition-mate-po.md).
연결: [PM](../.claude/agents/lion-condition-mate-pm.md),
[루프 전문 PO](../.claude/agents/lion-condition-mate-po-loop-engineering.md).

## 호출과 산출물

이 프로젝트에서 “컨디션 메이트 PO로 이 요청을 정리해줘: …”라고 요청한다.
기본 산출물은 `issue/<날짜>-<주제>/`의 `intent.md`, `problem-v<n>.md`,
`solutions-v<n>.md`다. 후속 정정은 기존 폴더에서 버전업한다.

문제마다 우선순위·이유·선행 조건·확인 방법·완료 조건·현재 상태를 적는다.
핵심 불확실성을 확인하기 전에는 쉬운 기존 기능 구현으로 우회하지 않는다.
솔루션 후보는 문제 ID와 연결한다. 문서 작성 범위면 작성 후 멈춘다.

## 검증 범위

- agent-factory 배치 감사가 수정한 정의 3개에 대해 발견한 위반: 0건.
- 새 PO의 파일명·이름, 필수 산출물, 우선순위 표 필드, 버전 관리 규칙과 빈 템플릿 제거 확인.
- 기존 PM의 추천 규칙보다 PO 선행 조건을 먼저 적용하도록 명시.
- 맥 전체 감사에는 다른 파일의 기존 위반이 남아 있다. 전체 감사 통과를 뜻하지 않는다.
- 별도 모델 실행을 통한 산출물 품질 검증이나 현재 세션의 에이전트 목록 재로딩은 확인하지 않았다.
  이번 검증은 정의와 배치에 대한 정적 확인이다.

근거 사례: [AI 사용량 의도](../issue/2026-09-06-ai-usage-visibility/intent.md),
[문제 정의 v2](../issue/2026-09-06-ai-usage-visibility/problem-v2.md).
