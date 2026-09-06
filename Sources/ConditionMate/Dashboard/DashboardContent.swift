import Foundation

// Self-contained dashboard page (no external CDN — works offline). Polls
// /data.json every 5s and renders:
//   - today's per-minute activity timeline (canvas)
//   - which app was active across the day (colored strip)
//   - per-app active time (bars)
//   - per-app BGM debug table: which strategy/tracks played, flagging tracks
//     whose BPM falls outside the strategy band (i.e. "wrong" BGM)
// Raw Swift string => no interpolation/escaping surprises.
enum DashboardContent {
    static func html(lastView: String = "input", doneCutoff: Double? = nil, uiPrefs: String? = nil) -> String {
        // Clamp to a known view key so the injected JS literal can never be malformed.
        // "actions"(액션로그)·"history"(히스토리)는 컨디션 관리 페이지(/bgm-player)로 이동 — 저장돼 있던 옛 값은 input으로 클램프된다.
        // "queue"는 chat(/goal-add)의 detail-큐로 이전(QueuePanel.swift) — 옛 저장값은 input으로 클램프된다.
        let valid: Set<String> = ["input", "group", "table", "token", "schedule", "preview", "sprint", "archived"]
        let view = valid.contains(lastView) ? lastView : "input"
        // Server-persisted 완료 컷오프 as a JS literal: an integer epoch (0 = 해제) when the
        // user has set one, else "DC_DEFAULT" so the client keeps its built-in default.
        let dcInit: String = doneCutoff.map { String(Int($0)) } ?? "DC_DEFAULT"
        // Server-persisted UI layout blob, re-emitted as a JS object literal (the client
        // produced it with JSON.stringify, so it is already valid JS). Guard against a
        // malformed/empty value or a stray "</" that could break out of the <script> tag —
        // fall back to null so the client uses its built-in defaults.
        let prefsInit: String = {
            guard let s = uiPrefs, s.hasPrefix("{"), !s.contains("</") else { return "null" }
            return s
        }()
        return #"""
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Condition Mate — 활동</title>
<style>
  :root{--bg:#0f1115;--panel:#171a21;--line:#232733;--mut:#8b93a7;--fg:#e7ebf3;--accent:#5b8cff;--green:#36c08a;--red:#e2667d;}
  *{box-sizing:border-box} html,body{margin:0}
  body{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif}
  /* Thin, dark-theme scrollbars everywhere (chat body, modals, popups, textareas, the
     page body itself) — WKWebView otherwise falls back to the thick default macOS bar. */
  *{scrollbar-width:thin;scrollbar-color:#333a4a transparent}
  *::-webkit-scrollbar{width:8px;height:8px}
  *::-webkit-scrollbar-track{background:transparent}
  *::-webkit-scrollbar-thumb{background:#333a4a;border-radius:8px;border:2px solid transparent;background-clip:padding-box}
  *::-webkit-scrollbar-thumb:hover{background:#4a5468;border:2px solid transparent;background-clip:padding-box}
  *::-webkit-scrollbar-corner{background:transparent}
  .wrap{max-width:980px;margin:0 auto;padding:28px 20px}
  h1{font-size:18px;margin:0 0 4px}
  h2{font-size:14px;margin:22px 0 10px;color:var(--fg)}
  .sub{color:var(--mut);font-size:13px;margin-bottom:20px}
  /* 헤더 타임존 셀렉터 — 모든 시각의 기준이라 눈에 잘 띄게(강조 테두리) 상시 노출. */
  .hdrtz{display:inline-flex;align-items:center;gap:7px;padding:5px 9px;border:1px solid var(--accent);
         border-radius:10px;background:rgba(91,140,255,.12);white-space:nowrap}
  .hdrtz-ic{font-size:13px;line-height:1}
  .hdrtz-lbl{font-size:11px;color:var(--mut);font-weight:600;letter-spacing:.2px}
  .hdrtz-sel{appearance:auto;background:#0e1320;color:var(--fg);border:1px solid var(--line);
             border-radius:7px;padding:3px 6px;font-size:12px;font-weight:600;cursor:pointer;
             font-variant-numeric:tabular-nums}
  .hdrtz-sel:hover{border-color:var(--accent)}
  .cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:8px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px;flex:1;min-width:150px}
  .card .k{color:var(--mut);font-size:12px}
  .card .v{font-size:22px;font-weight:700;margin-top:4px}
  .card .cap{color:var(--mut);font-size:11px;margin-top:3px}
  #tiers{width:100%;display:block}
  .nowline{color:var(--mut);font-size:13px;margin:4px 0 18px}
  .nowline b{color:var(--fg);font-weight:600}
  .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;vertical-align:middle}
  .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px}
  canvas{width:100%;display:block}
  #chart{height:260px} #strip{height:34px;margin-top:8px}
  .legend{color:var(--mut);font-size:12px;margin-top:10px;display:flex;gap:18px;flex-wrap:wrap}
  .bars{display:flex;flex-direction:column;gap:8px}
  .bar{display:flex;align-items:center;gap:10px;font-size:13px}
  .bar .name{width:160px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .bar .track{flex:1;height:14px;border-radius:7px;background:#0d1f17;overflow:hidden}
  .bar .fill{height:100%;border-radius:7px}
  .bar .val{width:60px;text-align:right;color:var(--mut)}
  table{width:100%;border-collapse:collapse;font-size:13px}
  th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
  th{color:var(--mut);font-weight:600;font-size:12px}
  /* Sortable table view: clickable headers with an asc/desc arrow on the active key. */
  .gtbl th.sortable{cursor:pointer;user-select:none;white-space:nowrap}
  .gtbl th.sortable:hover{color:var(--fg)}
  .gtbl th.sorted{color:var(--fg)}
  .gtbl th .arr{opacity:.5;font-size:10px;margin-left:3px}
  .gtbl td{font-variant-numeric:tabular-nums}
  .gtbl tr.done td{opacity:.62}
  /* 이름 열도 한 줄 고정 — max-width:0 + table width:100% 조합이 셀 폭을 남은 공간으로
     묶어 주어야 ellipsis가 실제로 걸린다. 전문은 title(hover)·CSV에서 본다. */
  .gtbl .nm{max-width:0;width:55%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .gtbl .child .nm{color:var(--mut)}
  /* Sprint badge + release button + sprint view */
  .btn.rel{background:rgba(54,192,138,.14);border-color:var(--green);color:#9be9c9;font-weight:600}
  .btn.rel:hover{background:rgba(54,192,138,.24);border-color:var(--green)}
  .spbadge{display:inline-block;border:1px solid #3a4a7a;border-radius:999px;padding:1px 8px;font-size:11px;background:rgba(91,140,255,.10);color:#aec4ff;cursor:pointer;font-variant-numeric:tabular-nums;white-space:nowrap}
  .spbadge:hover{border-color:var(--accent);color:#cdddff;background:rgba(91,140,255,.20)}
  .spbadge.none{border-color:var(--line);color:var(--mut);background:#0e1320}
  .spedit{width:52px;text-align:center;padding:2px 4px;font-size:11px;border:1px solid var(--accent);border-radius:6px;background:#0e1320;color:var(--fg)}
  .subtab{display:flex;gap:6px;margin:0 0 12px}
  .relitem{border:1px solid var(--line);border-radius:10px;padding:11px 14px;margin:0 0 10px;background:#11151f}
  .relitem h4{margin:0 0 8px;font-size:13px;display:flex;justify-content:space-between;align-items:center;gap:8px;font-weight:600}
  .relgoals{display:flex;flex-wrap:wrap;gap:6px}
  .relitem h4.clk{cursor:pointer;user-select:none}
  .relitem .chev{display:inline-block;color:var(--mut);font-size:11px;transition:transform .15s;margin-right:4px}
  .relitem .chev.open{transform:rotate(90deg)}
  /* 완료 로그 섹션 헤더: 클릭으로 섹션 전체 펼침/접힘 (기본 접힘) */
  .rellog-hd{cursor:pointer;user-select:none}
  .rellog-hd .chev{display:inline-block;font-size:11px;transition:transform .15s;margin-right:6px}
  .rellog-hd .chev.open{transform:rotate(90deg)}
  .relbody{display:none;margin-top:8px;border-top:1px solid var(--line);padding-top:8px}
  .relbody.open{display:block}
  .relrow{padding:4px 2px;font-size:13px}
  .relrow .gn{color:var(--mut);font-variant-numeric:tabular-nums;margin-right:6px}
  /* 출처 태그 — 루프에 담긴 항목이 AI 세션 작업(session)인지 메모장 체크(노트)인지.
     상태 신호등이 아니라 출처의 낯빛: session=앱색, 노트=중립 회색. */
  .relrow .srct{margin-right:6px;font-size:11px;border-radius:6px;padding:1px 6px;
    border:1px solid var(--line);color:var(--mut);white-space:nowrap}
  .relrow .srct.sess{color:#7fa6e8;border-color:rgba(127,166,232,.4);background:rgba(127,166,232,.10)}
  /* Parent indicator in release log: gray = has a parent (shows parent's number), purple = is top-level. */
  .relrow .pn{font-variant-numeric:tabular-nums;margin-right:6px;font-size:11px;border-radius:6px;padding:1px 6px;border:1px solid var(--line);color:var(--mut)}
  .relrow .pn.top{color:#9b7bff;border-color:rgba(155,123,255,.4);background:rgba(155,123,255,.12)}
  /* Sprint board: sprint groups + backlog (Jira-style) */
  .spgrp{border:1px solid var(--line);border-radius:10px;margin:0 0 12px;background:#11151f;overflow:hidden}
  .spgrp.dropOver{border-color:var(--accent);background:rgba(91,140,255,.07)}
  .spgrp.bg{border-style:dashed}
  /* Bump out (아이디어 인박스): 가장 날 것의 하위 티어 — 더 흐린 점선으로 '정리 전'임을 표시 */
  .spgrp.bump{border-style:dashed;border-color:#2a3346;background:#0d111a}
  .spgrp.bump .spgrp-hd b{color:#8fa0bf}
  .spchev{cursor:pointer;color:var(--mut);font-size:12px;transition:transform .15s;user-select:none;width:14px;text-align:center}
  .spgrp.collapsed .spchev{transform:rotate(-90deg)}
  .spgrp.collapsed .spgrp-body,.spgrp.collapsed .spedit{display:none}
  .spgrp-hd{display:flex;align-items:center;gap:10px;padding:10px 12px;border-bottom:1px solid var(--line);flex-wrap:wrap}
  .spgrp-hd .ttl{font-size:13px;color:var(--fg)}
  .spgrp-hd .dd{font-size:12px;color:var(--mut)}
  .spgrp-hd .dd.soon{color:#ff9db0}
  /* PC방식 남은시간 카운트다운 칩 — 클릭하면 연장 모달. 30분 전부터 빨강(soon), 만료 시 깜빡임(over) */
  .spgrp-hd .spcd{font-size:14px;font-weight:700;font-variant-numeric:tabular-nums;letter-spacing:.6px;color:#9be9c9;cursor:pointer;padding:2px 9px;border-radius:7px;border:1px solid var(--line);background:#0e1320;user-select:none}
  .spgrp-hd .spcd:hover{border-color:#3a4a7a;filter:brightness(1.12)}
  .spgrp-hd .spcd.soon{color:#ffb3c0;border-color:#5a2738;background:rgba(120,30,50,.12)}
  .spgrp-hd .spcd.over{color:#ff4d6a;border-color:#7a2030;background:rgba(150,25,45,.16);animation:cdblink 1s steps(1,end) infinite}
  @keyframes cdblink{50%{opacity:.18}}
  .spgrp-hd .spcd.muted{color:var(--mut);font-weight:500;font-size:12px}
  /* 시간 연장 모달 */
  .extrow{display:flex;align-items:center;justify-content:center;gap:18px;margin:16px 0}
  .extbtn{width:46px;height:46px;border-radius:12px;border:1px solid var(--line);background:#0e1320;color:var(--fg);font-size:24px;line-height:1;cursor:pointer;font-weight:600}
  .extbtn:hover{border-color:var(--accent);color:var(--accent)}
  .exth{min-width:96px;text-align:center}
  .exth b{font-size:30px;font-variant-numeric:tabular-nums}
  .exth small{display:block;font-size:12px;color:var(--mut);margin-top:2px}
  .extcur,.extnew{text-align:center;font-size:13px;color:var(--mut)}
  .extnew{color:#9be9c9}
  .extnew b,.extcur b{color:var(--fg);font-variant-numeric:tabular-nums}
  .exthint{text-align:center;font-size:11px;color:var(--mut);margin-top:10px}
  /* 직접 지정 행 — 절대 마감 시각을 datetime-local로 바로 설정 */
  .extset{display:flex;flex-direction:column;align-items:center;gap:5px;margin-top:12px;padding-top:12px;border-top:1px solid var(--line)}
  .extset .dlab{color:var(--mut);font-size:11px}
  .spcount{display:inline-flex;gap:4px}
  .spcount span{font-size:11px;border-radius:6px;padding:1px 7px;background:#0e1320;border:1px solid var(--line);color:var(--mut);font-variant-numeric:tabular-nums}
  .spcount .ip{color:#aec4ff;border-color:#3a4a7a}
  .spcount .dn{color:#9be9c9;border-color:var(--green)}
  .spgrp-body{padding:6px 10px;min-height:38px}
  .spgrp-body .empty{color:var(--mut);font-size:12px;padding:8px 2px}
  .bgoal{display:flex;align-items:center;gap:8px;padding:7px 4px;border-bottom:1px solid rgba(255,255,255,.05);cursor:grab}
  .bgoal:last-child{border-bottom:none}
  .bgoal.dragging{opacity:.4}
  .bgoal.dropTarget{border-top:2px solid var(--accent)}
  /* 행 가운데에 놓으면 '자식으로 붙이기' — 순서 변경(윗선)과 다른 신호를 준다 */
  .bgoal.dropChild{background:rgba(91,140,255,.14);box-shadow:inset 3px 0 0 var(--accent);border-radius:6px}
  .bgoal.child{padding-left:24px;background:rgba(255,255,255,.015)}
  .bgoal .grip{color:#3a4150}
  .bgoal .t{flex:1;min-width:60px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .bgchev{cursor:pointer;color:var(--mut);width:14px;text-align:center;display:inline-block;font-size:11px;user-select:none}
  .bgsp{display:inline-block;width:14px}
  .bgoal .pref{margin-left:8px;font-size:11px;color:var(--mut);border:1px solid var(--line);border-radius:999px;padding:1px 7px;white-space:nowrap}
  /* 상태 콤보 왼쪽의 부모 번호 칸 (예: 02 입력 → goal-02 의 자식으로).
     칸의 겉모양(테두리/배경/폭)은 .pinwrap 이 갖고, 그 안에 [회색 추천][입력] 이 나란히 앉는다.
     WARN: 추천을 입력칸 위에 겹쳐 띄우지 않는다 — goal-680 같은 세 자리 부모 번호가 오면 겹친
     영역이 칸의 절반을 넘어, 타이핑하려고 칸 가운데를 누른 클릭까지 링크가 삼켜 페이지를
     이동시킨다. 나란히 두면 히트 영역이 겹칠 수 없다. */
  .pinwrap{display:inline-flex;flex:none;align-items:center;width:84px;background:#0e1320;
    border:1px solid var(--line);border-radius:6px;overflow:hidden}
  .pinwrap:focus-within{border-color:var(--accent)}
  .bgoal .pinwrap{margin-right:6px}
  /* 겉모양은 wrap 이 그린다 — 여기서는 전역 input[type=text] 규칙(:366)을 벗겨낸다
     (그 규칙이 더 구체적이라 클래스 하나짜리 선택자로는 못 이긴다). */
  .pinwrap .pin{flex:1 1 auto;min-width:0;text-align:center;font-size:12px;color:var(--fg);
    background:transparent;border:0;border-radius:0;outline:none;padding:2px 0}
  .pinwrap .pin::placeholder{color:#4a5163}
  .bgoal .pin-sp{width:84px;flex:none;margin-right:6px;display:inline-block}
  /* 회색 추천 번호. 값처럼 보이지만 링크다(클릭=그 부모 goal 열기). 확정은 오직 타이핑 경로. */
  .pghost{flex:0 0 auto;display:flex;align-items:center;gap:3px;padding:0 3px 0 5px;font-size:12px;
    font-variant-numeric:tabular-nums;color:#5b6274;text-decoration:none;white-space:nowrap;
    cursor:pointer;align-self:stretch;border-right:1px solid rgba(255,255,255,.06)}
  .pghost:hover{color:#9fc0ff;background:rgba(91,140,255,.12)}
  .pinwrap.focus .pghost{display:none}      /* 타이핑 중에는 칸 전체를 입력에 내준다 */
  .bgoal.parfill .pghost{display:none}      /* Cmd+드래그로 방금 칠한 값이 추천에 가리지 않게 */
  /* 추천 상태 점: 색=추천 부모의 실효 상태(행의 상태 칩과 같은 팔레트), 계산 중=보라 pulse */
  .psdot{width:6px;height:6px;border-radius:50%;background:var(--mut);flex:0 0 auto}
  .psdot.calc{background:#9b7bff;animation:psblink 1.2s ease-in-out infinite}
  .psdot.in_progress{background:#5b8cff}
  .psdot.on_track{background:#4cc9f0}
  .psdot.waiting{background:#e8a33d}
  .psdot.done{background:var(--green)}
  .psdot.cancelled{background:#7a2233}
  @keyframes psblink{0%,100%{opacity:1}50%{opacity:.28}}
  .popup .popitem .pswhy{display:block;font-size:11px;color:var(--mut);margin-top:2px}
  .popup .popitem .ppfresh.sug{color:#c3b0ff;border-color:#6b5aa8}
  /* 부모 채우기(fill-down): Cmd 누르면 부모칸이 채우기 소스로 무장(hover 강조), 드래그 중 대상 행 강조 */
  body.armparent .bgoal .pin{cursor:cell}
  body.armparent .bgoal .pinwrap:hover{border-color:var(--accent);box-shadow:0 0 0 2px rgba(91,140,255,.4)}
  body.parfilling,body.parfilling *{cursor:cell !important;user-select:none}
  .bgoal.parfill{background:rgba(91,140,255,.12);box-shadow:inset 2px 0 0 var(--accent)}
  .bgoal.parsrc .pinwrap{border-color:var(--accent);box-shadow:0 0 0 2px rgba(91,140,255,.55)}
  /* 우선순위 화살표 (Jira식 셰브론, 색은 currentColor) — 클릭=피커, Cmd+드래그=같은 값 페인트 */
  .pri{flex:0 0 auto;display:inline-flex;align-items:center;justify-content:center;width:16px;height:16px;line-height:0;cursor:pointer;transition:transform .06s}
  .pri svg{display:block;pointer-events:none}
  .pri:hover{transform:scale(1.3)}
  .pri-urgent{color:#ff4d4f}
  .pri-high{color:#ff8a4c}
  .pri-medium{color:#e9c46a}
  .pri-low{color:#9aa3ad}
  .pri-lowest{color:#5b6068}
  .pripaint .pri{transition:none}
  body.pripaint{cursor:crosshair;user-select:none}
  .popitem .pri{vertical-align:middle;margin-right:8px;pointer-events:none}
  /* ⋯ menu + 우클릭 이동 팝업 */
  .popup{position:fixed;z-index:50;background:#171c28;border:1px solid var(--line);border-radius:8px;padding:4px;min-width:170px;max-height:60vh;overflow:auto;box-shadow:0 10px 28px rgba(0,0,0,.5)}
  .popup .pophdr{font-size:11px;color:var(--mut);padding:5px 9px}
  .popup .popitem{display:block;width:100%;text-align:left;background:none;border:none;color:var(--fg);padding:7px 10px;font-size:13px;border-radius:6px;cursor:pointer;white-space:nowrap}
  .popup .popitem:hover{background:#1d2230}
  .popup .popitem[disabled]{opacity:.32;cursor:default}
  .popup .popitem[disabled]:hover{background:none}
  .popup .popitem.danger{color:#ff9db0}
  .popup .popitem.unlink{color:#aec4ff}
  .popup .popitem .gn{color:var(--mut);font-variant-numeric:tabular-nums;margin-right:6px}
  .popup .popitem .ppfresh{margin-left:7px;font-size:10px;color:var(--mut);border:1px solid var(--line);border-radius:4px;padding:0 4px;vertical-align:middle}
  .popup .ppsearch{width:calc(100% - 8px);margin:4px;background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:6px;padding:6px 8px;font-size:13px}
  .popup .ppsearch:focus{outline:none;border-color:var(--accent)}
  .popup #ppList{max-height:260px;overflow:auto}
  /* 보기(상태) 콤보박스 + 체크박스 메뉴 */
  .btn.combo{display:inline-flex;align-items:center;gap:7px;font-weight:600}
  .btn.combo .cv{color:var(--mut);font-size:10px;line-height:1}
  /* 선택이 있으면 Jira식 아웃라인(파란 테두리·글자) — 솔리드 채움 대신 깔끔하게 */
  .btn.combo.active{border-color:var(--accent);color:var(--accent)}
  .btn.combo.active .cv{color:var(--accent)}
  /* 체크 개수 배지 — 체크할수록 숫자가 올라간다 */
  .btn.combo .cbadge{background:rgba(91,140,255,.22);color:#cdddff;font-size:11px;font-weight:700;min-width:18px;height:18px;line-height:18px;text-align:center;border-radius:5px;padding:0 5px}
  .ckmenu{min-width:158px}
  /* 뷰 탭바 (Jira식): 콤보 대신 탭으로 펼친다. 각 탭은 ⋯ 메뉴(기본 지정·좌우 이동)를 가진다. */
  .viewtabs{display:flex;align-items:stretch;gap:2px;flex-wrap:wrap;border-bottom:1px solid var(--line);margin:18px 0 12px}
  .vtab{position:relative;display:inline-flex;align-items:center;gap:6px;background:none;border:none;border-bottom:2px solid transparent;color:var(--mut);padding:8px 10px 9px;font-size:13px;font-weight:600;cursor:pointer;border-radius:6px 6px 0 0}
  .vtab:hover{color:var(--fg);background:#1d2230}
  .vtab.active{color:var(--fg);border-bottom-color:var(--accent)}
  .vtab .vdef{color:var(--accent);font-size:9px;line-height:1}
  .vtab .vdots{visibility:hidden;color:var(--mut);font-size:14px;line-height:1;padding:0 3px;border-radius:4px}
  .vtab:hover .vdots,.vtab.active .vdots{visibility:visible}
  .vtab .vdots:hover{color:var(--fg);background:#2a3142}
  /* AI 큐 상태 노티 (탭바 우측): 실행 중=액센트 펄스, 검토 대기=보라(대기=보라 컨벤션).
     클릭하면 chat(/goal-add)의 detail-큐로 이동한다 — 큐 UI 이전 후 대시보드의 유일한 큐 신호. */
  .vnoti{display:none;align-items:center;gap:7px;align-self:center;margin-left:auto;margin-bottom:3px;border:1px solid var(--line);background:#151b28;border-radius:20px;padding:5px 12px 5px 10px;font-size:12px;font-weight:600;cursor:pointer;color:var(--fg);font-family:inherit}
  .vnoti:hover{border-color:var(--accent)}
  .vnoti .nd{width:7px;height:7px;border-radius:50%;flex:none}
  .vnoti.run{color:#b9cdff;border-color:#2c3c63}
  .vnoti.run .nd{background:var(--accent);animation:qpulse 1s infinite}
  .vnoti.ready{color:#cfc3f7;border-color:#4b3d78;background:rgba(167,139,250,.10)}
  .vnoti.ready .nd{background:#a78bfa}
  .vnoti .narr{color:var(--mut);font-size:11px}
  /* 루프 메뉴: 라벨이 길어 줄바꿈 허용 + 폭 확대 */
  .ckmenu.spmenu{min-width:220px;max-width:340px}
  .popup .spmenu .popitem.chk{white-space:normal;align-items:flex-start}
  .popup .popitem.chk{display:flex;align-items:center;gap:9px}
  .popup .popitem.chk .cbx{width:15px;height:15px;border:1.5px solid var(--line);border-radius:4px;flex:0 0 auto;display:inline-flex;align-items:center;justify-content:center;font-size:11px;color:#091022;line-height:1}
  .popup .popitem.chk.on .cbx{background:var(--accent);border-color:var(--accent)}
  .popup .popitem.chk.on .cbx::after{content:'✓'}
  .popdiv{height:1px;background:var(--line);margin:5px 6px}
  /* AI추가 안내 툴팁 (마우스 올리거나 우클릭하면 표시) */
  .infowrap{position:relative;display:inline-block}
  .infotip{display:none;position:absolute;top:calc(100% + 6px);right:0;z-index:55;width:280px;background:#171c28;border:1px solid var(--line);border-radius:8px;padding:9px 11px;font-size:12px;line-height:1.55;color:var(--mut);box-shadow:0 10px 28px rgba(0,0,0,.5);white-space:normal;text-align:left;cursor:default}
  .infotip b{color:var(--fg)}
  .infowrap:hover .infotip,.infotip.show{display:block}
  /* 루프 편집 모달 */
  .spmodal{position:fixed;inset:0;z-index:60;background:rgba(0,0,0,.55);align-items:center;justify-content:center}
  .modal-box{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px 20px;width:min(560px,92vw);max-height:86vh;overflow:auto}
  .modal-box h3{margin:0 0 14px;font-size:15px}
  .modal-box .line{display:flex;align-items:center;gap:8px;margin:0 0 12px;flex-wrap:wrap}
  .modal-box .line .lab{width:64px;font-size:12px;color:var(--mut);flex:0 0 auto}
  .modal-box input[type=datetime-local]{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 9px;font-size:13px;color-scheme:dark}
  .modal-box .spmgoal{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 9px;font-size:13px;flex:1;min-width:200px}
  .spedit{padding:10px 12px;border-bottom:1px solid var(--line);background:#0e1320;display:none}
  .spedit.open{display:block}
  .spedit .line{display:flex;align-items:center;gap:8px;margin:0 0 8px;flex-wrap:wrap}
  .spedit .line .lab{width:48px;font-size:12px;color:var(--mut);flex:0 0 auto}
  .spedit input[type=datetime-local]{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 8px;font-size:12px;color-scheme:dark}
  .spedit .spmgoal{max-width:none}
  .valbadge{color:#9be9c9;background:rgba(54,192,138,.12);border:1px solid var(--green);border-radius:999px;font-size:12px;padding:2px 9px;white-space:nowrap}
  /* 골 배정 입력칸: type 속성이 없어 글로벌 input[type=text] 규칙이 안 먹으므로 직접 다크 지정 */
  .asgn input{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 8px;font-size:13px}
  .asgn input:focus{outline:none;border-color:var(--accent)}
  .asgn input.title{width:100%}
  .asgn input.par,.asgn input.spn{width:48px;text-align:center}
  /* 루프 관리: 생성 폼 + 기간 칩 + 루프 카드 */
  .durchip{display:inline-block;padding:4px 11px;border-radius:999px;border:1px solid var(--line);background:#0e1320;color:var(--mut);cursor:pointer;font-size:12px;margin:0 4px 0 0}
  .durchip:hover{border-color:var(--accent)}
  .durchip.on{background:var(--accent);border-color:var(--accent);color:#091022;font-weight:600}
  .spmcard{border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin:0 0 10px;background:#11151f}
  .spmcard h4{margin:0 0 8px;font-size:13px;font-weight:600;display:flex;justify-content:space-between;align-items:center;gap:8px}
  .spmgoal{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 8px;font-size:13px;width:100%;max-width:440px}
  .spmcreate{border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin:0 0 14px;background:#0e1320}
  .chip{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;margin:2px 4px 2px 0;background:#1d2230;border:1px solid var(--line)}
  .chip.bad{background:#2a1620;border-color:#5a2738;color:#ff9db0}
  .chip.bad::after{content:" ⚠";}
  .foot{color:var(--mut);font-size:12px;margin-top:18px;text-align:center}
  .empty{color:var(--mut)}
  .btn{background:#1d2230;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:6px 12px;font-size:13px;cursor:pointer}
  .btn:hover{border-color:var(--accent)}
  .btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
  .btn:disabled{opacity:.5;cursor:not-allowed}
  /* View switcher combobox (입력 / 그룹 / 프리뷰) — styled to match .btn. */
  select.btn{appearance:none;-webkit-appearance:none;-moz-appearance:none;padding-right:24px;
    background-image:linear-gradient(45deg,transparent 50%,var(--mut) 50%),linear-gradient(135deg,var(--mut) 50%,transparent 50%);
    background-position:calc(100% - 13px) 55%,calc(100% - 8px) 55%;background-size:5px 5px,5px 5px;background-repeat:no-repeat}
  /* Group-mode input: sticky add bar + collapsible per-parent sections. */
  .gqbar{position:sticky;top:0;z-index:5;background:var(--panel);padding:8px 0;margin:0 0 6px;border-bottom:1px solid var(--line)}
  .gsec{border:1px solid var(--line);border-radius:10px;margin:8px 0;overflow:hidden}
  .gsec-hd{display:flex;align-items:center;gap:8px;padding:8px 10px;background:#1a1e27;cursor:pointer;user-select:none}
  .gsec-hd:hover{background:#1d2230}
  .gsec-hd .tw{color:var(--mut);width:12px;flex:0 0 auto;transition:transform .15s;text-align:center}
  .gsec.collapsed .gsec-hd .tw{transform:rotate(-90deg)}
  .gsec-hd .gtitle{flex:1;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .gsec-hd .prog{color:var(--mut);font-size:12px;font-variant-numeric:tabular-nums;flex:0 0 auto}
  .gsec-body{padding:4px 10px 8px}
  .gsec.collapsed .gsec-body{display:none}
  .gchild{display:flex;align-items:center;gap:8px;padding:4px 0;border-bottom:1px solid var(--line);flex-wrap:wrap}
  .gchild:last-of-type{border-bottom:none}
  .gchild .gt{flex:1;min-width:0}
  .gsec-add{display:flex;gap:6px;margin-top:6px}
  .hdr{display:flex;align-items:center;justify-content:space-between;gap:12px}
  .overlay{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:flex-start;justify-content:center;padding:40px 16px;overflow:auto;z-index:50}
  .overlay.on{display:flex}
  /* 배경 클릭이 무시됐을 때(입력 내용 있음) '닫기' 버튼을 살짝 튕겨 안내 */
  @keyframes cmNudge{0%,100%{transform:translateX(0)}25%{transform:translateX(-3px)}75%{transform:translateX(3px)}}
  .btn.nudge{animation:cmNudge .4s ease;box-shadow:0 0 0 2px var(--accent,#5b8cff)}
  /* 작성 중이던 목표 초안(draft) 이어쓰기 칩 — 모달을 ESC로 닫아도 입력이 남아 있으면 여기서 이어서 편집 */
  .gadraft-chip{display:none;position:fixed;right:18px;bottom:18px;z-index:49;align-items:center;gap:6px;
    padding:8px 14px;border-radius:999px;border:1px solid var(--line);background:var(--panel);color:var(--fg);
    font-size:13px;font-weight:600;cursor:pointer;box-shadow:0 4px 16px rgba(0,0,0,.35)}
  .gadraft-chip:hover{border-color:var(--acc,#5b8cff)}
  .gadraft-chip .pen{font-size:14px}
  .modal{background:var(--panel);border:1px solid var(--line);border-radius:14px;max-width:720px;width:100%;padding:24px}
  .modal h2{margin-top:18px} .modal h2:first-child{margin-top:0}
  .modal ul{margin:6px 0;padding-left:18px} .modal li{margin:3px 0}
  .modal .muted{color:var(--mut)}
  .pill{display:inline-block;padding:1px 7px;border-radius:999px;font-size:11px;border:1px solid var(--line);margin-right:4px}
  a.pill.gp{cursor:pointer;text-decoration:none;color:inherit}
  a.pill.gp:hover{border-color:var(--accent);color:var(--accent)}
  .pill.lkdot{cursor:default}
  /* 링크 확인 다이얼로그의 전/후 그래픽 */
  .lkba{display:flex;align-items:center;gap:14px}
  .lkcol{flex:1;min-width:0}
  .lkcap{font-size:11px;color:var(--mut);margin-bottom:5px}
  .lkbox{border:1px solid var(--line);border-radius:9px;padding:8px 10px;font-size:13px;background:#0d1016}
  .lknest{margin-top:4px;padding-left:8px;font-size:12px}
  .lkchip{display:inline-block;margin-left:4px;padding:1px 7px;border-radius:999px;font-size:11px;border:1px solid var(--accent);color:var(--accent)}
  .lkarrow{color:var(--mut);font-size:18px;flex:0 0 auto}
  .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
  /* 목표 추가 히어로: 화면 가운데로 모으고 입력창을 크게 — 머릿속 덤프의 주 입구 */
  .addhero{max-width:760px;margin:30px auto 16px}
  .addhero-label{text-align:center;font-size:16px;font-weight:600;letter-spacing:.5px;color:var(--fg);margin:0 0 12px}
  .addhero-row{margin:0;flex-wrap:nowrap}
  .addhero .bardwrap{min-width:0}
  .addhero #goalText{font-size:16px;padding:13px 16px;border-radius:12px}
  .addhero .btn{padding:12px 16px;font-size:14px}
  input[type=text],input[type=number]{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 9px;font-size:13px}
  input[type=range]{vertical-align:middle}
  .goal{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:5px 0;border-bottom:1px solid var(--line)}
  .goal .g{flex:1;min-width:0;position:relative;display:flex;align-items:center;gap:0}
  /* 부분과제(task) 행: 유형 필터에 task를 켰을 때 goal 아래 붙는 컴팩트 읽기 전용 행. */
  .goal.taskrow{padding:3px 0 3px 22px;background:rgba(255,255,255,.015)}
  .goal.taskrow .gt{font-size:12.5px;cursor:default}
  .goal.taskrow .gt:hover{background:none}
  .goal.taskrow .tlead{font-size:12px}
  /* Editable goal title: double-click to rename in place (목록 + 그룹 자식 행). */
  /* 목표 제목은 어느 뷰에서든 한 줄 — 넘치면 …로 자르고 전문은 title(hover)로 본다.
     (목록 .goal .g / 그룹 .gchild / 일정 .schrow .st / 토큰 뷰가 모두 이 .gt를 쓴다.) */
  .gt{cursor:text;border-radius:5px;padding:1px 4px;margin:0 -4px;
      flex:1;min-width:0;max-width:100%;display:block;
      white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .gt:hover{background:rgba(255,255,255,.05)}
  .gt input.gedit{width:100%;box-sizing:border-box;padding:3px 6px;font-size:13px}
  /* Concurrency-gated AI-work row: shown only when 2+ goals run at once (= AI).
     Holds energy allocation, assigned agents, tokens spent, value, and ROI. */
  .aiwork{flex:0 0 100%;display:flex;flex-wrap:wrap;align-items:center;gap:6px 12px;margin:2px 0 4px 26px;
          padding:6px 10px;border-radius:8px;background:rgba(91,140,255,.06);border:1px solid var(--line);font-size:12px}
  .aiwork .lab{color:var(--mut);font-size:11px}
  .aiwork input[type=number]{width:62px;text-align:right;padding:4px 7px;font-size:12px}
  .aiwork input.agents{width:150px;padding:4px 7px;font-size:12px}
  .roi{font-variant-numeric:tabular-nums;border-radius:6px;padding:2px 8px;font-size:11px;border:1px solid var(--line);white-space:nowrap}
  .roi.hi{background:rgba(54,192,138,.16);border-color:var(--green);color:#9be9c9}
  .roi.mid{background:rgba(232,161,58,.14);border-color:#e8a13a;color:#f0c884}
  .roi.lo{background:rgba(255,99,99,.14);border-color:#ff6363;color:#ff9b9b}
  /* Energy gauge banner: sum of in_progress energy vs the 100% cap. */
  .engauge{margin:6px 0 8px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:rgba(91,140,255,.05);font-size:12px}
  .engauge .head{display:flex;justify-content:space-between;align-items:center;margin-bottom:5px}
  .engauge .bar{height:8px;border-radius:999px;background:#1d2230;overflow:hidden}
  .engauge .fill{height:100%;background:linear-gradient(90deg,#36c08a,#5b8cff);transition:width .3s}
  .engauge.over{border-color:#ff6363;background:rgba(255,99,99,.08)}
  .engauge.over .fill{background:linear-gradient(90deg,#e8a13a,#ff6363)}
  .engauge .warn{color:#ff9b9b}
  /* Completion evidence (links + files) attached to a goal. */
  .evbtn{flex:0 0 auto;padding:3px 8px;font-size:12px}
  .evbtn.has{border-color:var(--green);color:#9be9c9}
  .evpanel{flex:0 0 100%;display:none;margin:2px 0 6px 26px;padding:8px 10px;border-radius:8px;background:rgba(54,192,138,.05);border:1px solid var(--line)}
  .evpanel.open{display:block}
  .evlist{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
  .evitem{display:inline-flex;align-items:center;gap:4px;background:#1d2230;border:1px solid var(--line);border-radius:999px;padding:2px 4px 2px 10px;font-size:12px;max-width:340px}
  .evitem a{color:var(--accent);text-decoration:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .evitem a:hover{text-decoration:underline}
  .evx{background:none;border:none;color:var(--mut);cursor:pointer;font-size:12px;line-height:1;padding:0 3px}
  .evx:hover{color:var(--red)}
  .evrep{margin:2px 0 6px;font-size:12px;display:flex;flex-wrap:wrap;gap:10px}
  .evrep a{color:var(--accent);text-decoration:none}
  .evrep a:hover{text-decoration:underline}
  /* Review memo: not important enough for an always-on field, so it collapses to a
     button that opens an inline editor on click (mirrors the evidence panel pattern). */
  .notebtn{flex:0 0 auto;padding:3px 8px;font-size:12px}
  .notebtn.has{border-color:var(--accent);color:#9fc0ff}
  .notepanel{flex:0 0 100%;display:none;margin:2px 0 6px 26px;padding:8px 10px;border-radius:8px;background:rgba(91,140,255,.05);border:1px solid var(--line)}
  .notepanel.open{display:block}
  .notepanel input{width:100%}
  /* 일정관리(schedule) view: urgency-grouped sections + per-goal target/완료 datetime pickers. */
  .schsec{border:1px solid var(--line);border-radius:10px;margin:10px 0;overflow:hidden}
  .schsec-hd{display:flex;align-items:center;gap:8px;padding:8px 12px;font-weight:600;background:#1a1e27}
  .schsec-hd .cnt{color:var(--mut);font-weight:400;font-size:12px}
  .schsec.overdue .schsec-hd{background:rgba(255,99,99,.10);color:#ff9b9b}
  .schsec.today .schsec-hd{background:rgba(232,163,61,.12);color:#f0c884}
  .schsec.done .schsec-hd{background:rgba(54,192,138,.10);color:#9be9c9}
  .schrow{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:6px 12px;border-bottom:1px solid var(--line)}
  .schrow:last-child{border-bottom:none}
  .schrow .st{flex:1;min-width:0;overflow:hidden}
  .schrow .dlab{color:var(--mut);font-size:11px}
  .schrow input[type=datetime-local]{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 8px;font-size:12px;color-scheme:dark}
  .dday{font-variant-numeric:tabular-nums;font-size:11px;border-radius:6px;padding:1px 7px;border:1px solid var(--line);color:var(--mut);white-space:nowrap}
  .dday.over{border-color:#ff6363;color:#ff9b9b;background:rgba(255,99,99,.10)}
  .dday.soon{border-color:#e8a33d;color:#f0c884;background:rgba(232,163,61,.10)}
  .dday.done{border-color:var(--green);color:#9be9c9;background:rgba(54,192,138,.10)}
  /* 토큰 뷰: 완료 항목의 토큰 사용량을 완료일(오늘·어제·…) 그룹으로 합산해 본다. */
  .tksum{display:flex;flex-wrap:wrap;gap:16px;align-items:baseline;margin:2px 0 10px;padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:#1a1e27}
  .tksum .big{font-size:18px;font-weight:700;font-variant-numeric:tabular-nums}
  .tksum .k{color:var(--mut);font-size:12px}
  .tksum b{font-variant-numeric:tabular-nums;color:#bcd0ff}
  .tkn{font-variant-numeric:tabular-nums;font-size:12px;border-radius:6px;padding:1px 8px;border:1px solid var(--line);background:rgba(91,140,255,.08);color:#bcd0ff;white-space:nowrap;margin-left:auto}
  .schsec-hd .tot{margin-left:auto;font-weight:600;color:#bcd0ff;font-variant-numeric:tabular-nums}
  .tkspr{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0 2px}
  .tkspr .chip{display:inline-flex;gap:6px;align-items:center;border:1px solid var(--line);border-radius:999px;padding:3px 11px;font-size:12px}
  .tkspr .chip b{font-variant-numeric:tabular-nums;color:#bcd0ff}
  /* Completion celebration: check sweep (strike + green flash) + floating +Nv value. */
  .goal.celebrate{background:rgba(54,192,138,.14);transition:background .45s}
  .gstrike{position:absolute;left:0;top:55%;height:2px;width:0;background:var(--green);transition:width .45s ease}
  .gstrike.on{width:100%}
  .vfloat{position:fixed;z-index:60;background:rgba(54,192,138,.16);border:1px solid var(--green);color:#9be9c9;border-radius:999px;padding:2px 10px;font-size:12px;font-weight:600;pointer-events:none;opacity:0;transition:transform 1s ease,opacity 1s ease}
  .grip{cursor:grab;color:var(--mut);user-select:none;padding:0 2px;font-size:14px;line-height:1}
  .grip:active{cursor:grabbing}
  /* Session-link toggle: bright chain when a Claude session is attached (opens the
     readable transcript), dim broken chain when not (opens the connect picker). */
  .slink{cursor:pointer;background:none;border:none;padding:2px 4px;border-radius:6px;font-size:13px;line-height:1}
  .slink:hover{background:#1d2230}
  .slink.on{filter:none;opacity:1}
  .slink.off{opacity:.4;filter:grayscale(1)}
  /* DEV dataset badge — shown only when the app runs on a CM_DATA_DIR override
     (e.g. .localdata). Makes "this is not production data" impossible to miss. */
  .devbadge{display:inline-block;vertical-align:middle;margin-left:8px;padding:2px 9px;border-radius:6px;
    font-size:12px;font-weight:700;letter-spacing:.06em;color:#1a1205;background:#f5a623;border:1px solid #ffce7a}
  body.devmode{border-top:3px solid #f5a623}
  .goal.dragging{opacity:.45}
  .goal.dropTarget{border-top:2px solid var(--accent)}
  /* Group-view drag priority: dim the dragged section/child, mark the drop target. */
  .gsec.dragging{opacity:.5}
  .gsec.dropTarget{outline:2px solid var(--accent);outline-offset:-2px}
  .gchild.dragging{opacity:.5}
  .gchild.dropTarget{border-top:2px solid var(--accent)}
  .stat{display:inline-flex;gap:3px;flex:0 0 auto}
  .sb{background:#1d2230;border:1px solid var(--line);color:var(--mut);border-radius:6px;padding:3px 8px;font-size:12px;cursor:pointer}
  .sb:hover{border-color:var(--accent)}
  .sb.on.backlog{color:var(--fg);border-color:var(--mut)}
  .sb.on.in_progress{background:var(--accent);border-color:var(--accent);color:#fff}
  .sb.on.waiting{background:#e8a33d;border-color:#e8a33d;color:#2a1c06}
  .sb.on.done{background:var(--green);border-color:var(--green);color:#06281c}
  /* Status combobox: six statuses outgrew the inline buttons, so leaf goals pick status
     from a select. Border/text color-code the CURRENT status so the row reads at a glance. */
  .statsel{background:#1d2230;border:1px solid var(--line);color:var(--fg);border-radius:6px;
    padding:3px 8px;font-size:12px;cursor:pointer;flex:0 0 auto}
  .statsel:hover{border-color:var(--accent)}
  .statsel.in_progress{border-color:var(--accent);color:#9fc0ff}
  .statsel.waiting{border-color:#e8a33d;color:#e8a33d}
  .statsel.stopped{border-color:var(--mut);color:var(--mut)}
  .statsel.cancelled{border-color:#7a2233;color:#e07a8c;text-decoration:line-through}
  .statsel.done{border-color:var(--green);color:#36c08a}
  /* Live "응답 대기" badge: a human-attention flag, pulsing amber so it stands out. */
  .wbadge{font-variant-numeric:tabular-nums;font-size:11px;color:#e8a33d;border:1px solid #e8a33d;
    border-radius:6px;padding:1px 6px;margin-left:6px;white-space:nowrap;animation:wpulse 1.6s ease-in-out infinite}
  @keyframes wpulse{0%,100%{opacity:1}50%{opacity:.45}}
  .ttime{font-variant-numeric:tabular-nums;color:var(--mut);font-size:12px;min-width:48px;text-align:right;flex:0 0 auto}
  .ttime.clk{cursor:pointer;color:#9fc0ff}
  .ttime.clk:hover{text-decoration:underline}
  .goal.running{background:rgba(91,140,255,.06)}
  .goal.ontrack{background:rgba(76,201,240,.07)}
  /* Derived rollup status for parent goals (computed from children, not clickable). */
  .ot{display:inline-block;border-radius:6px;padding:3px 9px;font-size:12px;border:1px solid var(--line);color:var(--mut);white-space:nowrap}
  .ot.on_track{background:rgba(76,201,240,.16);border-color:#4cc9f0;color:#9be3fb}
  .ot.done{background:var(--green);border-color:var(--green);color:#06281c}
  /* Status pill colors for the 테이블 view (other views compute their own rollup). */
  .ot.in_progress{background:rgba(91,140,255,.16);border-color:#5b8cff;color:#aec4ff}
  .ot.waiting{background:rgba(240,180,76,.14);border-color:#f0b44c;color:#f5d79b}
  .ot.cancelled{opacity:.55}
  .otTag{display:inline-block;border:1px solid #4cc9f0;color:#9be3fb;background:rgba(76,201,240,.12);border-radius:999px;font-size:11px;padding:1px 8px;margin-left:8px;vertical-align:middle}
  /* 리포트는 1초 안에 훑을 수 있어야 한다 — 제목/항목은 절대 줄바꿈하지 않고 넘치면 …로 자른다.
     전체 문장은 title 속성(hover)과 CSV 다운로드에서 확인한다. */
  #report h3{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  #report ul{margin:4px 0;padding-left:18px}
  #report li.rli{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}
  #report li.rli .evrep{display:inline-flex;gap:8px;margin-left:8px;vertical-align:middle}
  .stage{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid var(--line)}
  .stage .n{width:22px;height:22px;border-radius:50%;background:#1d2230;display:flex;align-items:center;justify-content:center;font-size:12px;flex:0 0 auto}
  .stage .s{flex:1} .stage .st{font-size:12px}
  .ok{color:var(--green)} .wait{color:var(--mut)} .bad{color:var(--red)}
  /* Pixel bard standing fully above the goal input, anchored to the right edge. */
  .bardwrap{position:relative;flex:1;display:flex;min-width:140px}
  #bardCanvas{position:absolute;top:-40px;right:14px;width:40px;height:40px;image-rendering:pixelated;pointer-events:none;z-index:3}
  /* --- Chat panel (Claude-Desktop-style 대화), inline below the button -------- */
  .chatpanel{display:none;margin:14px auto 0;width:min(880px,100%)}
  .chatpanel.on{display:block}
  .chatcard{display:flex;flex-direction:column;max-height:70vh;
    background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden}
  .chathdr{display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid var(--line)}
  .chathdr h1{margin:0;font-size:16px}
  .chatbody{flex:1;min-height:160px;max-height:46vh;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:14px}
  .chatempty{margin:auto;color:var(--mut);text-align:center;font-size:13px;line-height:1.7}
  .msg{display:flex;gap:10px;max-width:88%}
  .msg.user{align-self:flex-end;flex-direction:row-reverse}
  .msg.assistant{align-self:flex-start}
  .msg .av{width:26px;height:26px;border-radius:7px;flex:0 0 auto;display:flex;align-items:center;justify-content:center;font-size:14px}
  .msg.user .av{background:rgba(91,140,255,.18)}
  .msg.assistant .av{background:rgba(54,192,138,.16)}
  .bub{padding:9px 13px;border-radius:12px;font-size:14px;line-height:1.6;white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere}
  .msg.user .bub{background:rgba(91,140,255,.14);border:1px solid rgba(91,140,255,.3)}
  .msg.assistant .bub{background:#11151f;border:1px solid var(--line)}
  .bub img.att{display:block;max-width:240px;max-height:200px;border-radius:8px;margin:6px 0 0;border:1px solid var(--line)}
  .bub code{background:#0d1018;padding:1px 5px;border-radius:4px;font-size:12.5px}
  .bub pre{background:#0d1018;border:1px solid var(--line);border-radius:8px;padding:10px;overflow:auto;margin:6px 0}
  .bub pre code{background:none;padding:0}
  .chatpending{align-self:flex-start;color:var(--mut);font-size:13px;padding:4px 2px}
  .chatpending .dotpulse{display:inline-block;animation:cpd 1.2s infinite}
  @keyframes cpd{0%,60%,100%{opacity:.25}30%{opacity:1}}
  /* Composer — the bordered box the user typed they love. */
  .composer{border-top:1px solid var(--line);padding:10px 12px 12px}
  .compbox{border:1px solid var(--line);border-radius:14px;background:#0e1320;padding:8px 10px;
    transition:border-color .15s}
  .compbox:focus-within{border-color:var(--accent)}
  .compthumbs{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:8px}
  .compthumbs:empty{display:none}
  .thumb{position:relative;width:56px;height:56px;border-radius:8px;overflow:hidden;border:1px solid var(--line)}
  .thumb img{width:100%;height:100%;object-fit:cover}
  .thumb .x{position:absolute;top:1px;right:1px;width:16px;height:16px;border-radius:50%;background:rgba(0,0,0,.7);
    color:#fff;font-size:11px;line-height:16px;text-align:center;cursor:pointer;border:none}
  #chatInput{width:100%;border:none;outline:none;background:transparent;color:var(--fg);resize:none;
    font:14px/1.5 inherit;max-height:200px;min-height:24px;overflow-y:auto}
  .comprow{display:flex;align-items:center;gap:8px;margin-top:6px}
  .comprow .spacer{flex:1}
  .iconbtn{width:32px;height:32px;border-radius:8px;border:1px solid var(--line);background:transparent;color:var(--fg);
    cursor:pointer;font-size:16px;display:flex;align-items:center;justify-content:center}
  .iconbtn:hover{border-color:var(--accent)}
  .iconbtn.send{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:700}
  .iconbtn.send:disabled{opacity:.4;cursor:default}
  .compmodel{background:#0e1320;color:var(--fg);border:1px solid var(--line);border-radius:8px;padding:5px 8px;font-size:12px}
  .comphint{color:var(--mut);font-size:11px}
  .chatdrop{outline:2px dashed var(--accent);outline-offset:-6px}
  /* (목표 추가 컴포저는 전용 페이지 /goal-add 로 이주 — GoalAddContent.swift. 여기 있던
     모달·컴포저 CSS(.gacomp·.fchip·.ga-* 계열)는 그 페이지가 가진다.) */
  /* Conversation thread inside the AI 중복 확인 다이얼로그. */
  .dupconv{display:flex;flex-direction:column;gap:10px;max-height:38vh;overflow-y:auto;padding:2px}
  .dupconv:empty{display:none}
  .dupsug{align-self:flex-start;margin:2px 0 0 36px}
  .dupsug button{font-size:12px;padding:4px 10px}
  .duppending{align-self:flex-start;color:var(--mut);font-size:13px;padding:2px 2px 2px 36px}

  /* ===== Zen (시작/휴식 화면) =====
     body.cm-zen hides the entire right-hand board so only the rail's challenge dial shows —
     a clean slate lowers the barrier to starting, where a board full of in-progress work
     feels like resuming a heavy game. SessionRail owns the class: armed on the app session's
     FIRST dashboard load (same launch test as the auto-start countdown: sessionStorage
     cmChArmed), revealed when the challenge actually starts (cmChRender → cmZenReveal), and
     RE-ENTERED when the 음원/챌린지 stops (running→stopped transition → cmZenEnter — 메모리를
     걷어내는 효과) AND when the 포모도로 완주 수확 오브 appears (cmChRenderReward — the finished
     session's board is leftover working memory; 수확 단계는 그걸 걷어내고 다시 집중하게 한다).
     The native window mirrors the class at rail width via the cmzen message
     channel (AppWindow). The dim 둘러보기 escape below reveals the board for browsing without
     starting. Idle navigations/reloads (no transition) keep the board. */
  body.cm-zen{ overflow:hidden }
  .wrap{ transition:opacity .7s ease }
  body.cm-zen .wrap{ opacity:0; visibility:hidden }
  .cmzen-peek{ display:none }
  body.cm-zen .cmzen-peek{ display:flex; position:fixed; left:var(--cmrail-w,240px); right:0; bottom:22px;
    justify-content:center; z-index:5 }
  .cmzen-peek button{ background:none; border:0; color:#39415a; font-size:12px; font-family:inherit;
    cursor:pointer; padding:6px 12px; border-radius:8px }
  .cmzen-peek button:hover{ color:#8b93a7; background:rgba(255,255,255,.04) }

  /* ===== Responsive (narrow-width) layout =====
     The rail (SessionRail.swift) is a fixed 240px strip that reserves space via
     `body{padding-left:var(--cmrail-w)}` — it is not a flex/grid sibling of .wrap, so
     "stacking" it at narrow widths means collapsing it via the EXISTING cmrail-collapsed
     mechanism (already ships a ☰ toggle + slide-out), not a new layout. Below ~720px the
     rail auto-collapses so the content gets the full narrow width instead of losing 240px
     of it. Above the breakpoint nothing here changes, so the desktop window layout is
     untouched (the native window is always wide).
     Self-check harness (runQaAudit, ~line 4106) flags th/.btn/.chip/short-td that wrap to
     2+ lines or overflow — so tab/button bars get horizontal scroll (nowrap) here rather
     than permitting them to wrap mid-label. */
  @media (max-width: 720px){
    /* Auto-collapse the fixed left rail so its reserved 240px doesn't eat the narrow
       viewport; the existing ☰ toggle still lets the user pull it back out. */
    /* Zero the reserved width itself (not just body's padding) so everything anchored to
       --cmrail-w — the overlays, the zen peek bar — follows the auto-collapse too. */
    body:not(.cmrail-force-open){ --cmrail-w:0px; padding-left:0 }
    body:not(.cmrail-force-open) .cmrail{ transform:translateX(-100%) }
    body:not(.cmrail-force-open) .cmrail-toggle{ display:block }

    .wrap{ padding:16px 12px }
    /* Whenever the rail is collapsed — either by this narrow-width auto-collapse
       (body:not(.cmrail-force-open)) or by the user's manual toggle (body.cmrail-collapsed) —
       the floating sidebar-toggle button (SessionRail.swift, fixed at top:40px/left:12px to
       clear the traffic lights) sits over the top-left of the page. Push the header down so
       the subtitle text doesn't render underneath it. */
    body:not(.cmrail-force-open) .wrap, body.cmrail-collapsed .wrap{ padding-top:52px }
    /* Header: allow the title to wrap at word boundaries (never per-character) and let
       the flex children actually shrink instead of refusing to (the per-character wrap
       symptom is a flex child with no min-width:0 forcing overflow). */
    .hdr{ flex-wrap:wrap; row-gap:8px }
    .hdr, .hdr > div{ min-width:0 }
    .hdr h1{ font-size:16px; overflow-wrap:break-word; word-break:keep-all }
    .hdr .sub{ overflow-wrap:break-word }

    .cards{ gap:8px }
    .card{ min-width:calc(50% - 4px); flex:0 0 calc(50% - 4px) }

    /* Sprint tab bar (view tabs) + sprint group header: keep every label on ONE line
       (required by the self-check harness) by scrolling horizontally instead of
       wrapping to a new row per tab. */
    .viewtabs{ flex-wrap:nowrap; overflow-x:auto; -webkit-overflow-scrolling:touch; padding-bottom:2px }
    .vtab{ flex:0 0 auto; white-space:nowrap }

    .spgrp-hd{ flex-wrap:nowrap; overflow-x:auto; -webkit-overflow-scrolling:touch }
    .spgrp-hd > *{ flex:0 0 auto; white-space:nowrap }

    /* Rows built with fixed min-widths (bar names, goal text, schedule/table cells)
       collapse to their content instead of forcing horizontal overflow. */
    .bar .name{ width:auto; max-width:38vw }
    .schrow .st{ min-width:0 }
    .gchild .gt{ min-width:0 }
    .aiwork input.agents{ width:100%; min-width:0 }
    .modal-box{ width:94vw }
    .modal-box .spmgoal, .spmgoal{ min-width:0 }
  }
  @media (max-width: 480px){
    .card{ min-width:100%; flex:0 0 100% }
    .hdr h1{ font-size:15px }
  }

  /* ===== 좁은 "판" 대응 (body.cmnarrow / body.cmxnarrow) =====
     위의 @media 는 뷰포트 폭을 본다. 그런데 3단계(작업 보드 + 대화 분할)에서는 창이 넓어도
     보드가 실제로 쓰는 폭은 뷰포트에서 레일(--cmrail-w)과 대화 패널(--cmchat-w)을 뺀 나머지다.
     그래서 창 1400px 에서도 보드는 600px 남짓이고, 데스크톱 규칙이 그대로 적용돼 목표 줄이
     잘리고 가로로 넘쳤다. 보드(.wrap)의 실제 폭을 재서 클래스를 붙이고(아래 cmNarrowWatch),
     같은 완화 규칙을 그 클래스에도 건다 — 뷰포트가 아니라 판이 기준. */
  body.cmnarrow .wrap{ padding:16px 12px }
  body.cmnarrow .hdr{ flex-wrap:wrap; row-gap:8px }
  body.cmnarrow .hdr, body.cmnarrow .hdr > div{ min-width:0 }
  body.cmnarrow .hdr h1{ font-size:16px; overflow-wrap:break-word; word-break:keep-all }
  body.cmnarrow .hdr .sub{ overflow-wrap:break-word }
  body.cmnarrow .cards{ gap:8px }
  body.cmnarrow .card{ min-width:calc(50% - 4px); flex:0 0 calc(50% - 4px) }
  body.cmnarrow .viewtabs{ flex-wrap:nowrap; overflow-x:auto; -webkit-overflow-scrolling:touch; padding-bottom:2px }
  body.cmnarrow .vtab{ flex:0 0 auto; white-space:nowrap }
  body.cmnarrow .spgrp-hd{ flex-wrap:nowrap; overflow-x:auto; -webkit-overflow-scrolling:touch }
  body.cmnarrow .spgrp-hd > *{ flex:0 0 auto; white-space:nowrap }
  body.cmnarrow .bar .name{ width:auto; max-width:38% }
  body.cmnarrow .bardwrap{ min-width:0 }
  body.cmnarrow .schrow .st{ min-width:0 }
  body.cmnarrow .gchild .gt{ min-width:0 }
  body.cmnarrow .aiwork input.agents{ width:100%; min-width:0 }
  body.cmnarrow .modal-box .spmgoal, body.cmnarrow .spmgoal{ min-width:0 }
  /* 목표/작업 줄: 이름은 남는 폭을 먹고 넘치면 말줄임, 뒤의 상태·시간 배지는 줄바꿈 없이 유지.
     (한 줄이 두 줄로 접히거나 글자가 세로로 쪼개지는 증상의 원인은 min-width 를 못 줄이는 flex 자식) */
  body.cmnarrow .gchild .gt{ overflow:hidden; text-overflow:ellipsis }
  body.cmnarrow .gchild > *:not(.gt){ flex:0 0 auto; white-space:nowrap }
  body.cmnarrow .exth{ min-width:0 }
  /* 아주 좁을 때(대화 패널을 크게 끌어다 놓은 경우) 카드는 한 줄에 하나. */
  body.cmxnarrow .card{ min-width:100%; flex:0 0 100% }
  body.cmxnarrow .hdr h1{ font-size:15px }

  /* 창을 더 넓힐 수 없는 경우(작은 화면)의 안전판: 3단계에서 대화 패널이 화면의 절반 이상을
     가져가지 못하게 묶는다. 여기서 body 에 다시 선언하므로 드래그가 :root 에 넣어 둔 값보다
     본문 안쪽 요소에는 이 값이 먼저 적용된다. */
  @media (max-width: 1000px){
    body.cmchat-side{ --cmchat-w:min(42vw, 420px) }
  }

  /* ===== 대화 패널 (2026-07-31 작업+대화 통합) =====
     레일 ⊞ 3단계와 짝을 이룬다 — 1 메모장만 / 2 메모+AI 컴포저 / 3 작업 보드 + 대화 분할.
     메모는 네이티브로 붙이고(1단계가 iframe 로딩에 안 묶이도록), 컴포저·큐·세션 뷰는
     /goal-add?embed=1 을 iframe 으로 얹는다 — 두 페이지의 전역 심볼(post/esc/$ 등)이 겹쳐서
     서버측 병합은 불가능했다. */
  /* 기본 분할 비율: 레일(240px)을 뺀 나머지를 작업 보드와 대화가 거의 반반씩 나눈다 —
     화면 전체로 편 3단계에서 사진과 같은 비율이 나오는 값이다. 드래그(cmchat-grip)는 :root 에
     인라인으로 값을 넣으므로 이 기본값을 덮고, 그 선택이 그대로 유지된다. */
  :root{ --cmchat-w:clamp(420px, calc((100vw - 240px) / 2), 1000px) }
  .cmchat{ position:fixed; top:0; right:0; bottom:0; width:var(--cmchat-w);
           display:flex; flex-direction:column; background:var(--bg);
           border-left:1px solid var(--line); z-index:40 }
  .cmchat-memo{ padding:14px 16px 0 }
  .cmchat-frame{ flex:1; min-height:0; border:0; width:100%; background:transparent }
  /* 분할 손잡이 — 3단계에서만. 실제 폭은 --cmchat-w 로 흘러간다(localStorage 영속). */
  .cmchat-grip{ position:absolute; left:-3px; top:0; bottom:0; width:7px; cursor:col-resize; z-index:1 }
  .cmchat-grip:hover{ background:rgba(91,140,255,.35) }
  body{ transition:padding-right .14s ease }
  body.cmchat-side{ padding-right:var(--cmchat-w) }
  /* 2단계: 보드가 없으니 대화 패널이 레일 오른쪽 전부를 차지한다. */
  body.cmchat-full .cmchat{ left:var(--cmrail-w); width:auto }
  body.cmchat-full .cmchat-grip{ display:none }
  /* 1단계: 레일도 접히고 메모장만. iframe(컴포저·큐)은 내린다. */
  body.cmmemo-only .cmchat{ left:0; width:auto; border-left:0 }
  body.cmmemo-only .cmchat-frame,
  body.cmmemo-only .cmchat-grip{ display:none }
  body.cmmemo-only .cmchat-memo{ flex:1; min-height:0; padding:0 }
  /* 보드 숨김(1·2단계) — grid/flex 가 아니라 단일 블록이라 display:none 으로 충분하다. */
  body.cmboard-off .wrap{ display:none !important }
</style>
</head>
<body>
\#(SessionRail.html())
<!-- Zen-start escape: browse the board without starting a challenge (body.cm-zen CSS above). -->
<div class="cmzen-peek"><button onclick="if(window.cmZenReveal)cmZenReveal()" title="챌린지를 시작하지 않고 보드만 봅니다">그냥 둘러보기 →</button></div>
<!-- 대화 패널 — 메모는 네이티브, 컴포저·큐·세션 뷰는 /goal-add 임베드. -->
<aside class="cmchat">
  <div class="cmchat-grip" id="cmChatGrip" title="드래그해서 작업/대화 폭을 조절합니다"></div>
  <div class="cmchat-memo">\#(MemoPad.html())</div>
  <iframe class="cmchat-frame" id="cmChatFrame" src="/goal-add?embed=1" title="대화"></iframe>
</aside>
<!-- data-cmboard: 레일 단계 머신이 "이 페이지에는 작업 보드가 있다"고 인식하는 표식.
     이게 있어야 ⊞ 가 1→2→3 세 단계로 순환한다(없으면 기존 접기/펴기 2단계). -->
<div class="wrap" data-cmboard>
  <div class="hdr">
    <div>
      <h1>오늘 활동 · BGM 디버그 <span id="devBadge" class="devbadge" style="display:none"></span></h1>
      <div class="sub" id="date">불러오는 중…</div>
    </div>
    <!-- 표시 타임존: 모든 시각의 기준이라 헤더 우상단에 상시 노출 — 성능 정보 위에 둔다.
         저장·계산은 항상 UTC(epoch), 이 값은 화면 표기 기준만 바꾼다. 변경 즉시 페이지 전체를
         새 tz로 다시 그린다(window.cmCondSetTz는 레일 설정과 공용). -->
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:5px">
      <div class="hdrtz" id="hdrTz" title="시간 표기 기준 — 저장·계산은 항상 UTC, 화면 표기만 이 타임존을 따릅니다. 모든 시각의 기준입니다.">
        <span class="hdrtz-ic" aria-hidden="true">🕓</span>
        <span class="hdrtz-lbl">타임존</span>
        <select class="hdrtz-sel" id="hdrTzSel" onchange="cmCondSetTz(event,this.value)" aria-label="표시 타임존"><option>불러오는 중…</option></select>
      </div>
      <span id="perf" title="이 대시보드 페이지의 자원 사용량 (메모리=JS 힙, CPU=프레임 타이밍 근사치)"
            style="font-size:11px;color:var(--mut);font-variant-numeric:tabular-nums;white-space:nowrap">측정 중…</span>
    </div>
  </div>

  <!-- 오늘 활동 요약(KPI 카드·티어 바·지금-라인)·최근 요약/차트·주요 앱 블록은
       컨디션 관리 페이지(/bgm-player)의 컨디션맵 탭으로 이동했다 — 컨디션맵과 함께 분석.
       라이브 APM은 왼쪽 세션 레일의 챌린지 다이얼(SessionRail) 서브라인으로 이동했다 —
       스포츠/타임 토글 게이지는 제거. -->

  <div id="viewTabs" class="viewtabs"></div>
  <div class="panel" id="goalPanel">
    <div id="goalFilters">
    <!-- SHARED STATUS FILTER — one bar drives 목록·그룹·프리뷰 alike -->
    <div class="row" style="margin:0 0 8px;gap:6px">
      <button class="btn combo" id="flt_status_combo" onclick="openStatusFilter(event)" title="표시할 상태를 선택 (다중 선택)">보기<span class="cbadge" id="flt_status_cnt" style="display:none">0</span> <span class="cv">▾</span></button>
      <button class="btn combo" id="flt_sprint_combo" onclick="openSprintFilter(event)" title="루프로 목록 필터 (다중 선택 · 릴리즈된 목표는 숨김)">루프<span class="cbadge" id="flt_sprint_cnt" style="display:none">0</span> <span class="cv">▾</span></button>
      <button class="btn combo" id="flt_type_combo" onclick="openTypeFilter(event)" title="유형으로 필터 (부모 · 자식 · task 다중 선택 — task를 켜면 부분과제 행이 목록에 나타납니다)">유형<span class="cbadge" id="flt_type_cnt" style="display:none">0</span> <span class="cv">▾</span></button>
      <span class="muted" id="flt_summary" style="font-size:12px">— 모두 표시</span>
    </div>
    <!-- COMPLETION-TIME CUTOFF — hide 완료 goals finished before this instant -->
    <div class="row" style="margin:0 0 8px;gap:6px">
      <span class="muted" style="font-size:12px">완료 컷오프</span>
      <input type="datetime-local" id="flt_donesince" class="btn" style="padding:4px 6px" value="2026-06-24T17:00"
             onchange="setDoneSince(this.value)" title="이 시각 이전에 완료된 목표는 숨깁니다 (완료 외 상태는 영향 없음)">
      <button class="btn" id="flt_donesince_clear" onclick="clearDoneSince()" title="완료 컷오프 해제 (모든 완료 표시)">해제</button>
    </div>
    </div><!-- /#goalFilters -->
    <!-- INPUT VIEW -->
    <div id="inputView">
      <div class="addhero">
        <div class="addhero-label">목표 추가</div>
        <div class="row addhero-row">
          <span class="bardwrap">
            <canvas id="bardCanvas" width="48" height="48" aria-hidden="true" title="음유시인이 1분마다 버프를 연주합니다"></canvas>
            <input type="text" id="goalText" placeholder="목표/디테일 입력 후 Enter (계속 추가)" style="width:100%"
                   onkeydown="goalKey(event)">
          </span>
          <span class="infowrap">
            <button class="btn" id="aiAddBtn" onclick="aiAdd()" oncontextmenu="return toggleAiTip(event)">AI추가</button>
            <div class="infotip" id="aiTip">번호를 보고 각 목표의 <b>부모#</b> 칸에 부모 번호를 입력하면 묶입니다 (비우면 최상위). 압축된 결과는 리포트에서 확인. <b>AI추가</b>는 기다리지 않고 큐에 담아 백그라운드로 중복을 분석합니다 — 결과는 chat의 <b>detail-큐</b>에서 원탭으로 확정.</div>
          </span>
          <button class="btn" onclick="addGoal()">추가</button>
        </div>
      </div>
      <div id="goals"></div>
    </div>

    <!-- (큐 뷰는 chat(/goal-add)의 detail-큐로 완전히 이전 — QueuePanel.swift. 진입은
         탭바 우측 큐 상태 노티 또는 chat 헤더의 detail-큐 토글.) -->

    <!-- REPORT VIEW (기간 필터는 컨디션맵과 동일한 CMTimeFilter 재사용) -->
    <div id="previewView" style="display:none">
      <div class="row" style="justify-content:space-between;gap:8px;flex-wrap:wrap">
        <div id="reportFilter"></div>
        <div class="row" style="margin:0;gap:6px">
          <button class="btn" onclick="copyMd(this)">마크다운 복사</button>
          <button class="btn" onclick="downloadCsv(this)" title="화면은 한 줄 요약, CSV는 전 필드 원문 — 팀·수신자별로 필요한 열만 골라 쓰세요">CSV 다운로드</button>
        </div>
      </div>
      <div id="report"></div>
    </div>

    <!-- GROUP VIEW (grouped input) -->
    <div id="groupView" style="display:none">
      <div class="gqbar">
        <div class="row" style="margin:0">
          <input type="text" id="gAddText" placeholder="목표 입력 후 Enter — 오른쪽 '부모'로 지정된 곳에 추가" style="flex:1;min-width:140px">
          <span class="muted" style="font-size:12px">부모</span>
          <input type="text" id="gParentPick" list="gParentList" placeholder="미분류(최상위)" onchange="gPickParent(this.value)" style="width:170px">
          <datalist id="gParentList"></datalist>
          <button class="btn primary" onclick="gAdd()">추가</button>
        </div>
        <div class="muted" style="font-size:12px;margin-top:4px">부모를 고르면 그 자리에 고정되어 Enter로 자식을 계속 추가할 수 있습니다. 부모를 비우면 새 최상위 목표가 됩니다. 각 섹션 머리글의 <b>+여기에</b>를 누르면 그 목표가 부모로 지정됩니다.</div>
      </div>
      <div class="row" style="margin:0 0 6px">
        <input type="text" id="gSearch" placeholder="부모 섹션 검색…" oninput="gSetQuery(this.value)" style="flex:1;min-width:120px">
        <button class="btn" onclick="gCollapseAll(true)">모두 접기</button>
        <button class="btn" onclick="gCollapseAll(false)">모두 펼치기</button>
      </div>
      <div id="groupSections"></div>
    </div>

    <!-- TABLE VIEW (정렬 전용 — 한 화면 평면 표, 헤더 클릭으로 정렬) -->
    <div id="tableView" style="display:none">
      <div class="muted" style="font-size:12px;margin:0 0 6px">헤더를 클릭하면 그 기준으로 정렬됩니다. 같은 헤더를 다시 누르면 오름차순·내림차순이 바뀝니다. 상태·완료 컷오프 필터가 그대로 적용됩니다.</div>
      <div id="tableHost"></div>
    </div>

    <!-- TOKEN VIEW (토큰 — 완료 항목의 토큰 사용량을 완료일·루프로 묶어 본다) -->
    <div id="tokenView" style="display:none">
      <div class="muted" style="font-size:12px;margin:0 0 6px"><b>일별 토큰 사용량</b> — 모든 Claude 세션 트랜스크립트(~/.claude/projects)에서 그날 실제로 쓴 토큰을 날짜별로 합산합니다. 신규 입력·출력·캐시 생성만 셉니다(캐시 재사용 제외, 같은 응답이 블록별로 중복 기재된 라인은 1회만). 막대는 구성비 — <b>컨텍스트</b>(프롬프트 쪽 전부)를 다시 4분할합니다: <span style="color:#3a4356">■ 재적재</span>(이전 턴 히스토리 재캐시+시스템 프롬프트) · <span style="color:#54627f">■ 도구결과</span>(파일 읽기·명령 출력·도구 스크린샷) · <span style="color:#96a5c8">■ 타이핑</span>(직접 친 프롬프트) · <span style="color:#c8b1e8">■ 사진</span>(첨부 이미지 — 장수·용량 병기). 출력 쪽은 <span style="color:#e8a13a">■ 생각</span>(thinking) · <span style="color:#8f6fe3">■ 응답</span>(보이는 텍스트) · <span style="color:#4f79c9">■ 도구</span>(도구 호출 인자). 하위 분할은 추정(텍스트=글자 가중, 이미지=w×h÷750 공식)이며 재적재는 잔차입니다. <b>비용($)</b>은 메시지별 모델(도중 교체 포함)에 공시 단가를 적용한 추정 — 캐시 읽기(×0.1)·캐시 쓰기(5분 ×1.25, 1시간 ×2)까지 반영하므로 토큰 K와 비례하지 않습니다. <b>AI 가동</b> = 프롬프트를 보낸 뒤 AI가 실제로 돌아간 시간의 합(응답이 끝난 뒤 방치한 시간은 포함 안 됨). <b>리드</b> = 응답이 끝난 뒤 다음 프롬프트 입력까지(이해+작성, 30분 초과 이탈 제외). <b>일 행을 클릭하면 세션별 상세</b>(토큰·$·구성비·모델·AI 가동·리드)가 펼쳐집니다. <b>창</b>은 그 세션이 쓴 모델의 컨텍스트 윈도우 크기이고, 그 옆 <b>%</b>는 마지막 어시스턴트 요청 하나에 실린 프롬프트 총량(input+cache_read+cache_creation, 서브에이전트 제외)을 그 창으로 나눈 <b>창 점유율</b>입니다 — 바로 옆의 구성비(<b>컨</b> …%)와는 다른 축이니 섞어 읽지 마십시오. 창 크기는 공시 기본값(대부분 200K)에서 시작하되 <b>관측된 세션이 그 기본값을 넘으면 1M로 승격</b>합니다(1M 컨텍스트 베타로 띄운 창이 실제로 있어, 표만 믿으면 점유율이 400%로 나옵니다). 공시 창 크기를 모르는 모델(<code>glm-*</code> 등)은 숫자를 지어내지 않고 <b>창 —</b>로 두고 절대 토큰만 보입니다.</div>
      <div class="row" style="margin:0 0 6px;gap:6px;align-items:center;flex-wrap:wrap">
        <button class="btn primary" id="tkm_tok" onclick="setTkMode('tok')" title="세션이 실제로 쓴 토큰(K)">토큰량</button>
        <button class="btn" id="tkm_val" onclick="setTkMode('val')" title="토큰효율·시간효율을 반영한 투입 지수(무단위 pt). 성과(가치)가 아니라 투입(비용) 측 지표">투입 지수</button>
        <span class="muted" id="tkModeHint" style="font-size:11px">세션이 실제로 쓴 토큰(K)</span>
      </div>
      <div class="muted" style="font-size:11px;margin:0 0 10px;padding:5px 9px;border:1px dashed #3a3550;border-radius:6px;color:#9a90c0">
        🔒 <b>성과(가치)·ROI: 미측정</b> — 여기 숫자는 <b>투입(토큰·시간)</b>이지 <b>성과</b>가 아닙니다. 얼마나 <b>썼는지</b>만 보여줍니다. 실제 가치는 회사 goal 연동 시 활성화 (<b>ROI = 성과 ÷ 투입</b>).
      </div>
      <div class="row" style="margin:0 0 10px;gap:6px;align-items:center;flex-wrap:wrap">
        <span class="muted" style="font-size:12px">기간</span>
        <button class="btn" id="tr_today" onclick="setTkRange('today')" title="오늘 하루">오늘</button>
        <button class="btn" id="tr_yesterday" onclick="setTkRange('yesterday')" title="어제 하루">어제</button>
        <button class="btn" id="tr_7d" onclick="setTkRange('7d')" title="최근 7일">7일</button>
        <button class="btn" id="tr_1m" onclick="setTkRange('1m')" title="최근 한 달">한달</button>
        <button class="btn" id="tr_3m" onclick="setTkRange('3m')" title="최근 3달">3달</button>
        <input type="date" id="tkFrom" class="btn" onchange="onTkDate()" style="color-scheme:dark;padding:5px 8px" title="시작 날짜">
        <span class="muted" style="font-size:12px">~</span>
        <input type="date" id="tkTo" class="btn" onchange="onTkDate()" style="color-scheme:dark;padding:5px 8px" title="끝 날짜">
        <button class="btn" onclick="loadTokenDaily(true)" style="margin-left:auto" title="일별 토큰 새로고침">새로고침</button>
      </div>
      <!-- MULTI-LLM & ACCOUNT FILTER BAR -->
      <div class="row" id="tkAccountBar" style="margin:0 0 6px;gap:6px;align-items:center;flex-wrap:wrap">
        <span class="muted" style="font-size:12px">도구·계정</span>
        <button class="btn primary" id="tkacc_all" onclick="setTkAccFilter('all')" title="모든 도구 및 계정">전체</button>
        <span id="tkAccChips" style="display:inline-flex;gap:5px;flex-wrap:wrap"></span>
      </div>
      <!-- MODEL & EFFORT ROUTING BAR -->
      <div class="row" id="tkModelBar" style="margin:0 0 10px;gap:6px;align-items:center;flex-wrap:wrap">
        <span class="muted" style="font-size:12px">모델·라우팅</span>
        <button class="btn primary" id="tkm_all" onclick="setTkModelFilter('all')" title="모든 모델">전체</button>
        <span id="tkModelChipsHost" style="display:inline-flex;gap:5px;flex-wrap:wrap"></span>
      </div>
      <div id="tokenDailyRange" class="muted" style="font-size:11px;margin:0 0 8px">불러오는 중…</div>
      <div id="tokenDailyHost"></div>
      <div class="muted" style="font-size:12px;margin:14px 0 6px;border-top:1px solid #222a36;padding-top:10px">완료된 목표를 <b>완료일</b>로 묶습니다. 위의 <b>기간</b> 필터가 완료일 기준으로 그대로 적용됩니다 — <b>어제</b>를 누르면 어제 완료된 목표만 나옵니다. 각 목표의 <b>세션 전체</b> 토큰이라, 위 일별 타임라인(그날 <b>소비량</b>)과는 기준이 다릅니다.</div>
      <div id="tokenHost"></div>
    </div>

    <!-- SCHEDULE VIEW (일정관리 — resource management) -->
    <div id="scheduleView" style="display:none">
      <div class="muted" style="font-size:12px;margin:0 0 4px">목표 날짜·완료 날짜로 리소스를 관리합니다. 각 목표의 <b>목표</b> 날짜시간을 정하면 긴급도(지남·오늘·이번 주·예정)로 묶입니다. 상태를 완료로 바꾸면 <b>완료</b> 시각이 자동 기록되며, 필요하면 직접 수정할 수 있습니다.</div>
      <div id="scheduleSections"></div>
    </div>

    <!-- SPRINT VIEW (루프 관리 — Jira식 백로그 보드 + 완료 로그) -->
    <div id="sprintView" style="display:none">
      <div id="sprintHost"></div>
      <div id="spModal" class="spmodal" style="display:none"><div class="modal-box" id="spModalBox"></div></div>
      <div id="extModal" class="spmodal" style="display:none" onclick="if(event.target===this)closeExtendModal()"><div class="modal-box" id="extModalBox" style="width:min(380px,92vw)"></div></div>
    </div>

    <!-- ARCHIVED VIEW (전체 목록 검색 — 활성·아카이브(릴리즈) 목표를 모두 검색·검토) -->
    <div id="archivedView" style="display:none">
      <div class="row" style="margin:0 0 8px">
        <input type="text" id="archSearch" placeholder="내용을 입력하고 AI 검색 — 비슷한 목표를 모두 찾습니다 (Enter)" oninput="onArchInput(this.value)" onkeydown="archKey(event)" style="flex:1;min-width:200px">
        <button class="btn primary" id="archAiBtn" onclick="archAiSearch()" oncontextmenu="archToggleHelp();return false" title="내용을 입력하면 표현이 달라도 의미가 비슷한 목표를 AI가 모두 찾아줍니다 (우클릭: 검색 사용법)">AI 검색</button>
        <button class="btn" id="archPlainBtn" onclick="archPlainSearch()" title="번호·내용·루프 코드의 글자 일치 검색 (즉시)">일반 검색</button>
        <button class="btn" id="archClearBtn" onclick="archClear()" title="검색을 지우고 전체 목록 표시">전체</button>
        <span class="muted" id="archSummary" style="font-size:12px"></span>
      </div>
      <div id="archHelp" class="muted" style="display:none;font-size:12px;margin:0 0 8px;padding:8px 10px;border:1px solid var(--border);border-radius:6px">루프 릴리즈로 비워진 것까지 포함해 <b>모든 목표</b>를 한곳에서 봅니다. <b>AI 검색</b>은 내용을 입력하면 표현이 달라도 의미가 비슷한 목표를 모두 찾아줍니다(기본). <b>일반 검색</b>은 번호·내용·루프 코드의 글자 일치입니다. 아카이브 항목은 <b>복원</b>으로 활성 목록에 되돌립니다.</div>
      <div id="archivedList"></div>
    </div>

    <!-- HERO VIEW (팀 칭찬 기록 — agent-mustcompany /hero 스킬이 쌓는 heroes.db 읽기 전용 뷰).
         기록은 Claude Code의 /hero 스킬로 하고, 여기서는 관리 편의(훑어보기·사람별 횟수·
         표준 포맷 복사)만 담당한다. 서버는 GET /api/hero/list (HeroStore.swift) 하나만 쓴다. -->
    <div id="heroView" style="display:none">
      <style>
        .hero-card{border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin:0 0 10px;background:var(--panel)}
        .hero-no{color:var(--mut);font-size:12px}
        .hero-skill{border:1px solid var(--accent);color:var(--accent);border-radius:999px;padding:1px 8px;font-size:11px;white-space:nowrap}
        .hero-reason{margin:8px 0 0;line-height:1.55}
        .hero-next{margin:8px 0 0;padding:5px 10px;border-left:3px solid var(--accent);font-size:13px;line-height:1.5}
        .hero-next2{margin:4px 0 0 13px;font-size:12px;color:var(--mut)}
        .hero-stat{display:inline-block;border:1px solid var(--line);border-radius:6px;padding:2px 8px;margin:0 6px 6px 0;font-size:12px}
        #heroView .btn.on{border-color:var(--accent);color:var(--accent)}
        /* 리더보드 — 순위는 굵기·막대 길이로만 표현한다 (상태 신호등 색 금지 규칙) */
        .hero-lb{border:1px solid var(--line);border-radius:8px;padding:8px 10px;margin:0 0 14px;background:var(--panel)}
        .hero-lbrow{display:flex;align-items:center;gap:8px;padding:4px 0;flex-wrap:wrap}
        .hero-rank{width:20px;text-align:right;font-size:12px;color:var(--mut)}
        .hero-lbrow:nth-child(-n+3) .hero-rank{color:var(--accent);font-weight:700}
        .hero-lbname{min-width:150px}
        .hero-bar{flex:1;min-width:60px;height:6px;border-radius:3px;background:var(--line);overflow:hidden}
        .hero-bar>i{display:block;height:100%;background:var(--accent);opacity:.75}
        .hero-lbn{font-size:12px;min-width:38px;text-align:right}
        .hero-lbskills{display:flex;gap:4px;flex-wrap:wrap}
        .hero-src{border:1px solid var(--line);border-radius:999px;padding:1px 8px;font-size:11px;color:var(--mut);text-decoration:none}
        a.hero-src:hover{color:var(--accent);border-color:var(--accent)}
        .hero-rawbox{border:1px solid var(--line);border-radius:8px;margin:14px 0 0;background:var(--panel)}
        .hero-rawhead{padding:8px 12px;font-size:12px;color:var(--mut);cursor:pointer;user-select:none}
        .hero-rawitem{border-top:1px solid var(--line);padding:8px 12px;font-size:12px;line-height:1.5;white-space:pre-wrap}
      </style>
      <div id="heroHost"><div class="empty">불러오는 중…</div></div>
    </div>

    <!-- 액션로그 뷰는 컨디션 관리 페이지(/bgm-player)의 액션로그 탭으로 이동했다 —
         컨디션맵 띠 클릭 드릴다운과 함께 분석 (BGMPlayerContent 참고). 대시보드에선 제거. -->

    <!-- 히스토리(날짜별 집중도·초집중 세션·시간대 분석)는 대시보드에서 분리되어 컨디션 관리
         페이지(/bgm-player)의 '히스토리' 서브탭으로 이동했다 — BGMPlayerContent.swift 참고. -->

    <!-- 워커(백그라운드/주기 작업) 상태는 대시보드에서 분리되어 독립 /cron 페이지로 이동했다.
         (레일의 '크론' 메뉴 → AppDelegate.cronPage) -->

  </div>

  <div class="foot">127.0.0.1 로컬 전용</div>
</div>

<!-- 🧩 플러그인 오버레이는 레일의 플러그인 페이지(SessionRail cmSkOverlay)로 머지되어 제거됐다.
     openPlugins()는 그 페이지를 여는 얇은 shim으로 남아 ?plugins=1 진입을 계속 받는다. -->

<!-- 공용 팝업: 보기(상태) 콤보·⋯ 메뉴·우클릭 이동 등. 어떤 뷰에서도 보이도록 최상위에 둔다
     (뷰 컨테이너 안에 두면 그 뷰가 숨겨질 때 position:fixed라도 렌더되지 않는다). -->
<div id="popup" class="popup" style="display:none"></div>

<!-- AI추가 중복 확인 다이얼로그: AI가 유사 목표를 찾으면 지금 추가(confirm)할지,
     나중 큐에 쌓아둘지(later) 고른다. -->
<div class="overlay" id="dupModal">
  <div class="modal" id="dupDrop">
    <div class="hdr"><h1 style="margin:0" id="dupTitle">🤖 AI 중복 확인</h1>
      <div style="display:flex;gap:6px;align-items:center">
        <button class="btn" id="dupCliBtn" style="display:none" title="이 다듬기 세션을 터미널에서 claude --resume 으로 바로 엽니다"
                onclick="openDupCli(this)">CLI에서 열기</button>
        <button class="btn" id="dupSessBtn" style="display:none" title="이 다듬기 세션의 claude 세션 ID를 복사합니다 (CLI에서 --resume 으로 이어쓰기)"
                onclick="copyDupSession(this)">세션 ID 복사</button>
        <button class="btn" onclick="closeDup()">닫기</button>
      </div></div>
    <p class="muted" id="dupNote">유사한 목표가 이미 있습니다. AI와 상의해 다듬은 뒤 추가하세요.</p>
    <div style="margin:6px 0 4px;font-size:13px;color:var(--mut)">추가하려는 목표 <span class="muted" style="font-size:11px">(직접 수정하거나 AI 제안을 적용할 수 있어요)</span></div>
    <input type="text" id="dupGoalText" class="btn" style="width:100%;font-weight:600;padding:8px 10px;margin-bottom:10px"
           onkeydown="if(event.key==='Enter'){event.preventDefault();dupConfirm();}">
    <div style="margin:6px 0 4px;font-size:13px;color:var(--mut)">이미 비슷한 목표</div>
    <div id="dupMatches"></div>
    <!-- AI와 대화하며 목표를 다듬는 영역 -->
    <div style="margin:14px 0 4px;font-size:13px;color:var(--mut)">AI와 대화하며 다듬기</div>
    <div class="dupconv" id="dupConv"></div>
    <div class="compbox" id="dupDropBox" style="margin-top:8px">
      <div class="compthumbs" id="dupThumbs"></div>
      <textarea id="dupChatInput" rows="1" placeholder="예) 이건 총량 검증이라 #4 안내와는 달라요. 문구를 더 구체적으로 다듬어줘 (이미지 붙여넣기·끌어다놓기 가능)"
                style="width:100%;border:none;outline:none;background:transparent;color:var(--fg);resize:none;font:14px/1.5 inherit;max-height:140px;min-height:22px"></textarea>
      <div class="comprow">
        <button class="iconbtn" onclick="dupPick()" title="이미지 첨부">＋</button>
        <span class="comphint" id="dupChatHint"></span>
        <span class="spacer"></span>
        <button class="iconbtn send" id="dupChatSend" onclick="dupChatSend()" title="AI에게 보내기 (Enter)">↑</button>
      </div>
      <input type="file" id="dupFile" accept="image/*" multiple style="display:none" onchange="dupPicked(this.files)">
    </div>
    <div class="row" style="justify-content:flex-end;gap:8px;margin-top:14px">
      <button class="btn" id="dupLaterBtn" onclick="dupLater()" title="지금은 결정하지 않고 큐에 보관합니다 — 검토는 chat의 detail-큐에서">later (큐에 보관)</button>
      <button class="btn" id="dupConfirmBtn" onclick="dupConfirm()" title="위 '추가하려는 목표' 문구로 지금 추가합니다">confirm (지금 추가)</button>
    </div>
  </div>
</div>

<!-- 목표 추가는 전용 페이지(/goal-add, GoalAddContent.swift)로 이주 — 모든 추가 진입점이
     openGoalAdd()를 통해 그 페이지로 이동한다(모달 없음, 깨끗한 새 문서에서 집중). -->
<!-- 작성 중이던 목표 초안 이어쓰기 칩: /goal-add 페이지에서 담지 않고 나온 입력(cm.gaDraft)이
     남아 있으면 표시된다. 클릭하면 마지막 대상 그대로 페이지를 다시 연다. -->
<button class="gadraft-chip" id="gaDraftChip" onclick="resumeGoalDraft()"><span class="pen">✎</span><span>작성 중인 목표</span></button>
<script>
\#(CMTimeFilter.js)
</script>
<script>
const $ = id => document.getElementById(id);
const PALETTE = ['#5b8cff','#36c08a','#e8a13a','#c879e6','#e2667d','#3ac6c6','#d98c5f','#9aa4b2'];
const colorCache = {};
function appColor(a){
  if(colorCache[a]) return colorCache[a];
  let h=0; for(const c of a) h=(h*31+c.charCodeAt(0))>>>0;
  const col = PALETTE[h % PALETTE.length]; colorCache[a]=col; return col;
}
function fmtMin(m){ if(m>=60) return (m/60).toFixed(1)+'시간'; return m+'분'; }
// The live APM "accelerator" gauge (and its 스포츠/타임 toggle) was removed from the
// dashboard header. Live APM now lives in the left session rail's challenge dial
// (see SessionRail.swift → #cmChApm), so it shows on every page, not just here.
// --- Page resource meter (top-right) -------------------------------------
// Memory: JS heap via performance.memory (Chromium only); DOM node count works
// everywhere. CPU is not exposed to JS, so we approximate it from frame timing:
// over a 1s window, the fraction of wall-clock the main thread overran the
// 60fps frame budget (16.7ms) is shown as an approximate busy %, with the
// measured FPS alongside. Honest proxy, not a real OS CPU reading.
const _FRAME_MS=1000/60;
let _pfFrames=0, _pfBusy=0, _pfWin=0, _pfLast=0, _pfRenderMs=0;
function perfFrame(t){
  if(_pfLast){ const ms=t-_pfLast; _pfFrames++; if(ms>_FRAME_MS) _pfBusy+=(ms-_FRAME_MS); }
  _pfLast=t;
  if(t-_pfWin>=1000){
    const span=t-_pfWin; _pfWin=t;
    const fps=Math.round(_pfFrames*1000/Math.max(1,span));
    const cpu=Math.min(99,Math.round(_pfBusy/Math.max(1,span)*100));
    _pfFrames=0; _pfBusy=0;
    const el=$('perf'); if(el){
      let mem='';
      const m=(performance&&performance.memory)?performance.memory:null;
      if(m){ mem='메모리 '+(m.usedJSHeapSize/1048576).toFixed(0)+'MB'; }
      const nodes=document.getElementsByTagName('*').length;
      const r=_pfRenderMs?(' · 렌더 '+_pfRenderMs.toFixed(0)+'ms'):'';
      el.textContent=(mem?mem+' · ':'')+'DOM '+nodes+'개 · CPU ~'+cpu+'% · '+fps+'fps'+r;
    }
  }
}
// Frame loop: drives only the page resource meter now (the header gauge is gone).
function perfLoop(t){ perfFrame(t); requestAnimationFrame(perfLoop); }
requestAnimationFrame(perfLoop);

// 헤더 타임존 셀렉터 채우기 — /api/settings/timezone(레일 설정과 동일 소스)에서 현재 tz를 읽어
// 옵션을 그린다. 변경은 window.cmCondSetTz(레일 JS의 전역, 저장 후 페이지 리로드)가 처리한다.
(function initHdrTz(){
  var sel=$('hdrTzSel'); if(!sel) return;
  fetch('/api/settings/timezone',{cache:'no-store'}).then(function(r){ return r.json(); }).then(function(tz){
    if(!tz){ return; }
    var cur=tz.tz||'system';
    // 인도(Asia/Kolkata, UTC+05:30)를 목록에 둔다 — 레일 설정 메뉴와 같은 목록이어야 한다.
    var opts=[['system','시스템 (맥 설정)'],['Asia/Seoul','KST (UTC+9)'],['Asia/Kolkata','IST (UTC+5:30)'],['UTC','UTC (+0)']];
    var seen=false, html=opts.map(function(x){ if(x[0]===cur) seen=true;
      return '<option value="'+x[0]+'"'+(x[0]===cur?' selected':'')+'>'+x[1]+'</option>'; }).join('');
    if(!seen) html+='<option value="'+cur+'" selected>'+(tz.label||cur)+'</option>';
    sel.innerHTML=html;
    var host=$('hdrTz'); if(host&&tz.label) host.title='시간 표기 기준 — 저장·계산은 항상 UTC, 화면 표기만 이 타임존을 따릅니다. 현재: '+tz.label;
  }).catch(function(){});
})();

async function load(){
  let d;
  try { d = await (await fetch('/data.json',{cache:'no-store'})).json(); }
  catch(e){ return; }
  $('date').textContent = d.date + ' · 분당 기록';
  // DEV dataset indicator: badge + top ribbon + tab title prefix when not production.
  const dev=$('devBadge');
  if(d.dev){ dev.style.display='inline-block'; dev.textContent='DEV · '+(d.dataLabel||'localdata');
    document.body.classList.add('devmode');
    if(!document.title.startsWith('[DEV]')) document.title='[DEV] '+document.title; }
  else { dev.style.display='none'; document.body.classList.remove('devmode'); }
  const _t0=performance.now();
  renderReview(d);   // 확정 가치/목표
  // 오늘 활동 요약·차트·주요 앱 블록은 컨디션 관리 페이지로 이동했다.
  // 워커 상태는 독립 /cron 페이지가 /workers.json 으로 자체 폴링한다(이 대시보드는 관여하지 않음).
  _pfRenderMs=performance.now()-_t0;
}

// ===== Plugins — merged into the rail's 플러그인 page (SessionRail cmSkOverlay).
// Kept as a shim so old entry points (?plugins=1, bookmarks) still land there.
function openPlugins(){ if(typeof cmSkillsOpen==='function') cmSkillsOpen(); }
// Tiny, safe markdown for AI replies: escape first, then code fences + inline code + bold.
// white-space:pre-wrap (CSS) keeps newlines, so we don't touch them.
function mdLite(s){
  let h=esc(s);
  h=h.replace(/```([\s\S]*?)```/g,(_,c)=>'<pre><code>'+c.replace(/^\n/,'')+'</code></pre>');
  h=h.replace(/`([^`\n]+)`/g,'<code>$1</code>');
  h=h.replace(/\*\*([^*\n]+)\*\*/g,'<b>$1</b>');
  return h;
}
function hhmm(t){ return CMTimeFilter.hhmm(t); }   // 표시 타임존 기준 HH:MM

// 최근 요약 렌더(renderSummary)·타임라인 로그 렌더(timelineSegments/rowHtml/
// paintTimeline/renderTimeline)는 컨디션 관리 페이지(/bgm-player)로 이동했다 — 대시보드에선 제거.

function esc(s){ return (s||'-').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function fmtH(min){ const h=Math.floor(min/60), m=min%60; return h>0? h+'시간 '+m+'분' : m+'분'; }
const TENMIN=10*60;
// Carry-forward (10-min continuity): a rest gap <= 10min bridged by work on BOTH
// sides becomes part of that continuous work — the in-between minutes are absorbed
// into the surrounding work, so a brief interruption (System Settings check, a
// loginwindow, a quick google) counts as 집중/책상 instead of breaking the streak.
//
// WHY neighbor-AGREEMENT (전후 일치), not "inherit the preceding tier":
//   The bridge tier is decided by BOTH ends. We only call the gap 집중(focus) when
//   BOTH neighbors are focus; if either side is merely 책상(desk), the gap stays
//   책상. Rationale: 집중 is 순공/몰입 (payout-relevant), so an interruption must
//   never INVENT focus it didn't earn — a pause between focus and desk is, at best,
//   desk-level continuity. Examples (matches the user's screenshots):
//     Cursor (집중) | System Settings | Cursor (집중)  -> gap = 집중
//     Slack (책상)  | loginwindow     | Slack (책상)   -> gap = 책상
//     Cursor (집중) | System Settings | Slack (책상)   -> gap = 책상 (전후 불일치)
function withCarryForward(samples){
  const ss=samples.slice().sort((a,b)=>a.t-b.t).map(s=>Object.assign({},s));
  ss.forEach(s=>{
    if(s.meeting) s._cat='meeting';
    else if((s.active||0)>0 && s.tier==='적극') s._cat='focus';
    else if((s.active||0)>0 && s.tier==='중간') s._cat='desk';
    else s._cat='rest';
  });
  const work=[]; ss.forEach((s,i)=>{ if(s._cat==='focus'||s._cat==='desk') work.push(i); });
  for(let k=0;k<work.length-1;k++){
    const a=work[k], b=work[k+1];                      // a = preceding work, b = following work
    if(ss[b].t-ss[a].t<=TENMIN){
      // Only focus when BOTH ends are focus; otherwise the bridge is desk.
      const bridgeFocus=(ss[a]._cat==='focus' && ss[b]._cat==='focus');
      // Inherit display fields from the neighbor that matches the bridge tier.
      const src=bridgeFocus ? a : (ss[a]._cat==='desk' ? a : b);
      const cat=bridgeFocus ? 'focus' : 'desk';
      for(let j=a+1;j<b;j++) if(ss[j]._cat==='rest'){
        ss[j]._cat=cat; ss[j]._inferred=true;
        ss[j].app=ss[src].app; ss[j].site=ss[src].site; ss[j].profile=ss[src].profile;
        ss[j].track=ss[src].track; ss[j].tier=ss[src].tier; ss[j].mult=ss[src].mult;
      }
    }
  }
  return ss;
}
// Time buckets (operates on carry-forward samples; each = 1 minute).
// Span anchors separated by < 8h = one work span; >= 8h gaps are 퇴근.
function timeBuckets(ss){
  const OFFGAP=8*3600;
  const anchors=[]; let desk=0, focus=0;
  ss.forEach(s=>{
    if(s._cat==='focus'){ focus++; desk++; }
    else if(s._cat==='desk'){ desk++; }
    if((s.active||0)>0 || s.meeting || s._inferred) anchors.push(s.t);
  });
  let total=0, off=0;
  if(anchors.length){
    total=1;
    for(let i=1;i<anchors.length;i++){
      const gap=anchors[i]-anchors[i-1];
      if(gap < OFFGAP) total += gap/60; // rest/meeting within span -> total
      else off += gap/60;               // >=8h gap -> 퇴근
    }
  }
  return {total:Math.round(total), desk, focus, off:Math.round(off)};
}
// 티어 바 렌더(drawTiers)·티어 색/배지(tierColor/tierBadge)는
// 컨디션 관리 페이지(/bgm-player)로 이동했다 — 대시보드에선 제거.

// 히스토리 뷰(날짜별 집중도·초집중 세션·시간대 분석)는 컨디션 관리 페이지(/bgm-player)의
// '히스토리' 서브탭으로 이동했다 — BGMPlayerContent.swift 참고. 아래 histDayStr/daysBetween/
// histPresetStart/tzLabel 은 토큰 뷰(tk*)도 쓰는 공통 헬퍼라 대시보드에 그대로 남긴다.
// 날짜 계산·프리셋·타임존은 공통 모듈(CMTimeFilter)에 위임 — 컨디션맵과 한 소스.
function histDayStr(d){ return CMTimeFilter.dayStr(d); }
function daysBetween(a,b){ return CMTimeFilter.daysBetween(a,b); }
function histPresetStart(preset){ return CMTimeFilter.presetRange(preset).start; }   // 'today'면 오늘 그대로
// 모든 시각은 이 기기의 로컬 타임존 기준. 하드코딩이 아니라 감지: Asia/Seoul이면 KST, 아니면 지역명 + UTC 오프셋.
function tzLabel(){ return CMTimeFilter.tzLabel(); }

// --- Value-confirmation pipeline + report ---
function provisionalHours(samples){ return samples.reduce((a,s)=>a+(s.active||0)*(s.mult||1),0)/3600; }
function post(path,obj){ return fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(obj||{})}).then(()=>load()); }
// Korean IME safe submit: defer the Enter-submit until composition ends. macOS WebKit
// can report the composition-committing Enter with isComposing=false, so a plain keydown
// guard is unreliable; if addGoal() clears the field mid-composition the IME re-inserts
// the trailing syllable into the empty field, leaking it as a duplicate goal.
let _composing=false,_pendingAdd=false;
function goalKey(e){ if(e.key!=='Enter')return; if(_composing){_pendingAdd=true;} else { addGoal(); } }
(function(){ const el=document.getElementById('goalText'); if(!el)return;
  el.addEventListener('compositionstart',function(){_composing=true;});
  el.addEventListener('compositionend',function(){_composing=false; if(_pendingAdd){_pendingAdd=false; addGoal();}});
})();
// Group-mode top add bar: same IME-safe Enter (bindImeEnter is hoisted).
(function(){ bindImeEnter(document.getElementById('gAddText'), function(){ gAdd(); }); })();
// (목표 추가 모달의 입력 배선은 전용 페이지 /goal-add 로 이주 — GoalAddContent.swift.)
// --- 목표 추가/검색은 전용 페이지(/goal-add)로 이주 — GoalAddContent.swift. ---
// 루프 보드의 모든 추가 진입점·레일의 목표 만들기/검색이 openGoalAdd()를 거쳐 그 페이지로
// 이동한다. 모달을 없앤 이유: 완전히 새 문서(깨끗한 JS 힙·최소 DOM)에서 목표 생성에 집중.
// 페이지가 초안(cm.gaDraft)과 마지막 대상(cm.gaCtx)을 localStorage 에 남기므로, 담지 않고
// 나온 입력은 아래 이어쓰기 칩이 같은 맥락으로 다시 연다.
function openGoalAdd(opts){
  opts=opts||{};
  if(opts.search){ location.href='/goal-add?search=1'; return; }
  const q=[];
  if(opts.sprint) q.push('sprint='+opts.sprint);
  if(opts.bump) q.push('bump=1');
  if(opts.parent) q.push('parent='+encodeURIComponent(opts.parent));
  if(opts.label) q.push('label='+encodeURIComponent(opts.label));
  location.href='/goal-add'+(q.length?('?'+q.join('&')):'');
}
// 초안이 남아 있으면 이어쓰기 칩을 보여준다 (load 마다 재확인 — 페이지에서 돌아오면 갱신됨).
function updateGaDraftChip(){
  const c=$('gaDraftChip'); if(!c) return;
  let d=''; try{ d=localStorage.getItem('cm.gaDraft')||''; }catch(e){}
  c.style.display=d.trim()?'inline-flex':'none';
}
// 이어쓰기 칩 클릭 → 마지막 대상(cm.gaCtx) 그대로 /goal-add 를 다시 열어 초안을 복원한다.
function resumeGoalDraft(){ location.href='/goal-add?resume=1'; }
// ===== 재사용 목표 추가 모듈 (single source of truth) =====
// 입력창(상단 항상 보이는 바)·루프 보드(Backlog·각 루프)의 모든 "목표 추가"가
// 이 두 코어 함수를 통해서만 추가한다. 진입점마다 미세하게 다른 add 로직을 두지 않는다.
// ctx: {sprint, parent} — 비어 있으면(0/'') 그 필드는 보내지 않아 기존 Backlog 추가와 동일.
// exec: 컴포저 실행 설정 {effort,mode,cwd,images} — 있으면 payload에 실어 goal에 영속화된다.
function gaMergeExec(o, exec){ if(!exec) return o;
  if(exec.effort) o.effort=exec.effort; if(exec.mode) o.mode=exec.mode; if(exec.cwd) o.cwd=exec.cwd;
  if(exec.images && exec.images.length) o.images=exec.images.slice(0,5); return o; }
function goalAddSubmit(text, ctx, exec){
  const t=String(text||'').trim(); if(!t) return false;
  const o={text:t};
  if(ctx){ if(ctx.sprint) o.sprint=ctx.sprint; if(ctx.parent) o.parent=ctx.parent; if(ctx.bump) o.bump=true; }
  gaMergeExec(o, exec);
  post('/api/goal/add',o);
  return true;
}
// AI추가 코어 (bump out): 기다리지 않는다. 후보를 즉시 큐(pending)에 담고 입력창을 비운 뒤
// 곧장 돌려준다 — 유저는 머릿속을 계속 비우면 된다. 서버 백그라운드 워커가 중복을 분석해
// '검토 대기(ready)'로 바꾸면, 아래 큐 목록에서 원탭(추가/수정/스킵)으로 확정한다.
// btn/onDup은 옛 시그니처 호환용으로 남겨두며 더는 쓰지 않는다.
function goalAddAi(text, ctx, btn, onAdded, onDup, exec){
  const t=String(text||'').trim(); if(!t) return;
  const o={text:t};
  if(ctx){ if(ctx.sprint) o.sprint=ctx.sprint; if(ctx.parent) o.parent=ctx.parent; }
  gaMergeExec(o, exec);               // 실행 설정은 큐 후보에 실려 승급(추가) 시 goal로 이어진다
  post('/api/goal/queue/enqueue',o);   // post()가 이어서 load()까지 호출 → 큐에 즉시 반영 (AI 큐는 그 자체가 bump out 파이프라인)
  if(onAdded) onAdded();               // 입력창 비우기/모달 닫기는 즉시 (대기 0초)
}
// 상단 항상 보이는 빠른 추가바 = 머릿속 덤프의 주 입구. 정리되지 않은 새 목표는 기본으로
// Bump out 인박스에 담아, 나중에 Backlog·Sprint로 끌어올린다(승격 파이프라인).
function addGoal(){ const el=$('goalText'); if(goalAddSubmit(el.value,{bump:true})){ el.value=''; el.focus(); } }
// --- AI추가: 추가 전에 claude -p가 기존 목표를 읽고 중복인지 먼저 판단한다. 중복이면
// later(큐 보관)/confirm(지금 추가) 다이얼로그를 띄우고, 아니면 곧장 추가한다. AI 호출이
// 실패/미설치여도 게이트가 아니므로 평소처럼 추가한다(베스트 에포트). ---
let _dupPending=null;   // {text,parent,note,matches} awaiting a later/confirm choice
// 우클릭으로 AI추가 안내 툴팁을 토글한다(브라우저 기본 메뉴는 막는다). 다른 곳을 클릭하면 닫힌다.
function toggleAiTip(ev){ ev.preventDefault(); const tip=$('aiTip'); if(!tip) return false;
  const open=tip.classList.toggle('show');
  if(open){ const close=(e)=>{ if(!tip.parentElement.contains(e.target)){ tip.classList.remove('show'); document.removeEventListener('mousedown',close); } };
    setTimeout(()=>document.addEventListener('mousedown',close),0); }
  return false; }
function aiAdd(){ const inp=$('goalText'); goalAddAi(inp.value,null,$('aiAddBtn'),()=>{ inp.value=''; inp.focus(); },null); }
// 다이얼로그 안의 대화 상태: 시작 메시지(중복 판정)부터 사용자/AI 주고받기까지.
let _dupConv=[];        // [{role:'user'|'assistant', text, images?:[dataURL]}]
let _dupImages=[];      // [{name, dataURL}] staged attachments for the next dup turn
let _dupBusy=false;     // an aiChat turn is in flight
let _dupWired=false;
function showDup(p){
  // 큐 항목 다듬기 모드(queueId 있음)면 안내·버튼 라벨을 그 맥락으로 바꾼다. 새 목표 추가 모드면 기존 그대로.
  const isQ=!!(p&&p.queueId);
  const tt=$('dupTitle'); if(tt) tt.textContent = isQ?'🤖 AI 큐 다듬기':'🤖 AI 중복 확인';
  const sid=(p&&p.refineSession)||'';
  const sb=$('dupSessBtn'); if(sb){ sb.style.display = sid?'':'none'; sb.textContent='세션 ID 복사'; }
  const cbi=$('dupCliBtn'); if(cbi){ cbi.style.display = sid?'':'none'; cbi.textContent='CLI에서 열기'; }
  $('dupNote').textContent = isQ
    ? '이 큐 항목을 AI와 대화하며 다듬으세요 (이미지 붙여넣기·끌어다놓기 가능). 다듬은 뒤 진행하거나 큐에 반영합니다.'
    : '유사한 목표가 있습니다. AI와 상의해 다듬은 뒤 추가하세요.';
  const cb=$('dupConfirmBtn'); if(cb){ cb.textContent = isQ?'이 결과로 진행':'confirm (지금 추가)';
    cb.title = isQ?'다듬은 문구로 이 항목을 목표로 추가합니다':"위 '추가하려는 목표' 문구로 지금 추가합니다"; }
  const lb=$('dupLaterBtn'); if(lb){ lb.textContent = isQ?'큐에 반영':'later (큐에 보관)';
    lb.title = isQ?'다듬은 문구로 큐 항목만 갱신하고 계속 대기시킵니다':'지금은 결정하지 않고 큐에 보관합니다 — 검토는 chat의 detail-큐에서'; }
  $('dupGoalText').value=p.text;       // 편집 가능한 "추가하려는 목표" (이게 실제로 추가됨)
  $('dupMatches').innerHTML=(p.matches||[]).map(m=>
    '<div style="padding:6px 8px;border:1px solid var(--line);border-radius:6px;margin-bottom:6px">'
    +'#'+m.seq+' <b>'+esc(m.text||'')+'</b>'
    +(m.why?'<div class="muted" style="font-size:12px;margin-top:2px">'+esc(m.why)+'</div>':'')+'</div>'
  ).join('')||'<div class="muted">(상세 없음)</div>';
  // AI의 첫 판정(note)을 대화의 시작 메시지로 깐다.
  _dupConv = p.note ? [{role:'assistant',text:p.note}] : [];
  _dupImages=[]; dupRenderThumbs();
  renderDupConv();
  wireDupChat();
  $('dupModal').classList.add('on');
  setTimeout(()=>{ const t=$('dupChatInput'); if(t) t.focus(); },50);
}
function wireDupChat(){
  if(_dupWired) return; _dupWired=true;
  const t=$('dupChatInput');
  t.addEventListener('input',()=>{ t.style.height='auto'; t.style.height=Math.min(140,t.scrollHeight)+'px'; });
  let composing=false;
  t.addEventListener('compositionstart',()=>composing=true);
  t.addEventListener('compositionend',()=>composing=false);
  t.addEventListener('keydown',e=>{
    if(e.key==='Enter' && !e.shiftKey && !composing && !e.isComposing){ e.preventDefault(); dupChatSend(); }
  });
  // 이미지 붙여넣기 (Claude Desktop 입력창처럼).
  t.addEventListener('paste',e=>{
    const items=(e.clipboardData||{}).items||[];
    const files=[]; for(const it of items){ if(it.type&&it.type.indexOf('image')===0){ const f=it.getAsFile(); if(f) files.push(f); } }
    if(files.length){ e.preventDefault(); dupAddFiles(files); }
  });
  // 다이얼로그 어디에든 이미지 끌어다 놓기.
  const drop=$('dupDrop');
  ['dragover','dragenter'].forEach(ev=>drop.addEventListener(ev,e=>{ e.preventDefault(); drop.classList.add('chatdrop'); }));
  drop.addEventListener('dragleave',e=>{ if(!drop.contains(e.relatedTarget)) drop.classList.remove('chatdrop'); });
  drop.addEventListener('drop',e=>{
    e.preventDefault(); drop.classList.remove('chatdrop');
    const fs=[...((e.dataTransfer||{}).files||[])].filter(f=>f.type.indexOf('image')===0);
    if(fs.length) dupAddFiles(fs);
  });
}
function dupPick(){ $('dupFile').click(); }
function dupPicked(files){ dupAddFiles(files); $('dupFile').value=''; }
function dupAddFiles(files){
  [...files].slice(0,8).forEach(f=>{
    if(_dupImages.length>=8) return;
    const r=new FileReader();
    r.onload=()=>{ _dupImages.push({name:f.name||'image.png',dataURL:r.result}); dupRenderThumbs(); };
    r.readAsDataURL(f);
  });
}
function dupRenderThumbs(){
  const host=$('dupThumbs'); if(!host) return;
  host.innerHTML=_dupImages.map((im,i)=>
    '<div class="thumb"><img src="'+im.dataURL+'" alt=""><button class="x" onclick="dupRemoveImg('+i+')" title="제거">×</button></div>'
  ).join('');
  const hint=$('dupChatHint'); if(hint) hint.textContent=_dupImages.length?(_dupImages.length+'장 첨부'):'';
}
function dupRemoveImg(i){ _dupImages.splice(i,1); dupRenderThumbs(); }
function renderDupConv(){
  const host=$('dupConv'); if(!host) return;
  host.innerHTML=_dupConv.map(m=>{
    const av=m.role==='user'?'🧑':'🤖';
    const body=(m.role==='assistant')?mdLite(m.text):esc(m.text);
    const imgs=(m.images||[]).map(u=>'<img class="att" src="'+u+'" alt="첨부 이미지">').join('');
    let extra='';
    if(m.role==='assistant' && m.suggestion){
      extra='<div class="dupsug"><button class="btn" onclick="dupApply('+JSON.stringify(m.suggestion).replace(/"/g,'&quot;')+')" title="이 문구를 위 목표 칸에 적용">📝 이 문구로 교체</button></div>';
    }
    return '<div class="msg '+(m.role==='user'?'user':'assistant')+'">'
      +'<div class="av">'+av+'</div><div class="bub">'+body+imgs+'</div></div>'+extra;
  }).join('');
  host.scrollTop=host.scrollHeight;
}
function dupApply(text){ $('dupGoalText').value=text; $('dupGoalText').focus(); }
function dupMatchesPayload(){
  // 첫 메시지에 보였던 매치들을 그대로 컨텍스트로 넘긴다.
  return (_dupPending&&_dupPending.matches)||[];
}
function dupChatSend(){
  if(_dupBusy) return;
  const t=$('dupChatInput'); const msg=t.value.trim();
  const imgs=_dupImages.slice();
  if(!msg && !imgs.length) return;
  _dupBusy=true; $('dupChatSend').disabled=true;
  t.value=''; t.style.height='auto'; _dupImages=[]; dupRenderThumbs();
  _dupConv.push({role:'user',text:msg,images:imgs.map(im=>im.dataURL)});
  renderDupConv();
  const host=$('dupConv');
  host.insertAdjacentHTML('beforeend','<div class="duppending" id="dupPending">AI가 생각하는 중<span class="dotpulse">…</span></div>');
  host.scrollTop=host.scrollHeight;
  // 직전까지의 대화(history, 이미지 dataURL은 제외해 가볍게) + 현재 편집 중인 목표(candidate) + 이번 이미지.
  const history=_dupConv.slice(0,-1).map(m=>({role:m.role,text:m.text}));
  fetch('/api/goal/aiChat',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({candidate:$('dupGoalText').value,matches:dupMatchesPayload(),history:history,message:msg,
      images:imgs.map(im=>({name:im.name,data:im.dataURL}))})})
    .then(r=>r.json())
    .then(res=>{
      if(!res||!res.ok){ _dupConv.push({role:'assistant',text:'⚠️ 응답을 받지 못했습니다.'}); }
      else { _dupConv.push({role:'assistant',text:res.reply||'',suggestion:res.suggestion||''}); }
      renderDupConv();
    })
    .catch(()=>{ _dupConv.push({role:'assistant',text:'⚠️ 전송에 실패했습니다.'}); renderDupConv(); })
    .finally(()=>{ _dupBusy=false; $('dupChatSend').disabled=false; const t2=$('dupChatInput'); if(t2) t2.focus(); });
}
function closeDup(){ $('dupModal').classList.remove('on'); _dupPending=null; _dupConv=[]; _dupImages=[]; dupRenderThumbs(); }
// confirm/later 모두 편집 가능한 "추가하려는 목표"(dupGoalText)의 현재 문구를 사용한다 —
// 대화로 다듬은 결과가 그대로 반영되도록.
function dupConfirm(){ const p=_dupPending; if(!p){closeDup();return;}
  const text=$('dupGoalText').value.trim(); if(!text){ $('dupGoalText').focus(); return; }
  closeDup();
  // 큐 항목 모드: 다듬은 문구로 그 항목을 목표로 승격(add). 새 목표 모드: 그냥 추가.
  if(p.queueId){ post('/api/goal/queue/resolve',{id:p.queueId,action:'add',text:text}); return; }
  const gt=$('goalText'); if(gt){ gt.value=''; gt.focus(); }
  const o={text:text,parent:p.parent||''}; if(p.sprint) o.sprint=p.sprint;   // 루프 보드에서 시작한 추가면 대상 유지
  post('/api/goal/add',o); }
function dupLater(){ const p=_dupPending; if(!p){closeDup();return;}
  const text=$('dupGoalText').value.trim()||p.text;
  closeDup();
  // 큐 항목 모드: 다듬은 문구로 큐 항목만 갱신(edit, 계속 대기). 새 목표 모드: 큐에 새로 보관.
  if(p.queueId){ post('/api/goal/queue/resolve',{id:p.queueId,action:'edit',text:text}); return; }
  const gt=$('goalText'); if(gt){ gt.value=''; gt.focus(); }
  post('/api/goal/queue/add',{text:text,parent:p.parent||'',note:p.note||'',matches:p.matches||[]}); }
// --- AI 큐 리뷰 UI는 chat(/goal-add)의 detail-큐로 완전히 이전됐다 (QueuePanel.swift) ---
// 대시보드에 남는 것: 탭바 우측 큐 상태 노티(updateQueueNoti, 클릭=chat detail-큐로 이동)와
// enqueue 진입점(aiAdd·dupLater·exportLinkmap). 아래 변수는 노티가 쓰는 큐 스냅샷이다.
let _lastAiQueue=[];
// 내보내기(링크 체인): linkmap 잡을 큐에 던지고 결과가 쌓이는 detail-큐(chat)로 이동한다.
function exportLinkmap(id){
  post('/api/queue/enqueue-linkmap',{root:id});
  location.href='/goal-add?q=detail';
}
function removeGoal(id){ post('/api/goal/remove',{id:id}); }
function saveNote(id,note){ post('/api/goal/note',{id:id,note:note}); }
// Inline rename: double-click a goal title to edit it in place. IME-safe Enter
// commits, Esc cancels, blur commits; empty or unchanged just restores. For a
// session-linked goal the server also mirrors the new title into the transcript so
// it survives future session events (see /api/goal/title).
function startTitleEdit(e,id){
  if(e){e.stopPropagation();}
  const span=document.getElementById('gt_'+id); if(!span||span._editing)return;
  const g=(_goals||[]).find(x=>x.id===id); const cur=g?(g.text||''):span.textContent;
  span._editing=true;
  const inp=document.createElement('input');
  inp.type='text'; inp.className='gedit'; inp.value=cur; inp.title='Enter 저장 · Esc 취소';
  span.innerHTML=''; span.appendChild(inp); inp.focus(); inp.select();
  let done=false;
  function commit(){ if(done)return; done=true;
    const t=inp.value.trim();
    if(!t||t===cur){ load(); return; }   // unchanged/empty -> restore
    post('/api/goal/title',{id:id,title:t}); }   // reloads on success
  inp.addEventListener('keydown',function(ev){ if(ev.key==='Escape'){ev.preventDefault();ev.stopPropagation(); if(!done){done=true; load();}} });
  inp.addEventListener('blur',commit);
  bindImeEnter(inp,commit);
}
// --- Completion evidence (links + files) + 완료 필터 ---
// Evidence is attached to the goal (persistent), so a finished item keeps its links
// and files for later — to find it and hand off the supporting material. Files are
// copied into the app store and served back via /evidence/<goalId>/<id>.
let _evOpen=new Set();    // goal ids whose evidence panel is expanded
// Per-status visibility toggles. A goal shows when its effective status is active.
// All-on = 전체(모두); only-done reproduces the old "완료만" hand-off view.
// waiting has no filter toggle (no UI button): it is always surfaced so a goal parked
// for the user can never be hidden — the whole point of the 응답 대기 state.
// stopped (중지) is shown by default like waiting (user needs to see it to resume); cancelled
// (취소) is HIDDEN by default and revealed via its own toggle, the way 완료 hand-off works.
let _statusFilter={backlog:true,in_progress:true,waiting:true,stopped:true,cancelled:false,done:true};
// 상위 항상 표시: when on, parents (goals with children) bypass the status filter so the
// hierarchy never collapses out from under a child. Default off = parents follow their
// rolled-up status like any other goal (디폴트는 부모도 안 보이도록).
let _showParents=false;
// 루프 콤보박스 선택값(다중 선택). 비어 있으면 '모두'(전체), 아니면 선택된 루프 번호 집합.
let _sprintSel=new Set();
// 유형 콤보박스 선택값(다중 선택): 'parent'(최상위 goal)·'child'(하위 goal)·'task'(부분과제).
// 비어 있으면 '모두' — 기존 그대로 부모+자식 goal을 보이고 task 행은 숨긴다. 'task'를 켜면
// 각 goal 아래에 tasks/<taskN> 행이 나타난다 (task가 추가돼도 목록에서 바로 보이도록).
let _typeSel=new Set();
const TYPE_KEYS=['parent','child','task'];
// 완료 컷오프: 이 시각(Unix 초) 이전에 완료된 목표는 숨긴다. 0이면 컷오프 해제(모든 완료 표시).
// 기본값은 필터 바 datetime-local 입력의 초기값과 동일하게 맞춘다(2026-06-24 17:00).
// 완료 외 상태(대기·진행 등)는 이 컷오프의 영향을 받지 않는다 — 현재 진행 중인 일은 항상 보인다.
const DONE_CUTOFF_DEFAULT='2026-06-24T17:00';
const DC_DEFAULT=CMTimeFilter.inputToEpoch(DONE_CUTOFF_DEFAULT);   // 표시 tz 벽시계로 해석
// Server-injected: the persisted cutoff (0 = 해제) if the user has set one, else DC_DEFAULT.
// This is what survives an app restart; the URL hash, if present, still overrides it below.
let _doneSince=\#(dcInit);
// Server-injected dashboard UI layout from the last session (null = never saved).
// Applied as the base in restoreFromURL; an explicit URL hash still overrides it.
const _prefsInit=\#(prefsInit);
let _review=null;         // last review object (for filter-only re-render)
let _lastReportArgs=null; // cached (d,r,conf,prov) so 리포트 can re-render on filter change
let _reportRange=null;    // {mode,preset,start,end} — 리포트 기간 필터(컨디션맵과 동일 CMTimeFilter)
let _reportCtl=null;      // mounted CMTimeFilter controller (mount once on first 리포트 view)
function evCount(g){ return (g.evidence||[]).length; }
function toggleEv(id){ if(_evOpen.has(id))_evOpen.delete(id); else _evOpen.add(id); applyEvOpen(); }
function applyEvOpen(){ (_goals||[]).forEach(g=>{ const p=document.getElementById('ev_'+g.id);
  if(p) p.classList.toggle('open', _evOpen.has(g.id)); }); }
// Review memo as a toggle button + collapsible inline editor (saveNote unchanged).
let _noteOpen=new Set();   // goal ids whose memo editor is expanded
function noteBtn(g,r){ const has=!!gnote(r,g.id);
  return '<button class="btn notebtn'+(has?' has':'')+'" onclick="toggleNote(\''+g.id+'\')" title="리뷰 메모">📝'+(has?' ✓':'')+'</button>'; }
function notePanel(g,r){ const nv=gnote(r,g.id).replace(/"/g,'&quot;');
  return '<div class="notepanel" id="note_'+g.id+'">'
    +'<input type="text" placeholder="리뷰 메모 입력" value="'+nv+'" onchange="saveNote(\''+g.id+'\',this.value)">'
    +'</div>'; }
function toggleNote(id){ if(_noteOpen.has(id))_noteOpen.delete(id); else _noteOpen.add(id); applyNoteOpen();
  const p=document.getElementById('note_'+id); if(p&&_noteOpen.has(id)){ const el=p.querySelector('input'); if(el) el.focus(); } }
function applyNoteOpen(){ (_goals||[]).forEach(g=>{ const p=document.getElementById('note_'+g.id);
  if(p) p.classList.toggle('open', _noteOpen.has(g.id)); }); }
function evItem(g,e){
  const t=esc(e.title||e.href||''), icon=(e.kind==='file')?'📄 ':'🔗 ';
  const a=(e.kind==='file')
    ? '<a href="'+esc(e.href)+'" download>'+icon+t+'</a>'
    : '<a href="'+esc(e.href)+'" target="_blank" rel="noopener">'+icon+t+'</a>';
  return '<span class="evitem">'+a+'<button class="evx" title="삭제" onclick="removeEvidence(\''+g.id+'\',\''+e.id+'\')">✕</button></span>';
}
function evidencePanel(g){
  const ev=g.evidence||[];
  const list=ev.length? ev.map(e=>evItem(g,e)).join('')
    : '<span class="muted" style="font-size:12px">첨부된 증거가 없습니다. 링크나 파일을 추가하세요.</span>';
  return '<div class="evpanel" id="ev_'+g.id+'">'
    +'<div class="evlist">'+list+'</div>'
    +'<div class="row" style="margin:6px 0 0">'
      +'<input type="text" id="evurl_'+g.id+'" placeholder="링크 URL 붙여넣기 후 Enter" style="flex:1;min-width:140px" onkeydown="evLinkKey(event,\''+g.id+'\')">'
      +'<button class="btn" onclick="addEvidenceLink(\''+g.id+'\')">링크 추가</button>'
      +'<label class="btn" style="cursor:pointer">파일 첨부<input type="file" multiple style="display:none" onchange="addEvidenceFiles(\''+g.id+'\',this)"></label>'
    +'</div></div>';
}
function evLinkKey(e,id){ if(e.key==='Enter'){ e.preventDefault(); addEvidenceLink(id); } }
function addEvidenceLink(id){
  const el=document.getElementById('evurl_'+id); if(!el)return;
  let u=el.value.trim(); if(!u)return;
  if(!/^[a-z][a-z0-9+.-]*:/i.test(u)) u='https://'+u;   // bare domain -> https
  el.value=''; _evOpen.add(id);
  post('/api/goal/evidence/add',{id:id,kind:'link',url:u});
}
function removeEvidence(gid,eid){ _evOpen.add(gid); post('/api/goal/evidence/remove',{id:gid,evidenceId:eid}); }
const EV_MAX=48*1024*1024;   // ~48MB/file (server caps the base64 request at 64MB)
function addEvidenceFiles(id,input){
  const files=input.files; if(!files||!files.length)return;
  _evOpen.add(id);
  let i=0;
  (function next(){
    if(i>=files.length){ input.value=''; load(); return; }
    const f=files[i++];
    if(f.size>EV_MAX){ alert('파일이 너무 큽니다(48MB 초과): '+f.name); next(); return; }
    const rd=new FileReader();
    rd.onload=function(){
      fetch('/api/goal/evidence/add',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({id:id,kind:'file',filename:f.name,data:rd.result})})
        .then(()=>next()).catch(()=>next());
    };
    rd.onerror=function(){ next(); };
    rd.readAsDataURL(f);
  })();
}
// 완료 필터: 완료된 목표(또는 자식이 모두 완료된 부모)만 추려, 나중에 찾고 자료를 넘길 때 사용.
function isDoneGoal(g,goals){ return (g.status==='done')||(derivedStatus(goals,g)==='done'); }
// Effective status used for visibility filtering. Parents report a derived rollup
// (on_track counts as 진행); leaves use their own status (default 대기).
function effStatus(g,goals){ const ds=derivedStatus(goals,g); if(ds!=null) return ds==='on_track'?'in_progress':ds; return g.status||'backlog'; }
// ===== Unified visibility: ONE filter feeds 목록·그룹·프리뷰 =====
// Single source of truth for "does this goal pass the current filter". Every view calls
// this instead of re-implementing the status test, so a filter applied once shows the
// same result everywhere. A parent (has children) is kept regardless when 상위 항상 표시
// is on; otherwise it follows its rolled-up effStatus like a leaf.
function hasKids(goals,g){ return goals.some(k=>k.parent===g.id); }
// Effective completion time for the cutoff test. A leaf uses its own completedAt; a
// derived-done parent (no own timestamp) rolls up to the latest child completion so a
// branch that all finished before the cutoff is hidden together with its parent.
function goalCompletedAt(g,goals){
  if(g.completedAt) return g.completedAt;
  let m=0; goals.forEach(k=>{ if(k.parent===g.id){ const c=goalCompletedAt(k,goals); if(c>m) m=c; } });
  return m;
}
// 완료 컷오프 통과 여부: 컷오프가 설정돼 있고 목표가 (롤업 기준) 완료 상태이며 완료 시각이
// 컷오프 이전이면 숨긴다. 완료 시각을 알 수 없으면(0) 안전하게 표시를 유지한다.
function passesDoneCutoff(g,goals){
  if(!_doneSince) return true;
  if(effStatus(g,goals)!=='done') return true;
  const c=goalCompletedAt(g,goals);
  if(!c) return true;
  return c>=_doneSince;
}
// Effective sprint number. A goal's own sprint wins; a DONE goal with no own sprint
// inherits its parent's (이미 완료한 건 부모 상속으로 입력 비용↓). Active goals never
// inherit — 이번 루프에서 자식이 빠질 수 있으므로 개별 배정한다.
function effSprint(g,goals){
  if(g.sprint>0) return g.sprint;
  if(effStatus(g,goals)==='done' && g.parent){ const p=byId(goals,g.parent); return p?(p.sprint||0):0; }
  return 0;
}
function byId(goals,id){ return (goals||[]).find(x=>x.id===id)||null; }
// 보드 그룹 판정: 자신의 sprint가 있으면 그것, 없으면 부모를 따라간다(부모-자식이 한 그룹에
// 묶여 보이도록). 자식을 다른 루프로 명시 배정하면 그 그룹으로 분리된다.
function boardSprint(g,goals){
  if(g.sprint>0) return g.sprint;
  if(g.sprint<0) return 0;            // 명시적 Backlog 분리 — 부모를 따라가지 않는다
  if(g.parent){ const p=byId(goals,g.parent); return p?boardSprint(p,goals):0; }
  return 0;
}
// 루프 콤보박스 통과 여부: '모두'면 전부, 숫자면 그 루프만.
function passesSprintFilter(g,goals){ return _sprintSel.size===0 ? true : _sprintSel.has(effSprint(g,goals)); }
// 유형 콤보박스 통과 여부: 비어 있으면 모두. '부모'=최상위(parent 없음), '자식'=하위(parent 있음).
// 'task'만 골라도 부분과제를 가진 goal은 남긴다 — task 행이 붙을 컨텍스트가 필요하므로.
function passesTypeFilter(g){
  if(_typeSel.size===0) return true;
  if(_typeSel.has('parent') && !g.parent) return true;
  if(_typeSel.has('child') && !!g.parent) return true;
  if(_typeSel.has('task') && (g.tasks||[]).length>0) return true;
  return false;
}
function goalPasses(g,goals){
  if(g.archived) return false;                    // 보관된 목표는 활성 목록에서 숨김(아카이브 뷰에만 노출)
  if(g.released) return false;                    // 릴리즈(커밋)된 목표는 활성 목록에서 숨김
  if(!passesSprintFilter(g,goals)) return false;  // 루프 콤보박스 (하드 게이트)
  if(!passesTypeFilter(g)) return false;          // 유형 콤보박스 (하드 게이트)
  if(!passesDoneCutoff(g,goals)) return false;    // 완료 컷오프는 상위 항상 표시보다 우선하는 하드 게이트
  if(_showParents && hasKids(goals,g)) return true;
  return !!_statusFilter[effStatus(g,goals)];
}
function getFilteredGoals(goals){ return goals.filter(g=>goalPasses(g,goals)); }
// 루프 보드용 필터: 상태 토글·완료 컷오프는 적용하되, 루프 콤보박스는 적용하지 않는다
// (보드 자체가 루프별로 그루핑하므로). 그래서 완료를 끄면 보드에서도 완료가 숨겨진다.
function goalPassesBoard(g,goals){
  if(g.archived) return false;
  if(g.released) return false;
  if(!passesTypeFilter(g)) return false;          // 유형 콤보박스는 보드에도 동일 적용
  if(!passesDoneCutoff(g,goals)) return false;
  if(_showParents && hasKids(goals,g)) return true;
  return !!_statusFilter[effStatus(g,goals)];
}
// Re-render every view from the cached review when the filter changes — instant feedback
// in whichever view is active, without waiting for the 5s auto-refresh.
function reapplyFilter(){
  if(!_review) return;
  updateFilterButtons();
  fillActiveView(_review);
  if(_lastReportArgs){ const a=_lastReportArgs; _md=buildMarkdown(a.d,a.r,a.conf,a.prov); renderReport(a.d,a.r,a.conf,a.prov); }
}
// ===== 리포트 기간 필터 (컨디션맵과 동일한 CMTimeFilter 재사용) =====
// 리포트 뷰를 처음 열 때 한 번 마운트한다. 프리셋/커스텀/자동은 컨디션맵과 동일.
function initReportFilter(){
  if(_reportCtl) return;
  const host=$('reportFilter'); if(!host) return;
  _reportCtl=CMTimeFilter.mount(host, {
    presets:['today','yesterday','7d','30d','90d'], auto:true, custom:true, initial:'auto',
    onChange:(r)=>{ _reportRange=r;
      // 캐시된 리뷰로 리포트만 즉시 다시 그린다 (5초 폴링을 기다리지 않음).
      if(_lastReportArgs){ const a=_lastReportArgs; _md=buildMarkdown(a.d,a.r,a.conf,a.prov); renderReport(a.d,a.r,a.conf,a.prov); }
    }
  });
}
// 기간 필터는 '완료' 목표에만 건다(완료 컷오프와 동일한 규칙). 대기·진행 등 미완료 목표는
// 기간과 무관하게 보기(상태) 필터만 따른다. 완료 목표는 롤업 완료 시각(goalCompletedAt)이
// 선택 기간 [start, end] 안에 들 때만 리포트에 포함. 완료 시각 불명(0)이면 표시를 유지.
function reportPassesRange(g,goals){
  if(!_reportRange || !_reportRange.start) return true;
  if(effStatus(g,goals)!=='done') return true;
  const c=goalCompletedAt(g,goals); if(!c) return true;
  const s=CMTimeFilter.parseDay(_reportRange.start).getTime()/1000;
  const e=CMTimeFilter.parseDay(_reportRange.end).getTime()/1000 + 86400;   // end 당일 끝까지 포함
  return c>=s && c<e;
}
// 리포트 헤더에 표시할 기간 라벨. 범위 미설정이면 그날 날짜, 하루면 그 날짜, 아니면 start ~ end.
function reportRangeLabel(fallbackDate){
  const r=_reportRange; if(!r || !r.start) return fallbackDate;
  return (r.start===r.end) ? r.start : (r.start+' ~ '+r.end);
}
// 보기 토글: 상태 버튼을 켜면 그 상태의 목표가 보이고, 끄면 숨겨진다.
function toggleStatusFilter(s){ _statusFilter[s]=!_statusFilter[s]; reapplyFilter(); syncURL(); }
function toggleShowParents(){ _showParents=!_showParents; reapplyFilter(); syncURL(); }
// 보기(상태) 콤보박스: 체크박스 드롭다운으로 다중 선택. 깔끔한 한 칸 UI로 묶었다.
function statusMenuHTML(){
  function row(on,label,call){
    return '<button class="popitem chk'+(on?' on':'')+'" onclick="'+call+'">'
      +'<span class="cbx"></span>'+label+'</button>';
  }
  return '<div class="ckmenu">'
    +'<div class="pophdr">보기 상태 (다중 선택)</div>'
    +row(_statusFilter.backlog,'대기','sfPick(\'backlog\')')
    +row(_statusFilter.in_progress,'진행','sfPick(\'in_progress\')')
    +row(_statusFilter.done,'완료','sfPick(\'done\')')
    +row(_statusFilter.cancelled,'취소','sfPick(\'cancelled\')')
    +'<div class="popdiv"></div>'
    +row(_showParents,'상위 항상 표시','sfParents()')
    +'</div>';
}
function openStatusFilter(e){
  e.stopPropagation();
  const r=e.currentTarget.getBoundingClientRect();
  showPopup(r.left, r.bottom+4, statusMenuHTML());
}
// 토글 후 팝업은 열어 둔 채 내용만 갱신 — 연속 선택을 위해.
function sfPick(s){ toggleStatusFilter(s); setPopupHTML(statusMenuHTML()); }
function sfParents(){ toggleShowParents(); setPopupHTML(statusMenuHTML()); }
// 루프 콤보박스(다중 선택): 상태 콤보와 같은 체크박스 드롭다운 패턴. 비어 있으면 '모두'.
// 옵션 산출: 닫히지 않은(진행 중) 루프는 골이 아직 없어도 보여준다 — 만들자마자 배정할 수
// 있게. 릴리즈로 닫힌 루프는 숨긴다. 여기에 활성 골이 붙은 번호도 합쳐, 닫혔지만 미완료
// 골이 남은 루프의 잔여 작업도 놓치지 않는다. 정렬해 라벨로 고를 때 헷갈리지 않게.
function sprintNums(){
  const goals=(_review&&_review.goals)||[];
  const defined=(_review&&_review.sprints)||[];
  const openDefined=defined.filter(s=>!s.closed).map(s=>s.number);
  const activeNums=goals.filter(g=>!g.released).map(g=>effSprint(g,goals)).filter(n=>n>0);
  return [...new Set(openDefined.concat(activeNums))].sort((a,b)=>a-b);
}
function sprintMenuHTML(){
  const defined=(_review&&_review.sprints)||[];
  const labelOf={}; defined.forEach(s=>{ labelOf[s.number]=(s.code||('#'+s.number))+(s.goalText?(' · '+s.goalText):''); });
  const nums=sprintNums();
  [..._sprintSel].forEach(n=>{ if(!nums.includes(n)) _sprintSel.delete(n); });   // 사라진 루프는 선택에서 제거
  let h='<div class="ckmenu spmenu"><div class="pophdr">루프 (다중 선택)</div>';
  h+='<button class="popitem chk'+(_sprintSel.size===0?' on':'')+'" onclick="spAll()"><span class="cbx"></span>모두</button>';
  if(nums.length) h+='<div class="popdiv"></div>';
  nums.forEach(function(n){ const on=_sprintSel.has(n); const lab=labelOf[n]||('루프 '+n);
    h+='<button class="popitem chk'+(on?' on':'')+'" onclick="spPick('+n+')"><span class="cbx"></span>'+lab.replace(/</g,'&lt;')+'</button>'; });
  return h+'</div>';
}
function openSprintFilter(e){
  e.stopPropagation();
  const r=e.currentTarget.getBoundingClientRect();
  showPopup(r.left, r.bottom+4, sprintMenuHTML());
}
// 토글 후 팝업은 열어 둔 채 내용만 갱신 — 연속 선택을 위해. '모두'는 선택을 비운다.
function spPick(n){ if(_sprintSel.has(n)) _sprintSel.delete(n); else _sprintSel.add(n); reapplyFilter(); syncURL(); setPopupHTML(sprintMenuHTML()); }
function spAll(){ _sprintSel.clear(); reapplyFilter(); syncURL(); setPopupHTML(sprintMenuHTML()); }
// 유형 콤보박스(다중 선택): 상태·루프 콤보와 같은 체크박스 드롭다운 패턴. 비어 있으면 '모두'.
// 'task'를 켜면 목록의 각 goal 아래에 부분과제(tasks/<taskN>) 행이 나타난다.
const TYPE_LABELS={parent:'부모 (최상위)',child:'자식 (하위)',task:'task (부분과제)'};
function typeMenuHTML(){
  let h='<div class="ckmenu"><div class="pophdr">유형 (다중 선택)</div>';
  h+='<button class="popitem chk'+(_typeSel.size===0?' on':'')+'" onclick="tyAll()"><span class="cbx"></span>모두</button>';
  h+='<div class="popdiv"></div>';
  TYPE_KEYS.forEach(function(k){
    h+='<button class="popitem chk'+(_typeSel.has(k)?' on':'')+'" onclick="tyPick(\''+k+'\')"><span class="cbx"></span>'+TYPE_LABELS[k]+'</button>';
  });
  return h+'</div>';
}
function openTypeFilter(e){
  e.stopPropagation();
  const r=e.currentTarget.getBoundingClientRect();
  showPopup(r.left, r.bottom+4, typeMenuHTML());
}
// 토글 후 팝업은 열어 둔 채 내용만 갱신 — 연속 선택을 위해. '모두'는 선택을 비운다.
function tyPick(k){ if(_typeSel.has(k)) _typeSel.delete(k); else _typeSel.add(k); reapplyFilter(); syncURL(); setPopupHTML(typeMenuHTML()); }
function tyAll(){ _typeSel.clear(); reapplyFilter(); syncURL(); setPopupHTML(typeMenuHTML()); }
// 콤보 버튼 카운트 배지 갱신 (Jira식): 라벨은 '유형' 고정, 선택 개수만 배지 숫자로.
function updateTypeCombo(){
  const cnt=$('flt_type_cnt'), combo=$('flt_type_combo');
  const n=_typeSel.size;
  if(cnt){ if(n>0){ cnt.textContent=n; cnt.style.display=''; } else cnt.style.display='none'; }
  if(combo) combo.classList.toggle('active', n>0);
}
// 콤보 버튼 카운트 배지 갱신 (Jira식): 라벨은 '루프' 고정, 선택 개수만 배지 숫자로.
function updateSprintCombo(){
  const cnt=$('flt_sprint_cnt'), combo=$('flt_sprint_combo');
  const n=_sprintSel.size;
  if(cnt){ if(n>0){ cnt.textContent=n; cnt.style.display=''; } else cnt.style.display='none'; }
  if(combo) combo.classList.toggle('active', n>0);
}
// 완료 컷오프 설정/해제. datetime-local 값(표시 tz 벽시계)을 Unix 초로 환산; 빈 값이면 해제(0).
function setDoneSince(v){ _doneSince=CMTimeFilter.inputToEpoch(v); reapplyFilter(); syncURL(); post('/api/prefs/donecutoff',{dc:_doneSince}); }
function clearDoneSince(){ _doneSince=0; const el=$('flt_donesince'); if(el) el.value=''; reapplyFilter(); syncURL(); post('/api/prefs/donecutoff',{dc:_doneSince}); }
function anyStatusActive(){ return _statusFilter.backlog||_statusFilter.in_progress||_statusFilter.done||_statusFilter.cancelled; }
// Summary text mirrors the active combo: 모두 / 완료 만 / 완료 진행 만 …
function filterSummary(){
  if(!anyStatusActive()) return '표시할 상태를 선택하세요 (대기 · 진행 · 완료)';
  if(_statusFilter.backlog&&_statusFilter.in_progress&&_statusFilter.done&&!_statusFilter.cancelled) return '모두 표시';
  const names=[];
  if(_statusFilter.done) names.push('완료');
  if(_statusFilter.cancelled) names.push('취소');
  if(_statusFilter.in_progress) names.push('진행');
  if(_statusFilter.backlog) names.push('대기');
  return names.join(' ')+' 만';
}
function updateFilterButtons(){
  // Jira식: 라벨은 '보기' 고정, 선택된 상태 개수만 배지 숫자로. 상세 요약은 flt_summary가 맡는다.
  const scnt=$('flt_status_cnt'); const ssel=['backlog','in_progress','done','cancelled'].filter(k=>_statusFilter[k]).length;
  if(scnt){ if(ssel>0){ scnt.textContent=ssel; scnt.style.display=''; } else scnt.style.display='none'; }
  const combo=$('flt_status_combo'); if(combo) combo.classList.toggle('active',ssel>0);
  const cb=$('flt_donesince_clear'); if(cb) cb.classList.toggle('primary',!!_doneSince);
  updateSprintCombo();
  updateTypeCombo();
  const spArr=[..._sprintSel].sort((a,b)=>a-b);
  const sp=spArr.length?(' · 루프 '+spArr.map(sprintCode).join(', ')+' 만'):'';
  const tyNames={parent:'부모',child:'자식',task:'task'};
  const ty=_typeSel.size?(' · 유형 '+TYPE_KEYS.filter(k=>_typeSel.has(k)).map(k=>tyNames[k]).join(', ')+' 만'):'';
  const cut=_doneSince?' · '+fmtDate(_doneSince)+' 이전 완료 숨김':'';
  const s=$('flt_summary'); if(s) s.textContent='— '+filterSummary()+sp+ty+(_showParents?' · 상위 항상 표시':'')+cut;
}
// ===== URL 상태 영속화 — 뷰·필터 설정을 location.hash에 보관 =====
// 목적: 루프 작업 중 새로고침해도 뷰/필터가 초기화되지 않게 한다(완료 토글 해제 등도 보존).
// 해시만 사용하므로 서버로는 전송되지 않고, 북마크·공유로도 같은 화면이 재현된다.
// 기본값과 같은 항목은 기록을 생략해 해시를 깔끔하게 유지한다.
const _ST_DEFAULT='backlog,in_progress,done';   // 토글 4종(대기·진행·완료·취소) 중 기본 ON 조합
let _urlReady=false;   // restore 완료 전에는 syncURL을 막아 부팅 중 기본값 덮어쓰기 방지
function syncURL(){
  if(!_urlReady) return;
  const q=new URLSearchParams();
  if(_view!=='input') q.set('view',_view);
  const st=['backlog','in_progress','done','cancelled'].filter(k=>_statusFilter[k]).join(',');
  if(st!==_ST_DEFAULT) q.set('st',st);
  if(_showParents) q.set('par','1');
  if(_sprintSel.size) q.set('sp',[..._sprintSel].sort((a,b)=>a-b).join(','));
  if(_typeSel.size) q.set('ty',TYPE_KEYS.filter(k=>_typeSel.has(k)).join(','));
  if(_doneSince!==DC_DEFAULT) q.set('dc',String(_doneSince));   // 0 = 컷오프 해제
  // 보드 접기 상태도 보존 — 그룹(루프 번호·'bg' Backlog)과 자식 접은 부모 id.
  // 새로고침/5초 폴 재렌더 후에도 접어둔 섹션이 다시 펼쳐지지 않게 한다.
  if(_spCollapsed.size) q.set('spc',[..._spCollapsed].join(','));
  if(_bgCollapsed.size) q.set('bgc',[..._bgCollapsed].join(','));
  const s=q.toString();
  history.replaceState(null,'',s?('#'+s):(location.pathname+location.search));
  // URL 해시는 같은 세션의 새로고침엔 충분하지만, 서버 포트가 매 실행마다 바뀌어
  // 앱을 껐다 켜면 사라진다. 그래서 같은 레이아웃을 서버에도 저장해 재시작 후에도
  // 마지막 보기·필터·펼침 상태가 그대로 복원되게 한다.
  savePrefs();
}
// 서버 저장용 UI 레이아웃 블롭. syncURL이 호출되는 모든 변경 지점(보기 토글·상위 표시·
// 루프 선택·보드 접기)에서 함께 저장된다. 펼침 상태를 정확히 복원하려면 _bgSeen·_gSeen
// (사용자가 이미 본 부모들)도 저장해야 한다 — 그래야 복원 후 첫 렌더의 기본-접기 로직이
// 펼쳐둔 부모를 다시 접지 않는다.
function savePrefs(){
  if(!_urlReady) return;   // 부팅 복원 중에는 저장된 prefs를 덮어쓰지 않는다
  const p={
    st:['backlog','in_progress','done','cancelled'].filter(k=>_statusFilter[k]),
    par:_showParents?1:0,
    sp:[..._sprintSel],
    ty:[..._typeSel],
    spc:[..._spCollapsed],
    bgc:[..._bgCollapsed],
    bgseen:[..._bgSeen],
    gc:[..._gCollapsed],
    gseen:[..._gSeen],
    tord:_tabOrder,        // 뷰 탭 순서 (좌우 이동 결과)
    dv:_defaultView        // 기본 보기 (Set as default)
  };
  // 순수 저장이므로 post()의 자동 재로드(load())를 타지 않는다 — 토글마다 데이터 재요청·깜빡임을 피한다.
  fetch('/api/prefs/ui',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({data:JSON.stringify(p)})}).catch(()=>{});
}
// 서버에 저장된 UI 레이아웃을 상태 변수에 적용한다(restoreFromURL에서 해시보다 먼저 호출 →
// 명시적 URL 해시가 있으면 그 값이 우선한다).
function applyPrefs(p){
  if(!p||typeof p!=='object') return;
  if(Array.isArray(p.st)){ const on=new Set(p.st);
    ['backlog','in_progress','done','cancelled'].forEach(k=>{ _statusFilter[k]=on.has(k); }); }
  if('par' in p) _showParents=!!p.par;
  if(Array.isArray(p.sp)) p.sp.forEach(n=>{ const v=parseInt(n,10); if(v>0) _sprintSel.add(v); });
  if(Array.isArray(p.ty)) p.ty.forEach(k=>{ if(TYPE_KEYS.includes(k)) _typeSel.add(k); });
  // 루프 그룹 키는 숫자(루프 번호)면 Number로 되돌려 _spCollapsed.has(s.number)와 일치시킨다.
  if(Array.isArray(p.spc)) p.spc.forEach(k=>_spCollapsed.add(/^\d+$/.test(String(k))?parseInt(k,10):k));
  if(Array.isArray(p.bgc)) p.bgc.forEach(k=>_bgCollapsed.add(k));
  // 펼침 보존의 핵심: 이미 본 부모를 시드해 첫 렌더의 기본-접기가 펼쳐둔 부모를 다시 접지 않게 한다.
  if(Array.isArray(p.bgseen)) p.bgseen.forEach(k=>_bgSeen.add(k));
  if(Array.isArray(p.gc)) p.gc.forEach(k=>_gCollapsed.add(k));
  if(Array.isArray(p.gseen)) p.gseen.forEach(k=>_gSeen.add(k));
  if(Array.isArray(p.tord)) _tabOrder=p.tord.filter(k=>VIEW_KEYS.includes(k));   // 빠진 표준 키는 normTabOrder가 채운다
  if(typeof p.dv==='string' && VIEW_KEYS.includes(p.dv)) _defaultView=p.dv;   // 사라진 탭(옛 skills 등)이 기본뷰로 남아 있으면 무시
}
// 부팅 시 1회 호출: 서버 prefs를 적용한 뒤 해시를 읽어 상태 변수와 렌더가 건드리지 않는 폼
// 컨트롤(뷰 셀렉트·완료 컷오프 입력)을 맞춘다. 상태 버튼의 활성 표시는 이후 updateFilterButtons로 동기화된다.
function restoreFromURL(){
  applyPrefs(_prefsInit);   // 서버 저장 레이아웃을 기본으로 깔고, 아래 해시가 있으면 덮어쓴다
  const h=(location.hash||'').replace(/^#/,'');
  let hashHasView=false;
  if(h){
    const q=new URLSearchParams(h);
    if(q.has('view')){ _view=q.get('view'); hashHasView=true; }
    if(q.has('st')){ const on=new Set(q.get('st').split(',').filter(Boolean));
      ['backlog','in_progress','done','cancelled'].forEach(k=>{ _statusFilter[k]=on.has(k); }); }
    _showParents=q.get('par')==='1';
    if(q.has('sp')) q.get('sp').split(',').filter(Boolean).forEach(function(x){ const v=parseInt(x,10); if(v>0) _sprintSel.add(v); });
    if(q.has('ty')){ _typeSel.clear(); q.get('ty').split(',').filter(Boolean).forEach(k=>{ if(TYPE_KEYS.includes(k)) _typeSel.add(k); }); }
    if(q.has('dc')) _doneSince=parseInt(q.get('dc'),10)||0;
    // 접기 상태 복원: 그룹 키는 숫자(루프 번호)면 Number로 되돌려 _spCollapsed.has(s.number)와 일치시킨다.
    if(q.has('spc')) q.get('spc').split(',').filter(Boolean).forEach(k=>_spCollapsed.add(/^\d+$/.test(k)?parseInt(k,10):k));
    if(q.has('bgc')) q.get('bgc').split(',').filter(Boolean).forEach(k=>_bgCollapsed.add(k));
  }
  // 명시적 URL 해시 뷰가 없으면, 사용자가 지정한 기본 보기(Set as default)로 연다.
  // 기본 보기가 없으면 서버가 주입한 마지막 보기(lastView)를 그대로 쓴다.
  if(!hashHasView && _defaultView) _view=_defaultView;
  // 'skills'·'agents'(레일 독립 오버레이)·'actions'·'history'(컨디션 관리 페이지로 이동)는 더 이상
  // 대시보드 탭이 아니다. 오래된 해시/저장값이 오면 기본 작업뷰로 보정.
  if(_view==='skills'||_view==='agents'||_view==='actions'||_view==='history') _view='input';
  // 'queue'는 chat(/goal-add)의 detail-큐로 완전히 이전 — 옛 북마크/저장값은 그 화면으로 보낸다.
  if(_view==='queue'){ location.replace('/goal-add?q=detail'); return; }
  renderTabs();
  const ds=$('flt_donesince'); if(ds) ds.value=_doneSince?localInput(_doneSince):'';
  _urlReady=true;
}
// --- Goal status + per-goal time tracking ---
// Multiple goals MAY run in_progress at once (only feasible with AI). The server banks
// elapsed time on every transition; trackedSeconds is the banked total, and while running
// we add the live session (now - startedAt) on the client so the clock ticks without
// re-rendering. The count of concurrent in_progress goals gates the AI-work inputs below.
const VGAIN='0.5';   // value units (v) awarded per completion — abstract value, NOT hours
// --- Concurrency-gated AI-work helpers (energy / agents / tokens / value / ROI) ---
// Energy/agent/token/value are managed at the PARENT (big-picture goal) level, NOT per
// leaf task — per-task entry was too costly/noisy. The unit of "concurrent work" is an
// ACTIVE PARENT: a parent whose rollup is on_track (some child is in progress). Thresholds:
// 1+ active parent -> agent/token/value/ROI; 2+ active parents -> energy split + gauge.
const CONC_ENERGY=2, CONC_AGENT=1;
// ROI = value / tokens(K). Tunable bands: >=HI efficient, >=LO acceptable, else token burn.
const ROI_HI=1.0, ROI_LO=0.4;
// A parent is "active" when its derived rollup is on_track (a child is in progress).
function activeParent(goals,g){ return derivedStatus(goals,g)==='on_track'; }
function concCount(goals){ return (goals||[]).filter(g=>activeParent(goals,g)).length; }
function energySum(goals){ return (goals||[]).filter(g=>activeParent(goals,g)).reduce((a,g)=>a+(g.energy||0),0); }
function roiOf(g){ return ((g.tokens||0)>0)?((g.value||0)/g.tokens):null; }
function roiClass(r){ return r==null?'':(r>=ROI_HI?'hi':(r>=ROI_LO?'mid':'lo')); }
function setEnergy(id,v){ post('/api/goal/energy',{id:id,energy:parseInt(v,10)||0}); }
function setAgents(id,s){ post('/api/goal/agents',{id:id,agents:String(s||'')}); }
function setTokens(id,v){ post('/api/goal/tokens',{id:id,tokens:parseInt(v,10)||0}); }
function setValue(id,v){ post('/api/goal/value',{id:id,value:parseInt(v,10)||0}); }
function setStatus(id,s,ev){
  // Completing a task is a value moment: play the check sweep + floating +Nv, then
  // commit. Value is in "v" (not hours) on purpose — rewarding hours just invites
  // filling time; v rewards finishing something worth finishing.
  if(s==='done'){ celebrateDone(id, ev&&ev.target?ev.target.closest('.goal'):null); return; }
  post('/api/goal/status',{id:id,status:s});
}
function celebrateDone(id,row){
  if(row && row.classList.contains('celebrate')) return;   // debounce double-clicks
  _evOpen.add(id);   // open the evidence panel so the just-finished goal invites a link/file
  playDing();
  if(row){
    row.classList.add('celebrate');
    const g=row.querySelector('.g'); if(g && !g.querySelector('.gstrike')){
      const st=document.createElement('span'); st.className='gstrike'; g.appendChild(st);
      requestAnimationFrame(()=>requestAnimationFrame(()=>st.classList.add('on')));
    }
    floatValue(row);
  }
  // Commit after the sweep is visible; the reload then settles the row to its done state.
  setTimeout(()=>post('/api/goal/status',{id:id,status:'done'}), 480);
}
// Cash-register "ka-ching" completion sound (Web Audio — no asset, offline):
// a drawer clack (band-passed noise burst) + a double metallic bell built from
// INHARMONIC partials (1 : 2.41 : 3.93 : 5.2 — non-integer ratios give the metal
// timbre). Played inside the click gesture so WebKit autoplay allows it; gentle
// gains so it sits over the focus BGM without spiking.
let _actx=null;
function _bell(c,t0,base,amp,dur){
  [1,2.41,3.93,5.2].forEach((r,i)=>{
    const o=c.createOscillator(), g=c.createGain();
    o.type='sine'; o.frequency.value=base*r; const a=amp/(i+1);
    g.gain.setValueAtTime(0.0001,t0);
    g.gain.exponentialRampToValueAtTime(a,t0+0.005);
    g.gain.exponentialRampToValueAtTime(0.0001,t0+dur);
    o.connect(g).connect(c.destination); o.start(t0); o.stop(t0+dur+0.02);
  });
}
function _clack(c,t0,freq,amp,dur){
  const n=Math.floor(c.sampleRate*dur), buf=c.createBuffer(1,n,c.sampleRate), d=buf.getChannelData(0);
  for(let i=0;i<n;i++) d[i]=Math.random()*2-1;
  const s=c.createBufferSource(); s.buffer=buf;
  const bp=c.createBiquadFilter(); bp.type='bandpass'; bp.frequency.value=freq; bp.Q.value=6;
  const g=c.createGain(); g.gain.setValueAtTime(amp,t0); g.gain.exponentialRampToValueAtTime(0.0001,t0+dur);
  s.connect(bp).connect(g).connect(c.destination); s.start(t0); s.stop(t0+dur);
}
function playDing(){
  try{
    // 효과음 게이트 — 음소거(⌃⌘M)거나 레일의 '효과음' 스위치가 꺼져 있으면 울리지 않는다.
    // 네이티브 이펙트음은 서버가 막지만 이건 페이지가 직접 만드는 Web Audio 소리라
    // 레일이 노출한 같은 판정을 여기서 읽는다(레일이 없는 페이지면 그대로 울린다).
    if(window.cmSfxSilenced && window.cmSfxSilenced()) return;
    // Duck the native BGM under the effect (fire-and-forget; ignore if server busy).
    fetch('/api/duck',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}).catch(()=>{});
    const AC=window.AudioContext||window.webkitAudioContext; if(!AC) return;
    _actx=_actx||new AC(); if(_actx.state==='suspended') _actx.resume();
    const t=_actx.currentTime+0.01;
    _clack(_actx,t,1500,0.22,0.05);        // drawer clack
    _bell(_actx,t+0.05,1318.5,0.14,0.5);   // ching (E6)
    _bell(_actx,t+0.10,1760.0,0.12,0.6);   // ching (A6)
  }catch(e){}
}
function floatValue(row){
  const r=row.getBoundingClientRect();
  const v=document.createElement('div'); v.className='vfloat'; v.textContent='+'+VGAIN+'v';
  v.style.left=(r.left+58)+'px'; v.style.top=(r.top+4)+'px';
  document.body.appendChild(v);
  requestAnimationFrame(()=>requestAnimationFrame(()=>{ v.style.opacity='1'; v.style.transform='translateY(-34px)'; }));
  setTimeout(()=>{ v.style.opacity='0'; }, 650);
  setTimeout(()=>{ v.remove(); }, 1100);
}
function statBtn(g,val,label){ const on=(g.status||'backlog')===val;
  return '<button class="sb'+(on?(' on '+val):'')+'" onclick="setStatus(\''+g.id+'\',\''+val+'\',event)">'+label+'</button>'; }
// Leaf-goal status picker. Six statuses (대기·진행·응답 대기·중지·취소·완료) are too many for
// inline buttons, so a single combobox carries them. waiting is normally auto-set by the
// session hooks, but kept selectable for manual override. setStatus still routes 완료 through
// the celebration path. Parent goals use a derived rollup (statLabel), not this picker.
const STATUS_OPTS=[['backlog','대기'],['in_progress','진행'],['waiting','응답 대기'],['stopped','중지'],['cancelled','취소'],['done','완료']];
function statSel(g){
  const cur=g.status||'backlog';
  const opts=STATUS_OPTS.map(o=>'<option value="'+o[0]+'"'+(o[0]===cur?' selected':'')+'>'+o[1]+'</option>').join('');
  return '<select class="statsel '+cur+'" title="상태 변경" onchange="setStatus(\''+g.id+'\',this.value,event)">'+opts+'</select>';
}
// Board variant: same picker, but the row is draggable="true" so plain mousedown on a
// <select> would start a drag instead of opening the dropdown. ondragstart/onmousedown
// guards let the combobox work while leaving the rest of the row draggable.
function statSelBoard(g){
  const cur=g.status||'backlog';
  const opts=STATUS_OPTS.map(o=>'<option value="'+o[0]+'"'+(o[0]===cur?' selected':'')+'>'+o[1]+'</option>').join('');
  return '<select class="statsel '+cur+'" title="상태 변경" ondragstart="return false"'
    +' onmousedown="event.stopPropagation()" onclick="event.stopPropagation()"'
    +' onchange="setStatus(\''+g.id+'\',this.value,event)">'+opts+'</select>';
}
// Children of a goal (1-level hierarchy: only top-level goals can be parents).
function goalKids(goals,g){ return (goals||[]).filter(c=>c.parent===g.id); }
// Derived parent status (rollup from children). null = leaf (use manual buttons).
//   on_track : at least one child is in_progress -> the big-picture goal is being worked on
//   done     : every child is done
//   backlog  : has children but none in progress yet
// Purpose: managers see which parent goal is active (on track) while workers freely
// manage the leaf tasks underneath. Derived every render, so a child going 진행
// flips the parent to on track automatically (no stored/duplicated state).
// Parent rollup. Manual done wins. A parent with NO remaining tasks — every child terminal
// (완료/취소) and at least one actually 완료 — rolls up to done automatically, so the finished
// branch drops out of the board with its children (완료 필터/컷오프가 함께 숨긴다). Derived
// every render: adding a new task under a done parent revives it. Otherwise any activity
// (a child in progress, or some child done) reads as On Track; otherwise 대기.
function derivedStatus(goals,g){
  const kids=goalKids(goals,g); if(!kids.length) return null;
  // 수동 완료(done) 부모라도 아직 안 끝난(대기/진행/응답대기/중지) 자식이 남아 있으면 On Track
  // 으로 부활한다 — 완료된 부모 아래에 새 과제를 붙이면 다시 진행 상태로 보드에 나오게(위 주석의
  // 의도). 자식이 전부 종료(완료/취소)면 done 유지.
  if((g.status||'')==='done'){
    const live=kids.some(c=>{ const s=c.status||'backlog'; return s!=='done'&&s!=='cancelled'; });
    return live?'on_track':'done';
  }
  if(kids.some(c=>(c.status||'backlog')==='in_progress')) return 'on_track';
  const dn=kids.filter(c=>(c.status||'backlog')==='done').length;
  const term=kids.filter(c=>{ const s=c.status||'backlog'; return s==='done'||s==='cancelled'; }).length;
  if(dn>0 && term===kids.length) return 'done';   // 남은 task 없음 → 자동 완료
  if(dn>0) return 'on_track';
  return 'backlog';
}
function statLabel(s){ return s==='on_track'?'On Track':(s==='done'?'완료':'대기'); }
function effTracked(g){ const base=g.trackedSeconds||0;
  return (g.startedAt&&g.startedAt>0)?(base+Math.max(0,(Date.now()/1000)-g.startedAt)):base; }
function fmtDur(sec){ sec=Math.max(0,Math.floor(sec)); const h=(sec/3600)|0,m=((sec%3600)/60)|0,s=sec%60,p=n=>(n<10?'0':'')+n;
  return (h>0?(h+':'+p(m)):m)+':'+p(s); }
// Live wait duration (seconds since waitingSince). DISPLAY-ONLY — never folded into
// effTracked, so the work clock stays frozen while this ticks up. 0 = not waiting.
function waitSecs(g){ return (g.waitingSince&&g.waitingSince>0)?Math.max(0,(Date.now()/1000)-g.waitingSince):0; }
function wbadgeHTML(g){ if((g.status||'')!=='waiting') return '';
  return '<span class="wbadge" id="tw_'+g.id+'" title="사람의 응답을 기다린 시간 — 작업 시간(왼쪽)에는 포함되지 않음">⏳ 응답 대기 '+fmtDur(waitSecs(g))+'</span>'; }
function tickTimers(){ (_goals||[]).forEach(g=>{
  const el=document.getElementById('tt_'+g.id); if(el) el.textContent=fmtDur(effTracked(g));
  const w=document.getElementById('tw_'+g.id); if(w) w.textContent='⏳ 응답 대기 '+fmtDur(waitSecs(g));
}); }
setInterval(tickTimers,1000);
// Set parent by typing the parent's number (1-based). Empty clears it.
let _goals=[];
// --- Drag-and-drop priority reorder (decide what to focus on) ---
let _dragFrom=null;
function dragStart(e,i){ _dragFrom=i; e.dataTransfer.effectAllowed='move'; try{e.dataTransfer.setData('text/plain',String(i));}catch(_){}
  const row=e.target.closest('.goal'); if(row)row.classList.add('dragging'); }
function dragEnd(e){ _dragFrom=null; document.querySelectorAll('.goal').forEach(el=>el.classList.remove('dragging','dropTarget')); }
function dragOver(e,i){ if(_dragFrom===null)return; e.preventDefault(); e.dataTransfer.dropEffect='move';
  if(i!==_dragFrom){ const row=e.currentTarget; if(row){document.querySelectorAll('.goal.dropTarget').forEach(el=>el.classList.remove('dropTarget')); row.classList.add('dropTarget');} } }
function dragLeave(e){ e.currentTarget.classList.remove('dropTarget'); }
function dropOn(e,i){ e.preventDefault();
  const from=_dragFrom; _dragFrom=null;
  document.querySelectorAll('.goal').forEach(el=>el.classList.remove('dragging','dropTarget'));
  if(from===null||from===i)return;
  const ids=_goals.map(g=>g.id);
  if(from<0||from>=ids.length)return;
  const moved=ids.splice(from,1)[0]; ids.splice(i,0,moved);
  post('/api/goal/reorder',{order:ids});
}
function setParentByNumber(id,numStr){
  const s=(numStr||'').trim();
  if(!s){ post('/api/goal/parent',{id:id,parent:''}); return; }
  const n=parseInt(s.replace(/[^0-9]/g,''),10);   // accept "goal-01", "01", or "1"
  let tgt=_goals.find(g=>g.seq===n)||null;   // match by stable seq, not position
  if(!tgt){ load(); return; }   // 없는 번호 -> 표시 되돌림
  // 하위 과제 번호(예: 완료된 #240이 goal-1의 하위)를 입력하면 그 최상위 조상 아래로 붙인다.
  // 앱은 1단계 트리만 허용하므로 서브를 부모로 쓰면 되돌아가 버린다 — 조상까지 걸어 올라가
  // 그룹(최상위)에 부착한다. 순환은 seen 으로 막고, 부모가 목록에 없으면 거기서 멈춘다.
  const seen=new Set();
  while(tgt&&tgt.parent&&!seen.has(tgt.id)){ seen.add(tgt.id); const up=byId(_goals,tgt.parent); if(!up) break; tgt=up; }
  if(!tgt||tgt.id===id){ load(); return; }   // 자기 자신/해석 불가 -> 되돌림
  post('/api/goal/parent',{id:id,parent:tgt.id});
}
function num2(i){ return (i<9?'0':'')+(i+1); }
// Stable per-goal id label (goal-NN, seq zero-padded). Assigned at creation and
// UNCHANGED by reorder — drag only moves position, the label stays with the goal.
function gnum(g){ const n=g.seq||0; return 'goal-'+(n<10?'0':'')+n; }
// Clickable goal number: navigates to /goal?n=NN (정의 + 첨부) in the same tab.
// Unnumbered goals (seq 0) render as a plain, non-clickable pill. stopPropagation so
// clicking the number never triggers the row's own click handlers.
function gpill(g){ const n=g.seq||0; const t=gnum(g);
  if(n<=0) return '<span class="pill" style="font-variant-numeric:tabular-nums">'+t+'</span>';
  return '<a class="pill gp" href="/goal?n='+n+'" title="골 페이지 — 정의·첨부 보기" style="font-variant-numeric:tabular-nums" onclick="event.stopPropagation()">'+t+'</a>'; }
// Link indicator: shown ONLY on a SOURCE goal that links out (g.links non-empty). Reuses
// the .pill visual (same chip family as gpill), tinted with the accent so it reads as a
// small dot/badge. Hover lists the linked targets as goal-NN. Display stays flat — the
// link is a directional export hint, not a nesting. See docs/specs/goal-link-and-generic-queue.md.
function linkDot(g){
  const ids=(g&&g.links)||[]; if(!ids.length) return '';
  const labs=ids.map(function(id){ const t=byId(_goals,id); return t?('goal-'+pad2(t.seq||0)):id; });
  return '<span class="pill lkdot" title="링크됨: '+esc(labs.join(', '))+'" style="color:var(--accent);border-color:var(--accent)">🔗'+(ids.length>1?(' '+ids.length):'')+'</span>';
}
// Session-link icon for a goal row. Connected -> bright chain that opens the readable
// transcript; not connected -> dim broken chain that opens the native connect picker.
function slinkBtn(g){
  if(g.sessionId){
    return '<button class="slink on" title="세션 트랜스크립트 보기" onclick="viewSession(event,\''+g.id+'\')">🔗</button>';
  }
  return '<button class="slink off" title="세션 연결 (파일 선택)" onclick="connectSession(event,\''+g.id+'\')">⛓️‍💥</button>';
}
function viewSession(e,id){ if(e){e.stopPropagation();} window.open('/transcript?goal='+encodeURIComponent(id),'_blank'); }
// The accumulated-time cell. For a session-linked goal it becomes a clickable link
// to the minute-by-minute breakdown (tools + tokens); otherwise it's a plain readout.
function ttimeHTML(g){
  const on=!!g.sessionId;
  const attr=on?(' onclick="viewBreakdown(event,\''+g.id+'\')" title="분 단위 작업·토큰 보기"'):' title="누적 작업 시간"';
  return '<span class="ttime'+(on?' clk':'')+'" id="tt_'+g.id+'"'+attr+'>'+fmtDur(effTracked(g))+'</span>';
}
function viewBreakdown(e,id){ if(e){e.stopPropagation();} window.open('/breakdown?goal='+encodeURIComponent(id),'_blank'); }
function connectSession(e,id){ if(e){e.stopPropagation();}
  // The picker is a native modal opened by the app; the POST returns immediately, so
  // reload a few times to catch the link once the user has chosen a file.
  post('/api/goal/connect',{id:id});
  [1500,4000,8000].forEach(function(ms){ setTimeout(load,ms); });
}

let _view='\#(view)', _md='';   // server-injected: the view the app last had open
function pad2(n){ return (n<10?'0':'')+n; }

// ===== 뷰 탭바 (콤보박스를 Jira식 탭으로 펼침) =====
// 각 뷰는 하나의 탭. 탭 순서(_tabOrder)와 기본 보기(_defaultView)는 savePrefs로 서버에
// 저장되어 앱을 껐다 켜도 그대로 복원된다. ⋯ 메뉴로 기본 지정·좌우 이동을 한다.
const VIEW_DEFS=[
  {k:'input',t:'목록'},{k:'group',t:'그룹'},{k:'table',t:'테이블'},
  {k:'token',t:'토큰'},{k:'schedule',t:'일정'},{k:'preview',t:'리포트'},
  {k:'sprint',t:'루프'},{k:'archived',t:'아카이브'},{k:'hero',t:'Hero'}
  // 큐는 더 이상 대시보드 탭이 아니다 — chat(/goal-add)의 detail-큐로 완전히 이전 (QueuePanel.swift).
  // 탭바 우측 큐 상태 노티(qNoti)가 /goal-add?q=detail 로 안내한다. 옛 'queue' 해시/저장값은
  // restoreFromURL이 그 주소로 리다이렉트한다.
  // 액션로그·히스토리는 더 이상 대시보드 탭이 아니다 — 컨디션 관리 페이지(/bgm-player)의 서브탭으로 이동
  // (컨디션맵·오늘 활동과 한곳에서 분석). normTabOrder가 저장된 옛 'actions'·'history' 키를 걸러낸다.
  // 에이전트는 더 이상 대시보드 탭이 아니다 — 레일의 '위임' 메뉴가 소유하는 독립 오버레이(SessionRail cmNav('delegate')).
  // 워커(백그라운드/주기 작업)도 대시보드에서 분리됐다 — 레일의 '크론' 메뉴가 독립 페이지 /cron 을 연다.
];
const VIEW_LABEL={}; VIEW_DEFS.forEach(d=>{ VIEW_LABEL[d.k]=d.t; });
const VIEW_KEYS=VIEW_DEFS.map(d=>d.k);
let _tabOrder=VIEW_KEYS.slice();   // 사용자가 좌우로 옮긴 순서
let _defaultView='';               // 'Set as default' — 비어 있으면 마지막 보기(lastView)로 연다
// 저장된 순서에 빠진/잘못된 키를 보정: 알 수 없는 키는 버리고, 빠진 표준 키는 뒤에 채운다.
function normTabOrder(){
  _tabOrder=_tabOrder.filter(k=>VIEW_KEYS.includes(k));
  VIEW_KEYS.forEach(k=>{ if(!_tabOrder.includes(k)) _tabOrder.push(k); });
}
function renderTabs(){
  const host=$('viewTabs'); if(!host) return;
  normTabOrder();
  host.innerHTML=_tabOrder.map(function(k){
    const act=(k===_view)?' active':'';
    const def=(k===_defaultView)?'<span class="vdef" title="기본 보기">●</span>':'';
    return '<button class="vtab'+act+'" data-k="'+k+'" onclick="setView(\''+k+'\')">'
      +'<span>'+VIEW_LABEL[k]+'</span>'+def
      +'<span class="vdots" title="탭 설정" onclick="openTabMenu(event,\''+k+'\')">⋯</span>'
      +'</button>';
  }).join('')
  // 탭바 우측 AI 큐 상태 노티 — innerHTML 재생성으로 사라지므로 매번 스켈레톤을 함께 그리고 채운다.
  // 큐 UI는 chat(/goal-add)의 큐 목록(행 펼침 검토)으로 이전됐으므로 클릭은 그 화면으로 이동한다
  // (?q=detail: 미확정 행을 모두 펼치고 큐 히스토리를 연 상태로 진입).
  +'<button class="vnoti" id="qNoti" onclick="location.href=\'/goal-add?q=detail\'" title="큐(chat)로 이동 — 담긴 항목을 펼쳐 검토·확정합니다">'
  +'<span class="nd"></span><span class="nt"></span><span class="narr">→</span></button>';
  updateQueueNoti(_lastAiQueue);
}
// 폴링 재렌더(5초)마다 탭바를 통째로 다시 그리지 않고 활성 표시만 갱신 — 열린 ⋯ 메뉴 보존.
function markActiveTab(){
  const host=$('viewTabs'); if(!host) return;
  [...host.querySelectorAll('.vtab')].forEach(b=>b.classList.toggle('active', b.dataset.k===_view));
}
// 탭바 우측 AI 큐 상태 노티 — enqueue 직후엔 '큐 실행 중 N건'(액센트 펄스), 분석이 끝나면
// '검토 대기 N건'(보라)으로 바뀐다. 클릭하면 chat의 detail-큐로 이동한다(큐 UI 이전 후 대시보드에
// 남은 유일한 큐 신호). 리스트/보드에 큐 박스를 끼워 넣지 않아도 "지금 큐가 돌고 있다"는 걸
// 어느 뷰에서든 알 수 있게 하는 것이 목적.
function updateQueueNoti(items){
  const n=$('qNoti'); if(!n) return;
  const list=items||[];
  const running=list.filter(it=>it.status==='analyzing'||it.status==='pending'||it.status==='running').length;
  const ready=list.filter(function(it){
    const kind=it.jobKind||'dedup';
    if(kind==='dedup') return !it.status||it.status==='ready';   // 리뷰 대기
    return it.status==='ready';                                   // 잡: 완료/오류
  }).length;
  n.classList.remove('run','ready');
  if((running+ready)===0){ n.style.display='none'; return; }
  n.style.display='inline-flex';
  const t=n.querySelector('.nt'); if(!t) return;
  if(ready>0){ n.classList.add('ready'); t.textContent='🤖 검토 대기 '+ready+'건'+(running?' · 실행 중 '+running:''); }
  else{ n.classList.add('run'); t.textContent='🤖 큐 실행 중 '+running+'건'; }
}
function openTabMenu(e,k){
  e.stopPropagation();   // 탭 자체의 setView가 같이 발동하지 않게
  const idx=_tabOrder.indexOf(k), isDef=(k===_defaultView);
  let h='<div class="ckmenu"><div class="pophdr">'+VIEW_LABEL[k]+' 탭</div>';
  h+='<button class="popitem" onclick="tabSetDefault(\''+k+'\')">'+(isDef?'기본 보기 해제':'기본 보기로 설정')+'</button>';
  h+='<div class="popdiv"></div>';
  h+='<button class="popitem"'+(idx<=0?' disabled':'')+' onclick="tabMove(\''+k+'\',-1)">왼쪽으로 이동</button>';
  h+='<button class="popitem"'+(idx>=_tabOrder.length-1?' disabled':'')+' onclick="tabMove(\''+k+'\',1)">오른쪽으로 이동</button>';
  h+='</div>';
  const r=e.currentTarget.getBoundingClientRect();
  showPopup(r.left, r.bottom+4, h);
}
function tabMove(k,dir){
  const i=_tabOrder.indexOf(k), j=i+dir;
  if(i<0||j<0||j>=_tabOrder.length) return;
  const tmp=_tabOrder[i]; _tabOrder[i]=_tabOrder[j]; _tabOrder[j]=tmp;
  renderTabs(); savePrefs(); hidePopup();   // 위치가 바뀌므로 메뉴는 닫는다
}
function tabSetDefault(k){
  _defaultView=(_defaultView===k)?'':k;
  renderTabs(); savePrefs(); hidePopup();
}

// Persist the chosen view server-side (Settings file store) so the next launch reopens here.
// A URL hash (bookmark/refresh) still wins over this on load — see restoreFromURL.
function setView(v){ _view=v; if(_review) fillActiveView(_review); applyView(); syncURL(); post('/api/prefs/view',{view:v});
  updateQueueNoti(_lastAiQueue);   // 뷰 전환 시 노티를 즉시 갱신
}
function applyView(){
  const inp=$('inputView'), pv=$('previewView'), gv=$('groupView'), sv=$('scheduleView'), tv=$('tableView'), tkv=$('tokenView'), spv=$('sprintView'), av=$('archivedView'), hv=$('heroView');
  inp.style.display=(_view==='input')?'':'none';
  gv.style.display =(_view==='group')?'':'none';
  sv.style.display =(_view==='schedule')?'':'none';
  tv.style.display =(_view==='table')?'':'none';
  tkv.style.display=(_view==='token')?'':'none';
  spv.style.display=(_view==='sprint')?'':'none';
  av.style.display =(_view==='archived')?'':'none';
  hv.style.display =(_view==='hero')?'':'none';
  pv.style.display =(_view==='preview')?'':'none';
  if(_view==='preview') initReportFilter();   // 리포트 기간 필터를 최초 진입 시 마운트
  if(_view==='hero') heroLoad();              // Hero 탭은 진입 시 heroes.db를 읽는다(1회 캐시)
  // Page view (컨디션): in-flow panel below the tab bar instead of the goal panel.
  // 스킬·에이전트는 더 이상 대시보드 탭이 아니라 레일이 소유하는 독립 오버레이다
  // (SessionRail cmNav('skills') / cmNav('delegate') 참고).
  const isPage=(_view==='condition');
  const gp=$('goalPanel'); if(gp) gp.style.display=isPage?'none':'';
  markActiveTab();
}
// 에이전트 오버레이(cmAgOverlay)는 더 이상 대시보드 컨텐츠로 재부모화하지 않는다.
// 스킬 오버레이(cmSkOverlay)와 마찬가지로 레일이 소유하는 독립 오버레이로 남긴다
// (레일 '위임' 메뉴 → cmAgentsOpen). 대시보드 탭 의존성 제거.
// Fill ONLY the active view's input DOM. 목록/그룹 render the same goals with the same
// element ids (tt_<id>, ev_<id>) for live timers and evidence panels, so keeping both
// in the DOM at once would collide. We blank the inactive one and render the active one.
function fillActiveView(r){
  if(_view==='group'){ $('goals').innerHTML=''; $('scheduleSections').innerHTML=''; $('tableHost').innerHTML=''; renderGroupSections(r); }
  else if(_view==='input'){ $('groupSections').innerHTML=''; $('scheduleSections').innerHTML=''; $('tableHost').innerHTML=''; renderGoalsInput(r); }
  else if(_view==='schedule'){ $('goals').innerHTML=''; $('groupSections').innerHTML=''; $('tableHost').innerHTML=''; renderSchedule(r); }
  else if(_view==='table'){ $('goals').innerHTML=''; $('groupSections').innerHTML=''; $('scheduleSections').innerHTML=''; $('tableHost').innerHTML=''; renderTable(r); }
  else if(_view==='token'){ $('goals').innerHTML=''; $('groupSections').innerHTML=''; $('scheduleSections').innerHTML=''; $('tableHost').innerHTML=''; renderTokenView(r); }
  else if(_view==='sprint'){ $('goals').innerHTML=''; $('groupSections').innerHTML=''; $('scheduleSections').innerHTML=''; $('tableHost').innerHTML=''; renderSprintView(r); }
  else if(_view==='archived'){ $('goals').innerHTML=''; $('groupSections').innerHTML=''; $('scheduleSections').innerHTML=''; $('tableHost').innerHTML=''; renderArchivedView(r); }
  else { $('goals').innerHTML=''; $('groupSections').innerHTML=''; $('scheduleSections').innerHTML=''; $('tableHost').innerHTML=''; }   // preview: report only
}

// ===== Hero 뷰 (팀 칭찬 기록 — 읽기 전용) =====
// GET /api/hero/list 는 두 소스를 머지해서 준다 (HeroStore.swift):
//   source:'slack' — Slack #hero 채널 원문 (slack-eyes 데몬이 백필·실시간 수집).
//                    parsed:false면 구조화 실패 → 원문만 있는 항목.
//   source:'db'    — Claude Code /hero 스킬의 heroes.db 엔트리.
// 이 팀의 칭찬 문화: 디테일 없는 칭찬은 조롱이며, 바로 다음 단계(next todo)가 없으면 성장이
// 멈춘다 — 그래서 카드에서 next todo를 항상 강조해 보여준다. 기록은 /hero 스킬이 담당하고,
// 이 탭은 리더보드(셀프 모티베이션)·훑어보기·표준 포맷 복사만 맡는다.
let _heroEntries=[];
let _heroPeriod='all';      // all | quarter | month
let _heroRaw=false;         // 미파싱 원문 섹션 펼침 여부
function heroEsc(s){ return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
// 표준 칭찬 포맷 — 스킬(hero_db.py)의 format_entry와 같은 모양을 유지한다.
function heroFormat(e){
  const kr=e.nominee_korean?(' ('+e.nominee_korean+')'):'';
  let body=e.skill+' (lv'+e.level+') / '+e.reason+' / next todo: '+e.next_todo;
  if(e.next_level_goal) body+=' (next level: '+e.next_level_goal+')';
  return '['+(e.no||'')+'] @'+e.nominee+kr+'\n'+body;
}
function heroFlash(btn){ const t=btn.textContent; btn.textContent='복사됨'; setTimeout(function(){btn.textContent=t;},1200); }
function heroCopy(key,btn){
  const e=_heroEntries.find(function(x){return x.key===key;}); if(!e) return;
  navigator.clipboard.writeText(e.parsed?heroFormat(e):e.text).then(function(){heroFlash(btn);});
}
function heroCopyAll(btn){
  const list=heroInPeriod().filter(function(e){return e.parsed;});
  if(!list.length) return;
  const txt=list.slice().reverse().map(heroFormat).join('\n\n---\n\n');
  navigator.clipboard.writeText(txt).then(function(){heroFlash(btn);});
}
// 기간 필터 — 표시 타임존 벽시계 기준(CMTimeFilter). raw Date getter를 쓰지 않는다.
function heroInPeriod(){
  if(_heroPeriod==='all') return _heroEntries;
  const now=CMTimeFilter.parts(Date.now());
  const q=Math.floor((now.mo-1)/3);
  return _heroEntries.filter(function(e){
    if(!e.at) return false;
    const p=CMTimeFilter.parts(e.at*1000);
    if(p.y!==now.y) return false;
    if(_heroPeriod==='month') return p.mo===now.mo;
    return Math.floor((p.mo-1)/3)===q;
  });
}
function heroSetPeriod(k){ _heroPeriod=k; renderHeroView(); }
function heroToggleRaw(){ _heroRaw=!_heroRaw; renderHeroView(); }
function heroLoad(force){
  const host=$('heroHost'); if(!host) return;
  if(_heroEntries.length && !force) return;   // 탭 재진입 시 재요청하지 않음 — 새로고침 버튼으로 갱신
  fetch('/api/hero/list').then(function(r){return r.json();})
    .then(function(d){ _heroEntries=(d&&d.entries)||[]; _heroMeta=d||{}; renderHeroView(); })
    .catch(function(){ host.innerHTML='<div class="empty">칭찬 기록을 불러오지 못했습니다.</div>'; });
}
let _heroMeta={};
// 리더보드 — 셀프 모티베이션용. 사람별 누적 횟수와 스킬별 최고 레벨을 보여준다.
// 순위 색은 신호등(빨강/녹색) 금지 규칙에 따라 강조 = 액센트 굵기로만 준다.
function heroLeaderboard(list){
  const by={};
  list.forEach(function(e){
    if(!e.parsed || !e.nominee) return;
    const k=e.nominee;
    if(!by[k]) by[k]={n:0, kr:e.nominee_korean||'', best:{}, last:0};
    by[k].n++;
    if(e.at>by[k].last) by[k].last=e.at;
    if(e.skill) by[k].best[e.skill]=Math.max(by[k].best[e.skill]||0, e.level||0);
    if(!by[k].kr && e.nominee_korean) by[k].kr=e.nominee_korean;
  });
  const names=Object.keys(by).sort(function(a,b){ return by[b].n-by[a].n || by[b].last-by[a].last; });
  if(!names.length) return '';
  const top=by[names[0]].n;
  return '<div class="hero-lb">'
    +names.map(function(k,i){
      const v=by[k];
      const skills=Object.keys(v.best).sort(function(a,b){return v.best[b]-v.best[a];}).slice(0,3)
        .map(function(s){return '<span class="hero-skill">'+heroEsc(s)+' lv'+v.best[s]+'</span>';}).join(' ');
      const pct=top?Math.round(v.n*100/top):0;
      return '<div class="hero-lbrow">'
        +'<span class="hero-rank">'+(i+1)+'</span>'
        +'<span class="hero-lbname"><b>'+heroEsc(k)+'</b>'
        +(v.kr?(' <span class="muted">('+heroEsc(v.kr)+')</span>'):'')+'</span>'
        +'<span class="hero-bar"><i style="width:'+pct+'%"></i></span>'
        +'<span class="hero-lbn">'+v.n+'회</span>'
        +'<span class="hero-lbskills">'+skills+'</span>'
        +'</div>';
    }).join('')
    +'</div>';
}
function renderHeroView(){
  const host=$('heroHost'); if(!host) return;
  if(!_heroEntries.length){
    host.innerHTML='<div class="empty">아직 칭찬 기록이 없습니다.'
      +'<div style="margin-top:6px">Slack <b>#hero</b> 채널 수집은 slack-eyes 데몬이, 직접 기록은 Claude Code의 <b>/hero</b> 스킬이 담당합니다.</div>'
      +'<div style="margin-top:6px;font-size:11px;color:var(--mut)">'+heroEsc(_heroMeta.slack||'')+'</div></div>';
    return;
  }
  const list=heroInPeriod();
  const parsed=list.filter(function(e){return e.parsed;});
  const raw=list.filter(function(e){return !e.parsed;});
  const seg=[['all','전체'],['quarter','이번 분기'],['month','이번 달']]
    .map(function(p){ return '<button class="btn'+(_heroPeriod===p[0]?' on':'')+'" onclick="heroSetPeriod(\''+p[0]+'\')">'+p[1]+'</button>'; }).join('');
  let h='<div class="row" style="margin:0 0 10px;align-items:center;gap:6px">'
    +seg
    +'<span class="muted" style="font-size:12px;margin-left:6px">칭찬 '+parsed.length+'건'
    +(raw.length?(' · 미분류 '+raw.length+'건'):'')
    +' · Slack #hero + /hero 스킬</span>'
    +'<span style="flex:1"></span>'
    +'<button class="btn" onclick="heroCopyAll(this)" title="이 기간의 엔트리를 표준 포맷으로 복사">전체 복사</button>'
    +'<button class="btn" onclick="heroLoad(true)" title="다시 읽기">새로고침</button>'
    +'</div>'
    +heroLeaderboard(parsed);
  h+=parsed.map(function(e){
    const kr=e.nominee_korean?(' <span class="muted">('+heroEsc(e.nominee_korean)+')</span>'):'';
    const nx=e.next_level_goal?('<div class="hero-next2">next level: '+heroEsc(e.next_level_goal)+'</div>'):'';
    const no=e.no?('<span class="hero-no">['+e.no+']</span>'):'';
    const src=e.source==='slack'
      ? (e.permalink?('<a class="hero-src" href="'+heroEsc(e.permalink)+'" target="_blank" title="슬랙 원문 열기">#hero</a>'):'<span class="hero-src">#hero</span>')
      : '<span class="hero-src">/hero</span>';
    return '<div class="hero-card">'
      +'<div class="row" style="align-items:baseline;gap:8px;flex-wrap:wrap">'
      +no
      +'<b>@'+heroEsc(e.nominee)+'</b>'+kr
      +(e.skill?('<span class="hero-skill">'+heroEsc(e.skill)+' lv'+e.level+'</span>'):'')
      +'<span style="flex:1"></span>'+src
      +'<span class="muted" style="font-size:11px">'+heroEsc(e.created_at)+(e.nominator?(' · by '+heroEsc(e.nominator)):'')+'</span>'
      +'<button class="btn" style="font-size:11px;padding:2px 8px" onclick="heroCopy(\''+heroEsc(e.key)+'\',this)" title="이 엔트리를 표준 포맷으로 복사">복사</button>'
      +'</div>'
      +'<div class="hero-reason">'+heroEsc(e.reason)+'</div>'
      +(e.next_todo?('<div class="hero-next"><b>next todo</b> · '+heroEsc(e.next_todo)+'</div>'):'')
      +nx
      +'</div>';
  }).join('');
  // 구조화하지 못한 메시지는 버리지 않고 접어서 남긴다 — 파서 보정의 재료이자
  // 채널 맥락(축하 코멘트 등)이라 목록에서 사라지면 안 된다.
  if(raw.length){
    h+='<div class="hero-rawbox"><div class="hero-rawhead" onclick="heroToggleRaw()">'
      +(_heroRaw?'▾':'▸')+' 칭찬 포맷이 아닌 메시지 '+raw.length+'건</div>';
    if(_heroRaw) h+=raw.map(function(e){
      const src=e.permalink?('<a class="hero-src" href="'+heroEsc(e.permalink)+'" target="_blank">원문</a>'):'';
      return '<div class="hero-rawitem"><span class="muted" style="font-size:11px">'+heroEsc(e.created_at)
        +(e.nominator?(' · '+heroEsc(e.nominator)):'')+'</span> '+src
        +'<div>'+heroEsc(e.text)+'</div></div>';
    }).join('');
    h+='</div>';
  }
  host.innerHTML=h;
}
// ===== Group-mode input: sticky add bar (active parent) + collapsible parent sections =====
let _activeParent='';        // active parent goal id ('' = new top-level)
let _gCollapsed=new Set();    // collapsed parent ids
let _gSeen=new Set();         // parents already defaulted-collapsed (so the 5s re-render never re-collapses one the user opened)
let _gQuery='';              // section search filter (lowercased)
// IME-safe Enter binding (Korean composition; same rationale as goalKey). Reusable so
// the top add bar and every per-section add box commit only on a fully-composed Enter.
function bindImeEnter(el, fn){
  if(!el || el._imeBound) return; el._imeBound=true;
  let composing=false, pending=false;
  el.addEventListener('compositionstart',function(){composing=true;});
  el.addEventListener('compositionend',function(){composing=false; if(pending){pending=false; fn(el);}});
  el.addEventListener('keydown',function(e){ if(e.key!=='Enter')return; if(composing){pending=true;} else { fn(el); } });
}
// Resolve the active parent from the picker text ("goal-03", "03", "3", or empty).
function gPickParent(val){
  const s=(val||'').trim();
  if(!s){ _activeParent=''; return; }
  const n=parseInt(s.replace(/[^0-9]/g,''),10);
  const tgt=(_goals||[]).find(g=>g.seq===n && !g.parent);   // parent must be top-level
  _activeParent=tgt?tgt.id:'';
}
// Set the active parent from a section header (+여기에) and reflect it in the picker.
function gSetActiveParent(id){
  _activeParent=id||'';
  const g=(_goals||[]).find(x=>x.id===id);
  const el=$('gParentPick'); if(el) el.value=g?('goal-'+pad2(g.seq||0)):'';
}
function gAdd(){
  const el=$('gAddText'); if(!el) return;
  const t=el.value.trim(); if(!t) return;
  el.value=''; el.focus();
  post('/api/goal/add',{text:t,parent:_activeParent});
}
// Add a child directly under a parent (section add box). The section re-renders on
// reload (new input element), so we flag the parent to restore focus after render —
// enabling rapid Enter-Enter entry straight into a section.
let _gRefocus='';
function gAddChild(parentId, inputEl){
  const t=inputEl.value.trim(); if(!t) return;
  inputEl.value=''; _gRefocus=parentId;
  post('/api/goal/add',{text:t,parent:parentId});
}
function gSectAdd(parentId, btn){ const inp=btn.parentNode.querySelector('input'); if(inp) gAddChild(parentId,inp); }
function gToggleSec(id){ if(_gCollapsed.has(id))_gCollapsed.delete(id); else _gCollapsed.add(id);
  const el=document.getElementById('gsec_'+id); if(el) el.classList.toggle('collapsed', _gCollapsed.has(id)); savePrefs(); }
function gCollapseAll(c){ const tops=(_goals||[]).filter(g=>!g.parent);
  _gCollapsed = c ? new Set(tops.map(g=>g.id)) : new Set();
  if(_review) renderGroupSections(_review); savePrefs(); }
function gSetQuery(q){ _gQuery=(q||'').toLowerCase(); if(_review) renderGroupSections(_review); }
// --- Group-view drag priority -------------------------------------------------
// Two independent reorders share the existing /api/goal/reorder endpoint (which takes a
// FULL ordered id list): dragging a section header reprioritises the parent goals, and
// dragging a child grip reorders tasks within one parent. gBuildOrder rebuilds the whole
// id list from a parent order, keeping each parent immediately followed by its children,
// so a single drop never disturbs the rest of the tree. childOverride supplies a new child
// order for one parent (used by child drags). The trailing sweep appends any goal not yet
// placed — a safety net so reorderGoals' count check can never reject the payload.
function gBuildOrder(parentOrder, childOverride){
  const out=[]; childOverride=childOverride||{};
  parentOrder.forEach(p=>{ out.push(p);
    const kids=childOverride[p]||_goals.filter(g=>g.parent===p).map(g=>g.id);
    kids.forEach(c=>out.push(c)); });
  _goals.forEach(g=>{ if(out.indexOf(g.id)<0) out.push(g.id); });
  return out;
}
// Move id within order so it lands just before/after target, picking the side from drag
// direction (downward -> after, upward -> before). This lets a drop reach the very end,
// which a fixed before-insert cannot.
function gMove(order, id, target){
  const fi=order.indexOf(id), ti=order.indexOf(target);
  if(fi<0||ti<0||id===target) return null;
  const without=order.filter(x=>x!==id);
  let at=without.indexOf(target); if(fi<ti) at++;
  without.splice(at,0,id); return without;
}
let _gSecFrom=null;   // parent id being dragged (section reorder)
function gSecStart(e,pid){ _gSecFrom=pid; e.dataTransfer.effectAllowed='move'; try{e.dataTransfer.setData('text/plain',pid);}catch(_){}
  const s=document.getElementById('gsec_'+pid); if(s) s.classList.add('dragging'); }
function gSecEnd(){ _gSecFrom=null; document.querySelectorAll('.gsec').forEach(el=>el.classList.remove('dragging','dropTarget')); }
function gSecOver(e,pid){ if(_gSecFrom===null||_gSecFrom===pid) return; e.preventDefault(); e.dataTransfer.dropEffect='move';
  const s=document.getElementById('gsec_'+pid); if(s){ document.querySelectorAll('.gsec.dropTarget').forEach(el=>el.classList.remove('dropTarget')); s.classList.add('dropTarget'); } }
function gSecLeave(e){ if(_gSecFrom===null) return; const s=e.currentTarget; if(s && !s.contains(e.relatedTarget)) s.classList.remove('dropTarget'); }
function gSecDrop(e,pid){ if(_gSecFrom===null) return; e.preventDefault();
  const from=_gSecFrom; gSecEnd();
  if(from===pid) return;
  const order=gMove(_goals.filter(g=>!g.parent).map(g=>g.id), from, pid);
  if(order) post('/api/goal/reorder',{order:gBuildOrder(order)});
}
let _gChildFrom=null;   // {pid,id} of child being dragged
function gChildStart(e,pid,id){ _gChildFrom={pid:pid,id:id}; e.dataTransfer.effectAllowed='move'; try{e.dataTransfer.setData('text/plain',id);}catch(_){}
  e.stopPropagation(); const row=e.target.closest('.gchild'); if(row) row.classList.add('dragging'); }
function gChildEnd(){ _gChildFrom=null; document.querySelectorAll('.gchild').forEach(el=>el.classList.remove('dragging','dropTarget')); }
// Children only reorder within their own parent — a drag over a foreign section is ignored.
function gChildOver(e,pid,id){ if(!_gChildFrom||_gChildFrom.pid!==pid) return; e.preventDefault(); e.stopPropagation(); e.dataTransfer.dropEffect='move';
  const row=e.currentTarget; document.querySelectorAll('.gchild.dropTarget').forEach(el=>el.classList.remove('dropTarget')); row.classList.add('dropTarget'); }
function gChildLeave(e){ if(!_gChildFrom) return; e.currentTarget.classList.remove('dropTarget'); }
function gChildDrop(e,pid,id){ if(!_gChildFrom||_gChildFrom.pid!==pid) return; e.preventDefault(); e.stopPropagation();
  const from=_gChildFrom.id; gChildEnd();
  if(from===id) return;
  const kids=gMove(_goals.filter(g=>g.parent===pid).map(g=>g.id), from, id);
  if(!kids) return;
  const ov={}; ov[pid]=kids;
  post('/api/goal/reorder',{order:gBuildOrder(_goals.filter(g=>!g.parent).map(g=>g.id), ov)});
}
// One child row: same inline editors (status / note / evidence / delete) and element
// ids as the 목록 view, so timers + evidence panels work unchanged here too.
function gChildRow(g,r){
  return '<div class="gchild" oncontextmenu="goalCtx(event,\''+g.id+'\')" ondragover="gChildOver(event,\''+g.parent+'\',\''+g.id+'\')" ondrop="gChildDrop(event,\''+g.parent+'\',\''+g.id+'\')" ondragleave="gChildLeave(event)">'
    +'<span class="grip" draggable="true" ondragstart="gChildStart(event,\''+g.parent+'\',\''+g.id+'\')" ondragend="gChildEnd(event)" title="드래그하여 순서 변경">⠿</span>'
    +gpill(g)+linkDot(g)
    +slinkBtn(g)
    +'<span class="gt" id="gt_'+g.id+'" title="'+esc(g.text)+' — 더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span>'
    +'<span class="stat">'+statSel(g)+'</span>'
    +ttimeHTML(g)
    +noteBtn(g,r)
    +'<button class="btn evbtn'+(evCount(g)>0?' has':'')+'" onclick="toggleEv(\''+g.id+'\')" title="증거(링크·파일)">📎 '+evCount(g)+'</button>'
    +'<button class="btn" onclick="removeGoal(\''+g.id+'\')">삭제</button>'
    +notePanel(g,r)+evidencePanel(g)+'</div>';
}
function gSection(t,all,r){
  const kids=goalKids(all,t);
  const vkids=kids.filter(k=>goalPasses(k,all));   // filter for display; count stays full
  const done=kids.filter(k=>(k.status||'backlog')==='done').length;
  const ds=derivedStatus(all,t);
  const collapsed=_gCollapsed.has(t.id);
  const tag=ds==='on_track'?'<span class="otTag">On Track</span>'
    :(ds==='done'?'<span class="otTag" style="border-color:var(--green);color:var(--green);background:rgba(54,192,138,.12)">완료</span>':'');
  const prog=kids.length?('자식 '+done+'/'+kids.length):'자식 없음';
  let body=vkids.length? vkids.map(k=>gChildRow(k,r)).join('')
    : '<div class="muted" style="font-size:12px;padding:4px 0">'
      +(kids.length?('필터로 가려진 자식 '+kids.length+'개'):'아직 자식이 없습니다. 아래에서 추가하세요.')+'</div>';
  body+='<div class="gsec-add">'
    +'<input type="text" data-parent="'+t.id+'" placeholder="이 목표 아래 추가 후 Enter" style="flex:1;min-width:120px">'
    +'<button class="btn" onclick="gSectAdd(\''+t.id+'\',this)">추가</button></div>';
  return '<div class="gsec'+(collapsed?' collapsed':'')+'" id="gsec_'+t.id+'" ondragover="gSecOver(event,\''+t.id+'\')" ondrop="gSecDrop(event,\''+t.id+'\')" ondragleave="gSecLeave(event)">'
    +'<div class="gsec-hd" draggable="true" oncontextmenu="goalCtx(event,\''+t.id+'\')" ondragstart="gSecStart(event,\''+t.id+'\')" ondragend="gSecEnd(event)" onclick="gToggleSec(\''+t.id+'\')" title="드래그하여 그룹 우선순위 변경 · 클릭하여 접기 · 우클릭하여 이동 메뉴">'
      +'<span class="grip" title="드래그하여 그룹 우선순위 변경">⠿</span>'
      +'<span class="tw">▾</span>'
      +gpill(t)+linkDot(t)
      +slinkBtn(t)
      +'<span class="gtitle">'+esc(t.text)+tag+'</span>'
      +'<span class="prog">'+prog+'</span>'
      +'<button class="btn" onclick="event.stopPropagation();gSetActiveParent(\''+t.id+'\')" title="상단 입력칸의 부모를 이 목표로 지정">+여기에</button>'
      +'<button class="btn" onclick="event.stopPropagation();removeGoal(\''+t.id+'\')">삭제</button>'
    +'</div><div class="gsec-body">'+body+'</div></div>';
}
function renderGroupSections(r){
  const all=(r&&r.goals)||[]; _goals=all;
  const host=$('groupSections'); if(!host) return;
  // Parent autocomplete = top-level goals only (1-level hierarchy).
  const dl=$('gParentList');
  if(dl) dl.innerHTML=all.filter(g=>!g.parent)
    .map(g=>'<option value="goal-'+pad2(g.seq)+'">goal-'+pad2(g.seq)+' · '+esc(g.text)+'</option>').join('');
  if(!all.length){ host.innerHTML='<div class="muted" style="padding:8px 0">목표가 없습니다. 위 입력칸에 추가하세요.</div>'; return; }
  // Group sections open COLLAPSED by default. Apply once per parent (tracked in _gSeen) so a
  // section the user later expands stays open across the 5s poll re-render, and newly added
  // parents still start closed.
  all.filter(g=>!g.parent).forEach(g=>{ if(!_gSeen.has(g.id)){ _gSeen.add(g.id); _gCollapsed.add(g.id); } });
  updateFilterButtons();
  // Parent sections follow the shared filter too (디폴트는 상위도 필터; 상위 항상 표시 시 모두 노출).
  const tops=all.filter(g=>!g.parent && goalPasses(g,all));
  if(!tops.length){ host.innerHTML='<div class="muted" style="padding:8px 0">'+(anyStatusActive()?'해당 상태의 상위 목표가 없습니다.':'표시할 상태를 선택하세요 (대기 · 진행 · 완료).')+'</div>'; return; }
  const q=_gQuery;
  const vis=q? tops.filter(t=> t.text.toLowerCase().includes(q) || goalKids(all,t).some(k=>k.text.toLowerCase().includes(q))) : tops;
  if(!vis.length){ host.innerHTML='<div class="muted" style="padding:8px 0">검색 결과 없음: '+esc(_gQuery)+'</div>'; return; }
  host.innerHTML=vis.map(t=>gSection(t,all,r)).join('');
  applyEvOpen(); applyNoteOpen();
  host.querySelectorAll('.gsec-add input').forEach(el=>bindImeEnter(el,function(x){ gAddChild(x.dataset.parent,x); }));
  if(_gRefocus){ const el=host.querySelector('.gsec-add input[data-parent="'+_gRefocus+'"]'); _gRefocus=''; if(el) el.focus(); }
}
function copyMd(b){ if(navigator.clipboard) navigator.clipboard.writeText(_md); const o=b.textContent; b.textContent='복사됨'; setTimeout(()=>{b.textContent=o;},1200); }
// 열려 있는 큐 다듬기 항목의 claude 세션 ID를 클립보드로 복사. CLI에서 `claude --resume <id>` 로 이어쓸 수 있다.
function copyDupSession(b){ const sid=(_dupPending&&_dupPending.refineSession)||''; if(!sid){ b.textContent='세션 없음'; setTimeout(()=>{b.textContent='세션 ID 복사';},1200); return; }
  if(navigator.clipboard) navigator.clipboard.writeText(sid); b.textContent='복사됨'; setTimeout(()=>{b.textContent='세션 ID 복사';},1200); }
// 열려 있는 큐 항목의 다듬기 세션을 터미널에서 `claude --resume`으로 바로 연다(백엔드가 Terminal.app 실행).
function openDupCli(b){ const id=(_dupPending&&_dupPending.queueId)||''; if(!id) return; const o='CLI에서 열기'; b.disabled=true; b.textContent='여는 중…';
  fetch('/api/goal/queue/cli',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id})})
    .then(r=>r.json()).then(j=>{ b.textContent=j&&j.ok?'열림':'실패'; })
    .catch(()=>{ b.textContent='실패'; })
    .finally(()=>{ setTimeout(()=>{ b.disabled=false; b.textContent=o; },1200); }); }
function gnote(r,id){ return (r.notes&&r.notes[id])||''; }

// ===== 일정관리 (schedule / resource management) =====
// Every goal is dropped into an urgency bucket derived from its 목표(target) datetime, so
// the board reads "what's overdue / due today / this week / later". Completed goals collect
// in their own 완료 group (newest first) regardless of target. Each row carries inline
// target/완료 datetime pickers; editing one posts to the server and the 5s poll re-renders.
function startOfDay(epochSec){ return CMTimeFilter.parseDay(CMTimeFilter.dayStr(new Date(epochSec*1000))).getTime()/1000; }   // 표시 tz 자정
// datetime-local needs "YYYY-MM-DDTHH:mm" — 표시 타임존 벽시계로; 0/absent => empty field.
function localInput(epochSec){ return CMTimeFilter.epochToInput(epochSec); }
function fmtDate(epochSec){ if(!epochSec) return '–'; const q=CMTimeFilter.parts(epochSec*1000), p=n=>(n<10?'0':'')+n;
  return q.mo+'/'+q.d+' '+p(q.h)+':'+p(q.mi); }
// datetime-local value -> epoch seconds (표시 tz); empty -> 0 (clears the field server-side).
function setTarget(id,val){ post('/api/goal/target',{id:id,target:CMTimeFilter.inputToEpoch(val)}); }
function setCompleted(id,val){ post('/api/goal/completed',{id:id,completed:CMTimeFilter.inputToEpoch(val)}); }
function ddayBadge(g){
  if((g.status||'backlog')==='done'){ const c=g.completedAt||0; return '<span class="dday done">✓ '+(c?fmtDate(c):'완료')+'</span>'; }
  const t=g.targetAt||0; if(!t) return '<span class="dday">미정</span>';
  const days=Math.round((startOfDay(t)-startOfDay(Date.now()/1000))/86400);
  if(days<0) return '<span class="dday over">D+'+(-days)+' 지남</span>';
  if(days===0) return '<span class="dday soon">D-DAY</span>';
  if(days<=3) return '<span class="dday soon">D-'+days+'</span>';
  return '<span class="dday">D-'+days+'</span>';
}
function schRow(g,r){
  const ds=derivedStatus(r.goals,g);
  const statCell=(ds!==null)?'<span class="ot '+ds+'" title="자식 태스크 상태에서 자동 계산">'+statLabel(ds)+'</span>':statSel(g);
  return '<div class="schrow" oncontextmenu="goalCtx(event,\''+g.id+'\')">'
    +gpill(g)+linkDot(g)
    +slinkBtn(g)
    +'<span class="st"><span class="gt" id="gt_'+g.id+'" title="'+esc(g.text)+' — 더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span></span>'
    +'<span>'+statCell+'</span>'
    +ddayBadge(g)
    +'<span class="dlab">목표</span><input type="datetime-local" value="'+localInput(g.targetAt)+'" onchange="setTarget(\''+g.id+'\',this.value)">'
    +'<span class="dlab">완료</span><input type="datetime-local" value="'+localInput(g.completedAt)+'" onchange="setCompleted(\''+g.id+'\',this.value)">'
    +noteBtn(g,r)
    +'<button class="btn evbtn'+(evCount(g)>0?' has':'')+'" onclick="toggleEv(\''+g.id+'\')" title="증거(링크·파일)">📎 '+evCount(g)+'</button>'
    +notePanel(g,r)+evidencePanel(g)+'</div>';
}
function schSection(cls,title,goals,r){
  return '<div class="schsec'+(cls?' '+cls:'')+'">'
    +'<div class="schsec-hd">'+esc(title)+'<span class="cnt">'+goals.length+'개</span></div>'
    +goals.map(g=>schRow(g,r)).join('')+'</div>';
}
function renderSchedule(r){
  const all=(r&&r.goals)||[]; _goals=all;
  const host=$('scheduleSections'); if(!host) return;
  // Unified status filter (목록·그룹·프리뷰와 동일): unchecking 완료 etc. hides those goals here too.
  const list=getFilteredGoals(all);
  if(!list.length){ host.innerHTML='<div class="muted" style="padding:8px 0">'+(anyStatusActive()?'해당 상태의 목표가 없습니다.':'표시할 상태를 선택하세요 (대기 · 진행 · 완료).')+'</div>'; return; }
  const sod=startOfDay(Date.now()/1000), eod=sod+86400, week=sod+7*86400;
  const G={over:[],today:[],week:[],later:[],none:[],done:[]};
  list.forEach(g=>{
    if((g.status||'backlog')==='done'){ G.done.push(g); return; }
    const t=g.targetAt||0;
    if(!t) G.none.push(g);
    else if(t<sod) G.over.push(g);
    else if(t<eod) G.today.push(g);
    else if(t<week) G.week.push(g);
    else G.later.push(g);
  });
  const byTarget=(a,b)=>((a.targetAt||0)-(b.targetAt||0))||((a.seq||0)-(b.seq||0));
  G.over.sort(byTarget); G.today.sort(byTarget); G.week.sort(byTarget); G.later.sort(byTarget);
  G.none.sort((a,b)=>(a.seq||0)-(b.seq||0));
  G.done.sort((a,b)=>(b.completedAt||0)-(a.completedAt||0));
  const secs=[
    ['overdue','지남 (기한 초과)',G.over],
    ['today','오늘',G.today],
    ['','이번 주',G.week],
    ['','예정',G.later],
    ['','미정 (목표일 없음)',G.none],
    ['done','완료',G.done],
  ];
  host.innerHTML=secs.filter(s=>s[2].length).map(s=>schSection(s[0],s[1],s[2],r)).join('');
  applyEvOpen(); applyNoteOpen();
}

let _lastReviewKey='';
function renderReview(d){
  const r=d.review||{goals:[],notes:{},submittedSelf:false,aiScore:null,selfScore:null};
  _review=r;   // keep latest review so the 완료 필터 can re-render rows on demand
  // confirmed value (drives the header 가치 figure; stays 0 until self+AI pass)
  const prov=provisionalHours(d.samples);
  let conf=0;
  if(r.submittedSelf && r.aiScore!=null) conf=prov*((r.selfScore||0)/100)*((r.aiScore||0)/100);
  // 확정 가치 카드(#value)는 컨디션 관리 페이지로 이동했다 — 여기 없으면 건너뛴다(conf 자체는 아래에서 계속 사용).
  const _valEl=$('value'); if(_valEl) _valEl.textContent=conf.toFixed(1)+'h';
  // report + markdown (read-only; safe to rebuild each tick)
  _md=buildMarkdown(d,r,conf,prov);
  _lastReportArgs={d:d,r:r,conf:conf,prov:prov};   // so reapplyFilter() can rebuild 프리뷰
  renderReport(d,r,conf,prov);
  // input-side DOM (has text fields) — rebuild only when review data changes,
  // so the 5s auto-refresh never wipes a note you're typing.
  const key=JSON.stringify(r);
  if(key!==_lastReviewKey){
    _lastReviewKey=key;
    // 큐 아이템 수를 기억해 탭바 우측 큐 상태 노티(실행 중/검토 대기)를 갱신한다.
    _lastAiQueue=r.aiQueue||[];
    fillActiveView(r);   // renders 목록 OR 그룹 OR 큐 (only the active one — see note above)
    updateQueueNoti(r.aiQueue||[]);
  }
  applyView();
}
// Flat, numbered list (creation order). Parent set later via the 부모# field.
// The 완료만 filter narrows the rendered rows but keeps _goals as the full list so
// drag indices and the live timers stay correct.
function renderGoalsInput(r){
  const all=r.goals||[], gv=$('goals');
  _goals=all;
  updateFilterButtons();
  if(!all.length){ gv.innerHTML='<div class="muted" style="padding:4px 0">목표를 추가하세요. (Enter로 계속 추가)</div>'; return; }
  const list=getFilteredGoals(all);
  // 완료만 보기일 땐 첨부(증거) 패널을 펼쳐 자료 넘기기를 돕는다 (기존 동작 유지).
  const onlyDone=_statusFilter.done&&!_statusFilter.backlog&&!_statusFilter.in_progress;
  if(onlyDone) list.forEach(g=>_evOpen.add(g.id));
  if(!list.length){ gv.innerHTML='<div class="muted" style="padding:4px 0">'+(anyStatusActive()?'해당 상태의 목표가 없습니다.':'표시할 상태를 선택하세요 (대기 · 진행 · 완료).')+'</div>'; return; }
  gv.innerHTML=energyGauge(all)+list.map(g=>goalRow(g,all.indexOf(g),r)+taskRows(g)).join('');
  applyEvOpen(); applyNoteOpen();
}
// 부분과제(task) 행: 유형 필터에 'task'가 켜졌을 때만 goal 행 바로 아래에 붙는 읽기 전용 행.
// 데이터는 /data.json goal.tasks(서버가 goal-NN/tasks/*의 _task.md를 요약). 클릭하면 해당
// task 페이지(/goal?n=NN&t=<folder>)로 이동. 보기(상태) 필터도 task 상태에 맞춰 적용한다
// (TODO→대기, DOING→진행, DONE→완료 — BLOCKED(막힘)는 중지처럼 항상 표시).
const TASK_ST={TODO:{f:'backlog',cls:'',lab:'대기'},DOING:{f:'in_progress',cls:'in_progress',lab:'진행'},
               DONE:{f:'done',cls:'done',lab:'완료'},BLOCKED:{f:'',cls:'waiting',lab:'막힘'}};
function taskRows(g){
  if(!_typeSel.has('task')) return '';
  const ts=g.tasks||[]; if(!ts.length) return '';
  return ts.filter(t=>{
    const m=TASK_ST[(t.status||'TODO').toUpperCase()];
    return !(m&&m.f)||!!_statusFilter[m.f];
  }).map(t=>{
    const st=(t.status||'TODO').toUpperCase();
    const m=TASK_ST[st]||{cls:'',lab:st};
    const href='/goal?n='+g.seq+'&t='+encodeURIComponent(t.folder);
    return '<div class="goal taskrow">'
      +'<span class="tlead muted">└</span>'
      +'<a class="pill gp" href="'+href+'" title="task 페이지 열기">'+esc(t.id)+'</a>'
      +'<span class="g"><span class="gt" title="'+esc(t.title||t.folder)+'">'+esc(t.title||t.folder)+'</span></span>'
      +'<span class="ot '+m.cls+'" style="font-size:11px">'+m.lab+'</span>'
      +'</div>';
  }).join('');
}
// Energy gauge: only meaningful once 2+ goals run at once (AI concurrency). Shows the
// summed allocation against the user's 100% cap; turns red and warns when over-committed.
function energyGauge(goals){
  const c=concCount(goals); if(c<CONC_ENERGY) return '';
  const sum=energySum(goals), over=sum>100, pct=Math.min(100,sum);
  return '<div class="engauge'+(over?' over':'')+'">'
    +'<div class="head"><span>동시 진행 '+c+'개 · 에너지 '+sum+'% / 100</span>'
    +'<span class="'+(over?'warn':'muted')+'">'+(over?'⚠ 에너지 초과 — 동시 작업 과부하':('남은 '+Math.max(0,100-sum)+'%'))+'</span></div>'
    +'<div class="bar"><div class="fill" style="width:'+pct+'%"></div></div></div>';
}
// Clickable sprint badge for a goal row. Click → swaps to a tiny number input that
// commits on blur/Enter (스프 배지를 눌러 일일 목록에서 바로 루프 변경).
function spBadge(g){
  const n=(g.sprint>0)?g.sprint:0;   // -1(분리)·0은 모두 미배정 표시
  return '<span class="spbadge'+(n?'':' none')+'" id="sp_'+g.id+'" title="클릭해 루프 변경"'
    +' onclick="editSpInline(\''+g.id+'\')">'+(n?esc(sprintCode(n)):'루프 –')+'</span>';
}
function editSpInline(id){
  const el=$('sp_'+id); if(!el) return;
  const g=(_goals||[]).find(x=>x.id===id); const cur=(g&&g.sprint)?g.sprint:'';
  el.outerHTML='<input class="spedit" id="spi_'+id+'" inputmode="numeric" value="'+cur+'" placeholder="–"'
    +' onkeydown="if(event.key===\'Enter\')this.blur()" onblur="commitSpInline(\''+id+'\',this.value)">';
  const inp=$('spi_'+id); if(inp){ inp.focus(); inp.select(); }
}
// Commit a sprint assignment. Used by the daily-list inline badge (blur, single fire)
// and the 골 배정 table inputs (per-row onchange). post() reloads the view.
function commitSpInline(id,v){
  const n=(String(v).trim()==='')?0:(parseInt(String(v).replace(/[^0-9]/g,''),10)||0);
  post('/api/goal/sprint',{id:id,sprint:n});
}
function goalRow(g,i,r){
  const isChild=!!g.parent;
  // Parent goals show a derived rollup status (not manual buttons); leaves stay manual.
  const ds=derivedStatus(r.goals,g);
  const statCell=(ds!==null)
    ? '<span class="ot '+ds+'" title="자식 태스크 상태에서 자동 계산">'+statLabel(ds)+'</span>'
    : statSel(g);
  const running=(g.status==='in_progress')||(ds==='on_track');
  return '<div class="goal'+(ds==='on_track'?' ontrack':(running?' running':''))+'" data-i="'+i+'" oncontextmenu="goalCtx(event,\''+g.id+'\')" ondragover="dragOver(event,'+i+')" ondrop="dropOn(event,'+i+')" ondragleave="dragLeave(event)">'
    +'<span class="grip" draggable="true" ondragstart="dragStart(event,'+i+')" ondragend="dragEnd(event)" title="드래그하여 우선순위 변경">⠿</span>'
    +gpill(g)+linkDot(g)
    +slinkBtn(g)+spBadge(g)
    +'<span class="g">'+(isChild?'<span class="muted">└ </span>':'')+'<span class="gt" id="gt_'+g.id+'" title="'+esc(g.text)+' — 더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span></span>'
    +'<span class="stat">'+statCell+'</span>'
    +ttimeHTML(g)+wbadgeHTML(g)
    +'<span class="muted" style="font-size:12px">부모#</span>'
    +parentCellHTML(g,false)
    +noteBtn(g,r)
    +'<button class="btn evbtn'+(evCount(g)>0?' has':'')+'" onclick="toggleEv(\''+g.id+'\')" title="증거(링크·파일) 첨부·보기">📎 '+evCount(g)+'</button>'
    +'<button class="btn" onclick="removeGoal(\''+g.id+'\')">삭제</button>'
    +aiWorkRow(g,r)+notePanel(g,r)+evidencePanel(g)+'</div>';
}
// AI-work inputs on a PARENT goal (big-picture level), shown only while that parent is
// active (on_track). Energy and agent blocks gate independently on the active-parent count:
//   agents/tokens/value/ROI from CONC_AGENT (1 = a single active parent can name its agents),
//   energy from CONC_ENERGY (2 = two parents in parallel must split the 100% capacity).
function aiWorkRow(g,r){
  if(!activeParent(r.goals,g)) return '';
  const c=concCount(r.goals);
  const showEnergy=c>=CONC_ENERGY, showAgent=c>=CONC_AGENT;
  if(!showEnergy && !showAgent) return '';
  let h='<div class="aiwork">';
  if(showEnergy){
    h+='<span class="lab">에너지</span>'
      +'<input type="number" min="0" max="100" value="'+(g.energy||0)+'" onchange="setEnergy(\''+g.id+'\',this.value)">'
      +'<span class="lab">%</span>';
  }
  if(showAgent){
    const ag=(g.agents||[]).join(', ').replace(/"/g,'&quot;');
    const roi=roiOf(g), rc=roiClass(roi);
    const roiTxt=(roi==null)?'ROI –':('ROI '+roi.toFixed(2));
    h+='<span class="lab">에이전트</span>'
      +'<input type="text" class="agents" placeholder="agent1, agent2" value="'+ag+'" onchange="setAgents(\''+g.id+'\',this.value)">'
      +'<span class="lab">토큰</span>'
      +'<input type="number" min="0" value="'+(g.tokens||0)+'" onchange="setTokens(\''+g.id+'\',this.value)"><span class="lab">K</span>'
      +'<span class="lab">가치</span>'
      +'<input type="number" min="0" value="'+(g.value||0)+'" onchange="setValue(\''+g.id+'\',this.value)">'
      +'<span class="roi '+rc+'" title="가치 ÷ 토큰(K) — 동시 작업이 실제로 의미있는지">'+roiTxt+'</span>';
  }
  return h+'</div>';
}
// ===== 테이블 뷰 (정렬 전용) =====
// A flat, sortable table over the SAME filtered goal set as 목록/그룹. Purpose is pure
// sorting — by parent, goal number, status, name, session presence, target/완료 time, and
// accumulated work time — so a single header click reorders the whole list. Hierarchy is
// not drawn (a child just shows its parent's number in the 부모 column).
let _tblSort={key:'seq',dir:1};   // active sort key + direction (1 asc, -1 desc)
const TBL_COLS=[
  {key:'seq',label:'번호'},
  {key:'parent',label:'부모'},
  {key:'status',label:'상태'},
  {key:'name',label:'목표'},
  {key:'session',label:'세션'},
  {key:'tracked',label:'누적시간'},
  {key:'target',label:'목표시각'},
  {key:'completed',label:'완료시각'},
];
// Sort order for the status column: active work first, finished/cancelled last.
const STATUS_RANK={in_progress:0,waiting:1,backlog:2,stopped:3,done:4,cancelled:5};
function tblStatLabel(s){ const m={backlog:'대기',in_progress:'진행',waiting:'응답 대기',stopped:'중지',cancelled:'취소',done:'완료'}; return m[s]||s; }
function tblVal(g,key,all,idToNum){
  if(key==='seq') return g.seq||0;
  if(key==='parent') return (g.parent&&idToNum[g.parent])?idToNum[g.parent]:0;
  if(key==='status'){ const r=STATUS_RANK[effStatus(g,all)]; return r==null?99:r; }
  if(key==='name') return g.text||'';
  if(key==='session') return g.sessionId?1:0;
  if(key==='tracked') return effTracked(g);
  if(key==='target') return g.targetAt||0;
  if(key==='completed') return g.completedAt||0;
  return 0;
}
function tblCmp(a,b,key,all,idToNum,dir){
  const va=tblVal(a,key,all,idToNum), vb=tblVal(b,key,all,idToNum);
  let c=(key==='name')?String(va).localeCompare(String(vb),'ko'):(va-vb);
  if(c===0) c=(a.seq||0)-(b.seq||0);   // stable tiebreak by goal number
  return c*dir;
}
function setTblSort(key){
  if(_tblSort.key===key) _tblSort.dir=-_tblSort.dir;   // same header -> flip direction
  else { _tblSort.key=key; _tblSort.dir=1; }           // new header -> ascending
  if(_review) renderTable(_review);
}
function tblRow(g,all,idToNum){
  const es=effStatus(g,all), isChild=!!g.parent;
  // Parents carry a derived rollup -> show the rolled-up label (On Track / 완료 / 대기),
  // matching 목록·그룹 views; leaves show their own status.
  const ds=derivedStatus(all,g);
  const stCell=(ds!==null)
    ? '<span class="ot '+ds+'">'+statLabel(ds)+'</span>'
    : '<span class="ot '+es+'">'+tblStatLabel(es)+'</span>';
  const pnum=(g.parent&&idToNum[g.parent])?('goal-'+pad2(idToNum[g.parent])):'<span class="muted">–</span>';
  return '<tr class="'+(es==='done'?'done ':'')+(isChild?'child':'')+'" oncontextmenu="goalCtx(event,\''+g.id+'\')">'
    +'<td>'+gpill(g)+linkDot(g)+'</td>'
    +'<td>'+pnum+'</td>'
    +'<td>'+stCell+'</td>'
    +'<td class="nm" title="'+esc(g.text)+'">'+(isChild?'<span class="muted">└ </span>':'')+esc(g.text)+'</td>'
    +'<td>'+(g.sessionId?slinkBtn(g):'<span class="muted">–</span>')+'</td>'
    +'<td>'+ttimeHTML(g)+'</td>'
    +'<td>'+(g.targetAt?fmtDate(g.targetAt):'<span class="muted">–</span>')+'</td>'
    +'<td>'+(g.completedAt?fmtDate(g.completedAt):'<span class="muted">–</span>')+'</td>'
    +'</tr>';
}
function renderTable(r){
  const all=r.goals||[]; _goals=all;
  updateFilterButtons();
  const host=$('tableHost');
  if(!all.length){ host.innerHTML='<div class="muted" style="padding:4px 0">목표를 추가하세요.</div>'; return; }
  const idToNum={}; all.forEach(g=>{ idToNum[g.id]=g.seq; });
  const list=getFilteredGoals(all).slice().sort((a,b)=>tblCmp(a,b,_tblSort.key,all,idToNum,_tblSort.dir));
  if(!list.length){ host.innerHTML='<div class="muted" style="padding:4px 0">'+(anyStatusActive()?'해당 상태의 목표가 없습니다.':'표시할 상태를 선택하세요 (대기 · 진행 · 완료).')+'</div>'; return; }
  const arrow=_tblSort.dir>0?'▲':'▼';
  const head=TBL_COLS.map(c=>{ const on=c.key===_tblSort.key;
    return '<th class="sortable'+(on?' sorted':'')+'" onclick="setTblSort(\''+c.key+'\')">'+c.label+(on?'<span class="arr">'+arrow+'</span>':'')+'</th>'; }).join('');
  host.innerHTML='<table class="gtbl"><thead><tr>'+head+'</tr></thead><tbody>'+list.map(g=>tblRow(g,all,idToNum)).join('')+'</tbody></table>';
}

// ===== 토큰 뷰 — 완료 항목의 토큰 사용량을 완료일로 묶어 본다 =====
// 목적: "어제(혹은 특정 기간)에 무엇을 끝내며 토큰을 얼마나 썼나"를 한눈에. 완료된 목표만
// 대상으로, 완료 시각(없으면 자식 롤업)의 날짜가 상단 기간 필터(_tkStart~_tkEnd) 안에 드는
// 것만 완료일별 그룹으로 보여준다. 날짜가 유일한 축 — 루프 그룹핑·완료 컷오프 연동은 폐기.
// 일별 그룹용: 완료 시각(epoch초) → 'YYYY-MM-DD'(로컬), 그리고 그 날의 사람용 라벨(요일 포함).
function tkDayStr(epochSec){ return histDayStr(new Date(epochSec*1000)); }
function tkDayLabel(dayStr){
  const wd=['일','월','화','수','목','금','토'][new Date(dayStr+'T00:00:00').getDay()];
  const diff=daysBetween(dayStr, histDayStr(new Date()));   // 0=오늘, 1=어제 …
  const rel=(diff===0)?' · 오늘':(diff===1?' · 어제':'');
  return dayStr+' ('+wd+')'+rel;
}
// 읽기 전용 루프 코드 태그 (스프 배지와 달리 클릭 편집 없음 — id 충돌 방지).
function tkSprintTag(g,goals){
  const n=effSprint(g,goals);
  return '<span class="spbadge'+(n?'':' none')+'" style="cursor:default" title="루프">'+(n?esc(sprintCode(n)):'루프 –')+'</span>';
}
function tkRow(g,goals){
  const c=goalCompletedAt(g,goals);
  // [4] 투입 지수 모드에서 부모(자식 세션 보유) 목표는 '활동량(세션 수)' 배지를 함께 보여준다.
  const kids=(_tkMode==='val')?childSessionCount(g,goals):0;
  const breadth=kids>0?'<span class="chip" style="margin:0 0 0 4px;border-color:#8f6fe3;color:#b39cf0" title="이 목표에 매달린 세션(자식) 수 = 활동량(산출물 폭). 성과(가치) 아님">세션 '+kids+'</span>':'';
  const amtTitle=(_tkMode==='val')?'투입 지수 (토큰효율×가중치, pt) — 투입이지 성과 아님':'이 목표에 연결된 세션 토큰';
  return '<div class="schrow">'
    +gpill(g)+slinkBtn(g)
    +'<span class="st"><span class="gt" title="'+esc(g.text)+'">'+esc(g.text)+'</span></span>'
    +tkSprintTag(g,goals)
    +'<span class="dday done">✓ '+(c?fmtDate(c):'완료')+'</span>'
    +breadth
    +'<span class="tkn" title="'+amtTitle+'">'+tkAmount(g.tokens||0)+'</span>'
    +'</div>';
}
// ===== 투입 지수(input index) 모델 — 임시(회사 goal 연동 전). 자세한 근거는 docs/value-model.md 참고 =====
// 중요: 이 숫자는 '성과(가치)'가 아니라 '투입(비용)'이다. 토큰을 많이 쓸수록 커지므로, 돈($)이나 '가치'로
//       표기하지 않는다 — 투입을 성과로 오독하면 "돈만 쓰고 성과 없는" 것을 성과로 포장하게 된다.
// [2] 토큰효율: 100% 한달치 사용 = 10,000 pt(무단위). 100% 한달 토큰량을 60만 K(=600M, 캐시 포함)로 잡아
//     가중치 W=10000/600000≈0.0167 pt/K.
// [3] 시간효율: 같은 투입 지수를 더 적은 시간에 굴렸으면 도구를 더 효율적으로 쓴 것(노동생산성, 투입 측).
//     풀타임 한달(720h)에 10,000 pt를 내는 속도를 기준선(BASE_RATE)으로, 실제 (pt/시간) ÷ 기준선 = 배수 F.
const IDX_PER_MONTH=10000, FULL_MONTH_K=600000, FULL_MONTH_H=720;
const TK_W=IDX_PER_MONTH/FULL_MONTH_K;        // pt/K (투입 지수 가중치)
const BASE_RATE=IDX_PER_MONTH/FULL_MONTH_H;   // pt/시간 (풀타임 기준선)
function tkIndex(k){ return (k||0)*TK_W; }
function fmtIdx(v){ return Math.round(v).toLocaleString()+' pt'; }   // 무단위 지수 — $ 아님
// 저장 단위는 K를 유지하되 1,000K부터 M으로 축약해 크기를 즉시 읽을 수 있게 한다.
// M은 최대 소수점 한 자리까지만 보여주고 불필요한 .0은 제거한다 (예: 864 K, 1M, 113.1M).
function fmtTokenK(k){
  const n=Number(k)||0;
  if(Math.abs(n)<1000) return n.toLocaleString()+' K';
  return (Math.round(n/100)/10).toLocaleString(undefined,{maximumFractionDigits:1})+'M';
}
// 표시 헬퍼: 토큰량 모드면 크기에 따라 K/M, 투입 지수 모드면 'N pt'. 뷰 전체가 이 함수를 통해 숫자를 그린다.
function tkAmount(k){ return (_tkMode==='val') ? fmtIdx(tkIndex(k)) : fmtTokenK(k); }
// [4] 활동량(breadth): 부모 goal 하나에 매달린 세션(자식) 수 = 그 목표가 만든 산출물 폭(가치 아님). 1세션=1.
function childSessionCount(g,all){ let n=0; (all||[]).forEach(k=>{ if(k.parent===g.id) n++; }); return n; }
let _tkMode='tok';   // 'tok' 토큰량 | 'val' 투입 지수(pt)
function reflectTkMode(){
  const a=$('tkm_tok'),b=$('tkm_val'); if(a)a.classList.toggle('primary',_tkMode==='tok'); if(b)b.classList.toggle('primary',_tkMode==='val');
  const h=$('tkModeHint'); if(h) h.textContent=(_tkMode==='val')
    ? '토큰효율×시간효율 투입 지수 (100% 한달='+fmtIdx(IDX_PER_MONTH)+' · 투입이지 성과 아님)'
    : '세션이 실제로 쓴 토큰(K)';
}
function setTkMode(m){ _tkMode=m; reflectTkMode(); renderTokenDaily(); if(_review) renderTokenView(_review); }

// ===== 일별 실토큰 타임라인 — /tokens.json(트랜스크립트 합산)에서 하루당 한 줄 =====
// 히스토리 뷰와 같은 기간 필터(오늘·어제·7일·한달·3달 + 직접 범위). 서버는 최신 N일을 주므로
// 캐시된 전체에서 선택 범위만 잘라 렌더 — 범위가 캐시 안이면 재fetch 없이 무비용.
let _tkDaily=null, _tkDailyLoading=false, _tkFetchedDays=0;
let _tkStart='', _tkEnd='', _tkPreset='3m';
let _tkAccFilter='all', _tkAccounts=[];
let _tkModelFilter='all';
function syncTkInputs(){ const a=$('tkFrom'),b=$('tkTo'); if(a)a.value=_tkStart; if(b)b.value=_tkEnd; }
function reflectTkBtn(){ ['today','yesterday','7d','1m','3m'].forEach(k=>{ const b=$('tr_'+k); if(b) b.classList.toggle('primary', k===_tkPreset); }); }
function loadTokenAccounts(){
  fetch('/tokens-accounts.json').then(x=>x.json()).then(j=>{
    _tkAccounts=(j&&j.accounts)||[];
    renderTkAccChips();
  }).catch(()=>{});
}
function setTkAccFilter(aid){
  _tkAccFilter=aid;
  renderTkAccChips();
  renderTokenDaily();
}
function setTkModelFilter(mid){
  _tkModelFilter=mid;
  renderTkModelChips();
  renderTokenDaily();
}
function renderTkAccChips(){
  const allBtn=$('tkacc_all');
  if(allBtn) allBtn.classList.toggle('primary', _tkAccFilter==='all');
  const host=$('tkAccChips');
  if(!host) return;
  host.innerHTML=_tkAccounts.map(a=>{
    const sel=(_tkAccFilter===a.id);
    const col=a.color||'#64748b';
    const bg=sel? col : col+'22';
    const fg=sel? '#ffffff' : col;
    const bd=col+(sel?'cc':'55');
    return '<button class="btn" onclick="setTkAccFilter(\''+a.id+'\')" '
      +'style="background:'+bg+';color:'+fg+';border:1px solid '+bd+';font-weight:'+(sel?'bold':'normal')+';padding:3px 8px;font-size:11px" '
      +'title="'+esc(a.org||a.email||a.id)+'">'+esc(a.label)+'</button>';
  }).join('');
}
function renderTkModelChips(){
  const allBtn=$('tkm_all');
  if(allBtn) allBtn.classList.toggle('primary', _tkModelFilter==='all');
  const host=$('tkModelChipsHost');
  if(!host) return;

  const modelStats={};
  const efforts=new Set();
  (_tkDaily||[]).forEach(d=>{
    for(const m in (d.models||{})){
      const u=d.models[m]||{};
      const sName=m.replace(/^claude-/,'');
      if(!modelStats[sName]) modelStats[sName]={tokens:0,efforts:new Set()};
      modelStats[sName].tokens += (u.in||0) + (u.out||0);
      if(u.effort){
        modelStats[sName].efforts.add(u.effort);
        efforts.add(u.effort.toLowerCase());
      }
    }
  });

  const sortedModels=Object.keys(modelStats).sort((a,b)=>modelStats[b].tokens-modelStats[a].tokens);
  let html=sortedModels.map(m=>{
    const sel=(_tkModelFilter===m);
    let col='#38bdf8';
    if(m.includes('opus')) col='#c084fc';
    else if(m.includes('haiku')) col='#34d399';
    else if(m.includes('glm')) col='#fb923c';
    else if(m.includes('gemini')) col='#60a5fa';
    else if(m.includes('o1')||m.includes('o3')||m.includes('gpt')) col='#10b981';

    const bg=sel? col : col+'22';
    const fg=sel? '#ffffff' : col;
    const bd=col+(sel?'cc':'55');
    const effArr=Array.from(modelStats[m].efforts);
    const effBadge=effArr.length? (' '+effArr.map(e=>e.toUpperCase()).join('/')) : '';
    return '<button class="btn" onclick="setTkModelFilter(\''+esc(m)+'\')" '
      +'style="background:'+bg+';color:'+fg+';border:1px solid '+bd+';font-weight:'+(sel?'bold':'normal')+';padding:3px 8px;font-size:11px" '
      +'title="모델: '+esc(m)+' ('+tkAmount(Math.round(modelStats[m].tokens/1000))+')">'
      +esc(m)+(effBadge? '<span style="font-size:9px;opacity:0.85;margin-left:3px">'+esc(effBadge)+'</span>' : '')
      +'</button>';
  }).join('');

  if(efforts.size>0){
    html += '<span style="border-left:1px solid #334155;margin:0 4px;height:16px;display:inline-block"></span>';
    const effOrder=['high','medium','low','thinking','max'];
    effOrder.forEach(eff=>{
      if(!Array.from(efforts).some(e=>e.includes(eff))) return;
      const key='effort:'+eff;
      const sel=(_tkModelFilter===key);
      let col='#f87171';
      if(eff==='medium') col='#fbbf24';
      else if(eff==='low') col='#60a5fa';
      else if(eff==='thinking') col='#c084fc';
      const bg=sel? col : col+'22';
      const fg=sel? '#ffffff' : col;
      const bd=col+(sel?'cc':'55');
      html += '<button class="btn" onclick="setTkModelFilter(\''+key+'\')" '
        +'style="background:'+bg+';color:'+fg+';border:1px solid '+bd+';font-weight:'+(sel?'bold':'normal')+';padding:3px 8px;font-size:11px" '
        +'title="Effort: '+eff.toUpperCase()+' 필터링">'
        +'⚡ '+eff.toUpperCase()+'</button>';
    });
  }

  host.innerHTML=html;
}
function setTkRange(preset){
  _tkPreset=preset;
  _tkStart=histPresetStart(preset);
  _tkEnd=(preset==='yesterday') ? _tkStart : histDayStr(new Date());
  syncTkInputs(); loadTokenDaily(); refreshTokenGoals();
}
function onTkDate(){
  const a=$('tkFrom'),b=$('tkTo'); if(!a||!b) return;
  if(a.value) _tkStart=a.value; if(b.value) _tkEnd=b.value;
  if(_tkStart>_tkEnd){ const t=_tkStart; _tkStart=_tkEnd; _tkEnd=t; syncTkInputs(); }
  _tkPreset='';                    // 직접 입력하면 퀵버튼 선택 해제
  loadTokenDaily(); refreshTokenGoals();
}
// 기간이 바뀌면 아래 완료 목표 섹션도 같은 범위로 다시 그린다 (renderTokenView가
// loadTokenDaily를 다시 부르지만 캐시·로딩 가드가 있어 무비용).
function refreshTokenGoals(){ if(_review) renderTokenView(_review); }
function loadTokenDaily(force){
  if(!_tkStart){ _tkPreset='3m'; _tkEnd=histDayStr(new Date()); _tkStart=histPresetStart('3m'); syncTkInputs(); }  // 최초 진입 기본값: 3달
  reflectTkBtn();
  if(!_tkAccounts.length) loadTokenAccounts();
  if(_tkDailyLoading) return;
  const need=Math.max(1, daysBetween(_tkStart, histDayStr(new Date()))+1);   // 시작~오늘을 덮을 일수
  if(_tkDaily && !force && need<=_tkFetchedDays){ renderTkModelChips(); renderTokenDaily(); return; }  // 캐시 우선
  _tkDailyLoading=true;
  const rng=$('tokenDailyRange'); if(rng) rng.textContent='불러오는 중…';
  fetch('/tokens.json?days='+need).then(x=>x.json()).then(j=>{
    _tkDaily=(j&&j.days)||[]; _tkFetchedDays=need; _tkDailyLoading=false; renderTkModelChips(); renderTokenDaily();
  }).catch(()=>{ _tkDailyLoading=false; const h=$('tokenDailyHost'); if(h) h.innerHTML='<div class="muted" style="padding:6px 0">일별 토큰을 불러오지 못했습니다</div>'; });
}
// 리드타임(초) 표시 — 60초 미만은 초, 그 위는 분. 케이브맨 효과가 한눈에 보이게 짧은 단위 유지.
function tkFmtLead(s){ if(!(s>0)) return '-'; if(s<60) return Math.round(s)+'초'; const m=s/60; return (m<10? m.toFixed(1) : Math.round(m))+'분'; }
// 하루 구성비 문자열. '컨텍스트'=input+cache_creation — 그 안을 다시 4분할해 보여준다:
// 재적재(이전 턴 히스토리 재캐시+시스템 프롬프트, 잔차) · 도구결과(파일 읽기·명령 출력·
// 도구 스크린샷) · 타이핑(직접 친 프롬프트) · 사진(첨부 이미지 — 장수·용량 병기).
// 하위 %는 전체(spent) 기준이라 넷을 더하면 컨텍스트 %가 된다. 텍스트=글자 가중 추정,
// 이미지=w×h÷750 공식. 서버가 아직 하위 필드를 안 주면(구버전 응답) 상위 4버킷만 표시.
function tkCompStr(d,short){
  const spent=d.tokens||0; if(!(spent>0) || d.inTok==null) return '';
  const p=v=>{ const x=100*(v||0)/spent; return (x>0&&x<1)? x.toFixed(1) : String(Math.round(x)); };
  const imgMeta=(d.imgN>0)? '·'+d.imgN+'장 '+tkFmtMB(d.imgBytes) : '';
  const ctxSub=(d.reloadTok==null)? '' : (short
    ? '(재 '+p(d.reloadTok)+'·결 '+p(d.toolResTok)+'·타 '+p(d.typedTok)+'·사 '+p(d.imgTok)+imgMeta+')'
    : ' (재적재 '+p(d.reloadTok)+'% · 도구결과 '+p(d.toolResTok)+'% · 타이핑 '+p(d.typedTok)+'% · 사진 '+p(d.imgTok)+'%'+imgMeta+')');
  return short
    ? '컨 '+p(d.inTok)+ctxSub+'·생 '+p(d.thinkTok)+'·응 '+p(d.textTok)+'·도 '+p(d.toolTok)+'%'
    : '컨텍스트 '+p(d.inTok)+'%'+ctxSub+' · 생각 '+p(d.thinkTok)+'% · 응답 '+p(d.textTok)+'% · 도구 '+p(d.toolTok)+'%';
}
// 창 점유 — "이 세션이 그 모델의 창을 얼마나 채웠나". 옆의 `컨 77%` 는 구성비지 창 점유가 아니다.
// 분자는 마지막 어시스턴트 요청의 input+cache_read+cache_creation (서브에이전트 제외),
// 분모는 그 모델의 창. 옛 응답에는 이 필드가 없으므로 null 이면 칩을 아예 그리지 않는다 —
// 0 으로 떨어뜨려 0% 를 그리면 "창을 안 썼다" 는 거짓말이 된다.
function tkCtxWinFmt(w){
  if(!(w>0)) return '—';
  if(w<1000000) return Math.round(w/1000)+'K';
  const m=w/1000000; return (Math.round(m*10)/10)+'M';   // 1048576 → 1M (1.0M 이 아니라)
}
function tkCtxWinStr(s){
  if(s==null || s.ctxFinal==null) return '';
  const fin=s.ctxFinal||0, peak=(s.ctxPeak!=null? s.ctxPeak : fin), win=(s.ctxWin!=null? s.ctxWin : 0);
  const model=(s.ctxModel||'').trim();
  const tipTail=' · 산식 input + cache_read + cache_creation (마지막 어시스턴트 요청, 서브에이전트 제외)';
  if(!(win>0)){
    // 창 크기를 모르는 모델(glm-* 등) — 숫자를 지어내지 않고 절대 토큰만 보인다.
    const tip=(model||'모델 미상')+' · 창 미상 · 최종 컨텍스트 '+tkFmtTok(fin)+' · 피크 '+tkFmtTok(peak)+tipTail;
    return '<span class="muted" title="'+esc(tip)+'">창 — · '+tkFmtTok(fin)+'</span>';
  }
  const pct=(s.ctxPct!=null? s.ctxPct : (100*fin/win));
  const peakPct=100*peak/win;
  const col=(pct>=80)? '#e5534b' : (pct>=50? '#d29922' : '');
  const body='창 '+tkCtxWinFmt(win)+' · '+(pct<10? pct.toFixed(1) : Math.round(pct))+'%'
    +((peak>fin)? '(최대 '+(peakPct<10? peakPct.toFixed(1) : Math.round(peakPct))+'%)' : '');
  const tip=(model||'모델 미상')+' · 창 '+tkCtxWinFmt(win)+' · 최종 컨텍스트 '+tkFmtTok(fin)+' · 피크 '+tkFmtTok(peak)+tipTail;
  return col
    ? '<span style="color:'+col+';font-weight:600" title="'+esc(tip)+'">'+body+'</span>'
    : '<span class="muted" title="'+esc(tip)+'">'+body+'</span>';
}
// 일 행·기간 요약의 창 점유 분포 한 조각. 창을 아는 세션이 하나도 없으면 통째로 뺀다.
function tkCtxDistStr(d){
  if(d==null || d.ctxMedPct==null || !(d.ctxSessN>0)) return '';
  const m=d.ctxMedPct;
  return '창 점유 중앙 '+(m<10? m.toFixed(1) : Math.round(m))+'% · 80%↑ '+(d.ctxHighN||0)+'개';
}
// 첨부 이미지 용량 표시 (원본 바이트 기준)
function tkFmtMB(b){ if(!(b>0)) return ''; const mb=b/1048576; return mb>=10? Math.round(mb)+'MB' : mb>=1? mb.toFixed(1)+'MB' : Math.max(1,Math.round(b/1024))+'KB'; }
// AI 가동시간(초) — 사람 프롬프트→그 턴 마지막 AI/도구 라인의 합. 응답이 끝난 뒤 사용자가
// 몇 시간을 방치해도 여기 포함되지 않는다(턴이 마지막 AI 라인에서 닫힘).
function tkFmtAi(s){ if(!(s>0)) return ''; if(s<60) return Math.round(s)+'초'; if(s<5400) return Math.round(s/60)+'분'; return (s/3600).toFixed(1)+'h'; }
// 막대의 컨텍스트 구간을 하위 4분할로 칠한다. 추정 합이 실측 inTok을 넘치면 비율 축소해
// 막대 총길이는 항상 spent와 일치시킨다. 하위 필드가 없으면(구버전) 단색 유지.
function tkCtxSegs(d,seg){
  if(d.reloadTok==null) return seg(d.inTok,'#54627f');
  let r=d.reloadTok||0,t=d.toolResTok||0,y=d.typedTok||0,i=d.imgTok||0;
  const s=r+t+y+i;
  if(s>0 && s>(d.inTok||0)){ const f=(d.inTok||0)/s; r*=f; t*=f; y*=f; i*=f; }
  return seg(r,'#3a4356')+seg(t,'#54627f')+seg(y,'#96a5c8')+seg(i,'#c8b1e8');
}
// ===== 모델 단가($/MTok, 2026-08 Claude API 공시가) — 캐시 읽기=입력단가×0.1,
// 캐시 쓰기 5분 TTL=×1.25, 1시간 TTL=×2, 출력=출력단가. 접두어 매칭(위에서 첫 일치).
// 세션 도중 모델을 바꿔도(하이쿠→페이블 등) 메시지별 model 필드로 집계하므로 정확.
const TK_PRICE=[
  ['claude-fable-5',10,50],['claude-mythos',10,50],
  ['claude-opus-4-1',15,75],['claude-opus-4-0',15,75],
  ['claude-opus',5,25],                        // opus-5 · 4.8 · 4.7 · 4.6 · 4.5
  ['claude-sonnet',3,15],                      // sonnet-5 · 4.6 · 4.5 (sonnet-5 인트로가 반영 전 정식가)
  ['claude-3-5-haiku',0.8,4],['claude-3-haiku',0.25,1.25],
  ['claude-haiku',1,5],
  // GLM(z.ai) — 접두어가 긴 것을 먼저. glm-claude 로 띄운 창이 여기 걸린다.
  ['glm-4.5-air',0.2,1.1],['glm-4.6',0.6,2.2],
  ['glm-5',0.5,1.5],['glm-4',0.5,1.5],
  ['gemini-2',0.1,0.4],['gemini-1.5',0.35,1.05],
  ['o1',15,60],['o3',10,40],['gpt-4o',2.5,10],
];
function tkRate(m){ for(const r of TK_PRICE){ if(m&&m.startsWith(r[0])) return r; } return null; }
// 모델 이름 → provider. 서버의 provider 귀속(AppDelegate.providerForModel 및 각 수집기가
// 붙이는 provider)과 같은 축이어야 한다 — 계정으로 걸렀을 때 그 계정의 모델만 남기려고 쓴다.
function tkProviderOfModel(m){
  const s=String(m||'').toLowerCase();
  if(s.startsWith('glm')) return 'glm';
  if(s.startsWith('gemini')) return 'antigravity';
  if(s.startsWith('gpt')||s.startsWith('o1')||s.startsWith('o3')||s.startsWith('codex')) return 'codex';
  return 'claude';
}
function tkModelCost(m,u){ const r=tkRate(m); if(!r) return 0;
  return ((u.in||0)*r[1] + (u.cr||0)*r[1]*0.1 + (u.c5m||0)*r[1]*1.25 + (u.c1h||0)*r[1]*2 + (u.out||0)*r[2])/1e6; }
function tkCost(models){ let c=0; for(const m in (models||{})) c+=tkModelCost(m,models[m]); return c; }
function tkFmtCost(c){ if(!(c>0)) return '-'; return '$'+(c>=100? Math.round(c) : c>=10? c.toFixed(1) : c.toFixed(2)); }

function tkEffortTag(effort){
  if(!effort || effort==='none' || effort==='off' || effort==='default') return '';
  const eff = String(effort).toLowerCase();
  let bg='rgba(100,116,139,0.25)', fg='#94a3b8', label=String(effort).toUpperCase();
  if (eff.includes('high') || eff.includes('max')) {
    bg='rgba(239, 68, 68, 0.25)'; fg='#f87171'; label=eff.includes('max') ? 'MAX' : (eff.includes('xhigh') ? 'X-HIGH' : 'HIGH');
  } else if (eff.includes('med')) {
    bg='rgba(245, 158, 11, 0.25)'; fg='#fbbf24'; label='MED';
  } else if (eff.includes('low')) {
    bg='rgba(59, 130, 246, 0.25)'; fg='#60a5fa'; label='LOW';
  } else if (eff.includes('think')) {
    bg='rgba(168, 85, 247, 0.25)'; fg='#c084fc'; label='THINK';
  }
  return '<span style="font-size:9px;padding:1px 5px;border-radius:3px;background:'+bg+';color:'+fg+';margin-left:4px;font-weight:700;letter-spacing:0.4px">'+label+'</span>';
}

function tkSessionModelBadge(s){
  const models = s.models || {};
  const entries = Object.keys(models);
  if(!entries.length){
    if(s.provider==='codex') return '<span style="font-size:10px;padding:1px 6px;border-radius:4px;background:#05966922;color:#059669;border:1px solid #05966955;font-weight:600">codex</span>';
    if(s.provider==='antigravity') return '<span style="font-size:10px;padding:1px 6px;border-radius:4px;background:#ea580c22;color:#ea580c;border:1px solid #ea580c55;font-weight:600">Gemini Pro/Flash</span>';
    if(s.provider==='glm') return '<span style="font-size:10px;padding:1px 6px;border-radius:4px;background:#fb923c22;color:#fb923c;border:1px solid #fb923c55;font-weight:600">GLM (z.ai)</span>';
    return '';
  }
  entries.sort((a,b)=> ((models[b].in||0)+(models[b].out||0)) - ((models[a].in||0)+(models[a].out||0)));
  const topM = entries[0];
  const u = models[topM] || {};
  const eff = u.effort || s.effort || '';
  const shortName = topM.replace(/^claude-/,'');

  let mColor = '#38bdf8';
  if (shortName.includes('opus')) mColor = '#c084fc';
  else if (shortName.includes('haiku')) mColor = '#34d399';
  else if (shortName.includes('glm')) mColor = '#fb923c';
  else if (shortName.includes('gemini')) mColor = '#60a5fa';
  else if (shortName.includes('o1')||shortName.includes('o3')||shortName.includes('gpt')) mColor = '#10b981';

  return '<span style="font-size:10px;padding:1px 6px;border-radius:4px;background:'+mColor+'20;color:'+mColor+';border:1px solid '+mColor+'55;font-weight:600;display:inline-flex;align-items:center;flex:0 0 auto" title="모델: '+esc(topM)+(eff?' | 에포트: '+esc(eff):'')+'">'
    + esc(shortName)
    + tkEffortTag(eff)
    + (entries.length > 1 ? '<span style="font-size:9px;opacity:0.6;margin-left:3px">+' + (entries.length - 1) + '</span>' : '')
    + '</span>';
}

// 모델 칩: 비용 비중 상위 3개 + 에포트 태그
function tkModelChips(models){
  const list=[];
  for(const m in (models||{})){
    const u = models[m] || {};
    list.push({
      name: m.replace(/^claude-/,''),
      cost: tkModelCost(m, u),
      effort: u.effort || '',
      tokens: (u.in || 0) + (u.out || 0)
    });
  }
  if(!list.length) return '';
  const tot=list.reduce((a,x)=>a+x.cost,0);
  list.sort((a,b)=> (b.cost-a.cost) || (b.tokens-a.tokens));
  return list.slice(0,3).map(x=>{
    const effTag = tkEffortTag(x.effort);
    const pct = (tot>0) ? (' '+Math.round(100*x.cost/tot)+'%') : '';
    return '<b>'+esc(x.name)+'</b>'+effTag+pct;
  }).join(' · ')+(list.length>3?' 외':'');
}
// ===== 비용 상세 툴팁 — $ 셀에 마우스를 올리면 모델×과금버킷(입력·캐시읽기·캐시쓰기
// 5분/1시간·출력) 5개를 각각 "토큰수 × 배율 × 단가 = 금액"으로 그대로 펼쳐 보여준다.
// tkModelCost와 같은 산식이라 셀의 $와 툴팁 합계가 항상 일치. 캐시 읽기는 상단 토큰
// 합계(spent)에는 안 들어가지만 비용에는 들어가는 것도 여기서 드러난다.
let _tkTipReg={}, _tkTipN=0;
function tkTipId(models){ const id='tkm'+(++_tkTipN); _tkTipReg[id]=models; return id; }
// title=""는 부모 행의 네이티브 title 툴팁이 커스텀 툴팁 위에 겹쳐 뜨는 것을 차단.
function tkTipAttrs(models){ return ' title="" onmouseenter="tkTipShow(event,\''+tkTipId(models)+'\')" onmousemove="tkTipMove(event)" onmouseleave="tkTipHide()"'; }
function tkTipMoney(v){ if(!(v>0)) return '$0'; return '$'+(v>=100? Math.round(v) : v>=10? v.toFixed(1) : v>=1? v.toFixed(2) : v>=0.01? v.toFixed(3) : v.toFixed(4)); }
function tkTipRate(v){ return '$'+(Math.round(v*1000)/1000)+'/M'; }
function tkCostTipHTML(models){
  const list=[]; for(const m in (models||{})){ const r=tkRate(m); if(r) list.push([m,models[m],r]); }
  if(!list.length) return '';
  list.sort((a,b)=>tkModelCost(b[0],b[1])-tkModelCost(a[0],a[1]));
  const td='padding:1px 7px 1px 0;text-align:right;font-variant-numeric:tabular-nums';
  let total=0, totalTok=0;
  const body=list.map(([m,u,r])=>{
    // 배율은 입력 기본단가 기준(출력만 별도 출력단가) — TK_PRICE 주석과 동일 규칙.
    const buckets=[
      ['입력(신규)',       u.in||0,  '×1',    r[1]],
      ['캐시 읽기',        u.cr||0,  '×0.1',  r[1]*0.1],
      ['캐시 쓰기·5분',    u.c5m||0, '×1.25', r[1]*1.25],
      ['캐시 쓰기·1시간',  u.c1h||0, '×2',    r[1]*2],
      ['출력',             u.out||0, '출력가', r[2]],
    ];
    let sub=0;
    const tr=buckets.map(([lb,tok,mul,rate])=>{
      const amt=tok*rate/1e6; sub+=amt; totalTok+=tok;
      return '<tr'+(tok>0?'':' style="opacity:.35"')+'><td style="padding:1px 10px 1px 0">'+lb+'</td>'
        +'<td style="'+td+'">'+tok.toLocaleString()+'</td>'
        +'<td style="'+td+'">'+mul+'</td>'
        +'<td style="'+td+'">'+tkTipRate(rate)+'</td>'
        +'<td style="'+td.replace(/7px/,'0')+'">'+tkTipMoney(amt)+'</td></tr>';
    }).join('');
    total+=sub;
    return '<div style="margin:7px 0 3px"><b>'+esc(m.replace(/^claude-/,''))+'</b>'
      +' <span class="muted">기본단가: 입력 '+tkTipRate(r[1])+' · 출력 '+tkTipRate(r[2])+'</span></div>'
      +'<table style="border-collapse:collapse;width:100%">'
      +'<tr class="muted"><td style="padding:1px 10px 1px 0">항목</td><td style="'+td+'">토큰</td><td style="'+td+'">배율</td><td style="'+td+'">단가</td><td style="'+td.replace(/7px/,'0')+'">금액</td></tr>'
      +tr
      +'<tr style="border-top:1px solid #2a3140"><td style="padding:2px 10px 1px 0">소계</td><td colspan="3"></td><td style="'+td.replace(/7px/,'0')+'"><b>'+tkTipMoney(sub)+'</b></td></tr>'
      +'</table>';
  }).join('');
  return body
    +(list.length>1? '<div style="margin-top:7px;border-top:1px solid #2a3140;padding-top:4px;text-align:right">합계 <b>'+tkTipMoney(total)+'</b></div>' : '')
    +'<div class="muted" style="margin-top:7px;max-width:360px">단가=$/100만 토큰(MTok). 캐시 읽기=입력단가×0.1, 캐시 쓰기 5분 TTL=×1.25 · 1시간 TTL=×2. 캐시 읽기 토큰은 상단 토큰 합계에는 포함되지 않지만 비용에는 포함됩니다.</div>';
}
function tkTipEl(){ let el=document.getElementById('tkCostTip'); if(!el){
  el=document.createElement('div'); el.id='tkCostTip';
  el.style.cssText='position:fixed;z-index:9999;display:none;background:#171c26;border:1px solid #2a3140;border-radius:8px;padding:9px 12px;font-size:11px;line-height:1.5;box-shadow:0 6px 24px rgba(0,0,0,.55);pointer-events:none;max-width:440px';
  document.body.appendChild(el); } return el; }
function tkTipShow(ev,id){ const m=_tkTipReg[id]; if(!m) return; const el=tkTipEl();
  const html=tkCostTipHTML(m); if(!html) return;
  el.innerHTML=html; el.style.display='block'; tkTipMove(ev); }
function tkTipMove(ev){ const el=document.getElementById('tkCostTip'); if(!el||el.style.display==='none') return;
  const r=el.getBoundingClientRect();
  let x=ev.clientX+14, y=ev.clientY+12;
  if(x+r.width>window.innerWidth-8) x=Math.max(8,ev.clientX-r.width-14);
  if(y+r.height>window.innerHeight-8) y=Math.max(8,ev.clientY-r.height-12);
  el.style.left=x+'px'; el.style.top=y+'px'; }
function tkTipHide(){ const el=document.getElementById('tkCostTip'); if(el) el.style.display='none'; }
// 기간 합산용: 일별 models 맵 병합
function tkMergeModels(days){
  const out={};
  days.forEach(d=>{ const ms=d.models||{}; for(const m in ms){ const u=ms[m], t=out[m]=out[m]||{in:0,cr:0,c5m:0,c1h:0,out:0};
    t.in+=u.in||0; t.cr+=u.cr||0; t.c5m+=u.c5m||0; t.c1h+=u.c1h||0; t.out+=u.out||0; } });
  return out;
}
function renderTokenDaily(){
  reflectTkBtn(); reflectTkMode();
  if(_tkLoopProg===null){ _tkLoopProg=undefined; tkLoadLoopProgress(); }   // 한 번만 부른다
  // 전체 재렌더마다 툴팁 레지스트리 초기화(행이 전부 새로 만들어지므로 누수 방지).
  _tkTipReg={}; _tkTipN=0; tkTipHide();
  const host=$('tokenDailyHost'); if(!host) return;
  // 캐시된 전체에서 선택 범위(_tkStart~_tkEnd)만 골라 렌더. 날짜 문자열(YYYY-MM-DD)은 사전순=시간순.
  let days=(_tkDaily||[]).filter(d=> d.day>=_tkStart && d.day<=_tkEnd);
  if(_tkAccFilter !== 'all'){
    // 고른 계정의 provider. 계정이 provider 를 이미 들고 있으므로 id 접두어를 다시 파싱하지 않는다.
    const accMeta=_tkAccounts.find(a=>a.id===_tkAccFilter);
    const accPrv=accMeta? accMeta.provider : (_tkAccFilter.split(':')[0]||'');
    days = days.map(d=>{
      const accInfo = (d.accounts && d.accounts[_tkAccFilter]) || null;
      if(!accInfo || !(accInfo.tokens>0)) return null;
      const copy = Object.assign({}, d);
      copy.tokens = accInfo.tokens;
      copy.k = Math.round(accInfo.tokens / 1000);
      // 비용과 모델 칩은 그날 전체가 아니라 이 provider 의 모델만 봐야 한다. 안 그러면
      // GLM 으로 걸러 놓고 "비용 $480 (opus-5 93%)" 이 붙어서, 맞는 토큰 수 옆에 틀린
      // 금액이 나란히 선다. 한 줄 안에서 반은 맞고 반은 틀리면 그 줄을 통째로 못 믿는다.
      const mine={}; let any=false;
      for(const m in (d.models||{})){
        if(tkProviderOfModel(m)===accPrv){ mine[m]=d.models[m]; any=true; }
      }
      if(any) copy.models=mine;
      return copy;
    }).filter(Boolean);
  }
  if(_tkModelFilter !== 'all'){
    days = days.map(d=>{
      const models = d.models || {};
      let matchedTokens = 0, matchedModels = {};
      if (_tkModelFilter.startsWith('effort:')) {
        const targetEff = _tkModelFilter.replace('effort:', '').toLowerCase();
        for (const m in models) {
          const u = models[m] || {};
          if ((u.effort || '').toLowerCase().includes(targetEff)) {
            matchedTokens += (u.in || 0) + (u.out || 0);
            matchedModels[m] = u;
          }
        }
      } else {
        const targetM = _tkModelFilter.toLowerCase();
        for (const m in models) {
          if (m.toLowerCase().includes(targetM)) {
            const u = models[m] || {};
            matchedTokens += (u.in || 0) + (u.out || 0);
            matchedModels[m] = u;
          }
        }
      }
      if (!(matchedTokens > 0)) return null;
      const copy = Object.assign({}, d);
      copy.tokens = matchedTokens;
      copy.k = Math.round(matchedTokens / 1000);
      copy.models = matchedModels;
      return copy;
    }).filter(Boolean);
  }
  const rng=$('tokenDailyRange');
  const val=(_tkMode==='val');
  const totalK=days.reduce((a,d)=>a+(d.k||0),0);
  const totalIdx=tkIndex(totalK);
  const totalHrs=days.reduce((a,d)=>a+(d.activeSec||0),0)/3600;
  const curAcc = _tkAccounts.find(a=>a.id===_tkAccFilter);
  const accFilterNotice = curAcc ? (' · <span style="color:'+(curAcc.color||'#8f6fe3')+';font-weight:600">['+esc(curAcc.label)+']</span> 필터') : '';
  let modelFilterNotice = '';
  if (_tkModelFilter !== 'all') {
    const isEff = _tkModelFilter.startsWith('effort:');
    const label = isEff ? ('⚡ ' + _tkModelFilter.replace('effort:', '').toUpperCase()) : _tkModelFilter;
    modelFilterNotice = ' · <span style="color:#38bdf8;font-weight:600">[' + esc(label) + ']</span> 필터';
  }
  // 기간 전체 구성비(컨텍스트 하위 4분할 포함) + 모델별 비용($) + AI 가동 + 프롬프트 리드 평균.
  const sum=k=>days.reduce((a,d)=>a+(d[k]||0),0);
  const anyCtx=days.some(d=>d.reloadTok!=null);   // 구버전 응답(하위 필드 없음) 가드
  const perTot=tkCompStr({tokens:sum('tokens'),inTok:sum('inTok'),thinkTok:sum('thinkTok'),textTok:sum('textTok'),toolTok:sum('toolTok'),
    reloadTok:anyCtx?sum('reloadTok'):null,toolResTok:sum('toolResTok'),typedTok:sum('typedTok'),
    imgTok:sum('imgTok'),imgN:sum('imgN'),imgBytes:sum('imgBytes')},false);
  const merged=tkMergeModels(days), totCost=tkCost(merged), chips=tkModelChips(merged);
  const leadN=sum('leadN'), leadSum=sum('leadSum'), aiTot=sum('aiSec');
  // 기간 전체의 창 점유 분포. 일별 중앙값의 중앙값이다 — 세션별 원값이 여기 없으므로
  // 정확한 전체 중앙값은 못 내지만, 라벨을 그대로 두고 근사치를 감추지 않는다.
  const ctxDays=days.filter(d=>d.ctxMedPct!=null&&d.ctxSessN>0).map(d=>d.ctxMedPct).sort((a,b)=>a-b);
  const ctxDist=ctxDays.length? tkCtxDistStr({ctxMedPct:ctxDays[Math.floor(ctxDays.length/2)],ctxSessN:1,
    ctxHighN:days.reduce((a,d)=>a+((d.ctxSessN>0)?(d.ctxHighN||0):0),0)}) : '';
  const tail=(perTot?'<br>'+perTot:'')
    +(ctxDist? ' · '+ctxDist : '')
    +(totCost>0? ' · 비용 <b style="cursor:help"'+tkTipAttrs(merged)+'>'+tkFmtCost(totCost)+'</b>'+(chips?' ('+chips+')':'') : '')
    +(aiTot>0? ' · AI 가동 <b>'+tkFmtAi(aiTot)+'</b>' : '')
    +(leadN>0?' · 프롬프트 리드 평균 <b>'+tkFmtLead(leadSum/leadN)+'</b> ('+leadN+'회)':'');
  if(rng){
    if(val){
      // [3] 시간효율 배수: (투입지수/시간) ÷ 기준선. 시간 기록이 있어야 계산.
      const rate=totalHrs>0? totalIdx/totalHrs : 0;
      const F=totalHrs>0? rate/BASE_RATE : 0;
      const adj=totalIdx*(F||1);
      rng.innerHTML=(days.length? (days.length+'일 · 투입 <b>'+fmtIdx(totalIdx)+'</b>') : '기간 내 기록 없음')
        +(totalHrs>0? (' · 활성 <b>'+totalHrs.toFixed(1)+'</b>h · 시간효율 <b>×'+F.toFixed(2)+'</b> → 시간보정 <b>'+fmtIdx(adj)+'</b>') : ' · 활성시간 기록 없음')
        +' · 시각 '+tzLabel()+' 기준'+accFilterNotice+modelFilterNotice+tail;
    }else{
      rng.innerHTML=(days.length? (days.length+'일 기록 · 합계 <b>'+fmtTokenK(totalK)+'</b>') : '기간 내 토큰 기록 없음')+' · 시각 '+tzLabel()+' 기준'+accFilterNotice+modelFilterNotice+tkLoopProgStr()+tail;
    }
  }
  if(!days.length){ host.innerHTML='<div class="empty">선택한 기간('+_tkStart+' ~ '+_tkEnd+') 및 필터에 토큰 기록이 없습니다</div>'; return; }
  const mx=Math.max(1,...days.map(d=>d.k||0));
  const todayStr=histDayStr(new Date());
  host.innerHTML=days.map(d=>{
    const k=d.k||0, w=Math.round(100*k/mx);
    // 스택 막대: 하루 길이는 기간 최대치 대비, 내부는 입력·생각·응답·도구 구성비.
    const spent=d.tokens||0;
    let inner;
    if(spent>0 && d.inTok!=null){
      const seg=(v,c)=>'<div style="height:9px;width:'+(100*(v||0)/spent)+'%;background:'+c+'"></div>';
      inner='<div style="display:flex;height:9px;width:'+w+'%;border-radius:4px;overflow:hidden">'
        +tkCtxSegs(d,seg)+seg(d.thinkTok,'#e8a13a')+seg(d.textTok,'#8f6fe3')+seg(d.toolTok,'#4f79c9')+'</div>';
    }else{
      inner='<div style="position:absolute;left:0;top:0;height:9px;border-radius:4px;width:'+w+'%;background:#8f6fe3"></div>';
    }
    const bar='<div style="position:relative;background:#2a2f3a;border-radius:4px;height:9px;width:180px;flex:0 0 auto">'+inner+'</div>';
    const hrs=(d.activeSec||0)/3600;
    const ai=(d.aiSec>0)? ' · AI '+tkFmtAi(d.aiSec) : '';
    const meta=val
      ? '<span class="muted" style="font-size:11px">세션 '+(d.sessions||0)+' · '+hrs.toFixed(1)+'h'+ai+'</span>'
      : '<span class="muted" style="font-size:11px">세션 '+(d.sessions||0)+'개'+ai+'</span>';
    const comp=tkCompStr(d,true);
    const cost=tkCost(d.models);
    const lead=(d.leadN>0)? '리드 <b>'+tkFmtLead(d.leadMed)+'</b>·'+d.leadN+'회' : '';
    const chips=tkModelChips(d.models);
    const dist=tkCtxDistStr(d);   // 창 점유 분포 — 옛 응답이면 빈 문자열
    // 툴팁은 실제로 그려진 조각만 설명한다. 옛 응답에는 dist 가 빈 문자열인데 툴팁이 창 점유
    // 분포를 약속하고 있으면, 없는 것을 찾느라 사람이 행을 뒤진다.
    const extraTip='구성비(컨텍스트·생각·응답·도구)와 다음 프롬프트까지 리드 중앙값'+(dist?', 그리고 그날 세션들의 창 점유 분포':'');
    const extra=(comp||lead||dist)? '<span class="muted" style="font-size:11px" title="'+extraTip+'">'+comp+(comp&&lead?' · ':'')+lead+((comp||lead)&&dist?' · ':'')+dist+'</span>' : '';
    const costCell=cost>0? '<b style="font-variant-numeric:tabular-nums;min-width:64px;text-align:right;color:#7fc98f;cursor:help"'+tkTipAttrs(d.models)+'>'+tkFmtCost(cost)+'</b>' : '';
    const open=_tkSessOpen.has(d.day);
    return '<div class="panel" style="margin:0 0 6px;padding:8px 14px">'
      +'<div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;cursor:pointer" onclick="tkDayToggle(\''+d.day+'\')" title="클릭하면 그날 세션별 상세를 펼칩니다">'
      +'<span class="muted" style="width:10px;flex:0 0 auto">'+(open?'▾':'▸')+'</span>'
      +'<b style="font-variant-numeric:tabular-nums;min-width:150px'+(d.day===todayStr?';color:#e8a13a':'')+'">'+esc(tkDayLabel(d.day))+'</b>'
      +bar
      +'<b style="font-variant-numeric:tabular-nums;min-width:90px;text-align:right">'+tkAmount(k)+'</b>'
      +costCell
      +meta
      +extra
      +'</div>'
      +(open? tkSessListHTML(d.day) : '')
      +'</div>';
  }).join('');
}

// ===== 세션별 드릴다운 — 일 행 클릭 → /tokens-sessions.json?day= 로 그날 세션 전수 상세.
// "컨텍스트 82%가 말이 되나"를 세션 단위로 검증하는 용도: 세션마다 토큰·$·구성비·모델·리드.
let _tkSessOpen=new Set(), _tkSessCache={};   // day -> rows(배열) | 'loading'
function tkDayToggle(day){
  if(_tkSessOpen.has(day)){ _tkSessOpen.delete(day); renderTokenDaily(); return; }
  _tkSessOpen.add(day);
  if(!_tkSessCache[day]){
    _tkSessCache[day]='loading';
    fetch('/tokens-sessions.json?day='+day).then(x=>x.json())
      .then(j=>{ _tkSessCache[day]=(j&&j.sessions)||[]; renderTokenDaily(); })
      .catch(()=>{ _tkSessCache[day]=[]; renderTokenDaily(); });
  }
  renderTokenDaily();
}
// 루프 배지. 등록된 루프는 파랑, 기계가 반복해서 연 미등록 루프 후보는 노랑, 사람이 연 세션은
// 배지를 달지 않는다 — 대부분이 사람 세션이라 전부 달면 배지가 배경이 되어 아무것도 안 보인다.
function tkLoopBadge(s){
  const kind=s.loopKind||'', label=(s.loop||'').trim();
  if(!label||kind==='human') return '';
  const st=(kind==='loop')
    ? 'background:#1a2336;border:1px solid #263149;color:#9fb6e8'
    : 'background:#2a2312;border:1px solid #4a3d1a;color:#d29922';
  // 미등록 루프의 이름은 그 루프가 매번 보내는 첫 프롬프트 그 자체다. 옆 칸의 세션 제목도
  // 같은 문장이라 그대로 달면 같은 글자가 두 번 나온다. 그럴 때는 배지에서 이름을 빼고
  // '루프 반복'만 남긴다 — 배지가 답해야 하는 것은 이름이 아니라 "사람이 연 게 아니다"다.
  const title=((s.title||'').trim());
  const dup=label.length>8 && title.slice(0,12)===label.slice(0,12);
  const text=dup? (kind==='loop'?'루프':'루프 반복') : label;
  return '<span style="'+st+';font-size:10px;padding:1px 7px;border-radius:20px;flex:0 0 auto;max-width:150px;'
    +'overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="'+esc((kind==='loop'?'등록된 루프: ':'미등록 루프 후보: ')+label)+'">'
    +esc(text)+'</span>';
}
// 세션 판정이 어디까지 됐는지. 토큰 뷰 머리줄에 한 줄로만 적는다 — 여기서 전량을 그리면
// 목록이 무거워지고, 자세한 것은 루프 엔지니어링 화면이 소유한다.
let _tkLoopProg=null;
function tkLoadLoopProgress(){
  fetch('/api/loop-engineering/sessions?summary=1').then(x=>x.json())
    .then(j=>{ _tkLoopProg=j; renderTokenDaily(); }).catch(()=>{});
}
function tkLoopProgStr(){
  const j=_tkLoopProg; if(!j||!j.progress) return '';
  const p=j.progress, t=j.totals||{};
  const done=(p.total||0)-(p.pending||0);
  const head=p.running? ('세션 판정 '+done+'/'+(p.total||0)+' 분석 중') : ('세션 판정 '+(p.analyzed||0)+'/'+(p.total||0)+' 완료');
  const lp=t.loop||{}, cd=t.candidate||{};
  const n=(lp.sessions||0)+(cd.sessions||0);
  return ' · <span title="루프를 돌리려고 열린 세션과 사람이 연 세션의 구분 — 자세한 것은 루프 엔지니어링 화면">'
    +head+(n? (' · 루프 세션 '+n+'개') : '')+'</span>';
}
function tkSessListHTML(day){
  const rawRows=_tkSessCache[day];
  if(rawRows==='loading'||!rawRows) return '<div class="muted" style="font-size:11px;padding:6px 0 0 22px">세션 불러오는 중…</div>';
  const rows = rawRows.filter(s => {
    if (_tkAccFilter !== 'all' && s.account !== _tkAccFilter && s.provider !== _tkAccFilter) return false;
    if (_tkModelFilter !== 'all') {
      if (_tkModelFilter.startsWith('effort:')) {
        const targetEff = _tkModelFilter.replace('effort:', '').toLowerCase();
        const sEff = (s.effort || '').toLowerCase();
        let match = sEff.includes(targetEff);
        if (!match && s.models) {
          match = Object.values(s.models).some(u => (u.effort || '').toLowerCase().includes(targetEff));
        }
        if (!match) return false;
      } else {
        const targetM = _tkModelFilter.toLowerCase();
        let match = (s.models && Object.keys(s.models).some(m => m.toLowerCase().includes(targetM)));
        if (!match && s.provider && s.provider.toLowerCase().includes(targetM)) match = true;
        if (!match) return false;
      }
    }
    return true;
  });
  if(!rows.length) return '<div class="muted" style="font-size:11px;padding:6px 0 0 22px">선택한 필터 조건의 세션이 없습니다</div>';
  const mx=Math.max(1,...rows.map(s=>s.tokens||0));
  return '<div style="margin:8px 0 0 22px;border-top:1px solid #222a36;padding-top:6px">'
    +rows.map(s=>{
      const spent=s.tokens||0, w=Math.round(100*spent/mx);
      const seg=(v,c)=>'<div style="height:7px;width:'+(100*(v||0)/(spent||1))+'%;background:'+c+'"></div>';
      const bar='<div style="position:relative;background:#2a2f3a;border-radius:4px;height:7px;width:120px;flex:0 0 auto">'
        +'<div style="display:flex;height:7px;width:'+w+'%;border-radius:4px;overflow:hidden">'
        +tkCtxSegs(s,seg)+seg(s.thinkTok,'#e8a13a')+seg(s.textTok,'#8f6fe3')+seg(s.toolTok,'#4f79c9')+'</div></div>';
      const cost=tkCost(s.models), chips=tkModelChips(s.models);
      const title=(s.title||'').trim() || (s.proj+' · '+s.sid);
      const PRV_FALLBACK={codex:['코덱스','#059669'],antigravity:['안티그라비티','#ea580c'],glm:['GLM','#fb923c']};
      const prvFb=PRV_FALLBACK[s.provider]||['클로드','#7c3aed'];
      const accLabel = s.accountLabel || prvFb[0];
      const accColor = s.accountColor || prvFb[1];
      const accBadge = '<span style="font-size:10px;padding:1px 6px;border-radius:4px;background:'+accColor+'22;color:'+accColor+';border:1px solid '+accColor+'66;font-weight:600;flex:0 0 auto" title="'+esc(s.account||s.provider||'')+'">'+esc(accLabel)+'</span>';
      const modelBadge = tkSessionModelBadge(s);
      const lp=tkLoopBadge(s);
      const lead=((s.aiSec>0)? ' · AI '+tkFmtAi(s.aiSec) : '')
        +((s.leadN>0)? ' · 리드 '+tkFmtLead(s.leadMed)+'·'+s.leadN+'회' : '');
      const cw=tkCtxWinStr(s);   // 창 점유 칩 — 옛 응답이면 빈 문자열이라 아무것도 안 붙는다
      const detKey=day+'|'+s.sid, detOpen=_tkDetOpen.has(detKey);
      return '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:3px 0">'
        +accBadge
        +modelBadge
        +lp
        +'<span style="font-size:11px;min-width:180px;max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="'+esc(s.proj+' · '+s.sid+' — '+(s.title||''))+'">'+esc(title)+'</span>'
        +bar
        +'<b style="font-size:11px;font-variant-numeric:tabular-nums;min-width:56px;text-align:right">'+tkAmount(s.k||0)+'</b>'
        +(cost>0? '<b style="font-size:11px;font-variant-numeric:tabular-nums;min-width:52px;text-align:right;color:#7fc98f;cursor:help"'+tkTipAttrs(s.models)+'>'+tkFmtCost(cost)+'</b>' : '')
        +'<span class="muted" style="font-size:11px;cursor:pointer;text-decoration:underline dotted" onclick="event.stopPropagation();tkSessDetailToggle(\''+day+'\',\''+esc(s.sid)+'\')" title="클릭: 이 구성비의 실제 내용물(무엇이 토큰을 먹었는지)을 항목별로 펼칩니다">'+(detOpen?'▾ ':'')+(cw? cw+' · ' : '')+tkCompStr(s,true)+(chips?' · '+chips:'')+lead+'</span>'
        +'</div>'
        +(detOpen? tkDetailHTML(day,s.sid) : '');
    }).join('')
    +'</div>';
}

// ===== 버킷 내용물 드릴다운 — 세션 행의 구성비를 클릭하면 그 세션·그날의 컨텍스트가 실제로
// 무엇이었는지 항목 단위·큰 순서로 보여준다("컨텍스트 86%"의 정체). 재적재=턴별 재캐시(어느
// 시점부터 히스토리가 무거워졌나), 도구결과=어느 도구가 무엇을 읽어왔나(파일 경로·명령),
// 타이핑=친 프롬프트 원문 머리, 사진=형식·해상도·용량. 목적: 세션을 열어 뒤지지 않고도
// "무엇이 토큰을 먹는지 → 무엇을 잘라낼지"를 여기서 판단.
let _tkDetOpen=new Set(), _tkDetCache={}, _tkDetMore=new Set();
function tkSessDetailToggle(day,sid){
  const key=day+'|'+sid;
  if(_tkDetOpen.has(key)){ _tkDetOpen.delete(key); renderTokenDaily(); return; }
  _tkDetOpen.add(key);
  if(!_tkDetCache[key]){
    _tkDetCache[key]='loading';
    fetch('/tokens-detail.json?sid='+encodeURIComponent(sid)+'&day='+day).then(x=>x.json())
      .then(j=>{ _tkDetCache[key]=(j&&j.items)||{}; renderTokenDaily(); })
      .catch(()=>{ _tkDetCache[key]={}; renderTokenDaily(); });
  }
  renderTokenDaily();
}
function tkFmtTok(t){ if(!(t>0)) return '0'; if(t<1000) return String(t); const k=t/1000; return (k>=100? Math.round(k) : k.toFixed(1))+'K'; }
function tkDetMoreToggle(key){ if(_tkDetMore.has(key)) _tkDetMore.delete(key); else _tkDetMore.add(key); renderTokenDaily(); }
function tkDetailHTML(day,sid){
  const key=day+'|'+sid, d=_tkDetCache[key];
  if(d==='loading'||!d) return '<div class="muted" style="font-size:11px;padding:4px 0 4px 34px">내용물 불러오는 중…</div>';
  const SECS=[['reload','재적재 — 턴별 재캐시 (히스토리가 무거워진 지점·모델)','#8b98b8'],
              ['toolres','도구결과 — 어느 도구가 무엇을 읽어왔나','#54627f'],
              ['typed','타이핑 — 직접 친 프롬프트','#96a5c8'],
              ['img','사진 — 첨부 이미지 (형식·해상도·용량)','#c8b1e8']];
  let h='<div style="margin:4px 0 8px 34px;padding:6px 10px;border:1px solid #222a36;border-radius:6px">';
  let any=false;
  SECS.forEach(sec=>{
    const k=sec[0], label=sec[1], color=sec[2];
    const s=d[k]; const list=(s&&s.list)||[];
    if(!list.length) return;
    any=true;
    const tot=list.reduce((a,x)=>a+(x.tok||0),0)+((s.moreTok)||0);
    const mkey=key+'|'+k, moreOpen=_tkDetMore.has(mkey);
    const shown=moreOpen? list : list.slice(0,12);
    h+='<div style="margin:4px 0"><div class="muted" style="font-size:11px;margin:2px 0"><span style="color:'+color+'">■</span> <b>'+label+'</b> · '+(list.length+((s.moreN)||0))+'건 · '+tkFmtTok(tot)+'</div>'
      +shown.map(x=>'<div style="display:flex;gap:8px;font-size:11px;padding:1px 0 1px 14px">'
        +'<span class="muted" style="flex:0 0 34px">'+esc(x.t||'')+'</span>'
        +'<span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="'+esc(x.label||'')+'">'+esc(x.label||'')
        +(x.bytes? ' <span class="muted">('+tkFmtMB(x.bytes)+')</span>':'')+'</span>'
        +'<b style="flex:0 0 52px;text-align:right;font-variant-numeric:tabular-nums">'+tkFmtTok(x.tok)+'</b></div>').join('');
    const hidden=list.length-shown.length, extraN=(s.moreN)||0;
    if(hidden>0||extraN>0) h+='<div class="muted" style="font-size:11px;padding:1px 0 1px 14px;cursor:pointer;text-decoration:underline dotted" onclick="event.stopPropagation();tkDetMoreToggle(\''+mkey+'\')">'
      +(moreOpen? '접기' : ('외 '+(hidden+extraN)+'건 더보기'+((s.moreTok)? ' · '+tkFmtTok(s.moreTok):'')))+'</div>';
    h+='</div>';
  });
  if(!any) h+='<div class="muted" style="font-size:11px">이 날짜의 내용물이 없습니다</div>';
  h+='</div>';
  return h;
}
function renderTokenView(r){
  const all=(r&&r.goals)||[]; _goals=all;
  updateFilterButtons();
  loadTokenDaily();   // 일별 실토큰 타임라인(트랜스크립트 합산) — 캐시되어 재호출은 무비용
  const host=$('tokenHost'); if(!host) return;
  // 완료된 목표만: 상태 콤보와 무관하게 done만 본다(토큰 뷰의 본분). 기간은 위 일별 타임라인과
  // 같은 필터(_tkStart~_tkEnd)를 완료일 기준으로 그대로 적용한다 — "어제"를 누르면 어제 완료된
  // 것만 나온다. 루프 콤보·완료 컷오프 같은 다른 뷰의 필터는 여기에 개입하지 않는다(2026-08-09:
  // 루프 그룹핑은 날짜와 기준이 엇갈려 혼란만 줘서 폐기, 완료일이 유일한 축).
  const inRange=c=>{ if(!c) return false; const d=tkDayStr(c); return d>=_tkStart && d<=_tkEnd; };
  const list=all.filter(g=>!g.released && effStatus(g,all)==='done' && inRange(goalCompletedAt(g,all)));
  if(!list.length){ host.innerHTML='<div class="muted" style="padding:8px 0">선택한 기간('+_tkStart+' ~ '+_tkEnd+')에 완료된 목표가 없습니다.</div>'; return; }
  const sumTok=gs=>gs.reduce((a,g)=>a+(g.tokens||0),0);
  const total=sumTok(list);
  // 완료일별 분배 — 최근 날짜 먼저, 하루 안에서는 완료 최신순.
  const byDay={};
  list.forEach(g=>{ const d=tkDayStr(goalCompletedAt(g,all)); (byDay[d]=byDay[d]||[]).push(g); });
  const dayKeys=Object.keys(byDay).sort().reverse();   // 'YYYY-MM-DD' 사전순=시간순
  const newestFirst=(a,b)=>(goalCompletedAt(b,all)-goalCompletedAt(a,all))||((b.seq||0)-(a.seq||0));
  let h='<div class="tksum">'
    +'<span><span class="k">합계</span> <span class="big">'+tkAmount(total)+'</span> <span class="k">· 완료 '+list.length+'개 · '+dayKeys.length+'일</span></span>'
    +'</div>';
  const todayStr=histDayStr(new Date());
  dayKeys.forEach(d=>{
    const gs=byDay[d]; gs.sort(newestFirst);
    h+='<div class="schsec'+(d===todayStr?' today':'')+'">'
      +'<div class="schsec-hd">'+esc(tkDayLabel(d))+'<span class="cnt">'+gs.length+'개</span>'
      +'<span class="tot">'+tkAmount(sumTok(gs))+'</span></div>'
      +gs.map(g=>tkRow(g,all)).join('')+'</div>';
  });
  host.innerHTML=h;
}

// ===== 루프 뷰 — Jira식 백로그 보드 (루프 그룹 + Backlog + 완료 로그) =====
const DUR_OPTS=[['1d','1일'],['2d','2일'],['3d','3일'],['1w','1주'],['2w','2주'],['1m','1달']];
function durLabel(k){ const o=DUR_OPTS.find(x=>x[0]===k); return o?o[1]:k; }
let _spCollapsed=new Set();  // collapsed groups (sprint number, 'bg' for Backlog, or 'bump' for Bump out)
let _bgCollapsed=new Set();  // collapsed parent goal ids (자식 접기) within a group
let _bgSeen=new Set();       // parents already defaulted-collapsed (so the 5s re-render never re-collapses one the user opened)
let _relOpen=new Set();      // expanded release ids (완료 로그는 기본 닫힘)
let _relLogOpen=false;       // 완료 로그 섹션 전체 펼침 (기본 접힘 — 접히면 아이템 DOM을 아예 만들지 않아 노드 수를 줄인다)
// 루프 코드(26-1) 조회 — 일일 목록의 스프 배지 등에서 사용.
function sprintCode(n){ if(!n) return ''; const s=((_review&&_review.sprints)||[]).find(x=>x.number===n); return (s&&s.code)?s.code:('#'+n); }
function statLabel2(s){ const m={backlog:'대기',in_progress:'진행',waiting:'응답 대기',stopped:'중지',cancelled:'취소',done:'완료'}; return m[s]||s; }
function renameGoal(id,v){ const t=String(v||'').trim(); if(!t) return; post('/api/goal/title',{id:id,title:t}); }

// ===== 전체 목록 검색 뷰 — 활성·아카이브(릴리즈) 목표를 모두 한곳에서 검색·검토 =====
// 목적 두 가지: (1) 릴리즈로 비워진 목표까지 포함해 모든 목표를 한 화면에서 본다.
// (2) 두 가지 검색 — 일반(글자 일치, 즉시)과 AI(의미 유사, claude -p로 비슷한 것 모두). 기본은 AI.
// AI 검색은 서버 왕복이라 버튼/Enter로만 실행하고, 일반 검색·입력 변경은 클라이언트에서 즉시 반영.
let _archQuery='';                  // 검색어
let _archMode='ai';                 // 'ai' | 'plain' — 기본 AI
let _archAi=null;                   // AI 결과: {seqs:[...정렬된 seq], why:{seq:사유}, q:질의} 또는 null
let _archBusy=false;                // AI 검색 진행 중
function onArchInput(v){
  _archQuery=String(v||'');
  // 입력이 바뀌면 직전 AI 결과는 더 이상 이 질의와 무관 — 비우고(질의가 보존된 동안만 유효),
  // 일반 모드면 즉시 글자 필터를 다시 적용한다.
  if(_archAi && _archAi.q!==_archQuery.trim()) _archAi=null;
  if(_review) renderArchivedView(_review);
}
function archKey(e){ if(e.key==='Enter'){ e.preventDefault(); (_archMode==='plain'?archPlainSearch:archAiSearch)(); } }
function archClear(){ _archQuery=''; _archAi=null; const el=$('archSearch'); if(el) el.value=''; if(_review) renderArchivedView(_review); }
// 검색 사용법: AI 검색 버튼 우클릭으로 설명을 펼치고 접는다.
function archToggleHelp(){ const h=$('archHelp'); if(!h) return; h.style.display=(h.style.display!=='none')?'none':'block'; }
// 일반 검색: 글자 일치. 즉시 클라이언트에서 처리.
function archPlainSearch(){ _archMode='plain'; _archAi=null; if(_review) renderArchivedView(_review); }
// AI 검색: 내용을 서버로 보내 의미가 비슷한 목표를 모두 찾는다 (claude -p). 비어 있으면 전체 표시.
function archAiSearch(){
  _archMode='ai';
  const q=_archQuery.trim();
  if(!q){ _archAi=null; if(_review) renderArchivedView(_review); return; }
  if(_archBusy) return;
  _archBusy=true; const btn=$('archAiBtn'); const orig=btn?btn.textContent:''; if(btn){ btn.disabled=true; btn.textContent='AI 검색 중…'; }
  const sum=$('archSummary'); if(sum) sum.textContent='— AI가 비슷한 목표를 찾는 중…';
  fetch('/api/goal/aiSearch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({query:q})})
    .then(r=>r.json())
    .then(res=>{
      if(!res||!res.ok){ _archAi={seqs:[],why:{},q:q,err:(res&&res.error)||'failed'}; }
      else{
        const seqs=[], why={};
        (res.matches||[]).forEach(m=>{ seqs.push(m.seq); why[m.seq]=m.why||''; });
        _archAi={seqs:seqs,why:why,q:q};
      }
    })
    .catch(()=>{ _archAi={seqs:[],why:{},q:q,err:'network'}; })
    .finally(()=>{ _archBusy=false; if(btn){ btn.disabled=false; btn.textContent=orig; } if(_review) renderArchivedView(_review); });
}
function renderArchivedView(r){
  const all=(r&&r.goals)||[]; _goals=all;
  updateFilterButtons();
  const host=$('archivedList'), sum=$('archSummary');
  const aiBtn=$('archAiBtn'), plBtn=$('archPlainBtn');
  if(aiBtn) aiBtn.classList.toggle('primary',_archMode==='ai');
  if(plBtn) plBtn.classList.toggle('primary',_archMode==='plain');
  const relById={}; ((r&&r.releases)||[]).forEach(rel=>{ relById[rel.id]=rel; });
  const codeOf={}; ((r&&r.sprints)||[]).forEach(s=>{ codeOf[s.number]=s.code||('#'+s.number); });
  const bySeq={}; all.forEach(g=>{ bySeq[g.seq]=g; });
  const q=_archQuery.trim();
  let list, whyOf=null;
  if(_archMode==='ai' && _archAi){
    // AI 결과 순서(관련도 높은 순)대로 해당 목표를 배열
    list=_archAi.seqs.map(s=>bySeq[s]).filter(Boolean);
    whyOf=_archAi.why;
  }else if(_archMode==='plain' && q){
    const lq=q.toLowerCase();
    list=all.filter(g=>{
      const rel=relById[g.releaseId];
      const sp=(g.sprint>0)?codeOf[g.sprint]:((rel&&rel.sprint>0)?codeOf[rel.sprint]:'');
      return (gnum(g)+' '+(g.text||'')+' '+(sp||'')).toLowerCase().indexOf(lq)>=0;
    });
    // 전체 보기와 동일하게 번호순
    list.sort((a,b)=>(a.seq||0)-(b.seq||0));
  }else{
    // 검색 없음 → 전체 목표를 번호순으로
    list=all.slice().sort((a,b)=>(a.seq||0)-(b.seq||0));
  }
  // 보기 상태 필터를 아카이브 검색에도 동일하게 적용 — 완료를 끄면 여기서도 숨긴다.
  // (다른 뷰와 일관: 릴리즈/아카이브 여부는 여기서 가리지 않는다 — 그게 이 뷰의 존재 이유)
  const _archTotal=list.length;
  list=list.filter(g=>!!_statusFilter[effStatus(g,all)]);
  // 요약 라벨
  if(sum){
    if(_archMode==='ai' && _archAi){
      sum.textContent=_archAi.err ? ('— AI 검색 실패('+_archAi.err+') — 일반 검색을 사용하세요')
        : ('— AI 검색 「'+_archAi.q+'」 · '+list.length+'개');
    }else if(_archMode==='plain' && q){
      sum.textContent='— 일반 검색 · '+list.length+' / '+all.length+'개';
    }else if(list.length!==_archTotal){
      sum.textContent='— '+list.length+' / 전체 '+all.length+'개 (보기 상태 필터 적용)';
    }else{
      sum.textContent='— 전체 '+all.length+'개 (아카이브 포함)';
    }
  }
  if(!all.length){ host.innerHTML='<div class="muted" style="padding:4px 0">목표가 없습니다.</div>'; return; }
  if(!list.length){
    const msg=(_archMode==='ai'&&_archAi&&!_archAi.err)?'AI가 비슷한 목표를 찾지 못했습니다.':'검색 결과가 없습니다.';
    host.innerHTML='<div class="muted" style="padding:4px 0">'+msg+'</div>'; return;
  }
  host.innerHTML=list.map(function(g){
    const rel=g.released?relById[g.releaseId]:null;
    const sn=(g.sprint>0)?g.sprint:((rel&&rel.sprint>0)?rel.sprint:0);
    const spLab=sn?('<span class="spbadge">'+esc(sprintCode(sn))+'</span>'):'';
    const st=effStatus(g,all);
    const stLab='<span class="ot '+st+'" style="font-size:11px">'+statLabel2(st)+'</span>';
    // 꼬리표: 보관(수동) → '보관 해제', 릴리즈(커밋) → '복원', 활성이면 없음
    const tail=g.archived
      ? ('<span class="muted" style="font-size:12px;white-space:nowrap">보관됨</span>'
         +'<button class="btn" onclick="archiveGoal(\''+g.id+'\',false)" title="보관을 해제해 활성 목록으로 되돌립니다">보관 해제</button>')
      : (g.released
        ? ('<span class="muted" style="font-size:12px;white-space:nowrap">아카이브 · 릴리즈 '+((rel&&rel.releasedAt)?fmtDate(rel.releasedAt):'–')+'</span>'
           +(rel?'<button class="btn" onclick="restoreRelease(\''+rel.id+'\')" title="이 릴리즈를 복원해 활성 목록으로 되돌립니다">복원</button>':''))
        : '');
    const why=(whyOf&&whyOf[g.seq])?('<div class="muted" style="font-size:12px;margin-top:2px">↳ '+esc(whyOf[g.seq])+'</div>'):'';
    return '<div class="goal" style="flex-wrap:wrap'+((g.released||g.archived)?';opacity:.72':'')+'">'
      +gpill(g)+spLab+stLab
      +'<span class="g"><span class="gt" title="'+esc(g.text)+'">'+esc(g.text)+'</span>'+why+'</span>'
      +tail
    +'</div>';
  }).join('');
}
function renderSprintView(r){ renderSprintBoard(r); }
function renderSprintBoard(r){
  const all=(r&&r.goals)||[]; _goals=all;
  // Parent rows (those with children) open COLLAPSED by default — an expanded board is
  // tiring; collapsed reads simpler. Apply once per parent (tracked in _bgSeen) so a row
  // the user later expands stays open across the 5s poll re-render, and newly added
  // parents still start closed.
  new Set(all.filter(g=>g.parent).map(g=>g.parent)).forEach(id=>{ if(!_bgSeen.has(id)){ _bgSeen.add(id); _bgCollapsed.add(id); } });
  updateFilterButtons();
  const sprints=((r&&r.sprints)||[]).filter(s=>!s.closed).sort((a,b)=>a.number-b.number);
  const shown=all.filter(g=>goalPassesBoard(g,all));   // 상태 필터·완료 컷오프 적용 (행)
  const allLive=all.filter(g=>!g.released);            // 카운트는 전체 멤버십 기준
  let h=sprints.map(s=>sprintGroupHTML(s,shown,allLive)).join('');
  h+=backlogHTML(shown,allLive);
  h+=bumpHTML(shown,allLive);          // Backlog 아래: 정리 전 아이디어 인박스
  h+=completedLogHTML(r);
  $('sprintHost').innerHTML=h;
  if(_spModalNum!=null) fillSprintModal();   // 열려 있으면 최신 데이터로 갱신(기간 변경 시 목표일 반영)
  if(_relModalId!=null) fillRelModal();      // 릴리즈 편집 모달도 최신 데이터로 갱신
}
// 상태 카운트 배지 (대기 · 진행 · 완료)
function countsHTML(members){
  let bk=0,ip=0,dn=0;
  members.forEach(g=>{ const s=effStatus(g,_goals); if(s==='done')dn++; else if(s==='in_progress')ip++; else bk++; });
  return '<span class="spcount"><span title="대기">'+bk+'</span><span class="ip" title="진행">'+ip+'</span><span class="dn" title="완료">'+dn+'</span></span>';
}
// 목표 날짜 + D-day
function ddayHTML(t){
  if(!t) return '<span class="dd muted">날짜 미정</span>';
  const days=Math.ceil((t-Date.now()/1000)/86400);
  const lab=days>0?('D-'+days):(days===0?'D-DAY':('D+'+(-days)));
  return '<span class="dd'+(days<=1?' soon':'')+'">'+fmtDate(t)+' · '+lab+'</span>';
}
// PC방 남은 시간 카운트다운. D-day 대신 실제 잔여 시간(HH:MM:SS)을 1초마다 표시해
// 집중을 유도한다. 30분 전(1800초)부터 빨강, 만료되면 00:00:00 으로 깜빡인다.
// 클릭하면 마감 조정 모달(연장·단축·직접 지정)이 열린다. data-target = 마감 epoch(초).
const CD_SOON=1800;   // 30분 — 이 시점부터 빨간색
function cdRemain(t){ return Math.floor(t-Date.now()/1000); }
function fmtCD(sec){ sec=Math.max(0,sec); const h=(sec/3600)|0,m=((sec%3600)/60)|0,s=sec%60,p=n=>(n<10?'0':'')+n; return p(h)+':'+p(m)+':'+p(s); }
// 남은 시간에 따른 표시 텍스트와 상태 클래스를 함께 돌려준다(틱·최초 렌더 공용).
function cdState(t){ const r=cdRemain(t);
  if(r<=0) return {txt:'00:00:00',soon:false,over:true};
  return {txt:fmtCD(r),soon:r<=CD_SOON,over:false}; }
function sprintCountdownHTML(s){
  const t=s.targetAt||0;
  if(!t) return '<span class="spcd muted" title="목표일 미정 — 클릭하여 설정" onclick="event.stopPropagation();openSprintModal('+s.number+')">날짜 미정</span>';
  const c=cdState(t);
  return '<span class="spcd'+(c.soon?' soon':'')+(c.over?' over':'')+'" data-target="'+t+'"'
    +' title="남은 시간 — 클릭하여 마감 조정(연장·단축·직접 지정)" onclick="event.stopPropagation();openExtendModal('+s.number+')">'+c.txt+'</span>';
}
// 매초 모든 카운트다운 칩을 갱신한다(renderSprintBoard 사이에도 부드럽게 흐르도록).
function tickSprintCD(){ document.querySelectorAll('.spcd[data-target]').forEach(function(el){
  const t=+el.getAttribute('data-target')||0; if(!t) return; const c=cdState(t);
  el.textContent=c.txt; el.classList.toggle('soon',c.soon); el.classList.toggle('over',c.over);
}); }
setInterval(tickSprintCD,1000);
// --- 마감 조정 모달 (2시간 단위 연장·단축 + 직접 지정) ---
// _extHours: 상대 조정량(시간). 양수=연장, 음수=단축, 0=변경 없음.
// _extAbs:  직접 지정한 절대 마감(epoch 초). >0이면 상대 조정보다 우선.
// 두 입력 모두 즉시 적용하지 않고 "조정 후" 미리보기에만 반영한 뒤, 하단 버튼에서 확정한다.
let _extNum=null,_extHours=0,_extAbs=0;
function openExtendModal(n){ _extNum=n; _extHours=0; _extAbs=0; fillExtendModal(); const m=$('extModal'); if(m) m.style.display='flex'; }
function closeExtendModal(){ _extNum=null; const m=$('extModal'); if(m) m.style.display='none'; }
function extStep(d){ _extHours=_extHours+d*2; _extAbs=0; fillExtendModal(); }   // 2시간 단위(양수 연장·음수 단축)·직접 지정 취소
function extSprint(){ return ((_review&&_review.sprints)||[]).find(x=>x.number===_extNum); }
function fillExtendModal(){ if(_extNum==null) return; const s=extSprint(); if(!s){ closeExtendModal(); return; } const b=$('extModalBox'); if(b) b.innerHTML=extModalForm(s); }
// 상대 조정 기준점: 아직 남았으면 현재 마감(잔여 보존), 이미 지났으면 지금.
function extBase(s){ const t=s.targetAt||0; return Math.max(Date.now()/1000,t); }
// 현재 입력으로 만들어질 최종 마감(epoch). 직접 지정이 있으면 그 값, 아니면 상대 조정 결과, 둘 다 없으면 0.
function extPreviewAt(){ const s=extSprint(); if(!s) return 0;
  if(_extAbs) return _extAbs; if(_extHours===0) return 0; return Math.floor(extBase(s)+_extHours*3600); }
function extDirty(){ return _extAbs>0 || _extHours!==0; }
function extApplyLabel(){ if(_extAbs>0) return '이 시각으로 설정';
  const mag=Math.abs(_extHours); if(_extHours>0) return mag+'시간 연장'; if(_extHours<0) return mag+'시간 단축'; return '변경 없음'; }
// 직접 지정 입력: 값만 예약(스테이징)하고 미리보기·버튼만 부분 갱신한다. 여기서 모달을
// 통째로 다시 그리면 입력 도중 포커스가 튕겨(분을 못 넣고 닫힘) 버리므로 재렌더하지 않는다.
function extSetAbs(val){ _extAbs=CMTimeFilter.inputToEpoch(val); if(_extAbs) _extHours=0;
  const pv=$('extPrev'); if(pv){ const nt=extPreviewAt(); pv.innerHTML='조정 후 <b>'+(nt?fmtDate(nt):'변경 없음')+'</b>'; }
  const ap=$('extApply'); if(ap){ const on=extDirty(); ap.disabled=!on; ap.style.opacity=on?'':'0.5'; ap.style.cursor=on?'':'default'; ap.textContent=extApplyLabel(); } }
function extModalForm(s){
  const t=s.targetAt||0, base=extBase(s);
  const mag=Math.abs(_extHours), dir=_extHours>0?'시간 연장':(_extHours<0?'시간 단축':'변경 없음');
  const sign=_extHours>0?'+':(_extHours<0?'−':'');
  const on=extDirty(), pv=extPreviewAt();
  return '<h3>루프 '+esc(s.code||('#'+s.number))+' 마감 조정</h3>'
    +'<div class="extcur">현재 마감 <b>'+(t?fmtDate(t):'미정')+'</b></div>'
    +'<div class="extrow"><button class="extbtn" onclick="extStep(-1)">−</button>'
    +'<span class="exth"><b>'+sign+mag+'</b><small>'+dir+'</small></span>'
    +'<button class="extbtn" onclick="extStep(1)">＋</button></div>'
    +'<div class="extnew" id="extPrev">조정 후 <b>'+(pv?fmtDate(pv):'변경 없음')+'</b></div>'
    +'<div class="exthint">＋ / − 2시간 단위로 연장·단축</div>'
    +'<div class="extset"><span class="dlab">직접 지정</span>'
    +'<input type="datetime-local" value="'+localInput(_extAbs||t||Math.floor(base))+'" oninput="extSetAbs(this.value)" onchange="extSetAbs(this.value)" onkeydown="if(event.key===\'Enter\'){event.preventDefault();extSetAbs(this.value);applyExtend();}">'
    +'<span class="dlab" style="font-size:10px">예: 오늘 18:30까지 마감 · 입력 후 아래 버튼으로 확정</span></div>'
    +'<div class="line" style="margin-top:14px"><button class="btn" onclick="closeExtendModal()">취소</button><span style="flex:1"></span>'
    +'<button class="btn primary" id="extApply" '+(on?'':'disabled style="opacity:.5;cursor:default"')
    +' onclick="applyExtend()">'+extApplyLabel()+'</button></div>';
}
// 확정: 직접 지정이 있으면 그 값을, 아니면 상대 조정 결과를 마감으로 설정한다.
function applyExtend(){ const s=extSprint(); const nt=extPreviewAt(); if(!s||!nt){ closeExtendModal(); return; }
  post('/api/sprint/update',{number:_extNum,targetAt:nt}); closeExtendModal(); }
// 보드용 목표 행 (드래그 가능 · 우클릭 이동). hasKids면 접기 셰브론, 자식이면 들여쓰기.
// pref(부모 seq)>0이면 다른 그룹에 있는 부모를 참조 표시(예: Backlog로 분리한 자식).
function bgoalRow(g,hasKids,collapsed,pref){
  const isChild=!!g.parent;
  // Parent goals carry a derived rollup (auto-computed from children) -> read-only badge.
  // Leaf goals get the inline status picker so the sprint board is directly editable.
  const ds=derivedStatus(_goals,g);
  const statCell=(ds!==null)
    ? '<span class="ot '+ds+'" title="자식 태스크 상태에서 자동 계산">'+statLabel(ds)+'</span>'
    : statSelBoard(g);
  const lead=hasKids
    ? '<span class="bgchev" onclick="event.stopPropagation();toggleBgCollapse(\''+g.id+'\')" title="자식 접기/펼치기">'+(collapsed?'▸':'▾')+'</span>'
    : '<span class="bgsp"></span>';
  const pr=(pref>0)?'<span class="pref" title="부모">↳ 부모 goal-'+pad2(pref)+'</span>':'';
  const pri=g.priority||'medium';
  const priDot='<span class="pri pri-'+pri+'" data-gid="'+g.id+'" title="우선순위: '+priLabel(pri)+' (클릭=변경 · Cmd+드래그=같은 값으로)"'
    +' ondragstart="return false" onmousedown="priDown(event,\''+g.id+'\')" onclick="priClick(event,\''+g.id+'\')">'+priSvg(pri)+'</span>';
  // 상태 콤보 왼쪽의 부모 번호 입력칸. 부모를 가질 수 없는 행(자식을 둔 부모 목표)은
  // 정렬용 빈칸만 둔다. Cmd+누른 채 여기서 시작하면 아래로 '채우기'(pinDown), 그냥 클릭은 타이핑.
  const pcell = hasKids ? '<span class="pin-sp"></span>' : parentCellHTML(g,true);
  return '<div class="bgoal'+(isChild?' child':'')+'" data-id="'+g.id+'" draggable="true"'
    +' oncontextmenu="goalCtx(event,\''+g.id+'\')" onmouseenter="priRowEnter(\''+g.id+'\');pinRowEnter(\''+g.id+'\')"'
    +' ondragstart="spDragStart(event,\''+g.id+'\')" ondragend="spDragEnd(event)"'
    +' ondragover="bgReorderOver(event,\''+g.id+'\')" ondrop="bgReorderDrop(event,\''+g.id+'\')" ondragleave="bgReorderLeave(event)">'
    +lead+'<span class="grip" title="드래그=루프 이동 · 다른 행 가운데에 놓으면 그 목표의 자식 · 우클릭=메뉴 · 부모#칸에서 Cmd+드래그=부모 채우기">⠿</span>'+priDot+gpill(g)+linkDot(g)
    +'<span class="t gt" id="gt_'+g.id+'" title="'+esc(g.text)+' — 더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+pr+'</span>'
    +pcell+statCell+'</div>';
}
// 그룹 본문: 같은 그룹 안의 부모-자식을 트리로 렌더(자식 접기 가능, 1단계 계층).
// 부모가 이 그룹에 없는 자식(분리된 자식)은 최상위로 그리되 부모 번호를 참조 표시한다.
function groupBodyHTML(rows){
  if(!rows.length) return '';
  const inSet=new Set(rows.map(g=>g.id));
  const kids={}; rows.forEach(g=>{ if(g.parent && inSet.has(g.parent)){ (kids[g.parent]=kids[g.parent]||[]).push(g); } });
  const tops=rows.filter(g=>!g.parent || !inSet.has(g.parent));
  return tops.map(function(g){
    const pref=(g.parent && !inSet.has(g.parent)) ? (function(){ const p=byId(_goals,g.parent); return p?(p.seq||0):0; })() : 0;
    const ch=kids[g.id]||[];
    if(!ch.length) return bgoalRow(g,false,false,pref);
    const col=_bgCollapsed.has(g.id);
    return bgoalRow(g,true,col,pref)+(col?'':ch.map(c=>bgoalRow(c,false,false,0)).join(''));
  }).join('');
}
// 루프 그룹 (드롭 타깃). AI 큐 박스는 더 이상 여기 끼워 넣지 않는다 — 큐는 큐 탭이
// 유일한 홈이고, 진행 상황은 탭바 우측 노티가, 행선지는 큐 카드의 목적지 라벨이 알린다.
function sprintGroupHTML(s,shown,allLive){
  const rows=shown.filter(g=>!g.bump&&boardSprint(g,_goals)===s.number);
  const members=allLive.filter(g=>!g.bump&&boardSprint(g,_goals)===s.number);   // 카운트는 전체 멤버 (Bump out 제외)
  const body=rows.length?groupBodyHTML(rows)
    :'<div class="empty">'+(members.length?'필터에 맞는 목표가 없습니다 (상태 필터 확인)':'여기로 목표를 끌어다 놓기')+'</div>';
  const col=_spCollapsed.has(s.number);
  return '<div class="spgrp'+(col?' collapsed':'')+'" ondragover="spOver(event)" ondragleave="spLeave(event)" ondrop="spDrop(event,'+s.number+')">'
    +'<div class="spgrp-hd">'
      +'<span class="spchev" onclick="toggleSpCollapse('+s.number+')" title="펼치기/접기">▾</span>'
      +'<span class="pill sp clk" onclick="openSprintModal('+s.number+')" title="클릭: 별칭·날짜 상세 설정" style="cursor:pointer">'+esc(s.code||('#'+s.number))+'</span>'
      +'<span class="ttl">'+(s.goalText?esc(s.goalText):'<span class="muted">예상 결과 미정</span>')+'</span>'
      +sprintCountdownHTML(s)+'<span style="flex:1"></span>'+countsHTML(members)
      +'<button class="btn" onclick="addGoalToSprint('+s.number+')" title="이 루프에 목표 바로 추가">＋ 목표</button>'
      +'<button class="btn rel" onclick="releaseSprintGroup('+s.number+')">Complete loop</button>'
      +'<button class="btn" onclick="spMenu(event,'+s.number+')" title="자세히 (편집·삭제)">⋯</button>'
    +'</div>'
    +'<div class="spgrp-body">'+body+'</div>'
  +'</div>';
}
// Backlog (미배정) — Create loop 버튼 포함. Bump out 인박스 아이템은 여기서 제외.
function backlogHTML(shown,allLive){
  const rows=shown.filter(g=>!g.bump&&boardSprint(g,_goals)===0);
  const members=allLive.filter(g=>!g.bump&&boardSprint(g,_goals)===0);
  const body=rows.length?groupBodyHTML(rows)
    :'<div class="empty">'+(members.length?'필터에 맞는 목표가 없습니다 (상태 필터 확인)':'미배정 목표가 없습니다')+'</div>';
  const col=_spCollapsed.has('bg');
  return '<div class="spgrp bg'+(col?' collapsed':'')+'" ondragover="spOver(event)" ondragleave="spLeave(event)" ondrop="spDrop(event,0)">'
    +'<div class="spgrp-hd"><span class="spchev" onclick="toggleSpCollapse(\'bg\')" title="펼치기/접기">▾</span>'
      +'<b>Backlog</b><span class="muted" style="font-size:12px">미배정</span>'
      +'<span style="flex:1"></span>'+countsHTML(members)
      +'<button class="btn" onclick="addGoalToBacklog()" title="목표를 추가합니다 (입력·AI추가 모듈)">＋ 목표</button>'
      +'<button class="btn" onclick="cleanupSprintsNow()" title="열린 빈 루프(목표 0·예상 결과 없음)를 정리합니다">빈 루프 정리</button>'
      +'<button class="btn primary" onclick="createSprintNow()">＋ Create loop</button></div>'
    +'<div class="spgrp-body">'+body+'</div>'
  +'</div>';
}
// Bump out (아이디어 인박스) — Backlog 아래. 머릿속에서 막 꺼낸 날 것의 아이디어가 처음
// 담기는 곳(정리 전). 여기서 다듬어 Backlog·Sprint로 끌어올린다(위로 승격). g.bump 로만
// 판정 — 부모 상속·sprint 값과 무관하게 항상 이 버킷에 모인다.
function bumpHTML(shown,allLive){
  const rows=shown.filter(g=>g.bump);
  const members=allLive.filter(g=>g.bump);
  const body=(rows.length?groupBodyHTML(rows)
    :'<div class="empty">'+(members.length?'필터에 맞는 아이디어가 없습니다 (상태 필터 확인)':'머릿속 아이디어를 여기로 던져두기 — 위 입력창이 기본으로 담깁니다')+'</div>');
  const col=_spCollapsed.has('bump');
  return '<div class="spgrp bump'+(col?' collapsed':'')+'" ondragover="spOver(event)" ondragleave="spLeave(event)" ondrop="spDropBump(event)">'
    +'<div class="spgrp-hd"><span class="spchev" onclick="toggleSpCollapse(\'bump\')" title="펼치기/접기">▾</span>'
      +'<b>Dump out</b><span class="muted" style="font-size:12px">머리속 비워내기</span>'
      +'<span style="flex:1"></span>'+countsHTML(members)
      +'<button class="btn" onclick="addGoalToBump()" title="머릿속 아이디어를 인박스에 담기 (정리 전)">＋ 목표</button></div>'
    +'<div class="spgrp-body">'+body+'</div>'
  +'</div>';
}
// 완료된 루프 (릴리즈 커밋 로그) — 기본 닫힘, 헤더 클릭으로 펼침.
// 섹션이 접혀 있으면 릴리즈 아이템을, 아이템이 접혀 있으면 그 목표 행을 아예 만들지 않는다(지연 렌더링).
// display:none 으로 숨기면 노드가 DOM에 그대로 남으므로, 실제 노드 수를 줄이려면 innerHTML 자체를 비워야 한다.
// 빈 컷(2026-08-30) — 완료한 것이 하나도 없는 채로 루프를 닫으면 서버가 경계만 남긴
// 릴리즈를 만든다(ReviewStore.completeSprint 1b). 그 기록의 쓸모는 시간축 하나다:
// 메모장이 '이 줄이 어느 루프냐' 를 컷의 시각으로 자른다. 여기 목록은 "무엇을 완료했나"
// 를 읽는 자리라 커밋도 노트도 없는 줄은 뺀다 — 넣으면 며칠 만에 빈 줄이 로그를 덮는다.
// 알아보는 법은 저장된 표식이 아니라 내용이다: 커밋한 목표도 거둔 메모도 없으면 빈 컷.
// (예전 기록 중에는 이 조건에 걸리는 것이 없다 — 릴리즈는 둘 중 하나가 있어야 생겼다.)
function isEmptyCut(rel){
  return !((rel.goalIds||[]).length) && !((rel.titles||[]).length) && !((rel.notes||[]).length);
}
function completedLogHTML(r){
  const rels=((r&&r.releases)||[]).filter(x=>!isEmptyCut(x)); if(!rels.length) return '';
  const hdr='<h3 class="rellog-hd'+(_relLogOpen?' open':'')
    +'" onclick="toggleRelLog()" style="font-size:13px;color:var(--mut);margin:18px 0 8px;border-top:1px solid var(--line);padding-top:14px">'
    +'<span class="chev'+(_relLogOpen?' open':'')+'">▸</span>완료된 루프 (릴리즈 로그) '
    +'<span class="muted" style="font-weight:400">('+rels.length+')</span></h3>';
  if(!_relLogOpen) return hdr;   // 섹션 접힘: 헤더만 렌더 — 릴리즈 아이템 DOM을 만들지 않는다
  const goalById={}; ((r&&r.goals)||[]).forEach(g=>{ goalById[g.id]=g; });
  const sgoalOf={}; ((r&&r.sprints)||[]).forEach(s=>{ sgoalOf[s.number]=s.goalText||''; });
  const codeOf={}; ((r&&r.sprints)||[]).forEach(s=>{ codeOf[s.number]=s.code||('#'+s.number); });
  const items=rels.map(function(rel){
    // 마감 시각만 표기한다. 시작~완료 기간은 휴식까지 루프 시간으로 보이게 해서 오해를
    // 부르므로 (2026-07-09 결정) 로그에는 "언제 마감쳤는가"만 남긴다.
    const when=rel.releasedAt?fmtDate(rel.releasedAt):'—';
    // Prefer the release's own snapshot code (unique per release); fall back to the sprint's
    // current code for legacy records saved before per-release codes existed.
    const code=rel.code||((rel.sprint>0)?(codeOf[rel.sprint]||('#'+rel.sprint)):'');
    const gtext=(rel.sprint>0&&sgoalOf[rel.sprint])?(' · '+esc(sgoalOf[rel.sprint])):'';
    const head=code?(code+gtext):'미배정';
    const open=_relOpen.has(rel.id);
    const ids=rel.goalIds||[], titles=rel.titles||[], notes=rel.notes||[];
    // 재오픈 표시: 릴리즈 기록은 불변이지만, 소속 goal 이 더는 released 가 아니면(검색의
    // '이 목표만 다시 열기') 그 사실을 역산해 헤더와 행에 주석으로 보여준다.
    const reopened=ids.filter(function(id){ const g=goalById[id]; return g&&!g.released; }).length;
    // 접힌 아이템은 행을 만들지 않는다 — 펼칠 때(open) 재렌더에서 생성되어 DOM 노드를 아낀다.
    // 출처 태그: 보드 목표 = AI 세션으로 굴린 작업(session), 메모장 수확분 = 노트.
    const goalRows=titles.map(function(t,i){
      const g=goalById[ids[i]]; const gn=g?('<span class="gn">goal-'+pad2(g.seq||0)+'</span>'):'';
      // Parent indicator: child goals show the parent's number (gray); top-level goals show a purple "부모" badge.
      let pn='';
      if(g){
        if(g.parent){ const p=goalById[g.parent]; pn='<span class="pn" title="상위 목표">'+(p?('goal-'+pad2(p.seq||0)):'상위')+'</span>'; }
        else { pn='<span class="pn top" title="최상위 목표">부모</span>'; }
      }
      const ro=(g&&!g.released)?' <span class="muted" style="font-size:11px">↩ 재오픈됨</span>':'';
      return '<div class="relrow"><span class="srct sess" title="AI 세션으로 굴린 작업">session</span>'+pn+gn+'✓ '+esc(t)+ro+'</div>';
    }).join('');
    const noteRows=notes.map(function(t){
      return '<div class="relrow"><span class="srct" title="메모장에서 완료한 줄">노트</span>✓ '+esc(t)+'</div>';
    }).join('');
    const rows=!open ? '' : ((goalRows+noteRows) || '<div class="muted" style="font-size:12px">목표 없음</div>');
    // 펼치기/닫기는 앞의 ▸ 버튼, 제목(코드·마감 시각 전체) 클릭은 편집 모달 — 두 상호작용을 분리한다.
    return '<div class="relitem">'
      +'<h4>'
        +'<span><span class="chev'+(open?' open':'')+' clk" onclick="toggleRel(\''+rel.id+'\')" title="펼치기/닫기" style="padding:2px 6px 2px 2px">▸</span>'
        +'<span class="clk" onclick="openRelModal(\''+rel.id+'\')" title="클릭: 제목·마감 시간 편집">'+head+' · '+when+'</span>'
        +' <span class="muted" style="font-weight:400;font-size:12px">('+(titles.length+notes.length)+'개'+(reopened?(' · '+reopened+'건 재오픈'):'')+')</span></span>'
        +'<span class="row" style="gap:8px"><span class="valbadge">만든 가치 '+(rel.value||0)+'</span>'
        +'<button class="btn" onclick="event.stopPropagation();restoreRelease(\''+rel.id+'\')">복원</button></span></h4>'
      +'<div class="relbody'+(open?' open':'')+'">'+rows+'</div></div>';
  }).join('');
  return hdr+items;
}

// --- 우선순위 (5단계) : 색 점 클릭=피커 · Cmd+드래그=같은 값으로 페인트 ---
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
  else                  inner='<path d="M2.5 5h9" '+a+'/><path d="M2.5 9h9" '+a+'/>';   // medium = 작대기 둘(=) — 접기/펴기 화살표와 혼동 방지
  return '<svg viewBox="0 0 14 14" width="14" height="14" aria-hidden="true">'+inner+'</svg>';
}
let _priPaint=null;        // 페인트 중인 값(null=비활성)
let _priPainted=null;      // 페인트한 goal id 집합(시작 셀 포함) — mouseup에서 일괄 저장
let _priClickGuard=false;  // 페인트 직후의 click이 피커를 열지 않게 억제
// 낙관적 DOM 갱신: 서버 응답·새로고침 전에 즉시 색을 바꿔 게임처럼 반응하게.
function priApplyDom(id,val){
  document.querySelectorAll('.pri[data-gid="'+id+'"]').forEach(function(el){
    el.className='pri pri-'+val; el.title='우선순위: '+priLabel(val)+' (클릭=변경 · Cmd+드래그=같은 값으로)';
    el.innerHTML=priSvg(val);
  });
}
// Cmd+mousedown: 시작 셀의 현재 값으로 페인트 시작. Cmd 없으면 클릭(피커)에 맡긴다.
function priDown(e,id){
  e.stopPropagation();
  if(!(e.metaKey||e.ctrlKey)) return;   // Cmd(또는 Ctrl)일 때만 페인트
  e.preventDefault();                   // 행의 네이티브 드래그(루프 이동) 차단
  const g=byId(_goals,id); if(!g) return;
  _priPaint=g.priority||'medium';
  _priPainted=new Set([id]);
  document.body.classList.add('pripaint');
  priApplyDom(id,_priPaint);
  document.addEventListener('mouseup',priUp);
}
// 드래그하며 지나가는 행을 같은 값으로 칠한다(행 어디든 진입 시 적용 — 들여쓰기 무관).
function priRowEnter(id){
  if(_priPaint==null||_priPainted.has(id)) return;
  _priPainted.add(id);
  priApplyDom(id,_priPaint);
}
function priUp(){
  document.removeEventListener('mouseup',priUp);
  document.body.classList.remove('pripaint');
  if(_priPaint!=null && _priPainted && _priPainted.size){
    post('/api/goal/priority',{ids:[..._priPainted],priority:_priPaint});
  }
  _priPaint=null; _priPainted=null;
  _priClickGuard=true; setTimeout(function(){ _priClickGuard=false; },0);
}
// 일반 클릭: 5단계 피커 팝업
function priClick(e,id){
  e.stopPropagation();
  if(_priClickGuard||e.metaKey||e.ctrlKey) return;   // 페인트였거나 Cmd면 피커 열지 않음
  const cur=(byId(_goals,id)||{}).priority||'medium';
  const html='<div class="pophdr">우선순위</div>'+PRI_ORDER.map(function(p){
    return '<button class="popitem" onmousedown="event.stopPropagation();hidePopup();setPriority(\''+id+'\',\''+p+'\')">'
      +'<span class="pri pri-'+p+'">'+priSvg(p)+'</span>'+priLabel(p)+(p===cur?' ✓':'')+'</button>';
  }).join('');
  showPopup(e.clientX,e.clientY,html);
}
function setPriority(id,p){ priApplyDom(id,p); post('/api/goal/priority',{id:id,priority:p}); }

// --- 드래그 배정 (루프/Backlog 그룹 이동) ---
let _spDrag=null;
function spDragStart(e,id){ _spDrag=id; e.currentTarget.classList.add('dragging'); e.dataTransfer.effectAllowed='move'; }
function spDragEnd(e){ e.currentTarget.classList.remove('dragging'); document.querySelectorAll('.spgrp.dropOver').forEach(x=>x.classList.remove('dropOver')); bgClearDrop(); _spDrag=null; }
// Intra-group reorder on the sprint board. Dropping a row ONTO a sibling row in the SAME
// bucket (same Bump/Backlog/sprint + same parent) reorders the two; the group-level drop
// (spDrop/spDropBump) only moves BETWEEN buckets and can't change position. Cross-bucket
// drags fall through (no preventDefault/stopPropagation) so the group handler still fires.
function bgBucket(g){ return g.bump ? 'bump' : ('s'+boardSprint(g,_goals)); }
function bgSameGroup(a,b){ return a&&b&&(a.parent||'')===(b.parent||'')&&bgBucket(a)===bgBucket(b); }
// 드롭 대상 행을 '부모'로 해석한다. 보드는 1단계 트리이므로 자식 행 위에 놓으면 그 행의
// 최상위 조상에 붙인다(부모#칸의 setParentByNumber 와 같은 규칙). 붙일 수 없으면 null.
function bgParentTarget(src,tgt){
  if(!src||!tgt||src.id===tgt.id) return null;
  if((_goals||[]).some(k=>k.parent===src.id)) return null;      // 자식을 가진 목표는 자식이 될 수 없다(2단계 방지)
  let p=tgt; const seen=new Set();
  while(p&&p.parent&&!seen.has(p.id)){ seen.add(p.id); const up=byId(_goals,p.parent); if(!up) break; p=up; }
  if(!p||p.id===src.id||p.released||p.archived) return null;
  if(p.id===(src.parent||'')) return null;                      // 이미 그 부모의 자식
  return p;
}
// 한 행 안에서 세로 위치로 의도를 가른다: 가운데 밴드=자식으로 붙이기(부모 변경),
// 위·아래 가장자리=기존 동작(같은 그룹이면 순서 변경, 다른 버킷이면 그룹 드롭으로 통과).
function bgDropIntent(e,id){
  const src=byId(_goals,_spDrag), tgt=byId(_goals,id);
  const r=e.currentTarget.getBoundingClientRect();
  const rel=(e.clientY-r.top)/(r.height||1);
  if(rel>0.3&&rel<0.7){ const p=bgParentTarget(src,tgt); if(p) return {kind:'child',parent:p}; }
  return bgSameGroup(src,tgt)?{kind:'reorder'}:null;
}
function bgClearDrop(){ document.querySelectorAll('.bgoal.dropTarget,.bgoal.dropChild').forEach(x=>x.classList.remove('dropTarget','dropChild')); }
function bgReorderOver(e,id){
  if(_spDrag==null||_spDrag===id) return;
  const it=bgDropIntent(e,id);
  if(!it) return;                    // 해석 불가 -> let spOver/spDrop take it
  e.preventDefault(); e.stopPropagation(); e.dataTransfer.dropEffect='move';
  const row=e.currentTarget; bgClearDrop(); row.classList.add(it.kind==='child'?'dropChild':'dropTarget');
}
function bgReorderLeave(e){ e.currentTarget.classList.remove('dropTarget','dropChild'); }
function bgReorderDrop(e,id){
  if(_spDrag==null||_spDrag===id) return;
  const src=byId(_goals,_spDrag), tgt=byId(_goals,id);
  const it=bgDropIntent(e,id);
  if(!it) return;                    // fall through to group drop (bucket move)
  e.preventDefault(); e.stopPropagation();
  if(it.kind==='child'){ const from=_spDrag; _spDrag=null; bgClearDrop();
    setParentById(from,it.parent.id); return; }
  const from=_spDrag; _spDrag=null;
  bgClearDrop();
  const pid=src.parent||'';
  if(pid){ const kids=gMove(_goals.filter(g=>g.parent===pid).map(g=>g.id), from, id); if(!kids) return;
    const ov={}; ov[pid]=kids; post('/api/goal/reorder',{order:gBuildOrder(_goals.filter(g=>!g.parent).map(g=>g.id), ov)}); }
  else { const order=gMove(_goals.filter(g=>!g.parent).map(g=>g.id), from, id); if(order) post('/api/goal/reorder',{order:gBuildOrder(order)}); }
}
function spOver(e){ e.preventDefault(); e.currentTarget.classList.add('dropOver'); }
function spLeave(e){ e.currentTarget.classList.remove('dropOver'); }
function spDrop(e,n){ e.preventDefault(); e.currentTarget.classList.remove('dropOver');
  if(_spDrag!=null){
    let val=n;
    if(n===0){ const g=byId(_goals,_spDrag); if(g&&g.parent) val=-1; }   // 자식을 Backlog로 끌면 부모와 분리
    post('/api/goal/sprint',{id:_spDrag,sprint:val});
  }
  _spDrag=null;
}
// Bump out 버킷 드롭: 끌어온 목표를 아이디어 인박스로 내린다(sprint 해제).
function spDropBump(e){ e.preventDefault(); e.currentTarget.classList.remove('dropOver');
  if(_spDrag!=null) post('/api/goal/bump',{id:_spDrag,bump:true});
  _spDrag=null;
}

// --- 부모 채우기(fill-down): 부모#칸에서 Cmd+드래그로 아래 행에 같은 부모를 칠한다 ---
// 우선순위 페인트와 같은 패턴. 드래그 도중에는 재렌더하지 않고(그러면 mouseenter 체인이
// 끊김) 칸 값만 낙관적으로 바꾼 뒤, mouseup에서 전체 id를 한 번의 요청으로 커밋한다.
let _fill=null;        // {parent:부모id(''=해제), seq:표시번호} — null이면 비활성
let _filled=null;      // 이번에 칠한 goal id 집합
function bgRowEl(id){ return document.querySelector('.bgoal[data-id="'+id+'"]'); }
// 채울 대상 판정: 자기 자신을 부모로 불가, 자식 가진 목표(2단계 방지)·릴리즈는 스킵.
function fillOk(g){ return g && g.id!==_fill.parent && !g.released && !g.archived && !(_goals||[]).some(k=>k.parent===g.id); }
function pinDown(e,id){
  if(!(e.metaKey||e.ctrlKey)){ e.stopPropagation(); return; }   // Cmd 아니면 타이핑 포커스(행 드래그만 차단)
  e.preventDefault(); e.stopPropagation();                       // 포커스·네이티브 드래그 차단
  const g=byId(_goals,id); if(!g) return;
  const p=g.parent?byId(_goals,g.parent):null;
  _fill={parent:g.parent||'', seq:p?(p.seq||0):0};
  _filled=new Set();
  document.body.classList.add('parfilling');
  const src=bgRowEl(id); if(src) src.classList.add('parsrc');
  document.addEventListener('mouseup',pinUp);
  pinPaint(id);
}
function pinPaint(id){
  if(!_fill||_filled.has(id)) return;
  const g=byId(_goals,id); if(!fillOk(g)) return;
  _filled.add(id);
  const row=bgRowEl(id); if(row){ const pin=row.querySelector('.pin');
    if(pin) pin.value=_fill.parent?pad2(_fill.seq):''; row.classList.add('parfill'); }
}
function pinRowEnter(id){ if(_fill) pinPaint(id); }
function pinUp(){
  document.removeEventListener('mouseup',pinUp);
  document.body.classList.remove('parfilling');
  const ids=_filled?[..._filled].filter(id=>id!==_fill.parent):[];
  const parent=_fill?_fill.parent:'';
  _fill=null; _filled=null;
  if(ids.length) post('/api/goal/parent',{ids:ids,parent:parent});   // 폴링이 새 계층으로 재렌더
  else if(_review) renderSprintBoard(_review);                        // 아무것도 안 칠했으면 원복
}

// --- 접기 (그룹/자식) ---
function toggleSpCollapse(k){ if(_spCollapsed.has(k))_spCollapsed.delete(k); else _spCollapsed.add(k); syncURL(); if(_review) renderSprintBoard(_review); }
function toggleBgCollapse(id){ if(_bgCollapsed.has(id))_bgCollapsed.delete(id); else _bgCollapsed.add(id); syncURL(); if(_review) renderSprintBoard(_review); }

// --- 팝업(⋯ 메뉴 · 우클릭 이동) ---
function showPopup(x,y,html){
  const p=$('popup'); if(!p) return;
  p.innerHTML=html; p.style.display='block';
  // 화면 밖으로 넘치지 않게 위치 보정
  const w=p.offsetWidth, h=p.offsetHeight;
  p.style.left=Math.min(x, window.innerWidth-w-8)+'px';
  p.style.top=Math.min(y, window.innerHeight-h-8)+'px';
  // 바깥을 클릭할 때만 닫는다(내부 검색 입력 등은 유지).
  setTimeout(function(){ document.addEventListener('mousedown',popupOutside); },0);
}
function popupOutside(e){ const p=$('popup'); if(p && !p.contains(e.target)) hidePopup(); }
function hidePopup(){ const p=$('popup'); if(p) p.style.display='none'; document.removeEventListener('mousedown',popupOutside); }
function setPopupHTML(html){ const p=$('popup'); if(p) p.innerHTML=html; }   // 위치 유지하며 내용 교체
// ⋯ : 편집 / 삭제
function spMenu(e,n){ e.preventDefault(); e.stopPropagation();
  const html='<button class="popitem" onmousedown="event.stopPropagation();hidePopup();openSprintModal('+n+')">편집</button>'
    +'<button class="popitem danger" onmousedown="event.stopPropagation();hidePopup();deleteSprintNow('+n+')">삭제</button>';
  showPopup(e.clientX,e.clientY,html);
}
// --- 작업 항목 이동 (Move work item) — reorder a goal within its sibling group ---
// Shared by EVERY view's right-click menu (목록·그룹·테이블·일정·루프). A top-level
// goal reorders among the other top-level goals; a child reorders among its parent's
// children only. Reuses gBuildOrder so the rest of the tree (other parents and their
// kids) is left untouched, and the existing /api/goal/reorder endpoint persists the new
// full order — so no per-view reorder code is duplicated.
function goalSiblingIds(id){
  const g=byId(_goals,id); if(!g) return [];
  const pid=g.parent||'';
  return (pid? _goals.filter(x=>x.parent===pid) : _goals.filter(x=>!x.parent)).map(x=>x.id);
}
function moveGoalOrder(id,where){
  const g=byId(_goals,id); if(!g) return;
  const pid=g.parent||'';
  const sibs=goalSiblingIds(id);
  const i=sibs.indexOf(id); if(i<0) return;
  let j=i;
  if(where==='top') j=0;
  else if(where==='bottom') j=sibs.length-1;
  else if(where==='up') j=i-1;
  else if(where==='down') j=i+1;
  if(j<0||j>=sibs.length||j===i) return;
  sibs.splice(i,1); sibs.splice(j,0,id);
  if(pid){ const ov={}; ov[pid]=sibs;
    post('/api/goal/reorder',{order:gBuildOrder(_goals.filter(x=>!x.parent).map(x=>x.id),ov)}); }
  else { post('/api/goal/reorder',{order:gBuildOrder(sibs)}); }
}
// 우클릭: 작업 항목 이동(순서) · 루프/Backlog 이동 · 부모(계층) — 모든 뷰 공용
function goalCtx(e,id){ e.preventDefault(); e.stopPropagation();
  const sprints=((_review&&_review.sprints)||[]).filter(s=>!s.closed).sort((a,b)=>a.number-b.number);
  const g=byId(_goals,id); const bg=(g&&g.parent)?-1:0;   // 자식은 -1로 분리(부모 상속 끊기)
  // 이동 버튼 enable/disable: 형제 그룹 내 현재 위치 기준
  const sibs=goalSiblingIds(id); const pos=sibs.indexOf(id);
  const atTop=pos<=0, atBot=pos<0||pos>=sibs.length-1;
  const mv=function(w,lab,dis){
    return dis ? '<button class="popitem" disabled>'+lab+'</button>'
      : '<button class="popitem" onmousedown="event.stopPropagation();hidePopup();moveGoalOrder(\''+id+'\',\''+w+'\')">'+lab+'</button>'; };
  let html='<div class="pophdr">작업 항목 이동</div>'
    +mv('top','맨 위로 ⤒',atTop)
    +mv('up','위로 ↑',atTop)
    +mv('down','아래로 ↓',atBot)
    +mv('bottom','맨 아래로 ⤓',atBot);
  html+='<div class="pophdr" style="border-top:1px solid var(--line);margin-top:2px">루프로 이동</div>'
    +'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();moveGoalToSprint(\''+id+'\','+bg+')">Backlog'+((g&&g.parent)?' (부모와 분리)':'')+'</button>';
  html+=sprints.map(s=>'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();moveGoalToSprint(\''+id+'\','+s.number+')">'+esc(s.code||('#'+s.number))+(s.goalText?(' · '+esc(s.goalText)):'')+'</button>').join('');
  // 정리 전 아이디어로 내리기 — 이미 Bump out에 있으면 숨긴다.
  if(!(g&&g.bump)) html+='<button class="popitem" onmousedown="event.stopPropagation();hidePopup();moveGoalToBump(\''+id+'\')">Dump out (아이디어로 내리기)</button>';
  html+='<div class="pophdr" style="border-top:1px solid var(--line);margin-top:2px">부모(계층)</div>'
    +'<button class="popitem" onmousedown="event.stopPropagation();openParentPicker(\''+id+'\')">부모 설정 / 해제 ▸</button>';
  // 링크: 이 목표를 다른 목표로 링크한다. 링크하면 이 목표가 최상위로 승격되고(parent="")
  // 링크가 기록된다(계층은 평면 유지, 내보내기만 링크를 따라간다).
  html+='<div class="pophdr" style="border-top:1px solid var(--line);margin-top:2px">링크</div>'
    +'<button class="popitem" onmousedown="event.stopPropagation();openLinkPicker(\''+id+'\')">링크로 연결 ▸</button>'
    +'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();exportLinkmap(\''+id+'\')">내보내기 (링크 체인) ↗</button>';
  const isParent=(_goals||[]).some(k=>k.parent===id);
  // 보관: 활성 목록에서 치우고 아카이브 뷰로 보낸다(자식도 함께). 되돌리기는 아카이브 뷰의 '보관 해제'.
  html+='<div class="pophdr" style="border-top:1px solid var(--line);margin-top:2px">보관</div>'
    +'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();archiveGoal(\''+id+'\',true)">아카이브로 보관'+(isParent?' (하위 포함)':'')+'</button>';
  // Parents are never auto-completed from their children (they are a living history container).
  // Give the user the MANUAL close/reopen switch here — used only at a branch point.
  if(isParent){
    const manualDone=(g&&(g.status||'')==='done');
    html+='<div class="pophdr" style="border-top:1px solid var(--line);margin-top:2px">부모 상태 (수동)</div>'
      +(manualDone
        ? '<button class="popitem" onmousedown="event.stopPropagation();hidePopup();setStatus(\''+id+'\',\'backlog\')">On Track으로 되돌리기</button>'
        : '<button class="popitem" onmousedown="event.stopPropagation();hidePopup();setStatus(\''+id+'\',\'done\')">완료로 표시 (분기 마감)</button>');
  }
  // 삭제: 되돌릴 수 없는 파괴적 동작. 자식이 있으면 함께 삭제되므로 확인을 받는다.
  html+='<div class="pophdr" style="border-top:1px solid var(--line);margin-top:2px">삭제</div>'
    +'<button class="popitem danger" onmousedown="event.stopPropagation();hidePopup();deleteGoalNow(\''+id+'\','+(isParent?'true':'false')+')">삭제'+(isParent?' (하위 포함)':'')+'</button>';
  showPopup(e.clientX,e.clientY,html);
}
// 우클릭 메뉴 전용: 삭제 전 확인. 자식이 있으면 함께 삭제됨을 알린다.
function deleteGoalNow(id,hasChildren){ if(!confirm(hasChildren?'이 작업 항목과 모든 하위 항목을 삭제합니다. 되돌릴 수 없습니다.':'이 작업 항목을 삭제합니다. 되돌릴 수 없습니다.')) return; removeGoal(id); }
function moveGoalToSprint(id,n){ post('/api/goal/sprint',{id:id,sprint:n}); }
// Bump out 인박스로 내리기(정리 전 아이디어로). 서버가 sprint를 0으로 비운다.
function moveGoalToBump(id){ post('/api/goal/bump',{id:id,bump:true}); }
// 보관 / 보관 해제 — 서버가 자식까지 함께 보관 처리한다. 활성 뷰에서 사라지고 아카이브 뷰로 이동.
function archiveGoal(id,on){ post('/api/goal/archive',{id:id,archived:!!on}); }

// --- 부모 선택기 (검색 + Unlink + 후보 목록) — 팝업 내용 교체, 닫히지 않음 ---
let _ppId=null;
function openParentPicker(id){
  _ppId=id;
  setPopupHTML('<div class="pophdr">부모 설정</div>'
    +'<input class="ppsearch" id="ppSearch" placeholder="번호·이름 검색" oninput="renderParentList(this.value)" onmousedown="event.stopPropagation()">'
    +'<button class="popitem unlink" onmousedown="event.stopPropagation();hidePopup();setParentById(\''+id+'\',\'\')">Unlink (부모 해제)</button>'
    +'<div id="ppList"></div>');
  renderParentList('');
  const s=$('ppSearch'); if(s) s.focus();
}
// 최근 사용한 부모(newest-first, 서버 보관). 브라우저 localStorage 가 아니라 서버에 두는 이유는
// 대시보드 포트가 실행마다 바뀌어 origin 저장소가 매번 초기화되기 때문(lastView·doneCutoff 와 동일).
function recentParentSeqs(){ return (_review&&_review.recentParents)||[]; }
function recentParentIds(){
  const m={}; (_goals||[]).forEach(function(g){ if(g.seq) m[g.seq]=g.id; });
  return recentParentSeqs().map(function(n){ return m[n]||''; }).filter(Boolean);
}
function renderParentList(q){
  const el=$('ppList'); if(!el) return;
  q=String(q||'').toLowerCase().trim();
  // 후보: 최상위(부모 없음)·릴리즈 안 됨·자기 자신 제외 (백엔드가 2단계 중첩은 재차 검증)
  const cands=(_goals||[]).filter(g=>g.id!==_ppId && !g.parent && !g.released && !g.archived);
  // 정렬 우선순위: ① 최근 사용한 부모(서버 MRU, 최신순) → ② 현재(열린) 루프 부모(루프 번호·보드 순)
  //              → ③ 나머지. 동일 그룹 안에서는 원래 _goals 순서를 유지한다.
  const recents=recentParentIds();
  const rpos={}; recents.forEach(function(id,i){ rpos[id]=i; });
  const openSp={}; ((_review&&_review.sprints)||[]).forEach(function(s){ if(!s.closed) openSp[s.number]=true; });
  const idx={}; cands.forEach(function(g,i){ idx[g.id]=i; });
  function rank(g){ if(rpos[g.id]!==undefined) return 0; if(g.sprint>0 && openSp[g.sprint]) return 1; return 2; }
  const ordered=cands.slice().sort(function(a,b){
    const ra=rank(a),rb=rank(b); if(ra!==rb) return ra-rb;
    if(ra===0) return rpos[a.id]-rpos[b.id];                                           // 최근 사용 순(최신 먼저)
    if(ra===1 && (a.sprint||0)!==(b.sprint||0)) return (a.sprint||0)-(b.sprint||0);   // 현재 루프 번호 순
    return idx[a.id]-idx[b.id];                                                        // 그 외 보드(원래) 순
  });
  const f=ordered.filter(function(g){ if(!q) return true; const lab=('goal-'+pad2(g.seq||0)+' '+(g.text||'')).toLowerCase(); return lab.indexOf(q)>=0; });
  el.innerHTML = f.length
    ? f.map(g=>'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();setParentById(\''+_ppId+'\',\''+g.id+'\')"><span class="gn">goal-'+pad2(g.seq||0)+'</span>'+esc(g.text)+(rpos[g.id]!==undefined?'<span class="ppfresh">최근</span>':'')+'</button>').join('')
    : '<div class="muted" style="padding:7px 10px;font-size:12px">결과 없음</div>';
}
// 부모 확정. 최근 사용 목록(MRU)은 서버가 /api/goal/parent 안에서 갱신한다.
function setParentById(id,pid){ post('/api/goal/parent',{id:id,parent:pid}); }

// ===== 부모# 칸 — 공용 셀 · 추천 고스트 · 최근/추천 드롭다운 =====
// 한 칸 안에 세 겹이 겹쳐 있다.
//   ① <input class="pin">  확정 경로. 부모가 실제로 바뀌는 길은 여기 하나뿐이다.
//   ② <a class="pghost">   서버가 계산한 추천 번호를 회색으로 보여준다. 클릭=그 부모 goal 열기.
//      고스트는 input.value 를 절대 건드리지 않는다 — 추천을 확정으로 바꾸는 것은 사용자가
//      숫자를 직접 입력할 때뿐이라, 잘못된 추천이 조용히 계층을 바꾸는 일이 없다.
//   ③ <i class="psdot">    추천 상태 점. 계산 중=보라 pulse, 추천 있음=추천 부모의 실효 상태색.
const PIN_TIP='번호 입력 (예: 02 → goal-02의 자식) · Cmd+드래그로 아래 행에 채우기 · 비우면 최상위';
function escAttr(s){ return esc(s).replace(/"/g,'&quot;'); }
function psugItems(){ const ps=_review&&_review.psug; return (ps&&ps.items)||[]; }
function psugRunning(){ const ps=_review&&_review.psug; return !!(ps&&ps.state==='running'); }
function psugFor(g){
  if(!g||!g.seq) return null;
  const it=psugItems(); for(let i=0;i<it.length;i++){ if(it[i].seq===g.seq) return it[i]; }
  return null;
}
function bySeq(n){ return (_goals||[]).find(x=>x.seq===n)||null; }
// 점 색·문구는 새 팔레트를 만들지 않고 그 행이 이미 쓰는 상태 표현을 그대로 재사용한다
// (자식을 둔 목표는 롤업 상태, 잎 목표는 자기 상태).
function psugStatusOf(p){ const ds=derivedStatus(_goals,p); return ds||(p.status||'backlog'); }
function psugStatusLabel(p){ const ds=derivedStatus(_goals,p); return ds?statLabel(ds):statLabel2(p.status||'backlog'); }
function psugGhostHTML(g){
  const s=psugFor(g);
  if(!s){
    // 계산 중이고 아직 결론이 없을 때만 점 하나로 알린다(추천이 이미 있으면 그 쪽이 이긴다).
    return psugRunning()
      ? '<span class="pghost" title="부모 추천 계산 중"><i class="psdot calc"></i></span>' : '';
  }
  const p=bySeq(s.p); if(!p) return '';
  const num=pad2(p.seq||0);
  const cls=psugRunning()?'calc':psugStatusOf(p);
  const tip='추천 부모 goal-'+num+' · '+(psugRunning()?'다시 계산 중':psugStatusLabel(p))
    +' · 근거: '+(s.why||'제목 키워드 일치')+' — 클릭하면 goal-'+num+'을(를) 엽니다 (확정은 번호를 직접 입력)';
  return '<a class="pghost" href="/goal?n='+(p.seq||0)+'" title="'+escAttr(tip)+'"'
    +' onmousedown="event.stopPropagation()" onclick="event.stopPropagation()"><i class="psdot '+cls+'"></i>'+num+'</a>';
}
// 루프 보드(board=true)와 목록 뷰가 같은 셀을 쓴다. 보드에서 자식을 둔 행은 애초에
// 부모가 될 수 없어 호출되지 않는다(정렬용 빈칸이 대신 들어간다).
function parentCellHTML(g,board){
  const p=g.parent?byId(_goals,g.parent):null;
  const pv=p?pad2(p.seq||0):'';
  const gh=g.parent?'':psugGhostHTML(g);
  // Cmd+드래그 채우기는 행이 세로로 늘어선 보드에서만 의미가 있다(목록 뷰에는 채울 행 좌표가 없다).
  const md=board?(' onmousedown="pinDown(event,\''+g.id+'\')"'):' onmousedown="event.stopPropagation()"';
  const tip=board?PIN_TIP:'부모 번호 입력 (비우면 최상위)';
  // 추천이 입력칸 앞에 나란히 온다(겹치지 않는다 — .pinwrap 주석 참고).
  return '<span class="pinwrap">'+gh
    +'<input class="pin" type="text" inputmode="numeric" draggable="false" value="'+pv+'"'
    +' placeholder="'+(gh?'':'부모#')+'" title="'+escAttr(gh?('추천은 회색 번호 · '+tip):tip)+'"'+md
    +' onclick="event.stopPropagation()" ondblclick="event.stopPropagation()"'
    +' onfocus="pinFocus(event,\''+g.id+'\')" onblur="pinBlur(event)" oninput="renderPinList(this.value)"'
    +' onkeydown="if(event.key===\'Enter\')this.blur()" onchange="setParentByNumber(\''+g.id+'\',this.value)">'
    +'</span>';
}

// --- 칸을 누르면 뜨는 드롭다운: 추천 → 최근 사용 → 후보 ---
// 포커스는 입력칸에 그대로 둔다(항목은 mousedown 에서 preventDefault). 그래서 타이핑하면
// 목록이 실시간으로 걸러지고, 그대로 숫자를 쳐서 확정하는 기존 경로도 막히지 않는다.
let _pinId=null;
function pinFocus(e,id){
  const w=e.target.closest('.pinwrap'); if(w) w.classList.add('focus');
  if(_fill) return;                       // Cmd+드래그 채우기 중에는 열지 않는다
  _pinId=id;
  // 칸 전체(.pinwrap) 기준으로 연다 — 입력칸은 추천이 있으면 칸의 오른쪽 일부만 차지한다.
  const r=(w||e.target).getBoundingClientRect();
  showPopup(r.left, r.bottom+4, '<div class="pophdr">부모 연결</div><div id="pinList"></div>');
  renderPinList(e.target.value);
}
function pinBlur(e){
  const w=e.target.closest('.pinwrap'); if(w) w.classList.remove('focus');
  if(_pinId){ _pinId=null; hidePopup(); }
}
function pinPick(pid){ const id=_pinId; _pinId=null; hidePopup(); if(id) setParentById(id,pid); }
function pinItemHTML(g,badge,why){
  return '<button class="popitem" onmousedown="event.preventDefault();event.stopPropagation();pinPick(\''+g.id+'\')">'
    +'<span class="gn">goal-'+pad2(g.seq||0)+'</span>'+esc(g.text)
    +(badge?'<span class="ppfresh'+(badge==='추천'?' sug':'')+'">'+badge+'</span>':'')
    +(why?'<span class="pswhy">'+esc(why)+'</span>':'')+'</button>';
}
function renderPinList(q){
  const el=$('pinList'); if(!el) return;
  const me=byId(_goals,_pinId); if(!me) return;
  q=String(q||'').toLowerCase().trim();
  function hit(g){ if(!q) return true; return ('goal-'+pad2(g.seq||0)+' '+(g.text||'')).toLowerCase().indexOf(q)>=0; }
  // 후보 = 최상위·살아있는 목표(백엔드가 2단계 중첩을 재차 검증한다)
  const cands=(_goals||[]).filter(g=>g.id!==_pinId && !g.parent && !g.released && !g.archived);
  const used={};
  let html='';
  const s=psugFor(me), sp=s?cands.find(x=>x.seq===s.p):null;
  if(sp&&hit(sp)){ used[sp.id]=1; html+='<div class="pophdr">추천</div>'+pinItemHTML(sp,'추천',s.why); }
  const rec=recentParentIds().map(id=>cands.find(x=>x.id===id)).filter(g=>g&&!used[g.id]&&hit(g)).slice(0,5);
  if(rec.length){ rec.forEach(g=>{ used[g.id]=1; }); html+='<div class="pophdr">최근 사용</div>'+rec.map(g=>pinItemHTML(g,'최근','')).join(''); }
  // 나머지 후보. 검색 전에는 목록이 화면을 덮지 않게 잘라 보여주고, 타이핑하면 더 넓게 찾는다.
  const rest=cands.filter(g=>!used[g.id]&&hit(g));
  const cap=q?24:8;
  if(rest.length) html+='<div class="pophdr">후보'+(rest.length>cap?' (상위 '+cap+'/'+rest.length+' · 검색으로 좁히기)':'')+'</div>'
    +rest.slice(0,cap).map(g=>pinItemHTML(g,'','')).join('');
  if(me.parent) html='<button class="popitem unlink" onmousedown="event.preventDefault();event.stopPropagation();pinPick(\'\')">Unlink (부모 해제)</button>'+html;
  el.innerHTML = html||'<div class="muted" style="padding:7px 10px;font-size:12px">결과 없음</div>';
}

// --- 링크 대상 선택기 (검색 + 후보 목록) — 부모 선택기와 같은 팝업 UX ---
// 부모 선택기(openParentPicker/renderParentList)와 동일한 패턴. 다만 링크는 최상위가
// 아니어도 아무 목표나 대상이 될 수 있으므로 후보에서 '최상위' 제한을 걸지 않는다.
let _lkId=null;
function openLinkPicker(id){
  _lkId=id;
  setPopupHTML('<div class="pophdr">링크 대상 선택</div>'
    +'<input class="ppsearch" id="lkSearch" placeholder="번호·이름 검색 (goal-01 · 01 · 1)" oninput="renderLinkList(this.value)" onmousedown="event.stopPropagation()">'
    +'<div id="lkList"></div>');
  renderLinkList('');
  const s=$('lkSearch'); if(s) s.focus();
}
function renderLinkList(q){
  const el=$('lkList'); if(!el) return;
  q=String(q||'').toLowerCase().trim();
  const src=byId(_goals,_lkId);
  const already=new Set((src&&src.links)||[]);
  // 후보: 자기 자신·이미 링크된 목표·보관됨 제외. 부모 제한은 없다(어떤 목표든 대상 가능).
  const cands=(_goals||[]).filter(g=>g.id!==_lkId && !already.has(g.id) && !g.archived);
  const f=cands.filter(function(g){ if(!q) return true; const lab=('goal-'+pad2(g.seq||0)+' '+(g.text||'')).toLowerCase(); return lab.indexOf(q)>=0; });
  el.innerHTML = f.length
    ? f.map(g=>'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();confirmLink(\''+_lkId+'\',\''+g.id+'\')"><span class="gn">goal-'+pad2(g.seq||0)+'</span>'+esc(g.text)+'</button>').join('')
    : '<div class="muted" style="padding:7px 10px;font-size:12px">결과 없음</div>';
}
// 링크 확인 다이얼로그: 승격(최상위) 전/후를 그림으로 보여주고 확인/취소를 받는다.
// 확인하면 소스가 최상위로 승격되고 소스→대상 링크가 기록된다.
function confirmLink(srcId,tgtId){
  const s=byId(_goals,srcId), t=byId(_goals,tgtId); if(!s||!t) return;
  const sLab='goal-'+pad2(s.seq||0), tLab='goal-'+pad2(t.seq||0);
  const par=s.parent?byId(_goals,s.parent):null;
  const parLab=par?('goal-'+pad2(par.seq||0)):'';
  // "지금" 상태: 부모 안에 묻혀 있으면 그 부모를, 아니면 이미 최상위임을 보여준다.
  const beforeInner = par
    ? '<div class="lkbox">'+esc(parLab)+' <span class="muted">('+esc(par.text)+')</span><div class="lknest">└ '+esc(sLab)+' <span class="muted">('+esc(s.text)+')</span></div></div>'
    : '<div class="lkbox">'+esc(sLab)+' <span class="muted">('+esc(s.text)+')</span> <span class="muted">— 이미 최상위</span></div>';
  const afterInner =
    '<div class="lkbox">'+esc(sLab)+' <span class="muted">('+esc(s.text)+')</span> <span class="lkchip">🔗 '+esc(tLab)+'</span></div>'
    +'<div class="muted" style="font-size:12px;margin-top:4px">최상위로 승격 + '+esc(tLab)+' 링크</div>';
  const ov=document.createElement('div');
  ov.className='overlay on'; ov.id='lkConfirm';
  ov.innerHTML='<div class="modal" style="max-width:520px">'
    +'<h2 style="margin:0 0 6px">링크로 연결</h2>'
    +'<p class="muted" style="font-size:13px;margin:0 0 14px">'+esc(sLab)+' 을(를) 최상위로 승격하고 '+esc(tLab)+' 로 링크합니다. 화면 계층은 평면(1단계) 그대로이며, 링크는 내보내기(압축)에서만 따라갑니다.</p>'
    +'<div class="lkba">'
      +'<div class="lkcol"><div class="lkcap">지금</div>'+beforeInner+'</div>'
      +'<div class="lkarrow">➜</div>'
      +'<div class="lkcol"><div class="lkcap">연결 후</div>'+afterInner+'</div>'
    +'</div>'
    +'<div class="row" style="justify-content:flex-end;margin-top:18px">'
      +'<button class="btn" onclick="closeLinkConfirm()">취소</button>'
      +'<button class="btn primary" onclick="doLink(\''+srcId+'\',\''+tgtId+'\')">확인</button>'
    +'</div></div>';
  ov.addEventListener('mousedown',function(e){ if(e.target===ov) closeLinkConfirm(); });
  document.body.appendChild(ov);
}
function closeLinkConfirm(){ const el=$('lkConfirm'); if(el) el.remove(); }
function doLink(srcId,tgtId){ closeLinkConfirm(); post('/api/goal/link',{id:srcId,target:tgtId}); }

// --- 루프 편집 모달 ---
let _spModalNum=null;
function spModalForm(s){
  const chips=DUR_OPTS.map(o=>'<span class="durchip'+(o[0]===s.durationKind?' on':'')+'" onclick="setSprintDur('+s.number+',\''+o[0]+'\')">'+o[1]+'</span>').join('');
  return '<h3>루프 '+esc(s.code||('#'+s.number))+' 편집</h3>'
    +'<div class="line"><span class="lab">별칭</span><input value="'+esc(s.code||'').replace(/"/g,'&quot;')+'" placeholder="예: 26-15 · 자유 별칭 가능" onchange="setSprintCode('+s.number+',this.value)"></div>'
    +'<div class="line"><span class="lab">예상 결과</span><input class="spmgoal" value="'+esc(s.goalText).replace(/"/g,'&quot;')+'" placeholder="이 루프가 끝나면 완성될 것" onchange="updateSprintGoal('+s.number+',this.value)"></div>'
    +'<div class="line"><span class="lab">기간</span><span class="chips">'+chips+'</span></div>'
    +'<div class="line"><span class="lab">시작</span><input type="datetime-local" value="'+localInput(s.startAt)+'" onchange="setSprintDate('+s.number+',\'startAt\',this.value)"></div>'
    +'<div class="line"><span class="lab">목표</span><input type="datetime-local" value="'+localInput(s.targetAt)+'" onchange="setSprintDate('+s.number+',\'targetAt\',this.value)"></div>'
    +'<div class="line" style="margin-top:4px"><button class="btn danger" style="border-color:#5a2738;color:#ff9db0" onclick="deleteSprintNow('+s.number+')">루프 삭제</button><span style="flex:1"></span><button class="btn primary" onclick="closeSprintModal()">닫기</button></div>';
}
function openSprintModal(n){ _spModalNum=n; _relModalId=null; fillSprintModal(); const m=$('spModal'); if(m) m.style.display='flex'; }
function fillSprintModal(){ if(_spModalNum==null) return; const s=((_review&&_review.sprints)||[]).find(x=>x.number===_spModalNum); if(!s){ closeSprintModal(); return; } const b=$('spModalBox'); if(b) b.innerHTML=spModalForm(s); }
function closeSprintModal(){ _spModalNum=null; _relModalId=null; const m=$('spModal'); if(m) m.style.display='none'; }

// --- 완료 루프(릴리즈) 편집 모달 --- 완료 로그의 제목(코드·마감 시각) 클릭으로 열린다.
// 별칭과 마감 일시만 편집한다 — 시작~완료 기간은 휴식까지 포함돼 오해를 부르므로 기록·편집
// 대상에서 제외 (startedAt 데이터는 남아 있지만 노출하지 않는다).
// 루프 편집 모달과 같은 #spModal 컨테이너를 공유한다 (_spModalNum과 상호 배타).
let _relModalId=null;
function relModalForm(rel){
  return '<h3>완료 루프 '+esc(rel.code||'미배정')+' 편집</h3>'
    +'<div class="line"><span class="lab">별칭</span><input value="'+esc(rel.code||'').replace(/"/g,'&quot;')+'" placeholder="예: 26-15 · 자유 별칭 가능" onchange="setRelCode(\''+rel.id+'\',this.value)"></div>'
    +'<div class="line"><span class="lab">마감</span><input type="datetime-local" value="'+localInput(rel.releasedAt)+'" onchange="setRelDate(\''+rel.id+'\',this.value)"></div>'
    +'<div class="line" style="margin-top:4px"><span style="flex:1"></span><button class="btn primary" onclick="closeSprintModal()">닫기</button></div>';
}
function openRelModal(id){ _relModalId=id; _spModalNum=null; fillRelModal(); const m=$('spModal'); if(m) m.style.display='flex'; }
function fillRelModal(){ if(_relModalId==null) return; const rel=((_review&&_review.releases)||[]).find(x=>x.id===_relModalId); if(!rel){ closeSprintModal(); return; } const b=$('spModalBox'); if(b) b.innerHTML=relModalForm(rel); }
// 별칭 변경 — 루프·릴리즈 코드 전체에서 유일해야 저장된다 (서버도 재검증 후 무시).
function setRelCode(id,v){
  const t=String(v||'').trim();
  if(!t){ alert('별칭을 입력하세요.'); fillRelModal(); return; }
  const r=_review||{};
  const dup=((r.sprints)||[]).some(s=>s.code===t) || ((r.releases)||[]).some(x=>x.id!==id&&x.code===t);
  if(dup){ alert('이미 사용 중인 별칭입니다: '+t); fillRelModal(); return; }
  post('/api/release/update',{id:id,code:t});
}
// 마감 일시 변경 — 비울 수 없다 (서버도 재검증: releasedAt은 never cleared).
function setRelDate(id,val){
  const ep=CMTimeFilter.inputToEpoch(val);
  if(!ep){ alert('마감 일시는 비울 수 없습니다.'); fillRelModal(); return; }
  post('/api/release/update',{id:id,releasedAt:ep});
}

// 이 루프에 목표 바로 추가 — 전용 페이지(/goal-add)로 이동한다 (대상=이 루프).
function addGoalToSprint(n){ const s=((_review&&_review.sprints)||[]).find(x=>x.number===n); openGoalAdd({sprint:n,label:(s&&s.code)||('#'+n)}); }
// Backlog(미배정)에 목표 추가 — 같은 페이지, 대상만 Backlog.
function addGoalToBacklog(){ openGoalAdd({sprint:0,label:'Backlog'}); }
// Bump out(아이디어 인박스)에 담기 — 같은 페이지, 대상만 Bump out.
function addGoalToBump(){ openGoalAdd({bump:true,label:'Dump out'}); }
function createSprintNow(){ post('/api/sprint/create',{goalText:'',durationKind:'1d'}); }   // 자동 코드(26-N), Backlog 비움
// 열린 빈 루프(목표 0·예상 결과 없음)를 정리한다. 다른 작업 중 루프가 있으면 전부,
// 없으면 최신 1개만 남기고 삭제 (서버 cleanupSprints 규칙).
function cleanupSprintsNow(){ if(!confirm('열린 빈 루프(목표 0개·예상 결과 없음)를 정리합니다. 작업 중인 루프는 건드리지 않습니다.')) return; post('/api/sprint/cleanup',{}); }
// 별칭(code) 변경 — 루프·릴리즈 코드 전체에서 유일해야 저장된다 (서버도 재검증 후 무시).
function setSprintCode(n,v){
  const t=String(v||'').trim();
  if(!t){ alert('별칭을 입력하세요.'); fillSprintModal(); return; }
  const r=_review||{};
  const dup=((r.sprints)||[]).some(s=>s.number!==n&&s.code===t) || ((r.releases)||[]).some(x=>x.code===t);
  if(dup){ alert('이미 사용 중인 별칭입니다: '+t); fillSprintModal(); return; }
  post('/api/sprint/update',{number:n,code:t});
}
function updateSprintGoal(n,v){ post('/api/sprint/update',{number:n,goalText:String(v||'')}); }
function setSprintDur(n,k){ post('/api/sprint/update',{number:n,durationKind:k}); }   // 목표 날짜는 서버가 재계산
function setSprintDate(n,key,val){ const ep=CMTimeFilter.inputToEpoch(val); const o={number:n}; o[key]=ep; post('/api/sprint/update',o); }
function deleteSprintNow(n){ if(!confirm('이 루프를 삭제합니다. 배정된 목표는 Backlog로 돌아갑니다.')) return; post('/api/sprint/delete',{number:n}); }
// Complete loop = 커밋하고 닫는다. 미완료 목표가 있을 때만 이월 — 이미 열린 루프가
// 있으면 그리로, 없으면 새 루프(24시간 auto)가 열린다. 빈 루프는 기록 없이 닫힌다.
function releaseSprintGroup(n){ if(!confirm('이 루프를 완료합니다. 완료 목표는 커밋되고, 미완료 목표가 있으면 열린 루프로 이월됩니다(없으면 새로 열림). 완료한 목표가 없으면 완료 로그에는 남지 않고 닫힙니다(루프 경계는 기록됩니다).')) return; completeSprintPost(n); }
// 루프 완료의 유일한 창구 — 커밋한 뒤 같은 화면의 메모장에 컷을 곧바로 알린다.
// 패드는 자기 폴링(30초 틱 + boardFetch 의 60초 스로틀)으로만 보드를 알아서, 이 한 줄이
// 없으면 방금 자른 루프가 패드에 닿는 데 60~90초가 걸린다(2026-08-30). 새 타이머를 두지
// 않고, 사람이 컷을 누른 그 순간에만 한 번 깨운다. 패드가 없는 페이지에서는 조용히 넘어간다.
function completeSprintPost(n){
  return post('/api/sprint/complete',{number:n})
    .then(function(){ try{ if(window.CMMemo && CMMemo.boardChanged) CMMemo.boardChanged(); }catch(e){} });
}

// 완료 로그 펼침/복원
function toggleRel(id){ if(_relOpen.has(id))_relOpen.delete(id); else _relOpen.add(id); if(_review) renderSprintBoard(_review); }
function toggleRelLog(){ _relLogOpen=!_relLogOpen; if(_review) renderSprintBoard(_review); }   // 섹션 전체 펼침/접힘
function restoreRelease(id){ post('/api/release/restore',{id:id}); }
// 오른쪽 위 Complete loop 버튼: 현재 루프 필터의 완료 목표를 커밋한다.
function releaseCurrentSprint(){
  if(_sprintSel.size>1){ alert('Complete loop는 한 번에 하나의 루프만 가능합니다. 루프를 하나만 선택하세요.'); return; }
  const only=(_sprintSel.size===1)?[..._sprintSel][0]:0;   // 0 = 모두
  // 단일 루프 선택 시 = 완료 후 다음 번호로 전진(이월 포함). '모두' 선택 시 = 전진 없이
  // 전 루프의 완료 목표만 커밋(번호 전진은 특정 루프를 완료할 때만 의미가 있으므로).
  if(only){
    if(!confirm('루프 '+sprintCode(only)+'을(를) 완료합니다. 완료 목표는 커밋되고, 미완료 목표가 있으면 열린 루프로 이월됩니다(없으면 새로 열림). 완료한 목표가 없으면 완료 로그에는 남지 않고 닫힙니다(루프 경계는 기록됩니다).')) return;
    completeSprintPost(only);
  }else{
    if(!confirm('모든 루프의 완료 목표를 커밋합니다. 목록에서 사라지고 완료 로그로 이동합니다.')) return;
    post('/api/sprint/release',{sprint:'all'});
  }
}
// Evidence rendered for the report (clickable, in-app) and markdown (portable text).
// In markdown, file rows show the name only — their /evidence URL is dashboard-local
// and won't resolve once the text is pasted elsewhere; links keep their full URL.
function evReportHtml(g){
  const ev=g.evidence||[]; if(!ev.length) return '';
  return '<div class="evrep">'+ev.map(e=>{
    const t=esc(e.title||e.href||''), icon=(e.kind==='file')?'📄 ':'🔗 ';
    return (e.kind==='file')
      ? '<a href="'+esc(e.href)+'" download>'+icon+t+'</a>'
      : '<a href="'+esc(e.href)+'" target="_blank" rel="noopener">'+icon+t+'</a>';
  }).join('')+'</div>';
}
function evMd(g){
  const ev=g.evidence||[]; if(!ev.length) return '';
  return ev.map(e=> '  - '+(e.kind==='file'?('📄 '+(e.title||'file')):('🔗 '+(e.title||e.href)+' '+e.href))).join('\n')+'\n';
}
// goal-NN 라벨(내보내기 링크 표시용). seq를 2자리로 패딩.
function goalTag(g){ const n=(g&&g.seq)||0; return 'goal-'+(n<10?'0'+n:''+n); }
function buildMarkdown(d,r,conf,prov){
  const goals=r.goals||[], byId={}; goals.forEach(g=>{ byId[g.id]=g; });
  const tops=goals.filter(g=>!g.parent && goalPasses(g,goals) && reportPassesRange(g,goals));
  let md='# 리포트 ('+reportRangeLabel(d.date)+')\n\n- 확정 가치: '+conf.toFixed(2)+'h (잠정 '+prov.toFixed(1)+'h)\n\n';
  // visited-set으로 중복·사이클을 방지하며 각 top의 링크 체인을 따라간다(01→233→…→01 종료).
  const visited=new Set();
  // linked=true면 "↗ goal-NN (링크됨)" 헤더로 표시. 재귀로 링크된 목표의 자식/링크도 따라간다.
  function emitTop(t,linked){
    if(visited.has(t.id)) return; visited.add(t.id);
    const ds=derivedStatus(goals,t);
    const head=linked?('↗ '+goalTag(t)+' (링크됨) '+t.text):t.text;
    md+='## '+head+(ds==='on_track'?' [on track]':(ds==='done'?' [완료]':''))+(gnote(r,t.id)?(' — '+gnote(r,t.id)):'')+'\n';
    md+=evMd(t);
    goals.filter(c=>c.parent===t.id && goalPasses(c,goals)).forEach(c=>{ const cs=(c.status||'backlog');
      const m=cs==='in_progress'?' (진행)':(cs==='done'?' (완료)':'');
      md+='- '+c.text+m+(gnote(r,c.id)?(' — '+gnote(r,c.id)):'')+'\n'; md+=evMd(c); });
    md+='\n';
    (t.links||[]).forEach(lid=>{ const lg=byId[lid]; if(lg) emitTop(lg,true); });
  }
  tops.forEach(t=>emitTop(t,false));
  return md;
}
function renderReport(d,r,conf,prov){
  const goals=r.goals||[], byId={}; goals.forEach(g=>{ byId[g.id]=g; });
  const tops=goals.filter(g=>!g.parent && goalPasses(g,goals) && reportPassesRange(g,goals));
  let html='<div class="muted" style="margin-bottom:10px">'+esc(reportRangeLabel(d.date))+' · 확정 '+conf.toFixed(2)+'h (잠정 '+prov.toFixed(1)+'h)</div>';
  if(!tops.length) html+='<div class="muted">'+((_reportRange&&_reportRange.start)?'선택한 기간·보기 필터에 해당하는 목표가 없습니다.':(anyStatusActive()?'필터에 해당하는 목표가 없습니다.':'목표가 없습니다. 입력 뷰에서 추가하세요.'))+'</div>';
  // visited-set으로 중복·사이클을 방지하며 링크 체인을 따라간다.
  const visited=new Set();
  function emitTop(t,linked){
    if(visited.has(t.id)) return; visited.add(t.id);
    const ds=derivedStatus(goals,t);
    const tag=ds==='on_track'?'<span class="otTag">On Track</span>':(ds==='done'?'<span class="otTag" style="border-color:var(--green);color:var(--green);background:rgba(54,192,138,.12)">완료</span>':'');
    const head=linked?('<span style="color:#9b7bff">↗ '+esc(goalTag(t))+' (링크됨)</span> '+esc(t.text)):esc(t.text);
    html+='<h3 style="margin:12px 0 4px" title="'+esc(t.text)+'">'+head+tag+'</h3>';
    if(gnote(r,t.id)) html+='<div class="muted" style="margin-bottom:4px">'+esc(gnote(r,t.id))+'</div>';
    html+=evReportHtml(t);
    const kids=goals.filter(c=>c.parent===t.id && goalPasses(c,goals));
    if(kids.length) html+='<ul>'+kids.map(c=>{ const cs=(c.status||'backlog');
      const m=cs==='in_progress'?' <span style="color:#9be3fb">(진행)</span>':(cs==='done'?' <span class="ok">(완료)</span>':'');
      const note=gnote(r,c.id);
      // 한 줄 고정(.rli): 넘치는 문장은 …로 잘리고, 전문은 title(hover)과 CSV에서 본다.
      const full=(c.text||'')+(note?(' — '+note):'');
      return '<li class="rli" title="'+esc(full)+'">'+esc(c.text)+m+(note?' <span class="muted">— '+esc(note)+'</span>':'')+evReportHtml(c)+'</li>'; }).join('')+'</ul>';
    (t.links||[]).forEach(lid=>{ const lg=byId[lid]; if(lg) emitTop(lg,true); });
  }
  tops.forEach(t=>emitTop(t,false));
  $('report').innerHTML=html;
}

// ===== 리포트 CSV 내보내기 =====
// 화면(리포트)은 1초 안에 훑는 한 줄 요약이고, CSV는 그 반대편 — 사람/팀마다 필요한 축이
// 다르므로 자르지 않은 전 필드를 그대로 싣는다. 받는 쪽이 열을 골라 자기 톤의 보고서를 만든다.
// 행 단위: 목표(부모) 1행 + 자식 1행씩 + 부분과제(task) 1행씩. 화면과 동일한 필터/기간을 따른다.
function csvCell(v){ const s=(v==null?'':String(v)).replace(/\r?\n/g,' ').replace(/"/g,'""'); return '"'+s+'"'; }
function csvHours(sec){ return ((Math.max(0,sec||0))/3600).toFixed(2); }
function buildReportCsv(d,r,conf,prov){
  const goals=r.goals||[], byId={}; goals.forEach(g=>{ byId[g.id]=g; });
  const tops=goals.filter(g=>!g.parent && goalPasses(g,goals) && reportPassesRange(g,goals));
  const cols=['구분','goal','제목','부모goal','부모제목','상태','롤업상태','우선순위','노트',
    '추적시간(h)','추적시간(표시)','진행중','대기중','토큰(k)','가치','에너지','에이전트',
    '세션ID','목표일','완료일','루프','릴리즈','릴리즈ID','아카이브','링크',
    '증거수','증거','부분과제수','effort','mode','cwd','branch','model','이미지수'];
  const rows=[];
  function row(kind,g,parent){
    const ev=g.evidence||[];
    rows.push([
      kind, goalTag(g), g.text||'',
      parent?goalTag(parent):'', parent?(parent.text||''):'',
      statLabel2(g.status||'backlog'), statLabel(derivedStatus(goals,g)), g.priority||'',
      gnote(r,g.id),
      csvHours(g.trackedSeconds), fmtDur(g.trackedSeconds||0),
      (g.startedAt>0?'Y':''), (g.waitingSince>0?'Y':''),
      g.tokens||0, g.value||0, g.energy||0, (g.agents||[]).join(' / '),
      g.sessionId||'', fmtDate(g.targetAt), fmtDate(g.completedAt),
      g.sprint||'', (g.released?'Y':''), g.releaseId||'', (g.archived?'Y':''),
      (g.links||[]).map(id=>byId[id]?goalTag(byId[id]):id).join(' / '),
      ev.length, ev.map(e=>(e.kind==='file'?'📄 ':'🔗 ')+(e.title||e.href||'')+(e.kind==='file'?'':' '+(e.href||''))).join(' | '),
      (g.tasks||[]).length, g.effort||'', g.mode||'', g.cwd||'', g.branch||'', g.model||'',
      (g.images||[]).length
    ].map(csvCell).join(','));
  }
  // 부분과제는 목표 자체 필드를 갖지 않으므로 소유 목표의 맥락만 채운 행으로 싣는다.
  function taskRows(g){
    (g.tasks||[]).forEach(t=>{
      const line=new Array(cols.length).fill('');
      line[0]='부분과제'; line[1]=goalTag(g)+'/'+(t.id||''); line[2]=t.title||t.folder||'';
      line[3]=goalTag(g); line[4]=g.text||''; line[5]=t.status||'';
      rows.push(line.map(csvCell).join(','));
    });
  }
  const visited=new Set();
  function emitTop(t,linked){
    if(visited.has(t.id)) return; visited.add(t.id);
    row(linked?'목표(링크됨)':'목표',t,null); taskRows(t);
    goals.filter(c=>c.parent===t.id && goalPasses(c,goals)).forEach(c=>{ row('자식',c,t); taskRows(c); });
    (t.links||[]).forEach(lid=>{ const lg=byId[lid]; if(lg) emitTop(lg,true); });
  }
  tops.forEach(t=>emitTop(t,false));
  // 1행 요약 메타(기간·가치)를 맨 앞에 주석처럼 얹지 않고 별도 첫 줄로 두면 스프레드시트가
  // 열 정렬을 망치므로, 메타는 파일명에만 담고 CSV 본문은 순수 표로 유지한다.
  return cols.map(csvCell).join(',')+'\n'+rows.join('\n')+'\n';
}
function downloadCsv(b){
  const a=_lastReportArgs; if(!a){ return; }
  const csv=buildReportCsv(a.d,a.r,a.conf,a.prov);
  // BOM: Excel(ko)에서 한글이 깨지지 않게.
  const blob=new Blob(['﻿'+csv],{type:'text/csv;charset=utf-8'});
  const url=URL.createObjectURL(blob), el=document.createElement('a');
  el.href=url; el.download='report-'+String(reportRangeLabel(a.d.date)).replace(/[^0-9A-Za-z_-]+/g,'_')+'.csv';
  document.body.appendChild(el); el.click(); el.remove();
  setTimeout(()=>URL.revokeObjectURL(url),1000);
  if(b){ const o=b.textContent; b.textContent='내려받음'; setTimeout(()=>{b.textContent=o;},1200); }
}

// 활동 차트(drawChart)·시간대 앱 띠(drawStrip)·앱 통계(appStats)·주요 앱 렌더(renderApps)는
// 컨디션 관리 페이지(/bgm-player)의 컨디션맵 탭으로 이동했다 — 대시보드에선 제거.
// minOfDay 헬퍼도 이들 전용이라 함께 제거.

// ===== Workers (background jobs) =====
// The 워커/크론 surface moved to its OWN page (/cron, served by AppDelegate.cronPage) so it no
// longer depends on this dashboard document. renderWorkers/toggleWorker/runWorker/tickWorkers and
// the fmtInterval/fmtAgo helpers now live inline in that page, polling /workers.json on their own.
// ===== Self-audit for the QA agent (deterministic UI-breakage detection) =====
// Pixel-measure elements that should stay on ONE line — table headers, buttons, chips,
// and short table cells — and flag any whose short label wraps to 2+ lines or overflows
// horizontally. This catches font-size / column-width breakage (e.g. '자동 생성' breaking
// to two lines) reliably, which a downscaled screenshot can't. The QA runner reads the
// published result via headless Chrome --dump-dom at real widths, so it sees the WHOLE
// page (no screenshot height cutoff) and spends no AI tokens unless something is found.
function runQaAudit(){
  const issues=[];
  const els=document.querySelectorAll('th, .btn, .chip, #workerrows td, table td');
  els.forEach(el=>{
    const txt=(el.textContent||'').replace(/\s+/g,' ').trim();
    if(!txt) return;
    const cs=getComputedStyle(el);
    if(cs.display==='none'||el.offsetParent===null) return;
    const fs=parseFloat(cs.fontSize)||13;
    let lh=parseFloat(cs.lineHeight); if(!lh||isNaN(lh)) lh=fs*1.4;
    // Measure the TEXT's own height, not the cell box. A td in a vertical-align:top row
    // inherits the ROW height (tallest sibling cell), so clientHeight makes every short
    // cell read as multi-line when any one cell in the row wraps. A Range over the
    // element's contents reports the actual rendered text bounds, immune to row stretch.
    let textH=0;
    try{ const rg=document.createRange(); rg.selectNodeContents(el);
      textH=rg.getBoundingClientRect().height; }catch(e){}
    if(!textH) textH=lh;
    const lines=Math.max(1, Math.round(textH/lh));
    const horizOverflow=el.scrollWidth>el.clientWidth+2;
    // Headers/buttons/chips should never wrap; table cells only flagged for SHORT text
    // (long prose like goal titles is allowed to wrap).
    const isShortCell=el.tagName==='TD' ? txt.length<=14 : true;
    if(isShortCell && (lines>=2 || horizOverflow)){
      issues.push({tag:el.tagName.toLowerCase(),
        cls:(el.className||'').toString().slice(0,40),
        text:txt.slice(0,40), lines:lines, overflow:horizOverflow,
        w:Math.round(el.getBoundingClientRect().width)});
    }
  });
  return issues;
}
let _qaAuditLast='', _qaAuditLastPost=0;
function publishQaAudit(){
  try{
    const issues=runQaAudit();
    let node=document.getElementById('qaAudit');
    if(!node){ node=document.createElement('div'); node.id='qaAudit';
      node.style.display='none'; document.body.appendChild(node); }
    node.setAttribute('data-width', String(window.innerWidth));
    node.textContent=JSON.stringify(issues);
    // Push to the app so the QA runner reads exactly what THIS real viewport renders —
    // no headless timing/height guesswork. POST when the finding set changes OR as a
    // ~20s heartbeat, so a fresh timestamp means "dashboard open, measurement current".
    const sig=window.innerWidth+'|'+JSON.stringify(issues);
    const now=Date.now();
    if(sig!==_qaAuditLast || now-_qaAuditLastPost>20000){
      _qaAuditLast=sig; _qaAuditLastPost=now;
      fetch('/api/qa-audit',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({width:window.innerWidth, ts:now, issues:issues})}).catch(()=>{});
    }
  }catch(e){}
}
restoreFromURL();   // 해시에 저장된 뷰·필터 설정을 첫 렌더 전에 복원(새로고침 후에도 유지)
// Open the plugins overlay when arrived here from another page's rail settings menu (?plugins=1).
try{ if(new URLSearchParams(location.search).get('plugins')==='1' && typeof openPlugins==='function'){ setTimeout(openPlugins,80); } }catch(e){}
load();
// 새로고침 후에도 localStorage 에 남은 초안이 있으면 이어쓰기 칩을 되살린다.
try{ if(typeof updateGaDraftChip==='function') updateGaDraftChip(); }catch(e){}
window.addEventListener('resize', load);
// 부모 채우기 무장: Cmd(또는 Ctrl)를 누르는 동안 부모#칸이 채우기 소스로 강조된다.
document.addEventListener('keydown',function(e){ if(e.key==='Meta'||e.key==='Control') document.body.classList.add('armparent'); });
document.addEventListener('keyup',  function(e){ if(e.key==='Meta'||e.key==='Control') document.body.classList.remove('armparent'); });
window.addEventListener('blur',function(){ document.body.classList.remove('armparent'); });
// Run the QA self-audit independently of load(), so it still fires (and re-measures on
// resize) even if a render path hiccups. Cheap; only POSTs when the finding set changes.
setInterval(publishQaAudit, 7000);
window.addEventListener('resize', publishQaAudit);
setTimeout(publishQaAudit, 1500);

// ===== Pixel bard perched on the goal input =====
// Idle by default; plays a short "buff performance" (notes rise from a raised
// hand) once a minute. Same pixel data as the macOS menu-bar bard.
(function(){
  var cv=document.getElementById('bardCanvas'); if(!cv) return;
  var ctx=cv.getContext('2d'); ctx.imageSmoothingEnabled=false;
  var PAL={'.':null,o:'#2a2440',p:'#7b5cff',r:'#ff6b3d',s:'#ffd0a3',e:'#15101f',t:'#21c7b8',b:'#4a3b73',w:'#e0863a',m:'#ffd9a0',n:'#ffd84d'};
  var idle=["................",".......oo.......","......orro......","....oorppo......","...opppppo......","...opppppo......","...osssso.......","...oseseo.......","...osssso.......","....oooo........","...ottto........","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var cast1=["................",".......oo.......","......orro......","....oorppo......","...opppppo......","...opppppo......","...osssso....n..","...oseseo.......","...osssso..oso..","....oooo..osso..","...ottto.oso....","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var cast2=["................",".......oo.......","......orro......","....oorppo......","...opppppo...n..","...opppppo......","...osssso...n...","...oseseo.......","...osssso..oso..","....oooo..osso..","...ottto.oso....","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var cast3=["................",".......oo.......","......orro....n.","....oorppo...n..","...opppppo......","...opppppo...n..","...osssso.......","...oseseo.......","...osssso..oso..","....oooo..osso..","...ottto.oso....","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var cast4=["..............n.",".......oo.......","......orro......","....oorppo...n..","...opppppo......","...opppppo......","...osssso.......","...oseseo.......","...osssso..oso..","....oooo..osso..","...ottto.oso....","..otttttto......","..ottwwwtto.....","..obtwmwwto.....","...otwwwto......","...oo..oo......."];
  var casts=[cast1,cast2,cast3,cast4], SC=3;
  function draw(g){ ctx.clearRect(0,0,48,48);
    for(var y=0;y<g.length;y++){ var row=g[y];
      for(var x=0;x<row.length;x++){ var c=PAL[row[x]]; if(!c) continue; ctx.fillStyle=c; ctx.fillRect(x*SC,y*SC,SC,SC); } } }
  var frameTimer=null;
  function playBuff(){ if(frameTimer) return;
    var start=Date.now(), i=0;
    frameTimer=setInterval(function(){
      if(Date.now()-start>=3500){ clearInterval(frameTimer); frameTimer=null; draw(idle); return; }
      draw(casts[i%4]); i++;
    },130);
  }
  draw(idle);
  playBuff();                 // play once on load as feedback
  setInterval(playBuff,60000); // then once a minute
})();
</script>
<script>
// 대화 패널 분할 드래그 — 폭은 --cmchat-w 하나로 흐르고 localStorage 에 영속된다.
(function(){
  var MIN=340, root=document.documentElement;
  function apply(w){ root.style.setProperty('--cmchat-w', w+'px'); }
  // 보드에 남겨 줄 최소 폭. 레일이 이미 --cmrail-w 만큼 먹고 있으므로 그것까지 빼고 계산한다
  // (이걸 빼먹어서 창 1400px·레일 240px 에서 보드가 280px 밖에 못 받고 무너졌다).
  function railW(){ return parseInt(getComputedStyle(root).getPropertyValue('--cmrail-w'),10) || 0; }
  function clamp(w){
    var max=Math.max(MIN, window.innerWidth - railW() - 560);
    return Math.min(max, Math.max(MIN, w));
  }
  var saved=0; try{ saved=parseInt(localStorage.getItem('cmChatW')||'0',10)||0; }catch(e){}
  if(saved) apply(clamp(saved));
  var grip=document.getElementById('cmChatGrip'), frame=document.getElementById('cmChatFrame'), drag=false;
  if(grip) grip.addEventListener('mousedown', function(e){
    drag=true; e.preventDefault();
    // 드래그 중에는 iframe 이 마우스를 삼키지 않게 막는다.
    if(frame) frame.style.pointerEvents='none';
    document.body.style.cursor='col-resize';
  });
  window.addEventListener('mousemove', function(e){
    if(!drag) return;
    apply(clamp(window.innerWidth - e.clientX));
  });
  window.addEventListener('mouseup', function(){
    if(!drag) return;
    drag=false;
    if(frame) frame.style.pointerEvents='';
    document.body.style.cursor='';
    var w=parseInt(getComputedStyle(root).getPropertyValue('--cmchat-w'),10);
    if(w) try{ localStorage.setItem('cmChatW', String(w)); }catch(e){}
  });
  window.addEventListener('resize', function(){
    var w=parseInt(getComputedStyle(root).getPropertyValue('--cmchat-w'),10);
    if(w) apply(clamp(w));
  });
  window.CMChatReclamp=function(){
    var w=parseInt(getComputedStyle(root).getPropertyValue('--cmchat-w'),10);
    if(w) apply(clamp(w));
  };
})();
</script>
<script>
// 보드가 실제로 쓸 수 있는 폭을 감시해 body.cmnarrow / body.cmxnarrow 를 붙인다.
// 뷰포트 @media 로는 3단계(오른쪽 대화 패널이 붙은 상태)를 잡을 수 없기 때문 —
// 창은 넓은데 보드만 좁은 상황이 여기서 유일하게 정확히 측정된다.
(function(){
  var NARROW=760, XNARROW=520;
  function board(){ return document.querySelector('.wrap'); }
  function paint(){
    var el=board(); if(!el) return;
    // 보드가 숨겨진 단계(1·2단계)에서는 폭이 0으로 읽히므로 건드리지 않는다.
    var w=el.clientWidth; if(!w) return;
    document.body.classList.toggle('cmnarrow', w<=NARROW);
    document.body.classList.toggle('cmxnarrow', w<=XNARROW);
    if(window.CMChatReclamp) window.CMChatReclamp();
  }
  function boot(){
    var el=board(); if(!el) return;
    if(window.ResizeObserver){ new ResizeObserver(paint).observe(el); }
    window.addEventListener('resize', paint);
    paint();
  }
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
</script>
</body>
</html>
"""#
    }
}
