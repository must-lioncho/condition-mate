# suno-mcp

개인용 MCP 서버. Suno의 내부 웹 API를 래핑해 음원 생성을 자동화합니다. 공식 API가 없으므로, 로그인된 브라우저 세션의 **쿠키**로 인증합니다. 본인 계정 한정 사용 전제입니다.

## 제공 툴

- `generate_song` — 생성 시작 (description 모드 또는 lyrics/style/title 커스텀 모드). pending clip id 반환
- `get_status` — clip id로 진행 상태 폴링 (`complete` 되면 완료)
- `get_audio` — 완성된 곡 mp3를 `DOWNLOAD_DIR`로 다운로드
- `list_library` — 최근 곡 목록
- `get_credits` — 남은 크레딧

## 설치

```
cd suno-mcp
npm install
npm run build
cp .env.example .env   # 값 채우기
```

## 인증 구조

studio-api 요청은 **쿠키가 아니라 헤더 3종**으로 인증합니다 (DevTools 캡처로 확인됨):

- `authorization: Bearer <JWT>` — Clerk 액세스 토큰. 약 1시간 만료
- `browser-token: {"token":"<b64>"}` — 안은 `{"timestamp":<ms>}`. 서명 없어 **코드가 매번 생성** (`auth.ts`)
- `device-id: <uuid>` — 고정 기기 id

## 1단계: 값 추출 (DevTools cURL)

1. Suno 로그인 → DevTools(F12) > Network
2. 곡 생성을 한 번 실행 → `generate/v2-web` 요청(Type: fetch)을 우클릭 → **Copy as cURL**
3. cURL에서 다음을 `.env`에 옮김:
   - `-H 'authorization: Bearer XXX'` 의 `XXX` → `SUNO_AUTH_TOKEN`
   - `-H 'device-id: XXX'` → `SUNO_DEVICE_ID`
   - payload의 `metadata.user_tier` → `SUNO_USER_TIER` (선택)

`SUNO_AUTH_TOKEN`은 약 1시간 만료됩니다. 호출이 401을 내면 cURL을 다시 떠서 토큰만 교체하세요.

### 무인 자동화 (선택): 토큰 자동 갱신

매시간 재붙여넣기가 싫으면 `SUNO_AUTH_TOKEN`을 비우고 `SUNO_COOKIE`에 `clerk.suno.com`
쿠키를 넣으세요. 서버가 호출 직전 Clerk에서 Bearer를 자동 발급합니다 (`auth.ts`의 옵션 B).

## 검증된 엔드포인트

- 생성: `POST {SUNO_BASE_URL}/api/generate/v2-web/`
- 상태/목록: `GET /api/feed/v2?ids=...`
- 크레딧: `GET /api/billing/info/`
- `SUNO_BASE_URL` = `https://studio-api-prod.suno.com`, `SUNO_MODEL` = `chirp-fenix`

Suno가 경로/모델을 바꾸면 위 값과 `src/suno.ts`를 그에 맞게 수정하세요.

## 3단계: Claude Code에 등록

```
claude mcp add --scope user suno -- node /Users/lioncho/Work/departtment_service/projects/condition-mate/Sources/ConditionMate/Plugins/suno-mcp/dist/index.js
```

서버는 시작 시 같은 폴더의 `.env`를 자동으로 읽습니다(`src/env.ts`). 따라서 `.env`만
채워두면 별도 `--env` 주입 없이 동작합니다. (다른 환경에서 강제로 주입하고 싶으면
`--env SUNO_COOKIE="..."` 식으로 넘겨도 되고, 그 값이 우선합니다.)

등록 후 `/mcp`로 연결 상태를 확인할 수 있습니다.

## 개발

```
npm run dev        # tsx watch 로 즉시 실행
npm run typecheck
```

## 동작 흐름

```
generate_song  →  clip id 반환 (status: submitted/queued)
      │
get_status(ids) 폴링  →  status: streaming → complete
      │
get_audio(id)  →  audio_url 다운로드 → DOWNLOAD_DIR/<id>.mp3
```

## 주의

- 비공식 내부 API 사용입니다. Suno 약관/레이트리밋을 본인 책임 하에 준수하세요.
- 쿠키는 비밀값입니다. `.env`는 `.gitignore`에 포함돼 있습니다. 커밋하지 마세요.
