#!/usr/bin/env python3
# Render the Condition Manager docs hub: a GitBook-style single HTML file (SPEC.html) with
# top tabs. The SPEC tab renders SPEC.md (per-page QA spec); the "제품 소울" tab renders SOUL.md
# (why the product exists). Each doc stays the Markdown source of truth; run this after editing
# either one to regenerate the human view. Craft principles live in craft-soul.md (not rendered
# here, referenced from SOUL.md).
#   python3 docs/specs/script/render-spec.py
#
# Layout (dev repo): this script lives in docs/specs/script/ . SPEC.md, SPEC.html and img/ live in
# docs/specs/ ; SOUL.md (the product-soul tab source) lives one level up in docs/ .
import re, html, os, base64, datetime
try:
    from zoneinfo import ZoneInfo
    KST = ZoneInfo("Asia/Seoul")
except Exception:
    KST = datetime.timezone(datetime.timedelta(hours=9))

HERE  = os.path.dirname(os.path.abspath(__file__))   # docs/specs/script
SPECS = os.path.dirname(HERE)                          # docs/specs
DOCS  = os.path.dirname(SPECS)                         # docs
SPEC_SRC = os.path.join(SPECS, "SPEC.md")
SOUL_SRC = os.path.join(DOCS,  "SOUL.md")
OUT      = os.path.join(SPECS, "SPEC.html")
IMG_DIR  = os.path.join(SPECS, "img")

# Page-id -> screenshot filename (base name only, under img/). Each SPEC page section (## PN. ...)
# looks up its "PN" token to decide whether to embed a real screenshot right under the heading.
PAGE_IMAGES = {
    "P1": "menu-bar.png",      # native NSMenu — screenshot via screencapture if permitted, else placeholder
    "P3": "bgm-act.png",       # BGM mode / 액티비티 sub-tab — WKWebView snapshot
    "P4": "bgm-dbg.png",       # BGM mode / 디버그 sub-tab — WKWebView snapshot
    "P5": "dashboard.png",     # 대시보드 mode — WKWebView snapshot
}

def b64_img(basename):
    path = os.path.join(IMG_DIR, basename)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        data = f.read()
    return "data:image/png;base64," + base64.b64encode(data).decode("ascii")

def slug(s):
    s = re.sub(r"[`*]", "", s)
    s = re.sub(r"[^0-9A-Za-z가-힣]+", "-", s).strip("-").lower()
    return s or "s"

def inline(s):
    s = html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`(.+?)`", r"<code>\1</code>", s)
    return s

LABEL = re.compile(r"^(EN|KO|Verify|History|Note|RETIRED[^:]*):\s*(.*)$")

def flush_table(rows):
    if not rows: return ""
    cells = [ [c.strip() for c in r.strip().strip("|").split("|")] for r in rows ]
    # drop the |---| separator row if present
    cells = [c for c in cells if not all(re.fullmatch(r":?-{2,}:?", x or "-") for x in c)]
    if not cells: return ""
    head, *rest = cells
    out = ['<table><thead><tr>'] + [f"<th>{inline(c)}</th>" for c in head] + ['</tr></thead><tbody>']
    for r in rest:
        out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)

def render_item(block):
    # block = list of raw lines for one "- " bullet (header line + indented body)
    header_parts, paras, cur_cls, cur_buf = [], [], None, []
    def push():
        nonlocal cur_buf, cur_cls
        if cur_buf:
            cls = {"EN":"lang en","KO":"lang ko"}.get(cur_cls, "meta")
            lab = {"EN":"","KO":""}.get(cur_cls, f'<span class="tag">{cur_cls}</span> ' if cur_cls else "")
            paras.append(f'<p class="{cls}">{lab}{inline(" ".join(cur_buf))}</p>')
        cur_buf = []
    first = re.sub(r"^\s*-\s+", "", block[0])
    header_parts.append(first)
    in_body = False
    for ln in block[1:]:
        t = ln.strip()
        m = LABEL.match(t)
        if m:
            in_body = True; push()
            key = m.group(1); cur_cls = "EN" if key=="EN" else "KO" if key=="KO" else key
            cur_buf = [m.group(2)] if m.group(2) else []
        elif not in_body:
            header_parts.append(t)      # header wrapped across lines
        else:
            cur_buf.append(t)           # continuation of current label
    push()
    head = inline(" ".join(header_parts))
    return f'<div class="item"><div class="ihead">{head}</div>{"".join(paras)}</div>'

