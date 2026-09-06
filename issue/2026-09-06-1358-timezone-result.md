# 시간 표시가 사용자 시간대를 따르게 한다 — 결과

카드 `2026-09-06-1358-condition-mate-timezone` · `FAST` · `L1`/`P2`/`C2` · 2026-09-06 22:45 IST

원인은 하드코딩이 아니라 **변환을 안 한 것**이었다. 저장된 ISO 문자열을
`.replace('T',' ').slice(0,16)` 으로 잘라 그대로 찍었다. 자르기는 변환이 아니다.

앞선 세션(`term_03b91170`, exited)이 소스 수정을 끝내고 `cf22aea` 로 커밋해 뒀다. 이 세션은
남아 있던 셋 — 커밋 안 된 하네스, 한 번도 안 돈 라이브 e2e, **도는 앱 반영 여부 미판정** — 을
이어서 끝냈다. 같은 조사를 반복하지 않았다.

## 변경 파일

**소스 (`cf22aea`, 앞선 세션 · 이 세션은 안 건드림)**
- `CMTimeFilter.swift` — `isoDisp(v,len,sep)` 신설. 변환 규칙 한 벌.
- `IssuesContent.swift`(5) · `LoopEngineeringContent.swift`(6) · `BGMPlayerContent.swift`(1) —
  자르기 12 자리 → `tdisp`/`isoDisp`.
- `WorkQueueVersionLedger.swift:83` · `IssueArchiveStore.swift:99` ·
  `WorkQueueLiveStore.swift:138` — 저장 포매터에 `TimeZone(identifier: "UTC")`. 포맷의 `Z` 는
  그대로 둬서 옛 오프셋 값이 계속 정확히 읽힌다.

**이 세션 커밋 (`98864aa`)**
- `Scripts/e2e-timezone-display.sh` (새 파일) · `.e2e/timezone.test.js` ·
  `.e2e/run.js`(게이트 등재) · `.e2e/issues.test.js` · `.e2e/screens.test.js` ·
  `docs/specs/SPEC.md`(EP-21 헌크만) · `issue/2026-09-06-1358-timezone-live-render.js`.

`SPEC.md` 와 `BGMPlayerContent.swift` 에 있는 **다른 작업자의 BGM 변경은 손대지 않았다.**
`SPEC.md` 는 EP-21 헌크 하나만 골라 담았고 그쪽 두 헌크는 워킹트리에 그대로 있다.

## 검증

| 명령 | 결과 |
|---|---|
| `node .e2e/timezone.test.js` | 32 passed / 0 failed |
| `bash Scripts/e2e-timezone-display.sh` | PASS=10 FAIL=0 |
| `bash Scripts/e2e-timezone-boundary.sh` | PASS=8 FAIL=0 |
| `cd .e2e && node run.js` | 55 파일 · 1714 단정 통과 / 0 실패 |
| `swift build` | exit 0, 새 경고 없음 |
| `node issue/2026-09-06-1358-timezone-live-render.js` | 16 passed / 0 failed (도는 앱 대상) |

문제 사례 `2026-09-06T07:31:12Z` (세션 `97cc3cc2`) → 한국 `16:31` · 인도 `13:01`(30분 오프셋) ·
UTC `07:31`. 날짜 경계 `2026-09-06T19:00:00Z` → 한국 `2026-09-07 04:00` · 인도 `2026-09-07 00:30`.
설정 5 회 전환이 매번 다시 계산된다.

## 현재 실행 중인 앱 반영 — 반영됐다

도는 것은 `/Applications/ConditionMate.app/…/ConditionMate` pid **5544**, 포트 **57797**.

1. `strings -a` — `function isoDisp(v, len, sep)` 1 · `esc(tdisp(S.startedAt,16))` 1 ·
   옛 자르기 `esc(String(S.startedAt||'').replace` **0** · `Asia/Kolkata` 4.
2. 그 인스턴스에 설정 6 회 POST — `Asia/Seoul`/`Asia/Kolkata`/`UTC` 마다 `/issues` 가
   `window.CM_TZ='<그 id>'` 를 내보냈다. **라이언의 원래 설정 `system` 으로 되돌려 놓았다.**
3. 그 앱이 오늘 쓴 값이 UTC 다 — 카드 `2026-09-06-2225-script-first-routing-loop` 의
   `versionFirstSeen = 2026-09-06T17:01:18+0000`. 맥 로컬은 `Asia/Kolkata` 인데 `+0000` 이다.
4. 그 앱이 서빙한 360,592 바이트에서 진짜 JS 를 뽑아 그 진짜 값을 찍었다 — 한국
   `2026-09-07 02:01`(날짜 넘음) · 인도 `2026-09-06 22:31` · UTC `2026-09-06 17:01`.
   옛 `+0530` 저장분도 세 설정 모두에서 같은 순간으로 읽힌다.

재시작·재설치는 필요 없었고 하지 않았다. 도는 바이너리가 이미 고쳐진 것이다.

## 기존 데이터

**한 개도 안 고쳤다.** 마이그레이션도 일괄 수정도 없다. 포맷의 `Z` 가 적힌 오프셋을 존중하므로
옛 `+0530`/`+0900` 값이 그대로 맞게 읽힌다. 오프셋 없는 값은 적힌 그대로 둔다 — 없는 정보를
UTC 라고 지어내면 옛 기록이 조용히 다른 시각으로 바뀐다.

## 미완료

없다. 막힌 것도 없다.

## 발견 (실행하지 않음)

- 다른 작업자의 BGM 자동재생 수정이 커밋 안 된 채 워킹트리에만 있다. `git checkout` 한 번이면
  되돌아간다.
- `.e2e/slackdecision.test.js` 가 어떤 스크립트에도 게이트에도 없다 (기존 상태).

## 1초 요약

요구 — 신규 시각은 UTC 저장, 화면은 설정 시간대로 변환, 설정 변경 반영.
문제 — 변환을 안 하고 저장 문자열을 잘라 찍었다. 자르기는 변환이 아니다.
완성 — 표시 12 자리가 `isoDisp` 를 거치고 신규 저장이 UTC 이며, 도는 앱에서 한국·인도·UTC 가
갈리는 것을 서빙된 바이트로 확인했다. 기존 데이터는 안 건드렸다.
