const D = process.argv[2];
const { scaffoldLeaks, sensitiveContext, echoRatio } = await import(`${D}/send-layer.mjs`);
const POL = [`${D}/slack-sensitive-policy.json`];
let pass = 0, fail = 0;
const t = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  ok ? pass++ : fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `\n        got  ${JSON.stringify(got)}\n        want ${JSON.stringify(want)}`}`);
};

// ---------- scaffolding leak ----------
const leaked = `This is an automated agent response. It should still be very helpful.
Purpose: Inform that converting and signing the notice is difficult...
Intent · request_assistance: The sender acknowledges a notice from Maryam Mansha...
Define problem: Converting the notice document for signature causes the loss of watermarks.
Alignment: NO`;
t('incident body: every scaffold label caught',
  scaffoldLeaks(leaked).sort(),
  ['Alignment', 'Define problem', 'Intent', 'Purpose', 'automated-agent-declaration']);

t('KO v1 body caught',
  scaffoldLeaks('에이전트 자동 응답입니다. 하지만 매우 도움이 될 것입니다.\n목적: 어쩌구\n부합 여부: NO').sort(),
  ['automated-agent-declaration', '목적', '부합 여부']);

t('v2 body is clean', scaffoldLeaks(
  'Read as: *request_assistance*\nThis is an agent answer for now.\n\n*What this means*\nHe asks for an editable URL.'), []);

t('normal prose using the word purpose mid-sentence is clean',
  scaffoldLeaks('The purpose of this change is to keep the watermark. Alignment with the spec is fine.'), []);

t('Maryam real answer is clean',
  scaffoldLeaks('You can simply download the attached PDF, add your signature to it, and send it back here.'), []);

// ---------- sensitive context ----------
// The real incident: Hamilton's own text has no "PIP"; the daemon's 8-message
// context window holds exactly Maryam's PIP notice + the four PIP PDFs.
const hamilton = `Thank you @Maryam Mansha for the notice
I am still reviewing and processing documents...
To convert the Notice and sign is a bit difficult.
Would appreciate a url that I can have edit permission in order to sign.`;
const realCtx = `[Slack recent channel context — may contain mixed topics; not a thread]
Maryam Mansha: Hi <@U0A2J0Z9D89>  This is to formally inform you that a two-week PIP will begin today, August 31, and continue through September 13, 2026. First, I want to mak…`;

t('message alone does NOT contain the signal (this is why context matters)',
  sensitiveContext({ text: hamilton, policyFiles: POL }).domain, null);

const real = sensitiveContext({
  channelName: '그룹 DM · m.maryam, silkstone, cardinal, green, iris',
  text: hamilton, context: realCtx, policyFiles: POL,
});
t('REAL INCIDENT blocked via context', [real.domain, real.where, real.hit], ['hr', 'context', 'PIP']);

const viaFile = sensitiveContext({
  text: 'please sign', files: [{ name: 'PIP Notice Hamilton .docx.pdf' }], policyFiles: POL });
t('blocked via attachment name', [viaFile.domain, viaFile.where], ['hr', 'attachment']);

t('salary talk blocked', sensitiveContext({ text: '연봉 조정 관련해서', policyFiles: POL }).domain, 'compensation');
t('lawsuit blocked', sensitiveContext({ text: 'Their counsel sent a cease and desist', policyFiles: POL }).domain, 'legal');

// false positives — these must stay sendable
t('pip install NOT blocked', sensitiveContext({ text: 'run pip install -r requirements.txt', policyFiles: POL }).domain, null);
t('pip3 NOT blocked', sensitiveContext({ text: 'use pip3 to install it', policyFiles: POL }).domain, null);
t('ordinary standup NOT blocked',
  sensitiveContext({ text: 'Can you review PR 412 before the deploy?', context: 'we shipped the fix', policyFiles: POL }).domain, null);
t('mixed message: pip install does not shield a real PIP notice',
  sensitiveContext({ text: 'first run pip install foo, and about the PIP notice you sent', policyFiles: POL }).domain, 'hr');
t('no policy file -> no opinion', sensitiveContext({ text: 'PIP', policyFiles: ['/nope.json'] }).domain, null);

// ---------- echo (metric only) ----------
const e = echoRatio(leaked, hamilton);
console.log(`\nINFO  echo(incident body vs message) = ${e}  (recorded, never blocking)`);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
