// Visual stub for 메모장 + 사이드바 3단계. Serves a page shaped like /goal-add — the SHIPPING
// rail CSS + stage machine (SessionRail.swift) and the SHIPPING MemoPad module (MemoPad.swift),
// extracted at request time — with an in-memory /api/memo. Lets the 3 stages, the ≤360px
// responsive fold and the 문서형 layout be checked in a real browser without launching the app
// (the app's own port must never be borrowed for this — see the 앱 포트 금지 rule).
//
//   node .e2e/memostub.js            → http://127.0.0.1:8933
//   (or the "memo-stub" entry in .claude/launch.json)
const http = require('http');
const PORT = Number(process.env.PORT || 8933);

let memo = { text: ['전역 메모장 — 여기 적은 글은 어느 화면에서 열어도 그대로 있습니다.',
  '',
  '- [ ] 이번 루프에 할 일',
  '- [x] 이번 루프에 끝낸 일',
  '- [x] 지난 루프에 끝낸 일 (보기 ▾ → 이전 루프 포함으로만 보인다)',
  '    @루프: 26-37',
  '',
  '⊞ 를 세 번 누르면 이 화면만 남습니다.'].join('\n'), updatedAt: 1, rev: 1 };
// 지난 판 저널 스텁 — MemoStore 의 memo-history.jsonl 과 같은 규칙: 수용될 때 묻힌 판,
// 판번호가 어긋나 거부된 판이 쌓인다(최신이 끝). GET /api/memo/history 는 최신순으로 준다.
const memoHist = [];
// 골번호 채번 스텁 상태 — 보드가 이미 쓴 번호 다음부터(재사용 없음).
let seqFloor = 600;
// 부모 칸 MRU 스텁 — 최신이 맨 앞(앱은 Settings.recentParentSeqs). 599 는 비워 둔다 —
// '슬랙 …' 줄 제목으로 AI 추천 섹션에 등장할 수 있게(최근과 겹치면 최근만 남는다).
let recentParents = [598];
const BOARD_GOALS = [
  { seq: 598, text: '주정산 온체인 실측 파이프라인' },
  { seq: 599, text: '슬랙 번역 데몬 재시작 처리' },
];
// 루프 코드 스텁 — 메모장 루프 번호는 보드의 스프린트/릴리즈 코드와 한 일련번호다.
// 현재 = 열린 스프린트 중 가장 이른 번호의 코드, 이전 = 최신(첫) 릴리즈의 코드.
const BOARD_SPRINTS = [
  { number: 38, code: '26-38', closed: false },
  { number: 37, code: '26-37', closed: true },
];
const BOARD_RELEASES = [
  { id: 'r1', code: '26-37', sprint: 37 },
];

function page(tz) {
  // Re-read the Swift sources on every request so an edit shows up on reload.
  delete require.cache[require.resolve('./memosrc')];
  const { RAIL_CSS, RAIL_JS, PAD_HTML, DASH_CHAT_CSS, TZ_JS } = require('./memosrc');
  return `<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>메모장 3단계 스텁</title>
<style>
  :root{ --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3; --accent:#5b8cff }
  html,body{ margin:0; background:#0b0e14; color:var(--fg);
    font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif }
  main{ padding:26px 22px; max-width:900px }
  .wrap{ padding:26px 22px }
  .card{ background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:14px; margin-bottom:12px }
  .gs-bar{ position:fixed; left:var(--cmrail-w,0); right:0; bottom:0; z-index:40;
    background:#0f141d; border-top:1px solid var(--line); padding:10px 16px }
</style>
${RAIL_CSS}
<style>
  :root{ --bg:#0b0e14 }
  ${DASH_CHAT_CSS}
</style>
</head><body>
<aside class="cmrail">
  <div class="cmrail-brand">
    <button class="cmrail-sbtoggle" data-cmrail-tg onclick="cmRailToggle(event)" title="접기">⊞</button>
    <span class="cmrail-dots" data-cmrail-dots><i></i><i></i><i></i></span>
  </div>
  <div style="padding:10px 14px;color:#7c869c">세션 레일 (스텁)</div>
</aside>
<div class="cmrail-toggle">
  <button class="cmrail-sbtoggle" data-cmrail-tg onclick="cmRailToggle(event)" title="열기">⊞</button>
  <span class="cmrail-dots" data-cmrail-dots><i></i><i></i><i></i></span>
</div>
<!-- 대시보드 모양: 왼쪽 작업 보드 + 오른쪽 대화 패널(메모 네이티브 + 컴포저 iframe) -->
<aside class="cmchat">
  <div class="cmchat-grip" id="cmChatGrip" title="드래그"></div>
  <div class="cmchat-memo"><main>${PAD_HTML}</main></div>
  <iframe class="cmchat-frame" id="cmChatFrame" src="/embed" title="대화"></iframe>
</aside>
<div class="wrap" data-cmboard>
  <div class="card"><b>작업 보드 (스텁)</b><div style="color:var(--mut)">3단계에서만 보인다.</div></div>
  <div class="card">목표 12 · 목표 13 · 목표 14</div>
</div>
<!-- 앱에서는 레일이 주입하는 표시 타임존. ?tz=Asia/Kolkata 로 바꿔 가며 같은 목표일이
     각자의 시계로 다시 계산되는지 눈으로 확인할 수 있다(빈 값 = 브라우저 로컬). -->
<script>window.CM_TZ=${tz ? JSON.stringify(tz) : 'null'};
${TZ_JS}</script>
<script>${RAIL_JS}</script>
</body></html>`;
}