def render_doc(src_path, id_prefix=""):
    """Parse one Markdown doc into (title, nav, body_html). id_prefix namespaces heading ids/anchors
    so two docs can coexist in one page without slug collisions."""
    lines = open(src_path, encoding="utf-8").read().split("\n")
    title = "SPEC"
    nav = []          # (level, text, slug)
    body = []         # html chunks
    i, N = 0, len(lines)
    while i < N:
        ln = lines[i]
        if ln.startswith("# ") and not ln.startswith("## "):
            title = ln[2:].strip(); body.append(f'<h1>{inline(title)}</h1>'); i+=1; continue
        if ln.startswith("### "):
            t = ln[4:].strip(); sg = id_prefix+slug(t); nav.append((3,t,sg))
            body.append(f'<h3 id="{sg}">{inline(t)}</h3>'); i+=1; continue
        if ln.startswith("## "):
            t = ln[3:].strip(); sg = id_prefix+slug(t); nav.append((2,t,sg))
            body.append(f'<h2 id="{sg}">{inline(t)}</h2>')
            # Real per-page screenshot: pages titled "P1. ..." / "P3. ..." look up "PN" in PAGE_IMAGES.
            m_page = re.match(r"^(P\d+)\.", t)
            if m_page:
                pid = m_page.group(1); fname = PAGE_IMAGES.get(pid)
                if fname:
                    data_uri = b64_img(fname)
                    if data_uri:
                        body.append(f'<img class="shot" src="{data_uri}" alt="{html.escape(pid)} screenshot">')
                    else:
                        body.append(
                            f'<div class="shot placeholder">screenshot pending for {html.escape(pid)} '
                            f'({html.escape(fname)} not found) — native surface or capture blocked, see '
                            f'manager-qa report</div>')
            i+=1; continue
        if ln.strip()=="---" or ln.strip()=="":
            i+=1; continue
        if ln.lstrip().startswith("|"):
            rows=[]
            while i<N and lines[i].lstrip().startswith("|"): rows.append(lines[i]); i+=1
            body.append(flush_table(rows)); continue
        if ln.startswith("**Purpose"):
            m = re.match(r"\*\*Purpose[^*]*\*\*(.*?)(?:\*\*EN:\*\*(.*?))?(?:\*\*KO:\*\*(.*))?$", ln, re.S)
            intro = (m.group(1) or "").strip(); en=(m.group(2) or "").strip(); ko=(m.group(3) or "").strip()
            h = f'<div class="purpose"><span class="tag">Purpose · 목적</span> {inline(intro)}'
            if en: h += f'<span class="lang en"> {inline(en)}</span>'
            if ko: h += f'<span class="lang ko"> {inline(ko)}</span>'
            h += "</div>"; body.append(h); i+=1; continue
        if ln.lstrip().startswith("- "):
            indent = len(ln)-len(ln.lstrip())
            block=[ln]; i+=1
            while i<N:
                nx=lines[i]
                if nx.strip()=="":
                    if i+1<N and (lines[i+1].startswith("#") or lines[i+1].lstrip().startswith("- ") or lines[i+1].strip()=="---"):
                        break
                    i+=1; continue
                if nx.lstrip().startswith("- ") and (len(nx)-len(nx.lstrip()))<=indent: break
                if nx.startswith("#") or nx.strip()=="---" or nx.startswith("**Purpose"): break
                if nx.lstrip().startswith("|"): break
                block.append(nx); i+=1
            body.append(render_item(block)); continue
        # top-level EN:/KO:/Verify: line (outside a bullet) -> language-toggled / meta paragraph
        m = LABEL.match(ln.strip())
        if m:
            key=m.group(1); buf=[m.group(2)] if m.group(2) else []; i+=1
            while i<N and lines[i].strip() and not LABEL.match(lines[i].strip()) and not lines[i].startswith("#") and not lines[i].lstrip().startswith("- ") and lines[i].strip()!="---" and not lines[i].lstrip().startswith("|") and not lines[i].startswith("**Purpose"):
                buf.append(lines[i].strip()); i+=1
            cls={"EN":"lang en","KO":"lang ko"}.get(key,"meta")
            lab="" if key in ("EN","KO") else f'<span class="tag">{key}</span> '
            body.append(f'<p class="{cls}">{lab}{inline(" ".join(buf))}</p>'); continue
        # plain paragraph (e.g. Intent audit prose, section intro)
        para=[ln.strip()]; i+=1
        while i<N and lines[i].strip() and not lines[i].startswith("#") and not lines[i].lstrip().startswith("- ") and not lines[i].lstrip().startswith("|") and lines[i].strip()!="---" and not lines[i].startswith("**Purpose"):
            para.append(lines[i].strip()); i+=1
        body.append(f'<p class="para">{inline(" ".join(para))}</p>')
    return title, nav, "".join(body)

