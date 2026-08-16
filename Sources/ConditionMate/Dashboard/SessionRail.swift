import Foundation

// Shared left rail injected into BOTH the dashboard (`/`) and every goal page
// (`/goal?n=NN`). It mirrors the Claude-Code-desktop shell: a persistent sidebar
// with a "새 대화" pop-out, a 대시보드 link, and a live list of background CLI
// sessions. Because the in-page CLI's PTY now survives navigation (server-side),
// this rail is what makes a backgrounded session reachable again — clicking a
// session navigates to its goal page with ?cli=1, which auto-reconnects and
// replays the terminal buffer.
//
// One self-contained block (markup + CSS + JS), returned as a raw string so it can
// be interpolated into the dashboard's raw string (`\#(...)`) and the goal page's
// normal string (`\(...)`) alike. 목표 만들기/검색 nav items navigate to the dedicated
// goal-add page (`/goal-add`), which works identically from every page.
enum SessionRail {
    static func html() -> String {
        return #"""
        \#(CMTimeFilter.bootHTML())
        <style>
          /* --cmrail-w is the space the rail TAKES FROM THE PAGE, so it goes to 0 when the rail
             is collapsed and every consumer (body padding, the skills/agents/team overlays,
             GoalAdd's fixed 세션 컴포저 bar) follows automatically. The rail's own width stays
             a literal 240px — it slides out of view rather than shrinking. */
          :root{ --cmrail-w:240px }
          body{ padding-left:var(--cmrail-w) }
          body.cmrail-collapsed{ --cmrail-w:0px }
          .cmrail{ position:fixed; top:0; left:0; bottom:0; width:240px; z-index:40;
            background:#0d1017; border-right:1px solid #1c2230; display:flex; flex-direction:column;
            font:13px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif; color:#c8cfdb }
          body.cmrail-collapsed .cmrail{ transform:translateX(-100%) }
          /* Zen (rail-width window) shows ONLY the rail — it must win over a persisted manual
             collapse, or the zen window would be entirely empty. Same specificity, later rule. */
          body.cm-zen .cmrail{ transform:none }
          /* Zen folds the native window to rail width (242pt) on EVERY page, not just the
             dashboard — but only the dashboard styled its own board away (.wrap). On
             /goal-add the 메모장·컴포저 stayed rendered and got crushed into a 242pt column
             (세로로 한 글자씩 흐르는 깨진 화면). Hide every non-rail top-level block here, in
             the rail's global CSS, so any page folds to just the rail's dial/button.
             .wrap is excluded on purpose: the dashboard fades it (opacity/visibility) so the
             board can transition back in on reveal. */
          body.cm-zen > *:not(.cmrail):not(.wrap):not(.cmzen-peek):not(script):not(style){ display:none !important }
          /* The native window uses fullSizeContentView (see AppWindow.swift) so this web content
             rides up under the transparent titlebar — the traffic-light window buttons occupy
             roughly the top-left ~78px wide x ~28px tall. Push the rail header down below them
             with a comfortable gap instead of letting the logo/title/toggle sit under the dots. */
          /* Rail header: no brand text/logo — just the sidebar-toggle and session-search icons,
             sitting on the same row as (to the right of) the native traffic-light window buttons.
             The traffic lights occupy ~78px at top-left, so pad the left to clear them. */
          .cmrail-brand{ display:flex; align-items:center; gap:2px; padding:2px 10px 6px 84px; min-height:30px }
          /* Top-of-rail mode navigation (대화/스킬/크론/위임/팀위임/작업 + 미정×3) — a horizontal
             segmented switcher like the Claude-Code shell's Chat/Cowork/Code control. Nine items form
             a 3-column × 3-row grid of vertical mini-tabs (icon over label), ordered by the intended
             work flow: 대화로 목표를 만들고(대화) → 실행한다. 대화/스킬/크론/작업 route to real
             surfaces (크론 → 워커 뷰); 위임 opens the rail-owned agents overlay; 팀위임 opens the
             team-discussion composer (#cmTeamOverlay). The 계획 menu (planning composer overlay)
             was removed 2026-07-19 — planning now happens inside a goal session itself; the server
             side (/api/plan/delegate, preset:'plan') stays for legacy "계획:" goals. The 메모장
             focus shortcut was removed 2026-07-21. The three 미정 slots are reserved
             placeholders (disabled). */
          .cmrail-nav{ display:grid; grid-template-columns:repeat(3,1fr); gap:4px; padding:6px;
            margin:0 8px 6px; background:#0f141d; border:1px solid #1c2230; border-radius:12px }
          .cmrail-item{ position:relative; display:flex; flex-direction:column; align-items:center;
            justify-content:center; gap:4px; padding:9px 4px; border-radius:8px; color:#c8cfdb;
            text-decoration:none; font-size:12px; cursor:pointer; text-align:center }
          .cmrail-item:hover{ background:#161c2a }
          .cmrail-item.on{ background:#152036; color:#e7ecf4 }
          /* Monochrome line icons (SF-Symbols style): a single dim tint at rest so the six
             nav items read as one calm set; the ACTIVE item alone lights up blue (icon + label)
             to mark the current surface. Replaces the multi-color emoji that looked busy. */
          .cmrail-item .cmr-ico{ font-size:16px; line-height:1; flex:none;
            display:flex; align-items:center; justify-content:center; height:18px }
          .cmrail-item .cmr-ico svg{ width:17px; height:17px; display:block; stroke:currentColor; color:#8b93a7 }
          .cmrail-item:hover .cmr-ico svg{ color:#c8cfdb }
          .cmrail-item.on .cmr-lbl{ color:#7db0ff }
          .cmrail-item.on .cmr-ico svg{ color:#5b8cff }
          .cmrail-item .cmr-lbl{ max-width:100%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          /* 미정(reserved) slots: visible so the 3×3 grid reads complete, but clearly inert. */
          .cmrail-item.off{ opacity:.35; pointer-events:none }
          .cmrail-item .cmr-cap{ flex:none; font-size:8.5px; line-height:1; color:#5d6678; background:#141a26;
            border:1px solid #222c3e; border-radius:999px; padding:2px 5px }
          .cmrail-seclabel{ padding:10px 16px 6px; font-size:11px; letter-spacing:.04em; color:#5d6678; text-transform:uppercase }
          /* Work surface wrapper: always flex:1 (fills the rail, keeping the settings bar pinned to the
             bottom). Invisible pre-challenge; fades in when the challenge starts. padding-bottom while
             running reserves the docked dial's footprint so the session list never slides under it. */
          .cmrail-work{ flex:1; display:flex; flex-direction:column; min-height:0;
            opacity:0; pointer-events:none; transition:opacity .5s ease }
          .cmrail.chrun .cmrail-work{ opacity:1; pointer-events:auto; transition-delay:.22s; padding-bottom:190px }
          .cmrail-sessions{ flex:1; overflow-y:auto; padding:0 8px 14px }
          .cmrail-empty{ display:block; padding:8px 10px; color:#5d6678; font-size:12px }
          /* 세션 목록 안의 소제목(고정됨 / 세션). 상단 고정 seclabel 과 같은 서체지만 목록
             안쪽이라 여백을 줄였고, 첫 소제목은 위 여백을 더 줄여 목록 상단에 붙인다. */
          .cmrail-sessions .cmrail-subhd{ padding:8px 8px 4px; font-size:11px; letter-spacing:.04em;
            color:#5d6678; text-transform:uppercase }
          .cmrail-sessions .cmrail-subhd:first-child{ padding-top:2px }
          .cmrail-sess{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-radius:8px; cursor:pointer }
          .cmrail-sess:hover{ background:#161c2a }
          .cmrail-sess.on{ background:#1a2438 }
          .cmrail-sess .dot{ width:9px; height:9px; border-radius:50%; flex:none; background:#8b93a7; box-sizing:border-box }
          .cmrail-sess .dot.pulse{ animation:cmpulse 1.4s ease-in-out infinite }      /* 진행 중 (gray blink) */
          .cmrail-sess .dot.hollow{ background:transparent; border:1.5px solid #8b93a7 }/* 완료 (empty ring) */
          @keyframes cmpulse{ 0%,100%{ opacity:1 } 50%{ opacity:.3 } }
          .cmrail-sess .meta{ min-width:0; flex:1; margin:0 }
          /* margin:0 defends against host-page globals — the dashboard defines a generic
             `.sub{margin-bottom:20px}` that would otherwise bleed in and balloon each row's
             gap (rail looked wide on `/`, tight on goal pages). Reset it here so the rail
             renders identically everywhere. */
          .cmrail-sess .ttl{ color:#dbe2ee; font-size:13px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; margin:0 }
          .cmrail-sess .sub{ color:#6b7589; font-size:11px; margin:0 }
          .cmrail-sess .kill{ flex:none; visibility:hidden; background:none; border:0; color:#7a8499; cursor:pointer; font-size:13px; padding:2px 4px; border-radius:5px }
          .cmrail-sess:hover .kill{ visibility:visible }
          .cmrail-sess .kill:hover{ background:#2a2230; color:#e2667d }
          /* Per-session "⋯" overflow button → opens a small menu (보관 / 세션 종료). Shown on
             hover for every row (not just live PTY ones) so any session can be archived away. */
          .cmrail-sess .more{ flex:none; visibility:hidden; background:none; border:0; color:#7a8499;
            cursor:pointer; font-size:16px; line-height:1; padding:2px 5px; border-radius:5px }
          .cmrail-sess:hover .more{ visibility:visible }
          .cmrail-sess .more:hover{ background:#222a3a; color:#e7ecf4 }
          /* ── AI 정리 (메모장 → 클로드 코드) ────────────────────────────────
             세션 행과 같은 생김새를 쓴다 — 사용자에게는 둘 다 "맡겨 둔 일" 이라 다른
             모양일 이유가 없다. 다만 진행 중인 줄은 경과 시간이 1초마다 오르고(멈춘 것이
             아니라는 유일한 신호), 끝난 줄은 눌러 결과를 다시 복사한다.
             빈 목록이면 컨테이너째 접힌다(:empty) — 평소 레일은 조용하게. */
          .cmrail-tidy{ padding:0 8px }
          .cmrail-tidy:empty{ display:none }
          /* '세션' 절 이름과 같은 리듬 — 레일에서 같은 층위의 묶음이기 때문. */
          .cmrail-tidy .cmrail-subhd{ padding:10px 8px 6px; font-size:11px; letter-spacing:.04em;
            color:#5d6678; text-transform:uppercase }
          .cmrail-tidy .el{ flex:none; color:#8792a5; font-size:11px; font-variant-numeric:tabular-nums }
          /* 결과 창 — 레일 오른쪽에 떠서 본문을 가리지 않는다. */
          .cmtidy-pop{ position:fixed; z-index:90; width:min(520px, calc(100vw - 40px));
            max-height:min(70vh, 560px); display:none; flex-direction:column;
            background:#171d2b; border:1px solid #2a3450; border-radius:12px;
            box-shadow:0 18px 44px rgba(0,0,0,.6); padding:12px 13px 11px }
          .cmtidy-pop .hd{ display:flex; align-items:center; gap:8px; margin-bottom:8px }
          .cmtidy-pop .hd b{ font-size:13px; color:#e7ecf4; font-weight:600; min-width:0;
            overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          .cmtidy-pop .hd .sp{ flex:1 }
          .cmtidy-pop pre{ flex:1; min-height:0; overflow:auto; margin:0 0 10px; padding:10px 11px;
            background:#0e1320; border-radius:9px; white-space:pre-wrap; word-break:break-word;
            color:#dbe2ee; font:12.5px/1.7 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif }
          .cmtidy-pop .ax{ display:flex; gap:7px; justify-content:flex-end; align-items:center }
          .cmtidy-pop .ax .note{ margin-right:auto; font-size:11px; color:#6b7589 }
          .cmtidy-pop button{ background:#20283a; border:1px solid #2f3a54; color:#e7ecf4;
            border-radius:8px; padding:6px 13px; font-size:12.5px; cursor:pointer; font-family:inherit }
          .cmtidy-pop button.pri{ background:#2f5bd0; border-color:#3d63b8; font-weight:600 }
          .cmtidy-pop button:hover{ filter:brightness(1.12) }
          /* Body-level floating menu anchored under the clicked "⋯" (fixed, so the 3s session
             poll rebuilding the list never yanks it out from under the pointer). */
          .cmrail-menu{ position:fixed; z-index:60; min-width:158px; background:#171d2b; border:1px solid #2a3450;
            border-radius:10px; box-shadow:0 12px 34px rgba(0,0,0,.55); padding:5px; display:none }
          .cmrail-menu button{ display:flex; align-items:center; gap:9px; width:100%; text-align:left;
            background:none; border:0; color:#c8cfdb; font:inherit; font-size:12.5px; padding:8px 10px;
            border-radius:7px; cursor:pointer; white-space:nowrap }
          .cmrail-menu button:hover{ background:#222c40 }
          .cmrail-menu button.danger:hover{ background:#2a2230; color:#e2667d }
          /* Native-style sidebar toggle: a flat icon button (no filled gray box) using the
             macOS "sidebar.left" glyph (rectangle with a vertical divider) instead of a chevron
             or hamburger, so it reads like a real toolbar control next to the traffic lights
             rather than a floating gray "<" pill. Shared by the in-rail collapse button and the
             floating show-again button (when collapsed) — both cycle the same stage machine. */
          .cmrail-sbtoggle{ display:inline-flex; align-items:center; justify-content:center; width:26px; height:26px;
            border-radius:6px; background:none; border:0; color:#8b93a7; cursor:pointer; padding:0 }
          .cmrail-sbtoggle:hover{ background:rgba(255,255,255,.08); color:#e7ecf4 }
          .cmrail-sbtoggle svg{ width:16px; height:16px; display:block; pointer-events:none }
          /* Stage indicator (메모장만 / 메모+컴포저 / 작업+대화) next to the toggle: three dots so the
             third stage is discoverable at all — a plain icon button gives no hint that pressing
             again goes further. Only rendered on pages that host the full 3-stage machine. */
          .cmrail-dots{ display:none; align-items:center; gap:3px; padding-left:1px }
          .cmrail-dots.on{ display:inline-flex }
          .cmrail-dots i{ width:4px; height:4px; border-radius:50%; background:#39415a }
          .cmrail-dots i.at{ background:#5b8cff }
          /* When collapsed, the floating show-again cluster must land on the SAME spot the in-rail
             toggle occupied while expanded (right of the traffic lights, top titlebar row) so it
             doesn't visually jump downward. Match .cmrail-brand's top padding (2px) and left
             padding (84px, which clears the ~78px traffic-light cluster). */
          .cmrail-toggle{ position:fixed; top:2px; left:84px; z-index:41; display:none;
            align-items:center; gap:2px }
          body.cmrail-collapsed .cmrail-toggle{ display:inline-flex }
          /* ===== 1단계: 메모장만 (문서형) — 대화/보드까지 걷어내고 메모 패드만 남긴다.
             패드 자체의 문서형 스타일은 MemoPad.swift 가 갖고, 여기서는 "나머지를 숨긴다"만
             책임진다. main 의 형제(#gsHead·컴포저·큐 등)와 하단 고정 바가 대상. */
          body.cmmemo-only main > *:not(.cmmemo){ display:none !important }
          body.cmmemo-only .gs-bar, body.cmmemo-only .wrap, body.cmmemo-only .cmzen-peek{ display:none !important }
          /* ===== Challenge dial: the one prominent start/stop control (챌린지 = 재생 + 음원).
             Wired to the shared state module — POST /api/session/control + /api/session/mute, and
             reflects GET /api/session/state — so this dial, the menu, ⌘S/⌘M, and the BGM player all
             agree. Unlimited challenge (no fixed target), so the ring is a per-minute sweep and the
             1-lap/second orbit dot give the "alive/progressing" feel without faking a countdown. */
          /* The dial is an absolute overlay inside the rail so it can glide between two anchors:
             idle → a larger HERO up top (draws attention, hosts the 5s countdown); running → a compact
             DOCK just above the settings bar. Toggling .chrun on the rail animates top+scale (proposal A:
             slide + shrink); the work surface fades in as it descends. */
          /* width is CONSTRAINED (not full-rail) so the HERO scale(1.22) doesn't blow the card past
             the 240px rail: full width × 1.22 = ~293px, overflowing ~26px each side (clipping the 25분
             pill at the window edge). 190px × 1.22 ≈ 232px fits inside with a small margin. box-sizing
             keeps padding inside that 190px; margin-inline:auto centers it between left:0/right:0. */
          .cmch{ position:absolute; left:0; right:0; z-index:5; box-sizing:border-box; width:190px; margin-inline:auto;
            display:flex; flex-direction:column; align-items:center; gap:9px; padding:0 14px;
            top:24%; transform:scale(1.22); transform-origin:center top;
            transition:top .85s cubic-bezier(.32,.03,.2,1), transform .85s cubic-bezier(.32,.03,.2,1) }
          .cmrail.chrun .cmch{ top:calc(100% - 234px); transform:scale(1) }
          /* The rail-level update button sits in normal flow above the settings bar, but the
             docked dial is an absolute overlay — it won't be pushed up by flow. Shift the dock
             anchor up by the button's height (≈42px incl. margin) while the button is visible,
             or the button covers the dial's timer/APM sub-line. */
          .cmrail.chrun.cmupd .cmch{ top:calc(100% - 276px) }
          /* The docked (running) dial shares the bottom area with the condition-menu popup. While that
             popup is open, fade the dial out so its red stop button / timer don't overlap the menu. */
          .cmrail.cmcond-open .cmch{ opacity:0; pointer-events:none; transition:opacity .18s }
          /* Suppress the glide on first paint (e.g. a page loaded mid-session shouldn't animate in). */
          .cmrail.cmboot .cmch, .cmrail.cmboot .cmrail-work{ transition:none !important }
          @media (prefers-reduced-motion: reduce){ .cmch, .cmrail-work{ transition:none !important } }
          .cmch-dial{ position:relative; width:116px; height:116px }
          .cmch-dial svg{ position:absolute; inset:0 }
          .cmch-dial .rot{ transform:rotate(-90deg); transform-origin:58px 58px }
          .cmch-track{ fill:none; stroke:#1b2432; stroke-width:5 }
          .cmch-prog{ fill:none; stroke:url(#cmchG); stroke-width:5; stroke-linecap:round;
            stroke-dasharray:333; stroke-dashoffset:333; transition:stroke-dashoffset .3s linear }
          .cmch-orbit{ transform-origin:58px 58px; animation:cmchOrbit 1s linear infinite }
          .cmch-orbit-dot{ fill:#bcd3ff; filter:drop-shadow(0 0 3px rgba(96,165,250,.9)) }
          .cmch-btn{ position:absolute; inset:18px; border-radius:50%; border:0; cursor:pointer;
            background:linear-gradient(135deg,#3b82f6,#2563eb); display:grid; place-items:center;
            box-shadow:0 10px 24px -8px rgba(59,130,246,.55), inset 0 1px 0 rgba(255,255,255,.25); transition:.16s }
          .cmch-btn:hover{ transform:scale(1.04) } .cmch-btn:active{ transform:scale(.96) }
          .cmch-btn .tri{ width:0; height:0; border-style:solid; border-width:13px 0 13px 21px;
            border-color:transparent transparent transparent #fff; margin-left:5px }
          .cmch-btn.on{ background:linear-gradient(135deg,#ef4444,#dc2626) }
          .cmch-btn.on .tri{ width:22px; height:22px; border:0; border-radius:5px; background:#fff; margin:0 }
          /* Pre-start countdown: the center button shows 5→1 (amber) instead of the play triangle. */
          .cmch-cd{ display:none; color:#fff; font-size:30px; font-weight:800; line-height:1; font-variant-numeric:tabular-nums }
          .cmch.counting .cmch-btn{ background:linear-gradient(135deg,#f59e0b,#d97706) }
          .cmch.counting .cmch-btn .tri{ display:none }
          .cmch.counting .cmch-btn .cmch-cd{ display:block }
          /* ===== Pomodoro completion reward (B: tap-to-harvest 🍅, C: daily N/2 tracker) ===== */
          .cmch-tom{ display:none; font-size:34px; line-height:1 }
          .cmch.reward .cmch-btn{ background:linear-gradient(135deg,#f59e0b,#d97706); cursor:pointer;
            animation:cmchBeat2 1.1s ease-in-out infinite }
          .cmch.reward .cmch-btn .tri, .cmch.reward .cmch-btn .sq, .cmch.reward .cmch-btn .cmch-cd{ display:none }
          .cmch.reward .cmch-btn .cmch-tom{ display:block }
          .cmch.reward .cmch-modes, .cmch.reward .cmch-timer, .cmch.reward .cmch-mute{ display:none }
          .cmch.reward .cmch-sub, .cmch.done .cmch-sub{ display:flex }   /* show the N/2 tracker note */
          .cmch.done .cmch-mute{ display:none }
          @keyframes cmchBeat2{ 0%,100%{ transform:scale(1) } 50%{ transform:scale(1.06) } }
          /* Confetti burst from the dial center on harvest. */
          .cmch-burst{ position:absolute; inset:0; pointer-events:none; z-index:6 }
          .cmch-pt{ position:absolute; left:50%; top:50%; width:8px; height:8px; margin:-4px; border-radius:2px;
            transition:transform .85s cubic-bezier(.15,.7,.3,1), opacity .85s ease }
          .cmch-pulse{ position:absolute; inset:18px; border-radius:50%; pointer-events:none;
            box-shadow:0 0 0 0 rgba(59,130,246,.5); animation:cmchRing 2.6s infinite }
          .cmch.run .cmch-pulse{ animation:none }
          .cmch-label{ font-size:13px; font-weight:700; color:#e7ecf4 }
          /* Pre-start mode selector: 25분(포모도로) · 루프 · 무제한. Hidden once running. */
          .cmch-modes{ display:flex; gap:3px; width:100%; padding:3px; border-radius:999px;
            background:#141a26; border:1px solid #222c3e }
          .cmch.run .cmch-modes{ display:none }
          .cmch-modes button{ flex:1; background:none; border:0; color:#8792a5; font-size:11px;
            font-weight:600; padding:4px 6px; border-radius:999px; cursor:pointer; white-space:nowrap }
          .cmch-modes button.on{ background:#1f5bd0; color:#fff }
          .cmch-modes button:hover:not(.on){ color:#c8cfdb }
          .cmch-timer{ display:none; font-variant-numeric:tabular-nums; font-size:21px; font-weight:800;
            color:#e7ecf4; letter-spacing:.5px; line-height:1 }
          .cmch.run .cmch-label{ display:none } .cmch.run .cmch-timer{ display:block }
          .cmch-sub{ display:none; align-items:center; justify-content:center; flex-wrap:wrap;
            gap:3px 7px; font-size:11px; color:#6b7589; line-height:1.5; text-align:center }
          .cmch.run .cmch-sub{ display:flex }
          /* Keep the daily counter ("· 오늘 3/2") as one unbreakable chunk so it never splits
             mid-token, and give it a hair of left breathing room from the mode name. */
          .cmch-day{ white-space:nowrap; margin-left:1px }
          /* Live APM readout (moved here from the old dashboard header gauge). D-style:
             a small intensity pulse-dot + a spring-animated number, shown only while a
             challenge runs. The dot's color/size and the number are driven every frame
             by cmApmFrame() from /live.json's apm·norm. */
          /* Pin the APM readout to its own bottom line (flex-basis:100% forces a wrap) with a hair
             of top gap, so a changing number width never re-wraps the sub-line and makes the block
             jump up/down. Own line → drop the inline "·" separator. */
          .cmch-apm{ display:none; align-items:center; justify-content:center; gap:5px;
            flex-basis:100%; margin-top:2px }
          .cmch-apm .dot{ width:6px; height:6px; border-radius:50%; background:#36c08a; flex:none }
          .cmch-apm b{ font-variant-numeric:tabular-nums; font-weight:700; color:#c8cfdb }
          .cmch-apm .u{ font-size:9.5px; color:#5d6678; letter-spacing:.03em; margin-left:1px }
          /* During the launch auto-start countdown, show the timer + hint but KEEP the mode selector
             visible — the user can switch what will auto-start, press the dial to start right away,
             or hit the 취소 link in the sub line to cancel. */
          .cmch.counting .cmch-label{ display:none }
          .cmch.counting .cmch-timer{ display:block } .cmch.counting .cmch-sub{ display:flex }
          .cmch-cdcancel{ color:#8792a5; text-decoration:underline; cursor:pointer }
          .cmch-cdcancel:hover{ color:#c8cfdb }
          .cmch-mute{ position:relative; width:11px; height:11px; border-radius:50%; border:0; padding:0;
            cursor:pointer; background:#22c55e; flex:none;
            box-shadow:0 0 0 0 rgba(34,197,94,.6); animation:cmchBeat 1.6s infinite }
          .cmch-mute.muted{ background:#5c6577; animation:none }
          .cmch-mute.muted::after{ content:""; position:absolute; left:1.5px; top:4.5px; width:8px; height:2px;
            background:#fff; border-radius:2px; transform:rotate(-45deg) }
          @keyframes cmchOrbit{ to{ transform:rotate(360deg) } }
          @keyframes cmchRing{ 0%{ box-shadow:0 0 0 0 rgba(59,130,246,.5) } 70%{ box-shadow:0 0 0 15px rgba(59,130,246,0) } 100%{ box-shadow:0 0 0 0 rgba(59,130,246,0) } }
          @keyframes cmchBeat{ 0%{ box-shadow:0 0 0 0 rgba(34,197,94,.6) } 70%{ box-shadow:0 0 0 5px rgba(34,197,94,0) } 100%{ box-shadow:0 0 0 0 rgba(34,197,94,0) } }
          /* ===== Condition control (bottom of rail, always present — a settings-like popup). The
             controls only hit endpoints; the audio lives in the independent engine (native + the
             always-alive BGM webview), so this survives per-page rail re-renders with no audio effect.
             Replaces the old titlebar 대시보드/컨디션 segmented toggle. ===== */
          .cmcond-bar{ display:flex; align-items:center; gap:9px; margin:4px 8px 0; padding:9px 10px;
            border-radius:10px; cursor:pointer; border:1px solid #1c2230; background:#0f141d }
          .cmcond-bar:hover{ background:#141b28 }
          /* Headphone icon = mute shortcut (own hit area; the rest of the bar opens the menu).
             Audible → green animated EQ bars + beat ring (same grammar as .cmch-mute);
             muted → gray + white diagonal strike, animation frozen. */
          .cmcond-hp{ position:relative; width:30px; height:30px; flex:none; display:flex; align-items:center;
            justify-content:center; border-radius:8px; border:0; padding:0; margin-left:-4px;
            background:transparent; cursor:pointer }
          .cmcond-hp:hover{ background:#1d2636 }
          .cmcond-hp svg{ width:19px; height:19px; display:block }
          .cmcond-hp .cup{ stroke:#c3cddd; fill:none; stroke-width:1.5; stroke-linecap:round; stroke-linejoin:round }
          .cmcond-hp:hover .cup{ stroke:#eef3fb }
          .cmcond-hp .eq rect{ fill:#39424f; transform-origin:center 13.5px; transform:scaleY(.35) }
          .cmcond-bar.hp-live .cmcond-hp .eq rect{ fill:#22c55e }
          .cmcond-bar.hp-live .cmcond-hp .eq rect:nth-child(1){ animation:cmcondEq 1.05s ease-in-out infinite }
          .cmcond-bar.hp-live .cmcond-hp .eq rect:nth-child(2){ animation:cmcondEq 1.05s ease-in-out -.35s infinite }
          .cmcond-bar.hp-live .cmcond-hp .eq rect:nth-child(3){ animation:cmcondEq 1.05s ease-in-out -.7s infinite }
          .cmcond-bar.hp-live .cmcond-hp::before{ content:""; position:absolute; inset:4px; border-radius:50%;
            box-shadow:0 0 0 0 rgba(34,197,94,.45); animation:cmchBeat 1.6s infinite; pointer-events:none }
          @keyframes cmcondEq{ 0%,100%{ transform:scaleY(.35) } 50%{ transform:scaleY(1) } }
          .cmcond-bar.hp-muted .cmcond-hp .cup{ stroke:#5c6577 }
          .cmcond-bar.hp-muted .cmcond-hp .eq rect{ fill:#5c6577 }
          .cmcond-bar.hp-muted .cmcond-hp::after{ content:""; position:absolute; left:4px; top:14px;
            width:22px; height:2px; background:#e7ecf4; border-radius:2px; transform:rotate(-45deg);
            box-shadow:0 0 0 2.5px #0f141d }
          .cmcond-bar.hp-muted:hover .cmcond-hp::after{ box-shadow:0 0 0 2.5px #141b28 }
          .cmcond-bar.hp-muted .cmcond-track{ color:#8a93a5 }
          .cmcond-meta{ min-width:0; flex:1 }
          .cmcond-track{ color:#dbe2ee; font-size:12.5px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmcond-sub{ color:#6b7589; font-size:11px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmcond-chev{ color:#5d6678; flex:none; font-size:11px; transition:transform .15s }
          .cmcond-bar.open .cmcond-chev{ transform:rotate(180deg) }
          .cmcond-menu{ margin:0 8px 6px; padding:6px; border-radius:12px; background:#171d2b;
            border:1px solid #2a3450; box-shadow:0 -8px 30px rgba(0,0,0,.5) }
          .cmcond-row{ display:flex; align-items:center; gap:8px; padding:8px 10px; font-size:12.5px; color:#c8cfdb }
          .cmcond-row .lbl{ flex:1 }
          .cmcond-tog{ flex:none; border:1px solid #2f3a54; background:#20283a; color:#e7ecf4; border-radius:999px;
            padding:4px 12px; font-size:12px; font-weight:600; cursor:pointer }
          .cmcond-tog.on{ background:#1f5bd0; border-color:#2f6bff }
          .cmcond-now{ color:#8792a5; font-size:11.5px; padding:6px 10px; border-top:1px solid #202838; margin-top:2px }
          .cmcond-full{ width:100%; margin-top:4px; border:0; background:#20283a; color:#e7ecf4; border-radius:9px;
            padding:9px 10px; font-size:12.5px; font-weight:600; cursor:pointer; text-align:left }
          .cmcond-full:hover{ background:#28324a }
          /* 아이콘: 컬러 이모지 대신 상단 레일 네비와 같은 단색 라인 SVG로 톤앤매너 통일
             (muted gray → hover 시 밝아짐, 레일 .cmr-ico 규칙과 동일 색상). */
          .cmcond-full .cmcond-ico{ display:inline-flex; vertical-align:-3px; margin-right:7px; color:#8b93a7 }
          .cmcond-full .cmcond-ico svg{ width:15px; height:15px; display:block }
          .cmcond-full:hover .cmcond-ico{ color:#c8cfdb }
          /* 업데이트 row: accent-tinted so a pending new build is noticeable but not alarming
             (no red/green status colors by convention). Hidden unless /api/update/check says so. */
          .cmcond-update{ background:#16263f; color:#8fc0ff; border:1px solid #24457a }
          .cmcond-update:hover{ background:#1b2f4f }
          .cmcond-update:disabled{ opacity:.7; cursor:default }
          /* 레일 직접 노출형 업데이트 버튼 — 설정 메뉴 밖, 포모도로 다이얼 바로 아래.
             다이얼은 absolute 오버레이라 flow로 밀리지 않음 — .cmrail.cmupd가 도킹 위치를 올린다. */
          .cmrail-update{ width:calc(100% - 16px); margin:6px 8px 0; padding:9px 10px;
            border-radius:9px; font-size:12.5px; font-weight:600; cursor:pointer; text-align:left }
          /* 준비 중: 백그라운드 빌더가 컴파일하는 동안의 대기 상태. 대기=보라 (프로젝트 규칙),
             누를 수 없다는 걸 커서·투명도로 알리되 사라지지는 않는다. */
          .cmcond-update.cmupd-prep{ background:#1e1a33; color:#b9a3ff; border-color:#352b57;
            cursor:default; opacity:.85 }
          .cmcond-update.cmupd-prep:hover{ background:#1e1a33 }
          /* 장비 row: current overall level chip on the right (fed by /api/equipment) */
          .cmcond-equip{ display:flex; align-items:center }
          .cmcond-equip .cmcond-lv{ margin-left:auto; font-size:11px; font-weight:800; letter-spacing:.3px;
            padding:2px 9px; border-radius:999px; background:#123039; color:#33c9e6; border:1px solid #1d4b57 }
          /* 설정 section: storage folder paths (data / BGM / Claude sessions). Paths render
             right-aligned tail-first (rtl ellipsis) so the meaningful last segments show. */
          .cmcond-paths{ margin-top:4px; padding:4px 2px 2px; border-top:1px solid #202838 }
          .cmcond-paths .hd{ display:flex; align-items:center; gap:6px; padding:4px 8px 6px;
            color:#8792a5; font-size:11px; font-weight:700; letter-spacing:.2px }
          .cmcond-paths .hd .store{ margin-left:auto; font-weight:600; font-size:10.5px; color:#5fae7d }
          .cmcond-paths .hd .store.warn{ color:#e8a33d }
          .cmcond-path{ display:flex; align-items:center; gap:7px; padding:5px 8px; border-radius:8px;
            cursor:pointer }
          .cmcond-path:hover{ background:#1d2636 }
          .cmcond-path .k{ flex:none; width:74px; color:#8a93a5; font-size:11px }
          /* Claude 연결 상태 점 — 유저 요청대로 "연결됨"만 녹색이고, 문제일 때는 신호등
             빨강 대신 경고 앰버(설정 패널의 .store.warn 과 같은 톤)를 쓴다. */
          .cmcond-gwdot{ display:inline-block; width:7px; height:7px; border-radius:50%;
            margin-right:5px; background:#5a6272; vertical-align:middle }
          .cmcond-gwdot.ok{ background:#5fae7d }
          .cmcond-gwdot.bad{ background:#e8a33d }
          .cmcond-path .v{ flex:1; min-width:0; color:#c8cfdb; font-size:10.5px;
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace; white-space:nowrap; overflow:hidden;
            text-overflow:ellipsis; direction:rtl; text-align:left }
          .cmcond-path .v.unset{ color:#6b7589; direction:ltr; font-family:inherit; font-size:11px }
          .cmcond-tzsel{ flex:1; min-width:0; background:#141a26; color:#c8cfdb; border:1px solid #232c3e;
            border-radius:7px; font:inherit; font-size:11px; padding:3px 6px; cursor:pointer }
          .cmcond-path .go{ flex:none; border:0; background:transparent; color:#5d6678; cursor:pointer;
            font-size:12px; padding:2px 4px; border-radius:6px }
          .cmcond-path .go:hover{ color:#c8cfdb; background:#28324a }
          .cmcond-paths .tip{ padding:4px 8px 2px; color:#5d6678; font-size:10px }
        </style>
        <div class="cmrail-toggle">
          <button class="cmrail-sbtoggle" data-cmrail-tg onclick="cmRailToggle(event)" title="세션 레일 열기">
            <svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
              <rect x="1.5" y="2.5" width="13" height="11" rx="2" stroke="currentColor" stroke-width="1.3"/>
              <line x1="6" y1="2.5" x2="6" y2="13.5" stroke="currentColor" stroke-width="1.3"/>
            </svg>
          </button>
          <span class="cmrail-dots" data-cmrail-dots><i></i><i></i><i></i></span>
        </div>
        <aside class="cmrail cmboot" id="cmRail">
          <div class="cmrail-brand">
            <button class="cmrail-sbtoggle" data-cmrail-tg onclick="cmRailToggle(event)" title="접기">
              <svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
                <rect x="1.5" y="2.5" width="13" height="11" rx="2" stroke="currentColor" stroke-width="1.3"/>
                <line x1="6" y1="2.5" x2="6" y2="13.5" stroke="currentColor" stroke-width="1.3"/>
              </svg>
            </button>
            <span class="cmrail-dots" data-cmrail-dots><i></i><i></i><i></i></span>
            <button class="cmrail-sbtoggle" onclick="cmRailGoalSearch()" title="목표 검색">
              <svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
                <circle cx="7" cy="7" r="4.5" stroke="currentColor" stroke-width="1.3"/>
                <line x1="10.6" y1="10.6" x2="14" y2="14" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/>
              </svg>
            </button>
          </div>
          <!-- Work surface (모드 네비 + 세션). Hidden until a challenge is running — before
               that the rail shows only the challenge dial above the settings bar. Uses visibility so
               the wrapper keeps its flex:1 space, pinning the dial+settings to the bottom either way. -->
          <div class="cmrail-work" id="cmRailWork">
            <nav class="cmrail-nav" id="cmRailNav">
              <a class="cmrail-item" data-nav="chat" onclick="cmNav('chat')" title="대화를 통해 목표를 만듭니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 7.5c0-2.2 2.3-4 5.5-4s5.5 1.8 5.5 4-2.3 4-5.5 4c-.7 0-1.4-.08-2-.23L3.2 12.7l.7-2.1C3 9.85 2.5 8.73 2.5 7.5Z"/></svg></span><span class="cmr-lbl">대화</span></a>
              <a class="cmrail-item" data-nav="skills" onclick="cmNav('skills')" title="플러그인·스킬로 기능을 확장합니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6.3 2.6h3.4v1.5a1.1 1.1 0 1 0 2.2 0V2.6h1.5v3.4h-1.5a1.1 1.1 0 1 0 0 2.2h1.5v3.4h-3.4v-1.5a1.1 1.1 0 1 0-2.2 0v1.5H3.9V10.2h1.5a1.1 1.1 0 1 0 0-2.2H3.9V4.6" transform="translate(-.4 .2)"/></svg></span><span class="cmr-lbl">플러그인</span></a>
              <a class="cmrail-item" data-nav="cron" onclick="cmNav('cron')" title="주기적으로 실행해야 하는 업무(워커)를 등록·관리합니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8.4" r="5"/><path d="M8 5.6V8.4l1.9 1.2"/></svg></span><span class="cmr-lbl">크론</span></a>
              <a class="cmrail-item" data-nav="delegate" onclick="cmNav('delegate')" title="목적을 달성하는 책임 에이전트를 봅니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="5.6" cy="5.4" r="2.1"/><path d="M2.4 12.8c0-1.9 1.5-3.2 3.2-3.2 1.1 0 2 .5 2.6 1.2"/><path d="M9.4 8.4h4M11.7 6.5l1.9 1.9-1.9 1.9"/></svg></span><span class="cmr-lbl">위임</span></a>
              <a class="cmrail-item" data-nav="team" onclick="cmNav('team')" title="teamlead와 더 깊게 대화하고 위임합니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="5.8" r="2"/><path d="M2.6 12.4c0-1.9 1.5-3.1 3.4-3.1s3.4 1.2 3.4 3.1"/><circle cx="11" cy="6.3" r="1.6"/><path d="M10.4 9.4c1.7 0 3 1 3 2.8"/></svg></span><span class="cmr-lbl">팀위임</span></a>
              <a class="cmrail-item" data-nav="work" onclick="cmNav('work')" title="현재 대시보드(작업 목록)를 봅니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M2.6 5.2c0-.6.5-1.1 1.1-1.1h2.1l1.1 1.3h4.4c.6 0 1.1.5 1.1 1.1v4.9c0 .6-.5 1.1-1.1 1.1H3.7c-.6 0-1.1-.5-1.1-1.1V5.2Z"/></svg></span><span class="cmr-lbl">작업</span></a>
              <a class="cmrail-item" data-nav="slack" onclick="cmNav('slack')" title="슬랙 👀 리액션 메시지를 한국어로 번역해 모아 봅니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8" r="5.4"/><path d="M2.6 8h10.8M8 2.6c-1.7 1.5-2.5 3.3-2.5 5.4s.8 3.9 2.5 5.4c1.7-1.5 2.5-3.3 2.5-5.4S9.7 4.1 8 2.6Z"/></svg></span><span class="cmr-lbl">번역</span></a>
              <a class="cmrail-item off" data-nav="tbd2" title="준비 중입니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 8.2h.01M8 8.2h.01M12.4 8.2h.01"/></svg></span><span class="cmr-lbl">미정</span></a>
              <a class="cmrail-item off" data-nav="tbd3" title="준비 중입니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 8.2h.01M8 8.2h.01M12.4 8.2h.01"/></svg></span><span class="cmr-lbl">미정</span></a>
            </nav>
            <!-- 메모장 'AI로 정리해서 복사' 잡. 세션 묶음 '위'에 선다 — 몇 분 걸리는 일을
                 맡겨 두고 딴 일을 하러 가는 자리라, 무엇이 돌고 있는지 늘 눈에 있어야 한다.
                 세션(goal)과는 다른 종류라 '세션' 소제목 아래로 들어가지 않는다.
                 비어 있으면 아무것도 그리지 않는다(평소 레일은 조용하게). -->
            <div class="cmrail-tidy" id="cmRailTidy"></div>
            <div class="cmrail-seclabel">세션</div>
            <div class="cmrail-sessions" id="cmRailSessions"><span class="cmrail-empty">불러오는 중…</span></div>
          </div>
          <!-- 챌린지 다이얼(카운팅 버튼) — 설정(컨디션 바) 바로 위. -->
          <div class="cmch" id="cmChallenge">
            <div class="cmch-dial">
              <svg viewBox="0 0 116 116" aria-hidden="true">
                <defs><linearGradient id="cmchG" x1="0" y1="0" x2="1" y2="1">
                  <stop offset="0" stop-color="#60a5fa"/><stop offset="1" stop-color="#2563eb"/></linearGradient></defs>
                <g class="rot"><circle class="cmch-track" cx="58" cy="58" r="53"/>
                  <circle class="cmch-prog" id="cmChProg" cx="58" cy="58" r="53"/></g>
                <g class="cmch-orbit"><circle class="cmch-orbit-dot" cx="58" cy="5" r="2.6"/></g>
              </svg>
              <div class="cmch-pulse"></div>
              <button class="cmch-btn" id="cmChBtn" onclick="cmChToggle()" title="챌린지 시작 (⌘S)"><span class="tri"></span><span class="cmch-cd" id="cmChCd"></span><span class="cmch-tom">🍅</span></button>
              <div class="cmch-burst" id="cmChBurst"></div>
            </div>
            <div class="cmch-label">챌린지 시작</div>
            <div class="cmch-modes" id="cmChModes">
              <button data-m="pomodoro" onclick="cmChSetMode('pomodoro',event)" title="25분 포모도로 — 25분 카운트다운">25분</button>
              <button data-m="sprint" onclick="cmChSetMode('sprint',event)" title="현재 루프 시간에 맞춰 카운트다운">루프</button>
              <button data-m="unlimited" onclick="cmChSetMode('unlimited',event)" title="트래커 — 오늘 총 활동 시간을 계속 적립">트래커</button>
            </div>
            <div class="cmch-timer" id="cmChTimer">0:00</div>
            <div class="cmch-sub">
              <button class="cmch-mute" id="cmChMute" onclick="cmChMuteToggle(event)" title="음소거 — 챌린지는 계속, 소리만 끕니다"></button>
              <span id="cmChSubLabel">챌린지 진행 중</span>
              <span class="cmch-apm" id="cmChApm" title="분당 활동량 (APM) — 지금 얼마나 세게 일하는지"><span class="dot" id="cmChApmDot"></span><b id="cmChApmVal">0</b><span class="u">APM</span></span>
            </div>
          </div>
          <!-- 업데이트: 소스가 이 빌드보다 새로울 때만 나타남 (/api/update/check, 주기 조회).
               설정 메뉴 밖 — 포모도로 다이얼 바로 아래 레일에 직접 노출. 다이얼은 absolute 도킹이라
               rail의 .cmupd 클래스가 도킹 위치를 버튼 높이만큼 올려 겹침을 피한다.
               누르면 build-app.sh가 재빌드→종료→교체→재실행까지 수행 (/api/update/run). -->
          <button class="cmcond-update cmrail-update" id="cmCondUpdate" onclick="cmCondUpdate(event)" style="display:none">⬆️  업데이트 — 새 빌드 적용</button>
          <div class="cmcond-menu" id="cmCondMenu" style="display:none">
            <div class="cmcond-row"><span class="lbl">BGM 음악</span>
              <button class="cmcond-tog" id="cmCondBgmTog" onclick="cmCondToggleBgm(event)">—</button></div>
            <div class="cmcond-row"><span class="lbl">음소거</span>
              <button class="cmcond-tog" id="cmCondMuteTog" onclick="cmChMuteToggle(event)">—</button></div>
            <div class="cmcond-now" id="cmCondNow">컨디션 상태를 불러오는 중…</div>
            <button class="cmcond-full" onclick="cmCondFull(event)"><span class="cmcond-ico"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><path d="M4 2.6v10.8M8 2.6v10.8M12 2.6v10.8"/><path d="M2.5 5.5h3M6.5 10h3M10.5 7h3"/></svg></span>시스템관리</button>
            <!-- '플러그인 관리' 메뉴 항목은 제거 — 플러그인 페이지가 레일 메인 네비(플러그인)로 승격됐다. -->
            <button class="cmcond-full cmcond-equip" onclick="cmOpenEquip(event)" style="margin-top:4px"><span class="cmcond-ico"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2 3.2 3.8v3.6c0 3 2 5.2 4.8 6.4 2.8-1.2 4.8-3.4 4.8-6.4V3.8z"/></svg></span>장비<span class="cmcond-lv" id="cmCondEquipLv">—</span></button>
            <button class="cmcond-full" onclick="cmCondSettings(event)" style="margin-top:4px"><span class="cmcond-ico"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M8 1.9 13.3 5v6L8 14.1 2.7 11V5z"/><circle cx="8" cy="8" r="2.1"/></svg></span>설정</button>
            <div class="cmcond-paths" id="cmCondPaths" style="display:none"></div>
          </div>
          <div class="cmcond-bar" id="cmCondBar" onclick="cmCondToggle(event)">
            <button class="cmcond-hp" id="cmCondHp" onclick="cmChMuteToggle(event)" title="음소거 — 곡은 계속, 소리만 끕니다">
              <svg viewBox="0 0 30 30" aria-hidden="true">
                <path class="cup" d="M6.5 17.5v-3.2a8.5 8.5 0 0 1 17 0v3.2"/>
                <rect class="cup" x="4.6" y="16.2" width="4.2" height="6.4" rx="2.1"/>
                <rect class="cup" x="21.2" y="16.2" width="4.2" height="6.4" rx="2.1"/>
                <g class="eq"><rect x="12.1" y="15.2" width="1.8" height="5.4" rx="0.9"/><rect x="14.6" y="13.6" width="1.8" height="7" rx="0.9"/><rect x="17.1" y="15.2" width="1.8" height="5.4" rx="0.9"/></g>
              </svg>
            </button>
            <div class="cmcond-meta"><div class="cmcond-track" id="cmCondTrack">컨디션</div>
              <div class="cmcond-sub" id="cmCondSubL">대기 중</div></div>
            <span class="cmcond-chev">⌄</span>
          </div>
        </aside>
        <!-- 세션 행의 "⋯" 메뉴 (body 레벨 고정 팝업). 보관=완료 처리 후 레일에서 제거. -->
        <div class="cmrail-menu" id="cmRailMenu">
          <button id="cmRailMenuPin" onclick="cmRailPin()" title="이 목표를 레일 맨 위 고정됨 섹션에 고정합니다 — 완료·종료돼도 남아 있고 앱을 재시작해도 유지됩니다">📌  고정</button>
          <button onclick="cmRailArchive()" title="이 목표를 완료 처리하고 보관합니다 — 세션 목록에서 사라집니다">🗄  보관 (완료 처리)</button>
          <button class="danger" id="cmRailMenuKill" onclick="cmRailKillActive()" style="display:none" title="실행 중인 터미널 세션을 종료합니다">✕  세션 종료</button>
        </div>
        <script>
        (function(){
          // Which goal page we are on, if any (so the rail can highlight the active session).
          var CMRAIL_SEQ = (function(){ try{ var m=/[?&]n=(\d+)/.exec(location.search); return m?parseInt(m[1],10):null; }catch(e){ return null; } })();
          // The subtask folder this page is scoped to (?t=/?task=), if any — so the matching
          // "보는 중" task row highlights, and a goal row only highlights on the goal's own page.
          var CMRAIL_TASK = (function(){ try{ var m=/[?&](?:t|task)=([^&]*)/.exec(location.search); return m?decodeURIComponent(m[1]):null; }catch(e){ return null; } })();
          function esc(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }

          // ===== Zen start: on the app session's FIRST dashboard load ('/'), hide the whole
          // right-hand board (body.cm-zen — CSS lives in DashboardContent) so launch shows only
          // this rail's challenge dial. A board full of in-progress work makes starting feel
          // heavy; a clean slate makes it easy. Revealed the moment a challenge actually runs
          // (cmChRender below) or via the dashboard's 둘러보기 escape. This must read cmChArmed
          // BEFORE cmChMaybeAutoStart stamps it, so in-session navigations and reloads never
          // re-hide the board — only a genuine app launch does.
          // cmrail-force-open rides along: the native window is at just the rail's width during
          // zen (AppWindow), which is inside the <=720px responsive breakpoint that would
          // otherwise auto-collapse the rail — the one thing zen exists to show.
          try{ if(location.pathname==='/' && !sessionStorage.getItem('cmChArmed')) document.body.classList.add('cm-zen','cmrail-force-open'); }catch(e){}
          // A stop on another rail page (goal 세부 페이지 등) lands back here with ?zen=1 —
          // enter zen straight from the load so the stopped session's page never reappears,
          // then strip the param so a later reload of a revealed board doesn't re-hide it.
          try{ if(location.pathname==='/' && /[?&]zen=1/.test(location.search)){
            document.body.classList.add('cm-zen','cmrail-force-open');
            try{ webkit.messageHandlers.cmzen.postMessage('narrow'); }catch(e){}
            try{ history.replaceState(null,'','/'); }catch(e){}
          } }catch(e){}
          window.cmZenReveal=function(){ var b=document.body; if(!b.classList.contains('cm-zen')) return;
            b.classList.remove('cm-zen','cmrail-force-open');
            // zen 은 단계를 0으로 눌러두므로, 나오면서 사용자가 고른 단계로 되돌린다.
            if(window.cmRailSync) cmRailSync();
            // Tell the native window to grow back from its zen-narrow frame (no-op in a browser
            // or when the window was never narrowed — AppWindow ignores it unless zen is active).
            try{ webkit.messageHandlers.cmzen.postMessage('reveal'); }catch(e){} };
          // Stopping the 음원/챌린지 folds the board away again — 메모리를 걷어내는 효과: a board
          // full of half-done work makes the next start feel heavy, so ending a session returns
          // the window to the clean start palette. Entered only on a genuine running→stopped
          // TRANSITION (cmChRender below), and only while this page is actually the visible
          // surface (a detached/covered webview must not fold the window out from under the
          // BGM page). On the dashboard the board hides in place; on any OTHER rail page
          // (goal 세부 페이지 등) the page itself is the leftover memory, so fold the window and
          // leave for the zen dashboard — keeping the detail page would defeat the clean slate.
          // Idle page loads without a transition (navigation) keep the board.
          window.cmZenEnter=function(){ var b=document.body;
            if(document.hidden || b.classList.contains('cm-zen')) return;
            if(location.pathname!=='/'){
              try{ webkit.messageHandlers.cmzen.postMessage('narrow'); }catch(e){}
              location.href='/?zen=1';
              return; }
            b.classList.add('cm-zen','cmrail-force-open');
            if(window.cmRailSync) cmRailSync();     // zen = 레일 전용 화면 → 접힘/메모 단계 해제
            try{ webkit.messageHandlers.cmzen.postMessage('narrow'); }catch(e){} };
          var cmZenWasRun=false;   // last MAIN-PATH render's running state, for the stop transition

          // ===== 사이드바 토글: 3단계 (2026-07-31 재정의) =====
          //   1 메모장만 (문서형)          — 레일도 보드도 없다. 기본값.
          //   2 메모 + AI 컴포저           — 레일이 올라오고, 본문은 메모 위 / 컴포저·큐 아래.
          //   3 작업 + 대화 분할           — 레일 + 왼쪽·가운데 작업 보드 / 오른쪽 대화 패널.
          //   0 레일 접힘 (본문 전체폭)     — 메모장이 없는 페이지(컨디션·장비·크론 등) 전용 잔여 단계.
          // 왜 0 이 남아 있나: 메모장이 없는 페이지에서 1·2 로 들어가면 빈 화면이 된다. 그런
          // 페이지에서는 ⊞ 가 예전처럼 "레일 보임(3) ↔ 레일 접힘(0)" 두 상태만 오간다.
          // 같은 ⊞ 글리프를 계속 누르면 순환하고, ⌥+클릭은 역방향, Esc 는 1단계에서 3단계로
          // 빠져나온다. 선택한 단계는 localStorage(cmStage)에 남고, 좁은 창이 강제한 메모장
          // 모드는 '일시' 상태여서 저장값을 덮지 않는다 — 창을 넓히면 원래 단계로 돌아온다.
          // 툴팁은 "다음에 누르면 뭐가 되는지"로 말한다.
          var CMRAIL_TIPS={0:'사이드바 접기',1:'메모장만 보기 (Esc로 복귀)',2:'메모 + AI 컴포저',3:'작업 + 대화 분할'};
          var cmRailStageWant=1;      // 사용자가 고른 단계(영속)
          var cmRailStageNow=-1;      // 화면에 적용된 단계
          var cmRailForcedMemo=false; // 좁은 창이 강제한 메모장 모드인가
          function cmRailHasMemo(){ return !!document.querySelector('[data-cmmemo]'); }
          function cmRailHasBoard(){ return !!document.querySelector('[data-cmboard]'); }
          // 이 페이지가 지원하는 단계 목록(순환 순서). 대시보드만 3단계 전부를 갖는다.
          function cmRailStages(){
            if(!cmRailHasMemo()) return [3,0];
            return cmRailHasBoard() ? [1,2,3] : [1,2];
          }
          // 저장된 단계가 이 페이지에 없으면 '전부 보이는' 쪽으로 떨어뜨린다 — 빈 화면 방지.
          function cmRailFit(st){
            var l=cmRailStages();
            if(l.indexOf(st)>=0) return st;
            return l.indexOf(3)>=0 ? 3 : l[l.length-1];
          }
          function cmRailPaint(st){
            var b=document.body;
            b.classList.toggle('cmrail-collapsed', st===0 || st===1);
            b.classList.toggle('cmmemo-only', st===1);
            b.classList.toggle('cmboard-off', st===1 || st===2);   // 작업 보드를 걷어낸다
            b.classList.toggle('cmchat-full', st===2);             // 대화 패널이 본문 전체폭
            b.classList.toggle('cmchat-side', st===3);             // 대화 패널이 오른쪽 분할
            var l=cmRailStages(), i=l.indexOf(st), next=l[(i<0?0:i+1)%l.length];
            var tgs=document.querySelectorAll('[data-cmrail-tg]');
            // 단축키를 툴팁에 같이 적어 둔다 — 이 버튼이 키보드로도 된다는 걸 알 곳이 여기뿐이다.
            for(var t=0;t<tgs.length;t++) tgs[t].title=CMRAIL_TIPS[next]+' · ⌃⌘N';
            var dots=document.querySelectorAll('[data-cmrail-dots]');
            for(var j=0;j<dots.length;j++){
              dots[j].classList.toggle('on', l.length===3);
              var ds=dots[j].children;
              for(var k=0;k<ds.length;k++) ds[k].classList.toggle('at', k===st-1);
            }
            var was=cmRailStageNow;
            cmRailStageNow=st;
            // 네이티브 창을 단계에 맞춘다: 메모장만 보기(1)로 들어가면 포스트잇 크기(최소 가로 +
            // 유저가 메모장에서 마지막으로 고른 세로)로 접고, 나가면 접기 직전 크기로 되돌린다.
            // 첫 페인트(was<0)와 좁은 창이 강제한 메모장(cmRailForcedMemo — 이미 유저가 창을
            // 줄여 놓은 상태다)은 건드리지 않는다. 브라우저에서는 핸들러가 없어 조용히 무시된다.
            var moved = (was>=0 && was!==st && !cmRailForcedMemo && !cmRailZen() && (st===1 || was===1));
            if(moved){
              // 나갈 때는 가려는 단계를 같이 보낸다 — 3단계(작업+대화 분할)는 더 넓은 창이 필요하고,
              // 유저가 손으로 좁혀 둔 창 그대로 나가면 레이아웃이 우겨넣어져 깨지기 때문이다.
              try{ webkit.messageHandlers.cmzen.postMessage(st===1 ? 'memo' : ('memoExit:'+st)); }catch(e){}
            }
            // 3단계는 보드와 대화를 좌우로 나눠 놓기 때문에 화면 전체를 쓴다. 단계 전환이 아니어도
            // (부팅·새로고침·2→3 복귀 포함) 네이티브에 창을 화면 전체로 펴 달라고 한다. 이미 그
            // 크기면 네이티브가 조용히 무시한다.
            else if(st===3 && !cmRailForcedMemo && !cmRailZen()){
              try{ webkit.messageHandlers.cmzen.postMessage('memoExit:3'); }catch(e){}
            }
          }
          // zen(레일 폭 창)은 레일만 보여주는 화면이라 접기·메모장 단계 자체가 의미가 없다.
          function cmRailZen(){ return document.body.classList.contains('cm-zen'); }
          function cmRailSync(){
            if(cmRailZen()){ if(cmRailStageNow!==3) cmRailPaint(3); return; }
            var st=(cmRailForcedMemo && cmRailHasMemo()) ? 1 : cmRailFit(cmRailStageWant);
            if(st!==cmRailStageNow) cmRailPaint(st);
          }
          // zen 진입/이탈은 이 상태 머신 밖에서 body 클래스를 바꾸므로(cmZenEnter/cmZenReveal)
          // 그쪽에서 이 함수를 불러 단계를 다시 맞춘다.
          window.cmRailSync=cmRailSync;
          window.cmRailStage=function(st, persist){
            cmRailForcedMemo=false;
            cmRailStageWant=cmRailFit(st);
            if(persist!==false){ try{ localStorage.setItem('cmStage', String(cmRailStageWant)); }catch(e){} }
            cmRailSync();
          };
          window.cmRailToggle=function(ev){
            var l=cmRailStages(), i=l.indexOf(cmRailStageNow);
            if(i<0) i=0;
            var n = l[(ev && ev.altKey) ? (i+l.length-1)%l.length : (i+1)%l.length];
            cmRailStage(n);
            if(n===1 && window.CMMemo) try{ CMMemo.focus(); }catch(e){}
          };
          // Esc: 메모장만 보기에서 한 번에 작업 화면으로. 메모 textarea 안에서도 동작해야 하므로
          // (그 상태에선 거기 포커스가 있다) 캡처 단계에서 받는다.
          document.addEventListener('keydown', function(e){
            if(e.key==='Escape' && document.body.classList.contains('cmmemo-only')){
              e.preventDefault(); cmRailStage(3); }
          }, true);
          // ⌃⌘N: ⊞ 버튼과 같은 단계 순환 — 마우스를 쓰지 않기 위한 경로. 앱에서는 네이티브
          // 단축키 모니터(AppDelegate.handleShortcut)가 먼저 삼켜 여기까지 오지 않고, 이 핸들러는
          // 브라우저로 대시보드를 열었을 때를 받는다. 한글 입력원에서 e.key 는 'ㅜ' 가 되므로
          // 물리 키(e.code)로 본다.
          document.addEventListener('keydown', function(e){
            if(e.metaKey && e.ctrlKey && !e.shiftKey && (e.code==='KeyN' || e.key==='n' || e.key==='ㅜ')){
              e.preventDefault(); cmRailToggle();
            }
          }, true);
          // 창을 최소한으로 줄이면(≤360px = 포스트잇 크기) 메모장만 남는다 — 메모장이 있는
          // 페이지에서만. 영속 단계는 그대로라 창을 넓히면 원래 보던 화면으로 복귀한다.
          (function(){
            try{
              var mq=window.matchMedia('(max-width:360px)');
              function onNarrow(){
                var want = mq.matches && cmRailHasMemo() && !cmRailZen();
                if(want===cmRailForcedMemo) return;
                cmRailForcedMemo=want; cmRailSync();
              }
              if(mq.addEventListener) mq.addEventListener('change', onNarrow); else mq.addListener(onNarrow);
              // 안전망: 임계값을 오갈 때 change 가 오지 않는 환경(webview 리사이즈 에뮬레이션 등)이
              // 있어 창 드래그에도 직접 건다. 값이 그대로면 onNarrow 는 바로 빠져나온다.
              window.addEventListener('resize', onNarrow);
              window.cmRailNarrowCheck=onNarrow;
              onNarrow();
            }catch(e){}
          })();
          // 초기 단계: 새 키(cmStage). 구 키(cmRailStage, 0=전부/1=접힘/2=메모장만)는 의미가
          // 뒤집혔으므로 값으로 매핑해 옮긴다 — 옛 '메모장만'만 새 1단계로 살리고 나머지는 3.
          try{
            var s0=localStorage.getItem('cmStage');
            if(s0!==null){ cmRailStageWant=Math.max(0, Math.min(parseInt(s0,10)||0, 3)); }
            else {
              var old=localStorage.getItem('cmRailStage');
              // 처음 여는 사람은 메모장만(1). 쓰던 사람은 옛 단계의 뜻을 그대로 옮긴다.
              cmRailStageWant = (old===null) ? 1 : (old==='2' ? 1 : 3);
              try{ localStorage.setItem('cmStage', String(cmRailStageWant)); }catch(e2){}
            }
          }catch(e){}
          // ?stage=N — 다른 페이지에서 "대화로" 같은 이동이 목적지 단계를 함께 지정한다.
          try{
            var qs=parseInt(new URLSearchParams(location.search).get('stage')||'',10);
            if(qs>=0 && qs<=3) cmRailStageWant=qs;
          }catch(e){}
          cmRailSync();
          // 메모장은 DOM 이 준비된 뒤에야 조회되므로(레일이 <main> 보다 먼저 온다) 로드 후 한 번
          // 더 맞춘다 — 3단계 존재 여부·인디케이터·좁은 창 강제가 이때 확정된다.
          function cmRailStageBoot(){ if(window.cmRailNarrowCheck) cmRailNarrowCheck(); cmRailSync(); cmRailPaint(cmRailStageNow); }
          if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', cmRailStageBoot); else cmRailStageBoot();

          // 목표 만들기 (AI추가) = 대화 단계(2단계)로 들어가는 것. 2026-07-31 통합 이후 대화는
          // 별도 페이지가 아니라 대시보드가 품는 오른쪽 패널이라, 보드가 있는 페이지에서는 그냥
          // 단계를 바꾸고(이동 없음), 다른 페이지에서는 대시보드로 가며 목적지 단계를 넘긴다.
          window.cmComposeAi=function(){
            if(cmRailHasBoard()){ cmRailStage(2); if(window.cmNavReflect) cmNavReflect(); return; }
            location.href='/?stage=2';
          };
          // Honor a legacy ?compose= hint (old bookmarks/links): 'ai' now redirects to the
          // goal-add page; anything else focuses the dashboard's quick-add bar as before.
          (function(){ try{ var c=new URLSearchParams(location.search).get('compose'); if(!c) return;
            function go(){ if(c==='ai'){ location.replace('/goal-add'); }
              else { var inp=document.getElementById('goalText'); if(inp){ inp.scrollIntoView({block:'center'}); inp.focus(); } } }
            if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',function(){ setTimeout(go,60); }); else setTimeout(go,60);
          }catch(e){} })();

          // ===== Challenge dial (start/stop + mute), driven by the shared state module =====
          // Optimistic on click (instant feel), then confirmed by the /api/session/state poll so
          // this dial stays in sync with ⌘S/⌘M, the menu, and the BGM player.
          var cmChRun=false, cmChMuted=false, cmChSecs=0;
          var cmChWall=0;                               // wall-clock secs since start (포모도로 기준시계)
          var cmChToday=0;                              // today's TOTAL active seconds (무제한 mode readout)
          var cmChCountdown=null, cmChCdTimer=null;     // 5→1 pre-start countdown (null = not counting)
          // Optimistic start/stop latch: the state the user just asked for, held until the
          // server's poll confirms it (or the deadline passes). Without this, a poll that was
          // already in flight — or lands before the start/stop commits server-side — reports the
          // OLD state and cmChRender's zen edge folds/unfolds the window against the click:
          // expand→re-narrow→expand flapping with a black board for seconds (app.log
          // 14:22:50.763 expand / 14:22:50.776 re-narrow, 13ms apart).
          var cmChPendWant=null, cmChPendUntil=0;       // null = no pending action
          var cmChBooted=false;                         // becomes true after the first state settles
          var cmChAutoDone=false;                       // launch auto-start attempted (once per page load)
          // Drop the boot guard (which suppressed the hero↔dock glide) once the real running state is
          // known, so a page that loaded mid-session never animates in — only genuine clicks glide.
          function cmChBoot(){ if(cmChBooted) return; cmChBooted=true;
            var rail=document.getElementById('cmRail');
            if(rail) requestAnimationFrame(function(){ rail.classList.remove('cmboot'); }); }
          // Timer mode chosen before start: 'pomodoro' (25분, default) · 'sprint' · 'unlimited'.
          var cmChMode=(function(){ try{ return localStorage.getItem('cmChMode')||'pomodoro'; }catch(e){ return 'pomodoro'; } })();
          var cmChSprintStart=0, cmChSprintTarget=0;   // current sprint window (epoch secs), from state poll
          var CMCH_LEADIN=5, CMCH_DAILY_GOAL=2;
          // 포모도로 목표시간(분): 25분 칩을 다시 누르면 이 프리셋을 순환한다(25→45→50→25).
          // 45·50분은 "초집중" 롱세션용. 선택값은 localStorage 에 남고 시작 시 서버로 전달돼
          // 완주 판정(벽시계)도 이 시간으로 이뤄진다.
          var CMCH_POMO_PRESETS=[25,45,50];
          var cmChPomoMin=(function(){ try{ var v=parseInt(localStorage.getItem('cmChPomoMin'),10);
            return CMCH_POMO_PRESETS.indexOf(v)>=0?v:25; }catch(e){ return 25; } })();
          function cmChPomoSecs(){ return cmChPomoMin*60; }
          // Reflect the current mode selection AND the pomodoro chip's live duration: the 25분
          // chip shows its chosen minutes and, while selected, a ↻ hint that re-tapping cycles it.
          function cmChSyncModeBtns(el){
            var mb=el.querySelectorAll('#cmChModes button');
            for(var i=0;i<mb.length;i++){
              var m=mb[i].getAttribute('data-m'), on=(m===cmChMode);
              mb[i].classList.toggle('on', on);
              if(m==='pomodoro'){
                mb[i].textContent = cmChPomoMin+'분'+(on?' ↻':'');
                mb[i].title = '포모도로 '+cmChPomoMin+'분 — 다시 누르면 시간 변경 ('+CMCH_POMO_PRESETS.join('·')+'분)';
              }
            }
          }
          // Pomodoro completion reward state (B tap-to-harvest + C daily N/2 tracker).
          // The SERVER owns completion now: the app's wall-clock heartbeat judges 25:00
          // (webview-independent), the daily count is the durable PomodoroStats history
          // (d.pomoToday), and the reward orb mirrors d.reward — a rail reload can no
          // longer lose a completion. Only the post-harvest "한 판 더?" chooser stays
          // local: it's a pure UI moment with no state worth persisting.
          var cmChReward=false;      // mirror of server d.reward: 완료 → 수확 오브(탭 대기)
          var cmChDone=false;        // 수확 후 "한 판 더?" 재선택 히어로 (local-only)
          var cmChDailyN=0;          // today's completion count (server d.pomoToday)
          function cmChFmt(s){ s=Math.max(0,s|0); var h=(s/3600)|0, m=((s%3600)/60)|0, ss=s%60;
            return (h>0?h+':':'')+((m<10&&h>0)?'0'+m:m)+':'+(ss<10?'0'+ss:ss); }
          // Digital-clock duration for 트래커/루프 readouts: always zero-padded HH:MM:SS
          // ("03:41:00"), a calmer, more modern look than the old "3h 41m" unit-mix. Hours keep
          // accumulating past 24 for a clean clock feel (오늘 총 rarely exceeds a day anyway).
          function cmChDur(s){ s=Math.max(0,s|0); var h=(s/3600)|0, m=((s%3600)/60)|0, ss=s%60;
            var p=function(n){ return n<10?'0'+n:''+n; };
            return p(h)+':'+p(m)+':'+p(ss); }
          function cmChModeLabel(){
            if(cmChMode==='sprint') return cmChSprintTarget>0?'루프':'루프(설정 없음)';
            if(cmChMode==='unlimited') return '트래커 <span class="cmch-day">· 오늘 총</span>';
            // 오늘 N/2 rides on the idle/running label too, so the daily tracker is
            // always visible — not only during the fleeting reward/done moments.
            // The count is its own nowrap chunk (see .cmch-day) so a wrap breaks cleanly
            // after "포모도로 25분" instead of cramming "오늘 3/2" against the line above.
            return '포모도로 25분 <span class="cmch-day">· 오늘 '+cmChDailyN+'/'+CMCH_DAILY_GOAL+'</span>';
          }
          // The dial's live readout while running: {text, frac} where frac∈[0,1] is how full the ring is.
          //  - pomodoro: count DOWN from 25:00; ring fills as the 25분이 소진됨.
          //  - sprint:   count DOWN to the current sprint target (wall clock); ring = 루프 진행률.
          //  - unlimited: count UP; ring is a per-minute sweep (the "alive" feel).
          function cmChView(){
            // 무제한: show TODAY's total active time (counts up), not just this session.
            if(cmChMode==='unlimited') return { text: cmChDur(cmChToday), frac: (cmChToday%60)/60 };
            if(cmChMode==='sprint'){
              if(cmChSprintTarget>0){
                var now=Math.floor(Date.now()/1000);
                var total=Math.max(1, cmChSprintTarget-cmChSprintStart);
                var rem=Math.max(0, cmChSprintTarget-now);
                return { text: cmChDur(rem), frac: Math.min(1, Math.max(0,(now-cmChSprintStart)/total)) };
              }
              return { text: cmChDur(cmChToday), frac: (cmChToday%60)/60 };   // no sprint → behave like 무제한
            }
            // pomodoro (default): WALL-CLOCK countdown — 포모도로는 벽시계 25분이라 유휴/앱
            // 필터로 멈추는 활동초(cmChSecs)가 아니라 d.wall을 기준으로 그린다.
            var pr=Math.max(0, cmChPomoSecs()-cmChWall);
            return { text: cmChFmt(pr), frac: Math.min(1, cmChWall/cmChPomoSecs()) };
          }
          function cmChClearCd(){ if(cmChCdTimer){ clearInterval(cmChCdTimer); cmChCdTimer=null; } cmChCountdown=null; }
          // Full-takeover render for the 5→1 pre-start countdown (amber center digit, ring filling).
          function cmChRenderCountdown(el){
            el.classList.add('counting'); el.classList.remove('run');
            // Countdown plays in the HERO position, so keep the rail out of its running (docked) layout.
            var rail=document.getElementById('cmRail'); if(rail) rail.classList.remove('chrun');
            var btn=document.getElementById('cmChBtn'); if(btn){ btn.classList.remove('on'); btn.title='즉시 시작 — 카운트다운 건너뛰기'; }
            var cd=document.getElementById('cmChCd'); if(cd) cd.textContent=cmChCountdown;
            document.getElementById('cmChTimer').textContent='곧 시작';
            // 누르면 즉시 시작(카운트다운 스킵); 취소는 서브 라벨의 링크로 분리.
            var subEl=document.getElementById('cmChSubLabel');
            if(subEl) subEl.innerHTML='누르면 즉시 시작 · <span class="cmch-cdcancel" onclick="cmChCancelCd(event)">취소</span>';
            var apmCd=document.getElementById('cmChApm'); if(apmCd) apmCd.style.display='none';
            // Keep the mode selector reflecting the current choice — the user may switch mid-countdown.
            cmChSyncModeBtns(el);
            var frac=(CMCH_LEADIN-cmChCountdown)/CMCH_LEADIN;   // ring fills across the 5s lead-in
            document.getElementById('cmChProg').style.strokeDashoffset=(333*(1-frac)).toFixed(1);
          }
          // Pomodoro-done reward: a beating amber 🍅 orb in the hero, waiting for a tap to harvest.
          // 수확 단계 = 인간 메모리 클리어: the finished session's board is leftover working memory,
          // so the moment the orb appears the right-hand content folds away (zen) — the user faces
          // only the harvest, then re-engages deliberately. Edge-triggered off cmZenWasRun (true only
          // when THIS page just watched the session run), so a fresh page load mid-reward or a
          // deliberate 둘러보기 reveal is never re-folded.
          function cmChRenderReward(el){
            el.classList.add('reward'); el.classList.remove('run','counting','done');
            if(cmZenWasRun){ cmZenWasRun=false; cmZenEnter(); }   // fold once, on the live 완주 transition
            var rail=document.getElementById('cmRail'); if(rail) rail.classList.remove('chrun');
            var btn=document.getElementById('cmChBtn'); if(btn){ btn.classList.remove('on'); btn.title='탭해서 수확'; }
            var lab=el.querySelector('.cmch-label'); if(lab) lab.textContent='수확하기';
            var sub=document.getElementById('cmChSubLabel'); if(sub) sub.innerHTML='🍅 탭해서 수확 <span class="cmch-day">· 오늘 '+cmChDailyN+'/'+CMCH_DAILY_GOAL+'</span>';
            var apmR=document.getElementById('cmChApm'); if(apmR) apmR.style.display='none';
            document.getElementById('cmChProg').style.strokeDashoffset='0';   // full ring = 완료
          }
          function cmChRender(){
            var el=document.getElementById('cmChallenge'); if(!el) return;
            // The launch countdown owns the dial for its full 5s — even though the app auto-starts the
            // session server-side (state polls report running), keep showing the counter until it fires.
            if(cmChCountdown!=null){ cmChRenderCountdown(el); return; }
            if(cmChReward){ cmChRenderReward(el); return; }   // pomodoro done → tap-to-harvest orb
            el.classList.remove('counting','reward');
            var btn=document.getElementById('cmChBtn'), mute=document.getElementById('cmChMute');
            // Rail layout: running docks the dial (bottom) + reveals the work surface; idle floats the
            // hero dial up top. The CSS transition on .cmch does the slide+shrink (proposal A).
            var rail=document.getElementById('cmRail'); if(rail) rail.classList.toggle('chrun', cmChRun);
            // Zen ties the board to the session: running reveals it (not during the countdown —
            // that branch returns above), and the running→stopped transition folds it away again.
            // Transition-only, so idle page loads (navigating back while stopped) keep the board.
            if(cmChRun) cmZenReveal();
            else if(cmZenWasRun) cmZenEnter();
            cmZenWasRun=cmChRun;
            el.classList.toggle('run', cmChRun);
            // Post-harvest "한 판 더?" chooser hero (mode selector doubles as the re-selection).
            var isDone=(cmChDone && !cmChRun); el.classList.toggle('done', isDone);
            btn.classList.toggle('on', cmChRun);
            btn.title = cmChRun ? '챌린지 중단 (⌘S)' : '챌린지 시작 (⌘S)';
            var lab=el.querySelector('.cmch-label'); if(lab) lab.textContent = isDone ? '한 판 더?' : '챌린지 시작';
            // Reflect the selected mode (and pomodoro duration) on the pre-start selector.
            cmChSyncModeBtns(el);
            var view = cmChRun ? cmChView() : { text: cmChFmt(0), frac: 0 };
            document.getElementById('cmChTimer').textContent = view.text;
            var subEl=document.getElementById('cmChSubLabel');
            if(subEl) subEl.innerHTML = isDone
              ? ('<span class="cmch-day">🍅 오늘 '+cmChDailyN+'/'+CMCH_DAILY_GOAL+'</span>'+(cmChDailyN>=CMCH_DAILY_GOAL?' · 목표 달성 🎉':' · 다음 세션 고르기'))
              : cmChModeLabel();
            // APM readout: only meaningful while truly running (hidden during the post-harvest chooser).
            var apmEl=document.getElementById('cmChApm');
            if(apmEl) apmEl.style.display = (cmChRun && !isDone) ? 'inline-flex' : 'none';
            mute.classList.toggle('muted', cmChMuted);
            mute.title = cmChMuted ? '음소거 해제 — 소리를 다시 켭니다' : '음소거 — 챌린지는 계속, 소리만 끕니다';
            document.getElementById('cmChProg').style.strokeDashoffset = (333*(1-view.frac)).toFixed(1);
            cmCondRenderHp();   // headphone strip mirrors the same mute state
          }
          // Pre-start mode selection (persisted). Ignored while running — mode is locked once started.
          window.cmChSetMode=function(m,ev){ if(ev) ev.stopPropagation();
            if(cmChRun && cmChCountdown==null) return;   // truly running → mode is locked
            // 이미 선택된 25분 칩을 (자동 리드인이 아닐 때) 다시 누르면 "시작"이 아니라
            // 목표시간을 순환한다(25→45→50). "한 판 더?" 상태도 동일 — 숫자를 바꾸려는 재탭이
            // 세션을 시작해 버리지 않도록, 시작은 다이얼 또는 다른 모드 칩으로만 한다.
            var reTapPomo = (m==='pomodoro' && cmChMode==='pomodoro' && cmChCountdown==null);
            cmChMode=m; try{ localStorage.setItem('cmChMode',m); }catch(e){}
            if(reTapPomo){
              var pi=CMCH_POMO_PRESETS.indexOf(cmChPomoMin); pi=(pi+1)%CMCH_POMO_PRESETS.length;
              cmChPomoMin=CMCH_POMO_PRESETS[pi];
              try{ localStorage.setItem('cmChPomoMin',cmChPomoMin); }catch(e){}
              cmChRender(); return;   // 순환만 — 시작하지 않는다
            }
            // 카운트다운은 유저가 가만히 있을 때만 적용한다. 그동안 모드 버튼을 누르는 건 곧 "지금 이 모드로
            // 시작"이라는 명시적 의사 → 카운트다운을 걷어내고 즉시 시작(인터랙티브 반응감).
            if(cmChCountdown!=null){ cmChFire(); return; }   // during launch countdown → start now
            if(cmChDone){ cmChFire(); return; }              // "한 판 더?" 재선택 → 그 모드로 바로 시작
            cmChRender(); };
          // 앱 시작 시 자동 시작(포모도로 기본)을 알리는 5초 리드인. 그동안 유저는 모드를 바꾸거나,
          // 다이얼을 눌러 기다림 없이 즉시 시작하거나, 서브 라벨의 '취소'로 자동 시작을 걷어낼 수 있다.
          // 수동 시작(다이얼 클릭)은 이 리드인을 쓰지 않고 즉시 시작 — 카운트다운은 오직 자동 시작에서만
          // 나온다. (수동은 시원시원하게.)
          function cmChBeginCountdown(){
            cmChCountdown=CMCH_LEADIN; cmChRender();
            cmChCdTimer=setInterval(function(){
              cmChCountdown--;
              if(cmChCountdown<=0){ cmChClearCd(); cmChFire(); } else cmChRender();
            },1000);
          }
          function cmChFire(){   // actually start the challenge (immediately, or after the auto lead-in)
            cmChClearCd(); cmChReward=false; cmChDone=false;
            cmChPendWant=true; cmChPendUntil=Date.now()+8000;   // hold 'running' against stale polls
            cmChRun=true; cmChSecs=0; cmChWall=0; cmChRender();
            // Carry the chosen mode so the server selects that mode's BGM playlist
            // (each mode opens on its own pinned first track).
            fetch('/api/session/control',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({action:'start', mode:cmChMode, pomodoroSecs:cmChPomoSecs()})})
              .then(function(){ cmChSync(); }).catch(function(){});   // committed → confirm now, don't wait for the 2s poll
          }
          // Confetti burst from the dial center (harvest reward).
          function cmChBurst(){
            var box=document.getElementById('cmChBurst'); if(!box) return;
            var cols=['#f59e0b','#22c55e','#3b82f6','#ef4444','#e879f9','#fbbf24'];
            for(var i=0;i<18;i++){ (function(k){
              var s=document.createElement('span'); s.className='cmch-pt'; s.style.background=cols[k%cols.length];
              box.appendChild(s);
              var a=Math.random()*6.2832, d=34+Math.random()*54;
              requestAnimationFrame(function(){ requestAnimationFrame(function(){
                s.style.transform='translate('+(Math.cos(a)*d).toFixed(0)+'px,'+(Math.sin(a)*d).toFixed(0)+'px) scale(.3)';
                s.style.opacity='0'; }); });
              setTimeout(function(){ s.remove(); }, 900);
            })(i); }
          }
          // 25:00 completion is judged SERVER-SIDE (heartbeat wall clock): the server stops
          // the session, records history + EXP, plays the chime, and raises d.reward — this
          // page only renders that state, so nothing is missed when the rail isn't open.
          // Tap the orb → claim the reward: burst + ack the server (count already recorded
          // at completion), then the re-selection hero.
          window.cmChHarvest=function(){
            cmChBurst();
            // 수확 ack: clears the server's pending orb and plays the sparkle chime
            // natively — distinct from the calmer completion chime at 25:00.
            fetch('/api/session/control',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({action:'harvest'})}).catch(function(){});
            cmChReward=false; cmChDone=true; cmChRender();
          };
          // App-launch auto-start: once per webview session, if nothing is running, arm the 5s countdown
          // that auto-starts the pomodoro default. sessionStorage keeps it to a genuine app launch —
          // navigating between pages (which reloads this rail) must NOT re-trigger it.
          function cmChMaybeAutoStart(){
            if(cmChAutoDone) return; cmChAutoDone=true;
            try{ if(sessionStorage.getItem('cmChArmed')) return; sessionStorage.setItem('cmChArmed','1'); }catch(e){}
            if(cmChCountdown!=null) return;   // already counting
            // The app auto-starts the session on launch (AppDelegate.startWorking), so this 5s countdown is
            // the VISIBLE announcement before the work UI appears — shown even though the session is already
            // technically running. It fires immediately (no network wait) so the counter never looks stuck.
            cmChMode='pomodoro';              // launch default selection
            cmChBeginCountdown();
          }
          window.cmChToggle=function(){
            if(cmChReward){ cmChHarvest(); return; }   // tapping the 🍅 orb harvests the reward
            // Counting → 즉시 시작(카운트다운 스킵). 취소는 서브 라벨의 '취소' 링크(cmChCancelCd)로 분리.
            // This must be checked BEFORE cmChRun: the app auto-starts the session at launch, so the
            // first state poll flips cmChRun to true while the 5s countdown is still on screen — the
            // run-branch would treat the click as a stop instead of the intended "start now".
            if(cmChCountdown!=null){ cmChFire(); return; }
            if(cmChRun){   // running → stop immediately (no lead-in)
              cmChPendWant=false; cmChPendUntil=Date.now()+8000;   // hold 'stopped' against stale polls
              cmChRun=false; cmChDone=false; cmChRender();
              fetch('/api/session/control',{method:'POST',headers:{'Content-Type':'application/json'},
                body:JSON.stringify({action:'stop'})})
                .then(function(){ cmChSync(); }).catch(function(){});
              return;
            }
            cmChFire();   // 수동 시작은 항상 즉시 (카운트다운 없음) — 어느 모드든 시원시원하게
          };
          // 카운트다운 취소: 자동 시작을 걷어내고, 서버가 이미 auto-start한 세션도 함께 멈춘다.
          window.cmChCancelCd=function(ev){ if(ev){ ev.stopPropagation(); ev.preventDefault(); }
            if(cmChCountdown==null) return;
            cmChClearCd();
            cmChPendWant=false; cmChPendUntil=Date.now()+8000;   // the auto-started session is stopping
            cmChRun=false; cmChRender();
            fetch('/api/session/control',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({action:'stop'})})
              .then(function(){ cmChSync(); }).catch(function(){});
          };
          window.cmChMuteToggle=function(ev){ if(ev) ev.stopPropagation();
            cmChMuted=!cmChMuted; cmChRender();
            fetch('/api/session/mute',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({muted:cmChMuted})}).catch(function(){});
          };
          function cmChSync(){
            fetch('/api/session/state').then(function(r){return r.json();}).then(function(d){
              if(!d) return;
              // Pending start/stop: a poll reporting the opposite of what the user just clicked is
              // stale (in flight, or the control POST hasn't committed yet). Accepting it would
              // flip cmChRun back and cmChRender's zen edge would fold/unfold the window against
              // the click. Hold the clicked state until the server echoes it; if it never does
              // within the deadline, believe the server (the action genuinely failed).
              var run=!!d.working, stale=false;
              if(cmChPendWant!==null){
                if(run===cmChPendWant || Date.now()>cmChPendUntil) cmChPendWant=null;
                else { run=cmChPendWant; stale=true; }
              }
              cmChRun=run; cmChMuted=!!d.muted;
              // A stale payload also carries the OLD session's clock/mode — don't let it
              // overwrite the fresh optimistic ones (the local 1s tick owns them meanwhile).
              if(!stale && typeof d.seconds==='number') cmChSecs=d.seconds;
              if(!stale && typeof d.wall==='number') cmChWall=d.wall;
              if(typeof d.today==='number') cmChToday=d.today;
              if(typeof d.pomoToday==='number') cmChDailyN=d.pomoToday;
              if(typeof d.sprintStart==='number') cmChSprintStart=d.sprintStart;
              if(typeof d.sprintTarget==='number') cmChSprintTarget=d.sprintTarget;
              // While truly running, the dial mirrors the SERVER's session mode — a rail
              // loaded mid-session must not render the localStorage mode of a past choice.
              if(!stale && cmChRun && cmChCountdown==null && typeof d.mode==='string' && d.mode) cmChMode=d.mode;
              // Server-owned reward orb (survives rail reloads). cmChDone is the local
              // post-harvest chooser: while it's up, a lagging poll (harvest ack still
              // propagating) must not re-raise the orb.
              if(!cmChDone) cmChReward=!!d.reward;
              // The reward/choose phase owns the UI locally — don't let a lagging poll flip it back to
              // the running/docked layout while the stop is still propagating.
              if(cmChReward||cmChDone) cmChRun=false;
              cmChRender();
              cmChBoot();             // first real state applied → arm the glide for subsequent clicks
              // BGM master switch state for the condition popup toggle.
              var tog=document.getElementById('cmCondBgmTog');
              if(tog){ var on=!!d.bgm; tog.classList.toggle('on',on); tog.textContent=on?'켜짐':'꺼짐'; }
            }).catch(function(){});
          }
          cmChRender();            // reflect the saved mode on the selector before the first poll resolves
          cmChMaybeAutoStart();    // fresh app launch → show the 5s countdown immediately (no network wait)
          cmChSync(); setInterval(cmChSync, 2000);
          setTimeout(cmChBoot, 1500);   // fallback: arm the glide even if the first poll never lands
          // Local 1s tick keeps the countdown smooth between polls; the 2s poll re-anchors
          // cmChWall to the server's authoritative value (and delivers the completion flip).
          setInterval(function(){ if(cmChRun){ cmChSecs++; cmChWall++; cmChToday++; cmChRender(); } }, 1000);

          // ===== Live APM readout (D-style dot + number) in the running dial's sub-line =====
          // Replaces the old dashboard header 스포츠/타임 gauge. Polls the same tiny /live.json
          // (apm·norm) and animates the number with the same damped spring (K=500,D=26) so it
          // keeps the tachometer bounce; the dot's color/size tracks intensity (green→amber→red).
          // Living in the rail means APM now shows on every page, not just the dashboard.
          var cmApmT=0, cmApm=0, cmApmV=0, cmNmT=0, cmNm=0, cmNmV=0, cmApmLast=0;
          var CMAPM_K=500, CMAPM_D=26;
          function cmApmZone(x){ var h=x<0.6?145-(145-42)*(x/0.6):42-42*Math.min(1,(x-0.6)/0.4);
            return 'hsl('+Math.max(0,h).toFixed(0)+',72%,55%)'; }
          function cmApmPoll(){
            if(!cmChRun){ cmApmT=0; cmNmT=0; return; }   // not running → ease the readout down to 0
            fetch('/live.json',{cache:'no-store'}).then(function(r){return r.json();}).then(function(l){
              if(!l) return; cmApmT=Math.max(0,l.apm||0); cmNmT=Math.max(0,Math.min(1,l.norm||0));
            }).catch(function(){});
          }
          setInterval(cmApmPoll, 250);
          function cmApmFrame(t){
            var dt=cmApmLast?Math.min(0.05,(t-cmApmLast)/1000):0.016; cmApmLast=t;
            var rem=dt, H=0.006;
            while(rem>1e-4){ var h=Math.min(H,rem); rem-=h;
              cmApmV += ((cmApmT-cmApm)*CMAPM_K - cmApmV*CMAPM_D)*h; cmApm += cmApmV*h;
              cmNmV  += ((cmNmT-cmNm)*CMAPM_K   - cmNmV*CMAPM_D)*h;   cmNm  += cmNmV*h; }
            var dot=document.getElementById('cmChApmDot'), val=document.getElementById('cmChApmVal');
            if(dot){ var nm=Math.min(1,Math.max(0,cmNm)), c=cmApmZone(nm),
              pulse=0.5+0.5*Math.sin(t/1000*(2+nm*10)), sc=1+nm*0.7*pulse;
              dot.style.background=c; dot.style.transform='scale('+sc.toFixed(3)+')';
              dot.style.boxShadow='0 0 '+(3+8*nm*pulse).toFixed(1)+'px '+c; }
            if(val){ val.textContent=Math.round(cmApm); val.style.color=cmNm>0.85?'#ff5a6e':'#c8cfdb'; }
            requestAnimationFrame(cmApmFrame);
          }
          requestAnimationFrame(cmApmFrame);

          // ===== Condition control popup (bottom of rail, always present) =====
          // The headphone icon is a mute shortcut (same state as the dial's green dot); the menu
          // duplicates it as a 음소거 row so users who don't discover the shortcut still reach it.
          // Rest: BGM on/off, current track/condition, and "시스템관리" which switches the app window.
          window.cmCondToggle=function(ev){ if(ev) ev.stopPropagation();
            var bar=document.getElementById('cmCondBar'), m=document.getElementById('cmCondMenu');
            if(!bar||!m) return; var open=(m.style.display==='none');
            m.style.display=open?'block':'none'; bar.classList.toggle('open',open);
            var rail=document.getElementById('cmRail'); if(rail) rail.classList.toggle('cmcond-open',open);
            if(open){ cmEquipLvRefresh(); }
          };
          // ⬆️ 업데이트 버튼: 적용할 새 빌드가 있으면 포모도로 다이얼 아래(설정 메뉴 밖)에
          // 나타난다. 원격 업데이트 서버는 없고, 같은 머신 안에서 판정한다 — 백그라운드
          // 자동 빌더(Scripts/autobuild-watch.sh)가 완성해 둔 빌드가 있으면 그것이 기준이고
          // (누르면 교체만, 2초), 빌더가 없으면 소스 mtime 비교로 폴백한다(누르면 그때 빌드).
          // 메뉴를 열지 않아도 보이도록 주기 폴링한다.
          function cmUpdateCheck(){
            fetch('/api/update/check',{cache:'no-store'}).then(function(r){ return r.json(); }).then(function(u){
              var b=document.getElementById('cmCondUpdate'); if(!b) return;
              if(!b.disabled){
                // 준비 중: 빌더가 지금 컴파일하고 있다. 누를 수는 없지만 숨기지도 않는다 —
                // "저장했는데 아무 반응 없음"이 40초 이어지는 것보다 진행 중이라고 말해주는
                // 편이 신뢰가 간다. 완성되면 같은 자리에서 누를 수 있는 버튼으로 바뀐다.
                if(u&&u.preparing){
                  b.style.display='block'; b.classList.add('cmupd-prep');
                  b.textContent='🛠  새 빌드 준비 중…';
                }else{
                  b.classList.remove('cmupd-prep');
                  // behind = 준비된 빌드 이후에도 소스를 더 저장했다. 적용은 되지만 방금
                  // 저장한 것까지는 아니라는 뜻이라, 문구로 구분해 준다.
                  b.textContent=(u&&u.behind)?'⬆️  업데이트 — 준비된 빌드 적용(이후 수정 제외)'
                                             :'⬆️  업데이트 — 새 빌드 적용';
                  b.style.display=(u&&u.available)?'block':'none';
                }
              }
              // Docked dial is an absolute overlay: flag the rail so CSS lifts it above the button.
              var rail=document.getElementById('cmRail');
              if(rail) rail.classList.toggle('cmupd', b.style.display!=='none');
            }).catch(function(){});
          }
          // Fast lead-in polling (2s for the first 30s): a pending build must surface
          // while the 5s launch countdown is still on screen, not a minute later —
          // the user updates first, works after. Steady state stays at 60s.
          cmUpdateCheck(); setInterval(cmUpdateCheck, 60000);
          var cmUpdFast=setInterval(cmUpdateCheck, 2000);
          setTimeout(function(){ clearInterval(cmUpdFast); }, 30000);
          window.cmCondUpdate=function(ev){ if(ev) ev.stopPropagation();
            var b=document.getElementById('cmCondUpdate'); if(!b||b.disabled) return;
            // 준비 중에는 적용할 빌드가 아직 없다 — 누르면 옛 동작(그 자리에서 컴파일)으로
            // 되돌아가 유저를 기다리게 하므로 무시한다. 곧 눌 수 있는 상태로 바뀐다.
            if(b.classList.contains('cmupd-prep')) return;
            // Pressing 업데이트 during the launch countdown means "update first, work
            // after" — cancel the auto-start (and the server's auto-started session) so
            // a phantom seconds-long session doesn't run while the app rebuilds.
            if(cmChCountdown!=null) cmChCancelCd();
            b.disabled=true; b.textContent='⏳  업데이트 중…';
            // 실패는 유저에게 에러로 보여주지 않는다: 현재 버전이 그대로 살아있으므로 잃은 것이
            // 없고, 상세는 update.log·액션로그에 남는다. 중립 문구를 잠깐 보여준 뒤 버튼을
            // 숨긴다 — 서버가 소스 변경을 감지하면 버튼이 다시 나타난다.
            function standDown(){
              b.textContent='현재 버전 유지 — 새 빌드가 준비되면 다시 알려드려요';
              setTimeout(function(){
                b.disabled=false; b.textContent='⬆️  업데이트 — 새 빌드 적용'; b.style.display='none';
                var rail=document.getElementById('cmRail'); if(rail) rail.classList.remove('cmupd');
              }, 5000); }
            fetch('/api/update/run',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})
              .then(function(r){ return r.json(); }).then(function(j){
                if(!(j&&j.ok)){ standDown(); return; }
                // Success ends with THIS app being replaced (page dies with it), so the only
                // outcome to detect here is failure: the server reports deferred (unavailable
                // for this tree state) when the build exits non-zero while the app lives on.
                var t=setInterval(function(){
                  fetch('/api/update/check',{cache:'no-store'}).then(function(r){ return r.json(); })
                    .then(function(u){ if(u&&u.deferred){ clearInterval(t); standDown(); } })
                    .catch(function(){});   // unreachable = quitting/relaunching — let the page die
                },5000);
              }).catch(function(){ standDown(); });
          };
          // 장비 row: refresh the overall-level chip whenever the menu opens, so the
          // settings entry always shows the current 평균 레벨 (same /api/equipment the
          // equipment page reads — one source of truth).
          function cmEquipLvRefresh(){
            fetch('/api/equipment').then(function(r){ return r.json(); }).then(function(j){
              var el=document.getElementById('cmCondEquipLv');
              if(el && j && j.overall) el.textContent='Lv.'+j.overall;
            }).catch(function(){});
          }
          window.cmOpenEquip=function(ev){ if(ev) ev.stopPropagation(); location.href='/equipment'; };
          // ⚙️ 설정: expandable storage-paths section. Shows WHERE the app reads/writes —
          // data dir, BGM 음원 folder, Claude 세션 store — so a dev/prod path mix-up is
          // visible at a glance instead of looking like "data disappeared". Row click
          // copies the path; ↗ reveals the folder in Finder (fixed-target POST).
          window.cmCondSettings=function(ev){ if(ev) ev.stopPropagation();
            var box=document.getElementById('cmCondPaths'); if(!box) return;
            if(box.style.display!=='none'){ box.style.display='none'; return; }
            box.style.display='block';
            box.innerHTML='<div class="tip">경로 불러오는 중…</div>';
            Promise.all([
              fetch('/api/settings/paths',{cache:'no-store'}).then(function(r){ return r.json(); }),
              fetch('/api/settings/timezone',{cache:'no-store'}).then(function(r){ return r.json(); }).catch(function(){ return null; }),
              fetch('/api/settings/debug-buttons',{cache:'no-store'}).then(function(r){ return r.json(); }).catch(function(){ return null; }),
              fetch('/api/settings/gateway',{cache:'no-store'}).then(function(r){ return r.json(); }).catch(function(){ return null; })
            ]).then(function(rs){
              var p=rs[0], tz=rs[1], dbg=rs[2], gw=rs[3];
              if(!p){ box.innerHTML='<div class="tip">경로를 불러오지 못했습니다</div>'; return; }
              var store = p.shared ? '단일 저장소 (dev·prod 공용)' : '격리 저장소 (CM_DATA_DIR)';
              function row(key,label,path){
                var has = !!(path&&path.length);
                return '<div class="cmcond-path" onclick="cmCondCopyPath(event,this)" data-p="'+esc(path||'')+'" title="'+(has?('클릭하여 복사: '+esc(path)):'미설정')+'">'
                  + '<span class="k">'+label+'</span>'
                  + (has ? '<span class="v">&lrm;'+esc(path)+'</span>' : '<span class="v unset">미설정</span>')
                  + (has ? '<button class="go" onclick="cmCondReveal(event,\''+key+'\')" title="Finder에서 열기">↗</button>' : '')
                  + '</div>';
              }
              // 표시 타임존 선택 — 저장·기준은 항상 UTC(epoch), 화면 표기만 이 tz를 따른다.
              // 선택 즉시 서버에 저장하고 새로고침해 페이지 전체(레일·본문)가 새 tz로 그려진다.
              function tzRow(){
                if(!tz) return '';
                var cur=tz.tz||'system';
                var opts=[['system','시스템 (맥 설정)'],['Asia/Seoul','KST (UTC+9)'],['UTC','UTC (+0)']];
                var seen=false;
                var o=opts.map(function(x){ if(x[0]===cur) seen=true;
                  return '<option value="'+x[0]+'"'+(x[0]===cur?' selected':'')+'>'+x[1]+'</option>'; }).join('');
                if(!seen) o+='<option value="'+esc(cur)+'" selected>'+esc(cur)+'</option>';
                return '<div class="cmcond-path" style="cursor:default" onclick="event.stopPropagation()" title="시간 표기 기준 (저장은 항상 UTC) — 현재 '+esc(tz.label||'')+'">'
                  + '<span class="k">타임존</span>'
                  + '<select class="cmcond-tzsel" onchange="cmCondSetTz(event,this.value)">'+o+'</select>'
                  + '</div>';
              }
              // 전역 디버그 버튼 노출 토글 — off면 각 페이지의 디버그성 버튼이 아예 안 그려진다.
              function dbgRow(){
                if(!dbg) return '';
                return '<div class="cmcond-path" style="cursor:default" onclick="event.stopPropagation()" title="켜면 각 페이지에 디버그 버튼이 표시됩니다">'
                  + '<span class="k">디버그 버튼</span>'
                  + '<label style="margin-left:auto;display:flex;align-items:center;gap:6px;cursor:pointer">'
                  + '<input type="checkbox" '+(dbg.on?'checked':'')+' onchange="cmCondSetDbg(event,this.checked)">'
                  + '<span>'+(dbg.on?'켜짐':'꺼짐')+'</span></label>'
                  + '</div>';
              }
              // Claude CLI 연결 — 앱이 spawn하는 claude 는 터미널 쉘 함수를 타지 않으므로,
              // 게이트웨이를 쓰는 환경에서는 여기서 선언해야 한다. '자동'이면 아무것도 주입하지
              // 않고 CLI 자신의 로컬 로그인(OAuth)을 쓴다. 토큰은 앱이 저장하지 않는다 —
              // 키체인 항목 이름만 두고 매번 키체인에서 읽는다.
              // 상태 행 — 연결이 확인되면 녹색 점, 아니면 상태 칩 + 원인 문구 + 그 원인에 맞는
              // 행동 버튼(로그인 열기 / 네트워크 진단 / 다시 확인). state 는 마지막 확인 결과이며
              // 패널을 열 때 자동으로 한 번 확인한다.
              function gwState(){
                var st = gw.state||'';
                var label = {ok:'연결됨', needLogin:'로그인 필요', badAuth:'인증 거부',
                  unreachable:'네트워크 연결 안 됨', noKey:'키체인 항목 없음',
                  noCLI:'claude 없음', error:'오류'}[st] || '확인 안 됨';
                var dot = '<span class="cmcond-gwdot'+(st==='ok'?' ok':(st?' bad':''))+'"></span>';
                var h = '<div class="cmcond-path" style="cursor:default" onclick="event.stopPropagation()">'
                  + '<span class="k">상태</span>'
                  + '<span class="v" id="cmCondGwTestOut">'+dot+esc(label)+'</span>'
                  + '<button class="go" style="margin-left:auto" onclick="cmCondGwTest(event)">다시 확인</button></div>';
                if(st && st!=='ok'){
                  var msg = (gw.detail||'') + (gw.hint?(' · '+gw.hint):'');
                  h += '<div class="tip" style="margin:2px 0 0">'+esc(msg)+'</div>';
                  var acts = '';
                  if(st==='needLogin'||st==='badAuth'||st==='noCLI')
                    acts += '<button class="go" onclick="cmCondGwLogin(event)">로그인 열기</button>';
                  if(st==='unreachable')
                    acts += '<button class="go" onclick="cmCondFull(event)">네트워크 진단 열기</button>';
                  if(acts) h += '<div class="cmcond-path" style="cursor:default;gap:6px;justify-content:flex-end"'
                    + ' onclick="event.stopPropagation()">'+acts+'</div>';
                }
                return h;
              }
              function gwRows(){
                if(!gw) return '';
                var isGw = gw.mode==='gateway';
                var h = '<div class="hd" style="margin-top:8px">Claude 연결<span class="store">'+esc(gw.status||'')+'</span></div>'
                  + '<div class="cmcond-path" style="cursor:default" onclick="event.stopPropagation()" title="앱이 실행하는 claude CLI의 인증 방법">'
                  + '<span class="k">연결</span>'
                  + '<select class="cmcond-tzsel" onchange="cmCondSetGw(event,{mode:this.value})">'
                  + '<option value="auto"'+(isGw?'':' selected')+'>자동 (로컬 로그인)</option>'
                  + '<option value="gateway"'+(isGw?' selected':'')+'>게이트웨이</option>'
                  + '</select></div>';
                if(!isGw) return h + gwState();
                h += '<div class="cmcond-path" style="cursor:default" onclick="event.stopPropagation()" title="추론 게이트웨이 엔드포인트 (https)">'
                  + '<span class="k">게이트웨이 URL</span>'
                  + '<input class="cmcond-tzsel" style="flex:1;min-width:0" value="'+esc(gw.baseURL||'')+'"'
                  + ' placeholder="https://…" onchange="cmCondSetGw(event,{baseURL:this.value})"></div>'
                  + '<div class="cmcond-path" style="cursor:default" onclick="event.stopPropagation()" title="토큰을 어떤 헤더로 보낼지">'
                  + '<span class="k">인증 방식</span>'
                  + '<select class="cmcond-tzsel" onchange="cmCondSetGw(event,{scheme:this.value})">'
                  + '<option value="bearer"'+(gw.scheme==='apiKey'?'':' selected')+'>bearer</option>'
                  + '<option value="apiKey"'+(gw.scheme==='apiKey'?' selected':'')+'>x-api-key</option>'
                  + '</select></div>'
                  + '<div class="cmcond-path" style="cursor:default" onclick="event.stopPropagation()" title="토큰이 담긴 키체인 항목 이름 — 계정: '+esc(gw.keyAccountEffective||'')+'">'
                  + '<span class="k">키체인 항목</span>'
                  + '<input class="cmcond-tzsel" style="flex:1;min-width:0" value="'+esc(gw.keyService||'')+'"'
                  + ' placeholder="claude-code-token" onchange="cmCondSetGw(event,{keyService:this.value})"></div>'
                  + gwState();
                return h;
              }
              box.innerHTML =
                '<div class="hd">저장 폴더<span class="store'+(p.shared?'':' warn')+'">'+store+(p.dev?' · DEV 빌드':'')+'</span></div>'
                + row('data','데이터',p.data)
                + row('bgm','BGM 음원',p.bgm)
                + row('claude','Claude 세션',p.claude)
                + tzRow()
                + dbgRow()
                + gwRows()
                + '<div class="tip">행 클릭=경로 복사 · ↗=Finder에서 열기 · 타임존=시간 표기 기준 · 연결=자동이면 로컬 Claude 로그인 사용</div>';
              // 앱 실행 후 처음 패널을 열면 상태가 없다 — 이때 한 번만 자동으로 확인한다.
              // (이후에는 서버가 기억한 결과를 그대로 보여주고, '다시 확인'이 갱신한다.)
              if(gw && !gw.state && !window.cmCondGwBusy) cmCondGwTest(null);
            }).catch(function(){ box.innerHTML='<div class="tip">경로를 불러오지 못했습니다</div>'; });
          };
          window.cmCondSetDbg=function(ev,on){ if(ev) ev.stopPropagation();
            fetch('/api/settings/debug-buttons',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({on:on})}).then(function(){ cmCondSettings(); cmCondSettings(); }).catch(function(){});
          };
          // Claude 연결 설정 부분 갱신 — 보낸 필드만 반영된다. 저장 후 패널을 다시 그려
          // (닫고 열기) 상태 칩과 표시/숨김 행이 새 상태를 반영하게 한다.
          window.cmCondSetGw=function(ev,patch){ if(ev) ev.stopPropagation();
            fetch('/api/settings/gateway',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify(patch)}).then(function(){ cmCondSettings(); cmCondSettings(); })
              .catch(function(){});
          };
          // 연결 확인 — 실제 claude 왕복까지 하므로 수 초 걸린다. 결과는 서버가 기억하므로
          // 끝나면 패널만 다시 그리면 상태 점·원인·행동 버튼이 새 결과로 갱신된다.
          window.cmCondGwTest=function(ev){ if(ev) ev.stopPropagation();
            if(window.cmCondGwBusy) return; window.cmCondGwBusy=1;
            var out=document.getElementById('cmCondGwTestOut'); if(out) out.textContent='확인 중…';
            fetch('/api/settings/gateway/test',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})
              .then(function(r){ return r.json(); }).then(function(){
                window.cmCondGwBusy=0; cmCondSettings(); cmCondSettings();
              }).catch(function(){ window.cmCondGwBusy=0;
                if(out) out.textContent='확인하지 못했습니다'; });
          };
          // 로그인 요청 — CLI의 OAuth 로그인은 대화형이라 앱 안에서 대신할 수 없다.
          // 터미널에서 claude /login 을 띄우고, 유저가 끝낸 뒤 다시 확인하면 된다.
          window.cmCondGwLogin=function(ev){ if(ev) ev.stopPropagation();
            var out=document.getElementById('cmCondGwTestOut');
            fetch('/api/settings/gateway/login',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})
              .then(function(r){ return r.json(); }).then(function(j){
                if(out) out.textContent=(j&&j.detail)?j.detail:'터미널을 확인하세요';
              }).catch(function(){ if(out) out.textContent='터미널에서 claude /login 을 실행하세요'; });
          };
          window.cmCondSetTz=function(ev,tzv){ if(ev) ev.stopPropagation();
            fetch('/api/settings/timezone',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({tz:tzv})})
            .then(function(){ location.reload(); })   // 페이지 전체를 새 표시 tz로 다시 그린다
            .catch(function(){});
          };
          window.cmCondCopyPath=function(ev,el){ if(ev) ev.stopPropagation();
            var p=el&&el.getAttribute('data-p'); if(!p) return;
            try{ navigator.clipboard.writeText(p); }catch(e){}
            var v=el.querySelector('.v'); if(v){ var t=v.innerHTML; v.innerHTML='복사됨 ✓'; v.style.direction='ltr';
              setTimeout(function(){ v.innerHTML=t; v.style.direction='rtl'; },900); }
          };
          window.cmCondReveal=function(ev,target){ if(ev) ev.stopPropagation();
            fetch('/api/settings/reveal',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({target:target})}).catch(function(){});
          };
          document.addEventListener('click',function(e){
            var m=document.getElementById('cmCondMenu'), bar=document.getElementById('cmCondBar');
            if(m&&m.style.display!=='none'&&bar&&!bar.contains(e.target)&&!m.contains(e.target)){
              m.style.display='none'; bar.classList.remove('open');
              var rail=document.getElementById('cmRail'); if(rail) rail.classList.remove('cmcond-open'); } });
          window.cmCondToggleBgm=function(ev){ if(ev) ev.stopPropagation();
            var on=document.getElementById('cmCondBgmTog').classList.contains('on');
            fetch('/api/bgm/control',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({action: on?'stop':'play'})}).then(cmCondRefresh).catch(function(){});
          };
          window.cmCondFull=function(ev){ if(ev) ev.stopPropagation();
            fetch('/api/window/mode',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({mode:'condition'})}).catch(function(){});
          };
          // (구 '플러그인 관리' 메뉴의 cmOpenPlugins는 제거 — 플러그인 페이지는 레일 네비로 연다.)
          // Headphone icon state: "audible" (playing && !muted) animates the EQ bars; muted grays
          // the icon and draws the strike. The sub-line composes the muted prefix here so a mute
          // toggle reflects instantly instead of waiting for the next /api/bgm/now poll.
          var cmCondPlaying=false, cmCondSubBase='대기 중';
          function cmCondRenderHp(){
            var bar=document.getElementById('cmCondBar'); if(!bar) return;
            bar.classList.toggle('hp-muted', cmChMuted);
            bar.classList.toggle('hp-live', cmCondPlaying && !cmChMuted);
            var hp=document.getElementById('cmCondHp');
            if(hp) hp.title = cmChMuted ? '음소거 해제 — 소리를 다시 켭니다' : '음소거 — 곡은 계속, 소리만 끕니다';
            var s=document.getElementById('cmCondSubL');
            if(s) s.textContent = (cmChMuted?'음소거됨 · ':'') + (cmCondSubBase||'대기 중');
            var tog=document.getElementById('cmCondMuteTog');
            if(tog){ tog.classList.toggle('on', cmChMuted); tog.textContent = cmChMuted?'켜짐':'꺼짐'; }
          }
          function cmCondRefresh(){
            fetch('/api/bgm/now').then(function(r){return r.json();}).then(function(n){
              if(!n) return;
              var t=document.getElementById('cmCondTrack'), now=document.getElementById('cmCondNow');
              var playing=!!n.on;
              if(t) t.textContent = (n.id>=0&&n.title)? n.title : '컨디션';
              cmCondPlaying=playing;
              cmCondSubBase = playing ? ((n.phase||'-')+(n.bpm>0?' · '+n.bpm+' BPM':' · 준비 중')) : '대기 중';
              if(now) now.textContent = playing ? ('전략 '+(n.profile||'-')+' · 컨디션 '+(n.phase||'-'))
                                                : '활동이 시작되면 곡이 잡힙니다';
              cmCondRenderHp();
            }).catch(function(){});
          }
          cmCondRefresh(); setInterval(cmCondRefresh, 3000);

          // Live background CLI sessions.
          function killSession(token, ev){ if(ev) ev.stopPropagation();
            fetch('/api/goal/cli/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:token})}).then(loadSessions).catch(loadSessions);
          }
          // ===== Per-session "⋯" overflow menu (보관 / 세션 종료) =====
          // One shared body-level popup carries the row's identity while open. 보관 marks the
          // goal done + archives it (server clears the 보는 중 marker and stops any live PTY),
          // so it drops out of all three rail sources — the session disappears.
          var cmRailMenuSeq=null, cmRailMenuTok='', cmRailMenuPinned=false;
          window.cmRailMenuOpen=function(seq, live, token, pinned, ev){ if(ev){ ev.stopPropagation(); ev.preventDefault(); }
            var menu=document.getElementById('cmRailMenu'); if(!menu) return;
            cmRailMenuSeq=seq; cmRailMenuTok=token||''; cmRailMenuPinned=!!pinned;
            var kb=document.getElementById('cmRailMenuKill'); if(kb) kb.style.display=live?'flex':'none';
            // 고정 버튼은 현재 상태에 따라 라벨을 바꾼다: 고정 안 됨 → "📌 고정", 고정됨 → "📌 고정 해제".
            var pb=document.getElementById('cmRailMenuPin');
            if(pb){ pb.textContent = cmRailMenuPinned ? '📌  고정 해제' : '📌  고정';
              pb.title = cmRailMenuPinned ? '이 목표를 고정됨 섹션에서 내립니다'
                : '이 목표를 레일 맨 위 고정됨 섹션에 고정합니다 — 완료·종료돼도 남아 있고 앱을 재시작해도 유지됩니다'; }
            var r=ev.currentTarget.getBoundingClientRect();
            menu.style.display='block';
            var mw=menu.offsetWidth||160, mh=menu.offsetHeight||90;
            var left=Math.min(r.right-mw, window.innerWidth-mw-8);
            var top=r.bottom+4; if(top+mh>window.innerHeight-8) top=r.top-mh-4;
            menu.style.left=Math.max(8,left)+'px'; menu.style.top=Math.max(8,top)+'px';
          };
          window.cmRailMenuClose=function(){ var m=document.getElementById('cmRailMenu');
            if(m) m.style.display='none'; cmRailMenuSeq=null; cmRailMenuTok=''; };
          document.addEventListener('click', function(e){ var m=document.getElementById('cmRailMenu');
            if(m && m.style.display==='block' && !m.contains(e.target)) cmRailMenuClose(); });
          window.cmRailArchive=function(){ var seq=cmRailMenuSeq; cmRailMenuClose(); if(seq==null) return;
            fetch('/api/goal/rail/archive',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({seq:seq})}).then(loadSessions).catch(loadSessions); };
          // 고정 토글: 현재 상태의 반대로 보내고(명시적 pin) 목록을 다시 그린다 — 고정된 목표는
          // 서버 union(Settings.pinnedGoalSeqs)에 항상 포함돼 고정됨 섹션에 남는다.
          window.cmRailPin=function(){ var seq=cmRailMenuSeq, want=!cmRailMenuPinned; cmRailMenuClose();
            if(seq==null) return;
            fetch('/api/cli/pin',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({seq:seq,pin:want})}).then(loadSessions).catch(loadSessions); };
          window.cmRailKillActive=function(){ var tok=cmRailMenuTok; cmRailMenuClose();
            if(tok) killSession(tok); };
          // Claude-Desktop status vocabulary. The dot's color/shape mirrors what the session
          // needs from the user, NOT just whether a terminal is open:
          //   확인 요청  (waiting+permission) -> blue solid     #5b8cff
          //   의사결정 요청 (waiting+decision)  -> amber solid    #e8a33d
          //   보는 중    (viewing)            -> purple pulsing  #a78bfa (the page I'm on now)
          //   진행 중    (in_progress)         -> gray pulsing   (blinking)
          //   완료       (done)               -> gray hollow ring
          // rank: lower = higher up the list (actionable items first). An actionable prompt
          // (확인/의사결정) still outranks everything — you need to answer it first.
          // IMPORTANT: 보는 중(viewing)은 정렬 순위를 바꾸지 않는다 — rank는 항상 실제 작업
          // 상태(진행/완료/중지)로 결정한다. 세션을 클릭해 그 페이지로 이동하면 viewing 이 켜지는데,
          // 그때 순위가 올라가면 방금 누른 항목이 목록 맨 위로 튀어 위치가 바뀐다. 그래서 viewing 은
          // 점 색/라벨(보라 보는 중)만 덧입히고 자리(rank)는 그대로 유지한다.
          function stateMeta(s){
            if(s.status==='waiting' && s.waitKind==='permission') return {color:'#5b8cff', label:'확인 요청', rank:0};
            if(s.status==='waiting') return {color:'#e8a33d', label:'의사결정 요청', rank:1};
            var m;
            if(s.status==='done') m={color:'#8b93a7', label:'완료', hollow:true, rank:3};
            else if(s.status==='stopped') m={color:'#8b93a7', label:'중지', rank:2};
            else m={color:'#8b93a7', label:'진행 중', pulse:true, rank:2};   // in_progress / running
            if(s.viewing){ m.color='#a78bfa'; m.label='보는 중'; m.pulse=true; m.hollow=false; }
            return m;
          }
          // 🔍 header button → GOAL search (찾기만). The goal-add PAGE in '검색' mode
          // (/goal-add?search=1): 번호/제목 즉시 조회 + AI검색(search:true 큐, findOnly) —
          // 목표를 만들지 않는다. Works from any page. Exposed on window (inline onclick).
          window.cmRailGoalSearch=function(){ location.href='/goal-add?search=1'; };
          // Build one session row element (dot + title/sub + "⋯" overflow menu).
          function cmRailRow(s){
            var m=s._m;
            // A goal row highlights only on the goal's OWN page — not when a subtask of it is
            // open (that page highlights the task row instead).
            var on=(s.seq===CMRAIL_SEQ && !CMRAIL_TASK);
            var row=document.createElement('div'); row.className='cmrail-sess'+(on?' on':'');
            // 세션을 다시 열면 그 목표에서 '마지막 본 탭'(CLI/GUI/DETAIL)으로 복원한다.
            // cm.lastTab.<seq> 는 각 탭 진입 시 goal-add·목표 페이지가 기록한다. 없으면 DETAIL.
            row.onclick=function(){
              var t=''; try{ t=localStorage.getItem('cm.lastTab.'+s.seq)||''; }catch(e){}
              if(t==='gui') location.href='/goal-add?goal='+s.seq+'&ui=gui';
              else if(t==='cli') location.href='/goal-add?goal='+s.seq+'&ui=cli';
              else location.href='/goal?n='+s.seq+'&cli=1';
            };
            var dotCls='dot'+(m.pulse?' pulse':'')+(m.hollow?' hollow':'');
            var style=m.hollow?('border-color:'+m.color):('background:'+m.color);
            row.innerHTML='<span class="'+dotCls+'" style="'+style+'"></span>'
              +'<div class="meta"><div class="ttl">'+esc(s.title||('goal-'+s.seq))+'</div>'
              +'<div class="sub">goal-'+s.seq+' · '+m.label+'</div></div>';
            // "⋯" overflow menu on every row (고정 / 보관 / 세션 종료). 고정 pins to the top
            // 고정됨 섹션; 보관 completes+archives; 세션 종료 only when a live terminal exists.
            var more=document.createElement('button'); more.className='more'; more.title='메뉴'; more.textContent='⋯';
            (function(sess){ more.onclick=function(e){ cmRailMenuOpen(sess.seq, !!sess.live, sess.token||'', !!sess.pinned, e); }; })(s);
            row.appendChild(more);
            return row;
          }
          // One "보는 중" TASK row: the task's own title over a "task-NN · 보는 중" sub-line,
          // clicking back into the subtask page. Always the purple 보는 중 dot (these rows exist
          // only because the task was recently viewed). No "⋯" menu — tasks aren't pinned/archived
          // from the rail.
          function cmRailTaskRow(t){
            var on=(t.seq===CMRAIL_SEQ && t.task===CMRAIL_TASK);
            var row=document.createElement('div'); row.className='cmrail-sess'+(on?' on':'');
            row.onclick=function(){ location.href='/goal?n='+t.seq+'&task='+encodeURIComponent(t.task)+'&cli=1'; };
            row.innerHTML='<span class="dot pulse" style="background:#a78bfa"></span>'
              +'<div class="meta"><div class="ttl">'+esc(t.title||t.task)+'</div>'
              +'<div class="sub">'+esc(t.label||'task')+' · 보는 중</div></div>';
            return row;
          }
          function cmRailSubhead(text){
            var h=document.createElement('div'); h.className='cmrail-subhd'; h.textContent=text; return h;
          }
          function loadSessions(){
            fetch('/api/cli/sessions').then(function(r){return r.json();}).then(function(d){
              var box=document.getElementById('cmRailSessions'); if(!box) return;
              var list=(d&&d.sessions)||[];
              var tasks=(d&&d.tasks)||[];   // 보는 중 task rows (newest-first, already ordered)
              if(!list.length && !tasks.length){ box.innerHTML='<span class="cmrail-empty">진행 중인 세션이 없습니다</span>'; return; }
              list.forEach(function(s){ s._m=stateMeta(s); });
              // 고정됨(pinned) vs 나머지. Actionable first (확인/의사결정 요청), then 진행 중,
              // then 완료; ties by goal number — the same ordering inside each group.
              function ord(a,b){ return a._m.rank-b._m.rank || (a.seq||0)-(b.seq||0); }
              var pinned=list.filter(function(s){ return s.pinned; }).sort(ord);
              var rest=list.filter(function(s){ return !s.pinned; }).sort(ord);
              box.innerHTML='';
              // 고정됨 섹션 — 고정된 항목이 하나라도 있을 때만 헤더를 보인다.
              if(pinned.length){
                box.appendChild(cmRailSubhead('고정됨'));
                pinned.forEach(function(s){ box.appendChild(cmRailRow(s)); });
              }
              // 세션 섹션 — 고정된 항목이 있을 때만 소제목을 붙여 두 그룹을 구분한다.
              // 보는 중 task 행이 먼저(최신순), 이어서 goal 세션 행. task 를 여러 개 열어 봤다면
              // 각각 자기 정보(제목·task-NN)로 순서대로 나온다.
              if(rest.length || tasks.length){
                if(pinned.length) box.appendChild(cmRailSubhead('세션'));
                tasks.forEach(function(t){ box.appendChild(cmRailTaskRow(t)); });
                rest.forEach(function(s){ box.appendChild(cmRailRow(s)); });
              }
            }).catch(function(){});
          }
          loadSessions(); setInterval(loadSessions, 3000);
        })();
        </script>

        <!-- ===== AI 정리 (메모장 우클릭 → 'AI로 정리해서 복사') =====
             메모장이 던진 잡 하나가 클로드 코드로 1~5분간 돌아간다. 그 시간을 사람이 화면
             앞에서 기다리게 하지 않는 것이 이 줄의 존재 이유다: 진행은 경과 시간으로 보이고,
             완료 통보는 클립보드가 대신한다(서버가 직접 NSPasteboard 에 넣는다 — 웹뷰
             포커스와 무관하게 확실하다). 그 사이 딴 일을 했더라도 줄을 눌러 다시 복사한다. -->
        <script>
        (function(){
          var _tj=[], _open='';
          function esc3(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }
          // 경과 시간 — 진행 중이면 '지금까지', 끝났으면 '걸린 시간'. 분:초로만 읽는다
          // (몇 분짜리 일이라 시간 단위는 필요 없고, 초가 오르는 게 곧 '살아 있다'는 신호다).
          function el(j){
            var end=(j.endedAt||0)>0 ? j.endedAt : Math.floor(Date.now()/1000);
            var s=Math.max(0, end-(j.startedAt||0));
            return ((s/60)|0)+':'+('0'+(s%60)).slice(-2);
          }
          function sub(j){
            if(j.status==='running') return 'AI 정리 중 · ' + j.chars + '자';
            if(j.status==='done')    return '완료 · 클립보드에 복사됨';
            return '실패 — ' + (j.error||'사유 없음');
          }
          // 하루가 지난 끝난 잡은 레일에서 내린다(결과 파일에는 남는다) — 레일은 '지금
          // 무슨 일이 도는가' 를 보는 자리지 기록 보관소가 아니다.
          function live(j){
            if(j.status==='running') return true;
            return (Math.floor(Date.now()/1000) - (j.endedAt||0)) < 86400;
          }
          function render(){
            var box=document.getElementById('cmRailTidy'); if(!box) return;
            var list=_tj.filter(live);
            if(!list.length){ box.innerHTML=''; return; }
            var h='<div class="cmrail-subhd">AI 정리</div>';
            list.forEach(function(j){
              var running=(j.status==='running');
              var color = j.status==='failed' ? '#8b93a7' : (running ? '#a78bfa' : '#8b93a7');
              var dot='<span class="dot'+(running?' pulse':(j.status==='done'?' hollow':''))+'" style="'
                      +(j.status==='done'?'border-color:':'background:')+color+'"></span>';
              h+='<div class="cmrail-sess" data-tid="'+esc3(j.id)+'" title="'
                +(running ? '클로드 코드가 다듬는 중입니다 — 끝나면 클립보드에 자동으로 들어갑니다'
                          : (j.status==='done' ? '눌러서 결과를 보고 다시 복사합니다' : esc3(j.error||'')))+'">'
                +dot+'<div class="meta"><div class="ttl">'+esc3(j.title||'메모 정리')+'</div>'
                +'<div class="sub">'+esc3(sub(j))+'</div></div>'
                +'<span class="el">'+el(j)+'</span></div>';
            });
            box.innerHTML=h;
            Array.prototype.slice.call(box.querySelectorAll('[data-tid]')).forEach(function(row){
              row.onclick=function(){ openResult(row.getAttribute('data-tid')); };
            });
          }
          // 목록만 다시 읽는다(3초). 경과 시간은 서버를 기다리지 않고 1초마다 우리가 올린다 —
          // 초가 멈춰 보이면 그 자체로 "죽었나?" 라는 의심이 된다.
          function load(){
            fetch('/api/memo/tidy',{cache:'no-store'}).then(function(r){ return r.json(); })
              .then(function(d){ _tj=(d&&d.jobs)||[]; render(); }).catch(function(){});
          }
          window.cmTidyPoke=function(){ load(); };
          function pop(){
            var p=document.getElementById('cmTidyPop');
            if(p) return p;
            p=document.createElement('div'); p.className='cmtidy-pop'; p.id='cmTidyPop';
            p.innerHTML='<div class="hd"><b id="cmTidyTtl"></b><span class="sp"></span>'
              +'<button id="cmTidyX">닫기</button></div><pre id="cmTidyBody"></pre>'
              +'<div class="ax"><span class="note" id="cmTidyNote"></span>'
              +'<button class="pri" id="cmTidyCopy">복사</button></div>';
            document.body.appendChild(p);
            p.querySelector('#cmTidyX').onclick=function(){ p.style.display='none'; _open=''; };
            p.querySelector('#cmTidyCopy').onclick=function(){
              if(!_open) return;
              var b=p.querySelector('#cmTidyCopy');
              // 클립보드에 넣는 일은 앱이 한다 — 웹뷰의 clipboard API 는 포커스에 따라
              // 조용히 실패한다. 성공을 눈으로 알려 주는 것까지가 이 버튼의 일이다.
              fetch('/api/memo/tidy/copy',{method:'POST',headers:{'Content-Type':'application/json'},
                                           body:JSON.stringify({id:_open})})
                .then(function(r){ return r.json(); })
                .then(function(j){ if(j&&j.ok){ b.textContent='복사됨'; setTimeout(function(){ b.textContent='복사'; },1400); } })
                .catch(function(){});
            };
            document.addEventListener('click', function(e){
              if(p.style.display==='flex' && !p.contains(e.target)
                 && !(e.target.closest && e.target.closest('#cmRailTidy'))){ p.style.display='none'; _open=''; }
            });
            return p;
          }
          function openResult(id){
            var j=_tj.filter(function(x){ return x.id===id; })[0];
            if(!j) return;
            var p=pop();
            p.querySelector('#cmTidyTtl').textContent=j.title||'메모 정리';
            p.querySelector('#cmTidyNote').textContent =
              j.status==='running' ? '아직 정리 중입니다 — 끝나면 클립보드에 자동으로 들어갑니다'
              : (j.status==='failed' ? '실패 — ' + (j.error||'') : j.outChars + '자 · ' + el(j) + ' 걸림');
            p.querySelector('#cmTidyCopy').style.display = (j.status==='done') ? '' : 'none';
            var body=p.querySelector('#cmTidyBody');
            body.textContent = j.status==='done' ? '불러오는 중…'
                             : (j.status==='running' ? '클로드 코드가 다듬는 중입니다.' : (j.error||'실패'));
            _open=id;
            // 레일 오른쪽에 붙인다 — 접힌 레일에서도 화면 안에 들어오도록 왼쪽 여백만 지킨다.
            // 폭은 보이기 전에는 0이므로 display 를 먼저 켜고 잰다.
            p.style.display='flex';
            var rail=document.getElementById('cmRail');
            var x=(rail && !document.body.classList.contains('cmrail-collapsed')
                   ? rail.getBoundingClientRect().right : 0)+10;
            p.style.left=Math.max(10, Math.min(x, window.innerWidth-(p.offsetWidth||520)-10))+'px';
            p.style.top=Math.max(10, Math.min(120, window.innerHeight-160))+'px';
            if(j.status==='done'){
              fetch('/api/memo/tidy?id='+encodeURIComponent(id),{cache:'no-store'})
                .then(function(r){ return r.json(); })
                .then(function(d){ if(_open===id) body.textContent=(d&&d.text)||'(비어 있음)'; })
                .catch(function(){ if(_open===id) body.textContent='(결과를 읽지 못했습니다)'; });
            }
          }
          load(); setInterval(load, 3000); setInterval(render, 1000);
        })();
        </script>

        <!-- ===== 스킬 목록 오버레이 (rail의 "스킬" 클릭 시 열림) — ~/.claude/skills 를 표시 ===== -->
        <style>
          /* Sit to the RIGHT of the rail so the left sidebar stays visible/usable;
             when the rail is collapsed, reclaim the full width. */
          .cmsk-overlay{ position:fixed; top:0; right:0; bottom:0; left:var(--cmrail-w); z-index:80;
            background:#0a0d12; display:flex; flex-direction:column; color:#c8cfdb;
            font:14px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif }
          body.cmrail-collapsed .cmsk-overlay{ left:0 }
          /* 스킬·에이전트 오버레이는 모두 레일이 소유하는 독립 fixed 오버레이다(대시보드 탭으로
             재부모화하지 않는다). 레일 '스킬'/'위임' 메뉴가 각각 cmSkillsOpen/cmAgentsOpen으로 연다. */
          /* 40px top clears the native titlebar toggle overlapping this web content (see
             .cmag-head) so the top-right action buttons don't collide with it. */
          .cmsk-panel{ flex:1; display:flex; flex-direction:column; width:100%; max-width:1100px;
            margin:0 auto; padding:40px 28px 22px; min-height:0 }
          .cmsk-head{ display:flex; align-items:center; gap:10px; margin-bottom:20px }
          .cmsk-title{ font-size:24px; font-weight:700; color:#eef2f8 }
          .cmsk-actions{ margin-left:auto; display:flex; align-items:center; gap:8px }
          .cmsk-icon{ background:none; border:0; color:#c8cfdb; font-size:15px; cursor:pointer;
            padding:7px 9px; border-radius:8px; line-height:1 }
          .cmsk-icon:hover{ background:#1a2130 }
          .cmsk-search{ background:#141a26; border:1px solid #2a3450; border-radius:8px; color:#e7ecf4;
            padding:7px 10px; width:190px; font-size:13px; outline:none }
          .cmsk-btn{ background:#20283a; border:1px solid #2f3a54; color:#e7ecf4; border-radius:8px;
            padding:7px 14px; font-size:13px; font-weight:600; cursor:pointer }
          .cmsk-btn:hover{ background:#28324a }
          .cmsk-addwrap{ position:relative }
          .cmsk-addmenu{ position:absolute; right:0; top:40px; background:#171d2b; border:1px solid #2a3450;
            border-radius:10px; padding:5px; min-width:230px; box-shadow:0 14px 34px rgba(0,0,0,.55); z-index:5 }
          .cmsk-addmenu button{ display:block; width:100%; text-align:left; background:none; border:0;
            color:#d4dbe7; padding:9px 10px; border-radius:7px; font-size:13px; cursor:pointer }
          .cmsk-addmenu button:hover{ background:#222c42 }
          .cmsk-cols,.cmsk-row{ display:grid; grid-template-columns:1fr 200px 150px; gap:12px }
          .cmsk-cols{ padding:0 14px 10px; color:#8792a5; font-size:13px; border-bottom:1px solid #1c2330 }
          .cmsk-list{ flex:1; overflow-y:auto; min-height:0 }
          .cmsk-row{ padding:14px; border-bottom:1px solid #161c28; cursor:pointer; align-items:start }
          .cmsk-row:hover{ background:#111722 }
          .cmsk-row .c1{ min-width:0 }
          .cmsk-row .nmrow{ display:flex; align-items:center; gap:8px }
          .cmsk-row .nm{ color:#e7ecf4; font-size:16px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmsk-edit{ background:none; border:0; color:#5d6678; cursor:pointer; font-size:12px; padding:2px 5px;
            border-radius:5px; flex:none; visibility:hidden }
          .cmsk-row:hover .cmsk-edit{ visibility:visible }
          .cmsk-edit:hover{ background:#222c42; color:#c8cfdb }
          .cmsk-row .sm{ color:#8792a5; font-size:13px; margin-top:4px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmsk-row .sm.empty{ color:#5a6474; font-style:italic }
          .cmsk-row .dt,.cmsk-row .au{ color:#9aa4b6; font-size:14px; padding-top:2px }
          .cmsk-edrow{ display:flex; align-items:center; gap:6px; margin-top:6px }
          .cmsk-sminput{ flex:1; min-width:0; background:#141a26; border:1px solid #2a3450; border-radius:6px;
            color:#e7ecf4; padding:6px 9px; font-size:13px; outline:none }
          .cmsk-sminput:focus{ border-color:#3d63b8 }
          .cmsk-mini{ flex:none; background:#20283a; border:1px solid #2f3a54; color:#e7ecf4; border-radius:6px;
            padding:6px 11px; font-size:12px; font-weight:600; cursor:pointer }
          .cmsk-mini.cmsk-pri{ background:#2f5bd0; border-color:#3d63b8 }
          .cmsk-mini:hover{ filter:brightness(1.12) }
          .cmsk-empty{ padding:44px 14px; color:#6b7589; text-align:center }
          .cmsk-foot{ padding:12px 14px 0; color:#5d6678; font-size:12px }
          /* Configurable skills base folder (defaults to ~/.claude). */
          .cmsk-folderbar{ display:flex; align-items:center; gap:9px; margin:-6px 0 16px; padding:9px 12px;
            background:#0f141d; border:1px solid #1c2330; border-radius:9px; font-size:12.5px }
          .cmsk-folderbar .lbl{ color:#6b7589; flex:none }
          .cmsk-folderbar .pth{ color:#c8cfdb; flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis;
            white-space:nowrap; font-family:ui-monospace,SFMono-Regular,Menlo,monospace }
          .cmsk-folderbar .tag{ flex:none; color:#5d6678; font-size:11px }
          .cmsk-folderbar button{ flex:none; background:#20283a; border:1px solid #2f3a54; color:#e7ecf4;
            border-radius:7px; padding:5px 11px; font-size:12px; font-weight:600; cursor:pointer }
          .cmsk-folderbar button:hover{ background:#28324a }
          /* Tabs: 현재(installed list) vs 히스토리(usage feed). */
          .cmsk-tabs{ display:flex; gap:4px; margin-bottom:14px; border-bottom:1px solid #1c2330 }
          .cmsk-tab{ background:none; border:0; color:#8792a5; font-size:14px; font-weight:600; cursor:pointer;
            padding:8px 14px; border-bottom:2px solid transparent; margin-bottom:-1px }
          .cmsk-tab:hover{ color:#c8cfdb }
          .cmsk-tab.active{ color:#eef2f8; border-bottom-color:#2f5bd0 }
          /* Usage meta on a current-tab row: "사용 12회 · 마지막 7. 5." */
          .cmsk-row .use{ color:#7f8ba0; font-size:12.5px; margin-top:5px; display:flex; gap:8px; align-items:center }
          .cmsk-row .use .n{ color:#9db4e6; font-weight:600 }
          .cmsk-row .use .never{ color:#5a6474; font-style:italic }
          /* History tab. */
          .cmsk-hcols,.cmsk-hrow{ display:grid; grid-template-columns:1fr 190px 1fr; gap:12px }
          .cmsk-hcols{ padding:0 14px 10px; color:#8792a5; font-size:13px; border-bottom:1px solid #1c2330 }
          .cmsk-hrow{ padding:11px 14px; border-bottom:1px solid #161c28; align-items:center }
          .cmsk-hrow:hover{ background:#111722 }
          .cmsk-hrow .hn{ color:#e7ecf4; font-size:14px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmsk-hrow .ht{ color:#9aa4b6; font-size:13px }
          .cmsk-hrow .hc{ color:#6b7589; font-size:12px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
            white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          /* ===== 플러그인 섹션 (스킬→플러그인 개편, v3 목업) =====
             접힌 행은 상태만(이름·유형 배지·구성 칩·상태 필), 모든 조작은 펼친 안에.
             상태 필은 신호등 금지 규칙: 청록(켜짐/연결됨)/회색(꺼짐)/호박(주의)만. */
          .cmsk-seclbl{ display:flex; align-items:center; gap:8px; color:#5d6678; font-size:12px;
            letter-spacing:.1em; text-transform:uppercase; margin:20px 2px 8px }
          .cmsk-seclbl:first-child{ margin-top:2px }
          .cmsk-seclbl .cnt{ color:#414b5e; letter-spacing:0; text-transform:none }
          .cmpl-card{ border:1px solid #1c2330; border-radius:12px; background:#0f141d; margin-bottom:10px; overflow:hidden }
          .cmpl-head{ display:flex; align-items:center; gap:9px; padding:13px 16px; cursor:pointer }
          .cmpl-head:hover{ background:#111722 }
          .cmpl-head .nm{ color:#eef2f8; font-size:16px; font-weight:600; white-space:nowrap }
          .cmpl-head .right{ margin-left:auto; display:flex; align-items:center; gap:12px }
          .cmpl-head .caret{ color:#5d6678; font-size:11px; transition:transform .15s }
          .cmpl-card.open .caret{ transform:rotate(90deg) }
          .cmpl-sm{ margin-top:-7px; padding:0 16px 12px; color:#8792a5; font-size:13px }
          .cmpl-body{ display:none; border-top:1px solid #161c28; background:#0c1017 }
          .cmpl-card.open .cmpl-body{ display:block }
          .cmpl-chip{ display:inline-flex; align-items:center; font-size:11px; font-weight:700;
            padding:2px 8px; border-radius:20px; line-height:1.5; flex:none }
          .cmpl-chip.type{ color:#5d6678; background:none; border:1px solid #2a3450; font-weight:600 }
          .cmpl-chip.opt{ color:#a9b6cc; background:rgba(169,182,204,.1); border:1px solid rgba(169,182,204,.24) }
          .cmpl-pill{ display:inline-flex; align-items:center; gap:5px; font-size:11.5px; font-weight:700;
            padding:3px 10px; border-radius:20px; flex:none }
          .cmpl-pill::before{ content:''; width:6px; height:6px; border-radius:50%; background:currentColor }
          .cmpl-pill.on{ color:#8fd0e8; background:rgba(143,208,232,.1); border:1px solid rgba(143,208,232,.3) }
          .cmpl-pill.off{ color:#77839a; background:rgba(119,131,154,.08); border:1px solid rgba(119,131,154,.25) }
          .cmpl-pill.warn{ color:#e0b16a; background:rgba(224,177,106,.1); border:1px solid rgba(224,177,106,.3) }
          /* 진행 중 — 결과가 아니라 '기다리는 중'이다. 점이 깜빡여서 멈춘 화면과
             구분된다 (반응 없는 스위치를 연타하게 만든 그 자리). */
          .cmpl-pill.busy{ color:#b39ae8; background:rgba(179,154,232,.1); border:1px solid rgba(179,154,232,.3) }
          .cmpl-pill.busy::before{ animation:cmpulse 1s ease-in-out infinite }
          .cmpl-conn{ padding:12px 16px; border-bottom:1px solid #10151f }
          .cmpl-conn .row1{ display:flex; align-items:center; gap:9px; font-size:13px; min-width:0 }
          .cmpl-conn .pth{ color:#c8cfdb; font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
            overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          .cmpl-conn .ok{ color:#8fd0e8; font-size:12.5px; flex:none }
          .cmpl-conn .bad{ color:#e0b16a; font-size:12.5px; flex:none }
          .cmpl-conn .meta{ color:#8792a5; font-size:12.5px; margin-top:4px }
          .cmpl-conn .btns{ display:flex; gap:7px; margin-top:10px }
          .cmpl-btn{ background:#20283a; border:1px solid #2f3a54; color:#eef2f8; border-radius:7px;
            padding:5px 12px; font-size:12px; font-weight:600; cursor:pointer }
          .cmpl-btn:hover{ background:#28324a }
          .cmpl-btn.cmpl-pri{ background:#2f5bd0; border-color:#3d63b8; color:#fff }
          .cmpl-btn.danger{ color:#d8a0a0; border-color:#4a3038; background:#231a1e }
          .cmpl-part{ display:flex; align-items:baseline; gap:12px; padding:11px 16px; border-bottom:1px solid #10151f }
          .cmpl-part .pd{ color:#8792a5; font-size:12.5px }
          .cmpl-part label{ display:flex; align-items:center; gap:8px; color:#eef2f8; font-size:14px; cursor:pointer; flex:none }
          .cmpl-part input[type=checkbox]{ accent-color:#2f5bd0; width:15px; height:15px }
          .cmpl-foot{ display:flex; align-items:center; gap:8px; padding:10px 16px; background:#0b0f16 }
          .cmpl-foot .sp{ margin-left:auto; color:#5d6678; font-size:12px }
          /* 프로젝트 활성도 (claude-desktop) — 기존 대시보드 카드 데이터 그대로 보존 */
          .cmpl-acthd{ padding:12px 16px 6px; color:#8792a5; font-size:13px }
          .cmpl-acthd b{ color:#eef2f8 }
          .cmpl-act{ display:flex; align-items:center; gap:10px; padding:7px 16px; border-bottom:1px solid #10151f }
          .cmpl-act:hover{ background:#101622 }
          /* NOTE: 대시보드 전역 .bars(column)와 충돌하므로 반드시 cmpl- 접두 클래스 사용. */
          .cmpl-act .cmpl-bars{ display:flex; flex-direction:row; gap:2.5px; flex:none }
          .cmpl-act .cmpl-bars i{ width:9px; height:13px; border-radius:2.5px; background:#252d3d }
          .cmpl-act .an{ color:#eef2f8; font-size:14px; font-weight:600; min-width:0;
            overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          .cmpl-act .tail{ margin-left:auto; display:flex; align-items:center; gap:10px; flex:none }
          .cmpl-act .using{ color:#4ec99a; background:rgba(78,201,154,.12); border:1px solid rgba(78,201,154,.32);
            border-radius:20px; padding:2px 10px; font-size:11.5px; font-weight:700 }
          .cmpl-act .ago{ color:#8792a5; font-size:12.5px; min-width:62px; text-align:right }
          .cmpl-actmore{ padding:9px 16px; color:#5d6678; font-size:12.5px }
          /* ===== 연동 칸 =====
             플러그인 카드 안(슬랙 토큰)과 LLM 연동 섹션(모델 키)이 같은 마크업을 쓴다 —
             한 화면에서 두 가지 모양으로 키를 다루면 사용자가 매번 다시 배워야 한다.
             입력 칸은 값을 되돌려 받지 않는다: 저장된 키는 마스킹(뒤 4자리)만 보인다. */
          .cmig-row{ padding:12px 16px; border-bottom:1px solid #10151f }
          .cmig-top{ display:flex; align-items:center; gap:8px; flex-wrap:wrap }
          .cmig-nm{ color:#eef2f8; font-size:14px; font-weight:600 }
          .cmig-svc{ color:#5d6678; font-size:11.5px;
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace }
          .cmig-role{ color:#8792a5; font-size:12.5px; margin-top:4px }
          .cmig-det{ color:#8fd0e8; font-size:12.5px; margin-top:5px }
          .cmig-err{ color:#e0b16a; font-size:12.5px; margin-top:5px; line-height:1.55 }
          .cmig-in{ display:flex; gap:7px; margin-top:9px; align-items:center; flex-wrap:wrap }
          .cmig-in input{ flex:1; min-width:190px; background:#0b0f16; border:1px solid #263149;
            border-radius:7px; color:#e7ecf4; padding:6px 10px; font-size:12.5px; outline:none;
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace }
          .cmig-in input:focus{ border-color:#2f5bd0 }
          .cmig-mask{ color:#8792a5; font-size:12.5px;
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace }
          .cmig-hint{ color:#5d6678; font-size:12px; margin-top:7px; line-height:1.6 }
          .cmig-hint a{ color:#7f9fe0; text-decoration:none }
          .cmig-hint a:hover{ text-decoration:underline }
          /* 기능 게이팅 줄 — "지금 이게 왜 못 도는가"를 카드 안에서 바로 말한다. */
          .cmig-cap{ padding:11px 16px; border-bottom:1px solid #10151f; font-size:12.5px;
            line-height:1.6; color:#e0b16a; background:rgba(224,177,106,.06) }
          .cmig-cap.ok{ background:none; color:#8792a5 }
          .cmig-cap b{ color:#eef2f8; font-weight:600 }
          .cmig-cap button{ margin-left:8px }
          /* ===== MCP 연동 =====
             인스턴스 한 줄이 곧 '토큰 하나 = MCP 서버 하나'다. 등록 스위치를 상태 필과
             같은 줄에 두지 않는 이유: 토큰이 유효한가(연결 테스트)와 Claude에 붙였는가
             (등록)는 다른 사실이고, 한 칸에 섞으면 어느 쪽이 실패했는지 알 수 없다. */
          .cmig-fields{ display:flex; gap:7px; margin-top:9px; flex-wrap:wrap }
          .cmig-fields label{ display:flex; flex-direction:column; gap:3px; flex:1; min-width:190px;
            color:#5d6678; font-size:11.5px }
          .cmig-fields input{ background:#0b0f16; border:1px solid #263149; border-radius:7px;
            color:#e7ecf4; padding:6px 10px; font-size:12.5px; outline:none }
          .cmig-fields input:focus{ border-color:#2f5bd0 }
          .cmig-mcp{ display:flex; align-items:center; gap:9px; margin-top:10px; flex-wrap:wrap;
            padding:9px 11px; border:1px solid #1c2330; border-radius:9px; background:#0d1219 }
          .cmig-mcp label{ display:flex; align-items:center; gap:7px; color:#eef2f8;
            font-size:12.5px; font-weight:600; cursor:pointer }
          .cmig-mcp .pd{ color:#5d6678; font-size:12px;
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace }
          /* 테스트 줄 — 등록 스위치 바로 아래. 두 일이 이어져 있다는 것을 자리로
             보여주되(등록 → 테스트), 버튼은 따로 둔다. */
          .cmig-test{ display:flex; align-items:center; gap:9px; margin-top:7px; flex-wrap:wrap }
          .cmig-test .pd{ color:#5d6678; font-size:11.5px }
          .cmig-add{ background:#0d1219 }
          .cmig-add .cmig-nm{ font-size:13px }
          /* 인증 방식 세그먼트 — 이름 칸보다 위에 둔다. 아래 폼의 모양이 이 선택에
             따라 바뀌므로, 읽는 순서와 고르는 순서가 같아야 한다. */
          .cmig-modes{ display:flex; gap:7px; margin-top:9px; flex-wrap:wrap }
          /* LLM 연동 섹션 — 연동된 것만 보이고, 나머지는 '연동 추가'로 펼친다. */
          .cmsk-seclbl .add{ margin-left:auto; letter-spacing:0; text-transform:none;
            background:#20283a; border:1px solid #2f3a54; color:#c8cfdb; border-radius:7px;
            padding:3px 10px; font-size:12px; cursor:pointer }
          .cmsk-seclbl .add:hover{ background:#28324a }
          /* 찾아보기(카탈로그) 탭 */
          .cmpl-cat{ display:grid; grid-template-columns:1fr 1fr; gap:10px }
          @media (max-width:760px){ .cmpl-cat{ grid-template-columns:1fr } }
          .cmpl-catcard{ border:1px solid #1c2330; border-radius:12px; background:#0f141d; padding:16px }
          .cmpl-catcard .top{ display:flex; align-items:center; gap:9px; flex-wrap:wrap }
          .cmpl-catcard .nm{ color:#eef2f8; font-size:15px; font-weight:600 }
          .cmpl-catcard .desc{ color:#8792a5; font-size:13px; margin:8px 0 14px; min-height:38px }
          .cmpl-catcard .bot{ display:flex; align-items:center; gap:8px }
          .cmpl-catcard .bot .hint{ color:#5d6678; font-size:12px; margin-left:auto }
        </style>
        <div class="cmsk-overlay" id="cmSkOverlay" style="display:none">
          <div class="cmsk-panel">
            <div class="cmsk-head">
              <div class="cmsk-title">플러그인</div>
              <div class="cmsk-actions">
                <button class="cmsk-icon" title="검색" onclick="cmSkToggleSearch()">🔍</button>
                <input class="cmsk-search" id="cmSkSearch" placeholder="플러그인·연동·스킬 검색…" oninput="cmSkRender();cmPlRender();cmLlmRender();cmMcpRender()" style="display:none">
                <button class="cmsk-btn" onclick="cmSkReveal('')">스킬 폴더 열기</button>
                <button class="cmsk-icon cmsk-close" title="닫기 (Esc)" onclick="cmSkClose();if(window.cmNavReflect)cmNavReflect()">✕</button>
              </div>
            </div>
            <div class="cmsk-tabs">
              <button class="cmsk-tab active" data-tab="current" onclick="cmSkTab('current')">현재</button>
              <button class="cmsk-tab" data-tab="browse" onclick="cmSkTab('browse')">찾아보기</button>
              <button class="cmsk-tab" data-tab="history" onclick="cmSkTab('history')">히스토리</button>
            </div>
            <div id="cmSkTabCurrent" class="cmsk-list">
              <!-- 플러그인: 설치형(설치=연결)·폴더형(폴더 선택+검증) 카드. 접힌 행은 상태만,
                   조작(제거·폴더 변경·옵션 토글)은 전부 펼친 안에. 설치는 찾아보기 탭에서만. -->
              <div class="cmsk-seclbl">플러그인 <span class="cnt" id="cmPlCount"></span></div>
              <div id="cmPlList"><div class="cmsk-empty">불러오는 중…</div></div>
              <!-- MCP 연동: 앱이 직접 부르는 API가 아니라 Claude 세션이 도구로 쓰는 외부
                   서비스(노션·지라·깃허브). 토큰은 여기서 받고 키체인에만 두며, 등록 스위치가
                   claude mcp add/remove 를 대신 눌러 준다. 같은 서비스라도 계정·조직·사이트가
                   여럿이므로 인스턴스를 이름 붙여 여러 개 만든다. -->
              <div class="cmsk-seclbl">MCP 연동 <span class="cnt" id="cmMcpCount"></span>
                <button class="add" id="cmMcpAddBtn" onclick="cmMcpToggleAll()">연동 추가</button></div>
              <div id="cmMcpList"><div class="cmsk-empty">불러오는 중…</div></div>
              <!-- LLM 연동: 플러그인이 빌려 쓰는 모델 연결. 플러그인 다음, 스킬 앞.
                   모델은 많고 대부분은 안 쓰므로 연동된 것만 보이고 나머지는 '연동 추가'로
                   펼친다. 여기의 상태가 곧 플러그인 카드의 경고 문구의 근거다. -->
              <div class="cmsk-seclbl">LLM 연동 <span class="cnt" id="cmLlmCount"></span>
                <button class="add" id="cmLlmAddBtn" onclick="cmLlmToggleAll()">연동 추가</button></div>
              <div id="cmLlmList"><div class="cmsk-empty">불러오는 중…</div></div>
              <!-- 스킬: 임시적 도구 — 플러그인과 별개의 독립 섹션 (스킬 폴더 그대로).
                   스크립트로 대체되면 사라지고 모델 업그레이드로 동작이 달라지는, 수명이 짧은 존재다. -->
              <div class="cmsk-seclbl">스킬 <span class="cnt">· 임시적 도구 — 플러그인과 별개</span></div>
              <div class="cmsk-folderbar">
                <span class="lbl">스킬 폴더</span>
                <span class="pth" id="cmSkRoot" title="">~/.claude</span>
                <span class="tag" id="cmSkRootTag"></span>
                <button onclick="cmSkPickFolder()">변경</button>
                <button onclick="cmSkResetFolder()">기본값</button>
              </div>
              <div class="cmsk-cols"><span>스킬</span><span>마지막 업데이트</span><span>작성자</span></div>
              <div id="cmSkList"></div>
              <div class="cmsk-foot" id="cmSkFoot"></div>
            </div>
            <div id="cmSkTabBrowse" class="cmsk-list" style="display:none">
              <!-- 카탈로그 = 설치의 유일한 진입점. 이미 설치/연결된 항목은 비활성 버튼. -->
              <div class="cmpl-cat" id="cmPlCat"><div class="cmsk-empty">불러오는 중…</div></div>
              <div class="cmsk-foot">카탈로그에서만 설치할 수 있어요 — 설치된 플러그인 관리는 현재 탭에서</div>
            </div>
            <div id="cmSkTabHistory" style="display:none">
              <div class="cmsk-hcols"><span>스킬</span><span>사용 시각</span><span>위치</span></div>
              <div class="cmsk-list" id="cmSkHistList"></div>
              <div class="cmsk-foot" id="cmSkHistFoot"></div>
            </div>
          </div>
        </div>
        <script>
        (function(){
          function esc2(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }
          function escAttr(t){ return esc2(t).replace(/"/g,'&quot;'); }
          var _data=[], _dir='', _root='';
          window.cmSkillsOpen=function(ev){ if(ev) ev.preventDefault();
            if(typeof window.cmAgClose==='function') window.cmAgClose();
            var o=document.getElementById('cmSkOverlay');
            if(o){ o.style.display='flex'; cmSkTab('current'); load(); plLoad(); } };
          window.cmSkClose=function(){ var o=document.getElementById('cmSkOverlay'); if(o) o.style.display='none';
            var m=document.getElementById('cmSkAddMenu'); if(m) m.style.display='none'; };
          window.cmSkToggleSearch=function(){ var s=document.getElementById('cmSkSearch'); if(!s) return;
            var show=(s.style.display==='none'); s.style.display=show?'block':'none';
            if(show){ s.focus(); } else { s.value=''; cmSkRender(); } };
          // Open the skills folder (or one skill) in Finder so the user can inspect/edit files.
          window.cmSkReveal=function(name){
            fetch('/api/skills/reveal',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({name:name||''})}).catch(function(){});
            var m=document.getElementById('cmSkAddMenu'); if(m) m.style.display='none'; };
          // Apply a /api/skills payload to the UI: folder line + skills list in one pass.
          function applyData(d){
            _data=(d&&d.skills)||[]; _dir=(d&&d.dir)||''; _root=(d&&d.root)||'';
            var f=document.getElementById('cmSkFoot'); if(f) f.textContent=_dir?('폴더: '+_dir):'';
            var rt=document.getElementById('cmSkRoot');
            if(rt){ rt.textContent=_root||'~/.claude'; rt.title=_root||''; }
            var tag=document.getElementById('cmSkRootTag');
            if(tag) tag.textContent=(d&&d.isDefault)?'기본값':'';
            cmSkRender();
          }
          function load(){ var box=document.getElementById('cmSkList'); if(box) box.innerHTML='<div class="cmsk-empty">불러오는 중…</div>';
            fetch('/api/skills').then(function(r){return r.json();}).then(applyData)
            .catch(function(){ if(box) box.innerHTML='<div class="cmsk-empty">스킬을 불러오지 못했습니다</div>'; }); }
          // ---- Tabs: 현재(installed) vs 히스토리(usage feed) ----
          window.cmSkTab=function(name){
            var tabs=document.querySelectorAll('.cmsk-tab');
            for(var i=0;i<tabs.length;i++){ tabs[i].classList.toggle('active', tabs[i].getAttribute('data-tab')===name); }
            var cur=document.getElementById('cmSkTabCurrent'), his=document.getElementById('cmSkTabHistory'),
                bro=document.getElementById('cmSkTabBrowse');
            if(cur) cur.style.display=(name==='current')?'block':'none';
            if(bro) bro.style.display=(name==='browse')?'block':'none';
            if(his) his.style.display=(name==='history')?'block':'none';
            if(name==='history') loadHist();
            if(name==='browse') plLoad();
          };
          function loadHist(){ var box=document.getElementById('cmSkHistList');
            if(box) box.innerHTML='<div class="cmsk-empty">불러오는 중…</div>';
            fetch('/api/skills/history').then(function(r){return r.json();}).then(renderHist)
            .catch(function(){ if(box) box.innerHTML='<div class="cmsk-empty">히스토리를 불러오지 못했습니다</div>'; }); }
          // Relative time for the history feed; falls back to the stored ISO string.
          function fmtTime(epoch, ts){
            if(!epoch) return esc2(ts||'');
            var d=new Date(epoch*1000), diff=(Date.now()-d.getTime())/1000;
            if(diff<60) return '방금';
            if(diff<3600) return Math.floor(diff/60)+'분 전';
            if(diff<86400) return Math.floor(diff/3600)+'시간 전';
            if(diff<604800) return Math.floor(diff/86400)+'일 전';
            var p=window.CMTimeFilter.parts(d);
            return (p.y%100)+'. '+p.mo+'. '+p.d+'.';
          }
          function baseName(p){ if(!p) return ''; var a=(''+p).split('/').filter(Boolean); return a.length?a[a.length-1]:p; }
          function renderHist(d){ var box=document.getElementById('cmSkHistList'); if(!box) return;
            var evs=(d&&d.events)||[]; var foot=document.getElementById('cmSkHistFoot');
            if(foot) foot.textContent=(d&&d.total)?('총 '+d.total+'회 실행'+((d.total>evs.length)?(' — 최근 '+evs.length+'개 표시'):'')):'';
            if(!evs.length){ box.innerHTML='<div class="cmsk-empty">아직 스킬 사용 기록이 없습니다</div>'; return; }
            box.innerHTML='';
            evs.forEach(function(e){ var row=document.createElement('div'); row.className='cmsk-hrow';
              row.innerHTML='<span class="hn">'+esc2(e.skill||'')+'</span>'
                +'<span class="ht" title="'+escAttr(e.ts||'')+'">'+esc2(fmtTime(e.epoch,e.ts))+'</span>'
                +'<span class="hc" title="'+escAttr(e.cwd||'')+'">'+esc2(baseName(e.cwd))+'</span>';
              box.appendChild(row); }); }
          // Choose the skills base (.claude) folder via a native picker, then reload the list.
          window.cmSkPickFolder=function(){
            fetch('/api/skills/folder/pick',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})
              .then(function(r){return r.json();}).then(applyData).catch(function(){}); };
          // Reset the skills base folder back to the ~/.claude default.
          window.cmSkResetFolder=function(){
            fetch('/api/skills/folder',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({folder:''})}).then(function(r){return r.json();}).then(applyData).catch(function(){}); };
          window.cmSkRender=function(){ var box=document.getElementById('cmSkList'); if(!box) return;
            var si=document.getElementById('cmSkSearch'); var q=((si&&si.value)||'').trim().toLowerCase();
            var list=_data.filter(function(s){ if(!q) return true;
              return (s.name||'').toLowerCase().indexOf(q)>=0
                  || (s.summary||'').toLowerCase().indexOf(q)>=0
                  || (s.desc||'').toLowerCase().indexOf(q)>=0; });
            if(!list.length){ box.innerHTML='<div class="cmsk-empty">'+(q?'검색 결과가 없습니다':('스킬이 없습니다'+(_dir?' — '+esc2(_dir):'')))+'</div>'; return; }
            box.innerHTML='';
            list.forEach(function(s){ var key=s.folder||s.name;
              var row=document.createElement('div'); row.className='cmsk-row'; row.dataset.key=key;
              // Clicking the row (but not the edit button/inputs) opens the folder in Finder.
              row.onclick=function(e){ if(e.target.closest('.cmsk-edit')||e.target.closest('.cmsk-edrow')) return; cmSkReveal(key); };
              var sm=(s.summary||'').trim();
              var smHtml=sm?('<div class="sm" title="'+escAttr(sm)+'">'+esc2(sm)+'</div>')
                           :('<div class="sm empty">한줄 요약 없음 — 연필을 눌러 추가</div>');
              var uc=s.useCount||0;
              var useHtml=uc>0
                ? ('<div class="use"><span class="n">사용 '+uc+'회</span>'+(s.lastUsed?('<span>· 마지막 '+esc2(s.lastUsed)+'</span>'):'')+'</div>')
                : ('<div class="use"><span class="never">아직 사용 안 함</span></div>');
              row.innerHTML='<div class="c1">'
                  +'<div class="nmrow"><span class="nm">'+esc2(s.name)+'</span>'
                  +'<button class="cmsk-edit" title="한줄 요약 수정">✏️</button></div>'
                  +smHtml+useHtml
                +'</div>'
                +'<span class="dt">'+esc2(s.updated||'')+'</span>'
                +'<span class="au">'+esc2(s.author||'사용자')+'</span>';
              row.querySelector('.cmsk-edit').onclick=function(e){ e.stopPropagation(); startEdit(row, key, sm); };
              box.appendChild(row); }); };

          // Swap a row's summary line for an inline editor (input + 저장/취소).
          function startEdit(row, key, cur){
            var c1=row.querySelector('.c1'); if(!c1) return;
            var old=c1.querySelector('.sm'); if(old) old.style.display='none';
            var prev=c1.querySelector('.cmsk-edrow'); if(prev) prev.remove();
            var box=document.createElement('div'); box.className='cmsk-edrow';
            box.innerHTML='<input class="cmsk-sminput" maxlength="200" placeholder="한줄 요약을 입력…" value="'+escAttr(cur||'')+'">'
              +'<button class="cmsk-mini cmsk-pri" data-a="save">저장</button>'
              +'<button class="cmsk-mini" data-a="cancel">취소</button>';
            c1.appendChild(box);
            var inp=box.querySelector('.cmsk-sminput'); inp.focus(); inp.select();
            inp.onclick=function(e){ e.stopPropagation(); };
            box.querySelector('[data-a=save]').onclick=function(e){ e.stopPropagation(); saveSummary(key, inp.value); };
            box.querySelector('[data-a=cancel]').onclick=function(e){ e.stopPropagation(); cmSkRender(); };
            inp.onkeydown=function(e){ e.stopPropagation();
              if(e.key==='Enter'){ saveSummary(key, inp.value); }
              else if(e.key==='Escape'){ cmSkRender(); } };
          }
          function saveSummary(key, val){
            fetch('/api/skills/summary',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({folder:key, summary:val})}).then(function(r){return r.json();})
              .then(function(){ var s=_data.find(function(x){return (x.folder||x.name)===key;});
                if(s){ s.summary=(val||'').trim(); s.hasSummary=!!s.summary; } cmSkRender(); })
              .catch(function(){ cmSkRender(); });
          }
          document.addEventListener('keydown',function(e){ if(e.key==='Escape'){ var o=document.getElementById('cmSkOverlay');
            if(o&&o.style.display!=='none'){ cmSkClose(); if(typeof window.cmNavReflect==='function') window.cmNavReflect(); } } });

          // ===== 플러그인 섹션 (설치형·폴더형 카드, 구 대시보드 🧩 오버레이 머지) =====
          // 데이터: GET /api/plugins (PluginStore.pluginsJSON — /data.json plugins와 동일 형식).
          // 접힌 행은 상태만, 조작은 펼친 안에. 설치는 찾아보기 탭 카탈로그에서만.
          var _pl=[];                              // last /api/plugins payload
          // 카드는 모두 접힌 상태로 시작한다 — 펼친 기본값은 프로젝트 활성도 목록이 길어
          // 페이지가 어수선해진다. 펼침은 사용자가 헤더를 눌렀을 때만.
          var _plOpen={};                          // per-card expanded state (in-memory)
          function plLoad(){
            fetch('/api/plugins',{cache:'no-store'}).then(function(r){return r.json();})
              .then(function(d){ _pl=(d&&d.plugins)||[]; cmPlRender(); cmPlCatRender(); })
              .catch(function(){});
            intgLoad();
          }
          // Native folder picker POSTs return immediately; poll a few times for the verdict.
          function plRefresh(){ [400,1200,2500,4000].forEach(function(ms){ setTimeout(plLoad,ms); }); }
          function plPost(url,body){ fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify(body||{})}).catch(function(){}); plRefresh(); }
          window.cmPlToggle=function(id){ _plOpen[id]=!_plOpen[id]; cmPlRender(); };
          window.cmPlConnect=function(id){ plPost('/api/plugin/connect',{id:id}); };
          window.cmPlVerify=function(id){ plPost('/api/plugin/verify',{id:id}); };
          window.cmPlDisconnect=function(id){ if(confirm('이 플러그인 연결을 해제할까요?')) plPost('/api/plugin/disconnect',{id:id}); };
          window.cmPlInstall=function(id){ plPost('/api/plugin/install',{id:id}); };
          window.cmPlUninstall=function(id){
            if(confirm('이 플러그인을 제거할까요? 완전히 삭제됩니다. (컨디션 메이트는 BGM도 함께 꺼집니다)'))
              plPost('/api/plugin/uninstall',{id:id}); };
          window.cmPlDraw=function(on){ plPost('/api/draw/enabled',{on:!!on}); };
          window.cmPlCamera=function(on){ plPost('/api/camera/enabled',{on:!!on}); };
          // 5단계 활성 강도 → 세그먼트 색 (기존 대시보드 levelMeta와 동일한 사다리).
          function plLevelColor(lv){
            return ['#252d3d','#8a8f9c','#e8a13a','#e0c23a','#36c08a','#2ee6a6'][lv]||'#252d3d';
          }
          function plAgo(sec){
            if(sec<60) return Math.max(0,sec)+'초 전';
            if(sec<3600) return Math.floor(sec/60)+'분 전';
            if(sec<86400) return Math.floor(sec/3600)+'시간 전';
            return Math.floor(sec/86400)+'일 전';
          }
          // 상태 필: 신호등 금지 — 청록(켜짐/연결됨)/회색(꺼짐)/호박(주의)만 사용.
          function plPill(p){
            if(p.kind==='toggle'){
              if(!p.installed) return ['off','꺼짐'];
              // 켜져 있어도 필요한 연동이 빠져 있으면 실제로는 일을 못 한다 —
              // 접힌 행에서 '켜짐'만 보이면 그 사실을 펼쳐야만 알게 된다.
              if(intgPluginNeedsAttention(p)) return ['warn','연동 필요'];
              return ['on','켜짐'];
            }
            if(p.status==='valid') return ['on','연결됨'];
            if(p.status==='invalid') return ['warn','잘못된 연결'];
            return ['warn','폴더 연결 필요'];
          }
          // claude-desktop 펼침 안의 프로젝트 활성도 — 기존 대시보드 카드 그대로 보존
          // (사용 중 필·5단계 강도 바·최근성·휴면 요약). 이 데이터가 이 카드의 핵심이다.
          function plActivityHtml(p){
            var ps=p.projects||[];
            if(p.status!=='valid'||!ps.length) return '';
            var live=ps.filter(function(x){return x.level>=1;});
            var dormant=ps.length-live.length;
            var activeN=ps.filter(function(x){return x.inUse;}).length;
            var h='<div class="cmpl-acthd">프로젝트 활성도 <b>'+activeN+'</b>개 사용 중 · 활성 강도 5단계</div>';
            live.forEach(function(x){
              var bars='';
              for(var i=1;i<=5;i++){ bars+='<i style="background:'+(i<=x.level?plLevelColor(x.level):'#252d3d')+'"></i>'; }
              h+='<div class="cmpl-act"><span class="cmpl-bars">'+bars+'</span>'
                +'<span class="an" title="'+escAttr(x.path||'')+'">'+esc2(x.name)+'</span>'
                +'<span class="tail">'+(x.inUse?'<span class="using">사용 중</span>':'')
                +'<span class="ago">'+esc2(plAgo(x.lastActiveSec))+'</span></span></div>';
            });
            if(dormant>0) h+='<div class="cmpl-actmore">+ 휴면 '+dormant+'개 (7일+)</div>';
            return h;
          }
          // 펼친 본문: 폴더형=연결 블록(+활성도), 설치형=옵션·정보 행 + 제거 푸터.
          function plBodyHtml(p){
            var h='';
            if(p.kind==='folder'){
              var st=(p.status==='valid')?('<span class="ok">'+esc2(p.detail||'')+'</span>')
                    :(p.folder?('<span class="bad">'+esc2(p.detail||'')+'</span>'):'');
              h+='<div class="cmpl-conn"><div class="row1"><span>📁</span>'
                +(p.folder?('<span class="pth" title="'+escAttr(p.folder)+'">'+esc2(p.folder)+'</span>')
                          :'<span class="pth" style="color:#77839a">아직 폴더가 연결되지 않았습니다</span>')
                +st+'</div>'
                +'<div class="meta">기준: '+esc2(p.hint||'')+'</div>'
                +'<div class="btns"><button class="cmpl-btn cmpl-pri" onclick="event.stopPropagation();cmPlConnect(\''+esc2(p.id)+'\')">'
                +(p.folder?'폴더 변경':'폴더 선택')+'</button>'
                +(p.folder?('<button class="cmpl-btn" onclick="event.stopPropagation();cmPlVerify(\''+esc2(p.id)+'\')">재검증</button>'
                  +'<button class="cmpl-btn" onclick="event.stopPropagation();cmPlDisconnect(\''+esc2(p.id)+'\')">해제</button>'):'')
                +'</div></div>';
              h+=plActivityHtml(p);
            } else {
              if(p.id==='draw'){
                h+='<div class="cmpl-part"><span class="cmpl-chip opt">옵션</span>'
                  +'<label><input type="checkbox" '+(p.drawOn?'checked':'')
                  +' onclick="event.stopPropagation()" onchange="cmPlDraw(this.checked)"> draw on/off</label>'
                  +'<span class="pd">왼쪽 ⌥ 그리기 · 왼쪽 ⌘⌘⌘ 글씨 · fn 지우기 — 끄면 즉시 일시정지</span></div>';
              }
              if(p.id==='camera-guard'){
                h+='<div class="cmpl-part"><span class="cmpl-chip opt">옵션</span>'
                  +'<label><input type="checkbox" '+(p.cameraOn?'checked':'')
                  +' onclick="event.stopPropagation()" onchange="cmPlCamera(this.checked)"> 지킴이 on/off</label>'
                  +'<span class="pd">개더 실행 중 카메라 상시-ON 유지 — 끄면 즉시 일시정지</span></div>';
              }
              // 연동이 필요한 플러그인(슬랙 번역)은 키 칸과 기능 게이팅을 카드 안에서
              // 끝낸다 — 다른 페이지로 보내면 "설치는 했는데 왜 안 되지"가 남는다.
              h+=intgCapsHtml(p);
              h+=intgCredsHtml(p.credentials);
              h+='<div class="cmpl-part"><span class="cmpl-chip opt">정보</span>'
                +'<span class="pd">'+esc2(p.hint||'')+'</span></div>';
              h+='<div class="cmpl-foot"><button class="cmpl-btn danger" onclick="event.stopPropagation();cmPlUninstall(\''+esc2(p.id)+'\')">플러그인 제거</button>'
                +'<span class="sp">완전히 삭제됩니다'
                +(p.id==='condition-mate'?' — BGM도 함께 꺼집니다':'')
                +(p.id==='slack-translate'?' — 수집 데몬이 대기 상태로 들어갑니다 (키는 남습니다)':'')
                +'</span></div>';
            }
            return h;
          }
          // 현재 탭 목록: 폴더형은 항상, 설치형은 설치된 것만 (미설치는 카탈로그에서만).
          window.cmPlRender=function(){
            var box=document.getElementById('cmPlList'); if(!box) return;
            var si=document.getElementById('cmSkSearch'); var q=((si&&si.value)||'').trim().toLowerCase();
            var list=_pl.filter(function(p){ return p.kind==='folder'||p.installed; })
              .filter(function(p){ if(!q) return true;
                return (p.name||'').toLowerCase().indexOf(q)>=0||(p.desc||'').toLowerCase().indexOf(q)>=0; });
            var cnt=document.getElementById('cmPlCount'); if(cnt) cnt.textContent='· '+list.length;
            if(!list.length){ box.innerHTML='<div class="cmsk-empty">'+(q?'검색 결과가 없습니다':'플러그인이 없습니다 — 찾아보기 탭에서 설치하세요')+'</div>'; return; }
            box.innerHTML='';
            list.forEach(function(p){
              var pill=plPill(p);
              var opts=(p.id==='draw'||p.id==='camera-guard')?'<span class="cmpl-chip opt">옵션 1</span>':'';
              var card=document.createElement('div');
              card.className='cmpl-card'+(_plOpen[p.id]?' open':'');
              card.innerHTML='<div class="cmpl-head" onclick="cmPlToggle(\''+esc2(p.id)+'\')">'
                +'<span class="nm">'+esc2(p.name)+'</span>'
                +'<span class="cmpl-chip type">'+(p.kind==='folder'?'폴더형':'설치형')+'</span>'+opts
                +'<div class="right"><span class="cmpl-pill '+pill[0]+'">'+pill[1]+'</span><span class="caret">▶</span></div></div>'
                +'<div class="cmpl-sm">'+esc2(p.desc||'')+'</div>'
                +'<div class="cmpl-body" onclick="event.stopPropagation()">'+plBodyHtml(p)+'</div>';
              box.appendChild(card);
            });
          };
          // 찾아보기 탭: 카탈로그 카드 — 설치의 유일한 진입점.
          window.cmPlCatRender=function(){
            var box=document.getElementById('cmPlCat'); if(!box) return;
            if(!_pl.length){ box.innerHTML='<div class="cmsk-empty">불러오는 중…</div>'; return; }
            box.innerHTML='';
            _pl.forEach(function(p){
              var installed=(p.kind==='toggle')?p.installed:(p.status==='valid');
              var act, hint;
              if(installed){ act='<button class="cmpl-btn" disabled style="opacity:.5">'
                  +(p.kind==='folder'?'연결됨':'설치됨')+'</button>'; hint='현재 탭에서 관리'; }
              else if(p.kind==='toggle'){ act='<button class="cmpl-btn cmpl-pri" onclick="cmPlInstall(\''+esc2(p.id)+'\')">설치</button>';
                hint='설치 즉시 동작'; }
              else { act='<button class="cmpl-btn cmpl-pri" onclick="cmPlConnect(\''+esc2(p.id)+'\')">연결</button>';
                hint='폴더 선택 + 내용 검증'; }
              var card=document.createElement('div'); card.className='cmpl-catcard';
              card.innerHTML='<div class="top"><span class="nm">'+esc2(p.name)+'</span>'
                +'<span class="cmpl-chip type">'+(p.kind==='folder'?'폴더형':'설치형')+'</span></div>'
                +'<div class="desc">'+esc2(p.desc||'')+'</div>'
                +'<div class="bot">'+act+'<span class="hint">'+esc2(hint)+'</span></div>';
              box.appendChild(card);
            });
          };

          /* ===== 연동 (GET /api/integrations) =====
             한 곳에서 받은 payload를 두 화면이 나눠 쓴다: 플러그인 카드 안의 키 칸과
             아래 LLM 연동 섹션. 카탈로그·상태·기능 게이팅이 모두 서버의 단일 원본
             (IntegrationStore)에서 오므로, 여기서는 그리기만 하고 판단하지 않는다. */
          var _intg={credentials:[],providers:[],capabilities:[]};
          var _llmAll=false;                 // 연동 안 된 제공자까지 펼쳐 보기
          var _llmOpen={};                   // 제공자 카드 펼침 상태
          function intgLoad(){
            fetch('/api/integrations',{cache:'no-store'}).then(function(r){return r.json();})
              .then(function(d){ if(d&&d.credentials){ _intg=d; cmLlmRender(); cmMcpRender(); cmPlRender(); } })
              .catch(function(){});
          }
          function intgCred(id){
            var list=_intg.credentials||[];
            for(var i=0;i<list.length;i++){ if(list[i].id===id) return list[i]; }
            return null;
          }
          // 자격증명 하나의 상태 필. 라이브 검사 전에는 '등록됨'까지만 말한다 —
          // 확인하지 않은 것을 '연결됨'이라고 하면 그 화면이 거짓말을 하게 된다.
          function intgPill(c){
            if(c.state==='ok') return ['on','연결됨'];
            if(c.state==='manual') return ['on','웹 세션'];
            if(c.state==='fail') return ['warn','연결 실패'];
            if(c.state==='missing') return ['off','연동 안 됨'];
            return c.present?['on','등록됨 · 미확인']:['off','연동 안 됨'];
          }
          // 이 자격증명이 지금 일할 수 있는 상태인가 (게이팅과 같은 기준).
          function intgLive(c){
            if(!c) return false;
            if(c.state==='ok'||c.state==='manual') return true;
            if(c.state==='fail'||c.state==='missing') return false;
            return !!c.present;
          }
          function intgPluginNeedsAttention(p){
            var creds=(p.credentials||[]).map(intgCred).filter(Boolean);
            for(var i=0;i<creds.length;i++){ if(!intgLive(creds[i])) return true; }
            var caps=(_intg.capabilities||[]).filter(function(c){ return c.owner===p.id; });
            for(var j=0;j<caps.length;j++){ if(!caps[j].ok) return true; }
            return false;
          }
          function intgCredRow(c){
            if(!c) return '';
            var pill=intgPill(c);
            var typed=(c.kind==='apiKey'||c.kind==='endpoint');
            var h='<div class="cmig-row"><div class="cmig-top">'
              +'<span class="cmig-nm">'+esc2(c.name)+'</span>'
              +'<span class="cmpl-chip type">'+esc2(c.kindLabel||'')+'</span>'
              +(c.service?('<span class="cmig-svc">'+esc2(c.service)+'</span>'):'')
              +'<span class="cmpl-pill '+pill[0]+'" style="margin-left:auto">'+pill[1]+'</span></div>'
              +'<div class="cmig-role">'+esc2(c.role||'')+'</div>';
            if(c.detail) h+='<div class="cmig-det">'+esc2(c.detail)+'</div>';
            if(c.error) h+='<div class="cmig-err">⚠ '+esc2(c.error)+'</div>';
            if((c.missingScopes||[]).length){
              h+='<div class="cmig-err">⚠ 토큰은 유효하지만 스코프가 빠져 일부 동작이 조용히 실패합니다 — 누락: '
                +esc2(c.missingScopes.join(', '))+'</div>';
            }
            if(typed){
              // 저장된 값은 절대 되돌려 받지 않는다 — 마스킹만 보이고, 입력 칸은 늘 비어 있다.
              h+='<div class="cmig-in">'
                +(c.present?('<span class="cmig-mask">'+esc2(c.masked||'')+'</span>'):'')
                +'<input id="cmig-in-'+esc2(c.id)+'" type="password" autocomplete="off" spellcheck="false"'
                +' placeholder="'+escAttr(c.present?'새 값으로 교체하려면 붙여넣기':(c.placeholder||'키 붙여넣기'))+'"'
                +' onkeydown="if(event.key===\'Enter\'){event.preventDefault();cmIntgSave(\''+esc2(c.id)+'\',null);}">'
                +'<button class="cmpl-btn cmpl-pri" onclick="cmIntgSave(\''+esc2(c.id)+'\',this)">저장</button>'
                +'<button class="cmpl-btn" onclick="cmIntgTest([\''+esc2(c.id)+'\'],this)">연결 테스트</button>'
                +(c.present?('<button class="cmpl-btn danger" onclick="cmIntgClear(\''+esc2(c.id)+'\')">삭제</button>'):'')
                +'</div>';
            } else {
              h+='<div class="cmig-in"><button class="cmpl-btn" onclick="cmIntgTest([\''+esc2(c.id)+'\'],this)">연결 확인</button></div>';
            }
            var hint=esc2(c.issueHint||'');
            if(c.issueURL) hint+=(hint?' · ':'')+'<a href="'+escAttr(c.issueURL)+'" target="_blank" rel="noopener">발급 페이지 열기 ↗</a>';
            if(hint) h+='<div class="cmig-hint">'+hint+'</div>';
            return h+'<div class="cmig-st" id="cmig-st-'+esc2(c.id)+'"></div></div>';
          }
          function intgCredsHtml(ids){
            return (ids||[]).map(function(id){ return intgCredRow(intgCred(id)); }).join('');
          }
          // 기능 게이팅 줄 — 서버가 판단한 문장을 그대로 싣는다 (여기서 다시 계산하면
          // 두 벌의 판단이 생긴다). 백업이 없다는 경고도 여기서 나온다.
          function intgCapsHtml(p){
            var caps=(_intg.capabilities||[]).filter(function(c){ return c.owner===p.id; });
            if(!caps.length) return '';
            return caps.map(function(c){
              if(!c.message) return '<div class="cmig-cap ok"><b>'+esc2(c.name)+'</b> 정상 동작 중입니다.</div>';
              var jump=(c.level==='none'||c.level==='nobackup'||c.level==='backup')
                ? '<button class="cmpl-btn" onclick="cmLlmFocus()">LLM 연동으로 이동</button>' : '';
              return '<div class="cmig-cap"><b>'+esc2(c.name)+'</b> — '+esc2(c.message)+jump+'</div>';
            }).join('');
          }
          // 저장: 값은 이 요청 본문으로만 나가고, 응답에도 로그에도 남지 않는다.
          window.cmIntgSave=function(id,btn){
            var inp=document.getElementById('cmig-in-'+id); if(!inp) return;
            var v=(inp.value||'').trim();
            var st=document.getElementById('cmig-st-'+id);
            if(!v){ if(st){ st.className='cmig-err'; st.textContent='⚠ 값을 붙여넣어 주세요'; } return; }
            if(btn) btn.disabled=true;
            if(st){ st.className='cmig-det'; st.textContent='저장하고 연결을 확인하는 중…'; }
            fetch('/api/integrations/key',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({id:id,value:v})})
              .then(function(r){return r.json();})
              .then(function(j){
                inp.value='';                       // 입력 칸에 키가 남아 있지 않게
                if(!j||!j.ok){
                  if(st){ st.className='cmig-err'; st.textContent='⚠ '+((j&&j.error)||'저장 실패'); }
                  return;
                }
                intgLoad();
              })
              .catch(function(){ if(st){ st.className='cmig-err'; st.textContent='⚠ 저장 요청 실패'; } })
              .finally(function(){ if(btn) btn.disabled=false; });
          };
          window.cmIntgClear=function(id){
            if(!confirm('이 연동 키를 키체인에서 삭제할까요?')) return;
            fetch('/api/integrations/key/clear',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({id:id})}).then(function(){ intgLoad(); }).catch(function(){});
          };
          // 연결 테스트 — 실제 API를 한 번 호출한다. 사용자가 눌렀을 때만 돈다.
          window.cmIntgTest=function(ids,btn){
            var label=btn?btn.textContent:'';
            if(btn){ btn.disabled=true; btn.textContent='확인 중…'; }
            fetch('/api/integrations/check',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({ids:ids||[]})})
              .then(function(r){return r.json();})
              .then(function(){ intgLoad(); })
              .catch(function(){})
              .finally(function(){ if(btn){ btn.disabled=false; btn.textContent=label; } });
          };
          /* ===== MCP 연동 섹션 =====
             LLM 섹션과 같은 카드 골격을 쓰되, 카드 본문이 '자격증명 한 줄'이 아니라
             '인스턴스 목록 + 추가 폼'이다. 값은 언제나 서버에서 온 것만 그린다 —
             저장 성공 여부를 화면이 낙관적으로 먼저 반영하면, 실패했을 때 사용자는
             등록된 줄 알고 그다음 단계(MCP 등록)로 넘어간다. */
          var _mcpAll=false;                 // 연동 안 된 제공자까지 펼쳐 보기
          var _mcpOpen={};                   // 제공자 카드 펼침 상태
          var _mcpAddOpen={};                // 인스턴스 추가 폼 펼침 상태 (credId별)
          var _mcpMode={};                   // 추가 폼에서 고른 인증 방식 (credId별)
          // 지금 고른 방식. 아직 안 골랐으면 첫 번째(=토큰) — 예전 화면과 같은 자리다.
          function mcpMode(c){
            var opts=c.authOptions||[];
            if(!opts.length) return null;
            var want=_mcpMode[c.id];
            for(var i=0;i<opts.length;i++){ if(opts[i].id===want) return opts[i]; }
            return opts[0];
          }
          function mcpInputVal(id){ var e=document.getElementById(id); return e?(e.value||'').trim():''; }
          function mcpSay(id,cls,msg){
            var st=document.getElementById(id); if(!st) return;
            st.className=cls; st.textContent=msg;
          }
          /* MCP 서버의 실검사 상태. 등록됨과 명확히 구분한다 — 등록은 설정 파일에
             줄 하나를 넣는 일이라 언제나 성공하고, 그것만으로는 붙는지 알 수 없다.
             확인하지 않은 상태를 주황으로 남겨 두는 것이 요점이다: '아직 확인 안 함'과
             '확인했고 된다'가 같은 색이면 사용자는 둘을 구분할 수 없다. */
          function mcpTestPill(inst){
            var pr=inst.probe;
            if(pr&&(pr.phase==='starting'||pr.phase==='auth'||pr.phase==='handshake'||pr.phase==='verify')){
              return ['busy', pr.phase==='auth'?'승인 대기 중'
                             :(pr.phase==='verify'?'테스트 페이지 만드는 중':'연결 확인 중')];
            }
            // 실패는 등록 여부보다 먼저 말한다 — 등록 안 된 인스턴스를 테스트해서
            // 실패했는데 '등록 안 됨'만 뜨면, 방금 확인한 실패가 화면에서 사라진다.
            if(inst.testedAt&&!inst.testOk) return ['warn','테스트 실패'];
            if(!inst.mcpRegistered) return inst.testedAt?['off','테스트됨 · 미등록']:['off','등록 안 됨'];
            if(!inst.testedAt) return ['warn','테스트 안 됨'];
            return ['on','테스트 완료'+(inst.testNote?(' · '+inst.testNote):'')];
          }
          // 검사가 지금 무엇을 기다리는지 한 줄. 진행 중이 아니면 마지막 결과를 말한다.
          function mcpTestNote(inst){
            var pr=inst.probe;
            if(pr&&pr.phase==='auth') return pr.detail||'브라우저에서 승인을 완료하세요';
            if(pr&&(pr.phase==='starting'||pr.phase==='handshake'||pr.phase==='verify')) return pr.detail||'확인 중…';
            if(pr&&pr.phase==='error'&&!inst.testOk) return '⚠ '+(pr.error||'연결하지 못했습니다');
            if(inst.mcpRegistered&&!inst.testedAt){
              return '등록만 되어 있습니다 — 테스트를 눌러야 실제로 붙는지 확인됩니다';
            }
            if(inst.testedAt&&!inst.testOk) return '⚠ '+(inst.testNote||'연결하지 못했습니다');
            // 붙기는 했는데 흔적을 못 남긴 경우 — 읽기 전용 토큰이면 여기서 갈린다.
            if(inst.testedAt&&inst.testOk&&!inst.testUrl&&(pr&&pr.phase==='ok'&&pr.detail)){
              if(pr.detail.indexOf('확인 페이지')>=0) return pr.detail;
            }
            return '';
          }
          // 인스턴스 한 줄. 상태 필은 자격증명 한 줄(intgPill)과 같은 사다리를 쓴다.
          function mcpInstHtml(c,inst){
            // 브라우저 승인 인스턴스는 검사할 토큰이 없다 — 상태 사다리가 다르다.
            // 저 줄의 유일한 진실은 '서버가 실제로 붙었나'이므로 검사 상태를 그대로 쓴다.
            var oauth=(inst.needsToken===false);
            var pill=oauth?mcpTestPill(inst):intgPill(inst);
            var stId='cmmc-st-'+c.id+'-'+inst.key;
            var h='<div class="cmig-row"><div class="cmig-top">'
              +'<span class="cmig-nm">'+esc2(inst.label)+'</span>'
              +(((c.authOptions||[]).length>1&&inst.modeName)
                ?('<span class="cmpl-chip type">'+esc2(inst.modeName)+'</span>'):'')
              +(inst.masked?('<span class="cmig-mask">'+esc2(inst.masked)+'</span>'):'')
              +'<span class="cmpl-pill '+pill[0]+'" id="cmmc-pill-'+esc2(c.id)+'-'+esc2(inst.key)+'"'
              +' data-oauth="'+(oauth?'1':'0')+'" style="margin-left:auto">'+pill[1]+'</span></div>';
            if(inst.detail) h+='<div class="cmig-det">'+esc2(inst.detail)+'</div>';
            if(inst.error) h+='<div class="cmig-err">⚠ '+esc2(inst.error)+'</div>';
            // 비밀 아닌 필드(지라 사이트·이메일)는 그대로 보이고 그 자리에서 고친다.
            if((c.fields||[]).length){
              h+='<div class="cmig-fields">';
              (c.fields||[]).forEach(function(f){
                var v=(inst.fields||{})[f.key]||'';
                h+='<label>'+esc2(f.label)
                  +'<input id="cmmc-f-'+esc2(c.id)+'-'+esc2(inst.key)+'-'+esc2(f.key)+'"'
                  +' type="text" autocomplete="off" spellcheck="false" value="'+escAttr(v)+'"'
                  +' placeholder="'+escAttr(f.placeholder||'')+'"></label>';
              });
              h+='</div>';
            }
            if(oauth){
              // 붙여넣을 것이 없으므로 칸을 그리지 않는다. 빈 토큰 칸을 남겨 두면
              // 사용자는 '아직 뭔가 넣어야 하나'에서 멈춘다.
              h+='<div class="cmig-hint" style="margin-top:6px">'+esc2(inst.modeHint||'')+'</div>'
                +'<div class="cmig-in">'
                +'<button class="cmpl-btn danger" onclick="cmMcpRemove(\''+esc2(c.id)+'\',\''+esc2(inst.key)+'\',\''+escAttr(inst.label)+'\')">삭제</button>'
                +'</div>';
            } else {
              h+='<div class="cmig-in">'
                +'<input id="cmmc-t-'+esc2(c.id)+'-'+esc2(inst.key)+'" type="password" autocomplete="off"'
                +' spellcheck="false" placeholder="'+escAttr(inst.present?'새 토큰으로 교체하려면 붙여넣기':'토큰 붙여넣기')+'">'
                +'<button class="cmpl-btn cmpl-pri" onclick="cmMcpSave(\''+esc2(c.id)+'\',\''+esc2(inst.key)+'\',this)">저장</button>'
                +'<button class="cmpl-btn" onclick="cmIntgTest([\''+esc2(inst.id)+'\'],this)">연결 테스트</button>'
                +'<button class="cmpl-btn danger" onclick="cmMcpRemove(\''+esc2(c.id)+'\',\''+esc2(inst.key)+'\',\''+escAttr(inst.label)+'\')">삭제</button>'
                +'</div>';
            }
            // 등록 스위치 — 실제 등록 여부(mcpRegistered)를 그린다. 앱이 기억하는
            // '켜 뒀다'(mcpWanted)와 다르면 그 사실을 그대로 말한다.
            if(c.mcp){
              var drift=inst.mcpWanted&&!inst.mcpRegistered;
              var tp=mcpTestPill(inst), note=mcpTestNote(inst);
              var busy=(tp[0]==='busy');
              h+='<div class="cmig-mcp"><label><input type="checkbox" '+(inst.mcpRegistered?'checked':'')
                +' onchange="cmMcpRegister(\''+esc2(c.id)+'\',\''+esc2(inst.key)+'\',this)"> MCP 등록</label>'
                +'<span class="pd">'+esc2(inst.mcpName||'')+'</span>'
                +'<span class="pd" style="margin-left:auto">'
                +esc2(inst.mcpSummary||(c.mcp&&c.mcp.summary)||'')+'</span></div>';
              // 등록과 테스트는 다른 일이므로 버튼도 따로 둔다. 테스트를 눌러야만
              // '붙는다'가 사실이 되고, 그 전까지는 주황으로 남는다.
              h+='<div class="cmig-test">'
                +'<button class="cmpl-btn'+(busy?'':' cmpl-pri')+'" '+(busy?'disabled ':'')
                +'onclick="cmMcpProbe(\''+esc2(c.id)+'\',\''+esc2(inst.key)+'\',this)">'
                +(busy?'확인 중…':(inst.testedAt?'다시 테스트':'MCP 테스트'))+'</button>'
                +'<span class="cmpl-pill '+tp[0]+'" id="cmmc-tp-'+esc2(c.id)+'-'+esc2(inst.key)+'">'+tp[1]+'</span>'
                // 검사가 남긴 흔적. 숫자가 아니라 이 링크가 증거다 — 눌러서 보이면
                // 그 워크스페이스에 실제로 닿았다는 뜻이고, 그것 말고 확인할 방법이 없다.
                +(inst.testUrl?('<a class="cmpl-btn" href="'+escAttr(inst.testUrl)+'"'
                  +' target="_blank" rel="noopener">테스트 페이지 열기 ↗</a>'):'')
                +(inst.testedAt?('<span class="pd">'+esc2(cmMcpWhen(inst.testedAt))+'</span>'):'')
                +'</div>'
                +'<div class="cmig-'+(note.indexOf('⚠')===0?'err':'det')+'" id="cmmc-prog-'
                +esc2(c.id)+'-'+esc2(inst.key)+'">'+esc2(note)+'</div>';
              if(drift) h+='<div class="cmig-err">⚠ 켜 두었지만 claude 설정에 없습니다 — 스위치를 다시 켜면 재등록합니다</div>';
            }
            return h+'<div class="cmig-st" id="'+stId+'"></div></div>';
          }
          // 추가 폼. 토큰까지 한 번에 받는다 — 만들고 다시 키를 넣는 두 단계로 나누면
          // 값 없는 껍데기 인스턴스가 목록에 남는다.
          function mcpAddHtml(c){
            var open=!!_mcpAddOpen[c.id];
            if(!open){
              return '<div class="cmig-row cmig-add"><div class="cmig-in">'
                +'<button class="cmpl-btn cmpl-pri" onclick="cmMcpAddToggle(\''+esc2(c.id)+'\')">인스턴스 추가</button>'
                +'<span class="cmig-hint" style="margin:0">계정·조직·사이트마다 하나씩 — 이름을 붙여 구분합니다</span>'
                +'</div></div>';
            }
            // 방식을 먼저 고른다 — 아래 폼의 모양이 여기서 갈린다(토큰 칸의 유무).
            // 이걸 안 물으면, 브라우저로 붙이려는 사람에게 키부터 내놓으라고 하게 된다.
            var opts=c.authOptions||[];
            var mode=mcpMode(c);
            var h='<div class="cmig-row cmig-add"><div class="cmig-top">'
              +'<span class="cmig-nm">인스턴스 추가</span></div>';
            if(opts.length>1){
              h+='<div class="cmig-modes">'
                +opts.map(function(o){
                  return '<button class="cmpl-btn'+((mode&&o.id===mode.id)?' cmpl-pri':'')+'"'
                    +' onclick="cmMcpModePick(\''+esc2(c.id)+'\',\''+esc2(o.id)+'\')">'
                    +esc2(o.name)+'</button>';
                }).join('')
                +'</div>'
                +'<div class="cmig-det">'+esc2((mode&&mode.desc)||'')+'</div>';
            }
            h+='<div class="cmig-fields"><label>이름'
              +'<input id="cmmc-n-'+esc2(c.id)+'" type="text" autocomplete="off" placeholder="예: 개인 계정 · MUST 조직"></label>'
              // MCP 서버 이름은 영문만 쓸 수 있다 — 한글 이름만 넣으면 자동 슬러그가
              // 남지 않으므로(cm-github-inst) 여기서 직접 줄 수 있게 열어 둔다.
              +(c.mcp?('<label>MCP 서버 이름 (영문, 비우면 자동)'
                +'<input id="cmmc-s-'+esc2(c.id)+'" type="text" autocomplete="off" spellcheck="false"'
                +' placeholder="예: personal · must"></label>'):'');
            (c.fields||[]).forEach(function(f){
              h+='<label>'+esc2(f.label)+'<input id="cmmc-nf-'+esc2(c.id)+'-'+esc2(f.key)+'"'
                +' type="text" autocomplete="off" spellcheck="false" placeholder="'+escAttr(f.placeholder||'')+'"></label>';
            });
            var needsToken=!mode||mode.needsToken!==false;
            h+='</div><div class="cmig-in">'
              +(needsToken?('<input id="cmmc-nt-'+esc2(c.id)+'" type="password" autocomplete="off" spellcheck="false"'
                +' placeholder="'+escAttr(c.placeholder||'토큰 붙여넣기')+'">'):'')
              +'<button class="cmpl-btn cmpl-pri" onclick="cmMcpAdd(\''+esc2(c.id)+'\',this)">추가</button>'
              +'<button class="cmpl-btn" onclick="cmMcpAddToggle(\''+esc2(c.id)+'\')">취소</button></div>';
            // 안내는 방식마다 다르다 — 토큰은 발급 경로가, OAuth는 승인이 언제
            // 일어나는지가 사용자가 다음에 할 일이다.
            var hint=esc2((mode&&mode.hint)||c.issueHint||'');
            if(needsToken&&c.issueURL) hint+=(hint?' · ':'')+'<a href="'+escAttr(c.issueURL)+'" target="_blank" rel="noopener">발급 페이지 열기 ↗</a>';
            if(hint) h+='<div class="cmig-hint">'+hint+'</div>';
            return h+'<div class="cmig-st" id="cmmc-nst-'+esc2(c.id)+'"></div></div>';
          }
          window.cmMcpToggleAll=function(){ _mcpAll=!_mcpAll; cmMcpRender(); };
          window.cmMcpProvToggle=function(id){ _mcpOpen[id]=!_mcpOpen[id]; cmMcpRender(); };
          window.cmMcpAddToggle=function(credId){ _mcpAddOpen[credId]=!_mcpAddOpen[credId]; cmMcpRender(); };
          window.cmMcpModePick=function(credId,mode){ _mcpMode[credId]=mode; cmMcpRender(); };
          // 마지막 확인 시각은 '얼마나 지났나'로만 쓴다 — 경과 시간은 표시 시간대와
          // 무관해서, 시간대 설정이 무엇이든 같은 문장이 된다.
          window.cmMcpWhen=function(ts){
            if(!ts) return '';
            var s=Math.max(0,Math.floor(Date.now()/1000-ts));
            if(s<60) return '방금 확인';
            if(s<3600) return Math.floor(s/60)+'분 전 확인';
            if(s<86400) return Math.floor(s/3600)+'시간 전 확인';
            return Math.floor(s/86400)+'일 전 확인';
          };
          /* 실검사 — 서버를 실제로 띄워 핸드셰이크까지 해 본다. 오래 걸릴 수 있어서
             (승인은 사람이 브라우저에서 하는 일이다) 시작만 시키고 상태를 폴링한다.
             폴링 중에는 그 두 칸만 갈아 끼운다: 전체를 다시 그리면 옆에서 입력 중인
             칸이 날아간다. */
          var _mcpPoll={};
          window.cmMcpProbe=function(credId,key,btn){
            if(btn){ btn.disabled=true; btn.textContent='확인 중…'; }
            mcpProbeSay(credId,key,'busy','연결 확인 중','서버를 띄우는 중…',false);
            fetch('/api/integrations/mcp/probe',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({credId:credId,key:key})})
              .then(function(r){return r.json();})
              .then(function(j){
                if(!j||!j.ok){
                  mcpProbeSay(credId,key,'warn','테스트 실패',(j&&j.error)||'검사를 시작하지 못했습니다',true);
                  if(btn){ btn.disabled=false; btn.textContent='MCP 테스트'; }
                  return;
                }
                cmMcpPollStart(credId,key);
              })
              .catch(function(){
                mcpProbeSay(credId,key,'warn','테스트 실패','검사 요청 실패',true);
                if(btn){ btn.disabled=false; btn.textContent='MCP 테스트'; }
              });
          };
          function mcpProbeSay(credId,key,cls,pillText,note,isErr){
            var p=document.getElementById('cmmc-tp-'+credId+'-'+key);
            if(p){ p.className='cmpl-pill '+cls; p.textContent=pillText; }
            var top=document.getElementById('cmmc-pill-'+credId+'-'+key);
            // 위쪽 필은 OAuth 인스턴스에서만 검사 상태를 그린다 (토큰 쪽은 토큰 상태다).
            if(top&&top.getAttribute('data-oauth')==='1'){ top.className='cmpl-pill '+cls; top.textContent=pillText; }
            var g=document.getElementById('cmmc-prog-'+credId+'-'+key);
            if(g){ g.className=isErr?'cmig-err':'cmig-det'; g.textContent=note||''; }
          }
          window.cmMcpPollStart=function(credId,key){
            var id=credId+'-'+key;
            if(_mcpPoll[id]) return;
            _mcpPoll[id]=setInterval(function(){
              fetch('/api/integrations/mcp/probe/state',{method:'POST',headers:{'Content-Type':'application/json'},
                body:JSON.stringify({credId:credId,key:key})})
                .then(function(r){return r.json();})
                .then(function(j){
                  if(!j||!j.ok) return;
                  if(j.phase==='auth'){
                    mcpProbeSay(credId,key,'busy','승인 대기 중',
                      j.detail||'브라우저에서 승인을 완료하세요',false);
                    return;
                  }
                  if(j.phase==='starting'||j.phase==='handshake'){
                    mcpProbeSay(credId,key,'busy','연결 확인 중',j.detail||'확인 중…',false);
                    return;
                  }
                  // 도구를 실제로 한 번 부르는 중 — 여기가 끝나야 사용자가 열어 볼
                  // 링크가 생긴다. 그냥 '확인 중'으로 뭉뚱그리면 왜 더 걸리는지 모른다.
                  if(j.phase==='verify'){
                    mcpProbeSay(credId,key,'busy','테스트 페이지 만드는 중',
                      j.detail||'도구를 실제로 호출하는 중…',false);
                    return;
                  }
                  // 끝났다 — 결과는 서버가 인스턴스에 적어 뒀으므로 전체를 다시 읽는다.
                  clearInterval(_mcpPoll[id]); delete _mcpPoll[id];
                  intgLoad();
                })
                .catch(function(){});
            },800);
          };
          // 저장 = 라벨·필드 + (있으면) 새 토큰. 서버가 저장·검사·MCP 갱신까지 한 번에 한다.
          window.cmMcpSave=function(credId,key,btn){
            var c=intgCred(credId); if(!c) return;
            var fields={};
            (c.fields||[]).forEach(function(f){ fields[f.key]=mcpInputVal('cmmc-f-'+credId+'-'+key+'-'+f.key); });
            var stId='cmmc-st-'+credId+'-'+key;
            if(btn) btn.disabled=true;
            mcpSay(stId,'cmig-det','저장하고 연결을 확인하는 중…');
            var inst=null;
            (c.instances||[]).forEach(function(x){ if(x.key===key) inst=x; });
            fetch('/api/integrations/instance',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({credId:credId,key:key,label:(inst&&inst.label)||key,
                                   fields:fields,value:mcpInputVal('cmmc-t-'+credId+'-'+key)})})
              .then(function(r){return r.json();})
              .then(function(j){
                var t=document.getElementById('cmmc-t-'+credId+'-'+key); if(t) t.value='';
                if(!j||!j.ok){ mcpSay(stId,'cmig-err','⚠ '+((j&&j.error)||'저장 실패')); return; }
                intgLoad();
              })
              .catch(function(){ mcpSay(stId,'cmig-err','⚠ 저장 요청 실패'); })
              .finally(function(){ if(btn) btn.disabled=false; });
          };
          window.cmMcpAdd=function(credId,btn){
            var c=intgCred(credId); if(!c) return;
            var fields={};
            (c.fields||[]).forEach(function(f){ fields[f.key]=mcpInputVal('cmmc-nf-'+credId+'-'+f.key); });
            var stId='cmmc-nst-'+credId;
            var label=mcpInputVal('cmmc-n-'+credId);
            if(!label){ mcpSay(stId,'cmig-err','⚠ 이름을 입력하세요'); return; }
            if(btn) btn.disabled=true;
            mcpSay(stId,'cmig-det','만들고 연결을 확인하는 중…');
            var mode=mcpMode(c);
            fetch('/api/integrations/instance',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({credId:credId,label:label,slug:mcpInputVal('cmmc-s-'+credId),
                                   authMode:(mode&&mode.id)||'',
                                   fields:fields,value:mcpInputVal('cmmc-nt-'+credId)})})
              .then(function(r){return r.json();})
              .then(function(j){
                var t=document.getElementById('cmmc-nt-'+credId); if(t) t.value='';
                if(!j||!j.ok){ mcpSay(stId,'cmig-err','⚠ '+((j&&j.error)||'추가 실패')); return; }
                _mcpAddOpen[credId]=false;
                intgLoad();
              })
              .catch(function(){ mcpSay(stId,'cmig-err','⚠ 추가 요청 실패'); })
              .finally(function(){ if(btn) btn.disabled=false; });
          };
          window.cmMcpRemove=function(credId,key,label){
            if(!confirm('['+label+'] 인스턴스를 삭제할까요? 키체인의 토큰과 MCP 등록도 함께 지워집니다.')) return;
            fetch('/api/integrations/instance/remove',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({credId:credId,key:key})})
              .then(function(){ intgLoad(); }).catch(function(){});
          };
          // 등록 스위치는 실패하면 원래 자리로 되돌린다 — 체크만 켜진 채 등록이 안 된
          // 상태로 두면 화면이 거짓말을 한다.
          window.cmMcpRegister=function(credId,key,el){
            var want=!!(el&&el.checked);
            var stId='cmmc-st-'+credId+'-'+key;
            if(el) el.disabled=true;
            mcpSay(stId,'cmig-det',want?'claude에 등록하는 중…':'등록을 해제하는 중…');
            fetch('/api/integrations/mcp',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({credId:credId,key:key,on:want})})
              .then(function(r){return r.json();})
              .then(function(j){
                if(!j||!j.ok){
                  if(el) el.checked=!want;
                  mcpSay(stId,'cmig-err','⚠ '+((j&&j.error)||'등록 실패'));
                  return;
                }
                // 켰으면 서버가 곧바로 실검사를 시작한다 — 승인이 필요한 방식이면
                // 지금 브라우저 창이 뜬다. 그 사실을 말하고 진행을 따라간다.
                mcpSay(stId,'cmig-det',want
                  ? ('등록했습니다 ('+(j.name||'')+') — 실제로 붙는지 확인하는 중입니다')
                  : '등록을 해제했습니다');
                if(want&&j.probing){
                  mcpProbeSay(credId,key,'busy','연결 확인 중','서버를 띄우는 중…',false);
                  cmMcpPollStart(credId,key);
                }
                intgLoad();
              })
              .catch(function(){ if(el) el.checked=!want; mcpSay(stId,'cmig-err','⚠ 등록 요청 실패'); })
              .finally(function(){ if(el) el.disabled=false; });
          };
          window.cmMcpRender=function(){
            var box=document.getElementById('cmMcpList'); if(!box) return;
            var si=document.getElementById('cmSkSearch'); var q=((si&&si.value)||'').trim().toLowerCase();
            var all=(_intg.providers||[]).filter(function(p){ return p.section==='mcp'; });
            var live=all.filter(function(p){ return p.connected; });
            var list=(_mcpAll?all:live).filter(function(p){ if(!q) return true;
              return (p.name||'').toLowerCase().indexOf(q)>=0||(p.desc||'').toLowerCase().indexOf(q)>=0; });
            var regd=0;
            all.forEach(function(p){ regd+=(p.mcpCount||0); });
            var cnt=document.getElementById('cmMcpCount');
            if(cnt) cnt.textContent='· 연결 '+live.length+' / '+all.length+' · 등록 '+regd;
            var ab=document.getElementById('cmMcpAddBtn');
            if(ab) ab.textContent=_mcpAll?'연동된 것만 보기':'연동 추가';
            if(!list.length){
              box.innerHTML='<div class="cmsk-empty">'
                +(q?'검색 결과가 없습니다':'연동된 MCP가 없습니다 — \'연동 추가\'로 토큰을 등록하세요')+'</div>';
              return;
            }
            box.innerHTML='';
            list.forEach(function(p){
              var creds=(p.credentials||[]).map(intgCred).filter(Boolean);
              var bad=creds.some(function(c){
                return (c.instances||[]).some(function(i){ return i.state==='fail'; }); });
              var pill=p.connected?(bad?['warn','일부 실패']:['on','연결됨']):['off','연동 안 됨'];
              var body='';
              creds.forEach(function(c){
                if(!c.multi){ body+=intgCredRow(c); return; }
                (c.instances||[]).forEach(function(inst){
                  body+=mcpInstHtml(c,inst);
                  // 페이지를 새로 열었는데 검사가 아직 돌고 있으면 폴링을 이어붙인다 —
                  // 안 그러면 스피너가 켜진 채 영원히 멈춰 있는다.
                  var ph=inst.probe&&inst.probe.phase;
                  if(ph==='starting'||ph==='auth'||ph==='handshake') cmMcpPollStart(c.id,inst.key);
                });
                body+=mcpAddHtml(c);
              });
              var card=document.createElement('div');
              card.className='cmpl-card'+(_mcpOpen[p.id]?' open':'');
              card.innerHTML='<div class="cmpl-head" onclick="cmMcpProvToggle(\''+esc2(p.id)+'\')">'
                +'<span class="nm">'+esc2(p.name)+'</span>'
                +'<span class="cmpl-chip type">'+(p.instanceCount||0)+'개'+'</span>'
                +((p.mcpCount||0)?('<span class="cmpl-chip opt">MCP 등록 '+p.mcpCount+'</span>'):'')
                +'<div class="right"><span class="cmpl-pill '+pill[0]+'">'+pill[1]+'</span>'
                +'<span class="caret">▶</span></div></div>'
                +'<div class="cmpl-sm">'+esc2(p.desc||'')+'</div>'
                +'<div class="cmpl-body" onclick="event.stopPropagation()">'+body+'</div>';
              box.appendChild(card);
            });
          };
          window.cmLlmToggleAll=function(){ _llmAll=!_llmAll; cmLlmRender(); };
          window.cmLlmProvToggle=function(id){ _llmOpen[id]=!_llmOpen[id]; cmLlmRender(); };
          // 플러그인 카드의 '연동으로 이동' — 같은 화면 안에서 섹션으로 스크롤한다.
          window.cmLlmFocus=function(){
            _llmAll=true; cmLlmRender();
            var box=document.getElementById('cmLlmList');
            if(box) box.scrollIntoView({behavior:'smooth',block:'center'});
          };
          // LLM 연동 섹션. 모델이 워낙 많으니 기본은 연동된 것만 — 나머지는 '연동 추가'.
          window.cmLlmRender=function(){
            var box=document.getElementById('cmLlmList'); if(!box) return;
            var si=document.getElementById('cmSkSearch'); var q=((si&&si.value)||'').trim().toLowerCase();
            var all=(_intg.providers||[]).filter(function(p){ return p.isLLM; });
            var live=all.filter(function(p){ return p.connected; });
            var list=(_llmAll?all:live).filter(function(p){ if(!q) return true;
              return (p.name||'').toLowerCase().indexOf(q)>=0||(p.desc||'').toLowerCase().indexOf(q)>=0; });
            var cnt=document.getElementById('cmLlmCount');
            if(cnt) cnt.textContent='· 연결 '+live.length+' / '+all.length;
            var ab=document.getElementById('cmLlmAddBtn');
            if(ab) ab.textContent=_llmAll?'연동된 것만 보기':'연동 추가';
            if(!list.length){
              box.innerHTML='<div class="cmsk-empty">'
                +(q?'검색 결과가 없습니다':'연동된 LLM이 없습니다 — \'연동 추가\'로 키를 등록하세요')+'</div>';
              return;
            }
            box.innerHTML='';
            list.forEach(function(p){
              var creds=(p.credentials||[]).map(intgCred).filter(Boolean);
              var bad=p.connected&&creds.some(function(c){ return c.state==='fail'; });
              var pill=p.connected?(bad?['warn','일부 실패']:['on','연결됨']):['off','연동 안 됨'];
              var card=document.createElement('div');
              card.className='cmpl-card'+(_llmOpen[p.id]?' open':'');
              card.innerHTML='<div class="cmpl-head" onclick="cmLlmProvToggle(\''+esc2(p.id)+'\')">'
                +'<span class="nm">'+esc2(p.name)+'</span>'
                +(p.via?('<span class="cmpl-chip type">'+esc2(p.via)+'</span>'):'')
                +'<div class="right"><span class="cmpl-pill '+pill[0]+'">'+pill[1]+'</span>'
                +'<span class="caret">▶</span></div></div>'
                +'<div class="cmpl-sm">'+esc2(p.desc||'')+'</div>'
                +'<div class="cmpl-body" onclick="event.stopPropagation()">'
                +intgCredsHtml(p.credentials)
                +'<div class="cmpl-foot"><button class="cmpl-btn" onclick="cmIntgTest('
                +escAttr(JSON.stringify(p.credentials||[]))+',this)">전체 연결 테스트</button>'
                +'<span class="sp">키 값은 저장 후 다시 표시되지 않습니다</span></div></div>';
              box.appendChild(card);
            });
          };
        })();
        </script>
        <div class="cmag-overlay" id="cmAgOverlay" style="display:none">
          <div class="cmag-panel">
            <div class="cmag-head">
              <div class="cmag-title">에이전트 <span class="cmag-sub">— 목적을 달성하는 책임</span></div>
              <button class="cmag-x" title="닫기 (Esc)" onclick="cmAgClose();if(window.cmNavReflect)cmNavReflect()">✕</button>
            </div>
            <div class="cmag-tools">
              <input class="cmag-search" id="cmAgSearch" type="text" placeholder="에이전트 검색…" oninput="cmAgRender()">
              <span class="cmag-slabel">정렬</span>
              <button class="cmag-sort" data-k="runs" onclick="cmAgSort('runs')">사용수</button>
              <button class="cmag-sort" data-k="rate" onclick="cmAgSort('rate')">성공률</button>
              <button class="cmag-sort" data-k="name" onclick="cmAgSort('name')">이름</button>
              <span class="cmag-count" id="cmAgCount"></span>
            </div>
            <div class="cmag-list" id="cmAgList"></div>
          </div>
        </div>
        <style>
          .cmag-overlay{ position:fixed; top:0; right:0; bottom:0; left:var(--cmrail-w); z-index:81;
            background:#0a0d12; display:flex; flex-direction:column; color:#c8cfdb;
            font:14px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif }
          body.cmrail-collapsed .cmag-overlay{ left:0 }
          .cmag-panel{ flex:1; display:flex; flex-direction:column; min-height:0 }
          /* Top padding clears the native titlebar toggle (대시보드/컨디션 segmented control),
             which is a .right titlebar accessory floating over this web content under
             fullSizeContentView — same reason the rail brand starts at 40px (see .cmrail-brand).
             Without it the ✕ close button sits directly under the toggle and reads as broken. */
          .cmag-head{ display:flex; align-items:center; gap:12px; padding:40px 20px 16px; border-bottom:1px solid #1c2432 }
          .cmag-title{ font-size:16px; font-weight:600; color:#e6e9ef }
          .cmag-title .cmag-sub{ color:#6b7589; font-weight:400; font-size:13px }
          .cmag-x{ margin-left:auto; background:transparent; border:0; color:#8b93a3; font-size:16px; cursor:pointer }
          .cmag-tools{ display:flex; align-items:center; gap:8px; padding:10px 20px; border-bottom:1px solid #1c2432; flex-wrap:wrap }
          .cmag-search{ flex:1; min-width:160px; background:#11151d; border:1px solid #263149; border-radius:8px;
            color:#c8cfdb; padding:7px 12px; font-size:13px; outline:none }
          .cmag-search:focus{ border-color:#33406a } .cmag-search::placeholder{ color:#5a6376 }
          .cmag-slabel{ color:#6b7589; font-size:12px; margin-left:4px }
          .cmag-sort{ background:#161c2a; border:1px solid #263149; color:#8b93a3; border-radius:8px;
            padding:6px 12px; cursor:pointer; font-size:12px }
          .cmag-sort.on{ color:#e6e9ef; border-color:#33406a; background:#1a2336 }
          .cmag-count{ color:#6b7589; font-size:12px; margin-left:4px }
          .cmag-list{ flex:1; overflow:auto; padding:16px 20px; display:flex; flex-direction:column; gap:14px }
          .cmag-card{ background:#11151d; border:1px solid #1e2836; border-radius:12px; padding:16px 18px }
          .cmag-crow{ display:flex; align-items:center; gap:10px }
          .cmag-nm{ font-size:15px; font-weight:600; color:#e6e9ef }
          .cmag-active{ font-size:11px; padding:2px 8px; border-radius:20px; background:#241a30; color:#a371f7; border:1px solid #33265a }
          .cmag-purpose{ color:#9aa4b6; font-size:13px; margin:6px 0 12px }
          .cmag-resp{ display:flex; align-items:center; gap:16px; margin-bottom:6px; flex-wrap:wrap }
          .cmag-metric{ font-size:26px; font-weight:700; line-height:1 }
          .cmag-badge{ font-size:12px; padding:3px 10px; border-radius:20px }
          .cmag-badge.ok{ background:#12281a; color:#3fb950; border:1px solid #1c4128 }
          .cmag-badge.warn{ background:#2a1d12; color:#d29922; border:1px solid #4a3410 }
          .cmag-stat{ color:#8b93a3; font-size:12px }
          .cmag-time{ display:flex; gap:3px; margin:10px 0 2px; flex-wrap:wrap }
          .cmag-dot{ width:9px; height:9px; border-radius:2px; background:#33405a }
          .cmag-dot.ok{ background:#3fb950 } .cmag-dot.no{ background:#f85149 }
          .cmag-vers{ margin-top:10px; border-top:1px solid #1a2230; padding-top:12px }
          .cmag-vlabel{ font-size:11px; color:#6b7589; text-transform:uppercase; letter-spacing:.05em; margin-bottom:8px }
          .cmag-vrow{ display:flex; align-items:center; gap:10px; font-size:13px; margin-bottom:6px }
          .cmag-vname{ width:150px; color:#c8cfdb; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmag-vrow.act .cmag-vname{ color:#a371f7; font-weight:600 }
          .cmag-vbar{ flex:1; height:6px; background:#1a2230; border-radius:4px; overflow:hidden }
          .cmag-vbar>i{ display:block; height:100%; background:#3fb950 }
          .cmag-vnum{ width:130px; text-align:right; color:#8b93a3; font-size:12px }
          .cmag-retro{ margin-top:10px; padding:10px 12px; background:#0f1620; border-radius:8px; color:#9aa4b6; font-size:12px; white-space:pre-wrap }
          .cmag-hist{ margin-top:10px; border-top:1px solid #1a2230; padding-top:12px }
          .cmag-hlabel{ font-size:11px; color:#6b7589; text-transform:uppercase; letter-spacing:.05em; margin-bottom:8px }
          .cmag-hrow{ display:flex; gap:10px; font-size:12px; margin-bottom:7px }
          .cmag-hts{ color:#8b93a3; white-space:nowrap; min-width:92px }
          .cmag-hmodel{ color:#a371f7 }
          .cmag-htabs{ display:flex; gap:6px; margin-bottom:10px }
          .cmag-htab{ background:transparent; border:0; border-bottom:2px solid transparent; color:#6b7589;
            font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:.05em;
            padding:2px 2px 6px; cursor:pointer }
          .cmag-htab.on{ color:#e6e9ef; border-bottom-color:#a371f7 }
          .cmag-fempty{ color:#6b7589; font-size:12px; padding:4px 0 }
          .cmag-fsum{ color:#8b93a3; font-size:12px; margin-bottom:9px }
          .cmag-fhint{ margin-left:8px; color:#d29922; background:#2a1d12; border:1px solid #4a3410;
            border-radius:20px; padding:1px 8px; font-size:11px }
          .cmag-frow{ padding:8px 0; border-top:1px solid #141b26 } .cmag-frow:first-of-type{ border-top:0 }
          .cmag-fhd{ display:flex; align-items:center; gap:9px; flex-wrap:wrap }
          .cmag-fnm{ color:#c8cfdb; font-size:13px; font-weight:600 }
          .cmag-fcnt{ color:#e6e9ef; background:#1a2336; border:1px solid #263149; border-radius:20px;
            padding:1px 9px; font-size:12px; font-weight:600 }
          .cmag-fb{ font-size:11px; padding:1px 9px; border-radius:20px }
          .cmag-fb.ok{ background:#12281a; color:#3fb950; border:1px solid #1c4128 }
          .cmag-fb.mid{ background:#20242e; color:#8b93a3; border:1px solid #2c3444 }
          .cmag-fb.bad{ background:#2a1416; color:#f85149; border:1px solid #4a1f22 }
          .cmag-fnote{ color:#8b93a3; font-size:12px; margin-top:4px; overflow:hidden; text-overflow:ellipsis }
          .cmag-hdesc{ color:#9aa4b6; overflow:hidden; text-overflow:ellipsis }
          .cmag-act{ margin-top:12px; display:flex; align-items:center; gap:10px } .cmag-act button{ background:#161c2a; border:1px solid #263149;
            color:#c8cfdb; border-radius:8px; padding:6px 12px; cursor:pointer; font-size:12px }
          .cmag-path{ color:#6b7589; font-size:12px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace }
          .cmag-empty{ color:#6b7589; padding:40px; text-align:center }
          /* collapsible list */
          .cmag-list{ gap:8px }
          .cmag-item{ background:#11151d; border:1px solid #1e2836; border-radius:12px; overflow:hidden }
          .cmag-item.open{ border-color:#2a3852 }
          .cmag-row{ display:flex; align-items:center; gap:10px; padding:12px 16px; cursor:pointer }
          .cmag-row:hover{ background:#141a25 }
          .cmag-caret{ color:#6b7589; font-size:10px; width:12px; text-align:center; flex:none }
          .cmag-sdot{ width:9px; height:9px; border-radius:50%; flex:none }
          .cmag-row .cmag-nm{ flex:none; white-space:nowrap }
          .cmag-htag{ font-size:11px; padding:1px 8px; border-radius:20px; background:#12281a;
            color:#3fb950; border:1px solid #1c4128; flex:none; white-space:nowrap }
          .cmag-rpurpose{ flex:1; min-width:40px; color:#8b93a3; font-size:12px;
            white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmag-rmetric{ font-size:16px; font-weight:700; line-height:1; flex:none }
          .cmag-rmeta{ color:#6b7589; font-size:11px; white-space:nowrap; flex:none; text-align:right }
          .cmag-body{ padding:14px 16px 16px; border-top:1px solid #1a2230 }
          .cmag-body .cmag-crow{ margin-bottom:0 }
          .cmag-body .cmag-purpose{ margin:8px 0 12px }
        </style>
        <script>
        (function(){
          function esc3(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }
          window.cmAgentsOpen=function(ev){ if(ev) ev.preventDefault();
            if(typeof window.cmSkClose==='function') window.cmSkClose();
            var o=document.getElementById('cmAgOverlay');
            if(o){ o.style.display='flex'; load(); } };
          window.cmAgClose=function(){ var o=document.getElementById('cmAgOverlay'); if(o) o.style.display='none'; };
          function fmtTs(ts){ if(!ts) return '없음'; try{ var d=new Date(ts); if(isNaN(d.getTime())) return ts;
            var p=window.CMTimeFilter.parts(d);
            return p.mo+'/'+p.d+' '+String(p.h).padStart(2,'0')+':'+String(p.mi).padStart(2,'0'); }catch(e){ return ts; } }
          function fmtRel(ts){ if(!ts) return ''; try{ var d=new Date(ts).getTime(); if(isNaN(d)) return '';
            var s=Math.max(0,(Date.now()-d)/1000);
            if(s<60) return '방금'; if(s<3600) return Math.floor(s/60)+'분전';
            if(s<86400) return Math.floor(s/3600)+'시간전'; if(s<2592000) return Math.floor(s/86400)+'일전';
            return Math.floor(s/2592000)+'개월전'; }catch(e){ return ''; } }
          function load(){ var box=document.getElementById('cmAgList'); if(box) box.innerHTML='<div class="cmag-empty">불러오는 중…</div>';
            fetch('/api/agents').then(function(r){return r.json();}).then(render)
            .catch(function(){ if(box) box.innerHTML='<div class="cmag-empty">에이전트를 불러오지 못했습니다</div>'; }); }
          var _ag=[], _agSort='runs', _agDir=-1;   // runs desc / name asc; toggle flips direction
          window.cmAgSort=function(k){ if(_agSort===k){ _agDir=-_agDir; } else { _agSort=k; _agDir=(k==='name'||k==='rate')?1:-1; } cmAgRender(); };
          function agToolsUI(){ var bs=document.querySelectorAll('.cmag-sort');
            for(var i=0;i<bs.length;i++){ var b=bs[i],k=b.getAttribute('data-k'),base=(k==='runs')?'사용수':(k==='rate')?'성공률':'이름';
              if(k===_agSort){ b.classList.add('on'); b.textContent=base+' '+(_agDir<0?'▼':'▲'); }
              else { b.classList.remove('on'); b.textContent=base; } } }
          function render(d){ _ag=(d&&d.agents)||[]; cmAgRender(); }
          window.cmAgRender=function(){ var box=document.getElementById('cmAgList'); if(!box) return;
            agToolsUI();
            var si=document.getElementById('cmAgSearch'); var q=((si&&si.value)||'').trim().toLowerCase();
            var list=_ag.filter(function(a){ if(!q) return true; return ((a.name||'')+' '+(a.desc||'')).toLowerCase().indexOf(q)>=0; });
            list.sort(function(a,b){ if(_agSort==='name') return _agDir*String(a.name||'').localeCompare(String(b.name||''));
              if(_agSort==='rate'){ var ra=(a.runs||0)>0, rb=(b.runs||0)>0;
                if(ra!==rb) return ra?-1:1;   // no-run agents always sink to the bottom
                var rc=((a.recentRate||0)-(b.recentRate||0)); if(rc===0) rc=(a.runs||0)-(b.runs||0);
                if(rc===0) return String(a.name||'').localeCompare(String(b.name||'')); return _agDir*rc; }
              var c=((a.runs||0)-(b.runs||0)); if(c===0) c=String(a.name||'').localeCompare(String(b.name||'')); return _agDir*c; });
            var cnt=document.getElementById('cmAgCount'); if(cnt) cnt.textContent=list.length+'개';
            if(!list.length){ box.innerHTML='<div class="cmag-empty">'+(_ag.length?'검색 결과가 없습니다':'에이전트가 없습니다 — ~/.claude/agents/ 에 .md 에이전트를 두면 여기 나타납니다')+'</div>'; return; }
            box.innerHTML='';
            list.forEach(function(a){
              var rate=Math.round((a.recentRate||0)*100);
              var ran=(a.runs||0)>0;
              var good=ran&&(a.lastOutcome!=='fail')&&(rate>=60);
              var mc=rate>=80?'#3fb950':(rate>=50?'#d29922':'#f85149');
              var dots=(a.recent||[]).slice(-24).map(function(r){
                return '<span class="cmag-dot '+(r.ok?'ok':'no')+'" title="'+esc3(fmtTs(r.ts)+' · '+(r.label||''))+'"></span>'; }).join('');
              var hist=(a.history||[]); var funcs=(a.functions||[]);
              // Tab 1 — 수정 히스토리 (how the agent's own definition evolved).
              var histRows=hist.slice().reverse().slice(0,6).map(function(h){
                  return '<div class="cmag-hrow"><span class="cmag-hts">'+esc3(fmtTs(h.ts))+'</span>'
                    +'<span class="cmag-hdesc"><span class="cmag-hmodel">'+esc3(h.model||'inherit')+'</span> · '+esc3(h.desc||'')+'</span></div>'; }).join('')
                || '<div class="cmag-fempty">기록 없음</div>';
              // Tab 2 — 기능 역할 (which roles it performed, how often, how cleanly).
              var funcHtml='<div class="cmag-fempty">아직 기능 역할 기록이 없습니다 — 에이전트가 원장(agent-update-log.jsonl)에 기록하면 여기 집계됩니다</div>';
              if(funcs.length){
                var totalRuns=funcs.reduce(function(s,f){return s+(f.count||0);},0);
                var frows=funcs.map(function(f){
                  var hasR=(f.avgRounds!=null); var rtxt='', rcls='mid';
                  if(hasR){ var av=Math.round(f.avgRounds*10)/10;
                    rcls=(f.avgRounds<=1.2?'ok':(f.avgRounds>=3?'bad':'mid'));
                    rtxt='평균 '+av+'라운드'+(f.avgRounds<=1.2?' · 한 번에 완수':(f.avgRounds>=3?' · 반복 잦음, 개선 필요':' · 보통'))
                      +((f.maxRounds&&f.maxRounds>1)?(' (최다 '+f.maxRounds+')'):''); }
                  return '<div class="cmag-frow"><div class="cmag-fhd">'
                    +'<span class="cmag-fnm">'+esc3(f.name)+'</span>'
                    +'<span class="cmag-fcnt">'+(f.count||0)+'회</span>'
                    +(hasR?'<span class="cmag-fb '+rcls+'">'+esc3(rtxt)+'</span>':'')
                    +'</div>'+(f.sample?'<div class="cmag-fnote">최근: '+esc3(f.sample)+'</div>':'')+'</div>';
                }).join('');
                var hint=(funcs.length>=4?'<span class="cmag-fhint">역할 '+funcs.length+'종 — 분리 검토</span>':'');
                funcHtml='<div class="cmag-fsum">역할 '+funcs.length+'종 · 총 '+totalRuns+'회 수행'+hint+'</div>'+frows;
              }
              var histHtml='<div class="cmag-hist">'
                +'<div class="cmag-htabs">'
                +'<button class="cmag-htab on" data-p="hist">수정 히스토리 ('+hist.length+')</button>'
                +'<button class="cmag-htab" data-p="func">기능 역할 ('+funcs.length+')</button>'
                +'</div>'
                +'<div class="cmag-hpanel" data-p="hist">'+histRows+'</div>'
                +'<div class="cmag-hpanel" data-p="func" style="display:none">'+funcHtml+'</div>'
                +'</div>';
              var card=document.createElement('div'); card.className='cmag-item';
              card.innerHTML=
                '<div class="cmag-row">'
                  +'<span class="cmag-caret">▸</span>'
                  +'<span class="cmag-sdot" style="background:'+(ran?mc:'#33405a')+'"></span>'
                  +'<span class="cmag-nm">'+esc3(a.name)+'</span>'
                  +(a.harness?'<span class="cmag-htag">'+esc3(a.harness)+'</span>':'')
                  +'<span class="cmag-rpurpose">'+esc3(a.desc||'')+'</span>'
                  +(ran?'<span class="cmag-rmetric" style="color:'+mc+'">'+rate+'%</span>'
                    :'<span class="cmag-rmetric" style="color:#5a6376">—</span>')
                  +'<span class="cmag-rmeta">'+esc3(ran?((a.recentN||0)+'회'+(a.lastTs?' · '+fmtRel(a.lastTs):'')):'기록 없음')+'</span>'
                +'</div>'
                +'<div class="cmag-body" style="display:none">'
                  +'<div class="cmag-crow">'
                    +'<span class="cmag-active">모델 '+esc3(a.model||'inherit')+'</span>'
                    +(a.harness?'<span class="cmag-active" style="background:#12281a;color:#3fb950;border-color:#1c4128">하네스 '+esc3(a.harness)+'</span>':'')+'</div>'
                  +'<div class="cmag-purpose">'+esc3(a.desc||'')+'</div>'
                  +(ran?('<div class="cmag-resp"><span class="cmag-badge '+(good?'ok':'warn')+'">'+(good?'목적 달성 중':'회고 필요')+'</span>'
                    +'<span class="cmag-stat">최근 '+(a.recentN||0)+'회 성공률 · 누적 실행 '+(a.runs||0)+'회 · 마지막 '+fmtTs(a.lastTs)+' ('+(a.lastOutcome==='fail'?'실패':'성공')+')</span></div>')
                    :'<div class="cmag-resp"><span class="cmag-stat">아직 실행 기록 없음</span></div>')
                  +(dots?'<div class="cmag-time">'+dots+'</div>':'')
                  +(a.retro?'<div class="cmag-vers"><div class="cmag-vlabel">회고 (교체 이력)</div><div class="cmag-retro">'+esc3(a.retro)+'</div></div>':'')
                  +histHtml
                  +'<div class="cmag-act"><button class="cmag-open" data-f="'+esc3(a.file)+'">📂 에이전트 파일 열기</button>'
                    +'<span class="cmag-path">agents/'+esc3(a.file)+'</span></div>'
                +'</div>';
              var row=card.querySelector('.cmag-row'), body=card.querySelector('.cmag-body'), caret=card.querySelector('.cmag-caret');
              if(row) row.onclick=function(){ var open=body.style.display==='none';
                body.style.display=open?'block':'none'; if(caret) caret.textContent=open?'▾':'▸'; card.classList.toggle('open',open); };
              var ob=card.querySelector('.cmag-open'); if(ob) ob.onclick=function(e){ e.stopPropagation();
                fetch('/api/agents/reveal',{method:'POST',headers:{'Content-Type':'application/json'},
                  body:JSON.stringify({file:this.dataset.f||''})}).catch(function(){}); };
              var htabs=card.querySelectorAll('.cmag-htab');
              for(var ti=0;ti<htabs.length;ti++){ htabs[ti].onclick=function(){
                var p=this.getAttribute('data-p'), c=this.closest('.cmag-item');
                var bs=c.querySelectorAll('.cmag-htab');
                for(var j=0;j<bs.length;j++) bs[j].classList.toggle('on', bs[j].getAttribute('data-p')===p);
                var ps=c.querySelectorAll('.cmag-hpanel');
                for(var j=0;j<ps.length;j++) ps[j].style.display=(ps[j].getAttribute('data-p')===p)?'block':'none';
              }; }
              box.appendChild(card);
            });
          };
          document.addEventListener('keydown',function(e){ if(e.key==='Escape'){ var o=document.getElementById('cmAgOverlay');
            if(o&&o.style.display!=='none'){ cmAgClose(); if(typeof window.cmNavReflect==='function') window.cmNavReflect(); } } });
        })();
        </script>

        <!-- ===== 레일 모드 내비게이션 라우팅 (대화/스킬/크론/위임/팀위임/작업) ===== -->
        <script>
        (function(){
          // Views that are "pages" (not the goal work panel) in the dashboard tab system.
          var PAGES={condition:1};
          // The first non-page tab in the user's saved order — what "작업" should reveal.
          function firstWorkView(){
            if(typeof _tabOrder!=='undefined' && _tabOrder && _tabOrder.length){
              for(var i=0;i<_tabOrder.length;i++){ if(!PAGES[_tabOrder[i]]) return _tabOrder[i]; }
            }
            return 'input';
          }
          function setActive(kind){
            var items=document.querySelectorAll('#cmRailNav .cmrail-item');
            for(var i=0;i<items.length;i++){ items[i].classList.toggle('on', items[i].getAttribute('data-nav')===kind); }
          }
          // Reflect the dashboard's current state onto the nav highlight. Called on load and after a
          // placeholder closes. Something is ALWAYS highlighted so the nav reads as a selected-state
          // switcher: when no other surface matches (goal pages, /goal-add), 'chat' is the default.
          window.cmNavReflect=function(){
            // 독립 크론 페이지(/cron)에선 '크론'을 항상 켠다 — 대시보드 뷰 상태와 무관.
            if(window.CM_PAGE==='cron'){ setActive('cron'); return; }
            var tm=document.getElementById('cmTeamOverlay');
            if(tm && tm.style.display!=='none'){ setActive('team'); return; }   // 팀위임 오버레이가 떠 있으면 '팀위임'
            var sk=document.getElementById('cmSkOverlay');
            if(sk && sk.style.display!=='none'){ setActive('skills'); return; }   // 스킬 오버레이가 떠 있으면 '스킬'
            var ag=document.getElementById('cmAgOverlay');
            if(ag && ag.style.display!=='none'){ setActive('delegate'); return; }   // 에이전트 오버레이가 떠 있으면 '위임'
            // 통합 화면(대시보드): 단계가 곧 선택 상태다 — 1·2단계=대화, 3단계=작업.
            if(document.querySelector('[data-cmboard]')){
              setActive(document.body.classList.contains('cmboard-off') ? 'chat' : 'work'); return; }
            if(typeof _view!=='undefined'){ setActive('work'); return; }
            setActive('chat');   // 기본 선택 = chat (goal 페이지 / /goal-add 포함)
          };
          window.cmNav=function(kind){
            // 장비 장착풍 클릭음 (sound/nav-equip.mp3, 네이티브 재생) — cron/work 분기는 같은 틱에
            // location.href 로 페이지를 떠나므로, 언로드에도 살아남는 sendBeacon 을 우선 사용한다.
            try{ var sb=JSON.stringify({name:'nav'});
              if(navigator.sendBeacon) navigator.sendBeacon('/api/sfx', new Blob([sb],{type:'application/json'}));
              else fetch('/api/sfx',{method:'POST',headers:{'Content-Type':'application/json'},body:sb}).catch(function(){});
            }catch(e){}
            // 팀위임: 레일이 소유하는 독립 오버레이(내용 입력 → 팀 토론 세션 생성)를 연다.
            if(kind==='team'){ setActive(kind);
              if(typeof cmTeamOpen==='function') cmTeamOpen(); return; }
            // 다른 목적지로 이동하면 열려 있던 팀위임 오버레이는 닫는다(cmTeamHide는 순수 함수).
            if(typeof window.cmTeamHide==='function') window.cmTeamHide();
            setActive(kind);
            // 위임: 대시보드 탭이 아니라 레일이 소유하는 독립 에이전트 오버레이를 직접 연다(의존성 분리).
            if(kind==='delegate'){ if(typeof cmAgentsOpen==='function') cmAgentsOpen(); return; }
            // 다른 목적지로 이동하면 열려 있던 에이전트 오버레이는 닫는다.
            if(typeof window.cmAgClose==='function') window.cmAgClose();
            // 스킬: 대시보드 탭이 아니라 레일이 소유하는 독립 오버레이를 직접 연다(의존성 분리).
            if(kind==='skills'){ if(typeof cmSkillsOpen==='function') cmSkillsOpen(); else location.href='/#skills'; return; }
            // 다른 목적지로 이동하면 열려 있던 스킬 오버레이는 닫는다(cmSkClose는 순수 함수라 하이라이트를 건드리지 않음).
            if(typeof window.cmSkClose==='function') window.cmSkClose();
            if(kind==='chat'){ if(typeof cmComposeAi==='function') cmComposeAi(); else location.href='/goal-add'; return; }
            // 크론: 대시보드 뷰가 아니라 자체 페이지(/cron)로 이동한다(의존성 분리).
            if(kind==='cron'){ if(window.CM_PAGE!=='cron') location.href='/cron'; return; }
            // 번역: 슬랙 👀 번역함도 자체 페이지(/slack-translate)로 이동한다.
            if(kind==='slack'){ location.href='/slack-translate'; return; }
            if(kind==='work'){
              // 통합 화면에서는 '작업'이 곧 3단계(보드+대화 분할)다. 다른 페이지에서는 대시보드로.
              if(document.querySelector('[data-cmboard]')){
                if(window.cmRailStage) cmRailStage(3);
                if(typeof setView==='function') setView(firstWorkView());
                return; }
              location.href='/?stage=3'; return; }
          };
          if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',function(){ setTimeout(cmNavReflect,80); });
          else setTimeout(cmNavReflect,80);
        })();
        </script>

        <!-- ===== 팀위임 오버레이 — 내용을 입력하면 팀 토론 세션(goal)을 만들어 이동 ===== -->
        <style>
          .cmteam-overlay{ position:fixed; top:0; right:0; bottom:0; left:var(--cmrail-w); z-index:82;
            background:#0a0d12; display:flex; flex-direction:column; color:#c8cfdb;
            font:14px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif }
          body.cmrail-collapsed .cmteam-overlay{ left:0 }
          .cmteam-head{ display:flex; align-items:center; gap:12px; padding:40px 20px 16px; border-bottom:1px solid #1c2432 }
          .cmteam-title{ font-size:16px; font-weight:600; color:#e6e9ef }
          .cmteam-x{ margin-left:auto; background:transparent; border:0; color:#8b93a3; font-size:16px; cursor:pointer }
          .cmteam-body{ flex:1; display:flex; align-items:center; justify-content:center; padding:24px }
          .cmteam-card{ width:100%; max-width:640px }
          .cmteam-greet{ font-size:20px; font-weight:700; color:#eef2f8; margin-bottom:8px }
          .cmteam-sub{ color:#9aa4b6; font-size:13px; margin-bottom:16px }
          .cmteam-in{ width:100%; box-sizing:border-box; min-height:180px; resize:vertical;
            background:#0f141c; border:1px solid #263143; border-radius:10px; color:#e6e9ef;
            font-family:inherit; font-size:14px; line-height:1.6; padding:12px 14px; outline:none }
          .cmteam-in:focus{ border-color:#3b82f6 }
          .cmteam-foot{ display:flex; align-items:center; gap:12px; margin-top:12px }
          .cmteam-hint{ color:#5f6b7f; font-size:12px }
          .cmteam-go{ margin-left:auto; background:#2563eb; border:0; color:#fff; font-size:13px;
            font-weight:600; border-radius:8px; padding:9px 18px; cursor:pointer }
          .cmteam-go:disabled{ opacity:.5; cursor:default }
          .cmteam-status{ margin-top:12px; color:#9aa4b6; font-size:13px }
        </style>
        <div class="cmteam-overlay" id="cmTeamOverlay" style="display:none">
          <div class="cmteam-head"><div class="cmteam-title">팀위임</div>
            <button class="cmteam-x" title="닫기 (Esc)" onclick="cmTeamClose()">✕</button></div>
          <div class="cmteam-body"><div class="cmteam-card">
            <div class="cmteam-greet">깊게 논의할 내용이 있으시군요! 아래에 내용을 입력해주세요.</div>
            <div class="cmteam-sub">주제·문서·질문을 그대로 붙여넣으면 팀리드가 서로 다른 관점의 에이전트들을 병렬로 실행해 토론하고, 결론과 개선안을 정리합니다.</div>
            <textarea class="cmteam-in" id="cmTeamInput" placeholder="예) 현재 문서는 OKR인데, 문제정의 없이 목표부터 세우는 것이 맞나?&#10;3개월 지나서 실패를 결정하면 너무 오래 걸리지 않나? 빨리 시그널을 1주일 안에 잡을 수 없나?"></textarea>
            <div class="cmteam-foot">
              <span class="cmteam-hint">⌘⏎ 로 시작</span>
              <button class="cmteam-go" id="cmTeamGo" onclick="cmTeamSubmit()">팀 토론 시작</button>
            </div>
            <div class="cmteam-status" id="cmTeamStatus" style="display:none">팀 토론 세션을 준비하는 중…</div>
          </div></div>
        </div>
        <script>
        (function(){
          // 순수 hide (하이라이트 불변) — cmNav가 다른 목적지로 갈 때 호출한다.
          window.cmTeamHide=function(){ var o=document.getElementById('cmTeamOverlay'); if(o) o.style.display='none'; };
          window.cmTeamOpen=function(){
            if(typeof window.cmSkClose==='function') window.cmSkClose();
            if(typeof window.cmAgClose==='function') window.cmAgClose();
            var o=document.getElementById('cmTeamOverlay'); if(o) o.style.display='flex';
            var t=document.getElementById('cmTeamInput'); if(t) setTimeout(function(){ t.focus(); },50);
          };
          window.cmTeamClose=function(){ window.cmTeamHide();
            if(typeof cmNavReflect==='function') cmNavReflect(); };
          // 제출: 토론 goal을 만들고, 입력 전문은 sessionStorage로 goal 페이지에 넘겨 첫 턴
          // (preset:'team')이 자동 전송되게 한다. 프롬프트 래핑은 서버의 team preamble이 담당하므로
          // 사용자 말풍선에는 입력한 원문만 남는다.
          window.cmTeamSubmit=function(){
            var t=document.getElementById('cmTeamInput'); var v=t?t.value.trim():''; if(!v) return;
            var btn=document.getElementById('cmTeamGo'), st=document.getElementById('cmTeamStatus');
            if(btn&&btn.disabled) return;
            if(btn) btn.disabled=true;
            if(st){ st.style.display='block'; st.textContent='팀 토론 세션을 준비하는 중…'; }
            function fail(){ if(btn) btn.disabled=false;
              if(st){ st.style.display='block'; st.textContent='세션 생성에 실패했습니다. 다시 시도해주세요.'; } }
            fetch('/api/team/delegate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text:v})})
              .then(function(r){return r.json();})
              .then(function(d){ if(d&&d.ok&&d.seq){
                  try{ sessionStorage.setItem('cmTeamKick:'+d.seq, v); }catch(e){}
                  location.href='/goal?n='+d.seq;
                } else fail(); })
              .catch(fail);
          };
          var ta=document.getElementById('cmTeamInput');
          if(ta) ta.addEventListener('keydown',function(e){
            if(e.key==='Enter'&&(e.metaKey||e.ctrlKey)){ e.preventDefault(); cmTeamSubmit(); } });
          document.addEventListener('keydown',function(e){ if(e.key==='Escape'){ var o=document.getElementById('cmTeamOverlay');
            if(o&&o.style.display!=='none') cmTeamClose(); } });
        })();
        </script>

        <!-- (계획 오버레이는 2026-07-19 계획 메뉴 삭제와 함께 제거 — 계획 수립은 목표 세션
             안(작업 모드 '계획')에서 한다. 서버의 /api/plan/delegate·preset:'plan' 경로는
             기존 "계획:" goal 세션 호환용으로 남아 있다.) -->

        """#
    }
}
