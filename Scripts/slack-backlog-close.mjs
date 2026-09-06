#!/usr/bin/env node
// slack-backlog-close.mjs — items.jsonl 한 번 쓰는 오프라인 이전(移轉) 도구.
//
// 두 가지를 한다.
//   (a) 백로그 마감 — requestLevel/ackGrade 부여 파이프라인이 들어오기(2026-08-29)
//       전에 수집돼 등급조차 못 받은 미처리 항목에 backlogClosedAt 을 찍는다.
//       AI가 판단한 적이 없는 줄이 화면 맨 앞을 막고 있어서, 사람이 하나씩 넘길
//       것이 아니라 한 번에 "이건 그 시절 것" 으로 표시하고 치운다.
//   (b) autoByMe 백필 — 이미 쌓인 autoBy 를 "내가 누른 것" / "남이 누른 것" 으로
//       가른다. 데몬은 앞으로 붙는 것에만 이 필드를 쓰므로 옛 줄은 여기서 채운다.
//
// 슬랙에 아무것도 보내지 않는다. API 를 부르지 않고 토큰을 읽지 않는다. done.json
// 도 건드리지 않는다 — done.json 을 바꾸면 앱이 슬랙 리액션 동기화를 시도한다.
// 이 스크립트가 쓰는 파일은 items.jsonl 하나뿐이다.
//
// 기본값이 dry-run 인 이유는, 되돌릴 수 있게 만들어도 되돌리는 것보다 안 쓰는
// 쪽이 항상 싸기 때문이다. 실제로 쓰려면 --apply 를 명시해야 한다.
//
//   node Scripts/slack-backlog-close.mjs                 # dry-run (기본)
//   node Scripts/slack-backlog-close.mjs --apply
//   node Scripts/slack-backlog-close.mjs --undo --apply  # 원상복구
//   node Scripts/slack-backlog-close.mjs --me U03GRE909MJ

