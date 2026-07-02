// E2E: reproduce the macOS WKWebView Korean-IME duplicate-goal bug and verify the fix.
//
// The bug lives in WebKit's IME pipeline, which Chromium does not reproduce natively.
// So we drive a REAL Chromium DOM with the REAL handler code, but script the exact
// event sequence that macOS 2-beolsik IME emits when committing a composing syllable
// with Enter. The sequence is calibrated to the user's observed reality:
//   input "지급" (C="지" committed, S="급" composing) + Enter  ->  goals: ["지급","급"]
//
// We compare three handlers to prove which one actually fixes it.
const { chromium } = require('playwright');

// --- handler variants (onkeydown attr + addGoal/composition wiring) ---
const VARIANTS = {
  // A) original (pre-fix)
  A_original: {
    onkeydown: `if(event.key==='Enter')addGoal()`,
    wiring: '',
  },
  // B) isComposing guard (what is currently in source)
  B_isComposingGuard: {
    onkeydown: `if(event.key==='Enter'&&!event.isComposing&&event.keyCode!==229)addGoal()`,
    wiring: '',
  },
  // C) compositionend-deferred (proposed robust fix)
  C_compositionDeferred: {
    onkeydown: `if(event.key==='Enter'){ if(_composing){ _pendingAdd=true; } else { addGoal(); } }`,
    wiring: `
      let _composing=false,_pendingAdd=false;
      const _gi=document.getElementById('goalText');
      _gi.addEventListener('compositionstart',()=>{_composing=true;});
      _gi.addEventListener('compositionend',()=>{_composing=false; if(_pendingAdd){_pendingAdd=false; addGoal();}});
    `,
  },
};

// Real addGoal from source (post() mocked to record submissions).
const ADDGOAL = `
  function $(id){return document.getElementById(id);}
  window.__submits=[];
  function post(path,obj){ window.__submits.push(obj.text); return Promise.resolve(); }
  function addGoal(){ const t=$('goalText').value.trim(); if(!t)return; $('goalText').value=''; $('goalText').focus(); post('/api/goal/add',{text:t}); }
`;

function pageHtml(variant) {
  return `<!doctype html><meta charset=utf-8><body>
    <input type="text" id="goalText" onkeydown="${variant.onkeydown}">
    <script>${ADDGOAL}${variant.wiring}</script>
  </body>`;
}

// Faithful model of macOS 2-beolsik committing a multi-syllable word with Enter.
// committedPrefix = syllables already finalized; composing = the last syllable still in IME.
// imeCommitsOnEnterWithComposingFlag lets us test both "isComposing=true" (spec) and
// "isComposing=false" (WebKit divergence the user appears to hit).
async function typeKoreanAndEnter(page, { committedPrefix, composing, enterIsComposing }) {
  await page.evaluate(async ({ committedPrefix, composing, enterIsComposing }) => {
    const el = document.getElementById('goalText');
    el.focus();
    // 1. type the already-committed prefix as plain text
    el.value = committedPrefix;
    // 2. begin composing the last syllable -> field shows prefix+composing
    el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    el.value = committedPrefix + composing;
    el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: composing }));

    // 3. Enter pressed to commit+submit. keydown fires FIRST (handler may clear value).
    el.dispatchEvent(new KeyboardEvent('keydown', {
      bubbles: true, key: 'Enter',
      isComposing: enterIsComposing,
      keyCode: enterIsComposing ? 229 : 13,
    }));
    // 4. IME finalizes: it writes the composing syllable back into the field, replacing
    //    the composition range. If the handler cleared the field in step 3, the field is
    //    now just the committed syllable (this is the observed WKWebView re-insertion).
    const cleared = el.value === '';
    el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: composing }));
    if (cleared) { el.value = composing; el.dispatchEvent(new Event('input', { bubbles: true })); }

    // 5. With the original/guarded handler the first Enter did NOT submit yet on WebKit
    //    when isComposing was reported false-then-true; user presses Enter again.
    if (el.value !== '') {
      el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', isComposing: false, keyCode: 13 }));
    }
  }, { committedPrefix, composing, enterIsComposing });
  return page.evaluate(() => window.__submits.slice());
}

