# 작업지시서 — 컨디션 메이트 사운드 미작동 (2026-09-06)

- 큐 항목: `2026-09-06-2107-condition-mate-sound-not-working` (BEST · L1 · P2 · C2)
- 트랙 카드: `/Users/lioncho/Work/lion_work/organization/lion/lion-work-queue/inbox/2026-09-06-2107-condition-mate-sound-not-working.md`
- 목적지 폴더: `/Users/lioncho/Work/lion_work/organization/lion/lion-condition-mate`
- 이 폴더는 P2 라 일반 PO 자리가 없다. entry_agent(`lion-condition-mate-pm`)가 PO 몫까지 맡아 이 지시서를 썼다.

## 원문

```
컨디션 메이트 관련한 건데
디렉터 예전되기 위임하고
현재 지금 사운드가 안 나거든
```

## 무엇이 문제였는가 — 확인된 원인

**원인 한 줄: BGM webview 가 창의 유일한 오디오 주인인데, 재생을 시작하려면 사용자의 클릭
제스처를 기다리도록 되어 있었다. 그 제스처가 오지 않으니 `engaged` 가 영원히 false 였고,
네이티브 오디오는 소유권 때문에 이미 강제 음소거된 상태라 아무 데서도 소리가 나지 않았다.**

근거는 셋이다.

**하나. 코드.** `Sources/ConditionMate/Dashboard/BGMPlayerContent.swift` 의 `refreshNow()` 안,
디렉터가 고른 곡을 따라가는 분기다. HEAD(커밋된) 판은 1114 행이 이렇다.

```js
if(engaged && audioEl.paused){ audioEl.play().catch(()=>{}); }
```

`engaged` 는 사용자가 재생 버튼을 눌렀을 때만 true 가 된다. 전용 BGM 창은 자동으로 뜨고
사람이 그 안을 클릭할 이유가 없으므로 `engaged` 는 계속 false 다. 그래서 곡은 `loadTrack` 으로
element 에 물리기만 하고 `play()` 는 한 번도 불리지 않는다. 같은 파일 130~140 행대의 SPEC
근거(WINLIFE 계열)대로 **창이 열려 있는 동안 네이티브는 계속 음소거**이므로, webview 가 안
울면 소리의 출처가 하나도 없다.

**둘. 로그.** `~/.condition-mate/app.log` 의 `app-window audio-probe(periodic mode=dashboard)`
라인은 webview 의 audio element 상태를 그대로 찍는다. 2026-09-04 21:16 KST 부터
2026-09-07 00:33 KST 까지 앱이 뜬 **모든 pid 가 예외 없이** 아래 상태였다.

```
paused=true  engaged=false  readyState=0
```

`readyState=0` 은 데이터가 한 바이트도 안 실렸다는 뜻이고 `paused=true` 는 재생이 시작된 적이
없다는 뜻이다. 며칠 내내 침묵이었다. 침묵 중에도 앱은 스스로 `on:true, playing:true` 를
보고하고 있었다 — **앱의 자기 보고와 실제 소리가 갈라져 있었던 것이 이 결함이 오래 안 잡힌
이유다.** 디렉터는 곡을 고르고 있었고 화면은 "재생 중" 이었는데 스피커만 조용했다.

**셋. 고친 뒤의 같은 로그.** 작업트리 판은 같은 자리가 이렇게 바뀌어 있다 (1114~1116 행).

```js
if(!curTrack || curTrack.id!==now.id){ loadTrack({id:now.id,title:now.title,bpm:now.bpm}, !EMBEDDED || engaged); }
if((!EMBEDDED || engaged) && audioEl.paused){ engage(); audioEl.play().catch(()=>{}); }
$("status").textContent = (!EMBEDDED || engaged) ? ("재생 중 · "+now.title) : ("앱 BGM 재생 중 · 눌러서 여기서 공간감으로 듣기");
```

축은 `EMBEDDED` 다. `BGMPlayerContent.swift:906` 에서 `window.frameElement !== null` 로 정해지며,
대시보드 안에 끼워진 BGM 탭이면 true, 전용 최상위 BGM webview 면 false 다. **전용 창은
WKWebView 설정이 autoplay 를 허용하므로 제스처 없이 시작해도 되고, 그것이 창의 오디오 주인의
정의다.** 끼워진 복사본은 `!EMBEDDED` 가 false 라 그대로 제스처 전용으로 남아 세 번째 소리
출처가 되지 않는다.

