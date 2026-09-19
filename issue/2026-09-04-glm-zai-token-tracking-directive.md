# GLM(Z.ai) 토큰 추적 작업지시서

- 날짜: 2026-09-04
- 트랙: BEST · 레벨 L1 · 규모 P2
- 트랙 카드: `organization/lion/lion-work-queue/inbox/2026-09-04-0420-glm-zai-tracking.md`
- 대상 화면: 대시보드 → 토큰 뷰 (`도구·계정` / `모델·라우팅` 필터 줄)

## 요구

대시보드 토큰 트래커에서 GLM(Z.ai) 모델의 세션과 토큰 사용량이 추적·집계되지
않는다. 추적되게 만들고, 데이터가 부족하면 검증용 세션을 만들어서 화면에 실제로
숫자가 나오는 것까지 확인한다.

## 실측 — 무엇이 실제로 벌어지고 있었나

`~/.local/bin/glm-claude` 는 Claude Code 를 z.ai 의 Anthropic 호환 엔드포인트로
꺾어서 띄운다. 그래서 GLM 창은 **Claude Code 창이고**, 트랜스크립트도 다른 클로드
세션과 똑같이 `~/.claude/projects/<프로젝트>/<세션id>.jsonl` 에 쌓인다.

디스크를 세어 봤다 (2026-09-04 기준):

- `"model":"glm-5.3-flash"` 를 담은 assistant 줄 72 개
- 그 줄이 든 트랜스크립트 5 개
  (`-Users-lioncho-Work-lion-work/` 4 개, `-private-tmp/` 1 개)
- usage 블록은 정상이다 — `input_tokens`, `output_tokens`,
  `cache_read_input_tokens`, `cache_creation` 이 다 들어 있다.

즉 **데이터는 들어와 있었고 파싱도 되고 있었다.** 사라진 것은 귀속이다.

## 문제 — 번역

원인은 두 줄이다. `AppDelegate.swift` 의 트랜스크립트 스캔이 끝나는 자리에서
provider 를 문자열 상수로 박아 놓았다.

```swift
let acc = LLMAccountStore.shared.resolve(provider: "claude", accountId: accountUuid)
st.providers["claude"] = (st.providers["claude"] ?? 0) + st.spent
```

`~/.claude/projects` 아래 있으면 무조건 클로드다, 라는 가정이다. 엔드포인트를 꺾어
띄운 창이 생기기 전에는 맞는 가정이었고 지금은 아니다.

여기에 두 번째가 겹친다. GLM 세션의 트랜스크립트에는 `ownerAccountUuid` 도
`accountUuid` 도 없다 (OAuth 로그인을 거치지 않으므로 당연하다). 그래서
`accountUuid` 가 빈 문자열로 남고 `resolve` 가 `claude:default` 로 떨어진다.

**결과: GLM 이 쓴 토큰이 `클로드 기본` 계정에 섞여 들어간다.** 화면에 GLM 칩이
없는 것이 아니라, GLM 이 클로드로 위장된 채 이미 세어지고 있었다. 그래서
"추적이 안 된다" 가 맞다 — 총합에는 들어가는데 GLM 것만 골라낼 수가 없다.

`모델·라우팅` 줄에 `glm-5.3-flash HIGH` 칩이 이미 떠 있는 것이 이 진단의 방증이다.
모델 축은 데이터에서 자동 생성되므로 잡혔고, 계정·provider 축만 하드코딩 때문에
못 잡았다.

## 무엇을 고치는가

1. **모델 이름에서 provider 를 판정한다.** `glm-` 으로 시작하는 모델은 provider
   `glm`. 세션 단위가 아니라 **메시지 단위**로 가른다 — 한 트랜스크립트가 두
   provider 를 섞어 담을 수 있다고 보는 쪽이 안전하다.
2. **`LLMAccountStore` 에 `glm` provider 를 추가한다.** 계정 목록의 정본은
   `~/.zai/glm-accounts.json` 이다 (`zai-key` 가 소유. 키는 키체인에만 있고 이
   파일에는 라벨과 활성 표시만 산다). 여기 있는 라벨마다 계정을 하나씩 등록한다.
3. **하루치 집계에서 GLM 몫과 클로드 몫을 갈라 적는다.** `spent` 를 모델별
   사용량에서 다시 나눠 `accounts` / `providers` 두 맵에 각각 넣는다.
4. **세션 한 줄의 provider 도 다수결로 정한다.** GLM 이 더 많이 쓴 세션은 GLM
   계정 뱃지를 달고, `도구·계정` 필터에서 GLM 을 눌렀을 때 그 세션만 남는다.
5. **단가표를 z.ai 실제 공시가로 바꾼다.** 지금 `glm-5`/`glm-4` 가 둘 다
   $0.5/$1.5 로 뭉뚱그려져 있다. 비용 열이 틀리면 그 열을 안 믿게 된다.

## 무엇을 고치지 않는가

- `zai-key`, `glm`, `glm-claude` 세 래처는 건드리지 않는다. 인증의 소유자이고
  이 작업의 범위 밖이다.
- 트랜스크립트에는 **어느 z.ai 계정으로 돌았는지가 안 적힌다.** 그래서 귀속은
  현재 활성 계정으로 한다. 계정이 하나뿐인 지금은 정확하고, 둘 이상이 되면
  과거 세션이 활성 계정으로 몰린다. 이 한계는 코드 주석에 남긴다. 정확히 하려면
  `glm-claude` 가 세션 시작 줄에 계정 라벨을 찍어야 하는데, 그것은 래퍼를
  고치는 일이라 이번 범위가 아니다.

## 검증

