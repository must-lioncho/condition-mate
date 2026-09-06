# 조사 보고 — 슬랙 공용 루프의 "어제 9개"가 무엇을 센 숫자인가

- 작성 2026-09-04 · 워커 lion-condition-mate-worker-slack-corpus-analyst · 레벨 L1
- 지시서 `issue/2026-09-04-slack-loop-9-vs-100-directive.md`
- 조사는 전부 읽기 전용이다. 프로덕션 파일과 데이터 파일 어느 것도 고치지 않았다.
- 스냅샷 시각 **2026-09-04 13:56 IST**. 그때의 크기:
  `items.jsonl` 1,922줄 · `actions-daemon.jsonl` 12,328줄 · `sessions.json` 1,901행.
  데몬이 지금도 쓰고 있으므로 다시 돌리면 뒤가 자란다. 09-03 이전 구간은 자라지 않는다.

---

## 0. 결론 세 줄

1. **`9` 는 정확하다. 다만 메시지를 센 숫자가 아니다.** `9 · 204,695 토큰 · $0.4910` 을
   스크린샷의 `9개 · 204.7K · $0.49` 와 소수점까지 재현했다. 이것은 "선언된 접두어와
   첫 프롬프트가 맞아떨어진 Claude CLI 세션" 의 개수다. 75건의 메시지를 묶은 배치가 아니다.
2. **같은 날 같은 데몬이 연 세션 26개 중 17개가 어느 루프에도 안 붙었다.** 세션 17개 ·
   392,118 토큰 · **$0.9490** 이 이름 없이 샜다. 비용 기준 귀속률 **34.1%**.
3. **그리고 지시서가 잡지 못한 것이 하나 더 있다 — 축 C 와 축 D 는 배타가 아니다.**
   09-03 의 haiku `model.usage` 25건은 그날 CLI 세션 26개 중 25개와 **1:1 같은 호출**이다.
   두 원장이 같은 API 호출을 서로 다른 가격표로 두 번 적고 있다
   (세션원장 596,813토큰 $1.4400 ↔ 데몬원장 839,184토큰 $1.1357). 두 값을 더하면 안 된다.

---

## 1. 하루 경계를 무엇으로 잘랐는가 — 먼저 정하고 시작한다

`~/.condition-mate/settings.json` 의 `"cm.timeZone": "system"` →
`Settings.displayTimeZone == TimeZone.current`(`Settings.swift:613-617`) → 이 맥의
`/etc/localtime` 은 **Asia/Kolkata (UTC+5:30)** 다. `sessions.json` 의
`days`/`firstDay`/`lastDay` 키는 이미 그 존으로 잘려 디스크에 박혀 있고
(`AppDelegate.swift:4657-4660` 이 `dayFmt.timeZone = Settings.shared.displayTimeZone` 으로
자른다), 대시보드 JS 의 `sledDay()` 도 브라우저 로컬을 쓴다. 그러므로 **네 축을 전부
Asia/Kolkata 로 자른다.** 다른 존으로 자르면 축 A·B·C 만 움직이고 축 D 는 안 움직여서
비교 자체가 성립하지 않는다.

민감도(같은 스크립트에 `--tz Asia/Seoul`):

| | Asia/Kolkata (앱 기준) | Asia/Seoul |
|---|---|---|
| 09-03 메시지 | **75** | 84 |
| 09-03 `model.usage` | **192건 · $1.1743** | 199건 · $1.1765 |
| 09-03 대시보드 세션 | **9개 · 204,695 · $0.4910** | 9개 · 204,695 · $0.4910 (안 움직임) |

축 D 가 안 움직이는 것 자체가 계측의 성질이다 — 날짜가 디스크에 이미 구워져 있어
조회 시점에 다시 자를 수 없다.

---

## 2. 2026-09-03 네 축 대응표

| 축 | 값 | 파일 | 필드 · 판정 조건 |
|---|---|---|---|
| **A 메시지** | **75** | `~/.condition-mate/slack-translate/items.jsonl` | 1줄 = 1건. `ts`(슬랙 발화 시각, epoch 문자열)를 IST 로 잘라 `2026-09-03` 인 줄. 수집 시각 `reactedAt` 이 아니다 |
| A-1 출처 | mention 47 · dm 18 · broadcast 9 · 미기재 1 | 같은 파일 | `source` |
| A-2 번역 담당 | gemini-flash-lite 66 · haiku 8 · level1-router 1 | 같은 파일 | `model` |
| A-3 백로그 | 193 (전 기간) | 같은 파일 | `backlogClosedAt` 존재. `SlackTranslateContent.swift:2039-2041` 의 `백로그` 와 같은 정의 |
| A-4 전체 | 1,922 (스냅샷 시각) | 같은 파일 | 그 순간 로드된 줄 수. 스크린샷의 `1874` 는 그때의 줄 수다. 계속 자란다 |
| **B 처리 묶음** | **collect 75 · translate 75** | `~/.condition-mate/slack-translate/actions-daemon.jsonl` | `at` 를 IST 로 자르고 `action`. `collect` 실패 0, `translate` 실패 1 (`ok!=true`) |
| B-1 후속 동작 | auto.done 52 · ack-emoji 42 · media 31 · ack.grade 24 · retrigger 7 · route.level1 1 | 같은 파일 | `action` |
| B-2 translate 라우팅 | gemini-flash-lite 65 · haiku 9 · level1-router 1 | 같은 파일 | `detail` 의 `·` 앞 토막 |
| **C 모델 호출** | **192건 · 1,133,591 토큰 · $1.1743** | 같은 파일, `action=="model.usage"` | `model` · `total_tokens` · `cost_usd` |
| C-1 | gemini-flash-lite-latest 167건 · 294,407 · $0.0386 | 〃 | 〃 |
| C-2 | claude-haiku-4-5-20251001 25건 · 839,184 · $1.1357 | 〃 | 〃 |
| **D CLI 세션** | **화면에 찍힌 9개 · 204,695 토큰 · $0.4910** | `~/.condition-mate/loop-sessions/sessions.json` | `prompt` 가 루프 선언의 `sessionSignatures` 중 하나로 **시작**하고(`LoopSessionLedger.swift:386-393`), `lastDay`(없으면 `startTS`)가 09-03. 토큰·달러는 `days["2026-09-03"]` 합 (`LoopEngineeringContent.swift:345-349`) |
| D-1 그날 데몬이 연 세션 전부 | **26개 · 596,813 토큰 · $1.4400** | 같은 파일 | `proj=="slack-translate"`(= `cwd` 꼬리, 데몬이 `cwd: OUT_DIR` 로 CLI 를 띄운다) 이고 `startTS` 가 09-03 |
| D-2 안 붙은 것 | **17개 · 392,118 토큰 · $0.9490** | 같은 파일 | D-1 에서 D 를 뺀 것 |

### 축이 서로 어떻게 붙는가

```
슬랙 메시지 75건 (축 A)
   └─ collect 75 / translate 75 (축 B)          ← 1 메시지 = 1 collect = 1 translate. 거의 정확히 1:1
        ├─ gemini 직접 API 65건 ──────────────┐
        ├─ level1-router 1건                   ├─ 축 C model.usage 192건
        └─ haiku = claude CLI 9건 ─────┐       │   (gemini 167 · haiku 25)
                                       │       │
   다른 층들도 같은 CLI 를 쓴다:         │       │
        emoji-layer / answer-context /  │       │
        problem-frame / alignment       ├───────┴──▶ 축 D CLI 세션 26개
        = 17건                          │             (그중 9개만 루프에 붙음)
                                        └─ 축 C 의 haiku 25건 ≡ 축 D 의 25개 (같은 호출)
```

- **A ↔ B 는 1:1 이다.** 75 = 75 = 75. 수집 손실 0.
- **B ↔ C 는 1:다 이다.** 메시지 1건이 여러 층을 거치며 모델을 여러 번 부른다. 75건이
  192호출이 됐다.
- **C ↔ D 는 배타가 아니라 겹친다.** 아래 4절.
- **A ↔ D 는 직접 대응이 없다.** 9는 75의 배치가 아니다. 75건 중 haiku 로 번역된 9건이
  우연히 같은 수인데, 그 9개 세션이 곧 그 9건의 번역이다 — 배치가 아니라 1:1이다.
  나머지 66건은 세션을 아예 열지 않아 축 D 에 들어올 길이 없다.

---

## 3. 판정 — `9` 는 배치 집계인가 집계 누락인가

**한 단어로는 답이 안 된다. 셋으로 갈린다.**

### (가) 무엇에 대해서는 정상인가

