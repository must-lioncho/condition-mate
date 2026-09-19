# Notion 키를 화면에 노출하지 않고 Keychain에서 연결한다 — 작업지시서

작성 2026-09-03 · 규모 P2 · 구현 대상 macOS Condition Mate

## 현재 상태 조사

- 연동 정본은 `IntegrationCatalog`/`IntegrationStore`이고, Notion은 `notion-token` 다중 인스턴스로 정의돼 있다. 기본 Keychain service는 `cm-notion-token-<instance-key>`, account는 `notion`이다.
- `IntegrationChecks.checkNotion`은 Keychain에서 토큰을 읽어 Notion `users/me`와 `search`를 실제 호출한다. 토큰 유효성 및 공유 페이지 없음은 이미 구분한다.
- 현재 `SessionRail` 연동 UI와 `/api/integrations/instance`는 브라우저의 password input과 JSON body로 토큰을 받는다. 이번 요구의 “앱/웹 UI에 Notion 비밀키를 직접 입력하지 않는다”와 충돌한다.
- 기존 단일 service `cm-notion-token` 및 현재 인스턴스 service `cm-notion-token-<key>`를 읽는 소비자가 함께 존재한다. 기존 항목은 삭제·이동하지 않고 계속 읽혀야 한다.
- macOS `security` CLI의 일반 비밀번호 검색은 service를 모르면 전체 항목을 안전하게 열거하는 공개 명령을 제공하지 않는다. Security.framework의 `SecItemCopyMatching`에 `kSecMatchLimitAll + kSecReturnAttributes`를 사용하면 현재 프로세스가 볼 수 있는 generic-password의 **속성만** 조회할 수 있으나, Keychain/ACL/잠금 상태에 따라 일부 또는 전체가 반환되지 않을 수 있다. 따라서 이는 완전한 전수 검색이 아니라 “접근 가능한 메타데이터 후보 검색”이며, 실패·빈 결과를 정상 상태로 처리한다. 후보 조회에는 `kSecReturnData`를 절대 사용하지 않는다.

## 목표 UX

1. Notion 미연결 카드에서 토큰 입력 칸을 없애고 `Keychain에서 찾기`를 제공한다.
2. 조회 결과 중 service 또는 account에 `notion`이 대소문자 무시로 포함된 generic-password 항목만 결정적으로 정렬해 추천한다.
3. 후보 행에는 service/account만 표시하며 비밀값·마스킹 끝자리도 표시하지 않는다. 동일 service/account는 중복 제거하고, 같은 service의 여러 account는 서로 다른 후보로 유지한다.
4. 사용자가 후보를 선택하면 해당 service/account 참조를 비밀이 아닌 연결 설정에 저장하고, 그 정확한 항목의 비밀을 Keychain에서 읽어 실제 Notion 연결을 즉시 검증한다.
5. 연결 후 카드에는 `Keychain: <service> · <account>`와 `연결됨` 또는 `검증 실패`를 표시한다.
6. 후보가 없을 때만 `터미널에서 안전하게 등록`을 제공한다. 앱은 Terminal을 열어 저장소가 생성한 로컬 등록 도구를 실행하고, 도구는 TTY에서 echo를 끈 표준입력으로 토큰을 받아 Keychain에 저장한다. 토큰은 argv·환경변수·셸 히스토리·앱 HTTP 요청을 통과하지 않는다. 완료 뒤 앱이 감지할 수 있는 비밀 없는 결과 파일/상태를 남겨 UI 재조회와 실검증으로 이어지게 한다.

## 보안 불변조건

- Notion 토큰은 HTML/DOM, HTTP request/response, 로그, 오류, 프로세스 인자, 환경변수, `integrations.json`, 결과 파일에 나타나지 않는다.
- 후보 검색은 Keychain 속성만 요청하고 `kSecReturnData`를 사용하지 않는다.
- service/account는 길이와 허용 문자/제어문자를 검증한 뒤에만 저장·프로세스 인자로 전달한다. 토큰은 오직 TTY 표준입력 → `security -i` 표준입력으로 흐른다.
- API는 Notion 자격증명에만 동작하도록 allowlist하고 임의 Keychain 읽기/검증 오라클이 되지 않게 한다.
- 검증 오류는 Notion 응답 메시지를 제한·정제해 반환하며 토큰 및 Authorization 헤더를 포함하지 않는다.
- 기존 키를 자동 삭제·복제·이동하지 않는다. 연결 해제는 참조만 제거하는 동작과 실제 Keychain 삭제를 구분한다.

## 구현 범위

- Integrations 모듈: Keychain 메타데이터 후보 모델/열거, 정확한 service+account 읽기, 외부 Keychain 참조를 담는 후방 호환 인스턴스 필드, 참조 연결 및 검증 API.
- ConditionMate 앱: 후보 조회/선택, 안전한 Terminal 등록 시작/상태 API 및 endpoint allowlist/action-log 비밀 차단.
- SessionRail: Notion에만 적용되는 후보 목록·선택·상태·CLI 등록 UX. 다른 연동의 기존 입력 UX는 이번 범위에서 바꾸지 않는다.
- 등록 도구: Foundation/Security 기반 macOS CLI executable target. TTY echo-off 입력, Keychain 저장, 비밀 없는 완료 신호.
- SPEC: 연동 관리 화면과 endpoint 기대 동작을 EN/KO로 추가하고 HTML 재생성.

## 오류 처리

