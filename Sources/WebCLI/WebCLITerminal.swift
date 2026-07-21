import Foundation

// The shared in-page web terminal CLIENT engine, emitted as one <script> block and included
// by every page that embeds the web CLI (the 목표 추가 CLI session view and the goal page's
// CLI overlay). One source of truth: xterm version bumps, the WebKit Korean-IME takeover,
// the /api/goal/cli/* polling protocol and the resize plumbing all live HERE — pages keep
// only thin adapters (their element ids, state label, and the start POST payload).
//
// Page contract:
//   const ctl = CMWebCLI.create({ termEl, onState });
//   ctl.connect((cols, rows) => fetch('/api/goal/cli/start', {...cols, rows...}));
//   ctl.fit();          // window resized / overlay shown
//   ctl.reset();        // clear the screen before reconnecting to a live PTY
//   ctl.disconnect();   // stop polling but leave the PTY running server-side
public enum WebCLITerminal {
    // Engine version, shown as a badge at the terminal's bottom-right ("webcli v…").
    // BUMP ON EVERY BEHAVIOR CHANGE — it exists so a live page's engine build is
    // identifiable at a glance (stale-build confusion cost hours on 2026-07-13).
    public static let engineVersion = "1.1.0"
    // Bump these to upgrade xterm — the ONLY place versions appear. NOTE: upstream renamed the
    // packages at 5.5.0 (`xterm` → `@xterm/xterm`, `xterm-addon-*` → `@xterm/addon-*`) and the
    // addon FILES with them (`xterm-addon-fit.js` → `addon-fit.js`), so a major bump touches the
    // URLs below too, not just these numbers. Globals are unchanged across the rename
    // (`FitAddon.FitAddon`, `Unicode11Addon.Unicode11Addon`) — verified against the 6.0.0 UMD.
    public static let xtermVersion = "6.0.0"
    public static let fitAddonVersion = "0.11.0"
    public static let unicode11AddonVersion = "0.9.0"
    // Hangul coding font: fills the 2-cell CJK grid slot (unlike the fallback system font,
    // which leaves visible gaps between syllables — "안 녕 하 세 요"). Verified live on jsdelivr
    // (npm package `d2coding`, HTTP 200 font/woff2, 2026-07-13): the "-subset" build (완성형
    // Hangul + jamo + latin + symbols, ~350KB) keeps load light; the CSS below ships its own
    // @font-face with the matching woff/ttf fallbacks, so we only need to <link> it.
    public static let d2CodingVersion = "1.3.2"