`9` 는 자기가 세겠다고 선언한 것을 정확히 셌다. 루프 선언
`Sources/Plugins/Slack/loops/index.md:17-22` 의 `sessionSignatures` 네 줄과 첫 프롬프트가
접두어로 일치한 CLI 세션이 09-03 에 정확히 9개였고, 아홉 개 전부 두 번째 줄
`"다음 슬랙 메시지를 세 단계로 처리하라. 목표 언어: 한국어."` 에 걸렸다.

```
502b7ad7 12:54:41  22,905  $0.0494      cb2cd58f 14:05:22  26,493  $0.0642
90033cd8 12:58:26  25,007  $0.0581      d7de2017 14:23:17  26,958  $0.0675
a8ede383 13:46:03       0  $0.0000      7eb6e384 14:32:42  26,379  $0.0649
6a5ae5da 13:54:03  25,616  $0.0633      77534b8f 14:59:59  26,741  $0.0652
                                        90a13b47 15:34:22  24,596  $0.0584
                                        ────────────────────────────────────
                                        9개 · 204,695 토큰 · $0.4910
```

`a8ede383` 은 세션이 열렸으나 토큰을 한 줄도 기록하지 못했다(`turns=0`). 그래서
**개수는 9이고 토큰 합은 8개분**이다. 화면에 9로 나오는 이유는 대시보드 JS 가
`r.day || sledDay(r.start*1000)` 로 `lastDay` 가 빈 세션을 `startTS` 로 떨어뜨리기
때문이다(`LoopEngineeringContent.swift:346`). 이 폴백을 빼고 세면 8이 나온다 —
처음에 나도 8을 냈고, JS 를 한 글자씩 다시 읽고서야 9가 됐다.

### (나) 무엇에 대해서는 배치가 아닌가

**배치 집계가 아니다.** 배치라면 75를 9묶음으로 나눈 흔적이 있어야 하는데 없다.
9개 세션은 각각 `turns=1` 짜리 단발 `claude -p` 호출이고, 각각 슬랙 메시지 **한 건**을
번역했다. 12:54:41 세션 ↔ 12:54:54 `translate D03GL66BWBX:1788420272` 처럼 1:1로 붙는다.
즉 9는 "75건을 9묶음으로 처리했다" 가 아니라 "75건 중 9건만 이 경로로 갔다" 이고,
나머지 66건은 Gemini 직접 API 로 가서 세션을 열지 않았다.

### (다) 무엇에 대해서는 누락인가

셋 다 누락이다.

1. **귀속 누락 (선언이 코드를 못 따라감).** 같은 날 같은 데몬이 같은 `translateClaude()`
   로 연 세션 26개 중 17개가 어느 루프에도 안 붙었다. 붙지 않은 이유는 하나뿐이다 —
   그 17개의 첫 프롬프트가 선언의 네 줄 중 어느 것으로도 시작하지 않는다. 데몬에 층이
   네 개 늘었는데 선언은 그대로였다.
2. **축 누락 (Gemini 는 이 화면에 들어올 길이 없다).** 09-03 의 167건 gemini 호출은
   세션을 열지 않으므로 세션 축에 원리상 못 들어온다. 이 화면은 루프 비용의
   세션 부분만 보여 주면서 그 사실을 밝히지 않는다. 데몬의 192건은 루프 카드의
   `usageTotals` 패널(`LoopDefinitionStore.swift:128-129`, 31일 컷오프)에는 뜨지만
   **토큰 대시보드의 날짜 필터가 거기에는 걸리지 않는다.** 두 숫자는 다른 화면에 있고
   다른 기간을 본다.
3. **계측 누락 (원장 자체가 없던 구간).** `model.usage` 의 첫 줄은
   **2026-08-30 00:39:45 IST** 다. 그전 구간(08-28 129건, 08-29 56건 번역)은 어느
   원장에도 토큰이 없다. 그 이틀의 루프 비용은 "0" 이 아니라 "모른다" 다.

---

## 4. 지시서가 못 잡은 발견 — 축 C 와 축 D 는 같은 호출을 두 번 센다

`Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs:1457-1489` 의 `translateClaude()` 는
`claude --model claude-haiku-4-5-20251001 --output-format json -p <prompt>` 를
`cwd: OUT_DIR`(=`~/.condition-mate/slack-translate`)로 띄운다. 그 한 번의 실행이
두 군데에 흔적을 남긴다.

- `claude` CLI 가 `~/.claude/projects/-Users-lioncho--condition-mate-slack-translate/*.jsonl`
  에 트랜스크립트를 쓴다 → `sessions.json` 의 한 행 (축 D)
- 데몬이 같은 응답 봉투의 `usage` 로 `act('model.usage', …)` 한 줄을 쓴다 (축 C)

09-03 의 haiku `model.usage` 25건과 그날 CLI 세션 26개를 시각으로 1:1 짝지은 결과
**25쌍이 전부 붙었고 짝 못 지은 usage 는 0건**이다. 짝이 없는 세션은
`a8ede383`(토큰 0) 하나뿐이다. 지연은 대부분 0~1초다.

```
세션 12:54:41~12:54:53  22,905tok $0.0494   ↔  usage 12:54:54  31,818tok $0.0354
세션 12:58:26~12:58:50  25,007tok $0.0581   ↔  usage 12:58:51  33,920tok $0.0435
세션 14:05:38~14:06:35  27,749tok $0.0749   ↔  usage 14:06:37  36,662tok $0.0614
…  (25쌍 전부)
합계  596,813tok $1.4400                    ↔        839,184tok $1.1357
```

같은 호출인데 값이 다른 이유는 가격표와 토큰 정의가 다르기 때문이다. 데몬은
`slack-eyes-daemon.mjs:461` 의 `{in: 1.00, out: 5.00}` 한 장으로 매기고 캐시 구분이
없다. Swift 추출기는 캐시 생성 5m/1h 배율을 갈라 매긴다(`AppDelegate.swift:4736-4748`).

**그래서 "이 루프가 09-03 에 얼마 썼나" 에 답할 때 $1.1743 + $1.4400 = $2.61 로
더하면 안 된다.** 중복을 뺀 값은 계산 기준에 따라 둘 중 하나다.

| 기준 | 09-03 이 루프의 총비용 |
|---|---|
| 세션원장 가격표 (26개 CLI) + 데몬 gemini($0.0386) | **$1.4786** |
| 데몬원장 가격표 (haiku 25 + gemini 167) | **$1.1743** |

두 값의 차 $0.30 은 가격표 차이지 누락이 아니다. 지금 화면이 보여 주는 $0.49 는
어느 쪽 기준으로도 **총비용의 33~42% 에 불과하다.**

---

## 5. 누락분 — 세션 개수 · 토큰 · 달러

### 2026-09-03

| 항목 | 세션 | 토큰 | 달러 |
|---|---:|---:|---:|
| 화면에 잡힌 것 (`9개 · 204.7K · $0.49`) | 9 | 204,695 | $0.4910 |
| **귀속 안 된 것 (같은 데몬이 연 세션)** | **17** | **392,118** | **$0.9490** |
| 그날 데몬 CLI 세션 합계 | 26 | 596,813 | $1.4400 |
| 비용 귀속률 | | | **34.1%** |
| 추가로, 세션 축에 원리상 안 들어오는 gemini 직접 호출 | (세션 없음) | 294,407 | $0.0386 |

귀속 안 된 17개의 내역:

| 건 | 토큰 | 달러 | 첫 프롬프트 | 어디가 여는가 |
|---:|---:|---:|---|---|
| 5 | 107,236 | $0.2304 | `아래 Slack 메시지가 요구하는 일을 실제로 처리하려면…` | `answer-context.mjs:432` |
| 4 | 106,590 | $0.2756 | `아래 Slack 메시지에 글로 답할 것이 있는지, 아니면 리액션 이모지…` | `emoji-layer.mjs:406` |
| 4 | 101,167 | $0.2389 | `나는 응답의 분량을 깎는 에이전트다…` | `alignment-engine.mjs:59` |
| 4 | 77,125 | $0.2040 | `나는 물음의 모양을 보는 에이전트다…` | `problem-frame.mjs:35` |
| **17** | **392,118** | **$0.9490** | | |

스크린샷 둘째 행의 `5개` 는 첫 줄(`answer-context.mjs`)이다. 그것은 루프에 안 붙어
`candidate`(미등록 루프 후보)로 따로 떠 있었던 것이고, 화면이 그 사실을 이름으로
말해 주지 않았다.

### 전 기간 (누적)

