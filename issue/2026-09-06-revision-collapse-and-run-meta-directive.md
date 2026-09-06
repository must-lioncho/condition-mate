# 작업지시서 — 이슈 상세 섹션 2 를 접고, 그 수정을 만든 실행 정보를 같이 보인다

카드: `organization/lion/lion-work-queue/inbox/2026-09-06-0445-condition-mate-revision-details.md`
카드 id: `d7a0211b-3ee8-4a5e-a172-400cb674b595`
트랙 BEST · 레벨 L1 · 규모 P2 · 정리 C2
쓴 사람: `lion-condition-mate-pm` (P2 이므로 PM 이 PO 를 겸한다)

## 원문

라이언이 말한 그대로다. 요약하지 않는다.

```
컨디션 메이트 관련
디렉터 에이전트에게 위임

사진을 보면 지금 내가 원문을 주고 나서 그 원문에 이제 수정을 하잖아? 그 수정한 내용이
기본적으로 접혀있고 그걸 전문으로 볼 수 있게 해줘요 그리고 그거를 어떤 AI 모델이 그리고
얼마나 앱폭트를 써서 몇 초 걸려서 했는지도 알려줘요

그게 세션에 이게 나와 있지 않나 따로 파일을 만들 필요 없을 것 같은데
```

스크린샷은 `/issues` 상세 화면이다. 섹션 1 `리퀘스트 (원문)` 에는 접기·펼치기와 글자 수가
있고, 섹션 2 `수정된 최초의 리퀘스트` 에는 셋 다 없다. 라이언이 가리킨 "수정한 내용" 은
섹션 2 다.

## 조사해서 확정한 것 — 워커는 이것을 다시 조사하지 않는다

### 1. "수정" 은 어디서 오는가

`Sources/ConditionMate/Core/WorkQueueStore.swift:934-946` 이 전부다.

```
var cleaned = section(body, "정리된 요청")          // 실측 0 개
if cleaned.isEmpty { cleaned = summaryLine(body, "요구"); cleanedSource = "1초 요약의 요구" }
if cleaned.isEmpty { cleaned = String(origin.prefix(400)); cleanedSource = "(정리 안 됨)" }
```

곧 **섹션 2 의 값은 카드 파일의 `## 1초 요약` 의 `요구` 줄**이다. 앱이 실시간으로 만드는
값이 아니라 카드가 쓰일 때 이미 정해진 값이다. 그래서 "그 수정을 누가 했나" 는 **그 카드
파일을 쓴 실행**을 가리킨다.

### 2. 그 실행은 이미 세션 기록에 있다 — 새 파일이 필요 없다

이 카드로 실측했다. 카드를 쓴 것은

`~/.claude/projects/-Users-lioncho-Work-lion-work/11b66f83-03c0-4542-ac34-140b9f3cd2e4/subagents/agent-a76a3488df2463e20.jsonl`

의 Bash 툴 호출 한 번이다. `codex exec` 로 `lion-queue-po` 를 돌렸고, 그 **tool_result 본문에
Codex 배너가 그대로 들어 있다.**

```
OpenAI Codex v0.153.4
--------
workdir: /Users/lioncho/Work/lion_work
model: gpt-6-astra
provider: openai
approval: never
sandbox: workspace-write [workdir, /tmp, $TMPDIR]
reasoning effort: none
reasoning summaries: none
session id: 01a073da-80fa-7ab2-b8d8-5e5529240495
--------
...
tokens used
31,521
```

그리고 같은 tool_result 안에 카드를 만든 python 코드와 그 안의 `요구 —` 줄이 통째로 있다.

- 시작: tool_use 레코드 `timestamp` = `2026-09-05T23:14:54.708Z`
- 끝: tool_result 레코드 `timestamp` = `2026-09-05T23:15:53.646Z`
- 걸린 시간 = **58.9 초**

세 값이 전부 이미 디스크에 있다. **라이언의 제약 — "따로 파일을 만들 필요 없을 것 같은데" —
이 그대로 지켜진다.** 새 로그 파일을 만들지 않는다.

### 3. "앱폭트" 는 effort 다 — 추측이 아니라 근거가 둘이다

라이언의 구술 낱말 `앱폭트` 를 이렇게 확정한다. **`앱폭트` = `effort` (에포트).**

