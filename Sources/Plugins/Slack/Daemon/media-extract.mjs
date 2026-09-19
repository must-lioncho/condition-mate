// 슬랙 메시지에 붙은 "글자가 아닌 것"을 번역기가 실제로 읽을 수 있는 재료로 바꾼다.
// 이미지는 비전 파트로, PDF 는 텍스트 레이어(없으면 페이지 래스터)로, 영상은 프레임으로,
// 유튜브·일반 링크는 자막·본문 텍스트로 환원한다. 번역은 하지 않는다 — 데몬이 한다.
//
// 소유자: lion-condition-mate-worker-media-extract. 이 파일 밖은 건드리지 않는다.
// 규격 출처: issue/2026-08-27-slack-번역-멀티모달.md 의 "모듈 인터페이스 계약".
//
// ─────────────────────────────────────────────────────────────────────────────
// 어떤 바이트가 이 맥을 떠나는가 (경로별 외부 전송 명세 — 새 경로를 더하면 여기도 갱신한다)
// ─────────────────────────────────────────────────────────────────────────────
//  A. 슬랙 파일 다운로드 — files.slack.com
//     나가는 것: 파일 URL + `Authorization: Bearer <slackToken>` 헤더.
//     들어오는 것: 첨부 원본 바이트. 이미 슬랙이 가진 데이터를 슬랙에서 되받는 것이므로
//     새 유출은 아니다. 토큰은 slack.com 이외의 어떤 호스트로도 나가지 않는다.
//
//  B. 이미지 / 스캔 PDF 페이지 / 영상 프레임 → inline 파트 (기본 동작)
//     이 모듈은 아무 데도 보내지 않는다. 축소·변환·프레임 추출은 전부 이 맥에서
//     sips·pdftoppm·ffmpeg 로 처리하고, 결과 바이트를 base64 로 담아 호출자에게 돌려줄 뿐이다.
//     ★ 다만 그 파트를 받은 데몬이 Gemini 로 보낸다. 즉 이 경로의 실질 목적지는
//       generativelanguage.googleapis.com 이며, 사내 슬랙 첨부의 축소본이 그리로 나간다.
//       원본이 아니라 축소본이다: 이미지는 긴 변 imageMaxEdge(기본 1280)px JPEG,
//       PDF 는 앞쪽 maxPdfPages(기본 4)장만 PNG 래스터, 영상은 maxVideoFrames(기본 6)장 JPEG.
//       나머지 페이지·프레임과 원본 해상도 바이트는 이 맥을 떠나지 않는다.
//
//  C. opts.mode === 'text' 일 때만 — generativelanguage.googleapis.com
//     이 모듈이 직접 Gemini generateContent 를 호출해 위 파트를 한국어 서술로 바꾼다.
//     나가는 것: 축소된 이미지 파트 + 짧은 지시문. 키는 x-goog-api-key 헤더로만 싣는다.
//     기본값(mode 'inline')에서는 이 호출을 하지 않는다.
//
//  D. PDF 텍스트 레이어 — 아무 것도 나가지 않는다
//     pdftotext 로 이 맥에서 뽑는다. PDF 원본은 이 맥을 떠나지 않는다.
//
//  E. 유튜브 자막 — www.genspark.ai (gsk CLI)
//     나가는 것: 유튜브 video id 뿐. 슬랙 본문도 첨부도 나가지 않는다.
//     들어오는 것: 자막 텍스트. 자막 원천은 젠스파크 서버이지 이 맥이 아니다.
//
//  F. 일반 링크 본문 — www.genspark.ai (gsk CLI)
//     나가는 것: URL 문자열. 젠스파크가 그 URL 을 대신 열어 본문을 돌려준다.
//     ★ URL 자체가 사내 정보일 수 있으므로 사설/내부 호스트는 아예 보내지 않는다
//       (isPublicHttpUrl 참조: localhost, RFC1918, *.local, *.internal, 점 없는 호스트,
//        slack.com 계열은 전부 차단하고 method 'skipped-private-host' 로 돌려준다).
//
//  그 밖의 엔드포인트로 나가는 경로는 없다. tesseract 와 yt-dlp 는 이 맥에 없어서 쓰지 않는다.
//
// ─────────────────────────────────────────────────────────────────────────────
// 인터페이스 계약 (데몬 쪽은 이 주석만 읽고 붙일 수 있어야 한다)
// ─────────────────────────────────────────────────────────────────────────────
//  collectRefs(msg) -> Ref[]
//    동기. 부작용 없음. 예외를 던지지 않는다(입력이 무엇이든 배열을 돌려준다).
//    Ref = { kind:'file', url, mimetype, name, size, id? }
//        | { kind:'link', url }
//    같은 url 은 한 번만 담는다. 슬랙 permalink·멘션·mailto 같은 잡음은 걸러낸다.
//
//  await extractEvidence(refs, opts) -> { evidence: Evidence[], notes: string[] }
//    ★ 절대 예외를 밖으로 던지지 않는다. 첨부 하나가 실패해도 나머지와 메시지 전체는 산다.
//    Evidence = {
//      ref,                                  // 입력 Ref 그대로
//      type,                                 // 'image'|'pdf'|'video'|'youtube'|'link'|'audio'|'unknown'
//      text,                                 // 프롬프트에 그대로 넣을 수 있는 문자열 (없으면 '')
//      inline: [{ mimeType, dataB64 }],      // 비전 모델에 그대로 넘길 파트 (없으면 [])
//      method,                               // 실제로 근거를 만든 기법 이름 ('pdftotext' 등)
//      error,                                // 성공하면 null, 실패하면 사람이 읽는 짧은 사유 문자열
//    }
//    실패는 값이다. 못 뽑았다는 사실과 뽑을 게 없었다는 사실을 구분하려고
//    error 는 성공 시에도 키가 존재하며 null 이다. `if (e.error)` 로 판정하면 된다.
//    notes 는 문자열 배열이다(잘라낸 페이지 수, 빠진 도구 이름 등). 프롬프트에 넣으려면
//    notes.join(' / ') 처럼 합쳐 쓰면 된다.
//
//    opts = {
//      slackToken,        // 슬랙 파일 다운로드용. 이 모듈은 로그·에러·캐시에 절대 쓰지 않는다.
//      geminiKey,         // mode 'text' 일 때만 쓴다. 마찬가지로 절대 기록하지 않는다.
//      geminiModel,       // 예: 'gemini-2.0-flash'
//      cacheDir,          // 콘텐츠 해시 기반 캐시 위치. 없으면 캐시 없이 동작한다.
//      timeoutMs,         // 외부 호출 하나당 상한 (기본 30000)
//      // ↓ 이하는 선택. 안 주면 DEFAULTS 를 쓴다. 계약을 바꾸지 않는 순수 추가분이다.
//      mode, totalBudgetMs, maxDownloadBytes, maxVideoBytes, maxInlineBytes,
//      maxInlineTotalBytes, maxInlineParts, maxPdfPages, maxVideoFrames,
//      maxTextChars, imageMaxEdge, geminiEndpoint,
//    }
//
//  await probeTools() -> { [도구이름]: 절대경로|null }
//    선택 진단용. 어느 경로가 도구 부재로 막혔는지 데몬이 로그에 남길 수 있게 한다.
//
// 규격을 바꿔야 할 일이 생기면 말없이 바꾸지 않는다. 붙이는 쪽이 조용히 깨진다.

