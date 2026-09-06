# 시간 표시가 사용자 시간대를 따르게 한다 — 결과

- 카드 `2026-09-06-1358-condition-mate-timezone` · 트랙 `FAST` · `L1` / `P2` / `C2`
- 작성 2026-09-06 22:45 IST (= 2026-09-07 02:15 KST = 2026-09-06 17:15 UTC)
- 이 세션 `term_aa44bb44-10aa-4e57-a7c5-f91cdf81b903`. 앞선 세션
  `term_03b91170-eab0-4763-8df3-6c4944aedcbc` 이 exited 로 끝나 카드가 `launched` 에 머물러
  있었고, 이 세션은 그 세션이 남긴 것을 **재사용해서 이어서** 끝냈다. 조사를 처음부터 다시
  하지 않았다.

## 앞선 세션이 어디까지 했고 이 세션이 무엇을 더했는가

앞선 세션은 **소스 수정을 끝내고 커밋까지 했다** (`cf22aea`, 2026-09-06 14:11 IST). 원인은
하드코딩된 타임존이 아니라 **변환을 아예 안 한 것**이었다 — 저장된 ISO 문자열을
`.replace('T',' ').slice(0,16)` 으로 잘라서 그대로 찍었다. 자르기는 변환이 아니다.

이 세션이 시작할 때 남아 있던 것은 셋이다.

1. 하네스 파일 다섯 개가 **커밋되지 않은 채** 워킹트리에만 있었다.
2. 살아 있는 서버 축을 보는 `Scripts/e2e-timezone-display.sh` 가 **한 번도 안 돌았다**(추적되지
   않은 새 파일).
3. **지금 도는 앱에 반영되었는지가 판정되지 않았다.** 소스가 맞다는 것과 도는 앱이 맞다는 것은
   다른 판정이고, 앞선 세션은 앞엣것만 했다.

이 세션은 2·3 을 실제로 돌려서 판정했고, 1 을 커밋했다.

## 변경 파일

### 앞선 세션이 이미 커밋한 것 (`cf22aea` · 이 세션은 안 건드렸다)

| 파일 | 무엇이 바뀌었나 |
|---|---|
| `Sources/ConditionMate/Dashboard/CMTimeFilter.swift` | `isoDisp(v,len,sep)` 신설 — 저장된 ISO 를 `window.CM_TZ` 벽시계로 다시 찍는다. 변환 규칙 한 벌이 여기 있다. |
| `Sources/ConditionMate/Dashboard/IssuesContent.swift` | 자르기 5 자리 → `tdisp()` (= `CMTimeFilter.isoDisp`). 세션 줄·턴 줄·보고 줄·버전 줄. |
| `Sources/ConditionMate/Dashboard/LoopEngineeringContent.swift` | 자르기 6 자리 → `tdisp()`. |
| `Sources/ConditionMate/Dashboard/BGMPlayerContent.swift` | 자르기 1 자리 → `isoDisp()`. (같은 파일의 BGM 자동재생 수정은 **다른 작업자 것**이고 이 세션은 손대지 않았다.) |
| `Sources/ConditionMate/Core/WorkQueueVersionLedger.swift` | 저장 포매터 `f.timeZone = TimeZone(identifier: "UTC")` (`:83`). |
| `Sources/ConditionMate/Core/IssueArchiveStore.swift` | 같음 (`:99`). |
| `Sources/ConditionMate/Core/WorkQueueLiveStore.swift` | 같음 (`:138`). |

세 원장 모두 포맷은 `"yyyy-MM-dd'T'HH:mm:ssZ"` 로 **그대로 뒀다.** `Z` 지정자가 적혀 있는
오프셋을 존중하므로 옛 `+0530` · `+0900` 값이 계속 정확히 읽힌다. 그래서 마이그레이션이
필요 없다.

### 이 세션이 커밋한 것

