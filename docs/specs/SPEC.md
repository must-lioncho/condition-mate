# Condition Manager — SPEC (per-page, bilingual)

EN: Source of truth for **manager-qa** regression testing, owned by manager-qa. Organized **per page/screen** (not per category) so a broken page is obvious at a glance. Base format = this Markdown file. `SPEC.html` is a generated, human-friendly render of the same content — regenerate it in the same change whenever this file changes.
KO: **manager-qa** 회귀 테스트의 기준 문서이며 manager-qa가 소유·관리한다. 카테고리가 아니라 **페이지/화면별**로 정리해 깨진 페이지가 한눈에 보이게 한다. 기준 포맷은 이 Markdown 파일이고, `SPEC.html`은 같은 내용을 사람이 보기 좋게 만든 생성물이다 — 이 파일이 바뀌면 같은 작업에서 다시 생성한다.

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
  EN: Verification uses `<CM_DATA_DIR>/app.log` (KST timestamps, `Core/AppLog.swift`) and isolated bundle instances with a **unique** bundle id + `CM_QUIT_AFTER`. See the manager-qa agent playbook.
  KO: 검증은 `<CM_DATA_DIR>/app.log`(KST 타임스탬프, `Core/AppLog.swift`)와, **유니크한** 번들 id + `CM_QUIT_AFTER`를 사용하는 격리 번들 인스턴스로 수행한다. manager-qa 플레이북을 참고하라.

## Page index