근거 하나. 위 배너에 `reasoning effort: none` 이라는 **필드가 그 이름 그대로 찍혀 있다.**
근거 둘. 이 카드를 쓴 Codex 실행이 돌려준 한 줄이 라이언의 낱말을 스스로 이렇게 옮겼다 —
"기존 세션에서 수정 전문과 **모델·에포트·소요 시간**을 확인하고 연결할 수 있는지 먼저
알아내야 한다." 다른 모델이 독립적으로 같은 음차를 골랐다.
반대 근거. 두 기록 형식(Codex 배너 · Claude JSONL) 어디에도 `output`·`impact`·`app` 계열
필드는 없다. 다른 후보가 물리적으로 존재하지 않는다.

다만 라이언의 문장은 `얼마나 앱폭트를 **써서**` 로, 쓴 **양**을 묻는다. `reasoning effort` 는
양이 아니라 설정값이다. 그래서 **둘 다 보인다.**

- `effort` — Codex 배너의 `reasoning effort:` 값. Claude 실행에는 이 필드가 없으므로 빈칸.
- `tokens` — 실제로 쓴 양. Codex 는 `tokens used` 줄, Claude 는 `message.usage` 의
  `input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens`.

**ASSUMPTION (L1, 갈래를 스스로 골랐다).** 라이언에게 되묻지 않고 이렇게 정했다. 화면에는
어느 필드에서 온 값인지를 같이 적어서, 이 해석이 틀렸을 때 라이언이 화면만 보고 반려할 수
있게 한다.

### 4. 기존 세션 링크를 재사용하면 **틀린 세션**이 나온다

`Core/WorkQueueSessionStore.swift` 의 `session(cardID:cardPath:cwds:)` 는 이미 카드↔세션
끈을 갖고 있다. 그러나 그 판정은 "**첫 지시문에 카드 id 가 든 세션**" = 카드를 **받은**
목적지 세션이다. 카드를 **쓴** 실행은 그보다 앞에 있고 다른 세션이다. 실측으로

- 카드를 쓴 실행: `agent-a76a3488df2463e20.jsonl` (codex / gpt-6-astra), 2026-09-05T23:14Z
- 카드를 받은 세션: `bc96ab37-…` (lion-condition-mate 폴더), 2026-09-06T08:45Z

**둘을 섞지 마라.** 새 판정을 따로 만든다.

### 5. 찾는 값은 얼마인가 — 실측했다

기록 전체는 `.jsonl` 3,298 개 / 2.1GB 다. 통째로 훑으면 안 된다(그 실패가 DASH-12 의
`카드당 16 초` 였다). 좁히는 열쇠는 카드 프론트매터의 `captured` 다.

`captured: 2026-09-06-0445` 는 카드를 쓴 python 이 `date +%Y-%m-%d-%H%M` 로 찍은 값이고,
이 맥의 로컬 타임존은 `Asia/Kolkata`(UTC+5:30) 다. `2026-09-05T23:15:53Z + 5:30 = 04:45` —
정확히 맞는다. 곧 `captured` 를 **로컬 시각으로 해석하면** 카드가 만들어진 순간이다.

카드 파일의 `birthtime` 은 쓰지 마라. 이 카드는 birthtime 이 `2026-09-06 14:15 +0530` 인데,
그것은 나중에 `target_handle` 을 적은 Edit 가 파일을 새로 써서 갱신된 값이다. 실제 생성보다
9 시간 30 분 뒤다.

`captured` 이후에 수정된 기록만 후보로 두면 실측 —

```
candidates: 143 / 3298   (155MB)
grep 1.2 초, 27 개 파일이 카드 이름을 담고 있었다
```

**1.2 초면 상세 한 번에 물릴 수 있다.** 게다가 "이 카드를 누가 썼나" 는 한 번 정해지면
안 바뀌므로 `resolved` 와 같은 방식으로 프로세스가 사는 동안 캐시한다.

## 무엇을 만드는가

### A. 백엔드 — 새 `revision` 블록 (Core/)

`Core/WorkQueueSessionStore.swift` 에 함수 하나를 새로 만든다.

```swift
static func revision(cardID: String, cardPath: String, captured: String) -> [String: Any]
```

`Core/WorkQueueStore.swift` 의 `detailJSON` 이 `payload["revision"]` 자리에 그 값을 넣는다.
`payload` 의 다른 키는 한 글자도 안 바꾼다 — 화면의 다른 절이 전부 그 위에 서 있다.

**돌려주는 모양(찾았을 때).**

