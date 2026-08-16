// E2E for 메모장 저장 신뢰 (2026-08-06). Bound to REAL source: mounts the SHIPPING
// MemoPad module (MemoPad.swift, via memosrc) in a real Chromium against an in-page
// /api/memo that mirrors MemoStore.save(base:) — 판번호 게이트까지 서버와 같은 규칙.
//
// 지키려는 약속: "적은 글은 사라지지 않는다."
//   [1] 저장은 마지막으로 본 판번호(base)를 싣고 가고, 응답의 새 판을 이어받는다.
//   [2] 다른 창이 먼저 저장했으면(판 어긋남) 덮지 않는다 — 두 글을 합쳐 새 판으로 다시 민다.
//   [3] 창이 앞으로 오면 서버 판을 조용히 맞춘다 — 낡은 패드 위에 타이핑을 시작하지 않게.
//   [4] 저장이 못 닿고 죽은 세션의 로컬 초안은 다음 로드에서 복구된다(확인 후 초안 삭제).
//   [5] 로드가 끝나기 전에 친 글은 서버 글을 지우지 않는다 — 로드되는 순간 합쳐진다.
const http = require('http');
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const PORT = Number(process.env.PORT || 8941);

const html = `<!doctype html><html><head><meta charset="utf-8">
<style>:root{ --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3; --accent:#5b8cff }
  body{ margin:0; background:#0b0e14; color:#e6e9ef }</style></head>
<body><main>${PAD_HTML}</main>
<script>
// /api/memo 를 페이지 안에서 흉내 — 저장 규칙은 MemoStore.save(base:)와 동일하게 둔다.
// ?case= 로 초기 서버 상태(그리고 4번 케이스의 로컬 초안)를 심는다.
(function(){
  var c=new URLSearchParams(location.search).get('case')||'base';
  // 생성 스탬프(2026-08-10)는 서버 글에 이미 찍혀 있는 상태로 둔다 — 첫 로드
  // 마이그레이션(@생성: 이전 채우기)이 여기서 판번호와 저장 횟수를 흔들지 않도록.
  window.SRV={ text:'서버 첫 줄\\n    @생성: 이전', rev:7, updatedAt:100, posts:[] };
  window.__delayGet=false; window.__getWaiters=[];
  try{ localStorage.removeItem('cmMemoDraft'); }catch(e){}
  if(c==='draft'){
    window.SRV={ text:'서버 글\\n    @생성: 이전', rev:3, updatedAt:100, posts:[] };
    try{ localStorage.setItem('cmMemoDraft', JSON.stringify(
      {text:'서버 글\\n    @생성: 이전\\n죽기 전 초안 줄\\n    @생성: 이전', t:200})); }catch(e){}
  }
  if(c==='lateload'){ window.SRV={ text:'서버 글\\n    @생성: 이전', rev:5, updatedAt:100, posts:[] }; window.__delayGet=true; }
  // 이 파일이 보는 것은 저장 신뢰(판번호·합집합·초안)이지 스탬프가 아니다 — 걷어 내고 읽는다.
  window.__noCr=function(s){ return String(s||'').split('\\n')
    .filter(function(l){ return !/^\\s+@생성:/.test(l); }).join('\\n'); };
  window.__t=function(){ return __noCr(CMMemo.text()); };
  window.__st=function(){ return __noCr(SRV.text); };
  var _f=window.fetch;
  window.fetch=function(u,o){
    if(String(u).indexOf('/api/memo')<0) return _f.apply(this,arguments);
    var reply=function(obj){ return Promise.resolve({json:function(){ return Promise.resolve(obj); }}); };
    if(o && o.method==='POST'){
      var b=JSON.parse(o.body); SRV.posts.push(b);
      if(b.text===SRV.text) return reply({ok:true,rev:SRV.rev,updatedAt:SRV.updatedAt});
      if(typeof b.base==='number' && b.base!==SRV.rev)
        return reply({ok:true,conflict:true,text:SRV.text,rev:SRV.rev,updatedAt:SRV.updatedAt});
      SRV.text=b.text; SRV.rev++; SRV.updatedAt=Math.floor(Date.now()/1000);
      return reply({ok:true,rev:SRV.rev,updatedAt:SRV.updatedAt});
    }
    var snap=function(){ return {text:SRV.text,rev:SRV.rev,updatedAt:SRV.updatedAt}; };
    if(window.__delayGet) return new Promise(function(res){
      window.__getWaiters.push(function(){ res({json:function(){ return Promise.resolve(snap()); }}); }); });
    return reply(snap());
  };
})();
</script></body></html>`;

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
const eq = (n, got, want) => check(n, JSON.stringify(got) === JSON.stringify(want),
  JSON.stringify(got) === JSON.stringify(want) ? '' : `got=${JSON.stringify(got)} want=${JSON.stringify(want)}`);

