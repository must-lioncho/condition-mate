import Foundation

// 큐 카드 라이브러리 — AI 큐 리뷰 UI. 원래 대시보드 '큐 탭' → chat(/goal-add)의 detail-큐
// 표면(2026-07-17)을 거쳐, 2026-07-19 simple/detail 큐 병합으로 별도 표면이 사라지고
// "담김 목록의 행을 펼치면 나오는 인라인 검토 카드"가 됐다. 이 파일은 카드 HTML 빌더
// (qItemCardHTML — dedup 검토/검색(findOnly)/잡 결과)와 확정 액션(추가·task·스킵·번복·
// 프롬프트 다듬기)만 소유하고, 렌더 위치·전개 상태는 호스트(GoalAddContent)가 관리한다:
//   renderAiQueue(items) → _lastAiQueue 갱신 + window.gaQueueRender() (호스트 훅) 호출
//   queueAdd/queueAddTask/queueSkip 확정 → window.gaQueueResolved(id,info) (호스트 훅)
//   queueUndo 성공 → window.gaQueueUndone(qid) (호스트 훅 — 행을 미확정으로 되돌림)
//   queueClose(검색 카드 닫기) → window.gaQueueClosed(id) (호스트 훅 — 뷰만 접음, 큐에 남음)
// 호스트 페이지가 제공해야 하는 것: $, esc, post, CMTimeFilter, _review/_reviewAt,
// gaQueueRender/gaQueueResolved/gaQueueUndone.
enum QueuePanel {

