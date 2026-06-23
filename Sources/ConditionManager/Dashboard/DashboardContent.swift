import Foundation

// Self-contained dashboard page (no external CDN — works offline). Polls
// /data.json every 5s and renders:
//   - today's per-minute activity timeline (canvas)
//   - which app was active across the day (colored strip)
//   - per-app active time (bars)
//   - per-app BGM debug table: which strategy/tracks played, flagging tracks
//     whose BPM falls outside the strategy band (i.e. "wrong" BGM)
// Raw Swift string => no interpolation/escaping surprises.
enum DashboardContent {
    static func html() -> String {
        return #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Condition Manager — 활동</title>
<style>
  :root{--bg:#0f1115;--panel:#171a21;--line:#232733;--mut:#8b93a7;--fg:#e7ebf3;--accent:#5b8cff;--green:#36c08a;--red:#e2667d;}
  *{box-sizing:border-box} html,body{margin:0}
  body{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif}
  .wrap{max-width:980px;margin:0 auto;padding:28px 20px}
  h1{font-size:18px;margin:0 0 4px}
  h2{font-size:14px;margin:22px 0 10px;color:var(--fg)}
  .sub{color:var(--mut);font-size:13px;margin-bottom:20px}
  .cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:8px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px;flex:1;min-width:150px}
  .card .k{color:var(--mut);font-size:12px}
  .card .v{font-size:22px;font-weight:700;margin-top:4px}
  .card .cap{color:var(--mut);font-size:11px;margin-top:3px}
  #tiers{width:100%;display:block}
  .nowline{color:var(--mut);font-size:13px;margin:4px 0 18px}
  .nowline b{color:var(--fg);font-weight:600}
  .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;vertical-align:middle}
  .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px}
  canvas{width:100%;display:block}
  #chart{height:260px} #strip{height:34px;margin-top:8px}
  .legend{color:var(--mut);font-size:12px;margin-top:10px;display:flex;gap:18px;flex-wrap:wrap}
  .bars{display:flex;flex-direction:column;gap:8px}
  .bar{display:flex;align-items:center;gap:10px;font-size:13px}
  .bar .name{width:160px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .bar .track{flex:1;height:14px;border-radius:7px;background:#0d1f17;overflow:hidden}
  .bar .fill{height:100%;border-radius:7px}
  .bar .val{width:60px;text-align:right;color:var(--mut)}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
  th{color:var(--mut);font-weight:600;font-size:12px}
  .chip{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;margin:2px 4px 2px 0;background:#1d2230;border:1px solid var(--line)}
  .chip.bad{background:#2a1620;border-color:#5a2738;color:#ff9db0}
  .chip.bad::after{content:" ⚠";}
  .foot{color:var(--mut);font-size:12px;margin-top:18px;text-align:center}
  .empty{color:var(--mut)}
  .btn{background:#1d2230;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:6px 12px;font-size:13px;cursor:pointer}
  .btn:hover{border-color:var(--accent)}
  .btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
  .btn:disabled{opacity:.5;cursor:not-allowed}
  /* View switcher combobox (입력 / 그룹 / 프리뷰) — styled to match .btn. */
  select.btn{appearance:none;-webkit-appearance:none;-moz-appearance:none;padding-right:24px;
    background-image:linear-gradient(45deg,transparent 50%,var(--mut) 50%),linear-gradient(135deg,var(--mut) 50%,transparent 50%);
    background-position:calc(100% - 13px) 55%,calc(100% - 8px) 55%;background-size:5px 5px,5px 5px;background-repeat:no-repeat}
  /* Group-mode input: sticky add bar + collapsible per-parent sections. */
  .gqbar{position:sticky;top:0;z-index:5;background:var(--panel);padding:8px 0;margin:0 0 6px;border-bottom:1px solid var(--line)}
  .gsec{border:1px solid var(--line);border-radius:10px;margin:8px 0;overflow:hidden}
  .gsec-hd{display:flex;align-items:center;gap:8px;padding:8px 10px;background:#1a1e27;cursor:pointer;user-select:none}
  .gsec-hd:hover{background:#1d2230}
  .gsec-hd .tw{color:var(--mut);width:12px;flex:0 0 auto;transition:transform .15s;text-align:center}
  .gsec.collapsed .gsec-hd .tw{transform:rotate(-90deg)}
  .gsec-hd .gtitle{flex:1;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .gsec-hd .prog{color:var(--mut);font-size:12px;font-variant-numeric:tabular-nums;flex:0 0 auto}
  .gsec-body{padding:4px 10px 8px}
  .gsec.collapsed .gsec-body{display:none}
  .gchild{display:flex;align-items:center;gap:8px;padding:4px 0;border-bottom:1px solid var(--line);flex-wrap:wrap}
  .gchild:last-of-type{border-bottom:none}
  .gchild .gt{flex:1;min-width:80px}
  .gsec-add{display:flex;gap:6px;margin-top:6px}
  .hdr{display:flex;align-items:center;justify-content:space-between;gap:12px}
  .overlay{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:flex-start;justify-content:center;padding:40px 16px;overflow:auto;z-index:50}
  .overlay.on{display:flex}
  .modal{background:var(--panel);border:1px solid var(--line);border-radius:14px;max-width:720px;width:100%;padding:24px}
  .modal h2{margin-top:18px} .modal h2:first-child{margin-top:0}
  .modal ul{margin:6px 0;padding-left:18px} .modal li{margin:3px 0}
  .modal .muted{color:var(--mut)}
  .pill{display:inline-block;padding:1px 7px;border-radius:999px;font-size:11px;border:1px solid var(--line);margin-right:4px}
  .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
  input[type=text],input[type=number]{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 9px;font-size:13px}
  input[type=range]{vertical-align:middle}
  .goal{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:5px 0;border-bottom:1px solid var(--line)}
  .goal .g{flex:1;position:relative}
  /* Editable goal title: double-click to rename in place (목록 + 그룹 자식 행). */
  .gt{cursor:text;border-radius:5px;padding:1px 4px;margin:0 -4px}
  .gt:hover{background:rgba(255,255,255,.05)}
  .gt input.gedit{width:100%;box-sizing:border-box;padding:3px 6px;font-size:13px}
  /* Concurrency-gated AI-work row: shown only when 2+ goals run at once (= AI).
     Holds energy allocation, assigned agents, tokens spent, value, and ROI. */
  .aiwork{flex:0 0 100%;display:flex;flex-wrap:wrap;align-items:center;gap:6px 12px;margin:2px 0 4px 26px;
          padding:6px 10px;border-radius:8px;background:rgba(91,140,255,.06);border:1px solid var(--line);font-size:12px}
  .aiwork .lab{color:var(--mut);font-size:11px}
  .aiwork input[type=number]{width:62px;text-align:right;padding:4px 7px;font-size:12px}
  .aiwork input.agents{width:150px;padding:4px 7px;font-size:12px}
  .roi{font-variant-numeric:tabular-nums;border-radius:6px;padding:2px 8px;font-size:11px;border:1px solid var(--line);white-space:nowrap}
  .roi.hi{background:rgba(54,192,138,.16);border-color:var(--green);color:#9be9c9}
  .roi.mid{background:rgba(232,161,58,.14);border-color:#e8a13a;color:#f0c884}
  .roi.lo{background:rgba(255,99,99,.14);border-color:#ff6363;color:#ff9b9b}
  /* Energy gauge banner: sum of in_progress energy vs the 100% cap. */
  .engauge{margin:6px 0 8px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:rgba(91,140,255,.05);font-size:12px}
  .engauge .head{display:flex;justify-content:space-between;align-items:center;margin-bottom:5px}
  .engauge .bar{height:8px;border-radius:999px;background:#1d2230;overflow:hidden}
  .engauge .fill{height:100%;background:linear-gradient(90deg,#36c08a,#5b8cff);transition:width .3s}
  .engauge.over{border-color:#ff6363;background:rgba(255,99,99,.08)}
  .engauge.over .fill{background:linear-gradient(90deg,#e8a13a,#ff6363)}
  .engauge .warn{color:#ff9b9b}
  /* Completion evidence (links + files) attached to a goal. */
  .evbtn{flex:0 0 auto;padding:3px 8px;font-size:12px}
  .evbtn.has{border-color:var(--green);color:#9be9c9}
  .evpanel{flex:0 0 100%;display:none;margin:2px 0 6px 26px;padding:8px 10px;border-radius:8px;background:rgba(54,192,138,.05);border:1px solid var(--line)}
  .evpanel.open{display:block}
  .evlist{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
  .evitem{display:inline-flex;align-items:center;gap:4px;background:#1d2230;border:1px solid var(--line);border-radius:999px;padding:2px 4px 2px 10px;font-size:12px;max-width:340px}
  .evitem a{color:var(--accent);text-decoration:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .evitem a:hover{text-decoration:underline}
  .evx{background:none;border:none;color:var(--mut);cursor:pointer;font-size:12px;line-height:1;padding:0 3px}
  .evx:hover{color:var(--red)}
  .evrep{margin:2px 0 6px;font-size:12px;display:flex;flex-wrap:wrap;gap:10px}
  .evrep a{color:var(--accent);text-decoration:none}
  .evrep a:hover{text-decoration:underline}
  /* Review memo: not important enough for an always-on field, so it collapses to a
     button that opens an inline editor on click (mirrors the evidence panel pattern). */
  .notebtn{flex:0 0 auto;padding:3px 8px;font-size:12px}
  .notebtn.has{border-color:var(--accent);color:#9fc0ff}
  .notepanel{flex:0 0 100%;display:none;margin:2px 0 6px 26px;padding:8px 10px;border-radius:8px;background:rgba(91,140,255,.05);border:1px solid var(--line)}
  .notepanel.open{display:block}
  .notepanel input{width:100%}
  /* 일정관리(schedule) view: urgency-grouped sections + per-goal target/완료 datetime pickers. */
  .schsec{border:1px solid var(--line);border-radius:10px;margin:10px 0;overflow:hidden}
  .schsec-hd{display:flex;align-items:center;gap:8px;padding:8px 12px;font-weight:600;background:#1a1e27}
  .schsec-hd .cnt{color:var(--mut);font-weight:400;font-size:12px}
  .schsec.overdue .schsec-hd{background:rgba(255,99,99,.10);color:#ff9b9b}
  .schsec.today .schsec-hd{background:rgba(232,163,61,.12);color:#f0c884}
  .schsec.done .schsec-hd{background:rgba(54,192,138,.10);color:#9be9c9}
  .schrow{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:6px 12px;border-bottom:1px solid var(--line)}
  .schrow:last-child{border-bottom:none}
  .schrow .st{flex:1;min-width:120px}
  .schrow .dlab{color:var(--mut);font-size:11px}
  .schrow input[type=datetime-local]{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 8px;font-size:12px;color-scheme:dark}
  .dday{font-variant-numeric:tabular-nums;font-size:11px;border-radius:6px;padding:1px 7px;border:1px solid var(--line);color:var(--mut);white-space:nowrap}
  .dday.over{border-color:#ff6363;color:#ff9b9b;background:rgba(255,99,99,.10)}
  .dday.soon{border-color:#e8a33d;color:#f0c884;background:rgba(232,163,61,.10)}
  .dday.done{border-color:var(--green);color:#9be9c9;background:rgba(54,192,138,.10)}
  /* Completion celebration: check sweep (strike + green flash) + floating +Nv value. */
  .goal.celebrate{background:rgba(54,192,138,.14);transition:background .45s}
  .gstrike{position:absolute;left:0;top:55%;height:2px;width:0;background:var(--green);transition:width .45s ease}
  .gstrike.on{width:100%}
  .vfloat{position:fixed;z-index:60;background:rgba(54,192,138,.16);border:1px solid var(--green);color:#9be9c9;border-radius:999px;padding:2px 10px;font-size:12px;font-weight:600;pointer-events:none;opacity:0;transition:transform 1s ease,opacity 1s ease}
  .grip{cursor:grab;color:var(--mut);user-select:none;padding:0 2px;font-size:14px;line-height:1}
  .grip:active{cursor:grabbing}
  /* Session-link toggle: bright chain when a Claude session is attached (opens the
     readable transcript), dim broken chain when not (opens the connect picker). */
  .slink{cursor:pointer;background:none;border:none;padding:2px 4px;border-radius:6px;font-size:13px;line-height:1}
  .slink:hover{background:#1d2230}
  .slink.on{filter:none;opacity:1}
  .slink.off{opacity:.4;filter:grayscale(1)}
  /* DEV dataset badge — shown only when the app runs on a CM_DATA_DIR override
     (e.g. .localdata). Makes "this is not production data" impossible to miss. */
  .devbadge{display:inline-block;vertical-align:middle;margin-left:8px;padding:2px 9px;border-radius:6px;
    font-size:12px;font-weight:700;letter-spacing:.06em;color:#1a1205;background:#f5a623;border:1px solid #ffce7a}
  body.devmode{border-top:3px solid #f5a623}
  .goal.dragging{opacity:.45}
  .goal.dropTarget{border-top:2px solid var(--accent)}
  .stat{display:inline-flex;gap:3px;flex:0 0 auto}
  .sb{background:#1d2230;border:1px solid var(--line);color:var(--mut);border-radius:6px;padding:3px 8px;font-size:12px;cursor:pointer}
  .sb:hover{border-color:var(--accent)}
  .sb.on.backlog{color:var(--fg);border-color:var(--mut)}
  .sb.on.in_progress{background:var(--accent);border-color:var(--accent);color:#fff}
  .sb.on.waiting{background:#e8a33d;border-color:#e8a33d;color:#2a1c06}
  .sb.on.done{background:var(--green);border-color:var(--green);color:#06281c}
  /* Status combobox: six statuses outgrew the inline buttons, so leaf goals pick status
     from a select. Border/text color-code the CURRENT status so the row reads at a glance. */
  .statsel{background:#1d2230;border:1px solid var(--line);color:var(--fg);border-radius:6px;
    padding:3px 8px;font-size:12px;cursor:pointer;flex:0 0 auto}
  .statsel:hover{border-color:var(--accent)}
  .statsel.in_progress{border-color:var(--accent);color:#9fc0ff}
  .statsel.waiting{border-color:#e8a33d;color:#e8a33d}
  .statsel.stopped{border-color:var(--mut);color:var(--mut)}
  .statsel.cancelled{border-color:#7a2233;color:#e07a8c;text-decoration:line-through}
  .statsel.done{border-color:var(--green);color:#36c08a}
  /* Live "응답 대기" badge: a human-attention flag, pulsing amber so it stands out. */
  .wbadge{font-variant-numeric:tabular-nums;font-size:11px;color:#e8a33d;border:1px solid #e8a33d;
    border-radius:6px;padding:1px 6px;margin-left:6px;white-space:nowrap;animation:wpulse 1.6s ease-in-out infinite}
  @keyframes wpulse{0%,100%{opacity:1}50%{opacity:.45}}
  .ttime{font-variant-numeric:tabular-nums;color:var(--mut);font-size:12px;min-width:48px;text-align:right;flex:0 0 auto}
  .ttime.clk{cursor:pointer;color:#9fc0ff}
  .ttime.clk:hover{text-decoration:underline}
  .goal.running{background:rgba(91,140,255,.06)}
  .goal.ontrack{background:rgba(76,201,240,.07)}
  /* Derived rollup status for parent goals (computed from children, not clickable). */
  .ot{display:inline-block;border-radius:6px;padding:3px 9px;font-size:12px;border:1px solid var(--line);color:var(--mut);white-space:nowrap}
  .ot.on_track{background:rgba(76,201,240,.16);border-color:#4cc9f0;color:#9be3fb}
  .ot.done{background:var(--green);border-color:var(--green);color:#06281c}
  .otTag{display:inline-block;border:1px solid #4cc9f0;color:#9be3fb;background:rgba(76,201,240,.12);border-radius:999px;font-size:11px;padding:1px 8px;margin-left:8px;vertical-align:middle}
  .stage{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid var(--line)}
  .stage .n{width:22px;height:22px;border-radius:50%;background:#1d2230;display:flex;align-items:center;justify-content:center;font-size:12px;flex:0 0 auto}
  .stage .s{flex:1} .stage .st{font-size:12px}
  .ok{color:var(--green)} .wait{color:var(--mut)} .bad{color:var(--red)}
  /* Pixel bard standing fully above the goal input, anchored to the right edge. */
  .bardwrap{position:relative;flex:1;display:flex;min-width:140px}
  #bardCanvas{position:absolute;top:-40px;right:14px;width:40px;height:40px;image-rendering:pixelated;pointer-events:none;z-index:3}
</style>
</head>
<body>
<div class="wrap">
  <div class="hdr">
    <div>
      <h1>오늘 활동 · BGM 디버그 <span id="devBadge" class="devbadge" style="display:none"></span></h1>
      <div class="sub" id="date">불러오는 중…</div>
    </div>
    <div style="display:flex;align-items:center;gap:10px">
      <span id="perf" title="이 대시보드 페이지의 자원 사용량 (메모리=JS 힙, CPU=프레임 타이밍 근사치)"
            style="font-size:11px;color:var(--mut);font-variant-numeric:tabular-nums;white-space:nowrap">측정 중…</span>
      <span style="display:inline-flex;gap:4px" title="스포츠=라이브 APM 바운싱 (집중·재미), 타임=토탈 시간 카운트업 (체력 총량). 8시간+엔 타임 자동">
        <button class="btn primary" id="mode_sports" onclick="setGaugeMode('sports',true)">스포츠</button>
        <button class="btn" id="mode_time" onclick="setGaugeMode('time',true)">타임</button>
      </span>
      <button class="btn" onclick="document.getElementById('policy').classList.add('on')">기준 (정책서)</button>
    </div>
  </div>

  <div class="cards">
    <div class="card"><div class="k">토탈 시간</div><div class="v" id="t_total">–</div><div class="cap">업무 스팬 (휴식·미팅 포함)</div></div>
    <div class="card"><div class="k">책상 시간</div><div class="v" id="t_desk">–</div><div class="cap">만들기 시도 (리서치+코딩)</div></div>
    <div class="card"><div class="k">집중 시간</div><div class="v" id="t_focus">–</div><div class="cap">몰입 (에디터)</div></div>
    <div class="card"><div class="k">퇴근</div><div class="v" id="t_off">–</div><div class="cap">6시간+ 공백</div></div>
    <div class="card"><div class="k">오늘 가치 (확정)</div><div class="v" id="value">–</div><div class="cap">승인 전 = 0 (아래 절차)</div></div>
  </div>
  <div class="panel" style="margin:6px 0;padding:12px 16px">
    <canvas id="tiers" style="height:18px"></canvas>
    <div class="legend">
      <span><span class="dot" style="background:#2a2f3a;border:1px solid #444"></span>토탈(회색=휴식·미팅)</span>
      <span><span class="dot" style="background:#e8a13a"></span>책상</span>
      <span><span class="dot" style="background:#36c08a"></span>집중</span>
      <span>· 누적 <b id="total">–</b></span>
      <span>· <span id="status">–</span></span>
    </div>
  </div>
  <div class="nowline" id="now">지금: –</div>

  <div class="hdr"><h2 style="margin:18px 0 10px">오늘 가치 확정 (어뷰징 필터)</h2>
    <select class="btn" id="viewSelect" onchange="setView(this.value)" title="뷰 전환">
      <option value="input">목록</option>
      <option value="group">그룹</option>
      <option value="schedule">일정</option>
      <option value="preview">프리뷰</option>
    </select></div>
  <div class="panel">
    <!-- SHARED STATUS FILTER — one bar drives 목록·그룹·프리뷰 alike -->
    <div class="row" style="margin:0 0 8px;gap:6px">
      <span class="muted" style="font-size:12px">보기</span>
      <button class="btn primary" id="flt_backlog" onclick="toggleStatusFilter('backlog')">대기</button>
      <button class="btn primary" id="flt_inprog" onclick="toggleStatusFilter('in_progress')">진행</button>
      <button class="btn primary" id="flt_done" onclick="toggleStatusFilter('done')">완료</button>
      <button class="btn" id="flt_cancelled" onclick="toggleStatusFilter('cancelled')" title="켜면 취소된 목표도 표시 (기본은 숨김)">취소</button>
      <button class="btn" id="flt_parents" onclick="toggleShowParents()" title="켜면 상위 목표는 필터와 무관하게 항상 표시. 끄면 상위 목표도 롤업 상태로 필터링됩니다.">상위 항상 표시</button>
      <span class="muted" id="flt_summary" style="font-size:12px">— 모두 표시</span>
    </div>
    <!-- INPUT VIEW -->
    <div id="inputView">
      <div class="row">목표 추가:
        <span class="bardwrap">
          <canvas id="bardCanvas" width="48" height="48" aria-hidden="true" title="음유시인이 1분마다 버프를 연주합니다"></canvas>
          <input type="text" id="goalText" placeholder="목표/디테일 입력 후 Enter (계속 추가)" style="width:100%"
                 onkeydown="goalKey(event)">
        </span>
        <button class="btn" onclick="addGoal()">추가</button>
      </div>
      <div class="muted" style="font-size:12px;margin:2px 0 6px">번호를 보고 각 목표의 <b>부모#</b> 칸에 부모 번호를 입력하면 묶입니다 (비우면 최상위). 압축된 결과는 프리뷰에서 확인.</div>
      <div id="goals"></div>

      <div class="stage" style="margin-top:8px">
        <div class="n">1</div>
        <div class="s"><b>셀프 리뷰</b> — 오늘 가치 기여도
          <div class="row">
            <input type="range" id="selfRange" min="0" max="100" value="0"
                   oninput="document.getElementById('selfVal').textContent=this.value">
            <span><b id="selfVal">0</b>%</span>
            <button class="btn primary" onclick="submitSelf()">제출</button>
          </div>
        </div>
        <div class="st" id="st_self">미제출</div>
      </div>

      <div class="stage">
        <div class="n">2</div>
        <div class="s"><b>AI 필터</b> — 입력 패턴 어뷰징 검증
          <div class="row"><button class="btn" onclick="runAI()">AI 필터 실행</button>
            <span id="aiNote" class="muted"></span></div>
        </div>
        <div class="st" id="st_ai">대기</div>
      </div>

      <div class="stage">
        <div class="n">3</div>
        <div class="s"><b>관리자 승인</b> <span class="muted">(준비 중)</span></div>
        <div class="st wait">준비 중</div>
      </div>
    </div>

    <!-- PREVIEW (REPORT) VIEW -->
    <div id="previewView" style="display:none">
      <div class="row" style="justify-content:flex-end">
        <button class="btn" onclick="copyMd()">마크다운 복사</button>
      </div>
      <div id="report"></div>
    </div>

    <!-- GROUP VIEW (grouped input) -->
    <div id="groupView" style="display:none">
      <div class="gqbar">
        <div class="row" style="margin:0">
          <input type="text" id="gAddText" placeholder="목표 입력 후 Enter — 오른쪽 '부모'로 지정된 곳에 추가" style="flex:1;min-width:140px">
          <span class="muted" style="font-size:12px">부모</span>
          <input type="text" id="gParentPick" list="gParentList" placeholder="미분류(최상위)" onchange="gPickParent(this.value)" style="width:170px">
          <datalist id="gParentList"></datalist>
          <button class="btn primary" onclick="gAdd()">추가</button>
        </div>
        <div class="muted" style="font-size:12px;margin-top:4px">부모를 고르면 그 자리에 고정되어 Enter로 자식을 계속 추가할 수 있습니다. 부모를 비우면 새 최상위 목표가 됩니다. 각 섹션 머리글의 <b>+여기에</b>를 누르면 그 목표가 부모로 지정됩니다.</div>
      </div>
      <div class="row" style="margin:0 0 6px">
        <input type="text" id="gSearch" placeholder="부모 섹션 검색…" oninput="gSetQuery(this.value)" style="flex:1;min-width:120px">
        <button class="btn" onclick="gCollapseAll(true)">모두 접기</button>
        <button class="btn" onclick="gCollapseAll(false)">모두 펼치기</button>
      </div>
      <div id="groupSections"></div>
    </div>

    <!-- SCHEDULE VIEW (일정관리 — resource management) -->
    <div id="scheduleView" style="display:none">
      <div class="muted" style="font-size:12px;margin:0 0 4px">목표 날짜·완료 날짜로 리소스를 관리합니다. 각 목표의 <b>목표</b> 날짜시간을 정하면 긴급도(지남·오늘·이번 주·예정)로 묶입니다. 상태를 완료로 바꾸면 <b>완료</b> 시각이 자동 기록되며, 필요하면 직접 수정할 수 있습니다.</div>
      <div id="scheduleSections"></div>
    </div>

    <div class="row" style="margin-top:12px;font-size:15px;border-top:1px solid var(--line);padding-top:12px">
      <b>확정 가치:</b> <b id="confVal">0</b>
      <span class="muted">(현재 생성 <span id="provVal">0</span>)</span>
      · <span id="confStatus" class="muted"></span>
    </div>
  </div>

  <div class="panel" style="margin-bottom:6px"><div id="summary" class="empty">최근 요약 불러오는 중…</div></div>

  <div class="panel">
    <canvas id="chart"></canvas>
    <canvas id="strip"></canvas>
    <div class="legend">
      <span><span class="dot" style="background:var(--accent)"></span>전체 활동량</span>
      <span><span class="dot" style="background:var(--green)"></span>⌨ 키보드</span>
      <span><span class="dot" style="background:#e8a13a"></span>🖱 마우스</span>
      <span>아래 띠: 시간대별 주 활성 앱(색상)</span>
    </div>
  </div>

  <h2>타임라인 로그 (분 단위 · 최신순)</h2>
  <div class="panel">
    <table>
      <thead><tr><th>시간</th><th>길이</th><th>앱 · 사이트</th><th>무드</th><th>BGM 트랙</th><th>활동 (⌨/🖱)</th><th>구분</th></tr></thead>
      <tbody id="logrows"><tr><td colspan="7" class="empty">데이터 없음</td></tr></tbody>
    </table>
  </div>

  <h2>주요 앱 (오늘)</h2>
  <div class="panel"><div class="bars" id="appbars"><span class="empty">데이터 없음</span></div></div>

  <h2>앱별 BGM (적절성 디버그)</h2>
  <div class="panel">
    <table>
      <thead><tr><th>앱</th><th>주 전략</th><th>재생된 BGM 트랙 (BPM)</th><th>활성</th></tr></thead>
      <tbody id="bgmrows"><tr><td colspan="4" class="empty">데이터 없음</td></tr></tbody>
    </table>
    <div class="legend"><span><span class="chip bad" style="margin:0">예시</span> = 전략 밴드를 벗어난 트랙(부적절 의심)</span></div>
  </div>

  <h2 style="display:flex;align-items:center;justify-content:space-between">워커 상태 (백그라운드 작업)
    <a class="btn" href="/worker-log" target="_blank" style="font-size:12px;font-weight:400">전체 로그 타임라인</a></h2>
  <div class="panel">
    <table>
      <thead><tr><th>워커</th><th>하는 일</th><th>주기</th><th>마지막 실행</th><th>다음 실행</th><th>실행</th><th>상태</th><th>로그</th></tr></thead>
      <tbody id="workerrows"><tr><td colspan="8" class="empty">데이터 없음</td></tr></tbody>
    </table>
    <div class="legend"><span><span class="chip" style="margin:0">동작 중</span> = 일정대로 실행 중 · <span class="chip bad" style="margin:0">유휴</span> = 현재 멈춤(세션 비활성 등)</span></div>
  </div>

  <div class="foot">5초마다 자동 갱신 · 127.0.0.1 로컬 전용</div>
</div>

<div class="overlay" id="policy">
  <div class="modal">
    <div class="hdr"><h1 style="margin:0">정책서 (Policy Book)</h1>
      <button class="btn" onclick="document.getElementById('policy').classList.remove('on')">닫기</button></div>
    <p class="muted">각 지표가 어떤 규칙으로 산정되는지 — 규칙만 정리합니다.</p>

    <h2>시간 4분할</h2>
    <ul>
      <li><b>토탈</b>: 활동(입력 또는 미팅) 사이 공백이 <b>6시간 미만</b>인 업무 스팬 전체. 사이의 휴식·미팅·담배 전부 포함.</li>
      <li><b>책상</b>: 입력이 있는 분 중 컨텍스트가 <b>중간(리서치)</b> 또는 <b>적극(에디터)</b>. 뭔가 만들려 시도한 시간.</li>
      <li><b>집중</b>: 입력이 있는 분 중 컨텍스트가 <b>적극(에디터)</b>만. 몰입·순공시간.</li>
      <li><b>퇴근</b>: 활동 공백 <b>6시간 이상</b>. 토탈에서 제외(스팬 분리). 6시간 내 복귀 시 퇴근 없이 연속 업무.</li>
    </ul>
    <p class="muted"><b>연속성(10분 규칙)</b>: 작업(집중/책상) 사이 공백이 <b>10분 이내</b>이고 양쪽이 작업이면 그 사이 분도 같은 작업으로 이어서 인정(잠깐 멈춰도 연속). 예: 18분 집중·21분 작업이면 19·20분도 집중. 10분 초과 공백은 휴식.</p>
    <p class="muted">중첩: 집중 ⊆ 책상 ⊆ 토탈. 순수 휴식(입력 0)은 책상·집중에서 제외(6h 미만 공백은 토탈엔 포함).</p>

    <h2>활동 종류 · 가치 배수</h2>
    <ul>
      <li><span class="pill" style="color:#36c08a">집중 ×5</span> <b>Claude(데스크톱·Code)</b>·Cursor·VSCode·Xcode·IntelliJ·터미널 / 브라우저 <b>localhost(127.0.0.1)</b> · <b>claude.ai</b></li>
      <li><span class="pill" style="color:#e8a13a">책상 ×3</span> ChatGPT·Gemini·Genspark·Perplexity / Notion·Obsidian / <b>커뮤니케이션: Slack·Telegram·KakaoTalk</b></li>
      <li><span class="pill">휴식 ×1</span> YouTube, 일반 브라우징·시청</li>
      <li><span class="pill">미팅</span> Zoom · Teams · Google Meet 등 → 토탈에만 반영</li>
    </ul>
    <p class="muted">커뮤니케이션 앱(Slack·Telegram·Kakao)은 책상으로 분류. 분류는 앱 번들ID·사이트 도메인 기준 — 목록은 ValueTier.swift에서 조정.</p>

    <h2>오늘의 가치 확정 (어뷰징 필터)</h2>
    <ul>
      <li><b>잠정 가치</b> = Σ(작업분 × 배수). 화면엔 '(현재 생성 X)'로 표기.</li>
      <li><b>확정 가치</b>는 아래 3단계를 통과해야 산정되며, 통과 전에는 <b>0</b>:</li>
      <li>① 셀프 리뷰 — 목표 우선순위 대비 본인 기여도(0~100%) 입력</li>
      <li>② AI 필터 — 입력 패턴으로 매크로/어뷰징 자동 검증(신뢰도 %). 9시간 매크로처럼 일정한 입력은 감점.</li>
      <li>③ 관리자 승인 — (준비 중)</li>
      <li><b>확정 가치 = 잠정 × 셀프% × AI신뢰도%</b> (관리자 추후 반영)</li>
    </ul>
  </div>
</div>
<script>
const $ = id => document.getElementById(id);
const PALETTE = ['#5b8cff','#36c08a','#e8a13a','#c879e6','#e2667d','#3ac6c6','#d98c5f','#9aa4b2'];
const colorCache = {};
function appColor(a){
  if(colorCache[a]) return colorCache[a];
  let h=0; for(const c of a) h=(h*31+c.charCodeAt(0))>>>0;
  const col = PALETTE[h % PALETTE.length]; colorCache[a]=col; return col;
}
// strategy label -> [minBPM, maxBPM]
const BANDS = {'칠 (느긋)':[75,100],'스테디 (안정)':[100,125],'집중 (몰입)':[120,150],'하이프 (고조)':[140,175]};
function trackBpm(t){ const m=/\[(\d{2,3})\]/.exec(t||''); return m?parseInt(m[1],10):null; }
function fmtMin(m){ if(m>=60) return (m/60).toFixed(1)+'시간'; return m+'분'; }
// "Accelerator" gauge: live APM (actions/min, StarCraft-style). Backend polled
// fast (~100ms); the number + bar are driven by a damped SPRING every animation
// frame so they snap toward the target with a little tachometer kick (overshoot).
// Juice: zone color (green->amber->red), a redline pulse glow, and a VU-style
// peak-hold marker that floats down from the recent max.
let _apmTo=0,_apmAt=0,_apmV=0,_nmTo=0,_nmAt=0,_nmV=0,_peak=0,_gaugeOn=false,_lastT=0;
const SPRING_K=500, SPRING_D=26;   // stiffness / damping => zeta~0.58, ~250ms snap, ~8% overshoot
// --- Gauge mode: 스포츠(라이브 APM 바운싱) ↔ 타임(토탈 시간 카운트업) ----------
// 시작 1시간 이전엔 스포츠로 집중·재미에, 8시간을 넘기면 타임으로 체력 총량의
// 뿌듯함에 포커스가 가도록 자동 기본값을 정한다. 사용자가 직접 토글하면 자동
// 전환은 멈춘다(_modeUserSet). 타임 모드는 토탈 시간을 초 단위로 카운트업한다.
let _gaugeMode='sports', _modeUserSet=false;
let _totalBaseSec=0, _totalBaseWall=0, _working=false;
function fmtClock(sec){
  sec=Math.max(0,Math.floor(sec));
  const h=Math.floor(sec/3600), m=Math.floor((sec%3600)/60), s=sec%60;
  const p=n=>('0'+n).slice(-2);
  return h+':'+p(m)+':'+p(s);
}
function ensureTimeGauge(){
  const host=$('accel'); if(!host) return false;
  if(host.dataset.tbuilt!=='1'){
    host.innerHTML=' &nbsp; <span style="color:var(--mut)">토탈 </span>'
      +'<span id="apmtime" style="display:inline-block;font-variant-numeric:tabular-nums;font-weight:700">0:00:00</span>'
      +'<span id="apmtlab" style="color:var(--mut)"></span>';
    host.dataset.tbuilt='1';
  }
  return true;
}
function renderTime(){
  if(!ensureTimeGauge()) return;
  const live=_working ? (Date.now()-_totalBaseWall)/1000 : 0;
  const num=$('apmtime'); if(num){ num.textContent=fmtClock(_totalBaseSec+live); num.style.color=_working?'var(--green)':'var(--fg)'; }
  const lab=$('apmtlab'); if(lab) lab.textContent=_working?' · 진행 중':' · 정지';
}
function setGaugeMode(m, byUser){
  _gaugeMode=m;
  if(byUser) _modeUserSet=true;
  const sb=$('mode_sports'), tb=$('mode_time');
  if(sb) sb.className=(m==='sports')?'btn primary':'btn';
  if(tb) tb.className=(m==='time')?'btn primary':'btn';
  const host=$('accel');
  if(host){ host.innerHTML=''; host.dataset.built=''; host.dataset.tbuilt=''; }
  if(m==='time') renderTime();   // 스포츠는 다음 라이브 틱에서 재구성
}
function ensureGauge(){
  const host=$('accel'); if(!host) return false;
  if(host.dataset.built!=='1'){
    host.innerHTML=' &nbsp; <span id="apmlab" style="color:var(--mut)">APM </span>'
      +'<span id="apmnum" style="display:inline-block;min-width:4ch;text-align:right;font-variant-numeric:tabular-nums;font-weight:700">0</span>'
      +' <span id="apmbar" style="position:relative;display:inline-block;width:96px;height:9px;border-radius:5px;background:#1b1f29;vertical-align:middle;overflow:hidden">'
      +'<span id="apmfill" style="position:absolute;left:0;top:0;height:100%;width:0%;background:#36c08a"></span>'
      +'<span id="apmpeak" style="position:absolute;top:0;height:100%;width:2px;background:#fff;opacity:.65;left:0%"></span></span>'
      +'<span id="apmgear" style="color:var(--mut)"></span><span id="apmnext" style="color:var(--mut)"></span>';
    host.dataset.built='1';
  }
  return true;
}
function zoneColor(x){   // 0 -> green, 0.6 -> amber, 1 -> red
  const h = x<0.6 ? 145-(145-42)*(x/0.6) : 42-42*Math.min(1,(x-0.6)/0.4);
  return 'hsl('+Math.max(0,h).toFixed(0)+',72%,55%)';
}
function renderGauge(t){
  const red=_nmTo>=0.85, nm=Math.min(1,Math.max(0,_nmAt));
  const num=$('apmnum'),fill=$('apmfill'),bar=$('apmbar'),peak=$('apmpeak'),lab=$('apmlab');
  if(num){ num.textContent=Math.max(0,Math.round(_apmAt)); num.style.color=red?'#ff5a6e':'var(--fg)'; }
  if(fill){ fill.style.width=(nm*100).toFixed(1)+'%'; fill.style.background=zoneColor(nm); }
  if(peak) peak.style.left=(Math.min(1,_peak)*100).toFixed(1)+'%';
  if(lab) lab.style.color=red?'#ff5a6e':'var(--mut)';
  if(bar){
    if(red){ const g=0.5+0.5*Math.sin(t*0.009); bar.style.boxShadow='0 0 '+(5+9*g).toFixed(1)+'px rgba(255,90,110,'+(0.45+0.45*g).toFixed(2)+')'; }
    else bar.style.boxShadow='none';
  }
}
function setGauge(n){
  const host=$('accel');
  if(_gaugeMode==='time'){ renderTime(); return; }   // 타임 모드가 #accel을 소유
  if(!n||!n.track||n.track==='-'){ if(host){host.innerHTML='';host.dataset.built='';} _gaugeOn=false; _apmTo=_apmAt=_apmV=_nmTo=_nmAt=_nmV=_peak=0; return; }
  _gaugeOn=true;
  if(!ensureGauge()) return;
  _apmTo=Math.max(0,n.apm||0);
  _nmTo=Math.max(0,Math.min(1,n.norm||0));
  const g=$('apmgear'),nx=$('apmnext');
  if(g) g.textContent=(n.gear&&n.gear!=='-')?(' · '+n.gear):'';
  if(nx) nx.textContent=(n.nextTrack&&n.nextTrack!=='-')?(' → 다음 '+n.nextTrack):'';
}
// --- Page resource meter (top-right) -------------------------------------
// Memory: JS heap via performance.memory (Chromium only); DOM node count works
// everywhere. CPU is not exposed to JS, so we approximate it from frame timing:
// over a 1s window, the fraction of wall-clock the main thread overran the
// 60fps frame budget (16.7ms) is shown as an approximate busy %, with the
// measured FPS alongside. Honest proxy, not a real OS CPU reading.
const _FRAME_MS=1000/60;
let _pfFrames=0, _pfBusy=0, _pfWin=0, _pfLast=0, _pfRenderMs=0;
function perfFrame(t){
  if(_pfLast){ const ms=t-_pfLast; _pfFrames++; if(ms>_FRAME_MS) _pfBusy+=(ms-_FRAME_MS); }
  _pfLast=t;
  if(t-_pfWin>=1000){
    const span=t-_pfWin; _pfWin=t;
    const fps=Math.round(_pfFrames*1000/Math.max(1,span));
    const cpu=Math.min(99,Math.round(_pfBusy/Math.max(1,span)*100));
    _pfFrames=0; _pfBusy=0;
    const el=$('perf'); if(el){
      let mem='';
      const m=(performance&&performance.memory)?performance.memory:null;
      if(m){ mem='메모리 '+(m.usedJSHeapSize/1048576).toFixed(0)+'MB'; }
      const nodes=document.getElementsByTagName('*').length;
      const r=_pfRenderMs?(' · 렌더 '+_pfRenderMs.toFixed(0)+'ms'):'';
      el.textContent=(mem?mem+' · ':'')+'DOM '+nodes+'개 · CPU ~'+cpu+'% · '+fps+'fps'+r;
    }
  }
}
function tweenGauge(t){
  perfFrame(t);
  const dt = _lastT ? Math.min(0.033,(t-_lastT)/1000) : 0.016; _lastT=t;
  if(_gaugeMode==='time'){
    renderTime();
  } else if(_gaugeOn){
    _apmV += ((_apmTo-_apmAt)*SPRING_K - _apmV*SPRING_D)*dt; _apmAt += _apmV*dt;
    _nmV  += ((_nmTo-_nmAt)*SPRING_K - _nmV*SPRING_D)*dt;     _nmAt  += _nmV*dt;
    if(_nmAt>_peak) _peak=_nmAt; else _peak=Math.max(_nmAt, _peak-0.18*dt);  // peak-hold drifts down
    renderGauge(t);
  }
  requestAnimationFrame(tweenGauge);
}
requestAnimationFrame(tweenGauge);
async function liveTick(){
  let l; try { l = await (await fetch('/live.json',{cache:'no-store'})).json(); }
  catch(e){ return; }
  setGauge(l);
}

async function load(){
  let d;
  try { d = await (await fetch('/data.json',{cache:'no-store'})).json(); }
  catch(e){ return; }
  $('total').textContent = d.total.label;
  const w = d.now.working;
  $('status').innerHTML = '<span class="dot" style="background:'+(w?'var(--green)':'#555')+'"></span>'+d.now.status;
  $('date').textContent = d.date + ' · 분당 기록';
  // DEV dataset indicator: badge + top ribbon + tab title prefix when not production.
  const dev=$('devBadge');
  if(d.dev){ dev.style.display='inline-block'; dev.textContent='DEV · '+(d.dataLabel||'localdata');
    document.body.classList.add('devmode');
    if(!document.title.startsWith('[DEV]')) document.title='[DEV] '+document.title; }
  else { dev.style.display='none'; document.body.classList.remove('devmode'); }
  const ss = withCarryForward(d.samples);   // 10-min continuity applied
  const b = timeBuckets(ss);
  $('t_total').textContent = fmtH(b.total);
  $('t_desk').textContent = fmtH(b.desk);
  $('t_focus').textContent = fmtH(b.focus);
  $('t_off').textContent = b.off > 0 ? fmtH(b.off) : '–';
  // Gauge mode: 타임 카운트업 기준(토탈 분→초) + 자동 기본값(<8h 스포츠, 8h+ 타임).
  _totalBaseSec = b.total*60; _totalBaseWall = Date.now(); _working = !!w;
  if(!_modeUserSet) setGaugeMode(b.total>=480 ? 'time' : 'sports', false);
  drawTiers(b);
  const n=d.now;
  const siteStr=(n.site&&n.site!=='-')?' ('+esc(n.site)+')':'';
  $('now').innerHTML='지금: 앱 <b>'+esc(n.app)+siteStr+'</b> &nbsp; '+tierBadge(n.tier,n.mult)
    +' &nbsp; ⌨ '+(n.key||0)+' 🖱 '+(n.mouse||0)+' &nbsp; 전략 <b>'+esc(n.profile)+'</b> · BGM <b>'+esc(n.track)+'</b><span id="accel"></span>';
  setGauge(n);
  const _t0=performance.now();
  drawChart(ss);
  drawStrip(ss);
  renderReview(d);
  renderSummary(ss);
  renderTimeline(ss);
  renderApps(ss);
  renderWorkers(d.workers);
  _pfRenderMs=performance.now()-_t0;
}
function hhmm(t){ const d=new Date(t*1000); return ('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2); }

function renderSummary(samples){
  const el=$('summary');
  if(!samples.length){ el.textContent='데이터 없음'; return; }
  const lastT=samples[samples.length-1].t;
  const recent=samples.filter(s=>s.t>=lastT-30*60 && s.app && s.app!=='-');
  if(!recent.length){ el.textContent='최근 30분 활동 없음'; return; }
  const apps={}; let active=0, valSec=0;
  recent.forEach(s=>{ const e=apps[s.app]||(apps[s.app]={m:0,prof:{}}); e.m++; active+=(s.active||0);
    valSec+=(s.active||0)*(s.mult||1);
    if(s.profile&&s.profile!=='-') e.prof[s.profile]=(e.prof[s.profile]||0)+1; });
  const top=Object.entries(apps).sort((a,b)=>b[1].m-a[1].m).slice(0,3).map(([a,e])=>{
    const p=Object.entries(e.prof).sort((x,y)=>y[1]-x[1])[0];
    const col=appColor(a);
    return '<span class="dot" style="background:'+col+'"></span>'+esc(a)+' '+e.m+'분'+(p?' ('+esc(p[0].split(' ')[0])+')':'');
  });
  el.innerHTML='<b>최근 30분</b> · 작업 '+Math.round(active/60)+'분 · 가치 '+Math.round(valSec/60)+'분(가중) · '+top.join(' &nbsp; ');
}

// Merge consecutive minutes sharing the same app+site+mood+track into one segment.
function timelineSegments(samples){
  const segs=[];
  samples.forEach(s=>{
    const key=(s.app||'-')+'|'+(s.site||'-')+'|'+(s.profile||'-')+'|'+(s.track||'-');
    const last=segs[segs.length-1];
    if(last && last.key===key && (s.t-last.endT)<=120){
      last.endT=s.t; last.mins++; last.activeSum+=(s.active||0);
      last.keySum+=(s.key||0); last.mouseSum+=(s.mouse||0); last.meeting=s.meeting||last.meeting;
    } else {
      segs.push({key,app:s.app||'-',site:s.site||'-',profile:s.profile||'-',track:s.track||'-',
                 tier:s.tier||'소극',mult:s.mult||1,meeting:s.meeting||false,startT:s.t,endT:s.t,mins:1,
                 activeSum:(s.active||0),keySum:(s.key||0),mouseSum:(s.mouse||0)});
    }
  });
  return segs;
}

// Lazy timeline: keep all segments in memory-light form but only paint a small
// initial slice into the DOM (the table is the heaviest part of the page). The
// "불러오기" button reveals more on demand, so the default DOM footprint stays
// minimal regardless of how long the log gets. _logShown survives auto-refresh
// so an expanded view isn't collapsed every 5s.
const LOG_INIT=30, LOG_STEP=50, LOG_MAX=600;
let _logSegs=[], _logShown=LOG_INIT;
function rowHtml(g){
      const idle=(g.app==='-');
      const col=idle?'#555':appColor(g.app);
      const band=BANDS[g.profile];
      const bpm=trackBpm(g.track);
      const bad=band&&bpm!=null&&(bpm<band[0]||bpm>band[1]);
      const trackCell=(g.track==='-')?'<span class="empty">–</span>'
        :'<span class="chip'+(bad?' bad':'')+'" style="margin:0">'+esc(g.track)+'</span>';
      const siteRow=(g.site&&g.site!=='-')?'<div style="color:var(--mut);font-size:11px">'+esc(g.site)+'</div>':'';
      const k=Math.round(g.keySum/g.mins), mo=Math.round(g.mouseSum/g.mins);
      return '<tr>'
        +'<td style="white-space:nowrap">'+hhmm(g.startT)+'</td>'
        +'<td style="white-space:nowrap;color:var(--mut)">'+g.mins+'분</td>'
        +'<td style="white-space:nowrap"><span class="dot" style="background:'+col+'"></span>'+esc(g.app)+siteRow+'</td>'
        +'<td style="white-space:nowrap">'+esc(g.profile)+'</td>'
        +'<td>'+trackCell+'</td>'
        +'<td style="white-space:nowrap;color:var(--mut)">⌨'+k+' 🖱'+mo+'</td>'
        +'<td>'+categoryBadge(g)+'</td>'
        +'</tr>';
}
function paintTimeline(){
  const rows=$('logrows');
  const total=_logSegs.length;
  if(!total){ rows.innerHTML='<tr><td colspan="7" class="empty">데이터 없음</td></tr>'; return; }
  const shown=Math.min(_logShown,total);
  let html=_logSegs.slice(0,shown).map(rowHtml).join('');
  if(shown<total){
    const next=Math.min(LOG_STEP,total-shown);
    html+='<tr><td colspan="7" style="text-align:center;padding:10px">'
      +'<button class="btn" onclick="loadMoreLog()">불러오기 (+'+next+')</button>'
      +' <span class="muted" style="font-size:11px">전체 '+total+'개 중 '+shown+'개 표시 · 메모리 절약 모드</span>'
      +'</td></tr>';
  } else if(total>LOG_INIT){
    html+='<tr><td colspan="7" style="text-align:center;padding:6px"><span class="muted" style="font-size:11px">전체 '+total+'개 표시</span></td></tr>';
  }
  rows.innerHTML=html;
}
function loadMoreLog(){ _logShown=Math.min(_logShown+LOG_STEP,LOG_MAX,_logSegs.length); paintTimeline(); }
function renderTimeline(samples){
  _logSegs=timelineSegments(samples).reverse().slice(0,LOG_MAX);
  // Clamp the persisted "shown" count to the new total (never below the initial).
  _logShown=Math.max(LOG_INIT,Math.min(_logShown,_logSegs.length));
  paintTimeline();
}
function esc(s){ return (s||'-').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function minOfDay(s){ const dt=new Date(s.t*1000); return dt.getHours()*60+dt.getMinutes(); }
function fmtH(min){ const h=Math.floor(min/60), m=min%60; return h>0? h+'시간 '+m+'분' : m+'분'; }
const TENMIN=10*60;
// Carry-forward (10-min continuity): a rest gap <= 10min bridged by work on BOTH
// sides becomes part of that continuous work — the in-between minutes are absorbed
// into the surrounding work, so a brief interruption (System Settings check, a
// loginwindow, a quick google) counts as 집중/책상 instead of breaking the streak.
//
// WHY neighbor-AGREEMENT (전후 일치), not "inherit the preceding tier":
//   The bridge tier is decided by BOTH ends. We only call the gap 집중(focus) when
//   BOTH neighbors are focus; if either side is merely 책상(desk), the gap stays
//   책상. Rationale: 집중 is 순공/몰입 (payout-relevant), so an interruption must
//   never INVENT focus it didn't earn — a pause between focus and desk is, at best,
//   desk-level continuity. Examples (matches the user's screenshots):
//     Cursor (집중) | System Settings | Cursor (집중)  -> gap = 집중
//     Slack (책상)  | loginwindow     | Slack (책상)   -> gap = 책상
//     Cursor (집중) | System Settings | Slack (책상)   -> gap = 책상 (전후 불일치)
function withCarryForward(samples){
  const ss=samples.slice().sort((a,b)=>a.t-b.t).map(s=>Object.assign({},s));
  ss.forEach(s=>{
    if(s.meeting) s._cat='meeting';
    else if((s.active||0)>0 && s.tier==='적극') s._cat='focus';
    else if((s.active||0)>0 && s.tier==='중간') s._cat='desk';
    else s._cat='rest';
  });
  const work=[]; ss.forEach((s,i)=>{ if(s._cat==='focus'||s._cat==='desk') work.push(i); });
  for(let k=0;k<work.length-1;k++){
    const a=work[k], b=work[k+1];                      // a = preceding work, b = following work
    if(ss[b].t-ss[a].t<=TENMIN){
      // Only focus when BOTH ends are focus; otherwise the bridge is desk.
      const bridgeFocus=(ss[a]._cat==='focus' && ss[b]._cat==='focus');
      // Inherit display fields from the neighbor that matches the bridge tier.
      const src=bridgeFocus ? a : (ss[a]._cat==='desk' ? a : b);
      const cat=bridgeFocus ? 'focus' : 'desk';
      for(let j=a+1;j<b;j++) if(ss[j]._cat==='rest'){
        ss[j]._cat=cat; ss[j]._inferred=true;
        ss[j].app=ss[src].app; ss[j].site=ss[src].site; ss[j].profile=ss[src].profile;
        ss[j].track=ss[src].track; ss[j].tier=ss[src].tier; ss[j].mult=ss[src].mult;
      }
    }
  }
  return ss;
}
// Time buckets (operates on carry-forward samples; each = 1 minute).
// Span anchors separated by < 6h = one work span; >= 6h gaps are 퇴근.
function timeBuckets(ss){
  const SIXH=6*3600;
  const anchors=[]; let desk=0, focus=0;
  ss.forEach(s=>{
    if(s._cat==='focus'){ focus++; desk++; }
    else if(s._cat==='desk'){ desk++; }
    if((s.active||0)>0 || s.meeting || s._inferred) anchors.push(s.t);
  });
  let total=0, off=0;
  if(anchors.length){
    total=1;
    for(let i=1;i<anchors.length;i++){
      const gap=anchors[i]-anchors[i-1];
      if(gap < SIXH) total += gap/60;   // rest/meeting within span -> total
      else off += gap/60;               // >=6h gap -> 퇴근
    }
  }
  return {total:Math.round(total), desk, focus, off:Math.round(off)};
}
function drawTiers(b){
  const c=$('tiers'),dpr=window.devicePixelRatio||1,W=c.clientWidth,H=18;
  c.width=W*dpr;c.height=H*dpr;const g=c.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W,H);
  const max=Math.max(b.total,1), bw=v=>W*(v/max);
  g.fillStyle='#2a2f3a'; g.fillRect(0,2,bw(b.total),14);  // total
  g.fillStyle='#e8a13a'; g.fillRect(0,2,bw(b.desk),14);   // desk (nested)
  g.fillStyle='#36c08a'; g.fillRect(0,2,bw(b.focus),14);  // focus (nested)
}
function tierColor(t){ return t==='적극'?'#36c08a':t==='중간'?'#e8a13a':'#9aa4b2'; }
function tierBadge(t,m){ const c=tierColor(t); return '<span class="chip" style="margin:0;border-color:'+c+';color:'+c+'">'+esc(t||'소극')+' ×'+(m||1)+'</span>'; }
// 책상/집중/휴식/미팅 구분 뱃지 (타임라인용)
function categoryBadge(seg){
  let label,color;
  if(seg.meeting){label='미팅';color='#9aa4b2';}
  else if(seg.tier==='적극'){label='집중';color='#36c08a';}
  else if(seg.tier==='중간'){label='책상';color='#e8a13a';}
  else {label='휴식';color='#9aa4b2';}
  return '<span class="chip" style="margin:0;border-color:'+color+';color:'+color+'">'+label+' ×'+(seg.mult||1)+'</span>';
}

// --- Value-confirmation pipeline + report ---
function provisionalHours(samples){ return samples.reduce((a,s)=>a+(s.active||0)*(s.mult||1),0)/3600; }
function post(path,obj){ return fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(obj||{})}).then(()=>load()); }
// Korean IME safe submit: defer the Enter-submit until composition ends. macOS WebKit
// can report the composition-committing Enter with isComposing=false, so a plain keydown
// guard is unreliable; if addGoal() clears the field mid-composition the IME re-inserts
// the trailing syllable into the empty field, leaking it as a duplicate goal.
let _composing=false,_pendingAdd=false;
function goalKey(e){ if(e.key!=='Enter')return; if(_composing){_pendingAdd=true;} else { addGoal(); } }
(function(){ const el=document.getElementById('goalText'); if(!el)return;
  el.addEventListener('compositionstart',function(){_composing=true;});
  el.addEventListener('compositionend',function(){_composing=false; if(_pendingAdd){_pendingAdd=false; addGoal();}});
})();
// Group-mode top add bar: same IME-safe Enter (bindImeEnter is hoisted).
(function(){ bindImeEnter(document.getElementById('gAddText'), function(){ gAdd(); }); })();
function addGoal(){ const t=$('goalText').value.trim(); if(!t)return; $('goalText').value=''; $('goalText').focus(); post('/api/goal/add',{text:t}); }
function removeGoal(id){ post('/api/goal/remove',{id:id}); }
function saveNote(id,note){ post('/api/goal/note',{id:id,note:note}); }
// Inline rename: double-click a goal title to edit it in place. IME-safe Enter
// commits, Esc cancels, blur commits; empty or unchanged just restores. For a
// session-linked goal the server also mirrors the new title into the transcript so
// it survives future session events (see /api/goal/title).
function startTitleEdit(e,id){
  if(e){e.stopPropagation();}
  const span=document.getElementById('gt_'+id); if(!span||span._editing)return;
  const g=(_goals||[]).find(x=>x.id===id); const cur=g?(g.text||''):span.textContent;
  span._editing=true;
  const inp=document.createElement('input');
  inp.type='text'; inp.className='gedit'; inp.value=cur; inp.title='Enter 저장 · Esc 취소';
  span.innerHTML=''; span.appendChild(inp); inp.focus(); inp.select();
  let done=false;
  function commit(){ if(done)return; done=true;
    const t=inp.value.trim();
    if(!t||t===cur){ load(); return; }   // unchanged/empty -> restore
    post('/api/goal/title',{id:id,title:t}); }   // reloads on success
  inp.addEventListener('keydown',function(ev){ if(ev.key==='Escape'){ev.preventDefault();ev.stopPropagation(); if(!done){done=true; load();}} });
  inp.addEventListener('blur',commit);
  bindImeEnter(inp,commit);
}
// --- Completion evidence (links + files) + 완료 필터 ---
// Evidence is attached to the goal (persistent), so a finished item keeps its links
// and files for later — to find it and hand off the supporting material. Files are
// copied into the app store and served back via /evidence/<goalId>/<id>.
let _evOpen=new Set();    // goal ids whose evidence panel is expanded
// Per-status visibility toggles. A goal shows when its effective status is active.
// All-on = 전체(모두); only-done reproduces the old "완료만" hand-off view.
// waiting has no filter toggle (no UI button): it is always surfaced so a goal parked
// for the user can never be hidden — the whole point of the 응답 대기 state.
// stopped (중지) is shown by default like waiting (user needs to see it to resume); cancelled
// (취소) is HIDDEN by default and revealed via its own toggle, the way 완료 hand-off works.
let _statusFilter={backlog:true,in_progress:true,waiting:true,stopped:true,cancelled:false,done:true};
// 상위 항상 표시: when on, parents (goals with children) bypass the status filter so the
// hierarchy never collapses out from under a child. Default off = parents follow their
// rolled-up status like any other goal (디폴트는 부모도 안 보이도록).
let _showParents=false;
let _review=null;         // last review object (for filter-only re-render)
let _lastReportArgs=null; // cached (d,r,conf,prov) so 프리뷰 can re-render on filter change
function evCount(g){ return (g.evidence||[]).length; }
function toggleEv(id){ if(_evOpen.has(id))_evOpen.delete(id); else _evOpen.add(id); applyEvOpen(); }
function applyEvOpen(){ (_goals||[]).forEach(g=>{ const p=document.getElementById('ev_'+g.id);
  if(p) p.classList.toggle('open', _evOpen.has(g.id)); }); }
// Review memo as a toggle button + collapsible inline editor (saveNote unchanged).
let _noteOpen=new Set();   // goal ids whose memo editor is expanded
function noteBtn(g,r){ const has=!!gnote(r,g.id);
  return '<button class="btn notebtn'+(has?' has':'')+'" onclick="toggleNote(\''+g.id+'\')" title="리뷰 메모">📝'+(has?' ✓':'')+'</button>'; }
function notePanel(g,r){ const nv=gnote(r,g.id).replace(/"/g,'&quot;');
  return '<div class="notepanel" id="note_'+g.id+'">'
    +'<input type="text" placeholder="리뷰 메모 입력" value="'+nv+'" onchange="saveNote(\''+g.id+'\',this.value)">'
    +'</div>'; }
function toggleNote(id){ if(_noteOpen.has(id))_noteOpen.delete(id); else _noteOpen.add(id); applyNoteOpen();
  const p=document.getElementById('note_'+id); if(p&&_noteOpen.has(id)){ const el=p.querySelector('input'); if(el) el.focus(); } }
function applyNoteOpen(){ (_goals||[]).forEach(g=>{ const p=document.getElementById('note_'+g.id);
  if(p) p.classList.toggle('open', _noteOpen.has(g.id)); }); }
function evItem(g,e){
  const t=esc(e.title||e.href||''), icon=(e.kind==='file')?'📄 ':'🔗 ';
  const a=(e.kind==='file')
    ? '<a href="'+esc(e.href)+'" download>'+icon+t+'</a>'
    : '<a href="'+esc(e.href)+'" target="_blank" rel="noopener">'+icon+t+'</a>';
  return '<span class="evitem">'+a+'<button class="evx" title="삭제" onclick="removeEvidence(\''+g.id+'\',\''+e.id+'\')">✕</button></span>';
}
function evidencePanel(g){
  const ev=g.evidence||[];
  const list=ev.length? ev.map(e=>evItem(g,e)).join('')
    : '<span class="muted" style="font-size:12px">첨부된 증거가 없습니다. 링크나 파일을 추가하세요.</span>';
  return '<div class="evpanel" id="ev_'+g.id+'">'
    +'<div class="evlist">'+list+'</div>'
    +'<div class="row" style="margin:6px 0 0">'
      +'<input type="text" id="evurl_'+g.id+'" placeholder="링크 URL 붙여넣기 후 Enter" style="flex:1;min-width:140px" onkeydown="evLinkKey(event,\''+g.id+'\')">'
      +'<button class="btn" onclick="addEvidenceLink(\''+g.id+'\')">링크 추가</button>'
      +'<label class="btn" style="cursor:pointer">파일 첨부<input type="file" multiple style="display:none" onchange="addEvidenceFiles(\''+g.id+'\',this)"></label>'
    +'</div></div>';
}
function evLinkKey(e,id){ if(e.key==='Enter'){ e.preventDefault(); addEvidenceLink(id); } }
function addEvidenceLink(id){
  const el=document.getElementById('evurl_'+id); if(!el)return;
  let u=el.value.trim(); if(!u)return;
  if(!/^[a-z][a-z0-9+.-]*:/i.test(u)) u='https://'+u;   // bare domain -> https
  el.value=''; _evOpen.add(id);
  post('/api/goal/evidence/add',{id:id,kind:'link',url:u});
}
function removeEvidence(gid,eid){ _evOpen.add(gid); post('/api/goal/evidence/remove',{id:gid,evidenceId:eid}); }
const EV_MAX=48*1024*1024;   // ~48MB/file (server caps the base64 request at 64MB)
function addEvidenceFiles(id,input){
  const files=input.files; if(!files||!files.length)return;
  _evOpen.add(id);
  let i=0;
  (function next(){
    if(i>=files.length){ input.value=''; load(); return; }
    const f=files[i++];
    if(f.size>EV_MAX){ alert('파일이 너무 큽니다(48MB 초과): '+f.name); next(); return; }
    const rd=new FileReader();
    rd.onload=function(){
      fetch('/api/goal/evidence/add',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({id:id,kind:'file',filename:f.name,data:rd.result})})
        .then(()=>next()).catch(()=>next());
    };
    rd.onerror=function(){ next(); };
    rd.readAsDataURL(f);
  })();
}
// 완료 필터: 완료된 목표(또는 자식이 모두 완료된 부모)만 추려, 나중에 찾고 자료를 넘길 때 사용.
function isDoneGoal(g,goals){ return (g.status==='done')||(derivedStatus(goals,g)==='done'); }
// Effective status used for visibility filtering. Parents report a derived rollup
// (on_track counts as 진행); leaves use their own status (default 대기).
function effStatus(g,goals){ const ds=derivedStatus(goals,g); if(ds!=null) return ds==='on_track'?'in_progress':ds; return g.status||'backlog'; }
// ===== Unified visibility: ONE filter feeds 목록·그룹·프리뷰 =====
// Single source of truth for "does this goal pass the current filter". Every view calls
// this instead of re-implementing the status test, so a filter applied once shows the
// same result everywhere. A parent (has children) is kept regardless when 상위 항상 표시
// is on; otherwise it follows its rolled-up effStatus like a leaf.
function hasKids(goals,g){ return goals.some(k=>k.parent===g.id); }
function goalPasses(g,goals){
  if(_showParents && hasKids(goals,g)) return true;
  return !!_statusFilter[effStatus(g,goals)];
}
function getFilteredGoals(goals){ return goals.filter(g=>goalPasses(g,goals)); }
// Re-render every view from the cached review when the filter changes — instant feedback
// in whichever view is active, without waiting for the 5s auto-refresh.
function reapplyFilter(){
  if(!_review) return;
  updateFilterButtons();
  fillActiveView(_review);
  if(_lastReportArgs){ const a=_lastReportArgs; _md=buildMarkdown(a.d,a.r,a.conf,a.prov); renderReport(a.d,a.r,a.conf,a.prov); }
}
// 보기 토글: 상태 버튼을 켜면 그 상태의 목표가 보이고, 끄면 숨겨진다.
function toggleStatusFilter(s){ _statusFilter[s]=!_statusFilter[s]; reapplyFilter(); }
function toggleShowParents(){ _showParents=!_showParents; reapplyFilter(); }
function anyStatusActive(){ return _statusFilter.backlog||_statusFilter.in_progress||_statusFilter.done||_statusFilter.cancelled; }
// Summary text mirrors the active combo: 모두 / 완료 만 / 완료 진행 만 …
function filterSummary(){
  if(!anyStatusActive()) return '표시할 상태를 선택하세요 (대기 · 진행 · 완료)';
  if(_statusFilter.backlog&&_statusFilter.in_progress&&_statusFilter.done&&!_statusFilter.cancelled) return '모두 표시';
  const names=[];
  if(_statusFilter.done) names.push('완료');
  if(_statusFilter.cancelled) names.push('취소');
  if(_statusFilter.in_progress) names.push('진행');
  if(_statusFilter.backlog) names.push('대기');
  return names.join(' ')+' 만';
}
function updateFilterButtons(){
  [['flt_backlog','backlog'],['flt_inprog','in_progress'],['flt_done','done'],['flt_cancelled','cancelled']].forEach(function(p){
    const b=$(p[0]); if(b) b.classList.toggle('primary',!!_statusFilter[p[1]]);
  });
  const pb=$('flt_parents'); if(pb) pb.classList.toggle('primary',_showParents);
  const s=$('flt_summary'); if(s) s.textContent='— '+filterSummary()+(_showParents?' · 상위 항상 표시':'');
}
// --- Goal status + per-goal time tracking ---
// Multiple goals MAY run in_progress at once (only feasible with AI). The server banks
// elapsed time on every transition; trackedSeconds is the banked total, and while running
// we add the live session (now - startedAt) on the client so the clock ticks without
// re-rendering. The count of concurrent in_progress goals gates the AI-work inputs below.
const VGAIN='0.5';   // value units (v) awarded per completion — abstract value, NOT hours
// --- Concurrency-gated AI-work helpers (energy / agents / tokens / value / ROI) ---
// Energy/agent/token/value are managed at the PARENT (big-picture goal) level, NOT per
// leaf task — per-task entry was too costly/noisy. The unit of "concurrent work" is an
// ACTIVE PARENT: a parent whose rollup is on_track (some child is in progress). Thresholds:
// 1+ active parent -> agent/token/value/ROI; 2+ active parents -> energy split + gauge.
const CONC_ENERGY=2, CONC_AGENT=1;
// ROI = value / tokens(K). Tunable bands: >=HI efficient, >=LO acceptable, else token burn.
const ROI_HI=1.0, ROI_LO=0.4;
// A parent is "active" when its derived rollup is on_track (a child is in progress).
function activeParent(goals,g){ return derivedStatus(goals,g)==='on_track'; }
function concCount(goals){ return (goals||[]).filter(g=>activeParent(goals,g)).length; }
function energySum(goals){ return (goals||[]).filter(g=>activeParent(goals,g)).reduce((a,g)=>a+(g.energy||0),0); }
function roiOf(g){ return ((g.tokens||0)>0)?((g.value||0)/g.tokens):null; }
function roiClass(r){ return r==null?'':(r>=ROI_HI?'hi':(r>=ROI_LO?'mid':'lo')); }
function setEnergy(id,v){ post('/api/goal/energy',{id:id,energy:parseInt(v,10)||0}); }
function setAgents(id,s){ post('/api/goal/agents',{id:id,agents:String(s||'')}); }
function setTokens(id,v){ post('/api/goal/tokens',{id:id,tokens:parseInt(v,10)||0}); }
function setValue(id,v){ post('/api/goal/value',{id:id,value:parseInt(v,10)||0}); }
function setStatus(id,s,ev){
  // Completing a task is a value moment: play the check sweep + floating +Nv, then
  // commit. Value is in "v" (not hours) on purpose — rewarding hours just invites
  // filling time; v rewards finishing something worth finishing.
  if(s==='done'){ celebrateDone(id, ev&&ev.target?ev.target.closest('.goal'):null); return; }
  post('/api/goal/status',{id:id,status:s});
}
function celebrateDone(id,row){
  if(row && row.classList.contains('celebrate')) return;   // debounce double-clicks
  _evOpen.add(id);   // open the evidence panel so the just-finished goal invites a link/file
  playDing();
  if(row){
    row.classList.add('celebrate');
    const g=row.querySelector('.g'); if(g && !g.querySelector('.gstrike')){
      const st=document.createElement('span'); st.className='gstrike'; g.appendChild(st);
      requestAnimationFrame(()=>requestAnimationFrame(()=>st.classList.add('on')));
    }
    floatValue(row);
  }
  // Commit after the sweep is visible; the reload then settles the row to its done state.
  setTimeout(()=>post('/api/goal/status',{id:id,status:'done'}), 480);
}
// Cash-register "ka-ching" completion sound (Web Audio — no asset, offline):
// a drawer clack (band-passed noise burst) + a double metallic bell built from
// INHARMONIC partials (1 : 2.41 : 3.93 : 5.2 — non-integer ratios give the metal
// timbre). Played inside the click gesture so WebKit autoplay allows it; gentle
// gains so it sits over the focus BGM without spiking.
let _actx=null;
function _bell(c,t0,base,amp,dur){
  [1,2.41,3.93,5.2].forEach((r,i)=>{
    const o=c.createOscillator(), g=c.createGain();
    o.type='sine'; o.frequency.value=base*r; const a=amp/(i+1);
    g.gain.setValueAtTime(0.0001,t0);
    g.gain.exponentialRampToValueAtTime(a,t0+0.005);
    g.gain.exponentialRampToValueAtTime(0.0001,t0+dur);
    o.connect(g).connect(c.destination); o.start(t0); o.stop(t0+dur+0.02);
  });
}
function _clack(c,t0,freq,amp,dur){
  const n=Math.floor(c.sampleRate*dur), buf=c.createBuffer(1,n,c.sampleRate), d=buf.getChannelData(0);
  for(let i=0;i<n;i++) d[i]=Math.random()*2-1;
  const s=c.createBufferSource(); s.buffer=buf;
  const bp=c.createBiquadFilter(); bp.type='bandpass'; bp.frequency.value=freq; bp.Q.value=6;
  const g=c.createGain(); g.gain.setValueAtTime(amp,t0); g.gain.exponentialRampToValueAtTime(0.0001,t0+dur);
  s.connect(bp).connect(g).connect(c.destination); s.start(t0); s.stop(t0+dur);
}
function playDing(){
  try{
    // Duck the native BGM under the effect (fire-and-forget; ignore if server busy).
    fetch('/api/duck',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).catch(()=>{});
    const AC=window.AudioContext||window.webkitAudioContext; if(!AC) return;
    _actx=_actx||new AC(); if(_actx.state==='suspended') _actx.resume();
    const t=_actx.currentTime+0.01;
    _clack(_actx,t,1500,0.22,0.05);        // drawer clack
    _bell(_actx,t+0.05,1318.5,0.14,0.5);   // ching (E6)
    _bell(_actx,t+0.10,1760.0,0.12,0.6);   // ching (A6)
  }catch(e){}
}
function floatValue(row){
  const r=row.getBoundingClientRect();
  const v=document.createElement('div'); v.className='vfloat'; v.textContent='+'+VGAIN+'v';
  v.style.left=(r.left+58)+'px'; v.style.top=(r.top+4)+'px';
  document.body.appendChild(v);
  requestAnimationFrame(()=>requestAnimationFrame(()=>{ v.style.opacity='1'; v.style.transform='translateY(-34px)'; }));
  setTimeout(()=>{ v.style.opacity='0'; }, 650);
  setTimeout(()=>{ v.remove(); }, 1100);
}
function statBtn(g,val,label){ const on=(g.status||'backlog')===val;
  return '<button class="sb'+(on?(' on '+val):'')+'" onclick="setStatus(\''+g.id+'\',\''+val+'\',event)">'+label+'</button>'; }
// Leaf-goal status picker. Six statuses (대기·진행·응답 대기·중지·취소·완료) are too many for
// inline buttons, so a single combobox carries them. waiting is normally auto-set by the
// session hooks, but kept selectable for manual override. setStatus still routes 완료 through
// the celebration path. Parent goals use a derived rollup (statLabel), not this picker.
const STATUS_OPTS=[['backlog','대기'],['in_progress','진행'],['waiting','응답 대기'],['stopped','중지'],['cancelled','취소'],['done','완료']];
function statSel(g){
  const cur=g.status||'backlog';
  const opts=STATUS_OPTS.map(o=>'<option value="'+o[0]+'"'+(o[0]===cur?' selected':'')+'>'+o[1]+'</option>').join('');
  return '<select class="statsel '+cur+'" title="상태 변경" onchange="setStatus(\''+g.id+'\',this.value,event)">'+opts+'</select>';
}
// Children of a goal (1-level hierarchy: only top-level goals can be parents).
function goalKids(goals,g){ return (goals||[]).filter(c=>c.parent===g.id); }
// Derived parent status (rollup from children). null = leaf (use manual buttons).
//   on_track : at least one child is in_progress -> the big-picture goal is being worked on
//   done     : every child is done
//   backlog  : has children but none in progress yet
// Purpose: managers see which parent goal is active (on track) while workers freely
// manage the leaf tasks underneath. Derived every render, so a child going 진행
// flips the parent to on track automatically (no stored/duplicated state).
function derivedStatus(goals,g){
  const kids=goalKids(goals,g); if(!kids.length) return null;
  if(kids.some(c=>(c.status||'backlog')==='in_progress')) return 'on_track';
  if(kids.every(c=>(c.status||'backlog')==='done')) return 'done';
  return 'backlog';
}
function statLabel(s){ return s==='on_track'?'on track':(s==='done'?'완료':'대기'); }
function effTracked(g){ const base=g.trackedSeconds||0;
  return (g.startedAt&&g.startedAt>0)?(base+Math.max(0,(Date.now()/1000)-g.startedAt)):base; }
function fmtDur(sec){ sec=Math.max(0,Math.floor(sec)); const h=(sec/3600)|0,m=((sec%3600)/60)|0,s=sec%60,p=n=>(n<10?'0':'')+n;
  return (h>0?(h+':'+p(m)):m)+':'+p(s); }
// Live wait duration (seconds since waitingSince). DISPLAY-ONLY — never folded into
// effTracked, so the work clock stays frozen while this ticks up. 0 = not waiting.
function waitSecs(g){ return (g.waitingSince&&g.waitingSince>0)?Math.max(0,(Date.now()/1000)-g.waitingSince):0; }
function wbadgeHTML(g){ if((g.status||'')!=='waiting') return '';
  return '<span class="wbadge" id="tw_'+g.id+'" title="사람의 응답을 기다린 시간 — 작업 시간(왼쪽)에는 포함되지 않음">⏳ 응답 대기 '+fmtDur(waitSecs(g))+'</span>'; }
function tickTimers(){ (_goals||[]).forEach(g=>{
  const el=document.getElementById('tt_'+g.id); if(el) el.textContent=fmtDur(effTracked(g));
  const w=document.getElementById('tw_'+g.id); if(w) w.textContent='⏳ 응답 대기 '+fmtDur(waitSecs(g));
}); }
setInterval(tickTimers,1000);
// Set parent by typing the parent's number (1-based). Empty clears it.
let _goals=[];
// --- Drag-and-drop priority reorder (decide what to focus on) ---
let _dragFrom=null;
function dragStart(e,i){ _dragFrom=i; e.dataTransfer.effectAllowed='move'; try{e.dataTransfer.setData('text/plain',String(i));}catch(_){}
  const row=e.target.closest('.goal'); if(row)row.classList.add('dragging'); }
function dragEnd(e){ _dragFrom=null; document.querySelectorAll('.goal').forEach(el=>el.classList.remove('dragging','dropTarget')); }
function dragOver(e,i){ if(_dragFrom===null)return; e.preventDefault(); e.dataTransfer.dropEffect='move';
  if(i!==_dragFrom){ const row=e.currentTarget; if(row){document.querySelectorAll('.goal.dropTarget').forEach(el=>el.classList.remove('dropTarget')); row.classList.add('dropTarget');} } }
function dragLeave(e){ e.currentTarget.classList.remove('dropTarget'); }
function dropOn(e,i){ e.preventDefault();
  const from=_dragFrom; _dragFrom=null;
  document.querySelectorAll('.goal').forEach(el=>el.classList.remove('dragging','dropTarget'));
  if(from===null||from===i)return;
  const ids=_goals.map(g=>g.id);
  if(from<0||from>=ids.length)return;
  const moved=ids.splice(from,1)[0]; ids.splice(i,0,moved);
  post('/api/goal/reorder',{order:ids});
}
function setParentByNumber(id,numStr){
  const s=(numStr||'').trim();
  if(!s){ post('/api/goal/parent',{id:id,parent:''}); return; }
  const n=parseInt(s.replace(/[^0-9]/g,''),10);   // accept "goal-01", "01", or "1"
  const tgt=_goals.find(g=>g.seq===n)||null;   // match by stable seq, not position
  if(!tgt||tgt.id===id){ load(); return; }   // invalid -> revert display
  post('/api/goal/parent',{id:id,parent:tgt.id});
}
function num2(i){ return (i<9?'0':'')+(i+1); }
// Stable per-goal id label (goal-NN, seq zero-padded). Assigned at creation and
// UNCHANGED by reorder — drag only moves position, the label stays with the goal.
function gnum(g){ const n=g.seq||0; return 'goal-'+(n<10?'0':'')+n; }
// Session-link icon for a goal row. Connected -> bright chain that opens the readable
// transcript; not connected -> dim broken chain that opens the native connect picker.
function slinkBtn(g){
  if(g.sessionId){
    return '<button class="slink on" title="세션 트랜스크립트 보기" onclick="viewSession(event,\''+g.id+'\')">🔗</button>';
  }
  return '<button class="slink off" title="세션 연결 (파일 선택)" onclick="connectSession(event,\''+g.id+'\')">⛓️‍💥</button>';
}
function viewSession(e,id){ if(e){e.stopPropagation();} window.open('/transcript?goal='+encodeURIComponent(id),'_blank'); }
// The accumulated-time cell. For a session-linked goal it becomes a clickable link
// to the minute-by-minute breakdown (tools + tokens); otherwise it's a plain readout.
function ttimeHTML(g){
  const on=!!g.sessionId;
  const attr=on?(' onclick="viewBreakdown(event,\''+g.id+'\')" title="분 단위 작업·토큰 보기"'):' title="누적 작업 시간"';
  return '<span class="ttime'+(on?' clk':'')+'" id="tt_'+g.id+'"'+attr+'>'+fmtDur(effTracked(g))+'</span>';
}
function viewBreakdown(e,id){ if(e){e.stopPropagation();} window.open('/breakdown?goal='+encodeURIComponent(id),'_blank'); }
function connectSession(e,id){ if(e){e.stopPropagation();}
  // The picker is a native modal opened by the app; the POST returns immediately, so
  // reload a few times to catch the link once the user has chosen a file.
  post('/api/goal/connect',{id:id});
  [1500,4000,8000].forEach(function(ms){ setTimeout(load,ms); });
}
function submitSelf(){ post('/api/review',{selfScore:parseInt($('selfRange').value,10)||0}); }
function runAI(){ $('aiNote').textContent='분석 중…'; post('/api/aifilter',{}); }

let _view='input', _md='';
function pad2(n){ return (n<10?'0':'')+n; }
function setView(v){ _view=v; if(_review) fillActiveView(_review); applyView(); }
function applyView(){
  const inp=$('inputView'), pv=$('previewView'), gv=$('groupView'), sv=$('scheduleView');
  inp.style.display=(_view==='input')?'':'none';
  gv.style.display =(_view==='group')?'':'none';
  sv.style.display =(_view==='schedule')?'':'none';
  pv.style.display =(_view==='preview')?'':'none';
  const sel=$('viewSelect'); if(sel && sel.value!==_view) sel.value=_view;
}
// Fill ONLY the active view's input DOM. 목록/그룹 render the same goals with the same
// element ids (tt_<id>, ev_<id>) for live timers and evidence panels, so keeping both
// in the DOM at once would collide. We blank the inactive one and render the active one.
function fillActiveView(r){
  if(_view==='group'){ $('goals').innerHTML=''; $('scheduleSections').innerHTML=''; renderGroupSections(r); }
  else if(_view==='input'){ $('groupSections').innerHTML=''; $('scheduleSections').innerHTML=''; renderGoalsInput(r); }
  else if(_view==='schedule'){ $('goals').innerHTML=''; $('groupSections').innerHTML=''; renderSchedule(r); }
  else { $('goals').innerHTML=''; $('groupSections').innerHTML=''; $('scheduleSections').innerHTML=''; }   // preview: report only
}
// ===== Group-mode input: sticky add bar (active parent) + collapsible parent sections =====
let _activeParent='';        // active parent goal id ('' = new top-level)
let _gCollapsed=new Set();    // collapsed parent ids
let _gQuery='';              // section search filter (lowercased)
// IME-safe Enter binding (Korean composition; same rationale as goalKey). Reusable so
// the top add bar and every per-section add box commit only on a fully-composed Enter.
function bindImeEnter(el, fn){
  if(!el || el._imeBound) return; el._imeBound=true;
  let composing=false, pending=false;
  el.addEventListener('compositionstart',function(){composing=true;});
  el.addEventListener('compositionend',function(){composing=false; if(pending){pending=false; fn(el);}});
  el.addEventListener('keydown',function(e){ if(e.key!=='Enter')return; if(composing){pending=true;} else { fn(el); } });
}
// Resolve the active parent from the picker text ("goal-03", "03", "3", or empty).
function gPickParent(val){
  const s=(val||'').trim();
  if(!s){ _activeParent=''; return; }
  const n=parseInt(s.replace(/[^0-9]/g,''),10);
  const tgt=(_goals||[]).find(g=>g.seq===n && !g.parent);   // parent must be top-level
  _activeParent=tgt?tgt.id:'';
}
// Set the active parent from a section header (+여기에) and reflect it in the picker.
function gSetActiveParent(id){
  _activeParent=id||'';
  const g=(_goals||[]).find(x=>x.id===id);
  const el=$('gParentPick'); if(el) el.value=g?('goal-'+pad2(g.seq||0)):'';
}
function gAdd(){
  const el=$('gAddText'); if(!el) return;
  const t=el.value.trim(); if(!t) return;
  el.value=''; el.focus();
  post('/api/goal/add',{text:t,parent:_activeParent});
}
// Add a child directly under a parent (section add box). The section re-renders on
// reload (new input element), so we flag the parent to restore focus after render —
// enabling rapid Enter-Enter entry straight into a section.
let _gRefocus='';
function gAddChild(parentId, inputEl){
  const t=inputEl.value.trim(); if(!t) return;
  inputEl.value=''; _gRefocus=parentId;
  post('/api/goal/add',{text:t,parent:parentId});
}
function gSectAdd(parentId, btn){ const inp=btn.parentNode.querySelector('input'); if(inp) gAddChild(parentId,inp); }
function gToggleSec(id){ if(_gCollapsed.has(id))_gCollapsed.delete(id); else _gCollapsed.add(id);
  const el=document.getElementById('gsec_'+id); if(el) el.classList.toggle('collapsed', _gCollapsed.has(id)); }
function gCollapseAll(c){ const tops=(_goals||[]).filter(g=>!g.parent);
  _gCollapsed = c ? new Set(tops.map(g=>g.id)) : new Set();
  if(_review) renderGroupSections(_review); }
function gSetQuery(q){ _gQuery=(q||'').toLowerCase(); if(_review) renderGroupSections(_review); }
// One child row: same inline editors (status / note / evidence / delete) and element
// ids as the 목록 view, so timers + evidence panels work unchanged here too.
function gChildRow(g,r){
  return '<div class="gchild">'
    +'<span class="pill" style="font-variant-numeric:tabular-nums">'+gnum(g)+'</span>'
    +slinkBtn(g)
    +'<span class="gt" id="gt_'+g.id+'" title="더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span>'
    +'<span class="stat">'+statSel(g)+'</span>'
    +ttimeHTML(g)
    +noteBtn(g,r)
    +'<button class="btn evbtn'+(evCount(g)>0?' has':'')+'" onclick="toggleEv(\''+g.id+'\')" title="증거(링크·파일)">📎 '+evCount(g)+'</button>'
    +'<button class="btn" onclick="removeGoal(\''+g.id+'\')">삭제</button>'
    +notePanel(g,r)+evidencePanel(g)+'</div>';
}
function gSection(t,all,r){
  const kids=goalKids(all,t);
  const vkids=kids.filter(k=>goalPasses(k,all));   // filter for display; count stays full
  const done=kids.filter(k=>(k.status||'backlog')==='done').length;
  const ds=derivedStatus(all,t);
  const collapsed=_gCollapsed.has(t.id);
  const tag=ds==='on_track'?'<span class="otTag">on track</span>'
    :(ds==='done'?'<span class="otTag" style="border-color:var(--green);color:var(--green);background:rgba(54,192,138,.12)">완료</span>':'');
  const prog=kids.length?('자식 '+done+'/'+kids.length):'자식 없음';
  let body=vkids.length? vkids.map(k=>gChildRow(k,r)).join('')
    : '<div class="muted" style="font-size:12px;padding:4px 0">'
      +(kids.length?('필터로 가려진 자식 '+kids.length+'개'):'아직 자식이 없습니다. 아래에서 추가하세요.')+'</div>';
  body+='<div class="gsec-add">'
    +'<input type="text" data-parent="'+t.id+'" placeholder="이 목표 아래 추가 후 Enter" style="flex:1;min-width:120px">'
    +'<button class="btn" onclick="gSectAdd(\''+t.id+'\',this)">추가</button></div>';
  return '<div class="gsec'+(collapsed?' collapsed':'')+'" id="gsec_'+t.id+'">'
    +'<div class="gsec-hd" onclick="gToggleSec(\''+t.id+'\')">'
      +'<span class="tw">▾</span>'
      +'<span class="pill" style="font-variant-numeric:tabular-nums">'+gnum(t)+'</span>'
      +slinkBtn(t)
      +'<span class="gtitle">'+esc(t.text)+tag+'</span>'
      +'<span class="prog">'+prog+'</span>'
      +'<button class="btn" onclick="event.stopPropagation();gSetActiveParent(\''+t.id+'\')" title="상단 입력칸의 부모를 이 목표로 지정">+여기에</button>'
      +'<button class="btn" onclick="event.stopPropagation();removeGoal(\''+t.id+'\')">삭제</button>'
    +'</div><div class="gsec-body">'+body+'</div></div>';
}
function renderGroupSections(r){
  const all=(r&&r.goals)||[]; _goals=all;
  const host=$('groupSections'); if(!host) return;
  // Parent autocomplete = top-level goals only (1-level hierarchy).
  const dl=$('gParentList');
  if(dl) dl.innerHTML=all.filter(g=>!g.parent)
    .map(g=>'<option value="goal-'+pad2(g.seq)+'">goal-'+pad2(g.seq)+' · '+esc(g.text)+'</option>').join('');
  if(!all.length){ host.innerHTML='<div class="muted" style="padding:8px 0">목표가 없습니다. 위 입력칸에 추가하세요.</div>'; return; }
  updateFilterButtons();
  // Parent sections follow the shared filter too (디폴트는 상위도 필터; 상위 항상 표시 시 모두 노출).
  const tops=all.filter(g=>!g.parent && goalPasses(g,all));
  if(!tops.length){ host.innerHTML='<div class="muted" style="padding:8px 0">'+(anyStatusActive()?'해당 상태의 상위 목표가 없습니다.':'표시할 상태를 선택하세요 (대기 · 진행 · 완료).')+'</div>'; return; }
  const q=_gQuery;
  const vis=q? tops.filter(t=> t.text.toLowerCase().includes(q) || goalKids(all,t).some(k=>k.text.toLowerCase().includes(q))) : tops;
  if(!vis.length){ host.innerHTML='<div class="muted" style="padding:8px 0">검색 결과 없음: '+esc(_gQuery)+'</div>'; return; }
  host.innerHTML=vis.map(t=>gSection(t,all,r)).join('');
  applyEvOpen(); applyNoteOpen();
  host.querySelectorAll('.gsec-add input').forEach(el=>bindImeEnter(el,function(x){ gAddChild(x.dataset.parent,x); }));
  if(_gRefocus){ const el=host.querySelector('.gsec-add input[data-parent="'+_gRefocus+'"]'); _gRefocus=''; if(el) el.focus(); }
}
function copyMd(b){ if(navigator.clipboard) navigator.clipboard.writeText(_md); const o=b.textContent; b.textContent='복사됨'; setTimeout(()=>{b.textContent=o;},1200); }
function gnote(r,id){ return (r.notes&&r.notes[id])||''; }

// ===== 일정관리 (schedule / resource management) =====
// Every goal is dropped into an urgency bucket derived from its 목표(target) datetime, so
// the board reads "what's overdue / due today / this week / later". Completed goals collect
// in their own 완료 group (newest first) regardless of target. Each row carries inline
// target/완료 datetime pickers; editing one posts to the server and the 5s poll re-renders.
function startOfDay(epochSec){ const d=new Date(epochSec*1000); d.setHours(0,0,0,0); return d.getTime()/1000; }
// datetime-local needs "YYYY-MM-DDTHH:mm" in LOCAL time; 0/absent => empty field.
function localInput(epochSec){ if(!epochSec) return '';
  const d=new Date(epochSec*1000), p=n=>(n<10?'0':'')+n;
  return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+'T'+p(d.getHours())+':'+p(d.getMinutes()); }
function fmtDate(epochSec){ if(!epochSec) return '–'; const d=new Date(epochSec*1000), p=n=>(n<10?'0':'')+n;
  return (d.getMonth()+1)+'/'+d.getDate()+' '+p(d.getHours())+':'+p(d.getMinutes()); }
// datetime-local value -> epoch seconds (local tz); empty -> 0 (clears the field server-side).
function setTarget(id,val){ const v=val?Math.floor(new Date(val).getTime()/1000):0; post('/api/goal/target',{id:id,target:v}); }
function setCompleted(id,val){ const v=val?Math.floor(new Date(val).getTime()/1000):0; post('/api/goal/completed',{id:id,completed:v}); }
function ddayBadge(g){
  if((g.status||'backlog')==='done'){ const c=g.completedAt||0; return '<span class="dday done">✓ '+(c?fmtDate(c):'완료')+'</span>'; }
  const t=g.targetAt||0; if(!t) return '<span class="dday">미정</span>';
  const days=Math.round((startOfDay(t)-startOfDay(Date.now()/1000))/86400);
  if(days<0) return '<span class="dday over">D+'+(-days)+' 지남</span>';
  if(days===0) return '<span class="dday soon">D-DAY</span>';
  if(days<=3) return '<span class="dday soon">D-'+days+'</span>';
  return '<span class="dday">D-'+days+'</span>';
}
function schRow(g,r){
  const ds=derivedStatus(r.goals,g);
  const statCell=(ds!==null)?'<span class="ot '+ds+'" title="자식 태스크 상태에서 자동 계산">'+statLabel(ds)+'</span>':statSel(g);
  return '<div class="schrow">'
    +'<span class="pill" style="font-variant-numeric:tabular-nums">'+gnum(g)+'</span>'
    +slinkBtn(g)
    +'<span class="st"><span class="gt" id="gt_'+g.id+'" title="더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span></span>'
    +'<span>'+statCell+'</span>'
    +ddayBadge(g)
    +'<span class="dlab">목표</span><input type="datetime-local" value="'+localInput(g.targetAt)+'" onchange="setTarget(\''+g.id+'\',this.value)">'
    +'<span class="dlab">완료</span><input type="datetime-local" value="'+localInput(g.completedAt)+'" onchange="setCompleted(\''+g.id+'\',this.value)">'
    +noteBtn(g,r)
    +'<button class="btn evbtn'+(evCount(g)>0?' has':'')+'" onclick="toggleEv(\''+g.id+'\')" title="증거(링크·파일)">📎 '+evCount(g)+'</button>'
    +notePanel(g,r)+evidencePanel(g)+'</div>';
}
function schSection(cls,title,goals,r){
  return '<div class="schsec'+(cls?' '+cls:'')+'">'
    +'<div class="schsec-hd">'+esc(title)+'<span class="cnt">'+goals.length+'개</span></div>'
    +goals.map(g=>schRow(g,r)).join('')+'</div>';
}
function renderSchedule(r){
  const all=(r&&r.goals)||[]; _goals=all;
  const host=$('scheduleSections'); if(!host) return;
  // Unified status filter (목록·그룹·프리뷰와 동일): unchecking 완료 etc. hides those goals here too.
  const list=getFilteredGoals(all);
  if(!list.length){ host.innerHTML='<div class="muted" style="padding:8px 0">'+(anyStatusActive()?'해당 상태의 목표가 없습니다.':'표시할 상태를 선택하세요 (대기 · 진행 · 완료).')+'</div>'; return; }
  const sod=startOfDay(Date.now()/1000), eod=sod+86400, week=sod+7*86400;
  const G={over:[],today:[],week:[],later:[],none:[],done:[]};
  list.forEach(g=>{
    if((g.status||'backlog')==='done'){ G.done.push(g); return; }
    const t=g.targetAt||0;
    if(!t) G.none.push(g);
    else if(t<sod) G.over.push(g);
    else if(t<eod) G.today.push(g);
    else if(t<week) G.week.push(g);
    else G.later.push(g);
  });
  const byTarget=(a,b)=>((a.targetAt||0)-(b.targetAt||0))||((a.seq||0)-(b.seq||0));
  G.over.sort(byTarget); G.today.sort(byTarget); G.week.sort(byTarget); G.later.sort(byTarget);
  G.none.sort((a,b)=>(a.seq||0)-(b.seq||0));
  G.done.sort((a,b)=>(b.completedAt||0)-(a.completedAt||0));
  const secs=[
    ['overdue','지남 (기한 초과)',G.over],
    ['today','오늘',G.today],
    ['','이번 주',G.week],
    ['','예정',G.later],
    ['','미정 (목표일 없음)',G.none],
    ['done','완료',G.done],
  ];
  host.innerHTML=secs.filter(s=>s[2].length).map(s=>schSection(s[0],s[1],s[2],r)).join('');
  applyEvOpen(); applyNoteOpen();
}

let _lastReviewKey='';
function renderReview(d){
  const r=d.review||{goals:[],notes:{},submittedSelf:false,aiScore:null,selfScore:null};
  _review=r;   // keep latest review so the 완료 필터 can re-render rows on demand
  // confirmed value (always — no input fields here)
  const prov=provisionalHours(d.samples);
  $('provVal').textContent=prov.toFixed(1)+'h';
  let conf=0, status='';
  if(!r.submittedSelf) status='셀프 리뷰 대기 → 확정 0';
  else if(r.aiScore==null) status='AI 필터 대기 → 확정 0';
  else { conf=prov*((r.selfScore||0)/100)*((r.aiScore||0)/100); status='확정 (관리자 추후 반영)'; }
  $('confVal').textContent=conf.toFixed(2)+'h';
  $('confStatus').textContent=status;
  $('value').textContent=conf.toFixed(1)+'h';
  // report + markdown (read-only; safe to rebuild each tick)
  _md=buildMarkdown(d,r,conf,prov);
  _lastReportArgs={d:d,r:r,conf:conf,prov:prov};   // so reapplyFilter() can rebuild 프리뷰
  renderReport(d,r,conf,prov);
  // input-side DOM (has text fields) — rebuild only when review data changes,
  // so the 5s auto-refresh never wipes a note you're typing.
  const key=JSON.stringify(r);
  if(key!==_lastReviewKey){
    _lastReviewKey=key;
    fillActiveView(r);   // renders 목록 OR 그룹 (only the active one — see note above)
    renderStages(r);
  }
  applyView();
}
// Flat, numbered list (creation order). Parent set later via the 부모# field.
// The 완료만 filter narrows the rendered rows but keeps _goals as the full list so
// drag indices and the live timers stay correct.
function renderGoalsInput(r){
  const all=r.goals||[], gv=$('goals');
  _goals=all;
  updateFilterButtons();
  if(!all.length){ gv.innerHTML='<div class="muted" style="padding:4px 0">목표를 추가하세요. (Enter로 계속 추가)</div>'; return; }
  const list=getFilteredGoals(all);
  // 완료만 보기일 땐 첨부(증거) 패널을 펼쳐 자료 넘기기를 돕는다 (기존 동작 유지).
  const onlyDone=_statusFilter.done&&!_statusFilter.backlog&&!_statusFilter.in_progress;
  if(onlyDone) list.forEach(g=>_evOpen.add(g.id));
  if(!list.length){ gv.innerHTML='<div class="muted" style="padding:4px 0">'+(anyStatusActive()?'해당 상태의 목표가 없습니다.':'표시할 상태를 선택하세요 (대기 · 진행 · 완료).')+'</div>'; return; }
  const idToNum={}; all.forEach(g=>{ idToNum[g.id]=g.seq; });   // stable seq, not position
  gv.innerHTML=energyGauge(all)+list.map(g=>goalRow(g,all.indexOf(g),r,idToNum)).join('');
  applyEvOpen(); applyNoteOpen();
}
// Energy gauge: only meaningful once 2+ goals run at once (AI concurrency). Shows the
// summed allocation against the user's 100% cap; turns red and warns when over-committed.
function energyGauge(goals){
  const c=concCount(goals); if(c<CONC_ENERGY) return '';
  const sum=energySum(goals), over=sum>100, pct=Math.min(100,sum);
  return '<div class="engauge'+(over?' over':'')+'">'
    +'<div class="head"><span>동시 진행 '+c+'개 · 에너지 '+sum+'% / 100</span>'
    +'<span class="'+(over?'warn':'muted')+'">'+(over?'⚠ 에너지 초과 — 동시 작업 과부하':('남은 '+Math.max(0,100-sum)+'%'))+'</span></div>'
    +'<div class="bar"><div class="fill" style="width:'+pct+'%"></div></div></div>';
}
function goalRow(g,i,r,idToNum){
  const pnum=(g.parent&&idToNum[g.parent])?idToNum[g.parent]:'';
  const isChild=!!g.parent;
  // Parent goals show a derived rollup status (not manual buttons); leaves stay manual.
  const ds=derivedStatus(r.goals,g);
  const statCell=(ds!==null)
    ? '<span class="ot '+ds+'" title="자식 태스크 상태에서 자동 계산">'+statLabel(ds)+'</span>'
    : statSel(g);
  const running=(g.status==='in_progress')||(ds==='on_track');
  return '<div class="goal'+(ds==='on_track'?' ontrack':(running?' running':''))+'" data-i="'+i+'" ondragover="dragOver(event,'+i+')" ondrop="dropOn(event,'+i+')" ondragleave="dragLeave(event)">'
    +'<span class="grip" draggable="true" ondragstart="dragStart(event,'+i+')" ondragend="dragEnd(event)" title="드래그하여 우선순위 변경">⠿</span>'
    +'<span class="pill" style="font-variant-numeric:tabular-nums">'+gnum(g)+'</span>'
    +slinkBtn(g)
    +'<span class="g">'+(isChild?'<span class="muted">└ </span>':'')+'<span class="gt" id="gt_'+g.id+'" title="더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span></span>'
    +'<span class="stat">'+statCell+'</span>'
    +ttimeHTML(g)+wbadgeHTML(g)
    +'<span class="muted" style="font-size:12px">부모#</span>'
    +'<input type="text" inputmode="numeric" value="'+pnum+'" placeholder="–" title="부모 번호 입력 (비우면 최상위)" '
    +'onchange="setParentByNumber(\''+g.id+'\',this.value)" style="width:46px;text-align:center">'
    +noteBtn(g,r)
    +'<button class="btn evbtn'+(evCount(g)>0?' has':'')+'" onclick="toggleEv(\''+g.id+'\')" title="증거(링크·파일) 첨부·보기">📎 '+evCount(g)+'</button>'
    +'<button class="btn" onclick="removeGoal(\''+g.id+'\')">삭제</button>'
    +aiWorkRow(g,r)+notePanel(g,r)+evidencePanel(g)+'</div>';
}
// AI-work inputs on a PARENT goal (big-picture level), shown only while that parent is
// active (on_track). Energy and agent blocks gate independently on the active-parent count:
//   agents/tokens/value/ROI from CONC_AGENT (1 = a single active parent can name its agents),
//   energy from CONC_ENERGY (2 = two parents in parallel must split the 100% capacity).
function aiWorkRow(g,r){
  if(!activeParent(r.goals,g)) return '';
  const c=concCount(r.goals);
  const showEnergy=c>=CONC_ENERGY, showAgent=c>=CONC_AGENT;
  if(!showEnergy && !showAgent) return '';
  let h='<div class="aiwork">';
  if(showEnergy){
    h+='<span class="lab">에너지</span>'
      +'<input type="number" min="0" max="100" value="'+(g.energy||0)+'" onchange="setEnergy(\''+g.id+'\',this.value)">'
      +'<span class="lab">%</span>';
  }
  if(showAgent){
    const ag=(g.agents||[]).join(', ').replace(/"/g,'&quot;');
    const roi=roiOf(g), rc=roiClass(roi);
    const roiTxt=(roi==null)?'ROI –':('ROI '+roi.toFixed(2));
    h+='<span class="lab">에이전트</span>'
      +'<input type="text" class="agents" placeholder="agent1, agent2" value="'+ag+'" onchange="setAgents(\''+g.id+'\',this.value)">'
      +'<span class="lab">토큰</span>'
      +'<input type="number" min="0" value="'+(g.tokens||0)+'" onchange="setTokens(\''+g.id+'\',this.value)"><span class="lab">K</span>'
      +'<span class="lab">가치</span>'
      +'<input type="number" min="0" value="'+(g.value||0)+'" onchange="setValue(\''+g.id+'\',this.value)">'
      +'<span class="roi '+rc+'" title="가치 ÷ 토큰(K) — 동시 작업이 실제로 의미있는지">'+roiTxt+'</span>';
  }
  return h+'</div>';
}
function renderStages(r){
  if(r.submittedSelf){ $('st_self').innerHTML='<span class="ok">완료 '+(r.selfScore||0)+'%</span>'; $('selfRange').value=r.selfScore||0; $('selfVal').textContent=r.selfScore||0; }
  else $('st_self').innerHTML='<span class="wait">미제출</span>';
  if(r.aiScore!=null){ const cls=r.aiScore>=80?'ok':(r.aiScore>=50?'wait':'bad'); $('st_ai').innerHTML='<span class="'+cls+'">신뢰도 '+r.aiScore+'%</span>'; $('aiNote').textContent=r.aiNote||''; }
  else { $('st_ai').innerHTML='<span class="wait">대기</span>'; }
}
// Evidence rendered for the report (clickable, in-app) and markdown (portable text).
// In markdown, file rows show the name only — their /evidence URL is dashboard-local
// and won't resolve once the text is pasted elsewhere; links keep their full URL.
function evReportHtml(g){
  const ev=g.evidence||[]; if(!ev.length) return '';
  return '<div class="evrep">'+ev.map(e=>{
    const t=esc(e.title||e.href||''), icon=(e.kind==='file')?'📄 ':'🔗 ';
    return (e.kind==='file')
      ? '<a href="'+esc(e.href)+'" download>'+icon+t+'</a>'
      : '<a href="'+esc(e.href)+'" target="_blank" rel="noopener">'+icon+t+'</a>';
  }).join('')+'</div>';
}
function evMd(g){
  const ev=g.evidence||[]; if(!ev.length) return '';
  return ev.map(e=> '  - '+(e.kind==='file'?('📄 '+(e.title||'file')):('🔗 '+(e.title||e.href)+' '+e.href))).join('\n')+'\n';
}
function buildMarkdown(d,r,conf,prov){
  const goals=r.goals||[], tops=goals.filter(g=>!g.parent && goalPasses(g,goals));
  let md='# 오늘 리포트 ('+d.date+')\n\n- 확정 가치: '+conf.toFixed(2)+'h (잠정 '+prov.toFixed(1)+'h)\n\n';
  tops.forEach(t=>{
    const ds=derivedStatus(goals,t);
    md+='## '+t.text+(ds==='on_track'?' [on track]':(ds==='done'?' [완료]':''))+(gnote(r,t.id)?(' — '+gnote(r,t.id)):'')+'\n';
    md+=evMd(t);
    goals.filter(c=>c.parent===t.id && goalPasses(c,goals)).forEach(c=>{ const cs=(c.status||'backlog');
      const m=cs==='in_progress'?' (진행)':(cs==='done'?' (완료)':'');
      md+='- '+c.text+m+(gnote(r,c.id)?(' — '+gnote(r,c.id)):'')+'\n'; md+=evMd(c); });
    md+='\n';
  });
  return md;
}
function renderReport(d,r,conf,prov){
  const goals=r.goals||[], tops=goals.filter(g=>!g.parent && goalPasses(g,goals));
  let html='<div class="muted" style="margin-bottom:10px">'+esc(d.date)+' · 확정 '+conf.toFixed(2)+'h (잠정 '+prov.toFixed(1)+'h)</div>';
  if(!tops.length) html+='<div class="muted">'+(anyStatusActive()?'필터에 해당하는 목표가 없습니다.':'목표가 없습니다. 입력 뷰에서 추가하세요.')+'</div>';
  tops.forEach(t=>{
    const ds=derivedStatus(goals,t);
    const tag=ds==='on_track'?'<span class="otTag">on track</span>':(ds==='done'?'<span class="otTag" style="border-color:var(--green);color:var(--green);background:rgba(54,192,138,.12)">완료</span>':'');
    html+='<h3 style="margin:12px 0 4px">'+esc(t.text)+tag+'</h3>';
    if(gnote(r,t.id)) html+='<div class="muted" style="margin-bottom:4px">'+esc(gnote(r,t.id))+'</div>';
    html+=evReportHtml(t);
    const kids=goals.filter(c=>c.parent===t.id && goalPasses(c,goals));
    if(kids.length) html+='<ul>'+kids.map(c=>{ const cs=(c.status||'backlog');
      const m=cs==='in_progress'?' <span style="color:#9be3fb">(진행)</span>':(cs==='done'?' <span class="ok">(완료)</span>':'');
      return '<li>'+esc(c.text)+m+(gnote(r,c.id)?' <span class="muted">— '+esc(gnote(r,c.id))+'</span>':'')+evReportHtml(c)+'</li>'; }).join('')+'</ul>';
  });
  $('report').innerHTML=html;
}

function drawChart(samples){
  const c=$('chart'), dpr=window.devicePixelRatio||1, W=c.clientWidth, H=260;
  c.width=W*dpr; c.height=H*dpr; const g=c.getContext('2d'); g.setTransform(dpr,0,0,dpr,0,0); g.clearRect(0,0,W,H);
  const padL=44,padR=14,padT=14,padB=24, cw=W-padL-padR, ch=H-padT-padB;
  const maxRate=Math.max(1,...samples.map(s=>s.rate));
  const X=m=>padL+cw*(m/1440), Y=r=>padT+ch*(1-r/maxRate);
  g.strokeStyle='#232733'; g.fillStyle='#8b93a7'; g.lineWidth=1; g.font='11px system-ui';
  for(let h=0;h<=24;h+=3){ const px=X(h*60); g.beginPath(); g.moveTo(px,padT); g.lineTo(px,padT+ch); g.stroke(); g.fillText((h<10?'0':'')+h+':00',px-12,H-9); }
  if(!samples.length){ g.fillStyle='#8b93a7'; g.fillText('아직 활동 데이터가 없습니다. 작업을 시작하면 1분 뒤부터 쌓입니다.',padL,padT+ch/2); return; }
  g.fillStyle='rgba(54,192,138,0.22)'; const bw=Math.max(1,cw/1440);
  samples.forEach(s=>{ if(s.active>0) g.fillRect(X(minOfDay(s)),padT+ch-6,bw,6); });
  // total activity area
  g.beginPath(); samples.forEach((s,i)=>{const px=X(minOfDay(s)),py=Y(s.rate); i?g.lineTo(px,py):g.moveTo(px,py);});
  g.strokeStyle='#5b8cff'; g.lineWidth=2; g.stroke();
  g.lineTo(X(minOfDay(samples[samples.length-1])),padT+ch); g.lineTo(X(minOfDay(samples[0])),padT+ch); g.closePath();
  g.fillStyle='rgba(91,140,255,0.10)'; g.fill();
  // keyboard line
  g.beginPath(); samples.forEach((s,i)=>{const px=X(minOfDay(s)),py=Y(s.key||0); i?g.lineTo(px,py):g.moveTo(px,py);});
  g.strokeStyle='#36c08a'; g.lineWidth=1.5; g.stroke();
  // mouse line
  g.beginPath(); samples.forEach((s,i)=>{const px=X(minOfDay(s)),py=Y(s.mouse||0); i?g.lineTo(px,py):g.moveTo(px,py);});
  g.strokeStyle='#e8a13a'; g.lineWidth=1.5; g.stroke();
}

function drawStrip(samples){
  const c=$('strip'), dpr=window.devicePixelRatio||1, W=c.clientWidth, H=34;
  c.width=W*dpr; c.height=H*dpr; const g=c.getContext('2d'); g.setTransform(dpr,0,0,dpr,0,0); g.clearRect(0,0,W,H);
  const padL=44,padR=14, cw=W-padL-padR;
  g.fillStyle='#0d1016'; g.fillRect(padL,6,cw,20);
  const bw=Math.max(1.5,cw/1440);
  samples.forEach(s=>{ if(s.app && s.app!=='-'){ g.fillStyle=appColor(s.app); g.fillRect(padL+cw*(minOfDay(s)/1440),6,bw,20); } });
}

function appStats(samples){
  const apps={};
  samples.forEach(s=>{
    const a=s.app||'-'; if(a==='-') return;
    const e=apps[a]||(apps[a]={app:a,minutes:0,active:0,profiles:{},tracks:{}});
    e.minutes++; e.active+=(s.active||0);
    if(s.profile&&s.profile!=='-') e.profiles[s.profile]=(e.profiles[s.profile]||0)+1;
    if(s.track&&s.track!=='-') e.tracks[s.track]=(e.tracks[s.track]||0)+1;
  });
  return Object.values(apps).sort((x,y)=>y.minutes-x.minutes);
}

function renderApps(samples){
  const stats=appStats(samples);
  // bars
  const bars=$('appbars');
  if(!stats.length){ bars.innerHTML='<span class="empty">데이터 없음</span>'; }
  else {
    const max=Math.max(...stats.map(s=>s.minutes));
    bars.innerHTML=stats.map(s=>{
      const col=appColor(s.app), pct=Math.max(3,100*s.minutes/max);
      return '<div class="bar"><div class="name"><span class="dot" style="background:'+col+'"></span>'+esc(s.app)+'</div>'
        +'<div class="track"><div class="fill" style="width:'+pct+'%;background:'+col+'"></div></div>'
        +'<div class="val">'+fmtMin(s.minutes)+'</div></div>';
    }).join('');
  }
  // bgm debug table
  const rows=$('bgmrows');
  const withBgm=stats.filter(s=>Object.keys(s.tracks).length);
  if(!withBgm.length){ rows.innerHTML='<tr><td colspan="4" class="empty">아직 재생된 BGM 기록이 없습니다.</td></tr>'; return; }
  rows.innerHTML=withBgm.map(s=>{
    const col=appColor(s.app);
    const domProfile=Object.entries(s.profiles).sort((a,b)=>b[1]-a[1])[0];
    const profLabel=domProfile?domProfile[0]:'-';
    const band=BANDS[profLabel];
    const chips=Object.entries(s.tracks).sort((a,b)=>b[1]-a[1]).map(([t,n])=>{
      const bpm=trackBpm(t);
      const bad=band&&bpm!=null&&(bpm<band[0]||bpm>band[1]);
      return '<span class="chip'+(bad?' bad':'')+'">'+esc(t)+(n>1?' ×'+n:'')+'</span>';
    }).join('');
    return '<tr><td><span class="dot" style="background:'+col+'"></span>'+esc(s.app)+'</td>'
      +'<td>'+esc(profLabel)+'</td><td>'+chips+'</td><td>'+fmtMin(s.minutes)+'</td></tr>';
  }).join('');
}

// ===== Workers (background jobs) =====
// Shows every background worker, its schedule, and whether it's actually firing.
// The server sends agoSec/nextSec snapshots; we tick them locally each second so
// "마지막 실행" counts up and "다음 실행" counts down between 5s refreshes.
let _workers=[];          // last snapshot from the server
let _workersBase=0;       // performance.now() when the snapshot arrived (ms)
function fmtInterval(s){ if(s>=60&&s%60===0) return (s/60)+'분'; return s+'초'; }
function fmtAgo(sec){ if(sec<0) return '아직 없음';
  if(sec<60) return sec+'초 전'; const m=(sec/60)|0,s=sec%60; return m+'분 '+(s>0?s+'초 ':'')+'전'; }
function renderWorkers(arr){
  _workers=Array.isArray(arr)?arr:[];
  _workersBase=performance.now();
  const rows=$('workerrows');
  if(!_workers.length){ rows.innerHTML='<tr><td colspan="8" class="empty">데이터 없음</td></tr>'; return; }
  rows.innerHTML=_workers.map((w,i)=>{
    const badge=w.active?'<span class="chip">동작 중</span>':'<span class="chip bad">유휴</span>';
    const more=w.id?'<a class="btn" href="/worker?id='+encodeURIComponent(w.id)+'" target="_blank">자세히</a>':'';
    return '<tr><td><b>'+esc(w.name)+'</b></td>'
      +'<td class="muted">'+esc(w.detail)+'</td>'
      +'<td>'+fmtInterval(w.interval)+'</td>'
      +'<td id="wk_ago_'+i+'">'+fmtAgo(w.agoSec)+'</td>'
      +'<td id="wk_next_'+i+'">'+(w.active&&w.nextSec>=0?w.nextSec+'초 후':'–')+'</td>'
      +'<td>'+(w.runs||0).toLocaleString()+'</td>'
      +'<td>'+badge+'</td>'
      +'<td>'+more+'</td></tr>';
  }).join('');
}
// Live 1s tick: advance ago up / next down without waiting for the 5s reload.
function tickWorkers(){
  if(!_workers.length) return;
  const elapsed=Math.floor((performance.now()-_workersBase)/1000);
  _workers.forEach((w,i)=>{
    if(w.agoSec>=0){ const a=document.getElementById('wk_ago_'+i); if(a) a.textContent=fmtAgo(w.agoSec+elapsed); }
    if(w.active&&w.nextSec>=0){ const n=document.getElementById('wk_next_'+i);
      if(n) n.textContent=Math.max(0,w.nextSec-elapsed)+'초 후'; }
  });
}
setInterval(tickWorkers,1000);

load();
setInterval(load,5000);
setInterval(liveTick,100);
window.addEventListener('resize', load);

// ===== Pixel bard perched on the goal input =====
// Idle by default; plays a short "buff performance" (notes rise from a raised
// hand) once a minute. Same pixel data as the macOS menu-bar bard.
(function(){
  var cv=document.getElementById('bardCanvas'); if(!cv) return;
  var ctx=cv.getContext('2d'); ctx.imageSmoothingEnabled=false;
  var PAL={'.':null,o:'#2a2440',p:'#7b5cff',r:'#ff6b3d',s:'#ffd0a3',e:'#15101f',t:'#21c7b8',b:'#4a3b73',w:'#e0863a',m:'#ffd9a0',n:'#ffd84d'};
  var idle=["................",".......oo.......","......orro......","....oorppo......","...opppppo......","...opppppo......","...osssso.......","...oseseo.......","...osssso.......","....oooo........","...ottto........","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var cast1=["................",".......oo.......","......orro......","....oorppo......","...opppppo......","...opppppo......","...osssso....n..","...oseseo.......","...osssso..oso..","....oooo..osso..","...ottto.oso....","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var cast2=["................",".......oo.......","......orro......","....oorppo......","...opppppo...n..","...opppppo......","...osssso...n...","...oseseo.......","...osssso..oso..","....oooo..osso..","...ottto.oso....","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var cast3=["................",".......oo.......","......orro....n.","....oorppo...n..","...opppppo......","...opppppo...n..","...osssso.......","...oseseo.......","...osssso..oso..","....oooo..osso..","...ottto.oso....","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var cast4=["..............n.",".......oo.......","......orro......","....oorppo...n..","...opppppo......","...opppppo......","...osssso.......","...oseseo.......","...osssso..oso..","....oooo..osso..","...ottto.oso....","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var casts=[cast1,cast2,cast3,cast4], SC=3;
  function draw(g){ ctx.clearRect(0,0,48,48);
    for(var y=0;y<g.length;y++){ var row=g[y];
      for(var x=0;x<row.length;x++){ var c=PAL[row[x]]; if(!c) continue; ctx.fillStyle=c; ctx.fillRect(x*SC,y*SC,SC,SC); } } }
  var frameTimer=null;
  function playBuff(){ if(frameTimer) return;
    var start=Date.now(), i=0;
    frameTimer=setInterval(function(){
      if(Date.now()-start>=3500){ clearInterval(frameTimer); frameTimer=null; draw(idle); return; }
      draw(casts[i%4]); i++;
    },130);
  }
  draw(idle);
  playBuff();                 // play once on load as feedback
  setInterval(playBuff,60000); // then once a minute
})();
</script>
</body>
</html>
"""#
    }
}
