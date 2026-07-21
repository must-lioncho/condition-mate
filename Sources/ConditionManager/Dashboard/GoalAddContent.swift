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
// GUI시작 turns THIS page into an inline session view (no navigation): the composer
// panel hides, chat2 events stream into #gsLive over the goal's SSE channel
// (GET /api/goal/chat2/stream?seq=N), and a Claude-Code-Desktop-style composer fixed to
// the bottom sends follow-up turns (POST /api/goal/chat2/say). Composer images ride the
// first turn via the goal's stored attachments; images pasted into the bottom composer
// ride their own turn (chat2/say images:[…]) — both are embedded as real base64 image
// blocks server-side so the model actually sees them (chat2RunTurn).
//
// Queue surface (2026-07-19 simple/detail 큐 병합 — 별도 표면·헤더 세그 없음): the
// composer page IS the queue. Everything dumped stays visible in the 큐 list
// (cm.gaTallyHist, last 100; unresolved AI-queue rows resume polling after re-entry),
// and an unresolved row expands IN PLACE (▸) into the full review card
// (QueuePanel.swift — 추천 옵션·배치 오버라이드·프롬프트 다듬기) so review/confirm
// happens without leaving the page. Resolved rows fold into the 큐 히스토리 section at
// the bottom (번복 포함) which is COLLAPSED by default. Direct entry: /goal-add?q=detail
// (dashboard 큐 노티·exportLinkmap·old #view=queue redirects) auto-expands unresolved
// rows and opens the history. Non-dedup job results (linkmap 등) render as cards in the
// 작업 결과 section. AI검색(findOnly — 추가 모드의 전용 버튼과 검색 모드의 primary 리라벨
// 둘 다 gaAiSearch 공용)은 추가 모드에선 'AI 검색' 행으로 큐 목록에 담긴다(자동 펼침 →
// 검색 카드 인라인, 닫기 전까지 큐에 남아 재진입에도 복원 — 닫으면 '닫힘'으로 히스토리행).
// 검색 모드(레일 검색 페이지 — 큐 목록 없음)에서만 #gaResults 인라인 카드로 그린다.
//
// The header seg toggles (simple-큐/detail-큐 and CHAT/DETAIL) are gone with the merge.
// The session view's sub-header links to the goal page (구 DETAIL 버튼의 역할). Every
// queue row gets a GUI열기 button: rows that are already goals open the in-page session
// view directly (gsEnterResume), unresolved queue rows are promoted (resolve add, AI
// placement accepted) and the session starts immediately with the row text as the first
// turn (gsEnter). GUI시작/GUI열기 also stamp POST /api/goal/viewing so the goal appears
// in the LEFT RAIL's session list (보는 중) right away — no /goal navigation needed.
// The legacy CLI terminal view remains reachable only via ?ui=cli (old rail lastTab).
enum GoalAddContent {