| 파일 | 무엇 |
|---|---|
| `Scripts/e2e-timezone-display.sh` | **새 파일.** 살아 있는 격리 인스턴스에 설정을 POST 하고 `/issues` 가 새 `CM_TZ` 를 내보내는지 본다. |
| `.e2e/timezone.test.js` | 진짜 `CMTimeFilter` 와 진짜 `sesHead`/`tdisp` 를 소스에서 뽑아 돌린다. `global.window = globalThis` 로 고쳐 브라우저의 `window.X === X` 동일성을 세웠다. |
| `.e2e/run.js` | `timezone.test.js` 를 게이트에 등재. |
| `.e2e/issues.test.js` | 시각 단정을 `esc(String(t.at||'')…` → `esc(tdisp(t.at,16))` 로. 지키는 것(`esc` 통과)은 그대로다. |
| `.e2e/screens.test.js` | `CMTimeFilter` 스텁에 `isoDisp` 추가. 스텁이 안 따라가면 제품이 아니라 하네스가 진다. |
| `docs/specs/SPEC.md` | `EP-21` 절 + 이 세션의 **라이브 재검증** 문단. |
| `issue/2026-09-06-1358-timezone-live-render.js` | **새 파일.** 아래 라이브 판정을 그대로 다시 돌리는 스크립트. |

`docs/specs/SPEC.md` 는 다른 작업자의 BGM 문단과 한 파일에 섞여 있어서 **`EP-21` 헌크 하나만
골라 스테이징했다.** 그쪽 두 헌크는 워킹트리에 그대로 남아 있고 건드리지 않았다.

## 테스트 명령과 결과

전부 이 세션에서 실제로 돌린 것이다.

| 명령 | 결과 |
|---|---|
| `node .e2e/timezone.test.js` | **32 passed, 0 failed** |
| `bash Scripts/e2e-timezone-display.sh` | **PASS=10 FAIL=0** (격리 인스턴스, 포트 50994) |
| `bash Scripts/e2e-timezone-boundary.sh` | **PASS=8 FAIL=0** (EP-20 회귀 없음) |
| `cd .e2e && node run.js` | **파일 55 · 통과 55 · 실패 0 · 단정 1714 통과 / 0 실패** |
| `swift build` | **exit 0**. 새 경고 없음(기존 `Sources/GUI/README.md` · `loops/index.md` unhandled-file 경고 2 개만). |
| `swift tzprobe.swift` (임시) | 아래 Swift 축 |
| `node issue/2026-09-06-1358-timezone-live-render.js <dir>` | **16 passed, 0 failed** (도는 앱 대상) |

### 값 판정 — UTC · 한국 · 인도 · 날짜 경계 · 30분 오프셋

문제 사례의 순간 `2026-09-06T07:31:12.345Z` (세션 `97cc3cc2`, 라이언이 밑줄 그은 줄):

| 설정 | 세션 줄 |
|---|---|
| `Asia/Seoul` (UTC+09:00) | `세션 97cc3cc2 · 2026-09-06 16:31 · 사람 말 2 번 · 쓴 파일 3 개` |
| `Asia/Kolkata` (UTC+05:30) | `세션 97cc3cc2 · 2026-09-06 13:01 · …` ← 30 분 오프셋 |
| `UTC` | `세션 97cc3cc2 · 2026-09-06 07:31 · …` ← **이 설정일 때만** 07:31 이 맞다 |

날짜 경계 — `2026-09-06T19:00:00Z` → 한국 `2026-09-07 04:00`, 인도 `2026-09-07 00:30`.
설정 5 회 전환(`Seoul → Kolkata → Seoul → UTC → Kolkata`)이 매번 다시 계산된다. 굳지 않는다.

### Swift 축 (이 맥의 `TimeZone.current` 는 `Asia/Kolkata`)

