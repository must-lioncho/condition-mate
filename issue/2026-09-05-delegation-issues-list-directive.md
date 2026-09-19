# 위임 이슈 목록 화면 작업지시서 (항목 1)

- 날짜: 2026-09-05
- 트랙: BEST · 레벨 L1 · 규모 P2 · 정리 레벨 바닥 C2
- 트랙 카드: `organization/lion/lion-work-queue/inbox/2026-09-05-2228-condition-mate-delegation-issues.md`
- 대상 화면: 대시보드 왼쪽 레일 → 새 칸 `이슈` → 새 독립 페이지 `/issues`
- 이 문서를 쓴 자리: 이 폴더는 `P2` 라 PO 자리가 따로 없다. 진입 세션이 자기 손으로 썼다.
- 후속 문서: `issue/2026-09-05-delegation-issue-detail-directive.md` (항목 3, 상세 화면). **이 문서가 먼저다.**

## 원문 (온 그대로, 요약하지 않았다)

> 디렉터 에이전트에게 위임을 하고
> /Users/lioncho/.must-aios/issues
> 내가 지금 여기 라이언 언더바 워크에서 디렉터 에이전트에게 위임 할 때마다 다른 폴더는 아니야. 여기 라이어 언더밑 워크를 여기에서만 내가 디레터 에이전트에 위임을 하면 그 이 지금 그리고 그리고 어떤 것을 나중에 하려고 할지 어떤 게 중요한지 이런게 파악이 전혀 안되거든 그래서 이거를 좀 정리하려고 그래
>
> 그래서 여기에서 컨디션 메이트의 메뉴를 하나 더 만들어서 왼쪽에 있는 메뉴 중에 지금 한 칸을 더 만들어져서 그걸 누르면 이제 이슈가 나오고 그러면 거기에서 쭉 나오겠지? 내가 거기서 뭘 완료했고 뭘 안 했는지를 볼 수 있도록 그러면 이제 중요한 일단 첫 번째는 이거야
> 한 곳에서 내가 일하는 것들을 그래서 내 머릿속에 비워내는 게 가장 우선이야
>
> 내 머릿속을 비워내는 것 깨끗하게 하는 거 그래서 좀 더 중요한 걸 집중할 수 있도록 하는 거 지치지 않게 해주는 거 이게 첫 번째
>
> 자 이거 전체 하는 목적은 이거야 내 머릿속을 비워내고 쏟아내고 지금 40개 프로젝트와 40개의 프로젠트를 동시에 다발적으로 작업을 할 수 있게끔 하기 위함이야 지금은 이 인터페이스에서는 너무 어려워 병률로 하는게 거의 좀 어려워

## 이 일이 무엇인지 — 목록 화면을 만드는 일이 아니다

라이언이 우선순위 1 로 못박은 것은 화면이 아니라 **머릿속을 비워내는 것**이다. 목록을 그려
놓고 끝내면 실패다. 판정 기준은 하나다.

> 이 화면을 켠 뒤에, 내가 무엇을 위임했고 무엇이 끝났는지 알아내려고 **다른 창을 여는 횟수가 0** 이어야 한다.

이 문장이 아래 모든 설계 결정의 근거다. "정보가 화면에 있다" 가 아니라 "이 화면만 보고
끝난다" 가 기준이므로, 값이 없는 칸을 조용히 비워 두는 것은 허용되지 않는다. 비어 있으면
라이언은 확인하러 다른 창을 연다. **없으면 없다고 화면에 쓴다.**

## 실측 — 위임한 일의 실체는 이미 디스크에 있다

새로 만들 원천이 없다. 라이언이 말하는 "위임한 일" 은 `lion-work-queue` 의 트랙 카드다.

```
/Users/lioncho/Work/lion_work/organization/lion/lion-work-queue/
  inbox/   30 개 (카드 28 + png 2)
  done/    55 개
  QUEUE.md         두 레인(핫=FAST, 베스트=BEST)과 갱신 이력
  ROUTING-LOG.md   라우팅 기록
  INDEX-folders.md 폴더 인덱스 (L·C·P 값의 정의가 여기 있다)
  destinations.json
```

카드 `.md` 는 83 개다. 프론트매터 + `## 원문` + `## 1초 요약` 구조다.

