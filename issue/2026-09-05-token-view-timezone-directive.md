# 토큰 뷰 날짜 경계 타임존 작업지시서

- 날짜: 2026-09-05
- 트랙: BEST · 레벨 L1 · 규모 P2
- 트랙 카드: `organization/lion/lion-work-queue/inbox/2026-09-04-token-view-timezone-issue.md`
- 대상 화면: 대시보드 → 토큰 뷰 (`/tokens.json`, `/tokens-sessions.json`, 요약 줄)
- 이 문서를 쓴 자리: 이 폴더는 `P2` 라 PO 자리가 따로 없다. 진입 세션이 자기 손으로 썼다.

## 원문 (온 그대로, 요약하지 않았다)

> 발견 (lion-condition-mate 세션 `term_814ea136-ffde-440e-b3ff-fa6bd3952b99`에서 보내옴):
>
> 토큰 뷰의 모든 날짜 경계가 KST가 아니라 이 맥의 시스템 타임존(IST, UTC+5.5)에 묶여 있다.
>
> 근거 — 대시보드 요약 줄에 `시각 Asia/Calcutta (UTC+5.5) 기준`이라고 이미 찍혀 있다. 그래서
> "오늘"과 일자 그룹의 경계가 라이언이 사는 시간과 5시간 30분 어긋난다.
>
> 트랙 카드의 1초 요약:
> 요구 — 토큰 뷰의 날짜 경계 기준이 시스템 타임존(IST, UTC+5.5)에 묶여 있는 현재 상태 확인.
> 문제 — 대시보드가 이미 UTC+5.5 기준을 사용 중이므로, 이것이 의도된 설계인지 아니면 KST
> 기준으로 정정해야 하는지 판정 필요.
> 완성 — 토큰 뷰의 날짜 경계 기준이 확정되고 필요시 정정된다.

## 실측 — 무엇이 실제로 벌어지고 있나

### 이 맥의 시스템 타임존은 진짜로 IST 다

```
$ readlink /etc/localtime
/var/db/timezone/zoneinfo/Asia/Kolkata
$ date
Sat Sep  5 16:00:02 IST 2026
```

큐가 오늘 쓴 타임스탬프도 전부 `+05:30` 으로 찍혔다. 추정이 아니라 지금 그런 상태다.
`Asia/Kolkata` 를 `TimeZone.current` 로 읽으면 `Asia/Calcutta` 로 정규화되므로, 요약 줄의
`Asia/Calcutta (UTC+5.5)` 는 정확히 이것이다.

### 타임존 배관은 이미 다 깔려 있다 — 코드 버그가 아니었다

이것이 이번 조사에서 가장 중요한 실측이다. 원문은 "날짜 경계가 시스템 타임존에 묶여 있다"
고 했는데, 실제로는 **묶여 있는 게 아니라 설정값 하나가 `"system"` 이어서 그렇게 풀린 것**
이다. 이미 있는 것:

- `Sources/ConditionMate/Core/Settings.swift:512` — `timeZoneID` 설정. 기본값 `"system"`.
- `Sources/ConditionMate/Core/Settings.swift:613` — `displayTimeZone`. `"system"` 이면 `.current`.
- `Sources/ConditionMate/AppDelegate.swift:6951` — `POST /api/settings/timezone`. `"system"` 또는
  유효한 IANA id 만 받는다.
- `Sources/ConditionMate/Dashboard/DashboardContent.swift:1075` — 헤더 우상단 셀렉터.
  `시스템 (맥 설정)` / `Asia/Seoul KST (UTC+9)` / `UTC (+0)` 세 값.
- `Sources/ConditionMate/Dashboard/CMTimeFilter.swift` — JS 쪽 정본. 서버가 주입한
  `window.CM_TZ` 를 읽어 `dayStr`·`presetRange`·`parts` 를 그 벽시계로 계산한다. 오프셋 메모,
  DST 2회 수렴 보정까지 들어 있다.

토큰 뷰의 서버측 일자 버킷도 전부 이 설정을 탄다:

- `AppDelegate.swift:4183-4188` (`dashboardTokens`) — `cal.timeZone` · `dayFmt.timeZone` 둘 다
  `Settings.shared.displayTimeZone`.