    static func html(serverCtx: String = "{}", tallyHist: String = "[]") -> String {
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
          /* 상태 칩: 진행중(분석 중·펄스) → 완료(분석 끝·큐 탭 확정 대기) → 추가됨 #NN(확정, 링크) */
          .tally .t-st{ flex:0 0 auto; display:inline-flex; align-items:center; gap:4px; font-size:10.5px;
            border-radius:999px; padding:0 7px; white-space:nowrap; text-decoration:none }
          .tally .t-st.prog{ color:var(--accent); border:1px solid #33406a }
          .tally .t-st.prog .dot{ width:5px; height:5px; border-radius:50%; background:var(--accent);
            animation:tpulse 1.2s ease-in-out infinite }
          @keyframes tpulse{ 0%,100%{opacity:.25} 50%{opacity:1} }
          .tally .t-st.done{ color:var(--green); border:1px solid #2a5a3c }
          .tally .t-st.skip{ color:var(--mut); border:1px solid var(--line) }
          /* 인라인 수정: 행에 호버하면 ✎ — 입력창 + 저장/취소 (Enter 저장 · Esc 취소) */
          .tally .t-edit{ flex:0 0 auto; background:transparent; border:none; color:var(--mut);
            cursor:pointer; font-size:12px; padding:0 2px; opacity:0; transition:opacity .12s }
          .tally .t-row:hover .t-edit{ opacity:.85 }
          .tally .t-edit:hover{ color:var(--fg) }
          .tally .t-in{ flex:1; min-width:0; background:var(--bg); border:1px solid var(--accent);
            border-radius:8px; color:var(--fg); font:inherit; font-size:12.5px; padding:2px 8px; outline:none }
          .tally .t-act{ flex:0 0 auto; background:transparent; border:1px solid var(--line); border-radius:8px;
            color:var(--fg); cursor:pointer; font-size:11px; padding:1px 8px }
          .tally .t-act:hover{ background:#1d2230 }
          .tally .t-head{ display:flex; align-items:baseline; gap:8px }
          .tally .t-when{ flex:0 0 auto; font-size:10px; color:var(--mut) }
          .t-clear{ flex:0 0 auto; margin-left:auto; background:transparent; border:none;
            color:var(--mut); font-size:11px; cursor:pointer; padding:0 }
          .t-clear:hover{ color:var(--fg) }
          /* 행 펼침 토글(▸/▾): 미확정 AI 큐 행에서 검토 카드를 그 자리에 연다. sp=자리맞춤 */
          .tally .t-exp{ flex:0 0 auto; width:16px; background:transparent; border:none; color:var(--mut);
            cursor:pointer; font-size:11px; padding:0; text-align:center }
          .tally .t-exp:hover{ color:var(--fg) }
          .tally .t-exp.sp{ cursor:default }
          /* 펼쳐진 검토 카드 컨테이너 — QueuePanel 카드(qrow/qopt…)가 이 안에 그려진다 */
          .tally .t-det{ margin:4px 0 8px 22px; border:1px solid var(--line); border-radius:10px;
            padding:8px 10px; background:rgba(91,140,255,.05) }
          .tally .t-gui{ color:var(--accent); border-color:#33406a }
          .tally .t-gui:hover{ background:rgba(91,140,255,.12) }
          /* 큐 히스토리 (맨 하단, 기본 닫힘): 확정된 담김 기록 + 번복 */
          .qhist{ border:1px solid var(--line); border-radius:12px; padding:10px 14px; margin-top:12px;
            font-size:12.5px }
          .qhist .qh-head{ display:flex; align-items:baseline; gap:8px; cursor:pointer; user-select:none }
          .qhist .qh-head:hover #gaHistArrow{ color:var(--fg) }
          .qhist #gaHistArrow{ color:var(--mut); font-size:11px }

          /* ── 세션 뷰: GUI시작 후 이 화면이 그대로 세션이 된다 — 출력은 플레인 텍스트,
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

          /* ── CLI 세션 뷰(레거시, ?ui=cli 진입 전용): 페이지 안 임베디드 터미널 ──
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
        \#(QueuePanel.css())
        </style></head>
        <body>
          <script>window.CM_PAGE='goal-add';
          // 서버 영속 컴포저 컨텍스트(작업 폴더·브랜치·작업량·모드·최근 폴더). 렌더 시 인라인 주입 —
          // dynamic 포트로 origin 이 바뀌어도 재시작 후 고른 폴더가 유지된다(localStorage 대체 소스).
          try{ window._gaServerCtx=\#(serverCtx); }catch(e){ window._gaServerCtx={}; }
          // 담김 히스토리 서버 주입 — localStorage 는 dynamic 포트(새 origin)마다 리셋되므로
          // 서버 영속본이 진실이다 (localStorage 는 같은 실행 안 새로고침용 캐시로만 남는다).
          try{ window._gaTallyHist=\#(tallyHist); }catch(e){ window._gaTallyHist=[]; }</script>
          \#(SessionRail.html())
          <header>
            <div><h1><span id="gaEditIcon" style="display:none" title="작성 중이던 초안을 이어서 편집 중">✎ </span><span id="gaTitle">목표 추가</span> <span class="muted" id="gaWhere" style="font-size:13px;font-weight:400"></span></h1>
              <div class="sub" id="gaSub">깨끗한 화면에서 목표만 담습니다 — 담고 나면 대시보드로 돌아가세요</div></div>
            <!-- 헤더 세그 토글(simple-큐/detail-큐 · CHAT/DETAIL)은 2026-07-19 큐 병합으로 제거 —
                 검토·확정은 큐 행 펼침(▸)으로, 목표 페이지(구 DETAIL)는 세션 뷰 부제목 링크로. -->
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
              <button class="btn" id="gaAiSearchBtn" onclick="gaAiSearch()" title="표현이 달라도 의미가 비슷한 목표를 AI가 찾습니다 — 목표를 만들지 않고, 결과 카드가 아래에 표시됩니다">AI검색</button>
              <button class="btn start ga-execonly" id="gaStartGui" onclick="gaStart()" title="목표를 바로 추가하고 이 화면의 메신저형 세션 뷰에서 AI 세션을 시작합니다 — 하단 입력창으로 이어서 지시할 수 있습니다">GUI시작</button>
            </div>
            <div class="muted" id="gaHint" style="font-size:12px"><b>Enter</b>를 누르면 <b>AI추가</b>로 담깁니다 — 비슷한 목표가 있는지 먼저 확인하며, 페이지는 열린 채 계속 추가할 수 있습니다. 바로 추가하려면 <b>추가</b>. 찾기만 하려면 <b>검색</b>(번호·제목 즉시 조회) 또는 <b>AI검색</b>(표현이 달라도 의미로 찾기 — 목표를 만들지 않고 결과 카드만). <b>GUI시작</b>은 목표를 바로 추가하고 AI 세션까지 시작합니다 — 페이지 이동 없이 이 화면에서 AI 출력이 흐르고, 하단 입력창으로 이어서 지시할 수 있습니다.</div>
            <div id="gaResults" style="margin-top:2px"></div>
          </div>
          <!-- 큐 (simple/detail 병합): 담긴 항목이 여기 쌓이고, 미확정 AI 큐 행은 ▸ 로 펼쳐
               그 자리에서 검토·확정한다. 확정된 기록은 아래 큐 히스토리(기본 닫힘)로 접힌다. -->
          <div class="tally" id="gaTally"><div class="t-head"><b style="font-size:12px">큐 <span id="gaTallyN">0</span>건</b> <span class="muted" style="font-size:11px">— 행을 펼치면(▸) AI 분석 결과를 검토·확정할 수 있습니다 · <b>GUI열기</b>는 바로 세션까지</span></div><div id="gaTallyList" style="margin-top:6px"></div></div>
          <!-- 작업 결과 (linkmap/report 등 비-dedup 잡): 있을 때만 보인다 -->
          <div class="tally" id="gaJobs"><div class="t-head"><b style="font-size:12px">작업 결과</b></div><div id="gaJobsList" style="margin-top:6px"></div></div>
          <!-- 큐 히스토리: 확정된 담김 기록(+번복). 기본 닫힘 — 헤더를 누르면 펼쳐진다 -->
          <div class="tally qhist" id="gaHist"><div class="qh-head" onclick="gaHistToggle()" title="담고 확정한 기록 — 클릭해 펼치기/접기"><span id="gaHistArrow">▸</span> <b style="font-size:12px">큐 히스토리 <span id="gaHistN">0</span>건</b> <span class="muted" style="font-size:11px">— 확정된 담김 기록 · 번복 가능</span><button class="t-clear" onclick="event.stopPropagation();gaTallyClear()" title="큐 히스토리 표시를 비웁니다 — 미확정 큐 항목은 남습니다">비우기</button></div><div id="gaHistBody" style="display:none;margin-top:6px"></div></div>
          <!-- 세션 뷰: GUI시작이 페이지 이동 없이 여기서 진행된다 (body.sess 에서만 보임) -->
          <div id="gaSess">
            <div id="gsLive"></div>
            <div class="gs-stat" id="gsStat"><span class="gstar">✳</span><span id="gsStxt">대기 중</span></div>
          </div>
          <!-- CLI 세션 뷰(레거시, ?ui=cli 진입 전용): 페이지 안 임베디드 터미널 (body.cli 에서만 보임) -->
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

        // ── 헤더 세그 토글 없음 (2026-07-19 simple/detail 큐 + CHAT/DETAIL 병합): 검토는 큐 행
        //    펼침(▸)이, 목표 페이지 이동(구 DETAIL)은 세션 뷰 부제목 링크가 담당한다. 세션은
        //    항상 GUI(메신저형 세션 뷰)로 시작·재개하고, CLI 터미널 뷰(gaCliEnter)는 레거시
        //    진입(?ui=cli — 옛 레일 lastTab)용으로만 남는다. ──
        let _gaSessSeq=0;   // 이 화면에서 세션 뷰가 열린 목표 seq — 0 이면 세션 없음
        let _gaGoalSeq=0;   // 이 화면에서 만들어진/열린 마지막 목표 seq (기록용)
        function gaGoalBorn(seq){ if(seq>0) _gaGoalSeq=seq; }

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

        // ── 큐 목록 (simple/detail 병합): 페이지는 열린 채 계속 추가하므로, 담은 것들이 아래에
        //    쌓인다. 각 행은 그 자리에서 수정(✎)·펼침(▸ — QueuePanel 검토 카드)·GUI열기(세션
        //    시작)까지 된다. AI 큐 행 상태 칩: 진행중(pending/analyzing) → 완료(ready=분석 끝·
        //    펼쳐서 확정 대기) → 추가됨 #NN(확정). 완료된 항목을 수정하면 서버가 분석을 다시
        //    돌리므로 칩이 진행중으로 돌아갔다가 다시 완료가 된다. 목록은 localStorage
        //    (cm.gaTallyHist, 최근 100건) + 서버(settings.json)에 영속 — 재진입·새로고침에도
        //    남고, 미확정 AI 큐 행은 복원 후 폴링으로 상태가 이어진다. 확정/직접추가 행은
        //    '이번 방문(fresh)' 동안만 상단 큐 목록에 남고, 다음 방문부턴 큐 히스토리(하단,
        //    기본 닫힘)로 접힌다. ──
        let _gaTally=[];
        let _gaHistOpen=false;   // 큐 히스토리 섹션 — 기본 닫힘
        // 큐 파이프라인을 타는 행: AI 큐(dedup 검토) + AI 검색(findOnly — 결과 카드가 행 펼침으로
        // 열리고, 닫기 전까지 큐에 남는다). 상태 폴링·펼침·영속 로직이 이 둘을 같이 다룬다.
        function gaIsQ(x){ return x.kind==='AI 큐'||x.kind==='AI 검색'; }
        function gaTallyAdd(kind,text){
          const e={kind:kind,text:text,id:'',st:'',seq:0,resolved:'',editing:false,ts:Date.now(),
                   open:false,fresh:true};
          _gaTally.push(e); gaTallyRender(); return e; }
        function gaTallyStrip(){ return _gaTally.slice(-100).map(x=>(
          {kind:x.kind,text:x.text,id:x.id||'',st:x.st||'',seq:x.seq||0,resolved:x.resolved||'',ts:x.ts||0})); }
        // 영속 이중화: 진실은 서버(/api/goal/tally → settings.json — dynamic 포트 리셋을 견딘다),
        // localStorage 는 같은 실행 안 새로고침용 캐시. 서버 쓰기는 500ms 디바운스(폴링 갱신 묶음)
        // + 내용이 안 변했으면 보내지 않는다(병합 후 렌더 빈도가 늘어 무의미한 쓰기 방지).
        let _gaTallySaveT=null,_gaTallyLastSaved='';
        function gaTallyPersist(){ if(_gaSearchMode) return;
          const j=JSON.stringify(gaTallyStrip());
          try{ localStorage.setItem('cm.gaTallyHist',j); }catch(e){}
          if(j===_gaTallyLastSaved) return;
          clearTimeout(_gaTallySaveT);
          _gaTallySaveT=setTimeout(()=>{ _gaTallyLastSaved=JSON.stringify(gaTallyStrip());
            post('/api/goal/tally',{list:gaTallyStrip()}); },500); }
        function gaTallyClear(){
          // 히스토리 표시만 비운다 — 미확정 큐 행(검토 대상)은 남기고, 확정된 기록만 지운다.
          _gaTally=_gaTally.filter(x=>gaIsQ(x)&&x.id&&!x.resolved);
          clearTimeout(_gaTallySaveT); _gaTallySaveT=null;
          const j=JSON.stringify(gaTallyStrip());
          try{ localStorage.setItem('cm.gaTallyHist',j); }catch(e){}
          _gaTallyLastSaved=j;
          post('/api/goal/tally',{list:gaTallyStrip()});   // 서버 영속본도 즉시 반영 (디바운스 재기록 방지)
          gaTallyRender(); vtev('tallyClear 큐 히스토리 비우기'); }
        // 이전 날짜에 담긴 행엔 날짜 칩 (오늘 것엔 없음) — 표시 타임존 준수: CMTimeFilter.parts.
        function gaTallyWhen(ts){ if(!ts||!window.CMTimeFilter) return '';
          const a=CMTimeFilter.parts(ts), b=CMTimeFilter.parts(Date.now());
          if(a.y===b.y&&a.mo===b.mo&&a.d===b.d) return '';
          return '<span class="t-when">'+a.mo+'/'+a.d+'</span>'; }
        function gaTallyChip(x){
          if(!gaIsQ(x))
            return (x.seq>0)?('<a class="t-st done" href="/goal?n='+x.seq+'" title="목표 페이지 열기">#'+x.seq+'</a>'):'';
          if(x.resolved==='add'||x.resolved==='task')
            return '<a class="t-st done" href="/goal?n='+x.seq+'" title="목표 페이지 열기">추가됨 #'+x.seq+'</a>';
          // AI 검색 행의 닫기(skip)/큐 이탈은 결정이 아니라 결과 카드를 닫은 것 — '닫힘'으로 표기.
          if(x.kind==='AI 검색'&&x.resolved) return '<span class="t-st skip">닫힘</span>';
          if(x.resolved==='skip') return '<span class="t-st skip">스킵됨</span>';
          if(x.resolved) return '<span class="t-st skip">처리됨</span>';
          if(x.st==='ready')
            return (x.kind==='AI 검색')
              ? '<span class="t-st done" title="AI 검색 완료 — 행을 펼쳐(▸) 결과를 확인하세요">완료</span>'
              : '<span class="t-st done" title="AI 분석 완료 — 행을 펼쳐(▸) 검토·확정하세요">완료</span>';
          return '<span class="t-st prog" title="AI가 비슷한 목표를 분석 중입니다"><span class="dot"></span>진행중</span>';
        }
        // 상단 '큐' 목록에 남는 행: 미확정 AI 큐(검토 대상) 또는 이번 방문에서 담긴/확정된 행
        // (fresh — 결과 피드백이 바로 보이도록). 나머지는 하단 큐 히스토리로 접힌다.
        function gaTallyActiveRow(x){ return !!x.fresh || (gaIsQ(x)&&x.id&&!x.resolved); }
        // 이 행에 대응하는 처리 히스토리 항목 (번복 버튼·실패 사유용) — QueuePanel 의 _qHist.
        function gaTallyHistInfo(x){
          if(!(gaIsQ(x)&&x.id)) return null;
          const qh=(typeof _qHist!=='undefined'?_qHist:[])||[];
          return qh.find(y=>y&&y.qid===x.id&&y.action!=='edit')||null; }
        // 행 하나의 HTML (원본 인덱스 i 유지 — 핸들러가 _gaTally[i] 를 본다). inHist=히스토리 섹션.
        function gaTallyRowHTML(x,i,inHist){
          const kind='<span class="t-kind'+(x.kind==='직접 추가'?' direct':'')+'">'+x.kind+'</span>';
          if(x.editing) return '<div class="t-row"><span class="t-exp sp"></span>'+kind
            +'<input class="t-in" id="gaTIn'+i+'" onkeydown="gaTallyKey(event,'+i+')">'
            +'<button class="t-act" onclick="gaTallySave('+i+')">저장</button>'
            +'<button class="t-act" onclick="gaTallyCancel('+i+')" style="color:var(--mut)">취소</button></div>';
          // 펼침: 미확정 AI 큐/AI 검색 행 — 검토·검색 카드(QueuePanel)가 행 아래에 인라인으로 열린다.
          const expandable=(gaIsQ(x)&&x.id&&!x.resolved);
          const exp=expandable
            ?('<button class="t-exp" onclick="gaTallyToggle('+i+')" title="'+(x.open?'접기':'펼쳐서 검토·확정')+'">'+(x.open?'▾':'▸')+'</button>')
            :'<span class="t-exp sp"></span>';
          // 수정 가능: AI 큐(큐에 있는 동안 → 텍스트 재분석) 또는 목표가 이미 생긴 행(제목 변경).
          const editable=expandable||x.seq>0;
          // GUI열기: 이미 목표면 세션 뷰를 바로, 미확정 큐 행이면 승격+세션 시작까지 한 번에.
          // AI 검색 행은 목표를 만들지 않는(findOnly) 항목이라 승격 경로를 걸지 않는다
          // (task 추가로 seq가 생기면 그때부터 세션 열기 버튼이 살아난다).
          const gui=(x.seq>0||(expandable&&x.kind!=='AI 검색'))
            ?('<button class="t-act t-gui" onclick="gaTallyGui('+i+')"'+(x.busy?' disabled':'')
              +' title="'+(x.seq>0?'이 화면의 세션 뷰에서 goal-'+pad2(x.seq)+' 세션을 엽니다'
                                  :'AI 제안대로 바로 추가하고 이 화면에서 세션을 시작합니다')+'">GUI열기</button>')
            :'';
          // 히스토리 섹션: 번복 버튼(+실패 사유) — 처리 히스토리(_qHist)와 id 로 잇는다.
          let undo='',umsg='';
          if(inHist){ const h=gaTallyHistInfo(x);
            if(h&&!h.undone&&(h.action==='add'||h.action==='task'||h.action==='skip')&&typeof queueUndo==='function')
              undo='<button class="t-act" onclick="queueUndo(\''+h.id+'\')" title="이 결정을 되돌리고 항목을 큐로 복원">번복</button>';
            if(h&&typeof _qHistMsg!=='undefined'&&_qHistMsg[h.id])
              umsg='<div class="qhint" style="color:#e0a458;margin-left:22px">'+esc(_qHistMsg[h.id])+'</div>'; }
          let h='<div class="t-row">'+exp+kind+'<span class="t-txt">'+esc(x.text)+'</span>'+gaTallyWhen(x.ts)+gaTallyChip(x)
            +(editable?'<button class="t-edit" onclick="gaTallyEdit('+i+')" title="수정">✎</button>':'')
            +gui+undo+'</div>'+umsg;
          if(x.fb) h+='<div class="qhint" style="color:#e0a458;margin-left:22px">상위 목표 아래 넣을 수 없어 최상위로 추가됨</div>';
          if(expandable&&x.open) h+='<div class="t-det">'+gaTallyDetHTML(x)+'</div>';
          return h;
        }
        // 펼쳐진 검토 카드: 최신 aiQueue 스냅샷(_lastAiQueue — QueuePanel)에서 이 행의 항목을
        // 찾아 카드를 그린다. 아직 스냅샷이 없으면 로딩 문구 (gaTallyToggle 이 qdReload 를 돈다).
        function gaTallyDetHTML(x){
          const q=(typeof _lastAiQueue!=='undefined'?_lastAiQueue:[])||[];
          const it=q.find(y=>y&&y.id===x.id);
          if(it&&typeof qItemCardHTML==='function') return qItemCardHTML(it);
          return '<div class="muted" style="font-size:12px;padding:4px 2px">분석 데이터를 불러오는 중…</div>';
        }
        function gaTallyToggle(i){ const x=_gaTally[i]; if(!x) return;
          x.open=!x.open; gaTallyRender();
          if(x.open){ vtev('qExpand 큐 행 펼침');
            const q=(typeof _lastAiQueue!=='undefined'?_lastAiQueue:[])||[];
            if(!q.some(y=>y&&y.id===x.id)&&typeof qdReload==='function') qdReload(); } }
        function gaHistToggle(force){
          _gaHistOpen=(force!==undefined)?!!force:!_gaHistOpen;
          gaTallyRender();
          if(_gaHistOpen){ vtev('qHist 큐 히스토리 열림'); if(typeof qdReload==='function') qdReload(); } }
        // GUI열기: 이미 목표(seq>0)면 이 화면의 세션 뷰로 이어가기, 미확정 큐 행이면 AI 제안대로
        // 승격(resolve add)한 뒤 곧바로 세션 뷰에서 첫 턴(행 텍스트)을 시작한다.
        function gaTallyGui(i){ const x=_gaTally[i]; if(!x||x.busy) return;
          if(x.seq>0){ vtev('guiOpen goal-'+pad2(x.seq)); gsEnterResume(x.seq); return; }
          if(!(x.kind==='AI 큐'&&x.id&&!x.resolved)) return;
          x.busy=true; gaTallyRender();
          post('/api/goal/queue/resolve',{id:x.id,action:'add'}).then(r=>r.json()).then(d=>{
            x.busy=false;
            if(d&&d.ok&&d.seq>0){ x.resolved='add'; x.seq=d.seq; x.open=false; x.fresh=true;
              gaTallyRender(); vtev('guiOpen 승격 goal-'+pad2(d.seq)); gsEnter(d.seq,x.text); }
            else gaTallyRender();
          }).catch(()=>{ x.busy=false; gaTallyRender(); }); }
        // 작업 결과 (linkmap/report 등 비-dedup 잡): 있을 때만 섹션을 보인다 — QueuePanel 카드.
        function gaJobsRender(){
          const box=$('gaJobs'), l=$('gaJobsList'); if(!box||!l) return;
          const q=(typeof _lastAiQueue!=='undefined'?_lastAiQueue:[])||[];
          const jobs=q.filter(it=>it&&(it.jobKind||'dedup')!=='dedup');
          const on=jobs.length>0&&typeof queueJobCardHTML==='function';
          box.classList.toggle('on',on);
          if(on) l.innerHTML=jobs.map(queueJobCardHTML).join('');
        }
        function gaTallyRender(){
          gaTallyPersist();
          // 재렌더 전에 포커스·캐럿 보존 — 펼쳐진 카드의 기타/프롬프트 입력, 행 인라인 수정(t-in)이
          // 5초 폴 재렌더에 끊기지 않게 한다 (QueuePanel renderAiQueue 의 보존과 같은 취지).
          const af=document.activeElement;
          const foc=(af&&af.id&&((af.classList&&(af.classList.contains('qother-input')||af.classList.contains('qfind-input')||af.classList.contains('t-in')))||/^qp_/.test(af.id)))
            ?{id:af.id,pos:af.selectionStart}:null;
          // 최신이 위로 — 목록이 길어져도 방금 담은 것이 항상 눈앞에 온다 (핸들러의 원본 인덱스 유지).
          const act=[], hist=[];
          _gaTally.forEach((x,i)=>{ (gaTallyActiveRow(x)?act:hist).push({x:x,i:i}); });
          const box=$('gaTally'); if(box) box.classList.toggle('on',act.length>0);
          const n=$('gaTallyN'); if(n) n.textContent=String(act.length);
          const l=$('gaTallyList');
          if(l) l.innerHTML=act.slice().reverse().map(p=>gaTallyRowHTML(p.x,p.i,false)).join('');
          // 큐 히스토리 (하단, 기본 닫힘): 확정된 담김 기록 + 담김에 없는 처리 히스토리(orphan).
          const qh=(typeof _qHist!=='undefined'?_qHist:[])||[];
          const orphans=qh.filter(h=>h&&!_gaTally.some(x=>x.id&&x.id===h.qid));
          const hbox=$('gaHist'); if(hbox) hbox.classList.toggle('on',(hist.length+orphans.length)>0);
          const hn=$('gaHistN'); if(hn) hn.textContent=String(hist.length+orphans.length);
          const ar=$('gaHistArrow'); if(ar) ar.textContent=_gaHistOpen?'▾':'▸';
          const hb=$('gaHistBody');
          if(hb){ hb.style.display=_gaHistOpen?'':'none';
            if(_gaHistOpen) hb.innerHTML=hist.slice().reverse().map(p=>gaTallyRowHTML(p.x,p.i,true)).join('')
              +((orphans.length&&typeof queueHistRowHTML==='function')
                ?('<div class="muted" style="font-size:11px;margin:8px 0 2px">그 외 처리 기록 — 다른 진입점에서 담긴 항목</div>'
                  +orphans.map(queueHistRowHTML).join('')):''); }
          gaJobsRender();
          // 편집 입력값은 프로퍼티로 넣는다 — esc()가 따옴표를 안 다루므로 value 속성 주입은 안전하지 않다.
          _gaTally.forEach((x,i)=>{ if(x.editing){ const el=$('gaTIn'+i); if(el&&!el.value) el.value=x.text; } });
          if(foc){ const t=$(foc.id); if(t){ t.focus();
            try{ const p=(foc.pos==null?t.value.length:foc.pos); t.setSelectionRange(p,p); }catch(e){} } }
        }
        // ── QueuePanel 호스트 훅: 카드 액션·리로드가 이 페이지의 렌더러로 되돌아온다. ──
        // renderAiQueue(스냅샷 갱신) 후 호출 — 펼쳐진 카드·잡 결과·히스토리를 다시 그린다.
        window.gaQueueRender=function(){ gaFindRender(); if(!_gaSearchMode) gaTallyRender(); };
        // 확정(추가/task/스킵) 직후 — 해당 담김 행을 즉시 결과 상태로 바꾼다 (5초 폴 대기 없음).
        // AI검색(findOnly) 카드의 확정/닫기는 카드만 걷어낸다 (담김 행이 아니므로).
        window.gaQueueResolved=function(id,info){ info=info||{};
          if(_gaFindIds.indexOf(id)>=0){ _gaFindIds=_gaFindIds.filter(x=>x!==id); gaFindRender(); return; }
          if(_gaSearchMode) return;
          const x=_gaTally.find(y=>y.id===id); if(!x) return;
          x.resolved=info.action||'add';
          if(info.seq>0){ x.seq=info.seq; gaGoalBorn(info.seq); }
          x.fb=!!info.fallback; x.open=false; x.fresh=true;
          gaTallyRender(); };
        // 번복 성공 — 항목이 큐로 복원됐으니 행을 미확정으로 되돌리고 폴링을 재개한다.
        window.gaQueueUndone=function(qid){
          const x=_gaTally.find(y=>y.id===qid); if(!x) return;
          x.resolved=''; x.seq=0; x.st='pending'; x.fb=false; x.fresh=true;
          gaTallyRender(); gaTallyWatch(true); };
        function gaTallyEdit(i){ const x=_gaTally[i]; if(!x) return; x.editing=true; gaTallyRender();
          const el=$('gaTIn'+i); if(el){ el.focus(); el.setSelectionRange(el.value.length,el.value.length); } }
        function gaTallyCancel(i){ const x=_gaTally[i]; if(x) x.editing=false; gaTallyRender(); }
        function gaTallyKey(ev,i){ if(ev.key==='Enter'){ ev.preventDefault(); gaTallySave(i); }
          else if(ev.key==='Escape'){ ev.preventDefault(); gaTallyCancel(i); } }
        function gaTallySave(i){ const x=_gaTally[i]; if(!x) return;
          const el=$('gaTIn'+i); const t=String((el&&el.value)||'').trim();
          x.editing=false;
          if(!t||t===x.text){ gaTallyRender(); return; }
          if(gaIsQ(x)&&x.id&&!x.resolved){
            // 큐 후보 수정: 텍스트를 바꾸고 분석을 다시 돌린다 → 칩이 진행중으로 돌아간다.
            // 즉시 폴은 서버가 반영한 뒤(.then)에만 — 반영 전 스냅샷이 낙관적 갱신을 덮지 않게.
            x.text=t; x.st='pending'; x.busy=true; gaTallyRender(); gaTallyWatch(); vtev('tallyEdit 큐 재분석');
            post('/api/goal/queue/edit',{id:x.id,text:t}).then(r=>r.json()).then(d=>{
              x.busy=false;
              if(d&&d.ok){ gaTallyPoll(); return; }
              // 그 사이 큐 탭에서 확정된 뒤였다: 폴링으로 행 상태를 맞추고, 목표가 생겼으면 제목 변경으로 이어간다.
              gaTallyPoll().then(rev=>{ if(x.seq>0){ x.text=t;
                const g=((rev&&rev.goals)||[]).find(g=>(g.seq||0)===x.seq);
                if(g) post('/api/goal/title',{id:g.id,title:t});
                gaTallyRender(); } });
            }).catch(()=>{ x.busy=false; });
            return;
          }
          if(x.seq>0){
            // 이미 목표가 된 행(직접 추가·확정된 AI 큐): 제목만 변경 — goals.json 직접쓰기 금지, 전용 API 사용.
            x.text=t; gaTallyRender(); vtev('tallyEdit 제목 변경 #'+x.seq);
            gsData().then(r=>{ const g=((r&&r.goals)||[]).find(g=>(g.seq||0)===x.seq);
              if(g) post('/api/goal/title',{id:g.id,title:t}); });
            return;
          }
          gaTallyRender();
        }
        // ── 상태 폴링: AI 큐 행이 남아 있는 동안 /data.json 을 주기적으로 읽어 칩을 갱신한다.
        //    (대시보드와 같은 루프백 폴링 — 워커의 pending→analyzing→ready 전이와 큐 탭 확정을 따라간다.) ──
        let _gaTallyTimer=null;
        function gaTallyWatch(now){
          if(!_gaTallyTimer) _gaTallyTimer=setInterval(()=>{ if(!document.hidden) gaTallyPoll(); },5000);
          if(now) gaTallyPoll(); }
        function gaTallyPoll(){
          const watch=_gaTally.filter(x=>gaIsQ(x)&&x.id&&!x.resolved);
          // 비-dedup 잡(linkmap 등)이 도는 동안에도 계속 폴링해 작업 결과 카드를 갱신한다.
          const q0=(typeof _lastAiQueue!=='undefined'?_lastAiQueue:[])||[];
          const jobsBusy=q0.some(it=>it&&(it.jobKind||'dedup')!=='dedup'&&(it.status==='pending'||it.status==='analyzing'));
          if(!watch.length&&!jobsBusy){ if(_gaTallyTimer){ clearInterval(_gaTallyTimer); _gaTallyTimer=null; } return Promise.resolve(null); }
          return fetch('/data.json',{cache:'no-store'}).then(r=>r.json()).then(d=>{
            const rev=(d&&d.review)||{}; const q=rev.aiQueue||[], h=rev.queueHistory||[];
            let changed=false;
            // 스냅샷 변화(항목 상태·매치 도착·잡 진행)도 렌더 사유 — 펼쳐진 카드가 따라간다.
            const snapKey=a=>JSON.stringify((a||[]).map(it=>it&&[it.id,it.status,it.error||'',(it.matches||[]).length]));
            if(snapKey(q0)!==snapKey(q)) changed=true;
            for(const x of watch){
              if(x.editing||x.busy) continue;            // 편집 중/수정 요청 중인 행은 건드리지 않는다
              const it=q.find(y=>y.id===x.id);
              if(it){ x.miss=0;
                const st=(!it.status||it.status==='ready')?'ready':it.status;
                if(st!==x.st){ x.st=st; changed=true; }
                if(it.text&&it.text!==x.text){ x.text=it.text; changed=true; }   // 큐 탭에서 수정된 경우
              } else {
                // 큐를 떠났다: 히스토리(qid)로 결말을 찾는다 — add/task=확정(#seq 링크), skip=스킵.
                const he=h.find(y=>y.qid===x.id&&!y.undone&&y.action!=='edit');
                if(he){ x.miss=0; x.resolved=he.action; x.seq=he.seq||0; if(he.text) x.text=he.text; changed=true;
                  if(he.action==='add'&&he.seq>0) gaGoalBorn(he.seq); }
                // 어디에도 없음(큐 탭에서 닫힘/삭제, 혹은 일시적 글리치): 한 번에 단정하지 않고
                // 2회 연속 미스일 때만 확정한다 — 스냅샷 한 장으로 행을 죽이지 않는다.
                else if((x.miss=(x.miss||0)+1)>=2){ x.resolved='removed'; changed=true; }
              }
            }
            // QueuePanel 스냅샷 반입(_review/_goals/_qHist/_lastAiQueue) — 렌더는 아래서 한 번만.
            if(typeof qdSnap==='function') qdSnap(rev);
            if(changed) gaTallyRender();
            return rev;
          }).catch(()=>null);
        }
        document.addEventListener('visibilitychange',()=>{ if(!document.hidden&&_gaTallyTimer) gaTallyPoll(); });
        // ── 큐 목록 복원: chat 재진입·새로고침은 물론 앱 업데이트/재시작 후에도 담았던 기록이
        //    남는다. 서버 주입본(window._gaTallyHist — settings.json 영속)이 진실이고,
        //    비어 있을 때만 localStorage(같은 origin 캐시)로 폴백한다 — dynamic 포트가 origin 을
        //    바꿔 localStorage 를 리셋해도 서버본이 살아 있다. 미확정 AI 큐 행이 있으면 폴링을
        //    재개해 진행중→완료→추가됨을 이어간다. 복원 행은 fresh 가 아니므로 확정분은 하단
        //    큐 히스토리로 접히고, 미확정 행만 상단 큐 목록에 남는다(펼침은 기본 닫힘). ──
        if(!_gaSearchMode){ try{
          let arr=(Array.isArray(window._gaTallyHist)&&window._gaTallyHist.length)?window._gaTallyHist:null;
          if(!arr) arr=JSON.parse(localStorage.getItem('cm.gaTallyHist')||'[]');
          if(Array.isArray(arr)&&arr.length){
            _gaTally=arr.filter(x=>x&&x.text).map(x=>({kind:x.kind||'AI 큐',text:String(x.text),
              id:x.id||'',st:x.st||'',seq:x.seq||0,resolved:x.resolved||'',ts:x.ts||0,editing:false,open:false}));
            gaTallyRender();   // render→persist 가 서버·로컬 사본을 즉시 재동기화한다
            if(_gaTally.some(x=>gaIsQ(x)&&x.id&&!x.resolved)) gaTallyWatch(true);
          } }catch(e){} }

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
          const e=gaTallyAdd('직접 추가',t);
          post('/api/goal/add',gaPayload(t)).then(r=>r.json())
            .then(d=>{ if(d&&d.ok){ gaGoalBorn(d.seq); e.seq=d.seq||0; gaTallyRender(); } }).catch(()=>{});
          gaAfterSubmit(); }
        // GUI시작: 목표를 바로 추가하고(seq를 받아) 페이지 이동 없이 이 화면을 메신저형
        // 세션 뷰로 전환한다 (AI 출력 스트리밍 + 하단 컴포저). CLI 시작 경로는 제거됨
        // (2026-07-19, CLI 미사용). 첨부 이미지는 /api/goal/add 로 이미 목표에 실렸으므로
        // 첫 턴에 서버가 동봉한다. 실패 시 배너 없이 버튼만 되살린다 (no-user-facing-failure).
        function gaStart(){ const inp=$('gaText'); const t=String(inp.value||'').trim(); if(!t) return;
          const btn=$('gaStartGui'); if(btn&&btn.disabled) return; if(btn) btn.disabled=true;
          post('/api/goal/add',gaPayload(t)).then(r=>r.json()).then(d=>{
            if(!(d&&d.ok&&d.seq>0)){ if(btn) btn.disabled=false; return; }
            gaClearDraft();
            gsEnter(d.seq,t);
          }).catch(()=>{ if(btn) btn.disabled=false; }); }
        function gaAi(){ const inp=$('gaText'); const t=String(inp.value||'').trim(); if(!t) return;
          // 검색 모드의 primary 버튼은 AI검색으로 리라벨된다 — 같은 findOnly 경로로 보낸다.
          if(_gaSearchMode){ gaAiSearch(); return; }
          const e=gaTallyAdd('AI 큐',t);
          // 서버가 큐 후보 id를 돌려준다 — 행의 상태 칩(진행중→완료)과 인라인 수정이 이 id 로 이어진다.
          post('/api/goal/queue/enqueue',gaPayload(t)).then(r=>r.json())
            .then(d=>{ if(d&&d.ok&&d.id){ e.id=d.id; e.st='pending'; gaTallyRender(); gaTallyWatch(true); } })
            .catch(()=>{});
          gaAfterSubmit(); }

        // ── AI검색(findOnly): 목표를 만들지 않고 의미가 비슷한 기존 목표만 AI가 찾는다
        //    (search:true 큐 파이프라인). 추가 모드(전용 AI검색 버튼)에선 'AI 검색' 행으로
        //    큐 목록에 담는다 — 자동 펼침으로 분석 중 → 매치 목록 → 다음 액션(끝내기·task
        //    추가·그만두기)이 행 아래 인라인 카드(QueuePanel 검색 카드)로 흐르고, 닫기 전까지
        //    큐에 남아 재진입·새로고침에도 복원된다. 검색 모드(primary AI검색 리라벨 —
        //    큐 목록이 없는 레일 검색 페이지)에서만 #gaResults 카드로 그린다. 로컬 검색
        //    (gsRender)이 결과 영역을 차지한 뒤에는 폴링 재렌더가 그것을 덮지 않는다
        //    (#gaFindCards 마커 확인). ──
        let _gaFindIds=[],_gaFindSeen={},_gaFindTimer=null;
        function gaAiSearch(){ const inp=$('gaText'); const t=String(inp.value||'').trim(); if(!t) return;
          if(!_gaSearchMode){
            // 추가 모드: 큐 목록의 'AI 검색' 행으로 — AI 큐(gaAi)와 같은 담김/폴링 수명주기.
            const e=gaTallyAdd('AI 검색',t); e.open=true;
            post('/api/goal/queue/enqueue',{text:t,search:true}).then(r=>r.json())
              .then(d=>{ if(d&&d.ok&&d.id){ e.id=d.id; e.st='pending'; gaTallyRender(); gaTallyWatch(true); } })
              .catch(()=>{});
            vtev('aiSearch findOnly 담김');
            gaAfterSubmit(); return;
          }
          const res=$('gaResults'); if(res) res.innerHTML='<div id="gaFindCards"><div class="muted" style="font-size:12.5px;border:1px solid var(--line);border-radius:10px;padding:8px 12px;margin-top:6px">큐에 담는 중…</div></div>';
          post('/api/goal/queue/enqueue',{text:t,search:true}).then(r=>r.json()).then(d=>{
            if(d&&d.ok&&d.id){ _gaFindIds.push(d.id); gaFindRender(true); gaFindWatch();
              if(typeof qdReload==='function') qdReload(); } }).catch(()=>{});
          vtev('aiSearch findOnly 담김');
          gaAfterSubmit(); }
        function gaFindWatch(){ if(_gaFindTimer) return;
          _gaFindTimer=setInterval(()=>{ if(document.hidden) return;
            if(!_gaFindIds.length){ clearInterval(_gaFindTimer); _gaFindTimer=null; return; }
            if(typeof qdReload==='function') qdReload(); },5000); }
        function gaFindRender(force){
          const host=$('gaResults'); if(!host) return;
          const q=(typeof _lastAiQueue!=='undefined'?_lastAiQueue:[])||[];
          // 큐에서 사라진 항목(닫힘/확정)은 카드로 한 번 보인 적 있을 때만 목록에서 뺀다.
          _gaFindIds=_gaFindIds.filter(id=>{ const has=q.some(y=>y&&y.id===id);
            if(has) _gaFindSeen[id]=1; return has||!_gaFindSeen[id]; });
          const wrap=document.getElementById('gaFindCards');
          if(!wrap&&!force) return;   // 로컬 검색 결과가 영역을 점유 중 — 덮지 않는다
          if(!_gaFindIds.length){ if(wrap) host.innerHTML=''; return; }
          host.innerHTML='<div id="gaFindCards">'+_gaFindIds.map(id=>{
            const it=q.find(y=>y&&y.id===id);
            if(it&&typeof qItemCardHTML==='function')
              return '<div style="border:1px solid var(--line);border-radius:12px;padding:6px 12px;margin-top:8px">'+qItemCardHTML(it)+'</div>';
            return '<div class="muted" style="font-size:12.5px;border:1px solid var(--line);border-radius:10px;padding:8px 12px;margin-top:6px">🔍 AI가 의미가 비슷한 목표를 분석 중입니다…</div>';
          }).join('')+'</div>';
        }

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

        // ===== 세션 뷰 (GUI시작): 페이지 이동 없이 이 화면에서 chat2 턴을 돌린다. =====
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
        // ── CLI 세션 뷰 (레거시 ?ui=cli 진입 전용): 공용 웹터미널 엔진 CMWebCLI(Sources/WebCLI,
        //    WebCLITerminal.script() 로 이 페이지에 동봉)를 페이지 안 xterm 터미널로 연다.
        //    xterm 버전·IME 인수·폴링은 전부 엔진 소관 — 여기는 얇은 어댑터만: 뷰 전환,
        //    상태 라벨, 그리고 첫 프롬프트(입력한 목표 텍스트)를 실은 cli/start POST.
        //    페이지를 떠나도 PTY는 백그라운드 유지(레일에서 재접속). ──
        let _cliCtl=null;
        function cliState(txt,cls){ const e=$('gaCliState'); if(e){ e.textContent=txt; e.className='st'+(cls?(' '+cls):''); } }
        function gaCliEnter(seq,firstText){
          _gaSessSeq=seq; gaGoalBorn(seq);
          try{ localStorage.setItem('cm.lastTab.'+seq,'cli'); }catch(e){}
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
        // + 브랜치(있을 때만). 즉시 _gaComp 값으로 그리고(GUI시작 경로에선 이게 정답),
        // 목표 페이지 CHAT 재진입처럼 _gaComp 가 그 목표와 다를 수 있는 경우를 위해 goal 레코드로 보정한다.
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
          // 레일 "보는 중" 스탬프: /goal 페이지를 거치지 않고 세션이 열리므로 여기서 직접 찍어
          // 왼쪽 레일 세션 목록에 이 목표가 바로 나타난다.
          post('/api/goal/viewing',{seq:seq});
          try{ localStorage.setItem('cm.lastTab.'+seq,'gui'); }catch(e){}
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
        // 이어가기 진입 (목표 페이지 CHAT·레거시 CLI 뷰 탈출): 첫 턴을 쏘지 않고 세션 뷰만 연다. sess=true 라
        // 전송은 /api/goal/session/say(최신 연결 세션 headless 재개), 수신은 &sess=1 SSE.
        function gsEnterResume(seq){
          _gaSessSeq=seq; gaGoalBorn(seq);
          // 레일 "보는 중" 스탬프 — gsEnter 와 동일 (GUI열기/이어가기도 레일에 바로 뜬다).
          post('/api/goal/viewing',{seq:seq});
          try{ localStorage.setItem('cm.lastTab.'+seq,'gui'); }catch(e){}
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
        // 있는지 / 직전 턴이 어떻게 끝났는지"를 복원한다. 채널은 둘 다 본다 — GUI시작
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
                  if(d&&d.error==='no-session'){
                    // 이어갈 연결 세션이 없다(예: GUI열기로 연 아직 세션 없는 목표) — 메신저
                    // 채널(chat2)로 조용히 전환해 같은 턴을 다시 보낸다 (배너 없음).
                    _gs.sess=false;
                    if(_gs.es){ _gs.es.close(); _gs.es=null; }
                    gsOpenStream();
                    gsPost(text,images,override);
                    return;
                  }
                  gsNote('⚠️ 전송 실패 — 잠시 후 다시 시도하세요');
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
            // 전용 AI검색 버튼은 추가 모드용 — 검색 모드에선 primary(AI검색 리라벨)와 중복이라 숨긴다.
            const asB=$('gaAiSearchBtn'); if(asB) asB.style.display='none';
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
          // 초기 큐 데이터 반입(펼침 카드·작업 결과·큐 히스토리 카운트) + ?q=detail 직행 진입
          // (대시보드 큐 노티·exportLinkmap·옛 #view=queue): 미확정 행을 모두 펼치고 큐 히스토리도
          // 연다. QueuePanel 스크립트가 이 아래에서 로드되므로 파싱이 끝난 뒤(setTimeout 0) 돈다.
          if(!_gaSearchMode) setTimeout(function(){
            if(typeof qdReload==='function') qdReload();
            if(_qs.get('q')==='detail'){
              _gaTally.forEach(x=>{ if(gaIsQ(x)&&x.id&&!x.resolved) x.open=true; });
              _gaHistOpen=true; gaTallyRender(); vtev('qNav 큐 직행(q=detail)');
              const box=$('gaTally'); if(box&&box.classList.contains('on')) box.scrollIntoView({block:'start'});
            }
          },0);
          // 목표 페이지 헤더의 CHAT에서 되돌아오는 진입 (/goal-add?goal=N[&ui=…]):
          // 컴포저를 건너뛰고 그 목표의 GUI 세션 뷰(최신 연결 세션 이어가기)를 바로 연다.
          // ?ui=cli 는 레거시(옛 레일 lastTab)만 — 살아있는 PTY 재접속/--resume 터미널.
          const backSeq=parseInt(_qs.get('goal')||'0',10)||0;
          if(backSeq>0 && !_gaSearchMode){
            if(_qs.get('ui')==='cli') gaCliEnter(backSeq,''); else gsEnterResume(backSeq);
            return;
          }
          setTimeout(()=>{ gt.focus(); const n=gt.value.length; try{ gt.setSelectionRange(n,n); }catch(_){} },50);
        })();
        </script>
        <!-- 큐 검토 카드 + 확정 액션 스크립트 (QueuePanel.swift). 메인 스크립트가 제공하는
             $/esc/post/CMTimeFilter/_review 와 호스트 훅(gaQueueRender/gaQueueResolved/
             gaQueueUndone)을 쓰므로 그 뒤에 로드한다. -->
        <script>
        \#(QueuePanel.script())
        </script>
        </body></html>
        """#
    }
}