// 대화 패널 안의 임베드(실제로는 /goal-add?embed=1) 자리를 채우는 최소 스텁.
const embedPage = () => `<!doctype html><meta charset="utf-8"><style>
  html,body{margin:0;background:#0b0e14;color:#e6e9ef;font:14px/1.6 -apple-system,sans-serif}
  main{padding:14px 16px}
  .panel{background:#141821;border:1px solid #222a36;border-radius:14px;padding:15px;margin-bottom:12px}
</style><main>
  <div class="panel"><b>AI 검색 · 추가 컴포저</b> (임베드 스텁)</div>
  <div class="panel">큐 — 대기 3건</div>
</main>`;

// 메모장 칸 태그 사전(MemoTagStore.swift)의 in-memory 판. 매칭 규칙은 서버와 같게 둔다 —
// 앞글자 → 단어 앞글자 → 포함 순, 같은 단계에서는 많이 쓴 순.
const KINDS = ['담당', '팀', '프로젝트'];
const tags = {
  담당: [{ name: 'ismail', count: 4 }, { name: 'ismail.k', count: 1 }, { name: '김지훈', count: 3 }],
  팀: [{ name: '플랫폼', count: 5 }, { name: '프로덕트', count: 2 }],
  프로젝트: [{ name: 'NSS 모니터', count: 6 }, { name: '컨디션 관리', count: 2 }],
};
const fold = (s) => String(s || '').trim().toLowerCase().split(/\s+/).filter(Boolean).join(' ');
function searchTags(kind, q) {
  const list = tags[kind] || [];
  const byUse = (a, b) => b.count - a.count || a.name.localeCompare(b.name);
  if (!fold(q)) return list.slice().sort(byUse).slice(0, 8);
  const f = fold(q);
  return list
    .map((t) => {
      const n = fold(t.name);
      if (n.startsWith(f)) return [0, t];
      if (n.split(/[ \-_./]+/).some((w) => w.startsWith(f))) return [1, t];
      if (n.includes(f)) return [2, t];
      return null;
    })
    .filter(Boolean)
    .sort((a, b) => a[0] - b[0] || byUse(a[1], b[1]))
    .slice(0, 8)
    .map((p) => p[1]);
}

