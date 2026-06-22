// E2E bound to the REAL source: extracts the #goalText onkeydown + the goalKey/
// composition/addGoal JS straight from DashboardContent.swift, so the test cannot
// drift from what ships. Replays the macOS IME commit-with-Enter sequence.
const { chromium } = require('playwright');
const fs = require('fs');

const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/DashboardContent.swift', 'utf8');

// 1) onkeydown handler attribute for #goalText
const onkeydown = (SRC.match(/id="goalText"[\s\S]*?onkeydown="([^"]+)"/) || [])[1];
// 2) the JS slice from the IME comment block through the addGoal definition
const jsStart = SRC.indexOf('let _composing');
const jsEnd = SRC.indexOf('function removeGoal');
const realJs = SRC.slice(jsStart, jsEnd);
// helpers the slice depends on
const helpers = `function $(id){return document.getElementById(id);}\n`;

if (!onkeydown || jsStart < 0 || jsEnd < 0) {
  console.error('FAIL could not extract source pieces', { onkeydown, jsStart, jsEnd });
  process.exit(1);
}

const html = `<!doctype html><meta charset=utf-8><body>
  <input type="text" id="goalText" onkeydown="${onkeydown.replace(/"/g, '&quot;')}">
  <script>
    ${helpers}
    window.__submits=[];
    ${realJs}
    post=function(path,obj){ window.__submits.push(obj.text); return Promise.resolve(); };
  </script>
</body>`;

async function imeCommit(page, { committedPrefix, composing, enterIsComposing }) {
  await page.evaluate(async ({ committedPrefix, composing, enterIsComposing }) => {
    const el = document.getElementById('goalText'); el.focus();
    el.value = committedPrefix;
    el.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    el.value = committedPrefix + composing;
    el.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: composing }));
    el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', isComposing: enterIsComposing, keyCode: enterIsComposing ? 229 : 13 }));
    const cleared = el.value === '';
    el.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: composing }));
    if (cleared) { el.value = composing; el.dispatchEvent(new Event('input', { bubbles: true })); }
    if (el.value !== '') el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', isComposing: false, keyCode: 13 }));
  }, { committedPrefix, composing, enterIsComposing });
  return page.evaluate(() => window.__submits.slice());
}
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

(async () => {
  const browser = await chromium.launch();
  let pass = 0, fail = 0;
  const log = (ok, m) => { console.log((ok ? 'PASS ' : 'FAIL ') + m); ok ? pass++ : fail++; };

  for (const enterIsComposing of [true, false]) {
    const page = await browser.newPage(); await page.setContent(html);
    const s = await imeCommit(page, { committedPrefix: '지', composing: '급', enterIsComposing });
    log(eq(s, ['지급']), `SOURCE "지급" enterIsComposing=${enterIsComposing} -> ${JSON.stringify(s)} (expect ["지급"])`);
    await page.close();
  }
  for (const enterIsComposing of [true, false]) {
    const page = await browser.newPage(); await page.setContent(html);
    const s = await imeCommit(page, { committedPrefix: 'passbolt 되', composing: '게', enterIsComposing });
    log(eq(s, ['passbolt 되게']), `SOURCE mixed enterIsComposing=${enterIsComposing} -> ${JSON.stringify(s)} (expect ["passbolt 되게"])`);
    await page.close();
  }
  { // ASCII single Enter
    const page = await browser.newPage(); await page.setContent(html);
    await page.evaluate(() => { const el = document.getElementById('goalText'); el.focus(); el.value = 'passbolt'; el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', isComposing: false, keyCode: 13 })); });
    const s = await page.evaluate(() => window.__submits.slice());
    log(eq(s, ['passbolt']), `SOURCE ASCII -> ${JSON.stringify(s)} (expect ["passbolt"])`); await page.close();
  }
  { // empty Enter
    const page = await browser.newPage(); await page.setContent(html);
    await page.evaluate(() => { const el = document.getElementById('goalText'); el.focus(); el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter', isComposing: false, keyCode: 13 })); });
    const s = await page.evaluate(() => window.__submits.slice());
    log(eq(s, []), `SOURCE empty -> ${JSON.stringify(s)} (expect [])`); await page.close();
  }

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