### 실측 1 — 폴더가 완료를 뜻하지 않는다. 이것이 가장 중요한 사실이다

`done/` 안의 55 개를 `status:` 로 세면 이렇다.

```
$ grep -h '^status:' done/*.md | sort | uniq -c
  33 status: done
  16 status: classified      ← 완료가 아니다
   2 status: 닫힘
   2 status: incomplete
   1 status: folded
   1 status: split
```

`classified` 16 개는 **분류만 끝나고 일은 안 된 카드**인데 `done/` 에 들어 있다. 그러므로
`done/` 에 있다는 이유로 완료로 세면 **16 개를 완료라고 거짓말한다.** 라이언이 이 화면을
믿고 창을 안 여는 것이 목적인데, 거짓 완료는 그 목적을 정확히 반대로 깬다.

**폴더가 아니라 `status:` 값으로 판정한다.** 이것은 협상 대상이 아니다.

### 실측 2 — `status:` 값이 12 종이고 한국어와 영어가 섞여 있다

```
$ grep -h '^status:' inbox/*.md done/*.md | sort | uniq -c | sort -rn
  33 status: done            10 status: queued        2 status: submitted
  16 status: classified       2 status: incomplete     1 status: split
  13 status: 던짐             2 status: "던짐"          1 status: running
   2 status: 닫힘             1 status: folded         1 status: blocked
   1 status: 창 사라짐 — 결과 미확인
```

`던짐` 이 따옴표 있는 것과 없는 것으로 갈려 있다(13 + 2). 파서는 값을 읽은 뒤 앞뒤 따옴표와
공백을 벗겨야 한다. 그러지 않으면 같은 상태가 두 줄로 갈려 나온다.

### 실측 3 — 프론트매터 키가 카드마다 다르다

```
$ 83 개 카드의 프론트매터 키 census
  83 id:  83 captured:  83 status:  83 target:
  67 track:  67 target_handle:  67 return_handle:
  20 cleanup:   5 cleanup_level:   3 cleanup_floor:     ← 같은 뜻이 세 이름
  16 issue:                                             ← 작업지시서 경로
  12 closed:  11 closed_at:   1 completed:  1 completed_at:
   9 artifact:  8 artifacts:  4 output:  4 outputs:  1 output_path:  1 supporting_artifacts:
```

- `track:` 이 **16 개 카드에 없다.** 8/25~8/27 의 옛 카드다. 트랙 필터를 만들 때 `없음` 을
  버리면 그 16 개가 화면에서 사라진다. 버리지 말고 `트랙 없음` 으로 표시한다.
- `target:` 은 83 개 전부에 있지만 **30 개가 빈 값**(`target:` / `target: ""` / `target: "`)이다.
- `cleanup` 계열이 세 이름으로 갈려 있다. 세 이름을 다 읽어 하나로 합친다.

### 실측 4 — git 은 버전 원천이 못 된다

`lion_work` 는 `.gitignore` 의 `/*` 로 큐 폴더를 통째로 무시한다(`git check-ignore` 확인).
큐 폴더 자체는 **자기 git 저장소**를 갖고 있지만 실질적으로 죽어 있다.

```
$ cd lion-work-queue && git log --oneline | wc -l   →  3
$ git ls-files 'inbox/*.md' 'done/*.md' | wc -l     →  63   (83 중 20 개는 추적조차 안 됨)
$ 카드별 리비전 수: 82 개가 1, 1 개가 2
```

커밋 3 개에 카드 대부분이 리비전 1 이므로 git 히스토리로는 버전을 못 센다. **이 사실은
항목 3 의 버전 설계에 그대로 넘어간다.** 이번 항목에서는 버전을 다루지 않는다.

## 실측 — 레일에 칸을 하나 더 넣는 배관

### 3×3 그리드는 정말로 다 찼다

`Sources/ConditionMate/Dashboard/SessionRail.swift:64`

```
.cmrail-nav{ display:grid; grid-template-columns:repeat(3,1fr); gap:4px; padding:6px;
  margin:0 8px 6px; background:#0f141d; border:1px solid #1c2230; border-radius:12px }
```

항목 9 개는 448~465 행 — 대화·플러그인·크론·위임·팀위임·작업·번역·에이전트·루프 엔지니어링.

