# 작업지시서 — 세션 줄에서 그 세션의 기록과 폴더로 간다

- 카드 id: `dd4b8c12-b8e5-42c6-b18e-813b7f6328a8`
- 카드 파일: `/Users/lioncho/Work/lion_work/organization/lion/lion-work-queue/inbox/2026-09-06-1314-conditionmate-session-file-folder-open.md`
- 트랙: BEST · 규모: P2 · 레벨: L1 (사람에게 묻지 않는다)
- 쓴 자리: `lion-condition-mate` PO

## 원문 (라이언이 말한 그대로. 요약하지 않았다)

```
컨디션 에이전트 컨딘션메이트 관련된 거
디렉터 에젠티를 위임하고
지금 사진을 보면은 그 앞에 97cc 3cc2 있잖아요 세션인데 누르면은 그 파일이 열리게끔 그래서 내용을 볼 수 있게끔 그리고 오른쪽에 있는 곳은 거기다가 이제 파일 열기 폴더 열기를 해갖고 누르게 되면 그 해당 세션이 곧 폴터를 열어서
```

원문 마지막 문장이 끊겨 있다. 아래 `## 끊긴 문장을 무엇으로 완성했는가` 에서 정했다.

## 화면 컨텍스트

라이언이 붙인 스크린샷은 `/issues` 의 goal 상세다. `작업지시서` 절과 `결과물` 절 안에
파란 글씨 한 줄이 서 있다 —

```
세션 97cc3cc2 · 2026-09-06 07:31 · 사람 말 1 번 · 쓴 파일 1 개
```

라이언이 `97cc3cc2` 에 동그라미를 치고, 그 줄 **오른쪽 빈 공간**에 네모를 그렸다.
동그라미는 "눌러서 내용을 보게 해라", 네모는 "여기에 버튼 둘을 둬라" 는 뜻이다.

그 줄을 그리는 코드가 `Sources/ConditionMate/Dashboard/IssuesContent.swift:612-620`
의 `sesHead(S)` 다. 지금은 글자만 있고 누를 것이 하나도 없다.

## 지금 무엇이 있는가 (실측)

읽은 것과 근거를 그대로 적는다. 추측이 아니다.

**세션 기록은 실재한다.** 화면의 그 세션은 디스크에 있다 —
`/Users/lioncho/.claude/projects/-Users-lioncho-Work-lion-work-organization-globalmpc-workspace-globalmpc-legal/97cc3cc2-5041-46b5-a02c-9dca62b6707f.jsonl`
796KB · 124 줄. 레코드 종류는 `user` 9 · `assistant` 17 · `attachment` 38 · 그 밖의
하네스 레코드다. **모든 `user`/`assistant` 레코드에 `cwd` 필드가 있고** 이 세션의 값은
`/Users/lioncho/Work/lion_work/organization/globalmpc/workspace/globalmpc-legal` 하나뿐이다.

이것이 중요하다. `projectDir` 이름(`-Users-lioncho-Work-…`)에서 작업 폴더를 되돌리는 것은
**불가능하다** — `WorkQueueSessionStore.projectDirName` 이 `/` 와 `_` 와 `.` 을 전부 `-` 로
바꾸므로 역변환이 한 값으로 안 정해진다. 그러니 되돌리려 하지 말고 **기록 안의 `cwd` 를
그대로 읽어라.** 그것이 손실 없는 유일한 경로다.

**앱은 이미 그 기록 파일 경로를 들고 있다.** `WorkQueueSessionStore.scan()`
(`Core/WorkQueueSessionStore.swift:333-427`) 이 돌려주는 딕셔너리에 `file`(jsonl 절대경로),
`sessionId`, `projectDir`, `startedAt`, `lastAt`, `userTurns`, `writeCount` 가 이미 있다.
화면의 `S` 가 곧 이것이다. **새로 찾을 것이 없다. 이미 있는 것을 안 쓰고 있을 뿐이다.**

**Finder 열기 통로도 이미 있다.** `POST /api/issues/reveal` →
`AppDelegate.revealWorkQueuePath` (`AppDelegate.swift:6230-6243`). 허용 목록 대조를 하고,
목록 밖은 `unknown-path` 로 거절한다. 목록은 `WorkQueueStore.knownRevealPaths()`
(`Core/WorkQueueStore.swift:1029-1060`) 이고 그 첫 줄이
`WorkQueueSessionStore.revealAllowlist()` 와의 합집합이다.

