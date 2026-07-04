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
            <a class="cmrail-item" id="cmRailSkills" onclick="cmSkillsOpen(event)">🧩 스킬</a>
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

        <!-- ===== 스킬 목록 오버레이 (rail의 "스킬" 클릭 시 열림) — ~/.claude/skills 를 표시 ===== -->
        <style>
          /* Sit to the RIGHT of the rail so the left sidebar stays visible/usable;
             when the rail is collapsed, reclaim the full width. */
          .cmsk-overlay{ position:fixed; top:0; right:0; bottom:0; left:var(--cmrail-w); z-index:80;
            background:#0a0d12; display:flex; flex-direction:column; color:#c8cfdb;
            font:14px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif }
          body.cmrail-collapsed .cmsk-overlay{ left:0 }
          .cmsk-panel{ flex:1; display:flex; flex-direction:column; width:100%; max-width:1100px;
            margin:0 auto; padding:22px 28px; min-height:0 }
          .cmsk-head{ display:flex; align-items:center; gap:10px; margin-bottom:20px }
          .cmsk-title{ font-size:24px; font-weight:700; color:#eef2f8 }
          .cmsk-actions{ margin-left:auto; display:flex; align-items:center; gap:8px }
          .cmsk-icon{ background:none; border:0; color:#c8cfdb; font-size:15px; cursor:pointer;
            padding:7px 9px; border-radius:8px; line-height:1 }
          .cmsk-icon:hover{ background:#1a2130 }
          .cmsk-search{ background:#141a26; border:1px solid #2a3450; border-radius:8px; color:#e7ecf4;
            padding:7px 10px; width:190px; font-size:13px; outline:none }
          .cmsk-btn{ background:#20283a; border:1px solid #2f3a54; color:#e7ecf4; border-radius:8px;
            padding:7px 14px; font-size:13px; font-weight:600; cursor:pointer }
          .cmsk-btn:hover{ background:#28324a }
          .cmsk-addwrap{ position:relative }
          .cmsk-addmenu{ position:absolute; right:0; top:40px; background:#171d2b; border:1px solid #2a3450;
            border-radius:10px; padding:5px; min-width:230px; box-shadow:0 14px 34px rgba(0,0,0,.55); z-index:5 }
          .cmsk-addmenu button{ display:block; width:100%; text-align:left; background:none; border:0;
            color:#d4dbe7; padding:9px 10px; border-radius:7px; font-size:13px; cursor:pointer }
          .cmsk-addmenu button:hover{ background:#222c42 }
          .cmsk-cols,.cmsk-row{ display:grid; grid-template-columns:1fr 200px 150px; gap:12px }
          .cmsk-cols{ padding:0 14px 10px; color:#8792a5; font-size:13px; border-bottom:1px solid #1c2330 }
          .cmsk-list{ flex:1; overflow-y:auto; min-height:0 }
          .cmsk-row{ padding:14px; border-bottom:1px solid #161c28; cursor:pointer; align-items:start }
          .cmsk-row:hover{ background:#111722 }
          .cmsk-row .c1{ min-width:0 }
          .cmsk-row .nmrow{ display:flex; align-items:center; gap:8px }
          .cmsk-row .nm{ color:#e7ecf4; font-size:16px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmsk-edit{ background:none; border:0; color:#5d6678; cursor:pointer; font-size:12px; padding:2px 5px;
            border-radius:5px; flex:none; visibility:hidden }
          .cmsk-row:hover .cmsk-edit{ visibility:visible }
          .cmsk-edit:hover{ background:#222c42; color:#c8cfdb }
          .cmsk-row .sm{ color:#8792a5; font-size:13px; margin-top:4px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .cmsk-row .sm.empty{ color:#5a6474; font-style:italic }
          .cmsk-row .dt,.cmsk-row .au{ color:#9aa4b6; font-size:14px; padding-top:2px }
          .cmsk-edrow{ display:flex; align-items:center; gap:6px; margin-top:6px }
          .cmsk-sminput{ flex:1; min-width:0; background:#141a26; border:1px solid #2a3450; border-radius:6px;
            color:#e7ecf4; padding:6px 9px; font-size:13px; outline:none }
          .cmsk-sminput:focus{ border-color:#3d63b8 }
          .cmsk-mini{ flex:none; background:#20283a; border:1px solid #2f3a54; color:#e7ecf4; border-radius:6px;
            padding:6px 11px; font-size:12px; font-weight:600; cursor:pointer }
          .cmsk-mini.cmsk-pri{ background:#2f5bd0; border-color:#3d63b8 }
          .cmsk-mini:hover{ filter:brightness(1.12) }
          .cmsk-empty{ padding:44px 14px; color:#6b7589; text-align:center }
          .cmsk-foot{ padding:12px 14px 0; color:#5d6678; font-size:12px }
          /* Configurable skills base folder (defaults to ~/.claude). */
          .cmsk-folderbar{ display:flex; align-items:center; gap:9px; margin:-6px 0 16px; padding:9px 12px;
            background:#0f141d; border:1px solid #1c2330; border-radius:9px; font-size:12.5px }
          .cmsk-folderbar .lbl{ color:#6b7589; flex:none }
          .cmsk-folderbar .pth{ color:#c8cfdb; flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis;
            white-space:nowrap; font-family:ui-monospace,SFMono-Regular,Menlo,monospace }
          .cmsk-folderbar .tag{ flex:none; color:#5d6678; font-size:11px }
          .cmsk-folderbar button{ flex:none; background:#20283a; border:1px solid #2f3a54; color:#e7ecf4;
            border-radius:7px; padding:5px 11px; font-size:12px; font-weight:600; cursor:pointer }
          .cmsk-folderbar button:hover{ background:#28324a }
        </style>
        <div class="cmsk-overlay" id="cmSkOverlay" style="display:none">
          <div class="cmsk-panel">
            <div class="cmsk-head">
              <div class="cmsk-title">스킬</div>
              <div class="cmsk-actions">
                <button class="cmsk-icon" title="검색" onclick="cmSkToggleSearch()">🔍</button>
                <input class="cmsk-search" id="cmSkSearch" placeholder="스킬 검색…" oninput="cmSkRender()" style="display:none">
                <button class="cmsk-btn" onclick="cmSkReveal('')">찾아보기</button>
                <div class="cmsk-addwrap">
                  <button class="cmsk-btn" onclick="cmSkToggleAdd(event)">추가 ▾</button>
                  <div class="cmsk-addmenu" id="cmSkAddMenu" style="display:none">
                    <button onclick="cmSkReveal('')">Finder에서 스킬 폴더 열기</button>
                  </div>
                </div>
                <button class="cmsk-icon" title="닫기 (Esc)" onclick="cmSkClose()">✕</button>
              </div>
            </div>
            <div class="cmsk-folderbar">
              <span class="lbl">스킬 폴더</span>
              <span class="pth" id="cmSkRoot" title="">~/.claude</span>
              <span class="tag" id="cmSkRootTag"></span>
              <button onclick="cmSkPickFolder()">변경</button>
              <button onclick="cmSkResetFolder()">기본값</button>
            </div>
            <div class="cmsk-cols"><span>스킬</span><span>마지막 업데이트</span><span>작성자</span></div>
            <div class="cmsk-list" id="cmSkList"></div>
            <div class="cmsk-foot" id="cmSkFoot"></div>
          </div>
        </div>
        <script>
        (function(){
          function esc2(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }
          function escAttr(t){ return esc2(t).replace(/"/g,'&quot;'); }
          var _data=[], _dir='', _root='';
          window.cmSkillsOpen=function(ev){ if(ev) ev.preventDefault(); var o=document.getElementById('cmSkOverlay');
            if(o){ o.style.display='flex'; load(); } };
          window.cmSkClose=function(){ var o=document.getElementById('cmSkOverlay'); if(o) o.style.display='none';
            var m=document.getElementById('cmSkAddMenu'); if(m) m.style.display='none'; };
          window.cmSkToggleSearch=function(){ var s=document.getElementById('cmSkSearch'); if(!s) return;
            var show=(s.style.display==='none'); s.style.display=show?'block':'none';
            if(show){ s.focus(); } else { s.value=''; cmSkRender(); } };
          window.cmSkToggleAdd=function(ev){ if(ev) ev.stopPropagation(); var m=document.getElementById('cmSkAddMenu');
            if(m) m.style.display=(m.style.display==='none'?'block':'none'); };
          // Open the skills folder (or one skill) in Finder so the user can inspect/edit files.
          window.cmSkReveal=function(name){
            fetch('/api/skills/reveal',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({name:name||''})}).catch(function(){});
            var m=document.getElementById('cmSkAddMenu'); if(m) m.style.display='none'; };
          // Apply a /api/skills payload to the UI: folder line + skills list in one pass.
          function applyData(d){
            _data=(d&&d.skills)||[]; _dir=(d&&d.dir)||''; _root=(d&&d.root)||'';
            var f=document.getElementById('cmSkFoot'); if(f) f.textContent=_dir?('폴더: '+_dir):'';
            var rt=document.getElementById('cmSkRoot');
            if(rt){ rt.textContent=_root||'~/.claude'; rt.title=_root||''; }
            var tag=document.getElementById('cmSkRootTag');
            if(tag) tag.textContent=(d&&d.isDefault)?'기본값':'';
            cmSkRender();
          }
          function load(){ var box=document.getElementById('cmSkList'); if(box) box.innerHTML='<div class="cmsk-empty">불러오는 중…</div>';
            fetch('/api/skills').then(function(r){return r.json();}).then(applyData)
            .catch(function(){ if(box) box.innerHTML='<div class="cmsk-empty">스킬을 불러오지 못했습니다</div>'; }); }
          // Choose the skills base (.claude) folder via a native picker, then reload the list.
          window.cmSkPickFolder=function(){
            fetch('/api/skills/folder/pick',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})
              .then(function(r){return r.json();}).then(applyData).catch(function(){}); };
          // Reset the skills base folder back to the ~/.claude default.
          window.cmSkResetFolder=function(){
            fetch('/api/skills/folder',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({folder:''})}).then(function(r){return r.json();}).then(applyData).catch(function(){}); };
          window.cmSkRender=function(){ var box=document.getElementById('cmSkList'); if(!box) return;
            var si=document.getElementById('cmSkSearch'); var q=((si&&si.value)||'').trim().toLowerCase();
            var list=_data.filter(function(s){ if(!q) return true;
              return (s.name||'').toLowerCase().indexOf(q)>=0
                  || (s.summary||'').toLowerCase().indexOf(q)>=0
                  || (s.desc||'').toLowerCase().indexOf(q)>=0; });
            if(!list.length){ box.innerHTML='<div class="cmsk-empty">'+(q?'검색 결과가 없습니다':('스킬이 없습니다'+(_dir?' — '+esc2(_dir):'')))+'</div>'; return; }
            box.innerHTML='';
            list.forEach(function(s){ var key=s.folder||s.name;
              var row=document.createElement('div'); row.className='cmsk-row'; row.dataset.key=key;
              // Clicking the row (but not the edit button/inputs) opens the folder in Finder.
              row.onclick=function(e){ if(e.target.closest('.cmsk-edit')||e.target.closest('.cmsk-edrow')) return; cmSkReveal(key); };
              var sm=(s.summary||'').trim();
              var smHtml=sm?('<div class="sm" title="'+escAttr(sm)+'">'+esc2(sm)+'</div>')
                           :('<div class="sm empty">한줄 요약 없음 — 연필을 눌러 추가</div>');
              row.innerHTML='<div class="c1">'
                  +'<div class="nmrow"><span class="nm">'+esc2(s.name)+'</span>'
                  +'<button class="cmsk-edit" title="한줄 요약 수정">✏️</button></div>'
                  +smHtml
                +'</div>'
                +'<span class="dt">'+esc2(s.updated||'')+'</span>'
                +'<span class="au">'+esc2(s.author||'사용자')+'</span>';
              row.querySelector('.cmsk-edit').onclick=function(e){ e.stopPropagation(); startEdit(row, key, sm); };
              box.appendChild(row); }); };

          // Swap a row's summary line for an inline editor (input + 저장/취소).
          function startEdit(row, key, cur){
            var c1=row.querySelector('.c1'); if(!c1) return;
            var old=c1.querySelector('.sm'); if(old) old.style.display='none';
            var prev=c1.querySelector('.cmsk-edrow'); if(prev) prev.remove();
            var box=document.createElement('div'); box.className='cmsk-edrow';
            box.innerHTML='<input class="cmsk-sminput" maxlength="200" placeholder="한줄 요약을 입력…" value="'+escAttr(cur||'')+'">'
              +'<button class="cmsk-mini cmsk-pri" data-a="save">저장</button>'
              +'<button class="cmsk-mini" data-a="cancel">취소</button>';
            c1.appendChild(box);
            var inp=box.querySelector('.cmsk-sminput'); inp.focus(); inp.select();
            inp.onclick=function(e){ e.stopPropagation(); };
            box.querySelector('[data-a=save]').onclick=function(e){ e.stopPropagation(); saveSummary(key, inp.value); };
            box.querySelector('[data-a=cancel]').onclick=function(e){ e.stopPropagation(); cmSkRender(); };
            inp.onkeydown=function(e){ e.stopPropagation();
              if(e.key==='Enter'){ saveSummary(key, inp.value); }
              else if(e.key==='Escape'){ cmSkRender(); } };
          }
          function saveSummary(key, val){
            fetch('/api/skills/summary',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({folder:key, summary:val})}).then(function(r){return r.json();})
              .then(function(){ var s=_data.find(function(x){return (x.folder||x.name)===key;});
                if(s){ s.summary=(val||'').trim(); s.hasSummary=!!s.summary; } cmSkRender(); })
              .catch(function(){ cmSkRender(); });
          }
          document.addEventListener('keydown',function(e){ if(e.key==='Escape'){ var o=document.getElementById('cmSkOverlay');
            if(o&&o.style.display!=='none') cmSkClose(); } });
          document.addEventListener('click',function(e){ var w=document.querySelector('.cmsk-addwrap'); var m=document.getElementById('cmSkAddMenu');
            if(m&&m.style.display!=='none'&&w&&!w.contains(e.target)) m.style.display='none'; });
        })();
        </script>
        """#
    }
}
