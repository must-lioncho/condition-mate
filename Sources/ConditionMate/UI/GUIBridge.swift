import AppKit
import GUI

// Wiring between the reusable GUI module (Sources/GUI) and this app. The GUI module knows
// nothing about ConditionMate — this file injects everything app-specific:
//   - the two JS payloads the app window needs (view-trace heartbeat, screen-state probe)
//   - the log / trace / screen-catalog sinks (AppLog, ViewTrace, ScreenCatalog)
//   - the menu's state snapshot (MenuState) and its click targets (MenuControllerActions)

// MARK: - App window construction

extension AppDelegate {

    // Builds the app window with all Condition-Mate-specific behavior injected. Defaults in
    // AppWindowController.Configuration (paths, titles, zen geometry, autosave name) already
    // match this app; only the injected JS and the native sinks are wired here.
    func makeAppWindow() -> AppWindowController {
        var cfg = AppWindowController.Configuration()
        cfg.documentStartScripts = [AppWindowScripts.viewTraceHeartbeat]
        cfg.screenStateScript = AppWindowScripts.screenState
        let w = AppWindowController(configuration: cfg)
        w.onLog = { AppLog.log($0) }
        w.onTrace = { ViewTrace.shared.native($0, page: $1, detail: $2) }
        w.screenCatalog = ScreenCatalog.shared
        return w
    }

    // Snapshot of everything the status-bar menu shows, built fresh each time the menu opens.
    func menuState() -> MenuState {
        var m = MenuState()
        m.isWorking = isWorking
        m.isMuted = session.isMuted
        m.liveStatus = liveStatus
        m.sessionSeconds = sessionSeconds
        m.totalSeconds = store.data.totalSeconds
        m.todaySeconds = store.todaySeconds

        m.conditionActive = director.isActive
        m.strategyLabel = director.activeProfileLabel
        m.phaseLabel = director.phase.rawValue
        m.targetBPM = director.targetBPM
        m.releaseRemainingSeconds = director.releaseRemaining
        m.planSlotLabel = bgmPlan.slot()?.label
        m.activeAppLabel = activeAppLabel
        m.currentTrackTitle = audio.currentTitle
        m.musicEnabled = Settings.shared.musicEnabled
        m.trackCount = library.tracks.count
        m.bpmRange = library.bpmRange

        m.bgmWindowEnabled = Settings.shared.bgmWindowEnabled
        m.drawInstalled = pluginStore.isConnected("draw")
        m.drawEnabled = Settings.shared.drawEnabled
        m.cameraGuardInstalled = pluginStore.isConnected("camera-guard")
        m.cameraGuardOn = Settings.shared.cameraGuardOn
        m.menuBarModeIsSports = menuBarMode == .sports
        m.debugCaptureOn = DebugCapture.shared.isOn
        m.debugCaptureLabel = DebugCapture.shared.shortLabel()
        m.windowOpen = appWindowIsOpen
        m.windowModeIsBGM = appWindowMode == .bgm

        m.accessibilityTrusted = activity.isTrusted
        m.loginItemAvailable = LoginItem.isBundled
        m.loginItemEnabled = LoginItem.isEnabled
        return m
    }
}

// The menu's click targets — every method already exists on AppDelegate (they predate the
// GUI-module split); this conformance just exposes them to the menu.
extension AppDelegate: MenuControllerActions {}

// ScreenCatalog's observe/record signatures were designed for the window's capture loop and
// match the GUI protocol exactly.
extension ScreenCatalog: AppWindowScreenCatalogObserver {}

// MARK: - Injected JS (app-specific DOM/endpoint knowledge lives HERE, not in the GUI module)

enum AppWindowScripts {

