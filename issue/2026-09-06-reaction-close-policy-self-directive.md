# 작업지시서 — 리액션 닫기 정책 `self`: 우리가 단 이모지만 빼고 다시 연다

- id: `2026-09-06-0202-condition-mate-reaction-close-policy`
- 트랙: `BEST` · 규모 `P2` · 레벨 `L1`
- 작성: PO (`lion-condition-mate-po-loop-engineering`), 2026-09-06
- 근거 판정서: `issue/2026-09-06-slack-reaction-sync-report.md` (186줄)
- 앞선 지시서: `issue/2026-09-06-slack-reaction-sync-directive.md` (원인 판정까지가 그 범위였다)
- 규격: `docs/specs/SPEC.md` SLKST-7 · SLKST-8 (`:1756`~`:1760`) · SLKST-9 (`:1762`~`:1768`)

---

## 1. 무엇을 왜 하는가

2026-09-02 에 라이언이 "어떤 리액션도 항목을 닫지 않는다" 를 정했고 그것이
`slack-emoji-layer.json` 의 `resolvesPolicy: "none"` 으로 구현됐다. 도는 데몬에 실제로 걸린
것은 2026-09-04 04:22 KST 다.

그 결정이 막으려던 사고는 **데몬이 자기가 단 이모지를 자기가 되읽어 항목을 닫은 것**이었다.
그런데 정책은 리액션에 의한 자동 처리완료를 통째로 껐다. 그 차이를 오늘 실측했다
(`~/.condition-mate/slack-translate/items.jsonl` 2,004줄, 파싱 실패 0):

| 자동 처리완료 1,083건을 무엇이 닫았나 | 건수 | 비율 |
|---|---|---|
| 데몬이 자기가 단 이모지에 걸려 닫음 (`autoEmoji == ackEmoji`) | **155** | 14.3% |
| 라이언이 슬랙에서 손으로 단 리액션 (`autoByMe: true`, 자기 것 아님) | **557** | 51.4% |
| 다른 사람이 단 리액션 (`autoByMe: false`) | **371** | 34.3% |

**사고는 155건짜리 부분집합이었고 정책은 1,083건 전부를 껐다.** 닫힌 항목 1,607건 중
1,083건(67.4%)이 이 경로였으므로, 없앤 것은 부수 기능이 아니라 처리량의 3분의 2다. 대체
경로는 만들지 않았다.

라이언이 **B** 를 골랐다. 우리가 단 이모지만 빼고 다시 연다.

규칙은 두 조건의 논리곱이다.

```
자동 처리완료한다  ⟺  e.user === MY_USER
                     AND  baseEmoji(e.reaction) ∉ (그 항목에 우리가 단 이모지 집합)
```

**두 조건이 다 필요하다.** 데몬의 `slack()` 은 기본 토큰이 `USER_TOKEN`(xoxp) 이고
(`slack-eyes-daemon.mjs:605`) `postEmojiReaction()` 이 그 기본값으로 `reactions.add` 를
부르므로(`:2138`), **데몬이 단 것도 소켓에는 `e.user === MY_USER` 로 되돌아온다.**
`MY_USER` 조건만 걸면 2026-09-02 사고가 그대로 재현된다.

기대 효과: 155건 경로는 계속 막히고, 라이언 손 557건 경로는 되살아나고, 남이 단 371건은
계속 안 닫힌다. 마지막 것은 결함이 아니라 09-02 결정의 정신이다 — 남이 처리했다는 것과
라이언이 처리했다는 것은 다른 사실이다.

---

## 2. 설계 — 이 안으로 간다

### 2-1. `resolvesPolicy` 에 세 번째 값 `"self"` 를 넣는다. 코드에 규칙을 박지 않는다

SPEC SLKST-8 이 "정책 값이나 이모지 이름을 데몬에 박으면 회귀다" 를 계약으로 들고 있다.
그러므로 B 를 소켓 핸들러의 `if` 문에 박으면 그 자체가 회귀다. 축은 JSON 에 산다.

- 값 셋: `"none"`(아무것도 안 닫는다) · `"self"`(B) · `"catalog"`(2026-09-02 이전 동작).
- `RESOLVES_POLICIES` 배열(`slack-eyes-daemon.mjs:245` 부근)에 `'self'` 를 더한다.
- **바닥값은 한 글자도 건드리지 않는다.** 키 없음 → `catalog`, 못 읽음 또는 모르는 값 →
  `none`(fail-closed). 이 두 갈래는 SLKST-8 이 지키는 것이고 시험이 이미 있다
  (`emoji-layer.decision.test.mjs:314`·`:325`·`:336`·`:349`).
- 이 안을 고른 이유는 되돌리기가 JSON 한 낱말이라는 것이다. `"self"` 를 `"none"` 으로
  되돌리면 오늘 상태로 정확히 돌아온다.

### 2-2. 판정 함수의 시그니처를 넓힌다 — 문은 계속 하나여야 한다

SLKST-8 이 `isResolvingEmoji` / `resolvingReaction` / `firstNonTrigger` 셋을 **유일한 문**으로
잡고, 자동 처리완료 경로 셋(수집 · `reconcile` · 소켓)이 전부 여기를 지난다고 계약한다.
B 는 이름만으로 판정할 수 없으므로 문의 **입력이 넓어져야** 한다. 문을 우회해 호출부에
조건을 흩뿌리면 계약이 깨진다.

- `isResolvingEmoji(name)` → `isResolvingEmoji(name, ctx)`. `ctx = { by, item }`.
  - `by` = 그 리액션을 단 슬랙 사용자 id
  - `item` = 그 리액션이 붙은 `items.jsonl` 항목 객체
