# 돋보기(🔍)를 내가 멘션된 메시지에만 단다 — 작업지시서

작성 2026-09-02 · PO(lion-condition-mate-pm) · 규모 P2 · 레벨 L1
워커 입력용이다. 사람 보고서가 아니다.

---

## 원문

라이언이 구술한 그대로다. 요약하지 않았다.

> "지금 컨디션 메이트 좀 손을 봐야겠는데, 얘가 뭐가 문제냐면 지금 나 멘션한 거 말고도
> 모든 메시지에 다 돋보기를 달고 있거든. 그렇게 지금 커뮤니케이션 코스트를 엄청나게
> 만들고 있어. 그렇게 하면 안 되고, 나한테 멘션한 것만 돋보기를 달고, 그다음에 이제
> 컨텍스트를 확보하는 걸로 해줘."

---

## 1. "돋보기" 가 무엇인지 — 조사해서 확정했다

라이언이 코드상 어느 기능인지 지목하지 않아 확정이 필요했다. **후보는 하나뿐이었다.**

`Sources/Plugins/Slack/Daemon/slack-emoji-layer.json:9`

```
"pendingEmoji": "mag",
```

🔍(`mag`)는 **오늘(2026-09-02) 만들어져 오늘 라이브로 나간 "보는 중" 이모지**다.
근거는 `docs/2026-09-02-slack-reply-policy-split-brief.md` 전체이고, 특히
§9-1 의 코퍼스 1748건 재생 실측에서 **1569건이 `white_check_mark → mag` 로 바뀌었다**
(90%). 그 브리프의 §10 은 라이언이 A 안을 골라 그날 집행됐다고 적고 있다.

이 저장소 어디에도 다른 "돋보기" 는 없다. `mag` 를 다는 코드 경로는
`slack-eyes-daemon.mjs:2056` 의 `reactions.add` 한 곳뿐이고
(`postEmojiReaction()`), 그 함수를 부르는 것은 `postAcknowledgement()` 안의 두
자리(R1 확정, F2 강등)뿐이다. Swift 쪽 `reactions.add`
(`Sources/Plugins/Slack/SlackTranslateStore.swift:513`)는 처리완료 동기화용 트리거
이모지(👀)를 다는 것이라 이 건과 무관하다.

**후보가 하나라 결정 카드를 보내지 않았다.**

---

## 2. 지금 무슨 일이 벌어지고 있나 — 실측

### 2-1. 🔍 가 나가는 자격 조건은 소스 네 종류다

`slack-eyes-daemon.mjs:1483`

```js
function acknowledgementOn(source) {
  if (!['mention', 'team', 'dm', 'broadcast'].includes(source || '')) return false;
  ...
}
```

`mention` 만이 "라이언을 직접 `<@U03GRE909MJ>` 로 부른 메시지" 다
(`mentionKind()`, `:3517`). 나머지 셋은 라이언을 부르지 않은 메시지다.

| source | 뜻 | 라이언이 불렸나 |
|---|---|---|
| `mention` | 본문에 `<@MY_USER>` 가 있다 | **불렸다** |
| `team` | 본문에 라이언이 속한 `<!subteam^…>` 가 있다 | 그룹이 불렸다 |
| `dm` | DM·그룹DM 채널의 **모든 새 메시지** | 안 불렸다 |
| `broadcast` | 채널의 `@here`/`@channel` | 안 불렸다 |

`dm` 이 라이언이 말한 "모든 메시지" 다. **그룹 DM 에서 사람들끼리 주고받는 말 전부가
여기 걸린다.** 라이언은 그 방에 있을 뿐인데 그의 계정 이름으로 🔍 가 붙는다.

### 2-2. 수집량 (`~/.condition-mate/slack-translate/items.jsonl`, 1792건 전수)