82~95 행 주석이 라벨 폭 계산을 못박고 있다. 요지: 레일 240px → `.cmrail-nav` 좌우 마진
8px 씩(224px) → 패딩 6px(212px) → 3 열 + 4px 갭 2 개 = **열 68px** → `.cmrail-item` 좌우
패딩 4px = **글자 상자 60px**. `루프 엔지니어링` 만 이 60px 에 안 들어가서 `.wrap2` 로 두 줄
처리하고 있고, `word-break:keep-all` 이 load-bearing 이라고 명시돼 있다.

**즉 열 수를 바꾸면 이 60px 이 무너지고 라벨 9 개가 전부 다시 계산돼야 한다.**

### 페이지 하나를 새로 다는 배관은 이미 다섯 번 반복된 패턴이다

`루프 엔지니어링` 이 가장 최근에 이 길을 갔다. 만져야 할 자리가 정확히 다섯 곳이다.

| # | 자리 | 루프 엔지니어링의 예 |
|---|---|---|
| 1 | `SessionRail.swift:465` | `<a class="cmrail-item" data-nav="loop" onclick="cmNav('loop')">` |
| 2 | `SessionRail.swift:3537` | `if(kind==='loop'){ if(window.CM_PAGE!=='loop') location.href='/loop-engineering'; return; }` |
| 3 | `SessionRail.swift:3493` | `if(window.CM_PAGE==='loop'){ setActive('loop'); return; }` (cmNavReflect) |
| 4 | `AppDelegate.swift:83` | `if path.hasPrefix("/loop-engineering") { return LoopEngineeringContent.html() }` |
| 5 | `DashboardServer.swift:470` | 페이지 프리픽스 목록에 `/loop-engineering` 추가 |

API 는 두 곳이다. `AppDelegate.swift:153` 에 핸들러를 달고,
`DashboardServer.swift:414~451` 의 GET 허용 목록에 프리픽스를 추가한다. 목록에 안 넣으면
GET 이 대시보드 HTML 로 떨어져 JSON 대신 HTML 이 온다.

페이지 본문은 `Sources/ConditionMate/Dashboard/LoopEngineeringContent.swift` (932 행) 가
본보기다. 262 행에서 `window.CM_PAGE='loop'` 를 심는다 — 이것이 3 번을 작동시키는 값이다.

`Package.swift:71` 이 `Sources/ConditionMate` 를 폴더째 타깃으로 잡으므로 **새 `.swift` 파일을
그 폴더에 놓기만 하면 컴파일에 들어간다.** `Package.swift` 는 안 고친다.

### 칸을 10 개로 늘리면 지금 도는 e2e 시험이 깨진다

이것이 이 작업에서 유일한 기존 회귀 지점이고, 놓치면 `npm test` 가 빨갛게 된다.

`.e2e/plan.test.js:54-63` 이 레일 `<nav>` 를 정규식으로 뜯어 **개수·순서·라벨을 문자열로
못박아** 놓고 있다.

```js
check('nav has 9 items', items.length, 9);
check('nav flow order (plan removed)', items.map(x => x.nav),
      ['chat','skills','cron','delegate','team','work','slack','agents','loop']);
check('nav labels', items.map(x => x.lbl),
      ['대화','플러그인','크론','위임','팀위임','작업','번역','에이전트','루프 엔지니어링']);
```

`plan.test.js` 는 `.e2e/run.js:50` 의 `GATE` 배열에 들어 있어 `npm test` 에서 실제로 돈다.
세 줄을 10 개 기준으로 같이 고친다. **`.off` 예약 칸도 `cmrail-item` 클래스를 달고 있으므로
정규식에 잡힌다** — 개수는 9 가 아니라 12 가 된다(실물 10 + 예약 2). 셋 중 어느 수가 맞는지는
마크업을 실제로 짠 뒤 정규식을 돌려 확인하고, 확인한 수를 쓴다. 짐작으로 쓰지 마라.

새 페이지 자체의 시험은 `.e2e/issues.test.js` 로 따로 만들고 `run.js` 의 `GATE` 에 등록한다.
등록 안 하면 파일만 있고 안 도는 시험이 된다 — `package.json` 설명에 낡은 시험 16 건이 20 일
숨었던 기록이 그대로 남아 있다.

## 갈래와 내가 고른 것

### 갈래 A — 그리드를 어떻게 늘리는가

