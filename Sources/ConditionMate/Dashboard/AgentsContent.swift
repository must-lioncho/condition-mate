import Foundation

// GET /agents — 에이전트 인벤토리 페이지.
//
// 왜 별도 페이지인가: 레일의 '위임' 오버레이는 전역 폴더(~/.claude/agents) 하나만 본다. 그런데
// 실제 에이전트 정의는 세 곳에 흩어져 산다 — 전역, 스킬 하네스(~/.claude/skills/<skill>/.claude/
// agents), 그리고 프로젝트별(<project>/.claude/agents). 전역이 비어 있고 일은 프로젝트 에이전트가
// 하는 상태(2026-08 현재)에서는 오버레이가 "에이전트가 없습니다"만 말한다. 루프를
// 관리하려면 세 곳을 한 화면에서 봐야 한다.
//
// 화면이 답해야 하는 질문은 셋이다:
//   1. 지금 어떤 에이전트가 어디에 있는가            → 스코프별 목록 + 목적 + 도구/모델
//   2. 그 에이전트가 실제로 일을 하고 있는가          → 원장 기반 실행 횟수·성공률·기능 역할
//   3. 원하는 결과를 못 내면 무엇을 할 것인가         → 판정(목적 달성/교체 필요) + 교체 위임
//
// 3번의 '교체 위임'은 팀위임과 같은 경로를 쓴다: POST /api/agents/replace 가 goal 을 만들고
// 첫 턴 프롬프트를 돌려주면, 이 페이지가 그것을 sessionStorage(cmGoalKick:<seq>)에 넣고
// /goal?seq=N 으로 이동한다 — 목표 페이지가 첫 턴으로 쏘아 Claude 가 정의 파일을 고치기 시작한다.
enum AgentsContent {