import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// ── 기본값 ────────────────────────────────────────────────────────────────────
const DEFAULTS = {
  mode: 'inline',                        // 'inline' | 'text'
  timeoutMs: 30_000,                     // 외부 호출 하나당
  totalBudgetMs: 180_000,                // 메시지 하나 전체. 넘으면 남은 참조는 budget-exceeded
  maxDownloadBytes: 32 * 1024 * 1024,    // 일반 첨부 다운로드 상한
  maxVideoBytes: 96 * 1024 * 1024,       // 영상만 따로 (프레임만 뽑고 버리므로 조금 넉넉히)
  maxInlineBytes: 4 * 1024 * 1024,       // inline 파트 하나 상한 (base64 이전 원본 바이트)
  maxInlineTotalBytes: 16 * 1024 * 1024, // 한 메시지에서 만들어내는 inline 파트 총량
  maxInlineParts: 8,                     // 참조 하나가 만들 수 있는 파트 수
  maxPdfPages: 4,                        // 스캔본 PDF 래스터 상한
  maxVideoFrames: 6,                     // 영상 프레임 상한
  maxTextChars: 12_000,                  // text 하나의 길이 상한
  imageMaxEdge: 1280,                    // 축소 후 긴 변 픽셀
  jpegQuality: 68,
  linkCacheTtlMs: 6 * 60 * 60 * 1000,    // 링크·유튜브처럼 내용이 변할 수 있는 것만 TTL
  geminiEndpoint: 'https://generativelanguage.googleapis.com/v1beta',
};

const EMPTY = () => ({ evidence: [], notes: [] });

// text 는 "이미지 파트를 같이 보라"고 가리키는 문장으로 끝난다. mode 'text' 로 파트를 서술로
// 바꿔 비워버리면 그 문장이 거짓말이 되므로, 한 군데 상수로 두고 그때 잘라낸다.
const SEE_PARTS = ' 내용은 함께 실린 이미지 파트를 보라.';

// ── 도구 찾기 ─────────────────────────────────────────────────────────────────
// launchd 로 뜬 데몬은 PATH 가 빈약하다. 절대경로 후보를 먼저 훑고, 없으면 PATH 를 뒤진다.
// "있겠거니" 하고 만든 경로는 도구가 없는 순간 조용히 죽는다. 그래서 매번 확인한다.
const TOOL_HINTS = {
  pdftotext: ['/opt/homebrew/bin/pdftotext', '/usr/local/bin/pdftotext'],
  pdftoppm: ['/opt/homebrew/bin/pdftoppm', '/usr/local/bin/pdftoppm'],
  pdfinfo: ['/opt/homebrew/bin/pdfinfo', '/usr/local/bin/pdfinfo'],
  ffmpeg: ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'],
  ffprobe: ['/opt/homebrew/bin/ffprobe', '/usr/local/bin/ffprobe'],
  sips: ['/usr/bin/sips'],
  gsk: [path.join(os.homedir(), '.local', 'bin', 'gsk'), '/opt/homebrew/bin/gsk', '/usr/local/bin/gsk'],
};
const PATH_DIRS = ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'];
const toolCache = new Map();

async function toolPath(name) {
  if (toolCache.has(name)) return toolCache.get(name);
  const cands = [...(TOOL_HINTS[name] || []), ...PATH_DIRS.map((d) => path.join(d, name))];
  let found = null;
  for (const c of cands) {
    try { await fs.access(c, fs.constants.X_OK); found = c; break; } catch { /* 다음 후보 */ }
  }
  toolCache.set(name, found);
  return found;
}

/** 어느 도구가 있고 없는지 그대로 돌려준다. 데몬이 기동 로그에 남기라고 있는 것. */
export async function probeTools() {
  const out = {};
  for (const name of Object.keys(TOOL_HINTS)) out[name] = await toolPath(name);
  return out;
}

// ── 작은 유틸 ─────────────────────────────────────────────────────────────────
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const sha1 = (s) => createHash('sha1').update(String(s)).digest('hex');

// 에러 문구에 쿼리스트링을 남기지 않는다. 슬랙 파일 URL 뒤에는 토큰이 붙어 오기도 한다.
function safeUrl(u) {
  try {
    const p = new URL(String(u));
    const s = `${p.protocol}//${p.host}${p.pathname}`;
    return s.length > 140 ? `${s.slice(0, 137)}...` : s;
  } catch {
    return '(url)';
  }
}

function clip(s, max) {
  // 캐리지리턴만 걷어내고 공백은 살린다. 여기서 공백을 지우면 본문이 통째로 붙어버린다.
  const t = String(s ?? '').replace(/\r/g, '').replace(/\n{3,}/g, '\n\n').trim();
  if (t.length <= max) return { text: t, cut: 0 };
  return { text: `${t.slice(0, max)}\n…(이하 ${t.length - max}자 생략)`, cut: t.length - max };
}

function humanBytes(n) {
  if (!Number.isFinite(n)) return '?';
  if (n < 1024) return `${n}B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)}KB`;
  return `${(n / 1024 / 1024).toFixed(1)}MB`;
}

// 외부 프로세스를 돌린다. 절대 throw 하지 않고 결과를 값으로 돌려준다.
function run(file, args, { timeoutMs, encoding = 'utf8', maxBuffer = 64 * 1024 * 1024, cwd } = {}) {
  return new Promise((resolve) => {
    let child;
    try {
      child = execFile(
        file, args,
        { timeout: timeoutMs, killSignal: 'SIGKILL', maxBuffer, encoding, cwd, windowsHide: true },
        (err, stdout, stderr) => {
          resolve({
            ok: !err,
            stdout: stdout ?? (encoding === 'buffer' ? Buffer.alloc(0) : ''),
            stderr: String(stderr ?? ''),
            timedOut: !!(err && err.killed),
            error: err ? String(err.message || err).split('\n')[0] : null,
          });
        },
      );
    } catch (e) {
      resolve({ ok: false, stdout: encoding === 'buffer' ? Buffer.alloc(0) : '', stderr: '', timedOut: false, error: String(e && e.message ? e.message : e) });
      return;
    }
    child.on('error', () => { /* 콜백에서 이미 처리된다 */ });
  });
}

// 사설·내부 호스트는 외부 크롤러에 넘기지 않는다. URL 자체가 사내 정보인 경우가 있다.
function isPublicHttpUrl(u) {
  let p;
  try { p = new URL(String(u)); } catch { return false; }
  if (p.protocol !== 'http:' && p.protocol !== 'https:') return false;
  const h = p.hostname.toLowerCase();
  if (!h.includes('.')) return false;                       // 점 없는 사내 호스트명
  if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.internal') || h.endsWith('.lan')) return false;
  if (/^127\./.test(h) || /^10\./.test(h) || /^192\.168\./.test(h)) return false;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(h)) return false;
  if (/^169\.254\./.test(h) || h === '0.0.0.0' || h === '::1' || h.startsWith('[')) return false;
  if (h === 'slack.com' || h.endsWith('.slack.com') || h.endsWith('.slack-edge.com')) return false;
  return true;
}