| 안 | 내용 | 값 | 위험 |
|---|---|---|---|
| A1 | 4 번째 행 추가 (3×4). 10 번째 칸에 `이슈` | 열 60px 불변, 기존 9 개 라벨 손 안 댐 | 빈 칸 2 개 |
| A2 | 4 열로 (4×3) | 빈 칸 없음 | 글자 상자 60px→42px. `루프 엔지니어링`·`에이전트`·`플러그인` 라벨 전부 깨짐 |
| A3 | 기존 칸 하나를 교체 | 공짜 | 라이언은 "한 칸을 **더**" 라고 했다. 요구 위반 |
| A4 | 그리드 밖 상단에 전폭 항목으로 | 그리드 수학 불변 | 아홉 개와 다른 모양이라 메뉴가 두 종류가 됨 |

**A1 을 고른다.** 근거는 두 개다. 첫째, `SessionRail.swift:82-95` 주석이 60px 을 지키라고
명시적으로 경고하고 있고 A2 는 그것을 정면으로 깬다 — 이번 요구는 칸 하나 추가이지 라벨
9 개 재조판이 아니다. 둘째, **빈 칸용 스타일이 이미 코드에 있다.**

`SessionRail.swift:84` 근처:
```
/* Reserved-slot styling: visible so the grid reads complete, but clearly inert.
   No slot wears it today — the 3×3 grid is full since 루프 엔지니어링 took the ninth
   (2026-08-23). Kept for the next reserved slot. */
.cmrail-item.off{ opacity:.35; pointer-events:none }
```

`.off` 는 정확히 이 상황을 위해 남겨 둔 것이고 지금 아무도 안 쓰고 있다. 남는 두 칸에
`.off` 를 입히면 행이 깨진 것이 아니라 **예약된 것**으로 읽힌다. 코드가 이미 이 결정을
예상해 두었다.

`grid-template-columns` 는 건드리지 않는다. 항목을 10 개로 늘리면 CSS grid 가 자동으로 4 번째
행을 만든다. **CSS 를 한 줄도 안 고쳐도 된다** — `.cmrail-item.off` 를 두 개 추가하는 것이
전부다. 라벨 `이슈` 는 2 글자라 60px 에 여유롭게 들어가므로 `.wrap2` 가 필요 없다.

### 갈래 B — 완료·미완료 축을 어떻게 자르는가

12 종 상태를 그대로 보여 주면 라이언이 12 개를 해석해야 한다. 그건 머릿속을 비우는 것이
아니라 채우는 것이다. **4 개 버킷으로 정규화한다.**

| 버킷 | 들어가는 `status:` 값 | 뜻 |
|---|---|---|
| `완료` | `done`, `닫힘`, `folded`, `completed` | 끝났다 |
| `도는 중` | `던짐`, `"던짐"`, `running`, `submitted`, `dispatched` | 지금 다른 창에서 돌고 있다 |
| `대기` | `queued`, `classified`, `split` | 아직 시작 안 했다 |
| `막힘` | `blocked`, `incomplete`, `창 사라짐 — 결과 미확인` | 멈췄다. 사람이 봐야 한다 |

**모르는 값은 `미분류` 라는 다섯째 버킷으로 보낸다. 절대 `완료` 로 흘리지 않는다.** 큐의
상태 어휘는 지금도 늘고 있으므로(오늘만 `창 사라짐 — 결과 미확인` 이 새로 생겼다) 새 값이
조용히 완료로 세어지는 것이 이 화면이 망가지는 가장 빠른 길이다.

라이언의 말은 "뭘 완료했고 뭘 안 했는지" 라 축이 둘처럼 보이지만, 안 한 것 셋을 한 덩어리로
묶으면 `막힘` 이 `대기` 에 묻힌다. **`막힘` 이야말로 라이언이 가장 먼저 봐야 하는 것**이다 —
아무도 안 건드리는데 아무도 모르는 상태다. 그래서 넷으로 가른다. 화면 맨 위에는 큰 수 두
개(`완료 N` / `안 됨 M`)를 두고, `안 됨` 아래에 셋을 나눠 보인다.

### 갈래 C — 원천이 둘이다. `IssuePaths` 는 둘 다 아니다

