# 전략4 · 상태 인지형 BGM (Closed-Loop Observatory) — Spec

Status: PROPOSED (Phase 1 ready to implement)
Author: manager-pm
Date: 2026-07-10 (KST)
Supersedes-relationship: 전략3 · 플랜 맵 → 전략4 · 상태 인지형 (확장, 대체 아님 — 플랜 맵은 가설로 유지)

---

## 1. Goal

전략3(플랜 맵)은 "요일×시간대"라는 **가설**을 잘 세웠지만, 그 가설이 실제로 맞았는지
**검증하는 피드백 루프가 없다.** 전략4는 플랜 맵을 그대로 실행 기반으로 유지하면서,
관측 데이터(컨디션맵 업무시작·세션 진행/유휴·심야 활동 + `actions.jsonl`의 싫어요·뮤트·완주)를
**슬롯별 hit/miss 점수**로 환산해 "어떤 슬롯이 맞고, 어떤 슬롯이 재계획 후보인지"를 드러내는
폐루프(closed loop)를 만든다.

핵심 원칙(Phase 1): **관측·채점·표시만 한다. 선곡 로직·플랜 파일을 자동으로 바꾸지 않는다.**
데이터는 이미 `actions.jsonl`에 전부 있으므로, Phase 1은 그것을 점수로 환산해 대시보드에
보여주는 것이 전부다 — 회귀 위험이 사실상 0인 증분.

---

## 2. Evidence — 첫 슬롯 적중(hit) 기록

2026-07-10 00:00~00:03 (금, 새벽), 플랜 슬롯이 자동 전환되며 첫 긍정 신호를 남겼다.

- `t=1783609393` `trackChange` pool=`플랜 · 금 심야 · 애프터 라운지` track=`Velvet After Dark`
  (직전 슬롯은 `플랜 · 목 심야 · 달빛 정원`; 00:00 목→금 요일 경계에서 슬롯 flip).
  themes: `lounge`+`snow`, note "불금 애프터 — 클럽의 여운을 새벽 라운지로 잔잔하게"
  (`BGMPlanMap.swift:258`).
- 이어 `Velvet Pulse (2)`, `Velvet Pulse (3)`, `Midnight Velvet` 등 라운지 풀에서 연속 선곡.
- `t=1783610843` `sessionStop` detail=`세션 중지 · 1500초 경과` — 포모도로 25분 **완주**,
  그 사이 `dislike`/`mute` 이벤트 **없음**.
- 사용자 보고: "딱 적절한 타이밍." → 이 세션은 `금 심야 · 애프터 라운지` 슬롯의 **첫 hit**.

이 케이스는 전략4 채점기가 반드시 hit으로 집계해야 하는 **골든 샘플**이다(회귀 테스트 기준).

주의(오탐 방지): 같은 00:00 flip에서 `trackChange`가 `강제 전환 (슬롯/프로필 변경·싫어요·유휴
전환)` detail로 찍혔다(`ConditionDirector.swift:719-720`). 이 "강제 전환"은 슬롯 경계·프로필
변경·싫어요·유휴가 **전부 뭉뚱그려진** 신호라서, **강제 전환 자체를 miss로 세면 안 된다** —
여기서는 오히려 hit을 만든 좋은 flip이다. miss는 **명시적 `dislike` 액션 + 세션 중 `mute`** 로만
집계한다(§5.3).

---

## 3. 검증된 코드 사실 (구현 근거)

- **전략 카탈로그는 데이터 추가로 확장** — `TrackPlayStats.swift:20-23` 헤더가 명시:
  "adding a future 전략4 is a data append: a new BGMStrategy entry + bumping activeStrategy."
  카탈로그(`seedStrategies`, `migrateCatalog()`)에 행을 추가하고 `activeStrategy`를 가리키면,
  대시보드 전략 히스토리 섹션과 필터 버튼이 `/api/bgm/stats` 응답의 `strategies`로 **자동 렌더**
  (`AppDelegate.swift:6214-6221`, `BGMPlayerContent.swift:399-402,1175-1177`).