```json
"revision": {
  "found": true,
  "runner": "codex",
  "model": "gpt-6-astra",
  "effort": "none",
  "tokens": 31521,
  "tokensFrom": "codex `tokens used`",
  "seconds": 58.9,
  "startedAt": "2026-09-05T23:14:54.708Z",
  "endedAt":   "2026-09-05T23:15:53.646Z",
  "file": "/Users/lioncho/.claude/projects/.../agent-a76a3488df2463e20.jsonl",
  "sessionId": "01a073da-80fa-7ab2-b8d8-5e5529240495",
  "why": "이 카드 파일을 만든 실행이다 — codex exec 출력에 카드 경로와 `요구 —` 줄이 있다."
}
```

**못 찾았을 때.** 빈칸을 돌려주지 마라. 이 화면의 규칙은 `없으면 왜 없는지를 쓴다` 이다.

```json
"revision": { "found": false, "why": "기록 143 개를 봤는데 이 카드 파일을 만든 실행이 없다. ..." }
```

**찾는 절차.**

1. `captured` 를 로컬 시각으로 파싱한다. 지원 모양 둘 — `YYYY-MM-DD-HHMM` 과 ISO8601.
   파싱 실패면 이 필터를 건너뛰고 전체를 후보로 둔다(느리지만 틀리지는 않는다).
2. `~/.claude/projects/**/*.jsonl` 중 `mtime >= captured - 120초` 인 것만 후보. **하위
   대화(`<sessionId>/subagents/*.jsonl`)를 반드시 포함한다** — 실측으로 카드를 쓴 것이
   바로 그 자리다. `launchIndex()` 는 최상위 `.jsonl` 만 담으므로 여기에 쓸 수 없다.
3. 후보를 앞에서부터 읽으며 **카드 파일 이름 또는 카드 절대경로**를 담은 레코드를 찾는다.
   문자열로 먼저 거르고 그다음에 JSON 파싱한다(`scan()` 과 같은 방식).
4. 갈래 둘.
   - **codex 갈래.** `type == "user"` 의 `tool_result` 본문에 `OpenAI Codex` 배너와 카드
     경로가 같이 있는 레코드. 배너에서 `model:` / `reasoning effort:` / `session id:` 를,
     꼬리에서 `tokens used` 다음 줄의 숫자(콤마 제거)를 뽑는다. `runner = "codex"`.
     끝 시각 = 이 레코드의 `timestamp`. 시작 시각 = 같은 `tool_use_id` 를 낸 앞쪽 assistant
     레코드의 `timestamp`.
   - **claude 갈래.** `tool_use` 가 `Write`/`Edit`/`MultiEdit` 이고 `input.file_path` 가
     카드 절대경로인 레코드. 그 assistant 레코드의 `message.model` 과 `message.usage` 를
     쓴다. `runner = "claude"`, `effort = ""`. 시작 시각 = 바로 앞 사람 턴의 `timestamp`,
     끝 시각 = 그 assistant 레코드의 `timestamp`.
5. 둘 다 걸리면 **codex 갈래를 이긴 것으로 본다.** 카드를 처음 만든 것이 codex 이고 Claude
   쪽은 나중에 `status`·`target_handle` 을 적은 Edit 다 — 라이언이 물은 것은 수정을 **만든**
   실행이지 나중에 좌표를 적은 실행이 아니다. 같은 갈래에서 여럿이면 **가장 이른 것**을
   고른다(같은 이유).
6. 카드 id 로 캐시한다. 못 찾은 것은 `missTTL` 처럼 짧게(180 초) 캐시한다 — 방금 만들어진
   카드는 곧 찾아진다.
7. **읽기만 한다.** 파일을 만들지 않고 카드에 한 글자도 쓰지 않는다.
8. 뽑아낸 기록 경로는 `remember()` 로 reveal 허용 목록에 담는다 — 화면에서 그 기록을 열
   수 있어야 하고, 담기지 않으면 DASH-13 의 팝업이 `unknown-path` 로 거절한다.

**성능 상한.** 후보 파일 전체 읽기에 상한을 둔다 — 파일당 64MB(기존 `scan()` 과 같은 값),
전체 후보가 400 개를 넘으면 최신 400 개만 본다. 넘겨서 못 찾았으면 그 사실을 `why` 에 적는다.

### B. 화면 — 섹션 2 (Dashboard/)

`Sources/ConditionMate/Dashboard/IssuesContent.swift` 의 `수정된 최초의 리퀘스트` 절만
고친다. 라벨 문자열로 찾아라. 줄 번호는 옆 창 때문에 움직인다.

**B-1. 기본 접힘 + 3 단.** 섹션 1(`ORIGOPEN` / `isOrigSet`)과 **같은 모양**을 쓴다.

