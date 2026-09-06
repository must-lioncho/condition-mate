// ack-note.mjs — 슬랙에 나가지 않는 전부를 마크다운 한 장으로 남긴다.
//
// 설계 §7: 출력은 두 층이다. 슬랙에 나가는 것은 두 줄·280자 안의 한 덩어리이고,
// 근거·조회한 자료·판단의 과정은 슬랙 본문에 한 줄도 쓰지 않는다. 그 전부가 이
// 파일이 만드는 MD 로 간다.
//
// 두 곳에 남기는 이유는 받는 사람이 이 맥 바깥에 있어서다. 저장소 경로도,
// 대시보드 주소(127.0.0.1 루프백 전용)도 그 사람에게 도달하지 않는다. 스레드에
// 올린 파일만이 실제로 도달한다. 그래서 디스크 기록과 스레드 업로드 둘 다 한다.
//
// 새 관행을 만들지 않았다. OUT_DIR 아래에 데몬 산출물을 두는 것은 items.jsonl ·
// ack-threads.json · media-cache/ 가 이미 하고 있는 방식이고, 여기에 폴더 하나가
// 더 붙을 뿐이다. 업로드는 데몬이 한다 — 이 모듈은 슬랙 토큰을 모른다.

import { mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const clean = (v) => String(v || '').replace(/\s+/g, ' ').trim();

// 파일 이름은 <channel>-<ts>.md. 채널 ID 와 메시지 ts 는 그 자체로 좌표라 사람이
// 슬랙에서 되찾아 갈 수 있다. 본문에서 이름을 뽑아 붙이지 않는 이유는 그렇게 하면
// 파일 이름에 사람 이름이나 사건 이름이 실려 디스크에 남기 때문이다.
export function noteFileName(channel, ts) {
  const safe = (v) => String(v || '').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 40);
  return `${safe(channel) || 'unknown'}-${safe(ts) || '0'}.md`;
}

function section(title, body) {
  const s = String(body || '').trim();
  return s ? [`## ${title}`, '', s, ''] : [];
}

// 원장에 남길 한 장. 슬랙에 나간 한 줄이 무엇이고, 나가지 않은 나머지가 무엇이며,
// 어떤 등급으로 왜 그렇게 판정했는지가 한 곳에 보이게 쓴다. 판정 사유를 빼면
// 나중에 "왜 이 답이 이렇게 짧지" 가 다시 사람의 일이 된다.
// audience 는 이 한 장이 어디까지 가는지다. 두 벌을 만드는 이유는 하나다 — 디스크에
// 남기는 것과 스레드에 올리는 것은 같은 사실이 아니다.
//
// 스레드에 올리는 판에는 다른 스레드 검색 결과·Jira·용어집·첨부 원문·스레드 컨텍스트를
// 싣지 않는다. 앞의 셋은 이 스레드 사람들이 원래 볼 수 있는 자리가 아니다 — 근거를
// 붙이려다 다른 대화를 이 방으로 옮겨 오면 그것이 새 사고다. 뒤의 둘은 이미 이 스레드에
// 있는 것이라 다시 올릴 이유가 없다. 남는 것은 우리가 쓴 답과 그 판단, 그리고 공개 웹
// 자료다. 디스크 판은 전부 담는다 — 그것은 이 맥 밖으로 나가지 않는다.
// 사람 조회(축 0)는 스레드 판에도 넣는다. 그 내용은 메시지 1 로 이미 같은 스레드에
// 나간 것이라 새 노출이 아니고, 오히려 슬랙 메시지에서 사람 수 상한에 걸려 떨어진
// 나머지가 이 파일에만 남기 때문이다. 단 허용목록 밖 필드는 디스크 판에도 담기지
// 않는다 — 그것은 people-context.mjs 가 애초에 반환하지 않는다.
const THREAD_SAFE = new Set(['sent', 'overflow', 'detail', 'research', 'people']);

export function renderNote({
  channel = '', channelName = '', ts = '', permalink = '', author = '',
  grade = '', gradeReason = '', frameGrade = '', frameReason = '',
  requestLevel = null, language = '', message = '', sent = '', overflow = '',
  detail = '', evidence = {}, research = '', novelty = null, people = '', ctxGrade = '', at = new Date(),
  audience = 'disk',
} = {}) {
  const thread = audience === 'thread';
  const pick = (key, value) => (thread && !THREAD_SAFE.has(key) ? '' : value);
  const when = at instanceof Date ? at.toISOString() : String(at);
  const lines = [
    `# ${channelName || channel} · ${ts}`,
    '',
    `- 시각: ${when}`,
    `- 작성자: ${author || '(알 수 없음)'}`,
    `- 응답 등급: ${grade || '(없음)'}${gradeReason ? ` — ${gradeReason}` : ''}`,
    ...(frameGrade ? [`- 문제 정의 등급: ${frameGrade}${frameReason ? ` — ${frameReason}` : ''}`] : []),
    ...(requestLevel === null || requestLevel === undefined ? [] : [`- 근거 깊이(내부 값): L${requestLevel}`]),
    ...(language ? [`- 응답 언어: ${language}`] : []),
    ...(novelty ? [`- 신규성: ${novelty.novel ? '있음' : '없음'}`
      + `${novelty.overlap === null || novelty.overlap === undefined ? '' : ` · 스레드 중복 ${novelty.overlap}`}`
      + `${novelty.afterOverlap === null || novelty.afterOverlap === undefined ? '' : ` · 이후 메시지 중복 ${novelty.afterOverlap}`}`
      + `${novelty.reason ? ` · ${novelty.reason}` : ''}`] : []),
    ...(ctxGrade ? [`- 사람 조회 등급: ${ctxGrade}`] : []),
    ...(permalink ? [`- 원문: ${permalink}`] : []),
    '',
    ...section('사람 조회', pick('people', people)),
    ...section('슬랙에 나간 것', pick('sent', sent)),
    ...section('슬랙에 나가지 않은 나머지', pick('overflow', overflow)),
    ...section('근거와 판단', pick('detail', detail)),
    ...section('조회한 공개 자료', pick('research', research)),
    ...section('원문', pick('message', message)),
    ...section('스레드 컨텍스트', pick('context', clean(evidence.context))),
    ...section('스레드에 공유된 문서', pick('notion', clean(evidence.notion))),
    ...section('Jira', pick('jira', clean(evidence.jira))),
    ...section('다른 스레드', pick('related', clean(evidence.related))),
    ...section('용어집', pick('glossary', clean(evidence.glossary))),
    ...section('첨부에서 뽑아낸 텍스트', pick('attachments', clean(evidence.attachments))),
  ];
  return lines.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}

// 디스크에 남긴다. items.jsonl 과 같은 임시 파일 후 rename — 중간에 죽어도 반쯤
// 쓰인 파일이 남지 않는다. 실패해도 던지지 않는다: MD 를 못 남긴 것이 슬랙 응답을
// 막을 이유는 없고, 사유는 호출부가 로그로 남긴다.
export function writeNote(dir, fileName, body) {
  try {
    mkdirSync(dir, { recursive: true });
    const path = join(dir, fileName);
    const tmp = `${path}.tmp`;
    writeFileSync(tmp, body);
    renameSync(tmp, path);
    return { ok: true, path };
  } catch (e) {
    return { ok: false, error: String(e?.message || e).slice(0, 120) };
  }
}

export default { noteFileName, renderNote, writeNote };