- 취소: 아무 설정도 저장하지 않고 UI를 원상 복구한다.
- Keychain 잠금/권한 거절/열거 불가: 비밀 없는 안내와 CLI 대안을 보인다. 이를 “후보 없음”과 구분 가능한 상태 코드로 반환한다.
- 후보 없음: CLI 등록 버튼을 활성화한다.
- 중복/유사 후보: 정확한 service+account를 함께 표시하고 완전 동일 쌍만 제거한다. 자동 선택하지 않는다.
- 후보 선택 뒤 읽기 거절/항목 소실: 참조를 연결 완료로 표시하지 않고 `검증 실패`로 남긴다.
- 잘못된 토큰: Keychain 항목은 보존하되 Notion 검증 실패를 표시해 사용자가 다른 후보를 고르거나 CLI로 교체할 수 있게 한다.
- 네트워크 실패와 Notion 인증 실패는 서로 다른 문구로 표시한다.
- Terminal 실행 실패/도구 없음/저장 실패는 토큰 없는 오류만 상태로 남기며 재시도를 허용한다.

## 호환성 및 가정

- `integrations.json`의 기존 행은 새 Keychain 참조 필드가 없으면 지금처럼 `cm-notion-token-<key>`/기본 account를 사용한다.
- 기존 `cm-notion-token` 단일 항목은 별도 legacy 연결로 인식하고 현재 사용 service/account를 표시한다. 파괴적 마이그레이션은 하지 않는다.
- Keychain 전체 열거는 플랫폼상 완전성을 보장하지 못한다. 접근 가능한 generic-password 속성만 후보로 제시하며, 누락 시 CLI 등록이 확정 대안이다.
- Terminal.app 사용이 허용된 macOS를 대상으로 한다. 앱 샌드박스 배포는 현재 프로젝트가 사용하지 않는 전제이며, 향후 sandbox 도입 시 별도 helper/XPC 설계가 필요하다.

## 테스트 및 완료 기준

- 단위: 후보 필터가 service/account의 대소문자 무시 `notion`만 포함하고 정렬·완전중복 제거하며 비밀 필드를 갖지 않는다.
- 단위: 기존 인스턴스에 새 참조 필드가 없어도 기존 service/account를 그대로 해석한다.
- 단위: 외부 후보 연결 설정에는 service/account만 직렬화되고 토큰은 저장되지 않는다.
- 통합: 격리 Keychain 항목을 만든 뒤 후보 조회 → 선택 → 실제 Notion 검사 경로가 정확한 service/account를 사용한다. 라이브 Notion 자격증명이 없는 자동 테스트에서는 HTTP 검사를 주입/스텁하고, 실제 네트워크 검사는 기존 연결에 영향을 주지 않는 read-only 수동 검증으로 구분한다.
- CLI: 입력이 argv/env에 없고 TTY echo가 꺼지며, 성공/취소/빈 값/저장 실패가 비밀 없는 상태로 끝나는지 검증한다.
- API/UI: Notion 카드 HTML에 password input이 없고 후보/CLI 흐름만 있으며, 응답 JSON·로그·`integrations.json`에 sentinel token이 없는지 검사한다.
- 회귀: `swift build`, 관련 Swift tests, 기존 integrations E2E를 실행한다. SPEC.md 변경 후 `render-spec.py`로 SPEC.html을 재생성한다.
- 완료: 후보 탐색·선택, 안전한 CLI 등록, 실제 연결 검증, service/account 상태 표시, 기존 설정 호환, 명시된 오류 처리가 모두 코드와 테스트로 확인돼야 한다.

## 구현 체인

1. PO/작업지시서 확정(이 문서).
2. 구현자가 Integrations → 앱 API → SessionRail → CLI 순서로 최소 변경한다.
3. security 관점에서 토큰 유출 경로와 Keychain 참조 allowlist를 점검한다.
4. `lion-condition-mate-worker-qa` 기준으로 빌드·격리 테스트·SPEC 동기화를 수행하고 PASS/FAIL 근거를 남긴다.

## 1초 요약

Notion 키는 화면에 넣지 않는다. 앱은 Keychain의 이름만 찾아 보여 주고, 고른 항목을 실제 API로 확인한다. 후보가 없을 때만 Terminal의 숨김 입력으로 Keychain에 저장한다.

## 구현 기록 (2026-09-03)

- 후보 열거는 `SecItemCopyMatching` 속성-only 질의로 구현했다. 결과는 완전한 Keychain 전수 목록이 아니라 현재 앱 프로세스가 접근 가능한 generic-password 메타데이터 목록이라는 가정을 유지한다.
- 외부 후보 참조는 `keychainService`/`keychainAccount` 두 필드만 저장하며 Notion 검사, MCP launcher, Slack 데몬이 같은 정확한 쌍을 사용한다. 필드가 없는 기존 행과 `cm-notion-token` legacy 항목은 파괴 없이 기존 규칙으로 읽는다.
- 후보 연결 API는 현재 결정적으로 발견된 후보 또는 앱이 고정한 Terminal 등록 항목만 받는다. 존재 확인/검증 전에 설정 행을 만들지 않고, 실제 Notion 검증이 실패한 경우에는 선택한 참조와 `검증 실패` 상태를 남겨 재선택할 수 있게 한다.
- Terminal helper는 TTY가 아니면 거부하고, echo 복원을 `defer`로 보장하며, 앱의 `CMKeychain.set`과 동일하게 따옴표·역슬래시·백틱·달러 등 `security -i` 파서 문자를 거부한다.
- 검증: `.e2e/integrations.test.js` 76/76 통과, `Integrations` 타깃 및 `NotionKeychainRegister` 타깃 독립 scratch 빌드 통과, SPEC HTML 재생성. 전체 앱 scratch 빌드는 공유 작업트리에 이미 있던 `AppDelegate.swift:7282`의 `DispatchQueue.main.sync` 결과형 추론 오류로 중단됐다(이번 변경 구간 밖).
