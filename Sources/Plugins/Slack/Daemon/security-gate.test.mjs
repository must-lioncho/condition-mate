// 보안 게이트. 사용법은 이웃한 reply-language.test.mjs 와 같다:
//   node security-gate.test.mjs "$PWD"
//
// 고정값은 전부 items.jsonl 에서 그대로 가져왔다. 지어낸 문장으로 게이트를 맞추면
// 통과하는 것은 테스트뿐이다 — 옛 규칙이 90% 오탐이었던 것도 실제 메시지가 아니라
// 머릿속 예문으로 정규식을 지었기 때문이다.
const D = process.argv[2];
const { securityGate } = await import(`${D}/security-gate.mjs`);

let pass = 0, fail = 0;
const t = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  ok ? pass++ : fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : `\n        got  ${JSON.stringify(got)}\n        want ${JSON.stringify(want)}`}`);
};
const kind = (s) => securityGate(s)?.kind ?? null;

// ---- 서야 하는 것 (전수 8건 전부) ------------------------------------------------

t('API 키를 달라',
  kind('to @Lion cho (조중현,Cho Chung Hyun), please provide me the API key .'), 'credential');
t('내 급여 정보를 달라',
  kind('@Lion cho (조중현,Cho Chung Hyun) please provide me my salary information'), 'compensation');
t('공유 시크릿을 보내라',
  kind('Send me the shared secret out of band and I will have a PR up today.'), 'credential');
t('트위터 계정 자격증명을 공유해 달라',
  kind('To @Lion cho (조중현,Cho Chung Hyun) Please share Twitter account credentials!'), 'credential');
t('x 계정 자격증명을 달라',
  kind('Please provide me x account credentials and please share the complete context.'), 'credential');
t('이메일과 비밀번호를 보내라',
  kind('send email and password for twitter'), 'credential');
t('자격증명을 개인적으로 공유해 달라',
  kind('@Abdul Rehman can you please share the credentials privately?'), 'credential');
t('급여 시트를 공유해 주겠다',
  kind('@Lion cho you need separate sheet or I can share to you the payroll sheet of finance'),
  'compensation');

// ---- 서면 안 되는 것 -------------------------------------------------------------

// 2026-09-02 라이언이 지적한 그 메시지. "we need to consider" 와 URL 안의 "password"
// 가 3천 자를 사이에 두고 만나 게이트가 섰고, 그래서 영어 본문이 번역되지 않았다.
t('업무 보고 끝에 붙은 비밀번호 관리자 링크', kind(
  `With x accounts going for 7k, 8k.\n\n`
  + `I think from a business standpoint it might be a good idea to still try to appeal and try `
  + `to recover the our system x accounts: mpc_miningrwa handle.\n\n`
  + `-what we need to consider from ben consulting\n`
  + `-target budget : $4K~$7K\n`
  + `-password: https://password.must.company/app/passwords/view/ff809002-d2ce-40ba-b782-6c7a92962bac`),
  null);

// 2026-09-01 사고 그대로. "checklist" 의 list 와 "token-sale" 의 token 이 함께 있다는
// 이유만으로 게이트가 서서, 달라고 한 적 없는 사람에게 훈계가 나갔다.
t('checklist + token 이 같이 있는 업무 글',
  kind('Here is the checklist for the token sale page, please show it to Ben when ready.'), null);

t('코인을 뜻하는 token', kind('Meets Binance due diligence criteria for token listing.'), null);
t('설계 논의 안의 opaque token',
  kind('Put an opaque token in the `start` payload, not the waitlist id.'), null);
t('보안 상태를 설명하는 문장(요청이 아니다)',
  kind('container DB, no backup, plaintext secrets are expected for PoC, not for a shared demo'),
  null);
t('시드 문구를 설명하는 감사 결과',
  kind('In msquare the backend generates the wallet and returns the seed phrase to the client.'),
  null);
t('급여를 논평하는 문장',
  kind('First, the salary he requested is beyond our budget, so we should counter.'), null);
t('빈 문자열', kind(''), null);

// 줄이 갈리면 붙지 않는다 — 근접 규칙이 실제로 도는지.
t('요청과 명사가 다른 줄',
  kind('Please share the deck with Ben.\nThe password manager entry is already set up.'), null);

// ---- 근거 줄을 돌려주는가 --------------------------------------------------------
t('걸린 줄을 함께 돌려준다',
  securityGate('오늘 회의 정리했습니다.\nAPI key 를 알려주세요.')?.line,
  'API key 를 알려주세요.');

console.log(`\n${fail ? 'FAIL' : 'OK'}  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
