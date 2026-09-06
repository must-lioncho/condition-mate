// E2E for the 크론 페이지 '이 디바이스 등록' 탭, bound to the REAL source (AppDelegate.cronPage).
// Three things this tab has to get right, and they are what this asserts:
//   1. 상태 — 꺼짐(disable) vs 미로드(파일만 있고 launchd에 없음 = 죽어 있음) vs
//      오류(마지막 종료 코드 != 0) vs 동작 중/대기, in that precedence.
//   2. 사람 이름이 먼저 — reverse-DNS 라벨은 이름 아래 보조 정보로 내려간다.
//   3. 보기 필터 — 40개 프로젝트가 섞인 목록에서 "지금 도는 것만" / "이 프로젝트만"
//      을 골라낼 수 있어야 오케스트레이션 판단이 선다.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/AppDelegate.swift', 'utf8');
function slice(from, to) {
  const a = SRC.indexOf(from); const b = SRC.indexOf(to, a);
  if (a < 0 || b < 0) throw new Error('extract ' + from);
  return SRC.slice(a, b);
}
// Swift 의 """ 리터럴 안에서는 \\ 가 브라우저로 나갈 때 \ 한 글자가 된다.
// 이 블록의 유일한 이중 역슬래시는 tildify 의 정규식이므로 그대로 되돌린다.
const JS = slice('function fmtWhen(epoch){', 'function showTab(which){')
  .replace(/\\\\/g, '\\');

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got).slice(0, 200));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// ---- stubs (the page defines esc() above the extracted block) ----
const els = {};
function el(id) {
  if (!els[id]) els[id] = { id, innerHTML: '', textContent: '', value: '', style: {} };
  return els[id];
}
global.window = global;
global.document = { getElementById: id => el(id) };
global.esc = s => String(s == null ? '-' : s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
global.localStorage = { store: {}, getItem(k) { return k in this.store ? this.store[k] : null; },
                        setItem(k, v) { this.store[k] = v; } };
// setFilter() re-renders BOTH tables; the app-worker half lives above the slice.
global._workers = [];
global.renderWorkers = () => {};

eval(JS);

// 안내 줄은 '지금 보고 있는 탭'의 숫자만 쓴다. 이 파일은 디바이스 탭을 검사한다.
_tab='device';

// A launchd/crontab row as /device-cron.json emits it.
function job(over) {
  return Object.assign({
    id: 'com.x.job', source: 'launchd', name: 'job', label: 'com.x.job', project: 'proj-a',
    detail: '/bin/true', schedule: '매일 09:10', loaded: true, disabled: false,
    pid: -1, runs: 3, lastExit: 0, lastRunEpoch: 0, path: '/p.plist', hasLog: true
  }, over);
}
const rows = () => el('devicerows').innerHTML;
// 상태 판정 자체를 볼 때는 필터가 행을 지우면 안 되므로 전체 보기로 고정한다.
function showAll() { _filter.state = 'all'; _filter.proj = ''; }

// ---- 1) 상태 판정: the four shapes, in precedence order ----
showAll();
renderDevice([job({ disabled: true, loaded: false, lastExit: 9 })]);
check('꺼짐이 미로드·오류보다 앞선다', /꺼짐/.test(rows()) && !/미로드|오류/.test(rows()), true);

renderDevice([job({ loaded: false })]);
check('plist만 있고 로드 안 됨 → 미로드', /미로드/.test(rows()), true);
check('미로드 행은 붉게 표시', rows().includes('rgba(226,102,125,0.08)'), true);

renderDevice([job({ lastExit: 2 })]);
check('마지막 종료 코드 != 0 → 오류 + 코드 노출', /오류 ⚠ \(exit 2\)/.test(rows()), true);

renderDevice([job({ pid: 71551, lastExit: -1 })]);
check('PID 있으면 동작 중', /동작 중/.test(rows()) && rows().includes('PID 71551'), true);

renderDevice([job({ pid: -1, lastExit: 0 })]);
check('로드됐고 안 돌면 대기', /대기/.test(rows()), true);
// exit 0 은 "정상 종료"지 오류가 아니다 — 주기 작업 대부분이 여기 머문다.
check('종료 코드 0은 오류가 아님', /오류/.test(rows()), false);

// ---- 2) 사람 이름이 먼저, 개발용 라벨은 아래 ----
showAll();
renderDevice([job({ name: 'support-agents', label: 'com.globalmpc.support-agents' })]);
check('사람 이름이 굵게 앞에', rows().includes('<b class="devname">support-agents</b>'), true);
check('개발용 라벨은 보조 줄로', rows().includes('<span class="devlabel"') &&
      rows().includes('>com.globalmpc.support-agents</span>'), true);
check('등록 위치는 라벨 줄 title 로', rows().includes('title="com.globalmpc.support-agents · /p.plist"'), true);

// 실행 대상은 목록에서 빼고 상세 페이지로 보냈다 — 목록에는 이름 줄 호버로만 남는다.
renderDevice([job({ detail: '/Users/lioncho/Work/x/Scripts/support-agents.sh --once' })]);
check('실행 대상은 짧은 형태 + 전체 경로가 이름 줄 title 에',
      rows().includes('title="support-agents.sh --once — /Users/lioncho/Work/x/Scripts/support-agents.sh --once"'), true);
check('실행 대상은 목록 칸을 차지하지 않는다', rows().includes('<td class="muted"'), false);
// 리다이렉트(>> file 2>&1)는 배관이지 하는 일이 아니다.
check('리다이렉트는 요약에서 제외',
      shortCmd('/usr/bin/python3 /opt/cost_daily.py >> /tmp/cron.log 2>&1'), 'python3 cost_daily.py');

// ---- 3) 프로젝트: 오케스트레이션의 축 ----
showAll();
renderDevice([job({ project: 'globalmpc-marketing' })]);
check('프로젝트 칩', rows().includes('<span class="proj">globalmpc-marketing</span>'), true);
renderDevice([job({ project: '시스템' })]);
check('시스템 버킷은 흐리게', rows().includes('class="proj sys"'), true);
renderDevice([job({ project: '' })]);
check('프로젝트 없으면 미분류', rows().includes('미분류'), true);

// 프로젝트 셀렉트는 스캔 결과에서 자동으로 만들어진다 (시스템은 항상 맨 뒤).
renderDevice([job({ id: '1', project: 'zeta' }), job({ id: '2', project: '시스템' }),
              job({ id: '3', project: 'alpha' }), job({ id: '4', project: 'zeta' })]);
check('프로젝트 옵션 자동 생성 · 중복 제거 · 시스템은 뒤로',
      el('fProj').innerHTML,
      '<option value="">전체</option><option value="alpha">alpha</option>'
      + '<option value="zeta">zeta</option><option value="시스템">시스템</option>');

// ---- 4) 보기 필터 ----
const mixed = [job({ id: 'ok1', project: 'alpha' }),
               job({ id: 'ok2', project: 'beta' }),
               job({ id: 'dead', project: 'alpha', loaded: false }),
               job({ id: 'err', project: 'beta', lastExit: 1 }),
               job({ id: 'off', project: 'alpha', disabled: true })];
const rowCount = () => (rows().match(/<tr/g) || []).length;

_filter.state = 'live'; _filter.proj = '';
renderDevice(mixed);
check('동작 중만 — 미로드·오류·꺼짐은 숨김', rowCount(), 2);
check('숨긴 개수를 알려 준다', el('hiddenNote').textContent, '3개 숨김');
// 앱 탭을 보고 있을 때는 디바이스 표가 폴링돼도 안내 줄을 건드리지 않는다.
_tab='app'; el('hiddenNote').textContent='앱쪽 숫자';
renderDevice(mixed);
check('보고 있지 않은 탭은 안내 줄을 덮지 않는다', el('hiddenNote').textContent, '앱쪽 숫자');
_tab='device'; renderDevice(mixed);

_filter.state = 'bad';
renderDevice(mixed);
check('문제만 — 살아 있는 건 숨김', rowCount(), 3);

_filter.state = 'all';
renderDevice(mixed);
check('전체', rowCount(), 5);
check('전체 보기에서는 숨김 안내 없음', el('hiddenNote').textContent, '');

_filter.proj = 'alpha';
renderDevice(mixed);
check('프로젝트 필터', rowCount(), 3);
_filter.state = 'live';
renderDevice(mixed);
check('프로젝트 + 상태 동시 적용', rowCount(), 1);

_filter.state = 'live'; _filter.proj = 'nonexistent';
renderDevice(mixed);
check('걸리는 게 없으면 빈 안내', /이 조건에 맞는 작업이 없습니다/.test(rows()), true);

// 탭 배지는 필터와 무관하게 전체와 문제 개수를 그대로 보여 준다.
check('탭 배지는 필터에 영향받지 않음', el('cnt-device').textContent, '5 · 문제 3');

// setFilter 는 셀렉트 값을 읽어 두 표를 다시 그리고 선택을 저장한다.
_filter.proj = '';
el('fState').value = 'bad'; el('fProj').value = 'beta';
setFilter();
check('setFilter 가 셀렉트를 반영', [_filter.state, _filter.proj], ['bad', 'beta']);
check('선택은 다음 방문까지 저장', JSON.parse(localStorage.getItem('cmCronFilter')),
      { state: 'bad', proj: 'beta' });

// ---- 5) 자세히: 앱 창 안에서 열려야 한다 (target=_blank 면 기본 브라우저로 튄다) ----
showAll();
renderDevice([job({ id: 'com.globalmpc.support-agents' })]);
check('자세히는 상세 페이지로', rows().includes('href="/device-cron?id=com.globalmpc.support-agents"'), true);
check('자세히에 target=_blank 없음', /target=/.test(rows()), false);

// ---- 6) 빈 목록 / 실행 횟수 미상 / 이스케이프 ----
renderDevice([]);
check('빈 목록 안내', /등록된 launchd\/crontab 작업이 없습니다/.test(rows()), true);
renderDevice([job({ source: 'crontab', runs: -1 })]);
check('runs 미상은 – 표시', rows().includes('<td>–</td>'), true);
renderDevice([job({ name: '<script>x</script>' })]);
check('디스크에서 온 문자열 이스케이프', rows().includes('&lt;script&gt;'), true);

// ---- 7) 마지막 실행: 로그 파일이 없으면 추측하지 않는다 ----
const now = Math.floor(Date.now() / 1000);
check('로그 없음 → 아직 없음', fmtWhen(0), '아직 없음');
check('초', fmtWhen(now - 30), '30초 전');
check('분', fmtWhen(now - 300), '5분 전');
check('시간+분', fmtWhen(now - 3660), '1시간 1분 전');
check('일', fmtWhen(now - 86400 * 3), '3일 전');
// 앱과 로그 파일의 시계가 어긋나 미래 mtime이 와도 음수를 뱉지 않는다.
check('미래 시각은 0으로 클램프', fmtWhen(now + 120), '0초 전');

console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
