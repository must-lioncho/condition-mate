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
// 멀티모달: 이미지·PDF·영상·YouTube·링크에서 뽑아낸 근거가 optional `media`
// (원소 = type·name·url·method·text·error) 와 `mediaAt` 으로 실려 오면 원문과
// 의미 분석 사이에 첨부 근거 섹션으로 펼쳐진다. 두 필드가 없는 옛 레코드에서는
// 섹션 자체가 나타나지 않는다 (필드는 전부 선택 항목이다).
// 목록은 기본 전부 접힘 — 항목당 한 줄(채널·작성자·시각·본문 첫 줄 말줄임)만 보여
// 스크롤 없이 훑을 수 있게 하고, 행을 클릭하면 원문·의미 분석·의사결정·내 답장이
// 펼쳐진다 (펼친 뒤엔 메타 줄 클릭으로만 접힘 — 본문 텍스트 선택 보호). 펼침
// 상태는 화면 메모리에만 두어 페이지를 다시 열면 다시 전부 접힌다.
// Data contracts and file ownership: see SlackTranslateStore's header.
public enum SlackTranslateContent {

    // Extra HTML injected into <head> by the host app — the Condition Mate
    // passes CMTimeFilter.bootHTML() so timestamps honor the app's display
    // timezone. Standalone runs fall back to a local-timezone shim (below).
    public static var headExtraHTML: () -> String = { "" }
    // Optional host navigation rendered as the first body child. Keeping this a
    // closure lets the plugin stay app-agnostic while Condition Mate can attach
    // its shared SessionRail to this otherwise standalone page.
    public static var bodyLeadingHTML: () -> String = { "" }

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
          header a.back{ display:inline-flex; align-items:center; gap:7px; min-height:44px;
            padding:0 12px; border-radius:9px; color:#b8c9e8; text-decoration:none;
            font-size:13px; font-weight:600; white-space:nowrap }
          header a.back:hover{ background:#1b2230; color:#e6efff }
          header a.back:focus-visible{ outline:2px solid var(--accent); outline-offset:1px }
          header a.back svg{ width:17px; height:17px; stroke:currentColor; stroke-width:2;
            fill:none; flex:none }
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
          /* 데몬 연결 상태 칩 — 항상 보인다. 정상=녹색(연결이 살아 있다는 뜻은
             녹색이어야 한눈에 읽힌다), 대기=보라, 사용자 행동이 필요할 때만 주의색(주황). */
          .hchip{ display:inline-flex; align-items:center; gap:5px; font-size:11.5px;
            color:var(--mut); border:1px solid var(--line); border-radius:9px;
            padding:3px 10px; cursor:pointer; user-select:none }
          .hchip .dot{ width:6px; height:6px; border-radius:50%; background:#586173 }
          .hchip.ok{ color:#6fcf97; border-color:#245239 } .hchip.ok .dot{ background:#4fbf7a }
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
          /* 정상 상태를 펼쳐 봤을 때 — 문제 배너의 주황이 아니라 녹색으로 "괜찮다"를 말한다 */
          .hbanner.ok{ background:#0d1a12; border-color:#245239 }
          .hbanner.ok h3{ color:#6fcf97 }
          .hbanner.ok button{ background:#1d3a28; color:#a8e6c0 }
          .hbanner.ok button:hover{ background:#264b34 }
          .hbanner.ok button.ghost{ background:transparent; color:var(--mut) }
          .hbanner.ok .serr{ border-top-color:#245239 }
          /* 자동 복구 중을 펼쳐 봤을 때 — 대기색(보라) */
          .hbanner.wait{ background:#14111f; border-color:#3c3560 }
          .hbanner.wait h3{ color:#b9a3ff }
          .hbanner.wait button{ background:#2c2647; color:#cfc2ff }
          .hbanner.wait button:hover{ background:#38305a }
          .hbanner.wait button.ghost{ background:transparent; color:var(--mut) }
          .hbanner.wait .serr{ border-top-color:#3c3560 }
          .hbanner code{ display:block; margin-top:8px; background:#0c1017; border:1px solid var(--line);
            border-radius:8px; padding:7px 10px; font-size:11px; color:#9ec1ff;
            white-space:pre-wrap; word-break:break-all; cursor:pointer }
          /* 연동 관리 모달 — 이 페이지가 기대는 외부 연동(키 4개 + 보조 2개)의
             존재·실연결 상태를 한 화면에서 검증한다. 상태색 컨벤션:
             정상=녹색, 확인 중(대기)=보라, 조치 필요=주황. */
          .imodal{ position:fixed; inset:0; z-index:80; background:rgba(5,8,12,.55);
            display:flex; align-items:flex-start; justify-content:center; padding:56px 20px }
          .ipanel{ background:#141821; border:1px solid var(--line); border-radius:14px;
            width:100%; max-width:620px; max-height:82vh; overflow:auto; padding:18px 20px;
            box-shadow:0 18px 50px rgba(0,0,0,.55) }
          .ipanel h2{ margin:0; font-size:15px }
          .ipanel .isub{ color:var(--mut); font-size:12px; margin:3px 0 12px; line-height:1.6 }
          .ipanel .isub a{ color:#9ec1ff; text-decoration:none }
          .ipanel .isub a:hover{ text-decoration:underline }
          /* 토큰을 어디에 넣는지 — 터미널 명령 위에 먼저 온다 (앱 안에서 끝나는 길이 기본). */
          .iguide .gpick{ font-size:11.5px; margin-top:6px; color:var(--mut) }
          .iguide .gpick a{ color:#9ec1ff; text-decoration:none }
          .iguide .gpick a:hover{ text-decoration:underline }
          .ipanel .isec{ color:#9ec1ff; font-size:11.5px; font-weight:700; margin:14px 0 6px;
            display:flex; align-items:center; gap:8px }
          .ipanel .isec::after{ content:''; flex:1; height:1px; background:var(--line) }
          .irow{ background:var(--card); border:1px solid var(--line); border-radius:10px;
            padding:9px 12px; margin-bottom:8px }
          .irow .ihead{ display:flex; align-items:center; gap:8px }
          .irow .iname{ font-size:13px; font-weight:700 }
          .irow .isvc{ color:var(--mut); font-size:10.5px; font-family:ui-monospace,monospace }
          .irow .ist{ margin-left:auto; display:inline-flex; align-items:center; gap:5px;
            font-size:11.5px; border:1px solid var(--line); border-radius:8px; padding:2px 9px;
            color:var(--mut); white-space:nowrap }
          .irow .ist .dot{ width:6px; height:6px; border-radius:50%; background:#586173 }
          .irow .ist.ok{ color:#6fcf97; border-color:#245239 } .irow .ist.ok .dot{ background:#4fbf7a }
          .irow .ist.warn{ color:#f0a045; border-color:#5d4526 }
          .irow .ist.warn .dot{ background:#f0a045 }
          .irow .ist.wait{ color:#b9a3ff; border-color:#3c3560 }
          .irow .ist.wait .dot{ background:#b9a3ff; animation:hpulse 1.4s ease-in-out infinite }
          .irow .irole{ color:var(--mut); font-size:11.5px; margin-top:3px }
          .irow .idet{ font-size:11.5px; color:#8fa3c0; margin-top:3px }
          .irow .ierr{ font-size:11.5px; color:#f0a045; margin-top:3px; line-height:1.55 }
          .irow code{ display:block; margin-top:6px; background:#0c1017;
            border:1px solid var(--line); border-radius:7px; padding:5px 9px; font-size:10.5px;
            color:#9ec1ff; white-space:pre-wrap; word-break:break-all; cursor:pointer }
          /* 재발급 가이드 — 터미널 한 줄을 빼면 전부 슬랙 웹 설정이라, 어느 메뉴에서
             무엇을 누르는지까지 앱 안에 적어 둔다 (앱만 보고 끝낼 수 있게). */
          .iguide{ background:#12161f; border:1px solid var(--line); border-radius:10px;
            margin:10px 0 4px; overflow:hidden }
          .iguide > .gh{ display:flex; align-items:center; gap:8px; padding:9px 12px;
            cursor:pointer; user-select:none; font-size:12.5px; font-weight:700 }
          .iguide > .gh .gsub{ font-weight:400; color:var(--mut); font-size:11.5px }
          .iguide > .gh .gcv{ margin-left:auto; color:var(--mut); font-size:11px }
          .iguide .gbody{ padding:2px 12px 12px; border-top:1px solid var(--line) }
          .iguide .gstep{ display:flex; gap:9px; padding:9px 0; border-top:1px dashed #222836 }
          .iguide .gstep:first-child{ border-top:0 }
          .iguide .gno{ flex:none; width:19px; height:19px; border-radius:50%; margin-top:1px;
            background:#1f3a75; color:#9ec1ff; font-size:11px; font-weight:700;
            display:flex; align-items:center; justify-content:center }
          .iguide .gtx{ flex:1; font-size:12px; line-height:1.65 }
          .iguide .gtx b{ color:#cdd7e6 }
          .iguide .gtx .path{ font-family:ui-monospace,monospace; font-size:11px; color:#9ec1ff;
            background:#0c1017; border:1px solid var(--line); border-radius:5px; padding:1px 5px }
          .iguide .gtx .warnx{ color:#f0a045 }
          .iguide .gtx a{ color:#9ec1ff }
          .iguide .gtx code{ display:block; margin-top:6px; background:#0c1017;
            border:1px solid var(--line); border-radius:7px; padding:5px 9px; font-size:10.5px;
            color:#9ec1ff; white-space:pre-wrap; word-break:break-all; cursor:pointer }
          .ipanel .ifoot{ display:flex; align-items:center; gap:8px; margin-top:14px;
            flex-wrap:wrap }
          .ipanel .ifoot button{ background:#1f3a75; color:#9ec1ff; border:0; border-radius:8px;
            padding:5px 14px; font-size:12px; cursor:pointer }
          .ipanel .ifoot button:disabled{ opacity:.5; cursor:default }
          .ipanel .ifoot button.ghost{ background:transparent; border:1px solid var(--line);
            color:var(--mut) }
          .ipanel .ifoot .st{ font-size:11.5px; color:var(--mut) }
          .ipanel .inote{ color:var(--mut); font-size:11px; margin-top:10px; line-height:1.6 }
          .dbgpanel{ background:#12161f; border:1px solid #3a2f1c; border-radius:10px;
            padding:10px 12px; margin-bottom:14px; font-size:11px }
          .dbgpanel h3{ margin:0 0 6px; font-size:11px; color:#f0a045; font-weight:700 }
          /* 패널 머리 = 지금 어떤 경로로 수집 중인지(실시간/폴링). 로그보다 위에 둔다. */
          .dbgpanel .dbghead{ display:flex; align-items:center; gap:8px; flex-wrap:wrap }
          .dbgpanel .dbghead:not(:empty) .hchip{ margin-bottom:8px }
          .dbgpanel .scroll{ max-height:240px; overflow:auto }
          .dbgpanel table{ width:100%; border-collapse:collapse }
          .dbgpanel td{ padding:2px 6px; color:var(--mut); white-space:nowrap;
            border-top:1px solid #1a2029; font-size:11px }
          .dbgpanel tr:first-child td{ border-top:0 }
          .dbgpanel td.ms{ text-align:right; color:var(--fg); font-variant-numeric:tabular-nums }
          .dbgpanel td.ok{ color:#7bd88f }
          .dbgpanel td.bad{ color:#f0857a; white-space:normal; word-break:break-all }
          .dbgpanel td.dt{ white-space:normal; word-break:break-all; color:#5f6a7d }
          /* 앱 밖(데몬)이 한 액션 표식 — 수집·번역·자동 처리완료가 여기 속한다 */
          .dbgpanel .who{ font-size:9.5px; color:#b9a3ff; border:1px solid #33285a;
            border-radius:5px; padding:0 4px; margin-right:4px }
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
            max-width:68%; overflow:hidden }
          .item.collapsed .meta > span{ overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          /* 시각 칩(메시지 시각·수집 시각)과 상태 칩은 절대 줄이지 않는다 — 시각은
             정렬 기준이라 '8/16 1…'처럼 분이 잘리면 목록을 읽을 수 없고, 상태 칩은
             반쪽만 보이면 뜻이 사라진다. 줄어드는 건 이름류(채널·작성자)뿐. */
          .item.collapsed .meta > span.tm, .item.collapsed .meta > span.cat,
          .item.collapsed .meta > span.mtag, .item.collapsed .meta > span.ltag,
          .item.collapsed .meta > span.lvtag,
          .item.collapsed .meta > span.rtag, .item.collapsed .meta > span.atag,
          .item.collapsed .meta > span.ctag, .item.collapsed .meta > span.done-tag{
            flex:0 0 auto; overflow:visible }
          .item.collapsed .ko{ flex:1 1 auto; min-width:0; font-size:13px; color:var(--mut);
            white-space:nowrap; overflow:hidden; text-overflow:ellipsis }
          .item.collapsed .en, .item.collapsed .meaning, .item.collapsed .decision,
          .item.collapsed .media,
          .item.collapsed .myreply, .item.collapsed .pend, .item.collapsed .err{ display:none }
          .item.collapsed .done-tag{ margin-left:0 }
          /* 호버 액션 툴바 — 접힘 행에선 위로 튀어나오지 않게 우측 세로 중앙에 붙인다 */
          .item.collapsed > .acts{ top:50%; transform:translateY(-50%); right:8px; background:transparent;
            border:0; box-shadow:none; padding:0 }
          .item .caret{ color:var(--mut); font-size:9px; width:9px; flex:0 0 auto }
          /* 접힘일 때만 보이는 요약 배지 (답장 수 · 첨부 근거 · 경고 · 번역 중) */
          .item .ctag{ display:none; font-size:10.5px }
          .item.collapsed .ctag{ display:inline }
          .item .ctag.warn{ color:#f0a045 }
          .item .ctag.rep{ color:#9ec1ff }
          .item .ctag.med{ color:#a9b7cc }
          /* 읽지 못한 첨부가 섞여 있으면 접힌 줄에서도 주의색으로 보인다 */
          .item .ctag.med.warn{ color:#f0a045 }
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
          /* 빠른 리액션 버튼 — 이미 내가 단 이모지는 파랑 테두리(처리완료 초록과 구분) */
          .acts > button.rx{ font-size:13px }
          .acts > button.rx.mine{ background:#16203a; box-shadow:inset 0 0 0 1px #2f6bff }
          .acts > .sep{ width:1px; height:16px; background:var(--line); margin:0 2px }
          /* 슬랙 원문에 실제로 달려 있는 리액션 (데몬이 실시간으로 채운다).
             내가 단 것은 파랑으로 구분 — 앱에서 남긴 이모지가 슬랙에도 갔는지
             여기서 바로 확인된다. */
          .rx-row{ display:flex; flex-wrap:wrap; gap:5px; margin-top:10px }
          .item.collapsed .rx-row{ display:none }
          .rx-row button{ display:inline-flex; align-items:center; gap:5px; background:#151b26;
            border:1px solid var(--line); border-radius:12px; padding:1px 9px; font-size:12.5px;
            color:var(--mut); cursor:pointer; line-height:1.7 }
          .rx-row button:hover{ border-color:#2f6bff }
          .rx-row button.mine{ border-color:#2f6bff; background:#16203a; color:#9ec1ff }
          .rx-row button .n{ font-size:10.5px; font-weight:700 }
          .rx-row img{ width:15px; height:15px; object-fit:contain; vertical-align:-2px }
          .rx-row .more{ font-size:13px; color:var(--mut) }
          /* 워크스페이스 이모지인데 목록을 못 받아온 경우 — 이름 그대로 보여준다 */
          .cn{ font-size:10.5px; color:var(--mut) }
          /* 이모지 고르기 팝업 (＋) — 검색 + 자주 쓰는 + 분류 + 워크스페이스 */
          .empick{ width:300px }
          .empick input{ width:100%; background:#0c1017; border:1px solid var(--accent);
            border-radius:9px; color:var(--fg); padding:7px 11px; font-size:12.5px; outline:none }
          .empick .body{ max-height:250px; overflow:auto; margin-top:7px }
          .empick .sec{ font-size:10.5px; color:var(--mut); font-weight:700; margin:9px 3px 4px }
          .empick .grid{ display:grid; grid-template-columns:repeat(8,1fr); gap:2px }
          .empick .grid button{ background:none; border:0; border-radius:6px; cursor:pointer;
            font-size:17px; line-height:1; padding:5px 0; color:var(--fg) }
          .empick .grid button:hover{ background:#232b38 }
          .empick .grid button.mine{ background:#16203a; box-shadow:inset 0 0 0 1px #2f6bff }
          .empick .grid img{ width:18px; height:18px; object-fit:contain }
          .empick .none{ color:var(--mut); font-size:11.5px; padding:12px 4px }
          .empick .foot{ display:flex; align-items:center; gap:7px; flex-wrap:wrap;
            border-top:1px solid var(--line); margin-top:8px; padding-top:8px;
            font-size:11px; color:var(--mut) }
          .empick .foot button.lnk{ background:none; border:0; color:var(--accent);
            cursor:pointer; font-size:11px; padding:2px 0 }
          .empick .foot .cur{ font-size:14px; letter-spacing:2px }
          .empick .foot .hint{ flex:1 0 100%; color:#5f6a7d; font-size:10.5px }
          .empick.pinning input{ border-color:#f0a045 }
          .empick.pinning .grid button:hover{ background:#3a2f1c }
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
          /* ⋮ 메뉴 안의 구분 머리말 — 처리 액션과 "세션 추출"을 눈으로 갈라 준다 */
          .menu .mhdr{ padding:6px 12px 3px; font-size:10px; color:var(--mut); letter-spacing:.04em;
            border-top:1px solid var(--line); margin-top:3px }
          /* 컨텍스트 공유하기 패널 — 답장창(.reply-box) 스타일을 그대로 쓰고 머리말만 얹는다.
             같은 클래스를 다는 이유: 폴링 재렌더 가드(#list .reply-box)가 입력 중인 이 패널도
             함께 지켜 준다. */
          .ctx-box .ctx-head{ font-size:11.5px; color:#9ec1ff; font-weight:700; margin-bottom:5px }
          .ctx-box .send{ margin-left:auto }
          .done-tag{ margin-left:auto; color:#7bd88f; font-size:11px; font-weight:700 }
          .item .meta{ display:flex; align-items:center; gap:8px; flex-wrap:wrap;
            font-size:11.5px; color:var(--mut); margin-bottom:8px }
          .item .meta .ch{ font-weight:700; color:#9ec1ff }
          .item .meta .mtag{ color:#f0c045; border:1px solid #3a2f1c; border-radius:6px;
            padding:0 6px; font-size:10.5px; font-weight:700 }
          /* 요청 레벨은 내 대시보드에서만 보인다. Slack 회신에는 절대 싣지 않는다. */
          .item .meta .lvtag{ border:1px solid; border-radius:6px; padding:0 6px;
            font-size:10.5px; font-weight:700 }
          .item .meta .lvtag.l0{ color:#8ee6a3; border-color:#2d6740 }
          .item .meta .lvtag.l1{ color:#7bd88f; border-color:#245239 }
          .item .meta .lvtag.l2{ color:#9ec1ff; border-color:#294879 }
          .item .meta .lvtag.l3{ color:#ff8b8b; border-color:#6b3030 }
          .item .meta .lvtag.l4{ color:#d8a8ff; border-color:#654080 }
          /* Later 칩 — 대기 성격이라 보라 계열 (상태색 컨벤션: 대기=보라) */
          .item .meta .ltag{ color:#b9a3ff; border:1px solid #33285a; border-radius:6px;
            padding:0 6px; font-size:10.5px; font-weight:700 }
          /* 재트리거 칩 — 리액션을 다시 달아 미처리로 돌아온 항목 (대기=보라 계열) */
          .item .meta .rtag{ color:#b9a3ff; border:1px solid #33285a; border-radius:6px;
            padding:0 6px; font-size:10.5px; font-weight:700 }
          /* 수집 시각 — 메시지 시각과 다를 때만 덧붙인다. 목록 정렬 기준이라
             보여줘야 하지만, 메시지가 언제 온 것인지와 헷갈리면 안 되므로 흐리게. */
          .item .meta .cat{ color:#5f6b7d; font-size:10.5px }
          /* 지금 정렬 기준으로 쓰이는 시각 — 어느 쪽으로 줄 세운 목록인지 한눈에 */
          .item .meta .tm.key, .item .meta .cat.key{ color:#9ec1ff; font-weight:700 }
          /* 이모지 자동 해결 칩 — 완료 성격이라 초록 계열 (처리완료 라벨과 같은 색) */
          .item .meta .atag{ color:#7bd88f; border:1px solid #234a2e; border-radius:6px;
            padding:0 6px; font-size:10.5px; font-weight:700 }
          /* AI가 슬랙에 실제로 응답한 항목 — 완료가 아니라 '기계가 손댔음'이라
             초록이 아닌 파랑(정보색, lvtag.l2·mr-tag와 같은 계열)을 쓴다. */
          .item .meta .atag.ai{ color:#9ec1ff; border-color:#294879 }
          /* 백로그 칩 — 파이프라인 도입 전 미분류분. 상태가 아니라 출처 설명이라
             가장 흐린 계열(.cat·.ctag.med와 같은 회색)로 둔다. */
          .item .meta .atag.bk{ color:var(--mut); border-color:var(--line) }
          /* 접힌 줄에서는 이 둘을 아이콘만 남긴다 (뜻은 title 로 남는다) — 글자까지
             달면 오른쪽 끝의 '✓ 처리완료'가 잘린다. 실측: 전체 뷰 1443줄 중
             잘린 줄이 14 → 122 로 늘었다. .ctag(💬·📎)가 접힘에서 아이콘+숫자만
             쓰는 것과 같은 규칙이다. */
          .item.collapsed .meta .atag.ai .t, .item.collapsed .meta .atag.bk .t{ display:none }
          .item.collapsed .meta .atag.ai, .item.collapsed .meta .atag.bk{ padding:0; border:0 }
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
          /* 첨부 근거 — 데몬이 이미지·PDF·영상·YouTube·링크에서 뽑아낸 원본 근거
             (레코드의 optional media[] · mediaAt). 원문과 의미 분석 사이에 두어
             카드가 원문 → 근거 → 해석 → 결정 순으로 읽히게 한다. 의미/의사결정보다
             한 단계 조용한 색(중성 회청)을 쓴다 — 근거는 결론을 받쳐 주는 자료지
             결론이 아니다. */
          .item .media{ margin-top:10px; padding:8px 12px; background:#12161f;
            border-left:3px solid #6b7a94; border-radius:0 9px 9px 0 }
          .item .media .md-head{ display:flex; align-items:center; gap:7px; font-size:10.5px;
            color:#a9b7cc; font-weight:700; margin-bottom:4px }
          .item .media .md-n{ background:rgba(140,160,190,.18); border-radius:5px;
            padding:0 6px; font-size:10px; color:#cdd7e6 }
          .item .media .md-bad{ color:#f0a045 }
          .item .media .md-at{ margin-left:auto; color:#5f6b7d; font-weight:400 }
          .item .media .md-row{ border-top:1px dashed #222836; padding:3px 0 }
          .item .media .md-head + .md-row{ border-top:0 }
          /* 읽지 못한 첨부는 조용히 숨기지 않는다 — 근거에서 빠졌다는 사실 자체가
             판단에 필요하다 (주의색 배경 + 사유 한 줄). */
          .item .media .md-row.bad{ background:#1a1509; border-radius:7px }
          .item .media .md-line{ display:flex; align-items:center; gap:6px }
          .item .media .md-tog{ flex:1 1 auto; min-width:0; display:flex; align-items:center;
            gap:7px; background:transparent; border:0; color:var(--fg); font:inherit;
            font-size:12.5px; text-align:left; padding:3px 5px; border-radius:6px;
            cursor:pointer }
          .item .media .md-tog:hover{ background:#1a2130 }
          /* 본문이 없어 펼칠 것이 없는 줄 — 눌리지 않지만 흐려 보이지는 않게 */
          .item .media .md-tog[disabled]{ cursor:default; opacity:1 }
          .item .media .md-cv{ flex:0 0 auto; width:9px; color:var(--mut); font-size:9px }
          .item .media .md-ic{ flex:0 0 auto; font-size:12px }
          .item .media .md-ty{ flex:0 0 auto; color:#9ec1ff; font-size:10.5px; font-weight:700 }
          .item .media .md-nm{ flex:1 1 auto; min-width:0; overflow:hidden;
            text-overflow:ellipsis; white-space:nowrap }
          /* 어떤 경로로 읽어낸 근거인지 (pdftotext · 비전 래스터화 · 자막 …) —
             같은 PDF라도 텍스트 레이어인지 래스터화한 것인지에 따라 믿을 정도가 다르다 */
          .item .media .md-me{ flex:0 0 auto; color:var(--mut); font-size:10px;
            border:1px solid var(--line); border-radius:5px; padding:0 5px;
            font-family:ui-monospace,monospace; white-space:nowrap }
          .item .media .md-len{ flex:0 0 auto; color:#5f6b7d; font-size:10px;
            font-variant-numeric:tabular-nums }
          .item .media .md-ln{ flex:0 0 auto; color:var(--mut); text-decoration:none;
            font-size:12px; padding:2px 7px; border-radius:6px }
          .item .media .md-ln:hover{ color:#9ec1ff; background:#1a2130 }
          .item .media .md-err{ color:#f0a045; font-size:11.5px; padding:1px 5px 4px 21px;
            line-height:1.55; word-break:break-word }
          .item .media .md-non{ color:var(--mut); font-size:11.5px; padding:1px 5px 4px 21px }
          /* 펼친 근거 본문 — 아주 길 수 있어 자체 스크롤을 준다 (카드가 화면을 삼키지
             않도록). 기본은 접힘. */
          .item .media .md-tx{ margin:2px 0 5px 21px; padding:7px 10px; background:#0c1017;
            border:1px solid var(--line); border-radius:8px; font-size:12px; color:#cdd7e6;
            white-space:pre-wrap; word-break:break-word; max-height:320px; overflow:auto }
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
          .item .decision .dc-options{ display:grid; gap:7px; margin-top:10px }
          .item .decision .dc-option{ display:flex; align-items:flex-start; gap:9px; width:100%;
            padding:9px 11px; border:1px solid #34435d; border-radius:9px; background:#131f33;
            color:#e6edf6; text-align:left; cursor:pointer; font-size:12.5px; line-height:1.5 }
          .item .decision .dc-option:hover, .item .decision .dc-option:focus{
            border-color:#f0c045; background:#192944; outline:none }
          .item .decision .dc-key{ flex:0 0 auto; display:inline-grid; place-items:center;
            width:20px; height:20px; border:1px solid #6f6240; border-radius:5px;
            color:#f0c045; font:700 11px ui-monospace,SFMono-Regular,Menlo,monospace }
          .item .decision .dc-controls{ display:flex; align-items:center; gap:7px; margin-top:9px }
          .item .decision .dc-custom{ display:none; gap:7px; margin-top:8px }
          .item .decision .dc-custom.on{ display:flex }
          .item .decision .dc-custom input{ flex:1; min-width:0; background:#0c1017; color:#e6edf6;
            border:1px solid #34435d; border-radius:8px; padding:8px 10px; font-size:12.5px }
          .item .decision .dc-custom input:focus{ border-color:#f0c045; outline:none }
          .item .decision .dc-ghost, .item .decision .dc-send{ border:1px solid #34435d;
            border-radius:7px; background:transparent; color:#aeb9ca; padding:6px 9px; cursor:pointer }
          .item .decision .dc-send{ background:#725b17; border-color:#a88420; color:#fff2bd }
          .item .decision .dc-ghost:hover{ color:#fff; border-color:#687a96 }
          .item .decision .dc-hint{ margin-left:auto; color:var(--mut); font-size:10.5px }
          .item .decision .dc-state{ margin-top:8px; color:var(--mut); font-size:11.5px }
          .item .decision .dc-state.ok{ color:#7bd88f }
          .item .decision .dc-state.bad{ color:#f0857a }
          /* ---- 에이전트별 탭 (2026-08-31) ----
             세 에이전트의 산출물 — 컨텍스트 에이전트(의미 분석), 답변을 쓰는 에이전트,
             발신 에이전트 — 이 한 덩어리로 이어져 나오던 것을 가른다. 원문·번역·첨부는
             탭 밖에 남긴다. 그것은 에이전트의 산출물이 아니라 이 카드의 대상이고,
             의사결정 탭에서 바로 결정하려면 원문이 같이 보여야 하기 때문이다. */
          .item .tabs{ display:flex; gap:3px; margin-top:12px; border-bottom:1px solid var(--line) }
          .item .tabs button{ background:transparent; border:0; border-bottom:2px solid transparent;
            color:var(--mut); font-size:11.5px; padding:5px 10px 6px; cursor:pointer;
            border-radius:6px 6px 0 0; white-space:nowrap }
          .item .tabs button:hover{ color:#cdd7e6; background:#141a24 }
          .item .tabs button.on{ color:#e6edf6; border-bottom-color:#f0c045 }
          .item .tabs button .tdot{ margin-left:5px; font-size:9px; vertical-align:1px }
          .item.collapsed .tabs, .item.collapsed .tabbody{ display:none }
          /* 발신 상태 한 줄. 안 나간 건을 빈 화면으로 두지 않는다 — 무엇이 없는지가
             아니라 왜 없는지가 보여야 한다. */
          .item .sendline{ margin-top:10px; padding:8px 12px; border-radius:9px; font-size:12.5px;
            background:#0e1a15; border-left:3px solid #3fb27f; color:#cfe8db }
          .item .sendline.no{ background:#1c1512; border-left-color:#f0a045; color:#f0cba8 }
          .item .sendline b{ color:#fff; font-weight:600 }
          .item .sendline .why{ display:block; margin-top:4px; color:var(--mut); font-size:11.5px;
            line-height:1.6 }
          .item .sendline .code{ font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
            font-size:10.5px; color:var(--mut) }
          .item .sentbody{ margin-top:8px; padding:9px 12px; background:#0c1017;
            border:1px solid var(--line); border-radius:9px; font-size:13px;
            white-space:pre-wrap; word-break:break-word; color:#cdd7e6 }
          .item .langtag{ display:inline-block; margin-left:6px; padding:0 6px; border-radius:5px;
            font-size:10.5px; font-weight:700; background:#1a2130; color:#9ec1ff }
          .item .langtag.ko{ background:#1e1a2c; color:#c8a8ff }
          .item .tnone{ margin-top:10px; padding:9px 12px; background:#0c1017;
            border:1px dashed var(--line); border-radius:9px; font-size:12.5px; color:var(--mut) }
          /* ---- 스레드 묶음 ----
             라이언이 슬랙에 스레드로 쓰기 때문에 같은 대화의 조각이 시각순 목록에
             흩어진다. 묶음은 기본 꺼짐이다 — 켜면 정렬 기준이 사실상 바뀌므로
             (묶음 = 그 안에서 가장 앞선 항목의 자리) 고를 수 있게 둔다. */
          .thgrp{ border:1px solid #22303f; border-radius:12px; margin:10px 0; padding:0 0 2px;
            background:#0a0e14 }
          .thgrp .thhdr{ display:flex; align-items:center; gap:7px; padding:7px 12px;
            font-size:11.5px; color:#9ec1ff; border-bottom:1px solid #17202b }
          .thgrp .thhdr .n{ background:#1a2130; color:var(--mut); border-radius:999px;
            padding:0 7px; font-size:10.5px }
          .thgrp .item{ margin:0; border-radius:0; border-left:0; border-right:0 }
          .thgrp .item:last-child{ border-bottom:0 }
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
        <script>window.CM_PAGE='slack';</script>
        \#(bodyLeadingHTML())
        <header>
          <div><h1>Slack 번역</h1>
            <div class="sub">👀 리액션 · @나/@팀 멘션 · DM · @here/@channel · 🔖/📌 = Later · 자동 번역 + 의미 분석</div></div>
          <a class="back" href="/" aria-label="대시보드로 돌아가기"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 18l-6-6 6-6"/><path d="M9 12h10"/></svg><span>대시보드</span></a>
        </header>
        <main>
          <div class="toolbar">
            <div class="seg">
              <button id="fWait" class="on" onclick="setFilter('wait')"
                title="AI가 처리하지 못해 라이언이 직접 판단해야 하는 것만 모읍니다.">결정 대기</button>
              <button id="fAi" onclick="setFilter('ai')"
                title="AI가 슬랙에 이미 응답한 것입니다. 확인만 하면 됩니다.">AI 처리</button>
              <button id="fBacklog" onclick="setFilter('backlog')"
                title="자동 분류 파이프라인(08-29) 도입 전에 쌓인 것입니다. 급하지 않지만 사라지지 않습니다.">백로그</button>
              <button id="fAll" onclick="setFilter('all')">전체</button>
            </div>
            <button class="dbg" id="expBtn" onclick="toggleAll()"
              title="모든 항목을 펼치거나 다시 한 줄로 접습니다 (개별 항목은 클릭으로 펼침)">모두 펼치기</button>
            <button class="dbg" id="grpBtn" onclick="toggleGroup()"
              title="같은 슬랙 스레드에 속한 메시지를 한 묶음으로 모아 보여줍니다 — 묶음 안은 시각 오름차순(위에서 아래로 읽는 순서)입니다">🧵 스레드 묶기</button>
            <button class="combo" id="srcCombo" onclick="openSrcMenu(event)"
              title="어떤 메시지를 이 페이지에 수집할지 선택 (다중 선택) — 해제하면 앞으로 뜨지 않습니다 (이미 수집된 항목은 유지)">
              수집 기준<span class="cbadge" id="srcCnt">6</span> <span class="cv">▾</span></button>
            <select id="sortSel" onchange="setSort(this.value)"
              title="목록 정렬 기준 — 수집·체크 시각: 슬랙에서 👀를 새로 달거나 다시 달면 그 시각으로 갱신되어 맨 위로 올라옵니다. 메시지 시각: 슬랙에 글이 올라온 시각 그대로.">
              <option value="trig">↕ 수집·체크 시각순</option>
              <option value="msg">↕ 메시지 시각순</option>
            </select>
            <select id="langSel" onchange="setLang(this.value)"
              title="이 화면에서 읽을 번역의 목표 언어입니다 — 메시지가 이미 이 언어면 번역하지 않습니다 (새로 수집되는 항목부터 적용). 슬랙으로 나가는 답변의 언어는 이것과 무관하며, 상대의 프로필로 사람마다 정해집니다.">
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
            <button class="dbg" id="intBtn" onclick="openIntegrations()"
              title="이 페이지가 쓰는 외부 연동(슬랙 토큰 2 · 번역 키 2 · 스피킹)의 키 등록·실제 연결 상태를 한 번에 검증합니다">🔗 연동</button>
            <button class="dbg" id="dbgBtn" style="display:none" onclick="toggleDbg()"
              title="항목별 번역 모델·소요시간 + 액션 로그 패널 표시">디버그</button>
            <span class="hchip" id="hChip" onclick="toggleHealth()"
              title="슬랙 수집 연결 상태 — 클릭하면 자세히"><span class="dot"></span><span id="hChipT">확인 중</span></span>
            <span class="count" id="count"></span>
          </div>
          <div class="hbanner" id="hBanner" style="display:none"></div>
          <div class="popup" id="popup" style="display:none"></div>
          <!-- 수집 경로 칩(실시간 수신 / 폴링 수집)은 툴바가 아니라 이 패널 최상단에 둔다 —
               평소엔 '연결됨'만 있으면 되고, 그 옆에 경로 칩까지 서 있으면 상태가 둘인 것처럼
               읽혀 혼동을 준다. 지금 어느 경로로 들어오는지는 디버그를 켠 사람만 궁금하다. -->
          <div class="dbgpanel" id="dbgPanel" style="display:none">
            <div class="dbghead"><span class="hchip" id="pChip" style="display:none"
              onclick="toggleHealth()"><span class="dot"></span><span id="pChipT"></span></span></div>
            <div id="dbgBody"></div>
          </div>
          <div id="list"><div class="empty">불러오는 중…</div></div>
        </main>
        <script>
        // 독립 실행 폴백 — 호스트 앱이 headExtraHTML로 CMTimeFilter(표시 타임존)를
        // 주입하지 않았을 때만 로컬 타임존으로 대체한다 (앱 안에서는 항상 주입됨).
        if (!window.CMTimeFilter) window.CMTimeFilter = { parts: t => { const d = new Date(t);
          return { mo:d.getMonth()+1, d:d.getDate(), h:d.getHours(), mi:d.getMinutes(), s:d.getSeconds() }; } };
        // 세그 토글 = 결정 대기 / AI 처리 / 백로그 / 전체. 고른 값은 이 브라우저에
        // 기억하되, 옛 값('open')이나 모르는 값이 들어 있으면 'wait'로 떨어뜨린다 —
        // 남아 있던 localStorage 때문에 화면이 비는 일이 없어야 한다.
        const FILTERS = ['wait','ai','backlog','all'];
        let filter = FILTERS.includes(localStorage.getItem('cm.slackFilter'))
          ? localStorage.getItem('cm.slackFilter') : 'wait';
        let cache = null;
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
        const FILTER_BTN = { wait:'fWait', ai:'fAi', backlog:'fBacklog', all:'fAll' };
        function reflectFilter(){
          for (const f of FILTERS){
            const el = document.getElementById(FILTER_BTN[f]);
            if (el) el.classList.toggle('on', filter===f);
          }
        }
        function setFilter(f){
          filter = FILTERS.includes(f) ? f : 'wait';
          localStorage.setItem('cm.slackFilter', filter);
          reflectFilter();
          render();
        }
        function esc(s){ const d=document.createElement('div'); d.textContent=s||''; return d.innerHTML; }

        // ----- 스레드 묶음 -----
        // 정렬 기준을 바꾸는 것이므로 기본은 꺼짐이고, 고른 값은 기억한다.
        let groupThreads = localStorage.getItem('cm.slackGroup') === '1';
        function toggleGroup(){
          groupThreads = !groupThreads;
          localStorage.setItem('cm.slackGroup', groupThreads ? '1' : '0');
          render();
        }
        // 스레드 키. threadTs 가 없는 메시지는 자기 자신이 스레드의 뿌리다.
        function threadKey(it){ return (it.channel||'') + ':' + (it.threadTs || it.ts); }

        // ----- 에이전트별 탭 -----
        // 기본은 의사결정이다. 라이언이 카드를 열자마자 결정할 수 있는 것이 이 탭의
        // 존재 이유이므로, 탭을 옮긴 카드만 이 맵에 담긴다 (expanded 와 같은 규칙 —
        // 폴링 재렌더에는 유지되고 페이지를 다시 열면 전부 의사결정으로 돌아간다).
        const tabOf = new Map();
        const TABS = [['decision','의사결정'], ['context','컨텍스트'], ['send','발신'], ['ai','AI 실행']];
        function tabFor(id){ return tabOf.get(id) || 'decision'; }
        function setTab(ev, id, tab){
          ev.stopPropagation();
          tabOf.set(id, tab);
          render();
        }

        // 차단 사유 코드 → 사람이 읽는 한 줄. 코드는 데몬이 원장에 남기는 값 그대로다
        // (alignment-engine.mjs 의 ackSendGate, slack-eyes-daemon.mjs 의 강등 경로).
        // 모르는 코드가 와도 코드 자체를 보여 준다 — 빈 화면보다 낫다.
        const BLOCK_WHY = {
          NO_ADDS_LINE: '스레드에 무엇을 더하는지 한 줄을 대지 못했습니다. 더할 것이 없으면 글을 내지 않습니다.',
          NO_NOVELTY: '이미 스레드에 있는 내용이라 되풀이가 됩니다.',
          NO_BASIS: '근거를 찾지 못했습니다.',
          NO_BRIEF_LINE: '한 문장도 슬랙 상한(2줄·280자)에 들어가지 않아 전문을 MD 로만 남겼습니다.',
          NO_CONFIDENCE: '모델이 확신도를 돌려주지 않았습니다.',
          LOW_CONFIDENCE: '확신도가 기준(80%)에 못 미칩니다.',
          NO_INFORMATION_GAIN: '묻지도 요청하지도 않은 메시지이고 근거 레이어도 비어 있어, 재진술 말고 담을 것이 없습니다.',
          EVIDENCE_LOOKUP_FAILED: '스레드에 공유된 문서를 읽지 못한 상태였습니다.',
          INTERNAL_STATE_LEAK: '글에 내부 사정(토큰·조회 실패)이 새어 있었습니다.',
          ANALYSIS_SCAFFOLD_LEAK: '글에 분석 스키마의 라벨이 남아 있었습니다.',
          SENSITIVE_CONTEXT: '사람의 신분·보상·분쟁이 걸린 자리라 기계가 먼저 말하지 않습니다.',
          NO_UNRESOLVED_SCOPE: '무엇을 가리키는지 확정되지 않은 지시어가 남아 있었습니다.',
          R1_REACTION_FAILED: '리액션 하나로 끝낼 건이었는데 그 리액션을 달지 못했습니다.',
          F2_ALREADY_ANSWERED: '스레드에 이미 답이 나와 있습니다.',
          LANGUAGE_MISMATCH: '정해진 수신자 언어를 지키지 않은 글이라 내보내지 않았습니다.',
        };
        function blockWhy(code){
          const key = String(code||'').split(':')[0];
          return BLOCK_WHY[key] || '';
        }

        // 이 메시지에 대해 슬랙으로 무엇이 나갔는가. 카드가 답해야 하는 질문이 셋이다 —
        // 나갔는가, 나갔으면 어느 언어로, 안 나갔으면 왜.
        //   ackLang/ackBody 는 2026-08-31 에 추가한 필드다. 옛 레코드에는 없으므로
        //   없을 때 깨지지 않고 "기록 없음"으로 내려가야 한다.
        function ackState(it){
          if (it.securityBlocked) {
            return { sent:false, codes:[], lang:it.ackLang||'',
              why:'보안 게이트가 막았습니다 — 민감정보 요청('+(it.securityKind||'')+'). 스레드에는 아무것도 보내지 않았습니다.' };
          }
          if (it.ackTs || it.ackBody) {
            return { sent:true, lang:it.ackLang||'', basis:it.ackLangBasis||'',
              body:it.ackBody||'', at:it.ackAt||0, retried:!!it.ackLangRetried,
              superseded:it.ackSupersededAt||0, codes:[] };
          }
          if (it.ackEmoji) {
            return { sent:false, codes:[], lang:it.ackLang||'',
              why:'글 대신 리액션 하나로 끝냈습니다 (:'+it.ackEmoji+':).' };
          }
          if (it.ackBlockedAt) {
            const codes = Array.isArray(it.ackBlockedReasons) ? it.ackBlockedReasons : [];
            return { sent:false, lang:it.ackLang||'', basis:it.ackLangBasis||'', codes,
              why:it.ackGradeReason||'' };
          }
          if (it.ackGrade === 'R0') {
            return { sent:false, codes:[], lang:it.ackLang||'',
              why:it.ackGradeReason || '글을 받을 자격이 없는 메시지로 판정했습니다 (R0).' };
          }
          if (it.autoReplyPolicy) {
            return { sent:false, codes:[], lang:'',
              why:'이 상대·채널은 자동 응답 대상이 아닙니다 (응답 정책).' };
          }
          return { sent:false, codes:[], lang:'',
            why:'아직 발신 판정이 남지 않았습니다. 데몬이 이 건을 처리하기 전이거나, 발신 파이프라인을 거치지 않은 옛 레코드입니다.' };
        }

        function langTag(lang){
          if (lang !== 'ko' && lang !== 'en') return '';
          return '<span class="langtag '+lang+'">'+(lang==='ko'?'한국어':'English')+'</span>';
        }

        // 컨텍스트 탭·발신 탭이 함께 쓰는 전달 상태 한 줄.
        function sendLineHTML(it){
          const a = ackState(it);
          if (a.sent) {
            return '<div class="sendline"><b>슬랙에 전달됨</b>'
              + (a.lang ? langTag(a.lang) : '<span class="langtag">언어 기록 없음</span>')
              + (a.at ? ' · '+when(a.at) : '')
              + (a.superseded ? ' · 나중 답변으로 대체됨' : '')
              + (a.retried ? '<span class="why">모델이 언어를 한 번 어겨 다시 쓰게 했습니다.</span>' : '')
              + (a.basis ? '<span class="why">언어 근거: '+esc(a.basis)+'</span>' : '')
              + '</div>';
          }
          const codes = a.codes || [];
          const why = codes.map(blockWhy).filter(Boolean);
          const lines = [];
          if (a.why) lines.push(esc(a.why));
          for (const w of why) lines.push(esc(w));
          return '<div class="sendline no"><b>슬랙에 나가지 않음</b>'
            + (a.lang ? langTag(a.lang) : '')
            + '<span class="why">' + lines.join('<br>')
            + (codes.length ? '<br><span class="code">'+esc(codes.join(' · '))+'</span>' : '')
            + '</span></div>';
        }

        const stoppedDecisions = new Set();
        let activeDecisionId = '';
        function decisionOptions(raw){
          const out = []; const re = /(?:^|\s)([1-9])\)\s*([\s\S]*?)(?=(?:\s+[1-9]\)\s)|$)/g;
          let m;
          while ((m = re.exec(String(raw||''))) !== null) {
            const text = m[2].trim(); if (text) out.push({key:m[1], text:text});
          }
          return out;
        }
        function decisionHTML(it){
          const opts = decisionOptions(it.decision);
          if (!opts.length) return '<div class="decision"><div class="dc-head">의사결정</div>'+esc(it.decision)+'</div>';
          if (stoppedDecisions.has(it.id)) return '<div class="decision"><div class="dc-head">의사결정</div>'
            +'<div class="dc-state">선택을 중단했습니다.</div><div class="dc-controls">'
            +'<button class="dc-ghost" onclick="resumeDecision(this)">다시 선택</button></div></div>';
          const buttons = opts.map(o=>'<button class="dc-option" data-key="'+o.key+'" data-value="'+escA(o.text)+'" onclick="pickDecision(this)">'
            +'<span class="dc-key">'+o.key+'</span><span>'+esc(o.text)+'</span></button>').join('');
          return '<div class="decision decision-panel" tabindex="0" data-decision-id="'+escA(it.id)+'"'
            +' onmouseenter="activeDecisionId=this.dataset.decisionId" onfocusin="activeDecisionId=this.dataset.decisionId">'
            +'<div class="dc-head">의사결정</div>'+buttons
            +'<div class="dc-controls"><button class="dc-ghost" onclick="openCustomDecision(this)">직접 입력 <span class="dc-key">3</span></button>'
            +'<button class="dc-ghost" onclick="stopDecision(this)">중단 <span class="dc-key">Esc</span></button>'
            +'<span class="dc-hint">마우스 클릭 또는 숫자 키</span></div>'
            +'<div class="dc-custom"><input placeholder="결정을 직접 입력" onkeydown="customDecisionKey(event,this)">'
            +'<button class="dc-send" onclick="sendCustomDecision(this)">결정</button></div><div class="dc-state"></div></div>';
        }
        function decisionPanel(el){ return el.closest('.decision-panel'); }
        function decisionState(panel, text, kind){
          const st=panel&&panel.querySelector('.dc-state'); if(st){ st.textContent=text; st.className='dc-state '+(kind||''); }
        }
        function submitDecision(panel, text){
          if (!panel || panel.dataset.busy==='1' || !text.trim()) return;
          panel.dataset.busy='1'; decisionState(panel,'전달 중…','');
          panel.querySelectorAll('button,input').forEach(x=>x.disabled=true);
          fetch('/api/slack/reply',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({id:panel.dataset.decisionId,text:text.trim(),mention:true})})
            .then(r=>r.json()).then(j=>{
              if(j.ok){ decisionState(panel,'결정이 스레드에 전달됐습니다 ✓','ok'); setTimeout(load,700); }
              else throw new Error(j.error||'전달 실패');
            }).catch(e=>{
              panel.dataset.busy=''; panel.querySelectorAll('button,input').forEach(x=>x.disabled=false);
              decisionState(panel,'실패: '+e.message,'bad');
            });
        }
        function pickDecision(btn){ submitDecision(decisionPanel(btn),btn.dataset.value||''); }
        function openCustomDecision(btn){
          const panel=decisionPanel(btn), box=panel.querySelector('.dc-custom'); box.classList.add('on'); box.querySelector('input').focus();
        }
        function sendCustomDecision(btn){ const panel=decisionPanel(btn); submitDecision(panel,panel.querySelector('.dc-custom input').value); }
        function customDecisionKey(ev,input){ if(ev.key==='Enter'&&!ev.shiftKey){ ev.preventDefault(); sendCustomDecision(input); } }
        function stopDecision(btn){ const panel=decisionPanel(btn); stoppedDecisions.add(panel.dataset.decisionId); activeDecisionId=''; render(); }
        function resumeDecision(btn){ const id=btn.closest('.item').dataset.id; stoppedDecisions.delete(id); render(); setTimeout(()=>{ const p=itemEl(id)?.querySelector('.decision-panel'); if(p)p.focus(); },0); }
        document.addEventListener('keydown', ev=>{
          if(!activeDecisionId || ev.metaKey || ev.ctrlKey || ev.altKey) return;
          const panel=itemEl(activeDecisionId)?.querySelector('.decision-panel'); if(!panel) return;
          if(ev.target.matches('input,textarea')) return;
          if(ev.key==='Escape'){ ev.preventDefault(); stopDecision(panel); return; }
          if(ev.key==='3'){ ev.preventDefault(); openCustomDecision(panel); return; }
          const btn=panel.querySelector('.dc-option[data-key="'+ev.key+'"]');
          if(btn){ ev.preventDefault(); pickDecision(btn); }
        });

        function aiUsageHTML(it){
          if(!ackState(it).sent)return '<div class="tnone">게시된 AI 답변이 없습니다.</div>';
          const calls=it.ackAI?.calls;
          if(!Array.isArray(calls)||!calls.length)return '<div class="tnone">이 답변의 AI 실행 정보는 기록되지 않았습니다. 업데이트 이후 생성·게시되는 답변부터 표시됩니다.</div>';
          const number=n=>typeof n==='number'&&Number.isFinite(n)&&n>=0?n.toLocaleString():'미제공';
          const field=(label,value)=>'<div style="margin:5px 0"><b>'+label+'</b> '+value+'</div>';
          const total=calls.reduce((sum,c)=>sum+(typeof c.tokens?.total==='number'?c.tokens.total:0),0);
          const missing=calls.filter(c=>typeof c.tokens?.total!=='number').length;
          return '<div class="meaning"><div class="mn-head">AI 실행 정보 · 앱 내부</div>'
            +'<div>답변 생성·언어 재시도 범위 · 번역·근거 수집 제외</div>'
            +field('전체 토큰',number(total)+(missing?' + 미제공 '+missing+'건':''))
            +calls.map((c,i)=>{
              const t=c.tokens||{},ctx=c.context||{},effort=c.effort||{};
              const effortText=effort.state==='not-set'?'앱 지정 없음 · API 기본값':effort.state==='environment'?esc(effort.value)+' · CLI 환경 설정':'미확인 · CLI 내부 설정';
              const limit=typeof ctx.inputLimit==='number'?ctx.inputLimit:ctx.window;
              const limitLabel=ctx.inputLimit!=null?'입력 한도 ':'전체 한도 ';
              const used=ctx.usedInput==null?'단일 요청 사용량 미제공':number(ctx.usedInput)+' tokens'+(limit>0?' / '+number(limit)+' ('+(ctx.usedInput/limit*100).toFixed(2)+'%)':'');
              return '<div style="border-top:1px solid #303642;margin-top:12px;padding-top:8px">'
                +field('모델 '+(i+1),esc(c.model||'미기록')+(c.modelResolved?'':' · 요청 ID, 실제 버전 미제공'))
                +(c.requestedModel&&c.requestedModel!==c.model?field('요청 모델',esc(c.requestedModel)):'')
                +field('실행 경로',esc(c.transport||'미기록'))+field('Effort',effortText)
                +field('컨텍스트 윈도우',limit==null?'미제공':limitLabel+number(limit)+' tokens')
                +field('입력 사용량',used)
                +(ctx.outputLimit!=null?field('출력 한도',number(ctx.outputLimit)+' tokens'):'')
                +field(c.transport==='cli'?'입력 토큰 (호출 누적)':'입력 토큰',number(t.input))
                +field('출력 토큰',number(t.output))+field('추론 토큰',number(t.reasoning))
                +field('캐시 읽기 토큰',number(t.cached))
                +(t.cacheCreated!=null?field('캐시 생성 토큰',number(t.cacheCreated)):'')
                +field('전체 토큰',number(t.total))+'</div>';
            }).join('')+'<div style="margin-top:10px;opacity:.7">캐시 토큰은 입력에 포함됩니다. 이 정보는 Slack 답변·MD 첨부에 실리지 않습니다.</div></div>';
        }

        function tabBodyHTML(it, tab){
          if(tab === 'ai') return aiUsageHTML(it);
          if (tab === 'context') {
            // 컨텍스트 에이전트 — 무엇으로 읽었는가, 그리고 그것이 실제로 전달됐는가.
            return (it.meaning
                ? '<div class="meaning"><div class="mn-head">의미 분석</div>'+esc(it.meaning)+'</div>'
                : '<div class="tnone">이 건에는 의미 분석이 없습니다. 번역만 되었거나(옛 레코드), 컨텍스트 수집에 실패했습니다.</div>')
              + sendLineHTML(it);
          }
          if (tab === 'send') {
            // 발신 에이전트 — 무엇이 나갔는가. 안 나갔으면 그 사실과 이유.
            const a = ackState(it);
            return sendLineHTML(it)
              + (a.sent
                  ? (a.body
                      ? '<div class="sentbody">'+esc(a.body)+'</div>'
                      : '<div class="tnone">나간 본문이 이 레코드에 남아 있지 않습니다. 발신 본문 기록(ackBody)은 2026-08-31 부터 남기므로, 그 전에 나간 건은 슬랙 스레드에서 확인해야 합니다.</div>')
                  : '');
          }
          // 의사결정 — 기본 탭. 라이언이 여기서 바로 결정한다.
          return it.decision
            ? decisionHTML(it)
            : '<div class="tnone">이 건에는 의사결정 선택지가 없습니다. 결정할 것이 없는 메시지이거나, 분석이 선택지를 만들지 못했습니다.</div>';
        }

        function tabsHTML(it){
          const cur = tabFor(it.id);
          const a = ackState(it);
          // 탭 이름 옆의 점은 그 탭에 볼 것이 있는지다. 발신 탭은 안 나간 건도 볼
          // 것이 있으므로(사유) 언제나 켜진다.
          const has = { decision: !!it.decision, context: !!it.meaning, send: true, ai: a.sent };
          const dot = { decision:'#f0c045', context:'#4ac1b8', send: a.sent ? '#3fb27f' : '#f0a045', ai: it.ackAI?.calls?.length ? '#3fb27f' : '#f0a045' };
          const btns = TABS.map(function(t){
            const k = t[0];
            return '<button class="'+(cur===k?'on':'')+'" onclick="setTab(event,\''+esc(it.id)+'\',\''+k+'\')">'
              + t[1]
              + (has[k] ? '<span class="tdot" style="color:'+dot[k]+'">●</span>' : '')
              + '</button>';
          }).join('');
          return '<div class="tabs">'+btns+'</div><div class="tabbody">'+tabBodyHTML(it, cur)+'</div>';
        }
        // 속성값 안에 넣을 때 쓰는 이스케이프 — esc()는 < > & 만 막고 따옴표는 그대로
        // 둔다. 텍스트 자리에서는 그것으로 충분하지만, 첨부 URL처럼 외부에서 온
        // 문자열을 href나 title 안에 넣을 때는 따옴표까지 막아야 속성을 빠져나가
        // 새 속성(onmouseover 같은)을 만드는 길이 닫힌다.
        function escA(s){ return esc(s).replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }
        function when(epoch){
          if (!epoch) return '';
          const p = window.CMTimeFilter.parts(epoch*1000);
          return `${p.mo}/${p.d} ${String(p.h).padStart(2,'0')}:${String(p.mi).padStart(2,'0')}`;
        }
        // 트리거 발생 시각 — 목록 정렬의 기준. triggeredAt은 재트리거
        // (제거했다가 다시 리액션) 때 데몬이 갱신한다. 없으면 최초 수집 시각.
        function trigAt(it){ return it.triggeredAt || it.reactedAt || 0; }
        // ----- 정렬 기준 -----
        // 'trig' = 수집·체크 시각(기본): 👀를 새로 달거나 다시 달면 데몬이 triggeredAt을
        // 지금으로 갱신하므로 방금 체크한 메시지가 맨 위로 온다. 'msg' = 슬랙 원문 시각.
        // 이 브라우저에 기억한다.
        let sortBy = localStorage.getItem('cm.slackSort') === 'msg' ? 'msg' : 'trig';
        function sortKey(it){
          return sortBy === 'msg' ? (msgAt(it) || trigAt(it)) : (trigAt(it) || msgAt(it));
        }
        function setSort(v){
          sortBy = v === 'msg' ? 'msg' : 'trig';
          localStorage.setItem('cm.slackSort', sortBy);
          render();
        }
        function reflectSort(){ document.getElementById('sortSel').value = sortBy; }
        // 메시지가 슬랙에 올라온 시각 (Slack ts = epoch 초). 행에 찍는 시간은 이쪽이다 —
        // 예전에는 트리거 시각만 찍어서, 금요일에 올라온 글에 👀를 오늘 달면 오늘
        // 날짜로 보였다 (실제 혼동, 2026-08-11). 수집 시각은 다를 때만 흐리게 덧붙인다.
        function msgAt(it){ const t = parseFloat(it.ts||0); return t > 0 ? Math.floor(t) : 0; }
        const COLLECT_GAP = 120;   // 이 이상 벌어질 때만 '수집' 시각을 따로 보여준다
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
        // 동기화 에러 → 사람이 조치할 수 있는 힌트. 처리완료는 이모지 두 개
        // (트리거 제거 + ✅ 추가)를 한 번에 반영하므로 에러가 "이름=코드" 꼴로
        // 합쳐져 올 수 있다 — 정확히 같은지가 아니라 포함으로 판정한다.
        function syncHint(err){
          const e = String(err||'');
          if (e.includes('missing_scope')) return ' — 슬랙 앱 사용자 토큰에 reactions:write 스코프가 없습니다. 앱 OAuth 재설치 후 키체인 cm-slack-user-token 갱신 필요';
          if (e.includes('keychain token missing')) return ' — 키체인에 cm-slack-user-token이 없습니다';
          if (e.includes('network')) return ' — 네트워크 오류';
          if (e.includes('item not found')) return ' — items.jsonl에서 항목을 찾지 못했습니다';
          return '';
        }
        // ================= 리액션 (슬랙 원문에 이모지 남기기) =================
        // 항목 툴바의 빠른 버튼(기본 👀 볼게요 · 👌 승인)과 ＋ 이모지 고르기가
        // 여기로 모인다. 처리완료(✅)는 done 토글이 겸하고, 서버가 슬랙 원문에도
        // ✅를 달아 준다 — "앱에서 남긴 초록 체크가 슬랙에도 보여야 한다"
        // (user request 2026-08-16).
        //
        // 기본 이모지 세트 — [글자, 슬랙 이름, 검색어]. 워크스페이스 커스텀
        // 이모지(:ACK: 같은 것)는 GET /api/slack/emoji로 따로 받아 뒤에 붙인다.
        const EMOJI_CATS = [
          ['반응 · 승인', [
            ['✅','white_check_mark','체크 확인 완료 승인 done check approve'],
            ['☑️','ballot_box_with_check','체크 확인 check'],
            ['✔️','heavy_check_mark','체크 확인 check'],
            ['👀','eyes','눈 볼게요 확인중 take a look eyes watching'],
            ['👌','ok_hand','오케이 승인 ok approve fine'],
            ['🆗','ok','오케이 승인 ok'],
            ['🙆','ok_woman','오케이 승인 ok approve'],
            ['👍','+1','좋아요 굿 thumbsup like good yes'],
            ['👎','-1','싫어요 반대 thumbsdown no'],
            ['🙏','pray','감사 부탁 thanks please pray'],
            ['🙌','raised_hands','축하 환영 yay hands'],
            ['👏','clap','박수 잘했어 clap'],
            ['🤝','handshake','합의 협업 deal handshake'],
            ['💪','muscle','화이팅 힘내 strong'],
            ['🫡','saluting_face','알겠습니다 경례 salute ack'],
            ['🙋','raising_hand','저요 질문 volunteer hand'],
            ['🤙','call_me_hand','콜 연락 call'],
            ['👋','wave','안녕 인사 hi bye wave'],
            ['✍️','writing_hand','작성 기록 write note'],
            ['🤞','crossed_fingers','행운 기원 luck'],
          ]],
          ['진행 · 상태', [
            ['⏳','hourglass_flowing_sand','대기 진행중 waiting pending'],
            ['⏱️','stopwatch','시간 소요 timer'],
            ['🚧','construction','작업중 공사 wip progress'],
            ['🔄','arrows_counterclockwise','재시도 갱신 sync retry refresh'],
            ['🔁','repeat','반복 다시 repeat again'],
            ['▶️','arrow_forward','시작 재생 start play'],
            ['⏸️','double_vertical_bar','일시정지 보류 pause hold'],
            ['🛑','octagonal_sign','중지 스톱 stop'],
            ['📌','pushpin','고정 나중에 pin later'],
            ['🔖','bookmark','저장 나중에 bookmark later'],
            ['🗓️','calendar','일정 날짜 schedule date'],
            ['🔔','bell','알림 리마인드 notify remind'],
            ['⚡','zap','빠르게 긴급 fast urgent'],
            ['🚀','rocket','배포 출시 deploy ship launch'],
            ['🎯','dart','목표 타겟 goal target'],
            ['🏁','checkered_flag','완료 종료 finish done'],
            ['🆕','new','신규 새것 new'],
            ['🔥','fire','뜨거움 중요 hot fire'],
            ['💯','100','완벽 백점 perfect 100'],
            ['✨','sparkles','반짝 개선 nice sparkle'],
          ]],
          ['주의 · 문제', [
            ['⚠️','warning','경고 주의 warning caution'],
            ['❗','exclamation','중요 느낌표 important'],
            ['❓','question','질문 물음표 question'],
            ['🚨','rotating_light','긴급 비상 urgent alert'],
            ['🐛','bug','버그 오류 bug'],
            ['❌','x','아니오 취소 no cancel x'],
            ['⛔','no_entry','금지 중단 blocked'],
            ['🤔','thinking_face','고민 생각 hmm thinking'],
            ['😅','sweat_smile','민망 진땀 oops'],
            ['🙈','see_no_evil','민망 못보겠다 oops'],
            ['🆘','sos','도움 구조 help sos'],
            ['🔍','mag','확인 조사 search look'],
          ]],
          ['감정', [
            ['😀','grinning','웃음 smile'], ['😄','smile','웃음 smile'],
            ['😁','grin','웃음 grin'], ['😂','joy','웃김 lol joy'],
            ['🙂','slightly_smiling_face','미소 smile'], ['😊','blush','흐뭇 blush'],
            ['😍','heart_eyes','좋아 사랑 love'], ['🤩','star-struck','대박 wow'],
            ['😎','sunglasses','멋짐 cool'], ['🥳','partying_face','축하 party'],
            ['😢','cry','슬픔 cry'], ['😭','sob','슬픔 눈물 sob'],
            ['😱','scream','놀람 scream'], ['🤯','exploding_head','충격 mind blown'],
            ['😴','sleeping','졸림 sleep'], ['🤗','hugging_face','환영 hug'],
            ['😇','innocent','천사 innocent'], ['🥲','smiling_face_with_tear','웃픔'],
          ]],
          ['축하 · 마음', [
            ['🎉','tada','축하 완료 celebrate tada'],
            ['🎊','confetti_ball','축하 celebrate'],
            ['🏆','trophy','우승 성과 trophy win'],
            ['🥇','first_place_medal','1등 금메달 gold'],
            ['🎁','gift','선물 gift'], ['🍰','cake','케이크 cake'],
            ['❤️','heart','하트 love'], ['🧡','orange_heart','하트'],
            ['💛','yellow_heart','하트'], ['💚','green_heart','하트'],
            ['💙','blue_heart','하트'], ['💜','purple_heart','하트'],
            ['🖤','black_heart','하트'], ['🫶','heart_hands','마음 love'],
          ]],
          ['업무 · 사물', [
            ['📝','memo','메모 기록 note memo'],
            ['📄','page_facing_up','문서 document'],
            ['📊','bar_chart','차트 통계 chart'],
            ['📈','chart_with_upwards_trend','상승 증가 up'],
            ['📉','chart_with_downwards_trend','하락 감소 down'],
            ['💰','moneybag','돈 정산 money'],
            ['💵','dollar','달러 usd money'],
            ['🔒','lock','보안 잠금 lock'], ['🔑','key','키 권한 key'],
            ['🔧','wrench','수정 fix wrench'], ['🛠️','hammer_and_wrench','작업 fix tools'],
            ['💻','computer','개발 pc computer'], ['📱','iphone','모바일 phone'],
            ['📷','camera','사진 screenshot camera'], ['🔗','link','링크 link'],
            ['☕','coffee','커피 휴식 coffee'], ['🍺','beer','맥주 회식 beer'],
            ['🍕','pizza','피자 식사 food'], ['🏠','house','집 재택 home'],
          ]],
        ];
        const EMOJI_BY_NAME = {};
        EMOJI_CATS.forEach(c=>c[1].forEach(e=>{ EMOJI_BY_NAME[e[1]] = e[0]; }));
        // 워크스페이스 커스텀 이모지 {name: url} — emoji:read 스코프가 없으면 빈
        // 객체로 남고 기본 세트만 보인다 (실패 안내는 띄우지 않는다).
        let customEmoji = {};
        function loadCustomEmoji(){
          fetch('/api/slack/emoji').then(r=>r.json())
            .then(j=>{ customEmoji = j.emoji || {}; }).catch(()=>{});
        }
        // 이모지 한 개를 그리는 조각 — 기본 세트는 글자, 커스텀은 이미지,
        // 둘 다 없으면 :이름: 그대로 (슬랙에서 지운 이모지도 흔적은 남는다).
        function emFace(name){
          if (EMOJI_BY_NAME[name]) return esc(EMOJI_BY_NAME[name]);
          if (customEmoji[name]) return `<img src="${esc(customEmoji[name])}" alt=":${esc(name)}:">`;
          return `<span class="cn">:${esc(name)}:</span>`;
        }
        // 빠른 버튼 목록 — 서버 config.json이 원본, 없으면 기본값.
        function quickList(){ return (cache && cache.quick) || ['white_check_mark','eyes','ok_hand']; }
        function doneEmojiName(){ return (cache && cache.doneEmoji) || 'white_check_mark'; }
        function itemById(id){ return ((cache&&cache.items)||[]).find(i=>i.id===id); }
        // 내가 이 항목에 남긴 리액션 — 앱 대장(reactions.json) + 트리거 이모지.
        // 트리거(👀·🔖·📌)는 내가 슬랙에서 직접 단 것이다(데몬은 내 리액션만
        // 트리거로 본다). 대장에는 없지만 내 것으로 세지 않으면 👀 버튼이 꺼짐으로
        // 보이고, 누르면 이미 달린 리액션을 또 다는 꼴이 된다.
        function myRx(id){
          const list = ((cache && cache.myRx && cache.myRx[id]) || []).slice();
          const it = itemById(id);
          if (it && it.emoji && !it.source && !list.includes(it.emoji)) list.push(it.emoji);
          return list;
        }
        // 메시지에 실제로 달려 있는 리액션을 [이름, 개수, 내것] 로 묶는다.
        // item.reactions는 데몬이 채우는 다중집합(남이 단 것 포함)이라 여기에
        // 내 대장을 합쳐야 방금 누른 것이 폴링 전에도 보인다.
        function rxGroups(it){
          const m = new Map();
          for (const n of (it.reactions||[])) m.set(n, (m.get(n)||0)+1);
          for (const n of myRx(it.id)) if (!m.has(n)) m.set(n, 1);
          return Array.from(m.entries()).map(([n,c])=>[n, c, myRx(it.id).includes(n)]);
        }
        // 리액션 토글 — 낙관적으로 먼저 반영하고 서버(슬랙)에 보낸다. 실패하면
        // 다음 폴링이 실제 상태로 되돌린다 (배너 없이 조용히).
        function toggleRx(id, name, on){
          if (cache){
            cache.myRx = cache.myRx || {};
            const mine = (cache.myRx[id]||[]).filter(n=>n!==name);
            if (on) mine.push(name);
            if (mine.length) cache.myRx[id] = mine; else delete cache.myRx[id];
            const it = (cache.items||[]).find(i=>i.id===id);
            if (it){
              const list = (it.reactions||[]).slice();
              if (on) list.push(name);
              else { const i = list.indexOf(name); if (i>=0) list.splice(i,1); }
              it.reactions = list.length ? list : undefined;
            }
            render();
          }
          if (on) bumpFreq(name);
          fetch('/api/slack/reaction',{method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({id:id, name:name, on:on})}).catch(()=>{});
          // 데몬이 슬랙 이벤트를 받아 items.jsonl에 반영할 때까지 잠깐 걸린다.
          setTimeout(()=>{ load(); if (dbgOn) loadActions(); }, 2500);
        }
        // 자주 쓰는 이모지 — 이 브라우저에 사용 횟수를 센다 (슬랙 피커와 같은 감각).
        function emFreq(){
          try{ return JSON.parse(localStorage.getItem('cm.slackRxFreq')||'{}'); }catch(e){ return {}; }
        }
        function bumpFreq(name){
          const f = emFreq(); f[name] = (f[name]||0)+1;
          try{ localStorage.setItem('cm.slackRxFreq', JSON.stringify(f)); }catch(e){}
        }
        function freqTop(n){
          const f = emFreq();
          const seeded = Object.keys(f).length ? [] : quickList();
          return seeded.concat(Object.keys(f).sort((a,b)=>f[b]-f[a])).slice(0, n);
        }
        // ----- 이모지 고르기 팝업 (＋ = 자세히) -----
        // 슬랙 메시지 호버 툴바의 이모지 피커와 같은 자리·같은 동작: 검색 한 칸 +
        // 자주 쓰는 것부터. 아래 '빠른 버튼 편집'을 켜면 클릭이 리액션 대신
        // 툴바 기본 버튼 등록/해제로 바뀐다.
        let emTarget = null, emPinning = false;
        function openEmoji(btn, id){
          emTarget = id; emPinning = false;
          const r = btn.getBoundingClientRect();
          showPopup(Math.max(8, r.left - 150), r.bottom + 6, emPickHTML());
          renderEmBody();
          const q = document.getElementById('emQ');
          if (q) setTimeout(()=>q.focus(), 0);
        }
        function emPickHTML(){
          // 워크스페이스 이모지(:ACK: 같은 사내 이모지)는 emoji:read 스코프가 있어야
          // 목록을 받는다 — 없으면 기본 세트만 나오므로 조용한 각주로만 알린다.
          const noCustom = !Object.keys(customEmoji).length;
          return `<div class="empick${emPinning?' pinning':''}" id="emPick">
            <input id="emQ" placeholder="${emPinning?'빠른 버튼에 넣을 이모지 검색':'이모지 검색'}"
              oninput="renderEmBody()" autocomplete="off">
            <div class="body" id="emBody"></div>
            <div class="foot">
              <span class="cur">${quickList().map(n=>EMOJI_BY_NAME[n]||'').join('')}</span>
              <button class="lnk" onclick="toggleEmPin()">${emPinning?'완료':'빠른 버튼 편집'}</button>
              ${noCustom?'<span class="hint">사내 이모지는 emoji:read 스코프 필요</span>':''}
            </div></div>`;
        }
        function toggleEmPin(){
          emPinning = !emPinning;
          setPopupHTML(emPickHTML());
          renderEmBody();
        }
        function renderEmBody(){
          const body = document.getElementById('emBody');
          if (!body) return;
          const q = (document.getElementById('emQ')||{}).value || '';
          const key = q.trim().toLowerCase().replace(/\s+/g,'_');
          const mine = emTarget ? myRx(emTarget) : [];
          const cell = name => `<button class="${mine.includes(name)?'mine':''}"
            title=":${esc(name)}:" onclick="pickEmoji('${esc(name)}')">${emFace(name)}</button>`;
          const grid = names => `<div class="grid">${names.map(cell).join('')}</div>`;
          const custom = Object.keys(customEmoji);
          if (key){
            // 이름으로 시작하는 것 → 이름에 포함 → 검색어(한글 포함) 순. 커스텀
            // 이모지 이름은 대소문자를 가리지 않는다 (:ACK: 를 ack로 찾는다).
            const word = q.trim().toLowerCase();
            const hit = [];
            const push = (name, rank) => hit.push([name, rank]);
            EMOJI_CATS.forEach(c=>c[1].forEach(e=>{
              const n = e[1];
              if (n.startsWith(key)) push(n, 0);
              else if (n.includes(key)) push(n, 1);
              else if (e[2].includes(word)) push(n, 2);
            }));
            custom.forEach(n=>{
              const l = n.toLowerCase();
              if (l.startsWith(key)) push(n, 0); else if (l.includes(key)) push(n, 1);
            });
            hit.sort((a,b)=>a[1]-b[1]);
            body.innerHTML = hit.length ? grid(hit.slice(0,64).map(x=>x[0]))
              : '<div class="none">검색 결과가 없습니다.</div>';
            return;
          }
          let h = `<div class="sec">자주 쓰는</div>${grid(freqTop(16))}`;
          EMOJI_CATS.forEach(c=>{ h += `<div class="sec">${esc(c[0])}</div>${grid(c[1].map(e=>e[1]))}`; });
          if (custom.length) h += `<div class="sec">워크스페이스</div>${grid(custom.slice(0,80))}`;
          body.innerHTML = h;
        }
        function pickEmoji(name){
          // 편집 모드: 리액션을 달지 않고 툴바 빠른 버튼 목록만 바꾼다.
          if (emPinning){
            const cur = quickList().slice();
            const i = cur.indexOf(name);
            if (i>=0) cur.splice(i,1); else cur.push(name);
            if (cache) cache.quick = cur.length ? cur : [doneEmojiName()];
            fetch('/api/slack/config',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({quick: cache ? cache.quick : cur})}).catch(()=>{});
            setPopupHTML(emPickHTML()); renderEmBody(); render();
            return;
          }
          if (!emTarget) return;
          const on = !myRx(emTarget).includes(name);
          // ✅는 처리완료와 한 몸이다 — 따로 달면 슬랙과 앱 상태가 어긋나므로
          // 처리완료 토글로 넘긴다 (그쪽이 트리거 제거까지 함께 처리한다).
          if (name === doneEmojiName()) toggleDone(emTarget, on);
          else toggleRx(emTarget, name, on);
          hidePopup();
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
          const body = document.getElementById('dbgBody');
          const show = dbgOn && cache && cache.debugButtons;
          panel.style.display = show ? '' : 'none';
          if (!show) return;
          // 앱 액션과 데몬 액션(수집·번역·자동 처리완료)이 한 타임라인으로 합쳐져
          // 온다 — 어느 쪽이 한 일인지 앞에 칩으로 구분한다.
          const rows = (actionsCache||[]).slice().reverse().slice(0,80).map(a=>
            `<tr><td>${whenS(a.at)}</td>
             <td>${a.by==='daemon'?'<span class="who">데몬</span> ':''}${esc(a.action)}</td>
             <td class="ms">${a.ms}ms</td>
             <td class="${a.ok?'ok':'bad'}">${a.ok?'✓':'✗ '+esc(a.error||'')}</td>
             <td class="dt">${esc(a.detail||'')}${a.id?' · '+esc(a.id):''}</td></tr>`).join('');
          // panel이 아니라 body만 다시 쓴다 — 패널 머리의 수집 경로 칩은 reflectHealth가
          // 따로 갱신하는 실제 DOM이라, 여기서 통째로 덮으면 사라진다.
          body.innerHTML = '<h3>액션 로그 — 모든 액션 · 소요시간 (최신순)</h3>'
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
        // ----- 연동 관리 모달 -----
        // 이 페이지는 외부 연동 4키(슬랙 사용자/앱 토큰 + Gemini/Claude API 키)와
        // 보조 2개(Claude CLI 번역 폴백, 스피킹=ChatGPT 웹)에 기댄다. 어느 하나가
        // 죽으면 화면은 그냥 "조용히 안 늘어난다"가 되므로, 모달을 열면 서버가
        // 키체인 존재 + 실제 API 호출로 전부 라이브 검증해 어디가 끊겼는지 즉답한다
        // (POST /api/slack/integrations/check — 키 값 자체는 절대 내려오지 않는다).
        const INT_SECTIONS = [
          { name:'슬랙 수집', rows:[
            { k:'slackUser', name:'사용자 토큰', svc:'cm-slack-user-token', acct:'slack',
              role:'메시지 수집 · 스레드 답장 · 리액션 동기화 (xoxp-)' },
            { k:'slackApp', name:'앱 토큰', svc:'cm-slack-app-token', acct:'slack',
              role:'실시간 수신 Socket Mode (xapp-)' } ]},
          { name:'번역', rows:[
            { k:'gemini', name:'Gemini API 키', svc:'cm-gemini-api-key', acct:'gemini',
              role:'Gemini Flash-Lite · Flash 번역 (기본 모델)' },
            { k:'anthropic', name:'Claude API 키', svc:'cm-anthropic-api-key', acct:'anthropic',
              role:'Claude Haiku API 직통 번역' },
            { k:'claudeCli', name:'Claude CLI 구독', svc:'', acct:'',
              role:'번역 폴백 — 키 불필요, CLI 로그인 세션 사용' } ]},
          { name:'스피킹', rows:[
            { k:'speaking', name:'ChatGPT 웹', svc:'', acct:'',
              role:'브라우저 로그인 세션으로 연동 — 토큰 불필요 (추후 다른 엔진으로 교체 가능)' } ]},
        ];
        // 실시간(Socket Mode) 수신에 필요한 유저 이벤트 — 슬랙 앱 설정에 이 4개가
        // 없으면 message 이벤트가 영영 안 와서 폴링만 돈다. 가이드와 배너 안내가
        // 같은 배열을 쓴다 (두 곳에 손으로 적어두면 어긋난다).
        const RT_EVENTS = ['message.channels','message.groups','message.im','message.mpim'];
        // 스코프 목록의 원본은 Swift(SlackIntegrations.requiredUserScopes)이고 검사
        // 응답(userScopes)으로 내려온다 — 아래는 응답이 없을 때만 쓰는 폴백.
        const FALLBACK_SCOPES = ['reactions:read','reactions:write','chat:write',
          'channels:history','groups:history','im:history','mpim:history',
          'channels:read','groups:read','im:read','mpim:read'];
        let intData = null, intBusy = false, intAt = 0;
        // 가이드 펼침 — null이면 '자동'(슬랙 토큰이 실제로 문제일 때만 펼침),
        // true/false면 사용자가 직접 정한 상태를 존중한다.
        let intGuide = null;
        // 툴바 버튼 경고 — 피드에 이미 실려 오는 신호만으로 판단한다 (라이브 검사는
        // 모달을 열 때만): 데몬이 토큰 거부를 보고했거나, 선택된 번역 모델의 키가 없다.
        function intWarn(){
          if (!cache) return false;
          const h = cache.health || {};
          if (h.state === 'auth') return true;
          const m = cache.model || 'gemini-flash-lite';
          if (['gemini-flash-lite','gemini-flash'].includes(m) && !cache.geminiKey) return true;
          if (m === 'haiku-api' && !cache.anthropicKey) return true;
          return false;
        }
        function reflectIntegrations(){
          document.getElementById('intBtn').classList.toggle('on', intWarn());
        }
        function openIntegrations(guide){
          if (guide) intGuide = true;
          if (document.getElementById('intModal')) { renderIntModal(); return; }
          const m = document.createElement('div');
          m.className = 'imodal'; m.id = 'intModal';
          m.addEventListener('mousedown', e=>{ if (e.target === m) closeIntegrations(); });
          document.body.appendChild(m);
          renderIntModal();
          runIntCheck();
        }
        function closeIntegrations(){
          const m = document.getElementById('intModal');
          if (m) m.remove();
        }
        function runIntCheck(){
          intBusy = true; renderIntModal();
          fetch('/api/slack/integrations/check',{method:'POST',
            headers:{'Content-Type':'application/json'}, body:'{}'})
            .then(r=>r.json()).then(j=>{ intData = j; intAt = Date.now(); })
            .catch(()=>{ intData = { error:'network' }; })
            .finally(()=>{ intBusy = false; renderIntModal(); });
        }
        // 실패 원인 → 사람이 할 일. 원인별로 다른 조치가 필요하다는 것 자체가
        // 이 모달의 존재 이유다 (토큰 재발급 vs 스코프 추가 vs 데몬 재시작).
        function intHint(k, err){
          if (k === 'slackUser' || k === 'slackApp'){
            if (['token_revoked','invalid_auth','account_inactive','token_expired'].includes(err))
              return '토큰이 만료·회수됐습니다 — 아래 \'슬랙 토큰 재발급\' 가이드를 순서대로 따라 하면 끝납니다.';
          }
          if (k === 'gemini') return 'Google AI Studio에서 키를 확인하고 아래 명령으로 갱신하세요.';
          if (k === 'anthropic') return 'Anthropic Console에서 키를 확인하고 아래 명령으로 갱신하세요.';
          if (k === 'claudeCli') return 'claude CLI가 설치돼 있으면 번역 키가 없어도 구독으로 번역합니다 (없어도 다른 키가 있으면 무관).';
          return '';
        }
        function intRow(row){
          const c = (intData && intData.checks && intData.checks[row.k]) || null;
          let cls = 'wait', label = '확인 중', det = '', err = '';
          if (row.k === 'speaking'){
            // 토큰이 아예 없는 웹 연동 — 검증할 키가 없다는 사실 자체를 보여준다.
            cls = 'ok'; label = '웹 연동';
            det = '스피킹 시작을 누르면 chatgpt.com이 열리고 브리핑이 자동 주입됩니다.';
          } else if (!intBusy && !c){
            cls = 'warn'; label = '확인 실패'; err = '서버 응답에 이 항목이 없습니다.';
          } else if (!intBusy && c){
            if (c.state === 'ok' && c.missingScopes && c.missingScopes.length){
              cls = 'warn'; label = '스코프 부족';
              det = c.detail || '';
              err = '토큰은 유효하지만 일부 기능이 조용히 실패합니다 — 누락: '
                + c.missingScopes.join(', ')
                + '. 아래 재발급 가이드 5번(스코프 추가) → 6번(재설치·토큰 갱신) 순서로 하면 됩니다.';
            } else if (c.state === 'ok'){
              cls = 'ok'; label = '정상'; det = c.detail || '';
            } else if (c.state === 'missing'){
              cls = 'warn'; label = row.svc ? '키 없음' : '없음';
              err = intHint(row.k, '') || (row.svc ? '키체인에 항목이 없습니다 — 아래 명령으로 등록하세요.' : '');
              if (row.k === 'claudeCli') err = intHint('claudeCli','');
            } else {
              cls = 'warn'; label = '실패';
              err = (c.error || '') + ' — ' + (intHint(row.k, c.error||'') || '아래 명령으로 키를 갱신하세요.');
            }
          }
          const acct = (c && c.account) || row.acct;
          const cmd = row.svc && cls === 'warn'
            ? `<code onclick="copyCmd(this)" title="클릭하면 복사">security add-generic-password -U -s ${esc(row.svc)} -a ${esc(acct)} -w</code>`
            : '';
          return `<div class="irow">
            <div class="ihead"><span class="iname">${esc(row.name)}</span>
              ${row.svc?`<span class="isvc">${esc(row.svc)}</span>`:''}
              <span class="ist ${cls}"><span class="dot"></span>${esc(label)}</span></div>
            <div class="irole">${esc(row.role)}</div>
            ${det?`<div class="idet">${esc(det)}</div>`:''}
            ${err?`<div class="ierr">⚠ ${esc(err)}</div>`:''}
            ${cmd}</div>`;
        }
        // ----- 토큰 재발급 가이드 -----
        // 이 조치는 대부분 앱 밖(슬랙 웹 설정)에서 일어나서, 예전에는 "토큰을 다시
        // 발급하세요" 한 줄만 주고 어디서 무엇을 누르는지는 사람이 알아서 찾아야 했다.
        // 그 검색을 없애려고 메뉴 경로·버튼 이름·순서를 전부 여기 적어 둔다.
        // 순서에 의미가 있다: 이벤트 구독·스코프를 먼저 손보면 재설치 한 번으로
        // 토큰 갱신까지 같이 끝난다 (재설치를 두 번 하지 않는다).
        function intSlackBad(){
          const c = (intData && intData.checks) || null;
          if (!c) return false;
          return ['slackUser','slackApp'].some(k=> c[k]
            && (c[k].state !== 'ok' || ((c[k].missingScopes||[]).length > 0)));
        }
        function toggleIntGuide(){
          intGuide = !(intGuide === null ? intSlackBad() : intGuide);
          renderIntModal();
        }
        function intGuideHTML(){
          const open = intGuide === null ? intSlackBad() : intGuide;
          const scopes = (intData && intData.userScopes) || FALLBACK_SCOPES;
          // 계정명(-a)은 이미 등록된 키체인 항목에서 그대로 가져온다. 'slack'으로
          // 굳혀 두면 계정이 다른 사용자는 같은 서비스에 항목이 둘 생기고, 조회가
          // 엉뚱한 쪽을 집어 "갱신했는데 그대로"가 된다.
          // 토큰을 넣는 자리는 이제 플러그인 카드다 (붙여넣으면 앱이 키체인에 저장하고
          // 바로 연결까지 확인한다). 터미널 명령은 값에 따옴표·공백이 섞여 앱이 저장을
          // 거부하는 드문 경우를 위한 폴백으로만 남긴다.
          const cmd = (svc, k) => {
            const acct = ((intData && intData.checks && intData.checks[k]) || {}).account || 'slack';
            return `<div class="gpick"><b>붙여넣을 곳:</b> `
              + `<a href="/?plugins=1">플러그인 &gt; 슬랙 번역 카드 ↗</a> — 토큰을 붙여넣고 저장하면 연결까지 바로 확인합니다.</div>`
              + `<code onclick="copyCmd(this)" title="클릭하면 복사 — 터미널로 등록하는 폴백">`
              + `security add-generic-password -U -s ${svc} -a ${acct} -w</code>`;
          };
          const steps = [
            `<b>어디가 문제인지 먼저 봅니다.</b> 위 <b>슬랙 수집</b> 두 줄 중 <b>사용자 토큰</b>이
             빨간 상태면 1~5번을, <b>앱 토큰</b>만 문제면 6번만 하면 됩니다.`,
            `<b>슬랙 앱 설정을 엽니다.</b>
             <a href="https://api.slack.com/apps" target="_blank">api.slack.com/apps ↗</a>
             → 이 워크스페이스에 설치한 앱을 클릭.`,
            `<b>Socket Mode가 켜져 있는지 확인합니다.</b>
             왼쪽 메뉴 <span class="path">Settings &gt; Socket Mode</span> →
             <b>Enable Socket Mode</b>. 이게 켜져 있어야 공개 URL 없이 실시간 수신이 됩니다.`,
            `<b>실시간 수신용 이벤트 ${RT_EVENTS.length}개를 추가합니다.</b>
             왼쪽 메뉴 <span class="path">Features &gt; Event Subscriptions</span> →
             <b>Enable Events</b> 켜기 → 아래 <b>Subscribe to events on behalf of users</b>를 펼치고
             (<span class="warnx">⚠ 위쪽 Subscribe to bot events가 아닙니다</span>)
             <b>Add Workspace Event</b>로 하나씩 추가 → <b>Save Changes</b>.
             <code onclick="copyCmd(this)" title="클릭하면 복사">${RT_EVENTS.join('\n')}</code>`,
            `<b>사용자 토큰 스코프 ${scopes.length}개가 다 있는지 봅니다.</b>
             왼쪽 메뉴 <span class="path">Features &gt; OAuth &amp; Permissions</span> → 스크롤해서
             <b>Scopes &gt; User Token Scopes</b>
             (<span class="warnx">⚠ Bot Token Scopes가 아닙니다</span>) →
             빠진 것은 <b>Add an OAuth Scope</b>로 추가. 하나만 없어도 "연결은 되는데 일부만
             조용히 실패"가 됩니다.
             <code onclick="copyCmd(this)" title="클릭하면 복사">${scopes.join('  ')}</code>`,
            `<b>재설치해서 사용자 토큰(xoxp-)을 새로 받습니다.</b>
             같은 <span class="path">OAuth &amp; Permissions</span> 페이지 맨 위
             <b>Reinstall to Workspace</b> → 권한 화면에서 <b>허용(Allow)</b> →
             돌아온 페이지의 <b>User OAuth Token</b>(xoxp-…) <b>Copy</b>.
             터미널을 열어 아래 명령을 실행하고 프롬프트에 붙여넣습니다
             (입력이 화면에 안 보이는 것이 정상이고, 확인을 위해 두 번 물어봅니다).
             ${cmd('cm-slack-user-token','slackUser')}`,
            `<b>앱 토큰(xapp-)은 별도입니다.</b> 재설치로 갱신되지 않습니다 — 위 상태에서
             앱 토큰이 실패일 때만 하세요. 왼쪽 메뉴
             <span class="path">Settings &gt; Basic Information</span> → 아래
             <b>App-Level Tokens</b> → <b>Generate Token and Scopes</b> → 이름은 아무거나 +
             <b>Add Scope</b>로 <b>connections:write</b> → <b>Generate</b> → xapp- 토큰 복사.
             ${cmd('cm-slack-app-token','slackApp')}`,
            `<b>앱에 반영합니다.</b> 아래 <b>다시 연결 (데몬 재시작)</b> → <b>다시 확인</b> →
             슬랙 수집 두 줄이 모두 정상이면 끝. 슬랙에서 아무 메시지에 👀를 달아
             이 페이지에 뜨는지까지 보면 확실합니다.`,
          ];
          return `<div class="iguide">
            <div class="gh" onclick="toggleIntGuide()">
              <span>슬랙 토큰 재발급 · 실시간 수신 켜기</span>
              <span class="gsub">앱 밖(슬랙 웹)에서 할 일까지 이 순서 그대로</span>
              <span class="gcv">${open?'접기 ▲':'펼치기 ▼'}</span></div>
            ${open?`<div class="gbody">${steps.map((s,i)=>
              `<div class="gstep"><div class="gno">${i+1}</div><div class="gtx">${s}</div></div>`
            ).join('')}</div>`:''}</div>`;
        }
        function renderIntModal(){
          const m = document.getElementById('intModal');
          if (!m) return;
          const netFail = !intBusy && intData && intData.error === 'network';
          const when = intAt ? Math.round((Date.now()-intAt)/1000) : 0;
          const stTxt = intBusy ? '실제 API를 호출해 검증하는 중…'
            : netFail ? '앱에 연결할 수 없습니다'
            : intData ? `확인 완료 — ${when<3?'방금':when+'초 전'} · ${intData.ms||0}ms` : '';
          m.innerHTML = `<div class="ipanel" onmousedown="event.stopPropagation()">
            <h2>연동 관리</h2>
            <div class="isub">이 페이지가 기대는 외부 연동의 키 등록(키체인)과 실제 연결을 한 번에 검증합니다 — 키 값은 표시하지 않습니다.
              키 등록·교체와 모델 연동 관리는 <a href="/?plugins=1">플러그인 화면</a>의 연동 목록 한곳에서 합니다.</div>
            ${INT_SECTIONS.map(sec=>`<div class="isec">${esc(sec.name)}</div>`
              + sec.rows.map(intRow).join('')
              + (sec.name === '슬랙 수집' ? intGuideHTML() : '')).join('')}
            <div class="ifoot">
              <button onclick="runIntCheck()" ${intBusy?'disabled':''}>다시 확인</button>
              <button class="ghost" onclick="intRestartDaemon(this)" ${intBusy||rsTimer?'disabled':''}
                title="키를 갱신한 뒤에는 데몬을 재시작해야 새 키를 읽습니다">다시 연결 (데몬 재시작)</button>
              <button class="ghost" onclick="location.href='/?plugins=1'"
                title="키 등록·교체와 모델 연동은 플러그인 화면의 연동 목록 한곳에서 관리합니다">연동 목록 열기</button>
              <button class="ghost" onclick="closeIntegrations()">닫기</button>
              <span class="st" id="intSt">${esc(rsMsg)}</span>
              <span class="st">${esc(rsMsg?'':stTxt)}</span>
            </div>
            <div class="inote">키를 갱신했다면 <b>다시 연결</b>로 수집 데몬을 재시작해야 반영됩니다 (데몬은 번역 키를 시작할 때 한 번만 읽습니다). 번역 모델·언어 변경은 재시작 없이 즉시 적용됩니다.</div>
          </div>`;
        }
        // 모달의 '다시 연결'도 배너와 같은 타이머를 쓴다 — 어느 쪽에서 눌렀든
        // 사용자가 보는 것은 "몇 초째 기다리는 중 → 몇 초 걸려 붙었다" 하나여야 한다.
        function intRestartDaemon(btn){
          btn.disabled = true;
          beginRestart();
          fetch('/api/slack/daemon/restart',{method:'POST'}).then(r=>r.json()).then(j=>{
            if (!j.ok) rsFail = '재시작 실패 — 위 명령을 직접 실행해 주세요';
            // 붙었는지는 5초 피드가 판정한다. 검사 결과도 새로 받아 둔다.
            setTimeout(()=>{ load(); runIntCheck(); }, 3000);
          }).catch(()=>{ rsFail = '앱에 연결할 수 없습니다'; })
            .finally(()=>{ paintRestart(); });
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
        // ----- 컨텍스트 공유하기: 목표를 먼저 정하고 원 대화 전문까지 세션에 넘긴다 -----
        // 단순 추출(guiSession)은 카드에 있는 것만 넘긴다. 그런데 정작 판단에 필요한 앞
        // 맥락("문제부터 정의하라" 같은 앞선 결정)은 카드에 없고 슬랙에만 있어서, 세션이
        // 대화를 이어받아도 겉도는 답을 했다 (user request 2026-08-22). 여기서는 (1) 이
        // 대화로 달성하려는 목표를 사람이 한 줄로 적고, (2) 서버가 슬랙에서 원 대화를 다시
        // 긁어 목표 폴더에 문서로 저장한다 (POST /api/slack/context — goal-add 가 목표를
        // 만든 직후 호출). 세션은 그 목표를 기준으로 매 턴 답장 초안을 낸다.
        function openCtxShare(id){
          // 접힌 항목엔 패널이 눌려 보이지 않는다 — 답장창과 같은 이유로 먼저 펼친다.
          let item = itemEl(id);
          if (!expanded.has(id)){ expanded.add(id); render(); item = itemEl(id); }
          if (!item) return;
          const ex = item.querySelector('.ctx-box');
          if (ex){ ex.remove(); return; }
          const box = document.createElement('div');
          box.className = 'reply-box ctx-box';
          box.innerHTML = `<div class="ctx-head">이 대화로 달성하려는 목표</div>
            <textarea placeholder="예) 이 제품 방향이 맞다는 걸 인정받고, 다음 주에 검증 회의를 잡는다"></textarea>
            <div class="row">
            <span class="hint">목표를 세션에 고정하고, 슬랙 원 대화(스레드 전체 + 앞 40개)를 문서로 함께 넘깁니다</span>
            <span class="st"></span>
            <button class="send">세션 시작</button></div>`;
          item.appendChild(box);
          const ta = box.querySelector('textarea');
          ta.focus();
          const go = ()=>{
            const goal = ta.value.trim();
            if (!goal){ ta.focus(); return; }
            box.querySelector('.send').disabled = true;
            const st = box.querySelector('.st');
            st.textContent = '세션 여는 중…'; st.className = 'st';
            ctxSession(id, goal);
          };
          box.querySelector('.send').onclick = go;
          // ⌘/Ctrl+Enter 로도 시작 (답장창과 같은 손버릇), Esc 는 패널만 닫는다.
          ta.addEventListener('keydown', e=>{
            if ((e.metaKey || e.ctrlKey) && e.key === 'Enter'){ e.preventDefault(); go(); }
            else if (e.key === 'Escape'){ e.preventDefault(); e.stopPropagation(); box.remove(); }
          });
        }
        function ctxSession(id, goal){
          const it = ((cache&&cache.items)||[]).find(x=>x.id===id); if (!it) return;
          const L = [];
          L.push('[목표] ' + goal);
          L.push('');
          L.push('Slack 대화 대응: #'+(it.channelName||it.channel||'')+(it.author?' — '+it.author:''));
          if (it.textKo && it.textKo !== it.textEn){
            L.push('','[대상 메시지 번역]',it.textKo,'','[원문]',it.textEn);
          } else {
            L.push('','[대상 메시지]',it.textKo||it.textEn||'');
          }
          if (it.meaning) L.push('','[의미 분석]',it.meaning);
          if (it.decision) L.push('','[의사결정 선택지]',it.decision);
          if (it.permalink) L.push('','[슬랙 링크] '+it.permalink);
          L.push('','위 목표를 이 세션의 기준점으로 삼아라. 원 대화 전문을 먼저 읽고 지금 대화가 어디까지 왔는지 정리한 뒤, 목표를 향해 다음에 보낼 답장 초안을 제안해줘. 이후 상대의 새 메시지를 붙여넣을 때마다 같은 방식으로 이어가면 된다.');
          // 목표 본문은 goal-core.md 로도 남는다 (서버 /api/slack/context) — 같은 오리진
          // localStorage 계약으로 goal-add 에 넘긴다 (초안 cm.gaDraft 와 같은 방식).
          try{
            localStorage.setItem('cm.gaDraft', L.join('\n'));
            localStorage.setItem('cm.gaSlackGoal', goal);
          }catch(e){}
          // 목록에 걸릴 제목은 목표 한 줄로 짧게 (본문 전체가 제목이 되면 보드가 읽히지 않는다).
          const title = 'Slack 대응: ' + goal.split('\n')[0].slice(0, 50);
          location.href = '/goal-add?bump=1&label='+encodeURIComponent('Slack 스레드')
            +'&start=1&preset=slack&slackCtx=1'
            +'&slackId='+encodeURIComponent(id)
            +'&gtitle='+encodeURIComponent(title);
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
        // ================= 첨부 근거 (멀티모달) =================
        // 데몬이 이미지·PDF·영상·YouTube·링크에서 뽑아낸 근거를 optional 필드로
        // 실어 보낸다: media[] (원소 = type·name·url·method·text·error)와
        // mediaAt(추출 시각). 둘 다 없는 옛 레코드가 대부분이므로 — 지금 쌓여 있는
        // 1256건에는 하나도 없다 — 모든 접근은 없는 값을 전제로 한다. 없으면 섹션
        // 자체를 그리지 않는다: 라벨만 남은 빈 상자는 화면이 고장 난 것처럼 보인다.
        const MEDIA_TYPES = {
          image:   ['🖼', '이미지'],
          pdf:     ['📄', 'PDF'],
          video:   ['🎬', '영상'],
          youtube: ['▶️', 'YouTube'],
          link:    ['🔗', '링크'],
          audio:   ['🎧', '오디오'],
        };
        // 모르는 type(unknown 포함)도 버리지 않는다 — 첨부가 있었다는 사실은 남긴다.
        function mediaFace(t){
          return MEDIA_TYPES[String(t||'').toLowerCase()] || ['📎', '첨부'];
        }
        // 배열이 아니면 빈 배열 — 옛 레코드(media 없음)와 깨진 값이 여기서 함께 걸러진다.
        // 원소가 객체가 아니어도 빈 객체로 바꿔, 카드 하나가 목록 전체를 죽이지 않게 한다.
        // 유형도 이름도 주소도 본문도 실패 사유도 없는 원소는 버린다 — 그 줄은 사람에게
        // 아무것도 말해 주지 않는 껍데기고, 첨부가 있었다는 사실조차 담고 있지 않다.
        function mediaList(it){
          const a = it && it.media;
          if (!Array.isArray(a)) return [];
          return a.map(m => (m && typeof m === 'object') ? m : {})
                  .filter(m => m.type || m.name || m.url || m.text || m.error);
        }
        // 추출 시각 — 초/밀리초 어느 쪽으로 와도 읽는다 (when()은 초를 받는다).
        function mediaAtSec(v){
          const n = Number(v);
          if (!isFinite(n) || n <= 0) return 0;
          return Math.floor(n > 1e11 ? n / 1000 : n);
        }
        // 링크로 걸어도 되는 주소인지 — 첨부 URL은 슬랙 밖에서 온 문자열이고,
        // esc()는 HTML만 막지 javascript: 같은 스킴은 막지 못한다. http(s)만 통과.
        function safeURL(u){
          const s = String(u || '').trim();
          return /^https?:\/\//i.test(s) ? s : '';
        }
        // 이름이 없으면 URL 끝의 파일명, 그것도 없으면 유형 이름으로 대신한다.
        function mediaName(m, label){
          const n = String(m.name || '').trim();
          if (n) return n;
          const u = safeURL(m.url);
          if (!u) return label;
          try{
            const p = new URL(u);
            const seg = p.pathname.split('/').filter(Boolean).pop();
            return seg ? decodeURIComponent(seg) : p.hostname;
          }catch(e){ return u; }
        }
        // 펼친 근거 본문 — 항목 접기(expanded)와 같은 이유로 화면 메모리에만 둔다.
        // 폴링 재렌더에는 유지되고 페이지를 다시 열면 전부 접힌 상태로 시작한다.
        const mediaOpen = new Set();
        function toggleMedia(key){
          if (mediaOpen.has(key)) mediaOpen.delete(key); else mediaOpen.add(key);
          render();
        }
        function mediaHTML(it){
          const list = mediaList(it);
          if (!list.length) return '';
          const at = mediaAtSec(it.mediaAt);
          const bad = list.filter(m => m.error).length;
          const rows = list.map((m, i) => {
            const face = mediaFace(m.type), ic = face[0], label = face[1];
            const key = it.id + '#' + i;
            const open = mediaOpen.has(key);
            const text = typeof m.text === 'string' ? m.text : '';
            const err = String(m.error || '');
            const url = safeURL(m.url);
            const method = String(m.method || '').trim();
            // 본문이 있을 때만 누를 수 있는 줄이 된다 — 눌러도 아무 일 없는 버튼을
            // 두지 않으려고 disabled 로 잠근다 (항목 접기 클릭도 통과하지 않는다).
            const head = text
              ? `onclick="toggleMedia('${escA(key)}')" title="추출된 근거 ${text.length}자 — 클릭하면 ${open?'접힙니다':'펼쳐집니다'}"`
              : 'disabled';
            return `<div class="md-row${err?' bad':''}">
              <div class="md-line">
                <button class="md-tog" ${head}>
                  <span class="md-cv">${text ? (open?'▾':'▸') : '·'}</span>
                  <span class="md-ic">${ic}</span>
                  <span class="md-ty">${label}</span>
                  <span class="md-nm">${esc(mediaName(m, label))}</span>
                  ${method ? `<span class="md-me" title="이 근거를 뽑아낸 경로">${esc(method)}</span>` : ''}
                  ${text ? `<span class="md-len">${text.length}자</span>` : ''}
                </button>
                ${url ? `<a class="md-ln" href="${escA(url)}" target="_blank" rel="noreferrer"
                  title="원본 열기 — ${escA(url)}">↗</a>` : ''}
              </div>
              ${err ? `<div class="md-err">⚠ 읽지 못했습니다 — ${esc(err)}</div>` : ''}
              ${(!err && !text) ? '<div class="md-non">읽었지만 추출된 내용이 없습니다</div>' : ''}
              ${(text && open) ? `<div class="md-tx">${esc(text)}</div>` : ''}
            </div>`;
          }).join('');
          return `<div class="media">
            <div class="md-head">첨부 근거
              <span class="md-n">${list.length}</span>
              ${bad ? `<span class="md-bad">읽기 실패 ${bad}</span>` : ''}
              ${at ? `<span class="md-at" title="첨부에서 근거를 뽑아낸 시각">${when(at)}</span>` : ''}
            </div>${rows}</div>`;
        }
        // ----- 세그 분류 -----
        // done → backlog → ai → wait 순으로 판정하고, 위에서 걸리면 거기서 끝난다.
        // backlogClosedAt·ackAt 은 옛 레코드에 아예 없다. 없는 것이 기본값이고,
        // 없으면 그냥 다음 줄로 내려가면 된다 (없다고 해서 예외가 나지 않는다).
        function bucketOf(it, doneMap){
          if (doneMap[it.id] || it.autoDone) return 'done';
          if (it.backlogClosedAt) return 'backlog';
          if (it.ackAt) return 'ai';
          return 'wait';
        }
        // 이모지 자동 해결 칩 — 누가 달았느냐로 문구가 갈린다. autoByMe 는 옛 레코드에
        // 없고, 없음(undefined)은 '다른 사람이 함'(false)이 아니라 '누가 했는지 모름'
        // 이다. 셋을 각각 다르게 적는다 — 없는 것을 false 로 뭉개면 옛 938건이 전부
        // 남이 처리한 것으로 읽힌다.
        function autoTagHTML(it){
          if (!it.autoDone) return '';
          const emo = it.autoEmoji ? ` (:${esc(it.autoEmoji)}:)` : '';
          if (it.autoByMe === true)
            return `<span class="atag" title="라이언 본인이 슬랙에서 직접 이모지를 달아 처리한 것입니다. AI가 처리한 것이 아닙니다.">✅ 내가 슬랙에서 처리${emo}</span>`;
          if (it.autoByMe === false)
            return `<span class="atag" title="나 아닌 다른 사람이 슬랙에서 리액션을 달아 처리된 것으로 봤습니다. 그 리액션이 사라지면 다시 결정 대기로 돌아옵니다.">✅ 다른 사람이 처리${emo}</span>`;
          return `<span class="atag" title="트리거(👀·🔖·📌)가 아닌 리액션이 달려 이미 처리된 것으로 봤습니다. 그 리액션이 사라지면 다시 미처리로 돌아옵니다.">✅ 이모지로 해결됨${emo}</span>`;
        }
        function render(){
          if (!cache) return;
          reflectFilter();
          reflectModel();
          reflectLang();
          reflectSort();
          reflectSources();
          reflectDbg();
          reflectHealth();
          reflectIntegrations();
          // 답장 작성/수정 중엔 재렌더로 입력을 날리지 않는다 (폴링은 계속, 그리기만 보류).
          if (document.querySelector('#list .reply-box, #list .mr-editing, #list .mr-arming, #list .menu.open')) return;
          const doneMap = cache.done || {};
          const replies = cache.replies || {};
          const syncErr = cache.syncErr || {};
          // 정렬 기준 = 툴바 선택값(sortBy). 기본은 트리거 발생 시각 — 이미 수집된
          // 메시지에 리액션을 다시 달면 데몬이 triggeredAt을 갱신하고 처리완료를
          // 해제하므로 맨 위로 올라온다.
          let items = (cache.items||[]).slice().sort((a,b)=>sortKey(b)-sortKey(a));
          // 한 번만 훑어 네 갈래로 나눈다. done 은 목록으로 쓰지 않지만(전체 뷰에
          // 섞여 나온다) 카운트 계산을 한 곳에서 끝내려고 같이 담는다.
          const bucket = { wait:[], ai:[], backlog:[], done:[] };
          for (const it of items) bucket[bucketOf(it, doneMap)].push(it);
          const waitItems = bucket.wait;
          const laterN = waitItems.filter(it=>it.later).length;
          document.getElementById('count').textContent =
            `결정 대기 ${waitItems.length}${laterN?` · 📌 Later ${laterN}`:''}`
            + ` · AI 처리 ${bucket.ai.length} · 백로그 ${bucket.backlog.length}`
            + ` · 전체 ${items.length}`;
          const eb = document.getElementById('expBtn');
          eb.textContent = expanded.size ? '모두 접기' : '모두 펼치기';
          eb.classList.toggle('on', expanded.size > 0);
          const gb = document.getElementById('grpBtn');
          if (gb) gb.classList.toggle('on', groupThreads);
          const list = document.getElementById('list');
          // 빈 화면의 뜻은 세그마다 다르다. '결정 대기'가 비면 그건 좋은 상태이고,
          // '백로그'가 비면 남은 게 없다는 뜻이다. 수집 자체가 처음이면 어느 세그든
          // 같은 안내를 준다.
          const emptyBody = ()=>{
            if (!items.length) return '아직 번역된 메시지가 없습니다.<br>슬랙에서 메시지에 👀 리액션(🔖/📌는 Later로)을 달거나, 나·내 팀 멘션 / DM / @here·@channel 알림이 오면 여기 나타납니다.';
            if (filter==='wait'){
              // 백로그는 숨긴 게 아니라 따로 모아 둔 것이므로, 결정 대기가 비었을 때
              // 남은 백로그 건수를 여기서 다시 알려 잊히지 않게 한다.
              return '결정할 것이 없습니다 🎉'
                + (bucket.backlog.length
                    ? `<br>🗄 백로그 ${bucket.backlog.length}건은 따로 있습니다` : '');
            }
            if (filter==='ai') return 'AI가 슬랙에 응답한 항목이 없습니다.';
            if (filter==='backlog') return '백로그가 없습니다 — 파이프라인 도입 전 미분류분이 남아 있지 않습니다.';
            return '미처리 항목이 없습니다 🎉';
          };
          const emptyHTML = '<div class="empty">'+emptyBody()+'</div>';
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
            // 첨부 근거 — 없는 게 기본이다 (옛 레코드엔 media 자체가 없다).
            const med = mediaList(it);
            const medBad = med.filter(m=>m.error).length;
            // 처리완료 = 슬랙에 ✅를 남기고 트리거(👀)를 뗀다. 빠른 버튼은 그
            // ✅를 빼고 늘어선다 (같은 이모지가 두 버튼이면 상태가 갈라진다).
            const dEmo = doneEmojiName();
            const quick = quickList().filter(n=>n!==dEmo);
            const mineList = myRx(it.id);
            const doneTitle = (noEmoji ? '처리완료' : `처리완료 — 슬랙 ${emo} 제거`)
              + ` · ${EMOJI_BY_NAME[dEmo]||''} 남김`;
            const rxg = rxGroups(it);
            const rxClick = (n, on) => n===dEmo
              ? `toggleDone('${esc(it.id)}', ${on?'true':'false'})`
              : `toggleRx('${esc(it.id)}','${esc(n)}', ${on?'true':'false'})`;
            return `<div class="item ${done?'done':''} ${exp?'':'collapsed'}"
              data-id="${esc(it.id)}" onclick="toggleItem(event,'${esc(it.id)}')">
              <div class="acts">
                <button title="스레드 답장" onclick="openReply(this,'${esc(it.id)}')">💬</button>
                <span class="sep"></span>
                <button class="${done?'on':''}" title="${doneTitle}"
                  onclick="toggleDone('${esc(it.id)}', ${done?'false':'true'})">✅</button>
                ${quick.map(n=>`<button class="rx ${mineList.includes(n)?'mine':''}"
                  title=":${esc(n)}: 리액션 — 슬랙 원문에 그대로 달립니다"
                  onclick="${rxClick(n, !mineList.includes(n))}">${emFace(n)}</button>`).join('')}
                <button title="이모지 고르기" onclick="openEmoji(this,'${esc(it.id)}')">＋</button>
                <span class="sep"></span>
                <span class="menu-wrap">
                  <button title="더보기" onclick="toggleMenu(this)">⋮</button>
                  <div class="menu">
                    ${it.permalink?`<a href="${esc(it.permalink)}" target="_blank" onclick="closeMenus()">슬랙에서 열기 ↗</a>`:''}
                    <button onclick="toggleDone('${esc(it.id)}', ${done?'false':'true'}); closeMenus()">${done?'처리완료 취소':(noEmoji?`처리완료 (${EMOJI_BY_NAME[dEmo]||''} 남김)`:`처리완료 (${emo} 제거 · ${EMOJI_BY_NAME[dEmo]||''} 남김)`)}</button>
                    <div class="mhdr">세션 추출</div>
                    ${guiLink(it.id)
                      ? `<button title="이 메시지로 이미 연 세션(goal-${pad2(guiLink(it.id).seq)})을 그대로 이어갑니다 — 그때 넣은 컨텍스트와 대화가 남아 있습니다"
                          onclick="closeMenus(); guiSession('${esc(it.id)}','')">세션 이어가기 (goal-${pad2(guiLink(it.id).seq)})</button>`
                      : `<button title="이 카드에 있는 것(번역·원문·의미 분석·의사결정)만 들고 AI 세션을 엽니다"
                          onclick="closeMenus(); guiSession('${esc(it.id)}','')">단순 추출</button>
                         <button title="달성하려는 목표를 먼저 정하고, 슬랙 원 대화 전문을 문서로 함께 넘겨 그 목표 기준으로 대화를 이어가게 합니다"
                          onclick="closeMenus(); openCtxShare('${esc(it.id)}')">컨텍스트 공유하기</button>`}
                  </div>
                </span>
              </div>
              <div class="meta">
                <span class="caret">${exp?'▾':'▸'}</span>
                <span class="ch">${esc(it.channelName||it.channel)}</span>
                <span class="au">${esc(it.author||'')}</span>
                <span class="tm${sortBy==='msg'?' key':''}" title="메시지가 슬랙에 올라온 시각">${when(msgAt(it)||trigAt(it))}</span>
                ${msgAt(it) && trigAt(it) - msgAt(it) >= COLLECT_GAP
                  ? `<span class="cat${sortBy==='trig'?' key':''}" title="수집·체크(👀를 단) 시각 — 툴바에서 정렬 기준으로 고를 수 있습니다">수집 ${when(trigAt(it))}</span>` : ''}
                ${retrig?`<span class="rtag" title="${esc(when(it.reactedAt))} 최초 수집 — 리액션을 다시 달아 미처리로 복귀">🔁 다시</span>`:''}
                ${SRC_TAGS[it.source]?`<span class="mtag">${SRC_TAGS[it.source]}</span>`:''}
                ${it.requestLevel!==undefined&&it.requestLevel!==null?`<span class="lvtag l${esc(it.requestLevel)}" title="내부 요청 분류 — 상대방에게는 표시되지 않습니다">L${esc(it.requestLevel)}</span>`:''}
                ${it.later?'<span class="ltag">📌 Later</span>':''}
                ${dbgOn && cache.debugButtons && it.model
                  ? `<span class="dbgbadge">⏱ ${esc(it.model)}${it.trMs?` · ${(it.trMs/1000).toFixed(1)}초`:''}</span>` : ''}
                ${nRep?`<span class="ctag rep">💬 ${nRep}</span>`:''}
                ${med.length?`<span class="ctag med${medBad?' warn':''}"
                  title="첨부 근거 ${med.length}건${medBad?` · 그중 ${medBad}건은 읽지 못함`:''} — 펼치면 보입니다">📎 ${med.length}</span>`:''}
                ${it.pending?'<span class="ctag">⏳</span>':''}
                ${(it.error||se)?'<span class="ctag warn">⚠</span>':''}
                ${it.backlogClosedAt?`<span class="atag bk" title="등급 부여 파이프라인(08-29) 도입 전에 수집된 항목입니다. 자동 분류되지 않아 결정 대기에서 뺐습니다.">🗄<span class="t"> 백로그</span></span>`:''}
                ${it.ackAt?`<span class="atag ai" title="AI가 이 메시지에 슬랙에서 실제로 응답했습니다.">🤖<span class="t"> AI 응답함</span></span>`:''}
                ${autoTagHTML(it)}
                ${done?'<span class="done-tag">✓ 처리완료</span>':''}
              </div>
              <div class="ko">${esc(it.textKo || it.textEn)}</div>
              ${it.textKo && it.textKo !== it.textEn
                ? `<div class="en">${esc(it.textEn)}</div>` : ''}
              ${mediaHTML(it)}
              ${tabsHTML(it)}
              ${it.pending ? '<div class="pend"><i></i>번역 중…</div>' : ''}
              ${it.error ? '<div class="err">⚠ 번역 실패 — 원문만 저장됨 (데몬 재시작 시 재시도)</div>' : ''}
              ${rxg.length || exp ? `<div class="rx-row">${rxg.map(([n,c,mine])=>
                `<button class="${mine?'mine':''}" title=":${esc(n)}:"
                  onclick="${rxClick(n, !mine)}">${emFace(n)}${c>1?`<span class="n">${c}</span>`:''}</button>`).join('')}
                <button class="more" title="이모지 고르기" onclick="openEmoji(this,'${esc(it.id)}')">＋</button></div>` : ''}
              ${se ? `<div class="err">⚠ 슬랙 리액션 ${se.action==='reaction.add'?'복원':'반영'} 실패: ${esc(se.error)}${esc(syncHint(se.error))}
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
          // 목록 한 덩어리를 그린다. 묶음이 꺼져 있으면 예전 그대로 평평하게 찍는다 —
          // 켜졌을 때만 스레드로 접어 넣으므로, 꺼 두면 이 기능이 없던 때와 같다.
          const rowsHTML = rows=>{
            if (!groupThreads) return rows.map(itemHTML).join('');
            const groups = new Map();
            for (const it of rows){
              const k = threadKey(it);
              if (!groups.has(k)) groups.set(k, []);
              groups.get(k).push(it);
            }
            // rows 는 이미 정렬돼 있으므로 Map 의 삽입 순서가 곧 묶음 순서다 (그 묶음의
            // 가장 앞선 항목의 자리). 묶음 안은 시각 오름차순으로 되돌린다 — 스레드는
            // 위에서 아래로 읽는 것이고, 목록의 최신순을 그 안에까지 밀어 넣으면
            // 대화가 거꾸로 보인다.
            return Array.from(groups.values()).map(g=>{
              if (g.length < 2) return itemHTML(g[0]);
              const g2 = g.slice().sort((a,b)=>(msgAt(a)||0)-(msgAt(b)||0));
              return `<div class="thgrp"><div class="thhdr">🧵 스레드`
                + `<span>${esc(g2[0].channelName||g2[0].channel||'')}</span>`
                + `<span class="n">${g2.length}</span></div>`
                + g2.map(itemHTML).join('') + `</div>`;
            }).join('');
          };
          // 결정 대기 뷰: 지금 처리할 것 먼저, Later 저장분은 📌 접이식 섹션으로 분리.
          // Later 는 결정 대기의 하위 그룹이라 세그를 하나 더 만들지 않고 섹션으로
          // 푼다 (접힘 상태는 localStorage에 기억).
          if (filter==='wait'){
            const now = waitItems.filter(it=>!it.later);
            const lat = waitItems.filter(it=>it.later);
            if (!now.length && !lat.length){ list.innerHTML = emptyHTML; return; }
            let h = rowsHTML(now);
            if (lat.length){
              h += `<div class="sechdr" onclick="toggleLaterSec()">📌 Later`
                + `<span class="n">${lat.length}</span><span class="arrow">${laterSec?'▾':'▸'}</span></div>`;
              if (laterSec) h += rowsHTML(lat);
            }
            list.innerHTML = h;
          } else {
            // ai·backlog 는 해당 갈래만, all 은 전부. 모르는 값이 들어와도 전체로
            // 떨어져 화면이 비지 않는다.
            const rows = filter==='ai' ? bucket.ai
              : filter==='backlog' ? bucket.backlog : items;
            list.innerHTML = rows.length ? rowsHTML(rows) : emptyHTML;
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
          // 연결 자체가 고장난 것(connBad)과, 연결은 멀쩡한데 개별 리액션 동기화만
          // 실패한 것(syncBad)은 서로 다른 문제다 — 전자는 "슬랙에 못 붙는다", 후자는
          // "붙어 있지만 이 항목 하나가 안 넘어간다"(흔히 원본 메시지가 지워진 경우).
          // 예전엔 둘을 하나로 합쳐 제목을 '슬랙 동기화 실패'로 덮어써서, 연결이
          // 정상인데도 그 밑에 "지금은 정상입니다"가 뜨는 모순이 생겼다. 이제 제목·색은
          // 연결 상태를 그대로 따르고, 동기화 실패는 배너 본문에 별도 섹션으로만 붙인다.
          const connBad = h.needsUser;
          const syncBad = errs.length > 0;
          const bad = connBad || syncBad;
          chip.style.display='';
          // degraded = 소켓만 조용히 죽은 상태. 앱·데몬이 스스로 여는 중이라
          // 재연결과 같은 대기색으로 둔다 (needsUser가 되면 아래 bad가 가져간다).
          const wait = h.state==='restarting' || h.state==='connecting' || h.state==='degraded';
          chip.className = 'hchip ' + (bad ? 'warn' : h.state==='ok' ? 'ok' : wait ? 'wait' : '');
          document.getElementById('hChipT').textContent = connBad
            ? `연결 및 동기화 실패${errs.length?' '+errs.length:''}`
            : syncBad ? `동기화 실패 ${errs.length}건`
            : h.title;
          chip.title = (bad ? '클릭하면 원인과 조치 방법이 나옵니다 — ' : '')
            + h.detail + (h.ageSec>=0 ? ` (${h.ageSec}초 전 확인)` : '');
          // 배너 = 문제가 있을 때 + 사용자가 칩을 눌러 자세히 볼 때 + '다시 연결'을
          // 눌러 결과를 기다리는 동안(붙자마자 배너가 사라지면 "몇 초 걸려 붙었다"는
          // 확인을 못 본 채 화면만 휙 바뀐다).
          if (!bad && !hDetail && !rsTimer){ banner.style.display='none'; hSig=''; return; }
          banner.style.display='';
          // 배너 색 = 연결 상태 기준(연결이 진짜 고장났을 때만 주황). 동기화만 실패한
          // 경우는 연결 칩 색(녹색/보라)을 그대로 두고, 실패 목록만 아래에 얹는다.
          banner.className = 'hbanner' + (connBad ? '' : h.state==='ok' ? ' ok' : wait ? ' wait' : '');
          // 5초 폴링마다 innerHTML을 다시 쓰면 방금 누른 버튼의 상태 문구가 지워진다 —
          // 내용이 실제로 바뀔 때만 다시 그린다.
          const path = pathState(h);
          const errSig = errs.map(x=>x.id+':'+(x.e.error||'')).join(',');
          // rsTimer도 서명에 넣는다 — 기다리는 동안 '다시 연결' 버튼을 잠그고,
          // 끝나면 다시 풀어야 한다 (사이에 상태가 안 바뀌어도).
          const sig = h.state+'|'+h.title+'|'+h.detail+'|'+h.advice+'|'+path.label+'|'+errSig
            +'|'+(rsTimer?'w':'');
          if (sig === hSig) return;
          hSig = sig;
          const cmd = h.command ? `<code onclick="copyCmd(this)" title="클릭하면 복사">${esc(h.command)}</code>` : '';
          const advice = h.advice || (h.state==='ok'
            ? '지금은 정상입니다. 문제가 생기면 앱이 먼저 스스로 복구를 시도하고, 그래도 안 되면 여기서 안내합니다.'
            : '앱이 자동으로 복구하는 중입니다 — 잠시 기다려 주세요.');
          // 알림 수집 경로 — 토큰·차단처럼 사용자가 풀어야 하는 문제가 있는 동안에는
          // 데몬 자체가 못 돌아 실시간·폴링이 둘 다 멈춘다. 그때의 경로 표시는 원인이
          // 아니라 결과일 뿐인데, 여기에 '실시간 켜는 법'까지 붙이면 조치가 두 개인
          // 것처럼 읽힌다 (토큰이 또 있는 줄 안다). 그래서 문제 중에는 안내를 접고,
          // 원인이 풀린 뒤 정말 폴링만 돌고 있을 때만 실시간 켜는 법을 띄운다.
          const rtHelp = (path.cls === 'ok' || h.needsUser) ? ''
            : '<br>즉시 받으려면 이 아래 🔗 연동 &gt; 슬랙 토큰 재발급 가이드의 3번'
              + '(Event Subscriptions에 ' + RT_EVENTS.join(' · ') + ' 추가)만 하면 됩니다.';
          const pathLine = h.needsUser
            ? `<p class="why">알림 수집: <b>${esc(path.label)}</b> — 위 문제가 풀리기 전까지는
                수집 경로를 판단할 수 없습니다 (데몬이 못 돌아 실시간·폴링이 둘 다 멈춘 상태).
                별도의 조치가 아니라 위 문제의 결과이니, 위 조치를 끝낸 뒤 이 줄을 다시 보세요.</p>`
            : `<p>알림 수집: <b>${esc(path.label)}</b> — ${esc(path.tip)}${rtHelp}</p>`;
          // 리액션 동기화 실패 목록. connBad일 때는 연결 실패 설명 아래에 이어 붙으므로
          // 자체 제목(굵은 줄)이 필요하지만, syncBad만 있을 때는 아래 head가 이미
          // "슬랙 리액션 동기화 실패 N건"을 h3로 말했으니 같은 문구를 또 반복하지 않는다.
          const errIntro = connBad
            ? `<b>슬랙 리액션 동기화 실패 ${errs.length}건</b> — 처리완료를 눌렀지만 슬랙 쪽 이모지가 그대로입니다.`
            : '처리완료를 눌렀지만 슬랙 쪽 이모지가 그대로인 항목입니다.';
          const errHTML = !errs.length ? '' : `<div class="serr">
            ${errIntro}
            ${errs.map(x=>`<div class="serr-row">· ${esc((x.it && (x.it.channelName||x.it.channel)) || x.id)}
              ${esc((x.it && (x.it.textKo||x.it.textEn)||'').slice(0,50))} —
              <b>${esc(x.e.error||'')}</b>${esc(syncHint(x.e.error))}</div>`).join('')}
            <div class="serr-row">1분마다 앱이 조용히 다시 시도합니다 — 원인이 풀리면 이 경고는 저절로 사라집니다.</div>
          </div>`;
          // head: connBad(진짜 연결 실패) 또는 평상시(hDetail로 연 상세)는 h.title 그대로
          // 쓰고 조치 문구(advice)·수집 경로(pathLine)까지 온전히 보여준다. syncBad만
          // 있을 때는 연결 쪽 제목을 "슬랙 동기화 실패"로 덮어쓰지 않고, "연결은
          // 정상입니다"를 명시한 뒤 바로 실패 목록으로 넘어간다 — 필러 조치 문구
          // ("지금은 정상입니다")를 실패 제목 아래 반복하지 않기 위해서다.
          const head = (syncBad && !connBad)
            ? `<h3>슬랙 리액션 동기화 실패 ${errs.length}건</h3>
               <div class="why">연결은 정상입니다 — ${esc(h.detail)}</div>
               ${pathLine}`
            : `<h3>${esc(h.title)}</h3>
               <div class="why">${esc(h.detail)}</div>
               <p>${esc(advice)}</p>
               ${pathLine}`;
          banner.innerHTML = `${head}
            ${errHTML}
            <div class="row">
              ${h.state==='auth'?'<button onclick="openIntegrations(true)">토큰 갱신 방법 보기</button>':''}
              <button onclick="restartDaemon(this)" ${rsTimer?'disabled':''}>다시 연결</button>
              ${errs.length?'<button onclick="retryAllSync(this)">동기화 재시도</button>':''}
              ${hDetail?'<button class="ghost" onclick="toggleHealth()">닫기</button>':''}
              <span class="st" id="hSt">${esc(rsMsg)}</span>
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
        // ----- '다시 연결' 진행 표시 -----
        // 눌러도 화면이 그대로면 사용자는 '눌리긴 한 건가'부터 의심한다. 재시작은
        // 데몬 부팅 + 소켓 재연결이라 몇 초~수십 초가 걸리고, 그 사이 5초 피드는
        // 아직 옛 상태를 들고 있다. 그래서 누른 순간부터 초를 세어 "지금 기다리는
        // 중"임을 계속 보여주고, 실제로 붙는 순간(health.state==='ok') 몇 초 걸렸는지로
        // 끝낸다 — 판정은 서버가 하고 여기서는 표시만 한다.
        const RS_GIVEUP = 90;   // 이만큼 지나도 안 붙으면 기다림이 아니라 남은 문제다
        let rsAt = 0, rsTimer = null, rsEnd = 0, rsMsg = '', rsFail = '';
        function beginRestart(){
          rsAt = Date.now(); rsEnd = 0; rsFail = ''; rsMsg = '재시작을 요청하는 중…';
          if (rsTimer) clearInterval(rsTimer);
          rsTimer = setInterval(paintRestart, 500);
          paintRestart();
        }
        function paintRestart(){
          const sec = Math.round((Date.now() - rsAt)/1000);
          const st = (cache && cache.health && cache.health.state) || '';
          if (!rsEnd){
            if (rsFail){ rsMsg = rsFail; rsEnd = Date.now() + 8000; }
            else if (st === 'ok'){ rsMsg = `연결됐습니다 — ${sec}초 걸렸습니다`; rsEnd = Date.now() + 6000; }
            else if (sec >= RS_GIVEUP){
              rsMsg = `${sec}초째 붙지 않습니다 — 재시작으로는 풀리지 않는 원인이 남아 있습니다`;
              rsEnd = Date.now() + 8000;
            }
            else rsMsg = `재시작 요청됨 — ${sec}초째 연결을 기다리는 중`;
          }
          const done = rsEnd && Date.now() >= rsEnd;
          if (done){ clearInterval(rsTimer); rsTimer = null; rsMsg = ''; }
          for (const id of ['hSt','intSt']){
            const el = document.getElementById(id);
            if (el) el.textContent = rsMsg;
          }
          // 기다리는 동안 배너를 붙잡아 뒀으므로(reflectHealth), 끝나면 원래 규칙대로.
          if (done) reflectHealth();
        }
        function restartDaemon(btn){
          btn.disabled = true;
          beginRestart();
          fetch('/api/slack/daemon/restart', {method:'POST'}).then(r=>r.json()).then(j=>{
            if (!j.ok) rsFail = '재시작 실패 — 아래 명령을 직접 실행해 주세요';
            setTimeout(load, 2000);
          }).catch(()=>{ rsFail = '앱에 연결할 수 없습니다'; })
            .finally(()=>{ paintRestart(); });
        }
        function load(){
          fetch('/api/slack/items').then(r=>r.json()).then(j=>{ cache=j; render(); })
            .catch(()=>{});
          if (dbgOn) loadActions();
        }
        // 기억해 둔 세그를 첫 그리기 전에 버튼에 반영한다 — 피드가 오기 전까지
        // 버튼만 '결정 대기'에 켜져 있고 목록은 다른 것인 상태가 생기지 않게.
        reflectFilter();
        load(); setInterval(load, 5000);
        // 워크스페이스 커스텀 이모지는 한 번만 (서버가 1시간 캐시) — 리액션 칩이
        // :ACK: 같은 사내 이모지도 그림으로 보여주려면 목록이 먼저 있어야 한다.
        loadCustomEmoji();
        </script></body></html>
        """#
    }
}