```
machine tz            = Asia/Kolkata
ISO8601 default       = 2026-09-06T07:31:12Z          ← 원래부터 UTC. 손댈 것 없었다
DateFormatter 로컬(옛) = 2026-09-06T13:01:12+0530      ← 고치기 전 세 원장이 쓰던 값
DateFormatter UTC(새)  = 2026-09-06T07:31:12+0000      ← 고친 뒤
  parse 2026-09-06T13:01:12+0530 -> epoch 1788679872
  parse 2026-09-06T16:31:12+0900 -> epoch 1788679872
  parse 2026-09-06T07:31:12+0000 -> epoch 1788679872   ← 셋이 같은 순간. 옛 값이 계속 맞다
```

## 현재 실행 중인 앱에 실제로 반영되었는가 — 반영됐다

**도는 것은** `/Applications/ConditionMate.app/Contents/MacOS/ConditionMate`, pid **5544**,
설치 시각 **21:11**, 대시보드 **127.0.0.1:57797**. `.build/debug/ConditionMate` 가 아니다.

근거 넷을 따로 세웠다. 앱의 자기 보고 하나로는 판정하지 않았다.

**하나 — 바이너리 안에 실제로 들어 있다.** JS 가 Swift 문자열 리터럴로 박히므로 `strings` 로
바로 확인된다. 재빌드 없이 결론이 난다.

```
strings -a /Applications/ConditionMate.app/Contents/MacOS/ConditionMate |
  grep -c "function isoDisp(v, len, sep)"            → 1
  grep -c "esc(tdisp(S.startedAt,16))"               → 1
  grep -c "esc(String(S.startedAt||'').replace"      → 0     ← 옛 자르기가 없다
  grep -c "Asia/Kolkata"                             → 4
```

**둘 — 설정을 바꾸면 도는 앱이 새 값을 내보낸다.** 포트 57797 에 실제로 POST 했다.

```
ORIGINAL                {"tz":"system","effective":"Asia/Kolkata",...}
POST Asia/Seoul     →   /issues 가  window.CM_TZ='Asia/Seoul'
POST Asia/Kolkata   →   /issues 가  window.CM_TZ='Asia/Kolkata'
POST UTC            →   /issues 가  window.CM_TZ='UTC'
POST Asia/Seoul     →   window.CM_TZ='Asia/Seoul'      (되돌려도 따라온다)
POST Asia/Kolkata   →   window.CM_TZ='Asia/Kolkata'
POST system         →   window.CM_TZ=null              ← 원래 설정으로 복구함
```

라이언의 원래 설정은 `system`(실효 `Asia/Kolkata`)이었고 **검증 뒤 그대로 되돌려 놓았다.**

**셋 — 그 앱이 오늘 스스로 쓴 시각이 UTC 다.** 이것이 "앞으로 생성되는 시간" 조건의 직접
근거다. 살아 있는 `/api/issues` 응답에서:

```
카드 2026-09-06-2225-script-first-routing-loop
  versionFirstSeen = 2026-09-06T17:01:18+0000   ← 오늘 이 앱이 새로 쓴 시각. UTC 다
  captured         = 2026-09-06T22:25:55+0530   ← 카드 파일 원본. 옛 오프셋 그대로 둔다
```

맥의 `/etc/localtime` 이 `Asia/Kolkata` 인데 `+0000` 이 찍혔다. 고치기 전이면 `+0530` 이었다.

**넷 — 그 앱이 서빙한 페이지의 진짜 JS 로 그 진짜 값을 찍어 봤다.** 소스가 아니라 도는
인스턴스가 내보낸 360,592 바이트에서 `CMTimeFilter` · `tdisp` · `sesHead` · `esc` 를 뽑아
그대로 실행했다 (`issue/2026-09-06-1358-timezone-live-render.js`, **16 passed / 0 failed**).

| 값 | 한국 | 인도 | UTC |
|---|---|---|---|
| `…T17:01:18+0000` (새로 쓴 것) | `2026-09-07 02:01` | `2026-09-06 22:31` | `2026-09-06 17:01` |
| `…T22:25:55+0530` (옛 저장분) | `2026-09-07 01:55` | `2026-09-06 22:25` | `2026-09-06 16:55` |

