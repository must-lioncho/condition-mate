import Foundation

// GET /issues — 위임 이슈 목록.
//
// 무엇을 답하는 화면인가: "내가 lion_work 에서 위임한 일 중에 무엇이 끝났고 무엇이 안 끝났나".
// 원천은 lion-work-queue 의 트랙 카드이고 파서는 Core/WorkQueueStore.swift 다.
//
// 판정 기준은 목록의 예쁨이 아니라 이것 하나다 —
//   이 화면을 켠 뒤에 무엇이 끝났는지 알아내려고 다른 창을 여는 횟수가 0 이어야 한다.
// 그래서 이 화면은 값이 없는 칸을 조용히 비워 두지 않는다. 없으면 없다고 쓴다. 카드 0 개(필터
// 결과 없음)와 큐 폴더 없음(경로 실패)은 다른 사건이라 문구를 갈라 쓴다 — 라이언이 할 일이 다르다.
//
// 정규화한 버킷 옆에 원래 `status:` 문자열을 같이 보인다. 정규화를 믿으라고 요구하지 않고 근거를
// 옆에 두기 위한 것이다. 정규화가 틀리면 라이언이 그 줄에서 바로 안다.
//
// 2026-09-05 항목 3 에서 상세가 붙었다. 행을 누르면 오른쪽에 상세가 선다. 순서는 2026-09-06 에
// 뒤집혔다 — 리퀘스트(원문) → 수정된 최초의 리퀘스트 → 작업지시서 → 결과물 → 버전.
// 원문이 먼저 서되 닫혀 있고, 중요한 것은 그 다음에 펼쳐진 채 서는 수정된 리퀘스트다. 라이언의 말이
// "원문은 사실 중요하지 않기 때문에 내가 펼치게 하면 그때 보이고" 이므로, 닫혔을 때는 본문을 아예
// 그리지 않는다. 닫힌 자리에 작은 스크롤 상자를 두는 것은 닫은 게 아니라 작게 만든 것이다.
//
// 상세가 지키는 것 넷:
//
//   1) `결과물 없음` 은 회색 빈 칸이 아니라 **일급 상태**다. 실측 85 중 59 개가 결과물이 없다 —
//      없는 것이 예외가 아니라 다수다. 그래서 `요청만` / `작업지시서까지` / `결과물까지` 세
//      단계로 어디까지 갔는지를 말한다. 빈 칸은 화면이 고장 났다는 신호이고 그것과 다르다.
//   2) 경로마다 `있음` / `경로 없음` 이 갈려 찍힌다. `status: done` 인데 적힌 산출물이 디스크에
//      없는 카드가 실재한다. 죽은 버튼을 눌러 아무 일도 안 일어나는 것이 라이언이 창을 여는
//      이유가 되므로, 없으면 없다고 화면에서 읽히게 한다.
//   3) `마지막` 배지는 맨 위 헤더에도 둔다. 라이언의 말이 "글을 보고 이게 마지막 버젼 이구나
//      하면서 보겠지" 이므로 스크롤을 내려야 알게 되면 요구를 못 지킨 것이다.
//   4) 폴더 열기는 경로를 서버에 그대로 넘기지 않는다 — 넘기는 것은 넘기되 서버가 이번 스캔에서
//      카드로부터 파싱해 낸 경로 집합과 대조해서 밖의 것은 `unknown-path` 로 거절한다.
//      같은 이유로 Orca 열기와 아카이브도 경로나 명령을 받지 않는다 — 받는 것은 카드 키 하나이고
//      작업 폴더·터미널 제목·직전 상태는 전부 서버가 카드에서 만든다. 웹뷰 문자열은 셸에 닿지 않는다.
//      이 페이지의 POST 는 reveal · orca · archive · unarchive · mdsave 다섯이다. 아카이브
//      상태는 ~/.condition-mate/work-queue/archive.json 에만 산다.
//   5) 2026-09-06 에 `mdsave` 가 붙으면서 **이 페이지가 큐 폴더에 쓰는 첫 자리**가 생겼다. 앞선
//      판의 "큐 폴더에는 아무것도 쓰지 않는다" 는 이제 사실이 아니다. 대신 쓰기가 읽기와 같은
//      검증 함수(AppDelegate.workQueueMarkdownPath) 하나를 통과한다 — 절대경로 · `..` 없음 ·
//      `.md` · 그 스캔의 허용 목록 안 · 실재하는 파일. 쓰기 쪽만 느슨하면 루프백 대시보드가
//      임의 파일 쓰기 통로가 되고, 그것은 읽기 통로보다 나쁘다.
enum IssuesContent {