**2026-09-05 22:48 에 전제 하나가 정정됐다.** 앞선 브리핑은 "이슈 루트와 목표 폴더 코드는
`IssuePaths.swift` 에 있다" 고 적고 있었다. 두 개념을 한 이름으로 붙여 읽은 것이고, 지금은
갈라졌다.

**`IssuePaths.root` 는 이슈 루트가 아니라 목표(goal) 저장소다.** 실측:

```
$ ls -d ~/.condition-mate/issue/goal-* | wc -l   →  155
$ ls ~/.condition-mate/issue                     →  goal-01 goal-02 … _pending-att goal-07.md
```

goal 폴더 155 개와 첨부와 goal 별 chat 이 그 아래 산다. **여기를 가리키게 바꾸거나 여기에
파일을 떨어뜨리면 기존 goal 폴더 155 개가 오염된다.** 손대지 마라. 읽지도 마라 — 이번 화면과
아무 상관이 없다.

이슈가 쓰는 것은 **`Sources/ConditionMate/Core/IssueFolder.swift`** 다 (2026-09-05 22:48 신설).
그 파일이 스스로 경계를 주석에 적어 두었다 — "An issue is a different object — it belongs to
the PROJECT the work was delegated from, not to the app's own data dir." API 는 이렇다.

```swift
IssueFolder.override      -> URL?    // 사용자가 설정에서 고른 폴더. 있으면 이긴다. "issue" 를 덧붙이지 않는다.
IssueFolder.isDefault     -> Bool    // override 가 없는 동안 true
IssueFolder.defaultRoot(cwd:) -> URL // <cwd>/issue. cwd 가 비면 AppPaths.sub("issue")
IssueFolder.resolved(cwd:)    -> URL // 정본 호출 자리. 디스크를 안 건드린다.
IssueFolder.ensured(cwd:)     -> URL?// 같되 폴더를 만든다. 못 만들면 nil — 그때는 다른 데 쓰지 말고 못 썼다고 말한다.
```

**그런데 `IssueFolder` 만으로는 이번 완성 조건이 안 된다.** 기본값 경로가 지금 비어 있다.

```
$ ls /Users/lioncho/Work/lion_work/issue   →  No such file or directory
```

`IssueFolder.resolved(cwd: "…/lion_work")` 는 아직 존재하지 않는 폴더를 가리킨다. 이것만 읽으면
화면이 비고, "lion_work 에서 위임한 일이 쭉 나온다" 는 완성 조건이 깨진다.

**그래서 원천을 둘로 갈라 쓴다.** 둘은 다른 것이고 서로를 대체하지 못한다.

| 원천 | 무엇 | 어디서 | 이번 항목에서 |
|---|---|---|---|
| 위임 카드 83 개 | 무엇을 위임했고 무엇이 끝났나 | `lion-work-queue/{inbox,done}/*.md` | **완료·미완료 축의 유일한 원천** |
| 이슈 문서 | 앞으로 이슈 파일이 떨어질 자리 | `IssueFolder.resolved(cwd:)` | 폴더가 비어 있으면 그렇다고 쓴다 |

큐 경로는 `IssueFolder` 가 답해 주지 않으므로 **새 파일에 자기 상수로 둔다.** 기본값
`/Users/lioncho/Work/lion_work/organization/lion/lion-work-queue`, 환경변수
`CM_WORK_QUEUE_DIR` 로 덮어쓸 수 있게 한다(격리 인스턴스 테스트에 필요하다). 폴더가 없으면
빈 목록이 아니라 **"큐 폴더를 못 찾았다 + 찾아본 경로"** 를 화면에 쓴다.

### 남의 창이 소유한 자리 — 읽어도 되지만 고치지 마라

바로 앞의 FAST 창(`2026-09-05-2228-issue-folder-default-setting`)이 방금 끝나면서 아래를
소유했다. **커밋되지 않은 채 브랜치에 남아 있다.**

- `Settings.swift` 의 `cm.issueFolder` (`Settings.swift:42,174-176`)
- `AppDelegate.swift` 의 `/api/settings/paths`, `/api/settings/issue-folder`(7422),
  `/api/settings/issue-folder/pick`(7425)
- `SessionRail.swift` 의 레일 ⚙️설정 패널 **"이슈 폴더" 행**

