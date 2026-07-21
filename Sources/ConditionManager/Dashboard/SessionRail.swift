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
          :root{ --cmrail-w:240px }
          body{ padding-left:var(--cmrail-w) }
          body.cmrail-collapsed{ padding-left:0 }
          .cmrail{ position:fixed; top:0; left:0; bottom:0; width:var(--cmrail-w); z-index:40;
            background:#0d1017; border-right:1px solid #1c2230; display:flex; flex-direction:column;
            font:13px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif; color:#c8cfdb }
          body.cmrail-collapsed .cmrail{ transform:translateX(-100%) }
          /* Zen (rail-width window) shows ONLY the rail — it must win over a persisted manual
             collapse, or the zen window would be entirely empty. Same specificity, later rule. */
          body.cm-zen .cmrail{ transform:none }
          /* The native window uses fullSizeContentView (see AppWindow.swift) so this web content
             rides up under the transparent titlebar — the traffic-light window buttons occupy
             roughly the top-left ~78px wide x ~28px tall. Push the rail header down below them
             with a comfortable gap instead of letting the logo/title/toggle sit under the dots. */
          /* Rail header: no brand text/logo — just the sidebar-toggle and session-search icons,
             sitting on the same row as (to the right of) the native traffic-light window buttons.
             The traffic lights occupy ~78px at top-left, so pad the left to clear them. */
          .cmrail-brand{ display:flex; align-items:center; gap:2px; padding:2px 10px 6px 84px; min-height:30px }
          /* Top-of-rail mode navigation (대화/스킬/크론/위임/팀위임/작업/메모장 + 미정×2) — a horizontal
             segmented switcher like the Claude-Code shell's Chat/Cowork/Code control. Nine items form
             a 3-column × 3-row grid of vertical mini-tabs (icon over label), ordered by the intended
             work flow: 대화로 목표를 만들고(대화) → 실행한다. 대화/스킬/크론/작업 route to real
             surfaces (크론 → 워커 뷰); 위임 opens the rail-owned agents overlay; 팀위임 opens the
             team-discussion composer (#cmTeamOverlay). The 계획 menu (planning composer overlay)
             was removed 2026-07-19 — planning now happens inside a goal session itself; the server
             side (/api/plan/delegate, preset:'plan') stays for legacy "계획:" goals. 메모장 is a
             focus shortcut: it opens /goal-add with the rail collapsed for THAT load only (a
             one-shot sessionStorage hint, NOT the persisted cmRailCollapsed), so the composer
             fills the screen for brain-dumping. The two remaining 미정 slots are reserved
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
             floating show-again button (when collapsed) — both just toggle cmrail-collapsed. */
          .cmrail-sbtoggle{ display:inline-flex; align-items:center; justify-content:center; width:26px; height:26px;
            border-radius:6px; background:none; border:0; color:#8b93a7; cursor:pointer; padding:0 }
          .cmrail-sbtoggle:hover{ background:rgba(255,255,255,.08); color:#e7ecf4 }
          .cmrail-sbtoggle svg{ width:16px; height:16px; display:block; pointer-events:none }
          /* When collapsed, the floating show-again button must land on the SAME spot the in-rail
             toggle occupied while expanded (right of the traffic lights, top titlebar row) so it
             doesn't visually jump downward. Match .cmrail-brand's top padding (2px) and left
             padding (84px, which clears the ~78px traffic-light cluster). */
          .cmrail-toggle{ position:fixed; top:2px; left:84px; z-index:41; display:none }
          body.cmrail-collapsed .cmrail-toggle{ display:inline-flex }
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
          /* Pre-start mode selector: 25분(포모도로) · 스프린트 · 무제한. Hidden once running. */
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
        <button class="cmrail-toggle cmrail-sbtoggle" onclick="cmRailToggle()" title="세션 레일 열기">
          <svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
            <rect x="1.5" y="2.5" width="13" height="11" rx="2" stroke="currentColor" stroke-width="1.3"/>
            <line x1="6" y1="2.5" x2="6" y2="13.5" stroke="currentColor" stroke-width="1.3"/>
          </svg>
        </button>
        <aside class="cmrail cmboot" id="cmRail">
          <div class="cmrail-brand">
            <button class="cmrail-sbtoggle" onclick="cmRailToggle()" title="접기">
              <svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
                <rect x="1.5" y="2.5" width="13" height="11" rx="2" stroke="currentColor" stroke-width="1.3"/>
                <line x1="6" y1="2.5" x2="6" y2="13.5" stroke="currentColor" stroke-width="1.3"/>
              </svg>
            </button>
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
              <a class="cmrail-item" data-nav="skills" onclick="cmNav('skills')" title="반복적인 업무를 스킬로 실행합니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6.3 2.6h3.4v1.5a1.1 1.1 0 1 0 2.2 0V2.6h1.5v3.4h-1.5a1.1 1.1 0 1 0 0 2.2h1.5v3.4h-3.4v-1.5a1.1 1.1 0 1 0-2.2 0v1.5H3.9V10.2h1.5a1.1 1.1 0 1 0 0-2.2H3.9V4.6" transform="translate(-.4 .2)"/></svg></span><span class="cmr-lbl">스킬</span></a>
              <a class="cmrail-item" data-nav="cron" onclick="cmNav('cron')" title="주기적으로 실행해야 하는 업무(워커)를 등록·관리합니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="8.4" r="5"/><path d="M8 5.6V8.4l1.9 1.2"/></svg></span><span class="cmr-lbl">크론</span></a>
              <a class="cmrail-item" data-nav="delegate" onclick="cmNav('delegate')" title="목적을 달성하는 책임 에이전트를 봅니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="5.6" cy="5.4" r="2.1"/><path d="M2.4 12.8c0-1.9 1.5-3.2 3.2-3.2 1.1 0 2 .5 2.6 1.2"/><path d="M9.4 8.4h4M11.7 6.5l1.9 1.9-1.9 1.9"/></svg></span><span class="cmr-lbl">위임</span></a>
              <a class="cmrail-item" data-nav="team" onclick="cmNav('team')" title="teamlead와 더 깊게 대화하고 위임합니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="5.8" r="2"/><path d="M2.6 12.4c0-1.9 1.5-3.1 3.4-3.1s3.4 1.2 3.4 3.1"/><circle cx="11" cy="6.3" r="1.6"/><path d="M10.4 9.4c1.7 0 3 1 3 2.8"/></svg></span><span class="cmr-lbl">팀위임</span></a>
              <a class="cmrail-item" data-nav="work" onclick="cmNav('work')" title="현재 대시보드(작업 목록)를 봅니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M2.6 5.2c0-.6.5-1.1 1.1-1.1h2.1l1.1 1.3h4.4c.6 0 1.1.5 1.1 1.1v4.9c0 .6-.5 1.1-1.1 1.1H3.7c-.6 0-1.1-.5-1.1-1.1V5.2Z"/></svg></span><span class="cmr-lbl">작업</span></a>
              <a class="cmrail-item" data-nav="memo" onclick="cmNav('memo')" title="머릿속 비워내기 — 목표 추가 화면만 크게(레일 접힘) 엽니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3.2 4.1c0-.8.6-1.4 1.4-1.4h6.8c.8 0 1.4.6 1.4 1.4v7.8c0 .8-.6 1.4-1.4 1.4H4.6c-.8 0-1.4-.6-1.4-1.4V4.1Z"/><path d="M5.6 6.2h4.8M5.6 8.4h4.8M5.6 10.6h2.6"/></svg></span><span class="cmr-lbl">메모장</span></a>
              <a class="cmrail-item off" data-nav="tbd2" title="준비 중입니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 8.2h.01M8 8.2h.01M12.4 8.2h.01"/></svg></span><span class="cmr-lbl">미정</span></a>
              <a class="cmrail-item off" data-nav="tbd3" title="준비 중입니다">
                <span class="cmr-ico"><svg viewBox="0 0 16 16" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 8.2h.01M8 8.2h.01M12.4 8.2h.01"/></svg></span><span class="cmr-lbl">미정</span></a>
            </nav>
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
              <button data-m="sprint" onclick="cmChSetMode('sprint',event)" title="현재 스프린트 시간에 맞춰 카운트다운">스프린트</button>
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
            <button class="cmcond-full" onclick="cmOpenPlugins(event)" style="margin-top:4px"><span class="cmcond-ico"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><path d="M9 2.6c-.9 0-1.6.7-1.6 1.5 0 .3.1.5.2.7H4.6c-.3 0-.5.2-.5.5v2.1c-.2-.1-.4-.2-.7-.2-.8 0-1.5.7-1.5 1.6s.7 1.6 1.5 1.6c.3 0 .5-.1.7-.2v2.1c0 .3.2.5.5.5h2.1c-.1.2-.2.4-.2.7 0 .8.7 1.5 1.6 1.5s1.6-.7 1.6-1.5c0-.3-.1-.5-.2-.7h2.6c.3 0 .5-.2.5-.5v-2.1c.2.1.4.2.7.2.8 0 1.5-.7 1.5-1.6s-.7-1.6-1.5-1.6c-.3 0-.5.1-.7.2V5.3c0-.3-.2-.5-.5-.5h-2.1c.1-.2.2-.4.2-.7 0-.8-.7-1.5-1.6-1.5Z"/></svg></span>플러그인 관리</button>
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
            try{ webkit.messageHandlers.cmzen.postMessage('narrow'); }catch(e){} };
          var cmZenWasRun=false;   // last MAIN-PATH render's running state, for the stop transition

          // Collapse toggle (persisted) — frees the 240px when the user wants full width.
          window.cmRailToggle=function(){
            var on=document.body.classList.toggle('cmrail-collapsed');
            try{ localStorage.setItem('cmRailCollapsed', on?'1':''); }catch(e){}
          };
          try{ if(localStorage.getItem('cmRailCollapsed')==='1') document.body.classList.add('cmrail-collapsed'); }catch(e){}
          // 메모장(집중 담기) one-shot: the rail's 메모장 item stashes cmGaFocus before
          // navigating to /goal-add — collapse the rail for THIS load only, then consume
          // the flag so a reload (or the next visit) shows the rail again. Deliberately
          // does NOT touch the persisted cmRailCollapsed preference.
          try{ if(sessionStorage.getItem('cmGaFocus')==='1' && location.pathname.indexOf('/goal-add')===0){
            sessionStorage.removeItem('cmGaFocus'); document.body.classList.add('cmrail-collapsed'); } }catch(e){}

          // 목표 만들기 (AI추가): navigate to the dedicated goal-add PAGE (/goal-add,
          // GoalAddContent.swift) — a fresh document with a clean heap, from any page.
          // Used by the "chat" rail nav item.
          window.cmComposeAi=function(){ location.href='/goal-add'; };
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
          // Digital-clock duration for 트래커/스프린트 readouts: always zero-padded HH:MM:SS
          // ("03:41:00"), a calmer, more modern look than the old "3h 41m" unit-mix. Hours keep
          // accumulating past 24 for a clean clock feel (오늘 총 rarely exceeds a day anyway).
          function cmChDur(s){ s=Math.max(0,s|0); var h=(s/3600)|0, m=((s%3600)/60)|0, ss=s%60;
            var p=function(n){ return n<10?'0'+n:''+n; };
            return p(h)+':'+p(m)+':'+p(ss); }
          function cmChModeLabel(){
            if(cmChMode==='sprint') return cmChSprintTarget>0?'스프린트':'스프린트(설정 없음)';
            if(cmChMode==='unlimited') return '트래커 <span class="cmch-day">· 오늘 총</span>';
            // 오늘 N/2 rides on the idle/running label too, so the daily tracker is
            // always visible — not only during the fleeting reward/done moments.
            // The count is its own nowrap chunk (see .cmch-day) so a wrap breaks cleanly
            // after "포모도로 25분" instead of cramming "오늘 3/2" against the line above.
            return '포모도로 25분 <span class="cmch-day">· 오늘 '+cmChDailyN+'/'+CMCH_DAILY_GOAL+'</span>';
          }
          // The dial's live readout while running: {text, frac} where frac∈[0,1] is how full the ring is.
          //  - pomodoro: count DOWN from 25:00; ring fills as the 25분이 소진됨.
          //  - sprint:   count DOWN to the current sprint target (wall clock); ring = 스프린트 진행률.
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
            // 이미 선택된 25분 칩을 (자동 리드인·완료 상태가 아닐 때) 다시 누르면 "시작"이 아니라
            // 목표시간을 순환한다(25→45→50). 다른 모드에서 넘어온 첫 탭은 그냥 선택.
            var reTapPomo = (m==='pomodoro' && cmChMode==='pomodoro' && cmChCountdown==null && !cmChDone);
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
            cmChRun=true; cmChSecs=0; cmChWall=0; cmChRender();
            // Carry the chosen mode so the server selects that mode's BGM playlist
            // (each mode opens on its own pinned first track).
            fetch('/api/session/control',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({action:'start', mode:cmChMode, pomodoroSecs:cmChPomoSecs()})}).catch(function(){});
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
              cmChRun=false; cmChDone=false; cmChRender();
              fetch('/api/session/control',{method:'POST',headers:{'Content-Type':'application/json'},
                body:JSON.stringify({action:'stop'})}).catch(function(){});
              return;
            }
            cmChFire();   // 수동 시작은 항상 즉시 (카운트다운 없음) — 어느 모드든 시원시원하게
          };
          // 카운트다운 취소: 자동 시작을 걷어내고, 서버가 이미 auto-start한 세션도 함께 멈춘다.
          window.cmChCancelCd=function(ev){ if(ev){ ev.stopPropagation(); ev.preventDefault(); }
            if(cmChCountdown==null) return;
            cmChClearCd(); cmChRun=false; cmChRender();
            fetch('/api/session/control',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({action:'stop'})}).catch(function(){});
          };
          window.cmChMuteToggle=function(ev){ if(ev) ev.stopPropagation();
            cmChMuted=!cmChMuted; cmChRender();
            fetch('/api/session/mute',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({muted:cmChMuted})}).catch(function(){});
          };
          function cmChSync(){
            fetch('/api/session/state').then(function(r){return r.json();}).then(function(d){
              if(!d) return;
              cmChRun=!!d.working; cmChMuted=!!d.muted;
              if(typeof d.seconds==='number') cmChSecs=d.seconds;
              if(typeof d.wall==='number') cmChWall=d.wall;
              if(typeof d.today==='number') cmChToday=d.today;
              if(typeof d.pomoToday==='number') cmChDailyN=d.pomoToday;
              if(typeof d.sprintStart==='number') cmChSprintStart=d.sprintStart;
              if(typeof d.sprintTarget==='number') cmChSprintTarget=d.sprintTarget;
              // While truly running, the dial mirrors the SERVER's session mode — a rail
              // loaded mid-session must not render the localStorage mode of a past choice.
              if(cmChRun && cmChCountdown==null && typeof d.mode==='string' && d.mode) cmChMode=d.mode;
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
          // ⬆️ 업데이트 버튼: 설치된 빌드보다 소스가 새로우면 포모도로 다이얼 아래(설정 메뉴
          // 밖)에 나타난다. 업데이트 서버 없음 — 같은 머신의 소스 트리 mtime과 실행 파일
          // mtime을 서버가 비교한다. 메뉴를 열지 않아도 보이도록 주기 폴링한다.
          function cmUpdateCheck(){
            fetch('/api/update/check',{cache:'no-store'}).then(function(r){ return r.json(); }).then(function(u){
              var b=document.getElementById('cmCondUpdate'); if(!b) return;
              if(!b.disabled) b.style.display=(u&&u.available)?'block':'none';
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
              fetch('/api/settings/timezone',{cache:'no-store'}).then(function(r){ return r.json(); }).catch(function(){ return null; })
            ]).then(function(rs){
              var p=rs[0], tz=rs[1];
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
              box.innerHTML =
                '<div class="hd">저장 폴더<span class="store'+(p.shared?'':' warn')+'">'+store+(p.dev?' · DEV 빌드':'')+'</span></div>'
                + row('data','데이터',p.data)
                + row('bgm','BGM 음원',p.bgm)
                + row('claude','Claude 세션',p.claude)
                + tzRow()
                + '<div class="tip">행 클릭=경로 복사 · ↗=Finder에서 열기 · 타임존=시간 표기 기준</div>';
            }).catch(function(){ box.innerHTML='<div class="tip">경로를 불러오지 못했습니다</div>'; });
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
          // Plugins live in the dashboard's existing 🧩 overlay. From the dashboard, open it directly;
          // from another page (goal), navigate to the dashboard with ?plugins=1 which auto-opens it.
          window.cmOpenPlugins=function(ev){ if(ev) ev.stopPropagation();
            var m=document.getElementById('cmCondMenu'), bar=document.getElementById('cmCondBar');
            if(m) m.style.display='none'; if(bar) bar.classList.remove('open');
            var rail=document.getElementById('cmRail'); if(rail) rail.classList.remove('cmcond-open');
            if(typeof openPlugins==='function'){ openPlugins(); } else { location.href='/?plugins=1'; }
          };
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
        </style>
        <div class="cmsk-overlay" id="cmSkOverlay" style="display:none">
          <div class="cmsk-panel">
            <div class="cmsk-head">
              <div class="cmsk-title">스킬</div>
              <div class="cmsk-actions">
                <button class="cmsk-icon" title="검색" onclick="cmSkToggleSearch()">🔍</button>
                <input class="cmsk-search" id="cmSkSearch" placeholder="스킬 검색…" oninput="cmSkRender()" style="display:none">
                <button class="cmsk-btn" onclick="cmSkReveal('')">찾아보기</button>
                <div class="cmsk-addwrap">
                  <button class="cmsk-btn" onclick="cmSkToggleAdd(event)">추가 ▾</button>
                  <div class="cmsk-addmenu" id="cmSkAddMenu" style="display:none">
                    <button onclick="cmSkReveal('')">Finder에서 스킬 폴더 열기</button>
                  </div>
                </div>
                <button class="cmsk-icon cmsk-close" title="닫기 (Esc)" onclick="cmSkClose();if(window.cmNavReflect)cmNavReflect()">✕</button>
              </div>
            </div>
            <div class="cmsk-tabs">
              <button class="cmsk-tab active" data-tab="current" onclick="cmSkTab('current')">현재</button>
              <button class="cmsk-tab" data-tab="history" onclick="cmSkTab('history')">히스토리</button>
            </div>
            <div id="cmSkTabCurrent">
              <div class="cmsk-folderbar">
                <span class="lbl">스킬 폴더</span>
                <span class="pth" id="cmSkRoot" title="">~/.claude</span>
                <span class="tag" id="cmSkRootTag"></span>
                <button onclick="cmSkPickFolder()">변경</button>
                <button onclick="cmSkResetFolder()">기본값</button>
              </div>
              <div class="cmsk-cols"><span>스킬</span><span>마지막 업데이트</span><span>작성자</span></div>
              <div class="cmsk-list" id="cmSkList"></div>
              <div class="cmsk-foot" id="cmSkFoot"></div>
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
            if(o){ o.style.display='flex'; cmSkTab('current'); load(); } };
          window.cmSkClose=function(){ var o=document.getElementById('cmSkOverlay'); if(o) o.style.display='none';
            var m=document.getElementById('cmSkAddMenu'); if(m) m.style.display='none'; };
          window.cmSkToggleSearch=function(){ var s=document.getElementById('cmSkSearch'); if(!s) return;
            var show=(s.style.display==='none'); s.style.display=show?'block':'none';
            if(show){ s.focus(); } else { s.value=''; cmSkRender(); } };
          window.cmSkToggleAdd=function(ev){ if(ev) ev.stopPropagation(); var m=document.getElementById('cmSkAddMenu');
            if(m) m.style.display=(m.style.display==='none'?'block':'none'); };
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
            var cur=document.getElementById('cmSkTabCurrent'), his=document.getElementById('cmSkTabHistory');
            if(cur) cur.style.display=(name==='current')?'block':'none';
            if(his) his.style.display=(name==='history')?'block':'none';
            if(name==='history') loadHist();
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
          document.addEventListener('click',function(e){ var w=document.querySelector('.cmsk-addwrap'); var m=document.getElementById('cmSkAddMenu');
            if(m&&m.style.display!=='none'&&w&&!w.contains(e.target)) m.style.display='none'; });
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

        <!-- ===== 레일 모드 내비게이션 라우팅 (대화/스킬/크론/위임/팀위임/작업/메모장) ===== -->
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
            // 메모장(집중 담기): 목표 추가 화면만 크게 — 레일을 접은 채 /goal-add 를 연다.
            // 접힘은 이번 로드에만 적용되는 일회성 힌트(cmGaFocus)라, 다른 페이지로 가면
            // 레일은 평소대로 돌아온다(persisted cmRailCollapsed 는 건드리지 않음).
            // 이미 /goal-add 에 있으면(대화로 들어온 상태에서 다시 누르면) 즉시 접어 크게 본다.
            if(kind==='memo'){
              if(location.pathname.indexOf('/goal-add')===0){ document.body.classList.add('cmrail-collapsed'); return; }
              try{ sessionStorage.setItem('cmGaFocus','1'); }catch(e){}
              location.href='/goal-add'; return; }
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
            if(kind==='work'){ if(typeof setView==='function') setView(firstWorkView()); else location.href='/'; return; }
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