- **슬롯 식별자는 이미 로그에 있다** — `trackChange` 이벤트의 `pool` 필드가
  `"플랜 · <slot.label>"` 형식(`ActionLog.swift:28`, `ConditionDirector` logTrack).
  즉 `actions.jsonl` ↔ `BGMPlanMap.Slot.label` 조인 키가 **이미 존재** → Phase 1은 새 계측 불필요.
- **세션 경계** — `sessionStart`(`AppDelegate.swift:1188`) / `sessionStop`(1197, detail
  `세션 중지 · N초 경과`, `sessionSeconds`가 경과초). 모드는 `mode` 필드(pomodoro|sprint|unlimited).
- **부정 신호** — `dislike`(`AppDelegate.swift:1414`, detail "이 곡 싫어요 …"),
  `mute`/`unmute`(1277,1304). **긍정 신호** — 부정 신호 없이 완주한 `sessionStop`.
- **컨디션맵 업무시작 = 8시간 갭** (`BGMPlayerContent.swift:279` "8시간 이상 활동이 없으면 퇴근").
  주의: 배경 자료의 "6h gap"은 실제로는 **TimeStore reconcile 윈도우**(`AppDelegate.swift:251`,
  `21600s`)로 다른 상수다. 전략4 상태 감지는 **컨디션맵과 동일한 8h 업무시작 기준**을 써야 한다.
- **라이브 세션 상태** — `ChallengeSession.stateJSON` = `{working,muted}`,
  GET `/api/session/state` (`ChallengeSession.swift:51-53`).
- **GET 화이트리스트** — `DashboardServer.swift:235-247`의 `path.hasPrefix(...)` OR 체인에
  새 GET 엔드포인트를 반드시 등록해야 서빙된다. 라우팅 핸들러는 `AppDelegate.swift:33~` 블록.
- **시간 표시 규약** — 새 시간 표시는 UTC epoch 저장 + 표시 변환만, `CMTimeFilter.parts` 계열 사용
  (raw `Date` getter 금지), `cm.timeZone` 설정 반영.
- **reviewJSON/lastView 불필요** — 슬롯 성적표는 `/api/bgm/stats`처럼 **자체 GET 엔드포인트**로
  로드하며 `/data.json`(reviewJSON) 필드가 아니다 → reviewJSON 수기 직렬화·lastView 허용목록
  수정 불필요(전략 히스토리와 동일 패턴).

---

## 4. Options & Tradeoffs

### 축 A — 자동화 수위 (핵심 결정)

- **A1. 관측 전용(Observatory)** — 슬롯별 hit/miss를 채점·표시만. 선곡·플랜 무변경.
  - 효과: 회귀 위험 0(선곡 경로 미접촉), 데이터 이미 존재, 즉시 구축 가능, 재계획 판단 근거 축적.
  - 한계: 자동 교정은 없음(사람/관리자 AI가 점수를 보고 수동 재계획).
- **A2. 자동 슬롯 강등(auto-demotion)** — miss 임계 초과 슬롯을 심야 유휴 시 마무리 풀로 자동 강등.
  - 효과: 즉각적 체감 개선 가능.
  - 위험: 선곡 경로·플랜 파일에 자동 mutation → 회귀·"왜 갑자기 바뀌었나" 혼란, 되돌리기 어려움.
    강제 전환 신호 오탐(§2)까지 얽히면 잘못된 강등 위험.
- **A3. 재계획 제안(suggestion)** — 후보 슬롯을 관리자 AI에게 `POST /api/bgm/plan` diff 제안으로
  올리되 자동 적용 없음(human/AI-in-the-loop).
  - 효과: 자동화 이득 + 안전. 단, 제안 파이프라인 추가 구현 필요.

**결정: A1을 Phase 1로 채택.** 근거: (1) 사용자 지시 = "신호 수집·채점·표시만 하는 증분 우선",
(2) 데이터가 이미 존재해 계측 추가 불필요, (3) 선곡/플랜 경로 미접촉이라 회귀 표면 0,
(4) A2/A3는 A1이 만든 점수 없이는 신뢰할 근거가 없다 — 관측이 선행되어야 한다.
A2는 채택하지 않음(자동 mutation 위험), A3는 Phase 3로 미룸.

