# BGM 관리 (BGM Management)

ConditionMate가 배경음악(BGM)을 언제, 어떤 템포로 재생할지 결정하는 규칙을 정리한 문서입니다. 코드 기준은 다음 파일들입니다.

- `Sources/ConditionMate/AppDelegate.swift` — 1초 하트비트에서 재생 여부(세션)를 판정
- `Sources/ConditionMate/Audio/ConditionDirector.swift` — 상태 머신(WARMUP/SUSTAIN/RELEASE)으로 목표 BPM 결정
- `Sources/ConditionMate/Audio/BPMLibrary.swift` — 목표 BPM에 가장 가까운 트랙 선택
- `Sources/ConditionMate/Audio/AudioEngine.swift` — 실제 재생/크로스페이드/일시정지
- `Sources/ConditionMate/Core/ActivityMonitor.swift` — 키보드/마우스 입력률과 유휴 시간 측정
- `Sources/ConditionMate/Core/BGMProfile.swift` — 앱별 템포 밴드(프로파일)
- `Sources/ConditionMate/Core/Settings.swift` — 사용자 설정 기본값

---

## [1] 현재 BGM 재생 조건

### 1.1 재생 게이트 (세션 판정)

BGM이 소리를 내려면 매 1초 하트비트(`onHeartbeat`)에서 계산되는 `inSession`이 참이어야 합니다. 세 조건이 모두 만족해야 합니다.

- `isWorking` — 메뉴의 마스터 스위치가 켜져 있을 것 (최상위 게이트)
- `appOK` — 추적 앱 필터 통과. 추적 앱을 지정하지 않았으면 어떤 전경 앱이든 통과하고, 지정했으면 전경 앱이 그 목록에 있어야 통과
- `!isIdle` — 유휴 상태가 아닐 것. `isIdle`은 마지막 입력 이후 경과 시간(`activity.idleSeconds`)이 설정값 `cm.idleSeconds`(기본 60초) 이상이면 참

판정식: `inSession = isWorking && appOK && !isIdle`

추가로 실제 재생이 일어나려면 다음도 필요합니다.

- `musicEnabled` 설정이 켜져 있을 것 (기본값 true)
- 음악 폴더가 지정되어 있고 BPM이 해석된 트랙이 한 개 이상 적재되어 있을 것 (`library.tracks`가 비어있지 않음). 폴더가 없으면 세션당 1회 폴더 선택을 안내

### 1.2 재생 게이트의 상태 전이

`onHeartbeat`에서 매초 다음을 수행합니다.

- `musicEnabled`이고 트랙이 있을 때
  - `inSession`이면: 디렉터가 미동작이면 `director.start()`로 새 사이클 시작, 동작 중이나 일시정지 상태면 `director.resumeSession()`으로 재개
  - `inSession`이 아니면: 동작 중이던 디렉터를 `director.pauseSession()`으로 일시정지(소리만 끄고 phase/targetBPM은 보존)
- `musicEnabled`이 꺼졌으면: `director.stop()`으로 완전 종료

즉 **유휴(idle) 또는 추적 앱 비활성 또는 마스터 스위치 OFF가 되면 BGM은 일시정지되어 아무 소리도 나지 않습니다.**

### 1.3 템포 결정 상태 머신 (ConditionDirector)

세션 중에는 20초마다 `tick()`이 돌며 키보드+마우스 입력률(`activityRate`)을 읽어 목표 BPM(`targetBPM`)을 조정합니다. 목표 BPM은 현재 활성 프로파일의 밴드(`activeMinBPM`~`activeMaxBPM`) 안에서 움직입니다.

- WARMUP — 매 틱 `warmupStep`(8 BPM)씩 목표를 올려 사용자를 끌어올림. 상한(maxBPM)에 도달하면 SUSTAIN으로 전이
- SUSTAIN — 상한 부근 유지. 개인 최고치(`peakActivity`) 대비 정규화 활동량(`norm`)이 임계(0.6) 아래로 떨어진 틱이 연속 3회(`stagnationTicks`)면, 빠른 템포가 더 이상 효과 없다고 보고 RELEASE로 전이
- RELEASE — 밴드 하단 근처의 낮은 BPM(밴드 폭의 10% 지점)으로 떨어뜨려 회복 구간 진입. `cm.releaseMinutes`(기본 5분) 경과 후 더 낮은 바닥(밴드 폭의 25% 지점)에서 WARMUP 재시작

