// Shared extractor for the 메모장 + 사이드바 3단계 harnesses: pulls the SHIPPING CSS/JS out
// of the Swift sources so neither the test (memostage.test.js) nor the visual stub server
// (memostub.js) can drift from what the app actually serves.
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

const RAIL_SRC = read('Sources/ConditionMate/Dashboard/SessionRail.swift');
const PAD_SRC = read('Sources/ConditionMate/Dashboard/MemoPad.swift');
const GOALADD_SRC = read('Sources/ConditionMate/Dashboard/GoalAddContent.swift');

function slice(src, from, to, what) {
  const a = src.indexOf(from), b = src.indexOf(to, a);
  if (a < 0 || b < 0) throw new Error('cannot extract ' + what + ' from source');
  return src.slice(a, b + to.length);
}

module.exports = {
  RAIL_SRC, PAD_SRC, GOALADD_SRC, slice,
  RAIL_CSS: slice(RAIL_SRC, '<style>', '</style>', 'rail CSS'),
  // The 3-stage machine only — the rest of the rail script talks to live endpoints.
  RAIL_JS: slice(RAIL_SRC, 'var CMRAIL_TIPS=',
    "if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', cmRailStageBoot); else cmRailStageBoot();",
    'rail stage machine'),
  PAD_CSS: slice(PAD_SRC, '<style>', '</style>', 'MemoPad CSS'),
  // 대시보드 대화 패널(2026-07-31 작업+대화 통합)의 레이아웃 CSS만.
  DASH_CHAT_CSS: slice(read('Sources/ConditionMate/Dashboard/DashboardContent.swift'),
    // 앵커는 폭 계산식이 아니라 선택자에 건다 — 기본 분할 비율은 계속 손보는 값이라
    // 리터럴을 앵커로 쓰면 CSS 를 만질 때마다 추출기가 깨진다.
    '.cmchat{ position:fixed', 'body.cmboard-off .wrap{ display:none !important }', 'dashboard chat CSS'),
  // 표시 타임존 모듈 — 앱에서는 레일이 실어 주는 것을, 스텁/테스트도 같은 소스에서 가져온다.
  TZ_JS: slice(read('Sources/ConditionMate/Dashboard/CMTimeFilter.swift'),
    'window.CMTimeFilter = window.CMTimeFilter ||', '})();', 'CMTimeFilter module'),
  PAD_JS: slice(PAD_SRC, 'window.CMMemo = window.CMMemo ||', '})();', 'MemoPad module'),
  // Whole module (CSS + markup + script) as the app embeds it.
  PAD_HTML: slice(PAD_SRC, '<style>', '</script>', 'MemoPad module HTML')
};
