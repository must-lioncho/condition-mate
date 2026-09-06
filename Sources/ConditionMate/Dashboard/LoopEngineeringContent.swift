import Foundation

// GET /loop-engineering — 루프 엔지니어링 페이지.
//
// 에이전트 페이지(/agents)와 무엇이 다른가: 그쪽은 "어떤 파트가 어디에 있는가"를 답한다. 파트가
// 다 있어도 그것들로 짜인 경로가 실제로 돌았는지는 알 수 없다. 이 페이지는 그 경로 — 목표에서
// 결과까지의 이름 붙은 반복 가능한 라우트 — 를 세션 기록에서 되살려, 프로젝트마다 무엇이 돌았고
// 어디서 막히는지를 보여 준다.
//
// 화면이 우선순위대로 답하는 질문은 셋이다:
//   1. 이 프로젝트에 어떤 라우트가 있는가   → 정의된 파트 + 실제로 위임이 오간 대상
//   2. 그 라우트가 돌고 끝났는가            → 실행 / 완료 / 끊김 / 결과 없음
//   3. 병목은 어디이고 얼마짜리인가         → 끊긴 홉 → 진입점 → 종료 조건 → 파트 순서로 하나 지목
//
// 그리지 않는 것: 확인하지 못한 라우트. 없는 그래프의 그림은 없는 것보다 나쁘다 — 믿기기 때문이다.
// 그래서 이 화면의 모든 선과 막대는 디스크에 남은 기록에서만 나오고, 라우트가 없으면 없다고 적는다.
// 측정할 수 없는 축(핸드오프 비용)은 빈칸으로 두지 않고 "왜 못 재는지"를 적는다.
enum LoopEngineeringContent {