`peakActivity`는 매 틱 2%씩 감쇠하면서 최근 최대치를 추종하므로, 일회성 폭주가 기준을 영구 고정하지 않습니다.

### 1.4 트랙 선택과 전환

- `BPMLibrary.track(forTargetBPM:excluding:)`이 목표 BPM에 가장 가까운 트랙을 고름(현재 재생 중인 곡은 가능하면 제외)
- 무의미한 잦은 교체를 막기 위해, 강제(`force`)가 아니면 목표 BPM이 `trackSwitchDeltaBPM`(6 BPM) 이상 움직였을 때만 곡을 바꿈
- 교체 시 `AudioEngine`이 2초 크로스페이드로 부드럽게 전환

### 1.5 앱별 프로파일(템포 밴드) 전환

전경 앱이 `dwellThreshold` 이상 안정적으로 유지되고 그 앱이 추적 대상이면, 해당 앱의 프로파일 키로 `director.applyProfile(...)`을 호출해 템포 밴드를 바꿉니다. 기본 프로파일(`BGMProfile`)은 다음과 같습니다.

- chill (칠/느긋): 75~100 BPM — 브라우저 등 가벼운 작업
- steady (스테디/안정): 100~125 BPM — 글쓰기/기획 (기본값)
- focus (집중/몰입): 120~150 BPM — 코딩/딥워크
- hype (하이프/고조): 140~175 BPM — 고조

### 1.6 주요 설정 기본값 (Settings)

- `cm.minBPM` = 70, `cm.maxBPM` = 150 (전역 밴드, 프로파일 미적용 시 사용)
- `cm.releaseMinutes` = 5 (RELEASE 회복 시간, 분)
- `cm.idleSeconds` = 60 (이 시간 이상 무입력이면 유휴로 간주)
- `cm.musicEnabled` = true, `cm.volume` = 0.8

---

## [2] 유휴 상태에서 "매우 느린 음악" 재생 (구현 완료)

### 2.1 이전 동작과 문제

마우스/키보드가 `cm.idleSeconds`(기본 60초) 이상 움직이지 않으면 `isIdle`이 참이 되어 `inSession`이 거짓이 됩니다. 이전에는 그 결과 `director.pauseSession()`이 호출되어 **BGM이 완전히 멈추고 아무 소리도 나지 않았습니다.**

요구사항: 자리 비움/무입력 상태에서 침묵 대신 **매우 느린(저 BPM) 음악**이 흐르도록 한다. 사용자가 잠시 멈춰 생각하거나 자료를 읽는 동안에도 음악이 끊기지 않게 하여 몰입의 단절을 줄이는 것이 목적이다.

### 2.2 적용된 설계: IDLE(앰비언트) 모드

"유휴 = 일시정지"를 "유휴 = 최저 템포 앰비언트 재생"으로 바꿨습니다. `Phase` 열거형은 그대로 두고, 디렉터에 별도 플래그(`isIdleMode`)와 진입/이탈 메서드를 추가해 복귀를 단순화했습니다.

핵심 동작:

- 유휴로 진입하면 일시정지하지 않고, 라이브러리에서 가장 느린 트랙으로 목표 BPM을 낮춰 재생을 유지한다.
- 볼륨을 `cm.idleVolumeScale`(기본 0.5)배로 낮춰 배경으로 물러나게 한다.
- 결정 타이머를 멈춰 유휴 동안 템포가 다시 오르지 않게 한다.
- 입력이 재개되면 직전 phase/targetBPM/볼륨으로 복원하고 결정 타이머를 재가동한다.

### 2.3 구현 내용

- `ConditionDirector` (`Sources/ConditionMate/Audio/ConditionDirector.swift`)
  - 상태 추가: `isIdleMode`(외부 공개), 그리고 복원용 `savedPhase`/`savedTargetBPM`/`savedVolume`.
  - `enterIdle()`: 멱등. 디렉터가 미동작이면 새 세션을 시작한다(자리 비움이라도 무음이 되지 않도록). 진입 시 현재 phase/targetBPM/볼륨을 저장하고, 결정 타이머를 멈춘 뒤 목표를 `idleTargetBPM()`로 내리고 볼륨을 `idleVolumeScale`배로 낮춰 `applyTrack(force: true)`로 느린 트랙으로 크로스페이드한다.
  - `exitIdle()`: 저장한 phase/targetBPM/볼륨을 복원하고 결정 타이머를 재가동한다.
  - `idleTargetBPM()`: 라이브러리 최저 BPM(`library.bpmRange?.min`)과 활성 밴드 하단(`activeMinBPM`) 중 더 느린 값을 사용한다. 라이브러리에서 실제로 가장 느린 곡이 선택된다.
  - `pauseSession()`/`stop()`: 앰비언트 도중 호출되면 저장한 phase/targetBPM/볼륨을 먼저 되돌려, 이후 정상 재개나 다음 시작이 올바른 상태에서 출발하도록 한다.
  - `isPlaying`: `isActive || isIdleMode`. 결정 타이머가 멈춘 앰비언트 중에도 소리가 나는 상태를 가리킨다.

