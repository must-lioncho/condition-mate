import Foundation

// GET /slack-translate — Slack 👀 번역함: messages the user reacted :eyes: to in
// Slack — plus messages that @mention the user (item.source == "mention", no
// trigger emoji so 처리완료 skips the Slack reaction sync) and messages saved
// with Slack's 'Save for later' (item.later == true; 미처리 뷰에서 📌 Later
// 접이식 섹션으로 그룹핑 — 세그 토글은 미처리/전체 2개를 유지한다) — auto-translated by
// the slack-eyes daemon into the 목표 언어 the user picks in the toolbar
// (config.json "lang", default 한국어; already-in-target messages are shown
// untranslated). 1차 번역 + 2차 의미 분석: the daemon collects thread/channel
// context and the item carries `meaning` (컨텍스트 기반 의미 설명, "컨텍스트
// 부족:" 시작 시 수집 실패) and `decision` (의사결정 선택지).
// (Daemon/slack-eyes-daemon.mjs, Socket Mode listener + LLM translation.)
// 목록은 기본 전부 접힘 — 항목당 한 줄(채널·작성자·시각·본문 첫 줄 말줄임)만 보여
// 스크롤 없이 훑을 수 있게 하고, 행을 클릭하면 원문·의미 분석·의사결정·내 답장이
// 펼쳐진다 (펼친 뒤엔 메타 줄 클릭으로만 접힘 — 본문 텍스트 선택 보호). 펼침
// 상태는 화면 메모리에만 두어 페이지를 다시 열면 다시 전부 접힌다.
// Data contracts and file ownership: see SlackTranslateStore's header.
public enum SlackTranslateContent {

    // Extra HTML injected into <head> by the host app — the Condition Manager
    // passes CMTimeFilter.bootHTML() so timestamps honor the app's display
    // timezone. Standalone runs fall back to a local-timezone shim (below).
    public static var headExtraHTML: () -> String = { "" }