    static func html() -> String {
        return #"""
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>루프 엔지니어링</title>
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
          .acts{display:flex;gap:8px;align-items:center;flex-wrap:wrap}

          /* 요약 — 이 맥의 루프 규모와 손볼 것의 크기. */
          .sum{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:14px}
          .card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:10px 14px;min-width:104px}
          .card .n{font-size:20px;font-weight:700;line-height:1.2}
          .card .k{color:var(--mut);font-size:11px;letter-spacing:.03em}
          .card.warn .n{color:#f85149}

          /* 못 재는 축을 빈칸으로 두지 않는다 — 왜 못 재는지가 그 자체로 발견이다. */
          .note{background:#131822;border:1px solid var(--line);border-left:3px solid #d29922;
            border-radius:10px;padding:11px 14px;margin-bottom:14px;color:#c3cad6;font-size:12.5px}
          .note b{color:#e6e9ef}
          .note .t{color:#d29922;font-size:11px;letter-spacing:.04em;text-transform:uppercase;margin-bottom:5px}

          .tools{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:14px}
          .tools input[type=text]{flex:1;min-width:180px;background:#11151d;border:1px solid var(--line);
            color:var(--fg);border-radius:8px;padding:7px 11px;font-size:13px;outline:none}
          .tools input[type=text]:focus{border-color:#33518f}
          .tg{color:var(--mut);font-size:12px;display:flex;align-items:center;gap:6px;cursor:pointer;white-space:nowrap}

          /* 프로젝트 하나 = 루프 한 벌. */
          .proj{margin-bottom:16px;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
          .phd{display:flex;align-items:center;gap:10px;padding:11px 14px;border-bottom:1px solid var(--line);
            flex-wrap:wrap;cursor:pointer}
          .phd:hover{background:#171c26}
          .phd .nm{font-size:14px;font-weight:600}
          .caret{color:#5d6678;font-size:10px;width:12px;text-align:center;flex:none}
          .badge{font-size:11px;padding:1px 8px;border-radius:20px;border:1px solid var(--line);background:#1a2336;color:#9fb6e8}
          .badge.out{background:#1e1a17;border-color:#4a3a24;color:#d7a86a}
          .phd .path{color:#5d6678;font:11px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;
            margin-left:auto;max-width:44%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}

          /* 병목 한 줄 — 이 화면의 결론. 근거 숫자가 반드시 문장 안에 있다. */
          .verd{display:flex;align-items:flex-start;gap:9px;padding:10px 14px;border-bottom:1px solid #171d28;
            background:#101520;font-size:12.5px;color:#cfd6e2}
          .vcat{flex:none;font-size:11px;font-weight:700;padding:2px 9px;border-radius:20px;white-space:nowrap;
            background:#1a2336;border:1px solid #263149;color:#9fb6e8}
          .vcat.dead{background:#2a1416;border-color:#4a1f22;color:#f85149}
          .vcat.entry{background:#2a2312;border-color:#4a3d1a;color:#d29922}
          .vcat.term{background:#1d1a2e;border-color:#3a2f5a;color:#c3a7ff}
          .vcat.part{background:#12281a;border-color:#1c4128;color:#7ee29a}
          .vcat.none{background:#181c25;border-color:#242c3a;color:#7b8494}

          /* 라우트 한 줄 = 하나의 홉(메인 세션 → 파트). 막대는 그 홉이 붙든 시간의 몫이다. */
          .rt{display:flex;align-items:center;gap:10px;padding:9px 14px;border-top:1px solid #171d28;font-size:12.5px}
          .proj .rt:first-of-type{border-top:0}
          .rt .dot{width:9px;height:9px;border-radius:50%;flex:none;background:#3fb950}
          .rt .dot.dead{background:#f85149} .rt .dot.idle{background:#33405a} .rt .dot.async{background:#c3a7ff}
          .rt .ag{flex:none;font-weight:600;color:#dbe2ee;min-width:150px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
          .rt .sc{flex:none;font-size:10.5px;color:#7b8494;border:1px solid var(--line);border-radius:20px;padding:0 7px}
          .rt .sc.no{color:#f85149;border-color:#4a1f22;background:#2a1416}
          .bar{flex:1;min-width:60px;height:7px;background:#161c26;border-radius:4px;overflow:hidden}
          .bar i{display:block;height:100%;background:linear-gradient(90deg,#33518f,#5b8cff);border-radius:4px}
          .bar i.dead{background:#f85149}
          .rt .nums{flex:none;color:#8a93a3;font-size:11.5px;white-space:nowrap;text-align:right;min-width:168px}
          .rt .nums b{color:#e6e9ef;font-weight:600}
          .rt .nums .bad{color:#f85149;font-weight:600}

          .body{padding:10px 14px 14px 36px;border-top:1px solid #171d28;background:#0f141d}
          .sec{margin:9px 0}
          .sec .lb{color:var(--mut);font-size:11px;letter-spacing:.04em;text-transform:uppercase;margin-bottom:5px}
          .chips{display:flex;flex-wrap:wrap;gap:5px}
          .chip2{font-size:11px;padding:2px 9px;border-radius:20px;background:#1a1f2b;border:1px solid var(--line);color:#9aa4b6}
          .chip2.no{background:#2a2312;border-color:#4a3d1a;color:#d29922}
          .chip2.dead{background:#2a1416;border-color:#4a1f22;color:#f85149}
          .chip2.ok{background:#12281a;border-color:#1c4128;color:#7ee29a}
          .mini{color:#7b8494;font-size:11.5px}
          .empty{color:var(--mut);text-align:center;padding:34px 0}
          .foot{color:#5d6678;font-size:11px;text-align:center;margin-top:16px;line-height:1.7}

          /* 병목 밴드 — 이 화면의 첫 3초. 숫자 하나, 막대 하나, 분자·분모 한 줄, 한계 여러 줄.
             한계를 툴팁에 숨기지 않고 본문에 적는다: 이 지수는 잠자는 시간을 세고 있고, 상한은
             사용자가 정한 정책이며, 루프 아홉 칸을 잰 값이 아니다. 그 셋을 모르고 읽으면
             "너 때문이야"라는 문장으로 읽히고, 그러면 사용자가 이 화면을 안 열게 된다. */
          .band{background:var(--panel);border:1px solid var(--line);border-radius:12px;
            padding:14px 16px;margin-bottom:14px}
          .band .cap{color:var(--mut);font-size:11px;letter-spacing:.04em;text-transform:uppercase}
          .band .big{display:flex;align-items:baseline;gap:12px;margin:6px 0 8px}
          .band .pct{font-size:34px;font-weight:700;line-height:1;color:#f0b849}
          .band .who{font-size:14px;color:#cfd6e2}
          .band .meter{height:12px;background:#161c26;border-radius:6px;overflow:hidden;margin-bottom:9px}
          .band .meter i{display:block;height:100%;border-radius:6px;
            background:linear-gradient(90deg,#8a5a12,#f0b849)}
          .band .frac{font-size:12.5px;color:#cfd6e2;margin-bottom:2px}
          .band .frac b{color:#e6e9ef}
          .band .lim{color:#8a93a3;font-size:11.5px;line-height:1.65;margin-top:7px;
            border-top:1px solid #1b2130;padding-top:8px}
          .band .lim div{margin-top:3px}
          .band .lim div:before{content:"· "}

          /* 지금 열려 있는 대기 — 이 화면의 심장. 행마다 누를 것이 하나 이상 있고, 누른 결과가
             다음 조회에서 그 행이 사라지는 것으로 확인된다. */
          .waits{background:var(--panel);border:1px solid var(--line);border-radius:12px;
            overflow:hidden;margin-bottom:14px}
          .waits .whd{display:flex;align-items:center;gap:9px;padding:11px 14px;
            border-bottom:1px solid var(--line);font-size:13px;font-weight:600}
          .wrow{padding:10px 14px;border-top:1px solid #171d28}
          .waits .wrow:first-of-type{border-top:0}
          .wrow .l1{display:flex;align-items:center;gap:9px;flex-wrap:wrap;font-size:12.5px}
          .wrow .ttl{font-weight:600;color:#dbe2ee;flex:1;min-width:150px;
            overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .wrow .kd{flex:none;font-size:11px;padding:1px 8px;border-radius:20px;
            background:#1a2336;border:1px solid #263149;color:#9fb6e8}
          .wrow .kd.dead{background:#2a1416;border-color:#4a1f22;color:#f85149}
          .wrow .kd.worker{background:#2a2312;border-color:#4a3d1a;color:#d29922}
          .wrow .dw{flex:none;color:#8a93a3;font-size:11.5px;white-space:nowrap}
          .wrow .vd{flex:none;font-size:11px;font-weight:700;padding:1px 8px;border-radius:20px;
            background:#12281a;border:1px solid #1c4128;color:#7ee29a}
          .wrow .vd.stalled{background:#2a1416;border-color:#4a1f22;color:#f85149}
          .wrow .nt{color:#7b8494;font-size:11.5px;margin:4px 0 0 0}
          .wrow .acts2{display:flex;gap:6px;flex-wrap:wrap;margin-top:7px}
          .wrow .acts2 button{background:#1d2230;border:1px solid var(--line);color:#cfd6e2;
            border-radius:7px;padding:4px 10px;font-size:12px;cursor:pointer}
          .wrow .acts2 button:hover{background:#242b3b}
          .wrow .acts2 button.go{border-color:#2c4a7a;color:#9fb6e8}

          /* 추세 — 1단계에서는 꺾은선을 그리지 않는다. 값이 두세 개일 때 선을 그으면 없는
             추세가 있는 것처럼 보인다. 최근 세 값을 글자로만 적는다. */
          .trend{color:#8a93a3;font-size:11.5px;margin-bottom:14px;padding:0 2px}
          .trend b{color:#cfd6e2}

          /* 프로젝트 카드 28장은 지우지 않고 접어서 아래로 내린다. 판정 28개는 0개와 같지만,
             한 프로젝트를 파고들 때는 여전히 그 28개가 필요하다. */
          .fold{background:var(--panel);border:1px solid var(--line);border-radius:12px;
            margin-bottom:14px;overflow:hidden}
          .fold>.fhd{display:flex;align-items:center;gap:9px;padding:11px 14px;cursor:pointer;font-size:13px}
          .fold>.fhd:hover{background:#171c26}
          .fold>.fbd{padding:12px 14px 14px;border-top:1px solid var(--line);background:#0f141d}
          .versions{display:flex;gap:3px;background:#11151d;border:1px solid var(--line);padding:3px;border-radius:9px}
          .vtab{border:0;background:transparent;color:var(--mut);padding:5px 11px;border-radius:6px;cursor:pointer;font-size:12px}
          .vtab.on{background:#263149;color:#dbe7ff}
          .v2hero{background:linear-gradient(135deg,#151b28,#111720);border:1px solid #29344a;border-radius:14px;padding:18px;margin-bottom:14px}
          .v2top{display:flex;align-items:flex-start;gap:12px;flex-wrap:wrap}.v2top h2{font-size:20px;margin:0}.v2top .live{margin-left:auto}
          .live{font-size:11px;border:1px solid #23673b;background:#12281a;color:#7ee29a;border-radius:20px;padding:2px 9px}
          .v2purpose{font-size:14px;color:#d5dbe6;margin:10px 0 14px;max-width:850px}
          .v2grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}.v2box{background:#11151d;border:1px solid var(--line);border-radius:10px;padding:12px}
          .v2box .lb{color:#8290a7;font-size:11px;margin-bottom:5px}.v2box p{margin:0;color:#cbd3df;font-size:12.5px}
          .v2sec{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px;margin-bottom:12px}
          .v2sec h3{font-size:13px;margin:0 0 11px}.trigger{display:flex;align-items:center;gap:10px;padding:9px 0;border-top:1px solid #1c2330}.trigger:first-of-type{border-top:0}
          .trigger .kind{font-size:10px;color:#9fb6e8;border:1px solid #2c4168;border-radius:20px;padding:1px 7px}.trigger .name{font-weight:600}.trigger .detail{color:var(--mut);font-size:11.5px}.trigger .health{margin-left:auto;font-size:11px;color:#7ee29a}.trigger .health.bad{color:#f85149}
          .flow{display:flex;align-items:stretch;gap:7px;overflow-x:auto;padding:3px 0 8px}.step{min-width:150px;background:#111722;border:1px solid #263149;border-radius:9px;padding:9px}.step .from{font-weight:600;font-size:12px}.step .to{color:#8faeff;font-size:11px;margin:3px 0}.step .why{color:var(--mut);font-size:10.5px}.arrow{align-self:center;color:#506080;flex:none}
          .agents{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}.agent{background:#11151d;border:1px solid var(--line);border-radius:9px;padding:10px}.agent b{font-size:12px}.agent .role{color:#8faeff;font-size:10px}.agent p{color:var(--mut);font-size:11px;margin:5px 0 0}
          .layerstack{display:grid;grid-template-columns:repeat(4,minmax(150px,1fr));gap:7px}.layer{position:relative;background:#111722;border:1px solid #263149;border-radius:9px;padding:10px}.layer:not(:last-child):after{content:'→';position:absolute;right:-8px;top:50%;transform:translate(50%,-50%);z-index:2;color:#5b8cff}.layer .kind{color:#8faeff;font-size:10px}.layer b{display:block;font-size:12px;margin:2px 0}.layer p{color:var(--mut);font-size:10.5px;margin:0}.layer code{display:block;color:#68758b;font-size:9.5px;margin-top:6px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .maturity{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}.mstep{background:#11151d;border:1px solid var(--line);border-radius:10px;padding:11px}.mstep .lv{font-size:10px;color:#7d899c}.mstep b{display:block;font-size:12px;margin:3px 0}.mstep p{font-size:10.5px;color:var(--mut);margin:0}.mstep.done,.mstep.current{border-color:#23673b}.mstep.current{background:#12281a}.mstep.partial{border-color:#8a5a12}.mstep.next{border-style:dashed}.mstate{float:right;font-size:9px;color:#7ee29a}.mstep.partial .mstate{color:#f0b849}.mstep.next .mstate{color:#8a93a3}
          .evidence{display:flex;gap:6px;flex-wrap:wrap}.ev{background:#11151d;border:1px solid var(--line);border-radius:8px;padding:6px 9px;font-size:11px}.ev b{color:#cfd6e2}.ev span{color:#68758b;font-family:ui-monospace,monospace;margin-left:5px}
          .looplist{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
          .looplist-hd{display:flex;align-items:center;gap:9px;padding:11px 14px;border-bottom:1px solid var(--line)}
          .looplist-hd b{font-size:13px}.looplist-hd .dir{margin-left:auto;color:#596579;font:10.5px ui-monospace,monospace}
          details.looprow{border-top:1px solid #1b2230}details.looprow:first-of-type{border-top:0}
          details.looprow>summary{list-style:none;display:grid;grid-template-columns:minmax(220px,1.5fr) minmax(160px,1fr) minmax(240px,1.7fr) auto;gap:12px;align-items:center;padding:12px 14px;cursor:pointer}
          details.looprow>summary::-webkit-details-marker{display:none}details.looprow>summary:hover{background:#171c26}
          .loopname{font-weight:600}.loopname:before{content:'▸';display:inline-block;color:#596579;font-size:10px;width:16px}details[open] .loopname:before{content:'▾'}
          .loopwhat{color:#aeb8c8;font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.looppath{color:#69758a;font:10.5px ui-monospace,monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
          .looprecent{grid-column:1/-1;color:#707d91;font-size:10.5px;padding-left:16px;margin-top:-6px}
          .loopdetail{padding:14px 16px 18px;background:#0f141d;border-top:1px solid #202838}.loopdetail .v2hero{margin-bottom:12px}
          .usagecards{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}.ucard{background:#11151d;border:1px solid var(--line);border-radius:9px;padding:10px}.ucard .days{color:#7d899c;font-size:10.5px}.ucard .tok{font-size:18px;font-weight:700;margin-top:2px}.ucard .io{font-size:10px;color:#667389}
          .hourhd{display:flex;align-items:center;gap:7px;margin:13px 0 7px}.period{border:1px solid var(--line);background:#11151d;color:#8793a6;border-radius:6px;padding:3px 7px;font-size:10px;cursor:pointer}.period.on{border-color:#36558e;color:#adc4f5;background:#18243a}
          .hours{height:118px;display:grid;grid-template-columns:repeat(24,1fr);align-items:end;gap:3px;border-bottom:1px solid #273043;padding-top:8px}.hour{min-width:0;text-align:center}.hour i{display:block;background:linear-gradient(#5b8cff,#31518d);border-radius:3px 3px 0 0;min-height:1px}.hour span{display:block;color:#536077;font-size:8px;margin-top:3px}.hour.hot i{background:linear-gradient(#f0b849,#9b6717)}
          .unmeasured{border:1px dashed #394254;border-radius:9px;padding:12px;color:#8b96a8;font-size:11.5px}.unmeasured b{color:#c9d1dd}
          /* 세션 원장 — 어떤 세션이 어느 루프를 돌리려고 열렸는가. 진행률을 맨 위에 두는 이유:
             이 판정은 트랜스크립트 1GB 를 읽어야 나오므로 첫 실행에서는 반드시 "아직 덜 읽었다"는
             상태가 존재한다. 그것을 숨기면 아래 숫자가 완성된 합계처럼 읽힌다. */
          .sled{background:var(--panel);border:1px solid var(--line);border-radius:12px;margin-bottom:14px;overflow:hidden}
          .sled .shd{display:flex;align-items:center;gap:9px;padding:11px 14px;border-bottom:1px solid var(--line);flex-wrap:wrap}
          .sled .shd b{font-size:13px}
          .sled .prog{margin-left:auto;color:#8a93a3;font-size:11.5px}
          .sled .pbar{height:5px;background:#161c26;border-radius:3px;margin:0 14px 10px;overflow:hidden}
          .sled .pbar i{display:block;height:100%;background:linear-gradient(90deg,#33518f,#5b8cff)}
          .sled .stot{display:flex;gap:8px;flex-wrap:wrap;padding:10px 14px 4px}
          .sledtools{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:10px 14px;border-top:1px solid #171d28;margin-top:6px}
          .sledtools .ctl-label{color:#7d899c;font-size:10.5px;margin-right:-2px}.sledtools .spacer{flex:1}
          .sledtools select,.sledtools input{border:1px solid var(--line);background:#11151d;color:var(--txt);font:inherit;font-size:11.5px;padding:5px 8px;border-radius:8px;color-scheme:dark}
          .sledtools select{min-width:112px}.sledtools input{width:116px}
          .sledtools button{border:1px solid var(--line);background:transparent;color:#8a93a3;font:inherit;font-size:11.5px;padding:5px 9px;border-radius:8px;cursor:pointer}
          .sledtools button:hover{color:var(--txt)}.sledtools button.on{background:#315bc4;border-color:#5279db;color:#fff}
          .stotc{background:#11151d;border:1px solid var(--line);border-radius:9px;padding:9px 12px;min-width:150px}
          .stotc .k{color:#7d899c;font-size:10.5px}.stotc .n{font-size:16px;font-weight:700;margin-top:2px}
          .stotc .s{color:#667389;font-size:10.5px}
          .stotc.loop{border-color:#23673b}.stotc.cand{border-color:#4a3d1a}
          .grow{display:grid;grid-template-columns:minmax(180px,2fr) 70px 90px 80px minmax(120px,1fr);gap:10px;
            align-items:center;padding:8px 14px;border-top:1px solid #171d28;font-size:12px}
          .grow:hover{background:#141a24}
          .grow .gl{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .grow .gk{font-size:10px;padding:1px 7px;border-radius:20px;border:1px solid #263149;background:#1a2336;color:#9fb6e8;margin-right:6px}
          .grow .gk.cand{background:#2a2312;border-color:#4a3d1a;color:#d29922}
          .grow .gk.human{background:#181c25;border-color:#242c3a;color:#7b8494}
          .grow .num{text-align:right;font-variant-numeric:tabular-nums}
          .grow .pj{color:#68758b;font-size:10.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .grow{cursor:pointer}
          .grow .car{color:#5d6678;font-size:9px;width:10px;display:inline-block}
          /* 회차 목록 — 크론 목록처럼 날짜가 축이다. 사람이 여기서 찾는 것은 "어제 그 회차"라
             크기순이 아니라 시간순이어야 한다. */
          .slist{background:#0f141d;border-top:1px solid #171d28;padding:4px 0 8px}
          .sdate{color:#68758b;font-size:10.5px;padding:6px 14px 2px 30px;letter-spacing:.02em}
          .srow{display:grid;grid-template-columns:58px 54px minmax(60px,1fr) 74px 62px;gap:10px;
            align-items:center;padding:5px 14px 5px 30px;font-size:12px;cursor:pointer}
          .srow:hover{background:#151b25}
          .srow .tm{color:#cfd6e2;font-variant-numeric:tabular-nums}
          .srow .du{color:#7b8494;font-size:11px}
          .srow .wt{color:#8a93a3;font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .srow .num{text-align:right;font-variant-numeric:tabular-nums}
          .srow.on{background:#151b25}
          /* 회차 하나 — 무엇을 시켰고, 무엇을 했고, 무엇이라 답했나. 로그가 아니라 이야기여야 한다. */
          .sdet{margin:2px 14px 10px 30px;background:#11151d;border:1px solid var(--line);border-radius:10px;padding:12px}
          .sdet .hd{display:flex;gap:12px;flex-wrap:wrap;color:#8a93a3;font-size:11.5px;margin-bottom:9px}
          .sdet .hd b{color:#dbe2ee}
          .sdet .lb{color:#7d899c;font-size:10.5px;letter-spacing:.04em;text-transform:uppercase;margin:10px 0 4px}
          .sdet .ask{background:#0f141d;border-left:2px solid #33518f;border-radius:0 7px 7px 0;
            padding:7px 10px;color:#c3cad6;font-size:12px;white-space:pre-wrap}
          .sdet .res{background:#0f141d;border-left:2px solid #23673b;border-radius:0 7px 7px 0;
            padding:7px 10px;color:#c9d6cc;font-size:12px;white-space:pre-wrap}
          .flowl{display:flex;gap:8px;align-items:flex-start;padding:3px 0;font-size:12px}
          .flowl .ft{color:#68758b;font-size:10.5px;flex:0 0 38px;font-variant-numeric:tabular-nums;padding-top:1px}
          .flowl .fi{flex:0 0 16px;text-align:center;font-size:10px}
          .flowl .fx{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .flowl.say .fx{color:#d5dbe6;white-space:normal}
          .flowl.edit .fi{color:#7ee29a}.flowl.run .fi{color:#8faeff}.flowl.agent .fi{color:#d29922}
          .flowl .fn{color:#8faeff;font-size:11px;margin-right:5px}
          .sdet .more{color:#68758b;font-size:11px;padding:4px 0 4px 46px}
          @media(max-width:760px){.grow{grid-template-columns:1fr 70px 80px}.grow .pj,.grow .num.c{display:none}.sledtools .spacer{display:none}
            .srow{grid-template-columns:56px 50px 70px 60px}.srow .wt{display:none}}
          @media(max-width:760px){.v2grid{grid-template-columns:1fr}.agents,.layerstack,.maturity{grid-template-columns:1fr 1fr}.usagecards{grid-template-columns:1fr 1fr}.looplist-hd .dir{display:none}details.looprow>summary{grid-template-columns:1fr auto}.loopwhat,.looppath{grid-column:1/-1}.looprecent{grid-column:1/-1}}
        </style></head>
        <body>
          <script>window.CM_PAGE='loop';</script>
          \#(SessionRail.html())
          <header>
            <div><h1>루프 엔지니어링</h1><div class="sub" id="lpSubtitle">선언된 루프가 무슨 문제를 해결하며 지금 어떻게 움직이는지 보여줍니다</div></div>
            <div class="acts"><div class="versions"><button class="vtab" id="v1tab" onclick="lpVersion(1)">V1</button><button class="vtab on" id="v2tab" onclick="lpVersion(2)">V2</button></div><button class="btn" onclick="lpReload()">새로고침</button><button class="btn" onclick="lpRefreshAll()" title="24시간보다 오래된 세션까지 전체 검색">전체 새로고침</button></div>
          </header>
          <main>
            <div id="lpV1" style="display:none">
            <div id="lpBand"></div>
            <div id="lpWaits"></div>
            <div id="lpTrend"></div>
            <div class="fold" id="lpFold">
              <div class="fhd" id="lpFoldHd"><span class="caret" id="lpCaret">▸</span>
                <span id="lpFoldTitle">프로젝트별 라우트</span></div>
              <div class="fbd" id="lpFoldBd" style="display:none">
                <div class="sum" id="orSum"></div>
                <div id="orNote"></div>
                <div class="tools">
                  <input type="text" id="orQ" placeholder="프로젝트·파트 이름으로 찾기" oninput="orRender()">
                  <label class="tg"><input type="checkbox" id="orRan" onchange="orRender()">실행된 라우트가 있는 것만</label>
                  <label class="tg"><input type="checkbox" id="orBad" onchange="orRender()">막힌 것만</label>
                </div>
                <div id="orList"><div class="empty">세션 기록을 훑는 중… (첫 조회는 몇 초 걸립니다)</div></div>
              </div>
            </div>
            <div class="foot" id="orFoot"></div>
            </div>
            <div id="lpV2"><div class="empty">loops 폴더의 선언을 읽는 중…</div></div>
          </main>
        <script>
        (function(){
          var D=null, D2=null, S=null, OPEN={}, OPENG={}, SDET={};
          var SLED_RANGE={preset:'all',start:'',end:''}, SLED_SORT='tokens', SLED_DESC=true;

          window.lpVersion=function(v){
            document.getElementById('lpV1').style.display=v===1?'block':'none';
            document.getElementById('lpV2').style.display=v===2?'block':'none';
            document.getElementById('v1tab').className='vtab'+(v===1?' on':'');
            document.getElementById('v2tab').className='vtab'+(v===2?' on':'');
            document.getElementById('lpSubtitle').textContent=v===1
              ? '세션 기록·goal 상태·launchd에서 병목과 대기를 역추적합니다'
              : '선언된 루프가 무슨 문제를 해결하며 지금 어떻게 움직이는지 보여줍니다';
            try{ localStorage.setItem('cm-loop-version',String(v)); }catch(e){}
            if(v===2&&!D2) v2Load();
          };
          window.lpReload=function(){ var v=document.getElementById('lpV2').style.display==='none'?1:2; if(v===1)orLoad();else v2Load(); };
          window.lpRefreshAll=function(){
            fetch('/api/loop-engineering/sessions?refresh=all').then(function(r){return r.json();})
              .then(function(d){S=d;v2Render();setTimeout(sessLoad,1000);}).catch(function(){});
          };

          function v2Load(){
            fetch('/api/loop-engineering/v2').then(function(r){return r.json();}).then(function(d){D2=d;v2Render();})
              .catch(function(){document.getElementById('lpV2').innerHTML='<div class="empty">루프 선언을 불러오지 못했습니다</div>';});
            sessLoad();
          }
          // 세션 원장. 선언 조회와 따로 간다 — 첫 실행에서는 이쪽이 몇 분 걸릴 수 있고, 그동안
          // 루프 선언은 이미 그려져 있어야 한다.
          function sessLoad(){
            fetch('/api/loop-engineering/sessions').then(function(r){return r.json();})
              .then(function(d){S=d;v2Render();
                // 아직 읽는 중이면 스스로 다시 물어본다. 사람이 새로고침을 눌러야 진행률이
                // 움직이면 "멈춘 것"과 구별되지 않는다.
                if(d&&d.progress&&(d.progress.running||d.progress.pending>0)) setTimeout(sessLoad,4000);})
              .catch(function(){});
          }
          function money(v){v=v||0;if(v>=100)return '$'+Math.round(v);if(v>=10)return '$'+v.toFixed(1);if(v>0)return '$'+v.toFixed(2);return '-';}
          function sessAgg(g,days){var out={t:0,c:0};if(!g)return out;var cut=new Date(Date.now()-days*86400000).toISOString().slice(0,10);
            for(var d in (g.days||{})){if(d>=cut){out.t+=g.days[d].t||0;out.c+=g.days[d].c||0;}}return out;}
          function loopGroup(id){if(!S||!id)return null;return (S.groups||[]).find(function(g){return g.loopId===id;})||null;}

          function sledDay(d){
            if(window.CMTimeFilter) return CMTimeFilter.dayStr(d);
            var x=new Date(d),p=function(n){return (n<10?'0':'')+n;};return x.getFullYear()+'-'+p(x.getMonth()+1)+'-'+p(x.getDate());
          }
          function sledAdd(ds,n){var d=window.CMTimeFilter?CMTimeFilter.parseDay(ds):new Date(ds+'T12:00:00');d.setDate(d.getDate()+n);return sledDay(d);}
          function sledPreset(key){
            if(key==='all')return {preset:key,start:'',end:''};
            if(window.CMTimeFilter){var r=CMTimeFilter.presetRange(key);return {preset:key,start:r.start,end:r.end};}
            var t=sledDay(new Date()),s=t,e=t;if(key==='yesterday'){s=sledAdd(t,-1);e=s;}else if(key==='7d')s=sledAdd(t,-6);else if(key==='1m')s=sledAdd(t,-30);else if(key==='3m')s=sledAdd(t,-90);return {preset:key,start:s,end:e};
          }
          function sledInRange(day){return SLED_RANGE.preset==='all'||((!SLED_RANGE.start||day>=SLED_RANGE.start)&&(!SLED_RANGE.end||day<=SLED_RANGE.end));}
          function sledGroup(g){
            if(SLED_RANGE.preset==='all')return g;
            var runs=(g.runs||[]).filter(function(r){return sledInRange(r.day||sledDay((r.start||0)*1000));});
            var t=0,c=0,ds=[];Object.keys(g.days||{}).forEach(function(d){if(sledInRange(d)){t+=(g.days[d].t||0);c+=(g.days[d].c||0);ds.push(d);}});ds.sort();
            return Object.assign({},g,{runs:runs,sessions:runs.length,tokens:t,cost:c,first:ds[0]||'',last:ds.slice(-1)[0]||''});
          }
          function sledControlsHTML(){
            var b=function(k,lb){return '<button class="'+(SLED_RANGE.preset===k?'on':'')+'" onclick="sledPick(\''+k+'\')">'+lb+'</button>';};
            return '<div class="sledtools"><span class="ctl-label">기간</span>'+b('all','전체')+b('today','오늘')+b('yesterday','어제')+b('7d','7일')+b('1m','한달')+b('3m','3달')
              +'<input type="date" title="시작 날짜" value="'+esc(SLED_RANGE.start)+'" onchange="sledDate(0,this.value)"><span class="mini">~</span><input type="date" title="끝 날짜" value="'+esc(SLED_RANGE.end)+'" onchange="sledDate(1,this.value)">'
              +'<span class="spacer"></span><span class="ctl-label">정렬</span><select onchange="sledSort(this.value)">'
              +[['tokens','토큰 양'],['cost','총 금액'],['sessions','세션 수'],['name','이름']].map(function(x){return '<option value="'+x[0]+'"'+(SLED_SORT===x[0]?' selected':'')+'>'+x[1]+'</option>';}).join('')
              +'</select><button title="정렬 방향 바꾸기" onclick="sledDirection()">'+(SLED_DESC?'내림차순 ↓':'오름차순 ↑')+'</button></div>';
          }
          window.sledPick=function(k){SLED_RANGE=sledPreset(k);paintSled();};
          window.sledDate=function(which,v){var a=SLED_RANGE.start,b=SLED_RANGE.end;if(which===0)a=v;else b=v;if(!a)a=b;if(!b)b=a;if(a>b){var q=a;a=b;b=q;}SLED_RANGE={preset:'custom',start:a,end:b};paintSled();};
          window.sledSort=function(k){SLED_SORT=k;paintSled();};
          window.sledDirection=function(){SLED_DESC=!SLED_DESC;paintSled();};

          // 이 맥의 세션이 루프와 사람 사이에 어떻게 갈리는지 + 미등록 루프 후보.
          function sessPanelHTML(){
            if(!S) return '<div class="sled"><div class="shd"><b>세션 원장</b><span class="mini">세션 판정을 불러오는 중…</span></div></div>';
            var p=S.progress||{}, allGroups=S.groups||[];
            var t=SLED_RANGE.preset==='all'?(S.totals||{}):{loop:{sessions:0,tokens:0,cost:0},candidate:{sessions:0,tokens:0,cost:0},human:{sessions:0,tokens:0,cost:0}};
            if(SLED_RANGE.preset!=='all')allGroups.forEach(function(raw){var g=sledGroup(raw),x=t[g.kind]||t.human;x.sessions+=g.sessions||0;x.tokens+=g.tokens||0;x.cost+=g.cost||0;});
            var pct=p.total? Math.round(100*(p.total-(p.pending||0))/p.total) : 100;
            var scope=p.scope==='all'?'전체 세션':'최근 '+(p.lookbackHours||24)+'시간';
            var progTxt=p.running? (scope+' 분석 중 '+(p.total-(p.pending||0))+'/'+p.total+'개'+(p.current?(' · '+esc(String(p.current).slice(0,8))):''))
                                 : ('분석 완료 '+(p.analyzed||0)+'/'+(p.total||0)+'개'+(p.lastPassAt?(' · '+fmtRel(p.lastPassAt)):''));
            var card=function(k,cls,lb,note){var x=t[k]||{};return '<div class="stotc '+cls+'"><div class="k">'+lb+'</div>'
              +'<div class="n">'+tokenFmt(x.tokens||0)+' <span style="font-size:11px;color:#7d899c">'+money(x.cost)+'</span></div>'
              +'<div class="s">세션 '+(x.sessions||0)+'개 · '+note+'</div></div>';};
            var groups=allGroups.map(sledGroup).filter(function(g){return g.kind!=='human'&&(SLED_RANGE.preset==='all'||g.sessions||g.tokens||g.cost);});
            groups.sort(function(a,b){var av,bv;if(SLED_SORT==='name'){av=(a.label||'').toLocaleLowerCase();bv=(b.label||'').toLocaleLowerCase();var z=av.localeCompare(bv,'ko');return SLED_DESC?-z:z;}av=a[SLED_SORT]||0;bv=b[SLED_SORT]||0;return SLED_DESC?(bv-av):(av-bv);});
            var rows=groups.map(function(g){
              var kindLb=g.kind==='loop'?'등록':'미등록', op=!!OPENG[g.key];
              return '<div class="grow" onclick="lpToggleGroup(\''+esc(g.key).replace(/'/g,"&#39;")+'\')">'
                +'<div class="gl" title="'+esc(g.label)+'"><span class="car">'+(op?'▾':'▸')+'</span> <span class="gk '+(g.kind==='loop'?'':'cand')+'">'+kindLb+'</span>'+esc(g.label)+'</div>'
                +'<div class="num">'+g.sessions+'개</div>'
                +'<div class="num">'+tokenFmt(g.tokens)+'</div>'
                +'<div class="num c">'+money(g.cost)+'</div>'
                +'<div class="pj" title="'+esc((g.projects||[]).join(', '))+'">'+esc((g.projects||[]).join(', '))+' · '+esc(g.first||'')+'~'+esc(g.last||'')+'</div></div>'
                +(op? sessListHTML(g) : '');
            }).join('');
            return '<div class="sled" id="lpSled">'
              +'<div class="shd"><b>세션 원장</b><span class="badge">'+groups.length+'개 루프</span>'
              +'<span class="mini">기본 검색은 최근 24시간 · 분석된 세션은 다시 읽지 않음 · 과거 누락분은 전체 새로고침</span>'
              +'<span class="prog">'+progTxt+'</span></div>'
              +'<div class="pbar"><i style="width:'+pct+'%"></i></div>'
              +'<div class="stot">'+card('loop','loop','등록된 루프','loops/index.md 에 선언됨')
                                   +card('candidate','cand','미등록 루프 후보','기계가 반복해서 연 세션')
                                   +card('human','','사람이 연 세션','매번 다른 프롬프트')+'</div>'
              +sledControlsHTML()
              +(rows||'<div class="grow"><div class="gl mini">아직 루프로 판정된 세션이 없습니다</div></div>')
              +'</div>';
          }
          // 루프 행을 눌러 회차 목록을 펼친다. 패널만 다시 그린다 — 페이지 전체를 다시 그리면
          // 열어 둔 다른 것들이 닫힌다.
          window.lpToggleGroup=function(key){ OPENG[key]=!OPENG[key]; paintSled(); };
          function paintSled(){ var el=document.getElementById('lpSled'); if(el) el.outerHTML=sessPanelHTML();
            var el2=document.getElementById('lpLoopSess'); if(el2&&el2.dataset.loop) el2.innerHTML=loopSessInner(el2.dataset.loop); }

          var WD=['일','월','화','수','목','금','토'];
          function dstr(sec){var d=new Date(sec*1000);return (d.getMonth()+1)+'월 '+d.getDate()+'일 ('+WD[d.getDay()]+')';}
          function tstr(sec){var d=new Date(sec*1000),h=d.getHours(),m=d.getMinutes();return (h<10?'0':'')+h+':'+(m<10?'0':'')+m;}
          function durstr(a,b){var s=Math.max(0,(b||0)-(a||0));if(!s)return '';
            if(s<60)return s+'초'; if(s<3600)return Math.round(s/60)+'분'; return (Math.round(s/360)/10)+'시간';}

          // 회차 목록 — 크론 목록과 같은 읽는 법: 날짜가 머리, 그 아래 시각별로 한 줄.
          function sessListHTML(g){
            var list=(g.runs||[]).filter(function(r){return sledInRange(r.day||sledDay((r.start||0)*1000));});
            if(!list.length) return '<div class="slist"><div class="sdate">회차 기록이 없습니다</div></div>';
            var out='<div class="slist">', last='';
            list.forEach(function(r){
              var d=r.start? dstr(r.start) : (r.day||'');
              if(d!==last){ out+='<div class="sdate">'+esc(d)+'</div>'; last=d; }
              var op=!!SDET[r.sid];
              // 토큰을 하나도 안 쓰고 끝난 회차 — 크론은 돌았는데 아무 일도 안 일어난 자리다.
              // 목록에서 이것이 다른 회차와 같아 보이면 실패가 정상 옆에 숨는다.
              var dead=!(r.tokens>0)||(r.turns||0)<=1;
              out+='<div class="srow'+(op?' on':'')+'" onclick="lpToggleSess(\''+esc(r.sid)+'\')"'
                +(dead?' style="opacity:.55"':'')+'>'
                +'<span class="tm">'+(r.start? tstr(r.start) : '-')+'</span>'
                +'<span class="du">'+durstr(r.start,r.end)+'</span>'
                +'<span class="wt"'+(dead?' style="color:#d29922"':'')+'>'
                +esc(dead? '빈 회차 — 토큰을 쓰지 않고 끝남' : ('턴 '+r.turns+' · 도구 '+r.tools))+'</span>'
                +'<span class="num">'+tokenFmt(r.tokens)+'</span>'
                +'<span class="num">'+money(parseFloat(r.cost))+'</span></div>'
                +(op? sessDetailHTML(r.sid) : '');
            });
            return out+'</div>';
          }
          window.lpToggleSess=function(sid){
            if(event) event.stopPropagation();
            if(SDET[sid]){ delete SDET[sid]; paintSled(); return; }
            SDET[sid]='loading'; paintSled();
            fetch('/api/loop-engineering/session?sid='+encodeURIComponent(sid))
              .then(function(r){return r.json();})
              .then(function(d){ SDET[sid]=d||{}; paintSled(); })
              .catch(function(){ SDET[sid]={}; paintSled(); });
          };
          var ICON={say:'●',edit:'✎',run:'▶',agent:'⇢'};
          // 회차 하나를 읽는 법: 시켰다 → 했다 → 답했다. 도구 인자 원문과 읽기 호출은 세기만 하고
          // 적지 않는다 — 다 적으면 그냥 로그가 되고, 그러면 아무도 안 읽는다.
          function sessDetailHTML(sid){
            var d=SDET[sid];
            if(d==='loading') return '<div class="sdet"><div class="mini">회차를 읽는 중…</div></div>';
            if(!d||!d.sid) return '<div class="sdet"><div class="mini">이 회차의 기록을 찾지 못했습니다</div></div>';
            var hd='<div class="hd"><span>'+esc(dstr(d.start))+' <b>'+tstr(d.start)+'</b> → '+tstr(d.end)+'</span>'
              +'<span>소요 <b>'+durstr(d.start,d.end)+'</b></span>'
              +'<span>턴 <b>'+d.turns+'</b> · 도구 <b>'+d.tools+'</b></span>'
              +'<span><b>'+tokenFmt(d.tokens)+'</b> · '+money(parseFloat(d.cost))+'</span>'
              +'<span class="mini">'+esc(d.proj||'')+' · '+esc(d.sid)+'</span></div>';
            var ask=d.prompt? '<div class="lb">무엇을 시켰나</div><div class="ask">'+esc(d.prompt)+'</div>' : '';
            var flow=(d.steps||[]).map(function(st){
              return '<div class="flowl '+esc(st.kind)+'"><span class="ft">'+tstr(st.ts)+'</span>'
                +'<span class="fi">'+(ICON[st.kind]||'·')+'</span>'
                +'<span class="fx">'+(st.name?('<span class="fn">'+esc(st.name)+'</span>'):'')+esc(st.text)+'</span></div>';
            }).join('');
            if(d.elided>0) flow+='<div class="more">… 가운데 '+d.elided+'단계 생략</div>';
            var tools=(d.toolTop||[]).map(function(t){return esc(t.name)+' '+t.n;}).join(' · ');
            var files=(d.files||[]).length? '<div class="lb">고친 파일 '+d.files.length+'개</div><div class="mini">'+esc(d.files.join(' · '))+'</div>' : '';
            var ags=(d.agents||[]).length? '<div class="lb">위임한 에이전트</div><div class="mini">'+esc(d.agents.join(' · '))+'</div>' : '';
            var res=d.result? '<div class="lb">마지막 응답</div><div class="res">'+esc(d.result)+'</div>' : '';
            return '<div class="sdet">'+hd+ask
              +(flow? '<div class="lb">무엇을 했나</div>'+flow : '')
              +res
              +(tools? '<div class="lb">도구</div><div class="mini">'+tools+'</div>' : '')
              +files+ags+'</div>';
          }
          function loopSessInner(id){ var g=loopGroup(id); return g? sessListHTML(g) : ''; }
          function tokenFmt(n){n=n||0;if(n>=1000000)return (Math.round(n/100000)/10)+'M';if(n>=1000)return (Math.round(n/100)/10)+'K';return String(n);}
          function usageAgg(events,days){var cut=Date.now()-days*86400000, a={input:0,output:0,total:0,cost:0,hours:Array(24).fill(0),calls:0};
            (events||[]).forEach(function(e){var t=new Date(e.ts).getTime();if(isNaN(t)||t<cut)return;a.input+=e.input||0;a.output+=e.output||0;a.total+=e.total||0;a.cost+=e.costUSD||0;a.calls++;a.hours[new Date(t).getHours()]+=e.total||0;});return a;}
          // 토큰 사용량은 출처가 둘이다. (1) 루프가 스스로 남긴 원장 — 데몬이 API 를 직접 부르는
          // 루프는 여기에만 남는다. (2) 세션 원장 — 이 루프를 돌리려고 열린 Claude 세션의
          // 트랜스크립트. 둘을 더해 한 숫자로 보여 주되, 어느 쪽에서 왔는지는 항상 같이 적는다.
          // 합계만 적으면 "세션이 안 잡힌 것"과 "정말 안 돈 것"이 구별되지 않는다.
          function usageHTML(x){var ev=x.usageEvents||[], g=loopGroup(x.id);
            // 31일 창 밖의 기록만 있는 루프도 있다 — ev 가 비었다고 기록이 없는 것은 아니다.
            if(!ev.length&&!g&&!((x.usageTotals||{}).total)){
              var why=x.sessionNote? esc(x.sessionNote)
                : '이 루프의 선언에 <b>sessionSignatures</b>(이 루프가 여는 세션의 첫 프롬프트 앞머리)가 없으면 세션 원장이 세션을 이 루프에 붙이지 못합니다. loops/index.md 에 한 줄 넣으면 과거 세션까지 소급해 붙습니다.';
              return '<section class="v2sec"><h3>토큰 사용량</h3><div class="unmeasured"><b>이 루프에 붙은 토큰 기록이 아직 없습니다</b><br>0 tokens라는 뜻이 아닙니다. '+why+'</div></section>';}
            // 누적 카드를 맨 앞에 둔다. 창별 카드만 있으면 "최근 1일 12.9K"가 루프 전체를
            // 대표하는 것처럼 읽히는데, 기록이 그날 20분치뿐일 수 있다. 누적과 기록 시작을
            // 같이 보여야 그 착시가 안 생긴다.
            var ut=x.usageTotals||{};
            var cumTok=(ut.total||0)+((g&&g.tokens)||0), cumCost=(ut.costUSD||0)+((g&&g.cost)||0);
            var cumCard=cumTok? ('<div class="ucard" style="border-color:#2f4a6d">'
              +'<div class="days">누적'+(ut.calls?(' · '+ut.calls+'회 원장'):'')+((ut.calls&&g&&g.tokens)?' · 세션':'')+'</div>'
              +'<div class="tok">'+tokenFmt(cumTok)+'</div>'
              +'<div class="io">'+(cumCost?money(cumCost):'단가 미상')
              +(ut.firstAt?(' · '+tdisp(ut.firstAt,10)+' ~'):'')+'</div></div>') : '';

            // 원장은 오래됐는데 토큰 기록은 최근 것만 있는 상태 — 화면이 이걸 말하지 않으면
            // 사용자는 누적을 루프 전체 비용으로 읽는다. 실제로 원장 13일 / 기록 20분이었다.
            var gap='';
            if(ut.firstAt&&x.ledgerFrom){
              var lf=new Date(x.ledgerFrom).getTime(), uf=new Date(ut.firstAt).getTime();
              var blind=Math.floor((uf-lf)/86400000);
              if(blind>=1) gap='<div class="unmeasured" style="margin-bottom:8px">'
                +'<b>이 숫자는 루프 전체가 아닙니다</b><br>원장은 '+tdisp(x.ledgerFrom,10)
                +'부터인데 토큰 기록은 '+tdisp(ut.firstAt,10)+'부터입니다 — 앞의 '+blind
                +'일치 호출은 토큰이 기록되지 않아 이 합계에 없습니다.</div>';
            }
            if(ut.calls&&ut.pricedCalls<ut.calls){
              gap+='<div class="unmeasured" style="margin-bottom:8px"><b>비용이 과소 집계됩니다</b><br>'
                +'원장 '+ut.calls+'회 중 '+(ut.calls-ut.pricedCalls)+'회는 단가를 모르는 모델이라 비용이 0으로 잡혔습니다.</div>';
            }
            var cards=[1,3,7,30].map(function(d){var a=usageAgg(ev,d), sg=sessAgg(g,d);
              var tot=a.total+sg.t, cost=a.cost+sg.c;
              var src=(a.calls?(a.calls+'회 원장'):'')+((a.calls&&sg.t)?' · ':'')+(sg.t?'세션':'');
              return '<div class="ucard"><div class="days">최근 '+d+'일'+(src?(' · '+src):'')+'</div><div class="tok">'+tokenFmt(tot)+'</div><div class="io">'
                +(a.total?('원장 '+tokenFmt(a.total)):'')+((a.total&&sg.t)?' · ':'')+(sg.t?('세션 '+tokenFmt(sg.t)):'')
                +(cost?(' · '+money(cost)):'')+'</div></div>';}).join('');
            var sess='';
            if(g){
              sess='<section class="v2sec"><h3>이 루프를 돌린 세션</h3>'
                +'<div class="mini" style="margin-bottom:6px">세션 '+g.sessions+'개 · 합계 '+tokenFmt(g.tokens)+' · '+money(g.cost)+' · '+esc(g.first||'')+' ~ '+esc(g.last||'')+' · 회차를 누르면 그 회차가 무엇을 했는지 펼쳐집니다</div>'
                +'<div id="lpLoopSess" data-loop="'+esc(x.id)+'">'+sessListHTML(g)+'</div></section>';
            }
            return '<section class="v2sec"><h3>토큰 사용량</h3>'+gap+'<div class="usagecards">'+cumCard+cards+'</div>'
              +(ev.length? ('<div class="hourhd"><span class="mini">시간대별 사용량 (루프 원장 기준)</span>'+[1,3,7,30].map(function(d){return '<button class="period '+(d===7?'on':'')+'" onclick="event.preventDefault();usagePeriod(\''+esc(x.id)+'\','+d+',this)">'+d+'일</button>';}).join('')+'</div><div class="hours" id="hours-'+esc(x.id)+'"></div>') : '')
              +'</section>'+sess;}
          window.usagePeriod=function(id,days,btn){var x=((D2&&D2.loops)||[]).find(function(r){return r.id===id;});if(!x)return;var a=usageAgg(x.usageEvents||[],days),mx=Math.max.apply(null,a.hours.concat([1])),box=document.getElementById('hours-'+id);if(!box)return;
            box.innerHTML=a.hours.map(function(n,h){var pct=Math.round(n/mx*100);return '<div class="hour '+(n===mx&&n>0?'hot':'')+'" title="'+h+'시 · '+n.toLocaleString()+' tokens"><i style="height:'+Math.max(1,pct)+'px"></i><span>'+(h%3===0?h:'')+'</span></div>';}).join('');
            var root=box.parentNode;if(root)root.querySelectorAll('.period').forEach(function(b){b.classList.toggle('on',b.textContent===days+'일');});};
          function v2Render(){
            var box=document.getElementById('lpV2'), rows=(D2&&D2.loops)||[];
            // 선언이 아직 안 왔거나 하나도 없어도 세션 원장은 그린다 — 등록된 루프가 없다는
            // 것과 이 맥에서 루프가 안 돈다는 것은 다른 말이고, 그 차이가 이 화면의 요지다.
            if(!rows.length){box.innerHTML=sessPanelHTML()
              +'<div class="empty">loops 폴더에 루프 선언이 없습니다</div>';return;}
            var items=rows.map(function(x){
              var allOK=x.connected!==false && x.workspaceExists!==false && (x.triggers||[]).every(function(t){return t.registered!==false;});
              var last=x.lastRun||{};
              var recent=last.ts
                ? ('최근 활동 '+fmtRel(last.ts)+' · '+esc(last.stage||'')+' '+esc(last.outcome||'')+' · '+esc(last.detail||''))
                : '아직 실행 원장이 없습니다';
              recent+=' · 라우터 동기화 '+fmtRel(x.syncedAt);
              // 짧은 창(24시간)만 적으면, 토큰 기록이 20분치뿐인 루프에서 그 숫자가 루프
              // 전체를 대표하는 것처럼 읽힌다. 누적을 적고 그것이 언제부터의 숫자인지를
              // 같이 적는다 — 기록 구간이 원장 구간보다 짧다는 사실 자체가 정보다.
              var ut=x.usageTotals||{}, gCum=loopGroup(x.id);
              var cumTok=(ut.total||0)+((gCum&&gCum.tokens)||0);
              var cumCost=(ut.costUSD||0)+((gCum&&gCum.cost)||0);
              recent+=cumTok
                ? (' · 누적 토큰 '+tokenFmt(cumTok)+(cumCost?(' · '+money(cumCost)):'')
                   +(ut.firstAt?(' (기록 '+String(ut.firstAt).slice(5,10)+'~)'):''))
                : ' · 토큰 기록 없음';
              var gAll=loopGroup(x.id);
              if(gAll) recent+=' · 세션 '+gAll.sessions+'개 '+tokenFmt(gAll.tokens)+' '+money(gAll.cost);
              var triggerText=(x.triggers||[]).map(function(t){return (t.kind==='cron'?'실행 ':'이벤트 ')+t.cadence;}).join(' · ');
              var scope='<span class="badge" style="margin-left:7px">'+esc(x.scopeLabel||'프로젝트 전용')+'</span>';
              var tr=(x.triggers||[]).map(function(t){var ok=t.registered!==false;
                return '<div class="trigger"><span class="kind">'+esc(t.kind==='cron'?'CRON':'EVENT')+'</span><div><div class="name">'+esc(t.name)+'</div><div class="detail">'+esc(t.cadence)+' · '+esc(t.detail)+'</div></div><span class="health '+(ok?'':'bad')+'">'+(ok?'● 연결됨':'● 미등록')+'</span></div>';}).join('');
              var fl=(x.flow||[]).map(function(s,i){return (i?'<span class="arrow">→</span>':'')+'<div class="step"><div class="from">'+esc(s.from)+'</div><div class="to">→ '+esc(s.to)+'</div><div class="why">'+esc(s.label)+'</div></div>';}).join('');
              var ag=(x.agents||[]).map(function(a){return '<div class="agent"><div class="role">'+esc(a.role)+'</div><b>'+esc(a.name)+'</b><p>'+esc(a.job)+'</p></div>';}).join('');
              var layers=(x.layers||[]).map(function(a){return '<div class="layer"><div class="kind">'+esc(a.kind)+'</div><b>'+esc(a.name)+'</b><p>'+esc(a.job)+'</p><code>'+esc(a.source)+'</code></div>';}).join('');
              var states={done:'구축됨',current:'현재',partial:'일부',next:'다음'};
              var maturity=(x.maturity||[]).map(function(a){return '<div class="mstep '+esc(a.status)+'"><div class="lv">LEVEL '+esc(a.level)+'<span class="mstate">'+esc(states[a.status]||a.status)+'</span></div><b>'+esc(a.name)+'</b><p>'+esc(a.detail)+'</p></div>';}).join('');
              var ev=(x.evidence||[]).map(function(e){return '<div class="ev"><b>'+esc(e.name)+'</b><span>'+esc(e.path)+'</span></div>';}).join('');
              return '<details class="looprow"><summary><span class="loopname">'+esc(x.name||x.id)+scope+'</span><span class="loopwhat">'+esc(triggerText)+'</span><span class="looppath" title="'+esc(x.workspace)+'">'+esc(x.workspace)+'</span><span class="live" style="'+(allOK?'':'color:#f85149;border-color:#4a1f22;background:#2a1416')+'">'+(allOK?'동작 중':'확인 필요')+'</span><span class="looprecent">'+recent+' · 동작 '+(x.runCount||0)+'건'+((x.runCountPolls||0)?(' (+API 폴링 '+x.runCountPolls+'건)'):'')+'</span></summary><div class="loopdetail">'
                +'<section class="v2hero"><div class="v2top"><div><h2>'+esc(x.name||x.id)+scope+'</h2><div class="mini">관리 폴더 · '+esc(x.workspace)+'</div><div class="mini">루프 파일 · '+esc(x.definitionPath)+'</div></div></div><div class="v2purpose">'+esc(x.purpose)+'</div><div class="v2grid"><div class="v2box"><div class="lb">해결하는 문제</div><p>'+esc(x.problem)+'</p></div><div class="v2box"><div class="lb">책임 경계</div><p>'+esc(x.modelProblem)+'</p></div></div></section>'
                +usageHTML(x)
                +'<section class="v2sec"><h3>어떻게 시작되는가</h3>'+tr+'</section>'
                +'<section class="v2sec"><h3>전체 흐름</h3><div class="flow">'+fl+'</div></section>'
                +(layers?'<section class="v2sec"><h3>응답 레이어 · 실제 실행 순서</h3><div class="layerstack">'+layers+'</div></section>':'')
                +(maturity?'<section class="v2sec"><h3>에이전트 발전 단계</h3><div class="maturity">'+maturity+'</div></section>':'')
                +(ag?'<section class="v2sec"><h3>관리자와 워커</h3><div class="agents">'+ag+'</div></section>':'')
                +'<section class="v2sec"><h3>무엇으로 작동을 증명하는가</h3><div class="evidence">'+ev+'</div><div class="v2grid" style="margin-top:10px"><div class="v2box"><div class="lb">확인됨</div><p>'+esc(x.known)+'</p></div><div class="v2box"><div class="lb">아직 확인 전</div><p>'+esc(x.unknown)+'</p></div></div></section></div></details>';
            }).join('');
            box.innerHTML=sessPanelHTML()+'<div class="looplist"><div class="looplist-hd"><b>등록된 루프</b><span class="badge">'+rows.length+'개</span><span class="mini">프로젝트 원본을 직접 읽습니다 · 행을 누르면 상세 흐름이 열립니다</span><span class="dir">'+esc(D2.registry||D2.directory||'loops/index.md')+'</span></div>'+items+'</div>';
            rows.forEach(function(x){if((x.usageEvents||[]).length)usagePeriod(x.id,7);});
          }

          function esc(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }

          // 저장된 ISO 시각을 표시 타임존(설정값 · window.CM_TZ)의 벽시계로 찍는다.
          // 자르기(`slice`)는 변환이 아니다 — UTC 로 적힌 값이 그대로 화면에 나온다.
          // 규칙 한 벌은 CMTimeFilter.isoDisp 에 있고 레일이 임베드한다.
          function tdisp(v,len,sep){
            return (window.CMTimeFilter && CMTimeFilter.isoDisp)
              ? CMTimeFilter.isoDisp(v,len,sep)
              : String(v==null?'':v).replace('T',(sep===undefined?' ':sep)).slice(0,len||16);
          }
          function fmtRel(ts){ if(!ts) return '기록 없음';
            try{ var t=new Date(ts).getTime(); if(isNaN(t)) return '';
              var s=Math.max(0,(Date.now()-t)/1000);
              if(s<60) return '방금'; if(s<3600) return Math.floor(s/60)+'분전';
              if(s<86400) return Math.floor(s/3600)+'시간전'; if(s<2592000) return Math.floor(s/86400)+'일전';
              return Math.floor(s/2592000)+'개월전'; }catch(e){ return ''; } }
          // 초를 사람이 읽는 단위로. 병목 문장의 근거 숫자라 반올림만 하고 늘리거나 줄이지 않는다.
          function dur(s){ s=s||0; if(s<60) return s+'초';
            if(s<3600) return Math.round(s/60)+'분'; return (Math.round(s/360)/10)+'시간'; }

          window.orLoad=function(){
            fetch('/api/loop-engineering').then(function(r){ return r.json(); })
              .then(function(d){ D=d; orRender(); })
              .catch(function(){ var l=document.getElementById('orList');
                if(l) l.innerHTML='<div class="empty">루프 기록을 불러오지 못했습니다</div>'; });
          };

          // 체류 시간. 잰 값이 없으면 0이 아니라 '기록 없음'이다 — 0은 "방금 생겼다"는 뜻이고
          // 그것은 거짓말이 된다.
          function dwell(s){
            if(s==null||s<0) return '기록 없음';
            if(s<60) return Math.round(s)+'초';
            if(s<3600) return Math.round(s/60)+'분';
            if(s<86400) return (Math.round(s/360)/10)+'시간';
            return Math.round(s/86400)+'일';
          }

          // ── 병목 밴드 ───────────────────────────────────────────────────────────────
          function band(b){
            var el=document.getElementById('lpBand'); if(!el) return;
            if(!b){ el.innerHTML=''; return; }
            var pct=(b.index||0);
            var lims=(b.limits||[]).map(function(x){ return '<div>'+esc(x)+'</div>'; }).join('');
            el.innerHTML='<div class="band">'
              +'<div class="cap">사람 병목 지수</div>'
              +'<div class="big"><span class="pct">'+pct.toFixed(1)+'%</span>'
              +'<span class="who">이 맥의 병목은 사람입니다 — 에이전트가 아니라 사람의 차례를 기다리는 데 시간이 갑니다</span></div>'
              +'<div class="meter"><i style="width:'+Math.max(0,Math.min(100,pct))+'%"></i></div>'
              +'<div class="frac">사람 대기 <b>'+(b.humanHours||0)+'h</b> / 전체 <b>'+(b.totalHours||0)+'h</b>'
              +' · 에이전트 가동 '+(b.agentHours||0)+'h'
              +' · '+(b.capHours||4)+'시간 상한 적용</div>'
              +'<div class="frac">잰 사람 공백 '+(b.turns||0)+'회 · 세션 '+(b.files||0)+'개'
              +' · 서브에이전트 트랜스크립트 '+(b.agentFiles||0)+'개'
              +' · 창 '+esc(tdisp(b.windowStart,10))+' 이후 시작된 세션</div>'
              +'<div class="lim">'+lims+'</div>'
              +'</div>';
          }

          // ── 지금 열려 있는 대기 ─────────────────────────────────────────────────────
          function waits(rows){
            var el=document.getElementById('lpWaits'); if(!el) return;
            rows=rows||[];
            var stalled=rows.filter(function(r){ return r.stalled; }).length;
            var head='<div class="whd"><span>지금 열려 있는 대기</span>'
              +'<span class="badge">'+rows.length+'건</span>'
              +(stalled>0?'<span class="badge" style="background:#2a1416;border-color:#4a1f22;color:#f85149">STALLED '+stalled+'</span>':'')
              +'<span class="mini" style="margin-left:auto">체류 내림차순 · 해소하면 다음 조회에서 이 표에서 사라집니다</span></div>';
            if(!rows.length){
              el.innerHTML='<div class="waits">'+head
                +'<div class="wrow"><span class="mini">열려 있는 대기가 없습니다 — 사람 응답 대기, 끊긴 홉, 미등록 예약 워커 셋 다 비어 있습니다</span></div></div>';
              return;
            }
            el.innerHTML='<div class="waits">'+head+rows.map(waitRow).join('')+'</div>';
            // 버튼은 마크업 문자열이 아니라 위임(delegation)으로 붙인다 — goal 제목에 따옴표가
            // 들어가도 onclick 문자열이 깨지지 않는다.
            el.onclick=function(ev){
              var b=ev.target.closest('button[data-act]'); if(!b) return;
              var i=parseInt(b.getAttribute('data-i'),10);
              doAct(rows[i], b.getAttribute('data-act'), b.getAttribute('data-val'));
            };
          }

          function waitRow(r,i){
            var cls=r.kind==='dead'?'dead':(r.kind==='worker'?'worker':'');
            var acts=(r.actions||[]).map(function(a){
              return '<button data-i="'+i+'" data-act="'+esc(a.act)+'"'
                +(a.value?(' data-val="'+esc(a.value)+'"'):'')
                +(a.act==='status'&&a.value==='in_progress'?' class="go"':'')
                +'>'+esc(a.label)+'</button>';
            }).join('');
            var thr=(r.thresholdSec>0)?('임계 '+dwell(r.thresholdSec)):'임계 —';
            return '<div class="wrow">'
              +'<div class="l1">'
              +'<span class="kd '+cls+'">'+esc(r.kindLabel||'')+'</span>'
              +'<span class="ttl" title="'+esc(r.title||'')+'">'+esc(r.title||'')+'</span>'
              +(r.where?('<span class="mini">'+esc(r.where)+'</span>'):'')
              +'<span class="dw">'+esc(r.owner||'')+' · 체류 '+dwell(r.dwellSec)+' · '+thr+'</span>'
              +'<span class="vd '+(r.stalled?'stalled':'')+'">'+(r.stalled?'STALLED':'정상')+'</span>'
              +'</div>'
              +(r.note?('<div class="nt">'+esc(r.note)+'</div>'):'')
              +(acts?('<div class="acts2">'+acts+'</div>'):'')
              +'</div>';
          }

          function doAct(r, act, val){
            if(!r) return;
            if(act==='open-goal'){ location.href='/goal?seq='+encodeURIComponent(r.seq); return; }
            if(act==='status'){
              // 이 화면이 살아 있다는 증거: 여기서 상태를 바꾸면 다음 조회에서 그 행이 사라진다.
              fetch('/api/goal/status',{method:'POST',headers:{'Content-Type':'application/json'},
                body:JSON.stringify({id:r.goalId,status:val})})
                .then(function(){ orLoad(); })
                .catch(function(){});
              return;
            }
            if(act==='hint-dead'){
              alert('끊긴 홉을 푸는 법\n\n'
                +'세션은 시작할 때 파트 목록을 한 번 읽습니다. 그 뒤에 저장된 에이전트 정의는 같은 '
                +'세션 안에서 보이지 않습니다.\n\n'
                +'정의 파일이 이미 디스크에 있다면 파일을 더 고쳐도 풀리지 않습니다. 세션을 새로 여세요.\n'
                +'정의 파일이 없다면 먼저 그 이름의 파트를 만드세요.');
              return;
            }
            if(act==='hint-worker'){
              alert('예약 워커를 launchd 에 거는 법\n\n'
                +'plist: '+(r.path||'(경로 없음)')+'\n\n'
                +'  launchctl bootstrap gui/$(id -u) <plist 경로>\n'
                +'  launchctl enable gui/$(id -u)/<label>\n\n'
                +'등록 여부는 launchd 가 진실입니다 — 저장소에 커밋만 되어 있는 것은 등록이 아닙니다.');
              return;
            }
          }

          // ── 추세 ────────────────────────────────────────────────────────────────────
          function trend(h){
            var el=document.getElementById('lpTrend'); if(!el) return;
            h=h||[];
            if(!h.length){ el.innerHTML='<div class="trend">추세 — 아직 기록이 없습니다. '
              +'~/.condition-mate/ledger/loop-history.jsonl 에 정해진 간격으로 한 줄씩 쌓입니다(덮어쓰지 않습니다).</div>'; return; }
            var vals=h.map(function(x){ return '<b>'+(x.index||0).toFixed(1)+'%</b> ('
              +esc(tdisp(x.at,16).slice(5))+')'; }).join(' → ');
            el.innerHTML='<div class="trend">추세 — '+vals
              +(h.length<3?(' · 값이 '+h.length+'개뿐이라 선을 그리지 않습니다'):'')+'</div>';
          }

          function summary(t){
            var box=document.getElementById('orSum'); if(!box||!t) return;
            var cards=[
              ['프로젝트', t.projects||0, ''],
              ['라우트', t.routes||0, ''],
              ['실행된 위임', t.runs||0, ''],
              ['위임에 쓴 시간', (Math.round((t.hours||0)*10)/10)+'h', ''],
              ['끊긴 홉', t.dead||0, ((t.dead||0)>0?'warn':'')],
              ['한 번도 안 쓴 파트', t.unused||0, ((t.unused||0)>0?'warn':'')]
            ];
            box.innerHTML=cards.map(function(c){
              return '<div class="card '+c[2]+'"><div class="n">'+c[1]+'</div><div class="k">'+c[0]+'</div></div>';
            }).join('');

            // 측정 한계를 화면에 적는다. 2026-08-23 정정: 여기 있던 "서브에이전트의 내부 턴은
            // 한 줄도 남지 않는다(0건)"는 사실이 아니었다. 스캔이 subagents/ 하위 폴더로
            // 내려가지 않았을 뿐이고, 기록은 계속 디스크에 있었다. 남은 한계만 적는다.
            var n=document.getElementById('orNote'); if(!n) return;
            var teams=(t.teams||0), tm=(t.teamsWithMates||0);
            n.innerHTML='<div class="note"><div class="t">이 화면이 재는 것과 재지 못하는 것</div>'
              +'<b>핸드오프의 내부 기록은 잽니다.</b> 받은 쪽 트랜스크립트 '+(t.innerFiles||0)+'개에서 '
              +'내부 턴 '+(t.innerTurns||0)+'회, 내부 도구 호출 '+(t.innerTools||0)+'회, 내부 벽시계 '
              +(t.innerHours||0)+'시간을 읽었습니다. 위임 '+(t.hops||0)+'건 중 '+(t.joined||0)+'건('
              +(t.joinPct||0)+'%)이 자기 트랜스크립트와 이어졌고, 그중 '+(t.nested||0)+'건은 에이전트가 '
              +'다시 에이전트를 부른 중첩 위임입니다.<br>'
              +'<b>여전히 재지 못하는 것</b>은 그 내부 도구 호출 중 몇 번이 "앞 홉이 이미 알던 것을 '
              +'다시 캔 것"인지의 판정입니다. 두 홉이 같은 파일을 봤는지는 셀 수 있지만, 앞 홉이 그 내용을 '
              +'지시문에 실어 줄 수 있었는지는 판단이라 계측이 아닙니다. 두 홉이 아티팩트를 같이 썼는지도 '
              +'트랜스크립트에 구조화된 형태로 남지 않아 재지 못합니다.<br>'
              +'<b>백그라운드로 띄운 위임</b>은 이제 셈에 들어갑니다 — 부모의 결과 줄은 "띄웠다"는 '
              +'영수증일 뿐이지만, 받은 쪽 트랜스크립트의 첫 줄과 마지막 줄이 실제 시작과 끝입니다.'
              +(teams>0?('<br><b>팀 '+teams+'개</b> 중 팀원이 리드 말고 더 있는 팀은 '+tm+'개입니다.'):'')
              +'</div>';
          }

          function verdictHtml(v){
            if(!v) return '';
            var cat=v.cat||'', cls=(cat==='끊긴 홉')?'dead':(cat==='진입점'?'entry':
              (cat==='종료 조건'||cat==='측정 불가'?'term':(cat==='파트'?'part':'none')));
            return '<div class="verd"><span class="vcat '+cls+'">병목 · '+esc(cat)+'</span>'
              +'<span>'+esc(v.text||'')+'</span></div>';
          }

          function routeRow(r){
            // 한 홉의 상태색: 끊김(빨강) > 결과 없음/미실행(회색) > 백그라운드(보라) > 정상(초록)
            var cls=r.dead>0?'dead':(r.done>0?'':(r.async>0?'async':'idle'));
            var share=r.share||0;
            var nums=[];
            nums.push('<b>'+(r.runs||0)+'</b>회');
            if(r.done>0) nums.push(r.done+' 완료');
            if(r.async>0) nums.push('<span title="백그라운드 실행 — 소요시간을 잴 수 없습니다">'+r.async+' 비동기</span>');
            if(r.dead>0) nums.push('<span class="bad">'+r.dead+' 끊김</span>');
            if(r.open>0) nums.push('<span class="bad">'+r.open+' 결과없음</span>');
            if(r.sumSec>0) nums.push(dur(r.sumSec)+' ('+share+'%)');
            nums.push(fmtRel(r.lastTs));
            // 출처 칩은 서버가 정한 문구를 그대로 쓴다 — 화면이 "정의됨" 같은 말을 스스로
            // 지어내면, 실제로는 정의 파일을 못 찾은 파트에 없는 근거를 붙이게 된다.
            var scope=r.scope||'';
            return '<div class="rt">'
              +'<span class="dot '+cls+'"></span>'
              +'<span class="ag" title="'+esc(r.sample||'')+'">'+esc(r.agent)+'</span>'
              +(scope?('<span class="sc '+(r.defined?'':'no')+'">'+esc(scope)+'</span>'):'')
              +'<span class="bar"><i class="'+(r.dead>0?'dead':'')+'" style="width:'+(r.dead>0?100:share)+'%"></i></span>'
              +'<span class="nums">'+nums.join(' · ')+'</span>'
              +'</div>';
          }

          function projCard(p){
            var wrap=document.createElement('div'); wrap.className='proj';
            var routes=(p.routes||[]);
            var head='<div class="phd">'
              +'<span class="caret">▸</span>'
              +'<span class="nm">'+esc(p.name)+'</span>'
              +(p.gone?'<span class="badge out" title="'+esc(p.path)+'">지금은 없는 폴더</span>'
                       :(p.known?'':'<span class="badge out">저장소 밖</span>'))
              +'<span class="badge">파트 '+(p.parts||0)+'</span>'
              +'<span class="badge">라우트 '+routes.length+'</span>'
              +'<span class="badge">위임 '+(p.runs||0)+'회</span>'
              +((p.dead||0)>0?'<span class="badge" style="background:#2a1416;border-color:#4a1f22;color:#f85149">끊김 '+p.dead+'</span>':'')
              +'<span class="path" title="'+esc(p.path)+'">'+esc(p.path)+'</span>'
              +'</div>';

            var body='';
            if(routes.length){ body+=routes.map(routeRow).join(''); }
            else {
              // 빈 상태는 감추지 않는다 — 파트만 있고 라우트가 없는 것이 가장 흔한 실패다.
              body+='<div class="rt"><span class="mini">이 프로젝트에서 실행된 라우트가 없습니다 — 파트는 '
                +(p.parts||0)+'개 정의되어 있습니다</span></div>';
            }

            var det='<div class="body">';
            if((p.unused||[]).length){
              det+='<div class="sec"><div class="lb">한 번도 호출되지 않은 파트</div><div class="chips">'
                +p.unused.map(function(u){ return '<span class="chip2 no">'+esc(u)+'</span>'; }).join('')
                +'</div></div>';
            }
            var ws=(p.workers||[]);
            if(ws.length){
              det+='<div class="sec"><div class="lb">예약 워커 — 사람 없이 라우트를 시작하는 유일한 부품</div><div class="chips">'
                +ws.map(function(w){
                  return '<span class="chip2 '+(w.loaded?'ok':'dead')+'" title="'+esc(w.path)+'">'
                    +esc(w.label)+' · '+(w.loaded?('등록됨'+(w.pid>0?(' (실행 중 pid '+w.pid+')'):'')):'launchd 에 없음')+'</span>';
                }).join('')+'</div></div>';
            }
            var ts=(p.teams||[]);
            if(ts.length){
              det+='<div class="sec"><div class="lb">팀 — 하나의 작업 목록을 나눠 갖는 팀원들</div><div class="chips">'
                +ts.map(function(t){
                  var solo=(t.members||0)<=1 && (t.tasks||0)===0;
                  return '<span class="chip2 '+(solo?'no':'ok')+'">'+esc(t.name)+' · 팀원 '+(t.members||0)
                    +'명 · 작업 '+(t.tasks||0)+'건'+(solo?' (리드만 있고 작업 목록이 비어 있음)':'')+'</span>';
                }).join('')+'</div></div>';
            }
            if((p.partNames||[]).length){
              det+='<div class="sec"><div class="lb">이 저장소에 정의된 파트</div><div class="chips">'
                +p.partNames.map(function(n){
                  var used=(p.unused||[]).indexOf(n)<0;
                  return '<span class="chip2'+(used?' ok':'')+'">'+esc(n)+'</span>'; }).join('')
                +'</div></div>';
            }
            det+='</div>';

            var open=!!OPEN[p.path];
            wrap.innerHTML=head+verdictHtml(p.verdict)+body
              +'<div class="det" style="display:'+(open?'block':'none')+'">'+det+'</div>';
            var hd=wrap.querySelector('.phd'), dt=wrap.querySelector('.det'), cr=wrap.querySelector('.caret');
            if(open&&cr) cr.textContent='▾';
            hd.onclick=function(){
              var will=dt.style.display==='none';
              dt.style.display=will?'block':'none';
              cr.textContent=will?'▾':'▸';
              OPEN[p.path]=will;
            };
            return wrap;
          }

          window.orRender=function(){
            var box=document.getElementById('orList'); if(!box||!D) return;
            band(D.bottleneck);
            waits(D.openWaits);
            trend(D.history);
            var ft=document.getElementById('lpFoldTitle');
            if(ft){ var tt=D.totals||{};
              ft.textContent='프로젝트별 라우트 '+(tt.projects||0)+'곳 (끊김 '+(tt.dead||0)
                +' · 한 번도 안 쓴 파트 '+(tt.unused||0)+')'; }
            summary(D.totals);
            var qi=document.getElementById('orQ'); var q=((qi&&qi.value)||'').trim().toLowerCase();
            var ran=document.getElementById('orRan'); var onlyRan=!!(ran&&ran.checked);
            var bad=document.getElementById('orBad'); var onlyBad=!!(bad&&bad.checked);
            var list=(D.projects||[]).filter(function(p){
              if(onlyRan && !(p.runs>0)) return false;
              if(onlyBad){
                var v=(p.verdict&&p.verdict.cat)||'';
                if(v!=='끊긴 홉' && v!=='진입점' && v!=='종료 조건') return false;
              }
              if(!q) return true;
              var hay=(p.name||'')+' '+(p.path||'')+' '+((p.partNames||[]).join(' '))
                +' '+((p.routes||[]).map(function(r){ return r.agent; }).join(' '));
              return hay.toLowerCase().indexOf(q)>=0;
            });
            box.innerHTML='';
            if(!list.length){
              box.innerHTML='<div class="empty">'+((D.projects||[]).length
                ? '조건에 맞는 프로젝트가 없습니다'
                : '루프 흔적을 찾지 못했습니다 — 위임(Task) 기록, 프로젝트 에이전트 정의, 예약 워커 중 하나라도 있으면 여기 나타납니다')+'</div>';
            } else {
              list.forEach(function(p){ box.appendChild(projCard(p)); });
            }

            // 스킬 하네스는 프로젝트를 가로지르는 라우트다 — 프로젝트 카드 아래에 따로 세운다.
            var h=(D.harness||[]);
            if(h.length && !q){
              var sec=document.createElement('div'); sec.className='proj';
              sec.innerHTML='<div class="phd" style="cursor:default"><span class="nm">스킬 하네스</span>'
                +'<span class="badge">'+h.length+'개</span>'
                +'<span class="mini" style="margin-left:6px">에이전트를 결정적으로 돌리고 원장에 채점을 남기는 라우트 — 프로젝트를 가로지른다</span></div>'
                +h.map(function(x){
                  var ran=(x.runs||0)>0;
                  return '<div class="rt"><span class="dot '+(ran?'':'idle')+'"></span>'
                    +'<span class="ag">'+esc(x.skill)+'</span>'
                    +'<span class="sc">파트 '+(x.agents||0)+'</span>'
                    +'<span class="bar"><i style="width:'+(ran?100:0)+'%"></i></span>'
                    +'<span class="nums">'+(ran?('<b>'+x.runs+'</b>회 · '+fmtRel(x.lastTs))
                      :'<span class="bad">원장에 실행 기록이 없습니다</span>')+'</span></div>';
                }).join('');
              box.appendChild(sec);
            }

            var f=document.getElementById('orFoot');
            if(f) f.innerHTML='라우트는 ~/.claude/projects 의 세션 트랜스크립트에 남은 Task 위임 기록에서 재구성합니다 · '
              +'파트 목록은 에이전트 인벤토리(전역·스킬 하네스·프로젝트)와 같은 출처입니다 · '
              +'예약 워커 등록 여부는 launchd 가 진실입니다<br>측정 정의는 docs/loop-engineering.md 에 적혀 있습니다'
              +(D.scannedAt?(' · 훑은 시각 '+esc(tdisp(D.scannedAt,19))):'');
          };

          // 프로젝트 카드는 기본 접힘. 코드를 지운 것이 아니라 자리를 옮긴 것뿐이다.
          (function(){
            var hd=document.getElementById('lpFoldHd');
            if(!hd) return;
            hd.onclick=function(){
              var bd=document.getElementById('lpFoldBd'), cr=document.getElementById('lpCaret');
              var will=bd.style.display==='none';
              bd.style.display=will?'block':'none';
              if(cr) cr.textContent=will?'▾':'▸';
            };
          })();

          function initialLoad(){ var v=2; try{v=parseInt(localStorage.getItem('cm-loop-version')||'2',10);}catch(e){} lpVersion(v===1?1:2); if(v===1)orLoad(); }
          if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', initialLoad);
          else initialLoad();
        })();
        </script>
        </body></html>
        """#
    }
}
