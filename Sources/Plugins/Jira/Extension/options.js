// 옵션 화면 — 언어 선택과 (설치 스크립트를 안 쓴 경우의) 토큰 입력, 연결 확인.

const CFG = globalThis.CMJT_CONFIG || {};
const $ = (id) => document.getElementById(id);

(async () => {
  const saved = await chrome.storage.local.get(['token', 'lang']);
  $('lang').value = saved.lang || CFG.lang || 'ko';
  if (CFG.token) {
    $('token').value = '••••••••••••';
    $('token').disabled = true;
    $('token').placeholder = '설치 스크립트가 심어 둔 토큰을 씁니다';
  } else if (saved.token) {
    $('token').value = saved.token;
  }
  await check();
})();

$('lang').addEventListener('change', () => chrome.storage.local.set({ lang: $('lang').value }));

$('token').addEventListener('change', async () => {
  await chrome.storage.local.set({ token: $('token').value.trim() });
  await check();
});

$('check').addEventListener('click', check);

async function check() {
  const el = $('status');
  el.textContent = '확인 중…';
  el.className = 'status';
  const r = await chrome.runtime.sendMessage({ type: 'ping' });
  if (r?.ok) {
    el.textContent = `앱에 연결됨 · 모델 ${r.model}`;
    el.className = 'status ok';
  } else {
    el.textContent = r?.error || '연결할 수 없습니다';
    el.className = 'status bad';
  }
}
