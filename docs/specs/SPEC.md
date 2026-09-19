# Condition Mate — SPEC (per-page, bilingual)

EN: Source of truth for **lion-condition-mate-worker-qa** regression testing, owned by lion-condition-mate-worker-qa. Organized **per page/screen** (not per category) so a broken page is obvious at a glance. Base format = this Markdown file. `SPEC.html` is a generated, human-friendly render of the same content — regenerate it in the same change whenever this file changes.
KO: **lion-condition-mate-worker-qa** 회귀 테스트의 기준 문서이며 lion-condition-mate-worker-qa가 소유·관리한다. 카테고리가 아니라 **페이지/화면별**로 정리해 깨진 페이지가 한눈에 보이게 한다. 기준 포맷은 이 Markdown 파일이고, `SPEC.html`은 같은 내용을 사람이 보기 좋게 만든 생성물이다 — 이 파일이 바뀌면 같은 작업에서 다시 생성한다.

> **Docs hub / 문서 허브.** `SPEC.html` is now a small GitBook-style hub with top tabs. The **Spec** tab renders this file; the **Product Soul** tab renders `SOUL.md` (why the product exists, what problem it solves). When regenerating `SPEC.html`, preserve the tab shell and both panels — do not drop the Soul tab. / `SPEC.html`은 이제 상단 탭이 있는 깃북식 허브다. **Spec** 탭 = 이 파일, **제품 소울** 탭 = `SOUL.md`(존재 이유·푸는 문제). 재생성 시 탭 셸과 두 패널을 보존하고 Soul 탭을 떨어뜨리지 않는다.

## Standing rules (unchanged across reorganizations)

- **Regression rule / 회귀 규칙.**
  EN: If a test fails an item here, it is a **REGRESSION** ("되던 게 안 됨") — something that worked broke. Report it as such, per page.
  KO: 여기 있는 항목이 테스트에서 실패하면 그것은 **회귀(REGRESSION)** — 되던 게 깨진 것이다. 페이지별로 그렇게 보고한다.
- **Spec moves with code / 스펙은 코드와 함께 움직인다.**
  EN: When a behavior INTENTIONALLY changes, update THIS file (the page it lives on) in the same change, and append a line to `agent-update-log.jsonl`.
  KO: 동작이 의도적으로 바뀌면 같은 작업에서 이 파일(해당 동작이 있는 페이지)을 갱신하고, `agent-update-log.jsonl`에 한 줄을 덧붙인다.
- **Ask, don't guess / 추측하지 말고 질문하라.**
  EN: If a behavior's expected result is not pinned here and could reasonably go two ways, do not invent an expectation and test against it — surface it under OPEN QUESTIONS and ask the user.
  KO: 기대 결과가 여기에 고정돼 있지 않고 두 갈래로 갈릴 수 있으면, 기대를 지어내 검증하지 말고 OPEN QUESTIONS에 올려 사용자에게 물어라.
- **Verification / 검증 방법.**
  EN: Verification uses `<CM_DATA_DIR>/app.log` (KST timestamps, `Core/AppLog.swift`) and isolated bundle instances with a **unique** bundle id + `CM_QUIT_AFTER`. See the lion-condition-mate-worker-qa agent playbook.
  KO: 검증은 `<CM_DATA_DIR>/app.log`(KST 타임스탬프, `Core/AppLog.swift`)와, **유니크한** 번들 id + `CM_QUIT_AFTER`를 사용하는 격리 번들 인스턴스로 수행한다. lion-condition-mate-worker-qa 플레이북을 참고하라.

## Page index

| Page | id prefix | Source |
|---|---|---|
| P1. Menu-bar widget (status item + menu) | `WIDGET-` | `GUI/MenuController.swift` (+ `ConditionMate/UI/GUIBridge.swift`) |
| P2. App window lifecycle (shared across both modes) | `WINLIFE-` | `GUI/AppWindowController.swift`, `AppDelegate.swift` |
| P3. App window — BGM mode / 액티비티 sub-tab | `BGMACT-` | `Dashboard/BGMPlayerContent.swift` |
| P4. App window — BGM mode / 디버그 sub-tab | `BGMDBG-` | `Dashboard/BGMPlayerContent.swift` |
| P5. App window — 대시보드 mode | `DASH-` | `Dashboard/DashboardContent.swift` |
| P6. Server / endpoints | `EP-` | `AppDelegate.swift` (handlePost/apiGet/file), `Dashboard/DashboardServer.swift` |
| P7. Cross-cutting: logging | `LOG-` | `Core/AppLog.swift` |
| P8. App window — 루프 엔지니어링 페이지 | `LOOP-` | `Dashboard/LoopEngineeringContent.swift`, `Core/LoopScan.swift`, `Core/LoopHistory.swift`, `AppDelegate.loopEngineeringJSON()` |
| P9. App window — Slack 번역 페이지 / 상태축 | `SLKST-` | `Plugins/Slack/SlackTranslateContent.swift`, `Plugins/Slack/Daemon/slack-eyes-daemon.mjs`, `Scripts/slack-backlog-close.mjs` |

## Old id -> new id remap

| Old id | New id | Page | Note |
|---|---|---|---|
| L1 | WINLIFE-1 | P2 | unchanged behavior |
| L2 | WINLIFE-2 | P2 | unchanged behavior |
| Q1 | WINLIFE-4 | P2 | now explicitly covers BOTH modes (dashboard mode close verified too, not just bgm) |
| Q2 | WINLIFE-5 | P2 | unchanged behavior |
| Q3 | BGMACT-4 | P3 | disconnect auto-stop is a BGM-page (webview) behavior, moved off the lifecycle page |
| A1 | WINLIFE-3 | P2 | audio ownership is a window-lifecycle property (open state), not a BGM-page property; the "third source" sub-clause is RETIRED (see Intent audit P5) |
| G1 | LOG-1 | P7 | unchanged |
| G2 | LOG-2 | P7 | unchanged |
| E1 | EP-1..EP-5 | P6 | split into one id per endpoint group for finer-grained PASS/FAIL |

---

## P1. Menu-bar widget (status item + menu)
**Purpose / 목적:** **EN:** the always-present menu-bar entry point: lightning condition gauge, Start/Stop, cumulative time, BGM status, and every setting — the single control surface when no window is open. **KO:** 언제나 떠 있는 메뉴바 진입점 — 번개 컨디션 게이지, 시작/정지, 누적 시간, BGM 상태, 모든 설정을 담당한다. 창이 꺼져 있어도 항상 떠 있는 유일한 제어 화면이다.