| 항목 | 세션 | 토큰 | 달러 |
|---|---:|---:|---:|
| `proj==slack-translate` 세션 전체 | 218 | — | — |
| 그중 루프에 붙은 것 | 123 | — | — |
| **그중 안 붙은 것** | **95** | **779,639** | **$2.0923** |

---

## 6. 최근 7일 — 09-03 은 특이한 날이었는가

**그렇다. 두 가지 뜻에서 특이하다.**

| 날짜 | 메시지 | collect | translate | usage건 | usage$ | 세션 | 붙음 | 샌것 | 붙음tok | 붙음$ | 샌tok | 샌$ | 비용귀속률 | 화면표시 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2026-08-28 | 127 | 129 | 129 | 0 | $0.0000 | 0 | 0 | 0 | 0 | $0.0000 | 0 | $0.0000 | — | 0 |
| 2026-08-29 | 55 | 56 | 56 | 0 | $0.0000 | 2 | 2 | 0 | 42,494 | $0.0944 | 0 | $0.0000 | 100.0% | 2 |
| 2026-08-30 | 6 | 6 | 5 | 13 | $0.0000 | 0 | 0 | 0 | 0 | $0.0000 | 0 | $0.0000 | — | 0 |
| 2026-08-31 | 87 | 89 | 88 | 216 | $0.1451 | 2 | 1 | 1 | 26,927 | $0.0658 | 21,265 | $0.0489 | 57.4% | 1 |
| 2026-09-01 | 89 | 89 | 89 | 220 | $0.0429 | 0 | 0 | 0 | 0 | $0.0000 | 0 | $0.0000 | — | 0 |
| 2026-09-02 | 122 | 123 | 122 | 318 | $0.1008 | 1 | 1 | 0 | 22,712 | $0.0503 | 0 | $0.0000 | 100.0% | 1 |
| **2026-09-03** | **75** | **75** | **75** | **192** | **$1.1743** | **26** | **9** | **17** | **204,695** | **$0.4910** | **392,118** | **$0.9490** | **34.1%** | **9** |

읽는 법 셋.

1. **메시지 축은 09-03 이 평범하다. 오히려 적은 날이다.** 7일 중 75는 아래에서 셋째다
   (08-30 의 6, 08-29 의 55 다음). 08-28 은 127이었다. **라이언이 "어제 100개는 받았다"
   고 한 감각은 최근 일주일의 평균(80.1건/일)에 대해 맞다.** 09-03 이 특별히 적었던 것도
   아니고 수집이 샌 것도 아니다 — `collect` 75 = `translate` 75 = 메시지 75 로 손실 0이고,
   시간대 분포도 0시부터 21시까지 퍼져 있어 수집 중단 구간이 없다.
2. **세션 축은 09-03 이 극단적으로 튄다.** 그전 엿새의 CLI 세션은 하루 0~2개였는데
   09-03 하루에 26개다. 원인은 메시지가 늘어서가 아니라 **그날 haiku CLI 경로를 쓰는
   층이 한꺼번에 붙었기 때문**이다. 09-03 12:50 이전에는 CLI 세션이 0이고, 12:50:30
   부터 18:00:07 까지 5시간 반에 26개가 몰려 있다. 같은 창에서 usage$ 도 $0.10 대에서
   $1.17 로 뛴다.
3. **누락도 09-03 에 처음 크게 터졌다.** 08-31 에 1개(21,265토큰 $0.0489)가 한 번
   샜고, 09-03 에 17개($0.9490)가 샜다. 즉 **이것은 오래된 만성 누락이 아니라
   09-03 에 새 층들이 켜지면서 그날 생긴 구멍**이다. 라이언이 하필 09-03 을 보고
   이상하다고 느낀 것은 우연이 아니다.

곁가지로 **08-28·08-29 의 두 칸은 0이 아니라 "모른다"** 다. `model.usage` 원장이
08-30 00:39:45 에야 시작해서 그 이틀의 gemini 비용은 어디에도 없다. 화면은 그것을
$0.00 으로 그린다.

---

## 7. `sessionSignatures` 에 무엇을 더 적으면 무엇이 붙는가

**파일은 고치지 않았다.** 아래는 넣으면 무엇이 붙는지를 센 것이다.
판정은 `p.hasPrefix($0)` 접두어 일치이므로(`LoopSessionLedger.swift:388`),
접두어는 프롬프트 앞머리와 글자까지 같아야 한다.

| # | 후보 접두어 | 여는 자리 | 전 기간 건 | 전 기간 토큰 | 전 기간 $ | 09-03 건 | 09-03 토큰 | 09-03 $ | 다른 프로젝트 오염 |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | `아래 Slack 메시지가 요구하는 일을 실제로 처리하려면` | `answer-context.mjs:432` | 6 | 128,501 | $0.2792 | 5 | 107,236 | $0.2304 | 0 |
| 2 | `아래 Slack 메시지에 글로 답할 것이 있는지, 아니면 리액션 이모지` | `emoji-layer.mjs:406` | 4 | 106,590 | $0.2756 | 4 | 106,590 | $0.2756 | 0 |
| 3 | `나는 물음의 모양을 보는 에이전트다.` | `problem-frame.mjs:35` | 4 | 77,125 | $0.2040 | 4 | 77,125 | $0.2040 | 0 |
| 4 | `나는 응답의 분량을 깎는 에이전트다.` | `alignment-engine.mjs:59` | 4 | 101,167 | $0.2389 | 4 | 101,167 | $0.2389 | 0 |
| 5 | `You are parsing one Slack message from a team praise` | `slack-eyes-daemon.mjs:4577` (`HERO_AI_PROMPT`) | 77 | 366,256 | $1.0945 | 0 | 0 | $0.0000 | 0 |
| | **다섯 줄 전부** | | **95** | **779,639** | **$2.0923** | **17** | **392,118** | **$0.9490** | **0** |

읽는 법.

- **1~4 만 넣으면 09-03 의 누락 17개가 전부 붙는다.** 그날 화면은
  `9개 · 204.7K · $0.49` 에서 `26개 · 596.8K · $1.44` 가 된다. 잔여 누락 0.
- **5번은 성격이 다르다.** `HERO_AI_PROMPT` 는 #hero 채널 칭찬 파싱이고 번역·기본
  응답이 아니다. 같은 데몬이 같은 `translateClaude()` 로 돌리기 때문에 같은 폴더에
  세션이 쌓였을 뿐이다. 77개 전부 **2026-08-01** 자이고 09-03 에는 0건이다. 이 루프에
  붙이면 8월 1일 하루에 $1.09 가 소급해 얹힌다. **넣을지 말지는 "hero 파싱을 이 루프의
  일로 볼 것인가" 라는 정의 문제이지 계측 문제가 아니다.** 내 판단으로는 별도 루프
  선언으로 빼는 쪽이 맞고, 이 표는 그 선택의 값만 보여 준다.
- **다섯 후보 전부 다른 프로젝트를 오염시키지 않는다.** 전 코퍼스 1,901행에서 이 다섯
  접두어로 시작하는 세션은 100% `proj=="slack-translate"` 다. 사람이 연 세션을 루프
  비용으로 잘못 세는 위험은 0이다.
- **다섯 줄을 다 넣어도 `proj=="slack-translate"` 의 미귀속 잔여는 0이 된다.** 즉 이
  다섯이 전부다. 여섯 번째 후보는 없다.
- **다만 이것을 고쳐도 두 문제는 안 없어진다.** ① gemini 직접 호출 167건은 여전히
  세션 축에 안 들어온다. ② 4절의 이중 계상(같은 haiku 호출이 축 C·D 에 각각 한 줄)은
  오히려 커진다 — 붙는 세션이 9에서 26으로 늘면 데몬 원장과 겹치는 구간이 그만큼
  넓어진다. 이 두 가지는 선언이 아니라 화면 설계에서 갈라야 한다.

---

## 8. 가정 목록 — 조사해도 답이 안 나와 정하고 진행한 것

1. **"100개" 는 검증하지 않았다.** 슬랙 API 를 부르지 않았고 대응 원장도 없다. 체감값으로
   두고, 대신 **75가 설계대로 걸러진 결과인지**를 검증했다. 결과: 09-03 의 75건은
   mention 47 · dm 18 · broadcast 9 · 미기재 1 로, 루프 선언
   (`loops/index.md`, `"source": "MUST Company Slack · mention · DM · broadcast · 등록 채널"`)이
   담겠다고 한 범주 밖의 것이 하나도 없다. `collect` 실패 0, 중복 id 0, 시간대 공백 없음.
   **75는 설계대로 걸러진 결과다.** 75와 100의 차이는 라이언을 부르지 않은 채널 메시지이고,
   그것은 애초에 이 저장소의 대상이 아니다.
