// E2E for 메모장 링크 칸 — 2026-08-06 옛 통합 '링크' 칸을 지라·노션·슬랙 세 칸으로
// 나눴다. 목적: PM 에이전트가 주기적으로 와서 각 서비스 링크를 찾아 채우고 추적한다.
// REAL source(MemoPad.swift)에 묶는다. 여기서 지키는 계약:
//   - 링크 칸은 셋(지라·노션·슬랙), 저장 키도 '@지라: URL' 처럼 서비스 이름으로 갈린다
//   - 옛 '@링크: URL' 저장분은 계속 읽힌다 — 호스트 판정으로 세 칸에 나눠 담고(LK2F),
//     못 알아보는 링크(깃허브 등)는 상세 줄로 남긴다(글을 버리지 않는다)
//   - 판정은 호스트네임으로만 (경로에 slack.com 을 끼워 넣는 눈속임 불가)
//   - http(s) 만 칩을 탄다 (javascript: 류가 칩을 타면 안 된다)
//   - 칩은 값이 있는 칸마다 하나, 접힌 제목 줄에서도 보이고(data-u 있을 때만),
//     mousedown → window.open. 낯빛은 칸이 정한다(지라 칸=지라 낯빛)
//   - 칸 이름 옆 검증: 그 서비스 주소가 맞으면 성격(관리·문서·대화), 아니면 '주소 확인'
const fs = require('fs');
const R = (p) => fs.readFileSync(__dirname + '/../' + p, 'utf8');
const PAD = R('Sources/ConditionManager/Dashboard/MemoPad.swift');

let pass = 0, fail = 0;
function eq(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + '\n       got=' + g + '\n      want=' + w); }
}

// ── 칸 정의 — 서비스별 세 칸 ───────────────────────────────────────────────
const fields = PAD.match(/var FIELDS=\[([\s\S]*?)\];/)[1];
[['지라', 'jira'], ['노션', 'notion'], ['슬랙', 'slack']].forEach(([k, svc]) => {
  eq(k + ' 칸이 FIELDS 에 있다 (저장·CSV·병합이 공짜로 따라온다)',
    new RegExp("\\{k:'" + k + "'[^}]*link:'" + svc + "'").test(fields), true);
  eq(k + ' 칸에는 태그 사전이 없다 (URL 에 사전은 의미가 없다)',
    new RegExp("\\{k:'" + k + "'[^}]*tag:true").test(fields), false);
});
eq('옛 통합 링크 칸은 FIELDS 에서 사라졌다', /\{k:'링크'/.test(fields), false);
eq('링크 칸은 한 줄을 통째로 쓴다 (URL 은 길다)',
  /\.cmmemo \.cmm-fs label\[data-link\]\{ grid-column:1\/-1 \}/.test(PAD), true);

// ── 판정 규칙 — 실제로 돌려본다 ────────────────────────────────────────────
const slice = (from, to) => {
  const a = PAD.indexOf(from), b = PAD.indexOf(to, a);
  if (a < 0 || b < 0) throw new Error('cannot extract linkKind');
  return PAD.slice(a, b + to.length);
};
const linkKind = new Function(
  slice('var LINKS=', "return {t:'링크', c:'', k:'link'};") + '\n}\nreturn linkKind;')();
const kindOf = (u) => { const k = linkKind(u); return k ? k.k : null; };

eq('슬랙 워크스페이스 스레드 URL → 슬랙',
  kindOf('https://mustcompany.slack.com/archives/C0BFGCPAU3H/p1785927045348329?thread_ts=1785914309.398309'),
  'slack');
eq('app.slack.com 도 슬랙', kindOf('https://app.slack.com/client/T1/C2'), 'slack');
eq('지라 클라우드(atlassian.net) → 지라', kindOf('https://must.atlassian.net/browse/NSS-12'), 'jira');
eq('자가 호스팅 jira.* 도 지라', kindOf('https://jira.company.com/browse/X-1'), 'jira');
eq('노션 페이지 → 노션', kindOf('https://www.notion.so/team/Spec-abc123'), 'notion');
eq('notion.site 공개 페이지도 노션', kindOf('https://myteam.notion.site/doc'), 'notion');
eq('깃허브 PR → 깃허브', kindOf('https://github.com/must-lioncho/x/pull/8'), 'github');
eq('모르는 호스트는 일반 링크', kindOf('https://example.com/page'), 'link');
eq('경로의 slack.com 은 안 속는다 (호스트네임만 본다)',
  kindOf('https://evil.com/slack.com/archives'), 'link');
eq('notslack.com 은 슬랙이 아니다 (단어 경계)', kindOf('https://notslack.com/x'), 'link');
eq('http 도 허용', kindOf('http://jira.internal/browse/A-1'), 'jira');
eq('URL 이 아니면 판정 없음', kindOf('그냥 메모'), null);
eq('빈 값도 판정 없음', kindOf(''), null);
eq('javascript: 는 칩을 타지 못한다', kindOf('javascript:alert(1)'), null);
eq('ftp 등 다른 스킴도 제외', kindOf('ftp://files.example.com/a'), null);
eq('판정에는 성격이 딸려 있다 (슬랙=대화)', linkKind('https://x.slack.com/a').c, '대화');
eq('지라=관리', linkKind('https://x.atlassian.net/a').c, '관리');
eq('노션=문서', linkKind('https://x.notion.site/a').c, '문서');

// ── 옛 '@링크: ' 라우팅 (LK2F) ─────────────────────────────────────────────
eq('FRE 에 옛 링크 키가 별칭으로 남아 있다 (계속 읽힌다)',
  /\|링크[|)]/.test(PAD), true);
