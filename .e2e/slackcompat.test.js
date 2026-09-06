// E2E for items.jsonl 하위 호환 — 실제 코퍼스 사본에 실제 rewriteItem 을 돌린다.
// 원본(~/.condition-mate/slack-translate/items.jsonl)은 읽고 복사만 하며 절대 쓰지 않는다.
// 새 필드(media/mediaAt/trNote)는 전부 선택 항목이어야 하고, 그 필드가 없는 옛 줄을
// 읽는 쪽이 멈추면 안 된다. 검증 대상:
//   - 코퍼스 전 줄이 JSON 으로 파싱된다 (한 줄도 깨지지 않았다)
//   - 새 필드가 없는 옛 줄이 여전히 남아 있고, 읽는 쪽이 기본값으로 넘어간다
//   - rewriteItem 이 대상 한 줄만 패치하고 나머지는 바이트 단위로 그대로다 (append 아님)
//   - 값이 undefined 인 패치는 키 자체를 만들지 않는다
//   - 패치된 줄의 기존 필드는 하나도 바뀌지 않는다
//   - 검증이 끝난 뒤 원본 파일의 크기·수정시각이 그대로다 (사본만 건드렸다)
// 코퍼스가 없는 환경(CI 등)에서는 통째로 건너뛰고 그 사실을 출력한다.
const { readFileSync, writeFileSync, renameSync, copyFileSync, statSync, mkdtempSync, rmSync } = require('node:fs');
const { tmpdir, homedir } = require('node:os');
const { join } = require('node:path');

const SRC = readFileSync(__dirname + '/../Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs', 'utf8');
const LIVE = join(homedir(), '.condition-mate/slack-translate/items.jsonl');

