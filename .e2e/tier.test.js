// E2E for context-aware tier smoothing (carry-forward), bound to the REAL source.
// Extracts withCarryForward / timelineSegments / timeBuckets from BGMPlayerContent.swift
// (오늘 활동 분석이 대시보드에서 컨디션 관리 페이지로 이동하며 함수들도 같이 이주)
// and asserts the user's neighbor-agreement rules on screenshot-derived inputs.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/BGMPlayerContent.swift', 'utf8');
function slice(from, to) { const a = SRC.indexOf(from); const b = SRC.indexOf(to, a); if (a < 0 || b < 0) throw new Error('extract ' + from); return SRC.slice(a, b); }
// BGMPlayerContent 배치: TENMIN→withCarryForward→timelineSegments 가 연속이라 한 슬라이스로
// 끊는다 (rowHtml 이후는 DOM/window 를 만져 eval 불가).
eval(slice('const TENMIN', 'function rowHtml') + '\n'
   + slice('function timeBuckets', 'function drawTiers'));
function catLabel(seg) { if (seg.meeting) return '미팅'; if (seg.tier === '적극') return '집중'; if (seg.tier === '중간') return '책상'; return '휴식'; }

const T0 = 14 * 3600;
function mk(minStart, count, app, site, tier, active, meeting) {
  const o = []; for (let i = 0; i < count; i++) o.push({ t: T0 + (minStart + i) * 60, app, site: site || '-', profile: '기본', track: '-', tier, active, key: active ? 5 : 0, mouse: active ? 5 : 0, meeting: !!meeting }); return o;
}
const segLabels = ss => timelineSegments(withCarryForward(ss)).map(g => `${g.app}:${catLabel(g)}:${g.mins}`);
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
let pass = 0, fail = 0;
function check(name, got, want) { const ok = eq(got, want); console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got)); if (!ok) console.log('       want=' + JSON.stringify(want)); ok ? pass++ : fail++; }

// 1) photo1: System Settings(휴식) between Cursor 집중 / Cursor 집중 -> absorbed into 집중, no 휴식 row
check('photo1 absorbs into 집중', segLabels([
  ...mk(37, 4, 'Cursor', '-', '적극', 1),
  ...mk(41, 1, 'System Settings', '-', '소극', 1),
  ...mk(42, 3, 'Cursor', '-', '적극', 1),
]), ['Cursor:집중:8']);

// 2) photo2: loginwindow + Chrome(google) (휴식) between Slack/Kakao 책상 -> all 책상, no 휴식
check('photo2 absorbs into 책상', segLabels([
  ...mk(16, 3, 'Slack', '-', '중간', 1),
  ...mk(19, 1, 'loginwindow', '-', '소극', 1),
  ...mk(20, 1, 'Slack', 'admin.msq.market', '중간', 1),
  ...mk(21, 3, 'Google Chrome', 'google.com', '소극', 1),
  ...mk(24, 2, 'KakaoTalk', '-', '중간', 1),
]).every(l => l.endsWith && l.includes('책상') ? true : false) ? ['ok'] : ['has-non-책상'], ['ok']);

// 3) neighbor mismatch: 집중 | rest | 책상 -> gap becomes 책상 (never invents focus)
check('mismatch -> 책상', segLabels([
  ...mk(0, 2, 'Cursor', '-', '적극', 1),
  ...mk(2, 1, 'System Settings', '-', '소극', 1),
  ...mk(3, 2, 'Slack', '-', '중간', 1),
]), ['Cursor:집중:2', 'Slack:책상:3']);

// 4) gap > 10min: NOT bridged, stays 휴식
check('gap>10min stays 휴식', segLabels([
  ...mk(0, 1, 'Cursor', '-', '적극', 1),
  ...mk(1, 12, 'System Settings', '-', '소극', 1),
  ...mk(13, 1, 'Cursor', '-', '적극', 1),
]), ['Cursor:집중:1', 'System Settings:휴식:12', 'Cursor:집중:1']);

// 5) trailing rest with no work after: NOT absorbed (no right neighbor)
check('trailing rest not absorbed', segLabels([
  ...mk(0, 2, 'Cursor', '-', '적극', 1),
  ...mk(2, 2, 'System Settings', '-', '소극', 1),
]), ['Cursor:집중:2', 'System Settings:휴식:2']);

// 6) focus | desk | focus : the middle is genuine desk work (active), stays 책상 (only rest is absorbed)
check('genuine desk between focus stays 책상', segLabels([
  ...mk(0, 2, 'Cursor', '-', '적극', 1),
  ...mk(2, 1, 'Slack', '-', '중간', 1),
  ...mk(3, 2, 'Cursor', '-', '적극', 1),
]), ['Cursor:집중:2', 'Slack:책상:1', 'Cursor:집중:2']);

// 7) bucket value check on photo1: focus minutes should be 8 (all absorbed)
const b1 = timeBuckets(withCarryForward([...mk(37, 4, 'Cursor', '-', '적극', 1), ...mk(41, 1, 'System Settings', '-', '소극', 1), ...mk(42, 3, 'Cursor', '-', '적극', 1)]));
check('photo1 focus bucket = 8', [b1.focus, b1.desk], [8, 8]);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
