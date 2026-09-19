# Condition Mate Loop Registry

Condition Mate는 루프를 실행하거나 정의를 복사해 소유하지 않는다. 이 파일은 각 프로젝트가
소유한 `loops/index.md`로 가는 라우팅 표다. V2는 아래 경로를 매번 직접 읽으므로 중앙 사본과
프로젝트 원본 사이의 별도 동기화 작업은 없다.

## Routes

- /Users/lioncho/Work/lion_work/organization/lion/lion-condition-mate/Sources/Plugins/Slack/loops/index.md
- /Users/lioncho/Work/lion_work/organization/mustcompany/workspace/mustcompany-survive-failed-everyday/loops/index.md

새 루프를 등록할 때는 해당 프로젝트에 `loops/index.md`를 먼저 만들고, 그 절대 경로 한 줄만
여기에 추가한다. 경로가 사라지면 V2가 `연결 끊김`으로 표시한다.

## 세션을 이 루프에 붙이려면

루프가 Claude 세션을 열어 도는 것이라면, 그 세션이 쓴 토큰과 비용은 세션 트랜스크립트
(`~/.claude/projects`)에만 있다. 세션 원장(`LoopSessionLedger`)이 그것을 루프에 붙이는 근거는
**세션의 첫 프롬프트**이며, 선언이 그것을 적어야 한다. 폴더가 같다는 이유로 붙이지 않는다 —
같은 폴더에서 사람이 연 세션까지 루프 비용으로 세게 되기 때문이다.

```json
"sessionSignatures": ["Run exactly ONE SB-PO cycle now"],
"sessionSkills": ["nss-report-daily"]
```

- `sessionSignatures` — 이 루프가 세션을 열 때 보내는 첫 프롬프트의 **앞머리**(접두어 일치).
- `sessionSkills` — 스킬 하네스나 슬래시 커맨드로 열리는 루프의 스킬 이름.

둘 다 없으면 세션은 이 루프에 붙지 않고, 대신 반복 서명으로 묶여 **미등록 루프 후보**로
루프 엔지니어링 화면에 뜬다. 붙이고 나면 과거 세션까지 소급해 붙는다 — 판정은 매번 다시
하고 추출 결과만 캐시하기 때문이다. 데몬이 API를 직접 부르는 루프처럼 세션을 아예 열지
않는 경우에는 `sessionNote`에 그 사실을 적어 두면 화면이 "기록 없음"의 이유로 그것을 보여 준다.