- `AppDelegate.swift:4341-4344` (`dashboardTokenSessions`) — 같다.
- `AppDelegate.swift:4675` (`transcriptStats`) — 캐시 키에 타임존 id 를 넣어, KST↔UTC 를
  바꾸면 다른 존으로 쪼갠 일자 캐시를 재사용하지 않게 막아 뒀다.
- `Core/CodexTokenCollector.swift:45`, `Core/AntigravityTokenCollector.swift:36` — 같다.

디스크에 실제로 저장된 값:

```
$ python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.condition-mate/settings.json')))['cm.timeZone'])"
system
```

**즉 화면에 `Asia/Calcutta` 가 찍힌 것은 배관이 새서가 아니라, 밸브가 `시스템` 에 놓여 있고
그 시스템이 인도 시간이기 때문이다.**

### 그런데 배관 밖에 있는 자리가 하나 있다 — 활동 로그

`Sources/ConditionMate/Core/ActivityLog.swift:15-26` 의 `dayFormatter` 는 **타임존을 안 건다.**

```swift
let df = DateFormatter()
df.locale = Locale(identifier: "en_US_POSIX")
df.dateFormat = "yyyy-MM-dd"       // ← timeZone 미지정 → TimeZone.current (IST)
dayFormatter = df
```

그래서 `~/.condition-mate/activity/activity-YYYY-MM-DD.jsonl` 의 날짜는 표시 타임존이 아니라
언제나 **시스템 로컬** 로 잘린다. 디스크가 그렇게 말한다 — `activity-2026-09-04.jsonl` 의
mtime 이 `Sep 4 23:59` (IST) 다.

읽는 쪽 둘은 그 **파일 이름을 곧 날짜로 믿는다:**

- `ActivityLog.swift:121` `activeSecondsByDay(days:)` — 파일명을 키로 `active` 를 합산.
- `ActivityLog.swift:85` `historyJSON(days:)` — 파일명을 `"day"` 로 그대로 내보냄.

그리고 `activeSecondsByDay` 는 **토큰 뷰가 직접 쓴다:**

```
AppDelegate.swift:4287-4288
        // Active human seconds per day — for the 가치 mode's time-efficiency weighting.
        let activeSec = activityLog.activeSecondsByDay(days: days)
```

`totals` 는 `displayTimeZone` 으로 자른 날이고 `activeSec` 는 시스템 로컬로 자른 날인데, 두
맵을 같은 `day` 문자열로 조인한다. **지금은 둘 다 IST 라서 우연히 맞는다.** 표시 타임존만
KST 로 바꾸고 여기를 안 고치면, 토큰 뷰 `가치` 모드의 시간효율 배수가 KST 하루치 토큰을
IST 하루치 시간으로 나누게 된다 — 매일 3시간 30분어치 활동이 잘못된 날에 붙는다. 화면은
안 깨지고 숫자만 조용히 틀린다. **이번 변경이 새로 만드는 결함이므로 같이 고쳐야 한다.**

### 앱은 이미 세 자리에서 KST 를 못박고 있다

- `Core/AppLog.swift:14` — `static let logTimeZone = TimeZone(identifier: "Asia/Seoul")`. 앱 로그의
  시각은 이미 KST 다.
- `AppDelegate.swift:11956` — `isoWeek(of:)` 의 캘린더가 `Asia/Seoul`. 태스크 이름의 `_<W>w`
  주차 접미사가 KST 주차다.
- `AppDelegate.swift:11999` — `aiTaskNameParts` 의 `todayStr` 가 `Asia/Seoul`.

즉 **앱은 이미 "라이언의 하루는 KST 다" 를 전제하고 동작하는 부분을 갖고 있고,
표시 타임존 기본값만 그 전제와 어긋나 있다.**

### 정책 문서에는 타임존이 없다

`docs/time-policy.md` 를 읽었다. 토탈·책상·집중·퇴근 4분할, 10분 연속성 규칙, 가치 배수,
어뷰징 필터가 있다. **"어느 타임존의 하루인가" 는 한 줄도 없다.** 이 폴더에 날짜 경계의
정본 문서는 존재하지 않는다. 없다는 것을 가정으로 적고 진행한다 (L1 규칙).