이 판으로 뜬 pid 5544 는 2026-09-07 00:41:59 KST 에 아래로 뒤집혔고 그 뒤로 유지된다.

```
paused=false  engaged=true  readyState=4  currentTime 이 계속 증가
```

## 누가 언제 고쳤는가 — 이 세션이 고친 것이 아니다

정직하게 적는다. `BGMPlayerContent.swift` 의 mtime 은 **2026-09-06 21:09:19**, 앱 바이너리
`/Applications/ConditionMate.app/Contents/MacOS/ConditionMate` 의 mtime 은 **21:11:07** 이다.
이 항목의 트랙 카드가 잡힌 시각이 21:07 이고 이 세션이 뜬 것이 21:11 이므로, **수정은 이
세션이 시작되기 전에 다른 창(라이언이 원문에서 말한 "디렉터 예전되기 위임하고" 그 갈래)이
이미 넣어 둔 것이다.** 이 세션이 한 일은 원인을 특정하고, 그 수정이 실제로 도는 앱에
들어갔는지 확인하고, 귀로 확인할 수 없는 것을 객관적 증거로 대신 확인한 것이다.

## 도는 앱이 어느 바이너리인가

이 폴더에서 반복해서 사고가 난 자리라 먼저 잡았다.

```
lioncho 5544 /Applications/ConditionMate.app/Contents/MacOS/ConditionMate   ← 지금 도는 것
```

`.build/debug/ConditionMate` 가 아니라 **설치된 앱 번들**이다. 그리고 그 바이너리 안에 수정이
실제로 들어갔는지는 문자열로 확인했다 — JS 가 Swift 문자열로 박히므로 주석까지 바이너리에
남는다.

```
strings -a <바이너리> | grep -c "Start the dedicated owner immediately"   → 1   (새 판 있음)
strings -a <바이너리> | grep -c "leaving the window's audio owner silent" → 0   (옛 판 없음)
```

`~/.condition-mate/updates/` 는 비어 있다. 스테이징이 이미 소진되어 `/Applications` 에
반영됐다는 뜻이고, 파일만 고치고 화면에서 못 보던 이전 사고와 다른 상태다.

## 소리가 실제로 나는가 — 눈이 아니라 객관적 증거로

"고쳤다" 로 끝내지 말라는 것이 이 항목의 조건이므로, 오디오가 실제로 스피커로 나가는지를
따로 확인했다.

1. **audio element 가 실제로 재생 중이다.** pid 5544 의 `audio-probe` 가 `paused:false`,
   `readyState:4`, `currentTime` 이 3 초 폴링마다 정확히 3 초씩 증가, `err:null` 을 찍는다.
   곡이 바뀌어도(158 → 16 → 78) `currentTime` 이 0 근처에서 다시 올라가며 재생이 이어진다.
2. **CoreAudio 가 실제로 출력 장치를 잡고 있다.** `pmset -g assertions` 에 `coreaudiod` 가
   건 assertion 이 세 개 있고, 이름이
   `com.apple.audio.BuiltInSpeakerDevice.context.preventuseridlesleep`,
   `Resources: audio-out BuiltInSpeakerDevice` 다. **이것은 지금 내장 스피커로 오디오가
   나가고 있을 때만 잡히는 자원이다.** 경과 시간(00:02:36 / 00:02:51)이 앱 재시작 시각과
   맞는다.
3. **디코더가 앱의 자식 프로세스에 올라와 있다.** WKWebView 의 미디어는 별도 GPU 프로세스에서
   난다. 앱과 함께 뜬 `com.apple.WebKit.GPU` (pid 6204) 가 `CoreAudio.component`,
   `AudioCodecs.component`, `AudioDSP.component` 를 로드하고 있다.
4. **아무것도 소리를 죽이고 있지 않다.** 시스템 `output volume:100, output muted:false`,
   앱의 `/api/bgm/now` 가 `on:true, playing:true, muted:false`.

네 가지가 같은 방향을 가리키므로 **소리는 지금 실제로 나고 있다**고 판정한다.

## 가장 큰 잔여 위험 — 수정이 커밋되어 있지 않다