### 축 B — 점수 저장 방식

- **B1. 읽을 때 파생(derive-on-read)** — `actions.jsonl`을 재생해 매 요청 시 점수 계산. 저장 안 함.
  - 효과: 새 파일·마이그레이션·safe-write 경로 불필요, 상태 불일치 없음, 최소 표면. **채택.**
  - 한계: 로그 윈도우(최근 ~1MB, `ActionLog.recentJSON`)를 넘는 과거는 못 봄 → Phase 1엔 충분.
- **B2. 캐시 파일 지속(`bgm-slot-scores.json`)** — 추세·장기 이력용. Phase 1.5로 미룸.
  - 저장 위치: `~/.condition-mate/bgm-slot-scores.json`(`AppPaths.base`).
  - 쓰기 주체: **앱이 파생·소유**하는 데이터이므로 `track-playstats.json`처럼 앱이 atomic write
    (직접 쓰기 허용). safe-write POST 규약은 **에이전트가 편집하는** 데이터(goals, bgm-plan)에만
    적용된다 — 슬롯 점수는 앱 산출물이라 API 경유 쓰기 불필요.

**결정: Phase 1 = B1(파생).** 지속 캐시는 추세 요구가 생기면 Phase 1.5에서 B2로.

### 축 C — 상태 감지 훅 위치 (Phase 2 대비, Phase 1은 미구현)

- 후보: `ConditionDirector`의 슬롯 재해석 지점(`ConditionDirector.swift:248`, 플랜 replace 시
  re-resolve)에 "슬롯 해석 후 보정 단계"를 추가 — 세션 활성+심야면 몰입 풀 유지, 장시간 유휴+심야면
  마무리/수면 풀로 강등. 입력은 `/api/session/state`(working) + 8h 업무시작 + 심야 밴드 + 세션 경과.
- Phase 1은 이 훅을 **건드리지 않는다.** §7 Phase 2에 설계만 기록.

---

## 5. Data Model — 슬롯 hit/miss 점수

### 5.1 슬롯 식별
- 조인 키: `trackChange.pool` 문자열에서 접두사 `플랜 · ` 를 제거한 나머지 = `BGMPlanMap.Slot.label`.
- 슬롯 메타(days/from/to/themes)는 `BGMPlanMap.plan.slots`에서 label로 매칭해 채운다.
- pool이 `플랜 · `로 시작하지 않는 이벤트(모드 폴백·폭우 리셋)는 슬롯 채점에서 제외.

### 5.2 세션 → 슬롯 귀속
- 세션 = `sessionStart` … 다음 `sessionStop`(같은 흐름) 윈도우.
- 그 세션의 지배 슬롯 = 세션 윈도우 내 `trackChange` 이벤트들의 `pool` 슬롯 라벨.
  한 세션이 슬롯 경계를 넘으면(예: 목→금 심야) **관여한 각 슬롯에 세션 1건씩 귀속**한다.

### 5.3 신호 규칙 (per slot)
- **hit (+1)**: 그 슬롯이 관여한 세션이 부정 신호 없이 종료.
  - 완주 판정: `mode=pomodoro`는 `sessionStop`의 경과초가 목표(≈1500s) 이상이면 명확한 hit.
    `sprint`/`unlimited`는 임계 없음 → "부정 신호 없이 종료"를 hit로 간주(약한 hit).
- **miss (+1)**: 그 슬롯 윈도우 안에서 발생한
  - `dislike` 액션(명시적 싫어요), 또는
  - 세션 중 `mute`(unmute로 곧 복구돼도 그 슬롯 곡을 껐다는 신호).
- **중립(집계 제외)**: `trackChange`의 `강제 전환` detail — 슬롯 경계·프로필·유휴가 섞인 신호라
  miss로 세지 않는다(§2 오탐 방지). `bgmOff`/`bgmOn`도 슬롯 품질과 무관하므로 제외.