2. **"수집되지 않은 메시지가 몇 건인가" 는 현재 계측으로 답할 수 없다 — 결함이 아니라
   계측 공백이다.** 데몬은 건너뛴 메시지에 원장 줄을 남기지 않는다(`skip` 액션이 없다).
   전 원장 12,328줄의 `action` 값을 전수로 훑어 확인했다. 그러므로 "필터가 너무 빡빡한가"
   는 지금 디스크만으로는 답할 수 없고, 답하려면 데몬에 `skip` 계측을 넣어야 한다.
3. **하루 경계는 Asia/Kolkata 다.** 1절. 앱과 대시보드가 그렇게 자르기 때문이지, 라이언의
   생활 시간대라고 판단해서가 아니다. Asia/Seoul 로 자르면 메시지 축이 75→84 로 바뀐다.
4. **`proj=="slack-translate"` 를 "데몬이 연 세션" 의 정의로 썼다.** 근거는
   `slack-eyes-daemon.mjs:1465` 의 `cwd: OUT_DIR` 이고, `proj` 는 `cwd` 의 마지막 칸이다
   (`LoopSessionLedger.swift:239-243`). 사람이 그 디렉터리에서 세션을 열 수도 있지만,
   218개 전부의 첫 프롬프트를 훑어 사람 것으로 보이는 것은 없었다(전부 5개 기계 접두어
   또는 4개 선언 접두어로 시작한다).
5. **축 C↔D 짝짓기는 시각 근접으로 했다.** 두 원장에 공통 키가 없다(`model.usage` 의
   `id` 는 빈 문자열이다). 세션 종료 시각 기준 `[start-5s, end+30s]` 창 안의 usage 를
   차이가 작은 순으로 전역 그리디 배정했다. 실제 지연은 25쌍 모두 0~1초라 배정이
   흔들릴 여지가 없었다. **처음에 세션 순서대로 배정했을 때 13:46 대 두 세션의 짝이
   뒤바뀌었고, 전역 그리디로 바꿔 고쳤다.** 이 자리는 스크립트에 그대로 남겨 두었다.
6. **`a8ede383`(토큰 0)을 9에 포함했다.** 대시보드 JS 의 `r.day || sledDay(r.start*1000)`
   폴백을 그대로 재현한 결과다. 이 폴백을 빼면 8이 되고 화면과 어긋난다.

---

## 9. PO 실측치와의 대조 — 어긋난 자리

전부 독립 재현했다. **한 자리만 어긋났다.**

| 항목 | PO | 이 조사 | 판정 |
|---|---|---|---|
| 09-03 메시지 | 75 | 75 | 일치 |
| collect / translate | 75 / 75 (실패 0) | 75 / 75 (`translate` 실패 **1**) | 실패 건수만 어긋남 |
| 출처 내역 | mention 47 · dm 18 · broadcast 9 · 미기재 1 | 동일 | 일치 |
| `model.usage` | 192건 (gemini 167 · haiku 25) | 동일. 토큰·달러도 동일 | 일치 |
| 붙은 세션 | 9개 · 204,695 · $0.4910 | 동일 | 일치 |
| 안 붙은 세션 | 17개 · 392,118 · $0.9490 | 동일 | 일치 |
| 09-03 시작 세션 (proj=slack-translate) | 26개 | 26개 | 일치 |
| 백로그 / 전체 | 193 / 1921 | 193 / 1922 (스냅샷 시각 차) | 일치 |
| **09-03 번역 담당** | **gemini-flash-lite 65 · haiku 8 · level1-router 1** | **items.model 로는 66 · 8 · 1 / 원장 detail 로는 65 · 9 · 1** | **어긋남** |

**어긋난 것 자체가 발견이다.** PO 의 세 값은 합이 74 라서 75와 맞지 않는다. 두 다른
원장에서 한 값씩 집어 섞은 것으로 보인다. 실제로는 같은 하루를 두 자리가 다르게 적고 있다.

- `items.jsonl` 의 `model`: gemini-flash-lite **66** · haiku 8 · level1-router 1 = 75
- `actions-daemon.jsonl` 의 `translate` 줄 `detail`: gemini-flash-lite **65** · haiku **9** · level1-router 1 = 75

**한 건이 원장에서는 haiku 인데 아이템에는 gemini-flash-lite 로 적혀 있다.** 원장의
haiku 9건은 그날 CLI 세션 9개와 시각으로 정확히 1:1 붙으므로(3절 표), **원장 쪽이 맞고
`items.model` 한 건이 틀렸다.** 재번역이 일어나 나중 값이 앞 값을 덮었거나
(`retrigger` 가 그날 7건 있다), 폴백 경로에서 `model` 필드만 갱신되지 않았거나 둘 중
하나다. 1건이라 비용에 미치는 영향은 없지만, **"어느 모델이 얼마나 일했나" 를
`items.model` 로 세면 원장과 갈라진다**는 것은 지금 확인된 사실이다.

`translate` 실패 1건도 PO 는 0으로 적었다. `ok!=true` 한 줄이 실제로 있다.

---

## 10. 재현 스크립트 전문

경로: `/private/tmp/claude-501/…/scratchpad/slack_loop_audit.py`
(스크래치패드는 세션마다 사라진다. 아래 본문이 정본이고, 어디에 저장해 돌려도 같은 값이 나온다.)

실행:

```bash
python3 slack_loop_audit.py                                  # 09-03 기준 7일, Asia/Kolkata
python3 slack_loop_audit.py --day 2026-09-03 --tz Asia/Seoul # 타임존 민감도
```

의존성은 표준 라이브러리뿐이다(`zoneinfo` 는 Python 3.9+). 열기만 하고 쓰지 않는다.

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
slack-loop-9-vs-100 — 네 축 전수 조사 (읽기 전용, 아무것도 쓰지 않는다)

  A 메시지    ~/.condition-mate/slack-translate/items.jsonl          1줄 = 슬랙 메시지 1건, 날짜축 = ts
  B 처리묶음  ~/.condition-mate/slack-translate/actions-daemon.jsonl 1줄 = 데몬 동작 1건, 날짜축 = at
  C 모델호출  같은 파일 action=="model.usage"                        model / total_tokens / cost_usd
  D CLI세션   ~/.condition-mate/loop-sessions/sessions.json          1행 = 세션 1개

하루 경계 = 앱의 표시 타임존.
  ~/.condition-mate/settings.json 의 "cm.timeZone"=="system" → Settings.displayTimeZone == TimeZone.current
  이 맥의 /etc/localtime == Asia/Kolkata. sessions.json 의 days/firstDay/lastDay 키는 이미 그 존으로
  잘려 저장돼 있으므로 A·B·C 도 같은 존으로 잘라야 네 축이 같은 하루를 가리킨다.

  실행:  python3 slack_loop_audit.py                 # 09-03 기준 7일
         python3 slack_loop_audit.py --day 2026-09-03 --days 7 --tz Asia/Seoul
