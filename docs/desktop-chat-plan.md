# 골 채팅 → Claude Desktop형 UX 구현 계획

골 페이지의 "목표 명확화 대화"를 Claude Desktop 수준의 채팅으로 끌어올린다.
편한 채팅 입력은 유지하고, 실시간 스트리밍과 권한 모드(수동·자동·계획·편집자동)를
갖춘다. 터미널(PTY)이 아니라 채팅 UI가 1차 작업 인터페이스가 된다.

## 확정 결정 (이 계획의 전제)

- 전송 방식: 출력은 SSE(서버→브라우저 단방향 스트림), 입력·권한응답·중단은 POST.
- v1 권한 모드: 자동(bypassPermissions), 계획(plan), 수동(default 인라인 승인),
  편집자동(acceptEdits) — 네 가지 모두.
- 백엔드 실행: 대화당 상주 claude 프로세스를 `--input-format stream-json
  --output-format stream-json --include-partial-messages`로 구동. 턴별 `-p`가 아니다.
- 설치 CLI: 2.1.195. `--permission-prompt-tool` 플래그는 없음. 수동 모드의
  도구별 허용/거부는 stream-json control 프로토콜로 처리한다(아래 Phase 0에서 확정).

## 아키텍처 개요 (Phase 0 검증 후 확정)

핵심 단순화: 상주 프로세스를 두지 않는다. 턴마다 claude를 stream-json으로 새로
띄우고(resume로 문맥 유지), 그 stdout 이벤트를 대화의 SSE 채널로 중계한 뒤 result에서
프로세스가 끝난다. 기존 chatSendTo 구조와 같되 버퍼링 대신 스트리밍이다. 장시간 stdin을
연 양방향 프로세스를 관리하지 않으므로 좀비/교착 위험이 적다.

- 턴 실행: `claude -p --input-format stream-json --output-format stream-json --verbose
  --permission-mode <모드> [--resume <세션>] [--allowedTools ...] [--model ...]`.
  stdin으로 사용자 메시지 한 줄을 주면 그 턴을 처리하고 이벤트를 흘린 뒤 종료.
- 서버 라우트:
  - GET  /api/goal/chat2/stream?seq= — SSE 채널(대화 열 때 1회 연결). 턴 프로세스가 여기에 이벤트 push.
  - POST /api/goal/chat2/say — 사용자 메시지 1건 → 턴 프로세스 spawn, 이벤트는 SSE로.
  - POST /api/goal/chat2/permission — 수동 모드 승인/거부 → 승인 시 resume+allowlist로 이어서 진행.
  - POST /api/goal/chat2/mode — 다음 턴부터 적용할 권한 모드 변경.
  - POST /api/goal/chat2/stop — 진행 중 턴 프로세스 terminate.
- 서버는 1요청·즉시종료 구조라, SSE만 응답을 닫지 않고 유지하는 경로를 DashboardServer에 추가한다.

## Phase 0 스파이크 결과 (실측 확정)

- 입력: 한 줄에 `{"type":"user","message":{"role":"user","content":"..."}}`. 전체 이벤트
  방출에는 `--verbose` 필수.
- 출력 이벤트:
  - system/init — session_id, permissionMode, tools, model.
  - stream_event — Anthropic 원시 델타(content_block_delta). 실시간 타이핑 소스.
  - assistant — 메시지 스냅샷. content에 tool_use(name,id,input) 포함.
  - system/thinking_tokens — 사고 진행(선택 표시).
  - system/post_turn_summary — status_category·status_detail·needs_action(상태 매핑에 활용).
  - result — is_error, result, usage, total_cost_usd, permission_denials[{tool_name,tool_use_id,tool_input}].
- 권한: 이 CLI(2.1.195)는 `--permission-prompt-tool`이 없고, default 모드 + 순수
  stream-json은 막힌 도구를 자동 거부하고 턴을 끝낸다(대화형 대기 없음).
- 수동 모드 해법 = deny-replay (검증됨): default로 실행 → result.permission_denials가
  비어있지 않으면 인라인 승인 카드 표시 → 허용 시 같은 세션 resume + 해당 도구를
  --allowedTools에 넣고 "계속 진행" 한마디 → 작업 재개. 항상 허용은 대화 allowlist에 영속.