**그런데 지금 그 목록에 기록 파일 자신이 안 들어 있다.** `remember()` 를 부르는 자리가
`pathsIn()` 하나이고(`WorkQueueSessionStore.swift:288-296`), 그것은 `directiveFiles` 와
`outputFiles` 만 훑는다. 그래서 지금 상태로 `S.file` 을 reveal 에 넘기면 **`unknown-path`
로 거절된다.** 이것이 이 일에서 반드시 고쳐야 하는 한 자리다.

**md 팝업이 본보기다.** `.md` 를 앱 안에서 열어 보는 팝업이 이미 있다 —
markup `IssuesContent.swift:315-329`, JS `window.isMd` `IssuesContent.swift:750-779`,
서버 `GET /api/issues/mdfile` → `AppDelegate.workQueueMarkdownRead:6272-6287`,
경로 검증 `workQueueMarkdownPath:6263-6270`. 렌더러(`mdRender`/`mdInline`
`IssuesContent.swift:686-735`)도 인라인으로 직접 짜여 있다 — **외부 CDN 을 끌어오지 않는
것이 이 앱의 설계 원칙**이므로 이번에도 라이브러리를 넣지 마라.

세션 기록은 `.md` 가 아니라 `.jsonl` 이라 `workQueueMarkdownPath` 를 통과하지 못한다
(`hasSuffix(".md")` 로 막는다). 그러니 md 팝업을 재사용하지 말고 **읽기 전용 팝업을 따로**
둔다. 이유는 아래 `## 왜 md 팝업을 재사용하지 않는가` 에 있다.

## 끊긴 문장을 무엇으로 완성했는가

원문은 "누르게 되면 그 해당 세션이 곧 폴터를 열어서" 에서 끊긴다. 두 갈래가 있었다.

**갈래 A — 폴더 열기 = 기록 파일이 든 폴더(`~/.claude/projects/<이름>/`).**
**갈래 B — 폴더 열기 = 그 세션이 일한 작업 폴더(`cwd`).**

**B 로 정했다.** 근거 둘이다.

하나. macOS 의 `activateFileViewerSelecting(파일)` 은 그 파일이 든 폴더를 열고 파일을
선택해 준다. 그러니 A 를 택하면 `[파일 열기]` 와 `[폴더 열기]` 가 **화면에서 사실상 같은
동작**이 된다. 라이언이 버튼 둘을 그린 것은 둘이 다른 일을 하기 때문이다.

둘. 그 세션이 무엇을 만들었는지는 기록 폴더가 아니라 작업 폴더에 있다. 화면 상단 경로
배지가 이미 `/Users/lioncho/Work/lion_work/organization/globalmpc/workspace/globalmpc-legal`
를 보여 주고 있고, 라이언이 세션 줄에서 가고 싶은 자리도 거기다.

그래서 이렇게 완성한다 — **"…누르게 되면 그 해당 세션이 곧 [일했던] 폴더를 열어서 [그
세션이 만든 것을 보게 한다]."**

`cwd` 를 기록에서 못 읽었을 때만 A 로 떨어진다(폴백). 그때는 버튼 툴팁에 무엇을 여는지
그대로 적어라. 조용히 다른 것을 열지 마라.

## 무엇을 만드는가

세 조각이다. 셋 다 해야 완성이다.

### 1. 세션 기록 경로와 작업 폴더를 데이터에 실어 보낸다

`Sources/ConditionMate/Core/WorkQueueSessionStore.swift`

- `scan()` 이 훑는 동안 `user`/`assistant` 레코드의 `cwd` 문자열을 **처음 나온 것 하나만**
  잡아 둔다. 여러 개면 첫 것을 쓴다(실측 이 세션은 하나뿐이다). 못 잡으면 빈 문자열.
- 돌려주는 딕셔너리에 `"cwd"` 를 추가한다. `"file"` 은 이미 있으니 그대로 둔다.
- `pathsIn()` 이 `directiveFiles`/`outputFiles` 에 더해 **`file` 과 `cwd` 도 담게** 한다.
  그래야 `revealAllowlist()` 를 통과해 `/api/issues/reveal` 이 그 둘을 연다.
  `cwd` 는 폴더라 존재 확인만 하고 담는다.
