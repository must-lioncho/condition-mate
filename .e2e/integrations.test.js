// E2E for 연동 레지스트리 — 플러그인 페이지의 연동 목록(플러그인·MCP·모델 키 한 줄).
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
const INSTANCES = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/IntegrationInstances.swift'), 'utf8');
const REGISTRAR = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/MCPRegistrar.swift'), 'utf8');
const NOTION_CLI = fs.readFileSync(path.join(ROOT, 'Sources/NotionKeychainRegister/main.swift'), 'utf8');

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
  check('Notion 후보 열거는 속성만 요청하고 비밀 data를 요청하지 않는다',
    /kSecReturnAttributes: true/.test(KEYCHAIN) && /kSecReturnData: false/.test(KEYCHAIN));
  check('Notion 후보는 service 또는 account 이름만 대소문자 무시로 필터한다',
    /func filterNotionCandidates/.test(KEYCHAIN) && /options: \.caseInsensitive/.test(KEYCHAIN));
  check('Notion CLI는 TTY echo를 defer로 복원하고 명령 파싱 문자를 거부한다',
    /defer \{ _ = tcsetattr/.test(NOTION_CLI) && /!"\\\"\\\\'`\$"\.contains/.test(NOTION_CLI));
  check('외부 Keychain 참조에는 service/account만 저장되고 토큰 필드가 없다',
    /keychainService/.test(INSTANCES) && /keychainAccount/.test(INSTANCES) &&
    !/public var (token|secret|password):/.test(INSTANCES));
  check('후보 검증 전 실패는 인스턴스를 만들지 않고, 검증 실패는 상태와 참조를 남긴다',
    STORE.indexOf('guard CMKeychain.exists(service: service, account: account)') <
      STORE.indexOf('let inst = CredInstance(credId: c.id, key: key') &&
    /setTest\(credId: c\.id, key: key, ok: result\.state == \.ok/.test(STORE));
  check('선택한 account를 Notion 검사와 MCP 런처가 정확히 사용한다',
    /CMKeychain\.value\(service: svc, account: \$0\)/.test(fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/IntegrationChecks.swift'), 'utf8')) &&
    /find-generic-password -w -s "\$svc" -a "\$acct"/.test(REGISTRAR));
  check('Notion UI에는 토큰 input 대신 Keychain 후보와 Terminal 등록만 있다',
    /cmNotionFind/.test(RAIL) && /cmNotionRegister/.test(RAIL) &&
    RAIL.includes("needsToken&&c.id!=='notion-token'") &&
    RAIL.includes("if(c.id==='notion-token')") && RAIL.includes('Keychain에서 찾기'));
}

// ------------------------------------------------------- 2.5 지라: 두 갈래 연동
// 지라는 붙는 곳이 둘이고 서로를 대신하지 못한다 — 이슈는 API 토큰으로 MCP에,
// 골(Goals)은 REST에 없어서 OAuth 앱으로 GraphQL에 붙는다. 하나만 서 있는 상태를
// '연결됨'이라고 부르면 나머지 절반이 왜 안 되는지 화면 어디서도 알 수 없다.
{
  const CHECKS = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/IntegrationChecks.swift'), 'utf8');
  check('지라의 세 갈래가 카탈로그 한곳에 있다',
    /id: "jira-token", name: "Jira API 토큰", provider: "atlassian"/.test(CATALOG) &&
    /id: "jira-goals", name: "Jira 골 \(Goals\)", provider: "atlassian"/.test(CATALOG) &&
    /id: "jira-cli", name: "Atlassian CLI \(acli\)", provider: "atlassian"/.test(CATALOG));
  check('acli 는 깔린 것과 로그인된 것을 갈라서 말한다',
    /func checkAtlassianCli/.test(CHECKS) &&
    /acli를 찾지 못했습니다/.test(CHECKS) && /로그인돼 있지 않습니다/.test(CHECKS));
  check('지라는 둘 다 서야 연결로 본다 (requireAll)',
    /Provider\(id: "atlassian"[\s\S]{0,400}?requireAll: true\)/.test(CATALOG));
  check('부분 연결 판정은 서버가 하고 화면은 그리기만 한다',
    /"full\\":\\\(p\.requireAll \? live\.count == creds\.count : !live\.isEmpty\)/.test(STORE) &&
    /p\.full===false/.test(RAIL) && !/requireAll/.test(RAIL));
  check('골 자격증명은 앱이 보관하지 않는다 — 키체인 항목 존재만 본다',
    /id: "jira-goals"[\s\S]{0,200}?service: "", account: ""/.test(CATALOG) &&
    /jiraGoalsAccounts = \["client_id", "client_secret", "refresh_token"\]/.test(CHECKS) &&
    /CMKeychain\.exists\(service: jiraGoalsService, account: \$0\)/.test(CHECKS));
  check('골의 실제 호출은 사람이 눌렀을 때만 (목록을 그리는 경로는 얕게 본다)',
    /func check\(_ id: String, deep: Bool = false\)/.test(CHECKS) &&
    /checkAll\(targets, deep: true\)/.test(STORE) &&
    /if !deep \{/.test(CHECKS));
  const REG = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/MCPRegistrar.swift'), 'utf8');
  // 설정 파일을 어디서 어떻게 읽는지는 MCPHosts 가 안다 — 등록(Registrar)과 읽기(Hosts)를
  // 나눈 이유는 붙을 수 있는 곳이 Claude 하나가 아니기 때문이다.
  const HOSTS = fs.readFileSync(path.join(ROOT, 'Sources/Plugins/Integrations/MCPHosts.swift'), 'utf8');
  check('앱 밖에서 이미 붙어 있는 서버를 인정하는 규칙은 카탈로그에 있다',
    /externalHost: "mcp\.atlassian\.com"/.test(CATALOG) &&
    !/mcp\.atlassian\.com/.test(RAIL) && !/mcp\.atlassian\.com/.test(STORE));
  check('직접 등록한 서버는 프로젝트 스코프까지 찾는다',
    /obj\["projects"\] as\? \[String: Any\]/.test(HOSTS) && /proj\["mcpServers"\], scope: "프로젝트"/.test(HOSTS));
  check('앱이 만든 서버(cm-)는 직접 등록으로 세지 않는다',
    /!s\.name\.hasPrefix\("cm-"\)/.test(REG));

  // ---- 클라이언트(호스트)별 연결 ----
  // 이 기능이 답하는 질문: "연결했는데 왜 코덱스에서는 안 보이지". 예전에는
  // ~/.claude.json 하나만 보고 초록불을 켰기 때문에 물을 자리조차 없었다.
  check('등록 상태를 클라이언트마다 따로 읽는다',
    /public static func registeredNames\(hostId: String\)/.test(REG) &&
    /public static func hosts\(\) -> \[Host\]/.test(HOSTS));
  check('앱이 등록하는 곳은 Claude Code 사용자 스코프 하나뿐이라고 못 박는다',
    /hostId == MCPHosts\.claudeCodeId/.test(REG) && /scope == "사용자"/.test(REG));
  check('코덱스는 계정마다 홈이 따로라는 사실을 반영한다 (~/.codex 하나로 보지 않는다)',
    /codex-accounts/.test(HOSTS) && /CODEX_HOME/.test(HOSTS));
  check('앱이 등록하지 못하는 클라이언트는 managed=false 로 표시된다',
    /managed: false/.test(HOSTS) && /"managed\\":\\\(h\.managed\)/.test(STORE));
  check('인스턴스 한 줄이 클라이언트별 등록 여부를 싣는다',
    /hostStatusJSON\(name\)/.test(STORE) && /"registered\\":/.test(STORE));
  check('직접 등록도 클라이언트별로 전부 싣는다 (하나만 보여주지 않는다)',
    /externalServers\(host: String\)/.test(REG) && /"externals\\":/.test(STORE));
  check('화면은 서버가 판정한 호스트 목록을 그대로 그린다 (설정 파일을 직접 세지 않는다)',
    /function mcpHostsHtml\(inst\)/.test(RAIL) && /inst\.hosts\|\|\[\]/.test(RAIL) &&
    !/mcpServers/.test(RAIL) && !/mcp_servers/.test(RAIL));
  check('이 맥에 없는 클라이언트는 미연결이 아니라 없음으로 말한다',
    /이 맥에 없음/.test(RAIL) && /h\.present/.test(RAIL));

  // ---- 주의사항 ----
  // 붙이는 법(hint)과 붙이고 나면 무엇이 남는가(caution)는 다른 사실이다. 문구를
  // 화면이 조립하기 시작하면 같은 사실이 자리마다 다르게 적히므로, 원본은 하나다.
  check('방식별 주의사항의 원본은 카탈로그다 (화면이 문장을 만들지 않는다)',
    /public let caution: String/.test(CATALOG) &&
    /caution: "승인한 노션 계정의 권한으로 붙습니다/.test(CATALOG) &&
    !/승인한 노션 계정/.test(RAIL) && !/승인한 노션 계정/.test(STORE));
  check('계정에 매인 홈이라는 사실과 그 뜻을 호스트 쪽이 들고 있다',
    /accountScoped/.test(HOSTS) && /private static let accountCaution/.test(HOSTS) &&
    !/accountCaution/.test(RAIL));
  check('클라이언트마다 따로 붙는다는 사실을 한 줄로 내려보낸다',
    /public static let perClientNote/.test(HOSTS) && /mcpHostNote/.test(STORE) &&
    /mcpHostNote/.test(RAIL));
  check('붙이는 법과 주의사항을 payload에서도 갈라 싣는다',
    /"modeHint\\":/.test(STORE) && /"modeCaution\\":/.test(STORE));
  check('사이트 주소를 앱이 따로 적지 않고 스킬 메타데이터에서 읽는다',
    /jiraGoalsSite/.test(CHECKS) && !/mustcompany\.atlassian\.net/.test(CHECKS));
}

// --------------------------------------------------------------- 3. 정렬·배치
{
  check('플러그인 목록은 이름 가나다순 (정의 순서가 아니라)',
    /plugins\.sort \{ \$0\.name\.localizedStandardCompare\(\$1\.name\) == \.orderedAscending \}/.test(PLUGINS));
  const iInt = RAIL.indexOf('id="cmIntList"');
  const iSk = RAIL.indexOf('id="cmSkList"');
  check('연동 목록은 하나뿐이고 스킬 앞에 온다', iInt > 0 && iSk > iInt, `int=${iInt} sk=${iSk}`);
  // 예전엔 플러그인·연동(MCP)·LLM이 각각 자기 목록을 갖고 있었다. 같은 서비스가
  // 두 자리에 앉는 원인이었으므로, 그 목록들이 되살아나지 않는지 못을 박아 둔다.
  check('플러그인·MCP·LLM 목록으로 다시 쪼개지지 않았다',
    !/id="cmPlList"|id="cmMcpList"|id="cmLlmList"/.test(RAIL));
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
    { id: 'anthropic', name: 'Claude 연동', desc: 'c', isLLM: true, section: 'llm',
      connected: false, via: '', credentials: ['anthropic-api', 'claude-cli'] },
    { id: 'gemini', name: 'Gemini 연동', desc: 'g', isLLM: true, section: 'llm',
      connected: true, via: 'API 키', credentials: ['gemini-api'] },
    // 슬랙은 자기 카드가 없다 — 슬랙 연동 플러그인 카드 안에서 그려진다(section: plugin).
    { id: 'slack', name: '슬랙 연동', desc: 's', isLLM: false, section: 'plugin',
      connected: true, via: 'API 키', credentials: ['slack-user', 'slack-app'] },
    // 골만 붙고 이슈(MCP)는 아직 — 절반이다.
    { id: 'atlassian', name: 'Jira 연동', desc: '이슈와 골 둘로 붙습니다', isLLM: false, section: 'mcp',
      connected: true, via: 'OAuth 앱', instanceCount: 0, mcpCount: 0,
      liveCount: 1, credCount: 2, full: false, credentials: ['jira-goals', 'jira-token'] },
  ],
  credentials: [
    cred('slack-user', '슬랙 사용자 토큰', 'slack', { present: true, masked: '••••ab12', state: 'ok', detail: 'MUST · iris' }),
    cred('slack-app', '슬랙 앱 토큰', 'slack', { present: true, masked: '••••cd34', state: 'fail', error: 'token_revoked' }),
    cred('gemini-api', 'Gemini API 키', 'gemini', { present: true, masked: '••••ef56', state: 'ok', detail: '키 유효' }),
    cred('anthropic-api', 'Claude API 키', 'anthropic', { state: 'missing' }),
    cred('claude-cli', 'Claude CLI 구독', 'anthropic', { kind: 'cliSession', kindLabel: 'CLI 구독', service: '', state: 'missing' }),
    cred('jira-goals', 'Jira 골 (Goals)', 'atlassian', { kind: 'oauthApp', kindLabel: 'OAuth 앱', service: '',
      state: 'ok', detail: '자격증명 3종 등록됨' }),
    cred('jira-token', 'Jira API 토큰', 'atlassian', { multi: true, instances: [],
      mcp: { kind: 'jira', summary: 'mcp.atlassian.com' }, authOptions: [],
      fields: [{ key: 'site', label: '사이트 주소', placeholder: 'https://…', required: true, tokenOnly: false }] }),
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
  { id: 'slack-translate', name: '슬랙 연동', desc: '슬랙 번역함', hint: '설치형', kind: 'toggle',
    installed: true, folder: '', credentials: ['slack-user', 'slack-app'],
    capabilities: ['slack-translate'], status: 'valid', detail: '설치됨', verifiedAt: 0, projects: [] },
] };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  const posted = [];
  await page.exposeFunction('__record', (url, body) => { posted.push({ url, body }); });
  await page.addInitScript(([intg, plug]) => {
    // 시나리오를 바꿔 끼울 수 있게 페이로드를 창에 매달아 둔다 — 같은 화면이
    // '반만 붙은 지라'와 '직접 등록된 서버로 다 붙은 지라'를 둘 다 그려야 한다.
    window.__intg = intg;
    const json = d => Promise.resolve({ ok: true, json: () => Promise.resolve(d), text: () => Promise.resolve('') });
    window.fetch = (u, opt) => {
      if (opt && opt.method === 'POST') {
        window.__record(u, opt.body || '');
        if (String(u).indexOf('/api/integrations/key') >= 0) return json({ ok: true, saved: true });
        return json({ ok: true });
      }
      if (String(u).indexOf('/api/integrations') >= 0) return json(window.__intg);
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
  await page.waitForFunction(() => document.querySelectorAll('#cmIntList .cmpl-card').length > 0);

  check('슬랙 연동이 한 목록 안의 카드로 나온다',
    (await page.textContent('#cmIntList')).includes('슬랙 연동'));

  // 접힌 행이 문제를 감추지 않는다 — 앱 토큰이 실패면 '연동 필요'로 보인다.
  const pill = await page.evaluate(() => {
    const cards = document.querySelectorAll('#cmIntList .cmpl-card');
    for (const c of cards) {
      if (c.querySelector('.nm').textContent === '슬랙 연동') return c.querySelector('.cmpl-pill').textContent;
    }
    return '';
  });
  check('연동이 깨진 플러그인은 접힌 채로도 연동 필요로 보인다', pill === '연동 필요', pill);

  // 반만 붙은 지라는 접힌 채로도 반이라고 말한다 — '연결됨'이면 나머지 절반이
  // 왜 안 되는지 물을 자리가 사라진다.
  const provPill = (name) => page.evaluate((n) => {
    const cards = document.querySelectorAll('#cmIntList .cmpl-card');
    for (const c of cards) {
      if (c.querySelector('.nm').textContent === n) return c.querySelector('.cmpl-pill').textContent;
    }
    return '';
  }, name);
  check('둘 중 하나만 붙은 지라는 1/2 연결로 보인다', (await provPill('Jira 연동')) === '1/2 연결',
    await provPill('Jira 연동'));

  await page.evaluate(() => window.cmPlToggle('atlassian'));
  const jbody = await page.evaluate(() => {
    const cards = document.querySelectorAll('#cmIntList .cmpl-card');
    for (const c of cards) {
      if (c.querySelector('.nm').textContent === 'Jira 연동') return c.querySelector('.cmpl-body').innerHTML;
    }
    return '';
  });
  check('지라 카드 안에 골과 이슈 토큰이 둘 다 있다',
    jbody.includes('Jira 골 (Goals)') && jbody.includes('Jira API 토큰'), jbody.slice(0, 120));
  check('골은 붙여넣을 칸이 아니라 연결 확인만 준다',
    jbody.includes('연결 확인') && !jbody.includes('cmig-in-jira-goals'));

  await page.evaluate(() => window.cmPlToggle('slack-translate'));
  const body = await page.evaluate(() => {
    const cards = document.querySelectorAll('#cmIntList .cmpl-card');
    for (const c of cards) {
      if (c.querySelector('.nm').textContent === '슬랙 연동') return c.querySelector('.cmpl-body').innerHTML;
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
  check('카드 이름은 붙는 대상이고 기능은 그 안에 나열된다',
    body.includes('기능 1') && body.includes('슬랙 번역'));
  check('경고에서 연동 추가로 바로 갈 수 있다', body.includes('cmIntFocus()'));

  // 한 목록: 플러그인과 연동이 나란히 앉는다. 기본은 붙어 있는 것만 —
  // 제공자를 다 펼쳐 두면 실제로 쓰는 것이 안 쓰는 것에 묻힌다.
  const names = () => page.evaluate(() =>
    [].map.call(document.querySelectorAll('#cmIntList > .cmpl-card > .cmpl-head > .nm'), e => e.textContent));
  const shown = await names();
  check('플러그인과 연동이 한 목록에 섞여 나온다',
    shown.join(',') === '드로우,슬랙 연동,Gemini 연동,Jira 연동', shown.join(','));
  check('아직 안 붙인 연동은 기본으로 숨는다', !shown.includes('Claude 연동'));
  check('슬랙은 자기 카드를 따로 만들지 않는다 (플러그인 카드 안에서 산다)',
    shown.filter(n => n === '슬랙 연동').length === 1, shown.join(','));
  check('숨긴 개수를 요약이 말해 준다',
    (await page.textContent('#cmIntCount')).replace(/\s+/g, ' ').trim() === '· 4 · 미연동 1 숨김',
    await page.textContent('#cmIntCount'));
  await page.evaluate(() => window.cmIntToggleAll());
  const all = await names();
  check('연동 추가를 누르면 아직 안 붙인 제공자까지 보인다',
    all.length === 5 && all.includes('Claude 연동'), all.join(','));
  check('전부 보이면 숨김 표시가 사라진다',
    (await page.textContent('#cmIntCount')).replace(/\s+/g, ' ').trim() === '· 5');

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

  // 사람이 앱 밖에서 등록해 둔 지라 MCP가 이미 있는 경우 — 연결로 세되, 여기서
  // 끄거나 고칠 수 없다는 사실을 같이 말해야 한다.
  await page.evaluate(() => {
    const p = window.__intg.providers.find(x => x.id === 'atlassian');
    p.liveCount = 2; p.full = true; p.via = 'OAuth 앱 · API 키';
    const c = window.__intg.credentials.find(x => x.id === 'jira-token');
    c.external = { name: 'atlassian', scope: '프로젝트', target: 'https://mcp.atlassian.com/v1/mcp/authv2' };
  });
  await page.evaluate(() => window.cmIntgTest([], null));
  await page.waitForFunction(() => {
    const cards = document.querySelectorAll('#cmIntList .cmpl-card');
    for (const c of cards) {
      if (c.querySelector('.nm').textContent === 'Jira 연동') {
        return c.querySelector('.cmpl-pill').textContent === '연결됨';
      }
    }
    return false;
  });
  check('둘 다 붙으면 지라는 연결됨이다', (await provPill('Jira 연동')) === '연결됨');
  const jbody2 = await page.evaluate(() => {
    const cards = document.querySelectorAll('#cmIntList .cmpl-card');
    for (const c of cards) {
      if (c.querySelector('.nm').textContent === 'Jira 연동') return c.querySelector('.cmpl-body').innerHTML;
    }
    return '';
  });
  check('직접 등록한 서버는 연결로 세되 앱이 만든 것이 아니라고 말한다',
    jbody2.includes('연결됨 · 직접 등록') && jbody2.includes('끄거나 고칠 수 없습니다')
      && jbody2.includes('mcp.atlassian.com/v1/mcp/authv2'));
  check('직접 등록됐어도 앱이 관리하는 인스턴스를 따로 붙일 길은 남는다',
    jbody2.includes('인스턴스 추가'));

  // 클라이언트별 연결 — 같은 연동이 Claude엔 붙고 코덱스엔 안 붙은 상태를 그린다.
  // 이 화면이 답해야 하는 질문이 "연결했는데 왜 코덱스에서는 안 보이지"이므로,
  // 붙은 곳과 안 붙은 곳이 한 줄에 나란히 있어야 한다.
  await page.evaluate(() => {
    window.__intg.mcpHostNote = 'MCP 연동은 클라이언트마다 따로 붙습니다.';
    window.__intg.mcpHosts = [
      { id: 'claude-code', name: 'Claude Code', present: true, managed: true,
        configPath: '~/.claude.json', serverCount: 2 },
      { id: 'codex-acct-2eb6dfbd', name: 'Codex · 계정 2eb6dfbd', present: true, managed: false,
        accountScoped: true, caution: '이 연동은 사람이 아니라 Codex 계정에 붙습니다',
        configPath: '~/x/config.toml', serverCount: 0 },
      { id: 'claude-desktop', name: 'Claude 앱', present: false, managed: false,
        configPath: '~/y.json', serverCount: 0 },
    ];
    const c = window.__intg.credentials.find(x => x.id === 'jira-token');
    c.external = null; c.externals = [];
    c.instances = [{ key: 'must', label: 'MUST', id: 'jira-token:must', mode: 'token',
      modeName: '토큰', needsToken: true, modeHint: '', mcpSummary: 'mcp.atlassian.com',
      fields: { site: 'https://must.atlassian.net', email: 'a@b.c' },
      mcpWanted: true, mcpName: 'cm-jira-must', mcpRegistered: true,
      hosts: [
        { id: 'claude-code', name: 'Claude Code', present: true, managed: true, registered: true },
        { id: 'codex-acct-2eb6dfbd', name: 'Codex · 계정 2eb6dfbd', present: true, managed: false, registered: false },
        { id: 'claude-desktop', name: 'Claude 앱', present: false, managed: false, registered: false },
      ],
      testedAt: 0, testOk: false, testNote: '', testUrl: '', scan: null, scannedAt: 0,
      probe: null, present: true, masked: '••••99', state: 'ok', detail: '', error: '' }];
  });
  await page.evaluate(() => window.cmIntgTest([], null));
  await page.waitForFunction(() => !!document.querySelector('#cmIntList .cmig-hosts'));
  const hostRow = await page.evaluate(() => {
    const el = document.querySelector('#cmIntList .cmig-host');
    return el ? el.closest('.cmig-hosts').textContent : '';
  });
  check('인스턴스 한 줄이 클라이언트별로 붙었는지를 나란히 보여준다',
    hostRow.includes('Claude Code · 연결됨') && hostRow.includes('Codex · 계정 2eb6dfbd · 연결 안 됨'),
    hostRow);
  check('이 맥에 없는 클라이언트는 미연결이 아니라 없음이다',
    hostRow.includes('Claude 앱 · 이 맥에 없음'));
  const jbody3 = await page.evaluate(() => {
    for (const c of document.querySelectorAll('#cmIntList .cmpl-card')) {
      if (c.querySelector('.nm').textContent === 'Jira 연동') return c.querySelector('.cmpl-body').innerHTML;
    }
    return '';
  });
  check('앱이 등록하지 않는 클라이언트는 직접 붙여야 한다고 말한다',
    jbody3.includes('앱이 등록하지 않습니다') && jbody3.includes('codex mcp add'));
  const strip = await page.evaluate(() => {
    const el = document.getElementById('cmIntHosts');
    return el ? el.textContent : '';
  });
  check('목록 위에 이 맥의 MCP 클라이언트가 한 줄로 먼저 나온다',
    strip.includes('MCP 클라이언트') && strip.includes('Claude Code · 2개')
      && strip.includes('Codex · 계정 2eb6dfbd · 0개') && !strip.includes('Claude 앱'), strip);
  check('클라이언트마다 따로 붙는다는 사실을 목록 위에서 먼저 말한다',
    strip.includes('클라이언트마다 따로 붙습니다'));
  check('계정에 매인 클라이언트는 그 뜻을 주의사항으로 단다',
    strip.includes('Codex · 계정 2eb6dfbd — 이 연동은 사람이 아니라 Codex 계정에 붙습니다'));

  // 승인 방식이 남기는 흔적 — 붙이기 전에 읽어야 뜻이 있으므로 방식 옆·토큰 칸 앞에 온다.
  await page.evaluate(() => {
    const c = window.__intg.credentials.find(x => x.id === 'jira-token');
    c.instances[0].modeCaution = '승인한 계정의 권한으로 붙습니다 — 코멘트에 남는 이름도 그 계정입니다.';
  });
  await page.evaluate(() => window.cmIntgTest([], null));
  await page.waitForFunction(() => !!document.querySelector('#cmIntList .cmig-caution'));
  const jbody4 = await page.evaluate(() => {
    for (const c of document.querySelectorAll('#cmIntList .cmpl-card')) {
      if (c.querySelector('.nm').textContent === 'Jira 연동') return c.querySelector('.cmpl-body').innerHTML;
    }
    return '';
  });
  check('붙이면 무엇이 남는지를 인스턴스 줄에서 말한다',
    jbody4.includes('cmig-caution') && jbody4.includes('코멘트에 남는 이름도 그 계정입니다'));
  check('주의사항은 안내(cmig-hint)와 다른 자리에 그려진다',
    jbody4.indexOf('cmig-caution') < jbody4.indexOf('앱이 등록하지 않습니다'));

  await browser.close();
  console.log('');
  console.log(`${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