    static func html() -> String {
        return #"""
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>에이전트 · 루프 엔지니어링</title>
        <style>
          :root{--bg:#0e1116;--panel:#141821;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#5b8cff}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;z-index:30;display:flex;align-items:center;justify-content:space-between;gap:12px;
            background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          main{max-width:1080px;margin:0 auto;padding:18px 20px 90px}
          .btn{background:#1d2230;border:1px solid var(--line);color:var(--fg);border-radius:8px;
            padding:6px 12px;font-size:13px;cursor:pointer;text-decoration:none;display:inline-block;white-space:nowrap}
          .btn:hover{background:#242b3b}
          .btn.pri{background:#1d2740;border-color:#33518f}
          .btn.bad{background:#2a1620;border-color:#5a2738;color:#ff9db0}
          .btn.ok{background:#12281a;border-color:#1c4128;color:#7ee29a}

          /* 요약 — 이 맥의 에이전트 지형을 한 줄로. 숫자가 곧 관리 대상의 크기다. */
          .sum{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px}
          .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:10px 14px;min-width:104px}
          .card .n{font-size:20px;font-weight:700;line-height:1.2}
          .card .k{color:var(--mut);font-size:11px;letter-spacing:.03em}
          .card.warn .n{color:#f85149}

          .tools{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:14px}
          .tools input[type=text]{flex:1;min-width:180px;background:#11151d;border:1px solid var(--line);
            color:var(--fg);border-radius:8px;padding:7px 11px;font-size:13px;outline:none}
          .tools input[type=text]:focus{border-color:#33518f}
          .chip{background:#161b25;border:1px solid var(--line);color:var(--mut);border-radius:8px;
            padding:6px 12px;font-size:12px;cursor:pointer}
          .chip:hover{background:#1d2230;color:var(--fg)}
          .chip.on{background:#1d2740;border-color:#33518f;color:var(--fg);font-weight:600}
          .tg{color:var(--mut);font-size:12px;display:flex;align-items:center;gap:6px;cursor:pointer;white-space:nowrap}

          /* 스코프 = 에이전트가 사는 폴더 하나. 폴더가 곧 "누구의 에이전트인가"를 말한다. */
          .scope{margin-bottom:16px;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
          .shd{display:flex;align-items:center;gap:10px;padding:11px 14px;border-bottom:1px solid var(--line);flex-wrap:wrap}
          .shd .nm{font-size:14px;font-weight:600}
          .kind{font-size:11px;padding:1px 8px;border-radius:20px;border:1px solid var(--line);background:#1a2336;color:#9fb6e8}
          .kind.skill{background:#1d1a2e;border-color:#3a2f5a;color:#c3a7ff}
          .kind.project{background:#12281a;border-color:#1c4128;color:#7ee29a}
          .shd .cnt{color:var(--mut);font-size:12px}
          .shd .path{color:#5d6678;font:11px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;
            margin-left:auto;max-width:52%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}

          .row{display:flex;align-items:center;gap:10px;padding:11px 14px;border-top:1px solid #171d28;cursor:pointer}
          .scope .row:first-of-type{border-top:0}
          .row:hover{background:#171c26}
          .caret{color:#5d6678;font-size:10px;width:12px;text-align:center;flex:none}
          .dot{width:9px;height:9px;border-radius:50%;flex:none;background:#33405a}
          .dot.ok{background:#3fb950} .dot.rep{background:#f85149}
          .nm2{flex:none;font-size:13px;font-weight:600;color:#dbe2ee;white-space:nowrap}
          .purpose{flex:1;min-width:40px;color:var(--mut);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
          .rate{font-size:15px;font-weight:700;line-height:1;flex:none}
          .meta{color:#5d6678;font-size:11px;white-space:nowrap;flex:none;text-align:right;min-width:76px}
          .flag{font-size:11px;padding:1px 8px;border-radius:20px;flex:none;white-space:nowrap}
          .flag.rep{background:#2a1416;color:#f85149;border:1px solid #4a1f22}
          .flag.ok{background:#12281a;color:#3fb950;border:1px solid #1c4128}

          .body{padding:0 14px 16px 36px;border-top:1px solid #171d28;background:#101520}
          .desc{color:#cfd6e2;font-size:13px;margin:12px 0;white-space:pre-wrap;word-break:keep-all}
          .tags{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px}
          .tag{font-size:11px;padding:2px 9px;border-radius:20px;background:#1a1f2b;border:1px solid var(--line);color:#9aa4b6}
          .stat{color:var(--mut);font-size:12px;margin-bottom:10px}
          .funcs{margin:6px 0 12px}
          .frow{display:flex;align-items:center;gap:9px;padding:5px 0;border-top:1px solid #161c26;font-size:12px}
          .frow:first-child{border-top:0}
          .fnm{color:#c8cfdb;font-weight:600} .fcnt{color:#e6e9ef;background:#1a2336;border:1px solid #263149;
            border-radius:20px;padding:0 8px} .fnote{color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .dots{display:flex;flex-wrap:wrap;gap:3px;margin-bottom:12px}
          .d{width:7px;height:7px;border-radius:2px;background:#3fb950} .d.no{background:#f85149}

          /* 판정 — 성공률과 다른 축이다. 매번 ok 로 끝났는데 결과물이 쓸모없을 수 있다. */
          .judge{border:1px solid var(--line);border-radius:10px;padding:11px 12px;background:#0e131c;margin-bottom:10px}
          .judge .lb{color:var(--mut);font-size:11px;letter-spacing:.04em;text-transform:uppercase;margin-bottom:7px}
          .judge textarea{width:100%;min-height:52px;background:#11151d;border:1px solid var(--line);color:var(--fg);
            border-radius:8px;padding:8px 10px;font:13px/1.5 inherit;outline:none;resize:vertical}
          .judge textarea:focus{border-color:#33518f}
          .jact{display:flex;gap:8px;flex-wrap:wrap;margin-top:9px;align-items:center}
          .jnow{color:var(--mut);font-size:12px}
          .acts{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
          .fpath{color:#5d6678;font:11px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;
            overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .empty{color:var(--mut);text-align:center;padding:34px 0}
          .foot{color:#5d6678;font-size:11px;text-align:center;margin-top:16px}
        </style></head>
        <body>
          <script>window.CM_PAGE='agents';</script>
          \#(SessionRail.html())
          <header>
            <div><h1>에이전트</h1><div class="sub">전역·스킬·프로젝트에 흩어진 에이전트를 한곳에서 보고, 목적을 못 이룬 에이전트를 교체합니다</div></div>
            <div class="acts"><button class="btn" onclick="agLoad()">새로고침</button></div>
          </header>
          <main>
            <div class="sum" id="agSum"></div>
            <div class="tools">
              <input type="text" id="agQ" placeholder="이름·목적으로 찾기" oninput="agRender()">
              <button class="chip on" data-k="" onclick="agScope(this)">전체</button>
              <button class="chip" data-k="global" onclick="agScope(this)">전역</button>
              <button class="chip" data-k="skill" onclick="agScope(this)">스킬 하네스</button>
              <button class="chip" data-k="project" onclick="agScope(this)">프로젝트</button>
              <label class="tg"><input type="checkbox" id="agRep" onchange="agRender()">교체 필요만</label>
            </div>
            <div id="agList"><div class="empty">불러오는 중…</div></div>
            <div class="foot" id="agFoot"></div>
          </main>
        <script>
        (function(){
          var D=null, KIND='', OPEN={};   // OPEN: 펼침 상태를 경로로 기억(새로고침해도 유지)

          function esc(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }
          function fmtTs(ts){ if(!ts) return '없음';
            try{ var d=new Date(ts); if(isNaN(d.getTime())) return ts;
              var p=(window.CMTimeFilter&&window.CMTimeFilter.parts)?window.CMTimeFilter.parts(d):
                {mo:d.getMonth()+1,d:d.getDate(),h:d.getHours(),mi:d.getMinutes()};
              return p.mo+'/'+p.d+' '+String(p.h).padStart(2,'0')+':'+String(p.mi).padStart(2,'0');
            }catch(e){ return ts; } }
          function fmtRel(ts){ if(!ts) return '';
            try{ var t=new Date(ts).getTime(); if(isNaN(t)) return '';
              var s=Math.max(0,(Date.now()-t)/1000);
              if(s<60) return '방금'; if(s<3600) return Math.floor(s/60)+'분전';
              if(s<86400) return Math.floor(s/3600)+'시간전'; if(s<2592000) return Math.floor(s/86400)+'일전';
              return Math.floor(s/2592000)+'개월전'; }catch(e){ return ''; } }

          window.agLoad=function(){
            fetch('/api/agents/inventory').then(function(r){ return r.json(); })
              .then(function(d){ D=d; agRender(); })
              .catch(function(){ var l=document.getElementById('agList');
                if(l) l.innerHTML='<div class="empty">에이전트 목록을 불러오지 못했습니다</div>'; });
          };
          window.agScope=function(btn){
            KIND=btn.getAttribute('data-k')||'';
            var cs=document.querySelectorAll('.chip');
            for(var i=0;i<cs.length;i++) cs[i].classList.toggle('on', cs[i]===btn);
            agRender();
          };

          function summary(t){
            var box=document.getElementById('agSum'); if(!box||!t) return;
            var cards=[
              ['에이전트', t.agents||0, ''],
              ['실행 기록 있음', t.ran||0, ''],
              ['프로젝트', t.projects||0, ''],
              ['보관 위치', t.scopes||0, ''],
              ['교체 필요', t.replace||0, (t.replace>0?'warn':'')]
            ];
            box.innerHTML=cards.map(function(c){
              return '<div class="card '+c[2]+'"><div class="n">'+c[1]+'</div><div class="k">'+c[0]+'</div></div>';
            }).join('');
          }

          window.agRender=function(){
            var box=document.getElementById('agList'); if(!box||!D) return;
            summary(D.totals);
            var qi=document.getElementById('agQ'); var q=((qi&&qi.value)||'').trim().toLowerCase();
            var rep=document.getElementById('agRep'); var onlyRep=!!(rep&&rep.checked);
            var scopes=(D.scopes||[]).filter(function(s){ return !KIND || s.kind===KIND; });
            box.innerHTML='';
            var shown=0;
            scopes.forEach(function(s){
              var list=(s.agents||[]).filter(function(a){
                if(onlyRep && !(a.verdict&&a.verdict.state==='replace')) return false;
                if(!q) return true;
                return ((a.name||'')+' '+(a.desc||'')+' '+(a.file||'')).toLowerCase().indexOf(q)>=0;
              });
              // 전역 폴더는 비어 있어도 접지 않는다 — "전역에 무엇이 있나"의 답이 '아무것도 없다'
              // 인 것과, 화면이 그 폴더를 아예 안 본 것은 다르다. 단, 검색/필터 중일 때는 접는다.
              var keepEmpty=(s.kind==='global' && !q && !onlyRep);
              if(!list.length && !keepEmpty) return;
              shown+=list.length;
              var sec=document.createElement('div'); sec.className='scope';
              var kindLabel=(s.kind==='global')?'전역':(s.kind==='skill'?'스킬 하네스':'프로젝트');
              sec.innerHTML='<div class="shd">'
                +'<span class="nm">'+esc(s.name)+'</span>'
                +'<span class="kind '+esc(s.kind)+'">'+kindLabel+'</span>'
                +'<span class="cnt">'+list.length+'개</span>'
                +'<span class="path" title="'+esc(s.dir)+'">'+esc(s.dir)+'</span>'
                +'</div>';
              if(list.length){ list.forEach(function(a){ sec.appendChild(agentCard(a)); }); }
              else {
                var e=document.createElement('div'); e.className='empty';
                e.style.padding='18px 0'; e.style.fontSize='12px';
                e.textContent='이 폴더에는 에이전트 정의가 없습니다 — 모든 프로젝트에서 부를 에이전트는 여기에 둡니다';
                sec.appendChild(e);
              }
              box.appendChild(sec);
            });
            if(!shown && !box.children.length){
              box.innerHTML='<div class="empty">'+((D.totals&&D.totals.agents)
                ? '조건에 맞는 에이전트가 없습니다'
                : '에이전트 정의(.md)를 찾지 못했습니다 — ~/.claude/agents/ 또는 프로젝트의 .claude/agents/ 에 두면 여기 나타납니다')+'</div>';
            }
            var f=document.getElementById('agFoot');
            if(f) f.textContent='전역 폴더 '+((D&&D.globalDir)||'')+' · 프로젝트는 워크스페이스와 Claude Code 세션 기록에서 찾습니다';
          };

          // tools 프론트매터는 JSON 배열 문자열(["Bash","Read"])로도, 쉼표 목록으로도 적힌다.
          // 사람 눈에는 둘 다 이름 목록이면 충분하다. 빈 배열은 태그 자체를 달지 않는다.
          function toolsLabel(t){
            var v=(t==null?'':String(t)).trim();
            if(!v||v==='[]') return '';
            try{ var arr=JSON.parse(v); if(Array.isArray(arr)) return arr.length?arr.join(', '):''; }catch(e){}
            return v;
          }

          function agentCard(a){
            var wrap=document.createElement('div');
            var v=a.verdict||{}, st=v.state||'';
            var ran=(a.runs||0)>0, rate=Math.round((a.recentRate||0)*100);
            var rc=rate>=80?'#3fb950':(rate>=50?'#d29922':'#f85149');
            var flag=(st==='replace')?'<span class="flag rep">교체 필요</span>'
                    :(st==='ok'?'<span class="flag ok">목적 달성</span>':'');
            var row='<div class="row">'
              +'<span class="caret">▸</span>'
              +'<span class="dot '+(st==='replace'?'rep':(st==='ok'?'ok':''))+'"></span>'
              +'<span class="nm2">'+esc(a.name)+'</span>'
              +flag
              +'<span class="purpose">'+esc(a.desc||'')+'</span>'
              +(ran?'<span class="rate" style="color:'+rc+'">'+rate+'%</span>'
                   :'<span class="rate" style="color:#3a445c">—</span>')
              +'<span class="meta">'+esc(ran?((a.recentN||0)+'회 · '+fmtRel(a.lastTs)):'기록 없음')+'</span>'
              +'</div>';

            var tags='<div class="tags"><span class="tag">모델 '+esc(a.model||'inherit')+'</span>'
              +(a.harness?'<span class="tag">하네스 '+esc(a.harness)+'</span>':'')
              +(toolsLabel(a.tools)?'<span class="tag">도구 '+esc(toolsLabel(a.tools))+'</span>':'')
              +'<span class="tag">수정 '+esc(fmtTs(a.mtime))+'</span></div>';

            var stat=ran
              ? '<div class="stat">최근 '+(a.recentN||0)+'회 성공률 '+rate+'% · 누적 실행 '+(a.runs||0)+'회 · 마지막 '
                +esc(fmtTs(a.lastTs))+' ('+(a.lastOutcome==='fail'?'실패':'성공')+')</div>'
              : '<div class="stat">실행 기록 없음 — 이 에이전트가 원장(agent-update-log.jsonl)에 기록하면 성적이 여기 쌓입니다</div>';

            var dots=(a.recent||[]).slice(-32).map(function(r){
              return '<span class="d '+(r.ok?'':'no')+'" title="'+esc(fmtTs(r.ts)+' · '+(r.label||''))+'"></span>';
            }).join('');
            var dotsHtml=dots?('<div class="dots">'+dots+'</div>'):'';

            var funcs=(a.functions||[]);
            var funcHtml='';
            if(funcs.length){
              funcHtml='<div class="funcs">'+funcs.map(function(f){
                var r=(f.avgRounds!=null)?(' · 평균 '+(Math.round(f.avgRounds*10)/10)+'라운드'):'';
                return '<div class="frow"><span class="fnm">'+esc(f.name)+'</span>'
                  +'<span class="fcnt">'+(f.count||0)+'회</span>'
                  +'<span class="fnote">'+esc((f.sample||'')+r)+'</span></div>';
              }).join('')+'</div>';
            }

            var judged=st?('<span class="jnow">현재 판정: '+(st==='replace'?'교체 필요':'목적 달성')
              +(v.ts?(' · '+esc(fmtTs(v.ts))):'')+(v.seq?(' · 교체 세션 #'+v.seq):'')+'</span>'):'';
            var judge='<div class="judge">'
              +'<div class="lb">판정 — 이 에이전트가 원하는 결과를 냈습니까</div>'
              +'<textarea class="jr" placeholder="무엇이 기대와 달랐는지 (교체 위임 시 그대로 전달됩니다)">'+esc(v.reason||'')+'</textarea>'
              +'<div class="jact">'
                +'<button class="btn ok" data-act="ok">목적 달성</button>'
                +'<button class="btn bad" data-act="replace">교체 필요로 표시</button>'
                +(st?'<button class="btn" data-act="clear">판정 해제</button>':'')
                +judged
              +'</div></div>';

            var acts='<div class="acts">'
              +'<button class="btn" data-act="open">📂 정의 파일 열기</button>'
              +'<button class="btn pri" data-act="delegate">🔁 교체 위임 (세션 생성)</button>'
              +'<span class="fpath" title="'+esc(a.path)+'">'+esc(a.path)+'</span></div>';

            var open=!!OPEN[a.path];
            wrap.innerHTML=row+'<div class="body" style="display:'+(open?'block':'none')+'">'
              +tags+'<div class="desc">'+esc(a.desc||'(목적이 적혀 있지 않습니다)')+'</div>'
              +stat+dotsHtml+funcHtml+judge+acts+'</div>';

            var rowEl=wrap.querySelector('.row'), body=wrap.querySelector('.body'), caret=wrap.querySelector('.caret');
            if(open&&caret) caret.textContent='▾';
            rowEl.onclick=function(){
              var willOpen=body.style.display==='none';
              body.style.display=willOpen?'block':'none';
              caret.textContent=willOpen?'▾':'▸';
              OPEN[a.path]=willOpen;
            };
            var btns=wrap.querySelectorAll('[data-act]');
            for(var i=0;i<btns.length;i++){
              btns[i].onclick=function(e){
                e.stopPropagation();
                var act=this.getAttribute('data-act');
                var ta=wrap.querySelector('.jr'); var reason=(ta&&ta.value||'').trim();
                if(act==='open') return reveal(a.path);
                if(act==='delegate') return delegate(a, reason, this);
                var state=(act==='clear')?'':act;
                if(state==='replace'&&!reason){
                  if(!confirm('사유 없이 교체 필요로 표시할까요? 사유를 적어 두면 교체 위임 때 그대로 전달됩니다.')) return;
                }
                verdict(a.path, state, reason, this);
              };
            }
            return wrap;
          }

          function reveal(path){
            fetch('/api/agents/reveal',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({path:path})}).catch(function(){});
          }
          function verdict(path, state, reason, btn){
            if(btn) btn.disabled=true;
            fetch('/api/agents/verdict',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({path:path,state:state,reason:reason})})
              .then(function(r){ return r.json(); })
              .then(function(d){ if(d&&d.scopes){ D=d; agRender(); } else { if(btn) btn.disabled=false; } })
              .catch(function(){ if(btn) btn.disabled=false; });
          }
          // 교체 위임: goal 을 만들고 첫 턴 프롬프트를 받아 목표 페이지로 넘긴다(팀위임과 같은 경로).
          function delegate(a, reason, btn){
            if(!confirm('에이전트 '+a.name+' 을(를) 고쳐 쓸 세션을 만들까요?\n작업 폴더는 이 에이전트가 사는 폴더로 잡힙니다.')) return;
            if(btn) btn.disabled=true;
            fetch('/api/agents/replace',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({path:a.path,reason:reason})})
              .then(function(r){ return r.json(); })
              .then(function(d){
                if(!d||!d.ok||!d.seq){ if(btn) btn.disabled=false; alert('세션을 만들지 못했습니다'); return; }
                try{ sessionStorage.setItem('cmGoalKick:'+d.seq,
                  JSON.stringify({text:d.prompt,mode:'bypassPermissions'})); }catch(e){}
                location.href='/goal?seq='+d.seq;
              })
              .catch(function(){ if(btn) btn.disabled=false; });
          }

          if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', agLoad);
          else agLoad();
        })();
        </script>
        </body></html>
        """#
    }
}