(async () => {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  }).listen(PORT, '127.0.0.1');

  const browser = await chromium.launch();

  // 케이스마다 새 컨텍스트 — localStorage(로컬 초안)가 케이스를 넘어 오염되지 않게.
  const open = async (kase) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    await page.goto(`http://127.0.0.1:${PORT}/?case=${kase}`);
    await page.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);
    return { ctx, page };
  };
  const text = (page) => page.evaluate(() => __t());
  const srv = (page) => page.evaluate(() => ({ text: __st(), rev: SRV.rev, posts: SRV.posts }));
  const set = (page, s) => page.evaluate((s) => CMMemo.setText(s), s);
  const waitSrvText = (page, want) =>
    page.waitForFunction((w) => window.SRV && __st() === w, want, { timeout: 5000 });

  // [1] base 왕복 — 저장은 본 판을 싣고, 새 판을 이어받는다.
  {
    const { ctx, page } = await open('base');
    await page.waitForFunction(() => __t() === '서버 첫 줄');
    await set(page, '서버 첫 줄\n새 줄');
    await waitSrvText(page, '서버 첫 줄\n새 줄');
    let s = await srv(page);
    eq('base: 첫 저장이 base=7 을 싣는다', s.posts[0].base, 7);
    eq('base: 서버 판이 8 로 오른다', s.rev, 8);
    await set(page, '서버 첫 줄\n새 줄\n둘째 줄');
    await waitSrvText(page, '서버 첫 줄\n새 줄\n둘째 줄');
    s = await srv(page);
    eq('base: 다음 저장은 이어받은 base=8', s.posts[s.posts.length - 1].base, 8);
    await page.waitForFunction(() =>
      document.querySelector('.cmmemo-hd .meta').textContent === '저장됨');
    check('base: 확인된 저장은 저장됨 으로 표시', true);
    await ctx.close();
  }

  // [2] 판 어긋남 — 덮지 않고 합쳐서 다시 민다. 어느 쪽 글도 사라지지 않는다.
  {
    const { ctx, page } = await open('base');
    await page.waitForFunction(() => __t() === '서버 첫 줄');
    await page.evaluate(() => { SRV.text = '서버 첫 줄\n다른 창 줄'; SRV.rev = 8; });
    await set(page, '서버 첫 줄\n내 줄');
    await waitSrvText(page, '서버 첫 줄\n내 줄\n다른 창 줄');
    const s = await srv(page);
    eq('conflict: 서버 최종 = 두 글의 합집합', s.text, '서버 첫 줄\n내 줄\n다른 창 줄');
    eq('conflict: 화면도 같은 합집합', await text(page), '서버 첫 줄\n내 줄\n다른 창 줄');
    eq('conflict: 합친 판이 9 로 선다', s.rev, 9);
    await ctx.close();
  }

  // [3] 포커스 새로고침 — 놀고 있는 패드는 앞으로 올 때 서버 판을 이어받는다.
  {
    const { ctx, page } = await open('base');
    await page.waitForFunction(() => __t() === '서버 첫 줄');
    await page.evaluate(() => { SRV.text = '서버 첫 줄\n딴 데서 쓴 줄'; SRV.rev = 8; });
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    await page.waitForFunction(() => __t() === '서버 첫 줄\n딴 데서 쓴 줄');
    check('refresh: 창이 앞으로 오면 다른 화면의 글이 보인다', true);
    await ctx.close();
  }

  // [4] 로컬 초안 복구 — 저장 못 하고 죽은 세션의 글이 다음 로드에서 살아난다.
  {
    const { ctx, page } = await open('draft');
    await page.waitForFunction(() => __t() === '서버 글\n죽기 전 초안 줄');
    await waitSrvText(page, '서버 글\n죽기 전 초안 줄');
    const s = await srv(page);
    eq('draft: 복구된 글이 서버에 저장된다', s.text, '서버 글\n죽기 전 초안 줄');
    await page.waitForFunction(() => !localStorage.getItem('cmMemoDraft'));
    check('draft: 저장 확인 후에만 초안을 지운다', true);
    await ctx.close();
  }

  // [5] 로드 전 타이핑 — 서버 글을 지우지 않는다. 로드되는 순간 합쳐진다.
  {
    const { ctx, page } = await open('lateload');
    await set(page, '로드 전에 친 줄');
    // 로드가 안 됐으니 저장은 미뤄져야 한다(빈 base 로 서버를 덮으면 안 된다).
    await page.waitForTimeout(700);
    eq('lateload: 로드 전에는 서버에 쓰지 않는다', (await srv(page)).posts.length, 0);
    await page.evaluate(() => { window.__delayGet = false; window.__getWaiters.forEach((f) => f()); });
    await page.waitForFunction(() => __t() === '로드 전에 친 줄\n서버 글');
    await waitSrvText(page, '로드 전에 친 줄\n서버 글');
    check('lateload: 내 줄도 서버 글도 살아남는다', true);
    await ctx.close();
  }

  await browser.close();
  server.close();
  console.log(`\n${pass} pass, ${fail} fail`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