`issue/2026-09-04-glm-zai-token-tracking-directive.md` 와
`issue/2026-09-04-context-window-usage-directive.md` 도 읽었다. 토큰 뷰를 만든 지시서가 맞지만
**둘 다 타임존이나 날짜 경계 의도를 적어 두지 않았다.** 원 설계 의도는 문서로 남아 있지 않다.

## 판정 — KST 로 고정한다 (셀렉터는 남긴다)

L1 이므로 라이언에게 묻지 않고 여기서 정한다. 근거는 넷이다.

1. **앱이 이미 KST 를 전제하고 있다.** 로그 타임존, ISO 주차, 태스크 이름의 오늘 날짜가
   전부 `Asia/Seoul` 하드코딩이다. 표시 기본값만 `system` 이라 앱 안에서 두 개의 "오늘" 이
   공존한다. 하나로 맞추는 방향은 KST 쪽이다 — 이미 셋이 그쪽에 있고 하나만 반대편에 있다.
2. **이 제품이 세는 것은 라이언의 하루다.** `docs/time-policy.md` 의 토탈·퇴근·6시간 공백은
   전부 사람의 근무 스팬이다. 근무 스팬의 경계는 노트북 설정이 아니라 사는 곳이 정한다.
3. **`system` 은 조용히 틀린다.** IST 는 라이언이 고른 값이 아니라 이 맥이 그렇게 되어 있는
   것이다. 기본값이 기계 설정을 따르면, 기계 설정이 어긋난 순간 데이터가 아무 경고 없이
   어긋난다. 실제로 이번에 그렇게 됐고, 화면에 라벨이 찍혀 있었는데도 며칠을 못 봤다.
4. **되돌릴 수 있다.** 셀렉터가 이미 있으므로, KST 가 틀리면 헤더에서 한 번 누르면 된다.
   반대로 기본값을 `system` 으로 두는 쪽은 "지금 뭘 보고 있는지" 를 매번 라벨로 확인해야
   한다. 잘못됐을 때의 비용이 비대칭이다.

**안 고르는 쪽:** `system` 기본 유지 + 라벨 강조. 이미 라벨이 찍혀 있었는데 못 잡았다는 것이
그 안의 반증이다. 라벨은 이미 최대치이고 더 키울 곳이 없다.

**이번에 하지 않는 것:** `Asia/Seoul` 을 코드에 못박아 셀렉터를 없애지 않는다. 셀렉터는
그대로 두고 기본값과 폴백만 KST 로 옮긴다. 라이언이 실제로 다른 시간대에서 일하게 되면
그때 눌러서 바꾸는 길이 남아 있어야 한다.

## 무엇을 고치는가

### 1. 표시 타임존 기본값을 `Asia/Seoul` 로

`Sources/ConditionMate/Core/Settings.swift:512`

```swift
var timeZoneID: String {
    get { string(K.timeZone) ?? "system" }      // → ?? "Asia/Seoul"
    set { set(newValue, K.timeZone) }
}
```

주석(505-511행)도 같이 고친다. `"system" (default)` 이 더 이상 사실이 아니다.

### 2. 이미 저장된 `"system"` 을 1회만 `Asia/Seoul` 로 옮긴다

기본값만 바꾸면 이 맥은 안 바뀐다. `settings.json` 에 `cm.timeZone: "system"` 이 이미 들어
있기 때문이다. 그렇다고 매번 `"system"` 을 KST 로 읽어 버리면 셀렉터의 `시스템 (맥 설정)`
항목이 영원히 눌리지 않는 죽은 버튼이 된다.

그래서 **1회 마이그레이션 플래그**를 쓴다. 새 설정 키 `cm.timeZoneKSTMigrated` (Bool) 를 두고,
앱 시작 시 한 번:

- 플래그가 없고 저장값이 정확히 `"system"` 이면 → `"Asia/Seoul"` 로 쓰고 플래그를 세운다.
- 그 외에는 아무것도 안 한다.

이후에 라이언이 셀렉터에서 `시스템 (맥 설정)` 을 직접 고르면 플래그가 이미 서 있으므로
그 선택이 그대로 유지된다. 마이그레이션 코드 옆에 **왜 이렇게 했는지와 이 판정이 L1 에서
사람 확인 없이 내려졌다는 것을 주석으로 남긴다.**

