# Condition Mate — Slack 공용 응답 루프

```json
{
  "id": "condition-mate-slack-shared-reply",
  "name": "Slack 공용 수신 · 번역 · 기본 응답",
  "scope": "shared",
  "scopeLabel": "공용 인프라",
  "status": "live",
  "purpose": "Slack 연결을 한 벌로 유지하고 메시지를 수신·번역·기본 라우팅한 뒤 채널 전용 루프로 전달한다.",
  "problem": "각 채널 루프가 Socket Mode 연결, 중복 방지, 토큰, 스레드 게시를 제각각 구현하면 장애와 보안 경계가 흩어진다.",
  "modelProblem": "모든 채널에 같은 답변 품질을 강제하는 문제가 아니다. 공통 수신과 기본 번역·짧은 안내만 책임지고, 채널 의미와 품질 기준은 채널 전용 루프에 넘겨야 한다.",
  "workspace": "/Users/lioncho/Work/lion_work/organization/lion/lion-condition-mate",
  "source": "MUST Company Slack · mention · DM · broadcast · 등록 채널",
  "ledgerPath": "/Users/lioncho/.condition-mate/slack-translate/actions-daemon.jsonl",
  "usagePaths": ["/Users/lioncho/.condition-mate/slack-translate/actions-daemon.jsonl"],
  "sessionSignatures": [
    "다음 슬랙 메시지를 자연스러운 한국어로 번역하라.",
    "다음 슬랙 메시지를 세 단계로 처리하라. 목표 언어: 한국어.",
    "다음 슬랙 메시지를 두 단계로 처리하라.",
    "다음 Slack 메시지에 대한 짧은 선응답을 작성하라.",
    "아래 Slack 메시지가 요구하는 일을 실제로 처리하려면",
    "아래 Slack 메시지에 글로 답할 것이 있는지, 아니면 리액션 이모지",
    "나는 물음의 모양을 보는 에이전트다.",
    "나는 응답의 분량을 깎는 에이전트다."
  ],
  "sessionNote": "현재 데몬의 직접 API 호출은 usage 원장에서 세고, 이전 Claude CLI 번역·기본 응답 세션은 sessionSignatures로 소급해 이 루프에 붙인다. 2026-09-04 에 뒤 네 줄(answer-context·emoji-layer·problem-frame·alignment-engine)을 추가했다 — 이 층들은 위 layers 에 이미 이 루프의 층으로 선언돼 있는데 접두어가 없어 세션이 안 붙었고, 09-03 하루에만 17개 392,118토큰 $0.9490 이 미귀속으로 샜다. 근거는 issue/2026-09-04-slack-loop-9-vs-100-report.md 7절. 여기 없는 다섯째 후보 HERO_AI_PROMPT(#hero 칭찬 파싱, 77개 $1.0945, 전부 08-01자)는 이 루프의 일이 아니므로 일부러 뺐다. 2026-09-19: 세션 원장이 Gemini 및 transport=api 호출을 함께 표시한다. CLI 호출은 transcript에서만 세고, 과거 transport 미기록 Claude 호출은 중복 가능하여 별도 합산하지 않는다. 기간 필터는 세션별 활동일 기준이다.",
  "triggers": [
    {"kind":"cron", "name":"slack-eyes daemon", "label":"com.condition-mate.slack-eyes", "detail":"Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs", "cadence":"항상 연결"},
    {"kind":"event", "name":"Slack Socket Mode", "detail":"message · reaction · mention · DM 이벤트 수신", "cadence":"이벤트가 올 때"}
  ],
  "agents": [],
  "layers": [
    {"name":"즉시 판정", "kind":"규칙 + 모델", "source":"emoji-layer.mjs", "job":"닫는 말은 글 대신 이모지로 끝내고, 답이 필요한 메시지만 다음 단계로 보낸다."},
    {"name":"접근 범위", "kind":"권한", "source":"answer-context.mjs", "job":"발신자와 채널에 따라 조회해도 되는 근거의 범위를 먼저 정한다."},
    {"name":"같은 스레드", "kind":"Slack", "source":"slack-eyes-daemon.mjs", "job":"현재 대화의 앞뒤 문맥을 기본 근거로 모은다."},
    {"name":"스레드 대체", "kind":"Slack", "source":"slack-eyes-daemon.mjs", "job":"같은 스레드에 답이 쌓이지 않게 이전 답변을 지우고 내용은 ack-threads.json 에 축적해 마지막 한 개만 남긴다."},
    {"name":"공유 문서", "kind":"Notion", "source":"answer-context.mjs", "job":"스레드에 공유된 문서 본문을 읽어 답의 근거로 쓴다."},
    {"name":"업무 기록", "kind":"Jira", "source":"slack-eyes-daemon.mjs", "job":"이슈의 원래 문제 정의와 상태를 찾는다."},
    {"name":"관련 대화", "kind":"Slack", "source":"answer-context.mjs", "job":"앞선 근거가 부족할 때만 다른 스레드의 관련 기록을 찾는다."},
    {"name":"공개 리서치", "kind":"Web", "source":"answer-context.mjs", "job":"내부 근거와 일반 요건을 비교해야 할 때 공개 자료를 보충한다."},
    {"name":"정렬 판정·응답", "kind":"결정적 검사", "source":"alignment-engine.mjs", "job":"모델은 사실만 추출하고, 응답 형식은 코드가 판정한다. 포맷은 버전으로 관리한다 — v2는 한두 단어 판정 한 줄과 의미 분석·예상 의사결정 두 칸만 내보내고, config.json replyFormat 으로 v1로 되돌린다."}
  ],
  "maturity": [
    {"level":1, "name":"단일 에이전트", "status":"done", "detail":"한 프롬프트가 수신부터 답변까지 모두 처리하는 출발 단계."},
    {"level":2, "name":"스킬·스크립트 분리", "status":"current", "detail":"근거 수집, 이모지 판정, 정렬 검사를 모듈로 분리해 토큰과 지연을 줄인 현재 구조."},
    {"level":3, "name":"모델 라우팅", "status":"partial", "detail":"번역 모델 선택과 폴백은 동작한다. 응답 난이도별 모델 라우팅은 아직 한 경로다."},
    {"level":4, "name":"자기 개선", "status":"next", "detail":"실패 원장을 평가해 규칙·프롬프트·라우팅 변경을 제안하고 검증하는 폐루프는 다음 단계."}
  ],
  "flow": [
    {"from":"Slack", "to":"slack-eyes", "label":"Socket Mode 공용 연결"},
    {"from":"slack-eyes", "to":"공통 필터", "label":"중복·봇·보안·정책 판정"},
    {"from":"공통 필터", "to":"기본 처리", "label":"번역·짧은 확인·Level 1 라우팅"},
    {"from":"공통 필터", "to":"채널 구독", "label":"channelSubs의 프로젝트 핸들러 호출"},
    {"from":"채널 구독", "to":"채널 전용 루프", "label":"메시지 JSON과 Slack 토큰 전달"}
  ],
  "evidence": [
    {"name":"수신·응답 원장", "path":"~/.condition-mate/slack-translate/actions-daemon.jsonl"},
    {"name":"수집 메시지", "path":"~/.condition-mate/slack-translate/items.jsonl"},
    {"name":"채널 전달 원장", "path":"~/.condition-mate/slack-translate/channel-subs.jsonl"},
    {"name":"채널별 응답 정책", "path":"~/.condition-mate/slack-translate/channel-reply-policy.json"},
    {"name":"스레드 선응답 원장", "path":"~/.condition-mate/slack-translate/ack-threads.json"},
    {"name":"실행 코드", "path":"Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs"}
  ],
  "known": "slack-eyes launchd가 실행 중이고 Socket Mode 수신, 번역, 기본 스레드 응답, channelSubs 전달 기록이 원장에 남는다.",
  "unknown": "채널마다 다른 답변의 의미적 품질은 이 공용 루프의 측정 대상이 아니다. 해당 채널 전용 루프가 따로 책임져야 한다."
}
```

이 루프는 공용 운송 계층이다. 채널별 컨텍스트, 세션 권한, 답변 문체와 품질 기준을 소유하지
않는다. `channelSubs`로 넘긴 이후의 판단과 평가는 각 프로젝트의 `loops/index.md`가 소유한다.
