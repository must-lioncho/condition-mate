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
<title>Condition Manager — 활동</title>
<style>
  :root{--bg:#0f1115;--panel:#171a21;--line:#232733;--mut:#8b93a7;--fg:#e7ebf3;--accent:#5b8cff;--green:#36c08a;--red:#e2667d;}
  *{box-sizing:border-box} html,body{margin:0}
  body{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,BlinkMacSystemFont,system-ui,sans-serif}
  .wrap{max-width:980px;margin:0 auto;padding:28px 20px}
  h1{font-size:18px;margin:0 0 4px}
  h2{font-size:14px;margin:22px 0 10px;color:var(--fg)}
  .sub{color:var(--mut);font-size:13px;margin-bottom:20px}
  .cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:8px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 16px;flex:1;min-width:150px}
  .card .k{color:var(--mut);font-size:12px}
  .card .v{font-size:22px;font-weight:700;margin-top:4px}
  .card .cap{color:var(--mut);font-size:11px;margin-top:3px}
  /* 스포츠 모드: APM 게이지만 남기고 카드·티어 바·지금-라인 텍스트 숨김 */
  .wrap.sports #cards,
  .wrap.sports .tierpanel,
  .wrap.sports .nowtext,
  /* 스포츠 모드: 필터 요약(로그성 텍스트)은 숨기고, 타임 모드에서만 디테일하게 노출 (디버깅용) */
  .wrap.sports #flt_summary,
  /* 스포츠 모드: 확정 가치 아래 상세 섹션(요약·차트·타임라인·주요앱·BGM·워커) 통째로 숨김 */
  .wrap.sports #detailSections{display:none}
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
  .gtbl .nm{white-space:normal;word-break:break-word}
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
  /* Parent indicator in release log: gray = has a parent (shows parent's number), purple = is top-level. */
  .relrow .pn{font-variant-numeric:tabular-nums;margin-right:6px;font-size:11px;border-radius:6px;padding:1px 6px;border:1px solid var(--line);color:var(--mut)}
  .relrow .pn.top{color:#9b7bff;border-color:rgba(155,123,255,.4);background:rgba(155,123,255,.12)}
  /* Sprint board: sprint groups + backlog (Jira-style) */
  .spgrp{border:1px solid var(--line);border-radius:10px;margin:0 0 12px;background:#11151f;overflow:hidden}
  .spgrp.dropOver{border-color:var(--accent);background:rgba(91,140,255,.07)}
  .spgrp.bg{border-style:dashed}
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
  .bgoal.child{padding-left:24px;background:rgba(255,255,255,.015)}
  .bgoal .grip{color:#3a4150}
  .bgoal .t{flex:1;min-width:60px}
  .bgchev{cursor:pointer;color:var(--mut);width:14px;text-align:center;display:inline-block;font-size:11px;user-select:none}
  .bgsp{display:inline-block;width:14px}
  .bgoal .pref{margin-left:8px;font-size:11px;color:var(--mut);border:1px solid var(--line);border-radius:999px;padding:1px 7px;white-space:nowrap}
  /* 상태 콤보 왼쪽의 부모 번호 입력칸 (예: 02 입력 → goal-02 의 자식으로). */
  .bgoal .pin{width:54px;flex:none;text-align:center;font-size:12px;color:var(--fg);background:#0e1320;border:1px solid var(--line);border-radius:6px;padding:2px 0;margin-right:6px}
  .bgoal .pin::placeholder{color:#4a5163}
  .bgoal .pin:focus{outline:none;border-color:var(--accent)}
  .bgoal .pin-sp{width:54px;flex:none;margin-right:6px;display:inline-block}
  /* 부모 채우기(fill-down): Cmd 누르면 부모칸이 채우기 소스로 무장(hover 강조), 드래그 중 대상 행 강조 */
  body.armparent .bgoal .pin{cursor:cell}
  body.armparent .bgoal .pin:hover{border-color:var(--accent);box-shadow:0 0 0 2px rgba(91,140,255,.4)}
  body.parfilling,body.parfilling *{cursor:cell !important;user-select:none}
  .bgoal.parfill{background:rgba(91,140,255,.12);box-shadow:inset 2px 0 0 var(--accent)}
  .bgoal.parsrc .pin{border-color:var(--accent);box-shadow:0 0 0 2px rgba(91,140,255,.55)}
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
  /* 스프린트 메뉴: 라벨이 길어 줄바꿈 허용 + 폭 확대 */
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
  /* 스프린트 편집 모달 */
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
  /* 스프린트 관리: 생성 폼 + 기간 칩 + 스프린트 카드 */
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
  .gchild .gt{flex:1;min-width:80px}
  .gsec-add{display:flex;gap:6px;margin-top:6px}
  .hdr{display:flex;align-items:center;justify-content:space-between;gap:12px}
  .overlay{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:flex-start;justify-content:center;padding:40px 16px;overflow:auto;z-index:50}
  .overlay.on{display:flex}
  .modal{background:var(--panel);border:1px solid var(--line);border-radius:14px;max-width:720px;width:100%;padding:24px}
  .modal h2{margin-top:18px} .modal h2:first-child{margin-top:0}
  .modal ul{margin:6px 0;padding-left:18px} .modal li{margin:3px 0}
  .modal .muted{color:var(--mut)}
  .pill{display:inline-block;padding:1px 7px;border-radius:999px;font-size:11px;border:1px solid var(--line);margin-right:4px}
  a.pill.gp{cursor:pointer;text-decoration:none;color:inherit}
  a.pill.gp:hover{border-color:var(--accent);color:var(--accent)}
  .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
  input[type=text],input[type=number]{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 9px;font-size:13px}
  input[type=range]{vertical-align:middle}
  .goal{display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:5px 0;border-bottom:1px solid var(--line)}
  .goal .g{flex:1;position:relative}
  /* Editable goal title: double-click to rename in place (목록 + 그룹 자식 행). */
  .gt{cursor:text;border-radius:5px;padding:1px 4px;margin:0 -4px}
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
  .schrow .st{flex:1;min-width:120px}
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
  /* Conversation thread inside the AI 중복 확인 다이얼로그. */
  .dupconv{display:flex;flex-direction:column;gap:10px;max-height:38vh;overflow-y:auto;padding:2px}
  .dupconv:empty{display:none}
  .dupsug{align-self:flex-start;margin:2px 0 0 36px}
  .dupsug button{font-size:12px;padding:4px 10px}
  .duppending{align-self:flex-start;color:var(--mut);font-size:13px;padding:2px 2px 2px 36px}
  /* AI 큐(bump out): 실행 상태 표시 + 분석 중 행 강조. */
  .qrun{display:inline-flex;align-items:center;gap:5px;color:var(--green);font-weight:600;font-size:12px}
  .qrun .qdot{width:7px;height:7px;border-radius:50%;background:var(--green);animation:qpulse 1s infinite}
  @keyframes qpulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.35;transform:scale(.7)}}
  .qrow{display:flex;gap:8px;align-items:flex-start;padding:6px 0;border-top:1px solid var(--line);transition:background .2s}
  .qrow.analyzing{background:rgba(64,200,120,0.10);border-radius:6px;padding:6px 8px;border-top-color:transparent}
  .qspin{display:inline-block;animation:cpd 1.2s infinite}
</style>
</head>
<body>
\#(SessionRail.html())
<div class="wrap sports">
  <div class="hdr">
    <div>
      <h1>오늘 활동 · BGM 디버그 <span id="devBadge" class="devbadge" style="display:none"></span></h1>
      <div class="sub" id="date">불러오는 중…</div>
    </div>
    <div style="display:flex;align-items:center;gap:10px">
      <span id="perf" title="이 대시보드 페이지의 자원 사용량 (메모리=JS 힙, CPU=프레임 타이밍 근사치)"
            style="font-size:11px;color:var(--mut);font-variant-numeric:tabular-nums;white-space:nowrap">측정 중…</span>
      <button class="btn primary gtoggle" id="mode_toggle" onclick="toggleGaugeMode()" title="스포츠=라이브 APM 바운싱 (집중·재미), 타임=토탈 시간 카운트업 (체력 총량). 8시간+엔 타임 자동. 클릭하면 전환">⚡ 스포츠</button>
    </div>
  </div>

  <div class="cards" id="cards">
    <div class="card lead"><div class="k">토탈 시간</div><div class="v" id="t_total">–</div><div class="cap">업무 스팬 (휴식·미팅 포함)</div></div>
    <div class="card"><div class="k">책상 시간</div><div class="v" id="t_desk">–</div><div class="cap">만들기 시도 (리서치+코딩)</div></div>
    <div class="card"><div class="k">집중 시간</div><div class="v" id="t_focus">–</div><div class="cap">몰입 (에디터)</div></div>
    <div class="card"><div class="k">퇴근</div><div class="v" id="t_off">–</div><div class="cap">6시간+ 공백</div></div>
    <div class="card"><div class="k">오늘 가치 (확정)</div><div class="v" id="value">–</div><div class="cap">승인 전 = 0 (아래 절차)</div></div>
  </div>
  <div class="panel tierpanel" style="margin:6px 0;padding:12px 16px">
    <canvas id="tiers" style="height:18px"></canvas>
    <div class="legend">
      <span><span class="dot" style="background:#2a2f3a;border:1px solid #444"></span>토탈(회색=휴식·미팅)</span>
      <span><span class="dot" style="background:#e8a13a"></span>책상</span>
      <span><span class="dot" style="background:#36c08a"></span>집중</span>
      <span>· 누적 <b id="total">–</b></span>
      <span>· <span id="status">–</span></span>
    </div>
  </div>
  <div class="nowline" id="now">지금: –</div>

  <div id="viewTabs" class="viewtabs"></div>
  <div class="panel">
    <!-- SHARED STATUS FILTER — one bar drives 목록·그룹·프리뷰 alike -->
    <div class="row" style="margin:0 0 8px;gap:6px">
      <button class="btn combo" id="flt_status_combo" onclick="openStatusFilter(event)" title="표시할 상태를 선택 (다중 선택)">보기<span class="cbadge" id="flt_status_cnt" style="display:none">0</span> <span class="cv">▾</span></button>
      <button class="btn combo" id="flt_sprint_combo" onclick="openSprintFilter(event)" title="스프린트로 목록 필터 (다중 선택 · 릴리즈된 목표는 숨김)">스프린트<span class="cbadge" id="flt_sprint_cnt" style="display:none">0</span> <span class="cv">▾</span></button>
      <span class="muted" id="flt_summary" style="font-size:12px">— 모두 표시</span>
    </div>
    <!-- COMPLETION-TIME CUTOFF — hide 완료 goals finished before this instant -->
    <div class="row" style="margin:0 0 8px;gap:6px">
      <span class="muted" style="font-size:12px">완료 컷오프</span>
      <input type="datetime-local" id="flt_donesince" class="btn" style="padding:4px 6px" value="2026-06-24T17:00"
             onchange="setDoneSince(this.value)" title="이 시각 이전에 완료된 목표는 숨깁니다 (완료 외 상태는 영향 없음)">
      <button class="btn" id="flt_donesince_clear" onclick="clearDoneSince()" title="완료 컷오프 해제 (모든 완료 표시)">해제</button>
    </div>
    <!-- INPUT VIEW -->
    <div id="inputView">
      <div class="row">목표 추가:
        <span class="bardwrap">
          <canvas id="bardCanvas" width="48" height="48" aria-hidden="true" title="음유시인이 1분마다 버프를 연주합니다"></canvas>
          <input type="text" id="goalText" placeholder="목표/디테일 입력 후 Enter (계속 추가)" style="width:100%"
                 onkeydown="goalKey(event)">
        </span>
        <span class="infowrap">
          <button class="btn" id="aiAddBtn" onclick="aiAdd()" oncontextmenu="return toggleAiTip(event)">AI추가</button>
          <div class="infotip" id="aiTip">번호를 보고 각 목표의 <b>부모#</b> 칸에 부모 번호를 입력하면 묶입니다 (비우면 최상위). 압축된 결과는 프리뷰에서 확인. <b>AI추가</b>는 기다리지 않고 큐에 담아 백그라운드로 중복을 분석합니다 — 결과는 아래 <b>AI 큐</b>에서 원탭으로 확정.</div>
        </span>
        <button class="btn" onclick="addGoal()">추가</button>
      </div>
      <div id="goals"></div>
      <div id="aiQueue"></div>
    </div>

    <!-- PREVIEW (REPORT) VIEW -->
    <div id="previewView" style="display:none">
      <div class="row" style="justify-content:flex-end">
        <button class="btn" onclick="copyMd()">마크다운 복사</button>
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

    <!-- TOKEN VIEW (토큰 — 완료 항목의 토큰 사용량을 완료일·스프린트로 묶어 본다) -->
    <div id="tokenView" style="display:none">
      <div class="muted" style="font-size:12px;margin:0 0 6px">완료된 목표의 <b>토큰 사용량</b>을 <b>완료 시각</b> 기준으로 묶습니다(오늘·어제·이번 주·이전). 위의 <b>스프린트</b>·<b>완료 컷오프</b> 필터가 그대로 적용되어, 예를 들어 "어제 어느 스프린트에 토큰을 얼마나 썼는지"를 바로 볼 수 있습니다.</div>
      <div id="tokenHost"></div>
    </div>

    <!-- SCHEDULE VIEW (일정관리 — resource management) -->
    <div id="scheduleView" style="display:none">
      <div class="muted" style="font-size:12px;margin:0 0 4px">목표 날짜·완료 날짜로 리소스를 관리합니다. 각 목표의 <b>목표</b> 날짜시간을 정하면 긴급도(지남·오늘·이번 주·예정)로 묶입니다. 상태를 완료로 바꾸면 <b>완료</b> 시각이 자동 기록되며, 필요하면 직접 수정할 수 있습니다.</div>
      <div id="scheduleSections"></div>
    </div>

    <!-- SPRINT VIEW (스프린트 관리 — Jira식 백로그 보드 + 완료 로그) -->
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
        <button class="btn" id="archPlainBtn" onclick="archPlainSearch()" title="번호·내용·스프린트 코드의 글자 일치 검색 (즉시)">일반 검색</button>
        <button class="btn" id="archClearBtn" onclick="archClear()" title="검색을 지우고 전체 목록 표시">전체</button>
        <span class="muted" id="archSummary" style="font-size:12px"></span>
      </div>
      <div id="archHelp" class="muted" style="display:none;font-size:12px;margin:0 0 8px;padding:8px 10px;border:1px solid var(--border);border-radius:6px">스프린트 릴리즈로 비워진 것까지 포함해 <b>모든 목표</b>를 한곳에서 봅니다. <b>AI 검색</b>은 내용을 입력하면 표현이 달라도 의미가 비슷한 목표를 모두 찾아줍니다(기본). <b>일반 검색</b>은 번호·내용·스프린트 코드의 글자 일치입니다. 아카이브 항목은 <b>복원</b>으로 활성 목록에 되돌립니다.</div>
      <div id="archivedList"></div>
    </div>

  </div>

  <!-- 스포츠 모드에선 통째로 숨기고 렌더(로딩)도 건너뛴다 (요약·차트·타임라인·주요앱·BGM·워커) -->
  <div id="detailSections">
  <div class="panel" style="margin-bottom:6px"><div id="summary" class="empty">최근 요약 불러오는 중…</div></div>

  <div class="panel">
    <canvas id="chart"></canvas>
    <canvas id="strip"></canvas>
    <div class="legend">
      <span><span class="dot" style="background:var(--accent)"></span>전체 활동량</span>
      <span><span class="dot" style="background:var(--green)"></span>⌨ 키보드</span>
      <span><span class="dot" style="background:#e8a13a"></span>🖱 마우스</span>
      <span>아래 띠: 시간대별 주 활성 앱(색상)</span>
    </div>
  </div>

  <h2>타임라인 로그 (분 단위 · 최신순)</h2>
  <div class="panel">
    <table>
      <thead><tr><th>시간</th><th>길이</th><th>앱 · 사이트</th><th>무드</th><th>BGM 트랙</th><th>활동 (⌨/🖱)</th><th>구분</th></tr></thead>
      <tbody id="logrows"><tr><td colspan="7" class="empty">데이터 없음</td></tr></tbody>
    </table>
  </div>

  <h2>주요 앱 (오늘)</h2>
  <div class="panel"><div class="bars" id="appbars"><span class="empty">데이터 없음</span></div></div>

  <h2>앱별 BGM (적절성 디버그)</h2>
  <div class="panel">
    <table>
      <thead><tr><th>앱</th><th>주 전략</th><th>재생된 BGM 트랙 (BPM)</th><th>활성</th></tr></thead>
      <tbody id="bgmrows"><tr><td colspan="4" class="empty">데이터 없음</td></tr></tbody>
    </table>
    <div class="legend"><span><span class="chip bad" style="margin:0">예시</span> = 전략 밴드를 벗어난 트랙(부적절 의심)</span></div>
  </div>

  <h2 style="display:flex;align-items:center;justify-content:space-between">워커 상태 (백그라운드 작업)
    <a class="btn" href="/worker-log" target="_blank" style="font-size:12px;font-weight:400">전체 로그 타임라인</a></h2>
  <div class="panel">
    <table>
      <thead><tr><th>워커</th><th>구분</th><th>하는 일</th><th>주기</th><th>마지막 실행</th><th>다음 실행</th><th>실행</th><th>상태</th><th>로그</th></tr></thead>
      <tbody id="workerrows"><tr><td colspan="9" class="empty">데이터 없음</td></tr></tbody>
    </table>
    <div class="legend"><span><span class="chip" style="margin:0">동작 중</span> = 일정대로 실행 중 · <span class="chip bad" style="margin:0">유휴</span> = 현재 멈춤(세션 비활성 등) · <span class="chip bad" style="margin:0">오류</span> = 데이터 싱크 이상(로그 확인) · <b>구분</b> 기본=항상 실행, 플러그인=연결 시에만, 자동화=외부 스케줄러(launchd)가 주기 실행, 수동=퇴근 시 손으로 실행(주기 칸은 1회 실행 중 라운드 간격)</span></div>
  </div>
  </div><!-- /#detailSections -->

  <div class="row" style="justify-content:center;margin-top:18px">
    <button class="btn" id="pluginBtn" onclick="openPlugins()" title="외부 연동 플러그인 관리">🧩 플러그인</button>
  </div>
  <div class="foot">5초마다 자동 갱신 · 127.0.0.1 로컬 전용</div>
</div>

<div class="overlay" id="plugins">
  <div class="modal">
    <div class="hdr"><h1 style="margin:0">🧩 플러그인</h1>
      <button class="btn" onclick="document.getElementById('plugins').classList.remove('on')">닫기</button></div>
    <p class="muted">기능을 플러그인으로 관리합니다. <b>설치형</b>은 설치하면 바로 켜지고(예: 컨디션 메이트 — 설치 시 BGM 동작), <b>폴더형</b>은 <b>프로젝트 폴더 선택 + 내용 검증</b>으로 연결하며 아무 폴더나 고르면 <b>잘못된 연결</b>로 표시됩니다.</p>
    <div id="pluginList"><div class="empty">불러오는 중…</div></div>
  </div>
</div>

<!-- 공용 팝업: 보기(상태) 콤보·⋯ 메뉴·우클릭 이동 등. 어떤 뷰에서도 보이도록 최상위에 둔다
     (뷰 컨테이너 안에 두면 그 뷰가 숨겨질 때 position:fixed라도 렌더되지 않는다). -->
<div id="popup" class="popup" style="display:none"></div>

<!-- AI추가 중복 확인 다이얼로그: AI가 유사 목표를 찾으면 지금 추가(confirm)할지,
     나중 큐에 쌓아둘지(later) 고른다. -->
<div class="overlay" id="dupModal">
  <div class="modal" id="dupDrop">
    <div class="hdr"><h1 style="margin:0">🤖 AI 중복 확인</h1>
      <button class="btn" onclick="closeDup()">닫기</button></div>
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
      <button class="btn" onclick="dupLater()" title="지금은 결정하지 않고 아래 큐에 쌓아둡니다 — 나중에 하나씩 검토">later (큐에 보관)</button>
      <button class="btn" id="dupConfirmBtn" onclick="dupConfirm()" title="위 '추가하려는 목표' 문구로 지금 추가합니다">confirm (지금 추가)</button>
    </div>
  </div>
</div>

<!-- 재사용 목표 추가 모듈: 스프린트 보드(Backlog·각 스프린트)에서 같은 입력·AI추가·추가 UI를
     공유한다. 상단 항상 보이는 입력바와 동일한 add 흐름(goalAddSubmit/goalAddAi)을 쓴다. -->
<div class="overlay" id="gaModal">
  <div class="modal" style="max-width:560px">
    <div class="hdr"><h1 style="margin:0;font-size:16px">목표 추가 <span class="muted" id="gaWhere" style="font-size:13px;font-weight:400"></span></h1>
      <button class="btn" onclick="closeGoalAdd()">닫기</button></div>
    <div class="row">
      <input type="text" id="gaText" placeholder="목표/디테일 입력 후 Enter (계속 추가)" style="flex:1;min-width:200px">
      <button class="btn" id="gaAiBtn" onclick="gaAi()" title="추가 전에 AI가 비슷한 목표가 있는지 먼저 검사합니다">AI추가</button>
      <button class="btn primary" onclick="gaAdd()">추가</button>
    </div>
    <div class="muted" style="font-size:12px;margin-top:8px">Enter로 계속 추가할 수 있습니다. <b>AI추가</b>는 비슷한 목표가 있는지 먼저 확인합니다.</div>
  </div>
</div>
<script>
const $ = id => document.getElementById(id);
const PALETTE = ['#5b8cff','#36c08a','#e8a13a','#c879e6','#e2667d','#3ac6c6','#d98c5f','#9aa4b2'];
const colorCache = {};
function appColor(a){
  if(colorCache[a]) return colorCache[a];
  let h=0; for(const c of a) h=(h*31+c.charCodeAt(0))>>>0;
  const col = PALETTE[h % PALETTE.length]; colorCache[a]=col; return col;
}
// strategy label -> [minBPM, maxBPM]
const BANDS = {'칠 (느긋)':[75,100],'스테디 (안정)':[100,125],'집중 (몰입)':[120,150],'하이프 (고조)':[140,175]};
function trackBpm(t){ const m=/\[(\d{2,3})\]/.exec(t||''); return m?parseInt(m[1],10):null; }
function fmtMin(m){ if(m>=60) return (m/60).toFixed(1)+'시간'; return m+'분'; }
// "Accelerator" gauge: live APM (actions/min, StarCraft-style). Backend polled
// fast (~100ms); the number + bar are driven by a damped SPRING every animation
// frame so they snap toward the target with a little tachometer kick (overshoot).
// Juice: zone color (green->amber->red), a redline pulse glow, and a VU-style
// peak-hold marker that floats down from the recent max.
let _apmTo=0,_apmAt=0,_apmV=0,_nmTo=0,_nmAt=0,_nmV=0,_peak=0,_gaugeOn=false,_lastT=0;
const SPRING_K=500, SPRING_D=26;   // stiffness / damping => zeta~0.58, ~250ms snap, ~8% overshoot
// --- Gauge mode: 스포츠(라이브 APM 바운싱) ↔ 타임(토탈 시간 카운트업) ----------
// 시작 1시간 이전엔 스포츠로 집중·재미에, 8시간을 넘기면 타임으로 체력 총량의
// 뿌듯함에 포커스가 가도록 자동 기본값을 정한다. 사용자가 직접 토글하면 자동
// 전환은 멈춘다(_modeUserSet). 타임 모드는 토탈 시간을 초 단위로 카운트업한다.
let _gaugeMode='sports', _modeUserSet=false;
let _totalBaseSec=0, _totalBaseWall=0, _working=false;
function fmtClock(sec){
  sec=Math.max(0,Math.floor(sec));
  const h=Math.floor(sec/3600), m=Math.floor((sec%3600)/60), s=sec%60;
  const p=n=>('0'+n).slice(-2);
  return h+':'+p(m)+':'+p(s);
}
function ensureTimeGauge(){
  const host=$('accel'); if(!host) return false;
  if(host.dataset.tbuilt!=='1'){
    host.innerHTML=' &nbsp; <span style="color:var(--mut)">토탈 </span>'
      +'<span id="apmtime" style="display:inline-block;font-variant-numeric:tabular-nums;font-weight:700">0:00:00</span>'
      +'<span id="apmtlab" style="color:var(--mut)"></span>';
    host.dataset.tbuilt='1';
  }
  return true;
}
function renderTime(){
  if(!ensureTimeGauge()) return;
  const live=_working ? (Date.now()-_totalBaseWall)/1000 : 0;
  const num=$('apmtime'); if(num){ num.textContent=fmtClock(_totalBaseSec+live); num.style.color=_working?'var(--green)':'var(--fg)'; }
  const lab=$('apmtlab'); if(lab) lab.textContent=_working?' · 진행 중':' · 정지';
}
function toggleGaugeMode(){ setGaugeMode(_gaugeMode==='time'?'sports':'time', true); }
function setGaugeMode(m, byUser){
  _gaugeMode=m;
  if(byUser) _modeUserSet=true;
  const tg=$('mode_toggle');
  if(tg) tg.textContent=(m==='time')?'⏱ 타임':'⚡ 스포츠';
  // 스포츠 = APM 게이지만 (스포츠 집중), 타임 = 모든 정보 디테일
  const wrap=document.querySelector('.wrap');
  if(wrap) wrap.classList.toggle('sports', m!=='time');
  const host=$('accel');
  if(host){ host.innerHTML=''; host.dataset.built=''; host.dataset.tbuilt=''; }
  if(m==='time') renderTime();   // 스포츠는 다음 라이브 틱에서 재구성
  // 사용자가 타임으로 직접 전환하면, 스포츠 동안 건너뛴 상세 섹션을 즉시 로딩한다.
  // byUser 가드로 load() 내부 자동 기본값(setGaugeMode(...,false)) 재귀를 막는다.
  if(byUser && m==='time') load();
}
function ensureGauge(){
  const host=$('accel'); if(!host) return false;
  if(host.dataset.built!=='1'){
    host.innerHTML=' &nbsp; <span id="apmlab" style="color:var(--mut)">APM </span>'
      +'<span id="apmnum" style="display:inline-block;min-width:4ch;text-align:right;font-variant-numeric:tabular-nums;font-weight:700">0</span>'
      +' <span id="apmbar" style="position:relative;display:inline-block;width:96px;height:9px;border-radius:5px;background:#1b1f29;vertical-align:middle;overflow:hidden">'
      +'<span id="apmfill" style="position:absolute;left:0;top:0;height:100%;width:0%;background:#36c08a"></span>'
      +'<span id="apmpeak" style="position:absolute;top:0;height:100%;width:2px;background:#fff;opacity:.65;left:0%"></span></span>'
      +'<span id="apmgear" style="color:var(--mut)"></span><span id="apmnext" style="color:var(--mut)"></span>';
    host.dataset.built='1';
  }
  return true;
}
function zoneColor(x){   // 0 -> green, 0.6 -> amber, 1 -> red
  const h = x<0.6 ? 145-(145-42)*(x/0.6) : 42-42*Math.min(1,(x-0.6)/0.4);
  return 'hsl('+Math.max(0,h).toFixed(0)+',72%,55%)';
}
function renderGauge(t){
  const red=_nmTo>=0.85, nm=Math.min(1,Math.max(0,_nmAt));
  const num=$('apmnum'),fill=$('apmfill'),bar=$('apmbar'),peak=$('apmpeak'),lab=$('apmlab');
  if(num){ num.textContent=Math.max(0,Math.round(_apmAt)); num.style.color=red?'#ff5a6e':'var(--fg)'; }
  if(fill){ fill.style.width=(nm*100).toFixed(1)+'%'; fill.style.background=zoneColor(nm); }
  if(peak) peak.style.left=(Math.min(1,_peak)*100).toFixed(1)+'%';
  if(lab) lab.style.color=red?'#ff5a6e':'var(--mut)';
  if(bar){
    if(red){ const g=0.5+0.5*Math.sin(t*0.009); bar.style.boxShadow='0 0 '+(5+9*g).toFixed(1)+'px rgba(255,90,110,'+(0.45+0.45*g).toFixed(2)+')'; }
    else bar.style.boxShadow='none';
  }
}
function setGauge(n){
  const host=$('accel');
  if(_gaugeMode==='time'){ renderTime(); return; }   // 타임 모드가 #accel을 소유
  if(!n||!n.track||n.track==='-'){ if(host){host.innerHTML='';host.dataset.built='';} _gaugeOn=false; _apmTo=_apmAt=_apmV=_nmTo=_nmAt=_nmV=_peak=0; return; }
  _gaugeOn=true;
  if(!ensureGauge()) return;
  _apmTo=Math.max(0,n.apm||0);
  _nmTo=Math.max(0,Math.min(1,n.norm||0));
  const g=$('apmgear'),nx=$('apmnext');
  if(g) g.textContent=(n.gear&&n.gear!=='-')?(' · '+n.gear):'';
  if(nx) nx.textContent=(n.nextTrack&&n.nextTrack!=='-')?(' → 다음 '+n.nextTrack):'';
}
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
function tweenGauge(t){
  perfFrame(t);
  const dt = _lastT ? Math.min(0.05,(t-_lastT)/1000) : 0.016; _lastT=t;
  if(_gaugeMode==='time'){
    renderTime();
  } else if(_gaugeOn){
    // Integrate the spring in fixed sub-steps. Explicit Euler on a stiff spring
    // (K=500) goes unstable once dt grows on a dropped frame, which made the
    // number ring and stutter ("laggy"). Sub-stepping keeps it stable and smooth
    // at any frame rate while preserving the tachometer-kick feel.
    let rem=dt; const H=0.006;
    while(rem>1e-4){
      const h=Math.min(H,rem); rem-=h;
      _apmV += ((_apmTo-_apmAt)*SPRING_K - _apmV*SPRING_D)*h; _apmAt += _apmV*h;
      _nmV  += ((_nmTo-_nmAt)*SPRING_K - _nmV*SPRING_D)*h;     _nmAt  += _nmV*h;
    }
    if(_nmAt>_peak) _peak=_nmAt; else _peak=Math.max(_nmAt, _peak-0.18*dt);  // peak-hold drifts down
    renderGauge(t);
  }
  requestAnimationFrame(tweenGauge);
}
requestAnimationFrame(tweenGauge);
async function liveTick(){
  let l; try { l = await (await fetch('/live.json',{cache:'no-store'})).json(); }
  catch(e){ return; }
  setGauge(l);
}

async function load(){
  let d;
  try { d = await (await fetch('/data.json',{cache:'no-store'})).json(); }
  catch(e){ return; }
  $('total').textContent = d.total.label;
  const w = d.now.working;
  $('status').innerHTML = '<span class="dot" style="background:'+(w?'var(--green)':'#555')+'"></span>'+d.now.status;
  $('date').textContent = d.date + ' · 분당 기록';
  // DEV dataset indicator: badge + top ribbon + tab title prefix when not production.
  const dev=$('devBadge');
  if(d.dev){ dev.style.display='inline-block'; dev.textContent='DEV · '+(d.dataLabel||'localdata');
    document.body.classList.add('devmode');
    if(!document.title.startsWith('[DEV]')) document.title='[DEV] '+document.title; }
  else { dev.style.display='none'; document.body.classList.remove('devmode'); }
  const ss = withCarryForward(d.samples);   // 10-min continuity applied
  const b = timeBuckets(ss);
  $('t_total').textContent = fmtH(b.total);
  $('t_desk').textContent = fmtH(b.desk);
  $('t_focus').textContent = fmtH(b.focus);
  $('t_off').textContent = b.off > 0 ? fmtH(b.off) : '–';
  // Gauge mode: 타임 카운트업 기준(토탈 분→초) + 자동 기본값(<8h 스포츠, 8h+ 타임).
  _totalBaseSec = b.total*60; _totalBaseWall = Date.now(); _working = !!w;
  if(!_modeUserSet) setGaugeMode(b.total>=480 ? 'time' : 'sports', false);
  drawTiers(b);
  const n=d.now;
  const siteStr=(n.site&&n.site!=='-')?' ('+esc(n.site)+')':'';
  $('now').innerHTML='<span class="nowtext">지금: 앱 <b>'+esc(n.app)+siteStr+'</b> &nbsp; '+tierBadge(n.tier,n.mult)
    +' &nbsp; ⌨ '+(n.key||0)+' 🖱 '+(n.mouse||0)+' &nbsp; 전략 <b>'+esc(n.profile)+'</b> · BGM <b>'+esc(n.track)+'</b></span><span id="accel"></span>';
  setGauge(n);
  const _t0=performance.now();
  renderReview(d);   // 확정 가치/목표 — 스포츠 모드에서도 항상 렌더
  // 스포츠 모드에선 상세 섹션은 숨겨져 있으므로 렌더(로딩) 자체를 건너뛴다.
  // 차트·타임라인·주요앱·BGM·워커는 타임 모드로 전환할 때 비로소 채워진다.
  if(_gaugeMode!=='sports'){
    drawChart(ss);
    drawStrip(ss);
    renderSummary(ss);
    renderTimeline(ss);
    renderApps(ss);
    renderWorkers(d.workers);
  }
  _plugins = d.plugins || [];
  if($('plugins').classList.contains('on')) renderPlugins();
  _pfRenderMs=performance.now()-_t0;
}

// ===== Plugins (🧩 overlay) — extensible external integrations =====
function openPlugins(){ $('plugins').classList.add('on'); renderPlugins(); load(); }
// Tiny, safe markdown for AI replies: escape first, then code fences + inline code + bold.
// white-space:pre-wrap (CSS) keeps newlines, so we don't touch them.
function mdLite(s){
  let h=esc(s);
  h=h.replace(/```([\s\S]*?)```/g,(_,c)=>'<pre><code>'+c.replace(/^\n/,'')+'</code></pre>');
  h=h.replace(/`([^`\n]+)`/g,'<code>$1</code>');
  h=h.replace(/\*\*([^*\n]+)\*\*/g,'<b>$1</b>');
  return h;
}
function renderPlugins(){
  const host=$('pluginList');
  if(!_plugins.length){ host.innerHTML='<div class="empty">등록된 플러그인이 없습니다</div>'; return; }
  host.innerHTML=_plugins.map(p=>{
    const toggle=(p.kind==='toggle');
    const map=toggle
      ?{valid:['설치됨','var(--green)'],disconnected:['미설치','#777']}
      :{valid:['연결됨','var(--green)'],invalid:['잘못된 연결','var(--red,#e2667d)'],disconnected:['미연결','#777']};
    const m=map[p.status]||map.disconnected;
    const badge='<span class="chip" style="margin:0;background:'+m[1]+';color:#fff">'+m[0]+'</span>';
    const folder=(!toggle&&p.folder)?('<div class="muted" style="font-size:12px;word-break:break-all">📁 '+esc(p.folder)+'</div>'):'';
    const detail=p.detail?('<div class="muted" style="font-size:12px;margin-top:2px">'+esc(p.detail)+'</div>'):'';
    let actions;
    if(toggle){
      // Install IS the connection — no folder, no verify. 제거 turns the feature off.
      actions=p.installed
        ?'<button class="btn" onclick="uninstallPlugin(\''+esc(p.id)+'\')">제거</button>'
        :'<button class="btn primary" onclick="installPlugin(\''+esc(p.id)+'\')">설치</button>';
    } else {
      actions='<button class="btn primary" onclick="connectPlugin(\''+esc(p.id)+'\')">'+(p.folder?'폴더 변경':'연결')+'</button>';
      if(p.folder){
        actions+=' <button class="btn" onclick="verifyPlugin(\''+esc(p.id)+'\')">재검증</button>';
        actions+=' <button class="btn" onclick="disconnectPlugin(\''+esc(p.id)+'\')">해제</button>';
      }
    }
    return '<div class="panel" style="margin:8px 0">'
      +'<div class="row" style="justify-content:space-between;align-items:center;margin:0">'
      +'<b style="font-size:15px">'+esc(p.name)+'</b>'+badge+'</div>'
      +'<div class="muted" style="font-size:12px;margin:4px 0">'+esc(p.desc)+'</div>'
      +folder+detail
      +'<div class="muted" style="font-size:11px;margin:6px 0 8px">기준: '+esc(p.hint)+'</div>'
      +'<div class="row" style="margin:0">'+actions+'</div>'
      +renderProjectActivity(p)+'</div>';
  }).join('');
}
// 5-level activity ladder → [label, color]. 5 = 사용 중(≤5분), 1 = 주간(≤7일), 0 = 휴면.
function levelMeta(lv){
  return [['휴면','#555'],['거의 없음','#7a8290'],['뜸함','#e8a13a'],
          ['보통','#e0c23a'],['활발','#36c08a'],['사용 중','#2ee6a6']][lv]||['?','#555'];
}
function agoKo(sec){
  if(sec<60) return Math.max(0,sec)+'초 전';
  if(sec<3600) return Math.floor(sec/60)+'분 전';
  if(sec<86400) return Math.floor(sec/3600)+'시간 전';
  return Math.floor(sec/86400)+'일 전';
}
// Per-project activity list (claude-desktop only). 5-segment intensity bar, name,
// 사용중 marker, and recency. Dormant (level 0, 7일+) projects are summarized, not listed.
function renderProjectActivity(p){
  const ps=p.projects||[];
  if(p.status!=='valid'||!ps.length) return '';
  const live=ps.filter(x=>x.level>=1);
  const dormant=ps.length-live.length;
  const rows=live.map(x=>{
    const meta=levelMeta(x.level);
    let bar=''; for(let i=1;i<=5;i++){ bar+='<span style="display:inline-block;width:7px;height:12px;margin-right:2px;border-radius:2px;background:'+(i<=x.level?meta[1]:'#2a2f3a')+'"></span>'; }
    const use=x.inUse?' <span class="chip" style="margin:0;background:#2ee6a6;color:#06281d;font-size:10px">사용 중</span>':'';
    return '<div class="row" style="margin:0;gap:8px;align-items:center;padding:3px 0;border-top:1px solid var(--line)">'
      +'<span title="'+meta[0]+'" style="white-space:nowrap">'+bar+'</span>'
      +'<b style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="'+esc(x.path)+'">'+esc(x.name)+'</b>'+use
      +'<span class="muted" style="font-size:11px;white-space:nowrap">'+agoKo(x.lastActiveSec)+'</span></div>';
  }).join('');
  const summary=dormant>0?'<div class="muted" style="font-size:11px;margin-top:4px">+ 휴면 '+dormant+'개 (7일+)</div>':'';
  const activeN=ps.filter(x=>x.inUse).length;
  return '<div style="margin-top:10px">'
    +'<div class="muted" style="font-size:12px;margin-bottom:2px">프로젝트 활성도 <b>'+activeN+'</b>개 사용 중 · 활성 강도 5단계</div>'
    +rows+summary+'</div>';
}
// The folder picker is a native modal on the app side; the POST returns immediately,
// so refresh a few times to pick up the verified result without waiting for the 5s poll.
function pluginRefresh(){ [400,1200,2500,4000].forEach(ms=>setTimeout(load,ms)); }
function connectPlugin(id){ post('/api/plugin/connect',{id}); pluginRefresh(); }
function disconnectPlugin(id){ if(confirm('이 플러그인 연결을 해제할까요?')){ post('/api/plugin/disconnect',{id}); pluginRefresh(); } }
function verifyPlugin(id){ post('/api/plugin/verify',{id}); pluginRefresh(); }
// Toggle plugins (e.g. 컨디션 메이트): install/uninstall, no folder picker. 제거하면 BGM도 꺼짐.
function installPlugin(id){ post('/api/plugin/install',{id}); pluginRefresh(); }
function uninstallPlugin(id){ if(confirm('이 플러그인을 제거할까요? (컨디션 메이트는 BGM도 함께 꺼집니다)')){ post('/api/plugin/uninstall',{id}); pluginRefresh(); } }
function hhmm(t){ const d=new Date(t*1000); return ('0'+d.getHours()).slice(-2)+':'+('0'+d.getMinutes()).slice(-2); }

function renderSummary(samples){
  const el=$('summary');
  if(!samples.length){ el.textContent='데이터 없음'; return; }
  const lastT=samples[samples.length-1].t;
  const recent=samples.filter(s=>s.t>=lastT-30*60 && s.app && s.app!=='-');
  if(!recent.length){ el.textContent='최근 30분 활동 없음'; return; }
  const apps={}; let active=0, valSec=0;
  recent.forEach(s=>{ const e=apps[s.app]||(apps[s.app]={m:0,prof:{}}); e.m++; active+=(s.active||0);
    valSec+=(s.active||0)*(s.mult||1);
    if(s.profile&&s.profile!=='-') e.prof[s.profile]=(e.prof[s.profile]||0)+1; });
  const top=Object.entries(apps).sort((a,b)=>b[1].m-a[1].m).slice(0,3).map(([a,e])=>{
    const p=Object.entries(e.prof).sort((x,y)=>y[1]-x[1])[0];
    const col=appColor(a);
    return '<span class="dot" style="background:'+col+'"></span>'+esc(a)+' '+e.m+'분'+(p?' ('+esc(p[0].split(' ')[0])+')':'');
  });
  el.innerHTML='<b>최근 30분</b> · 작업 '+Math.round(active/60)+'분 · 가치 '+Math.round(valSec/60)+'분(가중) · '+top.join(' &nbsp; ');
}

// Merge consecutive minutes sharing the same app+site+mood+track into one segment.
function timelineSegments(samples){
  const segs=[];
  samples.forEach(s=>{
    const key=(s.app||'-')+'|'+(s.site||'-')+'|'+(s.profile||'-')+'|'+(s.track||'-');
    const last=segs[segs.length-1];
    if(last && last.key===key && (s.t-last.endT)<=120){
      last.endT=s.t; last.mins++; last.activeSum+=(s.active||0);
      last.keySum+=(s.key||0); last.mouseSum+=(s.mouse||0); last.meeting=s.meeting||last.meeting;
    } else {
      segs.push({key,app:s.app||'-',site:s.site||'-',profile:s.profile||'-',track:s.track||'-',
                 tier:s.tier||'소극',mult:s.mult||1,meeting:s.meeting||false,startT:s.t,endT:s.t,mins:1,
                 activeSum:(s.active||0),keySum:(s.key||0),mouseSum:(s.mouse||0)});
    }
  });
  return segs;
}

// Lazy timeline: keep all segments in memory-light form but only paint a small
// initial slice into the DOM (the table is the heaviest part of the page). The
// "불러오기" button reveals more on demand, so the default DOM footprint stays
// minimal regardless of how long the log gets. _logShown survives auto-refresh
// so an expanded view isn't collapsed every 5s.
const LOG_INIT=30, LOG_STEP=50, LOG_MAX=600;
let _logSegs=[], _logShown=LOG_INIT;
function rowHtml(g){
      const idle=(g.app==='-');
      const col=idle?'#555':appColor(g.app);
      const band=BANDS[g.profile];
      const bpm=trackBpm(g.track);
      const bad=band&&bpm!=null&&(bpm<band[0]||bpm>band[1]);
      const trackCell=(g.track==='-')?'<span class="empty">–</span>'
        :'<span class="chip'+(bad?' bad':'')+'" style="margin:0">'+esc(g.track)+'</span>';
      const siteRow=(g.site&&g.site!=='-')?'<div style="color:var(--mut);font-size:11px">'+esc(g.site)+'</div>':'';
      const k=Math.round(g.keySum/g.mins), mo=Math.round(g.mouseSum/g.mins);
      return '<tr>'
        +'<td style="white-space:nowrap">'+hhmm(g.startT)+'</td>'
        +'<td style="white-space:nowrap;color:var(--mut)">'+g.mins+'분</td>'
        +'<td style="white-space:nowrap"><span class="dot" style="background:'+col+'"></span>'+esc(g.app)+siteRow+'</td>'
        +'<td style="white-space:nowrap">'+esc(g.profile)+'</td>'
        +'<td>'+trackCell+'</td>'
        +'<td style="white-space:nowrap;color:var(--mut)">⌨'+k+' 🖱'+mo+'</td>'
        +'<td>'+categoryBadge(g)+'</td>'
        +'</tr>';
}
function paintTimeline(){
  const rows=$('logrows');
  const total=_logSegs.length;
  if(!total){ rows.innerHTML='<tr><td colspan="7" class="empty">데이터 없음</td></tr>'; return; }
  const shown=Math.min(_logShown,total);
  let html=_logSegs.slice(0,shown).map(rowHtml).join('');
  if(shown<total){
    const next=Math.min(LOG_STEP,total-shown);
    html+='<tr><td colspan="7" style="text-align:center;padding:10px">'
      +'<button class="btn" onclick="loadMoreLog()">불러오기 (+'+next+')</button>'
      +' <span class="muted" style="font-size:11px">전체 '+total+'개 중 '+shown+'개 표시 · 메모리 절약 모드</span>'
      +'</td></tr>';
  } else if(total>LOG_INIT){
    html+='<tr><td colspan="7" style="text-align:center;padding:6px"><span class="muted" style="font-size:11px">전체 '+total+'개 표시</span></td></tr>';
  }
  rows.innerHTML=html;
}
function loadMoreLog(){ _logShown=Math.min(_logShown+LOG_STEP,LOG_MAX,_logSegs.length); paintTimeline(); }
function renderTimeline(samples){
  _logSegs=timelineSegments(samples).reverse().slice(0,LOG_MAX);
  // Clamp the persisted "shown" count to the new total (never below the initial).
  _logShown=Math.max(LOG_INIT,Math.min(_logShown,_logSegs.length));
  paintTimeline();
}
function esc(s){ return (s||'-').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }
function minOfDay(s){ const dt=new Date(s.t*1000); return dt.getHours()*60+dt.getMinutes(); }
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
// Span anchors separated by < 6h = one work span; >= 6h gaps are 퇴근.
function timeBuckets(ss){
  const SIXH=6*3600;
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
      if(gap < SIXH) total += gap/60;   // rest/meeting within span -> total
      else off += gap/60;               // >=6h gap -> 퇴근
    }
  }
  return {total:Math.round(total), desk, focus, off:Math.round(off)};
}
function drawTiers(b){
  const c=$('tiers'),dpr=window.devicePixelRatio||1,W=c.clientWidth,H=18;
  c.width=W*dpr;c.height=H*dpr;const g=c.getContext('2d');g.setTransform(dpr,0,0,dpr,0,0);g.clearRect(0,0,W,H);
  const max=Math.max(b.total,1), bw=v=>W*(v/max);
  g.fillStyle='#2a2f3a'; g.fillRect(0,2,bw(b.total),14);  // total
  g.fillStyle='#e8a13a'; g.fillRect(0,2,bw(b.desk),14);   // desk (nested)
  g.fillStyle='#36c08a'; g.fillRect(0,2,bw(b.focus),14);  // focus (nested)
}
function tierColor(t){ return t==='적극'?'#36c08a':t==='중간'?'#e8a13a':'#9aa4b2'; }
function tierBadge(t,m){ const c=tierColor(t); return '<span class="chip" style="margin:0;border-color:'+c+';color:'+c+'">'+esc(t||'소극')+' ×'+(m||1)+'</span>'; }
// 책상/집중/휴식/미팅 구분 뱃지 (타임라인용)
function categoryBadge(seg){
  let label,color;
  if(seg.meeting){label='미팅';color='#9aa4b2';}
  else if(seg.tier==='적극'){label='집중';color='#36c08a';}
  else if(seg.tier==='중간'){label='책상';color='#e8a13a';}
  else {label='휴식';color='#9aa4b2';}
  return '<span class="chip" style="margin:0;border-color:'+color+';color:'+color+'">'+label+' ×'+(seg.mult||1)+'</span>';
}

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
// Reusable goal-add modal input: same IME-safe Enter as the always-on bar.
(function(){ bindImeEnter(document.getElementById('gaText'), function(){ gaAdd(); }); })();
// --- 재사용 목표 추가 모달 — 스프린트 보드의 모든 추가 진입점이 이 모달 하나를 연다. ---
let _gaCtx={sprint:0,parent:''};   // 현재 추가 대상 (0/''=Backlog 최상위)
function openGoalAdd(opts){
  opts=opts||{};
  _gaCtx={sprint:opts.sprint||0,parent:opts.parent||''};
  const where=$('gaWhere'); if(where) where.textContent=opts.label?('· '+opts.label):'';
  const inp=$('gaText'); if(inp) inp.value='';
  const m=$('gaModal'); if(m) m.classList.add('on');
  setTimeout(()=>{ const t=$('gaText'); if(t) t.focus(); },50);
}
function closeGoalAdd(){ const m=$('gaModal'); if(m) m.classList.remove('on'); }
// 추가 후 모달은 열어둔다(placeholder의 "계속 추가"). 닫기는 사용자가 직접.
function gaAdd(){ const inp=$('gaText'); if(goalAddSubmit(inp.value,_gaCtx)){ inp.value=''; inp.focus(); } }
function gaAi(){ goalAddAi($('gaText').value,_gaCtx,$('gaAiBtn'),()=>closeGoalAdd(),()=>closeGoalAdd()); }
// ===== 재사용 목표 추가 모듈 (single source of truth) =====
// 입력창(상단 항상 보이는 바)·스프린트 보드(Backlog·각 스프린트)의 모든 "목표 추가"가
// 이 두 코어 함수를 통해서만 추가한다. 진입점마다 미세하게 다른 add 로직을 두지 않는다.
// ctx: {sprint, parent} — 비어 있으면(0/'') 그 필드는 보내지 않아 기존 Backlog 추가와 동일.
function goalAddSubmit(text, ctx){
  const t=String(text||'').trim(); if(!t) return false;
  const o={text:t};
  if(ctx){ if(ctx.sprint) o.sprint=ctx.sprint; if(ctx.parent) o.parent=ctx.parent; }
  post('/api/goal/add',o);
  return true;
}
// AI추가 코어 (bump out): 기다리지 않는다. 후보를 즉시 큐(pending)에 담고 입력창을 비운 뒤
// 곧장 돌려준다 — 유저는 머릿속을 계속 비우면 된다. 서버 백그라운드 워커가 중복을 분석해
// '검토 대기(ready)'로 바꾸면, 아래 큐 목록에서 원탭(추가/수정/스킵)으로 확정한다.
// btn/onDup은 옛 시그니처 호환용으로 남겨두며 더는 쓰지 않는다.
function goalAddAi(text, ctx, btn, onAdded, onDup){
  const t=String(text||'').trim(); if(!t) return;
  const o={text:t};
  if(ctx){ if(ctx.sprint) o.sprint=ctx.sprint; if(ctx.parent) o.parent=ctx.parent; }
  post('/api/goal/queue/enqueue',o);   // post()가 이어서 load()까지 호출 → 큐에 즉시 반영
  if(onAdded) onAdded();               // 입력창 비우기/모달 닫기는 즉시 (대기 0초)
}
function addGoal(){ const el=$('goalText'); if(goalAddSubmit(el.value,null)){ el.value=''; el.focus(); } }
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
  $('dupNote').textContent='유사한 목표가 있습니다. AI와 상의해 다듬은 뒤 추가하세요.';
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
  $('goalText').value=''; $('goalText').focus(); closeDup();
  const o={text:text,parent:p.parent||''}; if(p.sprint) o.sprint=p.sprint;   // 스프린트 보드에서 시작한 추가면 대상 유지
  post('/api/goal/add',o); }
function dupLater(){ const p=_dupPending; if(!p){closeDup();return;}
  const text=$('dupGoalText').value.trim()||p.text;
  $('goalText').value=''; $('goalText').focus(); closeDup();
  post('/api/goal/queue/add',{text:text,parent:p.parent||'',note:p.note||'',matches:p.matches||[]}); }
// --- AI 큐(bump out): 도착 순서 그대로 한 줄로 쌓는다. 위쪽이 먼저 처리되고(분석 중·검토 대기),
// 방금 비워낸 후보는 맨 하단에 붙는다 — "쏟아내면 아래에 쌓이고, 위에서 익는다"는 컨베이어 감각.
// 헤더의 펄스 '실행 중' 배지로 워커가 돌고 있는지 한눈에 보인다. data.json은 oldest-first 순.
// aiQueueBoxHTML: 큐 박스 HTML 문자열을 돌려준다(빈 목록이면 ''). 입력(목록) 뷰는 #aiQueue에
// 전체 큐를, 스프린트 보드는 각 스프린트·백로그 섹션 하단에 해당 sprint의 큐만 끼워 넣는다. ---
function aiQueueBoxHTML(items){
  items=items||[];
  if(!items.length) return '';
  const isReady=it=>(!it.status||it.status==='ready');
  const analyzing=items.filter(it=>it.status==='analyzing').length;
  const pending=items.filter(it=>it.status==='pending').length;
  const ready=items.filter(isReady).length;
  // 헤더: 워커 실행 상태(펄스) + 큐/검토 건수.
  const run=analyzing
    ? '<span class="qrun"><span class="qdot"></span>실행 중</span>'
    : (pending?'<span class="muted" style="font-size:12px">곧 시작…</span>':'');
  const counts=[];
  if(analyzing+pending) counts.push('큐 '+(analyzing+pending)+'건');
  if(ready) counts.push('검토 대기 '+ready+'건');
  let waitNo=0;   // pending 행에 "대기 N번째" 부여 (도착 순)
  function row(it){
    const rdy=isReady(it);
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
    let meta='', cls='qrow';
    if(it.status==='analyzing'){
      cls='qrow analyzing';
      meta='<div style="font-size:12px;color:var(--green)"><span class="qspin">🔄</span> AI 분석 중…</div>';
    } else if(!rdy){
      waitNo++;
      meta='<div class="muted" style="font-size:12px">⏳ 대기 '+waitNo+'번째</div>';
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
      btns='<button class="btn" onclick="queueAdd(\''+it.id+'\')" title="이 목표를 추가">추가</button>'
        +'<button class="btn" onclick="queuePromptStart(\''+it.id+'\')" title="프롬프트로 결과를 다시 생성">프롬프트</button>'
        +'<button class="btn" onclick="queueSkip(\''+it.id+'\')" title="버리기">스킵</button>';
    }
    const newBadge=(_qJustRefined===it.id)
      ? '<span style="font-size:11px;padding:1px 7px;border-radius:20px;background:#0f2a1e;color:var(--green);border:1px solid #1e4a35;margin-right:6px">새 결과</span>' : '';
    return '<div class="'+cls+'">'
      +'<div style="flex:1;min-width:0">'+newBadge+'<span id="qt_'+it.id+'">'+esc(it.text)+'</span>'+meta+panel+'</div>'
      +'<div style="display:flex;gap:4px;flex-shrink:0;align-items:flex-start">'+btns+'</div></div>';
  }
  return '<div style="border:1px solid var(--line);border-radius:8px;padding:8px;margin:4px 0 10px;background:rgba(91,140,255,0.06)">'
    +'<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">'
    +'<span style="font-weight:600">🤖 AI 큐</span>'+run
    +'<span class="muted" style="font-weight:400;font-size:12px;margin-left:auto">'+(counts.join(' · ')||'대기 없음')+'</span></div>'
    +items.map(row).join('')+'</div>';
}
// === 큐 프롬프트 다듬기 상태 ===
// _qUI: 프롬프트 입력/생성 중 패널 상태 {id, mode:'prompt'|'gen', prompt}
// _qJustRefined: 방금 프롬프트로 다듬어진 항목 id — '새 결과'로 강조하고 진행/다시 프롬프트를 띄운다.
let _qUI=null, _qJustRefined='', _lastAiQueue=[];
// 입력(목록) 뷰의 전역 큐 박스: #aiQueue(목표 목록 아래)에 전체 큐를 그린다.
function renderAiQueue(items){ _lastAiQueue=items||[]; const host=$('aiQueue'); if(host) host.innerHTML=aiQueueBoxHTML(items);
  // 프롬프트 입력 중이면 재렌더 후 텍스트박스에 포커스를 되돌린다(캐럿 끝으로).
  if(_qUI&&_qUI.mode==='prompt'){ const t=$('qp_'+_qUI.id); if(t){ t.focus(); try{ t.setSelectionRange(t.value.length,t.value.length); }catch(e){} } } }
// 큐 박스는 입력 뷰(#aiQueue)뿐 아니라 스프린트 뷰(보드 하단)에도 렌더된다. 프롬프트 열기/취소
// 같은 즉시 상태 변화는 '지금 보고 있는 뷰'를 바로 다시 그려야 한다 — 안 그러면 5초 폴링을
// 기다리게 되어 반응이 느리게 느껴진다. 재렌더 후 입력 중이면 텍스트박스 포커스를 복원한다.
function rerenderAiQueue(){
  if(_view==='sprint' && _review) renderSprintView(_review);
  else renderAiQueue(_lastAiQueue);
  if(_qUI&&_qUI.mode==='prompt'){ const t=$('qp_'+_qUI.id); if(t){ t.focus(); try{ t.setSelectionRange(t.value.length,t.value.length); }catch(e){} } }
}
function queueAdd(id){ post('/api/goal/queue/resolve',{id:id,action:'add'}); }
function queueSkip(id){ _qJustRefined=''; post('/api/goal/queue/resolve',{id:id,action:'skip'}); }
// 프롬프트 열기 → 입력 → 생성(서버 refine) → 새 결과. 맞으면 진행(queueProceed), 아니면 다시.
function queuePromptStart(id){ _qJustRefined=''; _qUI={id:id,mode:'prompt',prompt:''}; rerenderAiQueue();
  const t=$('qp_'+id); if(t) t.focus(); }
function queuePromptCancel(){ _qUI=null; rerenderAiQueue(); }
function queuePromptGen(id){
  const t=$('qp_'+id); const prompt=((t?t.value:((_qUI&&_qUI.prompt)||''))||'').trim();
  if(!prompt){ if(t) t.focus(); return; }
  _qUI={id:id,mode:'gen',prompt:prompt}; rerenderAiQueue();
  fetch('/api/goal/queue/refine',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:id,prompt:prompt})})
    .then(r=>r.json()).then(res=>{ _qUI=null; if(res&&res.ok){ _qJustRefined=id; } else { alert('다듬기에 실패했습니다 (claude 미설치/오류). 잠시 후 다시 시도하세요.'); } load(); })
    .catch(()=>{ _qUI=null; load(); });
}
function queueProceed(id){ _qJustRefined=''; queueAdd(id); }
function queueEditStart(id){
  const span=$('qt_'+id); if(!span||span._editing)return; span._editing=true;
  const cur=span.textContent;
  const inp=document.createElement('input'); inp.type='text'; inp.className='gedit'; inp.value=cur;
  inp.title='Enter 저장 · Esc 취소'; span.innerHTML=''; span.appendChild(inp); inp.focus(); inp.select();
  let done=false;
  function commit(){ if(done)return; done=true; const t=inp.value.trim();
    if(!t||t===cur){ load(); return; } post('/api/goal/queue/resolve',{id:id,action:'edit',text:t}); }
  inp.addEventListener('keydown',function(ev){ if(ev.key==='Escape'){ev.preventDefault(); if(!done){done=true; load();}} });
  inp.addEventListener('blur',commit);
  bindImeEnter(inp,commit);
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
// 스프린트 콤보박스 선택값(다중 선택). 비어 있으면 '모두'(전체), 아니면 선택된 스프린트 번호 집합.
let _sprintSel=new Set();
// 완료 컷오프: 이 시각(Unix 초) 이전에 완료된 목표는 숨긴다. 0이면 컷오프 해제(모든 완료 표시).
// 기본값은 필터 바 datetime-local 입력의 초기값과 동일하게 맞춘다(2026-06-24 17:00).
// 완료 외 상태(대기·진행 등)는 이 컷오프의 영향을 받지 않는다 — 현재 진행 중인 일은 항상 보인다.
const DONE_CUTOFF_DEFAULT='2026-06-24T17:00';
const DC_DEFAULT=Math.floor(new Date(DONE_CUTOFF_DEFAULT).getTime()/1000);
// Server-injected: the persisted cutoff (0 = 해제) if the user has set one, else DC_DEFAULT.
// This is what survives an app restart; the URL hash, if present, still overrides it below.
let _doneSince=\#(dcInit);
// Server-injected dashboard UI layout from the last session (null = never saved).
// Applied as the base in restoreFromURL; an explicit URL hash still overrides it.
const _prefsInit=\#(prefsInit);
let _review=null;         // last review object (for filter-only re-render)
let _plugins=[];          // last plugin list from /data.json (rendered in the 🧩 overlay)
let _lastReportArgs=null; // cached (d,r,conf,prov) so 프리뷰 can re-render on filter change
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
// inherit — 이번 스프린트에서 자식이 빠질 수 있으므로 개별 배정한다.
function effSprint(g,goals){
  if(g.sprint>0) return g.sprint;
  if(effStatus(g,goals)==='done' && g.parent){ const p=byId(goals,g.parent); return p?(p.sprint||0):0; }
  return 0;
}
function byId(goals,id){ return (goals||[]).find(x=>x.id===id)||null; }
// 보드 그룹 판정: 자신의 sprint가 있으면 그것, 없으면 부모를 따라간다(부모-자식이 한 그룹에
// 묶여 보이도록). 자식을 다른 스프린트로 명시 배정하면 그 그룹으로 분리된다.
function boardSprint(g,goals){
  if(g.sprint>0) return g.sprint;
  if(g.sprint<0) return 0;            // 명시적 Backlog 분리 — 부모를 따라가지 않는다
  if(g.parent){ const p=byId(goals,g.parent); return p?boardSprint(p,goals):0; }
  return 0;
}
// 스프린트 콤보박스 통과 여부: '모두'면 전부, 숫자면 그 스프린트만.
function passesSprintFilter(g,goals){ return _sprintSel.size===0 ? true : _sprintSel.has(effSprint(g,goals)); }
function goalPasses(g,goals){
  if(g.archived) return false;                    // 보관된 목표는 활성 목록에서 숨김(아카이브 뷰에만 노출)
  if(g.released) return false;                    // 릴리즈(커밋)된 목표는 활성 목록에서 숨김
  if(!passesSprintFilter(g,goals)) return false;  // 스프린트 콤보박스 (하드 게이트)
  if(!passesDoneCutoff(g,goals)) return false;    // 완료 컷오프는 상위 항상 표시보다 우선하는 하드 게이트
  if(_showParents && hasKids(goals,g)) return true;
  return !!_statusFilter[effStatus(g,goals)];
}
function getFilteredGoals(goals){ return goals.filter(g=>goalPasses(g,goals)); }
// 스프린트 보드용 필터: 상태 토글·완료 컷오프는 적용하되, 스프린트 콤보박스는 적용하지 않는다
// (보드 자체가 스프린트별로 그루핑하므로). 그래서 완료를 끄면 보드에서도 완료가 숨겨진다.
function goalPassesBoard(g,goals){
  if(g.archived) return false;
  if(g.released) return false;
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
// 스프린트 콤보박스(다중 선택): 상태 콤보와 같은 체크박스 드롭다운 패턴. 비어 있으면 '모두'.
// 옵션 산출: 닫히지 않은(진행 중) 스프린트는 골이 아직 없어도 보여준다 — 만들자마자 배정할 수
// 있게. 릴리즈로 닫힌 스프린트는 숨긴다. 여기에 활성 골이 붙은 번호도 합쳐, 닫혔지만 미완료
// 골이 남은 스프린트의 잔여 작업도 놓치지 않는다. 정렬해 라벨로 고를 때 헷갈리지 않게.
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
  [..._sprintSel].forEach(n=>{ if(!nums.includes(n)) _sprintSel.delete(n); });   // 사라진 스프린트는 선택에서 제거
  let h='<div class="ckmenu spmenu"><div class="pophdr">스프린트 (다중 선택)</div>';
  h+='<button class="popitem chk'+(_sprintSel.size===0?' on':'')+'" onclick="spAll()"><span class="cbx"></span>모두</button>';
  if(nums.length) h+='<div class="popdiv"></div>';
  nums.forEach(function(n){ const on=_sprintSel.has(n); const lab=labelOf[n]||('스프린트 '+n);
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
// 콤보 버튼 카운트 배지 갱신 (Jira식): 라벨은 '스프린트' 고정, 선택 개수만 배지 숫자로.
function updateSprintCombo(){
  const cnt=$('flt_sprint_cnt'), combo=$('flt_sprint_combo');
  const n=_sprintSel.size;
  if(cnt){ if(n>0){ cnt.textContent=n; cnt.style.display=''; } else cnt.style.display='none'; }
  if(combo) combo.classList.toggle('active', n>0);
}
// 완료 컷오프 설정/해제. datetime-local 값(로컬 tz)을 Unix 초로 환산; 빈 값이면 해제(0).
function setDoneSince(v){ _doneSince=v?Math.floor(new Date(v).getTime()/1000):0; reapplyFilter(); syncURL(); post('/api/prefs/donecutoff',{dc:_doneSince}); }
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
  const spArr=[..._sprintSel].sort((a,b)=>a-b);
  const sp=spArr.length?(' · 스프린트 '+spArr.map(sprintCode).join(', ')+' 만'):'';
  const cut=_doneSince?' · '+fmtDate(_doneSince)+' 이전 완료 숨김':'';
  const s=$('flt_summary'); if(s) s.textContent='— '+filterSummary()+sp+(_showParents?' · 상위 항상 표시':'')+cut;
}
// ===== URL 상태 영속화 — 뷰·필터 설정을 location.hash에 보관 =====
// 목적: 스프린트 작업 중 새로고침해도 뷰/필터가 초기화되지 않게 한다(완료 토글 해제 등도 보존).
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
  if(_doneSince!==DC_DEFAULT) q.set('dc',String(_doneSince));   // 0 = 컷오프 해제
  // 보드 접기 상태도 보존 — 그룹(스프린트 번호·'bg' Backlog)과 자식 접은 부모 id.
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
// 스프린트 선택·보드 접기)에서 함께 저장된다. 펼침 상태를 정확히 복원하려면 _bgSeen·_gSeen
// (사용자가 이미 본 부모들)도 저장해야 한다 — 그래야 복원 후 첫 렌더의 기본-접기 로직이
// 펼쳐둔 부모를 다시 접지 않는다.
function savePrefs(){
  if(!_urlReady) return;   // 부팅 복원 중에는 저장된 prefs를 덮어쓰지 않는다
  const p={
    st:['backlog','in_progress','done','cancelled'].filter(k=>_statusFilter[k]),
    par:_showParents?1:0,
    sp:[..._sprintSel],
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
  // 스프린트 그룹 키는 숫자(스프린트 번호)면 Number로 되돌려 _spCollapsed.has(s.number)와 일치시킨다.
  if(Array.isArray(p.spc)) p.spc.forEach(k=>_spCollapsed.add(/^\d+$/.test(String(k))?parseInt(k,10):k));
  if(Array.isArray(p.bgc)) p.bgc.forEach(k=>_bgCollapsed.add(k));
  // 펼침 보존의 핵심: 이미 본 부모를 시드해 첫 렌더의 기본-접기가 펼쳐둔 부모를 다시 접지 않게 한다.
  if(Array.isArray(p.bgseen)) p.bgseen.forEach(k=>_bgSeen.add(k));
  if(Array.isArray(p.gc)) p.gc.forEach(k=>_gCollapsed.add(k));
  if(Array.isArray(p.gseen)) p.gseen.forEach(k=>_gSeen.add(k));
  if(Array.isArray(p.tord)) _tabOrder=p.tord.filter(k=>VIEW_KEYS.includes(k));   // 빠진 표준 키는 normTabOrder가 채운다
  if(typeof p.dv==='string') _defaultView=p.dv;
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
    if(q.has('dc')) _doneSince=parseInt(q.get('dc'),10)||0;
    // 접기 상태 복원: 그룹 키는 숫자(스프린트 번호)면 Number로 되돌려 _spCollapsed.has(s.number)와 일치시킨다.
    if(q.has('spc')) q.get('spc').split(',').filter(Boolean).forEach(k=>_spCollapsed.add(/^\d+$/.test(k)?parseInt(k,10):k));
    if(q.has('bgc')) q.get('bgc').split(',').filter(Boolean).forEach(k=>_bgCollapsed.add(k));
  }
  // 명시적 URL 해시 뷰가 없으면, 사용자가 지정한 기본 보기(Set as default)로 연다.
  // 기본 보기가 없으면 서버가 주입한 마지막 보기(lastView)를 그대로 쓴다.
  if(!hashHasView && _defaultView) _view=_defaultView;
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
// Parent rollup. A parent is a long-lived history container: it is NEVER auto-completed from
// its children. Even when every child is done it stays On Track — the user closes it MANUALLY
// (sets the parent's own status to done) only when the work branches. Manual done wins; else
// any activity (a child in progress, or some child done) reads as On Track; otherwise 대기.
function derivedStatus(goals,g){
  const kids=goalKids(goals,g); if(!kids.length) return null;
  if((g.status||'')==='done') return 'done';                              // 수동 완료(분기 마감)만 완료
  if(kids.some(c=>(c.status||'backlog')==='in_progress')) return 'on_track';
  if(kids.some(c=>(c.status||'backlog')==='done')) return 'on_track';     // 자동 완료 금지 — On Track 유지
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
  const tgt=_goals.find(g=>g.seq===n)||null;   // match by stable seq, not position
  if(!tgt||tgt.id===id){ load(); return; }   // invalid -> revert display
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
  {k:'token',t:'토큰'},{k:'schedule',t:'일정'},{k:'preview',t:'프리뷰'},
  {k:'sprint',t:'스프린트'},{k:'archived',t:'아카이브'}
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
  }).join('');
}
// 폴링 재렌더(5초)마다 탭바를 통째로 다시 그리지 않고 활성 표시만 갱신 — 열린 ⋯ 메뉴 보존.
function markActiveTab(){
  const host=$('viewTabs'); if(!host) return;
  [...host.querySelectorAll('.vtab')].forEach(b=>b.classList.toggle('active', b.dataset.k===_view));
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
function setView(v){ _view=v; if(_review) fillActiveView(_review); applyView(); syncURL(); post('/api/prefs/view',{view:v}); }
function applyView(){
  const inp=$('inputView'), pv=$('previewView'), gv=$('groupView'), sv=$('scheduleView'), tv=$('tableView'), tkv=$('tokenView'), spv=$('sprintView'), av=$('archivedView');
  inp.style.display=(_view==='input')?'':'none';
  gv.style.display =(_view==='group')?'':'none';
  sv.style.display =(_view==='schedule')?'':'none';
  tv.style.display =(_view==='table')?'':'none';
  tkv.style.display=(_view==='token')?'':'none';
  spv.style.display=(_view==='sprint')?'':'none';
  av.style.display =(_view==='archived')?'':'none';
  pv.style.display =(_view==='preview')?'':'none';
  markActiveTab();
}
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
    +gpill(g)
    +slinkBtn(g)
    +'<span class="gt" id="gt_'+g.id+'" title="더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span>'
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
      +gpill(t)
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
function gnote(r,id){ return (r.notes&&r.notes[id])||''; }

// ===== 일정관리 (schedule / resource management) =====
// Every goal is dropped into an urgency bucket derived from its 목표(target) datetime, so
// the board reads "what's overdue / due today / this week / later". Completed goals collect
// in their own 완료 group (newest first) regardless of target. Each row carries inline
// target/완료 datetime pickers; editing one posts to the server and the 5s poll re-renders.
function startOfDay(epochSec){ const d=new Date(epochSec*1000); d.setHours(0,0,0,0); return d.getTime()/1000; }
// datetime-local needs "YYYY-MM-DDTHH:mm" in LOCAL time; 0/absent => empty field.
function localInput(epochSec){ if(!epochSec) return '';
  const d=new Date(epochSec*1000), p=n=>(n<10?'0':'')+n;
  return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+'T'+p(d.getHours())+':'+p(d.getMinutes()); }
function fmtDate(epochSec){ if(!epochSec) return '–'; const d=new Date(epochSec*1000), p=n=>(n<10?'0':'')+n;
  return (d.getMonth()+1)+'/'+d.getDate()+' '+p(d.getHours())+':'+p(d.getMinutes()); }
// datetime-local value -> epoch seconds (local tz); empty -> 0 (clears the field server-side).
function setTarget(id,val){ const v=val?Math.floor(new Date(val).getTime()/1000):0; post('/api/goal/target',{id:id,target:v}); }
function setCompleted(id,val){ const v=val?Math.floor(new Date(val).getTime()/1000):0; post('/api/goal/completed',{id:id,completed:v}); }
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
    +gpill(g)
    +slinkBtn(g)
    +'<span class="st"><span class="gt" id="gt_'+g.id+'" title="더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span></span>'
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
  $('value').textContent=conf.toFixed(1)+'h';
  // report + markdown (read-only; safe to rebuild each tick)
  _md=buildMarkdown(d,r,conf,prov);
  _lastReportArgs={d:d,r:r,conf:conf,prov:prov};   // so reapplyFilter() can rebuild 프리뷰
  renderReport(d,r,conf,prov);
  // input-side DOM (has text fields) — rebuild only when review data changes,
  // so the 5s auto-refresh never wipes a note you're typing.
  const key=JSON.stringify(r);
  if(key!==_lastReviewKey){
    _lastReviewKey=key;
    fillActiveView(r);   // renders 목록 OR 그룹 (only the active one — see note above)
    renderAiQueue(r.aiQueue);   // AI추가 later 보관함 (큐) 갱신
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
  const idToNum={}; all.forEach(g=>{ idToNum[g.id]=g.seq; });   // stable seq, not position
  gv.innerHTML=energyGauge(all)+list.map(g=>goalRow(g,all.indexOf(g),r,idToNum)).join('');
  applyEvOpen(); applyNoteOpen();
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
// commits on blur/Enter (스프 배지를 눌러 일일 목록에서 바로 스프린트 변경).
function spBadge(g){
  const n=(g.sprint>0)?g.sprint:0;   // -1(분리)·0은 모두 미배정 표시
  return '<span class="spbadge'+(n?'':' none')+'" id="sp_'+g.id+'" title="클릭해 스프린트 변경"'
    +' onclick="editSpInline(\''+g.id+'\')">'+(n?esc(sprintCode(n)):'스프 –')+'</span>';
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
function goalRow(g,i,r,idToNum){
  const pnum=(g.parent&&idToNum[g.parent])?idToNum[g.parent]:'';
  const isChild=!!g.parent;
  // Parent goals show a derived rollup status (not manual buttons); leaves stay manual.
  const ds=derivedStatus(r.goals,g);
  const statCell=(ds!==null)
    ? '<span class="ot '+ds+'" title="자식 태스크 상태에서 자동 계산">'+statLabel(ds)+'</span>'
    : statSel(g);
  const running=(g.status==='in_progress')||(ds==='on_track');
  return '<div class="goal'+(ds==='on_track'?' ontrack':(running?' running':''))+'" data-i="'+i+'" oncontextmenu="goalCtx(event,\''+g.id+'\')" ondragover="dragOver(event,'+i+')" ondrop="dropOn(event,'+i+')" ondragleave="dragLeave(event)">'
    +'<span class="grip" draggable="true" ondragstart="dragStart(event,'+i+')" ondragend="dragEnd(event)" title="드래그하여 우선순위 변경">⠿</span>'
    +gpill(g)
    +slinkBtn(g)+spBadge(g)
    +'<span class="g">'+(isChild?'<span class="muted">└ </span>':'')+'<span class="gt" id="gt_'+g.id+'" title="더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+'</span></span>'
    +'<span class="stat">'+statCell+'</span>'
    +ttimeHTML(g)+wbadgeHTML(g)
    +'<span class="muted" style="font-size:12px">부모#</span>'
    +'<input type="text" inputmode="numeric" value="'+pnum+'" placeholder="–" title="부모 번호 입력 (비우면 최상위)" '
    +'onchange="setParentByNumber(\''+g.id+'\',this.value)" style="width:46px;text-align:center">'
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
    +'<td>'+gpill(g)+'</td>'
    +'<td>'+pnum+'</td>'
    +'<td>'+stCell+'</td>'
    +'<td class="nm">'+(isChild?'<span class="muted">└ </span>':'')+esc(g.text)+'</td>'
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

// ===== 토큰 뷰 — 완료 항목의 토큰 사용량을 완료일·스프린트로 묶어 본다 =====
// 목적: "어제(혹은 특정 기간)에 어느 스프린트로 토큰을 얼마나 썼나"를 한눈에. 완료된 목표만
// 대상으로 삼아, 완료 시각(없으면 자식 롤업)을 기준으로 오늘/어제/이번 주/이전 그룹으로 나누고
// 각 그룹·전체·스프린트별 토큰 합계를 보여준다. 상단의 스프린트 콤보·완료 컷오프 필터가 그대로
// 적용되어, 컷오프를 '어제 0시'로 두면 자연히 "어제 이후 완료분"만 남는 식으로 좁힐 수 있다.
// 0=오늘(미래 완료 포함), 1=어제, 2=이번 주(그제~6일 전), 3=이전, 9=완료 시각 미상.
function tkDayKey(epochSec){
  if(!epochSec) return 9;
  const diff=Math.round((startOfDay(Date.now()/1000)-startOfDay(epochSec))/86400);
  if(diff<=0) return 0;
  if(diff===1) return 1;
  if(diff<7) return 2;
  return 3;
}
const TK_GROUPS=[[0,'오늘'],[1,'어제'],[2,'이번 주'],[3,'이전'],[9,'완료 시각 미상']];
// 읽기 전용 스프린트 코드 태그 (스프 배지와 달리 클릭 편집 없음 — id 충돌 방지).
function tkSprintTag(g,goals){
  const n=effSprint(g,goals);
  return '<span class="spbadge'+(n?'':' none')+'" style="cursor:default" title="스프린트">'+(n?esc(sprintCode(n)):'스프 –')+'</span>';
}
function tkRow(g,goals){
  const c=goalCompletedAt(g,goals);
  return '<div class="schrow">'
    +gpill(g)+slinkBtn(g)
    +'<span class="st"><span class="gt">'+esc(g.text)+'</span></span>'
    +tkSprintTag(g,goals)
    +'<span class="dday done">✓ '+(c?fmtDate(c):'완료')+'</span>'
    +'<span class="tkn" title="이 목표에 누적된 토큰">'+(g.tokens||0)+' K</span>'
    +'</div>';
}
function renderTokenView(r){
  const all=(r&&r.goals)||[]; _goals=all;
  updateFilterButtons();
  const host=$('tokenHost'); if(!host) return;
  // 완료된 목표만: 상태 콤보와 무관하게 done만 본다(토큰 뷰의 본분). 단, 릴리즈 숨김·스프린트
  // 콤보·완료 컷오프는 다른 뷰와 동일하게 적용해 "특정 스프린트·특정 기간"으로 좁힐 수 있게 한다.
  const list=all.filter(g=>!g.released && effStatus(g,all)==='done'
    && passesSprintFilter(g,all) && passesDoneCutoff(g,all));
  if(!list.length){ host.innerHTML='<div class="muted" style="padding:8px 0">표시할 완료 목표가 없습니다 (스프린트·완료 컷오프 필터를 확인하세요).</div>'; return; }
  const sumTok=gs=>gs.reduce((a,g)=>a+(g.tokens||0),0);
  const total=sumTok(list);
  // 완료일 그룹으로 분배.
  const byDay={}; TK_GROUPS.forEach(d=>byDay[d[0]]=[]);
  list.forEach(g=>{ byDay[tkDayKey(goalCompletedAt(g,all))].push(g); });
  const newestFirst=(a,b)=>(goalCompletedAt(b,all)-goalCompletedAt(a,all))||((b.seq||0)-(a.seq||0));
  // 상단 요약: 합계 + 오늘·어제 즉시 비교 (이 뷰의 핵심 질문 — "어제 얼마나 썼나").
  let h='<div class="tksum">'
    +'<span><span class="k">합계</span> <span class="big">'+total+'</span> <span class="k">K · 완료 '+list.length+'개</span></span>'
    +'<span><span class="k">오늘</span> <b>'+sumTok(byDay[0])+'</b> <span class="k">K</span></span>'
    +'<span><span class="k">어제</span> <b>'+sumTok(byDay[1])+'</b> <span class="k">K</span></span>'
    +'<span><span class="k">이번 주</span> <b>'+sumTok(byDay[2])+'</b> <span class="k">K</span></span>'
    +'</div>';
  // 스프린트별 합계 (보이는 목록 기준, 토큰 많은 순) — "어느 스프린트에 썼나".
  const spTok={}; list.forEach(g=>{ const n=effSprint(g,all); spTok[n]=(spTok[n]||0)+(g.tokens||0); });
  const spRows=Object.keys(spTok).map(n=>[parseInt(n,10),spTok[n]]).sort((a,b)=>b[1]-a[1]);
  if(spRows.length){
    h+='<div class="tkspr">'+spRows.map(s=>'<span class="chip">'
      +(s[0]?esc(sprintCode(s[0])):'스프 –')+' <b>'+s[1]+'</b> K</span>').join('')+'</div>';
  }
  // 완료일 그룹 섹션 — 비어 있는 그룹은 건너뛴다. 각 섹션 머리글에 그룹 토큰 합계.
  TK_GROUPS.forEach(d=>{
    const gs=byDay[d[0]]; if(!gs.length) return;
    gs.sort(newestFirst);
    h+='<div class="schsec'+(d[0]===0?' today':'')+'">'
      +'<div class="schsec-hd">'+d[1]+'<span class="cnt">'+gs.length+'개</span>'
      +'<span class="tot">'+sumTok(gs)+' K</span></div>'
      +gs.map(g=>tkRow(g,all)).join('')+'</div>';
  });
  host.innerHTML=h;
}

// ===== 스프린트 뷰 — Jira식 백로그 보드 (스프린트 그룹 + Backlog + 완료 로그) =====
const DUR_OPTS=[['1d','1일'],['2d','2일'],['3d','3일'],['1w','1주'],['2w','2주'],['1m','1달']];
function durLabel(k){ const o=DUR_OPTS.find(x=>x[0]===k); return o?o[1]:k; }
let _spCollapsed=new Set();  // collapsed groups (sprint number, or 'bg' for Backlog)
let _bgCollapsed=new Set();  // collapsed parent goal ids (자식 접기) within a group
let _bgSeen=new Set();       // parents already defaulted-collapsed (so the 5s re-render never re-collapses one the user opened)
let _relOpen=new Set();      // expanded release ids (완료 로그는 기본 닫힘)
let _relLogOpen=false;       // 완료 로그 섹션 전체 펼침 (기본 접힘 — 접히면 아이템 DOM을 아예 만들지 않아 노드 수를 줄인다)
// 스프린트 코드(26-1) 조회 — 일일 목록의 스프 배지 등에서 사용.
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
      +'<span class="g"><span class="gt">'+esc(g.text)+'</span>'+why+'</span>'
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
  const aq=(r&&r.aiQueue)||[];                          // AI 큐: 섹션(sprint/backlog)별로 하단에 배치
  let h=sprints.map(s=>sprintGroupHTML(s,shown,allLive,aq)).join('');
  h+=backlogHTML(shown,allLive,aq);
  h+=completedLogHTML(r);
  $('sprintHost').innerHTML=h;
  if(_spModalNum!=null) fillSprintModal();   // 열려 있으면 최신 데이터로 갱신(기간 변경 시 목표일 반영)
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
function extSetAbs(val){ _extAbs=val?Math.floor(new Date(val).getTime()/1000):0; if(_extAbs) _extHours=0;
  const pv=$('extPrev'); if(pv){ const nt=extPreviewAt(); pv.innerHTML='조정 후 <b>'+(nt?fmtDate(nt):'변경 없음')+'</b>'; }
  const ap=$('extApply'); if(ap){ const on=extDirty(); ap.disabled=!on; ap.style.opacity=on?'':'0.5'; ap.style.cursor=on?'':'default'; ap.textContent=extApplyLabel(); } }
function extModalForm(s){
  const t=s.targetAt||0, base=extBase(s);
  const mag=Math.abs(_extHours), dir=_extHours>0?'시간 연장':(_extHours<0?'시간 단축':'변경 없음');
  const sign=_extHours>0?'+':(_extHours<0?'−':'');
  const on=extDirty(), pv=extPreviewAt();
  return '<h3>스프린트 '+esc(s.code||('#'+s.number))+' 마감 조정</h3>'
    +'<div class="extcur">현재 마감 <b>'+(t?fmtDate(t):'미정')+'</b></div>'
    +'<div class="extrow"><button class="extbtn" onclick="extStep(-1)">−</button>'
    +'<span class="exth"><b>'+sign+mag+'</b><small>'+dir+'</small></span>'
    +'<button class="extbtn" onclick="extStep(1)">＋</button></div>'
    +'<div class="extnew" id="extPrev">조정 후 <b>'+(pv?fmtDate(pv):'변경 없음')+'</b></div>'
    +'<div class="exthint">＋ / − 2시간 단위로 연장·단축</div>'
    +'<div class="extset"><span class="dlab">직접 지정</span>'
    +'<input type="datetime-local" value="'+localInput(_extAbs||t||Math.floor(base))+'" oninput="extSetAbs(this.value)" onchange="extSetAbs(this.value)">'
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
  const pcell = hasKids
    ? '<span class="pin-sp"></span>'
    : (function(){
        const p=g.parent?byId(_goals,g.parent):null;
        const psn=p?pad2(p.seq||0):'';
        return '<input class="pin" type="text" inputmode="numeric" draggable="false" value="'+psn+'"'
          +' placeholder="부모#" title="번호 입력 (예: 02 → goal-02의 자식) · Cmd+드래그로 아래 행에 채우기 · 비우면 최상위"'
          +' onmousedown="pinDown(event,\''+g.id+'\')" onclick="event.stopPropagation()" ondblclick="event.stopPropagation()"'
          +' onkeydown="if(event.key===\'Enter\')this.blur()" onchange="setParentByNumber(\''+g.id+'\',this.value)">';
      })();
  return '<div class="bgoal'+(isChild?' child':'')+'" data-id="'+g.id+'" draggable="true"'
    +' oncontextmenu="goalCtx(event,\''+g.id+'\')" onmouseenter="priRowEnter(\''+g.id+'\');pinRowEnter(\''+g.id+'\')"'
    +' ondragstart="spDragStart(event,\''+g.id+'\')" ondragend="spDragEnd(event)">'
    +lead+'<span class="grip" title="드래그=스프린트 이동 · 우클릭=메뉴 · 부모#칸에서 Cmd+드래그=부모 채우기">⠿</span>'+priDot+gpill(g)
    +'<span class="t gt" id="gt_'+g.id+'" title="더블클릭하여 제목 편집" ondblclick="startTitleEdit(event,\''+g.id+'\')">'+esc(g.text)+pr+'</span>'
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
// 스프린트 그룹 (드롭 타깃)
function sprintGroupHTML(s,shown,allLive,aq){
  const rows=shown.filter(g=>boardSprint(g,_goals)===s.number);
  const members=allLive.filter(g=>boardSprint(g,_goals)===s.number);   // 카운트는 전체 멤버
  const q=aiQueueBoxHTML((aq||[]).filter(it=>(it.sprint||0)===s.number));   // 이 스프린트로 담긴 큐 → 하단
  const body=(rows.length?groupBodyHTML(rows)
    :(q?'':'<div class="empty">'+(members.length?'필터에 맞는 목표가 없습니다 (상태 필터 확인)':'여기로 목표를 끌어다 놓기')+'</div>'))+q;
  const col=_spCollapsed.has(s.number);
  return '<div class="spgrp'+(col?' collapsed':'')+'" ondragover="spOver(event)" ondragleave="spLeave(event)" ondrop="spDrop(event,'+s.number+')">'
    +'<div class="spgrp-hd">'
      +'<span class="spchev" onclick="toggleSpCollapse('+s.number+')" title="펼치기/접기">▾</span>'
      +'<span class="pill sp">'+esc(s.code||('#'+s.number))+'</span>'
      +'<span class="ttl">'+(s.goalText?esc(s.goalText):'<span class="muted">예상 결과 미정</span>')+'</span>'
      +sprintCountdownHTML(s)+'<span style="flex:1"></span>'+countsHTML(members)
      +'<button class="btn" onclick="addGoalToSprint('+s.number+')" title="이 스프린트에 목표 바로 추가">＋ 목표</button>'
      +'<button class="btn rel" onclick="releaseSprintGroup('+s.number+')">Complete sprint</button>'
      +'<button class="btn" onclick="spMenu(event,'+s.number+')" title="자세히 (편집·삭제)">⋯</button>'
    +'</div>'
    +'<div class="spgrp-body">'+body+'</div>'
  +'</div>';
}
// Backlog (미배정) — Create sprint 버튼 포함
function backlogHTML(shown,allLive,aq){
  const rows=shown.filter(g=>boardSprint(g,_goals)===0);
  const members=allLive.filter(g=>boardSprint(g,_goals)===0);
  const q=aiQueueBoxHTML((aq||[]).filter(it=>(it.sprint||0)===0));   // 백로그로 담긴 큐 → 하단
  const body=(rows.length?groupBodyHTML(rows)
    :(q?'':'<div class="empty">'+(members.length?'필터에 맞는 목표가 없습니다 (상태 필터 확인)':'미배정 목표가 없습니다')+'</div>'))+q;
  const col=_spCollapsed.has('bg');
  return '<div class="spgrp bg'+(col?' collapsed':'')+'" ondragover="spOver(event)" ondragleave="spLeave(event)" ondrop="spDrop(event,0)">'
    +'<div class="spgrp-hd"><span class="spchev" onclick="toggleSpCollapse(\'bg\')" title="펼치기/접기">▾</span>'
      +'<b>Backlog</b><span class="muted" style="font-size:12px">미배정</span>'
      +'<span style="flex:1"></span>'+countsHTML(members)
      +'<button class="btn" onclick="addGoalToBacklog()" title="목표를 추가합니다 (입력·AI추가 모듈)">＋ 목표 추가</button>'
      +'<button class="btn primary" onclick="createSprintNow()">＋ Create sprint</button></div>'
    +'<div class="spgrp-body">'+body+'</div>'
  +'</div>';
}
// 완료된 스프린트 (릴리즈 커밋 로그) — 기본 닫힘, 헤더 클릭으로 펼침.
// 섹션이 접혀 있으면 릴리즈 아이템을, 아이템이 접혀 있으면 그 목표 행을 아예 만들지 않는다(지연 렌더링).
// display:none 으로 숨기면 노드가 DOM에 그대로 남으므로, 실제 노드 수를 줄이려면 innerHTML 자체를 비워야 한다.
function completedLogHTML(r){
  const rels=(r&&r.releases)||[]; if(!rels.length) return '';
  const hdr='<h3 class="rellog-hd'+(_relLogOpen?' open':'')
    +'" onclick="toggleRelLog()" style="font-size:13px;color:var(--mut);margin:18px 0 8px;border-top:1px solid var(--line);padding-top:14px">'
    +'<span class="chev'+(_relLogOpen?' open':'')+'">▸</span>완료된 스프린트 (릴리즈 로그) '
    +'<span class="muted" style="font-weight:400">('+rels.length+')</span></h3>';
  if(!_relLogOpen) return hdr;   // 섹션 접힘: 헤더만 렌더 — 릴리즈 아이템 DOM을 만들지 않는다
  const goalById={}; ((r&&r.goals)||[]).forEach(g=>{ goalById[g.id]=g; });
  const sgoalOf={}; ((r&&r.sprints)||[]).forEach(s=>{ sgoalOf[s.number]=s.goalText||''; });
  const codeOf={}; ((r&&r.sprints)||[]).forEach(s=>{ codeOf[s.number]=s.code||('#'+s.number); });
  const items=rels.map(function(rel){
    const when=rel.releasedAt?fmtDate(rel.releasedAt):'—';
    // Prefer the release's own snapshot code (unique per release); fall back to the sprint's
    // current code for legacy records saved before per-release codes existed.
    const code=rel.code||((rel.sprint>0)?(codeOf[rel.sprint]||('#'+rel.sprint)):'');
    const gtext=(rel.sprint>0&&sgoalOf[rel.sprint])?(' · '+esc(sgoalOf[rel.sprint])):'';
    const head=code?(code+gtext):'미배정';
    const open=_relOpen.has(rel.id);
    const ids=rel.goalIds||[], titles=rel.titles||[];
    // 접힌 아이템은 행을 만들지 않는다 — 펼칠 때(open) 재렌더에서 생성되어 DOM 노드를 아낀다.
    const rows=!open ? '' : (titles.length ? titles.map(function(t,i){
      const g=goalById[ids[i]]; const gn=g?('<span class="gn">goal-'+pad2(g.seq||0)+'</span>'):'';
      // Parent indicator: child goals show the parent's number (gray); top-level goals show a purple "부모" badge.
      let pn='';
      if(g){
        if(g.parent){ const p=goalById[g.parent]; pn='<span class="pn" title="상위 목표">'+(p?('goal-'+pad2(p.seq||0)):'상위')+'</span>'; }
        else { pn='<span class="pn top" title="최상위 목표">부모</span>'; }
      }
      return '<div class="relrow">'+pn+gn+'✓ '+esc(t)+'</div>';
    }).join('') : '<div class="muted" style="font-size:12px">목표 없음</div>');
    return '<div class="relitem">'
      +'<h4 class="clk" onclick="toggleRel(\''+rel.id+'\')">'
        +'<span><span class="chev'+(open?' open':'')+'">▸</span>'+head+' · '+when
        +' <span class="muted" style="font-weight:400;font-size:12px">('+titles.length+'개)</span></span>'
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
  e.preventDefault();                   // 행의 네이티브 드래그(스프린트 이동) 차단
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

// --- 드래그 배정 (스프린트/Backlog 그룹 이동) ---
let _spDrag=null;
function spDragStart(e,id){ _spDrag=id; e.currentTarget.classList.add('dragging'); e.dataTransfer.effectAllowed='move'; }
function spDragEnd(e){ e.currentTarget.classList.remove('dragging'); document.querySelectorAll('.spgrp.dropOver').forEach(x=>x.classList.remove('dropOver')); _spDrag=null; }
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
// Shared by EVERY view's right-click menu (목록·그룹·테이블·일정·스프린트). A top-level
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
// 우클릭: 작업 항목 이동(순서) · 스프린트/Backlog 이동 · 부모(계층) — 모든 뷰 공용
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
  html+='<div class="pophdr" style="border-top:1px solid var(--line);margin-top:2px">스프린트로 이동</div>'
    +'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();moveGoalToSprint(\''+id+'\','+bg+')">Backlog'+((g&&g.parent)?' (부모와 분리)':'')+'</button>';
  html+=sprints.map(s=>'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();moveGoalToSprint(\''+id+'\','+s.number+')">'+esc(s.code||('#'+s.number))+(s.goalText?(' · '+esc(s.goalText)):'')+'</button>').join('');
  html+='<div class="pophdr" style="border-top:1px solid var(--line);margin-top:2px">부모(계층)</div>'
    +'<button class="popitem" onmousedown="event.stopPropagation();openParentPicker(\''+id+'\')">부모 설정 / 해제 ▸</button>';
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
  showPopup(e.clientX,e.clientY,html);
}
function moveGoalToSprint(id,n){ post('/api/goal/sprint',{id:id,sprint:n}); }
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
function ppLastParent(){ try{ return localStorage.getItem('cm.lastParent')||''; }catch(e){ return ''; } }
function renderParentList(q){
  const el=$('ppList'); if(!el) return;
  q=String(q||'').toLowerCase().trim();
  // 후보: 최상위(부모 없음)·릴리즈 안 됨·자기 자신 제외 (백엔드가 2단계 중첩은 재차 검증)
  const cands=(_goals||[]).filter(g=>g.id!==_ppId && !g.parent && !g.released && !g.archived);
  // 정렬 우선순위: ① 마지막 선택 부모(전역 1개) → ② 현재(열린) 스프린트 부모(스프린트 번호·보드 순)
  //              → ③ 나머지. 동일 그룹 안에서는 원래 _goals 순서를 유지한다.
  const pinned=ppLastParent();
  const openSp={}; ((_review&&_review.sprints)||[]).forEach(function(s){ if(!s.closed) openSp[s.number]=true; });
  const idx={}; cands.forEach(function(g,i){ idx[g.id]=i; });
  function rank(g){ if(g.id===pinned) return 0; if(g.sprint>0 && openSp[g.sprint]) return 1; return 2; }
  const ordered=cands.slice().sort(function(a,b){
    const ra=rank(a),rb=rank(b); if(ra!==rb) return ra-rb;
    if(ra===1 && (a.sprint||0)!==(b.sprint||0)) return (a.sprint||0)-(b.sprint||0);   // 현재 스프린트 번호 순
    return idx[a.id]-idx[b.id];                                                        // 그 외 보드(원래) 순
  });
  const f=ordered.filter(function(g){ if(!q) return true; const lab=('goal-'+pad2(g.seq||0)+' '+(g.text||'')).toLowerCase(); return lab.indexOf(q)>=0; });
  el.innerHTML = f.length
    ? f.map(g=>'<button class="popitem" onmousedown="event.stopPropagation();hidePopup();setParentById(\''+_ppId+'\',\''+g.id+'\')"><span class="gn">goal-'+pad2(g.seq||0)+'</span>'+esc(g.text)+(g.id===pinned?'<span class="ppfresh">최근</span>':'')+'</button>').join('')
    : '<div class="muted" style="padding:7px 10px;font-size:12px">결과 없음</div>';
}
// 부모 지정 시 전역 '마지막 선택' 1개를 브라우저에 저장(해제는 저장하지 않음).
function setParentById(id,pid){ if(pid){ try{ localStorage.setItem('cm.lastParent',pid); }catch(e){} } post('/api/goal/parent',{id:id,parent:pid}); }

// --- 스프린트 편집 모달 ---
let _spModalNum=null;
function spModalForm(s){
  const chips=DUR_OPTS.map(o=>'<span class="durchip'+(o[0]===s.durationKind?' on':'')+'" onclick="setSprintDur('+s.number+',\''+o[0]+'\')">'+o[1]+'</span>').join('');
  return '<h3>스프린트 '+esc(s.code||('#'+s.number))+' 편집</h3>'
    +'<div class="line"><span class="lab">예상 결과</span><input class="spmgoal" value="'+esc(s.goalText).replace(/"/g,'&quot;')+'" placeholder="이 스프린트가 끝나면 완성될 것" onchange="updateSprintGoal('+s.number+',this.value)"></div>'
    +'<div class="line"><span class="lab">기간</span><span class="chips">'+chips+'</span></div>'
    +'<div class="line"><span class="lab">시작</span><input type="datetime-local" value="'+localInput(s.startAt)+'" onchange="setSprintDate('+s.number+',\'startAt\',this.value)"></div>'
    +'<div class="line"><span class="lab">목표</span><input type="datetime-local" value="'+localInput(s.targetAt)+'" onchange="setSprintDate('+s.number+',\'targetAt\',this.value)"></div>'
    +'<div class="line" style="margin-top:4px"><button class="btn danger" style="border-color:#5a2738;color:#ff9db0" onclick="deleteSprintNow('+s.number+')">스프린트 삭제</button><span style="flex:1"></span><button class="btn primary" onclick="closeSprintModal()">닫기</button></div>';
}
function openSprintModal(n){ _spModalNum=n; fillSprintModal(); const m=$('spModal'); if(m) m.style.display='flex'; }
function fillSprintModal(){ if(_spModalNum==null) return; const s=((_review&&_review.sprints)||[]).find(x=>x.number===_spModalNum); if(!s){ closeSprintModal(); return; } const b=$('spModalBox'); if(b) b.innerHTML=spModalForm(s); }
function closeSprintModal(){ _spModalNum=null; const m=$('spModal'); if(m) m.style.display='none'; }

// 이 스프린트에 목표 바로 추가 — 재사용 목표 추가 모듈을 연다 (입력·AI추가·추가 공유).
function addGoalToSprint(n){ const s=((_review&&_review.sprints)||[]).find(x=>x.number===n); openGoalAdd({sprint:n,label:(s&&s.code)||('#'+n)}); }
// Backlog(미배정)에 목표 추가 — 같은 재사용 모듈, 대상만 Backlog.
function addGoalToBacklog(){ openGoalAdd({sprint:0,label:'Backlog'}); }
function createSprintNow(){ post('/api/sprint/create',{goalText:'',durationKind:'1d'}); }   // 자동 코드(26-N), Backlog 비움
function updateSprintGoal(n,v){ post('/api/sprint/update',{number:n,goalText:String(v||'')}); }
function setSprintDur(n,k){ post('/api/sprint/update',{number:n,durationKind:k}); }   // 목표 날짜는 서버가 재계산
function setSprintDate(n,key,val){ const ep=val?Math.floor(new Date(val).getTime()/1000):0; const o={number:n}; o[key]=ep; post('/api/sprint/update',o); }
function deleteSprintNow(n){ if(!confirm('이 스프린트를 삭제합니다. 배정된 목표는 Backlog로 돌아갑니다.')) return; post('/api/sprint/delete',{number:n}); }
// Complete sprint = 닫고·이월하고·전진한다: 완료 목표는 커밋, 미완료는 다음 스프린트로 이월,
// 현재 스프린트는 닫고, 다음 번호(26-2→26-3)가 24시간 자동으로 새로 열린다.
function releaseSprintGroup(n){ if(!confirm('이 스프린트를 완료합니다. 완료 목표는 커밋되고, 미완료 목표는 다음 스프린트로 이월되며, 다음 번호의 스프린트가 24시간으로 새로 열립니다.')) return; post('/api/sprint/complete',{number:n}); }

// 완료 로그 펼침/복원
function toggleRel(id){ if(_relOpen.has(id))_relOpen.delete(id); else _relOpen.add(id); if(_review) renderSprintBoard(_review); }
function toggleRelLog(){ _relLogOpen=!_relLogOpen; if(_review) renderSprintBoard(_review); }   // 섹션 전체 펼침/접힘
function restoreRelease(id){ post('/api/release/restore',{id:id}); }
// 오른쪽 위 Complete sprint 버튼: 현재 스프린트 필터의 완료 목표를 커밋한다.
function releaseCurrentSprint(){
  if(_sprintSel.size>1){ alert('Complete sprint는 한 번에 하나의 스프린트만 가능합니다. 스프린트를 하나만 선택하세요.'); return; }
  const only=(_sprintSel.size===1)?[..._sprintSel][0]:0;   // 0 = 모두
  // 단일 스프린트 선택 시 = 완료 후 다음 번호로 전진(이월 포함). '모두' 선택 시 = 전진 없이
  // 전 스프린트의 완료 목표만 커밋(번호 전진은 특정 스프린트를 완료할 때만 의미가 있으므로).
  if(only){
    if(!confirm('스프린트 '+sprintCode(only)+'을(를) 완료합니다. 완료 목표는 커밋되고, 미완료 목표는 다음 스프린트로 이월되며, 다음 번호의 스프린트가 24시간으로 새로 열립니다.')) return;
    post('/api/sprint/complete',{number:only});
  }else{
    if(!confirm('모든 스프린트의 완료 목표를 커밋합니다. 목록에서 사라지고 완료 로그로 이동합니다.')) return;
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
function buildMarkdown(d,r,conf,prov){
  const goals=r.goals||[], tops=goals.filter(g=>!g.parent && goalPasses(g,goals));
  let md='# 오늘 리포트 ('+d.date+')\n\n- 확정 가치: '+conf.toFixed(2)+'h (잠정 '+prov.toFixed(1)+'h)\n\n';
  tops.forEach(t=>{
    const ds=derivedStatus(goals,t);
    md+='## '+t.text+(ds==='on_track'?' [on track]':(ds==='done'?' [완료]':''))+(gnote(r,t.id)?(' — '+gnote(r,t.id)):'')+'\n';
    md+=evMd(t);
    goals.filter(c=>c.parent===t.id && goalPasses(c,goals)).forEach(c=>{ const cs=(c.status||'backlog');
      const m=cs==='in_progress'?' (진행)':(cs==='done'?' (완료)':'');
      md+='- '+c.text+m+(gnote(r,c.id)?(' — '+gnote(r,c.id)):'')+'\n'; md+=evMd(c); });
    md+='\n';
  });
  return md;
}
function renderReport(d,r,conf,prov){
  const goals=r.goals||[], tops=goals.filter(g=>!g.parent && goalPasses(g,goals));
  let html='<div class="muted" style="margin-bottom:10px">'+esc(d.date)+' · 확정 '+conf.toFixed(2)+'h (잠정 '+prov.toFixed(1)+'h)</div>';
  if(!tops.length) html+='<div class="muted">'+(anyStatusActive()?'필터에 해당하는 목표가 없습니다.':'목표가 없습니다. 입력 뷰에서 추가하세요.')+'</div>';
  tops.forEach(t=>{
    const ds=derivedStatus(goals,t);
    const tag=ds==='on_track'?'<span class="otTag">On Track</span>':(ds==='done'?'<span class="otTag" style="border-color:var(--green);color:var(--green);background:rgba(54,192,138,.12)">완료</span>':'');
    html+='<h3 style="margin:12px 0 4px">'+esc(t.text)+tag+'</h3>';
    if(gnote(r,t.id)) html+='<div class="muted" style="margin-bottom:4px">'+esc(gnote(r,t.id))+'</div>';
    html+=evReportHtml(t);
    const kids=goals.filter(c=>c.parent===t.id && goalPasses(c,goals));
    if(kids.length) html+='<ul>'+kids.map(c=>{ const cs=(c.status||'backlog');
      const m=cs==='in_progress'?' <span style="color:#9be3fb">(진행)</span>':(cs==='done'?' <span class="ok">(완료)</span>':'');
      return '<li>'+esc(c.text)+m+(gnote(r,c.id)?' <span class="muted">— '+esc(gnote(r,c.id))+'</span>':'')+evReportHtml(c)+'</li>'; }).join('')+'</ul>';
  });
  $('report').innerHTML=html;
}

function drawChart(samples){
  const c=$('chart'), dpr=window.devicePixelRatio||1, W=c.clientWidth, H=260;
  c.width=W*dpr; c.height=H*dpr; const g=c.getContext('2d'); g.setTransform(dpr,0,0,dpr,0,0); g.clearRect(0,0,W,H);
  const padL=44,padR=14,padT=14,padB=24, cw=W-padL-padR, ch=H-padT-padB;
  const maxRate=Math.max(1,...samples.map(s=>s.rate));
  const X=m=>padL+cw*(m/1440), Y=r=>padT+ch*(1-r/maxRate);
  g.strokeStyle='#232733'; g.fillStyle='#8b93a7'; g.lineWidth=1; g.font='11px system-ui';
  for(let h=0;h<=24;h+=3){ const px=X(h*60); g.beginPath(); g.moveTo(px,padT); g.lineTo(px,padT+ch); g.stroke(); g.fillText((h<10?'0':'')+h+':00',px-12,H-9); }
  if(!samples.length){ g.fillStyle='#8b93a7'; g.fillText('아직 활동 데이터가 없습니다. 작업을 시작하면 1분 뒤부터 쌓입니다.',padL,padT+ch/2); return; }
  g.fillStyle='rgba(54,192,138,0.22)'; const bw=Math.max(1,cw/1440);
  samples.forEach(s=>{ if(s.active>0) g.fillRect(X(minOfDay(s)),padT+ch-6,bw,6); });
  // total activity area
  g.beginPath(); samples.forEach((s,i)=>{const px=X(minOfDay(s)),py=Y(s.rate); i?g.lineTo(px,py):g.moveTo(px,py);});
  g.strokeStyle='#5b8cff'; g.lineWidth=2; g.stroke();
  g.lineTo(X(minOfDay(samples[samples.length-1])),padT+ch); g.lineTo(X(minOfDay(samples[0])),padT+ch); g.closePath();
  g.fillStyle='rgba(91,140,255,0.10)'; g.fill();
  // keyboard line
  g.beginPath(); samples.forEach((s,i)=>{const px=X(minOfDay(s)),py=Y(s.key||0); i?g.lineTo(px,py):g.moveTo(px,py);});
  g.strokeStyle='#36c08a'; g.lineWidth=1.5; g.stroke();
  // mouse line
  g.beginPath(); samples.forEach((s,i)=>{const px=X(minOfDay(s)),py=Y(s.mouse||0); i?g.lineTo(px,py):g.moveTo(px,py);});
  g.strokeStyle='#e8a13a'; g.lineWidth=1.5; g.stroke();
}

function drawStrip(samples){
  const c=$('strip'), dpr=window.devicePixelRatio||1, W=c.clientWidth, H=34;
  c.width=W*dpr; c.height=H*dpr; const g=c.getContext('2d'); g.setTransform(dpr,0,0,dpr,0,0); g.clearRect(0,0,W,H);
  const padL=44,padR=14, cw=W-padL-padR;
  g.fillStyle='#0d1016'; g.fillRect(padL,6,cw,20);
  const bw=Math.max(1.5,cw/1440);
  samples.forEach(s=>{ if(s.app && s.app!=='-'){ g.fillStyle=appColor(s.app); g.fillRect(padL+cw*(minOfDay(s)/1440),6,bw,20); } });
}

function appStats(samples){
  const apps={};
  samples.forEach(s=>{
    const a=s.app||'-'; if(a==='-') return;
    const e=apps[a]||(apps[a]={app:a,minutes:0,active:0,profiles:{},tracks:{}});
    e.minutes++; e.active+=(s.active||0);
    if(s.profile&&s.profile!=='-') e.profiles[s.profile]=(e.profiles[s.profile]||0)+1;
    if(s.track&&s.track!=='-') e.tracks[s.track]=(e.tracks[s.track]||0)+1;
  });
  return Object.values(apps).sort((x,y)=>y.minutes-x.minutes);
}

function renderApps(samples){
  const stats=appStats(samples);
  // bars
  const bars=$('appbars');
  if(!stats.length){ bars.innerHTML='<span class="empty">데이터 없음</span>'; }
  else {
    const max=Math.max(...stats.map(s=>s.minutes));
    bars.innerHTML=stats.map(s=>{
      const col=appColor(s.app), pct=Math.max(3,100*s.minutes/max);
      return '<div class="bar"><div class="name"><span class="dot" style="background:'+col+'"></span>'+esc(s.app)+'</div>'
        +'<div class="track"><div class="fill" style="width:'+pct+'%;background:'+col+'"></div></div>'
        +'<div class="val">'+fmtMin(s.minutes)+'</div></div>';
    }).join('');
  }
  // bgm debug table
  const rows=$('bgmrows');
  const withBgm=stats.filter(s=>Object.keys(s.tracks).length);
  if(!withBgm.length){ rows.innerHTML='<tr><td colspan="4" class="empty">아직 재생된 BGM 기록이 없습니다.</td></tr>'; return; }
  rows.innerHTML=withBgm.map(s=>{
    const col=appColor(s.app);
    const domProfile=Object.entries(s.profiles).sort((a,b)=>b[1]-a[1])[0];
    const profLabel=domProfile?domProfile[0]:'-';
    const band=BANDS[profLabel];
    const chips=Object.entries(s.tracks).sort((a,b)=>b[1]-a[1]).map(([t,n])=>{
      const bpm=trackBpm(t);
      const bad=band&&bpm!=null&&(bpm<band[0]||bpm>band[1]);
      return '<span class="chip'+(bad?' bad':'')+'">'+esc(t)+(n>1?' ×'+n:'')+'</span>';
    }).join('');
    return '<tr><td><span class="dot" style="background:'+col+'"></span>'+esc(s.app)+'</td>'
      +'<td>'+esc(profLabel)+'</td><td>'+chips+'</td><td>'+fmtMin(s.minutes)+'</td></tr>';
  }).join('');
}

// ===== Workers (background jobs) =====
// Shows every background worker, its schedule, and whether it's actually firing.
// The server sends agoSec/nextSec snapshots; we tick them locally each second so
// "마지막 실행" counts up and "다음 실행" counts down between 5s refreshes.
let _workers=[];          // last snapshot from the server
let _workersBase=0;       // performance.now() when the snapshot arrived (ms)
function fmtInterval(s){ if(s>=60&&s%60===0) return (s/60)+'분'; return s+'초'; }
function fmtAgo(sec){ if(sec<0) return '아직 없음';
  if(sec<60) return sec+'초 전'; const m=(sec/60)|0,s=sec%60; return m+'분 '+(s>0?s+'초 ':'')+'전'; }
function renderWorkers(arr){
  _workers=Array.isArray(arr)?arr:[];
  _workersBase=performance.now();
  const rows=$('workerrows');
  if(!_workers.length){ rows.innerHTML='<tr><td colspan="9" class="empty">데이터 없음</td></tr>'; return; }
  const ownerLabel=(o,manual)=>{
    if(manual) return '<span class="chip" style="margin:0;background:#7a8699;color:#fff" title="퇴근 시 손으로 실행(Scripts/bug-hunt.sh) — 스케줄러가 돌리지 않음">수동</span>';
    if(o==='qa') return '<span class="chip" style="margin:0;background:#3aa0ff;color:#fff" title="외부 자동화(launchd → claude -p)가 보고">자동화</span>';
    if(o&&o!=='core') return '<span class="chip" style="margin:0;background:#9b7bff;color:#fff" title="'+esc(o)+'">플러그인</span>';
    return '<span class="muted">기본</span>';
  };
  rows.innerHTML=_workers.map((w,i)=>{
    const off=w.enabled===false;   // user-toggled OFF (only meaningful for toggleable workers)
    let badge;
    if(off) badge='<span class="chip bad" title="사용자가 끔">꺼짐</span>';
    else { badge=w.active?'<span class="chip">동작 중</span>':'<span class="chip bad">유휴</span>';
      if(w.error) badge='<span class="chip bad" title="'+esc(w.errorMsg||'')+'">오류 ⚠</span> '+badge; }
    const more=w.id?'<a class="btn" href="/worker?id='+encodeURIComponent(w.id)+'" target="_blank">자세히</a>':'';
    // QA workers get an on/off toggle; the periodic inspection worker also gets run-now
    // (the fix worker is event-driven, so no manual run button).
    let ctrl='';
    if(w.toggleable){
      ctrl+=' <button class="btn" onclick="toggleWorker(\''+esc(w.id)+'\','+off+')">'+(off?'켜기':'끄기')+'</button>';
    }
    if(w.runnable){
      ctrl+=' <button class="btn" title="지금 한 번 실행" onclick="runWorker(this,\''+esc(w.id)+'\')"'+(off?' disabled':'')+'>즉시 실행</button>';
    }
    return '<tr'+(w.error&&!off?' style="background:rgba(226,102,125,0.08)"':'')+(off?' style="opacity:0.6"':'')+'><td><b>'+esc(w.name)+'</b></td>'
      +'<td>'+ownerLabel(w.owner,w.manual)+'</td>'
      +'<td class="muted">'+esc(w.detail)+'</td>'
      +'<td'+(w.manual?' title="자동 실행 주기가 아니라, 1회 실행 동안 도는 라운드 간격"':'')+'>'+(w.manual?'라운드 '+fmtInterval(w.interval):fmtInterval(w.interval))+'</td>'
      +'<td id="wk_ago_'+i+'">'+fmtAgo(w.agoSec)+'</td>'
      +'<td id="wk_next_'+i+'">'+(!off&&w.active&&w.nextSec>=0?w.nextSec+'초 후':'–')+'</td>'
      +'<td>'+(w.runs||0).toLocaleString()+'</td>'
      +'<td>'+badge+'</td>'
      +'<td>'+more+ctrl+'</td></tr>';
  }).join('');
  // Publish the audit synchronously — reading scrollHeight forces layout, so measures
  // are valid now. Synchronous (not rAF) so headless --dump-dom reliably captures it.
  publishQaAudit();
}
// QA-style worker controls. Toggle persists (writes a flag the runner script reads);
// run-now forces a single immediate pass (bypasses the interval + change gates).
function toggleWorker(id,wasOff){ post('/api/worker/toggle',{id:id,enabled:wasOff}); }
function runWorker(btn,id){
  if(btn){ btn.disabled=true; btn.textContent='실행 중…'; }
  post('/api/worker/run',{id:id}).then(()=>setTimeout(load,1500));
}
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
// Live 1s tick: advance ago up / next down without waiting for the 5s reload.
function tickWorkers(){
  if(!_workers.length) return;
  const elapsed=Math.floor((performance.now()-_workersBase)/1000);
  _workers.forEach((w,i)=>{
    if(w.agoSec>=0){ const a=document.getElementById('wk_ago_'+i); if(a) a.textContent=fmtAgo(w.agoSec+elapsed); }
    if(w.active&&w.nextSec>=0){ const n=document.getElementById('wk_next_'+i);
      if(n) n.textContent=Math.max(0,w.nextSec-elapsed)+'초 후'; }
  });
}
setInterval(tickWorkers,1000);

restoreFromURL();   // 해시에 저장된 뷰·필터 설정을 첫 렌더 전에 복원(새로고침 후에도 유지)
load();
setInterval(load,5000);
setInterval(liveTick,100);
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
</body>
</html>
"""#
    }
}