- 0 단(기본) — 본문을 안 그리고 `펼치기 (요구 N자)` 버튼만. `N` 은 `toLocaleString()`.
- 1 단 — 5 줄(`.o5`), `접기` 버튼. 실제로 5 줄을 넘칠 때만 `전문 보기 (N자)` 를 보인다.
- 2 단 — 전문(`.full`), `5 줄만 보기` + `접기`.

**0 단의 `펼치기` 는 길이와 무관하게 언제나 그린다.** 라이언이 명시적으로 요구한 것이
접힘이고, 접힌 것을 여는 손잡이가 없으면 그 절이 통째로 사라진다.

**`전문 보기`(2 단) 는 실제로 넘칠 때만 그린다.** `:1242` 주석의 규칙 — "세 줄짜리 원문
밑에 붙은 죽은 [전문 보기] 는 누를 것만 늘리고 아는 것은 안 는다" — 을 그대로 따른다.
섹션 1 의 `#isOrigMore` 와 섹션 2 의 기존 `#isLeadMore` 가 이미 그린 뒤에 재는 방식을
쓰고 있다. **그 방식을 재발명하지 말고 그대로 쓴다.**

`isRawExcerpt` 일 때의 `.rawtag` 경고 줄은 **접힘 단계와 무관하게 항상 보인다.** 그것은
읽을 거리가 아니라 이 카드가 정리 안 됐다는 상태 표시다.

**B-2. 실행 정보 한 줄.** 섹션 2 제목 바로 밑, **접힌 상태에서도 보이는 자리**에 놓는다.
그것이 이 값의 목적이다 — 펼치지 않고도 이 수정을 누가 얼마에 만들었는지 안다.

찾았을 때 (예시 그대로):

```
gpt-6-astra · effort none · 31,521 토큰 · 59.0 초
```

- `effort` 가 빈 값이면 그 조각을 통째로 뺀다. `effort ` 만 남기지 마라.
- 토큰은 `toLocaleString()`. 어느 필드에서 온 값인지는 이 줄의 `title` 속성에
  `tokensFrom` 을 그대로 넣어 마우스로 확인되게 한다.
- 기록으로 가는 길은 **새로 만들지 말고** 이미 있는 것을 쓴다 — `sesHead` 가 쓰는
  `isTr*` 팝업과 같은 통로에 `revision.file` 을 넘긴다.

못 찾았을 때:

```
이 수정을 만든 실행을 못 찾았다 — <why>
```

`<why>` 를 자르지 마라. 빈 줄로 두지 마라.

**B-3. 데이터 계약 방어.** `DET.revision` 이 없어도(옛 응답, 백엔드가 아직 안 붙은 순간)
화면이 깨지면 안 된다. `var rv = DET.revision || {}` 로 받고 `rv.found` 가 참일 때만 값
줄을 그린다. `found` 가 거짓이고 `why` 도 없으면 이 줄을 아예 안 그린다.

## 이번에 하지 않는 것

- 섹션 1 을 건드리지 않는다. 이미 라이언이 원하는 모양이다.
- 목록(`GET /api/issues`)에 `revision` 을 붙이지 않는다. 카드 109 장마다 기록을 훑게 되고,
  그것이 DASH-12 가 이미 거절한 설계다. 상세를 열었을 때만 붙는다.
- 카드 파일과 큐 폴더에 쓰지 않는다. 로그 파일도 캐시 파일도 만들지 않는다.
- `IssuesContent.swift` 를 다시 쓰지 않는다. 되돌리기와 전면 재작성은 금지다.
- 옆 창이 만지는 파일(`.e2e/run.js`, `.e2e/screens.test.js`, `.e2e/timezone.test.js`,
  `.e2e/issues.test.js`)을 되돌리거나 `git checkout` 하지 않는다.

## SPEC — 새 항목 DASH-14

`docs/specs/SPEC.md` 의 DASH-13 바로 뒤에 새 항목을 넣는다. 기존 항목은 안 고친다.