- `'self'` 아래의 판정:
  ```
  if (!ctx || !ctx.by || !ctx.item || !MY_USER) return false;   // fail-closed
  if (ctx.by !== MY_USER) return false;
  if (isTriggerEmoji(name)) return false;
  if (ourAckEmojis(ctx.item).has(baseEmoji(name))) return false;
  return !nonResolvingEmojiNames().has(baseEmoji(name));        // 행 단위 값은 계속 존중
  ```
- **`MY_USER` 가 아직 null 이면 false 다.** `MY_USER` 는 `auth.test` 로 늦게 채워진다
  (`slack-eyes-daemon.mjs:4759`). 그 전에 도착한 이벤트가 항목을 닫으면 안 된다.
- **`'none'` 과 `'catalog'` 아래의 동작은 `ctx` 유무와 무관하게 지금과 바이트 단위로
  같아야 한다.** 판정 기준은 하나다 — 기존 시험 39개가 전부 그대로 통과한다.
  (예외는 아래 §5 에 적은 의도된 동작 변경 셋뿐이고, 그것은 계약 시험이 아니라 **점유**
  시험이다.)

### 2-3. `postEmojiReaction` 의 쓰기 순서에 경합이 있다 — 같이 고친다

**이것이 이번 배치에서 가장 중요한 항목이다. 보고서가 놓쳤다.**

`slack-eyes-daemon.mjs:2131`~`:2160` 의 순서가 이렇다.

```js
await slack('reactions.add', { channel, timestamp, name: verdict.emoji });   // :2138  먼저 슬랙에 단다
...
rewriteItem(item.id, { ackEmoji: verdict.emoji, ackAt: ... });                // :2157  그 뒤에 ackEmoji 를 적는다
```

그 `await` 이 풀리기 전에 우리가 방금 단 그 리액션의 `reaction_added` 가 소켓으로 돌아온다.
그 시점에 핸들러(`:4266`)가 `loadItems().find(...)` 로 읽는 항목에는 **`ackEmoji` 가 아직
없다.** 그러면 "우리가 단 이모지 집합" 이 비어 있으므로 필터를 통과하고,
**2026-09-02 사고가 그대로 재현된다.** B 를 순진하게 구현하면 이 창이 열린 채로 배포된다.

**고치는 방법 — 낙관적 선기록.**

1. `reactions.add` **전에** `rewriteItem` 으로 `ackEmoji`(그리고 §2-4 의 `ackEmojis`)를 먼저
   적는다.
2. `reactions.add` 가 실패하면 되돌린다. 실패했으면 슬랙에 아무것도 안 달렸으므로 이벤트도
   안 오고, 되돌리는 것이 안전하다. 되돌릴 때 `ackEmojis` 에서도 방금 넣은 값을 뺀다.
3. `already_reacted` 경로(`:2145`)도 같은 순서로 맞춘다 — 그쪽은 이미 달려 있는 것이므로
   선기록이 그대로 참이다.
4. `ackAt`·`requestLevel`·`patch` 는 성공 뒤에 적어도 되고 같이 적어도 된다. 경합을 막는 데
   필요한 것은 **`ackEmoji`/`ackEmojis` 가 `reactions.add` 보다 먼저 디스크에 있는 것** 하나다.

**디스크 쓰기만으로 충분한가 — 충분하다. PO 가 코드로 확인했다.**

- `rewriteItem`(`:3284`~`:3300`)은 `readFileSync` → `writeFileSync(tmp)` → `renameSync` 로
  **동기**다. 호출이 반환한 시점에 값은 이미 디스크에 있다.
- `loadItems`(`:4013`~`:4023`)는 호출마다 파일을 다시 읽는다. **캐시가 없다.** 소켓 핸들러가
  보는 것은 언제나 최신 디스크 상태다.
- node 는 단일 스레드이고 `rewriteItem` 은 동기이므로, 그 사이에 소켓 이벤트가 끼어들 수
  없다.
- **재시작 창도 디스크가 덮는다.** 데몬 재시작이 09-04 부터 하루 23~27회인데, 값이
  `reactions.add` 전에 이미 디스크에 있으므로 재시작해도 살아남는다. 인메모리 `Set` 으로
  막으면 오히려 그 창에서 뚫린다.

→ **인메모리 `Set` 은 두지 않는다.** 두더라도 디스크를 **대체**해서는 안 된다. 이 판정과
근거(`rewriteItem` 이 동기이고 `loadItems` 에 캐시가 없다)를 코드 주석으로 남겨라. 다음
사람이 순서를 되돌리지 않게 하는 것이 그 주석의 목적이다.

**시험을 반드시 하나 넣어라(§5-5).** 이것이 이번 배치에서 가장 값나가는 시험이다.

### 2-4. `ackEmoji` 는 스칼라라 갈아치워진다 — 집합으로 비교한다

항목에 `ackSupersededAt` 필드가 있고 실제로 **2건** 있다(실측). 데몬이 ✅ 를 달았다가 나중에
🔍 로 바꾸면 `item.ackEmoji` 는 최신 하나만 들고 있고, 예전에 우리가 단 ✅ 가 뒤늦게
이벤트로 돌아오면 B 의 필터를 통과해 항목을 닫는다.

**결정: `ackEmojis` 배열을 더한다. 옛 필드는 깨지 않는다.**

