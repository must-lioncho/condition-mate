const fs=require('node:fs'),assert=require('node:assert/strict');
const {chromium}=require('../.e2e/node_modules/playwright');
const source=fs.readFileSync('Sources/Plugins/Slack/SlackTranslateContent.swift','utf8');
const fn=source.slice(source.indexOf('        function aiUsageHTML('),source.indexOf('        function tabBodyHTML('));
(async()=>{
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage({viewport:{width:950,height:1050}});
  await page.setContent('<body style="background:#151820;color:#ddd;font:14px system-ui;padding:24px"><main></main></body>');
  await page.addScriptTag({content:'function esc(s){const d=document.createElement("div");d.textContent=s||"";return d.innerHTML;}function ackState(it){return {sent:!!it.ackTs};}'+fn});
  const result=await page.evaluate(()=>{
   const old=aiUsageHTML({ackTs:'1',model:'translation-model'}),unsent=aiUsageHTML({});
   const item={ackTs:'1',ackAI:{calls:[{model:'gemini-resolved',requestedModel:'gemini-alias',modelResolved:true,transport:'api',effort:{state:'not-set'},context:{inputLimit:1000000,usedInput:1200,outputLimit:65536},tokens:{input:1200,output:100,reasoning:30,cached:0,total:1330}},
    {model:'<img src=x onerror="window.injected=true">',transport:'cli',effort:{state:'unknown'},context:{window:200000,usedInput:null},tokens:{input:100,output:10,total:110}}]}};
   const html=aiUsageHTML(item);document.querySelector('main').innerHTML=html;
   return {html,old,unsent,text:document.querySelector('main').textContent};
  });
  assert.ok(result.old.includes('기록되지 않았습니다'));assert.ok(!result.old.includes('translation-model'));
  assert.ok(result.unsent.includes('게시된 AI 답변이 없습니다'));
  for(const text of ['gemini-resolved','1,440','1,000,000','0.12%','API 기본값','단일 요청 사용량 미제공','미확인 · CLI 내부 설정'])assert.ok(result.text.includes(text),text);
  assert.equal(await page.evaluate(()=>window.injected),undefined);
  assert.equal(await page.locator('img').count(),0);
  await page.screenshot({path:'issue/2026-09-19-reply-ai-metadata/ui-fixture.png'});
  // Parse every actual inline script, not only the isolated renderer.
  const html=source.split('#"""')[1].split('"""#')[0];
  for(const match of html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g))new (require('node:vm').Script)(match[1]);
  console.log('PASS internal AI panel: counts, context, effort, legacy, unsent, escaping, full script syntax');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
