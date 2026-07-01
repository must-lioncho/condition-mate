# goal-11: 볼륨 다운 신호 기반 BGM 선호도 학습

- 상태: in_progress (6절 dislike 버튼 슬라이스 구현 완료, 1~5절 볼륨 추론 미착수)
- 목적: 모티베이션 알고리즘 개선
- 작성일: 2026-06-24
- 관련 코드: AudioEngine, BPMLibrary, ConditionDirector, ActivityLog, ActivityMonitor

## 구현 현황

완료 (dislike 버튼 수직 슬라이스):
- Core/TrackPreference.swift: TrackPreferenceStore. score(0~1, 1=중립),
  recordDislike(score 하향 + cooldown), bpmPenalty/isBlocked, decay 복귀,
  track-prefs.json 영속화.
- Core/TrackEventLog.swift: events/track-events.jsonl 컨텍스트 스냅샷 원자료.
- BPMLibrary.track(...): penalty/blocked 클로저로 가중 선택(기본 동작 불변).
- ConditionDirector: prefStore 주입, applyTrack에 penalty/blocked 반영,
  dislikeCurrentTrack()(강등+cooldown+즉시 교체), lastNorm 노출.
- MenuController: 재생 중일 때 "이 곡 싫어요" 항목. AppDelegate.dislikeCurrentTrack()
  컨텍스트 수집 후 이벤트 기록.

확정 튜너블(7절·8절 미해결 질문에 대한 1차 선택):
- dislikePenalty = 0.5 (dislike 1회당 score 하향폭)
- penaltyScaleBPM = 40 (score 0 -> 가상 거리 +40 BPM)
- recoveryHalfLifeDays = 3 (score 복귀 반감기)
- dislikeCooldown = 2시간 (재선택 완전 차단 구간)

검증: swift build 통과. 전체 앱 부트 e2e(goal-status) 17/17 통과.
TrackPreferenceStore 실코드 단위 점검 8/8 통과(penalty 20/40 BPM, cooldown
2h 경계, 3일 후 반감, 영속화 재로드). dislike 자체는 메뉴(UI) 경로라 자동화
e2e 미커버.

미착수:
- 1~5절 볼륨 다운 암묵 신호(인앱 setter 훅 / CoreAudio 시스템 볼륨)
- 7절 컨텍스트 차원의 알고리즘 반영(현재는 원자료 수집만)

## 배경 / 문제 정의

특정 BGM 음원은 업무에 오히려 방해가 되는 경우가 있다. 사용자는 그럴 때
음악 소리를 줄인다. 이 "볼륨 줄임" 행동을 트래킹할 수 있다면, 해당 트랙의
선호도를 낮추고 업무에 도움이 되는 음원을 우선 추천하는 방향으로
모티베이션 알고리즘을 개선할 수 있다.

핵심 가설: "볼륨을 줄였다"는 행동은 해당 트랙에 대한 음성(negative) 신호로
활용 가능하다. 단, 항상 그런 것은 아니므로 맥락 보정이 필요하다(아래 3절).

## 1. 신호 종류와 포착 지점

현재 AudioEngine은 자체 AVAudioPlayer.volume만 제어하고 시스템 볼륨은
관찰하지 않는다. 따라서 "볼륨 줄임" 신호는 두 갈래로 나뉜다.

- 인앱 볼륨 슬라이더 하향
  - 의미: 메뉴 슬라이더로 직접 줄임
  - 포착: AudioEngine.targetVolume setter를 래핑해 변화 로깅
  - 난이도: 낮음 (Settings.volume 흐름이 이미 존재)

- OS 출력 볼륨 / 음소거 하향
  - 의미: 맥 시스템 단에서 줄임
  - 포착: CoreAudio AudioObjectAddPropertyListener (VirtualMainVolume) 신규 추가
  - 난이도: 중간

1차 구현 대상은 인앱 볼륨 변화로 한다. 메뉴 슬라이더가 이미
Settings.volume -> targetVolume 경로로 흐르므로, setter 훅 하나로
"어떤 트랙 재생 중에 얼마나 줄였는지"를 바로 기록할 수 있다.
ActivityLog가 이미 1분마다 현재 track 제목을 기록하므로, 타이밍 상관만으로
"이 트랙에서 볼륨 다운" 이벤트를 구성할 수 있다.