- `ackEmojis: string[]` 을 누적한다(중복 없이 push). `ackEmoji` 는 지금처럼 **최신 하나**를
  계속 들고 간다 — 대시보드와 원장이 그 스칼라를 읽고 있으므로 뜻을 바꾸면 그쪽이 깨진다.
- 비교용 헬퍼를 하나 둔다:
  ```js
  function ourAckEmojis(item) {
    const s = new Set();
    for (const n of item?.ackEmojis || []) s.add(baseEmoji(n));
    if (item?.ackEmoji) s.add(baseEmoji(item.ackEmoji));   // 옛 레코드 하위 호환
    return s;
  }
  ```
- **옛 레코드에 `ackEmojis` 가 없어도 안 깨진다** — `ackEmoji` 하나만 들어간 집합이 된다.
  이것이 배열이 아니라 "배열 ∪ 스칼라" 인 이유다. 항목 2,004건 중 `ackEmoji` 를 가진 것이
  295건이고 그 전부가 이 경로로 커버된다.

**왜 이 안인가.** 대안은 셋이었다. (i) `ackEmoji` 를 배열로 바꾼다 — 대시보드·원장·시험이
스칼라를 읽고 있어 하위 호환이 깨진다. (ii) `ackSupersededAt` 기록만 믿는다 — 그 필드는
2건뿐이고 갈아치우기의 **시각**만 있지 **무엇에서 무엇으로** 인지가 없다. (iii) 지금 도는
데몬이 실제로 다는 `ackEmoji` 가 세 종류뿐(`white_check_mark` 172 · `mag` 107 ·
`saluting_face` 16, 실측)이라는 것을 이용해 그 셋을 코드에 박는다 — **SLKST-8 이 금지한
이모지 이름 하드코딩이다.** 그래서 (i)~(iii) 을 버리고 항목별 누적 집합으로 간다.

### 2-5. 갈래 넷 — PO 가 정했다. 사람에게 묻지 마라

#### (a) 수집 경로(`processMessage`, `:3452`) — **`self` 아래에서 닫지 않는다**

`processMessage` 가 `msg.reactions` 를 옮기고 `resolvingReaction()` 을 지난다.
`conversations.history` 의 `r.users` 에 사용자가 들어 있으므로 `self` 판정이 원리적으로는
가능하다. 그런데 라이언이 이미 ✅ 를 단 메시지에 그가 다시 👀 를 달아 수집시키는 것은
"다시 보겠다" 는 뜻일 수 있고, 수집 순간에 곧바로 닫으면 그 👀 가 무의미해진다. 재트리거의
뜻을 지키는 쪽으로 간다. 그리고 B 가 되살리려는 557건은 **전부 수집 이후에 달린 리액션**
이므로 이 결정이 목표를 깎지 않는다.

**구현은 특례를 두지 않는다.** §2-2 의 fail-closed 규칙 `!ctx.item → false` 가 이것을 그대로
만든다 — 수집 시점에는 항목이 아직 존재하지 않으므로 `ctx.item` 이 null 이고, 따라서 자동으로
false 다. 별도 분기를 쓰지 마라. 규칙 하나가 두 자리를 덮는 것이 문이 하나로 남는 방법이다.
`processMessage` 는 `resolvingReaction(msg.reactions, { item: null })` 로 부르고, 이것이
의도된 null 이라는 것을 주석으로 남겨라.

#### (b) 앱 툴바 빠른 리액션 — **닫는다. 동작 변경이므로 SPEC 과 지시서에 적는다**

`/api/slack/reaction` → `SlackTranslateStore.setReaction` 이 `USER_TOKEN` 으로
`reactions.add` 를 부르므로 이것도 소켓에 `e.user === MY_USER` 로 돌아오고, 앱 대장
`reactions.json`(89건)에 남는다. 라이언이 카드 툴바에서 ✅ 를 직접 누른 것은 **의도된
행위**이므로 항목을 닫아도 된다. 앱에서 누른 것과 슬랙에서 단 것을 다르게 대우할 근거가
없다.

- 이것은 오늘과 다른 동작이다. SPEC SLKST-8 의 KO/EN 과 이 지시서에 명시한다.
- 한 가지 부작용을 적어 둔다: 툴바에서 누른 이모지가 마침 우리가 그 항목에 단
  `ackEmoji` 와 **같으면** 닫히지 않는다. 자기 이모지 배제가 이겨야 하기 때문이다. 이것은
  받아들인 한계이고, 그 경우 라이언은 앱의 ✅ 버튼으로 닫으면 된다.
- 소급에는 영향이 없다: 열린 128건 중 `reactions.json` 에 있는 것은 **0건**이다(실측).

#### (c) `reaction_removed` → `autoUnresolve`(`:4290` 부근) — **`firstNonTrigger` 에 기대지 않는다**

지금 조건은 이것이다.

```js
if (resolvesPolicy() !== 'none' && !firstNonTrigger(left)) autoUnresolve(id, it);
```

`'self'` 를 넣으면 앞 조건이 참이 되어 이 경로가 되살아난다. 그런데 **`item.reactions` 는
이름 다중집합만 저장하고 누가 달았는지를 저장하지 않는다**(항목 필드 전수 확인). 그래서
`self` 아래에서 `firstNonTrigger(left)` 는 `ctx.by` 를 만들 수 없어 **언제나 null** 이고,
그러면 `!null` 이 항상 참이 되어 **리액션 하나 뗄 때마다 예전에 자동 처리완료된 항목이
전부 다시 열린다.** SLKST-8 이 `none` 에서 정확히 이 함정을 지적하고 막아 둔 자리다.
`self` 에서 같은 함정을 다시 밟지 마라.

