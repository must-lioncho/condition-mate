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
  .goal{display:flex;align-items:center;gap:8px;padding:5px 0;border-bottom:1px solid var(--line)}
  .goal .g{flex:1}
  .grip{cursor:grab;color:var(--mut);user-select:none;padding:0 2px;font-size:14px;line-height:1}
  .grip:active{cursor:grabbing}
  .goal.dragging{opacity:.45}
  .goal.dropTarget{border-top:2px solid var(--accent)}
  .stat{display:inline-flex;gap:3px;flex:0 0 auto}
  .sb{background:#1d2230;border:1px solid var(--line);color:var(--mut);border-radius:6px;padding:3px 8px;font-size:12px;cursor:pointer}
  .sb:hover{border-color:var(--accent)}
  .sb.on.backlog{color:var(--fg);border-color:var(--mut)}
  .sb.on.in_progress{background:var(--accent);border-color:var(--accent);color:#fff}
  .sb.on.done{background:var(--green);border-color:var(--green);color:#06281c}
  .ttime{font-variant-numeric:tabular-nums;color:var(--mut);font-size:12px;min-width:48px;text-align:right;flex:0 0 auto}
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
</style>
</head>
<body>
<div class="wrap">
  <div class="hdr">
    <div>
      <h1>오늘 활동 · BGM 디버그</h1>
      <div class="sub" id="date">불러오는 중…</div>
    </div>
    <button class="btn" onclick="document.getElementById('policy').classList.add('on')">기준 (정책서)</button>
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
    <button class="btn" id="viewToggle" onclick="toggleView()">프리뷰 ▸</button></div>
  <div class="panel">
    <!-- INPUT VIEW -->
    <div id="inputView">
      <div class="row">목표 추가:
        <input type="text" id="goalText" placeholder="목표/디테일 입력 후 Enter (계속 추가)" style="flex:1;min-width:140px"
               onkeydown="goalKey(event)">
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

async function load(){
  let d;
  try { d = await (await fetch('/data.json',{cache:'no-store'})).json(); }
  catch(e){ return; }
  $('total').textContent = d.total.label;
  const w = d.now.working;
  $('status').innerHTML = '<span class="dot" style="background:'+(w?'var(--green)':'#555')+'"></span>'+d.now.status;
  $('date').textContent = d.date + ' · 분당 기록';
  const ss = withCarryForward(d.samples);   // 10-min continuity applied
  const b = timeBuckets(ss);
  $('t_total').textContent = fmtH(b.total);
  $('t_desk').textContent = fmtH(b.desk);
  $('t_focus').textContent = fmtH(b.focus);
  $('t_off').textContent = b.off > 0 ? fmtH(b.off) : '–';
  drawTiers(b);
  const n=d.now;
  const siteStr=(n.site&&n.site!=='-')?' ('+esc(n.site)+')':'';
  $('now').innerHTML='지금: 앱 <b>'+esc(n.app)+siteStr+'</b> &nbsp; '+tierBadge(n.tier,n.mult)
    +' &nbsp; ⌨ '+(n.key||0)+' 🖱 '+(n.mouse||0)+' &nbsp; 전략 <b>'+esc(n.profile)+'</b> · BGM <b>'+esc(n.track)+'</b>';
  drawChart(ss);
  drawStrip(ss);
  renderReview(d);
  renderSummary(ss);
  renderTimeline(ss);
  renderApps(ss);
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

function renderTimeline(samples){
  const rows=$('logrows');
  const segs=timelineSegments(samples).reverse().slice(0,120);
  if(!segs.length){ rows.innerHTML='<tr><td colspan="7" class="empty">데이터 없음</td></tr>'; return; }
  rows.innerHTML=segs.map(g=>{
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
  }).join('');
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
function addGoal(){ const t=$('goalText').value.trim(); if(!t)return; $('goalText').value=''; $('goalText').focus(); post('/api/goal/add',{text:t}); }
function removeGoal(id){ post('/api/goal/remove',{id:id}); }
function saveNote(id,note){ post('/api/goal/note',{id:id,note:note}); }
// --- Goal status + per-goal time tracking ---
// Only one goal can be in_progress; the server enforces it and banks elapsed time
// on every transition. trackedSeconds is the banked total; while running we add the
// live session (now - startedAt) on the client so the clock ticks without re-rendering.
function setStatus(id,s){ post('/api/goal/status',{id:id,status:s}); }
function statBtn(g,val,label){ const on=(g.status||'backlog')===val;
  return '<button class="sb'+(on?(' on '+val):'')+'" onclick="setStatus(\''+g.id+'\',\''+val+'\')">'+label+'</button>'; }
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
function tickTimers(){ (_goals||[]).forEach(g=>{ const el=document.getElementById('tt_'+g.id); if(el) el.textContent=fmtDur(effTracked(g)); }); }
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
function submitSelf(){ post('/api/review',{selfScore:parseInt($('selfRange').value,10)||0}); }
function runAI(){ $('aiNote').textContent='분석 중…'; post('/api/aifilter',{}); }

let _view='input', _md='';
function toggleView(){ _view=(_view==='input')?'preview':'input'; applyView(); }
function applyView(){
  const inp=$('inputView'), pv=$('previewView'), btn=$('viewToggle');
  if(_view==='preview'){ inp.style.display='none'; pv.style.display=''; btn.textContent='◂ 입력'; }
  else { inp.style.display=''; pv.style.display='none'; btn.textContent='프리뷰 ▸'; }
}
function copyMd(b){ if(navigator.clipboard) navigator.clipboard.writeText(_md); const o=b.textContent; b.textContent='복사됨'; setTimeout(()=>{b.textContent=o;},1200); }
function gnote(r,id){ return (r.notes&&r.notes[id])||''; }

let _lastReviewKey='';
function renderReview(d){
  const r=d.review||{goals:[],notes:{},submittedSelf:false,aiScore:null,selfScore:null};
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
  renderReport(d,r,conf,prov);
  // input-side DOM (has text fields) — rebuild only when review data changes,
  // so the 5s auto-refresh never wipes a note you're typing.
  const key=JSON.stringify(r);
  if(key!==_lastReviewKey){
    _lastReviewKey=key;
    renderGoalsInput(r);
    renderStages(r);
  }
  applyView();
}
// Flat, numbered list (creation order). Parent set later via the 부모# field.
function renderGoalsInput(r){
  const goals=r.goals||[], gv=$('goals');
  _goals=goals;
  if(!goals.length){ gv.innerHTML='<div class="muted" style="padding:4px 0">목표를 추가하세요. (Enter로 계속 추가)</div>'; return; }
  const idToNum={}; goals.forEach(g=>{ idToNum[g.id]=g.seq; });   // stable seq, not position
  gv.innerHTML=goals.map((g,i)=>goalRow(g,i,r,idToNum)).join('');
}
function goalRow(g,i,r,idToNum){
  const nv=gnote(r,g.id).replace(/"/g,'&quot;');
  const pnum=(g.parent&&idToNum[g.parent])?idToNum[g.parent]:'';
  const isChild=!!g.parent;
  // Parent goals show a derived rollup status (not manual buttons); leaves stay manual.
  const ds=derivedStatus(r.goals,g);
  const statCell=(ds!==null)
    ? '<span class="ot '+ds+'" title="자식 태스크 상태에서 자동 계산">'+statLabel(ds)+'</span>'
    : statBtn(g,'backlog','대기')+statBtn(g,'in_progress','진행')+statBtn(g,'done','완료');
  const running=(g.status==='in_progress')||(ds==='on_track');
  return '<div class="goal'+(ds==='on_track'?' ontrack':(running?' running':''))+'" data-i="'+i+'" ondragover="dragOver(event,'+i+')" ondrop="dropOn(event,'+i+')" ondragleave="dragLeave(event)">'
    +'<span class="grip" draggable="true" ondragstart="dragStart(event,'+i+')" ondragend="dragEnd(event)" title="드래그하여 우선순위 변경">⠿</span>'
    +'<span class="pill" style="font-variant-numeric:tabular-nums">'+gnum(g)+'</span>'
    +'<span class="g">'+(isChild?'<span class="muted">└ </span>':'')+esc(g.text)+'</span>'
    +'<span class="stat">'+statCell+'</span>'
    +'<span class="ttime" id="tt_'+g.id+'" title="누적 작업 시간">'+fmtDur(effTracked(g))+'</span>'
    +'<span class="muted" style="font-size:12px">부모#</span>'
    +'<input type="text" inputmode="numeric" value="'+pnum+'" placeholder="–" title="부모 번호 입력 (비우면 최상위)" '
    +'onchange="setParentByNumber(\''+g.id+'\',this.value)" style="width:46px;text-align:center">'
    +'<input type="text" placeholder="리뷰 메모" value="'+nv+'" onchange="saveNote(\''+g.id+'\',this.value)" style="flex:1;min-width:100px">'
    +'<button class="btn" onclick="removeGoal(\''+g.id+'\')">삭제</button></div>';
}
function renderStages(r){
  if(r.submittedSelf){ $('st_self').innerHTML='<span class="ok">완료 '+(r.selfScore||0)+'%</span>'; $('selfRange').value=r.selfScore||0; $('selfVal').textContent=r.selfScore||0; }
  else $('st_self').innerHTML='<span class="wait">미제출</span>';
  if(r.aiScore!=null){ const cls=r.aiScore>=80?'ok':(r.aiScore>=50?'wait':'bad'); $('st_ai').innerHTML='<span class="'+cls+'">신뢰도 '+r.aiScore+'%</span>'; $('aiNote').textContent=r.aiNote||''; }
  else { $('st_ai').innerHTML='<span class="wait">대기</span>'; }
}
function buildMarkdown(d,r,conf,prov){
  const goals=r.goals||[], tops=goals.filter(g=>!g.parent);
  let md='# 오늘 리포트 ('+d.date+')\n\n- 확정 가치: '+conf.toFixed(2)+'h (잠정 '+prov.toFixed(1)+'h)\n\n';
  tops.forEach(t=>{
    const ds=derivedStatus(goals,t);
    md+='## '+t.text+(ds==='on_track'?' [on track]':(ds==='done'?' [완료]':''))+(gnote(r,t.id)?(' — '+gnote(r,t.id)):'')+'\n';
    goals.filter(c=>c.parent===t.id).forEach(c=>{ const cs=(c.status||'backlog');
      const m=cs==='in_progress'?' (진행)':(cs==='done'?' (완료)':'');
      md+='- '+c.text+m+(gnote(r,c.id)?(' — '+gnote(r,c.id)):'')+'\n'; });
    md+='\n';
  });
  return md;
}
function renderReport(d,r,conf,prov){
  const goals=r.goals||[], tops=goals.filter(g=>!g.parent);
  let html='<div class="muted" style="margin-bottom:10px">'+esc(d.date)+' · 확정 '+conf.toFixed(2)+'h (잠정 '+prov.toFixed(1)+'h)</div>';
  if(!tops.length) html+='<div class="muted">목표가 없습니다. 입력 뷰에서 추가하세요.</div>';
  tops.forEach(t=>{
    const ds=derivedStatus(goals,t);
    const tag=ds==='on_track'?'<span class="otTag">on track</span>':(ds==='done'?'<span class="otTag" style="border-color:var(--green);color:var(--green);background:rgba(54,192,138,.12)">완료</span>':'');
    html+='<h3 style="margin:12px 0 4px">'+esc(t.text)+tag+'</h3>';
    if(gnote(r,t.id)) html+='<div class="muted" style="margin-bottom:4px">'+esc(gnote(r,t.id))+'</div>';
    const kids=goals.filter(c=>c.parent===t.id);
    if(kids.length) html+='<ul>'+kids.map(c=>{ const cs=(c.status||'backlog');
      const m=cs==='in_progress'?' <span style="color:#9be3fb">(진행)</span>':(cs==='done'?' <span class="ok">(완료)</span>':'');
      return '<li>'+esc(c.text)+m+(gnote(r,c.id)?' <span class="muted">— '+esc(gnote(r,c.id))+'</span>':'')+'</li>'; }).join('')+'</ul>';
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

load();
setInterval(load,5000);
window.addEventListener('resize', load);
</script>
</body>
</html>
"""#
    }
}
