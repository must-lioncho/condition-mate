# SECURITY — Condition Mate 보안 포스처

Owner: manager-security. 이 문서는 위협모델, 수용위험 대장, open-findings 를 담는 단일
소스다. 보안 서브에이전트(security-updates / security-pr-reviewer / security-audit /
security-patterns)는 보고 전 이 문서를 읽어 이미 알려졌거나 수용된 항목을 재보고하지 않는다.

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

- (시드) manager-security 팀 초기 구성: 리드 1 + 서브 4(security-updates,
  security-pr-reviewer, security-audit, security-patterns). 첫 정식 감사는 security-audit
  및 security-updates 실행 시 이 문서에 기록된다.