def build_sidebar(nav):
    sb=[]
    for lvl,t,sg in nav:
        cls = "s2" if lvl==2 else "s3"
        sb.append(f'<a class="{cls}" href="#{sg}">{html.escape(re.sub(chr(96),"",t))}</a>')
    return "\n".join(sb)

spec_title, spec_nav, spec_body = render_doc(SPEC_SRC)
soul_title, soul_nav, soul_body = render_doc(SOUL_SRC, id_prefix="soul-")
spec_sidebar = build_sidebar(spec_nav)
soul_sidebar = build_sidebar(soul_nav)
sync_stamp = datetime.datetime.now(KST).strftime("%Y-%m-%d %H:%M")

# --- extra CSS for the top tab bar (injected literally; single braces are fine here) ---
EXTRA_CSS = """
/* GitBook-style top tab bar (docs hub: Soul + Spec) */
.tabbar{position:fixed;top:52px;left:0;right:0;height:46px;background:rgba(13,16,23,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--line);display:flex;align-items:flex-end;gap:6px;padding:0 18px;z-index:19}
.tabbar .tab{appearance:none;background:none;border:none;color:var(--dim);font-weight:600;font-size:13.5px;padding:0 12px 11px;cursor:pointer;border-bottom:2px solid transparent;display:inline-flex;align-items:center;gap:7px;line-height:1}
.tabbar .tab:hover{color:var(--fg)}
.tabbar .tab.on{color:var(--fg);border-bottom-color:var(--acc)}
.tabbar .tab .dot{width:7px;height:7px;border-radius:50%;background:currentColor;opacity:.55}
.tabpanel{display:contents}
.tabpanel[hidden]{display:none}
"""

# --- tab-aware script (injected literally; scopes the scroll-highlight to the active panel) ---
SCRIPT = """<script>
(function(){
  var b=document.body, btns=[].slice.call(document.querySelectorAll('.langtoggle button'));
  function setLang(l){ b.dataset.lang=l; btns.forEach(function(x){x.classList.toggle('on',x.dataset.l===l);}); try{localStorage.setItem('spec-lang',l);}catch(e){} }
  btns.forEach(function(x){ x.onclick=function(){setLang(x.dataset.l);}; });
  setLang((function(){try{return localStorage.getItem('spec-lang')}catch(e){}})()||'ko');
  var tabs=[].slice.call(document.querySelectorAll('.tabbar .tab'));
  var panels={ soul:document.getElementById('tab-soul'), spec:document.getElementById('tab-spec') };
  var links=[], map={}, heads=[];
  function onScroll(){ var y=window.scrollY+80, cur=null; heads.forEach(function(h){ if(h.offsetTop<=y) cur=h.id; });
    links.forEach(function(a){a.classList.remove('on');}); if(cur&&map[cur]) map[cur].classList.add('on'); }
  function bindActive(t){ var p=panels[t]; if(!p) return;
    links=[].slice.call(p.querySelectorAll('.sidebar a'));
    map={}; links.forEach(function(a){ map[a.getAttribute('href').slice(1)]=a; });
    heads=[].slice.call(p.querySelectorAll('h2[id],h3[id]')); onScroll(); }
  function setTab(t){ if(!panels[t]) t='spec';
    tabs.forEach(function(x){ x.classList.toggle('on',x.dataset.tab===t); });
    Object.keys(panels).forEach(function(k){ if(panels[k]) panels[k].hidden=(k!==t); });
    try{localStorage.setItem('spec-tab',t);}catch(e){} bindActive(t); window.scrollTo(0,0); }
  tabs.forEach(function(x){ x.onclick=function(){setTab(x.dataset.tab);}; });
  window.addEventListener('scroll',onScroll,{passive:true});
  setTab((function(){try{return localStorage.getItem('spec-tab')}catch(e){}})()||'soul');
})();
</script>"""