**결정: `self` 아래에서는 "무엇이 남았는가" 가 아니라 "닫은 그것이 떼어졌는가" 로 판정한다.**

```
'self' 에서 autoUnresolve 를 부르는 조건:
    it.autoDone === true
AND baseEmoji(e.reaction) === baseEmoji(it.autoEmoji)
AND it.autoBy && e.user === it.autoBy
```

- 항목을 닫은 리액션이 무엇이었고 누가 달았는지는 이미 항목에 있다 — `autoDone`·`autoEmoji`·
  `autoBy` 를 `autoResolve`(`:3921`~`:3935`)가 적는다. 남은 목록을 추측할 필요가 없다.
- `autoBy` 가 없는 옛 레코드는 **fail-closed = 되돌리지 않는다.** 여기서 fail-closed 의 뜻이
  "지금 상태를 유지" 라는 것에 주의해라. 무더기 재개방이 이 자리의 해악이다.
- `'none'` 과 `'catalog'` 아래의 조건은 지금과 **글자 단위로 같게** 둔다.
- 시험을 반드시 넣어라(§5-6).

#### (d) `reconcile` 경로(`:4064`~`:4071`) — **같은 문을 지나게 해 두되 고치지 않는다**

`reactions.get` 이 2,018회 **전수 실패**(성공 0)라 이 경로는 원래부터 죽어 있다. 그 원인
규명은 이번 범위 밖이다(별건 카드 `2026-09-06-0202-condition-mate-reactions-get-failure`).
**고치지 마라.** 다만 그 호출이 언젠가 살아났을 때 올바르게 돌도록 `self` 규칙을 이 경로에도
같은 문으로 통과시켜 둔다.

- `resolvingReaction(reactions, ctx)` 로 `ctx = { item: o }` 를 넘긴다.
- **`by` 를 고르는 규칙을 고쳐라.** 지금은 `by: (r.users || [])[0]` 로 **첫 사용자**만 본다.
  여러 사람이 같은 이모지를 달았을 때 라이언이 첫 번째가 아니면 놓친다. `self` 아래에서는
  이렇게 한다:
  ```js
  const users = r.users || [];
  const by = (MY_USER && users.includes(MY_USER)) ? MY_USER : users[0];
  ```
  `'catalog'` 아래의 `by` 값은 지금과 같아야 한다 — 그쪽은 `by` 를 판정에 쓰지 않고 기록에만
  쓰므로 위 식을 공통으로 써도 동작이 안 갈리지만, 갈린다고 판단되면 정책별로 갈라라.
- `users` 가 비어 있으면 `by` 가 undefined 이고 §2-2 의 fail-closed 로 false 다.

---

## 3. 열린 128건 소급 — **하지 않는다**

PO 가 실측했다(`~/.condition-mate/slack-translate/`, `items.jsonl` 2,004줄, 파싱 실패 0):

- 열린 항목 **397건**, 그중 트리거가 아닌 리액션이 달린 것 **128건**
- 128건 중 `ackEmoji` 를 가진 것 **70건**, 비트리거 리액션이 우리 `ackEmoji` **뿐**인 것 **30건**
- 128건 중 앱 대장 `reactions.json` 에 있는 것 **0건**
- **`item.reactions` 는 이름 다중집합만 저장하고 누가 달았는지를 저장하지 않는다.**

그래서 셋이 따라 나온다.

1. **B 의 두 조건 중 `e.user === MY_USER` 를 로컬 데이터만으로는 판정할 수 없다.** 판정하려면
   `reactions.get`(응답 `r.users`)이 필요한데 그 호출은 2,018회 전수 실패이고 이번 범위 밖이다.
2. **이름만으로 근사하면 98건(=128−30)이 닫히는데**, 그 안에는 B 가 명시적으로 열어 두기로 한
   "남이 단 리액션"(과거 비율 34.3%)이 섞인다. 09-02 결정의 정신을 정면으로 어긴다.
3. SLKST-8 이 이미 "이 항목은 앞을 향할 뿐이며 원장에 남은 `auto.done` 을 소급해 다시 열지
   않는다" 를 계약으로 들고 있다. **반대 방향에도 같은 원칙을 적용하는 것이 일관된다.**

→ **B 는 앞을 향하는 규칙으로만 넣는다. 열린 128건은 손으로 닫거나, `reactions.get` 별건이
풀린 뒤 별도 배치로 다룬다.** 이 문장을 SPEC SLKST-8 의 근거 줄에도 적어라.

→ 128건이 화면에 왜 남아 있는지 라이언이 모르는 문제는 보고서의 **A(화면 표시)** 가 답이지만
**이번 범위가 아니다.** 필요하다고 판단되면 새 항목 후보로 최종 보고에 한 줄만 적고 하지 마라.

---

## 4. SPEC 편집 — SLKST-8 을 고친다 (`docs/specs/SPEC.md:1756`~`:1760`)

제목부터 지금 문언과 어긋나게 된다. 제목을 안 고치면 규격이 스스로를 반박한다.

- **old 제목**: `SLKST-8 — NO reaction closes an item. The queue is emptied by hand.`
- **new 제목**: `SLKST-8 — only a reaction the user placed themself closes an item, and never one this system posted.`
- **old EN 첫 문장**: "No reaction, from anyone, may move an item out of the user's 미처리 queue."
- **new EN 첫 문장 취지**: 어떤 리액션도 미처리에서 항목을 빼지 못한다 — **단, 라이언 본인이
  직접 달았고 그것이 이 시스템이 그 항목에 단 이모지가 아닌 경우는 예외다**
  (`e.user === MY_USER && baseEmoji(e.reaction) ∉ ourAckEmojis(item)`). 남이 단 리액션은
  여전히 항목을 닫지 못한다. **`MY_USER` 조건만 거는 것은 회귀다** — 데몬이 라이언의
  토큰으로 리액션을 달기 때문에 자기 ack 이모지가 `MY_USER` 로 되돌아온다. 그것이
  2026-09-02 사고 그 자체다.

