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
    <div class="card"><div class="k">집중 시간</div><div class="v" id="t_focus">–</div><div class="cap">딥워크 (에디터)</div></div>
    <div class="card"><div class="k">퇴근</div><div class="v" id="t_off">–</div><div class="cap">6시간+ 공백</div></div>
    <div class="card"><div class="k">오늘 가치 (가중)</div><div class="v" id="value">–</div><div class="cap">Σ 시간 × 배수</div></div>
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

  <h2>오늘 가치 확정 (어뷰징 필터)</h2>
  <div class="panel">
    <div class="row">목표 우선순위:
      <input type="text" id="goalText" placeholder="목표 입력 후 추가" style="flex:1;min-width:160px">
      <button class="btn" onclick="addGoal()">추가</button>
    </div>
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

    <div class="row" style="margin-top:12px;font-size:15px">
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
      <thead><tr><th>시간</th><th>길이</th><th>앱 · 사이트</th><th>무드</th><th>BGM 트랙</th><th>활동 (⌨/🖱)</th><th>가치</th></tr></thead>
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
  const b = timeBuckets(d.samples);
  $('t_total').textContent = fmtH(b.total);
  $('t_desk').textContent = fmtH(b.desk);
  $('t_focus').textContent = fmtH(b.focus);
  $('t_off').textContent = b.off > 0 ? fmtH(b.off) : '–';
  drawTiers(b);
  const n=d.now;
  const siteStr=(n.site&&n.site!=='-')?' ('+esc(n.site)+')':'';
  $('now').innerHTML='지금: 앱 <b>'+esc(n.app)+siteStr+'</b> &nbsp; '+tierBadge(n.tier,n.mult)
    +' &nbsp; ⌨ '+(n.key||0)+' 🖱 '+(n.mouse||0)+' &nbsp; 전략 <b>'+esc(n.profile)+'</b> · BGM <b>'+esc(n.track)+'</b>';
  const valSec=d.samples.reduce((a,s)=>a+(s.active||0)*(s.mult||1),0);
  $('value').textContent=(valSec/3600).toFixed(1)+'h';
  drawChart(d.samples);
  drawStrip(d.samples);
  renderSummary(d.samples);
  renderTimeline(d.samples);
  renderApps(d.samples);
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
      last.keySum+=(s.key||0); last.mouseSum+=(s.mouse||0);
    } else {
      segs.push({key,app:s.app||'-',site:s.site||'-',profile:s.profile||'-',track:s.track||'-',
                 tier:s.tier||'소극',mult:s.mult||1,startT:s.t,endT:s.t,mins:1,
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
      +'<td>'+tierBadge(g.tier,g.mult)+'</td>'
      +'</tr>';
  }).join('');
}
function esc(s){ return (s||'-').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function minOfDay(s){ const dt=new Date(s.t*1000); return dt.getHours()*60+dt.getMinutes(); }
function fmtH(min){ const h=Math.floor(min/60), m=min%60; return h>0? h+'시간 '+m+'분' : m+'분'; }
// Time buckets. Activity anchors = minutes with input (or a meeting). A "work
// span" is anchors separated by < 6h; gaps >= 6h are 퇴근 (off, span split).
// Total = span coverage (rest+meeting+work between anchors), excluding 퇴근.
// focus ⊆ desk ⊆ total. Each sample = 1 minute.
function timeBuckets(samples){
  const SIXH=6*3600;
  const anchors=[]; let desk=0, focus=0;
  samples.slice().sort((a,b)=>a.t-b.t).forEach(s=>{
    const act=(s.active||0)>0;
    if(act && (s.tier==='중간'||s.tier==='적극')) desk++;
    if(act && s.tier==='적극') focus++;
    if(act || s.meeting) anchors.push(s.t);
  });
  let total=0, off=0;
  if(anchors.length){
    total=1; // first anchor minute
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