    public static func html() -> String {
        return #"""
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Slack 번역</title>
        \#(headExtraHTML())
        <style>
          :root{
            --bg:#0e1116; --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3;
            --accent:#5b8cff; --card:#0f141d;
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
          main{ max-width:860px; margin:0 auto; padding:18px 20px 80px }
          .toolbar{ display:flex; align-items:center; gap:10px; margin-bottom:14px; flex-wrap:wrap }
          /* 수집 기준 콤보박스 — 대시보드 유형/루프 필터와 같은 체크 드롭다운 패턴.
             해제하면 데몬이 그 소스를 앞으로 수집하지 않는다 (기존 항목 유지). */
          .combo{ display:inline-flex; align-items:center; gap:7px; background:transparent;
            border:1px solid var(--line); border-radius:9px; color:var(--fg); font-size:12px;
            font-weight:600; padding:4px 12px; cursor:pointer }
          .combo:hover{ border-color:#2f6bff }
          .combo.active{ border-color:var(--accent); color:var(--accent) }
          .combo .cv{ color:var(--mut); font-size:10px; line-height:1 }
          .combo.active .cv{ color:var(--accent) }
          .combo .cbadge{ background:rgba(91,140,255,.22); color:#cdddff; font-size:11px;
            font-weight:700; min-width:18px; height:18px; line-height:18px; text-align:center;
            border-radius:5px; padding:0 5px }
          .popup{ position:fixed; z-index:50; background:#171c28; border:1px solid var(--line);
            border-radius:8px; padding:4px; min-width:170px; max-height:60vh; overflow:auto;
            box-shadow:0 10px 28px rgba(0,0,0,.5) }
          .popup .pophdr{ font-size:11px; color:var(--mut); padding:5px 9px }
          .popup .popitem{ display:block; width:100%; text-align:left; background:none;
            border:none; color:var(--fg); padding:7px 10px; font-size:13px; border-radius:6px;
            cursor:pointer; white-space:nowrap }
          .popup .popitem:hover{ background:#1d2230 }
          .popup .popitem.chk{ display:flex; align-items:center; gap:9px }
          .popup .popitem.chk .cbx{ width:15px; height:15px; border:1.5px solid var(--line);
            border-radius:4px; flex:0 0 auto; display:inline-flex; align-items:center;
            justify-content:center; font-size:11px; color:#091022; line-height:1 }
          .popup .popitem.chk.on .cbx{ background:var(--accent); border-color:var(--accent) }
          .popup .popitem.chk.on .cbx::after{ content:'✓' }
          .popdiv{ height:1px; background:var(--line); margin:5px 6px }
          .ckmenu{ min-width:186px }
          .seg{ display:flex; border:1px solid var(--line); border-radius:9px; overflow:hidden }
          .seg button{ background:transparent; color:var(--mut); border:0; padding:5px 14px;
            font-size:12px; cursor:pointer }
          .seg button.on{ background:#1f3a75; color:#9ec1ff }
          .count{ color:var(--mut); font-size:12px; margin-left:auto }
          .toolbar .speak{ background:#1f3a75; color:#9ec1ff; border:0; border-radius:9px;
            padding:5px 14px; font-size:12px; cursor:pointer }
          .toolbar .speak:hover{ background:#264a94 }
          .toolbar .st{ font-size:11px; color:var(--mut) }
          .toolbar select{ background:#141a24; color:var(--fg); border:1px solid var(--line);
            border-radius:9px; padding:4px 8px; font-size:12px; cursor:pointer }
          .toolbar .dbg{ background:transparent; border:1px solid var(--line); border-radius:9px;
            color:var(--mut); font-size:12px; padding:4px 12px; cursor:pointer }
          .toolbar .dbg.on{ color:#f0a045; border-color:#f0a045 }
          .dbgbadge{ color:#f0a045; font-size:10.5px; border:1px solid #3a2f1c;
            border-radius:6px; padding:0 6px }
          /* 배너 안 동기화 실패 목록 (연결 상태와 한 칩·한 배너로 합쳐졌다) */
          .hbanner .serr{ border-top:1px solid #5d4526; margin:8px 0; padding-top:8px;
            font-size:12px; color:var(--fg); line-height:1.6 }
          .hbanner .serr-row{ color:var(--mut); font-size:11.5px; margin-top:3px }
          /* 데몬 연결 상태 칩 — 항상 보인다. 신호등(빨강/녹색) 대신 중립 + 대기=보라,
             사용자 행동이 필요할 때만 주의색(주황). */
          .hchip{ display:inline-flex; align-items:center; gap:5px; font-size:11.5px;
            color:var(--mut); border:1px solid var(--line); border-radius:9px;
            padding:3px 10px; cursor:pointer; user-select:none }
          .hchip .dot{ width:6px; height:6px; border-radius:50%; background:#586173 }
          .hchip.ok{ color:#8fa3c0 } .hchip.ok .dot{ background:#4f7fd6 }
          .hchip.wait{ color:#b9a3ff; border-color:#3c3560 }
          .hchip.wait .dot{ background:#b9a3ff; animation:hpulse 1.4s ease-in-out infinite }
          .hchip.warn{ color:#f0a045; border-color:#5d4526 }
          .hchip.warn .dot{ background:#f0a045 }
          @keyframes hpulse{ 0%,100%{ opacity:1 } 50%{ opacity:.25 } }
          /* 안내 — 앱이 스스로 못 고치는 경우에만 나타난다 */
          .hbanner{ background:#1a1509; border:1px solid #5d4526; border-radius:10px;
            padding:12px 14px; margin-bottom:14px }
          .hbanner h3{ margin:0 0 4px; font-size:13px; color:#f0a045; font-weight:700 }
          .hbanner p{ margin:0 0 8px; font-size:12.5px; color:var(--fg); line-height:1.6;
            white-space:pre-wrap }
          .hbanner .why{ color:var(--mut); font-size:11.5px; margin-bottom:6px }
          .hbanner .row{ display:flex; align-items:center; gap:8px; flex-wrap:wrap }
          .hbanner button{ background:#3a2f1c; color:#f0c187; border:0; border-radius:8px;
            padding:5px 14px; font-size:12px; cursor:pointer }
          .hbanner button:hover{ background:#4b3c22 }
          .hbanner button.ghost{ background:transparent; border:1px solid var(--line);
            color:var(--mut) }
          .hbanner code{ display:block; margin-top:8px; background:#0c1017; border:1px solid var(--line);
            border-radius:8px; padding:7px 10px; font-size:11px; color:#9ec1ff;
            white-space:pre-wrap; word-break:break-all; cursor:pointer }
          .dbgpanel{ background:#12161f; border:1px solid #3a2f1c; border-radius:10px;
            padding:10px 12px; margin-bottom:14px; font-size:11px }
          .dbgpanel h3{ margin:0 0 6px; font-size:11px; color:#f0a045; font-weight:700 }
          .dbgpanel .scroll{ max-height:240px; overflow:auto }
          .dbgpanel table{ width:100%; border-collapse:collapse }
          .dbgpanel td{ padding:2px 6px; color:var(--mut); white-space:nowrap;
            border-top:1px solid #1a2029; font-size:11px }
          .dbgpanel tr:first-child td{ border-top:0 }
          .dbgpanel td.ms{ text-align:right; color:var(--fg); font-variant-numeric:tabular-nums }
          .dbgpanel td.ok{ color:#7bd88f }
          .dbgpanel td.bad{ color:#f0857a; white-space:normal; word-break:break-all }
          .dbgpanel td.dt{ white-space:normal; word-break:break-all; color:#5f6a7d }
          .item .err button{ margin-left:8px; background:transparent; border:1px solid #7a3b36;
            border-radius:6px; color:#f0857a; font-size:10.5px; padding:1px 8px; cursor:pointer }
          .item{ position:relative; background:var(--panel); border:1px solid var(--line);
            border-radius:12px; padding:14px 16px; margin-bottom:12px; transition:opacity .2s }
          .item.done{ opacity:.45 }
          /* 접힘(기본) — 한 줄 요약만: 메타 + 본문 첫 줄 말줄임. 클릭하면 펼쳐진다.
             메시지가 길어 스크롤이 과도해지는 문제를 스캔 가능한 목록으로 푼다. */
          .item.collapsed{ display:flex; align-items:center; gap:10px; overflow:hidden;
            padding:8px 46px 8px 12px; margin-bottom:6px; cursor:pointer }
          .item.collapsed:hover{ border-color:#2f6bff }
          .item.collapsed .meta{ margin-bottom:0; flex:0 0 auto; flex-wrap:nowrap;
            max-width:56%; overflow:hidden }
          .item.collapsed .meta > span{ overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          .item.collapsed .ko{ flex:1 1 auto; min-width:0; font-size:13px; color:var(--mut);
            white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .item.collapsed .en, .item.collapsed .meaning, .item.collapsed .decision,
          .item.collapsed .myreply, .item.collapsed .pend, .item.collapsed .err{ display:none }
          .item.collapsed .done-tag{ margin-left:0 }
          /* 호버 액션 툴바 — 접힘 행에선 위로 튀어나오지 않게 우측 세로 중앙에 붙인다 */
          .item.collapsed > .acts{ top:50%; transform:translateY(-50%); right:8px; background:transparent;
            border:0; box-shadow:none; padding:0 }
          .item .caret{ color:var(--mut); font-size:9px; width:9px; flex:0 0 auto }
          /* 접힘일 때만 보이는 요약 배지 (답장 수 · 경고 · 번역 중) */
          .item .ctag{ display:none; font-size:10.5px }
          .item.collapsed .ctag{ display:inline }
          .item .ctag.warn{ color:#f0a045 }
          .item .ctag.rep{ color:#9ec1ff }
          /* Slack식 호버 액션 툴바 (메시지 항목 + 내 답장 공용) */
          .acts{ position:absolute; top:-13px; right:14px; display:none; align-items:center;
            gap:1px; background:#1a1f29; border:1px solid var(--line); border-radius:8px;
            padding:2px; box-shadow:0 2px 10px rgba(0,0,0,.4); z-index:6 }
          .item:hover > .acts, .myreply:hover > .acts, .acts.pin{ display:flex }
          .acts > button, .menu-wrap > button{ background:transparent; border:0; color:var(--mut);
            cursor:pointer; font-size:14px; line-height:1; padding:5px 7px; border-radius:6px;
            display:inline-flex; align-items:center }
          .acts > button:hover, .menu-wrap > button:hover{ background:#232b38; color:var(--fg) }
          .acts > button.on{ color:#7bd88f }
          .menu-wrap{ position:relative; display:inline-flex }
          .menu{ position:absolute; top:calc(100% + 5px); right:0; display:none; flex-direction:column;
            min-width:138px; background:#1a1f29; border:1px solid var(--line); border-radius:9px;
            padding:4px; box-shadow:0 8px 22px rgba(0,0,0,.5); z-index:25 }
          .menu.open{ display:flex }
          .menu button, .menu a{ background:transparent; border:0; color:var(--fg); text-align:left;
            padding:7px 11px; border-radius:6px; font-size:12.5px; cursor:pointer;
            text-decoration:none; display:block; width:100% }
          .menu button:hover, .menu a:hover{ background:#232b38 }
          .menu button.danger{ color:#f0857a }
          .done-tag{ margin-left:auto; color:#7bd88f; font-size:11px; font-weight:700 }
          .item .meta{ display:flex; align-items:center; gap:8px; flex-wrap:wrap;
            font-size:11.5px; color:var(--mut); margin-bottom:8px }
          .item .meta .ch{ font-weight:700; color:#9ec1ff }
          .item .meta .mtag{ color:#f0c045; border:1px solid #3a2f1c; border-radius:6px;
            padding:0 6px; font-size:10.5px; font-weight:700 }
          /* Later 칩 — 대기 성격이라 보라 계열 (상태색 컨벤션: 대기=보라) */
          .item .meta .ltag{ color:#b9a3ff; border:1px solid #33285a; border-radius:6px;
            padding:0 6px; font-size:10.5px; font-weight:700 }
          /* 재트리거 칩 — 리액션을 다시 달아 미처리로 돌아온 항목 (대기=보라 계열) */
          .item .meta .rtag{ color:#b9a3ff; border:1px solid #33285a; border-radius:6px;
            padding:0 6px; font-size:10.5px; font-weight:700 }
          /* 이모지 자동 해결 칩 — 완료 성격이라 초록 계열 (처리완료 라벨과 같은 색) */
          .item .meta .atag{ color:#7bd88f; border:1px solid #234a2e; border-radius:6px;
            padding:0 6px; font-size:10.5px; font-weight:700 }
          /* 미처리 뷰의 📌 Later 접이식 섹션 헤더 */
          .sechdr{ display:flex; align-items:center; gap:8px; margin:20px 0 10px;
            cursor:pointer; user-select:none; color:#b9a3ff; font-size:12.5px; font-weight:700 }
          .sechdr .n{ background:rgba(150,120,255,.16); border-radius:5px; padding:0 7px;
            font-size:11px; min-width:18px; text-align:center }
          .sechdr .arrow{ color:var(--mut); font-size:10px }
          .sechdr::after{ content:''; flex:1; height:1px; background:var(--line) }
          .item .meta .au{ color:var(--fg) }
          .item .meta a{ color:var(--accent); text-decoration:none }
          .item .meta .chk{ margin-left:auto; display:flex; align-items:center; gap:5px;
            cursor:pointer; user-select:none }
          .item .ko{ font-size:14px; white-space:pre-wrap; word-break:break-word }
          .item .en{ font-size:12px; color:var(--mut); white-space:pre-wrap; word-break:break-word;
            margin-top:8px; padding-top:8px; border-top:1px dashed var(--line) }
          .item .meaning{ margin-top:10px; padding:9px 12px; background:#0e1a20;
            border-left:3px solid #4ac1b8; border-radius:0 9px 9px 0; font-size:13px;
            white-space:pre-wrap; word-break:break-word }
          .item .meaning .mn-head{ font-size:10.5px; color:#4ac1b8; font-weight:700;
            margin-bottom:4px }
          .item .decision{ margin-top:10px; padding:9px 12px; background:#101a2c;
            border-left:3px solid #f0c045; border-radius:0 9px 9px 0; font-size:13px;
            white-space:pre-wrap; word-break:break-word }
          .item .decision .dc-head{ font-size:10.5px; color:#f0c045; font-weight:700;
            margin-bottom:4px }
          .item .err{ color:#f0a045; font-size:11.5px; margin-top:6px }
          .item .pend{ color:#9ec1ff; font-size:11.5px; margin-top:6px }
          .item .pend i{ display:inline-block; width:9px; height:9px; border:2px solid #2f6bff;
            border-top-color:transparent; border-radius:50%; margin-right:5px; vertical-align:-1px;
            animation:spin 1s linear infinite }
          @keyframes spin{ to{ transform:rotate(360deg) } }
          .empty{ text-align:center; color:var(--mut); padding:60px 0; font-size:13px }
          .rp-btn{ background:transparent; border:1px solid var(--line); border-radius:7px;
            color:var(--mut); font-size:11px; padding:2px 10px; cursor:pointer }
          .rp-btn:hover{ color:#9ec1ff; border-color:#2f6bff }
          .reply-box{ margin-top:10px; padding-top:10px; border-top:1px dashed var(--line) }
          .reply-box textarea{ width:100%; min-height:64px; background:#0c1017;
            border:1px solid var(--line); border-radius:9px; color:var(--fg); padding:8px 10px;
            font:13px/1.5 inherit; resize:vertical }
          .reply-box .row{ display:flex; align-items:center; gap:8px; margin-top:6px }
          .reply-box .hint{ font-size:10.5px; color:var(--mut) }
          .reply-box .mchk{ display:flex; align-items:center; gap:4px; cursor:pointer }
          .reply-box .mchk input{ accent-color:#2f6bff; margin:0 }
          .reply-box .send{ margin-left:auto; background:#1f3a75; color:#9ec1ff; border:0;
            border-radius:8px; padding:5px 16px; font-size:12px; cursor:pointer }
          .reply-box .send:disabled{ opacity:.5; cursor:default }
          .reply-box .gui{ margin-left:auto; background:transparent; border:1px solid var(--line);
            border-radius:8px; color:var(--mut); padding:4px 12px; font-size:12px; cursor:pointer }
          .reply-box .gui:hover{ color:#9ec1ff; border-color:#2f6bff }
          .reply-box .gui ~ .send{ margin-left:0 }
          .reply-box .st{ font-size:11.5px }
          .reply-box .st.ok{ color:#7bd88f } .reply-box .st.bad{ color:#f0a045 }
          .myreply{ position:relative; margin-top:10px; padding:8px 12px; background:#0c1220;
            border-left:3px solid #2f6bff; border-radius:0 9px 9px 0 }
          .myreply .mr-head{ display:flex; align-items:center; gap:8px; font-size:10.5px;
            color:var(--mut); margin-bottom:4px }
          .myreply .mr-tag{ color:#9ec1ff; font-weight:700 }
          .myreply .mr-edit{ margin-left:auto; background:transparent; border:1px solid var(--line);
            border-radius:6px; color:var(--mut); font-size:10px; padding:1px 8px; cursor:pointer }
          .myreply .mr-edit:hover{ color:#9ec1ff; border-color:#2f6bff }
          .myreply .mr-del:hover{ color:#f0857a; border-color:#7a3b36 }
          .myreply .mr-del.armed{ color:#f0857a; border-color:#7a3b36 }
          .myreply .mr-text{ font-size:13px; white-space:pre-wrap; word-break:break-word }
        </style></head><body>
        <header>
          <div><h1>Slack 번역</h1>
            <div class="sub">👀 리액션 · @나/@팀 멘션 · DM · @here/@channel · 🔖/📌 = Later · 자동 번역 + 의미 분석</div></div>
          <a href="/">← 대시보드</a>
        </header>
        <main>
          <div class="toolbar">
            <div class="seg">
              <button id="fOpen" class="on" onclick="setFilter('open')">미처리</button>
              <button id="fAll" onclick="setFilter('all')">전체</button>
            </div>
            <button class="dbg" id="expBtn" onclick="toggleAll()"
              title="모든 항목을 펼치거나 다시 한 줄로 접습니다 (개별 항목은 클릭으로 펼침)">모두 펼치기</button>
            <button class="combo" id="srcCombo" onclick="openSrcMenu(event)"
              title="어떤 메시지를 이 페이지에 수집할지 선택 (다중 선택) — 해제하면 앞으로 뜨지 않습니다 (이미 수집된 항목은 유지)">
              수집 기준<span class="cbadge" id="srcCnt">6</span> <span class="cv">▾</span></button>
            <select id="langSel" onchange="setLang(this.value)"
              title="번역 목표 언어 — 메시지가 이미 이 언어면 번역하지 않습니다 (새로 수집되는 항목부터 적용)">
              <option value="ko">🌐 한국어</option>
              <option value="en">🌐 English</option>
              <option value="vi">🌐 Tiếng Việt</option>
              <option value="ja">🌐 日本語</option>
              <option value="zh">🌐 中文</option>
            </select>
            <select id="modelSel" onchange="setModel(this.value)"
              title="번역에 쓸 모델 — 데몬 재시작 없이 즉시 적용됩니다">
              <option value="gemini-flash-lite">Gemini Flash-Lite · ~1초 (기본)</option>
              <option value="gemini-flash">Gemini Flash</option>
              <option value="haiku-api">Claude Haiku · API 직통 ~1초</option>
              <option value="haiku">Claude Haiku · CLI 구독</option>
              <option value="auto">자동 (빠른 키 있으면 우선)</option>
            </select>
            <span class="st" id="modelSt"></span>
            <button class="speak" onclick="startSpeaking(this)"
              title="최근 스레드 컨텍스트로 ChatGPT 스피킹 연습을 시작합니다">🎙 스피킹 시작</button>
            <span class="st" id="speakSt"></span>
            <button class="dbg" id="dbgBtn" style="display:none" onclick="toggleDbg()"
              title="항목별 번역 모델·소요시간 + 액션 로그 패널 표시">디버그</button>
            <span class="hchip" id="hChip" onclick="toggleHealth()"
              title="슬랙 수집 연결 상태 — 클릭하면 자세히"><span class="dot"></span><span id="hChipT">확인 중</span></span>
            <span class="hchip" id="pChip" style="display:none" onclick="toggleHealth()"
              ><span class="dot"></span><span id="pChipT"></span></span>
            <span class="count" id="count"></span>
          </div>
          <div class="hbanner" id="hBanner" style="display:none"></div>
          <div class="popup" id="popup" style="display:none"></div>
          <div class="dbgpanel" id="dbgPanel" style="display:none"></div>
          <div id="list"><div class="empty">불러오는 중…</div></div>
        </main>
        <script>
        // 독립 실행 폴백 — 호스트 앱이 headExtraHTML로 CMTimeFilter(표시 타임존)를
        // 주입하지 않았을 때만 로컬 타임존으로 대체한다 (앱 안에서는 항상 주입됨).
        if (!window.CMTimeFilter) window.CMTimeFilter = { parts: t => { const d = new Date(t);
          return { mo:d.getMonth()+1, d:d.getDate(), h:d.getHours(), mi:d.getMinutes(), s:d.getSeconds() }; } };
        let filter = 'open', cache = null;
        // 📌 Later 섹션 접힘 상태 — 이 브라우저에 기억 (기본 펼침).
        let laterSec = localStorage.getItem('cm.slackLaterSec') !== '0';
        function toggleLaterSec(){
          laterSec = !laterSec;
          localStorage.setItem('cm.slackLaterSec', laterSec ? '1' : '0');
          render();
        }
        // ----- 항목 접기/펼치기 -----
        // 메시지 본문이 길어 목록 스캔이 어려우므로 기본은 전부 접힘(한 줄 요약).
        // 펼친 항목만 이 집합에 담는다 — 폴링 재렌더에는 유지되고, 페이지를 다시
        // 열면 다시 전부 접힌 상태로 시작한다.
        const expanded = new Set();
        function itemEl(id){
          return Array.prototype.find.call(document.querySelectorAll('#list .item'),
            e => e.dataset.id === id);
        }
        function toggleItem(ev, id){
          // 액션 버튼·메뉴·답장 입력 등 자체 동작이 있는 요소의 클릭은 통과시킨다.
          if (ev.target.closest('.acts, .menu, .reply-box, .myreply, a, button, textarea, input, label')) return;
          const on = expanded.has(id);
          // 펼친 뒤에는 헤더(메타 줄)로만 접는다 — 본문 드래그·텍스트 선택 보호.
          if (on && !ev.target.closest('.meta')) return;
          try{ if (String(window.getSelection())) return; }catch(e){}
          if (on) expanded.delete(id); else expanded.add(id);
          render();
        }
        function toggleAll(){
          if (expanded.size) expanded.clear();
          else ((cache&&cache.items)||[]).forEach(it=>expanded.add(it.id));
          render();
        }
        function setFilter(f){
          filter = f;
          document.getElementById('fOpen').classList.toggle('on', f==='open');
          document.getElementById('fAll').classList.toggle('on', f==='all');
          render();
        }
        function esc(s){ const d=document.createElement('div'); d.textContent=s||''; return d.innerHTML; }
        function when(epoch){
          if (!epoch) return '';
          const p = window.CMTimeFilter.parts(epoch*1000);
          return `${p.mo}/${p.d} ${String(p.h).padStart(2,'0')}:${String(p.mi).padStart(2,'0')}`;
        }
        // 트리거 발생 시각 — 목록 정렬·시간 표시의 단일 기준. triggeredAt은 재트리거
        // (제거했다가 다시 리액션) 때 데몬이 갱신한다. 없으면 최초 수집 시각.
        function trigAt(it){ return it.triggeredAt || it.reactedAt || 0; }
        function toggleDone(id, done){
          // Slack UX 그대로 — 낙관적 즉시 반영: 처리완료를 누르면 서버 왕복을 기다리지 않고
          // 곧바로 미처리 목록에서 사라진다(해제 시 다시 나타남). POST/load는 뒤에서 영속·정합만.
          if (cache){
            cache.done = cache.done || {};
            if (done) cache.done[id] = true; else delete cache.done[id];
            render();
          }
          fetch('/api/slack/done',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({id:id, done:done})}).then(load).catch(()=>{});
          // 리액션 동기화는 POST 응답 뒤 비동기로 끝난다 — 결과(성공/실패 경고)를
          // 다음 5초 폴링보다 먼저 보여주도록 한 번 더 당겨 읽는다.
          setTimeout(()=>{ load(); if (dbgOn) loadActions(); }, 2500);
        }
        // 동기화 실패 항목 재시도 — 같은 done 상태로 다시 POST하면 setDone은
        // 멱등이고 syncReaction만 다시 돈다.
        function retrySync(id, done){
          fetch('/api/slack/done',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({id:id, done:done})}).catch(()=>{});
          setTimeout(()=>{ load(); if (dbgOn) loadActions(); }, 2500);
        }
        // 동기화 에러 → 사람이 조치할 수 있는 힌트.
        function syncHint(err){
          if (err==='missing_scope') return ' — 슬랙 앱 사용자 토큰에 reactions:write 스코프가 없습니다. 앱 OAuth 재설치 후 키체인 cm-slack-user-token 갱신 필요';
          if (err==='keychain token missing') return ' — 키체인에 cm-slack-user-token이 없습니다';
          if (err==='network') return ' — 네트워크 오류';
          if (err==='item not found') return ' — items.jsonl에서 항목을 찾지 못했습니다';
          return '';
        }
        // ----- 디버그 모드: 항목별 번역 모델·소요시간 배지 + 액션 로그 패널 -----
        // 노출 자체는 전역 설정(레일 ⚙️ 디버그 버튼)이 결정하고, 켜고 끄는 상태는
        // 이 브라우저에 기억된다(localStorage). 패널은 slack-translate의 모든 액션
        // (완료 토글·리액션 동기화·답장·API 호출)을 소요시간·성공여부와 함께 보여준다.
        let dbgOn = localStorage.getItem('cm.slackDbg') === '1';
        let actionsCache = null;
        function toggleDbg(){
          dbgOn = !dbgOn;
          localStorage.setItem('cm.slackDbg', dbgOn ? '1' : '0');
          if (dbgOn) loadActions();
          reflectDbg(); render();
        }
        function reflectDbg(){
          const b = document.getElementById('dbgBtn');
          b.style.display = cache && cache.debugButtons ? '' : 'none';
          b.classList.toggle('on', dbgOn);
          renderDbgPanel();
        }
        function loadActions(){
          fetch('/api/slack/actions?limit=120').then(r=>r.json())
            .then(j=>{ actionsCache = j.actions || []; renderDbgPanel(); }).catch(()=>{});
        }
        function whenS(epoch){
          const p = window.CMTimeFilter.parts(epoch*1000);
          const z = n => String(n).padStart(2,'0');
          return `${p.mo}/${p.d} ${z(p.h)}:${z(p.mi)}:${z(p.s)}`;
        }
        function renderDbgPanel(){
          const panel = document.getElementById('dbgPanel');
          const show = dbgOn && cache && cache.debugButtons;
          panel.style.display = show ? '' : 'none';
          if (!show) return;
          const rows = (actionsCache||[]).slice().reverse().slice(0,80).map(a=>
            `<tr><td>${whenS(a.at)}</td><td>${esc(a.action)}</td>
             <td class="ms">${a.ms}ms</td>
             <td class="${a.ok?'ok':'bad'}">${a.ok?'✓':'✗ '+esc(a.error||'')}</td>
             <td class="dt">${esc(a.detail||'')}${a.id?' · '+esc(a.id):''}</td></tr>`).join('');
          panel.innerHTML = '<h3>액션 로그 — 모든 액션 · 소요시간 (최신순)</h3>'
            + `<div class="scroll"><table>${rows
              || '<tr><td>아직 기록된 액션이 없습니다</td></tr>'}</table></div>`;
        }
        // ----- 번역 모델 선택: config.json → 데몬이 호출마다 반영 -----
        function reflectModel(){
          const sel = document.getElementById('modelSel');
          if (document.activeElement === sel) return; // 사용자가 여는 중엔 건드리지 않음
          sel.value = cache.model || 'gemini-flash-lite';
          const st = document.getElementById('modelSt');
          let hint = '';
          if (['gemini-flash-lite','gemini-flash'].includes(sel.value) && !cache.geminiKey)
            hint = '⚠ Gemini API 키 필요 (키체인 cm-gemini-api-key)';
          else if (sel.value==='haiku-api' && !cache.anthropicKey)
            hint = '⚠ Anthropic API 키 필요 (키체인 cm-anthropic-api-key)';
          else if (sel.value==='auto' && !cache.geminiKey && !cache.anthropicKey)
            hint = '빠른 모델 키 없음 → CLI Haiku 사용 중';
          st.textContent = hint;
        }
        function setModel(m){
          fetch('/api/slack/config',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({model:m})}).then(()=>load());
        }
        // ----- 번역 목표 언어: config.json → 데몬이 번역 호출마다 반영 -----
        // 이미 목표 언어인 메시지는 데몬이 번역하지 않는다 (원문 그대로).
        // 바꿔도 기존 항목은 그대로 — 새로 수집되는 항목부터 새 언어로 번역된다.
        function reflectLang(){
          const sel = document.getElementById('langSel');
          if (document.activeElement === sel) return; // 사용자가 여는 중엔 건드리지 않음
          sel.value = cache.lang || 'ko';
        }
        function setLang(l){
          fetch('/api/slack/config',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({lang:l})}).then(()=>load());
        }
        // ----- 수집 기준 콤보박스 (대시보드 유형 필터와 같은 체크 드롭다운 패턴) -----
        // config.json sources → 데몬이 이벤트마다 반영. 기본 전부 on (config에 false로
        // 명시된 것만 해제). 해제하면 그 소스는 앞으로 수집되지 않는다 — 이미 목록에
        // 있는 항목은 그대로 남는다. '모두'는 모든 소스를 켠다.
        const SRC_KEYS = ['eyes','mention','team','dm','broadcast','later'];
        const SRC_LABELS = { eyes:'👀 taking a look', mention:'@나 멘션 (직접 멘션)',
          team:'@팀 멘션 (내 유저그룹)', dm:'💬 DM · 그룹 DM',
          broadcast:'📣 @here · @channel', later:'📌 Later (🔖/📌 리액션)' };
        // 항목 줄에 붙는 짧은 배지 (리액션 트리거 항목은 배지 없음).
        const SRC_TAGS = { mention:'@멘션', team:'@팀 멘션', dm:'💬 DM', broadcast:'📣 전체호출' };
        function srcOn(k){ return !cache || !cache.sources || cache.sources[k] !== false; }
        function srcMenuHTML(){
          const all = SRC_KEYS.every(srcOn);
          let h = '<div class="ckmenu"><div class="pophdr">수집 기준 (다중 선택)</div>';
          h += '<button class="popitem chk'+(all?' on':'')+'" onclick="srcAll()"><span class="cbx"></span>모두</button>';
          h += '<div class="popdiv"></div>';
          SRC_KEYS.forEach(k=>{
            h += '<button class="popitem chk'+(srcOn(k)?' on':'')+'" onclick="srcPick(\''+k+'\')"><span class="cbx"></span>'+SRC_LABELS[k]+'</button>';
          });
          return h+'</div>';
        }
        function openSrcMenu(e){
          e.stopPropagation();
          const r = e.currentTarget.getBoundingClientRect();
          showPopup(r.left, r.bottom+4, srcMenuHTML());
        }
        // 토글 후 팝업은 열어 둔 채 내용만 갱신 — 연속 선택을 위해 (대시보드 패턴).
        // 낙관적 즉시 반영 후 POST; load()가 서버 상태로 정합을 맞춘다.
        function postSources(s){
          if (cache) cache.sources = Object.assign({}, cache.sources, s);
          reflectSources(); setPopupHTML(srcMenuHTML());
          fetch('/api/slack/config',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({sources:s})}).then(()=>load()).catch(()=>{});
        }
        function srcPick(k){ postSources({[k]: !srcOn(k)}); }
        function srcAll(){
          const s = {}; SRC_KEYS.forEach(k=>{ s[k] = true; }); postSources(s);
        }
        // 콤보 버튼: 배지 = 켜진 소스 수, 일부만 켜져 있으면 active 강조 (Jira식).
        function reflectSources(){
          const n = SRC_KEYS.filter(srcOn).length;
          document.getElementById('srcCnt').textContent = n;
          document.getElementById('srcCombo').classList.toggle('active', n < SRC_KEYS.length);
        }
        // ----- 팝업 헬퍼 (대시보드 showPopup 축약판 — 바깥 클릭 시 닫힘) -----
        function showPopup(x, y, html){
          const p = document.getElementById('popup');
          p.innerHTML = html; p.style.display = 'block';
          p.style.left = Math.min(x, window.innerWidth - p.offsetWidth - 8)+'px';
          p.style.top = Math.min(y, window.innerHeight - p.offsetHeight - 8)+'px';
          setTimeout(()=>{ document.addEventListener('mousedown', popupOutside); }, 0);
        }
        function popupOutside(e){
          const p = document.getElementById('popup');
          if (p && !p.contains(e.target)) hidePopup();
        }
        function hidePopup(){
          document.getElementById('popup').style.display = 'none';
          document.removeEventListener('mousedown', popupOutside);
        }
        function setPopupHTML(html){ document.getElementById('popup').innerHTML = html; }
        // ----- 스피킹: 브리핑 프롬프트 조립 → ChatGPT 웹 자동 주입 -----
        function startSpeaking(btn){
          btn.disabled = true;
          const st = document.getElementById('speakSt');
          st.textContent = '여는 중…';
          fetch('/api/slack/speak',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})
            .then(r=>r.json()).then(j=>{
              st.textContent = j.mode==='clipboard'
                ? 'ChatGPT가 열리면 ⌘V로 붙여넣고 전송 → 음성 아이콘 탭'
                : '컨텍스트 자동 전송됨 — 음성 아이콘만 탭하세요';
              setTimeout(()=>{ st.textContent=''; }, 8000);
            }).catch(()=>{ st.textContent='실패'; })
            .finally(()=>{ btn.disabled=false; });
        }
        // ----- 스레드 답장: 원 메시지 스레드에 본인 계정으로 그대로 전송 -----
        function openReply(btn, id){
          // 접힌 항목에 답장창을 붙이면 한 줄 레이아웃에 눌리므로 먼저 펼친다
          // (재렌더로 DOM이 새로 그려지니 항목 요소를 다시 찾는다).
          let item = btn.closest('.item');
          if (!expanded.has(id)){ expanded.add(id); render(); item = itemEl(id); }
          if (!item) return;
          const ex = item.querySelector('.reply-box');
          if (ex){ ex.remove(); return; }
          const box = document.createElement('div');
          box.className = 'reply-box';
          box.innerHTML = `<textarea placeholder="스레드에 답장… (쓴 그대로 전송됩니다)"></textarea>
            <div class="row">
            <label class="hint mchk" title="답장 앞에 원 작성자 @멘션을 붙여 알림이 가게 합니다"><input type="checkbox" checked>@작성자 멘션</label>
            <span class="hint">내 계정으로 스레드에 달립니다</span>
            <span class="st"></span>
            <button class="gui"></button>
            <button class="send">전송</button></div>`;
          item.appendChild(box);
          const ta = box.querySelector('textarea');
          ta.focus();
          // 이미 이 메시지로 연 세션이 있으면 새로 만들지 않고 그 세션을 이어간다
          // (연결 대장 cache.gui — 서버 gui-sessions.json).
          const gb = box.querySelector('.gui');
          const lk = guiLink(id);
          gb.textContent = lk ? '세션 이어가기' : 'GUI세션';
          gb.title = lk
            ? '이 메시지로 이미 연 AI 세션(goal-'+pad2(lk.seq)+')을 그대로 이어갑니다 — 그때 넣은 컨텍스트와 대화가 남아 있습니다'
            : '이 메시지의 컨텍스트(번역·의미 분석·의사결정·쓰던 초안)로 AI 세션을 열어 대화로 해결합니다';
          gb.onclick = ()=>guiSession(id, ta.value.trim());
          box.querySelector('.send').onclick = function(){
            const text = ta.value.trim();
            if (!text) return;
            this.disabled = true;
            const st = box.querySelector('.st');
            st.textContent = '전송 중…'; st.className = 'st';
            fetch('/api/slack/reply',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({id:id, text:text,
                mention: box.querySelector('.mchk input').checked})})
              .then(r=>r.json()).then(j=>{
                if (j.ok){ st.textContent='전송됨 ✓'; st.className='st ok';
                  setTimeout(()=>{ box.remove(); load(); }, 1200); }
                else { st.textContent='실패: '+(j.error||''); st.className='st bad';
                  this.disabled=false; }
              }).catch(()=>{ st.textContent='실패: 네트워크'; st.className='st bad';
                this.disabled=false; });
          };
        }
        // ----- GUI세션: 이 메시지의 컨텍스트로 목표를 만들어 goal-add 세션 뷰에서 대화로 푼다 -----
        // 컨텍스트(번역·원문·의미 분석·의사결정·쓰던 답장 초안)를 goal-add 초안 계약
        // (localStorage cm.gaDraft — 같은 오리진)에 담고 ?start=1 로 넘기면, goal-add 가
        // GUI시작을 자동 실행해 첫 턴에 이 컨텍스트가 실린다. 답장은 이 페이지로 돌아와
        // 전송한다 (세션은 답장 초안까지만 제안).
        function pad2(n){ n=parseInt(n,10)||0; return n<10?('0'+n):String(n); }
        // 이 메시지로 연 세션의 연결 기록 ({seq,at}) — 없으면 null.
        function guiLink(id){
          const m = (cache&&cache.gui)||{}; const v = m[id];
          return (v && (v.seq>0)) ? v : null;
        }
        function guiSession(id, draft){
          const it = ((cache&&cache.items)||[]).find(x=>x.id===id); if (!it) return;
          // 이어가기: 이미 세션이 있으면 새 목표를 만들지 않고 그 세션 뷰로 들어간다.
          // 지금 쓰던 초안이 있으면 컴포저에 실어 보낸다 (?prefill=1 — 전송은 사용자가).
          const lk = guiLink(id);
          if (lk){
            try{ if (draft) localStorage.setItem('cm.gaDraft', draft);
                 else localStorage.removeItem('cm.gaDraft'); }catch(e){}
            location.href = '/goal-add?goal='+lk.seq+(draft?'&prefill=1':'');
            return;
          }
          const L = [];
          L.push('Slack 스레드 대응: #'+(it.channelName||it.channel||'')+(it.author?' — '+it.author:''));
          if (it.textKo && it.textKo !== it.textEn){
            L.push('','[번역]',it.textKo,'','[원문]',it.textEn);
          } else {
            L.push('','[메시지]',it.textKo||it.textEn||'');
          }
          if (it.meaning) L.push('','[의미 분석]',it.meaning);
          if (it.decision) L.push('','[의사결정 선택지]',it.decision);
          if (it.permalink) L.push('','[슬랙 링크] '+it.permalink);
          if (draft) L.push('','[작성 중이던 답장 초안]',draft);
          L.push('','위 Slack 스레드 컨텍스트를 파악하고, 대화로 이 문제를 해결하자. 스레드에 보낼 답장이 필요하면 초안을 제안해줘.');
          try{ localStorage.setItem('cm.gaDraft', L.join('\n')); }catch(e){}
          // slackId 를 함께 넘긴다 — goal-add 가 목표를 만든 뒤 이 id 로 세션 연결을
          // 기록하고(POST /api/slack/gui/link), 다음부터 이 버튼은 "세션 이어가기"가 된다.
          location.href = '/goal-add?bump=1&label='+encodeURIComponent('Slack 스레드')
            +'&start=1&slackId='+encodeURIComponent(id);
        }
        // ----- 내 답장 수정: chat.update로 슬랙 원문 자체를 고친다 -----
        function editReply(btn, id, ts){
          const wrap = btn.closest('.myreply');
          if (wrap.classList.contains('mr-editing')) return;
          wrap.classList.add('mr-editing');
          const textDiv = wrap.querySelector('.mr-text');
          // 편집 기준은 슬랙에 실제 전송된 원문 (ledger) — 화면엔 <@U…> 멘션이
          // @이름으로 프리티 렌더되므로 textContent를 그대로 쓰면 멘션이 깨진다.
          const raw = (((cache&&cache.replies)||{})[id]||[]).find(r=>r.ts===ts);
          const orig = raw ? raw.text : textDiv.textContent;
          textDiv.innerHTML = `<textarea style="width:100%;min-height:56px;background:#0c1017;
            border:1px solid var(--line);border-radius:8px;color:var(--fg);padding:7px 9px;
            font:13px/1.5 inherit;resize:vertical"></textarea>
            <div class="row" style="display:flex;gap:8px;margin-top:5px;align-items:center">
              <span class="st" style="font-size:11px"></span>
              <button class="mr-edit" style="margin-left:auto">취소</button>
              <button class="send" style="background:#1f3a75;color:#9ec1ff;border:0;border-radius:7px;
                padding:4px 14px;font-size:11.5px;cursor:pointer">저장</button></div>`;
          const ta = textDiv.querySelector('textarea');
          ta.value = orig; ta.focus();
          textDiv.querySelector('.mr-edit').onclick = ()=>{ load(); wrap.classList.remove('mr-editing'); };
          textDiv.querySelector('.send').onclick = function(){
            const text = ta.value.trim();
            this.disabled = true;
            const st = textDiv.querySelector('.st');
            st.style.color = '';
            // 슬랙 UX 패리티 — 내용을 모두 비우고 저장하면 메시지 삭제.
            const empty = !text;
            st.textContent = empty ? '삭제 중…' : '수정 중…';
            const url = empty ? '/api/slack/reply/delete' : '/api/slack/reply/edit';
            const payload = empty ? {id:id, ts:ts} : {id:id, ts:ts, text:text};
            fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify(payload)})
              .then(r=>r.json()).then(j=>{
                if (j.ok){ wrap.classList.remove('mr-editing'); load(); }
                else { st.textContent='실패: '+(j.error||''); st.style.color='#f0a045'; this.disabled=false; }
              }).catch(()=>{ st.textContent='실패: 네트워크'; st.style.color='#f0a045'; this.disabled=false; });
          };
        }
        // ----- 내 답장 삭제: chat.delete로 슬랙 메시지 자체를 지운다 (2-클릭 확인) -----
        function deleteReply(btn, id, ts){
          const wrap = btn.closest('.myreply');
          if (btn.dataset.armed !== '1'){
            // 1차 클릭 — 확인 대기. confirm() 대화상자는 WKWebView에서 무동작이라 인라인 확인.
            btn.dataset.armed = '1'; btn.textContent = '삭제 확인'; btn.classList.add('armed');
            wrap.classList.add('mr-arming');
            setTimeout(()=>{ if (btn.dataset.armed==='1'){ btn.dataset.armed=''; btn.textContent='삭제';
              btn.classList.remove('armed'); wrap.classList.remove('mr-arming'); } }, 3000);
            return;
          }
          wrap.style.opacity = '.4'; btn.disabled = true;
          fetch('/api/slack/reply/delete',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({id:id, ts:ts})})
            .then(r=>r.json()).then(j=>{
              if (j.ok){ wrap.classList.remove('mr-arming'); closeMenus(); load(); }
              else { wrap.style.opacity=''; btn.disabled=false; btn.dataset.armed='';
                btn.classList.remove('armed'); wrap.classList.remove('mr-arming');
                btn.textContent='실패: '+(j.error||'');
                setTimeout(()=>{ btn.textContent='삭제'; }, 2500); }
            }).catch(()=>{ wrap.style.opacity=''; btn.disabled=false; btn.dataset.armed='';
              btn.classList.remove('armed'); wrap.classList.remove('mr-arming');
              btn.textContent='실패'; setTimeout(()=>{ btn.textContent='삭제'; }, 2500); });
        }
        // ----- 슬랙식 ⋮ 더보기 드롭다운 -----
        function closeMenus(){
          document.querySelectorAll('.menu.open').forEach(m=>m.classList.remove('open'));
          document.querySelectorAll('.acts.pin').forEach(a=>a.classList.remove('pin'));
        }
        function toggleMenu(btn){
          const wasOpen = btn.parentElement.querySelector('.menu').classList.contains('open');
          closeMenus();
          if (wasOpen) return;
          // 접힌 행은 .item.collapsed{overflow:hidden}에 드롭다운이 잘려 아무것도 안
          // 보인다 — 먼저 항목을 펼치고(재렌더로 DOM이 새로 그려지니 버튼을 다시
          // 찾는다) 새 버튼의 메뉴를 연다. 메뉴가 열리면 폴링 재렌더는 보류된다.
          const item = btn.closest('.item');
          const id = item && item.dataset.id;
          if (item && item.classList.contains('collapsed') && id && !expanded.has(id)){
            expanded.add(id);
            render();
            const el = itemEl(id);
            btn = el && el.querySelector('.acts .menu-wrap > button');
            if (!btn) return;
          }
          const menu = btn.parentElement.querySelector('.menu');
          const acts = btn.closest('.acts');
          menu.classList.add('open');
          if (acts) acts.classList.add('pin');
        }
        // 바깥 클릭 시 열린 메뉴 닫기 (메뉴/토글 내부 클릭은 유지).
        document.addEventListener('click', e=>{ if (!e.target.closest('.menu-wrap')) closeMenus(); });
        function render(){
          if (!cache) return;
          reflectModel();
          reflectLang();
          reflectSources();
          reflectDbg();
          reflectHealth();
          // 답장 작성/수정 중엔 재렌더로 입력을 날리지 않는다 (폴링은 계속, 그리기만 보류).
          if (document.querySelector('#list .reply-box, #list .mr-editing, #list .mr-arming, #list .menu.open')) return;
          const doneMap = cache.done || {};
          const replies = cache.replies || {};
          const syncErr = cache.syncErr || {};
          // 정렬 기준 = 트리거 발생 시각. 이미 수집된 메시지에 리액션을 다시 달면
          // 데몬이 triggeredAt을 갱신하고 처리완료를 해제하므로 맨 위로 올라온다.
          let items = cache.items.slice().sort((a,b)=>trigAt(b)-trigAt(a));
          // 미처리 = done.json에 없고, 이모지로 자동 해결(autoDone)되지도 않은 것.
          // autoDone 항목은 데몬이 done.json에도 반영하지만(같은 처리완료 흐름),
          // 앱이 꺼져 있어 반영이 밀렸을 때도 미처리에 뜨지 않도록 여기서도 뺀다.
          const openItems = items.filter(it=>!doneMap[it.id] && !it.autoDone);
          const laterN = openItems.filter(it=>it.later).length;
          document.getElementById('count').textContent =
            `미처리 ${openItems.length}${laterN?` · 📌 Later ${laterN}`:''} · 전체 ${items.length}`;
          const eb = document.getElementById('expBtn');
          eb.textContent = expanded.size ? '모두 접기' : '모두 펼치기';
          eb.classList.toggle('on', expanded.size > 0);
          const list = document.getElementById('list');
          const emptyHTML = '<div class="empty">'+(cache.items.length
            ? '미처리 항목이 없습니다 🎉'
            : '아직 번역된 메시지가 없습니다.<br>슬랙에서 메시지에 👀 리액션(🔖/📌는 Later로)을 달거나, 나·내 팀 멘션 / DM / @here·@channel 알림이 오면 여기 나타납니다.')+'</div>';
          const itemHTML = it=>{
            const done = !!doneMap[it.id] || !!it.autoDone;
            const se = syncErr[it.id];
            // source: 없음=리액션 트리거(👀 또는 later용 🔖/📌), 'mention'=나를 직접
            // 멘션, 'team'=내 팀 멘션, 'dm'=DM/그룹DM, 'broadcast'=@here/@channel,
            // 'later'=레거시 star 저장. 알림·star류는 슬랙 쪽
            // 이모지가 없어 처리완료 라벨에서 리액션 제거 언급을 뺀다.
            // 멘션으로 수집된 뒤 👀를 직접 단 항목은 emoji가 붙어 있고, 그때부턴
            // 👀 항목과 똑같이 처리완료 시 리액션이 제거된다.
            const noEmoji = !it.emoji && !!it.source;
            const emo = it.emoji==='bookmark'?'🔖':it.emoji==='pushpin'?'📌':'👀';
            const retrig = it.triggeredAt && it.reactedAt && it.triggeredAt > it.reactedAt;
            const exp = expanded.has(it.id);
            const nRep = (replies[it.id]||[]).length;
            return `<div class="item ${done?'done':''} ${exp?'':'collapsed'}"
              data-id="${esc(it.id)}" onclick="toggleItem(event,'${esc(it.id)}')">
              <div class="acts">
                <button title="스레드 답장" onclick="openReply(this,'${esc(it.id)}')">💬</button>
                <button class="${done?'on':''}" title="${noEmoji?'처리완료':`처리완료 — 슬랙 ${emo} 제거`}"
                  onclick="toggleDone('${esc(it.id)}', ${done?'false':'true'})">✅</button>
                <span class="menu-wrap">
                  <button title="더보기" onclick="toggleMenu(this)">⋮</button>
                  <div class="menu">
                    ${it.permalink?`<a href="${esc(it.permalink)}" target="_blank" onclick="closeMenus()">슬랙에서 열기 ↗</a>`:''}
                    <button onclick="toggleDone('${esc(it.id)}', ${done?'false':'true'}); closeMenus()">${done?'처리완료 취소':(noEmoji?'처리완료':`처리완료 (${emo} 제거)`)}</button>
                  </div>
                </span>
              </div>
              <div class="meta">
                <span class="caret">${exp?'▾':'▸'}</span>
                <span class="ch">${esc(it.channelName||it.channel)}</span>
                <span class="au">${esc(it.author||'')}</span>
                <span>${when(trigAt(it))}</span>
                ${retrig?`<span class="rtag" title="${esc(when(it.reactedAt))} 최초 수집 — 리액션을 다시 달아 미처리로 복귀">🔁 다시</span>`:''}
                ${SRC_TAGS[it.source]?`<span class="mtag">${SRC_TAGS[it.source]}</span>`:''}
                ${it.later?'<span class="ltag">📌 Later</span>':''}
                ${dbgOn && cache.debugButtons && it.model
                  ? `<span class="dbgbadge">⏱ ${esc(it.model)}${it.trMs?` · ${(it.trMs/1000).toFixed(1)}초`:''}</span>` : ''}
                ${nRep?`<span class="ctag rep">💬 ${nRep}</span>`:''}
                ${it.pending?'<span class="ctag">⏳</span>':''}
                ${(it.error||se)?'<span class="ctag warn">⚠</span>':''}
                ${done&&it.autoDone?`<span class="atag" title="트리거(👀·🔖·📌)가 아닌 리액션이 달려 이미 처리된 것으로 봤습니다. 그 리액션이 사라지면 다시 미처리로 돌아옵니다.">✅ 이모지로 해결됨${it.autoEmoji?` (:${esc(it.autoEmoji)}:)`:''}</span>`:''}
                ${done?'<span class="done-tag">✓ 처리완료</span>':''}
              </div>
              <div class="ko">${esc(it.textKo || it.textEn)}</div>
              ${it.textKo && it.textKo !== it.textEn
                ? `<div class="en">${esc(it.textEn)}</div>` : ''}
              ${it.meaning ? `<div class="meaning"><div class="mn-head">의미 분석</div>${esc(it.meaning)}</div>` : ''}
              ${it.decision ? `<div class="decision"><div class="dc-head">의사결정</div>${esc(it.decision)}</div>` : ''}
              ${it.pending ? '<div class="pend"><i></i>번역 중…</div>' : ''}
              ${it.error ? '<div class="err">⚠ 번역 실패 — 원문만 저장됨 (데몬 재시작 시 재시도)</div>' : ''}
              ${se ? `<div class="err">⚠ 슬랙 ${se.action==='reaction.add'?'👀 복원':'👀 제거'} 실패: ${esc(se.error)}${esc(syncHint(se.error))}
                <button onclick="retrySync('${esc(it.id)}', ${done?'true':'false'})">재시도</button></div>` : ''}
              ${(replies[it.id]||[]).map(r=>`<div class="myreply">
                <div class="acts">
                  <span class="menu-wrap">
                    <button title="더보기" onclick="toggleMenu(this)">⋮</button>
                    <div class="menu">
                      <button onclick="editReply(this,'${esc(it.id)}','${esc(r.ts)}'); closeMenus()">편집</button>
                      <button class="danger" onclick="deleteReply(this,'${esc(it.id)}','${esc(r.ts)}')">삭제</button>
                    </div>
                  </span>
                </div>
                <div class="mr-head"><span class="mr-tag">내 답장${r.editedAt?' · 수정됨':''}</span>
                  <span>${when(r.at)}</span></div>
                <div class="mr-text">${esc(r.text).replace(/&lt;@[A-Z0-9]+&gt;/g, '@'+esc(it.author||'작성자'))}</div></div>`).join('')}
            </div>`;
          };
          // 미처리 뷰: 지금 처리할 것 먼저, Later 저장분은 📌 접이식 섹션으로 분리.
          // 세그 토글은 미처리/전체 2개 유지 — Later는 미처리의 하위 그룹이라
          // 세 번째 탭 대신 섹션으로 푼다 (접힘 상태는 localStorage에 기억).
          if (filter==='open'){
            const now = openItems.filter(it=>!it.later);
            const lat = openItems.filter(it=>it.later);
            if (!now.length && !lat.length){ list.innerHTML = emptyHTML; return; }
            let h = now.map(itemHTML).join('');
            if (lat.length){
              h += `<div class="sechdr" onclick="toggleLaterSec()">📌 Later`
                + `<span class="n">${lat.length}</span><span class="arrow">${laterSec?'▾':'▸'}</span></div>`;
              if (laterSec) h += lat.map(itemHTML).join('');
            }
            list.innerHTML = h;
          } else {
            list.innerHTML = items.length ? items.map(itemHTML).join('') : emptyHTML;
          }
        }
        // ----- 데몬 연결 상태 -----
        // 이 기능의 절반은 앱 밖 데몬이라, 죽으면 화면은 그냥 "안 늘어난다". 그래서
        // 상태를 항상 한 칩으로 보여주고, 앱이 스스로 되살리는 동안엔 조용히 '재연결
        // 중'만 둔다. 사용자가 뭔가 해야만 풀리는 상태에서만 배너로 올린다.
        let hDetail = localStorage.getItem('cm.slackHDetail') === '1';
        let hSig = '';
        function toggleHealth(){
          hDetail = !hDetail;
          hSig = '';
          localStorage.setItem('cm.slackHDetail', hDetail ? '1' : '0');
          render();
        }
        // 알림(멘션·DM·전체호출) 수집 경로 — 두 갈래다.
        //   실시간: 슬랙 Socket Mode message 이벤트. 즉시 뜨고 스레드 답글까지 잡는다.
        //     슬랙 앱 설정 > Event Subscriptions에 message.* 유저 이벤트가 있어야 온다.
        //   폴링: 데몬이 내 대화를 주기적으로 훑는다. 앱 설정을 안 건드려도 되지만
        //     최대 몇 분 늦고, 스레드 답글은 일부만 잡힌다.
        // 실패가 아니라 '어느 쪽으로 오고 있는지'라 경고색을 쓰지 않는다 — 폴링만이면
        // 실시간을 켜는 방법을 배너에서 안내한다.
        function pathState(h){
          const rt = (h.realtimeAt|0) > 0;
          // 소켓이 조용히 죽은 상태(degraded)에서는 예전에 실시간을 받았다는 이유로
          // '실시간 수신'이라고 말하면 안 된다 — 지금 안 오고 있는 게 문제다.
          if (h.state === 'degraded') return { cls:'wait', label:'실시간 점검 중',
            tip:'슬랙 소켓이 조용히 끊겨 다시 여는 중입니다. 그동안에도 폴링으로 수집되며(몇 분 지연), '
              +'연결이 돌아오면 놓친 항목을 자동으로 메웁니다.' };
          if (!rt && h.pollError) return { cls:'wait', label:'폴링 대기',
            tip:'대화 목록을 못 읽어 폴링이 쉬는 중입니다 ('+h.pollError
              +'). 토큰 스코프(channels:read · groups:read · im:read · mpim:read)를 확인하세요 — 다음 주기에 다시 시도합니다.' };
          if (rt) return { cls:'ok', label:'실시간 수신',
            tip:'슬랙 message 이벤트를 받고 있습니다 — 멘션·DM이 즉시 뜹니다 (폴링도 함께 돌며 놓친 것을 메웁니다).' };
          if ((h.pollAt|0) > 0) return { cls:'', label:'폴링 수집',
            tip:'대화 '+(h.pollConvs|0)+'개를 주기적으로 훑어 멘션·DM을 가져옵니다'
              +(h.pollLimited?' (슬랙 요청 제한에 걸려 주기를 늦추는 중)':'')
              +'. 실시간 이벤트는 아직 받은 적이 없습니다 — 최대 몇 분 늦게 뜹니다.' };
          return { cls:'wait', label:'수집 준비 중',
            tip:'첫 수집 주기를 기다리는 중입니다. 처음 켠 시점 이후의 알림부터 모읍니다 (과거 백필 없음).' };
        }
        function reflectPath(h, chip){
          const p = pathState(h);
          chip.style.display = '';
          chip.className = 'hchip ' + p.cls;
          document.getElementById('pChipT').textContent = p.label;
          chip.title = p.tip;
        }
        // 연결 상태와 리액션 동기화 실패를 하나의 칩으로 합친다 — 사용자에게는
        // 둘 다 "슬랙이 제대로 붙어 있나"라는 하나의 질문이다. 어느 쪽이든 문제면
        // 칩이 '⚠ 연결 및 동기화 실패'가 되고, 클릭하면 아래 배너에 원인이 나온다.
        // 해결되면(데몬 복구 / 서버의 60초 자가 재동기화) 칩은 저절로 평상 상태로
        // 돌아가고 배너의 실패 목록도 사라진다.
        function syncErrList(){
          const se = (cache && cache.syncErr) || {};
          const items = (cache && cache.items) || [];
          const byId = {};
          items.forEach(it=>{ byId[it.id] = it; });
          return Object.keys(se).map(id=>({ id, e:se[id], it:byId[id] }));
        }
        function reflectHealth(){
          const h = (cache && cache.health) || null;
          const chip = document.getElementById('hChip');
          const banner = document.getElementById('hBanner');
          const pchip = document.getElementById('pChip');
          if (!h){ chip.style.display='none'; pchip.style.display='none'; banner.style.display='none'; return; }
          reflectPath(h, pchip);
          const errs = syncErrList();
          const bad = h.needsUser || errs.length > 0;
          chip.style.display='';
          // degraded = 소켓만 조용히 죽은 상태. 앱·데몬이 스스로 여는 중이라
          // 재연결과 같은 대기색으로 둔다 (needsUser가 되면 아래 bad가 가져간다).
          const wait = h.state==='restarting' || h.state==='connecting' || h.state==='degraded';
          chip.className = 'hchip ' + (bad ? 'warn' : h.state==='ok' ? 'ok' : wait ? 'wait' : '');
          document.getElementById('hChipT').textContent =
            bad ? `연결 및 동기화 실패${errs.length?' '+errs.length:''}` : h.title;
          chip.title = (bad ? '클릭하면 원인과 조치 방법이 나옵니다 — ' : '')
            + h.detail + (h.ageSec>=0 ? ` (${h.ageSec}초 전 확인)` : '');
          // 배너 = 문제가 있을 때 + 사용자가 칩을 눌러 자세히 볼 때.
          if (!bad && !hDetail){ banner.style.display='none'; hSig=''; return; }
          banner.style.display='';
          // 5초 폴링마다 innerHTML을 다시 쓰면 방금 누른 버튼의 상태 문구가 지워진다 —
          // 내용이 실제로 바뀔 때만 다시 그린다.
          const path = pathState(h);
          const errSig = errs.map(x=>x.id+':'+(x.e.error||'')).join(',');
          const sig = h.state+'|'+h.title+'|'+h.detail+'|'+h.advice+'|'+path.label+'|'+errSig;
          if (sig === hSig) return;
          hSig = sig;
          const cmd = h.command ? `<code onclick="copyCmd(this)" title="클릭하면 복사">${esc(h.command)}</code>` : '';
          const advice = h.advice || (h.state==='ok'
            ? '지금은 정상입니다. 문제가 생기면 앱이 먼저 스스로 복구를 시도하고, 그래도 안 되면 여기서 안내합니다.'
            : '앱이 자동으로 복구하는 중입니다 — 잠시 기다려 주세요.');
          // 알림 수집 경로 — 폴링만 돌고 있으면 실시간으로 올리는 방법까지 같이 적는다.
          const rtHelp = path.cls === 'ok' ? ''
            : '<br>즉시 받으려면 api.slack.com 앱 설정 > Event Subscriptions > '
              + 'Subscribe to events on behalf of users에 message.channels · message.groups · '
              + 'message.im · message.mpim을 추가하고 앱을 다시 설치하세요.';
          // 리액션 동기화 실패 — 연결 문제와 같은 배너에 이어서 보여준다.
          const errHTML = !errs.length ? '' : `<div class="serr">
            <b>슬랙 리액션 동기화 실패 ${errs.length}건</b> — 처리완료를 눌렀지만 슬랙 쪽 이모지가 그대로입니다.
            ${errs.map(x=>`<div class="serr-row">· ${esc((x.it && (x.it.channelName||x.it.channel)) || x.id)}
              ${esc((x.it && (x.it.textKo||x.it.textEn)||'').slice(0,50))} —
              <b>${esc(x.e.error||'')}</b>${esc(syncHint(x.e.error))}</div>`).join('')}
            <div class="serr-row">1분마다 앱이 조용히 다시 시도합니다 — 원인이 풀리면 이 경고는 저절로 사라집니다.</div>
          </div>`;
          banner.innerHTML = `<h3>${esc(bad ? (h.needsUser ? h.title : '슬랙 동기화 실패') : h.title)}</h3>
            <div class="why">${esc(h.detail)}</div>
            <p>${esc(advice)}</p>
            <p>알림 수집: <b>${esc(path.label)}</b> — ${esc(path.tip)}${rtHelp}</p>
            ${errHTML}
            <div class="row">
              <button onclick="restartDaemon(this)">다시 연결</button>
              ${errs.length?'<button onclick="retryAllSync(this)">동기화 재시도</button>':''}
              ${hDetail?'<button class="ghost" onclick="toggleHealth()">닫기</button>':''}
              <span class="st" id="hSt"></span>
            </div>${cmd}`;
        }
        // 배너의 '동기화 재시도' — 실패한 항목 전부를 현재 done 상태 그대로 다시
        // 밀어 넣는다 (setDone은 멱등, syncReaction만 다시 돈다).
        function retryAllSync(btn){
          const errs = syncErrList();
          const doneMap = (cache && cache.done) || {};
          btn.disabled = true;
          const st = document.getElementById('hSt');
          if (st) st.textContent = `${errs.length}건 다시 시도하는 중…`;
          errs.forEach(x=>{
            fetch('/api/slack/done',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({id:x.id, done: !!doneMap[x.id]})}).catch(()=>{});
          });
          setTimeout(()=>{ load(); if (dbgOn) loadActions(); btn.disabled = false;
            if (st) st.textContent = ''; }, 2500);
        }
        function copyCmd(el){
          try{ navigator.clipboard.writeText(el.textContent); el.title='복사됨'; }catch(e){}
        }
        function restartDaemon(btn){
          btn.disabled = true;
          const st = document.getElementById('hSt');
          if (st) st.textContent = '다시 시작하는 중…';
          fetch('/api/slack/daemon/restart', {method:'POST'}).then(r=>r.json()).then(j=>{
            if (st) st.textContent = j.ok ? '재시작 요청됨 — 연결까지 몇 초 걸립니다'
                                          : '재시작 실패 — 아래 명령을 실행해 주세요';
            setTimeout(load, 2000);
          }).catch(()=>{ if (st) st.textContent = '앱에 연결할 수 없습니다'; })
            .finally(()=>{ btn.disabled = false; });
        }
        function load(){
          fetch('/api/slack/items').then(r=>r.json()).then(j=>{ cache=j; render(); })
            .catch(()=>{});
          if (dbgOn) loadActions();
        }
        load(); setInterval(load, 5000);
        </script></body></html>
        """#
    }
}
