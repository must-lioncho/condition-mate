// Reproduce the activity-log tier classification using the REAL functions from
// DashboardContent.swift, fed sample sequences matching the user's screenshots.
// Goal: see whether the existing carry-forward already absorbs the sandwiched
// rest minutes, or whether there is a real gap.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/DashboardContent.swift', 'utf8');

function slice(from, toExclusive) {
  const a = SRC.indexOf(from); const b = SRC.indexOf(toExclusive, a);
  if (a < 0 || b < 0) throw new Error('extract failed: ' + from);
  return SRC.slice(a, b);
}
// Pull the real functions out of the source.
const jsTimeline = slice('function timelineSegments', 'function renderTimeline');
const jsCarry = slice('const TENMIN', 'function timeBuckets');
const jsBuckets = slice('function timeBuckets', 'function drawTiers');
const jsBadge = slice('function tierColor', '\n// 책상/집중'); // tierColor + (categoryBadge after marker)
const jsCat = slice('// 책상/집중/휴식/미팅 구분 뱃지', '\n}\n', ); // categoryBadge body
// categoryBadge returns HTML; we only need its label. Re-extract cleanly:
const catFn = SRC.slice(SRC.indexOf('function categoryBadge'), SRC.indexOf('\n}', SRC.indexOf('function categoryBadge')) + 2);

eval(jsTimeline + '\n' + jsCarry + '\n' + jsBuckets + '\n' + catFn);

function catLabel(seg) {
  // mirror categoryBadge label logic without HTML
  if (seg.meeting) return '미팅';
  if (seg.tier === '적극') return '집중';
  if (seg.tier === '중간') return '책상';
  return '휴식';
}

// helper to build minute samples
const T0 = 14 * 3600; // 14:00 in seconds-of-day (absolute base irrelevant, diffs matter)
function mk(minStart, count, app, site, tier, active) {
  const out = [];
  for (let i = 0; i < count; i++) out.push({ t: T0 + (minStart + i) * 60, app, site: site || '-', profile: '기본', track: '-', tier, active, key: active ? 5 : 0, mouse: active ? 5 : 0, meeting: false });
  return out;
}
const hhmm = s => { const m = Math.floor(s / 60); return String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0'); };

function run(name, samples) {
  console.log('\n=== ' + name + ' ===');
  const ss = withCarryForward(samples);
  const segs = timelineSegments(ss);
  segs.forEach(g => console.log(`  ${hhmm(g.startT)}  ${g.mins}분  ${g.app.padEnd(16)} ${catLabel(g)}`));
  const b = timeBuckets(ss);
  console.log(`  buckets: total=${b.total} desk=${b.desk} focus=${b.focus}`);
}

// Photo 1: Cursor focus | System Settings rest(1m) | Cursor focus | Slack desk | Chrome focus
run('photo1 (System Settings sandwiched by 집중)', [
  ...mk(37, 4, 'Cursor', '-', '적극', 1),
  ...mk(41, 1, 'System Settings', '-', '소극', 1),
  ...mk(42, 3, 'Cursor', '-', '적극', 1),
  ...mk(45, 3, 'Slack', '-', '중간', 1),
  ...mk(48, 1, 'Google Chrome', '127.0.0.1', '적극', 1),
]);

// Photo 2: Slack desk | loginwindow rest | Slack desk | Chrome google rest(3m) | Kakao desk | Slack desk
run('photo2 (loginwindow & Chrome google sandwiched by 책상)', [
  ...mk(16, 3, 'Slack', '-', '중간', 1),
  ...mk(19, 1, 'loginwindow', '-', '소극', 1),
  ...mk(20, 1, 'Slack', 'admin.msq.market', '중간', 1),
  ...mk(21, 3, 'Google Chrome', 'google.com', '소극', 1),
  ...mk(24, 2, 'KakaoTalk', '-', '중간', 1),
  ...mk(26, 3, 'Slack', '-', '중간', 1),
]);

// Edge: focus | rest | desk  (neighbors DISAGREE) — what tier does the gap get?
run('edge (rest between 집중 and 책상)', [
  ...mk(0, 2, 'Cursor', '-', '적극', 1),
  ...mk(2, 1, 'System Settings', '-', '소극', 1),
  ...mk(3, 2, 'Slack', '-', '중간', 1),
]);
