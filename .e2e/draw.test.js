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
//   5) dashboard card: the draw plugin card renders the draw on/off sub-switch wired
//      to cmPlDraw → POST /api/draw/enabled
//
// 2026-08-29 — 5절은 DashboardContent.renderPlugins / setDrawOn 을 보고 있었다. 그 둘은
// 사라진 게 아니라 SessionRail.plBodyHtml / window.cmPlDraw 로 이사하며 이름이 바뀌었다.
// 구현의 이사는 계약의 이사가 아니므로, 기능 이름을 단 이 파일이 계속 그 계약을 지킨다
// (integrations.test.js 는 "목록에 이름이 뜬다" 만 보고 스위치도 POST 도 안 본다).
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
// 목록은 자란다(현재 WebCLI/GUI/Draw/Slack/Jira/Integrations). 정확 일치를 요구하면
// 무관한 타깃이 하나 붙을 때마다 이 시험이 진다 — 지켜야 할 계약은 "Draw 가 들어 있다" 다.
const CMDEPS = (PKG.match(/name: "ConditionMate",\s*dependencies: \[([^\]]*)\]/) || ['', ''])[1];
check('app depends on Draw', /"Draw"/.test(CMDEPS), true);

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
// 여기도 포함 검사 — 기본 설치 목록에 camera-guard·slack-translate 가 뒤이어 붙었다.
const DEFINST = (PS.match(/defaultInstalled: Set<String> = \[([^\]]*)\]/) || ['', ''])[1];
check('draw installed out of the box', /"draw"/.test(DEFINST), true);
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

// 5) 대시보드 카드 — 실제 소스(SessionRail.swift)의 plBodyHtml / cmPlDraw 를 그대로 돌린다.
const SR = fs.readFileSync(ROOT + '/Sources/ConditionMate/Dashboard/SessionRail.swift', 'utf8');

// window.<name>=function(...){...} 한 덩어리를 중괄호 짝을 맞춰 꺼낸다.
function winFn(src, name) {
  const start = src.indexOf('window.' + name + '=function');
  if (start < 0) throw new Error('no window.' + name);
  let depth = 0;
  for (let k = src.indexOf('{', start); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

// 카드 본문을 진짜 소스로 그린다. 이 절의 관심사는 드로우 스위치뿐이라 나머지 헬퍼는 스텁.
// (스텁을 빼면 plBodyHtml 이 ReferenceError 로 죽어 "스위치가 없다" 처럼 보인다.)
function bodyHtml(p) {
  const body = fn(SR, 'plBodyHtml') + '\nreturn plBodyHtml(p);';
  return new Function('p', 'esc2', 'escAttr', 'plActivityHtml', 'intgCapsHtml', 'intgCredsHtml', body)(
    p, s => String(s == null ? '' : s), s => String(s == null ? '' : s), () => '', () => '', () => '');
}
const drawPlugin = p => ({ id: 'draw', name: '드로우', desc: 'd', hint: 'h', detail: '설치됨',
                           kind: 'toggle', status: 'valid', installed: true, drawOn: true, ...p });

const on = bodyHtml(drawPlugin({}));
check('draw card renders the on/off checkbox',
      /<input type="checkbox" [^>]*onchange="cmPlDraw\(this\.checked\)">/.test(on), true);
check('checked follows drawOn=true', /<input type="checkbox" checked/.test(on), true);
const off = bodyHtml(drawPlugin({ drawOn: false }));
check('checked absent when drawOn=false', /<input type="checkbox" checked/.test(off), false);
check('the switch itself survives drawOn=false', off.includes('cmPlDraw(this.checked)'), true);
// 카드 헤더 전체가 접기 토글이다 — 전파를 막지 않으면 스위치를 누르는 순간 카드가 접힌다.
check('toggling the switch does not collapse the card',
      on.includes('onclick="event.stopPropagation()" onchange="cmPlDraw'), true);
check('other plugin cards carry no draw switch',
      bodyHtml(drawPlugin({ id: 'condition-mate' })).includes('cmPlDraw'), false);

// cmPlDraw → POST /api/draw/enabled {on:bool} (plPost 가 fetch POST + 새로고침을 한다)
function callDraw(v) {
  const posts = [];
  new Function('window', 'plPost',
    winFn(SR, 'cmPlDraw') + '\nwindow.cmPlDraw(' + JSON.stringify(v) + ');')(
    {}, (url, body) => posts.push([url, body]));
  return posts;
}
check('cmPlDraw(true) posts /api/draw/enabled {on:true}',
      callDraw(true), [['/api/draw/enabled', { on: true }]]);
check('cmPlDraw(false) posts {on:false}',
      callDraw(false), [['/api/draw/enabled', { on: false }]]);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
