# SECURITY — Condition Mate 보안 포스처

Owner: lion-condition-mate-pm-security. 이 문서는 위협모델, 수용위험 대장, open-findings 를 담는 단일
소스다. 보안 서브에이전트(lion-condition-mate-worker-security-updates / lion-condition-mate-worker-security-pr-reviewer / lion-condition-mate-worker-security-audit /
lion-condition-mate-worker-security-patterns)는 보고 전 이 문서를 읽어 이미 알려졌거나 수용된 항목을 재보고하지 않는다.

Last reviewed: (아직 첫 정식 감사 전 — 시드 문서)

## 1. 위협모델 (Threat model)

이 앱은 개인 단일 사용자용 macOS 메뉴바 앱이다. 현실적인 공격자는 원격 대량 공격자가
아니라, (a) 로컬에 접근한 다른 프로세스/사용자, (b) 앱이 실행하는 스크립트·훅·헤드리스
워커로 흘러드는 신뢰불가 데이터, (c) 앱이 수집하는 온체인/외부 데이터에 심어진 페이로드다.

보호 대상 자산:
- 사용자 로컬 데이터: `CM_DATA_DIR` 하위 (config, 로그, 리포트, 활동 기록).
- 루프백 대시보드: 랜덤 포트로 localhost 에 바인딩되는 HTTP 서버(`DashboardServer`).
- 훅/스크립트가 실행되는 사용자 머신 자체.
- NSS 리포트를 채우는 온체인/외부 데이터의 무결성.

신뢰 경계:
- 루프백 서버는 localhost 로만 바인딩되어야 하며, 포트를 신뢰불가 주체에 노출하지 않는다.
- WKWebView 는 루프백 대시보드/BGM 페이지만 로드하며, 비-루프백 origin 으로 항행하지 않는다.
- 훅/스크립트/워커로 들어가는 모든 외부 텍스트는 코드가 아닌 데이터로 취급한다.

## 2. 수용위험 대장 (Accepted-risk register)

(비어 있음.) 사용자가 명시적으로 수용한 리스크를 여기에 기록한다. 각 항목: 무엇을 수용했는지,
왜 수용 가능한지, 어떤 조건이 성립하면 더는 수용 가능하지 않은지.

## 3. Open findings

(비어 있음.) 확인되었으나 아직 미수정인 이슈를 여기에 기록한다. 각 항목: 심각도, 위치
(`file:line`), 영향, 담당, 종료 조건.

## 4. 감사 이력 (Audit history)

- (시드) lion-condition-mate-pm-security 팀 초기 구성: 리드 1 + 서브 4(lion-condition-mate-worker-security-updates,
  lion-condition-mate-worker-security-pr-reviewer, lion-condition-mate-worker-security-audit, lion-condition-mate-worker-security-patterns). 첫 정식 감사는 lion-condition-mate-worker-security-audit
  및 lion-condition-mate-worker-security-updates 실행 시 이 문서에 기록된다.

## 5. 슬랙 선응답 컨텍스트 레이어 (2026-08-29 추가)

슬랙 선응답(`slack-eyes-daemon.mjs` → `answer-context.mjs`)이 답을 만들 때 쓰는 근거가
스레드+Jira 에서 다섯 개로 늘었다. 근거가 늘어난 만큼 반출 경로와 노출 범위를 여기에 못
박아 둔다.

반출되는 것:
- Notion API (`api.notion.com`) — 스레드에 이미 공유된 노션 페이지의 id. 토큰은 키체인
  (`cm-notion-token-<key>`)에서 데몬만 읽고 모듈에는 값으로만 넘긴다.
- genspark (`gsk search`) — 모델이 만든 **일반화된 영어 검색어 한 줄**. 회사명·사람 이름·
  내부 코드명·URL·식별자를 넣지 말라고 프롬프트로 못 박고, 질의 생성에 실패하면 검색
  자체를 건너뛴다 (내부 문장을 그대로 검색창에 넣는 폴백은 두지 않는다).
- Slack `search.messages` — 메시지에서 뽑은 고유명사 최대 4개. 현재 user token 에
  `search:read` 스코프가 없어 이 레이어는 비활성이며 "권한 없음"으로 저하된다.
- 용어집(`slack-glossary.json`)은 로컬 파일만 읽는다. 밖으로 나가지 않는다.

권한 등급 (`slack-permission-policy.json`):
- 사람별·도메인별 등급으로 각 근거의 조회 가부를 정한다. 기본 2, 도메인 담당자는 그
  도메인에 한해 상향(예: Global MPC 담당 9). 도메인이 다르면 등급은 따라오지 않는다.
- 등급으로 빠진 근거는 빈 값이 아니라 "withheld" 문구로 프롬프트에 남는다 — 모델이
  "확인했지만 없었다"로 읽는 것을 막는다.
- **등급은 추가 컨텍스트 레이어에만 적용된다.** 자격증명·급여·내부 보안 정보 요청은
  등급과 무관하게 `securityGate` 가 먼저 차단한다. 9등급이어도 슬랙 봇이 API 키를 뱉는
  경로는 만들지 않는다.

### 5.1 이모지 레이어 (2026-08-29 추가)

선응답이 글 대신 리액션 하나로 끝내는 경로(`emoji-layer.mjs` → `slack-emoji-layer.json`).
답할 것이 없는 닫는 말("Understood, thank you. I'll proceed…")에 `Cannot answer` 3줄이
붙던 것을 이모지로 바꾼다.

반출되는 것:
- Slack `reactions.add` — 채널·ts·이모지 이름만. 메시지 본문은 나가지 않는다.
- 결정적 판정(`quickVerdict`)은 로컬 정규식만 쓴다. 모델도 네트워크도 타지 않는다.
- 모델 판정(`modelVerdict`)은 글 선응답이 이미 "근거 없음"으로 끝났을 때만 돈다. 그때
  실리는 것은 선응답이 이미 보내는 것과 같은 메시지·스레드이며, 새로 나가는 것은 없다.

노출 범위:
- 리액션은 그 메시지를 볼 수 있는 사람 전원에게 보인다. 그래서 이 레이어는 근거를
  싣지 않는다 — 이모지 이름 하나뿐이고, 조회한 문서·Jira·다른 스레드는 개입하지 않는다.
- 이모지의 뜻은 조직이 확정한 것(`slack-emoji-layer.json`)만 쓴다. 잘못 단 이모지는
  지울 수 있어도 이미 읽힌다 — 그래서 판정은 한쪽으로 기울여 두었다. 물음·요청·문제
  신호가 하나라도 있으면 이모지로 끝내지 않고 글로 답한다.
- 이 데몬 자신의 수집 트리거(👀·🔖·📌)는 봇이 달지 않는다(`emojiSafeToPost`). 달면
  `reaction_added(MY_USER)` 가 재수집으로 돌아와 같은 항목이 되살아난다. 어휘집에도
  `auto:false` 로 적어 두었지만, 운영 파일로 덮어쓸 수 있는 값 하나에 루프 여부를
  걸어 두지 않는다.