// ── 캐시 (콘텐츠 해시 기반) ───────────────────────────────────────────────────
// 같은 첨부를 두 번 받지 않는다. 다운로드 바이트는 URL 키로, 뽑아낸 근거는 콘텐츠 해시 키로.
async function cacheRead(cfg, kind, key, ttlMs) {
  if (!cfg.cacheDir) return null;
  try {
    const p = path.join(cfg.cacheDir, kind, `${sha1(key)}.json`);
    const rec = JSON.parse(await fs.readFile(p, 'utf8'));
    if (ttlMs && Date.now() - (rec.at || 0) > ttlMs) return null;
    return rec.val;
  } catch { return null; }
}

async function cacheWrite(cfg, kind, key, val) {
  if (!cfg.cacheDir) return;
  try {
    const dir = path.join(cfg.cacheDir, kind);
    await fs.mkdir(dir, { recursive: true });
    const body = JSON.stringify({ at: Date.now(), val });
    if (body.length > 48 * 1024 * 1024) return;   // 캐시가 디스크를 잡아먹지 않게
    const p = path.join(dir, `${sha1(key)}.json`);
    const tmp = `${p}.${process.pid}.tmp`;
    await fs.writeFile(tmp, body);
    await fs.rename(tmp, p);
  } catch { /* 캐시 실패는 추출 실패가 아니다 */ }
}

async function blobRead(cfg, key) {
  if (!cfg.cacheDir) return null;
  try {
    const p = path.join(cfg.cacheDir, 'blob', sha1(key));
    const bytes = await fs.readFile(p);
    let meta = {};
    try { meta = JSON.parse(await fs.readFile(`${p}.json`, 'utf8')); } catch { /* 없어도 된다 */ }
    return { bytes, contentType: meta.contentType || '' };
  } catch { return null; }
}

async function blobWrite(cfg, key, bytes, contentType) {
  if (!cfg.cacheDir) return;
  try {
    const dir = path.join(cfg.cacheDir, 'blob');
    await fs.mkdir(dir, { recursive: true });
    const p = path.join(dir, sha1(key));
    const tmp = `${p}.${process.pid}.tmp`;
    await fs.writeFile(tmp, bytes);
    await fs.rename(tmp, p);
    await fs.writeFile(`${p}.json`, JSON.stringify({ contentType, size: bytes.length, at: Date.now() }));
  } catch { /* 무시 */ }
}

// ── 1) collectRefs ────────────────────────────────────────────────────────────
const SLACK_ESC = (s) => String(s)
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