import { copyFileSync, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const DATA_DIR = process.env.CM_DATA_DIR || join(homedir(), '.condition-mate');
const OUT_DIR = join(DATA_DIR, 'slack-translate');
const ITEMS_FILE = join(OUT_DIR, 'items.jsonl');
const DONE_FILE = join(OUT_DIR, 'done.json');
const SELF_FILE = join(OUT_DIR, 'self.json');

// 등급 파이프라인 도입 시각. 이보다 앞선 수집분은 requestLevel/ackGrade 가 구조적으로
// 0건이다 — 등급이 없는 것이 그 줄의 잘못이 아니라 그때 기능이 없었던 것이다.
const CUTOFF = Math.floor(Date.parse('2026-08-29T00:00:00Z') / 1000);
const REASON = 'pre-grading-pipeline';

const argv = process.argv.slice(2);
const APPLY = argv.includes('--apply');
const UNDO = argv.includes('--undo');
const meArg = (() => {
  const i = argv.indexOf('--me');
  return i >= 0 ? argv[i + 1] : null;
})();

function log(...a) { console.log(...a); }

// 값이 "없다" 의 판정. null·undefined·빈 문자열을 한 묶음으로 본다. 0 은 있는
// 값으로 친다 — requestLevel 0 은 "등급 없음" 이 아니라 "0등급" 이다.
function absent(v) { return v === undefined || v === null || v === ''; }

// 트리거 시각. 필드마다 채워지는 시점이 달라 하나만 보면 옛 줄이 통째로 빠진다.
// 처음 발견되는 값을 쓰고, 숫자로 읽히지 않으면 시각을 모르는 것으로 둔다.
function triggerEpoch(o) {
  for (const k of ['triggeredAt', 'reactedAt', 'ts', 'msgAt']) {
    if (absent(o[k])) continue;
    const n = Number(o[k]);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return null;
}

function loadDone() {
  if (!existsSync(DONE_FILE)) return {};
  try { return JSON.parse(readFileSync(DONE_FILE, 'utf8')) || {}; } catch { return {}; }
}

function loadMe() {
  if (meArg) return meArg;
  if (!existsSync(SELF_FILE)) return null;
  try { return JSON.parse(readFileSync(SELF_FILE, 'utf8')).userId || null; } catch { return null; }
}

function stamp() {
  const d = new Date();
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}`
    + `-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function main() {
  if (!existsSync(ITEMS_FILE)) {
    console.error(`no items file: ${ITEMS_FILE}`);
    process.exit(1);
  }
  const done = loadDone();
  const me = loadMe();
  const now = Math.floor(Date.now() / 1000);

  // 줄 단위로 보존한다. split('\n') 의 마지막 빈 원소까지 그대로 두고 join 하므로
  // 끝의 개행 유무가 바뀌지 않는다 — 줄 수가 변하면 그 자체가 사고다.
  const lines = readFileSync(ITEMS_FILE, 'utf8').split('\n');

  let parsed = 0;
  let unparsable = 0;
  let closed = 0;
  let byMeTrue = 0;
  let byMeFalse = 0;
  let cleared = 0;
  const post = []; // 변경 후 상태 — "결정 대기" 예상 건수 계산용

  const out = lines.map((line) => {
    if (!line.trim()) return line;
    let o;
    try {
      o = JSON.parse(line);
    } catch {
      // 깨진 줄은 손대지 않고 원문 그대로 넘긴다. 조용히 버리면 되돌릴 데가 없다.
      unparsable++;
      return line;
    }
    parsed++;
    let touched = false;

    if (UNDO) {
      for (const k of ['backlogClosedAt', 'backlogReason', 'autoByMe']) {
        if (k in o) { delete o[k]; touched = true; cleared++; }
      }
      post.push(o);
      return touched ? JSON.stringify(o) : line;
    }

    // (a) 백로그 마감. 이미 찍힌 줄은 다시 세지 않는다 — 두 번 돌려도 같은 결과여야
    // dry-run 으로 "남은 대상 0" 을 확인할 수 있다.
    const t = triggerEpoch(o);
    const target = !done[o.id]
      && !o.autoDone
      && absent(o.ackAt)
      && absent(o.ackGrade)
      && (o.requestLevel === undefined || o.requestLevel === null)
      && absent(o.backlogClosedAt)
      && t !== null && t < CUTOFF;

    if (target) {
      o.backlogClosedAt = now;
      o.backlogReason = REASON;
      closed++;
      touched = true;
    }

    // (b) autoByMe 백필. autoBy 가 없는 줄은 누가 눌렀는지 기록 자체가 없으므로
    // 건드리지 않는다 — false 로 채우면 "남이 처리" 라는 없는 사실이 생긴다.
    if (me && !absent(o.autoBy)) {
      const v = o.autoBy === me;
      if (o.autoByMe !== v) { o.autoByMe = v; touched = true; }
      if (v) byMeTrue++; else byMeFalse++;
    }

    post.push(o);
    return touched ? JSON.stringify(o) : line;
  });

  // 마감 후 사람이 실제로 결정해야 하는 것 — done 도 autoDone 도 아니고, 백로그로
  // 접히지도 않았고, AI가 슬랙에 행동한 흔적(ackAt)도 없는 줄.
  const waiting = post.filter((o) => !done[o.id] && !o.autoDone
    && absent(o.backlogClosedAt) && absent(o.ackAt)).length;

  const mode = UNDO ? 'undo' : 'close';
  log(`mode: ${mode} · ${APPLY ? 'APPLY' : 'DRY-RUN'}`);
  log(`items: ${parsed} records · ${unparsable} unparsable (원문 유지) · ${lines.length} split slots`);
  log(`me: ${me || '(모름 — autoByMe 백필 건너뜀)'}${meArg ? ' (--me)' : me ? ' (self.json)' : ''}`);
  if (UNDO) log(`cleared fields: ${cleared}`);
  else log(`backlog close targets: ${closed} (reason=${REASON}, cutoff=${CUTOFF})`);
  log(`autoByMe true: ${byMeTrue} · false: ${byMeFalse}`);
  log(`waiting after change: ${waiting}`);

  if (!APPLY) {
    log('--apply 를 주지 않아 아무것도 쓰지 않았다.');
    return;
  }
  const bak = `${ITEMS_FILE}.bak.${stamp()}`;
  copyFileSync(ITEMS_FILE, bak);
  log(`backup: ${bak}`);
  const tmp = `${ITEMS_FILE}.tmp`;
  writeFileSync(tmp, out.join('\n'));
  renameSync(tmp, ITEMS_FILE);
  log(`wrote: ${ITEMS_FILE}`);
}

main();