### 5.4 파생 점수 스키마 (엔드포인트 응답 = 파생 결과)
슬롯별 레코드:
- `label` (string) — 슬롯 라벨(조인 키)
- `days` (string), `from` (string "HH:mm"), `to` (string "HH:mm") — 플랜에서 채운 메타
- `themes` (string[]) — 플랜 테마 풀
- `sessions` (int) — 귀속 세션 수
- `hits` (int), `misses` (int)
- `score` (int) — `hits - misses`
- `hitRate` (number 0..1) — `hits / max(1, hits+misses)`
- `rePlanCandidate` (bool) — 재계획 후보 플래그. 규칙: `sessions >= 3 && hitRate < 0.5`.
- `lastHitAt` (int, epoch|0), `lastMissAt` (int, epoch|0)
- `sampleTracks` (string[], ≤3) — 그 슬롯에서 최근 hit 세션에 흐른 곡 제목(증거 표시용)

응답 봉투:
- `generatedAt` (int epoch), `window` (string, 예 "actions.jsonl 최근 ~1MB"),
  `activeStrategy` (int), `slots` (위 레코드 배열, `score` 내림차순 → 동점 시 `sessions` 내림차순).

시간 표시: 응답의 모든 시각은 **UTC epoch**로 담고, 표시는 클라이언트에서 `CMTimeFilter.parts`로만 변환.

---

## 6. API Surface

### 6.1 신규 GET `/api/bgm/slot-scores`
- 응답: §5.4 봉투 JSON.
- 구현: `AppDelegate`에 `bgmSlotScoresJSON()` 추가 — `ActionLog.recentJSON`이 읽는 것과 동일한
  `actions.jsonl`을 재생해 §5.2~5.3 규칙으로 파생, `BGMPlanMap.plan.slots`로 메타 조인.
  선곡·플랜·파일 쓰기 **없음**(순수 읽기·파생).
- **화이트리스트 등록 필수**: `DashboardServer.swift`의 GET OR 체인(현 235-247행,
  `/api/bgm/stats` 인접)에 `|| path.hasPrefix("/api/bgm/slot-scores")` 추가.
- 라우팅: `AppDelegate.swift:33~` 핸들러 블록에 `if path.hasPrefix("/api/bgm/slot-scores")
  { return self?.bgmSlotScoresJSON() }` 추가.

### 6.2 신규 POST — 없음 (Phase 1)
파생 전용이라 쓰기 엔드포인트 불필요. Phase 3의 재계획 제안은 **기존** `POST /api/bgm/plan`
(검증 replace)을 재사용한다 — 새 쓰기 경로를 만들지 않는다.

---

## 7. UI — 대시보드

기존 **전략 히스토리** 섹션(`BGMPlayerContent.swift:399-402`, `/api/bgm/stats`의 `strategies`로
렌더)을 **확장**한다. 두 부분:

1. **전략4 카탈로그 카드** — §8의 카탈로그 추가만으로 전략 히스토리 목록과 필터 버튼에 **자동 표시**
   (추가 UI 코드 불필요). 전략3 카드의 retro도 §8의 seed로 채워져 3→4 전환 서사가 드러난다.
2. **슬롯 성적표(신규 sub-section)** — 전략 히스토리 아래에 "슬롯 성적표(전략4 관측)" 블록 추가.
   - 데이터: `GET /api/bgm/slot-scores`.
   - 렌더: 슬롯 라벨 · 요일/시간대 · `hits`/`misses`/`score` · hitRate 바 · `rePlanCandidate`면
     "재계획 후보" 배지. `sampleTracks`를 서브텍스트로.
   - 시각/색: 상태 신호등(빨강/녹색) 금지 규약 유지 — hitRate는 중립 톤 바로 표현(녹색은
     음원 뮤트 버튼 전용). "재계획 후보" 배지는 강조색이되 위험(빨강) 의미로 쓰지 않는다.
   - 시간 표시는 `CMTimeFilter.parts`만 사용.
- reviewJSON/lastView 수정 불필요(§3) — 별도 엔드포인트 로드.

---

## 8. 전략 카탈로그 엔트리 (구현 텍스트)