같이 반드시 들어가야 하는 것:

1. **값 목록을 셋으로.** `"none"` · `"self"` · `"catalog"`. fail-closed 바닥값이 `"none"` 인
   것과 키 없는 옛 어휘집이 `"catalog"` 인 것은 **그대로 둔다**고 명시해라.
2. **`postEmojiReaction` 이 `reactions.add` 보다 먼저 ack 이모지를 기록해야 한다**를 규격
   문장으로 넣어라. **순서를 뒤집으면 회귀다** — 우리가 방금 단 이모지가 `ackEmoji` 가
   적히기 전에 소켓으로 돌아와 스스로 항목을 닫는다.
3. **`ackEmojis` 누적 집합**과 그 이유(`ackEmoji` 는 스칼라라 갈아치워지고 실제로
   `ackSupersededAt` 이 2건 있다)를 넣어라. 옛 레코드에 그 필드가 없어도 `ackEmoji` 하나로
   읽힌다는 하위 호환을 명시해라.
4. **`'self'` 아래에서 `reaction_removed` → `autoUnresolve` 가 `firstNonTrigger` 의 null
   때문에 항상 참이 되면 안 된다**를 명시하고, §2-5(c) 의 `autoEmoji`/`autoBy` 대조 규칙을
   규격 문장으로 적어라.
5. **앱 툴바 빠른 리액션이 이제 항목을 닫는다**는 동작 변경을 명시해라(§2-5b).
6. **수집 경로는 `'self'` 에서 닫지 않는다**를 명시하고 그 이유(재트리거의 뜻)를 적어라.
7. **KO 문언도 같은 뜻으로 고쳐라. EN/KO 가 갈라지면 회귀다.**
8. `Why / 근거` 줄에 오늘 실측을 더해라 — 자동 처리완료 1,083건 = 자기 이모지 155 · 라이언 손
   557 · 남 371. 열린 397건 중 리액션 달린 것 128건, 그중 앱 대장에 있는 것 0건, 우리
   `ackEmoji` 뿐인 것 30건. `ackSupersededAt` 2건. `ackEmoji` 종류는 세 가지
   (`white_check_mark` 172 · `mag` 107 · `saluting_face` 16).
9. §3 의 문장 — "이 항목은 앞을 향할 뿐이며 열린 128건을 소급해 닫지 않는다" 를 근거와 함께
   넣어라.
10. **`Verify` 줄은 실제로 돌린 결과로 새로 써라. 지어내지 마라.** 이번 변경 전 기준선은
    `emoji-layer.decision.test.mjs` **39 pass / 0 fail** 이고 PO 가 오늘 직접 돌려 확인했다.

### SLKST-9 산문 동기화 — 세 곳이다

SLKST-9 는 "같은 규칙이 두 곳에 적혀 있고 갈라지면 안 된다" 를 계약한다. `resolvesPolicy` 의
현재 값을 산문으로 적어 둔 자리가 셋이고 **전부 고쳐야 한다.** 하나라도 빠지면 SLKST-9 위반이다.

| 파일 | 자리 | 지금 뭐라고 적혀 있나 |
|---|---|---|
| `Sources/Plugins/Slack/Daemon/slack-emoji-layer.json` | `:8` `_resolvesPolicy_doc` | "값은 둘뿐이다" |
| `Sources/Plugins/Slack/Daemon/slack-emoji-layer.json` | `:5` `_axis_doc` | "지금 값은 none 이라 … 어떤 리액션도 항목을 닫지 않는다" |
| `Sources/Plugins/Slack/Daemon/reply-policy/router.md` | `:137` §1-6 | "지금 값은 `none` — 아무것도 닫지 않는다 — 이다" |
| `Sources/Plugins/Slack/Daemon/reply-policy/level-1.md` | `:67` | "어떤 리액션도 항목을 닫지 않고 미처리는 손으로만 닫는다(어휘집의 `resolvesPolicy: none`)" |

행 단위 `resolves: false` 는 **지우지 마라.** `self` 아래에서도 그 값은 계속 존중된다
(§2-2 의 마지막 줄). `_axis_doc` 이 "모든 행에 `resolves:false` 를 명시해 두었다" 고 적은
것도 그대로 참이다.

---

## 5. 시험 — `Sources/Plugins/Slack/Daemon/emoji-layer.decision.test.mjs`

**기준선: 39 pass / 0 fail.** PO 가 2026-09-06 에 `node --test` 로 직접 돌려 확인했다.

기존 39개는 `none` 과 `catalog` 의 계약이므로 원칙적으로 전부 그대로 통과해야 한다. 다만
**아래 셋은 계약이 아니라 오늘의 점유를 재는 시험이라 반드시 깨진다. 이것은 의도된 동작
변경이고 회귀가 아니다.** 각각을 새 점유로 고치고, 무엇을 왜 고쳤는지 Verify 줄에 적어라.

