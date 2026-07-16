import Foundation
import WebCLI

// GET /goal-add — the 목표 추가 page. What used to be the dashboard's reusable goal-add
// MODAL now lives on its own page, so goal creation happens in a fresh document with a
// clean JS heap/DOM (the dashboard page is ~1500 DOM nodes; dumping goals deserves an
// empty room). Every add entry point (sprint board ＋목표, rail 목표 만들기, draft chip)
// navigates here instead of opening an overlay.
//
// Query params (all optional):
//   sprint=N   add into sprint N            label=…   human label shown next to the title
//   bump=1     add into the Bump out inbox  parent=ID add as a child of goal ID
//   search=1   목표 검색 mode (find only — no goal is created; same UI, actions differ)
//   resume=1   restore the last add context from localStorage (draft chip re-entry)
//
// Shares the same server APIs as the old modal: POST /api/goal/add (직접 추가),
// POST /api/goal/queue/enqueue (AI추가 / AI검색 with search:true), GET /api/folders
// (작업 폴더 프리셋), GET /data.json (검색의 로컬 즉시 조회 데이터).
// The draft is the same localStorage key the dashboard chip watches (cm.gaDraft), and
// the add context is persisted to cm.gaCtx so the chip can reopen the same target.
//
// 세션시작 turns THIS page into an inline session view (no navigation): the composer
// panel hides, chat2 events stream into #gsLive over the goal's SSE channel
// (GET /api/goal/chat2/stream?seq=N), and a Claude-Code-Desktop-style composer fixed to
// the bottom sends follow-up turns (POST /api/goal/chat2/say). Composer images ride the
// first turn via the goal's stored attachments; images pasted into the bottom composer
// ride their own turn (chat2/say images:[…]) — both are embedded as real base64 image
// blocks server-side so the model actually sees them (chat2RunTurn).
//
// The header CLI/GUI toggle is LIVE while a session view is open: clicking it switches
// the current view, continuing the same session. CLI→GUI stops the terminal polling
// (the PTY stays alive in the background) and opens the messenger view in resume mode —
// sends go through POST /api/goal/session/say (headless --resume of the goal's latest
// associated session, the 세션 정보 tab's channel) and events arrive over &sess=1 SSE.
// GUI→CLI closes the SSE stream and reopens the in-page terminal via cli/start, which
// reconnects the live PTY or --resumes the connected session (cliCommand tiers). A turn
// that is still running is NEVER aborted by the toggle: the CLI view waits (polling
// chat2/state) and connects the terminal once the turn finishes on its own.
enum GoalAddContent {

