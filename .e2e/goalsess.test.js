// E2E for the goal-add INLINE session view's event rendering (gsEvt), bound to the REAL
// source (GoalAddContent.swift). Feeds a realistic chat2 SSE event sequence and asserts
// the chat-ui conventions hold:
//   1) think deltas stream into a dim block, then COLLAPSE to a "생각 과정 ›" drilldown
//      as soon as the turn moves on (text or tool)
//   2) text deltas stream as a plain paragraph (no bubble), finalized as markdown on done
//   3) tools render as ONE summary line ("사용함 도구 N개 ›") with per-tool drilldown rows,
//      and tool results land in the matching row by id
//   4) done appends the cost line and returns the composer to idle (send shown, stop hidden)
//   5) denials on done raise the permission card; allowing continues the turn with the
//      denied tools in the session allowlist
//   6) error/stopped end the working state without wiping rendered content
//   7) cm-question blocks (docs/cm-question-protocol.md) never show raw JSON: streaming
//      shows a "질문 준비 중…" hint, done renders the one-at-a-time option card, answering
//      all questions submits ONE combined chat2/say turn, malformed JSON falls back to md
//   8) live status metrics (클로드 코드式): server stat events stream the output-token
//      count into the working line ("… · 453 tokens", 1000+ folds to "1.2k"), and done
//      appends tokens to the cost line — without tokens the cost line stays plain "$…"
const fs = require('fs');
const GA = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/GoalAddContent.swift', 'utf8');
function fn(src, name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0;
  for (let k = src.indexOf('{', start); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// ── Minimal DOM: enough for createElement/appendChild/classList/querySelector('.cls') ──
function node(tag) {
  const n = {
    tag, children: [], className: '', textContent: '', style: {},
    onclick: null, disabled: false, value: '', type: '', title: '', placeholder: '',
    classList: {
      add(c) { if (!n.className.split(' ').includes(c)) n.className = (n.className + ' ' + c).trim(); },
      remove(c) { n.className = n.className.split(' ').filter(x => x !== c).join(' '); },
      toggle(c, on) { const has = n.className.split(' ').includes(c);
        if (on === undefined) on = !has;
        if (on) n.classList.add(c); else n.classList.remove(c); return on; },
      contains(c) { return n.className.split(' ').includes(c); }
    },
    addEventListener() {}, focus() {},
    appendChild(ch) { n.children.push(ch); return ch; },
    remove() { n.removed = true; },
    querySelector(sel) { const c = sel.replace('.', '');
      const walk = m => { for (const ch of m.children) { if ((ch.className || '').split(' ').includes(c)) return ch;
        const d = walk(ch); if (d) return d; } return null; };
      return walk(n); },
    querySelectorAll(sel) { const c = sel.replace('.', ''); const out = [];
      const walk = m => { for (const ch of m.children) { if ((ch.className || '').split(' ').includes(c)) out.push(ch); walk(ch); } };
      walk(n); return out; }
  };
  // real-DOM semantics the qcard relies on: setting innerHTML replaces the children
  let html = '';
  Object.defineProperty(n, 'innerHTML', {
    get() { return html; },
    set(v) { html = v; n.children = []; }
  });
  return n;
}

function boot() {
  const env = { els: {}, posts: [] };
  const el = id => (env.els[id] = env.els[id] || node('div'));
  global.$ = el;
  global.document = { createElement: t => node(t), body: node('body'),
                      addEventListener() {}, removeEventListener() {} };
  global.window = { innerHeight: 800, scrollY: 0, scrollTo() {} };
  global.esc = s => String(s == null ? '-' : s);
  global.post = (path, obj) => { env.posts.push({ path, obj });
    return Promise.resolve({ json: () => Promise.resolve({ ok: true }) }); };
  global.md = t => '<md>' + t + '</md>';   // marked stub — proves finalization path ran
  global._gs = { seq: 7, mode: 'default', allow: [], es: null, cur: null, text: '', sawText: false,
                 think: null, thinkText: '', tools: null, toolCount: 0, toolCards: {},
                 running: false, lastMode: 'default' };
  global._gsImgs = [];
  global._gsQKey = null;
  for (const n2 of ['gsEvt', 'gsThinkClose', 'gsFlushPara', 'gsWorking', 'gsScroll',
                    'gsNote', 'gsUser', 'gsPerm', 'gsPlanRun', 'gsPost',
                    'gsRenderAssistant', 'gsExtractQ', 'gsBuildQcard', 'gsSetQKey',
                    'gsRedraft', 'gsRedraftBtn'])
    eval.call(global, 'global.' + n2 + ' = ' + fn(GA, n2));
  return env;
}
const tick = () => new Promise(r => setTimeout(r, 0));
const byClass = (env, c) => {
  const out = [];
  const walk = m => { for (const ch of m.children) { if ((ch.className || '').split(' ').includes(c)) out.push(ch); walk(ch); } };
  walk(env.els.gsLive); return out;
};

async function run() {
  // ── 1+2+3+4: full happy-path turn: think → text → tool×2 → text → done ──
  let env = boot();
  global.gsEvt({ t: 'start' });
  check('start flips the composer to working', env.els.gsStopBtn.style.display, '');
  global.gsEvt({ t: 'think', text: '먼저 구조를 ' });
  global.gsEvt({ t: 'think', text: '살펴보자' });
  const think = byClass(env, 'sthink')[0];
  check('think streams into the dim block', think.querySelector('.tkb').textContent, '먼저 구조를 살펴보자');
  check('think starts open', think.classList.contains('closed'), false);
  global.gsEvt({ t: 'delta', text: '구조를 확인했습니다. ' });
  check('text after think collapses it to a drilldown',
        [think.classList.contains('closed'), think.querySelector('.tks').textContent],
        [true, '생각 과정 ›']);
  global.gsEvt({ t: 'delta', text: '이제 수정합니다.' });
  check('deltas stream as a plain paragraph (no bubble)',
        byClass(env, 'sa')[0].textContent, '구조를 확인했습니다. 이제 수정합니다.');
  global.gsEvt({ t: 'tool', id: 'T1', name: 'Read', input: { file_path: '/x/a.swift' } });
  check('tool finalizes the open paragraph as markdown',
        byClass(env, 'sa')[0].innerHTML, '<md>구조를 확인했습니다. 이제 수정합니다.</md>');
  global.gsEvt({ t: 'tool', id: 'T2', name: 'Bash', input: { command: 'swift build' } });
  const sum = byClass(env, 'stoolsum')[0];
  check('tools fold into one summary line', sum.textContent, '사용함 도구 2개 ›');
  check('tool rows carry name + arg', byClass(env, 'strow').map(r => r.textContent),
        ['Read  /x/a.swift', 'Bash  $ swift build']);
  global.gsEvt({ t: 'toolresult', id: 'T2', text: 'Build complete!' });
  check('tool result lands in its row by id', byClass(env, 'strdet')[1].textContent, 'Build complete!');
  global.gsEvt({ t: 'delta', text: '빌드 통과. 완료했습니다.' });
  global.gsEvt({ t: 'done', cost: 0.1234 });
  check('done finalizes the tail paragraph as markdown',
        byClass(env, 'sa')[1].innerHTML, '<md>빌드 통과. 완료했습니다.</md>');
  check('done appends the cost line', byClass(env, 'scost')[0].textContent, '$0.1234');
  check('done returns the composer to idle',
        [env.els.gsSendBtn.style.display, env.els.gsStopBtn.style.display], ['', 'none']);

  // ── 8: live status metrics — stat streams tokens into the working line, done → cost line ──
  env = boot();
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'stat', tokens: 453 });
  check('stat streams the token count into the working line',
        env.els.gsStxt.textContent.includes('453 tokens'), true);
  global.gsEvt({ t: 'tool', id: 'T1', name: 'Bash', input: { command: 'ls' } });
  check('tool label keeps the token count', env.els.gsStxt.textContent.includes('453 tokens'), true);
  global.gsEvt({ t: 'stat', tokens: 1234 });
  check('1000+ tokens fold to k-notation', env.els.gsStxt.textContent.includes('1.2k tokens'), true);
  global.gsEvt({ t: 'done', cost: 0.5, tokens: 1234 });
  check('done appends tokens to the cost line',
        [byClass(env, 'scost')[0].textContent.includes('$0.5'),
         byClass(env, 'scost')[0].textContent.includes('1.2k tokens')], [true, true]);
  check('done resets the metrics for the next turn',
        [global._gs.startedAt, global._gs.tokens], [0, 0]);

  // ── no-delta turn: done falls back to o.result ──
  env = boot();
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'done', result: '한 줄 답변' });
  check('delta-less done renders o.result', byClass(env, 'sa')[0].innerHTML, '<md>한 줄 답변</md>');

  // ── 5: denials raise the permission card; allow continues with the allowlist ──
  env = boot();
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'done', denials: [{ tool_name: 'Bash', tool_input: { command: 'rm -rf x' } },
                                      { tool_name: 'Bash', tool_input: { command: 'ls' } }] });
  const card = byClass(env, 'gs-perm')[0];
  check('denials raise the permission card', !!card, true);
  const allowBtn = byClass(env, 'prow')[0].children[0];
  allowBtn.onclick();
  await tick();
  check('allow dedupes tools into the session allowlist', global._gs.allow, ['Bash']);
  check('allow continues the turn via chat2/say',
        env.posts.map(p => [p.path, p.obj.allow]), [['/api/goal/chat2/say', ['Bash']]]);

  // ── plan mode: done offers 실행, click forces acceptEdits with modeOverride ──
  env = boot();
  global._gs.mode = 'plan'; global._gs.lastMode = 'plan';
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'delta', text: '계획입니다' });
  global.gsEvt({ t: 'done' });
  const run2 = byClass(env, 'planrun')[0];
  check('plan turn offers 실행 button', !!run2, true);
  run2.onclick();
  await tick();
  check('plan approval forces acceptEdits this turn',
        [env.posts[0].obj.mode, env.posts[0].obj.modeOverride], ['acceptEdits', true]);

  // ── 6: error/stopped end working state, keep content ──
  env = boot();
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'delta', text: '진행 중' });
  global.gsEvt({ t: 'error', message: '실행 실패' });
  check('error ends the working state', env.els.gsStat.classList.contains('working'), false);
  check('error keeps rendered content + appends the note',
        byClass(env, 'sa').map(x => x.innerHTML || x.textContent), ['<md>진행 중</md>', '⚠️ 실행 실패']);

  // ── 6b: stopped → 다시작성 button restores the last sent text into the composer ──
  env = boot();
  global._gs.lastText = '이전에 보낸 지시';
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'delta', text: '진행 중' });
  global.gsEvt({ t: 'stopped', reason: 'user' });
  check('stopped ends the working state', env.els.gsStat.classList.contains('working'), false);
  check('stopped keeps content + appends the note',
        byClass(env, 'sa').map(x => x.innerHTML || x.textContent), ['<md>진행 중</md>', '⏹ 중단되었습니다 — 이어서 지시하면 계속됩니다']);
  const redraft = byClass(env, 'planrun').find(b => b.textContent.includes('다시작성'));
  check('stopped offers the 다시작성 button', !!redraft, true);
  redraft.onclick();
  check('다시작성 restores the last sent text into the composer', env.els.gsIn.value, '이전에 보낸 지시');

  // stopped with no prior send → no 다시작성 button (nothing to restore)
  env = boot();
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'stopped', reason: 'died' });
  check('stopped with no last content offers no 다시작성 button',
        byClass(env, 'planrun').filter(b => b.textContent.includes('다시작성')).length, 0);

  // ── 7: cm-question — streaming hint, option card, combined submit, md fallback ──
  env = boot();
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'delta', text: '문제정의부터 맞추겠습니다.\n```cm-question\n{"q":[{"ask"' });
  const streamPara = byClass(env, 'sa')[0];
  check('cm-question streaming shows the hint, not raw JSON',
        [streamPara.innerHTML.includes('질문 준비 중'), streamPara.innerHTML.includes('"q"')],
        [true, false]);
  global.gsEvt({ t: 'delta', text: ':"진짜 문제는?","opts":[' +
    '{"label":"디자인 시스템 부재","rec":true,"why":"메시지 근거"},{"label":"아이콘 색만 정리"}]},' +
    '{"ask":"어디서 관리?","opts":[{"label":"시스템 관리"},{"label":"별도 문서"}]}]}\n```' });
  global.gsEvt({ t: 'done' });
  check('done strips the block and renders the intro as markdown',
        streamPara.innerHTML, '<md>문제정의부터 맞추겠습니다.</md>');
  let qcard = byClass(env, 'qcard')[0];
  // qcount/qtitle are innerHTML-built (the stub doesn't parse HTML) — assert on the head string
  check('done renders the question card, one question at a time',
        [qcard.querySelector('.qhead').innerHTML.includes('1/2'),
         qcard.querySelector('.qhead').innerHTML.includes('진짜 문제는?')],
        [true, true]);
  let qopts = qcard.querySelectorAll('.qopt');
  check('options render with the recommended one preselected',
        [qopts.length, qopts[0].classList.contains('sel'), qopts[0].innerHTML.includes('추천')],
        [3, true, true]);   // 2 options + 기타
  qopts[1].onclick();
  check('clicking an option moves the selection',
        [qopts[0].classList.contains('sel'), qopts[1].classList.contains('sel')], [false, true]);
  qcard.querySelector('.qnextbtn').onclick();
  check('다음 advances to the second question', qcard.querySelector('.qhead').innerHTML.includes('2/2'), true);
  qcard.querySelector('.qskip').onclick();
  await tick();
  check('answering all questions marks the card answered', qcard.classList.contains('answered'), true);
  check('answers submit as ONE combined chat2/say turn',
        [env.posts.length, env.posts[0].path, env.posts[0].obj.text],
        [1, '/api/goal/chat2/say', '1. 진짜 문제는? → 아이콘 색만 정리\n2. 어디서 관리? → (미응답)']);
  check('the combined answer echoes as a user bubble', byClass(env, 'su')[0].textContent.startsWith('1. 진짜 문제는?'), true);

  // malformed JSON: no card, raw text falls back to markdown (safe fallback)
  env = boot();
  global.gsEvt({ t: 'start' });
  global.gsEvt({ t: 'delta', text: '```cm-question\n{broken json```' });
  global.gsEvt({ t: 'done' });
  check('malformed cm-question falls back to raw markdown, no card',
        [byClass(env, 'qcard').length, byClass(env, 'sa')[0].innerHTML.includes('broken json')],
        [0, true]);

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
}
run();