function fn(name) {
  let start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  if (SRC.slice(start - 6, start) === 'async ') start -= 6;
  let paren = 0, i = SRC.indexOf('(', start);
  for (; i < SRC.length; i++) { if (SRC[i] === '(') paren++; else if (SRC[i] === ')') { paren--; if (!paren) break; } }
  let d = 0;
  for (let k = SRC.indexOf('{', i); k < SRC.length; k++) {
    if (SRC[k] === '{') d++; else if (SRC[k] === '}') { d--; if (!d) return SRC.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

let fails = 0;
const ok = (c, m, extra) => { console.log((c ? '  ok   ' : '  FAIL ') + m + (extra ? '  ' + extra : '')); if (!c) fails++; };

let liveStat = null;
try { liveStat = statSync(LIVE); } catch {}
if (!liveStat) {
  console.log(`  skip 실제 코퍼스가 없어 건너뛴다 (${LIVE})`);
  console.log('\nall passed (skipped)');
  process.exit(0);
}

const dir = mkdtempSync(join(tmpdir(), 'slackcompat-'));
const ITEMS_FILE = join(dir, 'items.jsonl');
copyFileSync(LIVE, ITEMS_FILE);

const raw = readFileSync(ITEMS_FILE, 'utf8');
const lines = raw.split('\n').filter((l) => l.trim());
const parsed = [];
let bad = 0;
for (const l of lines) { try { parsed.push(JSON.parse(l)); } catch { bad++; } }
ok(bad === 0, `기존 ${lines.length}줄이 전부 JSON으로 파싱된다 (실패 ${bad}건)`);

// 새 필드는 선택 항목이다. 데몬이 돌면서 새 줄에는 media/trNote가 붙지만, 그 필드가
// 없는 옛 줄이 계속 남아 있어야 하고 읽는 쪽은 둘을 함께 읽어야 한다. 예전 판(版)은
// "코퍼스에 그 필드가 하나도 없다"를 단언했는데, 배포 뒤에는 당연히 거짓이 된다 —
// 스냅숏이 아니라 규칙을 검사한다.
const NEWF = ['media', 'mediaAt', 'trNote'];
const old = parsed.filter((o) => NEWF.every((k) => o[k] === undefined));
const withNew = parsed.filter((o) => NEWF.some((k) => o[k] !== undefined));
ok(old.length > 0, `새 필드가 없는 옛 줄이 ${old.length}줄 남아 있다 (신·구가 한 파일에 섞여 산다: 새 필드 있는 줄 ${withNew.length}줄)`);

// 새 필드가 없는 줄을 읽는 쪽 — 데몬 자신의 loadState/loadItems가 쓰는 접근 그대로.
let readerErr = '';
try {
  for (const o of parsed) {
    const rows = o.media || [];           // 없으면 빈 배열 — 읽는 쪽에 판단을 미루지 않는다
    const at = o.mediaAt || 0;
    const note = o.trNote || '';
    void note.split(',');
    if (rows.length && !Number.isFinite(at)) throw new Error('bad mediaAt');
    void rows.map((r) => r.type);
  }
} catch (e) { readerErr = e.message; }
ok(!readerErr, 'media/mediaAt/trNote가 없는 옛 줄을 읽어도 읽는 쪽이 멈추지 않는다', readerErr);

// 실제 rewriteItem으로 media 패치를 넣어 본다.
const ctx = { ITEMS_FILE, readFileSync, writeFileSync, renameSync };
const { rewriteItem } = new Function(...Object.keys(ctx),
  fn('rewriteItem') + '\nreturn { rewriteItem };')(...Object.values(ctx));

// 대상은 아직 새 필드가 없는 줄에서 고른다 — 이미 붙은 줄을 덮으면 "기존 필드 무변경"
// 검사가 자기 자신을 검사하게 된다.
if (old.length < 2) { console.log('  skip 새 필드가 없는 줄이 2줄 미만이라 패치 검사를 건너뛴다'); }
const target = old[old.length - 1].id;
const other = old[0].id;
const beforeObj = old[old.length - 1];
const beforeOther = old[0];

rewriteItem(target, {
  media: [{ type: 'image', name: 'a.png', method: 'gemini-vision', text: '차트' }],
  mediaAt: 1787900000,
  trNote: 'retried,kept-original',
});
// 첨부가 없는 항목은 undefined 패치 → 키가 생기지 않아야 한다.
rewriteItem(other, { media: undefined, mediaAt: undefined, trNote: undefined });

const after = readFileSync(ITEMS_FILE, 'utf8').split('\n').filter((l) => l.trim());
let bad2 = 0;
const reparsed = [];
for (const l of after) { try { reparsed.push(JSON.parse(l)); } catch { bad2++; } }
ok(bad2 === 0 && reparsed.length === parsed.length,
  `패치 후에도 ${reparsed.length}줄 전부 파싱된다 (줄 수 유지)`);
const t2 = reparsed.find((o) => o.id === target);
ok(t2.media?.[0]?.type === 'image' && t2.mediaAt === 1787900000 && t2.trNote === 'retried,kept-original',
  'media/mediaAt/trNote가 그 줄에만 붙는다');
const o2 = reparsed.find((o) => o.id === other);
ok(!('media' in o2) && !('mediaAt' in o2) && !('trNote' in o2), '해당 없으면 키 자체가 생기지 않는다');
ok(JSON.stringify(o2) === JSON.stringify(beforeOther), '첨부 없는 줄은 바이트 단위로 그대로다');

// 나머지 줄이 전부 원본과 동일한지
let changed = 0;
for (let i = 0; i < parsed.length; i++) {
  if (parsed[i].id === target) continue;
  if (JSON.stringify(parsed[i]) !== JSON.stringify(reparsed[i])) changed++;
}
ok(changed === 0, `대상 1줄 말고는 ${parsed.length - 1}줄이 전부 무변경 (변경 ${changed}건)`);

// 패치된 줄에서 기존 필드가 모두 살아 있는지
const missing = Object.keys(beforeObj).filter((k) => JSON.stringify(t2[k]) !== JSON.stringify(beforeObj[k]));
ok(missing.length === 0, '패치된 줄의 기존 필드는 하나도 바뀌지 않았다', missing.join(','));

// 원본 무변경 — 앞에서 잰 것과 끝에서 잰 것을 비교한다(같은 값끼리 비교하면 검사가 아니다).
const liveAfter = statSync(LIVE);
ok(liveAfter.size === liveStat.size && liveAfter.mtimeMs === liveStat.mtimeMs,
  '원본 items.jsonl은 크기·수정시각이 그대로다 (사본만 썼다)',
  `${liveStat.size}B/${liveStat.mtimeMs} → ${liveAfter.size}B/${liveAfter.mtimeMs}`);

rmSync(dir, { recursive: true, force: true });
console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