| 시험 | 위치 | 왜 깨지는가 | 어떻게 고치나 |
|---|---|---|---|
| `T4 ✅ 도 👍 도 항목을 닫지 않는다 (…resolvesPolicy:none)` | `:236`~`:238` | 번들 값이 `none` 이라고 단언한다 | 번들 값 단언을 `'self'` 로 고치고, "닫지 않는다" 를 `self` 계약(남이 단 것 · 우리 이모지)으로 다시 쓴다 |
| 번들 어휘집 단언 | `:372` | `raw.resolvesPolicy === 'none'` | `'self'` 로 고친다 |
| `autoUnresolve` 가드 원문 단언 | `:367` | 데몬 소스에 `if (resolvesPolicy() !== 'none' && !firstNonTrigger(left)) …` 가 그대로 있는지를 정규식으로 잰다 | §2-5(c) 의 새 가드를 재는 단언으로 다시 쓴다. **정규식을 느슨하게 지우지 마라** — 이 단언이 무더기 재개방을 막는 자리다 |

**깨지는 것이 이 셋 말고 더 있으면 그것은 회귀 의심이다.** 하나하나 의도한 동작 변경인지
회귀인지 판정하고 근거와 함께 보고에 적어라.

### 새로 넣어야 하는 시험 — 최소 여섯

1. `self` 에서 **데몬이 단 `ackEmoji` 가 `MY_USER` 로 되돌아와도 안 닫힌다**
2. `self` 에서 **`MY_USER` 가 단 다른 이름은 닫는다**
3. `self` 에서 **남이 단 리액션은 안 닫는다**
4. `self` 에서 **`ctx` 가 없거나 `ctx.item` 이 없거나 `MY_USER` 가 아직 null 이면 안 닫는다**
   (fail-closed). 수집 경로(§2-5a)가 이 규칙으로 덮인다는 것도 같이 단언해라.
5. **경합(§2-3)**: `ackEmoji` 가 아직 안 적힌 상태에서 우리가 방금 단 이모지의
   `reaction_added` 가 와도 안 닫힌다. **이것이 이번 배치에서 가장 값나가는 시험이다.**
   순서를 되돌리면(=`reactions.add` 를 먼저 하면) 반드시 실패하도록 써라 — 실패하지 않으면
   그 시험은 경합을 재고 있지 않은 것이다.
6. `self` 에서 **`reaction_removed` 가 예전 `autoDone` 항목을 무더기로 되살리지 않는다**
   (§2-5c). 닫은 그 이모지를 그 사람이 뗐을 때만 되살아나는 것도 같이 단언해라.

추가로 권장(필수 아님): `ackEmojis` 가 없는 옛 레코드에서 `ourAckEmojis` 가 `ackEmoji`
하나로 읽히는 하위 호환 시험, 그리고 `reconcile` 의 `by` 선택이 `r.users` 중간에 있는
`MY_USER` 를 잡는 시험(§2-5d).

### 이웃 시험 — 전부 돌려라

`ack-sources` · `send-layer` · `send-layer.gate` · `people-context` · `reply-language` ·
`security-gate`, 그리고 `.e2e/slackemoji.test.js` · `.e2e/slackalignment.test.js`.

`.e2e` 의 `slackdegrade` · `slackpipe` · `slackdefects` 셋은 **이 변경 전에도 이미 실패한다**
(SLKST-7/8 의 Verify NOTE 에 원인이 기록돼 있다 — 앞의 둘은 `ERR_MODULE_NOT_FOUND:
security-gate.mjs`, 셋째는 `untranslatedSegments is not defined`). 실패하면 **변경 전
상태에서도 같은 오류로 실패하는지 확인해서** 인과가 없다는 것을 근거로 적어라. "원래
깨져 있었다" 를 확인 없이 쓰지 마라.

---

## 6. 레벨 판정 — L3 게이트는 **성립하지 않는다**

PO 가 코드로 확인했다.

- `autoResolve()`(`slack-eyes-daemon.mjs:3921`) → `markDone(id)`(`:3899`) →
  `setDoneRemote(id, true)`(`:3883`)
- `setDoneRemote` 은 `POST http://127.0.0.1:<port>/api/slack/done` 에
  **`{ id, done, sync: false }`** 를 보낸다(`:3887`~`:3891`). **루프백이다.**
- `AppDelegate.swift:8468`~`:8489` 의 `/api/slack/done` 핸들러는 `sync` 를 읽고
  **`sync == true` 일 때만** `SlackTranslateStore.syncReaction` 을 부른다. `sync:false` 면
  슬랙에 이모지도 안 달고 스레드 답장도 안 한다. 주석이 이유를 그대로 적고 있다 —
  "sync:false = caller is the daemon … skip the mirror (loop guard)".
- `autoResolve` 이 그 밖에 부르는 것은 `rewriteItem`(로컬 파일) · `act`(로컬 원장) ·
  `log`(로컬) · `ping`(`:516`, 로컬 알림)뿐이다.

→ **자동 처리완료는 슬랙 밖의 사람에게 아무것도 발신하지 않는다.** 그러므로 소급 적용조차
L1 이었을 것이다. 그리고 §3 대로 소급을 하지 않으므로 게이트는 두 번 무의미하다.

→ 돌아올 주소 `term_82a15450-af38-400f-bcf7-4c45d047a54d` 로 **결정 카드를 보내지 마라.**
그 주소는 그 멈춤 지점 전용이고, 지점이 성립하지 않았다.

→ **이번 일에 사람에게 물을 자리가 하나도 없다.** 갈래를 만나면 가장 그럴듯한 안을 골라
진행하고, 무엇을 가정했는지 **산출물 안에** 적어라(보고에만 적지 마라). 조사하면 알 수 있는
것은 질문이 아니다.

