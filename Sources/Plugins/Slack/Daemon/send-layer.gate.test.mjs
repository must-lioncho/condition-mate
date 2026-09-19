const D = process.argv[2];
const ae = await import(`${D}/alignment-engine.mjs`);
const POL = [`${D}/slack-sensitive-policy.json`];

const hamilton = `Thank you @Maryam Mansha for the notice
I am still reviewing and processing documents...
To convert the Notice and sign is a bit difficult.
Reason; converted document I want to sign loses all the watermarks and logo of MUST Company
Would appreciate a url that I can have edit permission in order to sign.`;
const ctx = `[Slack recent channel context — may contain mixed topics; not a thread]
Maryam Mansha: Hi <@U0A2J0Z9D89>  This is to formally inform you that a two-week PIP will begin today, August 31…`;
const leaked = `This is an automated agent response. It should still be very helpful.
Purpose: Inform that converting and signing the notice is difficult...
Intent · request_assistance: The sender acknowledges a notice from Maryam Mansha...
Define problem: Converting the notice document causes loss of watermarks.
Alignment: NO`;
// what v2 would post after a restart — no field names, but still a restatement plus
// the wrong "likely decision" that Maryam corrected a minute later.
const v2body = `Read as: *request_assistance*
This is an agent answer for now. A final decision will follow shortly.

*What this means*
Hamilton asks for an editable URL so he can sign the notice without losing the watermark.

*Likely decision*
1) Find and share an editable document URL so he can sign
→ Option 1 is the most likely`;
// evidence layers exactly as the ledger recorded them: research only, no notion docs
const extra = {
  notion: '[Notion lookup] 스레드에 공유된 노션 링크가 없음',
  research: '[Web research · genspark · 공개 웹 자료]\n질의: pdf sign watermark\nhttps://x.test/a',
  glossary: '[용어집] 이 대화에 해당하는 이름 대응 없음',
};
const base = {
  analysis: { confidence: 0.92 }, extra, jira: '',
  channelName: '그룹 DM · m.maryam, silkstone, cardinal, green, iris',
  sourceText: hamilton, context: ctx, sensitivePolicyFiles: POL,
  requestLevel: 3, noRequestSignal: false,
};

const show = (name, g) => console.log(
  `${g.send ? 'SENT  ' : 'BLOCKED'}  ${name}\n          reasons=[${g.reasons.join(', ')}]`);

console.log('--- the incident, replayed through the real gate ---');
show('v1 body (what actually went out)', ae.ackSendGate({ ...base, body: leaked }));
show('v2 body (what a restart would have sent)', ae.ackSendGate({ ...base, body: v2body }));

console.log('\n--- the gate must not become a switch: ordinary traffic still sends ---');
const okCtx = 'Piyush: can you look at the deploy config';
show('ordinary question, clean body', ae.ackSendGate({
  ...base, channelName: '#must-matchhire', sourceText: 'Can you review PR 412 before the deploy?',
  context: okCtx, body: 'Read as: *review request*\n\n*What this means*\nHe wants PR 412 reviewed before deploy.' }));
show('pip install question (must not trip the HR gate)', ae.ackSendGate({
  ...base, channelName: '#eng', sourceText: 'the build fails on pip install -r requirements.txt',
  context: 'CI is red', body: 'Read as: *build failure*\n\n*What this means*\nThe dependency install step fails.' }));

console.log('\n--- the older gates still work ---');
show('low confidence', ae.ackSendGate({ ...base, channelName: '#eng',
  sourceText: 'ping', context: '', analysis: { confidence: 0.61 }, body: 'Read as: *ping*' }));
show('evidence lookup failed', ae.ackSendGate({ ...base, channelName: '#eng',
  sourceText: 'see the doc', context: '', body: 'Read as: *question*',
  extra: { notion: '[Notion lookup] unavailable — 노션 통합 토큰이 없음' } }));
