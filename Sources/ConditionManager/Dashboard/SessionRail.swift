import Foundation

// Shared left rail injected into BOTH the dashboard (`/`) and every goal page
// (`/goal?n=NN`). It mirrors the Claude-Code-desktop shell: a persistent sidebar
// with a "새 대화" pop-out, a 대시보드 link, and a live list of background CLI
// sessions. Because the in-page CLI's PTY now survives navigation (server-side),
// this rail is what makes a backgrounded session reachable again — clicking a
// session navigates to its goal page with ?cli=1, which auto-reconnects and
// replays the terminal buffer.
//
// One self-contained block (markup + CSS + JS), returned as a raw string so it can
// be interpolated into the dashboard's raw string (`\#(...)`) and the goal page's
// normal string (`\(...)`) alike. The JS branches on whether the page-local goal-add
// functions exist (dashboard) or not (goal page → navigate to `/?compose=...`).
enum SessionRail {
    static func html() -> String {
        return #"""
        <style>
          :root{ --cmrail-w:240px }
          body{ padding-left:var(--cmrail-w) }
          body.cmrail-collapsed{ padding-left:0 }
          .cmrail{ position:fixed; top:0; left:0; bottom:0; width:var(--cmrail-w); z-index:40;
            background:#0d1017; border-right:1px solid #1c2230; display:flex; flex-direction:column;
            font:13px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif; color:#c8cfdb }
          body.cmrail-collapsed .cmrail{ transform:translateX(-100%) }
          .cmrail-brand{ display:flex; align-items:center; gap:8px; padding:14px 14px 10px; font-weight:700; color:#e7ecf4 }
          .cmrail-brand .logo{ width:18px; height:18px; border-radius:5px; background:linear-gradient(135deg,#5b8cff,#36c08a) }
          .cmrail-newwrap{ position:relative; padding:4px 12px 10px }
          .cmrail-new{ width:100%; text-align:left; background:#161c2a; border:1px solid #263149; color:#e7ecf4;
            border-radius:9px; padding:9px 12px; font-size:13px; font-weight:600; cursor:pointer }
          .cmrail-new:hover{ background:#1b2233 }
          .cmrail-menu{ position:absolute; left:12px; right:12px; top:46px; z-index:5; background:#171d2b;
            border:1px solid #2a3450; border-radius:10px; padding:5px; box-shadow:0 14px 34px rgba(0,0,0,.55) }
          .cmrail-menu button{ display:flex; width:100%; align-items:center; gap:8px; text-align:left;
            background:none; border:0; color:#d4dbe7; padding:9px 10px; border-radius:7px; font-size:13px; cursor:pointer }
          .cmrail-menu button:hover{ background:#222c42 }
          .cmrail-menu .tag{ margin-left:auto; font-size:11px; color:#7fa8ff; background:#1b2742; border:1px solid #2c3e63;
            border-radius:999px; padding:1px 7px; font-weight:600 }
          .cmrail-nav{ padding:2px 8px 8px }
          .cmrail-item{ display:flex; align-items:center; gap:9px; padding:8px 10px; border-radius:8px; color:#c8cfdb;
            text-decoration:none; font-size:13px; cursor:pointer }
          .cmrail-item:hover{ background:#161c2a }
          .cmrail-item.on{ background:#1a2438; color:#e7ecf4 }
          .cmrail-seclabel{ padding:10px 16px 6px; font-size:11px; letter-spacing:.04em; color:#5d6678; text-transform:uppercase }
          .cmrail-sessions{ flex:1; overflow-y:auto; padding:0 8px 14px }
          .cmrail-empty{ display:block; padding:8px 10px; color:#5d6678; font-size:12px }
          .cmrail-sess{ display:flex; align-items:center; gap:8px; padding:8px 10px; border-radius:8px; cursor:pointer }
          .cmrail-sess:hover{ background:#161c2a }
          .cmrail-sess.on{ background:#1a2438 }
          .cmrail-sess .dot{ width:9px; height:9px; border-radius:50%; flex:none; background:#8b93a7; box-sizing:border-box }
          .cmrail-sess .dot.pulse{ animation:cmpulse 1.4s ease-in-out infinite }      /* 진행 중 (gray blink) */
          .cmrail-sess .dot.hollow{ background:transparent; border:1.5px solid #8b93a7 }/* 완료 (empty ring) */
          @keyframes cmpulse{ 0%,100%{ opacity:1 } 50%{ opacity:.3 } }
          .cmrail-sess .meta{ min-width:0; flex:1 }
          .cmrail-sess .ttl{ color:#dbe2ee; font-size:13px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmrail-sess .sub{ color:#6b7589; font-size:11px }
          .cmrail-sess .kill{ flex:none; visibility:hidden; background:none; border:0; color:#7a8499; cursor:pointer; font-size:13px; padding:2px 4px; border-radius:5px }
          .cmrail-sess:hover .kill{ visibility:visible }
          .cmrail-sess .kill:hover{ background:#2a2230; color:#e2667d }
          .cmrail-toggle{ position:fixed; top:12px; left:12px; z-index:41; width:30px; height:30px; border-radius:8px;
            background:#161c2a; border:1px solid #263149; color:#c8cfdb; cursor:pointer; display:none }
          body.cmrail-collapsed .cmrail-toggle{ display:block }
        </style>
        <button class="cmrail-toggle" onclick="cmRailToggle()" title="세션 레일 열기">☰</button>
        <aside class="cmrail" id="cmRail">
          <div class="cmrail-brand"><span class="logo"></span><span>ConditionMate</span>
            <button class="cmrail-item" style="margin-left:auto;padding:4px 8px" onclick="cmRailToggle()" title="접기">‹</button></div>
          <div class="cmrail-newwrap">
            <button class="cmrail-new" onclick="cmRailNew(event)">＋ 새 대화</button>
            <div class="cmrail-menu" id="cmRailMenu" style="display:none">
              <button onclick="cmComposeAi()">목표 만들기<span class="tag">AI추가</span></button>
              <button onclick="cmComposePlain()">일반추가</button>
            </div>
          </div>
          <nav class="cmrail-nav">
            <a class="cmrail-item" id="cmRailDash" href="/">▦ 대시보드</a>
          </nav>
          <div class="cmrail-seclabel">세션</div>
          <div class="cmrail-sessions" id="cmRailSessions"><span class="cmrail-empty">불러오는 중…</span></div>
        </aside>
        <script>
        (function(){
          // Which goal page we are on, if any (so the rail can highlight the active session).
          var CMRAIL_SEQ = (function(){ try{ var m=/[?&]n=(\d+)/.exec(location.search); return m?parseInt(m[1],10):null; }catch(e){ return null; } })();
          function esc(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }

          // Collapse toggle (persisted) — frees the 240px when the user wants full width.
          window.cmRailToggle=function(){
            var on=document.body.classList.toggle('cmrail-collapsed');
            try{ localStorage.setItem('cmRailCollapsed', on?'1':''); }catch(e){}
          };
          try{ if(localStorage.getItem('cmRailCollapsed')==='1') document.body.classList.add('cmrail-collapsed'); }catch(e){}

          // "새 대화" pop-out menu.
          window.cmRailNew=function(ev){ if(ev) ev.stopPropagation(); var m=document.getElementById('cmRailMenu'); if(m) m.style.display=(m.style.display==='none'?'block':'none'); };
          function closeMenu(){ var m=document.getElementById('cmRailMenu'); if(m) m.style.display='none'; }
          document.addEventListener('click',function(e){ var m=document.getElementById('cmRailMenu'); if(m&&m.style.display!=='none'&&!m.parentElement.contains(e.target)) closeMenu(); });

          // 목표 만들기 (AI추가): on the dashboard, open the existing reusable goal-add modal
          // (which hosts the AI추가 button); elsewhere, navigate to the dashboard and open it.
          window.cmComposeAi=function(){ closeMenu();
            if(typeof openGoalAdd==='function'){ openGoalAdd({sprint:0,label:'Backlog'}); }
            else { location.href='/?compose=ai'; }
          };
          // 일반추가: on the dashboard, focus the always-visible quick-add input (Enter = 바로 추가);
          // elsewhere, navigate to the dashboard with the plain-compose hint.
          window.cmComposePlain=function(){ closeMenu();
            var inp=document.getElementById('goalText');
            if(inp){ inp.scrollIntoView({block:'center'}); inp.focus(); }
            else { location.href='/?compose=plain'; }
          };
          // Honor a ?compose= hint after navigating here from another page's rail.
          (function(){ try{ var c=new URLSearchParams(location.search).get('compose'); if(!c) return;
            function go(){ if(c==='ai'){ if(typeof openGoalAdd==='function') openGoalAdd({sprint:0,label:'Backlog'}); }
              else { var inp=document.getElementById('goalText'); if(inp){ inp.scrollIntoView({block:'center'}); inp.focus(); } } }
            if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',function(){ setTimeout(go,60); }); else setTimeout(go,60);
          }catch(e){} })();

          // Live background CLI sessions.
          function killSession(token, ev){ if(ev) ev.stopPropagation();
            fetch('/api/goal/cli/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:token})}).then(loadSessions).catch(loadSessions);
          }
          // Claude-Desktop status vocabulary. The dot's color/shape mirrors what the session
          // needs from the user, NOT just whether a terminal is open:
          //   확인 요청  (waiting+permission) -> blue solid     #5b8cff
          //   의사결정 요청 (waiting+decision)  -> amber solid    #e8a33d
          //   진행 중    (in_progress)         -> gray pulsing   (blinking)
          //   완료       (done)               -> gray hollow ring
          // rank: lower = higher up the list (actionable items first).
          function stateMeta(s){
            if(s.status==='waiting' && s.waitKind==='permission') return {color:'#5b8cff', label:'확인 요청', rank:0};
            if(s.status==='waiting') return {color:'#e8a33d', label:'의사결정 요청', rank:1};
            if(s.status==='done') return {color:'#8b93a7', label:'완료', hollow:true, rank:3};
            if(s.status==='stopped') return {color:'#8b93a7', label:'중지', rank:2};
            return {color:'#8b93a7', label:'진행 중', pulse:true, rank:2};   // in_progress / running
          }
          function loadSessions(){
            fetch('/api/cli/sessions').then(function(r){return r.json();}).then(function(d){
              var box=document.getElementById('cmRailSessions'); if(!box) return;
              var list=(d&&d.sessions)||[];
              if(!list.length){ box.innerHTML='<span class="cmrail-empty">진행 중인 세션이 없습니다</span>'; return; }
              // Actionable first (확인/의사결정 요청), then 진행 중, then 완료; ties by goal number.
              list.forEach(function(s){ s._m=stateMeta(s); });
              list.sort(function(a,b){ return a._m.rank-b._m.rank || (a.seq||0)-(b.seq||0); });
              box.innerHTML='';
              list.forEach(function(s){
                var m=s._m;
                var row=document.createElement('div'); row.className='cmrail-sess'+(s.seq===CMRAIL_SEQ?' on':'');
                row.onclick=function(){ location.href='/goal?n='+s.seq+'&cli=1'; };
                var dotCls='dot'+(m.pulse?' pulse':'')+(m.hollow?' hollow':'');
                var style=m.hollow?('border-color:'+m.color):('background:'+m.color);
                row.innerHTML='<span class="'+dotCls+'" style="'+style+'"></span>'
                  +'<div class="meta"><div class="ttl">'+esc(s.title||('goal-'+s.seq))+'</div>'
                  +'<div class="sub">goal-'+s.seq+' · '+m.label+'</div></div>';
                // Only live PTY sessions can be terminated (idle/done goals have no process).
                if(s.live){ var kill=document.createElement('button'); kill.className='kill'; kill.title='세션 종료'; kill.textContent='✕';
                  kill.onclick=function(e){ killSession(s.token,e); }; row.appendChild(kill); }
                box.appendChild(row);
              });
            }).catch(function(){});
          }
          loadSessions(); setInterval(loadSessions, 3000);
        })();
        </script>
        """#
    }
}
