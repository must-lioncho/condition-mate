// E2E for the 리포트 CSV 내보내기 + 한 줄 고정 항목. Bound to REAL source: extracts the
// CSV builders from DashboardContent.swift and asserts header/row shape, quoting, and that
// newlines inside a goal text collapse (so one goal is always exactly one CSV row).
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/DashboardContent.swift', 'utf8');
function fn(name) {
  const start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0; for (let k = SRC.indexOf('{', start); k < SRC.length; k++) { if (SRC[k] === '{') depth++; else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); } }
  throw new Error('unbalanced ' + name);
}
// Stubs for the render-side helpers the CSV builder leans on.
function goalPasses() { return true; }
function reportPassesRange() { return true; }
function gnote(r, id) { return (r.notes && r.notes[id]) || ''; }
eval([fn('csvCell'), fn('csvHours'), fn('buildReportCsv'), fn('goalTag'),
      fn('statLabel'), fn('statLabel2'), fn('derivedStatus'), fn('goalKids'),
      fn('fmtDur'), fn('fmtDate')].join('\n'));
// fmtDate uses CMTimeFilter.parts; a minimal UTC stub is enough for shape assertions.
global.CMTimeFilter = { parts: (ms) => { const d = new Date(ms); return { mo: d.getUTCMonth() + 1, d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes() }; } };

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
const G = (o) => Object.assign({
  id: o.id, seq: o.seq || 1, text: '', parent: '', links: [], status: 'backlog',
  trackedSeconds: 0, startedAt: 0, waitingSince: 0, energy: 0, agents: [], tokens: 0, value: 0,
  evidence: [], sessionId: '', targetAt: 0, completedAt: 0, sprint: 0, released: false,
  releaseId: '', archived: false, priority: '', effort: '', mode: '', cwd: '', branch: '',
  model: '', images: [], tasks: []
}, o);

const top = G({ id: 'p1', seq: 2, text: 'Condition Mate', tasks: [{ id: 'task1', title: '큐 정리', status: 'DONE' }] });
const kid = G({
  id: 'c1', seq: 3, parent: 'p1', status: 'in_progress', trackedSeconds: 5400, tokens: 12,
  text: 'Slack 스레드 대응:\n여러 줄, 쉼표 "인용"까지 들어있는 긴 원문',
  evidence: [{ kind: 'link', title: '스레드', href: 'https://x/y' }]
});
const r = { goals: [top, kid], notes: { c1: '번역 포함' } };
const csv = buildReportCsv({ date: '2026-08-03' }, r, 1.5, 3.0);
const lines = csv.trim().split('\n');

check('header is the detailed column set', lines[0].startsWith('"구분","goal","제목","부모goal"') && lines[0].includes('"증거"'));
check('one row per 목표 + 부분과제 + 자식', lines.length === 4, lines.length + ' rows');
check('목표 row first', lines[1].startsWith('"목표","goal-02","Condition Mate"'));
check('부분과제 row carries owner goal', lines[2].startsWith('"부분과제","goal-02/task1","큐 정리","goal-02"'));
check('자식 row keeps parent context', lines[3].includes('"goal-02","Condition Mate"'));
check('newlines collapse — one goal stays one row', !lines[3].includes('\n') && lines[3].includes('Slack 스레드 대응: 여러 줄'));
check('quotes are doubled', lines[3].includes('""인용""'));
check('note column filled from review notes', lines[3].includes('"번역 포함"'));
check('tracked hours 2 decimals', lines[3].includes('"1.50","1:30:00"'));
check('evidence rendered with count', lines[3].includes('"1","🔗 스레드 https://x/y"'));

// 화면 쪽: 자식 항목은 .rli 한 줄 클래스 + title 전문을 달고 렌더된다.
const report = fn('renderReport');
check('li is one-line (.rli) with full-text title', /<li class="rli" title="/.test(report));
check('CSS pins report li to a single line', /#report li\.rli\{white-space:nowrap;overflow:hidden;text-overflow:ellipsis/.test(SRC));
check('CSV 다운로드 button wired', /onclick="downloadCsv\(this\)"/.test(SRC));

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