"""
import json, re, argparse, collections
from datetime import datetime
from zoneinfo import ZoneInfo

ITEMS    = "/Users/lioncho/.condition-mate/slack-translate/items.jsonl"
ACTIONS  = "/Users/lioncho/.condition-mate/slack-translate/actions-daemon.jsonl"
SESSIONS = "/Users/lioncho/.condition-mate/loop-sessions/sessions.json"
REGISTRY = ("/Users/lioncho/Work/lion_work/organization/lion/lion-condition-mate"
            "/Sources/ConditionMate/Plugins/Loop/loops/index.md")
SLACK_LOOP = "condition-mate-slack-shared-reply"
SLACK_PROJ = "slack-translate"     # 데몬이 여는 CLI 세션의 cwd 꼬리 (cwd=OUT_DIR)

ap = argparse.ArgumentParser()
ap.add_argument("--day", default="2026-09-03")
ap.add_argument("--days", type=int, default=7)
ap.add_argument("--tz", default="Asia/Kolkata")
A = ap.parse_args()
TZ = ZoneInfo(A.tz)
D = A.day

def day(epoch):
    return datetime.fromtimestamp(float(epoch), TZ).strftime("%Y-%m-%d")

_e = datetime.strptime(D, "%Y-%m-%d").toordinal()
WINDOW = [datetime.fromordinal(_e - i).strftime("%Y-%m-%d") for i in range(A.days - 1, -1, -1)]

# ═══ 축 A ════════════════════════════════════════════════════════════════════
items_total = items_parsefail = backlog_total = 0
items_by_day = collections.Counter()
items_src = collections.Counter()      # (day, source)
items_model = collections.Counter()    # (day, model)
items_hour = collections.defaultdict(collections.Counter)
items_id = collections.Counter()
for line in open(ITEMS, encoding="utf-8"):
    line = line.strip()
    if not line: continue
    items_total += 1
    try: it = json.loads(line)
    except Exception: items_parsefail += 1; continue
    items_id[it.get("id", "")] += 1
    if it.get("backlogClosedAt"): backlog_total += 1
    try: d = day(it["ts"])
    except Exception: continue
    items_by_day[d] += 1
    items_src[(d, it.get("source") or "<미기재>")] += 1
    items_model[(d, it.get("model") or "<없음>")] += 1
    items_hour[d][datetime.fromtimestamp(float(it["ts"]), TZ).hour] += 1

# ═══ 축 B·C ══════════════════════════════════════════════════════════════════
act_total = act_parsefail = 0
act_n = collections.Counter()          # (day, action)
act_bad = collections.Counter()
tr_model = collections.Counter()       # (day, translate detail 의 모델 이름)
usage_n = collections.Counter()        # (day, model)
usage_t = collections.Counter()
usage_c = collections.defaultdict(float)
usage_rows = []                        # 축 C↔D 겹침 대조용
for line in open(ACTIONS, encoding="utf-8"):
    line = line.strip()
    if not line: continue
    act_total += 1
    try: r = json.loads(line)
    except Exception: act_parsefail += 1; continue
    if r.get("at") is None: continue
    d = day(r["at"]); a = r.get("action", "")
    act_n[(d, a)] += 1
    if r.get("ok") is not True: act_bad[(d, a)] += 1
    if a == "translate":
        tr_model[(d, (r.get("detail") or "").split("·")[0].strip() or "<없음>")] += 1
    if a == "model.usage":
        m = r.get("model", "<없음>")
        usage_n[(d, m)] += 1
        usage_t[(d, m)] += int(r.get("total_tokens") or 0)
        usage_c[(d, m)] += float(r.get("cost_usd") or 0.0)
        usage_rows.append(r)

# ═══ 축 D — LoopSessionLedger.classifyAll() 재현 ═════════════════════════════
# Swift: Sources/ConditionMate/Plugins/Loop/LoopSessionLedger.swift:378-406
def registered_loops():
    """LoopDefinitionStore.routes()+definitions(). 등록표의 줄 순서를 지킨다 —
       Swift 의 loops.first(where:) 가 그 순서로 첫 일치를 고르기 때문이다."""
    routes = [s.strip()[2:].strip() for s in open(REGISTRY, encoding="utf-8").read().split("\n")
              if s.strip().startswith("- /")]
    out = []
    for route in routes:
        try: text = open(route, encoding="utf-8").read()
        except OSError: continue
        i = text.find("```json")
        if i < 0: continue
        j = text.find("```", i + 7)
        try: obj = json.loads(text[i + 7:j])
        except Exception: continue
        out.append({"id": obj.get("id", ""), "name": obj.get("name", ""),
                    "prefixes": obj.get("sessionSignatures") or [],
                    "skills": obj.get("sessionSkills") or [], "route": route})
    return out

BUILTIN = {"login","logout","model","compact","clear","help","init","resume","cost",
           "doctor","status","config","agents","review","memory","vim","terminal-setup"}
# Swift CharacterSet.whitespaces 는 개행을 포함하지 않는다. .strip() 을 쓰면 개행으로
# 시작하는 프롬프트가 Swift 와 다르게 판정되므로 공백·탭만 깎는다.
WS = " \t               　"

def slash_command(p):
    i = p.find("<command-name>")
    if i >= 0:
        tail = p[i+14:]; j = tail.find("</command-name>")
        if j < 0: return None
        return tail[:j].strip().strip("/") or None
    if not p.startswith("/"): return None
    rest = p[1:]; name = ""
    for ch in rest:
        if ch.isalpha() or ch.isdigit() or ch in "-_": name += ch
        else: break
    if rest[len(name):len(name)+1] == "/": return None   # 붙여넣은 절대경로는 커맨드가 아니다
    return name if len(name) >= 2 else None

def skill_name(p):
    M = "Base directory for this skill:"
    i = p.find(M)
    if i < 0: return None
    path = p[i+len(M):].lstrip().split(" ")[0].split("\n")[0]
    return path.rstrip("/").split("/")[-1] or None

def harness(p): return slash_command(p) or skill_name(p)
def signature(p): return re.sub(r"[0-9]", "#", re.sub(r"\s+", " ", p or "")).strip()[:60]

LOOPS = registered_loops()
rows = json.load(open(SESSIONS, encoding="utf-8"))

sig_n = collections.Counter(); sig_d = collections.defaultdict(set)
for r in rows:
    if r.get("prompt"):
        s = signature(r["prompt"]); sig_n[s] += 1
        if r.get("firstDay"): sig_d[s].add(r["firstDay"])

verdict = {}
for r in rows:
    p = (r.get("prompt") or "").strip(WS)
    if not p:
        verdict[r["sid"]] = ("human", "", "프롬프트 없음"); continue
    h = harness(p); hit = None
    for l in LOOPS:                                     # 1. 등록된 루프가 선언한 세션
        if any(p.startswith(x) for x in l["prefixes"]) or (h is not None and h in l["skills"]):
            if l["id"]: hit = l; break
    if hit: verdict[r["sid"]] = ("loop", hit["id"], hit["name"]); continue
    if h is not None and h not in BUILTIN:               # 2. 스킬·슬래시 하네스
        verdict[r["sid"]] = ("candidate", "", "/" + h); continue
    s = signature(p)                                    # 3. 3회 이상 · 2일 이상 반복 서명
    if sig_n[s] >= 3 and len(sig_d[s]) >= 2:
        verdict[r["sid"]] = ("candidate", "", p[:60]); continue
    verdict[r["sid"]] = ("human", "", "사람이 연 세션")  # 4. 나머지

# ═══ 대시보드 재현 ═══════════════════════════════════════════════════════════
# LoopEngineeringContent.swift:345-349 sledGroup()
#   세션 수  = runs 중 (r.day || sledDay(r.start*1000)) 가 구간에 드는 것의 개수
#              r.day 는 서버가 실은 lastDay 다 (LoopSessionLedger.swift:661)
#              토큰을 한 번도 안 쓴 세션은 lastDay 가 빈 문자열이라 start 로 떨어진다
#   토큰·달러 = days 맵에서 구간에 드는 날의 합 (그 세션에 lastDay 가 없으면 0 이 더해진다)
def dash(lo, hi, loop_id=SLACK_LOOP):
    n = t = 0; c = 0.0; picked = []
    for r in rows:
        if verdict[r["sid"]][1] != loop_id: continue
        d = r.get("lastDay") or (day(r["startTS"]) if r.get("startTS") else "")
        if d and lo <= d <= hi:
            n += 1; picked.append(r)
        for k, v in (r.get("days") or {}).items():
            if lo <= k <= hi: t += int(v.get("t") or 0); c += float(v.get("c") or 0.0)
    return n, t, c, picked

def started(d, proj=SLACK_PROJ):
    return [r for r in rows
            if r.get("startTS") and day(r["startTS"]) == d and (proj is None or r.get("proj") == proj)]

P = print
P("=" * 96)
P(f"타임존 {A.tz} · 기준일 {D} · 창 {WINDOW[0]} ~ {WINDOW[-1]}")
P("등록 루프: " + " / ".join(f"{l['id']}(sessionSignatures {len(l['prefixes'])}개, sessionSkills {len(l['skills'])}개)"
                            for l in LOOPS))
P("=" * 96)

P(f"\n[A] 메시지 — {ITEMS} · 필드 ts")
P(f"    총 줄 수 {items_total} · JSON 파싱 실패 {items_parsefail} · 중복 id {sum(v-1 for v in items_id.values() if v > 1)}")
P(f"    backlogClosedAt 보유 = 수집기 UI '백로그' = {backlog_total}")
P(f"    {D} 메시지 = {items_by_day[D]}")
P("      source: " + " · ".join(f"{s}={n}" for (d, s), n in sorted(items_src.items()) if d == D))
P("      items.model: " + " · ".join(f"{m}={n}" for (d, m), n in sorted(items_model.items(), key=lambda x: -x[1]) if d == D))
h = items_hour[D]
P("      시각대: " + " ".join(f"{x}시:{h[x]}" for x in range(24) if h[x]))
gaps = [g for g in "".join("." if h[x] else "X" for x in range(24)).split(".") if g]
P(f"      빈 시간대 {24-len(h)}개 · 연속 공백 최장 {max(map(len, gaps)) if gaps else 0}시간")

P(f"\n[B] 처리 묶음 — {ACTIONS} · 필드 at/action")
P(f"    총 줄 수 {act_total} · JSON 파싱 실패 {act_parsefail}")
for a in ["collect","translate","ack","ack-emoji","ack.grade","auto.done","retrigger","media",
          "route.level1","security.block","channelsub.failed-everyday"]:
    if act_n[(D, a)]: P(f"    {D} {a:26s} {act_n[(D,a)]:5d}  (ok!=true {act_bad[(D,a)]})")
P("    translate 의 detail 모델: " + " · ".join(f"{m}={n}" for (d, m), n in sorted(tr_model.items(), key=lambda x: -x[1]) if d == D))

P(f"\n[C] 모델 호출 — 같은 파일 action=model.usage · 필드 model/total_tokens/cost_usd")
tn = tt = 0; tc = 0.0
for (d, m), n in sorted(usage_n.items(), key=lambda x: -x[1]):
    if d != D: continue
    P(f"    {m:32s} {n:4d}건 · {usage_t[(d,m)]:>10,} 토큰 · ${usage_c[(d,m)]:.4f}")
    tn += n; tt += usage_t[(d, m)]; tc += usage_c[(d, m)]
P(f"    {'합계':32s} {tn:4d}건 · {tt:>10,} 토큰 · ${tc:.4f}")

P(f"\n[D] CLI 세션 — {SESSIONS} · 필드 prompt/proj/days/lastDay/startTS")
P(f"    원장 행 {len(rows)} · 그중 proj=={SLACK_PROJ} {sum(1 for r in rows if r.get('proj')==SLACK_PROJ)}")
n, t, c, picked = dash(D, D)
P(f"    ▶ 대시보드 재현 (기간 {D}~{D}) = {n}개 · {t:,} 토큰 · ${c:.4f}")
st = started(D); att = [r for r in st if verdict[r["sid"]][1] == SLACK_LOOP]
orp = [r for r in st if verdict[r["sid"]][1] != SLACK_LOOP]
P(f"    그날 데몬이 연 세션(startTS 기준, proj=={SLACK_PROJ}) = {len(st)}개 · "
  f"{sum(r['tokens'] for r in st):,} 토큰 · ${sum(r['costUSD'] for r in st):.4f}")
P(f"      붙은 것   {len(att):2d}개 · {sum(r['tokens'] for r in att):>7,} 토큰 · ${sum(r['costUSD'] for r in att):.4f}")
P(f"      안 붙은 것 {len(orp):2d}개 · {sum(r['tokens'] for r in orp):>7,} 토큰 · ${sum(r['costUSD'] for r in orp):.4f}")
g = collections.Counter()
for r in orp: g[(r.get("prompt") or "").strip(WS).replace("\n", " ")[:46]] += 1
for k, v in g.most_common(): P(f"        {v:3d}개  {k!r}")

# ═══ 축 C ↔ 축 D 겹침 — 같은 API 호출이 두 원장에 각각 한 줄씩 남는다 ═══════
# slack-eyes-daemon.mjs:1457-1489 translateClaude() 가 `claude --model haiku -p` 를
# cwd=OUT_DIR 로 띄우고, 그 CLI 가 자기 트랜스크립트를 ~/.claude/projects 에 남기는
# 동시에 데몬이 응답 봉투의 usage 로 model.usage 한 줄을 적는다. 두 축은 배타가 아니다.
#
# 두 원장에 공통 키가 없다(model.usage 의 id 는 빈 문자열). 그래서 시각으로 짝짓되,
# 세션 순서대로 그리디하게 배정하면 13:46 대의 두 세션처럼 시작이 1초 차인 쌍에서
# 짝이 뒤바뀐다. 차이가 작은 순으로 전역 정렬해 배정한다.
P(f"\n[C↔D] 겹침 — {D} 의 haiku model.usage 와 CLI 세션을 시각으로 1:1 짝짓기")
us = [r for r in usage_rows if day(r["at"]) == D and "haiku" in (r.get("model") or "")]
cand = []
for si, r in enumerate(st):
    s0, e0 = r["startTS"], (r.get("endTS") or r["startTS"])
    for ui, u in enumerate(us):
        if s0 - 5 <= u["at"] <= e0 + 30: cand.append((abs(u["at"] - e0), si, ui))
cand.sort()
us_of = {}; taken = set()
for _, si, ui in cand:
    if si in us_of or ui in taken: continue
    us_of[si] = ui; taken.add(ui)
P(f"    haiku model.usage {len(us)}건 · 그날 CLI 세션 {len(st)}개 · 짝지어진 쌍 {len(us_of)}")
P(f"    짝 못 지은 세션 {[st[i]['sid'][:8] for i in range(len(st)) if i not in us_of]}")
P(f"    짝 못 지은 usage {[datetime.fromtimestamp(us[i]['at'],TZ).strftime('%H:%M:%S') for i in range(len(us)) if i not in taken]}")
P(f"    같은 호출의 두 값: 세션원장 {sum(r['tokens'] for r in st):,} 토큰 ${sum(r['costUSD'] for r in st):.4f}"
  f"  ↔  데몬원장 {sum(u['total_tokens'] for u in us):,} 토큰 ${sum(u['cost_usd'] for u in us):.4f}")

# ═══ 7일치 ═══════════════════════════════════════════════════════════════════
P(f"\n[5] {WINDOW[0]} ~ {WINDOW[-1]} 하루씩")
P(f"  {'날짜':<11}{'msg':>5}{'collect':>8}{'transl':>7}{'usage':>6}{'usage$':>9}"
  f"{'세션':>5}{'붙음':>5}{'샌것':>5}{'붙음tok':>9}{'붙음$':>8}{'샌tok':>9}{'샌$':>8}{'귀속$%':>8}{'대시보드':>7}")
for d in WINDOW:
    dn, dt, dc, _ = dash(d, d)
    s2 = started(d)
    a2 = [r for r in s2 if verdict[r["sid"]][1] == SLACK_LOOP]
    o2 = [r for r in s2 if verdict[r["sid"]][1] != SLACK_LOOP]
    at_, ac_ = sum(r["tokens"] for r in a2), sum(r["costUSD"] for r in a2)
    ot_, oc_ = sum(r["tokens"] for r in o2), sum(r["costUSD"] for r in o2)
    un = sum(n for (x, m), n in usage_n.items() if x == d)
    uc = sum(v for (x, m), v in usage_c.items() if x == d)
    rate = ac_ / (ac_ + oc_) * 100 if (ac_ + oc_) else 0.0
    P(f"  {d:<11}{items_by_day[d]:>5}{act_n[(d,'collect')]:>8}{act_n[(d,'translate')]:>7}{un:>6}{uc:>9.4f}"
      f"{len(s2):>5}{len(a2):>5}{len(o2):>5}{at_:>9,}{ac_:>8.4f}{ot_:>9,}{oc_:>8.4f}{rate:>7.1f}%{dn:>7}")

# ═══ 6. sessionSignatures 후보 ═══════════════════════════════════════════════
P(f"\n[6] sessionSignatures 후보 — 지금 이 루프에 안 붙는 proj=={SLACK_PROJ} 세션")
un_all = [r for r in rows if r.get("proj") == SLACK_PROJ and verdict[r["sid"]][1] != SLACK_LOOP]
P(f"    대상 {len(un_all)}개 · {sum(r['tokens'] for r in un_all):,} 토큰 · ${sum(r['costUSD'] for r in un_all):.4f}")
CAND = [
    ("아래 Slack 메시지가 요구하는 일을 실제로 처리하려면", "answer-context.mjs:432"),
    ("아래 Slack 메시지에 글로 답할 것이 있는지, 아니면 리액션 이모지", "emoji-layer.mjs:406"),
    ("나는 물음의 모양을 보는 에이전트다.", "problem-frame.mjs:35"),
    ("나는 응답의 분량을 깎는 에이전트다.", "alignment-engine.mjs:59"),
    ("You are parsing one Slack message from a team praise", "slack-eyes-daemon.mjs:4577"),
]
P(f"  {'전체':>4}{'전체tok':>10}{'전체$':>9}  {D}: {'건':>3}{'tok':>9}{'$':>8}  {'타루프충돌':>7}  접두어 / 출처")
for pre, src in CAND:
    hits = [r for r in rows if (r.get("prompt") or "").strip(WS).startswith(pre)]
    dd = [r for r in hits if (r.get("lastDay") or (day(r["startTS"]) if r.get("startTS") else "")) == D]
    other = sum(1 for r in hits if r.get("proj") != SLACK_PROJ)
    P(f"  {len(hits):>4}{sum(r['tokens'] for r in hits):>10,}{sum(r['costUSD'] for r in hits):>9.4f}"
      f"      {len(dd):>3}{sum(r['tokens'] for r in dd):>9,}{sum(r['costUSD'] for r in dd):>8.4f}"
      f"  {other:>7}  {pre[:34]!r} ← {src}")
tot = [r for r in rows if any((r.get("prompt") or "").strip(WS).startswith(p) for p, _ in CAND)]
totd = [r for r in tot if (r.get("lastDay") or (day(r["startTS"]) if r.get("startTS") else "")) == D]
P(f"  다섯 줄을 모두 넣으면: 전체 +{len(tot)}개 +{sum(r['tokens'] for r in tot):,} 토큰 +${sum(r['costUSD'] for r in tot):.4f}"
  f" · {D} +{len(totd)}개 +{sum(r['tokens'] for r in totd):,} 토큰 +${sum(r['costUSD'] for r in totd):.4f}")
res = [r for r in un_all if not any((r.get("prompt") or "").strip(WS).startswith(p) for p, _ in CAND)]
P(f"  그래도 안 붙는 잔여: {len(res)}개 · {sum(r['tokens'] for r in res):,} 토큰 · ${sum(r['costUSD'] for r in res):.4f}")
for r in res[:10]:
    P(f"      {r['sid'][:8]} {r.get('firstDay','')} {r['tokens']:>7,} ${r['costUSD']:.4f} "
      f"{(r.get('prompt') or '').strip(WS).replace(chr(10),' ')[:60]!r}")
```

### 위 스크립트의 실제 출력 (2026-09-04 13:56 IST 스냅샷)

```
================================================================================================
타임존 Asia/Kolkata · 기준일 2026-09-03 · 창 2026-08-28 ~ 2026-09-03
등록 루프: condition-mate-slack-shared-reply(sessionSignatures 4개, sessionSkills 0개) / mustcompany-failed-everyday(sessionSignatures 2개, sessionSkills 0개)
================================================================================================

[A] 메시지 — /Users/lioncho/.condition-mate/slack-translate/items.jsonl · 필드 ts
    총 줄 수 1922 · JSON 파싱 실패 0 · 중복 id 0
    backlogClosedAt 보유 = 수집기 UI '백로그' = 193
    2026-09-03 메시지 = 75
      source: <미기재>=1 · broadcast=9 · dm=18 · mention=47
      items.model: gemini-flash-lite=66 · haiku=8 · level1-router=1
      시각대: 0시:1 6시:4 7시:5 8시:4 9시:10 10시:3 11시:3 12시:11 13시:6 14시:13 15시:5 17시:3 18시:3 19시:1 20시:1 21시:2
      빈 시간대 8개 · 연속 공백 최장 5시간

[B] 처리 묶음 — /Users/lioncho/.condition-mate/slack-translate/actions-daemon.jsonl · 필드 at/action
    총 줄 수 12328 · JSON 파싱 실패 0
    2026-09-03 collect                       75  (ok!=true 0)
    2026-09-03 translate                     75  (ok!=true 1)
    2026-09-03 ack-emoji                     42  (ok!=true 0)
    2026-09-03 ack.grade                     24  (ok!=true 0)
    2026-09-03 auto.done                     52  (ok!=true 0)
    2026-09-03 retrigger                      7  (ok!=true 0)
    2026-09-03 media                         31  (ok!=true 0)
    2026-09-03 route.level1                   1  (ok!=true 0)
    2026-09-03 channelsub.failed-everyday     2  (ok!=true 1)
    translate 의 detail 모델: gemini-flash-lite=65 · haiku=9 · level1-router=1

[C] 모델 호출 — 같은 파일 action=model.usage · 필드 model/total_tokens/cost_usd
    gemini-flash-lite-latest          167건 ·    294,407 토큰 · $0.0386
    claude-haiku-4-5-20251001          25건 ·    839,184 토큰 · $1.1357
    합계                                192건 ·  1,133,591 토큰 · $1.1743

[D] CLI 세션 — /Users/lioncho/.condition-mate/loop-sessions/sessions.json · 필드 prompt/proj/days/lastDay/startTS
    원장 행 1901 · 그중 proj==slack-translate 218
    ▶ 대시보드 재현 (기간 2026-09-03~2026-09-03) = 9개 · 204,695 토큰 · $0.4910
    그날 데몬이 연 세션(startTS 기준, proj==slack-translate) = 26개 · 596,813 토큰 · $1.4400
      붙은 것    9개 · 204,695 토큰 · $0.4910
      안 붙은 것 17개 · 392,118 토큰 · $0.9490
          5개  '아래 Slack 메시지가 요구하는 일을 실제로 처리하려면 무엇이 필요한지 알아보려 '
          4개  '아래 Slack 메시지에 글로 답할 것이 있는지, 아니면 리액션 이모지 하나로 끝내'
          4개  '나는 물음의 모양을 보는 에이전트다. 답하지 않는다. 이 물음이 제대로 세워졌는지,'
          4개  '나는 응답의 분량을 깎는 에이전트다. 답을 쓰는 것이 내 일이 아니라, 이 메시지가'

[C↔D] 겹침 — 2026-09-03 의 haiku model.usage 와 CLI 세션을 시각으로 1:1 짝짓기
    haiku model.usage 25건 · 그날 CLI 세션 26개 · 짝지어진 쌍 25
    짝 못 지은 세션 ['a8ede383']
    짝 못 지은 usage []
    같은 호출의 두 값: 세션원장 596,813 토큰 $1.4400  ↔  데몬원장 839,184 토큰 $1.1357

[5] 2026-08-28 ~ 2026-09-03 하루씩
  날짜           msg collect transl usage   usage$   세션   붙음   샌것    붙음tok     붙음$     샌tok      샌$    귀속$%   대시보드
  2026-08-28   127     129    129     0   0.0000    0    0    0        0  0.0000        0  0.0000    0.0%      0
  2026-08-29    55      56     56     0   0.0000    2    2    0   42,494  0.0944        0  0.0000  100.0%      2
  2026-08-30     6       6      5    13   0.0000    0    0    0        0  0.0000        0  0.0000    0.0%      0
  2026-08-31    87      89     88   216   0.1451    2    1    1   26,927  0.0658   21,265  0.0489   57.4%      1
  2026-09-01    89      89     89   220   0.0429    0    0    0        0  0.0000        0  0.0000    0.0%      0
  2026-09-02   122     123    122   318   0.1008    1    1    0   22,712  0.0503        0  0.0000  100.0%      1
  2026-09-03    75      75     75   192   1.1743   26    9   17  204,695  0.4910  392,118  0.9490   34.1%      9

[6] sessionSignatures 후보 — 지금 이 루프에 안 붙는 proj==slack-translate 세션
    대상 95개 · 779,639 토큰 · $2.0923
    전체     전체tok      전체$  2026-09-03:   건      tok       $    타루프충돌  접두어 / 출처
     6   128,501   0.2792        5  107,236  0.2304        0  '아래 Slack 메시지가 요구하는 일을 실제로 처리하려면' ← answer-context.mjs:432
     4   106,590   0.2756        4  106,590  0.2756        0  '아래 Slack 메시지에 글로 답할 것이 있는지, 아니면 리액' ← emoji-layer.mjs:406
     4    77,125   0.2040        4   77,125  0.2040        0  '나는 물음의 모양을 보는 에이전트다.' ← problem-frame.mjs:35
     4   101,167   0.2389        4  101,167  0.2389        0  '나는 응답의 분량을 깎는 에이전트다.' ← alignment-engine.mjs:59
    77   366,256   1.0945        0        0  0.0000        0  'You are parsing one Slack message ' ← slack-eyes-daemon.mjs:4577
  다섯 줄을 모두 넣으면: 전체 +95개 +779,639 토큰 +$2.0923 · 2026-09-03 +17개 +392,118 토큰 +$0.9490
  그래도 안 붙는 잔여: 0개 · 0 토큰 · $0.0000
```

`[B]` 의 `총 줄 수 12328` 과 `channelsub.failed-everyday 2` 는 데몬이 지금도 쓰고 있어
다시 돌리면 커진다. 09-03 이전 값은 고정이다.

---

## 11. 이 조사가 답하지 못한 것

- **수집되지 않은 메시지의 수.** `skip` 계측이 없다(8절 2항). 답하려면 계측을 넣어야 한다.
  이 조사는 이것을 결함이 아니라 계측 공백으로 남긴다.
- **08-28·08-29 의 루프 비용.** `model.usage` 원장이 08-30 00:39:45 에 시작해서
  그전 구간은 어느 원장에도 토큰이 없다. 화면의 $0.00 은 "0" 이 아니라 "모른다" 다.
- **`items.model` 한 건이 왜 원장과 갈렸는가.** 갈렸다는 사실은 확인했고(9절)
  원장 쪽이 맞다는 것도 확인했지만, `retrigger` 로 덮인 것인지 폴백에서 필드가 갱신되지
  않은 것인지는 데이터만으로 갈리지 않는다. 코드를 고치지 않는 이번 범위 밖이다.
- **이 조사는 파일을 하나도 고치지 않았다.** `loops/index.md`, `slack-eyes-daemon.mjs`,
  Swift 파일, `items.jsonl` 전부 읽기만 했다. 슬랙 API 를 부르지 않았고, 앱을 재빌드하거나
  데몬을 재시작하지 않았다.

---

---

## 12. 조사 뒤 실제로 고친 것 — 최상위 세션이 L1 로 정하고 진행한 자리

조사 자체는 파일을 하나도 고치지 않았다(11절). 그 위에서 **선언 파일 한 곳만** 고쳤다.
고친 사람은 목적지 세션이고, 고친 시각은 2026-09-04 다.

### 무엇을 고쳤나

`Sources/Plugins/Slack/loops/index.md` 의 `sessionSignatures` 에 7절 표의 1~4 번 접두어를
넣었다. 5번(`HERO_AI_PROMPT`)은 넣지 않았다.

```
+ "아래 Slack 메시지가 요구하는 일을 실제로 처리하려면",
+ "아래 Slack 메시지에 글로 답할 것이 있는지, 아니면 리액션 이모지",
+ "나는 물음의 모양을 보는 에이전트다.",
+ "나는 응답의 분량을 깎는 에이전트다."
```

`sessionNote` 에도 왜 넣었는지와 무엇을 일부러 뺐는지를 같이 적었다.

### 왜 이것이 사람에게 물을 갈래가 아니었나 — 판단 근거

**같은 파일의 `layers` 절이 이미 이 네 층을 이 루프의 층으로 선언하고 있다.**
`emoji-layer.mjs`(즉시 판정), `answer-context.mjs`(접근 범위·공유 문서·관련 대화·공개 리서치),
`alignment-engine.mjs`(정렬 판정·응답) 가 전부 `layers` 에 이름으로 적혀 있다.
즉 이 루프는 "이 층들이 내 것" 이라고 이미 말해 놓고, 그 층들이 쓴 비용만 세지 않고 있었다.
넣는 것은 취향 선택이 아니라 **선언을 자기가 이미 선언한 것과 맞추는 일**이다.
`problem-frame.mjs` 는 `layers` 에 이름이 없지만 같은 데몬이 같은 `translateClaude()` 로
같은 `cwd` 에서 여는 같은 파이프라인의 층이고, 7절에서 다른 프로젝트 오염 0 으로 확인됐다.

되돌리는 값은 이 네 줄을 지우는 것뿐이고 데이터는 한 바이트도 안 바뀐다.
그래서 L1(되돌리는 값이 컴퓨팅뿐) 에서 물을 자리가 아니다.

### 왜 5번(hero)은 뺐나 — 가정

`HERO_AI_PROMPT` 는 #hero 채널의 칭찬 파싱이고 **번역도 기본 응답도 아니다.** 같은 데몬이
같은 CLI 함수를 쓴다는 것은 구현이 같다는 뜻이지 루프가 같다는 뜻이 아니다. `layers` 에
이름이 없는 것도 같은 사실을 말한다. 넣으면 이 루프의 이름
("Slack 공용 수신 · 번역 · 기본 응답")이 세는 것과 실제로 세는 것이 갈라지고,
2026-08-01 하루에 $1.0945 가 소급해 얹혀 그날 그래프가 뜻 없이 튄다.
**가정** — hero 파싱은 별도 루프 선언으로 빼는 것이 맞다. 그 선언은 이번 범위 밖이고,
지금은 미귀속 77개 $1.0945 로 남아 있다. 이것은 이 루프의 누락이 아니라 **아직 선언되지
않은 다른 루프**다.

### 고친 뒤 검산 (읽기 전용, 같은 원장)

고친 `sessionSignatures` 8줄로 `LoopSessionLedger.swift:386-393` 의 접두어 판정과
`LoopEngineeringContent.swift:345-349` 의 날짜·합산(빈 `days` 를 `startTS` 로 떨어뜨리는
폴백 포함)을 그대로 재현했다.

| | 고치기 전 | 고친 뒤 |
|---|---|---|
| 09-03 화면 표시 | 9개 · 204,695 토큰 · $0.4910 | **26개 · 596,813 토큰 · $1.4400** |
| 09-03 잔여 미귀속 (`proj==slack-translate`) | 17개 · 392,118 토큰 · $0.9490 | **0개 · 0 토큰 · $0.0000** |
| 비용 귀속률 | 34.1% | **100%** |

내역은 `days` 를 가진 25개(596,813토큰 $1.4400)와 토큰 0 세션 `a8ede383` 1개의 폴백이다.
JSON 블록은 고친 뒤에도 파싱된다.

### 재빌드가 필요한가 — 필요 없다

선언 파일이 두 자리로 갈려 있어 한 번 확인했다. `LoopDefinitionStore.swift:15` 이 읽는
`Sources/ConditionMate/Plugins/Loop/loops/index.md` 는 **선언 본문이 아니라 절대경로 목록
(레지스트리)** 이고, 그 9번째 줄이
`/Users/lioncho/Work/lion_work/organization/lion/lion-condition-mate/Sources/Plugins/Slack/loops/index.md`
— 내가 고친 바로 그 파일이다. 목록의 두 경로 다 디스크에서 해석된다.

`LoopDefinitionStore.definitions()` 가 **매 조회마다 그 경로를 직접 읽으므로**
(`LoopDefinitionStore.swift:3-4`, `:31-40`) 앱을 다시 빌드하거나 데몬을 재시작할 필요가 없다.
대시보드를 다시 열면 그때 읽는다.

**다만 화면을 직접 열어 26 을 눈으로 보지는 않았다.** 검산은 `LoopSessionLedger.swift:386-393`
의 접두어 판정과 `LoopEngineeringContent.swift:345-349` 의 날짜·합산 폴백을 같은 원장 위에서
스크립트로 재현한 것이다. 화면과 어긋난다면 그 두 자리 밖에 내가 못 본 필터가 있다는 뜻이다.

### 이 수정으로 없어지지 않는 것 — 그대로 남는다

1. **gemini 직접 호출 167건($0.0386)은 여전히 이 화면에 못 들어온다.** 세션을 안 열기
   때문이고 선언으로 고칠 수 있는 문제가 아니다.
2. **축 C·D 이중 계상은 오히려 넓어진다**(7절 마지막). 겹치는 세션이 9개에서 26개로
   늘었다. `$1.1743 + $1.4400 = $2.61` 로 더하면 안 된다는 4절이 더 중요해졌다.
3. **`skip` 계측 공백**(8절 2항)과 **08-28·08-29 의 "모른다" 구간**(6절 곁가지)은 그대로다.

이 셋은 선언이 아니라 화면 설계와 데몬 계측에서 갈라야 하고, 이번 범위 밖이다.

## 1초 요약

요구 — 슬랙 공용수신 루프가 어제 9개라는데 나는 100개를 받았고 전체가 1874개다, 믿기지 않는다.
문제 — 9는 정확하지만 메시지가 아니라 "선언된 접두어와 맞은 CLI 세션" 을 센 제3의 축이고, 진짜 결함은 수집이 아니라 같은 날 26개 세션 중 17개($0.9490)가 어느 루프에도 안 붙는 귀속 누락이며, 더해서 축 C 와 축 D 가 같은 haiku 호출을 두 번 세고 있다.
완성 — 네 축이 파일·필드 근거로 대응되고, 9가 무엇에 정상이고 무엇에 누락인지 갈라 판정되고, 누락분이 17개·392,118토큰·$0.9490 으로 적히고, 그 누락을 없애는 접두어 네 줄을 선언에 넣어 09-03 화면이 26개·$1.4400·잔여 0 이 되는 것까지 검산됐고, 스크립트를 다시 돌리면 같은 값이 나온다 (12절).
