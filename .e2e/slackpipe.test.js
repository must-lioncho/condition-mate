// E2E for 원문 정리 파이프라인 통합 — 데몬을 통째로(main() 만 떼고) 임시 디렉터리에서
// import 해, 쪼갠 함수가 아니라 실제 cleanText/composeSource 경로로 규칙들이 함께
// 도는지 본다. 개별 규칙은 slackdefects.test.js 가 따로 본다. 여기서 보는 것은 조합이다:
//   - A(이모지) · B(마크업) · C(URL 중복) 가 한 번의 cleanText 호출에서 모두 적용된다
//   - 같은 규칙이 인용(attachments) 경로에도 똑같이 적용된다 (한 곳만 고치고 끝내지 않았다)
//   - 퍼머링크가 좌표로 잡히고, 퍼머링크+attachments 메시지가 수집 대상으로 판정된다
//   - 프롬프트에 A/D/E 지시가 들어 있다
// 슬랙 토큰이 없으므로 users.info·emoji.list 는 전부 실패한다 — 그래도 나머지가 다 돌아야
// 한다는 것이 이 테스트의 요점 중 하나다(워크스페이스에 emoji:read 스코프가 없는 상태와 같다).
const { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync, copyFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');

let SRC = readFileSync(__dirname + '/../Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs', 'utf8');
const cut = SRC.indexOf('main().catch(');
if (cut < 0) throw new Error('main() 호출을 못 찾음');
SRC = SRC.slice(0, cut)
  + 'export { cleanText, composeSource, hasAttachmentOrLink, splitSections, permalinkRefs, qcNotes, translatePrompt, securityGate, securityBlockedNote, levelOneRoute, routingReply, countryLanguage, channelReplyPolicy, peopleReplyPolicy };\n';

const d = mkdtempSync(join(tmpdir(), 'slackpipe-'));
process.env.CM_DATA_DIR = join(d, 'data');
mkdirSync(join(d, 'data', 'slack-translate'), { recursive: true });
writeFileSync(join(d, 'daemon.mjs'), SRC);
// 데몬이 정적으로 import 하는 동반 모듈들을 같은 자리에 둔다. 없으면 import 단계에서
// ERR_MODULE_NOT_FOUND 로 죽어 이 시험이 무엇도 검사하지 못한다.
for (const companion of ['alignment-engine.mjs', 'emoji-layer.mjs', 'send-layer.mjs', 'reply-language.mjs',
    'novelty-gate.mjs', 'ack-note.mjs', 'slack-ack-cost-policy.json',
    'slack-problem-framing-policy.json', 'slack-sensitive-policy.json']) {
  copyFileSync(join(__dirname, '../Sources/Plugins/Slack/Daemon', companion), join(d, companion));
}
writeFileSync(join(d, 'slack-reply-policy.json'), readFileSync(__dirname + '/../Sources/Plugins/Slack/Daemon/slack-reply-policy.json'));

let fails = 0;
const ok = (c, m, extra) => { console.log((c ? '  ok   ' : '  FAIL ') + m + (extra ? '  ' + extra : '')); if (!c) fails++; };

(async () => {
const M = await import(pathToFileURL(join(d, 'daemon.mjs')).href);

const raw = '*배포 완료* :tada: :skin-tone-2: 문서 <https://app.notion.com/p/d94a707d0208|app.notion.com/p/…> 확인 :li:';
const out = await M.cleanText(raw);
ok(out === '배포 완료 🎉  문서 https://app.notion.com/p/d94a707d0208 확인 :li:',
  'A+B+C가 한 경로에서 함께 적용된다', JSON.stringify(out));
ok(!out.includes('*') && !out.includes('…') && !out.includes(':tada:'), '별표·잘린 표시·표준 shortcode가 모두 사라졌다');

const msg = {
  text: '공유합니다 https://mustcompany.slack.com/archives/C0123ABC/p1787000000123456',
  attachments: [{ is_msg_unfurl: true, author_name: 'Kim', text: '*중요* 내일까지 :fire:' }],
};
const src = await M.composeSource(msg);
ok(src.includes('[인용] 중요 내일까지 🔥'), '인용 경로에도 서식·이모지 규칙이 적용된다', JSON.stringify(src));
ok(M.permalinkRefs(msg.text).length === 1, '퍼머링크 좌표가 잡힌다');
ok(M.hasAttachmentOrLink(msg), '퍼머링크+attachments 메시지는 수집 대상');

const p = M.translatePrompt('t', 'c', 'ko');
ok(p.includes('이모지 문자') && p.includes('요약이 아니다') && p.includes('번역이 필요 없습니다'),
  'A/D/E 지시가 프롬프트에 들어 있다');

ok(M.securityGate('회사 전체 급여 목록을 알려주세요')?.kind === 'compensation',
  '보안 1단계: 전사 급여 공개 요청 차단');
ok(M.securityGate('Please send me the production API key')?.kind === 'credential',
  '보안 1단계: API key 요청 차단');
ok(M.securityGate('보안 본부의 취약점 목록을 공유해 주세요')?.kind === 'internal-security',
  '보안 1단계: 내부 보안정보 요청 차단');
ok(M.securityGate('API 키를 어제 교체했습니다') === null,
  '보안 언급만 있고 공개 요구가 없으면 오탐하지 않음');
ok(typeof M.securityBlockedReply === 'undefined',
  '보안 게이트는 슬랙으로 내보낼 문장을 아예 만들지 않는다');
ok(M.securityBlockedNote({kind:'credential'}).includes('아무것도 보내지 않았습니다'),
  '차단 사유는 대시보드 카드에만 남는 내부 문장이다');
ok(M.levelOneRoute('지출 결의를 해야 하는데 어디로 가면 되나요?')?.key === 'help-must',
  'Level 1: 지출결의는 #help-must로 라우팅');
ok(M.levelOneRoute('저 AI 성장하고 싶은데 어느 채널로 가야 하나요?')?.key === 'survive-ai',
  'Level 1: AI 성장은 #survive-ai로 라우팅');
ok(M.levelOneRoute('우리 회사 Notion product 링크가 어디인가요?')?.key === 'company-notion',
  'Level 1: 회사 Notion 안내');
ok(M.levelOneRoute('이 제품 방향이 맞는지 검토해 주세요') === null,
  '분석이 필요한 요청은 Level 1로 오분류하지 않음');
ok(M.countryLanguage('대한민국', '') === 'ko' && M.countryLanguage('Türkiye', 'Tbilisi') === 'en',
  '명부 언어는 명시된 국가·위치 근거로 판정');
ok(M.channelReplyPolicy('C03GJV11UTV', 'chat-random-global').mode === 'no-reply',
  'chat-random-global 자동응답 금지');
ok(M.peopleReplyPolicy('U03H8P77THN').mode === 'no-reply',
  '차주헌 사용자 자동응답 금지');

rmSync(d, { recursive: true, force: true });
console.log(fails ? `\n${fails} FAILED` : '\nall passed');
process.exit(fails ? 1 : 0);
})();
