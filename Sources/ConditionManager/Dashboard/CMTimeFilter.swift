import Foundation

// Shared time-range filter, served as a self-contained JS module injected into any
// dashboard page that needs a 기간 filter (currently the 히스토리 뷰 and the 컨디션맵).
// One source of truth for the preset date math (오늘/어제/1주일/30일/90일 등), the custom
// date-range picker, an optional 자동 mode, and the timezone label — so every page's filter
// behaves identically. The module injects its own CSS once, so it is drop-in on any page
// that defines the usual --line/--txt/--dim/--accent CSS variables.
//
// Public API (window.CMTimeFilter):
//   dayStr(Date|ms) -> 'YYYY-MM-DD'       parseDay(str) -> Date (표시 tz 자정)
//   daysBetween(a,b) -> Int               tzLabel() -> 'KST (UTC+9)' 등
//   parts(Date|ms) -> {y,mo,d,h,mi,s,wd}  epoch을 표시 타임존 벽시계로 분해
//   fromParts(y,mo,d,h,mi,s) -> ms        표시 tz 벽시계 → epoch (datetime-local 역변환)
//   inputToEpoch(v) -> sec                'YYYY-MM-DDTHH:mm' → epoch초 (빈 값=0)
//   epochToInput(sec) -> str              epoch초 → datetime-local 값 (0/없음='')
//   hhmm(sec) / hourOf(sec) / weekdayKo(Date|ms)
//   presetRange(key) -> {start,end,preset}
//   mount(host, opts) -> controller       opts: {presets:[keys], auto:Bool, custom:Bool,
//                                                 initial:key, onChange:({mode,preset,start,end})=>…}
// The controller: get() current state, pick(key), setRange(start,end).
//
// 표시 타임존: 서버가 각 페이지에 주입하는 window.CM_TZ(IANA id, null=시스템)를 따른다.
// 저장·전송은 항상 epoch(UTC 기준)이고, 이 모듈이 "어느 벽시계로 보여줄지"만 바꾼다.
// `window.CMTimeFilter ||` 가드로 중복 임베드(레일+페이지 본문)에 안전하다.
enum CMTimeFilter {
    static let js = #"""
window.CMTimeFilter = window.CMTimeFilter || (function(){
  const DAYMS = 86400000;
  function pad(n){ return (n<10?'0':'')+n; }
  // 표시 타임존 id. 서버 주입 전역(CM_TZ)을 호출 시점마다 읽는다 — 주입 순서에 안전.
  function tzId(){ return window.CM_TZ || null; }
  let _fmtTz, _fmt=null;
  function fmt(){ const z=tzId();
    if(!_fmt || _fmtTz!==z){ _fmtTz=z;
      _fmt=new Intl.DateTimeFormat('en-US',{timeZone:z||undefined,hour12:false,
        year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',
        minute:'2-digit',second:'2-digit',weekday:'short'}); }
    return _fmt; }
  const WDN={Sun:0,Mon:1,Tue:2,Wed:3,Thu:4,Fri:5,Sat:6};
  // epoch(Date 또는 ms) → 표시 타임존의 벽시계 부품. tz 미설정이면 브라우저 로컬 그대로.
  function parts(x){ const d=(x instanceof Date)?x:new Date(x);
    if(!tzId()) return {y:d.getFullYear(),mo:d.getMonth()+1,d:d.getDate(),
      h:d.getHours(),mi:d.getMinutes(),s:d.getSeconds(),wd:d.getDay()};
    const p={}; fmt().formatToParts(d).forEach(function(q){ p[q.type]=q.value; });
    return {y:+p.year,mo:+p.month,d:+p.day,h:(+p.hour)%24,mi:+p.minute,s:+p.second,
      wd:(WDN[p.weekday]!==undefined?WDN[p.weekday]:0)};
  }
  // 표시 tz의 UTC 오프셋(ms, 동쪽 양수). 시간 히스토그램 같은 루프에서 싸도록 시간 버킷 메모.
  let _offTz, _off={};
  function offsetMs(ms){ const z=tzId();
    if(_offTz!==z){ _offTz=z; _off={}; }
    const k=Math.floor(ms/3600000);
    if(_off[k]!==undefined) return _off[k];
    const sec=ms-(ms%1000), p=parts(sec);
    const v=Date.UTC(p.y,p.mo-1,p.d,p.h,p.mi,p.s)-sec;
    _off[k]=v; return v; }
  // 표시 tz 벽시계 부품 → epoch ms. DST 경계까지 2회 보정으로 수렴.
  function fromParts(y,mo,d,h,mi,s){ h=h||0; mi=mi||0; s=s||0;
    if(!tzId()) return new Date(y,mo-1,d,h,mi,s).getTime();
    const w=Date.UTC(y,mo-1,d,h,mi,s);
    let t=w-offsetMs(w); t=w-offsetMs(t); return t; }
  // datetime-local 값('YYYY-MM-DDTHH:mm[:ss]') → epoch초. 빈/이상값은 0.
  function inputToEpoch(v){ if(!v) return 0;
    const m=/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/.exec(v);
    if(!m){ const t=new Date(v).getTime(); return isNaN(t)?0:Math.floor(t/1000); }
    return Math.floor(fromParts(+m[1],+m[2],+m[3],+m[4],+m[5],+(m[6]||0))/1000); }
  // epoch초 → datetime-local 값(표시 tz 벽시계). 0/없음 → ''.
  function epochToInput(sec){ if(!sec) return '';
    const p=parts(sec*1000);
    return p.y+'-'+pad(p.mo)+'-'+pad(p.d)+'T'+pad(p.h)+':'+pad(p.mi); }
  function hhmm(sec){ const p=parts(sec*1000); return pad(p.h)+':'+pad(p.mi); }
  // epoch초의 표시 tz 시(0–23). parts 대신 오프셋 메모를 타서 분 단위 루프에도 싸다.
  function hourOf(sec){ const ms=sec*1000, w=ms+offsetMs(ms);
    return Math.floor((((w%DAYMS)+DAYMS)%DAYMS)/3600000); }
  function weekdayKo(x){ return ['일','월','화','수','목','금','토'][parts(x).wd]; }
  function dayStr(d){ const p=parts(d); return p.y+'-'+pad(p.mo)+'-'+pad(p.d); }
  function parseDay(s){ const a=s.split('-'); return new Date(fromParts(+a[0],+a[1],+a[2])); }
  function daysBetween(a,b){ return Math.round((parseDay(b)-parseDay(a))/DAYMS); }
  // 표시 타임존 라벨. Asia/Seoul이면 KST, 그 외 설정값은 IANA id, 미설정이면 브라우저 로컬.
  function tzLabel(){
    const z=tzId(); const off=offsetMs(Date.now())/3600000;
    let nm;
    if(z){ nm=(z==='Asia/Seoul')?'KST':z; }
    else { let r=''; try{ r=Intl.DateTimeFormat().resolvedOptions().timeZone; }catch(e){}
      nm=(r==='Asia/Seoul')?'KST':(r||'현지'); }
    return nm+' (UTC'+(off>=0?'+':'')+(Number.isInteger(off)?off:off.toFixed(1))+')';
  }
  function today0(){ return parseDay(dayStr(new Date())); }
  // 날짜 문자열 산술 — 자정 대신 정오 기준으로 더해 DST 경계에도 하루가 안 밀린다.
  function addDays(ds,n){ return dayStr(new Date(parseDay(ds).getTime()+n*DAYMS+DAYMS/2)); }
  function addMonths(ds,n){ const a=ds.split('-').map(Number); const nm=a[1]-1+n;
    const y=a[0]+Math.floor(nm/12), m=((nm%12)+12)%12;
    const last=new Date(Date.UTC(y,m+1,0)).getUTCDate();
    return y+'-'+pad(m+1)+'-'+pad(Math.min(a[2],last)); }
  // 프리셋 → {start,end}(YYYY-MM-DD, 표시 tz 기준 "오늘"). 일 단위는 오늘 포함이라
  // (n-1)일 빼고, 월 단위는 같은 날짜 기준.
  function presetRange(key){
    const t=dayStr(new Date()); let s=t, e=t;
    if(key==='yesterday'){ s=addDays(t,-1); e=s; }
    else if(key==='7d')  { s=addDays(t,-6); }
    else if(key==='1m')  { s=addMonths(t,-1); }
    else if(key==='30d') { s=addDays(t,-29); }
    else if(key==='90d') { s=addDays(t,-89); }
    else if(key==='3m')  { s=addMonths(t,-3); }
    // 'today' 및 미지정: 오늘 하루
    return { start:s, end:e, preset:key };
  }
  const LABELS = { auto:'자동', today:'오늘', yesterday:'어제', '7d':'1주일', '1m':'한달', '30d':'30일', '90d':'90일', '3m':'3달', custom:'커스텀' };
  const TIPS   = { auto:'업무 시작을 자동 감지해 오늘 하루', today:'오늘 하루', yesterday:'어제 하루', '7d':'최근 7일', '1m':'최근 한 달', '30d':'최근 30일', '90d':'최근 90일', '3m':'최근 3달' };

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

  return { dayStr, parseDay, daysBetween, tzLabel, presetRange, mount, LABELS,
           parts, fromParts, inputToEpoch, epochToInput, hhmm, hourOf, weekdayKo };
})();
"""#

    // window.CM_TZ 전역 할당 — 표시 타임존 설정(Settings.timeZoneID)을 페이지 서빙 시점에
    // 주입한다. "system"이면 null(브라우저 로컬). POST /api/settings/timezone 검증을 거친
    // IANA id만 저장되지만, 방어적으로 따옴표는 벗겨 JS 리터럴이 깨질 수 없게 한다.
    static func tzAssignJS() -> String {
        let id = Settings.shared.timeZoneID
        let lit = (id == "system") ? "null"
            : "'\(id.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: ""))'"
        return "window.CM_TZ=\(lit);"
    }

    // 자기완결 부트스트랩(<script> 포함): CM_TZ 할당 + 모듈 본체. SessionRail이 임베드하므로
    // 레일이 있는 모든 페이지(대시보드·장비·goal 등)가 자동으로 받는다. 레일이 없는 페이지는
    // tzAssignJS()+js를 직접 인라인한다. 모듈의 `||` 가드 덕에 중복 임베드는 무해하다.
    static func bootHTML() -> String {
        "<script>\(tzAssignJS())\n\(js)</script>"
    }
}