---

## 7. 고칠 파일

| 파일 | 무엇을 |
|---|---|
| `Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs` | `RESOLVES_POLICIES` 에 `'self'` · `isResolvingEmoji(name, ctx)` · `resolvingReaction(reactions, ctx)` · `firstNonTrigger` 호출부 · `ourAckEmojis()` 신설 · `postEmojiReaction` 쓰기 순서 뒤집기 · 소켓 핸들러 `:4276` 에 ctx · `reaction_removed` 가드 `:4295` · `reconcile` `:4064` 에 ctx 와 `by` 선택 규칙 |
| `Sources/Plugins/Slack/Daemon/slack-emoji-layer.json` | `resolvesPolicy` → `"self"` · `_resolvesPolicy_doc`(값 셋) · `_axis_doc`(현재 값 서술) |
| `Sources/Plugins/Slack/Daemon/emoji-layer.decision.test.mjs` | 점유 시험 셋 수정 + 신규 시험 여섯 |
| `Sources/Plugins/Slack/Daemon/reply-policy/router.md` | `:137` §1-6 현재 값 서술 |
| `Sources/Plugins/Slack/Daemon/reply-policy/level-1.md` | `:67` 현재 값 서술 |
| `docs/specs/SPEC.md` | SLKST-8 전면 개정(제목·EN·KO·근거·Verify) |

---

## 8. 빌드와 배포 — 도는 데몬이 새 규칙으로 도는 것까지 확인한다

1. `Scripts/build-app.sh` 로 빌드해서 `/Applications/ConditionMate.app/Contents/Resources/` 에
   실제로 반영해라. **지금 배포본은 09-06 02:05 자이고 `"resolvesPolicy": "none"` 이다**
   (PO 실측). 배포 후
   `grep -o '"resolvesPolicy": "[a-z]*"' /Applications/ConditionMate.app/Contents/Resources/slack-emoji-layer.json`
   가 `"self"` 를 돌려줘야 한다.
2. **운영 오버라이드 파일을 확인해라.** `~/.condition-mate/slack-translate/emoji-layer.json`
   에 `resolvesPolicy` 가 적혀 있으면 **그쪽이 이긴다**(`emojiLayerResolveFields` 가 두 겹을
   순회하며 그 키를 실제로 적어 둔 마지막 파일이 이긴다, `:253`~`:268`). 번들만 고치고
   끝내면 안 도는 상태로 "됐다" 고 읽게 된다.
   **PO 실측(2026-09-06): 그 파일은 존재하지 않는다.** 그래도 배포 시점에 다시 확인해라 —
   그 사이에 생겼을 수 있다.
3. 데몬을 재시작하고(`launchctl kickstart -k gui/501/com.condition-mate.slack-eyes`) 로그에서
   새 정책이 실제로 읽히는 것을 확인해라. **캐시가 60초다.** 로그는
   `/tmp/cm-slack-eyes.out.log` · `/tmp/cm-slack-eyes.err.log`.
4. **실제로 도는 것을 확인하는 가장 값싼 방법을 골라라.** 슬랙에 실제로 리액션을 하나 달아
   항목이 닫히는 것을 보는 것이 가장 확실하지만, **그것은 라이언 계정으로 실제 메시지에
   이모지를 다는 것이다.** 대상 메시지를 라이언 본인이 쓴 것이나 이미 처리된 것으로 골라
   남에게 오해가 안 생기게 하고, 확인 뒤 되돌려라. 무엇을 어느 메시지에 달았고 되돌렸는지
   보고에 한 줄로 적어라. 그렇게 못 하겠으면 `reaction_added` 이벤트를 흉내내는 단위 시험으로
   대체하고 그 이유를 적어라.
5. `Scripts/autobuild-watch.sh` 가 돌고 있을 수 있다. 빌드가 겹치는지 확인해라.

---

## 9. 이번 범위 밖 — 손대지 마라

- `reactions.get` 전수 실패 원인 규명 — 별건 카드
  `2026-09-06-0202-condition-mate-reactions-get-failure`
- 데몬 재시작 급증(09-04 부터 하루 23~27회) 원인 규명 — 별건 카드
  `2026-09-06-0202-condition-mate-daemon-restart-surge`
- `conversations.history` rate limit (20일째)
- 화면 표시 개선(보고서의 A) — 접힌 줄에 리액션 칩 보이기
- 열린 128건 소급 적용(§3)

보다가 더 할 것이 보이면 **하지 말고** 최종 보고에 한 줄로만 적어라.

---

## 10. 완성 조건 — 이 전부가 참이어야 끝이다

1. `slack-emoji-layer.json` 의 `resolvesPolicy` 가 `"self"` 이고, `_resolvesPolicy_doc` 이
   값 셋을 말한다.
2. `emoji-layer.decision.test.mjs` 가 `node --test` 로 **0 fail**. 신규 시험 여섯이 전부 들어
   있고, 깨진 기존 시험은 §5 의 셋뿐이며 각각 왜 고쳤는지가 적혀 있다.
3. §5-5 의 경합 시험이 **쓰기 순서를 되돌리면 실패한다**는 것을 실제로 확인했다.
4. 이웃 시험 여섯과 `.e2e` 둘이 통과한다. 원래 깨져 있던 `.e2e` 셋은 변경 전에도 같은
   오류로 깨지는 것을 확인해 인과 없음을 근거로 적었다.