- 자동/편집자동/계획 = permission-mode 플래그(bypassPermissions/acceptEdits/plan) 직접 지정.
- UX 차이: 승인이 도구 호출 단위가 아니라 턴 경계에서 일어난다(claude가 멈추고 묻고
  재개). v1으로는 충분하고 오히려 명확하다.

## 단계별 체크리스트

### Phase 0 — 스파이크(완료)
- [x] stream-json 입출력 실측: 입력/출력 이벤트 종류 (위 "스파이크 결과" 참조)
- [x] 수동 모드 처리 방법 확정: deny-replay (검증됨)
- [x] resume 세션 연속성 동작 확인 (턴별 프로세스 + --resume)
- [ ] 계획 모드(plan) 산출물 형식·승인 전환 — Phase 2에서 실제 연결 시 확인

### Phase 1 — 전송/프로세스 기반 (완료, curl 종단 검증)
- [x] DashboardServer에 SSE 경로(SSEChannel: 연결 유지·이벤트 push·close 감지)
- [x] 턴 스트리밍 프로세스(chat2RunTurn) + 라인 파서(chat2Handle) → SSE 중계
- [x] stream-json 이벤트 → SSE 이벤트(start/delta/think/tool/done/error/stopped) + ChatStore 영속화
- [x] 중단(chat2Stop)·정상 종료·에러 이벤트
- 라우트: GET /api/goal/chat2/stream, POST /api/goal/chat2/say, POST /api/goal/chat2/stop

### Phase 2 — 권한 모드 (대부분 완료)
- [x] 모드 → 플래그 매핑: default / acceptEdits / bypassPermissions / plan
- [x] 자동 모드: 모드 선택 UI 연결
- [x] 편집자동 모드: acceptEdits 연결
- [x] 수동 모드: 인라인 권한 카드(허용하고 계속/거부) + deny-replay 배선 (curl 검증)
- [x] 모드 선택 드롭다운(헤더) + localStorage 저장
- [x] 계획 모드: 계획 텍스트 표시 + "이 계획대로 실행 ▶" 버튼(acceptEdits로 이어서 실행)
- [x] 허용(항상) 영속(localStorage cmAllow:SEQ, 매 say에 동봉)

### Phase 3 — 채팅 렌더링 UX (step 2 대부분 완료)
- [x] 스트리밍 타이핑(부분 메시지 실시간) + 커서 깜빡임
- [x] 중단(Stop) 버튼
- [x] 사고(thinking) 임시 표시(턴 종료 시 제거)
- [x] 도구 사용 카드: 접이식, 도구 결과(tool_result, id 페어링) 포함 (curl 검증)
- [x] 마크다운 렌더링(marked CDN + 새니타이즈, 오프라인 시 plain 폴백)
- [x] 토큰·비용 표시(done.cost → costline)
- [x] 자동 스크롤
- [ ] 편집 도구 diff 뷰, 코드블록 복사 버튼(후속)

### Phase 4 — 대화 관리
- [ ] 골당 여러 대화 + 히스토리(현재 1개 고정)
- [ ] 새 대화 / 이어가기 / 포크(--fork-session)
- [ ] 대화 제목 자동·수동

### Phase 5 — 설정·상태·안전
- [ ] allowedTools/disallowedTools 대화별 설정
- [ ] add-dir 범위 설정 UI
- [ ] 수동 모드 승인 대기 → goal "응답 대기" 자동 매핑
- [ ] 모드별 시각 구분 + bypass 경고/감사 로그

## 이미 되어 있는 것 (재사용/연결만)

- 자동 권한(bypassPermissions) 백엔드 동작
- 모델 선택(opus/sonnet/haiku)
- 이미지 첨부, 메시지 버블, 입력창
- 대화 시작 시 goal 진행 중 승격, 전체 권한 배지

## 위험·미해결

- 수동 모드 control 프로토콜 형식 미확정(Phase 0에서 해소). 여기에 가장 큰 불확실성.
- SSE 연결을 NWConnection에서 장시간 유지할 때의 정리/취소 처리.
- 상주 프로세스 다수 시 리소스·좀비 프로세스 관리.
- 기존 turn 기반 채팅(/api/goal/chat/*)과의 공존/이행 전략(병행 후 교체 권장).