이 수정은 **작업트리에만 있다.** `git status` 에서 `BGMPlayerContent.swift` 는 `M` 이고,
`git show HEAD:...` 는 여전히 옛 판(`if(engaged && audioEl.paused)`)을 들고 있다. 즉
**`git checkout` 이나 `git stash` 한 번, 또는 다른 창이 깨끗한 트리에서 빌드하는 것 한 번으로
며칠짜리 침묵이 그대로 돌아온다.**

이 항목에서는 커밋하지 않는다. 브랜치 `feat/dashboard-value-pipeline` 에 남의 미커밋 변경이
같이 얹혀 있어 커밋 자체가 남의 작업을 끌고 들어가기 때문이다. 그래서 **커밋은 하지 않되,
이 위험을 지시서와 보고에 명시하고 SPEC 에 기대 동작을 남기는 것**으로 대신한다. 회귀를
잡는 자리는 커밋이 아니라 SPEC 이다.

## 이번에 손대지 않는 것

- **서명/손쉬운 사용 권한.** `security find-identity -v -p codesigning` 이 0 valid 를 돌려주는
  반쪽 상태는 별도 큐 항목 `2026-09-05-2346-condition-mate-signing-accessibility-loss` 의
  것이다. 이번 침묵의 원인이 아니었다 — 원인은 위에 적은 제스처 게이트 하나로 완전히
  설명되고, 로그가 `on:true`(활동 감지가 되어 세션이 켜져 있었다는 뜻)를 찍고 있었으므로
  권한 소실 경로가 아니다. 그래서 이 항목에서는 건드리지 않는다.
- **커밋.** 위 사유로 하지 않는다.
- **EP-21 타임존 작업.** `docs/specs/SPEC.md` 의 미커밋 EP-21 항목이 BGMPlayerContent 1 곳을
  같이 고쳤다고 적고 있는데, 확인해 보니 그 수정은 작업트리에 멀쩡히 살아 있다
  (`isoDisp` 참조 있음, 옛 `slice(0,16)` 표현 없음). 사운드 수정이 그것을 덮어쓰지 않았다.
  다른 항목이므로 손대지 않는다.

## 무엇이 되면 끝인가

1. 원인이 코드 한 자리로 특정되어 있고 근거가 로그로 붙어 있다. ✔
2. 지금 도는 바이너리가 무엇인지 확정되어 있고 그 안에 수정이 들어갔음이 확인되어 있다. ✔
3. 소리가 실제로 스피커로 나간다는 것이 앱 자기 보고가 아닌 외부 증거로 확인되어 있다. ✔
4. 재생이 곡이 바뀌어도 유지되고, 끼워진 BGM 탭이 두 번째 소리 출처가 되지 않으며, 음소거
   설정이 이 자동 시작으로 무시되지 않는다 — `lion-condition-mate-worker-qa` 의 판정으로
   확인한다.
5. 이 기대 동작이 SPEC 에 항목으로 남아 다음 회귀를 잡는다.

## 검증 결과 — `lion-condition-mate-worker-qa` (읽기 전용, 2026-09-06)

도는 인스턴스(pid 5544)를 건드리지 않고 로그와 코드로만 판정했다. 네 항목 전부 PASS.

1. **재생이 유지되는가 — PASS.** pid 5544 의 `audio-probe` 124 행 전수 파싱. `err` 는 전 행
   `null`. `paused:true` 는 프로세스 수명 첫 10 초의 4 행뿐이고 그때는 디렉터가 아직 첫 곡을
   못 정한 상태(`lastNow:null, curTrack:null`)라 정상적인 콜드스타트다. 곡이 네 번
   바뀌었고(158 → 16 → 78 → 91) 매 전환마다 `currentTime` 이 0 근처에서 다시 3 초 폴링당 3 초
   씩 올라간다. `curTrack.id` 와 `lastNow.id` 가 두 폴링 이상 어긋난 구간은 0 이다.
2. **두 번째 소리 출처가 생겼는가 — PASS(코드 판정).** 로그에 이 pid 의 소유권 선언이 딱 한
   번(`app window owns audio=true -> native muted=true`, 00:41:44) 있고 프로세스 수명 내내
   뒤집히지 않는다. `EMBEDDED` 가드 셋(`:906` 정의, `:951` nativeMute, `:1016` bgmAutoStart)이
   그대로 살아 있고, 수정된 줄도 `EMBEDDED` 인 사본에는 여전히 `engaged` 를 요구한다.
   **한계: 끼워진 iframe 의 `<audio>` 상태를 라이브로 직접 들여다보지는 못했다.** 그러려면
   창의 모드나 탭을 바꿔야 해서 라이언이 보고 있는 창을 건드리게 된다. 이 절반은 코드 판정이다.