// 링크로 볼 가치가 없는 것들. permalink 는 메시지 자기 자신이라 근거가 되지 않는다.
function isNoiseLink(u) {
  const s = String(u);
  if (!/^https?:\/\//i.test(s)) return true;
  if (/slack\.com\/archives\//i.test(s)) return true;
  if (/slack\.com\/team\//i.test(s)) return true;
  if (/^https?:\/\/[^/]*slack-edge\.com\//i.test(s)) return true;   // 이모지·아바타
  if (/\/emoji\//i.test(s)) return true;
  return false;
}

function pushLink(out, seen, url) {
  if (!url) return;
  let u = SLACK_ESC(url).trim().replace(/[),.;:!?'"]+$/, '');
  if (!u || isNoiseLink(u)) return;
  try { u = new URL(u).toString(); } catch { return; }
  const k = `link:${u}`;
  if (seen.has(k)) return;
  seen.add(k);
  out.push({ kind: 'link', url: u });
}

function scanText(out, seen, text) {
  if (!text || typeof text !== 'string') return;
  const t = SLACK_ESC(text);
  // 슬랙 표기 <http://…|라벨> 을 먼저 걷어낸 뒤 남은 맨 URL 을 훑는다.
  const marked = /<((?:https?):\/\/[^>|\s]+)(?:\|[^>]*)?>/g;
  let m;
  while ((m = marked.exec(t)) !== null) pushLink(out, seen, m[1]);
  const bare = t.replace(marked, ' ');
  const re = /https?:\/\/[^\s<>"'`\])]+/g;
  while ((m = re.exec(bare)) !== null) pushLink(out, seen, m[0]);
}

function pushFile(out, seen, f) {
  if (!f || typeof f !== 'object') return;
  if (f.mode === 'tombstone' || f.deleted === true) return;
  const url = f.url_private_download || f.url_private || f.permalink_public || f.url_private_share || '';
  if (!url || typeof url !== 'string') return;
  const key = `file:${f.id || url}`;
  if (seen.has(key)) return;
  seen.add(key);
  out.push({
    kind: 'file',
    url,
    mimetype: String(f.mimetype || f.filetype || '') || '',
    name: String(f.name || f.title || f.id || 'file'),
    size: Number(f.size || 0) || 0,
    id: f.id ? String(f.id) : undefined,
  });
}

function walkBlocks(out, seen, node, depth) {
  if (!node || depth > 8) return;
  if (Array.isArray(node)) { for (const n of node) walkBlocks(out, seen, n, depth + 1); return; }
  if (typeof node !== 'object') return;
  if (typeof node.url === 'string') pushLink(out, seen, node.url);
  if (typeof node.image_url === 'string') pushLink(out, seen, node.image_url);
  if (typeof node.text === 'string') scanText(out, seen, node.text);
  for (const k of ['elements', 'blocks', 'fields', 'accessory', 'text', 'title']) {
    if (node[k] && typeof node[k] === 'object') walkBlocks(out, seen, node[k], depth + 1);
  }
}

/**
 * 슬랙 메시지 하나에서 "글자가 아닌 것"으로 갈 수 있는 참조를 모은다.
 * 동기, 부작용 없음, 어떤 입력에도 예외를 던지지 않는다.
 */
export function collectRefs(msg) {
  const out = [];
  const seen = new Set();
  try {
    if (!msg || typeof msg !== 'object') return out;

    if (Array.isArray(msg.files)) for (const f of msg.files) pushFile(out, seen, f);
    if (msg.file && typeof msg.file === 'object') pushFile(out, seen, msg.file);

    scanText(out, seen, msg.text);

    if (Array.isArray(msg.attachments)) {
      for (const a of msg.attachments) {
        if (!a || typeof a !== 'object') continue;
        if (Array.isArray(a.files)) for (const f of a.files) pushFile(out, seen, f);
        for (const k of ['original_url', 'from_url', 'title_link', 'app_unfurl_url', 'image_url', 'video_url', 'thumb_url']) {
          if (typeof a[k] === 'string') pushLink(out, seen, a[k]);
        }
        scanText(out, seen, a.text);
        scanText(out, seen, a.fallback);
        if (Array.isArray(a.blocks)) walkBlocks(out, seen, a.blocks, 0);
      }
    }

    if (Array.isArray(msg.blocks)) walkBlocks(out, seen, msg.blocks, 0);
  } catch {
    // 참조 수집이 메시지 처리를 깨뜨리면 안 된다. 지금까지 모은 것만 돌려준다.
  }
  return out;
}

// ── 참조 → 유형 판정 ──────────────────────────────────────────────────────────
const YT_RE = /(?:youtube\.com\/(?:watch\?(?:.*&)?v=|shorts\/|embed\/|live\/)|youtu\.be\/)([A-Za-z0-9_-]{6,})/i;

function youtubeId(u) {
  const m = YT_RE.exec(String(u));
  return m ? m[1] : null;
}

function refType(ref) {
  if (!ref) return 'unknown';
  if (ref.kind === 'file') {
    const mt = String(ref.mimetype || '').toLowerCase();
    const nm = String(ref.name || '').toLowerCase();
    if (mt.startsWith('image/') || /\.(png|jpe?g|gif|webp|heic|heif|bmp|tiff?)$/.test(nm)) return 'image';
    if (mt === 'application/pdf' || mt === 'pdf' || nm.endsWith('.pdf')) return 'pdf';
    if (mt.startsWith('video/') || /\.(mp4|mov|m4v|webm|mkv|avi)$/.test(nm)) return 'video';
    if (mt.startsWith('audio/') || /\.(mp3|m4a|wav|aac|ogg|flac)$/.test(nm)) return 'audio';
    // 텍스트 첨부는 내려받아 그대로 읽는다(외부 전송 없음). 계약의 type 목록에 'text' 가 없어서
    // 'unknown' 으로 표기한다 — 'link' 로 적으면 외부 URL 인 척하는 거짓말이 된다.
    // 목록에 'text' 를 넣는 게 맞지만 규격은 확정본이라 여기서 바꾸지 않고 보고만 한다.
    if (mt.startsWith('text/') || /\.(txt|md|csv|log|json|ya?ml)$/.test(nm)) return 'unknown';
    return 'unknown';
  }
  const u = String(ref.url || '');
  if (youtubeId(u)) return 'youtube';
  if (/loom\.com\/share\/|vimeo\.com\/\d|wistia\.com\/|drive\.google\.com\/file\//i.test(u)) return 'video';
  return 'link';
}

// ── 이미지 축소 (전부 이 맥에서. 나가는 것 없음) ──────────────────────────────
const GEMINI_OK_IMAGE = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/heic', 'image/heif']);

async function shrinkImage(cfg, bytes, mimeIn, tmpDir, tag) {
  const mime = String(mimeIn || '').toLowerCase();
  const needConvert = !GEMINI_OK_IMAGE.has(mime);
  const tooBig = bytes.length > Math.min(cfg.maxInlineBytes, 1.5 * 1024 * 1024);
  if (!needConvert && !tooBig) return { bytes, mimeType: mime, method: 'as-is' };

  const sips = await toolPath('sips');
  if (!sips) {
    if (bytes.length <= cfg.maxInlineBytes && !needConvert) return { bytes, mimeType: mime, method: 'as-is' };
    return { error: 'sips 없음 — 축소/변환 불가' };
  }
  const src = path.join(tmpDir, `${tag}.src`);
  const dst = path.join(tmpDir, `${tag}.jpg`);
  try {
    await fs.writeFile(src, bytes);
    const r = await run(sips, [
      '-s', 'format', 'jpeg',
      '-s', 'formatOptions', String(cfg.jpegQuality),
      '-Z', String(cfg.imageMaxEdge),
      src, '--out', dst,
    ], { timeoutMs: cfg.timeoutMs });
    if (!r.ok) return { error: `sips 실패: ${r.error || r.stderr.split('\n')[0] || 'unknown'}` };
    const outBytes = await fs.readFile(dst);
    if (outBytes.length > cfg.maxInlineBytes) {
      return { error: `축소 후에도 상한 초과 (${humanBytes(outBytes.length)} > ${humanBytes(cfg.maxInlineBytes)})` };
    }
    return { bytes: outBytes, mimeType: 'image/jpeg', method: 'sips' };
  } catch (e) {
    return { error: `이미지 변환 실패: ${String(e && e.message ? e.message : e)}` };
  } finally {
    await fs.rm(src, { force: true }).catch(() => {});
    await fs.rm(dst, { force: true }).catch(() => {});
  }
}

// ── 다운로드 (슬랙 파일) ──────────────────────────────────────────────────────
async function download(cfg, ref, maxBytes) {
  const cacheKey = `dl:${ref.id || ref.url}`;
  const hit = await blobRead(cfg, cacheKey);
  if (hit && hit.bytes && hit.bytes.length) return { bytes: hit.bytes, contentType: hit.contentType, cached: true };

  if (ref.size && ref.size > maxBytes) {
    return { error: `첨부가 상한을 넘음 (${humanBytes(ref.size)} > ${humanBytes(maxBytes)})` };
  }

  const headers = { 'User-Agent': 'condition-mate-media-extract/1' };
  // 토큰은 slack.com 계열에만 붙인다. 다른 호스트로는 절대 나가지 않는다.
  let host = '';
  try { host = new URL(ref.url).hostname.toLowerCase(); } catch { return { error: '잘못된 URL' }; }
  const isSlack = host === 'slack.com' || host.endsWith('.slack.com') || host.endsWith('.slack-edge.com');
  if (isSlack) {
    if (!cfg.slackToken) return { error: 'slackToken 없음 — 슬랙 파일을 받을 수 없다' };
    headers.Authorization = `Bearer ${cfg.slackToken}`;
  }

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), cfg.timeoutMs);
  try {
    const res = await fetch(ref.url, { headers, signal: ctrl.signal, redirect: 'follow' });
    if (!res.ok) return { error: `다운로드 실패 http-${res.status} ${safeUrl(ref.url)}` };
    const ctype = String(res.headers.get('content-type') || '').toLowerCase();
    // 슬랙은 토큰이 나쁘면 200 에 로그인 HTML 을 준다. 조용히 HTML 을 이미지로 취급하지 않는다.
    if (isSlack && ctype.includes('text/html') && refType(ref) !== 'link') {
      return { error: '슬랙이 파일 대신 HTML 을 돌려줌 — 토큰 권한(files:read) 의심' };
    }
    const declared = Number(res.headers.get('content-length') || 0);
    if (declared && declared > maxBytes) {
      return { error: `첨부가 상한을 넘음 (${humanBytes(declared)} > ${humanBytes(maxBytes)})` };
    }
    const chunks = [];
    let total = 0;
    for await (const chunk of res.body) {
      const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += b.length;
      if (total > maxBytes) {
        try { ctrl.abort(); } catch { /* 무시 */ }
        return { error: `첨부가 상한을 넘음 (>${humanBytes(maxBytes)})` };
      }
      chunks.push(b);
    }
    const bytes = Buffer.concat(chunks);
    if (!bytes.length) return { error: '빈 응답' };
    await blobWrite(cfg, cacheKey, bytes, ctype);
    return { bytes, contentType: ctype, cached: false };
  } catch (e) {
    const msg = String(e && e.name === 'AbortError' ? `타임아웃 ${cfg.timeoutMs}ms` : (e && e.message) || e);
    return { error: `다운로드 실패: ${msg} ${safeUrl(ref.url)}` };
  } finally {
    clearTimeout(timer);
  }
}

// ── 2) 경로별 추출기 ──────────────────────────────────────────────────────────
// 각 추출기는 { text, inline, method, error, notes } 를 돌려준다. 예외를 던지지 않는다.

async function fromImage(cfg, ref, bytes, tmpDir) {
  const notes = [];
  const mime = String(ref.mimetype || '').toLowerCase() || 'image/png';
  const shrunk = await shrinkImage(cfg, bytes, mime, tmpDir, `img-${sha1(ref.url).slice(0, 10)}`);
  if (shrunk.error) return { text: '', inline: [], method: 'slack-download', error: shrunk.error, notes };
  if (shrunk.method === 'sips') notes.push(`이미지 ${ref.name}: 긴 변 ${cfg.imageMaxEdge}px JPEG 로 축소 (${humanBytes(bytes.length)} → ${humanBytes(shrunk.bytes.length)})`);
  return {
    text: `[이미지 첨부] ${ref.name} (${mime || '?'}, ${humanBytes(bytes.length)})${SEE_PARTS}`,
    inline: [{ mimeType: shrunk.mimeType, dataB64: shrunk.bytes.toString('base64') }],
    method: shrunk.method === 'sips' ? 'slack-download+sips' : 'slack-download',
    error: null,
    notes,
  };
}

// 텍스트 레이어가 "진짜 본문"인지 판정한다. 스캔본은 보통 0자이거나 머리말·쪽번호 몇 자만 나온다.
// 문턱을 높이 잡으면 짧은 한 장짜리 공지 PDF 가 스캔본으로 오판돼 쓸데없이 이미지로 나간다
// (실제로 66자짜리 샘플이 문턱 80에 걸려 래스터 경로로 샜다). 낮게 잡되 0에 가까운 것만 거른다.
function pdfTextLooksReal(text, pages) {
  const letters = (String(text).match(/[\p{L}\p{N}]/gu) || []).length;
  const per = letters / Math.max(1, pages || 1);
  return letters >= 30 && per >= 10;
}

async function pdfPageCount(cfg, file) {
  const pdfinfo = await toolPath('pdfinfo');
  if (!pdfinfo) return 0;
  const r = await run(pdfinfo, [file], { timeoutMs: cfg.timeoutMs });
  if (!r.ok) return 0;
  const m = /^Pages:\s+(\d+)/m.exec(r.stdout);
  return m ? Number(m[1]) : 0;
}

async function fromPdf(cfg, ref, bytes, tmpDir) {
  const notes = [];
  const base = path.join(tmpDir, `pdf-${sha1(ref.url).slice(0, 10)}`);
  const file = `${base}.pdf`;
  await fs.writeFile(file, bytes);

  const pdftotext = await toolPath('pdftotext');
  const pages = await pdfPageCount(cfg, file);
  let layerLetters = -1;   // 판정 근거를 사람이 볼 수 있게 남긴다

  // (2) 텍스트 레이어 먼저. 여기서 끝나면 PDF 는 이 맥을 떠나지 않는다.
  if (pdftotext) {
    const r = await run(pdftotext, ['-q', '-enc', 'UTF-8', '-l', String(Math.max(1, cfg.maxPdfPages * 8)), file, '-'], { timeoutMs: cfg.timeoutMs });
    if (r.ok) layerLetters = (String(r.stdout).match(/[\p{L}\p{N}]/gu) || []).length;
    if (r.ok && pdfTextLooksReal(r.stdout, pages)) {
      const { text, cut } = clip(r.stdout.replace(/\f/g, '\n\n'), cfg.maxTextChars);
      if (cut) notes.push(`PDF ${ref.name}: 본문 ${cut}자를 잘라냄`);
      if (pages) notes.push(`PDF ${ref.name}: 총 ${pages}쪽, 텍스트 레이어 추출 (외부 전송 없음)`);
      return { text: `[PDF 본문] ${ref.name}\n${text}`, inline: [], method: 'pdftotext', error: null, notes };
    }
  } else {
    notes.push('pdftotext 없음 — 텍스트 레이어 경로가 막혔다');
  }

  // (3) 텍스트 레이어가 비었으면 스캔본이다. tesseract 는 이 맥에 없으므로 래스터 → 비전.
  const pdftoppm = await toolPath('pdftoppm');
  if (!pdftoppm) {
    return { text: '', inline: [], method: 'none', error: 'PDF 에 텍스트 레이어가 없고 pdftoppm 도 없음 — 스캔본 처리 불가', notes };
  }
  const lim = Math.max(1, cfg.maxPdfPages);
  const r2 = await run(pdftoppm, ['-png', '-r', '110', '-f', '1', '-l', String(lim), file, `${base}-p`], { timeoutMs: cfg.timeoutMs * 2 });
  if (!r2.ok) {
    return { text: '', inline: [], method: 'pdftoppm', error: `래스터화 실패: ${r2.error || r2.stderr.split('\n')[0] || 'unknown'}`, notes };
  }
  const files = (await fs.readdir(tmpDir)).filter((f) => f.startsWith(path.basename(`${base}-p`)) && f.endsWith('.png')).sort();
  if (!files.length) {
    return { text: '', inline: [], method: 'pdftoppm', error: '래스터화 결과가 비었다', notes };
  }
  const inline = [];
  for (const f of files.slice(0, Math.min(lim, cfg.maxInlineParts))) {
    const p = path.join(tmpDir, f);
    const raw = await fs.readFile(p).catch(() => null);
    await fs.rm(p, { force: true }).catch(() => {});
    if (!raw) continue;
    const sh = await shrinkImage(cfg, raw, 'image/png', tmpDir, `pg-${f}`);
    if (sh.error) { notes.push(`PDF ${ref.name}: ${f} 축소 실패 — ${sh.error}`); continue; }
    inline.push({ mimeType: sh.mimeType, dataB64: sh.bytes.toString('base64') });
  }
  if (!inline.length) {
    return { text: '', inline: [], method: 'pdftoppm', error: '페이지 이미지를 하나도 만들지 못했다', notes };
  }
  const shown = inline.length;
  if (pages > shown) notes.push(`PDF ${ref.name}: 총 ${pages}쪽 중 앞 ${shown}쪽만 이미지로 변환했다 (${pages - shown}쪽 잘라냄)`);
  else notes.push(`PDF ${ref.name}: ${shown}쪽을 이미지로 변환했다 (텍스트 레이어 ${layerLetters < 0 ? '추출 실패' : `${layerLetters}자`} = 스캔본으로 판정)`);
  return {
    text: `[스캔 PDF] ${ref.name} — 텍스트 레이어가 없어 앞 ${shown}쪽을 이미지로 변환했다.${SEE_PARTS}`,
    inline,
    method: 'pdftoppm+vision',
    error: null,
    notes,
  };
}

async function fromVideoFile(cfg, ref, bytes, tmpDir) {
  const notes = ['영상: 오디오 트랙(음성)은 이번 범위 밖이다. 프레임 이미지만 근거로 쓴다.'];
  const ffprobe = await toolPath('ffprobe');
  const ffmpeg = await toolPath('ffmpeg');
  if (!ffmpeg) return { text: '', inline: [], method: 'none', error: 'ffmpeg 없음 — 프레임 추출 불가', notes };

  const base = path.join(tmpDir, `vid-${sha1(ref.url).slice(0, 10)}`);
  const file = `${base}.bin`;
  await fs.writeFile(file, bytes);

  let dur = 0;
  if (ffprobe) {
    const r = await run(ffprobe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', file], { timeoutMs: cfg.timeoutMs });
    if (r.ok) dur = Number(String(r.stdout).trim()) || 0;
  } else {
    notes.push('ffprobe 없음 — 길이를 몰라 앞부분만 뽑았다');
  }

  const want = Math.max(1, Math.min(cfg.maxVideoFrames, cfg.maxInlineParts));
  const stamps = [];
  if (dur > 0.5) {
    const from = dur * 0.03;
    const to = dur * 0.97;
    const n = Math.max(1, Math.min(want, Math.ceil(dur / 5)));
    for (let i = 0; i < n; i += 1) stamps.push(n === 1 ? from : from + ((to - from) * i) / (n - 1));
  } else {
    for (let i = 0; i < Math.min(3, want); i += 1) stamps.push(i * 5);
  }

  const inline = [];
  for (let i = 0; i < stamps.length; i += 1) {
    const out = `${base}-f${i}.jpg`;
    const r = await run(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-nostdin',
      '-ss', stamps[i].toFixed(2), '-i', file,
      '-frames:v', '1', '-vf', `scale='min(${cfg.imageMaxEdge},iw)':-2`,
      '-q:v', '5', '-f', 'image2', '-y', out,
    ], { timeoutMs: cfg.timeoutMs });
    if (!r.ok) continue;
    const raw = await fs.readFile(out).catch(() => null);
    await fs.rm(out, { force: true }).catch(() => {});
    if (!raw || raw.length > cfg.maxInlineBytes) continue;
    inline.push({ mimeType: 'image/jpeg', dataB64: raw.toString('base64') });
  }
  await fs.rm(file, { force: true }).catch(() => {});

  if (!inline.length) {
    return { text: '', inline: [], method: 'ffmpeg-frames', error: '프레임을 하나도 뽑지 못했다', notes };
  }
  const durTxt = dur ? `${Math.round(dur)}초` : '길이 불명';
  notes.push(`영상 ${ref.name}: ${durTxt}에서 프레임 ${inline.length}장만 뽑았다 (상한 ${want}장)`);
  return {
    text: `[영상 첨부] ${ref.name} (${durTxt}) — 균등 간격 프레임 ${inline.length}장을 근거로 삼았다. 음성은 포함하지 않았다.${SEE_PARTS}`,
    inline,
    method: 'ffmpeg-frames',
    error: null,
    notes,
  };
}

// gsk 는 stderr 로 [INFO] 진행줄을 흘린다. stdout 만 파싱한다.
async function gskJson(cfg, args) {
  const gsk = await toolPath('gsk');
  if (!gsk) return { error: 'gsk 없음' };
  const r = await run(gsk, [...args, '--output', 'json', '--timeout', String(cfg.timeoutMs)], { timeoutMs: cfg.timeoutMs + 5000 });
  if (!r.ok) return { error: `gsk 실패: ${r.timedOut ? `타임아웃 ${cfg.timeoutMs}ms` : (r.error || 'unknown')}` };
  const s = String(r.stdout);
  const i = s.indexOf('{');
  if (i < 0) return { error: 'gsk 응답에 JSON 이 없다' };
  let json;
  try { json = JSON.parse(s.slice(i)); } catch (e) { return { error: `gsk JSON 파싱 실패: ${String(e.message || e)}` }; }
  // status 가 error 인 봉투를 그냥 파고들면 에러 문구를 본문으로 착각한다.
  if (json && json.status === 'error') {
    return { error: `gsk: ${String(json.message || 'unknown').split('\n')[0].slice(0, 160)}` };
  }
  return { json };
}

// gsk 가 status ok 로 "Content not found or crawler failed" 같은 실패 문구를 본문 자리에 담아 준다.
// 이걸 근거로 넘기면 번역기가 실패 문구를 번역한다. 짧은데 실패 문구면 못 뽑은 것으로 친다.
const GSK_FAIL_RE = /(content not found|no content found|crawler failed|failed to (?:fetch|crawl|load)|access denied|403 forbidden|unable to (?:fetch|access))/i;
// Loom은 녹화 직후 실제 제목과 함께 아래 지연 안내만 200/ok로 돌려주기도 한다.
// 이것을 정상 본문으로 캐시하면 자막이 준비된 뒤에도 6시간 동안 다시 읽지 않는다.
// 실패값으로 돌려 데몬의 Loom 재확인 큐가 일정 간격으로 다시 시도하게 한다.
const LOOM_TRANSIENT_RE = /(loom is running a bit slower than usual|check system status|processing (?:your )?(?:video|recording)|video (?:is )?still processing|recording (?:is )?not ready)/i;
function gskUseless(text) {
  const t = String(text || '').trim();
  return !t || LOOM_TRANSIENT_RE.test(t) || (t.length < 240 && GSK_FAIL_RE.test(t));
}

// gsk 응답 모양이 툴마다 조금씩 다르다. 텍스트로 보이는 것을 넓게 긁는다.
function digText(node, acc, depth) {
  if (!node || depth > 6 || acc.length > 400_000) return acc;
  if (typeof node === 'string') { if (node.length > 24) acc.push(node); return acc; }
  if (Array.isArray(node)) { for (const n of node) digText(n, acc, depth + 1); return acc; }
  if (typeof node !== 'object') return acc;
  for (const k of ['transcript', 'text', 'content', 'summary', 'answer', 'markdown', 'body', 'description', 'title']) {
    if (typeof node[k] === 'string' && node[k].length > 24) acc.push(node[k]);
  }
  for (const [k, v] of Object.entries(node)) {
    if (['transcript', 'text', 'content', 'summary', 'answer', 'markdown', 'body', 'description', 'title'].includes(k) && typeof v === 'string') continue;
    digText(v, acc, depth + 1);
  }
  return acc;
}

async function fromYoutube(cfg, ref) {
  const notes = [];
  const vid = youtubeId(ref.url);
  if (!vid) return { text: '', inline: [], method: 'none', error: '유튜브 video id 를 못 찾음', notes };

  const r = await gskJson(cfg, ['yt', 'transcript', '--video_id', vid]);
  if (r.error) {
    // 자막이 없거나 툴이 막히면 요약으로 물러선다. 나가는 것은 여전히 URL 뿐이다.
    const s = await gskJson(cfg, ['summarize', `https://www.youtube.com/watch?v=${vid}`, '--question', '이 영상의 핵심 내용을 요약하라']);
    if (s.error) return { text: '', inline: [], method: 'gsk-youtube', error: `${r.error} / 폴백도 실패: ${s.error}`, notes };
    const raw = digText(s.json, [], 0).join('\n');
    if (gskUseless(raw)) return { text: '', inline: [], method: 'gsk-summarize', error: '자막·요약 모두 내용을 못 가져왔다', notes };
    const { text, cut } = clip(raw, cfg.maxTextChars);
    if (!text) return { text: '', inline: [], method: 'gsk-summarize', error: '자막·요약 모두 비었다', notes };
    if (cut) notes.push(`유튜브 ${vid}: 요약 ${cut}자 잘라냄`);
    notes.push(`유튜브 ${vid}: 자막을 못 받아 요약으로 대체 (genspark.ai 로 video id 만 나감)`);
    return { text: `[유튜브 요약] youtube:${vid}\n${text}`, inline: [], method: 'gsk-summarize', error: null, notes };
  }
  const rawTr = digText(r.json, [], 0).join('\n');
  if (gskUseless(rawTr)) return { text: '', inline: [], method: 'gsk-youtube-transcript', error: '자막을 못 가져왔다', notes };
  const { text, cut } = clip(rawTr, cfg.maxTextChars);
  if (!text) return { text: '', inline: [], method: 'gsk-youtube-transcript', error: '자막이 비었다', notes };
  if (cut) notes.push(`유튜브 ${vid}: 자막 ${cut}자 잘라냄`);
  notes.push(`유튜브 ${vid}: 자막 확보 (genspark.ai 로 video id 만 나감, 첨부·본문은 안 나감)`);
  return { text: `[유튜브 자막] youtube:${vid}\n${text}`, inline: [], method: 'gsk-youtube-transcript', error: null, notes };
}

// 알려진 한계: 로그인 벽이 있는 페이지(링크드인 피드 등)는 크롤러가 로그인 화면 텍스트를
// 정상 본문으로 받아 온다. 실패 문구가 아니라 진짜 페이지 글자라서 자동으로는 못 거른다.
// 근거로는 쓸모없지만 해롭지도 않고, 걸러내려면 도메인 목록을 손으로 관리해야 해서 두었다.
async function fromLink(cfg, ref, typeHint) {
  const notes = [];
  if (!isPublicHttpUrl(ref.url)) {
    // 사내·사설 주소는 외부 크롤러에 URL 조차 넘기지 않는다. 이것도 유효한 결과다.
    return {
      text: '', inline: [], method: 'skipped-private-host',
      error: '사설/내부 호스트 — 외부 크롤러로 보내지 않았다',
      notes: [`링크 ${safeUrl(ref.url)}: 내부 주소로 판단해 외부 전송을 생략했다`],
    };
  }
  const r = await gskJson(cfg, ['crawl', ref.url]);
  let joined = r.error ? '' : digText(r.json, [], 0).join('\n');
  let loomPending = /loom\.com\/share\//i.test(ref.url) && LOOM_TRANSIENT_RE.test(joined);
  if (gskUseless(joined)) joined = '';
  let method = 'gsk-crawl';
  if (!joined) {
    const s = await gskJson(cfg, ['summarize', ref.url, '--question', '이 페이지의 핵심 내용을 요약하라']);
    if (s.error) {
      return { text: '', inline: [], method, error: `${r.error || '크롤 결과가 비었다'} / 폴백도 실패: ${s.error}`, notes };
    }
    joined = digText(s.json, [], 0).join('\n');
    loomPending ||= /loom\.com\/share\//i.test(ref.url) && LOOM_TRANSIENT_RE.test(joined);
    method = 'gsk-summarize';
  }
  if (gskUseless(joined)) {
    return { text: '', inline: [], method,
      error: loomPending ? 'Loom 영상 처리 중 — 잠시 후 다시 확인 필요' : '크롤·요약 모두 내용을 못 가져왔다 (로그인·봇차단 페이지로 보임)', notes };
  }
  const { text, cut } = clip(joined, cfg.maxTextChars);
  if (!text) return { text: '', inline: [], method, error: '페이지에서 텍스트를 못 뽑았다', notes };
  if (cut) notes.push(`링크 ${safeUrl(ref.url)}: 본문 ${cut}자 잘라냄`);
  notes.push(`링크 ${safeUrl(ref.url)}: URL 을 genspark.ai 에 넘겨 본문을 받았다`);
  const label = typeHint === 'video' ? '영상 페이지' : '링크 본문';
  return { text: `[${label}] ${safeUrl(ref.url)}\n${text}`, inline: [], method, error: null, notes };
}

// ── mode 'text' 전용: inline 파트를 한국어 서술로 바꿔 준다 ────────────────────
// 이 함수만이 이 모듈에서 유일하게 Gemini 로 바이트를 내보낸다.
async function describeWithGemini(cfg, ev) {
  if (!cfg.geminiKey || !ev.inline.length) return null;
  const model = cfg.geminiModel || 'gemini-2.0-flash';
  const url = `${cfg.geminiEndpoint}/models/${encodeURIComponent(model)}:generateContent`;
  const parts = [
    { text: '다음 이미지들은 슬랙에 올라온 첨부다. 무엇이 담겨 있는지 한국어로 사실만 서술하라. 읽히는 글자는 그대로 옮겨 적어라. 추측이나 평가는 하지 마라.' },
    ...ev.inline.map((p) => ({ inline_data: { mime_type: p.mimeType, data: p.dataB64 } })),
  ];
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), cfg.timeoutMs * 2);
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': cfg.geminiKey },
      body: JSON.stringify({ contents: [{ parts }] }),
      signal: ctrl.signal,
    });
    if (!res.ok) return { error: `gemini http-${res.status}` };   // 본문은 키를 되비칠 수 있어 싣지 않는다
    const j = await res.json();
    const out = (j?.candidates?.[0]?.content?.parts || []).map((p) => p.text || '').join('').trim();
    return out ? { text: out } : { error: 'gemini 응답이 비었다' };
  } catch (e) {
    return { error: `gemini 호출 실패: ${String(e && e.name === 'AbortError' ? '타임아웃' : (e && e.message) || e)}` };
  } finally {
    clearTimeout(timer);
  }
}

// ── 3) extractEvidence ────────────────────────────────────────────────────────
function normalizeOpts(opts) {
  const o = opts && typeof opts === 'object' ? opts : {};
  const num = (v, d) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Number(v) : d);
  return {
    slackToken: typeof o.slackToken === 'string' ? o.slackToken : '',
    geminiKey: typeof o.geminiKey === 'string' ? o.geminiKey : '',
    geminiModel: typeof o.geminiModel === 'string' && o.geminiModel ? o.geminiModel : 'gemini-2.0-flash',
    geminiEndpoint: typeof o.geminiEndpoint === 'string' && o.geminiEndpoint ? o.geminiEndpoint : DEFAULTS.geminiEndpoint,
    cacheDir: typeof o.cacheDir === 'string' && o.cacheDir ? o.cacheDir : '',
    mode: o.mode === 'text' ? 'text' : DEFAULTS.mode,
    timeoutMs: num(o.timeoutMs, DEFAULTS.timeoutMs),
    totalBudgetMs: num(o.totalBudgetMs, DEFAULTS.totalBudgetMs),
    maxDownloadBytes: num(o.maxDownloadBytes, DEFAULTS.maxDownloadBytes),
    maxVideoBytes: num(o.maxVideoBytes, DEFAULTS.maxVideoBytes),
    maxInlineBytes: num(o.maxInlineBytes, DEFAULTS.maxInlineBytes),
    maxInlineTotalBytes: num(o.maxInlineTotalBytes, DEFAULTS.maxInlineTotalBytes),
    maxInlineParts: num(o.maxInlineParts, DEFAULTS.maxInlineParts),
    maxPdfPages: num(o.maxPdfPages, DEFAULTS.maxPdfPages),
    maxVideoFrames: num(o.maxVideoFrames, DEFAULTS.maxVideoFrames),
    maxTextChars: num(o.maxTextChars, DEFAULTS.maxTextChars),
    imageMaxEdge: num(o.imageMaxEdge, DEFAULTS.imageMaxEdge),
    jpegQuality: num(o.jpegQuality, DEFAULTS.jpegQuality),
    linkCacheTtlMs: num(o.linkCacheTtlMs, DEFAULTS.linkCacheTtlMs),
  };
}