| Page | id prefix | Source |
|---|---|---|
| P1. Menu-bar widget (status item + menu) | `WIDGET-` | `UI/MenuController.swift` |
| P2. App window lifecycle (shared across both modes) | `WINLIFE-` | `UI/AppWindow.swift`, `AppDelegate.swift` |
| P3. App window — BGM mode / 액티비티 sub-tab | `BGMACT-` | `Dashboard/BGMPlayerContent.swift` |
| P4. App window — BGM mode / 디버그 sub-tab | `BGMDBG-` | `Dashboard/BGMPlayerContent.swift` |
| P5. App window — 대시보드 mode | `DASH-` | `Dashboard/DashboardContent.swift` |
| P6. Server / endpoints | `EP-` | `AppDelegate.swift` (handlePost/apiGet/file), `Dashboard/DashboardServer.swift` |
| P7. Cross-cutting: logging | `LOG-` | `Core/AppLog.swift` |

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
  "ConditionManager"` is AMBIGUOUS whenever a `dev-watch.sh`-spawned instance is also running (same
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
  ("컨디션 전체 보기") and the BGM page's "← 대시보드" button, both calling
  `POST /api/window/mode {mode}` — see WINLIFE-10. This item's Verify recipe below (real coordinate
  clicks on a titlebar segmented control) can no longer be exercised because the control is not on
  screen; kept for history only, do not re-run as written.
  KO: **2026-07-06 폐기(RETIRED) / 문서상 낡음.** 아래 설명된 타이틀바 세그먼트 대시보드/컨디션
  토글은 2026-07-06 내비게이션 리팩터에서 제거되었다. 코드 직접 확인으로 확정
  (`AppWindow.swift` ~354-358): `NSSegmentedControl`은 여전히 생성되고 연결되어 있지만(그래서
  `setMode`의 `segmented?.selectedSegment = ...`가 무해한 no-op으로 남음), `addTitlebarAccessoryViewController`로
  붙는 곳은 더 이상 없다 — 현재 파일엔 그런 호출이 없고 예전 패턴을 언급하는 주석만 남아 있다.
  내비게이션은 이제 레일의 컨디션 팝업("컨디션 전체 보기")과 BGM 페이지의 "← 대시보드" 버튼이
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
  popup button "컨디션 전체 보기", which POSTs `{mode:"condition"}`; (b) the BGM page's "← 대시보드"
  button, which POSTs `{mode:"dashboard"}`. Both call the SAME underlying mechanism as before
  (`AppWindowController.setMode` via `openBGMWindow()`/`openDashboard()`) — only the trigger UI
  changed, not the two-webview seamless-switch architecture (WINLIFE-3 still applies unchanged: the
  BGM webview is never reloaded on switch, native stays muted the whole time the window is open).
  KO: 타이틀바 세그먼트 토글(WINLIFE-7, 폐기됨)이 제거됐다. 대시보드와 전체 컨디션(BGM) 화면 사이
  전환은 이제 (a) 사이드바 레일의 컨디션 팝업 버튼 "컨디션 전체 보기"(`{mode:"condition"}` POST)와
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
- **BGMACT-2 — state machine has no stuck limbo.**
  EN: `GET /api/bgm/now` distinguishes `on` (system engaged) from `playing` (a resolvable track is
  actually streaming) from `id` (which library track). The status dot follows `on`; whether a
  track is queued follows `id>=0`, so warm-up/library-reload never reads as fully dead.
  KO: `on`(시스템 켜짐) / `playing`(실제 스트리밍 중) / `id`(어떤 곡)을 구분해, 워밍업이나
  라이브러리 리로드 중에도 "완전히 죽은" 상태로 안 보이게 한다.
  Verify: `AppDelegate.swift:bgmNowJSON` — `on = director.isPlaying`; `playing = on && !isPaused &&
  id >= 0`.
- **BGMACT-3 — the play button follows the browser transport.**
  EN: Once the user "engages" (first play gesture / auto-cue), further track switches (from the
  director) auto-play in this same webview; before engaging, native stays audible and this view
  just cues silently.
  KO: 사용자가 한 번 재생을 "잡으면" 이후 곡 전환도 이 화면에서 자동재생되고, 잡기 전까지는
  네이티브가 계속 들리며 이 화면은 조용히 큐만 잡는다.
  Verify: `BGMPlayerContent.swift:refreshNow()` — `engaged` flag gates auto-play vs. cue-only.
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
  History: found 2026-07-06 by manager-qa during the goal-link-and-generic-queue Phase 4 QA pass;
  fixed same day and re-verified PASS by manager-qa in fix-loop round 2.
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
  History: found 2026-07-06 by manager-qa during the goal-link-and-generic-queue Phase 4 QA pass;
  fixed same day and re-verified PASS by manager-qa in fix-loop round 2.
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
  History: DASH-6/7/8 added 2026-07-06 by manager-qa, Phase 4 QA pass for
  `docs/specs/goal-link-and-generic-queue.md`. Backend contract (link/unlink/idempotency/self/
  not-found, setParent guard, backward-compat, single-serial worker, retry/remove, linkmap cycle
  safety, non-blocking enqueue) all PASS. Two gaps found and reported (DASH-6 `/data.json` missing
  `links`; DASH-7 `lastView` clamp missing `"queue"`) — both fixed same day and RE-VERIFIED PASS by
  manager-qa in fix-loop round 2 (see RESOLVED notes above).

### Intent audit — P5
EN: **REGRESSION-CLASS FINDING (spec drift, confirmed):** the old A1 item's documented "third audio
source" — the dashboard's own in-page "BGM 관리" tab as a lazy-loaded `<iframe id="bgmFrame">` of
`/bgm-player` — **no longer exists in `DashboardContent.swift`.** Confirmed by:
`grep -n "bgmFrame" Sources/ConditionManager/Dashboard/DashboardContent.swift` → no matches;
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
`grep -n "bgmFrame" Sources/ConditionManager/Dashboard/DashboardContent.swift` → 일치 없음;
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
by manager-qa in fix-loop round 2 (see the RESOLVED notes under DASH-6/DASH-7 above for the live
evidence).
KO: **공백(2026-07-06, DASH-6/DASH-7) — 같은 날 2라운드에서 해결됨:** 목표-링크 + 범용-큐 기능에서
의도-동작 불일치 두 건이 발견됐다(전체 근거는 위 DASH-6/DASH-7 참고): (1) 백엔드는 `Goal.links`를
올바르게 저장·유지했지만 손수 작성한 `/data.json` 직렬화기가 이를 전혀 내보내지 않아, "링크가 있는
행에 점 표시"라는 의도된 UI가 실제로는 절대 렌더되지 않았다 — 코드의 의도(점 표시)와 동작(데이터가
클라이언트에 안 옴 → 점 없음)이 달랐다; (2) "보던 큐 탭으로 돌아오기"라는 의도된 지속성이, 탭 추가
시 서버측 뷰-이름 허용목록을 갱신하지 않아 조용히 실패했다. 둘 다 좁고 기계적인 수정(직렬화기에
필드 하나 추가; 배열에 문자열 하나 추가)이었으며 — 적용 후 manager-qa가 fix-loop 2라운드에서
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
  Verify: isolated instance 2026-07-08 (manager-qa) — library `loaded 187 tracks (164 no-BPM
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
  Verify: isolated instance 2026-07-08 (manager-qa) — heavy_rain 9곡 로드(id 70-78, bpm 110); 강제
  start → 다음 tick에 `now.plan:"🌧 폭우 리셋 59분"` + id 70(heavy_rain), `director.jsonl`에 "폭우
  리셋 발동" 라인; `rain-reset.txt`=오늘 날짜; stop → 즉시 플랜 슬롯("수 아침 · 대항해")·비-heavy_rain
  트랙 복귀 + "복귀" 라인; 심야 슬롯=snow/peace, heavy_rain 스케줄 슬롯 0개; 신규 세션 60초 관찰 시
  자발 폭우 없음(크레딧 미달로 구조적 불가). 자격 판정 로직은 standalone Swift 스크립트 9/9 통과
  (repo에 XCTest 타겟은 없음 — 라이브 상태머신 4회 실행으로 동등 검증). malformed body 4종 무크래시
  (수정 후 `{"ok":false}` no-op).

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
