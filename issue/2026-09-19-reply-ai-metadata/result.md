# 적용 결과

2026-09-19 Condition Mate 설치본 업데이트 완료. Slack 수신·번역 화면의 항목을 펼치면 **AI 실행** 탭에서 내부 실행 정보를 확인한다.

- Slack 자동답변 본문과 첨부 MD 형식은 유지한다.
- 신규 자동답변이 게시된 후 해당 항목에 ackAI를 저장한다. 답변 생성·언어 재시도 범위이며 번역·근거 수집 호출은 합산하지 않는다.
- 실제 응답 모델 ID, 요청 모델 ID, API/CLI 경로, effort 설정 상태를 표시한다.
- 컨텍스트 입력 한도, 실사용 입력과 비율, 출력 한도, 입력·출력·추론·캐시·전체 토큰을 구분한다.
- Gemini/Anthropic 모델 한도는 공식 Models API로 조회한다. 값이 없거나 조회 실패하면 미제공으로 표시한다.
- CLI의 누적 입력 토큰을 단일 요청의 컨텍스트 점유량으로 표시하지 않는다.
- 과거 기록은 소급 추정하지 않는다. 기존 번역 모델을 답변 모델로 대체하지 않는다.

## 검증

- reply-ai-usage.test.mjs: 6개 통과. 동시 답변 격리, 재시도, 늦게 끝난 호출 배제, 실제 모델·토큰 정규화, 캐시 중복 방지, 조회 실패, 실제 Gemini 호출 함수의 메시지 ID 연결 검증.
- 기존 ack-sources: 15개 통과. 발신 대상 정책 유지.
- 기존 reply-language: 24개 통과. 기존 send-layer.gate 시나리오도 실행했다.
- 외부 MD에 메타데이터를 추가로 전달해도 출력이 바이트 단위로 동일함을 검증했다. 실행 코드에서는 MD 렌더러에 메타데이터를 전달하지 않는다.
- slack-ai-usage-ui.cjs: 내부 UI, 모르는 값, 과거 답변, 미발신, escaping, 전체 JS 구문 검사 통과.
- slack-ai-usage-installed.cjs: 설치된 앱 HTML의 AI 실행 탭에서 표시 검증 통과. 브라우저 안의 모의 데이터만 사용했고 운영 원장은 수정하지 않았다.
- 실제 Gemini Models API 읽기 검증: gemini-flash-lite-latest 입력 한도 1,048,576 / 출력 한도 65,536 확인. 키 값은 기록하지 않았다.
- 릴리즈 빌드·적용·앱 재시작 완료. 설치된 데몬 및 새 모듈의 SHA-256이 소스와 일치하며 launchd 데몬은 running 상태다.
- 테스트를 위한 Slack 메시지 발송이나 기존 답변 재발송은 하지 않았다. 신규 실제 답변의 게시까지 강제로 발생시킨 검증은 아니다.

## 근거

- [설치 앱 UI — 모의 데이터](installed-ui-fixture.png)
- [UI 예외·알 수 없는 값 검증](ui-fixture.png)
- [Google Models API](https://ai.google.dev/api/models)
- [Anthropic Models API](https://platform.claude.com/docs/en/api/http/models/retrieve)

초기 회귀 실행에서 인자를 요구하는 레거시 테스트 두 개를 node --test로 잘못 실행했다. 모듈 디렉터리 인자를 전달하는 원래 실행법으로 다시 실행해 확인했다.
