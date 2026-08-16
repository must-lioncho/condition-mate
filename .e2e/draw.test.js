// E2E for the 드로우 plugin (screen-drawing overlay, Sources/Draw), bound to the REAL
// sources. Asserts:
//   1) package wiring: a standalone Draw target exists and ConditionMate depends on it
//   2) engine contract: layout-independent keycodes (left ⌥=58 draw, fn=63 wipe —
//      wipe moved off left ⌃ because it collides with the screenshot chords) polled via
//      CGEventSource.keyState — no event tap / no Accessibility permission — and the
//      overlay window is click-through on every Space
//   3) plugin registration: "draw" is a toggle builtin, installed out of the box, and
//      pluginsJSON carries the drawOn sub-switch state
//   4) app wiring: syncPluginWorkers gates the overlay on installed AND drawEnabled
//      (registering the draw-overlay worker), POST /api/draw/enabled persists + resyncs,
//      POST /api/draw/clear wipes programmatically
//   5) dashboard card: the installed draw card renders the draw on/off sub-switch wired
//      to setDrawOn → POST /api/draw/enabled (and hides it when uninstalled)
const fs = require('fs');
const ROOT = __dirname + '/..';
const PKG = fs.readFileSync(ROOT + '/Package.swift', 'utf8');
const CTRL = fs.readFileSync(ROOT + '/Sources/Draw/DrawOverlayController.swift', 'utf8');
const WIN = fs.readFileSync(ROOT + '/Sources/Draw/DrawOverlayWindow.swift', 'utf8');
const CANVAS = fs.readFileSync(ROOT + '/Sources/Draw/DrawCanvasView.swift', 'utf8');
const EDITOR = fs.readFileSync(ROOT + '/Sources/Draw/DrawTextEditorWindow.swift', 'utf8');
const PS = fs.readFileSync(ROOT + '/Sources/ConditionMate/Core/PluginStore.swift', 'utf8');
const SET = fs.readFileSync(ROOT + '/Sources/ConditionMate/Core/Settings.swift', 'utf8');
const AD = fs.readFileSync(ROOT + '/Sources/ConditionMate/AppDelegate.swift', 'utf8');
const DC = fs.readFileSync(ROOT + '/Sources/ConditionMate/Dashboard/DashboardContent.swift', 'utf8');

