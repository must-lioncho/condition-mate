// E2E for 연동 레지스트리 — 플러그인 페이지의 연동 칸과 LLM 연동 섹션.
//
// 왜 이 테스트가 있나: 이 기능의 요지는 "같은 사실을 한곳에만 둔다"이다. 예전에는
// 슬랙 토큰·번역 키 목록이 슬랙 페이지 모달, 검사 코드, hasKey 호출, 안내 문구에
// 각각 손으로 적혀 있어서 하나를 고치면 나머지가 조용히 어긋났다. 그래서 아래
// 검증은 두 축이다:
//   (1) 소스 계약 — 목록·서비스 이름의 원본이 IntegrationCatalog 한곳인가,
//       비밀값이 argv/로그로 새지 않는가.
//   (2) 실제 DOM — SessionRail의 진짜 HTML/JS를 크로미움에 띄우고 /api/integrations
//       payload를 물려, 카드가 서버의 판단을 그대로 그리는가 (다시 계산하지 않는가).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RAIL = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Dashboard/SessionRail.swift'), 'utf8');
const CATALOG = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/IntegrationCatalog.swift'), 'utf8');
const STORE = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/IntegrationStore.swift'), 'utf8');
const KEYCHAIN = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/Keychain.swift'), 'utf8');
const SLACKINT = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Slack/SlackIntegrations.swift'), 'utf8');
const SLACKSTORE = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Slack/SlackTranslateStore.swift'), 'utf8');
const PLUGINS = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/Core/PluginStore.swift'), 'utf8');
const APP = fs.readFileSync(path.join(ROOT, 'Sources/ConditionMate/AppDelegate.swift'), 'utf8');

let pass = 0, fail = 0;
const check = (n, ok, extra) => {
  console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : ''));
  ok ? pass++ : fail++;
};

