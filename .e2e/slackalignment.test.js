// Regression gate for execution alignment. Topic overlap alone must never produce YES.
const path = require('node:path');

let fails = 0;
const ok = (condition, label) => {
  console.log((condition ? '  ok   ' : '  FAIL ') + label);
  if (!condition) fails++;
};

(async () => {
  const engine = await import(path.join(__dirname, '../Sources/Plugins/Slack/Daemon/alignment-engine.mjs'));
  const message = 'Understood. Approach + Target date on all 10 rows. Monday 10AM Indian Time.';
  const context = '[Slack thread context — same topic]\nLion: find problem in notion of my approach and checklist with approach and target date';
  const extracted = {
    has_basis: true,
    purpose: 'Confirm the technical proposal plan',
    intent_label: 'Alignment',
    intent_summary: 'Provide approach and target dates by Monday',
    expected_problem: 'Agree on an approach and deadline',
    original_problem: 'Review the proposed technical approach',
    deliverable: 'Approach and target date',
    target: 'all 10 rows',
    owner: 'Hamilton',
    deadline: 'Monday 10AM',
    timezone: 'Indian Time',
    unresolved_references: [{ phrase: 'all 10 rows', resolved: false, evidence: '' }],
  };
  const input = { text: message, context, jira: '', extra: {}, language: 'en' };
  const verdict = engine.alignmentVerdict(extracted, input);
  ok(verdict.aligned === false, '정확한 10개 행을 식별할 수 없으면 Alignment NO');
  ok(verdict.reasons.some((x) => x.startsWith('NO_UNRESOLVED_SCOPE')), 'NO 사유는 unresolved scope로 고정');
  // 2026-08-31 두 축 구조: 판정은 원장에만 남고, 나가는 글에는 라벨이 한 줄도 없다
  // (docs/slack-ack-two-axis-design.md §3). renderAcknowledgement(v1 직렬화기)는 지웠다.
  ok(typeof engine.renderAcknowledgement === 'undefined'
    && typeof engine.renderAcknowledgementV2 === 'undefined',
    '라벨을 붙이던 옛 렌더러 둘은 남아 있지 않다');
  const rendered = engine.renderReply(
    { has_basis: true, adds: 'the exact 10 rows are still unidentified',
      reply: 'Alignment: The ten rows are not identified anywhere in the thread.' }, {});
  ok(!/Alignment:|Purpose:|Answer:/.test(rendered),
    '모델이 라벨을 뱉어도 wire 에는 라벨이 닿지 않는다', JSON.stringify(rendered));
  ok(engine.renderReply({ has_basis: true, adds: '', reply: 'anything' }, {}) === null,
    '무엇을 더하는지 대지 못하면 글 자체가 만들어지지 않는다');
  // 근거 깊이는 렌더러의 분기가 아니다 (설계 §5-1). L4 여도 직답이 그대로 나간다.
  ok(engine.renderReply({ has_basis: true, adds: 'x', reply: 'The register was filed on 12 March.' },
    { requestLevel: 4 }) === 'The register was filed on 12 March.',
    '근거를 많이 모았다고 직답이 사라지지 않는다');

  const resolvedContext = context + '\nLion: Use the 10 entries in https://notion.so/team/technical-proposals database table.';
  const resolved = { ...extracted, unresolved_references: [{
    phrase: 'all 10 rows', resolved: true,
    evidence: 'Use the 10 entries in https://notion.so/team/technical-proposals database table.',
  }] };
  ok(engine.alignmentVerdict(resolved, { ...input, context: resolvedContext }).aligned === true,
    '정확한 위치가 근거 원문으로 해소되면 YES');

  const hallucinated = { ...resolved, unresolved_references: [{
    phrase: 'all 10 rows', resolved: true, evidence: 'A secret Notion database not present in context',
  }] };
  ok(engine.alignmentVerdict(hallucinated, input).aligned === false,
    '모델이 근거에 없는 위치를 지어내도 코드가 NO로 되돌린다');

  ok(engine.parseExtraction('```json\n{"has_basis":true}\n```')?.has_basis === true,
    '작은 모델의 JSON 코드 펜스도 안전하게 파싱한다');
  ok(engine.parseExtraction('Alignment: YES') === null,
    '자유형 YES는 판정 입력으로 인정하지 않는다');

  // 이 값은 이제 원장에만 남는 내부 값이다. 계산 자체는 그대로 검사한다.
  ok(engine.evidenceRequestLevel({}) === 2, '현재 스레드만 쓰면 L2');
  ok(engine.evidenceRequestLevel({ research: '[Web research · genspark · 공개 웹 자료이며 우리 회사의 확정 사실이 아님]\n- KYC — rules — https://example.com' }) === 3,
    '공개 웹 조사까지 쓰면 L3');
  ok(engine.evidenceRequestLevel({
    research: '[Web research · genspark · 공개 웹 자료이며 우리 회사의 확정 사실이 아님]\n- KYC — rules — https://example.com',
    notion: '[Notion 문서 · 스레드에 공유됨] shareholder register',
  }) === 4, '공개 조사와 내부 자료를 함께 보면 L4');

  console.log(fails ? `\n${fails} failed` : '\nlevel/alignment checks passed');
  process.exit(fails ? 1 : 0);
})();