- 캐시된 값(`cache[h.path]`)을 그대로 돌려주는 갈래에서도 `remember(pathsIn(...))` 이
  이미 불린다(`session()` 안 `if let c = cached` 갈래). 새 키가 `pathsIn` 에 들어가면
  그 갈래도 저절로 맞는다 — 따로 손대지 마라.

### 2. 기록을 읽어 사람이 읽는 모양으로 돌려주는 엔드포인트

`Sources/ConditionMate/AppDelegate.swift`

- 경로 검증 함수 하나를 새로 둔다. 이름은 `workQueueTranscriptPath(_:) -> String?`.
  통과 조건 다섯 — (1) 절대경로 (2) `..` 없음 (3) `.jsonl` 로 끝남
  (4) `~/.claude/projects/` 아래 (5) `WorkQueueSessionStore.revealAllowlist()` 안.
  마지막으로 디스크에 **파일로** 실재하는지 본다.
  `workQueueMarkdownPath` 와 같은 모양으로 쓰고, 그 함수를 고치지는 마라.
- `GET /api/issues/transcript?path=…` 를 추가한다. 라우팅은 `AppDelegate.swift:176` 의
  `mdfile` 갈래 **바로 옆**에 둔다 — `/api/issues/<id>` 상세 갈래보다 **반드시 먼저** 서야
  한다. 뒤에 두면 `transcript` 라는 이름의 카드를 찾다가 `unknown-card` 가 온다.
  그 자리 주석에 이미 그 이유가 적혀 있다.
- 응답은 **원본 JSONL 이 아니라 정리한 턴 배열**이다.
  `{"ok":true,"path":…,"sessionId":…,"cwd":…,"turns":[{"role":"user|assistant","at":"…","text":"…","files":["…"]}],"total":N,"shown":M,"truncated":bool}`
  - `role` 은 `user` 와 `assistant` 둘만. `isMeta:true` 와
    `WorkQueueSessionStore.isSystemInjected` 가 잡는 하네스 주입은 뺀다 — 그 판정 규칙은
    이미 그 파일에 있으니 같은 규칙을 쓰되, 필요하면 그 함수를 `internal` 로 열어
    **한 벌만** 두어라. 두 벌을 만들지 마라.
  - `assistant` 의 `tool_use` 중 `Write`/`Edit`/`MultiEdit`/`NotebookEdit` 의 `file_path`
    만 그 턴의 `files` 에 담는다. 그 밖의 툴 호출은 담지 않는다.
  - 상한 — 턴은 **뒤에서부터 400 개**(오래된 것을 자른다. 라이언이 보고 싶은 것은 그
    세션이 무엇을 했나이고 그것은 뒤에 있다), 턴 하나의 `text` 는 4,000 자,
    응답 전체는 2MB. 자른 것이 있으면 `truncated:true` 와 `total`/`shown` 으로 말한다.
    **조용히 자르지 마라** — 이 화면의 규칙이 "없으면 없다고 쓴다" 이다.
  - 파일 자체가 2MB 를 넘어도 읽는다. md 리더처럼 통째로 거절하면 15MB 짜리 세션에서
    이 기능이 통째로 안 도는데, 그런 세션이야말로 라이언이 보고 싶어 하는 것이다.
    `Data(contentsOf:options:[.mappedIfSafe])` 로 열고 `scan()` 과 같은 64MB 상한을 쓴다.

### 3. 화면 — 세션 줄을 누를 수 있게 만든다

`Sources/ConditionMate/Dashboard/IssuesContent.swift`

- `sesHead(S)` 를 고친다. 지금은 문자열 한 줄이다. 바꾼 뒤 모양 —
  - 세션 ID 8 자를 `<a class="sesid" …>` 로 감싸고 누르면 기록 팝업을 연다.
    경로는 **JS 문자열 리터럴에 넣지 말고 `data-p` 속성으로** 넘겨라. `artRow` 의
    `mdlink` 가 이미 그 규칙을 쓰고 그 이유가 주석에 적혀 있다(따옴표가 든 경로 하나에
    `onclick` 이 통째로 깨진다).
  - 줄의 **오른쪽 끝**에 버튼 둘을 둔다 — `[파일 열기]` 와 `[폴더 열기]`.
    `.sh` 를 `display:flex; align-items:baseline; gap:8px` 로 만들고 버튼 묶음에
    `margin-left:auto` 를 준다. 라이언이 네모를 그린 자리가 거기다.
  - `[파일 열기]` → `isReveal(this, S.file)`.
  - `[폴더 열기]` → `isReveal(this, S.cwd || S.projectDir)`.
    `S.cwd` 가 비어 폴백으로 떨어지면 버튼 `title` 에 무엇을 여는지 적어라.
  - `S.file` 이 비면 그 버튼과 링크를 **아예 그리지 마라.** 눌러도 아무 일이 안 나는
    버튼이 죽은 버튼보다 나쁘다 — 이 파일이 이미 지키는 규칙이다.
