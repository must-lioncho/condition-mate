import AppKit
import GUI

// Wiring between the reusable GUI module (Sources/GUI) and this app. The GUI module knows
// nothing about ConditionManager — this file injects everything app-specific:
//   - the two JS payloads the app window needs (view-trace heartbeat, screen-state probe)
//   - the log / trace / screen-catalog sinks (AppLog, ViewTrace, ScreenCatalog)
//   - the menu's state snapshot (MenuState) and its click targets (MenuControllerActions)

// MARK: - App window construction

extension AppDelegate {

    // Builds the app window with all Condition-Manager-specific behavior injected. Defaults in
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
          fetch('/api/debug/view-trace', {method:'POST',
                headers:{'Content-Type':'application/json'}, body: payload,
                keepalive: true}).catch(function(){});
        }catch(e){}
      }
      function ev(note){ buf.push(samp('ev', note)); flush(); }
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