### 3. 활동 로그의 일자 버킷을 표시 타임존으로 맞춘다 — 파일 이름을 믿지 않는다

`Sources/ConditionMate/Core/ActivityLog.swift`

파일 이름 규칙은 **안 바꾼다.** 바꾸면 이미 디스크에 있는 파일 전부가 다른 규칙으로 잘려
있게 되고, 마이그레이션 없이는 과거가 영구히 어긋난다. 대신 **읽는 쪽에서 각 샘플의 `t`
(epoch) 로 다시 버킷한다.** 파일 이름은 날짜가 아니라 저장 샤드로만 쓴다.

- `activeSecondsByDay(days:)` — 요청 구간 앞뒤로 파일 1개씩 여유를 두고 읽은 뒤, 각 줄의 `t`
  를 `Settings.shared.displayTimeZone` 기준 `yyyy-MM-dd` 로 변환해 그 키에 `active` 를 더한다.
  반환은 지금과 같은 `[String: Int]`.
- `historyJSON(days:)` — 같은 방식으로 샘플을 표시 타임존 일자에 재배치해 `"day"` 를 낸다.
  앞뒤 여유 파일 1개씩. 브라우저가 받는 계약(`{"day":…,"samples":[…]}`)은 그대로 둔다.
- `fileURL(for:)` 의 `dayFormatter` 옆에 **"이 이름은 저장 샤드일 뿐이고 날짜 경계가 아니다.
  경계는 읽는 쪽이 `t` 로 정한다"** 를 주석으로 못박는다. 이 주석이 없으면 다음 사람이 같은
  자리를 다시 판다.

여유 파일 1개씩이 필요한 이유: KST 는 IST 보다 3시간 30분 빠르므로, KST 하루 D 는 IST 로
D-1 의 20:30 에 시작한다. 그 3시간 30분은 `activity-<D-1>.jsonl` 안에 들어 있다.

### 4. 무엇을 안 고치는가

- `AppLog.logTimeZone`, `isoWeek(of:)`, `aiTaskNameParts` 의 `Asia/Seoul` 하드코딩 셋은 그대로
  둔다. 이번 판정이 KST 이므로 어차피 같은 값이 되고, 이것들을 설정에 묶는 것은 별개의
  범위다. 다만 **셀렉터로 UTC 를 고르면 이 셋만 KST 로 남는다** 는 것은 사실이므로 아래
  `남은 것` 에 적는다.
- 트랜스크립트·활동 로그의 저장 포맷은 손대지 않는다. 저장은 계속 epoch 이다.
- 셀렉터의 세 항목(`시스템`/`Asia/Seoul`/`UTC`)을 늘리거나 줄이지 않는다.
- `docs/time-policy.md` 는 이번 범위에서 한 줄만 더한다 (아래 5번). 4분할 규칙 자체는 안 건드린다.

### 5. 정책 문서에 날짜 경계를 적는다

`docs/time-policy.md` 에 `## 날짜 경계` 절을 새로 만든다. 지금 이 문서에 그 축이 통째로
없어서 이번 건이 "의도인지 버그인지" 를 판정할 근거가 없었다. 다음에 같은 질문이 오면
그 문서 한 줄로 끝나야 한다. 내용은 이 지시서의 `판정` 절을 3~5줄로 줄인 것 —
기본 경계는 KST(`Asia/Seoul`), 저장은 언제나 epoch, 헤더 셀렉터로 표시 기준만 바꿀 수 있고
셀렉터를 바꾸면 토큰 뷰의 일자 그룹과 `오늘` 이 같이 움직인다.

## 검증 — 실제로 돌린다

`swift build` 만으로는 이 건이 안 잡힌다. 날짜 경계는 실행해서 숫자를 봐야 한다.

1. `swift build` 통과. 경고 신규 0.
2. **`.build` 함정 확인.** 이 폴더는 `.build` 가 `~/.cache/cm-swiftpm-build` 로 가는 심볼릭
   링크다 (`2026-09-04-glm-zai-token-tracking-directive.md` 의 `곁다리` 절 참조). 저장소 안에
   `.build` 실체가 생기면 SwiftPM 이 `disk I/O error` 를 내고도 `Build complete!` 로 exit 0 을
   돌려주며 **고친 코드가 안 들어간 바이너리를 내놓는다.** 빌드 후 `ls -la .build` 로 링크가
   살아 있는지 확인하고, 바이너리에 실제로 반영됐는지는 아래 3~6 번의 HTTP 응답으로 본다.