// ---------------------------------------------------------------- 1. 단일 원본
{
  check('슬랙 스코프 목록의 원본은 카탈로그 한곳',
    /slackUserScopes = \[/.test(CATALOG) &&
    /requiredUserScopes: \[String\] \{ IntegrationCatalog\.slackUserScopes \}/.test(SLACKINT));
  check('키체인 서비스 이름을 슬랙 코드가 따로 적지 않는다',
    !/cm-slack-user-token|cm-gemini-api-key|cm-anthropic-api-key/.test(SLACKSTORE) &&
    /cm-slack-user-token/.test(CATALOG));
  check('슬랙 검사는 레지스트리에 위임하고 옛 응답 키만 되짚는다',
    /IntegrationChecks\.checkAll/.test(SLACKINT) && /legacyKeys/.test(SLACKINT));
  check('한쪽에서 돌린 검사 결과를 레지스트리가 흡수한다 (같은 확인을 두 번 하지 않게)',
    /IntegrationStore\.record\(/.test(SLACKINT) && /public static func record\(/.test(STORE));
  check('플러그인은 키 내용을 들고 있지 않고 연동 id로만 가리킨다',
    /credentials: \["slack-user", "slack-app"\]/.test(PLUGINS) &&
    !/cm-slack-user-token/.test(PLUGINS));
}

// ------------------------------------------------------------- 2. 비밀값 취급
{
  check('키 쓰기는 argv가 아니라 stdin(security -i)으로 — ps에 값이 안 보인다',
    /run\(\["-i"\], stdin: cmd\)/.test(KEYCHAIN));
  check('파서가 값을 잘라먹을 수 있는 문자는 저장 전에 거부한다',
    /isSafe\(\$0\)/.test(KEYCHAIN) && /공백·따옴표·역슬래시/.test(KEYCHAIN));
  check('화면에는 마스킹(뒤 4자리)만 내려간다',
    /func masked\(service: String\) -> String/.test(KEYCHAIN) &&
    /"••••" \+ String\(v\.suffix\(4\)\)/.test(KEYCHAIN));
  check('키 등록 요청 본문은 액션 로그에 옮기지 않는다',
    /let secretBody = path\.hasPrefix\("\/api\/integrations\/key"\)/.test(APP) &&
    /where !secretBody/.test(APP));
  check('키를 바꾸면 이전 판단(캐시)을 즉시 버린다',
    /invalidate\(id\)/.test(STORE));
}

// --------------------------------------------------------------- 3. 정렬·배치
{
  check('플러그인 목록은 이름 가나다순 (정의 순서가 아니라)',
    /plugins\.sort \{ \$0\.name\.localizedStandardCompare\(\$1\.name\) == \.orderedAscending \}/.test(PLUGINS));
  const iPl = RAIL.indexOf('id="cmPlList"');
  const iLlm = RAIL.indexOf('id="cmLlmList"');
  const iSk = RAIL.indexOf('id="cmSkList"');
  check('LLM 연동 섹션은 플러그인 다음, 스킬 앞', iPl > 0 && iLlm > iPl && iSk > iLlm,
    `pl=${iPl} llm=${iLlm} sk=${iSk}`);
}

// --------------------------------------------------------------- 4. 실제 DOM
// SessionRail의 진짜 HTML/JS를 그대로 띄운다. payload는 서버 응답 형식 그대로.
const open = RAIL.indexOf('return #"""');
if (open < 0) throw new Error('레일 HTML 리터럴을 못 찾음');
const railHTML = RAIL.slice(open + 'return #"""'.length, RAIL.indexOf('"""#', open))
  .replace('\\#(CMTimeFilter.bootHTML())', '');

const cred = (id, name, provider, over) => Object.assign({
  id, name, provider, kind: 'apiKey', kindLabel: 'API 키',
  service: 'cm-' + id, account: provider, role: name + ' 역할', placeholder: 'key…',
  issueURL: 'https://example.invalid', issueHint: '발급 경로',
  present: false, masked: '', state: 'unknown', detail: '', error: '', missingScopes: [],
}, over || {});

// 시나리오: 번역 기본(Gemini)은 살아 있고 백업(Claude CLI)은 없다 —
// 사용자가 요구한 "백업용도 없습니다" 문구가 나오는 상태.
const INTEGRATIONS = {
  ok: true,
  providers: [
    { id: 'anthropic', name: 'Claude (Anthropic)', desc: 'c', isLLM: true,
      connected: false, via: '', credentials: ['anthropic-api', 'claude-cli'] },
    { id: 'gemini', name: 'Gemini (Google)', desc: 'g', isLLM: true,
      connected: true, via: 'API 키', credentials: ['gemini-api'] },
    { id: 'slack', name: 'Slack', desc: 's', isLLM: false,
      connected: true, via: 'API 키', credentials: ['slack-user', 'slack-app'] },
  ],
  credentials: [
    cred('slack-user', '슬랙 사용자 토큰', 'slack', { present: true, masked: '••••ab12', state: 'ok', detail: 'MUST · iris' }),
    cred('slack-app', '슬랙 앱 토큰', 'slack', { present: true, masked: '••••cd34', state: 'fail', error: 'token_revoked' }),
    cred('gemini-api', 'Gemini API 키', 'gemini', { present: true, masked: '••••ef56', state: 'ok', detail: '키 유효' }),
    cred('anthropic-api', 'Claude API 키', 'anthropic', { state: 'missing' }),
    cred('claude-cli', 'Claude CLI 구독', 'anthropic', { kind: 'cliSession', kindLabel: 'CLI 구독', service: '', state: 'missing' }),
  ],
  capabilities: [
    { id: 'slack-translate', name: '슬랙 번역', owner: 'slack-translate', ok: true,
      level: 'nobackup',
      message: '백업용도 없습니다 — 기본 연동이 끊기면 바로 멈춥니다. 백업 후보: Claude CLI 구독 — 함께 연동해 두세요.',
      primary: ['gemini-api'], backup: ['claude-cli'], usingPrimary: ['gemini-api'], usingBackup: [] },
  ],
  slackUserScopes: ['chat:write'],
};
const PLUGIN_PAYLOAD = { plugins: [
  { id: 'draw', name: '드로우', desc: 'd', hint: 'h', kind: 'toggle', installed: true,
    folder: '', credentials: [], capabilities: [], status: 'valid', detail: '설치됨',
    verifiedAt: 0, projects: [], drawOn: true },
  { id: 'slack-translate', name: '슬랙 번역', desc: '슬랙 번역함', hint: '설치형', kind: 'toggle',
    installed: true, folder: '', credentials: ['slack-user', 'slack-app'],
    capabilities: ['slack-translate'], status: 'valid', detail: '설치됨', verifiedAt: 0, projects: [] },
] };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  const posted = [];
  await page.exposeFunction('__record', (url, body) => { posted.push({ url, body }); });
  await page.addInitScript(([intg, plug]) => {
    const json = d => Promise.resolve({ ok: true, json: () => Promise.resolve(d), text: () => Promise.resolve('') });
    window.fetch = (u, opt) => {
      if (opt && opt.method === 'POST') {
        window.__record(u, opt.body || '');
        if (String(u).indexOf('/api/integrations/key') >= 0) return json({ ok: true, saved: true });
        return json({ ok: true });
      }
      if (String(u).indexOf('/api/integrations') >= 0) return json(intg);
      if (String(u).indexOf('/api/plugins') >= 0) return json(plug);
      if (String(u).indexOf('/api/skills/history') >= 0) return json({ items: [] });
      if (String(u).indexOf('/api/skills') >= 0) return json({ skills: [], dir: '', root: '~/.claude' });
      return json({});
    };
  }, [INTEGRATIONS, PLUGIN_PAYLOAD]);
  // setContent()는 about:blank 문서라 localStorage가 막혀 레일 부팅이 죽는다 (slackmenu
  // 테스트와 같은 이유). http 오리진을 주되 네트워크는 route로 가로채 오프라인 유지.
  await page.route('http://cm.test/**', r =>
    r.fulfill({ contentType: 'text/html; charset=utf-8',
                body: '<!doctype html><html><body>' + railHTML + '</body></html>' }));
  await page.goto('http://cm.test/');
  await page.evaluate(() => window.cmSkillsOpen());
  await page.waitForFunction(() => document.querySelectorAll('#cmPlList .cmpl-card').length > 0);

  const slackCard = '#cmPlList .cmpl-card:nth-of-type(2)';
  check('슬랙 번역이 플러그인 카드로 나온다',
    (await page.textContent('#cmPlList')).includes('슬랙 번역'));

  // 접힌 행이 문제를 감추지 않는다 — 앱 토큰이 실패면 '연동 필요'로 보인다.
  const pill = await page.evaluate(() => {
    const cards = document.querySelectorAll('#cmPlList .cmpl-card');
    for (const c of cards) {
      if (c.querySelector('.nm').textContent === '슬랙 번역') return c.querySelector('.cmpl-pill').textContent;
    }
    return '';
  });
  check('연동이 깨진 플러그인은 접힌 채로도 연동 필요로 보인다', pill === '연동 필요', pill);

  await page.evaluate(() => window.cmPlToggle('slack-translate'));
  const body = await page.evaluate(() => {
    const cards = document.querySelectorAll('#cmPlList .cmpl-card');
    for (const c of cards) {
      if (c.querySelector('.nm').textContent === '슬랙 번역') return c.querySelector('.cmpl-body').innerHTML;
    }
    return '';
  });
  check('카드 안에 필요한 키가 전부 나온다', body.includes('슬랙 사용자 토큰') && body.includes('슬랙 앱 토큰'));
  check('키 서비스 이름과 발급 경로가 함께 나온다',
    body.includes('cm-slack-user') && body.includes('발급 페이지 열기'));
  check('실패한 키의 원인을 그대로 보여준다', body.includes('token_revoked'));
  check('저장된 키는 마스킹만 — 값은 화면에 오지 않는다',
    body.includes('••••ab12') && !body.includes('value="'));
  check('백업이 없다는 경고를 서버 문구 그대로 싣는다',
    body.includes('백업용도 없습니다') && body.includes('Claude CLI 구독'));
  check('경고에서 LLM 연동으로 바로 갈 수 있다', body.includes('cmLlmFocus()'));

  // LLM 섹션: 기본은 연동된 것만 (모델이 많아 다 보이면 못 읽는다).
  const llmNames = () => page.evaluate(() =>
    [].map.call(document.querySelectorAll('#cmLlmList .cmpl-head .nm'), e => e.textContent));
  const shown = await llmNames();
  check('LLM 섹션은 연동된 것만 보인다', shown.length === 1 && shown[0] === 'Gemini (Google)', shown.join(','));
  check('슬랙은 LLM 섹션에 섞이지 않는다', !shown.includes('Slack'));
  await page.evaluate(() => window.cmLlmToggleAll());
  const all = await llmNames();
  check('연동 추가를 누르면 아직 안 붙인 제공자까지 보인다',
    all.length === 2 && all.includes('Claude (Anthropic)'), all.join(','));
  check('연동 개수 요약이 연결/전체로 나온다',
    (await page.textContent('#cmLlmCount')).replace(/\s+/g, ' ').trim() === '· 연결 1 / 2');

  // 저장: 값은 요청 본문으로만 나가고, 끝나면 입력 칸이 비워진다.
  await page.evaluate(() => window.cmLlmProvToggle('anthropic'));
  await page.fill('#cmig-in-anthropic-api', 'sk-ant-secret-value');
  await page.evaluate(() => window.cmIntgSave('anthropic-api', null));
  await page.waitForFunction(() => document.getElementById('cmig-in-anthropic-api') === null
    || document.getElementById('cmig-in-anthropic-api').value === '');
  const keyPost = posted.find(p => String(p.url).includes('/api/integrations/key'));
  check('저장은 키 등록 엔드포인트로 간다', !!keyPost, keyPost ? keyPost.url : '(없음)');
  check('요청 본문에 id와 값이 실린다',
    !!keyPost && keyPost.body.includes('anthropic-api') && keyPost.body.includes('sk-ant-secret-value'));
  check('저장 후 입력 칸에 키가 남지 않는다',
    await page.evaluate(() => { const el = document.getElementById('cmig-in-anthropic-api');
      return !el || el.value === ''; }));

  // 연결 테스트: 실제 API 호출은 사용자가 누를 때만 (렌더링만으로 돌면 안 된다).
  const before = posted.filter(p => String(p.url).includes('/api/integrations/check')).length;
  check('그리는 것만으로는 라이브 검사를 돌리지 않는다', before === 0, String(before));
  await page.evaluate(() => window.cmIntgTest(['gemini-api'], null));
  await page.waitForFunction(() => true);
  const after = posted.filter(p => String(p.url).includes('/api/integrations/check')).length;
  check('연결 테스트를 누르면 그때 검사한다', after === 1, String(after));

  await browser.close();
  console.log('');
  console.log(`${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