    // Probes the visible webview for its screen-state identity (screen catalog). Everything the
    // key needs is read in ONE evaluateJavaScript round-trip; returns a compact JSON string or
    // null (non-http page / not ready). Query VALUES are dropped from the key on purpose —
    // /goal?n=12 and /goal?n=34 are the same SCREEN — and flags capture the layout-changing UI
    // states the path can't see (zen fold, 수확 오브, running dial, open modal, collapsed rail).
    static let screenState = """
    (function(){try{
      if (location.protocol !== 'http:' || document.readyState !== 'complete') return null;
      var q=[]; try{ new URLSearchParams(location.search).forEach(function(v,k){ q.push(k); }); }catch(e){}
      q.sort();
      var view='';
      try{ if (window.cmView) view=String(window.cmView);
           else if (typeof _view==='string') view=_view;
           else if (typeof mode==='string') view=mode; }catch(e){}
      var flags=[]; var b=document.body?document.body.classList:null;
      if(b){ if(b.contains('cm-zen')) flags.push('zen');
             if(b.contains('cmrail-collapsed')) flags.push('railoff'); }
      var ch=document.getElementById('cmChallenge');
      if(ch){ var c=ch.classList;
        if(c.contains('reward')) flags.push('reward');
        else if(c.contains('counting')) flags.push('counting');
        else if(c.contains('done')) flags.push('done');
        else if(c.contains('run')) flags.push('run'); }
      // Modal/overlay detection is geometric (pages here name their modals ad hoc — planModal,
      // scLightbox, …): any visible fixed/absolute direct child of <body> covering most of the
      // viewport counts. The rail is excluded explicitly — at the 242px zen width the fixed
      // 240px rail covers nearly the whole viewport and would false-flag every zen state.
      var kids=document.body?document.body.children:[];
      for(var i=0;i<kids.length;i++){ var el=kids[i];
        if(!el.getBoundingClientRect) continue;
        if(el.id==='cmRail'||String(el.className||'').indexOf('cmrail')>=0) continue;
        var st=getComputedStyle(el);
        if((st.position!=='fixed' && st.position!=='absolute') || st.display==='none'
           || st.visibility==='hidden') continue;
        var r=el.getBoundingClientRect();
        if(r.width>=window.innerWidth*0.7 && r.height>=window.innerHeight*0.7){ flags.push('modal'); break; } }
      return JSON.stringify({p:location.pathname, q:q.join(','), v:view,
                             f:flags.join(','), w:window.innerWidth|0, h:window.innerHeight|0});
    }catch(e){ return null }})()
    """

