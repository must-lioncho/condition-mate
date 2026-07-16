// E2E bound to the REAL source: extracts goalRow()'s markup + the drag-and-drop
// handlers (dragStart/dragOver/dropOn/...) straight from DashboardContent.swift,
// renders a real goal list, and replays an actual HTML5 drag to verify the order
// posted to /api/goal/reorder. Cannot drift from what ships.
const { chromium } = require('playwright');
const fs = require('fs');

const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/DashboardContent.swift', 'utf8');

// 1) drag handler block: from `let _dragFrom` through the dropOn definition.
const dragStart = SRC.indexOf('let _dragFrom');
const dragEnd = SRC.indexOf('function setParentByNumber');
const dragJs = SRC.slice(dragStart, dragEnd);
// 2) goalRow() definition (returns the row markup incl. the .grip handle).
const rowStart = SRC.indexOf('function goalRow(');
const rowEnd = SRC.indexOf('function aiWorkRow');
const rowJs = SRC.slice(rowStart, rowEnd);

if (dragStart < 0 || dragEnd < 0 || rowStart < 0 || rowEnd < 0) {
  console.error('FAIL could not extract source pieces', { dragStart, dragEnd, rowStart, rowEnd });
  process.exit(1);
}

// Minimal stubs for helpers goalRow depends on (not under test here).
const helpers = `
  function $(id){return document.getElementById(id);}
  function num2(i){return (i<9?'0':'')+(i+1);}
  function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
  function derivedStatus(goals,g){return null;}
  function statLabel(s){return s;}
  function statSel(g){return '';}
  function gpill(g){return '';}
  function linkDot(g){return '';}
  function slinkBtn(g){return '';}
  function spBadge(g){return '';}
  function ttimeHTML(g){return '';}
  function wbadgeHTML(g){return '';}
  function noteBtn(g,r){return '';}
  function evCount(g){return 0;}
  function notePanel(g,r){return '';}
  function evidencePanel(g){return '';}
  function aiWorkRow(g,r){return '';}
  function goalCtx(){}
  function startTitleEdit(){}
  function removeGoal(){}
  function toggleEv(){}
  function fmtDur(sec){return String(Math.floor(sec||0))+'s';}
  function effTracked(g){return g.trackedSeconds||0;}
  function setStatus(){}
`;

const html = `<!doctype html><meta charset=utf-8><body>
  <div id="goals"></div>
  <script>
    ${helpers}
    window.__orders=[];
    var _goals=[];
    function load(){return Promise.resolve();}
    function post(path,obj){ if(path==='/api/goal/reorder') window.__orders.push(obj.order.slice()); return Promise.resolve(); }
    ${dragJs}
    ${rowJs}
    function render(items){
      _goals=items;
      var r={goals:items,notes:{}};
      var idToNum={}; items.forEach(function(g,i){idToNum[g.id]=i+1;});
      document.getElementById('goals').innerHTML=items.map(function(g,i){return goalRow(g,i,r,idToNum);}).join('');
    }
  </script>
</body>`;

// Replay a real HTML5 drag: dragstart on row[from]'s grip, dragover+drop on row[to].
// Uses a shared DataTransfer like a browser would, firing the inline handlers
// (ondragstart/ondragover/ondrop) wired in the real goalRow markup.
async function dragRow(page, from, to) {
  return page.evaluate(({ from, to }) => {
    const rows = document.querySelectorAll('.goal');
    const src = rows[from], dst = rows[to];
    const grip = src.querySelector('.grip');
    const dt = new DataTransfer();
    grip.dispatchEvent(new DragEvent('dragstart', { bubbles: true, dataTransfer: dt }));
    dst.dispatchEvent(new DragEvent('dragover', { bubbles: true, dataTransfer: dt }));
    dst.dispatchEvent(new DragEvent('drop', { bubbles: true, dataTransfer: dt }));
    grip.dispatchEvent(new DragEvent('dragend', { bubbles: true, dataTransfer: dt }));
    return window.__orders.slice();
  }, { from, to });
}

const ids = items => items.map(g => g.id);
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
// Mirror what reorderGoals + render would yield: apply the posted order to the list.
const applyOrder = (items, order) => order.map(id => items.find(g => g.id === id));

(async () => {
  const browser = await chromium.launch();
  let pass = 0, fail = 0;
  const log = (ok, m) => { console.log((ok ? 'PASS ' : 'FAIL ') + m); ok ? pass++ : fail++; };
  const base = [{ id: 'a', text: 'A' }, { id: 'b', text: 'B' }, { id: 'c', text: 'C' }, { id: 'd', text: 'D' }];

  // grip exists + is draggable (real markup)
  {
    const page = await browser.newPage(); await page.setContent(html);
    await page.evaluate(items => render(items), base);
    const grips = await page.$$eval('.goal .grip[draggable="true"]', els => els.length);
    log(grips === 4, `each row has a draggable grip -> ${grips} (expect 4)`);
    await page.close();
  }

  // drag last (D) onto first (A) -> order posts [d,a,b,c]
  {
    const page = await browser.newPage(); await page.setContent(html);
    await page.evaluate(items => render(items), base);
    const orders = await dragRow(page, 3, 0);
    log(orders.length === 1 && eq(orders[0], ['d', 'a', 'b', 'c']),
      `drag D->top posts order ${JSON.stringify(orders[0])} (expect [d,a,b,c])`);
    log(orders.length === 1 && eq(ids(applyOrder(base, orders[0])), ['d', 'a', 'b', 'c']),
      `resulting list = D,A,B,C`);
    await page.close();
  }

  // drag first (A) onto last (D) -> [b,c,d,a]
  {
    const page = await browser.newPage(); await page.setContent(html);
    await page.evaluate(items => render(items), base);
    const orders = await dragRow(page, 0, 3);
    log(orders.length === 1 && eq(orders[0], ['b', 'c', 'd', 'a']),
      `drag A->bottom posts order ${JSON.stringify(orders[0])} (expect [b,c,d,a])`);
    await page.close();
  }

  // drop a row onto itself -> no reorder posted (noise guard)
  {
    const page = await browser.newPage(); await page.setContent(html);
    await page.evaluate(items => render(items), base);
    const orders = await dragRow(page, 2, 2);
    log(orders.length === 0, `drop-on-self posts nothing -> ${JSON.stringify(orders)} (expect [])`);
    await page.close();
  }

  // adjacent swap: drag B (1) onto C (2) -> [a,c,b,d]
  {
    const page = await browser.newPage(); await page.setContent(html);
    await page.evaluate(items => render(items), base);
    const orders = await dragRow(page, 1, 2);
    log(orders.length === 1 && eq(orders[0], ['a', 'c', 'b', 'd']),
      `drag B past C posts order ${JSON.stringify(orders[0])} (expect [a,c,b,d])`);
    await page.close();
  }

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
