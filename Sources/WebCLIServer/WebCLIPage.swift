import Foundation
import WebCLI

// The single HTML page this standalone server serves at GET /. It reproduces the
// in-app "goal CLI 세션" view — left rail, CLI/GUI/DETAIL header toggle, 실행 중 status,
// and the embedded xterm terminal — but wired to THIS server's /api/cli/* routes and
// the shared CMWebCLI engine (WebCLITerminal.script()). GUI/DETAIL are app-only and
// render disabled here; only CLI is live in the standalone build.
enum WebCLIPage {
    static func html(label: String, cwd: String) -> String {
        let engine = WebCLITerminal.script()
        // Server-injected values, escaped for a JS string literal context.
        let cwdJS = jsEscape(cwd)
        let labelHTML = htmlEscape(label)
        let cwdHTML = htmlEscape(cwd)
        return #"""
        <!doctype html>
        <html lang="ko">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <title>\#(labelHTML) · webcli</title>
        <style>
          :root{
            --bg:#0b0e13; --panel:#0c0f15; --rail:#0a0d12; --line:rgba(140,150,170,.12);
            --ink:#e6e9f0; --muted:#8a93a3; --faint:#5a6273;
            --accent:#3b82f6; --live:#34d3a6;
          }
          *{box-sizing:border-box}
          html,body{height:100%;margin:0}
          /* 100dvh (not height:100%) gives body a DEFINITE height even when the browser
             doesn't propagate html{height:100%}; without it the flex column has no height
             to distribute and #panel (a flex-grow item whose only child is absolutely
             positioned) collapses to ~0, sizing the terminal — and the PTY — to 2 columns. */
          body{height:100dvh;background:var(--bg);color:var(--ink);
            font:14px/1.5 -apple-system,BlinkMacSystemFont,'Apple SD Gothic Neo','Segoe UI',sans-serif;
            display:flex;flex-direction:column;overflow:hidden}
          /* thin top accent bar, like the app's loading strip */
          #topbar{height:3px;flex:0 0 auto;
            background:linear-gradient(90deg,var(--accent),#6366f1 55%,transparent)}
          #shell{flex:1 1 auto;display:flex;min-height:0}
          /* left rail */
          #rail{flex:0 0 74px;background:var(--rail);border-right:1px solid var(--line);
            display:flex;flex-direction:column;align-items:center;gap:4px;padding-top:20px}
          .railitem{display:flex;flex-direction:column;align-items:center;gap:5px;
            width:58px;padding:10px 0;border-radius:10px;color:var(--muted);
            font-size:11px;user-select:none;cursor:default}
          .railitem svg{width:22px;height:22px;stroke:currentColor;fill:none;stroke-width:1.6}
          /* main column */
          #main{flex:1 1 auto;display:flex;flex-direction:column;min-width:0;min-height:0;
            padding:22px 26px 18px}
          #head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px}
          #title{font-size:22px;font-weight:700;letter-spacing:-.2px}
          #sub{margin-top:6px;color:var(--muted);font-size:13px;max-width:60ch}
          #sub a{color:var(--accent);text-decoration:none}
          /* CLI/GUI/DETAIL segmented toggle */
          #seg{flex:0 0 auto;display:inline-flex;background:#11151d;border:1px solid var(--line);
            border-radius:9px;padding:3px}
          #seg button{appearance:none;border:0;background:transparent;color:var(--muted);
            font:600 12px/1 -apple-system,sans-serif;letter-spacing:.4px;
            padding:7px 14px;border-radius:6px;cursor:default}
          #seg button.on{background:var(--accent);color:#fff;box-shadow:0 1px 2px rgba(0,0,0,.3)}
          #seg button.off{opacity:.55}
          #status{margin-top:16px;display:flex;align-items:center;gap:8px;
            font-size:13px;font-weight:600;color:var(--live)}
          #dot{width:8px;height:8px;border-radius:50%;background:var(--live);
            box-shadow:0 0 0 0 rgba(52,211,166,.6);animation:pulse 2s infinite}
          #status.dead{color:var(--muted)} #status.dead #dot{background:var(--muted);animation:none;box-shadow:none}
          #status.connecting{color:var(--muted)} #status.connecting #dot{background:var(--accent);animation:none}
          @keyframes pulse{0%{box-shadow:0 0 0 0 rgba(52,211,166,.5)}
            70%{box-shadow:0 0 0 7px rgba(52,211,166,0)}100%{box-shadow:0 0 0 0 rgba(52,211,166,0)}}
          /* terminal panel */
          #panel{flex:1 1 auto;margin-top:14px;min-height:0;
            background:var(--panel);border:1px solid var(--line);border-radius:12px;
            padding:14px 12px 12px;position:relative;overflow:hidden}
          #term{position:absolute;inset:12px}
          .xterm .xterm-viewport::-webkit-scrollbar{width:9px}
          .xterm .xterm-viewport::-webkit-scrollbar-thumb{background:rgba(140,150,170,.18);border-radius:5px}
        </style>
        </head>
        <body>
          <div id="topbar"></div>
          <div id="shell">
            <nav id="rail" aria-hidden="true">
              <div class="railitem">
                <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>
                크론
              </div>
              <div class="railitem">
                <svg viewBox="0 0 24 24"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
                작업
              </div>
            </nav>
            <section id="main">
              <div id="head">
                <div>
                  <div id="title">\#(labelHTML)</div>
                  <div id="sub">인터랙티브 claude 가 이 터미널에서 진행됩니다 — 작업 폴더는
                    <a href="#" onclick="return false" title="\#(cwdHTML)">\#(cwdHTML)</a></div>
                </div>
                <div id="seg" role="tablist">
                  <button class="on" role="tab" aria-selected="true">CLI</button>
                  <button class="off" role="tab" title="메신저형 세션 뷰는 앱 대시보드에서만 제공됩니다" disabled>GUI</button>
                  <button class="off" role="tab" title="목표 상세 페이지는 앱 대시보드에서만 제공됩니다" disabled>DETAIL</button>
                </div>
              </div>
              <div id="status" class="connecting"><span id="dot"></span><span id="stateTxt">연결 중…</span></div>
              <div id="panel"><div id="term"></div></div>
            </section>
          </div>

          \#(engine)

          <script>
            (function(){
              const CWD = "\#(cwdJS)";
              const statusEl = document.getElementById('status');
              const txtEl = document.getElementById('stateTxt');
              // Engine states: cls 'live' | 'dead' | '' (connecting/failed). Map to the
              // status pill without a hard red/green traffic light — live=teal, else muted.
              function onState(txt, cls){
                txtEl.textContent = txt;
                statusEl.className = (cls === 'live') ? '' : (cls === 'dead') ? 'dead' : 'connecting';
              }
              const ctl = CMWebCLI.create({
                termEl: document.getElementById('term'),
                onState: onState,
                ioPath: '/api/cli/io',
                resizePath: '/api/cli/resize'
              });
              const panelEl = document.getElementById('panel');

              // The engine's connect() creates the xterm and immediately fits it, sizing the
              // PTY from that first measurement. On a cold browser load the flex panel can
              // still be collapsed at that instant (~0px), so the first fit yields cols=2 and
              // the PTY starts 2 columns wide — every prompt wraps. Gate connect() until the
              // panel actually has a real size so the very first fit is correct.
              function whenSized(cb){
                let tries = 0;
                // setInterval (not requestAnimationFrame): rAF is throttled to ~0 in a
                // backgrounded/offscreen tab, which would stall the gate indefinitely.
                const iv = setInterval(() => {
                  if ((panelEl.clientWidth > 200 && panelEl.clientHeight > 100) || tries++ > 40) {
                    clearInterval(iv); cb();        // ~2s cap — connect anyway
                  }
                }, 50);
              }

              // Any later panel size change re-fits and resizes the PTY (SIGWINCH), so a
              // window resize / devtools open / font swap keeps the terminal correct.
              let rt;
              const refit = () => { clearTimeout(rt); rt = setTimeout(() => ctl.fit(), 60); };
              if (window.ResizeObserver) new ResizeObserver(refit).observe(panelEl);
              window.addEventListener('resize', refit);

              whenSized(() => {
                ctl.connect((cols, rows) => fetch('/api/cli/start', {
                  method:'POST', headers:{'Content-Type':'application/json'},
                  body: JSON.stringify({ cwd: CWD, cols: cols, rows: rows })
                })).then(() => {
                  // Settle loop: a couple of extra fits over the first second in case the
                  // font swap or a late layout tick shifts the cell size after connect.
                  requestAnimationFrame(() => ctl.fit());
                  setTimeout(() => ctl.fit(), 250);
                  setTimeout(() => ctl.fit(), 700);
                  ctl.focus();
                });
              });
              // Refocus the terminal when the page/tab regains focus.
              window.addEventListener('focus', () => ctl.focus());
              document.getElementById('panel').addEventListener('mousedown', () => setTimeout(() => ctl.focus(), 0));
            })();
          </script>
        </body>
        </html>
        """#
    }

    // Escape for embedding inside a double-quoted JS string literal.
    private static func jsEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "<": out += "\\x3c"   // avoid closing an enclosing </script>
            default: out.append(c)
            }
        }
        return out
    }

    // Escape for embedding inside HTML text / attribute content.
    private static func htmlEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }
}
