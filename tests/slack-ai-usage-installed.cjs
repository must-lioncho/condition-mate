// Installed HTML + browser-only fixture; no Slack messages and no store writes.
const fs=require('node:fs'),os=require('node:os'),assert=require('node:assert/strict');
const {chromium}=require('../.e2e/node_modules/playwright');
(async()=>{
 const base='http://127.0.0.1:'+fs.readFileSync(os.homedir()+'/.condition-mate/dashboard.port','utf8').trim();
 const html=await(await fetch(base+'/slack-translate')).text();assert.ok(html.includes('function aiUsageHTML('));
 const t=Math.floor(Date.now()/1000);
 const item={id:'ui-verification-only',channel:'test',channelName:'UI 검증 (모의 데이터)',source:'mention',ts:String(t),reactedAt:t,translatedAt:t,author:'검증 항목',textEn:'Test request',textKo:'검증 요청',ackTs:'fixture',ackBody:'검증 답변',ackAt:t,ackAI:{calls:[{model:'gemini-test-fixture',modelResolved:true,transport:'api',effort:{state:'not-set'},context:{inputLimit:1048576,usedInput:1283,outputLimit:65536},tokens:{input:1283,output:178,total:1461,reasoning:null,cached:0}}]}};
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage({viewport:{width:1450,height:1100}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route(base+'/**',r=>{
   const path=new URL(r.request().url()).pathname;
   if(path==='/slack-translate')return r.fulfill({contentType:'text/html',body:html});
   if(path==='/api/slack/items')return r.fulfill({json:{items:[item],done:{},replies:{},gui:{},syncErr:{},myRx:{},sources:{mention:true},quick:[]}});
   return r.fulfill({json:{ok:true,items:[],channels:[]}});
  });
  await page.goto(base+'/slack-translate');
  await page.locator('#fAi').click();
  const card=page.locator('.item[data-id="ui-verification-only"]');await card.waitFor();
  await card.click();await card.locator('.tabs button').filter({hasText:'AI 실행'}).click();
  await card.locator('.tabbody').getByText('gemini-test-fixture',{exact:false}).waitFor();
  const text=await card.locator('.tabbody').innerText();assert.ok(text.includes('1,461'));assert.ok(text.includes('1,048,576'));
  await card.screenshot({path:'issue/2026-09-19-reply-ai-metadata/installed-ui-fixture.png'});
  assert.deepEqual(errors,[]);
  console.log('PASS installed AI tab (browser-only fixture), no outbound requests');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