http.createServer((req, res) => {
  if (req.url.split('?')[0] === '/api/memo/tags') {
    const json = (o) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
    if (req.method === 'POST') {
      let b = '';
      req.on('data', (c) => { b += c; });
      req.on('end', () => {
        let k = '', name = '';
        try { const o = JSON.parse(b); k = o.k; name = String(o.name || '').trim(); } catch (e) {}
        if (!KINDS.includes(k) || !name) return json({ ok: false });
        const hit = tags[k].find((t) => fold(t.name) === fold(name));
        if (hit) hit.count += 1; else tags[k].push({ name, count: 1 });
        json({ ok: true, name: hit ? hit.name : name });
      });
      return;
    }
    const u = new URL(req.url, 'http://x');
    const k = u.searchParams.get('k') || '', q = (u.searchParams.get('q') || '').trim();
    if (!KINDS.includes(k)) return json({ tags: [], canCreate: false });
    return json({ tags: searchTags(k, q),
                  canCreate: !!q && !(tags[k] || []).some((t) => fold(t.name) === fold(q)) });
  }
  // 부모 칸 후보 스텁 — 앱의 /api/memo/parent-suggest 와 같은 모양: recent = MRU(최신이
  // 맨 앞), sug = AI 추천(여기서는 보드 골 제목에 줄 제목 낱말이 겹치면 후보로).
  if (req.url.split('?')[0] === '/api/memo/parent-suggest') {
    const u = new URL(req.url, 'http://x');
    const title = (u.searchParams.get('title') || '').trim();
    const no = Number(u.searchParams.get('no') || 0);
    const bySeq = {}; BOARD_GOALS.forEach((g) => { bySeq[g.seq] = g.text; });
    const recent = recentParents.filter((n) => n !== no).map((n) => ({ n, t: bySeq[n] || '' }));
    const words = title.split(/\s+/).filter((w) => w.length >= 2);
    const sug = BOARD_GOALS
      .filter((g) => g.seq !== no && words.some((w) => g.text.includes(w)))
      .map((g) => ({ n: g.seq, t: g.text, why: '제목 키워드 일치 (스텁)' }));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ recent, sug }));
  }
  // 부모 사용 기록 스텁 — Settings.noteParentUse 와 같은 규칙(맨 앞 삽입, 8개 상한).
  if (req.url.split('?')[0] === '/api/memo/parent-used') {
    let b = '';
    req.on('data', (c) => { b += c; });
    req.on('end', () => {
      let n = 0;
      try { n = (JSON.parse(b) || {}).n || 0; } catch (e) {}
      if (n > 0) {
        recentParents = [n].concat(recentParents.filter((x) => x !== n)).slice(0, 8);
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    return;
  }
  // 골번호 채번 스텁 — ReviewStore.reserveSeqs 와 같은 규칙(단조 증가, 재사용 없음).
  // 보드 골이 이미 500번대까지 쓴 상황을 흉내 내려고 600부터 시작한다.
  if (req.url.split('?')[0] === '/api/memo/seq') {
    let b = '';
    req.on('data', (c) => { b += c; });
    req.on('end', () => {
      let n = 1;
      try { n = Math.max(1, Math.min(500, (JSON.parse(b) || {}).count || 1)); } catch (e) {}
      const seqs = [];
      for (let i = 0; i < n; i++) seqs.push(++seqFloor);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, seqs }));
    });
    return;
  }
  // 부모 꼬리표·루프 코드의 보드 조회 스텁 — /data.json 의 goals(seq·text)와
  // sprints/releases(code) 만 쓰인다.
  if (req.url.split('?')[0] === '/data.json') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ goals: BOARD_GOALS, sprints: BOARD_SPRINTS, releases: BOARD_RELEASES }));
  }
  if (req.url.split('?')[0] === '/embed') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(embedPage());
  }
  // 지난 판 목록 — MemoStore.history() 와 같은 규칙: 최신순, 빈 글·현재 글과 같은 판은 뺀다.
  if (req.url.split('?')[0] === '/api/memo/history') {
    const items = memoHist.filter((e) => e.text && e.text !== memo.text).reverse().slice(0, 100)
      .map((e) => ({ t: e.t, rev: e.rev, kind: e.kind, chars: [...e.text].length, text: e.text }));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ items }));
  }
  if (req.url.split('?')[0] === '/api/memo') {
    if (req.method === 'POST') {
      let b = '';
      req.on('data', (c) => { b += c; });
      req.on('end', () => {
        // 판번호 게이트 — MemoStore.save(base:)와 같은 규칙. base 가 어긋난 낡은 쓰기는
        // 저장하지 않고 현재 글을 돌려준다(패드가 합쳐서 다시 민다). base 없으면 legacy 수용.
        const json = (o) => { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(o)); };
        let o = {};
        try { o = JSON.parse(b) || {}; } catch (e) {}
        const t = o.text || '';
        if (t === memo.text) return json({ ok: true, rev: memo.rev, updatedAt: memo.updatedAt, chars: [...memo.text].length });
        if (typeof o.base === 'number' && o.base !== memo.rev) {
          memoHist.push({ t: Math.floor(Date.now() / 1000), rev: o.base, kind: 'refused', text: t });
          return json({ ok: true, conflict: true, text: memo.text, rev: memo.rev, updatedAt: memo.updatedAt });
        }
        if (memo.text) memoHist.push({ t: Math.floor(Date.now() / 1000), rev: memo.rev, kind: 'replaced', text: memo.text });
        memo = { text: t, updatedAt: Math.floor(Date.now() / 1000), rev: memo.rev + 1 };
        json({ ok: true, rev: memo.rev, updatedAt: memo.updatedAt, chars: [...memo.text].length });
      });
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ text: memo.text, updatedAt: memo.updatedAt, rev: memo.rev, chars: [...memo.text].length }));
  }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(page(new URL(req.url, 'http://x').searchParams.get('tz')));
}).listen(PORT, '127.0.0.1', () => console.log('memo stub on http://127.0.0.1:' + PORT));
