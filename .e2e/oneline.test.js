// E2E: 모든 목표 뷰(목록·그룹·일정·테이블·토큰·리포트)의 제목은 한 줄로 고정된다.
// 긴 Slack 원문 하나가 행 높이를 수백 px로 늘려 표를 못 읽게 만들던 회귀를 잡는다.
// CSS 규칙과 title(hover 전문) 부착을 실제 소스에서 검사한다.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/DashboardContent.swift', 'utf8');
let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
const has = (re) => re.test(SRC);
const ONE = 'white-space:nowrap;overflow:hidden;text-overflow:ellipsis';

// --- CSS: 한 줄 고정 ---
check('.gt (목록·그룹·일정·토큰 공통 제목) is one line', SRC.includes(ONE) && /\.gt\{[^}]*\n?[^}]*white-space:nowrap;overflow:hidden;text-overflow:ellipsis\}/.test(SRC));
check('.gt can shrink inside flex rows (min-width:0)', /\.gt\{[\s\S]{0,200}?min-width:0/.test(SRC));
check('목록 .goal .g shrinks (min-width:0)', /\.goal \.g\{flex:1;min-width:0/.test(SRC));
check('그룹 .gchild .gt shrinks', /\.gchild \.gt\{flex:1;min-width:0\}/.test(SRC));
check('일정 .schrow .st shrinks + clips', /\.schrow \.st\{flex:1;min-width:0;overflow:hidden\}/.test(SRC));
check('테이블 이름 열 one line (max-width:0 trick)', new RegExp('\\.gtbl \\.nm\\{max-width:0;width:55%;' + ONE + '\\}').test(SRC));
check('리포트 li one line', new RegExp('#report li\\.rli\\{' + ONE).test(SRC));
check('리포트 h3 one line', new RegExp('#report h3\\{' + ONE + '\\}').test(SRC));
check('루프 .bgoal .t stays one line (기존 규칙 유지)', /\.bgoal \.t\{flex:1;min-width:60px;white-space:nowrap/.test(SRC));

// --- 전문은 hover(title)로 볼 수 있어야 한다 ---
const editable = SRC.match(/title="'\+esc\(g\.text\)\+' — 더블클릭하여 제목 편집"/g) || [];
check('편집 가능한 제목 4곳 모두 hover 전문 노출', editable.length === 4, editable.length + '곳');
check('테이블 이름 셀 hover 전문', has(/<td class="nm" title="'\+esc\(g\.text\)\+'"/));
check('토큰 뷰 제목 hover 전문', has(/<span class="st"><span class="gt" title="'\+esc\(g\.text\)\+'"/));
check('부분과제 행 hover 전문', has(/<span class="gt" title="'\+esc\(t\.title\|\|t\.folder\)\+'"/));

// --- 잘린 만큼 전문을 볼 다른 경로가 있어야 한다(CSV) ---
check('CSV 다운로드 경로 존재', has(/function buildReportCsv\(/) && has(/onclick="downloadCsv\(this\)"/));

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