- `AppDelegate.onHeartbeat()` (`Sources/ConditionMate/AppDelegate.swift`)
  - 음악 게이트 분기에서 "유휴만이 비세션 사유인 경우"를 분리한다. 판정: `isWorking && appOK && isIdle && cm.idleAmbientEnabled`.
    - 해당 시: `director.enterIdle()`로 앰비언트 유지.
    - 그 외 비세션(추적 앱 비활성, 마스터 OFF 등): 재생 중이면 `pauseSession()`(또는 음악 OFF 시 `stop()`).
    - 다시 `inSession`이 참이 되면: 직전이 앰비언트였으면 `exitIdle()`로 복원, 아니면 기존대로 `start()`/`resumeSession()`.
  - 라이브 상태 문구: 유휴이면서 앰비언트가 켜져 있고 추적 앱이 활성일 때 "자리 비움 · 앰비언트", 그 외 유휴는 "자리 비움 · 일시정지".
  - 대시보드 샘플과 디버그 출력은 `isPlaying`/`isIdleMode`를 사용해 앰비언트 재생을 반영한다(유휴 중 phase는 "IDLE"로 표기).
  - 메뉴의 "이 곡 싫어요"(dislike)도 앰비언트 재생 중 동작하도록 `isPlaying` 기준으로 변경.

- `Settings` (`Sources/ConditionMate/Core/Settings.swift`) — 신규 키
  - `cm.idleAmbientEnabled` (기본 true): 유휴 시 앰비언트 재생 on/off.
  - `cm.idleVolumeScale` (기본 0.5): 앰비언트 중 기본 볼륨에 곱하는 배수(0~1).

### 2.4 사용자 체감 동작

- 작업 중: 입력량에 따라 WARMUP→SUSTAIN→RELEASE로 템포가 오르내림 (기존과 동일).
- 60초 이상 무입력: 음악이 멈추지 않고 가장 느린 곡으로 부드럽게 내려가며 볼륨이 절반으로 줄어 배경으로 깔림. 메뉴는 "자리 비움 · 앰비언트" 표시.
- 다시 입력 시작: 직전 상태로 복귀해 자연스럽게 템포를 회복.

### 2.5 참고

- 라이브러리에 충분히 느린 트랙(예: 60~75 BPM)이 있어야 "매우 느림"이 체감된다. 가장 느린 곡이 그래도 빠르면, 코드 변경 없이 느린 곡을 음악 폴더에 추가하면 효과가 커진다.
- 앰비언트를 끄려면 `cm.idleAmbientEnabled`를 false로 두면 이전처럼 유휴 시 일시정지한다.

---

## [3] 시작 음원 전략 (BGM 시작/전이 전략)

### 3.1 전략 개요

곡을 "기능(BPM)"이 아니라 "장면(scene)"으로 배치한다. 사용자가 앱을 처음 켜는 순간을 게임의 로그인/시작 화면처럼 연출하고, 잠깐의 적응 시간 뒤에는 본격 작업을 위한 "시작 마을" 분위기로 자연스럽게 넘긴다. 곡별 역할은 다음과 같다.

- **096 유리문 속 세계로** — 시작(로그인) 곡. 앱을 처음 켜면 가장 먼저 흐른다. "유리문 속 세계로 들어간다"는 진입감이 로그인/세션 시작의 느낌과 맞는다.
- **105 새출발** — 시작 직후 정착 곡. 앱 시작 후 5분이 지나면 105로 넘어간다. 게임에서 튜토리얼을 지나 "시작 마을"에 도착해 본격적으로 자리잡는 느낌. 새출발 엔딩의 분위기가 작업 정착 구간과 잘 어울린다.
- **082** — 릴리즈(RELEASE) 전용 곡. 시작 구간에서는 쓰지 않고, RELEASE 단계(휴식/회복)로 떨어질 때 배치하기에 더 어울린다.