const mkEv = (ref, type, r) => ({
  ref,
  type,
  text: String(r.text || ''),
  inline: Array.isArray(r.inline) ? r.inline : [],
  method: String(r.method || 'none'),
  error: r.error ? String(r.error) : null,
});

async function extractOne(cfg, ref, tmpDir) {
  const type = refType(ref);
  const notes = [];

  // 캐시 변수에 들어가는 파라미터가 바뀌면 다른 결과이므로 키에 섞는다.
  const variant = `${cfg.mode}|${cfg.imageMaxEdge}|${cfg.maxPdfPages}|${cfg.maxVideoFrames}|${cfg.maxTextChars}`;

  // 외부 크롤러로 가는 경로는 '링크' 참조에 한한다. 파일 첨부는 아래에서 내려받아 이 맥에서 처리한다.
  if (ref.kind === 'link' && (type === 'youtube' || type === 'link' || type === 'video')) {
    const key = `ev:${type}:${variant}:${ref.url}`;
    const cached = await cacheRead(cfg, 'ev', key, cfg.linkCacheTtlMs);
    if (cached) return { ev: mkEv(ref, type, cached), notes: cached.notes || [] };
    const r = type === 'youtube' ? await fromYoutube(cfg, ref) : await fromLink(cfg, ref, type);
    if (!r.error) await cacheWrite(cfg, 'ev', key, r);
    return { ev: mkEv(ref, type, r), notes: r.notes || [] };
  }

  if (type === 'audio') {
    return {
      ev: mkEv(ref, 'audio', { text: `[음성 첨부] ${ref.name} (${humanBytes(ref.size)})`, inline: [], method: 'metadata-only', error: '음성 전사는 이번 범위 밖이다' }),
      notes: [`음성 ${ref.name}: 전사 경로를 만들지 않았다 (범위 밖)`],
    };
  }

  if (ref.kind !== 'file') {
    return { ev: mkEv(ref, 'unknown', { text: '', inline: [], method: 'none', error: '처리 경로가 없는 참조' }), notes };
  }

  const maxBytes = type === 'video' ? cfg.maxVideoBytes : cfg.maxDownloadBytes;
  const dl = await download(cfg, ref, maxBytes);
  if (dl.error) {
    return { ev: mkEv(ref, type, { text: '', inline: [], method: 'slack-download', error: dl.error }), notes };
  }

  const key = `ev:${type}:${variant}:${sha256(dl.bytes)}`;
  const cached = await cacheRead(cfg, 'ev', key, 0);
  if (cached) return { ev: mkEv(ref, type, cached), notes: cached.notes || [] };

  let r;
  if (type === 'image') r = await fromImage(cfg, ref, dl.bytes, tmpDir);
  else if (type === 'pdf') r = await fromPdf(cfg, ref, dl.bytes, tmpDir);
  else if (type === 'video') r = await fromVideoFile(cfg, ref, dl.bytes, tmpDir);
  else {
    // 텍스트로 보이는 첨부는 그대로 읽는다. 아무 것도 나가지 않는다.
    const looksText = /^text\//.test(String(dl.contentType)) || /^text\//.test(String(ref.mimetype));
    if (looksText) {
      const { text, cut } = clip(dl.bytes.toString('utf8'), cfg.maxTextChars);
      r = { text: `[텍스트 첨부] ${ref.name}\n${text}`, inline: [], method: 'inline-utf8', error: null, notes: cut ? [`${ref.name}: ${cut}자 잘라냄`] : [] };
    } else {
      r = { text: '', inline: [], method: 'none', error: `처리 경로가 없는 형식 (${ref.mimetype || '?'})`, notes: [] };
    }
  }

  if (cfg.mode === 'text' && !r.error && r.inline.length) {
    const d = await describeWithGemini(cfg, r);
    if (d && d.text) {
      // 파트를 비우므로 "파트를 보라" 는 안내는 걷어낸다.
      r.text = `${r.text.split(SEE_PARTS).join('')}\n${d.text}`;
      r.inline = [];
      r.method = `${r.method}+gemini-describe`;
      (r.notes = r.notes || []).push(`${ref.name}: 이미지 파트를 Gemini 로 서술 변환 (바이트가 generativelanguage.googleapis.com 으로 나갔다)`);
    } else if (d && d.error) {
      (r.notes = r.notes || []).push(`${ref.name}: 서술 변환 실패(${d.error}) — 이미지 파트를 그대로 둔다`);
    }
  }

  if (!r.error) await cacheWrite(cfg, 'ev', key, r);
  return { ev: mkEv(ref, type, r), notes: r.notes || [] };
}

