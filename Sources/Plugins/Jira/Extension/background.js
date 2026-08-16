// 서비스 워커 — 콘텐츠 스크립트와 로컬 브리지 사이의 유일한 통로.
//
// 왜 콘텐츠 스크립트가 직접 fetch 하지 않는가: 콘텐츠 스크립트의 fetch 는 지라 페이지의
// 출처(https://…atlassian.net)로 나가므로 CORS 와 mixed-content 규칙에 걸리고, 무엇보다
// 페이지의 자바스크립트가 같은 요청을 흉내 낼 수 있게 된다. 서비스 워커에서 나가면
// 출처가 chrome-extension:// 이라 브리지의 Origin 검사를 통과하고, 페이지 쪽 코드는
// 토큰을 볼 수 없다.

importScripts('config.js');

const DEFAULTS = globalThis.CMJT_CONFIG || { bridge: 'http://127.0.0.1:17321', token: '', lang: 'ko' };

// config.js 에 심긴 값이 우선, 없으면 옵션 화면에서 저장한 값.
async function settings() {
  const saved = await chrome.storage.local.get(['token', 'lang', 'bridge']);
  return {
    bridge: DEFAULTS.bridge || saved.bridge || 'http://127.0.0.1:17321',
    token: DEFAULTS.token || saved.token || '',
    lang: saved.lang || DEFAULTS.lang || 'ko',
  };
}

async function call(path, init = {}) {
  const s = await settings();
  if (!s.token) {
    return { ok: false, error: '연결 토큰이 없습니다 — 익스텐션 옵션에서 토큰을 넣거나 설치 스크립트를 다시 실행하세요.' };
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 40000);
  try {
    const res = await fetch(s.bridge + path, {
      ...init,
      headers: { 'Content-Type': 'application/json', 'x-cm-jira-token': s.token, ...(init.headers || {}) },
      signal: controller.signal,
    });
    if (res.status === 401) return { ok: false, error: '토큰이 맞지 않습니다 — 설치 스크립트를 다시 실행하세요.' };
    if (res.status === 429) return { ok: false, error: '잠시 후 다시 시도해 주세요 (호출이 몰렸습니다).' };
    if (!res.ok) return { ok: false, error: `앱 응답 오류 (HTTP ${res.status})` };
    return await res.json();
  } catch (e) {
    // 앱이 꺼져 있거나 브리지가 안 돌 때가 대부분이다.
    return { ok: false, error: '컨디션 매니저 앱에 연결할 수 없습니다 (앱이 실행 중인지 확인하세요).' };
  } finally {
    clearTimeout(timer);
  }
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === 'translate') {
    settings()
      .then((s) =>
        call('/translate', {
          method: 'POST',
          body: JSON.stringify({ texts: msg.texts, lang: msg.lang || s.lang }),
        }),
      )
      .then(sendResponse);
    return true; // 비동기 응답
  }
  if (msg?.type === 'ping') {
    call('/ping').then(sendResponse);
    return true;
  }
  if (msg?.type === 'lang') {
    settings().then((s) => sendResponse({ ok: true, lang: s.lang }));
    return true;
  }
  return false;
});

// 툴바 아이콘 = 옵션 화면 (연결 상태 확인용).
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());