3. **격리 인스턴스로 기본값 확인.** `Scripts/e2e-glm-tokens.sh` 와 같은 방식으로
   `CM_DATA_DIR=$(mktemp -d) CM_DASHBOARD=1 .build/debug/ConditionMate` 를 띄우고
   `GET /api/settings/timezone` 이 `{"tz":"Asia/Seoul","effective":"Asia/Seoul","label":"KST (UTC+9)"}`
   를 주는지 본다. 빈 데이터 디렉터리이므로 이것이 **새 기본값**의 검사다.
4. **마이그레이션 확인.** 격리 디렉터리에 `{"cm.timeZone":"system"}` 만 든 `settings.json` 을
   미리 넣고 띄운 뒤, 같은 엔드포인트가 `Asia/Seoul` 을 주고 `cm.timeZoneKSTMigrated` 가
   파일에 생겼는지 본다. 그 상태에서 `POST /api/settings/timezone {"tz":"system"}` 을 보내고
   재시작해 **`system` 이 유지되는지** 본다 (플래그가 서 있으므로 다시 안 바뀌어야 한다).
   이 세 번째 확인이 빠지면 셀렉터를 죽여 놓고도 통과한다.
5. **일자 경계가 실제로 움직이는지.** IST 20:30–23:59 구간(= KST 다음날 00:00–03:29)에
   assistant 줄이 있는 트랜스크립트를 픽스처로 만들어 격리 인스턴스가 읽는 자리에 놓고,
   `GET /tokens.json?days=7` 에서 그 토큰이 **다음 날** 키에 붙는지 본다. 안 움직이면 이번
   변경이 토큰 뷰에 도달하지 않은 것이다.
6. **활동 시간이 같은 날에 붙는지.** 같은 경계 구간의 `active` 샘플이 든
   `activity-<D-1>.jsonl` 을 격리 데이터 디렉터리에 놓고, `/tokens.json` 의 그 날 행에 붙는
   활동 초가 **KST 일자 기준**인지 본다. 3번 항목 없이 이것만 보면 안 되고, 반대도 안 된다 —
   두 축이 같은 날에 만나는 것이 이번 변경의 핵심이다.
7. 회귀: 기존 e2e 중 시간에 의존하는 것들(`Scripts/e2e-energy.sh`, `.e2e/tallyhist.test.js`,
   `.e2e/ontrack.test.js`)을 돌려 깨진 게 없는지 본다. 깨지면 그 테스트가 시스템 로컬을
   전제하고 있었던 것이므로, 테스트를 고치고 무엇을 왜 고쳤는지 보고에 적는다.

검사는 재현 가능한 스크립트로 남긴다 — `Scripts/e2e-timezone-boundary.sh`. `e2e-glm-tokens.sh`
의 구조(격리 `CM_DATA_DIR`, `dashboard.port` 폴링, PASS/FAIL 카운트, trap cleanup)를 그대로
따른다. 새 구조를 발명하지 않는다.

## 남은 것 — 이번에 안 고치는 것을 이름으로 남긴다

1. **셀렉터로 `UTC` 를 고르면 앱 안에 두 개의 하루가 생긴다.** `AppLog.logTimeZone`,
   `isoWeek(of:)`, `aiTaskNameParts` 셋이 `Asia/Seoul` 하드코딩이라 표시만 UTC 로 가고 로그와
   태스크 이름은 KST 로 남는다. 이번 판정이 KST 라서 실害가 없지만 결함은 결함이다.
2. **활동 로그 파일 이름은 여전히 시스템 로컬로 잘린다.** 읽는 쪽에서 `t` 로 재버킷하므로
   숫자는 맞지만, 파일을 사람이 직접 열어 볼 때(`grep activity-2026-09-05.jsonl`) 그 안의
   시각은 IST 하루다. 파일 이름까지 맞추려면 과거 파일 재분할 마이그레이션이 필요하고,
   그것은 이번 요구 범위 밖이다.