- **WIDGET-1 — single unified window-toggle menu item.**
  EN: There is exactly ONE menu entry that opens/switches the app window (no separate "대시보드
  열기" / "BGM 열기" items). Closed -> opens in the last-shown mode; open -> switches that same
  window's mode. Its label always names the destination state.
  KO: 창을 열고/전환하는 메뉴 항목은 단 하나뿅 (열기 항목 2개 아님). 닫혀 있으면 마지막 모드로 열고,
  열려 있으면 같은 창의 모드를 전환한다. 라벨은 항상 도착 상태를 가리킨다.
  Verify: `MenuController.swift:windowToggleLabel` + `AppDelegate.swift:toggleAppWindowMode`; no
  `onToggleBGMWindow`/dashboard-only menu action remains wired to a second "열기" item.
- **WIDGET-2 — 창 자동 열기 toggle is independent of `음악(BGM)` toggle.**
  EN: `Settings.bgmWindowEnabled` (label: "창 자동 열기 (BGM 자동재생)") gates ONLY whether the
  window auto-opens on launch; it must not be confused with `musicEnabled` ("음악 (BGM)"), which
  gates whether BGM plays at all. Launch auto-open must never be gated on `musicEnabled` (see
  WINLIFE-1 history).
  KO: `창 자동 열기` 토글은 "실행 시 창을 자동으로 열지"만 결정하고, `음악(BGM)` 토글(재생 여부)과는
  별개다. 실행 시 창 자동 열기가 `musicEnabled`에 의해 막혀선 안 된다.
  Verify: `Settings.swift:bgmWindowEnabled` vs `musicEnabled`; `AppDelegate.swift:305` comment
  "Don't gate on musicEnabled".
- **WIDGET-3 — menu-bar gauge reflects live condition.**
  EN: The lightning gauge (`LightningGauge`) charges across 5 stages and shifts color with the live
  condition ratio while a session is active, and shows idle otherwise.
  KO: 번개 게이지는 세션이 활성일 때 활동/개인 최고치 비율에 따라 5단계로 차오르고 색이 바뀌며,
  아닐 땐 대기 상태를 보인다.
  Verify: `AppDelegate.swift` gauge callback wiring; `gauge?.showIdle()` called in
  `applicationWillTerminate`.

### Intent audit — P1
EN: Code matches intent: PASS. The old two-item "대시보드 열기 / BGM 열기" menu design was replaced by a single unified toggle (per `agent-update-log.jsonl` 2026-07-05 05:16:41 entry) and MenuController.swift confirms only one `onToggleAppWindowMode`-wired item exists. No open questions on this page.
KO: 코드가 의도와 일치함: PASS. 기존의 "대시보드 열기 / BGM 열기" 2항목 메뉴 설계는 하나의 통합 토글로 대체됐고(`agent-update-log.jsonl` 2026-07-05 05:16:41 항목 기준), MenuController.swift에서 `onToggleAppWindowMode`로 연결된 항목이 단 하나만 존재함을 확인했다. 이 페이지에는 미해결 질문이 없다.

Note: SPEC.html's P1 section shows a labeled placeholder, not a real screenshot — the menu-bar menu
is a native `NSMenu`, not a `WKWebView`, so the `/api/debug/snapshot` mechanism (see EP-6) cannot
capture it, and `screencapture` requires Screen Recording permission not available in this headless
QA environment (2026-07-05: `screencapture -x` -> "could not create image from display"). Revisit if
Screen Recording permission becomes available, or accept a manual capture from the user.
Note (KO): SPEC.html의 P1 섹션은 실제 스크린샷이 아니라 라벨이 붙은 placeholder를 보여준다 —
메뉴바 메뉴는 `WKWebView`가 아니라 네이티브 `NSMenu`라서 `/api/debug/snapshot`(EP-6 참고) 방식으로
캡처할 수 없고, `screencapture`는 이 헤드리스 QA 환경에서 사용 불가능한 화면 기록 권한이
필요하다(2026-07-05: `screencapture -x` -> "could not create image from display"). 화면 기록 권한이
가능해지거나 사용자가 수동 캡처를 제공하면 다시 시도한다.

---

## P2. App window lifecycle (shared across BOTH modes)
**Purpose / 목적:** **EN:** the single native `NSWindow` (WKWebView-hosted) that is switched between `.dashboard` and `.bgm` modes by an in-window segmented control. Its OPEN/CLOSED state — not its mode — drives audio ownership and quit behavior. One window, two faces, one lifecycle. **KO:** `.dashboard`와 `.bgm` 모드를 창 안의 세그먼트 컨트롤로 전환하는, 하나의 네이티브 `NSWindow`(WKWebView 기반)다. 오디오 소유권과 종료 동작을 결정하는 것은 모드가 아니라 열림/닫힘 상태다. 창은 하나, 모드는 둘, 생사(生死)는 하나의 규칙을 따른다.

- **WINLIFE-1 — launch opens BOTH the menu-bar app and the window.**
  EN: Launching starts the menu-bar app AND the app window (when "창 자동 열기" is on). As of the
  2026-07-06 navigation refactor the window now auto-opens on the DASHBOARD (`.dashboard`), not
  `.bgm` (`AppDelegate.swift` ~352-357, `autoOpen(port:mode:.dashboard)`) — this is an INTENTIONAL
  change. The persistent BGM webview is now ALWAYS kept attached to the window's view hierarchy
  (layered underneath the opaque dashboard webview when `.dashboard` is shown) precisely because a
  WKWebView's `<audio>` element cannot begin loading media while its host webview has no
  `superview` — see BGMACT-1, PASS as of the 2026-07-06 third pass (fix verified: zero-click
  autoplay now works from a fresh launch landing in `.dashboard`, with no double-audio or gap
  regressions across mode switches).
  KO: 실행하면 메뉴바 앱과 앱 창이 (창 자동 열기가 켜져 있으면) 함께 뜬다. 2026-07-06 내비게이션
  리팩터 이후 창은 이제 BGM이 아니라 **대시보드**로 자동 오픈한다(의도된 변경). 지속형 BGM webview는
  이제 항상 창 뷰 계층에 붙어있다(`.dashboard`가 보일 때는 불투명한 대시보드 webview 아래 레이어로
  깔림) — 호스트 webview에 `superview`가 없으면 `<audio>` 요소가 미디어 로딩을 아예 시작하지 못하기
  때문이다. BGMACT-1 참고, 2026-07-06 3차 확인으로 PASS(수정 검증 완료 — `.dashboard`로 랜딩하는
  신규 실행에서 제로클릭 자동재생이 동작하며, 모드 전환에도 이중 오디오나 끊김 회귀가 없음).
  Verify: app.log `LAUNCH` -> `app-window autoOpen(port=N, mode=dashboard)` -> `app window owns
  audio=true -> native muted=true`; process alive. (Verify string updated 2026-07-06 to match the
  new launch mode; was `mode=bgm`.)
  History: a bug shipped where only the widget opened because launch was gated on a stale
  `musicEnabled=false`. 2026-07-06: launch mode intentionally changed from `.bgm` to `.dashboard`;
  the titlebar segmented mode-toggle was removed in the same change (see WINLIFE-7 update, WINLIFE-10).
- **WINLIFE-2 — single instance.**
  EN: Launching a new copy force-terminates any older instance with the same bundle id.
  KO: 새 인스턴스를 실행하면 같은 번들 ID의 이전 인스턴스를 강제 종료한다.
  Verify: app.log `single-instance: found N other instance(s)` -> `single-instance: forceTerminate
  pid N`; the old pid is gone (`kill -0` fails).
- **WINLIFE-3 — no double audio; ownership follows the window's OPEN state, not its mode.**
  EN: While the window is OPEN, native stays muted the ENTIRE time in BOTH `.dashboard` and `.bgm`
  modes and across every switch between them — the persistent BGM webview (never reloaded on
  switch) is the single continuous audio source; the dashboard view is purely visual. On
  close/quit, ownership releases (`owns audio=false`) and menu-bar-only BGM resumes. A
  `POST /api/bgm/native {mute:false}` cannot unmute while the window-open latch is set (the latch
  wins: `audio.muted = mute || windowOwnsAudio`).
  KO: 창이 열려 있는 동안엔 `.dashboard`/`.bgm` 두 모드 모두, 그리고 그 사이 전환 중에도 네이티브는
  계속 음소거 상태다 — 전환 시 다시 로드되지 않는 지속형 BGM webview가 유일한 소리 출처이고,
  대시보드 화면은 순수 시각적이다. 창을 닫거나 종료하면 소유권이 풀리고(`owns audio=false`)
  메뉴바 전용 BGM이 재개된다. 창이 열려 있는 동안엔 `/api/bgm/native {mute:false}`로도 음소거를
  풀 수 없다.
  History: previously ownership followed the MODE (`onOwnAudio?(mode == .bgm)`), so switching to
  `.dashboard` unmuted native while the BGM webview (parked off-view but still playing) kept going
  underneath — two audible sources at once ("음악이 중복되서 나와"). Fixed in `AppWindow.swift
  applyAudioOwnership()` to fire `onOwnAudio?(true)` whenever the window is open, in either mode.
  Verify (SIMULTANEOUS-AUDIBILITY, not just the mute latch): from launch, app.log shows
  `app window owns audio=true` and NEVER `owns audio=false` while the window stays open — including
  right after switching to `.dashboard` mode (`POST /api/debug/window-mode {"mode":"dashboard"}` for
  headless testing) — AND the `app-window audio-probe(...)` log line shows the BGM webview's own
  `<audio>` `paused:false` with `currentTime` strictly increasing at the same moments, proving
  native-muted AND web-advancing simultaneously (exactly one audible source). Switching back to
  `.bgm` must show no gap (currentTime keeps advancing monotonically) and no extra `owns audio`
  toggle.
  RETIRED sub-clause (see Intent audit below): the old "third source" (dashboard in-page BGM
  iframe / `bgmFrame`) no longer exists in code.
- **WINLIFE-4 — closing the app window quits the ENTIRE app, in EITHER mode.**
  EN: The window and the menu-bar app terminate together when the user clicks the window's close
  button, regardless of which mode (`.dashboard` or `.bgm`) was visible at the time.
  KO: 사용자가 창의 닫기 버튼을 누르면, 그 순간 보이던 모드(`.dashboard`든 `.bgm`이든)와 무관하게
  창과 메뉴바 앱이 함께 종료된다.
  Verify: app.log `app-window windowWillClose (user, mode=<dashboard|bgm>)` -> `app window
  user-closed -> quitting app (같이 종료)` -> `applicationWillTerminate — done`; process gone;
  menu-bar icon gone. Headless: `POST /api/debug/window-close` drives the real `NSWindow.close()`
  path.
- **WINLIFE-5 — quitting via menu 종료 stops everything; the quit path is not confused with a
  user-close.**
  EN: Audio stops, the window closes, the process dies; nothing lingers. The quit path must NOT
  trigger the user-close logic — app.log shows `app-window windowWillClose (during quit)`, never
  `(user)`, on quit.
  KO: 오디오가 멈추고 창이 닫히고 프로세스가 죽는다 — 아무것도 남지 않는다. 종료 경로는
  user-close 로직을 트리거하면 안 된다 — 종료 시 로그는 `(during quit)`이어야 하며 `(user)`가
  아니다.
  Verify (`CM_QUIT_AFTER`): app.log `applicationShouldTerminate — reply=terminateNow` ->
  `applicationWillTerminate — stopping director + audio, closing BGM window` -> `app-window
  closeForQuit (isOpen=BOOL)` -> `app window owns audio=false -> native muted=false` ->
  `applicationWillTerminate — done`; `kill -0` fails afterward.
- **WINLIFE-6 — window frame (size/position) is remembered across close/reopen AND across a
  rebuild of the same bundle id.**
  EN: Resizing/moving the window, then closing it (user-close or quit), persists the frame via
  `NSWindow.setFrameAutosaveName` + an explicit `saveFrame(usingName:)` + `UserDefaults.synchronize()`
  fired from BOTH `windowWillClose` and `closeForQuit` (so the frame in effect right before teardown
  is captured even if the process is torn down quickly after). On the next `ensureBuilt()` (fresh
  open, including after a rebuild — the UserDefaults key is keyed by bundle id, not binary hash),
  `setFrameUsingName` restores it; `center()` is called ONLY when there was no saved frame yet
  (first-ever launch), so it never stomps a restored frame.
  KO: 창을 리사이즈/이동한 뒤 닫으면(사용자 닫기 또는 종료), `NSWindow.setFrameAutosaveName` +
  명시적 `saveFrame(usingName:)` + `UserDefaults.synchronize()`가 `windowWillClose`와
  `closeForQuit` 양쪽에서 호출되어 프레임이 저장된다(프로세스가 곧바로 종료되어도 테어다운 직전
  프레임이 확실히 저장되도록). 다음 `ensureBuilt()`(재빌드 후 포함 — UserDefaults 키는 바이너리
  해시가 아니라 번들 id 기준)에서 `setFrameUsingName`이 복원하며, `center()`는 저장된 프레임이
  없을 때(최초 실행)만 호출되어 복원된 프레임을 덮어쓰지 않는다.
  Verify: `AppWindow.swift saveWindowFrame()`, `ensureBuilt()` `hadSavedFrame` gate. Isolated
  instance, 2026-07-06: real mouse-drag resize (CGEvent, not Accessibility `set size` — the latter
  moves the window server-side without updating `NSWindow.frame`, a test-methodology trap) from
  1040x720 to 1191x821 -> close via `/api/debug/window-close` -> app.log `saveWindowFrame {{760,
  439}, {1191, 821}}` -> `defaults read <bundle-id>` shows `NSWindow Frame ConditionMateAppWindow =
  "760 439 1191 821 …"` -> fresh relaunch (same bundle, rebuilt binary) -> app.log `ensureBuilt
  hadSavedFrame=true frame={{760, 439}, {1191, 821}}`, confirmed via Accessibility position/size
  query on the correct pid.
  Note: verifying this requires targeting the correct OS process — `System Events` `tell process
  "ConditionMate"` is AMBIGUOUS whenever a `dev-watch.sh`-spawned instance is also running (same
  process name), silently querying the wrong window. Always scope by
  `first process whose unix id is <pid>`.
- **WINLIFE-7 — [RETIRED 2026-07-06] unified titlebar: the mode toggle lived in the titlebar row
  itself.**
  EN: **RETIRED / STALE AS WRITTEN.** The titlebar segmented 대시보드/컨디션 toggle described below
  was REMOVED in the 2026-07-06 navigation refactor. Confirmed by direct code read
  (`AppWindow.swift` ~354-358): the `NSSegmentedControl` is still constructed and kept wired (so
  `setMode`'s `segmented?.selectedSegment = ...` stays a harmless no-op), but it is never attached
  via `addTitlebarAccessoryViewController` — no such call exists in the current file, only a
  leftover comment mentioning the pattern. Navigation is now via the rail's condition popup
  ("시스템관리", 2026-07-12 renamed from "컨디션 전체 보기") and the BGM page's "← 대시보드" button, both calling
  `POST /api/window/mode {mode}` — see WINLIFE-10. This item's Verify recipe below (real coordinate
  clicks on a titlebar segmented control) can no longer be exercised because the control is not on
  screen; kept for history only, do not re-run as written.
  KO: **2026-07-06 폐기(RETIRED) / 문서상 낡음.** 아래 설명된 타이틀바 세그먼트 대시보드/컨디션
  토글은 2026-07-06 내비게이션 리팩터에서 제거되었다. 코드 직접 확인으로 확정
  (`AppWindow.swift` ~354-358): `NSSegmentedControl`은 여전히 생성되고 연결되어 있지만(그래서
  `setMode`의 `segmented?.selectedSegment = ...`가 무해한 no-op으로 남음), `addTitlebarAccessoryViewController`로
  붙는 곳은 더 이상 없다 — 현재 파일엔 그런 호출이 없고 예전 패턴을 언급하는 주석만 남아 있다.
  내비게이션은 이제 레일의 컨디션 팝업("시스템관리", 2026-07-12에 "컨디션 전체 보기"에서 개명)과 BGM 페이지의 "← 대시보드" 버튼이
  각각 `POST /api/window/mode {mode}`를 호출하는 방식이다 — WINLIFE-10 참고. 아래 Verify 레시피
  (타이틀바 세그먼트 컨트롤 실좌표 클릭)는 화면에 컨트롤이 없으므로 더 이상 재현 불가 — 기록
  목적으로만 남기며 그대로 재실행하지 말 것.
  EN (original text, kept for history): `fullSizeContentView` + `titlebarAppearsTransparent` let the dark web content extend under
  the traffic lights; the 대시보드/BGM segmented toggle is a `.right`-aligned
  `NSTitlebarAccessoryViewController` sized via `sizeToFit()` on a real frame (NOT pure Auto Layout
  constraints on a zero-frame view, which silently collapses the accessory's hit-testable width to
  ~2px — clicks land outside the segments even though it may still render). The top row reads as
  one continuous bar instead of a wasted empty title strip; the toggle is still fully clickable and
  the window remains draggable.
  KO: `fullSizeContentView` + `titlebarAppearsTransparent`로 어두운 웹 콘텐츠가 트래픽 라이트 아래까지
  확장된다. 대시보드/BGM 세그먼트 토글은 `.right` 정렬 `NSTitlebarAccessoryViewController`이며, 순수
  Auto Layout 제약(프레임이 0인 뷰)이 아니라 실제 프레임에 `sizeToFit()`을 적용해 크기를 잡는다 —
  그러지 않으면 액세서리의 히트테스트 가능 폭이 약 2px로 붕괴해 시각적으로는 보여도 클릭이 세그먼트
  밖으로 빗나간다. 상단 줄이 빈 타이틀 바가 아니라 하나의 연속된 바로 보이며, 토글은 여전히 완전히
  클릭 가능하고 창은 계속 드래그된다.
  Verify: `AppWindow.swift ensureBuilt()` `seg.sizeToFit()` + explicit `bar` frame sizing. Isolated
  instance, 2026-07-06: Accessibility read (correct pid) showed the radio group at 114pt wide with
  two non-overlapping 63pt/47pt segments (vs. a broken first pass that collapsed to 2pt wide with
  both segments reporting an identical overlapping frame); real coordinate clicks on each segment
  correctly drove `setMode` both directions (`app-window audio-probe(mode=dashboard…)` /
  `(mode=bgm…)`), with `owns audio` staying `true` throughout (no WINLIFE-3 regression).
- **WINLIFE-8 — dashboard sidebar content clears the traffic lights; native-style sidebar toggle.**
  EN: WINLIFE-7's `fullSizeContentView` means web content (including the `.cmrail` sidebar, which
  is `position:fixed` at the page's top-left) rides up under the transparent titlebar. The rail
  header (`SessionRail.swift` `.cmrail-brand`) has `padding-top:40px` so the "ConditionMate"
  logo/title never sits under the ~78x28pt traffic-light zone. The old gray filled "‹" collapse
  button was replaced with a flat, icon-only native-style sidebar-toggle glyph (rectangle with a
  vertical divider, `.cmrail-sbtoggle`, shared by the in-rail collapse button and the floating
  show-again button) — same `cmRailToggle()` behavior, just restyled. The floating show-again
  button (shown whenever the rail is collapsed, whether by narrow-width auto-collapse or the
  manual toggle) also got a top-clearance fix on the page content underneath it
  (`DashboardContent.swift` `body:not(.cmrail-force-open) .wrap, body.cmrail-collapsed
  .wrap{padding-top:52px}`) so the header's date/subtitle line doesn't render underneath the fixed
  button.
  KO: WINLIFE-7의 `fullSizeContentView` 때문에 웹 콘텐츠(페이지 좌상단에 `position:fixed`로 붙는
  `.cmrail` 사이드바 포함)가 투명 타이틀바 아래까지 올라온다. 레일 헤더(`SessionRail.swift`
  `.cmrail-brand`)에 `padding-top:40px`를 주어 "ConditionMate" 로고/타이틀이 약 78x28pt 트래픽
  라이트 영역 아래에 깔리지 않게 했다. 회색 채워진 "‹" 접기 버튼은 플랫한 아이콘 전용 네이티브 스타일
  사이드바 토글 글리프(세로 구분선이 있는 사각형, `.cmrail-sbtoggle`, 레일 내부 접기 버튼과 다시
  펼치는 플로팅 버튼이 공유)로 교체됐다 — 동작은 동일한 `cmRailToggle()`, 스타일만 바뀜. 레일이
  접혀 있을 때(좁은 너비 자동 접힘이든 수동 토글이든) 항상 보이는 플로팅 재펼침 버튼 아래 콘텐츠에도
  상단 여백 수정(`DashboardContent.swift` `body:not(.cmrail-force-open) .wrap, body.cmrail-collapsed
  .wrap{padding-top:52px}`)을 적용해 헤더의 날짜/부제 줄이 고정 버튼 아래에 깔리지 않게 했다.
  Verify: isolated instance, 2026-07-06 — snapshot at desktop width (1300px) shows the toggle glyph
  cleanly above/beside the "ConditionMate" text with no overlap; snapshot at narrow width (641px,
  auto-collapsed rail) initially showed the floating toggle overlapping the "2026-07-06 (Mon)"
  subtitle (found via visual snapshot inspection, not caught by `runQaAudit` since it only checks
  wrap/overflow, not position overlap) — fixed by extending the `padding-top:52px` rule to also
  match the narrow-width auto-collapse selector (`body:not(.cmrail-force-open)`), re-verified clean
  after the fix. `qa-audit.json` `issues:[]` at both 641px and 1300px throughout. Toggle click
  verified via real CGEvent mouse click (not Accessibility `set`) — collapses and re-expands the
  rail correctly in both directions. `owns audio` stayed `true` throughout (no WINLIFE-3
  regression); close-via-debug-endpoint still produces the clean `windowWillClose (user) ->
  applicationWillTerminate — done` sequence.
  History: found 2026-07-06 from a user annotated-screenshot report — the WINLIFE-7 unified-titlebar
  change had no accompanying top-inset for the sidebar, so the rail header and (initially, in the
  first fix pass) the collapsed-state floating toggle both collided with the traffic lights /
  header text respectively.
- **WINLIFE-9 — the empty top strip drags the window again (regression from WINLIFE-7).**
  EN: WINLIFE-7's `fullSizeContentView` let the WKWebView content view span the full window
  including under the titlebar, which silently killed the normal "grab the empty titlebar to move
  the window" gesture across the whole top strip (the webview captured every mouse-down there, and
  WKWebView does not honor CSS `-webkit-app-region:drag`). A `TitlebarDragView` (transparent
  `NSView`, `mouseDownCanMoveWindow=true`, driving the move via `NSWindow.performDrag(with:)` in
  `mouseDown`) is pinned across the titlebar's full width, ABOVE the webview container, with the
  traffic-light zone (left ~78pt) and the segmented-control accessory's zone (right ~140pt)
  excluded via a coordinate-space-corrected `hitTest` override, so only the empty middle/top
  actually starts a drag.
  KO: WINLIFE-7의 `fullSizeContentView`로 WKWebView 콘텐츠 뷰가 타이틀바 아래까지 포함해 창 전체를
  덮으면서, "빈 타이틀바를 잡고 창을 움직이는" 평범한 제스처가 상단 줄 전체에서 조용히 죽었다(그
  영역의 모든 마우스다운을 webview가 가로챘고, WKWebView는 CSS `-webkit-app-region:drag`를 지원하지
  않는다). `TitlebarDragView`(투명 `NSView`, `mouseDownCanMoveWindow=true`, `mouseDown`에서
  `NSWindow.performDrag(with:)`로 이동을 구동)를 타이틀바 전체 너비에 걸쳐 webview 컨테이너 위에
  배치하고, 트래픽라이트 영역(좌측 ~78pt)과 세그먼트 컨트롤 액세서리 영역(우측 ~140pt)은 좌표계를
  보정한 `hitTest` 오버라이드로 제외해 빈 중간/상단만 실제로 드래그를 시작하게 했다.
  Verify: isolated instance, 2026-07-06 — real CGEvent mouse-drag (press-drag-release, not
  Accessibility `set position`) from a mid-top point (avoiding both excluded zones) confirmed via
  BOTH the Accessibility-reported window position AND `NSWindow.frame` (temporary `windowDidMove`
  logging during this investigation) moving by exactly the drag delta, e.g. delta (+106,+98) ->
  position (3094,388) -> (3200,486), frame log `{3094,332}` -> intermediate moves -> final matching
  the new screen position. Segmented-control real-coordinate clicks (both segments) and a real
  click on the minimize traffic-light button were re-verified working AFTER installing the drag
  view (`owns audio` stayed `true` throughout — no WINLIFE-3 regression); close-via-debug-endpoint
  still produces the clean `windowWillClose (user) -> applicationWillTerminate — done` sequence.
  History: found 2026-07-06 from a user report ("상단을 잡고 윈도우 움직이는게 잘 안돼") —
  REGRESSION from WINLIFE-7, fixed same day. A first implementation attempt (plain
  `mouseDownCanMoveWindow` override without `performDrag`) did NOT actually move the window despite
  mouse-down provably reaching the view (confirmed via logging) — switched to explicitly calling
  `NSWindow.performDrag(with:)`, which worked. A second bug was found in the same pass: the
  `hitTest` override compared the incoming point (in the SUPERVIEW's coordinate space) directly
  against `excludedRects` (defined in the view's OWN coordinate space) without converting first,
  so real mouse clicks on the segmented control were being silently swallowed by the drag view
  while `AXPress`-driven QA clicks kept "working" (accessibility actions bypass hit-testing
  entirely) — this made the regression easy to miss with an Accessibility-action-only test and is
  why this item's Verify uses real coordinate clicks, not `AXPress`, for the segmented control.
- **WINLIFE-10 — mode switch is driven by in-page controls via `POST /api/window/mode`, not the
  titlebar toggle (supersedes WINLIFE-7).**
  EN: The titlebar segmented toggle (WINLIFE-7, RETIRED) was removed. Switching between the
  dashboard and the full condition (BGM) surface is now driven by: (a) the sidebar rail's condition
  popup button "시스템관리" (2026-07-12 renamed from "컨디션 전체 보기"), which POSTs
  `{mode:"condition"}`; (b) the BGM page's "← 대시보드"
  button, which POSTs `{mode:"dashboard"}`. Both call the SAME underlying mechanism as before
  (`AppWindowController.setMode` via `openBGMWindow()`/`openDashboard()`) — only the trigger UI
  changed, not the two-webview seamless-switch architecture (WINLIFE-3 still applies unchanged: the
  BGM webview is never reloaded on switch, native stays muted the whole time the window is open).
  KO: 타이틀바 세그먼트 토글(WINLIFE-7, 폐기됨)이 제거됐다. 대시보드와 전체 컨디션(BGM) 화면 사이
  전환은 이제 (a) 사이드바 레일의 컨디션 팝업 버튼 "시스템관리"(2026-07-12에 "컨디션 전체 보기"에서
  개명, `{mode:"condition"}` POST)와
  (b) BGM 페이지의 "← 대시보드" 버튼(`{mode:"dashboard"}` POST)이 담당한다. 둘 다 이전과 동일한
  내부 메커니즘(`openBGMWindow()`/`openDashboard()`를 통한 `AppWindowController.setMode`)을
  호출한다 — 트리거 UI만 바뀌었을 뿐, 두-webview 무중단 전환 구조는 그대로다(WINLIFE-3는 변경 없이
  그대로 적용 — 전환 시 BGM webview는 다시 로드되지 않고, 창이 열려 있는 동안 네이티브는 계속
  음소거).
  Verify (2026-07-06, live against the running dev-watch instance, port discovered via `lsof -nP
  -iTCP -sTCP:LISTEN | grep -i Condition`): `POST /api/window/mode {"mode":"dashboard"}` ->
  `{"ok":true}`, `POST {"mode":"condition"}` -> `{"ok":true}`, `POST {"mode":"dashboard"}` again ->
  `{"ok":true}` — app.log shows the matching sequence `app window owns audio=true -> native
  muted=true` / `app-window audio-probe(mode=dashboard)` -> `.../(mode=bgm)` ->
  `.../(mode=dashboard)` immediately after each call, e.g.:
  ```
  2026-07-06 07:13:56.516 [pid 1854] app window owns audio=true -> native muted=true
  2026-07-06 07:13:56.520 [pid 1854] app-window audio-probe(mode=dashboard) ...
  2026-07-06 07:13:57.532 [pid 1854] app window owns audio=true -> native muted=true
  2026-07-06 07:13:57.539 [pid 1854] app-window audio-probe(mode=bgm) ...
  2026-07-06 07:13:58.565 [pid 1854] app window owns audio=true -> native muted=true
  2026-07-06 07:13:58.566 [pid 1854] app-window audio-probe(mode=dashboard) ...
  ```
  PASS: the endpoint and mode switch mechanism work correctly and native never unmutes mid-switch.
  Code-read confirms `setMode()` (AppWindow.swift ~169-185) ONLY adds/removes each webview from the
  view hierarchy and calls `applyAudioOwnership()` — it never calls `.pause()/.play()/.load()` on
  either webview, so the switch itself cannot be the source of an audio interruption.
  Note: `setMode()` was rewritten (2026-07-06 third pass, see BGMACT-1) so the BGM webview is now
  NEVER removed from the view hierarchy — only the dashboard webview is ever detached/attached.
  This closes the previously-noted `netState=NETWORK_NO_SOURCE` stall while `.dashboard` was visible
  (root-caused to the old code's `removeFromSuperview()` on the then-hidden BGM webview) without
  touching this item's mute/ownership mechanism, which was independently re-verified clean across
  the fix (native mute correctly asserted at every mode transition, no gap in `currentTime`).
- **WINLIFE-1, 2, 4, 5.**
  EN: Code matches intent — PASS (see Verify section below, run 2026-07-05).
  KO: 코드가 의도와 일치함 — PASS (아래 Verify 섹션 참고, 2026-07-05 실행).
- **WINLIFE-3.**
  EN: Code matches the CURRENT intent (open-state ownership) — PASS. However the "third source"
  sub-clause inherited from the old A1 item is now STALE: `DashboardContent.swift` no longer has a
  `bgm` view or a `bgmFrame` iframe element at all (`VIEW_DEFS`/`VIEW_KEYS` have no `bgm` entry) —
  the old browser-based dashboard's in-page BGM tab was fully replaced by the native window's own
  `.bgm` mode. **REGRESSION-ADJACENT FINDING (documentation drift, not a behavior bug):**
  `BGMPlayerContent.swift:276-277` still has comments describing "the dashboard's own in-page 'BGM
  관리' tab, which lazy-loads this page a SECOND time inside an `<iframe id="bgmFrame">` (see
  DashboardContent.swift)" — this iframe does not exist in the current DashboardContent.swift. The
  `EMBEDDED` guard code itself is harmless (defensive dead code, `window.frameElement !== null`
  never true via the current dashboard), but the comment now describes a surface that was removed,
  which will mislead the next reader/agent into re-verifying a non-existent third source. Flagged
  here as an intent-audit finding, not filed as a code diff per this agent's scope.
  KO: 코드가 현재 의도(열림 상태 기반 소유권)와 일치함 — PASS. 다만 예전 A1 항목에서 물려받은 "제3의
  소리 출처" 하위 조항은 이제 STALE(낡음) 상태다: `DashboardContent.swift`에는 더 이상 `bgm` 뷰나
  `bgmFrame` iframe 요소가 전혀 없다(`VIEW_DEFS`/`VIEW_KEYS`에 `bgm` 항목 없음) — 예전 브라우저 기반
  대시보드의 인페이지 BGM 탭은 네이티브 창 자체의 `.bgm` 모드로 완전히 대체되었다.
  **회귀에 준하는 발견(행동 버그가 아니라 문서 드리프트):** `BGMPlayerContent.swift:276-277`에는
  여전히 "대시보드 자체의 인페이지 'BGM 관리' 탭이 `<iframe id="bgmFrame">` 안에서 이 페이지를 두
  번째로 지연 로드한다(DashboardContent.swift 참고)"는 주석이 남아 있다 — 이 iframe은 현재
  DashboardContent.swift에는 존재하지 않는다. `EMBEDDED` 가드 코드 자체는 무해하다(방어적 죽은
  코드, 현재 대시보드를 통해서는 `window.frameElement !== null`이 참이 될 일이 없음)만, 주석이
  이미 제거된 화면을 설명하고 있어 다음 독자/에이전트가 존재하지 않는 제3의 소리 출처를 다시
  검증하도록 오도할 수 있다. 이 에이전트의 범위상 코드 diff로 제출하지 않고 intent-audit 발견으로
  플래그만 남긴다.

---

## P3. App window — BGM mode / 액티비티 sub-tab
**Purpose / 목적:** **EN:** auto-follows whatever the activity-driven BGM (`ConditionDirector`) is playing, with the venue Web Audio effect and a frequency-spectrum visualizer — the "what's playing right now, with atmosphere" view. **KO:** 활동 기반 BGM(`ConditionDirector`)이 재생 중인 곡을 자동으로 따라가며, 공간감 Web Audio 이펙트와 주파수 스펙트럼 시각화를 함께 보여준다 — "지금 흐르는 곡을 공간감과 함께" 보여주는 화면.

- **BGMACT-1 — zero-click autoplay.**
  EN: On window open in `.bgm` mode, the activity BGM plays immediately with the venue effect — no
  user gesture required (`mediaTypesRequiringUserActionForPlayback = []`). Audio must follow the
  challenge/session state regardless of which sub-tab (map/activity/debug) is visible, since the
  window now auto-opens on `.dashboard` (WINLIFE-1) and the BGM webview is parked off-view there.
  KO: `.bgm` 모드로 창이 열리면 사용자 제스처 없이 즉시 활동 BGM이 공간 이펙트와 함께 재생된다.
  창이 이제 기본적으로 `.dashboard`로 자동 오픈하고(WINLIFE-1) BGM webview는 그동안 화면 밖에
  대기하므로, 오디오는 어느 서브탭(맵/액티비티/디버그)이 보이든 챌린지/세션 상태를 따라야 한다.
  Verify: stderr `[app-window] loaded http://127.0.0.1:PORT/bgm-player`; audio-probe log shows
  `readyState:4` (HAVE_ENOUGH_DATA) and `currentTime` strictly increasing shortly after open — NOT
  just `paused:false` (see history below: `paused:false` alone is not sufficient evidence of
  playback).
  **STATUS: PASS — FIX VERIFIED, 2026-07-06 (third pass).** History of this item: (1) the sub-tab
  gate `mode!=='activity'` blocking `bgmAutoStart()` — FIXED (`BGMPlayerContent.swift` gates changed
  to `mode!=='debug'`); (2) the deeper off-view defect — a WKWebView's `<audio>` element cannot begin
  loading media while its hosting webview has no `superview`, and the BGM webview was detached
  (`removeFromSuperview()`) whenever `.dashboard` (the new default launch mode, WINLIFE-1) was
  visible — FIXED by keeping the BGM webview ALWAYS attached to the container in both modes
  (`AppWindow.swift setMode()`: only the silent dashboard webview is ever detached; the BGM webview
  is layered underneath, opaque dashboard on top, whenever `.dashboard` is shown). Verified in a
  fresh isolated bundle instance (unique bundle id, `CM_SCAN_DIR` -> real playable MP3,
  `CM_QUIT_AFTER`), landing in the real default `.dashboard` mode and NEVER switching modes:
  ```
  app-window autoOpen(port=59461, mode=dashboard)
  app-window audio-probe(periodic mode=dashboard) ...{"currentTime":0.75,...,"netState":1,"readyState":4,"mode":"map",...}
  app-window audio-probe(periodic mode=dashboard) ...{"currentTime":3.75,...,"netState":1,"readyState":4,...}
  app-window audio-probe(periodic mode=dashboard) ...{"currentTime":6.75,...}
  ... (continues advancing in exact 3.0s lockstep with wall-clock time through 18.75s+)
  ```
  `netState:1` (NETWORK_IDLE) / `readyState:4` (HAVE_ENOUGH_DATA) from the first probe onward — the
  `netState:3`/`readyState:0` stuck state from the prior pass never recurs. Reproduced identically on
  a second fresh instance. Also verified the round trip (`.dashboard` -> `.bgm` ->  `.dashboard` via
  `POST /api/debug/window-mode`) has NO gap and NO `netState` regression at either transition
  (`currentTime` 21.76 -> 22.69 -> 24.76 -> ... continuous through both switches; native mute
  reasserted at each transition, `app window owns audio=true -> native muted=true` both times). The
  design-comment correction (that an `<audio>` element cannot START a network load while off-view,
  unlike an already-running `AudioContext`) was folded into `AppWindow.swift`'s file header and
  `setMode()` comment in the same change. OPEN QUESTION resolved in favor of **option (a)** (always
  keep the BGM webview attached, dashboard layered opaquely on top) — this is the applied and
  verified fix; the OPEN QUESTIONS entry below is resolved and can be treated as historical context.
  NOTE: this PASS covers autoplay-starts-and-keeps-advancing only. See BGMACT-6 (new, 2026-07-06
  third pass) for a SEPARATE, newly-surfaced defect found while verifying this item: stopping the
  challenge does not actually stop the audible `<audio>` element.
  **REGRESSED then RE-FIXED, 2026-09-06 (fourth pass) — the 2026-07-06 PASS above is true as of
  its date and is left in place rather than deleted.** The window's own BGM webview stopped making
  any sound at all, for days: every app pid from 2026-09-04 21:16 KST through 2026-09-07 00:33 KST
  reported `paused:true, engaged:false, readyState:0` in `audio-probe`, i.e. the `<audio>` element
  never loaded a byte and `play()` was never called. CAUSE: `refreshNow()`'s director-follow branch
  gated the actual start on `engaged` alone (`if(engaged && audioEl.paused){ audioEl.play() }`),
  and `engaged` only becomes true on a user gesture inside the player. The dedicated BGM webview
  auto-opens and nobody ever clicks inside it, so the gesture never arrived — while native audio
  was already force-muted for the duration the window is open (WINLIFE-3), leaving ZERO audio
  sources. FIX (`BGMPlayerContent.swift:1114-1116`): branch on `!EMBEDDED || engaged` instead of
  `engaged`, and call `engage()` before `play()`. `EMBEDDED` (`:906`,
  `window.frameElement !== null`) is false for the dedicated top-level webview — the window's audio
  owner, whose WKWebView sets `mediaTypesRequiringUserActionForPlayback = []` — and true for the
  dashboard's in-page BGM tab, which stays gesture-only and never becomes a second source (the
  `EMBEDDED` guards at `:951` and `:1016` are unchanged). The `engage()`-before-`play()` ORDER is
  load-bearing, not cosmetic: `engage()` runs `ensureGraph()`, which is where
  `createMediaElementSource(audioEl)` (`:1364`) routes the element into the Web Audio graph behind
  `outMute` (`:1423-1425`). Calling `play()` first would let the element sound straight to the
  destination and bypass the mute gain entirely — audible sound while the user has muted.
  **Verify (STRENGTHENED — this is the part that let the bug hide for days): the app's own report
  is NOT evidence of sound.** Throughout the silent period `/api/bgm/now` returned
  `on:true, playing:true, muted:false` and the UI read "재생 중" while nothing came out of the
  speakers. Any future check of this item must pair the in-page probe with an EXTERNAL,
  outside-the-app audio signal. Two that work, both used on 2026-09-06: (a) `pmset -g assertions`
  must show `coreaudiod` holding `PreventUserIdleSystemSleep` named
  `com.apple.audio.<Device>.context.preventuseridlesleep` with `Resources: audio-out <Device>` —
  this assertion exists only while audio is actually being rendered to an output device; (b) the
  app's `com.apple.WebKit.GPU` helper process (WKWebView plays media out-of-process) must have
  `CoreAudio.component` / `AudioCodecs.component` / `AudioDSP.component` loaded (`lsof -p <gpu-pid>`).
  Also confirm WHICH binary is running (`ps` — `/Applications/ConditionMate.app/Contents/MacOS/ConditionMate`
  vs `.build/debug/ConditionMate`) and that the change is actually inside it; because the JS is
  embedded as a Swift string literal, `strings -a <binary> | grep <a comment from the change>`
  settles it without a rebuild.
  KO: 창의 전용 BGM webview 가 며칠 동안 소리를 전혀 내지 않았다. 원인은 재생 시작을 `engaged`
  (사용자 클릭)에만 걸어 둔 것이다 — 전용 창은 자동으로 뜨고 그 안을 클릭할 사람이 없으므로 그
  제스처는 오지 않고, 창이 열려 있는 동안 네이티브는 이미 강제 음소거라 소리의 출처가 0 개가
  된다. `!EMBEDDED || engaged` 로 바꿔 창의 오디오 주인만 제스처 없이 시작하게 했고, 끼워진
  BGM 탭은 그대로 제스처 전용으로 남는다. `engage()` 를 `play()` 앞에 두는 순서가 중요하다 —
  그래프가 먼저 서야 음소거 게인을 우회하지 않는다. **검증에서 배울 것: 앱의 자기 보고를 소리의
  증거로 쓰지 마라.** 침묵하는 내내 앱은 `playing:true` 라고 말하고 화면은 "재생 중" 이었다.
  앱 밖의 신호(`pmset` 의 audio-out assertion, WebKit GPU 프로세스의 CoreAudio 로드)를 반드시
  같이 봐야 한다.
  **위험 (2026-09-06 시점): 이 수정은 커밋되어 있지 않다.** `git show HEAD:` 판은 아직 옛
  `if(engaged && audioEl.paused)` 를 들고 있어, `git checkout`/`git stash` 한 번이나 깨끗한
  트리에서의 빌드 한 번으로 이 침묵이 그대로 돌아온다.
- **BGMACT-2 — state machine has no stuck limbo.**
  EN: `GET /api/bgm/now` distinguishes `on` (system engaged) from `playing` (a resolvable track is
  actually streaming) from `id` (which library track). The status dot follows `on`; whether a
  track is queued follows `id>=0`, so warm-up/library-reload never reads as fully dead.
  KO: `on`(시스템 켜짐) / `playing`(실제 스트리밍 중) / `id`(어떤 곡)을 구분해, 워밍업이나
  라이브러리 리로드 중에도 "완전히 죽은" 상태로 안 보이게 한다.
  Verify: `AppDelegate.swift:bgmNowJSON` — `on = director.isPlaying`; `playing = on && !isPaused &&
  id >= 0`.
- **BGMACT-3 — the play button follows the browser transport. SCOPED to the EMBEDDED / external
  copy (amended 2026-09-06).**
  EN: Once the user "engages" (first play gesture / auto-cue), further track switches (from the
  director) auto-play in this same webview; before engaging, native stays audible and this view
  just cues silently. **This cue-only-until-gesture half applies ONLY where `EMBEDDED` is true —
  the dashboard's in-page BGM tab — or to an external browser tab on `/bgm-player`. It does NOT
  apply to the dedicated top-level BGM webview**, which is the window's audio owner and must
  self-start (BGMACT-1 fourth pass).
  KO: 사용자가 한 번 재생을 "잡으면" 이후 곡 전환도 이 화면에서 자동재생되고, 잡기 전까지는
  네이티브가 계속 들리며 이 화면은 조용히 큐만 잡는다. **단, "잡기 전까지 큐만" 은 `EMBEDDED`
  가 참인 사본(대시보드 안의 BGM 탭)과 외부 브라우저 탭에만 해당한다. 창의 오디오 주인인 전용
  BGM webview 에는 해당하지 않는다.**
  Verify: `BGMPlayerContent.swift:refreshNow()` — the gate is `!EMBEDDED || engaged`, so `engaged`
  gates auto-play vs. cue-only for the embedded/external copy only.
  Why the scope had to be written down / 왜 범위를 적어야 했는가: the unqualified wording above was
  the premise that produced the 2026-09-06 silence. Its "before engaging, native stays audible" is
  simply FALSE for the window's own webview — WINLIFE-3 force-mutes native for exactly as long as
  the window is open, so "cue silently and let native cover it" leaves nothing making sound. The
  clause is true only for the copies that run while native is still audible.
  이 절의 조건 없는 옛 표현("잡기 전까지는 네이티브가 계속 들린다")이 2026-09-06 침묵을 만든
  전제다. 창의 전용 webview 에는 그 전제가 거짓이다 — 창이 열려 있는 동안 네이티브는 음소거이므로
  "조용히 큐만" 이 곧 무음이다.
- **BGMACT-4 (was Q3) — disconnect auto-stop.**
  EN: If the app/server becomes unreachable, this page stops itself on the FIRST failed
  `/api/bgm/now` poll (~1.5s poll interval) rather than waiting — a browser tab must not keep
  playing buffered audio with no app behind it ("위젯이 안 꺼짐"). This applies to ANY external
  page loading `/bgm-player` (e.g. a browser tab) — the app cannot reach into it to stop it, so the
  page must self-stop.
  KO: 앱/서버 연결이 끊기면 첫 폴링 실패(~1.5초 간격) 즉시 스스로 멈춘다 — 기다리지 않는다. 외부
  브라우저 탭처럼 앱이 직접 끌 수 없는 화면은 스스로 멈춰야 한다.
  Verify: `BGMPlayerContent.swift:refreshNow()` — `if(++_pollFails>=1){ ...pause()... }`.
  Note: this is `>=1` (first miss), NOT "~2 failed polls" — corrected from the prior L/Q-era wording.
- **BGMACT-5 — venue effect + visualizer are live, not decorative-only.**
  EN: The Web Audio venue-effect graph (dry + convolution reverb) processes the actual track, and
  the canvas frequency-spectrum visualizer reflects real analyser data (not a static placeholder).
  KO: 공간감 이펙트(드라이+컨볼루션 리버브) 그래프가 실제 트랙을 처리하고, 캔버스 스펙트럼
  시각화는 실제 analyser 데이터를 반영한다(정적 placeholder 아님).
  Verify: extract the `// ---------- visualizer` block (`BGMPlayerContent.swift:844-909`) and run
  under node with a mock 2d context + mock analyser + hand-pumped rAF; assert frame-to-frame
  change. `node --check` the extracted `<script>` block for syntax sanity.
- **BGMACT-6 — stopping the challenge stops the audible `<audio>`; restarting resumes with zero
  clicks.**
  EN: When the challenge/session is stopped (`POST /api/session/control {"action":"stop"}`), the
  BGM webview's `<audio>` element must actually pause — silence must follow `on:false`, matching the
  mute contract's "challenge stop -> audio stop" half of the user's mental model. When the challenge
  restarts, playback must resume with NO manual click (the user's mental model: "시작하면 다시
  나온다").
  KO: 챌린지/세션이 정지되면(`POST /api/session/control {"action":"stop"}`) BGM webview의 `<audio>`
  요소도 실제로 일시정지되어야 한다 — `on:false`를 따라 소리가 멈춰야 하며, 이는 "챌린지 정지 -> 오디오
  정지"라는 사용자의 기대(뮤트 계약의 나머지 절반)와 일치해야 한다. 챌린지가 재시작되면 수동 클릭
  없이 재생이 재개되어야 한다("시작하면 다시 나온다").
  Verify: `BGMPlayerContent.swift:refreshNow()` — the follow branch is gated on `now.on && now.id>=0`
  (not just `id>=0`), so the `else` branch (system-off -> pause, resets `curTrack` but keeps
  `engaged`) actually runs on stop; the retained `engaged` makes the next `on:true` poll's
  `loadTrack(..., engaged)` autoplay without a fresh gesture.
  **STATUS: PASS — FIX VERIFIED, 2026-07-06 (fourth pass).** History: this item was FAIL (confirmed
  2026-07-06 third pass) because `refreshNow()` branched on `now.id>=0` alone — `bgmNowJSON()`
  (`AppDelegate.swift:5388`) keeps reporting the last-loaded track's `id` even when `on:false`
  (`director.pauseSession()` calls `audio.pause()`, which does not clear `audio.currentURL`), so the
  "follow the director" branch kept winning over the "system off -> pause" branch, and audio never
  actually stopped. FIX: the follow branch is now gated on `now.on && now.id>=0` (was `now.id>=0`),
  and the system-off branch keeps `engaged` intact (only resets `curTrack`) so a restart auto-resumes
  with zero clicks via `loadTrack({...}, engaged)`. VERIFIED live in a fresh isolated bundle instance
  (rebuilt binary, `swift build` confirmed), full user-scenario chain, TWO complete stop/start
  cycles:
  ```
  ...currentTime":9.51... "on":true...                  <- playing before stop
  POST /api/session/control {"action":"stop"}
  ...currentTime":14.7639... "paused":true, "on":false,"curTrack":null,"engaged":true  <- PAUSED, frozen
  ...currentTime":14.7639...  (unchanged 3s later — confirms a real pause, not a stall)
  ...currentTime":14.7639...  (unchanged 6s later)
  POST /api/session/control {"action":"start"}
  ...currentTime":14.7639..., "on":false,"working":true  <- warm-up transient, still correctly paused
  ...currentTime":1.3423..., "paused":false,"on":true,"id":0  <- RESUMED, zero clicks, fresh loadTrack
  ...currentTime":4.3423... "on":true                     <- advancing again, real lockstep
  ...currentTime":7.3422...
  -- 2nd cycle --
  POST stop  -> currentTime frozen at 21.5952 across 2 probes
  POST start -> currentTime resumes at 2.3438 -> 5.3446 -> 8.3452, zero clicks again
  ```
  Confirmed stable across both cycles — no accumulating drift, no stuck-paused state, no
  double-play. Also re-confirmed no regression on FINDING 1 (fresh launch in `.dashboard` mode still
  autoplays: `netState:1/readyState:4`, `currentTime` advancing from the first probe) and on mute
  (`POST /api/session/mute {"muted":true}` -> `working:true` stays true, `currentTime` keeps
  advancing uninterrupted through mute and unmute — gain-based silence, not a pause, exactly as
  designed). NOTE: the fix is client-side only (`BGMPlayerContent.swift`); `/api/bgm/now` still
  reports a stale `id>=0` while `on:false` (the endpoint itself was NOT changed) — this is a
  reasonable choice since `playing` was already correct and other consumers may read `id`, but
  flagging it here as a known asymmetry: any FUTURE consumer of `/api/bgm/now` that branches on
  `id>=0` alone (as this client used to) will reproduce the same class of bug. Not treated as an
  open question — the fix as implemented is verified correct for this page; future work should keep
  this asymmetry in mind rather than re-deriving it from scratch.
- **BGMACT-7 — client-side ambient layers (비 소리 · 배기음): gated, export-clean.**
  EN: The 비 소리 (rain, synthesized in-browser) and 배기음 (sports-car exhaust, recorded loops)
  cards each run on an independent gated bus that joins the shared chain
  (dry → masterGain, wet → convolver → … → outMute) so 전체 볼륨 / mute / venue reverb are inherited
  and the 메인 음원 볼륨 (music-only) slider does NOT affect them. Both layers are audible only while
  the `<audio>` element is playing, may be active simultaneously, persist as
  `localStorage cm.bgm.state` (`rain:{type,level}`, `exhaust:{type,drive,level}`), and are absent
  from the `.wav` offline render (the offline graph never builds ambient nodes). They emit no
  actions, so strategy-4 slot scoring is unaffected. Exhaust assets: Suno-generated recordings made
  seamless offline (tail crossfaded into head, seam verified) in `<data>/sound/exhaust/` — outside
  the `bgm/` selection pool — served same-origin via `GET /exhaust-audio/<key>` with a whitelist
  (`lambo-idle|lambo-city|porsche-idle|porsche-city`; anything else 404, no traversal). The client
  fetch+decodes each loop once (cached), plays it via a looping BufferSource with a random start
  phase, swaps the voice on brand/drive change, and drops loads that finish after the selection
  changed. Brands 람보르기니(V12)·포르쉐 911(flat-6) × drive modes 아이들링·시내주행. (v1 synthesized
  the engine in Web Audio; replaced 2026-07-16 with recordings — old persisted `drive:"highway"`
  values are rejected by restore validation.)
  KO: 비 소리(브라우저 합성)·배기음(녹음 루프) 카드는 각각 독립 게이트 버스로 공용
  체인(dry→masterGain, wet→convolver→…→outMute)에 합류해 전체 볼륨·뮤트·공간 리버브를
  상속한다(메인 음원 볼륨 슬라이더는 곡에만 적용, 앰비언트 무관). 두 레이어는 재생 중일 때만
  들리고 동시에 켤 수 있으며 `localStorage cm.bgm.state`에 영속, `.wav` 오프라인 렌더에는 포함되지
  않는다(오프라인 그래프가 앰비언트 노드를 아예 만들지 않음). 액션을 emit하지 않으므로 전략4 슬롯
  채점과 격리된다. 배기음 에셋: Suno 생성 녹음을 오프라인에서 심리스 루프로 가공(꼬리→머리
  크로스페이드, 심 검증 완료)해 `<data>/sound/exhaust/`에 두고(bgm/ 선곡 풀 밖),
  `GET /exhaust-audio/<key>` 화이트리스트(4개 키, 그 외 404·경로 탈출 불가)로 same-origin 서빙.
  클라이언트는 키당 1회 fetch+decode(캐시), 루핑 BufferSource(랜덤 시작 위상)로 재생, 차종/주행
  전환 시 보이스 교체, 선택 변경 뒤 도착한 로드는 폐기. 차종 람보르기니(V12)·포르쉐 911(수평대향
  6기통) × 주행 모드 아이들링·시내주행. (v1 Web Audio 합성은 2026-07-16 녹음으로 교체 — 구
  `drive:"highway"` 저장값은 복원 검증에서 거부.)
  Verify: `.e2e/exhaust.test.js` — extracts the real blocks from `BGMPlayerContent.swift` and runs
  them under a stub Web Audio graph + stub fetch (21 asserts: profile→key mapping, bus wiring,
  playback gating, voice fetch/cache/swap, stale-load drop, saveState/restore round-trip incl.
  highway/unknown-type rejection). Export cleanliness is structural: the `$("render")` offline
  graph builds music nodes only.
  **STATUS: PASS — node stub suite 21/21 (2026-07-16, recorded-loop replacement).**
- **BGMACT-8 — 액티비티 탭 하단 "bgm태깅관리" 감사 섹션.**
  EN: When the 액티비티 sub-tab is shown, a bottom card "bgm태깅관리" renders a read-only audit of
  the scanned BGM library from `GET /api/bgm/list`: total tracks, BPM-resolved count,
  BPM-fallback(110) count, theme count, and a per-theme list (name · track count · BPM min–max ·
  선곡 목적 문구 · a neutral badge "BPM 없음 N곡" when any track fell back). Card is activity-only
  (`data-actbottom`, hidden in 디버그). No traffic-light colors; no failure banner (empty → quiet
  loading state). `/api/bgm/list` carries theme+bpmResolved per track and a themes[] summary with
  server-owned purpose copy. Each track additionally carries arc/tier/purpose joined from
  `<musicRoot>/bgm-tags.json` (app read-only via `BGMTags.swift`, reloaded with every library
  rescan; the path relative to the music root — theme folder + "/" + filename — is the join key;
  arc ∈ intro/build/peak/resolve/ambient shown as 기/승/전/결/앰비언트; tier ∈
  가볍게/라운지/집중/초집중, ambient tracks carry none). `/api/bgm/list` tracks[] gains
  arc/tier/purpose and themes[] gains an `arc` distribution object
  `{intro,build,peak,resolve,ambient}` (existing fields unchanged, backward compatible). Theme
  rows in the bgm태깅관리 card expand on click (default collapsed, click again to close) to
  per-track rows (title · BPM, "—" when unresolved · arc badge in neutral
  slate/indigo/violet/steel-blue hues · tier · purpose). Theme heads show an arc mini
  distribution (zeros dropped, e.g. 기4·승6·전7·결6; ambient-only reads 앰비언트 9); heavy_rain
  tracks are all ambient. If the tags file is missing, per-track fields are quietly empty (title ·
  BPM only) and the theme audit still works.
  KO: 액티비티 탭에서 맨하단 "bgm태깅관리" 카드가 `GET /api/bgm/list` 기반으로 스캔된 BGM
  라이브러리를 읽기 전용 감사로 표시한다 — 총 곡수, BPM 해결 곡수, 110 폴백 곡수, 테마 수,
  테마별(이름·곡수·BPM 범위·선곡 목적·폴백 시 중립 배지). 디버그 탭엔 안 보임. 신호등 색 금지,
  실패 배너 금지. 각 트랙은 `<musicRoot>/bgm-tags.json`(앱 읽기 전용, 상대경로=조인 키,
  라이브러리 재스캔 시 함께 재로드) 기반 arc(기/승/전/결/앰비언트)·tier(가볍게/라운지/집중/초집중,
  앰비언트는 없음)·purpose(곡별 선곡 목적)를 갖는다. 테마 행 클릭 시 곡별 행 펼침(기본 접힘,
  재클릭 닫힘) — 제목·BPM(미해결 "—")·arc 배지(중립 hue)·tier·purpose; 테마 행에는 arc 미니
  분포(0 생략, 앰비언트만이면 "앰비언트 N") 표기. 태그 파일 부재 시 곡별 필드만 조용히 비고
  테마 감사는 정상 동작.
  Verify: `swift build`; `data-actbottom` card + setMode activity gate in
  `BGMPlayerContent.swift`; `bgmListJSON()` has theme/bpmResolved/themes[]; headless open activity
  tab → 4 summary stats + ~20 theme rows, heavy_rain row shows "BPM 없음 9곡" badge.
  `BGMTags.swift` exists and is read-only (no write/seed path); `bgm/bgm-tags.json` has 260
  entries all joining to on-disk files; `/api/bgm/list` tracks[] carries arc/tier/purpose and
  themes[] carries the arc distribution; `.e2e/tagaudit.test.js` (node stub over the real
  extracted `arcMini`/`loadTagAudit`/`renderTagAudit` blocks) — theme expand → per-track rows +
  arc badges, collapse, quiet failure, and a hex-hue scan proving no traffic-light colors.
  **STATUS: PASS (2026-07-24, lion-condition-mate-worker-qa — full pass incl. per-track arc/tier/purpose extension).**
  Theme-level pass (same date, see history) reconfirmed unchanged. Per-track extension verified
  end-to-end: `bgm/bgm-tags.json` (260 entries) integrity-checked against an on-disk walk of
  `bgm/` — 260/260 paths join with 0 missing/0 duplicate/0 extra (NFC/NFD-safe comparison), every
  `arc` value is a valid enum member, `heavy_rain`'s 9 tracks are all `ambient` with no `tier` key,
  every `purpose` is non-empty with no template-leftover pattern (e.g. no bare "기·집중 — "), and
  every non-`heavy_rain` theme carries ≥2 distinct arc kinds (checked all 20 themes; smallest
  themes china/peace/last_goal actually show 3 kinds each, no exception needed). `swift build`
  green (touched `BGMTags.swift` to defeat cache). Isolated `CM_DEV=1` instance scanning the
  repo's real `bgm/` folder: `curl /api/bgm/list` — all 260 tracks carry non-empty `arc`
  (260/260 join success, confirming `BGMTags.swift`'s exact-string path lookup already handles
  this on-disk library without any Unicode normalization mismatch — no fix needed), all 260 also
  carry the unchanged legacy `id/title/bpm/theme/bpmResolved` (no regression), every `themes[].arc`
  distribution sums to that theme's `count` across all 20 themes, and `heavy_rain`'s `arc` is
  exactly `{intro:0,build:0,peak:0,resolve:0,ambient:9}`. Served `/bgm-player` HTML contains the
  expanded-row markup (`.tgtracks`, `.tgtrk`, `.tgab.intro/.build/.peak/.resolve/.ambient` with the
  documented steel-blue/indigo/violet/slate/gray hues) and the `data-actbottom` activity-only gate
  is unchanged. Grepped the full page for red/green traffic-light hex/keywords — none found. Ran
  `.e2e/tagaudit.test.js` — 34/34 passed (theme expand → per-track rows + arc badges, collapse,
  untagged-track fallback to title/BPM only, quiet fetch-failure path, no traffic-light hues).
  Cleaned up the isolated instance and temp files after.

### Intent audit — P3
EN: BGMACT-2..5 — code matches intent, PASS as previously recorded. `_pollFails>=1` confirmed by
direct read (auto-stop on first miss); prior spec wording ("~2 failed polls") was already imprecise
before this rewrite — corrected here. `node --check` on the extracted script succeeded (2026-07-05
run, 38446 chars, no syntax errors).
**BGMACT-1 — RESOLVED, PASS (2026-07-06 third pass).** The always-attached-BGM-webview fix
(`AppWindow.swift setMode()`) closes both the previously-recorded root causes (sub-tab gate, then
off-view network-load block) — live-verified with the richer audio-probe across two fresh isolated
instances landing in the real default `.dashboard` mode, plus a full `.dashboard`<->`.bgm` round
trip with no gap. See the item's own STATUS note for the full evidence trail.
**BGMACT-6 — RESOLVED, PASS (2026-07-06 fourth pass).** The client-side gate fix
(`now.on && now.id>=0`, retaining `engaged` across a stop) closes the id-tracking gap between
`director.pauseSession()` (leaves `audio.currentURL` set) and `refreshNow()`'s branch selection —
live-verified over two complete stop/start cycles: audio freezes within one poll of `on:false` and
resumes with zero clicks on the next `on:true`, no drift, no regression on FINDING 1 or on mute. See
the item's own STATUS note for the full evidence trail.
KO: BGMACT-2..5 — 코드가 의도와 일치함, 기존 기록대로 PASS. `_pollFails>=1`은 직접 코드 확인으로
확정됨(첫 실패 즉시 자동 정지). 이전 스펙 문구("~2 failed polls")는 이번 재작성 전부터 부정확했으며
여기서 바로잡았다. 추출한 스크립트에 대한 `node --check`도 통과했다(2026-07-05 실행, 38446자,
문법 오류 없음).
**BGMACT-1 — 해결됨, PASS (2026-07-06 3차 확인).** BGM webview 상시 부착 수정(`AppWindow.swift
setMode()`)이 앞서 기록된 두 근본 원인(서브탭 게이트, 이후 화면 밖 네트워크 로드 차단)을 모두
닫는다 — 실제 기본값인 `.dashboard` 모드로 랜딩하는 격리 인스턴스 두 곳에서 강화된 audio-probe로
라이브 검증했고, `.dashboard`<->`.bgm` 왕복도 끊김 없이 확인했다. 전체 근거는 해당 항목의 STATUS
참고.
**BGMACT-6 — 해결됨, PASS (2026-07-06 4차 확인).** 클라이언트 측 게이트 수정(`now.on && now.id>=0`,
정지 시에도 `engaged` 유지)이 `director.pauseSession()`(오디오 `currentURL`을 그대로 남겨둠)과
`refreshNow()`의 분기 선택 사이의 id 추적 간극을 닫는다 — 완전한 정지/재시작 사이클 2회에 걸쳐 라이브
검증했다: 오디오는 `on:false` 후 한 폴링 내에 멈추고, 다음 `on:true`에서 클릭 없이 재개되며, 드리프트나
FINDING 1/뮤트 회귀도 없다. 전체 근거는 해당 항목의 STATUS 참고.

---

## P4. App window — BGM mode / 디버그 sub-tab
**Purpose / 목적:** **EN:** manual library browser to audition any track (not activity-driven) with the same venue effect — a verification tool for the music library itself; "pick any track and listen with the effect" for library QA. **KO:** 활동과 무관하게 아무 곡이나 골라 같은 공간 이펙트로 들어볼 수 있는 수동 라이브러리 브라우저 — 음악 라이브러리 자체를 검증하는 도구다. 라이브러리 QA를 위해 "아무 곡이나 골라 이펙트로 들어보는" 화면.

- **BGMDBG-1 — manual track list from the library.**
  EN: `GET /api/bgm/list` populates a track picker; selecting a track loads and plays it (with the
  venue effect) independent of the activity director.
  KO: `GET /api/bgm/list`로 트랙 목록을 채우고, 트랙을 고르면 액티비티 디렉터와 무관하게 그 곡을
  로드해 공간 이펙트와 함께 재생한다.
  Verify: `BGMPlayerContent.swift:424 // ---------- library (debug tab) ----------`,
  `loadTracks()`/`renderTracks()`.
- **BGMDBG-2 — does not interfere with 액티비티 tab state.**
  EN: Switching to 디버그 and auditioning a track does not change what the director considers "now
  playing" system-wide (`/api/bgm/now` `id`) — it is a local, page-only audition.
  KO: 디버그 탭에서 곡을 시청해도 시스템 전체의 "현재 재생 중" 상태(`/api/bgm/now`의 `id`)는
  바뀌지 않는다 — 페이지 로컬 시청일 뿐이다.
  Verify: manual — audition a track in 디버그, then `GET /api/bgm/now` from a second client and
  confirm `id` still reflects the director's actual pick, not the debug audition.

### Intent audit — P4
EN: Not independently re-verified this pass beyond static code read (BGMDBG-1 confirmed by code;
BGMDBG-2 not exercised live this run — same conclusion as prior passes, no code change touching this
tab was found). No regression evidence either way — flagged for next live pass if this area is
touched.
KO: 이번 회차에서는 정적 코드 확인 이상으로 독립 재검증하지 않았다(BGMDBG-1은 코드로 확인됨;
BGMDBG-2는 이번 실행에서 라이브로 검증하지 않음 — 이전 회차와 동일한 결론이며, 이 탭을 건드린
코드 변경은 발견되지 않았다). 양쪽 다 회귀 증거는 없음 — 이 영역이 변경되면 다음 라이브 검증
때 플래그로 남긴다.

---

## P5. App window — 대시보드 mode
**Purpose / 목적:** **EN:** activity/goal/session dashboard (`DashboardContent.swift`) — the productivity tracking + goal-management surface, now rendered in-window (no browser); the "everything about your goals and sessions" view. **KO:** 활동/목표/세션 대시보드(`DashboardContent.swift`) — 생산성 추적과 목표 관리를 담당하는 화면으로, 이제 브라우저 없이 창 안에서 렌더링된다. 목표와 세션에 관한 모든 것을 보여주는, 목표·세션·활동을 관리하는 메인 화면.

- **DASH-1 — purely visual while the window is open (no audio of its own).**
  EN: The 대시보드 mode contributes ZERO audio; all audible BGM comes from the persistent BGM
  webview underneath (see WINLIFE-3). Switching to 대시보드 must not start, stop, or restart any
  audio.
  KO: 대시보드 모드 자체는 소리를 내지 않는다 — 들리는 BGM은 전부 아래 지속형 BGM webview에서
  나온다. 대시보드로 전환해도 오디오가 시작/정지/재시작되면 안 된다.
  Verify: see WINLIFE-3's simultaneous-audibility check (same evidence covers this page).
- **DASH-2 — view tabs render independently, one active view at a time.**
  EN: `VIEW_DEFS` (목록/그룹/테이블/토큰/일정/프리뷰/스프린트/아카이브/히스토리) — exactly one
  view's DOM is populated at a time (`fillActiveView`); others are blanked to avoid element-id
  collisions (`tt_<id>`, `ev_<id>` are shared across 목록/그룹).
  KO: 뷰 탭(목록/그룹/테이블/토큰/일정/프리뷰/스프린트/아카이브/히스토리) 중 한 번에 하나의 뷰만
  DOM을 채우고, 나머지는 비워 요소 id 충돌(목록/그룹이 공유하는 `tt_<id>`, `ev_<id>`)을 막는다.
  Verify: `DashboardContent.swift:2502 VIEW_DEFS`, `2581 fillActiveView`.
- **DASH-3 — the left-rail 스킬/에이전트 overlays are mutually exclusive (only one on top).**
  EN: The left rail's "🧩 스킬" and "🤖 에이전트" links each open a full-screen overlay
  (`#cmSkOverlay` z-index 80, `#cmAgOverlay` z-index 81) over the dashboard. Opening one MUST close
  the other first. If both are left with `display:flex` at the same time, the higher z-index
  overlay (에이전트) visually and functionally covers the lower one (스킬) — every click on the
  covered overlay (its close button, its skill rows) is intercepted by the overlay on top, so the
  user cannot interact with it at all ("스킬을 누르면 안눌림").
  KO: 좌측 레일의 "🧩 스킬"과 "🤖 에이전트" 링크는 각각 대시보드 위에 전체화면 오버레이를 연다
  (`#cmSkOverlay` z-index 80, `#cmAgOverlay` z-index 81). 하나를 열면 반드시 다른 하나를 먼저 닫아야
  한다. 둘 다 `display:flex`로 동시에 남아 있으면, z-index가 더 높은 오버레이(에이전트)가 아래
  오버레이(스킬)를 시각적으로도 기능적으로도 덮어버려 — 덮인 오버레이의 모든 클릭(닫기 버튼, 스킬
  행)이 위 오버레이에 가로채여 사용자가 전혀 조작할 수 없다("스킬을 누르면 안눌림").
  Verify: `SessionRail.swift:295-296 cmSkillsOpen`, `:535-536 cmAgentsOpen` — neither calls the
  other's close function. Repro: Playwright — click `#cmRailAgents`, then click `#cmRailSkills`;
  both overlays report `display:flex`, and `elementFromPoint` over the skill overlay's close button
  and first `.cmsk-row` resolves to `.cmag-head`/`.cmag-card` (the agents overlay), not the skill
  overlay's own elements.
  History: found 2026-07-05 from a user bug report ("에이전트 페이지에서 -> 스킬을 누르면
  안눌림") — REGRESSION-class UI defect, not yet fixed as of this SPEC entry.
- **DASH-4 — thin custom scrollbars everywhere (no default thick macOS bar).**
  EN: A global `*::-webkit-scrollbar` rule set (8px, rounded thumb, transparent track,
  `scrollbar-width:thin`) applies to every scrollable area — `.chatbody`, `.modal-box`, `.popup`,
  textareas, and the page body itself — instead of falling back to WKWebView's default thick
  scrollbar.
  KO: 전역 `*::-webkit-scrollbar` 규칙(8px, 둥근 손잡이, 투명 트랙, `scrollbar-width:thin`)이
  `.chatbody`, `.modal-box`, `.popup`, textarea, 페이지 본문 등 스크롤 가능한 모든 영역에 적용되어
  WKWebView 기본 두꺼운 스크롤바로 폴백하지 않는다.
  Verify: `DashboardContent.swift` style block, `*::-webkit-scrollbar*` rules right after `:root`.
  Confirmed served correctly via `curl` of `/` (rule text present, verbatim) and CSS brace-balance
  checked (451 open / 451 close after the change) 2026-07-06.
- **DASH-5 — responsive narrow-width layout (native window resized narrow, e.g. side-by-side
  with another app).**
  EN: Below 720px width the fixed left rail (`SessionRail.swift`, normally reserving 240px via
  `body{padding-left:var(--cmrail-w)}`) auto-collapses (reusing its existing `cmrail-collapsed`
  slide-out + `☰` toggle) so content gets the full narrow width; `.wrap` padding shrinks; the header
  wraps at word boundaries (never per-character) via `min-width:0` on flex children +
  `overflow-wrap`; the view-tab bar and sprint-group header scroll horizontally (`overflow-x:auto`,
  `white-space:nowrap`) rather than wrapping mid-label, so the self-check harness's "no th/.btn/
  .chip 2-line-wrap" invariant (`runQaAudit`, ~line 4106) still holds; fixed min-width rows (bar
  names, schedule rows) shrink instead of forcing overflow. Below 480px the 5-card summary row
  stacks to 1-per-row (720px breakpoint: 2-per-row). Desktop width (the native window's normal
  size) is unaffected — the media queries only apply below the breakpoints.
  KO: 720px 미만에서는 고정 좌측 레일(`SessionRail.swift`, 평소 `body{padding-left:var(--cmrail-w)}`
  로 240px를 예약)이 기존 `cmrail-collapsed` 슬라이드아웃 + `☰` 토글을 재사용해 자동으로 접혀 콘텐츠가
  좁은 너비를 온전히 쓴다. `.wrap` 패딩이 줄고, 헤더는 flex 자식에 `min-width:0` + `overflow-wrap`을
  적용해 단어 단위로 줄바꿈되며(글자 단위 줄바꿈 금지), 뷰탭바와 스프린트 그룹 헤더는 줄바꿈 대신
  가로 스크롤(`overflow-x:auto`, `white-space:nowrap`)되어 self-check 하니스(`runQaAudit`, ~4106줄)의
  "th/.btn/.chip 2줄 줄바꿈 금지" 불변식이 계속 유지된다. 고정 min-width 행(바 이름, 일정 행)은
  overflow 대신 줄어든다. 480px 미만에서는 카드 5개 요약 행이 1열로 쌓인다(720px 구간은 2열).
  데스크톱 너비(네이티브 창의 평상시 크기)는 미디어 쿼리 임계값 아래에서만 적용되므로 영향받지 않는다.
  Verify: isolated instance, 2026-07-06, real mouse-drag resize (not Accessibility `set size`,
  which doesn't route through `NSWindow.frame`) of the native window to 640px and 441px CSS-pixel
  widths (confirmed via `/api/debug/snapshot` PNG pixel dimensions at 2x = 1280x1800 and 882x1800).
  `runQaAudit`'s published result (`GET`-able via the app; read directly from
  `<CM_DATA_DIR>/qa-audit.json` in this run) reported `{"width":640,"issues":[]}` and
  `{"width":441,"issues":[]}` — zero wrap/overflow findings at either width. At 1141px (above the
  720px breakpoint) the full sidebar and all 9 view tabs render on one row exactly as at the
  original 1040px default, confirming no desktop regression.
- **DASH-6 — goal-to-goal LINK model (flat display, link-following export).**
  EN: A goal may LINK to another goal (`Goal.links: [String]`, source-side). Creating a link
  PROMOTES the source to top-level (`parent=""`) and records the link; idempotent; `POST
  /api/goal/link` returns `{"ok":false,"error":"self"}` when `id==target` and `"not-found"` for a
  missing goal. Display hierarchy stays flat 1-level — the `setParent` flat guards
  (`ReviewStore.swift:703-715/721-740`) are UNCHANGED; a goal that still has children silently
  no-ops when `/api/goal/parent` tries to make it a child. Rows with links are meant to show a link
  dot; only export/compression follows links.
  KO: 한 목표는 다른 목표로 링크할 수 있다(`Goal.links`, 소스 쪽 기록). 링크를 만들면 소스가
  최상위로 승격되고(`parent=""`) 링크가 기록되며 멱등이다; `POST /api/goal/link`는 `id==target`이면
  `{"ok":false,"error":"self"}`, 없는 목표면 `"not-found"`를 반환한다. 화면 계층은 1단계 평면
  그대로다 — `setParent` 평면 방어(`ReviewStore.swift:703-715/721-740`)는 변경 없음; 아직 자식이
  있는 목표를 `/api/goal/parent`로 자식으로 만들려 하면 조용히 무시된다. 링크가 있는 행에는 링크
  점이 표시되어야 하며, 링크는 내보내기(압축)에서만 따라간다.
  Verify: isolated instance 2026-07-06 — seeded goal-01/goal-233(has child goal-240)/goal-99.
  `POST /api/goal/link {"id":"g-233","target":"g-01"}` -> `{"ok":true}`; on-disk `goals.json` shows
  `g-233.parent==""`, `g-233.links==["g-01"]`. Repeating the same call -> `{"ok":true}`, `links`
  stays `["g-01"]` (idempotent, confirmed via disk read, not duplicated). `{"id":"g-01","target":
  "g-01"}` -> `{"ok":false,"error":"self"}`. `{"id":"g-01","target":"g-nonexistent"}` and
  `{"id":"g-nonexistent","target":"g-01"}` both -> `{"ok":false,"error":"not-found"}`. `POST
  /api/goal/unlink {"id":"g-01","target":"g-233"}` -> `{"ok":true}`, removes `g-233` from
  `g-01.links` without touching `parent` (Q2 one-way, confirmed). `POST /api/goal/parent
  {"id":"g-233","parent":"g-01"}` while `g-233` still parents `g-240` -> goals.json unchanged
  (`g-233.parent` stays `""`) — flat guard intact (PASS, DASH-6 backend contract holds).
  **RESOLVED (2026-07-06, round 2):** `AppDelegate.swift` (`reviewJSON()`, the hand-built string
  serializer backing `GET /data.json`, ~line 2177) now emits `let links = g.links.map { jsonString($0)
  }.joined(separator: ",")` and includes `"links":[\(links)],` right after `"parent"` in the goal
  object. Re-verified on a fresh isolated instance: after `POST /api/goal/link
  {"id":"g-233","target":"g-01"}`, the raw `/data.json` wire bytes for goal-233 now read
  `"parent":"","links":["g-01"],"status":...` (previously the key was entirely absent); a goal with no
  links (`g-01` itself) serializes `"links":[]`. The link-dot row indicator
  (`DashboardContent.swift:2570`) now renders — a WKWebView snapshot of the 목록 view shows the 🔗 chip
  on goal-233's row where it was missing before. The OLD 프리뷰-tab client JS export
  (`buildMarkdown`/`renderReport`, `:4139`/`:4163`) also now receives real `links` data through the
  same payload (not independently re-verified this round, but it reads the same `/data.json` field
  that is now confirmed populated).
  KO: **해결됨(2026-07-06, 2라운드):** `AppDelegate.swift`(`reviewJSON()`, `GET /data.json`을 만드는
  손수 작성 문자열 직렬화기, ~2177줄)가 이제 `let links = g.links.map { jsonString($0)
  }.joined(separator: ",")`를 만들고 `"parent"` 바로 뒤에 `"links":[\(links)],`를 포함한다. 새 격리
  인스턴스에서 재검증: `POST /api/goal/link {"id":"g-233","target":"g-01"}` 후 goal-233의 실제
  `/data.json` 원본 바이트가 `"parent":"","links":["g-01"],"status":...`로 나옴(이전에는 키 자체가
  없었음); 링크가 없는 목표(`g-01`)는 `"links":[]`로 직렬화됨. 링크 점 행 표시
  (`DashboardContent.swift:2570`)도 이제 렌더됨 — 목록 뷰 WKWebView 스냅샷에서 goal-233 행에 🔗 칩이
  보임(이전엔 없었음). 구 프리뷰 탭 클라이언트 JS 내보내기(`buildMarkdown`/`renderReport`,
  `:4139`/`:4163`)도 같은 payload를 읽으므로 이제 실제 `links` 데이터를 받는다(이번 라운드에서
  독립적으로 재검증하진 않았으나, 지금 채워짐이 확인된 동일 `/data.json` 필드를 읽는다).
  History: found 2026-07-06 by lion-condition-mate-worker-qa during the goal-link-and-generic-queue Phase 4 QA pass;
  fixed same day and re-verified PASS by lion-condition-mate-worker-qa in fix-loop round 2.
- **DASH-7 — generic async queue tab (generalized AI 큐); dedup review lives ONLY here.**
  EN: `VIEW_DEFS` includes `{k:'queue',t:'큐'}` (`DashboardContent.swift:2606`). The 큐 tab
  (`#queueView` / `#queueHost`) is the SOLE home of the AI 큐 review UI — confirmed the inline
  `#aiQueue` box is fully gone from `#inputView` (zero matches for `id="aiQueue"` in the served
  HTML). The tab lists every `aiQueue` job (`jobKind ∈ {dedup, linkmap, …}`) with status
  (`pending/analyzing/ready`), result (`resultHTML`) or `error`+재시도. Legacy dedup items (no
  `jobKind` on disk) decode `jobKind=="dedup"` and keep their 추가/수정/스킵 flow unchanged, now
  rendered inside `#queueView`. The "AI 추가"/`aiAdd()` field stays in `#inputView` and still POSTs
  `/api/goal/queue/enqueue`; only the review surface moved. An empty `aiQueue` renders a defined
  empty-state string ("큐가 비어 있습니다…"). The worker (`aiWorkerRunning` guard, `kickAIQueueWorker`/
  `drainAIQueue`) stays single-serial; `dedup` jobs take the unchanged `aiDedupVerdict` path, other
  `jobKind`s go through `runQueueJob`/`completeJob`.
  KO: `VIEW_DEFS`에 `{k:'queue',t:'큐'}`가 있다(`DashboardContent.swift:2606`). 큐 탭
  (`#queueView`/`#queueHost`)이 AI 큐 리뷰 UI의 유일한 자리다 — `#inputView`에서 인라인 `#aiQueue`
  박스가 완전히 사라졌음을 확인(서빙된 HTML에 `id="aiQueue"` 매치 0건). 큐 탭은 모든 `aiQueue` 작업을
  상태와 함께 나열하고 결과(`resultHTML`) 또는 오류+재시도를 보여준다. 레거시 dedup 항목(디스크에
  `jobKind` 없음)은 `jobKind=="dedup"`으로 디코드되어 추가/수정/스킵 흐름이 그대로 유지되며, 이제
  `#queueView` 안에서 렌더된다. "AI 추가"/`aiAdd()` 입력은 `#inputView`에 남아 여전히 `/api/goal/queue/
  enqueue`로 POST하고, 리뷰 화면만 옮겨졌다. 빈 `aiQueue`는 정의된 빈 상태 문자열을 보여준다.
  워커(`aiWorkerRunning` 가드, `kickAIQueueWorker`/`drainAIQueue`)는 계속 직렬이며, dedup 작업은 기존
  `aiDedupVerdict` 경로를, 그 외 종류는 `runQueueJob`/`completeJob` 경로를 탄다.
  Verify: isolated instance 2026-07-06 — seeded a legacy `ai-queue.json` item with NO `jobKind` key;
  `/data.json`'s `aiQueue[0].jobKind=="dedup"` (backward-compat confirmed). Fetched `/` and grepped
  for `id="queueView"` (1), `id="queueHost"` (1), `id="aiQueue"` (0), `id="inputView"` (1) — the
  queue box is structurally gone from the input view and `#queueView`/`#queueHost` exist exactly
  once each (no duplicate real DOM ids; a naive regex found 4 apparent "duplicates" but all were JS
  template-literal source text like `'+it.id+'` inside `<script>`, not actual HTML attributes).
  `POST /api/queue/retry {"id":"<existing>"}` -> `{"ok":true}`, item flips to pending then back to
  ready (worker re-ran it); `{"id":"nope"}` -> `{"ok":false,"error":"not-found"}`. `POST
  /api/queue/remove` on an existing ready item -> `{"ok":true}` and removed from `/data.json`;
  on a missing id -> `{"ok":false,"error":"not-found"}`. Malformed POST bodies (non-JSON garbage,
  wrong types, empty body) to `/api/goal/link` and `/api/queue/retry` all returned `200` with a
  graceful `{"ok":false,...}` and the server stayed responsive afterward (no crash, no hang).
  **RESOLVED (2026-07-06, round 2):** `DashboardContent.swift:14`'s server-side `lastView` clamp set
  now includes `"queue"` — `["input","group","table","token","queue","schedule","preview","sprint",
  "archived","history"]`. Re-verified on a fresh isolated instance: `POST /api/prefs/view
  {"view":"queue"}` -> `{"ok":true}`, then re-fetching `GET /` now injects `let _view='queue'`
  (previously silently reset to `'input'`) — a user who leaves the dashboard on the 큐 tab and
  restarts the app (or the window reloads `/`) is now correctly restored to the 큐 tab.
  KO: **해결됨(2026-07-06, 2라운드):** `DashboardContent.swift:14`의 서버측 `lastView` 허용 목록에
  이제 `"queue"`가 포함된다 — `["input","group","table","token","queue","schedule","preview",
  "sprint","archived","history"]`. 새 격리 인스턴스에서 재검증: `POST /api/prefs/view {"view":
  "queue"}` -> `{"ok":true}`한 뒤 `GET /`를 다시 받으면 이제 `let _view='queue'`가 주입됨(이전엔
  조용히 `'input'`으로 되돌아갔음) — 큐 탭을 보던 중 앱을 재시작하거나 창이 `/`를 다시 로드해도 이제
  올바르게 큐 탭으로 복원된다.
  History: found 2026-07-06 by lion-condition-mate-worker-qa during the goal-link-and-generic-queue Phase 4 QA pass;
  fixed same day and re-verified PASS by lion-condition-mate-worker-qa in fix-loop round 2.
- **DASH-8 — "내보내기" runs as a queued linkmap job (link-aware, cycle-safe).**
  EN: `POST /api/queue/enqueue-linkmap {root}` enqueues a `jobKind:"linkmap"` job and returns
  immediately (`{"ok":true,"id":...}`); it does NOT call `claude -p` — the runner
  (`AppDelegate.swift:runLinkmapJob`, off-main via the single serial `drainAIQueue`) is a
  deterministic Swift walk over `reviewStore.goals` (NOT `/data.json`, so it is unaffected by the
  DASH-6 `links`-serialization gap above). It walks parent-children (solid edges) then `links`
  (purple dashed edges) from the root with a `visited` id-set, so a deliberate cycle
  (`goal-01 -> goal-233 -> goal-01`) terminates — each goal is emitted into the map/export exactly
  once, and the second time a visited node is reached again the walk records a
  "링크 순환/중복" warning in the summary instead of recursing. The compressed export marks a linked
  section `## ↗ goal-NN (링크됨)` and nests that goal's own parent-children as bullets under it. No
  `claude -p` call anywhere in the runner, so `CM_SUPPRESS_SESSION_GOAL` is structurally moot (the
  goal count is provably unchanged after a run — no session-mirroring risk exists for this job kind).
  KO: `POST /api/queue/enqueue-linkmap {root}`는 `jobKind:"linkmap"` 작업을 큐에 넣고 즉시 반환한다
  (`{"ok":true,"id":...}`); `claude -p`를 전혀 호출하지 않는다 — 러너(`AppDelegate.swift:
  runLinkmapJob`, 단일 직렬 `drainAIQueue`에서 off-main 실행)는 `reviewStore.goals`를 직접 도는
  결정적 Swift 워크다(`/data.json`이 아니므로 위 DASH-6의 `links` 직렬화 공백에 영향받지 않는다).
  루트에서 부모-자식(실선)을 먼저, 그다음 `links`(보라 점선)를 `visited` id-집합으로 걸어가므로 의도적
  사이클(`goal-01 -> goal-233 -> goal-01`)이 종료된다 — 각 목표는 지도/내보내기에 정확히 한 번만
  나타나고, 이미 방문한 노드에 다시 도달하면 재귀하는 대신 요약에 "링크 순환/중복" 경고를 남긴다.
  압축 내보내기는 링크된 섹션을 `## ↗ goal-NN (링크됨)`로 표시하고 그 목표의 부모-자식을 그 아래
  불릿으로 중첩한다. 러너 어디에도 `claude -p` 호출이 없어 `CM_SUPPRESS_SESSION_GOAL`은 이 작업
  종류에서 구조적으로 무의미하다(실행 후 목표 개수가 늘지 않음을 직접 확인 — 세션-미러링 위험 자체가
  없다).
  Verify: isolated instance 2026-07-06 — linked `g-233.links=["g-01"]` then ALSO `g-01.links=
  ["g-233"]` (deliberate cycle) and `POST /api/queue/enqueue-linkmap {"root":"g-01"}` ->
  `{"ok":true,"id":"B62DEA00-..."}` returned immediately; polling `/data.json` ~2s later showed the
  job already `status:"ready"` (no LLM round-trip, deterministic). The `resultHTML` (2388 bytes)
  contains: summary "포함 3개 · 링크 홉 2 · 경고 1건: goal-233 ↗ goal-01 (링크 순환/중복)"; an inline
  SVG with a solid blue path (`stroke="#5b8cff"`, no dasharray) for the goal-01->goal-240 parent-child
  edge and TWO purple dashed paths (`stroke="#9b7bff" stroke-dasharray="5 4"`) for the two link edges;
  exactly 3 node `<rect>` boxes (goal-01/233/240, no duplicates); and the export markdown block
  containing `## ↗ goal-233 (링크됨) — goal-233 has a child (진행)` with `- goal-240 …` nested under
  it. Goal count before/after the run: 4 -> 4 (no mirrored session goal, confirms the
  no-claude-p/no-CM_SUPPRESS_SESSION_GOAL-risk claim above). `enqueue-linkmap` with a nonexistent
  root (`{"root":"g-doesnotexist"}`) or missing root (`{}`) both -> `{"ok":false,"error":"not-found"}`
  (guarded before the job is even created). All PASS.
  Note: the spec draft (`docs/specs/goal-link-and-generic-queue.md` Phase 3) originally described
  extending the CLIENT-side JS `buildMarkdown`/`renderReport` (the 프리뷰-tab export) to follow
  links; the SHIPPED implementation instead built an entirely separate SERVER-side deterministic
  renderer (`runLinkmapJob`/`buildLinkmapMapHTML`/`buildLinkmapExportMarkdown`) that never touches
  `buildMarkdown`/`renderReport` at all. This satisfies every DASH-8 acceptance criterion (link-aware,
  cycle-safe, async, non-blocking) but means the OLD 프리뷰-tab export (still reachable from the
  프리뷰 view) remains link-BLIND (and is additionally starved of `links` data by the DASH-6 gap
  above) — two independent export code paths now exist with different link-awareness. Not itself a
  failed acceptance criterion (Q4 scoped export to "one root goal's link chain," which the linkmap
  job delivers), but worth the user's attention as a design fork.
  KO: 스펙 초안(`docs/specs/goal-link-and-generic-queue.md` Phase 3)은 원래 클라이언트 JS
  `buildMarkdown`/`renderReport`(프리뷰 탭 내보내기)를 확장해 링크를 따라가게 하는 안이었으나, 실제
  구현은 `buildMarkdown`/`renderReport`를 전혀 건드리지 않는 완전히 별도의 서버측 결정적 렌더러
  (`runLinkmapJob`/`buildLinkmapMapHTML`/`buildLinkmapExportMarkdown`)를 만들었다. 이는 DASH-8의
  모든 수용 기준(링크 인식·사이클 안전·비동기·논블로킹)을 충족하지만, 기존 프리뷰 탭 내보내기(여전히
  프리뷰 뷰에서 접근 가능)는 여전히 링크를 인식하지 못한 채로 남는다(게다가 위 DASH-6 공백으로 링크
  데이터 자체를 못 받는다) — 링크 인식 수준이 다른 두 개의 독립된 내보내기 경로가 생겼다. 그 자체가
  수용 기준 실패는 아니지만(Q4가 내보내기 범위를 "단일 루트 목표의 링크 체인"으로 한정했고 linkmap
  잡이 이를 충족함), 설계가 갈라졌다는 점은 사용자가 알아야 한다.
  History: DASH-6/7/8 added 2026-07-06 by lion-condition-mate-worker-qa, Phase 4 QA pass for
  `docs/specs/goal-link-and-generic-queue.md`. Backend contract (link/unlink/idempotency/self/
  not-found, setParent guard, backward-compat, single-serial worker, retry/remove, linkmap cycle
  safety, non-blocking enqueue) all PASS. Two gaps found and reported (DASH-6 `/data.json` missing
  `links`; DASH-7 `lastView` clamp missing `"queue"`) — both fixed same day and RE-VERIFIED PASS by
  lion-condition-mate-worker-qa in fix-loop round 2 (see RESOLVED notes above).

- **DASH-9 — AI 큐 연관성 검색은 콘텐츠 실체(transcript/issue 폴더 근거)를 제목 유사도보다 우선한다.**
  KO: AI 큐 연관성 검색은 콘텐츠 실체(transcript/issue 폴더 근거)를 제목 유사도보다 우선한다. 제목만
  일치하고 내용 근거가 없는 '껍데기' 목표는 추천하지 않는다. 루틴이 명시한 목표 번호가 실제 목표에
  매핑되면 유사 후보로 노출한다. 나아가 판정은 부모를 찾는 데 그치지 않고 **관계 종류**를 분류한다:
  (a) 기존 목표 작업의 **반복 실행(recurring-execution)** → "#N의 task로 이번 회차 추가"를 추천,
  (b) 기존 목표 영역의 **하위 문제/개선(sub-problem)** → "#N 아래 서브 목표로 추가"를 추천,
  (c) **무관(unrelated)** → "별도 새 목표로 추가"를 추천. 추천 옵션 밑에는 항목 자체의 의도에서
  도출한 **관리형 다음 단계** 한 줄(예: 리포트 공유 자동화)을 함께 노출한다.
  EN: The AI-queue relatedness search ranks CONTENT substance (a real session transcript and/or a
  non-empty `issue/goal-NN/` folder with keyword hits) ABOVE title similarity. A "hollow" goal —
  a title with no content evidence (empty transcript AND empty folder) — is never recommended on the
  strength of a title echo. A goal number the routine text explicitly names, when it maps to a live
  goal, is surfaced as a similar candidate (a SECONDARY clue, never the sole auto-recommendation).
  The judge classifies the RELATIONSHIP, not just the parent: recurring-execution → recommend adding
  as a `task` under #N; sub-problem/improvement → recommend adding as a `sub-goal` under #N;
  unrelated → recommend a stand-alone new goal. A one-line managed NEXT STEP (inferred from the
  item's own intent) is surfaced under the recommended option.
  Mechanism: `RelatedGoalSearch` (retrieval) exposes per-candidate artifact/transcript hit counts and
  a structural `hollow` flag (`isHollow`/`hollowSeqs`), reserves a candidate slot for the top
  artifact-owner goal so it bypasses topN/cutoff, sqrt-normalizes transcript-vs-artifact raw counts,
  and no longer loses the routine tail (removed `"일일"` stopword, script-boundary splitting for glued
  `NSS일일리포트`, keyword cap 12→24). `referencedSeqs(from:existing:)` parses `#240`/`240번`/`goal 240`
  and a bare `240` only when it maps to an existing seq and is NOT glued to a unit char in
  `[시원월일분초%개년명]` (so `11시`, `7월4일` yield none). The judge prompt (`AppDelegate.aiDedupVerdict`)
  gets a hollow-annotated goal list + an ALREADY-EXISTS EVIDENCE block with a SUBSTANCE RULE and both
  worked examples, and `RelatedGoalSearch.reconcile(...)` deterministically post-merges the verdict:
  a hollow title echo is flipped to the content-substantive / user-referenced goal, the recommended
  action is derived from the relationship, and referenced + top-content goals are unioned into
  `matches` so the user always SEES them. The 큐 card (`DashboardContent.swift`) binds the 추천 badge to
  the reconciled `relation`/`matches[0]`.
  Regression anchors (deterministic level — the final LLM pick is nondeterministic, so tests assert
  retrieval + reconciliation only, never invoking `claude -p`):
  A) Routine `"…NSS 일일리포트 공유 (240 주정산지급 루틴)"` — the string is verbatim #291's TITLE, but
  `issue/goal-291/` is EMPTY (hollow). #240 (folder saturated: nss/주정산/입금/리포트) MUST surface and
  be the recommended parent as a `task`; #291 MUST be flagged hollow and MUST NOT be forced as the
  sole parent.
  B) `goal-507` (`"NSS 일일 리포트 … 로그인 형태로 외부에서 접속 … 공유 문제해결"`) — same NSS-daily-report
  family as #240 but a distinct sub-problem, MUST be classified sub-problem → recommended as a
  `sub-goal` under #240 with a report-sharing-automation next-step note.
  Verify: `Scripts/run-unit-tests.sh --filter RelatedGoalSearchTests` → 10/10 PASS
  (`tests/RelatedGoalSearchTests/`): keyword mining keeps `일일리포트`; `discover` returns #240; #291
  flagged hollow; `referencedSeqs` → `[240]` with `11시`/`7월4일`→none; judge evidence contains a #240
  line and marks #291 껍데기; reconcile rebinds hollow #291→#240 task (anchor A) and files goal-507
  under #240 as a sub-goal with the next-step surfaced (anchor B); ordinary no-signal cases unchanged.
  History: DASH-9 added 2026-07-13 (content-substance cascade + relationship-aware next action).

- **DASH-10 — 토큰 뷰 세션 행은 그 세션이 쓴 모델의 창 크기와 최종 창 점유율을 보인다
  (added 2026-09-04).**
  EN: Each session row in the 토큰 뷰 drill-down carries a leading chip `창 <window> · <pct>%`,
  placed immediately before the existing composition string (`컨 77(재 …`). The two are DIFFERENT
  axes and must not be read as one: `컨 %` is the token COMPOSITION (prompt share of that session's
  total spend), while the chip is WINDOW OCCUPANCY. Numerator = the prompt actually loaded into the
  window on ONE assistant request, `input_tokens + cache_read_input_tokens +
  cache_creation_input_tokens`, taken at that session·day's LAST non-sidechain assistant request.
  Denominator = that request's model's context window. Subagent (`isSidechain: true`) lines are
  EXCLUDED from this axis only — they carry their own context, so counting them would charge the
  parent a window it never filled; token totals and $-cost keep including sidechain, because that is
  money actually spent. The peak occupancy of the same day is tracked alongside and appended as
  `(최대 <peakPct>%)` only when it differs from the final. Color is the whole point — routing must be
  skimmable: `pct >= 80` → `#e5534b`, `50 <= pct < 80` → `#d29922`, below 50 stays `.muted`. A model
  whose published window is unknown (`glm-*`) renders `창 — · <absolute tokens>`; no number is
  invented. A cached/old `/tokens-sessions.json` response has no `ctxFinal`, and the client then
  draws NO chip at all (`s.ctxFinal == null` → `''`) — coercing the missing value to 0 would render
  `0%`, which asserts "the window was empty" and is a lie. The day row and the period summary carry
  the distribution instead of one session: `창 점유 중앙 <ctxMedPct>% · 80%↑ <ctxHighN>개`, omitted
  whole when no session on that day has a known window.
  KO: 토큰 뷰의 세션 행 맨 앞에 `창 <크기> · <퍼센트>` 칩이 붙는다. 옆의 `컨 77%`는 **구성비**이고
  이 칩은 **창 점유**라서 축이 다르다 — 섞어 읽으면 안 된다. 분자는 그 세션·그날의 마지막
  (비-sidechain) 어시스턴트 요청 하나에 실린 프롬프트 총량
  (`input + cache_read + cache_creation`)이고, 분모는 그 요청 모델의 컨텍스트 윈도우다. 누적
  `spent`를 분자로 쓰지 않는다 — 그것은 "창을 몇 번 채웠나"이지 "얼마나 채웠나"가 아니다.
  서브에이전트 줄은 자기 컨텍스트를 따로 가지므로 이 축에서만 제외한다(토큰 합계·비용은 실제로
  나간 돈이므로 지금대로 포함). 같은 날 피크가 최종과 다르면 `(최대 …%)`를 덧붙인다. 색은 3단
  (80%↑ `#e5534b`, 50–80% `#d29922`, 미만 `.muted`) — 라우팅 결론이 색 하나로 끝나야 한다.
  창 크기를 모르는 모델은 `창 — · <절대 토큰>`으로 두고 숫자를 지어내지 않는다. 옛 응답
  (`ctxFinal` 없음)에는 칩을 아예 그리지 않는다. 일 행·기간 요약에는 세션 하나가 아니라 분포
  (`창 점유 중앙 …% · 80%↑ …개`)를 적고, 창을 아는 세션이 하나도 없으면 조각을 통째로 뺀다.
  Mechanism: server-side (see EP-19) — `AppDelegate.contextWindow(forModel:)` /
  `resolvedWindow(model:peak:)` own the table and the escalation, `DayTok.ctxFinal/ctxPeak/ctxModel`
  own the per-day values, and the client only draws. `DashboardContent.tkCtxWinStr(s)` renders the
  chip (null-guarded exactly like the existing `d.reloadTok == null` guard), `tkCtxDistStr(d)`
  renders the day/period distribution, and the legend paragraph under `일별 토큰 사용량` states that
  `창` is the model's context window, that `%` divides the final request's prompt total by it (NOT
  the composition next to it), and that the window escalates to 1M when an observed session exceeds
  the published default.
  Verify: directive `issue/2026-09-04-context-window-usage-directive.md`; `swift build` clean
  (2026-09-04, 143 tasks, 64.7s). Regression anchor for the 1M escalation — session `53c8820a`
  (`claude-opus-5`, ctxFinal = ctxPeak = 823,490): the published 200K default would render 411.7%,
  and `resolvedWindow` lifts the window to 1,000,000 so the chip reads `창 1M · 82.3%` (red band).
  Offline replay of the exact table + escalation rule over all 1,884 transcripts under
  `~/.claude/projects` (2026-09-04): 1,735 sessions carry context, 1,723 resolve a window, **0**
  exceed 100%, median 32.4%, 221 sessions at ≥80%. The 12 unresolved rows are all `glm-5.3-flash`
  and render `창 —`. Final≠peak is real and the `(최대 …%)` branch is exercised — live-rendered
  2026-09-04 by executing the served dashboard script against the running server's
  `/tokens-sessions.json?day=2026-09-04`: `6e696696` (`claude-opus-5`, ctxFinal 313,393 / ctxPeak
  343,949 / ctxWin 1,000,000) renders `창 1M · 31%(최대 34%)` in the `.muted` band. **Percents carry
  one decimal ONLY below 10%** (`pct<10? toFixed(1) : round`) — a routing decision never turns on
  0.3 percentage points, but a 3% session must not read `0%` — so `cb865437` (117,301 after peaking
  at 409,470) renders `창 1M · 12%(최대 41%)`, NOT `11.7%`. Same live render, 88 session rows on that
  day: 70 chips drawn, 12 red (`#e5534b`) + 8 amber (`#d29922`) — the red count equals that day's
  `ctxHighN` — the chip sits before `컨 …` inside the same session line, the 8 `glm-5.3-flash` rows
  read `창 — · 116K` (no invented number), and the 18 antigravity rows draw no chip. Re-rendering the
  identical payload with every `ctx*` key deleted (pre-change response shape) draws 0 chips, no `창`,
  no `0%`, and the day/period distribution fragment disappears whole.
  History: DASH-10 added 2026-09-04 (모델 라우팅 판단을 위해 창 점유 축 신설).

### Intent audit — P5
EN: **REGRESSION-CLASS FINDING (spec drift, confirmed):** the old A1 item's documented "third audio
source" — the dashboard's own in-page "BGM 관리" tab as a lazy-loaded `<iframe id="bgmFrame">` of
`/bgm-player` — **no longer exists in `DashboardContent.swift`.** Confirmed by:
`grep -n "bgmFrame" Sources/ConditionMate/Dashboard/DashboardContent.swift` → no matches;
`VIEW_DEFS` (`DashboardContent.swift:2502-2506`) lists only
`input/group/table/token/schedule/preview/sprint/archived/history` — no `bgm` key, so `_view` can
never equal `'bgm'`. The dashboard's BGM surface today is exclusively the native window's `.bgm`
mode (P3/P4), not an in-page iframe. This is intentional-looking (superseded by the
two-persistent-webview native-window design, `agent-update-log.jsonl` 2026-07-05 05:16:41 entry) but
was **never explicitly retired in SPEC.md** until this rewrite, and `BGMPlayerContent.swift:276-277`
still comments as if `bgmFrame` exists — a live drift risk for the next contributor. Retired here;
the `EMBEDDED` guard in `BGMPlayerContent.swift` is now dead-but-harmless defense-in-depth (it would
only matter if `/bgm-player` were loaded in some other iframe in the future).
KO: **회귀급 발견(스펙 드리프트, 확인됨):** 예전 A1 항목이 기록한 "제3의 오디오 출처" — 대시보드
자체의 인페이지 "BGM 관리" 탭이 `/bgm-player`를 지연 로드하는 `<iframe id="bgmFrame">` —
**는 이제 `DashboardContent.swift`에 존재하지 않는다.** 다음으로 확인함:
`grep -n "bgmFrame" Sources/ConditionMate/Dashboard/DashboardContent.swift` → 일치 없음;
`VIEW_DEFS`(`DashboardContent.swift:2502-2506`)에는 `input/group/table/token/schedule/preview/
sprint/archived/history`만 있고 `bgm` 키가 없어 `_view`가 `'bgm'`이 될 수 없다. 오늘날 대시보드의
BGM 화면은 인페이지 iframe이 아니라 오직 네이티브 창의 `.bgm` 모드(P3/P4)뿐이다. 이는 의도된
변경으로 보이나(두 개의 지속형 webview를 쓰는 네이티브 창 설계로 대체됨, `agent-update-log.jsonl`
2026-07-05 05:16:41 항목 참고) 이번 재작성 전까지 **SPEC.md에서 명시적으로 폐기 처리된 적이 없었고**,
`BGMPlayerContent.swift:276-277`은 여전히 `bgmFrame`이 존재하는 것처럼 주석이 달려 있어 — 다음
기여자에게 살아있는 드리프트 위험이 된다. 여기서 폐기 처리한다; `BGMPlayerContent.swift`의
`EMBEDDED` 가드는 이제 죽었지만 무해한 방어 코드다(`/bgm-player`가 향후 다른 iframe에 로드될
때만 의미가 있을 것이다).

EN: **GAP (2026-07-06, DASH-6/DASH-7) — RESOLVED same day, round 2:** two intent mismatches were
found in the goal-link + generic-queue feature (see full evidence under DASH-6/DASH-7 above): (1) the
backend correctly stored/persisted `Goal.links`, but the hand-built `/data.json` serializer never
emitted it, so the intended "link dot on rows with links" UI could never actually render — the code's
INTENT (show a dot) did not match its BEHAVIOR (no dot, ever, because the client never received the
data); (2) the intended "return to the 큐 tab you left open" persistence silently failed because the
server-side view-name allowlist was not updated when the tab was added. Both were narrow, mechanical
fixes (add one field to one serializer; add one string to one array) — applied and re-verified PASS
by lion-condition-mate-worker-qa in fix-loop round 2 (see the RESOLVED notes under DASH-6/DASH-7 above for the live
evidence).
KO: **공백(2026-07-06, DASH-6/DASH-7) — 같은 날 2라운드에서 해결됨:** 목표-링크 + 범용-큐 기능에서
의도-동작 불일치 두 건이 발견됐다(전체 근거는 위 DASH-6/DASH-7 참고): (1) 백엔드는 `Goal.links`를
올바르게 저장·유지했지만 손수 작성한 `/data.json` 직렬화기가 이를 전혀 내보내지 않아, "링크가 있는
행에 점 표시"라는 의도된 UI가 실제로는 절대 렌더되지 않았다 — 코드의 의도(점 표시)와 동작(데이터가
클라이언트에 안 옴 → 점 없음)이 달랐다; (2) "보던 큐 탭으로 돌아오기"라는 의도된 지속성이, 탭 추가
시 서버측 뷰-이름 허용목록을 갱신하지 않아 조용히 실패했다. 둘 다 좁고 기계적인 수정(직렬화기에
필드 하나 추가; 배열에 문자열 하나 추가)이었으며 — 적용 후 lion-condition-mate-worker-qa가 fix-loop 2라운드에서
PASS로 재검증함(라이브 근거는 위 DASH-6/DASH-7의 RESOLVED 메모 참고).

