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

## 1단계: 쿠키 추출 (필수)

1. 브라우저에서 Suno에 로그인
2. DevTools(F12) > Network 탭 열기
3. 곡 생성 등 아무 동작을 해서 `studio-api` 또는 `clerk.suno.com` 요청을 하나 찾기
4. 그 요청의 **Request Headers > Cookie** 값 전체를 복사
5. `.env`의 `SUNO_COOKIE`에 붙여넣기

쿠키는 만료됩니다(보통 며칠~몇 주). 401이 나기 시작하면 다시 추출해 교체하세요.

## 2단계: 엔드포인트 검증 (중요)

`.env`의 `CLERK_BASE_URL`, `SUNO_BASE_URL`, `CLERK_JS_VERSION`, `SUNO_MODEL` 기본값은
커뮤니티 리버스 엔지니어링 기준의 추정치입니다. **Suno가 수시로 바꾸므로**, Network 탭에서
실제 값을 확인해 맞춰주세요:

- 생성 요청 URL → `SUNO_BASE_URL` + 경로 (코드의 `/api/generate/v2/` 확인)
- 토큰 발급 요청(`clerk...`) → `CLERK_BASE_URL`, `_clerk_js_version` 쿼리값
- 생성 payload의 `mv` 필드값 → `SUNO_MODEL`

응답 JSON 구조가 다르면 `src/auth.ts`(세션 id 위치), `src/suno.ts`(clips 위치)의
필드 접근부를 그에 맞게 수정하면 됩니다.

## 3단계: Claude Code에 등록

```
claude mcp add suno -- node /Users/lioncho/Work/departtment_service/projects/condition-manager/suno-mcp/dist/index.js
```

`.env`는 자동 로드되지 않습니다. 환경변수를 함께 넘기거나, 등록 시 `--env` 옵션 또는
래퍼 스크립트로 `SUNO_COOKIE` 등을 주입하세요. 예:

```
claude mcp add suno --env SUNO_COOKIE="..." --env SUNO_BASE_URL="..." -- node .../dist/index.js
```

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