- 읽기 전용 기록 팝업을 새로 둔다. markup id 는 `isTrWrap`/`isTrBox`/`isTrPath`/
  `isTrBody`/`isTrFoot`, JS 는 `window.isTr(el)` 과 `window.isTrClose()`.
  - CSS 는 `.mdw`/`.mdbox`/`.mdh`/`.mdbody`/`.mdfoot` 을 **그대로 재사용**한다. 새 클래스는
    턴 렌더에 필요한 것만 만든다(`.turn`, `.turn.u`, `.turn.a`, `.turn .who`, `.turn .fs`).
  - 사람 턴과 모델 턴을 **눈에서 갈라라** — 왼쪽 색 줄이면 충분하다. 사람 `#7db0ff`,
    모델 `#8a93a3`. 이 화면이 이미 쓰는 색이다.
  - 각 턴에 시각(`YYYY-MM-DD HH:MM`)과, `files` 가 있으면 그 경로들을 작게 붙인다.
  - 머리에 경로와 `사람 말 N 번 · 쓴 파일 M 개 · 턴 M/N` 을 적고 버튼은 `[닫기]` 하나다.
  - `truncated` 면 맨 위에 "앞의 N 턴은 안 실었다" 를 한 줄로 쓴다.
  - `Escape` 로 닫힌다. md 팝업의 키 핸들러(`IssuesContent.swift:818-830`)가 이미
    `Escape` 를 먹고 있으니, **기록 팝업이 열려 있으면 그것을 먼저 닫도록** 순서를 정해라.
    둘이 동시에 열릴 일은 없지만 키 하나가 두 팝업을 건드리게 두지 마라.
  - **모든 문자열을 `esc()` 로 통과시켜라.** 여기는 `innerHTML` 싱크이고 기록 안에는
    사람이 붙여 넣은 HTML 이 얼마든지 들어 있다. 마크다운 렌더를 하지 마라 — 기록은
    md 가 아니고, 렌더하면 그것이 곧 XSS 다.

### 4. 폴더를 열면 폴더가 열려야 한다

`AppDelegate.revealWorkQueuePath` 는 지금 파일이든 폴더든 `activateFileViewerSelecting`
을 부른다. 폴더에 그것을 부르면 **그 폴더가 열리는 게 아니라 부모에서 그 폴더가 선택된다.**
라이언이 앞서 이 버튼에 대고 한 말이 "그 폴더를 볼 수 있도록" 이었다(그 인용이
`AppDelegate.swift:6222` 주석에 있다). 지금 동작은 그 말과 다르다.

그러니 그 함수에서 대상이 **폴더면 `NSWorkspace.shared.open(url)`**, 파일이면 지금대로
`activateFileViewerSelecting` 을 쓰게 갈라라. 허용 목록 검사는 그대로 둔다 — **거기는 한
글자도 느슨하게 하지 마라.**

## 이번에 하지 않는 것

- 단계 배지(`요청만`/`작업지시서까지`/`결과물까지`)를 안 바꾼다. 그것은 카드 109 장을 한 번에
  세는 값이고, 세션까지 훑으면 목록이 선다. DASH-12 가 이미 그렇게 정해 두었다.
- 큐 폴더와 카드 파일에 **한 바이트도 쓰지 않는다.**
- 기록을 고치는 기능을 만들지 않는다. 이 팝업은 읽기 전용이다.
- 원본 JSONL 을 그대로 화면에 붓지 않는다.
- 외부 라이브러리를 넣지 않는다.
- 목록 화면(`/issues` 왼쪽)은 손대지 않는다. 이 일은 상세 우측 패널 안에서 끝난다.

## 보안 — 이 통로가 무엇을 여는가