---

## P6. Server / endpoints
**Purpose / 목적:** **EN:** the loopback `DashboardServer` (`AppDelegate.swift` handlers + `Dashboard/DashboardServer.swift`) backing every page above — the data/control plane all pages talk to. **KO:** 위의 모든 페이지를 뒷받침하는 루프백 `DashboardServer`(`AppDelegate.swift` 핸들러 + `Dashboard/DashboardServer.swift`)다 — 모든 페이지가 호출하는 데이터/제어 계층.

- **EP-1 — `GET /api/bgm/now`.**
  EN: Returns `{on,playing,id,title,bpm,phase,profile,plan}`. `id=-1` when nothing resolvable;
  `plan` (added 2026-07-08) is the 전략3 plan-map slot label currently governing selection
  ("-" when the plan has a gap or BGM is off).
  KO: `{on,playing,id,title,bpm,phase,profile,plan}`를 반환. 재생 가능한 트랙이 없으면 `id=-1`.
  `plan`(2026-07-08 추가)은 지금 선곡을 지배하는 전략3 플랜 맵 슬롯 라벨(플랜 공백/BGM 꺼짐이면 "-").
  Verify: `curl http://127.0.0.1:<port>/api/bgm/now` — confirmed 2026-07-05:
  `{"on":true,"playing":true,"id":0,"title":"QA [120]","bpm":70,"phase":"WARMUP","profile":"기본"}`;
  `plan` field confirmed 2026-07-08 (isolated instance): `"plan":"QA 전용 슬롯"` reflected within one
  decision tick after a plan replace.
