import Foundation

// 메모장 — a drop-in memo pad, embeddable at any spot on any dashboard page with a single
// `\#(MemoPad.html())`. Same shape as CMTimeFilter.swift: one self-contained block of
// CSS + markup + JS, guarded by `window.CMMemo ||` so embedding it twice is harmless.
//
// WHY a module and not page-local markup: the pad is meant to live in MANY places (approved
// 2026-07-30 — "메모장은 여러곳에 사용된다"). Today it is mounted at the top of the 대화
// surface (/goal-add); tomorrow the dashboard, a goal page, or the zen window can host it
// by adding the same one line. Text is ONE GLOBAL memo (GET/POST /api/memo, MemoStore.swift),
// so whichever surface you write on, the same note is there on the next one.
//
// ── 편집면 ────────────────────────────────────────────────────────────────────
// The pad is a ROW editor, not a textarea (changed 2026-08-04). Each visual line is one row,
// and a row may be:
//   평문        — 그냥 메모. 예전과 완전히 같다. 자유롭게 쓴다.
//   체크리스트  — 왼쪽에 라운드 박스가 붙는다. 미완료 / 완료 / 바틀넥 3상태.
//   + 상세      — 접힌 본문. 제목은 한 줄로 두고 긴 설명은 여기에 내려 둔다(⌘Enter).
//
// 골번호(2026-08-06): 체크리스트 줄, 그리고 상세·칸을 단 줄(2026-08-08 확대 — 제목 한 줄을
// 넘어 내용을 갖춘 줄은 리포트에서 지목될 수 있어야 한다)은 보드(트래커)와 같은 골 번호
// 공간에서 유일 번호를 자동으로 받는다 — 번호 없는 줄 수만큼 POST /api/memo/seq 로 예약해 '@골: N' 들여쓴 줄로
// 저장한다(ReviewStore.reserveSeqs — 번호만 예약, Goal 은 만들지 않는다). 번호는 한 번 받으면
// 불변·재사용 없음. 그래서 '@부모: M' 칸에 아무 골번호(보드 골이든 메모 줄이든)를 적으면
// 부모의 부모로 이어지는 트리가 서고, 리포트에서 번호로 지목할 수 있다. 서버가 없는 환경
// (스텁·초안)에서는 채번이 조용히 미뤄지고, 그동안은 위치 순서 1,2,3… 을 폴백으로 보여 준다.
// 번호는 라운드 박스 안에 숨어 있다가 마우스를 올릴 때만 드러나고(평소 화면은 깨끗하게),
// 리포트에서는 항상 보인다 — 무엇을 끝냈고 무엇이 바틀넥에 걸렸는지 번호로 지목하기 위해서.
//
// 루프(2026-08-07): "어제 완료한 건 볼 필요 없다" 를 날짜로 자르지 않는다 — 새벽까지
// 이어지는 작업에서 날짜 경계는 애매하다. 대신 보드(트래커)와 같은 루프가 단위다:
// 루프 번호는 보드의 스프린트/릴리즈 코드와 한 일련번호다(현재 = 열린 스프린트 코드
// 26-38, 이전 = 최신 릴리즈 코드 26-37 — /data.json 에서 게으르게 읽고, 보드가 없는
// 환경에서만 숫자 스탬프 폴백). 완료 줄은 두 길로 이전 루프에 묻힌다:
//   - 보기 콤보의 '루프 종료' — 그때까지의 완료 줄에 '@루프: <코드>' 스탬프(⌘Z 한 단계)
//   - 보드의 루프 컷(릴리즈) — 서버(MemoStore.harvestLoop)가 같은 스탬프를 찍고, 그
//     제목들을 릴리즈 기록(notes)에 실어 '완료된 루프' 로그에 '노트' 태그로 보인다
//     (AI 세션으로 굴린 보드 목표 = session 태그와 구분).
// 묻힌 줄은 기본 보기에서 사라지고 미완료·바틀넥은 다음 루프로 넘어간다. 스탬프도 여느
// 줄처럼 판번호·병합·히스토리의 보호를 그대로 받는다. 묻힌 완료는 보기 콤보의
// '이전 루프 포함' 으로 언제든 다시 본다(완료 체크와 다른 축). 완료에서 상태를 되돌리면
// 스탬프가 떨어져 현재 루프로 복귀한다 — 다시 완료하는 순간 또 묻히지 않도록.
//
// 저장 포맷(순수 텍스트 그대로, /api/memo):
//     - [ ] 할 일        미완료
//     - [x] 할 일        완료
//     - [!] 할 일        바틀넥(막힘)
//     ␣␣␣␣상세 본문      바로 앞 항목의 상세(4칸 들여쓰기, 여러 줄 가능)
//     ␣␣␣␣@루프: N       이전 루프 스탬프 — '루프 종료' 가 완료 줄에 찍는다(아래 루프 절)
//     그 외 줄          평문 메모
// 마크다운스러운 평문이라 다른 편집기로 열어도 읽히고, 체크리스트를 한 번도 안 쓴 기존 메모는
// 한 글자도 변하지 않는다(파싱 → 재직렬화가 항등).
//
// ── 되돌리기 ──────────────────────────────────────────────────────────────────
// ⌘Z / ⌘⇧Z 는 우리가 직접 처리한다(2026-08-05). 행을 코드로 조립하고 지우는 편집면이라
// WebKit 의 네이티브 undo 스택이 중간중간 끊기고, 브라우저에 맡기면 되돌아가는 대신 행
// 구조가 반쯤 부서진 상태가 나온다. 되돌리는 단위는 '저장 텍스트 + 캐럿 좌표(행 번호·칸·
// 글자 수)' 한 벌 — 텍스트가 곧 진실이므로 스냅숏만 다시 그리면 어떤 편집이든 원상 복귀한다.
// 타이핑은 0.55초 안에 이어지면 한 덩어리로 묶고, 구조가 바뀌는 편집(줄 합치기·삭제·붙여넣기·
// 상태 토글)은 언제나 한 단계다. 덩어리에는 3초 상한이 있다(2026-08-06) — 쉼 없이 이어 친
// 장문이 통째로 한 덩어리가 되어 ⌘Z 한 번에 전부 사라진 사고의 재발 방지. 그리고 프로그램이
// 일으킨 변경(골번호 스탬프·백그라운드 병합)은 '다시 실행' 갈래를 끊지 않는다 — ⌘Z 직후에
// 백그라운드 작업이 끼어들어도 ⌘⇧Z 로 제 글을 되찾는다.
//
// ── 줄 합치기 ────────────────────────────────────────────────────────────────
// 줄 맨 앞의 Backspace(그리고 줄 끝의 Delete)는 언제나 윗줄 '제목' 과 합친다. 갈래를 두지
// 않는 이유: 윗줄에 상세가 달렸을 때 브라우저에 맡기면 WebKit 이 글자를 제목이 아니라 회색
// 상세 칸 끝에 밀어 넣는다. 아랫줄의 상세·칸은 버리지 않고 윗줄로 옮겨 붙인다 — 접혀서 안
// 보이던 글이 조용히 증발하는 것이 이 편집기에서 가장 나쁜 사고다.
//
// Two display forms, driven by the rail's stage machine (SessionRail.swift):
//   기본        — a compact card at the top of the page, ~5 lines tall.
//   body.cmmemo-only (3단계 / 좁은 창) — 문서형: the chrome (border, panel background,
//                 header rules) drops away, the pad centers at 720px and fills the
//                 viewport height. Pure writing surface, nothing else on screen.
// The memo-only layout is applied to the pad's PARENT (given .cmmemo-host at mount) so the
// module stays page-agnostic — it never needs to know the host page's `main` selector.
//
// ── 저장 신뢰 (2026-08-06 강화) ──────────────────────────────────────────────
// Saving: 400ms debounce → POST /api/memo, plus an immediate flush on blur/pagehide/숨김
// so a closing window can't lose the last keystrokes. A failed save is SILENT (no banner —
// 앱 규칙): the text stays on screen, and the next keystroke (or a 3s retry) tries again.
// On top of that, four layers make "적었는데 사라졌다" structurally impossible:
//   판번호(base) — every POST carries the server revision we last saw. A pad that sat
//       stale in another webview can't wipe newer lines: the server refuses, returns the
//       current text, and we UNION-MERGE the two versions and save again. 어느 쪽 글도
//       버리지 않는다.
//   포커스 새로고침 — when the window comes back to front and the pad is idle, we quietly
//       re-fetch. Pads never sit hours-stale, so conflicts are a rare backstop, and 글이
//       화면 사이를 실시간처럼 따라다닌다.
//   로컬 초안 — every edit mirrors the text into localStorage; a save that never reached
//       the server (webview killed mid-debounce, app quit) is recovered on the next load
//       by merging the draft over the server text. 저장 확인 후에만 지운다.
//   저장됨 표시 — a confirmed save shows '저장됨' in the pad meta (next edit clears it).
//       실패를 알리는 배너는 없지만, 성공을 확인해 주는 신호는 있다.
// The server (MemoStore.swift) also journals every buried/refused version into
// memo-history.jsonl — and since 2026-08-06 that journal is USER-FACING: the header's
// 히스토리 menu (GET /api/memo/history) lists past versions newest-first with a full-text
// preview, and restores one either wholesale ('이 판으로 복원') or as a union merge
// ('현재 글과 합치기'). A restore is itself one undo step, so a wrong restore is one ⌘Z away.
enum MemoPad {