    // 0.5s view-trace heartbeat, injected at documentStart into EVERY page the app window's
    // webviews load, so route changes (/goal-add, /equipment, …) are traced without touching
    // each page's HTML. Its "boot" event is also the earliest possible in-page timestamp, which
    // is what makes the launch white-gap measurable.
    //
    // Samples WHAT THE USER SEES every 500ms and posts it to POST /api/debug/view-trace
    // (5s batches for ticks; boot/firstPaint/domReady/load/jsError immediately). The active
    // view is read from the page's own globals — `_view` (dashboard tab) or `mode` (condition
    // page sub-tab) — or an explicit `window.cmView` if a page ever sets one. Guarded to
    // http: pages only so the about:blank/empty loads used during close/quit stay silent.
    // Endpoint lives under /api/debug/ on purpose: dashboard POSTs there are exempt from
    // the action log, so the heartbeat can never flood actions.jsonl.
    //
    // window.cmVT.ev(note) — the page-side stamp for IN-PAGE user moments the heartbeat
    // can't see on its own (chat panel open, image attached to a composer, in-page CLI
    // session opened, GUI↔CLI view switches). Pages call it guarded
    // (`window.cmVT&&cmVT.ev(…)`) so they stay inert outside the app window's webviews.
    static let viewTraceHeartbeat = """
    (function(){
    try{
      if (window.__cmVT || location.protocol !== 'http:') return; window.__cmVT = 1;
      var buf = [], painted = false, t0 = Date.now();
      // 계측 자신의 왕복은 계측되면 안 된다 — 래핑 전의 원본 fetch를 붙잡아 둔다.
      var rawFetch = (window.fetch && window.fetch.bind) ? window.fetch.bind(window) : null;
      if (!rawFetch) rawFetch = function(){ return Promise.reject(new Error('no fetch')); };
      var cbuf = [], cap = false;   // 디버그 모드(버그 수집) 버퍼 + 게이트
      function view(){
        try{ if (window.cmView) return String(window.cmView); }catch(e){}
        try{ if (typeof _view === 'string') return _view; }catch(e){}
        try{ if (typeof mode === 'string') return mode; }catch(e){}
        return '';
      }
      function samp(k, note){
        var s = { t: Date.now(), k: k, page: location.pathname + location.search,
                  view: view(), ready: document.readyState, painted: painted,
                  hidden: !!document.hidden,
                  focus: !!(document.hasFocus && document.hasFocus()),
                  w: window.innerWidth||0, h: window.innerHeight||0 };
        if (note) s.note = String(note).slice(0, 280);
        return s;
      }
      function flush(sync){
        if (!buf.length) return;
        var payload = JSON.stringify({events: buf.splice(0, buf.length)});
        try{
          if (sync && navigator.sendBeacon) { navigator.sendBeacon('/api/debug/view-trace', payload); return; }
          // 응답의 cap 플래그가 디버그 모드(버그 수집)의 on/off 신호다 — 별도 폴링 없이
          // 이미 5초마다 오가는 이 왕복에 얹어 상태를 따라간다(전환은 최대 5초 지연).
          rawFetch('/api/debug/view-trace', {method:'POST',
                headers:{'Content-Type':'application/json'}, body: payload,
                keepalive: true})
            .then(function(r){ return r.json(); })
            .then(function(j){ setCap(!!(j && j.cap)); })
            .catch(function(){});
        }catch(e){}
      }
      function ev(note){ buf.push(samp('ev', note)); flush(); }

      // ---- 디버그 모드(버그 수집) 계층 -------------------------------------------------
      // 리스너는 항상 붙어 있지만, cap 이 false 면 함수 진입 즉시 반환한다(비용 ≈ 0).
      // cap 은 view-trace 응답의 cap 플래그로만 켜지고 꺼진다 — 페이지가 스스로 켤 수 없다.
      function desc(el){
        try{
          if (!el || !el.tagName) return '';
          var s = el.tagName.toLowerCase();
          if (el.id) s += '#' + el.id;
          var c = (typeof el.className === 'string') ? el.className.trim().split(/\\s+/).slice(0,2).join('.') : '';
          if (c) s += '.' + c;
          if (el.name) s += '[' + el.name + ']';
          var label = (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'))) || '';
          if (!label && el.tagName === 'BUTTON') label = (el.textContent||'').trim();
          if (label) s += ' «' + String(label).slice(0, 40) + '»';
          return s.slice(0, 160);
        }catch(e){ return ''; }
      }
      function isPassword(el){
        try{ return !!(el && el.tagName === 'INPUT' && String(el.type||'').toLowerCase() === 'password'); }
        catch(e){ return false; }
      }
      function cpush(o){
        if (!cap) return;
        try{
          o.t = Date.now(); o.page = location.pathname; o.view = view();
          cbuf.push(o);
          if (cbuf.length > 600) cbuf.splice(0, cbuf.length - 600);   // 폭주 시 오래된 것부터 버린다
        }catch(e){}
      }
      function cflush(sync){
        if (!cbuf.length) return;
        var payload = JSON.stringify({events: cbuf.splice(0, cbuf.length)});
        try{
          if (sync && navigator.sendBeacon) { navigator.sendBeacon('/api/debug/capture', payload); return; }
          rawFetch('/api/debug/capture', {method:'POST',
                headers:{'Content-Type':'application/json'}, body: payload,
                keepalive: true}).catch(function(){});
        }catch(e){}
      }
      function setCap(v){
        if (v === cap) return;
        cap = v;
        if (cap) cpush({k:'capture', note:'page armed'});
        else cflush();   // 끄는 신호를 받으면 남은 버퍼를 마저 보낸 뒤 멎는다
      }
      // 키 입력 — 어떤 키였는지까지. 비밀번호 필드에서는 글자를 남기지 않는다.
      document.addEventListener('keydown', function(e){
        if (!cap) return;
        var pw = isPassword(e.target);
        var mod = (e.metaKey?'⌘':'') + (e.ctrlKey?'⌃':'') + (e.altKey?'⌥':'') + (e.shiftKey?'⇧':'');
        cpush({k:'key', key: pw ? '•' : String(e.key||''), code: String(e.code||''),
               mod: mod, tgt: desc(e.target), ime: !!e.isComposing, pw: pw});
      }, true);
      document.addEventListener('compositionend', function(e){
        if (!cap) return;
        cpush({k:'ime', tgt: desc(e.target), len: String((e.data)||'').length});
      }, true);
      // 클릭 — 무엇을 눌렀는지(선택자 + 라벨) + 좌표.
      document.addEventListener('click', function(e){
        if (!cap) return;
        cpush({k:'click', tgt: desc(e.target), x: e.clientX|0, y: e.clientY|0,
               text: String((e.target && e.target.textContent) || '').trim().slice(0, 60)});
      }, true);
      document.addEventListener('focusin', function(e){
        if (!cap) return; cpush({k:'focus', tgt: desc(e.target)});
      }, true);
      // 입력 — 내용은 절대 남기지 않는다(길이만). 메모 본문이 로그로 새지 않게 하는 기존 원칙과 같다.
      document.addEventListener('input', function(e){
        if (!cap) return;
        var v = ''; try{ v = String((e.target && e.target.value) || ''); }catch(x){}
        cpush({k:'input', tgt: desc(e.target), len: v.length});
      }, true);
      // 콘솔 — 페이지가 스스로 남긴 진단. 항상 래핑하되 cap 일 때만 보낸다.
      try{
        ['error','warn','log'].forEach(function(lvl){
          var orig = console[lvl];
          if (typeof orig !== 'function') return;
          console[lvl] = function(){
            try{ if (cap) cpush({k:'console', lvl: lvl,
              msg: Array.prototype.map.call(arguments, function(a){
                try{ return (typeof a === 'string') ? a : JSON.stringify(a); }catch(x){ return String(a); }
              }).join(' ').slice(0, 300)}); }catch(x){}
            return orig.apply(console, arguments);
          };
        });
      }catch(e){}
      // 네트워크 — 페이지가 부른 fetch/XHR의 결과와 소요시간. 계측 자신의 왕복은 제외한다.
      function skipURL(u){ return u.indexOf('/api/debug/capture') >= 0 || u.indexOf('/api/debug/view-trace') >= 0; }
      // 같은 요청이 5초 안에 반복되면 접는다(skipped = 접힌 횟수). 대시보드는 /live.json 을
      // 250ms마다 폴링하므로, 접지 않으면 키·클릭이 폴링 줄에 파묻힌다. 네이티브 http 훅과
      // 같은 규칙(DebugCapture.http).
      var netSeen = {};
      function cnet(m, url, st, ms, msg){
        var key = m + ' ' + url + ' ' + st, now = Date.now(), e = netSeen[key];
        if (e && now - e.at < 5000) { e.n++; return; }
        var skipped = e ? e.n : 0;
        netSeen[key] = {at: now, n: 0};
        var o = {k:'net', m: String(m), url: String(url).slice(0,200), st: st|0, ms: ms|0};
        if (skipped > 0) o.skipped = skipped;
        if (msg) o.msg = String(msg).slice(0,120);
        cpush(o);
      }
      try{
        window.fetch = function(input, init){
          var url = ''; try{ url = String((input && input.url) || input || ''); }catch(x){}
          var m = (init && init.method) || (input && input.method) || 'GET';
          var st = Date.now();
          var p = rawFetch(input, init);
          if (!cap || skipURL(url)) return p;
          return p.then(function(r){
            cnet(m, url, (r && r.status)|0, Date.now()-st, '');
            return r;
          }, function(err){
            cnet(m, url, -1, Date.now()-st, String(err && err.message || err));
            throw err;
          });
        };
        var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(m, u){
          try{ this.__cmM = String(m||''); this.__cmU = String(u||''); }catch(x){}
          return XO.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function(){
          try{
            if (cap && !skipURL(this.__cmU || '')) {
              var self = this, st = Date.now();
              this.addEventListener('loadend', function(){
                cnet(self.__cmM||'GET', String(self.__cmU||''), self.status|0, Date.now()-st, '');
              });
            }
          }catch(x){}
          return XS.apply(this, arguments);
        };
      }catch(e){}
      setInterval(function(){ cflush(); }, 2000);
      window.addEventListener('pagehide', function(){ cflush(true); });
      // ---------------------------------------------------------------------------------

      window.cmVT = { ev: ev };   // page-side stamp for in-page user moments
      buf.push(samp('ev', 'boot'));   // earliest in-page moment (documentStart)
      try{ requestAnimationFrame(function(){ requestAnimationFrame(function(){
        painted = true; ev('firstPaint +' + (Date.now()-t0) + 'ms'); }); }); }catch(e){}
      document.addEventListener('DOMContentLoaded', function(){ ev('domReady +' + (Date.now()-t0) + 'ms'); });
      window.addEventListener('load', function(){ ev('load +' + (Date.now()-t0) + 'ms'); });
      document.addEventListener('visibilitychange', function(){
        ev(document.hidden ? 'hide' : 'show'); if (document.hidden) flush(true); });
      window.addEventListener('pagehide', function(){ ev('pagehide'); flush(true); });
      window.addEventListener('error', function(e){
        ev('jsError: ' + (e.message||'?') + ' @' + (e.filename||'') + ':' + (e.lineno||0)); });
      window.addEventListener('unhandledrejection', function(e){
        ev('rejection: ' + String(e.reason).slice(0, 180)); });
      window.addEventListener('hashchange', function(){ ev('hashchange'); });
      setInterval(function(){ buf.push(samp('tick')); if (buf.length >= 10) flush(); }, 500);
      flush();
    }catch(e){}
    })();
    """
}