- **EP-2 — `GET /api/bgm/list`.**
  EN: Returns `{tracks:[{id,title,bpm}...]}` from the current library.
  KO: 현재 라이브러리의 `{tracks:[{id,title,bpm}...]}`를 반환.
  Verify: `AppDelegate.swift:bgmListJSON`.
- **EP-3 — `GET /bgm-audio/<id>` supports Range/206.**
  EN: Serves the raw track bytes; honors `Range:` with a `206 Partial Content` + correct
  `Content-Range`; negative/out-of-range/non-numeric ids -> `404`, no crash.
  KO: 원본 트랙 바이트를 서빙하며 `Range:` 헤더를 `206 Partial Content` + 정확한 `Content-Range`로
  응답한다. 음수/범위초과/숫자아닌 id는 크래시 없이 `404`.
  Verify (2026-07-05, isolated instance): `Range: bytes=1000-2000` -> `HTTP/1.1 206 Partial Content`,
  `Content-Range: bytes 1000-2000/3325998`, `Content-Length: 1001`. id `-1`, `9999`, `abc` -> all
  `404`. Process stayed alive after all four requests.
- **EP-4 — `POST /api/bgm/control {action}` and `POST /api/bgm/native {mute}`.**
  EN: Both return `{"ok":true}`; `native{mute:false}` cannot unmute while the window-open ownership
  latch is set (`audio.muted = mute || windowOwnsAudio`, see WINLIFE-3).
  KO: 둘 다 `{"ok":true}`를 반환. 창이 열려 있는 동안엔 `native{mute:false}`로도 음소거를 풀 수
  없다(`audio.muted = mute || windowOwnsAudio`).
  Verify: `AppDelegate.swift:2605-2641`; malformed body (`'not json{{'`, `'{garbage'`) -> `200`, no
  crash (confirmed 2026-07-05).
- **EP-5 — debug/test-only endpoints (`/api/debug/window-mode`, `/api/debug/window-close`).**
  EN: Exist ONLY to let QA exercise the mode-switch and user-close paths headlessly, without a real
  click; `window-mode` with an invalid mode string returns `{"ok":false}` (no crash); `window-close`
  drives the real `NSWindow.close()`.
  KO: QA가 실제 클릭 없이 모드 전환/사용자 닫기 경로를 헤드리스로 검증하기 위한 테스트 전용
  엔드포인트. 잘못된 모드 문자열은 `{"ok":false}`(크래시 없음); `window-close`는 진짜
  `NSWindow.close()`를 구동한다.
  Verify: confirmed 2026-07-05 — `{"mode":"bogus"}` -> `{"ok":false}`; `{"mode":"dashboard"}` ->
  real mode switch (see WINLIFE-3 evidence); `window-close` -> real `windowWillClose (user, …)` ->
  quit sequence (see WINLIFE-4 evidence).
- **EP-6 — `GET /api/debug/snapshot?mode=bgm|dashboard[&tab=activity|debug]` (added 2026-07-05).**
  EN: QA-only endpoint: returns a PNG (`image/png`) snapshot of the app window's WKWebView (via
  `WKWebView.takeSnapshot`), used to embed REAL per-page screenshots in `SPEC.html` (P3/P4/P5). For
  `mode=bgm`, an optional `tab=activity|debug` first calls `BGMPlayerContent.swift`'s own
  `setMode(tab)` JS function to switch the in-page sub-tab before capturing. Requires the window to
  already be open (does not open it); `404` if not open or the webview has no URL loaded yet.
  KO: QA 전용 엔드포인트. `WKWebView.takeSnapshot`으로 앱 창 웹뷰의 PNG(`image/png`) 스냅샷을
  반환하며, `SPEC.html`의 실제 페이지별 스크린샷(P3/P4/P5)에 쓰인다. `mode=bgm`일 때 `tab=activity|
  debug`를 주면 캡처 전에 `BGMPlayerContent.swift` 자체의 `setMode(tab)` JS 함수로 인페이지
  서브탭을 먼저 전환한다. 창이 이미 열려 있어야 하며(직접 열지 않음), 창이 닫혀 있거나 웹뷰가
  아직 로드되지 않았으면 `404`.
  Verify: confirmed 2026-07-05, isolated instance — `mode=bgm&tab=activity` -> `200`, PNG 2080x1368,
  886596 bytes; `mode=bgm&tab=debug` -> `200`, PNG 2080x1368, 866147 bytes (디버그 sub-tab correctly
  shown, "불러오는 중..." library state); `mode=dashboard` (after `/api/debug/window-mode
  {"mode":"dashboard"}`) -> `200`, PNG 2080x1368, 195240 bytes (목록 view correctly shown). All three
  decoded as valid PNG (magic bytes confirmed) and visually inspected — genuine, not placeholders.
- **EP-7 — `POST /api/goal/link` / `POST /api/goal/unlink` (added 2026-07-06).**
  EN: `link` promotes the source goal to top-level and appends `target` to `source.links`
  (idempotent); returns `{"ok":false,"error":"self"}` when `id==target`, `"not-found"` for a missing
  id/target on either side. `unlink` removes `target` from `source.links` only — does NOT re-parent
  (one-way, matches Q2). Both are early-return custom-JSON blocks in `AppDelegate.swift` (not the
  default `switch`-based dispatch) so they can report `self`/`not-found` distinctly.
  KO: `link`은 소스 목표를 최상위로 승격하고 `target`을 `source.links`에 추가한다(멱등); `id==target`
  이면 `{"ok":false,"error":"self"}`, 양쪽 중 하나라도 없으면 `"not-found"`를 반환한다. `unlink`는
  `source.links`에서 `target`만 제거하고 부모는 되돌리지 않는다(일방향, Q2와 일치). 둘 다
  `self`/`not-found`를 구분해 응답하기 위해 `AppDelegate.swift`의 기본 `switch` 디스패치가 아닌
  조기 반환 커스텀-JSON 블록으로 구현되어 있다.
  Verify: see DASH-6 evidence block (same isolated-instance run) — self/not-found/idempotency all
  confirmed live 2026-07-06.
- **EP-8 — `POST /api/queue/retry` / `POST /api/queue/remove` (added 2026-07-06).**
  EN: `retry` clears `error`, flips `status` back to `pending`, and kicks the single serial worker
  (`kickAIQueueWorker`) so it re-runs; `{"ok":false,"error":"not-found"}` for a missing id. `remove`
  drops a finished/errored job card; the store-level guard (`removeQueueItem`) refuses to remove an
  item still `"analyzing"` (the worker holds it) — returns `not-found` in that case too (same wire
  shape, so the client can't distinguish "missing" from "busy," which is acceptable since the UI only
  offers 재시도/닫기 on `ready` cards anyway).
  KO: `retry`는 `error`를 지우고 `status`를 `pending`으로 되돌려 단일 직렬 워커
  (`kickAIQueueWorker`)를 깨워 재실행시킨다; id가 없으면 `{"ok":false,"error":"not-found"}`. `remove`
  는 끝났거나 오류난 작업 카드를 지운다; 스토어 단 가드(`removeQueueItem`)가 아직 `"analyzing"`인
  항목은 제거를 거부한다(이 경우도 동일하게 `not-found`를 반환해 클라이언트가 "없음"과 "작업중"을
  구분하지 못하지만, UI가 애초에 `ready` 카드에만 재시도/닫기를 노출하므로 무해하다).
  Verify: isolated instance 2026-07-06 — `retry` on an existing ready job -> `{"ok":true}`, item
  cycles pending->ready again (worker re-ran, confirmed via `/data.json` polling); `retry` on a
  missing id -> `{"ok":false,"error":"not-found"}`. `remove` on an existing ready job -> `{"ok":true}`
  and the item disappears from `/data.json`'s `aiQueue`; `remove` on a missing id -> `{"ok":false,
  "error":"not-found"}`.
- **EP-9 — `POST /api/queue/enqueue-linkmap` (added 2026-07-06).**
  EN: `{"root":"<goalId>"}` -> `{"ok":true,"id":"<jobId>"}` immediately (fire-and-forget); guards a
  missing/nonexistent root BEFORE creating the job (`{"ok":false,"error":"not-found"}`), so a bad
  root never even reaches the queue. No `GET /api/queue/list` or `GET /queue/result` route was added
  in this implementation (the spec draft listed them as "only if used"; the shipped design instead
  serves `resultHTML` inline via the existing `/data.json` `aiQueue` feed and a client-side
  `window.open`/Blob-download for 보기/다운로드, so neither GET route exists to whitelist).
  KO: `{"root":"<goalId>"}` -> 즉시 `{"ok":true,"id":"<jobId>"}`(던져두고 잊기); 없는/존재하지 않는
  root는 작업 생성 전에 걸러진다(`{"ok":false,"error":"not-found"}`) — 잘못된 root는 큐에 아예
  들어가지 않는다. 이번 구현에는 `GET /api/queue/list`나 `GET /queue/result` 라우트가 추가되지
  않았다(스펙 초안은 "필요하면"이라고 했고, 실제 구현은 기존 `/data.json`의 `aiQueue` 피드로
  `resultHTML`을 인라인 전달하고 보기/다운로드는 클라이언트측 `window.open`/Blob으로 처리해 화이트
  리스트에 넣을 GET 라우트 자체가 없다).
  Verify: see DASH-8 evidence block — non-blocking return, not-found guard, cycle-safe result all
  confirmed live 2026-07-06 on the isolated instance.
- **EP-10 — `GET /api/bgm/plan` / `POST /api/bgm/plan` (added 2026-07-08, 전략3 · 플랜 맵).**
  EN: The 전략3 plan map assigns a themed track pool (first-level subfolders of the music root —
  `office/`, `ship/`, `steel/`, ...) to each (day × "HH:mm"–"HH:mm") slot. `days` accepts a
  specific day `mon`..`sun`, the bands `weekday`/`weekend`, or `all`; resolution priority is
  specific day > band > all, file order within a pass (added 2026-07-08: the seed plan gives every
  weekday its own theme arc). The `ConditionDirector` gates its adaptive selection to the active
  slot's themes (mode playlists are the fallback when no slot matches). The plan lives at
  `<data>/bgm-plan.json` (`BGMPlanMap.swift`; seeded with a built-in default when missing/corrupt).
  GET returns `{plan,currentSlot,themes,themeCounts}` — `themes` lists the folders that actually
  exist in the library so a planning agent only references real pools. POST replaces the whole plan
  after validation (bad days/time/empty slots/themes ->
  `{"ok":false,"error":<reason>}`); on success returns `{"ok":true,"slots":N,"unknownThemes":[...]}`
  and forces an audible move into the new pool (`planDidChange`). Agents must use the POST (never
  write the file directly — same convention as goals). BPM-less tracks load at defaultBPM=110
  instead of being skipped (`BPMLibrary.swift`), and within a BPM-flat pool the director rotates by
  recency + a 240s dwell instead of BPM distance. Strategy catalog: `track-playstats.json` gains
  id 3 "플랜 맵" and `activeStrategy` migrates 2->3 idempotently (`TrackPlayStats.swift`).
  KO: 전략3 플랜 맵은 (요일 × "HH:mm"–"HH:mm") 슬롯마다 테마 곡 풀(음원 루트의 1단계 하위폴더 —
  `office/`, `ship/`, `steel/`, ...)을 지정한다. `days`는 개별 요일 `mon`..`sun`, 밴드
  `weekday`/`weekend`, `all`을 받으며 우선순위는 개별 요일 > 밴드 > all, 같은 패스 안에서는 파일
  순서(2026-07-08 추가: 시드 플랜은 월~금 각 요일이 고유한 테마 구성을 가짐). `ConditionDirector`는
  적응 선곡을 활성 슬롯의 테마로 제한한다(슬롯이 안 잡히면 모드 플레이리스트가 폴백). 플랜은
  `<data>/bgm-plan.json`에 저장되며(`BGMPlanMap.swift`; 없거나 깨지면 내장 기본 플랜으로 시드)
  GET은 `{plan,currentSlot,themes,themeCounts}`를 반환한다 — `themes`는 라이브러리에 실존하는
  폴더 목록이라 계획 에이전트가 실재하는 풀만 참조할 수 있다. POST는 검증 후 플랜 전체를 교체하고(잘못된 days/시간/빈
  slots·themes -> `{"ok":false,"error":<사유>}`), 성공 시 `{"ok":true,"slots":N,"unknownThemes":
  [...]}`를 반환하며 새 풀로 즉시 가청 전환한다(`planDidChange`). 에이전트는 파일을 직접 쓰지 말고
  반드시 POST를 사용한다(goals와 동일 규약). BPM 없는 곡은 스킵되지 않고 defaultBPM=110으로
  로드되며(`BPMLibrary.swift`), BPM이 동일한 풀 안에서는 BPM 거리 대신 최근재생 페널티 + 240초
  체류로 회전한다. 전략 카탈로그: `track-playstats.json`에 id 3 "플랜 맵"이 추가되고
  `activeStrategy`가 2->3으로 멱등 마이그레이션된다(`TrackPlayStats.swift`).
  A read-only visualization page `GET /bgm-plan` (`BGMPlanContent.swift`) renders the plan as
  day-band × 24h timeline strips — one colored block per slot (overnight wrap drawn as two
  segments), a "지금 HH:MM" cursor on today's band, the governing slot highlighted, and per-slot
  detail cards (theme chips with real track counts from `themeCounts`, pinned opener, planner
  note). Opened from the BGM player's "계획" chip (`window.open` -> default browser).
  KO 추가: 읽기 전용 시각화 페이지 `GET /bgm-plan`(`BGMPlanContent.swift`)이 플랜을 요일 밴드 ×
  24시간 타임라인 띠로 렌더링한다 — 슬롯마다 색 블록(자정 넘김은 두 조각), 오늘 밴드에 "지금
  HH:MM" 커서, 현재 지배 슬롯 하이라이트, 슬롯별 상세 카드(실제 곡 수가 붙은 테마 칩·고정 첫 곡·
  기획 노트). BGM 플레이어의 "계획" 칩에서 열린다(`window.open` -> 기본 브라우저).
  Verify: isolated instance 2026-07-08 (lion-condition-mate-worker-qa) — library `loaded 187 tracks (164 no-BPM
  defaulted) range 82-172`; GET at 04:30 KST Wed -> `currentSlot:"저녁 · 라운지 바람"` + 16 real
  themes; playing track confirmed inside the slot's theme folder (`bgm/challenge/The Memory
  Era.mp3` under a QA slot); POST rejections (`days:"someday"`, empty slots/themes, bad JSON, empty
  body) all `ok:false` with reasons, valid plan -> `ok:true` + audible switch (id 126->151);
  fresh-install stats seed ids 1/2/3 + `activeStrategy:3`, pre-placed v2 file (`activeStrategy:2`,
  ids 1·2) migrates to 3 with id 2 closed and stat rows preserved; plan file deleted mid-run -> no
  crash, in-memory plan persists; unknown-theme plan -> reported in `unknownThemes`, blocked-pool
  fallback keeps music playing (no silence). `/bgm-plan` page verified 2026-07-08 via node DOM-stub
  render (13/13 assertions: band strips, wrap split, now cursor, counts, opener/note) plus a
  static-server screenshot pass.
- **EP-11 — `POST /api/bgm/rain {action}` + 폭우 리셋 mechanic (added 2026-07-08, 전략3).**
  EN: An activity-triggered "rain reset". `ConditionDirector` builds *focus credit* while the
  smoothed activity `norm` ≥ 0.7; once ≥30 ticks (~10 min) of credit accrue AND `norm` then drops
  below 0.5, it rolls a 25%/tick die and — on a hit, at most ONCE per calendar day
  (`rain-reset.txt` holds the day-string) — summons a 1-hour reset from the `heavy_rain` pool. While
  raining, `inActivePool` gates selection to `heavy_rain` only (winning over the plan slot — which
  no longer schedules rain: the old 심야 slot is now `snow`/`peace` "고요한 밤"); when the hour
  elapses (`rainUntil`), `endRain()` warms back up and returns to plan selection. `director.gearLabel`
  → "폭우"; `/api/bgm/now` and `/data.json` `now.plan` → "🌧 폭우 리셋 N분". The lifecycle logs to
  `worker-logs/director.jsonl` (WorkerRegistry), not `app.log`. `POST /api/bgm/rain {"action":"start"}`
  force-starts (bypassing eligibility + daily limit) and `{"action":"stop"}` ends early — a
  debug/preview hook; any missing/invalid action is a `{"ok":false}` no-op (a malformed body can NOT
  summon rain).
  KO: 활동 기반 "폭우 리셋". `ConditionDirector`가 평활 활동 `norm` ≥ 0.7이면 *몰입 크레딧*을
  쌓고, ~10분(30틱) 이상 쌓인 상태에서 `norm`이 0.5 아래로 떨어지면 25%/틱 확률로 주사위를 굴려
  — 적중 시 하루 1회(`rain-reset.txt`에 날짜 기록) — `heavy_rain` 풀에서 1시간 리셋을 소환한다.
  폭우 중엔 `inActivePool`이 `heavy_rain`만 허용(플랜 슬롯을 이김 — 이제 폭우는 스케줄에 없음: 옛
  심야 슬롯은 `snow`/`peace` "고요한 밤"으로 교체). 1시간 경과 시 `endRain()`이 워밍업 후 플랜 선곡
  복귀. `gearLabel`→"폭우", `now.plan`→"🌧 폭우 리셋 N분". 로그는 `app.log`가 아니라
  `worker-logs/director.jsonl`. `POST /api/bgm/rain {"action":"start"|"stop"}`는 디버그/프리뷰 훅으로
  강제 시작/조기 종료하며, action이 없거나 잘못되면 `{"ok":false}` no-op(잘못된 바디가 폭우를 부를 수 없음).
  Verify: isolated instance 2026-07-08 (lion-condition-mate-worker-qa) — heavy_rain 9곡 로드(id 70-78, bpm 110); 강제
  start → 다음 tick에 `now.plan:"🌧 폭우 리셋 59분"` + id 70(heavy_rain), `director.jsonl`에 "폭우
  리셋 발동" 라인; `rain-reset.txt`=오늘 날짜; stop → 즉시 플랜 슬롯("수 아침 · 대항해")·비-heavy_rain
  트랙 복귀 + "복귀" 라인; 심야 슬롯=snow/peace, heavy_rain 스케줄 슬롯 0개; 신규 세션 60초 관찰 시
  자발 폭우 없음(크레딧 미달로 구조적 불가). 자격 판정 로직은 standalone Swift 스크립트 9/9 통과
  (repo에 XCTest 타겟은 없음 — 라이브 상태머신 4회 실행으로 동등 검증). malformed body 4종 무크래시
  (수정 후 `{"ok":false}` no-op).
- **EP-12 — `GET /api/bgm/slot-scores` (added 2026-07-10, 전략4 · 상태 인지형 관측).**
  EN: Strategy 4 keeps the 전략3 plan map executing and replays `actions.jsonl` to score each plan
  slot's hit/miss. hit = a session the slot was involved in ends with no negative signal (pomodoro
  must reach its target seconds — a completed run); miss = a dislike inside the slot's window or a
  mute during a session. trackChange's `강제 전환` detail bundles slot-boundary/idle flips and is
  NEVER counted as a miss. Scores are derived on read via `GET /api/bgm/slot-scores`
  (`BGMSlotScores.swift`; no storage, no writes) and rendered under the strategy history as the
  dashboard's `슬롯 성적표` section. Selection and the plan file are never changed automatically.
  `sessions>=3 && hitRate<0.5` -> 재계획 후보 badge. The strategy catalog gains id 4 (상태 인지형)
  and `activeStrategy` migrates to 4 idempotently (`TrackPlayStats.swift`).
  KO: 전략4 · 상태 인지형(관측): 전략3 플랜 맵을 유지한 채, actions.jsonl을 재생해 슬롯별 hit/miss를
  채점한다. hit=슬롯 관여 세션이 부정 신호 없이 종료(포모도로는 목표초 이상 완주), miss=슬롯 윈도우
  내 dislike 또는 세션 중 mute. trackChange의 '강제 전환'은 슬롯 경계/유휴가 섞인 신호이므로 miss로
  세지 않는다. 점수는 GET /api/bgm/slot-scores로 파생(저장/쓰기 없음), 대시보드 전략 히스토리 아래
  '슬롯 성적표'로 표시. 선곡·플랜 파일은 자동 변경하지 않는다. sessions>=3 && hitRate<0.5 → 재계획
  후보 배지. 전략 카탈로그에 id=4(상태 인지형) 추가, activeStrategy=4로 이관.
  Verify: derivation exercised standalone 2026-07-10 (swiftc harness over the real
  `~/.condition-mate/events/actions.jsonl` + live plan slots — no XCTest target in the repo):
  golden sample (spec §2) `금 심야 · 애프터 라운지` scored hits>=1, misses=0, score>=1, and the
  00:00 목→금 `강제 전환` flip produced no miss.
- **EP-13 — Wall-clock pomodoro completion, server-owned (added 2026-07-10).**
  EN: A pomodoro completes at 25 WALL-CLOCK minutes after session start (`AppDelegate.
  pomodoroWallSeconds`, `CM_POMODORO_SECS` override for e2e), judged by the 1 Hz heartbeat —
  NOT by the rail webview and NOT by the activity-gated `sessionSeconds` (idle/app-filter can
  freeze that count below target on a genuinely completed run; observed stops at 1499s). On
  completion the server logs `pomodoro.complete` (+`chime`), grants equipment EXP
  (`EquipmentStore.recordPomodoro`), appends to the durable history `<data>/pomodoro-stats.json`
  (`Core/PomodoroStats.swift`), stops the session, plays `pomodoro-success.mp3`, and raises a
  server-owned reward flag. `GET /api/session/state` carries `wall` (wall seconds since start),
  `mode`, `reward`, `pomoToday` (today's completions, display-timezone day bucket); the rail dial
  counts down `wall`, mirrors `reward` as the 🍅 orb (reload-safe), and shows `오늘 N/2` on the
  pomodoro label at all times. `POST /api/session/control {"action":"harvest"}` claims the orb
  (logs `pomodoro.harvest`, plays the harvest chime); starting the next session auto-claims an
  untapped orb — the count is never lost. `POST /api/equipment/pomodoro` is demoted to the
  /equipment dev 시뮬 button (logs `equipment.devAward`, no history write). 전략4 slot scoring
  treats a `pomodoro.complete` inside the session window as the completed signal (legacy logs
  fall back to elapsed>=target).
  KO: 포모도로 완주=세션 시작 후 벽시계 25분. 판정은 서버 하트비트가 소유 — 레일 웹뷰나 활동초
  (`sessionSeconds`)가 아니다(유휴/앱필터로 활동초가 목표 미달로 얼어붙는 1499초 중지 사례가 원인).
  완주 시 서버가 `pomodoro.complete` 기록, 장비 EXP 지급, 영속 히스토리(`pomodoro-stats.json`) 적재,
  세션 정지, 성공음 재생, 수확 대기 플래그를 올린다. `/api/session/state`에 `wall`/`mode`/`reward`/
  `pomoToday`(표시 타임존 기준 오늘 완주 수)가 실리고, 레일 다이얼은 `wall`로 카운트다운, `reward`를
  🍅 오브로 미러링(리로드 안전), 포모도로 라벨에 `오늘 N/2` 상시 표시. 수확 탭=`{"action":"harvest"}`
  (`pomodoro.harvest` 기록+수확음), 미수확 상태로 다음 세션 시작 시 자동 클레임(카운트 유실 없음).
  `POST /api/equipment/pomodoro`는 /equipment 시뮬 버튼 전용으로 강등(`equipment.devAward`, 히스토리
  미기록). 전략4 채점은 세션 윈도우 내 `pomodoro.complete`를 완주 신호로 사용(구 로그는 경과초 폴백).
  Verify: isolated instance (`CM_DATA_DIR`+`CM_POMODORO_SECS=6`) 2026-07-10 — two completions
  reached `pomoToday:2` with `pomodoro.complete`/`sessionStop`/`pomodoro.harvest` in order,
  `pomodoro-stats.json` persisted both, harvest cleared `reward`, and a start with an untapped orb
  auto-claimed it; rail contract locked by `.e2e/pomodoro.test.js` (8/8).
- **EP-14 — Mode energy: challenge mode reconnects to track selection within the SAME plan pool
  (added 2026-07-10, 전략5 · 모드 에너지).**
  EN: Strategy 4 left a gap: whichever challenge mode (25분 포모도로 / 스프린트 / 트래커=unlimited)
  the user picked, the SAME music played, because the 전략3 plan slot's theme pool fully owned
  selection and the mode playlists were only a fallback for plan gaps. Strategy 5 keeps the plan
  pool and slot-score gate (`inActivePool`) unchanged, but derives a per-mode EFFECTIVE BPM band
  from the base band (`Settings.minBPM`/`maxBPM`, default 70-150) via `ConditionDirector.
  applyModeEnergy()`: pomodoro -> 86-134 BPM (mid-band, ramp x1.0), sprint -> 114-150 BPM (upper
  band, ramp x1.6, faster warmup climb), unlimited -> 70-106 BPM (lower band, ramp x0.5, slower
  climb). The band is re-applied on `start()`, `setSessionMode()`, and `applyProfile()`, and every
  `trackChange` action-log line appends " · 모드밴드 <mode> <min>-<max>BPM" to its detail so the
  action log audits which band picked the track. `poolLabel` (플랜 · <slot> / 모드 · <mode>) is
  UNCHANGED by this strategy — the plan gate still owns which folder pool is eligible; mode energy
  only re-ranks nearest-BPM selection inside that pool. A mode switch while a session is live
  (`setSessionMode`) immediately re-seats the target into the new band and plays the mode's opener
  (or forces a gated nearest-BPM pick if the opener isn't in the active pool) — no silence: the
  switch never calls `pauseSession()`/`stop()`, only `audio.play()` via `AudioEngine`'s built-in
  crossfade.
  KO: 전략4는 공백을 남겼다 — 어떤 챌린지 모드(25분 포모도로/스프린트/트래커=무제한)를 골라도 같은
  음악이 나왔다. 전략3 플랜 슬롯의 테마 풀이 선곡을 완전히 소유했고 모드 플레이리스트는 플랜 공백일
  때의 폴백일 뿐이었기 때문이다. 전략5는 플랜 pool과 슬롯 채점 게이트(`inActivePool`)를 그대로 둔
  채, 기본 밴드(`Settings.minBPM`/`maxBPM`, 기본 70-150) 위에서 `ConditionDirector.
  applyModeEnergy()`로 모드별 유효 BPM 밴드를 도출한다: 포모도로 → 86-134 BPM(중앙·ramp x1.0),
  스프린트 → 114-150 BPM(상단·ramp x1.6, 빠른 웜업), 트래커(unlimited) → 70-106 BPM(하단·ramp
  x0.5, 느린 웜업). 밴드는 `start()`/`setSessionMode()`/`applyProfile()`에서 재적용되고, 모든
  `trackChange` 액션로그 detail 끝에 " · 모드밴드 <mode> <min>-<max>BPM"이 붙어 어느 밴드가 곡을
  골랐는지 감사할 수 있다. `poolLabel`(플랜 · <슬롯> / 모드 · <mode>)은 이 전략으로 바뀌지 않는다 —
  플랜 게이트가 여전히 어느 폴더 풀이 유효한지 결정하고, 모드 에너지는 그 풀 안에서 최근접-BPM
  순위만 재조정한다. 세션이 살아있는 중 모드를 전환하면(`setSessionMode`) 즉시 새 밴드로 타깃을
  재조정하고 모드의 오프너를 재생한다(오프너가 활성 풀 밖이면 게이트된 최근접-BPM 강제 선곡) —
  무음 구간 없음: 전환은 `pauseSession()`/`stop()`을 호출하지 않고 `AudioEngine`의 내장 크로스페이드로
  `audio.play()`만 호출한다.
  Verify (isolated bundle instance, unique bundle id, `CM_SCAN_DIR` -> a real `office/` pool copied
  from the repo's `bgm/office` folder spanning 82-172 BPM, custom `bgm-plan.json` pinning an
  "all-day" slot to that pool, `bgmWindowEnabled=false` to avoid an on-screen window, 2026-07-10):
  the `CM_DEBUG` heartbeat line's `[min-max]` showed the band change instantly on each mode switch
  (`[86-134]` -> `[114-150]` -> `[70-106]`), matching the formula exactly. `POST /api/session/control
  {"action":"start","mode":"sprint"}` played the sprint opener `[133] Glass Horizon` (133 BPM,
  inside 114-150); re-posting the SAME `bgm-plan.json` (forces `planDidChange()` ->
  `applyTrack(force:true)`) produced `trackChange` with detail `"강제 전환 (...) · 모드밴드 sprint
  114-150BPM"`, track `[120] Midnight Monitor Grid` (120 BPM), `pool":"플랜 · QA 오피스 슬롯"`
  (unchanged). Switching to `mode=unlimited` (same live session) played opener `[082] 창가의 바람`
  (82 BPM) then the same forced-replan trick produced `trackChange` detail `"... · 모드밴드
  unlimited 70-106BPM"`, track `[089] Neural Ops Room (1)` (89 BPM) — a clearly different, much
  lower BPM pick than sprint's, from the exact SAME plan pool (`pool` unchanged). Switching back to
  `pomodoro` produced `"... · 모드밴드 pomodoro 86-134BPM"`, track `[096] 유리문 속 세계` (96 BPM,
  mid-band). No app.log errors/crashes across the run; process stayed alive and responsive
  throughout. `activeStrategy` confirmed `5` and the catalog's id-5 retro/summary text present in
  `track-playstats.json`.
  Note: the forced-replan trick (re-POSTing the unchanged plan) was used INSTEAD OF waiting out the
  real 20s decision tick + 90s min-dwell gate, because this headless environment's background
  process is subject to real interference (the window-enabled first attempt had its window closed
  by something external at ~44s; a second window-disabled attempt had the whole process quit via
  the real `quit()` menu path at ~10s with no CM_QUIT_AFTER set and no code path that should have
  called it) — both are ENVIRONMENT flakiness (a shared desktop and/or App Nap throttling a
  windowless background process), not app defects, but they make a multi-minute unattended
  wall-clock wait for an organic tick-driven trackChange unreliable in this environment. The forced
  trigger exercises the identical `applyTrack()` code path (the modeBand suffix is appended
  unconditionally, whether `force` is true or false) so the evidence is equally valid for whether
  the mode band is applied; it does not by itself prove the ORGANIC (tick-driven, non-forced)
  warmup climb reaches the new band within a live session — that remains INFERRED from the code
  (`tick()`'s `targetBPM = min(maxBPM, targetBPM + warmupStep * modeRamp)` uses the mode-scoped
  `activeMaxBPM`/`modeRamp` already confirmed live via the `CM_DEBUG` band line) rather than
  directly observed via a real un-forced trackChange in this pass.