5. SPEC SLKST-8 의 제목·EN·KO·근거·Verify 가 새 규칙을 말하고, EN 과 KO 가 같은 뜻이다.
6. SLKST-9 산문 네 자리(`_resolvesPolicy_doc`·`_axis_doc`·`router.md:137`·`level-1.md:67`)가
   코드와 같은 것을 말한다.
7. 배포본
   `/Applications/ConditionMate.app/Contents/Resources/slack-emoji-layer.json` 의
   `resolvesPolicy` 실측값이 `"self"` 다.
8. 운영 오버라이드 파일의 유무를 실측해 보고했다.
9. 도는 데몬이 새 규칙으로 돈다는 근거(로그 줄 또는 실이벤트 확인)가 보고에 있다.
10. §3(128건 소급 안 함)과 §6(L3 게이트 불성립)이 SPEC 또는 이 지시서에 적혀 있다.

---

## 원문

> 컨디션 메이트 리액션 닫기 정책 고치기 — 방향 A/B/C 중 택일
>
> 09-02 에 정한 `resolvesPolicy:none` 이 09-04 04:22 에 발효돼 어떤 리액션도 항목을 닫지
> 않게 됐다. 열린 397건 중 128건이 이미 리액션을 달고 있고, 닫힌 1,607건 중 1,083건(67.4%)이
> 리액션으로 닫힌 것이었다. 정책이 없앤 것이 처리량의 3분의 2인데 대체 경로가 없다. 사고의
> 원인은 데몬이 자기가 단 이모지에 스스로 걸려 닫은 155건(14.3%)짜리 부분집합인데 정책은
> 1,083건 전부를 껐다.
>
> **라이언의 결정: B. 우리가 단 이모지만 빼고 다시 연다.**
>
> 고칠 방향 셋 중 라이언이 B를 선택했다. A(화면만)와 C(전부 되돌림)는 탈락. 착수 범위는
> B(우리가 단 이모지만 빼고 다시 연다) 하나다.
>
> 출처: `organization/lion/lion-condition-mate/issue/2026-09-06-slack-reaction-sync-report.md`
> 출처 세션 핸들: `term_c816c91c-ff03-4789-a9bd-73d406fd8b59`

(큐 트랙 카드 `organization/lion/lion-work-queue/inbox/2026-09-06-0202-condition-mate-reaction-close-policy.md` 의 `## 원문` 절 전문.)

---

## 1초 요약

요구 — 리액션 닫기 정책을 B 로 고친다. 우리가 단 이모지만 빼고 다시 연다.

문제 — B 를 이름 비교로 순진하게 넣으면 09-02 사고가 그대로 재현된다. 데몬이 라이언 토큰으로
리액션을 달아서 자기 이모지가 `MY_USER` 로 되돌아오고, 게다가 `postEmojiReaction` 이
`reactions.add` 를 먼저 하고 `ackEmoji` 를 나중에 적어서 "우리가 단 것" 을 판정할 근거가 그
순간 디스크에 없다. 그래서 이 일은 정책 값 한 낱말이 아니라 **쓰기 순서 · 판정 함수의 입력 ·
누가 달았는지의 출처** 셋을 같이 고치는 일이다.

완성 — 어휘집이 `"self"` 이고, 데몬이 단 이모지가 되돌아와도 안 닫히는 시험과 쓰기 순서를
되돌리면 실패하는 경합 시험이 통과하며, 배포본과 도는 데몬이 실제로 그 값으로 돈다.

---

## 범위 밖에서 나온 것 — `Sources/Plugins/Slack/Daemon/` 34개 파일이 git 추적 밖이다

이번 일을 하다가 나왔고 이번 완성 조건과는 무관하다. 목적지 세션이 실측했다 (2026-09-06).

```
tracked   : 2  (com.condition-mate.slack-eyes.plist, slack-eyes-daemon.mjs)
untracked : 34 (정책 JSON 8개 · .mjs 모듈 전부 · reply-policy/ 8개 · 시험 파일 6개)
ignored   : 0
```

`.gitignore` 로 무시된 것이 아니라 그냥 `git add` 가 안 된 것이다 (`--exclude-standard` 로
그대로 나온다). `a5b03d1` 폴더 이동 커밋 때 빠진 것으로 보인다.

**결과가 둘이다.** 하나, SLKST-8 축이 사는 `slack-emoji-layer.json` 자체가 버전 관리 밖이라
09-06 보고서가 `resolvesPolicy` 가 언제 `none` 이 됐는지를 커밋으로 못 밝혔다 — 원인이 이것이다.
둘, 오늘 고친 6개 중 4개(`slack-emoji-layer.json`, `emoji-layer.decision.test.mjs`,
`reply-policy/router.md`, `reply-policy/level-1.md`)가 추적 밖이라 지금 커밋 대상이 아니다.
추적되는 것은 `slack-eyes-daemon.mjs` 와 `docs/specs/SPEC.md` 둘뿐이다.

**커밋하지 않았다 — 이것이 이 세션의 판단이고 가정이다.** 근거 셋이다. (1) 이번 항목의 완성
조건은 "정책 B 가 실제로 도는 것" 과 "128건에 답" 둘이고 커밋은 거기 없다. (2) 이 저장소의
작업 트리는 지금 `feat/dashboard-value-pipeline` 브랜치에서 저장소 전역 수십 개 파일이 수정된
상태다 — 34개를 여기 섞어 담으면 이 정책 변경이 그 덩어리 안에서 안 보이게 된다. (3) 커밋
범위를 정하는 것은 이 항목의 위임 범위 밖이다.

비밀정보 스캔은 돌렸고 토큰·키 패턴 0건이다. 담을지 말지는 별건으로 세워야 한다.