```
- **DASH-14 — 수정된 최초의 리퀘스트는 기본 접힘이고, 그것을 만든 실행 정보를 같이 보인다.**
  KO: 이슈 상세의 `수정된 최초의 리퀘스트` 절은 섹션 1 과 같은 3 단이다 — 0 단(접힘, `펼치기
  (요구 N자)`) · 1 단(5 줄) · 2 단(전문). 0 단의 `펼치기` 는 길이와 무관하게 언제나 그리고,
  2 단의 `전문 보기` 는 그린 뒤에 재서 실제로 5 줄을 넘칠 때만 그린다(죽은 손잡이 금지).
  절 제목 밑에는 **접힌 상태에서도 보이는** 실행 정보 한 줄이 선다 — 그 `요구` 줄을 만든
  실행의 모델 · effort · 토큰 · 걸린 초. 값의 출처는 **이미 있는 세션 기록**이고 새 로그
  파일을 만들지 않는다. codex 실행은 tool_result 안의 Codex 배너(`model:` ·
  `reasoning effort:` · `tokens used`)에서, Claude 실행은 `message.model` 과 `message.usage`
  에서 읽는다. 찾는 대상은 **카드를 쓴 실행**이지 카드를 받은 세션(DASH-12)이 아니다 —
  둘은 다른 기록이다. 후보는 카드 `captured`(로컬 시각) 이후에 수정된 기록으로 좁히고
  하위 대화(`subagents/*.jsonl`)를 포함한다. 못 찾으면 빈칸이 아니라 왜 못 찾았는지를 쓴다.
  카드 파일과 큐 폴더에는 한 바이트도 쓰지 않는다.
  EN: The `수정된 최초의 리퀘스트` pane collapses by default with the same three-stage control as
  the origin pane, and carries a one-line run-provenance row that stays visible while collapsed:
  the model, reasoning effort, token count and elapsed seconds of the run that produced that line.
  All four are read from existing transcripts — no new log file. Codex runs are read from the
  banner inside the Bash tool_result; Claude runs from `message.model` / `message.usage`. The
  target is the run that WROTE the card, not the session that RECEIVED it (DASH-12) — different
  records. A miss states its reason.
  Mechanism: `Core/WorkQueueSessionStore.swift` (`revision(cardID:cardPath:captured:)`),
  `Core/WorkQueueStore.swift` (`detailJSON` 의 `revision` 블록),
  `Dashboard/IssuesContent.swift` (섹션 2 의 3 단 · 실행 정보 줄).
  Why: 2026-09-06. 라이언 — "그 수정한 내용이 기본적으로 접혀있고 그걸 전문으로 볼 수 있게
  해줘요 그리고 그거를 어떤 AI 모델이 그리고 얼마나 앱폭트를 써서 몇 초 걸려서 했는지도
  알려줘요 / 그게 세션에 이게 나와 있지 않나 따로 파일을 만들 필요 없을 것 같은데."
  `앱폭트` 는 `effort` 로 확정했다 — 기록에 `reasoning effort:` 필드가 그 이름 그대로 있고,
  이 카드를 쓴 Codex 실행 자신이 그 낱말을 `에포트` 로 옮겨 적었다.
  Verified: <워커가 실측으로 채운다>
```

## 완성 — 이것이 되면 끝이다

1. `swift build -c release` 통과.
2. 카드 `d7a0211b-3ee8-4a5e-a172-400cb674b595` 상세에서 섹션 2 가 **접힌 채로** 뜨고,
   `펼치기 (요구 N자)` → 5 줄 → (넘치면) 전문 → 접기 가 전부 돈다.
3. 같은 화면에서 실행 정보 줄이 `gpt-6-astra · effort none · 31,521 토큰 · 58.9 초`
   (초는 소수 첫째 자리까지, 반올림 차이는 허용) 로 뜬다. **이 값이 위 조사와 다르면
   구현이 틀린 것이다.**
4. `revision` 을 못 찾는 카드에서 빈칸이 아니라 이유 문장이 뜬다.
5. `.e2e/issues.test.js` 가 이번 변경 때문에 깨지지 않는다.
6. `git status --short` 에 **새로 생긴 파일이 없다** — 이 지시서와 커밋을 빼고.
7. SPEC 에 DASH-14 가 서 있고 `Verified:` 가 실측으로 채워져 있다.

## 1초 요약

요구 — 그 수정한 내용이 기본적으로 접혀있고 전문으로 볼 수 있게 하고, 어떤 AI 모델이 얼마나 앱폭트를 써서 몇 초 걸려서 했는지도 알려줘요.
문제 — 섹션 2 의 값은 앱이 만든 것이 아니라 카드의 `요구` 줄이므로, 물어야 할 것은 카드를 받은 세션(이미 붙어 있다)이 아니라 카드를 쓴 실행이고, 그 실행의 모델·effort·토큰·초는 codex 배너와 Claude `usage` 로 이미 기록에 있어 새 파일 없이 읽어 오면 된다.
완성 — 섹션 2 가 접힌 채 뜨고 3 단으로 펼쳐지며, 그 위에 `gpt-6-astra · effort none · 31,521 토큰 · 58.9 초` 가 접힌 상태에서도 보이고, 새 파일은 하나도 안 생겼다.