function eq(a, b) { return JSON.stringify(a) === JSON.stringify(b); }

(async () => {
  const browser = await chromium.launch();
  let pass = 0, fail = 0;
  const log = (ok, msg) => { console.log((ok ? 'PASS ' : 'FAIL ') + msg); ok ? pass++ : fail++; };

  // This is a COMPARISON harness: it runs three handler variants and asserts each
  // against its DOCUMENTED behavior, not against a single "correct" output. Only
  // C_compositionDeferred is deployed and must be correct in both WebKit realities;
  // A_original and B_isComposingGuard are kept as living proof of the bug, so each is
  // expected to REPRODUCE its known mis-handling. A green run therefore means both
  // "the fix works" and "the bug is still reproduced by the unfixed variants" — if C
  // ever regresses, or A/B silently stop leaking, that is a real failure worth seeing.
  // Keys are name|enterIsComposing; LEAK is the duplicate-goal bug, CLEAN is correct.
  const LEAK = ['지급', '급'], CLEAN = ['지급'];
  const expected = {
    'A_original|true': LEAK,   'A_original|false': LEAK,            // buggy in both realities
    'B_isComposingGuard|true': CLEAN, 'B_isComposingGuard|false': LEAK, // partial: only fixes isComposing=true
    'C_compositionDeferred|true': CLEAN, 'C_compositionDeferred|false': CLEAN, // deployed fix: correct in both
  };
  for (const [name, variant] of Object.entries(VARIANTS)) {
    const role = name === 'C_compositionDeferred' ? 'deployed fix' : 'pre-fix demo';
    // Scenario: "지급" committed-prefix="지", composing="급".
    // Test BOTH isComposing realities WebKit may report on the committing Enter.
    for (const enterIsComposing of [true, false]) {
      const page = await browser.newPage();
      await page.setContent(pageHtml(variant));
      const submits = await typeKoreanAndEnter(page, { committedPrefix: '지', composing: '급', enterIsComposing });
      const want = expected[`${name}|${enterIsComposing}`];
      const ok = eq(submits, want);
      log(ok, `${name} (${role}) | enterIsComposing=${enterIsComposing} | "지급" -> ${JSON.stringify(submits)} (expect ${JSON.stringify(want)})`);
      await page.close();
    }
  }

  // Extra correctness scenarios on the proposed fix (variant C):
  {
    // pure ASCII, no composition: single Enter -> one submit
    const page = await browser.newPage();
    await page.setContent(pageHtml(VARIANTS.C_compositionDeferred));
    await page.evaluate(() => {
      const el = document.getElementById('goalText'); el.focus(); el.value = 'passbolt';
      el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', isComposing: false, keyCode: 13 }));
    });
    const s = await page.evaluate(() => window.__submits.slice());
    log(eq(s, ['passbolt']), `C | ASCII "passbolt" -> ${JSON.stringify(s)} (expect ["passbolt"])`);
    await page.close();
  }
  {
    // empty input Enter -> nothing
    const page = await browser.newPage();
    await page.setContent(pageHtml(VARIANTS.C_compositionDeferred));
    await page.evaluate(() => {
      const el = document.getElementById('goalText'); el.focus();
      el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', isComposing: false, keyCode: 13 }));
    });
    const s = await page.evaluate(() => window.__submits.slice());
    log(eq(s, []), `C | empty Enter -> ${JSON.stringify(s)} (expect [])`);
    await page.close();
  }
  {
    // mixed "passbolt 되게" committed="passbolt 되", composing="게"
    const page = await browser.newPage();
    await page.setContent(pageHtml(VARIANTS.C_compositionDeferred));
    const s = await typeKoreanAndEnter(page, { committedPrefix: 'passbolt 되', composing: '게', enterIsComposing: false });
    log(eq(s, ['passbolt 되게']), `C | mixed -> ${JSON.stringify(s)} (expect ["passbolt 되게"])`);
    await page.close();
  }

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