eq('LK2F — 판정 결과를 세 칸에 나눠 담는 지도',
  /var LK2F=\{ slack:'슬랙', jira:'지라', notion:'노션' \};/.test(PAD), true);
eq('parse 가 옛 링크 줄을 칸으로 옮겨 담는다',
  /if\(f && f\[1\]==='링크'\)\{/.test(PAD), true);
eq('못 알아보는 옛 링크는 상세 줄로 남긴다 (글을 버리지 않는다)',
  /if\(dk && !last\.fields\[dk\]\)\{ last\.fields\[dk\]=f\[2\]; return; \}\s*last\.detail\.push\(det\[2\]\); return;/.test(PAD), true);
// 라우팅을 실제로 돌려본다 — LK2F 만 있으면 순수 함수다.
const LK2F = { slack: '슬랙', jira: '지라', notion: '노션' };
const routeOf = (u) => { const k = linkKind(u); return (k && LK2F[k.k]) || null; };
eq('옛 슬랙 링크 → 슬랙 칸', routeOf('https://mustcompany.slack.com/archives/C1/p2'), '슬랙');
eq('옛 지라 링크 → 지라 칸', routeOf('https://must.atlassian.net/browse/NSS-12'), '지라');
eq('옛 노션 링크 → 노션 칸', routeOf('https://team.notion.so/Spec'), '노션');
eq('옛 깃허브 링크는 담을 칸이 없다 (상세로)', routeOf('https://github.com/x/y/pull/8'), null);
eq('옛 일반 링크도 담을 칸이 없다 (상세로)', routeOf('https://example.com/page'), null);
// CSV 가져오기도 같은 라우팅을 탄다 — 옛 내보내기의 '링크' 열이 사라지지 않도록.
eq('CSV 의 옛 링크 열도 세 칸으로 담는다',
  /var li=head\.indexOf\('링크'\);/.test(PAD), true);

// ── 칩 — 칸마다 하나 · 보이기 · 눌러서 이동 ────────────────────────────────
eq('칩은 링크 칸마다 하나씩 만든다',
  /var lks=FIELDS\.filter\(function\(d\)\{ return d\.link; \}\)\.map\(function\(d\)\{/.test(PAD), true);
eq('칩은 값이 있을 때만 보인다 (data-u 유무를 CSS 가 본다)',
  /\.cmmemo \.cmm-lk\[data-u\]\{ display:inline-block \}/.test(PAD), true);
eq('값이 사라지면 칩의 흔적도 지운다',
  /lk\.removeAttribute\('data-u'\); lk\.removeAttribute\('data-lk'\);/.test(PAD), true);
eq('칩은 mousedown 으로 연다 (캐럿이 흔들리지 않게)',
  /lk\.addEventListener\('mousedown', function\(e\)\{\s*e\.preventDefault\(\); e\.stopPropagation\(\);/.test(PAD), true);
eq('window.open 으로 넘긴다 (앱 웹뷰에서는 기본 브라우저)',
  /var u=lk\.getAttribute\('data-u'\); if\(u\) window\.open\(u,'_blank'\);/.test(PAD), true);
eq('칩은 편집면 안의 원자다 (캐럿이 안으로 못 들어간다)',
  /lk\.className='cmm-lk'; lk\.contentEditable='false'; lk\.rel='noopener';/.test(PAD), true);
eq('칩은 제목 줄(접힘 상태)에 산다 — 제목·칩들·알약 순',
  /ln\.appendChild\(ck\); ln\.appendChild\(tx\);\s*lks\.forEach\(function\(lk\)\{ ln\.appendChild\(lk\); \}\);\s*ln\.appendChild\(cue\);/.test(PAD), true);
eq('칩의 낯빛은 칸이 정한다 (지라 칸=지라 낯빛)',
  /lk\.setAttribute\('data-u', u\); lk\.setAttribute\('data-lk', fd\.link\);/.test(PAD), true);
eq('칸 이름 옆 검증 — 맞으면 성격, 아니면 주소 확인',
  /kind\.k===fd\.link\) \? \(kind\.c\|\|''\)\s*: '주소 확인'/.test(PAD), true);

// ── 저장 왕복 — @지라/@노션/@슬랙 은 FRE 로 자동 커버 ──────────────────────
eq('FRE 는 FIELDS 이름들로 만든다 (세 칸이 자동 포함)',
  /var FRE=new RegExp\('\^@\('\+FIELDS\.map/.test(PAD), true);
const FRE = new RegExp('^@(목표일|담당|팀|프로젝트|지라|노션|슬랙|링크):\\s?(.*)$');
[['@지라: https://must.atlassian.net/browse/NSS-12', '지라'],
 ['@노션: https://team.notion.so/Spec-abc', '노션'],
 ['@슬랙: https://mustcompany.slack.com/archives/C1/p2', '슬랙'],
 ['@링크: https://mustcompany.slack.com/archives/C1/p2', '링크']].forEach(([line, k]) => {
  const m = FRE.exec(line);
  eq(line.split(':')[0] + ': 줄이 칸으로 읽힌다', m && m[1], k);
});

console.log('---');
console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
