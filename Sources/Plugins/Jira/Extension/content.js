// 지라 화면에 번역 버튼을 붙인다.
//
// 설계 원칙 — 지라의 DOM을 최대한 건드리지 않는다.
// 지라는 React로 그려지고 목록은 가상 스크롤이라, 행마다 버튼 엘리먼트를 심으면
// (1) 리렌더 때 통째로 날아가고 (2) 고정 높이 행의 레이아웃이 깨진다. 그래서 버튼은
// 페이지에 딱 하나만 띄우고(position: fixed), 마우스가 얹힌 대상의 오른쪽으로 따라
// 다니게 한다. 우리가 지라 트리에 실제로 넣는 노드는 번역 결과 블록 하나뿐이다.
//
// 번역 결과 표시:
//   - 이슈 상세(제목·설명·댓글): 원문 바로 아래에 블록으로 덧붙인다.
//   - 목록 행·보드 카드: 행 높이가 고정이라 아래에 끼워 넣으면 잘리므로, 행 옆에
//     뜨는 패널로 보여준다. 원문은 어느 쪽이든 그대로 둔다.

(() => {
  'use strict';

  const CFG = globalThis.CMJT_CONFIG || {};
  const ISSUE_KEY = /^[A-Z][A-Z0-9]*-\d+$/;

  // ---------------------------------------------------------------- 대상 판별
  //
  // 지라 Cloud의 data-testid는 릴리스마다 바뀐다. 그래서 되도록 바뀌지 않는 것에
  // 건다: ADF 렌더러의 .ak-renderer-document 클래스(설명·댓글 공통)와 /browse/키
  // 링크(모든 목록 행·카드에 있다). testid는 보조 수단으로만 쓴다.
  const SEL = {
    rich: '.ak-renderer-document',
    heading: 'h1[data-testid*="summary"], [data-testid*="summary.heading"]',
    keyLink: 'a[href*="/browse/"]',
    row: '[data-testid*="card"], [data-testid*="row"], [role="row"], li',
  };

  // el에서 위로 올라가며 번역 단위를 찾는다. { el, kind } 또는 null.
  function resolveUnit(el) {
    for (let n = el; n && n !== document.body; n = n.parentElement) {
      if (n.classList?.contains('cmjt-out') || n.classList?.contains('cmjt-ui')) return null;
      if (n.matches?.(SEL.rich)) return { el: n, kind: 'rich' };
      if (n.matches?.(SEL.heading) || (n.tagName === 'H1' && n.closest('[data-testid*="issue"]'))) {
        return { el: n, kind: 'heading' };
      }
    }
    // 목록 행·카드: 안에 이슈 키 링크를 품고 있는 가장 가까운 컨테이너.
    const link = el.closest?.(SEL.keyLink) || el.closest?.(SEL.row)?.querySelector?.(SEL.keyLink);
    if (link && ISSUE_KEY.test(link.textContent.trim())) {
      const row = link.closest(SEL.row) || link.parentElement;
      if (row && rowText(row).length > 3) return { el: row, kind: 'row' };
    }
    return null;
  }

  // 행에서 번역할 만한 텍스트만. 이슈 키와 상태 칩은 번역해도 의미가 없어 뺀다.
  function rowText(row) {
    const raw = (row.innerText || '').replace(/\s+/g, ' ').trim();
    return raw
      .split(' ')
      .filter((w) => !ISSUE_KEY.test(w))
      .join(' ')
      .trim();
  }

  function unitText(unit) {
    if (unit.kind === 'row') return rowText(unit.el);
    const t = (unit.el.innerText || '').replace(/\n{3,}/g, '\n\n').trim();
    return t;
  }

  // 이미 한국어면 굳이 왕복하지 않는다 (모델도 원문을 돌려줄 뿐이다).
  function looksKorean(s) {
    const hangul = (s.match(/[가-힣]/g) || []).length;
    const letters = (s.match(/[A-Za-z가-힣]/g) || []).length;
    return letters > 0 && hangul / letters > 0.5;
  }

  // ---------------------------------------------------------------- 요청 묶기
  //
  // 사용자가 연달아 여러 곳을 누르면 한 번의 Gemini 호출로 합친다.
  const queue = [];
  let flushTimer = null;

  function requestTranslate(text) {
    return new Promise((resolve) => {
      queue.push({ text, resolve });
      clearTimeout(flushTimer);
      flushTimer = setTimeout(flush, 120);
    });
  }

  async function flush() {
    const batch = queue.splice(0, queue.length);
    if (!batch.length) return;
    let res;
    try {
      res = await chrome.runtime.sendMessage({ type: 'translate', texts: batch.map((b) => b.text) });
    } catch {
      res = { ok: false, error: '익스텐션이 다시 로드됐습니다 — 페이지를 새로고침해 주세요.' };
    }
    if (!res?.ok) {
      batch.forEach((b) => b.resolve({ ok: false, error: res?.error || '번역 실패' }));
      return;
    }
    batch.forEach((b, i) => b.resolve({ ok: true, text: res.items[i] ?? b.text, model: res.model, warn: res.warn }));
  }

  // ---------------------------------------------------------------- 결과 표시

  const outputs = new WeakMap(); // unit el -> 결과 노드

  function removeOutput(el) {
    const node = outputs.get(el);
    if (node) node.remove();
    outputs.delete(el);
  }

  function makeBlock(text, meta) {
    const box = document.createElement('div');
    box.className = 'cmjt-out';
    const head = document.createElement('div');
    head.className = 'cmjt-out-head';
    head.textContent = meta || '번역';
    const close = document.createElement('button');
    close.className = 'cmjt-out-close';
    close.type = 'button';
    close.textContent = '✕';
    close.title = '번역 닫기';
    head.appendChild(close);
    box.appendChild(head);
    // 본문이 없는 경우도 있다 — "이미 한국어입니다"처럼 머리말만으로 할 말이 끝나면
    // 원문을 한 번 더 찍어 봐야 화면만 길어진다.
    if (text) {
      const body = document.createElement('div');
      body.className = 'cmjt-out-body';
      body.textContent = text;
      box.appendChild(body);
    }
    return { box, close };
  }

  // 이슈 상세: 원문 바로 아래.
  function showInline(unit, text, meta) {
    removeOutput(unit.el);
    const { box, close } = makeBlock(text, meta);
    close.addEventListener('click', () => removeOutput(unit.el));
    unit.el.insertAdjacentElement('afterend', box);
    outputs.set(unit.el, box);
  }

  // 목록 행·카드: 행 옆에 뜨는 패널 (행 높이를 건드리지 않는다).
  function showPopover(unit, text, meta) {
    removeOutput(unit.el);
    const { box, close } = makeBlock(text, meta);
    box.classList.add('cmjt-pop');
    close.addEventListener('click', () => removeOutput(unit.el));
    document.body.appendChild(box);
    const r = unit.el.getBoundingClientRect();
    const width = Math.min(520, Math.max(280, r.width));
    box.style.width = width + 'px';
    box.style.left = Math.max(8, Math.min(window.innerWidth - width - 8, r.left)) + 'px';
    // 화면 아래쪽 행이면 위로 띄운다.
    const below = window.innerHeight - r.bottom;
    if (below < 140) box.style.top = Math.max(8, r.top - box.offsetHeight - 6) + 'px';
    else box.style.top = r.bottom + 6 + 'px';
    outputs.set(unit.el, box);
  }

  function show(unit, text, meta) {
    if (unit.kind === 'row') showPopover(unit, text, meta);
    else showInline(unit, text, meta);
  }

  // ---------------------------------------------------------------- 떠다니는 버튼

  const btn = document.createElement('button');
  btn.className = 'cmjt-ui cmjt-btn';
  btn.type = 'button';
  btn.textContent = '번역';
  btn.title = '컨디션 매니저로 이 텍스트를 한국어로 번역';
  btn.style.display = 'none';
  document.documentElement.appendChild(btn);

  let current = null; // 지금 버튼이 가리키는 단위
  let hideTimer = null;
  // 번역이 오가는 동안 마우스가 다른 곳으로 지나가면 결과가 엉뚱한 자리에 붙는다.
  // 응답이 올 때까지 대상을 고정한다.
  let busy = false;

  function place(unit) {
    const r = unit.el.getBoundingClientRect();
    if (r.width < 40 || r.height < 12 || r.bottom < 0 || r.top > window.innerHeight) return hide();
    btn.style.display = 'block';
    const w = btn.offsetWidth || 44;
    // 오른쪽 끝에 붙이되, 화면 밖으로 나가지 않게.
    btn.style.left = Math.min(window.innerWidth - w - 6, Math.max(6, r.right - w - 4)) + 'px';
    btn.style.top = Math.max(4, r.top + 2) + 'px';
  }

  function hide() {
    btn.style.display = 'none';
    current = null;
  }

  function onPoint(e) {
    if (e.target === btn || busy) return; // 번역 중에는 대상을 바꾸지 않는다
    const unit = resolveUnit(e.target);
    clearTimeout(hideTimer);
    if (!unit) {
      hideTimer = setTimeout(hide, 250);
      return;
    }
    current = unit;
    place(unit);
  }

  let moveTick = 0;
  document.addEventListener(
    'mousemove',
    (e) => {
      const now = Date.now();
      if (now - moveTick < 80) return;
      moveTick = now;
      onPoint(e);
    },
    { passive: true, capture: true },
  );

  // 스크롤·리사이즈 중에는 위치가 어긋나므로 따라가게 한다.
  const reposition = () => {
    if (current?.el.isConnected) place(current);
    else hide();
  };
  window.addEventListener('scroll', reposition, { passive: true, capture: true });
  window.addEventListener('resize', reposition, { passive: true });

  btn.addEventListener('click', async (e) => {
    e.preventDefault();
    e.stopPropagation();
    const unit = current;
    if (!unit || busy) return;
    const text = unitText(unit);
    if (!text) return;
    if (looksKorean(text)) {
      show(unit, '', '이미 한국어입니다');
      return;
    }
    busy = true;
    btn.textContent = '…';
    btn.disabled = true;
    const res = await requestTranslate(text);
    btn.textContent = '번역';
    btn.disabled = false;
    busy = false;
    if (!res.ok) {
      // 실패는 조용히, 그 자리에서만 알린다 (전역 배너를 띄우지 않는다).
      show(unit, res.error, '번역할 수 없었습니다');
      return;
    }
    show(unit, res.text, `번역 · ${res.model || 'gemini'}`);
  });

  // 지라는 SPA라 화면이 통째로 바뀐다. 사라진 원문에 붙어 있던 결과 블록을 치운다.
  const observer = new MutationObserver(() => {
    document.querySelectorAll('.cmjt-out').forEach((box) => {
      if (box.classList.contains('cmjt-pop')) return; // 팝오버는 닫기 버튼으로만 사라진다
      if (!box.previousElementSibling) box.remove();
    });
    if (current && !current.el.isConnected) hide();
  });
  observer.observe(document.body, { childList: true, subtree: true });

  // 앱 연결 상태를 콘솔에 한 줄 남긴다 — 설치 직후 확인용.
  chrome.runtime.sendMessage({ type: 'ping' }).then((r) => {
    if (r?.ok) console.log('[컨디션 매니저 지라 번역] 앱 연결됨 · 모델', r.model);
    else console.warn('[컨디션 매니저 지라 번역]', r?.error || '앱에 연결할 수 없습니다');
  });

  void CFG;
})();