    // The engine <script> block. Idempotent — including it twice defines CMWebCLI once.
    public static func script() -> String {
        #"""
        <script>
        (function(){
          if(window.CMWebCLI) return;
          const XTERM_CSS='https://cdn.jsdelivr.net/npm/@xterm/xterm@\#(xtermVersion)/css/xterm.min.css';
          const XTERM_JS='https://cdn.jsdelivr.net/npm/@xterm/xterm@\#(xtermVersion)/lib/xterm.min.js';
          // The addon packages ship only .js/.mjs — the .min.js here is jsdelivr's own
          // on-the-fly minification of that .js (verified HTTP 200), not a package file.
          const FIT_JS='https://cdn.jsdelivr.net/npm/@xterm/addon-fit@\#(fitAddonVersion)/lib/addon-fit.min.js';
          const UNI_JS='https://cdn.jsdelivr.net/npm/@xterm/addon-unicode11@\#(unicode11AddonVersion)/lib/addon-unicode11.min.js';
          // Regular+bold woff2 straight from the npm package — NOT the package's own CSS.
          // (Confirmed live: d2coding-subset.css's @font-face IS family 'D2Coding', matching
          // FONT_FAMILY below — a name mismatch was ruled out. The real bug: driving font
          // load through <link rel=stylesheet> + document.fonts.load() in the same tick races
          // the browser's OWN async fetch+parse of that external stylesheet — document.fonts
          // has no 'D2Coding' FontFace registered yet when load() is called, so it resolves
          // against nothing and the web font silently never loads; canvas-rendered xterm text
          // never gets the browser's later lazy DOM-triggered font swap either, since nothing
          // in the page ever lays out real text in that family. Fix: construct the FontFace
          // objects ourselves and await their own .load() — no stylesheet-parse race.)
          const D2_REG='https://cdn.jsdelivr.net/npm/d2coding@\#(d2CodingVersion)/fonts/d2coding-subset.woff2';
          const D2_BOLD='https://cdn.jsdelivr.net/npm/d2coding@\#(d2CodingVersion)/fonts/d2coding-bold-subset.woff2';
          // Latin stays Menlo/SF Mono (first in the chain); 'D2Coding' only gets used for
          // glyphs Menlo doesn't have — i.e. Hangul — so it never affects ASCII rendering.
          const FONT_FAMILY="ui-monospace,SFMono-Regular,Menlo,monospace,'D2Coding'";
          let libs=null;
          // 폰트 로드 완주 프라미스(타임아웃과 무관). 타임아웃이 이기면 터미널은 폴백
          // 폰트 셀 폭으로 먼저 열리는데, 그 뒤 D2Coding 이 도착해도 재측정이 없으면
          // 한글 글리프가 셀 경계에서 잘린 채(오른쪽 끝 글자 바이섹트) 남는다 — 각
          // 인스턴스가 이 프라미스에 fit+refresh 를 걸어 도착 즉시 바로잡는다.
          let fontsSettled=Promise.resolve();
          function loadCSS(href){ if(document.querySelector('link[href="'+href+'"]')) return;
            const l=document.createElement('link'); l.rel='stylesheet'; l.href=href; document.head.appendChild(l); }
          function loadJS(src){ return new Promise((res,rej)=>{ const s=document.createElement('script');
            s.src=src; s.onload=res; s.onerror=()=>rej(new Error('load '+src)); document.head.appendChild(s); }); }
          // FontFace.load() + document.fonts.add() races a short timeout — a slow/blocked CDN
          // must never hold up the terminal opening; if the timeout wins, the Terminal is
          // simply created before D2Coding is registered and falls back to the system font
          // until the add() below finishes (xterm re-measures on the next resize/refresh).
          function loadHangulFont(){
            if(typeof FontFace==='undefined'||!document.fonts) return Promise.resolve();
            const mk=(url,weight)=>{ try{
                const f=new FontFace('D2Coding','url('+url+') format(\"woff2\")',{weight:weight});
                return f.load().then(loaded=>{ document.fonts.add(loaded); }).catch(()=>{});
              }catch(e){ return Promise.resolve(); } };
            const want=Promise.all([mk(D2_REG,'400'),mk(D2_BOLD,'700')]);
            fontsSettled=want;
            return Promise.race([want, new Promise(res=>setTimeout(res,1500))]);
          }
          function ensureLibs(){ if(libs) return libs; loadCSS(XTERM_CSS);
            libs=loadJS(XTERM_JS).then(()=>loadJS(FIT_JS)).then(()=>loadJS(UNI_JS))
              .then(()=>loadHangulFont()); return libs; }
          function b64e(s){ const by=new TextEncoder().encode(s); let bin='';
            for(let i=0;i<by.length;i++) bin+=String.fromCharCode(by[i]); return btoa(bin); }
          function b64d(b){ const bin=atob(b), a=new Uint8Array(bin.length);
            for(let i=0;i<bin.length;i++) a[i]=bin.charCodeAt(i); return a; }
          function postJSON(path,obj){ return fetch(path,{method:'POST',
            headers:{'Content-Type':'application/json'},body:JSON.stringify(obj)}); }

          // opts: { termEl, onState(txt,cls), ioPath?, resizePath? }
          function create(opts){
            const onState=opts.onState||function(){};
            const ioPath=opts.ioPath||'/api/goal/cli/io';
            const resizePath=opts.resizePath||'/api/goal/cli/resize';
            const st={term:null,fit:null,token:'',off:0,pending:'',busy:false,timer:null,
                      comp:false,hold:[],tap:null,flushT:null,sent:0,again:false};

            // IME(한글) 조합 중 도착한 PTY 출력은 hold 에 쥐고 있다가 조합이 끝나면 몰아서
            // 쓴다 — 조합 중 term.write 가 유발하는 재렌더도 WebKit 조합을 깨뜨리기 때문.
            function flushHold(){ const h=st.hold; st.hold=[]; for(const b of h) st.term.write(b); }
            function write(bytes){ if(st.comp) st.hold.push(bytes); else st.term.write(bytes); }
            function stopPolling(){ if(st.timer){ clearInterval(st.timer); st.timer=null; } }
            function pump(){
              if(!st.token) return;
              if(st.busy){ st.again=true; return; }   // 진행 중이면 끝난 직후 즉시 재폴링
              st.busy=true;
              const send=st.pending; st.pending='';
              postJSON(ioPath,{token:st.token,since:st.off,input:send?b64e(send):''})
                .then(r=>r.json()).then(d=>{
                  st.busy=false;
                  if(!d||!d.ok) return;
                  if(d.data) write(b64d(d.data));
                  st.off=d.offset;
                  if(d.alive) onState('실행 중','live');
                  else { onState('세션 종료됨','dead'); stopPolling(); return; }
                  // 입력을 보냈으면 에코가 곧 도착한다 — 다음 90ms 틱을 기다리지 말고
                  // ~30ms 후 한 번 더 당겨 폴링해 체감 지연을 줄인다. 대기 입력도 즉시.
                  if(st.again||send){ st.again=false; setTimeout(pump, send?30:0); }
                }).catch(()=>{ st.busy=false; st.pending=send+st.pending; });
            }
            function doFit(initial){
              if(!st.fit||!st.term) return;
              try{ st.fit.fit(); }catch(e){}
              if(initial) return;
              if(st.token) postJSON(resizePath,{token:st.token,cols:st.term.cols,rows:st.term.rows});
            }
            // Diagnostic tap, gated behind ?imedebug=1: every IME/onData event is ring-buffered
            // to window.__imeLog and mirrored to POST /api/debug/ime-log (server: IMEDebugLog).
            function setupTap(){
              if(new URLSearchParams(location.search).get('imedebug')!=='1') return;
              window.__imeLog=window.__imeLog||[];
              let q=[];
              setInterval(()=>{ if(!q.length) return; const b=q; q=[];
                postJSON('/api/debug/ime-log',{events:b}).catch(()=>{}); },200);
              st.tap=(type,ev)=>{
                const ta=st.term&&st.term.textarea;
                const rec={t:performance.now(),type:type,
                  key:(ev&&ev.key)||'', keyCode:(ev&&ev.keyCode)||0,
                  isComposing:!!(ev&&ev.isComposing), data:(ev&&ev.data)||'',
                  inputType:(ev&&ev.inputType)||'',
                  value:(ta&&ta.value)||'',
                  selStart:(ta&&ta.selectionStart!=null)?ta.selectionStart:-1,
                  selEnd:(ta&&ta.selectionEnd!=null)?ta.selectionEnd:-1};
                window.__imeLog.push(rec);
                if(window.__imeLog.length>2000) window.__imeLog.shift();
                q.push(rec);
              };
            }
            // WebKit(WKWebView) 한글 IME 전면 인수. xterm 의 CompositionHelper 는
            // compositionupdate 마다(+ 조합 중 0ms 타이머로 계속) 숨은 textarea 의
            // left/top/width/height 를 커서 위치로 다시 쓴다(updateCompositionElements —
            // xterm 5.3.0 CompositionHelper.ts 확인). WebKit 은 IME 조합 도중 포커스된
            // textarea 의 geometry 가 바뀌면 조합을 조기 커밋/리셋한다 — 이게 "안녕하세요"
            // → "ㅇㄴㅎ세요" 로 자모가 뜯기는 실제 트리거다(xterm.js #1939, #5894).
            // textarea 자신에게 리스너를 달아도 xterm 의 리스너가 먼저 등록돼 있어(동일
            // 타겟은 등록 순서가 이기고 capture 플래그로도 못 바꾼다) 소용없다. 그래서 한
            // 단계 위(document)의 CAPTURE 단계에서 가로챈다 — 타겟에 도달하기 전에 조상에서
            // 먼저 실행되므로 stopPropagation 하면 xterm 의 CompositionHelper 는 이벤트를
            // 아예 보지 못하고 textarea 를 건드리지 못한다. 조합은 엔진이 전부 떠맡는다:
            // compositionend 의 최종 완성 텍스트만 pending→pump 경로로 흘려보낸다.
            // 트레이드오프: 터미널 안 조합 중 미리보기는 없다(TUI 가 커밋 텍스트를 에코).
            // 조합 관련 키인지 — isComposing/229 에 더해, WebKit 이 조합 시작 "첫" 키에서
            // 둘 다 안 세워주는 경우가 있어 한글 문자키 자체도 조합 키로 취급한다. 이 키가
            // xterm 의 raw 키 경로(keydown/keypress→onData)로 새면 초성 자모("ㅇㄴㅎ…")가
            // PTY 로 직접 들어가 조합 결과와 겹친다.
            function isImeKey(ev){
              if(ev.isComposing||ev.keyCode===229||st.comp) return true;
              return !!(ev.key&&ev.key.length===1&&/[ㄱ-ㆎ가-힣]/.test(ev.key));
            }
            function setupIME(){
              const ta=st.term.textarea; if(!ta) return;
              // 조합 이벤트가 아예 안 오는 IME 경로(2026-07-13 실트레이스로 확정): WebKit 은
              // 상태에 따라 composition* 대신 beforeinput(insertReplacementText) →
              // input(insertText) 만으로 자모를 textarea 에 직접 쌓는다. xterm 의 textarea
              // 'input' 리스너(_inputEvent)가 그 insertText 를 keydown(229)보다 먼저 PTY 로
              // 흘려보내는 것이 자모 유출("ㅇㄴㅎ세요")의 실경로였다. 그래서 input/beforeinput
              // 도 캡처 차단하고, 이 경로의 커밋은 엔진이 맡는다: 입력이 잠잠해지면(250ms)
              // 또는 일반 키(Enter 등)가 경계를 만들면 textarea 값을 통째로 PTY 로 보낸다.
              function flushValue(){
                if(st.flushT){ clearTimeout(st.flushT); st.flushT=null; }
                if(st.comp) return;                 // 조합 경로는 compositionend 가 커밋
                const rest=ta.value.slice(st.sent);
                ta.value=''; st.sent=0;
                if(rest){ st.pending+=rest; pump(); }
              }
              function scheduleFlush(){
                if(st.flushT) clearTimeout(st.flushT);
                st.flushT=setTimeout(()=>{ st.flushT=null; flushValue(); },250);
              }
              const guard=(type,ev)=>{
                if(ev.target!==ta) return;
                if(st.tap) st.tap(type,ev);
                if(type==='compositionstart'){ st.comp=true; ev.stopPropagation(); return; }
                if(type==='compositionupdate'){ ev.stopPropagation(); return; }
                if(type==='compositionend'){
                  ev.stopPropagation();
                  st.comp=false;
                  if(st.flushT){ clearTimeout(st.flushT); st.flushT=null; }
                  const text=ev.data||'';
                  if(text){ st.pending+=text; pump(); }
                  ta.value=''; st.sent=0;
                  flushHold();
                  return;
                }
                if(type==='beforeinput'||type==='input'){
                  // xterm 의 _inputEvent 가 이 이벤트로 텍스트를 PTY 에 이중 전송하지 못하게
                  // 항상 차단. 값 자체는 IME 가 계속 다듬어야 하므로 preventDefault 하지 않고,
                  // 조합 이벤트 없는 경로만 우리가 커밋한다. (일반 영문 키는 xterm 이
                  // keypress 에서 preventDefault 하므로 textarea 값에 아예 안 쌓인다 — 이
                  // 경로로 값이 남는 것은 IME·받아쓰기·텍스트 대치뿐.)
                  ev.stopPropagation();
                  if(!st.comp){
                    if(type==='input'){
                      const v=ta.value;
                      if(v.length<st.sent){
                        // IME 편집(백스페이스)이 이미 커밋한 글자까지 지웠다 — PTY 쪽도
                        // 그만큼 백스페이스로 따라잡는다.
                        let n=st.sent-v.length; st.sent=v.length;
                        let bs=''; while(n-->0) bs+='\x7f';
                        st.pending+=bs; pump();
                      } else if(v.length-st.sent>2){
                        // 안정 접두사 즉시 커밋: 한글 조합은 꼬리 최대 2글자(받침 이동
                        // 포함)만 바뀔 수 있다 — 그 앞부분은 즉시 PTY 로 보내 "손 뗄
                        // 때까지 침묵"을 없앤다. 디바운스는 꼬리 2글자에만 남는다.
                        const cut=v.length-2;
                        st.pending+=v.slice(st.sent,cut); st.sent=cut; pump();
                      }
                    }
                    scheduleFlush();
                  }
                  return;
                }
                if(type==='keydown'||type==='keypress'){
                  if(isImeKey(ev)){ ev.stopPropagation(); return; }
                  // 무조합 경로에서 백스페이스는 IME 의 음절 편집(deleteContentBackward)에
                  // 맡긴다 — xterm 의 \x7f 전송이 겹치면 한 키에 두 글자가 지워진다.
                  if(type==='keydown'&&ev.key==='Backspace'&&ta.value){ ev.stopPropagation(); scheduleFlush(); return; }
                  // 일반 키(Enter·space·방향키…): 쌓인 IME 값을 먼저 커밋해 순서를 지킨다.
                  if(ta.value&&!st.comp) flushValue();
                }
              };
              ['compositionstart','compositionupdate','compositionend','keydown','keypress','beforeinput','input'].forEach(t=>{
                document.addEventListener(t,ev=>guard(t,ev),true);
              });
              ta.addEventListener('blur',()=>{ st.comp=false; flushValue(); flushHold(); });
              // 이중 방어: 캡처 가드를 어떤 경로로든 비껴간 조합 키가 있어도 xterm 이 raw
              // 키로 처리하지 않게 한다 — 텍스트는 compositionend/값 커밋으로만 들어온다.
              st.term.attachCustomKeyEventHandler(ev=>!isImeKey(ev));
            }
            function ensureTerm(){
              if(st.term) return;
              st.term=new Terminal({fontSize:13,
                fontFamily:FONT_FAMILY,
                theme:{background:'#0c0f15'},cursorBlink:true,scrollback:5000,
                allowProposedApi:true});
              st.fit=new FitAddon.FitAddon(); st.term.loadAddon(st.fit);
              // CJK 2-cell 정렬 — 없으면 한국어 리드로우에서 커서/입력줄이 어긋난다.
              try{ const uni=new Unicode11Addon.Unicode11Addon(); st.term.loadAddon(uni);
                st.term.unicode.activeVersion='11'; }catch(e){}
              st.term.open(opts.termEl);
              // 우하단 엔진 버전 배지 — 지금 화면의 엔진 빌드를 한눈에 식별한다
              // (2026-07-13 스테일 빌드 혼선의 재발 방지). 버전은 WebCLITerminal.engineVersion.
              try{
                const host=opts.termEl;
                if(getComputedStyle(host).position==='static') host.style.position='relative';
                const badge=document.createElement('span');
                badge.textContent='webcli v\#(engineVersion)';
                badge.style.cssText='position:absolute;right:10px;bottom:6px;z-index:5;'
                  +'font:10px ui-monospace,SFMono-Regular,Menlo,monospace;'
                  +'color:rgba(138,147,163,.45);pointer-events:none;user-select:none';
                host.appendChild(badge);
              }catch(e){}
              setupTap();
              // 최종 안전망(3중 방어, wk-hangul-ime 패턴): IME 가 textarea 에 값을 쌓는 중
              // (조합 중이거나 값이 남아있는 동안) 어떤 경로로든 xterm 키 핸들러가 한글을
              // onData 로 흘리면 버린다 — 그 텍스트는 조합/값 커밋 경로로만 들어와야 한다.
              st.term.onData(d=>{
                if((st.comp||(st.term.textarea&&st.term.textarea.value))
                   &&d&&/^[ㄱ-ㆎ가-힣]+$/.test(d)){ if(st.tap) st.tap('onDataDropped',{data:d}); return; }
                st.pending+=d; if(st.tap) st.tap('onData',{data:d}); pump();
              });
              setupIME();
              // 한글 폰트가 터미널 생성 뒤에 도착한 경우(1.5s 타임아웃 패배): 셀 폭을
              // 재측정하고 전체 리페인트 — 없으면 리사이즈 전까지 글리프 잘림이 남는다.
              fontsSettled.then(()=>{ if(!st.term) return;
                try{ doFit(false); st.term.refresh(0,st.term.rows-1); }catch(e){} });
            }
            return {
              // start(cols, rows) must return a fetch Promise for the page's cli/start POST.
              connect(start){
                onState('연결 중…','');
                return ensureLibs().then(()=>{
                  ensureTerm(); doFit(true); st.term.focus();
                  return start(st.term.cols,st.term.rows);
                }).then(r=>r.json()).then(d=>{
                  if(!d||!d.ok){ onState('시작 실패: '+((d&&d.error)||'?'),'dead'); return false; }
                  st.token=d.token; st.off=0; onState('실행 중','live');
                  stopPolling(); st.timer=setInterval(pump,90); pump();
                  return true;
                }).catch(()=>{ onState('xterm 로드 실패 — 네트워크를 확인하세요','dead'); return false; });
              },
              reset(){ if(st.term) st.term.reset(); },
              fit(){ doFit(false); },
              focus(){ if(st.term) st.term.focus(); },
              disconnect(){ stopPolling(); st.token=''; }
            };
          }
          window.CMWebCLI={create:create};
        })();
        </script>
        """#
    }
}
