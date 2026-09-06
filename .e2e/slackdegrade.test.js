// E2E for media-extract 모듈 유무에 따른 degrade — 데몬 소스를 임시 디렉터리로 복사해
// main() 호출만 떼고 실제로 import 한다(동적 import 의 경로 해석까지 진짜로 돈다).
// 첨부 텍스트 추출은 별도 모듈(media-extract.mjs)이 하고 데몬은 그것을 불러 쓰기만 하므로,
// 모듈이 없거나 계약을 어겨도 데몬은 절대 죽지 않고 텍스트 전용으로 내려앉아야 한다.
// 검증 대상:
//   - 모듈 없음: evidence 는 빈 배열, notes 에 사유, 원문의 첨부 표시는 그대로, 예외 없음
//   - 모듈 있음: 근거가 프롬프트에 실리고 method 는 남되 base64 는 items 에 안 들어간다
//   - 모듈이 던짐: extract-failed 로 살아남고 로컬 참조 수집으로 폴백한다
//   - 모듈 export 가 계약과 다름: 아예 안 쓴다 (mediaModule() === null)
// 이 경로가 실제로 이렇게 동작한 덕분에, 앱 번들에 media-extract.mjs 가 빠졌던 배포
// 결함이 크래시 없이 "첨부가 이름·링크만 남는다"로 드러났다.
const { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync, copyFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');

let SRC = readFileSync(__dirname + '/../Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs', 'utf8');
const cut = SRC.indexOf('main().catch(');
if (cut < 0) throw new Error('main() 호출을 못 찾음');
SRC = SRC.slice(0, cut)
  + 'export { mediaEvidence, mediaModule, composeSource, hasAttachmentOrLink, mediaRows, translatePrompt };\n';

let fails = 0;
const ok = (c, m, extra) => { console.log((c ? '  ok   ' : '  FAIL ') + m + (extra ? '  ' + extra : '')); if (!c) fails++; };

const imageMsg = { text: '이거 확인해줘', files: [{ name: 'shot.png', mimetype: 'image/png', url_private: 'https://files.slack.com/x', size: 10 }] };

// 데몬은 DATA_DIR 를 모듈 최상단에서 한 번 읽는다 — import 전에 임시 자리를 잡아 준다.
function stage(prefix, extract) {
  const d = mkdtempSync(join(tmpdir(), prefix));
  process.env.CM_DATA_DIR = join(d, 'data');
  mkdirSync(join(d, 'data', 'slack-translate'), { recursive: true });
  writeFileSync(join(d, 'daemon.mjs'), SRC);
  // 데몬이 정적으로 import 하는 동반 모듈들을 같은 자리에 둔다. 없으면 import 단계에서
  // ERR_MODULE_NOT_FOUND 로 죽어 이 시험이 무엇도 검사하지 못한다.
  for (const companion of ['alignment-engine.mjs', 'emoji-layer.mjs', 'send-layer.mjs', 'reply-language.mjs',
    'novelty-gate.mjs', 'ack-note.mjs', 'slack-ack-cost-policy.json',
    'slack-problem-framing-policy.json', 'slack-sensitive-policy.json']) {
    copyFileSync(join(__dirname, '../Sources/Plugins/Slack/Daemon', companion), join(d, companion));
  }
  if (extract) writeFileSync(join(d, 'media-extract.mjs'), extract);
  return d;
}

(async () => {

// --- 1. 모듈이 없는 디렉터리
const d1 = stage('noext-');
const m1 = await import(pathToFileURL(join(d1, 'daemon.mjs')).href);
const r1 = await m1.mediaEvidence(imageMsg, 'C1:1');
ok(Array.isArray(r1.evidence) && r1.evidence.length === 0, '모듈 없음: evidence는 빈 배열 (예외 없음)');
ok(r1.notes.includes('extractor-unavailable'), '모듈 없음: notes에 사유가 남는다', JSON.stringify(r1.notes));
ok(r1.refs.length === 1 && r1.refs[0].kind === 'file', '모듈 없음: 로컬 참조 수집으로 폴백');
ok(await m1.mediaModule() === null, '모듈 없음: mediaModule()이 null을 돌려주고 던지지 않는다');
ok(m1.mediaRows(r1.evidence, r1.refs)[0].error === 'extractor-unavailable', '모듈 없음: 첨부 흔적만 items에 남는다');
ok((await m1.composeSource(imageMsg)).includes('[이미지] shot.png'), '모듈 없음: 원문에 첨부 표시는 그대로 남는다');

// --- 2. 계약대로 동작하는 모듈이 있는 디렉터리
const d2 = stage('ext-', `
export function collectRefs(msg) {
  return (msg.files || []).map((f) => ({ kind: 'file', url: f.url_private, mimetype: f.mimetype, name: f.name, size: f.size }));
}
export async function extractEvidence(refs, opts) {
  globalThis.__seenOpts = Object.keys(opts).sort().join(',');
  return { evidence: refs.map((r) => ({ ref: r, type: 'image', text: 'OCR: 오늘 배포 중단', method: 'gemini-vision', inline: [{ mimeType: 'image/png', dataB64: 'QUJD' }] })), notes: [] };
}
`);
const m2 = await import(pathToFileURL(join(d2, 'daemon.mjs')).href);
const r2 = await m2.mediaEvidence(imageMsg, 'C1:2');
ok(r2.evidence.length === 1 && r2.evidence[0].text.includes('OCR'), '모듈 있음: evidence가 그대로 들어온다');
ok(globalThis.__seenOpts === 'cacheDir,geminiKey,geminiModel,slackToken,timeoutMs',
  '모듈에 넘기는 opts가 계약과 같다', globalThis.__seenOpts);
ok(m2.translatePrompt('t', '', 'ko', r2.evidence).includes('OCR: 오늘 배포 중단'), '모듈 있음: 근거가 프롬프트에 실린다');
const rows2 = m2.mediaRows(r2.evidence, r2.refs);
ok(rows2[0].method === 'gemini-vision' && !JSON.stringify(rows2).includes('QUJD'),
  '모듈 있음: method는 남고 base64는 items에 안 들어간다', JSON.stringify(rows2));

// --- 3. 계약을 어기고 던지는 모듈
const d3 = stage('bad-', `
export function collectRefs(msg) { throw new Error('collectRefs boom xoxp-1111-LEAK'); }
export async function extractEvidence() { throw new Error('extract boom'); }
`);
const m3 = await import(pathToFileURL(join(d3, 'daemon.mjs')).href);
// 모듈이 던진 예외 메시지에 토큰처럼 생긴 것이 섞여 있어도 로그로 새면 안 된다 —
// 데몬이 찍는 줄을 실제로 가로채서 본다.
const seen = [];
const realWrite = process.stdout.write.bind(process.stdout);
process.stdout.write = (chunk, ...rest) => { seen.push(String(chunk)); return realWrite(chunk, ...rest); };
let r3;
try { r3 = await m3.mediaEvidence(imageMsg, 'C1:3'); } finally { process.stdout.write = realWrite; }
const logged = seen.join('');
ok(r3.notes.includes('extract-failed'), '모듈이 던져도 데몬은 살아남는다 (extract-failed)', JSON.stringify(r3.notes));
ok(r3.refs.length === 1, 'collectRefs가 던지면 로컬 수집으로 폴백한다');
ok(!logged.includes('xoxp-1111-LEAK') && logged.includes('[redacted]'),
  '모듈 예외 메시지에 섞인 토큰은 로그에 찍히기 전에 가려진다');
ok(!JSON.stringify(r3).includes('xoxp-1111-LEAK'), '그 토큰이 evidence/notes 로도 새지 않는다');

// --- 4. 계약을 어기고 export가 없는 모듈
const d4 = stage('empty-', 'export const nothing = 1;\n');
const m4 = await import(pathToFileURL(join(d4, 'daemon.mjs')).href);
ok(await m4.mediaModule() === null, 'export가 계약과 다르면 모듈을 안 쓴다 (텍스트 전용으로 degrade)');

for (const d of [d1, d2, d3, d4]) rmSync(d, { recursive: true, force: true });
console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
})();