`TrackPlayStats.swift`의 `seedStrategies`에 id=4 추가 + `migrateCatalog()`에 3→4 이관 로직
(3을 닫고, 3의 빈 retro를 seed로 채우고, 4를 append, `activeStrategy=4`). 기존 3→ 이관과 동일 패턴,
**멱등**(id 4 존재 시 no-op → 사용자 편집 retro 미덮어씀).

전략3 retro seed (현재 빈 문자열을 채움):
```
요일×시간대 사전 계획은 실제로 잘 맞았지만(2026-07-10 00:00 '금 심야·애프터 라운지' 슬롯이 '딱 적절한 타이밍'으로 첫 적중), 계획이 맞는지/틀리는지 검증할 피드백 루프가 없었다 — actions.jsonl 기반 슬롯별 hit/miss 관측·교정 레이어(전략4)로 확장. 플랜 맵은 대체되지 않고 전략4의 실행 가설로 유지.
```

전략4 엔트리:
- `id`: 4
- `name`: `상태 인지형`
- `startedAt`: `2026-07-10`
- `endedAt`: `` (진행 중)
- `summary`: `전략3 플랜 맵을 가설로 유지하고, 컨디션맵 업무시작(8h 갭)·세션 진행/유휴·심야 활동과 actions.jsonl 피드백(싫어요·뮤트·완주)을 슬롯별 hit/miss로 채점하는 폐루프. 계획을 실행하며 동시에 검증·교정. Phase1은 관측·표시만(선곡·플랜 무변경).`
- `retro`: `` (진행 중)

`activeStrategy` 처리(축 A/B와 연결된 결정): **Phase 1에서 `activeStrategy`를 4로 올린다.**
- 근거: `TrackPlayStats.swift:20-23` 헤더가 4 도입을 "새 엔트리 + activeStrategy bump"으로 못박음.
  전략 히스토리에 "진행 중" 엔트리를 하나로 유지(3 닫고 4 오픈)해 카탈로그가 깔끔.
- 정직성: Phase 1의 선곡은 여전히 플랜 맵으로 동작하지만, "관측 레짐(전략4)"으로 전환된 시점부터의
  재생시간을 4 태그로 모으면 "상태 인지 레짐 전후 곡 편중 개선"을 비교할 근거가 된다.
- 되돌리기: 이 bump가 유일한 가역 노브다. 재생시간 태깅만 바뀌고 선곡·오디오는 불변 → 부작용 없음.
- OPEN(§11)로도 남긴다 — 사용자가 "선곡이 실제로 바뀔 때(Phase 2)까지 3을 유지"를 원하면
  bump를 Phase 2로 미룰 수 있다.

---

## 9. SPEC.md 반영 (구현과 함께 랜딩)

구현 에이전트가 코드와 **함께** `docs/specs/SPEC.md`에 아래 항목을 추가한다(behavior가 코드와
같이 이동해 manager-qa가 드리프트를 잡도록). manager-pm은 여기서 코드 미변경 원칙상 SPEC.md를
직접 편집하지 않고 문구만 지정한다.

신규 SPEC 항목 (BGM/전략 섹션):
```
- 전략4 · 상태 인지형(관측): 전략3 플랜 맵을 유지한 채, actions.jsonl을 재생해 슬롯별 hit/miss를
  채점한다. hit=슬롯 관여 세션이 부정 신호 없이 종료(포모도로는 목표초 이상 완주), miss=슬롯 윈도우
  내 dislike 또는 세션 중 mute. trackChange의 '강제 전환'은 슬롯 경계/유휴가 섞인 신호이므로 miss로
  세지 않는다. 점수는 GET /api/bgm/slot-scores로 파생(저장/쓰기 없음), 대시보드 전략 히스토리 아래
  '슬롯 성적표'로 표시. 선곡·플랜 파일은 자동 변경하지 않는다. sessions>=3 && hitRate<0.5 → 재계획
  후보 배지. 전략 카탈로그에 id=4(상태 인지형) 추가, activeStrategy=4로 이관.
```

---

## 10. Phased Plan