## 2. 현재 코드 구조 요약

- AudioEngine (Audio/AudioEngine.swift): AVAudioPlayer 기반 루프 재생.
  targetVolume(기본 0.8, Settings.volume에 영속). 볼륨은 앱 시작 시 1회만 설정,
  이후 변화 관찰 없음.
- BPMLibrary (Audio/BPMLibrary.swift): 트랙을 BPM으로만 색인.
  track(forTargetBPM:excluding:)는 타깃 BPM에 가장 가까운 단일 트랙 반환.
  선호/평점/랭킹 개념 없음.
- ConditionDirector (Audio/ConditionDirector.swift): 모티베이션 상태머신
  (WARMUP / SUSTAIN / RELEASE). peakActivity 적응형 최대치, norm = 활동량/peak,
  활동량 기반으로 템포(트랙)를 조정. 트랙 품질 개념은 없음.
- ActivityLog (Core/ActivityLog.swift): 분당 JSONL 로깅. 필드에 track(현재 곡 제목),
  app, site, profile, phase, rate, working, meeting 등 포함. 7일 보존.
- ActivityMonitor (Core/ActivityMonitor.swift): meeting 플래그 등 활동 상태 제공.

즉, 이벤트 로깅 인프라(ActivityLog)와 맥락 신호(norm, meeting)는 이미 존재하며,
빠진 것은 (a) 볼륨 변화 관찰, (b) 트랙별 선호 영속화, (c) 선택 로직의 가중치 반영이다.

## 3. 핵심 함정 - 볼륨 다운이 곧 불호는 아니다

볼륨을 줄이는 이유가 트랙 불호가 아닌 경우가 많다.

- 회의 / 통화 시작: ActivityMonitor의 meeting 플래그로 배제 가능
- 깊은 집중 진입(타이핑 폭증): 오히려 트랙이 잘 맞는다는 신호일 수 있음
- 단순 환경 소음 변화: 노이즈

따라서 "볼륨 하향 -> 선호 하향" 직결은 알고리즘을 왜곡한다. 조건부 해석이 핵심이다.

기준 규칙(초안): 회의 상태가 아니면서 작업 활동량(norm)은 높게 유지되는데
볼륨을 내렸다면, 그때만 해당 트랙이 거슬린다는 음성 신호로 카운트한다.
norm과 meeting 플래그는 이미 존재하므로 추가 수집 비용은 없다.

## 4. 제안 설계 - 트랙 선호도를 모티베이션 루프에 연결

### (a) TrackPreference 영속화

트랙별 선호 데이터를 별도 저장한다. 후보 필드:

- volumeLowerCount: 음성 신호(맥락 보정 통과) 누적
- volumeRaiseCount: 양성 신호 누적
- skipCount: 조기 전환 횟수
- totalPlaySeconds: 누적 재생 시간
- score: 추천 가중치 (기본 1.0)
- lastUpdated: 마지막 갱신 시각

부정/양성 신호는 시간이 지나면 옅어지도록 decay를 적용한다.
ConditionDirector의 peakActivity가 틱마다 일정 비율 감쇠하는 패턴을 재사용한다.

### (b) 선택 로직 변경 (BPMLibrary)

- 기존: 타깃 BPM에 가장 가까운 단일 곡
- 변경: 타깃 BPM 밴드 내 후보군을 모은 뒤 score로 가중. 거슬린다고 학습된 곡은
  자연스럽게 후순위로 밀리고, 선호 곡이 우선 노출된다.
- 기존 히스테리시스(타깃 6 BPM 미만 이동 시 전환 안 함)는 유지해 잦은 곡 전환을 방지.

### (c) 양성 신호도 함께 수집 (균형)

회피 학습만 하면 선택지가 계속 좁아진다. 균형을 위해 양성 신호도 모은다.

- 볼륨을 올리거나, 높은 norm을 유지하며 끝까지 재생한 곡은 score 상향
- 목표가 "업무에 도움 되는 음원 추천"이므로 단순 회피가 아니라 선호 강화로 작동해야 함

## 5. 단계별 진행안