    static func css() -> String {
        #"""
          /* ===== 큐 검토 카드 (담김 행 펼침 안에 인라인 렌더) ===== */
          .queue-section{ margin-top:2px }
          @keyframes cpd{0%,60%,100%{opacity:.25}30%{opacity:1}}
          .pri-urgent{color:#ff4d4f}
          .pri-high{color:#ff8a4c}
          .pri-medium{color:#e9c46a}
          .pri-low{color:#9aa3ad}
          .pri-lowest{color:#5b6068}
        /* AI 큐(bump out): 실행 상태 표시 + 분석 중 행 강조. */
        .qrun{display:inline-flex;align-items:center;gap:5px;color:var(--green);font-weight:600;font-size:12px}
        .qrun .qdot{width:7px;height:7px;border-radius:50%;background:var(--green);animation:qpulse 1s infinite}
        @keyframes qpulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.35;transform:scale(.7)}}
        .qrow{display:flex;gap:8px;align-items:flex-start;padding:6px 0;border-top:1px solid var(--line);transition:background .2s}
        .qrow.analyzing{background:rgba(64,200,120,0.10);border-radius:6px;padding:6px 8px;border-top-color:transparent}
        .qrow.qconfirm{background:rgba(54,192,138,0.10);border:1px solid #2a5a3c;border-radius:8px;padding:8px 10px;border-top-color:transparent;align-items:center;gap:10px}
        .qspin{display:inline-block;animation:cpd 1.2s infinite}
        /* 검토 대기 항목: 번호를 입력하거나 클릭해 선택하는 옵션 목록. 1번은 (추천), 마지막은 직접 입력. */
        .qchoice{margin-top:8px;display:flex;flex-direction:column;gap:5px}
        .qopt{display:flex;gap:10px;align-items:flex-start;border:1px solid var(--line);border-radius:8px;padding:8px 11px;cursor:pointer;background:#0f131b;transition:border-color .15s,background .15s}
        .qopt:hover{border-color:var(--accent);background:#131a28}
        .qopt.rec{border-color:#2a5a3c;background:rgba(54,192,138,.06)}
        .qopt.rec:hover{border-color:var(--green)}
        .qnum{flex-shrink:0;width:20px;height:20px;border-radius:6px;background:#1d2230;border:1px solid var(--line);color:var(--mut);font-size:12px;font-weight:600;display:flex;align-items:center;justify-content:center;font-variant-numeric:tabular-nums}
        .qopt.rec .qnum{background:#123024;border-color:#2a5a3c;color:var(--green)}
        .qopt-body{flex:1;min-width:0}
        .qopt-label{font-size:13px;font-weight:600;color:var(--fg)}
        .qrec-tag{margin-left:6px;font-size:10px;font-weight:600;color:var(--green);border:1px solid #2a5a3c;border-radius:20px;padding:1px 7px;vertical-align:middle}
        .qopt-desc{font-size:12px;color:var(--mut);margin-top:3px;line-height:1.45}
        .qopt.qother,.qopt.qother:hover{cursor:default;border-color:var(--line);background:#0f131b}
        .qother-input,.qfindn-input,.qfindp-input{width:100%;margin-top:6px;box-sizing:border-box;background:#0d1016;color:var(--fg);border:1px solid var(--accent);border-radius:7px;padding:7px 9px;font:13px/1.4 inherit;outline:none}
        .qhint{font-size:11px;color:var(--mut);margin-top:7px}
        /* AI 배치 제안: 독립/서브 배지 + 우선순위 칩 + 사유. confidence 낮으면 .dim 으로 흐리게. */
        .qplace{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin:5px 0 2px}
        .qbadge{display:inline-flex;align-items:center;gap:4px;font-size:11px;font-weight:600;border-radius:999px;padding:2px 9px;border:1px solid var(--line);background:#1d2230;color:var(--fg);white-space:nowrap;max-width:100%;overflow:hidden;text-overflow:ellipsis}
        .qbadge.top{border-color:#2a5a3c;background:rgba(54,192,138,.08);color:var(--green)}
        .qbadge.sub{border-color:#33406a;background:rgba(91,140,255,.10);color:#9db4ff}
        .qbadge.dim{opacity:.5}
        .qprichip{display:inline-flex;align-items:center;gap:4px;font-size:11px;font-weight:600;border-radius:999px;padding:2px 9px;border:1px solid var(--line);background:#0f131b}
        .qplace .qrationale{width:100%;font-size:12px;color:var(--mut);line-height:1.45;margin-top:1px}
        /* 오버라이드 패널: 배치/우선순위 직접 지정. 기본 닫힘, 링크로 토글. */
        .qovr-toggle{font-size:11px;color:var(--accent);cursor:pointer;text-decoration:none;user-select:none}
        .qovr-toggle:hover{text-decoration:underline}
        .qovr{border:1px dashed #33406a;border-radius:8px;padding:8px 10px;margin-top:6px;background:#101627;display:flex;flex-direction:column;gap:7px}
        .qovr-row{display:flex;flex-wrap:wrap;align-items:center;gap:6px}
        .qovr-lbl{font-size:11px;color:var(--mut);min-width:44px}
        .qovr select,.qovr input.qpin{background:#0d1016;color:var(--fg);border:1px solid var(--line);border-radius:7px;padding:5px 8px;font:12px inherit;outline:none}
        .qovr input.qpin{width:70px;font-variant-numeric:tabular-nums}
        .qovr input.qpin:focus,.qovr select:focus{border-color:var(--accent)}
        /* 큐 탭 dedup 카드의 목적지 라벨 — 인라인 배치(루프 하단) 대신 여기서 행선지를 알린다 */
        .qdest{font-size:11px;color:#8fa0bd;border:1px solid var(--line);border-radius:20px;padding:1px 8px;margin-left:8px;white-space:nowrap;font-weight:400;vertical-align:middle}
        """#
    }

    static func script() -> String {
        #"""
        // ===== 큐 검토 카드 + 확정 액션 (헤더 주석 참고 — 렌더 위치는 호스트 소관) =====
        let _goals=[];   // qdReload가 채운다 — topGoalTitle/오버라이드 부모 후보의 데이터
        const PRI_ORDER=['urgent','high','medium','low','lowest'];
        const PRI_LABEL={urgent:'최고',high:'높음',medium:'보통',low:'낮음',lowest:'최저'};
        function priLabel(p){ return PRI_LABEL[p]||'보통'; }
        // 레벨 화살표 SVG: 최고=이중↑, 높음=↑, 보통=작대기 둘(=), 낮음=↓, 최저=이중↓ (색은 .pri-* 의 currentColor)
        function priSvg(p){
          const a='fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
          let inner;
          if(p==='urgent')      inner='<path d="M2 7L7 3l5 4" '+a+'/><path d="M2 11L7 7l5 4" '+a+'/>';
          else if(p==='high')   inner='<path d="M2 9.5L7 5l5 4.5" '+a+'/>';
          else if(p==='low')    inner='<path d="M2 5.5L7 10l5-4.5" '+a+'/>';
          else if(p==='lowest') inner='<path d="M2 4L7 8l5-4" '+a+'/><path d="M2 8L7 12l5-4" '+a+'/>';
          else                  inner='<path d="M2.5 5h9" '+a+'/><path d="M2.5 9h9" '+a+'/>';
          return '<svg viewBox="0 0 14 14" width="14" height="14" aria-hidden="true">'+inner+'</svg>';
        }
        // --- AI 배치 제안 렌더 헬퍼 -------------------------------------------------
        // 큐 항목의 placement/suggestedParentSeq/priority/confidence/rationale 를 한눈 배지로.
        // 레거시 항목은 placement:'top', suggestedParentSeq:0, priority:'medium', confidence:0 로 디코드되어
        // '독립 태스크' 배지 + 보통 우선순위로 자연스럽게 그려진다.
        // 최상위 목표 #seq → 제목 조회 (parent picker 및 서브 배지에 쓴다). 없으면 ''.
        function topGoalTitle(seq){ const g=(_goals||[]).find(x=>!x.parent && (x.seq||0)===seq); return g?(g.text||''):''; }
        // 우선순위 칩(색상은 .pri-* currentColor 재사용) — 화살표 아이콘 + 한국어 라벨.
        function qPriChip(pri){ const p=pri||'medium';
        return '<span class="qprichip pri-'+p+'" title="AI 추천 우선순위">'+priSvg(p)+priLabel(p)+'</span>'; }
        // 배치 배지: top=독립 태스크(초록), sub=서브 → #seq 제목(파랑). confidence<0.5 면 흐리게(.dim).
        function qPlaceBadge(it){
        const place=it.placement||'top';
        const dim=((it.confidence!=null?it.confidence:0)<0.5)?' dim':'';
        if(place==='sub' && (it.suggestedParentSeq||0)>0){
            const pn=it.suggestedParentSeq, t=topGoalTitle(pn);
            const ttl=t?(' '+esc(t)):'';
            return '<span class="qbadge sub'+dim+'" title="AI 제안: #'+pn+' 아래 서브로">서브 → #'+pn+ttl+'</span>';
        }
        return '<span class="qbadge top'+dim+'" title="AI 제안: 독립(최상위) 태스크로">독립 태스크</span>';
        }
        // 배지줄: 배치 배지 + 우선순위 칩 + 사유 한 줄. verdict 카드 상단에 깐다.
        function qPlacementLine(it){
        const rat=it.rationale?('<div class="qrationale">'+esc(it.rationale)+'</div>'):'';
        return '<div class="qplace">'+qPlaceBadge(it)+qPriChip(it.priority||'medium')+rat+'</div>';
        }
        // 오버라이드 패널 HTML: 배치(독립/서브 #부모) + 우선순위 직접 지정. '적용' → queueOverrideApply.
        // 최상위 목표만 부모 후보(1-level 규칙) — select 로 고르거나 #번호 직접 입력. 백엔드도 규칙을 강제하므로
        // parentFallback 이 최종 안전망이다.
        function qOverrideHTML(it){
        const tops=(_goals||[]).filter(g=>!g.parent && (g.seq||0)>0).sort((a,b)=>(a.seq||0)-(b.seq||0));
        const curParent=(it.placement==='sub'?(it.suggestedParentSeq||0):0);
        const parentOpts=['<option value="0"'+(curParent===0?' selected':'')+'>독립 (최상위)</option>']
            .concat(tops.map(g=>'<option value="'+g.seq+'"'+(curParent===(g.seq||0)?' selected':'')+'>#'+g.seq+' '+esc(g.text||'')+'</option>')).join('');
        const curPri=it.priority||'medium';
        const priOpts=PRI_ORDER.map(p=>'<option value="'+p+'"'+(p===curPri?' selected':'')+'>'+priLabel(p)+'</option>').join('');
        return '<div class="qovr" id="qovr_'+it.id+'" style="display:none">'
            +'<div class="qovr-row"><span class="qovr-lbl">배치</span>'
              +'<select id="qovrp_'+it.id+'" onchange="qOvrPickParent(\''+it.id+'\')">'+parentOpts+'</select>'
              +'<input class="qpin" id="qovrn_'+it.id+'" type="text" inputmode="numeric" placeholder="#부모" '
        +'value="'+(curParent>0?curParent:'')+'" title="최상위 목표 번호 직접 입력 (0/빈칸=독립)" '
        +'oninput="qOvrSyncSelect(\''+it.id+'\')" onclick="event.stopPropagation()"></div>'
            +'<div class="qovr-row"><span class="qovr-lbl">우선순위</span>'
              +'<select id="qovrpri_'+it.id+'">'+priOpts+'</select></div>'
            +'<div class="qovr-row"><button class="btn primary" onclick="queueOverrideApply(\''+it.id+'\')">이 설정으로 승격</button>'
              +'<button class="btn" onclick="qOverrideToggle(\''+it.id+'\')">취소</button></div></div>';
        }
        // --- 큐 항목 검토 카드 (단독 렌더): 담김 목록의 행을 펼치면 이 카드가 인라인으로
        // 나온다. dedup 검토(추천 옵션·배치 배지·오버라이드·프롬프트), 검색(findOnly)의
        // 다음 액션 흐름 모두 이 하나로 그린다. 렌더 위치는 호스트가 정한다. ---
        function qItemCardHTML(it){
            const rdy=(!it.status||it.status==='ready');
            // 검색(찾기만) 카드: AI목표와 같은 dedup 분석을 돌리되 결과는 비슷한 기존 목표만 보여준다.
            // 분석 중/대기면 진행 상태를, 완료면 찾은 목표를 이유와 함께 나열하고, 액션은 '닫기'뿐(생성 없음).
            if(it.findOnly){
              const q='<span id="qt_'+it.id+'">🔍 '+esc(it.text)+'</span>';
              // 닫기 = 뷰만 접는다(항목은 큐에 남음). 버리기(스킵)는 목록의 '그만두기' 행 —
              // 둘을 섞지 않는다(닫았다가 나중에 다시 펼쳐 이어서 처리할 수 있다).
              const closeBtn='<button class="btn" onclick="queueClose(\''+it.id+'\')" title="접어두기 — 항목은 큐에 남습니다">닫기</button>';
              if(it.status==='analyzing'){
        return '<div class="qrow analyzing"><div style="flex:1;min-width:0">'+q
          +'<div style="font-size:12px;color:var(--green)"><span class="qspin">🔄</span> 비슷한 목표 찾는 중…</div></div></div>';
              }
              if(!rdy){
        return '<div class="qrow"><div style="flex:1;min-width:0">'+q
          +'<div class="muted" style="font-size:12px">⏳ 대기 중 — 곧 분석이 시작됩니다</div></div>'
          +'<div style="display:flex;gap:4px;flex-shrink:0">'
          +'<button class="btn" onclick="queueSkip(\''+it.id+'\')" title="검색을 버립니다">스킵</button>'+closeBtn+'</div></div>';
              }
              const hits=(it.matches||[]).filter(m=>(m.seq||0)>0);
              const cnt=hits.length?('비슷한 목표 '+hits.length+'건'):'결과 없음';
              const note=it.note?'<div class="muted" style="font-size:12px;margin-top:2px">'+esc(it.note)+'</div>':'';
              const head='<div style="display:flex;align-items:flex-start;gap:8px">'
        +'<div style="flex:1;min-width:0">'+q+'<div class="muted" style="font-size:12px">'+cnt+'</div>'+note+'</div>'
        +'<div style="flex-shrink:0">'+closeBtn+'</div></div>';
              let body;
              const sel=_qFind[it.id];
              if(hits.length && sel && sel.parentSeq>0){
        // 번호를 고른 뒤: 그 목표를 대상으로 다음 액션(끝내기·task 추가·그만두기)을 판단·추천.
        body=qFindActionHTML(it,hits,sel);
              } else {
        // 매치 목록(또는 결과 없음): 번호를 누르면 그 목표를 대상으로 '다음 액션'을 고른다(바로
        // 이동이 아님). 매치가 답이 아닐 때의 출구를 목록 안에 항상 둔다 — 잘못 잡힌 검색
        // (인사말 등)은 '그만두기' 행 하나로 버리고, 목록에 없는 목표는 #번호를 직접 치고,
        // 검색 자체가 빗나갔으면 마지막 행에 지시문을 쳐서 다시 찾는다(재검색). 결과 없음일
        // 때도 같은 꼬리 행들이 남아 막다른 길이 없다.
        let n=0;
        const list=hits.map(function(m){ const s=m.seq; n++;
          const why=m.why?'<div class="qopt-desc">'+esc(m.why)+'</div>':'';
          return '<div class="qopt" data-n="'+n+'" data-action="pick" data-arg="'+s+'" onclick="queueFindPick(\''+it.id+'\','+s+')" style="cursor:pointer">'
            +'<div class="qnum">'+n+'</div>'
            +'<div class="qopt-body"><div class="qopt-label"><a href="/goal?n='+s+'" onclick="event.stopPropagation()" style="color:var(--accent);text-decoration:none">#'+s+'</a> '+esc(m.text||'')+'</div>'+why+'</div></div>';
        }).join('');
        n++;
        const skipRow='<div class="qopt" data-n="'+n+'" data-action="skip" onclick="queueSkip(\''+it.id+'\')" style="cursor:pointer">'
          +'<div class="qnum">'+n+'</div>'
          +'<div class="qopt-body"><div class="qopt-label">그만두기 (스킵)</div>'
          +'<div class="qopt-desc">아무것도 하지 않고 이 검색 결과를 버립니다.</div></div></div>';
        n++;
        const mv=(_qFindNum[it.id]||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        const manualRow='<div class="qopt qother" data-n="'+n+'" data-action="findnum">'
          +'<div class="qnum">'+n+'</div>'
          +'<div class="qopt-body"><div class="qopt-label">다른 목표 번호 직접 입력</div>'
          +'<input id="qfindn_'+it.id+'" data-qid="'+it.id+'" class="qfindn-input" value="'+mv+'" inputmode="numeric" '
          +'placeholder="#번호 — Enter로 그 목표를 대상으로 진행" '
          +'oninput="_qFindNum[\''+it.id+'\']=this.value;qDraftSave()" onclick="event.stopPropagation()" '
          +'onkeydown="if(event.key===\'Enter\'){event.preventDefault();queueFindManual(\''+it.id+'\');}"></div></div>';
        n++;
        const pv=(_qFindPrompt[it.id]||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        const promptRow='<div class="qopt qother" data-n="'+n+'" data-action="findprompt">'
          +'<div class="qnum">'+n+'</div>'
          +'<div class="qopt-body"><div class="qopt-label">기타 (직접 지시 — 다시 검색)</div>'
          +'<input id="qfindp_'+it.id+'" data-qid="'+it.id+'" class="qfindp-input" value="'+pv+'" '
          +'placeholder="예: 인사말 말고 MPC 시즌 정리 쪽으로 다시 찾아줘 — Enter 재검색" '
          +'oninput="_qFindPrompt[\''+it.id+'\']=this.value;qDraftSave()" onclick="event.stopPropagation()"></div></div>';
        const hint=hits.length
          ?'번호를 누르면 다음 액션(끝내기 · task 추가 · 그만두기)을 고릅니다'
          :'비슷한 기존 목표를 찾지 못했습니다 — 번호를 직접 치거나 지시문으로 다시 찾을 수 있습니다';
        body='<div class="qhint" style="margin:6px 0 2px">'+hint+'</div>'
          +'<div class="qchoice" data-qid="'+it.id+'">'+list+skipRow+manualRow+promptRow+'</div>';
              }
              return '<div class="qrow" style="flex-direction:column;align-items:stretch">'+head
        +'<div style="margin-top:6px">'+body+'</div></div>';
            }
            // 매치의 번호(#seq)는 클릭하면 골 페이지(/goal?n=NN)로 이동해 그 목표 내용을 확인한다.
            // why가 있으면 링크 title(툴팁)로 붙인다. stopPropagation으로 행/버튼 핸들러와 충돌 방지.
            const ms=(it.matches||[]).map(m=>{
              const n=m.seq||0;
              const tip=m.why?' title='+JSON.stringify(String(m.why)):'';
              const num=n>0
        ? '<a href="/goal?n='+n+'"'+tip+' onclick="event.stopPropagation()" style="color:var(--accent);text-decoration:none;font-variant-numeric:tabular-nums">#'+n+'</a>'
        : '#'+n;
              return num+' '+esc(m.text||'');
            }).join(', ');
            let meta='', cls='qrow', choice='';
            if(it.status==='analyzing'){
              cls='qrow analyzing';
              meta='<div style="font-size:12px;color:var(--green)"><span class="qspin">🔄</span> AI 분석 중…</div>';
            } else if(!rdy){
              meta='<div class="muted" style="font-size:12px">⏳ 대기 중 — 곧 분석이 시작됩니다</div>';
            } else {
              const tag=it.duplicate
        ? '<span style="color:#e0a458">유사 목표 있음</span>'
        : '<span style="color:var(--green)">새 목표</span>';
              const sess=it.refining?'<span style="color:#9db4ff"> · 🔗 세션 이어감</span>':'';
              meta='<div class="muted" style="font-size:12px">'+tag+(it.note?' · '+esc(it.note):'')+sess+'</div>'
        +(ms?'<div class="muted" style="font-size:12px">유사: '+ms+'</div>':'');
            }
            // 프롬프트 다듬기 패널: 이 항목이 활성일 때만 (입력 or 생성 중).
            const uiOn=(_qUI&&_qUI.id===it.id);
            let panel='';
            if(uiOn && _qUI.mode==='gen'){
              panel='<div style="border:1px dashed #33406a;border-radius:8px;padding:8px 10px;margin-top:6px;background:#101627">'
        +'<span style="color:var(--green);font-size:13px"><span class="qspin">🔄</span> 새 결과 생성 중…</span></div>';
            } else if(uiOn){
              panel='<div style="border:1px dashed #33406a;border-radius:8px;padding:8px 10px;margin-top:6px;background:#101627">'
        +'<div style="font-size:11px;color:#9db4ff;margin-bottom:5px">'+(it.refining?'프롬프트 — 이 세션을 이어서 더 낫게 (지시를 계속 쌓으세요)':'프롬프트 — 이 세션에서 목표를 다듬습니다')+'</div>'
        +'<textarea id="qp_'+it.id+'" oninput="if(_qUI)_qUI.prompt=this.value" placeholder="예: 목표 문구를 &#39;스크립트화&#39;로 바꾸고 매일 자동 발송까지 포함해줘" '
        +'style="width:100%;background:#0f131b;color:var(--fg);border:1px solid var(--accent);border-radius:8px;padding:8px 10px;font:13px/1.5 inherit;outline:none;resize:vertical;min-height:52px">'+esc(_qUI.prompt||'')+'</textarea>'
        +'<div style="display:flex;gap:6px;margin-top:6px"><button class="btn" onclick="queuePromptGen(\''+it.id+'\')">생성</button>'
        +'<button class="btn" onclick="queuePromptCancel()">취소</button></div></div>';
            }
            // 우측 버튼: 상태별. 프롬프트 패널이 열려 있으면 액션은 패널이 가진다.
            let btns;
            if(!rdy){
              btns='<button class="btn" onclick="queueAdd(\''+it.id+'\')" title="분석을 기다리지 않고 바로 추가">바로 추가</button>'
        +'<button class="btn" onclick="queueSkip(\''+it.id+'\')" title="버리기">스킵</button>';
            } else if(uiOn){
              btns='';
            } else if(_qJustRefined===it.id){
              // 방금 프롬프트로 다듬어진 새 결과 — 맞으면 진행, 아니면 다시 프롬프트.
              btns='<button class="btn primary" onclick="queueProceed(\''+it.id+'\')" title="이 결과로 목표를 추가">이 결과로 진행</button>'
        +'<button class="btn" onclick="queuePromptStart(\''+it.id+'\')" title="아직 아니면 다시 프롬프트">다시 프롬프트</button>'
        +'<button class="btn" onclick="queueSkip(\''+it.id+'\')" title="버리기">스킵</button>';
            } else {
              // 검토 대기: 우측 버튼 대신 번호 선택 UI(추천 1번 + 대안 + 기타 직접입력)로 렌더.
              btns='';
              // 1번은 (추천): kind에 따라 다르다 — 반복이면 '부모 아래 추가', 새 목표면 '추가', 진짜 중복이면 '스킵'.
              const seqs=(it.matches||[]).filter(m=>m.seq>0).map(m=>'#'+m.seq);
              const note=it.note?esc(it.note):'';
              const m0=(it.matches||[]).find(function(m){return m.seq>0;});   // 반복/중복이 매달릴 부모 목표
              const pN=m0?m0.seq:0, pTitle=m0?esc(m0.text||''):'';
              const kind=it.kind||(it.duplicate?'duplicate':'new');
              let opts;
              if(kind==='recurring' && pN>0){
        // 관계에 따라 추천 액션이 다르다(DASH-9):
        //   relation==='recurring-execution' → 그 목표의 task(부분과제)로 이번 회차 추가.
        //   relation==='sub-problem'/'improvement' → 그 목표 아래 '서브 목표'로 추가(별개 하위 문제).
        // 백엔드 rationale(관리형 다음 단계 제안)이 있으면 추천 옵션 설명으로 그대로 노출한다.
        const relAct=({'recurring-execution':'task','sub-problem':'under','improvement':'under'})[it.relation]||'task';
        const backWhy=it.rationale?esc(it.rationale):'';
        const taskWhy=backWhy||((note?note+' ':'')+'#'+pN+' '+pTitle+'의 반복 작업이라, 새 목표 번호 없이 그 목표의 task로 추가하는 것을 추천합니다.');
        const underWhy=backWhy||('#'+pN+' '+pTitle+'와 같은 계열의 하위 문제라, 그 목표 아래 서브 목표로 추가하는 것을 추천합니다.');
        opts=[{a:'task',arg:pN,label:'#'+pN+'의 task로 이번 회차 추가',rec:(relAct==='task'),desc:(relAct==='task'?taskWhy:'기존 목표의 또 다른 회차로, 그 목표의 task(부분과제) 폴더에 붙입니다.')},
              {a:'under',arg:pN,label:'#'+pN+' 아래 서브 목표로 추가',rec:(relAct==='under'),desc:(relAct==='under'?underWhy:'새 번호를 받는 별도 목표를 만들어 #'+pN+' 아래에 둡니다.')},
              {a:'add',label:'별도 새 목표로 추가',desc:'#'+pN+'와 무관하게 최상위 목표로 추가합니다.'},
              {a:'skip',label:'스킵',desc:'이번 회차는 추적하지 않고 버립니다.'}];
        // 추천(rec) 옵션을 1번으로: "1번=추천" 넘버링 규칙을 지킨다.
        const ri=opts.findIndex(o=>o.rec); if(ri>0){ opts.unshift(opts.splice(ri,1)[0]); }
              } else if(kind==='duplicate'){
        // 진짜 중복: 같은 목표가 이미 있어 새로 추가할 실익이 없음 → 스킵 추천.
        const why=(seqs.length?'유사 목표 '+seqs.join(', ')+'가 이미 같은 목표를 담고 있습니다. ':'')+(note?note+' ':'')+'새로 추가해도 얻는 게 없어 스킵을 추천합니다.';
        opts=[{a:'skip',label:'스킵',rec:true,desc:why}];
        if(pN>0) opts.push({a:'under',arg:pN,label:'#'+pN+' 아래에 추가',desc:'그래도 별도 실행으로 남기려면 그 목표 아래에 넣습니다.'});
        opts.push({a:'add',label:'별도 목표로 추가',desc:'그래도 독립 목표로 추가합니다.'});
              } else {
        // 새 목표: AI 배치 제안(placement)을 그대로 수용해 한 번에 승격하는 것을 추천.
        // placement==='sub' 면 '#부모 아래 서브로', 'top' 이면 '독립 태스크로'. 어느 쪽이든 1번(승격)은
        // parentSeq/priority override 없이 add 만 보내 백엔드가 AI 제안을 적용하게 한다.
        const isSub=(it.placement==='sub' && (it.suggestedParentSeq||0)>0);
        const pn=it.suggestedParentSeq||0, pt=isSub?topGoalTitle(pn):'';
        const rat=it.rationale?(esc(it.rationale)):(note||'기존 목표와 겹치지 않는 새 목표라 추가를 추천합니다.');
        const primLabel=isSub?('승격 — 서브 → #'+pn+(pt?' '+esc(pt):'')):'승격 — 독립 태스크';
        opts=[{a:'add',label:primLabel,rec:true,desc:'AI 제안('+(isSub?('#'+pn+' 아래 · '):'독립 · ')+priLabel(it.priority||'medium')+' 우선순위)대로 한 번에 추가합니다. '+rat},
              {a:'override',label:'배치·우선순위 바꾸기',desc:'AI 제안 대신 부모(독립/서브)와 우선순위를 직접 정해 승격합니다.'},
              {a:'prompt',label:'프롬프트 열기',desc:'이미지 지원 AI 챗으로 이 항목을 직접 다듬습니다.'},
              {a:'skip',label:'스킵',desc:'이 제안을 버립니다.'}];
              }
              let n=0;
              const rows=opts.map(function(o){ n++;
        const argAttr=(o.arg!=null?' data-arg="'+o.arg+'"':'');
        const call=(o.arg!=null?'queueChoose(\''+it.id+'\',\''+o.a+'\','+o.arg+')':'queueChoose(\''+it.id+'\',\''+o.a+'\')');
        return '<div class="qopt'+(o.rec?' rec':'')+'" data-n="'+n+'" data-action="'+o.a+'"'+argAttr+' onclick="'+call+'">'
          +'<div class="qnum">'+n+'</div>'
          +'<div class="qopt-body"><div class="qopt-label">'+o.label+(o.rec?'<span class="qrec-tag">추천</span>':'')+'</div>'
          +'<div class="qopt-desc">'+o.desc+'</div></div></div>';
              }).join(''); n++;
              // 마지막 번호: 직접 입력(기타). 짧은 지시를 넣고 Enter를 누르면 그 문구로 즉시 다듬는다.
              // 보관해 둔 입력값을 value로 되살린다(속성 안전 이스케이프 — esc()는 따옴표 미처리+빈값을 '-'로 바꿔 부적합).
              const ov=(_qOther[it.id]||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
              const other='<div class="qopt qother" data-n="'+n+'" data-action="other">'
        +'<div class="qnum">'+n+'</div>'
        +'<div class="qopt-body"><div class="qopt-label">기타 (직접 지시)</div>'
        +'<input id="qother_'+it.id+'" data-qid="'+it.id+'" class="qother-input" value="'+ov+'" placeholder="예: 문구를 &#39;스크립트화&#39;로 바꾸고 자동 발송까지 포함해줘 — Enter 제출" '
        +'oninput="_qOther[\''+it.id+'\']=this.value;qDraftSave()" onclick="event.stopPropagation()"></div></div>';
              const tip='항목을 클릭해 확정하세요 — 검토 카드가 하나뿐이면 숫자키(1–N)로도 선택됩니다';
              const links=(ms?'유사: '+ms+' · ':'')+tip;
              // 새 목표 카드에는 AI 배치 제안 배지줄(placement/priority/rationale) + 오버라이드 패널을 얹는다.
              // 반복/중복 카드는 이미 부모(#seq) 컨텍스트가 옵션에 녹아 있어 배지줄을 생략한다.
              const placeLine=(kind!=='recurring' && kind!=='duplicate')?qPlacementLine(it):'';
              const ovr=(kind!=='recurring' && kind!=='duplicate')?qOverrideHTML(it):'';
              choice=placeLine+'<div class="qchoice" data-qid="'+it.id+'">'+rows+other+'</div>'+ovr+'<div class="qhint">'+links+'</div>';
              meta='';   // 기존 태그/노트/유사 줄은 추천 사유로 접어 넣었으므로 비운다
            }
            const newBadge=(_qJustRefined===it.id)
              ? '<span style="font-size:11px;padding:1px 7px;border-radius:20px;background:#0f2a1e;color:var(--green);border:1px solid #1e4a35;margin-right:6px">새 결과</span>' : '';
            // 목적지 라벨: 루프로 담긴 항목은 확정 시 어디로 들어가는지 표시 (인라인 배치 제거의 정보 보존).
            const dest=(it.sprint||0)>0?(function(){
              const s=((_review&&_review.sprints)||[]).find(x=>x.number===it.sprint);
              return '<span class="qdest">→ '+esc((s&&s.code)||('#'+it.sprint))+'</span>'; })():'';
            return '<div class="'+cls+'">'
              +'<div style="flex:1;min-width:0">'+newBadge+'<span id="qt_'+it.id+'">'+esc(it.text)+'</span>'+dest+meta+panel+choice+'</div>'
              +'<div style="display:flex;gap:4px;flex-shrink:0;align-items:flex-start">'+btns+'</div></div>';
        }
        // === 큐 프롬프트 다듬기 상태 ===
        // _qUI: 프롬프트 입력/생성 중 패널 상태 {id, mode:'prompt'|'gen', prompt}
        // _qJustRefined: 방금 프롬프트로 다듬어진 항목 id — '새 결과'로 강조하고 진행/다시 프롬프트를 띄운다.
        let _qUI=null, _qJustRefined='', _lastAiQueue=[];
        // _qOther: 기타(직접 지시) 입력칸에 친 값을 항목 id별로 보관 → 5초 폴링 재렌더가 innerHTML을
        // 갈아끼워도 value로 다시 그려 넣어 입력이 사라지지 않게 한다(프롬프트 textarea의 _qUI.prompt와 동일 취지).
        let _qOther={};
        // _qFindNum/_qFindPrompt: 검색(findOnly) 카드의 '#번호 직접 입력'/'기타(직접 지시)' 값
        // 보관 — _qOther와 같은 취지(5초 폴링 재렌더가 innerHTML을 갈아끼워도 value로 되살린다).
        let _qFindNum={},_qFindPrompt={};
        // 세 입력값은 localStorage(cm.qDrafts)에도 남긴다 — 페이지를 떠났다가 돌아와도(다른 탭/목표
        // 페이지 왕복) 치던 지시문이 그대로 있어야 한다. 제출/스킵 시에는 delete 후 저장해 비운다.
        function qDraftSave(){ try{ localStorage.setItem('cm.qDrafts',
            JSON.stringify({other:_qOther,findNum:_qFindNum,findPrompt:_qFindPrompt})); }catch(e){} }
        (function(){ try{ const raw=localStorage.getItem('cm.qDrafts'); if(!raw) return;
            const d=JSON.parse(raw)||{};
            _qOther=d.other||{}; _qFindNum=d.findNum||{}; _qFindPrompt=d.findPrompt||{}; }catch(e){} })();
        // 사라진 큐 항목의 초안은 남겨둘 이유가 없다 — 현재 큐에 없는 id는 정리한다.
        function qDraftPrune(items){
            const live={}; (items||[]).forEach(function(it){ live[it.id]=1; });
            let dirty=false;
            [_qOther,_qFindNum,_qFindPrompt].forEach(function(m){
              Object.keys(m).forEach(function(k){ if(!live[k]){ delete m[k]; dirty=true; } }); });
            if(dirty) qDraftSave(); }
        // _qFind: 검색(findOnly) 카드에서 '번호를 눌러 대상 목표를 고른 뒤 → 다음 액션(끝내기·task 추가·
        // 그만두기)' 흐름의 항목별 상태. id → {parentSeq, phase:'menu'|'suggesting'|'edit', name}.
        // phase 'edit'의 name(추천 task 폴더명)은 폴링 재렌더에도 유지되도록 여기 보관한다.
        let _qFind={};
        // 유일한 렌더 경로: 스냅샷을 보관하고 호스트(GoalAddContent)의 gaQueueRender 훅을 부른다.
        // 호스트가 펼쳐진 행의 카드(qItemCardHTML)·잡 결과·큐 히스토리를 자기 위치에 그린다.
        // 재렌더 전에 기타/검색 입력칸의 포커스·캐럿을 기억해 폴링 재렌더에도 타이핑이 안 끊긴다.
        function renderAiQueue(items){ _lastAiQueue=items||[]; qDraftPrune(_lastAiQueue);
        const af=document.activeElement;
        // 카드 안 입력칸(기타/task 이름/#번호/재검색 지시)은 모두 data-qid + 고유 id 를 가진다 —
        // 어느 것이든 id 로 포커스·캐럿을 복원한다(값은 각자 _qOther/_qFind/_qFindNum/_qFindPrompt 보관).
        const qo=(af&&af.id&&af.getAttribute&&af.getAttribute('data-qid'))?{eid:af.id,pos:af.selectionStart}:null;
        if(window.gaQueueRender) gaQueueRender();
        // 프롬프트 입력 중이면 재렌더 후 텍스트박스에 포커스를 되돌린다(캐럿 끝으로).
        if(_qUI&&_qUI.mode==='prompt'){ const t=$('qp_'+_qUI.id); if(t){ t.focus(); try{ t.setSelectionRange(t.value.length,t.value.length); }catch(e){} } }
        if(qo){ const t=$(qo.eid); if(t){ t.focus(); try{ const p=(qo.pos==null?t.value.length:qo.pos); t.setSelectionRange(p,p); }catch(e){} } } }
        // === 큐 처리 히스토리 (감사 + 번복) ===
        // _qHist: /data.json review.queueHistory (newest first, 최근 30건). 각 항목은 하나의 확정된
        // 결정 — 무엇을 골랐고 무엇이 생겼는지(#seq/task 폴더) 남아, 5초 확인 카드가 사라진 뒤에도
        // "제대로 됐는지" 확인하고, 클릭해 이동하고, 번복(undo)할 수 있다.
        let _qHist=[];
        // _qHistMsg: 마지막 번복 실패 사유(항목 id → 문구) — 행 안에 인라인으로 보여준다.
        let _qHistMsg={};
        function queueHistWhen(ts){ const p=CMTimeFilter.parts((ts||0)*1000), n=CMTimeFilter.parts(new Date());
            const hm=('0'+p.h).slice(-2)+':'+('0'+p.mi).slice(-2);
            const sameDay=(p.y===n.y&&p.mo===n.mo&&p.d===n.d);
            return sameDay?hm:(p.mo+'/'+p.d+' '+hm); }
        // 처리 히스토리 한 행 — 호스트의 큐 히스토리 섹션이 행 단위로 가져다 그린다.
        function queueHistRowHTML(h){
            // 결정 요약: 액션별로 "무엇이 생겼는지"를 링크로. #seq 클릭 → 그 목표 페이지.
            let what;
            if(h.action==='add'){
              const link='<a href="/goal?n='+h.seq+'" style="color:var(--accent);text-decoration:none">#'+h.seq+'</a>';
              const parent=(h.parentSeq>0)?(' <span class="muted">(#'+h.parentSeq+' 아래)</span>'):'';
              const fb=h.fallback?' <span style="color:#e0a458">· 서브 부착 불가 → 최상위</span>':'';
              what='<span style="color:var(--green)">추가</span> → '+link+parent+fb;
            } else if(h.action==='task'){
              const link='<a href="/goal?n='+h.seq+'" style="color:var(--accent);text-decoration:none">#'+h.seq+'</a>';
              what='<span style="color:var(--green)">task 추가</span> → '+link+' <span class="muted">· '+esc(h.task||'')+'</span>';
            } else if(h.action==='edit'){
              what='<span class="muted">수정 (계속 대기)</span>';
            } else {
              what='<span class="muted">스킵</span>';
            }
            // 번복: add/task/skip만. 이미 번복됐으면 흐리게 + '번복됨' 배지.
            const undoable=!h.undone && (h.action==='add'||h.action==='task'||h.action==='skip');
            const btn=undoable
              ? '<button class="btn" onclick="queueUndo(\''+h.id+'\')" title="이 결정을 되돌리고 항목을 큐로 복원">번복</button>'
              : (h.undone?'<span class="muted" style="font-size:12px">번복됨</span>':'');
            const msg=_qHistMsg[h.id]?('<div class="qhint" style="color:#e0a458">'+esc(_qHistMsg[h.id])+'</div>'):'';
            return '<div class="qrow" style="align-items:flex-start'+(h.undone?';opacity:.5':'')+'">'
              +'<div style="flex:1;min-width:0">'
              +'<div style="font-size:13px"><span class="muted" style="font-variant-numeric:tabular-nums;margin-right:8px">'+queueHistWhen(h.at)+'</span>'
              +what+' · '+esc(h.text||'')+'</div>'+msg+'</div>'
              +'<div style="flex-shrink:0">'+btn+'</div></div>';
        }
        // 번복 실행: 성공하면 결과물(goal/task 폴더)이 제거되고 항목이 큐로 복원된다. 실패 사유는
        // 행 안에 인라인으로 보여준다 (예: 만든 목표에 하위 목표가 생겨 되돌릴 수 없음).
        // 성공 시 호스트 훅(gaQueueUndone)으로 담김 행을 미확정 상태로 되돌려 폴링이 이어진다.
        function queueUndo(hid){
        delete _qHistMsg[hid];
        const h=(_qHist||[]).find(x=>x.id===hid);
        fetch('/api/goal/queue/undo',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:hid})})
            .then(r=>r.json()).then(res=>{
              if(!(res&&res.ok)){
        _qHistMsg[hid]=(res&&res.error==='has-children')
          ?'만든 목표 아래에 하위 목표가 생겨 번복할 수 없습니다. 목표를 직접 정리해주세요.'
          :'번복하지 못했습니다 (이미 처리됐거나 항목을 찾을 수 없음).';
        rerenderAiQueue();
              } else if(h&&h.qid&&window.gaQueueUndone){ gaQueueUndone(h.qid); }
              qdReload();
            }).catch(()=>qdReload());
        }
        // 비-dedup 잡(linkmap/report…) 카드 하나. 상태 배지 + 결과(resultHTML) 보기/다운로드, 또는 오류+재시도/닫기.
        function queueJobCardHTML(it){
        const title=esc(it.title||it.text||'(작업)');
        const st=it.status||'ready';
        const badge=st==='analyzing'
            ? '<span class="qrun"><span class="qdot"></span>실행 중</span>'
            : (st==='pending'
        ? '<span class="muted" style="font-size:12px">대기</span>'
        : (it.error?'<span style="color:#e0a458;font-size:12px">오류</span>':'<span style="color:var(--green);font-size:12px">완료</span>'));
        let body='';
        if(st==='ready' && it.error){
            body='<div class="muted" style="font-size:12px;color:#e0a458;margin-top:4px">'+esc(it.error)+'</div>'
              +'<div style="display:flex;gap:6px;margin-top:6px">'
              +'<button class="btn" onclick="queueRetry(\''+it.id+'\')">재시도</button>'
              +'<button class="btn" onclick="queueRemove(\''+it.id+'\')">닫기</button></div>';
        } else if(st==='ready' && it.resultHTML){
            // linkmap 잡: 노드-링크 지도 + 요약 + 압축 내보내기를 카드에 인라인으로 펼쳐 보여준다.
            // (resultHTML은 서버가 만든 자기완결 HTML 조각 — /data.json aiQueue로 전달됨.)
            const inline=(it.jobKind==='linkmap')
              ? '<div style="margin-top:8px;padding:12px;background:#101420;border:1px solid #222838;border-radius:10px;overflow-x:auto">'+it.resultHTML+'</div>'
              : '';
            body=inline+'<div style="display:flex;gap:6px;margin-top:6px">'
              +'<button class="btn primary" onclick="queueView(\''+it.id+'\')">보기</button>'
              +'<button class="btn" onclick="queueDownload(\''+it.id+'\')">다운로드</button>'
              +'<button class="btn" onclick="queueRemove(\''+it.id+'\')">닫기</button></div>';
        } else if(st==='ready'){
            body='<div class="muted" style="font-size:12px;margin-top:4px">결과가 비어 있습니다.</div>'
              +'<div style="display:flex;gap:6px;margin-top:6px">'
              +'<button class="btn" onclick="queueRetry(\''+it.id+'\')">재시도</button>'
              +'<button class="btn" onclick="queueRemove(\''+it.id+'\')">닫기</button></div>';
        }
        return '<div class="qrow" style="align-items:flex-start"><div style="flex:1;min-width:0">'
            +'<div style="font-size:13px">'+title+' <span style="margin-left:6px">'+badge+'</span></div>'
            +body+'</div></div>';
        }
        // 잡 결과 카드 액션.
        function queueRetry(id){ post('/api/queue/retry',{id:id}).then(()=>qdReload()); }
        function queueRemove(id){ post('/api/queue/remove',{id:id}).then(()=>qdReload()); }
        function queueView(id){ const it=(_lastAiQueue||[]).find(x=>x.id===id); if(!it||!it.resultHTML) return;
        const w=window.open('','_blank'); if(w){ w.document.write(it.resultHTML); w.document.close(); } }
        function queueDownload(id){ const it=(_lastAiQueue||[]).find(x=>x.id===id); if(!it||!it.resultHTML) return;
        const blob=new Blob([it.resultHTML],{type:'text/html'});
        const a=document.createElement('a'); a.href=URL.createObjectURL(blob);
        a.download=((it.title||it.text||'result').replace(/[^\w가-힣.-]+/g,'_'))+'.html';
        document.body.appendChild(a); a.click(); document.body.removeChild(a); setTimeout(()=>URL.revokeObjectURL(a.href),1000); }
        // (exportLinkmap 은 대시보드 진입점이라 DashboardContent 에 남는다 — enqueue 후
        //  /goal-add?q=detail 로 이동해 이 패널의 잡 카드에서 결과를 본다.)
        // 큐 박스는 큐 탭에만 렌더된다(인라인 배치 제거). 프롬프트 열기/취소 같은 즉시 상태 변화는
        // 5초 폴링을 기다리지 않고 바로 다시 그린다. 재렌더 후 입력 중이면 텍스트박스 포커스를 복원한다.
        function rerenderAiQueue(){
        renderAiQueue(_lastAiQueue);
        if(_qUI&&_qUI.mode==='prompt'){ const t=$('qp_'+_qUI.id); if(t){ t.focus(); try{ t.setSelectionRange(t.value.length,t.value.length); }catch(e){} } }
        }
        // 추가(1번/바로추가/이 결과로 진행): fire-and-forget이 아니라 응답의 새 #seq를 받아 호스트
        // 훅(gaQueueResolved)으로 담김 행을 즉시 '추가됨 #NN'으로 바꾼다. parentSeq가 있으면 그
        // 목표 아래(반복 회차)로 들어간다.
        // 승격(add): opts로 AI 제안을 덮어쓸 수 있다.
        //  - parentSeq: 숫자면 그 값(0=명시적 최상위)을 override로 보낸다. 생략(undefined)이면 AI 제안(suggestedParentSeq) 수용.
        //  - priority: 있으면 override로 보낸다. 생략이면 AI 제안 우선순위 수용.
        // 옛 시그니처 queueAdd(id, parentSeq) 는 두 번째 인자를 parentSeq override로 그대로 받는다.
        function queueAdd(id,parentSeq,priority){
        _qJustRefined='';
        const it=((_review&&_review.aiQueue)||_lastAiQueue||[]).find(x=>x.id===id);
        const label=it?it.text:'';
        const body={id:id,action:'add'};
        if(parentSeq!=null) body.parentSeq=parentSeq;   // 0 도 명시적 최상위 override로 보낸다
        if(priority) body.priority=priority;
        fetch('/api/goal/queue/resolve',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})
            .then(r=>r.json()).then(res=>{
              if(res&&res.ok&&res.seq&&window.gaQueueResolved){
        // parentFallback: 서브 부착이 1-level 트리 규칙에 막혀 최상위로 추가된 경우 — 행에 안내를 얹는다.
        gaQueueResolved(id,{action:'add',seq:res.seq,parentSeq:(res.parentSeq!=null?res.parentSeq:(parentSeq||0)),
                            text:label,fallback:!!(res&&res.parentFallback)});
              }
              qdReload();
            })
            .catch(()=>qdReload());
        }
        // task로 추가: 새 goal을 채번하지 않고 기존 goal #seq의 부분과제(tasks/taskN 폴더)로 붙인다.
        // 응답의 task 폴더명을 행에 실어 "무엇이 어디에 생겼는지" 바로 검증할 수 있게 한다.
        function queueAddTask(id,seq,taskName){
        _qJustRefined='';
        const it=((_review&&_review.aiQueue)||_lastAiQueue||[]).find(x=>x.id===id);
        const label=it?it.text:'';
        const body={id:id,action:'task',parentSeq:seq};
        if(taskName) body.taskName=taskName;   // 검색→task 추가: 추천/수정된 폴더명을 그대로 사용
        fetch('/api/goal/queue/resolve',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify(body)})
            .then(r=>r.json()).then(res=>{
              if(res&&res.ok&&res.seq&&window.gaQueueResolved)
        gaQueueResolved(id,{action:'task',seq:res.seq,parentSeq:0,text:label,task:res.task||''});
              qdReload();
            }).catch(()=>qdReload());
        }
        // === 검색(findOnly) → 다음 액션 흐름 ===
        // 추천 액션: AI가 붙인 relation/kind로 결정한다. 반복 실행/하위문제면 'task 추가'를, 그 외엔
        // '끝내기(열기)'를 추천한다. rationale/note는 추천 사유로 그대로 노출한다.
        function qFindRec(it){ const rel=it.relation||'', k=it.kind||'';
        return (rel==='recurring-execution'||rel==='sub-problem'||k==='recurring')?'task':'finish'; }
        // 번호를 골라 대상 목표를 정한다 → 다음 액션 메뉴로.
        function queueFindPick(id,seq){ _qFind[id]={parentSeq:seq,phase:'menu'}; rerenderAiQueue(); }
        // 매치 목록 마지막 행의 '#번호 직접 입력' 확정 — 목록에 없는 목표도 대상으로 삼는다.
        function queueFindManual(id){
        const inp=$('qfindn_'+id);
        const raw=((inp?inp.value:_qFindNum[id])||'').replace(/[^0-9]/g,'');
        const seq=parseInt(raw,10)||0;
        if(seq<=0){ if(inp) inp.focus(); return; }
        delete _qFindNum[id]; qDraftSave();
        queueFindPick(id,seq);
        }
        // 닫기 = 뷰만 닫는다(접기/카드 제거) — 항목은 큐에 남아 다시 펼치면 이어진다. 스킵과 다름.
        function queueClose(id){ delete _qFind[id]; if(window.gaQueueClosed) gaQueueClosed(id); }
        // '기타(직접 지시 — 다시 검색)': 지시문을 새 검색어로 보내 분석을 리셋(pending)하고 다시
        // 찾는다(/api/goal/queue/edit — 검색 분석 자체가 AI라 문장 지시를 그대로 이해한다).
        function queueFindPrompt(id){
        const inp=$('qfindp_'+id);
        const v=(((inp?inp.value:_qFindPrompt[id])||'')).trim();
        if(!v){ if(inp) inp.focus(); return; }
        delete _qFindPrompt[id]; delete _qFind[id]; qDraftSave();
        post('/api/goal/queue/edit',{id:id,text:v}).then(r=>r.json()).then(res=>{
            if(!(res&&res.ok)) alert('다시 검색을 시작하지 못했습니다 (이미 처리된 항목).');
            qdReload();
        }).catch(()=>qdReload());
        }
        // 대상 선택 취소 → 매치 목록으로 되돌린다.
        function queueFindBack(id){ delete _qFind[id]; rerenderAiQueue(); }
        // 액션 실행: finish=목표 열기(끝내기), stop=아무것도 안 하고 검색 닫기(skip),
        // task=이름 추천(서버)을 받아 수정 가능한 입력으로 넘어간다.
        function queueFindAct(id,action,pN){
        if(action==='finish'){ location.href='/goal?n='+pN; return; }
        if(action==='stop'){ delete _qFind[id]; queueSkip(id); return; }
        if(action==='task'){
            _qFind[id]={parentSeq:pN,phase:'suggesting'}; rerenderAiQueue();
            fetch('/api/goal/queue/suggest-task-name',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({id:id,parentSeq:pN})})
              .then(function(r){return r.json();}).then(function(res){
        if(res&&res.ok&&res.name){ _qFind[id]={parentSeq:pN,phase:'edit',name:res.name}; }
        else { alert('이름 추천에 실패했습니다 (claude 미설치/오류). 다시 시도하세요.'); _qFind[id]={parentSeq:pN,phase:'menu'}; }
        rerenderAiQueue();
              }).catch(function(){ _qFind[id]={parentSeq:pN,phase:'menu'}; rerenderAiQueue(); });
        }
        }
        // 생성: (수정된) 추천 이름으로 #parentSeq 아래 task를 만든다.
        function queueFindCreate(id){ const sel=_qFind[id]; if(!sel) return;
        const inp=$('qfind_'+id); const name=((inp?inp.value:sel.name)||'').trim();
        if(!name){ if(inp) inp.focus(); return; }
        const pN=sel.parentSeq; delete _qFind[id];
        queueAddTask(id,pN,name);
        }
        // 검색 카드의 다음 액션 패널 HTML(대상 목표 pN 기준). phase: menu→suggesting→edit.
        function qFindActionHTML(it,hits,sel){
        const pN=sel.parentSeq;
        // 직접 입력한 번호는 매치 목록에 없을 수 있다 — 그땐 최상위 목표 목록에서 제목을 찾는다.
        const m0=hits.find(function(m){return m.seq===pN;});
        const pT=m0?esc(m0.text||''):esc(topGoalTitle(pN)||'');
        const back='<div class="qhint" style="margin:2px 0 6px">대상: <a href="/goal?n='+pN+'" style="color:var(--accent);text-decoration:none">#'+pN+'</a> '+pT
            +' · <a href="#" onclick="queueFindBack(\''+it.id+'\');return false" style="color:var(--mut)">다른 목표 선택</a></div>';
        if(sel.phase==='suggesting'){
            return back+'<div style="border:1px dashed #33406a;border-radius:8px;padding:8px 10px;background:#101627">'
              +'<span style="color:var(--green);font-size:13px"><span class="qspin">🔄</span> task 이름 만드는 중…</span></div>';
        }
        if(sel.phase==='edit'){
            const nv=(sel.name||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
            return back+'<div style="border:1px dashed #33406a;border-radius:8px;padding:8px 10px;background:#101627">'
              +'<div style="font-size:11px;color:#9db4ff;margin-bottom:5px">추가할 task 이름 — 수정 가능 (Enter 생성)</div>'
              +'<input id="qfind_'+it.id+'" data-qid="'+it.id+'" class="qfind-input" value="'+nv+'" '
              +'onkeydown="if(event.key===\'Enter\'){event.preventDefault();queueFindCreate(\''+it.id+'\');}" '
              +'oninput="if(_qFind[\''+it.id+'\'])_qFind[\''+it.id+'\'].name=this.value" '
              +'style="width:100%;background:#0f131b;color:var(--fg);border:1px solid var(--accent);border-radius:8px;padding:8px 10px;font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;outline:none">'
              +'<div style="display:flex;gap:6px;margin-top:6px"><button class="btn primary" onclick="queueFindCreate(\''+it.id+'\')">생성</button>'
              +'<button class="btn" onclick="queueFindBack(\''+it.id+'\')">취소</button></div>'
              +'<div class="qhint" style="margin-top:4px">#'+pN+' 아래 tasks/ 폴더로 이번 회차가 생성됩니다</div></div>';
        }
        // phase 'menu': 3 액션(추천 1번).
        const rec=qFindRec(it);
        const recWhy=it.rationale?esc(it.rationale):(it.note?esc(it.note):'#'+pN+' '+pT+'의 반복 회차로 보여, 그 목표의 task로 이번 실행을 추가합니다.');
        let opts=[
            {a:'task',label:'#'+pN+'에 task 추가',rec:(rec==='task'),desc:(rec==='task'?recWhy:'이번 실행을 #'+pN+'의 task(부분과제)로 추가합니다. 이름은 AI가 추천합니다.')},
            {a:'finish',label:'#'+pN+' 열기 — 여기서 끝내기',rec:(rec==='finish'),desc:(rec==='finish'?'찾던 목표가 이미 있고 이번엔 새 작업이 없어, 그 목표를 열어 확인만 하고 마칩니다.':'새로 만들지 않고 찾은 목표를 열어 확인합니다.')},
            {a:'stop',label:'그만두기',desc:'아무것도 하지 않고 이 검색 결과를 닫습니다.'}
        ];
        const ri=opts.findIndex(function(o){return o.rec;}); if(ri>0){ opts.unshift(opts.splice(ri,1)[0]); }
        let n=0;
        const rows=opts.map(function(o){ n++;
            return '<div class="qopt'+(o.rec?' rec':'')+'" onclick="queueFindAct(\''+it.id+'\',\''+o.a+'\','+pN+')">'
              +'<div class="qnum">'+n+'</div>'
              +'<div class="qopt-body"><div class="qopt-label">'+o.label+(o.rec?'<span class="qrec-tag">추천</span>':'')+'</div>'
              +'<div class="qopt-desc">'+o.desc+'</div></div></div>';
        }).join('');
        return back+'<div class="qchoice">'+rows+'</div>';
        }
        function queueSkip(id){ _qJustRefined='';
        post('/api/goal/queue/resolve',{id:id,action:'skip'}).then(()=>{
          if(window.gaQueueResolved) gaQueueResolved(id,{action:'skip'});
          qdReload(); }); }
        // --- 오버라이드 패널: 배치/우선순위를 직접 지정해 승격 ---
        // 패널 열고 닫기(폴링 재렌더가 innerHTML을 갈아끼워도 다시 열려면 링크를 다시 눌러야 하므로, 열림 상태는 굳이 보존하지 않음 — 가벼움 유지).
        function qOverrideToggle(id){ const p=$('qovr_'+id); if(!p) return;
        p.style.display=(p.style.display==='none'||!p.style.display)?'flex':'none';
        if(p.style.display==='flex'){ const n=$('qovrn_'+id); if(n) n.focus(); } }
        // select(부모 목표)로 고르면 #번호 입력칸을 동기화.
        function qOvrPickParent(id){ const s=$('qovrp_'+id), n=$('qovrn_'+id); if(!s||!n) return;
        const v=parseInt(s.value,10)||0; n.value=(v>0?v:''); }
        // #번호 직접 입력 시 select 를 동기화(그 번호가 최상위 목록에 있으면 선택, 없으면 독립으로).
        function qOvrSyncSelect(id){ const s=$('qovrp_'+id), n=$('qovrn_'+id); if(!s||!n) return;
        const v=parseInt(n.value,10)||0; let has=false;
        for(let i=0;i<s.options.length;i++){ if((parseInt(s.options[i].value,10)||0)===v){ s.selectedIndex=i; has=true; break; } }
        if(!has) s.value='0';   // 최상위 목록에 없는 번호는 서브로 못 다니, 독립으로 표시(백엔드도 fallback)
        }
        // 오버라이드 승격: 선택한 parentSeq(0=독립) + priority 를 명시적으로 보낸다 → 백엔드가 AI 제안 대신 이 값을 적용.
        function queueOverrideApply(id){
        const n=$('qovrn_'+id), pri=$('qovrpri_'+id);
        const parentSeq=n?(parseInt(n.value,10)||0):0;   // 빈칸/0 → 명시적 최상위
        const priority=pri?pri.value:'';
        queueAdd(id,parentSeq,priority);
        }
        // 번호 선택 UI 액션 라우팅: 추가/스킵/프롬프트 열기(이미지 지원 챗)/부모 아래 추가. 'other'는 인라인 입력이 처리.
        function queueChoose(id,action,arg){
        if(action==='add') return queueAdd(id);
        if(action==='task') return queueAddTask(id,arg); // 반복 회차: #arg의 task(부분과제)로 — 새 goal 없음
        if(action==='under') return queueAdd(id,arg);   // 부모 #arg 아래 서브 목표로 추가 + 확인 카드
        if(action==='skip') return queueSkip(id);
        if(action==='prompt') return queuePromptChat(id);
        if(action==='override') return qOverrideToggle(id);   // 배치/우선순위 직접 지정 패널 토글
        if(action==='pick') return queueFindPick(id,parseInt(arg,10)||0);   // 검색 매치 → 다음 액션 메뉴
        }
        // 기타(직접 지시)·재검색 지시 입력의 IME-안전 Enter 제출 — 문서 레벨 위임이라 큐가 어느
        // 뷰(목록/루프)로 재렌더되든 재바인딩 없이 항상 동작한다. 한글 조합을 확정하는 Enter는
        // isComposing=true여서 그냥 무시하면 삼켜지므로(마지막 글자 확정용), 보류했다가
        // compositionend 직후에 제출한다. 제출 대상은 클래스로 가른다:
        //   qother-input → queueOtherSubmit(프롬프트 다듬기) · qfindp-input → queueFindPrompt(재검색)
        function qImeInput(el){ return el&&el.classList&&(el.classList.contains('qother-input')||el.classList.contains('qfindp-input')); }
        function qImeSubmit(el){ const id=el.getAttribute('data-qid'); if(!id) return;
        if(el.classList.contains('qfindp-input')) queueFindPrompt(id); else queueOtherSubmit(id); }
        document.addEventListener('keydown',function(e){
        const el=e.target;
        if(!qImeInput(el)||e.key!=='Enter') return;
        if(e.isComposing||el._composing){ el._pendingSubmit=true; return; }   // 조합 중: 확정 후로 보류
        e.preventDefault();
        qImeSubmit(el);
        });
        document.addEventListener('compositionstart',function(e){ if(qImeInput(e.target)) e.target._composing=true; });
        document.addEventListener('compositionend',function(e){ const el=e.target;
        if(!qImeInput(el)) return;
        el._composing=false;
        if(el._pendingSubmit){ el._pendingSubmit=false; qImeSubmit(el); }
        });
        function queueOtherSubmit(id){
        const inp=$('qother_'+id); const v=(((_qOther[id]!=null?_qOther[id]:(inp?inp.value:''))||'')).trim();
        if(!v){ if(inp) inp.focus(); return; }
        delete _qOther[id]; qDraftSave();      // 제출됐으니 보관값 정리
        _qUI={id:id,mode:'prompt',prompt:v};   // queuePromptGen이 t 없으면 _qUI.prompt를 사용
        queuePromptGen(id);
        }
        // 큐 항목 다듬기: 대시보드의 dup 모달(이미지 챗)은 이 페이지엔 없다 — 인라인 프롬프트 패널로
        // 연다. 같은 서버 refine 파이프라인(/api/goal/queue/refine, refineSession 유지)이라 다듬기
        // 능력은 동일하고, 이미지가 필요하면 항목을 승격한 뒤 목표 페이지에서 잇는다.
        function queuePromptChat(id){ queuePromptStart(id); }
        // 프롬프트 열기 → 입력 → 생성(서버 refine) → 새 결과. 맞으면 진행(queueProceed), 아니면 다시.
        function queuePromptStart(id){ _qJustRefined=''; _qUI={id:id,mode:'prompt',prompt:''}; rerenderAiQueue();
        const t=$('qp_'+id); if(t) t.focus(); }
        function queuePromptCancel(){ _qUI=null; rerenderAiQueue(); }
        function queuePromptGen(id){
        const t=$('qp_'+id); const prompt=((t?t.value:((_qUI&&_qUI.prompt)||''))||'').trim();
        if(!prompt){ if(t) t.focus(); return; }
        _qUI={id:id,mode:'gen',prompt:prompt}; rerenderAiQueue();
        fetch('/api/goal/queue/refine',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id,prompt:prompt})})
            .then(r=>r.json()).then(res=>{ _qUI=null; if(res&&res.ok){ _qJustRefined=id; } else { alert('다듬기에 실패했습니다 (claude 미설치/오류). 잠시 후 다시 시도하세요.'); } qdReload(); })
            .catch(()=>{ _qUI=null; qdReload(); });
        }
        function queueProceed(id){ _qJustRefined=''; queueAdd(id); }
        // (queueEditStart 는 제거 — 큐 병합 후 텍스트 수정은 담김 행의 인라인 수정(gaTallyEdit →
        //  /api/goal/queue/edit 재분석)이 담당한다. 대시보드 시절의 dblclick 진입점은 없다.)
        // 검토 대기 항목이 정확히 1건일 때 숫자키(1-N)로 옵션 선택. 여러 건이면 모호하므로 클릭만 허용.
        // 입력/텍스트영역에 포커스가 있으면(기타 직접 입력 등) 무시한다.
        document.addEventListener('keydown',function(e){
        if(e.metaKey||e.ctrlKey||e.altKey) return;
        if(!/^[1-9]$/.test(e.key)) return;
        const t=e.target, tag=(t&&t.tagName)||'';
        if(tag==='INPUT'||tag==='TEXTAREA'||(t&&t.isContentEditable)) return;
        const cards=document.querySelectorAll('.qchoice');
        if(cards.length!==1) return;
        const card=cards[0], opt=card.querySelector('.qopt[data-n="'+e.key+'"]');
        if(!opt) return;
        e.preventDefault();
        const id=card.getAttribute('data-qid'), act=opt.getAttribute('data-action'), arg=opt.getAttribute('data-arg');
        if(act==='other'){ const inp=$('qother_'+id); if(inp) inp.focus(); }
        else if(act==='findnum'){ const inp=$('qfindn_'+id); if(inp) inp.focus(); }
        else if(act==='findprompt'){ const inp=$('qfindp_'+id); if(inp) inp.focus(); }
        else queueChoose(id,act,arg);
        });
        // ===== 데이터 리로드 =====
        // qdSnap: /data.json review 스냅샷 반입(상태만 — 렌더 없음). 호스트의 5초 폴링
        // (gaTallyPoll)이 렌더 여부를 스스로 판단하며 이 함수를 공유한다 — 폴링 루프는 하나만.
        function qdSnap(rev){
          rev=rev||{};
          _review=rev; _reviewAt=Date.now();
          _goals.length=0; ((rev.goals)||[]).forEach(g=>_goals.push(g));
          _qHist=rev.queueHistory||[];
          _lastAiQueue=rev.aiQueue||[];
          return rev;
        }
        // qdReload: 리로드 + 즉시 렌더 — 확정/번복/재시도/펼침 등 액션 직후 반영용.
        function qdReload(){
          return fetch('/data.json',{cache:'no-store'}).then(r=>r.json()).then(d=>{
            const rev=qdSnap((d&&d.review)||{});
            renderAiQueue(_lastAiQueue);
            return rev;
          }).catch(()=>null);
        }
        """#
    }
}