- **EP-15 — Start-context selection: the session-start MOMENT (timer mode × daypart × hours into
  the work block) picks the opening mood (added 2026-07-12, 전략6 · 시작 컨텍스트).**
  EN: Strategy 5 made modes sound different through BPM bands, but every session still OPENED the
  same way — at night the plan slot (no opener, calm themes) simply resumed the previous track for
  pomodoro/sprint/tracker alike. Strategy 6 evaluates, at each session-start seam (`start()`,
  live `setSessionMode()`, `resumeSession()` with a re-armed opener), a start CONTEXT: session
  mode × daypart in the display timezone (아침 05-11 / 낮 11-17 / 저녁 17-23 / 심야 23-05) ×
  minutes since 업무 시작. Work start is detected Swift-side by `AppDelegate.workStart(anchors:
  gap:now:)` — the 6h-gap block walk over yesterday+today per-minute activity anchors (input or
  meeting), same rule as the condition map; 0 anchors or a 6h+ stale tail = fresh start (elapsed
  0). The pure rule table `ConditionDirector.startTierKey(mode:daypart:elapsedMin:)` maps the
  triple to a tier: <1h = 아침→가볍게(gentle) · 낮→집중(focus) · 저녁/심야→라운지(lounge, the
  "walked into a club" welcome for a tired evening arrival); 1-2h = 집중; ≥2h = 초집중(hyper,
  competition mode — 아침 only stays 집중). Sprint bumps the tier one step up (it IS the user
  choosing speed), tracker one step down. Each tier seats `targetBPM` at its `startFrac` of the
  전략5 mode band and scales the warmup climb (`contextRamp`, multiplied with `modeRamp`); lounge
  (themes `lounge`) and hyper (themes `challenge`/`steel`/`last_goal`) additionally OVERLAY the
  candidate pool for 20 minutes — gate precedence is now 폭우 > 시작 컨텍스트 > 플랜 슬롯 > 모드
  리스트 — with the opener picked from the overlay pool (recency-rotated, so consecutive starts
  differ), after which selection drifts back to the plan pool organically (no forced switch).
  Every evaluation logs a `startContext` system event ("시작 컨텍스트 심야 · 업무 3.0h → 초집중 ·
  시작 119BPM · 테마 challenge·steel·last_goal 20분"), and — the audit axis — EVERY actions.jsonl
  line now carries `workMin` (minutes into the work block, -1 = provider unwired), stamped
  centrally in `ActionLog.append` via a thread-safe 60s-cached provider; the 액션로그 UI renders
  it as an "업무 N분/N.Nh" pill.
  KO: 전략5로 모드별 밴드는 갈렸지만 세션의 "시작"은 여전히 같았다 — 심야엔 플랜 슬롯에 오프너가
  없어 포모도로/스프린트/트래커 모두 직전 곡이 그대로 이어졌다. 전략6은 세션이 시작되는 순간마다
  (`start()` · 라이브 `setSessionMode()` · 오프너 재장전된 `resumeSession()`) 시작 컨텍스트 —
  모드 × 표시 타임존 시간대(아침 05-11/낮 11-17/저녁 17-23/심야 23-05) × 업무 시작 후 경과 — 를
  평가한다. 업무 시작은 컨디션맵과 같은 6h-갭 규칙을 Swift쪽에서 재현(`AppDelegate.workStart`,
  어제+오늘 분단위 앵커 블록 워크; 앵커 없음/6h+ 공백 후는 경과 0 = 새 시작). 순수 규칙표
  `startTierKey`: 1시간 미만 = 아침→가볍게 · 낮→집중 · 저녁/심야→라운지(지쳐서 온 저녁 시작을
  클럽 라운지처럼 맞이해 휴식 기분으로); 1~2h = 집중; 2h+ = 초집중(이제 휴식이 아니라 경쟁 —
  아침만 집중 유지). 스프린트는 한 단계 위(스스로 고속을 골랐으니), 트래커는 한 단계 아래.
  티어는 전략5 모드 밴드 안의 시작점(`startFrac`)과 웜업 배율(`contextRamp`×`modeRamp`)을 정하고,
  라운지(`lounge`)와 초집중(`challenge`/`steel`/`last_goal`)은 20분간 선곡 풀 자체를 오버레이한다
  (게이트 우선순위: 폭우 > 시작 컨텍스트 > 플랜 슬롯 > 모드 리스트; 오프너도 이 풀에서
  recency 회전으로 선곡 — 연속 시작이 같은 곡으로 반복되지 않는다). 만료되면 강제 전환 없이
  회전 dwell로 플랜 풀에 자연 복귀. 평가마다 `startContext` 시스템 이벤트를 남기고, 감사 축으로
  actions.jsonl 모든 라인에 `workMin`(업무 경과 분, -1=미배선)을 `ActionLog.append`에서 중앙
  스탬프(스레드 안전 60s 캐시 공급자), 액션로그 UI는 "업무 N분/N.Nh" 필로 표시한다.
  Verify: isolated instances (`CM_DATA_DIR`, repo `bgm/` as music root, 2026-07-12 00:35 KST =
  주말 심야, plan slot "주말 심야 · 밤의 여운" opener-less). Scenario A (fresh data dir, workMin
  0): launch auto-start pomodoro → `startContext "심야 · 업무 0분 → 라운지 · 시작 93BPM · 테마
  lounge 20분"` + opener `Golden Hour (1)` (lounge); live switch to sprint → 집중 (lounge bumped
  up), no overlay, forced pick `The Last General` at 126BPM from the plan pool; stop + start
  unlimited → 라운지 75BPM opener `Break Room` — a DIFFERENT lounge track than pomodoro's
  (recency rotation), three timers audibly distinct at the same wall-clock moment. Scenario B
  (seeded `activity-<today>.jsonl`, anchors 3h ago→5min ago): every event stamped `workMin:180`;
  pomodoro start → `"심야 · 업무 3.0h → 초집중 · 시작 119BPM · 테마 challenge·steel·last_goal
  20분"` opener `The Last Dawn`; sprint switch → 139BPM opener `Rise of the New Era`. JS contract
  `.e2e/actioncat.test.js` 14/14 after the UI pill/label additions.
- **EP-16 — Harvest-stage memory clear: the 🍅 reward orb folds the board (added 2026-07-12).**
  EN: When the pomodoro completes and the server raises the reward orb (EP-13), the rail's reward
  render now ENTERS zen instead of revealing the board: the right-hand content folds away (window
  narrows to the rail; on a non-dashboard rail page it leaves for `/?zen=1`) so the finished
  session's board — leftover human working memory — is cleared and the user faces only the
  harvest, then re-engages deliberately. Edge-triggered off `cmZenWasRun` (true only when THIS
  page just watched the session run), so (a) a fresh page load while an orb is pending never
  folds/redirects (navigating around with an unharvested orb stays free), and (b) a deliberate
  둘러보기 reveal during a pending harvest is respected — the fold fires exactly once, on the live
  completion transition. This inverts the previous rule ("a pending harvest never hides the
  board") on purpose: 수확 단계의 목적이 메모리 클리어이기 때문.
  KO: 포모도로 완주로 서버가 수확 오브를 올리는 순간(EP-13), 레일의 reward 렌더가 보드를 드러내는
  대신 젠으로 접는다: 오른쪽 콘텐츠가 사라지고(창은 레일 폭으로, 대시보드가 아닌 레일 페이지에선
  `/?zen=1`로 이동) 끝난 세션의 보드 = 남은 인간 작업기억을 걷어내, 유저는 수확만 마주한 뒤
  의도적으로 다시 집중한다. `cmZenWasRun` 엣지 트리거(이 페이지가 방금 세션이 도는 걸 봤을 때만
  true)라서 (a) 오브가 대기 중인 상태의 새 페이지 로드는 접거나 리다이렉트하지 않고(미수확 오브를
  둔 채 자유롭게 탐색 가능), (b) 수확 대기 중 둘러보기로 드러낸 보드는 다시 접히지 않는다 — 접힘은
  라이브 완주 전환에서 정확히 한 번. 기존 규칙("수확 대기는 보드를 가리지 않는다")의 의도적 반전.
  Verify: `.e2e/harvest.test.js` (source-bound, 4/4 2026-07-12) — live transition folds exactly
  once, re-renders don't re-fold, fresh load mid-reward never folds; `.e2e/zen.test.js` 11/11
  unchanged.
- **EP-17 — 화면 카탈로그: every distinct screen state auto-captured under a stable SCR-ID
  (added 2026-07-12, UX/UI 개선 전용).**
  EN: `Core/ScreenCatalog.swift` + a 2s probe in `AppWindowController` (`screenCatalogTick`)
  identify the VISIBLE webview's screen state — key = `mode|path?queryKEYS|view|flags` where query
  values are dropped (goal #12/#34 are the same SCREEN) and flags capture layout-changing UI
  phases the path can't see (`zen`,`reward`,`run`,`counting`,`done`,`modal` via a geometric
  full-viewport-overlay scan that excludes the rail, `railoff`). A state must hold two consecutive
  ticks (settled, `readyState=complete`) before `WKWebView.takeSnapshot` stores ONE PNG per state
  (`<data>/screens/SCR-XXXX.png`, ≤1200px wide, re-shot when >24h old so each entry shows the
  screen's CURRENT look); the index (`screens/catalog.json`) tracks first/last seen, ENTER count,
  viewport, plus management fields (note, status: 미검토/검토중/개선필요/개선완료/무시). Endpoints
  (all under `/api/debug/` → action-log exempt): `GET /api/debug/screens/list`,
  `GET /api/debug/screens/img?id=SCR-NNNN` (strict id-regex + in-memory index lookup — no
  caller-supplied paths), `POST /api/debug/screens/note {id,note,status}`. UI: the condition
  page's 7th tab "화면 카탈로그" — filterable grid (status), thumbnail lightbox, per-screen memo
  editing. Hard caps: 600 distinct states, capture only while the window is open+visible.
  KO: `Core/ScreenCatalog.swift` + `AppWindowController`의 2초 프로브(`screenCatalogTick`)가 지금
  보이는 웹뷰의 화면 상태를 식별한다 — 키 = `모드|경로?쿼리키|뷰|플래그`, 쿼리 VALUE는 버려서
  문서가 아니라 화면 레이아웃 단위로 dedupe되고, 플래그는 경로가 못 보는 UI 국면(젠/수확/세션 중/
  카운트다운/한 판 더?/모달(레일 제외 기하 스캔)/레일 접힘)을 잡는다. 같은 상태가 두 틱 연속
  유지(안정)되면 상태당 PNG 1장을 저장(`<data>/screens/SCR-XXXX.png`, 최대 1200px 폭, 24h 지나면
  최신 모습으로 재촬영), 인덱스(`screens/catalog.json`)에 처음/최근 목격·진입 횟수·뷰포트와 관리
  필드(메모, 상태: 미검토/검토중/개선필요/개선완료/무시)를 기록한다. 엔드포인트(모두 `/api/debug/`
  하위 → 액션로그 제외): `GET /api/debug/screens/list`, `GET /api/debug/screens/img?id=SCR-NNNN`
  (엄격한 id 정규식 + 인메모리 인덱스 조회 — 호출자 경로 미사용), `POST /api/debug/screens/note`.
  UI: 컨디션 페이지 7번째 탭 "화면 카탈로그" — 상태 필터 그리드, 썸네일 라이트박스, 화면별 메모.
  상한: 상태 600개, 캡처는 창이 열려 있고 보일 때만.
  Verify: live dev instance 2026-07-12 — opening the window auto-recorded `SCR-0001`
  (`dashboard|/|sprint|zen,counting`) with its PNG within seconds and `SCR-0002` on the state
  transition; `GET …/img?id=SCR-0001` served the PNG inline; `.e2e/screens.test.js` (source-bound,
  9/9) locks the tab's rendering/filter/save contract.
- **EP-18 — UXUI sitemap + "UXUI 관리" worker: the screen hierarchy derived from SOURCE, kept in
  sync with main (added 2026-07-12).**
  EN: `Scripts/uxui-sitemap.py` deterministically parses the sources into a GitBook-style sitemap
  (big pages -> sub-pages -> UI states): routes from AppDelegate's `page:` closure
  (`path.hasPrefix`), dashboard sub-pages from DashboardContent's `VIEW_DEFS`, 시스템관리 sub-pages
  from BGMPlayerContent's `.subtab` buttons, and the state vocabulary from AppWindow's
  screen-catalog probe (`flags.push(...)`). Routes/flags present in code but not curated still land
  in the map as auto entries ("신규 라우트/상태 — 미작성"), so new code surfaces instead of
  drifting. Output `docs/uxui/sitemap.json` (repo) is installed to `<data>/screens/sitemap.json`
  by the "UXUI 관리" worker (`Scripts/uxui-sitemap.sh`, launchd
  `com.condition-mate.uxui-agent.plist`, 300s base tick): a commit gate (best-effort
  `git fetch origin main`, stamp `<data>/uxui-sitemap-last-commit`) makes ticks free until main
  actually moves; each real run reports via `POST /api/worker/ping` (id `uxui-sitemap`, registered
  in WorkerRegistry as "UXUI 관리", owner qa, toggleable via `uxui-sitemap-disabled`). Served by
  `GET /api/debug/screens/sitemap`; the 화면 카탈로그 tab's DEFAULT view is now the sitemap tree
  (left: pages/subpages/states with per-node coverage badges; right: node desc + the SCR-*
  screenshots matched by the catalog key vocabulary — mode/path(query keys stripped)/view/flag),
  with the previous grid behind a 전체 그리드 toggle. EP-6's QA snapshot `tab` hook now accepts
  every condition sub-tab (`map|activity|actions|diag|debug|syslog|screens`).
  KO: `Scripts/uxui-sitemap.py`가 소스를 결정적으로 파싱해 깃북식 사이트맵(큰 페이지 → 서브페이지
  → UI 상태)을 만든다: 라우트=AppDelegate `page:` 클로저의 `hasPrefix`, 대시보드 서브페이지=
  `VIEW_DEFS`, 시스템관리 서브페이지=`.subtab` 버튼, 상태 어휘=AppWindow 화면 카탈로그 프로브의
  `flags.push`. 코드에 있는데 큐레이션 표에 없는 라우트/상태도 자동 항목("신규 — 미작성")으로
  실려 새 코드가 드러난다. 산출물 `docs/uxui/sitemap.json`(레포)은 "UXUI 관리" 워커
  (`Scripts/uxui-sitemap.sh` + launchd 300초 베이스 틱)가 `<data>/screens/sitemap.json`으로
  설치한다: 커밋 게이트(`git fetch origin main` 베스트에포트, `<data>/uxui-sitemap-last-commit`
  스탬프)로 main이 실제로 움직일 때만 일하고, 실행마다 `POST /api/worker/ping`(id
  `uxui-sitemap`, WorkerRegistry "UXUI 관리", owner qa, `uxui-sitemap-disabled` 토글)으로 보고한다.
  `GET /api/debug/screens/sitemap`으로 서빙되며, 화면 카탈로그 탭의 기본 뷰가 사이트맵 트리
  (좌: 페이지/서브페이지/상태 + 노드별 커버리지 배지, 우: 설명 + 카탈로그 키 어휘(mode/경로
  (쿼리키 제거)/뷰/플래그)로 매칭된 SCR 스크린샷)가 됐고, 기존 그리드는 전체 그리드 토글 뒤로.
  EP-6 QA 스냅샷 `tab` 훅은 이제 컨디션 서브탭 전체를 받는다.
  Verify: generator run 2026-07-12 — 14 pages / 17 subpages / 7 flags from live source (including
  the 화면 카탈로그 tab itself); worker `--force` run installed the sitemap and pinged (워커 row
  `uxui-sitemap` runs:1, active); launchd agent loaded (RunAtLoad installed the prod copy);
  `GET /api/debug/screens/sitemap` returned the 14-page doc on the live dev instance;
  `.e2e/screens.test.js` 16/16 locks tree/coverage/match/grid/save contracts.

- **EP-19 — `/tokens-sessions.json` and `/tokens.json` carry the context-occupancy contract; a
  provider with no per-turn data emits `null`, never `0` (added 2026-09-04).**
  EN: `GET /tokens-sessions.json?day=YYYY-MM-DD` — every session object gains four fields plus the
  model they were resolved against: `ctxFinal` (int | null) = the prompt total
  `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of that session·day's LAST
  non-sidechain assistant request; `ctxPeak` (int | null) = the maximum of the same quantity over
  that session·day, sidechain excluded; `ctxWin` (int | null) = the resolved context window; `ctxPct`
  (float, 1 decimal | null) = `ctxFinal / ctxWin * 100`; `ctxModel` (string) = the model of that last
  request, i.e. the model the window was looked up for. `ctxFinal`/`ctxPeak` are `null` (never `0`)
  when nothing was measured; `ctxWin`/`ctxPct` are `null` when the model's window is unknown.
  The window is `AppDelegate.contextWindow(forModel:)` (prefix match, first hit wins:
  `claude-opus`/`claude-fable`/`claude-mythos`/`claude-sonnet`/`claude-*haiku` = 200_000,
  `gemini-` = 1_048_576, `gpt-4o` = 128_000, `o1`/`o3` = 200_000; everything else including `glm-*`
  is `nil` — an unverified window is left empty rather than invented), corrected UPWARD ONLY by
  `resolvedWindow(model:peak:)`: when the observed peak exceeds the published default, the window is
  lifted to the smallest published tier that contains it (tiers 200K, 1M), because a session opened
  on the 1M-context beta otherwise reports >400% occupancy. If no tier explains the peak, `ctxWin`
  is `null`. **Codex and Antigravity session rows emit all four as literal `null`** — those
  collectors return only a session token TOTAL, so there is no per-turn context to measure and
  emitting `0` would assert an empty window. `GET /tokens.json?days=N` — every day row gains
  `ctxMedPct` (float, 1 decimal | null) = median of that day's per-session final-occupancy percents,
  `ctxHighN` (int) = how many of those are ≥ 80%, and `ctxSessN` (int) = how many sessions that day
  have a known window. Occupancy is NOT additive, so it is never folded into the day's `DayTok`
  accumulator (`t.ctxFinal`/`ctxPeak`/`ctxModel` stay 0/"" there); the distribution is collected
  separately per file while the day is assembled.
  KO: `/tokens-sessions.json` 세션 객체에 `ctxFinal`·`ctxPeak`·`ctxWin`·`ctxPct`(+`ctxModel`)가,
  `/tokens.json` 일 행에 `ctxMedPct`·`ctxHighN`·`ctxSessN`이 추가된다. 측정된 것이 없으면 `0`이
  아니라 `null`이다 — `0`은 "창을 안 썼다"는 다른 주장이 된다. 창 표는 접두어 매칭이고 모르는
  모델(`glm-*` 포함)은 비워 둔다. 관측 피크가 표를 넘으면 그것을 담는 가장 작은 단계
  (200K → 1M)로 **위로만** 올린다. 턴별 컨텍스트가 없는 코덱스·안티그라비티 행은 네 값 모두
  `null`이다. 창 점유는 더할 수 없는 값이라 일 단위 `DayTok` 합산에 접지 않고 분포로만 낸다.
  Verify: `swift build` clean 2026-09-04. Backward-compat baseline captured from the still-running
  pre-change instance: `curl -s 'http://127.0.0.1:57797/tokens-sessions.json?day=2026-09-04'` →
  session `6e696696` returns `…"aiSec":3648,"models":{…},"leadN":…` with NO `ctx*` key at all, which
  is exactly the shape the client's `s.ctxFinal == null` guard must survive (chip not drawn).
  Live from the running server, isolated instance (`CM_DEV=1`, bundle
  `com.lioncho.conditionmate.qatest`, port 50921, 2026-09-04):
  `curl -s 'http://127.0.0.1:50921/tokens.json?days=2'` →
  `…"sessions":95,"leadN":32,"leadMed":160,"ctxMedPct":31.0,"ctxHighN":13,"ctxSessN":69,…`, and
  recomputing the median and the ≥80% count from that day's own `/tokens-sessions.json` rows
  reproduces `31.0 / 13` exactly. **The day boundary is `Settings.displayTimeZone`** — that rule is
  unchanged and is the same boundary every other number in the token view already uses; occupancy
  does not introduce a second one. **What the setting RESOLVES to changed on 2026-09-05: the default
  is now `Asia/Seoul`, not `"system"` — see EP-20.** The IST evidence in the next sentence was
  captured on 2026-09-04, while `cm.timeZone` still read `"system"` and this machine's system zone
  was `Asia/Kolkata`; it is kept because it demonstrates that the boundary really is the setting and
  not a hardcode, but it is NO LONGER the shape a fresh instance produces. As measured then: on a
  machine running IST a KST replay picks a different session set (`6e817b71` reads ctxFinal 69,270
  on 2026-08-30 under KST, while the server files that value under 2026-08-31 and returns 87,228 for
  2026-08-30). Re-running that replay today, with the default now KST, the server and a KST replay
  agree — which is the point of EP-20.
  Under the app's own timezone an independent replay of the exact rule matches the server on the
  frozen day 2026-08-30: 107/107 sessions, 0 mismatches on `ctxFinal/ctxPeak/ctxWin/ctxPct/ctxModel`,
  anchor `53c8820a` = `"ctxFinal":823490,"ctxPeak":823490,"ctxWin":1000000,"ctxPct":82.3`.
  `glm-5.3-flash` rows keep a real numerator and no denominator — `056888da` →
  `"ctxFinal":116415,"ctxPeak":138264,"ctxWin":null,"ctxPct":null` — and the 18 antigravity rows emit
  all four as literal null (`"ctxFinal":null,"ctxPeak":null,"ctxWin":null,"ctxPct":null`); the whole
  response contains zero `"ctx…":0`. Codex rows could not be observed live (this machine's
  `~/.codex/state_5.sqlite` has 0 rows in `threads`), so the codex branch (`AppDelegate.swift:4394`)
  rests on being the byte-identical literal to the live-verified antigravity branch (`:4414`).
  No regression: a build of this same tree with ONLY the ctx code removed, run side by side (port
  50923), returns day rows identical in every non-`ctx` field for all 7 settled days
  (2026-08-28…2026-09-03) and identical values on all 346 session rows of 2026-09-03 — the only
  differences are `loop`/`loopKind`, which each sandbox derives into its own
  `<CM_DATA_DIR>/loop-sessions/sessions.json`.
  History: EP-19 added 2026-09-04 alongside DASH-10.

- **EP-20 — the display timezone defaults to KST, and every day-bucketed number in the token view
  must land on the SAME day (added 2026-09-05).**
  EN: `Settings.timeZoneID` defaults to `"Asia/Seoul"`, and `displayTimeZone`'s invalid-identifier
  fallback is `Asia/Seoul` too. The explicit `"system"` value still resolves to `.current` — it is a
  choice, not a fallback. A stored `"system"` is moved to `"Asia/Seoul"` **exactly once**, guarded by
  `cm.timeZoneKSTMigrated`; after that flag is set, a user who re-picks `시스템 (맥 설정)` in the
  header selector KEEPS it across restarts. **Implementing this as a read-time coercion of
  `"system"` → KST is a regression** — it silently turns that selector option into a dead button, and
  a test that only checks "a stored `system` came back as `Asia/Seoul`" passes in both worlds, so the
  restart-persistence check is the only thing that tells them apart and must not be dropped.
  `ActivityLog`'s `activity-YYYY-MM-DD.jsonl` filenames are **storage shards, not date boundaries** —
  they are still cut on system-local and are deliberately NOT migrated. Both readers
  (`activeSecondsByDay`, `historyJSON`) must re-bucket every sample from its own `t` under
  `displayTimeZone`, reading one extra shard of padding on the older end (KST day D begins at IST
  20:30 of D-1, so those 3.5h physically live in the previous shard). **Deriving the day from the
  filename is a regression**: `AppDelegate.dashboardTokens` joins `activeSecondsByDay` against
  `totals` on the same `day` key, and `totals` is keyed by `displayTimeZone`. If the two axes are cut
  on different zones nothing visibly breaks — the 가치-mode time-efficiency multiplier just divides one
  day's tokens by another day's hours, every day, forever. The 히스토리 tab consumes the server's
  `"day"` field directly (`BGMPlayerContent.swift:3070,3081`) and does not re-bucket, so its 기간
  filter depends on this too.
  KO: `Settings.timeZoneID` 의 기본값은 `"Asia/Seoul"` 이고, `displayTimeZone` 의 잘못된 식별자
  폴백도 `Asia/Seoul` 이다. 명시적인 `"system"` 값은 여전히 `.current` 로 풀린다 — 그것은 폴백이
  아니라 선택이다. 저장된 `"system"` 은 `cm.timeZoneKSTMigrated` 플래그로 **딱 한 번만**
  `"Asia/Seoul"` 로 옮겨지고, 플래그가 선 뒤에 사람이 헤더 셀렉터에서 `시스템 (맥 설정)` 을 다시
  고르면 재시작을 넘어 **유지된다**. **이것을 읽을 때마다 `"system"` 을 KST 로 강제하는 방식으로
  구현하면 회귀다** — 그 셀렉터 항목이 아무도 모르게 죽은 버튼이 되고, "저장된 system 이
  Asia/Seoul 로 돌아왔다" 만 보는 시험은 양쪽 세계에서 똑같이 통과하므로, 둘을 가르는 것은
  재시작 유지 확인 하나뿐이고 그것을 빼면 안 된다. `ActivityLog` 의 `activity-YYYY-MM-DD.jsonl`
  파일 이름은 **저장 샤드일 뿐 날짜 경계가 아니다** — 여전히 시스템 로컬로 잘리며 일부러
  마이그레이션하지 않는다. 읽는 쪽 둘(`activeSecondsByDay`·`historyJSON`)은 각 샘플의 `t` 를
  `displayTimeZone` 기준으로 다시 버킷해야 하고, 과거 쪽으로 샤드 하나를 여유로 더 읽어야 한다
  (KST 하루 D 는 IST 로 D-1 의 20:30 에 시작하므로 그 3시간 30분이 이전 샤드 안에 있다).
  **파일 이름에서 날짜를 뽑으면 회귀다**: `AppDelegate.dashboardTokens` 가 `activeSecondsByDay` 를
  `totals` 와 같은 `day` 키로 조인하는데 `totals` 는 `displayTimeZone` 으로 잘린 것이다. 두 축이
  다른 존으로 잘리면 화면은 하나도 안 깨진다 — 가치 모드의 시간효율 배수가 어느 날의 토큰을 다른
  날의 시간으로 나눌 뿐이고, 그것이 매일, 계속된다. 히스토리 탭은 서버의 `"day"` 를 그대로 쓰고
  (`BGMPlayerContent.swift:3070,3081`) 스스로 재버킷하지 않으므로 그 탭의 기간 필터도 여기에 걸려
  있다.
  Verify: 2026-09-05 — `Scripts/e2e-timezone-boundary.sh` **PASS=8 FAIL=0**, re-run by
  lion-condition-mate-pm against the tree as it stands on disk (not merely as reported), after
  confirming `.build` is still a symlink to `~/.cache/cm-swiftpm-build` and `swift build` exits 0.
  Fixture instant `epoch=1788364800` = `2026-09-02T16:00:00Z` = IST `2026-09-02 21:30` = KST
  `2026-09-03 01:00`, i.e. inside the IST 20:30–23:59 window where the two zones name different days.
  Empty `CM_DATA_DIR` → `GET /api/settings/timezone` = `{"tz":"Asia/Seoul","effective":"Asia/Seoul",
  "label":"KST (UTC+9)"}`. Seeded `{"cm.timeZone":"system"}` → endpoint returns Asia/Seoul and
  `settings.json` gains `"cm.timeZoneKSTMigrated": true`; then `POST {"tz":"system"}` + restart →
  `{"tz":"system","effective":"Asia/Kolkata","label":"Asia/Kolkata (UTC+5.5)"}`, i.e. the selector is
  alive. Both axes move together: tokens `2026-09-02 = 123000 / 2026-09-03 = 0` under `tz=system`
  becomes `2026-09-02 = 0 / 2026-09-03 = 123000` under `tz=Asia/Seoul`, and `activeSec` moves
  `150 → 0` and `0 → 150` on the very same two rows. `/history.json` emits the samples under
  `2026-09-03` with the `{day,samples[{t,active,mult,meeting,tier,app}]}` contract intact.
  Regression: `Scripts/e2e-energy.sh` 16 passed / 0 failed, `.e2e/tallyhist.test.js` 63 passed /
  0 failed, `.e2e/ontrack.test.js` 14 passed / 0 failed — none needed modification, so none of them
  had been assuming system-local time. New warnings 0, proven by a revert-build baseline rather than
  asserted (the same two pre-existing AppDelegate warnings, shifted by exactly the inserted line
  count).
  NOTE: the fixture transcript cannot be isolated — `AppDelegate.claudeProjectsBase` uses
  `FileManager.homeDirectoryForCurrentUser`, which reads `getpwuid` and does NOT honor `$HOME`. The
  harness therefore writes a pid-unique folder under the real `~/.claude/projects` and removes it in
  `trap cleanup EXIT`. Fixture identifiers must stay pid-unique: a concurrent run of the same script
  once doubled the observed token count to 246000.
  Why / 근거: 2026-09-05. 원문 요구는 "토큰 뷰의 날짜 경계가 KST 가 아니라 시스템 타임존에 묶여
  있다" 였으나 실측은 반대였다 — 배관은 이미 `displayTimeZone` 하나로 다 몰려 있었고 새는 데가
  없었다. 어긋난 것은 설정값 하나(`cm.timeZone:"system"`)와 이 맥의 `/etc/localtime` 이
  `Asia/Kolkata` 라는 사실뿐이었다. KST 로 정한 근거 넷: 앱이 이미 `Core/AppLog.swift:14` ·
  `AppDelegate.swift:11956 isoWeek` · `:11999 aiTaskNameParts` · `docs/specs/script/render-spec.py:13`
  네 자리에서 `Asia/Seoul` 을 못박고 있어 앱 안에 "오늘" 이 둘 있었다; `docs/time-policy.md` 가
  재는 것은 사람의 근무 스팬이고 그 경계는 노트북 설정이 아니라 사는 곳이 정한다; `system` 기본값은
  기계 설정이 어긋나는 순간 경고 없이 데이터를 어긋나게 하는데 화면에 라벨이 찍혀 있었는데도 며칠을
  못 잡았다; 셀렉터가 이미 있어 되돌리는 값이 클릭 하나다. 판정 전문은
  `issue/2026-09-05-token-view-timezone-directive.md` 에 있다. 날짜 경계 정책은
  `docs/time-policy.md` 의 `## 날짜 경계` 절이 정본이며, 그 절은 이 항목과 같은 작업에서 신설됐다.
  History: EP-20 added 2026-09-05. Supersedes the `NOT KST` claim in EP-19's Verify, which was true
  on 2026-09-04 and is now dated in place rather than deleted.

- **EP-21 — new timestamps are stored in UTC and the screen converts them to the display
  timezone; slicing an ISO string is not conversion (added 2026-09-06).**
  EN: Every wall-clock time the dashboard prints from a STORED ISO string goes through
  `CMTimeFilter.isoDisp(value, len, sep)`, which resolves the instant and re-renders it under
  `window.CM_TZ` (the server injects `Settings.timeZoneID` per page request; the rail's selector
  saves then `location.reload()`s, so a setting change is picked up by re-serving). `isoDisp`
  converts ONLY values carrying an offset (`Z`, `±HH:MM`, `±HHMM`); a zone-less wall clock is
  printed verbatim, because we cannot know where it was written and inventing UTC would silently
  move old records. Newly written timestamps are UTC: `WorkQueueVersionLedger.stamp()`,
  `IssueArchiveStore.stamp()` and `WorkQueueLiveStore.fmt` pin `f.timeZone = TimeZone(identifier:
  "UTC")`. **Existing data is NOT migrated** and does not need to be — the format keeps its `Z`
  specifier, so `DateFormatter` honors whatever offset is written and old `+0530` / `+0900` values
  still parse to the correct instant. **Cutting the string is a regression**:
  `String(v).replace('T',' ').slice(0,16)` prints whatever zone the bytes were written in, and the
  only symptom is a number that is 3h (KST) or 3h30m (IST) off — a wrong number does not announce
  itself. The 설정 selector (rail menu and dashboard header, same list) must offer
  `Asia/Kolkata` alongside `system` / `Asia/Seoul` / `UTC`; without it India is reachable only by
  changing the Mac's own timezone.
  Verify: 2026-09-06 — `.e2e/timezone.test.js` **32 passed / 0 failed** (gated in `.e2e/run.js`).
  It evals the REAL `CMTimeFilter.js` and the REAL `sesHead`/`tdisp`/`esc` pulled out of
  `IssuesContent.swift`, so it fails when the product changes without it. The reported instant
  `2026-09-06T07:31:12.345Z` renders `2026-09-06 16:31` under `Asia/Seoul`, `2026-09-06 13:01`
  under `Asia/Kolkata` (the 30-minute offset), `2026-09-06 07:31` under `UTC`; the full session
  line reads `세션 <b>97cc3cc2</b> · 2026-09-06 16:31 · 사람 말 2 번 · 쓴 파일 3 개` in Korea and
  `… 13:01 …` in India. Flipping `CM_TZ` five times (Seoul→Kolkata→Seoul→UTC→Kolkata) yields five
  correspondingly different strings, i.e. nothing is cached and frozen. Day-boundary instant
  `2026-09-06T19:00:00Z` → `2026-09-07 04:00` (KR) vs `2026-09-07 00:30` (IN).
  `Scripts/e2e-timezone-display.sh` **PASS=10 FAIL=0** against a live isolated instance: POSTing
  `Asia/Seoul` / `Asia/Kolkata` / `Asia/Seoul` / `Asia/Kolkata` makes `/issues` serve
  `window.CM_TZ='<that id>'` each time, and the served 353,872-byte page carries `isoDisp`,
  `esc(tdisp(S.startedAt,16))`, the India option, and none of the three old slicing expressions.
  Swift side, run directly: the stamp formatter emitted `2026-09-06T13:01:12+0530` before (this
  Mac's `/etc/localtime` is `Asia/Kolkata`) and emits `2026-09-06T07:31:12+0000` after, while
  `+0530`, `+0900` and `+0000` inputs all parse back to epoch `1788679872`.
  Regression: `.e2e/run.js` **55 files, 1708 assertions passed / 0 failed**;
  `Scripts/e2e-timezone-boundary.sh` **PASS=8 FAIL=0** (EP-20 intact). Two harnesses needed
  editing and both were stale-by-design, not product failures: `issues.test.js` asserted the old
  expression text while still checking the same thing (the timestamp passes through `esc`), and
  `screens.test.js` stubbed `CMTimeFilter` with `parts` only. `swift build` exits 0 with the same
  two pre-existing `AppDelegate.swift` warnings and no new ones.
  KO: 대시보드가 **저장된 ISO 문자열**에서 벽시계를 찍는 자리는 전부 `CMTimeFilter.isoDisp` 를
  거친다. 오프셋이 붙은 값만 변환하고, 오프셋 없는 값은 어느 지역인지 알 수 없으므로 적힌 대로
  둔다 — 없는 정보를 UTC 라고 지어내면 옛 기록이 조용히 다른 시각으로 바뀐다. 앞으로 생성되는
  시각은 UTC 로 저장하고(원장 셋), **기존 데이터는 마이그레이션하지 않는다** — 포맷의 `Z` 가
  적힌 오프셋을 존중하므로 옛 값도 계속 정확히 읽힌다. **자르기는 변환이 아니다** — 자르면
  3시간(KST)이나 3시간 30분(IST) 어긋난 숫자가 나오고, 어긋난 숫자는 틀렸다고 소리치지 않는다.
  설정 셀렉터 두 곳(레일 메뉴·헤더)에 `Asia/Kolkata` 가 있어야 한다.
  Why / 근거: 2026-09-06. 라이언이 이슈 화면 스크린샷의 `2026-09-06 07:31` 에 밑줄을 그었다.
  그 세션은 KST 16:31 에 시작했다. 배관(`Settings.displayTimeZone` · `window.CM_TZ` ·
  `CMTimeFilter`)은 EP-20 에서 이미 다 놓여 있었고, 이 화면들만 그것을 안 쓰고 문자열을 잘라
  쓰고 있었다. 고친 것은 배관이 아니라 그 자리 12 개다 (IssuesContent 5 · LoopEngineeringContent 6 ·
  BGMPlayerContent 1).
  **Live re-verify on the RUNNING app, 2026-09-06 22:30–22:45 IST (second pass — the first pass
  only ever proved the SOURCE was right).** The binary actually running is
  `/Applications/ConditionMate.app/Contents/MacOS/ConditionMate` (pid 5544, installed 21:11,
  serving 127.0.0.1:57797), and it carries the fix: `strings -a` finds
  `function isoDisp(v, len, sep)` and `esc(tdisp(S.startedAt,16))` in it, finds `Asia/Kolkata`
  4×, and finds ZERO occurrences of `esc(String(S.startedAt||'').replace`. Posting
  `Asia/Seoul → Asia/Kolkata → UTC → Asia/Seoul → Asia/Kolkata → system` to
  `/api/settings/timezone` on that live instance made `/issues` serve
  `window.CM_TZ='<that id>'` (and `null` for `system`) on every single request; the user's
  original setting (`system`, effective `Asia/Kolkata`) was restored afterwards. The strongest
  evidence is that the running app's OWN data now proves the storage half: card
  `2026-09-06-2225-script-first-routing-loop`, written by this app today, carries
  `versionFirstSeen: 2026-09-06T17:01:18+0000` — a new timestamp, stored in UTC, on a Mac whose
  `/etc/localtime` is `Asia/Kolkata`. Feeding that live value plus the live `captured:
  2026-09-06T22:25:55+0530` through the REAL `CMTimeFilter` / `tdisp` / `sesHead` extracted from
  the 360,592-byte page THAT INSTANCE SERVED gives **16 passed / 0 failed**: the UTC-stored
  instant renders `2026-09-07 02:01` (KR, crosses the date line), `2026-09-06 22:31` (IN, the
  30-minute offset), `2026-09-06 17:01` (UTC); the old `+0530` value still resolves to the same
  instant in all three (`2026-09-07 01:55` / `2026-09-06 22:25` / `2026-09-06 16:55`), i.e. old
  records are read correctly WITHOUT migration; and five consecutive `CM_TZ` flips produce five
  correspondingly different strings, so nothing is cached and frozen.
  Swift side, run directly on this Mac (`TimeZone.current = Asia/Kolkata`): `ISO8601DateFormatter()`
  already emits `2026-09-06T07:31:12Z` by default, so only the three `DateFormatter` ledgers needed
  pinning — unpinned they emitted `…T13:01:12+0530`, pinned they emit `…T07:31:12+0000`, and
  `+0530` / `+0900` / `+0000` inputs all parse back to epoch `1788679872`.
  Regression this pass: `.e2e/run.js` **55 files, 1714 assertions passed / 0 failed**,
  `.e2e/timezone.test.js` **32/0**, `Scripts/e2e-timezone-display.sh` **PASS=10 FAIL=0**,
  `Scripts/e2e-timezone-boundary.sh` **PASS=8 FAIL=0**, `swift build` exit 0. (The 1708 above is
  the first pass's count; other work has added assertions since. Both numbers are 0 failed.)
  KO: 소스가 맞다는 것과 **지금 도는 앱이 맞다는 것은 다른 판정이다.** 두 번째 패스는 뒤엣것을
  본다 — 설치된 바이너리 안에 변환 코드가 있고 옛 자르기가 없으며, 살아 있는 인스턴스가 설정
  전환마다 새 `CM_TZ` 를 내보내고(사용자 원래 설정 `system` 은 되돌려 놓았다), 그 앱이 오늘
  스스로 쓴 레코드가 `+0000` 이고, 그 앱이 서빙한 페이지의 진짜 JS 로 그 진짜 값을 찍으면
  한국·인도·UTC 가 갈린다. 옛 `+0530` 값도 같은 순간으로 읽히므로 마이그레이션이 필요 없다.
  History: EP-21 added 2026-09-06. Builds on EP-20's plumbing (`displayTimeZone`, `CM_TZ`),
  which is unchanged.

### Intent audit — P6
EN: Code matches intent — PASS on EP-1..EP-6 and EP-7..EP-9 (added 2026-07-06), live-verified this
run (see per-item Verify). EP-9's design fork (server-side deterministic `linkmap` runner instead of
extending the client `buildMarkdown`/`renderReport`) is noted under DASH-8, not a P6 defect — the
endpoint contract itself matches its documented behavior.
KO: 코드가 의도와 일치함 — EP-1..EP-6과 EP-7..EP-9(2026-07-06 추가) 모두 PASS, 이번 실행에서
라이브로 검증함(항목별 Verify 참고). EP-9의 설계 분기(클라이언트 `buildMarkdown`/`renderReport`
확장 대신 서버측 결정적 `linkmap` 러너)는 DASH-8에 기록했으며 P6의 결함은 아니다 — 엔드포인트 계약
자체는 문서화된 동작과 일치한다.

---

## P7. Cross-cutting: logging
**Purpose / 목적:** **EN:** `Core/AppLog.swift` — the forensic trail for every page's lifecycle, read by every other page's Verify steps above; the one place all the other pages' evidence comes from. **KO:** `Core/AppLog.swift` — 위의 모든 페이지의 생명주기를 기록하는 포렌식 흔적으로, 다른 모든 페이지의 Verify 단계가 참조한다. 다른 모든 페이지의 증거가 나오는 단일 로그다.

- **LOG-1 — KST timestamps.**
  EN: All app.log lines use Asia/Seoul, format `yyyy-MM-dd HH:mm:ss.SSS KST`, pid-tagged.
  KO: 모든 app.log 라인은 Asia/Seoul, `yyyy-MM-dd HH:mm:ss.SSS KST` 포맷이며 pid가 찍힌다.
  Verify: `Core/AppLog.swift` — `TimeZone(identifier: "Asia/Seoul")`; live log lines confirmed
  2026-07-05, e.g. `2026-07-05 05:57:35.964 KST [pid 82731] LAUNCH …`.
- **LOG-2 — lifecycle coverage.**
  EN: Logged: `LAUNCH`, `single-instance: …`, `app-window autoOpen`, `app window owns audio=…`,
  `app-window audio-probe(…)`, `bgm auto-open on launch: …`, `app window user-closed -> quitting
  app`, `quit() — menu 종료 pressed`, `applicationShouldTerminate`, `applicationWillTerminate — …`
  (start and `— done`), `app-window closeForQuit`, `app-window windowWillClose (user|during quit,
  mode=…)`.
  KO: 위 목록의 모든 라인이 실제로 찍힌다.
  Verify: full sequence captured live 2026-07-05 in both a `CM_QUIT_AFTER` run and a real
  window-close-via-debug-endpoint run (see WINLIFE-1, WINLIFE-4, WINLIFE-5 evidence blocks).

### Intent audit — P7
EN: Code matches intent — PASS. `mode=…` was added to `windowWillClose` lines (not present in the old
L1 spec era's plain "bgm-window windowWillClose (user)"); LOG-2 wording updated to match current
strings so future literal-match testing does not false-FAIL on the old pre-refactor names.
KO: 코드가 의도와 일치함 — PASS. `windowWillClose` 라인에 `mode=…`가 추가됐다(예전 L1 스펙 시절의
단순한 "bgm-window windowWillClose (user)"에는 없었음); 이후 리터럴 매칭 테스트가 예전 리팩터링
이전 이름 때문에 잘못 FAIL하지 않도록 LOG-2 문구를 현재 문자열에 맞게 갱신했다.

---

## P8. App window — 루프 엔지니어링 페이지
**Purpose / 목적:** **EN:** `/loop-engineering` — the page that answers "where is the bottleneck and what do I press". Renamed from `/orchestration` on 2026-08-23. This page had ZERO spec entries before that date, so this is a NEW page registration, not an edit. Measurement definitions live in `docs/loop-engineering.md`; the loop itself (L1..L9) is defined in `docs/loop-definition.md`. **KO:** `/loop-engineering` — "병목이 어디이고 무엇을 누르면 되는가"에 답하는 페이지. 2026-08-23 에 `/orchestration` 에서 이름을 바꿨다. 그전까지 이 페이지에는 SPEC 항목이 하나도 없었으므로 이것은 기존 항목 수정이 아니라 **신규 페이지 등재**다. 측정 정의는 `docs/loop-engineering.md`, 루프 자체(L1..L9)의 정의는 `docs/loop-definition.md` 에 있다.

- **LOOP-1 — the rail's ninth slot goes to `/loop-engineering`.**
  EN: The rail's ninth nav item is labeled `루프 엔지니어링`, carries `data-nav="loop"`, and navigates to `/loop-engineering`. The page sets `window.CM_PAGE='loop'` so `cmNavReflect()` highlights that slot. The label wraps to two lines as `루프` / `엔지니어링` because `.cmr-lbl.wrap2` uses `word-break:keep-all` — it must NOT break mid-word. No slot in the 3x3 grid wears the inert `off` class any more.
  KO: 레일 아홉 번째 항목의 라벨은 `루프 엔지니어링` 이고 `data-nav="loop"` 이며 `/loop-engineering` 으로 이동한다. 페이지는 `window.CM_PAGE='loop'` 를 세워 `cmNavReflect()` 가 그 슬롯을 켜게 한다. 라벨은 `루프` / `엔지니어링` 두 줄로 끊긴다 — `.cmr-lbl.wrap2` 가 `word-break:keep-all` 이기 때문이며, 단어 중간에서 끊기면 회귀다. 3x3 격자에 비활성(`off`) 슬롯은 더 이상 없다.
  Verify: `.e2e/plan.test.js` — nine items, nav keys, labels, `keep-all`, and the `/loop-engineering` jump. 2026-08-23: 24 passed, 0 failed. The label regex MUST be `class="(cmr-lbl[^"]*)"`; pinning it to the bare `cmr-lbl` silently dropped the ninth item (the test read 8 of 9).

- **LOOP-2 — the old path `/orchestration` redirects; the old API is gone.**
  EN: `GET /orchestration` returns 200 with a redirect document pointing at `/loop-engineering`, and is matched BEFORE the `/loop-engineering` prefix in `AppDelegate.page`. `GET /api/orchestration` returns **404** — no alias. Note the 404 needs its own explicit branch in `DashboardServer`: the server's final `else` serves the dashboard HTML with 200 for any unmatched path, so without that branch a retired API answers 200 + HTML instead of 404.
  KO: `GET /orchestration` 은 404가 아니라 200으로 `/loop-engineering` 리다이렉트 문서를 돌려주며, `AppDelegate.page` 에서 `/loop-engineering` 보다 먼저 매칭된다. `GET /api/orchestration` 은 **404** 이고 별칭을 두지 않는다. 이 404 에는 `DashboardServer` 안의 전용 분기가 필요하다 — 서버의 마지막 `else` 가 매칭 안 된 경로 전부에 대시보드 HTML 을 200 으로 돌려주므로, 분기가 없으면 은퇴한 API 가 404 대신 200 + HTML 로 답한다.
  Verify: 2026-08-23 live — `/orchestration` 200 (meta refresh 문서), `/loop-engineering` 200, `/api/orchestration` 404, `/api/loop-engineering` 200 + JSON.

- **LOOP-3 — `GET /api/loop-engineering` payload contract.**
  EN: Returns `totals`, `bottleneck`, `openWaits[]`, `projects[]`, `harness[]`, `history[]`, `scannedAt`. Each project carries exactly one `verdict {cat, num, text}` chosen by the fixed ladder in `docs/loop-engineering.md`: dead hop → entry point → termination condition → part → unmeasurable → none. A project with no parts, no hops, no teams and no workers is NOT emitted. Delegations are extracted by the tool name `"name":"Agent"` (NOT `"subagent_type"`, and NOT `Task` — `"name":"Task"` is 0 across the corpus); a delegation with no `subagent_type` counts as `general-purpose`. `LoopScan` descends into `<slug>/<sessionId>/subagents/` and joins `agent-<id>.meta.json`'s `toolUseId` to the hop uid, which is what supplies `totals.innerTurns/innerTools/innerHours/nested/joined` and recovers the duration of background (async) hops.
  KO: `totals`, `bottleneck`, `openWaits[]`, `projects[]`, `harness[]`, `history[]`, `scannedAt` 을 돌려준다. 프로젝트마다 `verdict {cat, num, text}` 가 정확히 하나이며 `docs/loop-engineering.md` 의 고정 사다리(끊긴 홉 → 진입점 → 종료 조건 → 파트 → 측정 불가 → 없음)로 고른다. 파트·홉·팀·워커가 모두 없는 프로젝트는 싣지 않는다. 위임은 도구 이름 `"name":"Agent"` 로 뽑는다(`"subagent_type"` 이 아니고 `Task` 도 아니다 — 코퍼스 전량에서 `"name":"Task"` 는 0건). `subagent_type` 이 없는 위임은 `general-purpose` 로 센다. `LoopScan` 은 `<slug>/<sessionId>/subagents/` 로 내려가 `agent-<id>.meta.json` 의 `toolUseId` 를 홉 uid 에 잇고, 그 조인이 `totals.innerTurns/innerTools/innerHours/nested/joined` 를 채우며 백그라운드(async) 홉의 소요시간을 복구한다.
  Verify: 2026-08-23 live — `runs` 117 (top-level 102 + nested 15), `hours` 16.9, `innerFiles` 112, `joined` 112, `nested` 15. Before the scan-range expansion the same feed said `runs` 92, `hours` 4.0, and every inner field 0. All 112 internal transcripts attribute to a delegation; conversely 112 of 117 hops have one (the 5 without predate the `subagents/` folder).

- **LOOP-4 — the bottleneck band and the open-waits table.**
  EN: The first screen shows one human-bottleneck percentage with its numerator, denominator, sample size, cap policy and stated limits **as visible text, not tooltips**, then an "지금 열려 있는 대기" table sorted by dwell descending. Every row carries a kind, an owner, a dwell, a threshold, a STALLED/정상 verdict, and at least one action. A resolved wait must disappear from the table on the next load. The 28+ project cards render collapsed below it. Hard constraints: (a) the cap is a **policy choice**, labeled as such, and the sensitivity at other caps is printed; (b) the index is a **session-corpus proxy**, not a per-stage (L1..L9) measurement, and must NOT be broken down per stage; (c) the file selector is **session start time**, never file modification time; (d) `stopped` and `cancelled` goals are user-placed holds and must NOT appear in the table nor count toward the index; (e) `trackedSeconds` is never used as busy time anywhere; (f) an owner with no recorded activity prints `기록 없음`, never `0`.
  KO: 첫 화면은 사람 병목 지수 하나를 분자·분모·표본 크기·상한 정책·한계와 함께 **툴팁이 아니라 본문 텍스트로** 보이고, 그 아래 체류 내림차순의 "지금 열려 있는 대기" 표를 보인다. 모든 행에 종류·담당·체류·임계·STALLED/정상 판정·동작 하나 이상이 붙는다. 해소된 대기는 다음 조회에서 표에서 사라져야 한다. 프로젝트 카드는 그 아래에 접힌 채로 그린다. 하드 제약: (a) 상한은 **정책 선택**이며 그렇게 표기하고 다른 상한에서의 값도 함께 적는다. (b) 이 지수는 **세션 코퍼스 대용치**이지 칸별(L1..L9) 측정이 아니며 칸별로 쪼개 그리면 안 된다. (c) 파일 선택자는 **세션 시작 시각**이고 파일 수정 시각을 쓰지 않는다. (d) `stopped` 와 `cancelled` 는 사용자가 쥔 보류라 표에도 지수에도 넣지 않는다. (e) `trackedSeconds` 는 어떤 가동 시간에도 쓰지 않는다. (f) 기록이 없는 담당에는 `0` 이 아니라 `기록 없음` 을 적는다.
  Verify: 2026-08-23 live — band printed 95.5% with 사람 대기 327.9h / 전체 343.5h, 잰 사람 공백 984회, 세션 577개, cap 4h, sensitivity 98.5% (no cap) / 92.0% (1h). Disappearance proven end to end on a throwaway goal: waiting → row present (rows 11→12, dwell 2s, buttons 세션 열기 / 진행으로 / 보류) → `POST /api/goal/status {status:"in_progress"}` → row gone (12→11) → `stopped` → still absent.
  CAVEAT: for a goal with a `sessionId`, the session hook re-parks it as `waiting` within seconds if that session is genuinely still waiting, and `waitingSince` restarts. That is the wait not being over, not the page failing to write. Proven on seq 964 (flipped to `in_progress`, back to `waiting` with dwell reset to 1s).

- **LOOP-5 — `loop-history.jsonl` is append-only and time-gated.**
  EN: `~/.condition-mate/ledger/loop-history.jsonl` gains one line at most every 6 hours, appended via a seek-to-end write. It is NEVER rewritten or truncated. Each line carries the index AND the cap policy AND the raw numerator/denominator, so a later reader can tell which policy produced it. Writing on every page view is a regression: the ledger would become a record of how often the page was opened.
  KO: `~/.condition-mate/ledger/loop-history.jsonl` 은 최소 6시간 간격으로 한 줄씩만 늘어나며, 파일 끝으로 seek 해서 덧붙인다. 절대 다시 쓰거나 자르지 않는다. 각 줄은 지수뿐 아니라 상한 정책과 분자·분모의 원값을 함께 담는다 — 나중에 읽는 사람이 어떤 정책으로 나온 값인지 알 수 있어야 하기 때문이다. 조회마다 적으면 회귀다: 원장이 "페이지를 몇 번 열었나"의 기록이 된다.
  Verify: 2026-08-23 — first line written on the first feed call; repeated calls within the window added none. `Core/LoopHistory.swift` has no write path other than `append()`.

### Intent audit — P8
EN: New page registration, so there is no prior intent to compare against. Two facts previously asserted in `docs/loop-engineering.md`, in `LoopEngineeringContent`'s on-screen note and in the loop-engineering agent definition were found FALSE against disk and corrected in the same change: (1) "subagent internal turns leave no line in the transcript — 0 of 892 files" (they leave 112 transcripts; the scanner simply never descended into `subagents/`), and (2) delegations are traced by a `Task` tool call (the tool is named `Agent`; `"name":"Task"` is 0 across the corpus). A third: the human-bottleneck index published as 97.0% was derived with a file-modification-time selector and is retired in favour of 95.5% under a session-start selector.
KO: 신규 등재라 비교할 이전 의도가 없다. 다만 `docs/loop-engineering.md` 와 화면 안내문과 루프 엔지니어링 에이전트 정의가 함께 주장하던 사실 둘이 디스크와 대조해 **거짓**으로 확인되어 같은 변경에서 정정했다. (1) "서브에이전트의 내부 턴은 트랜스크립트에 한 줄도 남지 않는다 — 892개 파일에서 0건" (실제로는 트랜스크립트 112개가 남으며, 스캐너가 `subagents/` 로 내려가지 않았을 뿐이다). (2) 위임은 `Task` 도구 호출로 추적한다 (도구 이름은 `Agent` 이고 코퍼스 전량에서 `"name":"Task"` 는 0건이다). 셋째로, 97.0퍼센트로 발표됐던 사람 병목 지수는 파일 수정 시각 선택자로 계산된 값이라 폐기하고 세션 시작 시각 기준의 95.5퍼센트로 대체했다.

---

## P9. App window — Slack 번역 페이지 / 상태축
**Purpose / 목적:** **EN:** `/slack-translate` — the state axis that decides what lands in front of the user each day. This page had ZERO spec entries before 2026-09-01, so this is a NEW page registration covering the state axis only, not the whole 2284-line page. Measurement and rationale live in `issue/2026-09-01-slack-미처리-상태축.md` and `best.md`. **KO:** `/slack-translate` — 매일 사용자 앞에 무엇이 놓이는지를 정하는 상태축. 2026-09-01 이전 이 페이지에는 SPEC 항목이 하나도 없었으므로 이것은 **신규 페이지 등재**이며, 2284줄 페이지 전체가 아니라 상태축만 다룬다. 실측과 근거는 `issue/2026-09-01-slack-미처리-상태축.md` 와 `best.md` 에 있다.

- **SLKST-1 — the segment toggle has FOUR states and defaults to `결정 대기`.**
  EN: The toolbar segment is `결정 대기` / `AI 처리` / `백로그` / `전체`, in that order, and the default on a fresh load is `결정 대기`. The chosen value persists in `localStorage` under `cm.slackFilter`. A stored value that is the retired `'open'`, or any value not in the set, MUST fall back to `결정 대기` — a stale localStorage entry that renders an empty screen is a regression. Reverting to the old two-state `미처리 / 전체` toggle is a regression.
  KO: 툴바 세그는 `결정 대기` / `AI 처리` / `백로그` / `전체` 순이고, 새로 열면 기본값은 `결정 대기` 다. 고른 값은 `localStorage` 의 `cm.slackFilter` 에 남는다. 저장된 값이 은퇴한 `'open'` 이거나 집합에 없는 값이면 반드시 `결정 대기` 로 떨어져야 한다 — 낡은 localStorage 때문에 화면이 비면 회귀다. 옛 2상태 `미처리 / 전체` 로 되돌아가는 것도 회귀다.
  Verify: 2026-09-01 Chromium — stored `'open'` and `'zzz'` both fall back to `결정 대기` with a non-empty list; `'backlog'` survives a reload. NOTE: changing the default broke `.e2e/slacktabs.test.js`, whose fixtures all carry `ackAt` and so no longer appear in the default segment. That is the intended behavior change, not a bug; the test now seeds `cm.slackFilter='all'` in its `addInitScript` (`:88`) because that file tests tabs and extraction, not the segment axis. After the seed: 23 passed, 0 failed.

- **SLKST-2 — the bucket ladder is fixed and evaluated top-down, once.**
  EN: Every item resolves to exactly one bucket by this ladder, first match wins: `done` if `done.json[id]` or `autoDone` → `backlog` if `backlogClosedAt` → `ai` if `ackAt` → otherwise `wait`. Consequences that are NOT bugs: an item graded post-08-29 (`ackGrade`/`requestLevel` present) but with no `ackAt` lands in `wait`, because the AI looked at it and chose not to act, so a human must. An item both `backlogClosedAt` and `ackAt` lands in `backlog`, because the ladder is ordered. Reordering the ladder changes the counts and is a behavior change, not a refactor.
  KO: 모든 항목은 이 사다리로 정확히 하나의 칸에 떨어지며 먼저 걸리는 것이 이긴다: `done.json[id]` 또는 `autoDone` 이면 `done` → `backlogClosedAt` 이면 `backlog` → `ackAt` 이면 `ai` → 아니면 `wait`. 버그가 **아닌** 귀결: 08-29 이후 등급(`ackGrade`/`requestLevel`)은 있는데 `ackAt` 이 없는 항목은 `wait` 로 간다 — AI가 보고서 행동하지 않기로 했으므로 사람이 판단해야 한다. `backlogClosedAt` 과 `ackAt` 이 둘 다 있으면 `backlog` 로 간다 — 사다리에 순서가 있기 때문이다. 사다리 순서를 바꾸면 건수가 바뀌므로 리팩터가 아니라 동작 변경이다.

- **SLKST-3 — every new field is optional and absence is the default.**
  EN: `backlogClosedAt`, `backlogReason`, `ackAt`, `autoByMe` do NOT exist on old records and their absence is the normal case. Absent `backlogClosedAt` → not backlog. Absent `ackAt` → not AI-handled. For `autoByMe` the three-way distinction is load-bearing: `true` = the user themself reacted in Slack, `false` = somebody else did, `undefined` = **unknown, an old record**. Collapsing `undefined` into `false` is a regression — "somebody else did it" and "we do not know who did it" are different facts and the UI must not claim the former when it only knows the latter.
  KO: `backlogClosedAt`, `backlogReason`, `ackAt`, `autoByMe` 는 옛 레코드에 **없으며** 없는 것이 정상이다. `backlogClosedAt` 없음 → 백로그 아님. `ackAt` 없음 → AI 처리 아님. `autoByMe` 는 세 값의 구분이 의미를 진다: `true` = 사용자 본인이 슬랙에서 리액션함, `false` = 다른 사람이 함, `undefined` = **모름, 옛 레코드**. `undefined` 를 `false` 로 뭉개면 회귀다 — "다른 사람이 했다" 와 "누가 했는지 모른다" 는 다른 사실이고, 후자만 아는 상태에서 전자를 주장하면 안 된다.

- **SLKST-4 — the done chip names WHO closed it.**
  EN: The `autoDone` chip is not one label any more. `autoByMe === true` → `✅ 내가 슬랙에서 처리`; `autoByMe === false` → `✅ 다른 사람이 처리`; `autoByMe === undefined` → the legacy `✅ 이모지로 해결됨`. Independently, an item with `ackAt` also wears `🤖 AI 응답함`, and an item with `backlogClosedAt` wears `🗄 백로그`. This exists because 606 of the 938 `autoDone` records carry `autoBy: U03GRE909MJ`, which is the user themself — the old single label presented the user's own manual Slack work as automation output. Merging these chips back into one is a regression.
  KO: `autoDone` 칩은 더 이상 하나의 라벨이 아니다. `autoByMe === true` → `✅ 내가 슬랙에서 처리`, `autoByMe === false` → `✅ 다른 사람이 처리`, `autoByMe === undefined` → 기존 `✅ 이모지로 해결됨`. 이와 별개로 `ackAt` 이 있는 항목은 `🤖 AI 응답함` 을, `backlogClosedAt` 이 있는 항목은 `🗄 백로그` 를 함께 단다. 이 구분이 있는 이유는 `autoDone` 938건 중 606건의 `autoBy` 가 `U03GRE909MJ` = 사용자 본인이기 때문이다 — 옛 단일 라벨은 사용자가 손으로 한 일을 자동화 성과처럼 보이게 했다. 칩을 다시 하나로 합치면 회귀다.

- **SLKST-5 — backlog closing is reversible, local, and never touches Slack.**
  EN: `Scripts/slack-backlog-close.mjs` defaults to `--dry-run`; only `--apply` writes, and `--undo` reverses. Before any write it copies `items.jsonl` to `items.jsonl.bak.<timestamp>`. It MUST NOT send anything to Slack — no reaction, no message, no API call — and MUST NOT modify `done.json`, because a `done.json` change makes the app attempt a Slack reaction sync. It adds only `backlogClosedAt` and `backlogReason:"pre-grading-pipeline"`. The line count of `items.jsonl` must be unchanged after a run, and unparseable lines are rewritten verbatim rather than dropped. Closing is not deleting: closed items stay in the corpus, remain visible under the `백로그` segment, and come back on `--undo`.
  KO: `Scripts/slack-backlog-close.mjs` 의 기본은 `--dry-run` 이고 `--apply` 를 줘야 쓰며 `--undo` 로 되돌린다. 쓰기 전에 `items.jsonl` 을 `items.jsonl.bak.<타임스탬프>` 로 복사한다. 슬랙에 **아무것도 보내지 않는다** — 리액션도 메시지도 API 호출도 없다. `done.json` 도 고치지 않는다 — done.json 이 바뀌면 앱이 슬랙 리액션 동기화를 시도하기 때문이다. 붙이는 것은 `backlogClosedAt` 과 `backlogReason:"pre-grading-pipeline"` 뿐이다. 실행 후 `items.jsonl` 의 줄 수가 변하면 안 되고, 파싱 실패한 줄은 버리지 말고 원문 그대로 다시 쓴다. 마감은 삭제가 아니다 — 항목은 코퍼스에 남고 `백로그` 세그에서 보이며 `--undo` 로 돌아온다.

- **SLKST-6 — the count line prints all four numbers.**
  EN: The header count reads `결정 대기 N · AI 처리 N · 백로그 N · 전체 M`, with the `📌 Later` sub-count appended after `결정 대기` when non-zero. The `📌 Later` collapsible sub-section stays INSIDE the `결정 대기` view; it does not become a fifth segment. When `결정 대기` is empty the empty state says so as a good outcome, and if a backlog remains it also states the backlog count so the user does not forget it exists.
  KO: 헤더 카운트는 `결정 대기 N · AI 처리 N · 백로그 N · 전체 M` 이며, `📌 Later` 가 0이 아니면 `결정 대기` 뒤에 지금처럼 붙인다. `📌 Later` 접이식 하위 섹션은 `결정 대기` 뷰 **안에** 그대로 남는다 — 다섯 번째 세그가 되지 않는다. `결정 대기` 가 비면 빈 상태는 그것을 좋은 결과로 적고, 백로그가 남아 있으면 그 건수도 함께 적어 사용자가 잊지 않게 한다.
  Verify: 2026-09-01 corpus (`items.jsonl` 1670 lines, 1670 unique ids) — after applying the backlog close the four numbers are 결정 대기 **10** · AI 처리 **24** · 백로그 **193** · 전체 **1670**. Before the change the single number was 미처리 **227**. Cross-tab that produced these: post-08-29 with `ackAt` 24, post-08-29 graded-only 9, post-08-29 untouched 1, pre-08-29 untouched 193; zero pre-08-29 items carry `ackAt`.

- **SLKST-7 — ✅ requires positive evidence; "unknown" gets the pending emoji, never ✅.**
  EN: The auto-reaction layer resolves a `decision` axis with exactly three values before it picks an emoji. `not-needed` — a level0/heavy vocabulary row actually matched a closing word (understood / noted / 알겠습니다 / 진행하겠습니다) — is the ONLY state that may post `white_check_mark`. `needed` — `vetoReason()` hit (묻는다 · 요청한다 · 막혀 있다 · 장애 · over `maxChars`) — and `unknown` — the bare-floor R1 and group-address paths where no signal matched at all — both post the row named by `pendingEmoji` in `slack-emoji-layer.json`. Making ✅ the fallback again is a regression, and so is collapsing `unknown` into `not-needed`: "we could not classify it" and "nothing is being decided" are different facts. The response grades R0/R1/R2 are NOT changed by this axis — only which emoji rides along. The emoji name is read from JSON; hardcoding it in `emoji-layer.mjs` is a regression.
  KO: 자동 리액션 레이어는 이모지를 고르기 전에 `decision` 축을 세 값 중 하나로 판정한다. `not-needed` — level0/무거운 어휘집이 실제로 닫는 말(understood / noted / 알겠습니다 / 진행하겠습니다)을 물었을 때 — 만이 `white_check_mark` 를 달 수 있는 유일한 상태다. `needed` — `vetoReason()` 이 걸렸을 때(묻는다 · 요청한다 · 막혀 있다 · 장애 · `maxChars` 초과) — 와 `unknown` — 아무 신호도 안 잡힌 바닥값 R1 과 단체 수신 경로 — 는 둘 다 `slack-emoji-layer.json` 의 `pendingEmoji` 가 지목한 행을 단다. ✅ 를 다시 바닥값으로 되돌리면 회귀이고, `unknown` 을 `not-needed` 로 뭉개는 것도 회귀다 — "분류하지 못했다" 와 "의사결정이 필요 없다" 는 다른 사실이다. 응답 등급 R0/R1/R2 는 이 축으로 바뀌지 않는다 — 함께 실리는 이모지만 바뀐다. 이모지 이름은 JSON 에서 읽는다. `emoji-layer.mjs` 에 이름을 박으면 회귀다.
  Why / 근거: 2026-09-02, `C0BU7LC0QSH:1788337575.269469`. 원장 한 줄이 경로를 그대로 보여준다 — `ack-emoji … 선응답을 :white_check_mark: 로 대체 · 길다(1785자 > 240) → R2 이상 후보`. 즉 ✅ 는 "확인했다"의 결과가 아니라 "글을 못 썼다"의 결과로 나갔다. 리액션은 `USER_TOKEN`(xoxp)으로 나가므로 동료에게는 라이언 본인이 단 것으로 보였고(`slack-eyes-daemon.mjs:500`, `:1995`), Elma 가 채널에 "green check from Lion is from his AI agent. That is not automatic approval." 를 써야 했다(`1788345311.440649`). 원장 `ack-emoji` 158건 전수: 어휘집 일치 21 · veto 강등 60 · 바닥값 60 · 단체 10 · 무거운 어휘 5 · 모델 2 — **근거가 있었던 것은 26건(16%)뿐이다** (어휘집 일치 21 + 무거운 어휘 5).
  Verify: 2026-09-02 — `Sources/Plugins/Slack/Daemon/emoji-layer.decision.test.mjs` 18 pass / 0 fail (`node --test`). 기존 단위 시험 다섯(`send-layer`, `send-layer.gate`, `people-context`, `reply-language`, `security-gate`)과 `.e2e/slackemoji.test.js`·`slackalignment.test.js` 전부 exit 0. NOTE: 어휘집에 행이 하나 늘면서 `.e2e/slackemoji.test.js` 의 세 단언이 깨졌고 — 자동 이모지 개수 6, L0 목록이 🫡·✅ 둘, "모든 auto 항목은 판정 정규식을 갖는다" — 셋 다 **의도한 동작 변경**이라 시험을 고쳤다(개수 7, L0 셋, 정규식 검사는 `match` 가 있는 행만). 대신 보는 중 행이 `match` 를 갖지 않고 `pendingEmoji` 이며 `resolves:false` 라는 단언 넷을 새로 넣었다 — 정규식을 주면 어휘 일치로도 뽑히게 되어 이 항목의 규칙이 반대편으로 열린다. `.e2e` 의 `slackdefects`·`slackdegrade`·`slackpipe`·`slackanswer` 넷은 실패하지만 **변경 전 코드(앱 번들 사본)로 되돌려도 똑같이 넷 다 실패**하므로 이 변경과 인과가 없다(`untranslatedSegments`·`peopleContextModule` 미정의, 임시 폴더에 `security-gate.mjs` 미복사).

- **SLKST-8 — only a reaction the user placed themself closes an item, and never one this system posted.**
  EN: No reaction may move an item out of the user's 미처리 queue EXCEPT one the user placed themself that is not an emoji this system posted on that same item — `e.user === MY_USER && baseEmoji(e.reaction) ∉ ourAckEmojis(item)`. A reaction placed by anyone else still does NOT close the item; "someone else handled it" and "the user handled it" are different facts. **Gating on `MY_USER` alone is a regression** — the daemon posts its reactions with the user's own `USER_TOKEN` (xoxp), so its own ack emoji comes back over the socket as `e.user === MY_USER`; that is the 2026-09-02 incident itself. The rule lives in the catalog JSON as the workspace-level key `resolvesPolicy`, whose values are `"none"` (nothing resolves), `"self"` (the rule above), and `"catalog"` (the pre-2026-09-02 behaviour: per-row `resolves` decides and names absent from the catalog resolve). The two fallbacks are UNCHANGED: a catalog with no `resolvesPolicy` key at all still reads as `"catalog"` so pre-existing catalogs are byte-for-byte unchanged, and an unreadable catalog or a value that is not one of the three still fails CLOSED to `"none"` and logs once. `isResolvingEmoji(name, ctx)` / `resolvingReaction(reactions, ctx)` / `firstNonTrigger(names)` in `slack-eyes-daemon.mjs` remain the ONLY gate, and all three auto-close paths (collection, `reconcile`, the `reaction_added` socket handler) pass through them; `self` needs to know who reacted and on which item, so the gate's INPUT widened (`ctx = { by, item }`) instead of the condition being scattered into the call sites — scattering it is a regression, because one of the three paths always ends up bypassing the gate. Under `"self"` the gate is fail-closed: missing `ctx`, missing `ctx.by`, missing `ctx.item`, or a `MY_USER` that `auth.test` has not filled in yet all return `false`. That one rule also decides the collection path: at collection time the item does not exist yet, so `processMessage` passes `{ item: null }` and NOTHING closes on collection under `"self"` — re-triggering an already-✅'d message with 👀 means "I want to look again", and closing it in the same instant would make that 👀 meaningless. A special-case branch for collection is a regression. Behaviour change: the app card-toolbar quick reaction (`/api/slack/reaction` → `SlackTranslateStore.setReaction`) now DOES close the item, because it also goes out on `USER_TOKEN` and pressing it is just as deliberate as reacting in Slack; the one accepted limitation is that a toolbar emoji identical to the item's own ack emoji will not close it, since the self-emoji exclusion wins. **`postEmojiReaction()` MUST write `ackEmoji`/`ackEmojis` to disk BEFORE calling `reactions.add`, and roll them back if the call fails. Reversing that order is a regression** — the `reaction_added` for the emoji we just posted arrives over the socket before the `await` resolves, and at that instant the item on disk carries no ack emoji, so the exclusion set is empty and the daemon closes the item with its own reaction. A disk write is sufficient and an in-memory `Set` is not: `rewriteItem()` is synchronous (`readFileSync` → `writeFileSync` → `renameSync`), `loadItems()` re-reads the file on every call with no cache, node is single-threaded so no event can interleave, and the value survives the 23–27 daemon restarts a day that an in-memory set would not. `ackEmojis: string[]` accumulates every emoji this system posted on the item and `ackEmoji` keeps its old meaning as the latest one — the dashboard reads that scalar as a string, so widening it would break the reader. Comparison is against the UNION `ackEmojis ∪ ackEmoji`, which is why records written before this field exists still work: they yield a one-element set. Both fields are optional and their absence yields the empty set. Under `"self"` the `reaction_removed` handler MUST NOT decide with `firstNonTrigger(left)` — `item.reactions` stores names only and never users, so that function can never build `ctx.by` there and is always null, `!null` is always true, and every reaction removal would mass-reopen every past `autoDone` item. It decides instead on what actually closed the item: reopen only when `it.autoDone && it.autoBy && e.user === it.autoBy && baseEmoji(e.reaction) === baseEmoji(it.autoEmoji)`. A record without `autoBy` is fail-closed, which HERE means "leave it as it is"; mass reopening is the harm at this site. The `"none"` and `"catalog"` branches are unchanged to the letter. This item is forward-looking only: historical `auto.done` rows are NOT reopened, and the 128 open items that already carry a reaction are NOT retroactively closed — deciding `e.user === MY_USER` for them needs `reactions.get` (currently failing on every call, tracked separately) and approximating it by name alone would close 98 of them, including the other-people reactions this rule deliberately leaves open. `emojiSafeToPost()` must keep refusing trigger emojis (`eyes` / `bookmark` / `pushpin`) regardless of the policy — posting 👀 re-collects the item through `reaction_added(MY_USER)` and loops. Hardcoding an emoji name, or the workspace's policy VALUE, in the daemon is a regression (same reason as SLKST-7); branching on the policy the JSON selected is not the same thing as choosing that policy in code.
  KO: 어떤 리액션도 항목을 라이언의 미처리에서 빼지 못한다 — **단, 라이언 본인이 직접 달았고 그것이 이 시스템이 그 항목에 단 이모지가 아닌 경우는 예외다** (`e.user === MY_USER && baseEmoji(e.reaction) ∉ ourAckEmojis(item)`). 남이 단 리액션은 여전히 항목을 닫지 못한다 — 남이 처리했다는 것과 라이언이 처리했다는 것은 다른 사실이다. **`MY_USER` 조건만 거는 것은 회귀다** — 데몬이 라이언의 `USER_TOKEN`(xoxp)으로 리액션을 달기 때문에 자기 ack 이모지가 소켓에 `e.user === MY_USER` 로 되돌아온다. 그것이 2026-09-02 사고 그 자체다. 규칙이 사는 자리는 어휘집 JSON 의 워크스페이스 단위 키 `resolvesPolicy` 이고, 값은 `"none"`(아무것도 닫지 않는다) · `"self"`(위 규칙) · `"catalog"`(2026-09-02 이전 동작 — 행 단위 `resolves` 가 정하고 어휘집에 없는 이름은 닫는다) 셋이다. **바닥값 두 갈래는 그대로 둔다**: `resolvesPolicy` 키가 아예 없는 어휘집은 여전히 `"catalog"` 로 읽어 예전과 바이트 단위로 같게 돌고, 어휘집을 못 읽거나 셋 중 어느 것도 아닌 값이 적혀 있으면 여전히 `"none"` 으로 **닫히는 쪽으로 실패**하고 한 번 로그를 남긴다. `slack-eyes-daemon.mjs` 의 `isResolvingEmoji(name, ctx)`·`resolvingReaction(reactions, ctx)`·`firstNonTrigger(names)` 셋이 계속 **유일한 문**이고 자동 처리완료 경로 셋(수집 · `reconcile` · `reaction_added` 소켓 처리)이 전부 여기를 지난다. `self` 는 누가 어느 항목에 달았는지를 알아야 하므로 문의 **입력**을 넓혔다(`ctx = { by, item }`) — 조건을 호출부로 흩뿌리면 회귀다. 흩뿌리면 셋 중 하나가 반드시 문을 우회한다. `"self"` 아래의 문은 fail-closed 다 — `ctx` 가 없거나 `ctx.by` 가 없거나 `ctx.item` 이 없거나 `auth.test` 가 아직 `MY_USER` 를 안 채웠으면 전부 `false` 다. 그 규칙 하나가 수집 경로도 정한다: 수집 시점에는 항목이 아직 없으므로 `processMessage` 는 `{ item: null }` 을 넘기고, 따라서 `"self"` 아래에서 수집 시점에는 아무것도 닫히지 않는다 — 이미 ✅ 가 달린 메시지에 👀 를 다시 다는 것은 "다시 보겠다" 이고 그 순간 닫으면 그 👀 가 무의미해진다. 수집만을 위한 특례 분기를 두면 회귀다. **동작 변경**: 앱 카드 툴바의 빠른 리액션(`/api/slack/reaction` → `SlackTranslateStore.setReaction`)이 이제 항목을 닫는다. 그쪽도 `USER_TOKEN` 으로 나가고 툴바에서 누르는 것은 슬랙에서 다는 것과 똑같이 의도된 행위이기 때문이다. 받아들인 한계가 하나 있다 — 툴바에서 누른 이모지가 그 항목의 ack 이모지와 같으면 닫히지 않는다(자기 이모지 배제가 이긴다). **`postEmojiReaction()` 은 `reactions.add` 보다 먼저 `ackEmoji`/`ackEmojis` 를 디스크에 적어야 하고, 그 호출이 실패하면 되돌려야 한다. 순서를 뒤집으면 회귀다** — 우리가 방금 단 이모지의 `reaction_added` 가 그 `await` 이 풀리기 전에 소켓으로 돌아오고, 그 시점의 항목에는 ack 이모지가 없어 제외 집합이 비므로 데몬이 자기 리액션으로 자기 항목을 닫는다. 디스크 쓰기 하나로 충분하고 인메모리 `Set` 은 답이 아니다: `rewriteItem()` 은 `readFileSync` → `writeFileSync` → `renameSync` 로 동기이고, `loadItems()` 는 호출마다 파일을 다시 읽으며 캐시가 없고, node 는 단일 스레드라 그 사이에 이벤트가 끼지 못하고, 하루 23~27회인 데몬 재시작을 디스크 값은 넘어 살아남지만 `Set` 은 그 창에서 뚫린다. `ackEmojis: string[]` 는 이 시스템이 그 항목에 단 이모지를 누적하고 `ackEmoji` 는 지금 뜻 그대로 **최신 하나**를 들고 간다 — 대시보드가 그 스칼라를 문자열로 읽으므로 배열로 바꾸면 읽는 쪽이 깨진다. 비교는 **합집합** `ackEmojis ∪ ackEmoji` 로 한다. 그래서 이 필드가 생기기 전에 쓰인 레코드도 그대로 돈다 — 원소 하나짜리 집합이 된다. 두 필드는 모두 선택 항목이고 없으면 빈 집합이다. `"self"` 아래에서 `reaction_removed` 처리는 `firstNonTrigger(left)` 로 판정하면 안 된다 — `item.reactions` 는 이름만 저장하고 누가 달았는지를 저장하지 않아 그 함수는 거기서 `ctx.by` 를 만들 수 없고 언제나 null 이며, `!null` 이 항상 참이 되어 리액션 하나 뗄 때마다 예전에 자동 처리완료된 항목이 전부 되살아난다. 대신 **항목을 실제로 닫은 그것**으로 판정한다: `it.autoDone && it.autoBy && e.user === it.autoBy && baseEmoji(e.reaction) === baseEmoji(it.autoEmoji)` 일 때만 되돌린다. `autoBy` 가 없는 옛 레코드는 fail-closed 이고, **여기서 fail-closed 의 뜻은 "지금 상태를 유지" 다** — 무더기 재개방이 이 자리의 해악이다. `"none"` 과 `"catalog"` 갈래의 조건은 글자 단위로 그대로 둔다. 이 항목은 **앞을 향할 뿐이다**: 원장에 남은 `auto.done` 을 소급해 다시 열지 않고, 이미 리액션이 달린 채 열려 있는 128건도 소급해 닫지 않는다 — 그 128건에 대해 `e.user === MY_USER` 를 판정하려면 `reactions.get`(오늘 전수 실패, 별건)이 필요하고, 이름만으로 근사하면 98건이 닫히는데 그 안에 이 규칙이 일부러 열어 두기로 한 "남이 단 리액션" 이 섞인다. `emojiSafeToPost()` 는 정책이 무엇이든 트리거 이모지(`eyes` / `bookmark` / `pushpin`)를 계속 거부해야 한다 — 👀 를 달면 `reaction_added(MY_USER)` 로 재수집되어 루프가 돈다. 이모지 이름이나 워크스페이스의 정책 **값**을 데몬에 박으면 회귀다(SLKST-7 과 같은 이유). JSON 이 고른 정책에 따라 갈라지는 것과 그 정책을 코드가 고르는 것은 다른 일이다.
  Why / 근거: 2026-09-02 라이언 결정이 `"none"` 이었다 — "어떤 리액션도 항목을 닫지 않는다. 미처리는 손으로 닫는다. 리액션은 '봤다'는 표시일 뿐이고 미처리 목록에서 항목을 빼는 권한은 사람 손에만 있다." 그 결정이 도는 데몬에 실제로 걸린 것은 2026-09-04 04:22 KST 다. **2026-09-06 에 라이언이 그것을 `"self"` 로 좁혔다** — "우리가 단 이모지만 빼고 다시 연다". 근거는 그날 실측이다(`~/.condition-mate/slack-translate/items.jsonl` **2,004줄, 파싱 실패 0**). 자동 처리완료 **1,083건**의 내역: 데몬이 자기가 단 이모지에 걸려 닫은 것 **155건(14.3%)** · 라이언이 슬랙에서 손으로 단 것 **557건(51.4%)** · 남이 단 것 **371건(34.3%)**. 닫힌 1,607건 중 1,083건(67.4%)이 이 경로였으므로 `"none"` 이 없앤 것은 처리량의 3분의 2였고 대체 경로는 만들지 않았다. **사고는 155건짜리 부분집합인데 정책이 1,083건 전부를 껐다.** `"self"` 는 155건을 계속 막고 557건을 되살리고 371건은 계속 열어 둔다. 소급을 안 하는 근거도 같은 실측이다 — 열린 항목 **397건** 중 트리거가 아닌 리액션이 달린 것 **128건**, 그중 `ackEmoji` 를 가진 것 **70건**, 비트리거 리액션이 우리 `ackEmoji` **뿐**인 것 **30건**, 앱 대장 `reactions.json` 에 있는 것 **0건**. `item.reactions` 는 이름 다중집합만 저장하고 누가 달았는지를 저장하지 않으므로 로컬 데이터만으로는 `MY_USER` 판정이 불가능하다. `ackEmojis` 를 더한 근거: `ackEmoji` 는 스칼라라 갈아치워지고 실제로 `ackSupersededAt` 을 가진 항목이 **2건** 있다. 대안 셋을 버렸다 — (i) `ackEmoji` 를 배열로 바꾸면 대시보드·원장·시험이 스칼라를 읽고 있어 하위 호환이 깨지고, (ii) `ackSupersededAt` 에는 갈아치운 **시각**만 있고 무엇에서 무엇으로인지가 없고, (iii) 오늘 실제로 다는 `ackEmoji` 가 세 종류뿐(`white_check_mark` 172 · `mag` 107 · `saluting_face` 16)이라는 것을 코드에 박는 것은 이 항목이 금지한 이모지 이름 하드코딩이다. 이 배치는 사람에게 아무것도 발신하지 않는다 — `autoResolve()` → `markDone()` → `setDoneRemote()` 는 `{ sync: false }` 로 루프백 `POST /api/slack/done` 을 부르고, `AppDelegate.swift` 의 그 핸들러는 `sync == true` 일 때만 `syncReaction` 을 부른다. 자동 처리완료는 슬랙에 이모지도 스레드 답장도 남기지 않는다.
  Verify: 2026-09-06 — `Sources/Plugins/Slack/Daemon/emoji-layer.decision.test.mjs` **50 pass / 0 fail** (`node --test`). 변경 전 기준선은 같은 파일 **39 pass / 0 fail** 이었다. 기존 39개 중 **다섯**이 깨졌고 전부 계약이 아니라 **오늘의 점유**를 재고 있던 단언이라 새 점유로 고쳤다: (1) `T4 사전 확인` 의 `RESOLVES_POLICIES` 가 `['none','catalog']` 라는 단언 → `['none','self','catalog']`; (2) `T4 ✅ 도 👍 도 항목을 닫지 않는다` 의 번들 값 단언 `'none'` → `'self'` 이고 "닫지 않는다" 를 `self` 계약(남이 단 것 · 우리가 단 것 · 행 단위 `resolves:false`)으로 다시 씀; (3) `T4 emojiSafeToPost` 가 번들 기본값을 `'none'` 으로 가정하던 것 → 세 정책을 전부 명시적으로 만들어 돌리게 고쳐 번들 값이 무엇이 되든 다시 안 깨지게 함; (4) `autoUnresolve` 가드 원문 단언 → 새 가드를 재는 단언 셋으로 다시 씀(`none` 갈래 원문 · `self` 갈래의 세 조건 · `self` 갈래에 `firstNonTrigger` 가 없다는 것). 정규식을 느슨하게 지우지 않았다; (5) 번들 어휘집 단언 `resolvesPolicy === 'none'` → `'self'` 이고 SLKST-9 산문 단언(값이 셋 · 현재 값 · `_axis_doc` 에 `none` 없음)을 더함. 나머지 34개는 그대로 통과한다 — `"catalog"` 와 fail-closed 두 갈래가 바이트 단위로 안 바뀌었다는 근거가 그것이다(하네스만 고친 원본 시험 파일을 새 데몬에 대고 돌려 34 pass / 5 fail 로 확인). 새로 넣은 시험 열하나: 데몬이 단 ack 이모지가 `MY_USER` 로 되돌아와도 안 닫힌다(스칼라·배열·갈아치운 뒤·스킨톤 넷) · `MY_USER` 가 손으로 단 다른 이름은 닫는다 · 남이 단 것은 안 닫고 `r.users` 중간의 `MY_USER` 는 잡는다 · `ctx`/`ctx.item`/`MY_USER` 가 없으면 fail-closed 이고 수집 경로가 그 규칙 하나로 덮인다 · **쓰기 순서 경합** — `postEmojiReaction` 원문을 잘라 실제로 돌리고 `reactions.add` 가 불리는 그 순간에 소켓 핸들러가 하는 일(디스크를 다시 읽어 `isResolvingEmoji` 에 묻기)을 그대로 시켜, 그 시점의 판정이 `false` 임을 단언한다 · `reactions.add` 가 실패하면 선기록을 되돌리고 `already_reacted` 면 되돌리지 않는다 · `reaction_removed` 가 옛 `autoDone` 을 무더기로 되살리지 않는다(가드 원문을 잘라 실행, 다섯 갈래) · 닫은 그 이모지를 그 사람이 뗐을 때만 되살아난다 · `none`·`catalog` 가드는 예전 그대로다 · `ourAckEmojis` 하위 호환 · `withAckEmoji` 누적. **경합 시험이 실제로 경합을 잰다는 것을 확인했다** — `postEmojiReaction` 의 쓰기 순서를 `reactions.add` 먼저로 되돌리면 T8-5 두 개가 정확히 실패하고(소켓 판정이 `false` → `true` 로 뒤집힌다) 나머지 48개는 통과한다. 되돌린 것은 곧바로 원상복구했다. 이웃 시험 전부 통과 — `ack-sources` 15 pass / 0 fail · `send-layer` 15 passed / 0 failed · `send-layer.gate` exit 0 · `people-context` 16 pass / 0 fail · `reply-language` 24 passed / 0 failed · `security-gate` 18 passed / 0 failed · `.e2e/slackemoji.test.js` exit 0 · `.e2e/slackalignment.test.js` exit 0. `.e2e` 의 `slackdegrade`·`slackpipe`·`slackdefects` 셋은 여전히 실패하지만 **변경 전 트리(데몬·어휘집을 변경 전 사본으로 되돌린 것)에서 같은 오류 문자열로 실패하는 것을 실제로 확인**했다 — 앞의 둘은 `ERR_MODULE_NOT_FOUND: security-gate.mjs`(하네스가 데몬만 tmpdir 로 복사한다), 셋째는 `ReferenceError: untranslatedSegments is not defined` 다. 코퍼스: `items.jsonl` **2,004줄 전수 파싱 실패 0**. `ackEmoji` 를 가진 것 295건이고 `ackEmojis` 배열을 가진 것은 아직 0건인데, `ourAckEmojis` 가 그 295건 전부를 원소 하나짜리 집합으로 읽는다(옛 줄 하위 호환 실행 확인). `autoDone` 1,083건 전부가 `autoBy` 를 갖고 있어 `reaction_removed` 의 fail-closed 에 걸리는 옛 레코드는 0건이다. 키는 어느 파일·로그·오류 문자열에도 실리지 않았다 — 이 배치는 키체인을 열지 않는다.

- **SLKST-9 — the emoji rule lives in two places and they must not diverge.**
  EN: The same rule is written twice on purpose — as prose the model reads (`Sources/Plugins/Slack/Daemon/reply-policy/router.md`) and as deterministic values the code reads (`slack-emoji-layer.json` + `emoji-layer.mjs`). Both must state the same three rules: decision-needed → pending emoji; decision-not-needed → ✅; never ✅ on decision-needed. If the JSON's `pendingEmoji` changes, `router.md` and the level files must say the same name. A policy file that names an emoji the catalog does not carry is a regression — the prose would be describing behavior that cannot happen. The level policy set is split on the L0~L5 컨텍스트 축 and must not be renumbered onto R0~R4, F0~F3, E2~E4, C0~C2, or permission 1~9.
  KO: 같은 규칙이 일부러 두 곳에 적혀 있다 — 모델이 읽는 산문(`Sources/Plugins/Slack/Daemon/reply-policy/router.md`)과 코드가 읽는 결정값(`slack-emoji-layer.json` + `emoji-layer.mjs`)이다. 둘은 같은 세 줄을 말해야 한다: 의사결정 필요 → 보는 중 이모지, 필요 없음 → ✅, 의사결정이 필요한 글에 ✅ 금지. JSON 의 `pendingEmoji` 가 바뀌면 `router.md` 와 레벨 파일도 같은 이름을 적어야 한다. 어휘집에 없는 이모지를 정책 파일이 지목하면 회귀다 — 일어날 수 없는 동작을 산문이 설명하는 상태가 된다. 레벨 정책 묶음은 L0~L5 컨텍스트 축으로 쪼갠 것이며, R0~R4 · F0~F3 · E2~E4 · C0~C2 · permission 1~9 로 번호를 갈아끼우면 안 된다.

- **SLKST-10 — the auto-reaction runs only on sources the policy names, and the floor is `mention` alone.**
  EN: `acknowledgementOn()` in `slack-eyes-daemon.mjs` must read its allowed-source list from `ackSources` in `slack-ack-cost-policy.json` (bundled, overridable by `~/.condition-mate/slack-translate/ack-cost-policy.json`). Hardcoding the list back into the daemon is a regression. When the key is absent, not an array, or the policy cannot be read, the list falls back to `["mention"]` — the NARROW side. "We could not read the policy" must never widen who gets reacted to. A source not on the list gets no 🔍 and no evidence layer: `postAcknowledgement()` is the single entry for both the reaction (`postEmojiReaction`) and context acquisition (`ackEvidence` — Jira/Notion/web research/related threads/attachments — plus people-context 축 0, problem-frame 축 2, novelty gate), so splitting the two behind separate gates is a regression that would burn model calls invisibly. This axis does NOT change collection: `sourceOn()` and `mentionKind()` are untouched, so `dm`/`broadcast` items are still collected, translated, and listed on the dashboard. Reacting is a Slack-visible act; collecting is not.
  KO: `slack-eyes-daemon.mjs` 의 `acknowledgementOn()` 은 허용 소스 목록을 `slack-ack-cost-policy.json` 의 `ackSources` 에서 읽어야 한다(번들 정본, `~/.condition-mate/slack-translate/ack-cost-policy.json` 으로 덮어쓰기 가능). 목록을 데몬에 다시 박으면 회귀다. 키가 없거나 배열이 아니거나 정책을 못 읽으면 `["mention"]` 로 떨어진다 — **좁은 쪽**이다. "정책을 못 읽었다" 가 리액션 대상을 넓히는 사유가 되어서는 안 된다. 목록에 없는 소스에는 🔍 도 근거 레이어도 돌지 않는다: `postAcknowledgement()` 하나가 리액션(`postEmojiReaction`)과 컨텍스트 확보(`ackEvidence` — Jira·Notion·웹 리서치·다른 스레드·첨부 — 그리고 people-context 축 0, problem-frame 축 2, 신규성 게이트)의 공통 입구라서, 둘을 다른 게이트 뒤로 갈라 두면 이모지는 안 붙는데 모델 호출만 도는 상태가 생긴다. 이 축은 수집을 바꾸지 않는다: `sourceOn()`·`mentionKind()` 는 그대로라 `dm`·`broadcast` 항목은 계속 수집·번역되고 대시보드에 뜬다. 리액션은 슬랙에 보이는 행위이고 수집은 아니다.
  Why / 근거: 2026-09-02 라이언 구술 — "나 멘션한 거 말고도 모든 메시지에 다 돋보기를 달고 있거든. 그렇게 지금 커뮤니케이션 코스트를 엄청나게 만들고 있어." 그때까지 목록은 `['mention','team','dm','broadcast']` 로 코드에 박혀 있었고, `dm` 은 DM·**그룹DM 채널의 모든 새 메시지**를 뜻한다. 실측: `items.jsonl` 1792건 중 mention 803 · dm 588(1:1 358 · 그룹DM 230 · 38개 방) · broadcast 83 · team **0**. 원장 `actions-daemon.jsonl` 의 `ack-emoji` 195건 중 **78건(40%)** 이 라이언이 불리지도 않은 자리였고, 🔍 도입 첫날 나간 30건만 보면 **20건(67%)** 이 그 자리였다. 리액션은 `USER_TOKEN`(xoxp)으로 나가 라이언 본인이 단 것으로 보이므로(SLKST-7 의 근거와 같은 구조), 그가 있을 뿐인 38개 그룹 DM 의 남의 대화마다 "라이언이 이걸 들여다보고 있다" 가 찍혔다. 대시보드 체크박스로는 못 고친다 — `config.json` 의 `sources` 에 `dm`·`broadcast` 키가 아예 없고 `sourceOn()` 이 명시적 `false` 가 아니면 켠 것으로 읽으며, 끄면 번역과 대시보드 목록까지 같이 사라진다. `team` 을 뺀 것은 수집 실적이 0건이라 동작이 갈리지 않기 때문이고, 1:1 DM 을 뺀 것은 "나한테 멘션한 것만" 을 글자 그대로 읽었기 때문이다 — 되돌리는 값이 JSON 낱말 하나다.
  Verify: 2026-09-02 — `Sources/Plugins/Slack/Daemon/ack-sources.test.mjs` 15 pass / 0 fail. 변경 전 데몬 사본으로 같은 시험을 돌리면 15개 중 **9개가 깨진다**(dm·broadcast·team 이 통과해 버리는 셋 포함) — 초록의 원인이 시험이 아니라 코드임을 확인한 것이다. 기존 시험 6개(`emoji-layer.decision` 18 pass, `send-layer` 15 pass, `send-layer.gate`, `people-context` 16 pass, `reply-language` 24 pass, `security-gate` 18 pass) 전부 exit 0, 회귀 0. `items.jsonl` 1792줄 전수 파싱 실패 0. 라이브 확인: 번들 `slack-eyes-daemon.mjs`·`slack-ack-cost-policy.json` 이 저장소와 `cmp` 동일, 데몬 재기동 후 `health.json` 이 `socket:connected · codeStale:false · failures:0`, 그리고 배포된 번들 파일에서 `acknowledgementOn` 을 직접 뽑아 실행하니 `mention` 만 true 이고 `team`·`dm`·`broadcast`·`later`·undefined 는 전부 false.
  NOTE: `swift build` 는 이 항목과 무관하게 `.build/build.db: disk I/O error` 로 exit 1 이다. `Package.swift:55` 가 `exclude: ["Daemon", "loops"]` 라 이 변경은 Swift 타깃의 입력이 아니며, Swift 소스는 한 줄도 안 바뀌었다(설치된 바이너리보다 새로운 소스는 이 배치의 3개 파일뿐). 그래서 배포는 `Scripts/build-app.sh` 의 설치 꼬리(quit → Resources 교체 → 애드혹 재서명 → relaunch → 데몬 kickstart)만 손으로 밟았다. 빌드 DB 결함은 별도 건이다.

- **SLKST-11 — only emojis that carry an approval meaning get folded into ✅.**
  EN: When a heavy catalog row (`level0 !== true`) matches in `responseGrade()`, the layer emits the matched row itself ONLY IF that row declares `approval: false`; in every other case it folds to `white_check_mark`. The test is `heavy.approval !== false`. **Flipping it to `=== true` is a regression** — a catalog that predates the `approval` key, and any newly added row that forgets to declare it, would then all go out as themselves, and the failure in that direction is an approval posted from the user's own xoxp account. When we do not know, folding is the safe side. 👌 `ok_hand` (approval) and 👍 `+1` (agreement) MUST be `approval: true`: auto-posting those is worse than the 2026-09-02 incident, because the reaction goes out under the user's token and the reader takes it as the user's own approval. 🙏 `pray` (well-wishing), 🙇 `man-bowing` (deference) and 🙌 `raised_hands` (celebration) carry no approval meaning and MUST therefore be declared `approval: false` — that declaration stays true whether or not the row is allowed to fire, and rewriting it to `true` in order to suppress a row is a regression (it records a false meaning to achieve an eligibility outcome; lower `auto` instead). Whether such a row actually goes out is the separate `auto` gate below, and **as of 2026-09-02 none of the three clears it**, so the unfold path ships live but unoccupied. Deciding this by emoji NAME inside `emoji-layer.mjs` is a regression — `approval` is read from JSON, for the same reason SLKST-7 requires the emoji name to be read from JSON. Admission to the catalog as `auto: true` is a separate and stricter gate: a rule qualifies only at measured precision ≥ 0.70 over the user's own three-month reaction corpus with a sample of ≥ 8 matches. `approval` says which way a row folds; it does not say the row earned the right to fire.
  KO: `responseGrade()` 에서 무거운 어휘집 행(`level0 !== true`)이 일치하면, 그 행이 **`approval: false` 라고 명시했을 때만** 일치한 행 자신을 내보내고 그 밖에는 전부 `white_check_mark` 로 접어 내보낸다. 판정은 `heavy.approval !== false` 다. **`=== true` 로 뒤집으면 회귀다** — `approval` 키가 없는 옛 어휘집과 키를 안 적고 새로 추가된 행이 전부 자기 자신으로 나가게 되고, 그 방향의 실패는 라이언 계정(xoxp)에서 나가는 승인이다. 모르면 접는 쪽이 안전한 쪽이다. 👌 `ok_hand`(승인)와 👍 `+1`(동의)는 반드시 `approval: true` 다 — 이 둘을 자동으로 다는 것은 2026-09-02 사고보다 나쁘다. 리액션이 라이언의 토큰으로 나가므로 상대는 그것을 라이언의 승인·동의로 읽는다. 반대로 🙏 `pray`(기원) · 🙇 `man-bowing`(겸손) · 🙌 `raised_hands`(환호)는 승인 뜻이 없으므로 반드시 `approval: false` 다 — 이 선언은 그 행이 나갈 자격이 있든 없든 참이고, 어떤 행을 막으려고 이 값을 `true` 로 고쳐 쓰면 회귀다(자격 문제를 뜻을 거짓으로 적어서 푸는 것이다. 막으려면 `auto` 를 내려라). 그 행이 실제로 나가는지는 아래의 별도 문(`auto`)이 정하며, **2026-09-02 기준 이 셋 중 그 문을 통과한 것은 하나도 없다** — 접힘 해제 경로는 살아 있는 채로 주인이 없이 배포된다. 판정을 `emoji-layer.mjs` 에 이모지 **이름**으로 박으면 회귀다. `approval` 은 JSON 에서 읽는다(SLKST-7 이 이모지 이름을 JSON 에서 읽으라고 한 것과 같은 이유). 어휘집에 `auto: true` 로 들어갈 자격은 이것과 **다른, 더 엄격한** 문이다 — 라이언 본인의 3개월 리액션 코퍼스에 대고 잰 정밀도가 **0.70 이상이고 표본이 8건 이상**일 때만 자격이 선다. `approval` 은 어느 쪽으로 접히는지를 말할 뿐이고 그 행이 나갈 자격을 얻었다고 말하지 않는다.
  Why / 근거: 2026-09-02. `emoji-layer.mjs:362` 가 `matchHeavy` 로 🙇·🙏·👌·👍 를 정확히 골라낸 다음 매치된 행이 아니라 `back`(= ✅)을 돌려주고 있었다. 즉 어휘집에 뜻을 적어 둔 이모지 넷이 **구조적으로 한 번도 슬랙에 나갈 수 없었다.** 라이언이 이름을 댄 세 이모지(🫡·✅·🙏) 중 🙏 가 여기 걸려 있었다. 가드 자체는 의도였고 시험이 지키고 있었으므로(`emoji-layer.decision.test.mjs:104-109`) 없애지 않고 축을 다시 그었다 — 위험한 것은 무거움이 아니라 승인 뜻이다. 반대 부호를 먼저 짜 봤을 때 옛 어휘집에서 👌·👍 가 자기 자신으로 나갔다: 하위 호환이 안전한 쪽이 아니라 위험한 쪽으로 떨어졌다. 실측 두 개가 함께 붙는다. (1) 3개월 코퍼스 3,456건 중 clean 3,174건에서 `bow` 는 **0건**이고 실제 이름은 `man-bowing` **43건**이라 그 행의 `name` 을 교정했다 — 이름이 틀리면 `reactions.add` 가 `invalid_name` 으로 실패한다. (2) 🙌 `raised_hands` 는 어휘집이 "잘 안 쓴다" 라고 적어 두었는데 clean **123건**으로 👍 `+1`(121건)보다 많다. 뜻은 교정했으나 이 이모지를 겨냥한 규칙 후보의 실측 정밀도가 0.06 이라 위 채택선에 못 미쳐 `auto: false` 로 남긴다 — 뜻을 아는 것과 자리를 찾을 수 있는 것은 다른 문제이고, 후자가 안 되면 어휘집에 넣지 않고 "못 잡는다" 로 적는다(G4). 아직 손대지 않은 단서 하나를 숫자와 함께 남긴다(다음 사람이 다시 재지 않도록): `responseGrade` 는 `matchHeavy` 를 `matchLevelZero` 보다 **먼저** 돌린다. 그래서 '죄송합니다 … 하겠습니다' 처럼 무거운 어휘와 L0 어휘가 한 문장에 같이 있으면 무거운 쪽이 이긴다. 접힘을 열었던 판 2 상태에서 이 16건을 재 보면 무거운 쪽이 이겨서 맞은 것은 **1/16**이고, 둘의 순서를 바꿔 L0 를 먼저 보게 하면 **5/16(0.31)** 이 된다. 그래도 채택선 0.70 에는 못 미치고, 순서를 바꾸는 것은 특정 행이 아니라 **모든 메시지**의 판정을 바꾸는 규칙 변경이라 이 배치에 넣지 않았다. 손대려면 전수 재판정을 먼저 하고 별건으로 연다.
  Verify: 2026-09-02 (판 3, 최종) — `Sources/Plugins/Slack/Daemon/emoji-layer.decision.test.mjs` **31 pass / 0 fail** (`node --test`). **축은 배포되되 그 자리에 주인이 없다.** `pray` 와 `man-bowing` 을 채택선 미달로 `auto: false` 로 내렸으므로, 어휘집에 `approval: false` 이면서 `auto: true` 인 행은 하나도 없다 — 접힘 해제 경로는 살아 있고 오늘 그것을 쓰는 행이 없을 뿐이다(시험 28이 이 사실 자체를 고정한다). 두 행의 실측: `pray` 정밀도 **0.00**(표본 2) · `man-bowing` **0.07**(표본 14), 채택선은 **0.70 · 표본 8**. 둘 다 못 미치므로 나중에 누가 이 중 하나를 `auto: true` 로 되돌리려면 **채택선을 먼저 넘겨야 한다**. `approval: false` 는 지우지 않고 남겼다 — 접히는 방향과 나갈 자격은 다른 축이다. 세 변형 실측(`.localdata/emoji-corpus/23-variant-abc.mjs`, clean 3,174건, 채점은 '레이어가 고른 이모지가 라이언이 그 자리에 실제로 단 것 안에 있는가'): **A 지금 상태(두 행 auto:true) 163(5.1%) · B 옛 동작(전부 ✅ 로 접음) 166(5.2%) · C 두 행 auto:false 166(5.2%)**. 🔍 건수는 A 2669 · B 2669 · C 2676. 세 변형이 갈리는 것은 **16건**이고 그중 맞은 것은 **A 1 · B 4 · C 4** 다. 즉 C 는 정확도에서 옛 동작과 같고 지금 상태보다 낫다. 16건의 착지를 쪼개면 C 는 7건을 🔍 로(B 는 그 7건에서 3건 맞음, C 는 0건), 4건을 🫡 로(B 0 · C 3), 5건을 ✅ 로(B 1 · C 1) 보낸다 — 합이 4 대 4 다. **정확도가 같은 채로 B 가 내던 틀린 ✅ 12건 중 4건이 정직한 🔍 로 바뀌고, 🫡 로 옳게 가는 3건을 새로 얻는다.** (PO 요약의 '틀린 ✅ 7건을 🔍 7건으로 바꾼다' 는 결론은 같으나 숫자가 다르다. 🔍 로 가는 7건 중 B 가 실제로 틀렸던 것은 4건이고 나머지 3건은 B 가 맞혔던 ✅ 를 포기한 것이며, 그 3건은 🫡 에서 되찾는다. 위 숫자가 실행 출력이다.) 2026-09-02 사고가 잘못된 ✅ 를 라이언의 승인으로 읽은 사건이므로 이 교환은 옳은 방향이다. 시험 구조도 바꿨다 — **축**(접힘/접힘 해제, `!== false` 부호, 하위 호환)은 시험 파일 안에서 만든 **합성 어휘집**에 대고 재고, **점유**(오늘 어느 행이 어느 칸에 있는가)만 번들 어휘집에 대고 잰다. 판 2 는 축을 번들에 대고 쟀기 때문에 어휘집의 점유가 바뀌자 축 시험 셋이 한꺼번에 깨졌다 — 축이 한 글자도 안 바뀌었는데 깨졌다면 그것은 축이 아니라 점유를 잰 것이다. 돌연변이 확인 둘: 부호를 `=== true` 로 뒤집으면 **2개 실패**(키 없는 칸과 하위 호환), 접힘 해제를 통째로 없애면(`fold = true`, 판 1 로 되돌림) **1개 실패**. 즉 번들에 주인이 없는데도 접힘 해제 경로가 실제로 시험되고 있다. 이웃 시험 전부 exit 0 — `ack-sources` 15 pass · `send-layer` 15 pass · `send-layer.gate` · `people-context` 16 pass · `reply-language` 24 pass · `security-gate` 18 pass · `.e2e/slackemoji.test.js` 모두 통과 · `.e2e/slackalignment.test.js` 통과. `.e2e/slackemoji.test.js` 는 어휘집 점유가 바뀌어 세 단언을 고쳤다 — 자동 이모지 개수 7 → **5**, auto:false 목록에 `pray`·`man-bowing` 추가, 그리고 접힘 해제 칸이 비어 있다는 단언을 새로 넣었다. 같은 파일의 `quickVerdict` 단언 하나가 기대값이 바뀌었다(`'잘 부탁드립니다. 감사합니다.'` → null 에서 `white_check_mark` 로): 그 함수의 '좁은 뜻 먼저' 가드가 `autoEmojis()` 를 돌아서 자격과 뜻을 하나로 읽기 때문이다. **`quickVerdict` 는 어디서도 안 불린다** — 데몬은 `responseGrade`·`modelVerdict` 만 부르고(`slack-eyes-daemon.mjs:2482`·`:2672`) 유일한 호출부가 그 시험 파일이라, 슬랙에 나가는 동작은 한 글자도 안 바뀐다. 옛 동작(B)에서도 그 문장은 ✅ 였으므로(🙇 가 heavy 로 잡혀 접혔다) 나가는 것 기준으로 회귀가 아니다. 가드를 `match` 있는 비-level0 행 전부로 넓힐지는 별건이며 PO 판단 대기다. `items.jsonl` 1793줄 전수 파싱 실패 0. 키는 어느 파일·로그·오류 문자열에도 실리지 않았다(이 배치는 키체인을 열지 않는다). `.e2e` 의 `slackdefects`·`slackdegrade`·`slackpipe`·`slackanswer` 넷은 여전히 exit 1 이지만 원인이 이 변경과 무관하다 — 각각 `untranslatedSegments is not defined` · `security-gate.mjs` 미복사 ×2 · `peopleContextModule is not defined` 로 모듈 로드 단계에서 죽어 어휘집에 닿지도 못한다(SLKST-7 Verify 에 기록된 그대로).

- **SLKST-12 — 🫡 is an outbound authorship marker, not an inbound reaction. It must never be auto-posted.**
  EN: `saluting_face` 🫡 means "this message was written by the user's agent, not by the user." It is a marker placed on OUTGOING text, not a reaction to incoming text, and the rule for it lives in the shared layer `~/.must-aios/sources/docs/slack-layers/layer-2-attribution.md`, which states: "이 값을 본문에서 추론하지 않는다 — 발신하는 쪽은 자기가 그 글을 썼는지 아닌지를 이미 안다." The catalog and `router.md` are the places that infer from message body, so neither may own this emoji. Concretely: the `saluting_face` row must stay `auto: false` and `level0: false`, and it must carry NO `match` regex — leaving the regex in place means flipping `auto` back on silently resurrects the retired meaning. `levelZeroEmojis()` therefore yields ✅ and 🔍 only, and `parsePick()` must reject `saluting_face` even when the model picks it. **Re-enabling this row on precision grounds is a regression.** Its reason for leaving differs from 🙏 `pray` and 🙇 `man-bowing`, which left because they missed the adoption bar (SLKST-11); 🫡 left because the axis changed, so no precision measurement can ever qualify it. Putting two meanings on one emoji recreates the 2026-09-02 failure in which a colleague had to explain in-channel that the green check was the user's AI agent and not the user's approval.
  KO: `saluting_face` 🫡 의 뜻은 "이 글은 라이언이 아니라 라이언의 에이전트가 대신 썼다" 이다. 들어온 글에 다는 리액션이 아니라 **나간 글**에 다는 발신자 표시이고, 규칙 본문은 공용 레이어 `~/.must-aios/sources/docs/slack-layers/layer-2-attribution.md` 에 있으며 그 문서가 "이 값을 본문에서 추론하지 않는다 — 발신하는 쪽은 자기가 그 글을 썼는지 아닌지를 이미 안다" 를 못박았다. 어휘집과 `router.md` 는 본문에서 추론하는 자리이므로 이 이모지를 소유할 수 없다. 구체적으로 `saluting_face` 행은 `auto: false` · `level0: false` 이고 **`match` 정규식을 갖지 않아야 한다** — 남겨 두면 `auto` 를 다시 켜는 순간 폐기된 뜻으로 조용히 발화한다. 그래서 `levelZeroEmojis()` 는 ✅ 와 🔍 둘만 내고, `parsePick()` 은 모델이 🫡 를 골라도 받지 않는다. **정밀도를 근거로 이 행을 되살리면 회귀다.** 이 행이 축을 떠난 사유는 🙏·🙇 와 다르다 — 저 둘은 채택선 미달이라 내려갔고(SLKST-11) 🫡 는 축 자체가 달라져서 떠났으므로, 어떤 정밀도 측정으로도 자격이 서지 않는다.
  Why / 근거: 2026-09-02 라이언 확정. 이 배치의 3개월 실측(clean 3,174건)에서 ✅ 와 🫡 는 16개 축 어디에서도 갈리지 않았고 최대 격차가 15pp 였으며, 글자까지 같은 원문(`"Thank you"` · `"넵"` · `"FYI"` · `"To @Lion noted."`)에 둘 다 나갔다. 그 이유가 여기서 설명된다 — **🫡 는 본문의 함수가 아니라 "누가 썼는가" 의 함수였다.** 본문 축으로 아무리 갈라도 안 갈리는 것이 당연했다. 근거 문서는 `docs/2026-09-02-lion-emoji-corpus-brief.md` §3 · §4-1 · §4-2.
  Verify: 2026-09-02 — `emoji-layer.decision.test.mjs` **39 pass / 0 fail**, `.e2e/slackemoji.test.js` **모두 통과**(exit 0). 실측된 이동(`.localdata/emoji-corpus/40-salute-off-effect.mjs`, clean 3,174건): 🫡 를 끄면 **122건이 옮겨간다 — 🔍 97 · ✅ 25**. 라이언의 과거 사용과 대조한 적중은 그 122건에서 **67 → 8** 로 내려간다. **이것을 손실로 읽지 않는다** — 그 67건은 *폐기된 뜻 기준으로* 맞았던 것이고, 뜻이 바뀐 뒤에는 들어온 글에 🫡 를 다는 것 자체가 틀린 동작이다. 지표가 낡은 것이지 동작이 나빠진 것이 아니며, 이 항목을 정밀도로 판정하면 안 되는 이유가 바로 이 숫자다. `.e2e/slackemoji.test.js` 에서 옛 뜻을 굳히고 있던 단언 여덟을 고쳤다 — 자동 이모지 개수 5 → **4**, L0 목록 `saluting_face,white_check_mark,mag` → `white_check_mark,mag`, `catalogText` 에서 🫡 제외, 사고 문장 `"Understood… I'll proceed…"` 의 착지 🫡 → ✅(이 회귀 시험이 지키는 것은 어느 이모지냐가 아니라 "답변 불가 3줄이 안 나간다" 이고 그것은 그대로다), `'진행하겠습니다.'`·`'Will do.'` → null, `"Thanks! I'll handle it."` → ✅, `parsePick(':saluting_face:')` → null. 그리고 🫡 가 `autoEmojis()` 에 없다는 것과 `match` 를 갖지 않는다는 것을 단언 둘로 새로 고정했다. `.e2e` 의 `slackdefects`·`slackdegrade`·`slackpipe` 셋은 여전히 exit 1 이지만 원인이 이 변경과 무관하다(SLKST-7 Verify 에 기록된 모듈 로드 실패 그대로). 빌드·설치·재시작하지 않았고 커밋하지 않았다 — 앱 번들은 아직 옛 어휘집으로 돈다.

### Intent audit — P9
EN: New page registration, so there is no prior spec intent to compare against. One stated expectation was found FALSE against the corpus and is recorded here so it is not re-asserted: the three-state split (`AI 처리` / `결정 대기` / `전체`) was expected to cut the queue by 60%+; measured, it cuts it by **10.6%** (227 → 203), because classification only relocates work that was already done and only 24 of the 227 had been touched by the AI. The 60% target is reachable only by also closing the 193-item pre-pipeline backlog (227 → 10, 95.6%). The lever was the backlog, not the classification.
KO: 신규 등재라 비교할 이전 SPEC 의도가 없다. 다만 코퍼스와 대조해 **거짓**으로 확인된 기대치 하나를 여기 남겨 다시 주장되지 않게 한다. 3상태 분할(`AI 처리` / `결정 대기` / `전체`)이 대기열을 60% 이상 줄일 것으로 기대됐으나, 실측하면 **10.6%** 만 줄인다(227 → 203). 분류는 이미 처리된 것을 옮길 뿐이고 227건 중 AI 손을 탄 것은 24건뿐이기 때문이다. 60%는 파이프라인 도입 전 백로그 193건을 함께 마감해야 도달한다(227 → 10, 95.6%). 지렛대는 분류가 아니라 백로그였다.

---

### Notion Keychain registration

- **INTG-13 — Notion secrets never enter the dashboard.**
  EN: The Notion token flow has no password input. The dashboard requests metadata-only Keychain candidates whose service or account contains `notion` case-insensitively, displays only service/account, and stores only that reference. Selecting a candidate reads the exact service+account locally and immediately verifies it against Notion. The token must never enter DOM, HTTP, logs, argv, environment, `integrations.json`, or registration result files.
  KO: Notion 토큰 흐름에는 password input이 없다. 대시보드는 service 또는 account에 `notion`이 대소문자 무시로 들어간 Keychain 메타데이터 후보만 요청하고 service/account만 표시하며, 선택한 참조만 저장한다. 후보 선택 시 로컬에서 정확한 service+account 항목을 읽어 Notion에 즉시 실제 검증한다. 토큰은 DOM·HTTP·로그·argv·환경변수·`integrations.json`·등록 결과 파일에 들어가면 안 된다.

- **INTG-14 — Terminal registration is the no-candidate fallback.**
  EN: Only when metadata discovery returns no candidates (or cannot enumerate them), the UI offers Terminal registration. The helper requires a TTY, disables echo with guaranteed restoration, accepts the token only from stdin, rejects command-parser characters, writes to Keychain through `security -i`, and emits a secret-free result. Cancellation, access denial, invalid token, network failure, and authentication failure remain distinguishable without exposing Notion response secrets.
  KO: 메타데이터 탐색에 후보가 없거나 열거할 수 없을 때만 UI가 Terminal 등록을 제공한다. helper는 TTY를 요구하고 echo를 반드시 복원하며, 토큰은 stdin으로만 받고 명령 파서 문자를 거부한 뒤 `security -i`로 Keychain에 저장하며 비밀 없는 결과만 남긴다. 취소·접근 거절·잘못된 토큰·네트워크 실패·인증 실패는 Notion 응답의 비밀을 노출하지 않은 채 구분한다.

- **INTG-15 — external references are exact and backward-compatible.**
  EN: A Notion instance may carry `keychainService` and `keychainAccount`; API checks, MCP launch, and the Slack daemon must all use that exact pair. Rows without those fields keep the derived `cm-notion-token-<key>` behavior, and the legacy `cm-notion-token` item is surfaced as a non-destructive reference. Disconnecting an external reference removes only the reference, never the original Keychain item. A failed validation remains visible as validation failure; it must not be shown as connected.
  KO: Notion 인스턴스는 `keychainService`와 `keychainAccount`를 가질 수 있고 API 검사·MCP 실행·Slack 데몬이 모두 그 정확한 쌍을 사용해야 한다. 필드가 없는 기존 행은 `cm-notion-token-<key>` 파생 규칙을 유지하고 legacy `cm-notion-token` 항목은 파괴 없이 참조로 표시한다. 외부 참조 연결 해제는 참조만 없애며 원본 Keychain 항목을 삭제하지 않는다. 검증 실패는 검증 실패로 남고 연결됨으로 표시하면 안 된다.

---

## OPEN QUESTIONS
EN: None new discovered this pass that are testable-behavior-ambiguous. One documentation-only item
is already resolved by this rewrite (P2/P5 "third source" retirement) since it was a static code
fact (iframe genuinely absent), not a judgment call. If a NEW ambiguous behavior surfaces in a
future pass, it will be listed here — do not guess in the meantime.
KO: 이번 회차에서 테스트 가능한 행동 관점에서 모호한 새 질문은 발견되지 않았다. 문서 전용 항목 하나는
이번 재작성으로 이미 해결됐다(P2/P5 "제3의 소리 출처" 폐기) — 판단이 필요한 문제가 아니라 정적
코드 사실(iframe이 실제로 부재함)이었기 때문이다. 향후 새로운 모호한 동작이 발견되면 여기에
나열한다 — 그동안은 추측하지 않는다.

- **RESOLVED (2026-07-06 third pass): "off-view audio can't load" (BGMACT-1) — option (a) applied
  and verified.**
  EN: The three-way question below was answered by the implementer choosing option (a) — always
  keep the BGM webview attached to the container (layered under the opaque dashboard webview when
  `.dashboard` is shown) — and this QA pass confirmed it works with no regressions (no double
  audio, no gap on mode switch, native-mute latch still correctly asserted at every transition).
  Kept here as historical context; no longer an open question.
  KO: 아래 세 갈래 질문은 구현자가 (a)를 선택해 답했다 — BGM webview를 컨테이너에 항상 붙여두고
  (`.dashboard`가 보일 때는 불투명한 대시보드 webview 아래 레이어로 깔림) — 이번 QA에서 회귀 없이
  동작함을 확인했다(이중 오디오 없음, 모드 전환 시 끊김 없음, 모든 전환에서 네이티브 뮤트 래치
  정상 유지). 더 이상 열린 질문이 아니며 과거 기록으로 남겨둔다.
  Original question (EN): Three ways to close the gap, each with real UX tradeoffs — not guessing
  which one, asking: (a) always keep the BGM webview attached to SOME view (even a 1x1/covered
  host) so its `<audio>` can load regardless of visible mode — closest to "current design intent"
  but unverified for side effects (Web Audio graph timing, memory/GPU cost of two always-attached
  webviews); (b) revert the launch default from `.dashboard` back to `.bgm` — trivially fixes
  zero-click autoplay but reverses the intentional 2026-07-06 nav change (dashboard-first landing)
  that this same commit introduced; (c) accept that a challenge auto-starting does NOT play music
  until the user opens the `.bgm` mode at least once per launch, and drop "zero-click" from
  BGMACT-1's contract. Which is the intended fix?
  원래 질문 (KO): 이 간극(화면 밖에서는 오디오가 로드되지 않음, BGMACT-1, 2026-07-06 2차 확인)을
  메우는 방법은 세 갈래이고 각각 실제 UX 트레이드오프가 있다 — 어느 쪽인지 추측하지 않고 묻는다:
  (a) BGM webview를 어떤 뷰든(1x1이나 가려진 호스트라도) 항상 붙여둬서 보이는 모드와 무관하게
  `<audio>`가 로드되게 한다 — "현재 설계 의도"에 가장 가깝지만 부작용(Web Audio 그래프 타이밍,
  항상 붙어있는 webview 2개의 메모리/GPU 비용)은 검증되지 않았다; (b) 런치 기본값을 `.dashboard`에서
  `.bgm`으로 되돌린다 — 제로클릭 자동재생은 간단히 고쳐지지만 같은 커밋에서 도입한 의도된 2026-07-06
  내비게이션 변경(대시보드 우선 랜딩)을 되돌리는 셈이다; (c) 챌린지가 자동시작되어도 사용자가 한 번은
  `.bgm` 모드를 열어야 음악이 재생된다는 것을 받아들이고, BGMACT-1의 "제로클릭" 계약을 낮춘다. 어느
  쪽이 의도된 수정 방향인가?

- **DOC-ONLY (2026-07-06, goal-link-and-generic-queue Phase 4):** the source spec
  (`docs/specs/goal-link-and-generic-queue.md`) repeatedly cites "DASH-2 invariant holds —
  `runQaAudit` finds no id-collision" as the verification method for the 큐 tab's view-isolation. The
  app's actual `runQaAudit()` (`DashboardContent.swift:4295`) checks text-overflow/2-line-wrap on
  `.btn`/`.chip`/table cells — it has NO id-collision detection logic at all, and DASH-2 itself (the
  existing SPEC item) is about `fillActiveView` blanking other view hosts, not an automated audit
  function. This is a documentation-only mismatch (the underlying behavior — one view populated at a
  time, verified by direct DOM inspection this pass — is correct and PASSES); flagging so a future
  spec pass does not rely on `runQaAudit` output as evidence for id-collision-freedom, since it
  cannot detect that class of bug. Not asking the user to decide anything — this is a factual
  correction, not an ambiguous behavior.
  KO: 원본 스펙(`docs/specs/goal-link-and-generic-queue.md`)이 큐 탭의 뷰-격리 검증 방법으로 "DASH-2
  불변식 유지 — `runQaAudit`이 id 충돌 없음을 확인"을 반복해서 인용한다. 실제 앱의
  `runQaAudit()`(`DashboardContent.swift:4295`)은 `.btn`/`.chip`/테이블 셀의 텍스트 오버플로우/2줄
  줄바꿈만 검사하며 id 충돌 감지 로직은 전혀 없다 — DASH-2 자체(기존 SPEC 항목)도 자동 감사 함수가
  아니라 `fillActiveView`가 다른 뷰 호스트를 비우는 것에 관한 항목이다. 이는 문서 전용 불일치다(실제
  동작 — 한 번에 하나의 뷰만 채워짐 — 은 이번에 DOM을 직접 검사해 확인했고 PASS함); 향후 스펙
  패스가 `runQaAudit` 출력을 id-충돌-없음의 근거로 삼지 않도록 표시해 둔다(그 종류의 버그는 애초에
  감지할 수 없는 함수이므로). 사용자에게 판단을 요청하는 것이 아니라 사실 정정이다.

- **DASH-11 — 이슈 검색은 시각 조건을 직접 재고, 카드가 던져진 뒤의 발화까지 읽는다.**
  KO: 이슈 대시보드(`/issues`)의 검색은 두 가지를 보장한다.
  (a) **시각 조건은 모델에게 맡기지 않는다.** 질의에 `N시간 전`·`N분 전`·`N일 전`·`어제`·`오늘`·
  `아까` 같은 표현이 있으면 앱이 직접 창을 계산해 그 창에 드는 카드를 결과 **앞으로** 올린다.
  창 안 순서는 최신순이 아니라 (질의 낱말 겹침, 창 중심과의 거리) 순이고, 이미 결과에 있던
  카드도 앞으로 올린다. 이 보장은 **AI 가 죽어 있을 때도** 성립한다 — 글자 맞추기 갈래에도
  같은 창이 씌워진다. 모델에게는 카드의 시각을 `YYYY-MM-DD HH:MM` 으로 주고 프롬프트에
  `지금 시각` 을 같이 싣는다.
  (b) **카드가 던져진 뒤 목적지 창에서 라이언이 더 말한 것이 검색 코퍼스에 들어간다.**
  트랙 카드는 최상위 창의 첫 발화 한 번의 스냅샷이라 그 뒤에 자란 요구가 카드 파일에 없다.
  앱은 카드의 `target` 으로 그 세션 트랜스크립트를 찾아(첫 사람 턴에 카드 `id` 가 있는 파일)
  이후의 사람 턴만 읽어 발췌에 잇는다. 카드 본문과 **따로** 줄인다 — 이어 붙인 뒤 한 번 줄이면
  본문이 긴 카드에서 나중 발화가 통째로 잘려 나간다. 큐 폴더에는 한 바이트도 쓰지 않는다.
  EN: `/issues` search resolves relative-time expressions itself instead of delegating them to the
  model. Cards falling inside the computed window are promoted to the FRONT of the result list —
  ranked by query-token overlap then by distance from the window centre, not by recency — and
  already-present hits are promoted rather than skipped. The same window is applied on the
  literal-match fallback, so the guarantee survives an AI outage. The prompt now carries the current
  time and per-card timestamps at minute resolution. Separately, the corpus includes what Ryan said
  in the DESTINATION window AFTER the card was thrown: the app locates that session transcript via
  the card's `target` (the file whose first human turn contains the card `id`) and appends the later
  human turns to the excerpt, truncated on its OWN budget so a long card body cannot crowd it out.
  The queue folder is never written to.
  Mechanism: `Core/IssueSearch.swift` (`timeWindow`, `withTimeWindow`, `readableStamp`,
  `thinOriginLimit`, `laterLimit`) and `Core/CardLaterRequests.swift` (transcript lookup + cache).
  Why: 2026-09-06. 라이언이 `링크드인 컨텐츠를 4시간 전에 작성한 게 있거든 찾아줄래요?` 로 찾았는데
  9 건 중에 그 카드가 없었다. 원인은 둘이었다 — 모델에게 간 날짜가 `20260905` 라 시:분이 없었고
  프롬프트에 `지금` 이 없어 `4시간 전` 이 원리적으로 계산 불가였다. 그리고 그가 "내가 원했던 내용과
  다르다" 고 한 것은 구술이 잘려서가 아니라, 그 상세 요구를 카드가 만들어진 2 시간 34 분 뒤에
  목적지 창에서 말했고 그것이 카드로 돌아오는 경로가 없었기 때문이다.
  Verified: 격리 인스턴스에서 두 갈래 다 확인 — 시각 창은 `local`·`ai` 양쪽에서 대상 카드를 1 위로
  올렸고, 나중 발화는 카드 파일에 없는 낱말(`시트`·`600`·`200`)로 `2026-09-06-0006-blockchain-team-
  cost-final-report` 를 잡아 냈다(그 카드 파일에 그 낱말은 0 회).

- **DASH-12 — 카드에 안 적혀도 그 일을 한 세션에서 지시서와 결과물을 끌어와 보인다.**
  KO: 이슈 상세(`/issues` 우측 패널)의 `작업지시서` 칸과 `결과물` 칸은, 카드에 `issue:` 나
  산출물 키가 없더라도 그 카드를 받은 세션에서 나온 것을 그 자리에 세운다. 세우는 것은 넷이다 —
  (1) 그 세션의 **첫 지시문 전문**(최초 원문·문제 정의·어떻게 일할 건지가 그 안에 있다),
  (2) 그 세션이 `issue/` 아래에 쓴 파일, (3) 그 세션이 쓴 나머지 파일 전부(디스크 존재 확인),
  (4) 그 세션의 **마지막 보고**. 세션에서 온 것은 왼쪽 파란 줄(`.ses`)로 카드에 적힌 것과 눈에서
  갈리고, 헤더에 `세션에서 옴` 배지가 선다. 못 찾으면 빈칸이 아니라 **왜 못 찾았는지**를 쓴다.
  단계 배지(`요청만`/`작업지시서까지`/`결과물까지`)는 **카드 기준 그대로 두고 올리지 않는다** —
  목록 109 장을 그 값으로 세므로 카드마다 트랜스크립트를 훑을 수 없다. 배지가 `요청만` 인데 아래에
  지시서가 서 있는 상태는 화면의 버그가 아니라 진짜 상태이고, 그것을 카드에 적는 것은 큐 PM 의 일이다.
  **카드 파일과 큐 폴더에는 한 바이트도 쓰지 않는다.** 내용을 담을 별도 파일도 만들지 않는다.
  EN: The `작업지시서` and `결과물` panes of the issue detail fall back to the session that actually
  did the work when the card records no pointer: its first launch prompt, the files it wrote under
  `issue/`, every other file it wrote (existence-checked), and its last report. Session-derived rows
  are visually separated and the header carries a `세션에서 옴` badge. A miss states its reason
  instead of rendering blank. The stage badge stays card-derived. The queue folder stays read-only.
  Mechanism: `Core/WorkQueueSessionStore.swift` (세션 판정 · 지시문 색인 · 캐시 · reveal 허용 목록),
  `Core/WorkQueueStore.swift` (`detailJSON` 의 `session` 블록, `knownRevealPaths` 합집합,
  `json()` 의 색인 예열), `Dashboard/IssuesContent.swift` (`sesHead` · `longBox` · 4·5 번 절).
  세션 줄에서 기록·폴더로 가는 길은 DASH-13 이다.
  세션 판정 규칙은 DASH-11 의 `Core/CardLaterRequests.swift` 와 같다 — **첫 사람 턴에 카드 id 가
  들어 있는 트랜스크립트**. 두 파일이 같은 규칙을 따로 들고 있으므로 한쪽을 고치면 다른 쪽도 본다.
  Why: 2026-09-06. 라이언이 카드 `2026-09-05-2024-linkedin-version-scope` 상세를 보고
  "따로 파일을 만들 필요는 없고 그걸 갖고 와서 여기에 보여주는 걸로 하자" 고 했다. 그 카드는
  `issue:` 도 산출물 키도 비어 화면이 `작업지시서 없음` / `결과물 없음` 이라고 쓰고 있었는데,
  그 카드를 받은 세션(`7b59cb18-…`)이 `issue/2026-09-05-linkedin-version-scope-directive.md` 와
  `channels/linkedin/20260905-directive-is-deliverable.md` 를 실제로 썼고 둘 다 디스크에 있었다.
  화면이 거짓말을 한 것이 아니라 카드와 세션 사이에 끈이 없었다.
  Verified: 격리 인스턴스(`CM_DATA_DIR`)에서 카드 106 장을 전수로 열어 확인 — 세션이 붙은 것 59 장
  (그전 19 장), 그중 파일까지 붙은 것 28 장, 실패 0. 그 카드의 두 칸이 `없음` 대신 지시서 1 개와
  산출물 1 개와 지시문 전문과 마지막 보고를 보였다. `.e2e/issues.test.js` 131 PASS 0 FAIL.
  `/api/issues/reveal` 은 세션에서 파낸 경로만 열고 `/etc/hosts` 는 `unknown-path` 로 거절했다.
  성능: 지시문 색인 최초 1 회 10 초(목록이 뜰 때 뒤에서 미리 만든다) · 그 뒤 카드당 0.35 초 ·
  두 번째부터 0.03 초. 앞선 판은 카드마다 `grep -rl` 로 2.0GB 를 훑어 카드당 16 초였다.

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
  Verified: 격리 인스턴스(`CM_DATA_DIR=/tmp/cm-dash13`, 포트 50982)에서 실측.
  카드 `inbox/2026-09-06-1255-panama-ceo-nda-m-mata` 상세가 `session.file`
  (`…/-Users-…-globalmpc-legal/97cc3cc2-…jsonl`)과 `session.cwd`
  (`/Users/lioncho/Work/lion_work/organization/globalmpc/workspace/globalmpc-legal`)를 같이 실어 왔다.
  `GET /api/issues/transcript` 로 그 기록(796KB · 124 줄)에서 턴 3 개(사람 1 · 모델 2)가
  10,733 바이트로 왔다 — 원본의 1.3% 다. 카드 60 장을 훑어 세션이 붙은 것 전부에 같은 호출을
  돌렸고, 가장 큰 기록(1.1MB · 380 줄)이 턴 14 개(사람 3 · 모델 11)로 왔으며 턴 하나의 최대
  길이는 3,289 자였다. `inbox/2026-09-05-2201-blockchain-talent-csv-html` 의 턴 두 개가
  `Write` 로 쓴 파일 경로를 실어 왔다(`blockchain-cost.html`, `open-report.sh`).
  **실측 범위에서 400 턴·4,000 자·2MB 상한에 걸린 세션은 없었다** — `truncated` 는 전부 `false`
  였고, 상한이 실제로 자르는 것은 아직 못 봤다. 거절 실측 — `/etc/hosts` ·
  `~/.ssh/id_rsa` · `/Users/lioncho/.claude/projects/../../.zsh_history` 셋 다
  `{"ok":false,"error":"unknown-path"}` 이고, `/api/issues/reveal` 도 셋 다 같은 값으로 거절했다.
  경계가 허용 목록까지라는 것도 실측했다 — 같은 기록 폴더 안에 실재하는 다른 세션
  (`79aef52a-…jsonl`, 상세를 연 적 없는 카드의 것)이 `unknown-path` 로 거절됐다. `~/.claude/projects/`
  아래로만 자르면 그것이 열렸을 것이다. 허용된 둘(`97cc3cc2-…jsonl` 파일과 `globalmpc-legal` 폴더)은
  `{"ok":true}` 였다. `swift build` 통과, `.e2e/issues.test.js` 197 PASS 0 FAIL.
  그 파일의 닫힌 POST 목록에 `mdsave` 가 빠져 있어 이번에 같이 채웠다 — DASH-12 때 더해진
  엔드포인트인데 목록이 안 따라가서 이 항목과 무관하게 1 FAIL 이 서 있었다.

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
  ASSUMPTION (L1, 백엔드가 갈래를 스스로 골랐다): 라이언의 문장이 "얼마나 … **써서**" 로 쓴
  **양**을 묻는데 `reasoning effort` 는 양이 아니라 설정값이라, 양에 해당하는 `tokens` 를 같이
  돌려주고 어느 필드에서 왔는지를 `tokensFrom` 에 적는다. **모르는 값은 0 이 아니라 키를 뺀다** —
  codex 실행에 `tokens used` 줄이 없으면 `tokens` 키 자체가 안 실리고, 화면이
  `typeof rv.tokens === 'number'` 로 그 조각을 켜므로 조각이 통째로 빠진다. 0 을 실으면 화면이
  `0 토큰` 이라고 그리는데 그것은 "안 썼다" 는 뜻이 되어 거짓말이다. `seconds` 도 같다. Claude 갈래의 시작 시각은 **바로 앞 사람 턴**이므로, 하위
  대화에서는 그 워커가 뜬 순간부터 카드를 쓴 순간까지가 된다(실측 700.9 초 · 2,776.9 초).
  Bash heredoc 이나 `mv` 로 만든 카드는 못 잡는다 — Write/Edit 툴 호출도 Codex 배너도 안
  남기기 때문이고, 셸 문자열을 파싱해 추측하는 것보다 못 잡은 것을 못 잡았다고 두는 쪽이
  이 화면의 규칙("없으면 왜 없는지를 쓴다")에 맞는다.
  Verified: 2026-09-06 백엔드 실측. `Core/WorkQueueSessionStore.swift` 를 그대로 컴파일해
  (`swiftc -O`) 카드 `d7a0211b-3ee8-4a5e-a172-400cb674b595`
  (`inbox/2026-09-06-0445-condition-mate-revision-details.md`, `captured: 2026-09-06-0445`)로
  호출한 결과가 —
  `runner: "codex"` · `model: "gpt-6-astra"` · `effort: "none"` · `tokens: 31521` ·
  `tokensFrom: "codex \`tokens used\`"` · `seconds: 58.9` ·
  `startedAt: "2026-09-05T23:14:54.708Z"` · `endedAt: "2026-09-05T23:15:53.646Z"` ·
  `sessionId: "01a073da-80fa-7ab2-b8d8-5e5529240495"` ·
  `file: "/Users/lioncho/.claude/projects/-Users-lioncho-Work-lion-work/11b66f83-03c0-4542-ac34-140b9f3cd2e4/subagents/agent-a76a3488df2463e20.jsonl"`.
  후보 좁히기 실측 — 기록 전체 3,301 개 중 `captured - 120초` 이후에 수정된 것이 147 개
  (153.9MB)이고 그중 카드 이름을 담은 것이 27 개였다. **첫 호출 0.68 초**(같은 프로세스
  재호출 0.000 초 · 페이지 캐시가 더워진 뒤 0.13 초). 앞선 판은 줄을 String 으로 쪼개고
  줄마다 `String.contains` 를 물어 2.66~4.36 초였다 — 지금은 줄 경계를 바이트로 뜨고 카드
  이름이 실제로 나온 줄만 JSON 으로 판다. codex 후보가 5 개 걸렸고 **가장 이른 것**을 골라
  카드를 처음 만든 실행이 잡혔다(나머지 넷은 그 카드를 나중에 읽은 실행이다). claude 후보
  3 개는 전부 `status`·`target_handle` 을 적은 나중 Edit 이라 codex 가 이겼다.
  다른 카드 8 장으로도 돌렸다 — claude 갈래 3 건이
  `claude-haiku-4-5-20251001` · `message.usage` 합계 118,716 / 148,108 토큰으로 잡혔고,
  codex 갈래 1 건(`inbox/2026-09-06-1255-panama-ceo-nda-m-mata`)은 `tokens used` 줄이 없어
  `tokens: 0` · `tokensFrom: ""` 로 나왔다. 못 찾는 카드 3 장은 `found:false` 와
  "기록 N 개(전체 3,301 개 중 …)를 봤는데 이 카드 파일을 만든 실행이 없다 … 카드 이름을 담은
  기록은 M 개였다" 라는 문장이 왔고, 그중
  `inbox/2026-09-06-0455-condition-mate-orca-launch-confirm-undo` 는 실제로 Bash `mv` 로
  옮겨진 카드여서 못 잡는 것이 맞다고 기록으로 확인했다.
  `swift build -c release` 통과, `.e2e/issues.test.js` **203 PASS 0 FAIL**.
  그 하네스가 이 파일을 `static func transcriptJSON(` 부터 **파일 끝까지** 잘라서 그 조각에
  `jsonl` 이라는 낱말이 없는지를 보므로(DASH-13 이 원본 JSONL 을 그대로 붓지 않는다는 판정),
  이 절은 `transcriptJSON` **앞**에 둔다. 처음에 뒤에 뒀더니 이 절의 `subagents/*.jsonl` 이
  그 조각에 들어가 그 판정이 1 FAIL 로 거짓이 됐다 — 하네스를 고치지 않고 자리를 옮겨서 풀었다.
  카드 파일과 `lion-work-queue/` 아래에는 한 바이트도 안 썼다.

- **DASH-15 — 워크스페이스 루트는 큐 폴더를 따라가지 않는다.**
  EN: The workspace root that `organization/...` artifact values and the Orca launcher resolve
  against is found by walking UP from the queue folder to the first ancestor that actually has an
  `organization/` directory on disk, and when no such ancestor exists it falls back to its OWN
  constant — never to the queue folder itself. `CM_LION_WORK_DIR` still beats everything. The
  queue path is a HINT for finding the root, not the root's source: picking an arbitrary folder in
  큐 폴더 변경 changes where cards are read from and nothing else.
  KO: 산출물 `organization/...` 값과 Orca 작업 폴더가 기준으로 삼는 워크스페이스 루트는, 큐
  폴더에서 **위로 올라가며** `organization/` 하위 디렉터리를 디스크에 실제로 가진 첫 조상이다.
  그런 조상이 없으면 **자기 상수**로 떨어지고 큐 폴더 자신이 되지 않는다. `CM_LION_WORK_DIR` 는
  여전히 전부를 이긴다. 큐 경로는 루트를 **찾는 힌트**이지 루트의 출처가 아니다 — 큐 폴더
  변경으로 아무 폴더나 골라도 바뀌는 것은 카드를 어디서 읽는가뿐이다.
  이 항목이 보장하는 넷과 각각의 `Verify:` —
  1. 큐 폴더가 어디든 루트는 `organization/` 트리를 가진 자리를 가리킨다.
     Verify: `Core/WorkQueueStore.swift:131-148` (`resolveLionWorkRootPath(forQueuePath:)` 의
     위로-걷기 · `:138` 의 `appendingPathComponent("organization")` + `fileExists(isDirectory:)`).
     실행 근거는 `tests/RelatedGoalSearchTests/LionWorkRootTests.swift:51`
     (`<root>/queue`) 과 `:61` (옛 `<root>/organization/lion/lion-work-queue`) 둘 다
     `/Users/lioncho/Work/lion_work` 를 돌려주는 것.
  2. 큐 폴더로 임의의 폴더를 골라도 워크스페이스 루트는 따라가지 않는다.
     Verify: `Core/WorkQueueStore.swift:56-57` (`defaultLionWorkRootPath` 상수) 와 `:147`
     (걸음이 끝나면 그 상수로 떨어지는 3 단계). 실행 근거는
     `tests/RelatedGoalSearchTests/LionWorkRootTests.swift:74` — `/tmp/<uuid>` 를 큐로 골라도
     루트가 `/Users/lioncho/Work/lion_work` 이고 큐 폴더 자신이 아니다.
  3. `CM_LION_WORK_DIR` 가 전부를 이긴다.
     Verify: `Core/WorkQueueStore.swift:99-104` (getter 의 **첫** 갈래). 실행 근거는
     `tests/RelatedGoalSearchTests/LionWorkRootTests.swift:89` — 임의 큐 폴더일 때도, 오늘의
     `<root>/queue` 일 때도 환경변수 값이 이긴다.
  4. 라이브 큐 e2e 블록이 **실제로 도는** 경로를 본다.
     Verify: `.e2e/issues.test.js:646-651` (`QDIR` 이 소스의 `defaultRootPath` 를 그대로 읽고,
     둘이 다르면 실패한다) 와 `:862` (블록이 건너뛰어지면 그 자체를 실패로 세운다).
  Mechanism: `Core/WorkQueueStore.swift` (`defaultLionWorkRootPath` · `lionWorkRoot` ·
  `memoizedLionWorkRootPath(forQueuePath:)` · `resolveLionWorkRootPath(forQueuePath:)`),
  `.e2e/issues.test.js` (`LWR` 블록의 DASH-15 단언 11 개 + 라이브 큐 블록),
  `tests/RelatedGoalSearchTests/LionWorkRootTests.swift` (8 개).
  성능: 2 단계가 파일시스템을 만지므로 **큐 경로를 키로 메모**한다(`:116-127`). `resolve()` 는
  카드마다 포인터마다 불린다(2026-09-07 실측 167 장). `static let` 한 번 계산은 안 된다 —
  사용자가 도는 중에 선택기로 큐 폴더를 바꾸면 굳은 값이 남은 세션 내내 틀린 채로 산다.
  Why: 2026-09-07. 큐가 `<lion_work>/organization/lion/lion-work-queue` 에서 `<lion_work>/queue`
  로 옮겨졌고 옛 경로는 디스크에 없다. 그런데 앞선 판은 루트를 큐 **경로 문자열**에서 되짚어
  만들었다 — `/organization/` 앞을 자르고, 그 조각이 없으면 큐 폴더 자신을 루트로 봤다. 새
  경로에는 그 조각이 없으므로 되짚기가 실패해 루트가 큐 폴더가 됐고, `organization/...` 상대
  산출물 값이 `.../lion_work/queue/organization/...` — 없는 경로 — 로 풀렸다. PO 실측(지시서)은
  카드 **166 장 중 67 장(40%)** 이 그런 상대값을 들고 있다고 셌고, 2026-09-07 e2e 실측은 카드
  167 장 중 **47 장**이 산출물 포인터를 여섯 키 중 하나로 들고 있다고 센다 — 두 숫자는 다른
  것을 센 것이고, 여기서 중요한 것은 그 링크들이 전부 죽어 있었다는 사실이다. 같은 날 실린 큐 폴더 선택기가 `Settings.shared.queueFolder` 를
  `root` 의 최우선 출처로 만들어서, 사용자가 아무 폴더나 고르면 Orca 세션 작업 폴더까지 그
  폴더를 따라가는 상태였다. 안 터진 것이 아니라 클릭 한 번 거리였다.
  ASSUMPTION (L1, 갈래를 스스로 골랐다 · **미검증 전제**): "`organization/` 하위 디렉터리가
  워크스페이스 루트의 표식이다" 는 **이 맥의 배치 규약에서 온 설계 가설이지 영구 사실이 아니다.**
  규약이 바뀌면 표식도 바뀐다. 오늘 그 규약은 `lion_work/organization/<조직>/...` 이고 표식이
  루트 바로 밑에 있다. 규약이 바뀌면 고칠 자리는 `resolveLionWorkRootPath` 의 걷기 한 곳이다.
  되돌린 가정: 앞선 판의 `ASSUMPTION` 은 "상수로 못박지 않고 큐 경로에서 되짚는다 …
  `/organization/` 이 없으면 그 폴더 자신을 루트로 본다" 였다. 되돌리는 근거 둘 — (1)
  `organization/` 을 가진 픽스처는 2 단계가 그대로 잡으므로 잃는 것은 `organization/` 이 **없는**
  픽스처뿐이고 그것은 `CM_LION_WORK_DIR` 하나로 해결된다. (2) 실측 — `CM_WORK_QUEUE_DIR` 를
  설정하는 **자동 러너가 하나도 없다**(`.e2e/package.json` 과 `scripts/` 전수 확인). 옛 폴백이
  지키던 상황은 오늘 아무도 밟지 않는다.
  Verified: 2026-09-07 실측. `swift build` 통과(0 error). 단위 시험
  `scripts/run-unit-tests.sh` **39 tests in 5 suites passed** (LionWorkRootTests 8 개 포함).
  `.e2e/issues.test.js` **219 PASS 0 FAIL** 이고 라이브 큐 블록이 **실제로 돌았다** —
  `live: total=167` · `47 reading all six keys` 가 출력에 있다. 고치기 전에는 이 블록이
  통째로 건너뛰어지고 있었다: `QDIR` 폴백이 죽은 경로
  `/Users/lioncho/Work/lion_work/organization/lion/lion-work-queue` 였고 바로 아래
  `fs.existsSync` 가 거짓이 되어, **이 결함을 잡았어야 할 게이트가 스스로 꺼져 있었다.**
  게이트가 진짜로 도는지는 **일부러 깨뜨려서** 확인했다 — (a) `lionWorkRoot` 에 큐 폴더로
  떨어지는 갈래를 도로 넣으니 1 FAIL, (b) `defaultRootPath` 를 옛 경로로 되돌리니 3 FAIL 이고
  그중 하나가 "라이브 블록이 안 돌았다" 자신이며, (c) 루트 상수를 큐 기본값에서 잘라 만드니
  3 FAIL. (d) 단위 시험 쪽도 3 단계를 큐 폴더로 되돌려 5 issues 로 지는 것을 봤다. 넷 다
  되돌린 뒤 다시 219 PASS 0 FAIL · 39 tests passed 다.
  단위 시험은 `CM_DATA_DIR` 로 격리한 임시 store 에서만 돈다(`scripts/run-unit-tests.sh`).
  `Settings` 는 UserDefaults 가 아니라 `<data>/settings.json` 에 진짜로 쓰므로, 도는 앱과 시험이
  같은 파일에 붙으면 서로의 키를 덮어쓴다 — 이날 `cm.queueFolder` 가 한 번 그렇게 날아갔고
  앱의 `/api/settings/queue-folder` 로 되돌려 놓았다. `.claude/settings.local.json` 이
  `CM_DATA_DIR=~/.condition-mate` 를 넣어 두므로 "설정돼 있다" 가 곧 "격리돼 있다" 가 아니고,
  러너가 `AppPaths.isCustom` 과 같은 규칙으로 경로를 비교해 판정한다.
  앱을 다시 빌드해 `/Applications` 에 넣지 않았고, 커밋하지 않았고, `AppDelegate.swift` ·
  `IssuesContent.swift` · `SessionRail.swift` 는 한 줄도 안 건드렸다 — 병렬 `FAST` 자식 소유다.