1. 관찰 단계 (동작 무변경): AudioEngine.targetVolume setter 훅 추가 +
   볼륨 변화 이벤트를 ActivityLog 필드로 기록. 기존 재생/선택 동작은 그대로 둔다.
2. 검증 단계: 며칠치 로그로 볼륨 다운이 실제 어떤 맥락에서 일어나는지 확인.
   3절의 함정(회의/집중/노이즈) 가설을 데이터로 검증.
3. 학습 적용 단계: 검증되면 TrackPreference 영속화 추가 + BPMLibrary 선택에
   score 가중 반영. 양성/음성 신호 모두 반영.
4. (선택) 확장: CoreAudio 기반 OS 시스템 볼륨 / 음소거 감지 추가.

권장: 1번부터 시작해 데이터 신뢰성을 먼저 확보한 뒤 알고리즘을 바꾼다.

## 6. 명시적 dislike 버튼 (강한 신호) - 추가 제안

볼륨 다운(1~5절)은 약하고 잦은 암묵 신호다. 이와 별개로, 메뉴에 명시적
"이 곡 싫어요" 버튼을 두면 사용자가 정확한 의사를 직접 표현할 수 있다.
누르면 즉시 다른 음원으로 교체하고, 해당 곡의 우선순위를 낮춘다.

두 신호는 대체재가 아니라 보완재다.

- dislike 버튼: 강한 신호 / 빈도 낮음 / 맥락 보정 불필요(이미 명확한 의사)
- 볼륨 다운 추론: 약한 신호 / 빈도 높음 / 맥락 보정 필수(회의·집중 배제)

같은 TrackPreference.score에 가중치만 다르게 합산하면 된다.

### 핵심 함정 - 즉시 교체는 다음 틱에 되돌아온다

ConditionDirector.applyTrack은 library.track(forTargetBPM:excluding:)으로
곡을 고르는데, excluding은 "지금 재생 중인 한 곡"만 제외한다. 목표 BPM이
그대로면 다음 결정 틱(약 20초)에서 방금 싫어한 곡이 가장 가까운 후보로
다시 선택되어 되돌아온다.

따라서 dislike 버튼은 반드시 선택 로직의 영속 penalty로 이어져야 한다.
이것이 곧 4절의 TrackPreference.score / BPMLibrary 가중 설계와 직결된다.
즉, dislike 버튼은 4절 학습 구조 위에 얹는 강한 입력 채널이다.

### 구현 개요

- 메뉴 항목: 현재 "♪ 제목" 줄(MenuController 곡 표시) 바로 아래, 재생 중일
  때만 노출. 라벨 예: "이 곡 싫어요 (다른 곡으로)".
- 액션 경로: onDislikeTrack -> delegate.dislikeCurrentTrack()
  -> director.dislikeCurrentTrack().
- director 동작:
  1. 현재 곡의 TrackPreference.score를 강하게 하향
  2. 단기 cooldown(이번 세션 또는 N시간) 재생 금지 목록에 등록
  3. cooldown을 반영한 applyTrack(force: true)로 즉시 교체
- BPMLibrary.track(forTargetBPM:) 선택 시 cooldown 목록과 score를 함께 반영.
- 영구 차단이 아니라 일시 강등 권장: decay로 시간이 지나면 다시 후보로 복귀해
  맥락/기분 변화에 대응.

## 7. 신호 컨텍스트 스냅샷 - 판단 근거 강화

신호(dislike, 볼륨 다운) 자체만으로는 "왜 싫은지"를 판단하기 약하다.
발생 시점의 컨텍스트가 함께 기록돼야, 같은 거부라도 "심야 피로 상태의 거부"
인지 "한낮 고활동 중의 거부"인지 구분해 컨텍스트별 선호를 학습할 수 있다.

같은 곡도 맥락에 따라 다르게 느껴진다. 따라서 신호를 단일 평균 score로만
뭉개지 말고, 신호 발생 시점의 컨텍스트 스냅샷을 함께 남겨야 알고리즘을
명확히 개선할 수 있다.

### 함께 기록할 컨텍스트 차원

- 시각 / 요일: 절대 timestamp, 시간대 버킷(새벽/오전/오후/야간), 요일,
  평일·주말. 서카디언 리듬과 피로의 프록시. 특히 심야 구간은 피로 누적으로
  빠른 BPM이 역효과일 수 있어, 심야 거부는 "곡 불호"가 아니라 "시간대 부적합"
  일 가능성이 있다. 시간대 분리가 특히 중요한 이유.