마지막 것을 특히 조심하라. **`SessionRail.swift` 는 너도 그리드 때문에 여는 파일이다.
같은 파일 안에서 `<nav class="cmrail-nav">` 블록과 `cmNav`/`cmNavReflect` 만 만지고, 설정 패널의
"이슈 폴더" 행은 한 글자도 건드리지 마라.**

## 무엇을 만드는가

### 1. `Sources/ConditionMate/Core/WorkQueueStore.swift` (신규)

큐를 읽어 카드 배열로 만드는 자리. 이번 항목에서 필요한 것만 만든다.

- `inbox/*.md` 와 `done/*.md` 를 읽는다. `.md` 가 아닌 것은 건너뛴다(png 2 개가 있다).
- 프론트매터를 파싱한다. 첫 줄이 `---` 이고 다음 `---` 까지다. 값은 앞뒤 따옴표·공백을 벗긴다.
  블록 스칼라(`|`)와 리스트(`  - `)를 읽을 수 있어야 한다 — 산출물 키가 그 모양이다.
- 프론트매터가 없거나 깨진 카드는 **버리지 말고** `id` 를 파일명으로 삼아 `미분류` 로 싣는다.
- 필드: `id`, `captured`, `track`(없으면 `없음`), `status`(원문 그대로 보존), `bucket`(정규화 결과),
  `target`, `cleanup`(세 이름 합침), `folder`(`inbox`/`done`), `filePath`.
- 정렬 기본값: `captured` 내림차순(최신 위). 파싱 실패한 `captured` 는 파일 mtime 으로 대체.

### 2. `Sources/ConditionMate/Dashboard/IssuesContent.swift` (신규)

`/issues` 페이지 HTML. `LoopEngineeringContent.swift` 를 본보기로 삼되 그 화면의 복잡도를
따라가지 마라. 이번 화면은 목록 하나다.

- `window.CM_PAGE='issues'` 를 심는다.
- 맨 위: 큰 수 두 개 — `완료 N` / `안 됨 M`. 그 아래 작은 수 셋 — `도는 중 / 대기 / 막힘`.
- 필터 칩: 버킷 5 개 + 트랙(`FAST`/`BEST`/`없음`) + 대상 폴더. 복수 선택 없이 단일 선택이면 충분하다.
- 목록 한 줄에: 버킷 배지 · `captured` 날짜 · 제목 · 트랙 · `target` · 원래 `status` 문자열.
  - **제목**은 `## 1초 요약` 의 `요구` 줄을 쓰고, 없으면 `id` 슬러그를 사람이 읽을 수 있게 편다.
    (`요구` 줄이 없는 카드가 18 개다 — 아래 실측 참조.)
  - 원래 `status` 문자열을 같이 보이는 이유: 정규화가 틀렸을 때 라이언이 즉시 안다. 정규화를
    믿으라고 요구하지 않고 근거를 옆에 둔다.
- 빈 상태 문구를 상황별로 다르게 쓴다. "카드 0 개"(필터 결과 없음)와 "큐 폴더 없음"(경로 실패)은
  다른 사건이고 라이언이 할 일도 다르다.

> `## 1초 요약` 없는 카드 18 개(실측): `2026-08-25-1919-developer-vs-gtm-owner-essay` 외 17 개.
> 전부 8/25~9/03 의 옛 카드다. 이 카드들은 제목 자리에 슬러그를 편 문자열이 들어간다.

### 3. `/api/issues` (AppDelegate)

`AppDelegate.swift:153` 의 `/api/loop-engineering` 옆에 단다. `WorkQueueStore` 가 만든 배열을
JSON 으로 낸다. 카운트도 같이 넣어 화면이 다시 세지 않게 한다.

### 4. 배관 5 곳

위 표의 1~5 번을 `issues` 로 그대로 반복한다. `DashboardServer.swift` 의 GET 허용 목록에
`/api/issues` 를 넣는 것을 빠뜨리지 마라 — 빠뜨리면 JSON 대신 대시보드 HTML 이 온다.
`DashboardServer.swift:478` 의 catch-all `else` 가 **매칭 안 된 모든 GET 에 대시보드 HTML 을
200 으로 돌려준다.** 404 가 안 나므로 경로를 빠뜨려도 조용히 잘못된 것이 온다. 같은 파일
406~413 행의 `/api/orchestration` 주석이 이 함정을 이미 경고하고 있다.