3. **`historyJSON` 을 쓰는 히스토리 탭의 브라우저 쪽 재집계가 서버의 새 `day` 와 어긋나지
   않는지**는 이번에 서버 쪽 계약만 유지하는 것으로 막았다. 브라우저가 `day` 를 무시하고
   `t` 로 다시 자르고 있다면 이 변경은 무해하고, `day` 를 쓰고 있다면 이 변경으로 오히려
   정확해진다. 어느 쪽인지는 워커가 확인해 보고에 한 줄로 적는다.

   **답 (2026-09-05, `lion-condition-mate-worker-qa-webview-state` 소스 정독):
   둘 다 있고 둘 다 안전하다.** `/history.json` 을 fetch 하는 자리는 저장소 전체에 딱 둘이고
   둘 다 `Sources/ConditionMate/Dashboard/BGMPlayerContent.swift` 안에 있다.
   - **히스토리 탭은 `day` 를 그대로 쓴다** (`:3067` 이 `d.day>=_histStart && d.day<=_histEnd`
     로 거르고, `:3080`·`:3093` 이 `r.day` 로 묶고 정렬한다). `t` 는 그 안에서 시(hour) 버킷을
     만드는 데만 쓴다. → 이번 변경으로 **더 정확해지는 쪽**이다.
   - **컨디션맵 탭은 `day` 를 통째로 무시하고 `t` 로 다시 자른다** (`:2495-2500` 이 모든 샘플을
     평탄화하고, `:2505` 의 `localDayStr(t)` 가 일자를 만든다). → 이번 변경과 **무관하다**.
   - 두 기준이 어긋나지 않는 이유: 재계산 쪽이 시스템 로컬이 아니라 서버가 주입한
     `window.CM_TZ` 를 쓴다 (`CMTimeFilter.swift:32`, 주입은 `:171-178` 의 `tzAssignJS()`).
     그 값과 서버의 `day` 가 **같은 `Settings.shared.timeZoneID` 에서 갈라져 나온다.**
     그래서 한 화면에 두 방식이 공존하지만 같은 벽시계로 수렴한다. 결함 아님.
   - 실측하지 못한 것: 이 판정은 소스 정독만으로 냈다. 라이브 `curl /history.json` 대조는
     안 했다 — 다만 `Scripts/e2e-timezone-boundary.sh` 의 `[7]` 이 서버가 내는 `day` 쪽은
     격리 인스턴스로 실제 검증한다.

## 진행 상태 — 2026-09-05 마감 실측

이 절은 지시서를 쓴 뒤에 실제로 무엇이 디스크에 들어갔는지의 기록이다. 판정과 계획은
위의 절들이 정본이고, 여기서 뒤집지 않는다.

**다섯 항목 전부 반영됐다.**

| # | 무엇 | 어디 | 상태 |
|---|---|---|---|
| 1 | 기본값 `Asia/Seoul` | `Sources/ConditionMate/Core/Settings.swift:523-525` (근거 주석 505-522) | 반영 |
| 1' | `displayTimeZone` 폴백만 KST 로, `"system"` 브랜치는 명시적 선택으로 존치 | `Settings.swift:634-638` | 반영 |
| 2 | 1회 마이그레이션 | `Sources/ConditionMate/AppDelegate.swift:1370-1380`, 호출 `:620` (다른 무엇보다 먼저) | 반영 |
| 3 | 활동 로그를 `t` 로 재버킷 | `Sources/ConditionMate/Core/ActivityLog.swift` — `shardDays()`·`displayDayFormatter()`·`shardsCovering(days:)`·`shardObjects(_:)` 신설, `historyJSON(days:)`·`activeSecondsByDay(days:)` 재작성 | 반영 |
| 4 | 안 고치는 것 | — | 지켰다 |
| 5 | `## 날짜 경계` 절 | `docs/time-policy.md` (5줄) | 반영 |

**검증 하네스**: `Scripts/e2e-timezone-boundary.sh` (신규). `Scripts/e2e-glm-tokens.sh` 의 구조를
그대로 따랐다 — 격리 `CM_DATA_DIR`, `dashboard.port` 폴링, PASS/FAIL 카운트, trap cleanup.
`.build` 가 심볼릭 링크인지를 먼저 확인하고 아니면 즉시 멈춘다.