새 엔드포인트는 **사람의 대화 기록 전문을 루프백으로 내보내는 첫 자리**다. 그래서 경계를
`~/.claude/projects/` 아래로 자르는 것만으로는 부족하고, **허용 목록 안**까지 같이 요구한다.
허용 목록에는 라이언이 상세를 실제로 연 카드의 세션만 들어간다. 상세를 열기 전에는 아무것도
못 연다는 뜻이고, 그것이 실제 조작 순서와 같다.

`/etc/hosts`, `~/.ssh/id_rsa`, `~/.claude/projects/../../.zsh_history` 셋이 전부
`unknown-path` 로 거절되는 것을 **직접 확인해서** 보고에 적어라.

## 왜 md 팝업을 재사용하지 않는가

md 팝업에는 `[에디터]` 와 `[저장]` 이 있고 그 저장은 `POST /api/issues/mdsave` 로 디스크에
실제로 쓴다. 세션 기록은 하네스가 쓰는 append-only 파일이라 사람이 고치면 안 된다. 저장
버튼을 숨기는 것으로 막으면, 막는 것이 화면 상태 하나가 되고 그 상태가 언젠가 깨진다.
**팝업을 갈라 두면 저장 경로가 애초에 없다.** 그래서 CSS 는 나누지 않고 동작만 나눈다.

## 완성 조건 (이것으로 판정한다)

1. `/issues` 에서 세션이 붙은 카드를 열면, 세션 줄의 ID 8 자가 링크로 보이고 누르면
   팝업이 뜨며 그 세션의 사람 말과 모델 답이 시간 순으로 보인다.
2. 같은 줄 오른쪽 끝에 `[파일 열기]` `[폴더 열기]` 가 있다.
3. `[파일 열기]` 를 누르면 Finder 가 그 `.jsonl` 을 선택한 채 뜬다.
4. `[폴더 열기]` 를 누르면 Finder 가 그 세션의 **작업 폴더**를 열어 안이 보인다.
5. 허용 목록 밖 경로 셋이 `unknown-path` 로 거절된다.
6. `swift build` 가 통과한다.
7. `.e2e/issues.test.js` 가 통과한다. 위 1~5 를 지키는 검사를 그 파일에 더한다 —
   소스 문자열 검사라 빌드 없이 돈다.

## SPEC 편집 (반드시 같이 한다)

`docs/specs/SPEC.md` 에 항목 하나를 새로 넣는다. 자리는 **DASH-12 블록 바로 뒤**다.

```
- **DASH-13 — 세션 줄에서 그 세션의 기록과 작업 폴더로 한 번에 간다.**
  KO: 이슈 상세의 세션 줄(`sesHead`)에서 세션 ID 를 누르면 그 세션의 기록
  (`~/.claude/projects/<폴더>/<sessionId>.jsonl`)을 **읽기 전용 팝업**으로 열어 사람 말과 모델
  답을 시간 순으로 보인다. 같은 줄 오른쪽에 `[파일 열기]`(그 기록 파일을 Finder 에서 선택)와
  `[폴더 열기]`(그 세션이 **일한 작업 폴더**를 Finder 에서 연다)가 선다. 작업 폴더는 기록
  폴더 이름에서 되돌리지 않고 **기록 안의 `cwd` 필드를 읽는다** — `projectDirName` 이 `/`·`_`·`.`
  을 전부 `-` 로 바꾸므로 역변환이 한 값으로 안 정해진다. 팝업은 고칠 수 없다. 기록은 하네스가
  쓰는 append-only 파일이라 저장 경로를 애초에 두지 않는다(md 팝업과 갈라 둔 이유가 이것이다).
  턴은 뒤에서부터 400 개·턴당 4,000 자·전체 2MB 로 자르고, 자른 것이 있으면 화면이 그렇게 말한다.
  `GET /api/issues/transcript` 는 절대경로 · `..` 없음 · `.jsonl` · `~/.claude/projects/` 아래 ·
  **`WorkQueueSessionStore.revealAllowlist()` 안** 다섯을 다 통과할 때만 연다. 상세를 연 카드의
  세션만 목록에 들어가므로, 상세를 열기 전에는 아무것도 못 연다.
  `revealWorkQueuePath` 는 대상이 폴더면 `NSWorkspace.open`(안이 보인다), 파일이면
  `activateFileViewerSelecting`(부모에서 선택)으로 갈린다 — 앞선 판은 폴더에도 후자를 불러
  `폴더 열기` 가 폴더를 열지 않았다.
  EN: The session line in the issue detail becomes actionable: the id opens a read-only
  transcript popup, and two buttons reveal the transcript file and open the session's working
  directory. The working directory is read from the transcript's `cwd` field, never decoded from
  the project-dir name. Transcript reads require the path to be in the reveal allowlist.
  Mechanism: `Core/WorkQueueSessionStore.swift` (`cwd` 수집 · `pathsIn` 에 `file`/`cwd` 추가),
  `AppDelegate.swift` (`workQueueTranscriptPath` · `GET /api/issues/transcript` ·
  `revealWorkQueuePath` 의 폴더 갈래), `Dashboard/IssuesContent.swift`
  (`sesHead` 의 링크·버튼 · `isTr*` 팝업).
  Why: 2026-09-06. 라이언이 상세 스크린샷의 `세션 97cc3cc2` 에 동그라미를 치고 그 줄 오른쪽에
  네모를 그렸다 — "누르면은 그 파일이 열리게끔 그래서 내용을 볼 수 있게끔 … 파일 열기 폴더 열기".
  DASH-12 가 세션에서 지시서와 결과물을 끌어왔지만, 그 **세션 자체**로 가는 길은 없어서 라이언이
  기록을 보려면 창을 따로 열어야 했다. 그 창을 없애는 것이 이 화면의 유일한 목적이다.
  ASSUMPTION (L1): 원문 마지막 문장이 "그 해당 세션이 곧 폴터를 열어서" 에서 끊겼다. `폴더 열기`
  를 **작업 폴더**로 정했다 — 기록 파일을 reveal 하면 기록 폴더는 이미 열리므로, 기록 폴더로
  잡으면 버튼 둘이 같은 일을 한다. 라이언에게 되묻지 않고 이렇게 정했다.
  Verified: <워커가 실측으로 채운다>
```