### 3.2 시점별 음원 배치

앱 시작 시점을 기준으로 한 타임라인은 다음과 같다.

- 앱 첫 실행(0분): 096 유리문 속 세계로 — 로그인/진입 연출.
- 시작 후 5분 경과: 105 새출발 — 시작 마을 정착, 본격 작업 구간 진입.
- RELEASE 단계 진입 시: 082 — 휴식/회복 연출.

5분 기준은 RELEASE 회복 시간 설정값(`cm.releaseMinutes`, 기본 5분)과 의도적으로 같은 호흡으로 맞춘다. 즉 "시작 → 정착"의 전이 호흡이 "긴장 → 회복"의 전이 호흡과 일관되게 느껴지도록 한다.

### 3.3 구현 내용 (구현 완료)

기본 동작은 디렉터가 WARMUP으로 시작해 `BPMLibrary.track(forTargetBPM:)`으로 목표 BPM에 가장 가까운 곡을 자동 선택하는 것이다([1.3]~[1.4]). 시작 전략은 이 자동 선택 위에 "씬(scene) 곡 고정"을 얹어 구현했다. 곡은 파일명에 포함된 키워드로 식별한다(BPM 번호가 같은 `[096]` 곡이 둘이라 번호가 아닌 제목으로 구분).

- `BPMLibrary.track(matchingKeyword:)` (`Sources/ConditionMate/Audio/BPMLibrary.swift`) — 파일명에 키워드가 포함된 첫 트랙을 대소문자 무시로 찾는다. 씬 매핑 전용 조회.

- `ConditionDirector` (`Sources/ConditionMate/Audio/ConditionDirector.swift`)
  - 씬 키워드 상수: 오프닝 `"유리문"`(096), 정착 `"새 출발 엔딩"`(105), 릴리즈 `"창가의 바람"`(082). 오프닝 유지 시간 `openingHoldMinutes` = 5분.
  - 오프닝 상태: `openingPlayed`(이번 실행에서 오프닝을 한 번 했는지), `openingActive`(오프닝 진행 중), `openingStartedAt`(시작 시각). `openingPlayed`는 `stop()`으로 초기화되지 않아 실행(프로세스)당 한 번만 재생된다 — 실행 도중 음악 토글로는 재생되지 않는다.
  - `start()`: 이번 실행의 첫 활성 시작이면 자동 BPM 선택 대신 오프닝 곡(096 유리문)을 강제 재생하고 결정 타이머만 가동한다. 라이브러리에 해당 곡이 없으면 기존 `resumeSession()`(자동 선택)으로 폴백한다.
  - `tickOpening()`: 오프닝 중에는 적응 결정을 멈추고 5분 경과만 감시한다. 5분이 지나면 105 새 출발 엔딩으로 전환("시작 마을" 정착)하고 오프닝을 끝낸 뒤 WARMUP·밴드 하단으로 되돌려 다음 틱부터 적응 제어가 자연스럽게 이어받게 한다.
  - RELEASE 진입(SUSTAIN→RELEASE 전이) 시 082 창가의 바람을 한 번 고정 재생한다. 이후 릴리즈 틱은 최소 재생 시간(min-dwell)으로 이 곡을 유지하며, 라이브러리에 없으면 기존 최근접 BPM 선택으로 폴백한다.

동작 요약: 앱 첫 실행 후 작업을 시작하면 096이 흐르고, 5분 뒤 105로 넘어가 정착한 다음 평소의 입력량 기반 템포 제어가 이어진다. 작업 중 빠른 템포가 더 이상 효과 없어 RELEASE로 떨어질 때는 082가 배치된다.

### 3.4 참고와 한계

- 곡 식별은 파일명 키워드(유리문 / 새 출발 엔딩 / 창가의 바람)에 의존한다. 음원 파일명을 바꾸면 매칭이 끊겨 해당 씬은 자동 선택으로 폴백한다.
- 오프닝은 활성 세션 `start()`에서만 시작된다. 앱을 켠 직후 곧바로 유휴(자리 비움)로 진입해 앰비언트로 먼저 시작한 경우에는 오프닝이 생략될 수 있다(작업을 아직 시작하지 않은 상태로 보기 때문).
- 오프닝 중 대시보드 phase 표기는 WARMUP으로 보이지만 실제로는 씬 곡(096)이 재생된다.
