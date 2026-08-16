import Foundation

// 전략3 · 플랜 맵 visualization, served at GET /bgm-plan. Renders bgm-plan.json
// (via GET /api/bgm/plan) as day-band × 24h timeline strips so the plan's structure
// is graspable at a glance: one colored block per slot, positioned by its time
// range (overnight wrap drawn as two segments), a "now" cursor on today's band,
// and the currently governing slot highlighted. Below the strips, one detail card
// per slot shows the themes (with real track counts), the pinned opener, and the
// planner's note. Read-only — the plan itself is edited via POST /api/bgm/plan.
// Opened from the BGM player's "계획" chip (window.open → default browser).
enum BGMPlanContent {
    static func html() -> String {
        return #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>BGM 플랜 맵</title>
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
  .wrap{max-width:900px; margin:0 auto}
  .head{display:flex; align-items:baseline; gap:12px; flex-wrap:wrap; margin-bottom:4px}
  h1{font-size:20px; margin:0; letter-spacing:.2px}
  .sub{color:var(--dim); font-size:13px}
  .card{
    background:linear-gradient(180deg,var(--panel),var(--panel2));
    border:1px solid var(--line); border-radius:18px; padding:18px; margin-top:16px;
    box-shadow:0 10px 40px rgba(0,0,0,.35);
  }
  .bandtitle{font-size:13px; font-weight:700; margin:0 0 8px; display:flex; align-items:center; gap:8px}
  .bandtitle .today{font-size:11px; font-weight:600; color:#0b0c10; background:var(--accent2); border-radius:8px; padding:1px 8px}
  .strip{position:relative; height:56px; border:1px solid var(--line); border-radius:12px; background:#101219; overflow:hidden}
  .slotblk{position:absolute; top:0; bottom:0; display:flex; flex-direction:column; justify-content:center; padding:0 8px; overflow:hidden; border-left:1px solid rgba(0,0,0,.35); cursor:default}
  .slotblk .l{font-size:12px; font-weight:700; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; color:#0e0f14}
  .slotblk .t{font-size:10px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; color:rgba(10,11,16,.72); font-variant-numeric:tabular-nums}
  .slotblk.nowslot{outline:2px solid #fff; outline-offset:-2px; box-shadow:inset 0 0 18px rgba(255,255,255,.28)}
  .ticks{position:relative; height:16px; margin-top:4px}
  .tick{position:absolute; transform:translateX(-50%); font-size:10px; color:var(--dim); font-variant-numeric:tabular-nums}
  /* the now cursor: line lives inside the (overflow-clipped) strip; the time flag
     sits in the wrapper's reserved top padding so it is never clipped */
  .stripwrap{position:relative}
  .stripwrap.today{padding-top:16px}
  .nowline{position:absolute; top:0; bottom:0; width:2px; background:#fff; box-shadow:0 0 8px rgba(255,255,255,.9); z-index:30}
  .nowflag{position:absolute; top:0; transform:translateX(-50%); font-size:10px; font-weight:700; color:#fff; z-index:30; white-space:nowrap}
  .band{margin-top:18px}
  .band:first-child{margin-top:0}
  /* slot detail cards */
  .slots{display:grid; grid-template-columns:1fr; gap:10px; margin-top:12px}
  .slot{display:flex; gap:12px; align-items:flex-start; background:#12141c; border:1px solid var(--line); border-radius:14px; padding:12px 14px}
  .slot.nowslot{border-color:var(--accent2); box-shadow:0 0 18px rgba(0,212,200,.18)}
  .sw{flex:0 0 auto; width:14px; height:14px; border-radius:5px; margin-top:3px}
  .smain{flex:1 1 auto; min-width:0}
  .srow1{display:flex; gap:10px; align-items:baseline; flex-wrap:wrap}
  .slabel{font-size:14px; font-weight:700}
  .stime{font-size:12px; color:var(--dim); font-variant-numeric:tabular-nums}
  .sdays{font-size:11px; font-weight:700; border-radius:8px; padding:1px 8px; background:#1e2230; color:var(--dim)}
  .nowbadge{font-size:11px; font-weight:700; border-radius:8px; padding:1px 8px; background:var(--accent2); color:#0b0c10}
  .themes{display:flex; gap:6px; flex-wrap:wrap; margin-top:7px}
  .chip{font-size:11px; font-weight:600; border-radius:9px; padding:2px 9px; border:1px solid var(--line); color:var(--txt)}
  .chip b{font-weight:700; opacity:.75; margin-left:3px; font-variant-numeric:tabular-nums}
  .chip.missing{opacity:.45; text-decoration:line-through}
  .opener{font-size:12px; color:var(--dim); margin-top:7px}
  .opener b{color:var(--txt); font-weight:600}
  .note{font-size:12px; color:var(--dim); margin-top:5px; line-height:1.55}
  .foot{color:var(--dim); font-size:12px; margin-top:16px; line-height:1.7}
  .foot code{background:#12141c; border:1px solid var(--line); border-radius:6px; padding:1px 6px; font-size:11px}
  .err{color:#ffb4a8; font-size:13px; padding:20px 0}
</style>
</head>
<body>
<div class="wrap">
  <div class="head">
    <h1>BGM 플랜 맵</h1>
    <span class="sub" id="meta">불러오는 중…</span>
  </div>
  <div class="card" id="bands"></div>
  <div class="card">
    <div class="bandtitle">슬롯 상세</div>
    <div class="slots" id="slots"></div>
    <div class="foot" id="foot"></div>
  </div>
</div>
<script>
"use strict";
const $ = id => document.getElementById(id);
const PALETTE = ["#7c5cff","#00d4c8","#f6a821","#4e9cff","#ff7ab6","#8bd450","#c084fc","#5eead4","#fb923c","#93c5fd"];
const DAY_LABEL = {mon:"월요일", tue:"화요일", wed:"수요일", thu:"목요일", fri:"금요일",
                   sat:"토요일", sun:"일요일", weekday:"평일 (월–금)", weekend:"주말 (토·일)", all:"매일"};
const DAY_ORDER = ["mon","tue","wed","thu","fri","sat","sun","weekday","weekend","all"];
const DAY_KEYS  = ["sun","mon","tue","wed","thu","fri","sat"];   // Date.getDay() → plan day key

function minutes(hhmm){
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm||"");
  if(!m) return null;
  return (+m[1])*60 + (+m[2]);
}
// Split a slot's time range into non-wrapping [from,to) minute segments.
function segments(slot){
  const f = minutes(slot.from), t = minutes(slot.to);
  if(f==null || t==null) return [];
  if(f===t) return [[0,1440]];
  if(f<t) return [[f,t]];
  return [[f,1440],[0,t]];             // overnight wrap
}
// Mirror BGMPlanMap.slot(at:) — specific day > weekday/weekend band > "all";
// within a pass, file order decides.
function resolveSlot(slots, dayKey, band, minute){
  for(const pass of [dayKey, band, "all"]){
    const hit = slots.find(s => s.days===pass && segments(s).some(([a,b]) => minute>=a && minute<b));
    if(hit) return hit;
  }
  return null;
}
function esc(s){ const d=document.createElement("div"); d.textContent=s??""; return d.innerHTML; }
function fmtHM(min){ return String(Math.floor(min/60)).padStart(2,"0")+":"+String(min%60).padStart(2,"0"); }

async function load(){
  let j;
  try{
    j = await (await fetch("/api/bgm/plan")).json();
  }catch(e){
    $("bands").innerHTML = '<div class="err">플랜을 불러오지 못했습니다: '+esc(String(e))+'</div>';
    return;
  }
  const plan = j.plan || {slots:[]};
  const slots = plan.slots || [];
  const counts = j.themeCounts || {};
  const realThemes = new Set(j.themes || []);
  $("meta").textContent = (plan.updatedAt?("갱신 "+plan.updatedAt+" · "):"") + (plan.plannedBy||"");

  const now = new Date();
  const nowMin = now.getHours()*60 + now.getMinutes();
  const wd = now.getDay();                        // 0=Sun..6=Sat
  const todayKey = DAY_KEYS[wd];
  const todayBand = (wd===0 || wd===6) ? "weekend" : "weekday";
  const nowSlot = resolveSlot(slots, todayKey, todayBand, nowMin);

  // color per slot = file-order index
  const colorOf = s => PALETTE[slots.indexOf(s) % PALETTE.length];

  // ---- timeline bands (one strip per used days value, mon..sun first) ----
  const bandsUsed = DAY_ORDER.filter(b => slots.some(s => s.days===b));
  let bh = "";
  for(const band of bandsUsed){
    // today's cursor belongs on every strip that can govern today
    const isToday = band===todayKey || band===todayBand || band==="all";
    let blocks = "";
    // draw in REVERSE file order so earlier slots (which win resolution) sit on top
    const bandSlots = slots.filter(s => s.days===band);
    for(let i=bandSlots.length-1; i>=0; i--){
      const s = bandSlots[i];
      const isNow = isToday && s===nowSlot;
      for(const [a,b] of segments(s)){
        const left = a/1440*100, width = (b-a)/1440*100;
        blocks += '<div class="slotblk'+(isNow?" nowslot":"")+'" style="left:'+left+'%;width:'+width+'%;background:'+colorOf(s)+';z-index:'+(10+bandSlots.length-i)+'" title="'+esc(s.label)+' '+esc(s.from)+'–'+esc(s.to)+'">'
                + '<span class="l">'+esc(s.label)+'</span>'
                + '<span class="t">'+esc(s.from)+'–'+esc(s.to)+'</span></div>';
      }
    }
    const pct = nowMin/1440*100;
    const nowline = isToday ? '<div class="nowline" style="left:'+pct+'%"></div>' : "";
    const nowflag = isToday ? '<div class="nowflag" style="left:'+pct+'%">지금 '+fmtHM(nowMin)+'</div>' : "";
    let ticks = "";
    for(let h=0; h<=24; h+=3){
      ticks += '<div class="tick" style="left:'+(h/24*100)+'%">'+String(h).padStart(2,"0")+'</div>';
    }
    bh += '<div class="band">'
        + '<div class="bandtitle">'+esc(DAY_LABEL[band]||band)+(isToday?'<span class="today">오늘</span>':'')+'</div>'
        + '<div class="stripwrap'+(isToday?" today":"")+'">'+nowflag
        + '<div class="strip">'+blocks+nowline+'</div></div>'
        + '<div class="ticks">'+ticks+'</div>'
        + '</div>';
  }
  $("bands").innerHTML = bh || '<div class="err">플랜에 슬롯이 없습니다.</div>';

  // ---- slot detail cards (file order = resolution priority) ----
  let sh = "";
  for(const s of slots){
    const isNow = s===nowSlot;
    const chips = (s.themes||[]).map(t => {
      const known = realThemes.has(t);
      const n = counts[t];
      return '<span class="chip'+(known?"":" missing")+'" title="'+(known?"":"라이브러리에 없는 폴더")+'">'
           + esc(t)+(n?('<b>'+n+'곡</b>'):'')+'</span>';
    }).join("");
    sh += '<div class="slot'+(isNow?" nowslot":"")+'">'
        + '<span class="sw" style="background:'+colorOf(s)+'"></span>'
        + '<div class="smain">'
        + '<div class="srow1"><span class="slabel">'+esc(s.label)+'</span>'
        + '<span class="sdays">'+esc(DAY_LABEL[s.days]||s.days)+'</span>'
        + '<span class="stime">'+esc(s.from)+' – '+esc(s.to)+(minutes(s.from)>minutes(s.to)?" (자정 넘김)":"")+'</span>'
        + (isNow?'<span class="nowbadge">지금 이 슬롯</span>':'')
        + '</div>'
        + '<div class="themes">'+chips+'</div>'
        + (s.opener?('<div class="opener">첫 곡 고정 ♪ <b>'+esc(s.opener)+'</b></div>'):'')
        + (s.note?('<div class="note">'+esc(s.note)+'</div>'):'')
        + '</div></div>';
  }
  $("slots").innerHTML = sh;
  $("foot").innerHTML =
    '계획 파일: <code>~/.condition-mate/bgm-plan.json</code> — 직접 수정 대신 '
    + '<code>POST /api/bgm/plan</code>으로 교체하면 검증 후 즉시 반영됩니다. '
    + '우선순위: 개별 요일(<code>mon</code>..<code>sun</code>) &gt; <code>weekday</code>/<code>weekend</code> 밴드 &gt; <code>all</code>, '
    + '같은 우선순위 안에서는 파일 순서가 빠른 슬롯이 우선합니다.';
}
load();
// keep the "now" cursor honest without a heavy poll
setInterval(load, 60000);
</script>
</body>
</html>
"""#
    }
}