`PASS=8 FAIL=0` (2026-09-05, 연속 4회 재현). 검사 항목은 지시서 `## 검증` 의 3·4·5·6 에 대응한다.

- 빈 데이터 디렉터리 → `GET /api/settings/timezone` == `{tz:Asia/Seoul, effective:Asia/Seoul, label:KST (UTC+9)}`
- 저장된 `"system"` → 부팅 1회로 `Asia/Seoul`, `settings.json` 에 `cm.timeZoneKSTMigrated:true` 가 남는다
- **그 뒤 셀렉터로 `시스템` 을 다시 고르면 재시작을 넘어 유지된다** (`effective`=`Asia/Kolkata` 로 실측). 지시서가 특히 지목한 세 번째 확인이고, 이것이 없으면 셀렉터를 죽여 놓고도 통과한다
- 경계 구간 토큰: `tz=system` 일 때 `2026-09-02` → `tz=Asia/Seoul` 일 때 `2026-09-03` (123,000 tok 이 통째로 이동)
- 같은 구간 활동 초: `2026-09-02` 150s → `2026-09-03` 150s. **토큰과 같은 행에 붙는다** — 두 축이 만나는 자리
- `/history.json` 의 `day` 도 같은 경계를 쓰고 `{day,samples[{t,active,mult,meeting,tier,app}]}` 계약이 그대로다

**회귀**: `Scripts/e2e-energy.sh` 16/0, `.e2e/tallyhist.test.js` 63/0, `.e2e/ontrack.test.js` 14/0.
고친 테스트 없다.

**빌드**: `swift build` 통과, 신규 경고 0. `.build` 는 `~/.cache/cm-swiftpm-build` 링크로 살아 있다.
소스 mtime 이 바이너리보다 앞선 순간이 있어 강제 재컴파일 후 바이너리를 바이트 비교했고 동일했다
— 즉 초록 빌드가 낡은 바이너리를 가린 상태가 아니다.

### 알려진 것 — 이 하네스는 완전히 격리되지 않는다

`AppDelegate.claudeProjectsBase` 가 `FileManager.homeDirectoryForCurrentUser` 를 쓰므로 트랜스크립트
루트에 환경변수 우회가 없다. 그래서 픽스처 트랜스크립트만은 실제 `~/.claude/projects` 아래 고유
이름 폴더에 놓고 trap 으로 지운다. 결과로 **같은 맥에서 앱 인스턴스 둘이 동시에 그 폴더를 전수
스캔하면 `/tokens.json` 이 빈 응답을 주고 검사가 거짓 실패한다** — 실제로 1회 관측했다
(`PASS=6 FAIL=2`, 단독 실행 4회는 전부 `8/0`). 하네스를 단독으로 돌려라. 이것을 없애려면
트랜스크립트 루트에 `CM_CLAUDE_PROJECTS_DIR` 같은 우회를 새로 내야 하고, 그것은 이번 범위 밖이다.

### 마감 — 설치본까지 반영했다 (2026-09-05 16:31, 진입 세션)

앞 절은 "설치본은 여전히 IST 이므로 라이언이 `Scripts/build-app.sh` 를 돌려야 한다" 로 끝나
있었다. 그것을 라이언에게 넘기지 않고 진입 세션이 여기서 끝냈다. `L1` 이라 멈추는 자리가
없고, 트랙 카드의 완성 줄이 "필요시 정정된다" 이므로 코드에만 들어간 상태는 완성이 아니다.

`Scripts/build-app.sh` 를 돌리기 전에 메뉴바 앱이 안 떠 있는 것을 확인했다
(`pgrep -lf "ConditionMate.app/Contents/MacOS/ConditionMate"` 가 빈 결과). 남아 있던 것은
slack-eyes 데몬 하나뿐이라 quit/swap 이 사람 작업을 끊을 자리가 없었다.

```
Build complete! (65.22s)
==> Updating /Applications/ConditionMate.app
==> Relaunched /Applications/ConditionMate.app
```

서명은 `ConditionMate Dev` 가 없어 ad-hoc 으로 떨어졌다 (스크립트가 그렇게 알린다). 그래서
**손쉬운 사용(Accessibility) 권한이 이번 재빌드로 풀렸을 수 있다.** 이것은 이번 변경이 만든
것이 아니라 이 폴더에서 서명 없이 다시 말 때마다 늘 생기는 것이고, `Scripts/setup-signing.sh`
를 한 번 돌리면 없어진다. 이번 범위 밖이라 돌리지 않았고 사실만 적는다.

