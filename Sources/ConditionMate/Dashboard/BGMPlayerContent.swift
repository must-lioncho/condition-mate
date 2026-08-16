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
  /* 전략7 장소·컨디션 chips */
  .venuechips{display:flex;flex-wrap:wrap;gap:6px}
  .vchip{border:1px solid var(--line);background:#12141c;color:var(--dim);font-size:12.5px;font-weight:600;
         padding:7px 12px;border-radius:999px;cursor:pointer;transition:.12s}
  .vchip:hover{color:var(--txt);border-color:var(--accent)}
  .vchip.on{background:linear-gradient(145deg,var(--accent),#5a3ff0);color:#fff;border-color:transparent;box-shadow:var(--glow)}
  .vchip .vc-n{opacity:.6;font-weight:500;margin-left:4px;font-size:11px;font-variant-numeric:tabular-nums}
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
  /* strategy filter (전체/전략N) + 전략 히스토리 */
  .statseg{display:flex; gap:4px; padding:3px; border-radius:999px; background:#12141c; border:1px solid var(--line)}
  .statseg button{background:none; border:0; color:var(--dim); font-size:12px; font-weight:600;
                  padding:4px 11px; border-radius:999px; cursor:pointer; white-space:nowrap}
  .statseg button.on{background:var(--accent); color:#fff}
  .statseg button:hover:not(.on){color:var(--txt)}
  .strat{padding:10px 12px; border-radius:11px; background:#12141c; border:1px solid transparent}
  .strat+.strat{margin-top:6px}
  .strat.live{border-color:var(--accent)}
  .strat .sthead{display:flex; align-items:center; gap:9px; flex-wrap:wrap}
  .strat .stname{font-size:14px; font-weight:700}
  .strat .stperiod{font-size:11.5px; color:var(--dim); font-variant-numeric:tabular-nums}
  .strat .stlive{font-size:11px; color:var(--accent); border:1px solid var(--accent); border-radius:999px; padding:2px 8px}
  .strat .stbtn{font-size:11px; font-weight:600; color:var(--accent2); background:none; border:1px solid var(--accent2); border-radius:999px; padding:2px 10px; cursor:pointer; margin-left:auto}
  .strat .stbtn:hover{background:rgba(0,212,200,.12)}
  /* 플랜 맵 modal — embeds the standalone /bgm-plan page in an iframe. In-page modal
     because window.open inside this WKWebView proved unreliable as an entry point. */
  .pm-back{position:absolute; inset:0; background:rgba(4,5,9,.72); backdrop-filter:blur(3px)}
  .pm-panel{position:absolute; inset:4% 5%; background:var(--bg); border:1px solid var(--line); border-radius:18px; overflow:hidden; display:flex; flex-direction:column; box-shadow:0 24px 80px rgba(0,0,0,.6)}
  .pm-head{display:flex; align-items:center; gap:10px; padding:12px 16px; border-bottom:1px solid var(--line); font-size:14px}
  .pm-x{margin-left:auto; background:none; border:1px solid var(--line); color:var(--dim); border-radius:9px; font-size:13px; padding:3px 11px; cursor:pointer}
  .pm-x:hover{color:var(--txt); border-color:var(--dim)}
  .pm-frame{flex:1 1 auto; width:100%; border:0; background:transparent}
  .strat .stsum{font-size:12.5px; color:var(--txt); margin-top:5px; line-height:1.5}
  .strat .stretro{font-size:12px; color:var(--dim); margin-top:3px; line-height:1.5}
  /* 슬롯 성적표 (전략4 관측) — per-plan-slot hit/miss scores. NEUTRAL tones only:
     the hitRate bar uses the purple accent (never red/green traffic-light colors —
     green is reserved for the mute button), the 재계획 후보 badge uses teal. */
  .slotrow{padding:10px 12px; border-radius:11px; background:#12141c}
  .slotrow+.slotrow{margin-top:6px}
  .slotrow .slhead{display:flex; align-items:center; gap:9px; flex-wrap:wrap}
  .slotrow .slname{font-size:13.5px; font-weight:700}
  .slotrow .slmeta{font-size:11.5px; color:var(--dim); font-variant-numeric:tabular-nums}
  .slotrow .slreplan{font-size:11px; color:var(--accent2); border:1px solid var(--accent2); border-radius:999px; padding:2px 8px}
  .slotrow .slnums{margin-left:auto; font-size:12px; color:var(--dim); font-variant-numeric:tabular-nums; white-space:nowrap}
  .slotrow .slnums b{color:var(--txt); font-weight:600}
  .slotrow .slbarwrap{margin-top:7px; height:6px; border-radius:999px; background:#1c1f2c; overflow:hidden}
  .slotrow .slbar{height:100%; border-radius:999px; background:linear-gradient(90deg,var(--accent),#5a3ff0)}
  .slotrow .slsub{font-size:11.5px; color:var(--dim); margin-top:6px; line-height:1.5}
  /* bgm태깅관리 (액티비티 전용 감사) — NEUTRAL tones only: never red/green traffic-light
     colors (green is reserved for the mute button); the "BPM 없음" badge is plain gray. */
  .tagstats{display:grid; grid-template-columns:repeat(auto-fit,minmax(120px,1fr)); gap:8px; margin-bottom:10px}
  .tagstat{background:#12141c; border:1px solid var(--line); border-radius:11px; padding:10px 12px}
  .tagstat .tsv{font-size:18px; font-weight:700; font-variant-numeric:tabular-nums}
  .tagstat .tsl{font-size:11px; color:var(--dim); margin-top:2px}
  .tagrow{padding:10px 12px; border-radius:11px; background:#12141c}
  .tagrow+.tagrow{margin-top:6px}
  .tagrow .tghead{display:flex; align-items:center; gap:9px; flex-wrap:wrap}
  .tagrow .tgname{font-size:13.5px; font-weight:700}
  .tagrow .tgmeta{font-size:11.5px; color:var(--dim); font-variant-numeric:tabular-nums}
  .tagrow .tgfb{font-size:11px; color:var(--dim); border:1px solid var(--line); border-radius:999px;
                padding:2px 8px; background:#1c1f2c}
  .tagrow .tgpurpose{font-size:11.5px; color:var(--dim); margin-top:5px; line-height:1.5}
  /* Per-track expansion (theme row click). arc badges stay in NEUTRAL hues —
     slate / indigo / violet / steel-blue only, per the no-traffic-light rule. */
  .tagrow .tghead{cursor:pointer}
  .tagrow .tgarcs{font-size:11px; color:var(--dim); font-variant-numeric:tabular-nums; margin-left:auto}
  .tagrow .tgtracks{display:none; margin-top:8px; border-top:1px solid var(--line); padding-top:6px}
  .tagrow.open .tgtracks{display:block}
  .tgtrk{display:flex; align-items:center; gap:8px; padding:4px 6px; border-radius:8px; font-size:11.5px}
  .tgtrk+.tgtrk{margin-top:2px}
  .tgtrk .tgtn{flex:0 1 auto; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap}
  .tgtrk .tgtb{color:var(--dim); font-variant-numeric:tabular-nums; white-space:nowrap}
  .tgtrk .tgtier{font-size:10.5px; color:var(--dim); white-space:nowrap}
  .tgtrk .tgtp{flex:1; min-width:0; font-size:11px; color:var(--dim); text-align:right;
               overflow:hidden; text-overflow:ellipsis; white-space:nowrap}
  .tgab{font-size:10.5px; border-radius:999px; padding:1px 8px; border:1px solid var(--line);
        color:var(--dim); white-space:nowrap}
  .tgab.intro{color:#9db4dd; border-color:#2e3d5c; background:#182034}     /* steel blue: 기 */
  .tgab.build{color:#a8a5e8; border-color:#3b3868; background:#1d1c36}     /* indigo: 승 */
  .tgab.peak{color:#c4a2e4; border-color:#4c3866; background:#251a33}      /* violet: 전 */
  .tgab.resolve{color:#a3b4c2; border-color:#354350; background:#182028}   /* slate: 결 */
  .tgab.ambient{color:var(--dim); border-color:var(--line); background:#1c1f2c}
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
  /* 컨디션맵 → 액션로그 드릴다운: 띠가 클릭 대상임을 손모양으로 알린다 */
  .mapband{cursor:pointer}
  /* 액션로그 (대시보드에서 이동) — 렌더 함수가 쓰는 .panel/.pill 을 이 페이지 변수로 정의 */
  #actPanel .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px}
  #actPanel .pill{display:inline-block;padding:1px 7px;border-radius:999px;font-size:11px;border:1px solid var(--line)}
  #actPanel .empty{font-size:13px;padding:10px 4px;line-height:1.6}
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
  /* 히스토리 (대시보드에서 이동) — #histPanel 스코프로 다른 곳의 .card 와 충돌 방지, #todayBlocks 와 동일 스타일 */
  #histPanel h2{font-size:14px;margin:16px 0 6px;color:var(--txt)}
  #histPanel .cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:8px}
  #histPanel .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin-top:0;box-shadow:none;flex:1;min-width:150px}
  #histPanel .card .k{color:var(--dim);font-size:12px}
  #histPanel .card .v{font-size:22px;font-weight:700;margin-top:4px}
  #histPanel .card .cap{color:var(--dim);font-size:11px;margin-top:3px}
  #histPanel .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px}
  #histPanel canvas{width:100%;display:block}
  @media(max-width:560px){
    #histPanel .cards{gap:8px}
    #histPanel .card{min-width:calc(50% - 4px);flex:0 0 calc(50% - 4px)}
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
    <button class="subtab" data-m="history" onclick="setMode('history')" title="날짜별 집중도·초집중 세션·시간대 분석">히스토리</button>
    <button class="subtab" data-m="actions" onclick="setMode('actions')">액션로그</button>
    <button class="subtab" data-m="diag" onclick="setMode('diag')">네트워크 진단</button>
    <button class="subtab" data-m="debug" onclick="setMode('debug')">디버그</button>
    <button class="subtab" data-m="syslog" onclick="setMode('syslog')" title="프로덕트 퀄리티 개선 전용 — 유저가 매 순간 보던 화면(0.5초)과 창 라이프사이클">시스템 로그</button>
    <button class="subtab" data-m="screens" onclick="setMode('screens')" title="UX/UI 개선 전용 — 앱이 실제로 그린 모든 화면 상태를 자동 스크린샷(SCR-ID)으로 수집·관리">화면 카탈로그</button>
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

  <!-- 히스토리 (대시보드에서 이동): 날짜별 집중도 + 초집중 세션 + 시간대 분석. 컨디션맵과 같은
       /history.json(분 단위 샘플)을 재사용하고, 오늘 활동과 동일한 withCarryForward+timeBuckets 로
       총/책상/집중을 구한 뒤 '지속 시간 기준'의 초집중 세션을 잡는다. 요소 id는 대시보드와 동일. -->
  <div class="card" id="histPanel" style="display:none">
    <div class="row" style="margin:0 0 8px;gap:6px;align-items:center;flex-wrap:wrap">
      <span class="muted" style="font-size:12px">기간</span>
      <button class="btn" id="hr_today" onclick="setHistRange('today')" title="오늘 하루">오늘</button>
      <button class="btn" id="hr_yesterday" onclick="setHistRange('yesterday')" title="어제 하루">어제</button>
      <button class="btn" id="hr_7d" onclick="setHistRange('7d')" title="최근 7일">1주일</button>
      <button class="btn" id="hr_1m" onclick="setHistRange('1m')" title="최근 한 달">한달</button>
      <button class="btn" id="hr_30d" onclick="setHistRange('30d')" title="최근 30일">30일</button>
      <button class="btn" id="hr_3m" onclick="setHistRange('3m')" title="최근 3달">3달</button>
      <input type="date" id="histFrom" class="btn" onchange="onHistDate()" style="color-scheme:dark;padding:5px 8px" title="시작 날짜">
      <span class="muted" style="font-size:12px">~</span>
      <input type="date" id="histTo" class="btn" onchange="onHistDate()" style="color-scheme:dark;padding:5px 8px" title="끝 날짜">
      <button class="btn" onclick="loadHistory(true)" style="margin-left:auto" title="히스토리 새로고침">↻ 새로고침</button>
    </div>
    <div class="row" style="margin:0 0 10px;gap:6px;align-items:center;flex-wrap:wrap">
      <span class="muted" style="font-size:12px">초집중 기준 (끊김 없이 이어진 집중)</span>
      <button class="btn" id="df15" onclick="setDeepMin(15)" title="15분 이상 이어진 집중을 초집중으로">15분+</button>
      <button class="btn" id="df25" onclick="setDeepMin(25)" title="25분 이상 이어진 집중을 초집중으로">25분+</button>
      <button class="btn" id="df45" onclick="setDeepMin(45)" title="45분 이상 이어진 집중을 초집중으로">45분+</button>
      <span class="muted" id="histRange" style="font-size:12px;margin-left:auto">불러오는 중…</span>
    </div>
    <div id="histSummary" class="cards" style="margin:0 0 12px"></div>
    <h2 style="margin:16px 0 6px">초집중 시간대 · 언제 몰입하나</h2>
    <div class="panel" style="margin:0 0 14px">
      <canvas id="dfHours" style="height:120px"></canvas>
      <div class="muted" style="font-size:11px;margin-top:6px" id="dfHoursCap">시간대별 초집중 누적 — 막대가 높을수록 그 시간에 자주 몰입합니다.</div>
    </div>
    <h2 style="margin:16px 0 6px">날짜별 기록 (최신순)</h2>
    <div id="histDays"><div class="empty">불러오는 중…</div></div>
  </div>

  <!-- 액션로그 (대시보드에서 이동): 모든 유저 액션 + 그때 나온 BGM 반응 타임라인.
       데이터는 /api/actions(+SSE /api/actions/stream), 기간 필터는 컨디션맵과 같은
       CMTimeFilter 공유. 컨디션맵의 띠를 클릭하면 그 업무일로 필터되어 열린다(mapDrill). -->
  <div class="card" id="actPanel" style="display:none">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:6px">
      <p class="lbl" style="margin:0">액션로그 · 유저 액션 + BGM 반응</p>
      <button class="btn" onclick="loadActions(true)" title="액션로그 새로고침">↻ 새로고침</button>
    </div>
    <p class="actnote" style="margin:0 0 12px">모든 유저 액션과 그때 시스템이 어떻게 반응했는지를 시간순으로 봅니다. <b>컨디션맵의 띠를 클릭</b>하면 그 업무일의 로그로 바로 이동합니다.</p>
    <div id="actFilter" style="margin:0 0 10px"></div>
    <div class="cmf-row" style="margin:0 0 8px">
      <span style="font-size:12px;color:var(--dim)">종류</span>
      <button class="cmf-btn" id="ak_all" onclick="setActKind('')" title="모든 이벤트">전체</button>
      <button class="cmf-btn" id="ak_user" onclick="setActKind('user')" title="세션 시작·중지, 목표 조작, 음소거, 폭우 소환, 싫어요 등 직접 조작">유저 액션</button>
      <button class="cmf-btn" id="ak_bgm" onclick="setActKind('bgm')" title="곡 전환·오프너 — 어떤 규칙(풀)이 그 곡을 골랐는지">BGM 반응</button>
      <button class="cmf-btn" id="ak_system" onclick="setActKind('system')" title="앱 전환에 따른 프로필 이동 등 자동 동작">자동 전환</button>
      <span class="muted" id="actSummary" style="font-size:12px;margin-left:auto">불러오는 중…</span>
    </div>
    <div class="cmf-row" style="margin:0 0 8px">
      <span style="font-size:12px;color:var(--dim)">분류</span>
      <button class="cmf-btn" id="ac_all" onclick="setActCat('')" title="모든 분류">전체</button>
      <button class="cmf-btn" id="ac_pomodoro" onclick="setActCat('pomodoro')" title="세션 시작·중지, 포모도로 완주, 수확 — 포모도로에 대한 유저 행동">포모도로</button>
      <button class="cmf-btn" id="ac_goal" onclick="setActCat('goal')" title="목표 추가·큐 결정·상태 변경·루프·팀 위임 — 목표설정을 위한 행동">목표설정</button>
      <button class="cmf-btn" id="ac_bgm" onclick="setActCat('bgm')" title="음원 켬/끔·음소거·폭우·싫어요·곡 전환">BGM</button>
      <button class="cmf-btn" id="ac_equipment" onclick="setActCat('equipment')" title="장비 페이지 조작">장비</button>
      <button class="cmf-btn" id="ac_settings" onclick="setActCat('settings')" title="타임존·폴더 열기·창 전환·업데이트 등 설정 조작">설정</button>
    </div>
    <div class="muted" style="font-size:12px;margin:0 0 10px;padding:8px 10px;border:1px solid var(--line);border-radius:9px">
      곡 전환 줄의 <b>풀 칩</b>이 그 곡을 고른 규칙입니다 — <b>폭우 리셋</b> &gt; <b>플랜 · 슬롯</b>(요일·시간대) &gt; <b>모드 · 세션모드</b> 순으로 우선합니다.
      포모도로·루프·트래커가 같은 곡을 낸다면 풀 칩이 전부 <b>플랜 · …</b>으로 찍혀 있을 것입니다(플랜 슬롯이 모드보다 우선이라 모드가 선곡에 반영되지 않는 상태).
    </div>
    <div id="actList"></div>
  </div>

  <!-- 네트워크 진단: 유저가 "사이트가 안 열린다"고 할 때, 그 순간 VPN 상태·머신 네트워크·
       대상 호스트 도달성(DNS→HTTPS)을 앱이 직접 프로브해 스냅샷 1건으로 기록한다. 항상 켜두지
       않고 버튼을 누를 때만 실행(부하 0). 결과는 CSV로 내려받아 티켓에 첨부할 수 있다. -->
  <div class="card" id="diagPanel" style="display:none">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:6px">
      <p class="lbl" style="margin:0">네트워크 진단 · VPN · 호스트 도달성</p>
      <div style="display:flex;gap:8px">
        <button class="btn" id="diagCsv" onclick="downloadDiagCsv()" title="기록된 모든 진단을 CSV로 내려받기">⭳ CSV 다운로드</button>
        <button class="btn" onclick="loadDiagList(true)" title="기록 새로고침">↻ 새로고침</button>
      </div>
    </div>
    <p class="actnote" style="margin:0 0 12px">"사이트가 안 열린다"고 할 때 <b>그 순간</b> VPN이 실제로 올라와 있는지, DNS·라우트가 정상인지, 대상 호스트에 <b>DNS→HTTPS</b> 어느 단계에서 막히는지를 앱이 직접 확인합니다. 브라우저 세션(쿠키·로그인)은 보지 않고, 같은 네트워크에서 같은 호스트에 붙어보는 방식입니다.</p>

    <!-- 대상 호스트 편집 -->
    <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:0 0 12px">
      <span style="font-size:12px;color:var(--dim)">대상 호스트</span>
      <input type="text" id="diagHostsInput" placeholder="hris.must.company, intranet.must.company"
        style="flex:1;min-width:220px;background:#161c28;border:1px solid #2f3a54;color:#e7ecf4;border-radius:8px;padding:7px 10px;font-size:13px"
        onkeydown="if(event.key==='Enter')saveDiagHosts()">
      <button class="btn" onclick="saveDiagHosts()" title="쉼표로 구분해 저장">저장</button>
    </div>

    <div style="text-align:center;margin:6px 0 14px">
      <button id="diagRun" onclick="runDiag()"
        style="background:var(--accent);border:none;color:#0b0f18;border-radius:10px;padding:11px 26px;font-size:14px;font-weight:700;cursor:pointer">▶ 진단 실행</button>
      <div id="diagRunNote" class="muted" style="font-size:12px;margin-top:8px">최근 결과는 아래에 쌓입니다. 실행에는 몇 초 걸릴 수 있습니다.</div>
    </div>

    <div id="diagLatest"></div>
    <div id="diagList" style="margin-top:8px"></div>
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

  <!-- 시스템 로그: 일반 사용자용 화면이 아니다 — 프로덕트 퀄리티 개선 전용. 유저가 매 순간
       어떤 화면을 보고 있었는지(0.5초 view-trace)와 네이티브 창 라이프사이클(실행→창 표시→
       첫 페인트)을 그대로 보여줘, 재현이 어려운 화면 버그(예: 업데이트 후 실행 시 흰 화면)를
       스크린샷 없이 정확한 구간(ms)으로 리포트할 수 있게 한다. 데이터: events/view-trace.jsonl. -->
  <div class="card" id="vtPanel" style="display:none">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:6px">
      <p class="lbl" style="margin:0">시스템 로그 · 화면 추적 (0.5초)</p>
      <div style="display:flex;gap:10px;align-items:center">
        <label style="font-size:12px;color:var(--dim);display:flex;align-items:center;gap:5px;cursor:pointer" title="꺼짐: 같은 화면을 계속 보던 구간을 한 줄로 묶어 보여줍니다">
          <input type="checkbox" id="vtTicks" onchange="renderViewTrace()"> 0.5초 틱 펼치기
        </label>
        <button class="btn" onclick="loadViewTrace()" title="기록 새로고침">↻ 새로고침</button>
      </div>
    </div>
    <p class="actnote" style="margin:0 0 12px">일반 사용 화면이 아닙니다 — <b>프로덕트 퀄리티 개선 전용</b>입니다. 유저가 매 순간 어떤 화면을 보고 있었는지(0.5초 단위)와 앱 창 라이프사이클을 기록해, "실행하니 잠깐 흰 화면이 떴다" 같은 재현 어려운 버그를 스크린샷 없이 정확한 구간으로 잡아냅니다.</p>
    <div id="vtLaunch"></div>
    <div id="vtList" style="margin-top:8px"></div>
  </div>

  <!-- 화면 카탈로그: 앱이 실제로 그린 모든 "화면 상태"를 자동 수집한다 (UX/UI 개선 전용).
       상태 키 = 모드|경로?쿼리키|뷰|플래그 — 쿼리 VALUE는 버려서 문서(goal #12, #34)가 아니라
       화면 레이아웃 단위로 dedupe된다. 상태마다 스크린샷 1장(SCR-ID 고정, 24h 지나면 최신
       모습으로 재촬영)과 목격 횟수·기간, 그리고 관리용 메모·상태 필드를 가진다.
       기본 뷰는 사이트맵(깃북식 트리): UXUI 관리 워커가 main 갱신 시 코드에서 재생성하는
       페이지→서브페이지→상태 계층에 캡처된 SCR 스크린샷을 붙이고 커버리지를 보여준다.
       데이터: <data>/screens/catalog.json + PNG + sitemap.json · API: /api/debug/screens/*. -->
  <div class="card" id="scPanel" style="display:none">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:6px">
      <p class="lbl" style="margin:0">화면 카탈로그 · 사이트맵 + 화면 상태 전수 기록 (UX/UI)</p>
      <div style="display:flex;gap:8px;align-items:center">
        <button class="cmf-btn on" id="scv_map" onclick="setScView('map')" title="깃북식 페이지 트리 — 코드에서 재생성되는 사이트맵에 스크린샷·커버리지를 붙여 봅니다">사이트맵</button>
        <button class="cmf-btn" id="scv_grid" onclick="setScView('grid')" title="수집된 모든 화면 상태를 최근순 그리드로 봅니다">전체 그리드</button>
        <button class="btn" onclick="loadScreens()" title="카탈로그·사이트맵 새로고침">↻ 새로고침</button>
      </div>
    </div>
    <p class="actnote" style="margin:0 0 12px">일반 사용 화면이 아닙니다 — <b>UX/UI 개선 전용</b>입니다. 앱 창이 열려 있는 동안 2초마다 지금 보이는 화면의 상태(페이지·탭·젠/수확/모달 같은 UI 국면)를 식별하고, <b>처음 보는 상태면 자동으로 스크린샷</b>을 남깁니다. 각 화면은 고정 <b>SCR-ID</b>를 가지므로 개선 티켓·리뷰에서 "SCR-0012 화면"처럼 정확히 참조할 수 있습니다. 사이트맵은 <b>UXUI 관리</b> 워커가 main에 새 코드가 올라올 때마다 소스에서 다시 만듭니다.</p>
    <div id="scMapWrap" style="display:flex;gap:14px;align-items:flex-start">
      <div id="scTree" style="flex:0 0 300px;max-width:340px;border:1px solid var(--line);border-radius:12px;padding:10px;font-size:12.5px;line-height:1.5;max-height:70vh;overflow:auto"></div>
      <div id="scNode" style="flex:1;min-width:0"></div>
    </div>
    <div id="scGridWrap" style="display:none">
      <div class="cmf-row" style="margin:0 0 10px">
        <span style="font-size:12px;color:var(--dim)">상태</span>
        <button class="cmf-btn on" id="scf_all" onclick="setScFilter('all')">전체</button>
        <button class="cmf-btn" id="scf_" onclick="setScFilter('')">미검토</button>
        <button class="cmf-btn" id="scf_review" onclick="setScFilter('review')">검토중</button>
        <button class="cmf-btn" id="scf_fix" onclick="setScFilter('fix')">개선필요</button>
        <button class="cmf-btn" id="scf_done" onclick="setScFilter('done')">개선완료</button>
        <span class="muted" id="scSummary" style="font-size:12px;margin-left:auto">불러오는 중…</span>
      </div>
      <div id="scGrid" style="display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px"></div>
    </div>
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
            <!-- clickable: opens the plan-map visualization in the in-page modal -->
            <span style="cursor:pointer" title="플랜 맵 전체 보기" onclick="openPlanModal()">계획 <b id="nowPlan">-</b> <span style="opacity:.55">↗</span></span>
            <span title="전략7 · 지금 선택된 장소·컨디션">장소 <b id="nowVenue">-</b></span>
          </div>
        </div>
      </div>
      <div class="actnote" style="margin-top:12px">
        디렉터가 활동 강도에 맞춰 고른 곡이 여기서 재생되고, 활동이 바뀌면 곡도 자동 전환됩니다.
        <b>재생</b>을 누르면 <b>챌린지가 함께 시작</b>되고(위젯 연동), 메이트의 BGM이 흐릅니다.
        소리가 필요 없을 땐 <b>음소거</b> — 챌린지는 계속 달리고 소리만 꺼집니다.
      </div>
      <!-- 전략7 · 장소·컨디션: 지금 있는 곳/몸 상태를 원탭 선언 → 선곡 풀 재편성.
           마지막 선택은 settings.json에 영속 (재시작·업데이트 생존). -->
      <div style="margin-top:14px">
        <p class="lbl" style="margin:0 0 8px">장소·컨디션
          <span style="font-weight:500;color:var(--dim);font-size:11.5px;letter-spacing:0">— 지금 있는 곳·몸 상태에 맞게 선곡 풀을 재편성합니다 (기본: 2명 사무실 = 자동)</span></p>
        <div class="venuechips" id="venueChips"><span class="tkempty">불러오는 중…</span></div>
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
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
        <div class="statseg" id="statSeg"></div>
        <button class="btn" id="statsReload">↻ 새로고침</button>
        <button class="btn" id="statsReset">초기화</button>
      </div>
    </div>
    <p class="actnote" style="margin:0 0 12px">디렉터가 고른 곡이 실제로 재생된 누적 시간입니다. 특정 곡만 길게 잡히면 여기서 바로 드러납니다. 필터는 선곡 전략별 적립분을 나눠 보여주고, 초기화는 선택된 전략의 기록만 지웁니다.</p>
    <div id="statList" class="ranklist"><div class="tkempty">아직 재생 기록이 없습니다.</div></div>
  </div>

  <!-- 전략 히스토리: BGM 선곡 전략의 변천사(회고). /api/bgm/stats 응답의 strategies로 렌더 —
       데이터(track-playstats.json)에 전략을 추가하면 여기와 위 필터에 그대로 나타난다. -->
  <div class="card" data-bgmcard>
    <p class="lbl" style="margin:0 0 6px">전략 히스토리</p>
    <p class="actnote" style="margin:0 0 12px">선곡 전략의 변천사입니다. 위 순위 필터로 전략별 적립 데이터를 비교하며 회고합니다.</p>
    <div id="stratHist"><div class="tkempty">불러오는 중…</div></div>
  </div>

  <!-- 슬롯 성적표 (전략4 관측): /api/bgm/slot-scores — actions.jsonl을 재생해 파생한
       플랜 슬롯별 hit/miss 점수. 관측 전용(선곡·플랜 무변경), 저장 없음. -->
  <div class="card" data-bgmcard>
    <p class="lbl" style="margin:0 0 6px">슬롯 성적표 (전략4 관측)</p>
    <p class="actnote" style="margin:0 0 12px">플랜 슬롯이 실제로 맞았는지 액션 로그로 채점합니다. hit=부정 신호 없이 세션 종료(포모도로는 완주), miss=싫어요·세션 중 음소거. 세션 3회 이상인데 적중률이 절반 미만이면 재계획 후보로 표시합니다.</p>
    <div id="slotScores"><div class="tkempty">불러오는 중…</div></div>
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

  <!-- main-music level: music only — deliberately its own card, apart from the ambient
       effect layers (비 소리/배기음/환경음) it does not touch -->
  <div class="card" data-bgmcard>
    <div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;margin-bottom:10px">
      <p class="lbl" style="margin:0">메인 음원</p>
    </div>
    <div class="fld"><label>메인 음원 볼륨 <span class="v" id="musicV">100%</span></label>
      <input type="range" id="music" min="0" max="100" value="100"></div>
    <div class="foot">
      <b>곡(음악)</b> 크기만 낮춥니다 — 비 소리·배기음·환경음 같은 <b>사운드 이펙트는 그대로</b> 둔 채,
      카페에서 음악만 줄이듯. (전체 볼륨과 달리 음악에만 적용되고, .wav 저장 결과에는 영향을 주지 않습니다.)
    </div>
  </div>

  <!-- rain ambience (shared) -->
  <div class="card" data-bgmcard>
    <div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;margin-bottom:14px">
      <p class="lbl" style="margin:0">비 소리</p>
      <div class="subtabs" id="rainSeg">
        <button class="subtab on" data-rain="none">없음</button>
        <button class="subtab" data-rain="calm">🌧️ 잔잔한 비</button>
        <button class="subtab" data-rain="shower">🌩️ 소나기·천둥</button>
        <button class="subtab" data-rain="storm">⛈️ 폭우</button>
      </div>
    </div>
    <div class="fld"><label>빗소리 세기 <span class="v" id="rainV">50%</span></label>
      <input type="range" id="rain" min="0" max="100" value="50"></div>
    <div class="foot">
      브라우저에서 실시간 합성한 <b>빗소리</b>를 곡 아래에 깔아줍니다. <b>잔잔한 비</b>는 또렷한 빗방울과 부드러운 쉬 소리,
      <b>폭우</b>는 굵고 세찬 쏟아짐과 거센 빗줄기 소리입니다. <b>소나기·천둥</b>은 지나가는 소나기에 <b>천둥</b>을 얹어, 재생 기준 <b>1시간 중 약 10분은 천둥이 치고 나머지 50분은 소나기만</b> 흐르도록 반복합니다.
      공간 프리셋의 잔향을 함께 타므로 무대와 멀수록 더 넓게 퍼집니다.
      재생 중일 때만 들리고, 원본 파일과 .wav 저장에는 영향을 주지 않습니다.
    </div>
  </div>

  <!-- sports-car exhaust ambience (shared) -->
  <div class="card" data-bgmcard>
    <div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:10px;margin-bottom:10px">
      <p class="lbl" style="margin:0">배기음</p>
      <div class="subtabs" id="exhSeg">
        <button class="subtab on" data-exh="none">없음</button>
        <button class="subtab" data-exh="lambo">🐂 람보르기니</button>
        <button class="subtab" data-exh="porsche">🏁 포르쉐 911</button>
      </div>
    </div>
    <div style="display:flex;align-items:center;justify-content:flex-end;flex-wrap:wrap;gap:10px;margin-bottom:14px">
      <div class="subtabs" id="drvSeg">
        <button class="subtab" data-drv="idle">아이들링</button>
        <button class="subtab on" data-drv="city">시내주행</button>
      </div>
    </div>
    <div class="fld"><label>배기음 세기 <span class="v" id="exhV">40%</span></label>
      <input type="range" id="exh" min="0" max="100" value="40"></div>
    <div class="foot">
      실제 <b>배기음 녹음</b>(심리스 루프 가공)을 곡 아래에 깔아줍니다. <b>람보르기니</b>는 V12 특유의 굵고 건조한 배기 폭발음,
      <b>포르쉐 911</b>은 수평대향(복서) 6기통 특유의 촘촘하고 부글거리는 회전음입니다.
      <b>아이들링</b>은 낮게 웅웅대는 공회전, <b>시내주행</b>은 가속·변속이 섞인 주행 흐름입니다.
      공간 프리셋의 잔향을 함께 타므로 무대와 멀수록 더 넓게 퍼집니다.
      <b>비 소리와 함께</b> 켤 수 있고, 재생 중일 때만 들리며 원본 파일과 .wav 저장에는 영향을 주지 않습니다.
    </div>
  </div>

  <!-- bgm태깅관리 (액티비티 전용 — data-actbottom, 디버그에는 안 보임): 스캔된 라이브러리의
       테마·BPM 태깅 현황을 읽기 전용으로 감사. GET /api/bgm/list의 themes[] 요약으로 렌더. -->
  <div class="card" data-actbottom style="display:none">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap;margin-bottom:6px">
      <p class="lbl" style="margin:0">bgm태깅관리</p>
      <button class="btn" onclick="loadTagAudit(true)" title="라이브러리 태깅 현황 새로고침">↻ 새로고침</button>
    </div>
    <p class="actnote" style="margin:0 0 12px">스캔된 BGM 라이브러리의 테마·BPM 태깅 현황입니다. BPM이 없는 곡은 기본 110으로 폴백해 선곡 정밀도가 낮아지므로, 배지가 붙은 테마부터 태깅을 보강하세요.</p>
    <div class="tagstats" id="tagStats"></div>
    <div id="tagThemes"><div class="tkempty">불러오는 중…</div></div>
  </div>
</div>

<!-- 화면 카탈로그 lightbox: 스크린샷 클릭 → 원본 크기 확대 (배경 클릭으로 닫기) -->
<div id="scLightbox" onclick="this.style.display='none'"
  style="display:none;position:fixed;inset:0;background:rgba(5,8,14,.9);z-index:300;align-items:center;justify-content:center;cursor:zoom-out">
  <img id="scLightImg" alt="화면 스크린샷 확대" style="max-width:94%;max-height:92%;border:1px solid var(--line);border-radius:10px">
</div>

<!-- 플랜 맵 modal: iframe src is set on open / cleared on close so the plan page's
     refresh timer never runs while hidden -->
<div id="planModal" style="display:none; position:fixed; inset:0; z-index:200">
  <div class="pm-back" onclick="closePlanModal()"></div>
  <div class="pm-panel">
    <div class="pm-head"><b>BGM 플랜 맵</b><span style="color:var(--dim);font-size:12px">전략3 · 요일×시간대 계획</span>
      <button class="pm-x" onclick="closePlanModal()">닫기 ✕</button></div>
    <iframe id="planFrame" class="pm-frame" title="BGM 플랜 맵"></iframe>
  </div>
</div>

<script>
\#(CMTimeFilter.tzAssignJS())
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

// ---------- rain profiles (procedural, independent of the venue preset) ----------
// Two layers combine per type: a wideband "sheet/roar" bed (band+low-passed noise) and a
// "droplet" crackle (decaying resonant impulses). The 세기 slider scales the whole thing; the
// venue reverb is shared, so far seats spread the rain wider. calm = distinct drops + soft hiss;
// storm = dense fast patter under a loud, bright roar.
//   bed=bed level · drop=droplet level · bp/bpQ=roar band · lp=air lowpass (bright=near/heavy)
//   gust=bed surge depth · dropHP=droplet highpass · dropRate=droplet playback speed (density/pitch)
// shower = passing 소나기: denser/brighter than calm, pairs with thunder claps (see scheduleThunder).
const RAIN = {
  none:  { name:"없음",       bed:0,    drop:0,    bp:1200, bpQ:0.5, lp:6000,  gust:0,     dropHP:1500, dropRate:1.0  },
  calm:  { name:"잔잔한 비",   bed:0.18, drop:0.16, bp:1300, bpQ:0.6, lp:4200,  gust:0.035, dropHP:2500, dropRate:0.70 },
  shower:{ name:"소나기·천둥", bed:0.52, drop:0.46, bp:1100, bpQ:0.5, lp:8000,  gust:0.16,  dropHP:1500, dropRate:1.05 },
  storm: { name:"폭우",       bed:0.70, drop:0.52, bp:1000, bpQ:0.4, lp:10000, gust:0.24,  dropHP:1300, dropRate:1.18 },
};
let rainType = "none";

// ---------- exhaust profiles (real recorded loops, independent of the venue preset) ----------
// Recorded exhaust clips made seamless offline (tail crossfaded into the head) and installed under
// <data>/sound/exhaust/ — deliberately outside bgm/, the director's selection pool. Each brand ×
// drive mode maps to one loop served same-origin via GET /exhaust-audio/<key> (whitelisted),
// decoded once and looped sample-accurately with a BufferSource into the gated exhaust bus.
// lambo = V12, porsche = flat-6 boxer. (v1 synthesized the engine in Web Audio — replaced
// 2026-07-16 by real recordings; the bus/gate/persistence/export contract is unchanged.)
const EXHAUST = {
  lambo:  { name:"람보르기니", files:{ idle:"lambo-idle",   city:"lambo-city"   } },
  porsche:{ name:"포르쉐 911", files:{ idle:"porsche-idle", city:"porsche-city" } },
};
const EXH_DRIVE = { idle:{}, city:{} };   // valid drive modes (state restore validates against this)
let exhType = "none", exhDrive = "city";

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
  $("histPanel").style.display=(m==='history')?'':'none';
  $("actPanel").style.display=(m==='actions')?'':'none';
  $("actStatus").style.display=(m==='activity')?'':'none';   // 액티비티: 상태가 재생 카드에 합쳐진다
  $("diagPanel").style.display=(m==='diag')?'':'none';
  $("dbgPanel").style.display=(m==='debug')?'':'none';
  $("vtPanel").style.display=(m==='syslog')?'':'none';
  $("scPanel").style.display=(m==='screens')?'':'none';
  // 컨디션맵·히스토리·액션로그·진단·시스템로그·화면카탈로그 모드에선 BGM 재생/디버그 카드를 모두 숨겨 분석에 집중한다.
  document.querySelectorAll('[data-bgmcard]').forEach(el=>{ el.style.display=(m==='map'||m==='history'||m==='actions'||m==='diag'||m==='syslog'||m==='screens')?'none':''; });
  // 액티비티 전용 하단 카드(bgm태깅관리) — 디버그를 포함한 다른 모든 탭에선 숨긴다.
  document.querySelectorAll('[data-actbottom]').forEach(el=>el.style.display=(m==='activity')?'':'none');
  if(m==='activity') loadTagAudit();
  if(m==='map'){ initMap(); if(typeof loadBGMAnalytics==='function') loadBGMAnalytics(); }  // 맵 탭 진입 시 오늘 활동 블록 즉시 갱신(캔버스 폭이 이제 유효)
  if(m==='history') initHistory();
  if(m==='actions') initActions();
  if(m==='diag') initDiag();
  if(m==='syslog') loadViewTrace();
  if(m==='screens') loadScreens();
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

// ---------- 전략7 장소·컨디션 selector ----------
// One-tap venue/condition pick → POST /api/bgm/venue re-pools selection instantly.
// The highlighted chip is the source-of-truth current (server echoes it back), and the
// /api/bgm/now poll below re-syncs the highlight if the pick changes elsewhere.
let venueCur=null;
async function loadVenue(){
  let d=null;
  try{ const r=await fetch('/api/bgm/venue'); d=await r.json(); }catch(e){ return; }
  if(!d||!d.venues) return;
  venueCur=d.current;
  const host=$("venueChips"); host.innerHTML='';
  d.venues.forEach(function(v){
    const b=document.createElement('button');
    b.className='vchip'+(v.key===d.current?' on':'');
    b.title=v.desc+(v.themes.length?(' · 테마 '+v.themes.join('·')+' ('+v.tracks+'곡)'):'')
      +(v.isDefault?' · 기본값':'');
    b.innerHTML=v.emoji+' '+v.label+(v.themes.length?'<span class="vc-n">'+v.tracks+'</span>':'');
    b.onclick=async function(){
      if(v.key===venueCur) return;
      try{ await fetch('/api/bgm/venue',{method:'POST',headers:{'Content-Type':'application/json'},
                       body:JSON.stringify({key:v.key})}); }catch(e){}
      loadVenue();
    };
    host.appendChild(b);
  });
}
loadVenue();

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
  $("nowPlan").textContent    = now.plan||"-";
  $("nowVenue").textContent   = now.venue||"-";
  // 전략7: re-sync the chip highlight if the venue changed out-of-band.
  if(now.venueKey && venueCur && now.venueKey!==venueCur){ loadVenue(); }
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

// ---------- bgm태깅관리 (activity-only audit of the scanned library) ----------
// Read-only render of /api/bgm/list's themes[] summary (theme · count · BPM range over
// resolved tracks · arc 미니 분포 · 선곡 목적 · fallback badge). Cached after the first
// load; the 새로고침 button forces a re-fetch. NO failure banner (workspace rule): on
// fetch error or an empty library we quietly keep the 불러오는 중… state and only log —
// the next tab entry with force, i.e. the manual refresh, retries.
//
// Clicking a theme row toggles a per-track expansion (default collapsed): each track
// renders 제목 · BPM ("—" when bpmResolved is false) · arc 배지 (기/승/전/결/앰비언트)
// · tier · purpose, all from bgm-tags.json joined server-side into tracks[]. When the
// tags file is absent, arc/purpose arrive as "" and the track rows quietly show only
// 제목 · BPM — no banner, the theme-level audit keeps working.
let _tagAudit=null;
let _tagOpen=null;   // Set of expanded theme names — survives refresh re-renders
const ARC_KO={intro:'기',build:'승',peak:'전',resolve:'결',ambient:'앰비언트'};
// "기4·승6·전7·결6" (zeros dropped); an ambient-only theme reads "앰비언트 9".
function arcMini(a){
  if(!a) return '';
  const beats=['intro','build','peak','resolve'].filter(k=>a[k]>0).map(k=>ARC_KO[k]+a[k]);
  if(!beats.length) return a.ambient>0 ? ('앰비언트 '+a.ambient) : '';
  if(a.ambient>0) beats.push(ARC_KO.ambient+a.ambient);
  return beats.join('·');
}
async function loadTagAudit(force){
  if(_tagAudit && !force){ return; }
  let j=null;
  try{ const r=await fetch("/api/bgm/list"); j=await r.json(); }
  catch(e){ console.log("tag audit load failed", e); return; }
  if(!j || !Array.isArray(j.themes) || !j.themes.length){ console.log("tag audit: empty library"); return; }
  _tagAudit=j;
  renderTagAudit(j);
}
function renderTagAudit(j){
  if(!_tagOpen) _tagOpen=new Set();
  const themes=[...j.themes].sort((a,b)=>b.count-a.count);
  const total=themes.reduce((s,t)=>s+t.count,0);
  const resolved=themes.reduce((s,t)=>s+t.resolved,0);
  const fallback=themes.reduce((s,t)=>s+t.fallback,0);
  $("tagStats").innerHTML=[[total,"총 곡수"],[resolved,"BPM 해결"],[fallback,"BPM 없음(폴백)"],[themes.length,"테마 수"]]
    .map(([v,l])=>'<div class="tagstat"><div class="tsv">'+v+'</div><div class="tsl">'+l+'</div></div>').join('');
  const host=$("tagThemes"); host.innerHTML="";
  themes.forEach(t=>{
    // No resolved BPM in the theme (e.g. heavy_rain, beatless ambience) → "—" instead of a range.
    const range=t.resolved ? (t.minBpm===t.maxBpm ? 'BPM '+t.minBpm : 'BPM '+t.minBpm+'–'+t.maxBpm) : 'BPM —';
    const open=_tagOpen.has(t.name);
    const row=document.createElement("div");
    row.className="tagrow"+(open?" open":"");
    const mini=arcMini(t.arc);
    const head=document.createElement("div");
    head.className="tghead";
    head.innerHTML='<span class="tgname">'+esc(t.name)+'</span>'
      +'<span class="tgmeta">'+t.count+'곡 · '+range+'</span>'
      +(t.fallback>0 ? '<span class="tgfb">BPM 없음 '+t.fallback+'곡</span>' : '')
      +(mini ? '<span class="tgarcs">'+mini+'</span>' : '');
    // Toggle expansion; re-render keeps the cheap "build only what's open" model.
    head.onclick=()=>{ open?_tagOpen.delete(t.name):_tagOpen.add(t.name); renderTagAudit(_tagAudit||j); };
    row.appendChild(head);
    if(t.purpose){
      const p=document.createElement("div"); p.className="tgpurpose";
      p.innerHTML=esc(t.purpose); row.appendChild(p);
    }
    if(open){
      const box=document.createElement("div"); box.className="tgtracks";
      (j.tracks||[]).filter(x=>x.theme===t.name).forEach(x=>{
        const tr=document.createElement("div"); tr.className="tgtrk";
        // Untagged track (no tags file / no entry): quietly just 제목 · BPM.
        tr.innerHTML='<span class="tgtn">'+esc(x.title)+'</span>'
          +'<span class="tgtb">'+(x.bpmResolved?x.bpm+' BPM':'—')+'</span>'
          +(x.arc ? '<span class="tgab '+esc(x.arc)+'">'+(ARC_KO[x.arc]||esc(x.arc))+'</span>' : '')
          +(x.tier ? '<span class="tgtier">'+esc(x.tier)+'</span>' : '')
          +(x.purpose ? '<span class="tgtp">'+esc(x.purpose)+'</span>' : '');
        box.appendChild(tr);
      });
      row.appendChild(box);
    }
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
let rainBus, rainLevel, rainDry, rainWet;
let rainSrc, rainBP, rainLP, rainBed, rainGustMod;
let dropSrc, dropHP, dropGain;
let thunderBus, thunderBuf;
let thunderTimer = null, thunderAnchor = -1;   // anchor = ctx time when 소나기·천둥 began (storm-cycle phase)
let exhBus, exhLevel, exhDry, exhWet;
let exhSrc = null, exhSrcKey = null, exhLoadSeq = 0;
const exhBufCache = {};   // key -> decoded AudioBuffer (4 × ~10s loops — small enough to keep)
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
// A long, seamlessly-looping bed of individual rain droplets: many short, exponentially-decaying
// noise bursts scattered at random positions (decorrelated L/R for a natural stereo patter). The
// looped result reads as steady droplet crackle; playbackRate/highpass/gain then shape it per type.
function makeDroplets(context, sec){
  const sr = context.sampleRate, len = Math.floor(sec*sr);
  const buf = context.createBuffer(2, len, sr);
  const count = Math.floor(sec*14);            // ~14 baked drops/sec (density trimmed per type later)
  for(let ch=0; ch<2; ch++){
    const d = buf.getChannelData(ch);
    for(let n=0;n<count;n++){
      const pos = Math.floor(Math.random()*len);
      const dur = Math.floor((0.004+Math.random()*0.018)*sr);   // 4–22 ms tick
      const amp = 0.45+Math.random()*0.55;
      const decay = 3+Math.random()*4;
      for(let k=0;k<dur && pos+k<len;k++){
        d[pos+k] += (Math.random()*2-1)*Math.exp(-decay*k/dur)*amp;
      }
    }
    let peak=1e-6; for(let i=0;i<len;i++) peak=Math.max(peak,Math.abs(d[i]));
    const g=0.8/peak; for(let i=0;i<len;i++) d[i]*=g;
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
  buildRain();
  buildExhaust();
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

// Synthesize the rain bed (roar + droplets) on its own gated bus, mixed dry (enveloping) and wet
// (through the venue reverb) just like the ambience. Silent until applyRain() opens the gate.
function buildRain(){
  rainBus   = ctx.createGain(); rainBus.gain.value=1;
  rainLevel = ctx.createGain(); rainLevel.gain.value=0;    // gated: 0 until a rain type is playing
  rainDry   = ctx.createGain(); rainDry.gain.value=0.85;
  rainWet   = ctx.createGain(); rainWet.gain.value=0.5;

  // Sheet/roar bed: looped noise → bandpass (rain "shhh") → lowpass (air) → gain, with a slow gust.
  rainSrc = ctx.createBufferSource(); rainSrc.buffer=makeNoise(ctx,4.0); rainSrc.loop=true;
  rainBP  = ctx.createBiquadFilter(); rainBP.type="bandpass"; rainBP.frequency.value=1200; rainBP.Q.value=0.5;
  rainLP  = ctx.createBiquadFilter(); rainLP.type="lowpass";  rainLP.frequency.value=6000; rainLP.Q.value=0.5;
  rainBed = ctx.createGain(); rainBed.gain.value=0;
  rainSrc.connect(rainBP); rainBP.connect(rainLP); rainLP.connect(rainBed); rainBed.connect(rainBus);
  rainGustMod = attachLFO(ctx, rainBed.gain, 0, 0, 0.06, 0.083);   // base+depth set per rain type

  // Droplet crackle: looped droplet buffer → highpass (keep the ticks) → gain.
  dropSrc  = ctx.createBufferSource(); dropSrc.buffer=makeDroplets(ctx,8.0); dropSrc.loop=true;
  dropHP   = ctx.createBiquadFilter(); dropHP.type="highpass"; dropHP.frequency.value=1500; dropHP.Q.value=0.5;
  dropGain = ctx.createGain(); dropGain.gain.value=0;
  dropSrc.connect(dropHP); dropHP.connect(dropGain); dropGain.connect(rainBus);

  // Thunder claps route through the rain bus, so they obey 빗소리 세기 and sit in the venue reverb.
  thunderBus = ctx.createGain(); thunderBus.gain.value=1;
  thunderBus.connect(rainBus);
  thunderBuf = makeNoise(ctx, 3.0);

  rainBus.connect(rainLevel);
  rainLevel.connect(rainDry); rainDry.connect(masterGain);   // enveloping, obeys 전체 볼륨
  rainLevel.connect(rainWet); rainWet.connect(convolver);    // shares the venue reverb

  rainSrc.start(); dropSrc.start();
  scheduleThunder();
}

// The exhaust bus: recorded loops join dry (enveloping) and wet (through the venue reverb)
// exactly like rain/ambience. Silent until applyExhaust() opens the gate.
function buildExhaust(){
  exhBus   = ctx.createGain(); exhBus.gain.value=1;
  exhLevel = ctx.createGain(); exhLevel.gain.value=0;    // gated: 0 until a car is selected + playing
  exhDry   = ctx.createGain(); exhDry.gain.value=0.8;
  exhWet   = ctx.createGain(); exhWet.gain.value=0.35;
  exhBus.connect(exhLevel);
  exhLevel.connect(exhDry); exhDry.connect(masterGain);   // enveloping, obeys 전체 볼륨 + mute
  exhLevel.connect(exhWet); exhWet.connect(convolver);    // shares the venue reverb
}

function exhKey(){ const e=EXHAUST[exhType]; return e ? e.files[exhDrive] : null; }
function exhStopVoice(){
  if(exhSrc){ try{ exhSrc.stop(); }catch(e){} try{ exhSrc.disconnect(); }catch(e){} }
  exhSrc=null; exhSrcKey=null;
}
// Make sure the right loop is feeding the gated bus. Each file is fetched + decoded once (cached);
// a load that finishes after the selection changed is dropped, not started. Failures are silent —
// the gate simply sits over silence and the next selection retries (no user-facing failure).
async function exhEnsureVoice(){
  const key=exhKey(); if(!key || !ctx) return;
  if(exhSrc && exhSrcKey===key) return;                  // already looping the right file
  const seq=++exhLoadSeq;
  let buf=exhBufCache[key];
  if(!buf){
    try{
      const r=await fetch("/exhaust-audio/"+key);
      if(!r.ok) return;
      buf=await ctx.decodeAudioData(await r.arrayBuffer());
      exhBufCache[key]=buf;
    }catch(e){ return; }
  }
  if(seq!==exhLoadSeq || exhKey()!==key) return;         // superseded while loading
  exhStopVoice();
  exhSrc=ctx.createBufferSource(); exhSrc.buffer=buf; exhSrc.loop=true;
  exhSrc.connect(exhBus);
  exhSrc.start(0, Math.random()*buf.duration);           // random phase so re-entries don't repeat
  exhSrcKey=key;
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

// One thunder strike: a bright crack collapsing into a rolling low rumble, synthesized from a
// fresh short-lived noise voice. Routes into the rain bus, so it obeys 빗소리 세기 + venue reverb.
function fireThunder(){
  if(!ctx || !thunderBus) return;
  const t = ctx.currentTime;
  const src = ctx.createBufferSource(); src.buffer=thunderBuf; src.loop=true;
  src.playbackRate.value = 0.7 + Math.random()*0.5;
  const hp = ctx.createBiquadFilter(); hp.type="highpass"; hp.frequency.value=28;
  const lp = ctx.createBiquadFilter(); lp.type="lowpass";
  const g  = ctx.createGain(); g.gain.value=0.0001;
  src.connect(hp); hp.connect(lp); lp.connect(g); g.connect(thunderBus);

  const peak = 1.6 + Math.random()*1.6;                 // loud transient (rainLevel scales it back)
  const dur  = 3.0 + Math.random()*3.5;
  lp.frequency.setValueAtTime(2200, t);                 // crack …
  lp.frequency.exponentialRampToValueAtTime(240, t+0.5);
  lp.frequency.exponentialRampToValueAtTime(80,  t+dur);// … into a low rumble
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(peak, t+0.035);   // sharp attack
  g.gain.exponentialRampToValueAtTime(peak*0.35, t+0.6);
  g.gain.exponentialRampToValueAtTime(peak*0.55, t+0.9+Math.random()*0.7);  // a rolling swell
  g.gain.exponentialRampToValueAtTime(0.0001, t+dur);   // long decay
  src.start(t); src.stop(t+dur+0.1);                    // voice is GC'd after it stops
}

// Storm cycle for 소나기·천둥: ~10 min of thunder, then ~50 min shower-only, repeating each hour.
// Phase is measured from thunderAnchor in ctx time — which pauses when the context suspends, so the
// cycle tracks actual listening time and starts thundering right when the mode is selected.
function scheduleThunder(){
  clearTimeout(thunderTimer);
  const wait = 9000 + Math.random()*18000;              // 9–27s between strikes while active
  thunderTimer = setTimeout(()=>{
    if(ctx && rainType==="shower" && thunderAnchor>=0 && !audioEl.paused
       && ((ctx.currentTime - thunderAnchor) % 3600) < 600){
      fireThunder();
    }
    scheduleThunder();
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

// Tune the rain layer from the selected type + 세기 slider, and gate it to playback.
function applyRain(){
  if(!ctx || !rainBus) return;
  const r = RAIN[rainType] || RAIN.none;
  const pct = +$("rain").value/100;
  // Storm-cycle phase: start the 10-min thunder window when 소나기·천둥 begins; reset when it leaves.
  if(rainType==="shower"){ if(thunderAnchor<0) thunderAnchor = ctx.currentTime; }
  else thunderAnchor = -1;
  rainBP.frequency.value = r.bp; rainBP.Q.value = r.bpQ;
  rainLP.frequency.value = r.lp;
  rainGustMod.setBase(r.bed); rainGustMod.setDepth(r.bed*r.gust);
  dropGain.gain.value = r.drop;
  dropHP.frequency.value = r.dropHP;
  dropSrc.playbackRate.value = r.dropRate;

  const on = rainType!=="none" && pct>0 && !audioEl.paused;
  const t = ctx.currentTime;
  rainLevel.gain.cancelScheduledValues(t);
  rainLevel.gain.setTargetAtTime(on?pct:0, t, 0.4);         // smooth fade in/out
}

// Gate the exhaust loop to the selection + 세기 slider + playback, swapping the loop file when
// the car or drive mode changes (the voice keeps looping muted through a pause, like rain).
function applyExhaust(){
  if(!ctx || !exhBus) return;
  const e = EXHAUST[exhType];
  const pct = +$("exh").value/100;
  if(e){ exhEnsureVoice(); }
  else { exhLoadSeq++; exhStopVoice(); }                    // 없음: stop the voice, drop stale loads
  const on = !!e && pct>0 && !audioEl.paused;
  const t = ctx.currentTime;
  exhLevel.gain.cancelScheduledValues(t);
  exhLevel.gain.setTargetAtTime(on?pct:0, t, 0.4);          // smooth fade in/out
}

// Main music (곡) volume — scales the track alone via inGain (the only node the music passes
// through; rain/환경음 join downstream at masterGain/convolver). Lets you turn the music down
// while keeping rain/ambience up — the "카페에서 음악만 줄이기" effect. 전체 볼륨(masterGain)과 별개.
function applyMusic(){
  if(!ctx || !inGain) return;
  inGain.gain.value = +$("music").value/100;
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
  applyMusic();
  applyAmbience();
  applyRain();
  applyExhaust();
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
    level: { amb:+$("amb").value, vol:+$("vol").value, music:+$("music").value },
    rain: { type: rainType, level: +$("rain").value },
    exhaust: { type: exhType, drive: exhDrive, level: +$("exh").value }
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
  $("rainV").textContent = $("rain").value+"%";
  $("musicV").textContent = $("music").value+"%";
  $("exhV").textContent  = $("exh").value+"%";
  ["dist","wet","wid","hc","lc","shp","duck","amb","vol","rain","music","exh","seek"].forEach(id=>{
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
// 비 소리 type selector + 세기 slider (independent of venue preset / 환경음 toggle).
function reflectRain(){
  [...$("rainSeg").querySelectorAll('.subtab')].forEach(b=>b.classList.toggle('on', b.dataset.rain===rainType));
}
[...$("rainSeg").querySelectorAll('.subtab')].forEach(b=>{
  b.onclick=()=>{ rainType=b.dataset.rain; reflectRain(); applyRain(); saveState(); };
});
$("rain").addEventListener("input",()=>{ syncLabels(); applyRain(); saveState(); });
$("music").addEventListener("input",()=>{ syncLabels(); applyMusic(); saveState(); });
// 배기음 car + drive-mode selectors + 세기 slider (independent of venue preset / 비 소리).
function reflectExhaust(){
  [...$("exhSeg").querySelectorAll('.subtab')].forEach(b=>b.classList.toggle('on', b.dataset.exh===exhType));
  [...$("drvSeg").querySelectorAll('.subtab')].forEach(b=>b.classList.toggle('on', b.dataset.drv===exhDrive));
}
[...$("exhSeg").querySelectorAll('.subtab')].forEach(b=>{
  b.onclick=()=>{ exhType=b.dataset.exh; reflectExhaust(); applyExhaust(); saveState(); };
});
[...$("drvSeg").querySelectorAll('.subtab')].forEach(b=>{
  b.onclick=()=>{ exhDrive=b.dataset.drv; reflectExhaust(); applyExhaust(); saveState(); };
});
$("exh").addEventListener("input",()=>{ syncLabels(); applyExhaust(); saveState(); });
$("reload").onclick=loadTracks;

// ---------- play-time ranking ----------
function fmtDur(s){
  s=Math.max(0,Math.round(s));
  const h=Math.floor(s/3600), m=Math.floor((s%3600)/60), ss=s%60;
  if(h>0) return h+"시간 "+m+"분";
  if(m>0) return m+"분 "+ss+"초";
  return ss+"초";
}
// Strategy filter state. statStrat is null until the first response reveals the ACTIVE
// strategy (a query-less fetch defaults to it server-side); afterwards 0=전체, N=전략N.
// The strategy catalog (statStrategies) drives both the filter buttons and the 전략
// 히스토리 section, so adding 전략3 to the store shows up here with no UI change.
let statStrat=null, statActive=2, statStrategies=[];
function statSegRender(){
  const seg=$("statSeg"); if(!seg) return;
  const cur=(statStrat==null)?statActive:statStrat;
  const items=[{id:0,label:"전체"}].concat(statStrategies.map(s=>({id:s.id,label:"전략"+s.id})));
  seg.innerHTML="";
  items.forEach(it=>{
    const b=document.createElement("button");
    b.textContent=it.label;
    b.title=it.id===0?"모든 전략 합산":("전략"+it.id+" 적립분만");
    if(cur===it.id) b.classList.add("on");
    b.onclick=()=>{ statStrat=it.id; statSegRender(); loadStats(); };
    seg.appendChild(b);
  });
}
// 플랜 맵 modal (전략3). iframe src is only alive while open so the embedded
// /bgm-plan page's 60s refresh never runs in the background.
function openPlanModal(){
  $("planFrame").src="/bgm-plan";
  $("planModal").style.display="block";
}
function closePlanModal(){
  $("planModal").style.display="none";
  $("planFrame").src="about:blank";
}
document.addEventListener("keydown", e=>{
  if(e.key==="Escape" && $("planModal").style.display!=="none") closePlanModal();
});

function renderStrategies(){
  const host=$("stratHist"); if(!host) return;
  if(!statStrategies.length){ host.innerHTML='<div class="tkempty">전략 정보가 없습니다.</div>'; return; }
  host.innerHTML="";
  statStrategies.forEach(s=>{
    const live=!s.end;
    const period=(s.start?s.start:"")+" ~ "+(s.end?s.end+" 종료":"");
    const row=document.createElement("div");
    row.className="strat"+(live?" live":"");
    // 전략3(플랜 맵)은 계획 데이터가 계속 바뀌므로, 현재 계획을 시각화하는 /bgm-plan
    // 페이지로 가는 버튼을 전략 항목 자체에 붙인다 (now 카드의 계획 칩보다 안정적인 진입점).
    row.innerHTML='<div class="sthead"><span class="stname">전략'+s.id+' · '+esc(s.name)+'</span>'
      +'<span class="stperiod">'+esc(period)+'</span>'
      +(live?'<span class="stlive">진행 중</span>':'')
      +(s.id===3?'<button class="stbtn" onclick="openPlanModal()">플랜 맵 보기</button>':'')
      +'</div>'
      +'<div class="stsum">'+esc(s.summary)+'</div>'
      +(s.retro?'<div class="stretro">회고 · '+esc(s.retro)+'</div>':'');
    host.appendChild(row);
  });
}
async function loadStats(){
  const host=$("statList"); if(!host) return;
  let j=null;
  const q=(statStrat==null)?"":("?strategy="+statStrat);
  try{ const r=await fetch("/api/bgm/stats"+q); j=await r.json(); }catch(e){}
  if(!j){ host.innerHTML='<div class="tkempty">재생 기록을 불러오지 못했습니다.</div>'; return; }
  if(typeof j.activeStrategy==="number") statActive=j.activeStrategy;
  if(statStrat==null) statStrat=(typeof j.strategy==="number")?j.strategy:statActive;
  statStrategies=j.strategies||[];
  statSegRender(); renderStrategies();
  if(!j.tracks || !j.tracks.length){
    host.innerHTML='<div class="tkempty">'+(statStrat>0
      ?'전략'+statStrat+' 데이터 적립 중 —<br>이 전략으로 재생되는 곡의 시간이 여기에 쌓입니다.'
      :'아직 재생 기록이 없습니다.<br>BGM이 재생되면 곡별 누적 재생 시간이 여기에 쌓입니다.')+'</div>';
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
// 초기화 scopes to the SELECTED filter: 전략N view wipes only that strategy's rows,
// 전체 wipes every strategy. (Previously it always wiped everything.)
$("statsReset").onclick=()=>{
  const n=(statStrat==null)?statActive:statStrat;
  const msg=n>0
    ?("전략"+n+"의 곡별 재생 시간 기록만 초기화할까요?\n(다른 전략의 기록은 유지됩니다)")
    :"모든 전략의 곡별 재생 시간 기록을 초기화할까요?";
  if(!confirm(msg)) return;
  fetch("/api/bgm/stats/reset",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({strategy:n})}).then(()=>loadStats()).catch(()=>{});
};
loadStats();
setInterval(loadStats, 5000);

// ---------- 슬롯 성적표 (전략4 관측) ----------
// Renders /api/bgm/slot-scores: per-plan-slot hit/miss derived from actions.jsonl.
// Neutral tones only (no red/green status colors); times go through CMTimeFilter.
const SLOT_DAYS_KO={mon:"월",tue:"화",wed:"수",thu:"목",fri:"금",sat:"토",sun:"일",weekday:"평일",weekend:"주말",all:"매일"};
function slotWhen(t){ return CMTimeFilter.dayStr(t*1000)+" "+CMTimeFilter.hhmm(t); }
async function loadSlotScores(){
  const host=$("slotScores"); if(!host) return;
  let j=null;
  try{ const r=await fetch("/api/bgm/slot-scores"); j=await r.json(); }catch(e){}
  if(!j || !Array.isArray(j.slots)){ host.innerHTML='<div class="tkempty">슬롯 성적을 불러오지 못했습니다.</div>'; return; }
  if(!j.slots.length){
    host.innerHTML='<div class="tkempty">아직 채점할 세션이 없습니다.<br>플랜 슬롯에서 세션이 진행되면 슬롯별 성적이 여기에 쌓입니다.</div>';
    return;
  }
  host.innerHTML="";
  j.slots.forEach(s=>{
    const row=document.createElement("div");
    row.className="slotrow";
    const dayKo=SLOT_DAYS_KO[s.days]||s.days||"";
    const band=(s.from&&s.to)?(s.from+"–"+s.to):"";
    const meta=[dayKo,band].filter(Boolean).join(" ")+(s.themes&&s.themes.length?" · "+s.themes.join("/"):"");
    const ratePct=Math.round((s.hitRate||0)*100);
    const scored=(s.hits+s.misses)>0;
    const subs=[];
    if(s.sampleTracks&&s.sampleTracks.length) subs.push("hit 근거 곡 · "+s.sampleTracks.map(esc).join(" · "));
    const stamps=[];
    if(s.lastHitAt) stamps.push("최근 hit "+slotWhen(s.lastHitAt));
    if(s.lastMissAt) stamps.push("최근 miss "+slotWhen(s.lastMissAt));
    if(stamps.length) subs.push(stamps.join(" · "));
    row.innerHTML='<div class="slhead"><span class="slname">'+esc(s.label)+'</span>'
      +(meta?'<span class="slmeta">'+esc(meta)+'</span>':'')
      +(s.rePlanCandidate?'<span class="slreplan">재계획 후보</span>':'')
      +'<span class="slnums">세션 '+s.sessions+' · hit <b>'+s.hits+'</b> · miss <b>'+s.misses+'</b>'
      +' · 점수 <b>'+s.score+'</b>'+(scored?' · 적중률 <b>'+ratePct+'%</b>':'')+'</span></div>'
      +'<div class="slbarwrap"><div class="slbar" style="width:'+(scored?Math.max(ratePct,3):0)+'%"></div></div>'
      +(subs.length?'<div class="slsub">'+subs.join("<br>")+'</div>':'');
    host.appendChild(row);
  });
}
loadSlotScores();
setInterval(loadSlotScores, 30000);

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
function hhmm(t){ return CMTimeFilter.hhmm(t); }   // 표시 타임존 기준 HH:MM
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
function minOfDay(s){ const p=CMTimeFilter.parts(s.t*1000); return p.h*60+p.mi; }
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
audioEl.addEventListener("play", ()=>{ nativeMute(true); updatePlayIcon(); applyAmbience(); applyRain(); applyExhaust(); stopAutoStart();
  $("status").textContent="재생 중 · "+(curTrack?curTrack.title:"")+" · "+PRESETS[current].name; });
audioEl.addEventListener("pause",()=>{ nativeMute(false); updatePlayIcon(); applyAmbience(); applyRain(); applyExhaust(); });
audioEl.addEventListener("ended",()=>{ nativeMute(false); updatePlayIcon(); applyAmbience(); applyRain(); applyExhaust(); });
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
      if(st.level.music!=null) $("music").value = st.level.music;
    }
    if(st.rain){                                                  // rain is preset-independent too
      if(st.rain.type && RAIN[st.rain.type]) rainType = st.rain.type;
      if(st.rain.level!=null) $("rain").value = st.rain.level;
    }
    if(st.exhaust){                                               // exhaust is preset-independent too
      if(st.exhaust.type && EXHAUST[st.exhaust.type]) exhType = st.exhaust.type;
      if(st.exhaust.drive && EXH_DRIVE[st.exhaust.drive]) exhDrive = st.exhaust.drive;
      if(st.exhaust.level!=null) $("exh").value = st.exhaust.level;
    }
  } else { setPresetControls(current); }
}catch(e){ setPresetControls(current); }
reflectRain();
reflectExhaust();
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
    presets:['today','yesterday','7d','30d','90d'], auto:true, custom:true, initial:'auto',
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
function clock(t){ return CMTimeFilter.hhmm(t); }   // 표시 타임존 기준 HH:MM

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
  // 띠 클릭 → 액션로그 드릴다운. 24h 창이 자정을 넘으면 두 날짜에 걸치므로 범위로 넘긴다.
  const d1=localDayStr(band.startT), d2=localDayStr(band.startT+MAP_DAY-60);
  return '<div class="mapband" title="이 업무일의 액션로그 보기" onclick="mapDrill(\''+d1+'\',\''+d2+'\')">'+cells+marks+'</div><div class="mapaxis">'+axis+'</div>';
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
    // 다일 범위: 시작~끝 각 날짜를 한 행씩 (최신순, 띠 표시는 최대 31행)
    const list=[]; let d=_mapRange.end;
    while(d>=_mapRange.start && list.length<400){ list.push(d); d=CMTimeFilter.dayStr(new Date(CMTimeFilter.parseDay(d).getTime()-43200000)); }   // 자정-12h=전날 정오 → 하루 뒤로 (DST 안전)
    days=list;
  }
  // 다일 렌더 — 요약(누적·평균)은 기간 전체로 계산하고, 띠는 최근 31일만 그린다.
  const bands=[];
  days.forEach(day=>{ const st=startForDay(day, cands, active); if(st!=null) bands.push({day, band:buildBand(st, all, nowT)}); });
  if(!bands.length){ $("mapSummary").innerHTML=''; $("mapBody").innerHTML='<div class="tkempty">기간 내 활동 기록이 없습니다.</div>'; return; }
  const totalWork=bands.reduce((a,b)=>a+b.band.elapsedHours,0);
  const avgWork=totalWork/bands.length;
  const avgLv=bands.reduce((a,b)=>a+b.band.avgLevel,0)/bands.length;
  $("mapSummary").innerHTML = card('업무일', bands.length+'일')
    + card('누적 업무시간', totalWork.toFixed(1)+'h', '기준 합 '+(bands.length*_mapBase)+'h')
    + card('평균 업무시간', avgWork.toFixed(1)+'h', '기준 '+_mapBase+'h')
    + card('평균 컨디션', 'Lv '+avgLv.toFixed(1), levelName(avgLv));
  const rows=bands.slice(0,31).map(x=>{
    const b=x.band;
    const wk=CMTimeFilter.weekdayKo(b.startT*1000);
    return '<div class="maprow"><div class="rl"><b>'+x.day+' ('+wk+')</b>'
      +'<span class="rr">시작 '+clock(b.startT)+' · '+b.elapsedHours.toFixed(1)+'h · Lv '+b.avgLevel.toFixed(1)+'</span></div>'
      + bandHTML(b, nowT, x.day===todayStr) + '</div>';
  }).join('');
  const note=bands.length>31?'<div class="tkempty" style="text-align:left">띠는 최근 31일만 표시합니다 (요약은 업무일 '+bands.length+'일 전체 기준).</div>':'';
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

// ======================= 액션로그 (대시보드에서 이동) =======================
// 모든 유저 액션 + BGM 반응 타임라인. 데이터/실시간(SSE)은 /api/actions 계열,
// 기간 필터는 컨디션맵과 같은 CMTimeFilter를 공유한다('자동'=최근 전체).
// actCat/renderActions는 .e2e/actioncat.test.js 가 이 파일에서 추출해 검증하므로
// 상태 let 선언은 ACT_LABEL 앞에, actPad~renderActions는 종료 마커 앞에 둔다.
let _actInited=false, _actCtl=null, _actRange={mode:'auto',preset:'auto',start:'',end:''};
let _actEvents=null, _actKind='', _actCat='', _actFetchedAt=0, _actFetchedLimit=0, _actLoading=false, _actRenderedSig='';
const ACT_LABEL={ sessionStart:'세션 시작', sessionStop:'세션 중지', modeChange:'모드 변경',
  mute:'음소거 켬', unmute:'음소거 해제', bgmOn:'BGM 켬', bgmOff:'BGM 끔',
  profileShift:'프로필 전환', rainSummon:'폭우 소환', rainStart:'폭우 시작',
  rainEnd:'폭우 종료', dislike:'싫어요', trackChange:'곡 전환', opener:'오프너 재생',
  startContext:'시작 컨텍스트',
  // 대시보드 POST 자동 로깅(경로 유도 이름) — 미등록 이름은 원문 그대로 표시된다
  'pomodoro.complete':'포모도로 완주', 'pomodoro.harvest':'포모도로 수확',
  'goal.add':'목표 추가', 'goal.queue.add':'나중에 검토', 'goal.queue.enqueue':'AI 목표 추가',
  'goal.queue.search':'AI 검색', 'goal.queue.resolve':'큐 결정', 'goal.queue.undo':'큐 번복',
  'goal.queue.refine':'큐 다듬기', 'goal.queue.cli':'큐 CLI', 'queue.retry':'큐 재시도',
  'queue.remove':'큐 제거', 'queue.enqueue-linkmap':'링크맵 큐 등록',
  'goal.remove':'목표 삭제', 'goal.note':'노트 수정', 'goal.parent':'목표 이동',
  'goal.reorder':'순서 변경', 'goal.status':'상태 변경', 'goal.archive':'보관',
  'goal.reopen':'다시 열기', 'goal.title':'제목 수정', 'goal.task':'부분과제 추가',
  'goal.energy':'에너지 설정', 'goal.tokens':'토큰 기록', 'goal.value':'가치 설정',
  'goal.priority':'우선순위 변경', 'goal.target':'목표일 설정', 'goal.completed':'완료 처리',
  'goal.sprint':'루프 배정', 'goal.bump':'범프', 'goal.link':'목표 연결',
  'goal.unlink':'연결 해제', 'goal.connect':'세션 연결(파일)', 'goal.session.link':'세션 연결',
  'goal.session.unlink':'세션 해제', 'goal.definition.save':'정의 저장',
  'goal.chat.send':'채팅 전송', 'goal.chat.reset':'채팅 리셋', 'goal.chat2.say':'팀 채팅',
  'goal.chat2.stop':'팀 채팅 중단', 'goal.aiChat':'AI 채팅', 'goal.aiSearch':'AI 검색(구)',
  'goal.cli.start':'CLI 시작', 'goal.cli.stop':'CLI 중단',
  'chat.send':'채팅 전송', 'chat.reset':'채팅 리셋', 'team.delegate':'팀 위임',
  'sprint.create':'루프 생성', 'sprint.update':'루프 수정',
  'sprint.delete':'루프 삭제', 'sprint.cleanup':'루프 정리',
  'settings.timezone':'타임존 변경', 'settings.reveal':'폴더 열기',
  'window.mode':'창 전환', 'bgm.plan':'플랜 저장', 'bgm.stats.reset':'통계 리셋',
  'skills.summary':'스킬 요약', 'skills.folder':'스킬 폴더', 'skills.folder.pick':'스킬 폴더 선택',
  'skills.reveal':'스킬 폴더 열기', 'agents.reveal':'에이전트 폴더 열기' };
const ACT_MODE={ pomodoro:'25분', sprint:'루프', unlimited:'트래커' };
// 분류(도메인 축) — 서버가 cat을 안 준 옛 라인은 액션 이름으로 유도(서버의
// ActionLog.defaultCategory와 같은 규칙).
const ACT_CAT_LABEL={ pomodoro:'포모도로', goal:'목표설정', bgm:'BGM', equipment:'장비', settings:'설정', other:'기타' };
function actCat(e){ if(e.cat) return e.cat;
  if(e.action==='sessionStart'||e.action==='sessionStop'||e.action==='modeChange') return 'pomodoro';
  if(e.action==='updateRun') return 'settings';
  return 'bgm'; }
function setActKind(k){ _actKind=k; reflectActKind(); renderActions(); }
function reflectActKind(){ [['ak_all',''],['ak_user','user'],['ak_bgm','bgm'],['ak_system','system']]
  .forEach(p=>{ const b=$(p[0]); if(b) b.classList.toggle('on', _actKind===p[1]); }); }
function setActCat(c){ _actCat=c; reflectActCat(); renderActions(); }
function reflectActCat(){ [['ac_all',''],['ac_pomodoro','pomodoro'],['ac_goal','goal'],['ac_bgm','bgm'],['ac_equipment','equipment'],['ac_settings','settings']]
  .forEach(p=>{ const b=$(p[0]); if(b) b.classList.toggle('on', _actCat===p[1]); }); }
// ---------- 네트워크 진단 (on-demand VPN/host reachability probe) ----------
let _diagInited=false;
function diagTime(t){ try{ const p=CMTimeFilter.parts(t*1000); return p.y+'-'+p.mo+'-'+p.d+' '+p.h+':'+p.mi+':'+p.s; }catch(e){ return ''+t; } }
function initDiag(){
  if(_diagInited){ loadDiagList(); return; }
  _diagInited=true;
  loadDiagHosts();
  loadDiagList();
}
function loadDiagHosts(){
  fetch('/api/settings/diag-hosts').then(r=>r.json()).then(function(j){
    $("diagHostsInput").value=(j.hosts||[]).join(', ');
  }).catch(function(){});
}
function saveDiagHosts(){
  const hosts=$("diagHostsInput").value.split(',').map(s=>s.trim()).filter(Boolean);
  fetch('/api/settings/diag-hosts',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({hosts:hosts})})
    .then(r=>r.json()).then(function(j){ $("diagHostsInput").value=(j.hosts||[]).join(', ');
      $("diagRunNote").textContent='대상 호스트를 저장했습니다.'; }).catch(function(){});
}
function runDiag(){
  const btn=$("diagRun"); btn.disabled=true; const old=btn.textContent; btn.textContent='진단 중…';
  $("diagRunNote").textContent='VPN·네트워크·호스트 도달성을 확인하는 중입니다…';
  fetch('/api/debug/diag/run',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})
    .then(r=>r.json()).then(function(snap){
      $("diagLatest").innerHTML='<div class="lbl" style="margin:0 0 8px">방금 실행</div>'+renderDiagSnapshot(snap,true);
      $("diagRunNote").textContent='완료. 아래 기록에도 저장되었습니다.';
      loadDiagList(true);
    }).catch(function(){ $("diagRunNote").textContent='진단 실행에 실패했습니다.'; })
    .finally(function(){ btn.disabled=false; btn.textContent=old; });
}
function loadDiagList(force){
  fetch('/api/debug/diag/list').then(r=>r.json()).then(function(j){
    const arr=j.snapshots||[];
    if(!arr.length){ $("diagList").innerHTML='<div class="muted" style="font-size:12px;padding:8px 0">아직 진단 기록이 없습니다. 위 버튼으로 실행해 보세요.</div>'; return; }
    $("diagList").innerHTML='<div class="lbl" style="margin:14px 0 8px">기록 ('+arr.length+')</div>'+arr.map(s=>renderDiagSnapshot(s,false)).join('');
  }).catch(function(){});
}
function diagStepBadge(ok,label){ const c=ok?'#36c08a':'#e05a5a'; return '<span style="display:inline-block;font-size:11px;font-weight:700;color:'+c+';border:1px solid '+c+';border-radius:6px;padding:1px 7px">'+esc(label)+'</span>'; }
function renderDiagSnapshot(s,open){
  const vpn=s.vpnActive;
  const vpnChip='<span style="font-weight:700;color:'+(vpn?'#36c08a':'#e0a13a')+'">'+(vpn?'VPN 감지됨':'VPN 미감지')+'</span>';
  const hosts=(s.hosts||[]).map(function(h){
    const dns=diagStepBadge(h.dnsOk,'DNS '+(h.dnsOk?(h.dnsMs+'ms'):'실패'));
    const httpLabel=h.httpOk?('HTTP '+h.status+' · '+h.httpMs+'ms'):(h.dnsOk?'HTTP 실패':'—');
    const http=h.dnsOk?diagStepBadge(h.httpOk,httpLabel):'<span class="muted" style="font-size:11px">HTTP 건너뜀</span>';
    const ips=(h.ips&&h.ips.length)?'<div class="muted" style="font-size:11px;margin-top:3px">'+esc(h.ips.join(', '))+'</div>':'';
    const err=h.error?'<div style="font-size:11px;color:#e0a13a;margin-top:3px">'+esc(h.error)+'</div>':'';
    return '<div style="padding:8px 10px;border:1px solid var(--line);border-radius:9px;margin:6px 0">'
      +'<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap"><b style="font-size:13px">'+esc(h.host)+'</b>'+dns+http+'</div>'+ips+err+'</div>';
  }).join('');
  const net='<div class="muted" style="font-size:12px;margin:6px 0 2px">인터페이스 <b>'+esc(s.iface||'-')+'</b> · 게이트웨이 <b>'+esc(s.gateway||'-')+'</b> · DNS '+esc((s.dnsServers||[]).join(', ')||'-')+'</div>';
  const vpnDetail=s.vpnDetail?'<div class="muted" style="font-size:12px;margin:2px 0">'+esc(s.vpnDetail)+'</div>':'';
  return '<div style="border:1px solid var(--line);border-radius:11px;padding:12px 14px;margin:8px 0;background:'+(open?'#141b28':'transparent')+'">'
    +'<div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap"><span style="font-size:12px;color:var(--dim)">'+esc(diagTime(s.t))+'</span>'+vpnChip+'</div>'
    +vpnDetail+net+hosts+'</div>';
}
// WKWebView has no download delegate here, so a plain navigation to an attachment URL does
// nothing — fetch the CSV as a blob and trigger a same-page <a download> (the app's convention).
function downloadDiagCsv(){
  fetch('/api/debug/diag/export').then(function(r){
    if(!r.ok) throw new Error('no data'); return r.blob();
  }).then(function(blob){
    const cd=/* filename from server */ 'diag.csv';
    const url=URL.createObjectURL(blob);
    const a=document.createElement('a'); a.href=url; a.download=cd;
    document.body.appendChild(a); a.click();
    setTimeout(function(){ URL.revokeObjectURL(url); a.remove(); }, 1000);
  }).catch(function(){ $("diagRunNote").textContent='내려받을 진단 기록이 없습니다.'; });
}

// ===== 시스템 로그 (view-trace) — 프로덕트 퀄리티 개선 전용, 일반 유저 대상 아님 =====
// 0.5초 하트비트(어떤 페이지·탭을 보고 있었나) + 네이티브 창 라이프사이클을 타임라인으로 렌더.
// 기본은 같은 화면을 계속 보던 tick 구간을 한 줄로 압축("보는 중" 세그먼트)하고, 체크박스로
// 0.5초 틱을 원본 그대로 펼칠 수 있다. 최상단 카드는 마지막 실행의 흰 화면 구간(창 표시→첫
// 페인트)을 ms로 요약 — "업데이트 후 3초 흰 화면" 리포트가 스크린샷 없이 숫자로 나온다.
let _vtEvents=null;
function loadViewTrace(){
  fetch('/api/debug/view-trace/list?limit=4000').then(r=>r.json()).then(function(j){
    _vtEvents=j.events||[]; renderViewTrace();
  }).catch(function(){ const h=$("vtList"); if(h&&!_vtEvents) h.innerHTML='<div class="empty">불러오지 못했습니다</div>'; });
}
function vtTime(t){ const p=CMTimeFilter.parts(t); return actPad(p.h)+':'+actPad(p.mi)+':'+actPad(p.s)+'.'+String(t%1000).padStart(3,'0'); }
function vtPage(pg){
  const path=(pg||'').split('?')[0];
  const m={'/':'대시보드','/bgm-player':'컨디션 관리','/goal-add':'목표 추가','/goal':'목표 상세',
           '/equipment':'장비','/cron':'크론','/worker-log':'워커 로그','/transcript':'트랜스크립트','/breakdown':'브레이크다운'};
  return m[path]||path||'?';
}
function vtBadge(txt,color){ return '<span style="display:inline-block;font-size:11px;font-weight:700;color:'+color+';border:1px solid '+color+';border-radius:6px;padding:1px 7px">'+esc(txt)+'</span>'; }
// 마지막 실행 요약: appLaunch → windowOpen(창 표시) → firstPaint(첫 페인트) 오프셋과
// 그 사이의 빈 화면 구간. 800ms를 넘으면 앰버로 강조(신호등 빨강/녹색은 쓰지 않는다).
function vtLaunchSummary(evs){
  let li=-1;
  for(let i=evs.length-1;i>=0;i--){ const e=evs[i]; if(e.src==='native'&&e.note==='appLaunch'){ li=i; break; } }
  if(li<0) return '';
  const t0=evs[li].t; let open=null,paint=null;
  for(let i=li+1;i<evs.length;i++){ const e=evs[i];
    if(e.src==='native'&&e.note==='appLaunch') break;   // 다음 실행까지만
    if(open===null&&e.src==='native'&&e.note==='windowOpen') open=e.t;
    if(paint===null&&e.src==='js'&&(e.note||'').indexOf('firstPaint')===0) paint=e.t;
    if(open!==null&&paint!==null) break; }
  const p=CMTimeFilter.parts(t0);
  const when=p.y+'-'+actPad(p.mo)+'-'+actPad(p.d)+' '+actPad(p.h)+':'+actPad(p.mi)+':'+actPad(p.s);
  const gap=(open!==null&&paint!==null)?(paint-open):null;
  let bits='<b>실행</b> '+esc(when);
  if(open!==null) bits+=' · 창 표시 <b>+'+(open-t0)+'ms</b>';
  if(paint!==null) bits+=' · 첫 페인트 <b>+'+(paint-t0)+'ms</b>';
  if(gap!==null){
    const warn=gap>800, c=warn?'#e0a13a':'var(--dim)';
    bits+=' · <span style="color:'+c+';font-weight:700">빈 화면 구간 '+gap+'ms</span>';
  } else if(paint===null){
    bits+=' · <span style="color:#e0a13a;font-weight:700">첫 페인트 기록 없음</span>';
  }
  return '<div style="border:1px solid var(--line);border-radius:11px;padding:10px 14px;margin:2px 0 6px;background:#141b28;font-size:12.5px;color:var(--txt)">'+bits
    +'<div class="muted" style="font-size:11.5px;margin-top:4px">빈 화면 구간 = 창이 화면에 뜬 순간부터 페이지가 실제 픽셀을 그린 순간까지 — 실행 직후 흰 화면이 보였다면 이 숫자가 그 길이입니다.</div></div>';
}
function renderViewTrace(){
  const host=$("vtList"); if(!host) return;
  const evs=_vtEvents||[];
  const lc=$("vtLaunch"); if(lc) lc.innerHTML=vtLaunchSummary(evs);
  if(!evs.length){ host.innerHTML='<div class="empty">아직 기록이 없습니다 — 앱 창이 열려 있는 동안 0.5초 단위로 쌓입니다.</div>'; return; }
  const showTicks=$("vtTicks")&&$("vtTicks").checked;
  // 같은 화면(페이지+뷰+painted+hidden)을 연속으로 보던 tick 구간을 세그먼트 한 줄로 압축.
  const rows=[]; let seg=null;
  function flushSeg(){ if(seg){ rows.push(seg); seg=null; } }
  evs.forEach(function(e){
    if(e.k==='tick'&&!showTicks){
      const key=(e.page||'')+'|'+(e.view||'')+'|'+(e.painted?1:0)+'|'+(e.hidden?1:0);
      if(seg&&seg.key===key){ seg.t1=e.t; seg.n++; return; }
      flushSeg();
      seg={key:key,segment:true,t0:e.t,t1:e.t,n:1,page:e.page,view:e.view,painted:e.painted,hidden:e.hidden};
      return;
    }
    flushSeg(); rows.push(e);
  });
  flushSeg();
  const total=rows.length, recent=rows.slice(-400).reverse();
  let h='<div class="lbl" style="margin:14px 0 8px">타임라인 (최신순'+(total>400?', 최근 400줄':'')+')</div>';
  h+=recent.map(function(r){
    if(r.segment){
      const dur=((r.t1-r.t0)/1000+0.5).toFixed(1);
      const state=(r.hidden?' · 숨김':'')+(r.painted?'':' · 미페인트');
      return '<div style="display:flex;gap:10px;align-items:baseline;padding:4px 10px;border-left:2px solid #2a3146;margin:2px 0;font-size:12px;color:var(--dim)">'
        +'<span style="font-variant-numeric:tabular-nums">'+vtTime(r.t0)+'</span>'
        +'<span>보는 중 <b style="color:var(--txt)">'+esc(vtPage(r.page))+(r.view?(' · '+esc(r.view)):'')+'</b>'
        +esc(state)+' — '+dur+'s ('+r.n+'틱)</span></div>';
    }
    const isNative=r.src==='native';
    const note=r.note||'';
    // AI 턴 중단(사용자 중단/비정상 종료/오류)도 경고색 — "중단 여부"가 타임라인에서 눈에 띄게.
    const warn=note.indexOf('jsError')===0||note.indexOf('rejection')===0||note==='navFail'
      ||note==='aiTurnStopped'||note==='aiTurnDied'||note==='aiTurnError';
    const color=warn?'#e0a13a':(isNative?'#8f7ff0':'#48b8d0');
    const extra=(r.detail?(' '+esc(r.detail)):'')+(r.page?(' <span class="muted">'+esc(vtPage(r.page))+(r.view?(' · '+esc(r.view)):'')+'</span>'):'');
    return '<div style="display:flex;gap:10px;align-items:baseline;padding:5px 10px;border-left:2px solid '+color+';margin:2px 0;font-size:12.5px;color:var(--txt)">'
      +'<span class="muted" style="font-variant-numeric:tabular-nums">'+vtTime(r.t)+'</span>'
      +vtBadge(isNative?'네이티브':'페이지',color)
      +'<span><b>'+esc(note)+'</b>'+extra+'</span></div>';
  }).join('');
  host.innerHTML=h;
}

// ===== 화면 카탈로그 — 사이트맵(깃북식 트리) + 화면 상태 스크린샷 아카이브 (UX/UI 전용) =====
// 수집은 네이티브(AppWindowController.screenCatalogTick → ScreenCatalog)가 하고, 사이트맵은
// UXUI 관리 워커(Scripts/uxui-sitemap.sh)가 main 갱신 시 코드에서 재생성해 설치한다. 이 탭은
// 둘을 클라이언트에서 조인한다: 카탈로그 상태 키(모드|경로?쿼리키|뷰|플래그)를 사이트맵 노드의
// match 어휘(mode/path/view/flag)와 맞춰 노드마다 스크린샷·커버리지를 붙인다. 시간 표시는
// 표시 타임존 규칙(CMTimeFilter.parts)을 따른다.
let _scList=null, _scFilter='all', _scMap=null, _scView='map', _scSel=null;
const SC_FLAG_KO={zen:'젠(보드 접힘)',reward:'수확 대기',run:'세션 중',counting:'카운트다운',done:'한 판 더?',modal:'모달',railoff:'레일 접힘'};
const SC_STATUS_KO={'':'미검토',review:'검토중',fix:'개선필요',done:'개선완료',ignore:'무시'};
function loadScreens(){
  fetch('/api/debug/screens/list').then(r=>r.json()).then(function(j){
    _scList=j.screens||[];
    return fetch('/api/debug/screens/sitemap').then(r=>r.json());
  }).then(function(m){
    if(m&&m.pages) _scMap=m;
    renderScreens();
  }).catch(function(){ const h=$("scGrid"); if(h&&!_scList) h.innerHTML='<div class="empty">불러오지 못했습니다</div>'; });
}
window.setScView=function(v){ _scView=v;
  ['map','grid'].forEach(function(k){ const b=$("scv_"+k); if(b) b.classList.toggle('on', k===v); });
  renderScreens(); };
window.setScFilter=function(f){ _scFilter=f;
  ['all','','review','fix','done'].forEach(function(k){ const b=$("scf_"+k); if(b) b.classList.toggle('on', k===f); });
  renderScreens(); };
function scWhen(t){ if(!t) return '-'; const p=CMTimeFilter.parts(t);
  return (p.y%100)+'. '+p.mo+'. '+p.d+'. '+actPad(p.h)+':'+actPad(p.mi); }
function scChips(flags){
  if(!flags) return '';
  return flags.split(',').filter(Boolean).map(function(f){
    return '<span style="display:inline-block;font-size:10.5px;color:#a78bfa;border:1px solid #4c3f78;border-radius:6px;padding:0 6px;margin-right:4px">'+esc(SC_FLAG_KO[f]||f)+'</span>';
  }).join('');
}
// 한 화면 상태 카드 (그리드·사이트맵 상세 공용).
function scCard(s){
  const img=s.file
    ? '<img loading="lazy" src="/api/debug/screens/img?id='+encodeURIComponent(s.id)+'&t='+(s.shotAt||0)+'" onclick="scZoom(this.src)" style="width:100%;display:block;border-radius:8px;border:1px solid var(--line);cursor:zoom-in;background:#0b0f18">'
    : '<div style="height:110px;display:flex;align-items:center;justify-content:center;border:1px dashed var(--line);border-radius:8px;color:var(--dim);font-size:12px">스크린샷 대기 중… (그 화면이 다시 뜨면 촬영)</div>';
  const stOpts=Object.keys(SC_STATUS_KO).map(function(k){
    return '<option value="'+k+'"'+((s.status||'')===k?' selected':'')+'>'+SC_STATUS_KO[k]+'</option>'; }).join('');
  return '<div class="panel" style="padding:10px;border:1px solid var(--line);border-radius:12px">'
    +img
    +'<div style="display:flex;align-items:baseline;gap:8px;margin:8px 0 2px">'
    +'<b style="font-size:12.5px;font-variant-numeric:tabular-nums;color:#8fd3ff">'+esc(s.id)+'</b>'
    +'<span style="font-size:12px;color:var(--txt)">'+esc(vtPage(s.page))+(s.view?(' · '+esc(s.view)):'')+'</span>'
    +'<span class="muted" style="font-size:11px;margin-left:auto" title="'+esc(s.key)+'">'+esc(s.page)+'</span></div>'
    +'<div style="margin:2px 0 6px">'+scChips(s.flags)
    +'<span class="muted" style="font-size:11px">'+s.count+'회 · 처음 '+scWhen(s.firstSeen)+' · 최근 '+scWhen(s.lastSeen)+(s.shotAt?(' · 촬영 '+scWhen(s.shotAt)):'')+'</span></div>'
    +'<div style="display:flex;gap:6px;align-items:center">'
    +'<select id="scStatus-'+esc(s.id)+'" style="background:#161c28;border:1px solid #2f3a54;color:#e7ecf4;border-radius:7px;padding:4px 6px;font-size:12px">'+stOpts+'</select>'
    +'<input id="scNote-'+esc(s.id)+'" value="'+esc(s.note||'')+'" placeholder="UX/UI 메모 — 무엇을 개선할까"'
    +' style="flex:1;background:#161c28;border:1px solid #2f3a54;color:#e7ecf4;border-radius:7px;padding:4px 8px;font-size:12px"'
    +' onkeydown="if(event.key===\'Enter\')scSave(\''+esc(s.id)+'\')">'
    +'<button class="btn" onclick="scSave(\''+esc(s.id)+'\')" title="메모·상태 저장">저장</button>'
    +'</div></div>';
}
// ---- 사이트맵 노드 ↔ 카탈로그 매칭 (카탈로그 키의 어휘를 그대로 사용) ----
function scPagePath(e){ return (e.page||'').split('?')[0]; }
function scNodeMatches(node){
  return (_scList||[]).filter(function(e){
    if(node.mode&&e.mode!==node.mode) return false;
    if(scPagePath(e)!==node.path) return false;
    if(node.view!=null&&(e.view||'')!==node.view) return false;
    if(node.flag&&(','+(e.flags||'')+',').indexOf(','+node.flag+',')<0) return false;
    return true;
  });
}
// 사이트맵을 평탄한 노드 목록으로 (트리 렌더 + id 선택용). kind: page|view|state.
function scFlatNodes(){
  const out=[];
  ((_scMap&&_scMap.pages)||[]).forEach(function(p){
    out.push({id:p.id,kind:'page',title:p.title,path:p.path,mode:p.mode,desc:p.desc,src:p.src,page:p});
    (p.children||[]).forEach(function(c){
      out.push({id:c.id,kind:'view',title:c.title,path:p.path,mode:p.mode,view:c.view,page:p});
    });
    (p.states||[]).forEach(function(f){
      out.push({id:p.id+'~'+f,kind:'state',title:(_scMap.flagLabels||{})[f]||SC_FLAG_KO[f]||f,
                path:p.path,mode:p.mode,flag:f,page:p});
    });
  });
  return out;
}
function scCovBadge(matches){
  const shot=matches.filter(function(e){ return e.file; }).length;
  if(!matches.length) return '<span style="font-size:10.5px;color:#5a6377">·미수집</span>';
  return '<span style="font-size:10.5px;color:'+(shot?'#8fd3ff':'#e0a13a')+'">'+shot+'/'+matches.length+'장</span>';
}
window.scSelect=function(id){ _scSel=id; renderScreens(); };
function renderScSitemap(){
  const tree=$("scTree"), detail=$("scNode"); if(!tree||!detail) return;
  if(!_scMap||!(_scMap.pages||[]).length){
    tree.innerHTML='<div class="empty">사이트맵이 아직 없습니다 — UXUI 관리 워커가 main 갱신 시 생성합니다.<br><span class="muted" style="font-size:11px">수동 생성: Scripts/uxui-sitemap.sh --force</span></div>';
    detail.innerHTML='';
    return;
  }
  const nodes=scFlatNodes();
  if(!_scSel||!nodes.some(function(n){ return n.id===_scSel; })) _scSel=nodes.length?nodes[0].id:null;
  // 좌측 트리: 페이지 → (서브페이지, 상태). 깃북처럼 페이지가 큰 항목.
  let covered=0, total=0;
  const byPage={};
  nodes.forEach(function(n){ (byPage[n.path+n.mode]=byPage[n.path+n.mode]||[]).push(n);
    total++; if(scNodeMatches(n).some(function(e){ return e.file; })) covered++; });
  let h='<div class="muted" style="font-size:11px;margin:0 0 8px">커버리지 <b style="color:var(--txt)">'+covered+'/'+total+'</b> 노드'
    +(_scMap.generatedAt?(' · 생성 '+esc(String(_scMap.generatedAt).slice(0,16).replace('T',' '))):'')
    +(_scMap.commit?(' · <span style="font-variant-numeric:tabular-nums">'+esc(String(_scMap.commit).slice(0,8))+'</span>'):'')+'</div>';
  (_scMap.pages||[]).forEach(function(p){
    const pageNode=nodes.find(function(n){ return n.kind==='page'&&n.id===p.id; });
    function row(n,depth,icon){
      const on=n.id===_scSel;
      return '<div onclick="scSelect(\''+esc(n.id)+'\')" style="cursor:pointer;padding:3px 8px;margin-left:'+(depth*14)+'px;border-radius:7px;display:flex;gap:6px;align-items:baseline'
        +(on?';background:#1d2740;border:1px solid #2f3a54':'')+'">'
        +'<span style="opacity:.6;font-size:10.5px">'+icon+'</span>'
        +'<span style="'+(n.kind==='page'?'font-weight:700;color:var(--txt)':'color:var(--dim)')+'">'+esc(n.title)+'</span>'
        +'<span style="margin-left:auto">'+scCovBadge(scNodeMatches(n))+'</span></div>';
    }
    h+=row(pageNode,0,'📄');
    (p.children||[]).forEach(function(c){
      h+=row(nodes.find(function(n){ return n.id===c.id; }),1,'▸');
    });
    (p.states||[]).forEach(function(f){
      h+=row(nodes.find(function(n){ return n.id===p.id+'~'+f; }),1,'◦');
    });
  });
  tree.innerHTML=h;
  // 우측 상세: 선택 노드 설명 + 매칭 스크린샷.
  const sel=nodes.find(function(n){ return n.id===_scSel; });
  if(!sel){ detail.innerHTML=''; return; }
  const matches=scNodeMatches(sel);
  let d='<div style="border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:0 0 12px">'
    +'<div style="display:flex;gap:10px;align-items:baseline;flex-wrap:wrap">'
    +'<b style="font-size:14px">'+esc(sel.title)+'</b>'
    +'<span class="muted" style="font-size:12px;font-variant-numeric:tabular-nums">'+esc(sel.mode)+' · '+esc(sel.path)
    +(sel.view!=null?(' · 뷰 '+esc(sel.view)):'')+(sel.flag?(' · 상태 '+esc(sel.flag)):'')+'</span>'
    +'<span style="margin-left:auto">'+scCovBadge(matches)+'</span></div>'
    +(sel.desc?('<div class="muted" style="font-size:12px;margin-top:5px">'+esc(sel.desc)+'</div>'):'')
    +(sel.src?('<div class="muted" style="font-size:11px;margin-top:3px">src: '+esc(sel.src)+'</div>'):'')
    +'</div>';
  if(!matches.length){
    d+='<div class="empty">아직 캡처된 화면이 없습니다 — 앱에서 이 화면을 열면 자동으로 수집됩니다.</div>';
  }else{
    d+='<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px">'
      +matches.map(scCard).join('')+'</div>';
  }
  detail.innerHTML=d;
}
function renderScreens(){
  const mapWrap=$("scMapWrap"), gridWrap=$("scGridWrap");
  if(mapWrap) mapWrap.style.display=(_scView==='map')?'flex':'none';
  if(gridWrap) gridWrap.style.display=(_scView==='grid')?'':'none';
  if(_scView==='map'){ renderScSitemap(); return; }
  const host=$("scGrid"); if(!host) return;
  const all=_scList||[];
  const shot=all.filter(s=>s.file).length, fix=all.filter(s=>s.status==='fix').length;
  const sm=$("scSummary"); if(sm) sm.textContent='화면 상태 '+all.length+'개 · 스크린샷 '+shot+'장 · 개선필요 '+fix+'개';
  const list=(_scFilter==='all')?all:all.filter(s=>(s.status||'')===_scFilter);
  if(!list.length){
    host.innerHTML='<div class="empty">'+(all.length?'이 상태의 화면이 없습니다.':'아직 수집된 화면이 없습니다 — 앱 창이 열려 있는 동안 자동으로 쌓입니다.')+'</div>';
    return;
  }
  host.innerHTML=list.map(scCard).join('');
}
window.scZoom=function(src){ const lb=$("scLightbox"), im=$("scLightImg"); if(!lb||!im) return;
  im.src=src; lb.style.display='flex'; };
window.scSave=function(id){
  const note=(document.getElementById('scNote-'+id)||{}).value||'';
  const status=(document.getElementById('scStatus-'+id)||{}).value||'';
  fetch('/api/debug/screens/note',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({id:id,note:note,status:status})})
    .then(function(){ const s=(_scList||[]).find(function(x){ return x.id===id; });
      if(s){ s.note=note; s.status=status; } renderScreens(); })
    .catch(function(){});
};

// ===== 히스토리 (대시보드에서 이동: 날짜별 집중도 + 초집중 세션 + 시간대 분석) =====
// 서버 /history.json 은 날짜별 압축 샘플({t,active,tier,meeting,mult,app})을 준다.
// 컨디션맵/오늘 활동과 '똑같은' withCarryForward + timeBuckets 로 총/책상/집중을 구하고(단일
// 진실 공급원), 그 위에서 '지속 시간 기준' 초집중 세션을 잡는다. fmtH/hhmm/esc/CMTimeFilter/
// withCarryForward/timeBuckets 는 이미 이 페이지에 있으므로 재사용한다.
let _histData=null, _histLoading=false, _histRendered=false, _dfMin=25;
let _histStart='', _histEnd='', _histPreset='3m', _histFetchedDays=0, _histRangeSig='';
function histDayStr(d){ return CMTimeFilter.dayStr(d); }
function daysBetween(a,b){ return CMTimeFilter.daysBetween(a,b); }
function histPresetStart(preset){ return CMTimeFilter.presetRange(preset).start; }   // 'today'면 오늘 그대로
function tzLabel(){ return CMTimeFilter.tzLabel(); }
function syncHistInputs(){ const a=$('histFrom'),b=$('histTo'); if(a)a.value=_histStart; if(b)b.value=_histEnd; }
function reflectRangeBtn(){ ['today','yesterday','7d','1m','30d','3m'].forEach(k=>{ const b=$('hr_'+k); if(b) b.classList.toggle('primary', k===_histPreset); }); }
function setHistRange(preset){
  _histPreset=preset;
  _histStart=histPresetStart(preset);
  _histEnd=(preset==='yesterday') ? _histStart : histDayStr(new Date());   // '어제'는 끝도 어제로 고정, 나머지는 오늘까지
  syncHistInputs(); loadHistory();
}
function onHistDate(){
  const a=$('histFrom'),b=$('histTo'); if(!a||!b) return;
  if(a.value) _histStart=a.value; if(b.value) _histEnd=b.value;
  if(_histStart>_histEnd){ const t=_histStart; _histStart=_histEnd; _histEnd=t; syncHistInputs(); }
  _histPreset='';                  // 직접 입력하면 퀵버튼 선택 해제
  loadHistory();
}
function setDeepMin(m){ _dfMin=m; reflectDeepBtn(); if(_histData) renderHistory(); }
function reflectDeepBtn(){ [15,25,45].forEach(k=>{ const b=$('df'+k); if(b) b.classList.toggle('primary', k===_dfMin); }); }
function loadHistory(force){
  if(!_histStart){ _histPreset='3m'; _histEnd=histDayStr(new Date()); _histStart=histPresetStart('3m'); syncHistInputs(); }  // 최초 진입 기본값: 3달
  reflectDeepBtn(); reflectRangeBtn();
  if(_histLoading) return;
  const todayStr=histDayStr(new Date());
  const need=Math.max(1, daysBetween(_histStart, todayStr)+1);   // 시작~오늘을 덮을 일수(서버는 최신 N일을 준다)
  const sig=_histStart+'_'+_histEnd;
  if(_histData && !force && need<=_histFetchedDays){ if(!_histRendered || _histRangeSig!==sig) renderHistory(); return; }   // 캐시 우선 — 범위 안 바뀌면 재호출은 무비용
  _histLoading=true;
  const r=$('histRange'); if(r) r.textContent='불러오는 중…';
  fetch('/history.json?days='+need).then(x=>x.json()).then(j=>{
    _histData=(j&&j.days)||[]; _histFetchedDays=need; _histLoading=false; renderHistory();
  }).catch(()=>{ _histLoading=false; const e=$('histDays'); if(e) e.innerHTML='<div class="empty">불러오지 못했습니다</div>'; });
}
// 지속 시간 기준 초집중: carry-forward 후 _cat==='focus'가 끊김 없이(샘플 간 <=2분) 이어진
// 구간의 길이가 기준(_dfMin) 이상이면 한 세션. carry-forward가 이미 <=10분 짧은 끊김을
// 집중으로 메우므로, 잠깐의 딴짓(설정 확인 등)은 세션을 깨지 않는다.
function deepFocusSessions(ss){
  const runs=[]; let cur=null;
  ss.forEach(s=>{
    if(s._cat==='focus'){
      if(cur && (s.t-cur.endT)<=120){ cur.endT=s.t; cur.mins++; cur.apps[s.app||'-']=(cur.apps[s.app||'-']||0)+1; }
      else { if(cur) runs.push(cur); cur={startT:s.t,endT:s.t,mins:1,apps:{}}; cur.apps[s.app||'-']=1; }
    } else if(cur){ runs.push(cur); cur=null; }
  });
  if(cur) runs.push(cur);
  return runs.filter(x=>x.mins>=_dfMin).map(x=>({startT:x.startT,endT:x.endT,mins:x.mins,
    app:Object.entries(x.apps).sort((a,b)=>b[1]-a[1])[0][0]}));
}
function histCard(k,v,cap){ return '<div class="card"><div class="k">'+esc(k)+'</div><div class="v">'+esc(v)+'</div>'+(cap?'<div class="cap">'+esc(cap)+'</div>':'')+'</div>'; }
function renderHistory(){
  _histRendered=true; _histRangeSig=_histStart+'_'+_histEnd; reflectDeepBtn(); reflectRangeBtn();
  // 캐시된 전체에서 선택 범위(_histStart~_histEnd)만 골라 렌더. 날짜 문자열(YYYY-MM-DD)은 사전순=시간순.
  const data=(_histData||[]).filter(d=> d.day>=_histStart && d.day<=_histEnd);
  const r=$('histRange'); if(r) r.textContent=(data.length? (data.length+'일 기록') : '기간 내 기록 없음')+' · 시각 '+tzLabel()+' 기준';
  const rows=[]; const hourMin=new Array(24).fill(0);
  let totFocus=0, totSessions=0, focusDays=0;
  data.forEach(d=>{
    const ss=withCarryForward(d.samples||[]);
    const b=timeBuckets(ss);
    const sess=deepFocusSessions(ss);
    if(b.focus>0) focusDays++;
    totFocus+=b.focus; totSessions+=sess.length;
    sess.forEach(x=>{ for(let t=x.startT;t<=x.endT;t+=60){ hourMin[CMTimeFilter.hourOf(t)]++; } });
    rows.push({day:d.day,b,sess});
  });
  // 최신순(내림차순)으로 보여준다 — 라벨이 '최신순'이므로.
  rows.sort((a,b)=>a.day<b.day?1:-1);
  const sumH=$('histSummary');
  if(sumH) sumH.innerHTML=
     histCard('기록 일수', data.length+'일')
    +histCard('총 집중', fmtH(totFocus))
    +histCard('총 초집중', totSessions+'회', _dfMin+'분+ 몰입 세션')
    +histCard('집중일 평균', focusDays? fmtH(Math.round(totFocus/focusDays)) : '–', '집중한 날 하루 평균');
  drawDfHours(hourMin);
  const host=$('histDays');
  if(!rows.length){ if(host) host.innerHTML='<div class="empty">선택한 기간('+_histStart+' ~ '+_histEnd+')에 기록이 없습니다</div>'; return; }
  host.innerHTML=rows.map(dayRowHtml).join('');
}
function dayRowHtml(r){
  const b=r.b, mx=Math.max(b.total,1);
  // 중첩 막대: 책상(주황) 위에 집중(초록). 책상은 집중을 포함하므로 집중을 겹쳐 그린다.
  const w=v=>Math.round(100*v/mx);
  const bar='<div style="position:relative;background:#2a2f3a;border-radius:4px;height:9px;width:160px;flex:0 0 auto">'
    +'<div style="position:absolute;left:0;top:0;height:9px;border-radius:4px;width:'+w(b.desk)+'%;background:#e8a13a"></div>'
    +'<div style="position:absolute;left:0;top:0;height:9px;border-radius:4px;width:'+w(b.focus)+'%;background:#36c08a"></div></div>';
  const chips=r.sess.length? r.sess.map(x=>'<span class="chip" style="margin:0;border-color:#36c08a;color:#36c08a">'
      +hhmm(x.startT)+'–'+hhmm(x.endT)+' · '+fmtH(x.mins)+' · '+esc(x.app)+'</span>').join(' ')
    : '<span class="muted" style="font-size:11px">초집중 없음</span>';
  const wd=['일','월','화','수','목','금','토'][new Date(r.day+'T00:00:00').getDay()];
  return '<div class="panel" style="margin:0 0 8px;padding:10px 14px">'
    +'<div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap">'
    +'<b style="font-variant-numeric:tabular-nums;min-width:118px">'+esc(r.day)+' ('+wd+')</b>'
    +'<span class="muted" style="font-size:12px;min-width:180px">총 '+fmtH(b.total)+' · 책상 '+fmtH(b.desk)+' · 집중 '+fmtH(b.focus)+'</span>'
    +bar
    +'<span class="chip" style="margin:0;border-color:#36c08a;color:#36c08a">초집중 '+r.sess.length+'회</span>'
    +'</div>'
    +'<div style="margin-top:8px;display:flex;gap:6px;flex-wrap:wrap">'+chips+'</div>'
    +'</div>';
}
function drawDfHours(hourMin){
  const c=$('dfHours'); if(!c) return;
  const dpr=window.devicePixelRatio||1, W=c.clientWidth||600, H=120;
  c.width=W*dpr; c.height=H*dpr; const g=c.getContext('2d'); g.setTransform(dpr,0,0,dpr,0,0); g.clearRect(0,0,W,H);
  const max=Math.max(1,...hourMin), pad=16, bw=(W-pad)/24;
  for(let h=0;h<24;h++){
    const bh=(H-pad)*(hourMin[h]/max);
    g.fillStyle = hourMin[h]>0 ? '#36c08a' : '#222834';
    g.fillRect(pad+h*bw+1, (H-pad)-bh, Math.max(1,bw-2), bh);
    if(h%3===0){ g.fillStyle='#6b7688'; g.font='9px -apple-system,sans-serif'; g.fillText((h<10?'0':'')+h, pad+h*bw, H-3); }
  }
  const cap=$('dfHoursCap');
  if(cap) cap.textContent = (max>0 ? ('시간대별 초집중 누적 — 가장 자주 몰입하는 시간대: '+(hourMin.indexOf(max)<10?'0':'')+hourMin.indexOf(max)+'시 전후')
                                  : '아직 초집중 기록이 없습니다. 집중(에디터·개발) 상태가 '+_dfMin+'분 이상 이어지면 여기 쌓입니다.')
                            + ' · 시각 '+tzLabel()+' 기준';
}
// 서브탭 진입 시 로드(캐시되어 재진입은 무비용, 그때 캔버스 폭이 유효하므로 히스토그램도 다시 그린다).
function initHistory(){ loadHistory(); }

function initActions(){
  if(_actInited){ loadActions(); return; }
  _actInited=true;
  _actCtl = CMTimeFilter.mount($("actFilter"), {
    presets:['today','yesterday','7d','30d','90d'], auto:true, custom:true, initial:'auto',
    onChange:(r)=>{ _actRange=r; renderActions(); loadActions(); }
  });
}
function loadActions(force){
  reflectActKind(); reflectActCat(); ensureActStream();
  if(_actLoading) return;
  // '자동'(최근 전체)은 500건, 기간 조회는 서버 캡까지 깊게 (ActionLog.recentJSON cap 2000).
  const lim=(_actRange.mode==='auto')?500:2000;
  // SSE가 즉시 반영을 담당 — 재진입(뷰 전환·필터)은 신선하고 충분히 깊으면 렌더만 한다.
  if(_actEvents && !force && lim<=_actFetchedLimit && (Date.now()-_actFetchedAt)<4500){ renderActions(); return; }
  _actLoading=true;
  fetch('/api/actions?limit='+lim).then(x=>x.json()).then(j=>{
    _actEvents=(j&&j.events)||[]; _actFetchedAt=Date.now(); _actFetchedLimit=lim; _actLoading=false; renderActions();
  }).catch(()=>{ _actLoading=false; const e=$('actList'); if(e&&!_actEvents) e.innerHTML='<div class="empty">불러오지 못했습니다</div>'; });
}
// 실시간 피드: 서버가 액션 발생 즉시 SSE(/api/actions/stream)로 밀어준다 — 폴링 지연 0.
// 액션로그 탭에 처음 들어올 때 한 번 열고 계속 유지(EventSource가 끊기면 자동 재접속).
let _actES=null;
function ensureActStream(){
  if(_actES || typeof EventSource==='undefined') return;
  try{ _actES=new EventSource('/api/actions/stream'); }catch(e){ return; }
  _actES.onmessage=function(m){
    let e; try{ e=JSON.parse(m.data); }catch(_){ return; }
    if(!_actEvents) _actEvents=[];
    _actEvents.push(e); if(_actEvents.length>2200) _actEvents=_actEvents.slice(-2000);
    if(mode==='actions') renderActions();
  };
}
// 보정 폴링(15초): SSE 재접속 사이에 놓친 이벤트를 있으면 메꾼다. 탭이 보일 때만.
setInterval(function(){
  if(mode==='actions' && document.visibilityState==='visible') loadActions(true);
}, 15000);
function actPad(n){ return (n<10?'0':'')+n; }
// 기간 필터: '자동'은 무제한(최근 N건 전체), 그 외엔 표시 타임존 날짜로 [start,end] 포함.
function actInRange(e){
  if(!_actRange || _actRange.mode==='auto') return true;
  const d=CMTimeFilter.parts(e.t*1000), day=d.y+'-'+actPad(d.mo)+'-'+actPad(d.d);
  return day>=_actRange.start && day<=_actRange.end;
}
function renderActions(){
  const host=$('actList'); if(!host) return;
  const all=(_actEvents||[]).filter(actInRange);
  // 폴링 재렌더 가드: 이벤트·필터가 그대로면 innerHTML 재구성을 건너뛴다
  // (폴링이 스크롤 위치를 흔들거나 DOM을 계속 갈아끼우지 않게).
  const last=all.length?all[all.length-1]:null;
  const sig=all.length+':'+(last?last.t+'/'+last.action:'')+'|'+_actKind+'|'+_actCat
    +'|'+(_actRange?(_actRange.mode+_actRange.start+_actRange.end):'');
  if(sig===_actRenderedSig && host.firstChild) return;
  _actRenderedSig=sig;
  const evs=all.filter(e=>(!_actKind||e.kind===_actKind)&&(!_actCat||actCat(e)===_actCat));
  const s=$('actSummary');
  if(s){ const c={user:0,bgm:0,system:0}, cc={};
    all.forEach(e=>{ if(c[e.kind]!=null)c[e.kind]++; const k=actCat(e); cc[k]=(cc[k]||0)+1; });
    s.textContent=all.length?('유저 '+c.user+' · BGM '+c.bgm+' · 자동 '+c.system
      +' — 포모도로 '+(cc.pomodoro||0)+' · 목표 '+(cc.goal||0)):'기록 없음'; }
  if(!evs.length){ host.innerHTML='<div class="empty">기간 내 기록된 액션이 없습니다 — 세션을 시작·중지하거나 모드를 바꾸면 여기에 쌓입니다.</div>'; return; }
  // 종류 배지 색: 유저=액센트, BGM=시안, 자동=보라 (상태 신호등 빨강/녹색은 쓰지 않는다).
  const KC={ user:['유저','var(--accent)'], bgm:['BGM','#33c9e6'], system:['자동','#a97bff'] };
  let h='', lastDay='';
  for(let i=evs.length-1;i>=0;i--){   // 최신이 위로 (시각·일 경계 모두 표시 타임존 기준)
    const e=evs[i], d=CMTimeFilter.parts(e.t*1000);
    const day=d.y+'-'+actPad(d.mo)+'-'+actPad(d.d);
    if(day!==lastDay){ if(lastDay) h+='</div>';
      h+='<div class="muted" style="font-size:11.5px;font-weight:700;margin:14px 0 6px">'+day+'</div>'
        +'<div class="panel" style="padding:2px 12px">'; lastDay=day; }
    const kc=KC[e.kind]||[e.kind,'var(--dim)'];
    // 분류 칩 색: 포모도로=주황, 목표=액센트, BGM=시안, 나머지=중립 (신호등 빨강/녹색 금지).
    const CATC={pomodoro:'#ffb454',goal:'var(--accent)',bgm:'#33c9e6'};
    const cat=actCat(e);
    let l2='<span class="pill" style="color:'+(CATC[cat]||'var(--dim)')+'" title="분류 — 어떤 도메인의 행동인지">'+esc(ACT_CAT_LABEL[cat]||cat)+'</span>';
    if(e.track) l2+='<span class="pill" title="'+esc(e.trackKey||'')+'">♪ '+esc(e.track)+'</span>';
    if(e.pool) l2+='<span class="pill" style="color:#8fd9ea;border-color:#1e5563" title="이 곡을 고른 규칙 (폭우 &gt; 플랜 슬롯 &gt; 모드)">'+esc(e.pool)+'</span>';
    if(e.bpm) l2+='<span class="pill">'+e.bpm+' BPM</span>';
    if(e.mode&&e.mode!=='-') l2+='<span class="pill">모드 '+esc(ACT_MODE[e.mode]||e.mode)+'</span>';
    // 업무 경과(workMin): 업무 시작(6h 갭 블록) 후 몇 분 시점의 행동인지 — 전략6
    // 시작 컨텍스트 선곡의 근거 축. 옛 라인(-1/없음)은 표시하지 않는다.
    if(e.workMin!=null&&e.workMin>=0)
      l2+='<span class="pill" style="color:#c9a4ff;border-color:#4a3670" title="업무 시작 후 경과 (6h 갭 블록 기준)">업무 '
        +(e.workMin<60?e.workMin+'분':(e.workMin/60).toFixed(1)+'h')+'</span>';
    if(e.phase&&e.phase!=='-') l2+='<span class="pill">'+esc(e.phase)+'</span>';
    if(e.app) l2+='<span class="pill">'+esc(e.app)+'</span>';
    h+='<div style="display:flex;gap:10px;padding:8px 0;border-bottom:1px solid var(--line);align-items:flex-start">'
      +'<span class="muted" style="flex:none;width:60px;font-variant-numeric:tabular-nums;font-size:12px;padding-top:1px">'
        +actPad(d.h)+':'+actPad(d.mi)+':'+actPad(d.s)+'</span>'
      +'<div style="flex:1;min-width:0">'
        +'<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">'
        +'<span style="flex:none;font-size:10px;font-weight:800;letter-spacing:.4px;color:'+kc[1]+';border:1px solid;border-radius:999px;padding:1px 7px">'+kc[0]+'</span>'
        +'<b style="font-size:13px">'+esc(ACT_LABEL[e.action]||e.action)+'</b>'
        +(e.detail?'<span class="muted" style="font-size:12px">'+esc(e.detail)+'</span>':'')
        +'</div>'
        +(l2?'<div style="display:flex;gap:5px;flex-wrap:wrap;margin-top:4px">'+l2+'</div>':'')
      +'</div></div>';
  }
  if(lastDay) h+='</div>';
  host.innerHTML=h;
}
// 컨디션맵 → 액션로그 드릴다운: 띠(24h 창)를 클릭하면 그 창이 걸치는 날짜 범위로 필터해 연다.
function mapDrill(d1,d2){
  setMode('actions');                          // initActions()가 여기서 보장된다
  if(_actCtl) _actCtl.setRange(d1, d2||d1);    // 커스텀 범위 → onChange가 렌더+로드까지
}
// ======================= /액션로그 =======================

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