- **Phase 1 — 관측 전용(Observatory) [지금 구현].**
  카탈로그 전략4 append + `migrateCatalog` 3→4 이관 + 전략3 retro seed(§8);
  `bgmSlotScoresJSON()` 파생(§5); GET `/api/bgm/slot-scores` + 화이트리스트/라우팅(§6.1);
  대시보드 슬롯 성적표 sub-section(§7); SPEC.md 항목(§9). **선곡·플랜·쓰기 미접촉.**
- **Phase 1.5 — 점수 캐시(선택).** 추세/장기 이력 필요 시 `bgm-slot-scores.json` 앱-소유 atomic
  캐시(축 B2). 스냅샷을 주기적으로 append해 시간축 추이 제공.
- **Phase 2 — 교정 루프(closed loop).** `ConditionDirector` 슬롯 해석 후 보정 단계 추가(축 C):
  세션 활성+심야=몰입 풀 유지, 장시간 유휴+심야=마무리/수면 풀 강등. 플래그 뒤에서. 플랜 파일
  write-back은 **사람 확인 후에만**, 절대 무음(silent) 변경 금지.
- **Phase 3 — 재계획 제안.** 재계획 후보 슬롯을 관리자 AI에게 `POST /api/bgm/plan` diff 제안으로
  올림(human/AI-in-the-loop). 자동 적용 없음.

---

## 11. Open Questions

1. **activeStrategy bump 시점** — Phase 1에서 4로 올릴지(§8 권고), 아니면 선곡이 실제로 바뀌는
   Phase 2까지 3을 유지할지. 권고는 Phase 1 bump(헤더 규약 일치·카탈로그 단일 진행중). 사용자 확정 필요.
2. **재계획 후보 임계** — `sessions>=3 && hitRate<0.5`가 초기값. 표본이 쌓이기 전엔 후보가 뜨지
   않도록 최소 세션 3을 뒀다. 사용자 감으로 조정 가능(2로 완화 / 0.4로 엄격 등).
3. **sprint/unlimited의 hit 판정** — 목표초가 없어 "부정 신호 없이 종료"만으로 약한 hit 처리.
   너무 관대하면 성적표가 낙관 편향될 수 있음 — 최소 지속시간(예 10분↑)만 hit로 볼지 검토.

---

## 12. Ready-to-dispatch 구현 프롬프트

### Phase 1 → expert 엔지니어(예: expert-backend / general-purpose)