위 줄은 **날짜 경계를 넘고**(한국에서 하루 뒤), 인도는 **30 분 오프셋**이 붙는다. 아래 줄은
옛 `+0530` 값이 마이그레이션 없이 세 설정 모두에서 같은 순간으로 읽힌다는 뜻이다.

서빙된 바이트에 옛 자르기 표기(세션 줄·턴 줄·보고 줄) 셋 다 없고, 설정 셀렉터에
`['Asia/Kolkata','IST (UTC+5:30)']` 가 있다.

**재시작은 필요 없었고 하지 않았다.** 페이지는 요청마다 새로 만들어지고 설정 변경은
`location.reload()` 로 다시 받아 간다. 도는 바이너리가 이미 고쳐진 것이므로 새로 빌드해
설치할 이유도 없었다 (`swift build` 는 exit 0, `Build complete`, 새로 컴파일할 것 없음).

## 완성 조건 대조

| # | 조건 | 판정 | 근거 |
|---|---|---|---|
| 1 | 기존 데이터 마이그레이션 금지 | **지켰다** | 데이터 파일을 한 개도 안 고쳤다. 포맷의 `Z` 를 남겨 옛 `+0530`/`+0900` 이 그대로 읽힌다. 오프셋 없는 값은 적힌 그대로 둔다 — 없는 정보를 UTC 라고 지어내지 않는다 |
| 2 | 신규 시각은 UTC 저장 | **됐다** | 세 원장 `TimeZone(identifier:"UTC")`. 도는 앱이 오늘 쓴 `versionFirstSeen = …+0000` |
| 3 | 설정 시간대로 표시 · 설정 변경 반영 | **됐다** | 표시 12 자리가 `isoDisp` 를 거친다. 도는 앱에서 설정 6 회 전환이 매번 `CM_TZ` 에 반영 |
| 4 | UTC · KST · IST 변환과 전환을 실제 검증 (날짜 경계 · 30분 오프셋) | **했다** | 위 표 둘. `.e2e/timezone.test.js` 32/0 + 라이브 16/0 |
| 5 | 도는 앱에 반영 및 확인 | **했다** | 근거 넷 (바이너리 · 설정 전환 · 앱이 쓴 UTC 값 · 서빙된 JS 실행) |
| 6 | 이 결과 파일 | **이 파일** | |

## 미완료 사항

**이번 범위 안에는 없다.** 막힌 것도 없다.

## 발견 (실행하지 않고 한 줄씩만 남긴다)

- 다른 작업자의 BGM 자동재생 수정(`BGMPlayerContent.swift` 의 `!EMBEDDED || engaged`)이 아직
  커밋되지 않은 채 워킹트리에만 있다. `git checkout` 한 번이면 침묵이 돌아온다. 그쪽 작업자의
  것이라 이 세션은 손대지 않았다.
- `.e2e/slackdecision.test.js` 가 어떤 npm 스크립트에도 게이트에도 없다 (`run.js` 가 스스로
  경고한다). 이번 건과 무관한 기존 상태다.
- 저장소 워킹트리에 `_to_delete/` · `.state/` · `session-env-2026-07-06.csv` · `.cmdev-cert.pem`
  이 추적되지 않은 채 쌓여 있다. 이번 건과 무관하다.

## 1초 요약

요구 — 앞으로 생성되는 시간은 UTC 로 저장하고 화면에서는 설정한 시간대로 변환하며 설정 변경이
반영되게 한다.
문제 — 변환을 안 하고 저장된 ISO 문자열을 잘라 찍고 있었다. 자르기는 변환이 아니다.
완성 — 표시 12 자리가 `isoDisp` 를 거치고 신규 저장이 UTC 이며, **지금 도는 앱**에서 한국·인도·
UTC 가 갈리는 것을 서빙된 바이트로 확인했다. 기존 데이터는 안 건드렸다.
