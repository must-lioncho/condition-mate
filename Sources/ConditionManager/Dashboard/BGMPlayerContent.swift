import Foundation

// Standalone player page served at GET /bgm-player and embedded by the dashboard's
// BGM view via <iframe>. iframe isolation keeps this page's Web Audio graph and its
// short DOM ids ($("wet"), $("status"), …) from colliding with the dashboard's.
//
// Two sub-tabs share one venue-effect engine (dry + convolution reverb with a
// synthesized IR, distance EQ, reverb send high-pass, sidechain ducking, M/S width):
//   • 액티비티 — mirrors the activity-driven BGM. Polls GET /api/bgm/now for whatever
//     ConditionDirector currently plays and streams that same file here, auto-switching
//     as the activity/condition changes. While the browser makes sound it POSTs
//     /api/bgm/native {mute:true} so the native AudioEngine is silenced (no double audio).
//   • 디버그 — manual library browser: pick any track (GET /api/bgm/list) and audition it
//     with the effect. Same graph, manual source.
// Audio is streamed same-origin from GET /bgm-audio/<id>, so createMediaElementSource and
// the offline .wav export both work without CORS taint.
enum BGMPlayerContent {
    static func html() -> String {
        return #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>컨디션 관리</title>
<style>
  :root{
    --bg:#0b0c10; --panel:#15171f; --panel2:#1c1f2a; --line:#2a2e3c;
    --txt:#e8eaf0; --dim:#9aa0b4; --accent:#7c5cff; --accent2:#00d4c8;
    --glow:0 0 40px rgba(124,92,255,.25);
  }
  *{box-sizing:border-box}
  body{
    margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Apple SD Gothic Neo","Noto Sans KR",sans-serif;
    background:radial-gradient(1200px 700px at 70% -10%, #201a3a 0%, var(--bg) 55%) fixed;
    color:var(--txt); min-height:100vh; padding:18px 16px 60px;
  }
  .wrap{max-width:820px; margin:0 auto}
  .head{display:flex; align-items:baseline; gap:12px; flex-wrap:wrap; margin-bottom:12px}
  h1{font-size:20px; margin:0; letter-spacing:.2px}
  .sub{color:var(--dim); font-size:13px}
  .card{
    background:linear-gradient(180deg,var(--panel),var(--panel2));
    border:1px solid var(--line); border-radius:18px; padding:18px; margin-top:16px;
    box-shadow:0 10px 40px rgba(0,0,0,.35);
  }
  /* sub-tabs */
  .subtabs{display:inline-flex; gap:4px; background:#12141c; border:1px solid var(--line); border-radius:12px; padding:4px}
  .subtab{border:none; background:none; color:var(--dim); font-size:13px; font-weight:600; padding:7px 16px; border-radius:9px; cursor:pointer; transition:.12s}
  .subtab:hover{color:var(--txt)}
  .subtab.on{background:linear-gradient(145deg,var(--accent),#5a3ff0); color:#fff; box-shadow:var(--glow)}
  /* activity status */
  .nowcard{display:flex; align-items:center; gap:16px; flex-wrap:wrap}
  .nowdot{width:10px;height:10px;border-radius:50%;background:#4b5163;flex:0 0 auto;transition:.2s}
  .nowdot.live{background:var(--accent2);box-shadow:0 0 12px var(--accent2)}
  .nowmain{flex:1 1 auto; min-width:0}
  .nowtitle{font-size:17px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .nowmeta{font-size:12px;color:var(--dim);margin-top:3px;display:flex;gap:14px;flex-wrap:wrap}
  .nowmeta b{color:var(--accent2);font-variant-numeric:tabular-nums;font-weight:600}
  .actnote{color:var(--dim);font-size:12px;margin-top:12px;line-height:1.6}
  .pdiv{height:1px;background:var(--line);margin:16px 0 4px}
  /* track library */
  .lbl{font-size:12px; text-transform:uppercase; letter-spacing:1.4px; color:var(--dim); margin:0 0 12px}
  .tracklist{max-height:230px; overflow:auto; display:flex; flex-direction:column; gap:4px}
  .tk{display:flex; align-items:center; gap:10px; padding:9px 11px; border-radius:11px; cursor:pointer;
      border:1px solid transparent; background:#12141c; transition:.12s}
  .tk:hover{border-color:#3a3f52}
  .tk.on{border-color:var(--accent); background:linear-gradient(160deg,#241d46,#171a24)}
  .tk .tkname{flex:1 1 auto; min-width:0; font-size:14px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis}
  .tk .tkbpm{flex:0 0 auto; font-size:11px; color:var(--dim); font-variant-numeric:tabular-nums;
             border:1px solid var(--line); border-radius:6px; padding:1px 7px}
  .tk.on .tkbpm{color:var(--accent2); border-color:var(--accent)}
  .tk .tkplay{flex:0 0 auto; color:var(--accent2); font-size:12px; visibility:hidden}
  .tk.on .tkplay{visibility:visible}
  .tkempty{color:var(--dim); font-size:13px; padding:10px 4px; line-height:1.6}
  /* play-time ranking */
  .ranklist{display:flex; flex-direction:column; gap:6px}
  .rk{display:flex; align-items:center; gap:11px; padding:9px 11px; border-radius:11px;
      background:#12141c; border:1px solid transparent; transition:.12s}
  .rk.on{border-color:var(--accent); background:linear-gradient(160deg,#241d46,#171a24)}
  .rk .rknum{flex:0 0 auto; width:20px; text-align:center; font-variant-numeric:tabular-nums;
             color:var(--dim); font-size:13px; font-weight:700}
  .rk.top .rknum{color:var(--accent2)}
  .rk .rkmain{flex:1 1 auto; min-width:0}
  .rk .rktitle{font-size:14px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis}
  .rk .rklive{color:var(--accent2); font-size:11px; margin-left:6px}
  .rk .rkbar{height:5px; border-radius:5px; margin-top:6px; min-width:3px;
             background:linear-gradient(90deg,var(--accent),var(--accent2))}
  .rk .rkmeta{flex:0 0 auto; text-align:right}
  .rk .rktime{font-size:13px; color:var(--txt); font-weight:600; font-variant-numeric:tabular-nums}
  .rk .rkplays{font-size:11px; color:var(--dim); margin-top:2px; font-variant-numeric:tabular-nums}
  /* BGM analytics tables (앱별 BGM · 타임라인 로그) */
  .tblwrap{overflow-x:auto}
  table{width:100%; border-collapse:collapse; font-size:13px}
  th,td{text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top}
  th{color:var(--dim); font-weight:600; font-size:12px; white-space:nowrap}
  tbody tr:last-child td{border-bottom:none}
  td.empty,.empty{color:var(--dim)}
  .muted{color:var(--dim)}
  .dot{display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:7px}
  .chip{display:inline-block; margin:2px; padding:2px 8px; border-radius:7px; font-size:11px;
        border:1px solid var(--line); color:var(--txt); background:#12141c; white-space:nowrap}
  .chip.bad{border-color:#e2667d; color:#ff9db0}
  .legend{color:var(--dim); font-size:11px; margin-top:10px; line-height:1.6}
  /* transport */
  .transport{display:flex; align-items:center; gap:16px}
  .play{
    position:relative;
    width:56px;height:56px;border-radius:50%;border:none;cursor:pointer;flex:0 0 auto;
    background:linear-gradient(145deg,var(--accent),#5a3ff0); color:#fff; box-shadow:var(--glow);
    font-size:22px; display:flex;align-items:center;justify-content:center; transition:transform .12s;
  }
  .play:active{transform:scale(.94)}
  .play:disabled{opacity:.5;cursor:default;box-shadow:none}
  /* pacemaker beat: the play button itself thumps at the target BPM while the challenge runs —
     one heartbeat + an expanding ring per --beat. Follows pace, not sound (beats even when muted). */
  .play .ring{position:absolute; inset:0; border-radius:50%; pointer-events:none; z-index:-1;
    background:radial-gradient(circle, rgba(124,92,255,.55), rgba(124,92,255,0) 70%);
    transform:scale(.85); opacity:0;}
  .play.beating{animation:playBeat var(--beat,1s) ease-in-out infinite}
  .play.beating .ring{animation:playRing var(--beat,1s) ease-out infinite}
  @keyframes playBeat{0%,100%{transform:scale(1)} 16%{transform:scale(1.13)} 38%{transform:scale(.99)}}
  @keyframes playRing{0%{transform:scale(.85);opacity:.6} 70%{opacity:0} 100%{transform:scale(1.85);opacity:0}}
  @media (prefers-reduced-motion:reduce){ .play.beating,.play.beating .ring{animation:none} }
  /* mute: silences the audio you hear while the challenge keeps running (mate stays with you). */
  .mute{
    width:40px;height:40px;border-radius:50%;flex:0 0 auto;cursor:pointer;
    border:1px solid var(--line); background:#161a24; color:var(--dim);
    font-size:16px; display:flex;align-items:center;justify-content:center; transition:.15s;
  }
  .mute:hover{color:#fff;border-color:var(--accent)}
  .mute.on{background:rgba(124,92,255,.14); border-color:var(--accent); color:var(--accent2)}
  .mute:active{transform:scale(.94)}
  .tinfo{flex:1 1 auto; min-width:0}
  .seekrow{display:flex; align-items:center; gap:10px}
  .time{font-variant-numeric:tabular-nums; font-size:12px; color:var(--dim); flex:0 0 auto; width:42px}
  .time.r{text-align:right}
  input[type=range]{
    -webkit-appearance:none; appearance:none; width:100%; height:6px; border-radius:6px;
    background:linear-gradient(90deg,var(--accent) 0%, var(--accent) var(--fill,0%), #333747 var(--fill,0%));
    outline:none; cursor:pointer;
  }
  input[type=range]::-webkit-slider-thumb{
    -webkit-appearance:none; width:16px;height:16px;border-radius:50%;
    background:#fff; box-shadow:0 0 0 4px rgba(124,92,255,.25); cursor:pointer;
  }
  .seek{margin-top:2px}
  .presets{display:grid; grid-template-columns:repeat(auto-fit,minmax(120px,1fr)); gap:10px}
  .preset{
    border:1px solid var(--line); background:#12141c; color:var(--txt); border-radius:14px;
    padding:14px 12px; cursor:pointer; text-align:left; transition:.15s; position:relative; overflow:hidden;
  }
  .preset:hover{border-color:#3a3f52; transform:translateY(-1px)}
  .preset.on{border-color:var(--accent); background:linear-gradient(160deg,#241d46,#171a24); box-shadow:var(--glow)}
  .preset .pn{font-size:15px; font-weight:600}
  .preset .pd{font-size:11px; color:var(--dim); margin-top:3px; line-height:1.4}
  .preset .em{font-size:20px}
  .grid{display:grid; grid-template-columns:1fr 1fr; gap:18px 26px; margin-top:4px}
  @media(max-width:560px){.grid{grid-template-columns:1fr}}
  .fld label{display:flex; justify-content:space-between; font-size:13px; margin-bottom:8px}
  .fld label .v{color:var(--accent2); font-variant-numeric:tabular-nums}
  .row{display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-top:4px}
  .btn{
    border:1px solid var(--line); background:#12141c; color:var(--txt); border-radius:11px;
    padding:9px 14px; cursor:pointer; font-size:13px; transition:.15s; display:inline-flex; gap:8px; align-items:center;
  }
  .btn:hover{border-color:#3a3f52}
  .btn.primary{background:linear-gradient(145deg,var(--accent2),#00a89e); color:#062b29; border:none; font-weight:600}
  .btn:disabled{opacity:.5; cursor:default}
  .foot{color:var(--dim); font-size:12px; margin-top:14px; line-height:1.6}
  .status{font-size:12px;color:var(--dim);margin-top:8px;min-height:16px}
  .toggle{margin-left:auto;display:flex;gap:6px;align-items:center;font-size:12px;color:var(--dim)}
  .switch{position:relative;width:40px;height:22px;border-radius:22px;background:#333747;cursor:pointer;transition:.15s;flex:0 0 auto}
  .switch.on{background:var(--accent)}
  .switch>i{position:absolute;top:2px;left:2px;width:18px;height:18px;border-radius:50%;background:#fff;transition:.15s}
  .switch.on>i{left:20px}
  /* 컨디션 맵 */
  .mapcards{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;margin:0 0 16px}
  .mapcards:empty{display:none}
  .mapcard{background:#12141c;border:1px solid var(--line);border-radius:12px;padding:10px 12px}
  .mapcard .k{font-size:11px;color:var(--dim)}
  .mapcard .v{font-size:18px;font-weight:700;margin-top:3px;font-variant-numeric:tabular-nums}
  .mapcard .c{font-size:11px;color:var(--dim);margin-top:2px}
  .maprow{margin:0 0 14px}
  .maprow .rl{display:flex;justify-content:space-between;align-items:baseline;gap:8px;font-size:12px;margin:0 0 4px}
  .maprow .rl b{font-weight:600}
  .maprow .rl .rr{color:var(--dim)}
  .mapband{position:relative;height:30px;border-radius:8px;overflow:hidden;background:#0e1017;border:1px solid var(--line);display:flex}
  .mapcell{height:100%;flex:1 1 0}
  .mapmark{position:absolute;top:0;bottom:0;width:2px;background:rgba(255,255,255,.28);pointer-events:none}
  .mapmark.now{background:var(--accent2);box-shadow:0 0 6px var(--accent2)}
  /* 목표(기준) 마커: 데이터 셀과 확실히 구분되도록 점선 + 결승 깃발 */
  .mapmark.goal{width:0;background:none;border-left:2px dashed #f5c451;z-index:2}
  .mapmark>span{position:absolute;top:-15px;left:50%;transform:translateX(-50%);font-size:9px;color:var(--dim);white-space:nowrap}
  .mapmark.now>span{color:var(--accent2)}
  .mapmark.goal>span{top:-17px;font-size:11px;color:#f5c451;font-weight:600}
  .mapaxis{position:relative;height:14px;margin-top:2px}
  .mapaxis span{position:absolute;top:0;font-size:9px;color:var(--dim);transform:translateX(-50%)}
  .maplegend{display:flex;gap:14px;flex-wrap:wrap;margin-top:6px;font-size:11px;color:var(--dim)}
  .maplegend span{display:inline-flex;align-items:center;gap:5px}
  .maplegend i{width:12px;height:12px;border-radius:3px;display:inline-block}
  /* 오늘 활동 블록 (대시보드에서 이동) — #todayBlocks 스코프로 target의 .card 와 충돌 방지 */
  #todayBlocks h2.tbh2{font-size:14px;margin:22px 0 10px;color:var(--txt)}
  #todayBlocks .cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:8px}
  #todayBlocks .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-top:0;box-shadow:none;flex:1;min-width:150px}
  #todayBlocks .card .k{color:var(--dim);font-size:12px}
  #todayBlocks .card .v{font-size:22px;font-weight:700;margin-top:4px}
  #todayBlocks .card .cap{color:var(--dim);font-size:11px;margin-top:3px}
  #todayBlocks .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px;margin-top:10px}
  #todayBlocks .panel.tierpanel{margin:10px 0 0}
  #todayBlocks #tiers{width:100%;display:block}
  #todayBlocks canvas{width:100%;display:block}
  #todayBlocks #chart{height:260px} #todayBlocks #strip{height:34px;margin-top:8px}
  #todayBlocks .nowline{color:var(--dim);font-size:13px;margin:10px 0 4px}
  #todayBlocks .nowline b{color:var(--txt);font-weight:600}
  #todayBlocks .bars{display:flex;flex-direction:column;gap:8px}
  #todayBlocks .bar{display:flex;align-items:center;gap:10px;font-size:13px}
  #todayBlocks .bar .name{width:160px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #todayBlocks .bar .track{flex:1;height:14px;border-radius:7px;background:#0d1f17;overflow:hidden}
  #todayBlocks .bar .fill{height:100%;border-radius:7px}
  #todayBlocks .bar .val{width:60px;text-align:right;color:var(--dim)}
  @media(max-width:560px){
    #todayBlocks .cards{gap:8px}
    #todayBlocks .card{min-width:calc(50% - 4px);flex:0 0 calc(50% - 4px)}
    #todayBlocks .bar .name{width:auto;max-width:38vw}
  }
</style>
</head>
<body>
<audio id="audio" preload="none" crossorigin="anonymous"></audio>
<div class="wrap">
  <div class="head">
    <!-- Back to the dashboard — replaces the old titlebar segmented toggle. Seamless native switch
         (openDashboard); the BGM webview keeps playing underneath the whole time. -->
    <button onclick="fetch('/api/window/mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:'dashboard'})}).catch(function(){});"
      title="대시보드로 돌아가기"
      style="display:inline-flex;align-items:center;gap:6px;background:#20283a;border:1px solid #2f3a54;color:#e7ecf4;border-radius:8px;padding:6px 12px;font-size:13px;font-weight:600;cursor:pointer;margin-bottom:12px">← 대시보드</button>
    <h1>컨디션 관리</h1>
    <span class="sub" id="nowsub">하루 컨디션 흐름을 맵으로 보고, 활동에 맞는 BGM으로 페이스를 관리 · 원곡은 그대로, 재생할 때만 공간감 이펙트</span>
  </div>

  <div class="subtabs" id="subtabs">
    <button class="subtab on" data-m="map" onclick="setMode('map')">컨디션맵</button>
    <button class="subtab" data-m="activity" onclick="setMode('activity')">액티비티</button>
    <button class="subtab" data-m="debug" onclick="setMode('debug')">디버그</button>
  </div>

  <!-- 컨디션맵: 업무 시작(8h 무활동 뒤 첫 활동)을 기준으로 24시간 컨디션 흐름을 가로 띠로 -->
  <div class="card" id="mapPanel" style="display:none">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:6px">
      <p class="lbl" style="margin:0">컨디션 맵 · 하루 컨디션 흐름</p>
      <button class="btn" id="mapReload" onclick="loadMap(true)">↻ 새로고침</button>
    </div>
    <p class="actnote" style="margin:0 0 12px">8시간 이상 활동이 없으면 <b>퇴근</b>으로 보고, 이후 첫 활동을 <b>업무 시작</b>으로 잡아 그 시점부터 24시간을 그립니다. 기준 시간(8·12·18h 또는 직접)에 맞춰 진행 상태를 관리하세요.</p>
    <div id="mapFilter" style="margin:0 0 10px"></div>
    <div class="cmf-row" style="margin:0 0 12px">
      <span style="font-size:12px;color:var(--dim)">기준</span>
      <button class="cmf-btn" data-base="8" onclick="setBase(8)">8시간</button>
      <button class="cmf-btn" data-base="12" onclick="setBase(12)">12시간</button>
      <button class="cmf-btn" data-base="18" onclick="setBase(18)">18시간</button>
      <input type="number" id="baseCustom" class="cmf-date" min="1" max="24" step="1" placeholder="직접" style="width:74px" oninput="setBaseCustom(this.value)">
      <span style="font-size:12px;color:var(--dim)">시간</span>
      <span id="mapTz" style="font-size:12px;color:var(--dim);margin-left:auto"></span>
    </div>
    <div id="mapSummary" class="mapcards"></div>
    <div id="mapBody"><div class="tkempty">불러오는 중…</div></div>
    <div class="maplegend" id="mapLegend"></div>

    <!-- 오늘 활동 분석 (대시보드에서 이동) — 컨디션맵과 같은 페이지에 모아 분석하기 쉽게 한다.
         모든 요소 id는 대시보드와 동일하게 유지해 렌더 함수를 그대로 재사용한다.
         .card 등 이름 충돌을 피하려고 #todayBlocks 스코프 아래 CSS를 별도로 둔다. -->
    <div id="todayBlocks">
      <h2 class="tbh2" style="margin:22px 0 10px">오늘 활동 (요약)</h2>
      <div class="cards" id="cards">
        <div class="card lead"><div class="k">토탈 시간</div><div class="v" id="t_total">–</div><div class="cap">업무 스팬 (휴식·미팅 포함)</div></div>
        <div class="card"><div class="k">책상 시간</div><div class="v" id="t_desk">–</div><div class="cap">만들기 시도 (리서치+코딩)</div></div>
        <div class="card"><div class="k">집중 시간</div><div class="v" id="t_focus">–</div><div class="cap">몰입 (에디터)</div></div>
        <div class="card"><div class="k">퇴근</div><div class="v" id="t_off">–</div><div class="cap">8시간+ 공백</div></div>
        <div class="card"><div class="k">오늘 가치 (확정)</div><div class="v" id="value">–</div><div class="cap">승인 전 = 0 (대시보드에서 확정)</div></div>
      </div>
      <div class="panel tierpanel" style="margin:6px 0;padding:12px 16px">
        <canvas id="tiers" style="height:18px"></canvas>
        <div class="legend">
          <span><span class="dot" style="background:#2a2f3a;border:1px solid #444"></span>토탈(회색=휴식·미팅)</span>
          <span><span class="dot" style="background:#e8a13a"></span>책상</span>
          <span><span class="dot" style="background:#36c08a"></span>집중</span>
          <span>· 누적 <b id="tierTotal">–</b></span>
          <span>· <span id="tierStatus">–</span></span>
        </div>
      </div>
      <div class="nowline" id="now">지금: –</div>

      <div class="panel" style="margin-bottom:6px"><div id="summary" class="empty">최근 요약 불러오는 중…</div></div>

      <div class="panel">
        <canvas id="chart"></canvas>
        <canvas id="strip"></canvas>
        <div class="legend">
          <span><span class="dot" style="background:var(--accent)"></span>전체 활동량</span>
          <span><span class="dot" style="background:#36c08a"></span>⌨ 키보드</span>
          <span><span class="dot" style="background:#e8a13a"></span>🖱 마우스</span>
          <span>아래 띠: 시간대별 주 활성 앱(색상)</span>
        </div>
      </div>

      <h2 class="tbh2">주요 앱 (오늘)</h2>
      <div class="panel"><div class="bars" id="appbars"><span class="empty">데이터 없음</span></div></div>
    </div>
  </div>

  <!-- 디버그: 라이브러리에서 곡을 골라 공간감 이펙트를 테스트 (음원 검증 전용) -->
  <div class="card" id="dbgPanel" style="display:none">
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:6px">
      <p class="lbl" style="margin:0">BGM 라이브러리 (음원 테스트)</p>
      <button class="btn" id="reload">↻ 새로고침</button>
    </div>
    <p class="actnote" style="margin:0 0 12px">곡을 골라 공간감을 입혔을 때 이상하지 않은지 확인하는 용도입니다. 여기 재생은 앱 BGM을 켜지 않습니다.</p>
    <div id="tracks" class="tracklist"><div class="tkempty">불러오는 중…</div></div>
  </div>

  <!-- 재생 카드 (shared). 액티비티에선 '지금 활동에 맞는 BGM' 상태가 이 카드 안에 합쳐진다. -->
  <div class="card" data-bgmcard>
    <div id="actStatus">
      <p class="lbl" style="margin:0 0 14px">지금 활동에 맞는 BGM</p>
      <div class="nowcard">
        <span class="nowdot" id="nowdot"></span>
        <div class="nowmain">
          <div class="nowtitle" id="nowTitle">대기 중 — 활동이 시작되면 곡이 잡힙니다</div>
          <div class="nowmeta">
            <span>국면 <b id="nowPhase">-</b></span>
            <span>목표 <b id="nowBpm">-</b> BPM</span>
            <span>전략 <b id="nowProfile">-</b></span>
          </div>
        </div>
      </div>
      <div class="actnote" style="margin-top:12px">
        디렉터가 활동 강도에 맞춰 고른 곡이 여기서 재생되고, 활동이 바뀌면 곡도 자동 전환됩니다.
        <b>재생</b>을 누르면 <b>챌린지가 함께 시작</b>되고(위젯 연동), 메이트의 BGM이 흐릅니다.
        소리가 필요 없을 땐 <b>음소거</b> — 챌린지는 계속 달리고 소리만 꺼집니다.
      </div>
      <div class="pdiv"></div>
    </div>
    <div class="transport">
      <!-- the play button itself is the pacemaker: it thumps at the target BPM while the challenge runs -->
      <button class="play" id="play" disabled><span class="ring"></span><span class="ico" id="playIco">▶</span></button>
      <button class="mute" id="mute" title="음소거 — 챌린지는 계속, 소리만 끕니다">🔊</button>
      <div class="tinfo">
        <div class="seekrow">
          <span class="time" id="cur">0:00</span>
          <input type="range" class="seek" id="seek" min="0" max="1000" value="0">
          <span class="time r" id="dur">0:00</span>
        </div>
      </div>
    </div>
    <div class="status" id="status">재생을 눌러 시작하세요.</div>
  </div>

  <!-- 재생 시간 순위 (shared): 각 곡이 실제로 얼마나 재생됐는지 -> 같은 곡이 도는지 확인/제어 -->
  <div class="card" data-bgmcard>
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:6px">
      <p class="lbl" style="margin:0">재생 시간 순위</p>
      <div style="display:flex;gap:8px">
        <button class="btn" id="statsReload">↻ 새로고침</button>
        <button class="btn" id="statsReset">초기화</button>
      </div>
    </div>
    <p class="actnote" style="margin:0 0 12px">디렉터가 고른 곡이 실제로 재생된 누적 시간입니다. 특정 곡만 길게 잡히면 여기서 바로 드러납니다.</p>
    <div id="statList" class="ranklist"><div class="tkempty">아직 재생 기록이 없습니다.</div></div>
  </div>

  <!-- 앱별 BGM (적절성 디버그): 대시보드에서 이동 — BGM 컨텍스트 통합 -->
  <div class="card" data-bgmcard>
    <p class="lbl" style="margin:0 0 6px">앱별 BGM (적절성 디버그)</p>
    <p class="actnote" style="margin:0 0 12px">앱마다 어떤 전략·트랙이 재생됐는지. 전략 밴드를 벗어난 트랙은 <span class="chip bad" style="margin:0">빨강</span>으로 표시(부적절 의심).</p>
    <div class="tblwrap">
      <table>
        <thead><tr><th>앱</th><th>주 전략</th><th>재생된 BGM 트랙 (BPM)</th><th>활성</th></tr></thead>
        <tbody id="bgmrows"><tr><td colspan="4" class="empty">불러오는 중…</td></tr></tbody>
      </table>
    </div>
  </div>

  <!-- 타임라인 로그 (분 단위 · 최신순): 대시보드에서 이동 — BGM 컨텍스트 통합 -->
  <div class="card" data-bgmcard>
    <p class="lbl" style="margin:0 0 12px">타임라인 로그 (분 단위 · 최신순)</p>
    <div class="tblwrap">
      <table>
        <thead><tr><th>시간</th><th>길이</th><th>앱 · 사이트</th><th>무드</th><th>BGM 트랙</th><th>활동 (⌨/🖱)</th><th>구분</th></tr></thead>
        <tbody id="logrows"><tr><td colspan="7" class="empty">불러오는 중…</td></tr></tbody>
      </table>
    </div>
  </div>

  <!-- presets (shared) -->
  <div class="card" data-bgmcard>
    <p class="lbl">공간 프리셋</p>
    <div class="presets" id="presets"></div>
  </div>

  <!-- fine control (shared) -->
  <div class="card" data-bgmcard>
    <div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;margin-bottom:16px">
      <p class="lbl" style="margin:0">세부 조절</p>
      <div style="display:flex;gap:18px;align-items:center">
        <div class="toggle">환경음 <div class="switch on" id="ambToggle"><i></i></div></div>
        <div class="toggle">이펙트 <div class="switch on" id="fxToggle"><i></i></div></div>
      </div>
    </div>
    <div class="grid">
      <div class="fld"><label>무대와의 거리 <span class="v" id="distV">20 m</span></label>
        <input type="range" id="dist" min="3" max="60" value="20"></div>
      <div class="fld"><label>리버브 (공간 잔향) <span class="v" id="wetV">42%</span></label>
        <input type="range" id="wet" min="0" max="100" value="42"></div>
      <div class="fld"><label>스테레오 폭 <span class="v" id="widV">130%</span></label>
        <input type="range" id="wid" min="0" max="200" value="130"></div>
      <div class="fld"><label>고음 감쇠 (공기 흡음) <span class="v" id="hcV">12.0 kHz</span></label>
        <input type="range" id="hc" min="2000" max="18000" value="12000"></div>
      <div class="fld"><label>저음 컷 <span class="v" id="lcV">40 Hz</span></label>
        <input type="range" id="lc" min="20" max="300" value="40"></div>
      <div class="fld"><label>리버브 저음 차단 <span class="v" id="shpV">190 Hz</span></label>
        <input type="range" id="shp" min="20" max="500" value="190"></div>
      <div class="fld"><label>리버브 더킹 (비트 펌핑 억제) <span class="v" id="duckV">50%</span></label>
        <input type="range" id="duck" min="0" max="100" value="50"></div>
      <div class="fld"><label>환경음 (관객·바람) <span class="v" id="ambV">45%</span></label>
        <input type="range" id="amb" min="0" max="100" value="45"></div>
      <div class="fld"><label>전체 볼륨 <span class="v" id="volV">100%</span></label>
        <input type="range" id="vol" min="0" max="130" value="100"></div>
    </div>
    <div class="row" style="margin-top:20px">
      <button class="btn primary" id="render" disabled>현재 곡을 이펙트 적용해 저장 (.wav)</button>
      <span class="status" id="rstatus" style="margin:0"></span>
    </div>
    <div class="foot">
      <b>환경음</b>은 프리셋에 맞춰 관객 웅성거림·바람·환호를 실시간으로 만들어 곡 아래에 깔아줍니다(공연장에 사람이 있는 느낌). 크기는 슬라이더로, 무대와 멀수록 더 크게 들립니다.
      "쿵딱" 공사장 소리가 들리면 <b>리버브 더킹</b>과 <b>리버브 저음 차단</b>을 올려보세요.
      모든 처리는 브라우저 안에서 실시간으로 이뤄지고, 원본 파일은 전혀 바뀌지 않습니다. (.wav 저장은 곡만 담기고 환경음은 빠집니다.)
    </div>
  </div>
</div>

<script>
\#(CMTimeFilter.js)
</script>
<script>
"use strict";
const $ = id => document.getElementById(id);
const audioEl = $("audio");

// ---------- preset definitions ----------
const PRESETS = {
  hall:{ name:"콘서트홀", em:"🎻", desc:"넓고 긴 잔향, 따뜻하고 자연스러운 울림", dist:18,
         rt60:2.2, damp:6500, pre:28, dur:2.8, wet:42, wid:130, hc:12000, lc:40, shp:190, duck:50,
         er:[{t:13,l:.5,r:.35},{t:19,l:.3,r:.45},{t:27,l:.4,r:.3},{t:37,l:.25,r:.32}],
         amb:{crowd:.16, wind:0, cheer:.05, room:.12} },
  club:{ name:"클럽 / 라이브하우스", em:"🎸", desc:"짧고 타이트한 잔향, 벽 반사·저음 부밍", dist:8,
         rt60:0.95, damp:4600, pre:11, dur:1.2, wet:32, wid:110, hc:14000, lc:28, shp:150, duck:60,
         er:[{t:7,l:.6,r:.5},{t:13,l:.45,r:.55},{t:21,l:.35,r:.3}],
         amb:{crowd:.36, wind:.04, cheer:.14, room:.16} },
  fest:{ name:"야외 페스티벌", em:"🎪", desc:"잔향은 적고 넓게, 먼 대형 PA·바람 느낌", dist:34,
         rt60:1.3, damp:5200, pre:46, dur:1.6, wet:26, wid:160, hc:9000, lc:55, shp:120, duck:40,
         er:[{t:33,l:.55,r:.2},{t:64,l:.2,r:.5}],
         amb:{crowd:.24, wind:.5, cheer:.13, room:.1} },
  arena:{name:"아레나 / 스타디움", em:"🏟️", desc:"매우 긴 잔향과 딜레이, 웅장한 대형 공간", dist:40,
         rt60:3.6, damp:5400, pre:42, dur:4.2, wet:50, wid:150, hc:10000, lc:45, shp:200, duck:55,
         er:[{t:23,l:.5,r:.3},{t:41,l:.3,r:.5},{t:73,l:.35,r:.25},{t:110,l:.25,r:.3}],
         amb:{crowd:.5, wind:.08, cheer:.2, room:.12} },
  dry:{  name:"원곡 (드라이)", em:"🎧", desc:"이펙트 없이 원본 그대로", dist:3,
         rt60:0.1, damp:18000, pre:0, dur:0.2, wet:0, wid:100, hc:18000, lc:20, shp:20, duck:0, er:[],
         amb:{crowd:0, wind:0, cheer:0, room:0} },
};
let current = "hall";
let fxEnabled = true;
let ambEnabled = true;

// ---------- mode (activity | debug) ----------
let mode = "activity";
let engaged = false;     // has the user pressed play once (Web Audio gesture unlock)?
let muted = false;       // output muted? challenge keeps running; only the sound is off
let TRACKS = [];
let curTrack = null;
let lastNow = null;

// THIRD AUDIO SOURCE GUARD: this same page is loaded in TWO places — (a) the app window's
// dedicated, persistent BGM webview (the single intended audio source, always top-level), and
// (b) the dashboard's own in-page "BGM 관리" tab, which lazy-loads this page a SECOND time inside
// an <iframe id="bgmFrame"> (see DashboardContent.swift). Both copies run this identical script
// with their own <audio> element, so if the embedded copy were allowed to autoplay it would be an
// independent, fully audible source overlapping the dedicated webview — the native-mute latch only
// silences the NATIVE AudioEngine, it has no effect on a second WKWebView/iframe's own audio.
// window.frameElement is non-null only when this document is embedded in an iframe (same-origin),
// so this reliably distinguishes copy (b) without any query-string/URL change needed.
const EMBEDDED = (function(){ try{ return window.frameElement !== null; }catch(e){ return false; } })();

function esc(s){ return (s||"").replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

function setMode(m){
  mode=m;
  [...document.querySelectorAll('.subtab')].forEach(b=>b.classList.toggle('on', b.dataset.m===m));
  $("mapPanel").style.display=(m==='map')?'':'none';
  $("actStatus").style.display=(m==='activity')?'':'none';   // 액티비티: 상태가 재생 카드에 합쳐진다
  $("dbgPanel").style.display=(m==='debug')?'':'none';
  // 컨디션맵 모드에선 BGM 재생/디버그 카드를 모두 숨겨 맵에 집중한다.
  document.querySelectorAll('[data-bgmcard]').forEach(el=>{ el.style.display=(m==='map')?'none':''; });
  if(m==='map'){ initMap(); if(typeof loadBGMAnalytics==='function') loadBGMAnalytics(); }  // 맵 탭 진입 시 오늘 활동 블록 즉시 갱신(캔버스 폭이 이제 유효)
  if(m==='debug'){
    if(!TRACKS.length) loadTracks();
    if(!curTrack || audioEl.paused) $("status").textContent="라이브러리에서 곡을 골라 공간감을 테스트하세요.";
  }
  if(m!=='debug') refreshNow();   // resume director-follow when returning to map/activity
  updatePlayIcon();
}

// ---------- native mute handshake (no double audio while the browser plays) ----------
// Deduped: only POST when the desired state actually changes, so the 1.5s poll can safely
// re-assert "unmute while idle" every tick without spamming, and a leaked mute self-heals.
let _muteState=null;
function nativeMute(m){
  // The embedded copy (dashboard's in-page BGM tab) never owns audio and must never touch the
  // native-mute latch — the dedicated top-level BGM webview (via AppWindowController) is the sole
  // owner while the app window is open. Letting the embedded copy call this too would just be
  // redundant traffic on the same latch it doesn't control (harmless but pointless); more
  // importantly it must not be trusted to unmute native, since its own <audio> may not even be
  // playing (see bgmAutoStart guard below) — see EMBEDDED guard above.
  if(EMBEDDED) return;
  m=!!m; if(_muteState===m) return; _muteState=m;
  try{ fetch("/api/bgm/native",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({mute:m})}); }catch(e){ _muteState=null; }
}
// ---------- remote control: turn the widget's BGM system on/off (dashboard <-> widget) ----------
function bgmControl(action){
  try{ fetch("/api/bgm/control",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action})}); }catch(e){}
}
// ---------- remote control: start/stop the CHALLENGE (work session) — play button doubles as
// 챌린지 시작/중단, so the dashboard and the menu-bar widget share one start/stop. The director
// only makes sound while a session is live, so starting the session is what actually plays. ----
function sessionControl(action){
  try{ fetch("/api/session/control",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({action})}); }catch(e){}
}
// ---------- canonical mute: report the user's mute intent to the app (single source of truth).
// Every surface posts here; the app syncs native output and other webviews reconcile via their poll.
function sessionMute(m){
  try{ fetch("/api/session/mute",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({muted:!!m})}); }catch(e){}
}
// The play button / seek follow the BROWSER transport — that is what actually makes sound here.
// The green dot + track title separately show the app BGM system is live, so ⏸ never shows while
// the browser is silent (no frozen-looking UI).
function isBGMPlaying(){ return !audioEl.paused; }
function updatePlayIcon(){ $("playIco").textContent = isBGMPlaying() ? "⏸" : "▶"; }

// ---------- pacemaker: the play button thumps at the target BPM. Driven by the /api/bgm/now poll,
// so it follows the challenge's pace — not the audio — and keeps beating even while muted. ----
function updateBeat(now){
  const p=$("play");
  const live = !!(now && now.working);          // the button beats whenever the challenge is live
  if(live){
    const bpm = (now.bpm>0) ? now.bpm : 100;    // warm-up before a target lands: gentle default
    p.style.setProperty("--beat", (60/bpm).toFixed(3)+"s");
  }
  p.classList.toggle("beating", live);
}

// ---------- shared: load a track (by {id,title,bpm}) and optionally start it ----------
function loadTrack(t, autoplay){
  if(!t || t.id<0) return;
  const same = curTrack && curTrack.id===t.id;
  curTrack=t;
  if(!same){ decoded=null; audioEl.src="/bgm-audio/"+t.id; }
  $("play").disabled=false; $("render").disabled=false;
  $("nowsub").textContent="곡 · "+t.title;
  renderTracks();
  if(autoplay){ engage(); audioEl.play().catch(()=>{}); }
}
function engage(){ engaged=true; ensureGraph(); if(ctx && ctx.state==="suspended") ctx.resume(); }

// Auto-start playback (with effect) as soon as we're allowed to make sound. Browsers block
// audio until a user gesture, so this runs on: the first click/keypress anywhere in the player,
// AND when the dashboard's BGM tab is clicked (the parent calls window.__bgmAutoStart within
// that gesture — same-origin, so activation carries). Also tries once on load in case autoplay
// is permitted. No-op once the browser is already playing or when not in activity mode.
// EMBEDDED (dashboard's in-page BGM tab / third-source guard): never auto-start here. The
// dedicated top-level BGM webview is the single continuous audio source while the app window is
// open; letting the embedded copy also play its own <audio> would be an independent, fully audible
// second source the native-mute latch cannot silence (that latch only reaches the native
// AudioEngine, not another webview/iframe). The embedded copy still mirrors 재생 상태 visually
// via refreshNow() — it's just muted from ever making its own sound automatically.
function bgmAutoStart(e){
  // Audio follows the SESSION (challenge) state, not the visible sub-tab: 컨디션맵/액티비티 are two
  // views of the same live session, so both auto-start + follow the director. Only 디버그 (manual
  // library audition) suppresses the automatic follow so it doesn't fight the user's manual pick.
  if(EMBEDDED || mode==='debug' || !audioEl.paused) return;
  // Skip clicks on interactive controls — the play button, sliders, tabs and track rows have
  // their own handlers, so auto-starting here would race them (e.g. start then instantly stop).
  if(e && e.target && e.target.closest && e.target.closest('button,input,a,.subtab,.preset,.tk,.switch')) return;
  if(lastNow && lastNow.id>=0){
    if(!curTrack){ curTrack={id:lastNow.id,title:lastNow.title,bpm:lastNow.bpm};
      audioEl.src="/bgm-audio/"+curTrack.id; decoded=null; $("render").disabled=false; renderTracks(); }
    engage(); audioEl.play().catch(()=>{});
  } else if(lastNow && lastNow.on){
    engage(); bgmControl('play');   // no track yet — engaged, so the poll plays it once ready
  }
}
function stopAutoStart(){ document.removeEventListener("pointerdown",bgmAutoStart,true); document.removeEventListener("keydown",bgmAutoStart,true); }
window.__bgmAutoStart = bgmAutoStart;
document.addEventListener("pointerdown", bgmAutoStart, true);
document.addEventListener("keydown", bgmAutoStart, true);

// ---------- activity: mirror + follow the widget's BGM (ConditionDirector) ----------
let _pollFails=0;
async function refreshNow(){
  let now=null;
  try{ const r=await fetch("/api/bgm/now"); now=await r.json(); }catch(e){}
  if(!now){
    // The app/server is unreachable. On loopback a failed fetch means the app is gone, so stop on
    // the FIRST miss (~1.5s) instead of waiting — otherwise a browser tab keeps playing buffered
    // audio with no app behind it ("위젯이 안 꺼짐").
    if(++_pollFails>=1){
      if(!audioEl.paused) audioEl.pause();
      curTrack=null; engaged=false;
      $("nowdot").classList.remove("live");
      $("nowTitle").textContent="앱 연결 끊김 — 앱이 종료되었습니다";
      $("status").textContent="앱이 꺼져 재생을 멈췄습니다. 앱을 다시 켜세요.";
      updatePlayIcon();
      updateBeat(null);
    }
    return;
  }
  _pollFails=0;
  lastNow=now;
  // Reconcile mute from the source of truth (session.isMuted, carried in the poll). Backstops any
  // surface that changed mute out-of-band (⌘M, dashboard mute dot) so the sound the user hears here
  // always matches the app's state within one poll (~1.5s).
  if(typeof now.muted==='boolean' && now.muted!==muted){ muted=now.muted; applyMute(); }
  updateBeat(now);
  // status card — the green dot follows `on` (system live), not `playing` (a track streaming),
  // so warm-up shows live rather than dead.
  $("nowdot").classList.toggle("live", !!now.on);
  $("nowPhase").textContent   = now.phase||"-";
  $("nowBpm").textContent     = (now.bpm>0)?now.bpm:"-";
  $("nowProfile").textContent = now.profile||"-";
  if(now.id>=0 && now.title){ $("nowTitle").textContent = now.title; }
  else if(now.on){ $("nowTitle").textContent = "BGM 준비 중…"; }
  else { $("nowTitle").textContent = "대기 중 — 활동이 시작되면 곡이 잡힙니다"; }

  // Director-follow runs on every tab EXCEPT 디버그 (manual audition). 컨디션맵 is the default
  // landing tab; without this the challenge would auto-start but the browser would never play,
  // leaving the window's audio owner silent (native is muted while the window is open).
  if(mode==='debug'){ updatePlayIcon(); return; }
  // Branch on `now.on` (director actually playing), NOT just on id: when the challenge stops the
  // app reports on:false but may still carry a stale track id (director.pauseSession keeps
  // audio.currentURL so a resume can continue the same track). Gating the follow branch on `on` is
  // what makes "챌린지 중단 -> 음원 중단" actually stop the sound (BGMACT-6).
  if(now.on && now.id>=0){
    // system engaged AND a real track available: follow the director's pick. Auto-switch once
    // engaged; before the first play gesture just cue it (native stays audible until user takes over).
    if(!curTrack || curTrack.id!==now.id){ loadTrack({id:now.id,title:now.title,bpm:now.bpm}, engaged); }
    if(engaged && audioEl.paused){ audioEl.play().catch(()=>{}); }
    $("status").textContent = engaged ? ("재생 중 · "+now.title) : ("앱 BGM 재생 중 · 눌러서 여기서 공간감으로 듣기");
  } else if(now.on){
    // system on but no resolvable track yet (warm-up / library reload) — DON'T reset `engaged`,
    // or a play we just started would be lost. Wait; the next poll loads the track.
    $("status").textContent = engaged ? "BGM 준비 중…" : "앱 BGM 준비 중 · ▶ 눌러 여기서 재생";
  } else {
    // system OFF: challenge stopped (or master BGM off) — director isn't playing, so silence it here.
    // Keep `engaged` intact so a restart auto-resumes with ZERO clicks (시나리오: 시작하면 다시 나온다):
    // drop only the current track, and the next on:true poll reloads + auto-plays it (loadTrack with
    // autoplay=engaged). Resetting engaged here would strand the restart needing a fresh gesture.
    if(!audioEl.paused){ audioEl.pause(); }
    curTrack=null;
    $("play").disabled=false;
    $("status").textContent = "BGM 꺼짐 · ▶ 누르면 앱 BGM을 켜고 여기서 재생";
    $("nowsub").textContent = "원곡은 그대로, 재생할 때만 공간감 이펙트 적용";
  }
  // Safety: while the browser transport is idle, native BGM should be audible — clears any
  // leaked mute (e.g. a debug audition that stopped without a pause event). Deduped, no spam.
  if(audioEl.paused) nativeMute(false);
  updatePlayIcon();
}
(function nowLoop(){ refreshNow(); setInterval(refreshNow, 1500); })();

// ---------- library (debug tab) ----------
async function loadTracks(){
  const host=$("tracks");
  host.innerHTML='<div class="tkempty">불러오는 중…</div>';
  try{ const r=await fetch("/api/bgm/list"); const j=await r.json(); TRACKS=j.tracks||[]; }catch(e){ TRACKS=[]; }
  if(!TRACKS.length){
    host.innerHTML='<div class="tkempty">BGM 라이브러리가 비어 있습니다.<br>메뉴바 설정에서 음악 폴더를 지정하면 여기에 곡이 나타납니다.</div>';
    return;
  }
  renderTracks();
}
function renderTracks(){
  const host=$("tracks"); if(!host) return;
  if(!TRACKS.length) return;
  host.innerHTML="";
  TRACKS.forEach(t=>{
    const on = curTrack && curTrack.id===t.id;
    const row=document.createElement("div");
    row.className="tk"+(on?" on":"");
    row.innerHTML='<span class="tkplay">▶</span><span class="tkname">'+esc(t.title)+'</span>'
                 +(t.bpm?'<span class="tkbpm">'+t.bpm+' BPM</span>':'');
    row.onclick=()=>loadTrack(t, true);
    host.appendChild(row);
  });
}

// ---------- Web Audio graph ----------
let ctx=null, srcNode=null;
let inGain, lowcut, highcut, dryGain, sendHP, sendHP2, preDelay, convolver, wetGain, masterGain;
let outMute;   // final output gain: 0 = muted (challenge keeps running, only the sound is off)
let scHP, scLP, scRect, scEnv, scShape, scDepth;
function absCurve(){ const n=1025, c=new Float32Array(n);
  for(let i=0;i<n;i++){ const x=(i/(n-1))*2-1; c[i]=Math.abs(x); } return c; }
function duckCurve(){ const n=1025, c=new Float32Array(n);
  for(let i=0;i<n;i++){ const x=(i/(n-1))*2-1; c[i]=x<=0?0:Math.min(1,14*x); } return c; }
let splitter, gMid, gSideL, gSideR, gSide, sideWidth, sideNeg, outL, outR, merger;

// ---------- ambience (procedural venue atmosphere: crowd / wind / cheer / room tone) ----------
// A separate synthesized bed mixed under the music so the space doesn't feel empty.
// Per-preset profile (PRESETS[k].amb) sets the mix; the 환경음 slider + distance scale the whole thing.
// Two output paths: ambDry -> master (enveloping), ambWet -> convolver (sits in the same room).
let ambBus, ambLevel, ambDry, ambWet;
let crowdSrc, crowdBP, crowdHP, crowdGain, crowdMod;
let windSrc, windLP, windGain, windMod;
let roomSrc, roomLP, roomGain;
let cheerSrc, cheerBP, cheerGain;
let ambLFOs = [];
let cheerTimer = null;
let cheerTarget = 0;

// A few seconds of decorrelated stereo pink noise, looped as the raw material for every layer.
function makeNoise(context, sec){
  const len = Math.floor(sec*context.sampleRate);
  const buf = context.createBuffer(2, len, context.sampleRate);
  for(let ch=0; ch<2; ch++){
    const d = buf.getChannelData(ch);
    let b0=0,b1=0,b2=0,b3=0,b4=0,b5=0,b6=0;
    for(let i=0;i<len;i++){
      const w = Math.random()*2-1;
      b0=0.99886*b0+w*0.0555179; b1=0.99332*b1+w*0.0750759; b2=0.96900*b2+w*0.1538520;
      b3=0.86650*b3+w*0.3104856; b4=0.55000*b4+w*0.5329522; b5=-0.7616*b5-w*0.0168980;
      d[i]=(b0+b1+b2+b3+b4+b5+b6+w*0.5362)*0.11;
      b6=w*0.115926;
    }
  }
  return buf;
}
// Slow, non-mechanical drift: two detuned sines summed into an AudioParam for organic swell/gusts.
// Returns setters so the per-preset code can rescale the swell (setDepth) and center (setBase).
function attachLFO(context, param, base, depth, f1, f2){
  const o1=context.createOscillator(); o1.frequency.value=f1;
  const o2=context.createOscillator(); o2.frequency.value=f2;
  const g1=context.createGain(); g1.gain.value=depth;
  const g2=context.createGain(); g2.gain.value=depth*0.5;
  param.value=base;
  o1.connect(g1); g1.connect(param);
  o2.connect(g2); g2.connect(param);
  o1.start(); o2.start();
  ambLFOs.push(o1,o2);
  return { setDepth:d=>{ g1.gain.value=d; g2.gain.value=d*0.5; }, setBase:b=>{ param.value=b; } };
}

function buildIR(context, p){
  const sr = context.sampleRate;
  const len = Math.max(1, Math.floor(p.dur*sr));
  const buf = context.createBuffer(2, len, sr);
  const pre = Math.floor(p.pre/1000*sr);
  const a = Math.exp(-2*Math.PI*Math.min(p.damp, sr/2-100)/sr);
  for(let ch=0; ch<2; ch++){
    const d = buf.getChannelData(ch);
    let lp = 0;
    for(let i=0;i<len;i++){
      if(i<pre){ d[i]=0; continue; }
      const t=(i-pre)/sr;
      const env=Math.pow(10, -3*t/p.rt60);
      const n=(Math.random()*2-1)*env;
      lp = (1-a)*n + a*lp;
      d[i]=lp;
    }
    (p.er||[]).forEach(er=>{
      const idx = pre + Math.floor(er.t/1000*sr);
      const amp = 0.5*(ch===0?er.l:er.r);
      for(let k=0;k<40;k++){ const j=idx+k; if(j<len) d[j]+=amp*Math.exp(-k/8); }
    });
  }
  let peak=1e-6;
  for(let ch=0;ch<2;ch++){const d=buf.getChannelData(ch);for(let i=0;i<len;i++)peak=Math.max(peak,Math.abs(d[i]));}
  const g=0.9/peak;
  for(let ch=0;ch<2;ch++){const d=buf.getChannelData(ch);for(let i=0;i<len;i++)d[i]*=g;}
  return buf;
}

function ensureGraph(){
  if(ctx) return;
  ctx = new (window.AudioContext||window.webkitAudioContext)();
  srcNode = ctx.createMediaElementSource(audioEl);

  inGain    = ctx.createGain();
  lowcut    = ctx.createBiquadFilter(); lowcut.type="highpass";
  highcut   = ctx.createBiquadFilter(); highcut.type="lowpass"; highcut.Q.value=0.4;
  dryGain   = ctx.createGain();
  sendHP    = ctx.createBiquadFilter(); sendHP.type="highpass"; sendHP.Q.value=0.5;
  sendHP2   = ctx.createBiquadFilter(); sendHP2.type="highpass"; sendHP2.Q.value=0.5;
  preDelay  = ctx.createDelay(1.0);
  convolver = ctx.createConvolver();
  wetGain   = ctx.createGain();
  masterGain= ctx.createGain();

  scHP   = ctx.createBiquadFilter(); scHP.type="highpass"; scHP.frequency.value=40;
  scLP   = ctx.createBiquadFilter(); scLP.type="lowpass";  scLP.frequency.value=140;
  scRect = ctx.createWaveShaper();   scRect.curve=absCurve();
  scEnv  = ctx.createBiquadFilter(); scEnv.type="lowpass";  scEnv.frequency.value=16;
  scShape= ctx.createWaveShaper();   scShape.curve=duckCurve();
  scDepth= ctx.createGain();         scDepth.gain.value=0;

  splitter=ctx.createChannelSplitter(2);
  gMid=ctx.createGain(); gMid.gain.value=0.5;
  gSideL=ctx.createGain(); gSideL.gain.value=0.5;
  gSideR=ctx.createGain(); gSideR.gain.value=-0.5;
  gSide=ctx.createGain(); gSide.gain.value=1;
  sideWidth=ctx.createGain(); sideWidth.gain.value=1.3;
  sideNeg=ctx.createGain(); sideNeg.gain.value=-1;
  outL=ctx.createGain(); outR=ctx.createGain();
  merger=ctx.createChannelMerger(2);

  srcNode.connect(inGain);
  inGain.connect(lowcut);
  lowcut.connect(highcut);
  highcut.connect(dryGain);
  highcut.connect(sendHP);
  sendHP.connect(sendHP2);
  sendHP2.connect(preDelay);
  preDelay.connect(convolver);
  convolver.connect(wetGain);

  inGain.connect(scHP);
  scHP.connect(scLP); scLP.connect(scRect); scRect.connect(scEnv);
  scEnv.connect(scShape); scShape.connect(scDepth);
  scDepth.connect(wetGain.gain);

  dryGain.connect(splitter);
  wetGain.connect(splitter);
  splitter.connect(gMid,0); splitter.connect(gMid,1);
  splitter.connect(gSideL,0); splitter.connect(gSideR,1);
  gSideL.connect(gSide); gSideR.connect(gSide);
  gSide.connect(sideWidth);
  gMid.connect(outL);   sideWidth.connect(outL);
  gMid.connect(outR);   sideWidth.connect(sideNeg); sideNeg.connect(outR);
  outL.connect(merger,0,0);
  outR.connect(merger,0,1);

  merger.connect(masterGain);
  // Final mute node before the speakers: muting silences the sound while the challenge (and the
  // beating play button) keep running. Honors a mute chosen before the graph existed.
  outMute = ctx.createGain(); outMute.gain.value = muted ? 0 : 1;
  masterGain.connect(outMute);
  outMute.connect(ctx.destination);

  buildAmbience();
  applyAll();
}

// Synthesize the ambience bed and splice it in parallel with the music.
function buildAmbience(){
  const noise = makeNoise(ctx, 4.0);
  const mkSrc = ()=>{ const s=ctx.createBufferSource(); s.buffer=noise; s.loop=true; return s; };

  ambBus   = ctx.createGain(); ambBus.gain.value=1;
  ambLevel = ctx.createGain(); ambLevel.gain.value=0;    // gated: 0 until playing
  ambDry   = ctx.createGain(); ambDry.gain.value=0.75;
  ambWet   = ctx.createGain(); ambWet.gain.value=0.55;

  // Crowd murmur: pink noise shaped to a vocal-ish band, slowly swelling.
  crowdSrc = mkSrc();
  crowdBP  = ctx.createBiquadFilter(); crowdBP.type="bandpass"; crowdBP.frequency.value=520; crowdBP.Q.value=0.8;
  crowdHP  = ctx.createBiquadFilter(); crowdHP.type="highpass"; crowdHP.frequency.value=180;
  crowdGain= ctx.createGain(); crowdGain.gain.value=0;
  crowdSrc.connect(crowdBP); crowdBP.connect(crowdHP); crowdHP.connect(crowdGain); crowdGain.connect(ambBus);
  crowdMod = attachLFO(ctx, crowdGain.gain, 0, 0, 0.07, 0.11);   // base+depth set per-preset

  // Wind: low-passed noise with a gusting cutoff and level.
  windSrc  = mkSrc();
  windLP   = ctx.createBiquadFilter(); windLP.type="lowpass"; windLP.frequency.value=520; windLP.Q.value=0.7;
  windGain = ctx.createGain(); windGain.gain.value=0;
  windSrc.connect(windLP); windLP.connect(windGain); windGain.connect(ambBus);
  attachLFO(ctx, windLP.frequency, 520, 260, 0.05, 0.13);        // cutoff gust (fixed)
  windMod  = attachLFO(ctx, windGain.gain, 0, 0, 0.08, 0.037);   // level gust, set per-preset

  // Room tone: quiet broadband air so total silence never happens.
  roomSrc  = mkSrc();
  roomLP   = ctx.createBiquadFilter(); roomLP.type="lowpass"; roomLP.frequency.value=1800;
  roomGain = ctx.createGain(); roomGain.gain.value=0;
  roomSrc.connect(roomLP); roomLP.connect(roomGain); roomGain.connect(ambBus);

  // Cheer/applause: brighter noise, silent until the scheduler pokes it.
  cheerSrc = mkSrc();
  cheerBP  = ctx.createBiquadFilter(); cheerBP.type="bandpass"; cheerBP.frequency.value=2400; cheerBP.Q.value=0.5;
  cheerGain= ctx.createGain(); cheerGain.gain.value=0;
  cheerSrc.connect(cheerBP); cheerBP.connect(cheerGain); cheerGain.connect(ambBus);

  ambBus.connect(ambLevel);
  ambLevel.connect(ambDry); ambDry.connect(masterGain);   // enveloping, obeys 전체 볼륨
  ambLevel.connect(ambWet); ambWet.connect(convolver);    // shares the room reverb

  crowdSrc.start(); windSrc.start(); roomSrc.start(); cheerSrc.start();
  scheduleCheer();
}

// Occasional cheer/applause swell. Recursive random timer; only fires while the preset
// wants cheers, ambience is on, and something is actually playing.
function scheduleCheer(){
  const wait = 8000 + Math.random()*15000;
  cheerTimer = setTimeout(()=>{
    if(ambEnabled && cheerTarget>0 && !audioEl.paused && Math.random()<0.65){
      const t=ctx.currentTime, peak=cheerTarget, tail=2.5+Math.random()*2.5;
      cheerGain.gain.cancelScheduledValues(t);
      cheerGain.gain.setValueAtTime(Math.max(0.0001,cheerGain.gain.value), t);
      cheerGain.gain.linearRampToValueAtTime(peak, t+0.45);
      cheerGain.gain.linearRampToValueAtTime(0, t+0.45+tail);
    }
    scheduleCheer();
  }, wait);
}

// Set the ambience mix from the current preset + slider + distance, and gate it to playback.
function applyAmbience(){
  if(!ctx || !ambBus) return;
  const a = PRESETS[current].amb || {crowd:0,wind:0,cheer:0,room:0};
  const ambPct = +$("amb").value/100;
  const dist = +$("dist").value;
  const distN = (dist-3)/(60-3);
  const master = ambEnabled ? ambPct*(0.6+distN*0.8) : 0;   // farther = more atmosphere

  const crowdBase = a.crowd*0.5;
  crowdMod.setBase(crowdBase); crowdMod.setDepth(crowdBase*0.6);
  const windBase = a.wind*0.32;
  windMod.setBase(windBase); windMod.setDepth(windBase*0.85);
  roomGain.gain.value = a.room*0.4;
  cheerTarget = a.cheer*0.5;

  const on = master>0 && !audioEl.paused;
  const t = ctx.currentTime;
  ambLevel.gain.cancelScheduledValues(t);
  ambLevel.gain.setTargetAtTime(on?master:0, t, 0.4);       // smooth fade in/out
}

function applyAll(){
  if(!ctx) return;
  const p = PRESETS[current];
  const dist = +$("dist").value;
  const wetPct = +$("wet").value/100;
  const widPct = +$("wid").value/100;
  const hcHz = +$("hc").value;
  const lcHz = +$("lc").value;
  const shpHz = +$("shp").value;
  const duckPct = +$("duck").value/100;
  const vol = +$("vol").value/100;

  const distN = (dist-3)/(60-3);
  const preSec = (p.pre + distN*40)/1000;
  const wetEff = fxEnabled ? Math.min(1, wetPct*(0.7+distN*0.9)) : 0;
  const hcEff  = fxEnabled ? Math.min(hcHz, hcHz*(1-distN*0.45)) : 20000;
  const dryEff = fxEnabled ? (1 - 0.25*distN) : 1;

  convolver.buffer = buildIR(ctx, p);
  preDelay.delayTime.value = Math.min(0.99, preSec);
  wetGain.gain.value = wetEff;
  dryGain.gain.value = dryEff;
  highcut.frequency.value = hcEff;
  lowcut.frequency.value = fxEnabled ? lcHz : 20;
  sendHP.frequency.value = fxEnabled ? shpHz : 20;
  sendHP2.frequency.value = fxEnabled ? shpHz : 20;
  scDepth.gain.value = fxEnabled ? -Math.min(duckPct, 0.95) * wetEff : 0;
  sideWidth.gain.value = fxEnabled ? widPct : 1;
  masterGain.gain.value = vol;
  applyAmbience();
}

// ---------- UI wiring ----------
const STORE_KEY = "cm.bgm.state";       // remembers preset + custom + level sliders across reloads
// Sliders that DEFINE the spatial character. Touching any of these forks to 커스텀 so the
// built-in presets always keep their curated quality (never silently overwritten).
const CHAR_SLIDERS = ["dist","wet","wid","hc","lc","shp","duck"];
// Level sliders that are global user prefs (not part of a venue preset) — they never fork.
const LEVEL_SLIDERS = ["amb","vol"];

// Push a preset's characteristic slider values into the controls (no save / no apply).
function setPresetControls(k){
  const p=PRESETS[k];
  $("wet").value=p.wet; $("wid").value=p.wid; $("hc").value=p.hc; $("lc").value=p.lc; $("shp").value=p.shp; $("duck").value=p.duck;
  if(p.dist!=null){ $("dist").value=p.dist; }
}
function pickPreset(k){
  current=k;
  setPresetControls(k);
  syncLabels(); renderPresets(); applyAll(); saveState();
}
// Fork to (or refresh) the 커스텀 preset: snapshot the reverb IR + ambience profile from the
// current preset, then take the character sliders live. Built-in presets stay untouched.
function toCustom(){
  const base = (current==="custom" && PRESETS.custom) ? PRESETS.custom : (PRESETS[current]||PRESETS.hall);
  PRESETS.custom = { name:"커스텀", em:"🎛️", desc:"직접 조절한 나만의 설정",
    rt60:base.rt60, damp:base.damp, pre:base.pre, dur:base.dur, er:base.er, amb:base.amb,
    dist:+$("dist").value, wet:+$("wet").value, wid:+$("wid").value,
    hc:+$("hc").value, lc:+$("lc").value, shp:+$("shp").value, duck:+$("duck").value };
  if(current!=="custom"){ current="custom"; renderPresets(); }
}
function renderPresets(){
  const host = $("presets"); host.innerHTML="";
  Object.entries(PRESETS).forEach(([k,p])=>{
    const b=document.createElement("button");
    b.className="preset"+(k===current?" on":"");
    b.dataset.k=k;
    b.innerHTML='<div class="em">'+p.em+'</div><div class="pn">'+p.name+'</div><div class="pd">'+p.desc+'</div>';
    b.onclick=()=>pickPreset(k);
    host.appendChild(b);
  });
}
function saveState(){
  try{ localStorage.setItem(STORE_KEY, JSON.stringify({
    preset: current,
    custom: PRESETS.custom || null,
    level: { amb:+$("amb").value, vol:+$("vol").value }
  })); }catch(e){}
}
function fmt(s){ s=Math.max(0,s|0); return (s/60|0)+":"+String(s%60).padStart(2,"0"); }
function syncLabels(){
  $("distV").textContent = $("dist").value+" m";
  $("wetV").textContent  = $("wet").value+"%";
  $("widV").textContent  = $("wid").value+"%";
  $("hcV").textContent   = ($("hc").value/1000).toFixed(1)+" kHz";
  $("lcV").textContent   = $("lc").value+" Hz";
  $("shpV").textContent  = $("shp").value+" Hz";
  $("duckV").textContent = $("duck").value+"%";
  $("ambV").textContent  = $("amb").value+"%";
  $("volV").textContent  = $("vol").value+"%";
  ["dist","wet","wid","hc","lc","shp","duck","amb","vol","seek"].forEach(id=>{
    const el=$(id); const pct=(el.value-el.min)/(el.max-el.min)*100;
    el.style.setProperty("--fill", pct+"%");
  });
}
[...CHAR_SLIDERS, ...LEVEL_SLIDERS].forEach(id=>{
  $(id).addEventListener("input",()=>{
    if(CHAR_SLIDERS.includes(id)) toCustom();   // editing the character forks to 커스텀
    syncLabels(); applyAll(); saveState();
  });
});
$("fxToggle").onclick=()=>{
  fxEnabled=!fxEnabled;
  $("fxToggle").classList.toggle("on",fxEnabled);
  applyAll();
};
$("ambToggle").onclick=()=>{
  ambEnabled=!ambEnabled;
  $("ambToggle").classList.toggle("on",ambEnabled);
  applyAmbience();
};
$("reload").onclick=loadTracks;

// ---------- play-time ranking ----------
function fmtDur(s){
  s=Math.max(0,Math.round(s));
  const h=Math.floor(s/3600), m=Math.floor((s%3600)/60), ss=s%60;
  if(h>0) return h+"시간 "+m+"분";
  if(m>0) return m+"분 "+ss+"초";
  return ss+"초";
}
async function loadStats(){
  const host=$("statList"); if(!host) return;
  let j=null;
  try{ const r=await fetch("/api/bgm/stats"); j=await r.json(); }catch(e){}
  if(!j || !j.tracks || !j.tracks.length){
    host.innerHTML='<div class="tkempty">아직 재생 기록이 없습니다.<br>BGM이 재생되면 곡별 누적 재생 시간이 여기에 쌓입니다.</div>';
    return;
  }
  const max=Math.max(1, j.tracks[0].seconds);
  host.innerHTML="";
  j.tracks.forEach((t,i)=>{
    const row=document.createElement("div");
    row.className="rk"+(t.current?" on":"")+(i<3?" top":"");
    const pct=Math.max(3, t.seconds/max*100);
    row.innerHTML='<span class="rknum">'+(i+1)+'</span>'
      +'<div class="rkmain"><div class="rktitle">'+esc(t.title)
        +(t.current?'<span class="rklive">● 재생 중</span>':'')+'</div>'
      +'<div class="rkbar" style="width:'+pct+'%"></div></div>'
      +'<div class="rkmeta"><div class="rktime">'+fmtDur(t.seconds)+'</div>'
      +'<div class="rkplays">'+t.plays+'회'+(t.bpm?' · '+t.bpm+'BPM':'')+'</div></div>';
    host.appendChild(row);
  });
}
$("statsReload").onclick=loadStats;
$("statsReset").onclick=()=>{
  if(!confirm("곡별 재생 시간 기록을 모두 초기화할까요?")) return;
  fetch("/api/bgm/stats/reset",{method:"POST"}).then(()=>loadStats()).catch(()=>{});
};
loadStats();
setInterval(loadStats, 5000);

// ---------- BGM analytics (앱별 BGM · 타임라인 로그) — moved from the dashboard so all
// BGM context lives on one page. Both render from /data.json (same-origin loopback). ----------
const PALETTE=['#5b8cff','#36c08a','#e8a13a','#c879e6','#e2667d','#3ac6c6','#d98c5f','#9aa4b2'];
const colorCache={};
function appColor(a){ if(colorCache[a]) return colorCache[a];
  let h=0; for(const c of a) h=(h*31+c.charCodeAt(0))>>>0;
  const col=PALETTE[h%PALETTE.length]; colorCache[a]=col; return col; }
// strategy label -> [minBPM, maxBPM]; a track outside its app's band is flagged bad.
const BANDS={'칠 (느긋)':[75,100],'스테디 (안정)':[100,125],'집중 (몰입)':[120,150],'하이프 (고조)':[140,175]};
function trackBpm(t){ const m=/\[(\d{2,3})\]/.exec(t||''); return m?parseInt(m[1],10):null; }
function fmtMin(m){ if(m>=60) return (m/60).toFixed(1)+'시간'; return m+'분'; }
function hhmm(t){ const d=new Date(t*1000); return ('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2); }
function categoryBadge(seg){ let label,color;
  if(seg.meeting){label='미팅';color='#9aa4b2';}
  else if(seg.tier==='적극'){label='집중';color='#36c08a';}
  else if(seg.tier==='중간'){label='책상';color='#e8a13a';}
  else {label='휴식';color='#9aa4b2';}
  return '<span class="chip" style="margin:0;border-color:'+color+';color:'+color+'">'+label+' ×'+(seg.mult||1)+'</span>'; }

// 10-min continuity: a rest gap <= 10min bridged by work on BOTH sides is absorbed into
// the surrounding work (identical to the dashboard's carry-forward, kept in sync).
const TENMIN=10*60;
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
    const a=work[k], b=work[k+1];
    if(ss[b].t-ss[a].t<=TENMIN){
      const bridgeFocus=(ss[a]._cat==='focus' && ss[b]._cat==='focus');
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
// Merge consecutive minutes sharing app+site+mood+track into one timeline segment.
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
// Lazy timeline: keep all segments but only paint an initial slice; "불러오기" reveals more.
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
  const siteRow=(g.site&&g.site!=='-')?'<div style="color:var(--dim);font-size:11px">'+esc(g.site)+'</div>':'';
  const k=Math.round(g.keySum/g.mins), mo=Math.round(g.mouseSum/g.mins);
  return '<tr>'
    +'<td style="white-space:nowrap">'+hhmm(g.startT)+'</td>'
    +'<td style="white-space:nowrap;color:var(--dim)">'+g.mins+'분</td>'
    +'<td style="white-space:nowrap"><span class="dot" style="background:'+col+'"></span>'+esc(g.app)+siteRow+'</td>'
    +'<td style="white-space:nowrap">'+esc(g.profile)+'</td>'
    +'<td>'+trackCell+'</td>'
    +'<td style="white-space:nowrap;color:var(--dim)">⌨'+k+' 🖱'+mo+'</td>'
    +'<td>'+categoryBadge(g)+'</td>'
    +'</tr>';
}
function paintTimeline(){
  const rows=$("logrows"); if(!rows) return;
  const total=_logSegs.length;
  if(!total){ rows.innerHTML='<tr><td colspan="7" class="empty">데이터 없음</td></tr>'; return; }
  const shown=Math.min(_logShown,total);
  let html=_logSegs.slice(0,shown).map(rowHtml).join('');
  if(shown<total){
    const next=Math.min(LOG_STEP,total-shown);
    html+='<tr><td colspan="7" style="text-align:center;padding:10px">'
      +'<button class="btn" onclick="loadMoreLog()">불러오기 (+'+next+')</button>'
      +' <span class="muted" style="font-size:11px">전체 '+total+'개 중 '+shown+'개 표시</span></td></tr>';
  }
  rows.innerHTML=html;
}
function loadMoreLog(){ _logShown=Math.min(_logShown+LOG_STEP,LOG_MAX,_logSegs.length); paintTimeline(); }
window.loadMoreLog=loadMoreLog;
function renderTimeline(samples){
  _logSegs=timelineSegments(samples).reverse().slice(0,LOG_MAX);
  _logShown=Math.max(LOG_INIT,Math.min(_logShown,_logSegs.length));
  paintTimeline();
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
function renderBgmTable(samples){
  const rows=$("bgmrows"); if(!rows) return;
  const withBgm=appStats(samples).filter(s=>Object.keys(s.tracks).length);
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
// ===== 오늘 활동 블록 (대시보드에서 이동) =====
// appColor / appStats / withCarryForward / fmtMin / esc / $ 는 이미 이 페이지에 있으므로
// 중복 정의하지 않는다. 아래는 대시보드에만 있던 렌더러와 그 헬퍼를 그대로 옮긴 것.
function minOfDay(s){ const dt=new Date(s.t*1000); return dt.getHours()*60+dt.getMinutes(); }
function fmtH(min){ const h=Math.floor(min/60), m=min%60; return h>0? h+'시간 '+m+'분' : m+'분'; }
// Provisional value hours (weighted active time) — same formula as the dashboard.
function provisionalHours(samples){ return samples.reduce((a,s)=>a+(s.active||0)*(s.mult||1),0)/3600; }
// Time buckets (operates on carry-forward samples; each = 1 minute).
// Span anchors separated by < 8h = one work span; >= 8h gaps are 퇴근.
function timeBuckets(ss){
  const OFFGAP=8*3600;
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
      if(gap < OFFGAP) total += gap/60; // rest/meeting within span -> total
      else off += gap/60;               // >=8h gap -> 퇴근
    }
  }
  return {total:Math.round(total), desk, focus, off:Math.round(off)};
}
function drawTiers(b){
  const c=$('tiers'); if(!c) return;
  const dpr=window.devicePixelRatio||1,W=c.clientWidth,H=18;
  c.width=W*dpr;c.height=H*dpr;const g=c.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W,H);
  const max=Math.max(b.total,1), bw=v=>W*(v/max);
  g.fillStyle='#2a2f3a'; g.fillRect(0,2,bw(b.total),14);  // total
  g.fillStyle='#e8a13a'; g.fillRect(0,2,bw(b.desk),14);   // desk (nested)
  g.fillStyle='#36c08a'; g.fillRect(0,2,bw(b.focus),14);  // focus (nested)
}
function tierColor(t){ return t==='적극'?'#36c08a':t==='중간'?'#e8a13a':'#9aa4b2'; }
function tierBadge(t,m){ const c=tierColor(t); return '<span class="chip" style="margin:0;border-color:'+c+';color:'+c+'">'+esc(t||'소극')+' ×'+(m||1)+'</span>'; }
function renderSummary(samples){
  const el=$('summary'); if(!el) return;
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
function drawChart(samples){
  const c=$('chart'); if(!c) return;
  const dpr=window.devicePixelRatio||1, W=c.clientWidth, H=260;
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
  const c=$('strip'); if(!c) return;
  const dpr=window.devicePixelRatio||1, W=c.clientWidth, H=34;
  c.width=W*dpr; c.height=H*dpr; const g=c.getContext('2d'); g.setTransform(dpr,0,0,dpr,0,0); g.clearRect(0,0,W,H);
  const padL=44,padR=14, cw=W-padL-padR;
  g.fillStyle='#0d1016'; g.fillRect(padL,6,cw,20);
  const bw=Math.max(1.5,cw/1440);
  samples.forEach(s=>{ if(s.app && s.app!=='-'){ g.fillStyle=appColor(s.app); g.fillRect(padL+cw*(minOfDay(s)/1440),6,bw,20); } });
}
function renderApps(samples){
  const bars=$('appbars'); if(!bars) return;
  const stats=appStats(samples);
  if(!stats.length){ bars.innerHTML='<span class="empty">데이터 없음</span>'; return; }
  const max=Math.max(...stats.map(s=>s.minutes));
  bars.innerHTML=stats.map(s=>{
    const col=appColor(s.app), pct=Math.max(3,100*s.minutes/max);
    return '<div class="bar"><div class="name"><span class="dot" style="background:'+col+'"></span>'+esc(s.app)+'</div>'
      +'<div class="track"><div class="fill" style="width:'+pct+'%;background:'+col+'"></div></div>'
      +'<div class="val">'+fmtMin(s.minutes)+'</div></div>';
  }).join('');
}
// Render the moved today-activity blocks from a full /data.json payload.
// No sports-gauge guard here — this page always renders them.
function renderTodayBlocks(d){
  if(!d) return;
  // #total/#status 는 이 페이지 다른 곳(재생 상태)과 겹치므로 tierTotal/tierStatus 로 네임스페이스.
  if(d.total){ const tt=$('tierTotal'); if(tt) tt.textContent=d.total.label; }
  if(d.now){
    const w=d.now.working; const st=$('tierStatus');
    if(st) st.innerHTML='<span class="dot" style="background:'+(w?'#36c08a':'#555')+'"></span>'+esc(d.now.status);
  }
  const ss=withCarryForward(d.samples||[]);
  const b=timeBuckets(ss);
  const set=(id,v)=>{ const el=$(id); if(el) el.textContent=v; };
  set('t_total',fmtH(b.total));
  set('t_desk',fmtH(b.desk));
  set('t_focus',fmtH(b.focus));
  set('t_off',b.off>0?fmtH(b.off):'–');
  drawTiers(b);
  const n=d.now;
  if(n){
    const nowEl=$('now');
    if(nowEl){
      const siteStr=(n.site&&n.site!=='-')?' ('+esc(n.site)+')':'';
      nowEl.innerHTML='<span class="nowtext">지금: 앱 <b>'+esc(n.app)+siteStr+'</b> &nbsp; '+tierBadge(n.tier,n.mult)
        +' &nbsp; ⌨ '+(n.key||0)+' 🖱 '+(n.mouse||0)+' &nbsp; 전략 <b>'+esc(n.profile)+'</b> · BGM <b>'+esc(n.track)+'</b></span>';
    }
  }
  // 확정 가치: 대시보드와 동일하게 계산 (self+AI 승인 전엔 0). 승인 절차는 대시보드에 남아 있다.
  const r=d.review||{};
  const prov=provisionalHours(d.samples||[]);
  let conf=0;
  if(r.submittedSelf && r.aiScore!=null) conf=prov*((r.selfScore||0)/100)*((r.aiScore||0)/100);
  set('value',conf.toFixed(1)+'h');
  drawChart(ss); drawStrip(ss); renderSummary(ss); renderApps(ss);
}

async function loadBGMAnalytics(){
  let d=null;
  try{ d=await (await fetch('/data.json',{cache:'no-store'})).json(); }catch(e){ return; }
  if(!d || !Array.isArray(d.samples)) return;
  const ss=withCarryForward(d.samples);   // 10-min continuity, same as the dashboard
  renderTimeline(ss);
  renderBgmTable(ss);
  renderTodayBlocks(d);   // 오늘 활동 블록도 같은 폴링으로 갱신
}
loadBGMAnalytics();
setInterval(loadBGMAnalytics, 5000);

// transport
const playBtn=$("play");
function togglePlay(){
  // Decide by ACTUAL playing state, not just the audio element — so pressing while the app
  // BGM is already playing stops it, and pressing while idle starts it. No confusing state.
  if(!isBGMPlaying()){
    // START. Engage first (this click is the gesture) so even if the track isn't ready yet,
    // the poll will auto-play it the moment the director picks one.
    engage();
    // Start the CHALLENGE too (mate-together framing) — playback only makes sound while a
    // session is live, so this is what actually gets the director going. Then turn the BGM
    // master on. Both keep the dashboard and the widget in sync.
    if(mode!=='debug'){ sessionControl('start'); bgmControl('play'); }
    if(!curTrack && lastNow && lastNow.id>=0){
      curTrack={id:lastNow.id,title:lastNow.title,bpm:lastNow.bpm};
      audioEl.src="/bgm-audio/"+curTrack.id; decoded=null;
      $("render").disabled=false; renderTracks();
    }
    if(curTrack){ audioEl.play().catch(()=>{}); }
    // If a track is ready the 'play' event flips to ⏸ within ms; if not (warm-up), we stay ▶
    // and the poll flips it once real playback starts — so no ⏸→▶→⏸ flicker.
  } else {
    // STOP. In activity mode this stops the challenge AND turns the widget's BGM off (in sync).
    if(!audioEl.paused){ audioEl.pause(); }
    if(mode!=='debug'){ sessionControl('stop'); bgmControl('stop'); }
  }
  updatePlayIcon();
}
playBtn.onclick=togglePlay;

// ---------- mute: silence the sound while the challenge keeps running ----------
const muteBtn=$("mute");
function applyMute(){
  if(outMute && ctx){ outMute.gain.setTargetAtTime(muted?0:1, ctx.currentTime, 0.03); }
  muteBtn.textContent = muted ? "🔇" : "🔊";
  muteBtn.classList.toggle("on", muted);
  muteBtn.title = muted ? "음소거 해제 — 다시 소리를 켭니다"
                        : "음소거 — 챌린지는 계속, 소리만 끕니다";
}
// User clicked the in-page mute button: flip locally for instant feedback, then report the new
// state to the app so session.isMuted (the source of truth) and every other surface follow.
muteBtn.onclick=()=>{ muted=!muted; applyMute(); sessionMute(muted); };
// App-driven mute (⌘M, dashboard mute dot, menu): set our mute to a SPECIFIC state without looping
// back to the server — AppWindowController.setWebMute calls this. No-op if already in that state.
window.__setMute = function(m){ m=!!m; if(muted!==m){ muted=m; applyMute(); } };
applyMute();
audioEl.addEventListener("play", ()=>{ nativeMute(true); updatePlayIcon(); applyAmbience(); stopAutoStart();
  $("status").textContent="재생 중 · "+(curTrack?curTrack.title:"")+" · "+PRESETS[current].name; });
audioEl.addEventListener("pause",()=>{ nativeMute(false); updatePlayIcon(); applyAmbience(); });
audioEl.addEventListener("ended",()=>{ nativeMute(false); updatePlayIcon(); applyAmbience(); });
// If the media errors mid-play it may not fire pause — unmute so native BGM isn't left silent.
audioEl.addEventListener("error",()=>{ nativeMute(false); updatePlayIcon(); });
audioEl.addEventListener("stalled",()=>{ if(audioEl.paused) nativeMute(false); });
window.addEventListener("pagehide", ()=>nativeMute(false));
audioEl.addEventListener("loadedmetadata",()=>{ $("dur").textContent=fmt(audioEl.duration); });
audioEl.addEventListener("timeupdate",()=>{
  $("cur").textContent=fmt(audioEl.currentTime);
  if(audioEl.duration){ const s=$("seek"); s.value=audioEl.currentTime/audioEl.duration*1000;
    s.style.setProperty("--fill",(s.value/10)+"%"); }
});
$("seek").addEventListener("input",e=>{
  if(audioEl.duration){ audioEl.currentTime=e.target.value/1000*audioEl.duration; }
});

// ---------- offline render / export ----------
let decoded=null;
async function getDecoded(){
  if(decoded) return decoded;
  const resp=await fetch(audioEl.src);
  const ab=await resp.arrayBuffer();
  const tmp=new (window.AudioContext||window.webkitAudioContext)();
  decoded=await tmp.decodeAudioData(ab);
  tmp.close();
  return decoded;
}
$("render").onclick=async ()=>{
  if(!curTrack) return;
  const btn=$("render"); btn.disabled=true;
  $("rstatus").textContent="렌더링 중…";
  try{
    const src=await getDecoded();
    const p=PRESETS[current];
    const oc=new OfflineAudioContext(2, src.length+Math.ceil(p.dur*src.sampleRate)+src.sampleRate, src.sampleRate);
    const s=oc.createBufferSource(); s.buffer=src;
    const ig=oc.createGain();
    const lc=oc.createBiquadFilter(); lc.type="highpass";
    const hc=oc.createBiquadFilter(); hc.type="lowpass"; hc.Q.value=0.4;
    const dg=oc.createGain(), pd=oc.createDelay(1.0), cv=oc.createConvolver(), wg=oc.createGain(), mg=oc.createGain();
    const shpF=oc.createBiquadFilter(); shpF.type="highpass"; shpF.Q.value=0.5;
    const shpF2=oc.createBiquadFilter(); shpF2.type="highpass"; shpF2.Q.value=0.5;
    const dHP=oc.createBiquadFilter(); dHP.type="highpass"; dHP.frequency.value=40;
    const dLP=oc.createBiquadFilter(); dLP.type="lowpass";  dLP.frequency.value=140;
    const dRect=oc.createWaveShaper(); dRect.curve=absCurve();
    const dEnv=oc.createBiquadFilter(); dEnv.type="lowpass"; dEnv.frequency.value=16;
    const dShape=oc.createWaveShaper(); dShape.curve=duckCurve();
    const dGain=oc.createGain();
    const sp=oc.createChannelSplitter(2);
    const mid=oc.createGain(); mid.gain.value=0.5;
    const sl=oc.createGain(); sl.gain.value=0.5;
    const sr2=oc.createGain(); sr2.gain.value=-0.5;
    const sd=oc.createGain();
    const sw=oc.createGain();
    const sn=oc.createGain(); sn.gain.value=-1;
    const oL=oc.createGain(), oR=oc.createGain();
    const mrg=oc.createChannelMerger(2);

    const dist=+$("dist").value, distN=(dist-3)/57;
    const wetPct=+$("wet").value/100, widPct=+$("wid").value/100;
    const hcHz=+$("hc").value, lcHz=+$("lc").value, shpHz=+$("shp").value, duckPct=+$("duck").value/100, vol=+$("vol").value/100;
    const wetEff=fxEnabled?Math.min(1,wetPct*(0.7+distN*0.9)):0;
    const hcEff=fxEnabled?Math.min(hcHz,hcHz*(1-distN*0.45)):20000;
    const dryEff=fxEnabled?(1-0.25*distN):1;

    cv.buffer=buildIR(oc,p);
    pd.delayTime.value=Math.min(0.99,(p.pre+distN*40)/1000);
    wg.gain.value=wetEff; dg.gain.value=dryEff;
    hc.frequency.value=hcEff; lc.frequency.value=fxEnabled?lcHz:20;
    shpF.frequency.value=fxEnabled?shpHz:20; shpF2.frequency.value=fxEnabled?shpHz:20;
    dGain.gain.value=fxEnabled?-Math.min(duckPct,0.95)*wetEff:0;
    sw.gain.value=fxEnabled?widPct:1; mg.gain.value=vol;

    s.connect(ig); ig.connect(lc); lc.connect(hc);
    hc.connect(dg); hc.connect(shpF); shpF.connect(shpF2); shpF2.connect(pd); pd.connect(cv); cv.connect(wg);
    ig.connect(dHP); dHP.connect(dLP); dLP.connect(dRect); dRect.connect(dEnv);
    dEnv.connect(dShape); dShape.connect(dGain); dGain.connect(wg.gain);
    dg.connect(sp); wg.connect(sp);
    sp.connect(mid,0); sp.connect(mid,1);
    sp.connect(sl,0); sp.connect(sr2,1); sl.connect(sd); sr2.connect(sd); sd.connect(sw);
    mid.connect(oL); sw.connect(oL);
    mid.connect(oR); sw.connect(sn); sn.connect(oR);
    oL.connect(mrg,0,0); oR.connect(mrg,0,1);
    mrg.connect(mg); mg.connect(oc.destination);

    s.start();
    const rendered=await oc.startRendering();
    const blob=encodeWAV(rendered);
    const url=URL.createObjectURL(blob);
    const a=document.createElement("a");
    a.href=url; a.download=(curTrack.title||"bgm")+" ("+p.name+").wav"; a.click();
    setTimeout(()=>URL.revokeObjectURL(url),4000);
    $("rstatus").textContent="저장 완료: "+a.download;
  }catch(err){
    $("rstatus").textContent="오류: "+err.message;
    console.error(err);
  }finally{ btn.disabled=false; }
};

function encodeWAV(abuf){
  const nch=abuf.numberOfChannels, sr=abuf.sampleRate, n=abuf.length;
  let peak=1e-6;
  const chans=[];
  for(let c=0;c<nch;c++){ const d=abuf.getChannelData(c); chans.push(d);
    for(let i=0;i<n;i++) peak=Math.max(peak,Math.abs(d[i])); }
  const norm=Math.min(1, 0.89/peak);
  const bytes=44+n*nch*2;
  const buf=new ArrayBuffer(bytes); const view=new DataView(buf);
  const ws=(o,s)=>{for(let i=0;i<s.length;i++)view.setUint8(o+i,s.charCodeAt(i));};
  ws(0,"RIFF"); view.setUint32(4,bytes-8,true); ws(8,"WAVE"); ws(12,"fmt ");
  view.setUint32(16,16,true); view.setUint16(20,1,true); view.setUint16(22,nch,true);
  view.setUint32(24,sr,true); view.setUint32(28,sr*nch*2,true);
  view.setUint16(32,nch*2,true); view.setUint16(34,16,true); ws(36,"data");
  view.setUint32(40,n*nch*2,true);
  let off=44;
  for(let i=0;i<n;i++){
    for(let c=0;c<nch;c++){
      let v=chans[c][i]*norm; v=Math.max(-1,Math.min(1,v));
      view.setInt16(off, v<0?v*0x8000:v*0x7FFF, true); off+=2;
    }
  }
  return new Blob([buf],{type:"audio/wav"});
}

// init — restore the last state (default 콘서트홀 if none saved). A saved 커스텀 is rebuilt first
// so it reappears as a card and can be reselected.
try{
  const st = JSON.parse(localStorage.getItem(STORE_KEY) || "null");
  if(st){
    if(st.custom && st.custom.wet!=null) PRESETS.custom = st.custom;
    if(st.preset && PRESETS[st.preset]) current = st.preset;
    setPresetControls(current);                                   // character sliders (+ seat)
    if(st.level){                                                 // global levels are preset-independent
      if(st.level.amb!=null) $("amb").value = st.level.amb;
      if(st.level.vol!=null) $("vol").value = st.level.vol;
    }
  } else { setPresetControls(current); }
}catch(e){ setPresetControls(current); }
// ======================= 컨디션 맵 =======================
// 업무 시작(8h 무활동 뒤 첫 활동)을 기준으로 24시간 컨디션 흐름을 가로 띠로 그린다.
// 데이터는 대시보드와 동일한 /history.json (분 단위 샘플: t, active(초), tier, meeting)을 재사용.
const MAP_GAP = 8*3600;             // 8시간 무활동 => 퇴근 경계 (낮잠·짧은 수면으로 하루가 쪼개지지 않게)
const MAP_DAY = 24*3600;
const COND_COLOR = ['#1b1e27','#5a6172','#c98a3f','#e8a13a','#36c08a','#22e39a']; // 0휴식 1소극 2·3중간 4적극 5몰입
let _mapInited=false, _mapCtl=null, _mapRange={mode:'auto',preset:'auto',start:'',end:''};
let _mapBase=8, _mapData=null, _mapNeed=0, _mapLoading=false, _mapSig='';

function initMap(){
  if(_mapInited){ loadMap(); return; }
  _mapInited=true;
  $("mapTz").textContent='시각 '+CMTimeFilter.tzLabel()+' 기준';
  reflectBase();
  _mapCtl = CMTimeFilter.mount($("mapFilter"), {
    presets:['today','yesterday','7d','1m','30d'], auto:true, custom:true, initial:'auto',
    onChange:(r)=>{ _mapRange=r; loadMap(); }
  });
}
function reflectBase(){
  document.querySelectorAll('#mapPanel [data-base]').forEach(b=>b.classList.toggle('on', +b.dataset.base===_mapBase));
  const ci=$("baseCustom"); if(ci && document.activeElement!==ci) ci.value=([8,12,18].includes(_mapBase)?'':_mapBase);
}
function setBase(h){ _mapBase=h; reflectBase(); if(_mapData) renderMap(); }
function setBaseCustom(v){ const n=Math.max(1,Math.min(24,parseInt(v,10)||0)); if(!n) return; _mapBase=n; reflectBase(); if(_mapData) renderMap(); }

// 필요한 일수: 범위 시작~오늘 + 앞쪽 갭 탐지를 위한 여유 1일.
function mapNeededDays(){
  const todayStr=CMTimeFilter.dayStr(new Date());
  const start=_mapRange.start||todayStr;
  return Math.max(2, CMTimeFilter.daysBetween(start, todayStr)+2);
}
function loadMap(force){
  const need=mapNeededDays(), sig=need+'_'+_mapRange.start+'_'+_mapRange.end+'_'+_mapRange.mode;
  if(_mapData && !force && need<=_mapNeed && sig===_mapSig){ renderMap(); return; }
  if(_mapLoading) return; _mapLoading=true;
  $("mapBody").innerHTML='<div class="tkempty">불러오는 중…</div>';
  fetch('/history.json?days='+need).then(x=>x.json()).then(j=>{
    _mapData=(j&&j.days)||[]; _mapNeed=need; _mapSig=sig; _mapLoading=false; renderMap();
  }).catch(()=>{ _mapLoading=false; $("mapBody").innerHTML='<div class="tkempty">불러오지 못했습니다</div>'; });
}

// 전체 샘플을 시간순으로 평탄화 (각 샘플에 t/active/tier/meeting).
function mapAllSamples(){
  const out=[];
  (_mapData||[]).forEach(d=>{ (d.samples||[]).forEach(s=>out.push(s)); });
  out.sort((a,b)=>a.t-b.t);
  return out;
}
// 활동(active>0) 샘플 앞에 8h+ 공백이 있으면 그 샘플이 '업무 시작' 후보.
function mapStartCandidates(active){
  const st=[]; let prev=null;
  active.forEach(s=>{ if(prev===null || (s.t-prev)>=MAP_GAP) st.push(s.t); prev=s.t; });
  return st;
}
function localDayStr(t){ return CMTimeFilter.dayStr(new Date(t*1000)); }
function condLevel(s){ const a=s.active||0; if(a<=0) return 0; if(s.meeting) return 3; if(s.tier==='적극') return a>=40?5:4; if(s.tier==='중간') return a>=40?3:2; return 1; }
function clock(t){ const d=new Date(t*1000); return (d.getHours()<10?'0':'')+d.getHours()+':'+(d.getMinutes()<10?'0':'')+d.getMinutes(); }

// 하나의 업무일 띠 데이터: 96개(15분) 셀 레벨 + 통계.
function buildBand(startT, allSamples, nowT){
  const cells=new Array(96).fill(-1);              // -1 = 샘플 없음
  const sums=new Array(96).fill(0), cnts=new Array(96).fill(0);
  let activeSec=0, focusSec=0, lvSum=0, lvCnt=0, lastActive=startT;
  allSamples.forEach(s=>{
    if(s.t<startT || s.t>=startT+MAP_DAY) return;
    const idx=Math.min(95, Math.floor((s.t-startT)/900));
    const lv=condLevel(s); sums[idx]+=lv; cnts[idx]++;
    if((s.active||0)>0){ activeSec+=s.active; lastActive=s.t; lvSum+=lv; lvCnt++; if(s.tier==='적극') focusSec+=s.active; }
  });
  for(let i=0;i<96;i++){ if(cnts[i]>0) cells[i]=Math.round(sums[i]/cnts[i]); }
  const winEnd=startT+MAP_DAY;
  const effEnd=(nowT<winEnd)?nowT:lastActive;    // 진행중이면 지금까지, 지난 날이면 마지막 활동까지
  return { startT, cells, activeHours:activeSec/3600, focusHours:focusSec/3600,
           elapsedHours:Math.max(0,(effEnd-startT)/3600), avgLevel:lvCnt?lvSum/lvCnt:0, lastActive };
}
// 대상 로컬 날짜(YYYY-MM-DD)의 업무 시작 시각. 갭 뒤 첫 활동 우선, 없으면 그 날 첫 활동.
function startForDay(day, cands, active){
  const onDay=cands.filter(t=>localDayStr(t)===day); if(onDay.length) return Math.min(...onDay);
  const anyDay=active.filter(s=>localDayStr(s.t)===day).map(s=>s.t); return anyDay.length?Math.min(...anyDay):null;
}

function levelName(lv){ return lv>=4.5?'몰입':lv>=3.5?'적극':lv>=2.5?'중간':lv>=1.5?'중간':lv>=0.5?'소극':'휴식'; }

function bandHTML(band, nowT, showNow){
  const cells=band.cells.map(lv=>{
    if(lv<0) return '<div class="mapcell" style="background:transparent"></div>';
    return '<div class="mapcell" style="background:'+COND_COLOR[lv]+'"></div>';
  }).join('');
  // 마커: 기준 시간, (진행중이면) 지금
  let marks='';
  if(_mapBase<24){ const p=(_mapBase/24*100).toFixed(2); marks+='<div class="mapmark goal" style="left:'+p+'%"><span>🏁 '+_mapBase+'h</span></div>'; }
  if(showNow && nowT<band.startT+MAP_DAY && nowT>=band.startT){
    const p=((nowT-band.startT)/MAP_DAY*100).toFixed(2); marks+='<div class="mapmark now" style="left:'+p+'%"><span>지금</span></div>';
  }
  // 축: 0/6/12/18/24h 시점의 실제 시각
  let axis=''; [0,6,12,18,24].forEach(h=>{ const p=(h/24*100).toFixed(2); axis+='<span style="left:'+p+'%">'+clock(band.startT+h*3600)+'</span>'; });
  return '<div class="mapband">'+cells+marks+'</div><div class="mapaxis">'+axis+'</div>';
}

function mapLegend(){
  const items=[[0,'휴식/자리비움'],[1,'소극'],[3,'중간'],[4,'적극'],[5,'몰입']];
  $("mapLegend").innerHTML=items.map(x=>'<span><i style="background:'+COND_COLOR[x[0]]+'"></i>'+x[1]+'</span>').join('')
    + '<span style="margin-left:auto">기준 '+_mapBase+'h · 15분 단위</span>';
}
function card(k,v,c){ return '<div class="mapcard"><div class="k">'+k+'</div><div class="v">'+v+'</div>'+(c?'<div class="c">'+c+'</div>':'')+'</div>'; }

function renderMap(){
  reflectBase(); mapLegend();
  const all=mapAllSamples();
  const active=all.filter(s=>(s.active||0)>0);
  if(!active.length){ $("mapSummary").innerHTML=''; $("mapBody").innerHTML='<div class="tkempty">기간 내 활동 기록이 없습니다.</div>'; return; }
  const cands=mapStartCandidates(active);
  const nowT=Date.now()/1000;
  const todayStr=CMTimeFilter.dayStr(new Date());

  // 대상 날짜 목록 결정
  let days=[];
  if(_mapRange.mode==='auto'){
    // 지금 진행 중인 업무일: now 이전의 가장 최근 시작 후보 (없으면 마지막 활동일 첫 활동)
    const past=cands.filter(t=>t<=nowT);
    const startT=past.length?Math.max(...past):active[active.length-1].t;
    return renderSingle(startT, all, nowT, true, '자동 · 현재 업무일');
  } else if(_mapRange.preset==='today' || _mapRange.preset==='yesterday' || (_mapRange.start===_mapRange.end)){
    const day=_mapRange.start;
    const startT=startForDay(day, cands, active);
    if(startT==null){ $("mapSummary").innerHTML=''; $("mapBody").innerHTML='<div class="tkempty">해당 날짜에 활동 기록이 없습니다.</div>'; return; }
    return renderSingle(startT, all, nowT, day===todayStr, (day===todayStr?'오늘':day===CMTimeFilter.presetRange('yesterday').start?'어제':day));
  } else {
    // 다일 범위: 시작~끝 각 날짜를 한 행씩 (최신순, 최대 31행)
    const list=[]; let d=_mapRange.end;
    while(d>=_mapRange.start && list.length<400){ list.push(d); const dt=CMTimeFilter.parseDay(d); dt.setDate(dt.getDate()-1); d=CMTimeFilter.dayStr(dt); }
    days=list;
  }
  // 다일 렌더
  const capped=days.slice(0,31);
  const bands=[];
  capped.forEach(day=>{ const st=startForDay(day, cands, active); if(st!=null) bands.push({day, band:buildBand(st, all, nowT)}); });
  if(!bands.length){ $("mapSummary").innerHTML=''; $("mapBody").innerHTML='<div class="tkempty">기간 내 활동 기록이 없습니다.</div>'; return; }
  const avgWork=bands.reduce((a,b)=>a+b.band.elapsedHours,0)/bands.length;
  const avgLv=bands.reduce((a,b)=>a+b.band.avgLevel,0)/bands.length;
  $("mapSummary").innerHTML = card('업무일', bands.length+'일')
    + card('평균 업무시간', avgWork.toFixed(1)+'h', '기준 '+_mapBase+'h')
    + card('평균 컨디션', 'Lv '+avgLv.toFixed(1), levelName(avgLv));
  const rows=bands.map(x=>{
    const b=x.band, wd=new Date(b.startT*1000);
    const wk=['일','월','화','수','목','금','토'][wd.getDay()];
    return '<div class="maprow"><div class="rl"><b>'+x.day+' ('+wk+')</b>'
      +'<span class="rr">시작 '+clock(b.startT)+' · '+b.elapsedHours.toFixed(1)+'h · Lv '+b.avgLevel.toFixed(1)+'</span></div>'
      + bandHTML(b, nowT, x.day===todayStr) + '</div>';
  }).join('');
  const note=days.length>31?'<div class="tkempty" style="text-align:left">최근 31일만 표시합니다 (범위 '+days.length+'일).</div>':'';
  $("mapBody").innerHTML=rows+note;
}

function renderSingle(startT, all, nowT, showNow, label){
  const b=buildBand(startT, all, nowT);
  const endBase=clock(startT+_mapBase*3600);
  const prog=Math.min(999,(b.elapsedHours/_mapBase*100));
  $("mapSummary").innerHTML = card('업무 시작', clock(startT), label)
    + card('진행', b.elapsedHours.toFixed(1)+'h / '+_mapBase+'h', prog.toFixed(0)+'% · 예상 퇴근 '+endBase)
    + card('평균 컨디션', 'Lv '+b.avgLevel.toFixed(1), levelName(b.avgLevel))
    + card('몰입(적극)', b.focusHours.toFixed(1)+'h', '활동 '+b.activeHours.toFixed(1)+'h');
  $("mapBody").innerHTML='<div class="maprow">'+bandHTML(b, nowT, showNow)+'</div>';
}
// ======================= /컨디션 맵 =======================

renderPresets(); syncLabels(); setMode("map");

// Try autoplay on load: succeeds in the app's native BGM window (WKWebView with the autoplay
// gesture requirement disabled) so the effect plays with zero clicks; harmlessly rejected in a
// normal browser (play() is blocked) → falls back to the first-click auto-start. Bounded retries
// let the first /api/bgm/now resolve so there is a track to play.
let _autoTries=0;
function tryAutoplayOnLoad(){
  if(engaged || !audioEl.paused) return;      // already going
  if(_autoTries++ > 8) return;                // ~12s of attempts, then give up (browser needs a click)
  bgmAutoStart();
  setTimeout(tryAutoplayOnLoad, 1400);
}
setTimeout(tryAutoplayOnLoad, 300);
</script>
</body>
</html>
"""#
    }
}