HTMLDOC = f"""<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Condition Manager — Docs (Soul · Spec)</title>
<style>
:root{{--bg:#0d1017;--panel:#141925;--line:#232a3a;--fg:#e7ecf5;--dim:#93a0b5;--acc:#7c9bff;--acc2:#00d4c8;--code:#1b2230}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--fg);font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","Apple SD Gothic Neo","Noto Sans KR",sans-serif}}
.topbar{{position:fixed;top:0;left:0;right:0;height:52px;background:rgba(13,16,23,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px;padding:0 18px;z-index:20}}
.brand{{font-weight:700;font-size:14px;letter-spacing:.2px}}
.brand small{{color:var(--dim);font-weight:400;margin-left:8px}}
.langtoggle{{margin-left:auto;display:inline-flex;border:1px solid var(--line);border-radius:9px;overflow:hidden}}
.langtoggle button{{background:none;border:none;color:var(--dim);font-weight:700;font-size:12px;padding:7px 14px;cursor:pointer}}
.langtoggle button.on{{background:linear-gradient(145deg,var(--acc),#5a72e6);color:#fff}}
.layout{{display:flex;padding-top:98px}}
.sidebar{{position:fixed;top:98px;bottom:0;width:280px;overflow:auto;border-right:1px solid var(--line);background:var(--panel);padding:16px 10px 40px}}
.sidebar a{{display:block;text-decoration:none;color:var(--dim);border-radius:7px;padding:6px 12px;font-size:13.5px}}
.sidebar a:hover{{color:var(--fg);background:#1b2230}}
.sidebar a.on{{color:var(--fg);background:#1e2942;box-shadow:inset 2px 0 0 var(--acc)}}
.sidebar a.s2{{font-weight:600;margin-top:6px}}
.sidebar a.s3{{padding-left:26px;font-size:12.5px;color:#7c8aa3}}
.content{{margin-left:280px;max-width:900px;padding:26px 40px 120px}}
h1{{font-size:24px;margin:6px 0 18px}}
h2{{font-size:19px;margin:38px 0 10px;padding-top:10px;border-top:1px solid var(--line)}}
h3{{font-size:15px;margin:22px 0 8px;color:var(--acc2);text-transform:uppercase;letter-spacing:.6px}}
.purpose{{color:var(--dim);font-size:13.5px;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 14px;margin:8px 0 14px}}
.item{{border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:10px 0;background:linear-gradient(180deg,#141925,#111623)}}
.ihead{{font-weight:700;margin-bottom:6px}}
.item p{{margin:6px 0}}
p.lang{{margin:6px 0}}
.meta{{color:var(--dim);font-size:13px;border-left:2px solid var(--line);padding-left:10px}}
.tag{{display:inline-block;font-size:10.5px;font-weight:800;letter-spacing:.5px;color:var(--acc2);border:1px solid #2b5c57;background:rgba(0,212,200,.08);border-radius:5px;padding:0 6px;margin-right:6px;vertical-align:middle}}
.para{{color:var(--dim)}}
code{{background:var(--code);border:1px solid var(--line);border-radius:5px;padding:1px 5px;font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;color:#cdd7ea}}
strong{{color:var(--fg)}}
table{{border-collapse:collapse;width:100%;margin:10px 0;font-size:13px}}
th,td{{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top}}
th{{background:#1a2130;color:var(--fg)}}
td{{color:var(--dim)}}
.shot{{display:block;max-width:100%;height:auto;border:1px solid var(--line);border-radius:10px;margin:10px 0 16px;box-shadow:0 4px 18px rgba(0,0,0,.35)}}
.shot.placeholder{{display:flex;align-items:center;justify-content:center;min-height:120px;color:var(--dim);font-size:12.5px;font-style:italic;background:var(--code);text-align:center;padding:14px}}
.synctime{{color:var(--dim);font-size:11.5px;font-weight:400;margin-left:10px;white-space:nowrap}}
/* language toggle */
body[data-lang="en"] .lang.ko{{display:none}}
body[data-lang="ko"] .lang.en{{display:none}}
{EXTRA_CSS}
</style></head>
<body data-lang="ko">
<div class="topbar"><span class="brand">Condition Manager <small>Docs</small></span>
  <span class="synctime">Last synced: {sync_stamp} KST</span>
  <div class="langtoggle"><button data-l="en">EN</button><button data-l="ko">KO</button></div>
</div>
<div class="tabbar">
  <button class="tab" data-tab="soul"><span class="dot"></span><span class="lang ko">제품 소울</span><span class="lang en">Product Soul</span></button>
  <button class="tab" data-tab="spec"><span class="dot"></span><span class="lang ko">스펙 · per-page</span><span class="lang en">Spec · per-page</span></button>
</div>
<div class="layout">
<div class="tabpanel" id="tab-soul" hidden>
  <nav class="sidebar">{soul_sidebar}</nav>
  <main class="content">{soul_body}</main>
</div>
<div class="tabpanel" id="tab-spec">
  <nav class="sidebar">{spec_sidebar}</nav>
  <main class="content">{spec_body}</main>
</div>
</div>
{SCRIPT}
</body></html>"""

open(OUT,"w",encoding="utf-8").write(HTMLDOC)
print("wrote", OUT, f"({len(HTMLDOC)} bytes; spec {len(spec_nav)} nav, soul {len(soul_nav)} nav)")