    // Public JS API (window.CMMemo): mount(el) · flush() · focus() · text() · setText(s)
    static func html() -> String {
        return #"""
        <style>
          /* Colors come from the host page's variables. Pages use two naming sets
             (--fg/--mut on goal-add, --txt/--dim on the dashboard), so each chain falls back
             through both and finally to a literal — the pad looks native on either. */
          .cmmemo{ display:flex; flex-direction:column; box-sizing:border-box;
            background:var(--panel,#141821); border:1px solid var(--line,#222a36);
            border-radius:14px; padding:12px 14px; margin-bottom:14px }
          .cmmemo-hd{ display:flex; flex-wrap:wrap; align-items:baseline; gap:8px; margin-bottom:7px }
          .cmmemo-hd .sp{ flex:1 }
          .cmmemo-hd .meta{ font-size:11px; color:var(--mut,var(--dim,#8a93a3)); white-space:nowrap }
          /* 확장 토글 — 기본 3줄, 펼치면 10줄. 무한정 늘리지 않는다(카드가 화면을 삼키지 않도록). */
          .cmmemo-hd .exp, .cmmemo-hd .cmm-add{ appearance:none; cursor:pointer; white-space:nowrap; flex:0 0 auto;
            border:1px solid var(--line,#222a36); background:transparent;
            color:var(--mut,var(--dim,#8a93a3)); border-radius:7px; padding:2px 8px;
            font-size:11px; line-height:1.6; font-family:inherit }
          .cmmemo-hd .exp:hover, .cmmemo-hd .cmm-add:hover{ color:var(--fg,var(--txt,#e6e9ef));
            border-color:var(--accent,#5b8cff) }

          /* 힌트 줄 — 기능을 눈에 보이게 하는 유일한 장치. 좁은 카드에서는 접는다(자리가 없다). */
          .cmmemo .cmm-hint{ display:none; margin-top:9px; font-size:11px; line-height:1.9;
            color:var(--mut,var(--dim,#8a93a3)) }
          .cmmemo .cmm-hint b{ color:#b9c2d0; font-weight:600 }
          .cmmemo .cmm-hint kbd{ font:inherit; font-size:10.5px; border:1px solid var(--line,#222a36);
            border-radius:4px; padding:1px 5px; color:#c9d2e0;
            background:rgba(255,255,255,.03); white-space:nowrap }

          /* 편집면 — 행 하나가 곧 메모 한 줄. textarea 와 같은 크기 규칙을 그대로 쓴다. */
          /* 카드형(2단·3단)에서는 높이가 고정이다 — 내용이 늘어도 카드는 그대로 두고 안에서 스크롤한다.
             (메모가 자라면서 같은 화면의 다른 UI 를 밀어내는 일이 없도록.) */
          .cmmemo .cmm-doc{ box-sizing:border-box; width:100%; min-height:92px; max-height:92px; overflow:auto;
            border:1px solid transparent; border-radius:10px; background:#0e1320;
            color:var(--fg,var(--txt,#e6e9ef)); font:14px/1.75 -apple-system,BlinkMacSystemFont,
            "Apple SD Gothic Neo",sans-serif; padding:8px 10px }
          .cmmemo .cmm-doc:focus-within{ border-color:var(--accent,#5b8cff) }
          /* 드래그 선택·IME 조합이 WebKit 기본(밝은 바탕)으로 칠해지면 어두운 판에서
             글자가 하얗게 지워져 보인다 — 선택 배경을 앱 색으로 못 박는다. */
          .cmmemo .cmm-doc ::selection, .cmmemo .cmm-doc::selection{
            background:rgba(91,140,255,.35) }
          /* 10줄 = 10 × 24.5px(line-height 1.75) + 상하 패딩 20px */
          body.cmmemo-exp .cmmemo .cmm-doc{ min-height:265px; max-height:265px }
          /* 행은 반드시 블록 — 한 줄이 한 행이고 다음 줄은 아래로 간다.
             클래스 이름을 cmm- 로 못 박고 display 도 직접 적는 이유: 이 카드가 얹히는 페이지들이
             저마다 .row{display:flex} 같은 전역 규칙을 갖고 있어서, 이름이 겹치면 행이 옆으로 흐른다. */
          .cmmemo .cmm-row{ display:block; margin:0; padding:1px 0 }
          .cmmemo .cmm-ln{ display:flex; align-items:flex-start; gap:9px; margin:0 }
          /* 제목은 반드시 한 줄 — 넘치면 말줄임(…). 잘린 글은 편집(포커스) 중일 때만 아래로
             펼쳐진다. 마우스만 올렸을 때는 행을 부풀리지 않고 마우스 옆 툴팁(.cmmemo-tip)으로
             전문을 띄운다(2026-08-09 — hover 마다 행이 두세 줄로 출렁이면 목록의 줄 감각이
             흐트러진다는 피드백). min-width:0 은 flex 자식이 내용 폭만큼 버티며 말줄임을
             무시하는 것을 막는다. */
          .cmmemo .cmm-tx{ flex:1; min-width:0; outline:none; white-space:nowrap; overflow:hidden;
            text-overflow:ellipsis; word-break:break-word;
            min-height:24px; padding:1px 2px; border-radius:5px }
          .cmmemo .cmm-tx:focus{
            white-space:pre-wrap; overflow:visible; text-overflow:clip }
          .cmmemo .cmm-tx:empty::before{ content:attr(data-ph);
            color:var(--mut,var(--dim,#8a93a3)); opacity:.6 }

          /* ── 라운드 박스 ──────────────────────────────────────────────────
             기본은 빈 원. 호버하면 원 안이 일련번호로 바뀐다 — 번호는 데이터에만 있고
             평소 화면에는 없다가 필요할 때만 드러난다. */
          .cmmemo .cmm-ck{ position:relative; flex:0 0 auto; width:19px; height:19px; margin-top:3px;
            border-radius:50%; border:1.5px solid #3a4557; background:transparent; color:transparent;
            cursor:pointer; padding:0; display:grid; place-items:center;
            transition:border-color .12s, background .12s }
          .cmmemo .cmm-ck:hover{ border-color:var(--accent,#5b8cff) }
          /* 평문 줄에도 원은 늘 앞에 있다(2026-08-04) — 목록의 왼쪽 정렬이 줄마다 어긋나지
             않도록. 다만 흐리게 둬서 '아직 체크리스트가 아니다' 를 눈으로 구분하고,
             그 원을 누르면 바로 체크리스트가 된다. */
          .cmmemo .cmm-row:not([data-st]) .cmm-ck{ opacity:.3 }
          .cmmemo .cmm-row:not([data-st]) .cmm-ck:hover{ opacity:1 }
          .cmmemo .cmm-ck .cmm-mk{ font-size:12px; line-height:1 }
          /* 골번호는 서너 자리(#598)까지 온다 — 원을 벗어나면 알약으로 늘어난다. */
          .cmmemo .cmm-ck .cmm-no{ position:absolute; top:0; bottom:0; left:50%;
            transform:translateX(-50%); min-width:19px; width:max-content; padding:0 4px;
            box-sizing:border-box; display:none; place-items:center; z-index:1;
            font-size:10px; font-weight:700; letter-spacing:-.3px;
            color:var(--fg,var(--txt,#e6e9ef)); background:#0e1320; border-radius:10px }
          .cmmemo .cmm-ck:hover .cmm-no{ display:grid }         /* 호버 = 번호 노출 */
          .cmmemo .cmm-ck:hover .cmm-mk{ visibility:hidden }
          /* 번호가 아직 없는 줄(채번 전 평문)은 호버해도 빈 알약을 띄우지 않는다. */
          .cmmemo .cmm-ck:hover .cmm-no:empty{ display:none }
          .cmmemo .cmm-row[data-st="done"] .cmm-ck{ border-color:var(--accent,#5b8cff);
            background:rgba(91,140,255,.16); color:var(--accent,#5b8cff) }
          .cmmemo .cmm-row[data-st="done"] .cmm-tx{ color:var(--mut,var(--dim,#8a93a3));
            text-decoration:line-through; text-decoration-color:#4c566b }
          /* 바틀넥 = 막힘. 상태 표시에 빨강/녹색은 쓰지 않는다(앱 규칙) — 호박색. */
          .cmmemo .cmm-row[data-st="block"] .cmm-ck{ border-color:#e2a03f;
            background:rgba(226,160,63,.16); color:#e2a03f }
          .cmmemo .cmm-row[data-st="block"] .cmm-tx{ color:#f0cd97 }

          /* ── 상세(⌘Enter) ────────────────────────────────────────────────
             긴 글은 여기로 내려간다. 접혀 있을 때 목록에는 한 줄 제목만 남는다.
             접힘 표시는 제목 오른쪽의 작은 알약 — 상세가 있다는 사실만 조용히 알린다. */
          .cmmemo .cmm-cue{ flex:0 0 auto; margin-top:4px; font-size:10px; line-height:1.5;
            color:var(--mut,var(--dim,#8a93a3)); border:1px solid var(--line,#222a36);
            border-radius:20px; padding:0 7px; cursor:pointer; white-space:nowrap;
            user-select:none; visibility:hidden }
          .cmmemo .cmm-row[data-has="1"] .cmm-cue{ visibility:visible }
          .cmmemo .cmm-cue:hover{ color:var(--fg,var(--txt,#e6e9ef)); border-color:var(--accent,#5b8cff) }
          .cmmemo .cmm-row[data-open="1"] .cmm-cue{ color:var(--accent,#5b8cff); border-color:var(--accent,#5b8cff) }
          /* 하위 줄은 '작은 딸림 글' 이지 카드가 아니다(2026-08-04) — 배경·테두리 없이
             제목 밑에 얌전히 들여쓴 몇 줄. 줄마다 상자가 생기면 목록이 부풀어 원래 목적
             (제목 한 줄로 훑기)이 무너진다. */
          .cmmemo .cmm-dt{ display:none; margin:0 0 2px 28px; padding:0;
            color:#a8b1c0; font-size:12.5px; line-height:1.65;
            white-space:pre-wrap; word-break:break-word; outline:none }
          .cmmemo .cmm-row[data-open="1"] .cmm-dt{ display:block }
          /* WebKit 의 contenteditable 은 줄을 나눌 때 <div>/<br> 를 끼워 넣는다. 그 자식들이
             부모의 여백·배경을 다시 받아 한 줄이 한 칸처럼 부푸는 것을 여기서 막는다. */
          .cmmemo .cmm-dt div, .cmmemo .cmm-dt p{ display:block; margin:0; padding:0;
            background:none; border:0; border-radius:0; font:inherit; color:inherit }
          .cmmemo .cmm-dt:focus{ color:#c3cbd8 }
          /* 안내문이 너무 흐려 "칸이 있는지도 모르겠다" 는 피드백(2026-08-06) — 본문보다는
             흐리되 읽히는 농도까지만 낮춘다(아래 ::after 판도 같은 값). */
          .cmmemo .cmm-dt:empty::before{ content:'상세 내용 — Esc 로 접기';
            color:var(--mut,var(--dim,#8a93a3)); opacity:.8 }

          /* ── 필드(⌘⇧Enter) ───────────────────────────────────────────────
             목표일·담당·팀·프로젝트처럼 리포트에서 되묻게 되는 값들. 자유 문장으로 적으면
             나중에 모아 볼 수 없으니 칸으로 받는다. 평소에는 접혀 있고 저장은 상세와 같은
             들여쓴 줄(@키: 값)이라 텍스트로 열어도 읽힌다. */
          .cmmemo .cmm-fs{ display:none; margin:3px 0 6px 28px; padding:8px 10px;
            border-left:2px solid #2b3444; border-radius:0 8px 8px 0;
            background:rgba(91,140,255,.05);
            grid-template-columns:repeat(auto-fit,minmax(176px,1fr)); gap:7px 10px }
          .cmmemo .cmm-row[data-fs="1"] .cmm-fs{ display:grid }
          .cmmemo .cmm-fs label{ display:flex; flex-direction:column; gap:3px;
            font-size:10.5px; color:var(--mut,var(--dim,#8a93a3)) }
          /* 시각 칸의 타임존 꼬리표 — 지금 보고 있는 시계가 무엇인지 이름 옆에 조용히. */
          .cmmemo .cmm-fs .cmm-tz{ font-style:normal; margin-left:5px; opacity:.75 }
          /* 부모 칸 꼬리표 — 적은 골번호가 가리키는 제목(메모 줄 또는 보드 골)을 이름 옆에
             보여 준다. 못 찾으면 '번호 확인' — 배너 없이 조용히. */
          .cmmemo .cmm-fs .cmm-pk{ font-style:normal; margin-left:5px; opacity:.75 }
          /* 날짜+시간은 다른 칸보다 글자가 길다 — 조금 줄여야 'AM' 이 잘리지 않는다. */
          .cmmemo .cmm-fs input[data-tz]{ font-size:12px; padding-left:5px; padding-right:5px }
          .cmmemo .cmm-fs input{ appearance:none; box-sizing:border-box; width:100%;
            border:1px solid var(--line,#222a36); border-radius:6px; background:#0e1320;
            color:var(--fg,var(--txt,#e6e9ef)); font:13px/1.5 inherit; padding:4px 7px;
            color-scheme:dark }
          .cmmemo .cmm-fs input:focus{ outline:none; border-color:var(--accent,#5b8cff) }
          /* 번호 칸(2026-08-08) — 칸 패널 맨 앞의 표찰. 편집 칸이 아니라 이 줄의 골번호를
             보여만 준다(번호는 불변·재사용 없음). 점선 테두리가 '적는 칸이 아니다' 를 알린다.
             채번 전에는 조용히 '—' 만(배너 없음 — 앱 규칙). */
          .cmmemo .cmm-fs .cmm-gno{ box-sizing:border-box; width:100%; min-height:29px;
            display:flex; align-items:center; padding:4px 7px;
            border:1px dashed var(--line,#222a36); border-radius:6px;
            color:var(--fg,var(--txt,#e6e9ef)); font-size:13px; line-height:1.5;
            font-weight:700; letter-spacing:-.2px }
          /* 태그 칸(담당·팀·프로젝트)은 사전에서 고르는 칸이라는 걸 눈으로 알린다. */
          .cmmemo .cmm-fs input[data-tag]{ padding-right:22px }
          .cmmemo .cmm-fs label[data-tag]{ position:relative }
          .cmmemo .cmm-fs label[data-tag]::after{ content:'▾'; position:absolute; right:7px; bottom:5px;
            font-size:10px; line-height:1.5; color:var(--mut,var(--dim,#8a93a3)); pointer-events:none }

          /* ── 칸 + 상세 = 한 패널 (2026-08-06) ────────────────────────────
             칸이 열린 채 상세도 열리면, 상세가 패널 밑에 맨몸 회색 글로 따로 떠서 폼과
             깨져 보였다. 상세를 패널의 마지막 칸('내용')처럼 이어 붙인다 — 같은 왼쪽 선,
             같은 바탕, 위에는 다른 칸과 같은 꼴의 이름표. DOM 은 그대로다(상세는 여전히
             편집면의 .cmm-dt 한 블록) — 눈에만 한 폼으로 보이게 CSS 로 잇는다. */
          .cmmemo .cmm-row[data-fs="1"][data-open="1"] .cmm-fs{
            margin-bottom:0; border-radius:0 8px 0 0; padding-bottom:5px }
          .cmmemo .cmm-row[data-fs="1"][data-open="1"] .cmm-dt{
            margin:0 0 6px 28px; padding:0 10px 8px;
            border-left:2px solid #2b3444; border-radius:0 0 8px 0;
            background:rgba(91,140,255,.05) }
          .cmmemo .cmm-row[data-fs="1"][data-open="1"] .cmm-dt::before{
            content:'내용'; display:block; font-size:10.5px; line-height:1.5;
            color:var(--mut,var(--dim,#8a93a3)); margin:0 0 3px; opacity:1 }
          /* 위의 이름표가 ::before 를 차지하므로, 빈 상세의 안내문은 이 상태에서만
             ::after 로 옮긴다(:empty 는 실제 자식만 보니 pseudo 와 충돌하지 않는다). */
          .cmmemo .cmm-row[data-fs="1"][data-open="1"] .cmm-dt:empty::after{
            content:'상세 내용 — Esc 로 접기';
            color:var(--mut,var(--dim,#8a93a3)); opacity:.8 }

          /* ── 태그 후보 ────────────────────────────────────────────────────
             같은 사람·팀·프로젝트가 철자만 다르게 여러 벌 쌓이지 않도록, 몇 글자 치면
             이미 쓰던 이름이 떠오른다(슬랙에서 사람을 부를 때처럼). 없을 때만 만들기.
             메뉴와 같은 이유로 body 바로 아래 fixed — 편집면의 overflow 에 잘리지 않는다. */
          .cmmemo-sug{ position:fixed; z-index:10000; min-width:190px; max-width:320px; padding:5px;
            display:flex; flex-direction:column; max-height:236px; overflow:auto;
            background:var(--card,#171a21); border:1px solid var(--line,#2a2f3a); border-radius:10px;
            box-shadow:0 10px 28px rgba(0,0,0,.45) }
          .cmmemo-sug .cmm-sh{ padding:4px 9px 5px; font-size:10.5px;
            color:var(--mut,var(--dim,#8a93a3)) }
          .cmmemo-sug button{ appearance:none; text-align:left; cursor:pointer;
            display:flex; align-items:center; gap:8px;
            padding:6px 9px; border:0; border-radius:7px; background:transparent;
            color:var(--fg,var(--txt,#e6e9ef)); font-size:12.5px; font-family:inherit }
          .cmmemo-sug button b{ flex:1; font-weight:400; overflow:hidden; text-overflow:ellipsis;
            white-space:nowrap }
          .cmmemo-sug button em{ flex:0 0 auto; font-style:normal; font-size:10.5px;
            color:var(--mut,var(--dim,#8a93a3)) }
          .cmmemo-sug button:hover, .cmmemo-sug button[data-on="1"]{ background:var(--hov,rgba(255,255,255,.07)) }
          /* 만들기는 목록과 성격이 다르다(사전을 늘린다) — 선을 그어 떼어 놓는다. */
          .cmmemo-sug .cmm-sd{ height:1px; margin:4px 8px; background:var(--line,#2a2f3a) }
          .cmmemo-sug button.cmm-snew{ color:var(--accent,#5b8cff) }

          /* ── 보기 필터 ────────────────────────────────────────────────────
             처리에 집중할 때는 완료한 줄이 안 보이는 게 낫고(기본), 리포트를 쓸 때는
             무엇을 했는지 봐야 한다. 그 전환을 헤더의 다중 선택 콤보 하나로 한다. */
          .cmmemo .cmm-row[data-st="done"]{ display:block }
          .cmmemo[data-hide~="done"] .cmm-row[data-st="done"],
          .cmmemo[data-hide~="block"] .cmm-row[data-st="block"],
          .cmmemo[data-hide~="todo"] .cmm-row[data-st="todo"]{ display:none }
          .cmmemo-hd .cmm-view{ appearance:none; cursor:pointer; white-space:nowrap; flex:0 0 auto;
            display:inline-flex; align-items:center; gap:6px;
            border:1px solid var(--line,#222a36); background:transparent;
            color:var(--mut,var(--dim,#8a93a3)); border-radius:7px; padding:2px 8px;
            font-size:11px; line-height:1.6; font-family:inherit }
          .cmmemo-hd .cmm-view:hover, .cmmemo-hd .cmm-view[aria-expanded="true"]{
            color:var(--fg,var(--txt,#e6e9ef)); border-color:var(--accent,#5b8cff) }
          .cmmemo-hd .cmm-view i{ font-style:normal; font-size:10px; font-weight:700;
            min-width:15px; text-align:center; border-radius:5px; padding:0 3px;
            background:rgba(91,140,255,.16); color:var(--accent,#5b8cff) }
          /* '보기' 버튼의 날짜 범위 표찰 — 기본(오늘만)이 곧 감춤이라, 무엇이 감춰져
             있는지는 메뉴를 열지 않고도 버튼에 적혀 있어야 한다. */
          .cmmemo-hd .cmm-view b{ font-weight:600; font-size:10.5px;
            color:var(--mut,var(--dim,#8a93a3)) }
          /* ── 필드 필터 ────────────────────────────────────────────────────
             보기(상태)와 별개로 담당·팀·프로젝트·목표일 '값' 으로 줄을 거른다 —
             "ismail 이 맡은 것만", "이 프로젝트만", "오늘까지인 것만".
             안 걸려 있을 때는 숫자 칩을 감춘다(평소 헤더는 조용하게). */
          .cmmemo-hd .cmm-flt:not([data-on]) i{ display:none }
          .cmmemo-hd .cmm-flt[data-on]{ color:var(--fg,var(--txt,#e6e9ef));
            border-color:var(--accent,#5b8cff) }
          /* 걸러진 줄은 보기 필터와 같은 원칙 — CSS 로만 감춘다. 텍스트도 번호도 그대로다. */
          .cmmemo .cmm-row[data-fx]{ display:none }
          /* ── 루프 ────────────────────────────────────────────────────────
             이전 루프에 묻힌 완료 줄(@루프 스탬프, data-lp)은 기본에서 감춘다 — 지난
             사이클에 끝낸 일은 오늘의 처리 목록이 아니다. '이전 루프 포함' 을 켠 패드
             (data-loops="all")에서만 다시 보이고, 이때는 완료 체크 해제보다 우선한다
             (상태와 다른 축 — 묻힌 완료는 '완료' 가 아니라 '이전 루프' 로 본다).
             필드 필터(data-fx)는 이전 루프에도 그대로 걸린다. 감춤은 늘 CSS 만 —
             텍스트도 골번호도 그대로다. */
          .cmmemo .cmm-row[data-lp]{ display:none }
          .cmmemo[data-loops="all"] .cmm-row[data-lp]{ display:block }
          .cmmemo[data-loops="all"] .cmm-row[data-lp][data-fx]{ display:none }
          /* ── 생성 날짜 ────────────────────────────────────────────────────
             기본은 '오늘 만든 줄만'(2026-08-10). 아침에 패드를 열었을 때 어제·엊그제·
             그 전 줄까지 한꺼번에 눈에 들어오면, 오늘 머릿속에 있는 것을 꺼내 적기 전에
             지난 것을 정리하느라 시간을 다 쓴다. 그 정리는 사람이 손으로 할 일이 아니라
             골(목표) 기반으로 팀별 정리거리를 적립해 두고 AI 에이전트가 훑을 일이다.
             지난 줄은 '보기 > 생성 날짜' 에서 넓혀 본다. 루프(위)와 다른 축이다 —
             루프는 '완료를 언제 묻었나', 여기는 '이 줄을 언제 만들었나'.
             하루의 경계는 자정이 아니라 새벽 4시다(DAYCUT) — 밤샘 작업 중 자정이 지났다고
             30분 전에 적은 줄이 사라지면 안 된다.
             감춤은 늘 CSS 만(data-cx) — 텍스트도 골번호도 그대로다. */
          .cmmemo .cmm-row[data-cx]{ display:none }
          .cmmemo[data-loops="all"] .cmm-row[data-lp][data-cx]{ display:none }
          /* '왜 이 메뉴가 있는가' — data-why 가 달린 자리에 마우스를 올리면 까닭이 뜬다
             (.cmmemo-tip 과 같은 창). 콤보의 소제목은 점선 밑줄로 눌러 볼 곳임을 알린다. */
          .cmmemo-hd .cmm-view[data-why], .cmmemo-menu [data-why]{ cursor:help }
          .cmmemo-menu .cmm-vt[data-why]{ text-decoration:underline dotted;
            text-underline-offset:3px }
          .cmmemo-menu.cmm-vm{ min-width:206px }
          .cmmemo-menu .cmm-vt{ padding:5px 10px 4px; font-size:10.5px;
            color:var(--mut,var(--dim,#8a93a3)) }
          .cmmemo-menu .cmm-vd{ height:1px; margin:4px 8px; background:var(--line,#2a2f3a) }
          .cmmemo-menu button.cmm-vo{ display:flex; align-items:center; gap:8px; font-weight:400 }
          .cmmemo-menu button.cmm-vo u{ flex:0 0 auto; width:14px; height:14px; text-decoration:none;
            border:1.5px solid #3a4557; border-radius:4px; display:grid; place-items:center;
            font-size:10px; line-height:1; color:transparent }
          .cmmemo-menu button.cmm-vo[aria-checked="true"] u{ border-color:var(--accent,#5b8cff);
            background:var(--accent,#5b8cff); color:#0b0e15 }
          .cmmemo-menu button.cmm-vo b{ flex:1; font-weight:400; text-align:left }
          .cmmemo-menu button.cmm-vo em{ font-style:normal; font-size:11px;
            color:var(--mut,var(--dim,#8a93a3)) }

          /* ── 히스토리 ─────────────────────────────────────────────────────
             서버가 저널해 둔 지난 판(memo-history.jsonl)을 최신순으로 보여 주고, 고른 판을
             미리 본 뒤 복원한다. "장문을 썼는데 ⌘Z 하다가 다 사라졌다" 의 마지막 구조선 —
             무엇이 지워졌든 여기서 눈으로 찾아 되살린다. */
          .cmmemo-menu.cmm-hm{ min-width:300px; max-width:min(420px, calc(100vw - 24px)) }
          .cmmemo-menu .cmm-hl{ max-height:238px; overflow:auto; display:flex; flex-direction:column }
          .cmmemo-menu button.cmm-ho{ display:flex; align-items:baseline; gap:8px; font-weight:400 }
          .cmmemo-menu button.cmm-ho u{ flex:0 0 auto; min-width:58px; text-decoration:none;
            font-size:11px; color:var(--mut,var(--dim,#8a93a3)) }
          .cmmemo-menu button.cmm-ho b{ flex:1; font-weight:400; text-align:left; min-width:0;
            overflow:hidden; text-overflow:ellipsis; white-space:nowrap }
          .cmmemo-menu button.cmm-ho em{ flex:0 0 auto; font-style:normal; font-size:11px;
            color:var(--mut,var(--dim,#8a93a3)) }
          .cmmemo-menu button.cmm-ho[aria-checked="true"]{ background:var(--hov,rgba(255,255,255,.07)) }
          .cmmemo-menu .cmm-hp{ border-top:1px solid var(--line,#2a2f3a); margin-top:5px; padding-top:6px }
          .cmmemo-menu .cmm-hp pre{ max-height:176px; overflow:auto; margin:0 0 6px; padding:7px 9px;
            background:#0e1320; border-radius:8px; white-space:pre-wrap; word-break:break-word;
            color:var(--fg,var(--txt,#e6e9ef)); font:12px/1.65 -apple-system,BlinkMacSystemFont,
            "Apple SD Gothic Neo",sans-serif }
          .cmmemo-menu .cmm-ha{ display:flex; gap:6px; justify-content:flex-end }

          /* ── 정렬 ─────────────────────────────────────────────────────────
             처리 관점의 정렬 — 지금 할 것(미완료)이 맨 위, 진행이 막혀 나중에 볼 바틀넥은
             완료 바로 위, 끝낸 것은 맨 아래로 가라앉는다. 기본은 입력 순서.
             보기 필터와 같은 원칙으로 CSS(order)만 건드린다 — 저장 텍스트의 줄 순서도,
             원 안의 일련번호(텍스트 순서)도 그대로다. 정렬을 풀면 즉시 원래 자리다. */
          .cmmemo[data-sort="st"] .cmm-doc{ display:flex; flex-direction:column }
          .cmmemo[data-sort="st"] .cmm-row{ order:0 }
          .cmmemo[data-sort="st"] .cmm-row[data-st="block"]{ order:1 }
          .cmmemo[data-sort="st"] .cmm-row[data-st="done"]{ order:2 }
          /* 구조: 부모 기반 — '@부모: 골번호' 를 따라 자식이 부모 바로 아래로 모이고
             한 단씩 들여쓴다(UI 콤보의 구조 섹션). 순서(order)는 treePaint 가 행마다
             인라인으로 계산해 붙인다 — 역시 표시만 바꾼다. 저장 텍스트·골번호는 그대로다. */
          .cmmemo[data-grp="tree"] .cmm-doc{ display:flex; flex-direction:column }
          .cmmemo[data-grp="tree"] .cmm-row[data-tdep="1"]{ margin-left:24px }
          .cmmemo[data-grp="tree"] .cmm-row[data-tdep="2"]{ margin-left:48px }
          .cmmemo[data-grp="tree"] .cmm-row[data-tdep="3"]{ margin-left:72px }

          /* ── UI 모드: 집중 ────────────────────────────────────────────────
             화면을 남과 같이 볼 때(공유·발표)는 목록 전체보다 '지금 이 줄' 이 잘 보이는
             게 우선이다. 집중 모드는 캐럿이 있는(또는 마우스를 올린) 줄만 온전한 색으로
             남기고 나머지를 회색으로 가라앉히며, 글자를 한 단계 키운다. 정렬·보기와 같은
             원칙 — CSS 만 바꾼다. 저장 텍스트·번호·⌘Z 히스토리는 그대로다. */
          .cmmemo[data-ui="focus"] .cmm-doc{ font-size:16px }
          /* 문서형(3단계)은 기본이 이미 15px 이고 선택자 특이도도 높다 — 거기서도
             '한 단계 크게' 가 지켜지도록 문서형 판을 따로 둔다. */
          body.cmmemo-only .cmmemo[data-ui="focus"] .cmm-doc{ font-size:17px }
          .cmmemo[data-ui="focus"] .cmm-dt{ font-size:14px }
          .cmmemo[data-ui="focus"] .cmm-row{ transition:opacity .15s, filter .15s;
            border-radius:8px }
          .cmmemo[data-ui="focus"] .cmm-row:not(:focus-within):not(:hover){
            filter:grayscale(1); opacity:.4 }
          /* 쓰고 있는 줄 — 은은한 앱색 바탕으로 '여기' 를 짚어 주고, 상세도 밝게. */
          .cmmemo[data-ui="focus"] .cmm-row:focus-within{
            background:rgba(91,140,255,.10) }
          .cmmemo[data-ui="focus"] .cmm-row:focus-within .cmm-dt{ color:#c3cbd8 }

          /* ── UI 모드: 초집중 (2026-08-13 구조 교체) ───────────────────────
             프라이버시 — 옆에 누가 있어도 다른 메모가 보이면 안 될 때.
             예전에는 행 편집기를 그대로 두고 '지금 줄' 하나만 CSS 로 남겼다. 그런데
             그 화면에도 원·제목·접힌 상세·칸이 그대로 있어서 "적었는데 사라졌다"
             가 되풀이됐다 — 접힌 상세는 화면에 없는 글이고, 화면에 없는 글은 언제든
             구조가 삼킬 수 있다. 그래서 초집중에서는 편집면 자체를 바꾼다:
             지금 덩어리 하나만 담는 순수 textarea. 원도, 제목/상세 구분도, 칸도
             없다 — 보이는 글자가 곧 저장되는 글자다. 지울 구조가 없으니 구조 때문에
             지워질 일도 없다. 칸·골번호·상태는 행에 그대로 남아 기본 모드에서 다시 보인다.
             (기본·집중 모드의 행 편집기는 하나도 바뀌지 않는다.) */
          .cmmemo[data-ui="ultra"] .cmm-doc,
          .cmmemo[data-ui="ultra"] .cmm-hint,
          /* 문서형·확장은 힌트 줄을 펴는 규칙(아래 문서형 절)이 따로 있어 특이도가 높다 —
             초집중에서는 그 판까지 눌러 둔다. 행 편집기 단축키는 여기서 쓸 일이 없다. */
          body.cmmemo-only .cmmemo[data-ui="ultra"] .cmm-hint,
          body.cmmemo-exp .cmmemo[data-ui="ultra"] .cmm-hint{ display:none }
          .cmmemo .cmm-ua{ display:none }
          .cmmemo[data-ui="ultra"] .cmm-ua{ display:block; box-sizing:border-box; width:100%;
            resize:none; min-height:92px; max-height:92px; overflow:auto;
            border:1px solid transparent; border-radius:10px; background:#0e1320;
            /* 글자·줄 간격은 macOS 메모(Notes) 본문에 맞춘다(2026-08-16) — 16px/1.75 는
               한 줄이 28px 라 같은 화면에 담기는 글이 메모의 절반이었다. 13px/1.2(=15.6px)
               로 내리면 옆에 메모를 띄워 놓고 봐도 크기가 어긋나지 않는다. */
            color:var(--fg,var(--txt,#e6e9ef)); font:13px/1.2 -apple-system,BlinkMacSystemFont,
            "Apple SD Gothic Neo",sans-serif; padding:8px 10px; outline:none;
            /* 폼 컨트롤이라 스크롤바가 OS 기본(밝은 바탕)으로 그려진다 — 어두운 판에
               흰 막대가 서지 않도록 어두운 배색을 지정한다. */
            color-scheme:dark }
          .cmmemo[data-ui="ultra"] .cmm-ua:focus{ border-color:var(--accent,#5b8cff) }
          .cmmemo[data-ui="ultra"] .cmm-ua::placeholder{ color:var(--mut,var(--dim,#8a93a3)); opacity:.6 }
          .cmmemo[data-ui="ultra"] .cmm-ua::selection{ background:rgba(91,140,255,.35) }
          body.cmmemo-exp .cmmemo[data-ui="ultra"] .cmm-ua{ min-height:265px; max-height:265px }
          /* 문서형(1단계)에서는 남은 높이를 전부 쓴다 — 화면에 이 글 하나뿐이다. */
          body.cmmemo-only .cmmemo[data-ui="ultra"] .cmm-ua{ flex:1; height:auto;
            min-height:0; max-height:none; background:transparent; border-color:transparent;
            /* 문서형도 메모(Notes) 본문 크기 그대로 — 화면이 넓다고 글자를 키우면
               같은 글이 옆 메모보다 두 배로 부풀어 보인다(위 절과 같은 값). */
            font-size:13px; line-height:1.2; padding:8px 2px }

          /* ── 링크 태그 ────────────────────────────────────────────────────
             링크 칸은 지라·노션·슬랙 세 칸으로 나뉘어 있다(PM 에이전트가 주기적으로
             각 칸을 채우고 추적한다). 칩은 값이 있는 칸마다 하나씩 제목 줄에 붙고
             누르면 바로 그 링크로 간다(앱 웹뷰에서는 기본 브라우저로 넘어간다). */
          .cmmemo .cmm-lk{ display:none; flex:0 0 auto; margin-top:4px; font-size:10px;
            line-height:1.5; border:1px solid var(--line,#222a36); border-radius:20px;
            padding:0 7px; cursor:pointer; white-space:nowrap; user-select:none;
            text-decoration:none; color:var(--mut,var(--dim,#8a93a3)) }
          .cmmemo .cmm-lk[data-u]{ display:inline-block }
          .cmmemo .cmm-lk:hover{ color:var(--fg,var(--txt,#e6e9ef)); border-color:var(--accent,#5b8cff) }
          /* 종류별 낯빛 — 상태 신호등(빨강/녹색)이 아니라 서비스의 낯빛이다. */
          .cmmemo .cmm-lk[data-lk="slack"]{ color:#c39ede; border-color:rgba(195,158,222,.4) }
          .cmmemo .cmm-lk[data-lk="jira"]{ color:#7fa6e8; border-color:rgba(127,166,232,.4) }
          .cmmemo .cmm-lk[data-lk="notion"]{ color:#cfd6e2; border-color:rgba(207,214,226,.4) }
          /* URL 은 길다 — 링크 칸은 한 줄을 통째로 쓴다. */
          .cmmemo .cmm-fs label[data-link]{ grid-column:1/-1 }
          .cmmemo .cmm-fs .cmm-lkk{ font-style:normal; margin-left:5px; opacity:.85 }

          /* ── 3단계 / 좁은 창: 문서형 ── 테두리·배경을 걷어내고 폭 720px 중앙, 남은 높이 전부.
             호스트(부모)에 .cmmemo-host 가 붙어 있어 페이지의 main 선택자를 몰라도 된다. */
          body.cmmemo-only .cmmemo-host{ box-sizing:border-box; display:flex; flex-direction:column;
            min-height:100vh; max-width:720px; width:100%; margin:0 auto; padding:30px 22px 26px }
          body.cmmemo-only .cmmemo{ flex:1; min-height:0; margin:0; padding:0;
            background:transparent; border-color:transparent }
          body.cmmemo-only .cmmemo-hd{ margin-bottom:12px }
          /* 문서형은 이미 화면 전체를 쓰므로 확장 토글이 의미가 없다. */
          body.cmmemo-only .cmmemo-hd .exp{ display:none }
          body.cmmemo-only .cmmemo .cmm-doc{ flex:1; height:auto; min-height:0; max-height:none;
            background:transparent; border-color:transparent; font-size:15px; line-height:1.85;
            padding:8px 2px }
          /* 문서형·확장 카드에서는 프로토타입의 여유 있는 행 리듬을 그대로 쓴다. */
          body.cmmemo-only .cmmemo .cmm-tx, body.cmmemo-exp .cmmemo .cmm-tx{ min-height:24px }
          body.cmmemo-only .cmmemo .cmm-row, body.cmmemo-exp .cmmemo .cmm-row{ padding:1px 0 }
          body.cmmemo-only .cmmemo .cmm-hint, body.cmmemo-exp .cmmemo .cmm-hint{ display:block }
          body.cmmemo-only .cmmemo .cmm-hint{ margin-top:14px }

          /* 우클릭 내보내기 메뉴 — body 바로 아래에 붙어 어느 페이지에 얹혀도 잘리지 않는다. */
          .cmmemo-menu{ position:fixed; z-index:9999; min-width:186px; padding:5px;
            display:flex; flex-direction:column;
            background:var(--card,#171a21); border:1px solid var(--line,#2a2f3a); border-radius:10px;
            box-shadow:0 10px 28px rgba(0,0,0,.45) }
          .cmmemo-menu button{ appearance:none; text-align:left; cursor:pointer;
            padding:7px 10px; border:0; border-radius:7px; background:transparent;
            color:var(--fg,var(--txt,#e6e9ef)); font-size:12.5px; font-family:inherit }
          .cmmemo-menu button:hover{ background:var(--hov,rgba(255,255,255,.07)) }
          /* 기본 동작(내용 그대로 복사)임을 눈으로 알 수 있게. */
          .cmmemo-menu button[data-prime]{ font-weight:600 }
          /* 같은 상태의 이웃이 없어 막힌 방향 — 항목은 남겨 두되 눌리지 않음을 낯빛으로. */
          .cmmemo-menu button:disabled{ opacity:.35; cursor:default }
          .cmmemo-menu button:disabled:hover{ background:transparent }

          /* 잘린 제목의 전문 툴팁 — 마우스 옆에 뜨는 작은 창. 행 자체는 절대 안 커진다.
             pointer-events:none — 창이 마우스를 가로채 hover 가 깜빡이는 것을 막는다. */
          .cmmemo-tip{ position:fixed; z-index:10000; max-width:min(420px, calc(100vw - 24px));
            padding:7px 10px; background:var(--card,#171a21);
            border:1px solid var(--line,#2a2f3a); border-radius:9px;
            box-shadow:0 10px 28px rgba(0,0,0,.45);
            color:var(--fg,var(--txt,#e6e9ef));
            /* body 밑에 붙는 창이라 호스트 글꼴을 못 믿는다 — 패드 본문과 같은 글꼴로 명시. */
            font:12.5px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;
            white-space:pre-wrap; word-break:break-word; pointer-events:none }
        </style>
        <section class="cmmemo" data-cmmemo>
          <div class="cmmemo-hd">
            <span class="sp"></span>
            <span class="meta" data-cmmemo-meta></span>
            <button type="button" class="cmm-view" data-cmmemo-ui aria-expanded="false"
                    aria-haspopup="true" data-why="ui">UI ▾</button>
            <button type="button" class="cmm-view cmm-flt" data-cmmemo-flt aria-expanded="false"
                    aria-haspopup="true" data-why="flt">필터 <i data-cmmemo-flt-n>0</i> ▾</button>
            <button type="button" class="cmm-view" data-cmmemo-view aria-expanded="false"
                    aria-haspopup="true" data-why="view">보기 <b data-cmmemo-view-cr>오늘</b> <i data-cmmemo-view-n>2</i> ▾</button>
            <button type="button" class="cmm-view" data-cmmemo-sort aria-expanded="false"
                    aria-haspopup="true" data-why="sort">정렬 ▾</button>
            <button type="button" class="cmm-view" data-cmmemo-hist aria-expanded="false"
                    aria-haspopup="true" data-why="hist">히스토리 ▾</button>
            <button type="button" class="cmm-add" data-cmmemo-add>＋ 체크리스트</button>
            <button type="button" class="exp" data-cmmemo-exp>확장</button>
          </div>
          <div class="cmm-doc" data-cmmemo-doc contenteditable="true" spellcheck="false"></div>
          <!-- 초집중 편집면 — 지금 덩어리 하나만 담는 순수 textarea(위 CSS 절 참조).
               다른 모드에서는 감춰져 있고, 행 편집기(.cmm-doc)와 서로 건드리지 않는다. -->
          <textarea class="cmm-ua" data-cmmemo-ua spellcheck="false"
                    placeholder="지금 이 덩어리만 — 자동 저장됩니다. 새 덩어리는 위 ＋ 버튼."></textarea>
          <!-- 프로토타입의 힌트 줄. 아이콘만으로는 3단계 순환도 히든 번호도 알 길이 없다. -->
          <div class="cmm-hint">
            <kbd>⇧Enter</kbd> <b>하위 줄</b> ·
            <kbd>⌘Enter</kbd> <b>상세 열기/접기</b> ·
            <kbd>⌘⇧Enter</kbd> <b>목표일·담당·팀·프로젝트·부모·지라·노션·슬랙</b> ·
            <b>원</b> 클릭 미완료 → 완료 → 바틀넥 ·
            원에 <b>마우스 올리면</b> 골번호 ·
            <kbd>⌘⇧K</kbd> 체크리스트 ·
            <kbd>⌘⇧S</kbd> 취소선 ·
            <kbd>⌘Z</kbd> <b>되돌리기</b> ·
            우클릭 <b>CSV 복사 · 가져오기</b>
          </div>
        </section>
        <script>
        window.CMMemo = window.CMMemo || (function(){
          // rev   — 서버 판번호. 저장 때 base 로 되돌려 보내는 낡은-쓰기 방지 열쇠 (null = 아직 모름).
          // dirty — 화면의 글이 서버에 닿았음을 확인하지 못한 상태. flush 판단과 '저장됨' 표시의 근거.
          var pads=[], loaded=false, text='', timer=null, retry=null, pending=false;
          // uaWasUltra — 직전 페인트가 초집중이었나(모드를 나갈 때 딱 한 번 글을 행에 반영한다).
          var uaWasUltra=null;
          var rev=null, dirty=false, flushAfter=false;
          var STATES=['todo','done','block'], MARK={todo:'',done:'✓',block:'!'},
              TOKEN={todo:'- [ ] ',done:'- [x] ',block:'- [!] '}, IND='    ';
          var PH='떠오른 생각을 그대로 적어 두세요 — 자동 저장됩니다.';
          // ── 왜 이 메뉴가 있는가 ────────────────────────────────────────
          // 콤보가 다섯 개고 그 안의 축이 또 여러 개다. 무엇을 하는지는 항목 이름이
          // 말해 주지만, '왜 이런 게 있는지' 는 아무 데도 적혀 있지 않았다 — 그래서
          // 머리 버튼과 콤보 소제목에 마우스를 올리면 그 까닭이 뜬다(data-why).
          // 답이 아니라 결정의 배경을 적는다: 무엇을 포기하고 무엇을 얻었는지.
          var WHY={
            view:'왜 다중 선택인가\n\n'+
                 '미완료·완료·바틀넥은 서로 배타적인 모드가 아니라 각각 켜고 끄는 축이다. '+
                 '일을 처리하는 동안에는 완료를 꺼서 남은 것만 남기고, 회고나 리포트를 쓸 때는 '+
                 '완료를 켜서 무엇을 끝냈는지 그대로 읽는다. 하나만 고르는 라디오였다면 '+
                 '"완료만 빼고 나머지 전부" 같은 조합을 만들 수 없다.\n\n'+
                 '오른쪽 숫자는 각 상태의 줄 수. 감추는 것은 표시일 뿐이라 글도 골번호도 '+
                 '지워지지 않는다 — 다시 켜면 그 자리에 그대로 있다.',
            cr:  '왜 기본이 "오늘 만든 것만" 인가\n\n'+
                 '아침에 패드를 열었을 때 어제 것, 엊그제 것, 그 전부터 쌓인 것이 한꺼번에 '+
                 '눈에 들어오면 — 오늘 머릿속에 있는 것을 꺼내 적기도 전에 지난 것들을 '+
                 '정리하느라 시간을 다 쓴다. 하루의 첫 시간은 정리가 아니라 산출에 써야 한다.\n\n'+
                 '게다가 그 정리는 애초에 사람이 손으로 할 일이 아니다. 골(목표) 기반으로 '+
                 '팀별 정리거리를 적립해 두고 AI 에이전트가 대신 훑는다 — 사람이 아침마다 '+
                 '같은 목록을 다시 읽는 것은 비효율이다.\n\n'+
                 '그래서 기본은 오늘 만든 줄만이고, 지난 것을 봐야 할 때만 여기서 어제부터 · '+
                 '최근 7일 · 전체로 넓힌다. 하루의 경계는 자정이 아니라 새벽 4시다 — 밤을 새워 '+
                 '이어 쓰는 중에 자정이 지났다고 30분 전에 적은 줄이 사라지면 안 되니까. 새벽 '+
                 '3시에 적은 줄은 그날 밤 작업의 일부, 즉 어제의 업무일로 센다.\n\n'+
                 '"전체" 에서만 보이는 줄도 있다: 이 기능이 생기기 전부터 있던 줄(@생성: 이전). '+
                 '언제 만들었는지 알 길이 없어 날짜를 지어내지 않았다.',
            loop:'왜 날짜가 아니라 루프인가\n\n'+
                 '새벽까지 이어지는 작업에서 "어제 끝낸 것" 의 경계는 애매하다. 그래서 완료한 '+
                 '줄을 묻는 단위는 날짜가 아니라 보드(트래커)의 스프린트·릴리즈와 같은 '+
                 '일련번호로 잡았다.\n\n'+
                 '"루프 종료" 를 누르면 그때까지의 완료 줄에 현재 루프 코드가 찍혀 기본 보기에서 '+
                 '사라지고, 미완료·바틀넥만 다음 루프로 넘어간다. 지난 사이클에 무엇을 했는지 '+
                 '다시 봐야 하면 "이전 루프 포함".\n\n'+
                 '완료를 되돌리면 스탬프가 떨어져 현재 루프로 돌아온다 — 다시 하는 일은 이번 '+
                 '루프의 일이기 때문. 잘못 눌렀으면 ⌘Z 한 번이면 된다.\n\n'+
                 '생성 날짜와는 다른 축이다: 루프는 "완료를 언제 묻었나", 생성 날짜는 '+
                 '"이 줄을 언제 만들었나".',
            sort:'왜 정렬이 따로 있나\n\n'+
                 '저장 순서(적은 순서)는 생각이 흘러간 순서라 건드리지 않는다. 하지만 일을 '+
                 '처리할 때 필요한 순서는 다르다 — 지금 할 것(미완료)이 위, 진행이 막힌 '+
                 '바틀넥은 "나중에 볼 것" 으로 그 아래, 끝낸 것은 눈 밖으로.\n\n'+
                 '그래서 정렬은 표시(CSS)만 바꾼다. 저장 텍스트의 줄 순서도 골번호도 그대로라 '+
                 '정렬을 풀면 즉시 원래 모습이고, ⌘Z 히스토리에도 흔적이 남지 않는다.',
            ui:  '왜 UI 모드가 있나\n\n'+
                 '같은 메모를 혼자 볼 때와 남과 같이 볼 때가 다르다.\n\n'+
                 '집중 — 화면 공유·발표용. 쓰고 있는 줄만 또렷하게 남고 나머지는 회색으로 '+
                 '가라앉는다. 보는 사람의 눈이 "지금 이 줄" 을 따라온다.\n\n'+
                 '초집중 — 프라이버시용이자 쓰기 전용. 지금 덩어리 하나만 남고 나머지는 '+
                 '화면에서 사라진다. 어깨너머로 다른 글이 읽히지 않는다.\n\n'+
                 '초집중에서는 키보드가 이 덩어리를 벗어나지 않는다 — ↑↓ 로 앞뒤 덩어리를 '+
                 '넘기던 길을 없앴다(2026-08-16). 화면에 한 덩어리뿐이라 그 건너뜀은 "쓰던 '+
                 '글이 통째로 날아간 것" 과 눈으로 구분되지 않았기 때문이다. 덩어리를 바꾸는 '+
                 '길은 머리의 ＋ 버튼 한 번뿐이고, 그 전에 지금 글은 반드시 저장된다.\n\n'+
                 '초집중은 표시만 바꾸지 않는다 — 편집면 자체가 순수 텍스트 칸이다(2026-08-13). '+
                 '원도, 제목/상세 구분도, 칸도 없다. 접힌 상세처럼 "화면에 없는데 데이터에는 '+
                 '있는" 자리가 사라지니, 구조 때문에 글이 지워질 길도 함께 사라진다. 제목 칸이 '+
                 '없으므로 빈 덩어리에 쓰기 시작하면 날짜·시각 한 줄이 머리에 자동으로 붙는다.\n\n'+
                 '칸(목표일·담당 …)·골번호·완료 상태는 그대로 남아 기본 모드에서 다시 보인다. '+
                 '집중은 예전 그대로 표시만 바꾼다.',
            grp: '왜 구조 축이 따로 있나\n\n'+
                 '메모는 떠오른 순서대로 쌓이지만 일은 부모-자식으로 묶인다. "@부모: 골번호" 만 '+
                 '적어 두면 여기서 자식이 부모 바로 아래로 들어가 계층으로 보인다 — 줄을 손으로 '+
                 '끌어 옮겨 정리할 필요가 없다.\n\n'+
                 '역시 표시만 바꾼다. 저장 텍스트의 순서는 그대로라 리스트로 되돌리면 적은 '+
                 '그대로의 모습이다.',
            flt: '왜 필터가 따로 있나\n\n'+
                 '보기(상태)·생성 날짜와 또 다른 축이다 — 칸에 적힌 "값" 으로 거른다. 리포트를 '+
                 '쓰거나 남에게 넘길 때 필요한 것은 내 것 전부가 아니라 이 사람의 것, 이 팀의 것, '+
                 '이 프로젝트의 것이기 때문.\n\n'+
                 '후보는 사전이 아니라 지금 메모에 실제로 쓰인 담당·팀·프로젝트 값에서 나온다 — '+
                 '한 번 적어 두면 그게 곧 필터다. 같은 칸 안에서 여러 값을 고르면 그중 하나(OR), '+
                 '칸이 다르면 모두 만족(AND).\n\n'+
                 '조건과 안 맞는 줄은 감춰질 뿐 지워지지 않는다. 완전히 빈 줄은 거르지 않는다 — '+
                 '필터를 걸어 둔 채로도 이어 쓸 자리는 남아야 하니까.',
            hist:'왜 히스토리가 필요한가\n\n'+
                 '이 패드는 자동 저장이라 "저장하지 않고 닫기" 로 빠져나갈 길이 없다. 그리고 '+
                 '⌘Z 는 이 창을 연 뒤의 편집만 되돌린다 — 창을 닫았다 열었거나, 다른 창이 먼저 '+
                 '저장했거나, 한참 전 모습으로 돌아가야 할 때는 손쓸 방법이 없었다.\n\n'+
                 '그래서 저장될 때마다 지난 판을 서버 저널에 남긴다. 판을 고르면 전문을 미리 보고 '+
                 '"이 판으로 복원"(통째 교체) 또는 "현재 글과 합치기"(합집합 — 지금 글을 한 줄도 '+
                 '버리지 않는다) 중에 고른다.\n\n'+
                 '어느 쪽이든 되돌리기 한 단계다 — 잘못 눌렀으면 ⌘Z 로 즉시 돌아온다.'
          };
          // 리포트에서 되묻게 되는 값들만 칸으로 받는다(⌘⇧Enter). 저장은 상세와 같은 들여쓴
          // 줄이되 '@목표일: ' 처럼 이름을 달아 둔다 — 텍스트로 열어도 사람이 읽을 수 있게.
          // tag:true 인 칸은 자유 입력이 아니라 사전에서 고르는 칸이다(MemoTagStore) —
          // 같은 사람·팀·프로젝트가 철자만 다르게 여러 벌 쌓이는 것을 막기 위해서.
          // tz:true 인 칸은 '시각' 이다 — 날짜만이 아니라 시간까지 받고, 저장은 언제나 UTC
          // (…Z), 화면에는 현재 표시 타임존의 벽시계로 보여 준다. 리포트를 받는 사람이 서울에
          // 있든 인도에 있든, 표시 타임존만 바꾸면 같은 한 순간이 각자의 시계로 다시 계산된다.
          // link:'…' 인 칸은 서비스별 링크 칸이다(2026-08-06, 옛 통합 '링크' 칸을 셋으로
          // 나눔) — PM 에이전트가 주기적으로 와서 지라·노션·슬랙 각 칸을 찾아 채우고
          // 추적할 수 있도록 저장 키부터 '@지라: ' 처럼 서비스 이름으로 갈라 둔다.
          // 값은 어느 칸이든 그대로 저장하고, 주소가 그 서비스가 맞는지는 표시로만 알린다.
          // pno:true 인 칸은 부모 골번호 칸이다(2026-08-06) — 이 줄을 어느 골 아래에 둘지
          // 골번호 하나로 적는다(보드 골이든 메모의 다른 줄이든 같은 번호 공간). 부모 기반
          // 표시(UI 콤보의 구조)가 이 칸을 따라 자식을 부모 아래로 모으고, 이름 옆 꼬리표가
          // 그 번호의 제목을 보여 준다.
          var FIELDS=[ {k:'목표일', t:'datetime-local', ph:'', tz:true},
                       {k:'담당',   t:'text',  ph:'이름', tag:true},
                       {k:'팀',     t:'text',  ph:'팀',   tag:true},
                       {k:'프로젝트',t:'text', ph:'연관 프로젝트', tag:true},
                       {k:'부모',   t:'text',  ph:'부모 골번호 — 예: 12', pno:true},
                       {k:'지라',   t:'url',   ph:'https://…atlassian.net — 이슈·에픽',  link:'jira'},
                       {k:'노션',   t:'url',   ph:'https://…notion.so — 스펙·문서',      link:'notion'},
                       {k:'슬랙',   t:'url',   ph:'https://…slack.com — 스레드·대화',    link:'slack'} ];
          // '링크' 는 옛 통합 칸의 저장 키 — 새 칸에는 없지만 계속 읽는다(parse 가 세 칸에 나눠 담는다).
          // '골' 은 칸이 아니라 줄의 골번호다 — parse 가 행 자체에 싣는다(아래 골번호 절 참조).
          // '루프' 도 칸이 아니다 — '루프 종료' 가 완료 줄에 찍는 이전-루프 스탬프(루프 절 참조).
          // '생성' 도 칸이 아니다 — 줄이 만들어진 순간의 스탬프(생성 날짜 절 참조).
          var FRE=new RegExp('^@('+FIELDS.map(function(f){ return f.k; }).join('|')+'|링크|골|루프|생성):\\s?(.*)$');
          // '@부모: #12' / ' 12 ' 처럼 적어도 번호로 읽는다. 아니면 0.
          function pnum(v){ var m=/^\s*#?(\d+)\s*$/.exec(String(v||'')); return m?+m[1]:0; }
          // 루프 스탬프 값 — 보드 루프 코드('26-38', 부분 커밋 '26-38.2')나 순수 숫자
          // (보드 연동 전 과도기 스탬프)를 그대로 읽는다. 아니면 ''(스탬프 아님).
          function lcode(v){ var m=/^\s*#?(\d+(?:-\d+)?(?:\.\d+)?)\s*$/.exec(String(v||'')); return m?m[1]:''; }
          // 생성 스탬프 값 — 저장은 언제나 UTC('2026-08-10T04:12Z'). '이전' 은 이 기능이
          // 생기기 전부터 있던 줄(언제 만들었는지 알 길이 없다)의 자리표다. 그 외는 스탬프가
          // 아니다 — 사람이 직접 고쳐 쓴 이상한 값으로 줄이 사라지면 안 되므로 상세로 남긴다.
          function ccode(v){
            v=String(v||'').trim();
            if(v==='이전') return '이전';
            return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z$/.test(v) ? v : '';
          }

          // ── 링크 판정 ──────────────────────────────────────────────────
          // 칸이 서비스별로 나뉜 뒤에도 호스트 판정은 남아 두 가지 일을 한다:
          // (1) 옛 '@링크: ' 저장분을 어느 칸에 담을지 정하는 라우팅(LK2F),
          // (2) 칸에 넣은 주소가 정말 그 서비스인지 이름 옆에 알려 주는 검증.
          // 판정은 호스트네임으로만 한다(경로·쿼리는 사이트마다 제각각이라 믿을 수
          // 없고, 경로에 slack.com 을 끼워 넣는 눈속임도 막는다).
          // http(s) 가 아니면 판정하지 않는다 — javascript: 류가 칩을 타면 안 된다.
          // 모르는 호스트는 '링크' — 구분을 못 한다고 판정이 아예 없는 것보다 낫다.
          var LINKS=[ {re:/(^|\.)slack\.com$/,             t:'슬랙',   c:'대화',  k:'slack'},
                      {re:/(^|\.)atlassian\.net$|^jira\./, t:'지라',   c:'관리',  k:'jira'},
                      {re:/(^|\.)notion\.(so|site)$/,      t:'노션',   c:'문서',  k:'notion'},
                      {re:/(^|\.)github\.com$/,            t:'깃허브', c:'코드',  k:'github'} ];
          // 판정 결과 → 담을 칸. 여기 없는 종류(깃허브·일반)는 옛 줄을 그대로 상세로 남긴다.
          var LK2F={ slack:'슬랙', jira:'지라', notion:'노션' };
          function linkKind(u){
            u=String(u||'').trim();
            if(!/^https?:\/\//i.test(u)) return null;
            var h=''; try{ h=new URL(u).hostname.toLowerCase(); }catch(e){ return null; }
            if(!h) return null;
            for(var i=0;i<LINKS.length;i++) if(LINKS[i].re.test(h)) return LINKS[i];
            return {t:'링크', c:'', k:'link'};
          }

          // ── 시각 칸: 저장(UTC) ↔ 표시(현재 타임존) ──────────────────────
          // 변환은 CMTimeFilter(표시 tz = 서버가 주입한 window.CM_TZ)에 맡긴다. 레일이 없는
          // 페이지에 패드만 얹혔을 때를 대비해 브라우저 로컬 시계로 물러서는 길도 둔다.
          function p2(n){ return (n<10?'0':'')+n; }
          function tzMod(){ return window.CMTimeFilter || null; }
          function tzLabel(){
            var T=tzMod(); if(T && T.tzLabel) { try{ return T.tzLabel(); }catch(e){} }
            try{ return Intl.DateTimeFormat().resolvedOptions().timeZone||'현지'; }catch(e){ return '현지'; }
          }
          // 저장값 → <input type=datetime-local> 값. 끝에 Z 가 없는 값(예전 '@목표일: 2026-08-05')은
          // 타임존을 모르는 값이므로 벽시계 그대로 읽는다 — 옛 메모의 날짜가 하루 밀리지 않도록.
          function toDisp(v){
            var m=/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?(Z)?/.exec(String(v||'').trim());
            if(!m) return '';
            if(!m[6]) return m[1]+'-'+m[2]+'-'+m[3]+'T'+(m[4]||'00')+':'+(m[5]||'00');
            var sec=Math.floor(Date.UTC(+m[1],+m[2]-1,+m[3],+(m[4]||0),+(m[5]||0))/1000);
            var T=tzMod();
            if(T && T.epochToInput) return T.epochToInput(sec);
            var d=new Date(sec*1000);
            return d.getFullYear()+'-'+p2(d.getMonth()+1)+'-'+p2(d.getDate())
                   +'T'+p2(d.getHours())+':'+p2(d.getMinutes());
          }
          // 표시 벽시계 → 저장값(UTC, …Z). 값이 없거나 못 읽으면 빈 문자열 — 안 쓴 칸은 남기지 않는다.
          function toStore(v){
            var m=/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?/.exec(String(v||'').trim());
            if(!m) return '';
            var iso=m[1]+'-'+m[2]+'-'+m[3]+'T'+(m[4]||'00')+':'+(m[5]||'00');
            var T=tzMod(), sec;
            if(T && T.inputToEpoch) sec=T.inputToEpoch(iso);
            else sec=Math.floor(new Date(+m[1],+m[2]-1,+m[3],+(m[4]||0),+(m[5]||0)).getTime()/1000);
            if(!sec || isNaN(sec)) return '';
            var d=new Date(sec*1000);
            return d.getUTCFullYear()+'-'+p2(d.getUTCMonth()+1)+'-'+p2(d.getUTCDate())
                   +'T'+p2(d.getUTCHours())+':'+p2(d.getUTCMinutes())+'Z';
          }

          function meta(msg){ pads.forEach(function(p){ p.meta.textContent=msg; }); }

          // 확장 상태는 body 클래스 하나로 — 한 페이지에 패드가 여러 개여도 같이 움직인다.
          // 선택은 localStorage 에 남아 다음에 열 때도 유지된다.
          function expOn(){ try{ return localStorage.getItem('cmMemoExp')==='1'; }catch(e){ return false; } }
          function expPaint(){
            var on=expOn();
            if(document.body) document.body.classList.toggle('cmmemo-exp', on);
            pads.forEach(function(p){ if(p.exp){ p.exp.textContent = on ? '접기' : '확장';
              p.exp.setAttribute('aria-expanded', on ? 'true' : 'false'); } });
          }
          function expToggle(){
            try{ localStorage.setItem('cmMemoExp', expOn() ? '0' : '1'); }catch(e){}
            expPaint();
          }

          // ── 보기 필터 ──────────────────────────────────────────────────
          // 기본은 "완료 숨김" — 처리하는 동안에는 남은 일만 보이는 게 집중에 낫다.
          // 리포트를 쓸 때 완료를 켜면 무엇을 했는지 그대로 드러난다. 선택은 저장된다.
          // 감춤은 CSS 만 건드린다 — 텍스트도 번호도 그대로다(감춘 줄은 사라진 게 아니다).
          var VIEWS=[{s:'todo',n:'미완료'},{s:'done',n:'완료'},{s:'block',n:'바틀넥'}];
          function viewShown(){
            try{ var v=localStorage.getItem('cmMemoView');
                 if(v!==null) return v ? v.split(',') : []; }catch(e){}
            return ['todo','block'];                       // 기본: 완료만 숨김
          }
          function viewSet(list){
            try{ localStorage.setItem('cmMemoView', list.join(',')); }catch(e){}
            viewPaint();
          }
          function viewPaint(){
            var on=viewShown();
            var hide=VIEWS.filter(function(v){ return on.indexOf(v.s)<0; })
                          .map(function(v){ return v.s; }).join(' ');
            pads.forEach(function(p){
              p.el.setAttribute('data-hide', hide);
              if(p.viewN) p.viewN.textContent=on.length;
              ultraEnsure(p);            // 초집중의 '지금 줄' 이 방금 감춰졌으면 옮긴다
            });
            if(menuEl && menuEl.dataset.view==='1') paintMenu();
          }
          function viewToggle(s){
            var on=viewShown(), i=on.indexOf(s);
            if(i<0) on.push(s); else on.splice(i,1);
            viewSet(VIEWS.filter(function(v){ return on.indexOf(v.s)>=0; }).map(function(v){ return v.s; }));
          }

          // ── 루프 ──────────────────────────────────────────────────────
          // 보드와 같은 루프가 단위다(2026-08-07 — 날짜 기준은 새벽 작업에서 애매해 버렸다).
          // '루프 종료' 가 완료 줄에 '@루프: <보드 루프 코드>' 를 찍으면 그 줄은 이전
          // 루프로 묻혀 기본 보기에서 사라지고, 미완료·바틀넥은 다음 루프로 넘어간다.
          // (보드의 루프 컷도 서버에서 같은 스탬프를 찍는다 — MemoStore.harvestLoop.)
          // 보기 모드는 둘: 기본(현재 루프만) / 'all'(이전 루프 포함). 상태의 진실은
          // 메모리(loopState) — localStorage 는 다음에 열 때를 위한 best-effort 영속이다
          // (필드 필터와 같은 원칙: 저장소가 막힌 웹뷰에서도 동작해야 한다).
          var loopState=null;
          function loopMode(){
            if(loopState!==null) return loopState;
            try{ loopState = localStorage.getItem('cmMemoLoop')==='all' ? 'all' : ''; }
            catch(e){ loopState=''; }
            return loopState;
          }
          function loopSet(m){
            loopState = m==='all' ? 'all' : '';
            try{ localStorage.setItem('cmMemoLoop', loopState); }catch(e){}
            loopPaint();
          }
          function loopPaint(){
            var m=loopMode();
            pads.forEach(function(p){
              if(m) p.el.setAttribute('data-loops', m); else p.el.removeAttribute('data-loops');
              ultraEnsure(p);            // 초집중의 '지금 줄' 이 방금 묻혔으면 옮긴다
            });
            if(menuEl && menuEl.dataset.view==='1') paintMenu();
          }
          // 진행 중인 루프 번호 폴백 — 보드(/data.json)를 모르는 환경(스텁·오프라인)에서만
          // 쓰는 숫자 스탬프 최대+1. 보드가 있으면 진짜 루프 코드(bgLoop.cur)가 우선이다.
          function loopCur(pad){
            var mx=0;
            if(pad) rows(pad).forEach(function(r){
              var v=/^\d+$/.test(r.dataset.lp||'') ? +r.dataset.lp : 0; if(v>mx) mx=v; });
            return mx+1;
          }
          // 루프 종료 — 아직 스탬프 없는 완료 줄 전부에 현재 루프 코드(보드와 같은 일련번호,
          // 예: 26-38)를 찍는다. 사람의 액션 한 단계 — 잘못 눌렀으면 ⌘Z 로 그대로 돌아온다.
          // 릴리즈 컷(서버 harvestLoop)도 같은 문법으로 찍는다 — 어느 쪽이 먼저든 한 루프다.
          function loopEnd(pad){
            var code=(bgLoop&&bgLoop.cur)||String(loopCur(pad));
            var hit=rows(pad).filter(function(r){ return r.dataset.st==='done' && !r.dataset.lp; });
            if(!hit.length) return;
            hit.forEach(function(r){ r.dataset.lp=code; });
            onEdit(pad, true);
          }

          // ── 생성 날짜 ──────────────────────────────────────────────────
          // 왜(2026-08-10): 아침에 패드를 열면 어제·엊그제·그 전에 만든 줄이 한꺼번에
          // 눈에 들어온다. 그러면 오늘 머릿속에 있는 것을 꺼내 적기 전에 지난 것들을
          // 정리하느라 시간을 다 쓴다. 그 정리는 사람이 손으로 할 일이 아니다 — 골(목표)
          // 기반으로 팀별 정리거리를 적립해 두고 AI 에이전트가 대신 훑는다. 그래서 패드의
          // 기본은 '오늘 만든 줄만' 이고, 지난 것을 볼 필요가 있을 때만 여기서 날짜를 넓힌다.
          //
          // 루프와 다른 축이다: 루프는 '완료를 언제 묻었나'(끝낸 일), 여기는 '이 줄을 언제
          // 만들었나'(태어난 날). 미완료로 남아 있어도 어제 만든 줄은 어제 것이다.
          //
          // 하루 경계는 자정이 아니라 새벽 4시(DAYCUT). 밤을 새워 이어 쓰는 중에 자정이
          // 지났다고 30분 전에 적은 줄이 '어제 것' 으로 사라지면 안 된다 — 새벽 3시에 적은
          // 줄은 그날 밤 작업의 일부, 즉 어제의 업무일로 센다(루프 절이 날짜 기준 자체를
          // 버린 그 문제를, 여기서는 경계를 옮겨 푼다). 스탬프는 저장 텍스트에
          // '@생성: <UTC>' 로 남고, 감춤은 늘 CSS 만(data-cx) — 글도 골번호도 그대로다.
          var DAYCUT=4;
          var CRS=[{s:'',   n:'오늘만',    d:'기본'},
                   {s:'2',  n:'어제부터',  d:''},
                   {s:'7',  n:'최근 7일',  d:''},
                   {s:'all',n:'전체',      d:'예전 줄까지'}];
          // 버튼 표찰 — 메뉴를 열지 않고도 지금 어디까지 보이는지 알 수 있어야 한다.
          var CRLBL={'':'오늘','2':'어제부터','7':'7일','all':'전체'};
          var crState=null;
          function crMode(){
            if(crState!==null) return crState;
            try{ var v=localStorage.getItem('cmMemoCr');
                 crState = (v==='2'||v==='7'||v==='all') ? v : ''; }
            catch(e){ crState=''; }
            return crState;
          }
          function crSet(m){
            crState = (m==='2'||m==='7'||m==='all') ? m : '';
            try{ localStorage.setItem('cmMemoCr', crState); }catch(e){}
            meta(stat());                                  // 감춤은 paint 가 행마다 다시 매긴다
            crBtnPaint();
            if(menuEl && menuEl.dataset.view==='1') paintMenu();
          }
          function crBtnPaint(){
            var l=CRLBL[crMode()]||'오늘';
            pads.forEach(function(p){ if(p.viewCr) p.viewCr.textContent=l; });
          }
          // 지금 UTC 를 스탬프 문자열로. 저장은 언제나 UTC — 표시 타임존이 바뀌어도
          // '언제 만들었나' 는 한 순간 그대로다(칸의 시각 저장과 같은 원칙).
          function crNow(){
            var d=new Date(now());
            return d.getUTCFullYear()+'-'+p2(d.getUTCMonth()+1)+'-'+p2(d.getUTCDate())
                   +'T'+p2(d.getUTCHours())+':'+p2(d.getUTCMinutes())+'Z';
          }
          function crEpoch(v){
            var m=/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})Z$/.exec(String(v||''));
            return m ? Math.floor(Date.UTC(+m[1],+m[2]-1,+m[3],+m[4],+m[5])/1000) : 0;
          }
          // 그 순간이 속한 '업무일' 의 날짜 문자열. 표시 타임존의 벽시계에서 새벽
          // 4시를 하루의 시작으로 본다(= 4시간 당겨 읽는다).
          function crDay(sec){
            sec = sec - DAYCUT*3600;
            var T=tzMod();
            if(T && T.epochToInput){ try{ return T.epochToInput(sec).slice(0,10); }catch(e){} }
            var d=new Date(sec*1000);
            return d.getFullYear()+'-'+p2(d.getMonth()+1)+'-'+p2(d.getDate());
          }
          // 오늘부터 거슬러 7일치 업무일 문자열. 글자마다 다시 세지 않도록 1분 캐시.
          var crKeyC={t:0, k:null};
          function crKeys(){
            var t=Math.floor(now()/1000);
            if(crKeyC.k && t-crKeyC.t<60) return crKeyC.k;
            var k=[]; for(var i=0;i<7;i++) k.push(crDay(t-i*86400));
            crKeyC={t:t, k:k};
            return k;
          }
          // 이 줄이 며칠 전 것인가 — 0=오늘, 1=어제 … 6. '이전'(첫 로드에서 채운 예전 글)
          // 이거나 7일보다 오래됐으면 -1.
          //
          // 스탬프가 아예 없으면 '오늘' 로 본다. 실제로는 있을 수 없는 상태다(예전 글은
          // crMigrate 가 '이전' 으로 채우고, 새 줄은 저장 직전에 찍힌다) — 그래도 만에
          // 하나 스탬프 없는 줄이 생겼을 때 감춰 버리는 쪽으로 틀리면 사람 눈에는 글이
          // 사라진 것으로 보인다. 틀리려면 '너무 많이 보이는' 쪽으로 틀린다.
          function crAge(row, keys){
            var v=row.dataset.cr;
            if(!v) return 0;
            if(v==='이전') return -1;
            var sec=crEpoch(v); if(!sec) return -1;
            return keys.indexOf(crDay(sec));
          }
          function crFit(age, m){
            if(m==='all') return true;
            if(age<0) return false;
            if(m==='7') return true;
            if(m==='2') return age<=1;
            return age===0;
          }
          // 완전히 빈 줄 — 감추지 않는다(날짜를 좁혀 둔 채로도 이어 쓸 자리는 남는다).
          function crBlank(row){
            if(row.dataset.st) return false;
            if((row.querySelector('.cmm-tx').textContent||'').trim()) return false;
            if(dtText(row.querySelector('.cmm-dt')).trim()) return false;
            return !hasFields(row);
          }
          // 방금 만들어진 줄에 스탬프를 찍는다 — 저장 직전(onEdit)에 한 번. 아직 스탬프가
          // 없는 '내용 있는 줄' 이 곧 새 줄이다: 예전 글은 첫 로드에서 '이전' 으로 한 번
          // 채워지므로(crMigrate) 여기 걸리지 않는다.
          function crStampNew(pad){
            var t=null;
            rows(pad).forEach(function(r){
              if(r.dataset.cr || crBlank(r)) return;
              r.dataset.cr = (t = t || crNow());
            });
          }
          // 첫 로드에서 한 번: 스탬프가 하나도 없는 예전 글의 모든 줄에 '@생성: 이전' 을
          // 채운다. 언제 만들었는지는 알 길이 없으니 날짜를 지어내지 않는다 — '이전' 은
          // '전체' 에서만 보인다. 이 한 번이 지나면 스탬프 없는 줄 = 방금 만든 줄이 된다.
          function crMigrate(s){
            if(!s || s.indexOf('@생성:')>=0) return s;
            var out=[];
            s.split('\n').forEach(function(l){
              out.push(l);
              if(/^(\s{4}|\t)/.test(l)) return;            // 상세·칸 줄
              if(!l.trim()) return;                        // 빈 줄
              out.push(IND+'@생성: 이전');
            });
            return out.join('\n');
          }

          // ── 정렬 ──────────────────────────────────────────────────────
          // 기본은 입력 순서(현재 값 그대로). '미완료 위 · 완료 아래' 는 처리 관점 —
          // 지금 할 것부터 보이고, 진행이 막힌 바틀넥은 '나중에 볼 것' 으로 완료 바로 위에,
          // 끝낸 것은 눈 밖으로 내려간다. 보기 필터와 같은 원칙으로
          // CSS(order)만 바꾼다 — 저장 텍스트의 줄 순서와 일련번호는 그대로라, 정렬을
          // 풀면 즉시 원래 모습이고 ⌘Z 히스토리에도 아무 흔적이 없다. 선택은 저장된다.
          var SORTS=[{s:'',n:'입력 순서',d:'기본'},
                     {s:'st',n:'미완료 위 · 완료 아래',d:'처리'}];
          function sortMode(){
            try{ var v=localStorage.getItem('cmMemoSort');
                 return v==='st' ? v : ''; }catch(e){ return ''; }
          }
          function sortSet(m){
            try{ localStorage.setItem('cmMemoSort', m); }catch(e){}
            sortPaint();
          }
          function sortPaint(){
            var m=sortMode();
            pads.forEach(function(p){
              if(m) p.el.setAttribute('data-sort', m); else p.el.removeAttribute('data-sort');
              if(p.sort) p.sort.textContent = m ? '미완료↑ 완료↓ ▾' : '정렬 ▾';
            });
            if(menuEl && menuEl.dataset.sort==='1') paintMenu();
          }

          // ── UI 모드 ────────────────────────────────────────────────────
          // 기본은 지금 모습 그대로. '집중' 은 화면을 남과 같이 볼 때(공유·발표) —
          // 쓰고 있는 줄만 색을 남기고 나머지는 회색으로 가라앉히고, 글자를 한 단계
          // 키운다. '초집중' 은 프라이버시 — 지금 줄 하나만 남기고 나머지는 화면에서
          // 아예 사라진다(↑↓ 로 이웃 줄을 꺼내 본다). 정렬과 같은 원칙으로 CSS 만
          // 바꾼다. 선택은 저장된다.
          var UIS=[{s:'',n:'기본',d:'현재 모습'},
                   {s:'focus',n:'집중',d:'공유·발표'},
                   {s:'ultra',n:'초집중',d:'프라이버시 — 지금 덩어리만, 순수 텍스트'}];
          // 구조 — 같은 콤보의 두 번째 축. '리스트' 는 지금처럼 줄 순서 그대로,
          // '부모 기반' 은 '@부모: 골번호' 를 따라 자식이 부모 바로 아래로 들어가
          // 계층(들여쓰기)으로 보인다. 역시 표시만 — 저장 텍스트는 그대로다.
          // 부모 기반이 켜지면 행마다 인라인 order 가 붙어 정렬(미완료↑)보다 우선한다.
          var GRPS=[{s:'',n:'리스트',d:'지금처럼'},
                    {s:'tree',n:'부모 기반',d:'부모 아래 자식'}];
          function uiMode(){
            try{ var v=localStorage.getItem('cmMemoUI');
                 return (v==='focus'||v==='ultra') ? v : ''; }catch(e){ return ''; }
          }
          // 예전에는 트리가 정렬 콤보(cmMemoSort='tree')에 있었다 — 아직 구조를 한 번도
          // 고르지 않은 사용자는 그 선택을 그대로 이어받는다.
          function grpMode(){
            try{ var v=localStorage.getItem('cmMemoGrp');
                 if(v==null) return localStorage.getItem('cmMemoSort')==='tree' ? 'tree' : '';
                 return v==='tree' ? v : ''; }catch(e){ return ''; }
          }
          function uiSet(m){
            try{ localStorage.setItem('cmMemoUI', m); }catch(e){}
            uiPaint();
          }
          function grpSet(m){
            try{ localStorage.setItem('cmMemoGrp', m);
                 if(localStorage.getItem('cmMemoSort')==='tree')
                   localStorage.setItem('cmMemoSort',''); }catch(e){}
            uiPaint();
          }
          function uiPaint(){
            var m=uiMode(), g=grpMode();
            pads.forEach(function(p){
              if(m) p.el.setAttribute('data-ui', m); else p.el.removeAttribute('data-ui');
              if(g) p.el.setAttribute('data-grp', g); else p.el.removeAttribute('data-grp');
              if(p.ui) p.ui.textContent = 'UI'+(m==='focus'?' 집중':m==='ultra'?' 초집중':'')
                                             +(g?' 부모':'')+' ▾';
              // 초집중에는 체크리스트가 없다 — 같은 버튼이 '새 덩어리' 로 이름을 바꾼다.
              // (키보드로는 덩어리를 못 옮기니, 이 버튼이 유일한 길임을 눈으로 알려야 한다.)
              var ab=p.el.querySelector('[data-cmmemo-add]');
              if(ab) ab.textContent = (m==='ultra' ? '＋ 새 덩어리' : '＋ 체크리스트');
              treePaint(p);                     // 부모 기반은 행마다 order 를 계산해 얹는다
              ultraEnsure(p);                   // 초집중은 '지금 줄' 하나를 늘 짚어 둔다
              // 초집중으로 들어가면 그 덩어리를 textarea 에 싣고 바로 쓸 수 있게 한다.
              // 나올 때는 쓰던 글을 행에 반영하고 나간다 — 모드를 바꿨다고 글이 남겨지지 않게.
              if(m==='ultra') uaLoad(p, uaWasUltra===false, true);
              else if(uaWasUltra){ uaSync(p); p.uaRow=null; }
            });
            uaWasUltra=(m==='ultra');
            if(menuEl && menuEl.dataset.ui==='1') paintMenu();
          }

          // ── UI 모드: 초집중 ────────────────────────────────────────────
          // '지금 줄'(data-cur) 하나만 화면에 남긴다. 이웃 줄은 DOM 에 그대로 있고
          // CSS 로만 감춰진다 — ＋ 버튼으로 옮겨 가면 그 줄이 나타난다. 지금 줄의 진실은
          // 캐럿이다: selectionchange 마다 캐럿이 앉은 행을 따라간다(다른 곳을 클릭해
          // 캐럿이 패드 밖으로 나가도 마지막 줄 표시는 유지한다 — 화면이 통째로 비면
          // 어디에 쓰고 있었는지 알 길이 없다).
          function ultraRowAt(pad){
            var el=cellAt(pad); if(!el || !pad.doc.contains(el)) return null;
            var r=el.parentElement;
            while(r && !(r.classList && r.classList.contains('cmm-row'))) r=r.parentElement;
            return r;
          }
          function ultraMark(pad, row){
            rows(pad).forEach(function(r){ if(r!==row && r.dataset && r.dataset.cur) delete r.dataset.cur; });
            if(row) row.dataset.cur='1';
          }
          // 보기·필터·루프에 걸려 숨는 줄은 초집중의 '지금 줄' 후보에서도 뺀다 —
          // 다른 모드에서 안 보이던 줄이 초집중에서 불쑥 나오면 안 된다.
          function ultraFit(pad, r){
            if(!r || !r.classList || !r.classList.contains('cmm-row')) return false;
            if(r.dataset.fx || r.dataset.cx) return false;
            if(r.dataset.lp && loopMode()!=='all') return false;
            return (pad.el.getAttribute('data-hide')||'').split(' ')
                     .indexOf(r.dataset.st||'')<0;
          }
          // 지금 줄 표시를 세워 둔다 — 캐럿 줄 우선, 없으면 이전 표시 유지, 그도
          // 없으면 마지막 보이는 줄(이어 쓰던 자리). 표시만 고친다 — 캐럿은 안 옮긴다.
          function ultraEnsure(pad){
            if(uiMode()!=='ultra'){
              rows(pad).forEach(function(r){ if(r.dataset && r.dataset.cur) delete r.dataset.cur; });
              return;
            }
            // 초집중에서 '지금 덩어리' 를 정하는 것은 textarea 다(2026-08-13). 편집면
            // (.cmm-doc)은 화면에 없으니 그 안의 옛 캐럿을 따라가면 안 된다 — 따라가면
            // 쓰던 중에 엉뚱한 덩어리로 끌려가 글이 뒤섞인다. 묶여 있는 행을 그대로 두고,
            // 그 행이 사라졌을 때만 아래의 폴백 사슬로 내려간다.
            var rs=rows(pad);
            var mark=(pad.ua && pad.uaRow && rs.indexOf(pad.uaRow)>=0) ? pad.uaRow : ultraRowAt(pad);
            if(!mark || rs.indexOf(mark)<0){
              mark=rs.filter(function(r){ return r.dataset.cur==='1'; })[0]||null;
              if(mark && !ultraFit(pad,mark)) mark=null;
              if(!mark) for(var i=rs.length-1;i>=0;i--)
                if(ultraFit(pad,rs[i])){ mark=rs[i]; break; }
              if(!mark) mark=rs[rs.length-1]||null;
            }
            ultraMark(pad, mark);
          }

          // ── 초집중 편집면: 지금 덩어리 하나 = textarea 하나 ──────────────
          // 첫 줄이 그 행의 제목, 나머지가 상세다. 그 둘을 화면에서 가르지 않는다 —
          // 접힌 상세(화면에 없는 글)가 이 편집기에서 글이 사라지는 가장 흔한 길이었다.
          // 행의 칸(목표일·담당 …)·골번호·상태는 건드리지 않고 그대로 남는다.
          function uaText(row){
            var t=row.querySelector('.cmm-tx').textContent;
            var d=dtText(row.querySelector('.cmm-dt')).replace(/\s+$/,'');
            return d ? t+'\n'+d : t;
          }
          // textarea → 행. 첫 줄 제목, 나머지 상세. 한 글자도 버리지 않는다.
          // 상세는 makeRow 와 같은 길로 쓴다(참조를 잡고 textContent 에 통글) — 읽을 때만
          // dtText 를 거친다(WebKit 이 만들어 둔 <div>/<br> 줄바꿈 때문에).
          function uaWrite(pad, row, v){
            var ls=String(v==null?'':v).split('\n');
            var head=ls.shift()||'';
            var body=ls.join('\n').replace(/\s+$/,'');
            var tx=row.querySelector('.cmm-tx'), dt=row.querySelector('.cmm-dt');
            tx.textContent=head;
            dt.textContent=body;
            if(body.trim()) row.dataset.has='1';
            else if(!hasFields(row)) delete row.dataset.has;
          }
          // 지금 덩어리(data-cur)를 textarea 에 싣는다. force=true 는 덩어리를 옮길 때 —
          // 그 외에는 쓰고 있는 손을 덮지 않는다(포커스·조합 중이면 그대로 둔다).
          function uaLoad(pad, focus, force){
            if(!pad.ua) return;
            var row=rows(pad).filter(function(r){ return r.dataset.cur==='1'; })[0]||null;
            var same=(row===pad.uaRow);
            pad.uaRow=row;
            if(!force){
              // 쓰고 있는 손이 진실이다 — 같은 덩어리에 캐럿이 있는 동안에는 절대 덮지 않는다.
              // (행은 textarea 의 그림자다: 방금 친 줄바꿈처럼 행 모델이 정규화해 버리는
              //  글자를 되쓰기로 지우면, 그게 곧 "쳤는데 사라졌다" 다.)
              if(pad.uaComposing) return;
              if(same && document.activeElement===pad.ua) return;
            }
            var v=row ? uaText(row) : '';
            if(!focus && pad.ua.value===v) return;
            var a=pad.ua.selectionStart, b=pad.ua.selectionEnd, act=(document.activeElement===pad.ua);
            pad.ua.value=v;
            pad.uaWant=false;
            if(focus){ try{ pad.ua.focus(); pad.ua.setSelectionRange(v.length, v.length); }catch(e){} }
            else if(act){ try{ pad.ua.setSelectionRange(Math.min(a,v.length), Math.min(b,v.length)); }catch(e){} }
          }
          // textarea → 행 → 저장. 조합 중에도 부른다 — 쓰는 칸이 아니라 감춰진 행을
          // 고치는 것이라 IME 는 건드리지 않는다. 글은 언제나 즉시 저장 경로에 오른다.
          function uaSync(pad){
            if(!pad.ua || !pad.uaRow) return;
            if(rows(pad).indexOf(pad.uaRow)<0){ uaLoad(pad, false, true); return; }
            uaWrite(pad, pad.uaRow, pad.ua.value);
            onEdit(pad);
          }
          // 새 덩어리 — 머리의 ＋ 버튼에서만 온다(2026-08-16 이후 키보드 길은 없다).
          // 만들기 전에 지금 글을 행에 반영한다(자리를 옮기다 글이 사라지지 않게).
          // 빈 덩어리라 첫 글자를 치는 순간 날짜·시각이 머리에 붙는다(uaStampApply).
          function uaNew(pad){
            uaSync(pad);
            var row=makeRow(pad,'',null,'');
            pad.doc.appendChild(row);
            onEdit(pad, true);
            ultraMark(pad, row);
            uaLoad(pad, true, true);
          }
          // ── 날짜·시각 머리글 ───────────────────────────────────────────
          // 초집중에는 제목 칸이 없다. 그래서 빈 덩어리에 글을 쓰기 시작하면 그 위에
          // '2026-08-13 (목) 12:30' 한 줄이 자동으로 붙어 제목 자리를 대신한다
          // (제목 없이 내용만 있는 줄이 목록에서 빈 줄로 보이던 문제도 같이 사라진다).
          // 판정은 글자가 들어오기 전(beforeinput), 삽입은 조합이 아닌 순간에만 —
          // 한글 조합 중에 value 를 건드리면 글자가 깨진다.
          function stampNow(){
            var T=window.CMTimeFilter||null, p=null;
            if(T && T.parts){ try{ p=T.parts(now()); }catch(e){ p=null; } }
            if(!p){ var d=new Date();
              p={y:d.getFullYear(),mo:d.getMonth()+1,d:d.getDate(),
                 h:d.getHours(),mi:d.getMinutes(),wd:d.getDay()}; }
            var WD=['일','월','화','수','목','금','토'];
            return p.y+'-'+p2(p.mo)+'-'+p2(p.d)+' ('+WD[p.wd]+') '+p2(p.h)+':'+p2(p.mi);
          }
          function uaStampMark(pad, ev){
            if(pad.uaStamping || pad.uaWant) return;
            var t=(ev && ev.inputType)||'';
            if(t && t.indexOf('insert')!==0) return;              // 지우기·서식은 새 글이 아니다
            if(t==='insertLineBreak' || t==='insertParagraph') return;
            if(pad.ua.value.trim()) return;                       // 빈 덩어리에서 시작할 때만
            pad.uaWant=true;
          }
          function uaStampApply(pad){
            if(!pad.uaWant || pad.uaComposing || pad.uaStamping) return;
            var ta=pad.ua, v=ta.value;
            pad.uaWant=false;
            if(!v.trim()) return;                                  // 도로 비었다 — 없던 일로
            var head=stampNow()+'\n';
            var a=ta.selectionStart, b=ta.selectionEnd;
            pad.uaStamping=true;
            var ok=false;
            // execCommand 로 넣어야 textarea 의 네이티브 되돌리기가 끊기지 않는다 —
            // 머리글이 마음에 안 들면 ⌘Z 한 번.
            try{ ta.setSelectionRange(0,0);
                 ok=document.execCommand('insertText', false, head); }catch(e){ ok=false; }
            if(!ok) ta.value=head+v;
            try{ ta.setSelectionRange(a+head.length, b+head.length); }catch(e){}
            pad.uaStamping=false;
            uaSync(pad);
          }
          // ── 필드 필터 ──────────────────────────────────────────────────
          // 보기(상태)와 다른 축 — 칸에 적힌 '값' 으로 거른다. "ismail 이 맡은 것만",
          // "이 프로젝트만", "목표일이 오늘인 것만". 같은 칸 안에서 여러 값을 고르면
          // 그중 하나(OR), 칸이 다르면 모두 만족(AND). 감춤은 보기 필터와 같은 원칙 —
          // 행에 data-fx 를 달아 CSS 로만 숨긴다. 텍스트도 일련번호도 그대로다.
          // 완전히 빈 줄은 거르지 않는다 — 필터를 걸어 둔 채로도 이어 쓸 자리는 남는다.
          var TAGK=FIELDS.filter(function(f){ return f.tag; }).map(function(f){ return f.k; });
          // 상태의 진실은 메모리(fltState) — localStorage 는 다음에 열 때를 위한 best-effort
          // 영속일 뿐이다. 저장소가 막힌 웹뷰에서도 필터 자체는 동작해야 한다.
          var fltState=null;
          function fltGet(){
            if(fltState) return fltState;
            try{ var v=JSON.parse(localStorage.getItem('cmMemoFlt')||'');
                 if(v && v.t){ fltState={ t:v.t, due:v.due==='today' ? 'today' : '' };
                               return fltState; } }catch(e){}
            fltState={ t:{}, due:'' };
            return fltState;
          }
          function fltSet(F){
            fltState=F;
            try{ localStorage.setItem('cmMemoFlt', JSON.stringify(F)); }catch(e){}
            meta(stat()); fltBtnPaint();
          }
          function fltCount(F){
            var n=F.due ? 1 : 0;
            TAGK.forEach(function(k){ n+=(F.t[k]||[]).length; });
            return n;
          }
          function fltToggle(k, name){
            var F=fltGet(), sel=F.t[k]||[], i=sel.indexOf(name);
            if(i<0) sel.push(name); else sel.splice(i,1);
            F.t[k]=sel; fltSet(F);
          }
          function fltDueToggle(){ var F=fltGet(); F.due=F.due ? '' : 'today'; fltSet(F); }
          function fltClear(){ fltSet({ t:{}, due:'' }); }
          // '오늘' 은 표시 타임존의 오늘이다 — 목표일 칸이 화면에 보여 주는 그 시계와 같은
          // 시계로 비교해야 "화면에는 오늘인데 필터에는 안 걸린다" 가 생기지 않는다.
          function todayStr(){
            var T=tzMod(), sec=Math.floor((Date.now?Date.now():new Date().getTime())/1000);
            if(T && T.epochToInput){ try{ return T.epochToInput(sec).slice(0,10); }catch(e){} }
            var d=new Date();
            return d.getFullYear()+'-'+p2(d.getMonth()+1)+'-'+p2(d.getDate());
          }
          function fltMatch(F, f){
            for(var i=0;i<TAGK.length;i++){
              var sel=F.t[TAGK[i]]||[];
              if(sel.length && sel.indexOf(f[TAGK[i]]||'')<0) return false;
            }
            if(F.due){
              var v=f['목표일'];
              if(!v || toDisp(v).slice(0,10)!==todayStr()) return false;
            }
            return true;
          }
          // 지금 메모에 실제로 쓰인 값들이 곧 후보다 — 따로 사전을 묻지 않아도 한 번
          // 적어 둔 담당·팀·프로젝트가 바로 필터가 된다. 골라 뒀는데 지금은 안 쓰이는
          // 값(0건)도 목록에 남긴다 — 그래야 해제할 길이 있다.
          function fltCands(pad, k){
            var m={}, F=fltGet();
            rows(pad).forEach(function(row){
              var v=(fieldsOf(row)[k]||'').trim();
              if(v) m[v]=(m[v]||0)+1;
            });
            (F.t[k]||[]).forEach(function(v){ if(!(v in m)) m[v]=0; });
            return Object.keys(m).sort(function(a,b){ return m[b]-m[a] || (a<b?-1:1); })
                         .map(function(n){ return { name:n, count:m[n] }; });
          }
          function fltBtnPaint(){
            var n=fltCount(fltGet());
            pads.forEach(function(p){
              if(!p.flt) return;
              if(n) p.flt.dataset.on='1'; else delete p.flt.dataset.on;
              if(p.fltN) p.fltN.textContent=n;
            });
          }

          // ── 텍스트 ↔ 행 ────────────────────────────────────────────────
          // 규칙 하나뿐: 4칸(또는 탭) 이상 들여쓴 줄은 바로 앞 줄의 상세. 앞 줄이 없으면
          // 그냥 평문으로 둔다 — 파싱이 애매할 때 글을 버리지 않는 쪽으로.
          function parse(s){
            var out=[], last=null;
            (s||'').split('\n').forEach(function(line){
              var det=/^(\s{4}|\t)(.*)$/.exec(line);
              if(det && last){
                var f=FRE.exec(det[2]);
                if(f && f[1]==='링크'){
                  // 옛 통합 링크 칸 — 호스트를 읽어 지라/노션/슬랙 칸으로 옮겨 담는다.
                  // 못 알아보는 링크(깃허브 등)나 이미 찬 칸은 상세 줄로 남긴다 —
                  // 파서의 원칙 그대로, 애매할 때 글을 버리지 않는 쪽으로.
                  var kk=linkKind(f[2]), dk=kk && LK2F[kk.k];
                  if(dk && !last.fields[dk]){ last.fields[dk]=f[2]; return; }
                  last.detail.push(det[2]); return;
                }
                if(f && f[1]==='골'){
                  // 줄의 골번호 — 칸이 아니라 행의 정체성이다. 첫 유효 번호만 싣고,
                  // 중복·이상값은 상세 줄로 남긴다(애매할 때 글을 버리지 않는다).
                  var gn=pnum(f[2]);
                  if(gn>0 && !last.gno){ last.gno=gn; return; }
                  last.detail.push(det[2]); return;
                }
                if(f && f[1]==='루프'){
                  // 이전 루프 스탬프 — 완료 줄의 첫 유효 값(보드 루프 코드)만 싣는다.
                  // 미완료 줄에 남은 스탬프(직접 편집·옛 병합)나 중복은 상세 줄로 남긴다 —
                  // 스탬프로 읽으면 그 줄이 기본 보기에서 사라진다(애매할 때 글을 버리지 않는다).
                  var ln=lcode(f[2]);
                  if(ln && !last.lno && last.st==='done'){ last.lno=ln; return; }
                  last.detail.push(det[2]); return;
                }
                if(f && f[1]==='생성'){
                  // 만든 순간의 스탬프 — 첫 유효 값만 싣는다. 중복·이상값은 상세로 남긴다
                  // (루프 스탬프와 같은 방어: 스탬프로 잘못 읽으면 줄이 기본 보기에서 사라진다).
                  var cn=ccode(f[2]);
                  if(cn && !last.cno){ last.cno=cn; return; }
                  last.detail.push(det[2]); return;
                }
                if(f){ last.fields[f[1]]=f[2]; return; }   // @목표일: … 은 칸으로
                last.detail.push(det[2]); return;
              }
              var m=/^-\s\[([ x!])\]\s?(.*)$/.exec(line);
              last={ st: m ? ({' ':'todo','x':'done','!':'block'})[m[1]] : null,
                     text: m ? m[2] : line, detail: [], fields: {}, gno: 0, lno: '', cno: '' };
              out.push(last);
            });
            return out;
          }
          // 한 행에 채워진 칸들. 비어 있는 칸은 저장하지 않는다 — 안 쓴 값이 텍스트에 남지 않도록.
          // 시각 칸은 화면의 벽시계를 여기서 UTC 로 되돌린다 — 저장 텍스트에는 언제나 UTC 만 간다.
          function fieldsOf(row){
            var o={};
            Array.prototype.slice.call(row.querySelectorAll('.cmm-fs input')).forEach(function(i){
              var v=(i.value||'').trim(); if(!v) return;
              o[i.dataset.k] = i.dataset.tz==='1' ? toStore(v) : v;
              if(!o[i.dataset.k]) delete o[i.dataset.k];
            });
            return o;
          }
          function hasFields(row){ for(var k in fieldsOf(row)) return true; return false; }
          // 상세 칸의 글을 줄 단위로 읽는다. textContent 로 읽으면 안 되는 이유: WebKit 의
          // contenteditable 은 줄바꿈을 <div>/<br> 로 만들기 때문에 textContent 는 줄이
          // 통째로 붙어 나온다(= 저장하면 두 줄이 한 줄이 된다).
          function dtText(dt){
            var out=[], line='';
            (function walk(n){
              for(var c=n.firstChild; c; c=c.nextSibling){
                if(c.nodeType===3){ line+=c.nodeValue; continue; }
                if(c.nodeName==='BR'){ out.push(line); line=''; continue; }
                if(/^(DIV|P|LI)$/.test(c.nodeName)){
                  if(line){ out.push(line); line=''; }
                  walk(c);
                  if(line){ out.push(line); line=''; }
                  continue;
                }
                walk(c);
              }
            })(dt);
            if(line) out.push(line);
            // 자식 노드를 못 훑는 환경(테스트 스텁 등)에서는 원래대로 통글을 돌려준다.
            if(!out.length) return dt.textContent||'';
            return out.join('\n');
          }
          // 캐럿(컨테이너+오프셋)이 dtText(dt) 문자열의 몇 글자째인지 — dtText 와 같은
          // 걸음으로 걸어야 좌표가 맞는다(빈 <div> 줄을 떨구는 특성까지 동일). 붙여넣기가
          // 상세를 평문으로 다시 조립할 때 캐럿 자리를 찾는 용도. 못 찾으면 -1.
          function dtOffset(dt, cont, cOff){
            var out=[], line='', hit=-1;
            function here(){ return (out.length ? out.join('\n').length+1 : 0) + line.length; }
            (function walk(n){
              for(var c=n.firstChild; c && hit<0; c=c.nextSibling){
                if(c.nodeType===3){
                  if(c===cont){ hit=here()+Math.min(cOff, c.nodeValue.length); return; }
                  line+=c.nodeValue; continue;
                }
                // 캐럿이 요소 자체에 걸린 경우(줄 경계 클릭) — 그 요소 앞을 자리로 본다.
                if(c===cont){ hit=here(); return; }
                if(c.nodeName==='BR'){ out.push(line); line=''; continue; }
                if(/^(DIV|P|LI)$/.test(c.nodeName)){
                  if(line){ out.push(line); line=''; }
                  walk(c);
                  if(hit>=0) return;
                  if(line){ out.push(line); line=''; }
                  continue;
                }
                walk(c);
              }
            })(dt);
            return hit;
          }
          function lineOf(row){
            var st=row.dataset.st, out=[st ? TOKEN[st]+row.querySelector('.cmm-tx').textContent
                                             : row.querySelector('.cmm-tx').textContent];
            // 골번호는 칸보다 먼저 — 행의 정체성이라 들여쓴 줄 맨 위에 둔다.
            if(row.dataset.gno) out.push(IND+'@골: '+row.dataset.gno);
            if(row.dataset.lp) out.push(IND+'@루프: '+row.dataset.lp);
            var crAt=out.length;                 // 생성 스탬프 자리 — 내용이 있을 때만 채운다
            var f=fieldsOf(row);
            FIELDS.forEach(function(d){ if(f[d.k]) out.push(IND+'@'+d.k+': '+f[d.k]); });
            var d=dtText(row.querySelector('.cmm-dt')).replace(/\s+$/,'');
            if(d.trim()) d.split('\n').forEach(function(l){ out.push(IND+l); });
            // 생성 스탬프 — 완전히 빈 줄에는 싣지 않는다(글도 없는 자리에 들여쓴 줄만
            // 떠다닌다). 내용의 기준은 crBlank 와 같아야 한다: 다르면 '싣지는 않는데 새
            // 줄로도 안 보는' 줄이 생겨 저장할 때마다 스탬프가 새로 찍힌다.
            if(row.dataset.cr && (st || out[0] || out.length>crAt))
              out.splice(crAt, 0, IND+'@생성: '+row.dataset.cr);
            return out.join('\n');
          }
          function isRow(n){ return n && n.classList && n.classList.contains('cmm-row')
                             && n.querySelector && n.querySelector('.cmm-tx') && n.querySelector('.cmm-dt'); }
          // 편집면을 통째로 읽는다. ⌘A 로 지우거나 붙여넣다가 브라우저가 만들어 놓은 낯선
          // 노드가 섞여 있어도 글자는 건진다 — 구조를 못 알아보면 그 노드의 텍스트를 평문 줄로 본다.
          function serialize(pad){
            var out=[];
            Array.prototype.slice.call(pad.doc.childNodes).forEach(function(n){
              if(n.nodeType===3){ if(n.nodeValue.replace(/\s/g,'')) out.push(n.nodeValue); return; }
              if(isRow(n)){ out.push(lineOf(n)); return; }
              (n.textContent||'').split('\n').forEach(function(l){ out.push(l); });
            });
            return out.join('\n');
          }
          // 구조가 깨졌으면(=행이 아닌 자식이 생겼으면) 텍스트만 건져 다시 그린다.
          // 글도 캐럿도 잃지 않는다 — 다시 그리기 전에 '몇 번째 행 · 몇 글자째' 를 적어 두고
          // 그대로 되돌려 놓는다. (예전에는 무조건 맨 아랫줄 끝으로 보냈는데, 문서 중간을
          // 고치던 손이 갑자기 맨 밑으로 끌려가는 게 이 편집기의 가장 흔한 불평이었다.)
          function normalize(pad){
            var kids=Array.prototype.slice.call(pad.doc.childNodes);
            var bad = !kids.length || kids.some(function(n){ return n.nodeType===3 ? !!n.nodeValue.replace(/\s/g,'') : !isRow(n); });
            if(!bad) return false;
            var c=caretSnap(pad);
            render(pad, serialize(pad));
            if(c) caretRestore(pad, c);
            else { var last=pad.doc.lastElementChild; if(last) caretEnd(last.querySelector('.cmm-tx')); }
            return true;
          }
          function rows(pad){ return Array.prototype.slice.call(pad.doc.children); }

          function makeRow(pad, text, st, detail, fields, gno, lno, cno){
            var row=document.createElement('div');
            row.className='cmm-row'; if(st) row.dataset.st=st;
            // 골번호 — 저장 텍스트의 '@골: N' 에서 온 행의 영속 번호. 없으면 채번이 채운다.
            if(gno>0) row.dataset.gno=gno;
            // 이전 루프 스탬프 — 완료 줄에만 싣는다(parse 와 같은 방어). 값은 보드 루프 코드.
            if(lno && st==='done') row.dataset.lp=lno;
            // 생성 스탬프 — 없으면 다음 저장(crStampNew)이 '지금' 으로 찍는다.
            if(cno) row.dataset.cr=cno;

            var ln=document.createElement('div'); ln.className='cmm-ln';
            var ck=document.createElement('button');
            ck.type='button'; ck.className='cmm-ck'; ck.tabIndex=-1;
            // 편집면 안의 위젯은 통째로 하나의 원자 — 캐럿이 그 안으로 들어가지 않는다.
            ck.contentEditable='false';
            ck.innerHTML='<span class="cmm-mk"></span><span class="cmm-no"></span>';
            ck.addEventListener('click', function(){
              // 원을 누르는 손짓은 언제나 '이 줄 끝냈다' 는 뜻이다. 평문 줄을 먼저 체크리스트로
              // 승격만 하던 두 단계(2026-08-04)는 첫 클릭에 눈에 보이는 변화가 없어서(todo 의
              // 마크는 빈 문자열이다) "두 번 눌러야 체크가 된다" 는 불평으로 돌아왔다
              // (2026-08-10) — 그래서 평문 줄도 한 번에 완료로 간다. 완료로 건너뛰지 않고
              // 체크리스트로만 만들고 싶을 때는 ⌘⇧K 와 '- ' 타이핑이 그대로 남아 있다.
              if(!row.dataset.st){
                row.dataset.st='done';
                row.dataset.qk='1';    // 평문에서 한 번에 완료된 줄 — 취소는 곧장 평문으로
                onEdit(pad, true); return;
              }
              // 그 줄을 다시 누르면 취소다. 원래 평문이었으니 todo·바틀넥을 거치지 않고
              // 곧바로 평문으로 되돌린다(잘못 누른 손이 세 번 더 누르지 않도록).
              if(row.dataset.qk){ delete row.dataset.qk; setChecklist(pad,row,false); return; }
              var i=STATES.indexOf(row.dataset.st);
              row.dataset.st=STATES[(i+1)%STATES.length];
              // 완료에서 벗어나면 이전 루프에서 꺼내 온다 — 다시 진행하는 일은 현재
              // 루프의 일이다(스탬프가 남으면 완료로 되돌리는 순간 또 묻힌다).
              if(row.dataset.lp && row.dataset.st!=='done') delete row.dataset.lp;
              onEdit(pad, true);
            });
            // .cmm-tx / .cmm-dt 에는 contenteditable 을 걸지 않는다 — 편집 가능 여부는 편집면(.cmm-doc)
            // 하나가 정하고 이들은 그 안의 평범한 블록이다. 그래야 ↑↓ 캐럿 이동, 드래그 선택,
            // ⌘A 가 행 경계를 넘어 브라우저 기본 동작으로 작동한다(행마다 편집 섬을 두면 갇힌다).
            var tx=document.createElement('div');
            tx.className='cmm-tx'; tx.textContent=text||'';
            tx.setAttribute('data-ph', PH);
            var cue=document.createElement('span');
            cue.className='cmm-cue'; cue.textContent='상세'; cue.contentEditable='false';
            // 알약은 "감춘 것 전부" 를 여닫는다 — 칸에 값이 있으면 칸도 같이 열려야
            // 안 보이는 값이 생기지 않는다.
            cue.addEventListener('mousedown', function(e){
              e.preventDefault();
              if(row.dataset.open==='1'||row.dataset.fs==='1'){
                if(row.dataset.fs==='1') closeFields(pad,row);
                if(row.dataset.open==='1') closeDetail(pad,row);
                caretEnd(row.querySelector('.cmm-tx')); return;
              }
              if(hasFields(row)) toggleFields(pad,row,false);
              toggleDetail(pad,row,true);
            });
            // 링크 태그 — 칸이 접혀 있어도 제목 줄에서 보이고, 누르면 바로 그 링크로 간다.
            // 칸이 지라·노션·슬랙으로 나뉘어 있으니 칩도 칸마다 하나씩이다(값이 없는 칸은
            // 칩도 없다). mousedown 처리라 캐럿이 흔들리지 않고, 앱 웹뷰에서는 window.open
            // 이 기본 브라우저로 넘긴다(AppWindowController 의 createWebViewWith).
            var lks=FIELDS.filter(function(d){ return d.link; }).map(function(d){
              var lk=document.createElement('a');
              lk.className='cmm-lk'; lk.contentEditable='false'; lk.rel='noopener';
              lk.dataset.k=d.k;
              lk.addEventListener('mousedown', function(e){
                e.preventDefault(); e.stopPropagation();
                var u=lk.getAttribute('data-u'); if(u) window.open(u,'_blank');
              });
              return lk;
            });
            ln.appendChild(ck); ln.appendChild(tx);
            lks.forEach(function(lk){ ln.appendChild(lk); });
            ln.appendChild(cue);

            // 상세는 늘 DOM 에 있고 CSS 로만 접힌다 — 접었다 펴도 글이 사라질 여지가 없다.
            var dt=document.createElement('div');
            dt.className='cmm-dt'; dt.textContent=detail||'';

            // 칸도 늘 DOM 에 있고 CSS 로만 접힌다. 편집면 안의 <input> 이므로 contenteditable=false
            // 로 원자 취급해야 캐럿이 안으로 흘러들어 구조를 밟지 않는다.
            var fs=document.createElement('div');
            fs.className='cmm-fs'; fs.contentEditable='false'; fs.dataset.cmmFs='1';
            var got=fields||{}, any=false;
            // 번호 칸(2026-08-08) — 이 줄의 골번호 표찰. FIELDS 밖이다: 편집 칸이 아니고
            // 저장도 이미 '@골: N' 행 정체성으로 나간다. 값은 paint 가 채운다.
            var glb=document.createElement('label');
            var gcap=document.createElement('span'); gcap.textContent='번호';
            var gv=document.createElement('span'); gv.className='cmm-gno'; gv.textContent='—';
            glb.appendChild(gcap); glb.appendChild(gv); fs.appendChild(glb);
            FIELDS.forEach(function(d){
              var lb=document.createElement('label');
              var cap=document.createElement('span'); cap.textContent=d.k;
              // 시각 칸에는 지금 어느 시계로 보고 있는지를 이름 옆에 적어 둔다 — 같은 값을
              // 다른 타임존에서 열면 이 라벨과 함께 시각도 달라진다는 걸 눈으로 알 수 있게.
              if(d.tz){ var tzs=document.createElement('em'); tzs.className='cmm-tz';
                        tzs.textContent=tzLabel(); cap.appendChild(tzs);
                        lb.title='저장은 UTC 기준 — 화면 표기만 표시 타임존('+tzLabel()+')을 따릅니다.'; }
              // 링크 칸 이름 옆에는 주소 검증 결과가 붙는다(맞으면 성격, 아니면 확인 요청)
              // — paint 가 채운다. data-link 값은 그 칸이 기대하는 서비스 키다.
              if(d.link){ lb.dataset.link=d.link;
                          var lkk=document.createElement('em'); lkk.className='cmm-lkk';
                          lkk.dataset.k=d.k; cap.appendChild(lkk); }
              // 부모 칸 이름 옆에는 적은 골번호의 제목이 붙는다 — paint 가 채운다.
              if(d.pno){ var pk=document.createElement('em'); pk.className='cmm-pk';
                         pk.dataset.k=d.k; cap.appendChild(pk); }
              lb.appendChild(cap);
              var inp=document.createElement('input');
              inp.type=d.t; inp.dataset.k=d.k; inp.placeholder=d.ph||'';
              if(d.tz) inp.dataset.tz='1';
              inp.value = d.tz ? toDisp(got[d.k]) : (got[d.k]||'');
              if(got[d.k]) any=true;
              // 편집면의 input 핸들러까지 올라가면 같은 저장이 두 번 돈다 — 여기서 끊는다.
              inp.addEventListener('input', function(e){ e.stopPropagation(); paint(pad); onEdit(pad); });
              // 담당·팀·프로젝트는 사전에서 고른다 — 타이핑이 멎으면 비슷한 이름이 뜬다.
              if(d.tag){ lb.dataset.tag='1'; wireTag(pad, row, inp); }
              // 부모 칸은 후보 목록에서 고른다 — 최근 쓴 번호가 맨 위, 그 아래 AI 추천.
              if(d.pno){ wireParent(pad, row, inp); }
              lb.appendChild(inp); fs.appendChild(lb);
            });

            row.appendChild(ln); row.appendChild(fs); row.appendChild(dt);
            // 값이 있어도 처음에는 접어 둔다 — 목록은 제목만 보이는 게 원칙이다.
            // 대신 알약이 '필드' 라고 알려 주고, 알약을 누르면 값이 있는 칸이 함께 열린다.
            if(detail || any) row.dataset.has='1';
            return row;
          }
          function setChecklist(pad,row,on){
            if(on){ if(!row.dataset.st) row.dataset.st='todo'; }
            else { delete row.dataset.st;
                   // 평문에는 루프 스탬프도 없다 — 남으면 CSS 감춤에 걸려 글이 사라져 보인다.
                   delete row.dataset.lp; }
            onEdit(pad, true);
          }
          // 상세 열고 닫기. 열면 커서를 상세로 옮긴다 — ⌘Enter 치자마자 바로 쓸 수 있게.
          function toggleDetail(pad,row,focus){
            if(row.dataset.open==='1'){ closeDetail(pad,row); return; }
            row.dataset.open='1';
            if(focus) caretEnd(row.querySelector('.cmm-dt'));
            onEdit(pad);
          }
          function closeDetail(pad,row){
            delete row.dataset.open;
            // 비어 있으면 흔적을 남기지 않는다 — 실수로 연 상세가 알약으로 남지 않도록.
            if(!dtText(row.querySelector('.cmm-dt')).trim() && !hasFields(row)) delete row.dataset.has;
            onEdit(pad);
          }
          // 칸(목표일·담당·팀·프로젝트) 열고 닫기. 열면 첫 칸으로 바로 들어간다.
          function toggleFields(pad,row,focus){
            if(row.dataset.fs==='1'){ closeFields(pad,row); return; }
            row.dataset.fs='1';
            if(focus){ var i=row.querySelector('.cmm-fs input'); if(i && i.focus) i.focus(); }
            onEdit(pad);
          }
          function closeFields(pad,row){
            delete row.dataset.fs;
            if(sugRow===row) sugClose();      // 칸이 접히면 그 위에 떠 있던 후보도 같이 사라진다
            if(!dtText(row.querySelector('.cmm-dt')).trim() && !hasFields(row)) delete row.dataset.has;
            onEdit(pad);
          }
          // 편집면은 이제 .cmm-doc 하나뿐이라 포커스는 그쪽에 준다(행은 편집 가능하지 않다).
          function editHost(el){
            var n=el; while(n && !(n.isContentEditable || (n.getAttribute && n.getAttribute('contenteditable')==='true'))) n=n.parentElement;
            return n||el;
          }
          function caretEnd(el){
            var h=editHost(el); if(h.focus) h.focus();
            try{ var r=document.createRange(); r.selectNodeContents(el); r.collapse(false);
                 var s=getSelection(); s.removeAllRanges(); s.addRange(r); }catch(e){}
          }
          // 글자 수(off)로 캐럿을 놓는다. 첫 텍스트 노드만 보면 안 되는 이유: 상세 칸은
          // WebKit 이 <div>/<br> 로 여러 노드에 나눠 담아서, 두 번째 줄 이후의 자리를
          // 영영 못 찾는다(= 되돌리기 뒤 캐럿이 늘 첫 줄로 튄다).
          function caretTo(el, off){
            var h=editHost(el); if(h.focus) h.focus();
            try{ var left=off, node=null, at=0;
                 (function walk(n){
                   for(var c=n.firstChild; c && node===null; c=c.nextSibling){
                     if(c.nodeType===3){
                       if(left<=c.nodeValue.length){ node=c; at=left; return; }
                       left-=c.nodeValue.length;
                     } else if(c.nodeName==='BR'){ left-=1; }
                     else walk(c);
                   }
                 })(el);
                 var r=document.createRange();
                 if(node) r.setStart(node, at);
                 else { r.selectNodeContents(el); r.collapse(off<=0); }
                 r.collapse(true);
                 var s=getSelection(); s.removeAllRanges(); s.addRange(r); }catch(e){}
          }
          // 캐럿이 줄 맨 앞인가 — 합치기(Backspace)를 할지 판단하는 유일한 근거.
          function caretAt0(el){
            try{ var s=getSelection(); if(!s || !s.rangeCount || !s.isCollapsed) return false;
                 var r=s.getRangeAt(0).cloneRange();
                 r.selectNodeContents(el); r.setEnd(s.getRangeAt(0).startContainer, s.getRangeAt(0).startOffset);
                 return r.toString().length===0; }catch(e){ return false; }
          }
          // 캐럿이 줄 맨 끝인가 — Delete(앞으로 지우기)로 아랫줄을 끌어올릴지 판단한다.
          function caretAtEnd(el){
            try{ var s=getSelection(); if(!s || !s.rangeCount || !s.isCollapsed) return false;
                 var r=s.getRangeAt(0).cloneRange();
                 r.selectNodeContents(el); r.setStart(s.getRangeAt(0).endContainer, s.getRangeAt(0).endOffset);
                 return r.toString().length===0; }catch(e){ return false; }
          }
          // 캐럿의 위치를 '몇 번째 행 · 어느 칸 · 몇 글자째' 로 적어 둔다. 다시 그린 뒤에도
          // 같은 자리로 돌아오기 위한 좌표 — DOM 노드는 사라지지만 이 셋은 살아남는다.
          function caretSnap(pad){
            var el=cellAt(pad); if(!el) return null;
            var row=el.parentElement;
            while(row && !(row.classList && row.classList.contains('cmm-row'))) row=row.parentElement;
            if(!row) return null;
            var off=0;
            try{ var s=getSelection();
                 if(s && s.rangeCount){ var q=document.createRange();
                   q.selectNodeContents(el); q.setEnd(s.getRangeAt(0).endContainer, s.getRangeAt(0).endOffset);
                   off=q.toString().length; } }catch(e){}
            return { i:rows(pad).indexOf(row), c: el.classList.contains('cmm-dt') ? 'dt' : 'tx', o:off };
          }
          function caretRestore(pad, c){
            var rs=rows(pad); if(!rs.length) return;
            var row=rs[Math.max(0, Math.min(c ? c.i : rs.length-1, rs.length-1))];
            if(!row) return;
            // 되돌린 상태에서 상세가 접혀 있으면 제목으로 데려온다 — 안 보이는 칸에 캐럿을
            // 두면 글자가 어디로 들어가는지 사람이 알 수 없다.
            var wantDt = c && c.c==='dt';
            if(wantDt && row.dataset.open!=='1'){ row.dataset.open='1'; row.dataset.has='1'; }
            caretTo(row.querySelector(wantDt ? '.cmm-dt' : '.cmm-tx'), c ? c.o : 0);
          }

          // ── 되돌리기(⌘Z) / 다시 실행(⌘⇧Z) ────────────────────────────────
          // 직접 만든다. 이 편집면은 행을 코드로 조립하고 지우기 때문에(row.remove(),
          // textContent 대입) WebKit 의 네이티브 undo 스택이 그 사이에 끊긴다 — ⌘Z 를
          // 브라우저에 맡기면 되돌아가기는커녕 행 구조가 반쯤 부서진 상태가 나온다.
          // 되돌리는 단위는 '저장 텍스트 + 캐럿 좌표' 한 벌. 텍스트가 곧 진실이므로
          // 스냅숏만 다시 그리면 어떤 편집이었든 정확히 원상 복귀한다.
          var undoS=[], redoS=[], histCur=null, histAt=0, histT0=0, HIST=500,
              COALESCE=550, CHUNK_MAX=3000;
          function now(){ return Date.now ? Date.now() : new Date().getTime(); }
          function histReset(t){ undoS=[]; redoS=[]; histCur={t:t||'', c:null}; histAt=0; histT0=0; }
          // 타이핑은 글자마다 한 단계씩 쌓지 않는다(⌘Z 를 스무 번 눌러야 한 단어가 지워지면
          // 아무도 안 쓴다) — 0.55초 안에 이어진 입력은 한 덩어리로 묶는다. 구조가 바뀌는
          // 편집(줄 합치기·삭제·붙여넣기·상태 토글)은 묶지 않고 언제나 한 단계다.
          // 단, 덩어리에는 3초 상한이 있다(2026-08-06): 쉼 없이 이어 친 장문이 통째로 한
          // 덩어리가 되면 ⌘Z 한 번에 전부 사라진다 — 그 사고가 실제로 났다. 오래 이어진
          // 타이핑은 3초마다 끊어 쌓아, 길게 쓴 글일수록 되돌리기가 잘게 걸린다.
          // keep=true 는 프로그램이 일으킨 변경(골번호 스탬프·백그라운드 병합) — '다시 실행'
          // 갈래를 끊지 않는다. 사람이 ⌘Z 로 돌아간 직후 백그라운드 작업이 끼어들어도
          // ⌘⇧Z 로 제 글을 되찾는 길이 남아야 한다.
          function histNote(pad, nt, struct, keep){
            if(!histCur){ histCur={t:nt, c:caretSnap(pad)}; return; }
            if(histCur.t===nt){ histCur.c=caretSnap(pad); return; }
            var t=now();
            if(!keep) redoS=[];                      // 새로 쓰는 순간 '다시 실행' 갈래는 끊긴다
            if(struct || !histAt || (t-histAt)>COALESCE || (histT0 && (t-histT0)>CHUNK_MAX)){
              undoS.push(histCur);
              if(undoS.length>HIST) undoS.shift();
              histT0 = struct ? 0 : t;               // 새 덩어리의 시작 시각
            }
            histAt = struct ? 0 : t;                 // 구조 편집 뒤의 타이핑은 새 덩어리로
            histCur={ t:nt, c:caretSnap(pad) };
          }
          function histApply(pad, s){
            text=s.t;
            pads.forEach(function(p){ render(p, text); });
            histCur={ t:s.t, c:s.c }; histAt=0; histT0=0;
            caretRestore(pad, s.c);
            meta(stat()); schedule();
          }
          function undo(pad){
            if(!undoS.length) return false;
            redoS.push({ t:serialize(pad), c:caretSnap(pad) });
            histApply(pad, undoS.pop());
            return true;
          }
          function redo(pad){
            if(!redoS.length) return false;
            undoS.push({ t:serialize(pad), c:caretSnap(pad) });
            histApply(pad, redoS.pop());
            return true;
          }

          // ── 골번호 ─────────────────────────────────────────────────────
          // 체크리스트 줄, 그리고 상세·칸을 단 줄(2026-08-08 — 내용을 갖춘 줄은 번호로
          // 지목될 자격이 있다)인데 아직 골번호가 없는 줄 수만큼 서버에 예약을 청한다
          // (POST /api/memo/seq — 보드와 같은 번호 공간, ReviewStore 가 민트). 받은 번호를
          // 문서 순서대로 박고 저장을 건다. 실패는 조용히 — 다음 편집이 다시 청한다(스텁·
          // 오프라인에서는 영영 안 와도 된다: 위치 번호 폴백이 있다).
          function wantsGno(r){ return !!(r.dataset.st || r.dataset.has==='1'); }
          var allocBusy=false, allocT=null;
          function allocGoalNos(){
            if(allocBusy || !loaded || !pads.length) return;
            var p=pads[0];
            var need=rows(p).filter(function(r){ return wantsGno(r) && !r.dataset.gno; });
            if(!need.length) return;
            allocBusy=true;
            fetch('/api/memo/seq',{method:'POST',headers:{'Content-Type':'application/json'},
                                   body:JSON.stringify({count:need.length})})
              .then(function(r){ return r.json(); })
              .then(function(j){ allocBusy=false;
                if(!j || !j.ok || !j.seqs || !j.seqs.length) return;
                var used=0;
                need.forEach(function(r){
                  if(used>=j.seqs.length) return;
                  // 그 사이 지워졌거나 자격이 풀렸거나(체크 해제+내용 삭제) 이미 받았으면 건너뛴다.
                  if(!p.doc.contains(r) || !wantsGno(r) || r.dataset.gno) return;
                  r.dataset.gno=j.seqs[used++];
                });
                if(!used) return;
                text=serialize(p);
                // 스탬프도 되돌리기 한 단계 — 단 keep: 프로그램의 변경이 사람의 ⌘⇧Z 를 끊으면 안 된다.
                if(pads[0]) histNote(pads[0], text, true, true);
                pads.forEach(function(q){ if(q!==p) render(q, text); });
                meta(stat()); schedule();
              })
              .catch(function(){ allocBusy=false; });
          }
          function allocSoon(){
            if(allocT) clearTimeout(allocT);
            allocT=setTimeout(function(){ allocT=null; allocGoalNos(); }, 800);
          }

          // 보드(트래커) 골 제목 조회 — 부모 칸에 적힌 번호가 메모 안에 없으면 /data.json 의
          // goals 에서 찾는다. 게으르게 한 번 받고 60초 캐시. 실패는 조용히(스텁 환경).
          var bgMap=null, bgAt=0, bgBusy=false, bgLoop=null;
          function boardFetch(){
            var t=(Date.now?Date.now():new Date().getTime());
            if(bgBusy || (bgMap && t-bgAt<60000)) return;
            bgBusy=true;
            fetch('/data.json').then(function(r){ return r.json(); }).then(function(j){
              bgBusy=false; bgAt=(Date.now?Date.now():new Date().getTime());
              var m={};
              ((j&&j.goals)||[]).forEach(function(g){ if(g && g.seq>0) m[g.seq]=g.text||''; });
              bgMap=m;
              // 루프 코드 — 보드와 같은 일련번호(2026-08-07). 현재 = 열린 스프린트 중 가장
              // 이른 번호의 코드(완료 컷의 이월이 향하는 그 루프), 이전 = 최신 릴리즈 코드.
              var open=((j&&j.sprints)||[]).filter(function(s){ return s && !s.closed && s.number>0 && s.code; })
                        .sort(function(a,b){ return a.number-b.number; })[0];
              var rel=((j&&j.releases)||[])[0];
              bgLoop={ cur:(open&&open.code)||'', prev:(rel&&rel.code)||'' };
              meta(stat());                       // 꼬리표·루프 표기를 새 지식으로 다시 그린다
            }).catch(function(){ bgBusy=false; bgAt=(Date.now?Date.now():new Date().getTime()); });
          }
          function goalTitle(no, byNo){
            if(byNo && byNo[no]!=null) return byNo[no];
            if(bgMap && bgMap[no]!=null) return bgMap[no];
            return null;
          }

          // ── 부모 기반 표시(구조) ────────────────────────────────────────
          // UI 콤보의 구조 섹션. '@부모: 골번호' 를 따라 자식을 부모 바로 아래로 모은다.
          // 부모의 부모로 이어지면 단이 깊어진다(표시는 3단까지 들여쓰기). 메모 밖(보드)의
          // 골을 부모로 적은 줄은 제자리에 남는다 — 표시 전용이라 순서(order)·들여쓰기만
          // 바꾸고 저장 텍스트는 그대로다. 순환 참조는 걷지 않고 제자리에 남긴다.
          function treePaint(pad){
            var list=rows(pad), on=pad.el.getAttribute('data-grp')==='tree';
            if(!on){ list.forEach(function(r){ r.style.order=''; r.removeAttribute('data-tdep'); }); return; }
            var byNo={}, kids={}, roots=[];
            list.forEach(function(r){ var g=+r.dataset.gno||0; if(g && !byNo[g]) byNo[g]=r; });
            list.forEach(function(r){
              var pn=pnum(fieldsOf(r)['부모']||''), par=pn && byNo[pn];
              if(par && par!==r){ (kids[pn]=kids[pn]||[]).push(r); }
              else roots.push(r);
            });
            var i=0, seen={};
            function walk(r, d){
              var g=+r.dataset.gno||0;
              if(g){ if(seen[g]) return; seen[g]=1; }
              i++; r.style.order=i; r.setAttribute('data-tdep', Math.min(d,3));
              if(g && kids[g]) kids[g].forEach(function(c){ walk(c, d+1); });
            }
            roots.forEach(function(r){ walk(r, 0); });
            // 순환에 갇혀 한 번도 못 걸은 줄 — 문서 순서 그대로 맨 뒤에 둔다.
            list.forEach(function(r){ if(!r.style.order){ i++; r.style.order=i; r.setAttribute('data-tdep',0); } });
          }

          // 위치 번호는 오직 여기서만 생긴다 — 저장 텍스트에는 들어가지 않는다(골번호가 있으면
          // 원에는 골번호가 먼저 보인다).
          function paint(pad){
            var n=0, done=0, block=0, todo=0, lp=0, F=fltGet(), FN=fltCount(F);
            // 생성 날짜 — 오늘부터 7일치 업무일 문자열을 한 번 세어 두고 행마다 나이를 잰다.
            var CK=crKeys(), CM=crMode(), c1=0, c2=0, c7=0, cAll=0;
            // 부모 꼬리표용 — 이 메모 안의 골번호 → 제목.
            var byNo={};
            rows(pad).forEach(function(r){ var g=+r.dataset.gno||0;
              if(g && byNo[g]==null) byNo[g]=r.querySelector('.cmm-tx').textContent; });
            rows(pad).forEach(function(row){
              var dt=row.querySelector('.cmm-dt'), body=dtText(dt).trim();
              var f=fieldsOf(row), fld=false; for(var fk in f){ fld=true; break; }
              // 필드 필터 — 조건과 안 맞는 행을 감춘다. 완전히 빈 줄만 예외(이어 쓸 자리).
              var blank=!row.dataset.st && !body && !fld
                        && !row.querySelector('.cmm-tx').textContent;
              if(FN && !blank && !fltMatch(F, f)) row.dataset.fx='1';
              else delete row.dataset.fx;
              // 생성 날짜 — 고른 범위 밖의 줄을 감춘다(빈 줄은 예외: 이어 쓸 자리).
              // 개수는 범위와 무관하게 늘 센다 — 콤보에서 '넓히면 몇 개가 더 나오나' 를
              // 보고 고르는 것이므로.
              if(!blank){
                var age=crAge(row, CK);
                cAll++;
                if(age===0) c1++;
                if(age>=0 && age<=1) c2++;
                if(age>=0) c7++;
                if(!crFit(age, CM)) row.dataset.cx='1'; else delete row.dataset.cx;
              } else delete row.dataset.cx;
              if(body || fld) row.dataset.has='1';
              else if(row.dataset.open!=='1' && row.dataset.fs!=='1') delete row.dataset.has;
              // 감춰 둔 게 없으면 알약에 글자도 남기지 않는다 — 지우면 흔적 없이 사라져야 한다.
              // (visibility 로만 감추면 CSS 가 페이지 규칙에 밀렸을 때 '상세 0줄' 이 튀어나온다.)
              var open=row.dataset.open==='1'||row.dataset.fs==='1', tag=[];
              if(fld) tag.push('필드');
              if(body) tag.push('상세 '+body.split('\n').length+'줄');
              row.querySelector('.cmm-cue').textContent = open ? '접기' : tag.join(' · ');
              // 링크 칩 — 칸마다 하나. 값이 없으면 흔적도 없다(data-u 를 지우면 CSS 가
              // 칩을 감춘다). 칩의 낯빛은 칸이 정한다(지라 칸=지라 낯빛) — 주소가
              // 이상해도 어느 칸의 링크인지는 한눈에 남는다.
              Array.prototype.slice.call(row.querySelectorAll('.cmm-lk')).forEach(function(lk){
                var fd=FIELDS.filter(function(x){ return x.k===lk.dataset.k; })[0];
                var v=f[lk.dataset.k], kind=linkKind(v);
                if(fd && kind){ var u=String(v).trim();
                          lk.setAttribute('data-u', u); lk.setAttribute('data-lk', fd.link);
                          lk.textContent=fd.k+' ↗';
                          lk.title=u; }
                else { lk.removeAttribute('data-u'); lk.removeAttribute('data-lk');
                       lk.textContent=''; lk.title=''; }
              });
              // 칸 이름 옆의 검증 — 그 서비스 주소가 맞으면 성격(관리·문서·대화)만,
              // 다른 서비스거나 못 알아보는 주소면 '주소 확인' 을 조용히 남긴다(배너 없음).
              Array.prototype.slice.call(row.querySelectorAll('.cmm-lkk')).forEach(function(kEl){
                var fd=FIELDS.filter(function(x){ return x.k===kEl.dataset.k; })[0];
                var v=f[kEl.dataset.k], kind=linkKind(v);
                kEl.textContent = (!fd || !v) ? ''
                                : (kind && kind.k===fd.link) ? (kind.c||'')
                                : '주소 확인';
              });
              // 부모 칸 꼬리표 — 적힌 골번호의 제목(메모 줄 → 보드 골 순서로 찾는다).
              // 어디에도 없으면 '번호 확인' — 그리고 보드 지식이 없으면 게으르게 청해 둔다.
              var pkEl=row.querySelector('.cmm-pk');
              if(pkEl){
                var pv=f['부모']||'';
                if(!pv) pkEl.textContent='';
                else{
                  var pn=pnum(pv), pt=pn ? goalTitle(pn, byNo) : null;
                  if(pt!=null){ pt=String(pt).trim();
                                pkEl.textContent = pt ? (pt.length>16 ? pt.slice(0,16)+'…' : pt) : '#'+pn; }
                  else{ pkEl.textContent='번호 확인'; if(pn && !bgMap) boardFetch(); }
                }
              }
              // 칸 패널의 번호 표찰 — 원 호버와 같은 골번호. 채번 전에는 '—' 로 조용히.
              var gEl=row.querySelector('.cmm-gno');
              if(gEl) gEl.textContent = row.dataset.gno ? '#'+row.dataset.gno : '—';
              var st=row.dataset.st;
              if(!st){
                // 평문 줄도 골번호가 있으면(상세·칸을 단 줄) 원 호버로 드러난다.
                // 없으면 비워 둔다 — :empty 규칙이 빈 알약을 감춘다.
                row.querySelector('.cmm-no').textContent=row.dataset.gno||'';
                return;
              }
              n++;
              row.dataset.no=n;                                 // 위치 번호 — 폴백
              // 원에는 골번호가 먼저다. 채번 전(스텁·오프라인)에만 위치 번호가 보인다.
              row.querySelector('.cmm-no').textContent=row.dataset.gno||n;
              row.querySelector('.cmm-mk').textContent=MARK[st];
              // 이전 루프에 묻힌 줄은 상태 집계에서 뺀다 — 보기 콤보의 완료 개수는
              // '이번 루프에 끝낸 것' 이다(묻힌 것은 '이전 루프' 줄이 따로 센다).
              if(row.dataset.lp) lp++;
              else if(st==='done') done++; else if(st==='block') block++; else todo++;
            });
            treePaint(pad);
            ultraEnsure(pad);   // 다시 그리기·필터 반영 뒤에도 초집중의 '지금 줄' 을 세운다
            // 행이 다시 그려졌으면(병합·복원) 초집중 textarea 도 그 행에 다시 묶는다.
            // 쓰고 있는 손은 덮지 않는다 — uaLoad 가 포커스·조합 중이면 물러난다.
            if(uiMode()==='ultra') uaLoad(pad, false, false);
            return { n:n, done:done, block:block, todo:todo, lp:lp,
                     c1:c1, c2:c2, c7:c7, cAll:cAll };
          }
          // 헤더에는 집계를 늘어놓지 않는다(2026-08-04). 개수는 '보기' 콤보 안에서만 보인다 —
          // 평소 화면은 비워 두고, 숫자는 무엇을 감출지 고를 때만 필요하다.
          var COUNT={n:0,done:0,block:0,todo:0,lp:0,c1:0,c2:0,c7:0,cAll:0};
          function stat(){
            COUNT = pads.length ? paint(pads[0])
                                : {n:0,done:0,block:0,todo:0,lp:0,c1:0,c2:0,c7:0,cAll:0};
            pads.forEach(function(p,i){ if(i) paint(p); });
            if(menuEl && (menuEl.dataset.view==='1'||menuEl.dataset.flt==='1')) paintMenu();
            allocSoon();                                 // 번호 없는 체크리스트 줄이 있으면 채번
            return '';                                   // 평소 메타 자리는 비워 둔다
          }

          function render(pad, s){
            pad.doc.innerHTML='';
            parse(s).forEach(function(it){
              pad.doc.appendChild(makeRow(pad, it.text, it.st, it.detail.join('\n'), it.fields, it.gno, it.lno, it.cno)); });
            if(!pad.doc.children.length) pad.doc.appendChild(makeRow(pad,'',null,'',null));
            paint(pad);
          }

          // ── 로컬 초안: 마지막 그물 ──────────────────────────────────────
          // 저장이 서버에 닿기 전에 웹뷰가 죽으면(창 닫힘·앱 종료) 글이 증발한다. 편집 즉시
          // localStorage 에 같은 글을 적어 두고, 서버가 저장을 확인해 준 뒤에만 지운다.
          // 다음 로드에서 서버보다 새 초안이 남아 있으면 = 지난 저장이 끝내 못 닿은 것 —
          // 서버 글과 합쳐 조용히 복구하고 다시 저장한다(배너 없음 — 앱 규칙).
          function draftWrite(){ try{ localStorage.setItem('cmMemoDraft',
            JSON.stringify({text:text, t:Math.floor(Date.now()/1000)})); }catch(e){} }
          function draftClearIf(t){ try{ var d=JSON.parse(localStorage.getItem('cmMemoDraft')||'');
            if(d && d.text===t) localStorage.removeItem('cmMemoDraft'); }catch(e){} }
          function draftRead(){ try{ var d=JSON.parse(localStorage.getItem('cmMemoDraft')||'');
            return (d && typeof d.text==='string' && typeof d.t==='number') ? d : null; }catch(e){ return null; } }

          // 두 판의 줄 합집합 — 내 줄 순서는 그대로 두고, 상대에게만 있는 줄을 아래에 덧붙인다.
          // 같은 줄이 여러 번 있어도 개수로 맞춰 센다(중복 증식 방지). 지웠던 줄이 드물게
          // 되살아날 수는 있지만, 글이 사라지는 것보다 낫다 — 파서와 같은 원칙("글을 버리지
          // 않는 쪽으로"). 서버 히스토리가 원본 두 판을 다 보관하므로 최악에도 복구 가능.
          function mergeLines(mine, theirs){
            if(!theirs || mine===theirs) return mine;
            if(!mine) return theirs;
            var have={};
            mine.split('\n').forEach(function(l){ have[l]=(have[l]||0)+1; });
            var extra=[];
            theirs.split('\n').forEach(function(l){
              if(have[l]){ have[l]--; return; }
              if(l.replace(/\s/g,'')) extra.push(l);
            });
            return extra.length ? mine+'\n'+extra.join('\n') : mine;
          }
          // 병합/새로고침으로 글이 바뀌었을 때 모든 패드를 다시 그린다 — 캐럿은 제자리에.
          function adopt(t){
            text=t;
            pads.forEach(function(p){ var c=caretSnap(p); render(p, text); if(c) caretRestore(p, c); });
            // keep: 병합·새로고침은 프로그램의 변경 — 사람의 '다시 실행' 갈래를 끊지 않는다.
            if(pads[0]) histNote(pads[0], text, true, true);
          }

          // 저장은 조용히 — 실패해도 배너를 띄우지 않고 화면의 글은 그대로 둔다.
          // 다음 입력이 재시도하고, 입력이 없더라도 3초 뒤 한 번 더 시도한다.
          // base = 마지막으로 본 서버 판번호. 오래 열려 있던 다른 창이 최신 글을 모른 채
          // 통째로 덮어쓰는 사고(전역 메모의 최대 위험)를 서버가 판번호로 걸러 낸다.
          // 판이 어긋나면 서버는 저장하지 않고 현재 글을 돌려주고, 우리는 두 글을 합쳐
          // 새 판으로 다시 민다 — 어느 쪽 글도 버리지 않는다.
          // keepalive: 창이 닫히는 중의 마지막 flush 가 fetch 취소로 증발하지 않게.
          function push(){
            // 첫 GET 전에는 base 도 서버 글도 모른다 — 이대로 저장하면 빈 화면이 서버 글을
            // 덮을 수 있다. 로드가 될 때까지 미룬다(글은 화면과 로컬 초안에 안전하다).
            if(!loaded){ if(!retry) retry=setTimeout(function(){ retry=null; push(); }, 1000); return; }
            pending=true; meta('저장 중…');
            var sent=text;
            draftWrite();
            var payload={text:text}; if(typeof rev==='number') payload.base=rev;
            fetch('/api/memo',{method:'POST',headers:{'Content-Type':'application/json'},
                               body:JSON.stringify(payload), keepalive:true})
              .then(function(r){ return r.json(); })
              .then(function(j){ pending=false; if(retry){ clearTimeout(retry); retry=null; }
                if(j && j.conflict && typeof j.text==='string'){
                  // 다른 창이 먼저 저장했다 — 서버 글과 화면 글을 합쳐 새 판으로 다시 민다.
                  if(typeof j.rev==='number') rev=j.rev;
                  var m=mergeLines(text, j.text);
                  if(m!==text) adopt(m);
                  meta(stat()); schedule(); return;
                }
                if(j && typeof j.rev==='number') rev=j.rev;
                if(sent===text){ dirty=false; draftClearIf(sent); stat(); meta('저장됨'); }
                else meta(stat());
                // flush 가 in-flight 뒤에 대기시킨 마지막 글자 — 지금 바로 민다(종료 드레인 중).
                if(flushAfter){ flushAfter=false; if(dirty && !pending) push(); }
              })
              .catch(function(){ pending=false;
                if(!retry) retry=setTimeout(function(){ retry=null; push(); }, 3000);
                if(flushAfter){ flushAfter=false; if(dirty && !pending) push(); }
                meta(stat()); });
          }
          function schedule(){ dirty=true; draftWrite();
            if(timer) clearTimeout(timer); timer=setTimeout(function(){ timer=null; push(); }, 400); }
          // 창이 닫히거나 포커스를 잃을 때 즉시 반영 — 디바운스/재시도 대기 중인 글자를 잃지 않는다.
          // 저장이 이미 날아가는 중이면(pending) 그 완료 직후 한 번 더 민다(flushAfter) —
          // 종료 드레인(네이티브 drainForQuit)이 부를 때 마지막 몇 글자가 in-flight 뒤에
          // 숨어 있다가 프로세스와 함께 죽지 않도록.
          function flush(){
            if(timer){ clearTimeout(timer); timer=null; }
            if(retry){ clearTimeout(retry); retry=null; }
            if(dirty && !pending) push();
            else if(dirty) flushAfter=true;
          }

          // 창이 다시 앞으로 올 때 서버 판을 조용히 맞춰 둔다 — 다른 화면(대시보드 ↔ 대화)에서
          // 쓴 글이 이 창에도 바로 보이고, 무엇보다 몇 시간 낡은 글 위에 타이핑을 시작하는
          // 일이 없어진다(충돌 병합은 그래도 남는 마지막 경주 몇 초의 뒷받침일 뿐).
          // 편집·저장이 걸려 있으면 손대지 않는다. 판번호 없는 서버(옛 빌드·스텁)도 덮지 않는다.
          function refresh(){
            if(!loaded || timer || pending || retry || dirty) return;
            fetch('/api/memo').then(function(r){ return r.json(); }).then(function(j){
              if(timer || pending || dirty) return;
              if(!j || typeof j.text!=='string' || typeof j.rev!=='number') return;
              if(rev===j.rev) return;
              rev=j.rev;
              if(j.text===text) return;
              adopt(j.text);
              meta(stat());
            }).catch(function(){});
          }

          // 편집이 일어난 패드가 진실 — 나머지 패드는 그 텍스트로 다시 그린다.
          // 편집 중인 패드 자신은 다시 그리지 않는다(커서가 튀지 않도록).
          // struct=true 는 '구조가 바뀐 편집' — 줄을 합치거나 지우거나 상태를 토글한 경우.
          // 되돌리기에서 한 덩어리로 묶이지 않고 언제나 한 단계가 된다.
          function onEdit(src, struct){
            crStampNew(src);          // 방금 생긴 줄에 '@생성: 지금' — 저장 텍스트로 나가기 전에
            text=serialize(src);
            histNote(src, text, !!struct);
            meta(stat());
            pads.forEach(function(p){ if(p!==src) render(p, text); });
            schedule();
          }

          // 지금 캐럿이 어느 칸에 있나. 편집면이 .cmm-doc 하나뿐이라 keydown 의 target 은
          // 늘 .cmm-doc 로 온다 — 칸은 이벤트가 아니라 선택 위치에서 찾아야 한다.
          // (이걸 target 으로 보면 Enter 가 우리 손을 안 거치고 브라우저 기본 줄바꿈으로 새어
          //  나가 행 구조가 망가진다.)
          function cellAt(pad){
            var n=null;
            try{ var s=getSelection();
                 if(s && s.rangeCount) n=s.getRangeAt(0).startContainer; }catch(e){}
            if(!n) return null;
            if(n.nodeType===3) n=n.parentElement;
            while(n && n!==pad.doc && !(n.classList &&
                  (n.classList.contains('cmm-tx')||n.classList.contains('cmm-dt')))) n=n.parentElement;
            return (n && n!==pad.doc) ? n : null;
          }

          function onKey(pad, ev){
            // ⌘Z / ⌘⇧Z — 우리 히스토리로 되돌린다. 브라우저보다 먼저 가로채야 한다.
            // (칸 <input> 안에서는 네이티브 undo 가 제대로 도니 그대로 둔다.)
            if((ev.metaKey||ev.ctrlKey) && !ev.altKey && (ev.code==='KeyZ' || ev.key==='z' || ev.key==='Z')){
              if(ev.target && ev.target.tagName==='INPUT') return;
              ev.preventDefault();
              if(ev.shiftKey) redo(pad); else undo(pad);
              return;
            }
            // ⌘⇧Z 대신 ⌘Y 를 쓰는 손도 있다.
            if((ev.metaKey||ev.ctrlKey) && !ev.altKey && ev.code==='KeyY'){
              if(ev.target && ev.target.tagName==='INPUT') return;
              ev.preventDefault(); redo(pad); return;
            }
            // ⌘A — 화면에 보이는 것 전체를 고른다(selectShown 주석 참고).
            if((ev.metaKey||ev.ctrlKey) && !ev.altKey && !ev.shiftKey
               && (ev.code==='KeyA' || ev.key==='a' || ev.key==='A')){
              if(ev.target && ev.target.tagName==='INPUT') return;   // 칸 안에서는 그 칸만
              if(selectShown(pad)) ev.preventDefault();
              return;
            }
            // ⌘A 로 고른 화면 전체를 지울 때는 우리가 지운다. 브라우저에 맡기면 첫 줄과
            // 마지막 줄 '사이에' 감춰져 있던 줄까지 범위 안이라 함께 지워진다 — 보이지도
            // 않던 글이 소리 없이 사라지는 것이 이 편집기에서 가장 나쁜 사고다.
            if(pad.selAll && !ev.metaKey && !ev.ctrlKey
               && (ev.key==='Backspace' || ev.key==='Delete' || ev.key==='Del')){
              var wipe=selRows(pad);
              if(wipe.length){ ev.preventDefault(); dropRows(pad, wipe); return; }
            }
            // 그 밖의 키는 선택을 흩뜨린다 — '화면 전체' 표시를 내린다. ⌘C·⌘X 는 그
            // 선택을 그대로 쓰는 키라 표시를 지키고(keydown 이 copy 이벤트보다 먼저 온다),
            // 순수 조합키(⇧·⌘…)는 아직 아무것도 고르지 않은 상태다.
            if(!(ev.key==='Shift' || ev.key==='Meta' || ev.key==='Control' || ev.key==='Alt'
                 || ((ev.metaKey||ev.ctrlKey) && (ev.code==='KeyC' || ev.code==='KeyX')))){
              pad.selAll=false;
            }
            // 칸(<input>) 안에서 온 키는 별도로 본다 — 캐럿이 편집면에 없으므로 cellAt 이
            // 못 찾고, 그대로 두면 구조 복구 루틴이 애먼 데를 건드린다.
            var host=ev.target, fsRow=null;
            while(host && host!==pad.doc){
              if(host.classList && host.classList.contains('cmm-fs')){
                fsRow=host.parentElement; break;
              }
              host=host.parentElement;
            }
            if(fsRow){
              // 태그 후보가 떠 있으면 ↑↓·Enter·Esc 는 목록 것이다 — 목록이 없을 때만 칸의 키.
              if(sugKey(ev)) return;
              // 다 적었으면 ⌘Enter(또는 Esc)로 닫고 제목으로 돌아온다.
              if(((ev.metaKey||ev.ctrlKey) && ev.key==='Enter') || ev.key==='Escape'){
                ev.preventDefault(); ev.stopPropagation();
                closeFields(pad,fsRow); caretEnd(fsRow.querySelector('.cmm-tx'));
              }
              return;
            }
            var el=cellAt(pad);
            // 캐럿이 칸 밖(편집면 알몸)에 있으면 구조부터 세우고 그 줄 끝으로 데려간다.
            if(!el){ if(normalize(pad)) el=cellAt(pad); if(!el) return; }
            var inDetail=el.classList.contains('cmm-dt'), inTitle=el.classList.contains('cmm-tx');
            if(!inDetail && !inTitle) return;
            var row=el.parentElement; while(row && !row.classList.contains('cmm-row')) row=row.parentElement;
            if(!row) return;

            // (초집중의 ↑↓ 이웃-줄 이동은 없앴다 — 2026-08-16. 편집면이 textarea 로
            //  바뀐 뒤로 이 행 편집기는 초집중에서 화면에 없고, 키보드로 덩어리를
            //  넘기는 길 자체가 "쓰던 글이 사라졌다" 로 읽혔다. 덩어리 전환은 ＋ 버튼뿐.)

            // ⌘⇧Enter — 칸(목표일·담당·팀·프로젝트) 열기. 닫는 건 ⌘Enter 또는 Esc.
            if((ev.metaKey||ev.ctrlKey) && ev.shiftKey && ev.key==='Enter'){
              ev.preventDefault(); toggleFields(pad,row,true); return;
            }
            // ⌘Enter — 상세 열기/접기. 제목에서든 상세 안에서든 같은 키로 오간다.
            if((ev.metaKey||ev.ctrlKey) && ev.key==='Enter'){
              if(row.dataset.fs==='1'){ ev.preventDefault(); closeFields(pad,row);
                caretEnd(row.querySelector('.cmm-tx')); return; }
              ev.preventDefault();
              if(inDetail){ closeDetail(pad,row); caretEnd(row.querySelector('.cmm-tx')); }
              else toggleDetail(pad,row,true);
              return;
            }
            if(inDetail){
              if(ev.key==='Escape'){ ev.preventDefault(); ev.stopPropagation();
                closeDetail(pad,row); caretEnd(row.querySelector('.cmm-tx')); }
              // 상세 안의 Enter 는 그냥 줄바꿈 — 여기선 길게 쓰는 게 목적이다.
              return;
            }

            // ⌘⇧K 체크리스트 토글 · ⌘⇧S 취소선. code 로 보는 이유: ⇧ 가 눌린 상태에선 key 가
            // 'S'/'s' 로 엇갈리고, 한글 입력 중에는 key 가 'ㄴ' 으로 들어온다.
            if((ev.metaKey||ev.ctrlKey) && ev.shiftKey && !ev.altKey && ev.code==='KeyK'){
              ev.preventDefault(); setChecklist(pad,row, !row.dataset.st); return;
            }
            if((ev.metaKey||ev.ctrlKey) && ev.shiftKey && !ev.altKey && ev.code==='KeyS'){
              ev.preventDefault(); strike(pad, el); return;
            }
            // ⇧Enter — 제목 아래에 붙는 하위 줄. 상세 칸을 펴 놓은 채로 쓰기 때문에
            // 화면에는 제목 밑에 들여쓴 줄들이 그대로 보인다(⌘Enter 는 접었다 폈다 하는 쪽).
            if(ev.key==='Enter' && ev.shiftKey && !ev.metaKey && !ev.ctrlKey && !ev.isComposing){
              ev.preventDefault();
              var dt=row.querySelector('.cmm-dt');
              if(row.dataset.open!=='1'){ row.dataset.open='1'; row.dataset.has='1'; }
              // 줄을 하나 더 열 때 WebKit 이 만들어 둔 <div> 구조를 평문으로 되돌린다 —
              // 하위 줄은 어디까지나 들여쓴 몇 줄이지 중첩 블록이 아니다.
              else { var cur=dtText(dt).replace(/\s+$/,''); if(cur) dt.textContent = cur + '\n'; }
              onEdit(pad, true); caretEnd(dt); return;
            }
            if(ev.key==='Enter' && !ev.shiftKey && !ev.isComposing){
              ev.preventDefault();
              var next=makeRow(pad,'', row.dataset.st ? 'todo' : null, '');  // 체크리스트면 이어서 체크리스트
              if(row.nextSibling) pad.doc.insertBefore(next,row.nextSibling); else pad.doc.appendChild(next);
              onEdit(pad, true); caretEnd(next.querySelector('.cmm-tx')); return;
            }
            // ── 합치기 ────────────────────────────────────────────────────
            // 줄 맨 앞의 Backspace 는 언제나 윗줄 '제목' 과 합친다. 예전에는 윗줄에 상세가
            // 달려 있으면 우리가 손을 떼고 브라우저에 맡겼는데, 그 순간 WebKit 은 글자를
            // 제목이 아니라 회색 상세 칸 끝에 밀어 넣어 버린다(딸림 글에 제목이 들러붙는
            // 그 증상). 그래서 갈래를 없앴다 — 제목은 제목끼리, 상세는 상세끼리 붙는다.
            if(ev.key==='Backspace' && caretAt0(el)){
              var pv=row.previousElementSibling;
              if(!pv){
                // 첫 줄에는 위가 없다. 체크리스트라면 상태만 벗기고 글자는 남긴다.
                if(row.dataset.st){ ev.preventDefault(); setChecklist(pad,row,false); }
                return;
              }
              ev.preventDefault();
              // 빈 체크리스트 줄은 한 번 더 눌러야 지워진다 — 손이 기억하는 감각을 유지한다.
              if(!el.textContent && row.dataset.st){ setChecklist(pad,row,false); return; }
              mergeRows(pad, pv, row); return;
            }
            // Delete(앞으로 지우기)도 대칭으로 — 줄 끝에서 누르면 아랫줄을 끌어올린다.
            if((ev.key==='Delete'||ev.key==='Del') && !ev.metaKey && !ev.ctrlKey && caretAtEnd(el)){
              var nx=row.nextElementSibling;
              if(nx){ ev.preventDefault(); mergeRows(pad, row, nx); }
              return;
            }
          }

          // 아랫줄(low)을 윗줄(up)에 접어 넣는다. 제목은 제목 뒤에 이어 붙고, 상세와 칸은
          // 사라지지 않고 윗줄로 옮겨 탄다 — 접혀 있어 안 보이던 글이 조용히 증발하는 것이
          // 이 편집기에서 가장 나쁜 사고다. 캐럿은 두 글이 만나는 이음매에 놓는다.
          function mergeRows(pad, up, low){
            // 두 줄이 같은 칸을 서로 다른 값으로 채우고 있으면 아랫줄 값은 옮겨 탈 자리가
            // 없다. 예전에는 그 값이 말없이 버려졌다 — 이제는 버리기 전에 묻고, 사용자가
            // 마다하면 합치기 자체를 하지 않는다(값이 같은 칸은 잃는 게 없으니 안 묻는다).
            var lf=fieldsOf(low), uf=fieldsOf(up), drop=[];
            for(var k in lf) if(uf[k] && uf[k]!==lf[k]) drop.push(k);
            if(drop.length && !confirm('합쳐지는 줄의 필드('+drop.join(', ')+') 내용이 모두 삭제됩니다.\n필드 내용을 지우고 합칠까요?')) return;

            var head=up.querySelector('.cmm-tx'), at=head.textContent.length;
            head.textContent = head.textContent + low.querySelector('.cmm-tx').textContent;

            var ud=up.querySelector('.cmm-dt'), ld=dtText(low.querySelector('.cmm-dt')).replace(/\s+$/,'');
            if(ld.trim()){
              var cur=dtText(ud).replace(/\s+$/,'');
              ud.textContent = cur.trim() ? cur+'\n'+ld : ld;
              up.dataset.has='1';
              if(low.dataset.open==='1') up.dataset.open='1';
            }
            Array.prototype.slice.call(up.querySelectorAll('.cmm-fs input')).forEach(function(i){
              var v=lf[i.dataset.k];
              // 시각 칸은 저장형(UTC …Z)이 아니라 화면형으로 넣어야 한다 — datetime-local
              // 은 형식이 다른 값을 소리 없이 거부해 목표일이 그 자리에서 증발한다.
              if(v && !(i.value||'').trim()){ i.value = i.dataset.tz==='1' ? toDisp(v) : v; up.dataset.has='1'; }
            });
            // 윗줄이 평문인데 아랫줄이 체크리스트였다면 상태를 물려받는다 — 체크 상태가
            // 합치기 한 번으로 말없이 풀리지 않도록.
            if(!up.dataset.st && low.dataset.st) up.dataset.st=low.dataset.st;

            low.remove();
            onEdit(pad, true);
            caretTo(head, at);
          }

          // 메모는 서식 없는 순수 텍스트로 저장된다. 그래서 <s> 같은 마크업 대신 결합 문자
          // U+0336 을 각 글자 뒤에 붙인다 — 저장·복사·다른 앱 붙여넣기에서도 선이 따라간다.
          var STRIKE='̶';
          function strike(pad, el){
            var s=el.textContent; if(!s.trim()) return;
            el.textContent = s.indexOf(STRIKE)>=0 ? s.split(STRIKE).join('')
                           : s.split('').map(function(c){ return c+STRIKE; }).join('');
            caretEnd(el); onEdit(pad, true);
          }

          // ── 내보내기(CSV) ────────────────────────────────────────────────
          // 목적: 메모를 다른 도구로 통째로 옮길 수 있어야 한다. 화면에서 감춰 둔 일련번호와
          // 상태는 여기서 열(column)로 드러난다 — 무엇을 끝냈고 무엇이 바틀넥인지 그대로 간다.
          var LABEL={todo:'미완료',done:'완료',block:'바틀넥'};
          function q(s){ return '"'+String(s).split('"').join('""')+'"'; }
          function toCSV(list, sep){
            sep=sep||',';
            // 시각 칸의 머리글에는 어느 시계인지 붙인다 — 표만 따로 봐도 기준이 남도록.
            // (가져오기는 이름으로 시작하는 열을 찾으므로 라벨이 붙어도 되돌아온다.)
            var head=['번호','상태','제목']
                     .concat(FIELDS.map(function(f){ return f.tz ? f.k+' ('+tzLabel()+')' : f.k; }))
                     .concat(['상세']);
            var out=[head.join(sep)];
            list.forEach(function(row){
              var st=row.dataset.st, f=fieldsOf(row);
              // 번호 열은 골번호가 먼저 — 리포트가 보드와 같은 번호로 지목할 수 있게.
              // 메모 줄도 골번호를 받았으면(상세·칸을 단 줄) 그대로 나간다.
              // (채번 전 체크리스트 줄만 위치 번호 폴백. '부모' 열은 FIELDS 를 따라 자동으로 나간다.)
              var cells=[ (row.dataset.gno||(st?row.dataset.no:'')||''), st?LABEL[st]:'메모',
                          row.querySelector('.cmm-tx').textContent ]
                        // 표로 나갈 때는 사람이 읽는 벽시계(표시 타임존)로 — 머리글이 그 타임존을 밝힌다.
                        .concat(FIELDS.map(function(d){ var v=f[d.k]||'';
                          return (d.tz && v) ? toDisp(v).replace('T',' ') : v; }))
                        .concat([ dtText(row.querySelector('.cmm-dt')).replace(/\n/g,' ') ]);
              // 표(TSV)로 갈 때는 셀 안의 탭·줄바꿈만 없애면 되고, 따옴표는 오히려 방해가 된다.
              out.push(sep==='\t' ? cells.map(function(c){ return String(c).split('\t').join(' '); }).join('\t')
                                  : cells.map(q).join(sep));
            });
            return out.join('\r\n');
          }
          // ── 가져오기(CSV) ────────────────────────────────────────────────
          // 내보내기의 정확한 역방향. 다른 도구(엑셀·시트·예전 메모)에서 복사한 표를 그대로
          // 붙여넣으면 상태·칸·상세가 열에서 다시 행으로 접혀 들어온다. 안전장치는 머리글 —
          // 첫 줄이 우리 머리글(번호/상태/제목…)일 때만 가져오기로 본다. 그 외의 붙여넣기는
          // 예전처럼 순수 텍스트로 들어가므로, 평범한 글을 붙이다 표로 오인될 일이 없다.
          function splitCSV(s, sep){
            var rows=[], row=[], cur='', q=false;
            s=String(s).split('\r\n').join('\n').split('\r').join('\n');
            for(var i=0;i<s.length;i++){
              var c=s.charAt(i);
              if(q){
                if(c!=='"'){ cur+=c; }
                else if(s.charAt(i+1)==='"'){ cur+='"'; i++; }   // "" 는 따옴표 한 글자
                else q=false;
                continue;
              }
              if(c==='"'){ q=true; }
              else if(c===sep){ row.push(cur); cur=''; }
              else if(c==='\n'){ row.push(cur); rows.push(row); row=[]; cur=''; }
              else cur+=c;
            }
            if(cur!=='' || row.length){ row.push(cur); rows.push(row); }
            return rows;
          }
          var ST_OF={};
          ST_OF[LABEL.todo]='todo'; ST_OF[LABEL.done]='done'; ST_OF[LABEL.block]='block';
          // 표로 읽히면 항목 배열, 아니면 null.
          // 머리글이 첫 줄에 딱 붙어 있으리라 기대하지 않는다 — 사람이 복사하면 앞에 빈 줄이나
          // 구분선(---) 이 한두 줄 딸려 온다. 앞 5줄 안에서 머리글을 찾고, 그 앞에 있던 줄은
          // 버리지 않고 평문으로 함께 들여온다(붙여넣은 글이 조용히 사라지면 안 된다).
          function fromCSV(s){
            if(!s || s.indexOf('제목')<0) return null;
            var seps=[',','\t'];
            for(var si=0; si<seps.length; si++){
              var sep=seps[si], g=splitCSV(s, sep);
              if(!g.length) continue;
              var hi=-1, head=null;
              for(var i=0; i<g.length && i<5; i++){
                var h=g[i].map(function(c){ return String(c).trim(); });
                if(h.indexOf('제목')>=0 && (h.indexOf('번호')>=0 || h.indexOf('상태')>=0)){ hi=i; head=h; break; }
              }
              if(hi<0) continue;
              var iSt=head.indexOf('상태'), iTx=head.indexOf('제목'), iDt=head.indexOf('상세');
              var out=[];
              for(var k=0; k<hi; k++){
                var lead=g[k].join(sep);
                if(lead.replace(/\s/g,'')) out.push({ st:null, text:lead, detail:'', fields:{} });
              }
              for(var r=hi+1; r<g.length; r++){
                var cells=g[r];
                if(!cells.length || cells.join('').replace(/\s/g,'')==='') continue;  // 빈 줄은 건너뛴다
                var pick=function(i){ return i>=0 && cells[i]!=null ? String(cells[i]) : ''; };
                var fields={};
                FIELDS.forEach(function(d){
                  // 머리글은 '목표일 (KST (UTC+9))' 처럼 라벨이 붙어 올 수 있다 — 이름으로 시작하면 그 열.
                  var ci=head.indexOf(d.k);
                  if(ci<0) for(var hj=0; hj<head.length; hj++){
                    if(head[hj].indexOf(d.k)===0){ ci=hj; break; } }
                  var v=pick(ci).trim(); if(!v) return;
                  // 표의 시각은 사람이 읽는 벽시계다 — 다시 UTC 로 접어 넣는다.
                  if(d.tz){ v=toStore(v); if(!v) return; }
                  fields[d.k]=v;
                });
                // 옛 내보내기의 통합 '링크' 열 — 호스트를 읽어 지라/노션/슬랙 칸에 담는다.
                var li=head.indexOf('링크');
                if(li>=0){ var lv=pick(li).trim(), lkk=linkKind(lv), ldk=lkk && LK2F[lkk.k];
                           if(ldk && !fields[ldk]) fields[ldk]=lv; }
                out.push({ st: ST_OF[pick(iSt).trim()] || null,
                           text: pick(iTx),
                           detail: pick(iDt).replace(/\s+$/,''),
                           fields: fields });
              }
              if(out.length) return out;
            }
            return null;
          }
          // 캐럿이 있는 줄 자리에 항목들을 펼쳐 넣는다. 그 줄이 빈 줄이면 자리를 내주고 사라진다 —
          // 빈 메모에 붙여넣었을 때 맨 위에 빈 줄이 남지 않도록.
          function insertItems(pad, items){
            var el=cellAt(pad), at=el ? el.parentElement : null;
            while(at && !(at.classList && at.classList.contains('cmm-row'))) at=at.parentElement;
            if(!at) at=pad.doc.lastElementChild;
            var made=[];
            items.forEach(function(it){
              var row=makeRow(pad, it.text, it.st, it.detail, it.fields);
              if(at && at.nextSibling) pad.doc.insertBefore(row, at.nextSibling);
              else pad.doc.appendChild(row);
              at=row; made.push(row);
            });
            var host=made.length ? made[0].previousElementSibling : null;
            if(host && isRow(host) && !host.querySelector('.cmm-tx').textContent
               && !host.dataset.st && !dtText(host.querySelector('.cmm-dt')).trim() && !hasFields(host)){
              host.remove();
            }
            onEdit(pad, true);
            if(made.length) caretEnd(made[made.length-1].querySelector('.cmm-tx'));
          }

          function toTitles(list){
            return list.map(function(row){
              var st=row.dataset.st;
              return (st?(row.dataset.no+'. '):'')+row.querySelector('.cmm-tx').textContent;
            }).join('\n');
          }
          // ── 화면에 보이는 것 ──────────────────────────────────────────────
          // 감춤은 어느 축이든(보기 상태 · 필드 필터 · 이전 루프 · 생성 날짜 · UI 초집중)
          // 전부 CSS 의 display:none 하나로 이뤄진다. 그래서 "지금 화면에 무엇이 있나" 는
          // 축을 하나씩 세어 보는 게 아니라 계산된 display 를 읽는 것이 옳다 — 나중에 축이
          // 하나 더 늘어도 이 함수는 그대로고, 새 축만 조용히 빠지는 사고가 없다.
          //
          // 복사·⌘A 가 이 함수 하나만 보게 만든 이유(2026-08-12): 예전에는 화면은 CSS 로
          // 거르고 복사는 rows() 로 전부 퍼 갔다. 초집중으로 한 줄만 띄워 두고 복사하면
          // 안 보이던 예순네 줄이 함께 클립보드에 실려 슬랙으로 나갔다. 보이는 것과
          // 복사되는 것이 갈라지지 않도록 진실을 하나로 둔다.
          function isShown(el){
            try{ return getComputedStyle(el).display!=='none'; }catch(e){ return true; }
          }
          function shownRows(pad){ return rows(pad).filter(isShown); }
          // 선택에 걸친 (보이는) 행들. 선택이 없거나 한 행 안에서만 그은 선택이면 [] —
          // 그때는 브라우저 기본 복사(고른 글자 그대로)가 옳다. 다만 ⌘A 로 고른 '화면
          // 전체' 는 한 줄만 보이는 초집중에서도 행 단위 복사여야 하므로, 그 선택만
          // pad.selAll 로 표시해 두고 한 행이어도 행 단위로 본다.
          function selRows(pad){
            try{
              var s=getSelection();
              if(!s || !s.rangeCount || s.isCollapsed) return [];
              var r=s.getRangeAt(0);
              var hit=shownRows(pad).filter(function(row){ return r.intersectsNode(row); });
              if(pad.selAll && hit.length) return hit;
              return hit.length>1 ? hit : [];
            }catch(e){ return []; }
          }
          function scope(pad){ var s=selRows(pad); return s.length ? s : shownRows(pad); }
          // ⌘A — '전체 선택' 은 화면에 보이는 것 전체다. 목적이 "슬랙에 붙여넣기" 이므로
          // 감춰 둔 줄(완료 · 이전 루프 · 다른 날 · 필터 밖)까지 딸려 나가면 안 된다.
          // 앱 창에서는 ⌘A 를 그냥 두면 웹뷰가 문서 전체를 골라 레일 메뉴·헤더 글자까지
          // 선택에 들어왔다(메모장 앱과 감각이 어긋나던 지점) — 그래서 패드 안에서는
          // 우리가 직접 첫 보이는 줄부터 마지막 보이는 줄까지 범위를 세운다.
          function selectShown(pad){
            var vis=shownRows(pad); if(!vis.length) return false;
            var first=vis[0], last=vis[vis.length-1];
            var a=first.querySelector('.cmm-tx');
            var dt=last.querySelector('.cmm-dt');
            var z=(dt && isShown(dt)) ? dt : last.querySelector('.cmm-tx');
            if(!a || !z) return false;
            try{
              var r=document.createRange();
              r.setStart(a, 0);
              r.setEnd(z, z.childNodes.length);
              var s=getSelection(); s.removeAllRanges(); s.addRange(r);
              pad.selAll=true;
              return true;
            }catch(e){ return false; }
          }
          // 고른 줄들을 통째로 지운다(⌘A 다음의 Backspace). 편집면이 완전히 비면 빈 줄
          // 하나를 세워 둔다 — 캐럿이 앉을 자리가 없는 편집면은 다시 쓸 수 없다.
          function dropRows(pad, list){
            var at=list[0].previousElementSibling;
            list.forEach(function(r){ r.remove(); });
            if(!pad.doc.children.length) render(pad,'');
            onEdit(pad, true);
            pad.selAll=false;
            var go=(at && isRow(at)) ? at : pad.doc.lastElementChild;
            if(go && isRow(go)) caretEnd(go.querySelector('.cmm-tx'));
          }
          function writeClip(text){
            try{ navigator.clipboard.writeText(text); }catch(e){}
          }
          // 메뉴에서 부르는 가져오기. 클립보드가 표가 아니거나 읽기가 막혀 있으면 조용히 아무 일도
          // 하지 않는다(앱 규칙 — 실패 배너 없음). 붙여넣기(⌘V)로도 같은 길이 열려 있다.
          function readClip(pad){
            try{
              var p=navigator.clipboard.readText();
              if(!p || !p.then) return;
              p.then(function(t){ var imp=fromCSV(t); if(imp) insertItems(pad, imp); })
               .catch(function(){});
            }catch(e){}
          }

          // 기본 복사는 사람이 읽는 내용 그대로. 상태 토큰·번호·열 머리글 없이 제목과 상세만
          // 나간다 — 대화창이나 메신저에 붙일 때 표가 딸려오면 방해가 되기 때문.
          function plainOf(row){
            var out=[row.querySelector('.cmm-tx').textContent];
            var f=fieldsOf(row);
            FIELDS.forEach(function(d){ if(f[d.k]) out.push(IND+'@'+d.k+': '+f[d.k]); });
            var d=dtText(row.querySelector('.cmm-dt')).replace(/\s+$/,'');
            if(d.trim()) d.split('\n').forEach(function(l){ out.push(IND+l); });
            return out.join('\n');
          }
          function toPlain(list){ return list.map(plainOf).join('\n'); }

          // ── AI 정리 ──────────────────────────────────────────────────────
          // 메모는 생각나는 대로 적은 초안이라 오타·줄 구조가 들쭉날쭉하다. 남에게(슬랙에)
          // 넘길 때만 그걸 다듬는데, 그 다듬기를 사람이 매번 손으로 하고 있었다.
          // 그 일을 클로드 코드에 넘긴다 — 다만 1~5분이 걸리므로 '멈춘 것처럼 보이는 버튼'
          // 으로 만들지 않는다. 요청만 던지고 즉시 손을 놓는다: 진행은 왼쪽 레일의
          // 'AI 정리' 줄에서 경과 시간으로 보이고, 끝나면 서버가 결과를 클립보드에 넣는다
          // (그 사이 다른 일을 하다 나중에 그 줄을 눌러 다시 복사해도 된다).
          // 실패해도 배너는 없다(앱 규칙) — 레일 줄이 조용히 '실패' 로 남는다.
          function tidyStart(list){
            var body=toPlain(list);
            if(!body.replace(/\s/g,'')) return;
            fetch('/api/memo/tidy',{method:'POST',headers:{'Content-Type':'application/json'},
                                    body:JSON.stringify({text:body})})
              .then(function(r){ return r.json(); })
              .then(function(){ if(window.cmTidyPoke) window.cmTidyPoke(); })
              .catch(function(){});
            // 레일이 첫 폴링을 기다리지 않고 곧바로 줄을 세우도록 한 번 더 찔러 준다.
            if(window.cmTidyPoke) setTimeout(window.cmTidyPoke, 400);
          }

          function clip(pad, ev, cut){
            var list=selRows(pad); if(!list.length) return;   // 한 행 안의 선택은 브라우저에 맡긴다
            if(!ev.clipboardData) return;
            ev.preventDefault();
            ev.clipboardData.setData('text/plain', toPlain(list));
            if(cut){ list.forEach(function(r){ r.remove(); });
                     if(!pad.doc.children.length) render(pad,'');
                     onEdit(pad, true); }
          }

          // 우클릭 메뉴 — 기본은 평문 복사. CSV·표(엑셀)·제목만은 여기서 명시적으로 고른다.
          var menuEl=null, menuPaint=null;
          function paintMenu(){ if(menuPaint) menuPaint(); }
          function closeMenu(){
            if(menuEl && menuEl.parentNode) menuEl.parentNode.removeChild(menuEl);
            menuEl=null; menuPaint=null;
            pads.forEach(function(p){
              if(p.view) p.view.setAttribute('aria-expanded','false');
              if(p.sort) p.sort.setAttribute('aria-expanded','false');
              if(p.ui) p.ui.setAttribute('aria-expanded','false');
              if(p.flt) p.flt.setAttribute('aria-expanded','false');
              if(p.hist) p.hist.setAttribute('aria-expanded','false');
            });
          }
          // 화면 밖으로 나가지 않게 접어 넣되, 뷰포트 크기를 모르면(0으로 오는 환경이 있다)
          // 접지 않는다 — 모르는 값으로 자르면 메뉴가 엉뚱한 구석에 붙는다.
          function place(x,y){
            var de=document.documentElement||{};
            var vw=window.innerWidth||de.clientWidth||0, vh=window.innerHeight||de.clientHeight||0;
            var w=menuEl.offsetWidth||190, h=menuEl.offsetHeight||120;
            menuEl.style.left=Math.max(6, vw ? Math.min(x, vw-w-6) : x)+'px';
            menuEl.style.top =Math.max(6, vh ? Math.min(y, vh-h-6) : y)+'px';
          }

          // 보기 콤보 — 다중 선택 체크박스. 완료를 끄면 처리에 집중하고, 켜면 리포트를 쓴다.
          function openView(pad, btn){
            var was = menuEl && menuEl.dataset.view==='1';
            closeMenu();
            if(was) return;                                  // 같은 버튼을 다시 누르면 닫기
            boardFetch();                                    // 루프 코드(26-38)를 게으르게 청한다
            menuEl=document.createElement('div');
            menuEl.className='cmmemo-menu cmm-vm'; menuEl.dataset.view='1';
            var ttl=document.createElement('div');
            ttl.className='cmm-vt'; ttl.textContent='보기 (다중 선택)';
            ttl.setAttribute('data-why','view');
            menuEl.appendChild(ttl);
            // 체크 표시 / 이름 / 개수 세 조각. innerHTML 대신 노드로 짓는다 — 이 카드는
            // 여러 페이지에 얹히므로 마크업 파싱에 기대지 않는 편이 안전하다.
            function opt(name){
              var b=document.createElement('button');
              b.type='button'; b.className='cmm-vo';
              var u=document.createElement('u'); u.textContent='✓';
              var t=document.createElement('b'); t.textContent=name;
              var e=document.createElement('em');
              b.appendChild(u); b.appendChild(t); b.appendChild(e);
              b.cnt=e; return b;
            }
            var all=opt('모두');
            all.addEventListener('mousedown', function(e){ e.preventDefault();
              viewSet(viewShown().length===VIEWS.length ? []
                                                       : VIEWS.map(function(v){ return v.s; })); });
            menuEl.appendChild(all);
            var div=document.createElement('div'); div.className='cmm-vd'; menuEl.appendChild(div);
            var opts=VIEWS.map(function(v){
              var b=opt(v.n);
              b.addEventListener('mousedown', function(e){ e.preventDefault(); viewToggle(v.s); });
              menuEl.appendChild(b);
              return { v:v, b:b };
            });
            // 루프 축 — 상태(위)와 다른 축. 이전 루프에 묻힌 완료를 볼지 말지 고르고(라디오),
            // 지금 사이클을 여기서 끝낸다(액션). 종료도 편집 한 단계 — ⌘Z 로 돌아온다.
            // 생성 날짜 축 — 상태·루프와 또 다른 축. '오늘 만든 것만' 이 기본이고,
            // 지난 것을 볼 필요가 있을 때만 여기서 넓힌다(생성 날짜 절 참조).
            var cd1=document.createElement('div'); cd1.className='cmm-vd'; menuEl.appendChild(cd1);
            var ct=document.createElement('div'); ct.className='cmm-vt';
            ct.textContent='생성 날짜'; ct.setAttribute('data-why','cr');
            menuEl.appendChild(ct);
            var copts=CRS.map(function(o){
              var b=opt(o.n);
              b.addEventListener('mousedown', function(e){ e.preventDefault(); crSet(o.s); });
              menuEl.appendChild(b);
              return { o:o, b:b };
            });
            var ld1=document.createElement('div'); ld1.className='cmm-vd'; menuEl.appendChild(ld1);
            var lt=document.createElement('div'); lt.className='cmm-vt';
            lt.setAttribute('data-why','loop'); menuEl.appendChild(lt);
            var lc=opt('현재 루프만');
            lc.addEventListener('mousedown', function(e){ e.preventDefault(); loopSet(''); });
            menuEl.appendChild(lc);
            var la=opt('이전 루프 포함');
            la.addEventListener('mousedown', function(e){ e.preventDefault(); loopSet('all'); });
            menuEl.appendChild(la);
            var ld2=document.createElement('div'); ld2.className='cmm-vd'; menuEl.appendChild(ld2);
            var le=document.createElement('button');
            le.type='button';
            le.addEventListener('mousedown', function(e){ e.preventDefault();
              if(!le.disabled) loopEnd(pad); });
            menuEl.appendChild(le);
            menuPaint=function(){
              var on=viewShown();
              all.setAttribute('aria-checked', on.length===VIEWS.length ? 'true' : 'false');
              opts.forEach(function(o){
                o.b.setAttribute('aria-checked', on.indexOf(o.v.s)>=0 ? 'true' : 'false');
                o.b.cnt.textContent=COUNT[o.v.s]||0;
              });
              // 생성 날짜 — 라디오(하나만). 오른쪽 숫자는 '이 범위로 넓히면 몇 줄이 보이나'.
              var cm=crMode(), CN={'':COUNT.c1||0, '2':COUNT.c2||0,
                                   '7':COUNT.c7||0, 'all':COUNT.cAll||0};
              copts.forEach(function(x){
                x.b.setAttribute('aria-checked', x.o.s===cm ? 'true' : 'false');
                x.b.cnt.textContent=CN[x.o.s];
              });
              // 항목 오른쪽에 루프 번호를 단다 — 보드와 같은 일련번호: 현재 = 열린 스프린트
              // 코드(26-38), 이전 = 최신 릴리즈 코드(26-37). 보드를 모르는 환경에서만
              // 숫자 스탬프 폴백(#N). 아직 이전 루프가 없으면 빈칸.
              var lm=loopMode(), L=bgLoop||{}, fb=loopCur(pad);
              lt.textContent='루프';
              lc.setAttribute('aria-checked', lm ? 'false' : 'true');
              lc.cnt.textContent = L.cur || ('#'+fb);
              la.setAttribute('aria-checked', lm ? 'true' : 'false');
              la.cnt.textContent = L.prev || (fb>1 ? '#'+(fb-1) : '');
              le.disabled=!COUNT.done;
              le.textContent='루프 종료 — 완료 '+(COUNT.done||0)+'건을 이전 루프로';
            };
            paintMenu();
            document.body.appendChild(menuEl);
            var r=btn.getBoundingClientRect ? btn.getBoundingClientRect() : {left:0,bottom:0};
            place(r.left, r.bottom+6);
            btn.setAttribute('aria-expanded','true');
          }

          // 정렬 콤보 — 단일 선택(라디오). 첫 항목이 기본(현재 입력 순서 그대로)이다.
          function openSort(pad, btn){
            var was = menuEl && menuEl.dataset.sort==='1';
            closeMenu();
            if(was) return;                                // 같은 버튼을 다시 누르면 닫기
            menuEl=document.createElement('div');
            menuEl.className='cmmemo-menu cmm-vm'; menuEl.dataset.sort='1';
            var ttl=document.createElement('div');
            ttl.className='cmm-vt'; ttl.textContent='정렬 (표시만 — 저장 순서는 그대로)';
            ttl.setAttribute('data-why','sort');
            menuEl.appendChild(ttl);
            var opts=SORTS.map(function(o){
              var b=document.createElement('button');
              b.type='button'; b.className='cmm-vo';
              var u=document.createElement('u'); u.textContent='✓';
              var t=document.createElement('b'); t.textContent=o.n;
              var e=document.createElement('em'); e.textContent=o.d;
              b.appendChild(u); b.appendChild(t); b.appendChild(e);
              b.addEventListener('mousedown', function(ev){
                ev.preventDefault(); sortSet(o.s); closeMenu(); });
              menuEl.appendChild(b);
              return { o:o, b:b };
            });
            menuPaint=function(){
              var m=sortMode();
              opts.forEach(function(x){
                x.b.setAttribute('aria-checked', x.o.s===m ? 'true' : 'false'); });
            };
            paintMenu();
            document.body.appendChild(menuEl);
            var r=btn.getBoundingClientRect ? btn.getBoundingClientRect() : {left:0,bottom:0};
            place(r.left, r.bottom+6);
            btn.setAttribute('aria-expanded','true');
          }

          // UI 콤보 — 단일 선택(라디오). 첫 항목이 기본(현재 모습 그대로)이다.
          function openUI(pad, btn){
            var was = menuEl && menuEl.dataset.ui==='1';
            closeMenu();
            if(was) return;                                // 같은 버튼을 다시 누르면 닫기
            menuEl=document.createElement('div');
            menuEl.className='cmmemo-menu cmm-vm'; menuEl.dataset.ui='1';
            var ttl=document.createElement('div');
            ttl.className='cmm-vt'; ttl.textContent='UI (표시만 — 글은 그대로)';
            ttl.setAttribute('data-why','ui');
            menuEl.appendChild(ttl);
            var opts=UIS.map(function(o){
              var b=document.createElement('button');
              b.type='button'; b.className='cmm-vo';
              var u=document.createElement('u'); u.textContent='✓';
              var t=document.createElement('b'); t.textContent=o.n;
              var e=document.createElement('em'); e.textContent=o.d;
              b.appendChild(u); b.appendChild(t); b.appendChild(e);
              b.addEventListener('mousedown', function(ev){
                ev.preventDefault(); uiSet(o.s); closeMenu(); });
              menuEl.appendChild(b);
              return { o:o, b:b };
            });
            // 구조 섹션 — 리스트(지금처럼) / 부모 기반(부모 아래 자식 계층). 같은 라디오.
            var gdv=document.createElement('div'); gdv.className='cmm-vd'; menuEl.appendChild(gdv);
            var gtt=document.createElement('div');
            gtt.className='cmm-vt'; gtt.textContent='구조';
            gtt.setAttribute('data-why','grp');
            menuEl.appendChild(gtt);
            var gopts=GRPS.map(function(o){
              var b=document.createElement('button');
              b.type='button'; b.className='cmm-vo';
              var u=document.createElement('u'); u.textContent='✓';
              var t=document.createElement('b'); t.textContent=o.n;
              var e=document.createElement('em'); e.textContent=o.d;
              b.appendChild(u); b.appendChild(t); b.appendChild(e);
              b.addEventListener('mousedown', function(ev){
                ev.preventDefault(); grpSet(o.s); closeMenu(); });
              menuEl.appendChild(b);
              return { o:o, b:b };
            });
            menuPaint=function(){
              var m=uiMode(), g=grpMode();
              opts.forEach(function(x){
                x.b.setAttribute('aria-checked', x.o.s===m ? 'true' : 'false'); });
              gopts.forEach(function(x){
                x.b.setAttribute('aria-checked', x.o.s===g ? 'true' : 'false'); });
            };
            paintMenu();
            document.body.appendChild(menuEl);
            var r=btn.getBoundingClientRect ? btn.getBoundingClientRect() : {left:0,bottom:0};
            place(r.left, r.bottom+6);
            btn.setAttribute('aria-expanded','true');
          }

          // ── 히스토리 콤보 ────────────────────────────────────────────────
          // 서버 저널(memo-history.jsonl)의 지난 판을 최신순으로 보여 준다. 판을 고르면
          // 아래에 전문이 펼쳐지고, '이 판으로 복원' 또는 '현재 글과 합치기' 로 되살린다.
          // 복원도 되돌리기 한 단계다 — 잘못 복원했으면 ⌘Z 로 즉시 돌아온다.
          // 시각은 상대 표기(방금·n분 전) 우선, 하루가 넘으면 표시 타임존(CMTimeFilter)의
          // 벽시계로 적는다 — raw Date getter 금지 규칙을 지킨다.
          function histWhen(sec){
            if(!sec) return '';
            var d=Math.max(0, Math.floor(now()/1000)-sec);
            if(d<60) return '방금';
            if(d<3600) return Math.floor(d/60)+'분 전';
            if(d<86400) return Math.floor(d/3600)+'시간 전';
            var T=tzMod();
            if(T && T.parts){ try{ var p=T.parts(sec*1000);
              return p.mo+'/'+p.d+' '+p2(p.h)+':'+p2(p.mi); }catch(e){} }
            return Math.floor(d/86400)+'일 전';
          }
          // 지난 판 되살리기. merge=true 는 합집합 병합(현재 글을 한 줄도 버리지 않는다),
          // false 는 통째 교체 — 교체로 묻히는 현재 글도 서버 저널에 남으니 잃지 않는다.
          function histRestore(s, merge){
            if(typeof s!=='string' || !s) return;
            var nt = merge ? mergeLines(text, s) : s;
            if(nt===text) return;
            text=nt;
            pads.forEach(function(p){ render(p, text); });
            if(pads[0]) histNote(pads[0], text, true);   // 사람의 액션 — ⌘Z 로 되돌릴 수 있는 한 단계
            meta(stat()); schedule();
          }
          function openHist(pad, btn){
            var was = menuEl && menuEl.dataset.hist==='1';
            closeMenu();
            if(was) return;                              // 같은 버튼을 다시 누르면 닫기
            menuEl=document.createElement('div');
            menuEl.className='cmmemo-menu cmm-hm'; menuEl.dataset.hist='1';
            var ttl=document.createElement('div');
            ttl.className='cmm-vt'; ttl.textContent='히스토리 (저장된 지난 판 — 최신순)';
            ttl.setAttribute('data-why','hist');
            menuEl.appendChild(ttl);
            var list=document.createElement('div'); list.className='cmm-hl';
            menuEl.appendChild(list);
            var note=document.createElement('div'); note.className='cmm-vt';
            note.textContent='불러오는 중…';
            list.appendChild(note);
            var me=menuEl, prev=null, pTxt=null;
            function rePlace(){
              var r=btn.getBoundingClientRect ? btn.getBoundingClientRect() : {left:0,bottom:0};
              place(r.left, r.bottom+6);
            }
            function pick(it, b){
              for(var i=0;i<list.children.length;i++)
                if(list.children[i].setAttribute) list.children[i].setAttribute('aria-checked','false');
              b.setAttribute('aria-checked','true');
              if(!prev){
                prev=document.createElement('div'); prev.className='cmm-hp';
                pTxt=document.createElement('pre');
                prev.appendChild(pTxt);
                var act=document.createElement('div'); act.className='cmm-ha';
                prev.appendChild(act);
                var keep=document.createElement('button');
                keep.type='button'; keep.textContent='현재 글과 합치기';
                var repl=document.createElement('button');
                repl.type='button'; repl.dataset.prime='1'; repl.textContent='이 판으로 복원';
                act.appendChild(keep); act.appendChild(repl);
                prev.keepB=keep; prev.replB=repl;
                menuEl.appendChild(prev);
              }
              pTxt.textContent=it.text;
              prev.replB.onmousedown=function(e){ e.preventDefault(); histRestore(it.text, false); closeMenu(); };
              prev.keepB.onmousedown=function(e){ e.preventDefault(); histRestore(it.text, true); closeMenu(); };
              rePlace();
            }
            fetch('/api/memo/history').then(function(r){ return r.json(); }).then(function(j){
              if(menuEl!==me) return;                    // 그 사이 닫혔다/다른 메뉴가 열렸다
              var items=(j && j.items) || [];
              // 이웃한 같은 글(거부 직후 수용 등)은 한 줄로 — 목록은 '고를 수 있는 판' 이다.
              var seen=[], last=null;
              items.forEach(function(it){
                if(!it || typeof it.text!=='string' || !it.text || it.text===last) return;
                last=it.text; seen.push(it);
              });
              list.innerHTML='';
              if(!seen.length){
                note.textContent='히스토리가 아직 없습니다 — 저장이 쌓이면 지난 판이 여기 남습니다';
                list.appendChild(note); rePlace(); return;
              }
              seen.forEach(function(it){
                var b=document.createElement('button');
                b.type='button'; b.className='cmm-ho';
                var tm=document.createElement('u'); tm.textContent=histWhen(it.t);
                var pv=document.createElement('b');
                var line=''; var ls=it.text.split('\n');
                for(var i=0;i<ls.length && !line;i++) line=ls[i].trim();
                pv.textContent=line||'(빈 줄)';
                var em=document.createElement('em');
                em.textContent=(typeof it.chars==='number' ? it.chars : it.text.length)+'자';
                b.appendChild(tm); b.appendChild(pv); b.appendChild(em);
                b.addEventListener('mousedown', function(e){ e.preventDefault(); pick(it, b); });
                list.appendChild(b);
              });
              rePlace();
            }).catch(function(){
              if(menuEl!==me) return;
              note.textContent='히스토리를 불러오지 못했습니다';
            });
            document.body.appendChild(menuEl);
            rePlace();
            btn.setAttribute('aria-expanded','true');
          }

          // 필터 콤보 — 후보는 지금 메모에 실제로 쓰인 담당·팀·프로젝트 값들 + 목표일 '오늘'.
          // 다중 선택 체크박스(보기와 같은 생김새). 열려 있는 동안 체크 상태는 paintMenu 로
          // 되그리지만 후보 목록 자체는 연 시점의 것 — 편집으로 값이 생기면 다시 열면 된다.
          function openFlt(pad, btn){
            var was = menuEl && menuEl.dataset.flt==='1';
            closeMenu();
            if(was) return;                                // 같은 버튼을 다시 누르면 닫기
            menuEl=document.createElement('div');
            menuEl.className='cmmemo-menu cmm-vm'; menuEl.dataset.flt='1';
            var ttl=document.createElement('div');
            ttl.className='cmm-vt'; ttl.textContent='필터 (다중 선택 — 조건과 맞는 줄만)';
            ttl.setAttribute('data-why','flt');
            menuEl.appendChild(ttl);
            function opt(name){
              var b=document.createElement('button');
              b.type='button'; b.className='cmm-vo';
              var u=document.createElement('u'); u.textContent='✓';
              var t=document.createElement('b'); t.textContent=name;
              var e=document.createElement('em');
              b.appendChild(u); b.appendChild(t); b.appendChild(e);
              b.cnt=e; return b;
            }
            function head(name){
              var d=document.createElement('div'); d.className='cmm-vd'; menuEl.appendChild(d);
              var h=document.createElement('div'); h.className='cmm-vt'; h.textContent=name;
              menuEl.appendChild(h);
            }
            // 목표일 — 오늘. 개수는 '오늘까지인 줄' 수(표시 타임존의 오늘, 상태 무관).
            var due=opt('목표일 — 오늘');
            var dueN=rows(pad).filter(function(row){
              var v=fieldsOf(row)['목표일'];
              return v && toDisp(v).slice(0,10)===todayStr();
            }).length;
            due.cnt.textContent=dueN;
            due.addEventListener('mousedown', function(e){ e.preventDefault(); fltDueToggle(); });
            menuEl.appendChild(due);
            // 담당·팀·프로젝트 — 값이 하나도 없는 칸은 줄을 차지하지 않는다.
            var ents=[];
            TAGK.forEach(function(k){
              var vals=fltCands(pad, k);
              if(!vals.length) return;
              head(k);
              vals.forEach(function(v){
                var b=opt(v.name); b.cnt.textContent=v.count;
                b.addEventListener('mousedown', function(e){ e.preventDefault(); fltToggle(k, v.name); });
                menuEl.appendChild(b);
                ents.push({ k:k, n:v.name, b:b });
              });
            });
            // 해제 — 걸린 게 있을 때만 나온다. 흩어진 체크를 하나씩 끄지 않아도 되게.
            var cdv=document.createElement('div'); cdv.className='cmm-vd'; menuEl.appendChild(cdv);
            var clr=document.createElement('button');
            clr.type='button'; clr.textContent='필터 해제';
            clr.addEventListener('mousedown', function(e){ e.preventDefault(); fltClear(); });
            menuEl.appendChild(clr);
            menuPaint=function(){
              var F=fltGet();
              due.setAttribute('aria-checked', F.due ? 'true' : 'false');
              ents.forEach(function(o){
                o.b.setAttribute('aria-checked', (F.t[o.k]||[]).indexOf(o.n)>=0 ? 'true' : 'false');
              });
              var on=fltCount(F)>0;
              clr.style.display=on ? '' : 'none';
              cdv.style.display=on ? '' : 'none';
            };
            paintMenu();
            document.body.appendChild(menuEl);
            var r=btn.getBoundingClientRect ? btn.getBoundingClientRect() : {left:0,bottom:0};
            place(r.left, r.bottom+6);
            btn.setAttribute('aria-expanded','true');
          }
          // ── 태그 후보 (담당·팀·프로젝트) ──────────────────────────────────
          // 같은 값을 매번 새로 적으면 사전이 철자 변형으로 갈라지고, 나중에 "ismail 이 맡은
          // 것" 을 한 번에 모아 볼 수 없게 된다. 그래서 칸에 몇 글자 치면 이미 쓰던 이름이
          // 뜨고, 그걸 고른다. 한 번도 쓴 적이 없을 때만 만들기가 나온다.
          //
          // 언제 찾는가: 타이핑이 SUG_WAIT(2초) 멎었을 때 한 번. 글자마다 부르지 않는 이유는
          // 사람이 이름을 다 치기 전에는 후보가 어차피 쓸모없기 때문이다(그리고 요청도 줄인다).
          // 칸에 처음 들어왔을 때는 기다리지 않고 바로 연다 — 자주 쓰는 이름을 먼저 보여 주는
          // 것이 중복을 막는 가장 값싼 방법이다.
          var SUG_WAIT=2000;
          var sugEl=null, sugInp=null, sugPad=null, sugRow=null, sugTimer=null, sugSeq=0, sugAt=-1;

          function sugClose(){
            if(sugTimer){ clearTimeout(sugTimer); sugTimer=null; }
            if(sugEl && sugEl.parentNode) sugEl.parentNode.removeChild(sugEl);
            sugEl=null; sugInp=null; sugPad=null; sugRow=null; sugAt=-1;
            sugSeq++;                                  // 날아오던 응답은 버린다
          }
          function sugOpen(){ return !!sugEl; }
          function sugItems(){
            return sugEl ? Array.prototype.slice.call(sugEl.querySelectorAll('button')) : [];
          }
          function sugMark(){
            sugItems().forEach(function(b,i){
              if(i===sugAt) b.setAttribute('data-on','1'); else b.removeAttribute('data-on'); });
          }
          function sugMove(d){
            var list=sugItems(); if(!list.length) return;
            sugAt = sugAt<0 ? (d>0 ? 0 : list.length-1) : (sugAt+d+list.length)%list.length;
            sugMark();
            if(list[sugAt].scrollIntoView) list[sugAt].scrollIntoView({block:'nearest'});
          }
          // 후보를 확정한다. 고르는 것도 만드는 것도 같은 길(POST /api/memo/tags) — 고르는
          // 행위 자체가 그 태그를 한 번 더 쓴 것이므로 사용 횟수가 오르고, 다음엔 더 위에 뜬다.
          // 칸에는 내가 친 글자가 아니라 사전에 저장된 표기가 들어간다(대소문자 흔들림 방지).
          function sugPick(name){
            var pad=sugPad, inp=sugInp, row=sugRow, kind=inp&&inp.dataset.k;
            if(!inp) return;
            inp.value=name; sugClose();
            paint(pad); onEdit(pad);
            if(inp.focus) inp.focus();
            fetch('/api/memo/tags',{method:'POST',headers:{'Content-Type':'application/json'},
                                    body:JSON.stringify({k:kind,name:name})})
              .then(function(r){ return r.json(); })
              .then(function(j){
                // 사전이 이미 다른 표기로 갖고 있으면 그쪽으로 맞춘다 — 두 벌이 되지 않도록.
                if(j && j.ok && j.name && j.name!==inp.value && document.contains(inp)){
                  inp.value=j.name; paint(pad); onEdit(pad);
                }
              })
              .catch(function(){});                    // 조용히 — 칸의 값은 이미 화면에 있다
          }
          function sugRender(pad, inp, row, q, data){
            sugClose();
            var tags=(data&&data.tags)||[], canNew=!!(data&&data.canCreate);
            if(!tags.length && !canNew) return;         // 보여 줄 게 없으면 아무것도 열지 않는다
            sugEl=document.createElement('div'); sugEl.className='cmmemo-sug';
            sugInp=inp; sugPad=pad; sugRow=row; sugAt=-1;
            var hd=document.createElement('div'); hd.className='cmm-sh';
            hd.textContent = tags.length ? (q ? inp.dataset.k+' — 비슷한 이름' : inp.dataset.k+' — 자주 쓰는')
                                         : inp.dataset.k+' — 처음 쓰는 이름';
            sugEl.appendChild(hd);
            tags.forEach(function(t){
              var b=document.createElement('button'); b.type='button';
              var n=document.createElement('b'); n.textContent=t.name;
              var c=document.createElement('em'); c.textContent=t.count>1 ? t.count+'회' : '';
              b.appendChild(n); b.appendChild(c);
              // mousedown + preventDefault — 칸이 포커스를 잃지 않으므로 blur 로 목록이
              // 먼저 닫혀 클릭이 허공을 치는 일이 없다.
              b.addEventListener('mousedown', function(e){ e.preventDefault(); sugPick(t.name); });
              sugEl.appendChild(b);
            });
            if(canNew){
              if(tags.length){ var d=document.createElement('div'); d.className='cmm-sd'; sugEl.appendChild(d); }
              var nb=document.createElement('button'); nb.type='button'; nb.className='cmm-snew';
              var nn=document.createElement('b'); nn.textContent='＋ "'+q+'" 새로 만들기';
              nb.appendChild(nn);
              nb.addEventListener('mousedown', function(e){ e.preventDefault(); sugPick(q); });
              sugEl.appendChild(nb);
            }
            document.body.appendChild(sugEl);
            sugPlace(inp);
          }
          // 목록을 칸 밑에 앉힌다(태그·부모 공용). 아래가 좁으면 칸 위로 뒤집는다 —
          // 목록이 화면 밖으로 잘리지 않게.
          function sugPlace(inp){
            var r=inp.getBoundingClientRect ? inp.getBoundingClientRect() : {left:0,bottom:0};
            var de=document.documentElement||{};
            var vw=window.innerWidth||de.clientWidth||0, vh=window.innerHeight||de.clientHeight||0;
            var w=sugEl.offsetWidth||200, h=sugEl.offsetHeight||140;
            sugEl.style.left=Math.max(6, vw ? Math.min(r.left, vw-w-6) : r.left)+'px';
            var below=(r.bottom||0)+5;
            sugEl.style.top=(vh && below+h>vh-6 ? Math.max(6,(r.top||0)-h-5) : below)+'px';
          }
          function sugFetch(pad, inp, row){
            var kind=inp.dataset.k, q=(inp.value||'').trim(), my=++sugSeq;
            fetch('/api/memo/tags?k='+encodeURIComponent(kind)+'&q='+encodeURIComponent(q))
              .then(function(r){ return r.json(); })
              .then(function(j){
                // 늦게 온 응답이나, 그 사이 다른 칸으로 옮겨 갔으면 버린다.
                if(my!==sugSeq || document.activeElement!==inp) return;
                sugRender(pad, inp, row, q, j);
              })
              .catch(function(){});                     // 조용히 — 사전이 없어도 손으로 적을 수 있다
          }
          function sugSchedule(pad, inp, row, now){
            if(sugTimer){ clearTimeout(sugTimer); sugTimer=null; }
            if(now){ sugFetch(pad, inp, row); return; }
            sugTimer=setTimeout(function(){ sugTimer=null; sugFetch(pad, inp, row); }, SUG_WAIT);
          }
          // 칸 안에서의 키 — 목록이 열려 있을 때만 가로챈다. 닫혀 있으면 예전 그대로다.
          function sugKey(ev){
            if(!sugOpen() || ev.target!==sugInp) return false;
            if(ev.key==='ArrowDown'){ ev.preventDefault(); sugMove(1); return true; }
            if(ev.key==='ArrowUp'){ ev.preventDefault(); sugMove(-1); return true; }
            if(ev.key==='Enter' && !ev.isComposing && !ev.metaKey && !ev.ctrlKey){
              var list=sugItems();
              if(sugAt>=0 && list[sugAt]){ ev.preventDefault(); ev.stopPropagation();
                list[sugAt].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));
                return true; }
              return false;
            }
            // Esc 는 목록만 닫는다 — 칸까지 접히면 한 번에 두 단계가 사라져 놀란다.
            if(ev.key==='Escape'){ ev.preventDefault(); ev.stopPropagation(); sugClose(); return true; }
            return false;
          }
          // 태그 칸 하나를 사전에 연결한다(makeRow 에서 호출).
          function wireTag(pad, row, inp){
            inp.dataset.tag='1';
            inp.setAttribute('autocomplete','off');
            inp.addEventListener('focus', function(){ sugSchedule(pad, inp, row, true); });
            inp.addEventListener('input', function(){ sugSchedule(pad, inp, row, false); });
            inp.addEventListener('blur', function(){ if(sugInp===inp) sugClose(); });
          }

          // ── 부모 후보 (부모 칸) ────────────────────────────────────────────
          // 부모 골번호는 사람이 다 외우지 못한다. 칸에 들어오면 목록이 뜬다:
          // 맨 위는 '최근' — 최근에 확정한 부모 번호(MRU, 최신이 맨 위. 보드 부모# 와
          // 같은 서버 목록이라 localStorage 웹뷰 격리에 안 갈라진다), 그 아래는
          // 'AI 추천' — 이 줄 제목을 서버 ParentSuggest 가 훑어 고른 후보다.
          // 타이핑하면 받아 둔 목록을 그 자리에서 거른다(재요청 없음 — 후보는 줄 제목에
          // 매달린 값이라 부모 칸의 타이핑으로는 변하지 않는다). 고르든 손으로 적든
          // 확정된 번호는 사용 기록(POST parent-used)으로 남아 다음에 맨 위에 뜬다.
          // 목록/키 조작은 태그 후보의 sug* 골격을 그대로 쓴다 — 항목과 확정만 다르다.
          function psugTitleOf(pad, n, t){
            if(t) return t;                              // 서버가 보드 제목을 이미 실어 줬다
            var byNo={};                                 // 보드에 없는 번호 = 메모 줄 번호
            rows(pad).forEach(function(r){ var g=+r.dataset.gno||0;
              if(g && byNo[g]==null) byNo[g]=r.querySelector('.cmm-tx').textContent; });
            var v=goalTitle(n, byNo);
            return v!=null ? String(v).trim() : '';
          }
          function psugItem(pad, it){
            var b=document.createElement('button'); b.type='button';
            var t=psugTitleOf(pad, it.n, it.t||'');
            var nm=document.createElement('b');
            nm.textContent='#'+it.n+(t?' · '+(t.length>24?t.slice(0,24)+'…':t):'');
            b.appendChild(nm);
            // 왜 이 후보인가 — 추천 항목만 갖는 근거(공유 키워드). 줄을 늘리지 않게 툴팁으로.
            if(it.why) b.title=it.why;
            b.addEventListener('mousedown', function(e){ e.preventDefault(); psugPick(it.n); });
            return b;
          }
          // 번호를 칸에 확정한다. 고르는 행위 자체가 그 부모를 한 번 더 쓴 것 — 사용
          // 기록이 올라 다음 목록의 맨 위에 뜬다. 실패는 조용히(칸의 값은 이미 화면에 있다).
          function psugPick(n){
            var pad=sugPad, inp=sugInp;
            if(!inp) return;
            inp.value=String(n); sugClose();
            paint(pad); onEdit(pad);
            if(inp.focus) inp.focus();
            fetch('/api/memo/parent-used',{method:'POST',headers:{'Content-Type':'application/json'},
                                           body:JSON.stringify({n:n})})
              .catch(function(){});
          }
          function psugRender(pad, inp, row, data){
            sugClose();
            var q=(inp.value||'').trim().replace(/^#/,'');
            function keep(it){
              if(!q) return true;
              var t=psugTitleOf(pad, it.n, it.t||'');
              return String(it.n).indexOf(q)===0 || (t && t.indexOf(q)>=0);
            }
            var rec=((data&&data.recent)||[]).filter(keep);
            var sug=((data&&data.sug)||[]).filter(function(it){
              // 추천이 최근과 겹치면 최근 쪽만 — 같은 번호가 두 번 보이면 길어 보이기만 한다.
              return keep(it) && !rec.some(function(r){ return r.n===it.n; });
            });
            if(!rec.length && !sug.length) return;       // 보여 줄 게 없으면 열지 않는다
            sugEl=document.createElement('div'); sugEl.className='cmmemo-sug';
            sugInp=inp; sugPad=pad; sugRow=row; sugAt=-1;
            if(rec.length){
              var h1=document.createElement('div'); h1.className='cmm-sh';
              h1.textContent='최근 — 방금 쓴 것이 맨 위';
              sugEl.appendChild(h1);
              rec.forEach(function(it){ sugEl.appendChild(psugItem(pad, it)); });
            }
            if(sug.length){
              if(rec.length){ var d=document.createElement('div'); d.className='cmm-sd'; sugEl.appendChild(d); }
              var h2=document.createElement('div'); h2.className='cmm-sh';
              h2.textContent='AI 추천 — 이 줄 제목으로';
              sugEl.appendChild(h2);
              sug.forEach(function(it){ sugEl.appendChild(psugItem(pad, it)); });
            }
            document.body.appendChild(sugEl);
            sugPlace(inp);
          }
          function psugFetch(pad, inp, row){
            var title=(row.querySelector('.cmm-tx')||{textContent:''}).textContent||'';
            var no=+row.dataset.gno||0, my=++sugSeq;
            fetch('/api/memo/parent-suggest?title='+encodeURIComponent(title.trim())
                  +'&no='+no)
              .then(function(r){ return r.json(); })
              .then(function(j){
                // 늦게 온 응답이나, 그 사이 다른 칸으로 옮겨 갔으면 버린다.
                if(my!==sugSeq || document.activeElement!==inp) return;
                inp._psug=j;                             // 타이핑 필터가 재사용하는 원본
                psugRender(pad, inp, row, j);
              })
              .catch(function(){});                      // 조용히 — 손으로 적는 길은 그대로다
          }
          // 부모 칸 하나를 후보 목록에 연결한다(makeRow 에서 호출).
          function wireParent(pad, row, inp){
            inp.setAttribute('autocomplete','off');
            var v0='';
            inp.addEventListener('focus', function(){ v0=inp.value; psugFetch(pad, inp, row); });
            inp.addEventListener('input', function(){
              if(inp._psug) psugRender(pad, inp, row, inp._psug);
            });
            inp.addEventListener('blur', function(){
              if(sugInp===inp) sugClose();
              // 손으로 적은 번호도 확정이다 — 이번 포커스에서 값이 바뀌었을 때만 기록.
              var n=pnum(inp.value);
              if(n && inp.value!==v0)
                fetch('/api/memo/parent-used',{method:'POST',headers:{'Content-Type':'application/json'},
                                               body:JSON.stringify({n:n})})
                  .catch(function(){});
            });
          }

          // 우선순위 이동 — 같은 상태값 안에서만 오르내린다. 완료는 완료끼리, 바틀넥은
          // 바틀넥끼리, 미완료는 미완료끼리(평문 줄도 평문끼리). 우선순위는 상태 그룹
          // 안에서의 순서이기 때문이다. 사이에 다른 상태가 끼어 있으면 건너뛰어 같은
          // 상태의 가장 가까운 행 곁으로 간다 — 정렬(미완료↑ 완료↓)을 켠 화면에서는
          // 그 행이 바로 눈에 보이는 이웃이다. 그 방향에 같은 상태가 더 없으면 끝이다.
          function moveTarget(row, up){
            var st=row.dataset.st||'', n = up ? row.previousElementSibling : row.nextElementSibling;
            while(n && !(isRow(n) && (n.dataset.st||'')===st))
              n = up ? n.previousElementSibling : n.nextElementSibling;
            return n;
          }
          function moveOK(row, up){ return !!moveTarget(row, up); }
          function moveRow(pad, row, up){
            var t=moveTarget(row, up);
            if(!t) return;
            if(up) pad.doc.insertBefore(row, t);
            else pad.doc.insertBefore(row, t.nextElementSibling);   // t 바로 뒤로
            onEdit(pad, true);
          }
          function openMenu(pad, x, y, row){
            closeMenu();
            var list=scope(pad), whole=selRows(pad).length===0;
            menuEl=document.createElement('div');
            menuEl.className='cmmemo-menu';
            var items=[];
            if(row){
              // 막힌 방향도 항목은 남긴다(흐리게) — 메뉴가 열 때마다 늘었다 줄면 손이 헤맨다.
              items.push(['위로 이동', function(){ moveRow(pad, row, true); }, !moveOK(row, true)]);
              items.push(['아래로 이동', function(){ moveRow(pad, row, false); }, !moveOK(row, false)]);
              items.push(null);                          // 구분선
            }
            // 복사는 모두 '화면에 보이는 것' 이 대상이다(scope → shownRows). 감춰 둔 줄이
            // 조용히 딸려 나가지 않도록, 무엇이 빠졌는지는 메뉴에 숫자로 적어 둔다.
            var hidden=rows(pad).length-shownRows(pad).length;
            var allTip='지금 화면에 보이는 줄만 복사합니다'
                       +(hidden>0 ? ' — 감춰 둔 '+hidden+'줄은 빠집니다(보기·필터·UI 모드)' : '');
            items.push(
             ['복사'+(whole?' (화면 전체)':''), function(){ writeClip(toPlain(list)); }, false, true, allTip],
             ['제목만 복사', function(){ writeClip(toTitles(list)); }, false, false, allTip],
             ['CSV로 복사', function(){ writeClip(toCSV(list)); }, false, false, allTip],
             ['표로 복사 (엑셀 붙여넣기)', function(){ writeClip(toCSV(list,'\t')); }, false, false, allTip],
             ['메모 그대로 복사', function(){ writeClip(list.map(lineOf).join('\n')); }, false, false, allTip],
             null,
             ['AI로 정리해서 복사', function(){ tidyStart(list); }, false, false,
              '클로드 코드가 오타·줄 구조를 다듬어 슬랙에 붙일 평문으로 만듭니다. '
              +'1~5분 걸리므로 기다리지 않습니다 — 왼쪽 레일의 \'AI 정리\' 줄에서 경과 시간이 오르고, '
              +'끝나면 결과가 클립보드에 자동으로 들어갑니다(나중에 그 줄을 눌러 다시 복사해도 됩니다).'],
             null,
             ['CSV 가져오기 (붙여넣기)', function(){ readClip(pad); }]);
            items.forEach(function(it){
              if(!it){ var d=document.createElement('div'); d.className='cmm-vd'; menuEl.appendChild(d); return; }
              var b=document.createElement('button');
              b.type='button'; b.textContent=it[0];
              if(it[2]) b.disabled=true;
              if(it[3]) b.dataset.prime='1';
              if(it[4]) b.title=it[4];
              b.addEventListener('mousedown', function(e){ e.preventDefault(); if(b.disabled) return; it[1](); closeMenu(); });
              menuEl.appendChild(b);
            });
            document.body.appendChild(menuEl);
            place(x, y);   // 화면 밖으로 나가지 않도록 — 메뉴는 항상 통째로 보여야 한다.
          }

          // ⌘A 는 편집면의 keydown 으로 오는 것이 정상이지만, 앱 창(WKWebView)에서는 창
          // 자체가 '문서 전체 선택' 으로 먼저 처리해 이벤트의 target 이 편집면이 아닐 수
          // 있다. 그 경우에도 캐럿이 패드 안에 있으면 전체 선택은 우리 몫이다 —
          // 문서 단계(capture)에서 한 번 더 잡아 화면에 보이는 줄만 고른다.
          // 편집면 안에서 온 이벤트는 여기서 건드리지 않는다(아래 onKey 가 처리한다).
          var guardOn=false;
          function selAllGuard(){
            if(guardOn) return; guardOn=true;
            document.addEventListener('keydown', function(ev){
              if(!(ev.metaKey||ev.ctrlKey) || ev.altKey || ev.shiftKey) return;
              if(!(ev.code==='KeyA' || ev.key==='a' || ev.key==='A')) return;
              if(ev.target && (ev.target.tagName==='INPUT' || ev.target.tagName==='TEXTAREA')) return;
              // 캐럿(선택)이 어느 패드의 편집면 안에 있나 — 없으면 이 페이지의 다른 곳이다.
              var n=null;
              try{ var s=getSelection(); if(s && s.rangeCount) n=s.getRangeAt(0).startContainer; }catch(e){}
              if(n && n.nodeType===3) n=n.parentElement;
              for(var i=0;i<pads.length;i++){
                var p=pads[i];
                if(!p.doc || !n || !p.doc.contains(n)) continue;
                if(p.doc===ev.target || p.doc.contains(ev.target)) return;   // onKey 가 받는다
                if(selectShown(p)){ ev.preventDefault(); ev.stopPropagation(); }
                return;
              }
            }, true);
          }

          function mount(el){
            if(!el || el.dataset.cmmemoOn) return null;
            el.dataset.cmmemoOn='1';
            var pad={ el:el, doc:el.querySelector('[data-cmmemo-doc]'), meta:el.querySelector('[data-cmmemo-meta]'),
                      exp:el.querySelector('[data-cmmemo-exp]'),
                      view:el.querySelector('[data-cmmemo-view]'),
                      viewN:el.querySelector('[data-cmmemo-view-n]'),
                      viewCr:el.querySelector('[data-cmmemo-view-cr]'),
                      sort:el.querySelector('[data-cmmemo-sort]'),
                      ui:el.querySelector('[data-cmmemo-ui]'),
                      hist:el.querySelector('[data-cmmemo-hist]'),
                      flt:el.querySelector('[data-cmmemo-flt]'),
                      fltN:el.querySelector('[data-cmmemo-flt-n]'),
                      // 초집중 편집면 — 지금 덩어리 하나를 담는 textarea.
                      // uaRow=묶여 있는 행, uaWant=머리글 예약, uaComposing/uaStamping=IME·재진입 방어.
                      ua:el.querySelector('[data-cmmemo-ua]'),
                      uaRow:null, uaWant:false, uaComposing:false, uaStamping:false };
            if(!pad.doc || !pad.meta) return null;
            if(pad.exp) pad.exp.addEventListener('click', expToggle);
            if(pad.view) pad.view.addEventListener('mousedown', function(e){
              e.preventDefault(); openView(pad, pad.view); });
            if(pad.sort) pad.sort.addEventListener('mousedown', function(e){
              e.preventDefault(); openSort(pad, pad.sort); });
            if(pad.ui) pad.ui.addEventListener('mousedown', function(e){
              e.preventDefault(); openUI(pad, pad.ui); });
            if(pad.hist) pad.hist.addEventListener('mousedown', function(e){
              e.preventDefault(); openHist(pad, pad.hist); });
            if(pad.flt) pad.flt.addEventListener('mousedown', function(e){
              e.preventDefault(); openFlt(pad, pad.flt); });
            // ＋ 체크리스트 — 단축키를 모르는 손을 위한 길. 마지막 줄이 비어 있으면 그 줄을
            // 체크리스트로 바꾸고, 아니면 새 줄을 붙인다(빈 줄이 쌓이지 않도록).
            var addBtn=el.querySelector('[data-cmmemo-add]');
            if(addBtn) addBtn.addEventListener('click', function(){
              // 초집중에는 체크리스트도 행도 없다 — 여기서는 '새 덩어리' 버튼이다.
              // 키보드로는 이 덩어리를 벗어날 수 없으니(위 배선), 뜻을 담아 누르는
              // 이 한 번만이 화면의 글을 바꾼다. 지금 글은 uaNew 안에서 먼저 저장된다.
              if(uiMode()==='ultra' && pad.ua){ uaNew(pad); return; }
              var last=pad.doc.lastElementChild;
              if(last && !last.dataset.st && !last.querySelector('.cmm-tx').textContent){
                setChecklist(pad,last,true); caretEnd(last.querySelector('.cmm-tx')); return;
              }
              var row=makeRow(pad,'','todo','');
              pad.doc.appendChild(row); onEdit(pad, true); caretEnd(row.querySelector('.cmm-tx'));
            });
            // ── 초집중 편집면 배선 ────────────────────────────────────────
            // 쓰는 즉시 행에 반영하고(uaSync) 평소의 저장 경로를 그대로 탄다 —
            // '나갈 때 저장' 같은 늦은 반영은 이 앱에서 글이 사라지는 길이다.
            if(pad.ua){
              pad.ua.addEventListener('beforeinput', function(ev){ uaStampMark(pad, ev); });
              pad.ua.addEventListener('input', function(ev){
                if(pad.uaStamping) return;                  // 우리가 넣은 머리글의 메아리
                uaSync(pad);
                if(!ev.isComposing) uaStampApply(pad);
              });
              // 조합(한글) 중에는 머리글을 넣지 않는다 — 확정된 다음 틱에 넣는다.
              pad.ua.addEventListener('compositionstart', function(){ pad.uaComposing=true; });
              pad.ua.addEventListener('compositionend', function(){ pad.uaComposing=false;
                setTimeout(function(){ uaStampApply(pad); }, 0); });
              pad.ua.addEventListener('keydown', function(ev){
                if(ev.isComposing || ev.metaKey || ev.ctrlKey || ev.altKey) return;
                // 머리글 예약은 beforeinput 이 맡지만, IME 첫 타(key='Process'/keyCode 229)를
                // beforeinput 으로 늦게 주는 엔진이 있어 키에서도 한 번 더 짚는다
                // (uaStampMark 는 이미 예약돼 있으면 조용히 물러난다).
                if((ev.key && ev.key.length===1) || ev.key==='Process' || ev.keyCode===229)
                  uaStampMark(pad, null);
                // ↑↓ 는 이 덩어리 안에서만 움직인다 — 앞뒤 덩어리로 넘어가지 않는다.
                // 예전에는 첫 줄에서 ↑, 마지막 줄에서 ↓ 가 이웃 덩어리로 건너뛰었다.
                // 그런데 초집중은 화면에 한 덩어리뿐이라, 그 건너뜀은 쓰던 글이 통째로
                // 사라진 것과 구분되지 않는다 — 캐럿을 끝으로 내리려던 손짓 한 번에
                // 다른 글이 뜨니, 방금 적은 것이 날아갔다고 읽힌다(2026-08-16).
                // 초집중에서 덩어리를 바꾸는 길은 머리의 ＋ 버튼(뜻을 담은 누름)뿐이고,
                // 키보드만으로는 이 덩어리를 절대 벗어나지 않는다.
              });
              pad.ua.addEventListener('blur', function(){ uaSync(pad); flush(); });
            }
            // 문서형(3단계) 레이아웃은 부모를 flex 컨테이너로 쓴다 — 페이지별 선택자 불필요.
            if(el.parentElement) el.parentElement.classList.add('cmmemo-host');
            // 빈 자리 클릭 — 감춤(생성 날짜·루프·필터)이 걸려 화면에 보이는 줄이 하나도
            // 없을 때도 쓸 자리가 있어야 한다. 편집면 자체를 누르면 마지막 빈 줄로 캐럿을
            // 보내고, 빈 줄이 없으면 하나 만든다(새 줄은 오늘 만든 것이니 곧바로 보인다).
            pad.doc.addEventListener('mousedown', function(ev){
              pad.selAll=false;                             // 마우스가 닿으면 '화면 전체' 선택은 끝
              if(ev.target!==pad.doc) return;               // 행을 눌렀으면 브라우저에 맡긴다
              // 왼쪽 버튼만 '쓰겠다는 뜻' 이다. 오른쪽(내보내기 메뉴)·가운데 버튼으로는
              // 줄이 생기지 않는다 — 메뉴를 열려다 빈 줄이 따라 생기던 길을 막는다.
              if(ev.button!==0) return;
              ev.preventDefault();
              // 초집중에서는 줄 하나만 남고 나머지 편집면이 통째로 빈 자리다 — 여기서
              // 빈 자리 클릭이 줄을 만들면 마우스가 스치기만 해도 빈 줄이 쌓인다.
              // 그러니 초집중에서는 만들지 않는다. 캐럿을 '지금 줄' 로 되돌릴 뿐이고,
              // 이미 그 줄에 있으면 자리도 그대로 둔다(새 줄은 Enter·＋버튼으로).
              if(uiMode()==='ultra'){
                if(ultraRowAt(pad)) return;                 // 캐럿이 이미 어느 줄 안 — 그대로
                var cur=pad.doc.querySelector('.cmm-row[data-cur="1"]');
                if(cur) caretEnd(cur.querySelector('.cmm-tx'));
                return;
              }
              var last=pad.doc.lastElementChild;
              if(last && isRow(last) && crBlank(last)){ caretEnd(last.querySelector('.cmm-tx')); return; }
              var row=makeRow(pad,'',null,'');
              pad.doc.appendChild(row); onEdit(pad, true); caretEnd(row.querySelector('.cmm-tx'));
            });
            pad.doc.addEventListener('keydown', function(ev){ onKey(pad, ev); });
            selAllGuard();
            // 편집 메뉴의 '실행 취소' 나 트랙패드 제스처는 키가 아니라 beforeinput 으로 온다.
            // 그 길도 막고 우리 히스토리로 보낸다 — 두 개의 되돌리기가 따로 놀면 안 된다.
            pad.doc.addEventListener('beforeinput', function(ev){
              if(ev.inputType==='historyUndo'){ ev.preventDefault(); undo(pad); }
              else if(ev.inputType==='historyRedo'){ ev.preventDefault(); redo(pad); }
            });
            pad.doc.addEventListener('input', function(ev){
              // "- " 를 직접 타이핑해도 체크리스트가 되게 — 손이 기억하는 마크다운 습관 존중.
              var t=cellAt(pad), row=t && t.parentElement;
              while(row && !row.classList.contains('cmm-row')) row=row.parentElement;
              if(t && row && t.classList.contains('cmm-tx') && !row.dataset.st && /^-\s/.test(t.textContent)){
                t.textContent=t.textContent.replace(/^-\s/,'');
                setChecklist(pad,row,true); caretEnd(t); return;
              }
              // 전체 선택 후 삭제·붙여넣기는 행 구조를 부술 수 있다. 구조가 상했으면
              // 남은 글자에서 다시 세워 놓는다(실패 배너 없이 조용히 복구).
              if(normalize(pad)){ onEdit(pad); return; }
              onEdit(pad);
            });
            // 여러 행에 걸친 복사·잘라내기는 내용 그대로(평문) 나간다 — CSV 는 우클릭 메뉴에서만.
            // 한 행 안에서 고른 글자는 그대로 두는 게 옳으니 건드리지 않는다.
            pad.doc.addEventListener('copy', function(ev){ clip(pad, ev, false); });
            pad.doc.addEventListener('cut',  function(ev){ clip(pad, ev, true); });
            pad.doc.addEventListener('paste', function(ev){
              var t=ev.clipboardData && ev.clipboardData.getData('text/plain');
              if(t==null) return;
              ev.preventDefault();
              // 상세 칸이 활성화된 채 붙여넣으면 몇 줄이든 '그 상세 안의 줄들'로 들어간다 —
              // 새 체크리스트 행을 만들지 않는다(10줄 복사 = 10개 항목이 되던 길을 막는다).
              // execCommand 는 못 쓴다: 줄바꿈에서 첫 줄만 넣고 나머지를 버린다(실측).
              // 캐럿 앞뒤를 dtText 좌표(div/BR = 줄)로 잘라 평문으로 다시 조립한다 —
              // ⇧Enter 핸들러가 상세를 평문 textContent 로 되돌리는 것과 같은 규칙.
              // 탭은 내보내기(TSV) 왕복을 지키려고 공백으로 눕힌다.
              var cell=cellAt(pad);
              if(cell && cell.classList.contains('cmm-dt')){
                var dRow=cell.parentElement;
                while(dRow && !dRow.classList.contains('cmm-row')) dRow=dRow.parentElement;
                var ins=t.split('\r\n').join('\n').split('\r').join('\n').split('\t').join(' ');
                var full=dtText(cell), a=-1, b=-1;
                try{ var ps=getSelection(), pr=ps.getRangeAt(0);
                     a=dtOffset(cell, pr.startContainer, pr.startOffset);
                     b=dtOffset(cell, pr.endContainer, pr.endOffset); }catch(e){}
                var pre, suf;
                // 캐럿 자리를 못 읽는 환경에서는 끝에 줄로 잇는다 — 글자를 잃는 것보단 낫다.
                if(a<0){ var cur=full.replace(/\s+$/,''); pre=cur?cur+'\n':''; suf=''; }
                else { pre=full.slice(0,a); suf=full.slice(b<a?a:b); }  // 선택돼 있던 글자는 덮는다
                cell.textContent=pre+ins+suf;
                if(dRow) dRow.dataset.has='1';
                onEdit(pad, true);
                caretTo(cell, (pre+ins).length);
                return;
              }
              // 우리 머리글을 단 표라면 열 → 행으로 되접어 가져온다(내보내기의 역방향).
              var imp=fromCSV(t);
              if(imp){ insertItems(pad, imp); return; }
              // 여러 줄 글은 반드시 우리가 행으로 나눠 넣는다. execCommand 에 맡기면 WebKit 이
              // 줄마다 <div> 를 만들어 .cmm-ln(flex) 의 형제로 끼워 넣고, 그러면 줄이 아래가
              // 아니라 옆으로 흐른다(한 글자 폭 세로 기둥). 메모 문법(- [ ] · 4칸 들여쓰기)도
              // 이 길에서만 살아난다.
              var txt=t.split('\r\n').join('\n').split('\r').join('\n');
              if(txt.indexOf('\n')>=0){
                insertItems(pad, parse(txt).map(function(it){
                  return { st:it.st, text:it.text, detail:it.detail.join('\n'), fields:it.fields };
                }));
                return;
              }
              // 서식·표를 데려오지 않도록 순수 텍스트만 넣는다. TSV 로 온 표는 CSV 왕복을 위해
              // 탭을 공백으로 눕힌다(열 구조는 붙여넣는 쪽에서 의미가 없다).
              document.execCommand('insertText', false, t.split('\r\n').join('\n').split('\t').join(' '));
            });
            pad.doc.addEventListener('contextmenu', function(ev){
              ev.preventDefault();
              // 누른 자리의 행 — 이동(우선순위) 항목은 이 행에 대해서만 뜬다.
              var n=ev.target, hit=null;
              while(n && n!==pad.doc){ if(isRow(n)){ hit=n; break; } n=n.parentElement; }
              openMenu(pad, ev.clientX, ev.clientY, hit);
            });
            pad.doc.addEventListener('blur', flush, true);
            pads.push(pad);
            render(pad, loaded ? text : '');
            if(!histCur) histReset(loaded ? text : '');
            viewPaint();
            loopPaint();
            crBtnPaint();
            sortPaint();
            uiPaint();
            fltBtnPaint();
            pad.meta.textContent = loaded ? stat() : '불러오는 중…';
            return pad;
          }

          function load(){
            fetch('/api/memo').then(function(r){ return r.json(); }).then(function(j){
              loaded=true;
              var srv=(j&&typeof j.text==='string')?j.text:'';
              if(j && typeof j.rev==='number') rev=j.rev;
              // 지난 세션의 미저장 초안이 서버보다 새로우면 — 저장이 못 닿고 웹뷰가 죽은 것.
              // 서버 글과 합쳐 복구하고 다시 저장한다.
              // d.t 는 같은 초까지 인정(>=) — 저장 확정과 같은 초에 이어 친 글자가 초안에만
              // 남고 죽는 엣지(GET 의 updatedAt 은 초 단위 절사)를 병합으로 줍는다. 병합은
              // 합집합이라 이미 반영된 초안이어도 해가 없다.
              var d=draftRead();
              if(!text && !timer && !pending && d && d.text!==srv
                 && j && typeof j.updatedAt==='number' && d.t>=j.updatedAt){
                // 생성 스탬프 채우기는 합친 뒤에 한 번 — 한쪽만 스탬프가 있으면 합집합
                // 병합에서 같은 줄이 두 벌로 남는다.
                text=crMigrate(mergeLines(d.text, srv));
                pads.forEach(function(p){ render(p, text); });
                histReset(text);
                meta(stat()); schedule(); return;
              }
              // 이미 타이핑을 시작했다면 서버 값을 버리지 않고 합친다. (예전에는 버렸다 —
              // 응답이 느린 사이 쓴 첫 줄이 다음 저장에서 서버 글 전체를 덮는 사고의 길.)
              if(text && text!==srv){
                var m=crMigrate(mergeLines(text, srv));
                if(m!==text) adopt(m);
                meta(stat()); schedule(); return;
              }
              if(!text && !timer && !pending){
                var mig=crMigrate(srv);
                text=mig; pads.forEach(function(p){ render(p, text); });
                // 불러온 값이 되돌리기의 바닥이다 — ⌘Z 로 '빈 메모' 까지 거슬러 가면
                // 서버에 있던 글이 통째로 지워진 것처럼 보인다.
                histReset(text);
                // 예전 글에 '@생성: 이전' 을 채웠으면 그 판을 서버에도 올려 둔다 —
                // 다음에 열 때 또 채우지 않도록(조용히, 배너 없음).
                if(mig!==srv) schedule();
              }
              meta(stat());
            }).catch(function(){
              // 첫 GET 실패 = 판번호도 서버 글도 모르는 상태. 이대로 저장을 열어 두면 빈
              // 화면이 서버 글을 덮을 수 있다 — 될 때까지 3초 간격으로 다시 읽는다.
              // (그동안의 타이핑은 화면·로컬 초안에 안전하고, 로드되는 순간 합쳐진다.)
              if(!loaded) setTimeout(load, 3000);
              meta('불러오는 중…');
            });
          }

          function boot(){
            var els=document.querySelectorAll('[data-cmmemo]');
            for(var i=0;i<els.length;i++) mount(els[i]);
            if(pads.length){ expPaint(); load(); }
          }
          if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', boot); else boot();
          window.addEventListener('pagehide', flush);
          // 앞으로 오면 서버 판을 맞추고(낡은 패드 방지), 뒤로 가면 즉시 저장한다.
          window.addEventListener('focus', refresh);
          document.addEventListener('visibilitychange', function(){
            if(document.hidden) flush(); else refresh();
          });
          // ── 제목 툴팁 ──────────────────────────────────────────────────
          // 잘린 제목(…)에 마우스를 올리면 행을 펼치는 대신 마우스 옆에 작은 창으로
          // 전문을 보여 준다(2026-08-09). 행이 hover 마다 두세 줄로 부풀면 "몇 줄짜리
          // 목록인지" 감각이 흐트러진다는 피드백 — 행 높이는 불변, 창만 뜬다.
          var tipEl=null, tipTm=0, tipFor=null;
          function tipHide(){
            if(tipTm){ clearTimeout(tipTm); tipTm=0; }
            tipFor=null;
            if(tipEl && tipEl.parentNode) tipEl.parentNode.removeChild(tipEl);
            tipEl=null;
          }
          function tipShow(txt, x, y){
            tipEl=document.createElement('div');
            tipEl.className='cmmemo-tip';
            tipEl.textContent=txt;
            document.body.appendChild(tipEl);
            // 먼저 붙여 크기를 잰 뒤 화면 안으로 밀어 넣는다 — 기본은 마우스 오른쪽 아래,
            // 아래가 모자라면 마우스 위로 뒤집는다.
            var r=tipEl.getBoundingClientRect(), px=x+14, py=y+18;
            if(px+r.width>innerWidth-8) px=Math.max(8, innerWidth-8-r.width);
            if(py+r.height>innerHeight-8) py=Math.max(8, y-10-r.height);
            tipEl.style.left=px+'px'; tipEl.style.top=py+'px';
          }
          document.addEventListener('mouseover', function(ev){
            var t=ev.target;
            // '왜 이 메뉴가 있는가' — 머리 버튼·콤보 소제목(data-why)이 제목 툴팁보다 우선.
            var wy=(t && t.closest) ? t.closest('[data-why]') : null;
            var tx=(t && t.closest) ? t.closest('.cmm-tx') : null;
            var hit=wy||tx;
            if(hit===tipFor && tipFor) return;     // 같은 대상 안에서의 이동은 유지
            tipHide();
            var x=ev.clientX, y=ev.clientY;
            if(wy){
              var k=wy.getAttribute('data-why'), wtx=WHY[k]||k;
              tipFor=wy;
              // 까닭은 긴 글이라 조금 더 기다린다 — 버튼 위를 지나가기만 해도 뜨면 방해다.
              tipTm=setTimeout(function(){ tipTm=0; if(tipFor===wy) tipShow(wtx,x,y); }, 420);
              return;
            }
            if(!tx) return;
            if(tx===document.activeElement) return;              // 편집 중 = 이미 펼쳐짐
            if(tx.scrollWidth<=tx.clientWidth+1) return;         // 안 잘렸으면 창도 없다
            tipFor=tx;
            // 살짝 기다렸다 띄운다 — 목록을 훑으며 지나가는 마우스에 창이 깜빡이지 않게.
            tipTm=setTimeout(function(){ tipTm=0; if(tipFor===tx) tipShow(tx.textContent,x,y); }, 300);
          });
          // 창 밖으로 마우스가 나가면 mouseover 가 다시 안 온다 — 여기서 거둔다.
          document.addEventListener('mouseout', function(ev){
            if(tipFor && !ev.relatedTarget) tipHide();
          });
          document.addEventListener('focusin', tipHide);
          document.addEventListener('mousedown', function(ev){
            tipHide();
            if(menuEl && !menuEl.contains(ev.target)) closeMenu();
            // 후보는 자기 칸을 누를 때는 살아 있어야 한다(다시 열려고 누르는 것이므로).
            if(sugEl && ev.target!==sugInp && !sugEl.contains(ev.target)) sugClose();
          }, true);
          window.addEventListener('scroll', function(){ closeMenu(); sugClose(); tipHide(); }, true);
          window.addEventListener('resize', function(){ closeMenu(); sugClose(); tipHide(); });
          // 초집중 — '지금 줄' 은 캐럿을 따라간다. 클릭·Enter(새 줄)·⌘Z 복원 등
          // 캐럿이 움직이는 모든 길이 여기 하나로 모인다.
          document.addEventListener('selectionchange', function(){
            if(uiMode()!=='ultra') return;
            pads.forEach(function(p){
              // 초집중에서 쓰는 자리는 textarea 다 — 거기 캐럿이 있는 동안에는 편집면의
              // 옛 선택을 따라 '지금 덩어리' 를 옮기지 않는다(옮기면 글이 뒤섞인다).
              if(p.ua && document.activeElement===p.ua) return;
              var r=ultraRowAt(p);
              if(r && r.dataset.cur!=='1') ultraMark(p,r);
            });
          });

          return { mount:mount, flush:flush, count:function(){ return pads.length; },
                   expand:expToggle, expanded:expOn,
                   strike:function(){ if(pads[0]) strike(pads[0], document.activeElement); },
                   text:function(){ return text; },
                   setText:function(s){ text=s||''; pads.forEach(function(p){ render(p, text); });
                     // 바깥에서 통째로 갈아 끼운 것도 되돌릴 수 있어야 한다(한 단계).
                     if(pads[0]) histNote(pads[0], text, true);
                     meta(stat()); schedule(); },
                   undo:function(){ return pads[0] ? undo(pads[0]) : false; },
                   redo:function(){ return pads[0] ? redo(pads[0]) : false; },
                   // 앱 창의 ⌘A — 네이티브 Edit 메뉴(AppDelegate.installEditMenu)가 먼저
                   // 가로채는 경로다. 메뉴는 웹뷰에 selectAll: 을 보내 문서 전체(레일 메뉴
                   // 글자까지)를 고르므로, 캐럿이 패드 안에 있으면 우리가 먼저 답한다.
                   // true = 우리가 골랐다(네이티브는 그만둔다), false = 패드 밖이다.
                   selectVisible:function(){
                     var n=null;
                     try{ var s=getSelection(); if(s && s.rangeCount) n=s.getRangeAt(0).startContainer; }catch(e){}
                     if(n && n.nodeType===3) n=n.parentElement;
                     for(var i=0;i<pads.length;i++){
                       var p=pads[i];
                       // 초집중에서는 편집면이 textarea 하나다 — 그 안에 있으면 그 글만 고른다.
                       if(p.ua && document.activeElement===p.ua){
                         try{ p.ua.select(); }catch(e){ return false; }
                         return true;
                       }
                       if(p.doc && n && p.doc.contains(n)) return selectShown(p);
                     }
                     return false;
                   },
                   focus:function(){ if(!pads[0]) return;
                     // 초집중이면 그 덩어리의 textarea 로 — 행 편집기는 화면에 없다.
                     if(uiMode()==='ultra' && pads[0].ua){
                       var ta=pads[0].ua;
                       try{ ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); }catch(e){}
                       return;
                     }
                     var r=pads[0].doc.lastElementChild;
                     if(r) caretEnd(r.querySelector('.cmm-tx')); } };
        })();
        </script>
        """#
    }
}
