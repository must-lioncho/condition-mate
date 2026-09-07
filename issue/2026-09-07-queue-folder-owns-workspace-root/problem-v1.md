# 문제 정의 v1 — 큐 경로가 워크스페이스 루트의 유일한 출처다

기반 의도 — [`intent.md`](intent.md) (I1) · 2026-09-07

## 문제 한 문장

**워크스페이스 루트가 자기 출처를 갖지 않고 큐 폴더 문자열에서 되짚어 만들어지는데, 그 되짚기가
성립하던 근거(옛 큐 경로 안에 `/organization/` 조각이 있었다)가 사라졌고, 같은 날 들어온 폴더
선택기가 그 문자열을 사용자가 아무 값으로나 바꿀 수 있게 만들었다.**

## 관측 — 내가 직접 읽고 실측한 것

`Sources/ConditionMate/Core/WorkQueueStore.swift:58-68`

```swift
static var lionWorkRoot: URL {
    let env = (ProcessInfo.processInfo.environment["CM_LION_WORK_DIR"] ?? "") …
    if !env.isEmpty { return URL(fileURLWithPath: …) }
    let p = root.path
    if let r = p.range(of: "/organization/") {
        return URL(fileURLWithPath: String(p[..<r.lowerBound]), isDirectory: true)
    }
    return root          // ← 여기로 떨어진다
}
```

| # | 관측 | 근거 (내가 실행한 확인) |
|---|---|---|
| O1 | 옛 큐 경로가 디스크에 없다 | `ls -ld /Users/lioncho/Work/lion_work/organization/lion/lion-work-queue` → `No such file or directory` |
| O2 | 새 기본값에 `/organization/` 이 없다 | `WorkQueueStore.swift:31-32` 의 `defaultRootPath = "/Users/lioncho/Work/lion_work/queue"` |
| O3 | 따라서 `lionWorkRoot` 는 `return root` 로 떨어져 **큐 폴더 자신**이 된다 | O2 + 위 코드. 문자열에 `/organization/` 이 없으므로 `range(of:)` 가 nil |
| O4 | 그 값을 쓰는 곳이 셋이다 | `IssueOrcaLauncher.swift:25` (Orca 세션 cwd), `WorkQueueStore.swift:650` (`organization/…` 산출물), `:658` (상대 `target:` 의 기준) |
| O5 | **카드 166 개 중 67 개(40%)** 가 `organization/…` 상대값을 들고 있다 | `grep -rlE '^[a-zA-Z_]+: *organization/' queue/inbox queue/done \| wc -l` → 67, 전체 `.md` 166 |
| O6 | 그 67 개는 지금 `/Users/lioncho/Work/lion_work/queue/organization/…` 로 풀린다 — 없는 경로다 | O3 + `resolve()` 의 `kindWorkspace` 갈래 |
| O7 | 사용자가 고른 폴더가 `root` 의 **최우선** 출처가 됐다 | 커밋 안 된 수정 `WorkQueueStore.swift:36-38` — `Settings.shared.queueFolder` 가 환경변수보다 앞이다 |
| O8 | 폴더 선택기는 아무 폴더나 받는다 | `AppDelegate.swift:pickQueueFolder()` — `canChooseDirectories = true`, 경로 검사 없음 |
| O9 | **이 결함을 잡았어야 할 e2e 게이트가 지금 꺼져 있다** | `.e2e/issues.test.js:594-595` 의 `QDIR` 폴백이 옛 경로를 하드코딩한다. O1 로 `fs.existsSync` 가 거짓 → 라이브 큐 블록 전체가 조용히 건너뛰어진다 |
| O10 | 자동 러너가 `CM_WORK_QUEUE_DIR` 를 설정하는 자리는 없다 | `.e2e/package.json` 과 `scripts/` 전수 grep — 설정하는 곳 0 개. 격리는 사람이 손으로 넣는 환경변수 하나뿐이다 |
| O11 | SPEC 에 큐 경로·워크스페이스 루트·변경 버튼 항목이 하나도 없다 | `docs/specs/SPEC.md` 전수 grep. 최대 dash id 는 `DASH-14` |

## 가설 — 아직 확인하지 않은 것

- **H1.** O6 의 67 개 중 실제로 화면에서 죽은 포인터로 보이는 개수를 화면에서 세어 보지 않았다.
  코드 경로상 전부 죽는 것이 맞지만 **도는 앱에서 눈으로 확인하지 않았다.**
  근거: `/Applications/ConditionMate.app` 바이너리(2026-09-06 23:09 빌드)에 이번 수정이 없다.
- **H2.** `lionWorkRoot` 의 `return root` 폴백이 지키려던 "픽스처 자기완결" 은 주석에만 있고
  실제로 그 폴백에 의존하는 픽스처를 디스크에서 찾지 못했다 (O10). 존재하지 않는다고
  단정하지는 않는다 — 사람이 손으로 만들어 쓰는 것은 흔적이 안 남는다.

## 문제 목록 — 우선순위