### 5. `.e2e/plan.test.js` 수정 + `.e2e/issues.test.js` 신설

위 "칸을 10 개로 늘리면" 절대로. `plan.test.js` 는 컴파일 없이 Swift 소스를 문자열로 읽어
정규식으로 검사하는 방식이므로 빌드 없이 빨리 돈다. 새 시험도 같은 방식으로 쓴다.

## 이번에 하지 않는 것

- 상세 화면. 카드를 눌렀을 때의 동작은 항목 3 이다. 이번에는 **행이 눌리지 않아도 된다.**
- 결과물 경로 해석, Finder 열기, 버전. 전부 항목 3 이다.
- 카드 파일 쓰기. **이 화면은 읽기 전용이다.** `## 원문` 훼손으로 카드 하나가 폐기된 기록이
  `QUEUE.md` 2026-09-05 14:31 에 있다. 큐 폴더에 한 바이트도 쓰지 마라.
- `IssuePaths.swift`. 그것은 goal 저장소(155 개 폴더)다. 읽지도 고치지도 마라.
- 앞 절의 "남의 창이 소유한 자리" 세 곳. 읽는 것은 되지만 고치지 마라.
- `QUEUE.md`·`ROUTING-LOG.md` 파싱. 카드 파일만으로 이번 완성 조건이 충족된다.
- **커밋.** 브랜치 `feat/dashboard-value-pipeline` 에 남의 미커밋 변경이 섞여 있다.
  파일을 바꾸는 데까지만 하고 무엇을 바꿨는지 목록으로 돌려줘라.
  **`git add -A` 와 `git commit -a` 를 절대 쓰지 마라.** 남의 변경을 같이 담게 된다.

## 어떻게 확인하는가

1. `Scripts/build-app.sh` 가 통과한다.
2. 앱을 띄우고 레일에 칸이 10 개이고 10 번째가 `이슈` 이며, 남는 두 칸이 `.off` 로 흐리게 있다.
   기존 9 개 라벨 중 어느 것도 줄바꿈이나 말줄임이 바뀌지 않았다 (`루프 엔지니어링` 이 여전히
   두 줄이고 `루프 엔…` 이 아니다).
3. `이슈` 를 누르면 `/issues` 로 가고 `이슈` 칸이 켜진 채로 남는다(`cmNavReflect`).
### 큐는 살아 있다 — 기대값을 숫자로 박지 마라

**2026-09-05 23:10 정정.** 이 문서를 쓰기 시작한 22:30 에 카드가 83 개였는데 구현이 도는
사이에 **85 개가 됐다.** FAST 카드 하나가 `done/` 으로 옮겨졌고 새 카드 둘이 `inbox/` 에
들어왔다. `status` 분포도 같이 움직였다(`done` 33→34, `queued` 10→12).

그러므로 **기대값을 상수로 박은 시험은 내일 반드시 빨갛게 된다.** 맞게 짠 구현이 틀린 것처럼
보이는 시험은 없는 시험보다 나쁘다. 검증은 전부 **관계식**으로 쓴다.

4. 카드 수 == 그 순간의 `ls inbox/*.md done/*.md | wc -l`. 하나도 안 버렸다는 뜻이다.
   png 2 개는 안 센다.
5. `완료` 버킷의 수 == 같은 파일들에서 `status:` 가 완료 집합(`done`·`닫힘`·`folded`)에
   드는 카드의 수. **양쪽을 같은 순간에 세서 비교한다.**

   > **정정 (구현 중 워커가 잡았다).** 이 문서의 앞선 판은 완료 집합에 `completed` 를 넣고
   > `37 = done 33 + 닫힘 2 + folded 1 + completed 1` 이라고 적었다. **틀렸다.** 실측 표에
   > `completed` 라는 `status` 값은 없었고(그 이름은 `completed:` 라는 별개의 날짜 필드다),
   > 합도 36 이라 37 이 안 된다. 실제로는 구현 시점에 `done` 이 33→34 로 늘어
   > `34 + 닫힘 2 + folded 1 = 37` 이 된 것이다. 숫자를 못박지 말라는 바로 위의 규칙을
   > 이 문서 자신이 어겨서 생긴 오류다.