- 세션 경과: 현재 세션 시작 후 연속 작업 시간. 누적 피로 프록시.
- 누적 작업량: 오늘 총 작업 시간, 누적 시간. 직전 휴식 여부.
- 활동 수준: activityRate, norm(=rate/peakActivity), 현재 phase
  (WARMUP/SUSTAIN/RELEASE). 고활동 중 거부와 저활동 중 거부는 의미가 다르다.
- BGM 상태: 목표 BPM, 곡 BPM, 프로필, 해당 곡 재생 경과 시간
  (얼마나 듣고 나서 거부했는가).
- 작업 맥락: 현재 앱, 사이트 도메인, value tier, meeting 여부.

ActivityLog는 이미 rate/active/bpm/phase/app/profile/track/site/tier/working/
meeting/mult를 분당 기록 중이다. 신호 이벤트에는 여기에 더해 초단위
timestamp, hourBucket, weekday, sessionElapsed, trackElapsed, norm,
targetBPM, trackBPM, signalType(dislike/volumeDown/volumeUp),
signalMagnitude를 남기면 충분하다.

### 저장 방식 - 원자료 우선

- 이벤트 로그(원자료): 각 신호 발생 시 위 컨텍스트 전체를 한 줄로 기록.
  ActivityLog 확장 또는 별도 track-events.jsonl. 나중에 어떤 차원이 선호를
  실제로 가르는지 분석할 수 있게 한다.
- 집계(파생): 분석으로 유의미한 차원이 확인된 뒤에만 컨텍스트별 score를
  분리한다(예: 시간대 버킷별 score, phase별 score).

핵심 원칙: 먼저 원자료를 풍부하게 남기고(관찰 단계), 어떤 컨텍스트 차원이
실제로 선호를 가르는지 데이터로 확인한 뒤에 집계와 알고리즘에 반영한다.
차원을 성급하게 고정하지 않는다.

### 현재 시점 스냅샷 (실측 예시)

이 문서 작성 시점의 실제 컨텍스트를 참고 데이터포인트로 남긴다.

- 로컬 시각: 2026-06-24 01:24 KST, 수요일. 시간대 버킷: 심야(새벽).
- 작업 상태: 작업 중. 세션 경과 약 00:11:33.
- 작업량: 누적 1.8h, 오늘 1.0h. 다음 마일스톤(10h)까지 8.2h.
- 컨디션: 전략 기본, phase WARMUP, 목표 146 BPM.
- 재생 곡: [140] 흥겨운 골목길. 라이브러리 23곡(82~172 BPM).

해석 메모: 새벽 1시대 + 누적 1.8h라는 맥락에서는 빠른 BPM(146 목표) 곡에
대한 거부가 곡 자체의 문제라기보다 심야 피로로 인한 시간대 부적합일 수 있다.
이런 사례를 컨텍스트 없이 평균 score에만 반영하면, 낮 시간대에는 잘 맞는
곡까지 부당하게 강등될 위험이 있다. 컨텍스트 스냅샷이 필요한 직접적 근거.

## 8. 미해결 질문

- "볼륨 줄임"의 범위: 앱 내 슬라이더만인가, 맥 시스템 볼륨까지 포함인가.
  (구현 범위를 크게 가르는 결정 사항)
- 음성 신호로 카운트할 norm / meeting 임계값 구체화
- score decay 비율과 추천 가중 함수 형태
- 음소거(volume 0)와 점진적 하향을 동일 가중으로 볼지, 차등할지
- dislike cooldown 길이: 이번 세션 한정인지, N시간인지, 영구 옵션도 둘지
- dislike 1회의 score 하향폭과 볼륨 다운 신호의 상대 가중치
- 시간대 버킷 경계: 새벽/오전/오후/야간을 몇 시 기준으로 나눌지
- phase별(WARMUP/SUSTAIN/RELEASE) score를 분리할지, 통합할지
- 컨텍스트별 score 분리 시 데이터 희소성 처리: 버킷당 표본이 적을 때
  전역 score로 폴백할지, 베이지안 평활을 쓸지