```
전략4 · 상태 인지형 BGM Phase 1(관측 전용)을 구현하라. 스펙:
/Users/lioncho/Work/departtment_service/projects/condition-mate/docs/specs/strategy4-state-aware-bgm.md
User: lioncho. 사용자 응답 한국어, 코드 주석·식별자 영어.

범위(선곡 로직·오디오·플랜 파일은 절대 건드리지 말 것 — 순수 관측·표시 증분):

1) 전략 카탈로그 확장 (Sources/ConditionMate/Core/TrackPlayStats.swift)
   - seedStrategies에 id=4 엔트리 추가(스펙 §8 텍스트 그대로: name "상태 인지형",
     startedAt "2026-07-10", endedAt "", summary/ retro §8).
   - migrateCatalog()에 3→4 이관 추가: id 4 미존재일 때만(멱등) — 전략3 endedAt이 비면
     "2026-07-10"으로 닫고, 전략3 retro가 비면 §8 seed 문자열로 채우고, 4를 append,
     activeStrategy=4. id 4 존재 시 no-op(사용자 편집 retro 미덮어씀).

2) 슬롯 점수 파생 (Sources/ConditionMate/AppDelegate.swift)
   - func bgmSlotScoresJSON() -> String 추가. ActionLog가 읽는 것과 동일한
     events/actions.jsonl(최근 ~1MB 윈도우)을 재생.
   - 세션 귀속: sessionStart..sessionStop 윈도우, 그 안 trackChange.pool에서 접두사 "플랜 · "
     제거한 라벨 = 슬롯. 슬롯 경계 넘으면 관여 각 슬롯에 세션 1건씩.
   - hit: 슬롯 관여 세션이 부정신호 없이 종료(mode=pomodoro는 sessionStop 경과초>=1500이면 확정
     hit; sprint/unlimited는 부정신호 없이 종료를 약한 hit). miss: 슬롯 윈도우 내 dislike 또는
     세션 중 mute. trackChange의 "강제 전환" detail은 miss로 세지 말 것(중립). bgmOff/On 제외.
   - 슬롯 메타(days/from/to/themes)는 BGMPlanMap.plan.slots에서 label 매칭으로 채움.
   - 응답: 스펙 §5.4 스키마(slots는 score 내림차순, 동점 시 sessions 내림차순; 모든 시각은 UTC
     epoch). rePlanCandidate = sessions>=3 && hitRate<0.5. sampleTracks ≤3.
   - 순수 읽기·파생. 파일 쓰기 금지.

3) 엔드포인트 노출
   - Sources/ConditionMate/AppDelegate.swift 라우팅 핸들러 블록(현 33행 인근)에
     if path.hasPrefix("/api/bgm/slot-scores") { return self?.bgmSlotScoresJSON() } 추가.
   - Sources/ConditionMate/Dashboard/DashboardServer.swift GET 화이트리스트 OR 체인
     (현 235-247행, /api/bgm/stats 인접)에 || path.hasPrefix("/api/bgm/slot-scores") 추가.

4) 대시보드 UI (Sources/ConditionMate/Dashboard/BGMPlayerContent.swift)
   - 전략 히스토리 섹션(399행 인근) 아래에 "슬롯 성적표(전략4 관측)" sub-section 추가.
   - GET /api/bgm/slot-scores로 로드해 슬롯별 라벨·요일/시간대·hits/misses/score·hitRate 바 렌더,
     rePlanCandidate면 "재계획 후보" 배지, sampleTracks 서브텍스트.
   - 상태 신호등(빨강/녹색) 금지 규약 준수(녹색=뮤트 버튼 전용). hitRate는 중립 톤 바.
   - 시간 표시는 CMTimeFilter.parts만 사용(raw Date getter 금지).
   - reviewJSON/lastView는 건드리지 않는다(별도 엔드포인트 로드).

5) SPEC 반영: docs/specs/SPEC.md의 BGM/전략 섹션에 스펙 §9 항목 텍스트 추가(코드와 함께 랜딩).

빌드 통과(swift build) 후, GET /api/bgm/slot-scores가 골든 샘플을 hit으로 집계하는지 확인:
'금 심야 · 애프터 라운지' 슬롯이 hits>=1, misses=0, score>=1로 나와야 한다(스펙 §2).
완료 후 manager-qa 검증용으로 (a) 슬롯-성적표 응답 예시 JSON, (b) 전략 히스토리에 전략4 표시
스크린샷/HTML 근거, (c) activeStrategy=4 확인을 보고하라.
```

### 검증 게이트 → manager-qa

```
전략4 Phase 1(관측 전용)을 SPEC §9 항목과 스펙
docs/specs/strategy4-state-aware-bgm.md 기준으로 검증하라. PASS 조건:
1) swift build 성공, 앱 격리 인스턴스 기동.
2) GET /api/bgm/slot-scores 200 + 스펙 §5.4 스키마 준수(필드 존재·타입·정렬).
3) 골든 샘플(스펙 §2): '금 심야 · 애프터 라운지' 슬롯 hits>=1, misses=0, score>=1.
4) 오탐 방지: trackChange의 '강제 전환'만으로는 miss가 증가하지 않음(같은 00:00 목→금 flip이
   miss로 집계되지 않아야 함).
5) 전략 히스토리에 전략4(상태 인지형, 진행 중) 표시 + 전략3 retro가 3→4 전환 서사로 채워짐,
   activeStrategy=4.
6) 선곡·플랜 무변경 회귀: bgm-plan.json 미변경, /api/bgm/now 동작 불변, 오디오 재생 정상.
7) 상태 신호등(빨강/녹색) 금지 규약 위반 없음, 시간 표시 CMTimeFilter.parts 사용.
FAIL 시 미탐 항목과 재현 로그를 첨부하고 QA fix-loop(최대 3라운드) 개시.
```
