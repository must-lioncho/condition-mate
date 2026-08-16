import Foundation

// Standalone planning/prototype page served at GET /lounge-break-test.
//
// 기획 프로토타입 — "라운지 브레이크" (user-initiated BGM override).
//
// Today the director (BGM BJ) auto-drives selection from the 전략3 plan map. This page
// explores letting the USER step away on demand: hit a button to switch the whole vibe to
// the club lounge (warm, crowd, reverb) for a short destress break, then return to work —
// "잠깐 클럽 라운지 가서 스트레스 풀다가 다시 회사 복귀." It is a design exploration: the
// three interaction models (프리셋 타이머 / 무제한 토글 / 하이브리드) are all simulated in
// JS so the user can FEEL each before we commit. Nothing here touches the running app.
//
// When wired for real, the break = a manual override slot that wins over the plan gate for
// its duration (ConditionDirector already has forced-switch + a themed pool concept), plus a
// venue-effect swap (BGMPlayerContent's convolution/crowd engine) for the "club" feeling.
enum LoungeBreakTestContent {
    static func html() -> String {
        return #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>라운지 브레이크 — 기획 프로토타입</title>
<style>
  :root{
    --bg:#0b0c10; --panel:#15171f; --panel2:#1c1f2a; --line:#2a2e3c;
    --txt:#e8eaf0; --dim:#9aa0b4; --dim2:#6b7188;
    /* work vibe (cool) */
    --accent:#7c5cff; --accent2:#00d4c8;
    /* lounge vibe (warm velvet) */
    --lounge1:#f6a821; --lounge2:#d14b8f; --lounge-bg1:#2a1420; --lounge-bg2:#1a0f14;
    --ok:#33c98a; --warn:#ffb020;
  }
  *{box-sizing:border-box}
  body{
    margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Apple SD Gothic Neo","Noto Sans KR",sans-serif;
    background:radial-gradient(1200px 700px at 70% -10%, #1a1a33 0%, var(--bg) 55%) fixed;
    color:var(--txt); min-height:100vh; padding:20px 16px 60px;
  }
  .wrap{max-width:760px; margin:0 auto}
  h1{font-size:20px; margin:0; letter-spacing:.2px}
  .sub{color:var(--dim); font-size:13px; line-height:1.7; margin:8px 0 18px}
  .sub b{color:var(--txt); font-weight:600}
  .card{background:linear-gradient(180deg,var(--panel),var(--panel2)); border:1px solid var(--line);
    border-radius:18px; padding:18px; margin-top:16px; box-shadow:0 10px 40px rgba(0,0,0,.35)}
  .lbl{font-size:11.5px; color:var(--dim2); text-transform:uppercase; letter-spacing:.4px; margin:0 0 10px}

  /* mode selector */
  .modes{display:flex; gap:8px; flex-wrap:wrap}
  .modebtn{flex:1 1 30%; min-width:150px; text-align:left; padding:12px 14px; border-radius:13px;
    border:1px solid var(--line); background:#12141c; color:var(--txt); cursor:pointer; transition:.14s}
  .modebtn:hover{border-color:var(--accent)}
  .modebtn.on{border-color:var(--accent); background:linear-gradient(160deg,rgba(124,92,255,.18),#12141c); box-shadow:0 0 26px rgba(124,92,255,.2)}
  .modebtn .mt{font-size:13.5px; font-weight:700}
  .modebtn .md{font-size:11.5px; color:var(--dim); margin-top:4px; line-height:1.5}
  .modebtn .rec{font-size:10px; font-weight:700; color:var(--accent2); border:1px solid var(--accent2); border-radius:7px; padding:1px 6px; margin-left:6px}

  /* the stage — the vibe surface that transitions work <-> lounge */
  .stage{position:relative; border-radius:18px; overflow:hidden; border:1px solid var(--line);
    background:radial-gradient(700px 300px at 30% -20%, #201a3a 0%, #101019 60%); transition:background .9s ease}
  .stage.lounge{background:radial-gradient(700px 320px at 70% -10%, var(--lounge-bg1) 0%, var(--lounge-bg2) 62%)}
  .stinner{position:relative; z-index:2; padding:22px}
  /* crowd/light overlay only in lounge */
  .glow{position:absolute; inset:0; z-index:1; opacity:0; transition:opacity .9s ease; pointer-events:none;
    background:radial-gradient(220px 120px at 20% 90%, rgba(246,168,33,.18), transparent 70%),
               radial-gradient(240px 130px at 82% 85%, rgba(209,75,143,.20), transparent 70%)}
  .stage.lounge .glow{opacity:1}

  .nowrow{display:flex; align-items:center; gap:14px}
  .disc{width:52px; height:52px; border-radius:14px; flex:0 0 auto; display:grid; place-items:center; font-size:22px;
    background:linear-gradient(145deg,#2a2340,#171526); border:1px solid var(--line); transition:.6s}
  .stage.lounge .disc{background:linear-gradient(145deg,#3a1f2e,#241017); border-color:#5a2c3f}
  .nowmeta{flex:1; min-width:0}
  .vibe{font-size:11px; font-weight:700; letter-spacing:.5px; text-transform:uppercase; color:var(--accent2); transition:.5s}
  .stage.lounge .vibe{color:var(--lounge1)}
  .track{font-size:16px; font-weight:700; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; margin-top:2px}
  .subline{font-size:12px; color:var(--dim); margin-top:3px}
  /* equalizer */
  .eq{display:flex; align-items:flex-end; gap:3px; height:26px}
  .eq i{width:4px; background:var(--accent2); border-radius:2px; animation:bounce 1s infinite ease-in-out}
  .stage.lounge .eq i{background:var(--lounge1)}
  .eq i:nth-child(2){animation-delay:.15s} .eq i:nth-child(3){animation-delay:.3s}
  .eq i:nth-child(4){animation-delay:.45s} .eq i:nth-child(5){animation-delay:.6s}
  @keyframes bounce{0%,100%{height:7px}50%{height:24px}}

  /* action row */
  .actions{margin-top:20px; display:flex; align-items:center; gap:12px; flex-wrap:wrap}
  .breakbtn{border:none; border-radius:13px; padding:13px 20px; font-size:14px; font-weight:700; cursor:pointer;
    color:#0b0c10; background:linear-gradient(145deg,var(--lounge1),var(--lounge2)); box-shadow:0 8px 26px rgba(209,75,143,.28)}
  .breakbtn:hover{filter:brightness(1.06)}
  .backbtn{border:none; border-radius:13px; padding:13px 20px; font-size:14px; font-weight:700; cursor:pointer;
    color:#fff; background:linear-gradient(145deg,var(--accent),#5a3ff0); box-shadow:0 8px 26px rgba(124,92,255,.3)}
  .backbtn:hover{filter:brightness(1.08)}
  .ghost{background:none; border:1px solid var(--line); color:var(--dim); border-radius:11px; padding:12px 14px; font-size:13px; cursor:pointer}
  .ghost:hover{color:var(--txt); border-color:var(--dim)}

  /* break status */
  .brk{display:none; align-items:center; gap:14px; flex-wrap:wrap}
  .brk.show{display:flex}
  .timer{font-size:28px; font-weight:800; font-variant-numeric:tabular-nums; color:var(--lounge1); letter-spacing:.5px}
  .brkinfo{font-size:12px; color:var(--dim); line-height:1.55}
  .brkinfo b{color:var(--txt)}
  /* preset chips (A) */
  .presets{display:flex; gap:7px}
  .preset{border:1px solid var(--line); background:#12141c; color:var(--txt); border-radius:10px; padding:7px 13px; font-size:13px; cursor:pointer}
  .preset:hover{border-color:var(--lounge1)}
  .preset.on{border-color:var(--lounge1); background:rgba(246,168,33,.14); color:var(--lounge1)}

  /* progress ring background bar */
  .pbar{height:5px; border-radius:3px; background:#20222c; overflow:hidden; margin-top:14px}
  .pfill{height:100%; width:0%; background:linear-gradient(90deg,var(--lounge1),var(--lounge2)); transition:width 1s linear}

  /* work session strip: does the challenge keep running? */
  .sess{display:flex; align-items:center; gap:10px; font-size:12px; color:var(--dim); margin-top:16px; padding-top:14px; border-top:1px solid var(--line)}
  .dot{width:8px; height:8px; border-radius:50%; background:var(--ok); box-shadow:0 0 8px var(--ok)}
  .dot.brk{background:var(--lounge1); box-shadow:0 0 8px var(--lounge1)}

  /* design decision list */
  .q{font-size:13px; line-height:1.7; color:var(--dim); margin:0}
  .q li{margin:9px 0}
  .q b{color:var(--txt)}
  .pill{font-size:11px; font-weight:700; border-radius:8px; padding:1px 8px; margin-right:6px}
  .pill.a{background:rgba(0,212,200,.14); color:var(--accent2)}
  .pill.o{background:rgba(255,176,32,.14); color:var(--warn)}
  .foot{color:var(--dim2); font-size:11.5px; margin-top:14px; line-height:1.7}
  code{background:#12141c; border:1px solid var(--line); border-radius:6px; padding:1px 6px; font-size:11px}
  .toast{position:fixed; left:50%; bottom:26px; transform:translateX(-50%) translateY(20px); opacity:0;
    background:#1c1f2a; border:1px solid var(--line); color:var(--txt); font-size:13px; padding:11px 18px; border-radius:12px;
    box-shadow:0 12px 40px rgba(0,0,0,.5); transition:.25s; z-index:50}
  .toast.show{opacity:1; transform:translateX(-50%) translateY(0)}
</style>
</head>
<body>
<div class="wrap">
  <h1>라운지 브레이크 · 기획 프로토타입</h1>
  <div class="sub">
    지금은 <b>BGM 디렉터(BJ)가 자동으로</b> 시간·활동에 맞춰 곡을 골라줍니다. 여기에 <b>유저가 직접 "잠깐 라운지 다녀오기"</b>를
    누를 수 있게 하려는 기획입니다 — 클럽 라운지로 분위기를 확 바꿔 스트레스를 풀고, 다시 <b>회사로 복귀</b>.
    아래 세 가지 복귀 방식을 <b>직접 눌러 느껴보고</b> 어떤 게 맞는지 정합니다. (이 페이지는 시뮬레이션 — 실제 앱엔 영향 없음)
  </div>

  <div class="card">
    <p class="lbl">복귀 방식 — 하나 골라 아래 스테이지에서 체험</p>
    <div class="modes" id="modes">
      <button class="modebtn on" data-mode="preset">
        <div class="mt">A · 프리셋 타이머</div>
        <div class="md">5·10·15분을 정해 들어가면 카운트다운 후 자동으로 회사 복귀. "정해진 쉬는 시간"</div>
      </button>
      <button class="modebtn" data-mode="toggle">
        <div class="mt">B · 무제한 토글</div>
        <div class="md">시간 제한 없이 라운지 유지, 내가 "복귀" 누를 때까지. "내가 정하는 복귀"</div>
      </button>
      <button class="modebtn" data-mode="hybrid">
        <div class="mt">C · 하이브리드 <span class="rec">추천</span></div>
        <div class="md">기본 10분 타이머로 시작하되, "조금 더"로 연장하거나 언제든 즉시 복귀. 방심·과몰입 둘 다 방지</div>
      </button>
    </div>
  </div>

  <div class="card" style="padding:0; overflow:hidden">
    <div class="stage" id="stage">
      <div class="glow"></div>
      <div class="stinner">
        <div class="nowrow">
          <div class="disc" id="disc">🎧</div>
          <div class="nowmeta">
            <div class="vibe" id="vibe">집중 모드 · 오후 오피스</div>
            <div class="track" id="track">[123] Neural Dashboard Glow</div>
            <div class="subline" id="subline">디렉터가 활동 강도에 맞춰 선곡 중 · 96 BPM</div>
          </div>
          <div class="eq"><i></i><i></i><i></i><i></i><i></i></div>
        </div>

        <div class="pbar" id="pbarWrap" style="display:none"><div class="pfill" id="pfill"></div></div>

        <div class="actions" id="actions">
          <!-- work state: the break trigger -->
          <button class="breakbtn" id="goBreak" onclick="startBreak()">🍸 잠깐 라운지 다녀오기</button>
          <span style="font-size:12px;color:var(--dim)">지금 분위기가 답답하면 잠깐 벗어났다 오세요</span>

          <!-- break state -->
          <div class="brk" id="brkPanel">
            <span class="timer" id="timer">10:00</span>
            <div class="presets" id="presets"></div>
            <button class="backbtn" onclick="endBreak(true)">↩ 회사 복귀</button>
            <button class="ghost" id="extendBtn" onclick="extend()" style="display:none">+5분 더</button>
            <div class="brkinfo" id="brkinfo"></div>
          </div>
        </div>

        <div class="sess">
          <span class="dot" id="sessDot"></span>
          <span id="sessText">작업 세션은 계속 진행 중 — 소리만 쉬는 겁니다 (컨디션 게이지는 유지)</span>
        </div>
      </div>
    </div>
  </div>

  <div class="card">
    <p class="lbl">이번 체험에서 결정할 것 (기획 질문)</p>
    <ul class="q">
      <li><span class="pill a">핵심</span><b>복귀 방식은 A / B / C 중 무엇?</b> — 위 세 개를 직접 눌러보고 정합니다. (제 추천은 C 하이브리드)</li>
      <li><span class="pill o">확인</span><b>라운지 중 작업 세션은?</b> — 지금 프로토타입은 "계속 진행, 소리만 휴식"으로 뒀습니다. 아예 "작업도 일시정지"가 맞을지.</li>
      <li><span class="pill o">확인</span><b>분위기 전환 강도</b> — 라운지 진입 시 크라우드 웅성거림·리버브를 얼마나 넣을지(클럽 느낌 vs 은은하게). 조명·색도 지금처럼 확 바꿀지.</li>
      <li><span class="pill o">확인</span><b>진입 버튼 위치</b> — 컨디션(BGM) 화면 재생 카드 옆 / 메뉴바 위젯 / 둘 다.</li>
      <li><span class="pill o">확인</span><b>남용 방지</b> — 하루 라운지 총량 상한이나 "복귀 후 25분은 집중" 같은 가드가 필요한지.</li>
    </ul>
    <div class="foot">
      실제 구현 시: 브레이크 = 플랜 게이트를 일정 시간 이기는 <b>수동 오버라이드 슬롯</b>(<code>lounge</code> 풀 + 클럽 이펙트),
      복귀 = 오버라이드 해제 후 플랜 선곡으로 자연 복귀. 지금 플랜엔 <b>수 20:30~·금 19:00~ 클럽 라운지</b>가 이미 스케줄로 들어가 있고,
      이 기능은 <b>아무 때나</b> 그 분위기를 부르는 온디맨드 버전입니다.
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
"use strict";
const $ = id => document.getElementById(id);
let mode = "preset";      // preset | toggle | hybrid
let onBreak = false;
let secs = 0, tick = null, chosen = 10;

const WORK = { vibe:"집중 모드 · 오후 오피스", track:"[123] Neural Dashboard Glow", sub:"디렉터가 활동 강도에 맞춰 선곡 중 · 96 BPM", disc:"🎧" };
const LOUNGE = { vibe:"클럽 라운지 · 브레이크", track:"Velvet Pulse", sub:"따뜻한 하우스 · 웅성이는 라운지 · 리버브 ↑", disc:"🍸" };

function toast(msg){ const t=$("toast"); t.textContent=msg; t.classList.add("show"); clearTimeout(t._h); t._h=setTimeout(()=>t.classList.remove("show"),1900); }
function fmt(s){ const m=Math.floor(s/60), r=s%60; return String(m).padStart(2,"0")+":"+String(r).padStart(2,"0"); }

// mode switch
$("modes").addEventListener("click", e=>{
  const b=e.target.closest(".modebtn"); if(!b) return;
  if(onBreak) endBreak(false);
  mode=b.dataset.mode;
  [...$("modes").children].forEach(x=>x.classList.toggle("on", x===b));
  renderIdle();
});

function renderIdle(){
  // reset break controls to reflect the current mode's idle affordance
  $("presets").innerHTML="";
  if(mode==="preset" || mode==="hybrid"){
    const opts = mode==="preset" ? [5,10,15] : [10];
    // for preset we pick before entering; show chips on the trigger area via label
  }
}

function startBreak(){
  onBreak=true;
  applyVibe(true);
  $("goBreak").style.display="none";
  $("goBreak").nextElementSibling.style.display="none";
  $("brkPanel").classList.add("show");
  $("pbarWrap").style.display = (mode==="toggle") ? "none" : "block";
  $("sessDot").classList.add("brk");
  $("sessText").textContent = "라운지 브레이크 중 — 작업 세션은 계속 흐르고 소리만 쉬는 중";

  const presets=$("presets"), extend=$("extendBtn");
  presets.innerHTML=""; extend.style.display="none";

  if(mode==="toggle"){
    // no timer — count UP, return only on button
    secs=0; $("timer").textContent="00:00";
    $("brkinfo").innerHTML="무제한 · <b>복귀</b>를 누르면 회사로 돌아갑니다";
    clearInterval(tick); tick=setInterval(()=>{ secs++; $("timer").textContent=fmt(secs); },1000);
    toast("라운지 입장 — 편하게 계세요 🍸");
  } else {
    // preset & hybrid count DOWN
    const opts = mode==="preset" ? [5,10,15] : [10,20,30];
    chosen = mode==="preset" ? 10 : 10;
    opts.forEach(m=>{
      const c=document.createElement("button"); c.className="preset"+(m===chosen?" on":"");
      c.textContent=m+"분"; c.onclick=()=>{ chosen=m; secs=m*60; [...presets.children].forEach(x=>x.classList.toggle("on",x===c)); updateTimerUI(); };
      presets.appendChild(c);
    });
    secs=chosen*60; updateTimerUI();
    if(mode==="hybrid"){ extend.style.display="inline-block"; $("brkinfo").innerHTML="기본 10분 · <b>+5분 더</b>로 연장 · 언제든 즉시 복귀"; }
    else $("brkinfo").innerHTML="정해진 시간이 끝나면 <b>자동으로</b> 회사 복귀";
    clearInterval(tick); tick=setInterval(countDown,1000);
    toast("라운지 입장 — "+chosen+"분 후 자동 복귀 🍸");
  }
  animateTrack();
}

function updateTimerUI(){ $("timer").textContent=fmt(secs); $("pfill").style.width="0%"; startTotal=secs; }
let startTotal=600;
function countDown(){
  secs--; $("timer").textContent=fmt(Math.max(0,secs));
  $("pfill").style.width = (100*(startTotal-secs)/startTotal)+"%";
  if(secs<=0){ endBreak(true, true); }
}
function extend(){ secs+=300; startTotal+=300; $("timer").textContent=fmt(secs); toast("+5분 연장"); }

function endBreak(userInit, auto){
  onBreak=false; clearInterval(tick); tick=null;
  applyVibe(false);
  $("brkPanel").classList.remove("show");
  $("goBreak").style.display="inline-block";
  $("goBreak").nextElementSibling.style.display="inline";
  $("pbarWrap").style.display="none";
  $("sessDot").classList.remove("brk");
  $("sessText").textContent = "작업 세션은 계속 진행 중 — 소리만 쉬는 겁니다 (컨디션 게이지는 유지)";
  if(userInit) toast(auto ? "시간 종료 — 회사 복귀, 다시 집중 🎯" : "회사 복귀 — 다시 집중 모드로 🎯");
  animateTrack();
}

function applyVibe(lounge){
  $("stage").classList.toggle("lounge", lounge);
  const v = lounge?LOUNGE:WORK;
  $("vibe").textContent=v.vibe; $("track").textContent=v.track; $("subline").textContent=v.sub; $("disc").textContent=v.disc;
}

// gently cycle the lounge/work track name so it feels alive
let trackTimer=null;
const LOUNGE_TRACKS=["Velvet Pulse","Midnight Velvet","Golden Hour","Break Room","Velvet After Dark","Midnight on the Edge"];
const WORK_TRACKS=["[123] Neural Dashboard Glow","[129] Signal Mapping","[126] Open Tabs Atlas","[096] Neural Searchlight"];
function animateTrack(){
  clearInterval(trackTimer);
  trackTimer=setInterval(()=>{
    const pool = onBreak?LOUNGE_TRACKS:WORK_TRACKS;
    $("track").textContent = pool[Math.floor((Date.now()/9000)%pool.length)];
  }, 9000);
}

// eq bar heights randomized a touch for life (pure CSS anim already runs)
[...document.querySelectorAll(".eq i")].forEach((b,i)=>{ b.style.height=(8+i*3)+"px"; });
renderIdle(); animateTrack();
</script>
</body>
</html>
"""#
    }
}