3. **음소거가 여전히 지켜지는가 — PASS(코드 판정).** `refreshNow()` 는 `:1083` 에서 서버의
   `now.muted` 로 음소거를 먼저 맞춘 뒤에야 `:1114` 의 재생 분기로 간다. `engage()` 는
   `engaged` 와 그래프와 `ctx.resume()` 만 만지고 `muted`/`outMute` 를 건드리지 않는다.
   실제 소리 크기는 `outMute` 게인 하나가 정하고 그 값은 `outGainValue()`(`:892`)
   = `muted ? 0 : ...` 다. `ensureGraph()` 는 멱등이고 생성 시점에 이미 `outGainValue()` 를
   넣는다("Honors a mute chosen before the graph existed"). 라이언의 실제 음소거 상태를
   토글해서 시험하지는 않았다.
4. **작업트리를 되돌리면 무음이 돌아오는가 — 확인됨, 그렇다.** `git show HEAD:` 판은
   `loadTrack(..., engaged)` 와 `if(engaged && audioEl.paused)` 둘 다 `EMBEDDED` 구분 없이
   `engaged` 에만 걸려 있다. 전용 webview 는 제스처를 받을 일이 없으므로 `engaged` 가 영원히
   false 다.

## SPEC 에 무엇을 반영했는가

QA 는 새 항목 `BGMACT-9` 신설을 제안했다. **채택하지 않고 대신 기존 두 항목을 고쳤다.**
근거는 `BGMACT-1` 의 제목이 이미 "zero-click autoplay" 로 이번 계약과 정확히 같은 것이라,
같은 계약을 주장하는 항목이 둘이 되면 다음에 반드시 갈라지기 때문이다. 이 파일의 관행도
(EP-19/EP-20 처럼) 지우지 않고 날짜와 함께 제자리에 덧붙이는 쪽이다.

- **`BGMACT-1`** (`docs/specs/SPEC.md:435`) — "2026-09-06 4차: 회귀 후 재수정" 블록을 덧붙였다.
  2026-07-06 PASS 는 그 날짜 기준으로 참이므로 지우지 않고 그대로 뒀다. 원인, 수정 위치,
  `engage()` 를 `play()` 앞에 두는 순서가 음소거 우회를 막는다는 것, 그리고 **강화된 Verify** —
  앱의 자기 보고(`playing:true`, 화면의 "재생 중")는 소리의 증거가 아니며 앱 밖 신호
  (`pmset` 의 audio-out assertion, WebKit GPU 프로세스의 CoreAudio 로드, 어느 바이너리가 도는지)
  를 반드시 같이 봐야 한다는 것을 적었다. **이 항목이 2026-07-06 에 PASS 로 적혀 있었는데도
  며칠짜리 무음을 못 잡은 이유가 바로 검증법이 앱 안만 봤기 때문이다.**
- **`BGMACT-3`** (`docs/specs/SPEC.md:488`) — `EMBEDDED`/외부 탭으로 범위를 한정했다. 조건 없던
  옛 표현 "잡기 전까지는 네이티브가 계속 들리며 이 화면은 조용히 큐만 잡는다" 가 이번 침묵을
  만든 전제다. 창이 열려 있는 동안 네이티브는 음소거이므로 창의 전용 webview 에서는 그 말이
  거짓이고, "조용히 큐만" 이 곧 무음이었다.

## 1초 요약

요구 — 컨디션 메이트에서 현재 지금 사운드가 안 난다.
문제 — 창의 유일한 오디오 주인인 BGM webview 가 오지 않을 사용자 클릭을 기다리느라 `play()` 를 한 번도 부르지 않았고, 네이티브는 소유권 때문에 이미 음소거라 소리의 출처가 0 개였다 — 그런데 앱은 스스로 "재생 중" 이라 보고해서 결함이 며칠 안 보였다.
완성 — 전용 BGM 창이 제스처 없이 재생을 시작해 `audio-probe` 가 `paused:false` 를 유지하고 `coreaudiod` 가 audio-out 자원을 잡은 상태이며, 그 기대가 SPEC 항목으로 남아 있다.
