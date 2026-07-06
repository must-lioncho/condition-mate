import Foundation

// Shared time-range filter, served as a self-contained JS module injected into any
// dashboard page that needs a 기간 filter (currently the 히스토리 뷰 and the 컨디션맵).
// One source of truth for the preset date math (오늘/어제/1주일/한달/30일/3달), the custom
// date-range picker, an optional 자동 mode, and the timezone label — so every page's filter
// behaves identically. The module injects its own CSS once, so it is drop-in on any page
// that defines the usual --line/--txt/--dim/--accent CSS variables.
//
// Public API (window.CMTimeFilter):
//   dayStr(Date) -> 'YYYY-MM-DD'          parseDay(str) -> Date (local midnight)
//   daysBetween(a,b) -> Int               tzLabel() -> 'KST (UTC+9)' 등
//   presetRange(key) -> {start,end,preset}
//   mount(host, opts) -> controller       opts: {presets:[keys], auto:Bool, custom:Bool,
//                                                 initial:key, onChange:({mode,preset,start,end})=>…}
// The controller: get() current state, pick(key), setRange(start,end).
enum CMTimeFilter {
    static let js = #"""
window.CMTimeFilter = (function(){
  const DAYMS = 86400000;
  function pad(n){ return (n<10?'0':'')+n; }
  function dayStr(d){ return d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate()); }
  function parseDay(s){ return new Date(s+'T00:00:00'); }
  function daysBetween(a,b){ return Math.round((parseDay(b)-parseDay(a))/DAYMS); }
  // 로컬 타임존 라벨. Asia/Seoul이면 KST, 아니면 지역 이름 + UTC 오프셋.
  function tzLabel(){
    const off=-new Date().getTimezoneOffset()/60;
    let z=''; try{ z=Intl.DateTimeFormat().resolvedOptions().timeZone; }catch(e){}
    const nm=(z==='Asia/Seoul')?'KST':(z||'현지');
    return nm+' (UTC'+(off>=0?'+':'')+(Number.isInteger(off)?off:off.toFixed(1))+')';
  }
  function today0(){ const n=new Date(); return new Date(n.getFullYear(),n.getMonth(),n.getDate()); }
  // 프리셋 → {start,end}(YYYY-MM-DD). 일 단위는 오늘 포함이라 (n-1)일 빼고, 월 단위는 같은 날짜 기준.
  function presetRange(key){
    const t=today0(); let s=new Date(t), e=new Date(t);
    if(key==='yesterday'){ s.setDate(s.getDate()-1); e=new Date(s); }
    else if(key==='7d')  { s.setDate(s.getDate()-6); }
    else if(key==='1m')  { s.setMonth(s.getMonth()-1); }
    else if(key==='30d') { s.setDate(s.getDate()-29); }
    else if(key==='3m')  { s.setMonth(s.getMonth()-3); }
    // 'today' 및 미지정: 오늘 하루
    return { start:dayStr(s), end:dayStr(e), preset:key };
  }
  const LABELS = { auto:'자동', today:'오늘', yesterday:'어제', '7d':'1주일', '1m':'한달', '30d':'30일', '3m':'3달', custom:'커스텀' };
  const TIPS   = { auto:'업무 시작을 자동 감지해 오늘 하루', today:'오늘 하루', yesterday:'어제 하루', '7d':'최근 7일', '1m':'최근 한 달', '30d':'최근 30일', '3m':'최근 3달' };

  // 자체 CSS 1회 주입 — 어떤 페이지에 붙어도 동일하게 보인다.
  function ensureCSS(){
    if(document.getElementById('cmf-css')) return;
    const st=document.createElement('style'); st.id='cmf-css';
    st.textContent=
      '.cmf-row{display:flex;gap:6px;align-items:center;flex-wrap:wrap}'+
      '.cmf-btn{border:1px solid var(--line);background:transparent;color:var(--dim);font:inherit;font-size:12px;font-weight:600;padding:6px 12px;border-radius:9px;cursor:pointer;transition:.12s}'+
      '.cmf-btn:hover{color:var(--txt)}'+
      '.cmf-btn.on{background:linear-gradient(145deg,var(--accent),#5a3ff0);border-color:transparent;color:#fff}'+
      '.cmf-date{border:1px solid var(--line);background:transparent;color:var(--txt);font:inherit;font-size:12px;padding:5px 8px;border-radius:9px;color-scheme:dark}'+
      '.cmf-tilde{color:var(--dim);font-size:12px}';
    document.head.appendChild(st);
  }

  // host 요소 안에 버튼 + (옵션)날짜 입력을 렌더하고 상태를 관리한다.
  function mount(host, opts){
    opts=opts||{}; ensureCSS();
    const presets = opts.presets || ['today','yesterday','7d','1m','30d'];
    const useAuto = !!opts.auto, useCustom = opts.custom!==false;
    const state = { mode:'preset', preset:(opts.initial||(useAuto?'auto':presets[0])), start:'', end:'' };
    host.classList.add('cmf-row'); host.innerHTML='';
    const btns={};
    function mkBtn(key,label,tip){ const b=document.createElement('button'); b.className='cmf-btn'; b.textContent=label; if(tip)b.title=tip; b.onclick=()=>pick(key); host.appendChild(b); btns[key]=b; }
    if(useAuto) mkBtn('auto', LABELS.auto, TIPS.auto);
    presets.forEach(k=>mkBtn(k, LABELS[k]||k, TIPS[k]||''));
    let fromEl=null, toEl=null;
    if(useCustom){
      fromEl=document.createElement('input'); fromEl.type='date'; fromEl.className='cmf-date'; fromEl.title='시작 날짜';
      const tilde=document.createElement('span'); tilde.className='cmf-tilde'; tilde.textContent='~';
      toEl=document.createElement('input'); toEl.type='date'; toEl.className='cmf-date'; toEl.title='끝 날짜';
      host.appendChild(fromEl); host.appendChild(tilde); host.appendChild(toEl);
      fromEl.onchange=onDate; toEl.onchange=onDate;
    }
    function reflect(){
      Object.keys(btns).forEach(k=>{
        const active = (state.mode==='auto') ? (k==='auto') : (state.mode==='preset' && k===state.preset);
        btns[k].classList.toggle('on', active);
      });
      if(fromEl) fromEl.value=state.start; if(toEl) toEl.value=state.end;
    }
    function fire(){ reflect(); if(opts.onChange) opts.onChange({mode:state.mode, preset:state.preset, start:state.start, end:state.end}); }
    function pick(key){
      if(key==='auto'){ const t=dayStr(today0()); state.mode='auto'; state.preset='auto'; state.start=t; state.end=t; fire(); return; }
      const r=presetRange(key); state.mode='preset'; state.preset=key; state.start=r.start; state.end=r.end; fire();
    }
    function onDate(){
      let a=(fromEl&&fromEl.value)||'', b=(toEl&&toEl.value)||'';
      if(!a&&!b) return; if(!a)a=b; if(!b)b=a; if(a>b){ const t=a;a=b;b=t; }
      state.mode='custom'; state.preset='custom'; state.start=a; state.end=b; fire();
    }
    pick(state.preset);   // 초기 1회 onChange 발화
    return { get:()=>({...state}), pick, setRange:(s,e)=>{ state.mode='custom'; state.preset='custom'; state.start=s; state.end=e; fire(); }, presetRange };
  }

  return { dayStr, parseDay, daysBetween, tzLabel, presetRange, mount, LABELS };
})();
"""#
}