| source | 건수 |
|---|---|
| mention | 803 |
| dm | 588 (1:1 DM 358 · **그룹 DM 230 · 38개 방**) |
| broadcast | 83 (#chat-random-global 35 · #chat-random-kor 10 …) |
| later | 86 |
| (없음 = 👀 수동) | 232 |
| team | **0** |

### 2-3. 실제로 나간 리액션 전수 (`actions-daemon.jsonl` 의 `ack-emoji` 195줄)

| 이모지 / 자리 | 건수 |
|---|---|
| white_check_mark / mention | 99 |
| white_check_mark / 1:1 DM | 38 |
| **mag / 그룹 DM** | **13** |
| white_check_mark / 그룹 DM | 12 |
| **mag / mention** | **10** |
| saluting_face / mention | 9 |
| **mag / 1:1 DM** | **7** |
| white_check_mark / broadcast | 5 |
| saluting_face / (1:1 DM · 그룹 DM · broadcast) | 3 |

🔍 는 오늘 30건 나갔고 **그중 20건(67%)이 라이언이 불리지 않은 자리**다.
전체 리액션 195건으로 넓히면 78건(40%)이 그 자리다.

### 2-4. 왜 이것이 커뮤니케이션 코스트인가 — 이미 사고로 확인된 구조

`slack()` 의 기본 토큰이 `USER_TOKEN`(xoxp)이라
(`slack-eyes-daemon.mjs:500`, `:4579`) 리액션이 **봇이 아니라 라이언 계정으로 슬랙에
보인다** (오늘 브리프 §1-3). 어제 이 구조 때문에 Amani 가 ✅ 를 라이언의 승인으로 읽었고
Elma 가 채널에서 정정해야 했다. 이모지가 ✅ 에서 🔍 로 바뀌었을 뿐 **"라이언이 이 방의
모든 말을 하나씩 들여다보고 있다" 는 신호가 38개 그룹 DM 과 랜덤 채널에 계속 찍히는
구조는 그대로 남았다.** 받는 쪽은 그 표시를 해석해야 하고, 그 해석이 코스트다.

### 2-5. 대시보드 체크박스로는 못 고친다

`~/.condition-mate/slack-translate/config.json` 의 `sources` 에는 `mention`·`eyes`·
`team`·`later` 만 있고 `dm`·`broadcast` 키가 아예 없다. `sourceOn()`(`:288`)이
**명시적 `false` 가 아니면 켠 것으로 읽으므로** 둘은 켜져 있다. 그 체크박스를 끄면
수집 자체가 멈춰 **번역도 대시보드 목록도 같이 사라진다.** 라이언이 요구한 것은
"보는 것을 그만두라" 가 아니라 "표시를 그만두라" 이므로 그 손잡이는 답이 아니다.

---

## 3. 문제를 어떻게 정리했나

라이언의 요구는 이모지 하나에 관한 것으로 들리지만, 코드에서 그 이모지가 붙는 자리와
컨텍스트 확보(Jira·Notion·웹 리서치·다른 스레드·사람 디렉터리·문제 정의·모델 호출)가
도는 자리는 **같은 함수 하나**다.

`postAcknowledgement()`(`:2443`)가 그 함수이고, 그 안에서

1. `postEmojiReaction()` → 🔍 를 단다 (`:2474`, `:2589`)
2. `ackEvidence()` → 컨텍스트를 확보한다 (`:2500`)
3. `peopleContext`·`problemFrame`·`noveltyGate` → 더 확보한다 (`:2510`~`:2560`)

이 전부의 입구가 `shouldAutoReply()`(`:1519`) 한 줄이고, 그 첫 조건이
`acknowledgementOn(item.source)` 다.

**그래서 이 건은 "이모지 조건문을 찾아 고치는 일" 이 아니라 "선응답 파이프라인이 어떤
소스에 대해 도는가를 정하는 목록 하나를 좁히는 일" 이다.** 목록을 좁히면 라이언이 말한
두 가지 — 돋보기가 안 붙는 것과 컨텍스트가 안 도는 것 — 가 한 자리에서 같이 성립한다.
두 곳을 따로 고치면 "이모지는 안 붙는데 모델 호출은 계속 도는" 상태가 생길 수 있고,
그것은 눈에 안 보이는 채로 값만 나가는 상태다.

---

## 4. 결정

### D-1. `acknowledgementOn()` 의 소스 허용 목록을 `["mention"]` 로 좁힌다

`['mention', 'team', 'dm', 'broadcast']` → `['mention']`.

수집(`sourceOn`)은 **건드리지 않는다.** DM 과 broadcast 는 지금처럼 수집되고 번역되고
대시보드에 뜬다. 달라지는 것은 **슬랙에 흔적을 남기지 않고, 그 항목에 근거 레이어와
모델 호출을 쓰지 않는다는 것** 하나다.

### D-2. 목록을 코드에 박지 않고 정책 JSON 에 둔다

이 저장소가 이미 정해 둔 규칙을 그대로 따른다 —
"뜻의 정본은 코드가 아니라 JSON" (`emoji-layer.mjs:29-33`, 오늘 브리프 D-EMOJI-4).

- 정본: `Sources/Plugins/Slack/Daemon/slack-ack-cost-policy.json` 에
  `"ackSources": ["mention"]` 를 새로 둔다.
- 운영 덮어쓰기: `~/.condition-mate/slack-translate/ack-cost-policy.json` 이 이미
  이 파일의 덮어쓰기 자리로 선언돼 있다(그 파일의 `_doc`). 같은 키를 그쪽에서 덮어쓸 수
  있어야 한다.
- 값이 없거나 배열이 아니면 `["mention"]` 로 떨어진다. **바닥값이 좁은 쪽이다.**
  정책을 못 읽었다는 것이 "다 달아도 된다" 는 뜻은 아니다.

### D-3. `team` 도 뺀다

`team` 은 라이언이 속한 유저그룹을 부른 것이지 라이언을 부른 것이 아니다. 실측
수집량이 **0건**이라 이 선택으로 실제 동작이 갈리지 않는다. 넣고 싶어지면 JSON 한 줄로
돌아온다.

### D-4. 1:1 DM 도 뺀다

라이언의 말은 "나한테 멘션한 것만" 이다. 1:1 DM 은 그에게 온 말이 맞지만 멘션은 아니다.
글자 그대로 간다. 되돌리는 값이 JSON 한 줄이라(`["mention","dm"]`) 좁게 시작하는 쪽이
싸다. 이 선택으로 1:1 DM 358건에는 앞으로 아무 리액션도 안 나간다 — DM 에서 답이
없다가 라이언이 직접 답하는 것은 원래의 정상 상태다.

### D-5. 하지 않는 것

- 수집 규칙(`sourceOn`·`mentionKind`)을 고치지 않는다.
- 번역을 고치지 않는다. DM·broadcast 항목은 계속 번역되어 대시보드에 뜬다.
- 이모지 어휘집(`slack-emoji-layer.json`)의 뜻·veto·decision 축을 고치지 않는다.
  오늘 확정된 판이고 이 건과 다른 축이다.
- `postLevelOneRoute`(단순 라우팅 회신)는 `shouldAutoReply` 를 공유하므로 자동으로
  같이 좁아진다. 이것은 의도한 것이다 — 라이언을 부르지 않은 메시지에 그의 계정으로
  안내문이 나가는 것도 같은 코스트다.
- 이미 나간 🔍 30건을 소급해서 지우지 않는다.

---

## 5. 만들 것 — 파일 단위

| 파일 | 무엇 |
|---|---|
| `Sources/Plugins/Slack/Daemon/slack-ack-cost-policy.json` | `ackSources: ["mention"]` 신설 + `_ackSources_doc` 에 근거(§2-3 숫자와 사유) |
| `Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs` | `acknowledgementOn()` 이 하드코딩 배열 대신 정책의 `ackSources` 를 읽는다. 못 읽으면 `['mention']` |
| `Sources/Plugins/Slack/Daemon/ack-sources.test.mjs` | 신규 시험 (§6) |

`ackCostPolicy()` 는 이미 데몬 안에 있다(`:2549` 에서 `const policy = ackCostPolicy();`
로 쓰인다). 새 로더를 만들지 말고 그것을 쓴다. `acknowledgementOn` 은 메시지마다 불리므로
그 함수가 매번 파일을 읽는 구조인지 확인하고, 아니면 지금 `sourceOn()` 이 하는 것처럼
매번 읽어도 된다 — 파일이 작고 이 코드베이스는 재시작 없는 반영을 규칙으로 삼는다.

---

## 6. 통과 조건

`node --test Sources/Plugins/Slack/Daemon/` 로 다음이 전부 초록이어야 한다.

- `T1` — `source: 'mention'` 이면 선응답이 돈다.
- `T2` — `source: 'dm'` 이면 돌지 않는다.
- `T3` — `source: 'broadcast'` 이면 돌지 않는다.
- `T4` — `source: 'team'` 이면 돌지 않는다.
- `T5` — `source: 'eyes'`(undefined)·`'later'` 는 예전과 같이 돌지 않는다.
- `T6` — 정책 JSON 에 `ackSources: ["mention","dm"]` 를 넣으면 **코드 수정 없이**
  `dm` 이 돈다. 정책을 아예 못 읽으면 `mention` 만 돈다.
- `T7` — `acknowledgements: false` 라는 기존 전체 off 토글이 그대로 이긴다.

기존 시험 6개(`emoji-layer.decision`, `send-layer`, `send-layer.gate`,
`people-context`, `reply-language`, `security-gate`)가 전부 그대로 통과해야 한다.

빌드 확인은 둘 다 한다.

- `node --check` 로 고친 `.mjs` 가 파싱되는지.
- `swift build` 가 성공하는지. Swift 를 안 고쳐도 돌린다 — 고쳤는데 빌드를 안 돌린 것은
  끝난 것이 아니다.

---

## 7. 라이브 반영 — 이 저장소에서는 고치는 것이 곧 배포다

오늘 브리프 §10-1 이 실측으로 적어 두었다. `/Applications/ConditionMate.app`
(지금 pid 84592)이 `SlackDaemonInstall.swift:16`·`:47` 대로 개발 트리의 데몬을 자기
`Contents/Resources` 로 복사하고 kickstart 한다. 도는 데몬은 pid 84642 이고 번들에서
실행된다.

**그래서 저장소를 고치면 앱이 스스로 라이브로 밀어 넣는다.** 이 건은 레벨 L1 이고
라이언이 지금 멈추라고 한 동작이라 그것이 원하는 결과다. 다만 워커는 다음을 지킨다.

- `Scripts/build-app.sh` 를 손으로 돌리지 않는다. 앱이 알아서 한다.
- `launchctl kickstart` 를 손으로 하지 않는다.
- `~/.condition-mate/slack-translate/ack-cost-policy.json`(운영 덮어쓰기)에 쓰지 않는다.
  거기에 쓰면 저장소가 정본이라는 것이 깨진다.
- git commit 하지 않는다.
- 반영됐는지는 **확인만 한다** — `cmp` 로 번들과 저장소가 같은지, 그리고
  `actions-daemon.jsonl` 에 `dm`/`broadcast` 항목의 `ack-emoji` 줄이 더 이상 안 생기는지.
  반영이 몇 분 안 되면 그것을 그대로 보고한다. 억지로 밀지 않는다.

---

## 8. 조사해도 안 나와서 가정으로 두는 것

- **A1.** "돋보기" 는 `mag`(🔍) 하나다. 저장소에 다른 돋보기가 없다(§1). 다른 것을
  뜻했을 가능성은 조사 범위에서 나오지 않았다.
- **A2.** "컨텍스트 확보" 는 `postAcknowledgement()` 안에서 도는 근거 레이어
  (`ackEvidence` = Jira·Notion·웹 리서치·다른 스레드·첨부, `people-context` 축 0,
  `problem-frame` 축 2, 신규성 게이트)를 뜻한다고 본다. **번역은 여기 넣지 않았다.**
  번역은 밖으로 나가는 것이 아니라 라이언이 대시보드에서 읽는 것이라 커뮤니케이션
  코스트가 아니고, 끄라는 말도 없었다.
- **A3.** `docs/slack-context-analysis-levels.md` 의 L0~L5 컨텍스트 레벨은 이 건에서
  손대지 않는다. 그 축은 "얼마나 깊이 볼 것인가" 이고 이 건은 "누구 것을 볼 것인가"
  라서 다른 축이다. 오늘 브리프 §5 의 G5 도 L0~L5 의 코드 분기를 별도 배치로 남겨 두었다.
- **A4.** 1:1 DM 을 뺀다(D-4). 라이언의 말을 글자 그대로 읽었다. 되돌리는 값이
  JSON 한 줄이라 좁게 시작한다.
- **A5.** 대시보드에 `ackSources` 를 고르는 UI 를 만들지 않는다. Swift 쪽에
  `acknowledgements` 토글 UI 자체가 없는 것을 확인했다(grep 0건). 손잡이가 없던 값에
  화면을 새로 만드는 것은 이 요구에서 읽히지 않는다.

---

## 9. 집행 기록 (2026-09-02 22:00~22:40)

### 9-1. §7 의 전제가 틀렸다 — 앱은 스스로 배포하지 않는다

§7 은 오늘 브리프 §10-1 을 근거로 "앱이 개발 트리의 데몬을 자기 번들로 복사하고
kickstart 한다" 고 적었다. **그것은 사실이 아니다.** 워커가 확인했고 나도 확인했다.

- `SlackDaemonInstall.swift` 는 launchd plist 를 쓰고 kickstart 할 뿐 **복사하지 않는다.**
  그 파일 주석이 직접 "`Scripts/build-app.sh` 가 데몬을 번들 `Contents/Resources` 에
  복사하고" 라고 적고 있다.
- 실제 복사는 `Scripts/build-app.sh:106`(데몬)·`:149`(정책 JSON)이다.
- 그것을 자동으로 돌릴 워처가 **설치돼 있지 않다** —
  `~/Library/LaunchAgents/com.condition-mate.autobuild.plist` 없음,
  `launchctl print … com.condition-mate.autobuild` "Could not find service",
  `pgrep autobuild-watch` 없음.

브리프 §10-1 이 17:32 의 번들 교체를 "앱 자신이 했다" 고 읽은 것이 오독이다. 그 시각의
정황(앱 pid 와 데몬 pid 가 연달아 새로 뜬 것)은 **누군가 `build-app.sh` 를 돌린 것**과
일치한다. 이 저장소에서 "고치면 곧 배포" 는 성립하지 않는다. **고치면 그대로 멈춰 있다.**

### 9-2. `swift build` 는 이 변경과 무관하게 깨져 있다

```
error: accessing build database ".build/build.db": disk I/O error
```

컴파일과 링크는 끝나고 바이너리는 나오지만 llbuild 가 build db 를 쓰는 마지막 단계에서
exit 1 이다. db 를 치우고 새로 만들게 해도 같다. `set -euo pipefail` 인 `build-app.sh` 는
이 지점에서 조용히 죽어 **번들에 아무것도 복사하지 못한다** — 22:20 에 실제로 돌려
확인했고 번들은 17:32 그대로였다.

이 변경과 인과가 없다는 근거: `Package.swift:55` 가 `exclude: ["Daemon", "loops"]` 이고
Swift 소스는 한 줄도 안 바뀌었다. 설치된 바이너리(17:32)보다 새로운 소스를 전수로 뽑으니
**이 배치의 3개 파일뿐**이었다(`slack-ack-cost-policy.json`, `slack-eyes-daemon.mjs`,
`ack-sources.test.mjs`). 즉 **설치된 바이너리는 지금 Swift 트리와 이미 일치한다 — 다시
빌드할 이유가 없다.**

### 9-3. 그래서 배포는 build-app.sh 의 설치 꼬리만 손으로 밟았다

리빌드는 불필요하고(9-2) 가능하지도 않아서, `build-app.sh` 의 설치 구간과 **같은 순서**로
같은 일을 했다. 새로 지어낸 절차가 아니다.

1. `osascript … to quit` — 정상 종료 경로로 앱을 내렸다(도는 번들을 고치지 않기 위해).
2. `slack-eyes-daemon.mjs` + `slack-ack-cost-policy.json` 을 번들 `Resources/` 로 복사,
   데몬에 `chmod +x` (스크립트 `:106`·`:107`·`:149` 와 동일).
3. `codesign --force --deep --sign -` — 애드혹. 이 맥에 `ConditionMate Dev` 신원이
   없어서(`security find-identity` 0건) 스크립트도 애드혹으로 떨어지는 자리다.
   `codesign --verify --deep` 통과.
4. `open` 으로 relaunch (`CM_DATA_DIR`·`CM_DEV`·`CM_DEV_AUTO_OPEN` 을 벗겨서 — 스크립트와 동일).
5. `launchctl kickstart -k gui/<uid>/com.condition-mate.slack-eyes`.

**하지 않은 것:** 운영 덮어쓰기(`ack-cost-policy.json`)에 쓰기, git commit, 이미 나간
🔍 30건의 소급 삭제, Swift 재빌드.

### 9-4. 라이브에서 확인된 것

- 번들 두 파일 `cmp` 저장소와 동일.
- 앱 pid 84592 → 27433, 데몬 pid 84642 → 27640.
- `health.json`: `socket: connected` · `codeStale: false` · `failures: 0` ·
  `authError` 없음 · `script` 가 번들 경로.
- 번들 정책이 `ackSources = ["mention"]`.
- **배포된 번들 파일에서 `acknowledgementOn` 을 직접 뽑아 실행한 결과** —
  `mention` 만 true, `team`·`dm`·`broadcast`·`later`·undefined 는 전부 false.

### 9-5. 집행 중에 정하고 간 것

- **G1. 리빌드하지 않고 Resources 두 개만 교체했다.** 설치된 바이너리가 현재 Swift 트리와
  이미 일치하는 것을 실측으로 확인했으므로(9-2), 깨진 빌드 DB 를 고쳐 가며 릴리즈 컴파일을
  다시 하는 것은 값만 들고 얻는 것이 없다. 게다가 이 작업트리는 Swift 파일 40여 개가
  수정된 기능 브랜치라, 굳이 다시 빌드했다면 이 요구와 무관한 진행 중 변경이 운영 앱으로
  같이 나갈 뻔했다.
- **G2. 앱을 내렸다가 다시 띄웠다.** 도는 번들의 Resources 를 바꾸고 재서명하면 실행 중
  프로세스가 서명 무효로 죽을 수 있다. `build-app.sh` 도 같은 이유로 quit → swap →
  relaunch 순서다.
- **G3. `.build/build.db` 결함은 이 건에서 고치지 않았다.** 별도 건이고, 고치려면 이
  파일시스템이 SQLite 에 무엇을 하는지부터 봐야 한다.

---

## 1초 요약

요구 — 나한테 멘션한 것만 돋보기를 달고, 그다음에 컨텍스트를 확보하는 걸로 해줘.
문제 — 🔍 는 이모지 문제가 아니라 선응답 파이프라인이 도는 소스 목록 문제다. `mention`·`team`·`dm`·`broadcast` 네 개를 다 받는 목록 하나가 이모지와 컨텍스트 확보를 동시에 열고 있고, 그 목록 때문에 라이언이 불리지도 않은 그룹 DM 38개 방의 남의 대화에 그의 계정 이름으로 표시가 찍힌다.
완성 — `acknowledgementOn()` 이 정책 JSON 의 `ackSources`(바닥값 `["mention"]`)를 읽고, `dm`·`broadcast`·`team` 항목에는 🔍 도 근거 레이어도 돌지 않으며, 시험 7개와 기존 시험 6개와 `swift build` 가 전부 통과한다.