재기동 뒤 실측 — 격리 픽스처가 아니라 **라이언이 실제로 보는 인스턴스**다.

```
$ python3 -c "...settings.json..."
cm.timeZone= 'Asia/Seoul'  migrated= True

$ curl -s http://127.0.0.1:57797/api/settings/timezone
{"tz":"Asia/Seoul","effective":"Asia/Seoul","label":"KST (UTC+9)"}

$ curl -s http://127.0.0.1:57797/ | grep -o "Asia/Calcutta\|Asia/Seoul\|KST (UTC+9)\|UTC+5.5" | sort | uniq -c
  10 Asia/Seoul
   3 KST (UTC+9)
```

`Asia/Calcutta` 와 `UTC+5.5` 는 대시보드 HTML 어디에도 남아 있지 않다. 1회 마이그레이션이
실제로 돌아 저장값이 `system` 에서 `Asia/Seoul` 로 옮겨졌고 플래그가 섰다. `/tokens.json?days=4`
의 일자 키도 KST 기준으로 나온다.

**하네스는 이 마감 시점에 다시 돌리지 않았다.** `Scripts/e2e-timezone-boundary.sh` 는 픽스처를
실제 `~/.claude/projects` 아래에 놓는데 (`AppDelegate.claudeProjectsBase` 가
`homeDirectoryForCurrentUser` 라 우회가 없다), 방금 설치본을 다시 띄웠으므로 앱 인스턴스 둘이
같은 폴더를 동시에 전수 스캔해 `/tokens.json` 이 빈 응답을 주는 거짓 실패가 난다 — 검증 세션이
실제로 1회 관측한 것이다. 통과 근거는 그 세션의 단독 실행 4회 연속 `PASS=8 FAIL=0` 이고,
마감 근거는 위의 라이브 인스턴스 실측이다. 둘을 합쳐서 완성으로 판정했다. 하네스를 앱이 뜬
상태에서도 돌리려면 `CM_CLAUDE_PROJECTS_DIR` 같은 우회를 새로 내야 하고 그것은 이번 범위 밖이다.

### 이 폴더의 정리 레벨 — `C2` 로 정한다

`destinations.json` 에 이 폴더의 `cleanup` 값이 없다. 없으므로 끝낸 세션이 정한다는 규칙에
따라 `C2` 로 판정한다. 근거는 둘이다. 산출물이 전부 이 폴더 안의 파일과 커밋 대상 코드로
남아 창 스크롤백에만 있는 사실이 없다는 것, 그리고 남은 것 세 가지를 아래 절에 이름으로
적어 두어 다음 세션이 창을 다시 열 이유가 없다는 것이다.

## 1초 요약

요구 — 토큰 뷰의 모든 날짜 경계가 KST 가 아니라 이 맥의 시스템 타임존(IST, UTC+5.5)에 묶여
있으니, 의도된 설계인지 KST 로 정정할 것인지 판정하고 필요하면 고쳐라.
문제 — 코드는 이미 표시 타임존 설정 하나로 모든 경계를 몰아 놓았고 새는 데가 없다. 어긋난
것은 그 설정의 기본값이 `system` 이고 이 맥이 인도 시간이라는 것뿐인데, 앱은 로그·주차·태스크
이름 세 자리에서 이미 KST 를 못박고 있어 앱 안에 두 개의 "오늘" 이 공존한다. 그리고 표시
타임존만 KST 로 옮기면 활동 로그가 파일 이름(시스템 로컬)을 날짜로 믿고 있어 토큰 뷰의
시간효율 배수가 조용히 3시간 30분 어긋난다.
완성 — 표시 타임존 기본값이 `Asia/Seoul` 이 되고 저장된 `system` 이 1회 마이그레이션되며,
활동 로그가 파일 이름 대신 각 샘플의 epoch 으로 일자를 잘라, 격리 인스턴스에서 IST 20:30 의
토큰과 활동 초가 둘 다 KST 기준 다음 날 행에 붙는 것이 `Scripts/e2e-timezone-boundary.sh` 로
재현된다.