DASH-12 블록의 `Mechanism:` 줄 끝에 한 문장을 덧붙인다 —
`세션 줄에서 기록·폴더로 가는 길은 DASH-13 이다.`

## 어떻게 검증하는가

- `swift build` — 통과해야 한다. 이것이 이 항목의 하드 게이트다.
- `cd .e2e && node issues.test.js` — 전부 PASS.
- 격리 인스턴스로 실제 화면을 확인한다.
  `CM_DATA_DIR=/tmp/cm-dash13 .build/debug/ConditionMate` 로 띄우고
  `curl 'http://127.0.0.1:<port>/api/issues/<카드키>'` 로 `session.cwd` 와 `session.file` 이
  실려 오는지 보고, `curl 'http://127.0.0.1:<port>/api/issues/transcript?path=…'` 로 턴이
  오는지 본다. 포트와 기동 방법은 `lion-condition-mate-worker-qa` 플레이북에 있다.
- 거절 확인 셋(`/etc/hosts`, `~/.ssh/id_rsa`, `..` 이 든 경로)을 실제로 쳐 보고 응답을 적어라.

## 1초 요약

요구 — 세션 `97cc3cc2` 를 누르면 그 파일이 열려 내용을 볼 수 있게, 그리고 그 줄 오른쪽에 파일 열기·폴더 열기를 둬서 누르면 그 세션의 폴더가 열리게.
문제 — 앱은 이미 그 세션의 기록 경로를 손에 들고 있는데(`scan()` 의 `file`) 화면에 안 내보내고 있고, 허용 목록에도 안 담겨 있어 지금 넘기면 `unknown-path` 로 거절된다. 그래서 이것은 새 기능이 아니라 **이미 있는 값을 화면까지 잇는 일**이고, 그 과정에서 정해야 할 것 하나가 "폴더 열기가 여는 폴더가 기록 폴더인가 작업 폴더인가" 다 — 기록 폴더로 잡으면 버튼 둘이 같은 일을 해서 라이언이 버튼을 둘 그린 이유가 사라진다.
완성 — 세션 ID 를 눌러 기록이 팝업으로 보이고, 같은 줄의 `[파일 열기]` 가 `.jsonl` 을 Finder 에서 선택하고 `[폴더 열기]` 가 그 세션의 작업 폴더를 열며, 허용 목록 밖 경로 셋이 거절되고, `swift build` 와 `.e2e/issues.test.js` 가 통과한다.
