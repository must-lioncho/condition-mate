// 설치 시점에 Scripts/install-jira-ext.sh 가 이 파일을 다시 써서 토큰을 심는다.
// 레포에 있는 원본은 언제나 빈 토큰이다 — 토큰이 깃에 들어가면 안 된다.
//
// 토큰이 비어 있으면 익스텐션은 chrome.storage 에 저장된 값을 쓴다(옵션 화면에서 입력).
// 설치 스크립트를 쓰면 옵션 화면을 건드릴 일이 없다.
globalThis.CMJT_CONFIG = {
  bridge: 'http://127.0.0.1:17321',
  token: '',
  lang: 'ko',
};