/**
 * 참조 배열을 근거로 바꾼다. 절대 예외를 던지지 않는다 — 실패는 evidence 원소의 error 로만 나온다.
 * @param {Array} refs collectRefs 가 돌려준 것
 * @param {Object} opts 위 계약 주석 참조
 * @returns {Promise<{evidence: Array, notes: string[]}>}
 */
export async function extractEvidence(refs, opts) {
  const out = EMPTY();
  if (!Array.isArray(refs) || !refs.length) return out;

  let cfg;
  try { cfg = normalizeOpts(opts); } catch { return out; }

  let tmpDir = '';
  const deadline = Date.now() + cfg.totalBudgetMs;
  let inlineTotal = 0;

  try {
    const root = cfg.cacheDir ? path.join(cfg.cacheDir, 'tmp') : path.join(os.tmpdir(), 'cm-media-extract');
    await fs.mkdir(root, { recursive: true });
    tmpDir = await fs.mkdtemp(path.join(root, 'x-'));
  } catch (e) {
    out.notes.push(`임시 폴더를 못 만들었다: ${String(e && e.message ? e.message : e)}`);
  }

  for (const ref of refs) {
    if (!ref || typeof ref !== 'object') continue;
    if (Date.now() > deadline) {
      out.evidence.push(mkEv(ref, refType(ref), { text: '', inline: [], method: 'none', error: `전체 예산 ${cfg.totalBudgetMs}ms 초과로 건너뜀` }));
      continue;
    }
    let res;
    try {
      res = await extractOne(cfg, ref, tmpDir || os.tmpdir());
    } catch (e) {
      // 여기까지 온 예외는 버그다. 그래도 밖으로 던지지 않는다.
      res = { ev: mkEv(ref, refType(ref), { text: '', inline: [], method: 'none', error: `내부 오류: ${String(e && e.message ? e.message : e)}` }), notes: [] };
    }

    // inline 총량 상한. 넘치는 파트는 잘라내고 그 사실을 남긴다.
    const ev = res.ev;
    if (ev.inline.length) {
      const kept = [];
      for (const p of ev.inline) {
        const sz = Math.ceil((p.dataB64 || '').length * 0.75);
        if (inlineTotal + sz > cfg.maxInlineTotalBytes) break;
        inlineTotal += sz;
        kept.push(p);
      }
      if (kept.length !== ev.inline.length) {
        out.notes.push(`${ev.ref.name || safeUrl(ev.ref.url)}: inline 총량 상한(${humanBytes(cfg.maxInlineTotalBytes)}) 때문에 파트 ${ev.inline.length - kept.length}개를 잘라냈다`);
      }
      ev.inline = kept;
    }

    out.evidence.push(ev);
    for (const n of res.notes || []) if (n) out.notes.push(String(n));
  }

  if (tmpDir) await fs.rm(tmpDir, { recursive: true, force: true }).catch(() => {});
  return out;
}

export default { collectRefs, extractEvidence, probeTools };