| ID | 문제와 근거 | 순위 | 순위 이유 | 선행 조건 | 확인 방법 | 완료 조건 | 현재 상태 |
|---|---|---|---|---|---|---|---|
| **P1** | 워크스페이스 루트가 자기 출처 없이 큐 문자열에서 파생된다. 파생 규칙의 전제(O1)가 죽었다. 소유 관계를 정하지 않으면 아래 전부가 임시방편이 된다 | **1** | 이 판정이 P2·P3·P4 의 **모양을 바꾼다.** 파생을 유지하기로 하면 P2 는 문자열 규칙 추가이고, 끊기로 하면 P2 는 새 폴백 상수다. 뒤에 알면 P2 를 두 번 짠다 | 없음 | 후보 셋을 놓고 카드의 `완성` 줄(임의 폴더를 골라도 루트가 안 따라간다)에 대조한다 | 후보 하나가 골라지고 **고르지 않은 것이 왜 아닌지**가 적혀 있다 | **확인됨** — `solutions-v1.md` 에서 S4 채택 |
| **P2** | 카드 67/166 의 `organization/…` 산출물이 없는 경로로 풀린다 (O5·O6). 사용자가 /issues 에서 누르는 링크가 죽는다 | 2 | 사용자가 실제로 겪는 증상. 다만 고치는 **방법**이 P1 판정에 달려 있다 | P1 | `resolve()` 에 `organization/…` 값을 넣어 `lion_work` 아래로 풀리는지 본다 | 단위 확인 하나로 `organization/x` 가 `/Users/lioncho/Work/lion_work/organization/x` 로 풀린다 | **미확인** — 워커가 고친다 |
| **P3** | 폴더 선택기로 임의 폴더를 고르면 Orca 세션 cwd 와 산출물 기준이 그 폴더를 따라간다 (O7·O8) | 3 | P2 와 같은 뿌리인데 **아직 안 터진 쪽**이다. 선택기가 오늘 실렸으므로 클릭 한 번으로 도달한다. P2 를 고쳐도 이쪽을 안 막으면 같은 버그가 사용자 손으로 재생산된다 | P1 | 큐 폴더를 `/tmp/…` 로 두고 `lionWorkRoot` 를 읽는다 | 임의 폴더 상태에서 `lionWorkRoot` 가 `/Users/lioncho/Work/lion_work` 다 | **미확인** — 워커가 고친다 |
| **P4** | 이 결함을 잡을 e2e 게이트가 꺼져 있다 (O9). 옛 경로 폴백 때문에 라이브 큐 블록이 조용히 건너뛰어진다 | 4 | 순위가 낮은 것이 덜 중요해서가 아니다. **P1 판정이 있어야 무엇을 단언할지 정해진다.** 다만 이것을 안 고치면 P2·P3 수정이 다음에 또 조용히 되돌아간다 | P1 | `node .e2e/issues.test.js` 를 돌려 라이브 큐 블록이 실제로 돌았는지 본다 | 게이트가 새 경로를 보고, 새 단언이 실패하도록 일부러 깨 봤을 때 실패한다 | **미확인** — 워커가 고친다 |
| **P5** | SPEC 에 이 계약이 없다 (O11). 다음 사람이 `lionWorkRoot` 를 고쳐도 무엇을 어긴 것인지 알 방법이 없다 | 5 | 산출물이지 불확실성이 아니다. P1 판정문이 그대로 SPEC 본문이 되므로 마지막이다 | P1·P2·P3 | SPEC 에 항목이 서고 `Verify:` 줄이 실제 파일:줄을 가리키는지 본다 | `DASH-15` 가 서고 `Verify:` 가 해석되는 파일:줄을 가리킨다 | **미확인** — 워커가 세운다 |
| **P6** | 도는 앱(`/Applications`)에 이번 수정이 없다 (카드 근거 6) | — | **이번 범위 밖.** 병렬 `FAST` 자식 `...-button-ship` 의 (d) 가 재빌드를 소유한다. 여기서 하면 겹친다 | — | — | — | **범위 밖 — FAST 자식 소유** |

## 지금 1순위와 그 판정의 완료 조건

**1순위는 P1 이다.** 완료 조건은 "코드를 고쳤다" 가 아니라 **"후보 셋 이상을 놓고 하나를 고르고,
고르지 않은 것이 왜 아닌지가 적혀 있다"** 이다. 그것이 [`solutions-v1.md`](solutions-v1.md) 이고
이미 서 있다 — **S4 채택.**

## 판정별 다음 행동

| P1 판정 | 다음에 할 것 |
|---|---|
| S1 (파생 유지 + 규칙 추가) | `lionWorkRoot` 에 문자열 갈래를 늘린다. P3 는 **고쳐지지 않는다** — 그 사실을 SPEC 에 한계로 적는다 |
| S2 (루트가 상위 설정, 큐를 그 아래로) | 설정 두 개와 마이그레이션이 필요하다. 이번 범위를 넘는다 |
| S3 (완전 독립 설정 두 개) | UI 설정을 하나 더 만든다. 격리 시험이 환경변수 둘을 요구하게 된다 |
| **S4 (채택)** | 큐 경로를 **힌트로 강등**하고, 못 찾으면 큐 폴더가 아니라 **자기 기본 상수**로 떨어지게 한다. P2·P3 가 같이 닫힌다 |

## 보류할 작업

- **앱 재빌드와 `/Applications` 반영.** `FAST` 자식이 소유한다 (P6).
- **`/api/settings/reveal` 의 `queue` 갈래, `/issues` 상자의 변경 버튼.** `FAST` 자식이 이미 넣었다
  (`git diff` 로 확인). 손대지 않는다.
- **워크스페이스 루트를 화면에서 바꾸는 UI.** 사용자가 요청하지 않았고 의도 문서에 미확인으로
  남겼다. 환경변수로만 둔다.

## 변경 이력

| 버전 | 날짜 | 무엇이 바뀌었나 |
|---|---|---|
| v1 | 2026-09-07 | 최초. PM 실측 6 항목을 근거로만 쓰고 코드를 직접 읽어 O1~O11 로 다시 세웠다. PM 이 안 본 O9(게이트 꺼짐)·O10(격리 러너 없음)·O5(67/166)를 새로 실측했다. |
