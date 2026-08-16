import Foundation

// GET /equipment — the 장비(Equipment) page: a game-style character sheet where the
// rail's nav abilities (대화·스킬·위임·워커·팀) and plugins are worn by an 8등신
// human avatar as body-part gear. Each category carries a proficiency level 0..7 +
// XP gauge; the OVERALL level (shown next to 설정 메뉴의 장비 row) is the rounded
// average — Lv.7 완전자율 only when everything is mastered.
//
// All numbers come from GET /api/equipment (EquipmentStore + plugin list); EXP is
// granted server-side when a pomodoro completes (rail cmChOnComplete → POST
// /api/equipment/pomodoro). This page is a pure view + a dev-only 시뮬 button.
// Prototype/기획: tests/prototypes/equipment-test.html.
enum EquipmentContent {

    static func html() -> String {
        return #"""
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>장비 · 숙련도</title>
        <style>
          :root{
            --bg:#0e1116; --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3;
            --accent:#5b8cff; --card:#0f141d; --card-hi:#141b28;
            --lv-cyan:#33c9e6; --lv-red:#f05045; --lv-purple:#a97bff;
          }
          *{ box-sizing:border-box }
          body{ margin:0; background:var(--bg); color:var(--fg);
            font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif }
          header{ position:sticky; top:0; z-index:30; display:flex; align-items:center;
            justify-content:space-between; gap:12px; background:rgba(14,17,22,.92);
            backdrop-filter:blur(6px); border-bottom:1px solid var(--line); padding:14px 20px }
          header h1{ margin:0; font-size:16px }
          header .sub{ color:var(--mut); font-size:12px; margin-top:2px }
          header a{ color:var(--accent); text-decoration:none; font-size:12px }
          main{ max-width:1020px; margin:0 auto; padding:18px 20px 80px }
          .panel{ background:var(--panel); border:1px solid var(--line); border-radius:12px;
            padding:16px; margin-bottom:14px }

          .equip-head{ display:flex; align-items:baseline; gap:14px; flex-wrap:wrap }
          .equip-head h2{ margin:0; font-size:15px }
          .lv-big{ font-size:15px; font-weight:800; letter-spacing:.3px }
          .lv-name{ color:var(--mut); font-size:12.5px }
          .lv-avg{ color:var(--mut); font-size:11.5px; margin-left:auto }
          .lv-bar{ height:7px; background:#151b28; border:1px solid var(--line); border-radius:999px;
            overflow:hidden; margin:10px 0 14px }
          .lv-bar i{ display:block; height:100%; border-radius:999px; transition:width .35s, background .35s }

          .market{ display:flex; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:16px;
            padding:8px 12px; background:#10151f; border:1px solid var(--line); border-radius:10px;
            font-size:12px; color:var(--mut) }
          .market b{ color:var(--fg) }
          .market .mk-date{ font-size:10.5px }
          .market .hint{ font-size:10.5px; margin-left:auto }

          .equip-grid{ display:grid; grid-template-columns:270px 1fr 250px; gap:18px; align-items:start }
          @media (max-width:900px){ .equip-grid{ grid-template-columns:1fr } }
          .slot-col h4, .plug-area h4{ margin:0 0 8px; font-size:12px; color:var(--mut);
            font-weight:700; letter-spacing:.4px }
          .slot{ padding:9px 11px; margin-bottom:8px; background:var(--card);
            border:1px solid var(--line); border-radius:11px; user-select:none; position:relative;
            transition:border-color .15s }
          .slot .top{ display:flex; align-items:center; gap:9px }
          .slot .ico{ width:32px; height:32px; flex:none; display:flex; align-items:center;
            justify-content:center; font-size:17px; background:#131a26; border-radius:9px;
            border:1px solid var(--line) }
          .slot .nm{ font-size:12.5px; font-weight:600 }
          .slot .ds{ font-size:10.5px; color:var(--mut); line-height:1.3 }
          .slot .lvchip{ margin-left:auto; font-size:10px; font-weight:800; letter-spacing:.4px;
            padding:2px 8px; border-radius:999px; background:#1a2130; color:var(--mut); flex:none }
          .slot.lit{ border-color:#2f6bff }
          .slot.lit .lvchip{ background:#1f3a75; color:#9ec1ff }
          .slot.max .lvchip{ background:#241f3a; color:var(--lv-purple) }
          .xp{ height:4px; background:#151b28; border-radius:999px; overflow:hidden; margin-top:7px }
          .xp i{ display:block; height:100%; background:#2f6bff; border-radius:999px; transition:width .3s }
          .slot.max .xp i{ background:var(--lv-purple) }
          .xptxt{ font-size:9.5px; color:var(--mut); margin-top:3px; text-align:right }

          .char{ text-align:center; padding:6px 8px 8px }
          .char .fig{ position:relative; width:230px; height:352px; margin:0 auto;
            background:radial-gradient(ellipse 60% 45% at 50% 46%, rgba(51,201,230,.10), transparent 70%);
            transition:background .4s }
          /* 도트(픽셀아트) avatar canvas — fills the fig with the cobblestone scene. */
          .char .fig canvas{ position:absolute; left:0; top:0; width:230px; height:352px;
            border-radius:14px }
          .pop3d{ position:absolute; font-size:18px; pointer-events:none; z-index:3;
            animation:pop3d .75s ease-out forwards }
          .popxp{ position:absolute; font-size:11px; font-weight:800; color:#f5c85b;
            pointer-events:none; z-index:3; text-shadow:0 1px 2px rgba(0,0,0,.65);
            animation:pop3d .85s ease-out forwards }
          @keyframes pop3d{ from{ transform:translateY(0) scale(.6); opacity:1 }
            to{ transform:translateY(-28px) scale(1.2); opacity:0 } }
          .mini{ position:absolute; display:flex; align-items:center; gap:4px; padding:3px 7px;
            background:var(--card); border:1px solid var(--line); border-radius:8px;
            font-size:10px; user-select:none; z-index:2; white-space:nowrap }
          .mini .ic{ font-size:12px }
          .mini .lv{ font-weight:800; color:var(--mut) }
          .mini .part{ color:var(--mut); font-size:8.5px; letter-spacing:.3px }
          .mini.lit{ border-color:#2f6bff } .mini.lit .lv{ color:#9ec1ff }
          .mini.max{ border-color:#3d3560 } .mini.max .lv{ color:var(--lv-purple) }
          .mini.future{ border-style:dashed; opacity:.45 }
          @keyframes breath{ 0%,100%{ opacity:.78 } 50%{ opacity:1 } }

          /* 폭우 소환 — storm overlay raining on the avatar while a 폭우 리셋 is active */
          .fig .rainfx{ position:absolute; inset:0; overflow:hidden; pointer-events:none;
            z-index:1; opacity:0; transition:opacity .8s; border-radius:18px }
          .fig.raining .rainfx{ opacity:1 }
          .fig .storm-cloud{ position:absolute; font-size:30px;
            filter:drop-shadow(0 5px 12px rgba(96,150,235,.55));
            animation:cloud-drift 3.6s ease-in-out infinite }
          @keyframes cloud-drift{ 0%,100%{ transform:translateX(-4px) } 50%{ transform:translateX(4px) } }
          .fig .drop{ position:absolute; top:-24px; width:2px; height:15px; border-radius:2px;
            background:linear-gradient(180deg, rgba(130,185,255,0), rgba(130,185,255,.85));
            animation:rain-fall linear infinite }
          @keyframes rain-fall{ to{ transform:translateY(400px) } }
          .char .who{ margin-top:10px; font-size:12.5px; color:var(--mut) }
          .char .who b{ color:var(--fg) }
          .char .auto-badge{ display:none; margin:10px auto 0; width:fit-content; font-size:11px;
            font-weight:800; letter-spacing:.5px; padding:4px 14px; border-radius:999px;
            background:#241f3a; color:var(--lv-purple); border:1px solid #3d3560;
            animation:breath 1.4s ease-in-out infinite }
          .char.lv7 .auto-badge{ display:block }

          .plug-grid{ display:grid; grid-template-columns:repeat(2, 1fr); gap:8px }
          .plug{ padding:10px; background:var(--card); border:1px solid var(--line); border-radius:11px;
            user-select:none; min-height:74px }
          .plug .ico{ font-size:17px }
          .plug .nm{ font-size:11.5px; font-weight:600; margin-top:4px }
          .plug .st{ font-size:10px; color:var(--mut); margin-top:2px }
          .plug.on{ border-color:#2f6bff } .plug.on .st{ color:#9ec1ff }
          .plug.empty{ border-style:dashed; opacity:.55; display:flex; align-items:center;
            justify-content:center; color:var(--mut); font-size:11px }

          .rule{ font-size:12px; color:var(--mut); line-height:1.7 }
          .rule b{ color:var(--fg) }
          .ledger{ font-size:12px; color:var(--mut) }
          .ledger .row{ padding:7px 12px; background:#10151f; border:1px solid var(--line);
            border-radius:9px; margin-bottom:6px }
          .ledger b{ color:var(--fg) }
          .ledger .win{ color:var(--lv-cyan); font-weight:700 }
          .ledger .empty{ text-align:center; padding:14px 0 }
          .devbtn{ background:#1d2230; border:1px solid var(--line); color:var(--mut);
            border-radius:8px; padding:5px 10px; font-size:11px; cursor:pointer }
          .devbtn:hover{ background:#242b3b; color:var(--fg) }

          .rain-summon{ margin-top:12px; padding:12px; background:#0f1620; border:1px solid var(--line);
            border-radius:11px; text-align:center }
          .rain-summon button{ width:100%; padding:9px 12px; border-radius:9px; cursor:pointer;
            font-size:12.5px; font-weight:700; color:#dbeafe; border:1px solid #2f5fa8;
            background:linear-gradient(180deg,#1b3358,#152744); transition:filter .15s, opacity .15s }
          .rain-summon button:hover:not(:disabled){ filter:brightness(1.18) }
          .rain-summon button:disabled{ opacity:.45; cursor:not-allowed }
          .rain-summon .rain-note{ font-size:10px; color:var(--mut); margin-top:6px; line-height:1.4 }
          .rain-summon .rain-msg{ font-size:10.5px; margin-top:5px; min-height:13px; font-weight:700 }
          .foot{ color:var(--mut); font-size:11px; text-align:center; margin-top:18px }
        </style></head>
        <body>
          <script>window.CM_PAGE='equipment';</script>
          \#(SessionRail.html())
          <header>
            <div><h1>⚔️ 장비 · 숙련도</h1>
              <div class="sub">포모도로 성공 → 가장 많이 쓴 장비에 EXP · 전체 레벨 = 평균 숙련도 · Lv.7 완전자율</div></div>
            <a href="/">← 대시보드</a>
          </header>
          <main>
            <div class="panel">
              <div class="equip-head">
                <h2>내 장비</h2>
                <span class="lv-big" id="lvBig">Lv.—</span>
                <span class="lv-name" id="lvName"></span>
                <span class="lv-avg" id="lvAvg"></span>
              </div>
              <div class="lv-bar"><i id="lvFill" style="width:0%; background:var(--lv-cyan)"></i></div>
              <div class="market">
                <span>📈</span>
                <span>시장 경험치 — <b id="mkLv">시장 Lv.—</b> · 필요 XP <b id="mkInf">×—</b></span>
                <span class="mk-date" id="mkDate"></span>
                <span class="hint">매월 새 모델 출시 → 필요 경험치 ×1.3 인플레이션</span>
              </div>

              <div class="equip-grid">
                <div class="slot-col">
                  <h4>네비게이션 능력</h4>
                  <div class="slot" data-cat="chat">
                    <div class="top"><div class="ico">💬</div>
                      <div><div class="nm">대화</div><div class="ds">대화로 목표 생성</div></div>
                      <span class="lvchip" id="lv-chat">—</span></div>
                    <div class="xp"><i id="xp-chat"></i></div><div class="xptxt" id="xt-chat"></div>
                  </div>
                  <div class="slot" data-cat="skills">
                    <div class="top"><div class="ico">🎯</div>
                      <div><div class="nm">스킬</div><div class="ds">반복 업무를 스킬로 실행</div></div>
                      <span class="lvchip" id="lv-skills">—</span></div>
                    <div class="xp"><i id="xp-skills"></i></div><div class="xptxt" id="xt-skills"></div>
                  </div>
                  <div class="slot" data-cat="delegate">
                    <div class="top"><div class="ico">🤝</div>
                      <div><div class="nm">위임</div><div class="ds">책임 에이전트에게 위임</div></div>
                      <span class="lvchip" id="lv-delegate">—</span></div>
                    <div class="xp"><i id="xp-delegate"></i></div><div class="xptxt" id="xt-delegate"></div>
                  </div>
                  <div class="slot" data-cat="cron">
                    <div class="top"><div class="ico">⏰</div>
                      <div><div class="nm">워커</div><div class="ds">주기 업무 자동 실행</div></div>
                      <span class="lvchip" id="lv-cron">—</span></div>
                    <div class="xp"><i id="xp-cron"></i></div><div class="xptxt" id="xt-cron"></div>
                  </div>
                  <div class="slot" data-cat="team">
                    <div class="top"><div class="ico">👥</div>
                      <div><div class="nm">팀</div><div class="ds">teamlead 오케스트레이션</div></div>
                      <span class="lvchip" id="lv-team">—</span></div>
                    <div class="xp"><i id="xp-team"></i></div><div class="xptxt" id="xt-team"></div>
                  </div>
                </div>

                <div class="char" id="char">
                  <div class="fig" id="fig">
                    <canvas id="cv3d" width="230" height="352"></canvas>
                    <div class="rainfx" id="rainFx"></div>
                    <div class="mini" id="mini-chat" style="left:142px; top:14px">
                      <span class="ic">💬</span><span class="part">머리</span><span class="lv" id="mlv-chat">—</span></div>
                    <div class="mini future" style="left:14px; top:36px" title="미래 아이템 슬롯">
                      <span class="ic">📿</span><span class="part">목걸이</span></div>
                    <div class="mini" id="mini-team" style="left:6px; top:76px">
                      <span class="ic">👥</span><span class="part">어깨</span><span class="lv" id="mlv-team">—</span></div>
                    <div class="mini" id="mini-plugin" style="left:144px; top:104px">
                      <span class="ic">🧩</span><span class="part">갑옷</span><span class="lv" id="mlv-plugin">—</span></div>
                    <div class="mini" id="mini-skills" style="left:0px; top:158px">
                      <span class="ic">🎯</span><span class="part">무기</span><span class="lv" id="mlv-skills">—</span></div>
                    <div class="mini" id="mini-delegate" style="left:152px; top:158px">
                      <span class="ic">🤝</span><span class="part">방패</span><span class="lv" id="mlv-delegate">—</span></div>
                    <div class="mini future" style="left:150px; top:210px" title="미래 아이템 슬롯">
                      <span class="ic">💍</span><span class="part">반지</span></div>
                    <div class="mini" id="mini-cron" style="left:12px; top:298px">
                      <span class="ic">⏰</span><span class="part">신발</span><span class="lv" id="mlv-cron">—</span></div>
                  </div>
                  <div class="who"><b>나</b> · 컨디션 매니저</div>
                  <div class="auto-badge">완 전 자 율</div>
                </div>

                <div class="plug-area">
                  <h4>플러그인</h4>
                  <div class="slot" data-cat="plugin" style="margin-bottom:10px">
                    <div class="top"><div class="ico">🧩</div>
                      <div><div class="nm">플러그인 숙련도</div><div class="ds">연결·활용 전체</div></div>
                      <span class="lvchip" id="lv-plugin">—</span></div>
                    <div class="xp"><i id="xp-plugin"></i></div><div class="xptxt" id="xt-plugin"></div>
                  </div>
                  <div class="plug-grid" id="plugGrid"></div>

                  <div class="rain-summon">
                    <button id="rainBtn" onclick="summonRain()">🌧 경험치로 폭우소환하기</button>
                    <div class="rain-note">200 XP 소모 · 30~60분 자연 빗소리로 전환<br>
                      음악이 물릴 때 빗소리로 바꿔 컨디션 회복을 실험</div>
                    <div class="rain-msg" id="rainMsg"></div>
                  </div>
                </div>
              </div>
            </div>

            <div class="panel">
              <div style="display:flex; align-items:center; gap:10px; margin-bottom:10px">
                <h2 style="margin:0; font-size:14px">🍅 경험치 지급 기록</h2>
                <button class="devbtn" style="margin-left:auto" onclick="devAward()"
                  title="개발용 — 지난 25분 실사용 기준으로 포모도로 성공 지급을 시뮬레이션">시뮬 지급(개발)</button>
              </div>
              <div class="ledger" id="ledger"><div class="empty">아직 지급 기록이 없습니다 — 포모도로를 완주하면 여기 쌓입니다.</div></div>
            </div>

            <div class="panel rule">
              <b>규칙</b> — 포모도로 25분 성공 시 +<span id="ruleXP">80</span> XP를 그 세션에서 <b>가장 많이 사용한 장비 1곳</b>에 전액 지급
              (사용 집계: 스킬 실행 · 대화 메시지 — 사용자 행동만, 실로그 기반 / 기록 없으면 기본기(대화)).
              전체 레벨은 6개 장비 숙련도의 <b>평균(반올림)</b> — 전 장비 마스터 = 평균 7 = <b>완전자율</b>.
              캐릭터 쓰다듬기(클릭) = <b>+1 XP</b>, 가장 약한 장비에 지급.
              필요 EXP는 (60 + 레벨×40) × 1.3^(시장Lv−1) — 매월 새 모델 출시마다 시장 레벨 +1.
            </div>
            <div class="foot">장비·숙련도 원장: equipment.json · 조회 /api/equipment · 지급 POST /api/equipment/pomodoro</div>
          </main>

          <script>
          var CATS = ['chat','skills','delegate','cron','team','plugin'];
          var NAME = {chat:'대화', skills:'스킬', delegate:'위임', cron:'워커', team:'팀', plugin:'플러그인'};
          var LVCOLOR = function(lv){
            if (lv >= 6) return {c:'var(--lv-purple)', glow:'169,123,255'};
            if (lv >= 4) return {c:'var(--lv-red)',    glow:'240,80,69'};
            return {c:'var(--lv-cyan)', glow:'51,201,230'};
          };

          var RAIN_COST = 200;
          var wasRaining = false;
          function render(j){
            if (!j || !j.categories) return;
            var raining = !!(j.rain && j.rain.active);
            // Rain-summon affordability: pooled XP gauges across all categories.
            var pool = 0;
            CATS.forEach(function(k){ var c = j.categories[k]; if (c) pool += (c.xp || 0); });
            var rb = document.getElementById('rainBtn');
            if (rb){
              if (raining){
                rb.disabled = true;
                rb.title = '이미 폭우가 내리는 중입니다';
              } else {
                rb.disabled = pool < RAIN_COST;
                rb.title = pool < RAIN_COST
                  ? ('경험치 부족 — 보유 ' + pool + ' / 필요 ' + RAIN_COST + ' XP')
                  : ('보유 경험치 ' + pool + ' XP · ' + RAIN_COST + ' 소모');
              }
            }
            // Storm on the avatar while rain is falling (summon response + 15s poll both land here).
            var fig = document.getElementById('fig');
            if (fig){
              if (raining) ensureRainFx();
              fig.classList.toggle('raining', raining);
            }
            var rmsg = document.getElementById('rainMsg');
            if (rmsg){
              if (raining){
                var mins = Math.max(1, Math.round((j.rain.remaining || 0) / 60));
                rmsg.textContent = '🌧 폭우 내리는 중 · 약 ' + mins + '분 남음';
                rmsg.style.color = 'var(--lv-cyan)';
              } else if (wasRaining){
                rmsg.textContent = '';
              }
            }
            wasRaining = raining;
            CATS.forEach(function(k){
              var c = j.categories[k]; if (!c) return;
              var el = document.getElementById('lv-'+k); if (el) el.textContent = 'Lv.' + c.lv;
              var slot = document.querySelector('.slot[data-cat="'+k+'"]');
              if (slot){
                slot.classList.toggle('lit', c.lv > 0 && c.lv < 7);
                slot.classList.toggle('max', c.lv >= 7);
              }
              var pct = c.lv >= 7 ? 100 : (c.need > 0 ? Math.min(100, c.xp / c.need * 100) : 0);
              var xp = document.getElementById('xp-'+k); if (xp) xp.style.width = pct + '%';
              var xt = document.getElementById('xt-'+k);
              if (xt) xt.textContent = c.lv >= 7 ? 'MASTER' : (c.xp + ' / ' + c.need + ' XP');
              var m = document.getElementById('mini-'+k);
              if (m){
                m.classList.toggle('lit', c.lv > 0 && c.lv < 7);
                m.classList.toggle('max', c.lv >= 7);
                var ml = document.getElementById('mlv-'+k); if (ml) ml.textContent = 'Lv.' + c.lv;
              }
            });
            var d = LVCOLOR(j.overall);
            document.getElementById('lvBig').textContent  = 'Lv.' + j.overall;
            document.getElementById('lvName').textContent = j.overallName || '';
            document.getElementById('lvAvg').textContent  = '평균 숙련도 ' + j.average.toFixed(1) + ' / 7';
            var fill = document.getElementById('lvFill');
            fill.style.width = (j.average / 7 * 100).toFixed(1) + '%';
            fill.style.background = d.c;
            var glow = raining ? '96,150,235' : d.glow;   // stormy blue ambience while raining
            document.getElementById('fig').style.background =
              'radial-gradient(ellipse 60% 45% at 50% 46%, rgba(' + glow + ',' + (raining ? '.16' : '.12') + '), transparent 70%)';
            if (window.CM3D) CM3D.setGlow(glow, j.overall);   // pixel scene glow follows level color
            document.getElementById('char').classList.toggle('lv7', j.overall === 7);
            // market strip
            document.getElementById('mkLv').textContent  = '시장 Lv.' + j.market.lv;
            document.getElementById('mkInf').textContent = '×' + j.market.inflation.toFixed(2);
            document.getElementById('mkDate').textContent = (j.market.epoch || '') + ' 기점';
            document.getElementById('ruleXP').textContent = j.rewardXP || 80;
            // plugin boxes: one per plugin + two dashed future slots
            var pg = document.getElementById('plugGrid');
            if (pg){
              var h = '';
              (j.plugins || []).forEach(function(p){
                var on = (p.status === 'valid');
                h += '<div class="plug' + (on ? ' on' : '') + '"><div class="ico">' +
                     (p.kind === 'toggle' ? '🎵' : '🖥️') + '</div><div class="nm">' + esc(p.name) +
                     '</div><div class="st">' + esc(p.detail || p.status) + '</div></div>';
              });
              h += '<div class="plug empty">빈 슬롯</div><div class="plug empty">빈 슬롯</div>';
              pg.innerHTML = h;
            }
            // award ledger
            var lg = document.getElementById('ledger');
            if (lg){
              var rows = (j.awards || []).map(function(a){
                var t = CMTimeFilter.parts(a.at * 1000);   // 표시 타임존 기준
                var hh = String(t.h).padStart(2,'0') + ':' + String(t.mi).padStart(2,'0');
                var mm = t.mo + '/' + t.d;
                var use = [];
                CATS.forEach(function(k){ if (a.usage && a.usage[k] > 0) use.push((NAME[k]||k) + ' ' + a.usage[k]); });
                return '<div class="row">' + mm + ' ' + hh + ' · 🍅 <span class="win">' + (NAME[a.category]||a.category) +
                  '</span>에 <b>+' + a.xp + ' XP</b>' +
                  (use.length ? ' <span style="opacity:.7">(' + use.join(' · ') + ')</span>' : ' <span style="opacity:.7">(사용 기록 없음 → 기본기)</span>') +
                  (a.leveledTo > 0 ? ' · <b>레벨 업! Lv.' + a.leveledTo + '</b>' : '') + '</div>';
              });
              lg.innerHTML = rows.length ? rows.join('') :
                '<div class="empty">아직 지급 기록이 없습니다 — 포모도로를 완주하면 여기 쌓입니다.</div>';
            }
          }
          function esc(t){ var d = document.createElement('div'); d.textContent = (t == null ? '' : t); return d.innerHTML; }

          // Build the storm layer once (clouds over the head + randomized rain streaks);
          // visibility is driven purely by the fig's .raining class so it fades in/out.
          function ensureRainFx(){
            var fx = document.getElementById('rainFx');
            if (!fx || fx.childNodes.length) return;
            var h = '<span class="storm-cloud" style="left:24%; top:-8px">⛈️</span>' +
                    '<span class="storm-cloud" style="left:46%; top:0px; font-size:24px; animation-delay:-1.8s">🌧️</span>';
            for (var i = 0; i < 26; i++){
              var dur = 0.7 + Math.random() * 0.6;
              h += '<i class="drop" style="left:' + (3 + Math.random() * 94).toFixed(1) + '%;' +
                   ' animation-duration:' + dur.toFixed(2) + 's;' +
                   ' animation-delay:-' + (Math.random() * dur).toFixed(2) + 's;' +
                   ' opacity:' + (0.45 + Math.random() * 0.55).toFixed(2) + '"></i>';
            }
            fx.innerHTML = h;
          }

          function summonRain(){
            var btn = document.getElementById('rainBtn');
            var msg = document.getElementById('rainMsg');
            if (btn) btn.disabled = true;
            if (msg){ msg.textContent = '소환 중…'; msg.style.color = 'var(--mut)'; }
            fetch('/api/equipment/rain', {method:'POST',
              headers:{'Content-Type':'application/json'}, body:'{}'})
              .then(function(r){ return r.json(); })
              .then(function(j){
                if (j && j.ok){
                  if (msg){ msg.textContent = '🌧 폭우 소환! −' + (j.spent || RAIN_COST) + ' XP · 30~60분';
                    msg.style.color = 'var(--lv-cyan)'; }
                  render(j);   // gauges drop in place; render re-evaluates affordability
                } else {
                  if (msg){ msg.textContent = (j && j.error) ? j.error : '소환 실패';
                    msg.style.color = 'var(--lv-red)'; }
                  if (btn) btn.disabled = false;
                }
              })
              .catch(function(){
                if (msg){ msg.textContent = '요청 실패'; msg.style.color = 'var(--lv-red)'; }
                if (btn) btn.disabled = false;
              });
          }

          function load(){
            fetch('/api/equipment').then(function(r){ return r.json(); }).then(render).catch(function(){});
          }
          function devAward(){
            fetch('/api/equipment/pomodoro', {method:'POST',
              headers:{'Content-Type':'application/json'}, body:'{}'})
              .then(function(r){ return r.json(); }).then(render).catch(function(){});
          }
          load();
          setInterval(load, 15000);
          </script>

          <script>
          // 도트(픽셀아트) 아바타 — 사자 전사 + 늑대 동료 + 조약돌 바닥 씬. 외부 라이브러리
          // 없이 캔버스 하나로 그린다(오프라인 안전). 스프라이트는 코드에서 1:1 픽셀로
          // 조립한 뒤(자동 외곽선 포함) 4x로 확대 블릿; 애니메이션은 ~8fps 틱으로 도트
          // 게임 감성을 유지한다. 인터랙션: 시선 글린트가 마우스를 따라오고, 사자를
          // 두드리면 스쿼시+이모지, 늑대를 두드리면 폴짝 뛴다.
          (function(){
            var cv = document.getElementById('cv3d');
            if (!cv || !cv.getContext) return;
            var CW = 230, CH = 352, S = 4;                  // css size, art pixel scale
            var DPR = Math.min(window.devicePixelRatio || 1, 2);
            cv.width = CW * DPR; cv.height = CH * DPR;
            var ctx = cv.getContext('2d');
            ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
            ctx.imageSmoothingEnabled = false;

            // ---- sprite factory: paint at 1:1, then auto-outline every filled region ----
            function mkSprite(w, h, paint){
              var c = document.createElement('canvas'); c.width = w; c.height = h;
              var x = c.getContext('2d');
              function put(px, py, col){ if (px >= 0 && py >= 0 && px < w && py < h){ x.fillStyle = col; x.fillRect(px|0, py|0, 1, 1); } }
              function disc(cx2, cy2, r, col){ for (var py = Math.floor(cy2-r); py <= cy2+r; py++) for (var px = Math.floor(cx2-r); px <= cx2+r; px++){ var ddx = px-cx2, ddy = py-cy2; if (ddx*ddx + ddy*ddy <= r*r + 0.4) put(px, py, col); } }
              function box(bx, by, bw, bh, col){ for (var py = by; py < by+bh; py++) for (var px = bx; px < bx+bw; px++) put(px, py, col); }
              paint(put, disc, box);
              // auto outline: transparent px touching a filled px -> dark edge
              var img = x.getImageData(0, 0, w, h), d = img.data;
              function fil(i){ return d[i*4+3] > 10; }
              var edges = [];
              for (var y = 0; y < h; y++) for (var px2 = 0; px2 < w; px2++){
                var i = y*w + px2;
                if (!fil(i) && ((px2 > 0 && fil(i-1)) || (px2 < w-1 && fil(i+1)) || (y > 0 && fil(i-w)) || (y < h-1 && fil(i+w)))) edges.push(i);
              }
              for (var e = 0; e < edges.length; e++){ var k = edges[e]*4; d[k] = 22; d[k+1] = 17; d[k+2] = 10; d[k+3] = 255; }
              x.putImageData(img, 0, 0);
              return c;
            }

            // ---- lion warrior 40x44 (hat / mane / face / sword / shield / gem loincloth) ----
            var LION_W = 40, LION_H = 44;
            var lionSpr = mkSprite(LION_W, LION_H, function(put, disc, box){
              var D='#b5791f', G='#e6a428', L='#f5c85b', F='#f8dc96', W='#fdf3d2',
                  E='#3a230d', N='#a85f38', M='#6b3d20',
                  h='#8a5a32', hx='#684327', hy='#a97a4c',
                  T='#41d2c8', t='#1e9c92',
                  b='#c2cad2', bd='#838d97', g='#7a4a26',
                  s='#8f5f36', sd='#5c3a20', sl='#b07f4e';
              // sword (viewer-left), blade up
              box(2, 22, 2, 12, b); box(3, 22, 1, 12, bd);
              put(2, 21, b); put(2, 20, b); put(3, 21, bd);
              box(0, 34, 7, 2, g); box(2, 36, 2, 4, g); put(2, 40, hx);
              // mane: scalloped ring
              disc(20, 20, 13, D);
              for (var a = 0; a < 10; a++){ var ang = a/10*Math.PI*2;
                disc(20 + Math.cos(ang)*12.5, 20 + Math.sin(ang)*12.5, 3.4, D); }
              disc(20, 20, 11, G);
              disc(14, 12, 2.2, L); disc(20, 10, 2.2, L); disc(26, 12, 2.2, L);   // top highlights
              // face
              disc(20, 22, 8.4, F);
              disc(14, 26, 2, W); disc(26, 26, 2, W);                              // cheeks
              disc(20, 26, 4.4, W);                                                // muzzle
              // fierce brows + eyes
              put(13, 17, E); put(14, 17, E); put(15, 18, E); put(16, 18, E);
              put(26, 17, E); put(25, 17, E); put(24, 18, E); put(23, 18, E);
              box(14, 19, 2, 2, E); box(24, 19, 2, 2, E);
              // nose + mouth
              box(19, 24, 3, 2, N); put(20, 26, M); put(19, 27, M); put(21, 27, M);
              // hat: dome + bent tip + brim with teal band
              disc(20, 7, 6.4, h);
              box(24, 3, 2, 5, hx);
              box(18, 1, 3, 3, h); put(17, 0, hx); put(18, 0, h); put(19, 1, hy);
              box(9, 12, 23, 3, h); box(9, 14, 23, 1, hx); box(11, 11, 19, 1, hy);
              box(9, 12, 23, 1, t); put(14, 12, T); put(20, 12, T); put(26, 12, T);
              // body + belly
              box(14, 32, 13, 9, G); box(14, 32, 1, 9, D); box(26, 32, 1, 9, D);
              box(17, 33, 7, 5, F);
              // right arm to sword grip
              box(9, 33, 5, 3, G); box(5, 35, 5, 3, G); disc(4, 37, 1.8, F);
              // gem loincloth (inverted triangle)
              box(15, 37, 11, 1, t); box(16, 38, 9, 1, t); box(17, 39, 7, 1, t);
              box(18, 40, 5, 1, t); box(19, 41, 3, 1, t);
              box(19, 37, 2, 2, T); put(20, 39, T);
              // feet + tail curl
              box(13, 41, 5, 3, G); box(23, 41, 5, 3, G);
              put(14, 41, L); put(16, 41, L); put(24, 41, L); put(26, 41, L);
              put(11, 41, G); put(10, 42, G); put(11, 43, D);
              // shield (viewer-right) over body edge
              disc(34, 31, 5.2, sd); disc(34, 37, 5.2, sd); box(29, 31, 11, 6, sd);
              disc(34, 31, 4.2, s); disc(34, 37, 4.2, s); box(30, 31, 9, 6, s);
              box(32, 28, 1, 12, sl); box(35, 27, 1, 13, sd);
            });

            // ---- wolf companion 20x18, two tail frames ----
            function wolfPaint(tailUp){ return function(put, disc, box){
              var w = '#9a8d7a', wd = '#6e6252', wl = '#c9bfae', cr = '#e8e2d4', E = '#2c1e10';
              if (tailUp){ put(2, 4, wl); put(1, 5, w); put(2, 6, w); put(2, 7, wd); }
              else { put(1, 7, w); put(2, 7, wl); put(2, 8, w); put(1, 6, wd); }
              box(3, 8, 12, 6, w); box(3, 13, 12, 1, wd);
              box(4, 14, 2, 3, w); box(7, 14, 2, 3, wd); box(10, 14, 2, 3, w); box(13, 14, 2, 3, wd);
              disc(13, 6, 4.4, w);
              put(10, 1, wd); put(10, 2, w); put(11, 2, w); put(16, 1, wd); put(16, 2, w); put(15, 2, w);
              disc(13, 8, 2.4, cr); box(12, 3, 3, 2, wl);
              put(11, 5, E); put(15, 5, E); put(13, 8, E);
            }; }
            var wolfA = mkSprite(20, 18, wolfPaint(true));
            var wolfB = mkSprite(20, 18, wolfPaint(false));

            // ---- cobblestone background (soft, like the reference) + vignette + level glow ----
            var bg = document.createElement('canvas'); bg.width = CW * DPR; bg.height = CH * DPR;
            var glowRGB = '51,201,230', glowLv = 0;
            function drawBG(){
              var x = bg.getContext('2d');
              x.setTransform(DPR, 0, 0, DPR, 0, 0);
              x.fillStyle = '#71808c'; x.fillRect(0, 0, CW, CH);
              var SW = 40, SH = 28, GAP = 3, tones = ['#75848f', '#6d7c87', '#7c8b97'];
              for (var row = -1; row < Math.ceil(CH/(SH+GAP)) + 1; row++){
                var off = (row % 2) ? -SW/2 : 0;
                for (var col = -1; col < Math.ceil(CW/(SW+GAP)) + 1; col++){
                  var sx = col*(SW+GAP) + off, sy2 = row*(SH+GAP);
                  x.fillStyle = '#5a6773';
                  x.beginPath(); x.roundRect(sx-1, sy2-1, SW+2, SH+2, 9); x.fill();
                  x.fillStyle = tones[((row*7 + col*5) % 3 + 3) % 3];
                  x.beginPath(); x.roundRect(sx, sy2, SW, SH, 8); x.fill();
                  x.fillStyle = 'rgba(255,255,255,.07)';
                  x.beginPath(); x.roundRect(sx+3, sy2+2, SW-6, 6, 4); x.fill();
                }
              }
              var vg = x.createRadialGradient(CW/2, CH*0.45, 60, CW/2, CH*0.5, 240);
              vg.addColorStop(0, 'rgba(0,0,0,0)'); vg.addColorStop(1, 'rgba(10,14,20,.42)');
              x.fillStyle = vg; x.fillRect(0, 0, CW, CH);
              var gl = x.createRadialGradient(CW/2, 150, 10, CW/2, 150, 170);
              gl.addColorStop(0, 'rgba(' + glowRGB + ',' + (0.10 + glowLv*0.015) + ')');
              gl.addColorStop(1, 'rgba(' + glowRGB + ',0)');
              x.fillStyle = gl; x.fillRect(0, 0, CW, CH);
            }
            drawBG();

            // ---- scene layout (css px), interaction state ----
            var LX = 24, LY = 116, LW2 = LION_W*S, LH2 = LION_H*S;    // lion blit box
            var WX = 152, WY = 234, WW = 20*S, WH = 18*S;             // wolf blit box
            var look = {x: 0, y: 0}, bob = 0, tickN = 0;
            var lionBlinkAt = -99, wolfHopAt = -99, bonkAt = -99;
            var EMO = ['🦁', '💢', '⚔️', '❤️'], emoI = 0;

            document.addEventListener('pointermove', function(e){
              var r = cv.getBoundingClientRect();
              look.x = Math.max(-1, Math.min(1, (e.clientX - (r.left + LX + LW2/2)) / 120));
              look.y = Math.max(-1, Math.min(1, (e.clientY - (r.top + LY + 90)) / 140));
            });
            cv.addEventListener('click', function(e){
              var r = cv.getBoundingClientRect(), px = e.clientX - r.left, py = e.clientY - r.top;
              var fig2 = document.getElementById('fig');
              function pop(txt){
                var p = document.createElement('div');
                p.className = 'pop3d'; p.textContent = txt;
                p.style.left = (px - 9) + 'px'; p.style.top = (py - 26) + 'px';
                fig2.appendChild(p);
                p.addEventListener('animationend', function(){ p.remove(); });
              }
              // 쓰다듬기: any character hit grants +1 XP to the weakest gear (server-side).
              function tapXP(){
                var xp = document.createElement('div');
                xp.className = 'popxp'; xp.textContent = '+1 XP';
                xp.style.left = (px + 10) + 'px'; xp.style.top = (py - 6) + 'px';
                fig2.appendChild(xp);
                xp.addEventListener('animationend', function(){ xp.remove(); });
                fetch('/api/equipment/tap', {method:'POST',
                  headers:{'Content-Type':'application/json'}, body:'{}'})
                  .then(function(r){ return r.json(); })
                  .then(function(j){ if (j && j.categories) render(j); })
                  .catch(function(){});
              }
              if (px >= LX && px <= LX + LW2 && py >= LY && py <= LY + LH2){
                bonkAt = tickN; pop(EMO[emoI++ % EMO.length]); tapXP();
              } else if (px >= WX && px <= WX + WW && py >= WY && py <= WY + WH){
                wolfHopAt = tickN; pop('🐺'); tapXP();
              }
            });

            function frame(){
              tickN++;
              ctx.clearRect(0, 0, CW, CH);
              ctx.drawImage(bg, 0, 0, CW, CH);
              // contact shadows
              ctx.fillStyle = 'rgba(20,26,34,.30)';
              ctx.beginPath(); ctx.ellipse(LX + LW2/2, LY + LH2 + 4, 66, 10, 0, 0, Math.PI*2); ctx.fill();
              ctx.beginPath(); ctx.ellipse(WX + WW/2, WY + WH + 3, 34, 7, 0, 0, Math.PI*2); ctx.fill();
              // wolf: tail wag + occasional hop
              var hop = (tickN - wolfHopAt < 3) ? 10 : 0;
              ctx.drawImage((tickN >> 2) % 2 ? wolfA : wolfB, WX, WY - hop, WW, WH);
              // lion: idle bob (1 art px), bonk squash
              bob = ((tickN >> 3) % 2) ? S : 0;
              var sy = 1, p = (tickN - bonkAt) / 5;
              if (p >= 0 && p < 1) sy = 1 - 0.16 * Math.sin(p * Math.PI);
              var lh = LH2 * sy;
              ctx.drawImage(lionSpr, LX, LY + bob + (LH2 - lh), LW2, lh);
              // eye glints track the pointer (skip mid-blink: eyes covered with face color)
              if (tickN - lionBlinkAt < 2){
                ctx.fillStyle = '#f8dc96';
                ctx.fillRect(LX + 14*S, LY + bob + 19*S, 2*S, 2*S);
                ctx.fillRect(LX + 24*S, LY + bob + 19*S, 2*S, 2*S);
              } else {
                var gx = look.x > 0.33 ? 1 : 0, gy = look.y > 0.33 ? 1 : 0;
                ctx.fillStyle = '#fdf3d2';
                ctx.fillRect(LX + (14 + gx)*S, LY + bob + (19 + gy)*S, S, S);
                ctx.fillRect(LX + (24 + gx)*S, LY + bob + (19 + gy)*S, S, S);
              }
              if (tickN % 40 === 0 && Math.random() < 0.7) lionBlinkAt = tickN;
            }

            var timer = 0;
            function start(){ if (!timer) timer = setInterval(frame, 120); }
            function stop(){ if (timer){ clearInterval(timer); timer = 0; } }
            document.addEventListener('visibilitychange', function(){ document.hidden ? stop() : start(); });

            // level color -> scene glow (called from render())
            window.CM3D = { setGlow: function(rgb, overall){
              glowRGB = rgb || glowRGB; glowLv = overall || 0; drawBG();
            }};
            frame(); start();
          })();
          </script>
        </body></html>
        """#
    }
}