6. **불변식(이것이 진짜 시험이다): `classified` 인 카드는 단 하나도 `완료` 버킷에 없다.**
   `done/` 폴더에 있는 `classified` 16 개가 여기 안 들어간 것이 이 화면이 거짓말을 안 한다는
   증거다. 폴더로 세면 이 불변식이 깨진다.
7. `미분류` 버킷이 비어 있다. 비어 있지 않으면 새 상태 어휘가 생긴 것이므로 **그 값을 보고에
   적어라** — 실패가 아니라 매핑 표에 한 줄 더할 일이다.
7. `cd .e2e && npm test` 가 통과한다. `plan.test.js` 가 새 칸 수로 갱신됐고 `issues.test.js` 가
   `GATE` 에 등록돼 실제로 돈 것이 표에 찍힌다.
8. 큐 폴더에 아무것도 안 썼다: `cd lion-work-queue && git status --porcelain` 과 `ls -la inbox done`
   의 mtime 이 작업 전과 같다.

## 1초 요약

요구 — 컨디션 메이트의 왼쪽 메뉴에 한 칸을 더 만들어서 그걸 누르면 이슈가 쭉 나오고, 내가
거기서 뭘 완료했고 뭘 안 했는지를 볼 수 있게 해라. 목적은 내 머릿속을 비워내는 것이다.
문제 — 위임한 일의 원천은 이미 큐에 83 개 카드로 있으므로 만들 것은 목록이 아니라 **믿을 수
있는 완료 축**이다. 그런데 `done/` 폴더에 완료가 아닌 `classified` 16 개가 섞여 있어 폴더로
세면 화면이 16 개를 완료라고 거짓말하고, 상태 어휘는 12 종에 한글·영어·따옴표가 섞인 채 지금도
늘고 있어 새 값이 조용히 완료로 흘러들 수 있다. 라이언이 이 화면을 믿고 창을 안 여는 것이
목적이므로 거짓 완료 한 건이 화면 전체의 값을 0 으로 만든다. 그래서 폴더가 아니라 `status:`
값으로 4 개 버킷에 정규화하고, 모르는 값은 완료로 흘리지 않고 `미분류` 로 세워 보이게 한다.
그리고 그리드는 열을 늘리면 60px 라벨 계산이 무너지므로 행을 늘려 기존 9 개를 손대지 않는다.
완성 — 레일 10 번째 칸 `이슈` 가 `/issues` 를 열고, 카드 83 개가 하나도 안 버려진 채 `완료` 37 /
`안 됨` 46 으로 갈려 나오며, `안 됨` 이 `도는 중`·`대기`·`막힘` 으로 다시 갈리고, 각 행이 원래
`status` 문자열을 같이 보여 정규화를 라이언이 검산할 수 있고, 기존 9 개 라벨의 줄바꿈이 변하지
않는다.

---

## 커밋 판정 — 목적지 세션이 L1 로 정했다 (2026-09-05)

**커밋하지 않는다.** 이것은 미완료가 아니라 내린 결정이다.

근거는 실측이다. 브랜치 `feat/dashboard-value-pipeline` 에 미커밋 경로가 152 개 있고
(수정 62, 나머지는 추적 안 된 새 파일 — `.e2e/` 테스트 20 여 개와 `.claude/agents/` 등),
스테이지된 것은 0 이다. 이 일이 만든 10 개 파일은 그 152 개의 일부다. 같은 자리를 앞서
소유했던 FAST 창(`2026-09-05-2228-issue-folder-default-setting`)도 같은 이유로 커밋하지 않았다.

가정 — 이 항목이 요구한 것은 화면이 동작하는 것이고 커밋은 요구에 없었다. `git add -A` 로
담으면 남의 변경 142 개가 같이 들어가고, 경로를 하나씩 골라 담으면 이미 엉킨 브랜치에
부분 커밋이 하나 더 얹힌다. 둘 다 이 항목이 푸는 문제와 무관한 위험이므로 파일 반영까지만
하고 멈춘다. 브랜치 정리는 이 항목의 범위가 아니고 별건이다.

검증 — 이 결정 시점에 `swift build` 통과(`IssuesContent.swift.o` 와
`WorkQueueVersionLedger.swift.o` 가 debug·release 양쪽에 실재), e2e 54 파일 · 1591 단정 ·
0 실패, `lion-work-queue/` 변경 0 건, `HEAD` 는 `706f457` 그대로다.
