const fs = require('node:fs');
const assert = require('node:assert/strict');
const { chromium } = require('../.e2e/node_modules/playwright');
function template(file) { return fs.readFileSync(file,'utf8').split('#"""')[1].split('"""#')[0]; }
const html = template('Sources/ConditionMate/Dashboard/LoopEngineeringContent.swift')
  .replace('\\#(SessionRail.html())','')
  .replace(/        \}\)\(\);\s*<\/script>/, 'window.__activity={sledGroup,sessListHTML,sessPanelHTML,usageHTML,setRange:r=>SLED_RANGE=r,setData:d=>{S=d;reveal=1000;}};})();</script>');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try {
  const page=await browser.newPage({viewport:{width:1600,height:1000}}), errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('http://loop.test/**',r=>r.fulfill(r.request().url()==='http://loop.test/'?{contentType:'text/html',body:html}:{json:{groups:[],loops:[],targets:[],resources:[],progress:{},ok:true}}));
  await page.goto('http://loop.test/');
  await page.waitForTimeout(300);
  const result=await page.evaluate(()=>{
    const {sledGroup,sessListHTML,sessPanelHTML,usageHTML,setRange,setData}=window.__activity;
    const g={key:'loop:example',kind:'loop',label:'Slack 공용 수신 · 번역 · 기본 응답',loopId:'condition-mate-slack-shared-reply',sessions:1,apiCalls:1,tokens:310,cost:3.1,projects:[],
      days:{'2026-09-18':{t:110,c:1.1},'2026-09-19':{t:200,c:2}},
      runs:[{sid:'session1',day:'2026-09-19',start:1789720000,end:1789810000,turns:4,tools:2,tokens:300,cost:3,days:{'2026-09-18':{t:100,c:1},'2026-09-19':{t:200,c:2}}},
      {sid:'api-1',source:'api',title:'gemini-test',day:'2026-09-18',start:1789720000,end:1789720000,tokens:10,cost:0.1}],ambiguousDays:{'2026-09-18':2}};
    setRange({preset:'custom',start:'2026-09-18',end:'2026-09-18'});
    const yesterday=sledGroup(g), list=sessListHTML(yesterday);
    setRange({preset:'custom',start:'2026-09-19',end:'2026-09-19'});
    const today=sledGroup(g);
    setRange({preset:'all',start:'',end:''});const all=sledGroup(g);
    setRange({preset:'custom',start:'2026-09-18',end:'2026-09-18'});
    setData({groups:[g],progress:{total:1,analyzed:1},apiLogUnreadable:false});
    document.getElementById('lpV2').innerHTML=sessPanelHTML();
    const usage=usageHTML({id:g.loopId,usageTotals:{total:10,costUSD:0.1,calls:1,pricedCalls:1}});
    return {yesterday,today,all,list,usage};
  });
  assert.ok(result.usage.includes('<div class="tok">310</div>'));
  assert.ok(!result.usage.includes('<div class="tok">320</div>'));
  assert.equal(result.yesterday.sessions,1);assert.equal(result.yesterday.apiCalls,1);
  assert.equal(result.yesterday.tokens,110);assert.equal(result.yesterday.runs[0].tokens,100);
  assert.equal(result.yesterday.ambiguous,2);
  assert.equal(result.today.sessions,1);assert.equal(result.today.apiCalls,0);assert.equal(result.today.tokens,200);
  assert.equal(result.all.tokens,310);assert.equal(result.all.sessions,1);
  assert.ok(result.list.includes('API · gemini-test'));
  assert.ok(!result.list.includes("lpToggleSess('api-1')"));
  assert.ok(result.list.includes('2026-09-18'));
  assert.deepEqual(errors,[]);
  await page.screenshot({path:'issue/2026-09-19-loop-activity/ui-regression.png',fullPage:true});
  console.log('loop activity UI: multi-day filtering, separate API count, totals, rendering passed');
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