function fn(src, name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0;
  for (let k = src.indexOf('{', start); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// 1) package wiring
check('Draw target exists', /\.target\(\s*name: "Draw",\s*path: "Sources\/Draw"/.test(PKG), true);
check('app depends on Draw', /dependencies: \["WebCLI", "GUI", "Draw"\]/.test(PKG), true);

// 2) engine contract — left-side keys, permissionless polling, click-through overlay
check('left ⌥ keycode 58', CTRL.includes('leftOptionKey: CGKeyCode = 58'), true);
check('fn keycode 63 (wipe)', CTRL.includes('fnKey: CGKeyCode = 63'), true);
check('polls keyState (no event tap)',
      CTRL.includes('CGEventSource.keyState(.combinedSessionState'), true);
check('no Accessibility-needing monitor',
      /addGlobalMonitorForEvents|CGEvent\.tapCreate/.test(CTRL + WIN), false);
check('wipe fires on fn down edge only',
      CTRL.includes('if fnDown && !prevFnDown { clear() }'), true);
check('overlay is click-through', WIN.includes('ignoresMouseEvents = true'), true);
check('overlay follows all Spaces', WIN.includes('.canJoinAllSpaces'), true);
check('overlay never takes key', WIN.includes('override var canBecomeKey: Bool { false }'), true);

// 2b) text mode — triple left-⌘ writes 30pt text; only the editor window takes key
check('left ⌘ keycode 55', CTRL.includes('leftCommandKey: CGKeyCode = 55'), true);
check('tap window 0.4s', CTRL.includes('cmdTapWindow: TimeInterval = 0.4'), true);
check('three taps required', CTRL.includes('cmdTapsRequired = 3'), true);
check('text size defaults to 30pt', CTRL.includes('textFontSize: CGFloat = 30'), true);
check('triple-tap toggles the editor',
      /commandTapCount >= Self\.cmdTapsRequired[\s\S]*?toggleTextEditor\(at: NSEvent\.mouseLocation\)/.test(CTRL), true);
check('a long gap resets the tap chain', CTRL.includes('commandTapCount = 1'), true);
check('commit stamps text on the canvas',
      CTRL.includes('canvas.addText(text, at: local, size: textFontSize)'), true);
check('wipe also discards an open editor', /public func clear\(\) \{\s*\n\s*textEditor\?\.cancelNow\(\)/.test(CTRL), true);
check('editor IS a key window', EDITOR.includes('override var canBecomeKey: Bool { true }'), true);
check('⏎ commits / Esc cancels',
      EDITOR.includes('insertNewline(_:)) { finish(commitText: true)')
      && EDITOR.includes('cancelOperation(_:)) { finish(commitText: false)'), true);
check('focus loss commits typed text', EDITOR.includes('func windowDidResignKey') , true);
check('previous app gets focus back', CTRL.includes('prev.activate()'), true);
check('canvas wipes texts too', /func clearAll\(\) \{\s*\n\s*strokes = \[\]\s*\n\s*texts = \[\]/.test(CANVAS), true);
check('texts render at their stamped size', CANVAS.includes('.font: NSFont.systemFont(ofSize: t.size'), true);

// 3) plugin registration
check('draw builtin is a toggle plugin',
      /Plugin\(id: "draw",[\s\S]*?kind: \.toggle/.test(PS), true);
check('draw installed out of the box',
      /defaultInstalled: Set<String> = \["condition-mate", "draw"\]/.test(PS), true);
check('pluginsJSON carries drawOn',
      PS.includes('"drawOn\\":\\(Settings.shared.drawEnabled)'), true);
check('drawEnabled defaults ON', /K\.drawEnabled: true/.test(SET), true);

// 4) app wiring
const sync = AD.slice(AD.indexOf('func syncPluginWorkers()'), AD.indexOf('// MARK: - Heartbeat'));
check('overlay gated on installed AND drawEnabled',
      sync.includes('pluginStore.isConnected("draw") && Settings.shared.drawEnabled'), true);
check('draw-overlay worker registered under draw',
      /register\(id: "draw-overlay",[\s\S]*?owner: "draw"\)/.test(sync), true);
check('gate closed → poller stopped', /r\.unregister\(id: "draw-overlay"\)\s*\n\s*drawOverlay\.stop\(\)/.test(sync), true);
check('/api/draw/enabled persists + resyncs',
      /case "\/api\/draw\/enabled":[\s\S]*?Settings\.shared\.drawEnabled = [\s\S]*?syncPluginWorkers\(\)/.test(AD), true);
check('/api/draw/clear wipes', /case "\/api\/draw\/clear":[\s\S]*?drawOverlay\.clear\(\)/.test(AD), true);

// 5) dashboard card — run the real renderPlugins over stub plugins
function renderWith(plugin) {
  let html = '';
  const host = { set innerHTML(v) { html = v; }, get innerHTML() { return html; } };
  const body = fn(DC, 'renderPlugins') + '; renderPlugins(); return host.innerHTML;';
  return new Function('$', '_plugins', 'esc', 'renderProjectActivity', 'host', body)(
    () => host, [plugin], s => String(s), () => '', host);
}
const drawCard = p => ({ id: 'draw', name: '드로우', desc: 'd', hint: 'h', detail: '설치됨',
                         kind: 'toggle', status: 'valid', installed: true, drawOn: true, ...p });
const on = renderWith(drawCard({}));
check('installed card has draw on/off switch', on.includes('setDrawOn(this.checked)'), true);
check('switch reflects drawOn=true', on.includes("checked onchange=\"setDrawOn"), true);
const off = renderWith(drawCard({ drawOn: false }));
check('switch reflects drawOn=false', off.includes("checked onchange=\"setDrawOn"), false);
const un = renderWith(drawCard({ installed: false, status: 'disconnected', detail: '미설치' }));
check('uninstalled card hides the switch', un.includes('setDrawOn'), false);
check('uninstalled card offers 설치', un.includes("installPlugin('draw')"), true);
check('setDrawOn posts /api/draw/enabled',
      fn(DC, 'setDrawOn').includes("post('/api/draw/enabled',{on:!!on})"), true);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
