import Foundation

// Standalone judging page served at GET /bgm-timeline-test.
//
// Purpose: let the user SEE and JUDGE a proposed "daily life timeline" model for BGM
// selection BEFORE it is wired into ConditionDirector. Today the director picks a track
// purely from live activity → target BPM → nearest track, so a flat activity pattern keeps
// landing on the same 1–2 files. This page proposes a second axis: time-of-day × day-of-week
// → mood band (BPM range), and shows, for any (weekday, hour), which library tracks would be
// eligible and lets the user actually play them.
//
// It is read-only and self-contained: it fetches the real library from GET /api/bgm/list and
// streams same-origin from GET /bgm-audio/<id>. The schedule lives entirely in JS here so the
// user can eyeball the mapping; nothing in this page changes the running director.
enum BGMTimelineTestContent {
    static func html() -> String {
        return #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BGM 라이프타임 테스트</title>
<style>
  :root{
    --bg:#0b0c10; --panel:#15171f; --panel2:#1c1f2a; --line:#2a2e3c;
    --txt:#e8eaf0; --dim:#9aa0b4; --accent:#7c5cff; --accent2:#00d4c8;
    --chill:#4aa3ff; --steady:#33c98a; --focus:#ffb020; --hype:#ff5c7c; --unknown:#4a4f60;
  }
  *{box-sizing:border-box}
  body{
    margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Apple SD Gothic Neo","Noto Sans KR",sans-serif;
    background:radial-gradient(1200px 700px at 70% -10%, #201a3a 0%, var(--bg) 55%) fixed;
    color:var(--txt); min-height:100vh; padding:18px 16px 80px;
  }
  .wrap{max-width:960px; margin:0 auto}
  .head{display:flex; align-items:baseline; gap:12px; flex-wrap:wrap; margin-bottom:4px}
  h1{font-size:20px; margin:0; letter-spacing:.2px}
  .sub{color:var(--dim); font-size:12.5px; line-height:1.6; margin:6px 0 16px}
  .card{background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:16px; margin-bottom:16px}
  .card h2{font-size:13px; margin:0 0 12px; color:var(--dim); font-weight:600; letter-spacing:.4px; text-transform:uppercase}
  .badge{display:inline-flex; align-items:center; gap:5px; font-size:11px; padding:2px 8px; border-radius:20px; background:var(--panel2); border:1px solid var(--line)}
  .dot{width:9px; height:9px; border-radius:50%; display:inline-block}
  .legend{display:flex; gap:14px; flex-wrap:wrap; font-size:12px; color:var(--dim); margin-bottom:10px}
  /* Weekly heatmap */
  .heat{overflow-x:auto}
  table.grid{border-collapse:collapse; font-size:10.5px}
  table.grid th{color:var(--dim); font-weight:500; padding:2px 4px; text-align:center; white-space:nowrap}
  table.grid td.hr{width:22px; height:20px; padding:0; cursor:pointer; position:relative}
  table.grid td.hr:hover{outline:2px solid #fff; outline-offset:-2px; z-index:2}
  table.grid td.hr.now{outline:2px solid var(--accent2); outline-offset:-2px; z-index:3}
  table.grid td.hr.sel{outline:2px solid #fff; outline-offset:-2px; z-index:3}
  table.grid td.dayname{color:var(--dim); padding-right:8px; text-align:right; white-space:nowrap; font-size:11.5px}
  table.grid td.dayname.wknd{color:var(--hype)}
  /* Scrubber */
  .row{display:flex; gap:8px; align-items:center; flex-wrap:wrap}
  .daybtns{display:flex; gap:6px; flex-wrap:wrap}
  .daybtn{padding:5px 11px; border-radius:9px; border:1px solid var(--line); background:var(--panel2); color:var(--txt); font-size:12.5px; cursor:pointer}
  .daybtn.on{background:var(--accent); border-color:var(--accent); color:#fff}
  input[type=range]{width:100%; accent-color:var(--accent)}
  .slabel{display:flex; justify-content:space-between; color:var(--dim); font-size:11px; margin-top:2px}
  .now-seg{display:flex; gap:14px; flex-wrap:wrap; align-items:center; margin-top:12px; padding:12px; border-radius:10px; background:var(--panel2); border:1px solid var(--line)}
  .now-seg .big{font-size:17px; font-weight:600}
  .now-seg .mut{color:var(--dim); font-size:12.5px}
  /* Track list */
  .tracks{display:flex; flex-direction:column; gap:6px}
  .trk{display:flex; align-items:center; gap:10px; padding:8px 10px; border-radius:9px; background:var(--panel2); border:1px solid var(--line)}
  .trk.playing{border-color:var(--accent2); box-shadow:0 0 0 1px var(--accent2) inset}
  .trk .play{width:30px; height:30px; border-radius:50%; border:1px solid var(--line); background:#0e1017; color:var(--txt); cursor:pointer; font-size:12px; flex:0 0 auto}
  .trk .play:hover{border-color:var(--accent)}
  .trk .t{flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:13px}
  .trk .bpm{font-size:11px; color:var(--dim); flex:0 0 auto; font-variant-numeric:tabular-nums}
  .warn{color:var(--hype); font-size:12.5px; margin-top:8px}
  .ok{color:var(--steady); font-size:12.5px; margin-top:8px}
  .btn{padding:8px 14px; border-radius:9px; border:1px solid var(--accent); background:var(--accent); color:#fff; font-size:12.5px; cursor:pointer}
  .btn.ghost{background:transparent; color:var(--txt); border-color:var(--line)}
  /* Coverage bars */
  .cov{display:flex; flex-direction:column; gap:8px}
  .covrow{display:flex; align-items:center; gap:10px; font-size:12px}
  .covrow .name{width:120px; flex:0 0 auto; color:var(--dim)}
  .covbar{flex:1; height:16px; background:var(--panel2); border-radius:6px; overflow:hidden; position:relative}
  .covbar .fill{height:100%; border-radius:6px}
  .covrow .cnt{width:70px; text-align:right; flex:0 0 auto; font-variant-numeric:tabular-nums}
  #nowbar{position:fixed; left:0; right:0; bottom:0; background:rgba(14,16,23,.96); border-top:1px solid var(--line); padding:9px 16px; display:flex; align-items:center; gap:12px; font-size:12.5px; backdrop-filter:blur(8px)}
  #nowbar .np{flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:var(--dim)}
  #nowbar .np b{color:var(--txt)}
  a.plain{color:var(--accent2); text-decoration:none}
</style>
</head>
<body>
<div class="wrap">
  <div class="head">
    <h1>BGM 라이프타임 테스트</h1>
    <span class="badge" id="clock">--</span>
  </div>
  <div class="sub">
    지금은 BGM이 <b>활동량(키·마우스) → 목표 BPM → 가장 가까운 곡</b> 하나로만 골라져서, 하루 종일 비슷한 곡만 반복됩니다.
    여기서는 <b>요일 × 시간대 → 무드(BPM 밴드)</b> 스케줄을 제안합니다. 아래에서 요일과 시간을 옮겨 보며
    그 시간대에 <b>어떤 곡이 후보로 잡히고 실제로 어떻게 들리는지</b> 직접 듣고 판단하세요. (이 페이지는 실제 재생 로직을 바꾸지 않는 미리보기입니다.)
  </div>

  <div class="card">
    <h2>주간 스케줄 (요일 × 시간)</h2>
    <div class="legend" id="legend"></div>
    <div class="heat"><table class="grid" id="heat"></table></div>
    <div style="color:var(--dim); font-size:11.5px; margin-top:8px">셀을 클릭하면 아래 스크러버가 그 요일·시간으로 이동합니다. 청록 테두리 = 지금.</div>
  </div>

  <div class="card">
    <h2>시간대 미리듣기</h2>
    <div class="row" style="justify-content:space-between; margin-bottom:10px">
      <div class="daybtns" id="daybtns"></div>
      <button class="btn ghost" id="jumpnow">지금으로</button>
    </div>
    <input type="range" id="hour" min="0" max="1439" step="10" value="600">
    <div class="slabel"><span>00:00</span><span>06:00</span><span>12:00</span><span>18:00</span><span>24:00</span></div>
    <div class="now-seg" id="nowseg"></div>
    <div style="display:flex; gap:8px; margin:14px 0 6px; align-items:center; flex-wrap:wrap">
      <div style="font-size:12.5px; color:var(--dim)">이 밴드 후보곡</div>
      <button class="btn" id="autoplay">이 시간대 자동재생 ▶</button>
      <button class="btn ghost" id="shuffle">다른 곡으로</button>
    </div>
    <div class="tracks" id="tracks"></div>
    <div id="covernote"></div>
  </div>

  <div class="card">
    <h2>라이브러리 커버리지 — "왜 2곡만 도는가"</h2>
    <div style="color:var(--dim); font-size:12px; margin-bottom:10px">
      내 음악 폴더의 곡을 BPM 밴드별로 센 것. 특정 밴드에 곡이 없으면 그 시간대는 재생할 게 없고,
      한 밴드에 곡이 몰려 있으면 지금처럼 같은 곡만 반복됩니다.
    </div>
    <div class="cov" id="cov"></div>
    <div id="covtotal" style="color:var(--dim); font-size:12px; margin-top:10px"></div>
  </div>
</div>

<div id="nowbar">
  <span>🎵</span>
  <div class="np" id="np">재생 중인 곡 없음</div>
  <button class="btn ghost" id="stop">정지</button>
</div>

<audio id="audio" preload="none"></audio>

<script>
// ---- Mood bands (mirror of Swift BGMProfile.all) --------------------------
const BANDS = {
  chill:   {label:'칠 (느긋)',   min:75,  max:100, cssvar:'--chill'},
  steady:  {label:'스테디 (안정)', min:100, max:125, cssvar:'--steady'},
  focus:   {label:'집중 (몰입)',  min:120, max:150, cssvar:'--focus'},
  hype:    {label:'하이프 (고조)', min:140, max:175, cssvar:'--hype'},
};
const BANDKEYS = ['chill','steady','focus','hype'];
function bandColor(k){ return getComputedStyle(document.documentElement).getPropertyValue(BANDS[k].cssvar).trim(); }

// ---- The proposed daily life timeline -------------------------------------
// Each template is a list of [startHour, bandKey, label]. A segment runs until
// the next segment's startHour (last one wraps to 24:00).
const WEEKDAY = [
  [0,'chill','심야·수면'],
  [6,'chill','기상·시동'],
  [8,'steady','출근·준비'],
  [9,'focus','오전 딥워크'],
  [12,'chill','점심·휴식'],
  [13,'steady','나른한 오후'],
  [14,'focus','오후 집중'],
  [17,'steady','마무리·퇴근'],
  [19,'chill','저녁 휴식'],
  [22,'chill','밤·정리'],
];
const WEEKEND = [
  [0,'chill','심야·수면'],
  [8,'chill','느긋한 아침'],
  [11,'steady','브런치·활동'],
  [14,'focus','낮 활동'],
  [18,'chill','저녁'],
  [22,'chill','밤'],
];
const DAYNAMES = ['일','월','화','수','목','금','토'];
// Per-weekday variation so "요일별 분리"가 실제로 눈에 보이게: 월=워밍업, 금=불금 스퍼트.
function templateFor(day){
  if(day===0||day===6) return WEEKEND;
  if(day===1) return WEEKDAY.map(s => s[0]===9 ? [9,'steady','오전 워밍업'] : s.slice());
  if(day===5) return WEEKDAY.map(s => {
    if(s[0]===14) return [14,'focus','오후 집중'];
    if(s[0]===17) return [17,'hype','불금 스퍼트'];
    if(s[0]===19) return [19,'steady','불금 저녁'];
    return s.slice();
  });
  return WEEKDAY.map(s=>s.slice());
}
function segAt(day, hour){
  const t = templateFor(day);
  let cur = t[0];
  for(const s of t){ if(hour >= s[0]) cur = s; else break; }
  return {band:cur[1], label:cur[2], start:cur[0]};
}

// ---- State ----------------------------------------------------------------
let LIB = [];        // {id,title,bpm}
let selDay = 1;      // selected weekday (0=일..6=토)
let selMin = 600;    // selected minute-of-day (0..1439)
let curPlayId = -1;

const audio = document.getElementById('audio');
const $ = id => document.getElementById(id);

function fmt(min){
  const h = Math.floor(min/60), m = min%60;
  return String(h).padStart(2,'0')+':'+String(m).padStart(2,'0');
}
function tracksForBand(k){
  const b = BANDS[k];
  return LIB.filter(t => t.bpm>0 && t.bpm>=b.min && t.bpm<=b.max)
            .sort((a,z)=>a.bpm-z.bpm);
}

// ---- Legend ---------------------------------------------------------------
function renderLegend(){
  $('legend').innerHTML = BANDKEYS.map(k =>
    `<span><span class="dot" style="background:${bandColor(k)}"></span>${BANDS[k].label} · ${BANDS[k].min}–${BANDS[k].max}bpm</span>`
  ).join('');
}

// ---- Weekly heatmap -------------------------------------------------------
function renderHeat(){
  const now = new Date();
  const nowDay = now.getDay(), nowHour = now.getHours();
  let html = '<tr><th></th>';
  for(let h=0; h<24; h++) html += `<th>${h}</th>`;
  html += '</tr>';
  for(let d=0; d<7; d++){
    const wknd = (d===0||d===6) ? ' wknd' : '';
    html += `<tr><td class="dayname${wknd}">${DAYNAMES[d]}</td>`;
    for(let h=0; h<24; h++){
      const s = segAt(d,h);
      const isNow = (d===nowDay && h===nowHour) ? ' now' : '';
      const isSel = (d===selDay && h===Math.floor(selMin/60)) ? ' sel' : '';
      html += `<td class="hr${isNow}${isSel}" data-d="${d}" data-h="${h}" title="${DAYNAMES[d]} ${h}:00 · ${s.label} · ${BANDS[s.band].label}" style="background:${bandColor(s.band)}"></td>`;
    }
    html += '</tr>';
  }
  $('heat').innerHTML = html;
  $('heat').querySelectorAll('td.hr').forEach(td=>{
    td.onclick = ()=>{ selDay=+td.dataset.d; selMin=(+td.dataset.h)*60+30; syncAll(); };
  });
}

// ---- Day buttons ----------------------------------------------------------
function renderDayBtns(){
  $('daybtns').innerHTML = DAYNAMES.map((n,d)=>
    `<button class="daybtn${d===selDay?' on':''}" data-d="${d}">${n}</button>`
  ).join('');
  $('daybtns').querySelectorAll('.daybtn').forEach(b=>{
    b.onclick = ()=>{ selDay=+b.dataset.d; syncAll(); };
  });
}

// ---- Scrubber / now-seg / tracks ------------------------------------------
function renderScrubber(){
  const hour = Math.floor(selMin/60);
  const s = segAt(selDay, hour);
  const b = BANDS[s.band];
  $('nowseg').innerHTML =
    `<div><div class="big">${DAYNAMES[selDay]}요일 ${fmt(selMin)}</div>`
    + `<div class="mut">구간: ${s.label}</div></div>`
    + `<div style="margin-left:auto; text-align:right">`
    + `<div class="big"><span class="dot" style="background:${bandColor(s.band)}"></span> ${b.label}</div>`
    + `<div class="mut">목표 ${b.min}–${b.max} BPM</div></div>`;

  const list = tracksForBand(s.band);
  $('tracks').innerHTML = list.length
    ? list.map(t=>trackRow(t)).join('')
    : `<div class="mut" style="color:var(--dim);padding:6px">이 밴드(${b.min}–${b.max}bpm)에 해당하는 곡이 라이브러리에 없습니다.</div>`;
  bindPlays();

  if(list.length===0)
    $('covernote').innerHTML = `<div class="warn">⚠ 이 시간대에 재생할 곡이 0개 — 이 밴드의 음악을 추가하거나 BPM 태그를 확인하세요.</div>`;
  else if(list.length===1)
    $('covernote').innerHTML = `<div class="warn">⚠ 후보 1곡뿐 — 이 시간대에는 항상 같은 곡이 나옵니다.</div>`;
  else
    $('covernote').innerHTML = `<div class="ok">✓ 후보 ${list.length}곡 — 이 시간대에 번갈아 재생 가능합니다.</div>`;
}
function trackRow(t){
  const playing = t.id===curPlayId ? ' playing' : '';
  return `<div class="trk${playing}" data-id="${t.id}">`
    + `<button class="play">${t.id===curPlayId?'❚❚':'▶'}</button>`
    + `<span class="t">${escapeHtml(t.title)}</span>`
    + `<span class="bpm">${t.bpm} bpm</span></div>`;
}
function bindPlays(){
  $('tracks').querySelectorAll('.trk').forEach(row=>{
    const id = +row.dataset.id;
    row.querySelector('.play').onclick = ()=>{
      if(id===curPlayId && !audio.paused){ audio.pause(); }
      else { playTrack(id); }
    };
  });
}

// ---- Playback -------------------------------------------------------------
function playTrack(id){
  const t = LIB.find(x=>x.id===id); if(!t) return;
  curPlayId = id;
  audio.src = '/bgm-audio/'+id;
  audio.play().catch(()=>{});
  $('np').innerHTML = `<b>${escapeHtml(t.title)}</b> · ${t.bpm} bpm`;
  refreshPlayingUI();
}
function autoplayBand(shuffle){
  const s = segAt(selDay, Math.floor(selMin/60));
  const list = tracksForBand(s.band);
  if(!list.length) return;
  let pick;
  if(shuffle && list.length>1){
    do { pick = list[Math.floor(Math.random()*list.length)]; } while(pick.id===curPlayId);
  } else {
    // nearest to band center = the "representative" track for this slot
    const c = (BANDS[s.band].min+BANDS[s.band].max)/2;
    pick = list.reduce((a,z)=> Math.abs(z.bpm-c)<Math.abs(a.bpm-c)?z:a);
  }
  playTrack(pick.id);
}
function refreshPlayingUI(){
  $('tracks').querySelectorAll('.trk').forEach(row=>{
    const id=+row.dataset.id, on=(id===curPlayId && !audio.paused);
    row.classList.toggle('playing', id===curPlayId);
    row.querySelector('.play').textContent = on ? '❚❚' : '▶';
  });
}
audio.onplay = refreshPlayingUI;
audio.onpause = refreshPlayingUI;
audio.onended = ()=>{ autoplayBand(true); };   // roll to another track in the same band

// ---- Coverage -------------------------------------------------------------
function renderCoverage(){
  const withBpm = LIB.filter(t=>t.bpm>0);
  const unknown = LIB.length - withBpm.length;
  const maxc = Math.max(1, ...BANDKEYS.map(k=>tracksForBand(k).length), unknown);
  let html='';
  for(const k of BANDKEYS){
    const n = tracksForBand(k).length;
    html += covRow(BANDS[k].label+' ('+BANDS[k].min+'–'+BANDS[k].max+')', n, maxc, bandColor(k));
  }
  if(unknown>0) html += covRow('BPM 미상', unknown, maxc, getComputedStyle(document.documentElement).getPropertyValue('--unknown').trim());
  $('cov').innerHTML = html;
  $('covtotal').textContent = `총 ${LIB.length}곡 (BPM 있음 ${withBpm.length} · 미상 ${unknown}). 밴드 경계가 겹쳐서(예: 120–125) 한 곡이 두 밴드에 잡힐 수 있습니다.`;
}
function covRow(name, n, maxc, color){
  const pct = Math.round(n/maxc*100);
  return `<div class="covrow"><span class="name">${name}</span>`
    + `<span class="covbar"><span class="fill" style="width:${pct}%;background:${color}"></span></span>`
    + `<span class="cnt">${n}곡</span></div>`;
}

// ---- Sync -----------------------------------------------------------------
function syncAll(){
  $('hour').value = selMin;
  renderDayBtns();
  renderHeat();
  renderScrubber();
}
function escapeHtml(s){ return (s||'').replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

// ---- Clock ----------------------------------------------------------------
function tickClock(){
  const n=new Date();
  const s=segAt(n.getDay(), n.getHours());
  $('clock').innerHTML = `지금 · ${DAYNAMES[n.getDay()]} ${String(n.getHours()).padStart(2,'0')}:${String(n.getMinutes()).padStart(2,'0')} · `
    + `<span class="dot" style="background:${bandColor(s.band)}"></span> ${BANDS[s.band].label}`;
}

// ---- Wire up --------------------------------------------------------------
$('hour').oninput = e=>{ selMin=+e.target.value; renderScrubber();
  // keep heatmap 'sel' outline roughly in sync without full re-render churn
  const h=Math.floor(selMin/60);
  $('heat').querySelectorAll('td.hr.sel').forEach(td=>td.classList.remove('sel'));
  const cell=$('heat').querySelector(`td.hr[data-d="${selDay}"][data-h="${h}"]`);
  if(cell) cell.classList.add('sel');
};
$('jumpnow').onclick = ()=>{ const n=new Date(); selDay=n.getDay(); selMin=n.getHours()*60+n.getMinutes(); syncAll(); };
$('autoplay').onclick = ()=>autoplayBand(false);
$('shuffle').onclick = ()=>autoplayBand(true);
$('stop').onclick = ()=>{ audio.pause(); audio.removeAttribute('src'); audio.load(); curPlayId=-1; $('np').textContent='재생 중인 곡 없음'; refreshPlayingUI(); renderScrubber(); };

async function boot(){
  renderLegend();
  const n=new Date(); selDay=n.getDay(); selMin=n.getHours()*60+n.getMinutes();
  try{
    const r = await fetch('/api/bgm/list');
    const j = await r.json();
    LIB = (j.tracks||[]).map(t=>({id:t.id, title:t.title, bpm:+t.bpm||0}));
  }catch(e){ LIB=[]; }
  syncAll();
  renderCoverage();
  tickClock(); setInterval(tickClock, 30000);
}
boot();
</script>
</body>
</html>
"""#
    }
}