    static func html(serverCtx: String = "{}") -> String {
        return #"""
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>목표 추가</title>
        <style>
          :root{
            --bg:#0e1116; --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3;
            --accent:#5b8cff; --green:#36c08a;
          }
          *{ box-sizing:border-box }
          body{ margin:0; background:var(--bg); color:var(--fg);
            font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif }
          header{ position:sticky; top:0; z-index:30; display:flex; align-items:center;
            justify-content:space-between; gap:12px; background:rgba(14,17,22,.92);
            backdrop-filter:blur(6px); border-bottom:1px solid var(--line); padding:14px 20px }
          header h1{ margin:0; font-size:16px }
          header .sub{ color:var(--mut); font-size:12px; margin-top:2px }
          main{ max-width:760px; margin:0 auto; padding:26px 20px 80px }
          .panel{ background:var(--panel); border:1px solid var(--line); border-radius:14px;
            padding:20px; margin-bottom:14px }
          .row{ display:flex; align-items:center }
          .muted{ color:var(--mut) }
          .btn{ background:#1d2230; border:1px solid var(--line); color:var(--fg); border-radius:8px;
            padding:6px 12px; font-size:13px; cursor:pointer }
          .btn:hover{ border-color:var(--accent) }
          .btn.primary{ background:var(--accent); border-color:var(--accent); color:#fff }
          .btn.start{ border-color:var(--accent); color:var(--accent); font-weight:600 }
          .btn.start:hover{ background:var(--accent); color:#fff }
          .btn:disabled{ opacity:.5; cursor:not-allowed }
          .pill{ display:inline-block; padding:1px 7px; border-radius:999px; font-size:11px;
            border:1px solid var(--line); margin-right:4px; color:var(--fg); text-decoration:none }

          /* ── 목표 추가 컴포저: 폴더칩 · 입력(compbox) · 툴바(작업량·작업모드·사진) ── */
          .compbox{ border:1px solid var(--line); border-radius:14px; background:#0e1320; padding:10px 12px;
            transition:border-color .15s }
          .compbox:focus-within{ border-color:var(--accent) }
          .compthumbs{ display:flex; flex-wrap:wrap; gap:8px; margin-bottom:8px }
          .compthumbs:empty{ display:none }
          .thumb{ position:relative; width:56px; height:56px; border-radius:8px; overflow:hidden; border:1px solid var(--line) }
          .thumb img{ width:100%; height:100%; object-fit:cover }
          .thumb .x{ position:absolute; top:1px; right:1px; width:16px; height:16px; border-radius:50%; background:rgba(0,0,0,.7);
            color:#fff; font-size:11px; line-height:16px; text-align:center; cursor:pointer; border:none }
          .comprow{ display:flex; align-items:center; gap:8px; margin-top:6px }
          .comprow .spacer{ flex:1 }
          .iconbtn{ width:32px; height:32px; border-radius:8px; border:1px solid var(--line); background:transparent; color:var(--fg);
            cursor:pointer; font-size:16px; display:flex; align-items:center; justify-content:center }
          .iconbtn:hover{ border-color:var(--accent) }
          .comphint{ color:var(--mut); font-size:11px }
          .chatdrop{ outline:2px dashed var(--accent); outline-offset:-6px }
          .gacomp{ display:flex; flex-direction:column; gap:14px }
          .ga-folder{ display:flex; align-items:center; gap:8px; flex-wrap:wrap }
          .ga-folder .flab{ font-size:11px; color:var(--mut); flex:0 0 auto }
          .fchip{ display:inline-flex; align-items:center; gap:6px; padding:5px 11px; border-radius:999px; border:1px solid var(--line); background:#0e1320; color:var(--fg); font-size:12.5px; cursor:pointer; max-width:100% }
          .fchip:hover{ border-color:var(--accent) }
          .fchip .nm{ overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:300px }
          .fchip .cv{ color:var(--mut); font-size:11px }
          .ga-fmenu{ position:absolute; left:0; z-index:70; margin-top:5px; min-width:300px; max-width:460px; max-height:320px; overflow:auto; background:#171c28; border:1px solid var(--line); border-radius:10px; box-shadow:0 12px 32px rgba(0,0,0,.5); padding:6px }
          .ga-fmenu .fopt{ display:flex; align-items:center; gap:8px; padding:7px 9px; border-radius:7px; cursor:pointer; font-size:12.5px }
          .ga-fmenu .fopt:hover{ background:#1d2230 }
          .ga-fmenu .fopt.on{ background:#1d2230; outline:1px solid var(--accent) }
          .ga-fmenu .fopt .nm{ flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          .ga-fmenu .fopt .fp{ color:var(--mut); font-size:10.5px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; max-width:170px }
          .ga-fmenu .gitb{ font-size:10px; color:#5eead4; border:1px solid #134e4a; border-radius:999px; padding:0 6px; flex:0 0 auto }
          .ga-fmenu .recb{ font-size:10px; color:var(--mut); border:1px solid var(--line); border-radius:999px; padding:0 6px; flex:0 0 auto }
          .ga-fmenu .ck{ color:var(--accent); flex:0 0 auto; font-size:12px }
          .ga-fmenu .fcustom{ display:flex; gap:6px; padding:7px 6px 3px; border-top:1px solid var(--line); margin-top:5px }
          .ga-fmenu .fcustom input{ flex:1; background:#0d1016; border:1px solid var(--line); color:var(--fg); border-radius:7px; padding:5px 8px; font-size:12px }
          /* 작업 모드 드롭다운 메뉴 (수동/편집수락/계획/자동 라디오 + 권한 건너뛰기 토글) */
          .ga-modemenu{ min-width:216px; max-width:260px }
          .ga-modemenu .mm-title{ font-size:10.5px; color:var(--mut); padding:3px 9px 6px; letter-spacing:.02em }
          .ga-modemenu .mm-k{ color:var(--mut); font-size:11px; flex:0 0 auto; min-width:12px; text-align:right }
          .ga-modemenu .mm-sep{ height:1px; background:var(--line); margin:5px 4px }
          .ga-modemenu .mm-state{ flex:0 0 auto; font-size:11px; color:var(--mut) }
          .ga-modemenu .mm-state.act{ color:var(--accent); font-weight:600 }
          #gaText{ width:100%; border:none; outline:none; background:transparent; color:var(--fg); resize:none;
            font:15px/1.6 inherit; max-height:320px; min-height:72px; overflow-y:auto }
          /* 하단 바: 왼쪽(작업모드) ↔ 오른쪽(모델·작업량) — 클로드 코드 데스크탑 컴포저식 */
          .ga-toolbar{ display:flex; align-items:center; justify-content:space-between; gap:16px; flex-wrap:wrap }
          .ga-tbleft, .ga-tbright{ display:flex; align-items:center; gap:16px; flex-wrap:wrap }
          .ga-field{ display:flex; flex-direction:column; gap:5px }
          .ga-field.ga-inline{ flex-direction:row; align-items:center; gap:8px }
          .ga-field .lab{ font-size:11px; color:var(--mut); white-space:nowrap }
          .ga-seg{ display:inline-flex; border:1px solid var(--line); border-radius:9px; overflow:hidden; flex-wrap:wrap }
          .ga-seg button{ background:transparent; border:none; color:var(--mut); padding:5px 10px; font-size:12px; cursor:pointer; border-right:1px solid var(--line) }
          .ga-seg button:last-child{ border-right:none }
          .ga-seg button.on{ background:var(--accent); color:#fff; font-weight:600 }
          .ga-seg button:hover:not(.on):not(:disabled){ color:var(--fg); background:#1d2230 }
          .ga-seg button:disabled{ opacity:.35; cursor:not-allowed }
          .ga-effort{ display:flex; align-items:center; gap:9px; min-width:200px }
          .ga-effort input[type=range]{ flex:1; accent-color:var(--accent); cursor:pointer }
          .ga-effort .cap{ font-size:10.5px; color:var(--mut); white-space:nowrap }

          /* 이번 방문에서 담은 목표(세션 집계) — 페이지는 열린 채 계속 추가하는 흐름의 피드백 */
          .tally{ border:1px solid var(--line); border-radius:12px; padding:10px 14px; margin-top:12px;
            font-size:12.5px; display:none }
          .tally.on{ display:block }
          .tally .t-row{ display:flex; gap:8px; align-items:baseline; padding:3px 0 }
          .tally .t-kind{ flex:0 0 auto; font-size:11px; color:var(--green); border:1px solid #2a5a3c;
            border-radius:999px; padding:0 8px; white-space:nowrap }
          .tally .t-kind.direct{ color:var(--accent); border-color:#33406a }
          .tally .t-txt{ overflow:hidden; text-overflow:ellipsis; white-space:nowrap }

          /* ── 세션 뷰: 세션시작 후 이 화면이 그대로 세션이 된다 — 출력은 플레인 텍스트,
                도구는 요약 한 줄›드릴다운, 입력은 하단 고정 컴포저(클로드 코드 데스크탑식) ── */
          body.sess main{ padding-bottom:170px }
          body.sess .gacomp, body.sess .tally{ display:none }
          #gaSess{ display:none }
          body.sess #gaSess{ display:block }
          #gsLive .su{ width:fit-content; max-width:82%; margin:16px 0 16px auto; padding:9px 13px;
            border-radius:12px; background:rgba(91,140,255,.10); border:1px solid rgba(91,140,255,.30);
            white-space:pre-wrap; font-size:13.5px }
          #gsLive .su .simgs{ display:block; font-size:11px; color:var(--mut); margin-top:3px }
          /* 첨부 이미지 썸네일 (클로드 코드식) — 클릭하면 원본 크기 오버레이 */
          #gsLive .su .satt{ display:flex; gap:6px; flex-wrap:wrap; margin-top:7px }
          #gsLive .su .satt img{ width:88px; height:88px; object-fit:cover; border-radius:9px;
            border:1px solid var(--line); cursor:zoom-in; display:block }
          #gsImgView{ display:none; position:fixed; inset:0; z-index:80; background:rgba(0,0,0,.75);
            align-items:center; justify-content:center; cursor:zoom-out }
          #gsImgView.on{ display:flex }
          #gsImgView img{ max-width:92vw; max-height:92vh; border-radius:10px; box-shadow:0 12px 48px rgba(0,0,0,.6) }
          #gsLive .sa{ margin:12px 0; font-size:14px; line-height:1.75; word-break:break-word }
          #gsLive .sa.streaming{ white-space:pre-wrap }
          #gsLive .sa p{ margin:6px 0 }
          #gsLive .sa h1,#gsLive .sa h2,#gsLive .sa h3{ font-size:15px; margin:14px 0 4px }
          #gsLive .sa ul,#gsLive .sa ol{ padding-left:20px; margin:6px 0 }
          #gsLive .sa pre{ background:#0d1016; border:1px solid var(--line); border-radius:8px;
            padding:8px 10px; overflow-x:auto; font-size:12px }
          #gsLive .sa code{ font-family:ui-monospace,Menlo,monospace; font-size:12.5px }
          #gsLive .sa table{ border-collapse:collapse; margin:6px 0 }
          #gsLive .sa th,#gsLive .sa td{ border:1px solid var(--line); padding:4px 9px; font-size:12.5px }
          #gsLive .sthink{ margin:10px 0 }
          #gsLive .sthink .tks{ font-size:12px; color:var(--mut); cursor:pointer; user-select:none }
          #gsLive .sthink .tks:hover{ color:var(--fg) }
          #gsLive .sthink .tkb{ margin-top:4px; padding:2px 10px; border-left:2px solid var(--line);
            color:var(--mut); font-size:12.5px; line-height:1.7; white-space:pre-wrap;
            max-height:240px; overflow-y:auto; font-style:italic }
          #gsLive .sthink.closed .tkb{ display:none }
          #gsLive .stoolsum{ font-size:12px; color:var(--mut); margin:8px 0 2px; cursor:pointer; user-select:none }
          #gsLive .stoolsum:hover{ color:var(--fg) }
          #gsLive .stoolbox{ display:none; border:1px solid var(--line); border-radius:10px;
            padding:4px 6px; margin:4px 0 8px; background:#0d1016 }
          #gsLive .stoolbox.open{ display:block }
          #gsLive .strow{ font-size:12px; color:var(--mut); padding:6px 7px; border-radius:6px; cursor:pointer;
            overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          #gsLive .strow:hover{ background:#141a24; color:var(--fg) }
          #gsLive .strdet{ display:none; margin:2px 7px 7px; padding:8px 10px; border-left:2px solid var(--line);
            font-family:ui-monospace,Menlo,monospace; font-size:11px; white-space:pre-wrap;
            color:var(--mut); max-height:260px; overflow-y:auto }
          #gsLive .strdet.open{ display:block }
          #gsLive .scost{ font-size:11px; color:var(--mut); margin:2px 0 6px }
          /* 지난 대화 기록(진입 시 로드) — 라이브 스트림과 구분되는 얇은 안내/구분선 */
          #gsLive .shist-note{ font-size:11.5px; color:var(--mut); text-align:center; margin:2px 0 4px }
          #gsLive .shist-sep{ display:flex; align-items:center; gap:10px; margin:20px 0 8px }
          #gsLive .shist-sep:before,#gsLive .shist-sep:after{ content:''; flex:1; height:1px; background:var(--line) }
          #gsLive .shist-sep span{ flex:none; font-size:11px; color:var(--mut) }
          #gsLive .gs-perm{ border:1px solid #6b4a1f; border-radius:12px; padding:10px 14px; margin:10px 0 }
          #gsLive .gs-perm .pq{ font-size:12px; color:#e8b04a; margin-bottom:6px }
          #gsLive .gs-perm code{ display:block; font-family:ui-monospace,Menlo,monospace; font-size:11.5px;
            color:var(--mut); overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          #gsLive .gs-perm .prow{ display:flex; gap:6px; margin-top:8px }
          #gsLive .planrun{ display:block; margin:8px 0; background:var(--accent); border:none; color:#fff;
            border-radius:9px; padding:7px 14px; font-size:13px; font-weight:600; cursor:pointer }
          /* cm-question 명확화 카드 — 목표 페이지 메신저(AppDelegate)와 같은 규약/모양 */
          .qcard{ display:flex; flex-direction:column; gap:10px; background:#0f131b; border:1px solid var(--line);
            border-radius:12px; padding:12px 13px; margin:10px 0; max-width:560px }
          .qcard .qhead{ display:flex; align-items:flex-start; gap:9px }
          .qcard .qcount{ flex:none; background:rgba(240,198,116,.16); color:#f0c674; font-size:11px; font-weight:600;
            padding:2px 8px; border-radius:7px; line-height:1.6; font-variant-numeric:tabular-nums }
          .qcard .qtitle{ flex:1; font-size:14px; font-weight:600; color:var(--fg); line-height:1.45; min-width:0 }
          .qcard .qctrls{ flex:none; display:flex; gap:4px }
          .qcard .qicon{ background:transparent; border:1px solid var(--line); color:var(--mut); width:24px; height:24px;
            border-radius:7px; cursor:pointer; font-size:14px; line-height:1; display:flex; align-items:center; justify-content:center; padding:0 }
          .qcard .qicon:hover{ color:var(--fg); border-color:var(--accent) }
          .qcard .qbody{ display:flex; flex-direction:column; gap:7px }
          .qcard .qopt{ display:flex; align-items:flex-start; justify-content:space-between; gap:10px; width:100%; text-align:left;
            background:#11151f; border:1px solid var(--line); border-radius:9px; padding:9px 11px; cursor:pointer; color:var(--fg); font:inherit }
          .qcard .qopt:hover{ border-color:#3a4658 }
          .qcard .qopt.sel{ background:#1b212d; border-color:var(--accent) }
          .qcard .qopt .qmain{ display:flex; flex-direction:column; gap:2px; min-width:0 }
          .qcard .qopt .qlabel{ font-size:13px; font-weight:600; color:var(--fg); line-height:1.4 }
          .qcard .qopt .qwhy{ font-size:11px; color:var(--mut); line-height:1.4 }
          .qcard .qopt .qnum{ flex:none; background:#0d1016; border:1px solid var(--line); color:var(--mut); font-size:11px;
            min-width:20px; height:20px; border-radius:6px; display:flex; align-items:center; justify-content:center; font-variant-numeric:tabular-nums }
          .qcard .qopt.sel .qnum{ color:var(--accent); border-color:var(--accent) }
          .qcard .qfreein{ background:#0d1016; border:1px solid var(--line); color:var(--fg); border-radius:8px;
            padding:8px 10px; font-size:13px; width:100%; box-sizing:border-box }
          .qcard .qfreein:focus{ border-color:var(--accent); outline:none }
          .qcard .qfoot{ display:flex; justify-content:flex-end; gap:8px; margin-top:1px }
          .qcard .qskip{ background:transparent; border:1px solid var(--line); color:var(--mut); border-radius:7px; padding:6px 12px; font-size:13px; cursor:pointer }
          .qcard .qskip:hover{ color:var(--fg) }
          .qcard .qnextbtn{ background:var(--accent); border:1px solid var(--accent); color:#fff; border-radius:7px; padding:6px 14px; font-size:13px; cursor:pointer }
          .qcard.answered{ opacity:.5; pointer-events:none }
          .qhint{ color:var(--mut); font-style:italic }
          .gs-stat{ display:flex; align-items:center; gap:8px; font-size:12px; color:var(--mut); margin:12px 0 6px }
          .gs-stat .gstar{ display:inline-block; font-size:14px; line-height:1 }
          .gs-stat.working .gstar{ color:#ff6b4a; animation:gsspin 1.6s linear infinite }
          .gs-stat.working #gsStxt{ color:#ff6b4a }
          @keyframes gsspin{ to{ transform:rotate(360deg) } }
          .gs-bar{ display:none; position:fixed; left:var(--cmrail-w,0); right:0; bottom:0; z-index:40;
            padding:18px 20px 16px; background:linear-gradient(to top, var(--bg) 72%, rgba(14,17,22,0)) }
          body.sess .gs-bar{ display:block }
          .gs-bar .inner{ max-width:760px; margin:0 auto; border:1px solid var(--line); border-radius:14px;
            background:#0e1320; padding:10px 12px; box-shadow:0 8px 30px rgba(0,0,0,.45) }
          .gs-bar .inner:focus-within{ border-color:var(--accent) }
          .gs-bar textarea{ width:100%; border:none; outline:none; background:transparent; color:var(--fg);
            resize:none; font:14px/1.6 inherit; max-height:220px; min-height:24px; display:block }
          .gs-bar .brow{ display:flex; align-items:center; gap:8px; margin-top:6px }
          /* 실행 컨텍스트 스트립 (작업 폴더 + 브랜치) — 입력창 위 얇은 줄 */
          .gs-bar .gs-ctx{ display:flex; align-items:center; gap:12px; margin:0 2px 8px;
            padding-bottom:8px; border-bottom:1px solid var(--line); font-size:11.5px; flex-wrap:wrap }
          .gs-bar .gs-ctx .gc-repo,.gs-bar .gs-ctx .gc-branch{ display:inline-flex; align-items:center; gap:5px }
          .gs-bar .gs-ctx .gc-repo{ color:var(--fg); font-weight:600 }
          .gs-bar .gs-ctx .gc-branch{ color:#5eead4 }
          .gs-bar .gs-ctx .ic{ opacity:.7; font-size:11px }

          /* ── CLI 세션 뷰: 세션시작(CLI 토글)이 페이지 안 임베디드 터미널로 진행된다 ──
             높이는 flex 체인으로 채운다 — calc(100vh - N) 매직넘버는 헤더 실높이(제목/부제
             줄바꿈에 따라 가변)와 어긋나는 순간 터미널 하단이 뷰포트 밖으로 잘린다. */
          #gaCli{ display:none }
          body.cli .gacomp, body.cli .tally, body.cli #gaSess, body.cli .gs-bar{ display:none }
          body.cli{ height:100vh; overflow:hidden; display:flex; flex-direction:column }
          body.cli header{ flex:0 0 auto }
          body.cli main{ flex:1; min-height:0; max-width:none; width:100%; margin:0; padding:12px 18px 16px }
          body.cli #gaCli{ display:flex; flex-direction:column; gap:8px; height:100% }
          #gaCli .cli-head{ display:flex; align-items:center; gap:10px; font-size:12px; color:var(--mut) }
          #gaCli .cli-head .st.live{ color:var(--green) }
          #gaCli .cli-head .st.dead{ color:#e8b04a }
          #gaCliTerm{ flex:1; min-height:0; background:#0c0f15; border:1px solid var(--line);
            border-radius:12px; padding:10px 12px 14px; overflow:hidden }
          #gaCliTerm .xterm{ height:100% }
          /* 스크롤바: WebKit 기본(밝은 회백색)은 어두운 터미널에서 깨진 것처럼 튄다 —
             목표 페이지 CLI 오버레이(.cliterm)와 같은 톤의 얇고 어두운 썸으로 통일. */
          #gaCliTerm .xterm-viewport{ background:#0c0f15 !important;
            scrollbar-width:thin; scrollbar-color:#2a3340 transparent }
          #gaCliTerm .xterm-viewport::-webkit-scrollbar{ width:8px }
          #gaCliTerm .xterm-viewport::-webkit-scrollbar-track{ background:transparent }
          #gaCliTerm .xterm-viewport::-webkit-scrollbar-thumb{ background:#2a3340; border-radius:4px }
          #gaCliTerm .xterm-viewport::-webkit-scrollbar-thumb:hover{ background:#3a4658 }
        </style></head>
        <body>
          <script>window.CM_PAGE='goal-add';
          // 서버 영속 컴포저 컨텍스트(작업 폴더·브랜치·작업량·모드·최근 폴더). 렌더 시 인라인 주입 —
          // dynamic 포트로 origin 이 바뀌어도 재시작 후 고른 폴더가 유지된다(localStorage 대체 소스).
          try{ window._gaServerCtx=\#(serverCtx); }catch(e){ window._gaServerCtx={}; }</script>
          \#(SessionRail.html())
          <header>
            <div><h1><span id="gaEditIcon" style="display:none" title="작성 중이던 초안을 이어서 편집 중">✎ </span><span id="gaTitle">목표 추가</span> <span class="muted" id="gaWhere" style="font-size:13px;font-weight:400"></span></h1>
              <div class="sub" id="gaSub">깨끗한 화면에서 목표만 담습니다 — 담고 나면 대시보드로 돌아가세요</div></div>
            <!-- 세션시작 실행 방식 토글: 클릭이 곧 디폴트 변경 (cm.gaUiMode 영속, 기본 CLI).
                 세션 뷰가 열려 있으면 클릭이 곧 뷰 전환 — 같은 세션을 이어서 반대 모드로 연다. -->
            <div class="ga-seg" id="gaUiSeg">
              <button type="button" id="gaUiCli" onclick="gaUiSet('cli')" title="세션시작이 이 화면 안 터미널(claude CLI)로 열립니다 (기본) — 세션 중이면 지금 세션을 터미널로 이어서 엽니다">CLI</button>
              <button type="button" id="gaUiGui" onclick="gaUiSet('gui')" title="세션시작이 이 화면의 메신저형 세션 뷰로 열립니다 — 세션 중이면 지금 세션을 이어서 이 뷰로 전환합니다">GUI</button>
              <!-- 대시보드: 이 화면에서 목표가 실제로 생기면(직접 추가·세션시작) 활성화 —
                   목표 페이지로 이동한다. 목표/과제 없는 temp 상태(입력만·AI 큐 대기)에선 비활성. -->
              <button type="button" id="gaUiDash" onclick="gaDashOpen()" disabled>DETAIL</button>
            </div>
          </header>
          <main>
          <div class="panel gacomp">
            <!-- 작업 폴더: 목표가 실제로 어느 폴더에서 실행될지 (프리셋 + 직접 입력) -->
            <div class="ga-folder ga-execonly">
              <span class="flab">작업 폴더</span>
              <div style="position:relative">
                <button class="fchip" onclick="gaFolderToggle(event)" title="이 목표가 실행될 작업 폴더를 고릅니다 — 정하지 않으면 목표 전용 폴더에서 실행됩니다">
                  📁 <span class="nm" id="gaFolderName">기본 (목표 폴더)</span> <span class="cv">▾</span></button>
                <div class="ga-fmenu" id="gaFolderMenu" style="display:none"></div>
              </div>
              <div style="position:relative;display:none" id="gaBranchWrap">
                <button class="fchip" onclick="gaBranchToggle(event)" title="이 폴더에서 세션이 실행될 git 브랜치 — 세션 시작 전에 체크아웃됩니다">
                  ⎇ <span class="nm" id="gaBranchName"></span> <span class="cv">▾</span></button>
                <div class="ga-fmenu" id="gaBranchMenu" style="display:none"></div>
              </div>
            </div>
            <!-- 입력 + 사진 첨부 (paste·drag·＋, 최대 5장) -->
            <div class="compbox" id="gaCompBox">
              <div class="compthumbs" id="gaThumbs"></div>
              <textarea id="gaText" rows="4" placeholder="목표/디테일 입력 후 Enter (AI추가로 계속 추가) · Shift+Enter 줄바꿈 · 이미지 붙여넣기/끌어놓기 가능"></textarea>
              <div class="comprow">
                <button class="iconbtn ga-execonly" onclick="gaPick()" title="사진 첨부 (최대 5장)">＋</button>
                <span class="comphint" id="gaImgHint"></span>
                <span class="spacer"></span>
              </div>
              <input type="file" id="gaFile" accept="image/*" multiple style="display:none" onchange="gaPicked(this.files)">
            </div>
            <!-- 하단 바(클로드 코드 데스크탑식): 왼쪽=작업모드 · 오른쪽=모델·작업량 -->
            <div class="ga-toolbar ga-execonly">
              <!-- 왼쪽: 작업 모드 -->
              <div class="ga-tbleft">
                <div class="ga-field ga-inline">
                  <span class="lab">작업 모드</span>
                  <div style="position:relative">
                    <button class="fchip" id="gaModeChip" onclick="gaModeToggle(event)" title="이 목표의 AI 세션 권한 모드 — 수동/편집 수락/계획/자동 중 하나 + 권한 건너뛰기 토글">
                      <span class="nm" id="gaModeName">자동</span> <span class="cv">▾</span></button>
                    <div class="ga-fmenu ga-modemenu" id="gaModeMenu" style="display:none"></div>
                  </div>
                </div>
              </div>
              <!-- 오른쪽: 모델 → 작업량 순서 -->
              <div class="ga-tbright">
                <div class="ga-field ga-inline">
                  <span class="lab">모델</span>
                  <div class="ga-seg" id="gaModelSeg" title="이 목표의 AI 세션이 쓸 모델 — 자동은 CLI 기본값을 따릅니다"></div>
                </div>
                <div class="ga-field ga-inline">
                  <span class="lab">작업량 · <span id="gaEffortLab" style="color:var(--fg)">기본</span></span>
                  <div class="ga-effort">
                    <span class="cap">더 빠름</span>
                    <input type="range" min="0" max="5" step="1" value="0" id="gaEffort" oninput="gaEffortSet(this.value)"
                           title="AI 작업량(추론 노력): 왼쪽=빠름, 오른쪽=스마트함. 기본은 CLI 기본값을 따릅니다">
                    <span class="cap">더 스마트함</span>
                  </div>
                </div>
              </div>
            </div>
            <!-- 액션 -->
            <div class="row" style="justify-content:flex-end;gap:8px;margin:2px 0 0">
              <button class="btn primary" id="gaAiBtn" onclick="gaAi()" title="추가 전에 AI가 비슷한 목표가 있는지 먼저 검사합니다">AI추가</button>
              <button class="btn" id="gaAddBtn" onclick="gaAdd()">추가</button>
              <button class="btn" id="gaSearchBtn" onclick="gaSearch()" title="번호 또는 제목으로 즉시 찾습니다 — 완료·릴리즈·보관·취소된 목표도 찾아줍니다">검색</button>
              <button class="btn start ga-execonly" id="gaStartBtn" onclick="gaStart()" title="목표를 바로 추가하고 이 화면에서 AI 세션을 시작합니다 — 하단 입력창으로 이어서 지시할 수 있습니다">세션시작</button>
            </div>
            <div class="muted" id="gaHint" style="font-size:12px"><b>Enter</b>를 누르면 <b>AI추가</b>로 담깁니다 — 비슷한 목표가 있는지 먼저 확인하며, 페이지는 열린 채 계속 추가할 수 있습니다. 바로 추가하려면 <b>추가</b>, 비슷한 목표만 찾으려면 <b>검색</b>. <b>세션시작</b>은 목표를 바로 추가하고 AI 세션까지 시작합니다 — 페이지 이동 없이 이 화면에서 AI 출력이 흐르고, 하단 입력창으로 이어서 지시할 수 있습니다.</div>
            <div id="gaResults" style="margin-top:2px"></div>
          </div>
          <div class="tally" id="gaTally"><b style="font-size:12px">이번에 담김 <span id="gaTallyN">0</span>건</b> <span class="muted" style="font-size:11px">— AI추가 항목의 검토·확정은 대시보드 <a href="/#view=queue" style="color:var(--accent)">큐 탭</a>에서</span><div id="gaTallyList" style="margin-top:6px"></div></div>
          <!-- 세션 뷰: 세션시작이 페이지 이동 없이 여기서 진행된다 (body.sess 에서만 보임) -->
          <div id="gaSess">
            <div id="gsLive"></div>
            <div class="gs-stat" id="gsStat"><span class="gstar">✳</span><span id="gsStxt">대기 중</span></div>
          </div>
          <!-- CLI 세션 뷰: 세션시작(CLI 토글)이 페이지 안 임베디드 터미널로 진행된다 (body.cli 에서만 보임) -->
          <div id="gaCli">
            <div class="cli-head"><span class="st" id="gaCliState">연결 중…</span></div>
            <div id="gaCliTerm"></div>
          </div>
          </main>
          <!-- 하단 고정 컴포저 (세션 뷰 전용): 이어서 지시 + 이미지 붙여넣기 -->
          <div class="gs-bar" id="gsBar">
            <div class="inner">
              <!-- 현재 실행 컨텍스트: 작업 폴더 + 브랜치 (세션이 실제로 도는 위치) -->
              <div class="gs-ctx" id="gsCtx" style="display:none">
                <span class="gc-repo"><span class="ic">📁</span><span id="gsCtxFolder"></span></span>
                <span class="gc-branch" id="gsCtxBranch" style="display:none"><span class="ic">⎇</span><span id="gsCtxBranchName"></span></span>
              </div>
              <div class="compthumbs" id="gsThumbs"></div>
              <textarea id="gsIn" rows="1" placeholder="이어서 지시하기… (Enter 전송 · ⇧Enter 줄바꿈 · 이미지 붙여넣기 가능)"></textarea>
              <div class="brow">
                <span class="comphint" id="gsImgHint"></span>
                <span class="spacer" style="flex:1"></span>
                <button class="btn" id="gsStopBtn" onclick="gsStop()" style="display:none" title="Esc 로도 중단할 수 있습니다">중단 <span style="opacity:.55;font-size:.85em">Esc</span></button>
                <button class="btn primary" id="gsSendBtn" onclick="gsSend()">보내기 ↵</button>
              </div>
            </div>
          </div>
        \#(WebCLITerminal.script())
        <script>
        const $ = id => document.getElementById(id);
        function esc(s){ return (s||'-').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
        function pad2(n){ return (n<10?'0':'')+n; }
        // fire-and-refresh POST — the page has no board to re-render, so this only re-runs the
        // last search (the dashboard's post() chains a full load() instead).
        function post(path,obj){ return fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(obj||{})}); }

        // ── 추가 대상 컨텍스트: 쿼리 파라미터 → {sprint,parent,bump} (0/''=Backlog 최상위) ──
        const _qs=new URLSearchParams(location.search);
        let _gaCtx={sprint:0,parent:'',bump:false,label:''};
        let _gaSearchMode=(_qs.get('search')==='1');
        (function(){
          if(_qs.get('resume')==='1'){
            // 대시보드의 이어쓰기 칩: 마지막으로 열었던 대상(cm.gaCtx) 그대로 복원.
            try{ const c=JSON.parse(localStorage.getItem('cm.gaCtx')||'{}');
              _gaCtx={sprint:c.sprint||0,parent:c.parent||'',bump:!!c.bump,label:c.label||''}; }catch(e){}
          } else {
            _gaCtx={sprint:parseInt(_qs.get('sprint')||'0',10)||0,parent:_qs.get('parent')||'',
                    bump:_qs.get('bump')==='1',label:_qs.get('label')||''};
          }
          if(!_gaSearchMode){ try{ localStorage.setItem('cm.gaCtx',JSON.stringify(_gaCtx)); }catch(e){} }
        })();
        // 뒤로: 앱 안 내비게이션이면 이전 페이지로, 직접 진입이면 대시보드로. (ESC 전용 — 헤더 링크는 없음)
        function gaBack(){ if(history.length>1) history.back(); else location.href='/'; }

        // 시스템 로그(뷰 트레이스) 스탬프: 채팅/CLI 열기·사진 첨부 같은 페이지 안 상태 변화는
        // 0.5초 하트비트가 볼 수 없으므로 여기서 직접 찍는다 (window.cmVT = 주입 하트비트 API,
        // 앱 창 밖에서 열리면 없을 수 있어 가드).
        function vtev(n){ try{ if(window.cmVT) cmVT.ev(n); }catch(e){} }

        // ── 세션시작 실행 방식 토글 (헤더 CLI/GUI): CLI=터미널의 claude, GUI=이 화면 세션 뷰.
        //    클릭이 곧 디폴트 변경 — cm.gaUiMode 로 영속, 기본 cli.
        //    세션 뷰가 이미 열려 있으면 클릭이 곧 라이브 전환: 같은 세션을 이어서 반대 뷰로
        //    연다 (CLI→GUI = session/say 재개, GUI→CLI = cli/start 재접속·--resume). ──
        let _gaUi='cli';
        let _gaSessSeq=0;   // 이 화면에서 세션 뷰가 열린 목표 seq — 0 이면 세션 없음
        // ── 대시보드 버튼: 이 화면에서 목표가 실제로 생겨야(직접 추가·세션시작) 열 수 있다.
        //    입력만 있거나 AI추가로 큐에 담긴 temp 상태에선 목표 페이지가 없으므로 비활성.
        //    여러 개를 담았으면 마지막으로 생긴 목표를 가리킨다. ──
        let _gaGoalSeq=0;   // 이 화면에서 만들어진/열린 마지막 목표 seq — 0=temp(비활성)
        function gaGoalBorn(seq){ if(!(seq>0)) return; _gaGoalSeq=seq; gaDashSync(); }
        function gaDashSync(){ const b=$('gaUiDash'); if(!b) return;
          b.disabled=!(_gaGoalSeq>0);
          b.title=(_gaGoalSeq>0)
            ?('goal-'+pad2(_gaGoalSeq)+' 목표 페이지(DETAIL)를 엽니다 — 정의·대화 기록·첨부가 여기 남습니다')
            :'아직 목표가 없습니다 — 추가 또는 세션시작으로 목표가 생기면 열 수 있습니다'; }
        function gaDashOpen(){ if(!(_gaGoalSeq>0)) return;
          try{ localStorage.setItem('cm.lastTab.'+_gaGoalSeq,'detail'); }catch(e){}
          vtev('dashOpen goal-'+pad2(_gaGoalSeq)); location.href='/goal?n='+_gaGoalSeq; }
        function gaUiSync(){ const c=$('gaUiCli'), g=$('gaUiGui');
          if(c) c.className=(_gaUi==='cli')?'on':'';
          if(g) g.className=(_gaUi==='gui')?'on':'';
          const b=$('gaStartBtn'); if(b) b.title=(_gaUi==='cli')
            ?'목표를 바로 추가하고 이 화면 안 터미널(claude CLI)에서 세션을 시작합니다'
            :'목표를 바로 추가하고 이 화면에서 AI 세션을 시작합니다 — 하단 입력창으로 이어서 지시할 수 있습니다'; }
        function gaUiSet(m){ _gaUi=(m==='gui')?'gui':'cli';
          try{ localStorage.setItem('cm.gaUiMode',_gaUi); }catch(e){}
          // 열려 있는 세션이 있으면 그 목표의 '마지막 본 탭'으로 이 뷰를 기록 — 레일 재진입 복원용.
          try{ const sq=_gaSessSeq>0?_gaSessSeq:_gaGoalSeq; if(sq>0) localStorage.setItem('cm.lastTab.'+sq,_gaUi); }catch(e){}
          gaUiSync();
          if(_gaSessSeq>0){
            if(_gaUi==='gui'&&document.body.classList.contains('cli')) gaCliToGui();
            else if(_gaUi==='cli'&&document.body.classList.contains('sess')) gaGuiToCli();
          } }
        // CLI → GUI 라이브 전환: 터미널 폴링만 끊고(PTY는 백그라운드 유지 — 레일·재전환으로
        // 재접속 가능) 같은 화면을 메신저형 세션 뷰로 바꾼다. 이어지는 지시는
        // /api/goal/session/say 가 목표의 최신 연결 세션(방금 그 CLI 세션)을 headless 로
        // 재개한다 — 목표 페이지 세션 정보 탭과 같은 &sess=1 채널.
        function gaCliToGui(){
          if(_cliCtl) _cliCtl.disconnect();
          document.body.classList.remove('cli');
          gsEnterResume(_gaSessSeq);
        }
        // GUI → CLI 라이브 전환: SSE만 닫고 같은 세션을 페이지 안 터미널로 다시 연다 —
        // cli/start 가 살아있는 PTY 재접속 또는 연결 세션 --resume 으로 잇는다(cliCommand).
        // 턴이 돌고 있어도 중단하지 않는다: 백그라운드에서 계속 돌게 두고, 끝나서 세션
        // id 가 저장된 뒤 터미널이 이어받는다(그 전에 --resume 하면 진행 중 턴을 못 본다).
        function gaGuiToCli(){
          const seq=_gaSessSeq;
          let running=false, sess=false;
          if(_gs){
            running=!!_gs.running; sess=!!_gs.sess;
            if(_gs.es){ try{ _gs.es.close(); }catch(e){} }
            _gs=null;
          }
          gsWorking(false);
          document.body.classList.remove('sess');
          if(!running){ gaCliEnter(seq,''); return; }
          gaCliWaitTurn(seq,sess);
        }
        // 턴이 도는 동안의 CLI 진입 대기: CLI 뷰 골격(타이틀·상태줄)만 먼저 열고 턴 상태를
        // 폴링, running=false 가 되면 그때 터미널을 연결한다. 사용자가 GUI 로 되돌아가면
        // (body 에서 cli 클래스가 빠지면) 폴링을 멈춘다 — 턴은 계속 GUI 뷰로 수신된다.
        let _gaCliWaitT=null;
        function gaCliWaitTurn(seq,sess){
          document.body.classList.add('cli');
          document.title='goal-'+pad2(seq)+' CLI';
          const ttl=$('gaTitle'); if(ttl) ttl.textContent='goal-'+pad2(seq)+' CLI 세션';
          const sub=$('gaSub'); if(sub) sub.innerHTML='인터랙티브 claude 가 이 터미널에서 진행됩니다 — 기록·첨부는 <a href="/goal?n='+seq+'" style="color:var(--accent)">목표 페이지</a>에 그대로 남습니다';
          cliState('AI 턴 진행 중 — 중단하지 않고, 끝나는 대로 터미널이 이어받습니다 (GUI 탭에서 진행을 볼 수 있습니다)');
          const url='/api/goal/chat2/state?seq='+seq+(sess?'&sess=1':'');
          clearInterval(_gaCliWaitT);
          _gaCliWaitT=setInterval(()=>{
            if(!document.body.classList.contains('cli')){ clearInterval(_gaCliWaitT); _gaCliWaitT=null; return; }
            fetch(url).then(r=>r.json()).then(d=>{
              if(d&&d.running) return;
              clearInterval(_gaCliWaitT); _gaCliWaitT=null;
              if(document.body.classList.contains('cli')) gaCliEnter(seq,'');
            }).catch(()=>{});
          },1000);
        }
        (function(){ let m='cli'; try{ m=localStorage.getItem('cm.gaUiMode')||'cli'; }catch(e){}
          _gaUi=(m==='gui')?'gui':'cli'; gaUiSync(); gaDashSync(); })();

        // ===== 컴포저 상태 — 폴더·작업량·작업모드·사진. gaExec()로 추가 payload에 실린다. =====
        let _gaComp={images:[],effort:'',mode:'',cwd:'',branch:'',model:''};   // images: [{data:dataURL,name}]
        let _gaReady=false;   // 초기 복원이 끝나기 전엔 서버 영속(gaComposerPersist)을 보류 — 복원값 에코 방지.
        let _gaFolders=null;   // /api/folders 캐시 (프리셋 폴더 목록)
        const _GA_EFFORTS=['','low','medium','high','xhigh','max'];
        const _GA_EFFORT_LABELS=['기본','낮음','보통','높음','매우 높음','최대'];
        // 작업 모드 = 베이스 모드(수동/편집수락/계획/자동, 라디오) + 권한 건너뛰기(독립 토글).
        // 실효 permission-mode = 건너뛰기 켜짐이면 bypassPermissions, 아니면 베이스 모드.
        const _GA_MODE_ITEMS=[['default','수동'],['acceptEdits','편집 수락'],['plan','계획'],['auto','자동']];
        let _gaBaseMode='auto';   // 마지막으로 고른 베이스 모드
        let _gaBypass=true;       // 권한 건너뛰기 — 기본 켜짐(기존 빈값 기본과 동일한 동작: 프롬프트 없이 실행)
        // 모델 선택 — 빈 값('')은 자동(CLI 기본값). 나머지는 서버의 claudeModelAlias 와 1:1.
        const _GA_MODELS=[['','자동'],['fable','Fable 5'],['opus','Opus 4.8'],['sonnet','Sonnet'],['haiku','Haiku']];
        // 실행 설정 수집 — 비어 있는 값은 넣지 않아(기본) 서버가 CLI 기본을 따르게 한다.
        function gaExec(){
          const o={};
          if(_gaComp.effort) o.effort=_gaComp.effort;
          if(_gaComp.mode)   o.mode=_gaComp.mode;
          if(_gaComp.cwd)    o.cwd=_gaComp.cwd;
          if(_gaComp.cwd && _gaComp.branch) o.branch=_gaComp.branch;
          if(_gaComp.model)  o.model=_gaComp.model;
          if(_gaComp.images.length) o.images=_gaComp.images.slice(0,5);
          return o;
        }
        // 작업량 슬라이더 (0=기본 · 1..5=low..max).
        function gaEffortSet(v){ const i=Math.max(0,Math.min(5,parseInt(v,10)||0));
          _gaComp.effort=_GA_EFFORTS[i]; const el=$('gaEffortLab'); if(el) el.textContent=_GA_EFFORT_LABELS[i];
          gaComposerPersist(); }
        // ── 작업 모드 드롭다운 (Claude Code 스타일: 라디오 4 + 권한 건너뛰기 토글) ──
        // _gaComp.mode(서버로 보내는 실효값)에서 베이스/건너뛰기 상태를 역산. 빈값('')은
        // 예전 기본(서버가 bypassPermissions 로 폴백)과 동일하게 자동+건너뛰기로 본다.
        function gaModeDerive(){ const m=_gaComp.mode;
          if(m==='bypassPermissions'){ _gaBypass=true; }
          else if(m===''){ _gaBypass=true; _gaBaseMode='auto'; }
          else if(['default','acceptEdits','plan','auto'].indexOf(m)>=0){ _gaBypass=false; _gaBaseMode=m; } }
        function gaModeLabel(){ const el=$('gaModeName'); if(!el) return;
          const base=(_GA_MODE_ITEMS.find(x=>x[0]===_gaBaseMode)||['auto','자동'])[1];
          el.textContent=_gaBypass?(base+' · 건너뛰기'):base; }
        function gaBuildModeMenu(){ const m=$('gaModeMenu'); if(!m) return;
          let h='<div class="mm-title">모드</div>';
          _GA_MODE_ITEMS.forEach((it,i)=>{ const on=(!_gaBypass && it[0]===_gaBaseMode);
            h+='<div class="fopt'+(on?' on':'')+'" onclick="gaModeBasePick(\''+it[0]+'\')">'
              +'<span class="nm">'+it[1]+'</span>'
              +(on?'<span class="ck">✓</span>':'')
              +'<span class="mm-k">'+(i+1)+'</span></div>'; });
          h+='<div class="mm-sep"></div>';
          h+='<div class="fopt'+(_gaBypass?' on':'')+'" onclick="gaModeBypassToggle()">'
            +'<span class="nm">권한 건너뛰기</span>'
            +'<span class="mm-state'+(_gaBypass?' act':'')+'">'+(_gaBypass?'활성화':'비활성화')+'</span></div>';
          m.innerHTML=h; }
        // 실효값 반영 + 라벨·메뉴 갱신 + 서버 영속. init 때는 persist=false 로 불필요한 쓰기 방지.
        function gaModeApply(persist){ _gaComp.mode=_gaBypass?'bypassPermissions':_gaBaseMode;
          gaModeLabel(); gaBuildModeMenu(); if(persist!==false) gaComposerPersist(); }
        function gaModeBasePick(v){ _gaBaseMode=v; gaModeApply(true); }
        function gaModeBypassToggle(){ _gaBypass=!_gaBypass; gaModeApply(true); }
        function gaModeInit(){ gaModeDerive(); gaModeLabel(); gaBuildModeMenu(); }
        function gaModeToggle(ev){ ev.stopPropagation(); const m=$('gaModeMenu'); if(!m) return;
          if(m.style.display==='block'){ m.style.display='none'; return; }
          gaBuildModeMenu(); m.style.display='block';
          const close=(e)=>{ if(!m.contains(e.target) && !e.target.closest('#gaModeChip')){ m.style.display='none'; document.removeEventListener('mousedown',close); } };
          setTimeout(()=>document.addEventListener('mousedown',close),0); }
        // 모델 세그먼트 렌더 + 선택 (작업 모드와 같은 ga-seg 스타일).
        function gaBuildModelSeg(){ const seg=$('gaModelSeg'); if(!seg) return;
          seg.innerHTML=_GA_MODELS.map(m=>'<button type="button" data-m="'+m[0]+'"'+(m[0]===_gaComp.model?' class="on"':'')
            +' onclick="gaModelSet(\''+m[0]+'\')">'+m[1]+'</button>').join(''); }
        function gaModelSet(m){ _gaComp.model=m; gaBuildModelSeg(); gaComposerPersist(); }
        // ── 작업 폴더 (프리셋 목록 + 직접 입력) ──
        function gaFolderToggle(ev){ ev.stopPropagation(); const m=$('gaFolderMenu'); if(!m) return;
          if(m.style.display==='block'){ m.style.display='none'; return; }
          m.style.display='block'; gaFolderRender();
          if(_gaFolders===null){ fetch('/api/folders').then(r=>r.json()).then(d=>{ _gaFolders=(d&&d.folders)||[]; gaFolderRender(); }).catch(()=>{ _gaFolders=[]; gaFolderRender(); }); }
          const close=(e)=>{ if(!m.contains(e.target) && !e.target.closest('.fchip')){ m.style.display='none'; document.removeEventListener('mousedown',close); } };
          setTimeout(()=>document.addEventListener('mousedown',close),0);
        }
        // 최근 사용 폴더 (MRU, 최대 8) — cm.gaFolderRecents:[{cwd,name,branch}]. 항목당 마지막
        // 사용 브랜치도 함께 기억해 같은 폴더를 다시 고르면 그 브랜치가 기본이 된다.
        // 최근 목록은 이제 서버가 소스 오브 트루스(window._gaServerCtx.recents, 서버가 MRU 관리).
        // 서버값이 없을 때만 예전 localStorage 로 폴백한다.
        function gaRecents(){ const sc=window._gaServerCtx&&window._gaServerCtx.recents;
          if(Array.isArray(sc)) return sc.filter(x=>x&&x.cwd);
          try{ const a=JSON.parse(localStorage.getItem('cm.gaFolderRecents')||'[]');
          return Array.isArray(a)?a.filter(x=>x&&x.cwd):[]; }catch(e){ return []; } }
        function gaRecentsPut(cwd,name,branch){ if(!cwd) return;
          const a=gaRecents().filter(x=>x.cwd!==cwd); a.unshift({cwd:cwd,name:name||cwd,branch:branch||''});
          try{ localStorage.setItem('cm.gaFolderRecents',JSON.stringify(a.slice(0,8))); }catch(e){} }
        function gaFolderRender(){ const m=$('gaFolderMenu'); if(!m) return;
          const cur=_gaComp.cwd;
          const row=(path,name,git,recent)=>{ const on=(path===cur)?' on':'';
            return '<div class="fopt'+on+'" onclick="gaFolderSet('+JSON.stringify(path).replace(/"/g,'&quot;')+','+JSON.stringify(name).replace(/"/g,'&quot;')+')">'
              +'<span class="nm">'+esc(name)+'</span>'+(recent?'<span class="recb">최근</span>':'')
              +(git?'<span class="gitb">git</span>':'')+'<span class="fp">'+esc(path)+'</span></div>'; };
          let html='<div class="fopt'+(cur?'':' on')+'" onclick="gaFolderSet(\'\',\'기본 (목표 폴더)\')"><span class="nm">기본 (목표 폴더)</span></div>';
          // 최근 사용이 먼저(마지막 사용이 맨 위), 그 다음 아직 안 나온 프리셋 폴더들.
          const seen={};
          gaRecents().forEach(r=>{ if(seen[r.cwd]) return; seen[r.cwd]=1;
            const p=(_gaFolders||[]).find(f=>f.path===r.cwd);
            html+=row(r.cwd, r.name||(p&&p.name)||r.cwd, !!(p&&p.git), true); });
          if(_gaFolders===null){ html+='<div class="fopt" style="pointer-events:none;color:var(--mut)">불러오는 중…</div>'; }
          else { html+=_gaFolders.filter(f=>!seen[f.path]).map(f=>row(f.path,f.name,f.git,false)).join(''); }
          html+='<div class="fcustom"><input type="text" id="gaFolderCustom" placeholder="폴더 경로 직접 입력 (예: /Users/…/repo)" '
            +'oninput="gaFolderBtnSync()" onkeydown="if(event.key===\'Enter\'){event.preventDefault();gaFolderCustom();}">'
            +'<button class="btn" id="gaFolderGo" onclick="gaFolderGo()">찾기</button></div>';
          m.innerHTML=html;
        }
        // 경로 입력이 비어 있으면 [찾기](네이티브 폴더 브라우저), 직접 입력을 시작하면 [지정]으로 바뀐다.
        function gaFolderBtnSync(){ const i=$('gaFolderCustom'),b=$('gaFolderGo'); if(!i||!b) return;
          b.textContent=String(i.value||'').trim()?'지정':'찾기'; }
        function gaFolderGo(){ const i=$('gaFolderCustom');
          if(i&&String(i.value||'').trim()){ gaFolderCustom(); return; }
          gaFolderBrowse(); }
        // 찾기: 네이티브 폴더 선택 패널을 연다 — 취소하면 현재 선택 유지.
        function gaFolderBrowse(){ post('/api/folders/pick').then(r=>r.json()).then(d=>{
          if(d&&d.ok&&d.path) gaFolderSet(d.path,(d.name||d.path)+' (직접)'); }).catch(()=>{}); }
        // 마지막 선택 폴더를 기억한다 — 보통 같은 폴더 작업을 이어가므로 다음 방문의 기본값이 된다.
        // 폴더가 바뀌면 그 폴더에서 마지막으로 쓰던 브랜치를 우선 복원하고 브랜치 칩을 동기화한다.
        function gaFolderSet(path,name){ _gaComp.cwd=path||''; const fn=$('gaFolderName'); if(fn) fn.textContent=name||(path?path:'기본 (목표 폴더)');
          const saved=gaRecents().find(x=>x.cwd===_gaComp.cwd);
          _gaComp.branch=(saved&&saved.branch)||'';
          gaFolderPersist();
          const m=$('gaFolderMenu'); if(m) m.style.display='none';
          gaBranchSync(); }
        function gaFolderPersist(){ const fn=$('gaFolderName');
          try{ localStorage.setItem('cm.gaFolder',JSON.stringify({cwd:_gaComp.cwd,name:fn?fn.textContent:'',branch:_gaComp.branch})); }catch(e){}
          if(_gaComp.cwd) gaRecentsPut(_gaComp.cwd, fn?fn.textContent:_gaComp.cwd, _gaComp.branch);
          gaComposerPersist(); }
        // 서버 영속: 변경마다 실행 컨텍스트 전체(폴더·브랜치·작업량·모드)를 보낸다(디바운스 250ms).
        // 서버가 recents MRU 를 관리하고 갱신된 컨텍스트를 돌려주므로 응답으로 window._gaServerCtx 를
        // 갱신해 이번 세션 내 최근목록도 즉시 최신이 된다. 검색 모드나 초기 복원 중엔 보내지 않는다.
        let _gaCompTimer=null;
        function gaComposerPersist(){ if(!_gaReady||_gaSearchMode) return;
          if(_gaCompTimer) clearTimeout(_gaCompTimer);
          _gaCompTimer=setTimeout(function(){ _gaCompTimer=null; const fn=$('gaFolderName');
            try{ fetch('/api/goal/composer',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({cwd:_gaComp.cwd||'',name:fn?fn.textContent:'',branch:_gaComp.branch||'',
                effort:_gaComp.effort||'',mode:_gaComp.mode||'',model:_gaComp.model||''})})
              .then(r=>r.json()).then(d=>{ if(d&&typeof d==='object') window._gaServerCtx=d; }).catch(function(){}); }catch(e){}
          },250); }
        function gaFolderCustom(){ const i=$('gaFolderCustom'); if(!i) return; const p=String(i.value||'').trim(); if(!p) return;
          const base=p.replace(/\/+$/,'').split('/').pop()||p; gaFolderSet(p, base+' (직접)'); }

        // ── 브랜치 칩: 선택 폴더가 git repo면 나타난다. 목록은 /api/folders/branches, 기본값은
        //    그 폴더에서 마지막으로 쓰던 브랜치(없으면 현재 체크아웃된 브랜치). 검색으로 필터. ──
        let _gaBranchInfo=null;   // {current,branches[]} — 현재 _gaComp.cwd 기준
        let _gaBranchQ='';
        function gaBranchSync(){ const wrap=$('gaBranchWrap'); _gaBranchInfo=null; _gaBranchQ='';
          const menu=$('gaBranchMenu'); if(menu) menu.style.display='none';
          if(!_gaComp.cwd){ _gaComp.branch=''; if(wrap) wrap.style.display='none'; return; }
          const want=_gaComp.cwd;
          fetch('/api/folders/branches?path='+encodeURIComponent(want)).then(r=>r.json()).then(d=>{
            if(_gaComp.cwd!==want) return;   // 로딩 중 폴더가 바뀌면 무시
            if(!d||!d.ok||!d.git||!(d.branches||[]).length){ _gaComp.branch=''; if(wrap) wrap.style.display='none'; return; }
            _gaBranchInfo={current:d.current||'',branches:d.branches};
            if(!_gaComp.branch || d.branches.indexOf(_gaComp.branch)<0) _gaComp.branch=d.current||d.branches[0];
            const bn=$('gaBranchName'); if(bn) bn.textContent=_gaComp.branch;
            if(wrap) wrap.style.display='';
            gaFolderPersist();
          }).catch(()=>{ if(wrap) wrap.style.display='none'; });
        }
        function gaBranchToggle(ev){ ev.stopPropagation(); const m=$('gaBranchMenu'); if(!m||!_gaBranchInfo) return;
          if(m.style.display==='block'){ m.style.display='none'; return; }
          _gaBranchQ=''; m.style.display='block'; gaBranchRender();
          const close=(e)=>{ if(!m.contains(e.target) && !e.target.closest('#gaBranchWrap')){ m.style.display='none'; document.removeEventListener('mousedown',close); } };
          setTimeout(()=>document.addEventListener('mousedown',close),0);
        }
        // 검색 입력은 고정 노드로 두고 목록만 다시 그린다 — 타이핑 중 포커스가 안 끊기게.
        function gaBranchRender(){ const m=$('gaBranchMenu'); if(!m) return;
          m.innerHTML='<div id="gaBranchList"></div>'
            +'<div class="fcustom"><input type="text" id="gaBranchSearch" placeholder="브랜치 검색…" '
            +'oninput="_gaBranchQ=this.value;gaBranchList()"></div>';
          gaBranchList();
          const inp=$('gaBranchSearch'); if(inp) setTimeout(()=>inp.focus(),30);
        }
        function gaBranchList(){ const host=$('gaBranchList'); if(!host||!_gaBranchInfo) return;
          const q=String(_gaBranchQ||'').toLowerCase();
          const list=_gaBranchInfo.branches.filter(b=>!q||b.toLowerCase().includes(q));
          host.innerHTML=list.length?list.map(b=>{ const on=(b===_gaComp.branch);
            return '<div class="fopt'+(on?' on':'')+'" onclick="gaBranchSet('+JSON.stringify(b).replace(/"/g,'&quot;')+')">'
              +'<span class="nm">'+esc(b)+'</span>'+(on?'<span class="ck">✓</span>':'')+'</div>'; }).join('')
            :'<div class="fopt" style="pointer-events:none;color:var(--mut)">일치하는 브랜치 없음</div>'; }
        function gaBranchSet(b){ _gaComp.branch=b; const bn=$('gaBranchName'); if(bn) bn.textContent=b;
          const m=$('gaBranchMenu'); if(m) m.style.display='none'; gaFolderPersist(); }
        // ── 사진 첨부 (최대 5장) ──
        function gaPick(){ const f=$('gaFile'); if(f) f.click(); }
        function gaPicked(files){ for(const f of (files||[])) gaAddImageFile(f); const fi=$('gaFile'); if(fi) fi.value=''; }
        function gaAddImageFile(file){ if(!file || !/^image\//.test(file.type||'')) return;
          if(_gaComp.images.length>=5){ const h=$('gaImgHint'); if(h) h.textContent='최대 5장까지 첨부할 수 있어요'; return; }
          const r=new FileReader(); r.onload=()=>{ if(_gaComp.images.length>=5) return; _gaComp.images.push({data:r.result,name:file.name||'image.png'}); vtev('imageAttach 컴포저 '+_gaComp.images.length+'/5'); gaRenderThumbs(); gaSaveImgDraft(); }; r.readAsDataURL(file); }
        function gaRemoveImg(i){ _gaComp.images.splice(i,1); vtev('imageRemove 컴포저 '+_gaComp.images.length+'/5'); gaRenderThumbs(); gaSaveImgDraft(); }
        function gaRenderThumbs(){ const t=$('gaThumbs'); if(!t) return;
          t.innerHTML=_gaComp.images.map((im,i)=>'<div class="thumb"><img src="'+im.data+'"><button class="x" onclick="gaRemoveImg('+i+')" title="제거">×</button></div>').join('');
          const h=$('gaImgHint'); if(h) h.textContent=_gaComp.images.length?(_gaComp.images.length+'/5장'):''; }

        // ── 초안: 대시보드의 이어쓰기 칩과 같은 localStorage 키(cm.gaDraft)를 쓴다.
        //    페이지에선 입력하는 동안 계속 저장한다(모달과 달리 닫힘 이벤트가 없을 수 있으므로). ──
        function gaSaveDraft(){ try{ const v=String($('gaText').value||'').trim();
          if(v) localStorage.setItem('cm.gaDraft',v); else localStorage.removeItem('cm.gaDraft'); }catch(e){} }
        // 첨부 사진 초안: 텍스트(cm.gaDraft)와 별도 키에 담는다 — 칩이 감시하는 문자열 형태는 건드리지 않는다.
        //   base64 dataURL 이라 용량이 커서 QuotaExceededError 가 날 수 있는데, 그 땐 조용히 이미지 초안만
        //   생략하고(직전 저장분은 그대로 남는다) 텍스트 초안·화면은 유지한다(실패 배너 없음).
        function gaSaveImgDraft(){ try{
          if(_gaComp.images.length) localStorage.setItem('cm.gaDraftImgs',JSON.stringify(_gaComp.images.slice(0,5)));
          else localStorage.removeItem('cm.gaDraftImgs'); }catch(e){} }
        function gaClearDraft(){ try{ localStorage.removeItem('cm.gaDraft'); }catch(e){}
          const ei=$('gaEditIcon'); if(ei) ei.style.display='none'; }
        // 추가 후 이미지는 비운다(이 목표 전용) — 폴더·작업량·모드는 다음 빠른 추가를 위해 유지.
        function gaClearImages(){ _gaComp.images=[]; gaRenderThumbs(); const fi=$('gaFile'); if(fi) fi.value='';
          try{ localStorage.removeItem('cm.gaDraftImgs'); }catch(e){} }

        // ── 이번 방문 집계: 페이지는 열린 채 계속 추가하므로, 방금 담은 것들을 아래에 쌓아 보여준다. ──
        let _gaTally=[];
        function gaTallyAdd(kind,text){ _gaTally.push({kind:kind,text:text});
          const box=$('gaTally'); if(box) box.classList.add('on');
          const n=$('gaTallyN'); if(n) n.textContent=String(_gaTally.length);
          const l=$('gaTallyList'); if(l) l.innerHTML=_gaTally.map(x=>
            '<div class="t-row"><span class="t-kind'+(x.kind==='직접 추가'?' direct':'')+'">'+x.kind+'</span><span class="t-txt">'+esc(x.text)+'</span></div>').join(''); }

        // ── 추가/AI추가/검색 — 서버 API는 모달 시절과 동일하다. ──
        function gaPayload(text){
          const o={text:text};
          if(_gaCtx.sprint) o.sprint=_gaCtx.sprint; if(_gaCtx.parent) o.parent=_gaCtx.parent; if(_gaCtx.bump) o.bump=true;
          const e=gaExec();
          if(e.effort) o.effort=e.effort; if(e.mode) o.mode=e.mode; if(e.cwd) o.cwd=e.cwd;
          if(e.branch) o.branch=e.branch; if(e.images) o.images=e.images;
          return o;
        }
        function gaAfterSubmit(){ const inp=$('gaText'); inp.value=''; if(inp._grow) inp._grow();
          gaClearDraft(); gaClearImages(); inp.focus(); }
        function gaAdd(){ const inp=$('gaText'); const t=String(inp.value||'').trim(); if(!t) return;
          post('/api/goal/add',gaPayload(t)).then(r=>r.json())
            .then(d=>{ if(d&&d.ok) gaGoalBorn(d.seq); }).catch(()=>{});
          gaTallyAdd('직접 추가',t); gaAfterSubmit(); }
        // 세션시작: 목표를 바로 추가하고(seq를 받아) 헤더 CLI/GUI 토글에 따라, 페이지 이동
        // 없이 이 화면을 세션 뷰로 전환한다.
        //   GUI - 메신저형 세션 뷰 (AI 출력 스트리밍 + 하단 컴포저)
        //   CLI - 페이지 안 임베디드 터미널(xterm)에서 인터랙티브 claude (gaCliEnter)
        // 첨부 이미지는 /api/goal/add 로 이미 목표에 실렸으므로 첫 턴에 서버가 동봉한다.
        // 실패 시 배너 없이 버튼만 되살린다 (no-user-facing-failure).
        function gaStart(){ const inp=$('gaText'); const t=String(inp.value||'').trim(); if(!t) return;
          const btn=$('gaStartBtn'); if(btn&&btn.disabled) return; if(btn) btn.disabled=true;
          post('/api/goal/add',gaPayload(t)).then(r=>r.json()).then(d=>{
            if(!(d&&d.ok&&d.seq>0)){ if(btn) btn.disabled=false; return; }
            gaClearDraft();
            if(_gaUi==='cli') gaCliEnter(d.seq,t); else gsEnter(d.seq,t);
          }).catch(()=>{ if(btn) btn.disabled=false; }); }
        function gaAi(){ const inp=$('gaText'); const t=String(inp.value||'').trim(); if(!t) return;
          if(_gaSearchMode){
            // 검색 모드의 [AI검색]: findOnly 큐 파이프라인(search:true) — 목표 생성 없이 유사도 분석만.
            post('/api/goal/queue/enqueue',{text:t,search:true}); gaAfterSubmit();
            const res=$('gaResults'); if(res) res.innerHTML='<div class="muted" style="font-size:12.5px;border:1px solid var(--line);border-radius:10px;padding:8px 12px;margin-top:6px">큐에 담겼습니다 — AI가 의미가 비슷한 목표를 분석 중입니다. 결과는 대시보드 <b>큐</b> 탭에 \'검색 결과\' 카드로 표시됩니다.<div style="margin-top:8px"><a href="/#view=queue" style="display:inline-block;color:var(--accent);font-weight:600;text-decoration:none">큐 페이지로 이동 →</a></div></div>';
            return;
          }
          post('/api/goal/queue/enqueue',gaPayload(t)); gaTallyAdd('AI 큐',t); gaAfterSubmit(); }

        // ── 검색(즉시 조회): 큐를 거치지 않는 로컬 검색 — /data.json 을 필요할 때 받아 캐시한다.
        //    숫자 → seq 정확 일치(상태 무관: 완료·릴리즈·보관·취소 포함), 텍스트 → 제목 부분일치. ──
        let _review=null,_reviewAt=0,_gsQuery='';
        function gsData(){ const now=Date.now();
          if(_review && now-_reviewAt<5000) return Promise.resolve(_review);
          return fetch('/data.json',{cache:'no-store'}).then(r=>r.json()).then(d=>{
            _review=(d&&d.review)||{goals:[]}; _reviewAt=Date.now(); return _review; }); }
        function gaSearch(){ const inp=$('gaText'); const t=String(inp.value||'').trim(); if(!t) return;
          _gsQuery=t; gsRender(); }
        function gsRefresh(){ if(_gsQuery) gsRender(); }
        function gsRender(){
          const host=$('gaResults'); if(!host) return;
          host.innerHTML='<div class="muted" style="font-size:12px;padding:6px 2px">찾는 중…</div>';
          gsData().then(r=>{
            const all=(r&&r.goals)||[];
            const t=_gsQuery;
            if(/^\d+$/.test(t)){
              const n=parseInt(t,10);
              const g=all.find(x=>(x.seq||0)===n && n>0);
              host.innerHTML=g?gsCard(g,all):gsMiss(n,all);
            } else {
              const q=t.toLowerCase();
              const hits=all.filter(x=>String(x.text||'').toLowerCase().includes(q)).slice(0,8);
              const qhits=((r&&r.aiQueue)||[]).filter(x=>!x.jobKind&&String(x.text||'').toLowerCase().includes(q)).slice(0,3);
              host.innerHTML=(hits.length||qhits.length)
                ? hits.map(g=>gsCard(g,all)).join('')+qhits.map(gsQueueRow).join('')
                : '<div class="muted" style="font-size:12.5px;padding:8px 2px">"'+esc(t)+'" 제목 일치 없음 — 표현이 다를 수 있으면 <b>AI검색</b>을 눌러보세요.</div>';
            }
          });
        }
        const STATUS_OPTS=[['backlog','대기'],['in_progress','진행'],['waiting','응답 대기'],['stopped','중지'],['cancelled','취소'],['done','완료']];
        function fmtDur(sec){ sec=Math.max(0,Math.floor(sec||0)); const h=(sec/3600)|0,m=((sec%3600)/60)|0;
          return h?(h+'시간 '+m+'분'):(m+'분'); }
        function fmtDate(epochSec){ if(!epochSec) return '–'; const q=CMTimeFilter.parts(epochSec*1000), p=n=>(n<10?'0':'')+n;
          return q.mo+'/'+q.d+' '+p(q.h)+':'+p(q.mi); }
        function sprintCode(n){ if(!n) return ''; const s=((_review&&_review.sprints)||[]).find(x=>x.number===n); return (s&&s.code)?s.code:('#'+n); }
        function gpill(g){ const n=g.seq||0; const t='goal-'+pad2(n);
          if(n<=0) return '<span class="pill" style="font-variant-numeric:tabular-nums">'+t+'</span>';
          return '<a class="pill" href="/goal?n='+n+'" title="골 페이지 — 정의·첨부 보기" style="font-variant-numeric:tabular-nums;color:var(--accent)">'+t+'</a>'; }
        // 목표가 속한 릴리즈: releaseId 우선, 레거시 레코드는 goalIds 로 역산.
        function gsRelOf(g){ const rels=(_review&&_review.releases)||[];
          return rels.find(r=>r.id===g.releaseId)||rels.find(r=>(r.goalIds||[]).includes(g.id))||null; }
        // 현재 위치 설명: 보드 어디에도 안 보이는 상태(릴리즈·보관·취소)를 사람이 읽게 풀어준다.
        function gsWhere(g){
          if(g.archived) return '보관함';
          if(g.released){ const rel=gsRelOf(g);
            return '릴리즈 '+((rel&&rel.code)?esc(rel.code):'')+((rel&&rel.releasedAt)?(' · '+fmtDate(rel.releasedAt)):''); }
          if(g.status==='cancelled') return '취소됨';
          if(g.sprint>0) return '스프린트 '+esc(sprintCode(g.sprint));
          return g.bump?'Dump out 인박스':'백로그';
        }
        function gsBadge(g){
          if(g.archived) return '<span class="pill" style="color:var(--mut)">보관</span>';
          if(g.released) return '<span class="pill" style="color:#5eead4;border-color:#134e4a">릴리즈됨</span>';
          const lab=(STATUS_OPTS.find(o=>o[0]===(g.status||'backlog'))||[])[1]||g.status;
          return '<span class="pill">'+esc(lab)+'</span>';
        }
        function gsCard(g,all){
          const kids=(all||[]).filter(x=>x.parent===g.id);
          const meta=['위치: '+gsWhere(g)];
          if(g.completedAt) meta.push('완료 '+fmtDate(g.completedAt));
          if(g.trackedSeconds>0) meta.push('누적 '+fmtDur(g.trackedSeconds));
          const kidRows=kids.length?('<div class="muted" style="font-size:12px;margin-top:6px;padding-left:10px;border-left:2px solid var(--line)">'
            +kids.slice(0,5).map(k=>'goal-'+pad2(k.seq||0)+' '+esc(k.text)).join('<br>')
            +(kids.length>5?('<br>… 외 '+(kids.length-5)+'개'):'')+'</div>'):'';
          return '<div style="border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin-top:8px">'
            +'<div class="row" style="gap:8px;flex-wrap:wrap">'+gpill(g)+gsBadge(g)
              +'<span style="font-weight:600">'+esc(g.text)+'</span></div>'
            +'<div class="muted" style="font-size:12px;margin-top:4px">'+meta.join(' · ')+'</div>'
            +kidRows
            +'<div class="row" style="gap:6px;margin-top:8px;flex-wrap:wrap">'+gsActions(g)+'</div></div>';
        }
        // 상태 → 액션 매핑: 활성=보기만, 완료·취소=다시 열기, 릴리즈=개별/전체 복원, 보관=해제.
        function gsActions(g){
          const view='<a class="btn" href="/goal?n='+(g.seq||0)+'" style="text-decoration:none" title="골 페이지 — 정의·첨부 보기">상세 보기 →</a>';
          if(g.archived)
            return view+'<button class="btn primary" onclick="gsAct(\'unarchive\',\''+g.id+'\')" title="보관을 해제해 활성 목록으로 되돌립니다">보관 해제</button>';
          if(g.released){
            const rel=gsRelOf(g);
            return view
              +'<button class="btn primary" onclick="gsAct(\'reopen\',\''+g.id+'\')" title="이 목표만 릴리즈에서 꺼내 백로그로 되돌립니다 — 릴리즈 기록은 그대로 남고 재오픈 표시가 붙습니다">이 목표만 다시 열기</button>'
              +(rel?('<button class="btn" onclick="gsAct(\'restore\',\''+rel.id+'\')" title="릴리즈 전체를 복원합니다 — 소속 목표 모두 활성으로, 스프린트도 다시 열립니다">릴리즈 전체 복원</button>'):'');
          }
          if(g.status==='done'||g.status==='cancelled')
            return view+'<button class="btn primary" onclick="gsAct(\'reopen\',\''+g.id+'\')" title="백로그로 되돌립니다 (번호 유지)">다시 열기</button>';
          return view;   // 활성(대기·진행·응답 대기·중지): 이미 보드에 있다 — 보기만 제공
        }
        // 카드 액션 실행 — 반영 후 캐시를 버리고 같은 검색을 다시 그린다.
        function gsAct(kind,id){
          const p = kind==='unarchive' ? post('/api/goal/archive',{id:id,archived:false})
                : kind==='restore'    ? post('/api/release/restore',{id:id})
                :                       post('/api/goal/reopen',{id:id});
          p.then(()=>{ _review=null; gsRefresh(); });
        }
        function gsMiss(n,all){
          const near=all.filter(g=>(g.seq||0)>0).map(g=>g.seq)
            .sort((a,b)=>Math.abs(a-n)-Math.abs(b-n)).slice(0,3);
          return '<div class="muted" style="font-size:12.5px;padding:8px 2px">goal-'+n+' — 없는 번호입니다. 큐 후보는 승급 전이라 번호가 없습니다.'
            +(near.length?('<div class="row" style="gap:6px;margin-top:6px;align-items:center">근접: '
              +near.map(s=>'<button class="btn" onclick="gsGo('+s+')">goal-'+pad2(s)+'</button>').join('')+'</div>'):'')
            +'</div>';
        }
        function gsGo(n){ const i=$('gaText'); if(i) i.value=String(n); gaSearch(); }
        function gsQueueRow(q){
          return '<div style="border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin-top:8px;opacity:.85">'
            +'<div class="row" style="gap:8px;flex-wrap:wrap"><span class="pill">큐 후보</span><span>'+esc(q.text)+'</span></div>'
            +'<div class="muted" style="font-size:12px;margin-top:4px">아직 번호가 없습니다 — 추가/스킵 확정은 대시보드 큐 탭에서.</div></div>';
        }

        // ===== 세션 뷰 (세션시작): 페이지 이동 없이 이 화면에서 chat2 턴을 돌린다. =====
        // 이벤트는 목표의 메신저 채널(/api/goal/chat2/stream?seq=N)을 그대로 쓰므로 대화
        // 기록은 목표 페이지에도 남는다. 컨벤션(chat-ui): AI 말풍선 금지(플레인 텍스트),
        // 도구는 요약 한 줄›드릴다운, 생각(thinking)은 흐린 스트림 → 턴이 이어지면 접힘.
        let _gs=null;           // 세션 상태 — null 이면 세션 뷰 아님
        let _gsImgs=[];         // 하단 컴포저의 턴 단위 이미지 첨부
        // marked(CDN, lazy) + 소독기 — 오프라인이면 플레인 텍스트 폴백 (목표 페이지와 동일).
        function loadMarked(cb){ if(window.marked){ if(cb) cb(); return; }
          let s=document.getElementById('gsMarkedJs');
          if(!s){ s=document.createElement('script'); s.id='gsMarkedJs';
            s.src='https://cdn.jsdelivr.net/npm/marked/marked.min.js'; document.head.appendChild(s); }
          if(cb) s.addEventListener('load',cb,{once:true}); }
        function sanitizeHTML(h){ return (h||'')
          .replace(/<\/?(script|style|iframe|object|embed|link|meta|base)[^>]*>/gi,'')
          .replace(/ on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi,'')
          .replace(/javascript:/gi,''); }
        function md(text){ if(window.marked){ try{ return sanitizeHTML(window.marked.parse(text||'',{breaks:true})); }catch(e){} }
          return esc(text||'').replace(/\n/g,'<br>'); }
        // ── CLI 세션 뷰 (세션시작의 CLI 토글): 공용 웹터미널 엔진 CMWebCLI(Sources/WebCLI,
        //    WebCLITerminal.script() 로 이 페이지에 동봉)를 페이지 안 xterm 터미널로 연다.
        //    xterm 버전·IME 인수·폴링은 전부 엔진 소관 — 여기는 얇은 어댑터만: 뷰 전환,
        //    상태 라벨, 그리고 첫 프롬프트(입력한 목표 텍스트)를 실은 cli/start POST.
        //    페이지를 떠나도 PTY는 백그라운드 유지(레일에서 재접속). ──
        let _cliCtl=null;
        function cliState(txt,cls){ const e=$('gaCliState'); if(e){ e.textContent=txt; e.className='st'+(cls?(' '+cls):''); } }
        function gaCliEnter(seq,firstText){
          _gaSessSeq=seq; gaGoalBorn(seq);
          vtev('cliOpen goal-'+pad2(seq)); window.cmView='cli';
          document.body.classList.add('cli');
          document.title='goal-'+pad2(seq)+' CLI';
          const ttl=$('gaTitle'); if(ttl) ttl.textContent='goal-'+pad2(seq)+' CLI 세션';
          const sub=$('gaSub'); if(sub) sub.innerHTML='인터랙티브 claude 가 이 터미널에서 진행됩니다 — 기록·첨부는 <a href="/goal?n='+seq+'" style="color:var(--accent)">목표 페이지</a>에 그대로 남습니다';
          gaClearImages();
          if(!_cliCtl) _cliCtl=CMWebCLI.create({termEl:$('gaCliTerm'),onState:cliState});
          else _cliCtl.reset();   // 재접속: 살아있는 PTY 가 버퍼 테일을 처음부터 다시 재생한다
          _cliCtl.connect((cols,rows)=>post('/api/goal/cli/start',{seq:seq,cols:cols,rows:rows,text:firstText}));
        }
        window.addEventListener('resize',()=>{ if(document.body.classList.contains('cli')&&_cliCtl) _cliCtl.fit(); });

        // 세션 하단 컴포저의 실행 컨텍스트 스트립을 채운다 — 작업 폴더(cwd 없으면 목표 폴더)
        // + 브랜치(있을 때만). 즉시 _gaComp 값으로 그리고(세션시작 경로에선 이게 정답),
        // 헤더 토글 재진입처럼 _gaComp 가 그 목표와 다를 수 있는 경우를 위해 goal 레코드로 보정한다.
        function gsRenderCtx(seq,cwd,branch){ const box=$('gsCtx'); if(!box) return;
          const folder=cwd ? (cwd.replace(/\/+$/,'').split('/').pop()||cwd)
                           : ('goal-'+pad2(seq||_gaSessSeq||0)+' (목표 폴더)');
          const ff=$('gsCtxFolder'); if(ff){ ff.textContent=folder; ff.title=cwd||''; }
          const bw=$('gsCtxBranch'), bn=$('gsCtxBranchName');
          if(cwd && branch){ if(bn) bn.textContent=branch; if(bw) bw.style.display=''; }
          else if(bw){ bw.style.display='none'; }
          box.style.display='flex'; }
        function gsSetCtx(seq){
          gsRenderCtx(seq,_gaComp.cwd,_gaComp.cwd?_gaComp.branch:'');
          // 그 목표의 저장된 실행 설정으로 보정 (side-effect 없이 스트립 DOM 만 갱신).
          try{ fetch('/data.json',{cache:'no-store'}).then(r=>r.json()).then(d=>{
            const gs=(d&&d.review&&d.review.goals)||[]; const g=gs.find(x=>x&&x.seq===seq);
            if(g && document.body.classList.contains('sess')) gsRenderCtx(seq,g.cwd||'',g.cwd?(g.branch||''):'');
          }).catch(function(){}); }catch(e){} }
        function gsEnter(seq,firstText){
          _gaSessSeq=seq; gaGoalBorn(seq);
          vtev('sessOpen goal-'+pad2(seq)); window.cmView='sess';
          _gs={seq:seq,sess:false,mode:_gaComp.mode||'bypassPermissions',allow:[],es:null,cur:null,text:'',sawText:false,
               think:null,thinkText:'',tools:null,toolCount:0,toolCards:{},running:false,lastMode:'',
               startedAt:0,tokens:0,workLabel:''};
          document.body.classList.add('sess');
          document.title='goal-'+pad2(seq)+' 세션';
          const ttl=$('gaTitle'); if(ttl) ttl.textContent='goal-'+pad2(seq)+' 세션';
          const sub=$('gaSub'); if(sub) sub.innerHTML='세션이 이 화면에서 진행됩니다 — 대화 기록·첨부는 <a href="/goal?n='+seq+'" style="color:var(--accent)">목표 페이지</a>에 그대로 남습니다';
          gsSetCtx(seq);
          const firstImgs=_gaComp.images.slice(0,5);
          gaClearImages(); loadMarked();
          gsUser(firstText,firstImgs);
          gsOpenStream();
          gsPost(firstText,[]);
          setTimeout(()=>{ const i=$('gsIn'); if(i) i.focus(); },80);
        }
        // 이어가기 진입 (CLI→GUI 토글): 첫 턴을 쏘지 않고 세션 뷰만 연다. sess=true 라
        // 전송은 /api/goal/session/say(최신 연결 세션 headless 재개), 수신은 &sess=1 SSE.
        function gsEnterResume(seq){
          _gaSessSeq=seq; gaGoalBorn(seq);
          vtev('sessResume goal-'+pad2(seq)); window.cmView='sess';
          _gs={seq:seq,sess:true,mode:_gaComp.mode||'bypassPermissions',allow:[],es:null,cur:null,text:'',sawText:false,
               think:null,thinkText:'',tools:null,toolCount:0,toolCards:{},running:false,lastMode:'',
               startedAt:0,tokens:0,workLabel:'',lastText:'',lastImgs:[]};
          document.body.classList.add('sess');
          document.title='goal-'+pad2(seq)+' 세션';
          const ttl=$('gaTitle'); if(ttl) ttl.textContent='goal-'+pad2(seq)+' 세션';
          const sub=$('gaSub'); if(sub) sub.innerHTML='터미널 세션을 이 뷰에서 이어갑니다 — 대화 기록은 <a href="/goal?n='+seq+'" style="color:var(--accent)">목표 페이지</a>에 그대로 남습니다';
          gsSetCtx(seq);
          loadMarked();
          const tx=$('gsStxt'); if(tx) tx.textContent='대기 중 — 아래 입력창으로 지시하면 방금 세션이 여기서 이어집니다';
          gsLoadHistory(seq);
          gsRestoreState(seq);
          setTimeout(()=>{ const i=$('gsIn'); if(i) i.focus(); },80);
        }
        // 세션 뷰 진입 시 지난 대화를 불러와 라이브 영역 맨 위에 그대로 렌더한다 — 세션을
        // 이어가지 않아도(전송 전에도) 이전 내용이 보인다. 소스는 목표 메신저 기록(우선) 또는
        // 최신 연결 세션 트랜스크립트(폴백, 서버가 판단). 뷰당 한 번만 실행하고 비면 아무것도
        // 그리지 않는다. 지난 어시스턴트 메시지의 cm-question 블록은 본문만 남기고 비활성으로
        // 렌더한다(과거 카드가 키보드를 가로채지 않도록).
        function gsLoadHistory(seq){
          if(!_gs||_gs.seq!==seq||_gs.histLoaded) return; _gs.histLoaded=true;
          fetch('/api/goal/session/history?seq='+seq,{cache:'no-store'})
            .then(r=>r.json()).then(d=>{
              if(!_gs||_gs.seq!==seq) return;
              const msgs=(d&&d.messages)||[]; if(!msgs.length) return;
              const live=$('gsLive'); if(!live) return;
              loadMarked(function(){
                if(!_gs||_gs.seq!==seq) return;
                const frag=document.createDocumentFragment();
                const top=document.createElement('div'); top.className='shist-note';
                top.textContent='지난 대화 기록 — 아래 입력창으로 이어가면 여기서 계속됩니다';
                frag.appendChild(top);
                msgs.forEach(m=>{
                  if(m.role==='user'){
                    const u=document.createElement('div'); u.className='su'; u.textContent=m.text||'';
                    const imgs=(m.images||[]);
                    if(imgs.length){ const w=document.createElement('div'); w.className='satt';
                      imgs.forEach(src=>{ const img=document.createElement('img'); img.src=src;
                        img.alt='첨부 이미지'; img.onclick=()=>gsImgView(src); w.appendChild(img); });
                      u.appendChild(w); }
                    frag.appendChild(u);
                  } else {
                    const a=document.createElement('div'); a.className='sa';
                    try{ const ex=gsExtractQ(m.text||''); a.innerHTML=md(ex.clean||''); }
                    catch(e){ a.textContent=m.text||''; }
                    frag.appendChild(a);
                  }
                });
                const sep=document.createElement('div'); sep.className='shist-sep';
                sep.innerHTML='<span>여기서부터 이어집니다</span>';
                frag.appendChild(sep);
                live.insertBefore(frag,live.firstChild);
                gsScroll(true);
              });
            }).catch(function(){});
        }
        // 재진입 시 중단 여부 가시화: 서버 턴 상태(/api/goal/chat2/state)로 "지금 돌고
        // 있는지 / 직전 턴이 어떻게 끝났는지"를 복원한다. 채널은 둘 다 본다 — 세션시작(GUI)
        // 턴은 메신저 채널(chat2/say), 이어가기 턴은 sess 채널(session/say)이라, sess 만
        // 열면 돌고 있는 메신저 턴의 진행이 안 보여 '중단'처럼 보인다.
        function gsRestoreState(seq){
          const st=u=>fetch(u).then(r=>r.json()).catch(()=>null);
          Promise.all([st('/api/goal/chat2/state?seq='+seq),
                       st('/api/goal/chat2/state?seq='+seq+'&sess=1')]).then(([chat,sess])=>{
            if(!_gs||_gs.seq!==seq) return;
            if(chat&&chat.running&&!(sess&&sess.running)) _gs.sess=false;   // 돌고 있는 채널을 잇는다
            gsOpenStream();
            const cur=(chat&&chat.running)?chat:((sess&&sess.running)?sess
              :((chat&&sess)?((chat.at>=sess.at)?chat:sess):(chat||sess)));
            if(!cur||cur.state==='none') return;
            const q=CMTimeFilter.parts(cur.at||Date.now()), p=n=>(n<10?'0':'')+n, hm=p(q.h)+':'+p(q.mi)+':'+p(q.s);
            if(cur.running){
              // 라이브 메트릭 복원: at=턴 시작 ms, tokens=지금까지 스트림된 output 토큰 —
              // 상태줄이 곧바로 "작업 중 — Bash · 3분 12초 · 453 tokens"로 이어진다.
              if(cur.at) _gs.startedAt=cur.at;
              if(cur.tokens) _gs.tokens=cur.tokens;
              let lab='작업 중'+(cur.label?(' — '+cur.label):'')+' · 진행 중인 턴을 이어서 수신합니다';
              if(cur.totalRunning>1) lab+=' · 실행 중 작업 '+cur.totalRunning+'개';
              gsWorking(true,lab); return;
            }
            const tx2=$('gsStxt'); if(!tx2) return;
            if(cur.state==='stopped') tx2.textContent='대기 중 — 직전 턴이 '+hm+'에 중단되었습니다(사용자 중단) · 이어서 지시하면 계속됩니다';
            else if(cur.state==='died') tx2.textContent='대기 중 — 직전 턴이 '+hm+'에 비정상 종료되었습니다 · 이어서 지시하면 계속됩니다';
            else if(cur.state==='error') tx2.textContent='대기 중 — 직전 턴이 '+hm+'에 오류로 끝났습니다 · 이어서 지시하면 계속됩니다';
            else if(cur.state==='done') tx2.textContent='대기 중 — 직전 턴 완료 '+hm+' · 아래 입력창으로 이어가세요';
          });
        }
        function gsOpenStream(){ if(!_gs||_gs.es) return;
          _gs.es=new EventSource('/api/goal/chat2/stream?seq='+_gs.seq+(_gs.sess?'&sess=1':''));
          _gs.es.onmessage=ev=>{ try{ gsEvt(JSON.parse(ev.data)); }catch(e){} }; }
        // override=true 면 이 턴만 전달한 mode 를 강제한다 (계획 승인 → acceptEdits 전환).
        // sess 세션(이어가기)은 session/say 로 간다 — 최신 연결 세션을 --resume 하는 경로라
        // 턴 이미지 동봉은 아직 지원되지 않는다 (gsSend 에서 안내).
        function gsPost(text,images,override){
          gsWorking(true,_gs.sess?'세션 재개 중…':'세션 시작 중…'); _gs.lastMode=_gs.mode;
          if(_gs.sess){
            post('/api/goal/session/say',{seq:_gs.seq,task:'',text:text,mode:_gs.mode,allow:_gs.allow})
              .then(r=>r.json()).then(d=>{
                if(!d||!d.ok){
                  gsNote(d&&d.error==='no-session'
                    ?'⚠️ 이어갈 세션을 찾지 못했습니다 — 터미널(CLI)로 전환해 계속하세요'
                    :'⚠️ 전송 실패 — 잠시 후 다시 시도하세요');
                  gsWorking(false); }
              }).catch(()=>{ gsNote('⚠️ 전송 실패 — 잠시 후 다시 시도하세요'); gsWorking(false); });
            return;
          }
          const body={seq:_gs.seq,task:'',text:text,mode:_gs.mode,model:'',allow:_gs.allow};
          if(images&&images.length) body.images=images;
          if(override) body.modeOverride=true;
          post('/api/goal/chat2/say',body).then(r=>r.json()).then(d=>{
            if(!d||!d.ok){ gsNote('⚠️ 전송 실패 — 잠시 후 다시 시도하세요'); gsWorking(false); }
          }).catch(()=>{ gsNote('⚠️ 전송 실패 — 잠시 후 다시 시도하세요'); gsWorking(false); });
        }
        // imgs: 첨부 이미지 [{data:dataURL,name}] — 클로드 코드처럼 말풍선 안에 실제
        // 썸네일로 보여준다 (클릭=원본 크기 오버레이). 숫자가 오면 개수 라벨 폴백.
        function gsUser(text,imgs){
          const live=$('gsLive'); if(!live) return;
          const u=document.createElement('div'); u.className='su'; u.textContent=text;
          if(Array.isArray(imgs)&&imgs.length){
            const w=document.createElement('div'); w.className='satt';
            imgs.forEach(im=>{ const img=document.createElement('img');
              img.src=im.data; img.alt=im.name||'첨부 이미지'; img.title=im.name||'';
              img.onclick=()=>gsImgView(im.data); w.appendChild(img); });
            u.appendChild(w);
            const i=document.createElement('span'); i.className='simgs';
            i.textContent='🖼 이미지 '+imgs.length+'장 첨부'; u.appendChild(i);
          } else if(imgs>0){ const i=document.createElement('span'); i.className='simgs'; i.textContent='🖼 이미지 '+imgs+'장 첨부'; u.appendChild(i); }
          live.appendChild(u); gsScroll(true);
        }
        // 썸네일 클릭 → 화면 전체 오버레이로 원본 보기 (클릭/ESC 로 닫힘).
        function gsImgView(src){
          let v=$('gsImgView');
          if(!v){ v=document.createElement('div'); v.id='gsImgView';
            v.appendChild(document.createElement('img'));
            v.onclick=()=>v.classList.remove('on');
            document.addEventListener('keydown',e=>{ if(e.key==='Escape') v.classList.remove('on'); });
            document.body.appendChild(v); }
          v.querySelector('img').src=src; v.classList.add('on');
        }
        function gsNote(msg){ const live=$('gsLive'); if(!live) return;
          const e=document.createElement('div'); e.className='sa'; e.textContent=msg; live.appendChild(e); gsScroll(); }
        // 상태줄 = 클로드 코드식 라이브 메트릭: "작업 중 — Bash · 3분 12초 · 453 tokens".
        // 경과는 _gs.startedAt(턴 시작/서버 복원), 토큰은 서버 stat 이벤트 누적. 1초 티커는
        // window._gsTick 하나만 유지한다. (goalsess.test.js 가 이 함수를 추출 실행하므로
        // 렌더는 함수 안에 자체 완결로 둔다 — 외부 헬퍼 참조 금지.)
        function gsWorking(on,label){
          if(_gs){ _gs.running=on;
            if(on){ if(label!=null) _gs.workLabel=label; if(!_gs.startedAt) _gs.startedAt=Date.now(); }
            else { _gs.startedAt=0; _gs.tokens=0; _gs.workLabel=''; } }
          const st=$('gsStat'); if(st) st.classList.toggle('working',on);
          const paint=function(){
            const tx=$('gsStxt'); if(!tx) return;
            if(!_gs||!_gs.running){ tx.textContent='대기 중 — 아래 입력창으로 이어서 지시할 수 있습니다'; return; }
            let s=_gs.workLabel||'작업 중…';
            const el=_gs.startedAt?Math.floor((Date.now()-_gs.startedAt)/1000):0;
            if(el>=1) s+=' · '+(el>=60?Math.floor(el/60)+'분 ':'')+(el%60)+'초';
            const tk=_gs.tokens||0;
            if(tk>0) s+=' · '+(tk>=1000?(Math.round(tk/100)/10)+'k':tk)+' tokens';
            tx.textContent=s;
          };
          if(on){ if(!window._gsTick) window._gsTick=setInterval(paint,1000); }
          else if(window._gsTick){ clearInterval(window._gsTick); window._gsTick=null; }
          paint();
          const s=$('gsSendBtn'),x=$('gsStopBtn'); if(s) s.style.display=on?'none':''; if(x) x.style.display=on?'':'none';
        }
        // 사용자가 위로 스크롤해 읽는 중이면 강제 스크롤하지 않는다 (force=사용자 액션 직후).
        function gsScroll(force){
          const nearBottom=(window.innerHeight+window.scrollY)>=(document.body.scrollHeight-260);
          if(force||nearBottom) window.scrollTo(0,document.body.scrollHeight);
        }
        // 진행 중이던 생각 블록을 "생각 과정 ›" 드릴다운으로 접는다.
        function gsThinkClose(){
          if(!_gs||!_gs.think) return;
          const s=_gs.think.querySelector('.tks'); if(s) s.textContent='생각 과정 ›';
          _gs.think.classList.add('closed'); _gs.think=null; _gs.thinkText='';
        }
        // 스트리밍 중이던 문단을 마크다운으로 확정한다 (도구 사용 직전 / 턴 종료 시).
        function gsFlushPara(final){
          if(!_gs.cur){
            if(final&&!_gs.sawText){ const d=document.createElement('div'); d.className='sa';
              gsRenderAssistant(d,final); $('gsLive').appendChild(d); }
            return;
          }
          _gs.cur.classList.remove('streaming');
          const t=(final!=null)?final:_gs.text;
          gsRenderAssistant(_gs.cur,t);
          _gs.cur=null; _gs.text='';
        }
        // ── cm-question 명확화 카드 (docs/cm-question-protocol.md) ──
        // 어시스턴트가 cm-question 코드블록으로 보낸 질문을 한 번에 하나씩 박스 카드로
        // 렌더한다. 목표 페이지 메신저(AppDelegate)의 extractQ/buildQcard 이식판 —
        // 전송만 이 뷰의 gsUser/gsPost 경로를 쓴다. 파싱 실패 시 원문 마크다운 폴백.
        function gsRenderAssistant(el,text){
          const ex=gsExtractQ(text);
          try{ el.innerHTML=ex.clean?md(ex.clean):''; }catch(e){ el.textContent=ex.clean; }
          if(ex.qs) el.appendChild(gsBuildQcard(ex.qs));
        }
        function gsExtractQ(text){
          const re=/```cm-question\s*([\s\S]*?)```/; const m=re.exec(text||'');
          if(!m) return {clean:(text||''), qs:null};
          let qs=null; try{ const o=JSON.parse(m[1]); qs=(o&&o.q)||null; }catch(e){ return {clean:text, qs:null}; }
          if(!qs||!qs.length) return {clean:text, qs:null};
          return {clean:(text.slice(0,m.index)+text.slice(m.index+m[0].length)).trim(), qs:qs};
        }
        // 활성 카드의 키보드 핸들러(숫자 선택·Enter 확정)는 항상 하나만.
        let _gsQKey=null;
        function gsSetQKey(h){ if(_gsQKey) document.removeEventListener('keydown',_gsQKey,true);
          _gsQKey=h; if(h) document.addEventListener('keydown',h,true); }
        function gsBuildQcard(qs){
          const answers=new Array(qs.length).fill(null); let idx=0, sel=-1;
          const card=document.createElement('div'); card.className='qcard';
          function submit(){
            gsSetQKey(null); card.classList.add('answered');
            const msg=qs.map((q,i)=>(i+1)+'. '+(q.ask||'')+' → '+(answers[i]||'(미응답)')).join('\n');
            gsUser(msg,0); gsPost(msg,[]);
          }
          function advance(val){ answers[idx]=val; if(idx<qs.length-1){ idx++; draw(); } else { draw(); submit(); } }
          function confirmSel(){
            const fi=card.querySelector('.qfreein'); const fv=fi?fi.value.trim():'';
            if(fv){ advance(fv); return; }
            const opts=qs[idx].opts||[];
            if(sel>=0&&opts[sel]) advance(opts[sel].label||('선택지 '+(sel+1)));
          }
          function draw(){
            const q=qs[idx], opts=q.opts||[]; card.innerHTML='';
            sel=-1; for(let i=0;i<opts.length;i++){ if(opts[i].rec){ sel=i; break; } }
            if(sel<0&&opts.length) sel=0;
            const head=document.createElement('div'); head.className='qhead';
            head.innerHTML='<span class="qcount">'+(idx+1)+'/'+qs.length+'</span><span class="qtitle">'+esc(q.ask||'')+'</span>';
            const ctr=document.createElement('span'); ctr.className='qctrls';
            const col=document.createElement('button'); col.className='qicon'; col.textContent='⌄'; col.title='접기';
            const cls=document.createElement('button'); cls.className='qicon'; cls.textContent='×'; cls.title='닫기';
            ctr.appendChild(col); ctr.appendChild(cls); head.appendChild(ctr); card.appendChild(head);
            const body=document.createElement('div'); body.className='qbody'; card.appendChild(body);
            col.onclick=()=>{ body.style.display=(body.style.display==='none')?'':'none'; };
            cls.onclick=()=>{ gsSetQKey(null); card.remove(); };
            function paint(){ const rs=body.querySelectorAll('.qopt'); for(let k=0;k<rs.length;k++){ rs[k].classList.toggle('sel', k===sel); } }
            opts.forEach((op,oi)=>{
              const key=op.label||('선택지 '+(oi+1));
              const btn=document.createElement('button'); btn.className='qopt';
              let desc=op.why||''; if(op.rec){ desc=desc?(desc+' · 추천'):'추천'; }
              btn.innerHTML='<div class="qmain"><span class="qlabel">'+esc(key)+'</span>'+(desc?'<span class="qwhy">'+esc(desc)+'</span>':'')+'</div><span class="qnum">'+(oi+1)+'</span>';
              btn.onclick=()=>{ sel=oi; const fi=card.querySelector('.qfreein'); if(fi) fi.value=''; paint(); };
              body.appendChild(btn);
            });
            const etc=document.createElement('button'); etc.className='qopt qetc';
            etc.innerHTML='<div class="qmain"><span class="qlabel">기타</span></div><span class="qnum">'+(opts.length+1)+'</span>';
            body.appendChild(etc);
            const fin=document.createElement('input'); fin.type='text'; fin.className='qfreein'; fin.placeholder='여기에 답변을 입력하세요';
            body.appendChild(fin);
            etc.onclick=()=>{ sel=-1; paint(); fin.focus(); };
            fin.addEventListener('input',()=>{ if(fin.value){ sel=-1; paint(); } });
            fin.addEventListener('keydown',e=>{ if(e.key==='Enter'&&!e.isComposing){ e.preventDefault(); confirmSel(); } });
            const foot=document.createElement('div'); foot.className='qfoot';
            const skip=document.createElement('button'); skip.className='qskip'; skip.textContent='건너뛰기'; skip.onclick=()=>advance(null);
            const nb=document.createElement('button'); nb.className='qnextbtn'; nb.textContent=(idx<qs.length-1?'다음 ⏎':'완료 ⏎'); nb.onclick=()=>confirmSel();
            foot.appendChild(skip); foot.appendChild(nb); card.appendChild(foot);
            paint();
            gsSetQKey(function(e){
              const ae=document.activeElement, tag=ae?ae.tagName:'';
              if(tag==='INPUT'||tag==='TEXTAREA') return;
              if(e.key==='Enter'){ e.preventDefault(); confirmSel(); return; }
              const n=parseInt(e.key,10); if(isNaN(n)) return;
              if(n>=1&&n<=opts.length){ e.preventDefault(); sel=n-1; const fi=card.querySelector('.qfreein'); if(fi) fi.value=''; paint(); }
              else if(n===opts.length+1){ e.preventDefault(); sel=-1; paint(); fin.focus(); }
            });
          }
          draw(); return card;
        }
        function gsEvt(o){
          const live=$('gsLive'); if(!live||!_gs) return;
          if(o.t==='start'){
            _gs.text=''; _gs.cur=null; _gs.sawText=false; _gs.tools=null; _gs.toolCount=0; _gs.toolCards={};
            _gs.startedAt=Date.now(); _gs.tokens=0;
            gsThinkClose(); gsWorking(true,'작업 중…');
          } else if(o.t==='stat'){
            // 서버 토큰 카운터 (API 콜당 한 번) — 상태줄 "N tokens" 갱신.
            if(o.tokens) _gs.tokens=o.tokens;
            if(_gs.running) gsWorking(true);
          } else if(o.t==='delta'){
            gsThinkClose();
            if(!_gs.cur){ _gs.cur=document.createElement('div'); _gs.cur.className='sa streaming'; live.appendChild(_gs.cur); _gs.text=''; }
            _gs.text+=o.text; _gs.sawText=true;
            // cm-question 블록은 스트리밍 중 raw JSON 을 보이지 않는다 — done 에서 카드로 바뀐다.
            const qi=_gs.text.indexOf('```cm-question');
            if(qi>=0){ _gs.cur.innerHTML=(qi>0?esc(_gs.text.slice(0,qi)):'')+'<span class="qhint">질문 준비 중…</span>'; }
            else { _gs.cur.textContent=_gs.text; }
            gsScroll();
          } else if(o.t==='think'){
            if(!_gs.think){ const w=document.createElement('div'); w.className='sthink';
              const s=document.createElement('div'); s.className='tks'; s.textContent='✳ 생각 중…';
              const b=document.createElement('div'); b.className='tkb';
              s.onclick=function(){ w.classList.toggle('closed'); };
              w.appendChild(s); w.appendChild(b); live.appendChild(w); _gs.think=w; _gs.thinkText='';
              _gs.tools=null;   // 생각 뒤 도구는 새 요약 묶음으로
            }
            _gs.thinkText+=o.text; _gs.think.querySelector('.tkb').textContent=_gs.thinkText; gsScroll();
          } else if(o.t==='tool'){
            gsThinkClose(); gsFlushPara(null);
            if(!_gs.tools){ const sum=document.createElement('div'); sum.className='stoolsum';
              const box=document.createElement('div'); box.className='stoolbox';
              sum.onclick=function(){ box.classList.toggle('open'); };
              live.appendChild(sum); live.appendChild(box); _gs.tools={sum:sum,box:box}; }
            _gs.toolCount++; _gs.tools.sum.textContent='사용함 도구 '+_gs.toolCount+'개 ›';
            let arg=''; try{ if(o.input){ arg=o.input.command?('$ '+o.input.command):(o.input.file_path||o.input.pattern||''); } }catch(e){}
            const row=document.createElement('div'); row.className='strow'; row.textContent=o.name+(arg?('  '+arg):'');
            const det=document.createElement('div'); det.className='strdet';
            row.onclick=function(){ if(det.textContent) det.classList.toggle('open'); };
            _gs.tools.box.appendChild(row); _gs.tools.box.appendChild(det);
            if(o.id) _gs.toolCards[o.id]=det;
            gsWorking(true,'작업 중 — '+o.name); gsScroll();
          } else if(o.t==='toolresult'){
            const r=_gs.toolCards[o.id]; if(r) r.textContent=o.text||'';
          } else if(o.t==='done'){
            gsThinkClose();
            gsFlushPara(_gs.cur?_gs.text:(o.result||''));
            if(o.cost){ const c=document.createElement('div'); c.className='scost';
              const cm=['$'+(Math.round(o.cost*10000)/10000)];
              if(o.tokens>0) cm.push((o.tokens>=1000?(Math.round(o.tokens/100)/10)+'k':o.tokens)+' tokens');
              if(_gs.startedAt){ const ce=Math.floor((Date.now()-_gs.startedAt)/1000);
                if(ce>=1) cm.push((ce>=60?Math.floor(ce/60)+'분 ':'')+(ce%60)+'초'); }
              c.textContent=cm.join(' · '); live.appendChild(c); }
            if(o.denials&&o.denials.length){ gsPerm(o.denials); }
            else if(_gs.lastMode==='plan'){ gsPlanRun(); }
            gsWorking(false); _gs.tools=null; gsScroll();
          } else if(o.t==='stopped'){
            gsThinkClose(); gsFlushPara(null); gsWorking(false); _gs.tools=null;
            // 중단 가시화: 왜 멈췄는지 본문에 남긴다 — user=중단 버튼, died=프로세스가
            // 결과 없이 사라진 비정상 종료 (예전엔 이 케이스가 아무 표시 없이 침묵했다).
            gsNote(o.reason==='died'
              ?'⏹ 턴이 비정상 중단되었습니다 — 이어서 지시하면 계속됩니다'
              :'⏹ 중단되었습니다 — 이어서 지시하면 계속됩니다');
            // 직전에 보낸 내용이 있으면 '다시작성'으로 입력창에 되살릴 수 있게 한다.
            if(_gs.lastText||(_gs.lastImgs&&_gs.lastImgs.length)) gsRedraftBtn();
          } else if(o.t==='error'){
            gsThinkClose(); gsFlushPara(null); gsNote('⚠️ '+(o.message||'오류')); gsWorking(false); _gs.tools=null;
          }
        }
        // 수동 모드에서 거부된 도구: 허용하고 계속 / 거부 (허용 목록은 이 세션 뷰에서만 유지).
        function gsPerm(denials){
          const live=$('gsLive');
          const card=document.createElement('div'); card.className='gs-perm';
          const lines=denials.map(d=>{ const i=d.tool_input||{}; const a=i.command?('$ '+i.command):(i.file_path||''); return d.tool_name+(a?('  '+a):''); });
          card.innerHTML='<div class="pq">권한 요청</div>'+lines.map(n=>'<code>'+esc(n)+'</code>').join('');
          const tools=denials.map(d=>d.tool_name).filter((v,i,a)=>a.indexOf(v)===i);
          const row=document.createElement('div'); row.className='prow';
          const allow=document.createElement('button'); allow.className='btn primary'; allow.textContent='허용하고 계속';
          allow.onclick=()=>{ card.remove(); tools.forEach(t=>{ if(_gs.allow.indexOf(t)<0) _gs.allow.push(t); });
            gsUser('(권한 허용)',0); gsPost('권한을 허용했습니다. 방금 하려던 작업을 계속 진행하세요.',[]); };
          const deny=document.createElement('button'); deny.className='btn'; deny.textContent='거부';
          deny.onclick=()=>card.remove();
          row.appendChild(allow); row.appendChild(deny); card.appendChild(row);
          live.appendChild(card); gsScroll();
        }
        // 계획 모드: 제시된 계획을 승인하면 acceptEdits 로 전환해 실행을 잇는다.
        function gsPlanRun(){
          const live=$('gsLive');
          const b=document.createElement('button'); b.className='planrun'; b.textContent='이 계획대로 실행 ▶';
          b.onclick=()=>{ b.disabled=true; _gs.mode='acceptEdits';
            gsUser('(계획 승인 — 실행)',0); gsPost('위 계획을 승인합니다. 계획대로 실행하세요.',[],true); };
          live.appendChild(b); gsScroll();
        }
        function gsSend(){
          if(!_gs) return; const ta=$('gsIn'); if(!ta) return;
          const t=String(ta.value||'').trim();
          if((!t&&!_gsImgs.length)||_gs.running) return;
          // 이어가기(sess) 경로는 턴 이미지 동봉 미지원 — 조용히 버리지 않고 알려준다.
          if(_gs.sess&&_gsImgs.length){
            _gsImgs=[]; gsThumbsRender();
            gsNote('이어가기 모드에서는 이미지 첨부가 아직 지원되지 않습니다 — 텍스트만 전송됩니다');
            if(!t) return;
          }
          const imgs=_gsImgs.slice(0,5); _gsImgs=[]; gsThumbsRender();
          ta.value=''; ta.style.height='auto';
          // 다시작성용으로 방금 보낸 내용을 보관한다 — 중단되면 입력창으로 되살린다.
          _gs.lastText=t; _gs.lastImgs=imgs.slice();
          gsUser(t||'(이미지 첨부)',imgs);
          gsPost(t||'첨부한 이미지를 확인해 주세요.',imgs);
        }
        // 중단 뒤 '다시작성' — 직전에 보낸 내용(텍스트·이미지)을 입력창으로 되살려
        // 사용자가 고쳐서 다시 보낼 수 있게 한다. 자동 재전송은 하지 않는다.
        function gsRedraft(){
          if(!_gs) return; const ta=$('gsIn');
          if(ta){ ta.value=_gs.lastText||''; ta.style.height='auto';
            ta.style.height=Math.min(ta.scrollHeight,220)+'px'; }
          if(Array.isArray(_gs.lastImgs)&&_gs.lastImgs.length){ _gsImgs=_gs.lastImgs.slice(0,5); gsThumbsRender(); }
          if(ta) ta.focus();
        }
        // 중단 알림 아래에 붙는 '다시작성' 버튼 (계획 실행 버튼과 같은 스타일).
        function gsRedraftBtn(){
          const live=$('gsLive'); if(!live) return;
          const b=document.createElement('button'); b.className='planrun'; b.textContent='↻ 다시작성';
          b.title='직전에 보낸 내용을 입력창으로 되살립니다 — 고쳐서 다시 보낼 수 있습니다';
          b.onclick=()=>{ b.disabled=true; gsRedraft(); };
          live.appendChild(b); gsScroll();
        }
        function gsStop(){ if(!_gs) return;
          post(_gs.sess?'/api/goal/session/stop':'/api/goal/chat2/stop',{seq:_gs.seq,task:''}); }
        // 하단 컴포저 이미지: 붙여넣기/끌어놓기 — 보내는 턴에만 동봉된다 (턴 단위 첨부).
        function gsAddImageFile(file){ if(!file||!/^image\//.test(file.type||'')) return;
          if(_gsImgs.length>=5){ const h=$('gsImgHint'); if(h) h.textContent='최대 5장까지'; return; }
          const r=new FileReader(); r.onload=()=>{ if(_gsImgs.length>=5) return;
            _gsImgs.push({data:r.result,name:file.name||'image.png'}); vtev('imageAttach 세션 '+_gsImgs.length+'/5'); gsThumbsRender(); }; r.readAsDataURL(file); }
        function gsRemoveImg(i){ _gsImgs.splice(i,1); vtev('imageRemove 세션 '+_gsImgs.length+'/5'); gsThumbsRender(); }
        function gsThumbsRender(){ const t=$('gsThumbs'); if(!t) return;
          t.innerHTML=_gsImgs.map((im,i)=>'<div class="thumb"><img src="'+im.data+'"><button class="x" onclick="gsRemoveImg('+i+')" title="제거">×</button></div>').join('');
          const h=$('gsImgHint'); if(h) h.textContent=_gsImgs.length?(_gsImgs.length+'/5장'):''; }
        // 하단 컴포저 배선: 오토그로우 · IME-safe Enter · 이미지 paste/drop.
        (function(){
          const ta=$('gsIn'); if(!ta) return;
          function grow(){ ta.style.height='auto'; ta.style.height=Math.min(ta.scrollHeight,220)+'px'; }
          ta.addEventListener('input',grow);
          ta.addEventListener('keydown',function(e){
            if(e.key!=='Enter'||e.shiftKey||e.isComposing) return; e.preventDefault(); gsSend(); });
          ta.addEventListener('paste',function(e){
            const items=(e.clipboardData&&e.clipboardData.items)||[];
            for(const it of items){ if(it.type&&it.type.indexOf('image')===0){ const f=it.getAsFile(); if(f){ e.preventDefault(); gsAddImageFile(f); } } }
          });
          const bar=$('gsBar');
          if(bar){ const inner=bar.querySelector('.inner');
            bar.addEventListener('dragover',function(e){ e.preventDefault(); if(inner) inner.classList.add('chatdrop'); });
            bar.addEventListener('dragleave',function(){ if(inner) inner.classList.remove('chatdrop'); });
            bar.addEventListener('drop',function(e){ e.preventDefault(); if(inner) inner.classList.remove('chatdrop');
              const fs=(e.dataTransfer&&e.dataTransfer.files)||[]; for(const f of fs) gsAddImageFile(f); });
          }
        })();

        // ── 페이지 초기화: 모드별 문구/버튼, 초안 복원, 입력 배선(오토그로우·IME-safe Enter·이미지) ──
        (function(){
          const where=$('gaWhere'); if(where) where.textContent=_gaCtx.label?('· '+_gaCtx.label):'';
          if(_gaSearchMode){
            document.title='목표 검색';
            document.querySelectorAll('.ga-execonly').forEach(el=>{ el.style.display='none'; });
            const ttl=$('gaTitle'); if(ttl) ttl.textContent='목표 검색';
            const sub=$('gaSub'); if(sub) sub.textContent='번호·제목으로 즉시 찾고, 표현이 다르면 AI검색으로 의미 검색';
            const inp=$('gaText'); if(inp) inp.placeholder='goal 번호(예: 346) 또는 제목 일부 — Enter로 즉시 조회';
            const aiB=$('gaAiBtn'); if(aiB){ aiB.classList.remove('primary'); aiB.textContent='AI검색';
              aiB.title='표현이 달라도 의미가 비슷한 목표를 AI가 찾습니다 — 큐에 담겨 비동기로 분석, 결과는 대시보드 큐 탭'; }
            const seB=$('gaSearchBtn'); if(seB) seB.classList.add('primary');
            const adB=$('gaAddBtn'); if(adB) adB.style.display='none';   // 검색 모드에서 '추가'는 혼란만 준다
            const hint=$('gaHint'); if(hint) hint.innerHTML='<b>검색</b>은 번호를 넣으면 그 목표를 <b>상태와 무관하게</b>(완료·릴리즈·보관·취소 포함) 즉시 찾고, 텍스트면 제목 부분일치로 찾습니다. 표현이 달라 못 찾으면 <b>AI검색</b> — AI가 의미가 비슷한 목표를 찾아 대시보드 큐 탭에 결과를 남깁니다.';
          } else if(_gaCtx.label){ document.title='목표 추가 · '+_gaCtx.label; }
          // 마지막 선택 폴더·브랜치 복원 (추가 모드만) — 보통 같은 폴더 작업을 이어가므로 그대로
          // 기본값. 브랜치 칩은 gaBranchSync가 실제 브랜치 목록과 대조해 표시/보정한다.
          // 서버 영속 컨텍스트(window._gaServerCtx)를 먼저 복원한다 — dynamic 포트로 origin 이 바뀌어도
          // 재시작 후 그대로 유지되는 소스. 작업량·모드는 폴더 없이도 복원하고, 폴더가 있으면 폴더·브랜치까지.
          // 서버값이 없을 때만 예전 localStorage(cm.gaFolder)로 폴백한다(구버전 상태 흡수).
          if(!_gaSearchMode){ try{
            const sc=window._gaServerCtx||{};
            if(sc.effort){ const ei=_GA_EFFORTS.indexOf(sc.effort);
              if(ei>0){ const sl=$('gaEffort'); if(sl) sl.value=ei; gaEffortSet(ei); } }
            if(sc.mode) _gaComp.mode=sc.mode;   // 모드 드롭다운은 아래 gaModeInit 이 역산·반영
            if(sc.model) _gaComp.model=sc.model;   // 모델 세그먼트는 아래 gaBuildModelSeg 가 반영
            if(sc.cwd){ _gaComp.cwd=sc.cwd; _gaComp.branch=sc.branch||'';
              const fn=$('gaFolderName'); if(fn) fn.textContent=sc.name||sc.cwd; gaBranchSync(); }
            else { const f=JSON.parse(localStorage.getItem('cm.gaFolder')||'null');
              if(f&&f.cwd){ _gaComp.cwd=f.cwd; _gaComp.branch=f.branch||'';
                const fn=$('gaFolderName'); if(fn) fn.textContent=f.name||f.cwd; gaBranchSync(); } }
          }catch(e){} }
          _gaReady=true;   // 복원 완료 — 이제부터의 변경은 서버에 영속한다.
          const gt=$('gaText');
          // 초안 복원(추가 모드만) — 검색 모드 입력은 초안과 무관하다.
          if(!_gaSearchMode){ try{ const d=localStorage.getItem('cm.gaDraft')||'';
            if(d.trim()){ gt.value=d; const ei=$('gaEditIcon'); if(ei) ei.style.display=''; } }catch(e){} }
          // 첨부 사진 초안 복원(추가 모드만) — 다른 페이지로 갔다 와도 붙였던 사진이 남도록.
          if(!_gaSearchMode){ try{ const raw=localStorage.getItem('cm.gaDraftImgs');
            if(raw){ const arr=JSON.parse(raw); if(Array.isArray(arr)){
              _gaComp.images=arr.filter(im=>im&&im.data).slice(0,5); gaRenderThumbs(); } } }catch(e){} }
          function grow(){ gt.style.height='auto'; gt.style.height=Math.min(gt.scrollHeight,320)+'px'; }
          gt.addEventListener('input',function(){ grow(); if(!_gaSearchMode) gaSaveDraft(); }); gt._grow=grow; grow();
          // Enter 라우팅: Enter=제출(줄바꿈 막음), Shift+Enter=줄바꿈, IME 조합 중엔 통과.
          // 검색 모드면 Enter → 검색(찾기만), 아니면 Enter → AI추가(찾고+만들기). ESC → 대시보드.
          gt.addEventListener('keydown',function(e){
            if(e.key==='Escape' && !e.isComposing){ e.preventDefault(); gaBack(); return; }
            if(e.key!=='Enter' || e.shiftKey || e.isComposing) return;
            e.preventDefault();
            if(_gaSearchMode){ gaSearch(); return; }
            gaAi();
          });
          // 세션(GUI) 뷰에서 턴이 돌고 있으면 Esc = 중단. CLI 뷰의 Esc 는 claude TUI 의
          // 키라 건드리지 않는다. 이미지 오버레이가 열려 있으면 그게 먼저 Esc 로 닫힌다.
          document.addEventListener('keydown',function(e){
            if(e.key!=='Escape'||e.isComposing) return;
            if(!document.body.classList.contains('sess')) return;
            const iv=$('gsImgView'); if(iv&&iv.classList.contains('on')) return;
            if(_gs&&_gs.running){ e.preventDefault(); e.stopPropagation(); gsStop(); }
          });
          // 세션/CLI 뷰에선 ESC 이탈을 막는다 — 진행 중 화면을 실수로 떠나지 않게
          // (CLI 뷰의 ESC 는 claude TUI 의 키이기도 하다).
          document.addEventListener('keydown',function(e){
            if(document.body.classList.contains('sess')||document.body.classList.contains('cli')) return;
            if(e.key==='Escape' && document.activeElement!==gt) gaBack(); });
          // 이미지 붙여넣기 / 끌어놓기 — compbox 위에서 받는다 (최대 5장).
          const box=$('gaCompBox');
          gt.addEventListener('paste',function(e){
            const items=(e.clipboardData&&e.clipboardData.items)||[];
            for(const it of items){ if(it.type&&it.type.indexOf('image')===0){ const f=it.getAsFile(); if(f){ e.preventDefault(); gaAddImageFile(f); } } }
          });
          if(box){
            box.addEventListener('dragover',function(e){ e.preventDefault(); box.classList.add('chatdrop'); });
            box.addEventListener('dragleave',function(){ box.classList.remove('chatdrop'); });
            box.addEventListener('drop',function(e){ e.preventDefault(); box.classList.remove('chatdrop');
              const fs=(e.dataTransfer&&e.dataTransfer.files)||[]; gaPicked(fs); });
          }
          gaModeInit(); gaBuildModelSeg(); gaRenderThumbs();
          // 목표 페이지 헤더의 CLI/GUI 토글에서 되돌아오는 진입 (/goal-add?goal=N&ui=cli|gui):
          // 컴포저를 건너뛰고 그 목표의 세션 뷰를 바로 연다 — CLI=살아있는 PTY 재접속/--resume,
          // GUI=최신 연결 세션 이어가기 뷰. 헤더 토글 상태·기본 모드도 함께 맞춘다.
          const backSeq=parseInt(_qs.get('goal')||'0',10)||0;
          if(backSeq>0 && !_gaSearchMode){
            const m=(_qs.get('ui')==='gui')?'gui':'cli';
            _gaUi=m; try{ localStorage.setItem('cm.gaUiMode',m); }catch(e){}
            try{ localStorage.setItem('cm.lastTab.'+backSeq,m); }catch(e){}
            gaUiSync();
            if(m==='gui') gsEnterResume(backSeq); else gaCliEnter(backSeq,'');
            return;
          }
          setTimeout(()=>{ gt.focus(); const n=gt.value.length; try{ gt.setSelectionRange(n,n); }catch(_){} },50);
        })();
        </script>
        </body></html>
        """#
    }
}