    static func html() -> String {
        return #"""
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>이슈</title>
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
            padding:6px 12px;font-size:13px;cursor:pointer}
          .btn:hover{background:#242b3b}

          /* 맨 위 — 큰 수 두 개. 이 화면이 답하는 질문이 둘이라서 둘이다. */
          .heads{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:12px}
          .big{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 20px;min-width:150px}
          .big .n{font-size:34px;font-weight:700;line-height:1.1;font-variant-numeric:tabular-nums}
          .big .k{color:var(--mut);font-size:12px;letter-spacing:.03em;margin-top:2px}
          .big.ok .n{color:#5fd08a}
          .big.no .n{color:#e8b339}
          /* 안 됨 아래의 셋. 막힘을 대기에 묻으면 아무도 안 건드리는 것이 안 보인다. */
          .subs{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px}
          .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:9px 14px;min-width:104px}
          .card .n{font-size:19px;font-weight:700;line-height:1.2;font-variant-numeric:tabular-nums}
          .card .k{color:var(--mut);font-size:11px;letter-spacing:.03em}
          .card.blocked .n{color:#f85149}
          .card.unk{border-color:#5a4520}
          .card.unk .n{color:#d29922}

          /* 없으면 없다고 쓰는 자리. 비워 두면 라이언이 확인하러 창을 연다. */
          .note{background:#131822;border:1px solid var(--line);border-left:3px solid #d29922;
            border-radius:10px;padding:11px 14px;margin-bottom:14px;color:#c3cad6;font-size:12.5px}
          .note b{color:#e6e9ef}
          .note.bad{border-left-color:#f85149}
          .note .t{color:#d29922;font-size:11px;letter-spacing:.04em;text-transform:uppercase;margin-bottom:5px}
          .note.bad .t{color:#f85149}
          .note code{background:#0f141d;border:1px solid var(--line);border-radius:5px;padding:1px 5px;font-size:11.5px}

          /* 필터 — 단일 선택. 복수 선택은 이번 화면이 답하는 질문에 필요 없다. */
          .filters{display:flex;flex-direction:column;gap:7px;margin-bottom:14px}
          .frow{display:flex;align-items:center;gap:7px;flex-wrap:wrap}
          .frow .fl{color:#68758b;font-size:10.5px;letter-spacing:.04em;text-transform:uppercase;flex:0 0 46px}
          .chip{background:#11151d;border:1px solid var(--line);color:#aab3c2;border-radius:999px;
            padding:4px 11px;font-size:12px;cursor:pointer;white-space:nowrap}
          .chip:hover{background:#182031}
          .chip.on{background:#16233c;border-color:#33518f;color:#cfe0ff}
          .chip .c{color:#68758b;font-size:11px;margin-left:5px;font-variant-numeric:tabular-nums}
          .chip.on .c{color:#8fb0ee}
          .filters select{background:#11151d;border:1px solid var(--line);color:#aab3c2;border-radius:8px;
            padding:4px 9px;font-size:12px;max-width:420px}

          /* 목록 — 한 줄에 배지·날짜·제목·트랙·대상·원래 status. */
          .list{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
          /* 마지막 칸이 트랙 이름 하나였다가 [보관] 을 같이 이고 있게 되어 넓어졌다. 라이언의
             지적이 "액션을 취할 수 있는데 이게 없네" 였고, 상세를 열어야만 나오는 버튼은
             그 지적을 못 지운다 — 목록에서 바로 치울 수 있어야 한다. */
          .row{display:grid;grid-template-columns:66px 92px 1fr 78px;gap:10px;align-items:start;
            padding:9px 14px;border-bottom:1px solid #1b2230}
          .list.arch .row{grid-template-columns:66px 92px 1fr 84px}
          .act{display:flex;flex-direction:column;align-items:flex-end;gap:4px}
          .row:last-child{border-bottom:0}
          .row:hover{background:#171d29}
          .bdg{font-size:11px;border-radius:999px;padding:2px 0;text-align:center;border:1px solid transparent}
          .bdg.done{background:#12281c;color:#5fd08a;border-color:#1f4630}
          .bdg.run{background:#132038;color:#7db0ff;border-color:#25406e}
          .bdg.wait{background:#20242e;color:#a3adbe;border-color:#2c3444}
          .bdg.blocked{background:#2a1618;color:#ff7b72;border-color:#5a2a2c}
          .bdg.unk{background:#2a2210;color:#e3b341;border-color:#5a4520}
          .dt{color:#68758b;font-size:11.5px;font-variant-numeric:tabular-nums;padding-top:1px}
          .ti{min-width:0}
          .ti .h{color:#dbe2ee;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .ti .m{color:#68758b;font-size:11px;margin-top:2px;display:flex;gap:10px;flex-wrap:wrap}
          .ti .m .raw{color:#8a7a4a}
          .ti .m .tg{color:#7d899c}
          .trk{font-size:10.5px;color:#8a93a3;text-align:right;padding-top:2px}
          .trk.fast{color:#7db0ff}.trk.best{color:#c69df1}
          /* 마우스를 올릴 수 있는 것에는 그렇게 보이게 밑줄을 점선으로 둔다. 설명이 붙어
             있다는 것을 모르면 아무도 올려 보지 않으므로 title 만으로는 요구를 못 지킨다. */
          .hint{cursor:help;border-bottom:1px dotted #4a5468}
          /* 검색 — 헤더에 산다. 이 화면에서 라이언이 두 번째로 자주 할 일이라 접어 두지 않는다. */
          .search{display:flex;align-items:center;gap:6px}
          .search input{background:#11151d;border:1px solid var(--line);color:var(--fg);
            border-radius:8px;padding:6px 11px;font-size:13px;width:290px}
          .search input:focus{outline:none;border-color:#33518f}
          .sbar{background:#131822;border:1px solid var(--line);border-left:3px solid var(--accent);
            border-radius:10px;padding:10px 13px;margin-bottom:12px;color:#c3cad6;font-size:12.5px}
          .sbar.local{border-left-color:#d29922}
          .sbar b{color:#e6e9ef}
          .sbar .x{float:right;background:none;border:0;color:#7db0ff;font-size:12px;cursor:pointer}
          /* AI 가 왜 이 카드를 골랐는지. 행 안에 두는 이유는 목록 밖에 모아 두면 어느 줄의
             설명인지 라이언이 다시 맞춰 봐야 하기 때문이다. */
          .ti .whyhit{color:#8fb0ee;font-size:11px;margin-top:3px}
          .empty{color:var(--mut);padding:26px 16px;text-align:center;font-size:13px}
          .foot{color:#5d6678;font-size:11.5px;margin-top:12px}
          @media(max-width:760px){.row{grid-template-columns:60px 1fr}.dt,.trk{display:none}}

          /* ── 상세 ───────────────────────────────────────────────────────────
             분할로 둔다(오버레이가 아니라). 목록과 상세를 같이 보는 것이 이 화면에서
             자연스럽고, 돌아가기 한 번을 아낀다. 좁은 화면에서만 오버레이로 접힌다. */
          main.split{max-width:1560px;display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1.25fr);gap:16px;align-items:start}
          main.split .left{min-width:0}
          .row.sel{background:#16233c;box-shadow:inset 3px 0 0 var(--accent)}
          .row{cursor:pointer}
          .det{background:var(--panel);border:1px solid var(--line);border-radius:14px;
            position:sticky;top:74px;max-height:calc(100vh - 96px);overflow:auto}
          .det .dh{position:sticky;top:0;background:#161b25;border-bottom:1px solid var(--line);
            padding:12px 16px;z-index:2}
          .det .dh h2{margin:0 0 7px;font-size:14.5px;line-height:1.45;color:#eaeef6}
          .det .dh .meta{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
          .det .dh .x{float:right;margin-left:10px;background:none;border:0;color:#68758b;
            font-size:17px;cursor:pointer;line-height:1}
          .det .dh .x:hover{color:#e6e9ef}
          .pill{font-size:11px;border-radius:999px;padding:2px 9px;border:1px solid var(--line);
            background:#11151d;color:#aab3c2;white-space:nowrap}
          .pill.ver{background:#1b1430;border-color:#3d2b6b;color:#c9b6ff}
          .pill.last{background:#2a2210;border-color:#5a4520;color:#e3b341}
          .pill.stage3{background:#12281c;border-color:#1f4630;color:#5fd08a}
          .pill.stage2{background:#132038;border-color:#25406e;color:#7db0ff}
          .pill.stage1{background:#20242e;border-color:#2c3444;color:#a3adbe}
          .sec{padding:14px 16px;border-bottom:1px solid #1b2230}
          .sec:last-child{border-bottom:0}
          .sec > .t{color:#8a93a3;font-size:11px;letter-spacing:.05em;text-transform:uppercase;
            margin-bottom:8px;display:flex;align-items:center;gap:8px}
          .sec .why{color:#5d6678;font-size:10.5px;text-transform:none;letter-spacing:0}
          /* 절 제목의 [Orca 로 열기] 는 오른쪽 끝에 붙인다 — 제목 옆에 붙으면 근거 문구를 민다. */
          .sec > .t .open{margin-left:auto;text-transform:none;letter-spacing:0}
          .det .dh .meta .open{text-transform:none}
          .lead{color:#e2e8f2;font-size:14px;line-height:1.65;white-space:pre-wrap;word-break:break-word}
          .lead.raw{color:#c3cad6;border-left:3px solid #5a4520;padding-left:11px}
          /* 펼쳐진 채로 보이되 5 줄에서 자른다. 라이언이 이 자리에서 원하는 것은 전문이 아니라
             "무슨 일이었나" 한 눈이고, 길면 그 아래 절들이 화면 밖으로 밀린다. */
          .lead.clamp{display:-webkit-box;-webkit-line-clamp:5;-webkit-box-orient:vertical;overflow:hidden}
          .rawtag{color:#d29922;font-size:11px;margin-bottom:6px}
          /* DASH-14 — 이 `요구` 줄을 만든 실행의 정보. 절 제목 바로 밑, **접힌 상태에서도
             보이는 자리**에 선다. 펼치지 않고도 누가 얼마를 써서 몇 초에 만들었는지 아는
             것이 이 줄의 목적이므로, 3 단 접힘 바깥에 둔다.
             `.sesid` 를 그대로 못 쓰는 이유는 그 규칙이 `.ses .sh a.sesid` 로 세션 블록
             안에만 걸려 있어서다 — 여기는 `.ses` 밖이라 선택자가 안 닿는다. 그래서 링크
             모양만 같은 값으로 다시 적는다(색·밑줄·hover 동일). */
          .revrow{color:#8fa2c0;font-size:11px;line-height:1.55;margin-bottom:7px;
            font-variant-numeric:tabular-nums;word-break:break-word}
          .revrow.miss{color:#8a93a3}
          .revrow a{color:#cfe0ff;text-decoration:underline;text-underline-offset:2px;
            text-decoration-color:#4a6ea8;cursor:pointer}
          .revrow a:hover{color:#fff;background:#1b2436}
          /* 원문은 읽기 전용이다. 한 글자도 못 고친다 — 원문 훼손으로 폐기된 카드가 있다. */
          .orig{background:#0f141d;border:1px solid var(--line);border-radius:9px;padding:11px 13px;
            color:#c3cad6;font-size:12.5px;line-height:1.7;white-space:pre-wrap;word-break:break-word;
            max-height:230px;overflow:auto;user-select:text}
          /* 펼치기 1 단: 5 줄. 왜 5 인가 — 라이언이 댄 이유가 "속독을 해도 5줄 이상을 보기
             어려우니까" 이고, 이 파일은 이미 같은 화면의 `.lead` 에서 5 줄을 
             `-webkit-line-clamp:5` 로 구현해 두었다(위). 같은 화면에서 같은 말이 두 가지
             크기로 보이면 안 되므로 같은 수단을 쓴다. 픽셀로 고정하지 않는 이유는 폭에 따라
             줄바꿈이 달라져 px 로는 줄 수를 못 맞추기 때문이다 (12.5px × 1.7 = 21.25px/줄).
             max-height 를 푸는 것은 밑줄의 230px 스크롤 상자와 겹치면 5 줄보다 먼저 잘려서다.

             padding-bottom 을 0 으로 죽이는 이유는 따로 있다. `overflow:hidden` 은 content box
             가 아니라 padding box 에서 자르므로, 아래 여백 11px 이 남아 있으면 여섯 번째 줄의
             윗머리가 그 11px 안으로 새어 나와 "5 줄" 밑에 잘린 줄 하나가 더 붙어 보인다
             (WebKit 실측 2026-09-06). 0 으로 두면 다섯째 줄의 … 에서 정확히 끝난다. */
          .orig.o5{display:-webkit-box;-webkit-line-clamp:5;-webkit-box-orient:vertical;
            overflow:hidden;max-height:none;padding-bottom:0}
          /* 펼치기 2 단: 전문. 원문 데이터는 어느 단계에서도 잘리지 않는다 — 잘리는 것은
             보이는 높이뿐이고 텍스트는 언제나 통째로 DOM 에 있다.

             이름이 `open` 이 아니라 `full` 인 이유가 있다. 이 시트에는 버튼용 `.open` 이
             아래(‘Orca 로 열기’·‘아카이브’)에 따로 있고 둘 다 특이도가 0,1,0 인데 버튼 쪽이
             뒤에 있어서 이겼다. 그래서 `class="orig open"` 이던 앞선 판은 전문을 펼치면
             버튼의 `font-size:11.5px` 와 `white-space:nowrap` 을 뒤집어써서, 1,198 자짜리
             원문이 가로 9,151px 짜리 한 줄로 그려졌다 (WebKit 실측 2026-09-06).

             그래서 두 가지를 같이 한다. 이름을 `full` 로 갈라 두고, `open` 도 같은 규칙에
             태워서 버튼이 훔쳐 간 값을 여기서 되찾는다 — `.orig.open` 은 0,2,0 이라 버튼의
             `.open`(0,1,0)을 이긴다. 이름만 갈랐다면 `class="orig open"` 을 쓰는 다른 자리가
             조용히 깨진 채 남는다. 실제로 이 화면에는 그런 자리가 하나 더 있다(longBox). */
          .orig.full,.orig.open{max-height:none;
            font-size:12.5px;line-height:1.7;white-space:pre-wrap;color:#c3cad6;
            background:#0f141d;border-radius:9px;padding:11px 13px;cursor:auto}
          .lnk{background:none;border:0;color:#7db0ff;font-size:11.5px;cursor:pointer;padding:4px 0}
          .art{display:flex;gap:8px;align-items:flex-start;padding:7px 0;border-bottom:1px solid #171d29}
          .art:last-child{border-bottom:0}
          .art .p{flex:1;min-width:0;color:#cfd6e3;font-size:12px;word-break:break-all;line-height:1.55}
          .art .p .k{color:#5d6678;font-size:10.5px}
          .art .st{font-size:10.5px;border-radius:5px;padding:2px 7px;white-space:nowrap;border:1px solid transparent}
          .st.ok{background:#12281c;color:#5fd08a;border-color:#1f4630}
          .st.no{background:#2a1618;color:#ff7b72;border-color:#5a2a2c}
          .st.url{background:#132038;color:#7db0ff;border-color:#25406e}
          .st.nap{background:#20242e;color:#a3adbe;border-color:#2c3444}
          .st.notgt{background:#2a2210;color:#e3b341;border-color:#5a4520}
          .open{background:#1d2230;border:1px solid var(--line);color:#cfe0ff;border-radius:7px;
            padding:3px 9px;font-size:11.5px;cursor:pointer;white-space:nowrap}
          .open:hover{background:#26314a}
          .none{color:#8a93a3;font-size:12.5px;background:#11151d;border:1px dashed #2c3444;
            border-radius:9px;padding:11px 13px;line-height:1.6}
          .none b{color:#cfd6e3}
          /* 세션에서 끌어온 것. 카드에 적힌 것과 **눈으로 갈려야 한다** — 출처가 다르다.
             카드는 사람이 적은 것이고 이쪽은 앱이 세션 기록에서 파낸 것이라, 둘을 같은 모양으로
             그리면 라이언이 카드에 이미 적혀 있는 줄 알고 큐 PM 을 안 부른다. */
          .ses{margin-top:10px;border-left:3px solid #25406e;padding-left:11px}
          .ses .sh{color:#7db0ff;font-size:11px;line-height:1.5;margin-bottom:6px}
          .ses .sh b{color:#cfe0ff;font-weight:600}
          /* 세션 머리 줄만 flex 다. 라이언이 스크린샷에서 네모를 그린 자리가 이 줄의 오른쪽
             빈 공간이라, 버튼 묶음을 margin-left:auto 로 그리로 민다.
             ASSUMPTION (L1): `.ses .sh` 전체가 아니라 `.shrow` 가 붙은 줄에만 flex 를 준다.
             `.sh` 는 `첫 지시문` / `마지막 보고` 머리에도 쓰이는데, 거기까지 flex 로 만들면
             `<b>…</b>` 와 뒤따르는 설명 글이 두 개의 flex 아이템이 되어 사이에 gap 이 벌어진다.
             바꾸라고 한 것은 세션 줄 하나이므로 그 줄만 바꾼다. */
          .ses .sh.shrow{display:flex;align-items:baseline;gap:8px}
          .ses .sh.shrow .shb{margin-left:auto;display:flex;gap:6px;flex:none}
          .ses .sh.shrow .shb .open{padding:2px 8px;font-size:11px}
          .ses .sh a.sesid{color:#cfe0ff;font-weight:600;text-decoration:underline;
            text-underline-offset:2px;text-decoration-color:#4a6ea8;cursor:pointer}
          .ses .sh a.sesid:hover{color:#fff;background:#1b2436}
          .vrow{display:flex;gap:9px;align-items:baseline;padding:5px 0;font-size:12.5px;color:#c3cad6}
          .vrow .vn{color:#c9b6ff;font-weight:600;font-variant-numeric:tabular-nums}
          .vrow .vt{color:#68758b;font-size:11.5px}
          @media(max-width:1000px){
            main.split{display:block}
            .det{position:fixed;inset:56px 0 0;top:56px;z-index:60;max-height:none;border-radius:0;
              border-left:0;border-right:0}
          }
          /* md 팝업. 경로 한 줄이 밑줄 링크가 되고, 누르면 이 화면 위에 뜬다.
             Finder 로 나가지 않고 여기서 읽고 고치는 것이 이 절의 존재 이유다. */
          .art .p a.mdlink{color:#cfe0ff;text-decoration:underline;text-underline-offset:2px;
            text-decoration-color:#4a6ea8;cursor:pointer}
          .art .p a.mdlink:hover{color:#fff;background:#1b2436}
          .mdw{position:fixed;inset:0;z-index:200;background:rgba(4,7,12,.74);
            display:flex;align-items:center;justify-content:center;padding:28px}
          .mdbox{width:min(1000px,100%);height:min(88vh,940px);display:flex;flex-direction:column;
            background:#0d121a;border:1px solid var(--line);border-radius:12px;overflow:hidden;
            box-shadow:0 18px 60px rgba(0,0,0,.6)}
          .mdh{display:flex;gap:7px;align-items:center;padding:9px 11px;border-bottom:1px solid #1b2230;
            background:#111722}
          .mdh .mdt{flex:1;min-width:0;color:#8a93a3;font-size:11.5px;word-break:break-all;line-height:1.45}
          .mdh .tab{background:#161c28;border:1px solid var(--line);color:#8a93a3;border-radius:7px;
            padding:3px 11px;font-size:11.5px;cursor:pointer;white-space:nowrap}
          .mdh .tab.on{background:#1d2a44;color:#cfe0ff;border-color:#2c4470}
          .mdbody{flex:1;min-height:0;display:flex}
          .mdprev{flex:1;min-width:0;overflow:auto;padding:16px 20px;color:#cfd6e3;font-size:13px;line-height:1.75}
          .mdprev h1,.mdprev h2,.mdprev h3,.mdprev h4,.mdprev h5,.mdprev h6{
            color:#e6e9ef;margin:18px 0 8px;line-height:1.35}
          .mdprev h1{font-size:19px;border-bottom:1px solid #1f2836;padding-bottom:6px}
          .mdprev h2{font-size:16px} .mdprev h3{font-size:14px} .mdprev h4,.mdprev h5,.mdprev h6{font-size:13px}
          .mdprev p{margin:8px 0}
          .mdprev ul,.mdprev ol{margin:8px 0;padding-left:22px}
          .mdprev li{margin:3px 0}
          .mdprev hr{border:0;border-top:1px solid #222a36;margin:16px 0}
          .mdprev blockquote{margin:9px 0;padding:2px 0 2px 11px;border-left:3px solid #25406e;color:#a3adbe}
          .mdprev code{background:#161c28;border:1px solid #222a36;border-radius:5px;padding:1px 5px;
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;color:#cfe0ff}
          .mdprev pre{background:#0b0f16;border:1px solid #1f2836;border-radius:9px;padding:11px 13px;
            overflow:auto;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;
            line-height:1.6;color:#c3cad6;white-space:pre;margin:10px 0}
          .mdprev a{color:#7db0ff}
          .mdprev .mdload{color:#8a93a3}
          .mdedit{flex:1;min-width:0;box-sizing:border-box;border:0;outline:0;resize:none;
            background:#0b0f16;color:#cfd6e3;padding:16px 18px;
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;line-height:1.7}
          .mdfoot{padding:7px 12px;border-top:1px solid #1b2230;color:#68758b;font-size:11px;min-height:15px}
          /* 기록 팝업. 껍데기는 md 팝업의 `.mdw`/`.mdbox`/`.mdh`/`.mdbody`/`.mdfoot` 을 그대로
             쓴다 — 갈라 둔 것은 CSS 가 아니라 동작이다(저장 경로가 애초에 없다).
             새로 만드는 것은 턴 렌더에 필요한 것뿐이다. 사람과 모델은 왼쪽 색 줄로 가른다. */
          .turn{border-left:3px solid #2c3444;padding:1px 0 1px 11px;margin:12px 0}
          .turn.u{border-left-color:#7db0ff}
          .turn.a{border-left-color:#8a93a3}
          .turn .who{color:#68758b;font-size:11px;margin-bottom:4px}
          .turn.u .who{color:#7db0ff}
          .turn .tx{white-space:pre-wrap;word-break:break-word;color:#cfd6e3;font-size:12.5px;line-height:1.7}
          .turn .fs{color:#8a93a3;font-size:11px;margin-top:6px;word-break:break-all;line-height:1.55}
          .turn .fs b{color:#c9b6ff;font-weight:600}
          .trcut{color:#e3b341;background:#2a2210;border:1px solid #5a4520;border-radius:8px;
            padding:8px 11px;font-size:11.5px;line-height:1.6;margin-bottom:6px}
          .mdh .mdt .sub2{display:block;color:#68758b;margin-top:2px}
        </style></head>
        <body>
          <script>window.CM_PAGE='issues';</script>
          \#(SessionRail.html())
          <header>
            <div><h1>이슈</h1><div class="sub" id="isSub">lion_work 에서 위임한 일이 무엇이고 무엇이 끝났는지</div></div>
            <div class="search">
                 <input id="isQ" type="search" autocomplete="off"
                        placeholder="AI 로 찾기 — 예: 링크 정합성 관련해서 뭐 했더라"
                        title="카드 내용을 AI 가 읽고 찾는다. 제목 글자 맞추기가 아니다.">
                 <button class="btn" id="isSearchBtn" onclick="isSearch()">찾기</button>
                 <button class="btn" id="isBulkBtn" onclick="isBulk()">일괄 보관</button>
                 <button class="btn" id="isViewBtn" onclick="isToggleView()">아카이브</button>
                 <button class="btn" onclick="isLoad()">새로고침</button></div>
          </header>
          <main id="isMain">
            <div class="left">
              <div class="heads" id="isHeads"></div>
              <div class="subs" id="isSubs"></div>
              <div id="isNotes"></div>
              <div id="isSBar"></div>
              <div class="filters" id="isFilters"></div>
              <div class="list" id="isList"><div class="empty">큐를 읽는 중…</div></div>
              <div class="foot" id="isFoot"></div>
            </div>
            <div class="det" id="isDet" style="display:none"></div>
          </main>
          <!-- md 팝업. 기본은 프리뷰이고, [에디터] 로 바꿔 고친 뒤 [저장] 하면 그 md 파일에
               실제로 써진다. 렌더는 인라인 JS 가 직접 한다 — 이 앱은 루프백 전용이고 외부
               CDN 을 끌어오지 않는 것이 설계 원칙이다. -->
          <div class="mdw" id="isMdWrap" style="display:none">
            <div class="mdbox">
              <div class="mdh">
                <div class="mdt" id="isMdPath"></div>
                <button class="tab on" id="isMdTabP" onclick="isMdMode(0)">프리뷰</button>
                <button class="tab" id="isMdTabE" onclick="isMdMode(1)">에디터</button>
                <button class="open" id="isMdSaveBtn" onclick="isMdSave()" style="display:none">저장</button>
                <button class="open" id="isMdCloseBtn" onclick="isMdClose()">닫기</button>
              </div>
              <div class="mdbody">
                <div class="mdprev" id="isMdPrev"></div>
                <textarea class="mdedit" id="isMdEdit" style="display:none" spellcheck="false"></textarea>
              </div>
              <div class="mdfoot" id="isMdMsg"></div>
            </div>
          </div>
          <!-- 세션 기록 팝업. **읽기 전용이다.** md 팝업과 껍데기 CSS 를 같이 쓰지만 통로가
               갈려 있어 저장 경로가 애초에 없다 — 기록은 하네스가 쓰는 append-only 파일이고,
               저장 버튼을 숨기는 것으로 막으면 막는 것이 화면 상태 하나가 되어 언젠가 깨진다.
               마크다운 렌더도 하지 않는다. 기록은 md 가 아니고, 렌더하면 그것이 곧 XSS 다. -->
          <div class="mdw" id="isTrWrap" style="display:none">
            <div class="mdbox" id="isTrBox">
              <div class="mdh">
                <div class="mdt" id="isTrPath"></div>
                <button class="open" id="isTrCloseBtn" onclick="isTrClose()">닫기</button>
              </div>
              <div class="mdbody"><div class="mdprev" id="isTrBody"></div></div>
              <div class="mdfoot" id="isTrFoot"></div>
            </div>
          </div>
        <script>
        (function(){
          var D=null, F={bucket:'전체', track:'전체', target:'전체'};
          var BCLS={'완료':'done','도는 중':'run','대기':'wait','막힘':'blocked','미분류':'unk'};
          var SEL=null, DET=null;
          // 수정된 최초의 리퀘스트도 원문과 같은 3 단이다 — 0 접힘(기본) · 1 다섯 줄 · 2 전문.
          // DASH-14 이전에는 불리언이었고 기본이 펼침이었다. 라이언이 이 절을 콕 집어
          // "기본적으로 접혀있고 그걸 전문으로 볼 수 있게" 라고 했으므로 아래 ORIGOPEN 과
          // 같은 모양으로 맞춘다. 화면의 두 절이 같은 말을 다른 손잡이로 하면 안 된다.
          var CLEANOPEN=0;
          // 원문 박스는 세 단계다 — 0 접힘(기본) · 1 다섯 줄 · 2 전문.
          // 불리언이었을 때는 펼치면 곧바로 전문이 쏟아져 그 아래 절이 화면 밖으로
          // 밀렸다. 라이언이 원한 것은 "펼치면 5줄" 이므로 중간 단이 필요하다.
          var ORIGOPEN=0;
          // 세션에서 끌어온 두 덩어리(첫 지시문 · 마지막 보고)의 펼침. 원문과 같은 이유로
          // 기본은 5 줄이다 — 지시문 전문이 2 만 자까지 오므로 펼친 채로 두면 그 아래 절이
          // 화면 밖으로 밀린다.
          var SESOPEN=0, REPOPEN=0;
          // 보고 있는 것이 산 목록인가 보관함인가. 아카이브는 상태값이 아니라 다른 축이라
          // 필터(F)와 섞지 않고 따로 둔다 — 섞으면 여섯째 버킷이 되어 버린다.
          var VIEW='live';
          // 검색도 같은 이유로 F 와 섞지 않는다. 검색은 목록을 좁히는 축이 아니라 **순서를
          // 정하는 축**이다 — 관련도 순으로 다시 세우고, 필터는 그 위에서 그대로 돈다.
          // null 이면 검색이 안 걸린 상태이고 목록은 평소대로 날짜 순이다.
          var Q=null;          // {q, mode, model, note, error, scanned, order:[key], why:{key:text}}
          var QRUN=false;      // 검색이 도는 중인가 (버튼 두 번 눌리는 것을 막는다)
          var BULKARM=0;       // 일괄 보관의 두 번째 누름을 기다리는 시각. 0 이면 안 눌린 상태.
          var SHOWN=[];        // 지금 목록에 그려진 카드의 키. 일괄 보관이 치울 범위가 이것이다.

          // 상세를 가리키는 키. `id:` 가 아니라 `<레인>/<파일명>` 이다 — 같은 `id:` 를 가진 카드가
          // inbox/ 와 done/ 에 하나씩 남아 있는 쌍이 4 쌍 있어서 id 로는 어느 쪽인지 안 정해진다.
          function key(c){ return c.folder+'/'+String(c.file||'').replace(/\.md$/,''); }

          function esc(s){ return String(s==null?'':s)
            .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

          // 저장된 ISO 시각을 **표시 타임존**(설정값 · 서버가 주입한 window.CM_TZ)의 벽시계로
          // 찍는다. 이 화면이 다루는 시각은 하네스 트랜스크립트의 `timestamp` 처럼 UTC(`…Z`)
          // 라서, 예전처럼 문자열을 잘라 쓰면 KST 16:31 인 세션이 `07:31` 로 보인다.
          // 변환 규칙 한 벌은 CMTimeFilter.isoDisp 에 있다(레일이 임베드한다). 그것이 아직
          // 없으면 옛 동작으로 떨어져 화면이 비지는 않게 한다.
          function tdisp(v,len,sep){
            return (window.CMTimeFilter && CMTimeFilter.isoDisp)
              ? CMTimeFilter.isoDisp(v,len,sep)
              : String(v==null?'':v).replace('T',(sep===undefined?' ':sep)).slice(0,len||16);
          }

          // captured 는 13 가지 모양으로 갈려 있다(오프셋 있는 것/없는 것/붙여 쓴 HHMM). 화면에서는
          // 파서가 이미 만들어 둔 정렬 키(YYYYMMDDHHMMSS)에서 잘라 쓴다 — 여기서 다시 파싱하면
          // 목록의 정렬과 표시가 서로 다른 규칙을 쓰게 된다.
          function when(c){
            var k=c.capturedKey||'';
            if(k.length<12) return c.captured||'—';
            return k.slice(2,4)+'-'+k.slice(4,6)+'-'+k.slice(6,8)+' '+k.slice(8,10)+':'+k.slice(10,12);
          }

          function chip(label, count, on, group, value, why){
            return '<span class="chip'+(on?' on':'')+'"'+(why?' title="'+esc(why)+'"':'')
              + ' onclick="isPick(\''+group+'\',\''+esc(value)+'\')">'
              + esc(label) + (count==null?'':'<span class="c">'+count+'</span>') + '</span>';
          }

          // 버킷 하나의 규칙. 2026-09-06 라이언: "막힘 요거는 왜 있는 건지 설명이 들어가면 좋을
          // 것 같은데 … 마우스 오버를 하면은 왜 막힘로 여기는 어떤 걸로 분류가 되는건지".
          //
          // ASSUMPTION (L1, 갈래를 스스로 골랐다): 규칙 문구는 서버가 준 `bucketRules` 를 쓰고
          // 없으면 아무 말도 하지 않는다. 여기서 문장을 만들어 두면 WorkQueueStore 의 정규화
          // 표가 늘 때 화면만 옛말을 계속하게 되고, 틀린 설명은 없는 설명보다 나쁘다.
          function ruleOf(b){ return (D&&D.bucketRules&&D.bucketRules[b])||''; }

          window.isPick=function(group,value){ F[group]=value; render(); };

          function render(){
            if(!D) return;
            var cs=D.cards||[], cnt=(D.counts||{}), bb=(cnt.byBucket||{});

            // 보관함으로 가는 문. 숫자를 얼굴에 붙이는 이유는 라이언이 "치운 게 몇 개였지" 를
            // 확인하려고 눌러 보게 하지 않기 위한 것이다. 세는 것은 서버이고 여기서 안 센다.
            var vb=document.getElementById('isViewBtn');
            if(vb) vb.textContent = (VIEW==='archive') ? '목록으로' : ('아카이브 ('+(D.archivedCount||0)+')');

            // 큰 수 둘. 안 됨은 전체에서 완료를 뺀 것 — 셋을 더해서 만들면 미분류가 빠질 수 있다.
            document.getElementById('isHeads').innerHTML =
                '<div class="big ok"><div class="n">'+(cnt.done||0)+'</div><div class="k">완료</div></div>'
              + '<div class="big no"><div class="n">'+(cnt.notDone||0)+'</div><div class="k">안 됨</div></div>'
              + '<div class="big"><div class="n">'+(cnt.total||0)+'</div><div class="k">전체 카드</div></div>';
            // 네 칸 다 마우스를 올리면 왜 그 칸인지가 나온다. 라이언이 물은 것은 `막힘` 이지만
            // 하나만 설명하면 나머지 셋은 설명이 없다는 것이 규칙처럼 읽힌다.
            function subCard(cls, b, label){
              var r=ruleOf(b);
              return '<div class="card'+(cls?' '+cls:'')+'"'+(r?' title="'+esc(r)+'"':'')+'>'
                + '<div class="n">'+(bb[b]||0)+'</div>'
                + '<div class="k'+(r?' hint':'')+'">'+esc(label||b)+'</div></div>';
            }
            document.getElementById('isSubs').innerHTML =
                subCard('', '도는 중', '도는 중')
              + subCard('', '대기', '대기')
              + subCard('blocked', '막힘', '막힘 · 사람이 봐야 한다')
              + subCard('unk', '미분류', '미분류');

            // 없는 것을 없다고 쓰는 자리. 셋 다 서로 다른 사건이고 라이언이 할 일이 다르다.
            var notes='';
            if(!D.rootExists){
              notes += '<div class="note bad"><div class="t">큐 폴더를 못 찾았다</div>'
                + '찾아본 경로 <code>'+esc(D.root)+'</code> 가 없다. 목록이 비어 있는 것이 아니라 <b>읽지 못한 것</b>이다.'
                + (D.envOverride?' (환경변수 <code>CM_WORK_QUEUE_DIR</code> 로 덮어쓴 경로다.)':'')+'</div>';
            }
            if((bb['미분류']||0)>0){
              notes += '<div class="note"><div class="t">모르는 상태값이 있다</div>'
                + '<b>'+(bb['미분류'])+'건</b>의 <code>status:</code> 값이 버킷 표에 없다. 완료로 흘리지 않고 여기 세워 둔다 — '
                + 'WorkQueueStore.bucket(for:) 의 표에 그 값을 더해야 한다.</div>';
            }
            var ifd=D.issueFolder||{};
            if(ifd.set && !ifd.exists){
              notes += '<div class="note"><div class="t">이슈 문서 폴더</div>설정에서 고른 <code>'+esc(ifd.path)+'</code> 가 '
                + '디스크에 없다. 위 목록(위임 카드)과는 다른 원천이고, 이 화면의 숫자에는 섞이지 않았다.</div>';
            } else if(ifd.set && ifd.count===0){
              notes += '<div class="note"><div class="t">이슈 문서 폴더</div><code>'+esc(ifd.path)+'</code> 는 있는데 '
                + '<b>문서가 0 개</b>다. 위 목록은 위임 카드에서 온 것이고 이 폴더와 무관하다.</div>';
            }
            if((D.laneDuplicates||0)>0){
              notes += '<div class="note"><div class="t">같은 카드가 두 레인에 있다</div>'
                + '<b>'+D.laneDuplicates+'건</b>의 카드 파일이 <code>inbox/</code> 와 <code>done/</code> 에 같은 이름으로 '
                + '둘 다 남아 있다. 위 숫자에는 두 번 세어져 있고, 정리는 큐 PM 의 자리다. '
                + '이 화면은 큐 폴더에 아무것도 쓰지 않으므로 여기서 지우지 않는다.</div>';
            }
            document.getElementById('isNotes').innerHTML=notes;

            // 필터 — 카운트를 붙여 고르기 전에 몇 개인지 보이게 한다.
            var order=D.bucketOrder||[], tracks=D.tracks||{}, targets=D.targets||{};
            var h='<div class="frow"><span class="fl">상태</span>'+chip('전체',cnt.total||0,F.bucket==='전체','bucket','전체');
            for(var i=0;i<order.length;i++) h+=chip(order[i], bb[order[i]]||0, F.bucket===order[i], 'bucket', order[i], ruleOf(order[i]));
            h+='</div><div class="frow"><span class="fl">트랙</span>'+chip('전체',null,F.track==='전체','track','전체');
            var tk=Object.keys(tracks).sort();
            for(var j=0;j<tk.length;j++) h+=chip(tk[j], tracks[tk[j]], F.track===tk[j], 'track', tk[j]);
            h+='</div><div class="frow"><span class="fl">대상</span><select onchange="isPick(\'target\',this.value)">';
            var gk=Object.keys(targets).sort(function(a,b){ return targets[b]-targets[a] || (a<b?-1:1); });
            h+='<option value="전체"'+(F.target==='전체'?' selected':'')+'>전체 ('+(cnt.total||0)+')</option>';
            for(var g=0;g<gk.length;g++)
              h+='<option value="'+esc(gk[g])+'"'+(F.target===gk[g]?' selected':'')+'>'+esc(gk[g])+' ('+targets[gk[g]]+')</option>';
            h+='</select></div>';
            document.getElementById('isFilters').innerHTML=h;

            var rows=cs.filter(function(c){
              if(F.bucket!=='전체' && c.bucket!==F.bucket) return false;
              if(F.track!=='전체' && c.track!==F.track) return false;
              if(F.target!=='전체' && (c.target||'없음')!==F.target) return false;
              return true;
            });

            // 검색이 걸려 있으면 찾은 것만, 찾은 순서(관련도)대로 세운다. 날짜 순으로 두면
            // 관련도 1 등이 목록 한가운데 묻혀서 AI 가 고른 값이 그 자리에서 사라진다.
            if(Q){
              var rank={}, ri;
              for(ri=0;ri<Q.order.length;ri++) rank[Q.order[ri]]=ri;
              rows=rows.filter(function(c){ return rank[key(c)]!=null; })
                       .sort(function(a,b){ return rank[key(a)]-rank[key(b)]; });
            }

            // 일괄 보관이 무엇을 치울지는 **지금 보이는 이 목록**이다. 서버가 "전부" 를 스스로
            // 정하지 않고 이 키 목록을 받아 그것만 치운다 — 라이언이 방금 좁혀 놓은 것을
            // 무시하면 되돌리기가 있어도 나쁜 실패다.
            SHOWN = rows.map(key);

            var el=document.getElementById('isList');
            // 보관함에서는 마지막 칸이 트랙이 아니라 [보관 해제] 버튼이라 칸을 넓힌다.
            el.className = 'list' + (VIEW==='archive' ? ' arch' : '');
            if(!rows.length){
              // 네 사건을 갈라 쓴다: 못 읽은 것, 필터에 안 걸리는 것, 카드가 0 개인 것, 그리고
              // 보관한 것이 없는 것. 넷은 라이언이 할 일이 서로 다르므로 문구를 합치지 않는다.
              el.innerHTML='<div class="empty">'
                + (!D.rootExists ? '큐 폴더를 읽지 못했다. 위 상자의 경로를 확인해라.'
                   // 검색이 걸린 채로 0 건인 것은 다시 두 사건이다. 찾은 것이 아예 없는 것과,
                   // 찾긴 했는데 그것들이 지금 보고 있는 쪽(산 목록/보관함)에 없는 것.
                   // 둘은 라이언이 할 일이 다르므로 문구를 합치지 않는다.
                   : (Q ? (Q.order.length
                            ? '찾은 '+Q.order.length+' 개가 지금 화면에 없다. '
                              + (VIEW==='archive' ? '[목록으로] 를 눌러 봐라.' : '[아카이브] 에 있거나 필터에 걸렸다.')
                            : '「'+esc(Q.q)+'」 로 찾은 카드가 없다.')
                   : (VIEW==='archive' && !cnt.total ? '보관한 것이 없다.'
                   : (cnt.total ? '이 필터에 걸리는 카드가 없다. 상태·트랙·대상을 전체로 되돌려 봐라.'
                                : '큐 폴더는 있는데 카드가 0 개다. inbox/ 와 done/ 에 .md 가 없다.'))))
                + '</div>';
            } else {
              var out='';
              for(var r=0;r<rows.length;r++){
                var c=rows[r], cls=BCLS[c.bucket]||'unk';
                var tcls=c.track==='FAST'?'fast':(c.track==='BEST'?'best':'');
                var k=key(c);
                // 배지에 마우스를 올리면 왜 이 버킷인지가 나온다. 문구는 서버가 정규화 표에서
                // 만든 것이고(WorkQueueStore.bucketWhy), 없으면 버킷 규칙으로 떨어진다.
                var bwhy=c.bucketWhy||ruleOf(c.bucket);
                out+='<div class="row'+(SEL===k?' sel':'')+'" onclick="isOpen(\''+esc(k)+'\')">'
                  + '<span class="bdg '+cls+(bwhy?' hint':'')+'"'
                  + (bwhy?' title="'+esc(bwhy)+'"':'')+'>'+esc(c.bucket)+'</span>'
                  + '<span class="dt">'+esc(when(c))+'</span>'
                  + '<div class="ti"><div class="h" title="'+esc(c.id)+'">'+esc(c.title)+'</div>'
                  + '<div class="m"><span class="raw" title="카드에 적힌 원래 status 값">status: '+esc(c.status||'(없음)')+'</span>'
                  + '<span class="tg">'+esc(c.target||'대상 없음')+'</span>'
                  + '<span class="tg">'+esc(c.folder)+'/</span>'
                  // 어디까지 갔나. 결과물 없음이 다수(85 중 59)라 목록에서도 단계를 말한다.
                  + '<span class="tg" title="요청만 → 작업지시서까지 → 결과물까지">'+esc(c.stage||'')
                  + (c.artifactCount>0?' ('+c.artifactCount+')':'')+'</span>'
                  + (c.cleanup?'<span class="tg">정리 '+esc(c.cleanup)+'</span>':'')
                  + (c.parsed?'':'<span class="raw">프론트매터를 못 읽었다</span>')
                  // 보관 당시의 버킷. 지금 값과 다르면 눈에 띄게 둘 다 보인다 — 보관해 둔
                  // 사이에 카드가 계속 바뀐 것을 감추면 그것이 화면의 거짓말이다.
                  + (c.prevBucket
                     ? '<span class="'+(c.prevBucket===c.bucket?'tg':'raw')+'">보관 당시 '
                       + esc(c.prevBucket)+'</span>' : '')
                  + '</div>'
                  // AI 가 왜 이 카드를 골랐는지. 검색이 안 걸렸으면 아무것도 안 그린다.
                  + ((Q&&Q.why[k])?'<div class="whyhit">'+esc(Q.why[k])+'</div>':'')
                  + '</div>'
                  + (VIEW==='archive'
                     ? '<button class="open" onclick="isUnarchive(event,this,\''+esc(k)+'\')">보관 해제</button>'
                     // 목록에서 바로 치운다. 상세를 열어야만 나오는 버튼은 "액션을 취할 수
                     // 있는데 이게 없네" 라는 지적을 못 지운다. 버킷을 안 따지므로 미분류에도
                     // 그대로 붙는다 — 보관은 상태값이 아니라 다른 축이기 때문이다.
                     : '<div class="act"><span class="trk '+tcls+'">'+esc(c.track)+'</span>'
                       + '<button class="open" title="이 카드를 목록에서 치운다. 아카이브에서 되돌릴 수 있다."'
                       + ' onclick="isRowArchive(event,this,\''+esc(k)+'\')">보관</button></div>')
                  + '</div>';
              }
              el.innerHTML=out;
            }
            drawSearchBar();

            // 일괄 보관은 두 번 눌러야 실행된다. confirm() 은 이 웹뷰에서 대화상자를 띄워 줄
            // 델리게이트가 있어야 동작하는데 그것에 기대면 아무 일도 안 일어나는 침묵이 된다.
            // 버튼 자신이 되묻는 것은 그 의존이 없다.
            var bk=document.getElementById('isBulkBtn');
            if(bk){
              // 보관함에서는 숨긴다. 거기서 "일괄 보관" 은 뜻이 없고, 일괄 해제는 라이언이
              // 말하지 않은 것이라 만들지 않는다.
              bk.style.display = (VIEW==='archive') ? 'none' : '';
              bk.disabled = !SHOWN.length;
              bk.textContent = BULKARM
                ? ('정말? 한 번 더 ('+SHOWN.length+')')
                : ('일괄 보관 ('+SHOWN.length+')');
              bk.title = '지금 이 목록에 보이는 '+SHOWN.length+' 개를 한 번에 보관한다. '
                       + '필터를 걸어 두면 걸린 것만 치운다. 아카이브에서 하나씩 되돌릴 수 있다.';
            }

            document.getElementById('isFoot').innerHTML =
              '보이는 카드 '+rows.length+' / 전체 '+(cnt.total||0)+' · 원천 <code>'+esc(D.root)+'</code>'
              + ' · 완료 판정은 폴더가 아니라 카드의 status 값으로 한다 (done/ 안에 완료가 아닌 카드가 섞여 있다).'
              // 이 수가 무너지면 여섯 키 파싱이 무너진 것이다. `output:` 하나만 읽으면 26 이 4 가 된다.
              + '<br>결과물이 적힌 카드 <b>'+(D.withArtifacts||0)+'</b> · 작업지시서가 적힌 카드 <b>'
              + (D.withDirective||0)+'</b> · 나머지는 요청만 있다. 산출물 키는 여섯 이름으로 갈려 있어 여섯을 다 읽는다.';
          }

          // ── 상세 ─────────────────────────────────────────────────────────────

          // `v1 · 2026-09-05 첫 관측 · 마지막`. 없는 역사를 있는 척하지 않는 것이 이 배지의 값이다.
          // 이 원장은 오늘 처음 켜졌고 v1 은 "한 번 바뀌었다" 가 아니라 "처음 봤다" 는 뜻이다.
          function verLabel(v){
            if(!v) return 'v?';
            return 'v'+v.v+' · '+tdisp(v.firstSeen,10)+(v.isFirstObservation?' 첫 관측':'');
          }

          var KCLS={'있음':'ok','경로 없음':'no','URL':'url','경로 아님':'nap','대상 폴더 없음':'notgt'};
          // 값 하나를 한 줄로. 존재 확인을 실제로 한 결과만 `있음` 이라고 쓴다 — 죽은 버튼을
          // 눌러 아무 일도 안 일어나는 것이 라이언이 창을 여는 이유가 된다.
          function artRow(a){
            var label, cls;
            if(a.kind==='URL'){ label='URL'; }
            else if(a.kind==='경로 아님'){ label='경로 아님'; }
            else if(a.kind==='대상 폴더 없음'){ label='대상 폴더 없음'; }
            else { label=a.exists?'있음':'경로 없음'; }
            cls=KCLS[label]||'nap';
            var btn='';
            if(a.kind==='URL'){
              btn='<a class="open" href="'+esc(a.raw)+'" target="_blank" rel="noopener">링크 열기</a>';
            } else if(a.openable){
              btn='<button class="open" onclick="isReveal(this,\''+esc(a.path)+'\')">'
                + (a.isDir?'폴더 열기':'파일 열기')+'</button>';
            }
            // 경로 한 줄 자체를 밑줄 링크로 만든다 — 단, **.md 이고 디스크에 실재하는 파일**
            // 일 때만이다. 라이언: "md파일을 언더바가 되어 있어서 클릭을 하게 되면 md 파일이
            // 열리게 해줘요 … 지금 화면에서 팝업으로". md 가 아니거나 없는 경로는 예전 그대로
            // 평문이다 — 눌러도 아무 일이 안 일어나는 링크가 죽은 버튼보다 나쁘다.
            // 경로는 JS 문자열 리터럴이 아니라 data-p 로 넘긴다. 리터럴에 넣으면 따옴표가 든
            // 경로 하나에 onclick 이 통째로 깨지는데, 속성은 esc 가 이미 " 를 막아 준다.
            var head=esc(a.raw);
            if(a.kind!=='URL'&&!a.isDir&&a.exists&&a.path&&/\.md$/i.test(a.path)){
              head='<a class="mdlink" data-p="'+esc(a.path)+'" onclick="isMd(this)"'
                 + ' title="이 화면에서 열어 보고 고친다">'+esc(a.raw)+'</a>';
            }
            return '<div class="art"><div class="p">'+head
              + '<div class="k">'+esc(a.key)+':'
              + (a.kind!=='URL'&&a.kind!=='경로 아님' ? ' · '+esc(a.kind) : '')
              + (a.path&&a.path!==a.raw ? ' · '+esc(a.path) : '')
              + '</div></div>'
              + '<span class="st '+cls+'">'+esc(label)+'</span>'+btn+'</div>';
          }

          // 세션 블록의 머리 한 줄. 어느 세션인지와 얼마나 돌았는지를 말한다. 이것이 없으면
          // 화면에 갑자기 나타난 긴 글이 어디서 왔는지 알 수 없고, 출처를 모르는 글은 근거가
          // 아니라 소음이다.
          //
          // 2026-09-06 부터 이 줄은 누를 수 있다. 라이언이 스크린샷의 `97cc3cc2` 에 동그라미를
          // 치고 그 줄 오른쪽 빈 공간에 네모를 그렸다 — "누르면은 그 파일이 열리게끔 그래서
          // 내용을 볼 수 있게끔 그리고 오른쪽에 있는 곳은 거기다가 이제 파일 열기 폴더 열기를".
          //
          // 경로는 JS 문자열 리터럴이 아니라 **data-p 속성**으로 넘긴다. 리터럴에 넣으면
          // 따옴표가 든 경로 하나에 onclick 이 통째로 깨지는데, 속성은 esc 가 이미 " 를 막아
          // 준다. artRow 의 mdlink 가 이미 그 규칙을 쓴다.
          //
          // `S.file` 이 비면 링크도 버튼도 **아예 안 그린다.** 눌러도 아무 일이 안 나는 버튼이
          // 죽은 버튼보다 나쁘다 — 이 파일이 이미 지키는 규칙이다.
          function sesHead(S){
            var sid=String(S.sessionId||'').slice(0,8);
            var f=String(S.file||''), cwd=String(S.cwd||''), pd=String(S.projectDir||'');
            var idHTML = f
              ? '<a class="sesid" data-p="'+esc(f)+'" onclick="isTr(this)"'
                + ' title="이 세션의 기록을 이 화면에서 읽는다 (읽기 전용)">'+esc(sid)+'</a>'
              : '<b>'+esc(sid)+'</b>';
            var txt='세션 '+idHTML
              + ' · '+esc(tdisp(S.startedAt,16))
              + ' · 사람 말 '+(S.userTurns||0)+' 번'
              + ' · 쓴 파일 '+(S.writeCount||0)+' 개';
            if(!f) return txt;
            // 폴더 열기가 여는 것은 **그 세션이 일한 작업 폴더**다. 기록 폴더로 잡으면
            // activateFileViewerSelecting 이 이미 그 폴더를 열어 주므로 버튼 둘이 화면에서
            // 같은 일을 한다. cwd 를 기록에서 못 읽었을 때만 기록 폴더로 떨어지고, 그때는
            // 무엇을 여는지 title 에 그대로 적는다 — 조용히 다른 것을 열지 않는다.
            var folder = cwd || pd;
            var ftitle = cwd
              ? '이 세션이 일한 작업 폴더를 Finder 에서 연다 — '+cwd
              : '작업 폴더를 기록에서 못 읽었다. 기록이 든 폴더를 연다 — '+pd;
            var btns='<span class="shb">'
              + '<button class="open" data-p="'+esc(f)+'" onclick="isRevealEl(this)"'
              + ' title="이 기록 파일을 Finder 에서 선택한다 — '+esc(f)+'">파일 열기</button>';
            if(folder){
              btns += '<button class="open" data-p="'+esc(folder)+'" onclick="isRevealEl(this)"'
                + ' title="'+esc(ftitle)+'">폴더 열기</button>';
            }
            return txt + btns + '</span>';
          }

          // 긴 글 상자. 기본은 5 줄이고 누르면 전문이다. 왜 5 인가는 위 `.orig.o5` 주석에
          // 라이언이 댄 이유 그대로 있다 — "속독을 해도 5줄 이상을 보기 어려우니까".
          // 여기서 접힘(0 단)을 두지 않는 이유는 이 자리가 `없음` 을 대신하는 자리라서다.
          // 접어 두면 화면은 다시 아무것도 안 말하고, 그러면 이 기능이 있으나 마나다.
          function longBox(t, open, setter){
            if(!t) return '';
            var n=t.length.toLocaleString();
            return '<div class="orig '+(open?'open':'o5')+'">'+esc(t)+'</div>'
              + (open ? '<button class="lnk" onclick="'+setter+'(0)">5 줄만 보기</button>'
                      : '<button class="lnk" onclick="'+setter+'(1)">전문 보기 ('+n+'자)</button>');
          }

          window.isReveal=function(btn,p){
            fetch('/api/issues/reveal',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({path:p})}).then(function(r){ return r.json(); }).then(function(j){
                if(j&&j.ok) return;
                // 거절도 화면에 말한다. 조용히 아무 일도 안 일어나면 라이언이 창을 연다.
                btn.textContent = (j&&j.error==='missing') ? '지금은 없다' : '열 수 없다';
              }).catch(function(){ btn.textContent='열 수 없다'; });
          };

          // 같은 일을 하되 경로를 **data-p 속성**에서 읽는다. 세션에서 파낸 경로는 카드에 적힌
          // 것과 달리 사람이 손으로 쓴 적이 없어 무엇이든 들어 있을 수 있고, 그 경로를 JS 문자열
          // 리터럴에 넣으면 따옴표 하나에 onclick 이 통째로 깨진다. 속성은 esc 가 " 를 막아 준다.
          window.isRevealEl=function(btn){
            var p=(btn&&btn.getAttribute)?btn.getAttribute('data-p'):'';
            if(p) isReveal(btn,p);
          };

          // Orca 로 열기. 서버로 나가는 것은 카드 키 하나뿐이다 — 작업 폴더도 창 제목도
          // 서버가 카드에서 만든다. 결과물이 마음에 안 들 때 그 자리에서 버전을 올리러 간다.
          function orcaBtn(){
            return '<button class="open" onclick="isOrca(this)">Orca 로 열기</button>';
          }

          window.isOrca=function(btn){
            var was=btn.textContent;
            fetch('/api/issues/orca',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({path:SEL})}).then(function(r){ return r.json(); }).then(function(j){
                // isReveal 과 같은 규칙이다 — 실패를 버튼 얼굴에 말한다. 눌렀는데 아무 일도
                // 안 일어나는 침묵이 라이언이 다른 창을 여는 이유다.
                btn.textContent = (j&&j.ok) ? '열었다'
                  : (j&&j.error==='no-orca') ? 'orca 없음'
                  : (j&&j.error==='missing-root') ? '폴더 없음' : '열 수 없다';
                setTimeout(function(){ btn.textContent=was; }, 2000);
              }).catch(function(){
                btn.textContent='열 수 없다';
                setTimeout(function(){ btn.textContent=was; }, 2000);
              });
          };

          // ── md 팝업 ────────────────────────────────────────────────────────────
          //
          // 최소 마크다운 렌더. **외부 CDN 을 끌어오지 않는다** — 이 앱은 루프백 전용이고 외부
          // 의존성 0 이 설계 원칙이라, marked.js 하나를 위해 그 원칙을 깨지 않는다.
          //
          // 순서가 규칙이다. **먼저 이스케이프하고 그다음 마크업을 붙인다.** 거꾸로 하면 방금
          // 만든 <b> 가 &lt;b&gt; 로 죽거나, 파일 안의 <script> 가 살아서 들어온다. 여기는
          // innerHTML 싱크라 그 실수 하나가 곧 XSS 다.
          function mdInline(s){
            s=s.replace(/`([^`]+)`/g,'<code>$1</code>');
            s=s.replace(/\*\*([^*]+)\*\*/g,'<b>$1</b>');
            s=s.replace(/(^|[^*])\*([^*]+)\*/g,'$1<i>$2</i>');
            // 링크는 http/https 만 연다. javascript: 를 막는 자리이고, 그 밖의 것은 링크가
            // 아니라 글자로 남긴다 — 눌러도 안 되는 링크보다 안 눌리는 글자가 정직하다.
            s=s.replace(/\[([^\]]*)\]\(([^)\s]+)\)/g,function(m,t,u){
              if(/^https?:\/\//i.test(u)) return '<a href="'+u+'" target="_blank" rel="noopener">'+t+'</a>';
              return t+' ('+u+')';
            });
            return s;
          }
          function mdRender(src){
            var lines=String(src==null?'':src).replace(/\r\n?/g,'\n').split('\n');
            var out=[], inCode=false, code=[], list=null;
            function closeList(){ if(list){ out.push('</'+list+'>'); list=null; } }
            for(var i=0;i<lines.length;i++){
              var ln=lines[i], m;
              if(/^\s*```/.test(ln)){
                if(inCode){ out.push('<pre>'+esc(code.join('\n'))+'</pre>'); code=[]; inCode=false; }
                else { closeList(); inCode=true; }
                continue;
              }
              if(inCode){ code.push(ln); continue; }
              if(/^\s*$/.test(ln)){ closeList(); continue; }
              if(/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(ln)){ closeList(); out.push('<hr>'); continue; }
              if((m=/^(#{1,6})\s+(.*)$/.exec(ln))){
                closeList(); var n=m[1].length;
                out.push('<h'+n+'>'+mdInline(esc(m[2]))+'</h'+n+'>'); continue;
              }
              if((m=/^\s*>\s?(.*)$/.exec(ln))){
                closeList(); out.push('<blockquote>'+mdInline(esc(m[1]))+'</blockquote>'); continue;
              }
              if((m=/^\s*[-*+]\s+(.*)$/.exec(ln))){
                if(list!=='ul'){ closeList(); out.push('<ul>'); list='ul'; }
                out.push('<li>'+mdInline(esc(m[1]))+'</li>'); continue;
              }
              if((m=/^\s*\d+[.)]\s+(.*)$/.exec(ln))){
                if(list!=='ol'){ closeList(); out.push('<ol>'); list='ol'; }
                out.push('<li>'+mdInline(esc(m[1]))+'</li>'); continue;
              }
              closeList(); out.push('<p>'+mdInline(esc(ln))+'</p>');
            }
            if(inCode) out.push('<pre>'+esc(code.join('\n'))+'</pre>');
            closeList();
            return out.join('');
          }

          var MDP=null;        // 지금 팝업이 물고 있는 파일의 절대경로. null 이면 닫힌 상태.
          var MDTEXT='';       // 마지막으로 서버와 맞춰진 본문. 저장 안 한 변경을 재는 기준이다.
          var MDCLOSEARM=0;    // 저장 안 한 채로 닫기를 한 번 눌렀는가 (일괄 보관과 같은 두 번 누르기)

          function mdErr(j){
            var e=(j&&j.error)||'';
            if(e==='unknown-path') return '이 파일은 열 수 없다 (허용 목록 밖)';
            if(e==='missing')      return '지금은 없다';
            if(e==='unreadable')   return '읽지 못했다 (UTF-8 이 아닐 수 있다)';
            if(e==='too-large')    return '너무 커서 안 연다';
            return e||'알 수 없는 이유';
          }

          // 0 프리뷰(기본) · 1 에디터. 프리뷰로 돌아올 때는 저장된 것이 아니라 **지금 편집기에
          // 있는 것**을 그린다 — 고치는 중에 어떻게 보이는지가 이 전환의 목적이라서다.
          window.isMdMode=function(mode){
            var pv=document.getElementById('isMdPrev'), ed=document.getElementById('isMdEdit');
            var tp=document.getElementById('isMdTabP'), te=document.getElementById('isMdTabE');
            var sv=document.getElementById('isMdSaveBtn');
            if(mode){
              pv.style.display='none'; ed.style.display=''; sv.style.display='';
              tp.className='tab'; te.className='tab on'; ed.focus();
            } else {
              if(ed.value!=='' || MDTEXT!=='') pv.innerHTML=mdRender(ed.value);
              pv.style.display=''; ed.style.display='none'; sv.style.display='none';
              tp.className='tab on'; te.className='tab';
            }
          };

          window.isMd=function(el){
            var p=(el&&el.getAttribute)?el.getAttribute('data-p'):String(el||'');
            if(!p) return;
            MDP=p; MDTEXT=''; MDCLOSEARM=0;
            document.getElementById('isMdPath').textContent=p;
            document.getElementById('isMdEdit').value='';
            document.getElementById('isMdPrev').innerHTML='<p class="mdload">읽는 중…</p>';
            document.getElementById('isMdMsg').textContent='';
            document.getElementById('isMdCloseBtn').textContent='닫기';
            document.getElementById('isMdWrap').style.display='flex';
            isMdMode(0);
            fetch('/api/issues/mdfile?path='+encodeURIComponent(p))
              .then(function(r){ return r.json(); })
              .then(function(j){
                if(MDP!==p) return;   // 그 사이에 다른 파일을 열었으면 늦게 온 응답은 버린다
                if(!j||!j.ok){
                  document.getElementById('isMdPrev').innerHTML='<p class="mdload">'+esc(mdErr(j))+'</p>';
                  return;
                }
                MDTEXT=j.text||'';
                document.getElementById('isMdEdit').value=MDTEXT;
                document.getElementById('isMdPrev').innerHTML=mdRender(MDTEXT);
                document.getElementById('isMdMsg').textContent=MDTEXT.length.toLocaleString()+'자';
              })
              .catch(function(e){
                if(MDP!==p) return;
                document.getElementById('isMdPrev').innerHTML='<p class="mdload">읽지 못했다 — '
                  + esc(String(e&&e.message))+'</p>';
              });
          };

          window.isMdSave=function(){
            if(!MDP) return;
            var t=document.getElementById('isMdEdit').value;
            var msg=document.getElementById('isMdMsg');
            msg.textContent='저장 중…';
            fetch('/api/issues/mdsave',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({path:MDP,text:t})}).then(function(r){ return r.json(); })
              .then(function(j){
                if(j&&j.ok){
                  MDTEXT=t; MDCLOSEARM=0;
                  document.getElementById('isMdCloseBtn').textContent='닫기';
                  document.getElementById('isMdPrev').innerHTML=mdRender(t);
                  msg.textContent='저장했다 · '+(j.bytes||0)+' 바이트 · '
                    + new Date().toTimeString().slice(0,8);
                } else {
                  // isReveal 과 같은 규칙 — 실패를 화면에 말한다. 눌렀는데 아무 일도 안 일어나는
                  // 침묵이 라이언이 다른 창을 여는 이유다.
                  msg.textContent='저장하지 못했다 — '+mdErr(j);
                }
              }).catch(function(e){ msg.textContent='저장하지 못했다 — '+String(e&&e.message); });
          };

          // 저장 안 한 변경이 있으면 한 번에 안 닫는다. confirm() 을 쓰지 않는 이유는 이 화면이
          // WKWebView 라서 패널 델리게이트가 없으면 조용히 false 가 돌아오기 때문이다 —
          // 물어본 적도 없는데 안 닫히는 것으로 보인다. 일괄 보관과 같은 두 번 누르기로 한다.
          window.isMdClose=function(){
            var ed=document.getElementById('isMdEdit');
            var btn=document.getElementById('isMdCloseBtn');
            if(MDP&&ed.value!==MDTEXT&&!MDCLOSEARM){
              MDCLOSEARM=1; btn.textContent='그냥 닫기';
              document.getElementById('isMdMsg').textContent='저장하지 않은 변경이 있다. 한 번 더 누르면 버린다.';
              return;
            }
            MDP=null; MDTEXT=''; MDCLOSEARM=0;
            btn.textContent='닫기';
            document.getElementById('isMdWrap').style.display='none';
          };

          // ── 세션 기록 팝업 (읽기 전용) ────────────────────────────────────────
          //
          // md 팝업과 껍데기를 같이 쓰지만 **마크다운 렌더를 하지 않는다.** 기록은 md 가 아니고,
          // 여기는 innerHTML 싱크이며 기록 안에는 사람이 붙여 넣은 HTML 이 얼마든지 들어 있다.
          // 그래서 모든 문자열이 esc() 를 통과한다. 렌더하면 그것이 곧 XSS 다.
          var TRP=null;        // 지금 팝업이 물고 있는 기록의 절대경로. null 이면 닫힌 상태.

          window.isTr=function(el){
            var p=(el&&el.getAttribute)?el.getAttribute('data-p'):String(el||'');
            if(!p) return;
            TRP=p;
            var head=document.getElementById('isTrPath');
            var body=document.getElementById('isTrBody');
            var foot=document.getElementById('isTrFoot');
            head.textContent=p;
            body.innerHTML='<p class="mdload">읽는 중…</p>';
            foot.textContent='';
            document.getElementById('isTrWrap').style.display='flex';
            fetch('/api/issues/transcript?path='+encodeURIComponent(p))
              .then(function(r){ return r.json(); })
              .then(function(j){
                if(TRP!==p) return;   // 그 사이에 다른 기록을 열었으면 늦게 온 응답은 버린다
                if(!j||!j.ok){ body.innerHTML='<p class="mdload">'+esc(mdErr(j))+'</p>'; return; }
                var ts=j.turns||[], out=[], say=0, wrote=0;
                // 자른 것이 있으면 맨 위에서 그렇게 말한다. 조용히 자르지 않는 것이 이 화면의
                // 규칙이다 — "없으면 없다고 쓴다".
                if(j.truncated){
                  out.push('<div class="trcut">앞의 '+((j.total||0)-(j.shown||0))
                    + ' 턴은 안 실었다 — 뒤에서부터 '+(j.shown||0)+' 턴만 보인다. '
                    + '이 세션의 턴은 모두 '+(j.total||0)+' 개다.</div>');
                }
                for(var i=0;i<ts.length;i++){
                  var t=ts[i]||{}, isU=(t.role==='user'), fs=t.files||[];
                  if(isU) say++; else wrote+=fs.length;
                  var fh='';
                  if(fs.length){
                    var rows=[];
                    for(var k=0;k<fs.length;k++) rows.push(esc(String(fs[k])));
                    fh='<div class="fs"><b>쓴 파일</b> — '+rows.join('<br>')+'</div>';
                  }
                  out.push('<div class="turn '+(isU?'u':'a')+'">'
                    + '<div class="who">'+(isU?'사람':'모델')+' · '
                    + esc(tdisp(t.at,16))+'</div>'
                    + '<div class="tx">'+esc(t.text||'')+'</div>'+fh+'</div>');
                }
                if(!ts.length) out.push('<p class="mdload">사람 말도 모델 답도 없다 — 하네스 레코드뿐인 기록이다.</p>');
                body.innerHTML=out.join('');
                body.scrollTop=0;
                // 머리에 경로와 센 것을 같이 적는다. 경로만 있으면 이 기록이 얼마나 큰지를
                // 라이언이 스크롤해 봐야 알 수 있다.
                head.innerHTML=esc(p)+'<span class="sub2">사람 말 '+say+' 번 · 쓴 파일 '+wrote
                  + ' 개 · 턴 '+(j.shown||0)+'/'+(j.total||0)
                  + (j.cwd?(' · 작업 폴더 '+esc(String(j.cwd))):'')+'</span>';
                foot.textContent='읽기 전용이다. 이 기록은 하네스가 쓰는 파일이라 여기서 고치지 않는다.';
              })
              .catch(function(e){
                if(TRP!==p) return;
                body.innerHTML='<p class="mdload">읽지 못했다 — '+esc(String(e&&e.message))+'</p>';
              });
          };

          window.isTrClose=function(){
            TRP=null;
            document.getElementById('isTrWrap').style.display='none';
            document.getElementById('isTrBody').innerHTML='';
          };

          document.addEventListener('keydown',function(e){
            // 기록 팝업이 열려 있으면 **그것을 먼저 닫는다.** 둘이 동시에 열릴 일은 없지만,
            // 키 하나가 두 팝업을 건드리게 두면 언젠가 md 팝업의 저장 안 한 변경이 기록 팝업을
            // 닫는 Escape 에 같이 날아간다.
            if(TRP){ if(e.key==='Escape') isTrClose(); return; }
            if(!MDP) return;
            if(e.key==='Escape'){ isMdClose(); return; }
            // ⌘S 는 에디터에서 저장. 브라우저 저장 대화상자를 뺏는다.
            if((e.metaKey||e.ctrlKey)&&(e.key==='s'||e.key==='S')){
              e.preventDefault();
              if(document.getElementById('isMdEdit').style.display!=='none') isMdSave();
            }
          });

          // 보관과 보관 해제. 되돌린 자리는 서버가 원장에서 읽어 돌려준 값을 그대로 쓴다 —
          // 라이언이 알고 싶은 것은 "내가 치웠을 때 무엇이었나" 이고 지금 값이 아니다.
          //
          // ASSUMPTION (L1, 갈래를 스스로 골랐다): `보관 해제 — 완료 로 돌아갔다` 를 상세의
          // 부제가 아니라 **페이지 머리의 부제(#isSub)** 에 띄운다. 해제와 동시에 상세를 닫으므로
          // 상세 안에 쓰면 쓰는 순간 그 자리가 사라져 라이언이 못 본다. 3 초 뒤 원래 문구로 돌아간다.
          function isSay(msg){
            var s=document.getElementById('isSub');
            if(!s) return;
            var was=s.textContent;
            s.textContent=msg;
            setTimeout(function(){ if(s.textContent===msg) s.textContent=was; }, 3000);
          }

          function isArchiveCall(url, k, btn, done){
            fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({path:k})}).then(function(r){ return r.json(); }).then(function(j){
                if(!(j&&j.ok)){
                  if(btn) btn.textContent=(j&&j.error==='not-archived')?'이미 풀렸다':'안 됐다';
                  return;
                }
                done(j);
                isLoad();
              }).catch(function(){ if(btn) btn.textContent='안 됐다'; });
          }

          window.isArchive=function(btn,k){
            if(VIEW==='archive'){
              isArchiveCall('/api/issues/unarchive', k, btn, function(j){
                var b=(j.restored&&j.restored.bucket)||'';
                isClose();
                isSay('보관 해제 — '+(b||'원래 상태')+' 로 돌아갔다');
              });
            } else {
              isArchiveCall('/api/issues/archive', k, btn, function(j){
                isClose();
                isSay('아카이브 — '+(j.prevBucket||'')+' 인 채로 치웠다');
              });
            }
          };

          // 목록 행의 [보관 해제]. 행 자체가 상세를 여는 클릭을 물고 있어서 막아야 한다.
          window.isUnarchive=function(ev,btn,k){
            ev.stopPropagation();
            isArchiveCall('/api/issues/unarchive', k, btn, function(j){
              var b=(j.restored&&j.restored.bucket)||'';
              isSay('보관 해제 — '+(b||'원래 상태')+' 로 돌아갔다');
            });
          };

          // 목록 행의 [보관]. 행 자체가 상세를 여는 클릭을 물고 있어서 막아야 한다.
          // 버킷을 안 따지므로 미분류 행에도 그대로 붙는다 — 2026-09-06 라이언의
          // "미분류에서도 보관하기 기능을 넣어줘" 가 이 한 줄로 지켜진다.
          window.isRowArchive=function(ev,btn,k){
            ev.stopPropagation();
            isArchiveCall('/api/issues/archive', k, btn, function(j){
              if(SEL===k) isClose();
              isSay('아카이브 — '+(j.prevBucket||'')+' 인 채로 치웠다');
            });
          };

          // ── 일괄 보관 ────────────────────────────────────────────────────────
          //
          // 2026-09-06 라이언: "일괄 워크하이브 버튼도 있으면 좋을 것 같아요 / 일괄 한 번에 다
          // 어카이브 하는 거야."
          //
          // ASSUMPTION (L1, 갈래를 스스로 골랐다): "다" 는 **지금 보이는 것**이다. 큐 전체가
          // 아니다. 필터를 전체로 두고 누르면 결과가 같고, 좁혀 두고 누르면 좁힌 것만 치운다.
          // 화면이 보여 주지 않은 것을 치우는 버튼은 라이언이 누르기 전에 무엇이 사라질지
          // 알 수 없고, 되돌리기가 있어도 그것은 나쁜 버튼이다.
          window.isBulk=function(){
            if(!SHOWN.length) return;
            if(!BULKARM){
              // 첫 누름은 되묻기만 한다. 5 초 안에 다시 안 누르면 저절로 풀린다.
              BULKARM=Date.now(); render();
              setTimeout(function(){ if(BULKARM && Date.now()-BULKARM>=4900){ BULKARM=0; render(); } }, 5000);
              return;
            }
            BULKARM=0;
            var keys=SHOWN.slice(), n=keys.length;
            var bk=document.getElementById('isBulkBtn');
            if(bk){ bk.disabled=true; bk.textContent='보관하는 중…'; }
            fetch('/api/issues/archive-bulk',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({paths:keys})}).then(function(r){ return r.json(); }).then(function(j){
                if(!(j&&j.ok)){ isSay('일괄 보관이 안 됐다'); render(); return; }
                isClose();
                // 건너뛴 것과 못 찾은 것을 감추지 않는다. 숫자가 안 맞는데 조용하면 라이언이
                // 무엇이 남았는지 확인하러 창을 연다.
                isSay('일괄 보관 — '+j.archived+' 개를 치웠다'
                      + (j.skipped?(' · 이미 보관돼 있던 '+j.skipped+' 개는 그대로 뒀다'):'')
                      + (j.unknown?(' · '+j.unknown+' 개는 카드를 못 찾았다'):''));
                isLoad();
              }).catch(function(){ isSay('일괄 보관이 안 됐다'); render(); });
          };

          // ── AI 검색 ─────────────────────────────────────────────────────────
          //
          // POST 로 일감을 만들고 GET 으로 물어본다. 서버가 모델을 기다리는 동안 대시보드가
          // 통째로 멈추지 않게 하기 위한 것이고, 그 이유는 Core/IssueSearch.swift 머리에 있다.
          window.isSearch=function(){
            var box=document.getElementById('isQ');
            var q=(box&&box.value||'').trim();
            if(!q){ isClearSearch(); return; }
            if(QRUN) return;
            QRUN=true;
            var btn=document.getElementById('isSearchBtn');
            if(btn){ btn.disabled=true; btn.textContent='찾는 중…'; }
            Q={q:q, mode:'', model:'', note:'', error:'', scanned:0, order:[], why:{}, running:true};
            drawSearchBar();
            fetch('/api/issues/search',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({q:q})}).then(function(r){ return r.json(); }).then(function(j){
                if(!(j&&j.ok&&j.id)) throw new Error((j&&j.error)||'시작하지 못했다');
                poll(j.id, 0);
              }).catch(function(e){ searchFailed(String(e&&e.message||e)); });
          };

          function poll(id, n){
            // 1 초마다, 최대 60 번. 모델 호출은 대개 5~15 초이고 45 초에서 서버가 끊는다.
            if(n>60){ searchFailed('시간이 너무 걸린다'); return; }
            fetch('/api/issues/search?id='+encodeURIComponent(id)).then(function(r){ return r.json(); })
              .then(function(j){
                if(j&&j.state==='running'){ setTimeout(function(){ poll(id, n+1); }, 1000); return; }
                if(!(j&&j.state==='done')){ searchFailed((j&&j.error)||'알 수 없음'); return; }
                var order=[], why={};
                for(var i=0;i<(j.hits||[]).length;i++){ order.push(j.hits[i].key); why[j.hits[i].key]=j.hits[i].why; }
                Q={q:j.q, mode:j.mode, model:j.model, note:j.note, error:j.error,
                   scanned:j.scanned, order:order, why:why, running:false};
                searchDone();
              }).catch(function(e){ searchFailed(String(e&&e.message||e)); });
          }

          function searchDone(){
            QRUN=false;
            var btn=document.getElementById('isSearchBtn');
            if(btn){ btn.disabled=false; btn.textContent='찾기'; }
            SEL=null; DET=null; drawDet(); render();
          }

          function searchFailed(msg){
            QRUN=false;
            var btn=document.getElementById('isSearchBtn');
            if(btn){ btn.disabled=false; btn.textContent='찾기'; }
            if(Q){ Q.running=false; Q.failed=msg; }
            render();
          }

          window.isClearSearch=function(){
            Q=null; QRUN=false;
            var box=document.getElementById('isQ'); if(box) box.value='';
            var btn=document.getElementById('isSearchBtn');
            if(btn){ btn.disabled=false; btn.textContent='찾기'; }
            render();
          };

          // 어떻게 찾았는지를 결과 위에 그대로 쓴다. AI 로 찾은 것과 글자 맞추기로 찾은 것은
          // 믿을 만한 정도가 다르고, 그 차이를 감추면 라이언이 "없다" 를 사실로 믿게 된다.
          function drawSearchBar(){
            var el=document.getElementById('isSBar');
            if(!el) return;
            if(!Q){ el.innerHTML=''; return; }
            if(Q.running){
              el.innerHTML='<div class="sbar">「'+esc(Q.q)+'」 — AI 가 카드를 읽는 중…</div>';
              return;
            }
            if(Q.failed){
              el.innerHTML='<div class="sbar local"><button class="x" onclick="isClearSearch()">검색 지우기</button>'
                + '「'+esc(Q.q)+'」 — <b>검색이 실패했다</b>: '+esc(Q.failed)+'</div>';
              return;
            }
            el.innerHTML='<div class="sbar'+(Q.mode==='local'?' local':'')+'">'
              + '<button class="x" onclick="isClearSearch()">검색 지우기</button>'
              + '「'+esc(Q.q)+'」 — <b>'+Q.order.length+' 건</b>'
              + (Q.mode==='ai' ? ' · AI 검색 ('+esc(Q.model)+')' : ' · 글자 맞추기')
              + (Q.note?' · '+esc(Q.note):'')
              + '</div>';
          }

          window.isToggleView=function(){
            VIEW = (VIEW==='archive') ? 'live' : 'archive';
            SEL=null; DET=null; drawDet(); isLoad();
          };

          window.isOrigSet=function(v){ ORIGOPEN=v; drawDet(); };
          // 원문(isOrigSet)과 똑같은 모양의 3 단 setter 다. 이름만 다르고 하는 일은 같다.
          window.isCleanSet=function(v){ CLEANOPEN=v; drawDet(); };
          window.isSesSet=function(v){ SESOPEN=v; drawDet(); };
          window.isRepSet=function(v){ REPOPEN=v; drawDet(); };
          window.isClose=function(){ SEL=null; DET=null; drawDet(); render(); };

          // DASH-14 — `수정된 최초의 리퀘스트` 를 만든 실행 한 줄.
          //
          // 이 함수는 **DET.revision 이 아예 없어도 안 깨져야 한다.** 백엔드가 이 필드를
          // 지금 만들고 있어서 화면이 먼저 배포되는 순간이 실제로 있고, 이미 쌓인 옛 응답에는
          // 영원히 없다. 그래서 rv 는 `DET.revision||{}` 로 받고, `found` 가 참일 때만 값
          // 줄을, 거짓이고 `why` 가 있을 때만 이유 줄을, 둘 다 아니면 빈 문자열을 돌려준다.
          // 라벨만 남은 껍데기를 그리면 화면이 고장 난 것처럼 보인다.
          //
          // ASSUMPTION (L1, 갈래를 스스로 골랐다). 셋을 되묻지 않고 이렇게 정했다.
          //  (1) 조각마다 값이 있을 때만 넣는다. `effort` 가 빈 값이면 조각을 통째로 뺀다 —
          //      Claude 실행에는 이 필드가 물리적으로 없으므로 `effort ` 만 남는 것은
          //      "값이 없다" 가 아니라 "화면이 깨졌다" 로 읽힌다. 같은 이유로 tokens 와
          //      seconds 도 숫자일 때만 넣는다 (문자열로 오면 toLocaleString 이 딴 값을 낸다).
          //  (2) 기록으로 가는 길은 새로 만들지 않고 sesHead 가 쓰는 isTr 팝업을 그대로
          //      쓴다. 경로는 JS 리터럴이 아니라 data-p 속성으로 넘긴다 — 따옴표가 든 경로
          //      하나에 onclick 이 통째로 깨지는 것을 이 파일이 이미 한 번 겪었다.
          //  (3) `tokensFrom` 은 지시대로 줄의 title 에 넣는데, 줄 전체가 링크가 되면 a 의
          //      title 이 위에 덮인다. 그래서 a 의 title 에도 같은 문장을 넣는다 — 마우스를
          //      어디에 올리든 출처가 보이는 쪽이 맞다.
          function revRow(rv){
            if(!rv || typeof rv!=='object') return '';
            if(rv.found){
              var bits=[];
              if(rv.model) bits.push(esc(String(rv.model)));
              if(rv.effort) bits.push('effort '+esc(String(rv.effort)));
              if(typeof rv.tokens==='number' && isFinite(rv.tokens)) bits.push(rv.tokens.toLocaleString()+' 토큰');
              if(typeof rv.seconds==='number' && isFinite(rv.seconds)) bits.push(rv.seconds.toFixed(1)+' 초');
              if(!bits.length) return '';
              var txt=bits.join(' · ');
              var tf=String(rv.tokensFrom||'');
              var f=String(rv.file||'');
              // f 가 비면 링크도 안 그린다. 눌러도 아무 일이 안 나는 링크가 링크가 없는 것보다
              // 나쁘다 — 이 파일이 sesHead 에서 이미 지키는 규칙이다.
              var body = f
                ? '<a data-p="'+esc(f)+'" onclick="isTr(this)" title="'
                  + esc(tf ? tf+' · 눌러서 이 실행의 기록을 읽는다 (읽기 전용)'
                            : '눌러서 이 실행의 기록을 읽는다 (읽기 전용)')+'">'+txt+'</a>'
                : txt;
              return '<div class="revrow" title="'+esc(tf)+'">'+body+'</div>';
            }
            // 못 찾았으면 빈칸이 아니라 왜 못 찾았는지를 쓴다. why 를 자르지 않는다.
            if(rv.why) return '<div class="revrow miss">이 수정을 만든 실행을 못 찾았다 — '+esc(String(rv.why))+'</div>';
            return '';
          }

          function drawDet(){
            var el=document.getElementById('isDet'), main=document.getElementById('isMain');
            if(!SEL){ el.style.display='none'; main.classList.remove('split'); return; }
            el.style.display=''; main.classList.add('split');
            if(!DET){ el.innerHTML='<div class="sec">상세를 읽는 중…</div>'; return; }
            if(!DET.ok){
              el.innerHTML='<div class="sec"><div class="t">상세를 읽지 못했다</div>'
                + '<div class="none">/api/issues/'+esc(SEL)+' 가 <b>'+esc(DET.error||'알 수 없음')
                + '</b> 를 돌려줬다. 카드가 방금 다른 레인으로 옮겨졌을 수 있다 — 새로고침해 봐라.</div></div>';
              return;
            }
            var c=DET.card||{}, vs=DET.versions||[], last=vs.length?vs[vs.length-1]:null;
            var scls=DET.stage==='결과물까지'?'stage3':(DET.stage==='작업지시서까지'?'stage2':'stage1');

            // 1. 헤더. `마지막` 배지가 여기에도 있어야 한다 — 라이언의 말이 "글을 보고 이게
            //    마지막 버젼 이구나 하면서 보겠지" 이므로 스크롤을 내려야 알면 요구를 못 지킨다.
            var h='<div class="dh"><button class="x" onclick="isClose()" title="닫기">✕</button>'
              + '<h2>'+esc(c.title||c.id)+'</h2><div class="meta">'
              + '<span class="bdg '+(BCLS[c.bucket]||'unk')+'" style="padding:2px 10px">'+esc(c.bucket)+'</span>'
              + '<span class="pill ver">'+esc(verLabel(last))+'</span>'
              + (last&&last.isLast?'<span class="pill last">마지막</span>':'')
              + '<span class="pill '+scls+'">'+esc(DET.stage||'')+'</span>'
              // 단계 배지는 **카드에 적힌 것**으로만 정해진다(목록 92 개를 그 값으로 세므로
              // 세션까지 훑을 수 없다). 세션에서 지시서나 산출물을 찾았는데 배지가 `요청만` 인
              // 상태는 화면의 버그가 아니라 진짜 상태다 — 일은 됐고 카드에 아직 안 적혔다.
              // 그 어긋남을 숨기지 않고 이 배지로 말한다. 큐 PM 이 적어야 할 자리다.
              + ((DET.session&&DET.session.found)
                 ? '<span class="pill stage2" title="이 카드를 받은 세션 기록에서 지시서·산출물을 찾았다. 단계 배지는 카드 기준이라 안 올라간다 — 큐 PM 이 카드에 적어야 올라간다.">세션에서 옴</span>'
                 : '')
              + '<span class="pill">'+esc(c.track||'없음')+'</span>'
              + '<span class="pill">'+esc(c.target||'대상 없음')+'</span>'
              + '<span class="pill" title="카드에 적힌 원래 status 값">status: '+esc(c.status||'(없음)')+'</span>'
              + '<span class="pill">'+esc(c.folder)+'/</span>'
              + (c.laneDuplicate?'<span class="pill last" title="같은 파일 이름이 inbox/ 와 done/ 에 둘 다 있다. 큐 PM 이 정리할 자리다.">두 레인에 있다</span>':'')
              // 보관 당시의 버킷. 지금 값과 갈렸으면 갈린 채로 둘 다 보인다.
              + (c.prevBucket
                 ? '<span class="pill'+(c.prevBucket===c.bucket?'':' last')+'">보관 당시 '
                   + esc(c.prevBucket)+'</span>' : '')
              // 라이언이 결과물을 하나씩 확인하고 치우는 자리. 되돌리기가 같은 자리에 있어야
              // 잘못 치운 것을 그 자리에서 되돌린다.
              + '<button class="open" onclick="isArchive(this,\''+esc(SEL)+'\')">'
              + (VIEW==='archive'?'보관 해제':'아카이브')+'</button>'
              + '</div></div>';

            // 2. 리퀘스트(원문). 읽기 전용이고 한 글자도 안 고친 그대로다.
            //
            //    기본은 **닫힘**이고, 닫힘은 본문을 안 그리는 것이다. 앞선 판은 닫혀 있어도
            //    230px 짜리 스크롤 상자를 그렸는데 그것은 닫힌 것이 아니라 작아진 것이다 —
            //    라이언이 먼저 봐야 하는 것은 아래의 정리된 요청이고 원문은 필요할 때 연다.
            //
            //    펼치기는 두 단이다. 1 단이 5 줄이고 2 단이 전문이다. 앞선 판은 펼치면 곧바로
            //    전문이었는데, 라이언이 원한 것은 "펼치기 하면 5줄 정도" 이고 이유를 이렇게
            //    댔다 — "그래야지만 어떤 내용인지 한눈에 파악하기 좋으니까 / 속독을 해도
            //    5절 이상을 보기 어려우니까". 한 눈에 파악하는 것이 목적이므로 1 단은 훑는
            //    자리이고, 그래도 전부 읽고 싶을 때를 위해 2 단을 남긴다.
            //
            //    **자르는 것은 보이는 높이뿐이고 데이터가 아니다.** og 는 어느 단계에서도
            //    통째로 esc() 되어 DOM 에 들어가고, 5 줄 상태는 CSS(-webkit-line-clamp)가
            //    가리는 것뿐이다. slice() 로 문자열을 자르지 않는 이유가 이것이다 — 원문
            //    훼손으로 폐기된 카드가 있어서, 이 박스는 화면에서도 원문을 안 깎는다.
            //
            //    [전문 보기] 는 실제로 5 줄을 넘칠 때만 그린다. 세 줄짜리 원문 밑에 붙은
            //    죽은 [전문 보기] 는 누를 것만 늘리고 아는 것은 안 는다 — 바로 아래 절의
            //    [더보기] 가 이미 같은 이유로 같은 방식(그려진 요소에서 재기)을 쓴다.
            var og=DET.origin||'';
            h+='<div class="sec"><div class="t">리퀘스트 (원문)<span class="why">읽기 전용 · 카드의 ## 원문 그대로</span></div>'
              + (og ? (ORIGOPEN===0
                        ? '<button class="lnk" onclick="isOrigSet(1)">펼치기 (원문 '
                          + og.length.toLocaleString()+'자)</button>'
                        : '<div class="orig '+(ORIGOPEN===1?'o5':'full')+'" id="isOrig">'+esc(og)+'</div>'
                          + (ORIGOPEN===1
                             ? '<button class="lnk" id="isOrigMore" style="display:none" onclick="isOrigSet(2)">'
                               + '전문 보기 ('+og.length.toLocaleString()+'자)</button>'
                             : '<button class="lnk" onclick="isOrigSet(1)">5 줄만 보기</button>')
                          + '<button class="lnk" style="margin-left:10px" onclick="isOrigSet(0)">접기</button>')
                    : '<div class="none">이 카드에는 <b>## 원문</b> 절이 없다.</div>')
              + '</div>';

            // 3. 수정된 최초의 리퀘스트. 원문을 고친 값이 아니라 원문 옆에 서는 값이다 —
            //    원문 훼손으로 카드가 폐기된 전례가 있다.
            //
            //    DASH-14 부터 **기본이 접힘**이고 위 원문 절과 똑같은 3 단이다 —
            //    0 접힘 · 1 다섯 줄 · 2 전문. 라이언이 이 절을 콕 집어 "그 수정한 내용이
            //    기본적으로 접혀있고 그걸 전문으로 볼 수 있게 해줘요" 라고 했다.
            //
            //    0 단의 [펼치기] 는 **길이와 무관하게 언제나 그린다.** 라이언이 요구한 것이
            //    접힘이고, 접힌 것을 여는 손잡이가 없으면 이 절이 화면에서 통째로 사라진다.
            //    반대로 2 단의 [전문 보기] 는 그린 뒤에 재서 실제로 5 줄을 넘칠 때만 그린다 —
            //    죽은 손잡이는 누를 것만 늘리고 아는 것은 안 는다. 재는 코드는 이 함수 끝에
            //    있고 #isOrigMore 와 같은 방식이다. 새로 만들지 않았다.
            //
            //    자르는 것은 보이는 높이뿐이고 데이터가 아니다 — cl.text 는 어느 단계에서도
            //    통째로 esc() 되어 DOM 에 들어가고 5 줄 상태는 CSS 가 가리는 것뿐이다.
            //
            //    `.rawtag` 경고 줄과 실행 정보 줄은 **접힘 단계 바깥**에 있다. 앞엣것은 읽을
            //    거리가 아니라 이 카드가 정리 안 됐다는 상태 표시이고, 뒤엣것은 펼치지 않고도
            //    보이는 것이 존재 이유다.
            var cl=DET.cleaned||{};
            var cltxt=String(cl.text||''), cllen=cltxt.length.toLocaleString();
            // 옛 응답과 백엔드가 아직 안 붙은 순간에는 이 키가 없다. 그때 rv 는 {} 이고
            // revRow() 가 빈 문자열을 돌려주므로 이 절은 평소대로 그려진다.
            var rv=DET.revision||{};
            h+='<div class="sec"><div class="t">수정된 최초의 리퀘스트'
              + '<span class="why">'+esc(cl.source||'')+'</span></div>'
              + revRow(rv)
              + (cl.isRawExcerpt
                 ? '<div class="rawtag">이 카드는 아직 정리되지 않았다. 아래는 원문 앞부분 그대로다.</div>'
                 : '')
              + (CLEANOPEN===0
                   ? '<button class="lnk" onclick="isCleanSet(1)">펼치기 (요구 '+cllen+'자)</button>'
                   : '<div class="lead'+(cl.isRawExcerpt?' raw':'')+(CLEANOPEN===1?' clamp':'')
                     + '" id="isLead">'+esc(cltxt)+'</div>'
                     + (CLEANOPEN===1
                        ? '<button class="lnk" id="isLeadMore" style="display:none" onclick="isCleanSet(2)">'
                          + '전문 보기 ('+cllen+'자)</button>'
                        : '<button class="lnk" onclick="isCleanSet(1)">5 줄만 보기</button>')
                     + '<button class="lnk" style="margin-left:10px" onclick="isCleanSet(0)">접기</button>')
              + '</div>';

            // 4. 작업지시서. 리스트로 들어온 카드가 있어 배열로 받는다.
            //
            //    2026-09-06 에 한 겹 늘었다. 카드에 `issue:` 가 안 적혀 있어도 그 일을 받은
            //    세션이 실제로 지시서를 쓴 경우가 있다 — 실측으로 이 카드가 그렇다. 그때
            //    `작업지시서 없음` 만 쓰면 라이언이 확인하러 다른 창을 열고, 그 창을 없애는
            //    것이 이 화면의 유일한 목적이다. 그래서 세션에서 온 것을 아래에 이어 붙인다.
            //    카드에 적힌 것과 세션에서 온 것은 왼쪽 파란 줄로 눈에서 갈린다 — 출처가 다르고,
            //    세션에서 온 것은 아직 카드에 안 적힌 것이라 큐 PM 이 적어야 할 자리다.
            var ds=DET.directives||[], S=DET.session||{};
            h+='<div class="sec"><div class="t">작업지시서<span class="why">카드의 issue: 필드 · 없으면 그 일을 한 세션</span>'
              + orcaBtn()+'</div>';
            if(ds.length){ h+=ds.map(artRow).join(''); }
            if(S.found){
              // 세션에서 온 것은 통째로 `.ses` 안에 넣는다. 파일 줄만 밖으로 내면 카드에 적힌
              // 것과 같은 모양이 되어 출처가 섞인다 — 이 줄들은 아직 카드에 없는 것이다.
              h+='<div class="ses"><div class="sh shrow">'+sesHead(S)+'</div>'
                + (S.directiveFiles||[]).map(artRow).join('')
                + '<div class="sh" style="margin-top:9px"><b>첫 지시문</b> — 최초 원문 · 문제 정의 · 어떻게 일할 건지가 이 안에 있다</div>'
                + longBox(S.directive||'', SESOPEN, 'isSesSet')+'</div>';
            } else if(!ds.length){
              h+='<div class="none">작업지시서 없음 — 이 카드에는 <b>issue:</b> 가 적혀 있지 않다.<br>'
                + '세션도 못 붙였다 — '+esc(S.why||'세션을 찾지 않았다')+'</div>';
            }
            h+='</div>';

            // 5. 결과물. 없는 것이 다수(85 중 59)이므로 없음을 일급 상태로 그린다.
            //    여기도 같은 겹이 붙는다 — 카드에 `output:` 이 없어도 세션이 쓴 파일이 있으면
            //    그것을 보인다. 파일이 하나도 없으면 마지막 보고가 그 세션이 낸 전부다.
            var as=DET.artifacts||[];
            h+='<div class="sec"><div class="t">결과물<span class="why">output · outputs · artifact · artifacts · output_path · supporting_artifacts</span>'
              + orcaBtn()+'</div>';
            if(as.length){ h+=as.map(artRow).join(''); }
            if(S.found){
              var of=S.outputFiles||[];
              h+='<div class="ses"><div class="sh shrow">'+sesHead(S)+'</div>';
              if(of.length){ h+=of.map(artRow).join(''); }
              else {
                h+='<div class="none">이 세션은 파일을 하나도 안 썼다. 아래 마지막 보고가 낸 전부다.</div>';
              }
              if(S.report){
                h+='<div class="sh" style="margin-top:9px"><b>마지막 보고</b> — '
                  + esc(tdisp(S.lastAt,16))+'</div>'
                  + longBox(S.report, REPOPEN, 'isRepSet');
              }
              h+='</div>';
            } else if(!as.length){
              h+= ds.length
                ? '<div class="none"><b>결과물 없음 — 작업지시서까지 나왔다.</b> 지시서는 있고 산출물 포인터가 카드에 아직 안 적혔다.</div>'
                : '<div class="none"><b>결과물 없음 — 요청만 있다.</b> 작업지시서도 산출물도 카드에 아직 안 적혔다.<br>'
                  + '세션도 못 붙였다 — '+esc(S.why||'세션을 찾지 않았다')+'</div>';
            }
            h+='</div>';

            // 6. 버전.
            h+='<div class="sec"><div class="t">버전'
              + '<span class="why">앱이 카드 내용 해시로 센 관측 기록이다 · 카드에도 git 에도 버전 원천이 없다</span></div>';
            if(vs.length){
              h+=vs.map(function(v){
                return '<div class="vrow"><span class="vn">v'+v.v+'</span>'
                  + '<span>'+esc(tdisp(v.firstSeen,16))+'</span>'
                  + '<span class="vt">'+(v.isFirstObservation?'첫 관측':'내용이 바뀌었다')+'</span>'
                  + (v.isLast?'<span class="pill last">마지막</span>':'')+'</div>';
              }).join('');
            } else {
              h+='<div class="none">아직 관측 기록이 없다.</div>';
            }
            h+='</div>';

            // 7. 계보. 실측 4 개 카드에만 있다. 추측이 아니라 진짜 데이터라 있으면 그린다.
            var lg=DET.lineage||[];
            if(lg.length){
              h+='<div class="sec"><div class="t">계보<span class="why">카드에 적힌 링크</span></div>'
                + lg.map(function(l){
                    return '<div class="vrow"><span class="vt">'+esc(l.label)+'</span><span>'+esc(l.value)+'</span></div>';
                  }).join('') + '</div>';
            }

            // 8. 카드 파일 자신.
            //
            //    2026-09-06 에 여기에도 [Orca 로 열기] 가 붙었다. [파일 열기] 는 카드를 보여
            //    주기만 해서, 읽고 나서 그 일을 시작하려면 라이언이 창을 따로 열고 경로를 다시
            //    쳐야 했다. 이 버튼은 그 카드 파일을 이미 물고 있는 Claude 세션을 띄운다 —
            //    서버가 카드 키로 경로를 찾아 첫 질의로 넣는다 (IssueOrcaLauncher.launch).
            if(c.path){
              h+='<div class="sec"><div class="t">카드 파일'
                + '<span class="why">이 카드를 읽고 그대로 실행할 세션을 연다</span>'
                + orcaBtn()+'</div>'
                + artRow({key:'card', raw:c.path, kind:'절대경로', path:c.path, exists:true,
                          isDir:false, openable:true})+'</div>';
            }
            el.innerHTML=h;

            // [전문 보기] 는 실제로 5 줄을 넘길 때만 그린다. 넘치는지는 글자 수로 짐작하지 않고
            // **그려진 요소에서 잰다** — 줄 수는 폭과 줄바꿈에 달려 있어서 글자 수로는 못 맞춘다.
            // DASH-14 에서 `CLEANOPEN||` 이 빠졌다. 이제 #isLeadMore 는 1 단(5 줄 클램프)
            // 에서만 DOM 에 있으므로, 펼쳤다는 이유로 무조건 보이던 옛 갈래는 죽은 손잡이를
            // 되살릴 뿐이다. 아래 #isOrigMore 와 판정이 같아졌다.
            var lead=document.getElementById('isLead'), more=document.getElementById('isLeadMore');
            if(lead&&more&&lead.scrollHeight>lead.clientHeight+2) more.style.display='';

            // 원문 5 줄 상태도 같은 방식으로 잰다. 글자 수로 짐작하면 폭과 줄바꿈 때문에
            // 틀린다 — 3,000 자여도 한 줄일 수 있고 40 자여도 다섯 줄을 넘길 수 있다.
            var org=document.getElementById('isOrig'), omore=document.getElementById('isOrigMore');
            if(org&&omore&&org.scrollHeight>org.clientHeight+2) omore.style.display='';
          }

          window.isOpen=function(k){
            if(SEL===k){ isClose(); return; }
            SEL=k; DET=null; ORIGOPEN=0; CLEANOPEN=0; SESOPEN=0; REPOPEN=0; render(); drawDet();
            fetch('/api/issues/'+k.split('/').map(encodeURIComponent).join('/'))
              .then(function(r){ return r.json(); })
              .then(function(j){ if(SEL===k){ DET=j; drawDet(); } })
              .catch(function(e){ if(SEL===k){ DET={ok:false,error:String(e&&e.message)}; drawDet(); } });
          };

          window.isLoad=function(){
            fetch('/api/issues'+(VIEW==='archive'?'?view=archive':'')).then(function(r){ return r.json(); }).then(function(j){
              D=j; render(); drawDet();
            }).catch(function(e){
              document.getElementById('isList').innerHTML=
                '<div class="empty">큐 피드(/api/issues)를 읽지 못했다: '+esc(e&&e.message)+'</div>';
            });
          };
          // 엔터로 찾는다. 검색창에서 버튼까지 손을 옮기게 하면 이 기능을 쓸 이유가 줄어든다.
          // 빈 칸에서 엔터를 치면 검색을 지운다 — 지우는 버튼을 찾으러 가지 않게 한다.
          (function(){
            var box=document.getElementById('isQ');
            if(!box) return;
            box.addEventListener('keydown', function(e){
              if(e.key==='Enter'){ e.preventDefault(); isSearch(); }
              if(e.key==='Escape'){ isClearSearch(); }
            });
          })();

          isLoad();
        })();
        </script>
        </body></html>
        """#
    }
}
