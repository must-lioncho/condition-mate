import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { captureReplyUsage, recordReplyUsage, replyUsageID, geminiReplyUsage, anthropicReplyUsage, cliReplyUsage, replyModelLimits } from './reply-ai-usage.mjs';
import { renderNote } from './ack-note.mjs';
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
test('concurrent replies and retries remain isolated; late results excluded', async()=>{
  const run=(id,ms)=>captureReplyUsage(id,async()=>{await delay(ms);assert.equal(replyUsageID(),id);recordReplyUsage({model:id});recordReplyUsage({model:id+'-retry'});setTimeout(()=>recordReplyUsage({model:'late'}),10);return 'body';});
  const [a,b]=await Promise.all([run('a',15),run('b',1)]);await delay(30);
  assert.deepEqual(a.usage.calls.map(c=>c.model),['a','a-retry']);assert.deepEqual(b.usage.calls.map(c=>c.model),['b','b-retry']);
  assert.equal(replyUsageID(),'');assert.equal(a.value,'body');
});
test('Gemini actual model, thinking, zero and unknown are distinct',()=>{
  const c=geminiReplyUsage({modelVersion:'resolved',usageMetadata:{promptTokenCount:100,candidatesTokenCount:20,thoughtsTokenCount:5,cachedContentTokenCount:0,totalTokenCount:125}},'alias',{inputTokenLimit:1000,outputTokenLimit:100});
  assert.equal(c.model,'resolved');assert.equal(c.tokens.total,125);assert.equal(c.tokens.cached,0);assert.equal(c.context.usedInput,100);assert.equal(c.effort.state,'not-set');
  assert.equal(geminiReplyUsage({},'alias').tokens.total,null);
});
test('Anthropic counts cache only once, CLI does not call cumulative input context usage',()=>{
 const c=anthropicReplyUsage({model:'resolved',usage:{input_tokens:10,output_tokens:20,cache_read_input_tokens:30,cache_creation_input_tokens:40}},'alias',{max_input_tokens:200000});
 assert.equal(c.tokens.input,80);assert.equal(c.tokens.total,100);
 const [cli]=cliReplyUsage({modelUsage:{actual:{inputTokens:10,outputTokens:20,cacheReadInputTokens:30,contextWindow:200000}}},'alias');
 assert.equal(cli.tokens.input,40);assert.equal(cli.context.usedInput,null);assert.equal(cli.context.window,200000);assert.equal(cli.effort.state,'unknown');
});
test('limits use provider metadata; failures yield unknown without stopping reply',async()=>{
 await captureReplyUsage('x',async()=>{
  let n=0;const mock=async()=>{n++;return {ok:true,json:async()=>({inputTokenLimit:1000,outputTokenLimit:200})};};
  assert.equal((await replyModelLimits('gemini','test-model','secret',mock)).inputTokenLimit,1000);
  await replyModelLimits('gemini','test-model','secret',mock);assert.equal(n,1);
  assert.deepEqual(await replyModelLimits('gemini','bad-model','secret',async()=>{throw Error('failure');}),{});
 });
});
test('public MD is byte-identical even if telemetry is present',()=>{
 const note={sent:'확인했습니다.',detail:'근거',at:new Date(0),audience:'thread'};
 assert.equal(renderNote(note),renderNote({...note,ackAI:{calls:[{model:'private',tokens:{total:100}}]}}));
 const source=readFileSync(new URL('./slack-eyes-daemon.mjs',import.meta.url),'utf8');
 assert.ok(source.includes('ackAI: captured.usage'));
 assert.ok(source.indexOf('ackAI: captured.usage')>source.indexOf('const res = await slack(\'chat.postMessage\'',source.indexOf('async function postAcknowledgement')));
});
test('real Gemini provider binds reply ID and usage without changing output',async()=>{
 const vm=await import('node:vm');
 const source=readFileSync(new URL('./slack-eyes-daemon.mjs',import.meta.url),'utf8');
 const body=source.slice(source.indexOf('async function translateGemini('),source.indexOf('// Anthropic Messages API direct'));
 const actions=[];
 const ctx=vm.createContext({recordReplyUsage,geminiReplyUsage,replyUsageID,replyModelLimits:async()=>({inputTokenLimit:1000}),geminiKey:'test',AbortSignal,
  act:(name,data)=>actions.push({name,data}),fetch:async()=>({ok:true,json:async()=>({modelVersion:'actual-version',usageMetadata:{promptTokenCount:100,candidatesTokenCount:20,totalTokenCount:120},candidates:[{content:{parts:[{text:'unchanged answer'}]}}]})})});
 vm.runInContext(body,ctx);
 const captured=await captureReplyUsage('message-A',()=>ctx.translateGemini('alias','private prompt'));
 assert.equal(captured.value,'unchanged answer');assert.equal(captured.usage.calls[0].model,'actual-version');
 assert.equal(actions[0].data.id,'message-A');assert.equal(captured.usage.calls[0].tokens.total,120);
 assert.ok(!JSON.stringify(captured.usage).includes('private prompt'));
});
