# QA 오케스트레이션 회고 (fix-loop retrospective)

버그 수정 오케스트레이션 루프(최대 3라운드)의 라운드별 회고를 누적한다. 규칙: 라운드마다
회고를 갱신하고, QA가 한 번에 못 잡은 부분은 원인을 적고 manager-qa 에이전트를 업데이트한다
(이유 포함). 3라운드로도 못 잡으면 방법 자체를 재검토하고 멈춘다.

- 오케스트레이터(메인)가 **최종 테스트**를 직접 수행한다.
- manager-pm이 최적안·QA 디스패치 프롬프트·회고를 설계한다.
- manager-qa가 구현·검증한다.

---

## Case: BGM ↔ 대시보드 전환 시 음악 중복 (double audio)

보고: 사용자 — "대시보드와 bgm을 전환하면서 음악이 중복되서나와" (Loom 영상 제공, 텍스트 증상 기준).
직전에 manager-qa에 위임했으나 못 잡은 버그.

### Round 1 — 2026-07-05 · 결과: FIXED (오케스트레이터 독립 검증 통과)

**버그**
통합 네이티브 창에서 BGM 모드 → 대시보드 모드로 전환하면 음악이 두 겹으로 재생됐다.
근본 원인: `AppWindow.swift`의 `applyAudioOwnership()`가 `onOwnAudio(mode == .bgm)`를 호출 →
대시보드 모드에서 네이티브 `AudioEngine`이 언뮤트(`AppDelegate.swift:241-245`)되는데, 상시 유지되는
BGM webview는 설계상 off-view에서도 계속 재생 → 두 소스 동시 재생.

**왜 QA가 못 잡았나 (핵심 회고)**
"seamless audio" 재설계로 오디오 모델이 "창 열려있으면 항상 소유" → "모드 따라 소유"로 바뀌었는데,
SPEC A1과 manager-qa 체크리스트 3번은 여전히 옛 모델("창 열려있는 동안 네이티브 계속 뮤트")을 담고
있었다. QA는 그 불변식 중 **아직 통과하는 절반**(BGM 모드의 mute latch, "재로드 없음" 로그)만 검증하고,
중복이 실제로 발생하는 **대시보드 모드의 동시 가청 상태**는 한 번도 테스트하지 않았다.

더 결정적으로, QA의 occlusion 테스트는 "webview가 off-view에서도 계속 재생됨"을 **증명**했으면서도 그걸
순수 성공("seamless")으로만 읽었다. "웹이 계속 재생 + 대시보드 모드가 네이티브 언뮤트라면, 둘이 동시에
울리는 것 아닌가?"라는 상보적 질문을 하지 않았다. 불변식의 한쪽만 확인하고, 그 한쪽과 결합해 버그가 되는
나머지 절반을 검증하지 않은 것이다.

**수정 (Option A — 창이 열린 동안은 항상 오디오 소유)**
- `AppWindow.swift applyAudioOwnership()`: `onOwnAudio?(true)` (모드 무관, 창 open 동안 항상). 네이티브는
  창이 열린 내내 뮤트, 전용 BGM webview가 양 뷰의 유일 오디오 소스. 닫힘/종료 시에만 해제.
- 제3 소스(대시보드 인페이지 BGM iframe = `/bgm-player` 사본) 가드: `BGMPlayerContent.swift`에
  `EMBEDDED = window.frameElement !== null` 판별 후, 임베디드 사본은 `bgmAutoStart()`/`nativeMute()`를 no-op.
- 계측: `AppWindow.logAudioProbe()` — 네이티브 `muted` + BGM webview `<audio>.paused/currentTime`를 동시 기록.
- SPEC A1을 open-상태 모델로 재작성.

**오케스트레이터 최종 검증 (독립 재현)**
전용 dev 번들 실행 → BGM→대시보드→BGM→대시보드 전환하며 app.log 관찰:
- 창이 열린 전 구간 `owns audio=false` **0회** — 네이티브 상시 뮤트.
- BGM webview `currentTime`이 0→29.7로 **단조 증가**(전환 넘어 리셋/정지/갭 없음).
- 대시보드 모드 샘플에서 네이티브 뮤트 + 웹 `paused:false` 전진 동시 성립 = 가청 소스 정확히 1개.

**방법 개선 (이 유형의 미탐을 막기 위해 — manager-qa 에이전트에 반영)**
1. **불변식은 양쪽을 다 검증한다.** "이중 오디오 없음"은 (a) 웹 소스 상태 + (b) 네이티브 소스 상태 두 절반으로
   구성된다. 한쪽만 보면 PASS가 나오지만 둘이 결합해 결함이 된다. 항상 상보 조건을 함께 단언한다.
2. **로그/latch가 아니라 실제 가청 종단 상태를 본다.** 오디오 기능은 모든 소스(네이티브 AudioEngine, 각
   webview `<audio>`)의 실제 재생 상태를 **모든 모드/전환에서 동시에** 관측한다(evaluateJavaScript로 웹 상태 읽기).
3. **모델이 바뀌면 옛 모델을 담은 SPEC/체크리스트 항목은 stale이므로 같은 변경에서 다시 쓴다.** stale 불변식은
   "잘못된 이유로 통과하는 테스트"다.

**에이전트 업데이트:** manager-qa.md 체크리스트 3번 재작성 + "오디오 기능은 실제 동시 가청을 검증" 상시 규칙
추가. 이유·원장은 `agent-update-log.jsonl` 참조.

**루프 종료:** Round 1에서 해결되어 2·3라운드 불필요.