1. `swift build` 통과.
2. 앱을 띄우고 `/tokens.json` 에 `providers.glm` 이 0 보다 큰 날이 나오는지 본다.
3. `/tokens-accounts.json` 에 `glm:lioncho` 계정이 나오는지 본다.
4. `/tokens-sessions.json?day=<날>` 에서 GLM 세션의 `provider` 가 `glm` 인지 본다.
5. 데이터가 얇으면 `glm-claude -p` 로 검증용 세션을 몇 개 새로 돌려 트랜스크립트를
   만들고 1~4 를 다시 본다.

## 결과 — 실측

`Scripts/e2e-glm-tokens.sh` 6/6 PASS (스테이징된 릴리즈 번들로도 재실행해 확인).

| | 고치기 전 | 고친 뒤 |
|---|---|---|
| 09-04 GLM 토큰 | `클로드 기본` 에 섞임 | `GLM 계정 1 (lioncho)` 519 K |
| 09-03 GLM 토큰 | `클로드 기본` 에 섞임 | `GLM 계정 1 (lioncho)` 83 K |
| GLM 세션 provider | `claude` | `glm` |
| GLM 필터 비용 | `$482 (opus-5 93%)` | `$0.44 (glm-5.3-flash 100%)` |

화면: `issue/assets/2026-09-04-glm-token-tracking.jpg`

검증용으로 `glm-claude -p` 세션 3 개를 새로 돌려, 새 세션이 곧바로 GLM 으로 집계되는
것까지 확인했다 (09-04 이 387 K → 519 K 로 늘었다).

## 고친 파일

- `Sources/ConditionMate/Core/LLMAccountStore.swift` — `glm` provider, `~/.zai/glm-accounts.json`
  부트스트랩, `activeGLMAccount()`.
- `Sources/ConditionMate/AppDelegate.swift` — `providerForModel()`, 트랜스크립트 스캔의
  메시지 단위 provider 분리, GLM 단가.
- `Sources/ConditionMate/Dashboard/DashboardContent.swift` — `tkProviderOfModel()`,
  계정 필터가 그 provider 의 모델만 보게, GLM 뱃지·단가.
- `Scripts/e2e-glm-tokens.sh` — 새 검사 6 종.

## 곁다리로 걸린 것 두 개 (이 작업의 원인은 아니지만 이것 때문에 막혔다)

**하나. 릴리즈 빌드가 안 나오고 있었다.** `Sources/ConditionMate/Plugins/suno-mcp` 는 Swift 가
한 줄도 없는 Node 플러그인인데 `node_modules` 가 딸려 있어 파일이 3,691 개다. SwiftPM 이
타깃 폴더 밑을 전부 빌드 입력으로 훑으므로 `build.db` 가 터졌고, `.build/release/ConditionMate`
자체가 안 만들어져 `staged.json` 이 `failed` 이었다 — **업데이트 버튼이 죽어 있었다.**
`Package.swift` 의 `exclude: ["Plugins/suno-mcp"]` 로 고쳤다. Slack 타깃이 `Daemon`·`loops` 를
빼는 것과 같은 방식이다.

**둘. 이 폴더 안에서는 SwiftPM 이 조용히 옛 코드를 배포한다.** 저장소 안에 `.build` 를 두면
`accessing build database ...: disk I/O error` 가 나는데, 그러고도 `Build complete!` 를 찍고
exit 0 을 돌려준다. 바뀐 파일을 컴파일하지 않고 넘어가므로 **고친 코드가 안 들어간 바이너리가
배포된다.** 이 작업에서 실제로 두 번 당했다 — 대시보드 JS 수정이 두 번 다 반영 안 된 채
"빌드 성공" 으로 보였고, 서빙된 HTML 을 직접 grep 해서야 알았다.

`.build` 를 저장소 밖(`~/.cache/cm-swiftpm-build`)을 가리키는 심볼릭 링크로 바꾸면 오류가
완전히 사라진다(exit 0, 오류 0). 지금 그렇게 해 두었고 `.gitignore` 의 `.build/` 에서
슬래시를 빼 링크도 무시되게 했다. 저장소 폴더 자체의 문제로 보이며(구글 드라이브 DriveFS 가
돌고 있다) 근본 원인은 안 팠다.

## 남은 것 — 이번에 안 고친 것

**계정으로 걸렀을 때 구성비가 그날 전체 값이다.** `컨텍스트 3523%` 처럼 100 을 넘는다.
분모만 걸러진 계정 것이고 분자는 그날 전체라서 그렇다. 토큰 합계와 비용은 이번에 정확해졌지만
구성비·AI 가동·리드는 아직 아니다.

이것은 GLM 만의 문제가 아니라 **계정 필터 전체의 문제**이고 GLM 추적 이전부터 있었다.
제대로 고치려면 서버가 `DayTok.accounts` 에 토큰 수 하나만이 아니라 구성비 하위 항목까지
계정별로 나눠 담아야 한다 — 이번 요구 범위 밖이라 손대지 않았다. 비율로 눌러 담는 추정은
일부러 안 했다. 틀린 숫자가 그럴듯해 보이는 쪽이 대놓고 깨져 보이는 쪽보다 나쁘다.

## 1초 요약

- **요구**: 대시보드 토큰 트래커에서 GLM(Z.ai) 사용량이 추적·집계·필터되게 하라.
- **문제**: `~/.claude/projects` 아래면 무조건 클로드로 귀속하는 하드코딩 두 줄 때문에,
  엔드포인트만 꺾어 띄운 GLM 세션이 `클로드 기본` 에 섞여 들어가 골라낼 수가 없다.
- **완성**: 모델 이름으로 provider 를 갈라 GLM 몫을 별도 계정·provider 로 적고,
  `도구·계정` 줄에 GLM 칩이 떠서 누르면 GLM 세션과 토큰만 남는다.
