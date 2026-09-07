import AppKit
import Draw
import GUI
import Integrations
import Jira
import Slack
import WebCLI
import WebKit

// Central coordinator. Owns every subsystem and runs a single 1 Hz heartbeat
// that drives time accumulation, session gating, and the status-bar label.
// One status item, one heartbeat timer — intentionally minimal.
final class AppDelegate: NSObject, NSApplicationDelegate {

    let store = TimeStore()
    let activity = ActivityMonitor()
    let library = BPMLibrary()
    let bgmTags = BGMTags()
    let audio = AudioEngine()
    let activityLog = ActivityLog()
    let reviewStore = ReviewStore()
    let trackPrefs = TrackPreferenceStore()
    let trackEvents = TrackEventLog()
    let trackPlayStats = TrackPlayStatsStore()
    let bgmPlan = BGMPlanMap()
    let boredom = BoredomRotation()
    let pluginStore = PluginStore()
    let drawOverlay = DrawOverlayController()
    let equipment = EquipmentStore()
    let chatStore = ChatStore()
    let cameraWatch = CameraMonitor()
    private(set) var director: ConditionDirector!

    // Local dashboard web server (loopback only, started on demand).
    private lazy var dashboard = DashboardServer(
        html: { DashboardContent.html(lastView: Settings.shared.lastView, doneCutoff: Settings.shared.doneCutoff, uiPrefs: Settings.shared.uiPrefs) },
        data: { [weak self] in self?.dashboardData() ?? "{}" },
        live: { [weak self] in self?.liveData() ?? "{}" },
        post: { [weak self] path, body in self?.handlePost(path, body) ?? "{}" },
        file: { [weak self] path in
            if path.hasPrefix("/bgm-audio/") { return self?.serveBGMAudio(path) }
            if path.hasPrefix("/exhaust-audio/") { return self?.serveExhaustAudio(path) }
            if path.hasPrefix("/chat-img/") { return self?.serveChatImage(path) }
            if path.hasPrefix("/task-file") { return self?.serveTaskFile(path) }
            if path.hasPrefix("/api/debug/snapshot") { return self?.serveSnapshot(path) }
            if path.hasPrefix("/api/debug/screens/img") { return self?.serveScreenImage(path) }
            if path.hasPrefix("/api/debug/diag/export") { return self?.serveDiagCSV() }
            return self?.serveEvidence(path)
        },
        page: { [weak self] path in
            if path.hasPrefix("/bgm-timeline-test") { return BGMTimelineTestContent.html() }
            if path.hasPrefix("/session-continue-test") { return SessionContinueTestContent.html() }
            if path.hasPrefix("/lounge-break-test") { return LoungeBreakTestContent.html() }
            if path.hasPrefix("/bgm-player") { return BGMPlayerContent.html() }
            if path.hasPrefix("/bgm-plan") { return BGMPlanContent.html() }
            if path.hasPrefix("/equipment") { return EquipmentContent.html() }
            if path.hasPrefix("/slack-translate") { return SlackTranslateContent.html() }
            // NOTE: must precede the generic "/goal" prefix below, which would swallow it.
            if path.hasPrefix("/goal-add") { return GoalAddContent.html(serverCtx: Settings.shared.gaComposerJSON(),
                                                                        tallyHist: Settings.shared.gaTallyHistJSON(),
                                                                        embed: path.contains("embed=1")) }
            if path.hasPrefix("/goal") { return self?.goalPage(path) }
            if path.hasPrefix("/worker-log") { return self?.workerLogAllPage(path) }
            if path.hasPrefix("/worker") { return self?.workerLogPage(path) }
            // NOTE: must precede "/cron" — it doesn't share the prefix today, but the
            // device page is the more specific route and belongs above it either way.
            if path.hasPrefix("/device-cron") { return self?.deviceCronPage(path) }
            if path.hasPrefix("/cron") { return self?.cronPage() }
            if path.hasPrefix("/agents") { return AgentsContent.html() }
            // 옛 이름(/orchestration)으로 들어온 북마크와 열어 둔 탭은 404 로 맞히지 않는다 —
            // 사용자에게는 기능이 사라진 것으로 보이기 때문이다. 서버 헬퍼가 페이지를 200 고정으로
            // 내보내므로(DashboardServer.swift) 302 대신 meta refresh 문서 한 장이 변경 폭이 가장 작다.
            // 새 경로보다 위에 둔다 — hasPrefix 매칭이라 목록 순서가 곧 우선순위다.
            // API 쪽(/api/orchestration)에는 이 이정표를 두지 않는다. 호출자가 저장소 안에 둘뿐이고
            // 둘 다 같은 변경에서 고치므로, 별칭을 남기면 다음 사람이 어느 쪽이 진짜인지 모른다.
            if path.hasPrefix("/orchestration") {
                return "<!doctype html><html lang=\"ko\"><head><meta charset=\"utf-8\">"
                     + "<meta http-equiv=\"refresh\" content=\"0;url=/loop-engineering\">"
                     + "<title>루프 엔지니어링</title></head><body>"
                     + "<p>이 페이지는 <a href=\"/loop-engineering\">/loop-engineering</a> 으로 옮겼습니다.</p>"
                     + "</body></html>"
            }
            if path.hasPrefix("/loop-engineering") { return LoopEngineeringContent.html() }
            // 위임 이슈 목록(/issues) — lion-work-queue 의 트랙 카드를 읽어 완료·미완료를 보인다.
            if path.hasPrefix("/issues") { return IssuesContent.html() }
            if path.hasPrefix("/breakdown") { return self?.breakdownPage(path) }
            return self?.transcriptPage(path)
        },
        loopFeed: { [weak self] in self?.loopQueueJSON() ?? "{}" },
        chat: { [weak self] in self?.chatJSON() ?? "{}" },
        apiGet: { [weak self] path in
            // All four feeds carry the scope in the query (?seq=NN[&task=…]); an empty/absent
            // task yields a goal scope, so existing seq-only links keep hitting the goal path.
            // NOTE: must precede the generic "/api/goal/chat" prefix below.
            if path.hasPrefix("/api/goal/chat2/state") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"running\":false,\"state\":\"none\",\"at\":0}" }
                let key = scope.key + (path.contains("sess=1") ? "|sess" : "")
                return self?.chat2StateJSON(key)
            }
            // Distinct prefix from "/api/goal/chat" and "/api/goal/sessions" ("session/" vs
            // "sessions"), so its position among the goal GET branches is free.
            if path.hasPrefix("/api/goal/session/history") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"source\":\"none\",\"messages\":[]}" }
                return self?.sessionHistoryJSON(scope)
            }
            if path.hasPrefix("/api/goal/chat") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"messages\":[]}" }
                return self?.goalChatJSON(scope)
            }
            if path.hasPrefix("/api/goal/definition") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"text\":\"\"}" }
                let kind = URLComponents(string: "http://x" + path)?.queryItems?
                    .first(where: { $0.name == "kind" })?.value ?? "core"
                return self?.goalDefinitionJSON(scope, kind: kind)
            }
            if path.hasPrefix("/api/goal/sessions") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"sessions\":[]}" }
                return self?.goalSessionsJSON(scope)
            }
            if path.hasPrefix("/api/sessions/recent") {
                let scope = AppDelegate.Scope.from(query: path)
                guard scope.seq > 0 else { return "{\"sessions\":[]}" }
                return self?.recentSessionsJSON(scope)
            }
            if path.hasPrefix("/api/cli/sessions") {
                return self?.cliSessionsJSON()
            }
            if path.hasPrefix("/api/skills/history") {
                return self?.skillHistoryJSON()
            }
            if path.hasPrefix("/api/skills") {
                return self?.skillsJSON()
            }
            // 플러그인 페이지(레일 오버레이) — /data.json의 plugins와 동일 payload를 어느
            // 페이지에서든 읽을 수 있게 독립 GET으로 노출한다.
            if path.hasPrefix("/api/plugins") {
                guard let store = self?.pluginStore else { return "{\"plugins\":[]}" }
                return "{\"plugins\":" + store.pluginsJSON() + "}"
            }
            // 에이전트 페이지(/agents)의 인벤토리 — 전역 + 스킬 하네스 + 프로젝트별 정의를 한 번에.
            // NOTE: must precede the generic "/api/agents" prefix below, which would swallow it.
            if path.hasPrefix("/api/agents/inventory") {
                return self?.agentInventoryJSON()
            }
            if path.hasPrefix("/api/agents") {
                return self?.agentsJSON()
            }
            // 루프 엔지니어링 페이지(/loop-engineering)의 단일 피드 — 병목 지수·열려 있는 대기·프로젝트별 라우트.
            // 옛 경로 /api/orchestration 에는 별칭을 남기지 않는다 — 404 가 맞다. 자세한 이유는 위 페이지 라우트의 주석.
            if path.hasPrefix("/api/loop-engineering") {
                // 세션 원장 — 어떤 세션이 어느 루프를 돌리려고 열렸는지, 어디까지 분석했는지.
                if path.hasPrefix("/api/loop-engineering/sessions") { return LoopSessionLedger.json(path) }
                // 세션 한 개를 사람이 읽을 수 있게 줄인 것 (목록에서 한 회차를 눌렀을 때)
                if path.hasPrefix("/api/loop-engineering/session") { return LoopSessionLedger.sessionJSON(path) }
                if path.hasPrefix("/api/loop-engineering/v2") { return LoopDefinitionStore.json() }
                return self?.loopEngineeringJSON()
            }
            // 이슈 페이지(/issues)의 단일 피드 — 위임 카드 전량 + 버킷별 카운트.
            // 읽기 전용이다. 큐 폴더에는 한 바이트도 쓰지 않는다.
            if path.hasPrefix("/api/issues") {
                // AI 검색의 결과를 물어보는 자리. **아래 상세 갈래보다 먼저 서야 한다** —
                // 아래는 `/api/issues/` 뒤의 것을 전부 카드 id 로 읽으므로, 여기서 안 가로채면
                // `search` 라는 이름의 카드를 찾다가 unknown-card 를 돌려준다.
                if path.hasPrefix("/api/issues/search") {
                    let id = URLComponents(string: "http://x" + path)?.queryItems?
                        .first(where: { $0.name == "id" })?.value ?? ""
                    return IssueSearch.poll(id: id)
                }
                // md 팝업이 본문을 읽는 자리. `search` 와 같은 이유로 **아래 상세 갈래보다 먼저
                // 서야 한다** — 안 그러면 `mdfile` 이라는 이름의 카드를 찾다가 unknown-card 가 온다.
                if path.hasPrefix("/api/issues/mdfile") {
                    let p = URLComponents(string: "http://x" + path)?.queryItems?
                        .first(where: { $0.name == "path" })?.value ?? ""
                    return self?.workQueueMarkdownRead(p)
                }
                // 세션 기록 팝업이 읽는 자리. `search`·`mdfile` 과 **같은 이유로 아래 상세
                // 갈래보다 먼저 서야 한다** — 안 그러면 `transcript` 라는 이름의 카드를 찾다가
                // unknown-card 가 온다.
                if path.hasPrefix("/api/issues/transcript") {
                    let p = URLComponents(string: "http://x" + path)?.queryItems?
                        .first(where: { $0.name == "path" })?.value ?? ""
                    return self?.workQueueTranscriptRead(p)
                }
                // `/api/issues/<id>` 는 상세, 그냥 `/api/issues` 는 목록. 상세를 갈라 둔 이유는
                // 상세가 `## 원문` 전문을 싣기 때문이다 — 목록에 섞으면 85 개 분량의 원문이
                // 새로고침마다 흐른다.
                var rest = String(path.dropFirst("/api/issues".count))
                if let q = rest.firstIndex(of: "?") { rest = String(rest[rest.startIndex..<q]) }
                let id = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !id.isEmpty {
                    return WorkQueueStore.detailJSON(id: id.removingPercentEncoding ?? id)
                }
                // ?view=archive → 보관된 것만. 기본은 보관되지 않은 것만. 아카이브는 상태값이
                // 아니라 별도의 축이라 버킷은 그대로 두고 목록에서만 가른다. 질의는 `rest` 가
                // 아니라 `path` 에서 읽는다 — `rest` 는 위에서 `?` 를 이미 잘라 냈다.
                return IssueArchiveStore.filter(
                    listJSON: WorkQueueStore.json(),
                    archivedOnly: URLComponents(string: "http://x" + path)?.queryItems?
                        .first(where: { $0.name == "view" })?.value == "archive")
            }
            // 연동 레지스트리 — 플러그인 페이지의 연동 목록과 슬랙 페이지가
            // 모두 이 하나의 payload를 읽는다 (등록 여부 + 마지막 검사 결과 + 기능 게이팅).
            // 라이브 API 호출은 하지 않는다 — 그건 POST /api/integrations/check.
            if path.hasPrefix("/api/integrations/notion/candidates") {
                return IntegrationStore.notionCandidatesJSON()
            }
            if path.hasPrefix("/api/integrations/notion/register/status") {
                let id = URLComponents(string: "http://localhost" + path)?.queryItems?
                    .first(where: { $0.name == "id" })?.value ?? ""
                guard CMKeychain.isSafeName(id) else { return "{\"ok\":false,\"error\":\"bad request\"}" }
                let url = AppPaths.base.appendingPathComponent("notion-register-\(id).json")
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else {
                    return "{\"ok\":true,\"state\":\"waiting\"}"
                }
                return text
            }
            if path.hasPrefix("/api/integrations") {
                // 슬랙 번역의 '기본' 경로는 사용자가 고른 모델에 따라 달라진다 —
                // 그 사실을 아는 쪽(Slack 플러그인)이 알려줘야 카드가 정확히 말한다.
                return IntegrationStore.statusJSON(
                    primaryOverrides: ["slack-translate": SlackTranslateStore.translationPrimaryCredentials()])
            }
            // 팀 칭찬 기록 (대시보드 Hero 탭) — agent-mustcompany /hero 스킬의 heroes.db 읽기 전용.
            if path.hasPrefix("/api/hero") {
                return HeroStore.listJSON()
            }
            if path.hasPrefix("/history.json") {
                return self?.dashboardHistory(path)
            }
            if path.hasPrefix("/tokens-accounts.json") {
                return LLMAccountStore.shared.allAccountsJSON()
            }
            if path.hasPrefix("/tokens-sessions.json") {   // /tokens.json 보다 먼저 (접두어 겹침)
                return self?.dashboardTokenSessions(path)
            }
            if path.hasPrefix("/tokens-detail.json") {     // 버킷 내용물 드릴다운
                return self?.dashboardTokenDetail(path)
            }
            if path.hasPrefix("/tokens.json") {
                return self?.dashboardTokens(path)
            }
            if path.hasPrefix("/api/bgm/now") {
                return self?.bgmNowJSON()
            }
            // Slack 👀 번역함 feed (the /slack-translate page): daemon-appended
            // items.jsonl + app-owned done map (see SlackTranslateStore).
            if path.hasPrefix("/api/slack/items") {
                return SlackTranslateStore.itemsJSON()
            }
            // slack-translate 액션 로그 (디버그 패널) — 모든 액션 + 소요시간.
            if path.hasPrefix("/api/slack/actions") {
                let limit = URLComponents(string: "http://x" + path)?.queryItems?
                    .first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 200
                return SlackActionLog.recentJSON(limit: limit)
            }
            // 워크스페이스 커스텀 이모지 — 이모지 고르기 팝업이 기본 세트 뒤에
            // 붙여 보여준다 (emoji:read 없으면 빈 목록, 1시간 캐시).
            if path.hasPrefix("/api/slack/emoji") {
                return SlackTranslateStore.customEmojiJSON()
            }
            // 디버그 모드(버그 수집) 상태 — 위젯 밖 surface(진단 페이지·QA)가 같은 진실을 읽는다.
            if path.hasPrefix("/api/debug/capture/status") {
                return DebugCapture.shared.statusJSON()
            }
            // 액션 로그 feed (the /actions page): last N user actions + BGM reactions.
            if path.hasPrefix("/api/actions") {
                let limit = URLComponents(string: "http://x" + path)?.queryItems?
                    .first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 500
                return ActionLog.shared.recentJSON(limit: limit)
            }
            // 전략3 plan map + planner context (current slot, real theme folders).
            if path.hasPrefix("/api/bgm/plan") {
                return self?.bgmPlanJSON()
            }
            // Shared challenge+mute state for any surface that polls it directly (the rail's
            // challenge dial). Includes elapsed active seconds so a page loading mid-session shows
            // the right time.
            if path.hasPrefix("/api/session/state") {
                return self?.sessionStateJSON()
            }
            // 장비+숙련도 state (levels, market inflation, award ledger + plugin list)
            // for the /equipment page and the rail's settings-menu level chip.
            if path.hasPrefix("/api/equipment") {
                return self?.equipmentJSON()
            }
            // Storage locations for the rail's 설정 menu (data dir, BGM folder, Claude sessions).
            if path.hasPrefix("/api/settings/paths") {
                return self?.settingsPathsJSON()
            }
            // 표시 타임존 설정 (rail ⚙️설정) — 저장은 항상 epoch(UTC), 표시만 이 tz를 따른다.
            if path.hasPrefix("/api/settings/timezone") {
                return self?.timezoneJSON()
            }
            // 메모장 칸(담당·팀·프로젝트) 태그 검색 — 타이핑이 2초 멎으면 패드가 한 번 부른다.
            // /api/memo 보다 먼저 봐야 한다(접두어가 겹친다).
            if path.hasPrefix("/api/memo/tags") {
                let q = URLComponents(string: "http://x" + path)?.queryItems
                return self?.memoTagsJSON(kind: q?.first(where: { $0.name == "k" })?.value ?? "",
                                          query: q?.first(where: { $0.name == "q" })?.value ?? "")
            }
            // 메모장 지난 판 목록 — 패드의 히스토리 메뉴가 열릴 때 읽는다(최신순).
            // /api/memo 보다 먼저 봐야 한다(접두어가 겹친다).
            if path.hasPrefix("/api/memo/history") {
                return self?.memoHistoryJSON()
            }
            // 메모장 'AI로 정리해서 복사' 잡 목록 — 레일의 'AI 정리' 줄이 3초마다 읽는다.
            // ?id=… 면 그 잡의 결과 전문(팝업이 열릴 때 한 번).
            // /api/memo 보다 먼저 봐야 한다(접두어가 겹친다).
            if path.hasPrefix("/api/memo/tidy") {
                let q = URLComponents(string: "http://x" + path)?.queryItems
                if let id = q?.first(where: { $0.name == "id" })?.value, !id.isEmpty {
                    return MemoTidyStore.shared.resultJSON(id: id)
                }
                return MemoTidyStore.shared.jsonPayload()
            }
            // 메모장 부모 칸 후보 — 칸에 들어오면 패드가 한 번 부른다: 최근 쓴 부모(MRU)
            // 가 맨 위, 그 아래 이 줄 제목에 대한 AI 추천(ParentSuggest.rank).
            // /api/memo 보다 먼저 봐야 한다(접두어가 겹친다).
            if path.hasPrefix("/api/memo/parent-suggest") {
                let q = URLComponents(string: "http://x" + path)?.queryItems
                let title = q?.first(where: { $0.name == "title" })?.value ?? ""
                let no = q?.first(where: { $0.name == "no" })?.value.flatMap(Int.init) ?? 0
                return self?.memoParentSuggestJSON(title: title, no: no)
            }
            // 메모장 (전역 1개 공유) — 페이지에 마운트된 MemoPad 가 로드 시 1회 읽는다.
            if path.hasPrefix("/api/memo") {
                return self?.memoJSON()
            }
            // 전역 디버그 버튼 노출 여부 (rail ⚙️설정 토글).
            if path.hasPrefix("/api/settings/debug-buttons") {
                return "{\"on\":\(Settings.shared.debugButtons)}"
            }
            // Claude CLI 연결 설정 (rail ⚙️설정) — 자동(로컬 OAuth) 또는 게이트웨이.
            if path.hasPrefix("/api/settings/gateway") {
                return self?.settingsGatewayJSON()
            }
            // 네트워크 진단(DiagProbe) 대상 호스트 목록 — 진단 탭에서 편집.
            if path.hasPrefix("/api/settings/diag-hosts") {
                return self?.diagHostsJSON()
            }
            // 네트워크 진단 스냅샷 피드 (최근 실행 결과, 최신순).
            if path.hasPrefix("/api/debug/diag/list") {
                return DiagStore.shared.recentJSON(limit: 100)
            }
            // 0.5s 화면 추적 로그(무엇을 보고 있었나) 조회 — 최신 window, oldest first.
            if path.hasPrefix("/api/debug/view-trace/list") {
                let limit = URLComponents(string: "http://x" + path)?.queryItems?
                    .first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 2000
                return ViewTrace.shared.recentJSON(limit: limit)
            }
            // TEMPORARY: Korean-IME/xterm diagnostic tap readback. Remove with Core/IMEDebugLog.swift.
            if path.hasPrefix("/api/debug/ime-log/list") {
                let limit = URLComponents(string: "http://x" + path)?.queryItems?
                    .first(where: { $0.name == "limit" })?.value.flatMap(Int.init) ?? 4000
                return IMEDebugLog.shared.recentJSON(limit: limit)
            }
            // 화면 카탈로그 (UX/UI 개선용 화면 상태 전수 기록) — 컨디션 페이지 '화면 카탈로그' 탭.
            if path.hasPrefix("/api/debug/screens/list") {
                return ScreenCatalog.shared.listJSON()
            }
            // UXUI 사이트맵 (UXUI 관리 워커가 main 갱신 시 코드에서 재생성·설치).
            if path.hasPrefix("/api/debug/screens/sitemap") {
                return ScreenCatalog.shared.sitemapJSON()
            }
            // In-app update availability for the rail's 업데이트 button (local-source model).
            if path.hasPrefix("/api/update/check") {
                return self?.updateCheckJSON()
            }
            // Local git branch list for one working folder (목표 추가 composer's 브랜치 칩) —
            // must be matched BEFORE the generic /api/folders prefix below.
            if path.hasPrefix("/api/folders/branches") {
                return self?.folderBranchesJSON(path)
            }
            // Preset working-folder list for the 목표 추가 composer (project dirs under the
            // workspace root), so a goal can be told which folder to run in.
            if path.hasPrefix("/api/folders") {
                return self?.foldersJSON()
            }
            if path.hasPrefix("/api/bgm/stats") {
                return self?.bgmStatsJSON(path)
            }
            // 전략4 · 상태 인지형 (observe-only): per-plan-slot hit/miss scores derived
            // from actions.jsonl on every read — nothing is stored or written.
            if path.hasPrefix("/api/bgm/slot-scores") {
                return self?.bgmSlotScoresJSON()
            }
            // 전략8 · 보링 로테이션: current roster (신선/단골/벤치) + epoch indexes.
            if path.hasPrefix("/api/bgm/boring") {
                return self?.bgmBoringJSON()
            }
            if path.hasPrefix("/api/bgm/list") {
                return self?.bgmListJSON()
            }
            // 전략7 · 장소·컨디션 preset catalog + current pick (액티비티 탭 selector).
            if path.hasPrefix("/api/bgm/venue") {
                return self?.bgmVenueJSON()
            }
            // Lightweight worker snapshot for the standalone 크론(/cron) page — just the
            // workers array, so that page never has to poll the heavy /data.json.
            if path.hasPrefix("/workers.json") {
                return self?.workersJSON()
            }
            // Periodic jobs registered on the Mac itself (launchd + crontab) — the '이 디바이스'
            // tab of the 크론 page. Scanned off the main thread and cached inside the scanner.
            if path.hasPrefix("/device-cron.json") {
                return DeviceCronScanner.shared.snapshotJSON()
            }
            return nil
        },
        sse: { [weak self] path, channel in
            // Live action-log feed: the channel subscribes to ActionLog and every append
            // is pushed instantly (the 액션로그 view renders without waiting for a poll).
            if path.hasPrefix("/api/actions/stream") { ActionLog.shared.subscribe(channel) }
            else { self?.handleChat2Stream(path, channel) }
        }
    )
    private var minuteInput = 0   // input-present seconds while working (any app), this minute
    private var minuteAppSeconds: [String: Int] = [:] // frontmost seconds per app this minute
    private var minuteSiteSeconds: [String: Int] = [:] // browser-domain seconds this minute
    private var chromeDomain = ""              // cached active-tab domain (refreshed periodically)
    private var siteRefreshing = false

    private var statusItem: NSStatusItem!
    private var gauge: LightningGauge!
    private var menuController: MenuController!
    // Single native app window (WKWebView) hosting both the dashboard and the BGM player, switched
    // by an in-window toggle. Replaces the old browser-based dashboard entirely — no web browser.
    private lazy var appWindow = makeAppWindow()   // GUI module; app wiring in UI/GUIBridge.swift
    // While the app window is OPEN (in EITHER .dashboard or .bgm mode) it owns audio output: native
    // BGM stays muted the whole time (not just reactively), so the two never overlap ("음악이 두
    // 번"). Released (native unmuted) only when the window closes. See AppWindowController's file
    // header for why: the BGM webview keeps playing regardless of visible mode, so ownership must
    // follow "window open", not "mode == .bgm" — the earlier mode-based rule left native audible
    // in .dashboard mode while the BGM webview kept playing underneath (double audio).
    private var windowOwnsAudio = false

    // 받아쓰기(superwhisper) 중 음악을 눌러 두는 감시자와 그 현재 상태. 상태를 따로 들고 있는
    // 이유는 창이 나중에 열려 오디오를 넘겨받을 때(onOwnAudio) 그 시점의 값을 웹뷰에 밀어
    // 넣어야 하기 때문 — 말하는 도중에 창을 열면 웹뷰만 원래 볼륨으로 시작해 버린다.
    private let voiceDictation = VoiceDictationMonitor()
    private var voiceDucked = false
    // App-wide keyboard shortcuts (⌘M mute / ⌘S start·stop challenge). A LOCAL event monitor fires
    // only while the app is active and for ANY of its windows/pages — exactly "앱을 활성화한 뒤 어느
    // 페이지에서든" — without the system-wide Accessibility grant a global monitor would need.
    private var shortcutMonitor: Any?
    // 전역 음소거 단축키 (⌃⌘M). Registered with the OS hotkey registry (GUI/GlobalHotKey), so it
    // fires from any app WITHOUT the Accessibility grant and never falls through to the frontmost
    // app. Held here because releasing the object unregisters the chord.
    private var globalMuteHotKey: GlobalHotKey?
    private var heartbeat: Timer?
    private var tick: Int = 0
    // Smooth menu-bar APM: the heartbeat only fires at 1 Hz, so reading instantAPM
    // straight into the title makes the number jump in big steps every second. A
    // dedicated ~20 Hz timer glides a displayed value toward the live target so the
    // digit rises and falls smoothly instead of stuttering.
    private var titleTimer: Timer?
    private var displayedAPM: Double = 0
    // Last values written to the worker log, so high-frequency workers log only on
    // change instead of one line per fire (see onHeartbeat).
    private var lastLoggedStatus = ""
    private var lastLoggedDomain = ""

    // Menu-bar gauge mode, mirroring the dashboard toggle. 스포츠 = live APM that
    // bounces every second (focus/fun early on); 타임 = the focus clock (pride in
    // the total once the day is long). Auto-defaults by today's tracked time until
    // the user picks one from the menu (menuBarModeUserSet), then the choice sticks.
    enum MenuBarMode { case sports, time }
    private(set) var menuBarMode: MenuBarMode = .sports
    private var menuBarModeUserSet = false
    // 토탈 시간 (work span), recomputed from samples periodically so the menu-bar clock
    // matches the dashboard "토탈 시간" card. Base = sum of sub-6h gaps between anchors
    // (minute-grained); while working we add the live seconds since the last anchor so
    // the clock ticks every second (HH:MM:SS). Samples are per-minute, hence the split.
    private var totalSpanBaseSec: Double = 0
    private var lastAnchorT: Int = 0
    private var totalSpanCacheAt: Date = .distantPast

    // 업무 시작 감지 (6h-갭 블록) — 컨디션맵의 업무시작 감지와 같은 규칙을 Swift쪽에서
    // 재현한다: 어제+오늘 분단위 샘플의 앵커(입력 or 미팅) 사이에 6h+ 공백이 나오면 새
    // 업무 블록, 마지막 블록의 첫 앵커가 "현재 업무 시작"이다. 전략6 시작 컨텍스트 선곡
    // (ConditionDirector)과 액션로그의 workMin 스탬프가 이 값을 읽는다. 파일 파싱이라
    // 60s 캐시 + 락 (액션로그 append는 대시보드 서버 스레드에서도 들어온다).
    private let workBlockGap = 6 * 3600
    private var workStartCached: Int = 0        // 0 = 앵커 없음 / 6h+ 쉬고 새 블록 시작점
    private var workStartCacheAt = Date.distantPast
    private let workStartLock = NSLock()

    // 토탈 시간 to display now: minute-grained base + live seconds since the last active
    // minute while working (frozen otherwise, and a 6h+ tail is 퇴근, so it stops).
    private func totalSpanDisplaySec() -> Double {
        guard lastAnchorT > 0 else { return totalSpanBaseSec }
        let tail = Date().timeIntervalSince1970 - Double(lastAnchorT)
        let live = (isWorking && tail < 8 * 3600) ? max(0, tail) : 0
        return totalSpanBaseSec + live
    }

    // Master switch (Hubstaff-style Start/Stop Working). Tracking + music only
    // run while this is on. Auto-started on launch (see applicationDidFinishLaunching);
    // the menu button remains available to pause/resume mid-session.
    // Single source of truth for the two live session flags (challenge on/off + music mute),
    // shared by every surface — gauge widget, dropdown menu, dashboard, BGM player. See
    // ChallengeSession. start/stopWorking and the mute path write through this object.
    let session = ChallengeSession()
    // Read-compat shim: many call sites read `isWorking` (is the challenge live?). The value now
    // lives in `session`; this keeps those sites unchanged while there is one owner of the state.
    var isWorking: Bool { session.isRunning }
    private(set) var sessionSeconds: Double = 0   // active seconds this session
    // Pomodoro completion is a WALL-CLOCK judgement (25 real minutes), independent of the
    // activity-gated sessionSeconds above — 포모도로는 벽시계다. The server owns the check
    // (heartbeat), so it holds regardless of whether any webview is alive to observe it.
    private(set) var sessionStartedAt: Date?
    // 완주 후 수확 오브 대기 — server-owned so a rail reload can't lose the reward moment.
    private(set) var pomodoroRewardPending = false
    let pomodoroStats = PomodoroStats()
    // 25 wall-clock minutes; CM_POMODORO_SECS shrinks it for e2e (same pattern as CM_DWELL).
    static let pomodoroWallSeconds =
        Int(ProcessInfo.processInfo.environment["CM_POMODORO_SECS"] ?? "") ?? 25 * 60
    // The active pomodoro's target seconds. The rail's 25분 chip is re-tappable to cycle its
    // duration (25·45·50분) for deeper focus; the chosen value rides the start request and the
    // completion judgement below runs against THIS, not the static default. Env CM_POMODORO_SECS
    // still wins (e2e determinism) — when it is set, the rail's choice is ignored.
    private(set) var pomodoroTargetSecs = AppDelegate.pomodoroWallSeconds
    private(set) var liveStatus = "정지"

    // Per-app BGM strategy: an app's profile takes over once it has been the
    // frontmost window for at least `dwellThreshold` seconds. (CM_DWELL for tests.)
    private let dwellThreshold = Int(ProcessInfo.processInfo.environment["CM_DWELL"] ?? "") ?? 60
    private var lastFrontBundle: String?
    private var frontStableSeconds = 0
    private var committedProfileKey = ""
    private(set) var activeAppLabel = ""

    // One-shot guard so the "no music folder" alert appears at most once per
    // playback session (the heartbeat runs at 1 Hz; nagging every tick would
    // freeze the menu bar). Re-armed when the session ends.
    private var musicFolderPromptShown = false

    // --- Waiting (응답 대기) detection (see .doc/waiting-signal-policy.md) ---
    // Safety-net timeout: an in_progress session whose transcript has not grown for
    // this many seconds is treated as parked-waiting, banking its time. Large enough
    // not to mistake a long-running tool for a stall; tunable (CM_WAIT_TIMEOUT, tests).
    private let waitTimeout = Double(ProcessInfo.processInfo.environment["CM_WAIT_TIMEOUT"] ?? "") ?? 120
    // Real-time "is it running?" window (priority 1): a transcript touched within this many
    // seconds means the agent is working right now, so the goal is promoted to in_progress
    // immediately — even when the active hook never fires. Smaller than waitTimeout so the
    // 진행중 → 응답 대기 demotion has hysteresis (no flicker for a session that writes every
    // few seconds). Tunable (CM_ACTIVE_WINDOW).
    private let activeWindow = Double(ProcessInfo.processInfo.environment["CM_ACTIVE_WINDOW"] ?? "") ?? 15
    // Recency window for retroactively reconciling a stranded backlog session goal back to
    // 응답 대기 (slice of design B). Only sessions touched within this window are revived,
    // so an ancient, abandoned session is never resurrected. Tunable (CM_RECONCILE_WINDOW).
    private let reconcileWindow = Double(ProcessInfo.processInfo.environment["CM_RECONCILE_WINDOW"] ?? "") ?? 21600
    // Reap window for an abandoned 응답 대기 goal: a session parked for a human whose
    // transcript stays silent this long is treated as abandoned (the user closed it, or
    // forked it into a new session_id) and retired to 취소(cancelled). Without this, waiting
    // is a one-way trap — priority-1 can't resume a transcript that never changes again and
    // SessionEnd never fires on app-close/fork — so the count grows forever and drifts from
    // Claude Code's live-session view. cancelled (not done) keeps it out of completion metrics
    // and hidden by default. Reap is terminal (recordSession + reconcile both skip cancelled,
    // so it never bounces back), so keep this comfortably longer than a plausible human break;
    // the user can manually reopen if they return to that exact session. Tunable (CM_WAIT_REAP).
    private let waitReap = Double(ProcessInfo.processInfo.environment["CM_WAIT_REAP"] ?? "") ?? 3600
    // Per-session transcript size cache: re-parse the tail only when the file grew,
    // so an idle/waiting session costs a cheap stat, not a full read, each tick.
    private var sessionSeenSize: [String: Int] = [:]
    private var sessionPendingAsk: [String: Bool] = [:]   // last tail had an unanswered AskUserQuestion
    private var sessionTurnEnded: [String: Bool] = [:]     // last tail was a finished assistant turn (awaiting human)
    // Session ids the title-repair sweep already probed and found to have no transcript
    // anywhere (a `start`-only ghost from before the mint guard). Locating one costs a
    // full ~/.claude/projects scan, and it will never appear, so probe it once per run.
    private var titleRepairHopeless: Set<String> = []
    // Per-transcript token-by-day cache: parsing every ~/.claude/projects/*.jsonl on each
    // poll would be costly, so remember (mtime, size) -> per-day token totals and re-parse a
    // file only when it changes. Keyed by absolute path. Guarded by tokenDayLock.
    // One day's aggregate for a transcript: deduped spend, prompt-vs-output split, the
    // output further split into thinking/visible-text/tool-args (apportioned from
    // output_tokens by block character weight), and human prompt lead times (seconds
    // between the assistant's last line and the next human-typed message, ≤30 min).
    struct DayTok {
        var spent = 0        // input + output + cache_creation, counted once per message id
        var inTok = 0        // prompt side: input + cache_creation
        var outTok = 0       // output_tokens
        var thinkTok = 0     // output share attributed to thinking blocks
        var textTok = 0      // output share attributed to visible text
        var toolTok = 0      // output share attributed to tool_use arguments
        // Prompt-side sub-split (estimates; the transcript records only per-request input
        // totals, so text is char-weighted and images use the official w*h/750 formula).
        // reloadTok is the residual: inTok minus the measured three — i.e. conversation
        // re-cache + system prompt/CLAUDE.md, the part the user never typed nor attached.
        var typedTok = 0     // human-typed prompt text
        var imgN = 0         // user-attached images (count)
        var imgBytes = 0     // their raw (decoded) bytes
        var imgTok = 0       // their estimated tokens
        var toolResTok = 0   // tool_result content fed back (incl. tool-produced images)
        var reloadTok = 0    // residual: history re-cache + system prompt
        var aiSec = 0        // AI runtime: human prompt -> last AI/tool line of that turn
        var models: [String: ModelUse] = [:]   // per-model raw usage, for $-cost (client-side rates)
        var leads: [Double] = []
        var accounts: [String: Int] = [:]      // accountId -> tokens spent
        var providers: [String: Int] = [:]     // provider -> tokens spent
        // 창 점유 축 — 위의 누적 버킷과 단위가 다르다. spent 는 "창을 몇 번 채웠나"이고
        // 아래 셋은 "창을 얼마나 채웠나"라서 더하면 안 되는 값이다. 그래서 여러 파일을
        // 하루로 접는 자리에서는 합산하지 않고 비워 둔다(분포는 따로 센다).
        var ctxFinal = 0     // window occupancy at the day's last non-sidechain assistant request
        var ctxPeak  = 0     // max occupancy seen that day (non-sidechain)
        var ctxModel = ""    // model of that last request — the window we divide by
    }
    // Raw per-model usage — kept separate from the display buckets above because $-cost
    // needs cache reads (excluded from `spent`) and the cache-write TTL split (5m=1.25x,
    // 1h=2x input rate). A session can switch models mid-way (haiku -> fable), so usage
    // is keyed by message.model, never assumed uniform per session.
    struct ModelUse {
        var inTok = 0        // uncached input_tokens
        var cacheRead = 0    // cache_read_input_tokens
        var cache5m = 0      // cache_creation ephemeral_5m (fallback bucket when no detail)
        var cache1h = 0      // cache_creation ephemeral_1h
        var outTok = 0
        var effort: String = ""
        var efforts: [String: Int] = [:]
    }
    // 트랜스크립트 한 개에서 뽑히는 전부. 튜플로 늘려 가다 자리 순서를 세는 코드가 되어서
    // 이름 붙인 형으로 바꿨다. days 밖의 값들은 토큰 뷰가 쓰지 않고 루프 세션 원장이 쓴다.
    struct TranscriptFacts {
        var days: [String: DayTok] = [:]
        var title = ""
        var cwd = ""
        var prompt = ""          // 첫 사람 프롬프트 400자 — 어느 루프의 세션인가의 근거
        var firstTS: Date?       // 세션이 열린 시각
        var lastTS: Date?        // 마지막 줄이 쓰인 시각
        var turns = 0            // 어시스턴트 메시지 수
        var tools = 0            // 도구 호출 수
        var accountId = ""       // e.g. "claude:3189e304-..."
        var accountLabel = ""    // e.g. "클로드 계정 1"
        var accountColor = ""    // e.g. "#7c3aed"
        var provider = "claude"
    }
    private var tokenDayCache: [String: (mtime: Date, size: Int, facts: TranscriptFacts)] = [:]
    private let tokenDayLock = NSLock()

    // JSON for a DayTok's per-model usage map: {"claude-fable-5":{"in":..,"cr":..,"c5m":..,"c1h":..,"out":..,"effort":..},...}
    private func modelsJSON(_ models: [String: ModelUse]) -> String {
        let rows = models.keys.sorted().map { m -> String in
            let u = models[m]!
            let topEffort = u.efforts.max(by: { $0.value < $1.value })?.key ?? u.effort
            return "\(jsonString(m)):{\"in\":\(u.inTok),\"cr\":\(u.cacheRead),\"c5m\":\(u.cache5m),\"c1h\":\(u.cache1h),\"out\":\(u.outTok),\"effort\":\(jsonString(topEffort))}"
        }
        return "{\(rows.joined(separator: ","))}"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.log("LAUNCH — bundle=\(Bundle.main.bundleIdentifier ?? "nil") argv0=\(CommandLine.arguments.first ?? "?") log=\(AppLog.fileURL.path)")
        WebCLILog.sink = AppLog.log   // WebCLI target logs (PTY spawn failures 등) into app.log
        // Slack 👀 번역 plugin (Sources/Plugins/Slack, app-agnostic) — wire the app's data
        // dir, the global debug-buttons setting, and the display-timezone boot HTML.
        SlackTranslateStore.dir = AppPaths.sub("slack-translate")
        SlackTranslateStore.migrateConfigurationDefaults()
        // 표시 타임존 1회 마이그레이션 — 다른 무엇보다 먼저 돌아야 한다. 이 뒤의 모든
        // 일자 버킷(activityLog·토큰 뷰·CM_TZ 주입)이 Settings.displayTimeZone 을 읽는다.
        migrateTimeZoneKSTDefault()
        // #hero 채널 수집 파일 (slack-eyes-daemon.mjs 소유, 앱은 읽기만)
        HeroStore.slackFile = AppPaths.sub("hero").appendingPathComponent("slack.jsonl")
        // 루프 세션 원장 (Sources/ConditionMate/Plugins/Loop): 세션 트랜스크립트를 세션마다
        // 딱 한 번 읽어 "이 세션은 어느 루프의 것인가"의 근거(첫 프롬프트·cwd)와 토큰·비용을
        // 디스크에 남긴다. 파서는 토큰 뷰의 것을 그대로 꽂아 준다 — 같은 파일을 두 벌의 규칙으로
        // 세면 루프 화면과 토큰 화면의 숫자가 서로 어긋난다.
        LoopSessionLedger.storeDir = AppPaths.sub("loop-sessions")
        LoopSessionLedger.log = AppLog.log
        LoopSessionLedger.extractor = { [weak self] url, mtime, size in
            guard let self else {
                return LoopSessionLedger.Extract(days: [:], title: "", cwd: "", prompt: "",
                                                 firstDay: "", lastDay: "")
            }
            let st = self.transcriptStats(file: url, mtime: mtime, size: size)
            var days: [String: LoopSessionLedger.DaySpend] = [:]
            for (day, t) in st.days where t.spent > 0 {
                days[day] = LoopSessionLedger.DaySpend(t: t.spent, c: self.modelsCostUSD(t.models))
            }
            let keys = days.keys.sorted()
            return LoopSessionLedger.Extract(days: days, title: st.title, cwd: st.cwd, prompt: st.prompt,
                                             firstDay: keys.first ?? "", lastDay: keys.last ?? "",
                                             startTS: st.firstTS?.timeIntervalSince1970 ?? 0,
                                             endTS: st.lastTS?.timeIntervalSince1970 ?? 0,
                                             turns: st.turns, tools: st.tools)
        }
        LoopSessionLedger.start()
        SlackTranslateStore.debugButtons = { Settings.shared.debugButtons }
        SlackTranslateContent.headExtraHTML = { CMTimeFilter.bootHTML() }
        SlackTranslateContent.bodyLeadingHTML = { SessionRail.html() }
        // 지라 번역 plugin (Sources/Plugins/Jira): 크롬 익스텐션 하나만 상대하는 고정 포트
        // 로컬 브리지. Gemini 키를 브라우저에 두지 않으려고 실제 호출은 앱이 대신한다.
        JiraBridge.dataDir = AppPaths.sub("jira-bridge")
        JiraBridge.log = AppLog.log
        if !FileManager.default.fileExists(atPath: Self.jiraBridgeDisabledFlag.path) {
            JiraBridge.shared.start()
        }
        // View-trace anchor: every launch (including an update relaunch) starts the screen
        // timeline here, so "실행 → 첫 화면까지" is measurable against windowOpen/navCommit/firstPaint.
        ViewTrace.shared.native("appLaunch",
                                detail: "pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        // Test hook: CM_QUIT_AFTER=<seconds> triggers the real NSApp.terminate quit path so the
        // full shutdown sequence (applicationShouldTerminate/WillTerminate + window/audio cleanup)
        // can be exercised headlessly and inspected in app.log.
        if let s = ProcessInfo.processInfo.environment["CM_QUIT_AFTER"], let n = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + n) { NSApp.terminate(nil) }
        }
        // Single instance: terminate any older copy already running (a dev auto-reload relaunch
        // or a double-click). Two instances would each start BGM ("음악이 두 번") and one would
        // linger after the other is quit ("앱을 껐는데 위젯이 남음").
        Self.terminateOtherInstances()

        // LSUIElement (menu-bar) apps have no application main menu, so the standard editing
        // key equivalents (Cmd+C/V/X/A, Undo/Redo) are never dispatched to the responder chain.
        // That breaks paste/copy inside the WKWebView's HTML inputs (e.g. the "목표 추가" modal —
        // "붙여넣기가 안 됨"). Install a minimal Edit menu so these shortcuts reach paste:/copy:/… .
        Self.installEditMenu()

        // 전략8 · 보링 로테이션: the roster reads the LIVE library and the all-strategy
        // cumulative play totals — the accrual-strategy switch never resets "많이 들은 곡".
        boredom.tracksProvider = { [weak self] in
            self?.library.tracks.map {
                BoredomRotation.TrackInfo(key: $0.url.lastPathComponent, url: $0.url)
            } ?? []
        }
        boredom.heardSecondsProvider = { [weak self] in
            self?.trackPlayStats.totals(strategy: nil).mapValues { $0.seconds } ?? [:]
        }
        director = ConditionDirector(activity: activity, library: library, audio: audio,
                                     prefStore: trackPrefs, planMap: bgmPlan, boredom: boredom)
        // 전략6 · 시작 컨텍스트 + 액션로그 workMin: 업무 경과(6h-갭 블록)를 선곡 판단과
        // 모든 로그 라인에 공급한다 — "시작한 지 얼마나 됐는가"가 선곡의 3번째 축.
        director.workElapsedMinutes = { [weak self] in self?.workElapsedMinutes() ?? 0 }
        ActionLog.shared.workMinutesProvider = { [weak self] in self?.workElapsedMinutes() ?? -1 }
        wireDebugCapture()
        audio.targetVolume = Float(Settings.shared.volume)
        // Restore the last mute state (ChallengeSession loads it from Settings): if the sound was
        // muted when the app went down, an update/relaunch must come back muted, not playing.
        applyNativeMute()
        applySfxGate()
        if session.isMuted { AppLog.log("mute restored from last run -> muted") }
        if !Settings.shared.sfxEnabled { AppLog.log("sfx switch restored from last run -> off") }
        // 받아쓰기 덕킹: superwhisper 가 녹음하는 동안만 음악을 15% 로 눌러 둔다.
        voiceDictation.onLog = { AppLog.log("voice-duck: \($0)") }
        voiceDictation.onChange = { [weak self] on in self?.applyVoiceDuck(on) }
        applyVoiceDuckSwitch()
        // Play-time accounting: AudioEngine times each audible segment; the store accrues
        // per-track seconds/plays that feed the BGM 관리 "재생 시간 순위" section.
        audio.onSegmentEnd = { [weak self] key, title, secs in
            self?.trackPlayStats.addSeconds(key: key, title: title, seconds: secs)
        }
        audio.onTrackStart = { [weak self] key, title in
            self?.trackPlayStats.bumpPlay(key: key, title: title)
        }

        activity.start()
        // 카메라 지킴이 (camera-guard plugin): 위반 시 반응만 여기서 배선한다 — 시작/중지는
        // syncPluginWorkers가 설치 상태 + 카드 on/off(Settings.cameraGuardOn)로 게이팅.
        cameraWatch.onViolation = { msg in
            // 음소거/효과음 끔이면 소리는 삼킨다 — 아래 osascript 배너가 그대로 뜨므로 경고는 남는다.
            if !SoundEffects.shared.muted { NSSound(named: "Funk")?.play() }
            // No UNUserNotificationCenter plumbing needed: a plain banner via
            // osascript, off-main (Process launch would stall the main thread).
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e",
                    "display notification \"\(msg)\" with title \"Condition Mate\" subtitle \"카메라 꺼짐 감지\""]
                try? p.run()
            }
        }
        // 권한이 없어 재활성화가 아예 못 도는 경우. 워커 로그 warn 한 줄은 아무도 안 보므로
        // 배너로 올린다 — 2026-09-05 에 이것 때문에 "감지는 되는데 안 켜진다" 로 하루가 갔다.
        cameraWatch.onAccessibilityMissing = { msg in
            AppLog.log("camera-watch: 손쉬운 사용 권한 없음 — \(msg)")
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e",
                    "display notification \"\(msg)\" with title \"Condition Mate\" subtitle \"손쉬운 사용 권한 필요\""]
                try? p.run()
            }
        }
        // 감지 → 자동 재활성화가 실제로 닫혔을 때. 이 배너가 뜨는 것이 두 쪽이 서로
        // 연결돼 있다는 눈에 보이는 증거다 (위반 배너와 소리를 다르게 둔 이유).
        cameraWatch.onRecovered = { msg in
            if !SoundEffects.shared.muted { NSSound(named: "Glass")?.play() }
            AppLog.log("camera-watch: \(msg)")
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e",
                    "display notification \"\(msg)\" with title \"Condition Mate\" subtitle \"카메라 자동으로 다시 켬\""]
                try? p.run()
            }
        }
        reloadLibrary()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            // Monospaced digits so the APM number and clock keep a constant width —
            // the title never jiggles as the digit count changes (ofSize 0 = default).
            button.font = .monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        }
        // Lightning condition gauge: a single bolt that charges bottom-up across
        // five stages and shifts colour with the live condition (활동/개인 최고치
        // 비율). Drives only the button image; the APM/clock text is the button
        // title (updateStatusTitle).
        gauge = LightningGauge { [weak self] image in
            self?.statusItem.button?.image = image
        }
        menuController = MenuController(actions: self,
                                        state: { [weak self] in self?.menuState() ?? MenuState() })
        statusItem.menu = menuController.menu

        // In BGM mode the window owns audio: keep native muted the whole time so playback never
        // doubles up, and hand it back on the dashboard / when the window closes.
        appWindow.onOwnAudio = { [weak self] owns in
            guard let self = self else { return }
            self.windowOwnsAudio = owns
            // While the window owns audio, native stays muted regardless of the user's mute intent
            // (no double playback). When it hands audio back on close, native reflects the user's
            // mute intent (session.isMuted) rather than blindly unmuting — so ⌘M made before closing
            // is preserved.
            self.applyNativeMute()
            // The window's player starts unmuted; push the restored/current mute intent as soon as
            // it takes over so a muted user never hears a burst before the /api/bgm/now poll lands.
            if owns {
                self.appWindow.setWebMute(self.session.isMuted)
                // 말하는 도중에 창이 열렸다면 웹뷰도 눌린 채로 시작해야 한다.
                if self.voiceDucked { self.appWindow.setWebVoiceDuck(true) }
            }
            AppLog.log("app window owns audio=\(owns) -> native muted=\(self.audio.muted)")
        }
        // Closing the app window quits the entire app — the window and the menu-bar app terminate
        // together (the user's goal: "같이 종료"). Dispatched async so we don't tear down while
        // still inside the window's own windowWillClose.
        appWindow.onUserClose = { [weak self] in
            AppLog.log("app window user-closed -> quitting app (같이 종료)")
            DispatchQueue.main.async { self?.quit() }
        }

        // App-wide keyboard shortcuts, active on any page while the app is frontmost:
        //   ⌘M — 음원 뮤트 on/off      ⌘S — 챌린지 시작/중단
        // Returning nil consumes the event so it never reaches the webview (⌘S "save", ⌘M "minimize").
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NOT `self?.handleShortcut(event) ?? event`: optional chaining flattens the
            // NSEvent?? to NSEvent?, so handleShortcut's nil ("swallow") would be replaced by
            // the original event — it then reaches the WKWebView, which re-dispatches unhandled
            // key equivalents, firing the shortcut twice (mute→unmute) and beeping.
            guard let self else { return event }
            return self.handleShortcut(event)
        }

        // 전역 음소거 토글 — ⌃⌘M works from ANY app, no activation first. The local monitor above
        // only fires while this app is frontmost, which made ⌘M useless in practice: you had to
        // click the app (and in another app ⌘M just minimised ITS window). ⌃⌘M avoids both the
        // system's ⌘M "minimize" and the 드로우 plugin's left-⌥ draw gesture, so it stays clean
        // whichever app has focus. Silent if the chord is already taken by another app: the
        // in-app ⌘M and the menu item still work (no failure banner).
        globalMuteHotKey = GlobalHotKey(keyCode: 46, modifiers: [.control, .command]) { [weak self] in
            self?.toggleMute()
        }
        AppLog.log("global hotkey ⌃⌘M mute registered=\(globalMuteHotKey != nil)")

        updateStatusTitle()

        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.onHeartbeat()
        }

        // Glide the menu-bar APM digit between the 1 Hz heartbeats so it flows
        // smoothly instead of jumping. Runs in .common mode so it keeps ticking
        // while the menu is open.
        let tt = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        RunLoop.main.add(tt, forMode: .common)
        titleTimer = tt

        registerWorkers()

        // Seed one sample so the dashboard isn't empty on first open.
        activityLog.append(ActivityLog.Sample())

        // Auto-start a work session on launch: the master switch comes up ON so
        // tracking + music begin immediately (activity/idle/app gating still apply).
        startWorking()

        // Test hooks (smoke tests): start dashboard server without opening a
        // browser and print its URL.
        let env = ProcessInfo.processInfo.environment
        if let fake = env["CM_FAKE_FRONT"] { Settings.shared.addTrackedApp(fake) }
        if env["CM_DASHBOARD"] != nil {
            dashboard.start { port in
                FileHandle.standardError.write("[dashboard] http://127.0.0.1:\(port)/\n".data(using: .utf8)!)
            }
        }

        // Start the loopback server eagerly (no browser) so its port is published to
        // dashboard.port from launch and the Claude Code session hooks can reach the
        // API even before the user opens the dashboard. Idempotent: openDashboard()
        // later reuses the same listener.
        dashboard.start { _ in }

        // Guaranteed zero-click BGM: auto-open the native BGM window (WKWebView with autoplay
        // enabled) on launch so the activity BGM plays with the space effect immediately. Respect
        // the master switch — if the user turned BGM off (e.g. by closing the window), don't force
        // it back on at launch.
        // Auto-open the app on launch on the DASHBOARD (its face is now the dashboard; the condition
        // surface is reached via the rail's "시스템관리"). BGM is still turned on so the BGM
        // webview — created + parked off-view by ensureBuilt — is the live audio engine from launch,
        // playing whenever a challenge runs. (Don't gate on musicEnabled: an earlier off-state would
        // then silently skip opening the window.)
        if Settings.shared.bgmWindowEnabled {
            setBGMEnabled(true)
            dashboard.start { [weak self] port in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Dev (CM_DEV): a dev-watch rebuild relaunches the process on every save, so
                    // auto-popping the window in front here would keep covering the editor. Start
                    // the server (done above) but leave the window closed — open it from the menu
                    // bar when wanted. Opt back in for dashboard-UI sessions with CM_DEV_AUTO_OPEN=1.
                    if AppPaths.isDev && !AppPaths.devAutoOpen {
                        AppLog.log("dev mode (CM_DEV): skip launch auto-open — open the window from the menu bar")
                        return
                    }
                    self.appWindow.autoOpen(port: port, mode: .dashboard)
                }
            }
        }
        AppLog.log("bgm auto-open on launch: bgmWindowEnabled=\(Settings.shared.bgmWindowEnabled)")

        // Resume any AI-queue candidates left pending by a previous run (loadQueue already
        // reverted orphaned "analyzing" items back to pending) so the "bump out" backlog
        // keeps draining across restarts.
        if reviewStore.hasPendingAnalysis { kickAIQueueWorker() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.log("applicationWillTerminate — stopping director + audio, closing BGM window")
        store.saveIfNeeded()
        director.stop()
        audio.stop()
        activity.stop()
        // Stop the loopback server; when dashboard.port still holds OUR port this removes
        // the file so a dev-watch relaunch never leaves it pointing at this dying port.
        dashboard.stop()
        // 지라 브리지도 함께 닫는다 — 포트가 고정이라 남아 있으면 다음 실행(특히
        // dev-watch 재기동)이 같은 포트를 못 잡는다.
        JiraBridge.shared.stop()
        appWindow.closeForQuit()
        gauge?.showIdle()
        if let m = shortcutMonitor { NSEvent.removeMonitor(m); shortcutMonitor = nil }
        // Hand ⌃⌘M back to the system explicitly (a relaunching dev-watch build re-registers it).
        globalMuteHotKey?.unregister(); globalMuteHotKey = nil
        heartbeat?.invalidate()
        titleTimer?.invalidate()
        AppLog.log("applicationWillTerminate — done")
    }

    // Drain unsaved webview state (메모장 debounce 등) BEFORE letting termination proceed —
    // the dashboard server is still alive here, so the pages' final flush POST can land.
    // willTerminate then stops the server and blanks the webviews as before. ≤1.5s delay,
    // well inside apply-update.sh's 6s quit-wait. Guarded so the reply happens exactly once.
    private var quitDrained = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitDrained {
            AppLog.log("applicationShouldTerminate — reply=terminateNow (drained)")
            return .terminateNow
        }
        AppLog.log("applicationShouldTerminate — draining webviews, reply=terminateLater")
        appWindow.drainForQuit { [weak self] in
            self?.quitDrained = true
            AppLog.log("applicationShouldTerminate — drain done, resuming quit")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // Force-quit any other running copy of this app (same bundle id) so only one instance ever
    // plays BGM or owns a menu-bar item. A bare SPM binary (no Info.plist / bundle id) is skipped.
    // Build a minimal application main menu whose Edit submenu carries the standard editing
    // actions with their conventional key equivalents. AppKit only routes Cmd+C/V/X/A (and
    // Undo/Redo) to the first responder's copy:/paste:/cut:/selectAll: when a menu item exposes
    // that key equivalent. Without a main menu (the default for LSUIElement apps) those shortcuts
    // are swallowed, so pasting into the WKWebView-hosted dashboard inputs silently fails.
    private static func installEditMenu() {
        let mainMenu = NSMenu()

        // A first (app) menu is conventional but not required for key equivalents; keep it minimal.
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        // Select All is the one editing command we intercept. ⌘A here never reaches the web
        // page as a keydown — the menu sends `selectAll:` straight to the WKWebView, and WebKit
        // selects the WHOLE DOCUMENT (rail menu labels and all). Inside the 메모장 that is the
        // wrong answer twice over: the user means "this note", and the pad hides rows by CSS
        // (완료·이전 루프·다른 날·필터 밖·초집중), so a document-wide selection carries text
        // that is not on screen into the clipboard — usually on its way to Slack.
        // So we ask the page first (CMMemo.selectVisible) and only fall back to the standard
        // selectAll: when the caret is not in a pad. Everything else keeps its native command.
        let all = editMenu.addItem(withTitle: "Select All",
                                   action: #selector(AppDelegate.selectAllCommand(_:)), keyEquivalent: "a")
        all.target = NSApp.delegate

        NSApp.mainMenu = mainMenu
    }

    // ⌘A. Asks the key window's web page whether a 메모장 owns the caret; if it does, the pad
    // has already selected what is on screen and we stop. Otherwise the normal responder-chain
    // selectAll: runs (a beat later — the JS round trip is a few ms and nothing else is racing
    // for the selection).
    @objc func selectAllCommand(_ sender: Any?) {
        guard let wv = Self.findWebView(NSApp.keyWindow?.contentView) else {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
            return
        }
        wv.evaluateJavaScript("try{ window.CMMemo && CMMemo.selectVisible ? (CMMemo.selectVisible()?1:0) : 0 }catch(e){ 0 }") { r, _ in
            let handled = ((r as? NSNumber)?.intValue ?? 0) == 1
            if !handled { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender) }
        }
    }

    private static func findWebView(_ v: NSView?) -> WKWebView? {
        guard let v else { return nil }
        if let w = v as? WKWebView { return w }
        for s in v.subviews { if let w = findWebView(s) { return w } }
        return nil
    }

    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            AppLog.log("single-instance: no bundle id (bare binary) — skipping dedup")
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        AppLog.log("single-instance: found \(others.count) other instance(s): \(others.map { $0.processIdentifier })")
        for app in others {
            AppLog.log("single-instance: forceTerminate pid \(app.processIdentifier)")
            app.forceTerminate()
        }
    }

    // MARK: - Workers

    // Declare every background worker once so the dashboard can show what exists,
    // whether it's running, and its schedule. Each worker stamps WorkerRegistry as
    // it fires (see onHeartbeat and the subsystem timers). Intervals here mirror the
    // actual cadences below — keep them in sync.
    private func registerWorkers() {
        let r = WorkerRegistry.shared
        let sampleInterval = Double(ProcessInfo.processInfo.environment["CM_SAMPLE_SEC"] ?? "") ?? 60
        r.register(id: "heartbeat", name: "코어 루프",
                   detail: "1초마다 시간 적립·세션 게이팅·상태바 갱신", interval: 1)
        r.register(id: "activity-sample", name: "활동 샘플",
                   detail: "키·마우스 입력률 평활화(APM 산출)", interval: 5)
        r.register(id: "browser-domain", name: "브라우저 도메인",
                   detail: "활성 탭 도메인 갱신(가치 분류용)", interval: 5)
        // The 카메라 지킴이 worker is owned by the camera-guard plugin (registered in
        // syncPluginWorkers) — installing that plugin is what brings the guard online.
        // The BGM 디렉터 worker is owned by 컨디션 메이트 (registered in syncPluginWorkers),
        // not core — installing that plugin is what brings BGM online.
        r.register(id: "autosave", name: "상태 저장",
                   detail: "누적 시간 디스크 플러시", interval: 30)
        r.register(id: "timeline-sample", name: "타임라인 기록",
                   detail: "분 단위 활동 샘플을 대시보드 타임라인에 적립", interval: sampleInterval)
        // QA agent: an EXTERNAL automation (launchd → claude -p, see Scripts/qa-scan.sh)
        // that screenshots the dashboard, flags UI rendering breakage, and files a goal
        // doc. The app only observes it — each run is reported via POST /api/worker/ping.
        // owner "qa" renders as a distinct 자동화 badge. It reads 유휴 whenever the
        // launchd job isn't pinging (which is the truth). The scan period is user-set in
        // qa-interval-sec (default 600=10분, via Scripts/qa-set-interval.sh); read it so
        // the dashboard 주기 column matches the real cadence (refreshed on next launch).
        r.register(id: "qa-agent", name: "QA 점검",
                   detail: "대시보드 UI 렌더링 깨짐 탐지 · goal 문서 자동 생성",
                   interval: Self.qaIntervalSeconds(), owner: "qa",
                   enabled: !FileManager.default.fileExists(atPath: Self.qaDisabledFlag.path))
        // QA fix agent: event-driven. qa-scan.sh fires it (detached) whenever the
        // inspection agent files a goal; it fixes the UI in an isolated git worktree and
        // reports here. Not periodic — interval is display-only; it reads 유휴 between fixes.
        r.register(id: "qa-fix", name: "QA 수정",
                   detail: "goal 생성 시 트리거 · 격리 worktree에서 UI 깨짐 자동 수정·빌드",
                   interval: Self.qaIntervalSeconds(), owner: "qa",
                   enabled: !FileManager.default.fileExists(atPath: Self.qaFixDisabledFlag.path))
        // Bug-hunt agent: a LONG-RUNNING (default 4h) hunt for FUNCTIONAL/LOGIC bugs —
        // wrong behavior a user hits (e.g. a 완료 filter that doesn't actually hide 완료
        // items), as opposed to the qa-agent's UI-rendering breakage. Run BY HAND at the
        // end of the day (Scripts/bug-hunt.sh); it reasons over the source for hours, files
        // a goal per confirmed bug, and never fixes. The app only observes it via the same
        // POST /api/worker/ping. Interval here is the round cadence (display-only); the row
        // reads 유휴 outside an active hunt. Toggleable (꺼짐 writes bug-hunt-disabled).
        r.register(id: "bug-hunt", name: "버그 헌트",
                   detail: "퇴근 시 수동 실행 · 최소 4시간 기능·로직 버그 탐색 · goal 문서 자동 생성",
                   interval: Self.bugHuntRoundSeconds(), owner: "qa",
                   enabled: !FileManager.default.fileExists(atPath: Self.bugHuntDisabledFlag.path))
        // UXUI 관리: an EXTERNAL automation (launchd → Scripts/uxui-sitemap.sh) that keeps
        // the UXUI sitemap (화면 카탈로그 탭의 사이트맵 뷰) in sync with the code — whenever
        // new commits land on main it re-derives the page/subpage/state hierarchy from the
        // sources and installs <data>/screens/sitemap.json. The app only observes it via
        // POST /api/worker/ping. Interval mirrors the plist's 300s base tick; the real work
        // is gated on main actually moving, so most ticks are silent no-ops.
        r.register(id: "uxui-sitemap", name: "UXUI 관리",
                   detail: "main 갱신 감지 · 코드에서 사이트맵(페이지·서브페이지·상태) 재생성 · 화면 카탈로그 연동",
                   interval: 300, owner: "qa",
                   enabled: !FileManager.default.fileExists(atPath: Self.uxuiSitemapDisabledFlag.path))
        // NSS 리포트: a SUT (Supertrust) automation (launchd → Scripts/nss-report-daily.sh)
        // that runs the /nss-report-daily skill every morning at 09:10 KST — it fetches the
        // on-chain + NSS figures, rebuilds the daily 모니터 리포트, and republishes the
        // "NSS 리포트 허브" artifact from the same raw data (no hand-entered values). The app
        // only observes it via POST /api/worker/ping. owner "sut" renders as a distinct SUT
        // badge and is user-toggleable (꺼짐 writes nss-report-disabled). Interval is 1 day
        // (display/liveness only); the real fire time is the plist's 09:10 calendar trigger.
        // It reads 오류 when a run fails (e.g. VPN off → Redash fetch fails), never a stale value.
        r.register(id: "nss-report", name: "NSS 리포트",
                   detail: "매일 09:10 온체인·NSS 데이터로 일일 모니터 리포트 생성 · 리포트 허브 아티팩트 재발행",
                   interval: 86400, owner: "sut",
                   enabled: !FileManager.default.fileExists(atPath: Self.nssReportDisabledFlag.path))
        // 자동 빌드: an EXTERNAL watcher (launchd KeepAlive → Scripts/autobuild-watch.sh)
        // that waits for the sources to go quiet after a save, then compiles a release
        // build and PARKS it in <data>/updates/ — the running app is never touched. It
        // exists so the rail's 업데이트 button is a ~2s copy instead of a ~40s compile the
        // user waits out. Realtime watcher, so interval is liveness only (it pings every
        // few seconds while idle). Toggleable (꺼짐 writes autobuild-disabled; the script
        // polls the flag and idles while present). Reads 오류 when a build fails — the
        // failure is deliberately invisible in the rail and lives on this row instead.
        r.register(id: "autobuild", name: "자동 빌드",
                   detail: "소스 저장 후 정적 상태 감지 · 백그라운드 릴리즈 빌드 · 업데이트 대기열에 적재(앱은 계속 실행)",
                   interval: 15,
                   enabled: !FileManager.default.fileExists(atPath: Self.autobuildDisabledFlag.path))
        // Slack 👀 번역: an EXTERNAL long-running daemon (launchd KeepAlive →
        // Sources/Plugins/Slack/Daemon/slack-eyes-daemon.mjs) holding a Slack Socket Mode WebSocket. When
        // the user reacts :eyes: to a Slack message it translates the text to Korean
        // (claude -p headless) and appends to <data>/slack-translate/items.jsonl,
        // rendered by the /slack-translate page. Realtime — interval is display/
        // liveness only. Toggleable (꺼짐 writes slack-translate-disabled; the daemon
        // polls the flag, idles while present, reconnects when removed).
        r.register(id: "slack-eyes", name: "Slack 번역",
                   detail: "슬랙 👀 리액션 실시간 감지 · 한국어 번역 · /slack-translate 페이지",
                   interval: 1800,
                   enabled: !FileManager.default.fileExists(atPath: Self.slackEyesDisabledFlag.path))
        // 지라 번역: 앱 안에서 도는 로컬 브리지(127.0.0.1:17321). 크롬 익스텐션이 지라
        // 화면의 텍스트를 보내면 Gemini로 번역해 돌려준다 — 키는 키체인에만 있고
        // 브라우저로 내려가지 않는다. 요청이 올 때만 일하므로 interval은 표시용이다.
        // 꺼짐은 jira-bridge-disabled 를 쓰고 즉시 리스너를 닫는다.
        r.register(id: "jira-bridge", name: "지라 번역",
                   detail: "크롬 익스텐션 요청을 받아 지라 텍스트를 Gemini로 번역 · 로컬 전용 포트 \(JiraBridge.fixedPort)",
                   interval: 1800,
                   enabled: !FileManager.default.fileExists(atPath: Self.jiraBridgeDisabledFlag.path))
        // 데몬은 앱 밖 launchd 프로세스라 죽어도 앱은 모른다. SlackHealth가 하트비트
        // 단절을 감지해 스스로 되살리고, 그 사실을 워커 상태 행에 남긴다 — 사용자가
        // 시스템 관리 화면에서 "꺼져 있었고, 다시 켰다"를 볼 수 있어야 한다.
        SlackHealth.onEvent = { why, effect, ok in
            let reg = WorkerRegistry.shared
            if ok {
                reg.clearError("slack-eyes")
                reg.recordRun("slack-eyes", why: why, effect: effect)
            } else {
                reg.recordError("slack-eyes", why: why, detail: effect)
            }
        }
        // 사람 손이 필요한 상태가 되면 배너로 부른다. 워커 표와 슬랙 페이지에만 적으면
        // 그 화면을 열기 전까지 아무도 모른다 — 2026-08-21 경로 사고 때 진단은 정확히
        // 돌았는데 아무도 볼 수 없는 곳에 적혀 19시간이 그냥 지나갔다. 카메라 지킴이와
        // 같은 osascript 배너 방식(별도 권한 배선 불필요)이고, 상태가 실제로 바뀔 때만
        // 한 번 뜬다 (SlackHealth.reportStateChange가 전환을 걸러 준다).
        SlackHealth.onNeedsUser = { title, detail in
            DispatchQueue.global(qos: .utility).async {
                let one = detail.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\"", with: "'")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e",
                    "display notification \"\(one.prefix(180))\" with title \"Condition Mate\" "
                    + "subtitle \"슬랙 번역 — \(title)\""]
                try? p.run()
            }
        }
        // 설치본은 자기 번들 안의 데몬을 가리키도록 launchd plist를 직접 유지한다.
        // 이 한 줄이 개발 트리와 운영 데몬을 갈라놓는다 — 레포를 옮기든 브랜치를 바꾸든
        // 운영은 /Applications/ConditionMate.app/Contents/Resources/ 를 계속 본다.
        // launchctl을 부르므로 메인 스레드에서 떼어낸다.
        DispatchQueue.global(qos: .utility).async {
            let r = SlackDaemonInstall.ensureInstalled()
            if r.changed {
                AppLog.log("slack daemon install: \(r.detail)")
                WorkerRegistry.shared.recordRun("slack-eyes", why: "데몬 경로 정규화",
                                                effect: r.detail)
            }
        }
        // Claude Desktop's session workers are NOT registered here — they are owned by
        // the plugin and appear/disappear with its connection (see syncPluginWorkers).
        migrateSlackPluginInstallState()
        syncPluginWorkers()
    }

    // The QA agent's scan period, read from the same qa-interval-sec file the runner
    // script reads (data dir). Default 600s (10분); floored at 60s. Display-only here —
    // the actual cadence is enforced by qa-scan.sh's interval gate.
    private static func qaIntervalSeconds() -> Double {
        let file = AppPaths.base.appendingPathComponent("qa-interval-sec")
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let v = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 60 else {
            return 600
        }
        return Double(v)
    }

    // The bug-hunt agent's per-round cadence, read from the same bug-hunt-round-sec file
    // the runner reads (data dir). Default 1200s (20분); floored at 300s (5분). Display-only
    // here — the hunt's real pacing is enforced by Scripts/bug-hunt.sh.
    private static func bugHuntRoundSeconds() -> Double {
        let file = AppPaths.base.appendingPathComponent("bug-hunt-round-sec")
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let v = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 300 else {
            return 1200
        }
        return Double(v)
    }

    // Flag files in the data dir that the runner script (qa-scan.sh) shares with the app:
    //   qa-disabled   present  -> the scan is OFF (the 꺼짐 toggle)
    //   qa-force-run  present  -> next base tick runs once now, bypassing the gates
    static var qaDisabledFlag: URL { AppPaths.base.appendingPathComponent("qa-disabled") }
    static var qaFixDisabledFlag: URL { AppPaths.base.appendingPathComponent("qa-fix-disabled") }
    static var uxuiSitemapDisabledFlag: URL { AppPaths.base.appendingPathComponent("uxui-sitemap-disabled") }
    // nss-report-disabled present -> the daily NSS report worker is OFF (its 꺼짐 toggle).
    // Scripts/nss-report-daily.sh reads this flag and no-ops when the file exists.
    static var nssReportDisabledFlag: URL { AppPaths.base.appendingPathComponent("nss-report-disabled") }
    static var qaForceRunFlag: URL { AppPaths.base.appendingPathComponent("qa-force-run") }
    // autobuild-disabled present -> the background auto-builder is OFF (its 꺼짐 toggle).
    // Scripts/autobuild-watch.sh polls this file and idles while it exists, so the user can
    // stop background compiles from the 시스템 페이지 without unloading the launchd agent.
    static var autobuildDisabledFlag: URL { AppPaths.base.appendingPathComponent("autobuild-disabled") }
    // bug-hunt-disabled present -> the bug-hunt agent is OFF (its 꺼짐 toggle). The runner
    // (Scripts/bug-hunt.sh) refuses to start, and a running hunt stops at the next round.
    static var bugHuntDisabledFlag: URL { AppPaths.base.appendingPathComponent("bug-hunt-disabled") }
    // slack-translate-disabled present -> the Slack 👀 번역 daemon is OFF (its 꺼짐 toggle).
    // slack-eyes-daemon.mjs polls this flag: idles while present, reconnects when removed.
    static var slackEyesDisabledFlag: URL { AppPaths.base.appendingPathComponent("slack-translate-disabled") }
    // jira-bridge-disabled present -> the 지라 번역 loopback bridge is OFF (its 꺼짐 toggle).
    // Unlike the other flags this one is read by the app itself: the toggle starts/stops the
    // listener in-process, so turning it off closes the port immediately.
    static var jiraBridgeDisabledFlag: URL { AppPaths.base.appendingPathComponent("jira-bridge-disabled") }
    // Latest DOM self-audit pushed by the dashboard ({width, ts, issues:[…]}).
    static var qaAuditFile: URL { AppPaths.base.appendingPathComponent("qa-audit.json") }

    // Best-effort path to the runner script, so "즉시 실행" can spawn it for true
    // immediacy. Resolved from the dev build's repo root (executable under <root>/.build/);
    // the old data-dir sibling probe is kept as a fallback for CM_DATA_DIR runs that point
    // inside a repo. Returns nil for an installed app with no reachable repo (run-now falls
    // back to the force-run flag, which the next launchd tick picks up).
    static func qaScriptURL() -> URL? {
        var candidates: [URL] = []
        if let proj = AppPaths.projectRoot {
            candidates.append(proj.appendingPathComponent("Scripts/qa-scan.sh"))
        }
        candidates.append(AppPaths.base.deletingLastPathComponent()
            .appendingPathComponent("Scripts/qa-scan.sh"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // Run the QA scan once, immediately, bypassing the interval + change gates. Spawns
    // the script detached (QA_FORCE=1) when reachable; otherwise drops the force-run flag
    // for the next launchd tick. Never blocks — the script reports back via the ping.
    func triggerQARunNow() {
        if let script = Self.qaScriptURL() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            // qa-scan.sh runs a headless `claude -p` UI-QA worker, so it needs the same
            // PATH/auth/session-suppression env as our in-process claude spawns.
            var env = Self.claudeEnv()
            env["QA_FORCE"] = "1"
            p.environment = env
            do { try p.run() } catch {
                try? Data().write(to: Self.qaForceRunFlag)   // fall back to the flag
            }
        } else {
            try? Data().write(to: Self.qaForceRunFlag)
        }
    }

    // Worker ids owned by the Claude Desktop plugin (registered on connect, removed on
    // disconnect). Kept in one place so the heartbeat gating and the registry agree.
    private let claudeWorkerIDs = ["session-reconcile", "title-stamp", "claude-sync-check", "title-repair"]

    // Worker ids owned by the 컨디션 메이트 plugin (registered on install, removed on
    // uninstall). The BGM director is the plugin's basic function; mate-tick is the
    // connoisseur layer. mate-discord / mate-suno join in later stages.
    private let mateWorkerIDs = ["director", "mate-tick"]

    // Bring the plugin-owned workers in line with the plugin's connection state. Called
    // at launch and after every plugin connect/disconnect/verify. Connecting Claude
    // Desktop makes its three workers appear in the dashboard and start running;
    // disconnecting removes them (sync pauses, existing goals are left untouched).
    func syncPluginWorkers() {
        let r = WorkerRegistry.shared
        if pluginStore.isConnected("claude-desktop") {
            r.register(id: "session-reconcile", name: "세션 상태 동기화",
                       detail: "트랜스크립트로 세션 진행중·응답 대기 실시간 판정", interval: 1, owner: "claude-desktop")
            r.register(id: "title-stamp", name: "세션 제목 스탬프",
                       detail: "데스크톱 세션 제목에 [seq] 재기입", interval: 30, owner: "claude-desktop")
            r.register(id: "claude-sync-check", name: "프로젝트 활성·싱크 점검",
                       detail: "프로젝트별 활성 강도(5단계) 산출 · 연동 목표 transcript 누락 검사", interval: 30, owner: "claude-desktop")
            r.register(id: "title-repair", name: "세션 제목 복구",
                       detail: "'Claude 세션 <id>' 플레이스홀더에 머문 목표를 트랜스크립트에서 재명명", interval: 30, owner: "claude-desktop")
            pluginStore.refreshClaudeProjects()   // seed the project list before the first 30s tick
        } else {
            claudeWorkerIDs.forEach { r.unregister(id: $0) }
        }

        // 컨디션 메이트: installing the plugin brings BGM online (the director, its basic
        // function) plus the mate decision loop. Uninstalling removes both — BGM goes silent
        // (the heartbeat music gate stops the director when the plugin is not installed).
        if pluginStore.isConnected("condition-mate") {
            r.register(id: "director", name: "BGM 디렉터",
                       detail: "활동률 기반 BGM 템포 결정(세션 활성 시)", interval: 20, owner: "condition-mate")
            r.register(id: "mate-tick", name: "컨디션 메이트",
                       detail: "상황 평가 후 음악 연출(Cue) 산출 — 활성 메이트가 결정", interval: 30, owner: "condition-mate")
        } else {
            mateWorkerIDs.forEach { r.unregister(id: $0) }
        }

        // 드로우: installing the plugin arms the screen-draw overlay (left ⌥ draws,
        // fn wipes). The card's draw on/off (Settings.drawEnabled) pauses it
        // without uninstalling; either gate closing stops the poller and clears strokes.
        if pluginStore.isConnected("draw") && Settings.shared.drawEnabled {
            r.register(id: "draw-overlay", name: "화면 드로우",
                       detail: "왼쪽 ⌥ 그리기 · 왼쪽 ⌘ 세 번 탭 30pt 글씨 · fn 지우기", interval: 5, owner: "draw")
            drawOverlay.onActivity = { WorkerRegistry.shared.recordRun("draw-overlay") }
            drawOverlay.start()
        } else {
            r.unregister(id: "draw-overlay")
            drawOverlay.stop()
        }

        // 카메라 지킴이: installing the plugin arms the guard (개더 실행 중 keep-alive로
        // 자리비움 카메라-끄기 방지 + 꺼짐 지속 시 알림). The card's on/off
        // (Settings.cameraGuardOn) pauses it without uninstalling. start/stop are
        // idempotent, so re-syncing is safe.
        if pluginStore.isConnected("camera-guard") && Settings.shared.cameraGuardOn {
            r.register(id: "camera-watch", name: "카메라 지킴이",
                       detail: "개더 실행 중 카메라 상시-ON — keep-alive · 꺼짐 지속 시 알림",
                       interval: 2, owner: "camera-guard")
            cameraWatch.start()
        } else {
            r.unregister(id: "camera-watch")
            cameraWatch.stop()
        }

        // 슬랙 번역: 데몬이 앱 밖 launchd 프로세스라 등록/해제로 껐다 켤 수 없다.
        // 대신 데몬이 계속 들여다보는 플래그 파일 하나가 스위치다 — 제거하면 파일을
        // 만들어 데몬이 대기 상태로 들어가고, 설치하면 지워서 다시 연결한다.
        // 워커 행의 enabled도 같은 사실을 반영해야 시스템 페이지와 어긋나지 않는다.
        let slackOn = pluginStore.isConnected("slack-translate")
        let slackFlagExists = FileManager.default.fileExists(atPath: Self.slackEyesDisabledFlag.path)
        if slackOn == slackFlagExists {           // 플래그가 플러그인 상태와 어긋난 경우에만 쓴다
            if slackOn {
                try? FileManager.default.removeItem(at: Self.slackEyesDisabledFlag)
                WorkerLog.shared.append("slack-eyes", why: "슬랙 번역 플러그인 설치", effect: "Slack 번역 켜짐")
            } else {
                try? Data().write(to: Self.slackEyesDisabledFlag)
                WorkerLog.shared.append("slack-eyes", why: "슬랙 번역 플러그인 제거", effect: "Slack 번역 꺼짐")
            }
        }
        r.setEnabled("slack-eyes", slackOn)
    }

    // 슬랙 번역이 플러그인으로 승격되기 전에는 시스템 페이지의 워커 토글(플래그
    // 파일)이 유일한 스위치였다. 그 상태를 첫 실행 때 한 번 플러그인 설치 상태로
    // 옮겨 온다 — 이걸 안 하면 꺼두었던 사람의 화면에서 데몬이 저절로 되살아난다.
    private func migrateSlackPluginInstallState() {
        guard Settings.shared.pluginInstalled["slack-translate"] == nil else { return }
        let off = FileManager.default.fileExists(atPath: Self.slackEyesDisabledFlag.path)
        Settings.shared.setPluginInstalled(!off, for: "slack-translate")
        if off { pluginStore.uninstall(pluginId: "slack-translate") }
    }

    // 표시 타임존 기본값이 "system" → "Asia/Seoul" 로 바뀐 것(2026-09-05)을 이미 디스크에
    // 값이 있는 설치본에도 한 번만 적용한다. 기본값만 바꾸면 settings.json 에 이미
    // cm.timeZone:"system" 이 들어 있는 맥은 영원히 안 바뀐다.
    //
    // WHY a one-shot flag and not a permanent read-time coercion of "system"→KST:
    // the header selector's `시스템 (맥 설정)` option must stay usable. If every read
    // coerced "system" into Asia/Seoul, that option would be a dead button — the user
    // would click it, the value would store, and the app would keep showing KST. With
    // the flag, a later explicit `시스템` choice sticks because the flag is already set.
    //
    // 이 판정은 L1 에서 사람 확인 없이 내려졌다 (issue/2026-09-05-token-view-timezone-
    // directive.md 의 `판정` 절). 근거 요약: 앱이 이미 세 자리(AppLog.logTimeZone,
    // isoWeek, aiTaskNameParts)에서 Asia/Seoul 을 못박고 있어 앱 안에 두 개의 "오늘" 이
    // 공존했고, 이 제품이 세는 것은 기계 설정이 아니라 사람의 하루이며, 틀렸을 때는
    // 헤더 셀렉터 한 번으로 되돌릴 수 있다.
    private func migrateTimeZoneKSTDefault() {
        let s = Settings.shared
        guard !s.timeZoneKSTMigrated else { return }
        // 정확히 "system" 일 때만 옮긴다. 사용자가 직접 고른 다른 값(UTC 등)은 건드리지 않는다.
        if s.timeZoneID == "system" {
            s.timeZoneID = "Asia/Seoul"
            AppLog.log("timezone migration: cm.timeZone \"system\" -> \"Asia/Seoul\" (one-shot, 2026-09-05 KST default)")
        }
        s.timeZoneKSTMigrated = true
    }

    // MARK: - Heartbeat (1 Hz)

    private func onHeartbeat() {
        tick += 1
        WorkerRegistry.shared.recordRun("heartbeat")
        // Reap idle/exited background CLI sessions once a minute.
        if tick % 60 == 0 { cliReapIdle() }
        // Slack 수집 데몬 워치독 — 하트비트가 끊겼으면 스스로 되살린다. 평상시엔
        // 파일 조회 한 번이라 가볍고, 죽었을 때만 launchctl을 부른다 (off-thread:
        // Process 실행이 메인 스레드를 잡으면 UI가 멈춘다).
        if tick % 30 == 0 {
            DispatchQueue.global(qos: .utility).async { SlackHealth.watchdogTick() }
        }
        let s = Settings.shared
        // CM_FAKE_FRONT overrides the frontmost app (tests).
        let frontBundle = ProcessInfo.processInfo.environment["CM_FAKE_FRONT"]
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // App filter: if the user designated tracked apps, only those count;
        // otherwise (none configured) any foreground app counts.
        let trackedConfigured = !s.trackedApps.isEmpty
        let isTracked = frontBundle.map { s.trackedApps.contains($0) } ?? false
        let appOK = !trackedConfigured || isTracked
        let isIdle = activity.idleSeconds >= s.idleSeconds

        // The manual switch is the master gate.
        let inSession = isWorking && appOK && !isIdle

        if inSession, let bundle = frontBundle {
            store.add(seconds: 1, app: bundle)
            sessionSeconds += 1
        }
        // 포모도로 완주(벽시계): 25 real minutes after start, regardless of the idle/app-filter
        // gates above — a pomodoro is a wall-clock interval, and the judgement lives HERE so it
        // holds even when no webview is open (the old rail-JS check silently missed these).
        if isWorking, director.sessionMode == "pomodoro", let startedAt = sessionStartedAt,
           Date().timeIntervalSince(startedAt) >= Double(pomodoroTargetSecs) {
            completePomodoro()
        }
        // Presence input: any input second while in a working session (regardless
        // of the tracked-app filter) — basis for total/desk/focus time.
        if isWorking && !isIdle { minuteInput += 1 }
        // Track the dominant frontmost app within this minute (for the dashboard).
        if let bundle = frontBundle { minuteAppSeconds[bundle, default: 0] += 1 }

        // For browsers, refresh the active-tab domain (throttled) and tally it.
        if let bundle = frontBundle, ValueTier.isBrowser(bundle) {
            if tick % 5 == 0 { refreshBrowserDomain(bundle); WorkerRegistry.shared.recordRun("browser-domain") }
            if !chromeDomain.isEmpty { minuteSiteSeconds[chromeDomain, default: 0] += 1 }
            // Log only on a real domain change (the 5s poll itself is just a counter).
            if chromeDomain != lastLoggedDomain {
                lastLoggedDomain = chromeDomain
                if !chromeDomain.isEmpty {
                    WorkerLog.shared.append("browser-domain",
                        why: "활성 탭 도메인 변경 감지", effect: "도메인 → \(chromeDomain)")
                }
            }
        } else {
            chromeDomain = ""
        }

        // Human-readable live status for the menu.
        if !isWorking {
            liveStatus = "정지"
        } else if isIdle {
            liveStatus = (Settings.shared.idleAmbientEnabled && appOK)
                ? "자리 비움 · 앰비언트"
                : "자리 비움 · 일시정지"
        } else if !appOK {
            liveStatus = "대기 · 추적 앱이 활성 아님"
        } else {
            liveStatus = "챌린지 중"
        }
        // Log only when the live status actually changes, so the heartbeat log stays
        // readable (one transition line) instead of one row every second.
        if liveStatus != lastLoggedStatus {
            WorkerLog.shared.append("heartbeat",
                why: "세션 평가 (작업=\(isWorking), 추적앱=\(appOK), 유휴=\(isIdle))",
                effect: "'\(lastLoggedStatus.isEmpty ? "시작" : lastLoggedStatus)' → '\(liveStatus)'")
            lastLoggedStatus = liveStatus
        }

        // --- Per-app BGM strategy: switch profile after >= dwell threshold ---
        if frontBundle == lastFrontBundle {
            frontStableSeconds += 1
        } else {
            lastFrontBundle = frontBundle
            frontStableSeconds = 0
        }
        if isWorking, let bundle = frontBundle, isTracked,
           frontStableSeconds >= dwellThreshold {
            let key = s.profileKey(for: bundle)
            if key != committedProfileKey {
                committedProfileKey = key
                director.applyProfile(BGMProfile.by(key: key))
                activeAppLabel = appDisplayName(bundle)
                ActionLog.shared.append(actionEvent("profileShift", kind: "system",
                    detail: "앱 전환 → \(activeAppLabel) · 프로필 \(director.activeProfileLabel)"))
            }
        }

        // Gate music to the active session — and to the 컨디션 메이트 plugin. BGM is the
        // plugin's basic function, so it only runs while the plugin is installed; uninstalled
        // means no music at all (the director is stopped and stays silent).
        if !pluginStore.isConnected("condition-mate") {
            if director.isRunning { director.stop() }
        } else if s.musicEnabled && inSession && !musicFolderConfigured {
            // Playback would start but no music folder is set: nudge the user
            // (once per session) and offer to jump straight to folder selection.
            promptForMusicFolderIfNeeded()
        } else if s.musicEnabled && !library.tracks.isEmpty {
            // Non-session caused ONLY by idleness (master on, tracked app active):
            // hold slow ambient music instead of silence.
            let idleOnly = isWorking && appOK && isIdle && s.idleAmbientEnabled
            if inSession {
                if !director.isRunning { director.start() }
                else if director.isIdleMode { director.exitIdle() }
                else if !director.isActive { director.resumeSession() }
            } else if idleOnly {
                director.enterIdle()
            } else if director.isPlaying {
                director.pauseSession()
            }
        } else if director.isRunning {
            director.stop()
        }
        // Re-arm the folder prompt once playback is no longer requested, so a
        // later session nudges again.
        if !inSession || !s.musicEnabled { musicFolderPromptShown = false }

        // Per-minute activity sample for the dashboard timeline. (CM_SAMPLE_SEC for tests.)
        let sampleInterval = Int(ProcessInfo.processInfo.environment["CM_SAMPLE_SEC"] ?? "") ?? 60
        if tick % sampleInterval == 0 {
            // Dominant app + site this minute, with the strategy/track + value tier.
            let domBundle = minuteAppSeconds.max { $0.value < $1.value }?.key
            let domSite = minuteSiteSeconds.max { $0.value < $1.value }?.key ?? "-"
            let tier = domBundle.map { ValueTier.classify(bundleID: $0, site: domSite) } ?? .passive
            let meeting = domBundle.map { ValueTier.isMeeting(bundleID: $0, site: domSite) } ?? false
            var sample = ActivityLog.Sample()
            sample.rate = Int(activity.activityRate)
            sample.key = Int(activity.keyRate)
            sample.mouse = Int(activity.mouseRate)
            sample.active = minuteInput
            sample.bpm = director.isPlaying ? Int(director.targetBPM) : 0
            sample.phase = director.isIdleMode ? "IDLE"
                : (director.isActive ? director.phase.rawValue : "-")
            sample.working = isWorking
            sample.meeting = meeting
            sample.app = domBundle.map { appDisplayName($0) } ?? "-"
            sample.profile = director.isPlaying ? director.activeProfileLabel : "-"
            sample.track = director.isPlaying ? (audio.currentTitle ?? "-") : "-"
            sample.site = domSite.isEmpty ? "-" : domSite
            sample.tier = tier.label
            sample.mult = tier.multiplier
            activityLog.append(sample)
            minuteInput = 0
            minuteAppSeconds.removeAll()
            minuteSiteSeconds.removeAll()
            WorkerRegistry.shared.recordRun("timeline-sample",
                why: "\(sampleInterval)초 주기 분 단위 집계",
                effect: "앱=\(sample.app) · tier=\(sample.tier) · 입력=\(sample.active)초 · BPM=\(sample.bpm)")
        }

        // Claude Desktop integration: session-reconcile, title-stamp, and the sync check
        // only run while the plugin is connected (valid folder). Disconnecting pauses
        // them — existing session goals keep their last status, no transcripts read.
        let claudeOn = pluginStore.isConnected("claude-desktop")
        if claudeOn {
            // Reconcile session goal status from transcripts every heartbeat (cheap stat per
            // goal; full re-parse only on growth) — keeps 진행중 real-time (priority 1).
            reconcileSessionStates(); WorkerRegistry.shared.recordRun("session-reconcile")

            // Policy 3: re-stamp [seq] onto Claude desktop session titles so a human can
            // eyeball-match a desktop session to its goal (file IO, throttled, off-main).
            if tick % 30 == 0 { stampSessionTitles()
                WorkerRegistry.shared.recordRun("title-stamp",
                    why: "30초 주기 세션 제목 동기화", effect: "데스크톱 세션 제목에 [seq] 재기입 점검") }

            // Quality check: every 30s confirm each session-linked goal's transcript is
            // resolvable. Any missing → 데이터 싱크 오류 (red status + error log line).
            if tick % 30 == 0 { runClaudeSyncCheck() }

            // The hooks title a goal at event time only — before the first turn the
            // transcript holds no title source, so the goal keeps its placeholder and
            // nothing ever re-reads it. Sweep those back up every 30s (file IO, cheap:
            // hopeless ids are probed once per app run).
            if tick % 30 == 0 { repairSessionTitles() }
        }

        // 컨디션 메이트: every 30s, the active mate reads the situation and hands the director
        // its next Cue. Only runs while the plugin is connected; a default cue is a no-op
        // (autonomous control). Aligned to the same 30s cadence as the worker's interval.
        if pluginStore.isConnected("condition-mate") && tick % 30 == 0 {
            runMateTick(isIdle: isIdle)
        }

        // Total span (= 대시보드 토탈 시간) — recompute from samples periodically. The
        // value is minute-grained, so a 10s refresh is plenty and keeps file IO low.
        if tick % 10 == 0 || totalSpanCacheAt == .distantPast { recomputeTotalSpan() }
        // Live status label every second while working; save every 30s.
        // Auto gauge mode (until the user picks one): 8h+ total -> 타임, else 스포츠.
        if !menuBarModeUserSet {
            menuBarMode = totalSpanDisplaySec() >= 8 * 3600 ? .time : .sports
        }
        updateStatusTitle()
        if tick % 30 == 0 { store.saveIfNeeded()
            WorkerRegistry.shared.recordRun("autosave",
                why: "30초 주기 영속화", effect: "누적 시간 변경분 디스크 플러시") }

        if ProcessInfo.processInfo.environment["CM_DEBUG"] != nil, tick % 2 == 0 {
            let dirPhase = director.isIdleMode ? "IDLE" : director.phase.rawValue
            let dir = director.isPlaying
                ? " | 전략=\(director.activeProfileLabel) [\(Int(director.activeMinBPM))-\(Int(director.activeMaxBPM))] BGM \(Int(director.targetBPM))BPM \(dirPhase)"
                : ""
            FileHandle.standardError.write(
                "[hb t=\(tick)] front=\(frontBundle ?? "-") dwell=\(frontStableSeconds) committed=\(committedProfileKey)\(dir)\n"
                    .data(using: .utf8)!)
        }
    }

    // Reconcile each session goal's live status from its transcript, real-time first. This
    // is the pull-based truth behind the hooks (push): even if no hook fires, the status
    // tracks real agent activity. Priority ladder (see .doc/waiting-signal-policy.md):
    //   1. transcript touched within activeWindow  -> in_progress  (the real-time "is it
    //      running?" signal; works without the active hook — top priority, surfaced instantly)
    //   2. in_progress but quiet past waitTimeout, or blocked on an AskUserQuestion -> 응답 대기
    //      (the lagging, inferred state — fine if it shows late)
    //   3. a stranded backlog goal (inside the recency window) parked on the human -> 응답 대기
    //   4. done is hook-terminal and is left untouched (not in the guard below)
    // Banking of active time happens in recordSession on each transition.
    // Short, single-line goal label for worker log entries (full titles can be long).
    private func goalLabel(_ goal: ReviewStore.Goal) -> String {
        let t = goal.text.replacingOccurrences(of: "\n", with: " ")
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }

    private func reconcileSessionStates() {
        let now = Date()
        let fm = FileManager.default
        for goal in reviewStore.goals {
            guard !goal.sessionId.isEmpty,
                  goal.status == "in_progress" || goal.status == "waiting" || goal.status == "backlog",
                  let url = resolveTranscript(goal),
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            let size = (attrs[.size] as? Int) ?? 0
            let stale = now.timeIntervalSince(mtime)

            // PRIORITY 1 — real-time active: a transcript touched within activeWindow means
            // the agent is working right now. Promote immediately, overriding any
            // waiting/backlog inference. Idempotent — recordSession only writes on a real
            // transition, so a session already in_progress costs just this stat.
            if stale <= activeWindow {
                if goal.status != "in_progress" {
                    reviewStore.recordSession(sessionId: goal.sessionId, event: "active")
                    WorkerLog.shared.append("session-reconcile",
                        why: "트랜스크립트 \(Int(stale))초 전 갱신(활성 윈도 이내)",
                        effect: "세션 '\(goalLabel(goal))' \(goal.status) → 진행중")
                }
                continue
            }

            // Not fresh. Stranded backlog goals are only reconciled inside the recency
            // window, so an ancient, abandoned session is never resurrected as 응답 대기.
            if goal.status == "backlog" && stale > reconcileWindow { continue }

            // Re-parse the transcript tail only when the file changed (a quiet session
            // stays a cheap stat, no re-read).
            if sessionSeenSize[goal.sessionId] != size {
                sessionSeenSize[goal.sessionId] = size
                let tail = transcriptTail(url)
                sessionPendingAsk[goal.sessionId] = (tail.pending == "AskUserQuestion")
                sessionTurnEnded[goal.sessionId] = (tail.pending == nil && tail.lastRole == "assistant")
            }
            let pendingAsk = sessionPendingAsk[goal.sessionId] ?? false
            let turnEnded  = sessionTurnEnded[goal.sessionId] ?? false

            switch goal.status {
            case "in_progress":
                // Quiet past the timeout, or blocked on the user -> park as 응답 대기 (the
                // waiting window is then excluded from banked active time).
                if pendingAsk || stale >= waitTimeout {
                    reviewStore.recordSession(sessionId: goal.sessionId, event: "wait")
                    WorkerLog.shared.append("session-reconcile",
                        why: pendingAsk ? "AskUserQuestion으로 사람 응답 대기"
                                        : "트랜스크립트 \(Int(stale))초 미변경(타임아웃 \(Int(waitTimeout))초)",
                        effect: "세션 '\(goalLabel(goal))' 진행중 → 응답 대기")
                }
            case "backlog":
                // Slice of design B: a goal the old idle→backlog mapping stranded rejoins
                // 응답 대기 when the transcript shows it parked on the human — an open
                // AskUserQuestion, or a finished assistant turn awaiting the next prompt.
                if pendingAsk || turnEnded {
                    reviewStore.recordSession(sessionId: goal.sessionId, event: "wait")
                    WorkerLog.shared.append("session-reconcile",
                        why: pendingAsk ? "AskUserQuestion으로 사람 응답 대기" : "턴 종료 후 다음 입력 대기",
                        effect: "세션 '\(goalLabel(goal))' 대기열 → 응답 대기 복원")
                }
            case "waiting":
                // A live session leaves waiting via priority-1 above (its transcript grows
                // again). One that never does — closed by the user, or superseded by a fork
                // under a new session_id — would otherwise sit in 응답 대기 forever, so the
                // count only grows and diverges from Claude Code's recent-session list. Past
                // waitReap of silence, retire it to 취소(cancelled): abandoned, not done, and
                // terminal (it won't bounce back). This is also what converges forks — the
                // orphaned parent goes quiet and is reaped without any prompt matching.
                if stale >= waitReap {
                    reviewStore.setStatus(id: goal.id, status: "cancelled")
                    WorkerLog.shared.append("session-reconcile",
                        why: "응답 대기 \(Int(stale))초 무변경(회수 임계 \(Int(waitReap))초) — 세션 방치/포크로 판단",
                        effect: "세션 '\(goalLabel(goal))' 응답 대기 → 취소")
                }
            default:
                break
            }
        }
    }

    // Re-title session goals still sitting on the "Claude 세션 <id>" placeholder
    // (title-repair worker, 30s). The hooks title a goal from the transcript at event
    // time, which is fire-and-forget: on the first events the transcript holds no title
    // source yet, and nothing re-reads it afterwards — so a goal can stay unnamed for
    // its whole life even though its transcript grew a perfectly good title minutes
    // later. This is the pull-based repair, same priority ladder as the hook
    // (override > ai-title > custom-title > first prompt), and it deliberately covers
    // every status: most stranded placeholders are already 완료.
    private func repairSessionTitles() {
        var fixed = 0, lastTitle = ""
        for goal in reviewStore.goals {
            guard !goal.sessionId.isEmpty,
                  goal.text == "Claude 세션 \(goal.sessionId.prefix(8))",
                  !titleRepairHopeless.contains(goal.sessionId) else { continue }
            guard let url = resolveTranscript(goal) else {
                titleRepairHopeless.insert(goal.sessionId)   // no transcript exists; never will
                continue
            }
            let title = transcriptTitle(url)
            guard !title.isEmpty else { continue }           // transcript exists but is still title-less
            reviewStore.setGoalTitle(id: goal.id, title: title)
            fixed += 1
            lastTitle = title
        }
        WorkerRegistry.shared.recordRun("title-repair",
            why: fixed > 0 ? "제목 없는 세션 목표 \(fixed)개 트랜스크립트에서 재명명"
                           : "제목 없는 세션 목표 점검 — 복구 대상 없음",
            effect: fixed > 0 ? "최근 복구: '\(lastTitle.count > 40 ? String(lastTitle.prefix(40)) + "…" : lastTitle)'"
                              : "변경 없음")
    }

    // Quality check for the Claude Desktop plugin (claude-sync-check worker, 30s). For
    // every active session-linked goal, confirm its transcript is resolvable — at the
    // stored path or as <connectedFolder>/<sessionId>.jsonl. Any goal whose transcript
    // is missing is a 데이터 싱크 오류: the folder moved, the session file was deleted, or
    // the goal points at a session that isn't in the connected folder. Missing ones are
    // logged as an error (red 상태); a clean pass clears the flag.
    private func runClaudeSyncCheck() {
        let fm = FileManager.default
        let folder = pluginStore.connectedFolder("claude-desktop")
        let root = PluginStore.claudeProjectsRoot(folder)

        // Refresh per-project activity (5-level intensity) for the dashboard, then log a
        // concise summary so the worker timeline shows what's active right now.
        pluginStore.refreshClaudeProjects()
        let projects = pluginStore.claudeProjects
        let active = projects.filter { $0.inUse }                 // level 5 (≤5분)
        let recent = projects.filter { $0.level >= 1 }            // within a week
        let topName = projects.first.map { "\($0.name)(\(Formatting.agoLabel($0.lastActiveSec)))" } ?? "-"

        // Quality: every active session-linked goal's transcript must be resolvable in the
        // connected root (or at its stored path). Missing ones are a 데이터 싱크 오류.
        let live = reviewStore.goals.filter {
            !$0.sessionId.isEmpty &&
            ($0.status == "in_progress" || $0.status == "waiting" || $0.status == "backlog")
        }
        var missing: [ReviewStore.Goal] = []
        for goal in live {
            let stored = !goal.transcriptPath.isEmpty && fm.fileExists(atPath: goal.transcriptPath)
            let inRoot = root.map { transcriptExists(sessionId: goal.sessionId, under: $0) } ?? false
            if !stored && !inRoot { missing.append(goal) }
        }
        let activitySummary = "활성 \(active.count)개 · 최근(주간) \(recent.count)개 · 최다활성 \(topName)"
        if missing.isEmpty {
            WorkerRegistry.shared.recordRun("claude-sync-check",
                why: "프로젝트 \(projects.count)개 활성 점검 · 연동 목표 \(live.count)개 transcript 검사",
                effect: "정상 — \(activitySummary) · transcript 누락 0")
            WorkerRegistry.shared.clearError("claude-sync-check")
        } else {
            let labels = missing.prefix(5).map { "#\($0.seq) \(goalLabel($0))" }.joined(separator: ", ")
            let more = missing.count > 5 ? " 외 \(missing.count - 5)건" : ""
            WorkerRegistry.shared.recordError("claude-sync-check",
                why: "연동 목표 \(live.count)개 중 transcript 누락 · \(activitySummary)",
                detail: "데이터 싱크 오류 — transcript 없음: \(labels)\(more)")
        }
    }

    // 컨디션 메이트 decision loop (mate-tick, 30s). Assemble the observation context, ask the
    // active mate for its next Cue, and pass it to the director. The mate is the optional
    // comrade above the executor; the director stays the executor. Stage 1 mates return a
    // default cue (no-op), so this exercises the full seam without changing playback yet.
    private func runMateTick(isIdle: Bool) {
        let ctx = MateContext(
            date: Date(),
            activityRate: activity.activityRate,
            isIdle: isIdle,
            frontAppLabel: activeAppLabel,
            phase: director.isIdleMode ? "IDLE"
                : (director.isActive ? director.phase.rawValue : "-"),
            targetBPM: director.targetBPM,
            profileLabel: director.activeProfileLabel,
            libMinBPM: library.bpmRange?.min,
            libMaxBPM: library.bpmRange?.max
        )
        let mate = MateRegistry.shared.current
        let cue = mate.decide(context: ctx)
        director.apply(cue: cue)
        WorkerRegistry.shared.recordRun("mate-tick",
            why: "30초 주기 상황 평가 (\(mate.name))",
            effect: cue.summary)
    }

    // Is <root>/<anyProject>/<sessionId>.jsonl present? (also accepts a transcript sitting
    // directly in root, the single-project-folder case). Bounded one level deep.
    private func transcriptExists(sessionId: String, under root: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(sessionId + ".jsonl").path) { return true }
        let children = (try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in children where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if fm.fileExists(atPath: dir.appendingPathComponent(sessionId + ".jsonl").path) { return true }
        }
        return false
    }

    // Policy 3 (.doc/session-lifecycle-policy.md): keep every session-linked goal's [seq]
    // stamped on the matching Claude desktop session title, so the two can be matched by
    // eye and the user can manually archive (desktop) / complete (web). reviewStore is
    // main-thread owned; we snapshot the (sessionId -> seq) map here, then SessionTitleStamper
    // does the directory scan + writes off-main.
    private func stampSessionTitles() {
        // Never mutate the real Claude store during dev/throwaway runs (CM_DATA_DIR set)
        // unless an explicit sessions-dir override points the stamper somewhere safe.
        if AppPaths.isCustom,
           ProcessInfo.processInfo.environment["CM_CLAUDE_SESSIONS_DIR"] == nil { return }
        var map: [String: SessionTitleStamper.Entry] = [:]
        for g in reviewStore.goals where !g.sessionId.isEmpty {
            map[g.sessionId] = .init(seq: g.seq, fallbackTitle: g.text)
        }
        SessionTitleStamper.stamp(bySession: map)
    }

    // Parse the transcript and report its tail state: the name of the last still-open
    // tool_use (nil once answered) and the role of the last user/assistant message. Walks
    // lines in order, tracking the most recent unanswered tool_use. A nil `pending` with
    // `lastRole == "assistant"` means the agent finished a turn and awaits the human.
    private func transcriptTail(_ url: URL) -> (pending: String?, lastRole: String?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, nil) }
        var pending: String? = nil   // name of an open tool_use, nil = all answered
        var lastRole: String? = nil
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return }
            lastRole = type
            for b in content {
                switch b["type"] as? String ?? "" {
                case "tool_use":    pending = b["name"] as? String
                case "tool_result": pending = nil
                default:            break
                }
            }
        }
        return (pending, lastRole)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        // The lightning bolt (button image) IS the condition indicator now — it
        // charges bottom-up across five stages from the live 활동/최고치 비율. Cheap
        // to call every refresh; it only swaps the image when the stage changes.
        gauge.update(norm: activity.conditionNorm, working: isWorking)
        // 스포츠 모드: while working, show the 1-minute average APM — a realistic
        // sustained pace rather than the twitchy instant value, so the digit no
        // longer jumps up and down every second. The dashboard gauge still tweens
        // the live instant APM for in-the-moment focus and fun. Idle has no APM, so
        // it falls through to the clock below.
        if menuBarMode == .sports && isWorking {
            // Glide the displayed value toward the (already smooth) 1-min average.
            // Asymmetric envelope keeps a brief rise snappy while the descent stays
            // smooth; snap when essentially there so the digit settles instead of
            // crawling the last fraction.
            let target = activity.averageAPM
            let alpha = target >= displayedAPM ? 0.45 : 0.20
            displayedAPM += (target - displayedAPM) * alpha
            if abs(target - displayedAPM) < 0.5 { displayedAPM = target }
            // Pad to 4 figure-spaces (U+2007, digit-width) so the title width is fixed —
            // APM never exceeds 4 digits, so it stops growing and never jiggles.
            let s = String(Int(displayedAPM.rounded()))
            let pad = String(repeating: "\u{2007}", count: max(0, 4 - s.count))
            // No ⚡ glyph here — the bolt now lives in the button image (the gauge).
            // A leading space keeps a small gap between the bolt and the number.
            button.title = " " + pad + s
            return
        }
        // 타임 모드 (and 스포츠 while idle): the 토탈 시간 work span — the exact same
        // number the dashboard "토탈 시간" card shows (휴식·미팅 포함, 8h+ 공백 제외),
        // e.g. 6:38. The total amount (총량) of the day, not a since-start session clock.
        button.title = " " + Formatting.clock(totalSpanDisplaySec())
    }


    // Recompute the 토탈 시간 work span from today's per-minute samples — mirrors the
    // dashboard timeBuckets() total: anchors are minutes with input or a meeting; the
    // span sums consecutive-anchor gaps under 8h (an 8h+ gap is 퇴근, excluded). Inferred
    // carry-forward minutes never change this telescoped sum, so we skip that pass.
    private func recomputeTotalSpan() {
        let samples = activityLog.todaySamplesParsed()
        var anchors: [Int] = []
        for s in samples {
            let active = (s["active"] as? NSNumber)?.intValue ?? 0
            let meeting = (s["meeting"] as? Bool) ?? false
            if active > 0 || meeting, let t = (s["t"] as? NSNumber)?.intValue { anchors.append(t) }
        }
        anchors.sort()
        var base = 0.0
        if let first = anchors.first {
            base = 60                          // the first anchored minute owns its 60s
            let offGap = 8 * 3600
            for i in 1..<anchors.count {
                let gap = anchors[i] - anchors[i - 1]
                if gap < offGap { base += Double(gap) }
            }
            lastAnchorT = anchors.last ?? first
        } else {
            lastAnchorT = 0
        }
        totalSpanBaseSec = base
        totalSpanCacheAt = Date()
    }

    // 업무 시작 후 경과(분). 0 = 방금 시작(앵커가 없거나 마지막 앵커가 6h+ 전 = 새 블록).
    // Thread-safe: 액션로그 스탬프가 서버 스레드에서도 부른다.
    func workElapsedMinutes() -> Int {
        workStartLock.lock(); defer { workStartLock.unlock() }
        let now = Date()
        if now.timeIntervalSince(workStartCacheAt) > 60 {
            workStartCached = Self.workStart(anchors: recentAnchors(), gap: workBlockGap,
                                             now: Int(now.timeIntervalSince1970))
            workStartCacheAt = now
        }
        guard workStartCached > 0 else { return 0 }
        return max(0, Int(now.timeIntervalSince1970) - workStartCached) / 60
    }

    // Yesterday+today anchor minutes (input or meeting), sorted — two files so an
    // overnight block that crossed midnight keeps its true start.
    private func recentAnchors() -> [Int] {
        var anchors: [Int] = []
        for dayOffset in [-1, 0] {
            let date = Date().addingTimeInterval(Double(dayOffset) * 86400)
            for s in activityLog.samplesParsed(for: date) {
                let active = (s["active"] as? NSNumber)?.intValue ?? 0
                let meeting = (s["meeting"] as? Bool) ?? false
                if active > 0 || meeting, let t = (s["t"] as? NSNumber)?.intValue { anchors.append(t) }
            }
        }
        return anchors.sorted()
    }

    // Pure block-walk (unit-testable): the start of the LAST work block, or 0 when
    // there is no anchor or the last block already ended (now - last anchor ≥ gap,
    // i.e. whatever happens next is a fresh 업무 시작).
    static func workStart(anchors: [Int], gap: Int, now: Int) -> Int {
        guard var start = anchors.first, let last = anchors.last else { return 0 }
        if now - last >= gap { return 0 }
        for i in 1..<anchors.count where anchors[i] - anchors[i - 1] >= gap { start = anchors[i] }
        return start
    }

    // Flip the menu-bar gauge between 스포츠(APM) and 타임(clock). Marks the choice as
    // user-set so the 8h auto-default stops overriding it.
    func toggleMenuBarMode() {
        menuBarMode = (menuBarMode == .sports) ? .time : .sports
        menuBarModeUserSet = true
        updateStatusTitle()
    }

    // MARK: - Manual Start/Stop Working

    func startWorking(mode: String? = nil, pomodoroSecs: Int? = nil) {
        // Remember the rail's chosen session mode (pomodoro/sprint/unlimited) even
        // when the session is already live: picking a mode during the launch
        // countdown must still switch the auto-started session's BGM playlist.
        if let mode = mode { director.setSessionMode(mode) }
        guard !isWorking else { return }
        // Lock in this session's pomodoro target: the rail's re-tappable 25분 chip may have
        // picked 45·50분. Env CM_POMODORO_SECS (e2e) keeps priority; otherwise the rail's value
        // wins, and a missing/invalid value falls back to the static default.
        if ProcessInfo.processInfo.environment["CM_POMODORO_SECS"] == nil {
            pomodoroTargetSecs = (pomodoroSecs.map { max(60, $0) }) ?? Self.pomodoroWallSeconds
        }
        // 시작 큐: each mode is a "character" — picking one and starting should give a
        // distinct battle-cry that syncs to the choice. Every start path (rail dial,
        // menu, ⌘S, launch auto-start) funnels here and gets the cue for the resolved
        // sessionMode: pomodoro = the crisp starting-gun snap (unchanged, it's perfect),
        // sprint = a rocket-ignition riser, tracker(unlimited) = a shimmer that fades in.
        // Quieter than the completion chime — the BGM opener lands right after, and the
        // cue must read as a lead-in, not compete with the music. Each mode's first
        // candidate is user-swappable at <data>/sound/ (the folder is the interface);
        // a missing per-mode file falls back to the shared session-start default.
        let startCues: [String: [String]] = [
            "sprint":    ["start-sprint.mp3", "session-start.m4a"],
            "unlimited": ["start-tracker.mp3", "session-start.m4a"],
            "pomodoro":  ["pomodoro-start.mp3", "session-start.m4a"],
        ]
        let cueCandidates = startCues[director.sessionMode] ?? startCues["pomodoro"]!
        if let cue = SoundEffects.shared.playFirst(cueCandidates, volume: 0.7) {
            ActionLog.shared.append(actionEvent("chime", kind: "system",
                detail: "세션 시작음 \(director.sessionMode) (sound/\(cue))"))
        }
        // Each session opens on its mode's pinned first track (per-mode playlist).
        director.armModeOpener()
        session.setRunning(true)
        sessionSeconds = 0
        sessionStartedAt = Date()
        // Starting the next session auto-claims any unharvested 🍅 — the completion was
        // already counted in PomodoroStats, so an untapped orb never loses the pomodoro.
        pomodoroRewardPending = false
        committedProfileKey = ""
        frontStableSeconds = 0
        activeAppLabel = ""
        ActionLog.shared.append(actionEvent("sessionStart",
            detail: "세션 시작 (\(director.sessionMode))"))
        // The gauge follows the live condition on the heartbeat; updateStatusTitle
        // below refreshes it immediately so the bolt lights up on session start.
        updateStatusTitle()
    }

    // playCue=false suppresses the stop cue when a louder signal owns the moment
    // (pomodoro completion plays its own 완주 success chime right after the stop).
    func stopWorking(playCue: Bool = true) {
        guard isWorking else { return }
        ActionLog.shared.append(actionEvent("sessionStop",
            detail: "세션 중지 · \(Int(sessionSeconds))초 경과"))
        session.setRunning(false)
        sessionStartedAt = nil
        committedProfileKey = ""
        activeAppLabel = ""
        director.pauseSession()
        // 정지 큐: every manual stop path (rail stop button, menu, ⌘S) funnels here.
        // Played after pauseSession so it lands in the silence the stop just made,
        // mirroring the start cue's lead-in role. Asset is user-swappable at
        // <data>/sound/ (the folder is the interface).
        if playCue, let cue = SoundEffects.shared.playFirst(["stop-challenge.mp3"], volume: 0.7) {
            ActionLog.shared.append(actionEvent("chime", kind: "system",
                detail: "세션 정지음 (sound/\(cue))"))
        }
        store.saveIfNeeded()
        gauge.showIdle()
        updateStatusTitle()
    }

    // 포모도로 25:00(벽시계) 도달 — the server concludes the interval: durable history,
    // equipment EXP, success chime, session stop, then the reward orb waits server-side.
    // Webviews only render this state from /api/session/state; none of it depends on a
    // page being open at the moment the clock hits zero.
    private func completePomodoro() {
        let active = Int(sessionSeconds)
        ActionLog.shared.append(actionEvent("pomodoro.complete",
            detail: "포모도로 \(pomodoroTargetSecs / 60)분 완주(벽시계) · 활동 \(active)초 — 장비 EXP 반영",
            category: "pomodoro"))
        equipment.recordPomodoro(usage: equipmentUsage(within: TimeInterval(pomodoroTargetSecs)))
        pomodoroStats.recordCompletion(mode: director.sessionMode, activeSecs: active)
        stopWorking(playCue: false)
        pomodoroRewardPending = true
        // 완주 성공음 plays into the silence right after the stop — a deliberate "완주"
        // signal, distinct from a mere stop. Asset is user-swappable at <data>/sound/.
        SoundEffects.shared.play("pomodoro-success.mp3")
        ActionLog.shared.append(actionEvent("chime", kind: "system",
            detail: "포모도로 완주 성공음 (sound/pomodoro-success.mp3)"))
    }

    // 🍅 수확 탭 — the count was already recorded at completion; the tap only claims the
    // orb (confetti + chime) and clears the pending state.
    func harvestPomodoro() {
        guard pomodoroRewardPending else { return }
        pomodoroRewardPending = false
        ActionLog.shared.append(actionEvent("pomodoro.harvest",
            detail: "🍅 수확 탭", category: "pomodoro"))
        if let played = SoundEffects.shared.playFirst(["pomodoro-harvest.mp3", "harvest.m4a"]) {
            ActionLog.shared.append(actionEvent("chime", kind: "system",
                detail: "이펙트음 harvest (sound/\(played))"))
        }
    }

    // A user-action event pre-filled with the moment's BGM context (mode, playing
    // track, phase, profile, frontmost app) so /actions rows can show "what was
    // sounding when the user did this" without a join.
    private func actionEvent(_ action: String, kind: String = "user", detail: String = "",
                             category: String = "") -> ActionLog.Event {
        var e = ActionLog.Event()
        e.kind = kind
        e.action = action
        e.category = category
        e.detail = detail
        e.mode = director?.sessionMode ?? "-"
        e.track = audio.currentTitle ?? ""
        e.trackKey = audio.currentURL?.lastPathComponent ?? ""
        e.phase = director?.phase.rawValue ?? "-"
        e.profile = director?.activeProfileLabel ?? "-"
        e.app = activeAppLabel
        return e
    }

    // Refresh the cached browser domain off the main thread (osascript can block
    // and the first call may show a permission prompt).
    private func refreshBrowserDomain(_ bundleID: String) {
        guard !siteRefreshing else { return }
        siteRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let domain = BrowserInspector.activeDomain(bundleID: bundleID)
            DispatchQueue.main.async {
                self?.chromeDomain = domain
                self?.siteRefreshing = false
            }
        }
    }

    // Display name for a bundle id (falls back to the id).
    func appDisplayName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    func toggleWorking() {
        isWorking ? stopWorking() : startWorking()
    }

    // App-wide shortcut handler (see the local monitor in applicationDidFinishLaunching). Fires only
    // while the app is active, on any window/page. Match Command exactly (no extra modifiers) so we
    // don't hijack ⌘⇧M / ⌥⌘S etc. Returns nil to swallow the event, or the event to let it pass.
    private func handleShortcut(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌃⌘N — 레일의 사이드바 버튼(⊞)과 똑같은 3단계 순환. 마우스 없이 레일 접기 → 메모장만 →
        // 원래대로 를 오간다. 전역(Carbon) 등록이 아니라 이 앱이 앞에 있을 때만 잡는 이유: ⌃⌘N 은
        // Finder 의 '선택 항목으로 새 폴더'라서 전역으로 뺏으면 남의 앱을 망가뜨린다.
        // 토글할 화면이 없으면 이벤트를 그대로 흘려보낸다.
        if mods == [.command, .control], event.keyCode == 45 {  // kVK_ANSI_N
            return appWindow.cycleRailStage() ? nil : event
        }
        guard mods == .command else { return event }
        // Match the physical key (keyCode), not the typed character: with a Korean input source
        // active, charactersIgnoringModifiers is "ㅡ"/"ㄴ" rather than "m"/"s", so a character
        // match falls through and the unhandled ⌘-key beeps.
        switch event.keyCode {
        case 46: toggleMute();    return nil  // kVK_ANSI_M
        case 1:  toggleWorking(); return nil  // kVK_ANSI_S
        default: return event
        }
    }

    // Mute/unmute the sound the user actually hears. `session.isMuted` is the single source of truth;
    // this flips it and syncs the two audio sources. While the app window is open the BGM webview
    // owns output (native stays force-muted — see windowOwnsAudio), so push the new state into the
    // webview's own mute control for instant feedback; the /api/bgm/now poll (which now carries
    // `muted`) reconciles the web as a backstop. When the window is closed the native AudioEngine is
    // the source, handled by applyNativeMute.
    func toggleMute() {
        session.toggleMuted()
        applyMuteToSurfaces()
        ActionLog.shared.append(actionEvent(session.isMuted ? "mute" : "unmute",
            detail: session.isMuted ? "음소거 켬" : "음소거 해제"))
        AppLog.log("mute toggle (⌘M / 전역 ⌃⌘M) -> \(session.isMuted) (windowOpen=\(appWindow.isOpen) nativeMuted=\(audio.muted))")
    }

    // The one place that writes audio.muted for the mute axis. Native output reflects the user's
    // mute intent, but stays force-muted while the app window owns audio (windowOwnsAudio) so the
    // native player and the BGM webview never both make sound.
    func applyNativeMute() { audio.muted = windowOwnsAudio || session.isMuted }

    // 효과음(원샷 이펙트음)의 단 하나의 게이트. 두 스위치를 AND로 합친다:
    // 마스터 음소거(⌃⌘M / 레일 '음소거')는 음악뿐 아니라 이펙트음까지 전부 끈다 —
    // 음소거를 누르는 이유가 "지금 집중해야 하니 이 앱은 조용히 하라"이기 때문이다.
    // 그와 별개로 '효과음' 스위치는 음악은 그대로 두고 알림음만 끈다(집중을 깨는 건
    // 음악이 아니라 불쑥 튀는 소리라는 게 이 스위치의 존재 이유).
    func applySfxGate() { SoundEffects.shared.muted = session.isMuted || !Settings.shared.sfxEnabled }

    // 받아쓰기 덕킹을 두 출력 경로에 동시에 건다. 창이 열려 있으면 실제로 들리는 소리는 BGM
    // 웹뷰가 내고 네이티브는 이미 뮤트(windowOwnsAudio)지만, 양쪽에 다 걸어 두는 편이 맞다 —
    // 말하는 도중에 창이 닫히면 네이티브가 곧바로 소리를 넘겨받는데 그때 눌려 있지 않으면
    // 음악이 튀어나온다. 뮤트 축은 건드리지 않으므로 ⌘M 상태는 그대로 유지된다.
    private func applyVoiceDuck(_ on: Bool) {
        guard voiceDucked != on else { return }
        voiceDucked = on
        audio.voiceDucked = on
        if appWindow.isOpen { appWindow.setWebVoiceDuck(on) }
    }

    // 설정 스위치를 실제 감시자에 반영한다. 꺼져 있으면 감시 자체를 내려서(전역 키 모니터 +
    // 폴더 감시) 비용을 0 으로 만들고, 눌려 있던 상태가 남지 않도록 먼저 되돌린다.
    private func applyVoiceDuckSwitch() {
        if Settings.shared.voiceDuckOn {
            voiceDictation.start()
        } else {
            voiceDictation.stop()
            applyVoiceDuck(false)
        }
    }

    // Push the current mute state to every audio surface: the BGM webview (what the user actually
    // hears while the window is open) and the native player. window.__setMute is idempotent, so
    // echoing it back to a webview that already flipped its own control is a harmless no-op — which
    // lets every surface (⌘M, the rail mute dot, the BGM player button) route through this one path.
    private func applyMuteToSurfaces() {
        if appWindow.isOpen { appWindow.setWebMute(session.isMuted) }
        applyNativeMute()
        applySfxGate()
    }

    // Remote mute control from any page (POST /api/session/mute): set the source of truth and sync
    // all surfaces. Safe to call from the BGM webview itself — the echo back is a no-op (see above).
    func setMutedRemote(_ muted: Bool) {
        let changed = session.isMuted != muted
        session.setMuted(muted)
        applyMuteToSurfaces()
        // Only real flips are logged — the poll-reconcile echo posts the same state back.
        if changed {
            ActionLog.shared.append(actionEvent(muted ? "mute" : "unmute",
                detail: muted ? "음소거 켬" : "음소거 해제"))
        }
    }

    // MARK: - Actions invoked by the menu

    func reloadLibrary() {
        // CM_SCAN_DIR env overrides the saved folder (handy for testing).
        let path = ProcessInfo.processInfo.environment["CM_SCAN_DIR"] ?? Settings.shared.musicFolderPath
        guard let path else { return }
        library.load(folderPath: path)
        // Per-track authoring tags live NEXT TO the scanned folder (read-only join
        // by relative path), so any rescan re-reads them from the same root.
        bgmTags.load(musicRoot: path)
        if ProcessInfo.processInfo.environment["CM_DEBUG"] != nil {
            let range = library.bpmRange.map { " range \(Int($0.min))-\(Int($0.max))" } ?? ""
            FileHandle.standardError.write(
                "[ConditionMate] loaded \(library.tracks.count) tracks (\(library.skippedCount) no-BPM defaulted)\(range)\n"
                    .data(using: .utf8)!
            )
            for t in library.tracks {
                FileHandle.standardError.write("  \(Int(t.bpm)) BPM  \(t.title)\n".data(using: .utf8)!)
            }
        }
    }

    // Whether a music source is configured: an explicit saved folder, or the
    // CM_SCAN_DIR test override. Mirrors reloadLibrary()'s path resolution.
    private var musicFolderConfigured: Bool {
        if ProcessInfo.processInfo.environment["CM_SCAN_DIR"] != nil { return true }
        if let path = Settings.shared.musicFolderPath, !path.isEmpty { return true }
        return false
    }

    // Ask the user to set a music folder when a session wants to play but none
    // is configured. Shown at most once per session (musicFolderPromptShown).
    // "예" jumps straight to the folder picker.
    private func promptForMusicFolderIfNeeded() {
        guard !musicFolderPromptShown else { return }
        musicFolderPromptShown = true

        let alert = NSAlert()
        alert.messageText = "음악 폴더 설정이 안되어 있습니다"
        alert.informativeText = "BGM을 재생하려면 음원 폴더가 필요합니다. 폴더 설정을 지금 할까요?"
        alert.addButton(withTitle: "예")     // .alertFirstButtonReturn
        alert.addButton(withTitle: "아니오")  // .alertSecondButtonReturn
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            chooseMusicFolder()
        }
    }

    func chooseMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "BPM이 파일명에 포함된 음원 폴더를 선택하세요"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.musicFolderPath = url.path
            reloadLibrary()
            // Restart cleanly so the new library takes effect.
            if director.isRunning { director.stop() }
        }
    }

    func toggleMusic() {
        Settings.shared.musicEnabled.toggle()
        if !Settings.shared.musicEnabled { director.stop() }
    }

    // 메뉴바 위젯의 드로우 전체 on/off. Same source of truth as the plugin card's
    // sub-switch (POST /api/draw/enabled): flips Settings.drawEnabled and resyncs the
    // plugin workers, so turning it off stops the key poller immediately and wipes any
    // strokes off the screen (잘못된 조작이 잦아 위젯에서 바로 끄고 켜기 위한 것).
    func toggleDraw() {
        Settings.shared.drawEnabled.toggle()
        let on = Settings.shared.drawEnabled
        ActionLog.shared.append(actionEvent(on ? "drawOn" : "drawOff",
            detail: on ? "드로우 켬 (메뉴)" : "드로우 끔 (메뉴)"))
        syncPluginWorkers()
    }

    // 메뉴바 위젯의 카메라 지킴이 on/off. Same source of truth as the plugin card's
    // sub-switch (POST /api/camera/enabled): flips Settings.cameraGuardOn and resyncs
    // the plugin workers, so the guard (개더 자리비움 카메라-끄기 방지) starts/stops
    // immediately without uninstalling the plugin.
    func toggleCameraGuard() {
        Settings.shared.cameraGuardOn.toggle()
        let on = Settings.shared.cameraGuardOn
        ActionLog.shared.append(actionEvent(on ? "cameraGuardOn" : "cameraGuardOff",
            detail: on ? "카메라 지킴이 켬 (메뉴)" : "카메라 지킴이 끔 (메뉴)"))
        syncPluginWorkers()
    }

    // 디버그 모드(버그 수집) 배선 + 복원. 훅은 항상 걸어 두고 DebugCapture.isOn 이 게이트다.
    // 스위치가 켜진 채로 앱이 죽거나 업데이트로 재시작해도 수집이 이어진다 — "재시작하면
    // 재현된다" 류의 버그가 캡처 밖으로 빠져나가지 않게 하기 위한 것.
    private func wireDebugCapture() {
        // 앱 자신의 창으로 들어온 키만. 다른 앱의 키는 이 훅으로 오지 않는다(전역 모니터는 개수만).
        activity.localKeySink = { event in
            guard DebugCapture.shared.isOn else { return }
            let f = event.modifierFlags
            var mod = ""
            if f.contains(.command) { mod += "⌘" }
            if f.contains(.control) { mod += "⌃" }
            if f.contains(.option) { mod += "⌥" }
            if f.contains(.shift) { mod += "⇧" }
            let chars = event.type == .flagsChanged ? "(flags)" : (event.charactersIgnoringModifiers ?? "")
            DebugCapture.shared.nativeKey(keyCode: Int(event.keyCode), chars: chars,
                                          modifiers: mod, window: event.window?.title ?? "")
        }
        // 아래 둘은 DebugCapture의 백그라운드 큐에서 불린다 → 메인 상태를 읽을 땐 hop 한다.
        DebugCapture.shared.screenshotProvider = { [weak self] in
            guard let self else { return nil }
            let open = DispatchQueue.main.sync { self.appWindow.isOpen }
            guard open else { return nil }
            let mode = DispatchQueue.main.sync { self.appWindow.mode }
            return self.appWindowSnapshotPNG(mode: mode, tab: nil)
        }
        DebugCapture.shared.contextProvider = { [weak self] in
            guard let self else { return [:] }
            return DispatchQueue.main.sync {
                [
                    "working": self.isWorking ? "yes" : "no",
                    "muted": self.session.isMuted ? "yes" : "no",
                    "windowOpen": self.appWindow.isOpen ? "yes" : "no",
                    "windowMode": self.appWindow.mode.rawValue,
                    "bgmActive": self.director?.isActive == true ? "yes" : "no",
                    "track": self.audio.currentTitle ?? "-",
                    "activeGoal": Settings.shared.activeGoalSeq.map(String.init) ?? "-",
                    "accessibility": self.activity.isTrusted ? "trusted" : "not-trusted",
                ]
            }
        }
        if Settings.shared.debugCapture {
            DebugCapture.shared.start(reason: "앱 시작 (이전 세션에서 켜져 있었음)")
        }
    }

    // 메뉴바 위젯의 디버그 모드(버그 수집) on/off.
    //
    // 켜기: 그 순간부터 앱 웹뷰의 키·클릭·콘솔·네트워크와 서버가 받은 모든 HTTP 요청이
    //       한 폴더에 쌓인다. 유저는 "버그를 다시 한 번 재현"하기만 하면 된다.
    // 끄기: 수집을 멈추고(웹뷰 마지막 배치를 위한 1.5초 유예) 번들을 만든 뒤, 그 번들을
    //       가리키는 버그 리포트 goal 하나를 자동 생성하고 그 세션 화면으로 이동한다 —
    //       제보를 위해 유저가 따로 무엇을 모으거나 붙여넣을 일이 없게 하는 것이 목적.
    func toggleDebugCapture() {
        setDebugCapture(!DebugCapture.shared.isOn, source: "메뉴")
    }

    func setDebugCapture(_ on: Bool, source: String) {
        // isOn 이 아니라 status().on 으로 본다 — isOn 은 끄기 직후의 drain 구간에서도 true라
        // "껐다가 곧바로 다시 켜기"가 무시돼 버린다.
        guard on != DebugCapture.shared.status().on else { return }
        Settings.shared.debugCapture = on
        if on {
            DebugCapture.shared.start(reason: source)
            ActionLog.shared.append(actionEvent("debug.captureOn",
                detail: "디버그 모드 켬 (\(source)) — 버그 수집 시작", category: "settings"))
            ViewTrace.shared.native("debugCaptureOn", detail: source)
        } else {
            ActionLog.shared.append(actionEvent("debug.captureOff",
                detail: "디버그 모드 끔 (\(source)) — 버그 리포트 생성", category: "settings"))
            ViewTrace.shared.native("debugCaptureOff", detail: source)
            DebugCapture.shared.stop(reason: source) { [weak self] report in
                guard let self, let report else { return }
                self.openBugReportSession(report)
            }
        }
    }

    // 디버그 모드를 끈 직후 만들어지는 "버그 리포트 세션": 캡처 번들을 가리키는 goal 하나를
    // 만들고(정의 문서에 무엇을 어디서 읽어야 하는지까지 써 둔다) 그 goal 화면을 띄운다.
    // 유저가 할 일은 무슨 일이 일어났는지 한 줄 적는 것뿐 — 로그 수집·첨부는 이미 끝나 있다.
    private func openBugReportSession(_ report: DebugCapture.Report) {
        // 조작이 하나도 없는 캡처는 리포트를 만들지 않는다. 스위치를 켰다 곧바로 끈 경우가
        // 그렇고, 그때 만들어진 goal은 "무엇을 눌렀는지" 칸이 영원히 비어 있어서 읽는 사람도
        // 세션도 할 말이 없다(실제로 첫 자동 리포트 3건 중 2건이 그랬다). 번들은 그대로 남으니
        // 필요하면 폴더를 열어보면 된다 — 배너는 띄우지 않고 로그로만 남긴다.
        guard report.userActions > 0 else {
            AppLog.log("debug-capture: 조작 0건 — 버그 리포트 goal 생략 (bundle=\(report.dir.path))")
            ActionLog.shared.append(actionEvent("debug.bugReportSkip",
                detail: "조작 0건 — 리포트 생략 (\(report.seconds)초)", category: "settings"))
            return
        }
        let when = DebugCapture.human(report.startedAt)
        let span = report.minutes > 0 ? "\(report.minutes)분" : "\(report.seconds)초"
        let title = "버그 리포트 · \(when) (디버그 캡처 \(span))"
        let seq = reviewStore.addGoal(text: title)
        guard seq > 0 else {
            AppLog.log("debug-capture: bug report goal 생성 실패 (bundle=\(report.dir.path))")
            return
        }
        writeBugReportDocs(seq: seq, report: report)
        ActionLog.shared.append(actionEvent("debug.bugReport",
            detail: "#\(seq) 버그 리포트 생성 · \(report.events)건", category: "settings"))
        // 창을 띄운 뒤 그 goal 세션 화면으로 보낸다(창이 닫혀 있으면 먼저 열린다).
        // debugNavigate는 창이 이미 열려 있어야 동작하므로 show 다음 프레임에서 부른다.
        dashboard.start { [weak self] port in
            DispatchQueue.main.async {
                guard let self else { return }
                self.appWindow.show(port: port, mode: .dashboard)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.appWindow.debugNavigate(path: "/goal?n=\(seq)", port: port)
                }
            }
        }
    }

    // goal-core.md(사람이 읽는 리포트 뼈대) + goal-detail.md(AI가 바로 착수할 수 있는 지시).
    // 캡처 폴더는 goal 폴더 밖(events/debug-capture/…)에 그대로 두고 절대경로로 가리킨다 —
    // 수십 MB가 될 수 있는 로그를 goal 폴더로 복사하지 않기 위한 것.
    private func writeBugReportDocs(seq: Int, report: DebugCapture.Report) {
        let dir = report.dir.path
        let span = report.minutes > 0 ? "\(report.minutes)분" : "\(report.seconds)초"
        let video = report.videoPath.isEmpty
            ? "화면 녹화 없음 — \(report.videoNote.isEmpty ? "녹화하지 못했습니다" : report.videoNote)"
            : "화면 녹화: \(report.videoPath)"
        // 플레이스홀더 벽을 쓰지 않는다. 앱이 이미 아는 사실(무엇을 눌렀고 어느 화면을 거쳤고
        // 무엇이 실패했는지)은 앱이 직접 채우고, 사람에게는 딱 한 칸 — 증상 — 만 남긴다.
        let core = """
        # 버그 리포트 (디버그 캡처 \(report.id))

        ## 문제정의
        **증상 (한 줄로 적어주세요):**

        \(video)

        캡처가 기록한 사실:

        \(report.summary)

        ## 예상결과
        위 조작에서 기대했던 동작.

        ## 예상해결방안
        (분석 후 채워짐)

        ## 예상테스트시나리오
        위 "마지막 조작 순서"를 그대로 재현 → 같은 증상이 나오는지 확인.

        ## 캡처 정보
        - 구간: \(DebugCapture.human(report.startedAt)) ~ \(DebugCapture.human(report.endedAt)) (\(span))
        - 이벤트 \(report.events)건 · 사용자 조작 \(report.userActions)건\(report.truncated ? " (상한 도달로 일부 잘림)" : "")
        - 번들: \(dir)
        """
        let detail = """
        # 디버그 캡처 번들 분석 지시

        이 goal은 유저가 메뉴바 위젯에서 디버그 모드를 끈 순간 자동 생성되었습니다.
        아래 번들에는 버그가 재현된 구간의 전수 기록이 들어 있습니다.

        번들 경로: \(dir)

        0. `\(dir)/screen.mp4` — 그 구간의 앱 창 화면 녹화. 먼저 이것부터 확인하세요
           (`open` 으로 재생하거나, 필요하면 `ffmpeg` 로 프레임을 뽑아 보세요).
        1. `\(dir)/report.md` — 앱이 결정적으로 만든 요약(마지막 조작 순서 · 거쳐간 화면 · 실패).
           이미 요약이 있으니 로그를 처음부터 다시 훑지 마세요.
        2. `\(dir)/capture.jsonl` — 요약이 놓친 세부만 확인. 뒤에서부터 읽으세요.
           - `k:"key"` 앱 웹뷰 키 입력(`pw:true`는 비밀번호 필드라 글자가 마스킹됨)
           - `k:"nkey"` 네이티브 키(IME 이전 원본)
           - `k:"click"` / `k:"focus"` 클릭·포커스 대상 선택자와 라벨
           - `k:"input"` 입력 길이만(내용은 기록하지 않음)
           - `k:"console"` 페이지 콘솔, `k:"net"` fetch/XHR 결과, `k:"http"` 서버가 받은 요청(GET 포함)
        3. `\(dir)/view-trace.jsonl` — 같은 시각(t, epoch ms)에 화면이 무엇이었는지.
        4. `\(dir)/actions.jsonl` — 같은 구간의 액션 로그.
        5. `\(dir)/app.log` — 네이티브 로그 꼬리. `\(dir)/screen.png` — 끄는 순간의 화면.
        6. `\(dir)/meta.json` — 앱 버전 · 데이터 디렉터리 · 캡처 당시 앱 상태.

        goal-core.md 의 "증상" 칸이 비어 있으면 로그를 뒤지지 말고, 이미 적혀 있는 조작 순서를
        근거로 "이 흐름에서 무엇이 잘못 보였나요?"라고 한 번 물어보고 답을 기다리세요 —
        증상 없이는 무엇이 버그인지 판단할 수 없고, 추측으로 분석을 시작하면 안 됩니다.
        증상이 적혀 있으면 그 시각 근처의 기록·영상으로 원인을 찾고 수정안까지 제시하세요.
        """
        if let url = IssuePaths.coreURL(seq: seq) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? core.write(to: url, atomically: true, encoding: .utf8)
        }
        if let url = IssuePaths.detailURL(seq: seq) {
            try? detail.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // Explicit on/off for the BGM system, used by the dashboard BGM view's remote control
    // (POST /api/bgm/control). Mirrors toggleMusic so the menu-bar widget and the dashboard
    // stay in sync. Enabling lets the heartbeat gating start the director on its next tick;
    // disabling stops it immediately (and unmutes, since the browser no longer owns output).
    func setBGMEnabled(_ on: Bool) {
        guard Settings.shared.musicEnabled != on else { return }
        Settings.shared.musicEnabled = on
        ActionLog.shared.append(actionEvent(on ? "bgmOn" : "bgmOff",
            detail: on ? "BGM 시스템 켬" : "BGM 시스템 끔"))
        if !on { director.stop(); applyNativeMute() }
    }

    // Explicit "I don't like this track" from the menu: down-weight + cooldown +
    // immediate switch (handled by the director), plus a context snapshot to the
    // event log so the algorithm can later learn *when* it was disliked.
    func dislikeCurrentTrack() {
        guard director.isPlaying, let info = director.dislikeCurrentTrack() else { return }

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let cal = Calendar.current
        var c = TrackEventLog.Context()
        c.signal = "dislike"
        c.trackKey = info.key
        c.title = info.title
        c.trackBPM = Int(info.bpm)
        c.targetBPM = Int(director.targetBPM)
        c.phase = director.phase.rawValue
        c.profile = director.activeProfileLabel
        c.app = activeAppLabel.isEmpty ? "-" : activeAppLabel
        c.site = chromeDomain.isEmpty ? "-" : chromeDomain
        c.norm = director.lastNorm
        c.rate = Int(activity.activityRate)
        c.sessionSeconds = Int(sessionSeconds)
        c.todaySeconds = Int(store.todaySeconds)
        c.totalSeconds = Int(store.data.totalSeconds)
        c.hour = cal.component(.hour, from: Date())
        c.weekday = cal.component(.weekday, from: Date())
        c.meeting = ValueTier.isMeeting(bundleID: frontBundle, site: chromeDomain)
        trackEvents.append(c)
        var e = actionEvent("dislike", detail: "이 곡 싫어요 — 쿨다운 + 즉시 전환")
        e.track = info.title
        e.trackKey = info.key
        e.bpm = Int(info.bpm)
        ActionLog.shared.append(e)
    }

    func requestAccessibility() {
        activity.requestAccessibilityPrompt()
    }

    func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    // MARK: - Dashboard

    // Open (and focus) the native app window on the dashboard — no browser. The in-window toggle
    // can switch to BGM from here.
    func openDashboard() {
        dashboard.start { [weak self] port in
            DispatchQueue.main.async { self?.appWindow.show(port: port, mode: .dashboard) }
        }
    }

    // Open (and focus) the native app window in BGM mode — the guaranteed-autoplay surface. Opening
    // BGM is an explicit "I want BGM" action, so it turns the BGM system on (symmetric with close=off).
    func openBGMWindow() {
        setBGMEnabled(true)
        dashboard.start { [weak self] port in
            DispatchQueue.main.async { self?.appWindow.show(port: port, mode: .bgm) }
        }
    }

    // Toggle whether the app window auto-opens (in BGM mode) on launch; turning it on opens it now.
    func toggleBGMWindowAutoOpen() {
        let on = !Settings.shared.bgmWindowEnabled
        Settings.shared.bgmWindowEnabled = on
        if on { openBGMWindow() }
    }

    // MARK: - Unified window-toggle menu entry (single item, replaces the old two "열기" entries)

    // Read-only state for the menu label: is the window open, and which mode is it showing.
    // Mirrors the in-window segmented toggle exactly — same appWindow, same `mode`.
    var appWindowIsOpen: Bool { appWindow.isOpen }
    var appWindowMode: AppWindowController.Mode { appWindow.mode }
    // Test-only: see AppWindowController.testUserClose and the /api/debug/window-close handler.
    func appWindowTestClose() { appWindow.testUserClose() }
    // TEMPORARY QA hook (Korean-IME investigation): see AppWindowController.debugNavigate /
    // the /api/debug/window-nav handler.
    func appWindowDebugNavigate(path: String) {
        dashboard.start { [weak self] port in
            DispatchQueue.main.async { self?.appWindow.debugNavigate(path: path, port: port) }
        }
    }

    // Test-only (SPEC.html screenshots): synchronously fetch a PNG snapshot of the app window's
    // WKWebView, blocking the calling (server) thread with a semaphore since HTTP GET handlers here
    // are synchronous while WKWebView.takeSnapshot is completion-based. See /api/debug/snapshot.
    func appWindowSnapshotPNG(mode: AppWindowController.Mode, tab: String?) -> Data? {
        let sema = DispatchSemaphore(value: 0)
        var result: Data?
        DispatchQueue.main.async {
            self.appWindow.snapshotPNG(mode: mode, tab: tab) { png in
                result = png
                sema.signal()
            }
        }
        _ = sema.wait(timeout: .now() + 5)
        return result
    }

    // Single toggle action for the unified menu entry:
    //  - window closed -> open it (in whatever mode it last showed, i.e. appWindow.mode default)
    //  - window open   -> switch ITS mode (same window, same toggle the in-window segmented
    //    control drives), so the menu entry and the in-window toggle always agree.
    func toggleAppWindowMode() {
        if appWindow.isOpen {
            let next: AppWindowController.Mode = (appWindow.mode == .bgm) ? .dashboard : .bgm
            if next == .bgm { openBGMWindow() } else { openDashboard() }
        } else {
            if appWindow.mode == .bgm { openBGMWindow() } else { openDashboard() }
        }
    }

    // MARK: - Session transcripts (connect + readable view)

    // ~/.claude/projects — where Claude Code stores per-project session transcripts.
    private var claudeProjectsBase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // Best guess at the "current" Claude session folder: the project subdirectory that
    // holds the most recently modified .jsonl. Used as the picker's default location so
    // the user lands on the active project. Falls back to the base, then home.
    private func currentClaudeSessionDir() -> URL {
        let fm = FileManager.default
        let base = claudeProjectsBase
        let fallback = fm.fileExists(atPath: base.path) ? base : fm.homeDirectoryForCurrentUser
        guard let subs = try? fm.contentsOfDirectory(at: base,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return fallback }
        var best: (dir: URL, when: Date)?
        for dir in subs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let files = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if best == nil || m > best!.when { best = (dir, m) }
            }
        }
        return best?.dir ?? fallback
    }

    // Resolve a goal's transcript file: prefer the stored path, else locate
    // <sessionId>.jsonl somewhere under ~/.claude/projects.
    private func resolveTranscript(_ goal: ReviewStore.Goal) -> URL? {
        let fm = FileManager.default
        if !goal.transcriptPath.isEmpty, fm.fileExists(atPath: goal.transcriptPath) {
            return URL(fileURLWithPath: goal.transcriptPath)
        }
        guard !goal.sessionId.isEmpty,
              let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase, includingPropertiesForKeys: nil) else { return nil }
        for dir in subs {
            let cand = dir.appendingPathComponent(goal.sessionId + ".jsonl")
            if fm.fileExists(atPath: cand.path) { return cand }
        }
        return nil
    }

    // Append a "goal-title-override" record to a session goal's transcript. The
    // session hook (cc-session-hook.sh) prefers the last such record over Claude's
    // aiTitle, so a manual rename sticks across future session events. Best-effort:
    // does nothing if the transcript can't be located or opened.
    private func writeTitleOverride(for goal: ReviewStore.Goal, title: String) {
        guard let url = resolveTranscript(goal),
              let data = "{\"type\":\"goal-title-override\",\"title\":\(jsonString(title))}\n".data(using: .utf8),
              let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        // Ensure our record starts on its own line (transcripts are line-delimited JSON).
        let end = fh.seekToEndOfFile()
        if end > 0 {
            fh.seek(toFileOffset: end - 1)
            if fh.readDataToEndOfFile() != Data([0x0a]) { fh.seekToEndOfFile(); fh.write(Data([0x0a])) }
        }
        fh.seekToEndOfFile()
        fh.write(data)
    }

    // Open a native file picker for the user to attach a transcript to a goal. Runs on
    // the main thread (modal). The session id is the file's base name, since Claude
    // names transcripts <sessionId>.jsonl.
    private func connectSessionViaPicker(goalId: String) {
        let panel = NSOpenPanel()
        panel.title = "세션 트랜스크립트 연결"
        panel.message = "이 목표에 연결할 Claude 세션 파일(.jsonl)을 선택하세요"
        panel.prompt = "연결"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentClaudeSessionDir()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sid = url.deletingPathExtension().lastPathComponent
        reviewStore.connectSession(goalId: goalId, sessionId: sid, transcriptPath: url.path)
    }

    // Open a native folder picker to connect a plugin to a project folder. Runs on the
    // main thread (modal). The chosen folder is verified by PluginStore; an arbitrary
    // folder (no Claude transcript inside) is recorded as 잘못된 연결, not silently OK.
    private func connectPluginViaPicker(pluginId: String) {
        let panel = NSOpenPanel()
        panel.title = "플러그인 폴더 연결"
        panel.prompt = "연결"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // Folder-based plugins only (toggle plugins install without a picker).
        panel.message = "Claude 루트 폴더 ~/.claude 를 선택하세요 (모든 프로젝트 세션을 연동)"
        // Default to ~/.claude so the user lands on the root (all projects), not one project.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pluginStore.connect(pluginId: pluginId, folderPath: url.path)
        pluginStore.refreshClaudeProjects()   // populate the project list right away
        syncPluginWorkers()                    // connecting activates the plugin's workers
    }

    // GET /transcript?goal=<id> -> a readable HTML rendering of the goal's transcript.
    // Returns nil (404) only when the goal id is unknown; a connected-but-missing file
    // still yields a page that explains the problem.
    func transcriptPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path) else { return nil }
        // A bare ?session=<id> view: any session linked to a goal (not just the goal's
        // primary one) can open its transcript. Resolve the .jsonl directly by id.
        if let sid = comps.queryItems?.first(where: { $0.name == "session" })?.value, !sid.isEmpty {
            guard let url = transcriptURL(forSessionId: sid) else {
                return transcriptHTML(title: "세션 \(String(sid.prefix(8)))",
                    body: "<p class=\"empty\">이 세션의 트랜스크립트 파일을 찾을 수 없습니다.</p>")
            }
            let title = transcriptTitle(url)
            return transcriptHTML(title: title.isEmpty ? "세션 \(String(sid.prefix(8)))" : title,
                                  body: renderTranscriptBody(url))
        }
        guard let id = comps.queryItems?.first(where: { $0.name == "goal" })?.value else { return nil }
        // reviewStore is main-thread owned; copy out the (value-type) goal under main.
        let goalOpt: ReviewStore.Goal? = DispatchQueue.main.sync { reviewStore.goals.first { $0.id == id } }
        guard let goal = goalOpt else { return nil }
        guard let url = resolveTranscript(goal) else {
            let where_ = goal.transcriptPath.isEmpty ? "(경로 미지정)" : goal.transcriptPath
            return transcriptHTML(title: goal.text,
                body: "<p class=\"empty\">연결된 트랜스크립트 파일을 찾을 수 없습니다.<br>\(htmlEscape(where_))</p>")
        }
        return transcriptHTML(title: goal.text, body: renderTranscriptBody(url))
    }

    private func renderTranscriptBody(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "<p class=\"empty\">파일을 읽을 수 없습니다.</p>"
        }
        var out = ""
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let html = self.renderTranscriptLine(obj) else { return }
            out += html
        }
        return out.isEmpty ? "<p class=\"empty\">표시할 메시지가 없습니다.</p>" : out
    }

    // Like renderTranscriptBody but only the last `limit` conversational bubbles — the
    // "현재 내용"(latest progress) view on the goal page wants what the session is doing
    // now, not the whole history.
    private func renderTranscriptTail(_ url: URL, limit: Int) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "<p class=\"empty\">파일을 읽을 수 없습니다.</p>"
        }
        var bubbles: [String] = []
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let html = self.renderTranscriptLine(obj) else { return }
            bubbles.append(html)
        }
        if bubbles.isEmpty { return "<p class=\"empty\">표시할 메시지가 없습니다.</p>" }
        return bubbles.suffix(limit).joined()
    }

    // One transcript line -> a message bubble, or nil for non-conversational records
    // (queue-operation, mode, ai-title, last-prompt, system, …).
    private func renderTranscriptLine(_ obj: [String: Any]) -> String? {
        let type = obj["type"] as? String ?? ""
        guard type == "user" || type == "assistant",
              let msg = obj["message"] as? [String: Any] else { return nil }
        let role = (msg["role"] as? String) ?? type
        let blocks = transcriptBlocksHTML(msg["content"])
        if blocks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let who = role == "user" ? "사용자" : "어시스턴트"
        return "<div class=\"msg \(role)\"><div class=\"who\">\(htmlEscape(who))</div><div class=\"body\">\(blocks)</div></div>"
    }

    private func transcriptBlocksHTML(_ content: Any?) -> String {
        if let s = content as? String { return "<div class=\"text\">\(htmlEscape(s))</div>" }
        guard let arr = content as? [[String: Any]] else { return "" }
        var out = ""
        for b in arr {
            switch b["type"] as? String ?? "" {
            case "text":
                if let s = b["text"] as? String { out += "<div class=\"text\">\(htmlEscape(s))</div>" }
            case "thinking":
                if let s = b["thinking"] as? String {
                    out += "<details class=\"think\"><summary>thinking</summary><pre>\(htmlEscape(s))</pre></details>"
                }
            case "tool_use":
                let name = b["name"] as? String ?? "tool"
                out += "<details class=\"tool\"><summary>🔧 \(htmlEscape(name))</summary><pre>\(htmlEscape(truncateText(prettyJSON(b["input"]), 2000)))</pre></details>"
            case "tool_result":
                out += "<details class=\"result\"><summary>↳ 결과</summary><pre>\(htmlEscape(truncateText(toolResultText(b["content"]), 2000)))</pre></details>"
            default:
                break
            }
        }
        return out
    }

    private func prettyJSON(_ v: Any?) -> String {
        guard let v = v else { return "" }
        if let s = v as? String { return s }
        if JSONSerialization.isValidJSONObject(v),
           let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            return String(decoding: d, as: UTF8.self)
        }
        return String(describing: v)
    }
    private func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.joined(separator: "\n")
        }
        return prettyJSON(content)
    }
    private func truncateText(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "\n… (\(s.count - n)자 생략)"
    }
    // GET /worker?id=<workerId> -> a readable run log for one background worker:
    // when it fired, why (the trigger/condition), and what changed. Backed by the
    // per-worker JSONL written by WorkerLog (size-capped; oldest lines trimmed).
    func workerLogPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value else { return nil }
        guard let info = WorkerRegistry.shared.info(id) else {
            return workerLogHTML(title: "알 수 없는 워커", subtitle: htmlEscape(id),
                body: "<p class=\"empty\">등록되지 않은 워커입니다.</p>")
        }
        let entries = WorkerLog.shared.recent(id, limit: 500)
        let s = Int(info.interval.rounded())
        let intervalLabel = (s >= 60 && s % 60 == 0) ? "\(s / 60)분" : "\(s)초"
        let subtitle = "\(htmlEscape(info.detail)) · 주기 \(intervalLabel) · 최근 \(entries.count)건 (오래된 항목은 자동 정리)"
        if entries.isEmpty {
            return workerLogHTML(title: info.name, subtitle: subtitle,
                body: "<p class=\"empty\">아직 기록된 실행이 없습니다.</p>")
        }
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.timeZone = Settings.shared.displayTimeZone
        tf.dateFormat = "MM-dd HH:mm:ss"
        var rows = ""
        for e in entries {
            let when = tf.string(from: Date(timeIntervalSince1970: Double(e.t) / 1000))
            let cls = e.level == "error" ? " style=\"color:#e2667d\"" : ""
            let tag = e.level == "error" ? "⚠ " : ""
            rows += "<tr\(cls)><td class=\"t\">\(htmlEscape(when))</td>"
                + "<td class=\"why\">\(tag)\(htmlEscape(e.why))</td>"
                + "<td class=\"eff\">\(htmlEscape(e.effect))</td></tr>"
        }
        let body = """
        <table>
          <thead><tr><th>시각</th><th>왜 실행했나 (실행 조건)</th><th>무엇이 바뀌었나 (영향)</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return workerLogHTML(title: info.name, subtitle: subtitle, body: body)
    }

    // GET /worker-log -> every worker's run log merged into one chronological
    // timeline (newest first), so the whole background is readable at a glance.
    // Each worker keeps a stable color so rows are easy to scan by source.
    func workerLogAllPage(_ path: String) -> String? {
        let workers = WorkerRegistry.shared.allWorkers()
        let palette = ["#5b8cff", "#36c08a", "#e2667d", "#e0a23a", "#9b7bff",
                       "#21c7b8", "#ff8a5b", "#7d8aff", "#c08adf"]
        var colorById: [String: String] = [:]
        var nameById: [String: String] = [:]
        for (i, w) in workers.enumerated() {
            colorById[w.id] = palette[i % palette.count]
            nameById[w.id] = w.name
        }
        var merged: [(t: Int, id: String, why: String, effect: String, level: String)] = []
        for w in workers {
            for e in WorkerLog.shared.recent(w.id, limit: 300) {
                merged.append((e.t, w.id, e.why, e.effect, e.level))
            }
        }
        merged.sort { $0.t > $1.t }
        if merged.count > 1000 { merged = Array(merged.prefix(1000)) }
        let subtitle = "전체 워커 통합 타임라인 · 최근 \(merged.count)건 (워커당 최대 300건, 오래된 항목은 자동 정리)"
        if merged.isEmpty {
            return workerLogHTML(title: "워커 통합 로그", subtitle: subtitle,
                body: "<p class=\"empty\">아직 기록된 실행이 없습니다.</p>")
        }
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.timeZone = Settings.shared.displayTimeZone
        tf.dateFormat = "MM-dd HH:mm:ss"
        var rows = ""
        for e in merged {
            let when = tf.string(from: Date(timeIntervalSince1970: Double(e.t) / 1000))
            let color = colorById[e.id] ?? "#8a93a3"
            let name = nameById[e.id] ?? e.id
            let dot = "<span style=\"display:inline-block;width:8px;height:8px;border-radius:50%;"
                + "margin-right:6px;vertical-align:middle;background:\(color)\"></span>"
            let rowStyle = e.level == "error" ? " style=\"color:#e2667d\"" : ""
            let tag = e.level == "error" ? "⚠ " : ""
            rows += "<tr\(rowStyle)><td class=\"t\">\(htmlEscape(when))</td>"
                + "<td class=\"wk\" style=\"white-space:nowrap\">\(dot)\(htmlEscape(name))</td>"
                + "<td class=\"why\">\(tag)\(htmlEscape(e.why))</td>"
                + "<td class=\"eff\">\(htmlEscape(e.effect))</td></tr>"
        }
        let body = """
        <table>
          <thead><tr><th>시각</th><th>워커</th><th>왜 실행했나 (실행 조건)</th><th>무엇이 바뀌었나 (영향)</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        """
        return workerLogHTML(title: "워커 통합 로그", subtitle: subtitle, body: body)
    }

    // GET /device-cron?id=<label> -> one launchd/crontab job's run history, in the same
    // shape as the app's own worker log: when it ran, what it did, how it ended. launchd
    // keeps no per-run trail (only a last exit code), so the history IS the job's log file
    // — which is also the honest answer when a job writes no log: there is nothing to show.
    func deviceCronPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value else { return nil }
        guard let j = DeviceCronScanner.shared.job(id: id) else {
            return workerLogHTML(title: "알 수 없는 작업", subtitle: htmlEscape(id),
                body: "<p class=\"empty\">이 맥에 등록되지 않은 작업입니다.</p>", back: "/cron")
        }

        let status: String
        if j.disabled { status = "꺼짐 (launchctl에서 disable됨)" }
        else if !j.loaded { status = "미로드 — 파일만 있고 launchd에 등록되지 않았습니다 (지금은 실행되지 않음)" }
        else if j.lastExit > 0 { status = "오류 — 마지막 실행이 종료 코드 \(j.lastExit)로 끝났습니다" }
        else if j.pid > 0 { status = "동작 중 (PID \(j.pid))" }
        else { status = "대기 — 로드됨, 다음 실행 시각을 기다리는 중" }

        var facts: [(String, String)] = [
            ("프로젝트", j.project.isEmpty ? "미분류" : j.project),
            ("상태", status),
            ("주기", j.schedule),
            ("실행 횟수", j.runs >= 0 ? "\(j.runs)회" : "알 수 없음 (crontab은 집계하지 않음)"),
            ("실행 대상", j.detail),
            ("등록 위치", j.path),
            ("작업명(개발용)", j.label)
        ]
        if !j.outLog.isEmpty { facts.append(("출력 로그", j.outLog)) }
        if !j.errLog.isEmpty && j.errLog != j.outLog { facts.append(("오류 로그", j.errLog)) }

        let factRows = facts.map {
            "<tr><td class=\"t\">\(htmlEscape($0.0))</td><td class=\"eff\" colspan=\"2\">\(htmlEscape($0.1))</td></tr>"
        }.joined()

        // stderr first: when a job is failing, that is the line the human came here for.
        var logBlocks = ""
        for (title, file) in [("오류 로그", j.errLog), ("출력 로그", j.outLog)] {
            guard !file.isEmpty else { continue }
            if title == "출력 로그" && file == j.errLog { continue }
            let lines = DeviceCronScanner.logTail(file)
            let inner = lines.isEmpty
                ? "<p class=\"empty\">비어 있습니다 — 아직 이 파일에 기록된 실행이 없습니다.</p>"
                : "<pre>" + lines.map(htmlEscape).joined(separator: "\n") + "</pre>"
            logBlocks += "<h2>\(title) <span class=\"mut\">\(htmlEscape(file)) · 최근 \(lines.count)줄</span></h2>\(inner)"
        }
        if j.outLog.isEmpty && j.errLog.isEmpty {
            logBlocks = "<h2>실행 기록</h2><p class=\"empty\">이 작업은 로그 파일을 지정하지 않아 실행 기록이 남지 않습니다."
                + " plist에 StandardOutPath를 추가하면 여기에 이력이 쌓입니다.</p>"
        }

        let body = """
        <table><tbody>\(factRows)</tbody></table>
        \(logBlocks)
        """
        let sub = "\(htmlEscape(j.project.isEmpty ? "미분류" : j.project)) · \(htmlEscape(j.source)) · \(htmlEscape(j.schedule))"
        return workerLogHTML(title: j.name, subtitle: sub, body: body, back: "/cron")
    }

    private func workerLogHTML(title: String, subtitle: String, body: String,
                               back: String = "/") -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(title)) · 워커 로그</title>
        <style>
          :root{--bg:#0e1116;--panel:#141821;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#5b8cff}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;z-index:30;background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:12px 20px 14px}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          header a.back{display:inline-flex;align-items:center;gap:7px;min-height:44px;margin:-4px 0 2px -10px;
            padding:0 12px;border-radius:9px;color:#b8c9e8;text-decoration:none;font-size:13px;font-weight:600}
          header a.back:hover{background:#1b2230;color:#e6efff}
          header a.back:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
          header a.back svg{width:17px;height:17px;stroke:currentColor;stroke-width:2;fill:none;flex:none}
          main{max-width:920px;margin:0 auto;padding:18px 20px 80px}
          table{width:100%;border-collapse:collapse}
          th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
          th{color:var(--mut);font-size:11px;letter-spacing:.04em;text-transform:uppercase;position:sticky;top:52px;background:var(--bg)}
          td.t{color:var(--mut);font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap}
          td.why{color:#cfd6e2}
          td.eff{color:#9fe0a0}
          tbody tr:hover{background:var(--panel)}
          .empty{color:var(--mut);text-align:center;padding:40px 0}
          h2{font-size:13px;color:var(--mut);letter-spacing:.04em;text-transform:uppercase;margin:26px 0 8px}
          h2 .mut{text-transform:none;letter-spacing:0;font-weight:400;font-size:11px}
          pre{margin:0;padding:12px 14px;background:var(--panel);border:1px solid var(--line);border-radius:10px;
            white-space:pre-wrap;word-break:break-word;font:12px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;
            color:#cdd4df;max-height:520px;overflow:auto}
        </style></head>
        <body>
          <script>window.CM_PAGE='\(back == "/cron" ? "cron" : "")';</script>
          \(SessionRail.html())
          <header><a class="back" href="\(back)" aria-label="\(back == "/cron" ? "크론 목록으로 돌아가기" : "대시보드로 돌아가기")"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 18l-6-6 6-6"/><path d="M9 12h10"/></svg><span>\(back == "/cron" ? "크론 목록" : "대시보드")</span></a><h1>\(htmlEscape(title))</h1><div class="sub">\(subtitle)</div></header>
          <main>\(body)</main>
        </body></html>
        """
    }

    // GET /workers.json — the worker snapshot ONLY, so the standalone 크론(/cron) page can poll
    // cheaply without pulling the heavy /data.json review payload. Main-thread read: the registry
    // is mutated on main (heartbeat recordRun/Error), matching sessionStateJSON's pattern.
    func workersJSON() -> String {
        DispatchQueue.main.sync { "{\"workers\":\(WorkerRegistry.shared.snapshotJSON())}" }
    }

    // GET /cron — the 크론(주기 작업) surface as its OWN page, decoupled from the dashboard's view
    // system. It embeds the shared session rail (so navigation/challenge dial stay consistent) and
    // renders the worker status table from /workers.json on its own 5s poll. Nothing here depends on
    // DashboardContent; the rail's cmNav routes 크론 here via location.href.
    func cronPage() -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>크론 · 주기 작업</title>
        <style>
          :root{--bg:#0e1116;--panel:#141821;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#5b8cff}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;z-index:30;display:flex;align-items:center;justify-content:space-between;gap:12px;
            background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          header a{color:var(--accent);text-decoration:none;font-size:12px}
          main{max-width:1080px;margin:0 auto;padding:18px 20px 80px}
          .panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px}
          /* narrow window → horizontal scroll instead of squeezing cells until Korean breaks per-glyph */
          .tablewrap{overflow-x:auto}
          table{width:100%;min-width:980px;border-collapse:collapse}
          th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top;white-space:nowrap}
          th{color:var(--mut);font-size:11px;letter-spacing:.04em;text-transform:uppercase}
          /* 하는 일: the only column allowed to wrap (at word boundaries), so the table stays sane */
          td:nth-child(3){white-space:normal;word-break:keep-all;min-width:280px}
          tbody tr:hover{background:#171c26}
          .muted{color:var(--mut)}
          .empty{color:var(--mut);text-align:center;padding:24px 0}
          .chip{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;margin:2px 4px 2px 0;background:#1d2230;border:1px solid var(--line);white-space:nowrap}
          .chip.bad{background:#2a1620;border-color:#5a2738;color:#ff9db0}
          .btn{background:#1d2230;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:6px 12px;font-size:13px;cursor:pointer;text-decoration:none;display:inline-block;white-space:nowrap}
          .btn:hover{background:#242b3b}
          .btn:disabled{opacity:.5;cursor:default}
          .legend{color:var(--mut);font-size:12px;margin-top:10px;display:flex;gap:18px;flex-wrap:wrap}
          .foot{color:var(--mut);font-size:11px;text-align:center;margin-top:18px}
          /* 탭: 앱이 등록한 워커 vs 이 맥에 등록된 주기 작업 — 두 목록의 출처가 다르므로 섞지 않는다 */
          .tabs{display:flex;gap:8px;margin-bottom:14px;flex-wrap:wrap}
          .tab{background:#161b25;border:1px solid var(--line);color:var(--mut);border-radius:8px;
            padding:7px 14px;font-size:13px;cursor:pointer}
          .tab:hover{background:#1d2230;color:var(--fg)}
          .tab[aria-selected="true"]{background:#1d2740;border-color:#33518f;color:var(--fg);font-weight:600}
          .tab .count{color:var(--mut);font-weight:400;margin-left:6px;font-size:12px}
          .mono{font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:#aab3c2}
          /* 이 표에서 제일 먼저 읽어야 하는 건 경로가 아니라 상태다. 그래서 상태를 작업
             바로 옆에 두고, 절대 경로인 실행 대상은 맨 끝에서 한 줄로 자른다(전체는 호버
             title). 가로 스크롤이 생겨도 잘리는 건 제일 안 급한 열이 된다. */
          .devtable{min-width:0}
          /* 이름과 '하는 일'은 한 줄로 자른다(전체는 호버 title). 벤더 업데이터의 긴 인자
             하나가 표 전체를 밀어내 정작 눌러야 할 '자세히'를 화면 밖으로 보내면 안 된다. */
          .devtable td:nth-child(1){max-width:260px}
          .devtable td:nth-child(3){white-space:nowrap;min-width:0}
          /* 그래도 좁아지면 가로 스크롤이 생기므로, 행동 열만은 오른쪽에 고정해 항상 닿게 한다. */
          .devtable th:last-child,.devtable td:last-child{position:sticky;right:0;
            background:var(--panel);box-shadow:-8px 0 8px -8px #000}
          .filters{margin-left:auto;display:flex;align-items:center;gap:12px;color:var(--mut);font-size:12px}
          .filters label{display:flex;align-items:center;gap:6px}
          .filters select{background:#161b25;border:1px solid var(--line);color:var(--fg);
            border-radius:8px;padding:6px 8px;font-size:12px}
          .hidden-note{color:var(--mut);font-size:11px}
          /* 개발용 식별자(reverse-DNS 라벨, plist 경로)는 사람이 읽을 이름 밑에 작게. */
          .devname{display:block}
          .devlabel{display:block;color:var(--mut);font:11px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;
            margin-top:2px;max-width:230px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .devname{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .proj{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;
            background:#1b2233;border:1px solid #2c3852;color:#a9bce0;white-space:nowrap}
          .proj.sys{background:#1a1d24;border-color:#2a3038;color:#7c8494}
        </style></head>
        <body>
          <script>window.CM_PAGE='cron';</script>
          \(SessionRail.html())
          <header>
            <div><h1>크론 · 주기 작업</h1><div class="sub">주기적으로 실행해야 하는 백그라운드 작업(워커)을 등록·관리합니다</div></div>
            <a class="btn" href="/worker-log">전체 로그 타임라인</a>
          </header>
          <main>
            <div class="tabs" role="tablist">
              <button class="tab" role="tab" id="tabbtn-app" aria-selected="true"
                      onclick="showTab('app')">컨디션 메이트 등록<span class="count" id="cnt-app"></span></button>
              <button class="tab" role="tab" id="tabbtn-device" aria-selected="false"
                      onclick="showTab('device')">이 디바이스 등록<span class="count" id="cnt-device"></span></button>
              <!-- 보기 필터는 탭 줄 오른쪽 끝. 40개 프로젝트가 섞인 목록에서 "지금 뭐가 도나"와
                   "이 프로젝트는 뭐가 도나" 두 질문에만 답하면 되므로 셀렉트 두 개로 충분하다. -->
              <div class="filters">
                <label>보기
                  <select id="fState" onchange="setFilter()">
                    <option value="live">동작 중만</option>
                    <option value="bad">문제만 (오류·미로드·꺼짐)</option>
                    <option value="all">전체</option>
                  </select>
                </label>
                <label id="fProjWrap">프로젝트
                  <select id="fProj" onchange="setFilter()"><option value="">전체</option></select>
                </label>
                <span class="hidden-note" id="hiddenNote"></span>
              </div>
            </div>
            <section id="tab-app">
            <div class="panel">
              <div class="tablewrap">
              <table>
                <thead><tr><th>워커</th><th>구분</th><th>하는 일</th><th>주기</th><th>마지막 실행</th><th>다음 실행</th><th>실행</th><th>상태</th><th>로그</th></tr></thead>
                <tbody id="workerrows"><tr><td colspan="9" class="empty">불러오는 중…</td></tr></tbody>
              </table>
              </div>
              <div class="legend"><span><span class="chip" style="margin:0">동작 중</span> = 일정대로 실행 중 · <span class="chip bad" style="margin:0">유휴</span> = 현재 멈춤(세션 비활성 등) · <span class="chip bad" style="margin:0">오류</span> = 데이터 싱크 이상(로그 확인) · <b>구분</b> 기본=항상 실행, 플러그인=연결 시에만, 자동화=외부 스케줄러(launchd)가 주기 실행, SUT=Supertrust 일일 리포트(launchd 09:10 → /nss-report-daily), 수동=퇴근 시 손으로 실행(주기 칸은 1회 실행 중 라운드 간격)</span></div>
            </div>
            </section>
            <section id="tab-device" hidden>
            <div class="panel">
              <div class="tablewrap">
              <table class="devtable">
                <thead><tr><th>작업</th><th>프로젝트</th><th>상태</th><th>주기</th><th>마지막 실행</th><th>실행</th><th>로그</th></tr></thead>
                <tbody id="devicerows"><tr><td colspan="7" class="empty">불러오는 중…</td></tr></tbody>
              </table>
              </div>
              <div class="legend"><span>이 맥에 직접 등록된 주기 작업을 자동으로 훑어 보여 줍니다 — 앱이 아니라 launchd(<span class="mono">~/Library/LaunchAgents</span>, <span class="mono">/Library/LaunchAgents</span>)와 <span class="mono">crontab -l</span>이 원본입니다. 새로 등록하면 다음 새로고침에 그냥 나타납니다.</span></div>
              <div class="legend"><span><span class="chip" style="margin:0">동작 중</span> = 지금 프로세스가 떠 있음 · <span class="chip" style="margin:0">대기</span> = 로드됨, 다음 시각을 기다리는 중 · <span class="chip bad" style="margin:0">오류</span> = 마지막 실행이 0이 아닌 코드로 종료 · <span class="chip bad" style="margin:0">미로드</span> = 파일만 있고 launchd에 등록되지 않음(죽어 있음) · <span class="chip bad" style="margin:0">꺼짐</span> = launchctl에서 disable됨 · <b>마지막 실행</b>은 로그 파일(StandardOutPath) 수정 시각 기준이라, 로그를 안 남기는 작업은 '–'로 나옵니다</span></div>
            </div>
            </section>
            <div class="foot">127.0.0.1 로컬 전용</div>
          </main>
          <script>
          function esc(s){ return (s||'-').replace(/[&<>]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c];}); }
          function post(p,b){ return fetch(p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}); }
          function fmtInterval(s){ if(s>0&&s%86400===0) return (s/86400)+'일';
            if(s>=3600&&s%3600===0) return (s/3600)+'시간';
            if(s>=60&&s%60===0) return (s/60)+'분'; return s+'초'; }
          function fmtAgo(sec){ if(sec<0) return '아직 없음';
            if(sec<60) return sec+'초 전'; var m=(sec/60)|0,s=sec%60; return m+'분 '+(s>0?s+'초 ':'')+'전'; }
          // Live countdown for 다음 실행. Scales the unit so a daily worker reads
          // "23시간 51분 후" instead of a raw "86400초 후".
          function fmtCountdown(sec){ if(sec<0) return '–'; sec=Math.max(0,sec);
            if(sec<60) return sec+'초 후';
            if(sec<3600){ var m=(sec/60)|0,s=sec%60; return m+'분 '+(s>0?s+'초 ':'')+'후'; }
            if(sec<86400){ var h=(sec/3600)|0,m=((sec%3600)/60)|0; return h+'시간 '+(m>0?m+'분 ':'')+'후'; }
            var d=(sec/86400)|0,h=((sec%86400)/3600)|0; return d+'일 '+(h>0?h+'시간 ':'')+'후'; }
          var _workers=[], _workersBase=0;
          function renderWorkers(arr){
            _workers=Array.isArray(arr)?arr:[];
            _workersBase=performance.now();
            var rows=document.getElementById('workerrows');
            // 디바이스 탭과 같은 규칙: 탭을 열지 않아도 문제가 있는지 배지에서 보인다.
            // 여기서 '문제'는 오류뿐 — 유휴/꺼짐은 의도한 상태라 세지 않는다.
            var c=document.getElementById('cnt-app');
            var werr=_workers.filter(function(w){ return w.error&&w.enabled!==false; }).length;
            if(c) c.textContent=_workers.length+(werr?' · 문제 '+werr:'');
            if(!_workers.length){ rows.innerHTML='<tr><td colspan="9" class="empty">데이터 없음</td></tr>'; return; }
            var ownerLabel=function(o,manual){
              if(manual) return '<span class="chip" style="margin:0;background:#7a8699;color:#fff" title="퇴근 시 손으로 실행(Scripts/bug-hunt.sh) — 스케줄러가 돌리지 않음">수동</span>';
              if(o==='qa') return '<span class="chip" style="margin:0;background:#3aa0ff;color:#fff" title="외부 자동화(launchd → claude -p)가 보고">자동화</span>';
              if(o==='sut') return '<span class="chip" style="margin:0;background:#12b886;color:#fff" title="Supertrust 일일 자동화(launchd 09:10 → claude -p /nss-report-daily)가 보고">SUT</span>';
              if(o&&o!=='core') return '<span class="chip" style="margin:0;background:#9b7bff;color:#fff" title="'+esc(o)+'">플러그인</span>';
              return '<span class="muted">기본</span>';
            };
            // 인덱스 i 는 필터와 무관하게 _workers 원본 기준으로 유지한다 — tickWorkers 가
            // wk_ago_<i>/wk_next_<i> 로 셀을 찾기 때문. 걸러진 행은 id 가 없을 뿐이고,
            // tickWorkers 는 이미 null 을 건너뛴다.
            var shown=0;
            rows.innerHTML=_workers.map(function(w,i){
              if(!workerVisible(w)) return '';
              shown++;
              var off=w.enabled===false;
              var badge;
              if(off) badge='<span class="chip bad" title="사용자가 끔">꺼짐</span>';
              else { badge=w.active?'<span class="chip">동작 중</span>':'<span class="chip bad">유휴</span>';
                if(w.error) badge='<span class="chip bad" title="'+esc(w.errorMsg||'')+'">오류 ⚠</span> '+badge; }
              // 앱 창(WKWebView) 안에서 그대로 열려야 한다 — target="_blank" 는 기본 브라우저로 튕긴다.
              var more=w.id?'<a class="btn" href="/worker?id='+encodeURIComponent(w.id)+'">자세히</a>':'';
              var ctrl='';
              if(w.toggleable) ctrl+=' <button class="btn" onclick="toggleWorker(\\''+esc(w.id)+'\\','+off+')">'+(off?'켜기':'끄기')+'</button>';
              if(w.runnable) ctrl+=' <button class="btn" title="지금 한 번 실행" onclick="runWorker(this,\\''+esc(w.id)+'\\')"'+(off?' disabled':'')+'>즉시 실행</button>';
              // 앱 밖 프로세스(Slack 수집 데몬, 자동 빌더)는 여기서 직접 되살릴 수 있어야
              // 한다 — 앱이 자동으로 복구하지만, 사용자가 지금 당장 확인하고 싶을 때의 수동 경로.
              if(w.restartable) ctrl+=' <button class="btn" title="이 워커를 다시 시작합니다 (앱이 자동 복구에 실패했을 때)" onclick="restartDaemon(this,\\''+esc(w.id)+'\\')"'+(off?' disabled':'')+'>다시 연결</button>';
              return '<tr'+(w.error&&!off?' style="background:rgba(226,102,125,0.08)"':'')+(off?' style="opacity:0.6"':'')+'><td><b>'+esc(w.name)+'</b></td>'
                +'<td>'+ownerLabel(w.owner,w.manual)+'</td>'
                +'<td class="muted">'+esc(w.detail)+'</td>'
                +'<td'+(w.manual?' title="자동 실행 주기가 아니라, 1회 실행 동안 도는 라운드 간격"':'')+'>'+(w.manual?'라운드 '+fmtInterval(w.interval):fmtInterval(w.interval))+'</td>'
                +'<td id="wk_ago_'+i+'">'+fmtAgo(w.agoSec)+'</td>'
                +'<td id="wk_next_'+i+'">'+(!off&&w.active&&w.nextSec>=0?fmtCountdown(w.nextSec):'–')+'</td>'
                +'<td>'+(w.runs||0).toLocaleString()+'</td>'
                +'<td>'+badge+'</td>'
                +'<td>'+more+ctrl+'</td></tr>';
            }).join('');
            if(!shown) rows.innerHTML='<tr><td colspan="9" class="empty">이 조건에 맞는 워커가 없습니다 — 보기를 \\'전체\\'로 바꿔 보세요</td></tr>';
            noteHidden(_workers.length-shown,'app');
          }
          function toggleWorker(id,wasOff){ post('/api/worker/toggle',{id:id,enabled:wasOff}).then(function(){ setTimeout(load,300); }); }
          function runWorker(btn,id){ if(btn){ btn.disabled=true; btn.textContent='실행 중…'; }
            post('/api/worker/run',{id:id}).then(function(){ setTimeout(load,1500); }); }
          function restartDaemon(btn,id){ if(btn){ btn.disabled=true; btn.textContent='다시 시작 중…'; }
            post('/api/worker/restart',{id:id}).then(function(){ setTimeout(load,2500); }); }
          function tickWorkers(){ if(!_workers.length) return;
            var elapsed=Math.floor((performance.now()-_workersBase)/1000);
            _workers.forEach(function(w,i){
              if(w.agoSec>=0){ var a=document.getElementById('wk_ago_'+i); if(a) a.textContent=fmtAgo(w.agoSec+elapsed); }
              if(w.active&&w.nextSec>=0){ var n=document.getElementById('wk_next_'+i);
                if(n) n.textContent=fmtCountdown(w.nextSec-elapsed); }
            });
          }
          // --- 이 디바이스 탭 -------------------------------------------------------
          // 출처가 launchd/crontab이라 앱이 켜고 끌 수 없다. 읽기 전용으로만 보여 주고,
          // '죽어 있음'(미로드)과 '오류'(마지막 종료 코드 != 0)를 구분하는 게 이 표의 목적.
          function fmtWhen(epoch){ if(!epoch) return '아직 없음';
            var sec=Math.floor(Date.now()/1000)-epoch; if(sec<0) sec=0;
            if(sec<60) return sec+'초 전';
            if(sec<3600) return ((sec/60)|0)+'분 전';
            if(sec<86400){ var h=(sec/3600)|0,m=((sec%3600)/60)|0; return h+'시간 '+(m>0?m+'분 ':'')+'전'; }
            return ((sec/86400)|0)+'일 전'; }
          function deviceBadge(j){
            if(j.disabled) return '<span class="chip bad" title="launchctl에서 disable된 상태">꺼짐</span>';
            if(!j.loaded) return '<span class="chip bad" title="plist 파일은 있지만 launchd에 로드되지 않음 — 지금은 절대 실행되지 않습니다">미로드</span>';
            if(j.lastExit>0) return '<span class="chip bad" title="마지막 실행이 종료 코드 '+j.lastExit+'로 끝났습니다">오류 ⚠ (exit '+j.lastExit+')</span>';
            if(j.pid>0) return '<span class="chip" title="PID '+j.pid+'">동작 중</span>';
            return '<span class="chip" title="로드됨 — 다음 실행 시각을 기다리는 중">대기</span>';
          }
          // 홈 경로를 ~ 로 줄인다. 잘린 셀에서 앞의 /Users/<이름>/ 이 자리를 다 먹는 걸 막는다.
          function tildify(s){ return String(s||'').replace(/\\/Users\\/[^/]+\\//g,'~/'); }
          function sourceChip(src){
            if(src==='crontab') return '<span class="chip" style="margin:0;background:#7a8699;color:#fff" title="classic unix crontab">crontab</span>';
            return '<span class="chip" style="margin:0;background:#3aa0ff;color:#fff" title="macOS launchd LaunchAgent">launchd</span>';
          }
          // 실행 대상 전체 경로 대신 실행되는 것의 이름만. 경로는 title 과 상세 페이지에 남는다.
          // '하는 일' 칸이 작업 이름의 반복이 되지 않으면서도 한 줄로 읽힌다.
          function shortCmd(s){
            var t=String(s||'').split(' ').filter(Boolean);
            // 첫 리다이렉트부터는 배관이지 '하는 일'이 아니다 — 대상 파일까지 통째로 끊는다.
            var cut=t.findIndex(function(x){ return /^\\d*>>?$/.test(x)||/^\\d*>/.test(x); });
            if(cut>=0) t=t.slice(0,cut);
            return t.map(function(x){ return x.indexOf('/')>=0 ? x.split('/').pop() : x; })
                    .join(' ').slice(0,60) || '(실행 경로 미지정)';
          }
          function projChip(p){
            if(!p) return '<span class="proj sys" title="어느 프로젝트에도 매이지 않음">미분류</span>';
            var sys=(p==='시스템');
            return '<span class="proj'+(sys?' sys':'')+'"'+(sys?' title="OS·벤더 업데이터 등 우리 작업이 아닌 것"':'')+'>'+esc(p)+'</span>';
          }
          var _device=[];
          function renderDevice(arr){
            _device=Array.isArray(arr)?arr:[];
            var rows=document.getElementById('devicerows');
            var cnt=document.getElementById('cnt-device');
            // 배지에는 '문제 있는 개수'를 띄운다 — 탭을 열지 않아도 죽은 게 있는지 보이도록.
            var bad=_device.filter(deviceBroken).length;
            if(cnt) cnt.textContent=_device.length+(bad?' · 문제 '+bad:'');
            syncProjectOptions();
            if(!_device.length){ rows.innerHTML='<tr><td colspan="7" class="empty">이 맥에 등록된 launchd/crontab 작업이 없습니다</td></tr>'; return; }
            var shown=0;
            rows.innerHTML=_device.map(function(j){
              if(!deviceVisible(j)) return '';
              shown++;
              var broken=deviceBroken(j)&&!j.disabled;
              return '<tr'+(broken?' style="background:rgba(226,102,125,0.08)"':'')+(j.disabled?' style="opacity:0.6"':'')+'>'
                // 사람이 부르는 이름이 먼저, 개발용 라벨은 그 밑에 작게.
                +'<td title="'+esc(shortCmd(j.detail))+' — '+esc(j.detail)+'">'
                  +'<b class="devname">'+esc(j.name)+'</b>'
                  +'<span class="devlabel" title="'+esc(j.label)+' · '+esc(tildify(j.path))+'">'+esc(j.label)+'</span></td>'
                +'<td>'+projChip(j.project)+'</td>'
                +'<td>'+deviceBadge(j)+'</td>'
                +'<td>'+esc(j.schedule)+'</td>'
                +'<td>'+fmtWhen(j.lastRunEpoch)+'</td>'
                +'<td>'+(j.runs>=0?j.runs.toLocaleString():'–')+'</td>'
                +'<td><a class="btn" href="/device-cron?id='+encodeURIComponent(j.id)+'">자세히</a></td></tr>';
            }).join('');
            if(!shown) rows.innerHTML='<tr><td colspan="7" class="empty">이 조건에 맞는 작업이 없습니다 — 보기나 프로젝트를 바꿔 보세요</td></tr>';
            noteHidden(_device.length-shown,'device');
          }

          // --- 보기 필터 -----------------------------------------------------------
          // 두 표의 '살아 있음' 정의가 다르다. 앱 워커는 방금 실행됐어야 동작 중이고,
          // launchd 작업은 로드만 돼 있으면 다음 시각에 확실히 뜬다(=대기도 살아 있는 것).
          var _filter={state:'live',proj:''};
          function deviceBroken(j){ return j.disabled||!j.loaded||j.lastExit>0; }
          function workerVisible(w){
            if(_filter.state==='all') return true;
            var alive=(w.enabled!==false)&&w.active&&!w.error;
            return _filter.state==='live' ? alive : !alive;
          }
          function deviceVisible(j){
            if(_filter.proj && (j.project||'')!==_filter.proj) return false;
            if(_filter.state==='all') return true;
            return _filter.state==='live' ? !deviceBroken(j) : deviceBroken(j);
          }
          // 두 표가 같은 안내 줄을 공유한다 — 지금 보고 있는 탭의 숫자만 쓰게 막지 않으면
          // 나중에 그려진 쪽(30초 폴링의 디바이스)이 앱 탭의 숫자를 덮어쓴다.
          var _tab='app';
          function noteHidden(n,which){
            if(which!==_tab) return;
            var el=document.getElementById('hiddenNote');
            if(el) el.textContent=n>0?(n+'개 숨김'):'';
          }
          // 프로젝트 목록은 스캔 결과에서 그대로 만든다 — 새 프로젝트가 생기면 그냥 나타난다.
          function syncProjectOptions(){
            var sel=document.getElementById('fProj'); if(!sel) return;
            var seen={}, list=[];
            _device.forEach(function(j){ var p=j.project||''; if(p&&!seen[p]){ seen[p]=1; list.push(p); } });
            list.sort(function(a,b){ return a==='시스템'?1:(b==='시스템'?-1:a.localeCompare(b)); });
            var want='<option value="">전체</option>'+list.map(function(p){
              return '<option value="'+esc(p)+'">'+esc(p)+'</option>'; }).join('');
            if(sel.innerHTML===want) return;   // 매 폴링마다 선택을 날리지 않도록
            sel.innerHTML=want;
            sel.value=_filter.proj;
            if(sel.value!==_filter.proj){ _filter.proj=''; sel.value=''; }
          }
          function setFilter(){
            var s=document.getElementById('fState'), p=document.getElementById('fProj');
            _filter.state=s?s.value:'live';
            _filter.proj=p?p.value:'';
            try{ localStorage.setItem('cmCronFilter',JSON.stringify(_filter)); }catch(e){}
            renderWorkers(_workers); renderDevice(_device);
          }

          function showTab(which){
            ['app','device'].forEach(function(t){
              document.getElementById('tab-'+t).hidden=(t!==which);
              document.getElementById('tabbtn-'+t).setAttribute('aria-selected',String(t===which));
            });
            // 프로젝트 축은 디바이스 목록에만 있다 — 앱 워커는 전부 컨디션 메이트 것.
            var pw=document.getElementById('fProjWrap'); if(pw) pw.style.display=(which==='device'?'':'none');
            _tab=which;
            try{ localStorage.setItem('cmCronTab',which); }catch(e){}
            noteHidden(which==='device' ? _device.filter(function(j){ return !deviceVisible(j); }).length
                                        : _workers.filter(function(w){ return !workerVisible(w); }).length, which);
          }
          function loadDevice(){ fetch('/device-cron.json').then(function(r){ return r.json(); })
            .then(function(d){ renderDevice(d.jobs); }).catch(function(){}); }
          function load(){ fetch('/workers.json').then(function(r){ return r.json(); })
            .then(function(d){ renderWorkers(d.workers); }).catch(function(){}); }
          try{ var f=JSON.parse(localStorage.getItem('cmCronFilter')||'null');
               if(f&&f.state){ _filter=f; document.getElementById('fState').value=f.state; } }catch(e){}
          try{ var saved=localStorage.getItem('cmCronTab'); showTab(saved||'app'); }catch(e){ showTab('app'); }
          load();
          // 서버가 30초 캐시를 물고 있으므로 이 주기보다 자주 훑을 이유가 없다.
          loadDevice();
          setInterval(loadDevice,30000);
          setInterval(tickWorkers,1000);
          </script>
        </body></html>
        """
    }

    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func transcriptHTML(title: String, body: String) -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(title))</title>
        <style>
          :root{--bg:#0e1116;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          main{max-width:920px;margin:0 auto;padding:18px 20px 80px}
          .msg{margin:14px 0;border:1px solid var(--line);border-radius:12px;overflow:hidden}
          .msg .who{font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:var(--mut);padding:8px 14px;border-bottom:1px solid var(--line);background:#11161f}
          .msg .body{padding:12px 14px}
          .msg.user .who{color:#9fc0ff}
          .msg.assistant .who{color:#8fe3c0}
          .text{white-space:pre-wrap;word-break:break-word}
          .text+.text,.text+details,details+.text,details+details{margin-top:10px}
          details{border:1px solid var(--line);border-radius:8px;background:#0f141c}
          details summary{cursor:pointer;padding:6px 10px;color:var(--mut);font-size:12px}
          details pre{margin:0;padding:10px 12px;border-top:1px solid var(--line);white-space:pre-wrap;word-break:break-word;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:#cdd4df;max-height:420px;overflow:auto}
          details.tool summary{color:#ffcf8f}
          details.result summary{color:#9fe0a0}
          details.think summary{color:#b6a8ff}
          .empty{color:var(--mut);text-align:center;padding:40px 0}
        </style></head>
        <body>
          <header><h1>\(htmlEscape(title))</h1><div class="sub">세션 트랜스크립트 · 읽기 전용</div></header>
          <main>\(body)</main>
        </body></html>
        """
    }

    // GET /breakdown?goal=<id> -> a minute-by-minute view of a session's work:
    // tool-call summary, per-minute token usage, and a grand total token tally.
    // Like /transcript, only session-linked goals (with a resolvable transcript)
    // produce a real page; everything else explains the gap.
    func breakdownPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path),
              let id = comps.queryItems?.first(where: { $0.name == "goal" })?.value else { return nil }
        let goalOpt: ReviewStore.Goal? = DispatchQueue.main.sync { reviewStore.goals.first { $0.id == id } }
        guard let goal = goalOpt else { return nil }
        guard let url = resolveTranscript(goal) else {
            let where_ = goal.transcriptPath.isEmpty ? "(경로 미지정)" : goal.transcriptPath
            return breakdownHTML(title: goal.text,
                body: "<p class=\"empty\">연결된 트랜스크립트 파일을 찾을 수 없습니다.<br>\(htmlEscape(where_))</p>")
        }
        return renderBreakdown(goal: goal, url: url)
    }

    // Per-minute accumulator for the breakdown view.
    private struct MinuteAgg {
        var input = 0, output = 0, cacheCreate = 0, cacheRead = 0
        var tools: [String: Int] = [:]   // tool name -> call count this minute
        var details: [String] = []       // representative targets (file/command/…), bounded
        var firstTs: Date?
    }

    private func renderBreakdown(goal: ReviewStore.Goal, url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return breakdownHTML(title: goal.text, body: "<p class=\"empty\">파일을 읽을 수 없습니다.</p>")
        }
        var minutes: [Int: MinuteAgg] = [:]
        var order: [Int] = []                    // minute-bucket keys, in first-seen order
        var totalIn = 0, totalOut = 0, totalCC = 0, totalCR = 0
        var msgCount = 0
        var firstDate: Date?, lastDate: Date?

        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = self.parseTS(tsStr) else { return }

            let usage = msg["usage"] as? [String: Any]
            let input = (usage?["input_tokens"] as? Int) ?? 0
            let output = (usage?["output_tokens"] as? Int) ?? 0
            let cc = (usage?["cache_creation_input_tokens"] as? Int) ?? 0
            let cr = (usage?["cache_read_input_tokens"] as? Int) ?? 0

            var hits: [(name: String, detail: String)] = []
            if let arr = msg["content"] as? [[String: Any]] {
                for b in arr where (b["type"] as? String) == "tool_use" {
                    let name = b["name"] as? String ?? "tool"
                    hits.append((name, self.toolDetail(b["input"])))
                }
            }
            // Skip bookkeeping-only chunks (no tokens, no tools).
            if input == 0 && output == 0 && cc == 0 && cr == 0 && hits.isEmpty { return }

            msgCount += 1
            totalIn += input; totalOut += output; totalCC += cc; totalCR += cr
            if firstDate == nil { firstDate = ts }
            lastDate = ts

            let key = Int(ts.timeIntervalSince1970 / 60)
            if minutes[key] == nil { minutes[key] = MinuteAgg(); order.append(key) }
            minutes[key]!.input += input
            minutes[key]!.output += output
            minutes[key]!.cacheCreate += cc
            minutes[key]!.cacheRead += cr
            if minutes[key]!.firstTs == nil { minutes[key]!.firstTs = ts }
            for h in hits {
                minutes[key]!.tools[h.name, default: 0] += 1
                if !h.detail.isEmpty, minutes[key]!.details.count < 6 { minutes[key]!.details.append(h.detail) }
            }
        }

        // Headline total counts each token once: new input + output + cache writes.
        // cache_read replays already-counted context every turn, so summing it would
        // inflate a short session into millions; it's surfaced separately below.
        let total = totalIn + totalOut + totalCC
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "en_US_POSIX")
        hm.timeZone = Settings.shared.displayTimeZone
        hm.dateFormat = "HH:mm"

        // Header card: grand total + breakdown + session facts.
        let spanFmt = DateFormatter()
        spanFmt.locale = Locale(identifier: "en_US_POSIX")
        spanFmt.timeZone = Settings.shared.displayTimeZone
        spanFmt.dateFormat = "MM-dd HH:mm"
        let span: String = {
            guard let f = firstDate, let l = lastDate else { return "-" }
            return "\(spanFmt.string(from: f)) ~ \(hm.string(from: l))"
        }()
        let header = """
        <div class="hcard">
          <div class="big"><span class="lab">총 토큰</span><span class="n">\(fmtNum(total))</span></div>
          <div class="bd">
            <span>출력 <b>\(fmtNum(totalOut))</b></span>
            <span>입력 <b>\(fmtNum(totalIn))</b></span>
            <span>캐시생성 <b>\(fmtNum(totalCC))</b></span>
            <span class="dim">캐시읽기(재사용) <b>\(fmtNum(totalCR))</b></span>
          </div>
          <div class="bd meta">
            <span>작업시간 <b>\(fmtClock(goal.trackedSeconds))</b></span>
            <span>메시지 <b>\(msgCount)</b></span>
            <span>구간 <b>\(htmlEscape(span))</b></span>
          </div>
        </div>
        """

        if order.isEmpty {
            return breakdownHTML(title: goal.text,
                body: header + "<p class=\"empty\">표시할 작업 기록이 없습니다.</p>")
        }

        var rows = ""
        for key in order {
            guard let m = minutes[key] else { continue }
            let label = hm.string(from: m.firstTs ?? Date(timeIntervalSince1970: Double(key * 60)))
            let chips = m.tools.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "<span class=\"chip\">\(htmlEscape($0.key))<i>×\($0.value)</i></span>" }
                .joined()
            let work = chips.isEmpty ? "<span class=\"chip none\">대화</span>" : chips
            let det = m.details.isEmpty ? ""
                : "<div class=\"det\">" + m.details.map { htmlEscape($0) }.joined(separator: " · ") + "</div>"
            let mTotal = m.input + m.output + m.cacheCreate
            rows += """
            <div class="min">
              <div class="t">\(label)</div>
              <div class="work">\(work)\(det)</div>
              <div class="tok"><b>\(fmtNum(m.output))</b><span>out</span><em>\(fmtNum(mTotal))</em></div>
            </div>
            """
        }
        return breakdownHTML(title: goal.text, body: header + "<div class=\"mins\">" + rows + "</div>")
    }

    // Pull a short, human-meaningful target out of a tool_use input dict
    // (filename, command, search pattern, …). Empty when nothing fits.
    private func toolDetail(_ input: Any?) -> String {
        guard let d = input as? [String: Any] else { return "" }
        func s(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let p = s("file_path") ?? s("notebook_path") ?? s("path") {
            return (p as NSString).lastPathComponent
        }
        if let c = s("command") { return String(c.prefix(80)) }
        if let p = s("pattern") { return p }
        if let q = s("query") { return q }
        if let u = s("url") { return u }
        if let desc = s("description") { return desc }
        if let pr = s("prompt") { return String(pr.prefix(60)) }
        return ""
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private func parseTS(_ s: String) -> Date? {
        Self.isoFrac.date(from: s) ?? Self.isoPlain.date(from: s)
    }

    private func fmtNum(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
    private func fmtClock(_ sec: Double) -> String {
        let s = max(0, Int(sec)); let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
    }

    private func breakdownHTML(title: String, body: String) -> String {
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(title)) · 작업 분석</title>
        <style>
          :root{--bg:#0e1116;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#8fe3c0}
          *{box-sizing:border-box}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif}
          header{position:sticky;top:0;background:rgba(14,17,22,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line);padding:14px 20px;z-index:2}
          header h1{margin:0;font-size:16px}
          header .sub{color:var(--mut);font-size:12px;margin-top:2px}
          main{max-width:920px;margin:0 auto;padding:18px 20px 80px}
          .hcard{border:1px solid var(--line);border-radius:14px;background:#11161f;padding:16px 18px;margin-bottom:18px}
          .hcard .big{display:flex;align-items:baseline;gap:10px}
          .hcard .big .lab{color:var(--mut);font-size:12px;letter-spacing:.04em}
          .hcard .big .n{font:600 30px/1.1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--accent)}
          .hcard .bd{display:flex;flex-wrap:wrap;gap:14px;margin-top:10px;color:var(--mut);font-size:12px}
          .hcard .bd b{color:var(--fg);font-variant-numeric:tabular-nums;font-weight:600}
          .hcard .bd.meta{margin-top:6px;padding-top:8px;border-top:1px solid var(--line)}
          .hcard .bd .dim{opacity:.6}
          .mins{display:flex;flex-direction:column;gap:1px;border:1px solid var(--line);border-radius:12px;overflow:hidden}
          .min{display:grid;grid-template-columns:54px 1fr 120px;gap:10px;align-items:start;padding:9px 12px;background:#0f141c}
          .min:nth-child(odd){background:#10151e}
          .min .t{color:var(--mut);font:600 12px/1.8 ui-monospace,SFMono-Regular,Menlo,monospace;font-variant-numeric:tabular-nums}
          .min .work{display:flex;flex-wrap:wrap;gap:5px;align-items:center}
          .chip{display:inline-flex;align-items:center;gap:3px;background:#1a2330;border:1px solid var(--line);border-radius:7px;padding:1px 7px;font-size:12px;color:#cdd4df}
          .chip i{font-style:normal;color:var(--mut);font-size:11px}
          .chip.none{color:var(--mut);background:transparent}
          .det{flex-basis:100%;color:var(--mut);font-size:11px;margin-top:2px;word-break:break-word}
          .min .tok{text-align:right;font-variant-numeric:tabular-nums}
          .min .tok b{color:var(--accent);font-size:14px}
          .min .tok span{color:var(--mut);font-size:11px;margin-left:3px}
          .min .tok em{display:block;color:var(--mut);font-size:11px;font-style:normal}
          .empty{color:var(--mut);text-align:center;padding:40px 0}
        </style></head>
        <body>
          <header><h1>\(htmlEscape(title))</h1><div class="sub">분 단위 작업 분석 · 툴 호출 · 토큰</div></header>
          <main>\(body)</main>
        </body></html>
        """
    }

    // Minimal JSON string encoder (quotes + escapes).
    private func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    // JSON payload for the dashboard (today's timeline + live summary).
    func dashboardData() -> String {
        let samples = activityLog.todaySamplesJSON()
        let todayLabel = Formatting.hoursLabel(store.todaySeconds)
        let totalLabel = Formatting.hoursLabel(store.data.totalSeconds)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = Settings.shared.displayTimeZone
        df.dateFormat = "yyyy-MM-dd (EEE)"
        let date = df.string(from: Date())
        let nowApp = activeAppLabel.isEmpty ? "-" : activeAppLabel
        let nowProfile = director.isPlaying ? director.activeProfileLabel : "-"
        let nowPlan: String
        if director.isPlaying && director.rainActive {
            let rem = director.rainRemaining.map { " \(Int($0/60))분" } ?? ""
            nowPlan = "🌧 폭우 리셋\(rem)"
        } else {
            nowPlan = director.isPlaying ? (bgmPlan.slot()?.label ?? "-") : "-"
        }
        let nowTrack = director.isPlaying ? (audio.currentTitle ?? "-") : "-"
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let nowSite = chromeDomain.isEmpty ? "-" : chromeDomain
        let nowTier = ValueTier.classify(bundleID: frontBundle, site: chromeDomain)
        // Accelerator gauge: live APM (pedal), redline fraction, gear phase, and the
        // next track the director is steering toward (gray "next gear" hint).
        let playing = director.isPlaying
        let nowAPM = playing ? Int(activity.instantAPM) : 0
        let nowNorm = playing ? activity.apmNorm : 0.0
        let nowGear = playing ? director.gearLabel : "-"
        let predictedNext: BPMLibrary.Track? = playing ? director.predictedNextTrack() : nil
        let nowNextBpm = predictedNext.map { Int($0.bpm) } ?? 0
        let nowNextTrack = predictedNext?.title ?? "-"
        let nowNormStr = String(format: "%.3f", nowNorm)
        let nowGearJSON = jsonString(nowGear)
        let nowNextTrackJSON = jsonString(nowNextTrack)
        return """
        {"date":"\(date)",\
        "dev":\(AppPaths.isCustom),"dataLabel":\(jsonString(AppPaths.label)),\
        "today":{"seconds":\(Int(store.todaySeconds)),"label":"\(todayLabel)"},\
        "total":{"seconds":\(Int(store.data.totalSeconds)),"label":"\(totalLabel)"},\
        "now":{"working":\(isWorking),"muted":\(session.isMuted),"status":"\(liveStatus)",\
        "app":\(jsonString(nowApp)),"profile":\(jsonString(nowProfile)),"plan":\(jsonString(nowPlan)),"track":\(jsonString(nowTrack)),\
        "site":\(jsonString(nowSite)),"key":\(Int(activity.keyRate)),"mouse":\(Int(activity.mouseRate)),\
        "tier":\(jsonString(nowTier.label)),"mult":\(nowTier.multiplier),\
        "apm":\(nowAPM),"norm":\(nowNormStr),"gear":\(nowGearJSON),\
        "nextBpm":\(nowNextBpm),"nextTrack":\(nowNextTrackJSON)},\
        "review":\(reviewJSON()),\
        "plugins":\(pluginStore.pluginsJSON()),\
        "workers":\(WorkerRegistry.shared.snapshotJSON()),\
        "samples":\(samples)}
        """
    }

    // GET /api/session/state — the shared live state the sidebar rail's challenge dial polls:
    // {working, muted} from the single source of truth, plus the current session's elapsed active
    // seconds (so the dial shows the right time when a page loads mid-session). Kept separate from
    // the heavier /data.json so any page (dashboard, goal) can poll it cheaply.
    func sessionStateJSON() -> String {
        DispatchQueue.main.sync {
            // Current sprint's wall-clock window (epoch secs) so the dial's 루프 mode can count
            // down to the sprint target; 0 when no sprint exists.
            let sp = self.reviewStore.currentSprint
            let spStart = sp?.startAt.map { Int($0.timeIntervalSince1970) } ?? 0
            let spTarget = sp?.targetAt.map { Int($0.timeIntervalSince1970) } ?? 0
            // wall = wall-clock seconds since session start (the pomodoro dial's basis);
            // seconds stays the activity-gated count for the surfaces that mean "active time".
            let wall = self.sessionStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return "{\"working\":\(self.session.isRunning),\"muted\":\(self.session.isMuted),"
                + "\"seconds\":\(Int(self.sessionSeconds)),\"wall\":\(wall),"
                + "\"mode\":\(jsonString(self.director?.sessionMode ?? "")),"
                + "\"reward\":\(self.pomodoroRewardPending),"
                + "\"pomoToday\":\(self.pomodoroStats.todayCount()),"
                + "\"today\":\(Int(self.store.todaySeconds)),"
                + "\"bgm\":\(Settings.shared.musicEnabled),"
                + "\"sfx\":\(Settings.shared.sfxEnabled),"
                + "\"voiceDuck\":\(Settings.shared.voiceDuckOn),"
                + "\"voiceDucking\":\(self.voiceDucked),"
                + "\"sprintStart\":\(spStart),\"sprintTarget\":\(spTarget)}"
        }
    }

    // GET /api/equipment — 장비+숙련도 state for the equipment page and the rail's
    // settings-menu level chip: per-category level/XP/need, average + overall level,
    // market inflation, the recent award ledger, plus the live plugin list so the
    // page renders one box per plugin (same serialized form as /data.json uses).
    func equipmentJSON() -> String {
        let payload = equipment.statePayload()
        let base = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var s = String(decoding: base, as: UTF8.self)
        // Rain state rides along so the /equipment page can rain on the avatar while a
        // 폭우 리셋 is falling. Director state lives on the main thread; this is called
        // both from server threads (GET) and inside main.sync (rain POST), so only hop
        // when needed to avoid a nested-sync deadlock.
        let rainRemaining: Int = Thread.isMainThread
            ? Int(director?.rainRemaining ?? 0)
            : DispatchQueue.main.sync { Int(self.director?.rainRemaining ?? 0) }
        if s.hasSuffix("}") {
            s.removeLast()
            s += ",\"plugins\":\(pluginStore.pluginsJSON())"
            s += ",\"rain\":{\"active\":\(rainRemaining > 0),\"remaining\":\(rainRemaining)}}"
        }
        return s
    }

    // GET /api/settings/paths — the storage locations the rail's 설정 menu shows, so the
    // user can always SEE which folders the app is actually reading/writing (added after
    // the dev/prod store split kept "losing" data): the active data dir (AppPaths.base),
    // the BGM music folder (settings, or the CM_SCAN_DIR test override), and the Claude
    // session store (~/.claude/projects). `shared` says whether this run uses the single
    // unified store (no CM_DATA_DIR override), `dev` whether it's a dev build (CM_DEV).
    func settingsPathsJSON() -> String {
        let dataDir = AppPaths.base.path
        let bgm = ProcessInfo.processInfo.environment["CM_SCAN_DIR"]
            ?? Settings.shared.musicFolderPath ?? ""
        let claude = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path
        // 이슈 폴더: `issue` is the picked folder, or "" while it follows the caller's cwd.
        // `issueDefault` is what an issue raised by THIS window would use right now, so the
        // 설정 row can show a concrete example of the default instead of only describing it.
        let issueOverride = IssueFolder.override?.path ?? ""
        let issueDefault = IssueFolder.defaultRoot(cwd: latestAgentCwd()).path
        let queueOverride = Settings.shared.queueFolder ?? ""
        let queueDefault = WorkQueueStore.defaultRootPath
        let queueIsDefault = Settings.shared.queueFolder == nil
        return "{\"data\":\(jsonString(dataDir)),\"bgm\":\(jsonString(bgm)),"
            + "\"claude\":\(jsonString(claude)),\"shared\":\(!AppPaths.isCustom),"
            + "\"issue\":\(jsonString(issueOverride)),"
            + "\"issueDefault\":\(jsonString(issueDefault)),"
            + "\"issueIsDefault\":\(IssueFolder.isDefault),"
            + "\"issueLabel\":\(jsonString(IssueFolder.displayLabel)),"
            + "\"queue\":\(jsonString(queueOverride)),"
            + "\"queueDefault\":\(jsonString(queueDefault)),"
            + "\"queueIsDefault\":\(queueIsDefault),"
            + "\"dev\":\(AppPaths.isDev)}"
    }

    // The folder the agent was most recently invoked in: the cwd of the highest-numbered
    // goal that carries one. This is what "기본값" resolves to right now, so 설정 can show a
    // concrete path next to the rule instead of only the rule. Empty when no goal has ever
    // been given a working folder — then the default falls back to the app's own store.
    // Reads `goals` on main, like every other reader on the server queue (goalCwdRoots).
    private func latestAgentCwd() -> String {
        DispatchQueue.main.sync {
            reviewStore.goals
                .filter { !$0.cwd.trimmingCharacters(in: .whitespaces).isEmpty }
                .max(by: { $0.seq < $1.seq })?.cwd ?? ""
        }
    }

    // Set (or reset) the folder where delegation issues are created. A blank folder resets
    // to the default — the folder the agent was invoked in. Returns the refreshed paths
    // payload so the 설정 panel updates the row in one round-trip (mirrors setSkillsFolder).
    func setIssueFolder(folder: String) -> String {
        IssueFolder.setOverride(folder)
        return settingsPathsJSON()
    }
    
    // Set (or reset) the explicit Queue folder. Blank resets to default (env or hardcoded).
    func setQueueFolder(folder: String) -> String {
        Settings.shared.queueFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : folder
        return settingsPathsJSON()
    }

    func pickIssueFolder() -> String {
        var chosen: String?
        DispatchQueue.main.sync {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "선택"
            panel.message = "이슈 파일이 생성될 폴더를 선택하세요 (기본값은 에이전트를 부른 폴더입니다)"
            panel.directoryURL = IssueFolder.override
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            if panel.runModal() == .OK, let url = panel.url { chosen = url.path }
        }
        if let c = chosen { IssueFolder.setOverride(c) }
        return settingsPathsJSON()
    }

    // Opens a native folder picker for the Queue folder.
    func pickQueueFolder() -> String {
        var chosen: String?
        DispatchQueue.main.sync {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "선택"
            panel.message = "큐 폴더를 선택하세요"
            panel.directoryURL = WorkQueueStore.root
            if panel.runModal() == .OK, let url = panel.url { chosen = url.path }
        }
        if let c = chosen { Settings.shared.queueFolder = c }
        return settingsPathsJSON()
    }

    // GET /api/memo — the one global 메모장 text (MemoStore). `chars` is a convenience for
    // the pad's "n자 · 저장됨" meta so the client doesn't have to recount on load.
    // `rev` is the revision the pad must echo back as `base` when it saves — the stale-
    // writer gate that keeps one long-lived webview from wiping another's lines.
    func memoJSON() -> String {
        let m = MemoStore.shared.current
        return "{\"text\":\(jsonString(m.text)),\"updatedAt\":\(Int(m.updatedAt)),"
            + "\"rev\":\(m.rev),\"chars\":\(m.text.count)}"
    }

    // GET /api/memo/history — 메모장의 지난 판 목록(memo-history.jsonl, 최신순). 패드의
    // 히스토리 메뉴가 이 목록으로 "지워진 장문"을 눈으로 찾아 복원한다. 복원 자체는 별도
    // API 가 아니라 평범한 POST /api/memo(판번호 게이트 포함)로 돌아간다 — 길이 하나면 충분.
    func memoHistoryJSON() -> String {
        let rows = MemoStore.shared.history().map {
            "{\"t\":\(Int($0.t)),\"rev\":\($0.rev),\"kind\":\(jsonString($0.kind)),"
                + "\"chars\":\($0.text.count),\"text\":\(jsonString($0.text))}"
        }
        return "{\"items\":[\(rows.joined(separator: ","))]}"
    }

    // GET /api/memo/tags?k=담당&q=isma — 메모장 칸의 태그 후보(MemoTagStore).
    // `canCreate` 는 "이 글자로 만들 태그가 아직 없다" 는 뜻 — 패드는 그때만 만들기 버튼을
    // 내민다. 알 수 없는 칸 이름은 빈 목록으로 조용히 돌려보낸다(실패 배너 없음 — 앱 규칙).
    func memoTagsJSON(kind: String, query: String) -> String {
        guard MemoTagStore.isKind(kind) else { return "{\"tags\":[],\"canCreate\":false}" }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = MemoTagStore.shared.search(kind: kind, query: q)
        let rows = hits.map { "{\"name\":\(jsonString($0.name)),\"count\":\($0.count)}" }
        let canCreate = !q.isEmpty && !MemoTagStore.shared.exists(kind: kind, name: q)
        return "{\"tags\":[\(rows.joined(separator: ","))],\"canCreate\":\(canCreate)}"
    }

    // GET /api/memo/parent-suggest?title=…&no=N — 메모장 부모 칸 드롭다운의 데이터.
    // `recent` = 최근 쓴 부모 번호(MRU, 최신이 먼저). 보드 부모# 와 같은 Settings 목록을
    // 공유한다 — 골번호 공간이 하나이므로 "무엇 아래에 모으는가" 라는 습관도 하나다.
    // `sug` = 이 줄 제목에 대한 AI 후보(ParentSuggest.rank). 자동 부착이 아니라 사용자가
    // 열어 읽는 목록이므로 보드 고스트의 침묵 게이트는 걸지 않는다(rank 의 주석 참조).
    // 보드에 없는 번호(메모 줄 번호)는 t 가 비어 온다 — 패드가 메모 안 제목으로 채운다.
    // 폴더 토큰 스캔은 하지 않는다: 칸 포커스마다 동기로 도는 길이라 디스크를 걷지 않는
    // 것이 우선이고, 제목+자식 프로필만으로도 후보는 선다. `no` = 이 줄 자신의 골번호 —
    // 자기 자신을 부모로 권하지 않기 위해 양쪽 목록에서 뺀다.
    func memoParentSuggestJSON(title: String, no: Int) -> String {
        var goals: [ReviewStore.Goal] = []
        DispatchQueue.main.sync { goals = self.reviewStore.goals }
        let bySeq = Dictionary(goals.map { ($0.seq, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = Settings.shared.recentParentSeqs.filter { $0 != no }
        let recentRows = recent.map {
            "{\"n\":\($0),\"t\":\(jsonString(bySeq[$0]?.text ?? ""))}"
        }
        var sugRows: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            let input = goals.map {
                ParentSuggest.GoalIn(seq: $0.seq, id: $0.id, title: $0.text, parentId: $0.parent,
                                     sprint: $0.sprint, archived: $0.archived, released: $0.released)
            }
            sugRows = ParentSuggest.rank(title: t, goals: input, recentParentSeqs: recent)
                .filter { $0.parentSeq != no }
                .map { "{\"n\":\($0.parentSeq),\"t\":\(jsonString(bySeq[$0.parentSeq]?.text ?? "")),"
                    + "\"why\":\(jsonString($0.why))}" }
        }
        return "{\"recent\":[\(recentRows.joined(separator: ","))],"
            + "\"sug\":[\(sugRows.joined(separator: ","))]}"
    }

    // GET /api/settings/timezone — the display-timezone setting for the rail's 설정 menu.
    // `tz` is the stored value ("system" | IANA id), `effective` the resolved zone, `label`
    // the human form ("KST (UTC+9)"). Timestamps are stored as epoch (UTC-based) throughout;
    // this setting only changes the wall clock they are rendered in.
    func timezoneJSON() -> String {
        let id = Settings.shared.timeZoneID
        let tz = Settings.shared.displayTimeZone
        let hours = Double(tz.secondsFromGMT()) / 3600
        let off = hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
        // TimeZone(identifier:"UTC") canonicalizes to "GMT"; keep the user-facing name "UTC".
        let name = tz.identifier == "Asia/Seoul" ? "KST"
            : (tz.identifier == "GMT" || tz.identifier == "UTC") ? "UTC" : tz.identifier
        let label = "\(name) (UTC\(hours >= 0 ? "+" : "")\(off))"
        return "{\"tz\":\(jsonString(id)),\"effective\":\(jsonString(tz.identifier)),"
            + "\"label\":\(jsonString(label))}"
    }

    // GET/POST /api/settings/gateway — how the app authenticates the `claude` CLI it spawns.
    // "auto" injects nothing (the CLI uses its own local login / OAuth); "gateway" injects
    // ANTHROPIC_BASE_URL plus a token read from the named Keychain item. Only `hasKey` (a
    // bool) leaves the app — never the token itself.
    func settingsGatewayJSON() -> String {
        let s = Settings.shared
        let mode = s.gatewayMode == "gateway" ? "gateway" : "auto"
        let hasKey = mode == "gateway" && Self.gatewayToken() != nil
        let baseSet = !s.gatewayBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        let status: String
        if mode == "auto" {
            status = "자동 · 로컬 Claude 로그인 사용"
        } else if !baseSet {
            status = "게이트웨이 · URL 미설정"
        } else if hasKey {
            status = "게이트웨이 · 토큰 확인됨"
        } else {
            status = "게이트웨이 · 키체인 항목을 찾지 못함"
        }
        // Carry the last 연결 확인 result so a freshly opened 설정 패널 shows 연결됨/문제
        // immediately instead of a blank row until the user presses 확인.
        var last = ""
        if let l = Self.lastGatewayState {
            last = ",\"state\":\(jsonString(l.state)),\"detail\":\(jsonString(l.detail)),"
                + "\"hint\":\(jsonString(l.hint)),\"checkedAgo\":\(Int(Date().timeIntervalSince(l.at)))"
        }
        return "{\"mode\":\(jsonString(mode)),\"baseURL\":\(jsonString(s.gatewayBaseURL)),"
            + "\"scheme\":\(jsonString(s.gatewayScheme)),"
            + "\"keyService\":\(jsonString(s.gatewayKeyService)),"
            + "\"keyAccount\":\(jsonString(s.gatewayKeyAccount)),"
            + "\"keyAccountEffective\":\(jsonString(s.gatewayKeyAccount.isEmpty ? NSUserName() : s.gatewayKeyAccount)),"
            + "\"hasKey\":\(hasKey),\"status\":\(jsonString(status))"
            + last + "}"
    }

    // POST /api/settings/gateway/test — a real end-to-end check of the 연결 settings, run in
    // the order the failures actually happen so the user is told WHICH link broke rather than
    // a generic "실패": CLI present → gateway host reachable (this is where a VPN that is not
    // up shows itself) → Keychain token readable → one headless `claude -p` round trip.
    //
    // `state` drives the UI: ok(연결됨) / needLogin(로그인 필요) / unreachable(네트워크·VPN) /
    // noKey / noCLI / badAuth / error. Only the CLI's own output is echoed back — a token can
    // never appear in it, and nothing here is logged beyond the state.
    func gatewayTestJSON() -> String {
        let s = Settings.shared
        let gateway = s.gatewayMode == "gateway"

        func result(_ state: String, _ detail: String, _ hint: String = "") -> String {
            Self.lastGatewayState = (state, detail, hint, Date())
            AppLog.log("gateway check state=\(state) mode=\(s.gatewayMode)")
            return "{\"state\":\(jsonString(state)),\"ok\":\(state == "ok"),"
                + "\"detail\":\(jsonString(detail)),\"hint\":\(jsonString(hint))}"
        }

        guard let claude = Self.resolveClaude() else {
            return result("noCLI", "claude CLI를 찾지 못했습니다",
                          "터미널에서 claude 를 설치한 뒤 다시 확인하세요")
        }
        if gateway {
            let base = s.gatewayBaseURL.trimmingCharacters(in: .whitespaces)
            if base.isEmpty {
                return result("error", "게이트웨이 URL이 비어 있습니다", "게이트웨이 URL을 입력하세요")
            }
            // Reachability first: on a machine that needs the VPN, an un-connected VPN fails
            // here (DNS or TLS), and saying so is far more useful than the CLI's auth error.
            // Reuses the 네트워크 진단 probe so both surfaces judge reachability identically.
            let snap = DiagProbe.run(hosts: [base])
            let host = (snap["hosts"] as? [[String: Any]])?.first
            let dnsOk = (host?["dnsOk"] as? Bool) ?? false
            let httpOk = (host?["httpOk"] as? Bool) ?? false
            if !dnsOk || !httpOk {
                let vpnActive = (snap["vpnActive"] as? Bool) ?? false
                let why = (host?["error"] as? String) ?? "연결 실패"
                let hint = vpnActive
                    ? "VPN은 연결돼 있습니다 — 게이트웨이 URL과 네트워크를 확인하세요"
                    : "VPN이 연결돼 있지 않습니다 — VPN을 연결한 뒤 다시 확인하세요"
                return result("unreachable", "게이트웨이에 연결할 수 없습니다 (\(why))", hint)
            }
            guard let token = Self.gatewayToken(), !token.isEmpty else {
                return result("noKey", "키체인 항목 '\(s.gatewayKeyService)'에서 토큰을 읽지 못했습니다",
                              "키체인 항목 이름과 계정을 확인하세요 (계정: \(s.gatewayKeyAccount.isEmpty ? NSUserName() : s.gatewayKeyAccount))")
            }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) -p --output-format text 2>&1"]
        p.environment = Self.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch {
            return result("error", "claude 를 실행하지 못했습니다")
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: killer)
        inPipe.fileHandleForWriting.write(Data("Reply with the single word OK.".utf8))
        try? inPipe.fileHandleForWriting.close()
        let d = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        let out = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let low = out.lowercased()
        let firstLine = String(String(out.split(separator: "\n").first ?? "").prefix(160))

        if out.isEmpty {
            return result("error", "응답이 없습니다", "잠시 후 다시 확인하세요")
        }
        if low.contains("not logged in") || low.contains("please run /login") || low.contains("/login") {
            return result("needLogin", "Claude CLI에 로그인돼 있지 않습니다",
                          gateway ? "게이트웨이 토큰이 거부됐거나 로그인이 필요합니다"
                                  : "아래 '로그인 열기'를 눌러 터미널에서 로그인하세요")
        }
        if low.contains("invalid api key") || low.contains("authentication_error")
            || low.contains("unauthorized") || low.contains("401") {
            return result("badAuth", "인증이 거부됐습니다 — \(firstLine)",
                          gateway ? "키체인 토큰이 만료됐는지 확인하세요" : "로그인 상태를 확인하세요")
        }
        if p.terminationStatus != 0 {
            return result("error", firstLine, "잠시 후 다시 확인하세요")
        }
        return result("ok", "연결됨 — 응답 \"\(firstLine)\"")
    }

    // Last check outcome, so the 설정 패널이 열릴 때 즉시 지난 결과(연결됨/문제)를 보여줄 수
    // 있다. In-memory only — a fresh launch starts at "unknown" and the panel re-checks.
    static var lastGatewayState: (state: String, detail: String, hint: String, at: Date)?

    // POST /api/settings/gateway/login — the "로그인 필요" action. Opens Terminal.app running
    // `claude /login`: the CLI's OAuth flow is interactive, so it cannot run headless inside
    // the app. The command is a fixed literal (no caller input) — the page cannot make this
    // run anything else.
    func gatewayLoginJSON() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\" to activate",
                       "-e", "tell application \"Terminal\" to do script \"claude /login\""]
        do { try p.run() } catch {
            return "{\"ok\":false,\"detail\":\(jsonString("터미널을 열지 못했습니다 — 직접 claude /login 을 실행하세요"))}"
        }
        // Any later check should re-probe rather than show the stale pre-login state.
        Self.lastGatewayState = nil
        return "{\"ok\":true,\"detail\":\(jsonString("터미널에서 claude /login 을 실행했습니다 — 로그인 후 다시 확인하세요"))}"
    }

    // GET/POST /api/settings/diag-hosts — the 네트워크 진단 target host list. Returns the
    // effective list (defaults applied), so the 진단 tab always shows at least the HRIS host.
    func diagHostsJSON() -> String {
        let hosts = Settings.shared.diagHosts.map { jsonString($0) }.joined(separator: ",")
        return "{\"hosts\":[\(hosts)]}"
    }

    // Source mtime snapshot taken when an in-app update build failed (script exited
    // non-zero while this instance kept running). While the tree hasn't changed since,
    // the same sources would fail the same way — so /api/update/check reports the
    // update as unavailable instead of surfacing an error: the user keeps the current
    // version and the button simply reappears once the sources change. Failure details
    // go to update.log and the action log only, never to the rail UI.
    private var updateFailedSrcAt: TimeInterval?

    // The staged-build handshake: <data>/updates/staged.json, written by
    // Scripts/build-app.sh --stage (driven by the autobuild watcher). Absent = no
    // background builder installed, and everything falls back to the original
    // build-on-demand model below.
    struct StagedBuild {
        let state: String        // building | ready | failed
        let buildStart: TimeInterval  // the staged bundle's CMBuildStart
        let srcAt: TimeInterval  // newest source mtime that build covers
        let at: TimeInterval     // when the stager last wrote
        let commit: String
    }
    static var stagedDir: URL { AppPaths.base.appendingPathComponent("updates", isDirectory: true) }
    static func readStagedBuild() -> StagedBuild? {
        let url = stagedDir.appendingPathComponent("staged.json")
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = o["state"] as? String
        else { return nil }
        let num: (String) -> TimeInterval = { k in
            if let d = o[k] as? Double { return d }
            if let i = o[k] as? Int { return TimeInterval(i) }
            if let s = o[k] as? String { return TimeInterval(s) ?? 0 }
            return 0
        }
        return StagedBuild(state: state, buildStart: num("buildStart"), srcAt: num("srcAt"),
                           at: num("at"), commit: (o["commit"] as? String) ?? "")
    }

    // GET /api/update/check — "is a newer build available?" for the rail's 업데이트 button.
    //
    // Two models, staged first:
    //  (1) STAGED — a background builder (Scripts/autobuild-watch.sh) has already compiled
    //      the new sources into <data>/updates/. Then "available" means a finished bundle
    //      is sitting there, and pressing 업데이트 is a ~2s copy. While that build is still
    //      running we report preparing:true so the rail can say 준비 중 instead of going
    //      silent for 40 seconds — the point of the split is that the user never waits on a
    //      compile they didn't ask for.
    //  (2) SOURCE MTIME (fallback, the original model) — no builder installed, so the only
    //      signal is "sources are newer than this binary" and pressing the button compiles
    //      then and there.
    // Dev builds and raw runs have no CMSourceRoot stamp -> always false (dev-watch owns
    // their rebuild loop).
    func updateCheckJSON() -> String {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "CMSourceRoot") as? String,
              !root.isEmpty,
              let exe = Bundle.main.executableURL,
              let built = (try? FileManager.default.attributesOfItem(atPath: exe.path))?[.modificationDate] as? Date
        else { return "{\"available\":false}" }
        let src = Self.latestSourceMTime(root: root)
        let ownBuildStart = (Bundle.main.object(forInfoDictionaryKey: "CMBuildStart") as? String)
            .flatMap(TimeInterval.init) ?? (built.timeIntervalSince1970 + 2)

        // (1) Staged model. Once a builder is installed it is the ONLY authority — the
        // source-mtime path below would otherwise light the button the instant a file is
        // saved and drag the user back into a blocking compile.
        if let st = Self.readStagedBuild() {
            let newer = st.buildStart > ownBuildStart
            switch st.state {
            case "ready" where newer:
                // Ready, and possibly already behind again if edits continued after it
                // started — say so rather than implying the button ships the latest save.
                let behind = src > st.srcAt + 0.5
                return "{\"available\":true,\"staged\":true,\"behind\":\(behind),"
                    + "\"builtAt\":\(Int(st.at)),\"srcAt\":\(Int(src)),"
                    + "\"commit\":\(jsonString(st.commit))}"
            case "building":
                return "{\"available\":false,\"staged\":true,\"preparing\":true,"
                    + "\"since\":\(Int(st.at)),\"srcAt\":\(Int(src))}"
            case "failed":
                // Quiet for the user (no-user-facing-failure): no button, no banner. The
                // 시스템 페이지 autobuild worker row carries the error, and the next save
                // triggers a fresh attempt.
                return "{\"available\":false,\"staged\":true,\"deferred\":true,\"srcAt\":\(Int(src))}"
            default:
                // ready-but-not-newer (already applied), or an unknown state: nothing to do.
                return "{\"available\":false,\"staged\":true,\"srcAt\":\(Int(src))}"
            }
        }
        // A build already failed for this exact tree state: report unavailable (plus a
        // deferred flag so an in-flight "업데이트 중…" button can quietly stand down).
        // The moment any source changes the failure snapshot is stale — clear it and
        // let the button come back.
        if let failedAt = updateFailedSrcAt {
            if src <= failedAt + 0.5 {
                return "{\"available\":false,\"deferred\":true}"
            }
            updateFailedSrcAt = nil
        }
        // (2) Source-mtime fallback. ownBuildStart is the BUILD START stamp when present:
        // sources saved while the (multi-minute) build ran are not in this binary, and the
        // exe mtime — stamped at the end of the build — would hide them until the next
        // unrelated save. With the stamp, a relaunch offers those pending changes
        // immediately, so the rail button is already visible during the 5s launch
        // countdown. Older builds without the stamp fall back to exe mtime +2s slack.
        let available = src > ownBuildStart
        return "{\"available\":\(available),\"builtAt\":\(Int(built.timeIntervalSince1970)),"
            + "\"srcAt\":\(Int(src))}"
    }

    // Newest modification time across the app's own sources: Sources/**/*.swift (skipping
    // node_modules / dotdirs — the bundled JS plugin tree is huge and not compiled in),
    // plus the few root files a rebuild depends on.
    private static func latestSourceMTime(root: String) -> TimeInterval {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var latest: TimeInterval = 0
        for extra in ["Package.swift", "Info.plist", "Scripts/build-app.sh"] {
            let p = rootURL.appendingPathComponent(extra).path
            if let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date {
                latest = max(latest, d.timeIntervalSince1970)
            }
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let en = fm.enumerator(at: rootURL.appendingPathComponent("Sources", isDirectory: true),
                                     includingPropertiesForKeys: keys) else { return latest }
        for case let url as URL in en {
            let name = url.lastPathComponent
            if name == "node_modules" || name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    en.skipDescendants()
                }
                continue
            }
            // .mjs도 센다: 슬랙 데몬은 이제 번들에 실려 나가는 산출물이라 리빌드
            // 대상이다. Scripts/build-app.sh·autobuild-watch.sh의 newest_src_mtime과
            // 같은 기준을 유지해야 "업데이트 있음" 판정이 양쪽에서 어긋나지 않는다.
            // slack-*.json(응답 정책·권한 등급·용어집)도 번들에 실려 나가는 산출물이라
            // 같이 센다. 이름 대응만 고친 변경이 "업데이트 없음"으로 보이면 안 된다.
            guard url.pathExtension == "swift" || url.pathExtension == "mjs"
                    || (url.pathExtension == "json" && name.hasPrefix("slack-")) else { continue }
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                latest = max(latest, d.timeIntervalSince1970)
            }
        }
        return latest
    }

    // USER-driven usage-event counts per equipment category over the last `window`
    // seconds — the pomodoro EXP attribution input. Only deliberate user actions
    // count: skills = skill executions (skillUsageEvents), chat = dashboard chat
    // user messages. Autonomous activity is deliberately EXCLUDED — background
    // workers fire 24/7 regardless of what the user does, so counting them would
    // hand every pomodoro's EXP to 워커 (confirmed in testing). 위임/워커/팀/
    // 플러그인 join once they have a user-action signal; with no usage at all the
    // store falls back to 대화 (기본기).
    private func equipmentUsage(within window: TimeInterval) -> [String: Int] {
        let cutoff = Date().timeIntervalSince1970 - window
        var usage: [String: Int] = [:]
        usage["skills"] = skillUsageEvents().filter {
            let e = ($0["epoch"] as? Double) ?? Double(($0["epoch"] as? Int) ?? 0)
            return e >= cutoff
        }.count
        usage["chat"] = chatStore.messages.filter {
            $0.role == "user" && $0.createdAt.timeIntervalSince1970 >= cutoff
        }.count
        return usage
    }

    // GET /history.json?days=N -> compact per-day samples for the 히스토리 tab.
    // The browser runs the same carry-forward + timeBuckets + deep-focus logic on
    // each day, so daily 총/책상/집중 and 초집중 sessions match the today view exactly.
    func dashboardHistory(_ path: String) -> String {
        let daysStr = URLComponents(string: "http://x" + path)?.queryItems?
            .first(where: { $0.name == "days" })?.value ?? ""
        let days = Int(daysStr) ?? 180
        return "{\"days\":\(activityLog.historyJSON(days: days))}"
    }

    // GET /tokens.json?days=N — real daily token usage summed from every Claude session
    // transcript under ~/.claude/projects, bucketed by the local calendar day the message
    // was written. This is the actual "how many tokens did I spend each day" timeline (the
    // token view's goal-based g.tokens field is manually set and usually empty). Each day's
    // total counts new input + output + cache-creation once; cache_read is excluded because
    // it replays already-counted context every turn and would inflate totals by orders of
    // magnitude (same convention as the per-session breakdown headline).
    func dashboardTokens(_ path: String) -> String {
        let daysStr = URLComponents(string: "http://x" + path)?.queryItems?
            .first(where: { $0.name == "days" })?.value ?? ""
        let days = max(1, Int(daysStr) ?? 90)
        let fm = FileManager.default
        // Only look back `days` from the start of today; a transcript touched before that
        // window cannot contribute to any in-window day, so skip it by mtime (cheap stat).
        var cal = Calendar.current
        cal.timeZone = Settings.shared.displayTimeZone
        let cutoff = cal.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86400)
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = Settings.shared.displayTimeZone
        dayFmt.dateFormat = "yyyy-MM-dd"   // 표시 타임존 — same day boundary the rest of the UI uses

        // Enumerate every project's *.jsonl. Missing base dir -> empty timeline.
        guard let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return "{\"days\":[]}"
        }
        var files: [URL] = []
        for dir in subs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let inner = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for f in inner where f.pathExtension == "jsonl" { files.append(f) }
        }

        var totals: [String: DayTok] = [:]        // day -> aggregated stats
        var sessionsPerDay: [String: Set<String>] = [:]  // day -> distinct session files that spent tokens
        // 창 점유는 합산할 수 없는 값이라 totals 안에서 접히지 않는다(t.ctxFinal 은 0 으로 남는다).
        // 대신 세션마다의 최종 점유율을 여기 모아 두고, 일 행에서 분포(중앙값·80%↑ 개수)로 낸다.
        // 라우팅은 세션 하나가 아니라 분포를 봐야 바뀐다.
        var ctxPctsPerDay: [String: [Double]] = [:]
        for f in files {
            let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = rv?.contentModificationDate ?? .distantPast
            let size = rv?.fileSize ?? 0
            if mtime < cutoff { continue }

            let perDay = tokensByDay(file: f, mtime: mtime, size: size)
            let sid = f.deletingPathExtension().lastPathComponent
            for (day, st) in perDay {
                var t = totals[day, default: DayTok()]
                t.spent += st.spent; t.inTok += st.inTok; t.outTok += st.outTok
                t.thinkTok += st.thinkTok; t.textTok += st.textTok; t.toolTok += st.toolTok
                t.typedTok += st.typedTok; t.imgN += st.imgN; t.imgBytes += st.imgBytes
                t.imgTok += st.imgTok; t.toolResTok += st.toolResTok; t.reloadTok += st.reloadTok
                t.aiSec += st.aiSec
                for (m, u) in st.models {
                    var mu = t.models[m, default: ModelUse()]
                    mu.inTok += u.inTok; mu.cacheRead += u.cacheRead
                    mu.cache5m += u.cache5m; mu.cache1h += u.cache1h; mu.outTok += u.outTok
                    if !u.effort.isEmpty { mu.effort = u.effort }
                    for (eff, cnt) in u.efforts { mu.efforts[eff, default: 0] += cnt }
                    t.models[m] = mu
                }
                t.leads.append(contentsOf: st.leads)
                for (aid, amt) in st.accounts { t.accounts[aid, default: 0] += amt }
                for (prv, amt) in st.providers { t.providers[prv, default: 0] += amt }
                // 창 점유는 t 로 접지 않는다 — 세션별 값을 그대로 모은다.
                if st.ctxFinal > 0, let w = Self.resolvedWindow(model: st.ctxModel, peak: st.ctxPeak), w > 0 {
                    ctxPctsPerDay[day, default: []].append(Double(st.ctxFinal) / Double(w) * 100)
                }
                totals[day] = t
                if st.spent > 0 { sessionsPerDay[day, default: []].insert(sid) }
            }
        }

        // Multi-LLM: Codex
        let codexSessions = CodexTokenCollector.shared.fetchSessions(since: cutoff)
        let codexAcc = LLMAccountStore.shared.resolve(provider: "codex", accountId: "local")
        for cs in codexSessions {
            var t = totals[cs.day, default: DayTok()]
            let inTok = Int(Double(cs.tokensUsed) * 0.65)
            let outTok = Int(Double(cs.tokensUsed) * 0.35)
            t.spent += cs.tokensUsed
            t.inTok += inTok
            t.outTok += outTok
            t.accounts[codexAcc.id, default: 0] += cs.tokensUsed
            t.providers["codex", default: 0] += cs.tokensUsed
            var mu = t.models[cs.model, default: ModelUse()]
            mu.inTok += inTok; mu.outTok += outTok
            if !cs.reasoningEffort.isEmpty {
                mu.effort = cs.reasoningEffort
                mu.efforts[cs.reasoningEffort, default: 0] += cs.tokensUsed
            }
            t.models[cs.model] = mu
            totals[cs.day] = t
            if cs.tokensUsed > 0 { sessionsPerDay[cs.day, default: []].insert(cs.id) }
        }

        // Multi-LLM: Antigravity
        let agySessions = AntigravityTokenCollector.shared.fetchSessions(since: cutoff)
        let agyAcc = LLMAccountStore.shared.resolve(provider: "antigravity", accountId: "default")
        for asess in agySessions {
            var t = totals[asess.day, default: DayTok()]
            t.spent += asess.tokensUsed
            t.inTok += asess.inTok
            t.outTok += asess.outTok
            t.accounts[agyAcc.id, default: 0] += asess.tokensUsed
            t.providers["antigravity", default: 0] += asess.tokensUsed
            var mu = t.models[asess.model, default: ModelUse()]
            mu.inTok += asess.inTok; mu.outTok += asess.outTok
            if !asess.effort.isEmpty {
                mu.effort = asess.effort
                mu.efforts[asess.effort, default: 0] += asess.tokensUsed
            }
            t.models[asess.model] = mu
            totals[asess.day] = t
            if asess.tokensUsed > 0 { sessionsPerDay[asess.day, default: []].insert(asess.id) }
        }

        // Active human seconds per day — for the 가치 mode's time-efficiency weighting.
        let activeSec = activityLog.activeSecondsByDay(days: days)

        // Emit only in-window days (a long session can carry an out-of-window day), newest first.
        let minDay = dayFmt.string(from: cutoff)
        let rows = totals.keys.filter { $0 >= minDay }.sorted(by: >).map { day -> String in
            let st = totals[day] ?? DayTok()
            let tokK = Int((Double(st.spent) / 1000.0).rounded())   // tokens -> K, matches UI unit
            let sess = sessionsPerDay[day]?.count ?? 0
            let leads = st.leads.sorted()
            let leadN = leads.count
            let leadSum = Int(leads.reduce(0, +).rounded())
            let leadMed = leadN > 0 ? Int(leads[leadN / 2].rounded()) : 0
            let accountsJSON = "{" + st.accounts.keys.sorted().map { aid -> String in
                let tok = st.accounts[aid] ?? 0
                let acc = LLMAccountStore.shared.resolve(provider: aid.split(separator: ":").first.map(String.init) ?? "claude",
                                                         accountId: aid.split(separator: ":").dropFirst().joined(separator: ":"))
                return "\(self.jsonString(aid)):{\"tokens\":\(tok),\"label\":\(self.jsonString(acc.label)),\"color\":\(self.jsonString(acc.color)),\"provider\":\(self.jsonString(acc.provider))}"
            }.joined(separator: ",") + "}"
            let providersJSON = "{" + st.providers.keys.sorted().map { prov -> String in
                let tok = st.providers[prov] ?? 0
                return "\(self.jsonString(prov)):\(tok)"
            }.joined(separator: ",") + "}"
            // 창 점유 분포 — 창을 아는 세션이 하나도 없으면 중앙값은 null 이고 화면은 조각을 뺀다.
            let ctxPcts = (ctxPctsPerDay[day] ?? []).sorted()
            let ctxSessN = ctxPcts.count
            let ctxMedPctJSON = ctxSessN > 0 ? String(format: "%.1f", ctxPcts[ctxSessN / 2]) : "null"
            let ctxHighN = ctxPcts.filter { $0 >= 80 }.count
            return "{\"day\":\(jsonString(day)),\"tokens\":\(st.spent),\"k\":\(tokK),"
                + "\"inTok\":\(st.inTok),\"outTok\":\(st.outTok),\"thinkTok\":\(st.thinkTok),"
                + "\"textTok\":\(st.textTok),\"toolTok\":\(st.toolTok),"
                + "\"typedTok\":\(st.typedTok),\"imgN\":\(st.imgN),\"imgBytes\":\(st.imgBytes),"
                + "\"imgTok\":\(st.imgTok),\"toolResTok\":\(st.toolResTok),\"reloadTok\":\(st.reloadTok),"
                + "\"aiSec\":\(st.aiSec),"
                + "\"models\":\(modelsJSON(st.models)),"
                + "\"accounts\":\(accountsJSON),"
                + "\"providers\":\(providersJSON),"
                + "\"sessions\":\(sess),\"leadN\":\(leadN),\"leadSum\":\(leadSum),\"leadMed\":\(leadMed),"
                + "\"ctxMedPct\":\(ctxMedPctJSON),\"ctxHighN\":\(ctxHighN),\"ctxSessN\":\(ctxSessN),"
                + "\"activeSec\":\(activeSec[day] ?? 0)}"
        }
        return "{\"days\":[\(rows.joined(separator: ","))]}"
    }

    // GET /tokens-sessions.json?day=YYYY-MM-DD — per-session breakdown for one day: each
    // session's spend, composition, per-model usage (for $-cost), lead times, and a
    // readable title. This is the drill-down under a day row in the token view, added
    // because the day-level "컨텍스트 82%" number was distrusted — per-session numbers
    // let the user verify where it comes from.
    func dashboardTokenSessions(_ path: String) -> String {
        guard let day = URLComponents(string: "http://x" + path)?.queryItems?
            .first(where: { $0.name == "day" })?.value, day.count == 10 else { return "{\"sessions\":[]}" }
        let fm = FileManager.default
        var cal = Calendar.current
        cal.timeZone = Settings.shared.displayTimeZone
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = Settings.shared.displayTimeZone
        dayFmt.dateFormat = "yyyy-MM-dd"
        // A file untouched since before this day began cannot contain the day.
        guard let dayDate = dayFmt.date(from: day) else { return "{\"sessions\":[]}" }
        let dayStart = cal.startOfDay(for: dayDate)
        guard let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return "{\"sessions\":[]}"
        }
        var rows: [(spent: Int, json: String)] = []
        for dir in subs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let proj = dir.lastPathComponent.split(separator: "-").suffix(2).joined(separator: "-")
            let inner = (try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for f in inner where f.pathExtension == "jsonl" {
                let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = rv?.contentModificationDate ?? .distantPast
                if mtime < dayStart { continue }
                let facts = transcriptStats(file: f, mtime: mtime, size: rv?.fileSize ?? 0)
                guard let st = facts.days[day], st.spent > 0 else { continue }
                let sid = f.deletingPathExtension().lastPathComponent
                let leads = st.leads.sorted()
                let leadMed = leads.isEmpty ? 0 : Int(leads[leads.count / 2].rounded())
                // 이 세션이 어느 루프를 돌리려고 열린 것인지 — 판정은 세션 원장이 소유한다.
                let v = LoopSessionLedger.verdict(sid: sid)
                let primaryModel = st.models.max(by: { ($0.value.inTok + $0.value.outTok) < ($1.value.inTok + $1.value.outTok) })
                let primaryEffort = primaryModel?.value.efforts.max(by: { $0.value < $1.value })?.key ?? primaryModel?.value.effort ?? ""
                // 창 점유 — 값이 없으면 0 이 아니라 null 이다. 0 을 내려보내면 화면이
                // "창을 안 썼다"로 그리게 되고, 그것은 없는 것과 다른 거짓말이 된다.
                let ctxWin = Self.resolvedWindow(model: st.ctxModel, peak: st.ctxPeak)
                let ctxFinalJSON = st.ctxFinal > 0 ? String(st.ctxFinal) : "null"
                let ctxPeakJSON = st.ctxPeak > 0 ? String(st.ctxPeak) : "null"
                let ctxWinJSON = ctxWin.map(String.init) ?? "null"
                var ctxPctJSON = "null"
                if let w = ctxWin, w > 0, st.ctxFinal > 0 {
                    ctxPctJSON = String(format: "%.1f", (Double(st.ctxFinal) / Double(w)) * 100)
                }
                let json = "{\"sid\":\(jsonString(String(sid.prefix(8)))),\"provider\":\(jsonString(facts.provider)),"
                    + "\"account\":\(jsonString(facts.accountId)),\"accountLabel\":\(jsonString(facts.accountLabel)),\"accountColor\":\(jsonString(facts.accountColor)),"
                    + "\"proj\":\(jsonString(proj)),\"title\":\(jsonString(facts.title)),"
                    + "\"loop\":\(jsonString(v?.label ?? "")),\"loopKind\":\(jsonString(v?.kind ?? "")),"
                    + "\"tokens\":\(st.spent),\"k\":\(Int((Double(st.spent) / 1000.0).rounded())),"
                    + "\"effort\":\(jsonString(primaryEffort)),"
                    + "\"inTok\":\(st.inTok),\"outTok\":\(st.outTok),\"thinkTok\":\(st.thinkTok),"
                    + "\"textTok\":\(st.textTok),\"toolTok\":\(st.toolTok),"
                    + "\"typedTok\":\(st.typedTok),\"imgN\":\(st.imgN),\"imgBytes\":\(st.imgBytes),"
                    + "\"imgTok\":\(st.imgTok),\"toolResTok\":\(st.toolResTok),\"reloadTok\":\(st.reloadTok),"
                    + "\"aiSec\":\(st.aiSec),"
                    + "\"models\":\(modelsJSON(st.models)),"
                    + "\"ctxFinal\":\(ctxFinalJSON),\"ctxPeak\":\(ctxPeakJSON),"
                    + "\"ctxWin\":\(ctxWinJSON),\"ctxPct\":\(ctxPctJSON),"
                    + "\"ctxModel\":\(jsonString(st.ctxModel)),"
                    + "\"leadN\":\(leads.count),\"leadMed\":\(leadMed)}"
                rows.append((st.spent, json))
            }
        }

        // Multi-LLM: Codex sessions for this day
        let codexSessions = CodexTokenCollector.shared.fetchSessions(since: dayStart)
        let codexAcc = LLMAccountStore.shared.resolve(provider: "codex", accountId: "local")
        for cs in codexSessions where cs.day == day {
            let proj = cs.cwd.split(separator: "/").last.map(String.init) ?? "codex"
            let inTok = Int(Double(cs.tokensUsed) * 0.65)
            let outTok = Int(Double(cs.tokensUsed) * 0.35)
            let json = "{\"sid\":\(jsonString(String(cs.id.prefix(8)))),\"provider\":\"codex\","
                + "\"account\":\(jsonString(codexAcc.id)),\"accountLabel\":\(jsonString(codexAcc.label)),\"accountColor\":\(jsonString(codexAcc.color)),"
                + "\"proj\":\(jsonString(proj)),\"title\":\(jsonString(cs.title)),\"loop\":\"\",\"loopKind\":\"\","
                + "\"tokens\":\(cs.tokensUsed),\"k\":\(Int((Double(cs.tokensUsed) / 1000.0).rounded())),"
                + "\"effort\":\(jsonString(cs.reasoningEffort)),"
                + "\"inTok\":\(inTok),\"outTok\":\(outTok),\"thinkTok\":0,"
                + "\"textTok\":\(outTok),\"toolTok\":0,\"typedTok\":0,\"imgN\":0,\"imgBytes\":0,\"imgTok\":0,"
                + "\"toolResTok\":0,\"reloadTok\":0,\"aiSec\":0,"
                + "\"models\":{\(jsonString(cs.model)):{\"in\":\(inTok),\"cr\":0,\"c5m\":0,\"c1h\":0,\"out\":\(outTok),\"effort\":\(jsonString(cs.reasoningEffort))}},"
                // 코덱스 수집기는 세션 총 토큰만 준다 — 턴별 컨텍스트가 없으므로 창 점유를
                // 0 으로 내리지 않고 모른다고 한다. 0 은 "창이 텅 비었다"는 거짓말이 된다.
                + "\"ctxFinal\":null,\"ctxPeak\":null,\"ctxWin\":null,\"ctxPct\":null,\"ctxModel\":\"\","
                + "\"leadN\":0,\"leadMed\":0}"
            rows.append((cs.tokensUsed, json))
        }

        // Multi-LLM: Antigravity sessions for this day
        let agySessions = AntigravityTokenCollector.shared.fetchSessions(since: dayStart)
        let agyAcc = LLMAccountStore.shared.resolve(provider: "antigravity", accountId: "default")
        for asess in agySessions where asess.day == day {
            let proj = asess.cwd.split(separator: "/").last.map(String.init) ?? "antigravity"
            let json = "{\"sid\":\(jsonString(String(asess.id.prefix(8)))),\"provider\":\"antigravity\","
                + "\"account\":\(jsonString(agyAcc.id)),\"accountLabel\":\(jsonString(agyAcc.label)),\"accountColor\":\(jsonString(agyAcc.color)),"
                + "\"proj\":\(jsonString(proj)),\"title\":\(jsonString(asess.title)),\"loop\":\"\",\"loopKind\":\"\","
                + "\"tokens\":\(asess.tokensUsed),\"k\":\(Int((Double(asess.tokensUsed) / 1000.0).rounded())),"
                + "\"effort\":\(jsonString(asess.effort)),"
                + "\"inTok\":\(asess.inTok),\"outTok\":\(asess.outTok),\"thinkTok\":0,"
                + "\"textTok\":\(asess.outTok),\"toolTok\":0,\"typedTok\":\(asess.inTok),\"imgN\":0,\"imgBytes\":0,\"imgTok\":0,"
                + "\"toolResTok\":0,\"reloadTok\":0,\"aiSec\":0,"
                + "\"models\":{\(jsonString(asess.model)):{\"in\":\(asess.inTok),\"cr\":0,\"c5m\":0,\"c1h\":0,\"out\":\(asess.outTok),\"effort\":\(jsonString(asess.effort))}},"
                // 안티그라비티도 턴별 컨텍스트가 없다 — 위 코덱스와 같은 이유로 전부 null.
                + "\"ctxFinal\":null,\"ctxPeak\":null,\"ctxWin\":null,\"ctxPct\":null,\"ctxModel\":\"\","
                + "\"leadN\":0,\"leadMed\":0}"
            rows.append((asess.tokensUsed, json))
        }

        rows.sort { $0.spent > $1.spent }
        return "{\"day\":\(jsonString(day)),\"sessions\":[\(rows.map(\.json).joined(separator: ","))]}"
    }

    // GET /tokens-detail.json?sid=XXXXXXXX&day=YYYY-MM-DD — 버킷 내용물 드릴다운. 세션 상세의
    // 구성비를 클릭하면 그 세션·그날의 컨텍스트가 실제로 무엇이었는지 항목 단위로 나열한다:
    // typed(친 프롬프트 원문 머리), img(첨부 이미지 — 형식·해상도·용량), toolres(도구 결과 —
    // 어느 도구가 무엇을 읽어왔는지), reload(턴별 재캐시 크기 — 히스토리가 무거워진 지점).
    // 목적: 세션을 열어 일일이 뒤지지 않고 "무엇이 토큰을 먹는지, 무엇을 잘라낼지" 판단.
    func dashboardTokenDetail(_ path: String) -> String {
        let q = URLComponents(string: "http://x" + path)?.queryItems
        guard let sid = q?.first(where: { $0.name == "sid" })?.value, sid.count >= 6,
              let day = q?.first(where: { $0.name == "day" })?.value, day.count == 10,
              sid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return "{\"items\":{}}" }
        let fm = FileManager.default
        var file: URL?
        if let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            outer: for dir in subs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                    where f.pathExtension == "jsonl" && f.lastPathComponent.hasPrefix(sid) {
                    file = f; break outer
                }
            }
        }
        guard let file, let data = try? Data(contentsOf: file) else { return "{\"items\":{}}" }

        let dayFmt = DateFormatter(); dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = Settings.shared.displayTimeZone; dayFmt.dateFormat = "yyyy-MM-dd"
        let hmFmt = DateFormatter(); hmFmt.locale = Locale(identifier: "en_US_POSIX")
        hmFmt.timeZone = Settings.shared.displayTimeZone; hmFmt.dateFormat = "HH:mm"

        var typed: [(tok: Int, json: String)] = []
        var imgs: [(tok: Int, json: String)] = []
        var toolres: [(tok: Int, json: String)] = []
        var reload: [(tok: Int, json: String)] = []
        var toolLabel: [String: String] = [:]   // tool_use id -> "Read …/file.swift"
        var seenMid = Set<String>()
        func clip(_ s: String, _ n: Int = 110) -> String {
            let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return t.count > n ? String(t.prefix(n)) + "…" : t
        }

        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String,
                  let msg = obj["message"] as? [String: Any] else { return }
            let ts = (obj["timestamp"] as? String).flatMap { self.parseTS($0) }
            guard let ts, dayFmt.string(from: ts) == day else {
                // 라벨 맵은 날짜와 무관하게 채운다 — 도구 호출이 전날, 결과가 이날일 수 있다.
                if type == "assistant", let content = msg["content"] as? [[String: Any]] {
                    for b in content where (b["type"] as? String) == "tool_use" {
                        let name = (b["name"] as? String) ?? "?"
                        let inp = (b["input"] as? [String: Any]) ?? [:]
                        let arg = (inp["file_path"] as? String) ?? (inp["command"] as? String)
                            ?? (inp["url"] as? String) ?? (inp["pattern"] as? String)
                            ?? (inp["query"] as? String) ?? (inp["prompt"] as? String) ?? ""
                        if let bid = b["id"] as? String { toolLabel[bid] = clip(name + " " + arg, 90) }
                    }
                }
                return
            }
            let hm = hmFmt.string(from: ts)

            if type == "assistant" {
                if let content = msg["content"] as? [[String: Any]] {
                    for b in content where (b["type"] as? String) == "tool_use" {
                        let name = (b["name"] as? String) ?? "?"
                        let inp = (b["input"] as? [String: Any]) ?? [:]
                        let arg = (inp["file_path"] as? String) ?? (inp["command"] as? String)
                            ?? (inp["url"] as? String) ?? (inp["pattern"] as? String)
                            ?? (inp["query"] as? String) ?? (inp["prompt"] as? String) ?? ""
                        if let bid = b["id"] as? String { toolLabel[bid] = clip(name + " " + arg, 90) }
                    }
                }
                // 턴 재캐시: 요청마다 usage 1회(같은 메시지의 후속 라인은 중복) — input+cache_creation.
                let mid = (msg["id"] as? String) ?? (obj["requestId"] as? String) ?? (obj["uuid"] as? String) ?? line
                guard !seenMid.contains(mid) else { return }
                seenMid.insert(mid)
                let usage = (msg["usage"] as? [String: Any]) ?? [:]
                let tok = ((usage["input_tokens"] as? Int) ?? 0) + ((usage["cache_creation_input_tokens"] as? Int) ?? 0)
                if tok > 0 {
                    let model = ((msg["model"] as? String) ?? "").replacingOccurrences(of: "claude-", with: "")
                    reload.append((tok, "{\"t\":\(self.jsonString(hm)),\"tok\":\(tok),\"label\":\(self.jsonString(model))}"))
                }
                return
            }

            guard type == "user" else { return }
            let sidechain = (obj["isSidechain"] as? Bool) == true
            if let arr = msg["content"] as? [[String: Any]] {
                for b in arr where (b["type"] as? String) == "tool_result" {
                    var tok = 0
                    if let s = b["content"] as? String { tok = self.estTextTokens(s) }
                    else if let inner = b["content"] as? [[String: Any]] {
                        for ib in inner {
                            switch ib["type"] as? String {
                            case "text": tok += self.estTextTokens((ib["text"] as? String) ?? "")
                            case "image":
                                let src = (ib["source"] as? [String: Any]) ?? [:]
                                tok += self.estImage(base64: (src["data"] as? String) ?? "").tok
                            default: break
                            }
                        }
                    }
                    guard tok > 0 else { continue }
                    let label = (b["tool_use_id"] as? String).flatMap { toolLabel[$0] } ?? "도구 결과"
                    toolres.append((tok, "{\"t\":\(self.jsonString(hm)),\"tok\":\(tok),\"label\":\(self.jsonString(label))}"))
                }
            }
            // 사람 프롬프트 + 첨부 이미지 (transcriptStats의 isHuman 판정과 동일 게이트)
            if !sidechain, (obj["isMeta"] as? Bool) != true, obj["toolUseResult"] == nil {
                var isHuman = false
                if let origin = obj["origin"] as? [String: Any] { isHuman = (origin["kind"] as? String) == "human" }
                else if let s = msg["content"] as? String { isHuman = !s.isEmpty }
                else if let arr = msg["content"] as? [[String: Any]] {
                    let kinds = arr.compactMap { $0["type"] as? String }
                    isHuman = kinds.contains("text") && !kinds.contains("tool_result")
                }
                guard isHuman else { return }
                if let s = msg["content"] as? String {
                    let tok = self.estTextTokens(s)
                    if tok > 0 { typed.append((tok, "{\"t\":\(self.jsonString(hm)),\"tok\":\(tok),\"label\":\(self.jsonString(clip(s)))}")) }
                } else if let arr = msg["content"] as? [[String: Any]] {
                    for b in arr {
                        switch b["type"] as? String {
                        case "text":
                            let s = (b["text"] as? String) ?? ""
                            let tok = self.estTextTokens(s)
                            if tok > 0 { typed.append((tok, "{\"t\":\(self.jsonString(hm)),\"tok\":\(tok),\"label\":\(self.jsonString(clip(s)))}")) }
                        case "image":
                            let src = (b["source"] as? [String: Any]) ?? [:]
                            let b64 = (src["data"] as? String) ?? ""
                            let est = self.estImage(base64: b64)
                            let media = ((src["media_type"] as? String) ?? "image").replacingOccurrences(of: "image/", with: "")
                            let prefix = String(b64.prefix(86400 - 86400 % 4))
                            let dims = Data(base64Encoded: prefix, options: .ignoreUnknownCharacters).flatMap { self.imageDims($0) }
                            let label = media + (dims.map { " \($0.w)×\($0.h)" } ?? "")
                            imgs.append((est.tok, "{\"t\":\(self.jsonString(hm)),\"tok\":\(est.tok),\"bytes\":\(est.bytes),\"label\":\(self.jsonString(label))}"))
                        default: break
                        }
                    }
                }
            }
        }

        // 큰 항목 먼저, 종류별 상한 — 초과분은 개수·토큰 합계로만 알린다(조용한 절단 금지).
        func pack(_ items: [(tok: Int, json: String)], cap: Int) -> String {
            let sorted = items.sorted { $0.tok > $1.tok }
            let kept = sorted.prefix(cap)
            let dropped = sorted.dropFirst(cap)
            let more = dropped.isEmpty ? "" : ",\"moreN\":\(dropped.count),\"moreTok\":\(dropped.reduce(0) { $0 + $1.tok })"
            return "{\"list\":[\(kept.map(\.json).joined(separator: ","))]\(more)}"
        }
        return "{\"day\":\(self.jsonString(day)),\"sid\":\(self.jsonString(sid)),\"items\":{"
            + "\"typed\":\(pack(typed, cap: 100)),\"img\":\(pack(imgs, cap: 100)),"
            + "\"toolres\":\(pack(toolres, cap: 150)),\"reload\":\(pack(reload, cap: 100))}}"
    }

    // Parse one transcript into per-local-day token stats (input + output + cache-creation;
    // cache_read excluded to avoid replayed-context inflation). One API response is written
    // as several JSONL lines (one per content block) each repeating the SAME usage object,
    // so usage is counted once per message id — the old per-line sum inflated totals 2-4x.
    // Also splits output into thinking/text/tool by block character weight, and collects
    // human prompt lead times. Cached by (mtime,size) so an unchanged file is never
    // re-parsed. Shared by the daily timeline and the per-session goal total.
    private func tokensByDay(file: URL, mtime: Date, size: Int) -> [String: DayTok] {
        return transcriptStats(file: file, mtime: mtime, size: size).days
    }

    // Rough token estimate for prompt-side text. CJK runs ~1.5-2 chars/token, ASCII ~4;
    // exact per-block input tokens are not in the transcript, so this is a display estimate.
    private func estTextTokens(_ s: String) -> Int {
        var cjk = 0, other = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F,   // Hangul
                 0x3040...0x30FF, 0x4E00...0x9FFF, 0xF900...0xFAFF:   // Kana + CJK ideographs
                cjk += 1
            default:
                other += 1
            }
        }
        return Int((Double(cjk) / 1.6 + Double(other) / 3.9).rounded())
    }

    // Pixel dimensions from a PNG/JPEG header (nil for other formats or corrupt data).
    private func imageDims(_ data: Data) -> (w: Int, h: Int)? {
        let b = [UInt8](data.prefix(65536))
        if b.count > 24, b[0] == 0x89, b[1] == 0x50 {   // PNG: IHDR width/height at 16..23
            let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
            let h = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
            if w > 0, h > 0 { return (w, h) }
        }
        if b.count > 4, b[0] == 0xFF, b[1] == 0xD8 {    // JPEG: first SOF segment
            var i = 2
            while i + 9 < b.count {
                guard b[i] == 0xFF else { i += 1; continue }
                let m = b[i + 1]
                if m == 0xD8 || (0xD0...0xD7).contains(m) || m == 0x01 { i += 2; continue }
                if (0xC0...0xCF).contains(m), m != 0xC4, m != 0xC8, m != 0xCC {
                    let h = Int(b[i + 5]) << 8 | Int(b[i + 6])
                    let w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                    return (w > 0 && h > 0) ? (w, h) : nil
                }
                i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
            }
        }
        return nil
    }

    // Estimated tokens + raw bytes for one base64 image block. Token formula is the API's
    // w*h/750 (capped ~1600, the >1568px downscale ceiling); unparseable formats fall back
    // to a byte-based guess so an image never counts as zero.
    private func estImage(base64 b64: String) -> (tok: Int, bytes: Int) {
        let bytes = b64.count * 3 / 4
        // Decode only a header-sized prefix (multiple of 4 chars) — dims live up front.
        let prefix = String(b64.prefix(86400 - 86400 % 4))
        if let d = Data(base64Encoded: prefix, options: .ignoreUnknownCharacters),
           let dims = imageDims(d) {
            return (min(1600, dims.w * dims.h / 750), bytes)
        }
        return (min(1600, max(300, bytes / 1500)), bytes)
    }

    // Full per-transcript stats: per-day aggregates + a human-readable session title
    // (last custom-title line, else the first human prompt's first line).
    private func transcriptStats(file: URL, mtime: Date, size: Int) -> TranscriptFacts {
        // Cache key carries the display timezone: switching KST↔UTC moves day boundaries,
        // so per-day splits cached under another zone must not be reused.
        let key = file.path + "|" + Settings.shared.displayTimeZone.identifier
        tokenDayLock.lock()
        let cached = tokenDayCache[key]
        tokenDayLock.unlock()
        if let c = cached, c.mtime == mtime, c.size == size { return c.facts }

        var perDay: [String: DayTok] = [:]
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = Settings.shared.displayTimeZone
        dayFmt.dateFormat = "yyyy-MM-dd"   // 표시 타임존 — same day boundary as the rest of the UI

        // Per-message accumulator: usage once, block chars summed across the message's lines.
        struct MsgAgg { var day = ""; var model = ""; var effort = ""; var input = 0; var output = 0; var cc = 0
                        var cr = 0; var c5m = 0; var c1h = 0
                        var th = 0; var tx = 0; var tool = 0; var blockSeen = Set<Int>()
                        // 창 점유 축 — 이 요청 하나에 실제로 실린 프롬프트 총량. 누적이 아니다.
                        var ctx = 0
                        // 서브에이전트 줄은 자기 컨텍스트를 따로 가지므로 부모의 창 점유로 세면 안 된다.
                        var sidechain = false }
        var msgs: [String: MsgAgg] = [:]
        var msgOrder: [String] = []
        var lastAssistantTS: Date?   // end of the assistant's turn, for prompt lead time
        var customTitle = ""         // last custom-title line wins
        var firstPrompt = ""         // first human prompt, fallback title
        // 세션 원장(LoopSessionLedger)이 "이 세션은 어느 루프를 돌리려고 열렸나"를 판정하는 근거.
        // 제목용 firstPrompt 는 첫 줄 80자라 "Run exactly ONE SB-PO cycle now, following…" 같은
        // 하네스 서명을 잘라 먹는다. 그래서 판정용으로 여러 줄 400자를 따로 남긴다.
        var firstPromptFull = ""
        var cwd = ""                 // 프로젝트 귀속의 근거 — 트랜스크립트 줄마다 실려 있다
        var accountUuid = ""         // ownerAccountUuid / accountUuid — 다중 계정 귀속 근거
        // 세션이 언제 열려 언제까지 갔는지, 그 안에서 몇 턴이 돌고 도구를 몇 번 불렀는지.
        // 루프 세션 목록이 "8월 29일 05:30 · 24분 · 도구 61회"로 한 줄을 적는 근거다.
        var firstTS: Date?
        var lastTS: Date?
        var turnCount = 0
        var toolCount = 0
        // AI-runtime turn tracking: a turn spans human prompt -> last AI/tool line before
        // the next human prompt. Idle time after the AI stops is charged to nobody (the
        // user walking away for 8h must not inflate this), so the turn is closed at
        // lastAITS, not at the next prompt's timestamp. Sidechain (subagent) lines count —
        // that's real AI work inside the turn.
        var turnStart: Date?
        var turnDay = ""
        var lastAITS: Date?
        func closeTurn(_ perDay: inout [String: DayTok]) {
            if let s = turnStart, let e = lastAITS, e > s {
                perDay[turnDay, default: DayTok()].aiSec += Int(e.timeIntervalSince(s).rounded())
            }
            turnStart = nil
        }

        if let data = try? Data(contentsOf: file) {
            String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
                guard let d = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let type = obj["type"] as? String else { return }
                let sidechain = (obj["isSidechain"] as? Bool) == true
                if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
                if accountUuid.isEmpty {
                    if let a = obj["ownerAccountUuid"] as? String, !a.isEmpty { accountUuid = a }
                    else if let a = obj["accountUuid"] as? String, !a.isEmpty { accountUuid = a }
                }
                if let t = (obj["timestamp"] as? String).flatMap({ self.parseTS($0) }) {
                    if firstTS == nil { firstTS = t }
                    lastTS = t
                }

                if type == "custom-title" {
                    if let t = obj["customTitle"] as? String, !t.isEmpty { customTitle = t }
                    return
                }

                if type == "assistant" {
                    guard let msg = obj["message"] as? [String: Any],
                          let tsStr = obj["timestamp"] as? String,
                          let ts = self.parseTS(tsStr) else { return }
                    // A subagent (sidechain) line spends real tokens but does not end the
                    // human's turn, so it never anchors a lead-time measurement.
                    if !sidechain { lastAssistantTS = ts }
                    lastAITS = ts   // any assistant line (sidechain too) extends the AI turn
                    let mid = (msg["id"] as? String) ?? (obj["requestId"] as? String)
                        ?? (obj["uuid"] as? String) ?? line
                    let eff = (obj["effort"] as? String) ?? ((msg["effort"] as? String) ?? "")
                    if msgs[mid] == nil {
                        var a = MsgAgg()
                        a.day = dayFmt.string(from: ts)
                        a.model = (msg["model"] as? String) ?? ""
                        a.effort = eff
                        let usage = (msg["usage"] as? [String: Any]) ?? [:]
                        a.input = (usage["input_tokens"] as? Int) ?? 0
                        a.output = (usage["output_tokens"] as? Int) ?? 0
                        a.cc = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                        a.cr = (usage["cache_read_input_tokens"] as? Int) ?? 0
                        // Cache-write TTL split (5m=1.25x vs 1h=2x input rate). Older
                        // transcripts lack the detail — fall back to counting it all as 5m.
                        if let ccd = usage["cache_creation"] as? [String: Any] {
                            a.c5m = (ccd["ephemeral_5m_input_tokens"] as? Int) ?? 0
                            a.c1h = (ccd["ephemeral_1h_input_tokens"] as? Int) ?? 0
                            if a.c5m + a.c1h == 0 { a.c5m = a.cc }
                        } else {
                            a.c5m = a.cc
                        }
                        // 이 요청이 창에 실제로 올린 프롬프트 = 새 입력 + 캐시 재사용 + 캐시 생성.
                        // spent(누적)와 다른 축이다 — 더하면 안 되고 마지막·최대만 의미가 있다.
                        a.ctx = a.input + a.cr + a.cc
                        a.sidechain = sidechain
                        msgs[mid] = a; msgOrder.append(mid)
                        if !sidechain { turnCount += 1 }
                    } else if !eff.isEmpty, var existing = msgs[mid], existing.effort.isEmpty {
                        existing.effort = eff
                        msgs[mid] = existing
                    }
                    if var a = msgs[mid], let content = msg["content"] as? [[String: Any]] {
                        for b in content {
                            // The same block can be re-emitted on a later line of the same
                            // message; hash the payload so its chars count once.
                            switch b["type"] as? String {
                            case "thinking":
                                let s = (b["thinking"] as? String) ?? ""
                                if a.blockSeen.insert(("th" + s).hashValue).inserted { a.th += s.count }
                            case "text":
                                let s = (b["text"] as? String) ?? ""
                                if a.blockSeen.insert(("tx" + s).hashValue).inserted { a.tx += s.count }
                            case "tool_use":
                                let bid = (b["id"] as? String) ?? ""
                                var n = 16
                                if let inp = b["input"],
                                   let bd = try? JSONSerialization.data(withJSONObject: inp) { n = max(n, bd.count) }
                                if a.blockSeen.insert(("tool" + bid).hashValue).inserted {
                                    a.tool += n; toolCount += 1
                                }
                            default: break
                            }
                        }
                        msgs[mid] = a
                    }
                    return
                }

                if type == "user", let msg = obj["message"] as? [String: Any] {
                    let ts0 = (obj["timestamp"] as? String).flatMap { self.parseTS($0) }
                    // Tool results fed back to the model (any user line, sidechain included):
                    // measure their text/images into the 도구 결과 bucket, and let the line
                    // extend the AI turn — tool execution time is the AI working.
                    if let arr = msg["content"] as? [[String: Any]] {
                        var trTok = 0
                        for b in arr where (b["type"] as? String) == "tool_result" {
                            if let s = b["content"] as? String { trTok += self.estTextTokens(s) }
                            else if let inner = b["content"] as? [[String: Any]] {
                                for ib in inner {
                                    switch ib["type"] as? String {
                                    case "text": trTok += self.estTextTokens((ib["text"] as? String) ?? "")
                                    case "image":
                                        let src = (ib["source"] as? [String: Any]) ?? [:]
                                        trTok += self.estImage(base64: (src["data"] as? String) ?? "").tok
                                    default: break
                                    }
                                }
                            }
                        }
                        if trTok > 0, let ts = ts0 {
                            perDay[dayFmt.string(from: ts), default: DayTok()].toolResTok += trTok
                            lastAITS = ts
                        }
                    }
                }

                // Human-typed prompt (not a tool_result, not meta, not a subagent feed):
                // its distance from the assistant's last line is the "read + think + type
                // the next prompt" lead time. >30 min means the user walked away — skip.
                if type == "user", !sidechain, (obj["isMeta"] as? Bool) != true,
                   obj["toolUseResult"] == nil,
                   let msg = obj["message"] as? [String: Any] {
                    var isHuman = false
                    if let origin = obj["origin"] as? [String: Any] {
                        isHuman = (origin["kind"] as? String) == "human"
                    } else if let s = msg["content"] as? String {
                        isHuman = !s.isEmpty
                    } else if let arr = msg["content"] as? [[String: Any]] {
                        let kinds = arr.compactMap { $0["type"] as? String }
                        isHuman = kinds.contains("text") && !kinds.contains("tool_result")
                    }
                    guard isHuman, let tsStr = obj["timestamp"] as? String,
                          let ts = self.parseTS(tsStr) else { return }
                    // Typed text + attached images -> their prompt-side buckets.
                    let hDay = dayFmt.string(from: ts)
                    var st = perDay[hDay, default: DayTok()]
                    if let s = msg["content"] as? String {
                        st.typedTok += self.estTextTokens(s)
                    } else if let arr = msg["content"] as? [[String: Any]] {
                        for b in arr {
                            switch b["type"] as? String {
                            case "text":
                                st.typedTok += self.estTextTokens((b["text"] as? String) ?? "")
                            case "image":
                                let src = (b["source"] as? [String: Any]) ?? [:]
                                let est = self.estImage(base64: (src["data"] as? String) ?? "")
                                st.imgN += 1; st.imgBytes += est.bytes; st.imgTok += est.tok
                            default: break
                            }
                        }
                    }
                    perDay[hDay] = st
                    // New human prompt = previous AI turn is over; start the next one.
                    closeTurn(&perDay)
                    turnStart = ts; turnDay = hDay
                    if firstPrompt.isEmpty {
                        var text = msg["content"] as? String ?? ""
                        if text.isEmpty, let arr = msg["content"] as? [[String: Any]] {
                            text = arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                                .first ?? ""
                        }
                        let line1 = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                        firstPrompt = String(line1.trimmingCharacters(in: .whitespaces).prefix(80))
                        firstPromptFull = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
                    }
                    if let prev = lastAssistantTS {
                        let lead = ts.timeIntervalSince(prev)
                        if lead > 0, lead <= 1800 {
                            perDay[dayFmt.string(from: ts), default: DayTok()].leads.append(lead)
                        }
                    }
                    lastAssistantTS = nil   // one lead per assistant turn
                }
            }
        }
        closeTurn(&perDay)   // a transcript ending mid-turn still charges its AI runtime

        // Fold per-message aggregates into per-day stats, apportioning output_tokens
        // across thinking/text/tool by character weight (estimate; exact split is not
        // recorded in the transcript).
        for mid in msgOrder {
            guard let a = msgs[mid] else { continue }
            let spent = a.input + a.output + a.cc
            if spent == 0 { continue }
            var st = perDay[a.day, default: DayTok()]
            // 창 점유 — 더하지 않는다. 서브에이전트(sidechain)는 자기 창을 따로 쓰므로
            // 부모 세션의 점유로 세면 부모가 쓰지도 않은 창을 쓴 것으로 보인다.
            if !a.sidechain && a.ctx > 0 {
                st.ctxPeak = max(st.ctxPeak, a.ctx)
                st.ctxFinal = a.ctx          // msgOrder is file order, so the last write wins
                st.ctxModel = a.model
            }
            st.spent += spent
            st.inTok += a.input + a.cc
            st.outTok += a.output
            var mu = st.models[a.model, default: ModelUse()]
            mu.inTok += a.input; mu.cacheRead += a.cr
            mu.cache5m += a.c5m; mu.cache1h += a.c1h; mu.outTok += a.output
            if !a.effort.isEmpty {
                mu.effort = a.effort
                mu.efforts[a.effort, default: 0] += spent
            }
            st.models[a.model] = mu
            let chars = a.th + a.tx + a.tool
            if a.output > 0 {
                if chars > 0 {
                    let th = Int((Double(a.output) * Double(a.th) / Double(chars)).rounded())
                    let tool = Int((Double(a.output) * Double(a.tool) / Double(chars)).rounded())
                    st.thinkTok += th
                    st.toolTok += tool
                    st.textTok += max(0, a.output - th - tool)
                } else {
                    st.textTok += a.output
                }
            }
            perDay[a.day] = st
        }

        // Prompt-side residual: what inTok holds beyond the measured typed/image/tool-result
        // estimates = conversation re-cache + system prompt. Estimates can overshoot on a
        // sparse day; clamp at zero rather than showing a negative bucket.
        for (day, var st) in perDay {
            st.reloadTok = max(0, st.inTok - st.typedTok - st.imgTok - st.toolResTok)
            perDay[day] = st
        }

        let title = customTitle.isEmpty ? firstPrompt : customTitle
        // ~/.claude/projects 아래에 있다고 전부 클로드가 아니다. glm-claude 는 Claude Code 를
        // z.ai 의 Anthropic 호환 엔드포인트로 꺾어 띄우므로, GLM 세션의 트랜스크립트가 여기에
        // 그대로 섞여 쌓인다. 그것을 클로드로 세면 GLM 이 쓴 토큰이 `클로드 기본` 에 묻혀
        // 골라낼 수 없게 된다 — 총합에는 들어가는데 추적은 안 되는 상태. 그래서 provider 는
        // 폴더가 아니라 메시지의 model 이름으로 판정한다.
        let claudeAcc = LLMAccountStore.shared.resolve(provider: "claude", accountId: accountUuid)
        let sawGLM = perDay.values.contains { st in
            st.models.keys.contains { Self.providerForModel($0) == "glm" }
        }
        // GLM 계정 해석은 목록 파일을 읽으므로, GLM 이 실제로 쓰인 세션에서만 부른다.
        let glmAcc = sawGLM ? LLMAccountStore.shared.activeGLMAccount() : nil
        var glmTotal = 0, allTotal = 0
        for day in perDay.keys {
            var st = perDay[day]!
            // 모델별 사용량에서 GLM 몫을 다시 뽑는다. ModelUse 의 네 필드 합은 그 모델의
            // (input + output + cache_creation) 이라 spent 와 같은 단위다.
            var glmSpent = 0
            for (m, u) in st.models where Self.providerForModel(m) == "glm" {
                glmSpent += u.inTok + u.outTok + u.cache5m + u.cache1h
            }
            glmSpent = min(max(0, glmSpent), st.spent)
            let claudeSpent = st.spent - glmSpent
            if let g = glmAcc, glmSpent > 0 {
                st.accounts[g.id] = (st.accounts[g.id] ?? 0) + glmSpent
                st.providers["glm"] = (st.providers["glm"] ?? 0) + glmSpent
            }
            if claudeSpent > 0 {
                st.accounts[claudeAcc.id] = (st.accounts[claudeAcc.id] ?? 0) + claudeSpent
                st.providers["claude"] = (st.providers["claude"] ?? 0) + claudeSpent
            }
            glmTotal += glmSpent; allTotal += st.spent
            perDay[day] = st
        }
        // 세션 한 줄에 붙는 뱃지는 하나뿐이라 다수결로 정한다. 한 창은 엔드포인트가 하나이므로
        // 실제로 섞이는 일은 드물다 — 섞였다면 더 많이 쓴 쪽이 그 세션의 성격이다.
        let sessionIsGLM = (glmAcc != nil) && glmTotal * 2 > allTotal
        let acc = sessionIsGLM ? glmAcc! : claudeAcc
        let facts = TranscriptFacts(days: perDay, title: title, cwd: cwd, prompt: firstPromptFull,
                                    firstTS: firstTS, lastTS: lastTS, turns: turnCount, tools: toolCount,
                                    accountId: acc.id, accountLabel: acc.label, accountColor: acc.color,
                                    provider: sessionIsGLM ? "glm" : "claude")
        tokenDayLock.lock()
        tokenDayCache[key] = (mtime, size, facts)
        tokenDayLock.unlock()
        return facts
    }

    // 한 세션·하루의 모델 사용량을 $ 로. 산식과 단가는 토큰 뷰의 TK_PRICE/tkModelCost 와 같은
    // 것이어야 한다 — 화면 두 곳이 같은 세션에 다른 금액을 적으면 둘 다 못 믿게 된다.
    // 캐시 읽기는 토큰 합계(spent)에는 안 들어가지만 과금에는 들어간다.
    private static let modelPrices: [(String, Double, Double)] = [
        ("claude-fable-5", 10, 50), ("claude-mythos", 10, 50),
        ("claude-opus-4-1", 15, 75), ("claude-opus-4-0", 15, 75),
        ("claude-opus", 5, 25),
        ("claude-sonnet", 3, 15),
        ("claude-3-5-haiku", 0.8, 4), ("claude-3-haiku", 0.25, 1.25),
        ("claude-haiku", 1, 5),
        // GLM (z.ai) — 접두어가 긴 것이 먼저 와야 한다(첫 일치가 이긴다).
        ("glm-4.5-air", 0.2, 1.1), ("glm-4.6", 0.6, 2.2),
        ("glm-5", 0.5, 1.5), ("glm-4", 0.5, 1.5),
    ]

    // 모델 이름 → provider. 트랜스크립트가 놓인 폴더가 아니라 모델이 근거다 — glm-claude 가
    // Claude Code 를 z.ai 로 꺾어 띄우면 GLM 세션도 ~/.claude/projects 에 쌓이기 때문이다.
    // 토큰 뷰의 provider 축과 계정 귀속이 둘 다 이 한 곳을 쓴다.
    static func providerForModel(_ model: String) -> String {
        let m = model.lowercased()
        if m.hasPrefix("glm") { return "glm" }
        return "claude"
    }

    // 모델 → 컨텍스트 윈도우 (2026-09-04 공시 기준). 접두어 매칭, 위에서 첫 일치.
    // 모르는 모델은 nil 이다 — 화면이 "창 —" 로 남게 하려는 것이고, 지어낸 숫자를 넣으면
    // 라우팅 판단이 틀린 분모 위에서 이루어진다.
    static func contextWindow(forModel m: String) -> Int? {
        let t: [(String, Int)] = [
            ("claude-opus", 200_000), ("claude-fable", 200_000), ("claude-mythos", 200_000),
            ("claude-sonnet", 200_000),
            ("claude-3-5-haiku", 200_000), ("claude-3-haiku", 200_000), ("claude-haiku", 200_000),
            ("gemini-", 1_048_576),
            ("gpt-4o", 128_000), ("o1", 200_000), ("o3", 200_000),
            // glm-* 은 공시 창 크기를 확인하지 못해 비워 둔다 (모르는 것을 채우지 않는다).
        ]
        for (p, w) in t where m.hasPrefix(p) { return w }
        return nil
    }
    // 표는 시작값일 뿐이다. opus-5 의 기본 창은 200K 인데 1M 컨텍스트 베타로 띄운 창이 있고,
    // 디스크에 823,490 토큰짜리 세션이 실제로 있다. 표만 믿으면 점유율이 400% 로 나온다.
    // 그래서 관측 피크가 표를 넘으면 그것을 담는 가장 작은 공시 단계로 올린다. 위로만 교정된다.
    static func resolvedWindow(model: String, peak: Int) -> Int? {
        guard let base = contextWindow(forModel: model) else { return nil }
        if peak <= base { return base }
        for tier in [200_000, 1_000_000] where peak <= tier { return max(base, tier) }
        return nil   // 어떤 단계로도 설명이 안 되면 모른다고 한다
    }
    private func modelsCostUSD(_ models: [String: ModelUse]) -> Double {
        var total = 0.0
        for (m, u) in models {
            guard let r = Self.modelPrices.first(where: { m.hasPrefix($0.0) }) else { continue }
            total += (Double(u.inTok) * r.1 + Double(u.cacheRead) * r.1 * 0.1
                      + Double(u.cache5m) * r.1 * 1.25 + Double(u.cache1h) * r.1 * 2
                      + Double(u.outTok) * r.2) / 1_000_000
        }
        return total
    }

    // Real token total (in K) for a goal's linked Claude session, summed from its transcript.
    // 0 when no transcript resolves. Cached via tokensByDay, so a completed goal parses once.
    private func sessionTokenK(for goal: ReviewStore.Goal) -> Int {
        guard let url = resolveTranscript(goal) else { return 0 }
        let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = rv?.contentModificationDate ?? .distantPast
        let size = rv?.fileSize ?? 0
        let total = tokensByDay(file: url, mtime: mtime, size: size).values.reduce(0) { $0 + $1.spent }
        return Int((Double(total) / 1000.0).rounded())
    }

    // Tiny real-time payload for the APM gauge, polled at 1 Hz (separate from the
    // heavier 5s /data.json so the needle moves like a game HUD).
    func liveData() -> String {
        let playing = director.isPlaying
        let apm = playing ? Int(activity.instantAPM) : 0
        let norm = playing ? activity.apmNorm : 0.0
        let track = playing ? (audio.currentTitle ?? "-") : "-"
        let predicted: BPMLibrary.Track? = playing ? director.predictedNextTrack() : nil
        let nextTrack = predicted?.title ?? "-"
        let normStr = String(format: "%.3f", norm)
        let gearJSON = jsonString(playing ? director.gearLabel : "-")
        let trackJSON = jsonString(track)
        let nextJSON = jsonString(nextTrack)
        return "{\"apm\":\(apm),\"norm\":\(normStr),\"gear\":\(gearJSON),\"track\":\(trackJSON),\"nextTrack\":\(nextJSON)}"
    }

    // Goals + today's review pipeline state.
    // MARK: - 부모 자동 추천 (ParentSuggest)
    // Cached suggestions + the goal-set signature they were computed for. Recomputing is
    // cheap but not free (it scans goal folders on disk), and /data.json is polled on a
    // loop, so the work runs on a background queue and only when the goal set actually
    // changed. The lock is what makes that safe: the HTTP thread reads the cache while the
    // background job writes it.
    private let psugLock = NSLock()
    private var psugItems: [ParentSuggest.Suggestion] = []
    private var psugSig = ""       // signature the cached items belong to ("" = none yet)
    private var psugPending = ""   // signature being computed right now ("" = idle)
    private var psugAt: Double = 0
    private let psugQueue = DispatchQueue(label: "cm.parentsuggest", qos: .utility)

    // Everything the score depends on. Anything NOT in here can change without triggering
    // a recompute — deliberately excludes status/time so a running timer doesn't thrash it.
    private func psugSignature(_ goals: [ReviewStore.Goal]) -> String {
        var h = Hasher()
        h.combine(goals.count)
        for g in goals {
            h.combine(g.seq); h.combine(g.text); h.combine(g.parent)
            h.combine(g.sprint); h.combine(g.archived); h.combine(g.released)
        }
        return "g\(h.finalize())"
    }

    // Drop the cache so the next read recomputes (the user just changed a parent, which
    // both moves a goal out of the orphan pool and shifts the MRU boost).
    private func psugInvalidate() {
        psugLock.lock(); psugSig = ""; psugPending = ""; psugLock.unlock()
    }

    // Kick a recompute if the goal set moved. Returns immediately; callers read whatever
    // is cached and see state "running" until the job lands.
    private func psugRefresh() {
        let goals = reviewStore.goals
        let sig = psugSignature(goals)
        psugLock.lock()
        if sig == psugSig || sig == psugPending { psugLock.unlock(); return }
        psugPending = sig
        psugLock.unlock()

        let input = goals.map {
            ParentSuggest.GoalIn(seq: $0.seq, id: $0.id, title: $0.text, parentId: $0.parent,
                                 sprint: $0.sprint, archived: $0.archived, released: $0.released)
        }
        let recent = Settings.shared.recentParentSeqs
        psugQueue.async { [weak self] in
            guard let self else { return }
            // Disk I/O stays inside the background job. Only candidate PARENTS are scanned —
            // scanning every goal folder on a large tracker would dominate the cost.
            var folders: [Int: [String]] = [:]
            for g in input where g.parentId.isEmpty && !g.archived && !g.released {
                guard let dir = IssuePaths.goalDir(seq: g.seq),
                      let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
                else { continue }
                let toks = ParentSuggest.folderTokens(names: names)
                if !toks.isEmpty { folders[g.seq] = toks }
            }
            let items = ParentSuggest.compute(goals: input, recentParentSeqs: recent,
                                              folderTokens: folders)
            self.psugLock.lock()
            // A parent change during the run already cleared psugPending; in that case this
            // result is stale, so publish the items but leave the signature empty to force
            // one more pass rather than caching an answer for a goal set that moved on.
            let stillCurrent = (self.psugPending == sig)
            self.psugItems = items
            self.psugSig = stillCurrent ? sig : ""
            if stillCurrent { self.psugPending = "" }
            self.psugAt = Date().timeIntervalSince1970
            self.psugLock.unlock()
        }
    }

    // `"psug":{state,at,items:[{seq,p,score,why}]}` for the dashboard's ghost number.
    private func psugJSON() -> String {
        psugRefresh()
        psugLock.lock()
        let items = psugItems
        let at = psugAt
        let running = !psugPending.isEmpty
        psugLock.unlock()
        let body = items.map {
            "{\"seq\":\($0.seq),\"p\":\($0.parentSeq),"
                + "\"score\":\((($0.score * 100).rounded()) / 100),\"why\":\(jsonString($0.why))}"
        }.joined(separator: ",")
        return "{\"state\":\(jsonString(running ? "running" : "ready")),\"at\":\(at),\"items\":[\(body)]}"
    }

    private func reviewJSON() -> String {
        let day = reviewStore.todayKey
        let r = reviewStore.review(day)
        let goals = reviewStore.goals
            .map { g -> String in
                // startedAt as epoch seconds (0 = not running); trackedSeconds is the
                // banked total, so the client can tick the live session locally.
                let started = g.startedAt.map { String($0.timeIntervalSince1970) } ?? "0"
                // waitingSince as epoch seconds (0 = not waiting); display-only, never
                // added to trackedSeconds. Lets the client show the live wait duration.
                let waiting = g.waitingSince.map { String($0.timeIntervalSince1970) } ?? "0"
                // Scheduling datetimes as epoch seconds (0 = unset); the client renders
                // them in the 일정관리 view and ticks D-day from targetAt.
                let target = g.targetAt.map { String($0.timeIntervalSince1970) } ?? "0"
                let completed = g.completedAt.map { String($0.timeIntervalSince1970) } ?? "0"
                let agents = g.agents.map { jsonString($0) }.joined(separator: ",")
                // Evidence: files expose a server download URL (/evidence/<goalId>/<id>);
                // links carry their own URL directly. `href` is what the dashboard opens.
                let evidence = g.evidence.map { e -> String in
                    let href = e.kind == "file" ? "/evidence/\(g.id)/\(e.id)" : e.url
                    return "{\"id\":\(jsonString(e.id)),\"kind\":\(jsonString(e.kind)),"
                        + "\"title\":\(jsonString(e.title)),\"href\":\(jsonString(href)),"
                        + "\"addedAt\":\(e.addedAt.timeIntervalSince1970)}"
                }.joined(separator: ",")
                // Tokens: the manual g.tokens field wins when set; otherwise fall back to the
                // real total parsed from this goal's linked session transcript (cached), so the
                // token view shows actual usage instead of an empty 0.
                let effTokens = g.tokens > 0 ? g.tokens : self.sessionTokenK(for: g)
                // Link chain (source-side): the client renders the link dot and follows these in export.
                let links = g.links.map { jsonString($0) }.joined(separator: ",")
                // Subtask summary (goal-NN/tasks/*): lets the dashboard 유형(type) filter
                // render task rows under the goal — without this, an added task is invisible
                // in the 목록 until the goal page is opened.
                let tasks = self.subtaskSummaryJSON(seq: g.seq)
                // 목표 추가 composer execution settings, so the UI can show/restore what a goal
                // runs with (effort/mode/cwd) and how many images are attached.
                let gImages = g.images.map { jsonString($0) }.joined(separator: ",")
                return "{\"id\":\(jsonString(g.id)),\"seq\":\(g.seq),\"text\":\(jsonString(g.text)),\"parent\":\(jsonString(g.parent)),"
                    + "\"links\":[\(links)],"
                    + "\"status\":\(jsonString(g.status)),\"trackedSeconds\":\(g.trackedSeconds),\"startedAt\":\(started),\"waitingSince\":\(waiting),"
                    + "\"energy\":\(g.energy),\"agents\":[\(agents)],\"tokens\":\(effTokens),\"value\":\(g.value),"
                    + "\"evidence\":[\(evidence)],\"sessionId\":\(jsonString(g.sessionId)),"
                    + "\"targetAt\":\(target),\"completedAt\":\(completed),"
                    + "\"sprint\":\(g.sprint),\"bump\":\(g.bump),\"released\":\(g.released),\"releaseId\":\(jsonString(g.releaseId)),\"archived\":\(g.archived),\"priority\":\(jsonString(g.priority)),"
                    + "\"effort\":\(jsonString(g.effort)),\"mode\":\(jsonString(g.mode)),\"cwd\":\(jsonString(g.cwd)),\"branch\":\(jsonString(g.branch)),\"model\":\(jsonString(g.model)),\"images\":[\(gImages)],"
                    + "\"tasks\":[\(tasks)]}"
            }
            .joined(separator: ",")
        // Release log (newest first): when each commit happened + the value it produced.
        // startedAt (0 = unknown/legacy) makes the covered period editable in the log.
        let releases = reviewStore.releases
            .map { rel -> String in
                let titles = rel.titles.map { jsonString($0) }.joined(separator: ",")
                let gids = rel.goalIds.map { jsonString($0) }.joined(separator: ",")
                // 메모장 수확분 — 로그에서 '노트' 태그로 구분 렌더된다(session 작업과 대비).
                let notes = rel.notes.map { jsonString($0) }.joined(separator: ",")
                let started = rel.startedAt.map { String($0.timeIntervalSince1970) } ?? "0"
                return "{\"id\":\(jsonString(rel.id)),\"sprint\":\(rel.sprint),\"code\":\(jsonString(rel.code)),"
                    + "\"releasedAt\":\(rel.releasedAt.timeIntervalSince1970),\"startedAt\":\(started),\"value\":\(rel.value),"
                    + "\"goalIds\":[\(gids)],\"titles\":[\(titles)],\"notes\":[\(notes)]}"
            }
            .joined(separator: ",")
        // Sprint definitions: code(YY-n) + 결과물 + 기간 + 시작/목표 날짜. closed = released.
        let sprints = reviewStore.sprints
            .map { s -> String in
                let st = s.startAt.map { String($0.timeIntervalSince1970) } ?? "0"
                let tg = s.targetAt.map { String($0.timeIntervalSince1970) } ?? "0"
                return "{\"number\":\(s.number),\"code\":\(jsonString(s.code)),\"goalText\":\(jsonString(s.goalText)),"
                    + "\"durationKind\":\(jsonString(s.durationKind)),\"startAt\":\(st),\"targetAt\":\(tg),\"closed\":\(s.closed)}"
            }
            .joined(separator: ",")
        // AI dedup queue (the "later" pile): candidates parked for one-by-one review.
        // Oldest first so the user works the backlog in arrival order.
        let aiQueue = reviewStore.aiQueue
            .map { item -> String in
                let matches = item.matches.map { m -> String in
                    "{\"seq\":\(m.seq),\"text\":\(jsonString(m.text)),\"why\":\(jsonString(m.why))}"
                }.joined(separator: ",")
                return "{\"id\":\(jsonString(item.id)),\"text\":\(jsonString(item.text)),"
                    + "\"parent\":\(jsonString(item.parent)),\"sprint\":\(item.sprint),"
                    + "\"status\":\(jsonString(item.status)),\"duplicate\":\(item.duplicate),"
                    + "\"kind\":\(jsonString(item.kind)),"
                    + "\"jobKind\":\(jsonString(item.jobKind)),\"title\":\(jsonString(item.title)),"
                    + "\"resultHTML\":\(jsonString(item.resultHTML)),\"error\":\(jsonString(item.error)),"
                    + "\"note\":\(jsonString(item.note)),\"refining\":\(!item.refineSession.isEmpty),"
                    + "\"refineSession\":\(jsonString(item.refineSession)),\"findOnly\":\(item.findOnly),"
                    // AI placement verdict (Option D) — the queue card pre-fills the promote form
                    // from these; the user can override parentSeq/priority at resolve time.
                    + "\"placement\":\(jsonString(item.placement)),\"suggestedParentSeq\":\(item.suggestedParentSeq),"
                    + "\"priority\":\(jsonString(item.priority)),\"confidence\":\(item.confidence),"
                    + "\"rationale\":\(jsonString(item.rationale)),\"relation\":\(jsonString(item.relation)),"
                    + "\"matches\":[\(matches)],\"createdAt\":\(item.createdAt.timeIntervalSince1970)}"
            }
            .joined(separator: ",")
        // 큐 처리 히스토리 (newest first, last 30): what each resolution did — so the 큐 탭 can
        // show the audit trail, link to the created goal/task, and offer 번복 (undo).
        let queueHistory = reviewStore.queueHistory.suffix(30).reversed()
            .map { h -> String in
                // qid = the resolved QUEUE item's id (from the restore snapshot; "" for edit
                // entries) — lets the goal-add tally match its AI 큐 rows to their resolution.
                "{\"id\":\(jsonString(h.id)),\"qid\":\(jsonString(h.item?.id ?? "")),\"at\":\(h.at.timeIntervalSince1970),"
                    + "\"action\":\(jsonString(h.action)),\"text\":\(jsonString(h.text)),"
                    + "\"seq\":\(h.seq),\"parentSeq\":\(h.parentSeq),\"task\":\(jsonString(h.taskFolder)),"
                    + "\"fallback\":\(h.fallback),\"undone\":\(h.undone)}"
            }
            .joined(separator: ",")
        let contribs = r.contributions
            .map { "\(jsonString($0.key)):\($0.value)" }
            .joined(separator: ",")
        let notes = r.notes
            .map { "\(jsonString($0.key)):\(jsonString($0.value))" }
            .joined(separator: ",")
        func optInt(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        // 부모# 지원 데이터: 자동 부모 추천(회색 고스트 번호)과 최근 사용한 부모(드롭다운 '최근 사용').
        let psug = psugJSON()
        let recentParents = Settings.shared.recentParentSeqs.map(String.init).joined(separator: ",")
        return "{\"goals\":[\(goals)],\"releases\":[\(releases)],\"sprints\":[\(sprints)],"
            + "\"aiQueue\":[\(aiQueue)],\"queueHistory\":[\(queueHistory)],"
            + "\"psug\":\(psug),\"recentParents\":[\(recentParents)],"
            + "\"selfScore\":\(optInt(r.selfScore)),\"submittedSelf\":\(r.submittedSelf),"
            + "\"contributions\":{\(contribs)},\"notes\":{\(notes)},"
            + "\"aiScore\":\(optInt(r.aiScore)),\"aiNote\":\(jsonString(r.aiNote)),"
            + "\"adminScore\":\(optInt(r.adminScore))}"
    }

    // Loop worklist: the queue an external auto-loop pulls from. Eligibility mirrors
    // ReviewStore.validStatuses semantics — ONLY backlog (대기) leaf goals are returned;
    // in_progress/waiting/stopped/cancelled/done are all excluded, so the loop can never
    // restart a held (중지) or abandoned (취소) goal. Parents are skipped (they roll up from
    // children and aren't executable units). Ordered by seq so the loop honors priority.
    // See .doc/loop-status-design.md.
    private func loopQueueJSON() -> String {
        let all = reviewStore.goals
        let parentIDs = Set(all.compactMap { $0.parent.isEmpty ? nil : $0.parent })
        let eligible = all
            .filter { $0.status == "backlog" && !parentIDs.contains($0.id) }
            .sorted { $0.seq < $1.seq }
        let queue = eligible
            .map { g -> String in
                let agents = g.agents.map { jsonString($0) }.joined(separator: ",")
                return "{\"id\":\(jsonString(g.id)),\"seq\":\(g.seq),\"text\":\(jsonString(g.text)),"
                    + "\"sessionId\":\(jsonString(g.sessionId)),\"transcriptPath\":\(jsonString(g.transcriptPath)),"
                    + "\"energy\":\(g.energy),\"agents\":[\(agents)],\"trackedSeconds\":\(g.trackedSeconds)}"
            }
            .joined(separator: ",")
        return "{\"queue\":[\(queue)],\"count\":\(eligible.count)}"
    }

    // POST router (runs on the server queue; mutations hop to main for safety).
    // ===== 스킬 목록 (rail의 "스킬" 메뉴) =====
    // The user's skills live in ~/.claude/skills; each subfolder holding a SKILL.md is
    // one skill. We surface name / last-updated / author for the rail's skills overlay so
    // the user can see what's installed without memorizing folder names.
    // Default ".claude" root under the home dir when the user has not configured one.
    private var skillsRootDefault: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }
    // Configurable base ".claude" folder (set on the skills page). Falls back to ~/.claude.
    // Skills are read from its /skills subfolder, so the on-disk layout is unchanged.
    private var skillsRoot: URL {
        let s = (Settings.shared.skillsRoot ?? "").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return skillsRootDefault }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
    }
    private var skillsDir: URL {
        skillsRoot.appendingPathComponent("skills", isDirectory: true)
    }

    // Path to the append-only skill-usage log the PostToolUse hook (cc-skill-hook.sh) writes.
    // One JSONL line per skill invocation: {epoch, ts, skill, session, cwd}. This file IS
    // the history surfaced on the skills page.
    private var skillUsageLog: URL {
        AppPaths.base.appendingPathComponent("skill-usage.jsonl", isDirectory: false)
    }

    // Read + parse the usage log into events (newest LAST, i.e. file order). Each event is a
    // dict with epoch/ts/skill/session/cwd. Malformed lines are skipped. Returns [] when the
    // log does not exist yet (no skill has ever run).
    private func skillUsageEvents() -> [[String: Any]] {
        guard let text = try? String(contentsOf: skillUsageLog, encoding: .utf8) else { return [] }
        var out: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let skill = obj["skill"] as? String, !skill.isEmpty else { continue }
            out.append(obj)
        }
        return out
    }

    // Aggregate the usage log per skill slug (lowercased) -> (count, lastEpoch). Used to
    // stamp each skill row with its use count and last-used time.
    private func skillUsageAgg() -> [String: (count: Int, lastEpoch: Double)] {
        var agg: [String: (count: Int, lastEpoch: Double)] = [:]
        for ev in skillUsageEvents() {
            guard let slug = (ev["skill"] as? String)?.lowercased(), !slug.isEmpty else { continue }
            let epoch = (ev["epoch"] as? Double) ?? Double((ev["epoch"] as? Int) ?? 0)
            let prev = agg[slug] ?? (0, 0)
            agg[slug] = (prev.count + 1, max(prev.lastEpoch, epoch))
        }
        return agg
    }

    func skillsJSON() -> String {
        let fm = FileManager.default
        let dir = skillsDir
        let usage = skillUsageAgg()
        var items: [[String: Any]] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                   options: [.skipsHiddenFiles])) ?? []
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let skillMd = url.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillMd.path) else { continue }   // a skill must have SKILL.md
            let text = (try? String(contentsOf: skillMd, encoding: .utf8)) ?? ""
            let meta = Self.parseSkillFrontmatter(text, fallbackName: url.lastPathComponent)
            // The one-line summary the user sees/edits: an explicit `summary:` field if
            // present, otherwise the first sentence of the (long) triggering description.
            let summary = meta.summary.isEmpty ? Self.firstSentence(meta.desc) : meta.summary
            // "Updated" = the more recent of the folder and its SKILL.md, so edits to the
            // manifest OR any bundled file both bump the date the user sees.
            let dMod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let mMod = (try? skillMd.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let updated = max(dMod, mMod)
            // Merge usage stats. The hook records ONE slug per event; for user skills it is
            // usually the folder name, but match on the frontmatter `name:` too so either
            // form is counted. Union the candidate keys (they collapse when equal), summing
            // counts and taking the latest use.
            var useCount = 0
            var lastEpoch = 0.0
            var seenKeys = Set<String>()
            for key in [meta.name.lowercased(), url.lastPathComponent.lowercased()] where !key.isEmpty {
                guard seenKeys.insert(key).inserted, let u = usage[key] else { continue }
                useCount += u.count
                lastEpoch = max(lastEpoch, u.lastEpoch)
            }
            let lastUsed = lastEpoch > 0 ? Self.koShortDate(Date(timeIntervalSince1970: lastEpoch)) : ""
            items.append([
                "name": meta.name,
                "folder": url.lastPathComponent,
                "desc": meta.desc,
                "summary": summary,
                "hasSummary": !meta.summary.isEmpty,
                "author": meta.author,
                "updated": Self.koShortDate(updated),
                "updatedTs": updated.timeIntervalSince1970,
                "useCount": useCount,
                "lastUsed": lastUsed,
                "lastUsedTs": lastEpoch,
            ])
        }
        items.sort { (($0["updatedTs"] as? Double) ?? 0) > (($1["updatedTs"] as? Double) ?? 0) }
        // `root` is the configurable ".claude" folder; `dir` is its /skills subfolder actually
        // scanned. The skills page shows `root` (editable) and lists from `dir`.
        let payload: [String: Any] = ["dir": dir.path, "root": skillsRoot.path,
                                      "isDefault": Settings.shared.skillsRoot?.isEmpty ?? true,
                                      "skills": items]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // Read-only feed for the 에이전트 page. Surfaces every skill that follows the
    // "responsible agent" convention — a skill folder with an agent/ subfolder holding
    // agent/ACTIVE (current version) and agent/vN-*.md (version history), plus ledger/*.jsonl
    // run records. For each we compute: active version, per-version success (the retrospective
    // arc that shows why a version was replaced), overall purpose-achievement rate, and a
    // recent run timeline — so the user sees when the agent ran, whether it met its purpose,
    // and when it needs replacing.
    func agentsJSON() -> String {
        let fm = FileManager.default
        let agentsDir = skillsRoot.appendingPathComponent("agents", isDirectory: true)
        var items: [[String: Any]] = []
        var history = loadAgentHistory()
        var historyDirty = false
        let isoFmt = ISO8601DateFormatter()
        // Universal ledger of agent actions (keyed by "agent"); grouped per agent below into
        // the 기능 역할 (function-role) tab so the user sees which roles each agent performs,
        // how often, and — where recorded — how cleanly (rounds).
        let updateLog = loadAgentUpdateLog()
        let entries = (try? fm.contentsOfDirectory(at: agentsDir, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        for url in entries where url.pathExtension == "md" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let front = Self.parseFrontmatter(text)
            let name = front["name"] ?? url.deletingPathExtension().lastPathComponent
            let desc = front["description"] ?? ""
            let model = front["model"] ?? "inherit"
            let harness = front["harness"] ?? ""

            // Modification history: ~/.claude/agents isn't git-tracked, so we snapshot each
            // revision (keyed by a launch-stable content hash) stamped with the file's mtime.
            // A new snapshot is recorded only when the file content actually changed, and each
            // one carries the purpose (description) as it read then — so the user can see how
            // the stated purpose evolved and whether an edit reflected the intended goal.
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let sig = Self.stableHash(text)
            var hist = history[url.lastPathComponent] ?? []
            if (hist.last?["sig"] as? String) != sig {
                let snippet = desc.count > 200 ? String(desc.prefix(200)) + "…" : desc
                hist.append(["ts": isoFmt.string(from: mtime), "model": model, "desc": snippet, "sig": sig])
                if hist.count > 20 { hist = Array(hist.suffix(20)) }
                history[url.lastPathComponent] = hist
                historyDirty = true
            }
            let clientHist: [[String: Any]] = hist.map {
                ["ts": $0["ts"] ?? "", "model": $0["model"] ?? "", "desc": $0["desc"] ?? ""]
            }

            // Join run history + retrospective from the harness skill this agent belongs to
            // (declared via the agent's custom `harness:` frontmatter field).
            let stats = agentRunStats(name: name, harness: harness, updateLog: updateLog)
            var row: [String: Any] = stats
            row["name"] = name
            row["file"] = url.lastPathComponent
            row["desc"] = desc
            row["model"] = model
            row["harness"] = harness
            row["history"] = clientHist
            items.append(row)
        }
        items.sort { (($0["runs"] as? Int) ?? 0) > (($1["runs"] as? Int) ?? 0) }
        if historyDirty { saveAgentHistory(history) }
        let payload: [String: Any] = ["dir": agentsDir.path, "root": skillsRoot.path, "agents": items]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // 에이전트 페이지(/agents)의 단일 피드 — 전역·스킬 하네스·프로젝트에 흩어진 에이전트 정의를
    // 스코프별로 묶어 한 번에 내려보낸다. 각 에이전트에는 세 가지가 함께 실린다:
    //   (a) 정의 자체 — 목적(description)·모델·도구·마지막 수정 시각
    //   (b) 실행 성적 — 원장에서 계산한 실행 횟수/성공률/기능 역할 (agentRunStats)
    //   (c) 사람의 판정 — 목적 달성 / 교체 필요 + 사유 (AgentVerdicts)
    // 셋이 같이 보여야 "어떤 에이전트를 교체할 것인가"를 근거로 결정할 수 있다. 성공률이 100%인데
    // 결과물이 쓸모없는 경우가 있기 때문에 (c) 를 따로 둔다.
    func agentInventoryJSON() -> String {
        let updateLog = loadAgentUpdateLog()
        let verdicts = AgentVerdicts.load()
        var scopes = AgentInventory.scopes(globalRoot: skillsRoot, extraRoots: goalCwdRoots())
        var total = 0, needReplace = 0, projectCount = 0, ranCount = 0
        for i in scopes.indices {
            var agents = (scopes[i]["agents"] as? [[String: Any]]) ?? []
            for j in agents.indices {
                let name = (agents[j]["name"] as? String) ?? ""
                let harness = (agents[j]["harness"] as? String) ?? ""
                for (k, v) in agentRunStats(name: name, harness: harness, updateLog: updateLog) {
                    agents[j][k] = v
                }
                if ((agents[j]["runs"] as? Int) ?? 0) > 0 { ranCount += 1 }
                if let path = agents[j]["path"] as? String, let vd = verdicts[path] {
                    agents[j]["verdict"] = vd
                    if (vd["state"] as? String) == "replace" { needReplace += 1 }
                }
            }
            // 교체 필요 → 실행 기록 많은 순 → 이름. 손볼 것이 늘 맨 위에 온다.
            agents.sort { a, b in
                let ra = ((a["verdict"] as? [String: Any])?["state"] as? String) == "replace"
                let rb = ((b["verdict"] as? [String: Any])?["state"] as? String) == "replace"
                if ra != rb { return ra }
                let na = (a["runs"] as? Int) ?? 0, nb = (b["runs"] as? Int) ?? 0
                if na != nb { return na > nb }
                return ((a["name"] as? String) ?? "") < ((b["name"] as? String) ?? "")
            }
            scopes[i]["agents"] = agents
            total += agents.count
            if (scopes[i]["kind"] as? String) == "project" { projectCount += 1 }
        }
        var totals: [String: Any] = [:]
        totals["agents"] = total
        totals["projects"] = projectCount
        totals["scopes"] = scopes.count
        totals["replace"] = needReplace
        totals["ran"] = ranCount
        var payload: [String: Any] = [:]
        payload["root"] = skillsRoot.path
        payload["globalDir"] = skillsRoot.appendingPathComponent("agents", isDirectory: true).path
        payload["scopes"] = scopes
        payload["totals"] = totals
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // 루프 엔지니어링 페이지(/loop-engineering)의 단일 피드 — "프로젝트별로 어떤 라우트가 실제로
    // 돌았고, 어디서 막히는가"를 디스크 증거만으로 세운다.
    //
    // 화면이 우선순위대로 답해야 하는 질문은 셋이다:
    //   1. 이 프로젝트에 어떤 라우트가 있는가      → 정의된 파트 + 트랜스크립트에서 재구성한 위임
    //   2. 그 라우트가 실제로 돌고 끝났는가        → 실행 횟수 / 완료 / 끊김 / 결과 없음
    //   3. 병목은 어디이고 얼마짜리인가            → 아래 사다리 순서로 하나를 지목하고 숫자를 붙인다
    //
    // 병목을 찾는 순서는 고정이다(자주 답인 순서다): 핸드오프 → 진입점 → 종료 조건 → 파트 자체.
    // 다만 존재하지 않는 파트로의 위임('끊긴 홉')은 라우트가 시작조차 못 한 것이라 사다리보다 앞선다.
    // 2026-08-23 정정: 핸드오프의 내부 기록은 측정할 수 있다. `subagents/` 아래에 받은 쪽
    // 트랜스크립트가 남고, LoopScan 이 그것을 읽어 내부 턴·도구 호출·벽시계 시간을 돌려준다.
    // 여전히 못 재는 것은 그 내부 도구 호출 중 몇 번이 "앞 홉이 이미 알던 것을 다시 캔 것"인지의
    // 판정이다. 측정할 수 없는 것을 추측으로 채우지 않고, 못 잰다고 화면에 적는다.
    func loopEngineeringJSON() -> String {
        let extra = goalCwdRoots()
        let roots = AgentInventory.discoveredProjects(extraRoots: extra)
        let scopes = AgentInventory.scopes(globalRoot: skillsRoot, extraRoots: extra)
        let scanned = LoopScan.scan()
        let hops = scanned.hops
        let inner = scanned.inner
        let bn = scanned.bottleneck
        let updateLog = loadAgentUpdateLog()
        let nowISO = ISO8601DateFormatter().string(from: Date())

        // 프로젝트 스코프에 정의된 파트(에이전트) — 경로로 묶는다.
        var partsByRoot: [String: [[String: Any]]] = [:]
        for sc in scopes where (sc["kind"] as? String) == "project" {
            guard let p = sc["path"] as? String else { continue }
            partsByRoot[p] = (sc["agents"] as? [[String: Any]]) ?? []
        }
        // 어디서든 부를 수 있는 파트 — 전역과 스킬 하네스. 프로젝트 라우트가 이 이름을 쓰면
        // '정의 있음'으로 친다(그 프로젝트 폴더에 없다고 해서 이름 없는 파트가 아니다).
        var sharedParts: [String: String] = [:]   // 이름 → 스코프 표시
        for sc in scopes where (sc["kind"] as? String) != "project" {
            let label = (sc["kind"] as? String) == "global" ? "전역" : "스킬 " + ((sc["name"] as? String) ?? "")
            for a in (sc["agents"] as? [[String: Any]]) ?? [] {
                if let n = a["name"] as? String { sharedParts[n] = label }
            }
        }

        // cwd → 프로젝트 루트.
        //
        // 에이전트 정의를 가진 폴더만 프로젝트로 치면 프로젝트별 화면이 무너진다: 워크스페이스 루트
        // (departtment_service)가 .claude/agents 를 하나 갖고 있다는 이유로 그 아래 저장소 전부의
        // 위임을 빨아들여, MPC·condition-manager·metastarglobal 이 한 덩어리 53건으로 뭉쳤다.
        // 그래서 위임이 일어난 cwd 마다 가장 가까운 .git 조상(= 사람이 "프로젝트"라고 부르는 단위)을
        // 후보에 함께 넣고, 그중 가장 긴 접두사가 이기게 한다 — 중첩 저장소에서 안쪽이 이겨야 한다.
        //
        // 홈 폴더는 프로젝트가 아니다. ~/.claude/agents 가 있다는 이유로 후보에 들어오면 전역 스코프가
        // 프로젝트로 둔갑하고, 홈 아래 아무 폴더에서 건 위임이 전부 거기 붙는다.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let fmgr = FileManager.default
        var repoCache: [String: String] = [:]
        func repoRoot(of cwd: String) -> String? {
            if let hit = repoCache[cwd] { return hit.isEmpty ? nil : hit }
            var u = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
            var found = ""
            while u.path.count > home.count, u.path.hasPrefix(home + "/") {
                if fmgr.fileExists(atPath: u.appendingPathComponent(".git").path) { found = u.path; break }
                u = u.deletingLastPathComponent()
            }
            repoCache[cwd] = found
            return found.isEmpty ? nil : found
        }

        var candidates = Set(roots.map { $0.path }.filter { $0 != home })
        for h in hops where !h.cwd.isEmpty {
            if let r = repoRoot(of: h.cwd) { candidates.insert(r) }
        }
        let sortedRoots = candidates.sorted { $0.count > $1.count }
        func rootOf(_ cwd: String) -> String? {
            for r in sortedRoots where cwd == r || cwd.hasPrefix(r + "/") { return r }
            return nil
        }

        // 위임 한 건이 어느 프로젝트의 것인가.
        //
        // 작업 폴더가 아직 있으면 가장 구체적인 조상(.git 저장소 → 그다음 발견된 프로젝트 루트)에 붙인다.
        // 폴더가 이미 사라졌으면 조상에 붙이지 않는다 — 저장소를 재편하면서 projects/MPC,
        // projects/condition-manager 같은 폴더가 org-*/ 아래로 옮겨졌는데, 그 이력을 워크스페이스
        // 루트에 몰아 주면 서로 다른 프로젝트 53건이 한 덩어리가 되어 정작 "프로젝트별"이 사라진다.
        // 그래서 사라진 폴더는 자기 이름으로 남기고 화면에 그렇다고 적는다.
        var missingCwds = Set<String>()
        func bucket(_ cwd: String) -> String {
            if !fmgr.fileExists(atPath: cwd) { missingCwds.insert(cwd); return cwd }
            return repoRoot(of: cwd) ?? rootOf(cwd) ?? cwd
        }

        // 어느 프로젝트 스코프에든 정의가 있는 파트의 이름 — "이 저장소에 없다"와 "이 맥 어디에도
        // 없다"는 다른 말이고, 둘을 섞으면 멀쩡히 돌아간 파트에 없는 결함을 씌우게 된다.
        var definedAnywhere = Set(sharedParts.keys)
        var defMtime: [String: String] = [:]
        for sc in scopes {
            for a in (sc["agents"] as? [[String: Any]]) ?? [] {
                guard let n = a["name"] as? String else { continue }
                definedAnywhere.insert(n)
                let m = (a["mtime"] as? String) ?? ""
                if let prev = defMtime[n], prev >= m { continue }
                defMtime[n] = m
            }
        }

        // 예약 워커 — 저장소가 소유한 plist 가 실제로 launchd 에 걸려 있는지. 커밋만 되고
        // 설치되지 않은 워커는 '사람 없이 시작되는 진입점'이 없는 것과 같다.
        let jobs = DeviceCronScanner.shared.jobsSnapshot()
        var loadedByLabel: [String: (loaded: Bool, pid: Int, exit: Int)] = [:]
        for j in jobs { loadedByLabel[j.label] = (j.loaded, j.pid, j.lastExit) }

        // 팀 — 하나의 작업 목록을 나눠 갖는 팀원들. cwd 로 프로젝트에 붙인다.
        var teamsByRoot: [String: [[String: Any]]] = [:]
        var teamsTotal = 0, teamsWithMates = 0
        for t in Self.scanTeams() {
            teamsTotal += 1
            if ((t["members"] as? Int) ?? 0) > 1 { teamsWithMates += 1 }
            let cwd = (t["cwd"] as? String) ?? ""
            let key = cwd.isEmpty ? "" : bucket(cwd)
            if key.isEmpty { continue }
            teamsByRoot[key, default: []].append(t)
        }

        // 위임 홉을 프로젝트별·에이전트별로 접는다.
        struct Acc {
            var runs = 0, done = 0, async = 0, dead = 0, open = 0
            var sumSec = 0.0, maxSec = 0.0
            var lastTs = "", sample = "", deadTs = ""
            var promptSum = 0
            var nested = 0          // 에이전트가 다시 부른 위임
            var joined = 0          // 받은 쪽 트랜스크립트를 찾은 위임
            var innerTurns = 0, innerTools = 0
        }
        var accByRoot: [String: [String: Acc]] = [:]
        var outsideKeys = Set<String>()
        for h in hops {
            if h.cwd.isEmpty { continue }
            let key = bucket(h.cwd)
            if !candidates.contains(key) { outsideKeys.insert(key) }
            var m = accByRoot[key] ?? [:]
            var a = m[h.agent] ?? Acc()
            a.runs += 1
            a.promptSum += h.promptBytes
            if h.depth >= 2 { a.nested += 1 }
            if h.joined { a.joined += 1; a.innerTurns += h.innerTurns; a.innerTools += h.innerTools }
            switch h.kind {
            case "done": a.done += 1
            case "async": a.async += 1
            case "dead":
                a.dead += 1
                if h.ts > a.deadTs { a.deadTs = h.ts }
            default: a.open += 1
            }
            // 시간은 끝맺음 종류가 아니라 "잰 값이 있는가"로 더한다. 확장 전에는 done 만 더했고,
            // 그래서 백그라운드로 띄운 위임 절반이 합계에서 통째로 빠져 있었다. 이제 그 홉들도
            // 받은 쪽 트랜스크립트의 벽시계 시간을 들고 온다(LoopScan.Hop.timeSource 참조).
            if h.seconds >= 0 { a.sumSec += h.seconds; a.maxSec = max(a.maxSec, h.seconds) }
            if h.ts > a.lastTs { a.lastTs = h.ts; a.sample = h.desc }
            m[h.agent] = a
            accByRoot[key] = m
        }

        // 화면에 실을 프로젝트 = 발견된 저장소 + 위임이 일어난 저장소 밖 폴더.
        var keys = candidates
        keys.formUnion(accByRoot.keys)
        keys.formUnion(teamsByRoot.keys)

        var projects: [[String: Any]] = []
        // "지금 열려 있는 대기" — 성격이 다른 세 종류를 한 표에 모은다. 나누면 표가 셋이 되고
        // 첫 화면이 다시 읽고 판단해야 하는 화면이 된다. 대신 행마다 종류를 적는다.
        var openWaits: [[String: Any]] = []
        var tRoutes = 0, tRuns = 0, tDead = 0, tUnused = 0, tSec = 0.0
        for key in keys {
            let known = candidates.contains(key)
            let gone = missingCwds.contains(key)
            let parts = partsByRoot[key] ?? []
            let acc = accByRoot[key] ?? [:]
            let teams = teamsByRoot[key] ?? []
            let workers = known ? Self.projectWorkers(root: key, loaded: loadedByLabel) : []
            // 아무 흔적도 없는 저장소는 싣지 않는다 — 목록을 채우는 것이 목적이 아니다.
            if parts.isEmpty && acc.isEmpty && teams.isEmpty && workers.isEmpty { continue }

            let projSum = acc.values.reduce(0.0) { $0 + $1.sumSec }
            var routes: [[String: Any]] = []
            for (agent, a) in acc {
                // 파트의 출처 표시. 실제로 돌아간 홉을 "정의 없음"으로 적지 않는다 — 돌았다면
                // 그 시점에 런타임이 그 이름을 알고 있었다는 뜻이고(내장 파트일 수도 있다),
                // 정의 파일을 못 찾은 것은 우리 스캔의 한계지 그 라우트의 결함이 아니다.
                // '정의 없음'은 실제로 끊긴 홉에만 붙인다.
                let inProject = parts.contains { ($0["name"] as? String) == agent }
                let ran = a.done > 0 || a.async > 0
                let defined = inProject || sharedParts[agent] != nil || definedAnywhere.contains(agent) || ran
                let scopeLabel: String
                if inProject { scopeLabel = "프로젝트" }
                else if let sh = sharedParts[agent] { scopeLabel = sh }
                else if definedAnywhere.contains(agent) { scopeLabel = "다른 프로젝트" }
                else if a.dead > 0 { scopeLabel = "정의 없음" }
                else if ran { scopeLabel = "런타임" }   // 돌았지만 정의 파일은 못 찾음(내장 파트일 수 있다)
                else { scopeLabel = "" }
                var r: [String: Any] = [:]
                r["agent"] = agent
                r["runs"] = a.runs; r["done"] = a.done; r["async"] = a.async
                r["dead"] = a.dead; r["open"] = a.open
                r["sumSec"] = Int(a.sumSec.rounded()); r["maxSec"] = Int(a.maxSec.rounded())
                r["share"] = projSum > 0 ? Int((a.sumSec / projSum * 100).rounded()) : 0
                r["lastTs"] = a.lastTs; r["sample"] = a.sample
                r["nested"] = a.nested; r["joined"] = a.joined
                r["innerTurns"] = a.innerTurns; r["innerTools"] = a.innerTools
                r["defined"] = defined || sharedParts[agent] != nil
                r["scope"] = scopeLabel
                r["avgPromptKB"] = a.runs > 0 ? Int((Double(a.promptSum) / Double(a.runs) / 1024).rounded()) : 0
                // 실행 성적은 원장을 아는 한 곳(agentRunStats)에서만 계산한다 — 에이전트 페이지와
                // 이 화면이 다른 숫자를 말하면 둘 다 못 믿게 된다.
                let harness = (parts.first { ($0["name"] as? String) == agent }?["harness"] as? String) ?? ""
                let stats = agentRunStats(name: agent, harness: harness, updateLog: updateLog)
                r["ledgerRuns"] = stats["runs"] ?? 0
                routes.append(r)
            }
            routes.sort { (($0["sumSec"] as? Int) ?? 0, ($0["runs"] as? Int) ?? 0)
                       > (($1["sumSec"] as? Int) ?? 0, ($1["runs"] as? Int) ?? 0) }

            let unused = parts.compactMap { $0["name"] as? String }.filter { acc[$0] == nil }.sorted()
            let deadCount = acc.values.reduce(0) { $0 + $1.dead }
            let openCount = acc.values.reduce(0) { $0 + $1.open }
            let runCount = acc.values.reduce(0) { $0 + $1.runs }
            let idleWorkers = workers.filter { ($0["loaded"] as? Bool) != true }

            // 대기 큐 재료 ① 끊긴 홉. 체류는 "끊긴 뒤로 지난 시간"이다 — 끊긴 홉은 스스로 낫지
            // 않으므로 그 시간이 곧 방치된 시간이다. 임계 1시간은 "알아채고 세션을 새로 열
            // 만한 시간"이고, 실제로는 대부분 며칠씩 지나 있어 STALLED 로 뜬다.
            for (agentName, a) in acc where a.dead > 0 {
                let age = a.deadTs.isEmpty ? -1.0
                    : Double(Self.secondsBetween(from: a.deadTs, to: nowISO))
                openWaits.append([
                    "kind": "dead", "kindLabel": "끊긴 홉", "owner": "워커",
                    "title": agentName,
                    "where": known ? AgentInventory.label(for: URL(fileURLWithPath: key))
                                   : URL(fileURLWithPath: key).lastPathComponent,
                    "note": "런타임이 이 이름을 모른다고 답했습니다 — \(a.dead)번. 정의 파일이 그때 이미 있었다면 파일이 아니라 세션을 새로 열어야 잡힙니다",
                    "dwellSec": age, "thresholdSec": 3600,
                    "stalled": age >= 3600,
                    "actions": [["label": "세션 새로 열기", "act": "hint-dead"]],
                ])
            }
            // 대기 큐 재료 ② 미등록 예약 워커. 사람 없이 라우트를 시작하는 유일한 부품이라,
            // 안 걸려 있으면 그 라우트에는 진입점이 없다. 체류는 plist 파일이 마지막으로
            // 저장된 뒤로 지난 시간이다 — 실제로 기록된 유일한 시각이고, 없으면 "기록 없음".
            for w in idleWorkers {
                let p = (w["path"] as? String) ?? ""
                var age = -1.0
                if !p.isEmpty,
                   let m = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate]) as? Date {
                    age = Date().timeIntervalSince(m)
                }
                openWaits.append([
                    "kind": "worker", "kindLabel": "미등록 워커", "owner": "진입점",
                    "title": (w["label"] as? String) ?? "",
                    "where": known ? AgentInventory.label(for: URL(fileURLWithPath: key))
                                   : URL(fileURLWithPath: key).lastPathComponent,
                    "note": "저장소에는 plist 가 있는데 launchd 에 걸려 있지 않습니다 — 사람 없이 시작하는 부품이 없는 것과 같습니다",
                    "dwellSec": age, "thresholdSec": 86400,
                    "stalled": age >= 86400,
                    "path": p,
                    "actions": [["label": "등록 방법 보기", "act": "hint-worker"]],
                ])
            }

            // 병목 사다리 — 끊긴 홉 → 진입점 → 종료 조건 → 파트 자체. 하나만 지목하고 숫자를 붙인다.
            var verdict: [String: Any] = [:]
            if deadCount > 0 {
                let deadRoutes = acc.filter { $0.value.dead > 0 }
                let names = deadRoutes.keys.sorted().joined(separator: ", ")
                // 끊긴 홉은 두 가지가 섞여 있고, 고치는 방법이 서로 다르다.
                //   (a) 부를 때 정의가 아직 없었다              → 파트를 먼저 만들어야 한다
                //   (b) 정의는 이미 디스크에 있었는데도 실패했다 → 세션이 시작할 때 읽은 파트 목록에
                //       그 이름이 없었던 것이다. 파일을 더 고칠 게 아니라 세션을 새로 열어야 한다.
                // 실측 5건 중 4건이 (b)였고, 정의가 저장된 지 26~79초 만에 부른 것들이었다. 둘을
                // 구분해 주지 않으면 이미 만들어 둔 파트를 또 만들게 된다.
                var staleLead = -1
                for (agentName, a) in deadRoutes {
                    guard let m = defMtime[agentName], !m.isEmpty, !a.deadTs.isEmpty else { continue }
                    let gap = Self.secondsBetween(from: m, to: a.deadTs)
                    if gap > 0 { staleLead = max(staleLead, gap) }
                }
                var text = "존재하지 않는 파트로 \(deadCount)번 위임했고 그때마다 라우트가 시작조차 못 했습니다 — \(names)"
                if staleLead >= 0 {
                    text += ". 정의 파일은 그때 이미 디스크에 있었습니다(가장 늦게 저장된 것도 위임 \(staleLead)초 전) — 세션이 시작할 때 읽은 파트 목록에 없었던 것이라, 파일을 더 고칠 게 아니라 세션을 새로 열어야 잡힙니다"
                }
                verdict = ["cat": "끊긴 홉", "num": deadCount, "text": text]
            } else if !unused.isEmpty {
                let pct = parts.isEmpty ? 0 : Int((Double(parts.count - unused.count) / Double(parts.count) * 100).rounded())
                verdict = ["cat": "진입점", "num": unused.count,
                           "text": "정의된 파트 \(parts.count)개 중 \(unused.count)개가 한 번도 호출되지 않았습니다 (호출률 \(pct)%) — \(unused.prefix(4).joined(separator: ", "))"]
            } else if !idleWorkers.isEmpty {
                let names = idleWorkers.compactMap { $0["label"] as? String }.joined(separator: ", ")
                verdict = ["cat": "진입점", "num": idleWorkers.count,
                           "text": "저장소가 소유한 예약 워커 \(idleWorkers.count)개가 launchd 에 걸려 있지 않습니다 — \(names)"]
            } else if openCount > 0 {
                verdict = ["cat": "종료 조건", "num": openCount,
                           "text": "\(openCount)번의 위임이 결과를 돌려받은 기록 없이 끝났습니다 — 무엇이 완료인지 라우트가 말하지 않습니다"]
            } else if let top = routes.first, ((top["sumSec"] as? Int) ?? 0) > 0 {
                let share = (top["share"] as? Int) ?? 0
                let name = (top["agent"] as? String) ?? ""
                verdict = ["cat": "파트", "num": share,
                           "text": "총 위임 시간 \(Int(projSum.rounded()))초 중 \(top["sumSec"] as? Int ?? 0)초(\(share)%)를 \(name) 한 파트가 붙들고 있습니다"]
            } else if runCount > 0 {
                // 위임은 있었는데 잴 수 있는 시간이 한 톨도 없다 = 전부 백그라운드로 띄운 위임이다.
                // "라우트가 없다"고 적으면 바로 아래 줄에 보이는 실행 기록과 어긋난다.
                verdict = ["cat": "측정 불가", "num": runCount,
                           "text": "위임 \(runCount)회가 모두 백그라운드 실행이라, 각 홉이 얼마나 붙들었는지 잴 수 있는 기록이 남지 않았습니다"]
            } else {
                verdict = ["cat": "없음", "num": 0, "text": "이 프로젝트에서 실행된 라우트가 없습니다"]
            }

            var p: [String: Any] = [:]
            p["name"] = known ? AgentInventory.label(for: URL(fileURLWithPath: key)) : URL(fileURLWithPath: key).lastPathComponent
            p["path"] = key
            p["known"] = known
            p["gone"] = gone
            p["parts"] = parts.count
            p["partNames"] = parts.compactMap { $0["name"] as? String }
            p["unused"] = unused
            p["routes"] = routes
            p["runs"] = runCount
            p["dead"] = deadCount
            p["open"] = openCount
            p["sumSec"] = Int(projSum.rounded())
            p["workers"] = workers
            p["teams"] = teams
            p["verdict"] = verdict
            projects.append(p)

            tRoutes += routes.count; tRuns += runCount; tDead += deadCount
            tUnused += unused.count; tSec += projSum
        }
        // 손볼 것이 위로 온다: 끊긴 홉 → 실행량 → 이름.
        projects.sort { a, b in
            let da = (a["dead"] as? Int) ?? 0, db = (b["dead"] as? Int) ?? 0
            if da != db { return da > db }
            let ra = (a["runs"] as? Int) ?? 0, rb = (b["runs"] as? Int) ?? 0
            if ra != rb { return ra > rb }
            return ((a["name"] as? String) ?? "") < ((b["name"] as? String) ?? "")
        }

        // 스킬 하네스 — 프로젝트를 가로지르는 라우트다. 원장이 곧 실행 기록이다.
        var harness: [[String: Any]] = []
        for sc in scopes where (sc["kind"] as? String) == "skill" {
            let name = (sc["name"] as? String) ?? ""
            let agents = (sc["agents"] as? [[String: Any]]) ?? []
            var runs = 0, last = ""
            for a in agents {
                let st = agentRunStats(name: (a["name"] as? String) ?? "",
                                       harness: (a["harness"] as? String) ?? name, updateLog: updateLog)
                runs += (st["runs"] as? Int) ?? 0
                let ts = (st["lastTs"] as? String) ?? ""
                if ts > last { last = ts }
            }
            harness.append(["skill": name, "agents": agents.count, "runs": runs, "lastTs": last,
                            "dir": (sc["dir"] as? String) ?? ""])
        }
        harness.sort { (($0["runs"] as? Int) ?? 0) > (($1["runs"] as? Int) ?? 0) }

        // 대기 큐 재료 ③ 사람 결정 대기. 이미 계측되어 있다 — status == "waiting" 이면
        // waitingSince 에 그 창의 시작이, waitKind 에 종류(permission/decision)가 들어 있다.
        //
        // stopped 와 cancelled 는 여기 넣지 않는다. 둘은 사용자가 손으로 쥔 보류이고, 세션 훅도
        // 되살리지 않는 상태다. 그걸 대기로 세면 사용자가 일부러 세워 둔 것을 전부 "당신이 만든
        // 병목"이라고 되돌려 주게 된다. 보관(archived)된 것도 뺀다 — 화면에서 치운 것이다.
        let waitingGoals: [ReviewStore.Goal] = DispatchQueue.main.sync {
            reviewStore.goals.filter { $0.status == "waiting" && !$0.archived }
        }
        for g in waitingGoals {
            let dwell = g.waitingSince.map { Date().timeIntervalSince($0) } ?? -1
            let kindText = g.waitKind == "permission" ? "확인 요청" : (g.waitKind == "decision" ? "의사결정 요청" : "응답 대기")
            // "막은 것" — goal 의 자식과 링크로 셀 수 있는 만큼만 센다. 사람이 손으로 적은
            // 차단 서술은 이 저장소에 없으므로 지어내지 않는다.
            let blocked = DispatchQueue.main.sync {
                reviewStore.goals.filter { $0.parent == g.id && $0.status != "done" && $0.status != "cancelled" }.count
            }
            openWaits.append([
                "kind": "human", "kindLabel": kindText, "owner": "사람",
                "title": "seq \(g.seq)  \(g.text)",
                "where": "",
                "note": blocked > 0 ? "막은 것: 하위 목표 \(blocked)건" : "막은 것: 없음",
                "dwellSec": dwell, "thresholdSec": 1800,
                "stalled": dwell >= 1800,
                "goalId": g.id, "seq": g.seq,
                "actions": [
                    ["label": "세션 열기", "act": "open-goal"],
                    ["label": "진행으로", "act": "status", "value": "in_progress"],
                    ["label": "보류", "act": "status", "value": "stopped"],
                ],
            ])
        }
        // 체류 내림차순. 잰 값이 없는 행(-1)은 맨 아래로 — 0으로 취급해 위로 올리면 "방금 생긴
        // 대기"처럼 보이는데, 실제로는 "언제부터인지 모르는 것"이다.
        openWaits.sort { a, b in
            let da = (a["dwellSec"] as? Double) ?? -1, db = (b["dwellSec"] as? Double) ?? -1
            if (da < 0) != (db < 0) { return db < 0 }
            return da > db
        }

        // 사람 병목 지수. 분자·분모·상한·창을 전부 같이 내보낸다 — 백분율만 있으면 표본이
        // 얼마나 얇은지와 어떤 정책으로 계산했는지가 숨는다(docs/loop-definition.md 5-3).
        func idx(_ waitSec: Double) -> Double {
            let w = waitSec / 3600, a = bn.agentSeconds / 3600
            guard w + a > 0 else { return 0 }
            return ((w / (w + a)) * 1000).rounded() / 10
        }
        var bottleneck: [String: Any] = [:]
        bottleneck["windowStart"] = bn.windowStart
        bottleneck["files"] = bn.files
        bottleneck["turns"] = bn.turns
        bottleneck["capHours"] = 4
        bottleneck["humanHours"] = (bn.waitCapped / 3600 * 10).rounded() / 10
        bottleneck["agentHours"] = (bn.agentSeconds / 3600 * 10).rounded() / 10
        bottleneck["totalHours"] = ((bn.waitCapped + bn.agentSeconds) / 3600 * 10).rounded() / 10
        bottleneck["index"] = idx(bn.waitCapped)
        bottleneck["indexNoCap"] = idx(bn.waitUncapped)
        bottleneck["indexHourCap"] = idx(bn.waitHour)
        bottleneck["agentFiles"] = bn.agentFiles
        // 화면이 반드시 같이 적어야 하는 한계. 문장을 서버가 들고 있는 이유는 정의 문서와 화면이
        // 어긋나지 않게 하기 위해서다 — 화면이 스스로 지어내면 두 벌이 된다.
        bottleneck["limits"] = [
            "4시간 상한은 관측이 아니라 사용자가 정한 정책입니다 — 상한 없이는 \(idx(bn.waitUncapped))%, 1시간 상한에서는 \(idx(bn.waitHour))% 입니다",
            "잠자는 시간이 대기로 잡힙니다. 사람은 상시 대기 인력이 아니고, 밤을 가로지르는 공백은 대부분 밤입니다",
            "사람이 워커 자리에서 직접 일한 시간과 결정을 기다린 시간이 분리되지 않아, 실제 '기다리게 한 시간'보다 높게 나옵니다",
            "이 지수는 루프 아홉 칸(L1..L9)을 잰 값이 아닙니다. 단계 이벤트 원장이 없어 잴 수 없고, 지금 재는 것은 세션 코퍼스 — 대화의 공백과 서브에이전트 벽시계 — 라는 대용치입니다",
            "파일 선택자는 세션 시작 시각입니다. 파일 수정 시각으로 자르면 창 밖 세션의 공백이 분자에 실려 지수가 부풀고, 그렇게 계산된 옛 값 97.0%는 폐기됐습니다",
        ]

        var totals: [String: Any] = [:]
        totals["projects"] = projects.count
        totals["routes"] = tRoutes
        totals["runs"] = tRuns
        totals["dead"] = tDead
        totals["unused"] = tUnused
        totals["hours"] = (tSec / 3600 * 10).rounded() / 10
        totals["teams"] = teamsTotal
        totals["teamsWithMates"] = teamsWithMates
        // 받은 쪽 트랜스크립트에서 나온 것들. 확장 전에는 전부 0 이었고 화면은 "0건"이라고 적었다.
        totals["innerFiles"] = inner.files
        totals["innerTurns"] = inner.turns
        totals["innerTools"] = inner.tools
        totals["innerHours"] = (inner.seconds / 3600 * 10).rounded() / 10
        totals["nested"] = inner.nested
        totals["joined"] = inner.joined
        totals["joinPct"] = hops.isEmpty ? 0 : Int((Double(inner.joined) / Double(hops.count) * 100).rounded())
        totals["hops"] = hops.count

        var payload: [String: Any] = [:]
        payload["totals"] = totals
        payload["bottleneck"] = bottleneck
        payload["openWaits"] = openWaits
        payload["projects"] = projects
        payload["harness"] = harness
        payload["scannedAt"] = nowISO
        // 추세는 조회마다가 아니라 정해진 간격으로만 한 줄 append 한다. 조회마다 적으면 원장이
        // 화면을 연 횟수의 기록이 되고, 추세선이 사용자의 클릭 습관을 그리게 된다.
        LoopHistory.appendIfDue(bottleneck: bottleneck, totals: totals)
        payload["history"] = LoopHistory.recent(3)
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // 두 ISO8601 시각의 초 차이. 정의 파일이 저장된 시각과 그 이름으로 위임한 시각을 견주는 데 쓴다.
    // 소수점 초가 붙은 형식과 안 붙은 형식이 섞여 들어오므로 이미 있는 두 파서를 그대로 쓴다.
    static func secondsBetween(from: String, to: String) -> Int {
        func d(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }
        guard let a = d(from), let b = d(to) else { return -1 }
        return Int(b.timeIntervalSince(a).rounded())
    }

    // 팀 구성 — ~/.claude/teams/session-*/config.json 과 그 팀의 작업 목록(~/.claude/tasks/<name>).
    // 팀원이 리드 하나뿐이고 작업 목록이 비어 있으면 "만들었지만 돌지 않은 팀"이다.
    private static func scanTeams() -> [[String: Any]] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/teams", isDirectory: true)
        let tasksBase = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/tasks", isDirectory: true)
        let dirs = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        var out: [[String: Any]] = []
        for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("config.json")),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let members = (o["members"] as? [[String: Any]]) ?? []
            let name = (o["name"] as? String) ?? d.lastPathComponent
            let taskDir = tasksBase.appendingPathComponent(name, isDirectory: true)
            let tasks = ((try? fm.contentsOfDirectory(at: taskDir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "json" }.count
            var row: [String: Any] = [:]
            row["name"] = name
            row["members"] = members.count
            row["tasks"] = tasks
            row["cwd"] = (members.first?["cwd"] as? String) ?? ""
            if let ms = o["createdAt"] as? Double {
                row["createdAt"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000))
            }
            out.append(row)
        }
        return out
    }

    // 저장소가 소유한 예약 워커 — 커밋된 plist 를 찾아 launchd 등록 여부와 맞춘다.
    // 사람 없이 라우트를 시작하는 유일한 부품이라, 걸려 있지 않으면 진입점이 없는 것이다.
    private static func projectWorkers(root: String,
                                       loaded: [String: (loaded: Bool, pid: Int, exit: Int)]) -> [[String: Any]] {
        let fm = FileManager.default
        let skip: Set<String> = ["node_modules", ".build", ".git", "Pods", "vendor", "dist",
                                 "build", "DerivedData", "venv", ".venv", "target", "__pycache__", ".next"]
        var found: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth > 0, found.count < 40 else { return }
            let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for s in subs.prefix(200) {
                if (try? s.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if skip.contains(s.lastPathComponent) { continue }
                    walk(s, depth: depth - 1)
                } else if s.pathExtension == "plist", s.lastPathComponent.hasPrefix("com.") {
                    found.append(s)
                }
            }
        }
        walk(URL(fileURLWithPath: root, isDirectory: true), depth: 4)
        var out: [[String: Any]] = []
        for f in found.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let label = f.deletingPathExtension().lastPathComponent
            let st = loaded[label]
            var row: [String: Any] = [:]
            row["label"] = label
            row["path"] = f.path
            row["loaded"] = st?.loaded ?? false
            row["pid"] = st?.pid ?? -1
            row["exit"] = st?.exit ?? -1
            out.append(row)
        }
        return out
    }

    // 에이전트 정의 파일을 Finder 에서 연다 — 프로젝트 에이전트는 전역 폴더 밖에 있으므로
    // 절대 경로로 받는다. 임의 파일 열람 통로가 되지 않도록 (1) .md 이고 (2) 인벤토리가 실제로
    // 스캔한 경로 집합 안에 있을 때만 연다. 목록에 없는 경로는 조용히 무시한다.
    // 위임 이슈 상세의 결과물/작업지시서를 Finder 에서 연다. 라이언이 "완료폴더가 나와야 돼
    // 결과물이 있고 그거를 누르면은 그 폴더를 볼수 있도록" 이라고 한 자리다.
    //
    // 보안 규칙은 revealAgentPath 와 같다 — (1) 절대경로이고 (2) `..` 이 없고 (3) **이번 스캔에서
    // 카드로부터 실제로 파싱해 낸 경로 집합 안에 있을 때만** 연다. 웹뷰가 준 문자열을 그대로
    // activateFileViewerSelecting 에 넘기면 대시보드가 임의 파일 열람 통로가 된다.
    // 목록 밖은 열지 않고 unknown-path 로 거절한다.
    func revealWorkQueuePath(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard p.hasPrefix("/"), !p.contains(".."), WorkQueueStore.knownRevealPaths().contains(p) else {
            return "{\"ok\":false,\"error\":\"unknown-path\"}"
        }
        // 허용 목록에 있어도 그 사이에 지워졌을 수 있다(status: done 인데 산출물이 없는 카드가
        // 실재한다). 없는 것을 열면 Finder 가 엉뚱한 창을 띄우므로 여기서 한 번 더 본다.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else {
            return "{\"ok\":false,\"error\":\"missing\"}"
        }
        let dir = isDir.boolValue
        DispatchQueue.main.async {
            let url = URL(fileURLWithPath: p)
            // 폴더와 파일이 갈린다. `activateFileViewerSelecting` 을 **폴더**에 부르면 그 폴더가
            // 열리는 게 아니라 부모에서 그 폴더가 선택된다 — 라이언이 이 버튼에 대고 한 말은
            // 위 주석의 "그 폴더를 볼수 있도록" 이고, 선택은 그 말과 다르다.
            // 파일은 지금대로 선택이 맞다. 그래야 그 파일이 어느 폴더에 있는지 같이 보인다.
            if dir { NSWorkspace.shared.open(url) }
            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        return "{\"ok\":true}"
    }

    // ── 이슈 상세의 md 팝업 (읽기 · 쓰기) ────────────────────────────────────────
    //
    // 카드가 가리키는 .md 를 Finder 로 넘기지 않고 **앱 안에서** 열어 보고 고치기 위한 자리다.
    // 라이언: "md 파일이 열리게 해줘요 … 팝업으로 띄워서 … 프리뷰가 있고 그리고 수정하기가 있어서
    // … 수정을 했으면 저장을 해야지".
    //
    // 검증은 읽기와 쓰기가 **같은 함수 하나**를 통과한다. 쓰기 쪽만 느슨하면 루프백 대시보드가
    // 임의 파일 쓰기 통로가 되고, 그것은 읽기 통로보다 훨씬 나쁘다. 통과 조건은 넷이다 —
    //   (1) 절대경로이고 `..` 이 없다 (경로 순회 차단)
    //   (2) `.md` 로 끝난다
    //   (3) revealWorkQueuePath 와 **같은 허용 목록**(이번 스캔에서 카드로부터 실제로 파싱해 낸
    //       경로 집합) 안에 있다
    //   (4) 디스크에 실재하는 **파일**이다 (폴더가 아니다)
    //
    // ASSUMPTION (L1, 갈래를 스스로 골랐다): 경계를 "큐 루트 아래" 가 아니라 "허용 목록 안" 으로
    // 잡았다. 작업지시서와 결과물 md 는 큐 루트가 아니라 목적지 폴더에 살아서, 큐 루트로 자르면
    // 라이언이 열고 싶어 하는 파일이 대부분 안 열린다. 허용 목록은 그보다 좁다 — 루트 아래
    // 전체가 아니라 카드에 실제로 적힌 경로만 들어 있기 때문이다.
    private func workQueueMarkdownPath(_ path: String) -> String? {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard p.hasPrefix("/"), !p.contains(".."), p.lowercased().hasSuffix(".md"),
              WorkQueueStore.knownRevealPaths().contains(p) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return p
    }

    // GET /api/issues/mdfile?path=… — 본문을 그대로 돌려준다. 렌더는 화면이 한다.
    func workQueueMarkdownRead(_ path: String) -> String {
        guard let p = workQueueMarkdownPath(path) else {
            return "{\"ok\":false,\"error\":\"unknown-path\"}"
        }
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"unreadable\"}"
        }
        // 팝업 하나에 부을 수 있는 상한. 큐의 md 는 대개 수 KB 이고, 상한에 걸리는 것이 있으면
        // 그것은 md 가 아니라 로그다 — 웹뷰에 통째로 부으면 화면이 선다.
        guard text.utf8.count <= 2_000_000 else {
            return "{\"ok\":false,\"error\":\"too-large\"}"
        }
        return "{\"ok\":true,\"path\":\(jsonString(p)),\"text\":\(jsonString(text))}"
    }

    // POST /api/issues/mdsave {path,text} — 그 md 파일에 실제로 쓴다. 원자적으로 갈아 끼워서
    // 쓰다 만 파일이 남지 않게 한다.
    func workQueueMarkdownWrite(path: String, text: String) -> String {
        guard let p = workQueueMarkdownPath(path) else {
            return "{\"ok\":false,\"error\":\"unknown-path\"}"
        }
        do {
            try text.write(toFile: p, atomically: true, encoding: .utf8)
        } catch {
            return "{\"ok\":false,\"error\":\(jsonString(error.localizedDescription))}"
        }
        return "{\"ok\":true,\"path\":\(jsonString(p)),\"bytes\":\(text.utf8.count)}"
    }

    // ── 세션 기록 팝업 (읽기 전용) ────────────────────────────────────────────────
    //
    // 라이언: "그 앞에 97cc3cc2 있잖아요 세션인데 누르면은 그 파일이 열리게끔 그래서 내용을
    // 볼 수 있게끔". 이슈 상세의 세션 줄에서 그 세션의 기록을 앱 안에서 읽는 자리다.
    //
    // md 팝업을 재사용하지 않는다. 그쪽에는 `POST /api/issues/mdsave` 로 디스크에 실제로 쓰는
    // 저장 경로가 붙어 있고, 세션 기록은 하네스가 쓰는 append-only 파일이라 사람이 고치면
    // 안 된다. 저장 버튼을 숨기는 것으로 막으면 막는 것이 화면 상태 하나가 되고 그 상태는
    // 언젠가 깨진다. 통로를 갈라 두면 쓰기 경로가 애초에 없다.
    //
    // 이 통로는 **사람의 대화 기록 전문을 루프백으로 내보내는 첫 자리**다. 그래서 경계를
    // `~/.claude/projects/` 아래로 자르는 것만으로는 부족하고 허용 목록 안까지 같이 요구한다.
    // 허용 목록에는 라이언이 상세를 실제로 연 카드의 세션만 들어간다 — 상세를 열기 전에는
    // 아무것도 못 연다는 뜻이고, 그것이 실제 조작 순서와 같다.
    //
    // 통과 조건 다섯. `workQueueMarkdownPath` 와 같은 모양이고, 그 함수는 고치지 않았다 —
    // `.md` 로 자르는 그쪽 규칙을 `.jsonl` 까지 넓히면 md 쓰기 경로가 같이 넓어진다.
    //   (1) 절대경로 (2) `..` 없음 (3) `.jsonl` 로 끝남 (4) `~/.claude/projects/` 아래
    //   (5) `WorkQueueSessionStore.revealAllowlist()` 안
    // 마지막으로 디스크에 **파일로** 실재하는지 본다(폴더가 아니다).
    private func workQueueTranscriptPath(_ path: String) -> String? {
        let p = path.trimmingCharacters(in: .whitespaces)
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects") + "/"
        guard p.hasPrefix("/"), !p.contains(".."), p.lowercased().hasSuffix(".jsonl"),
              p.hasPrefix(root),
              WorkQueueSessionStore.revealAllowlist().contains(p) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return p
    }

    // GET /api/issues/transcript?path=… — 원본 JSONL 이 아니라 정리한 턴 배열을 돌려준다.
    // 자르기와 턴 판정은 `WorkQueueSessionStore` 한 벌이 한다.
    func workQueueTranscriptRead(_ path: String) -> String {
        guard let p = workQueueTranscriptPath(path) else {
            return "{\"ok\":false,\"error\":\"unknown-path\"}"
        }
        return WorkQueueSessionStore.transcriptJSON(path: p)
    }

    func revealAgentPath(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard p.hasSuffix(".md"), !p.contains(".."), knownAgentPaths().contains(p) else {
            return "{\"ok\":false,\"error\":\"unknown-path\"}"
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
        return "{\"ok\":true}"
    }

    // 앱만 아는 작업 폴더 — 등록된 goal 들의 cwd. 인벤토리 탐색의 씨앗으로 넘긴다. 트랜스크립트에
    // 흔적이 없는 폴더라도 "사용자가 여기서 일을 시켰다"는 사실은 앱 쪽에 남아 있기 때문이다.
    private func goalCwdRoots() -> [String] {
        let cwds: [String] = DispatchQueue.main.sync { reviewStore.goals.map { $0.cwd } }
        return Array(Set(cwds.filter { !$0.isEmpty })).sorted().prefix(80).map { $0 }
    }

    // 현재 인벤토리에 잡히는 모든 에이전트 정의 파일의 절대 경로. reveal/판정/교체 요청이
    // 가리키는 경로가 진짜 우리가 아는 에이전트인지 확인하는 화이트리스트다.
    private func knownAgentPaths() -> Set<String> {
        var out = Set<String>()
        for sc in AgentInventory.scopes(globalRoot: skillsRoot, extraRoots: goalCwdRoots()) {
            for a in (sc["agents"] as? [[String: Any]]) ?? [] {
                if let p = a["path"] as? String { out.insert(p) }
            }
        }
        return out
    }

    // 판정 기록 — {path, state:"ok"|"replace"|"", reason}. 갱신 후 새 인벤토리를 그대로
    // 돌려주므로 화면은 한 번의 왕복으로 최신 상태가 된다.
    func setAgentVerdict(path: String, state: String, reason: String) -> String {
        guard knownAgentPaths().contains(path.trimmingCharacters(in: .whitespaces)) else {
            return "{\"ok\":false,\"error\":\"unknown-path\"}"
        }
        AgentVerdicts.set(path: path, state: state, reason: reason)
        return agentInventoryJSON()
    }

    // 교체 위임 — 이 에이전트를 고쳐 쓸 goal 세션을 만든다. 팀위임(/api/team/delegate)과 같은
    // 방식이다: 여기서는 goal 만 만들어 번호와 첫 턴 프롬프트를 돌려주고, 페이지가 그 프롬프트를
    // sessionStorage(cmGoalKick:<seq>) 에 넣고 /goal?seq=N 으로 이동하면 목표 페이지가 첫 턴으로
    // 쏜다. 작업 폴더(cwd)는 그 에이전트가 사는 곳 — 프로젝트 에이전트면 그 프로젝트, 전역/스킬
    // 에이전트면 ~/.claude — 로 잡아 Claude 가 곧바로 해당 파일을 고칠 수 있게 한다.
    func delegateAgentReplacement(path: String, reason: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard knownAgentPaths().contains(p) else { return "{\"ok\":false,\"error\":\"unknown-path\"}" }
        let url = URL(fileURLWithPath: p)
        let name = Self.parseFrontmatter((try? String(contentsOf: url, encoding: .utf8)) ?? "")["name"]
            ?? url.deletingPathExtension().lastPathComponent
        // <owner>/.claude/agents/x.md → <owner>
        let owner = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cwd = FileManager.default.fileExists(atPath: owner.path) ? owner.path : ""
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "에이전트 교체: " + name
        let seq = DispatchQueue.main.sync {
            reviewStore.addGoal(text: title, mode: "bypassPermissions", cwd: cwd)
        }
        guard seq > 0 else { return "{\"ok\":false,\"error\":\"create-failed\"}" }
        AgentVerdicts.set(path: p, state: "replace", reason: why, seq: seq)
        let prompt = """
        에이전트 `\(name)` 이 원하는 결과를 내지 못하고 있습니다. 정의를 교체(개선)해 주세요.

        - 정의 파일: \(p)
        - 사용자가 말한 미달 사유: \(why.isEmpty ? "(사유 미기재 — 아래 3번에서 먼저 물어봐 주세요)" : why)

        진행 순서:
        1. 정의 파일을 읽고 현재 이 에이전트가 무엇을 하기로 되어 있는지 요약하세요.
        2. 미달 사유와 대조해 어떤 지시가 빠졌거나 어긋났는지 진단하세요 — 추측이 아니라 파일의 문장을 근거로.
        3. 사유가 비어 있거나 모호하면 먼저 사용자에게 무엇이 기대와 달랐는지 물어보세요.
        4. 교체 방안을 제안하고 동의를 받은 뒤 파일을 수정하세요. 이전 버전은 되돌릴 수 있어야 합니다.
        5. 워크스페이스 규칙(CLAUDE.md 의 문서 표준: 코드 예시·표·이모지·시간 추정 금지)을 지키세요.
        """
        var out: [String: Any] = [:]
        out["ok"] = true
        out["seq"] = seq
        out["prompt"] = prompt
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // 실행 성적 — "이 에이전트가 얼마나 돌았고 얼마나 목적을 달성했나"를 이름(+하네스)만으로 낸다.
    // 위임 오버레이(/api/agents)와 에이전트 페이지(/api/agents/inventory)가 같은 수를 말해야 하므로
    // 계산은 여기 한 곳에만 있다. harness 가 선언된 에이전트는 그 하네스 스킬의 ledger/*.jsonl 을
    // 진실로 삼고, 없으면 범용 agent-update-log.jsonl 에서 자기 이름의 줄만 읽는다.
    func agentRunStats(name: String, harness: String, updateLog: [[String: Any]]) -> [String: Any] {
        let fm = FileManager.default
        var runs = 0, oks = 0
        var lastTs = "", lastOutcome = "", retro = ""
        var recent: [[String: Any]] = []
        if !harness.isEmpty {
            let hdir = skillsDir.appendingPathComponent(harness, isDirectory: true)
            retro = (try? String(contentsOf: hdir.appendingPathComponent("retro.md"), encoding: .utf8)) ?? ""
            let ledgerDir = hdir.appendingPathComponent("ledger", isDirectory: true)
            let ledgerFiles = ((try? fm.contentsOfDirectory(at: ledgerDir, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for lf in ledgerFiles {
                let t = (try? String(contentsOf: lf, encoding: .utf8)) ?? ""
                for line in t.split(separator: "\n") {
                    guard let d = line.data(using: .utf8),
                          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                    if (o["summary"] as? Bool) == true { continue }
                    let ts = (o["ts"] as? String) ?? ""
                    if ts.isEmpty && o["report"] == nil && o["goal_id"] == nil { continue }
                    let label = (o["after"] as? String) ?? (o["report"] as? String) ?? (o["reason"] as? String) ?? ""
                    let note = (o["note"] as? String) ?? ""
                    // Exclude non-attempts (dry-runs) and infra failures (app down) — neither
                    // reflects whether the AGENT did its job well.
                    if label.hasPrefix("(dry-run") || note.contains("http-error")
                        || note.contains("spawn-error") { continue }
                    let ok = ((o["ok"] as? Bool) ?? (o["synced"] as? Bool)) ?? false
                    runs += 1; if ok { oks += 1 }
                    lastTs = ts; lastOutcome = ok ? "ok" : "fail"
                    recent.append(["ts": ts, "ok": ok, "label": label])
                }
            }
        } else {
            // Standalone agents (no harness) don't own a harness ledger — their runs live in the
            // universal agent-update-log, keyed by agent name. Derive the SAME run headline from
            // there so they don't read as "기록 없음" despite an active ledger. `updateLog` is
            // chronological, so the last match is the most recent run.
            for o in updateLog where (o["agent"] as? String) == name {
                let ts = (o["ts"] as? String) ?? ""
                if ts.isEmpty { continue }
                // A missing `ok` means a recorded, completed action — count it as a success
                // unless the entry explicitly says otherwise.
                let ok = (o["ok"] as? Bool) ?? true
                let label = (o["func"] as? String) ?? (o["summary"] as? String)
                    ?? (o["type"] as? String) ?? ""
                runs += 1; if ok { oks += 1 }
                lastTs = ts; lastOutcome = ok ? "ok" : "fail"
                recent.append(["ts": ts, "ok": ok, "label": label])
            }
        }
        // Headline = success over the last 20 real runs (reflects the current agent, not
        // dragged down by old ledger entries).
        let window = recent.suffix(20)
        let windowOks = window.filter { ($0["ok"] as? Bool) == true }.count
        // Per-function-role rollup from the universal ledger (this agent's entries only).
        let functions = Self.functionRoles(forAgent: name, in: updateLog)
        var out: [String: Any] = [:]
        out["retro"] = retro
        out["runs"] = runs
        out["oks"] = oks
        out["okRate"] = runs > 0 ? Double(oks) / Double(runs) : 0
        out["recentRate"] = window.isEmpty ? 0 : Double(windowOks) / Double(window.count)
        out["recentN"] = window.count
        out["lastTs"] = lastTs
        out["lastOutcome"] = lastOutcome
        out["recent"] = Array(recent.suffix(40))
        out["functions"] = functions
        return out
    }

    // Generic YAML frontmatter -> [key: value] for top-level single-line scalar fields.
    // Unwraps quoted scalars; skips comments, blank lines, and nested/indented values.
    static func parseFrontmatter(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return map }
        var i = 1
        while i < lines.count {
            let raw = lines[i]; i += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") { continue }   // nested value
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var val = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { map[key] = val }
        }
        return map
    }

    // Deterministic (launch-stable) 64-bit FNV-1a hash. String.hashValue is per-process
    // seeded, so it would flag every app restart as a content change — this doesn't.
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // Per-agent modification history, persisted under the app data dir (never the read-only
    // ~/.claude tree). Shape: { "<file>.md": [ {ts, model, desc, sig}, … ] }.
    private var agentHistoryURL: URL { AppPaths.base.appendingPathComponent("agent-history.json") }
    private func loadAgentHistory() -> [String: [[String: Any]]] {
        guard let data = try? Data(contentsOf: agentHistoryURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[String: Any]]]
        else { return [:] }
        return obj
    }
    private func saveAgentHistory(_ h: [String: [[String: Any]]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: h) else { return }
        try? data.write(to: agentHistoryURL)
    }

    // The universal agent action ledger — one JSON line per action, keyed by "agent".
    // Responsible agents (e.g. manager-qa) append to it whenever they perform a function-role
    // or self-update. Minimum shape: {ts, agent, type, summary}; richer entries add
    // {func, rounds, ok} so the 기능 역할 tab can grade HOW WELL a role was performed
    // (round 1 = done in one pass; many rounds = the role was hard/mis-scoped).
    // The universal ledger now lives under the data dir's `ledger/` folder. Older builds/agents
    // appended it directly under the base — we still read that legacy path and merge (legacy first,
    // so its older entries sort ahead of post-move ones), so nothing is lost during the move or if a
    // straggler appends there mid-run.
    private var agentUpdateLogURL: URL { AppPaths.base.appendingPathComponent("ledger/agent-update-log.jsonl") }
    private var agentUpdateLogLegacyURL: URL { AppPaths.base.appendingPathComponent("agent-update-log.jsonl") }
    private func loadAgentUpdateLog() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for url in [agentUpdateLogLegacyURL, agentUpdateLogURL] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                out.append(o)
            }
        }
        return out
    }

    // Roll an agent's ledger entries up into per-function-role rows: how many times each role
    // was performed and — when the agent recorded `rounds` — how cleanly. This is the signal
    // for "did this role get done well?": a role that keeps taking many rounds (or is performed
    // far more than others) is a candidate to split out or update. Grouped by an explicit
    // `func` label if present, else a human label mapped from `type`. Sorted by count desc.
    static func functionRoles(forAgent name: String, in log: [[String: Any]]) -> [[String: Any]] {
        func roleName(_ o: [String: Any]) -> String {
            if let f = (o["func"] as? String)?.trimmingCharacters(in: .whitespaces), !f.isEmpty { return f }
            switch (o["type"] as? String) ?? "" {
            case "spec-update": return "SPEC 관리·동기화"
            case "agent-update": return "에이전트 자기개선"
            case "format-change": return "포맷 변경"
            case let t where !t.isEmpty: return t
            default: return "기타"
            }
        }
        func roundsOf(_ o: [String: Any]) -> Int? {
            if let i = o["rounds"] as? Int { return i }
            if let n = o["rounds"] as? NSNumber { return n.intValue }
            return nil
        }
        var order: [String] = []
        var groups: [String: [[String: Any]]] = [:]
        for o in log {
            guard ((o["agent"] as? String) ?? "") == name else { continue }
            let r = roleName(o)
            if groups[r] == nil { groups[r] = []; order.append(r) }
            groups[r]?.append(o)
        }
        var rows: [[String: Any]] = []
        for r in order {
            let entries = groups[r] ?? []
            let roundsVals = entries.compactMap(roundsOf)
            let sorted = entries.sorted { (($0["ts"] as? String) ?? "") > (($1["ts"] as? String) ?? "") }
            let lastTs = sorted.first.flatMap { $0["ts"] as? String } ?? ""
            let sample = sorted.first.flatMap { $0["summary"] as? String } ?? ""
            var row: [String: Any] = [
                "name": r, "count": entries.count, "lastTs": lastTs, "sample": sample,
            ]
            if !roundsVals.isEmpty {
                row["avgRounds"] = Double(roundsVals.reduce(0, +)) / Double(roundsVals.count)
                row["maxRounds"] = roundsVals.max() ?? 0
            }
            rows.append(row)
        }
        rows.sort { (($0["count"] as? Int) ?? 0) > (($1["count"] as? Int) ?? 0) }
        return rows
    }

    // Chronological usage feed for the skills page "히스토리" tab — newest first, capped so a
    // long-lived log never bloats the response. Each entry: skill / ts / epoch / cwd.
    func skillHistoryJSON() -> String {
        let events = skillUsageEvents().reversed()   // file order is oldest-first; show newest-first
        let cap = 500
        var rows: [[String: Any]] = []
        for ev in events.prefix(cap) {
            rows.append([
                "skill": (ev["skill"] as? String) ?? "",
                "ts": (ev["ts"] as? String) ?? "",
                "epoch": (ev["epoch"] as? Double) ?? Double((ev["epoch"] as? Int) ?? 0),
                "cwd": (ev["cwd"] as? String) ?? "",
            ])
        }
        let payload: [String: Any] = ["events": rows, "count": rows.count,
                                      "total": skillUsageEvents().count]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func revealSkill(name: String) -> String {
        let base = skillsDir
        // Guard against path traversal: only a bare folder name is honored; anything with a
        // slash or ".." falls back to revealing the skills root.
        let safe = name.trimmingCharacters(in: .whitespaces)
        let target = (!safe.isEmpty && !safe.contains("/") && !safe.contains(".."))
            ? base.appendingPathComponent(safe, isDirectory: true) : base
        DispatchQueue.main.async {
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } else {
                // Folder may not exist yet (no skills installed) — create it so Finder opens.
                try? fm.createDirectory(at: base, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([base])
            }
        }
        return "{\"ok\":true}"
    }

    // Reveal an official agent's .md file in ~/.claude/agents/ (selects the file in Finder;
    // falls back to the agents folder). Same bare-name path-traversal guard as revealSkill.
    func revealAgent(file: String) -> String {
        let base = skillsRoot.appendingPathComponent("agents", isDirectory: true)
        let safe = file.trimmingCharacters(in: .whitespaces)
        let target = (!safe.isEmpty && !safe.contains("/") && !safe.contains(".."))
            ? base.appendingPathComponent(safe) : base
        DispatchQueue.main.async {
            let fm = FileManager.default
            let sel = fm.fileExists(atPath: target.path) ? target : base
            NSWorkspace.shared.activateFileViewerSelecting([sel])
        }
        return "{\"ok\":true}"
    }

    // Set (or reset) the base ".claude" folder whose /skills holds the user's skills. A
    // blank folder resets to the ~/.claude default. Returns the refreshed skills listing so
    // the page updates the folder line AND the list in one round-trip.
    func setSkillsFolder(folder: String) -> String {
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.skillsRoot = trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
        return skillsJSON()
    }

    // Open a native folder picker so the user can choose the ".claude" root. The panel runs
    // modally on main (a direct user action, so a brief block is fine); on choose, the path
    // is persisted. Returns the refreshed skills listing (unchanged if cancelled).
    func pickSkillsFolder() -> String {
        var chosen: String?
        DispatchQueue.main.sync {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "선택"
            panel.message = "스킬이 들어있는 .claude 폴더를 선택하세요 (하위 skills 폴더를 읽습니다)"
            panel.directoryURL = skillsRoot
            if panel.runModal() == .OK, let url = panel.url { chosen = url.path }
        }
        if let c = chosen { Settings.shared.skillsRoot = c }
        return skillsJSON()
    }

    // Pull name / description / author out of a SKILL.md YAML frontmatter block. Kept
    // deliberately small — only the top-level `key: value` lines between the leading `---`
    // fences, plus folded/indented continuation lines for a multi-line description.
    static func parseSkillFrontmatter(_ text: String, fallbackName: String)
        -> (name: String, desc: String, summary: String, author: String) {
        var name = "", desc = "", summary = "", author = ""
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (fallbackName, "", "", "사용자")
        }
        var i = 1
        while i < lines.count {
            let raw = lines[i]
            if raw.trimmingCharacters(in: .whitespaces) == "---" { break }   // end of frontmatter
            // Only parse top-level keys (no leading indent); indented lines are handled as
            // continuations of the key that opened them (used for folded descriptions).
            if let colon = raw.firstIndex(of: ":"), !raw.hasPrefix(" ") && !raw.hasPrefix("\t") {
                let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                var val = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                // Folded/literal scalar (`>-`, `>`, `|`): gather the following indented lines.
                if val == ">-" || val == ">" || val == "|" || val == "|-" || val.isEmpty {
                    var parts: [String] = []
                    var j = i + 1
                    while j < lines.count {
                        let cont = lines[j]
                        if cont.hasPrefix(" ") || cont.hasPrefix("\t") {
                            parts.append(cont.trimmingCharacters(in: .whitespaces)); j += 1
                        } else { break }
                    }
                    if !parts.isEmpty { val = parts.joined(separator: " "); i = j - 1 }
                }
                // Unwrap a quoted scalar: a double-quoted value is unescaped (\" -> ", \\ -> \)
                // so a summary the user typed with quotes round-trips cleanly; a single-quoted
                // or bare value just has its surrounding quotes stripped.
                var clean = val
                if clean.count >= 2 && clean.hasPrefix("\"") && clean.hasSuffix("\"") {
                    clean = String(clean.dropFirst().dropLast())
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                } else if clean.count >= 2 && clean.hasPrefix("'") && clean.hasSuffix("'") {
                    clean = String(clean.dropFirst().dropLast())
                } else {
                    clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
                switch key {
                case "name": name = clean
                case "description": desc = clean
                case "summary": summary = clean
                case "author": author = clean
                default: break
                }
            }
            i += 1
        }
        if name.isEmpty { name = fallbackName }
        if author.isEmpty { author = "사용자" }   // ~/.claude/skills entries are user-authored
        return (name, desc, summary, author)
    }

    // First sentence (or a short truncation) of a long description — the fallback shown
    // when a skill has no explicit `summary:` yet.
    static func firstSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if let r = t.range(of: ". ") { return String(t[t.startIndex..<r.lowerBound]) + "." }
        if t.count > 100 {
            let idx = t.index(t.startIndex, offsetBy: 100)
            return String(t[t.startIndex..<idx]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return t
    }

    // Write (or replace) the top-level `summary:` line in a skill's SKILL.md frontmatter.
    // We only ever touch that single line, so the (long, folded) `description:` used for
    // triggering is left intact. Called from POST /api/skills/summary.
    func setSkillSummary(folder: String, summary: String) -> String {
        let safe = folder.trimmingCharacters(in: .whitespaces)
        guard !safe.isEmpty, !safe.contains("/"), !safe.contains("..") else { return "{\"ok\":false}" }
        let md = skillsDir.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        guard var text = try? String(contentsOf: md, encoding: .utf8) else { return "{\"ok\":false}" }
        let oneLine = summary.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let escaped = oneLine.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let newLine = "summary: \"\(escaped)\""
        var lines = text.components(separatedBy: "\n")

        // No frontmatter at all -> prepend a minimal block.
        guard let openIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            text = "---\n\(newLine)\n---\n\n" + text
            try? text.write(to: md, atomically: true, encoding: .utf8)
            return "{\"ok\":true}"
        }
        var closeIdx: Int? = nil
        var k = openIdx + 1
        while k < lines.count { if lines[k].trimmingCharacters(in: .whitespaces) == "---" { closeIdx = k; break }; k += 1 }
        guard let close = closeIdx else { return "{\"ok\":false}" }

        // Replace an existing top-level `summary:` (plus any folded continuation lines)…
        var replaced = false
        var i = openIdx + 1
        while i < close {
            let raw = lines[i]
            if !raw.hasPrefix(" "), !raw.hasPrefix("\t"), let colon = raw.firstIndex(of: ":"),
               String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces) == "summary" {
                var end = i + 1
                while end < close && (lines[end].hasPrefix(" ") || lines[end].hasPrefix("\t")) { end += 1 }
                lines.replaceSubrange(i..<end, with: [newLine])
                replaced = true
                break
            }
            i += 1
        }
        // …or insert right after `name:` (falling back to just inside the opening fence).
        if !replaced {
            var insertAt = openIdx + 1
            var j = openIdx + 1
            while j < close {
                let raw = lines[j]
                if !raw.hasPrefix(" "), !raw.hasPrefix("\t"), let colon = raw.firstIndex(of: ":"),
                   String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces) == "name" {
                    insertAt = j + 1; break
                }
                j += 1
            }
            lines.insert(newLine, at: insertAt)
        }
        let out = lines.joined(separator: "\n")
        try? out.write(to: md, atomically: true, encoding: .utf8)
        return "{\"ok\":true}"
    }

    // Korean short date, matching Claude Code's skill list ("26. 7. 3.").
    static func koShortDate(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        let yy = (c.year ?? 2000) % 100
        return "\(yy). \(c.month ?? 1). \(c.day ?? 1)."
    }

    // One tap for EVERY dashboard POST: each API call becomes an action-log event,
    // so 목표설정·설정 변경도 BGM 조작과 같은 타임라인에 남는다 — the filterable
    // behavior stream that EXP rules and agent decisions read from. The action name
    // is derived from the path ("goal.add", "goal.queue.resolve"), so new endpoints
    // are logged automatically with no per-endpoint table to keep in sync. Paths
    // that already log a richer event inside their handler (session/BGM controls)
    // and pure plumbing (webview audio sync, CLI keystrokes, debug hooks, worker
    // session hooks) are skipped so the log stays 1 user action = 1 line.
    // Known gap: headless agents that POST the same endpoints (e.g. goal-title-sync
    // hitting /api/goal/title) are indistinguishable from the user here and land as
    // kind:user — acceptable for v1; an origin marker can split them later.
    private func logDashboardAction(_ path: String, _ obj: [String: Any]) {
        let skip: Set<String> = [
            "/api/bgm/native",                        // webview audio-ownership sync
            "/api/bgm/control",                       // handler logs bgmOn/bgmOff
            "/api/session/control",                   // handler logs sessionStart/Stop
            "/api/session/mute",                      // handler logs mute/unmute
            "/api/session/sfx",                       // handler logs sfxOn/sfxOff
            "/api/equipment/pomodoro",                // handler logs equipment.devAward
            "/api/equipment/tap",                     // 쓰다듬기 +1 XP — high-frequency, noise not workflow
            "/api/sfx",                               // handler logs harvest/chime
            "/api/bgm/rain", "/api/equipment/rain",   // handlers log rainSummon
            "/api/bgm/venue",                         // director logs venueChange (richer)
            "/api/update/run",                        // handler logs updateRun
            "/api/goal/aiAdd",                        // dup pre-check inside the add flow
            "/api/session/event",                     // Claude session hooks, not the user
            "/api/goal/cli/io", "/api/goal/cli/resize", // terminal keystrokes (noise)
            "/api/memo",                              // 자동 저장 도배 방지 + 메모 내용 로그 유출 방지
            "/api/memo/seq",                          // 메모장 골번호 자동 채번 — 유저 액션이 아니다
            "/api/memo/tidy",                         // 본문이 body 에 실린다 — 핸들러가 글자 수만 남긴다
        ]
        guard path.hasPrefix("/api/"), !skip.contains(path),
              !path.hasPrefix("/api/debug/") else { return }

        // Category = domain of the action (the 액션로그 필터 축).
        let category: String
        if path.hasPrefix("/api/goal/") || path.hasPrefix("/api/queue/")
            || path.hasPrefix("/api/sprint/") || path.hasPrefix("/api/team/")
            || path.hasPrefix("/api/chat/") { category = "goal" }
        else if path.hasPrefix("/api/session/") { category = "pomodoro" }
        else if path.hasPrefix("/api/bgm/") { category = "bgm" }
        else if path.hasPrefix("/api/equipment/") { category = "equipment" }
        else if path.hasPrefix("/api/settings/") || path.hasPrefix("/api/window/")
            || path.hasPrefix("/api/update/") || path.hasPrefix("/api/skills/")
            || path.hasPrefix("/api/agents/") || path.hasPrefix("/api/plugin/")
            || path.hasPrefix("/api/integrations") { category = "settings" }
        else { category = "other" }

        var action = path.dropFirst("/api/".count).split(separator: "/").joined(separator: ".")
        // AI검색 rides the same enqueue endpoint (search:true = findOnly) — split the
        // action name so 검색 and 목표 추가 are distinguishable in the log.
        if path == "/api/goal/queue/enqueue", (obj["search"] as? Bool) == true {
            action = "goal.queue.search"
        }

        // Short human trail: goal number plus the single most telling body field,
        // truncated so one long paste can't bloat the log line.
        var bits: [String] = []
        if let n = obj["seq"] as? NSNumber { bits.append("#\(n.intValue)") }
        else if let s = obj["seq"] as? String, !s.isEmpty { bits.append("#" + s) }
        // 키 등록 요청의 본문에는 비밀값이 들어 있다 — 어떤 필드도 로그로 옮기지
        // 않는다. 아래 필드 목록에 value가 없다는 사실에만 기대면, 나중에 목록을
        // 한 줄 늘리는 순간 키가 액션 로그에 적힌다.
        // 인스턴스 추가도 같은 본문에 토큰을 싣는다 (credId·label만 있는 경우도
        // 있지만, 경로 단위로 막아야 나중에 필드가 늘어도 새지 않는다).
        let secretBody = path.hasPrefix("/api/integrations/key")
            || path.hasPrefix("/api/integrations/instance")
        for key in ["action", "status", "text", "title", "name", "tz", "mode"] where !secretBody {
            if let v = obj[key] as? String, !v.isEmpty {
                bits.append(v.count > 60 ? String(v.prefix(60)) + "…" : v)
                break
            }
        }
        let detail = bits.joined(separator: " · ")
        // actionEvent reads main-thread state (director/audio); handlePost runs on
        // the server thread, so hop to main for the snapshot + append.
        DispatchQueue.main.async {
            ActionLog.shared.append(self.actionEvent(action, detail: detail, category: category))
        }
    }

    func handlePost(_ path: String, _ body: String) -> String {
        // 0.5s view-trace heartbeat batches (injected JS, see AppWindowController.viewTraceScript).
        // Handled FIRST and entirely on this server thread — arrives every ~5s per webview, so it
        // must never touch main or the action log (it is under /api/debug/, which is exempt anyway).
        if path == "/api/debug/view-trace" {
            let n = ViewTrace.shared.appendBatch(body)
            // 응답의 cap 이 디버그 모드(버그 수집)의 on/off 신호다 — 주입 스크립트가 이 왕복
            // 하나로 상태를 따라가므로 별도 폴링 엔드포인트가 필요 없다.
            return "{\"ok\":true,\"accepted\":\(n),\"cap\":\(DebugCapture.shared.isOn)}"
        }
        // 디버그 모드 배치(키/클릭/콘솔/네트워크). view-trace와 같은 이유로 서버 스레드에서
        // 끝내고, 꺼져 있으면 appendBatch가 0을 돌려주며 아무것도 쓰지 않는다.
        if path == "/api/debug/capture" {
            let n = DebugCapture.shared.appendBatch(body)
            return "{\"ok\":true,\"accepted\":\(n),\"cap\":\(DebugCapture.shared.isOn)}"
        }
        // 디버그 모드 on/off — 메뉴바 위젯과 같은 동작(끄면 버그 리포트 goal 자동 생성).
        // QA/자동화가 위젯 클릭 없이 같은 경로를 태울 수 있도록 열어 둔다.
        if path == "/api/debug/capture/toggle" {
            let obj = (body.data(using: .utf8)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            let want = (obj["on"] as? NSNumber)?.boolValue ?? (obj["on"] as? Bool) ?? !DebugCapture.shared.isOn
            DispatchQueue.main.async { self.setDebugCapture(want, source: "API") }
            return "{\"ok\":true,\"on\":\(want)}"
        }
        // TEMPORARY: Korean-IME/xterm diagnostic tap (see Core/IMEDebugLog.swift). Remove with it.
        if path == "/api/debug/ime-log" {
            let n = IMEDebugLog.shared.appendBatch(body)
            return "{\"ok\":true,\"accepted\":\(n)}"
        }
        // 화면 카탈로그 관리 필드 (메모·상태) — the catalog tab's per-screen UX review notes.
        // Under /api/debug/ → exempt from the action log; handled on this server thread.
        if path == "/api/debug/screens/note" {
            let o = (body.data(using: .utf8)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            guard let id = o["id"] as? String else { return "{\"ok\":false}" }
            let ok = ScreenCatalog.shared.setNote(id: id,
                                                  note: o["note"] as? String,
                                                  status: o["status"] as? String)
            return "{\"ok\":\(ok)}"
        }
        let obj = (body.data(using: .utf8)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        logDashboardAction(path, obj)
        // AI dedup pass runs an external `claude -p` (seconds, blocking). Handle it HERE
        // on the server thread — never inside the main.sync block below, or the whole UI
        // would freeze while the model thinks. It only reads a goals snapshot, so it is
        // safe off-main.
        if path == "/api/goal/aiAdd" {
            return aiDuplicateCheck(text: (obj["text"] as? String) ?? "",
                                    parent: (obj["parent"] as? String) ?? "")
        }
        // BGM view took over playback in the browser (or released it): mute/unmute the
        // native AudioEngine so the same track is not heard twice. Just a flag set on main.
        if path == "/api/bgm/native" {
            let mute = (obj["mute"] as? Bool) ?? false
            // The app window's ownership latch wins: while the window is open (either mode), native
            // stays muted even if the player (e.g. on a track switch) briefly asks to unmute.
            DispatchQueue.main.sync { self.audio.muted = mute || self.windowOwnsAudio }
            return "{\"ok\":true}"
        }
        // Test-only hook: headlessly switch the app window's mode without clicking the in-window
        // segmented toggle, so QA can exercise the dashboard<->bgm switch (and the audio-ownership
        // fix) in a scripted/CI run. Only reachable if the window is already open (see openInternal);
        // does not open the window itself.
        if path == "/api/debug/window-mode" {
            let modeStr = (obj["mode"] as? String) ?? ""
            guard let m = AppWindowController.Mode(rawValue: modeStr) else { return "{\"ok\":false}" }
            DispatchQueue.main.sync {
                if m == .bgm { self.openBGMWindow() } else { self.openDashboard() }
            }
            return "{\"ok\":true}"
        }
        // Test-only hook: headlessly simulate the user clicking the window's close button (real
        // NSWindow.close(), so the genuine windowWillClose -> onUserClose -> quit() path runs) —
        // lets QA exercise "closing the window quits the whole app" (SPEC Q1) without a real click.
        if path == "/api/debug/window-close" {
            DispatchQueue.main.sync { self.appWindowTestClose() }
            return "{\"ok\":true}"
        }
        // TEMPORARY QA hook (Korean-IME investigation, 2026-07-12): headlessly navigate the open
        // app window's dashboard webview to an arbitrary path — see AppWindowController.debugNavigate.
        if path == "/api/debug/window-nav" {
            let navPath = (obj["path"] as? String) ?? ""
            guard navPath.hasPrefix("/") else { return "{\"ok\":false}" }
            DispatchQueue.main.sync { self.appWindowDebugNavigate(path: navPath) }
            return "{\"ok\":true}"
        }
        // 네트워크 진단 실행 (on-demand): probe VPN state + machine network + each target host's
        // DNS/HTTPS reachability, persist the snapshot, and return it for immediate rendering.
        // Runs on THIS server thread (bounded per-step timeouts inside DiagProbe), so a hung host
        // can't stall the app for more than a few seconds. Under /api/debug/ → not action-logged.
        // Optional body {"hosts":[…]} overrides the configured list for a one-off probe.
        if path == "/api/debug/diag/run" {
            let hosts: [String]
            if let override = obj["hosts"] as? [String], !override.isEmpty {
                hosts = override
            } else {
                hosts = Settings.shared.diagHosts
            }
            let snapshot = DiagProbe.run(hosts: hosts)
            DiagStore.shared.append(snapshot)
            let data = (try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        // 네트워크 진단 대상 호스트 목록 저장 (진단 탭 편집). Empty/whitespace entries are dropped;
        // an empty result falls back to the built-in default (see Settings.diagHosts).
        if path == "/api/settings/diag-hosts" {
            let hosts = (obj["hosts"] as? [String]) ?? []
            Settings.shared.diagHosts = hosts
            return diagHostsJSON()
        }
        // BGM view remote control: turn the BGM system (the widget's master switch) on/off
        // so the dashboard 액티비티 탭 and the menu-bar widget stay in sync. Mirrors the
        // menu's toggleMusic; the heartbeat starts the director on the next tick.
        if path == "/api/bgm/control" {
            let action = (obj["action"] as? String) ?? ""
            DispatchQueue.main.sync {
                if action == "play" { self.setBGMEnabled(true) }
                else if action == "stop" { self.setBGMEnabled(false) }
            }
            return "{\"ok\":true}"
        }
        // BGM view remote control for the CHALLENGE (work session) itself — the play button
        // in the 액티비티 탭 doubles as "챌린지 시작/중단" so the dashboard and the menu-bar
        // widget share one start/stop. Mirrors the menu's toggleWorking. Playback only makes
        // sound while a session is live (inSession gate), so the play button starts the session
        // here rather than only flipping the BGM master switch.
        if path == "/api/session/control" {
            let action = (obj["action"] as? String) ?? ""
            // Optional session mode from the rail's challenge dial (pomodoro /
            // sprint / unlimited) — selects the per-mode BGM playlist.
            let mode = obj["mode"] as? String
            // Optional pomodoro target seconds from the re-tappable 25분 chip (25·45·50분).
            let pomodoroSecs = (obj["pomodoroSecs"] as? NSNumber)?.intValue
                ?? Int((obj["pomodoroSecs"] as? String) ?? "")
            DispatchQueue.main.sync {
                if action == "start" { self.startWorking(mode: mode, pomodoroSecs: pomodoroSecs) }
                else if action == "stop" { self.stopWorking() }
                // 🍅 수확 탭: claim the server-owned reward orb (count already recorded
                // at completion — this only clears the pending state + plays the chime).
                else if action == "harvest" { self.harvestPomodoro() }
            }
            return "{\"ok\":true}"
        }
        // 세션 레일 고정(핀) 토글 — 고정된 goal 은 라이브 터미널·in_progress·보는 중 이 아니어도
        // 항상 레일 "고정됨" 섹션에 뜨고, 앱을 재시작해도 유지된다(Settings.pinnedGoalSeqs).
        // Body: {seq:N, pin?:true|false}. pin 을 주면 그 상태로 강제, 없으면 토글.
        if path == "/api/cli/pin" {
            let seq = (obj["seq"] as? NSNumber)?.intValue
                ?? Int((obj["seq"] as? String) ?? "")
            guard let seq, seq > 0 else { return "{\"ok\":false,\"error\":\"bad seq\"}" }
            let force = obj["pin"] as? Bool
            let pinned = Settings.shared.setPinnedGoal(seq, pinned: force)
            return "{\"ok\":true,\"seq\":\(seq),\"pinned\":\(pinned ? "true" : "false")}"
        }
        // 세션 뷰 "보는 중" 스탬프 — /goal 페이지 GET 이 찍는 markActiveGoal 과 같은 도장.
        // /goal-add 의 인라인 세션 뷰(GUI시작·GUI열기)는 페이지 이동 없이 세션을 열므로
        // 여기로 직접 찍어야 왼쪽 레일 세션 목록에 그 목표가 바로 나타난다.
        if path == "/api/goal/viewing" {
            let seq = (obj["seq"] as? NSNumber)?.intValue
                ?? Int((obj["seq"] as? String) ?? "")
            guard let seq, seq > 0 else { return "{\"ok\":false,\"error\":\"bad seq\"}" }
            Settings.shared.markActiveGoal(seq, at: Date().timeIntervalSince1970)
            return "{\"ok\":true,\"seq\":\(seq)}"
        }
        // 목표 추가 컴포저의 마지막 실행 컨텍스트(작업 폴더·브랜치·작업량·모드)를 서버에 영속.
        // localStorage 는 매 실행마다 바뀌는 dynamic 포트(=새 origin)에 리셋되므로, 여기 저장해
        // 재빌드/재시작 후에도 고른 폴더가 유지된다. recents MRU 는 서버가 관리(dedupe·상한 8).
        if path == "/api/goal/composer" {
            Settings.shared.markComposer(cwd: (obj["cwd"] as? String) ?? "",
                                         name: (obj["name"] as? String) ?? "",
                                         branch: (obj["branch"] as? String) ?? "",
                                         effort: (obj["effort"] as? String) ?? "",
                                         mode: (obj["mode"] as? String) ?? "",
                                         model: (obj["model"] as? String) ?? "")
            return Settings.shared.gaComposerJSON()
        }
        // 세션 뷰 하단 컴포저의 실행 설정 변경 — chat2Say/sessionSay read the GOAL's stored
        // effort/mode/model each turn (they win over the request), so a mid-session change
        // must land on the goal record to take effect from the next turn. Only the fields
        // present in the body change; invalid values are ignored ('' = CLI default is valid).
        if path == "/api/goal/exec" {
            let seq = (obj["seq"] as? NSNumber)?.intValue ?? 0
            guard seq > 0 else { return "{\"ok\":false,\"error\":\"seq\"}" }
            let validModes: Set<String> = ["acceptEdits", "auto", "bypassPermissions", "default", "plan"]
            var effort: String? = nil, mode: String? = nil, model: String? = nil
            if let e = obj["effort"] as? String, e.isEmpty || Self.validEffortLevels.contains(e) { effort = e }
            if let m = obj["mode"] as? String, validModes.contains(m) { mode = m }
            if let mo = obj["model"] as? String, mo.isEmpty || Self.validComposerModels.contains(mo) { model = mo }
            guard effort != nil || mode != nil || model != nil else { return "{\"ok\":false,\"error\":\"empty\"}" }
            DispatchQueue.main.sync {
                reviewStore.setGoalExecSettings(seq: seq, effort: effort, mode: mode, model: model)
            }
            return "{\"ok\":true}"
        }
        // 담김 히스토리(simple-큐) 서버 영속 — localStorage 는 dynamic 포트 리셋으로 업데이트/재시작
        // 때 사라지므로 여기 저장한다. 페이지가 보내는 목록을 알려진 필드만 골라 담는다(상한 100).
        if path == "/api/goal/tally" {
            let raw = (obj["list"] as? [[String: Any]]) ?? []
            Settings.shared.gaTallyHist = raw.suffix(100).map { e in
                ["kind": (e["kind"] as? String) ?? "",
                 "text": (e["text"] as? String) ?? "",
                 "id": (e["id"] as? String) ?? "",
                 "st": (e["st"] as? String) ?? "",
                 "seq": (e["seq"] as? NSNumber)?.intValue ?? 0,
                 "resolved": (e["resolved"] as? String) ?? "",
                 "ts": (e["ts"] as? NSNumber)?.doubleValue ?? 0] as [String: Any]
            }
            return "{\"ok\":true}"
        }
        // 장비 EXP 지급 시뮬 — the /equipment page's dev-only 시뮬 button. Real pomodoro
        // completions are judged server-side (heartbeat wall-clock → completePomodoro),
        // which grants EXP itself and logs pomodoro.complete; this endpoint only exercises
        // the award pipeline and must NOT log a complete or touch the durable N/2 history.
        // 쓰다듬기 — the equipment page's pixel avatar click: +1 XP to the weakest gear
        // (EquipmentStore.tap). Returns the full equipment state so the page re-renders
        // its gauges in place. Not action-logged (skip list above).
        if path == "/api/equipment/tap" {
            equipment.tap()
            return equipmentJSON()
        }
        if path == "/api/equipment/pomodoro" {
            let usage = equipmentUsage(within: TimeInterval(Self.pomodoroWallSeconds))
            equipment.recordPomodoro(usage: usage)
            DispatchQueue.main.async {
                ActionLog.shared.append(self.actionEvent("equipment.devAward", kind: "system",
                    detail: "장비 EXP 지급 시뮬 (/equipment 시뮬 버튼)", category: "pomodoro"))
            }
            return equipmentJSON()
        }
        // 원샷 이펙트음 재생 — the rail's 🍅 harvest tap is purely client-side (confetti +
        // daily counter, no server state change), so it requests the native chime here.
        // Names map through a fixed whitelist, NEVER a caller-supplied filename, so the
        // loopback page cannot probe or play arbitrary files.
        if path == "/api/sfx" {
            // First existing candidate wins: a user-dropped mp3 overrides the
            // generated m4a default (the sound folder is the interface).
            let sfx: [String: [String]] = [
                "harvest": ["pomodoro-harvest.mp3", "harvest.m4a"],
                "session-start": ["pomodoro-start.mp3", "session-start.m4a"],
                // 레일 모드 내비(chat/스킬/크론/위임/팀위임/작업) 클릭 — 장비 장착풍 메탈릭 클릭.
                "nav": ["nav-equip.mp3"],
            ]
            guard let name = obj["name"] as? String, let files = sfx[name] else {
                return "{\"ok\":false,\"error\":\"unknown sfx\"}"
            }
            DispatchQueue.main.async {
                // 수확 탭은 서버 상태를 안 바꾸는 순수 클라이언트 제스처라 이 sfx 요청이
                // 유일한 서버 접점 — 유저 행동 이벤트는 여기서 남긴다.
                if name == "harvest" {
                    ActionLog.shared.append(self.actionEvent("pomodoro.harvest",
                        detail: "🍅 수확 탭", category: "pomodoro"))
                }
                if let played = SoundEffects.shared.playFirst(files) {
                    ActionLog.shared.append(self.actionEvent("chime", kind: "system",
                        detail: "이펙트음 \(name) (sound/\(played))"))
                }
            }
            return "{\"ok\":true}"
        }
        // 설정 menu 표시 타임존 — accepts "system" (machine local) or a valid IANA identifier
        // only; anything else is rejected so settings.json can never hold a broken zone.
        // Storage/기준 stays epoch (UTC); this drives display conversion only, so no stored
        // data is rewritten. Pages pick it up on their next load (the rail reloads itself).
        if path == "/api/settings/timezone" {
            let raw = (obj["tz"] as? String) ?? ""
            guard raw == "system" || TimeZone(identifier: raw) != nil else {
                return "{\"ok\":false,\"error\":\(jsonString("알 수 없는 타임존: " + raw))}"
            }
            Settings.shared.timeZoneID = raw
            return timezoneJSON()
        }
        // Claude CLI 연결 설정 (rail ⚙️설정). 부분 갱신 — 보낸 필드만 반영한다. 비밀 값은
        // 받지 않는다: 토큰은 유저의 기존 키체인 항목에 그대로 두고 항목 이름만 저장한다.
        if path == "/api/settings/gateway" {
            let s = Settings.shared
            if let m = obj["mode"] as? String, m == "auto" || m == "gateway" { s.gatewayMode = m }
            if let b = obj["baseURL"] as? String {
                let t = b.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { s.gatewayBaseURL = "" }
                else if let u = URL(string: t), u.scheme?.lowercased() == "https", (u.host ?? "").isEmpty == false {
                    s.gatewayBaseURL = t
                } else {
                    return "{\"ok\":false,\"error\":\(jsonString("https URL이 필요합니다: " + t))}"
                }
            }
            if let sc = obj["scheme"] as? String, sc == "bearer" || sc == "apiKey" { s.gatewayScheme = sc }
            if let ks = obj["keyService"] as? String {
                s.gatewayKeyService = ks.trimmingCharacters(in: .whitespaces)
            }
            if let ka = obj["keyAccount"] as? String {
                s.gatewayKeyAccount = ka.trimmingCharacters(in: .whitespaces)
            }
            Self.invalidateGatewayEnv()
            Self.lastGatewayState = nil   // settings changed: the old verdict no longer applies
            return settingsGatewayJSON()
        }
        // 연결 테스트 — 현재 설정 그대로 headless `claude -p` 한 번을 실행해 응답이 오는지 본다.
        // detail은 CLI 출력의 앞부분만 (토큰은 포함될 수 없다).
        if path == "/api/settings/gateway/test" {
            return gatewayTestJSON()
        }
        // 로그인 필요 상태에서의 액션 — 터미널에서 `claude /login`(대화형 OAuth)을 띄운다.
        if path == "/api/settings/gateway/login" {
            return gatewayLoginJSON()
        }
        // 메모장 저장 (전역 1개 공유). MemoPad 가 타이핑 중 400ms 디바운스로, blur/pagehide 에서
        // 즉시 한 번 더 부른다. 액션 로그에는 남기지 않는다 — 자동 저장이라 actions.jsonl 을
        // 도배하고, 메모 내용이 로그로 흘러나가는 것도 원치 않는다.
        // 메모장 칸 태그 만들기 / 사용 기록. 후보를 골랐을 때도, 없는 이름을 "만들기" 로
        // 새로 세울 때도 같은 길로 온다 — 고르는 것 자체가 그 태그를 한 번 더 쓴 것이다.
        // 이미 있는 이름이면 새로 만들지 않고 횟수만 오른다(`name` 에 사전의 표기가 돌아온다).
        if path == "/api/memo/tags" {
            let kind = (obj["k"] as? String) ?? ""
            guard let stored = MemoTagStore.shared.touch(kind: kind, name: (obj["name"] as? String) ?? "")
            else { return "{\"ok\":false}" }
            return "{\"ok\":true,\"name\":\(jsonString(stored))}"
        }
        // 메모장 'AI로 정리해서 복사' — 화면에 보이는 줄을 클로드 코드에 넘겨 오타·줄 구조를
        // 다듬는다. 1~5분 걸리는 일이라 여기서 기다리지 않는다: 잡만 세우고 즉시 돌아가고,
        // 진행은 레일의 'AI 정리' 줄이, 완료 통보는 클립보드가 한다(MemoTidyStore).
        if path == "/api/memo/tidy" {
            let src = (obj["text"] as? String) ?? ""
            guard let id = MemoTidyStore.shared.start(text: src) else { return "{\"ok\":false}" }
            // 액션 로그에는 글자 수만 — 메모 본문이 actions.jsonl 로 흘러나가지 않도록
            // (일반 로거는 위 skip 목록에서 빼 두었다).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ActionLog.shared.append(self.actionEvent("memo.tidy",
                    detail: "AI 정리 시작 · \(src.count)자", category: "goal"))
            }
            return "{\"ok\":true,\"id\":\(jsonString(id))}"
        }
        // 끝난 정리 결과를 다시 클립보드로 (레일 팝업의 '복사'). 웹뷰의 clipboard API 를
        // 거치지 않고 앱이 직접 넣는다 — 포커스가 어디에 있든 확실하다.
        if path == "/api/memo/tidy/copy" {
            let ok = MemoTidyStore.shared.copyToPasteboard(id: (obj["id"] as? String) ?? "")
            return "{\"ok\":\(ok)}"
        }
        // 메모장 부모 칸 사용 기록 — 드롭다운에서 고르든 손으로 적든, 확정된 부모 번호가
        // MRU 로 올라 다음에 맨 위에 뜬다. 보드 부모# 드롭다운의 '최근 사용' 과 같은 목록.
        if path == "/api/memo/parent-used" {
            Settings.shared.noteParentUse((obj["n"] as? NSNumber)?.intValue ?? 0)
            return "{\"ok\":true}"
        }
        // 메모장 골번호 채번 — 체크리스트 줄이 보드와 같은 골 번호 공간에서 유일 번호를
        // 예약한다(ReviewStore.reserveSeqs, 번호만 예약 — Goal 은 만들지 않는다). 패드가
        // 번호 없는 줄 수만큼 묶어 한 번에 요청하고, 받은 번호를 '@골: N' 으로 줄에 박는다.
        // ReviewStore 는 메인 스레드 소유물이므로 여기서 잠깐 건너간다.
        if path == "/api/memo/seq" {
            let count = (obj["count"] as? NSNumber)?.intValue ?? 1
            var seqs: [Int] = []
            DispatchQueue.main.sync { seqs = self.reviewStore.reserveSeqs(count) }
            return "{\"ok\":true,\"seqs\":[\(seqs.map(String.init).joined(separator: ","))]}"
        }
        // `base` = the revision the pad last saw. Mismatch = a stale webview trying to
        // overwrite newer text: the store refuses (journaling the refused text), and we
        // return the CURRENT text so the pad can merge and retry with a fresh base.
        // A body without `base` (old client, e2e stubs) keeps the legacy always-accept path.
        if path == "/api/memo" {
            let saved = MemoStore.shared.save((obj["text"] as? String) ?? "",
                                              base: (obj["base"] as? NSNumber)?.intValue)
            if saved.conflict {
                return "{\"ok\":true,\"conflict\":true,\"text\":\(jsonString(saved.text)),"
                    + "\"rev\":\(saved.rev),\"updatedAt\":\(Int(saved.updatedAt))}"
            }
            return "{\"ok\":true,\"rev\":\(saved.rev),\"updatedAt\":\(Int(saved.updatedAt)),"
                + "\"chars\":\(saved.text.count)}"
        }
        // 전역 디버그 버튼 노출 토글 (rail ⚙️설정) — off면 각 페이지의 디버그성
        // 버튼이 아예 렌더링되지 않는다. 페이지 폴링이 다음 주기에 바로 반영.
        if path == "/api/settings/debug-buttons" {
            Settings.shared.debugButtons = (obj["on"] as? NSNumber)?.boolValue ?? true
            return "{\"on\":\(Settings.shared.debugButtons)}"
        }
        // 설정 menu "Finder에서 열기" — reveal one of the app's storage folders. Target is a
        // fixed key (data|bgm|claude), NEVER a caller-supplied path, so the loopback page
        // cannot open arbitrary filesystem locations.
        if path == "/api/settings/reveal" {
            let target = (obj["target"] as? String) ?? ""
            let url: URL?
            switch target {
            case "data":
                url = AppPaths.base
            case "bgm":
                let p = ProcessInfo.processInfo.environment["CM_SCAN_DIR"]
                    ?? Settings.shared.musicFolderPath
                url = p.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            case "claude":
                url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/projects", isDirectory: true)
            case "issue":
                // Only the CONFIGURED folder is revealable. While the setting is on its
                // default the issue folder has no single location — it is whatever the
                // next session's cwd is — so there is nothing honest to open.
                url = IssueFolder.override
            case "queue":
                // 이슈 폴더와 같은 규칙이다 — UI 에서 고른 폴더(override)만 연다. 기본값일 때는
                // 레일이 ↗ 를 아예 그리지 않으므로(SessionRail.queueRow) 여기서 볼 것은
                // Settings 의 override 하나뿐이고, 환경변수/하드코딩 기본값은 보지 않는다.
                url = Settings.shared.queueFolder.flatMap {
                    $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
                }
            default:
                url = nil
            }
            guard let u = url, FileManager.default.fileExists(atPath: u.path) else {
                return "{\"ok\":false,\"error\":\"폴더가 없거나 설정되지 않았습니다\"}"
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(u) }
            return "{\"ok\":true}"
        }
        // 설정 menu 업데이트 button — run the local auto-update. Scripts/build-app.sh rebuilds
        // from CMSourceRoot (a build-time stamp, never caller-supplied), quits this instance
        // through the normal shutdown path, swaps /Applications, and relaunches. The script is
        // spawned as its own child that outlives this process (orphaned to launchd on quit);
        // output goes to <data>/update.log for post-mortem.
        if path == "/api/update/run" {
            guard let root = Bundle.main.object(forInfoDictionaryKey: "CMSourceRoot") as? String,
                  !root.isEmpty else {
                return "{\"ok\":false,\"error\":\"소스 경로가 없는 빌드입니다 (dev 빌드는 dev-watch가 갱신)\"}"
            }
            // Fast path: a background build is already staged, so applying it is a copy +
            // relaunch (~2s) instead of a release compile (~40s+). Falls through to the
            // build-then-install script when nothing is staged (no builder installed, or
            // the staged bundle is older than this one).
            let ownBuildStart = (Bundle.main.object(forInfoDictionaryKey: "CMBuildStart") as? String)
                .flatMap(TimeInterval.init) ?? 0
            let staged = Self.readStagedBuild()
            let useStaged = staged?.state == "ready" && (staged?.buildStart ?? 0) > ownBuildStart
            let script = root + (useStaged ? "/Scripts/apply-update.sh" : "/Scripts/build-app.sh")
            guard FileManager.default.isExecutableFile(atPath: script) else {
                return "{\"ok\":false,\"error\":\"빌드 스크립트를 찾을 수 없습니다: \(script)\"}"
            }
            let logPath = AppPaths.base.appendingPathComponent("update.log").path
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script]
            p.currentDirectoryURL = URL(fileURLWithPath: root, isDirectory: true)
            // Strip CM_* overrides so the relaunched prod app never inherits a dev data dir
            // (same reason build-app.sh launches with `env -u CM_DATA_DIR`).
            var env = ProcessInfo.processInfo.environment
            for k in ["CM_DATA_DIR", "CM_DEV", "CM_DEV_AUTO_OPEN"] { env.removeValue(forKey: k) }
            p.environment = env
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile()
                p.standardOutput = h
                p.standardError = h
            }
            // On success this process is replaced, so the handler only ever fires for
            // failure (script exited non-zero, app still alive). No user-facing error:
            // snapshot the source state so check reports the update as unavailable until
            // the tree changes, and keep the post-mortem in update.log + action log.
            updateFailedSrcAt = nil
            p.terminationHandler = { [weak self] proc in
                guard proc.terminationStatus != 0 else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Only the BUILD path gets the source snapshot suppression — it means
                    // "these exact sources won't compile". A failed apply is about the
                    // staged bundle, not the tree, so leave the button alone: staged.json
                    // still says ready and pressing again is a reasonable retry.
                    if !useStaged { self.updateFailedSrcAt = Self.latestSourceMTime(root: root) }
                    ActionLog.shared.append(self.actionEvent("updateFail", kind: "system",
                        detail: useStaged
                            ? "업데이트 적용 실패 (exit \(proc.terminationStatus)) — 현재 버전 유지, 상세는 update.log"
                            : "업데이트 빌드 실패 (exit \(proc.terminationStatus)) — 현재 버전 유지, 상세는 update.log"))
                }
            }
            do { try p.run() } catch {
                return "{\"ok\":false,\"error\":\"업데이트 실행 실패: \(error.localizedDescription)\"}"
            }
            ActionLog.shared.append(actionEvent("updateRun",
                detail: useStaged
                    ? "업데이트 — 미리 준비된 빌드 적용 (apply-update.sh, 교체 후 재시작)"
                    : "업데이트 — build-app.sh 실행 (빌드 후 자동 재시작)"))
            return "{\"ok\":true,\"staged\":\(useStaged)}"
        }
        // 경험치로 폭우소환 — the 장비 page's manual nature-sound summon. The idea: when the
        // BGM has become tiring, spend accumulated EXP to swap it for 30–60분 of rain and
        // observe how condition recovers. Refused (no charge) if rain is already falling or
        // the XP gauges can't cover the cost. Returns the updated equipment payload + {ok}
        // so the page's gauges refresh in place.
        if path == "/api/equipment/rain" {
            return DispatchQueue.main.sync {
                if self.director?.rainActive == true {
                    return "{\"ok\":false,\"error\":\"이미 폭우가 내리는 중입니다\"}"
                }
                guard self.equipment.spendXP(EquipmentStore.rainSummonCost) != nil else {
                    return "{\"ok\":false,\"error\":\"경험치가 부족합니다 (필요 \(EquipmentStore.rainSummonCost) XP)\"}"
                }
                ActionLog.shared.append(self.actionEvent("rainSummon",
                    detail: "경험치로 폭우 소환 (\(EquipmentStore.rainSummonCost) XP)"))
                self.director?.triggerRain()
                let base = self.equipmentJSON()
                if base.hasSuffix("}") {
                    return String(base.dropLast()) + ",\"ok\":true,\"spent\":\(EquipmentStore.rainSummonCost)}"
                }
                return base
            }
        }
        // Canonical music-mute control — the ONE endpoint every surface (dashboard mute dot, BGM
        // player, menu) posts to. {toggle:true} flips; {muted:bool} sets an explicit state. Source of
        // truth is session.isMuted; native output is synced from it and other webviews reconcile via
        // their poll. Returns the resulting {working,muted} so the caller can confirm.
        if path == "/api/session/mute" {
            return DispatchQueue.main.sync {
                if (obj["toggle"] as? Bool) == true { self.toggleMute() }
                else { self.setMutedRemote((obj["muted"] as? Bool) ?? self.session.isMuted) }
                return self.session.stateJSON
            }
        }
        // 효과음 스위치 (레일 설정 팝업의 '효과음'). 음소거와 나란한 세 번째 스위치로, 음악은
        // 그대로 두고 원샷 이펙트음만 끈다. {toggle:true}는 뒤집고 {on:bool}은 명시적으로 설정한다.
        // 값은 Settings에 남아 재실행에도 유지되고, 실제 침묵 여부는 applySfxGate가 음소거와
        // 합쳐 판정한다 — 그래서 응답에 두 값을 함께 실어 준다(effective = 지금 실제로 들리는가).
        if path == "/api/session/sfx" {
            return DispatchQueue.main.sync {
                let cur = Settings.shared.sfxEnabled
                let want = (obj["toggle"] as? Bool) == true ? !cur : ((obj["on"] as? Bool) ?? cur)
                if want != cur {
                    Settings.shared.sfxEnabled = want
                    ActionLog.shared.append(self.actionEvent(want ? "sfxOn" : "sfxOff",
                        detail: want ? "효과음 켬" : "효과음 끔"))
                    AppLog.log("sfx switch -> \(want) (muted=\(self.session.isMuted))")
                }
                self.applySfxGate()
                return "{\"ok\":true,\"sfx\":\(want),\"muted\":\(self.session.isMuted),"
                    + "\"effective\":\(!SoundEffects.shared.muted)}"
            }
        }
        // 받아쓰기 덕킹 스위치. 효과음 스위치와 같은 모양이다({toggle:true} 는 뒤집고 {on:bool} 은
        // 명시적으로 설정). 끄면 감시자 자체가 내려가므로 오른쪽 ⌘ 를 눌러도 아무 일도 일어나지
        // 않고, 눌려 있던 볼륨은 즉시 되돌아온다. ducking 은 "지금 이 순간 눌려 있는가"라서
        // 스위치(voiceDuck)와 다른 값이다 — 켜져 있어도 말하고 있지 않으면 false.
        if path == "/api/session/voiceduck" {
            return DispatchQueue.main.sync {
                let cur = Settings.shared.voiceDuckOn
                let want = (obj["toggle"] as? Bool) == true ? !cur : ((obj["on"] as? Bool) ?? cur)
                if want != cur {
                    Settings.shared.voiceDuckOn = want
                    ActionLog.shared.append(self.actionEvent(want ? "voiceDuckOn" : "voiceDuckOff",
                        detail: want ? "받아쓰기 덕킹 켬" : "받아쓰기 덕킹 끔"))
                    AppLog.log("voice-duck switch -> \(want)")
                }
                self.applyVoiceDuckSwitch()
                return "{\"ok\":true,\"voiceDuck\":\(want),\"ducking\":\(self.voiceDucked)}"
            }
        }
        // Switch the app window between the dashboard and the full condition (BGM) surface. Driven by
        // the rail's condition popup ("시스템관리") and the BGM page's "← 대시보드" back button —
        // these replace the old titlebar segmented toggle. The two-webview switch is seamless and the
        // BGM webview keeps playing throughout (audio untouched).
        if path == "/api/window/mode" {
            let mode = (obj["mode"] as? String) ?? ""
            DispatchQueue.main.sync {
                if mode == "condition" || mode == "bgm" { self.openBGMWindow() } else { self.openDashboard() }
            }
            return "{\"ok\":true}"
        }
        // 폭우 리셋 manual trigger — normally the director summons it from activity, but
        // this lets QA and the user preview it on demand. {action:"start"} forces a rain
        // reset now (bypassing eligibility + daily limit); {action:"stop"} ends it early.
        // Require an EXPLICIT valid action so a malformed/empty body can't accidentally
        // summon rain (it would otherwise fall through to the default and start).
        if path == "/api/bgm/rain" {
            guard let action = obj["action"] as? String, action == "start" || action == "stop" else {
                return "{\"ok\":false,\"error\":\"action must be start|stop\"}"
            }
            DispatchQueue.main.sync {
                ActionLog.shared.append(self.actionEvent("rainSummon",
                    detail: action == "stop" ? "폭우 수동 종료" : "폭우 수동 시작"))
                self.director?.triggerRain(stop: action == "stop")
            }
            return "{\"ok\":true}"
        }
        // 전략7 장소·컨디션 선택 — the user's one-tap "where am I / how do I feel".
        // Persists via Settings (settings.json) so the last pick survives restarts and
        // updates; the director re-pools with an audible switch when music is live.
        if path == "/api/bgm/venue" {
            guard let key = obj["key"] as? String,
                  VenueContext.all.contains(where: { $0.key == key }) else {
                return "{\"ok\":false,\"error\":\"unknown venue key\"}"
            }
            DispatchQueue.main.sync {
                if let d = self.director { d.setVenue(key: key) }
                else { Settings.shared.bgmVenueKey = key }
            }
            return "{\"ok\":true,\"key\":\(jsonString(key))}"
        }
        // 전략3 plan-map replace — the 관리자 AI's safe write path (agents never edit
        // bgm-plan.json directly, mirroring the goals convention). The body is the full
        // plan JSON; it is validated before committing. Unknown theme folders are
        // accepted (the library falls back rather than going silent) but reported so
        // the planner can correct them.
        if path == "/api/bgm/plan" {
            guard let data = body.data(using: .utf8), !data.isEmpty else {
                return "{\"ok\":false,\"error\":\"empty body\"}"
            }
            do {
                let (plan, known): (BGMPlanMap.Plan, Set<String>) = try DispatchQueue.main.sync {
                    let p = try self.bgmPlan.replace(jsonData: data)
                    self.director?.planDidChange()
                    return (p, Set(self.library.tracks.map(\.theme)))
                }
                let unknown = Set(plan.slots.flatMap(\.themes)).subtracting(known).sorted()
                let unkJSON = "[" + unknown.map { jsonString($0) }.joined(separator: ",") + "]"
                return "{\"ok\":true,\"slots\":\(plan.slots.count),\"unknownThemes\":\(unkJSON)}"
            } catch {
                return "{\"ok\":false,\"error\":\(jsonString(error.localizedDescription))}"
            }
        }
        // Clear the per-track play-time history (BGM 관리 "재생 시간 순위" 초기화 버튼).
        // {strategy:N} resets only that strategy's rows (the ranking filter's selection);
        // {strategy:0} or no body resets every strategy. The strategy catalog survives.
        if path == "/api/bgm/stats/reset" {
            let n = (obj["strategy"] as? Int) ?? 0
            DispatchQueue.main.sync { self.trackPlayStats.reset(strategy: n == 0 ? nil : n) }
            return "{\"ok\":true}"
        }
        // Reveal the skills folder (or one skill's folder) in Finder. Pure side effect
        // (no model, no goal state), so it is safe to handle here off-main.
        if path == "/api/skills/reveal" {
            return revealSkill(name: (obj["name"] as? String) ?? "")
        }
        // Agents page: reveal the official agent's .md file in ~/.claude/agents/. 에이전트
        // 페이지는 전역 폴더 밖(프로젝트/스킬)의 정의도 열어야 하므로 절대 경로도 받는다.
        // 이슈 상세의 [폴더 열기]. 위임 카드에서 파싱해 낸 경로만 연다 — 호출자가 준 문자열을
        // 그대로 믿으면 루프백 대시보드가 임의 파일 열람 통로가 된다. revealAgentPath 와 같은
        // 허용 목록 대조 패턴이고, 목록 밖은 unknown-path 로 거절한다.
        if path == "/api/issues/reveal" {
            return revealWorkQueuePath(((obj["path"] as? String) ?? ""))
        }
        // 이슈 상세의 [Orca 로 열기]. 결과물이 마음에 안 들 때 그 자리에서 Orca 로 넘어가
        // 버전을 올리기 위한 것이다. 넘어가는 것은 카드 키 하나뿐이고, 작업 폴더와 창 제목은
        // 서버가 카드에서 스스로 만든다 — reveal 과 같은 이유로 웹뷰 문자열은 셸에 안 닿는다.
        // 이슈 상세의 md 팝업이 고친 본문을 저장하는 자리. 읽기(GET /api/issues/mdfile)와 **같은
        // 검증 함수**를 통과한다 — 쓰기만 느슨하면 임의 파일 쓰기 통로가 된다.
        if path == "/api/issues/mdsave" {
            return workQueueMarkdownWrite(path: (obj["path"] as? String) ?? "",
                                          text: (obj["text"] as? String) ?? "")
        }
        if path == "/api/issues/orca" {
            return IssueOrcaLauncher.launch(key: (obj["path"] as? String) ?? (obj["key"] as? String) ?? "")
        }
        // 보관과 보관 해제. 아카이브는 상태값이 아니라 별도의 축이라 카드 파일에 쓰지 않고
        // 앱 자기 폴더의 archive.json 에만 남는다 — 큐 폴더는 읽기 전용이다.
        if path == "/api/issues/archive"   { return IssueArchiveStore.archive(key: (obj["path"] as? String) ?? "") }
        if path == "/api/issues/unarchive" { return IssueArchiveStore.unarchive(key: (obj["path"] as? String) ?? "") }
        // 일괄 보관. 무엇을 치울지는 화면이 정해 키 목록으로 보낸다 — 서버가 "전부" 를 스스로
        // 정하면 라이언이 방금 필터로 좁혀 놓은 것을 무시하게 된다.
        if path == "/api/issues/archive-bulk" {
            return IssueArchiveStore.archiveMany(keys: (obj["paths"] as? [String]) ?? [])
        }
        // AI 검색을 **시작만** 한다. 여기서 모델을 기다리면 대시보드 서버의 직렬 큐가 그동안
        // 통째로 멈춰서 다른 페이지까지 같이 선다. 결과는 GET /api/issues/search?id=... 로 받는다.
        if path == "/api/issues/search" {
            return IssueSearch.start(query: (obj["q"] as? String) ?? "")
        }
        if path == "/api/agents/reveal" {
            let p = ((obj["path"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { return revealAgentPath(p) }
            return revealAgent(file: (obj["file"] as? String) ?? "")
        }
        // 에이전트 판정 기록 (목적 달성 / 교체 필요). 새 인벤토리를 그대로 돌려준다.
        if path == "/api/agents/verdict" {
            return setAgentVerdict(path: (obj["path"] as? String) ?? "",
                                   state: (obj["state"] as? String) ?? "",
                                   reason: (obj["reason"] as? String) ?? "")
        }
        // 교체 위임 — 이 에이전트를 고쳐 쓸 goal 세션을 만들고 첫 턴 프롬프트를 돌려준다.
        if path == "/api/agents/replace" {
            return delegateAgentReplacement(path: (obj["path"] as? String) ?? "",
                                            reason: (obj["reason"] as? String) ?? "")
        }
        // Save the user-edited one-line summary into the skill's SKILL.md. Pure file I/O.
        if path == "/api/skills/summary" {
            return setSkillSummary(folder: (obj["folder"] as? String) ?? "",
                                   summary: (obj["summary"] as? String) ?? "")
        }
        // Change (or reset) the skills base folder. Pure settings + directory scan.
        if path == "/api/skills/folder" {
            return setSkillsFolder(folder: (obj["folder"] as? String) ?? "")
        }
        // Native folder picker for the skills base folder (opens on main).
        if path == "/api/skills/folder/pick" {
            return pickSkillsFolder()
        }
        // 이슈 폴더 (rail ⚙️설정) — where a delegation issue file is created. Blank resets to
        // the default (the folder the agent was invoked in). Both return the refreshed
        // /api/settings/paths payload so the panel re-renders from one round-trip.
        if path == "/api/settings/issue-folder" {
            return setIssueFolder(folder: (obj["folder"] as? String) ?? "")
        }
        if path == "/api/settings/issue-folder/pick" {
            return pickIssueFolder()
        }
        if path == "/api/settings/queue-folder" {
            return setQueueFolder(folder: (obj["folder"] as? String) ?? "")
        }
        if path == "/api/settings/queue-folder/pick" {
            return pickQueueFolder()
        }
        // Native folder picker for the 목표 추가 composer's 작업 폴더 (찾기 button). Modal on
        // main like pickSkillsFolder — a direct user action, so the brief block is fine.
        // Cancel returns ok:false and the composer keeps its current selection.
        if path == "/api/folders/pick" {
            var chosen: String?
            DispatchQueue.main.sync {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "선택"
                panel.message = "이 목표가 실행될 작업 폴더를 선택하세요"
                if panel.runModal() == .OK, let url = panel.url { chosen = url.path }
            }
            guard let p = chosen else { return "{\"ok\":false}" }
            let name = (p as NSString).lastPathComponent
            return "{\"ok\":true,\"path\":\(jsonString(p)),\"name\":\(jsonString(name))}"
        }
        // Semantic search across ALL goals (including archived/released). Runs an external
        // `claude -p` (seconds, blocking) — handle here off-main like aiAdd, never inside the
        // main.sync block, so the UI never freezes while the model searches.
        if path == "/api/goal/aiSearch" {
            return aiSemanticSearch(query: (obj["query"] as? String) ?? "")
        }
        // Chat send runs `claude -p` (seconds) — handle off-main for the same reason.
        if path == "/api/chat/send" {
            return chatSend(text: (obj["text"] as? String) ?? "",
                            images: (obj["images"] as? [[String: Any]]) ?? [],
                            model: (obj["model"] as? String) ?? "")
        }
        // Per-goal "목표 명확화" chat. Send runs `claude -p` (seconds); reset routes through
        // goalChat() which itself hops to main — both must stay OUTSIDE the main.sync block.
        if path == "/api/goal/chat/send" {
            let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
            return goalChatSend(seq: seq, text: (obj["text"] as? String) ?? "",
                                model: (obj["model"] as? String) ?? "")
        }
        if path == "/api/goal/chat/reset" {
            return goalChatReset(Scope.from(body: obj))
        }
        // Streaming chat (chat2): say spawns a streaming claude turn whose events go out
        // over the scope's SSE channel; stop terminates the running turn. Non-blocking.
        if path == "/api/goal/chat2/say" {
            return chat2Say(Scope.from(body: obj), text: (obj["text"] as? String) ?? "",
                            mode: (obj["mode"] as? String) ?? "bypassPermissions",
                            model: (obj["model"] as? String) ?? "",
                            allow: (obj["allow"] as? [String]) ?? [],
                            preset: (obj["preset"] as? String) ?? "",
                            images: (obj["images"] as? [[String: Any]]) ?? [],
                            modeOverride: (obj["modeOverride"] as? Bool) ?? false)
        }
        // 팀위임: mint a discussion goal for the pasted topic and hand its number back —
        // the rail then navigates to the goal page, which auto-sends the first chat2 turn
        // with preset:"team" (the team-lead multi-agent debate preamble). The goal itself
        // is a plain addGoal so the discussion is tracked like any other work.
        if path == "/api/team/delegate" {
            let text = ((obj["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
            let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? text
            let title = "팀토론: " + String(firstLine.prefix(60))
            // Carry the composer's execution settings onto the discussion goal so the team-kick
            // first turn (chat2Say → chat2RunTurn) runs with the chosen effort/mode/cwd.
            let exec = Self.composerExec(obj)
            let seq = DispatchQueue.main.sync {
                reviewStore.addGoal(text: title, effort: exec.effort, mode: exec.mode, cwd: exec.cwd,
                                    branch: exec.branch, model: exec.model)
            }
            guard seq > 0 else { return "{\"ok\":false,\"error\":\"create-failed\"}" }
            if let imgs = obj["images"] as? [[String: Any]], !imgs.isEmpty,
               let adir = IssuePaths.attachmentsDir(seq: seq) {
                let names = Self.saveComposerImages(imgs, into: adir)
                if !names.isEmpty { DispatchQueue.main.sync { reviewStore.setGoalExecSettings(seq: seq, images: names) } }
            }
            return "{\"ok\":true,\"seq\":\(seq)}"
        }
        // 계획: mint a planning goal for what the user wants to do and hand its number back —
        // the rail then navigates to the goal page, which auto-sends the first chat2 turn with
        // preset:"plan" (the planning-coach preamble: refine 문제정의/결과물/진행 순서/완료 기준
        // BEFORE any real work). The goal itself is a plain addGoal; once the plan is agreed the
        // user starts actual work on the same goal via GUI시작.
        if path == "/api/plan/delegate" {
            let text = ((obj["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
            let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? text
            let title = "계획: " + String(firstLine.prefix(60))
            let exec = Self.composerExec(obj)
            let seq = DispatchQueue.main.sync {
                reviewStore.addGoal(text: title, effort: exec.effort, mode: exec.mode, cwd: exec.cwd,
                                    branch: exec.branch, model: exec.model)
            }
            guard seq > 0 else { return "{\"ok\":false,\"error\":\"create-failed\"}" }
            return "{\"ok\":true,\"seq\":\(seq)}"
        }
        if path == "/api/goal/chat2/stop" {
            chat2Stop(Scope.from(body: obj))
            return "{\"ok\":true}"
        }
        // 세션 정보 tab (A안 메신저형): continue the scope's latest associated session /
        // stop that running turn. Events stream over &sess=1 (see sessionSay).
        if path == "/api/goal/session/say" {
            return sessionSay(Scope.from(body: obj), text: (obj["text"] as? String) ?? "",
                              mode: (obj["mode"] as? String) ?? "bypassPermissions",
                              allow: (obj["allow"] as? [String]) ?? [])
        }
        if path == "/api/goal/session/stop" {
            chat2Stop(Scope.from(body: obj), sess: true)
            return "{\"ok\":true}"
        }
        // Session link/unlink for a SUBTASK mutate its own ChatStore.linkedSessions. Handled
        // here off-main because chatStore(for:) hops to main internally (calling it inside the
        // main.sync block below would deadlock). Goal scope falls through to that block.
        if (path == "/api/goal/session/link" || path == "/api/goal/session/unlink"),
           case let scope = Scope.from(body: obj), scope.task != nil {
            let sid = (obj["sessionId"] as? String) ?? ""
            if path.hasSuffix("/link") { chatStore(for: scope)?.addLinked(sid) }
            else { chatStore(for: scope)?.removeLinked(sid) }
            return "{\"ok\":true}"
        }
        // Inline edit of a scope version: write the edited markdown straight to disk. Pure
        // file write — handle off-main like the other early returns above.
        if path == "/api/goal/definition/save" {
            return goalDefinitionSave(Scope.from(body: obj), kind: (obj["kind"] as? String) ?? "core",
                                      text: (obj["text"] as? String) ?? "")
        }
        // In-page interactive CLI: a real claude session in a PTY, bridged to the
        // dashboard's xterm.js terminal by polling. start spawns it; io ships keystrokes
        // and pulls new output; resize/stop manage its lifecycle.
        if path == "/api/goal/cli/start" {
            let cols = UInt16(clamping: (obj["cols"] as? NSNumber)?.intValue ?? 80)
            let rows = UInt16(clamping: (obj["rows"] as? NSNumber)?.intValue ?? 24)
            return cliStart(Scope.from(body: obj), cols: cols, rows: rows,
                            seed: (obj["text"] as? String) ?? "")
        }
        if path == "/api/goal/cli/io" {
            return cliIO(token: (obj["token"] as? String) ?? "",
                         inputB64: (obj["input"] as? String) ?? "",
                         since: (obj["since"] as? NSNumber)?.intValue ?? 0)
        }
        if path == "/api/goal/cli/resize" {
            cliResize(token: (obj["token"] as? String) ?? "",
                      cols: UInt16(clamping: (obj["cols"] as? NSNumber)?.intValue ?? 80),
                      rows: UInt16(clamping: (obj["rows"] as? NSNumber)?.intValue ?? 24))
            return "{\"ok\":true}"
        }
        if path == "/api/goal/cli/stop" {
            cliStop(token: (obj["token"] as? String) ?? "")
            return "{\"ok\":true}"
        }
        // AI추가 중복 확인 다이얼로그 안의 대화 한 턴: 목표를 AI와 상의해 다듬는다. claude 호출.
        if path == "/api/goal/aiChat" {
            return aiGoalChat(candidate: (obj["candidate"] as? String) ?? "",
                              matches: (obj["matches"] as? [[String: Any]]) ?? [],
                              history: (obj["history"] as? [[String: Any]]) ?? [],
                              message: (obj["message"] as? String) ?? "",
                              images: (obj["images"] as? [[String: Any]]) ?? [],
                              model: (obj["model"] as? String) ?? "")
        }
        // 큐 프롬프트 다듬기: 유저 프롬프트로 큐 항목을 다시 생성한다. claude 호출(수초, blocking)이라
        // main.sync 밖에서 처리한다. 성공 시 항목 텍스트+설명을 갱신하고 새 결과를 돌려준다.
        if path == "/api/goal/queue/refine" {
            let id = (obj["id"] as? String) ?? ""
            let prompt = (obj["prompt"] as? String) ?? ""
            guard !id.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "{\"ok\":false,\"error\":\"empty\"}"
            }
            // 항목 스냅샷: 현재 텍스트 + 유사 목표(첫 턴 컨텍스트) + 이어갈 세션 id (스레드 안전하게 main에서).
            let snap: (text: String, matches: [ReviewStore.QueueMatch], session: String)? = DispatchQueue.main.sync {
                guard let it = reviewStore.aiQueue.first(where: { $0.id == id }) else { return nil }
                return (it.text, it.matches, it.refineSession)
            }
            guard let s = snap else { return "{\"ok\":false,\"error\":\"not-found\"}" }
            let v = aiRefineGoal(current: s.text, matches: s.matches, prompt: prompt, resumeSession: s.session)
            guard v.ok else { return "{\"ok\":false,\"error\":\"unavailable\"}" }
            let saved = DispatchQueue.main.sync {
                reviewStore.refineQueueItem(id: id, text: v.text, note: v.note, session: v.session)
            }
            guard saved else { return "{\"ok\":false,\"error\":\"gone\"}" }
            return "{\"ok\":true,\"text\":\(jsonString(v.text)),\"note\":\(jsonString(v.note)),\"session\":\(jsonString(v.session))}"
        }
        // 큐 항목의 다듬기 세션을 터미널에서 `claude --resume`으로 바로 연다. 세션은 앱 cwd에서
        // 생성되므로 같은 cwd로 이동해 이어붙인다. 세션이 아직 없으면(첫 refine 전) 실패한다.
        if path == "/api/goal/queue/cli" {
            let id = (obj["id"] as? String) ?? ""
            guard !id.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
            let session: String? = DispatchQueue.main.sync {
                reviewStore.aiQueue.first(where: { $0.id == id })?.refineSession
            }
            guard let sess = session, !sess.isEmpty else { return "{\"ok\":false,\"error\":\"no-session\"}" }
            guard openClaudeResume(session: sess) else { return "{\"ok\":false,\"error\":\"launch-failed\"}" }
            return "{\"ok\":true,\"session\":\(jsonString(sess))}"
        }
        // Goal-to-goal LINK: promote the source to top-level and record source→target.
        // Separate sanctioned path from setParent (never nests). Custom JSON responses so
        // the client can distinguish self/not-found; hence an early return block, not the
        // default switch. See docs/specs/goal-link-and-generic-queue.md Phase 1.
        if path == "/api/goal/link" {
            let source = (obj["id"] as? String) ?? ""
            let target = (obj["target"] as? String) ?? ""
            guard !source.isEmpty, !target.isEmpty else { return "{\"ok\":false,\"error\":\"not-found\"}" }
            if source == target { return "{\"ok\":false,\"error\":\"self\"}" }
            return DispatchQueue.main.sync {
                let bothExist = reviewStore.goals.contains(where: { $0.id == source })
                    && reviewStore.goals.contains(where: { $0.id == target })
                guard bothExist else { return "{\"ok\":false,\"error\":\"not-found\"}" }
                reviewStore.linkGoal(id: source, to: target)
                return "{\"ok\":true}"
            }
        }
        if path == "/api/goal/unlink" {
            let source = (obj["id"] as? String) ?? ""
            let target = (obj["target"] as? String) ?? ""
            guard !source.isEmpty, !target.isEmpty else { return "{\"ok\":false,\"error\":\"not-found\"}" }
            return DispatchQueue.main.sync {
                guard reviewStore.goals.contains(where: { $0.id == source }) else {
                    return "{\"ok\":false,\"error\":\"not-found\"}"
                }
                reviewStore.unlinkGoal(id: source, from: target)
                return "{\"ok\":true}"
            }
        }
        if path == "/api/goal/transfer" {
            // 이관 API: mark a source goal as moved into another goal (optionally one of its
            // tasks) and rewrite the source's goal-core.md deterministically — the same
            // "[이관됨 → …]" report a human would hand-write, but with the destination emitted
            // as a REAL direct link. The single thing that must be perfect is that link:
            // clicking it lands straight on goal-<targetSeq>[·<targetTask>], not the parent
            // goal. That extracted link is returned as "link" so callers can act on it.
            return handleGoalTransfer(obj)
        }
        return DispatchQueue.main.sync { () -> String in
            let day = reviewStore.todayKey
            switch path {
            case "/api/goal/add":
                if let text = obj["text"] as? String {
                    let sprint = (obj["sprint"] as? NSNumber)?.intValue ?? Int((obj["sprint"] as? String) ?? "") ?? 0
                    let bump = (obj["bump"] as? NSNumber)?.boolValue ?? (obj["bump"] as? Bool) ?? false
                    // Execution settings chosen in the 목표 추가 composer, sanitized against the
                    // CLI's known values (an unknown value falls back to "" = leave default).
                    let exec = Self.composerExec(obj)
                    // A direct add lands as a real goal immediately. bump=true parks it in the
                    // Bump out 인박스 (raw idea, 정리 전) at the bottom of the board; bump=false
                    // creates a normal Backlog/Sprint goal. Neither routes through the AI 큐 —
                    // that background dedup pipeline is the AI추가 button's job (queue/enqueue),
                    // not a plain add. This keeps a dumped idea visible where the user put it
                    // instead of disappearing into the queue and resurfacing in Backlog.
                    let newSeq = reviewStore.addGoal(text: text, parent: (obj["parent"] as? String) ?? "",
                                        sprint: sprint, bump: bump,
                                        effort: exec.effort, mode: exec.mode, cwd: exec.cwd,
                                        branch: exec.branch, model: exec.model)
                    // Attachments: save the composer's images beside the new goal and record
                    // their filenames so the worker can Read them on the first turn.
                    if newSeq > 0, let imgs = obj["images"] as? [[String: Any]], !imgs.isEmpty,
                       let adir = IssuePaths.attachmentsDir(seq: newSeq) {
                        let names = Self.saveComposerImages(imgs, into: adir)
                        if !names.isEmpty { reviewStore.setGoalExecSettings(seq: newSeq, images: names) }
                    }
                    // The 목표 추가 page's 세션시작 needs the new goal's number to navigate
                    // to /goal?n=seq and fire the first AI turn; other callers ignore it.
                    return "{\"ok\":true,\"seq\":\(newSeq)}"
                }
            case "/api/chat/reset":
                chatStore.reset()
            case "/api/goal/queue/add":
                // "later": park a flagged candidate for one-by-one review instead of
                // adding it now (saves the energy of deciding right away).
                if let text = obj["text"] as? String {
                    let matches = (obj["matches"] as? [[String: Any]])?.map { m in
                        ReviewStore.QueueMatch(seq: (m["seq"] as? NSNumber)?.intValue ?? 0,
                                               text: (m["text"] as? String) ?? "",
                                               why: (m["why"] as? String) ?? "")
                    } ?? []
                    reviewStore.addQueueItem(text: text, parent: (obj["parent"] as? String) ?? "",
                                             note: (obj["note"] as? String) ?? "", matches: matches)
                }
            case "/api/goal/queue/enqueue":
                // "Bump out": instantly park a freshly-dumped candidate as pending and return
                // right away — the user never waits on the AI. The background worker analyzes
                // it and flips it to ready for a one-tap 추가/수정/스킵 decision.
                if let text = obj["text"] as? String {
                    let sprint = (obj["sprint"] as? NSNumber)?.intValue ?? Int((obj["sprint"] as? String) ?? "") ?? 0
                    // `search:true` → 찾기만 후보(findOnly): 같은 큐·같은 dedup 분석을 돌리되 결과는
                    // 비슷한 목표를 보여줄 뿐 목표를 만들지 않는다 (AI목표=찾고+만들기, 검색=찾기만).
                    let findOnly = (obj["search"] as? Bool) ?? false
                    // Execution settings ride the queue candidate; a findOnly (검색) item never
                    // becomes a goal, so its settings/images are moot and skipped.
                    let exec: (effort: String, mode: String, cwd: String, branch: String, model: String) = findOnly ? ("", "", "", "", "") : Self.composerExec(obj)
                    // `origin` carries the user's full raw prompt when the client has one
                    // richer than the goal line; the store defaults it to `text` otherwise.
                    if let qid = reviewStore.enqueuePending(text: text, parent: (obj["parent"] as? String) ?? "",
                                                  sprint: sprint, origin: obj["origin"] as? String,
                                                  findOnly: findOnly,
                                                  effort: exec.effort, mode: exec.mode, cwd: exec.cwd,
                                                  branch: exec.branch, model: exec.model) {
                        // Stage the composer's images under the candidate's pending folder; they
                        // move into goal-NN/attachments when it is promoted (resolveQueueItem).
                        if !findOnly, let imgs = obj["images"] as? [[String: Any]], !imgs.isEmpty,
                           let pdir = IssuePaths.pendingAttachmentsDir(id: qid) {
                            let names = Self.saveComposerImages(imgs, into: pdir)
                            if !names.isEmpty { reviewStore.setQueueItemImages(id: qid, images: names) }
                        }
                        kickAIQueueWorker()
                        // The goal-add tally tracks this candidate by id (status chip + inline edit).
                        return "{\"ok\":true,\"id\":\(jsonString(qid))}"
                    }
                }
            case "/api/goal/queue/edit":
                // "이번에 담김" inline edit: rewrite the candidate's text and re-run the dedup
                // analysis (tally chip flips 완료 → 진행중 → 완료). not-found once the item was
                // resolved/removed — the tally then falls back to editing the created goal's title.
                if let id = obj["id"] as? String, let text = obj["text"] as? String {
                    if reviewStore.editQueueItemText(id: id, text: text) {
                        kickAIQueueWorker()
                        return "{\"ok\":true}"
                    }
                    return "{\"ok\":false,\"error\":\"not-found\"}"
                }
            case "/api/goal/queue/resolve":
                // Resolve one queued candidate: add (promote to goal), task (file as a
                // 부분과제 folder under an existing goal — no new goal number), edit (rewrite
                // text, keep queued), or skip (drop). Every resolution is recorded in the
                // queue history (queue-history.json) so the user can audit / 번복 it.
                if let id = obj["id"] as? String {
                    if (obj["action"] as? String) == "task" {
                        // Recurring-round path: attach the candidate to goal #parentSeq as a
                        // tasks/<taskN> folder instead of minting a new goal (the old behavior
                        // created e.g. goal325 when the user expected a task — see history).
                        let pSeq = (obj["parentSeq"] as? NSNumber)?.intValue
                            ?? Int((obj["parentSeq"] as? String) ?? "") ?? 0
                        guard pSeq > 0, reviewStore.goals.contains(where: { $0.seq == pSeq }),
                              let item = reviewStore.aiQueue.first(where: { $0.id == id }) else {
                            return "{\"ok\":false,\"error\":\"bad-task-target\"}"
                        }
                        // Optional explicit folder name from the 검색→task 추가 flow (the rich
                        // task<N>_round<R>_<slug>_<W>w scheme, possibly user-edited). Empty → legacy naming.
                        let taskName = (obj["taskName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let folder = addSubtaskFolder(seq: pSeq, title: item.text, status: "",
                                                            coin: "", week: "", outputs: "",
                                                            explicitFolder: (taskName?.isEmpty == false) ? taskName : nil) else {
                            return "{\"ok\":false,\"error\":\"create-failed\"}"
                        }
                        reviewStore.resolveQueueItemAsTask(id: id, parentSeq: pSeq, taskFolder: folder)
                        return "{\"ok\":true,\"seq\":\(pSeq),\"task\":\(jsonString(folder)),\"asTask\":true}"
                    }
                    // parentSeq contract (must distinguish "key absent" from "explicit 0"):
                    //  - key absent            → sentinel -1 = "no override, accept AI suggestion"
                    //  - present, value 0      → explicit TOP-LEVEL override (ignore AI sub suggestion)
                    //  - present, value > 0    → explicit parent #seq
                    // priority (optional): USER override of the AI-suggested bucket.
                    let hasParentSeq = obj["parentSeq"] != nil && !(obj["parentSeq"] is NSNull)
                    let parentSeq: Int = hasParentSeq
                        ? ((obj["parentSeq"] as? NSNumber)?.intValue ?? Int((obj["parentSeq"] as? String) ?? "") ?? 0)
                        : -1
                    let priority = obj["priority"] as? String
                    let res = reviewStore.resolveQueueItem(id: id, action: (obj["action"] as? String) ?? "skip",
                                                           text: obj["text"] as? String, parentSeq: parentSeq,
                                                           priority: priority)
                    // Return the created goal's #seq plus the EFFECTIVE placement (the parent it
                    // actually attached under, and whether a requested sub-attach fell back to
                    // top-level because it would break the 1-level tree) so the client can show
                    // the right "열기" link / placement note.
                    if let r = res {
                        return "{\"ok\":true,\"seq\":\(r.seq),\"parentSeq\":\(r.parentSeq),"
                            + "\"parentFallback\":\(r.parentFallback)}"
                    }
                }
            case "/api/goal/queue/suggest-task-name":
                // 검색→task 추가 flow: propose a rich subtask folder name for candidate `id`
                // under goal #parentSeq (task<N>_round<R>_<slug>_<W>w). Synchronous — spawns a
                // short `claude -p` for the english slug (same precedent as queue/refine), so the
                // client shows a spinner while awaiting. The name is only a suggestion; creation
                // happens later via queue/resolve action=task with the (maybe edited) taskName.
                if let id = obj["id"] as? String {
                    let pSeq = (obj["parentSeq"] as? NSNumber)?.intValue
                        ?? Int((obj["parentSeq"] as? String) ?? "") ?? 0
                    guard pSeq > 0, reviewStore.goals.contains(where: { $0.seq == pSeq }),
                          let item = reviewStore.aiQueue.first(where: { $0.id == id }) else {
                        return "{\"ok\":false,\"error\":\"bad-task-target\"}"
                    }
                    let name = suggestTaskFolderName(parentSeq: pSeq, query: item.text)
                    return "{\"ok\":true,\"name\":\(jsonString(name))}"
                }
                return "{\"ok\":false,\"error\":\"bad-request\"}"
            case "/api/goal/queue/undo":
                // 번복: revert one queue-history decision. Removes what the decision created
                // (add → the goal, task → the tasks/<taskN> folder while still pristine) and
                // restores the snapshotted candidate to the queue as "ready" for re-review.
                if let hid = obj["id"] as? String {
                    guard let entry = reviewStore.queueHistoryEntry(id: hid), !entry.undone else {
                        return "{\"ok\":false,\"error\":\"not-found\"}"
                    }
                    if entry.action == "add", entry.seq > 0,
                       let g = reviewStore.goals.first(where: { $0.seq == entry.seq }) {
                        // Refuse when the goal grew children since — removeGoal cascades and
                        // would delete work the queue decision never created.
                        if reviewStore.goals.contains(where: { $0.parent == g.id }) {
                            return "{\"ok\":false,\"error\":\"has-children\"}"
                        }
                        var r = reviewStore.review(day)
                        r.notes.removeValue(forKey: g.id); r.contributions.removeValue(forKey: g.id)
                        reviewStore.saveReview(r, day: day)
                        reviewStore.removeGoal(id: g.id)
                        try? FileManager.default.removeItem(at: Self.evidenceDir(goalId: g.id))
                        if let adir = IssuePaths.attachmentsDir(seq: g.seq) {
                            try? FileManager.default.removeItem(at: adir)
                        }
                    }
                    if entry.action == "task", entry.seq > 0, !entry.taskFolder.isEmpty,
                       let tdir = IssuePaths.taskDir(seq: entry.seq, task: entry.taskFolder) {
                        // Only delete while the folder still holds nothing but our _task.md
                        // anchor — never remove files the user added after the decision.
                        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tdir.path)) ?? []
                        if contents.allSatisfy({ $0 == "_task.md" || $0 == ".DS_Store" }) {
                            try? FileManager.default.removeItem(at: tdir)
                        }
                    }
                    if reviewStore.undoQueueDecision(id: hid) != nil { return "{\"ok\":true}" }
                    return "{\"ok\":false,\"error\":\"not-found\"}"
                }
            case "/api/queue/retry":
                // Re-run a failed/finished queue job: clear its error, flip to pending, kick
                // the worker. Used by the 재시도 button on a non-dedup job card.
                if let id = obj["id"] as? String, reviewStore.retryQueueItem(id: id) {
                    kickAIQueueWorker()
                    return "{\"ok\":true}"
                }
                return "{\"ok\":false,\"error\":\"not-found\"}"
            case "/api/queue/remove":
                // Drop a finished job card from the queue. Guarded in the store: never removes
                // an item still "analyzing" (the worker holds it).
                if let id = obj["id"] as? String, reviewStore.removeQueueItem(id: id) {
                    return "{\"ok\":true}"
                }
                return "{\"ok\":false,\"error\":\"not-found\"}"
            case "/api/queue/enqueue-linkmap":
                // Phase 3: "내보내기" enqueues a background linkmap job scoped to ONE root goal's
                // link chain (fire-and-forget). The worker builds the node-link map + link-aware
                // export off-main and posts the result as a 큐 card. Returns immediately.
                if let root = obj["root"] as? String,
                   let g = reviewStore.goals.first(where: { $0.id == root }) {
                    let title = "내보내기 · goal-\(String(format: "%02d", g.seq))"
                    if let jid = reviewStore.enqueueJob(jobKind: "linkmap", title: title, origin: root) {
                        kickAIQueueWorker()
                        return "{\"ok\":true,\"id\":\(jsonString(jid))}"
                    }
                }
                return "{\"ok\":false,\"error\":\"not-found\"}"
            case "/api/goal/remove":
                if let id = obj["id"] as? String {
                    // Clean up notes/contributions for the goal and its children.
                    let removed = Set([id] + reviewStore.goals.filter { $0.parent == id }.map { $0.id })
                    // Capture numbers before removal so we can locate attachment folders after.
                    let removedSeqs = reviewStore.goals.filter { removed.contains($0.id) }.map { $0.seq }
                    var r = reviewStore.review(day)
                    removed.forEach { r.notes.removeValue(forKey: $0); r.contributions.removeValue(forKey: $0) }
                    reviewStore.saveReview(r, day: day)
                    reviewStore.removeGoal(id: id)
                    // Drop attached files for the removed goal(s): the legacy UUID store and
                    // the number-named folder's attachments/. The definition (goal.md) is kept.
                    removed.forEach { try? FileManager.default.removeItem(at: Self.evidenceDir(goalId: $0)) }
                    removedSeqs.forEach { seq in
                        if let dir = IssuePaths.attachmentsDir(seq: seq) {
                            try? FileManager.default.removeItem(at: dir)
                        }
                    }
                }
            case "/api/goal/note":
                if let id = obj["id"] as? String {
                    var r = reviewStore.review(day)
                    r.notes[id] = (obj["note"] as? String) ?? ""
                    reviewStore.saveReview(r, day: day)
                }
            case "/api/goal/parent":
                // Single (id) or bulk (ids) — the board's Cmd-drag fill-down sends a whole
                // column of ids at once so it commits in one save.
                // A subtask can't itself be a parent (flat 1-level tree). If the requested
                // parent is a subtask (e.g. user typed a done sub-goal's #seq into 부모#),
                // redirect to its top-level ancestor so the attach lands on the GROUP instead
                // of silently reverting. Empty parent ("") = detach; leave it as-is.
                let rawParent = (obj["parent"] as? String) ?? ""
                let parentId = rawParent.isEmpty ? "" : reviewStore.topLevelAncestorId(of: rawParent)
                if let ids = obj["ids"] as? [String] {
                    reviewStore.setParent(ids: ids, parent: parentId)
                } else if let id = obj["id"] as? String {
                    reviewStore.setParent(id: id, parent: parentId)
                }
                // Remember what the user files things under, so the dropdown's 최근 사용 list
                // reflects real habits. Detach ("") records nothing.
                if !parentId.isEmpty,
                   let pseq = reviewStore.goals.first(where: { $0.id == parentId })?.seq {
                    Settings.shared.noteParentUse(pseq)
                }
                psugInvalidate()
            case "/api/goal/parent-suggest/refresh":
                // Force a recompute (debug / after editing titles outside the app).
                psugInvalidate()
            case "/api/goal/reorder":
                if let order = obj["order"] as? [String] {
                    reviewStore.reorderGoals(order: order)
                }
            case "/api/goal/status":
                if let id = obj["id"] as? String, let status = obj["status"] as? String {
                    reviewStore.setStatus(id: id, status: status)
                }
            case "/api/goal/archive":
                // 보관 / 보관 해제 toggle. archived=true stows the goal (and its children)
                // out of the active views into the 아카이브 view; false brings it back.
                if let id = obj["id"] as? String {
                    let archived = (obj["archived"] as? Bool)
                        ?? ((obj["archived"] as? NSNumber)?.boolValue ?? true)
                    reviewStore.setArchived(id: id, archived: archived)
                }
            case "/api/goal/rail/archive":
                // 세션 레일 오른쪽 메뉴의 "보관" — 이 goal을 완료 처리(done)하고 보관하여
                // 레일의 세 소스(라이브 PTY · 진행 중 · 보는 중)에서 모두 사라지게 한다.
                // 레일은 goal 번호(seq)만 가지고 있으므로 seq로 동작한다.
                let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
                if seq > 0, let g = reviewStore.goals.first(where: { $0.seq == seq }) {
                    reviewStore.setStatus(id: g.id, status: "done")     // 완료 처리
                    reviewStore.setArchived(id: g.id, archived: true)   // 보관
                    // 보는 중 도장 제거: 이 goal이 현재 활성(보는 중)이면 마커도 걷어내
                    // 완료했는데도 "보는 중"으로 레일에 남는 일을 막는다.
                    if Settings.shared.activeGoalSeq == seq {
                        Settings.shared.activeGoalSeq = nil
                        Settings.shared.activeGoalAt = nil
                    }
                    // 이 goal 산하의 task '보는 중' 행도 함께 걷어낸다(레일 잔상 방지).
                    Settings.shared.clearRecentTasks(seq: seq)
                    // 라이브 터미널이 붙어 있으면 종료해 레일에서 완전히 사라지게 한다.
                    cliStopBySeq(seq)
                    return "{\"ok\":true}"
                }
                return "{\"ok\":false,\"error\":\"not-found\"}"
            case "/api/goal/reopen":
                // 목표 검색 → 다시 열기: pull ONE goal back to backlog regardless of how
                // it left (done / cancelled / released). Release records stay immutable.
                if let id = obj["id"] as? String {
                    reviewStore.reopenGoal(id: id)
                }
            case "/api/goal/title":
                // Rename a goal from the dashboard. For a session-mirrored goal, also
                // append the new title to its transcript so the session hook honors it
                // over Claude's auto aiTitle (otherwise the next event overwrites it).
                if let id = obj["id"] as? String, let title = obj["title"] as? String {
                    if let g = reviewStore.setGoalTitle(id: id, title: title), !g.sessionId.isEmpty {
                        writeTitleOverride(for: g, title: g.text)
                    }
                }
            case "/api/goal/task":
                // Add a 부분과제 (subtask) under an existing goal (goal-NN/tasks/taskN-…) instead
                // of spawning a brand-new goal — e.g. a 주보상 패키지 becomes a task on goal-130.
                // Called by the goal page's "+ 태스크 추가" form AND directly by an AI so tasks
                // can be filed with or without the user. Auto-numbers taskN and writes a
                // _task.md anchor with whatever metadata was supplied.
                let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
                let title = ((obj["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if seq > 0, !title.isEmpty {
                    if let folder = addSubtaskFolder(
                        seq: seq, title: title,
                        status: (obj["status"] as? String) ?? "",
                        coin: Self.numString(obj["coin"]), week: Self.numString(obj["week"]),
                        outputs: (obj["outputs"] as? String) ?? "") {
                        let id = folder.split(separator: "-").first.map(String.init) ?? folder
                        return "{\"ok\":true,\"seq\":\(seq),\"id\":\(jsonString(id)),\"task\":\(jsonString(folder))}"
                    }
                    return "{\"ok\":false,\"error\":\"create-failed\"}"
                }
                return "{\"ok\":false,\"error\":\"bad-request\"}"
            case "/api/session/event":
                // Driven by Claude Code session hooks (see Scripts/cc-session-hook.sh).
                // event: start | active | idle | end. The goal is keyed by sessionId
                // and auto-created on first event, so no goal id is required.
                if let sid = obj["sessionId"] as? String {
                    let event = (obj["event"] as? String) ?? "start"
                    reviewStore.recordSession(sessionId: sid, event: event,
                                              text: (obj["text"] as? String) ?? "",
                                              transcriptPath: (obj["transcriptPath"] as? String) ?? "",
                                              waitKind: (obj["waitKind"] as? String) ?? "")
                }
            case "/api/goal/connect":
                // Open a native file picker (default: the current Claude session folder)
                // so the user can attach a transcript .jsonl to this goal. Runs async on
                // the next main-loop turn so the HTTP response returns immediately; the
                // dashboard's poll (and the client's follow-up reloads) pick up the link.
                if let id = obj["id"] as? String {
                    DispatchQueue.main.async { [weak self] in self?.connectSessionViaPicker(goalId: id) }
                }
            case "/api/goal/session/link":
                // Attach an extra session id to this goal (the goal page's "세션 연결" picker).
                // A subtask scope is handled off-main in the early return above.
                let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
                reviewStore.linkGoalSession(seq: seq, sessionId: (obj["sessionId"] as? String) ?? "")
            case "/api/goal/session/unlink":
                let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
                reviewStore.unlinkGoalSession(seq: seq, sessionId: (obj["sessionId"] as? String) ?? "")
            case "/api/plugin/connect":
                // Open a native folder picker so the user can attach a project folder to
                // the plugin. Runs async on the next main-loop turn so the HTTP response
                // returns immediately; the dashboard poll picks up the verified result.
                if let id = obj["id"] as? String {
                    DispatchQueue.main.async { [weak self] in self?.connectPluginViaPicker(pluginId: id) }
                }
            case "/api/plugin/disconnect":
                if let id = obj["id"] as? String { pluginStore.disconnect(pluginId: id); syncPluginWorkers() }
            case "/api/plugin/verify":
                if let id = obj["id"] as? String { pluginStore.reverify(pluginId: id); syncPluginWorkers() }
            case "/api/plugin/install":
                // Toggle plugins (e.g. 컨디션 메이트): install IS the connection — no folder.
                if let id = obj["id"] as? String { pluginStore.install(pluginId: id); syncPluginWorkers() }
            case "/api/plugin/uninstall":
                if let id = obj["id"] as? String { pluginStore.uninstall(pluginId: id); syncPluginWorkers() }
            case "/api/draw/enabled":
                // 드로우 card's draw on/off sub-switch. Persist + resync so the overlay
                // poller starts/stops immediately (turning off also wipes the canvas).
                Settings.shared.drawEnabled = (obj["on"] as? NSNumber)?.boolValue ?? false
                syncPluginWorkers()
            case "/api/camera/enabled":
                // 카메라 지킴이 card's on/off sub-switch (default on). Persist + resync so
                // the guard starts/stops immediately without uninstalling the plugin.
                Settings.shared.cameraGuardOn = (obj["on"] as? NSNumber)?.boolValue ?? true
                syncPluginWorkers()
            case "/api/camera/recover":
                // 감지를 기다리지 않고 자동 재활성화 한 번을 지금 쏜다 (시연/QA용). 폴러가
                // 쓰는 것과 같은 경로를 그대로 부른다 — 시연 전용 경로를 따로 두지 않는다.
                cameraWatch.attemptRecovery(reason: "수동 트리거 (POST /api/camera/recover)")
            case "/api/draw/clear":
                // Programmatic wipe (QA/debug parity with the left-⌃ gesture).
                drawOverlay.clear()
            case "/api/goal/energy":
                if let id = obj["id"] as? String, let e = (obj["energy"] as? NSNumber)?.intValue {
                    reviewStore.setEnergy(id: id, energy: e)
                }
            case "/api/goal/agents":
                if let id = obj["id"] as? String {
                    // Accept either a pre-split array or a comma/space-separated string.
                    let list: [String]
                    if let arr = obj["agents"] as? [String] {
                        list = arr
                    } else if let s = obj["agents"] as? String {
                        list = s.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                    } else {
                        list = []
                    }
                    reviewStore.setAgents(id: id, agents: list)
                }
            case "/api/goal/tokens":
                if let id = obj["id"] as? String, let t = (obj["tokens"] as? NSNumber)?.intValue {
                    reviewStore.setTokens(id: id, tokens: t)
                }
            case "/api/goal/value":
                if let id = obj["id"] as? String, let v = (obj["value"] as? NSNumber)?.intValue {
                    reviewStore.setValue(id: id, value: v)
                }
            case "/api/goal/priority":
                // Set 5-level priority. Accepts a batch ("ids":[...]) from the board's
                // Cmd-drag paint, or a single "id" from the click picker.
                if let p = obj["priority"] as? String {
                    if let ids = obj["ids"] as? [String] {
                        reviewStore.setGoalPriority(ids: ids, priority: p)
                    } else if let id = obj["id"] as? String {
                        reviewStore.setGoalPriority(ids: [id], priority: p)
                    }
                }
            case "/api/goal/target":
                // Set/clear the planned target datetime (epoch seconds; 0/absent = clear).
                if let id = obj["id"] as? String {
                    reviewStore.setTargetAt(id: id, date: Self.parseEpoch(obj["target"]))
                }
            case "/api/goal/completed":
                // Manually set/clear the completion datetime, overriding the auto-stamp.
                if let id = obj["id"] as? String {
                    reviewStore.setCompletedAt(id: id, date: Self.parseEpoch(obj["completed"]))
                }
            case "/api/goal/sprint":
                // Assign a goal's sprint number (0/absent = clear -> backlog).
                if let id = obj["id"] as? String {
                    let n = (obj["sprint"] as? NSNumber)?.intValue
                        ?? Int((obj["sprint"] as? String) ?? "") ?? 0
                    reviewStore.setGoalSprint(id: id, sprint: n)
                }
            case "/api/goal/bump":
                // Move a numbered goal into (bump=true) or out of (bump=false) the Bump out
                // 인박스. The goal keeps its unique seq either way, so demotion is safe.
                if let id = obj["id"] as? String {
                    let bump = (obj["bump"] as? NSNumber)?.boolValue ?? (obj["bump"] as? Bool) ?? false
                    reviewStore.setGoalBump(id: id, bump: bump)
                }
            case "/api/sprint/create":
                reviewStore.createSprint(goalText: (obj["goalText"] as? String) ?? "",
                                         durationKind: (obj["durationKind"] as? String) ?? "1d")
            case "/api/sprint/update":
                if let n = (obj["number"] as? NSNumber)?.intValue ?? Int((obj["number"] as? String) ?? "") {
                    // Date args use Date?? semantics: key absent = leave alone; present = set/clear.
                    let startAt: Date?? = obj.keys.contains("startAt") ? Optional(Self.parseEpoch(obj["startAt"])) : nil
                    let targetAt: Date?? = obj.keys.contains("targetAt") ? Optional(Self.parseEpoch(obj["targetAt"])) : nil
                    reviewStore.updateSprint(number: n,
                                             code: obj["code"] as? String,
                                             goalText: obj["goalText"] as? String,
                                             durationKind: obj["durationKind"] as? String,
                                             startAt: startAt, targetAt: targetAt)
                }
            case "/api/sprint/delete":
                if let n = (obj["number"] as? NSNumber)?.intValue ?? Int((obj["number"] as? String) ?? "") {
                    reviewStore.deleteSprint(number: n)
                }
            case "/api/sprint/cleanup":
                // Collapse duplicate empty open sprints (see ReviewStore.cleanupSprints).
                reviewStore.cleanupSprints()
            case "/api/sprint/release":
                // Commit the finished work of a sprint. sprint "all"/absent = across all
                // sprints; otherwise the given number. Done+unreleased goals are snapshotted.
                let sprint: Int?
                if let s = obj["sprint"] as? String, s == "all" { sprint = nil }
                else if let n = (obj["sprint"] as? NSNumber)?.intValue { sprint = n }
                else if let s = obj["sprint"] as? String, let n = Int(s) { sprint = n }
                else { sprint = nil }
                reviewStore.releaseSprint(sprint)
            case "/api/sprint/complete":
                // Complete a sprint: commit done goals, close it, and only when unfinished
                // goals remain carry them into the earliest open sprint (or a fresh auto one).
                if let n = (obj["number"] as? NSNumber)?.intValue ?? Int((obj["number"] as? String) ?? "") {
                    reviewStore.completeSprint(n)
                }
            case "/api/release/restore":
                // Bring a release's committed goals back into the active list.
                if let id = obj["id"] as? String {
                    reviewStore.restoreRelease(id: id)
                }
            case "/api/release/update":
                // Edit a 완료 로그 entry: alias (code) + real covered period (started/released).
                if let id = obj["id"] as? String {
                    let startedAt: Date?? = obj.keys.contains("startedAt") ? Optional(Self.parseEpoch(obj["startedAt"])) : nil
                    let releasedAt: Date?? = obj.keys.contains("releasedAt") ? Optional(Self.parseEpoch(obj["releasedAt"])) : nil
                    reviewStore.updateRelease(id: id, code: obj["code"] as? String,
                                              startedAt: startedAt, releasedAt: releasedAt)
                }
            case "/api/goal/evidence/add":
                // A subtask scope (task set) has no Goal: write the uploaded file straight
                // into its own attachments/ folder. The link kind is goal-only.
                let evScope = Scope.from(body: obj)
                if evScope.task != nil {
                    if (obj["kind"] as? String) == "file", let dataURL = obj["data"] as? String,
                       let raw = Self.decodeDataURL(dataURL), let dir = evScope.attachmentsDir {
                        let name = Self.sanitizeFilename((obj["filename"] as? String) ?? "file")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try? raw.write(to: dir.appendingPathComponent(name), options: .atomic)
                    }
                } else if let id = obj["id"] as? String {
                    let kind = (obj["kind"] as? String) ?? "link"
                    if kind == "file", let dataURL = obj["data"] as? String,
                       let raw = Self.decodeDataURL(dataURL) {
                        // Copy the upload into the goal's number-named folder
                        // (.issue/goal-NN/attachments); fall back to the legacy
                        // UUID-keyed store when the goal has no number yet (seq <= 0).
                        let name = Self.sanitizeFilename((obj["filename"] as? String) ?? "file")
                        let evId = UUID().uuidString
                        let dir = attachmentsDir(forGoalId: id) ?? Self.evidenceDir(goalId: id)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        // Prefix with the evidence id so duplicate file names never collide.
                        let stored = evId + "-" + name
                        if (try? raw.write(to: dir.appendingPathComponent(stored), options: .atomic)) != nil {
                            _ = reviewStore.addEvidence(goalId: id, kind: "file", title: name,
                                                        filename: stored)
                        }
                    } else if kind == "link", let url = obj["url"] as? String {
                        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !u.isEmpty {
                            let raw = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let title = (raw?.isEmpty == false) ? raw! : u
                            _ = reviewStore.addEvidence(goalId: id, kind: "link", title: title, url: u)
                        }
                    }
                }
            case "/api/goal/evidence/remove":
                // A subtask removes the named file from its attachments/ folder (the client
                // passes the bare filename as evidenceId for task scope).
                let rmScope = Scope.from(body: obj)
                if rmScope.task != nil {
                    if let name = obj["evidenceId"] as? String, let dir = rmScope.attachmentsDir {
                        let safe = Self.sanitizeFilename(name)
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent(safe))
                    }
                } else if let id = obj["id"] as? String, let evId = obj["evidenceId"] as? String {
                    if let removed = reviewStore.removeEvidence(goalId: id, evidenceId: evId),
                       removed.kind == "file" {
                        // Remove from whichever store holds it (new number-named folder
                        // and/or the legacy UUID store).
                        if let dir = attachmentsDir(forGoalId: id) {
                            try? FileManager.default.removeItem(at: dir.appendingPathComponent(removed.filename))
                        }
                        try? FileManager.default.removeItem(
                            at: Self.evidenceDir(goalId: id).appendingPathComponent(removed.filename))
                    }
                }
            case "/api/review":
                var r = reviewStore.review(day)
                if let s = (obj["selfScore"] as? NSNumber)?.intValue { r.selfScore = s }
                if let c = obj["contributions"] as? [String: Any] {
                    r.contributions = c.compactMapValues { ($0 as? NSNumber)?.intValue }
                }
                r.submittedSelf = true
                reviewStore.saveReview(r, day: day)
            case "/api/worker/ping":
                // External workers (e.g. the QA agent launched by launchd) report a run
                // here so the dashboard's 워커 상태 row reflects reality. recordRun/Error
                // both no-op for an unregistered id, so only declared workers count.
                //   status "error" -> red 오류 badge + error-level log line
                //   anything else  -> clear any error, stamp a healthy run + log line
                if let id = obj["id"] as? String {
                    let status = (obj["status"] as? String) ?? "ok"
                    let why = (obj["why"] as? String) ?? "외부 워커 보고"
                    let effect = (obj["effect"] as? String) ?? ""
                    if status == "error" {
                        WorkerRegistry.shared.recordError(id, why: why, detail: effect)
                    } else if status == "start" {
                        // In-progress signal: log only, no run-count bump. Lets a slow AI
                        // pass show activity immediately instead of looking idle until the
                        // result lands a minute or two later.
                        WorkerLog.shared.append(id, why: why, effect: effect)
                    } else {
                        WorkerRegistry.shared.clearError(id)
                        WorkerRegistry.shared.recordRun(id, why: why, effect: effect)
                    }
                }
            case "/api/worker/toggle":
                // User on/off for a toggleable QA worker. Writes the matching *-disabled
                // flag that the runner scripts read, and mirrors the state on the registry
                // so the row shows 꺼짐 immediately. Only the two QA workers are toggleable.
                if let id = obj["id"] as? String,
                   let flag = ["qa-agent": Self.qaDisabledFlag, "qa-fix": Self.qaFixDisabledFlag,
                               "bug-hunt": Self.bugHuntDisabledFlag,
                               "uxui-sitemap": Self.uxuiSitemapDisabledFlag,
                               "nss-report": Self.nssReportDisabledFlag,
                               "autobuild": Self.autobuildDisabledFlag,
                               "slack-eyes": Self.slackEyesDisabledFlag,
                               "jira-bridge": Self.jiraBridgeDisabledFlag][id] {
                    let name = ["qa-fix": "QA 수정", "bug-hunt": "버그 헌트",
                                "uxui-sitemap": "UXUI 관리",
                                "nss-report": "NSS 리포트",
                                "autobuild": "자동 빌드",
                                "slack-eyes": "Slack 번역",
                                "jira-bridge": "지라 번역"][id] ?? "QA 점검"
                    let enabled = (obj["enabled"] as? Bool) ?? ((obj["enabled"] as? NSNumber)?.boolValue ?? false)
                    WorkerRegistry.shared.setEnabled(id, enabled)
                    if enabled {
                        try? FileManager.default.removeItem(at: flag)
                        WorkerLog.shared.append(id, why: "사용자 토글", effect: "\(name) 켜짐")
                    } else {
                        try? Data().write(to: flag)
                        WorkerLog.shared.append(id, why: "사용자 토글", effect: "\(name) 꺼짐")
                    }
                    // 지라 브리지는 앱 안에서 도는 리스너라 플래그만 써두면 아무 일도
                    // 일어나지 않는다 — 여기서 실제로 포트를 열고 닫는다.
                    if id == "jira-bridge" {
                        if enabled { JiraBridge.shared.start() } else { JiraBridge.shared.stop() }
                    }
                }
            case "/api/slack/config":
                // 번역 모델 선택 — config.json에 기록, 데몬이 호출마다 읽는다.
                if let model = obj["model"] as? String,
                   ["auto", "gemini-flash-lite", "gemini-flash", "haiku-api", "haiku"].contains(model) {
                    let t0 = DispatchTime.now()
                    SlackTranslateStore.setModel(model)
                    SlackActionLog.log("config.model", ok: true,
                                       ms: SlackTranslateStore.ms(since: t0), detail: model)
                    return "{\"ok\":true}"
                }
                // 번역 목표 언어 — config.json {"lang": …}, 데몬이 호출마다 읽는다.
                // 이미 그 언어인 메시지는 번역하지 않는다 (원문 그대로).
                if let lang = obj["lang"] as? String,
                   ["ko", "en", "vi", "ja", "zh"].contains(lang) {
                    let t0 = DispatchTime.now()
                    SlackTranslateStore.setLang(lang)
                    SlackActionLog.log("config.lang", ok: true,
                                       ms: SlackTranslateStore.ms(since: t0), detail: lang)
                    return "{\"ok\":true}"
                }
                // 수집 기준 체크박스 — {"sources":{"eyes":…,"mention":…,"team":…}}
                // (부분 업데이트 가능). 해제된 소스는 데몬이 앞으로 수집하지 않는다.
                if let sources = obj["sources"] as? [String: Bool], !sources.isEmpty {
                    let t0 = DispatchTime.now()
                    SlackTranslateStore.setSources(sources)
                    let detail = sources.map { "\($0.key)=\($0.value ? "on" : "off")" }
                        .sorted().joined(separator: " ")
                    SlackActionLog.log("config.sources", ok: true,
                                       ms: SlackTranslateStore.ms(since: t0), detail: detail)
                    return "{\"ok\":true}"
                }
                // 빠른 리액션 버튼 목록 — 이모지 고르기 팝업의 '기본에 추가/빼기'.
                if let quick = obj["quick"] as? [String] {
                    let t0 = DispatchTime.now()
                    SlackTranslateStore.setQuick(quick)
                    SlackActionLog.log("config.quick", ok: true,
                                       ms: SlackTranslateStore.ms(since: t0),
                                       detail: quick.joined(separator: " "))
                    return "{\"ok\":true}"
                }
                SlackActionLog.log("config.model", ok: false, ms: 0, error: "bad model",
                                   detail: (obj["model"] as? String) ?? "")
                return "{\"ok\":false,\"error\":\"bad model\"}"
            case "/api/slack/speak":
                // 스피킹 시작 — 플러그인이 브리핑 조립 + 클립보드 + ChatGPT 열기까지 수행.
                return SlackTranslateStore.speakBriefing()
            case "/api/slack/reply":
                // Slack 번역함 스레드 답장 — 사용자가 페이지에서 직접 전송을 눌렀을
                // 때만 호출된다. 본인 계정(xoxp)으로 원 메시지 스레드에 그대로 전송.
                if let id = obj["id"] as? String, let text = obj["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // mention 기본 true — 원 작성자 <@멘션>을 붙여 알림이 가게 한다
                    // (페이지 체크박스로 해제 가능).
                    let mention = (obj["mention"] as? Bool)
                        ?? ((obj["mention"] as? NSNumber)?.boolValue ?? true)
                    return SlackTranslateStore.reply(id: id, text: text, mention: mention)
                }
                return "{\"ok\":false,\"error\":\"bad request\"}"
            case "/api/slack/gui/link":
                // GUI세션 연결 기록 — goal-add 가 이 메시지 컨텍스트로 목표를 만든 직후
                // (?slackId= 로 넘어온 id) 호출한다. 이후 번역함의 버튼은 "세션 이어가기"가
                // 되고 그 목표의 세션 뷰로 되돌아간다.
                if let id = obj["id"] as? String {
                    var seq = 0
                    if let n = obj["seq"] as? NSNumber { seq = n.intValue }
                    return SlackTranslateStore.linkGui(id: id, seq: seq)
                }
                return "{\"ok\":false,\"error\":\"bad request\"}"
            case "/api/slack/context":
                // 컨텍스트 공유하기 — 이 메시지가 놓인 원 대화(스레드 전체 + 채널 앞뒤)를
                // 슬랙에서 다시 긁어 목표 폴더에 문서로 남기고, 사용자가 적은 목표를
                // goal-core.md 에 박아 둔다. 세션은 그 두 파일을 읽고 대화를 이어간다.
                // 수집이 실패해도 ok:false 만 돌려준다 — 세션 시작 자체는 막지 않는다.
                if let id = obj["id"] as? String {
                    let seq = (obj["seq"] as? NSNumber)?.intValue ?? 0
                    return slackContextShare(id: id, seq: seq,
                                             goal: (obj["goal"] as? String) ?? "")
                }
                return "{\"ok\":false,\"error\":\"bad request\"}"
            case "/api/slack/reply/edit":
                // 내가 보낸 답장 수정 — chat.update로 슬랙 원문을 고치고 ledger 동기화.
                if let id = obj["id"] as? String, let ts = obj["ts"] as? String,
                   let text = obj["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return SlackTranslateStore.editReply(id: id, ts: ts, text: text)
                }
                return "{\"ok\":false,\"error\":\"bad request\"}"
            case "/api/slack/reply/delete":
                // 내가 보낸 답장 삭제 — chat.delete로 슬랙 메시지를 지우고 ledger에서 제거.
                // 수정 중 내용을 모두 비우고 저장해도 여기로 온다 (슬랙 UX 패리티).
                if let id = obj["id"] as? String, let ts = obj["ts"] as? String {
                    return SlackTranslateStore.deleteReply(id: id, ts: ts)
                }
                return "{\"ok\":false,\"error\":\"bad request\"}"
            case "/api/slack/reaction":
                // 항목 툴바의 빠른 리액션(✅·👀·👌)과 이모지 고르기 — 슬랙 원문에
                // 그대로 이모지를 달거나 뗀다. 처리완료와는 별개 액션이다
                // (처리완료의 ✅ 미러는 /api/slack/done → syncReaction 쪽).
                if let id = obj["id"] as? String, let name = obj["name"] as? String {
                    let on = (obj["on"] as? Bool) ?? ((obj["on"] as? NSNumber)?.boolValue ?? true)
                    return SlackTranslateStore.setReaction(id: id, name: name, on: on)
                }
                return "{\"ok\":false,\"error\":\"bad request\"}"
            case "/api/slack/done":
                // Slack 번역함 처리완료 toggle — app-owned done.json only; the
                // daemon's items.jsonl is never rewritten (append-only ownership).
                // Also mirrors the state to Slack: 완료 removes the 👀 reaction from
                // the original message AND adds ✅, 해제 does the reverse
                // (best-effort, off-thread — SlackTranslateStore.syncReaction).
                // sync:false = caller is the daemon reacting to an emoji removal
                // that ALREADY happened in Slack — skip the mirror (loop guard).
                if let id = obj["id"] as? String {
                    let t0 = DispatchTime.now()
                    let done = (obj["done"] as? Bool) ?? ((obj["done"] as? NSNumber)?.boolValue ?? false)
                    SlackTranslateStore.setDone(id: id, done: done)
                    let sync = (obj["sync"] as? Bool) ?? ((obj["sync"] as? NSNumber)?.boolValue ?? true)
                    SlackActionLog.log(done ? "done.set" : "done.unset", id: id, ok: true,
                                       ms: SlackTranslateStore.ms(since: t0),
                                       detail: sync ? "리액션 동기화 시작" : "동기화 생략 (데몬 발신)")
                    if sync {
                        DispatchQueue.global(qos: .utility).async {
                            SlackTranslateStore.syncReaction(id: id, done: done)
                        }
                    }
                }
            case "/api/slack/health":
                // 데몬(slack-eyes-daemon.mjs)의 30초 살아있음 보고. 이게 끊기면
                // SlackHealth 워치독이 스스로 launchctl kickstart로 되살린다.
                let out = SlackHealth.record(obj)
                // 워커 상태 행이 실제 데몬 생존을 반영하게 한다 (로그는 남기지 않는
                // 저비용 스탬프 — 30초마다 오므로 로그를 쓰면 도배된다).
                WorkerRegistry.shared.recordRun("slack-eyes")
                return out
            case "/api/slack/daemon/restart":
                // 사용자가 '다시 연결'을 눌렀다 — 자동 시도 카운터를 초기화하고 재시작.
                return SlackHealth.restartNow()
            case "/api/integrations/check":
                // 연동 라이브 검사 — {"ids":[…]} 로 일부만, 없으면 전부.
                // 실제 API를 한 번씩 부르므로 사용자가 '연결 테스트'를 눌렀을 때만 돈다.
                let ids = (obj["ids"] as? [String]) ?? []
                return IntegrationStore.checkJSON(ids: ids)
            case "/api/integrations/key":
                // 대시보드에서 받은 키를 키체인에 저장하고 즉시 연결까지 확인한다.
                // 값은 로그·응답 어디에도 남기지 않는다 (마스킹된 뒤 4자리만 돌려준다).
                guard let id = obj["id"] as? String, let value = obj["value"] as? String else {
                    return "{\"ok\":false,\"error\":\"bad request\"}"
                }
                let out = IntegrationStore.setKeyJSON(id: id, value: value)
                // 키가 바뀌면 데몬은 그 사실을 모른다 — 프로세스당 1회만 읽기 때문에
                // 재시작해야 반영된다. 슬랙 키라면 여기서 대신 눌러 준다.
                if out.contains("\"saved\":true"), id.hasPrefix("slack-") {
                    DispatchQueue.global(qos: .utility).async { _ = SlackHealth.restartNow() }
                }
                return out
            case "/api/integrations/key/clear":
                guard let id = obj["id"] as? String else { return "{\"ok\":false,\"error\":\"bad request\"}" }
                return IntegrationStore.clearKeyJSON(id: id)
            case "/api/integrations/instance":
                // 다중 연동(노션·지라·깃허브)의 인스턴스 추가·수정. 토큰이 함께 오면
                // 키체인 저장·라이브 검사까지 한 번에 끝낸다 (본문에 비밀값이 있으므로
                // 액션 로그는 이 경로도 통째로 가린다 — logAction의 secretBody 참고).
                guard let credId = obj["credId"] as? String, !credId.isEmpty else {
                    return "{\"ok\":false,\"error\":\"bad request\"}"
                }
                return IntegrationStore.setInstanceJSON(
                    credId: credId,
                    key: (obj["key"] as? String) ?? "",
                    label: (obj["label"] as? String) ?? "",
                    slugHint: (obj["slug"] as? String) ?? "",
                    mode: (obj["authMode"] as? String) ?? "",
                    fields: (obj["fields"] as? [String: String]) ?? [:],
                    value: (obj["value"] as? String) ?? "")
            case "/api/integrations/instance/remove":
                guard let credId = obj["credId"] as? String, let key = obj["key"] as? String else {
                    return "{\"ok\":false,\"error\":\"bad request\"}"
                }
                return IntegrationStore.removeInstanceJSON(credId: credId, key: key)
            case "/api/integrations/notion/connect":
                guard let service = obj["service"] as? String,
                      let account = obj["account"] as? String else {
                    return "{\"ok\":false,\"error\":\"bad request\"}"
                }
                return IntegrationStore.connectNotionCandidateJSON(
                    service: service, account: account, label: (obj["label"] as? String) ?? "")
            case "/api/integrations/notion/register":
                let service = "cm-notion-token-registered"
                let account = "notion"
                let id = UUID().uuidString.lowercased()
                let result = AppPaths.base.appendingPathComponent("notion-register-\(id).json")
                let bundled = Bundle.main.resourceURL?.appendingPathComponent("NotionKeychainRegister")
                let dev = (AppPaths.projectRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                    .appendingPathComponent(".build/debug/NotionKeychainRegister")
                let helper = (bundled.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true)
                    ? bundled! : dev
                guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                    return "{\"ok\":false,\"error\":\"등록 도구가 없습니다 — 앱을 다시 빌드해 주세요\"}"
                }
                let command = [helper.path, service, account, result.path]
                    .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                    .joined(separator: " ")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "tell application \"Terminal\" to activate",
                               "-e", "tell application \"Terminal\" to do script \(String(reflecting: command))"]
                do { try p.run() } catch {
                    return "{\"ok\":false,\"error\":\"Terminal을 열지 못했습니다\"}"
                }
                return "{\"ok\":true,\"id\":\(jsonString(id))," +
                    "\"service\":\(jsonString(service)),\"account\":\(jsonString(account))}"
            case "/api/integrations/mcp":
                // MCP 서버 등록·해제 — claude mcp add-json/remove 를 대신 눌러 준다.
                guard let credId = obj["credId"] as? String, let key = obj["key"] as? String else {
                    return "{\"ok\":false,\"error\":\"bad request\"}"
                }
                return IntegrationStore.setMCPJSON(credId: credId, key: key,
                                                   on: (obj["on"] as? Bool) ?? false)
            case "/api/integrations/mcp/probe":
                // 실검사 시작 — 서버를 실제로 띄워 핸드셰이크까지 해 본다. 승인이
                // 필요하면 오래 걸리므로 요청은 즉시 돌아오고, 화면이 상태를 폴링한다.
                guard let credId = obj["credId"] as? String, let key = obj["key"] as? String else {
                    return "{\"ok\":false,\"error\":\"bad request\"}"
                }
                return IntegrationStore.probeJSON(credId: credId, key: key)
            case "/api/integrations/mcp/probe/state":
                guard let credId = obj["credId"] as? String, let key = obj["key"] as? String else {
                    return "{\"ok\":false,\"error\":\"bad request\"}"
                }
                return IntegrationStore.probeStateJSON(credId: credId, key: key)
            case "/api/slack/integrations/check":
                // 연동 관리 모달 — 키체인 존재 + 실제 API 호출로 4키(슬랙 2 + 번역 2)와
                // Claude CLI 폴백을 병렬 라이브 검증한다 (SlackIntegrations).
                return SlackIntegrations.checkJSON()
            case "/api/worker/restart":
                // 시스템 페이지의 '다시 연결' — 앱 밖 launchd 워커를 사용자가 직접 되살린다.
                // 화이트리스트 매핑: 임의의 라벨이 launchctl 인자로 흘러가면 안 된다.
                switch obj["id"] as? String {
                case "slack-eyes": return SlackHealth.restartNow()
                case "autobuild":
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    p.arguments = ["kickstart", "-k",
                                   "gui/\(getuid())/com.condition-mate.autobuild"]
                    try? p.run()
                    WorkerLog.shared.append("autobuild", why: "사용자 다시 시작",
                        effect: "launchctl kickstart — 감시 프로세스 재시작")
                    return "{\"ok\":true}"
                default: return "{\"ok\":false,\"error\":\"restart 대상이 아닙니다\"}"
                }
            case "/api/qa-audit":
                // The dashboard's self-audit (deterministic UI overflow/wrapping check)
                // pushes its result here on every render. Persist the raw JSON so the QA
                // runner reads exactly what a real viewport measured — no headless height
                // cutoff, no screenshot-vision guesswork. Latest write wins.
                try? Data(body.utf8).write(to: Self.qaAuditFile, options: .atomic)
            case "/api/worker/run":
                // "즉시 실행": force one scan now, bypassing the gates (even when OFF).
                if (obj["id"] as? String) == "qa-agent" {
                    WorkerLog.shared.append("qa-agent", why: "사용자 즉시 실행",
                        effect: "1회 강제 스캔 시작 — 결과·토큰은 보통 1~2분 뒤 기록됩니다")
                    triggerQARunNow()
                }
            case "/api/prefs/view":
                // Remember the last-open dashboard view so the next launch reopens to it.
                if let v = obj["view"] as? String { Settings.shared.lastView = v }
            case "/api/prefs/donecutoff":
                // Persist the 완료 컷오프 so it survives an app restart (the dynamic
                // port resets the URL-hash store). 0 = 해제(show all); >0 = epoch cutoff.
                if let n = (obj["dc"] as? NSNumber)?.doubleValue, n >= 0 {
                    Settings.shared.doneCutoff = n
                }
            case "/api/prefs/ui":
                // Persist the dashboard UI layout (보기 상태 필터 · 상위 항상 표시 · 루프
                // 선택 · 접기/펼치기) so it survives an app restart. The client sends its
                // already-serialized prefs JSON in `data`; store it verbatim and re-inject
                // it on the next launch. An empty/missing value clears the saved layout.
                if let s = obj["data"] as? String, !s.isEmpty {
                    Settings.shared.uiPrefs = s
                } else {
                    Settings.shared.uiPrefs = nil
                }
            case "/api/duck":
                // Dashboard is about to play a UI sound effect; duck the BGM under it.
                audio.duck()
            case "/api/aifilter":
                var r = reviewStore.review(day)
                let result = AbuseFilter.evaluate(activityLog.todaySamplesParsed())
                r.aiScore = result.score
                r.aiNote = result.note
                reviewStore.saveReview(r, day: day)
            case "/api/tokens/account/label":
                if let aid = obj["id"] as? String, let label = obj["label"] as? String {
                    LLMAccountStore.shared.setLabel(id: aid, label: label)
                    return "{\"ok\":true}"
                }
                return "{\"ok\":false,\"error\":\"missing id or label\"}"
            default:
                break
            }
            return "{\"ok\":true}"
        }
    }

    // Parse a client-sent datetime: a positive epoch-seconds number => Date;
    // 0, an empty/zero string, or an absent value => nil (clear the field).
    private static func parseEpoch(_ v: Any?) -> Date? {
        if let n = (v as? NSNumber)?.doubleValue, n > 0 { return Date(timeIntervalSince1970: n) }
        if let s = v as? String, let n = Double(s), n > 0 { return Date(timeIntervalSince1970: n) }
        return nil
    }

    // MARK: AI dedup (AI추가)

    // Runs an external `claude -p` pass to judge whether `text` duplicates an existing
    // goal. BLOCKING (seconds) — call OFF the main thread (see handlePost). Returns a JSON
    // string the dashboard consumes:
    //   {"ok":true,"duplicate":<bool>,"matches":[{"seq":N,"text":"…","why":"…"}],"note":"…"}
    // On any failure it returns {"ok":false,"error":"…"} so the client falls back to a
    // plain add (the AI pass is best-effort, never a hard gate).
    // MARK: AI dedup queue worker (the "bump out" background drainer)

    // Single in-flight guard, owned by main. The worker is strictly sequential: one
    // `claude -p` at a time, so CPU/token pressure stays low and the user's dump is instant.
    private var aiWorkerRunning = false
    private let aiWorkerQueue = DispatchQueue(label: "condition.ai-queue.worker")

    // Wake the worker if it is idle. Safe to call from anywhere (hops to main to check the
    // guard). No-ops when a drain is already running — that drain will pick up new items.
    func kickAIQueueWorker() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.aiWorkerRunning else { return }
            self.aiWorkerRunning = true
            self.aiWorkerQueue.async { [weak self] in self?.drainAIQueue() }
        }
    }

    // Drain loop: claim the oldest pending item (main), analyze it off-main (blocking),
    // record the verdict (main), repeat until none remain. The guard is released inside the
    // same main hop that finds the queue empty, so a concurrent enqueue can never be lost.
    private func drainAIQueue() {
        while true {
            let item: ReviewStore.AIQueueItem? = DispatchQueue.main.sync {
                if let it = self.reviewStore.claimNextPending() { return it }
                self.aiWorkerRunning = false   // queue drained: release the guard atomically
                return nil
            }
            guard let item = item else { break }
            // Branch on the generalized jobKind. Legacy items decode jobKind=="dedup" and take
            // the UNCHANGED dedup path below. Non-dedup jobs run a per-kind runner and complete
            // via completeJob. The worker stays single-serial (one item at a time).
            if item.jobKind != "dedup" {
                let (html, err) = runQueueJob(item)
                DispatchQueue.main.sync {
                    self.reviewStore.completeJob(id: item.id, resultHTML: html, error: err)
                }
                continue
            }
            let v = aiDedupVerdict(text: item.text, origin: item.originPrompt)
            // ok=false (claude missing / spawn / parse failure) is NOT a gate: surface the
            // candidate as a clean, non-duplicate verdict so it still reaches the user for a
            // one-tap decision instead of getting stuck mid-queue.
            DispatchQueue.main.sync {
                self.reviewStore.completeAnalysis(id: item.id, duplicate: v.duplicate, kind: v.kind,
                                                  note: v.ok ? v.note : "", matches: v.matches,
                                                  relation: v.relation,
                                                  placement: v.placement, suggestedParentSeq: v.suggestedParentSeq,
                                                  priority: v.priority, confidence: v.confidence,
                                                  rationale: v.ok ? v.rationale : "")
            }
        }
    }

    // Per-kind runner hook for non-dedup queue jobs. Runs OFF main (called from drainAIQueue).
    // Returns (resultHTML, error); a non-empty error surfaces a 재시도 button on the card.
    // Phase 2 has no non-dedup producers yet — every kind is a stub that reports "not
    // implemented". Phase 3 will supply the "linkmap" runner here (build map + export HTML).
    private func runQueueJob(_ item: ReviewStore.AIQueueItem) -> (html: String, error: String) {
        switch item.jobKind {
        case "linkmap": return runLinkmapJob(item)   // Phase 3: node-link map + link-aware export
        default:
            return ("", "아직 지원하지 않는 작업 종류입니다: \(item.jobKind)")
        }
    }

    // ---- Phase 3: linkmap / export job -------------------------------------------------
    // A flattened goal snapshot the linkmap walker uses off-main (no store access after this).
    private struct LinkmapNode {
        let id: String; let seq: Int; let text: String; let parent: String
        let status: String; let links: [String]
    }

    // Runs OFF main (invoked from drainAIQueue's non-dedup branch). Snapshots goals on main,
    // walks the SINGLE root goal's link chain (parent-children + links, recursive, cycle-safe
    // via a visited-set keyed by goal id), builds the node-link MAP HTML (solid edges =
    // parent-child, purple dashed edges = links, plus a summary), builds a link-aware compressed
    // export, and returns the combined HTML. No claude -p is needed (the export is a deterministic
    // Markdown fold, so we avoid the LLM round-trip entirely).
    private func runLinkmapJob(_ item: ReviewStore.AIQueueItem) -> (html: String, error: String) {
        let rootId = item.originPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootId.isEmpty else { return ("", "내보내기 대상(root) goal이 지정되지 않았습니다.") }
        // (a) Snapshot goals on main — thread-safe store access, like aiDedupVerdict.
        let snapshot: [LinkmapNode] = DispatchQueue.main.sync {
            reviewStore.goals.map { LinkmapNode(id: $0.id, seq: $0.seq, text: $0.text,
                                                parent: $0.parent, status: $0.status, links: $0.links) }
        }
        let byId = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard let root = byId[rootId] else { return ("", "root goal을 찾을 수 없습니다: \(rootId)") }

        // (b) Walk the chain from root with a visited-set. `order` is the include order (root
        // first, then its parent-children, then its links, recursively). `edges` records every
        // parent-child (solid) and link (dashed) edge for the map. `linkHops` counts followed
        // link edges; `dupWarnings` records edges pointing at an already-visited node (a cycle
        // or a fan-in) so the summary can surface them instead of the walk looping forever.
        var visited = Set<String>()
        var order: [String] = []
        var edges: [(from: String, to: String, kind: String)] = []   // kind: "child" | "link"
        var linkHops = 0
        var dupWarnings: [String] = []

        // Iterative DFS keyed by goal id — the visited-set makes a link cycle (01→233→…→01)
        // terminate: the second time we reach 01 it is already visited, so we record a cycle
        // warning and do NOT recurse again. Each goal is emitted into `order` exactly once.
        func label(_ n: LinkmapNode) -> String { "goal-\(String(format: "%02d", n.seq))" }
        func visit(_ id: String) {
            guard let node = byId[id] else { return }
            if visited.contains(id) { return }
            visited.insert(id)
            order.append(id)
            // Parent-children first (solid edges), in seq order for a stable map.
            let kids = snapshot.filter { $0.parent == id }.sorted { $0.seq < $1.seq }
            for k in kids {
                edges.append((from: id, to: k.id, kind: "child"))
                if visited.contains(k.id) {
                    dupWarnings.append("\(label(node)) → \(label(k)) (이미 포함됨)")
                } else {
                    visit(k.id)
                }
            }
            // Then links (purple dashed edges), directional source → target.
            for tgt in node.links {
                guard let tnode = byId[tgt] else { continue }
                edges.append((from: id, to: tgt, kind: "link"))
                linkHops += 1
                if visited.contains(tgt) {
                    dupWarnings.append("\(label(node)) ↗ \(label(tnode)) (링크 순환/중복)")
                } else {
                    visit(tgt)
                }
            }
        }
        visit(rootId)

        // (c) Build the node-link MAP as a self-contained inline HTML/SVG fragment.
        let mapHTML = buildLinkmapMapHTML(order: order, edges: edges, byId: byId,
                                          root: root, linkHops: linkHops, dupWarnings: dupWarnings)
        // (d) Build the compressed export markdown (link-aware, same visited order).
        let exportMD = buildLinkmapExportMarkdown(order: order, byId: byId, root: root)
        // Render markdown into a simple <pre> block (deterministic; no LLM). The card's 다운로드
        // grabs this whole resultHTML.
        let exportHTML = "<h3 style=\"margin:14px 0 6px;font:600 14px system-ui\">압축 내보내기</h3>"
            + "<pre style=\"white-space:pre-wrap;font:12px/1.5 ui-monospace,Menlo,monospace;background:#0d1016;color:#c8d0de;padding:12px;border-radius:8px;overflow-x:auto\">"
            + escapeHTML(exportMD) + "</pre>"
        let full = "<div style=\"font:13px system-ui;color:#c8d0de\">" + mapHTML + exportHTML + "</div>"
        return (full, "")
    }

    // Minimal HTML-escape for embedding text into the result fragment.
    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    // The APPROVED map design: nodes = rounded goal boxes stacked vertically; SOLID connectors =
    // parent-child; PURPLE DASHED connectors = links; a summary block on top with included count,
    // link hops, and any duplicate/cycle warnings. Compact inline SVG (no external assets).
    private func buildLinkmapMapHTML(order: [String], edges: [(from: String, to: String, kind: String)],
                                     byId: [String: LinkmapNode], root: LinkmapNode,
                                     linkHops: Int, dupWarnings: [String]) -> String {
        func label(_ n: LinkmapNode) -> String { "goal-\(String(format: "%02d", n.seq))" }
        // Layout: one row per included goal. y is the node's vertical center; x is fixed.
        let rowH = 54.0, boxW = 300.0, boxH = 34.0, padX = 24.0, padTop = 20.0
        let width = boxW + padX * 2 + 40   // room for the link arcs on the right
        let height = padTop * 2 + Double(order.count) * rowH
        var yOf: [String: Double] = [:]
        for (i, id) in order.enumerated() { yOf[id] = padTop + Double(i) * rowH + boxH / 2 }
        let boxX = padX
        var svg = "<svg viewBox=\"0 0 \(Int(width)) \(Int(height))\" width=\"100%\" style=\"max-width:\(Int(width))px\" xmlns=\"http://www.w3.org/2000/svg\">"
        // Edges first (under the nodes).
        for e in edges {
            guard let y1 = yOf[e.from], let y2 = yOf[e.to] else { continue }
            if e.kind == "child" {
                // Solid parent-child connector: down the left gutter.
                let gx = boxX - 8
                svg += "<path d=\"M \(gx) \(y1) L \(gx) \(y2) L \(boxX) \(y2)\" fill=\"none\" stroke=\"#5b8cff\" stroke-width=\"2\"/>"
            } else {
                // Purple DASHED link connector: an arc down the right side.
                let rx = boxX + boxW + 8
                let mx = rx + 24
                svg += "<path d=\"M \(rx) \(y1) C \(mx) \(y1), \(mx) \(y2), \(rx) \(y2)\" fill=\"none\" stroke=\"#9b7bff\" stroke-width=\"2\" stroke-dasharray=\"5 4\"/>"
                svg += "<polygon points=\"\(rx-6),\(y2-4) \(rx),\(y2) \(rx-6),\(y2+4)\" fill=\"#9b7bff\"/>"
            }
        }
        // Nodes.
        let statusColor: [String: String] = ["done": "#36c08a", "in_progress": "#9be3fb"]
        for id in order {
            guard let n = byId[id], let cy = yOf[id] else { continue }
            let y = cy - boxH / 2
            let isRoot = (id == root.id)
            let stroke = isRoot ? "#e8c15a" : "#2b3242"
            let sw = isRoot ? "2" : "1"
            let dot = statusColor[n.status] ?? "#6b7486"
            svg += "<rect x=\"\(boxX)\" y=\"\(y)\" width=\"\(Int(boxW))\" height=\"\(Int(boxH))\" rx=\"8\" fill=\"#161a22\" stroke=\"\(stroke)\" stroke-width=\"\(sw)\"/>"
            svg += "<circle cx=\"\(boxX+16)\" cy=\"\(cy)\" r=\"5\" fill=\"\(dot)\"/>"
            let tag = label(n)
            let title = n.text.count > 34 ? String(n.text.prefix(33)) + "…" : n.text
            svg += "<text x=\"\(boxX+30)\" y=\"\(cy+4)\" font-family=\"system-ui\" font-size=\"12\" fill=\"#c8d0de\">"
            svg += "<tspan fill=\"#8b93a7\">\(tag)</tspan>  \(escapeHTML(title))</text>"
        }
        svg += "</svg>"
        // Summary block.
        let warn = dupWarnings.isEmpty
            ? "<span style=\"color:var(--green,#36c08a)\">순환/중복 없음</span>"
            : "<span style=\"color:#e0a458\">경고 \(dupWarnings.count)건: " + escapeHTML(dupWarnings.joined(separator: " · ")) + "</span>"
        let summary = "<div style=\"font:12px system-ui;color:#8b93a7;margin:2px 0 10px;line-height:1.6\">"
            + "루트 <b style=\"color:#c8d0de\">\(label(root))</b> · 포함 <b style=\"color:#c8d0de\">\(order.count)</b>개 · 링크 홉 <b style=\"color:#c8d0de\">\(linkHops)</b> · " + warn
            + "<br><span style=\"color:#5b8cff\">━</span> 부모-자식 &nbsp; <span style=\"color:#9b7bff\">┈┈▸</span> 링크</div>"
        return "<h3 style=\"margin:0 0 6px;font:600 14px system-ui\">노드-링크 지도</h3>" + summary
            + "<div style=\"overflow-x:auto\">" + svg + "</div>"
    }

    // Link-aware compressed export: emits each included goal once in visited order. Parent-child
    // children are listed as bullets under their top goal; linked goals get their own section
    // marked "↗ goal-NN (링크됨)". Same visited order guarantees no goal is emitted twice.
    private func buildLinkmapExportMarkdown(order: [String], byId: [String: LinkmapNode], root: LinkmapNode) -> String {
        func label(_ n: LinkmapNode) -> String { "goal-\(String(format: "%02d", n.seq))" }
        func statusTag(_ s: String) -> String {
            s == "done" ? " (완료)" : (s == "in_progress" ? " (진행)" : "")
        }
        var out = "# 내보내기 · \(label(root)) 링크 체인\n\n"
        var emittedAsChild = Set<String>()   // ids already printed as a bullet child
        for id in order {
            guard let n = byId[id] else { continue }
            if emittedAsChild.contains(id) { continue }
            // A linked (non-root, promoted) goal is marked; the root and structural tops are plain.
            if id != root.id && byId.values.contains(where: { $0.links.contains(id) }) {
                out += "## ↗ \(label(n)) (링크됨) — \(n.text)\(statusTag(n.status))\n"
            } else {
                out += "## \(label(n)) — \(n.text)\(statusTag(n.status))\n"
            }
            // Its parent-children (only those in the visited order) as bullets.
            let kids = order.compactMap { byId[$0] }.filter { $0.parent == id }.sorted { $0.seq < $1.seq }
            for k in kids {
                out += "- \(label(k)) \(k.text)\(statusTag(k.status))\n"
                emittedAsChild.insert(k.id)
            }
            out += "\n"
        }
        return out
    }

    // Verdict from the dedup judge. ok=false means the check could not run (no claude,
    // spawn/parse failure) — callers treat that as "not a duplicate" (best-effort gate).
    // `kind` ∈ {new, recurring, duplicate}: recurring = repeats/continues an existing goal's
    // work (nest under it); duplicate = same goal, nothing new (skip). `duplicate` stays true
    // for BOTH overlap kinds so the "유사 목표 있음" flag is unchanged. Default "new" lets the
    // best-effort early-return failures (ok:false) omit it.
    // The judge verdict. Two orthogonal axes:
    //   dedup axis   - duplicate/kind/matches: does this overlap an existing goal?
    //   placement axis (Option D) - placement/suggestedParentSeq/priority/confidence/rationale:
    //                  WHERE should the promoted goal land? These are advisory; the user can
    //                  override every one at resolve time.
    struct DedupVerdict {
        var ok: Bool
        var duplicate: Bool
        var note: String
        var matches: [ReviewStore.QueueMatch]
        var kind: String = "new"
        // Relationship of the NEW goal to its parent, finer than `kind`. Drives the RECOMMENDED
        // next action: recurring-execution → "task로 이번 회차 추가", sub-problem → "아래 서브 목표로
        // 추가", unrelated → "별도 새 목표로 추가". Reconciled deterministically post-judge.
        var relation: String = "unrelated"
        var placement: String = "top"       // "top" | "sub"
        var suggestedParentSeq: Int = 0      // parent #seq when placement=="sub" (0 otherwise)
        var priority: String = "medium"      // urgent | high | medium | low | lowest
        var confidence: Double = 0           // 0.0...1.0
        var rationale: String = ""           // short Korean placement reason
    }

    // Core dedup judge shared by the synchronous /api/goal/aiAdd route and the background
    // queue worker. Runs an external `claude -p` (seconds, BLOCKING) — call OFF main.
    private func aiDedupVerdict(text: String, origin: String = "") -> DedupVerdict {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return DedupVerdict(ok: false, duplicate: false, note: "", matches: []) }
        // Snapshot existing goals (brief hop to main for thread-safe store access).
        let snapshot: [(seq: Int, text: String, status: String, transcriptPath: String)] = DispatchQueue.main.sync {
            reviewStore.goals.map { (seq: $0.seq, text: $0.text, status: $0.status, transcriptPath: $0.transcriptPath) }
        }
        guard let claude = Self.resolveClaude() else {
            return DedupVerdict(ok: false, duplicate: false, note: "", matches: [])
        }
        // Retrieval BEFORE the judge: mine the raw prompt for keywords + a time window and
        // search session transcripts and goal files, so work buried inside a goal whose
        // TITLE never mentions it (the goal-130 "NSS 리포트" case) still becomes a candidate.
        let signalSource = origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? candidate : origin
        let signals = RelatedGoalSearch.signals(from: signalSource)
        let goalRefs = snapshot.map { RelatedGoalSearch.GoalRef(seq: $0.seq, title: $0.text, transcriptPath: $0.transcriptPath) }
        let hits = RelatedGoalSearch.discover(signals: signals, goals: goalRefs, issueRoot: IssuePaths.root)
        // Explicit goal numbers the routine names ("(240 …)") that map to a live goal — a
        // SECONDARY clue used to surface a candidate, never the sole recommendation.
        let existingSeqs = Set(snapshot.map { $0.seq })
        let referenced = RelatedGoalSearch.referencedSeqs(from: signalSource, existing: existingSeqs)
        // Structural "껍데기" flags: goals with a title but no transcript/folder substance.
        let hollow = RelatedGoalSearch.hollowSeqs(goals: goalRefs, issueRoot: IssuePaths.root)
        let titleBySeq = Dictionary(snapshot.map { ($0.seq, $0.text) }, uniquingKeysWith: { a, _ in a })
        // Build the two dynamic prompt pieces: a hollow-annotated existing-goals list and the
        // ALREADY-EXISTS EVIDENCE block (content hits + user-referenced goals + the SUBSTANCE
        // RULE that tells the judge to reject hollow title echoes).
        let goalInfos = snapshot.map { RelatedGoalSearch.GoalInfo(seq: $0.seq, title: $0.text, status: $0.status) }
        let evidence = RelatedGoalSearch.judgeEvidence(goals: goalInfos, hits: Array(hits.prefix(8)),
                                                        referenced: referenced, hollow: hollow)
        let listText = evidence.existingList
        let relatedText = evidence.evidenceBlock
        let prompt = """
        You are a triage judge for a personal goal tracker. Classify a NEW goal against the \
        EXISTING goals into exactly one of three kinds:
        - "new": a genuinely new goal with no meaningful overlap.
        - "recurring": repeats or continues the work of an existing goal (a routine, another \
        daily/weekly run, or a subtask of it) — worth adding as a run UNDER that goal.
        - "duplicate": the same goal already exists and re-adding it accomplishes nothing.

        Then, ORTHOGONALLY, decide WHERE the goal should be placed:
        - "placement": "top" for a stand-alone task or a brand-new parent goal; "sub" for a \
        goal that clearly belongs UNDER an existing goal as a child/subtask.
        - "suggestedParentSeq": when placement is "sub", the #seq of the parent goal it should \
        nest under (0 when placement is "top"). Only suggest a TOP-LEVEL existing goal as parent.
        - "priority": one of "urgent" | "high" | "medium" | "low" | "lowest" — your best guess \
        at how important/time-sensitive this goal is (the user may override).
        - "confidence": a number 0.0..1.0 for how sure you are about the placement.
        - "rationale": one short Korean sentence explaining the placement decision.
        A "recurring" goal is almost always placement "sub" under matches[0]. A "new" goal is \
        usually placement "top" unless it is obviously a subtask of an existing goal.

        Also classify the RELATIONSHIP to the parent goal (finer than kind) — this decides the \
        recommended next action:
        - "relation": "recurring-execution" — the new goal is ANOTHER EXECUTION/run of an existing \
        goal's ongoing work (a daily/weekly routine). Recommend adding it as a TASK under that goal.
        - "relation": "sub-problem" — the new goal is a DISTINCT sub-problem or IMPROVEMENT within \
        an existing goal's area (not just re-running it). Recommend adding it as a SUB-GOAL under \
        that goal.
        - "relation": "unrelated" — no substantive parent; a stand-alone new goal.
        SUBSTANCE RULE (critical): never choose a goal marked [껍데기]/[내용근거 없음] on the strength \
        of a title echo — it has no content. Prefer a goal with ALREADY-EXISTS EVIDENCE or a \
        [사용자 지목] reference.
        - "nextStep": one short Korean sentence recommending the MANAGED NEXT STEP derived from the \
        new goal's own intent (what to do after filing it) — infer it from the text, do not use a \
        fixed phrase.
        Worked example A (recurring-execution → task): a routine "…NSS 일일리포트 공유 (240 …루틴)" whose \
        work lives in goal #240 → relation "recurring-execution", matches[0]=240, recommend its task.
        Worked example B (sub-problem → sub-goal): "NSS 일일 리포트를 외부 로그인으로 접속해 볼 수 있게 → \
        공유 문제해결" belongs to the #240 NSS-report family but is a NEW sub-problem (solving sharing \
        via external login), not a re-run → relation "sub-problem", matches[0]=240, placement "sub", \
        nextStep about automating that report-sharing.

        EXISTING GOALS (one per line as "#<seq> <title>"; [껍데기] = title with no content):
        \(listText.isEmpty ? "(none)" : listText)\(relatedText)

        NEW GOAL:
        \(candidate)

        Respond with ONLY a single JSON object, no prose, no code fences:
        {"kind": "new" | "recurring" | "duplicate", "relation": "recurring-execution" | "sub-problem" | "unrelated", "matches": [{"seq": <int of an existing goal>, "why": "<short reason in Korean>"}], "note": "<one short Korean sentence>", "placement": "top" | "sub", "suggestedParentSeq": <int>, "priority": "urgent"|"high"|"medium"|"low"|"lowest", "confidence": <0.0..1.0>, "rationale": "<short Korean sentence>", "nextStep": "<short Korean sentence>"}
        For "recurring" and "duplicate", "matches" MUST list the related goal(s); the first is \
        the one to nest under. Use "new" with an empty "matches" array when it is genuinely new.
        """
        // Spawn via a login shell so PATH/node resolve like the user's terminal; feed the
        // prompt on stdin to dodge arg-length and quoting pitfalls.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) -p --output-format text 2>/dev/null"]
        p.environment = Self.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return DedupVerdict(ok: false, duplicate: false, note: "", matches: []) }
        // Watchdog: never let a hung model wedge the connection thread.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let raw = String(decoding: outData, as: UTF8.self)
        // Extract the first {...} block and parse it.
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let parsed = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any]
        else { return DedupVerdict(ok: false, duplicate: false, note: "", matches: []) }
        let note = (parsed["note"] as? String) ?? ""
        let bySeq = Dictionary(snapshot.map { ($0.seq, $0.text) }, uniquingKeysWith: { a, _ in a })
        let rawMatches = (parsed["matches"] as? [[String: Any]]) ?? []
        // LLM-picked match seqs (existing goals only) + their Korean "why", preserved so a
        // reordered/unioned match keeps its explanation.
        var whyBySeq: [Int: String] = [:]
        var llmMatchSeqs: [Int] = []
        for m in rawMatches {
            guard let seq = (m["seq"] as? NSNumber)?.intValue, bySeq[seq] != nil else { continue }
            if !llmMatchSeqs.contains(seq) { llmMatchSeqs.append(seq) }
            whyBySeq[seq] = (m["why"] as? String) ?? ""
        }
        // Read the 3-way kind; fall back to the legacy boolean when an older model omits it.
        let legacyDup = (parsed["duplicate"] as? Bool) ?? false
        var kind = (parsed["kind"] as? String)?.lowercased() ?? ""
        if !["new", "recurring", "duplicate"].contains(kind) { kind = legacyDup ? "duplicate" : "new" }
        let llmRelation = (parsed["relation"] as? String) ?? ""
        var placement = (parsed["placement"] as? String)?.lowercased() ?? "top"
        if placement != "sub" { placement = "top" }
        var suggestedParentSeq = (parsed["suggestedParentSeq"] as? NSNumber)?.intValue ?? 0
        if suggestedParentSeq > 0 && !existingSeqs.contains(suggestedParentSeq) { suggestedParentSeq = 0 }
        let rationale = (parsed["rationale"] as? String) ?? ""
        let nextStep = (parsed["nextStep"] as? String) ?? ""

        // DETERMINISTIC POST-MERGE (DASH-9): flip a hollow title echo to the content-substantive /
        // user-referenced goal, choose the recommended action from the RELATIONSHIP, and union
        // referenced + top-content goals into matches so the user always SEES them. This is what
        // rebinds the 추천 next action from the hollow #291 onto the substantive #240.
        let rec = RelatedGoalSearch.reconcile(
            kind: kind, relation: llmRelation, llmMatches: llmMatchSeqs,
            suggestedParentSeq: suggestedParentSeq, placement: placement, rationale: rationale,
            nextStep: nextStep, hits: hits, hollow: hollow, referenced: referenced, titles: titleBySeq)

        kind = rec.kind
        placement = rec.placement
        suggestedParentSeq = rec.suggestedParentSeq
        // recurring/duplicate need a concrete goal to act on; without one, treat as new.
        var matches: [ReviewStore.QueueMatch] = rec.matches.compactMap { seq in
            guard let gtext = bySeq[seq] else { return nil }
            return ReviewStore.QueueMatch(seq: seq, text: gtext, why: whyBySeq[seq] ?? "")
        }
        if kind != "new" && matches.isEmpty { kind = "new" }
        // `duplicate` flag stays true for BOTH overlap kinds (drives the "유사 목표 있음" line).
        let dupFinal = kind != "new"
        if placement == "sub" && suggestedParentSeq == 0 {
            suggestedParentSeq = matches.first?.seq ?? 0
            if suggestedParentSeq == 0 { placement = "top" }
        }
        var priority = (parsed["priority"] as? String)?.lowercased() ?? "medium"
        if !ReviewStore.validPriorities.contains(priority) { priority = "medium" }
        let confidence = max(0, min(1, (parsed["confidence"] as? NSNumber)?.doubleValue ?? 0))

        return DedupVerdict(ok: true, duplicate: dupFinal, note: note, matches: matches, kind: kind,
                            relation: rec.relation, placement: placement, suggestedParentSeq: suggestedParentSeq,
                            priority: priority, confidence: confidence, rationale: rec.rationale)
    }

    // Synchronous /api/goal/aiAdd: returns the verdict as JSON (kept for any direct caller).
    private func aiDuplicateCheck(text: String, parent: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
        let v = aiDedupVerdict(text: t)
        guard v.ok else { return "{\"ok\":false,\"error\":\"unavailable\"}" }
        let matches = v.matches.map {
            "{\"seq\":\($0.seq),\"text\":\(jsonString($0.text)),\"why\":\(jsonString($0.why))}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"duplicate\":\(v.duplicate),\"matches\":[\(matches)],\"note\":\(jsonString(v.note))}"
    }

    // Prompt-refine a single queued goal as a CONTINUING conversation. The refine loop
    // (프롬프트 → 생성 → 새 결과 → 다시 프롬프트) resumes ONE claude session per item, so each
    // new instruction builds on the prior turns and the similar-goal context instead of
    // starting fresh — better goal wording AND better context management. On the FIRST turn
    // (resumeSession empty) we seed the session with the current goal + the similar goals;
    // later turns pass only the new instruction and `--resume <session>`. Uses
    // `--output-format json` to capture BOTH the model reply and the session_id to resume.
    // Runs `claude -p` (seconds, BLOCKING) — call OFF main. ok=false on any failure so the
    // client keeps the current text unchanged (best-effort). Returns (ok, text, note, session).
    // Opens Terminal.app at the app's cwd and runs `claude --resume <session>` so the user can
    // continue the very conversation the refine loop built, interactively in a real shell. The
    // session was created in this process's cwd, so we cd there first (claude scopes sessions by
    // directory). Best-effort: returns false if Terminal/claude can't be resolved or launched.
    @discardableResult
    private func openClaudeResume(session: String) -> Bool {
        guard let claude = Self.resolveClaude() else { return false }
        let cwd = FileManager.default.currentDirectoryPath
        // The shell command Terminal will run. shellQuote guards path/session; PATH mirrors the
        // headless refine call so `claude` resolves the same way outside our injected env.
        let cmd = "cd \(Self.shellQuote(cwd)) && \(Self.shellQuote(claude)) --resume \(Self.shellQuote(session))"
        // Embed as an AppleScript string literal: escape backslashes then double-quotes.
        let asLit = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(asLit)\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }


    private func aiRefineGoal(current: String, matches: [ReviewStore.QueueMatch], prompt: String,
                              resumeSession: String) -> (ok: Bool, text: String, note: String, session: String) {
        let cur = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let ins = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cur.isEmpty, !ins.isEmpty else { return (false, "", "", resumeSession) }
        guard let claude = Self.resolveClaude() else { return (false, "", "", resumeSession) }
        let jsonRule = "Respond with ONLY a single JSON object, no prose, no code fences: "
            + "{\"text\": \"<the current best goal, one line, Korean>\", \"note\": \"<one short Korean sentence on what changed this turn>\"}"
        // First turn seeds full context; resumed turns carry it in the session, so send only
        // the new instruction (+ the JSON rule, since headless turns don't keep a system prompt).
        let promptText: String
        if resumeSession.isEmpty {
            let sim = matches.isEmpty ? "(none)" :
                matches.map { "#\($0.seq) \($0.text)\($0.why.isEmpty ? "" : " — \($0.why)")" }.joined(separator: "\n")
            promptText = """
            We will refine ONE goal for a personal goal tracker across a MULTI-TURN session. Each of my \
            messages is an instruction to improve the goal; keep all prior context and the similar goals \
            below in mind so we avoid duplication and manage context well. Keep the goal a single concise, \
            actionable line in Korean.

            CURRENT GOAL:
            \(cur)

            SIMILAR EXISTING GOALS (context — reuse/relate, don't duplicate):
            \(sim)

            FIRST INSTRUCTION:
            \(ins)

            \(jsonRule)
            """
        } else {
            promptText = "다음 지시로 목표를 이어서 다듬어줘: \(ins)\n\n\(jsonRule)"
        }
        var args = "-p --output-format json"
        if !resumeSession.isEmpty { args += " --resume \(Self.shellQuote(resumeSession))" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) \(args) 2>/dev/null"]
        p.environment = Self.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return (false, "", "", resumeSession) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
        inPipe.fileHandleForWriting.write(Data(promptText.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        // Outer envelope: {result, session_id}. `result` holds the model's own {text, note} JSON.
        let raw = String(decoding: outData, as: UTF8.self)
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let env2 = try? JSONSerialization.jsonObject(with: Data(raw[s...e].utf8)) as? [String: Any]
        else { return (false, "", "", resumeSession) }
        let session = (env2["session_id"] as? String) ?? resumeSession
        let result = (env2["result"] as? String) ?? ""
        // Parse the inner {text, note} out of the model reply.
        guard let is0 = result.firstIndex(of: "{"), let ie = result.lastIndex(of: "}"), is0 < ie,
              let inner = try? JSONSerialization.jsonObject(with: Data(result[is0...ie].utf8)) as? [String: Any],
              let text = (inner["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return (false, "", "", session) }
        let note = (inner["note"] as? String) ?? ""
        return (true, text, note, session)
    }

    // Semantic ("AI") search over ALL goals — including archived/released ones, which are
    // hidden from every active view. Given a free-text query (a keyword, a phrase, or a loose
    // description), the model returns every goal that overlaps in intent or topic, ranked by
    // relevance with a short Korean reason. This is the "find in seconds what Jira makes you
    // hunt for by hand" capability. Best-effort: any failure returns ok:false so the client
    // can fall back to plain substring search. BLOCKING — call OFF main (see handlePost).
    private func aiSemanticSearch(query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
        // Snapshot ALL goals (incl. released) for a thread-safe read.
        let snapshot: [(seq: Int, text: String, status: String, released: Bool)] = DispatchQueue.main.sync {
            reviewStore.goals.map { (seq: $0.seq, text: $0.text, status: $0.status, released: $0.released) }
        }
        guard let claude = Self.resolveClaude() else {
            return "{\"ok\":false,\"error\":\"claude-not-found\"}"
        }
        // Feed the full corpus (skip nothing — archived goals are the whole point) as
        // "#<seq> <title>" lines; demand a strict JSON list of relevant seqs.
        let listText = snapshot.map { "#\($0.seq) \($0.text)" }.joined(separator: "\n")
        let prompt = """
        You are a semantic search engine for a personal goal tracker. The user gives a QUERY \
        (a keyword, phrase, or loose description). Find EVERY goal that is related to the query \
        in meaning, intent, or topic — not just literal string matches. Match across paraphrases, \
        synonyms, and different languages. Be generous about topical overlap but skip goals that \
        are clearly unrelated.

        GOALS (one per line as "#<seq> <title>"):
        \(listText.isEmpty ? "(none)" : listText)

        QUERY:
        \(q)

        Respond with ONLY a single JSON object, no prose, no code fences:
        {"matches": [{"seq": <int of a matching goal>, "why": "<short Korean reason it matches>"}]}
        Order matches from most to least relevant. Return an empty array when nothing is related.
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) -p --output-format text 2>/dev/null"]
        p.environment = Self.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return "{\"ok\":false,\"error\":\"spawn-failed\"}" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let raw = String(decoding: outData, as: UTF8.self)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let parsed = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any]
        else { return "{\"ok\":false,\"error\":\"parse-failed\"}" }
        // Keep only matches that point at a real goal; pass through seq + reason in rank order.
        let known = Set(snapshot.map { $0.seq })
        let rawMatches = (parsed["matches"] as? [[String: Any]]) ?? []
        let matches = rawMatches.compactMap { m -> String? in
            guard let seq = (m["seq"] as? NSNumber)?.intValue, known.contains(seq) else { return nil }
            let why = (m["why"] as? String) ?? ""
            return "{\"seq\":\(seq),\"why\":\(jsonString(why))}"
        }.joined(separator: ",")
        return "{\"ok\":true,\"matches\":[\(matches)]}"
    }

    // One conversational turn inside the AI 중복 확인 다이얼로그: the user talks with Claude
    // to decide whether the candidate goal really duplicates existing ones AND to refine its
    // wording before adding. Stateless — the short dialog history is passed in each call.
    // Returns {"ok":bool,"reply":"…","suggestion":"…"} where suggestion (if present) is a
    // refined one-line goal the UI offers to apply to the editable goal field. BLOCKING —
    // called off-main (see handlePost).
    private func aiGoalChat(candidate: String, matches: [[String: Any]],
                            history: [[String: Any]], message: String,
                            images: [[String: Any]], model: String) -> String {
        let cand = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        var msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Decode + persist any attached images (reuse the chat attachments store), then
        // reference their paths so Claude can Read them. Off-main store access via main.sync.
        var imgPaths: [String] = []
        if !images.isEmpty {
            DispatchQueue.main.sync {
                for img in images.prefix(8) {
                    guard let b64 = img["data"] as? String, let dec = Self.decodeImageDataURL(b64) else { continue }
                    let ext = (img["name"] as? String).map { ($0 as NSString).pathExtension } ?? "png"
                    if let name = chatStore.saveImage(data: dec.bytes, ext: dec.ext.isEmpty ? ext : dec.ext) {
                        imgPaths.append(chatStore.imagePath(name).path)
                    }
                }
            }
        }
        if msg.isEmpty && !imgPaths.isEmpty { msg = "첨부한 이미지를 참고해서 목표를 다듬어줘." }
        guard !msg.isEmpty else { return "{\"ok\":false,\"error\":\"empty\"}" }
        guard let claude = Self.resolveClaude() else { return "{\"ok\":false,\"error\":\"claude-not-found\"}" }
        let matchText = matches.compactMap { m -> String? in
            guard let seq = (m["seq"] as? NSNumber)?.intValue else { return nil }
            let t = (m["text"] as? String) ?? ""
            let why = (m["why"] as? String) ?? ""
            return "#\(seq) \(t)" + (why.isEmpty ? "" : " — \(why)")
        }.joined(separator: "\n")
        let histText = history.compactMap { h -> String? in
            let t = ((h["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let who = (h["role"] as? String) == "assistant" ? "AI" : "사용자"
            return "\(who): \(t)"
        }.joined(separator: "\n")
        let prompt = """
        당신은 목표 관리 도구에서 사용자가 새 목표를 다듬도록 돕는 어시스턴트입니다.
        사용자가 추가하려는 새 목표가 기존 목표와 중복/유사할 수 있어 함께 상의해 결정합니다.
        지침:
        - 정말 중복이면 솔직히 말하고, 아니라면 왜 다른지 인정하세요.
        - 더 명확하고 구체적인 한 줄 목표 문구를 제안할 수 있으면 제안하세요.
        - 구체적인 목표 문구를 제안할 때는 답변 맨 마지막에 별도의 줄로 정확히
          "제안: <목표 문구>" 형식으로 한 줄만 덧붙이세요. (제안이 없으면 생략)
        - 한국어로 간결하게 답하고, 코드블록은 쓰지 마세요.

        [기존 유사 목표]
        \(matchText.isEmpty ? "(없음)" : matchText)

        [현재 작성 중인 새 목표]
        \(cand.isEmpty ? "(비어 있음)" : cand)

        [지금까지의 대화]
        \(histText.isEmpty ? "(없음)" : histText)

        [사용자의 새 메시지]
        \(msg)
        \(imgPaths.isEmpty ? "" : "\n[첨부 이미지 — Read 도구로 확인하세요]\n" + imgPaths.map { "- \($0)" }.joined(separator: "\n"))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Read-only + access to the attachments dir so the model can open attached images.
        var args = "-p --output-format json --add-dir \(Self.shellQuote(chatStore.attachmentsDir.path)) --allowedTools Read"
        if let m = Self.claudeModelAlias(model) { args += " --model \(Self.shellQuote(m))" }
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) \(args) 2>/dev/null"]
        p.environment = Self.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return "{\"ok\":false,\"error\":\"spawn-failed\"}" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let raw = String(decoding: outData, as: UTF8.self)
        var reply = ""
        if let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
           let parsed = try? JSONSerialization.jsonObject(with: Data(raw[s...e].utf8)) as? [String: Any] {
            reply = (parsed["result"] as? String) ?? ""
        }
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if reply.isEmpty { return "{\"ok\":false,\"error\":\"empty-reply\"}" }
        // Extract a "제안: <text>" line (the refined goal wording), if the model included one.
        var suggestion = ""
        for line in reply.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            for pfx in ["제안:", "제안 :", "📝 제안:"] where s.hasPrefix(pfx) {
                suggestion = String(s.dropFirst(pfx.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return "{\"ok\":true,\"reply\":\(jsonString(reply)),\"suggestion\":\(jsonString(suggestion))}"
    }

    // Locate the `claude` CLI. A GUI app launched from Finder inherits a minimal PATH, so
    // probe the common install locations first, then fall back to a login-shell `command -v`.
    // internal (not private): MemoTidyStore spawns its own headless `claude` and must resolve
    // the same binary — one probe order for every spawn in the app.
    static func resolveClaude() -> String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "/usr/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = nil
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    // Environment for every `claude` spawn. A GUI app inherits a minimal PATH, so the common
    // install dirs are prepended; CM_SUPPRESS_SESSION_GOAL marks these as internal workers so
    // the session hook doesn't mirror them as dashboard goals (Scripts/cc-session-hook.sh).
    //
    // Auth: the user's terminal `claude` may be a shell function that injects gateway env from
    // the Keychain — a `bash -lc <abs path>` spawn never sees that. When 연결 is set to
    // "gateway" (rail ⚙️설정), inject ANTHROPIC_BASE_URL plus the token here. In "auto" the env
    // is left untouched so the CLI uses its own local login (OAuth), and any ANTHROPIC_* we
    // inherited from our own parent still passes through unchanged.
    static func claudeEnv(suppressSessionGoal: Bool = true) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        if suppressSessionGoal { env["CM_SUPPRESS_SESSION_GOAL"] = "1" }
        let gw = gatewayEnv()
        // A gateway token and a leftover inherited key of the other kind would conflict; the
        // configured scheme wins.
        if gw["ANTHROPIC_AUTH_TOKEN"] != nil { env.removeValue(forKey: "ANTHROPIC_API_KEY") }
        if gw["ANTHROPIC_API_KEY"] != nil { env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN") }
        for (k, v) in gw { env[k] = v }
        return env
    }

    // Cached gateway env so a burst of spawns doesn't hit the Keychain (and its access prompt)
    // once per process. Invalidated when the settings are saved.
    private static var gatewayEnvCache: (at: Date, env: [String: String])?
    private static let gatewayEnvLock = NSLock()
    private static let gatewayEnvTTL: TimeInterval = 300

    static func invalidateGatewayEnv() {
        gatewayEnvLock.lock(); gatewayEnvCache = nil; gatewayEnvLock.unlock()
    }

    // The ANTHROPIC_* pairs to inject, or empty in "auto" mode / when the token is unavailable.
    // NEVER logged or returned to the page — only the fact that it resolved.
    static func gatewayEnv() -> [String: String] {
        gatewayEnvLock.lock()
        if let c = gatewayEnvCache, Date().timeIntervalSince(c.at) < gatewayEnvTTL {
            gatewayEnvLock.unlock(); return c.env
        }
        gatewayEnvLock.unlock()

        var out: [String: String] = [:]
        let s = Settings.shared
        let base = s.gatewayBaseURL.trimmingCharacters(in: .whitespaces)
        if s.gatewayMode == "gateway", !base.isEmpty, let token = gatewayToken(), !token.isEmpty {
            out["ANTHROPIC_BASE_URL"] = base
            out[s.gatewayScheme == "apiKey" ? "ANTHROPIC_API_KEY" : "ANTHROPIC_AUTH_TOKEN"] = token
        }
        gatewayEnvLock.lock(); gatewayEnvCache = (Date(), out); gatewayEnvLock.unlock()
        return out
    }

    // Read the configured Keychain generic-password. We never store the secret ourselves —
    // only the item's service/account name — so the user's existing item stays the one source.
    static func gatewayToken() -> String? {
        let s = Settings.shared
        let svc = s.gatewayKeyService.trimmingCharacters(in: .whitespaces)
        guard !svc.isEmpty else { return nil }
        let acct = s.gatewayKeyAccount.trimmingCharacters(in: .whitespaces).isEmpty
            ? NSUserName() : s.gatewayKeyAccount.trimmingCharacters(in: .whitespaces)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", svc, "-a", acct, "-w"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = nil
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let t = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // Single-quote a path for safe interpolation into a `bash -lc` command line.
    // internal (not private): MemoTidyStore builds its own `claude` command line.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Compact single-line JSON for an arbitrary value (tool input, denials array) so it
    // can be embedded in an SSE event payload. "null" if it isn't serializable.
    private static func jsonCompact(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    // Widest directory the powerful chat may touch: the multi-project workspace root.
    // A dev build sits at <workspace>/projects/<name>, so the root is two levels up.
    // nil for an installed app (no projectRoot) — bypassPermissions still lets the model
    // reach beyond its cwd, this just declares the workspace up front.
    private static func workspaceRoot() -> String? {
        guard let proj = AppPaths.projectRoot else { return nil }
        return proj.deletingLastPathComponent().deletingLastPathComponent().path
    }

    // Preset working-folder list for the 목표 추가 composer: the immediate project directories
    // under the workspace root (each a candidate cwd a goal can run in), the workspace root
    // itself, and the current project — with a `git` flag so the UI can badge real repos. The
    // user can still type any absolute path in the composer; this is only the dropdown seed.
    func foldersJSON() -> String {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [(path: String, name: String, git: Bool)] = []
        func add(_ p: String, _ name: String) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
                  !seen.contains(p) else { return }
            seen.insert(p)
            let git = fm.fileExists(atPath: (p as NSString).appendingPathComponent(".git"))
            out.append((p, name, git))
        }
        // Current project first (the most likely target), then the workspace root, then its
        // immediate non-hidden subdirectories (the sibling projects).
        if let proj = AppPaths.projectRoot?.path { add(proj, (proj as NSString).lastPathComponent) }
        if let ws = Self.workspaceRoot() {
            add(ws, (ws as NSString).lastPathComponent + " (워크스페이스)")
            let subs = (try? fm.contentsOfDirectory(atPath: ws)) ?? []
            for name in subs.sorted() where !name.hasPrefix(".") {
                add((ws as NSString).appendingPathComponent(name), name)
            }
        }
        let items = out.map {
            "{\"path\":\(jsonString($0.path)),\"name\":\(jsonString($0.name)),\"git\":\($0.git)}"
        }.joined(separator: ",")
        return "{\"folders\":[\(items)]}"
    }

    // GET /api/folders/branches?path=<folder> — the local git branches of one working folder,
    // for the 목표 추가 composer's 브랜치 칩. Non-git folders answer {git:false} so the chip
    // hides itself. Runs two quick git subprocesses on the server thread (local-only, fast).
    func folderBranchesJSON(_ path: String) -> String {
        guard let r = path.range(of: "path="),
              let dir = String(path[r.upperBound...]).split(separator: "&").first
                  .map(String.init)?.removingPercentEncoding,
              !dir.isEmpty else { return "{\"ok\":false}" }
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return "{\"ok\":false}"
        }
        // .git may be a directory (normal clone) or a file (worktree) — existence is enough.
        guard fm.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) else {
            return "{\"ok\":true,\"git\":false,\"current\":\"\",\"branches\":[]}"
        }
        let list = Self.gitOutput(cwd: dir, args: ["branch", "--list", "--format=%(refname:short)"]) ?? ""
        let branches = list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let current = (Self.gitOutput(cwd: dir, args: ["rev-parse", "--abbrev-ref", "HEAD"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let items = branches.map { jsonString($0) }.joined(separator: ",")
        return "{\"ok\":true,\"git\":true,\"current\":\(jsonString(current)),\"branches\":[\(items)]}"
    }

    // Run one git command in `cwd`, returning stdout on exit 0 (nil otherwise). Local-only
    // plumbing calls (branch list / rev-parse / checkout) — no network, completes in ms.
    static func gitOutput(cwd: String, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    // Best-effort branch switch before a goal session runs in its chosen folder: only when the
    // repo is not already on `branch`, and git itself is the guard (a checkout that would
    // clobber local changes fails and we silently stay on the current branch — the session
    // still runs; no user-facing failure).
    static func gitCheckoutIfNeeded(cwd: String, branch: String) {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return }
        let cur = (gitOutput(cwd: cwd, args: ["rev-parse", "--abbrev-ref", "HEAD"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cur.isEmpty, cur != branch else { return }
        if gitOutput(cwd: cwd, args: ["checkout", branch]) == nil {
            NSLog("[goal-branch] checkout '%@' failed in %@ — staying on '%@'", branch, cwd, cur)
        }
    }

    // MARK: Chat (Claude-Desktop-style 대화)

    // The conversation JSON the dashboard renders. Read on panel open + after each send.
    func chatJSON() -> String { chatJSON(chatStore) }

    // Same, for any conversation store (the global dashboard chat or a per-goal chat).
    func chatJSON(_ store: ChatStore) -> String {
        let msgs = DispatchQueue.main.sync { store.messages }
        let items = msgs.map { m -> String in
            let imgs = m.images.map { "\(jsonString("/chat-img/\($0)"))" }.joined(separator: ",")
            return "{\"id\":\(jsonString(m.id)),\"role\":\(jsonString(m.role)),"
                + "\"text\":\(jsonString(m.text)),\"images\":[\(imgs)],"
                + "\"createdAt\":\(m.createdAt.timeIntervalSince1970)}"
        }.joined(separator: ",")
        return "{\"messages\":[\(items)]}"
    }

    // GET /chat-img/<filename> -> the stored attachment bytes (inline), or nil (404).
    func serveChatImage(_ path: String) -> (Data, String, String)? {
        let name = String(path.dropFirst("/chat-img/".count))
            .removingPercentEncoding ?? ""
        return DispatchQueue.main.sync { chatStore.serveImage(name: name) }
    }

    // Send one chat turn to Claude. BLOCKING (seconds) — call OFF the main thread (see
    // handlePost). Persists the user message (+ any images), runs `claude -p` resuming the
    // conversation's session so context is kept, persists the reply, and returns the fresh
    // conversation JSON. On failure it still returns the conversation with an error note so
    // the panel stays consistent.
    private func chatSend(text: String, images: [[String: Any]], model: String) -> String {
        return chatSendTo(store: chatStore, extraAddDir: nil, preamble: "",
                          text: text, images: images, model: model)
    }

    // Generalized one-turn send against any conversation store. `extraAddDir` grants the
    // model Read access to an additional directory (a goal folder, for the per-goal chat).
    // `preamble` is prepended only on the FIRST turn of a fresh conversation (empty resume),
    // seeding the goal's context so the chat knows what it is helping to clarify.
    private func chatSendTo(store: ChatStore, extraAddDir: String?, preamble: String,
                            text: String, images: [[String: Any]], model: String,
                            powerful: Bool = false) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Decode + persist images first (on main for store safety); collect stored names + paths.
        var storedNames: [String] = []
        var imgPaths: [String] = []
        DispatchQueue.main.sync {
            for img in images.prefix(8) {
                guard let b64 = img["data"] as? String,
                      let data = Self.decodeImageDataURL(b64) else { continue }
                let ext = (img["name"] as? String).map { ($0 as NSString).pathExtension } ?? "png"
                if let name = store.saveImage(data: data.bytes, ext: data.ext.isEmpty ? ext : data.ext) {
                    storedNames.append(name)
                    imgPaths.append(store.imagePath(name).path)
                }
            }
        }
        guard !body.isEmpty || !storedNames.isEmpty else { return chatJSON(store) }

        // Record the user turn immediately so the panel shows it even if Claude is slow.
        let (resume, addDir): (String, String) = DispatchQueue.main.sync {
            store.appendUser(text: body, images: storedNames)
            return (store.sessionId, store.attachmentsDir.path)
        }
        let isFirstTurn = resume.isEmpty

        guard let claude = Self.resolveClaude() else {
            DispatchQueue.main.sync { _ = store.appendAssistant(text: "⚠️ claude CLI를 찾지 못했습니다. (~/.local/bin/claude 등)") }
            return chatJSON(store)
        }

        // Build the prompt: optional first-turn context preamble, user text, and a note
        // pointing the model at any attached images.
        var prompt = body
        if isFirstTurn, !preamble.isEmpty {
            prompt = preamble + "\n\n---\n\n" + body
        }
        if !imgPaths.isEmpty {
            let list = imgPaths.map { "- \($0)" }.joined(separator: "\n")
            prompt += "\n\n[첨부 이미지 — Read 도구로 확인하세요]\n\(list)"
        }
        // Assemble the claude args: print mode, JSON output (for result + session_id),
        // resume to keep context, optional model, image-read access to the attach dir, and
        // (for goal chats) the goal folder so the model may Read the core/detail docs.
        var args = "-p --output-format json --add-dir \(Self.shellQuote(addDir))"
        if powerful {
            // Full-auto chat (user-chosen): skip permission prompts and widen reach to the
            // whole workspace, so the model can edit files and run commands like the CLI
            // would — while the user keeps the comfortable chat input instead of a terminal.
            args += " --permission-mode bypassPermissions"
            if let ws = Self.workspaceRoot() { args += " --add-dir \(Self.shellQuote(ws))" }
        } else {
            args += " --allowedTools Read"   // global chat stays read-only
        }
        if let extra = extraAddDir, !extra.isEmpty { args += " --add-dir \(Self.shellQuote(extra))" }
        if !resume.isEmpty { args += " --resume \(Self.shellQuote(resume))" }
        if let m = Self.claudeModelAlias(model) { args += " --model \(Self.shellQuote(m))" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) \(args) 2>/dev/null"]
        p.environment = Self.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch {
            DispatchQueue.main.sync { _ = store.appendAssistant(text: "⚠️ claude 실행에 실패했습니다.") }
            return chatJSON(store)
        }
        // Watchdog: a long answer is fine, but never hang the connection forever. Powerful
        // turns run tools (edits/Bash) and can take minutes, so they get a longer leash.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + (powerful ? 900 : 180), execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        // Parse {result, session_id}; fall back to raw text if it isn't the json envelope.
        let raw = String(decoding: outData, as: UTF8.self)
        var reply = ""
        var newSession = ""
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
           let parsed = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any] {
            reply = (parsed["result"] as? String) ?? ""
            newSession = (parsed["session_id"] as? String) ?? ""
        }
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if reply.isEmpty { reply = "⚠️ 응답을 받지 못했습니다. (타임아웃이거나 빈 응답)" }
        DispatchQueue.main.sync {
            store.setSession(newSession)
            _ = store.appendAssistant(text: reply)
        }
        return chatJSON(store)
    }

    // MARK: Working scope (goal vs subtask)

    // The folder a goal-page request operates on: the parent goal itself (task == nil) or
    // one subtask under goal-NN/tasks/<task>. A subtask page reuses the whole goal-page
    // interface — messenger, CLI, docs, attachments, sessions — but every path is resolved
    // from this scope so each subtask works in isolation. Goal call sites pass a goal scope
    // (task == nil) and hit the exact same paths as before, guaranteeing zero regression.
    struct Scope {
        let seq: Int        // parent goal number (the container goal-NN), always present
        let task: String?   // subtask FOLDER NAME under goal-NN/tasks/, nil = the goal itself

        // Dictionary key for per-scope caches (chat stores, SSE streams, CLI tags).
        var key: String { task.map { "g\(seq)/t/\($0)" } ?? "g\(seq)" }

        // The folder this scope reads/writes — goal-NN for a goal, goal-NN/tasks/<task> for
        // a subtask. nil when the number/task can't resolve a folder.
        var workDir: URL? {
            if let t = task { return IssuePaths.taskDir(seq: seq, task: t) }
            return IssuePaths.goalDir(seq: seq)
        }
        var chatDir: URL? { workDir?.appendingPathComponent("chat", isDirectory: true) }
        var coreURL: URL? { workDir?.appendingPathComponent("goal-core.md") }
        var detailURL: URL? { workDir?.appendingPathComponent("goal-detail.md") }
        var attachmentsDir: URL? { workDir?.appendingPathComponent("attachments", isDirectory: true) }

        // Parse the optional task from a request: "?n=" / "seq=" for the goal number and
        // "t=" / "task=" (URL-decoded) for the subtask folder. An empty/absent task yields a
        // goal scope (task == nil), so existing seq-only links keep hitting the goal path.
        static func from(query path: String) -> Scope {
            guard let comps = URLComponents(string: "http://x" + path) else { return Scope(seq: 0, task: nil) }
            let items = comps.queryItems ?? []
            let rawSeq = items.first(where: { $0.name == "n" })?.value
                ?? items.first(where: { $0.name == "seq" })?.value ?? ""
            let seq = Int(rawSeq.replacingOccurrences(of: "goal-", with: "").filter { $0.isNumber }) ?? 0
            let rawTask = items.first(where: { $0.name == "t" })?.value
                ?? items.first(where: { $0.name == "task" })?.value ?? ""
            let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
            return Scope(seq: seq, task: task.isEmpty ? nil : task)
        }

        // Parse the scope from a POST JSON body: "seq" (int or numeric string) and an
        // optional "task" string. An empty "task" is treated as the goal scope.
        static func from(body obj: [String: Any]) -> Scope {
            let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
            let raw = (obj["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Scope(seq: seq, task: raw.isEmpty ? nil : raw)
        }
    }

    // MARK: Per-goal "목표 명확화" chat

    // One ChatStore per scope folder (goal-NN/chat or goal-NN/tasks/<task>/chat), created on
    // demand and cached by scope.key. The cache is touched only on main so the server queue
    // (GET/POST off-main) never races the dictionary.
    private var chatStores: [String: ChatStore] = [:]
    private func chatStore(for scope: Scope) -> ChatStore? {
        guard scope.seq > 0, let dir = scope.chatDir, let work = scope.workDir else { return nil }
        // A subtask whose folder doesn't exist yet has no store (the page shows an empty
        // state instead). A goal folder is created lazily by ChatStore as before.
        if scope.task != nil, !FileManager.default.fileExists(atPath: work.path) { return nil }
        let key = scope.key
        return DispatchQueue.main.sync {
            if let c = chatStores[key] { return c }
            let c = ChatStore(dir: dir)
            chatStores[key] = c
            return c
        }
    }
    // Thin seq-based wrapper so existing goal call sites compile unchanged (goal scope).
    private func goalChat(seq: Int) -> ChatStore? { chatStore(for: Scope(seq: seq, task: nil)) }

    // GET /api/goal/chat?seq=NN[&task=…] — the scope's conversation JSON (empty if no folder).
    func goalChatJSON(_ scope: Scope) -> String {
        guard let store = chatStore(for: scope) else { return "{\"messages\":[]}" }
        return chatJSON(store)
    }

    // GET /api/goal/session/history?seq=NN[&task=…] — prior conversation for the inline GUI
    // 세션 뷰 so past turns are visible the moment the view opens, even before the session is
    // resumed. Prefers the goal messenger ChatStore (the record the 목표 페이지 renders); falls
    // back to the tail of the goal's most-recently-used claude session transcript for sessions
    // that were never run through the messenger (e.g. a resumed CLI session). Shape mirrors the
    // messenger feed — {source, messages:[{role,text,images}]} — so the client renders it into
    // the same .su/.sa bubbles as the live stream.
    func sessionHistoryJSON(_ scope: Scope) -> String {
        if let store = chatStore(for: scope) {
            let msgs = DispatchQueue.main.sync { store.messages }
            if !msgs.isEmpty {
                let items = msgs.map { m -> String in
                    let imgs = m.images.map { jsonString("/chat-img/\($0)") }.joined(separator: ",")
                    return "{\"role\":\(jsonString(m.role)),\"text\":\(jsonString(m.text)),\"images\":[\(imgs)]}"
                }.joined(separator: ",")
                return "{\"source\":\"chat\",\"messages\":[\(items)]}"
            }
        }
        if let b = latestSession(scope) {
            let items = transcriptMessagesJSON(b.url, limit: 60)
            if !items.isEmpty { return "{\"source\":\"transcript\",\"messages\":[\(items)]}" }
        }
        return "{\"source\":\"none\",\"messages\":[]}"
    }

    // Parse a claude session transcript into compact {role,text} messages for the 세션 뷰
    // history — the last `limit` conversational bubbles. Text blocks become the bubble text;
    // tool calls collapse to a muted one-liner so activity is visible without the full I/O;
    // tool results and non-conversational records are dropped. Returns the JSON array body
    // (no enclosing brackets), empty when nothing renders.
    private func transcriptMessagesJSON(_ url: URL, limit: Int) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        var msgs: [(role: String, text: String)] = []
        String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any] else { return }
            let role = (msg["role"] as? String) ?? type
            let text = self.transcriptPlainText(msg["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }
            msgs.append((role: role == "user" ? "user" : "assistant", text: text))
        }
        return msgs.suffix(limit).map {
            "{\"role\":\(jsonString($0.role)),\"text\":\(jsonString($0.text)),\"images\":[]}"
        }.joined(separator: ",")
    }

    // Transcript content -> plain markdown for the 세션 뷰 history: text blocks kept, tool calls
    // summarized as "› 도구 실행: <name>", everything else (thinking, tool_result, system) dropped.
    private func transcriptPlainText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in arr {
            switch b["type"] as? String ?? "" {
            case "text": if let s = b["text"] as? String, !s.isEmpty { parts.append(s) }
            case "tool_use": parts.append("› 도구 실행: \(b["name"] as? String ?? "tool")")
            default: break
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // GET /api/goal/definition?seq=NN[&task=…]&kind=core|detail — the raw markdown of one
    // version, loaded into the inline editor. Returns {"text":"…"} ("" when the file is missing).
    func goalDefinitionJSON(_ scope: Scope, kind: String) -> String {
        let url = (kind == "detail") ? scope.detailURL : scope.coreURL
        var text = ""
        if let u = url, FileManager.default.fileExists(atPath: u.path),
           let data = try? Data(contentsOf: u) {
            text = String(decoding: data, as: UTF8.self)
        }
        return "{\"text\":\(jsonString(text))}"
    }

    // POST /api/goal/definition/save — overwrite goal-core.md (or goal-detail.md) with the
    // edited markdown. Pure file write (no claude, no store mutation), so it can run on the
    // server thread without hopping to main. Creates the scope folder if needed.
    func goalDefinitionSave(_ scope: Scope, kind: String, text: String) -> String {
        guard scope.seq > 0, let url = (kind == "detail") ? scope.detailURL : scope.coreURL else {
            return "{\"ok\":false,\"error\":\"bad seq\"}"
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return "{\"ok\":true}"
        } catch {
            return "{\"ok\":false,\"error\":\(jsonString(error.localizedDescription))}"
        }
    }

    // POST /api/slack/context — 번역함의 "컨텍스트 공유하기". 방금 만들어진 목표(seq)에
    // 두 가지를 남긴다:
    //   attachments/slack-context.md — 슬랙에서 다시 긁어온 원 대화 전문 (SlackContextDoc)
    //   goal-core.md                 — 사용자가 적은 목표 (세션 프리앰블이 항상 가리키는 파일)
    // 카드 본문만 넘기던 옛 GUI세션은 앞 맥락(예: "문제부터 정의하라")을 몰라서 세션이
    // 겉도는 답을 했다 — 이제 대화 전체가 파일로 세션 폴더에 들어간다. 슬랙 수집이
    // 실패해도 목표는 남기고 ok:false 만 돌려준다 (세션은 메시지 컨텍스트만으로 시작).
    func slackContextShare(id: String, seq: Int, goal: String) -> String {
        guard seq > 0, let adir = IssuePaths.attachmentsDir(seq: seq) else {
            return "{\"ok\":false,\"error\":\"bad seq\"}"
        }
        let doc = SlackTranslateStore.contextDoc(id: id)
        var path = "", writeError = ""
        if doc.ok {
            let url = adir.appendingPathComponent("slack-context.md")
            do {
                try FileManager.default.createDirectory(at: adir, withIntermediateDirectories: true)
                try doc.markdown.write(to: url, atomically: true, encoding: .utf8)
                path = url.path
            } catch {
                // 문서를 못 써도 목표는 남긴다 (아래) — 세션이 기준점 없이 시작하는 게 더 나쁘다.
                writeError = error.localizedDescription
            }
        }
        // 목표는 수집 성공 여부와 무관하게 남긴다 — 이게 이 세션의 기준점이다.
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty, let core = IssuePaths.coreURL(seq: seq),
           !FileManager.default.fileExists(atPath: core.path) {
            _ = goalDefinitionSave(Scope(seq: seq, task: nil), kind: "core",
                                   text: Self.slackGoalCore(goal: g, contextPath: path))
        }
        guard doc.ok, writeError.isEmpty else {
            return "{\"ok\":false,\"error\":\(jsonString(doc.ok ? writeError : doc.error))}"
        }
        return "{\"ok\":true,\"path\":\(jsonString(path)),\"n\":\(doc.messages),"
            + "\"thread\":\(doc.threadReplies)}"
    }

    // goal-core.md 본문 — 다른 목표와 같은 4개 섹션을 쓰되, '예상결과'에 사용자가 적은
    // 목표를 그대로 둔다. 세션 프리앰블이 이 파일을 가리키므로 턴이 아무리 길어져도
    // 에이전트가 기준을 다시 확인할 수 있다.
    private static func slackGoalCore(goal: String, contextPath: String) -> String {
        var out: [String] = []
        out.append("# 슬랙 대화 대응")
        out.append("")
        out.append("## 문제정의")
        out.append("슬랙에서 오간 대화를 이어받아 대응해야 한다. 앞 맥락이 길어 한 건씩 손으로 답하면 끝나지 않는다.")
        if !contextPath.isEmpty {
            out.append("원 대화 전문: \(contextPath)")
        }
        out.append("")
        out.append("## 예상결과")
        out.append(goal)
        out.append("")
        out.append("## 예상해결방안")
        out.append("원 대화 전문과 위 목표를 근거로, 매 턴 다음에 보낼 답장 초안을 제안한다. 슬랙 전송은 사람이 번역함 화면에서 직접 한다.")
        out.append("")
        out.append("## 예상테스트시나리오")
        out.append("- 상대의 새 메시지를 붙여넣으면 위 목표 기준의 답장 초안이 나온다.")
        out.append("- 목표에서 벗어난 제안이 나오면 이 파일의 '예상결과'를 고쳐 바로잡는다.")
        out.append("")
        return out.joined(separator: "\n")
    }

    // POST /api/goal/chat/send — one turn against the goal's conversation. BLOCKING.
    // Runs in powerful mode (bypassPermissions + workspace add-dir) so the comfortable
    // chat input can do real work — edits, commands — without dropping to a terminal.
    func goalChatSend(seq: Int, text: String, model: String) -> String {
        guard let store = goalChat(seq: seq) else { return "{\"messages\":[]}" }
        let addDir = IssuePaths.goalDir(seq: seq)?.path
        // Chatting on a goal means work has started — promote it like the CLI does. Only
        // from 대기/응답 대기; never resurrect a deliberately set hold (stopped/cancelled/done).
        DispatchQueue.main.sync {
            if let g = reviewStore.goals.first(where: { $0.seq == seq }),
               g.status == "backlog" || g.status == "waiting" {
                reviewStore.setStatus(id: g.id, status: "in_progress")
            }
        }
        return chatSendTo(store: store, extraAddDir: addDir, preamble: goalChatPreamble(seq: seq),
                          text: text, images: [], model: model, powerful: true)
    }

    // POST /api/goal/chat/reset — clear the scope's conversation and resume id.
    func goalChatReset(_ scope: Scope) -> String {
        guard let store = chatStore(for: scope) else { return "{\"messages\":[]}" }
        DispatchQueue.main.sync { store.reset() }
        return chatJSON(store)
    }

    // MARK: In-page CLI (PTY-backed interactive claude)

    // The in-page chat runs `claude -p` (headless: Read-only, add-dir limited, can't
    // prompt for permission). The CLI here runs the real interactive claude in a PTY so
    // it can ask for permission and reach beyond the goal folder — heavier work — while
    // staying inside the web page (no native Terminal). Bridged to xterm.js by polling.

    // Live CLI sessions keyed by token. Touched from the server queue (off-main); guarded
    // by its own lock since several connections may poll/stop concurrently.
    private var cliSessions: [String: PtySession] = [:]
    // Per-token metadata (the parent goal seq for the rail's status lookup, the scope key so
    // a subtask reconnects to its own session, + a display title) so the global left rail can
    // list background sessions across pages. Guarded by the same cliLock.
    private var cliTags: [String: (seq: Int, scopeKey: String, title: String)] = [:]
    private let cliLock = NSLock()

    // The claude command + working directory for this goal's CLI, plus the session id to
    // persist so closing the in-page terminal no longer loses the conversation. Continuity
    // is resolved in four tiers:
    //   1. Resume the CLI's own session if its transcript is still on disk.
    //   2. Resume a session CONNECTED to this goal — the lifecycle session it mirrors
    //      (goal.sessionId) or one manually linked via the "세션 연결" picker
    //      (goal.linkedSessions). This is what lets "이미 세션이 있으면 세션을 불러와" work:
    //      opening the CLI continues the real working session instead of an arbitrary seed.
    //   3. First CLI open with no connection: inherit the page chat's session (carry over
    //      context), adopting its id as the CLI session so future opens resume it.
    //   4. Fresh start: mint a session id up front via --session-id so we can persist it
    //      immediately — an interactive claude never reports its id back to us otherwise.
    // Resume omits --fork-session, so repeated open/close keeps appending to one transcript.
    // Whichever id is returned is adopted as the CLI session by the caller (cliStart).
    // `seed` (목표 추가's CLI 세션시작 — the typed goal text) replaces the default refine
    // prompt on a FRESH start so the terminal opens straight into the user's actual ask;
    // resumed sessions carry their own context and ignore it.
    private func cliCommand(_ scope: Scope, seed: String = "") -> (cwd: String, command: String, sessionId: String)? {
        guard let store = chatStore(for: scope), let workDir = scope.workDir,
              let claude = Self.resolveClaude() else { return nil }
        // Tier 2's connected sessions come from the parent goal for a goal scope, but from
        // the subtask's own ChatStore.linkedSessions for a task scope (it has no Goal).
        let (cliId, pageId, connectedIds, goalCwd, goalEffort, goalImages, goalBranch, goalModel): (String, String, [String], String, String, [String], String, String) = DispatchQueue.main.sync {
            var ids: [String] = []
            var gCwd = "", gEffort = "", gBranch = "", gModel = ""
            var gImages: [String] = []
            if scope.task == nil {
                if let g = reviewStore.goals.first(where: { $0.seq == scope.seq }) {
                    if !g.sessionId.isEmpty { ids.append(g.sessionId) }
                    ids.append(contentsOf: g.linkedSessions)
                    gCwd = g.cwd; gEffort = g.effort; gImages = g.images; gBranch = g.branch; gModel = g.model
                }
            } else {
                ids.append(contentsOf: store.linkedSessions)
            }
            return (store.cliSessionId, store.sessionId, ids, gCwd, gEffort, gImages, gBranch, gModel)
        }
        let goalPath = workDir.path
        // A `claude --resume <id>` invocation that grants Read access to the goal folder.
        func resume(_ id: String) -> String {
            "\(Self.shellQuote(claude)) --resume \(Self.shellQuote(id)) --add-dir \(Self.shellQuote(goalPath))"
        }
        // Tier 1: the CLI's own prior conversation.
        if !cliId.isEmpty, let cwd = sessionCwd(sessionId: cliId) {
            return (cwd, resume(cliId), cliId)
        }
        // Tier 2: a session connected to this goal, first one whose transcript still exists.
        if cliId.isEmpty {
            for sid in connectedIds where !sid.isEmpty {
                if let cwd = sessionCwd(sessionId: sid) { return (cwd, resume(sid), sid) }
            }
        }
        // Tier 3: inherit the page messenger chat's session.
        if cliId.isEmpty, !pageId.isEmpty, let cwd = sessionCwd(sessionId: pageId) {
            return (cwd, resume(pageId), pageId)
        }
        let newId = UUID().uuidString
        let defaultSeed = "이 폴더의 goal-core.md와 goal-detail.md(목표 정의)를 읽고, "
            + "문제정의·예상결과·예상해결방안·예상테스트시나리오 관점에서 모호한 점을 질문해 "
            + "목표를 더 또렷하게 다듬어 주세요. 특히 문제정의가 정확한지 가장 먼저 확인하세요. 한국어로 간결하게 답하세요."
        let seedText = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fresh interactive session honors the 목표 추가 composer's folder + effort: run in the
        // chosen project folder when set (still --add-dir the goal folder so goal-core/detail.md
        // stay Read-able), and pass --effort. cwd falls back to the goal folder as before.
        let runCwd = (!goalCwd.isEmpty && FileManager.default.fileExists(atPath: goalCwd)) ? goalCwd : goalPath
        // Same best-effort branch switch the GUI session path does (composer promises the
        // chosen branch is checked out before the session starts) — git guards dirty trees.
        if runCwd == goalCwd { Self.gitCheckoutIfNeeded(cwd: runCwd, branch: goalBranch) }
        // Composer-attached photos live in goal-NN/attachments; an interactive claude can't
        // take base64 blocks like the headless chat2 path, so ship their paths in the first
        // prompt for the model to Read (the goal folder is the cwd or an --add-dir).
        var prompt = seedText.isEmpty ? defaultSeed : seedText
        if !goalImages.isEmpty, let adir = IssuePaths.attachmentsDir(seq: scope.seq) {
            let list = goalImages.map { "- \(adir.appendingPathComponent($0).path)" }.joined(separator: "\n")
            prompt += "\n\n첨부 이미지 \(goalImages.count)장 — Read 도구로 열어서 확인하세요:\n\(list)"
        }
        var cmd = "\(Self.shellQuote(claude)) --session-id \(Self.shellQuote(newId))"
        if Self.validEffortLevels.contains(goalEffort) { cmd += " --effort \(Self.shellQuote(goalEffort))" }
        // Model rides the same pre-prompt slot as --effort (both must precede the variadic
        // --add-dir / positional prompt). 자동("") leaves the CLI's configured default.
        if let m = Self.claudeModelAlias(goalModel) { cmd += " --model \(Self.shellQuote(m))" }
        // The positional prompt MUST precede --add-dir: --add-dir is variadic (takes multiple
        // directories), so a prompt placed after it is swallowed as another directory and the
        // terminal opens with an empty input instead of running the user's ask.
        cmd += " \(Self.shellQuote(prompt))"
        if runCwd != goalPath { cmd += " --add-dir \(Self.shellQuote(goalPath))" }
        return (runCwd, cmd, newId)
    }

    // POST /api/goal/cli/start — reconnect to this scope's live background session if one
    // exists, otherwise spawn a fresh PTY-backed claude. Returns the token. `seed` rides
    // from 목표 추가's CLI 세션시작 (the typed goal text) — see cliCommand.
    func cliStart(_ scope: Scope, cols: UInt16, rows: UInt16, seed: String = "") -> String {
        let scopeKey = scope.key
        let title = DispatchQueue.main.sync {
            reviewStore.goals.first(where: { $0.seq == scope.seq })?.text ?? "goal-\(scope.seq)"
        }
        // Reconnect: if a session for this scope is still alive in the background, hand back
        // its token instead of spawning a second claude. The client polls from offset 0 and
        // the PTY's 4MB buffer tail replays, restoring the screen where the user left off.
        // Match by scopeKey so a subtask reuses only its own session, not the parent goal's.
        cliLock.lock()
        for (k, v) in cliSessions where !v.alive { v.terminate(); cliSessions.removeValue(forKey: k); cliTags.removeValue(forKey: k) }
        if let existing = cliSessions.first(where: { cliTags[$0.key]?.scopeKey == scopeKey && $0.value.alive }) {
            existing.value.resize(cols: max(cols, 20), rows: max(rows, 4))
            let tok = existing.key
            cliLock.unlock()
            return "{\"ok\":true,\"token\":\(jsonString(tok)),\"reused\":true}"
        }
        cliLock.unlock()

        guard let (cwd, command, sessionId) = cliCommand(scope, seed: seed) else {
            return "{\"ok\":false,\"error\":\"no-goal-or-claude\"}"
        }
        guard let s = PtySession(command: command, cwd: cwd, cols: max(cols, 20), rows: max(rows, 4),
                                extraEnv: Self.gatewayEnv()) else {
            return "{\"ok\":false,\"error\":\"pty-failed\"}"
        }
        // Record the session id now (we know it up front), so even an immediate close keeps
        // the conversation reachable on the next open.
        if let store = chatStore(for: scope) {
            DispatchQueue.main.sync {
                store.setCliSession(sessionId)
                // 목표 추가발 첫 CLI 세션(seed 동반): stamp the goal's primary session up
                // front so cc-session-hook events attach to THIS goal — rail and time
                // tracking follow the terminal session instead of minting an echo goal.
                if !seed.isEmpty, scope.task == nil,
                   let g = reviewStore.goals.first(where: { $0.seq == scope.seq }), g.sessionId.isEmpty {
                    reviewStore.connectSession(goalId: g.id, sessionId: sessionId, transcriptPath: "")
                }
            }
        }
        cliLock.lock()
        cliSessions[s.token] = s
        cliTags[s.token] = (seq: scope.seq, scopeKey: scopeKey, title: title)
        cliLock.unlock()
        // Opening the CLI means work has started — reflect it in the parent goal's status
        // (a subtask's parent goal is still promoted to 진행 중, which is desired).
        // Promote only from 대기(backlog)/응답 대기(waiting); never resurrect a status the
        // user set deliberately (stopped/cancelled/done) or disturb a live in_progress run.
        DispatchQueue.main.sync {
            if let g = reviewStore.goals.first(where: { $0.seq == scope.seq }),
               g.status == "backlog" || g.status == "waiting" {
                reviewStore.setStatus(id: g.id, status: "in_progress")
            }
        }
        return "{\"ok\":true,\"token\":\(jsonString(s.token))}"
    }

    // POST /api/goal/cli/io — write any keystrokes, return new output since `since`.
    func cliIO(token: String, inputB64: String, since: Int) -> String {
        cliLock.lock(); let s = cliSessions[token]; cliLock.unlock()
        guard let s else { return "{\"ok\":false,\"error\":\"no-session\"}" }
        if !inputB64.isEmpty, let d = Data(base64Encoded: inputB64) { s.write(d) }
        let (data, offset) = s.read(since: since)
        return "{\"ok\":true,\"data\":\(jsonString(data.base64EncodedString())),"
            + "\"offset\":\(offset),\"alive\":\(s.alive ? "true" : "false")}"
    }

    func cliResize(token: String, cols: UInt16, rows: UInt16) {
        cliLock.lock(); let s = cliSessions[token]; cliLock.unlock()
        s?.resize(cols: max(cols, 20), rows: max(rows, 4))
    }

    func cliStop(token: String) {
        cliLock.lock()
        let s = cliSessions.removeValue(forKey: token)
        cliTags.removeValue(forKey: token)
        cliLock.unlock()
        s?.terminate()
    }

    // Terminate any live PTY session(s) bound to a goal seq. Used by the rail's
    // 보관(완료) action so an archived goal leaves no orphaned terminal behind.
    func cliStopBySeq(_ seq: Int) {
        cliLock.lock()
        let tokens = cliTags.filter { $0.value.seq == seq }.map { $0.key }
        cliLock.unlock()
        for t in tokens { cliStop(token: t) }
    }

    // GET /api/cli/sessions — the left rail's unified worklist. Mirrors Claude Desktop's
    // colored session list. Union (by goal seq) of three sources, each tagged with the goal's
    // real status (+waitKind) so the rail can color the dot:
    //   • live PTY sessions   -> the goal's status (in_progress = 진행 중 pulse, or 확인/의사결정
    //                            요청 if it parked at a prompt); killable (has a token).
    //   • the goal I'm on now -> Settings.activeGoalSeq, the page I most recently opened,
    //                            marked 보는 중. Persisted, so it reappears after an app
    //                            restart — the in-memory PTY list does not, which is why a
    //                            page you were reading vanished from the rail after a quit.
    //   • any in_progress goal-> surfaced even with its terminal closed.
    //   • any PINNED goal      -> Settings.pinnedGoalSeqs, always surfaced (고정됨 section),
    //                            even when done/closed; survives an app quit like the pins do.
    // Each item: {seq, title, status, waitKind, live, token?, viewing, pinned}.
    func cliSessionsJSON() -> String {
        cliLock.lock()
        for (k, v) in cliSessions where !v.alive { v.terminate(); cliSessions.removeValue(forKey: k); cliTags.removeValue(forKey: k) }
        // One live token per goal (the reuse logic already prevents duplicates).
        var liveBySeq: [Int: (token: String, title: String)] = [:]
        for tok in cliSessions.keys { if let tag = cliTags[tok] { liveBySeq[tag.seq] = (tok, tag.title) } }
        cliLock.unlock()

        let goals: [(seq: Int, title: String, status: String, waitKind: String, completedAt: Date?)] =
            DispatchQueue.main.sync {
                reviewStore.goals.map { (seq: $0.seq, title: $0.text, status: $0.status,
                                         waitKind: $0.waitKind, completedAt: $0.completedAt) }
            }
        var bySeq: [Int: (seq: Int, title: String, status: String, waitKind: String, completedAt: Date?)] = [:]
        for g in goals { bySeq[g.seq] = g }

        func item(seq: Int, title: String, status: String, waitKind: String,
                  live: Bool, token: String?, viewing: Bool, pinned: Bool) -> String {
            var s = "{\"seq\":\(seq),\"title\":\(jsonString(title)),\"status\":\(jsonString(status)),"
                + "\"waitKind\":\(jsonString(waitKind)),\"live\":\(live ? "true" : "false")"
                + ",\"viewing\":\(viewing ? "true" : "false")"
                + ",\"pinned\":\(pinned ? "true" : "false")"
            if let token { s += ",\"token\":\(jsonString(token))" }
            return s + "}"
        }

        // The goal I'm actively on. Age the 보는 중 marker out after 12h so a page opened and
        // long forgotten doesn't linger in the rail forever.
        let activeSeq = Settings.shared.activeGoalSeq
        let activeFresh: Bool = {
            guard activeSeq != nil else { return false }
            guard let at = Settings.shared.activeGoalAt else { return true }
            return Date().timeIntervalSince1970 - at < 12 * 3600
        }()

        // Pinned goals always show (고정됨 section), even when done/closed.
        let pinnedSet = Set(Settings.shared.pinnedGoalSeqs)

        // Union by seq: whatever has a live terminal, plus every in_progress goal, plus the
        // goal I'm currently viewing, plus every pinned goal. One row per goal even if it is
        // several of these.
        var seqs = Set(liveBySeq.keys)
        for g in goals where g.status == "in_progress" { seqs.insert(g.seq) }
        if activeFresh, let a = activeSeq { seqs.insert(a) }
        seqs.formUnion(pinnedSet)

        var items: [String] = []
        for seq in seqs.sorted() {
            let g = bySeq[seq]
            let live = liveBySeq[seq]
            // A goal that no longer exists (e.g. a stale active/pinned seq) has neither a goal
            // record nor a live tag → nothing to title it with, so skip it.
            guard let title = g?.title ?? live?.title else { continue }
            items.append(item(seq: seq, title: title,
                              status: g?.status ?? "in_progress", waitKind: g?.waitKind ?? "",
                              live: live != nil, token: live?.token,
                              viewing: activeFresh && seq == activeSeq,
                              pinned: pinnedSet.contains(seq)))
        }

        // Task-level 보는 중 rows: the subtask pages recently opened (Settings.recentTasks),
        // newest-first, each aged out after 12h like the goal marker. Each row carries the
        // task's OWN title + "task-NN" label and links back to /goal?n=SEQ&task=FOLDER — so a
        // viewed task shows itself, not the parent goal. Skips entries whose folder is gone.
        let nowTs = Date().timeIntervalSince1970
        var taskItems: [String] = []
        for rt in Settings.shared.recentTasks {
            if rt.at > 0, nowTs - rt.at > 12 * 3600 { continue }
            let scope = Scope(seq: rt.seq, task: rt.task)
            guard let work = scope.workDir,
                  FileManager.default.fileExists(atPath: work.path) else { continue }
            let title = subtaskTitle(scope)
            let label = taskLeadingNumber(rt.task).map { "task-\($0)" } ?? rt.task
            taskItems.append("{\"seq\":\(rt.seq),\"task\":\(jsonString(rt.task)),"
                + "\"title\":\(jsonString(title)),\"label\":\(jsonString(label))}")
        }
        return "{\"sessions\":[\(items.joined(separator: ","))],"
            + "\"tasks\":[\(taskItems.joined(separator: ","))]}"
    }

    // "task29_round28_…" → 29 ; nil when the folder doesn't start with task<digits>. Mirrors
    // the leading-number parsing used by renderSubtasks/addSubtaskFolder.
    private func taskLeadingNumber(_ folder: String) -> Int? {
        guard folder.lowercased().hasPrefix("task") else { return nil }
        var d = ""
        for ch in folder.dropFirst(4) { if ch.isNumber { d.append(ch) } else { break } }
        return Int(d)
    }

    // Periodic reap: now that navigating away no longer kills the PTY, terminate sessions
    // whose terminal has gone untouched (no poll) for a long while so orphaned claude
    // processes don't accumulate. Called from the main activity tick.
    func cliReapIdle(maxIdle: TimeInterval = 30 * 60) {
        let now = Date()
        cliLock.lock()
        for (k, v) in cliSessions where !v.alive || now.timeIntervalSince(v.lastTouched) > maxIdle {
            v.terminate(); cliSessions.removeValue(forKey: k); cliTags.removeValue(forKey: k)
        }
        cliLock.unlock()
    }

    // MARK: Streaming chat (chat2 — Claude-Desktop-style)

    // Open SSE channels keyed by scope.key (one per browser tab), and the running turn
    // process per scope.key. Touched from the server queue; guarded by its own lock.
    private var chat2Streams: [String: [SSEChannel]] = [:]
    private var chat2Procs: [String: Process] = [:]
    // Last-known AI turn outcome per scope key (+"|sess"): how the previous turn ENDED
    // (done/error/stopped/died) and when (epoch ms). A page that navigated away and back
    // can't learn this from the SSE stream (events while away are gone) — GET
    // /api/goal/chat2/state reads this so the UI can visualize 중단 여부.
    private var chat2TurnInfo: [String: (state: String, at: Int64)] = [:]
    // Keys with a user-requested stop in flight (chat2Stop): distinguishes 사용자 중단
    // ("stopped") from a turn whose process vanished without a result ("died") when the
    // read loop unwinds.
    private var chat2StopRequested: Set<String> = []
    // Live turn metrics per key — what the Claude-Code-style status line shows (경과는
    // 클라이언트가 chat2TurnInfo.at 로 계산): output tokens streamed so far and tool count.
    // tokens = finished messages' committed usage; msgTokens = the in-flight message's
    // cumulative message_delta usage (committed on the next message_start). label = last
    // tool name, so a reattaching page can restore "작업 중 — Bash" without replaying events.
    private var chat2Live: [String: (tokens: Int, msgTokens: Int, tools: Int, label: String)] = [:]
    private let chat2Lock = NSLock()

    // GET /api/goal/chat2/stream?seq=NN[&task=…][&sess=1] — register a held-open SSE channel
    // for the scope (the goal, or one subtask), keyed so a subtask's events never reach the
    // goal tab. sess=1 registers the 세션 정보 tab's own stream (resume-linked-session turns,
    // see sessionSay) so those events never render into the messenger panel and vice versa.
    func handleChat2Stream(_ path: String, _ channel: SSEChannel) {
        let scope = Scope.from(query: path)
        guard scope.seq > 0 else { channel.close(); return }
        let key = scope.key + (path.contains("sess=1") ? "|sess" : "")
        chat2Lock.lock(); chat2Streams[key, default: []].append(channel); chat2Lock.unlock()
        channel.onClose = { [weak self] in
            guard let self else { return }
            self.chat2Lock.lock(); self.chat2Streams[key]?.removeAll { $0 === channel }; self.chat2Lock.unlock()
        }
    }

    // Push one JSON event to every open channel for the scope.
    private func chat2Emit(_ key: String, _ json: String) {
        chat2Lock.lock(); let chans = chat2Streams[key] ?? []; chat2Lock.unlock()
        for c in chans { c.event(json) }
    }

    // POST /api/goal/chat2/say — persist the user turn, then run a streaming claude turn
    // on a background queue whose events flow out over the goal's SSE channel. Returns
    // immediately; the answer arrives via the stream, not this response.
    func chat2Say(_ scope: Scope, text: String, mode: String, model: String, allow: [String],
                  preset: String = "", images: [[String: Any]] = [],
                  modeOverride: Bool = false) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let store = chatStore(for: scope), let claude = Self.resolveClaude(),
              let workDir = scope.workDir else { return "{\"ok\":false}" }
        let validModes: Set<String> = ["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"]
        let m = validModes.contains(mode) ? mode : "bypassPermissions"
        // Read the goal's stored 목표 추가 execution settings — these are the "실행 연동": the
        // effort/mode/cwd/images the user picked in the composer are applied whenever the goal
        // is worked, without the client having to resend them.
        var execEffort = "", execMode = m, execCwd: String? = nil, execBranch = ""
        // The goal's stored model wins over the (usually empty) request model, so the composer's
        // 자동/Fable/Opus/… choice sticks across every later turn (mirrors effort/mode 실행 연동).
        var execModel = model
        var imagePaths: [String] = [], turnImagePaths: [String] = []
        DispatchQueue.main.sync {
            store.appendUser(text: body, images: [])
            // Chatting means work has started — promote the parent goal like the other paths
            // (a subtask's parent goal is still promoted to 진행 중, which is desired).
            if let g = reviewStore.goals.first(where: { $0.seq == scope.seq }) {
                if g.status == "backlog" || g.status == "waiting" {
                    reviewStore.setStatus(id: g.id, status: "in_progress")
                }
                if Self.validEffortLevels.contains(g.effort) { execEffort = g.effort }
                if Self.validComposerModels.contains(g.model) { execModel = g.model }
                // Goal's chosen mode wins — except when the caller explicitly overrides for
                // this turn (계획 승인 → acceptEdits; otherwise a plan-mode goal could never
                // leave plan mode).
                if !modeOverride, validModes.contains(g.mode) { execMode = g.mode }
                if !g.cwd.isEmpty, FileManager.default.fileExists(atPath: g.cwd) { execCwd = g.cwd }
                execBranch = g.branch
                if !g.images.isEmpty, let adir = IssuePaths.attachmentsDir(seq: scope.seq) {
                    imagePaths = g.images.map { adir.appendingPathComponent($0).path }
                }
            }
            // Images pasted into THIS message (e.g. the goal-add session composer) are stored
            // with the goal's attachments but ride only this turn, unlike the goal-stored
            // first-turn set above.
            if !images.isEmpty, let adir = IssuePaths.attachmentsDir(seq: scope.seq) {
                let names = Self.saveComposerImages(images, into: adir)
                turnImagePaths = names.map { adir.appendingPathComponent($0).path }
            }
        }
        // preset selects the FIRST-turn framing: "team" turns this chat into a team-lead
        // multi-agent debate (팀위임); "plan" into a planning-coach session (계획);
        // "slack" into a Slack 대화 대응 세션 (번역함 컨텍스트 공유하기);
        // anything else keeps the 목표 명확화 preamble.
        let preamble: String
        switch preset {
        case "team": preamble = teamChatPreamble(scope)
        case "plan": preamble = planChatPreamble(scope)
        case "slack": preamble = slackChatPreamble(scope)
        default: preamble = goalChatPreamble(scope)
        }
        let key = scope.key
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 실행 연동: the composer's chosen branch is checked out in the goal's cwd before
            // the turn spawns (off-main; a refused checkout keeps the current branch).
            if let cwd = execCwd, !execBranch.isEmpty {
                Self.gitCheckoutIfNeeded(cwd: cwd, branch: execBranch)
            }
            self?.chat2RunTurn(key: key, store: store, claude: claude, goalDir: workDir.path,
                               prompt: body, preamble: preamble, mode: execMode, model: execModel, allow: allow,
                               turnImagePaths: turnImagePaths,
                               cwd: execCwd, effort: execEffort, imagePaths: imagePaths)
        }
        return "{\"ok\":true}"
    }

    // POST /api/goal/session/say — A안(메신저형) on the 세션 정보 tab: continue the scope's
    // most-recently-used ASSOCIATED session (the one "최신 진행 내용" shows) with a headless
    // streaming turn. Unlike chat2Say nothing is persisted to the goal messenger ChatStore —
    // the claude session transcript itself is the record. Events flow over the scope's
    // "|sess" SSE stream (GET /api/goal/chat2/stream?…&sess=1).
    func sessionSay(_ scope: Scope, text: String, mode: String, allow: [String]) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let claude = Self.resolveClaude(),
              let workDir = scope.workDir else { return "{\"ok\":false}" }
        // No associated session yet is NOT an error: start a NEW session whose first turn
        // carries the goal context (제목·핵심/디테일 파일) as preamble. chat2RunTurn(linkScope:)
        // links the new session id back to the goal on finish, so the next turn resumes it.
        let sess = latestSession(scope)
        let validModes: Set<String> = ["acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan"]
        var m = validModes.contains(mode) ? mode : "bypassPermissions"
        // Apply the goal's stored composer settings (실행 연동). For a RESUMED session cwd is
        // NOT overridden — resume is project-scoped and must run in the folder the session
        // was created in (sessionCwd below). A NEW session uses the goal's stored cwd.
        var execEffort = "", execModel = "", execCwd: String? = nil, imagePaths: [String] = []
        DispatchQueue.main.sync {
            // Continuing a session means work has (re)started — same promotion as chat2Say.
            if let g = reviewStore.goals.first(where: { $0.seq == scope.seq }) {
                if g.status == "backlog" || g.status == "waiting" {
                    reviewStore.setStatus(id: g.id, status: "in_progress")
                }
                if Self.validEffortLevels.contains(g.effort) { execEffort = g.effort }
                if validModes.contains(g.mode) { m = g.mode }
                if Self.validComposerModels.contains(g.model) { execModel = g.model }
                if sess == nil, !g.cwd.isEmpty, FileManager.default.fileExists(atPath: g.cwd) { execCwd = g.cwd }
                if !g.images.isEmpty, let adir = IssuePaths.attachmentsDir(seq: scope.seq) {
                    imagePaths = g.images.map { adir.appendingPathComponent($0).path }
                }
            }
        }
        let preamble = sess == nil ? sessionStartPreamble(scope) : ""
        let key = scope.key + "|sess"
        let cwd = sess != nil ? sessionCwd(sessionId: sess!.id) : execCwd   // resume is project-scoped (see chat2RunTurn)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.chat2RunTurn(key: key, store: nil, claude: claude, goalDir: workDir.path,
                               prompt: body, preamble: preamble, mode: m, model: execModel, allow: allow,
                               resumeOverride: sess?.id, linkScope: scope, cwd: cwd,
                               effort: execEffort, imagePaths: imagePaths)
        }
        if let sess { return "{\"ok\":true,\"session\":\(jsonString(sess.id))}" }
        return "{\"ok\":true,\"new\":true}"
    }

    // POST /api/goal/chat2/stop — terminate the scope's running turn. sess targets the
    // 세션 정보 tab's turn (sessionSay) instead of the messenger's.
    func chat2Stop(_ scope: Scope, sess: Bool = false) {
        let key = scope.key + (sess ? "|sess" : "")
        chat2Lock.lock()
        let p = chat2Procs[key]
        if p != nil { chat2StopRequested.insert(key) }
        chat2Lock.unlock()
        if let p, p.isRunning { p.terminate() }
        chat2Emit(key, "{\"t\":\"stopped\",\"reason\":\"user\"}")
    }

    // GET /api/goal/chat2/state?seq=NN[&task=…][&sess=1] — is a turn running on this
    // scope/channel right now, and how did the last one end. Lets a page that navigated
    // away and back tell "still working" from "was interrupted" (중단 여부 가시화).
    func chat2StateJSON(_ key: String) -> String {
        chat2Lock.lock()
        let running = chat2Procs[key] != nil
        let info = chat2TurnInfo[key]
        let live = chat2Live[key]
        let total = chat2Procs.count      // 실행 중인 AI 턴 개수 (전 스코프)
        chat2Lock.unlock()
        let state = running ? "running" : (info?.state ?? "none")
        return "{\"running\":\(running),\"state\":\(jsonString(state)),\"at\":\(info?.at ?? 0),"
            + "\"tokens\":\((live?.tokens ?? 0) + (live?.msgTokens ?? 0)),"
            + "\"tools\":\(live?.tools ?? 0),\"label\":\(jsonString(live?.label ?? "")),"
            + "\"totalRunning\":\(total)}"
    }

    // Record how a turn started/ended: the state feeds /api/goal/chat2/state, and the
    // same moment is stamped into the view-trace timeline (src:native, aiTurn*) so the
    // 시스템 로그 shows whether/why an AI turn was interrupted alongside the page events.
    private func chat2Mark(_ key: String, _ state: String, detail: String = "") {
        chat2Lock.lock()
        chat2TurnInfo[key] = (state, Int64(Date().timeIntervalSince1970 * 1000))
        chat2Lock.unlock()
        let name: String = {
            switch state {
            case "running": return "aiTurnStart"
            case "done":    return "aiTurnDone"
            case "error":   return "aiTurnError"
            case "stopped": return "aiTurnStopped"
            default:        return "aiTurnDied"
            }
        }()
        ViewTrace.shared.native(name, detail: key + (detail.isEmpty ? "" : " " + detail))
    }

    // Run one streaming turn: spawn claude in stream-json mode, write the user message,
    // and relay parsed events to the SSE channel until `result`. BLOCKING — runs on a
    // background queue (see chat2Say / sessionSay).
    //
    // store nil = 세션 정보 tab turn (sessionSay): nothing is persisted to a ChatStore — the
    // claude transcript is the record. resumeOverride picks the session to continue instead
    // of the store's; linkScope attaches the forked session id back to the scope on finish
    // so the next turn (and the session list) follows the continuation.
    private func chat2RunTurn(key: String, store: ChatStore?, claude: String, goalDir: String,
                              prompt: String, preamble: String, mode: String, model: String, allow: [String],
                              turnImagePaths: [String] = [],
                              resumeOverride: String? = nil, linkScope: Scope? = nil, cwd: String? = nil,
                              effort: String = "", imagePaths: [String] = []) {
        chat2Lock.lock(); let busy = chat2Procs[key] != nil; chat2Lock.unlock()
        if busy { chat2Emit(key, "{\"t\":\"error\",\"message\":\"이미 진행 중인 턴이 있습니다.\"}"); return }

        let resume = resumeOverride ?? (store.map { s in DispatchQueue.main.sync { s.sessionId } } ?? "")
        var full = prompt
        if resume.isEmpty, !preamble.isEmpty { full = preamble + "\n\n---\n\n" + prompt }
        // Attach images as REAL base64 image blocks in the user message so the model always
        // SEES them — the old "[Read 도구로 확인하세요]" text pointer was routinely ignored.
        // Goal-stored attachments (imagePaths) ride the first turn only; turnImagePaths
        // (pasted into this message) ride the turn they arrive with. The path list is still
        // appended as text so the model can re-open the files later (goalDir is an --add-dir).
        var attachPaths: [String] = (resume.isEmpty ? imagePaths : []) + turnImagePaths
        attachPaths = Array(attachPaths.prefix(8))
        var imageBlocks: [String] = []
        if !attachPaths.isEmpty {
            for p in attachPaths {
                // ~5MB API cap per image; oversized/unreadable files stay path-pointer only.
                guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)), d.count < 4_500_000 else { continue }
                imageBlocks.append("{\"type\":\"image\",\"source\":{\"type\":\"base64\","
                    + "\"media_type\":\"\(Self.imageMime(forPath: p))\",\"data\":\"\(d.base64EncodedString())\"}}")
            }
            let list = attachPaths.map { "- \($0)" }.joined(separator: "\n")
            full += imageBlocks.isEmpty
                ? "\n\n[첨부 이미지 — Read 도구로 확인하세요]\n\(list)"
                : "\n\n[첨부 이미지 — 이 메시지에 동봉되어 있습니다. 파일 경로:]\n\(list)"
        }

        var parts = [Self.shellQuote(claude), "-p", "--input-format", "stream-json",
                     "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--permission-mode", mode, "--add-dir", Self.shellQuote(goalDir)]
        if let ws = Self.workspaceRoot() { parts += ["--add-dir", Self.shellQuote(ws)] }
        if !allow.isEmpty { parts += ["--allowedTools"] + allow.map(Self.shellQuote) }
        if !resume.isEmpty { parts += ["--resume", Self.shellQuote(resume)] }
        if let alias = Self.claudeModelAlias(model) { parts += ["--model", Self.shellQuote(alias)] }
        // Reasoning effort chosen in the 목표 추가 composer (low|medium|high|xhigh|max). Empty =
        // leave the CLI default. Validated at capture time; re-guarded here defensively.
        if Self.validEffortLevels.contains(effort) { parts += ["--effort", Self.shellQuote(effort)] }
        // stderr goes to a small log instead of /dev/null: error_during_execution results
        // carry no message, so this file is the only way to see WHY a turn failed.
        let errLog = AppPaths.base.appendingPathComponent("chat2-stderr.log").path
        let command = parts.joined(separator: " ") + " 2>>" + Self.shellQuote(errLog)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", command]
        // `claude --resume` is PROJECT-SCOPED: it only finds the session when run from the
        // directory the session was created in. sessionSay passes that cwd (read from the
        // transcript); the messenger path keeps the app cwd its sessions were created with.
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        if resumeOverride != nil {
            AppLog.log("chat2 sess spawn cwd=\(cwd ?? "nil") resume=\(resumeOverride ?? "")")
        }
        p.environment = Self.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil

        chat2Emit(key, "{\"t\":\"start\"}")
        do { try p.run() } catch {
            chat2Emit(key, "{\"t\":\"error\",\"message\":\"claude 실행 실패\"}")
            chat2Mark(key, "error", detail: "spawn-failed")
            return
        }
        chat2Lock.lock()
        chat2Procs[key] = p; chat2StopRequested.remove(key)
        chat2Live[key] = (0, 0, 0, "")     // fresh turn — reset the status-line metrics
        chat2Lock.unlock()
        chat2Mark(key, "running")

        // With images the content becomes a Messages-API content-block array (text + images);
        // plain turns keep the simple string form.
        let userLine: String
        if imageBlocks.isEmpty {
            userLine = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\(jsonString(full))}}\n"
        } else {
            let blocks = (["{\"type\":\"text\",\"text\":\(jsonString(full))}"] + imageBlocks).joined(separator: ",")
            userLine = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[\(blocks)]}}\n"
        }
        inPipe.fileHandleForWriting.write(Data(userLine.utf8))
        try? inPipe.fileHandleForWriting.close()

        var buf = Data()
        var emittedTools = Set<String>()
        var finalText = ""
        var newSession = ""
        var finished = false
        var turnError = false
        let fh = outPipe.fileHandleForReading
        // stream-json input mode keeps the process alive after stdin EOF, so we end the
        // turn ourselves on `result` rather than waiting for a natural exit.
        outer: while true {
            let chunk = fh.availableData
            if chunk.isEmpty { break }            // EOF (process exited)
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0a) {
                let lineData = Data(buf[buf.startIndex..<nl])
                buf.removeSubrange(buf.startIndex...nl)
                guard !lineData.isEmpty,
                      let o = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                chat2Handle(o, key: key, emittedTools: &emittedTools, finalText: &finalText,
                            newSession: &newSession, finished: &finished, turnError: &turnError)
                if finished { break outer }
            }
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        chat2Lock.lock()
        chat2Procs[key] = nil
        let stopRequested = chat2StopRequested.remove(key) != nil
        chat2Lock.unlock()
        // 중단 여부 기록: result 를 받고 끝났으면 done/error, 못 받고 끝났으면 사용자 중단
        // (chat2Stop) 또는 비정상 종료(died — 프로세스가 결과 없이 사라짐). died 는 아무
        // 이벤트도 없이 침묵하던 케이스라 스트림에도 알린다 — 페이지가 '작업 중…'에 영원히
        // 걸려 있지 않게.
        let outcome = finished ? (turnError ? "error" : "done") : (stopRequested ? "stopped" : "died")
        chat2Mark(key, outcome, detail: outcome == "died" ? "no-result exit=\(p.terminationStatus)" : "")
        if outcome == "died" { chat2Emit(key, "{\"t\":\"stopped\",\"reason\":\"died\"}") }

        let reply = finalText
        if let store {
            DispatchQueue.main.sync {
                if !newSession.isEmpty { store.setSession(newSession) }
                if !reply.isEmpty { _ = store.appendAssistant(text: reply) }
            }
        }
        // A resumed headless turn forks a NEW session id; link it back so 세션 정보 (and the
        // next sessionSay turn, which resumes the latest transcript) follows the continuation.
        if let scope = linkScope, !newSession.isEmpty {
            if scope.task != nil {
                chatStore(for: scope)?.addLinked(newSession)   // hops to main internally
            } else {
                DispatchQueue.main.sync { reviewStore.linkGoalSession(seq: scope.seq, sessionId: newSession) }
            }
        }
    }

    // Translate one stream-json line into an SSE event (and accumulate turn results).
    private func chat2Handle(_ o: [String: Any], key: String, emittedTools: inout Set<String>,
                             finalText: inout String, newSession: inout String, finished: inout Bool,
                             turnError: inout Bool) {
        guard let t = o["type"] as? String else { return }
        switch t {
        case "stream_event":
            guard let ev = o["event"] as? [String: Any], let et = ev["type"] as? String else { return }
            // 상태줄 토큰 카운터: message_delta 의 usage.output_tokens 는 그 메시지 안에서
            // 누적값이므로 msgTokens 로 들고 있다가, 다음 메시지가 시작되면(도구 호출 뒤 새
            // API 콜) tokens 로 확정한다. 표시값 = tokens + msgTokens. 갱신 주기는 API 콜당
            // 한 번 — 클로드 코드 상태줄과 같은 체감 리듬이라 스로틀이 필요 없다.
            if et == "message_start" {
                chat2Lock.lock()
                if var l = chat2Live[key] { l.tokens += l.msgTokens; l.msgTokens = 0; chat2Live[key] = l }
                chat2Lock.unlock()
                return
            }
            if et == "message_delta" {
                guard let usage = ev["usage"] as? [String: Any],
                      let n = usage["output_tokens"] as? Int else { return }
                var shown = 0
                chat2Lock.lock()
                if var l = chat2Live[key] { l.msgTokens = max(l.msgTokens, n); chat2Live[key] = l
                    shown = l.tokens + l.msgTokens }
                chat2Lock.unlock()
                chat2Emit(key, "{\"t\":\"stat\",\"tokens\":\(shown)}")
                return
            }
            guard et == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any], let dt = delta["type"] as? String else { return }
            if dt == "text_delta", let s = delta["text"] as? String, !s.isEmpty {
                chat2Emit(key, "{\"t\":\"delta\",\"text\":\(jsonString(s))}")
            } else if dt == "thinking_delta", let s = delta["thinking"] as? String, !s.isEmpty {
                chat2Emit(key, "{\"t\":\"think\",\"text\":\(jsonString(s))}")
            }
        case "assistant":
            guard let msg = o["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for c in content where (c["type"] as? String) == "tool_use" {
                let id = (c["id"] as? String) ?? ""
                if id.isEmpty || emittedTools.contains(id) { continue }
                emittedTools.insert(id)
                let name = (c["name"] as? String) ?? "tool"
                chat2Lock.lock()
                if var l = chat2Live[key] { l.tools += 1; l.label = name; chat2Live[key] = l }
                chat2Lock.unlock()
                chat2Emit(key, "{\"t\":\"tool\",\"id\":\(jsonString(id)),\"name\":\(jsonString(name)),"
                    + "\"input\":\(Self.jsonCompact(c["input"] ?? [:]))}")
            }
        case "user":
            // Synthetic tool_result message echoed on stdout (we don't replay our own input):
            // carry the tool's output back to its card by tool_use_id.
            guard let msg = o["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
            for c in content where (c["type"] as? String) == "tool_result" {
                let id = (c["tool_use_id"] as? String) ?? ""
                let isErr = (c["is_error"] as? Bool) ?? false
                var text = ""
                if let s = c["content"] as? String { text = s }
                else if let arr = c["content"] as? [[String: Any]] {
                    text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                if text.count > 4000 { text = String(text.prefix(4000)) + "…(생략)" }
                chat2Emit(key, "{\"t\":\"toolresult\",\"id\":\(jsonString(id)),"
                    + "\"isError\":\(isErr ? "true" : "false"),\"text\":\(jsonString(text))}")
            }
        case "result":
            finalText = (o["result"] as? String) ?? finalText
            newSession = (o["session_id"] as? String) ?? newSession
            let denials = o["permission_denials"] as? [Any] ?? []
            let cost = (o["total_cost_usd"] as? Double) ?? 0
            let isErr = (o["is_error"] as? Bool) ?? false
            turnError = isErr
            if isErr {
                // Errored turns discard stderr, so keep the raw result record — subtype says
                // WHY (e.g. error_during_execution) and this is the only trace we get.
                AppLog.log("chat2 turn error key=\(key) raw=\(String(Self.jsonCompact(o).prefix(600)))")
            }
            // 최종 토큰 수: result 의 usage 가 정답이고, 없으면 스트림에서 센 누적값.
            let usageTok = ((o["usage"] as? [String: Any])?["output_tokens"] as? Int) ?? 0
            var liveTok = 0
            chat2Lock.lock()
            if var l = chat2Live[key] {
                l.tokens += l.msgTokens; l.msgTokens = 0
                if usageTok > 0 { l.tokens = usageTok }
                chat2Live[key] = l; liveTok = l.tokens
            }
            chat2Lock.unlock()
            chat2Emit(key, "{\"t\":\"done\",\"result\":\(jsonString(finalText)),"
                + "\"denials\":\(Self.jsonCompact(denials)),\"cost\":\(cost),"
                + "\"tokens\":\(liveTok),\"isError\":\(isErr ? "true" : "false")}")
            finished = true
        default: break
        }
    }

    // The cwd a session was created in, read from its transcript so an interactive
    // `claude --resume` launches from the matching project directory (resume is
    // project-scoped). Scans ~/.claude/projects/*/<sessionId>.jsonl and parses the
    // first record carrying a non-empty "cwd". nil if no transcript or no cwd found.
    private func sessionCwd(sessionId: String) -> String? {
        let fm = FileManager.default
        guard let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase, includingPropertiesForKeys: nil) else { return nil }
        var found: URL?
        for dir in subs {
            let cand = dir.appendingPathComponent(sessionId + ".jsonl")
            if fm.fileExists(atPath: cand.path) { found = cand; break }
        }
        guard let url = found, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        // 1MB window, not 64KB: early records can be huge (an 86KB queue snapshot was seen in
        // the wild), and a cwd record cut mid-line parses as nothing → cwd nil → resume fails
        // with "No conversation found" because claude then runs outside the session's project.
        let chunk = fh.readData(ofLength: 1_048_576)
        guard !chunk.isEmpty else { return nil }
        for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            // Only hand back a directory that still exists. After the data store was
            // consolidated to ~/.condition-mate, old transcripts still record a path like
            // <repo>/.condition-mate/issue/goal-NN that no longer exists; returning it would
            // make the resumed CLI's process.run() throw (surfacing as "pty-failed"). Returning
            // nil instead lets cliCommand skip that resume tier and start fresh in the goal's
            // current folder, which self-heals the stored cliSessionId on the next open.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
            return cwd
        }
        return nil
    }

    // MARK: - Per-goal session list (연결된 세션 목록)

    // Locate <sessionId>.jsonl anywhere under ~/.claude/projects. Generic sibling of
    // resolveTranscript that takes a bare id (no Goal needed).
    private func transcriptURL(forSessionId sid: String) -> URL? {
        let id = sid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              let subs = try? FileManager.default.contentsOfDirectory(at: claudeProjectsBase, includingPropertiesForKeys: nil) else { return nil }
        for dir in subs {
            let cand = dir.appendingPathComponent(id + ".jsonl")
            if FileManager.default.fileExists(atPath: cand.path) { return cand }
        }
        return nil
    }

    // The best human title for a transcript, mirroring the session hook's priority:
    //   goal-title-override > ai-title > custom-title > first user prompt (truncated).
    // Title records (override/ai/custom) are appended as the session runs, so the latest
    // sit near the END — read a bounded tail window for those, and only fall back to a
    // small head read for the first prompt. Bounded IO so the picker stays snappy even
    // with large transcripts. "" when no title source is present.
    private func transcriptTitle(_ url: URL) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        func scan(_ data: Data, _ visit: (String, [String: Any]) -> Void) {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let t = o["type"] as? String else { continue }
                visit(t, o)
            }
        }
        var override = "", ai = "", custom = "", first = ""
        let tailLen: UInt64 = 262_144
        try? fh.seek(toOffset: size > tailLen ? size - tailLen : 0)
        let tail = (try? fh.readToEnd()) ?? Data()
        scan(tail) { t, o in
            if t == "goal-title-override", let s = o["title"] as? String, !s.isEmpty { override = s }
            else if t == "ai-title", let s = o["aiTitle"] as? String, !s.isEmpty { ai = s }
            else if t == "custom-title", let s = o["customTitle"] as? String, !s.isEmpty { custom = s }
        }
        if override.isEmpty && ai.isEmpty && custom.isEmpty {
            try? fh.seek(toOffset: 0)
            let head = fh.readData(ofLength: 65_536)
            scan(head) { t, o in
                if t == "last-prompt", first.isEmpty, let s = o["lastPrompt"] as? String, !s.isEmpty { first = s }
            }
        }
        if !override.isEmpty { return override }
        if !ai.isEmpty { return ai }
        if !custom.isEmpty { return custom }
        let s = first.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
        if s.isEmpty { return "" }
        return s.count > 48 ? String(s.prefix(48)) + "…" : s
    }

    // GET /api/goal/sessions?seq=NN[&task=…] — every session associated with the scope: its
    // primary lifecycle session, the messenger chat session, the in-page CLI session, plus
    // any manually-linked ones. Each carries its last-used time (transcript mtime), a title,
    // and a resume command, sorted newest-first so the user can tell which to continue. A
    // subtask has no lifecycle Goal, so its primary is "" and links come from the task store.
    func goalSessionsJSON(_ scope: Scope) -> String {
        var pageMsg = "", pageCli = "", primary = ""
        var linked: [String] = []
        if scope.task == nil {
            (primary, linked) = DispatchQueue.main.sync { () -> (String, [String]) in
                let g = reviewStore.goals.first { $0.seq == scope.seq }
                return (g?.sessionId ?? "", g?.linkedSessions ?? [])
            }
        }
        if let store = chatStore(for: scope) {
            let (m, c, ls) = DispatchQueue.main.sync { (store.sessionId, store.cliSessionId, store.linkedSessions) }
            pageMsg = m; pageCli = c
            if scope.task != nil { linked = ls }
        }
        var order: [(id: String, src: String)] = []
        func add(_ id: String, _ src: String) {
            let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !order.contains(where: { $0.id == t }) else { return }
            order.append((t, src))
        }
        add(primary, "세션")
        add(pageMsg, "메신저")
        add(pageCli, "CLI")
        for s in linked { add(s, "연결") }

        let fm = FileManager.default
        var rows: [(json: String, when: TimeInterval)] = []
        for e in order {
            let url = transcriptURL(forSessionId: e.id)
            var when: TimeInterval = 0
            if let u = url, let a = try? fm.attributesOfItem(atPath: u.path),
               let m = a[.modificationDate] as? Date { when = m.timeIntervalSince1970 }
            let title = url.map { transcriptTitle($0) } ?? ""
            let display = title.isEmpty ? "Claude 세션 \(e.id.prefix(8))" : title
            let removable = (e.src == "연결")
            let j = "{\"id\":\(jsonString(e.id)),\"source\":\(jsonString(e.src)),"
                + "\"title\":\(jsonString(display)),\"lastUsed\":\(Int(when)),"
                + "\"exists\":\(url != nil),\"removable\":\(removable),"
                + "\"resume\":\(jsonString("claude --resume " + e.id))}"
            rows.append((j, when))
        }
        rows.sort { $0.when > $1.when }
        return "{\"now\":\(Int(Date().timeIntervalSince1970)),\"sessions\":[\(rows.map { $0.json }.joined(separator: ","))]}"
    }

    // GET /api/sessions/recent?seq=NN[&task=…] — the most recently used Claude sessions across
    // ~/.claude/projects, for the "세션 연결" picker. Newest-first, capped, each tagged with
    // whether it is already linked to this scope so the picker can pre-check / disable it.
    func recentSessionsJSON(_ scope: Scope) -> String {
        let fm = FileManager.default
        var already = DispatchQueue.main.sync { () -> Set<String> in
            var s = Set<String>()
            if scope.task == nil, let g = reviewStore.goals.first(where: { $0.seq == scope.seq }) {
                if !g.sessionId.isEmpty { s.insert(g.sessionId) }
                for x in g.linkedSessions { s.insert(x) }
            }
            return s
        }
        if let store = chatStore(for: scope) {
            let (m, c, ls) = DispatchQueue.main.sync { (store.sessionId, store.cliSessionId, store.linkedSessions) }
            if !m.isEmpty { already.insert(m) }
            if !c.isEmpty { already.insert(c) }
            if scope.task != nil { for x in ls { already.insert(x) } }
        }
        var files: [(url: URL, when: Date)] = []
        if let subs = try? fm.contentsOfDirectory(at: claudeProjectsBase, includingPropertiesForKeys: nil) {
            for dir in subs {
                let inner = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for f in inner where f.pathExtension == "jsonl" {
                    let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    files.append((f, m))
                }
            }
        }
        files.sort { $0.when > $1.when }
        var out: [String] = []
        for f in files.prefix(40) {
            let id = f.url.deletingPathExtension().lastPathComponent
            let title = transcriptTitle(f.url)
            let display = title.isEmpty ? "Claude 세션 \(id.prefix(8))" : title
            out.append("{\"id\":\(jsonString(id)),\"title\":\(jsonString(display)),"
                + "\"lastUsed\":\(Int(f.when.timeIntervalSince1970)),\"linked\":\(already.contains(id))}")
        }
        return "{\"now\":\(Int(Date().timeIntervalSince1970)),\"sessions\":[\(out.joined(separator: ","))]}"
    }

    // The scope's most-recently-touched ASSOCIATED session — same candidate set the
    // "최신 진행 내용" block shows (primary + goal-page messenger/CLI + linked; a subtask
    // scope uses its own ChatStore instead). This is the session sessionSay continues.
    private func latestSession(_ scope: Scope) -> (id: String, url: URL, when: Date)? {
        var ids: [String] = []
        func add(_ id: String) {
            let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !ids.contains(t) { ids.append(t) }
        }
        if scope.task != nil {
            if let store = chatStore(for: scope) {
                let (m, c, ls) = DispatchQueue.main.sync { (store.sessionId, store.cliSessionId, store.linkedSessions) }
                add(m); add(c); ls.forEach(add)
            }
        } else {
            let (primary, linked) = DispatchQueue.main.sync { () -> (String, [String]) in
                let g = reviewStore.goals.first { $0.seq == scope.seq }
                return (g?.sessionId ?? "", g?.linkedSessions ?? [])
            }
            var pageMsg = "", pageCli = ""
            if let store = goalChat(seq: scope.seq) {
                (pageMsg, pageCli) = DispatchQueue.main.sync { (store.sessionId, store.cliSessionId) }
            }
            add(primary); add(pageMsg); add(pageCli); linked.forEach(add)
        }
        let fm = FileManager.default
        var best: (id: String, url: URL, when: Date)?
        for id in ids {
            guard let url = transcriptURL(forSessionId: id),
                  let a = try? fm.attributesOfItem(atPath: url.path),
                  let m = a[.modificationDate] as? Date else { continue }
            if best == nil || m > best!.when { best = (id, url, m) }
        }
        return best
    }

    // The "최신 진행 내용" block under the 세션 정보 tab: the latest progress of the goal's
    // most-recently-used session. Picks the associated session whose transcript was touched
    // last, then renders its tail (the recent turns) so the user sees what it is doing now.
    private func renderCurrentContent(seq: Int) -> String {
        guard let b = latestSession(Scope(seq: seq, task: nil)) else {
            return "<p class=\"empty\">연결된 세션이 없습니다. 아래 입력창에 지시하면 목표 내용으로 새 세션이 시작됩니다. (오른쪽 메신저·CLI, “+ 세션 연결”도 가능)</p>"
        }
        let title = transcriptTitle(b.url)
        let secs = Int(max(0, Date().timeIntervalSince(b.when)))
        let ago = secs < 60 ? "방금" : secs < 3600 ? "\(secs / 60)분 전"
                : secs < 86400 ? "\(secs / 3600)시간 전" : "\(secs / 86400)일 전"
        let head = "<div class=\"curhdr\"><span class=\"ct\">\(htmlEscape(title.isEmpty ? "세션" : title))</span>"
            + "<span class=\"cage\">마지막 진행 \(ago)</span></div>"
        return head + "<div class=\"curbody\">\(renderTranscriptTail(b.url, limit: 20))</div>"
    }

    // Seq-based wrapper so the blocking goalChatSend keeps compiling (goal scope).
    private func goalChatPreamble(seq: Int) -> String { goalChatPreamble(Scope(seq: seq, task: nil)) }

    // First-turn context that tells the chat its job: clarify THIS scope through conversation.
    // For a subtask the title comes from its _task.md anchor (no Goal exists), and the file
    // paths point at the subtask's own goal-core.md / goal-detail.md.
    private func goalChatPreamble(_ scope: Scope) -> String {
        let label: String
        let title: String
        if let task = scope.task {
            label = "goal-\(scope.seq) / \(task)"
            title = subtaskTitle(scope)
        } else {
            label = "goal-\(scope.seq)"
            title = DispatchQueue.main.sync { reviewStore.goals.first { $0.seq == scope.seq }?.text ?? "" }
        }
        let core = scope.coreURL?.path ?? ""
        let detail = scope.detailURL?.path ?? ""
        return """
        이 대화의 목적은 아래 목표(골)를 대화로 점점 더 명확하게 만드는 것입니다.
        - 골 번호: \(label)
        - 제목: \(title)
        - 핵심 버전 파일: \(core)
        - 디테일 버전 파일: \(detail)
        핵심/디테일 두 버전과 4개 섹션(문제정의·예상결과·예상해결방안·예상테스트시나리오) 관점에서 모호한 점을 질문해 목표를 또렷하게 다듬어 주세요. 특히 '문제정의'가 정확한지 가장 먼저 확인하세요(잘못 정의하면 모든 방향이 달라집니다). 필요하면 위 두 파일을 직접 읽고, 사용자가 요청하면 파일을 수정하거나 명령을 실행해 작업을 진행하세요. 한국어로 간결하게 답하세요.

        사용자에게 명확화 질문을 할 때는 본문 마크다운으로 길게 풀어쓰지 말고, 반드시 아래 형식의 cm-question 코드블록 하나로만 출력하세요(블록 앞에 짧은 맥락 한두 줄은 두어도 됩니다).
        ```cm-question
        {"q":[{"ask":"질문 한 줄","opts":[{"label":"짧은 선택지","why":"추천 이유 한 줄","rec":true},{"label":"다른 선택지"}]}]}
        ```
        규칙: 물어볼 질문을 q 배열에 모두 담고, 각 질문의 opts는 2~4개로 한다. 가장 가능성 높은 선택지 하나에만 rec를 true로 두고 why에 한 줄 근거를 적는다. label은 짧게 쓴다. 사용자는 직접 입력으로도 답할 수 있으니 모든 경우를 선택지로 나열할 필요는 없다. 질문이 아닌 일반 설명·답변은 평소대로 마크다운으로 답한다.
        """
    }

    // First-turn context when the 세션 정보 composer starts a NEW session (no associated
    // session existed). Unlike goalChatPreamble this is a WORK session, not a clarification
    // chat: the goal body is the brief and the user's message is an instruction to execute.
    private func sessionStartPreamble(_ scope: Scope) -> String {
        let label: String
        let title: String
        if let task = scope.task {
            label = "goal-\(scope.seq) / \(task)"
            title = subtaskTitle(scope)
        } else {
            label = "goal-\(scope.seq)"
            title = DispatchQueue.main.sync { reviewStore.goals.first { $0.seq == scope.seq }?.text ?? "" }
        }
        let core = scope.coreURL?.path ?? ""
        let detail = scope.detailURL?.path ?? ""
        return """
        아래 목표(골)의 작업 세션입니다. 목표 내용을 컨텍스트로 삼아, 이어지는 사용자 지시를 바로 수행하세요.
        - 골 번호: \(label)
        - 목표 내용: \(title)
        - 핵심 버전 파일: \(core)
        - 디테일 버전 파일: \(detail)
        지시가 목표 내용을 가리키면("내용을 보고", "위 목표대로" 등) 위 목표 내용과 두 파일을 근거로 작업하세요. 산출물은 파일로 남기고, 한국어로 간결하게 답하세요.
        """
    }

    // First-turn context for a 슬랙 대화 대응 세션 (chat2 preset:"slack" — 번역함의
    // "컨텍스트 공유하기"). 이 세션의 기준점은 목표(goal-core.md)이고, 재료는 슬랙에서
    // 긁어온 원 대화 전문(attachments/slack-context.md)이다. 기본 프리앰블(목표 명확화)을
    // 쓰면 에이전트가 대화를 이어받는 대신 목표를 캐묻기만 해서 따로 뒀다.
    private func slackChatPreamble(_ scope: Scope) -> String {
        let title = DispatchQueue.main.sync {
            reviewStore.goals.first { $0.seq == scope.seq }?.text ?? ""
        }
        let core = scope.coreURL?.path ?? ""
        let ctx = scope.attachmentsDir?.appendingPathComponent("slack-context.md").path ?? ""
        return """
        당신은 이 슬랙 대화를 사용자 대신 끌고 가는 대응 파트너입니다. 상대는 계속 질문하고 대화를 이어갈 것이고, 사용자는 매번 직접 답을 쓸 시간이 없습니다. 사용자가 정한 목표를 먼저 이해하고, 그 목표를 달성하는 방향으로 대화가 흘러가게 만드는 것이 당신의 일입니다.
        - 골 번호: goal-\(scope.seq)
        - 목표(사용자가 정한 기준점): \(title)
        - 목표 파일: \(core)
        - 슬랙 원 대화 전문: \(ctx)

        진행 방식 — 반드시 이 순서대로:
        1. 첫 턴에 위 두 파일을 Read 도구로 직접 읽습니다. 원 대화 전문에는 카드에 안 보이던 앞 맥락(누가 무엇을 요구했는지, 이미 합의된 것과 반박된 것)이 들어 있습니다.
        2. 읽은 내용을 서너 줄로 정리해 보여줍니다: 지금 대화가 어디까지 왔는지, 상대가 실제로 요구하는 것이 무엇인지, 목표와 어긋나는 지점이 무엇인지.
        3. 그 다음 바로 슬랙에 보낼 답장 초안을 제시합니다. 초안은 그대로 복사해 붙일 수 있는 완성된 글이어야 하고, 원 대화와 같은 언어로 씁니다.
        4. 이후 사용자가 상대의 새 메시지를 붙여넣으면, 매번 같은 방식으로 목표 기준의 판단 + 다음 답장 초안을 냅니다.

        규칙: 판단이 갈리는 지점에서는 목표 파일의 '예상결과'를 기준으로 결정합니다. 목표 자체가 바뀌면 목표 파일을 고쳐 기록합니다. 슬랙 전송은 절대 직접 하지 않습니다 — 전송은 사용자가 번역함 화면에서 합니다. 한국어로 간결하게 답하되, 답장 초안만은 원 대화의 언어로 씁니다.

        사용자에게 되물어야 할 때는 본문 마크다운으로 길게 풀어쓰지 말고, 반드시 아래 형식의 cm-question 코드블록 하나로만 출력하세요(블록 앞에 짧은 맥락 한두 줄은 두어도 됩니다).
        ```cm-question
        {"q":[{"ask":"질문 한 줄","opts":[{"label":"짧은 선택지","why":"추천 이유 한 줄","rec":true},{"label":"다른 선택지"}]}]}
        ```
        규칙: 물어볼 질문을 q 배열에 모두 담고, 각 질문의 opts는 2~4개로 한다. 가장 가능성 높은 선택지 하나에만 rec를 true로 두고 why에 한 줄 근거를 적는다. label은 짧게 쓴다. 사용자는 직접 입력으로도 답할 수 있으니 모든 경우를 선택지로 나열할 필요는 없다. 질문이 아닌 일반 설명·답변은 평소대로 마크다운으로 답한다.
        """
    }

    // First-turn context for a 팀위임 discussion (chat2 preset:"team"): the chat acts as a
    // team lead who runs a parallel multi-agent debate (PM perspective vs devil's advocate)
    // over the user's pasted topic and synthesizes a decided answer — replicating the deep
    // team-discussion flow the user otherwise runs by hand in Claude Code. The agents are
    // general-purpose subagents with role prompts (NOT project agents), because this claude
    // runs from the goal folder where repo-local agent definitions are not visible.
    private func teamChatPreamble(_ scope: Scope) -> String {
        let title = DispatchQueue.main.sync {
            reviewStore.goals.first { $0.seq == scope.seq }?.text ?? ""
        }
        let dir = scope.workDir?.path ?? ""
        return """
        당신은 이 세션의 팀리드입니다. 사용자가 가져온 주제를 팀 단위로 깊게 토론해 결론을 내리는 것이 이 대화의 목적입니다.
        - 골 번호: goal-\(scope.seq)
        - 제목: \(title)
        - 작업 폴더: \(dir) (토론 산출물을 파일로 남기고 싶을 때 사용)

        진행 방식 — 반드시 이 순서대로:
        1. 파악: 사용자의 입력에서 주제와 질문들을 항목별로 정리합니다. 파일 경로·링크·첨부가 언급되면 먼저 직접 읽습니다.
        2. 팀 토론: Task(Agent) 도구로 general-purpose 서브에이전트를 최소 2개, 서로 다른 관점으로 한 메시지에서 병렬 실행합니다.
           - 팀리드/PM 관점: 원인 분석, 사용자의 각 질문에 대한 정면 답변, 주제 문서 기준의 구체적 개선안
           - 비판자(devil's advocate) 관점: 통념과 교과서식 정답까지 의심하는 반론, 리스크, 반례
           - 주제에 따라 필요하면 도메인 전문가 관점을 1개 더 추가합니다.
           각 에이전트의 프롬프트에는 사용자의 입력 전문(주제+질문)을 그대로 포함해 독립적으로 판단하게 하고, 답변은 한국어로 받습니다.
        3. 종합: 두 관점을 맞붙여 아래 순서로 정리합니다.
           - 합의된 결론
           - 이견이 남은 지점과 각 진영의 근거 (숨기지 말 것)
           - 사용자의 각 질문에 대한 최종 답 (질문마다 번호를 붙여 빠짐없이)
           - 실행 가능한 개선안 (우선순위 포함)

        규칙: 한국어로 답합니다. 결론을 먼저 쓰고 근거를 뒤에 씁니다. 토론을 시작하기 전에 사용자에게 되묻지 말고 바로 진행합니다(입력이 정말 모호할 때만 짧게 확인). 이후 사용자가 추가 질문을 하면 필요할 때 에이전트를 다시 실행해 같은 방식으로 깊게 답합니다.
        """
    }

    // First-turn context for a 계획 session (chat2 preset:"plan"): the chat acts as a planning
    // coach. Purpose: the user historically started work without a plan, burning tokens without
    // converging on a deliverable — so this preamble forces plan-first (문제정의 → 결과물 →
    // 진행 순서 → 완료 기준) and explicitly forbids starting implementation. Once the plan is
    // agreed, the user starts real work on the same goal via GUI시작.
    private func planChatPreamble(_ scope: Scope) -> String {
        let title = DispatchQueue.main.sync {
            reviewStore.goals.first { $0.seq == scope.seq }?.text ?? ""
        }
        let dir = scope.workDir?.path ?? ""
        return """
        당신은 이 세션의 플래너(계획 코치)입니다. 업무를 시작하기 전에 사용자와 함께 계획을 세우는 것이 이 대화의 유일한 목적입니다. 계획 없이 바로 실행하면 토큰만 쓰고 결과물에 집중하지 못하므로, 이 대화에서는 계획만 다룹니다.
        - 골 번호: goal-\(scope.seq)
        - 제목: \(title)
        - 작업 폴더: \(dir) (계획 산출물을 파일로 남길 때 사용)

        진행 방식 — 반드시 이 순서대로:
        1. 파악: 사용자의 입력에서 하려는 일을 정리합니다. 파일 경로·링크가 언급되면 먼저 직접 읽고, 계획에 필요한 코드·문서 조사는 해도 됩니다.
        2. 계획 수립 대화: 아래 4가지가 또렷해질 때까지 모호한 것만 골라 질문합니다.
           - 문제정의: 왜 하는가, 무엇이 문제인가 (가장 먼저 확인 — 잘못 정의하면 모든 방향이 달라집니다)
           - 최종 결과물: 끝났을 때 손에 쥐는 것이 정확히 무엇인가
           - 진행 순서: 단계별로 무엇을 어떤 순서로 하는가 (각 단계는 결과 확인이 가능한 단위로)
           - 완료 기준: 무엇이 확인되면 끝났다고 판정하는가
        3. 계획 확정: 합의되면 위 4개 항목으로 계획을 정리해 보여주고, 사용자가 승인하면 "계획이 확정되었습니다. 이 목표에서 GUI시작을 눌러 업무를 시작하세요."라고 안내합니다.

        규칙: 이 대화에서는 실제 구현·실행을 시작하지 않습니다(파일 수정과 상태를 바꾸는 명령 실행 금지, 조사를 위한 읽기만 허용). 한국어로 간결하게 답합니다.

        사용자에게 계획 질문을 할 때는 본문 마크다운으로 길게 풀어쓰지 말고, 반드시 아래 형식의 cm-question 코드블록 하나로만 출력하세요(블록 앞에 짧은 맥락 한두 줄은 두어도 됩니다).
        ```cm-question
        {"q":[{"ask":"질문 한 줄","opts":[{"label":"짧은 선택지","why":"추천 이유 한 줄","rec":true},{"label":"다른 선택지"}]}]}
        ```
        규칙: 물어볼 질문을 q 배열에 모두 담고, 각 질문의 opts는 2~4개로 한다. 가장 가능성 높은 선택지 하나에만 rec를 true로 두고 why에 한 줄 근거를 적는다. label은 짧게 쓴다. 사용자는 직접 입력으로도 답할 수 있으니 모든 경우를 선택지로 나열할 필요는 없다. 질문이 아닌 일반 설명·답변은 평소대로 마크다운으로 답한다.
        """
    }

    // Map the dashboard's model picker to a claude --model alias. "자동"/"" => nil (default).
    private static func claudeModelAlias(_ key: String) -> String? {
        switch key {
        case "fable": return "claude-fable-5"
        case "opus": return "claude-opus-4-8"
        case "sonnet": return "claude-sonnet-4-6"
        case "haiku": return "claude-haiku-4-5"
        default: return nil   // 자동: let claude use its configured default
        }
    }

    // The composer's model picker keys, whitelisted so a stray value degrades to "" (자동 =
    // leave the CLI default) instead of injecting a broken --model flag. Mirror claudeModelAlias.
    static let validComposerModels: Set<String> = ["fable", "opus", "sonnet", "haiku"]

    // Decode a browser image payload. Accepts a "data:image/png;base64,…" URL (preferred,
    // carries the type) or a bare base64 string. Returns the bytes + a best-guess extension.
    private static func decodeImageDataURL(_ s: String) -> (bytes: Data, ext: String)? {
        var b64 = s, ext = ""
        if s.hasPrefix("data:") {
            guard let comma = s.firstIndex(of: ",") else { return nil }
            let meta = s[s.index(s.startIndex, offsetBy: 5)..<comma]   // e.g. image/png;base64
            if let slash = meta.firstIndex(of: "/") {
                let after = meta[meta.index(after: slash)...]
                ext = String(after.prefix { $0.isLetter || $0.isNumber })
            }
            if ext == "jpeg" { ext = "jpg" }
            b64 = String(s[s.index(after: comma)...])
        }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (data, ext)
    }

    // The 목표 추가 composer's execution settings, whitelisted to the CLI's known values so a
    // stray/absent value degrades to "" (= leave the default) instead of a broken flag.
    //   effort → `claude --effort`     · mode → `--permission-mode`     · cwd → run folder.
    static let validEffortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]
    static let validPermissionModes: Set<String> = ["default", "acceptEdits", "plan", "auto", "bypassPermissions", "dontAsk"]
    private static func composerExec(_ obj: [String: Any]) -> (effort: String, mode: String, cwd: String, branch: String, model: String) {
        let rawEffort = ((obj["effort"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawMode = ((obj["mode"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCwd = ((obj["cwd"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawModel = ((obj["model"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Branch rides only alongside a cwd (a repo to check out in). A leading "-" is
        // rejected so a stored name can never be misread as a git flag when applied.
        var rawBranch = ((obj["branch"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if rawBranch.hasPrefix("-") || rawCwd.isEmpty { rawBranch = "" }
        let effort = validEffortLevels.contains(rawEffort) ? rawEffort : ""
        let mode = validPermissionModes.contains(rawMode) ? rawMode : ""
        let model = validComposerModels.contains(rawModel) ? rawModel : ""
        return (effort, mode, rawCwd, rawBranch, model)
    }

    // Media type for an attached image file, by extension — feeds the base64 image blocks
    // chat2RunTurn embeds in the user message (Messages-API media_type values only).
    private static func imageMime(forPath p: String) -> String {
        switch (p as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    // Save the 목표 추가 composer's image payload ([{data:"data:image/…;base64,…", name}]) into
    // `dir`, capped at 5, returning the stored filenames. Used by the goal-add / team-delegate /
    // queue-enqueue handlers so the attachments live beside the goal (goal-NN/attachments) or in
    // the queue candidate's pending staging folder. Best-effort: undecodable entries are skipped.
    private static func saveComposerImages(_ images: [[String: Any]], into dir: URL) -> [String] {
        let entries = images.prefix(5)
        guard !entries.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for img in entries {
            guard let b64 = img["data"] as? String, let d = decodeImageDataURL(b64) else { continue }
            let hint = (img["name"] as? String).map { ($0 as NSString).pathExtension } ?? ""
            var ext = d.ext.isEmpty ? hint : d.ext
            if ext.isEmpty { ext = "png" }
            let name = UUID().uuidString + "." + ext
            if (try? d.bytes.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil {
                names.append(name)
            }
        }
        return names
    }

    // MARK: Evidence files

    // Legacy on-disk folder holding a goal's uploaded files, keyed by UUID. New
    // uploads go to the number-named folder (attachmentsDir(forGoalId:)); this
    // remains for reading/cleaning files written before the move.
    static func evidenceDir(goalId: String) -> URL {
        AppPaths.sub("evidence").appendingPathComponent(goalId, isDirectory: true)
    }

    // New attachment folder for a goal, keyed by its number (goal-NN/attachments).
    // nil for an unnumbered goal (seq <= 0). Reads reviewStore — call on main.
    private func attachmentsDir(forGoalId id: String) -> URL? {
        guard let seq = reviewStore.goals.first(where: { $0.id == id })?.seq else { return nil }
        return IssuePaths.attachmentsDir(seq: seq)
    }

    // GET /evidence/<goalId>/<evidenceId> -> the stored file (bytes, MIME, name).
    // Returns nil (404) for unknown ids or missing files. Prefers the number-named
    // folder, falling back to the legacy UUID store so older uploads keep working.
    func serveEvidence(_ path: String) -> (Data, String, String)? {
        let comps = path.split(separator: "/").map(String.init)   // ["evidence", goalId, evidenceId]
        guard comps.count >= 3, comps[0] == "evidence" else { return nil }
        let goalId = comps[1], evId = comps[2]
        return DispatchQueue.main.sync {
            guard let ev = reviewStore.evidence(goalId: goalId, evidenceId: evId),
                  ev.kind == "file" else { return nil }
            var data: Data? = nil
            if let dir = attachmentsDir(forGoalId: goalId) {
                data = try? Data(contentsOf: dir.appendingPathComponent(ev.filename))
            }
            if data == nil {
                data = try? Data(contentsOf: Self.evidenceDir(goalId: goalId).appendingPathComponent(ev.filename))
            }
            guard let bytes = data else { return nil }
            let name = ev.title.isEmpty ? ev.filename : ev.title
            return (bytes, Self.mimeType(name), name)
        }
    }

    // GET /task-file?seq=NN&task=<folder>&name=<file> — download one file from a subtask's
    // own attachments/ folder. A subtask has no ReviewStore.Goal, so its attachments are
    // plain files (not evidence records); this is the file-based counterpart to
    // serveEvidence. The name is treated as a single component (no traversal).
    func serveTaskFile(_ path: String) -> (Data, String, String)? {
        guard let comps = URLComponents(string: "http://x" + path) else { return nil }
        let items = comps.queryItems ?? []
        let scope = Scope.from(query: path)
        guard scope.task != nil, let dir = scope.attachmentsDir else { return nil }
        let name = (items.first(where: { $0.name == "name" })?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != "..", !name.hasPrefix(".") else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return (bytes, Self.mimeType(name), name)
    }

    // MARK: BGM view (library manager + venue player)

    // Server-owned Korean copy for the bgm태깅관리 audit section: what each theme
    // folder is FOR in the selection strategies (선곡 목적). Themes not listed here
    // render with an empty purpose. Keyed by the first subfolder name under bgm/.
    static let bgmThemePurpose: [String: String] = [
        "office": "업무 적응 본진 — 넓은 템포 폭, 오후 집중",
        "joseon": "여유·고요한 몰입 — 점심·심야 저강도 집중",
        "ship": "하루 시동·항해감 — 아침 시작, 심야 정박",
        "england": "대항해 시동·야간 몰입 — 아침/깊은 밤",
        "mongolia": "광활한 개방감 — 아침 시동",
        "samurai": "절제된 긴장·몰입 시동 — 아침 집중",
        "lounge": "가장 낮은 템포대 — 저녁 라운지, 이완",
        "fantagy": "판타지 기분전환 — 주말 원정",
        "challenge": "마감 스퍼트 추진 — 초집중",
        "gold": "결실·보상 톤 — 금요일 아침 시동",
        "house": "고템포 추진 보조 — 마감 스퍼트",
        "steel": "묵직한 초집중 마감 — 제련 스퍼트",
        "heavy_rain": "폭우 앰비언트(무비트) — 활동 저하 시 소환, BPM 태깅 대상 아님",
        "desert": "이국적 휴식 — 오아시스 점심",
        "magic": "판타지 기분전환 — 주말 원정",
        "snow": "상쾌한 리프레시·휴식 — 저녁 스트레스 완화",
        "return": "마무리·개선 행진 — 귀환 저녁",
        "china": "옥정원 휴식 — 점심·저녁 이완",
        "peace": "평온·내려놓기 — 점심 휴식, 저녁 마무리",
        "last_goal": "최후의 목표 돌진 — 초집중 마감",
    ]

    // GET /api/bgm/list — the BGM library (BPMLibrary, scanned from the music folder)
    // as JSON for the BGM view's player. id is the index into library.tracks; the player
    // streams that file from /bgm-audio/<id>. Snapshots on main so we never race the load.
    // Each track also carries theme + bpmResolved, and the response includes a themes[]
    // summary (count / resolved / fallback / BPM range over resolved tracks / 선곡 목적)
    // for the 액티비티 tab's bgm태깅관리 audit card.
    //
    // Per-track authoring tags (BGMTags, <musicRoot>/bgm-tags.json) are joined by the
    // track's music-root-relative path (theme + "/" + filename; root files by filename
    // alone): each tracks[] item additionally carries arc/tier/purpose ("" when the
    // tags file is absent or the track is untagged — quiet, backward compatible), and
    // each themes[] item carries an "arc" distribution object
    // {intro,build,peak,resolve,ambient} for the theme-row mini summary.
    func bgmListJSON() -> String {
        func esc(_ s: String) -> String {
            var o = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n": o += "\\n"
                case "\r": o += "\\r"
                case "\t": o += "\\t"
                default:
                    if c.value < 0x20 { o += String(format: "\\u%04x", c.value) }
                    else { o.unicodeScalars.append(c) }
                }
            }
            return o
        }
        let (tracks, tagMap) = DispatchQueue.main.sync { (library.tracks, bgmTags.byPath) }
        // Music-root-relative path — the bgm-tags.json join key (see BGMTags header).
        func relPath(_ t: BPMLibrary.Track) -> String {
            let file = t.url.lastPathComponent
            return t.theme.isEmpty ? file : t.theme + "/" + file
        }
        let items = tracks.enumerated().map { (i, t) -> String in
            let bpm = t.bpm > 0 ? String(Int(t.bpm.rounded())) : "0"
            let theme = t.theme.isEmpty ? "(root)" : t.theme
            let tag = tagMap[relPath(t)]
            return "{\"id\":\(i),\"title\":\"\(esc(t.title))\",\"bpm\":\(bpm)"
                + ",\"theme\":\"\(esc(theme))\",\"bpmResolved\":\(t.bpmResolved)"
                + ",\"arc\":\"\(esc(tag?.arc ?? ""))\",\"tier\":\"\(esc(tag?.tier ?? ""))\""
                + ",\"purpose\":\"\(esc(tag?.purpose ?? ""))\"}"
        }
        // Per-theme audit summary: BPM range is computed over RESOLVED tracks only
        // (fallback tracks all sit at defaultBPM and would fake a range); 0 if none.
        // The arc distribution counts only joined tags — with no tags file it is all
        // zeros and the card's mini summary quietly disappears.
        var order: [String] = []
        var agg: [String: (count: Int, resolved: Int, minB: Double, maxB: Double)] = [:]
        var arcAgg: [String: [String: Int]] = [:]   // theme -> arc -> count
        for t in tracks {
            let name = t.theme.isEmpty ? "(root)" : t.theme
            if agg[name] == nil { order.append(name); agg[name] = (0, 0, 0, 0); arcAgg[name] = [:] }
            var a = agg[name]!
            a.count += 1
            if t.bpmResolved {
                a.minB = a.resolved == 0 ? t.bpm : min(a.minB, t.bpm)
                a.maxB = a.resolved == 0 ? t.bpm : max(a.maxB, t.bpm)
                a.resolved += 1
            }
            agg[name] = a
            if let arc = tagMap[relPath(t)]?.arc, !arc.isEmpty {
                arcAgg[name]![arc, default: 0] += 1
            }
        }
        let themes = order.map { name -> String in
            let a = agg[name]!
            let purpose = Self.bgmThemePurpose[name] ?? ""
            let arcs = arcAgg[name] ?? [:]
            let arcObj = ["intro", "build", "peak", "resolve", "ambient"]
                .map { "\"\($0)\":\(arcs[$0] ?? 0)" }.joined(separator: ",")
            return "{\"name\":\"\(esc(name))\",\"count\":\(a.count),\"resolved\":\(a.resolved)"
                + ",\"fallback\":\(a.count - a.resolved)"
                + ",\"minBpm\":\(Int(a.minB.rounded())),\"maxBpm\":\(Int(a.maxB.rounded()))"
                + ",\"purpose\":\"\(esc(purpose))\",\"arc\":{\(arcObj)}}"
        }
        return "{\"tracks\":[\(items.joined(separator: ","))],\"themes\":[\(themes.joined(separator: ","))]}"
    }

    // GET /api/bgm/stats[?strategy=N] — per-track cumulative play time, ranked
    // longest-first, for the BGM 관리 page's "재생 시간 순위" section. Merges the persisted
    // totals with the still-open segment (audio.currentSegment) so a long-playing track
    // shows fresh time without writing on every tick. bpm is looked up from the current
    // library by file name.
    //
    // Strategy filter: no param → the ACTIVE strategy (the default view watches the
    // current strategy's data accumulate); strategy=0 → 전체 (merged across strategies);
    // strategy=N → that strategy only. The response also carries the strategy catalog
    // (전략 히스토리 section) so the page needs no extra endpoint.
    func bgmStatsJSON(_ path: String) -> String {
        func esc(_ s: String) -> String {
            var o = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n": o += "\\n"
                case "\r": o += "\\r"
                case "\t": o += "\\t"
                default:
                    if c.value < 0x20 { o += String(format: "\\u%04x", c.value) }
                    else { o.unicodeScalars.append(c) }
                }
            }
            return o
        }
        // strategy=0 → 전체 (nil filter); missing → active strategy; N → that strategy.
        let stratParam = URLComponents(string: "http://x" + path)?.queryItems?
            .first(where: { $0.name == "strategy" })?.value
        return DispatchQueue.main.sync {
            let active = trackPlayStats.activeStrategy
            let filter: Int?
            if let raw = stratParam, let n = Int(raw) { filter = (n == 0) ? nil : n }
            else { filter = active }
            var totals = trackPlayStats.totals(strategy: filter)
            // Fold in the in-flight segment so the currently playing track counts live.
            // The open segment accrues under the ACTIVE strategy, so it only belongs in
            // views that include it (전체 or the active strategy itself).
            var liveKey: String? = nil
            if let seg = audio.currentSegment(), filter == nil || filter == active {
                liveKey = seg.key
                var s = totals[seg.key] ?? TrackPlayStat(key: seg.key, title: seg.title, strategy: active)
                if !seg.title.isEmpty && seg.title != "-" { s.title = seg.title }
                s.seconds += seg.seconds
                totals[seg.key] = s
            }
            let bpmByKey = Dictionary(library.tracks.map { ($0.url.lastPathComponent, $0.bpm) },
                                      uniquingKeysWith: { a, _ in a })
            let sorted = totals.values.sorted {
                $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.plays > $1.plays
            }
            let items = sorted.map { s -> String in
                let bpm = bpmByKey[s.key] ?? 0
                let bpmStr = bpm > 0 ? String(Int(bpm.rounded())) : "0"
                let cur = (s.key == liveKey)
                return "{\"title\":\"\(esc(s.title))\",\"seconds\":\(Int(s.seconds.rounded())),"
                    + "\"plays\":\(s.plays),\"bpm\":\(bpmStr),\"current\":\(cur)}"
            }
            let total = Int(totals.values.reduce(0.0) { $0 + $1.seconds }.rounded())
            // Strategy catalog for the 전략 히스토리 section + the filter buttons.
            let strategies = trackPlayStats.strategies.map { s -> String in
                "{\"id\":\(s.id),\"name\":\"\(esc(s.name))\",\"start\":\"\(esc(s.startedAt))\","
                    + "\"end\":\"\(esc(s.endedAt))\",\"summary\":\"\(esc(s.summary))\","
                    + "\"retro\":\"\(esc(s.retro))\"}"
            }
            return "{\"total\":\(total),\"strategy\":\(filter ?? 0),\"activeStrategy\":\(active),"
                + "\"strategies\":[\(strategies.joined(separator: ","))],"
                + "\"tracks\":[\(items.joined(separator: ","))]}"
        }
    }

    // GET /api/bgm/slot-scores — 전략4 · 상태 인지형 (Phase 1, observe-only): per-plan-slot
    // hit/miss scores derived by replaying the same actions.jsonl window ActionLog serves
    // (rules in BGMSlotScores.swift / docs/specs/strategy4-state-aware-bgm.md §5). Slot
    // metadata (days/from/to/themes) is joined from the live plan by label. Pure
    // read/derive — no file is written, selection and the plan are untouched.
    func bgmSlotScoresJSON() -> String {
        // ActionLog reads on its own serial queue; only the plan/catalog need main.
        let eventsJSON = ActionLog.shared.recentJSON(limit: 2000)
        return DispatchQueue.main.sync {
            let meta = bgmPlan.plan.slots.map {
                BGMSlotScores.SlotMeta(label: $0.label, days: $0.days, from: $0.from,
                                       to: $0.to, themes: $0.themes)
            }
            return BGMSlotScores.deriveJSON(eventsJSON: eventsJSON, slots: meta,
                                            activeStrategy: trackPlayStats.activeStrategy)
        }
    }

    // GET /api/bgm/boring — 전략8 · 보링 로테이션 roster snapshot: cohort membership
    // (신선 / 단골 활성 / 벤치) with each track's all-strategy cumulative heard seconds,
    // plus the epoch indexes, so the rotation is auditable ("왜 이 곡이 벤치인가").
    // Read-only: the refresh here is the same lazy epoch check selection already does.
    func bgmBoringJSON() -> String {
        DispatchQueue.main.sync {
            boredom.refreshIfNeeded()
            let heard = trackPlayStats.totals(strategy: nil).mapValues { $0.seconds }
            var freshItems: [String] = [], activeItems: [String] = [], benchItems: [String] = []
            let ranked = library.tracks.sorted {
                (heard[$0.url.lastPathComponent] ?? 0) < (heard[$1.url.lastPathComponent] ?? 0)
            }
            for t in ranked {
                let key = t.url.lastPathComponent
                let item = "{\"key\":\(jsonString(key)),\"title\":\(jsonString(t.title)),"
                    + "\"theme\":\(jsonString(t.theme)),\"heardSec\":\(Int(heard[key] ?? 0))}"
                if boredom.isBenched(key: key) { benchItems.append(item) }
                else if boredom.isFresh(key: key) { freshItems.append(item) }
                else { activeItems.append(item) }
            }
            let snap = boredom.snapshot
            return "{\"weekIndex\":\(snap?.weekIndex ?? -1),"
                + "\"biweekIndex\":\(snap?.biweekIndex ?? -1),"
                + "\"computedAt\":\(Int(snap?.computedAt ?? 0)),"
                + "\"fresh\":[\(freshItems.joined(separator: ","))],"
                + "\"active\":[\(activeItems.joined(separator: ","))],"
                + "\"benched\":[\(benchItems.joined(separator: ","))]}"
        }
    }

    // GET /api/bgm/now — what the activity-driven BGM (ConditionDirector) is playing right
    // now: the current track's library id (so the BGM view's 액티비티 탭 can load the SAME
    // file via /bgm-audio/<id>), plus condition/phase/target-BPM/profile for the status
    // card. id = -1 when nothing is playing or the track isn't in the library.
    // GET /api/bgm/plan — the 전략3 plan map plus live planning context: the slot
    // resolved for "now" and the theme folders that actually exist in the library,
    // so a planning pass (관리자 AI) can only reference real pools.
    func bgmPlanJSON() -> String {
        DispatchQueue.main.sync {
            var counts: [String: Int] = [:]
            for t in library.tracks where !t.theme.isEmpty { counts[t.theme, default: 0] += 1 }
            let themes = counts.keys.sorted()
            let themesJSON = "[" + themes.map { jsonString($0) }.joined(separator: ",") + "]"
            let countsJSON = "{" + themes.map { "\(jsonString($0)):\(counts[$0] ?? 0)" }.joined(separator: ",") + "}"
            let slot = bgmPlan.slot()
            return "{\"plan\":\(bgmPlan.planJSON()),"
                + "\"currentSlot\":\(jsonString(slot?.label ?? "")),"
                + "\"themes\":\(themesJSON),"
                + "\"themeCounts\":\(countsJSON)}"
        }
    }

    // GET /api/bgm/venue — 전략7 장소·컨디션 preset catalog plus the current pick, with
    // each preset's playable track count so the selector can flag empty pools.
    func bgmVenueJSON() -> String {
        DispatchQueue.main.sync {
            let current = director?.venue.key ?? Settings.shared.bgmVenueKey ?? VenueContext.defaultKey
            var themeCounts: [String: Int] = [:]
            for t in library.tracks where !t.theme.isEmpty { themeCounts[t.theme, default: 0] += 1 }
            let items = VenueContext.all.map { v -> String in
                let count = v.themes.reduce(0) { $0 + (themeCounts[$1] ?? 0) }
                let themesJSON = "[" + v.themes.map { jsonString($0) }.joined(separator: ",") + "]"
                return "{\"key\":\(jsonString(v.key)),\"label\":\(jsonString(v.label)),"
                    + "\"emoji\":\(jsonString(v.emoji)),\"desc\":\(jsonString(v.desc)),"
                    + "\"themes\":\(themesJSON),\"tracks\":\(count),"
                    + "\"isDefault\":\(v.key == VenueContext.defaultKey)}"
            }
            return "{\"current\":\(jsonString(current)),\"venues\":[" + items.joined(separator: ",") + "]}"
        }
    }

    func bgmNowJSON() -> String {
        func esc(_ s: String) -> String {
            var o = ""
            for c in s.unicodeScalars {
                switch c {
                case "\"": o += "\\\""
                case "\\": o += "\\\\"
                case "\n", "\r", "\t": o += " "
                default:
                    if c.value < 0x20 { o += " " } else { o.unicodeScalars.append(c) }
                }
            }
            return o
        }
        return DispatchQueue.main.sync {
            guard let director = self.director else {
                return "{\"on\":false,\"playing\":false,\"working\":false,\"muted\":\(self.session.isMuted),\"id\":-1,\"title\":\"\",\"bpm\":0,\"phase\":\"-\",\"profile\":\"-\"}"
            }
            let tracks = library.tracks
            let id = audio.currentURL.flatMap { u in tracks.firstIndex(where: { $0.url == u }) } ?? -1
            // `on` = the BGM system is engaged (widget master on & director running). `playing`
            // = a resolvable track is actually streaming right now (id valid). They differ during
            // warm-up or a library reload — the client uses `on` for the live dot and `id>=0` to
            // decide there's a real track to follow, so it never lands in a stuck limbo.
            let on = director.isPlaying
            let playing = on && !audio.isPaused && id >= 0
            let title = audio.currentTitle ?? ""
            let phase = director.isIdleMode ? "IDLE" : (director.isActive ? director.phase.rawValue : "-")
            let profile = on ? director.activeProfileLabel : "-"
            // 전략3 plan slot: resolve live (not the director's cache) so the label is
            // right even before the first decision tick. A live 폭우 리셋 overrides the
            // shown situation (it wins over the plan gate).
            let plan: String
            if director.rainActive {
                let rem = director.rainRemaining.map { " \(Int($0/60))분" } ?? ""
                plan = "🌧 폭우 리셋\(rem)"
            } else {
                plan = self.bgmPlan.slot()?.label ?? "-"
            }
            let bpm = Int(director.targetBPM.rounded())
            // 전략7: surface the venue pick so the status card shows what re-pooled selection.
            let venue = director.venue
            return "{\"on\":\(on),\"playing\":\(playing),\"working\":\(self.isWorking),\"muted\":\(self.session.isMuted),\"id\":\(id),\"title\":\"\(esc(title))\","
                + "\"bpm\":\(bpm),\"phase\":\"\(esc(phase))\",\"profile\":\"\(esc(profile))\",\"plan\":\"\(esc(plan))\","
                + "\"venue\":\"\(esc(venue.emoji + " " + venue.label))\",\"venueKey\":\"\(esc(venue.key))\"}"
        }
    }

    // GET /bgm-audio/<id> — stream one library track's raw file bytes. Same-origin, so the
    // BGM player's createMediaElementSource and offline .wav export are not CORS-tainted.
    // The track url is snapshotted on main; the (possibly large) file read stays off-main.
    func serveBGMAudio(_ path: String) -> (Data, String, String)? {
        let comps = path.split(separator: "/").map(String.init)   // ["bgm-audio", id]
        guard comps.count >= 2, comps[0] == "bgm-audio", let id = Int(comps[1]) else { return nil }
        let url: URL? = DispatchQueue.main.sync {
            let t = library.tracks
            return (id >= 0 && id < t.count) ? t[id].url : nil
        }
        guard let u = url, let bytes = try? Data(contentsOf: u) else { return nil }
        let mime: String
        switch u.pathExtension.lowercased() {
        case "mp3":          mime = "audio/mpeg"
        case "m4a", "aac":   mime = "audio/mp4"
        case "wav":          mime = "audio/wav"
        case "aiff", "aif":  mime = "audio/aiff"
        case "caf":          mime = "audio/x-caf"
        default:             mime = "application/octet-stream"
        }
        return (bytes, mime, u.lastPathComponent)
    }

    // GET /exhaust-audio/<key> — one of the exhaust ambient loops for the BGM 배기음 card
    // (recorded loops in <data>/sound/exhaust/, deliberately outside the bgm/ selection pool).
    // Whitelisted keys only, so the path can never traverse; anything else is a 404.
    func serveExhaustAudio(_ path: String) -> (Data, String, String)? {
        let comps = path.split(separator: "/").map(String.init)   // ["exhaust-audio", key]
        guard comps.count >= 2, comps[0] == "exhaust-audio" else { return nil }
        let allowed = ["lambo-idle", "lambo-city", "porsche-idle", "porsche-city"]
        guard allowed.contains(comps[1]) else { return nil }
        let url = AppPaths.sub("sound").appendingPathComponent("exhaust")
            .appendingPathComponent(comps[1] + ".wav")
        guard let bytes = try? Data(contentsOf: url) else { return nil }
        return (bytes, "audio/wav", url.lastPathComponent)
    }

    // GET /api/debug/snapshot?mode=bgm|dashboard[&tab=activity|debug] — QA-only PNG snapshot of the
    // app window's WKWebView, used to embed real per-page screenshots in SPEC.html. Requires the
    // window to already be open (does not open it itself, mirroring /api/debug/window-mode).
    func serveSnapshot(_ path: String) -> (Data, String, String)? {
        let q = URLComponents(string: "http://x" + path)?.queryItems ?? []
        let modeStr = q.first(where: { $0.name == "mode" })?.value ?? "bgm"
        let tab = q.first(where: { $0.name == "tab" })?.value
        guard let mode = AppWindowController.Mode(rawValue: modeStr) else { return nil }
        guard let png = appWindowSnapshotPNG(mode: mode, tab: tab) else { return nil }
        return (png, "image/png", "snapshot.png")
    }

    // GET /api/debug/screens/img?id=SCR-0001 — a 화면 카탈로그 entry's stored screenshot, served
    // inline for the catalog tab's grid. The id must match the strict SCR-format before it ever
    // reaches the catalog (which itself only resolves ids through its in-memory index — no
    // caller-supplied path touches the filesystem).
    func serveScreenImage(_ path: String) -> (Data, String, String)? {
        let q = URLComponents(string: "http://x" + path)?.queryItems ?? []
        guard let id = q.first(where: { $0.name == "id" })?.value,
              id.range(of: "^SCR-[0-9]{4,6}$", options: .regularExpression) != nil,
              let png = ScreenCatalog.shared.imageData(id: id) else { return nil }
        return (png, "image/png", "\(id).png")
    }

    // GET /api/debug/diag/export — every recorded 네트워크 진단 snapshot as a CSV (one row per
    // snapshot×host), for attaching to a support ticket. Time column renders in the display tz;
    // filename is stamped so multiple exports don't collide.
    func serveDiagCSV() -> (Data, String, String)? {
        let tz = Settings.shared.displayTimeZone
        let csv = DiagStore.shared.csv(timeZone: tz)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        df.timeZone = tz
        df.locale = Locale(identifier: "en_US_POSIX")
        let name = "diag-\(df.string(from: Date())).csv"
        // Prepend a UTF-8 BOM so Excel opens Korean text correctly.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(csv.utf8))
        return (data, "text/csv; charset=utf-8", name)
    }

    // MARK: Goal page (/goal?n=<NN>[&t=<task>])

    // One goal's page: number, title, key metrics, definition (goal.md) and the
    // attachment list with add/remove/download controls. Looked up by stable seq.
    // With &t=<task> it instead renders the SUBTASK page (the same interface scoped to
    // goal-NN/tasks/<task>) — handled in goalSubtaskPage.
    func goalPage(_ path: String) -> String? {
        guard let comps = URLComponents(string: "http://x" + path),
              let raw = comps.queryItems?.first(where: { $0.name == "n" })?.value else { return nil }
        let digits = raw.replacingOccurrences(of: "goal-", with: "").filter { $0.isNumber }
        guard let n = Int(digits) else { return nil }
        // A subtask request (&t=…/&task=…) routes to the subtask page; a goal request keeps
        // the exact path below unchanged.
        let scope = Scope.from(query: path)
        if let task = scope.task { return goalSubtaskPage(seq: n, task: task) }
        let goalOpt: ReviewStore.Goal? = DispatchQueue.main.sync { reviewStore.goals.first { $0.seq == n } }
        guard let goal = goalOpt else {
            // No registered Goal for this number. But a folder-only goal (e.g. an archive
            // goal created by hand and cross-linked from another goal's doc) still has a
            // goal-core.md worth showing — render it read-only so the link lands on content
            // instead of a dead end. Falls through to the real empty-state only if no folder.
            let fm = FileManager.default
            let hasFolder = IssuePaths.goalDir(seq: n).map { fm.fileExists(atPath: $0.path) } ?? false
            if hasFolder {
                Settings.shared.markActiveGoal(n, at: Date().timeIntervalSince1970)
                return goalPageHTML(seq: n, title: IssuePaths.label(seq: n) ?? "goal-\(n)", goalId: "",
                    meta: "", sessionLink: "", sessionSummary: "",
                    coreHTML: renderVersion(scope, detail: false),
                    detailHTML: renderVersion(scope, detail: true),
                    currentHTML: "", attachments: "<p class=\"empty\">등록된 골이 아니라 첨부는 표시되지 않습니다.</p>",
                    subtasks: renderSubtasks(seq: n))
            }
            return goalPageHTML(seq: n, title: "goal-\(n)", goalId: "", meta: "", sessionLink: "",
                sessionSummary: "",
                coreHTML: "<p class=\"empty\">번호 \(n)에 해당하는 골이 없습니다.</p>", detailHTML: "",
                currentHTML: "", attachments: "<p class=\"empty\">번호 \(n)에 해당하는 골이 없습니다.</p>")
        }
        migrateDefinitionIfNeeded(scope)
        // Remember this as the goal I'm actively on, so the left rail can show "보는 중"
        // and it survives an app restart (see Settings.activeGoalSeq).
        Settings.shared.markActiveGoal(n, at: Date().timeIntervalSince1970)
        return goalPageHTML(seq: n, title: goal.text, goalId: goal.id,
            meta: goalMetaLine(goal), sessionLink: goalSessionLink(goal),
            sessionSummary: goalSessionSummary(goal),
            coreHTML: renderVersion(scope, detail: false),
            detailHTML: renderVersion(scope, detail: true),
            currentHTML: renderCurrentContent(seq: n),
            attachments: renderAttachments(goal),
            subtasks: renderSubtasks(seq: n))
    }

    // The SUBTASK page: the same interface as the goal page, scoped to goal-NN/tasks/<task>.
    // Its own messenger conversation, CLI session rooted in the subtask folder, docs,
    // attachments and linked sessions — all isolated. Renders a friendly empty state if the
    // subtask folder doesn't exist. The 부분과제 section is intentionally omitted (a subtask
    // has no nested subtasks here), and the header links back to the parent goal.
    func goalSubtaskPage(seq: Int, task: String) -> String? {
        let scope = Scope(seq: seq, task: task)
        let fm = FileManager.default
        guard let work = scope.workDir, fm.fileExists(atPath: work.path) else {
            // Folder missing: a dead subtask link. Show a calm empty state that points back
            // to the parent goal instead of a 404.
            return goalPageHTML(seq: seq, task: task, title: task, goalId: "",
                meta: "", sessionLink: "", sessionSummary: "",
                coreHTML: "<p class=\"empty\">부분과제 폴더를 찾을 수 없습니다: <code>\(htmlEscape(scope.workDir?.path ?? task))</code></p>",
                detailHTML: "", currentHTML: "",
                attachments: "<p class=\"empty\">부분과제 폴더가 없습니다.</p>",
                subtasks: "",
                backHref: "/goal?n=\(seq)", backLabel: "← goal-\(seq)")
        }
        migrateDefinitionIfNeeded(scope)
        // Viewing a subtask stamps the TASK itself (task-level 보는 중), not just the parent
        // goal — the rail shows a "task-NN 보는 중" row for it. Drop the parent goal's own
        // 보는 중 marker if it was pointing here, so the task replaces the goal rather than
        // both claiming 보는 중 at once.
        let nowEpoch = Date().timeIntervalSince1970
        Settings.shared.markActiveTask(seq, task, at: nowEpoch)
        if Settings.shared.activeGoalSeq == seq {
            Settings.shared.activeGoalSeq = nil
            Settings.shared.activeGoalAt = nil
        }
        // The subtask CLI/messenger isolate per folder; "goalId" stays "" so the goal-only
        // evidence (link upload / ReviewStore) controls don't render — the subtask uses its
        // own file-based attachments instead (handled by goalPageHTML's task branch).
        return goalPageHTML(seq: seq, task: task, title: subtaskTitle(scope), goalId: "",
            meta: "", sessionLink: "", sessionSummary: subtaskSessionSummary(),
            coreHTML: renderVersion(scope, detail: false),
            detailHTML: renderVersion(scope, detail: true),
            currentHTML: "",
            attachments: renderAttachments(scope),
            subtasks: "",
            backHref: "/goal?n=\(seq)", backLabel: "← goal-\(seq)")
    }

    // The 세션 정보 card for a subtask page: no Goal lifecycle rows, just the connected-session
    // list + picker (loaded by the same loadSessions/openSessPicker JS as a goal, scoped via
    // TASK so /api/goal/sessions and the link/unlink endpoints hit the subtask's own store).
    private func subtaskSessionSummary() -> String {
        let sessUI = """
          <div class="sesshead"><span class="sklabel">연결된 세션</span><button class="lnk" onclick="openSessPicker()">+ 세션 연결</button></div>
          <div id="sessList" class="sesslist"><span class="mut">불러오는 중…</span></div>
        """
        return "<section class=\"seccard sess\"><h3>세션 정보</h3>\(sessUI)</section>"
    }

    // When a Claude session is attached to this goal, surface a clickable link to its
    // transcript (and minute-by-minute breakdown) right under the header meta line.
    // Empty when no session is linked, so the row simply doesn't render.
    private func goalSessionLink(_ g: ReviewStore.Goal) -> String {
        guard !g.sessionId.isEmpty else { return "" }
        let gid = htmlEscape(g.id)
        return """
          <div class="slink">
            <a class="chip" href="/transcript?goal=\(gid)" target="_blank" rel="noopener">🔗 세션 트랜스크립트 보기</a>
            <a class="chip" href="/breakdown?goal=\(gid)" target="_blank" rel="noopener">📊 작업 분석</a>
          </div>
        """
    }

    // A compact "세션 정보" card shown at the top of the 핵심 버전 so a goal that has only
    // been worked on via the messenger/CLI/Claude Code session still surfaces something
    // durable: current status, accumulated work time, value/tokens, the linked session id
    // and links to its transcript and minute-by-minute breakdown.
    private func goalSessionSummary(_ g: ReviewStore.Goal) -> String {
        let labels = ["backlog": "대기", "in_progress": "진행", "waiting": "응답 대기",
                      "stopped": "중지", "cancelled": "취소", "done": "완료"]
        let st = labels[g.status] ?? g.status
        let secs = g.trackedSeconds + (g.startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        var rows = ""
        rows += "<div class=\"srow\"><span class=\"sk\">상태</span><span class=\"sv\">\(htmlEscape(st))</span></div>"
        rows += "<div class=\"srow\"><span class=\"sk\">작업 시간</span><span class=\"sv\">\(h)시간 \(m)분</span></div>"
        rows += "<div class=\"srow\"><span class=\"sk\">가치 · 토큰</span><span class=\"sv\">\(g.value) · \(g.tokens)K</span></div>"
        // The session list itself is loaded by JS (loadSessions) so last-used times stay
        // fresh on reload and the picker can refresh it after linking. "세션 연결" opens the
        // recent-session picker to attach more sessions worked on this goal.
        let sessUI = """
          <div class="sesshead"><span class="sklabel">연결된 세션</span><button class="lnk" onclick="openSessPicker()">+ 세션 연결</button></div>
          <div id="sessList" class="sesslist"><span class="mut">불러오는 중…</span></div>
        """
        return "<section class=\"seccard sess\"><h3>세션 정보</h3>\(rows)\(sessUI)</section>"
    }

    // Bring an older single-version definition into the core/detail split on first page
    // open. The pre-existing detailed doc (legacy flat .issue/goal-NN.md or the folder's
    // goal.md) becomes the 디테일 버전 (goal-detail.md); the 핵심 버전 starts empty for the
    // user to fill via the messenger. Idempotent and non-destructive (a no-op once
    // goal-detail.md exists).
    private func migrateDefinitionIfNeeded(_ scope: Scope) {
        guard let dst = scope.detailURL else { return }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dst.path) else { return }
        if let task = scope.task {
            // A subtask has no legacy goal.md / flat doc lineage; instead promote the first
            // pre-existing doc it commonly carries into goal-detail.md (non-destructively),
            // leaving goal-core.md untouched so a subtask that already has one shows at once.
            guard let work = IssuePaths.taskDir(seq: scope.seq, task: task) else { return }
            for cand in ["goal.md", "문제정의.md", "readme.md", "README.md"] {
                let src = work.appendingPathComponent(cand)
                if fm.fileExists(atPath: src.path) {
                    try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.moveItem(at: src, to: dst)
                    return
                }
            }
            return
        }
        var src: URL? = nil
        if let d = IssuePaths.definitionURL(seq: scope.seq), fm.fileExists(atPath: d.path) { src = d }
        else if let l = IssuePaths.legacyDefinitionURL(seq: scope.seq), fm.fileExists(atPath: l.path) { src = l }
        guard let s = src else { return }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: s, to: dst)
    }

    // The four canonical goal sections, in order, each with the one-line purpose hint
    // surfaced under its title (mirrors .doc/goal-policy.md).
    private static let goalSectionHints: [(label: String, hint: String)] = [
        ("문제정의", "어떤 문제를 풀 것인가 — 가장 중요. 잘못 정의하면 모든 방향이 달라진다."),
        ("예상결과", "문제정의를 바텀업으로 검증하는 기대 결과."),
        ("예상해결방안", "당장 떠오르는 방향(확정 아닌 제안)."),
        ("예상테스트시나리오", "결과를 받았을 때 통과/실패를 즉시 판단하는 기준."),
    ]

    // Render one version (core or detail) as section cards. Reads the file, or returns an
    // empty-state pointing at the path + the messenger when the version is missing/blank.
    private func renderVersion(_ scope: Scope, detail: Bool) -> String {
        let url = detail ? scope.detailURL : scope.coreURL
        let fm = FileManager.default
        let text: String
        if let u = url, fm.fileExists(atPath: u.path), let data = try? Data(contentsOf: u) {
            text = String(decoding: data, as: UTF8.self)
        } else { text = "" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kind = detail ? "디테일" : "핵심"
            let p = url?.path ?? ""
            return "<p class=\"empty\">\(kind) 버전이 비어 있습니다. <code>\(htmlEscape(p))</code> 에 작성하거나, 오른쪽 메신저로 대화하며 정리하세요.</p>"
        }
        return renderGoalDoc(text)
    }

    // Split a goal markdown doc on its H2 (## ) headings into (intro, [(heading, body)]).
    private func splitSections(_ md: String) -> (intro: String, sections: [(String, String)]) {
        var sections: [(String, String)] = []
        var intro = ""
        var heading: String? = nil
        var bodyLines: [String] = []
        func flush() {
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let h = heading { sections.append((h, body)) } else { intro = body }
            bodyLines = []
        }
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                bodyLines.append(line)
            }
        }
        flush()
        return (intro, sections)
    }

    // Render a goal doc as the four canonical section cards (in policy order), each with
    // its purpose hint. Recognized headings are matched by keyword; missing ones show a
    // placeholder; any extra headings are appended after. A doc with no headings at all
    // (legacy free-form) falls back to a single raw block so old goals still read fine.
    //
    // Each body is emitted as an HTML-escaped `.mdbody` block: the raw markdown lives as the
    // element's text, and the client renders it to formatted HTML (marked.js) on load, then
    // linkifies `goal-NN` references. The edit textarea still loads the raw markdown from the
    // API, so the input screen keeps showing plain markdown while the read view is a preview.
    private func renderGoalDoc(_ md: String) -> String {
        let (intro, secs) = splitSections(md)
        if secs.isEmpty {
            let t = md.trimmingCharacters(in: .whitespacesAndNewlines)
            return "<div class=\"mdbody\">\(htmlEscape(t))</div>"
        }
        var used = Set<Int>()
        var html = ""
        if !intro.isEmpty {
            html += "<section class=\"seccard\"><div class=\"mdbody\">\(htmlEscape(intro))</div></section>"
        }
        for canon in Self.goalSectionHints {
            var bodyHTML = "<p class=\"hint\">아직 작성되지 않았습니다 — 오른쪽 메신저로 대화하며 채워 보세요.</p>"
            var filled = false
            for i in secs.indices where !used.contains(i) {
                if secs[i].0.contains(canon.label) {
                    used.insert(i)
                    let body = secs[i].1
                    if body.isEmpty {
                        bodyHTML = "<p class=\"hint\">(비어 있음)</p>"
                    } else {
                        bodyHTML = "<div class=\"mdbody\">\(htmlEscape(body))</div>"
                        filled = true
                    }
                    break
                }
            }
            html += goalSecCard(title: canon.label, hint: canon.hint, bodyHTML: bodyHTML, empty: !filled)
        }
        for i in secs.indices where !used.contains(i) {
            let body = secs[i].1
            let bodyHTML = body.isEmpty ? "" : "<div class=\"mdbody\">\(htmlEscape(body))</div>"
            html += goalSecCard(title: secs[i].0, hint: "", bodyHTML: bodyHTML, empty: body.isEmpty)
        }
        return html
    }

    // An empty section shows only its dimmed title. The purpose hint and the
    // "아직 작성되지 않았습니다" placeholder live in the card's native tooltip so they
    // surface as guidance on hover — never inside the box masquerading as content.
    // A filled section renders fully; an empty one stays quiet.
    private func goalSecCard(title: String, hint: String, bodyHTML: String, empty: Bool) -> String {
        if empty {
            let placeholder = "아직 작성되지 않았습니다 — 오른쪽 메신저로 대화하며 채워 보세요."
            let tip = hint.isEmpty ? placeholder : "\(hint)\n\(placeholder)"
            return "<section class=\"seccard secempty\" title=\"\(htmlEscape(tip))\"><h3>\(htmlEscape(title))</h3></section>"
        }
        let h = hint.isEmpty ? "" : "<div class=\"sechint\">\(htmlEscape(hint))</div>"
        return "<section class=\"seccard\"><h3>\(htmlEscape(title))</h3>\(h)\(bodyHTML)</section>"
    }

    private func renderAttachments(_ g: ReviewStore.Goal) -> String {
        if g.evidence.isEmpty {
            return "<p class=\"empty\">첨부가 없습니다. 아래에서 링크나 파일을 추가하세요.</p>"
        }
        var items = ""
        for e in g.evidence {
            let href = e.kind == "file" ? "/evidence/\(g.id)/\(e.id)" : e.url
            let icon = e.kind == "file" ? "📄" : "🔗"
            let title = e.title.isEmpty ? href : e.title
            let extra = e.kind == "file" ? " download" : " target=\"_blank\" rel=\"noopener\""
            items += "<li><a href=\"\(htmlEscape(href))\"\(extra)>\(icon) \(htmlEscape(title))</a>"
                + "<button class=\"x\" onclick=\"rm('\(htmlEscape(e.id))')\">삭제</button></li>"
        }
        return "<ul class=\"atts\">\(items)</ul>"
    }

    // A subtask has no Goal (so no ReviewStore.evidence): list the files physically present
    // in its attachments/ folder. Each downloads via /task-file?seq=&task=&name=. Removal is
    // keyed by the bare filename (rm passes it through to /api/goal/evidence/remove).
    private func renderAttachments(_ scope: Scope) -> String {
        guard let dir = scope.attachmentsDir, let task = scope.task else {
            return "<p class=\"empty\">첨부가 없습니다.</p>"
        }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path))?
            .filter { !$0.hasPrefix(".") }.sorted() ?? []
        if names.isEmpty {
            return "<p class=\"empty\">첨부가 없습니다. 아래에서 파일을 추가하세요.</p>"
        }
        let seq = scope.seq
        let tq = Self.queryEncode(task)
        var items = ""
        for name in names {
            let href = "/task-file?seq=\(seq)&task=\(tq)&name=\(Self.queryEncode(name))"
            items += "<li><a href=\"\(htmlEscape(href))\" download>📄 \(htmlEscape(name))</a>"
                + "<button class=\"x\" onclick=\"rm('\(htmlEscape(name))')\">삭제</button></li>"
        }
        return "<ul class=\"atts\">\(items)</ul>"
    }

    // Pull one frontmatter field from a _task.md (the YAML-ish "key: value" lines between
    // the leading --- fences). A trailing inline "# comment" and surrounding whitespace are
    // stripped. nil when the field is absent. Mirrors gen-index.sh's get_field so the web
    // 부분과제 table and the on-disk INDEX.md read the same anchors identically.
    private func taskField(_ md: String, _ key: String) -> String? {
        var inFM = false
        for (i, raw) in md.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if i == 0 { if trimmed == "---" { inFM = true; continue } else { return nil } }
            guard inFM else { continue }
            if trimmed == "---" { return nil }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            var v = String(line[line.index(after: colon)...])
            if let hash = v.firstIndex(of: "#") { v = String(v[v.startIndex..<hash]) }
            return v.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // The display title for a subtask: its _task.md title (preferred), else its id, else the
    // folder name. Used for the subtask page header and the chat preamble. Never empty.
    private func subtaskTitle(_ scope: Scope) -> String {
        guard let task = scope.task, let work = IssuePaths.taskDir(seq: scope.seq, task: task) else {
            return scope.task ?? "goal-\(scope.seq)"
        }
        let anchor = work.appendingPathComponent("_task.md")
        if let data = try? Data(contentsOf: anchor) {
            let md = String(decoding: data, as: UTF8.self)
            if let t = taskField(md, "title"), !t.isEmpty { return t }
            if let i = taskField(md, "id"), !i.isEmpty { return i }
        }
        return task
    }

    // A colored pill for a subtask status, mapped to a Korean label. Unknown/blank
    // statuses (folders with no _task.md anchor) show as 미정 in the muted 대기 style.
    private func subtaskStatusBadge(_ status: String) -> String {
        let map: [String: (String, String)] = [
            "DOING": ("진행", "doing"), "BLOCKED": ("막힘", "blocked"),
            "TODO": ("대기", "todo"), "DONE": ("완료", "done"), "ARCHIVED": ("보관", "arch"),
        ]
        let (label, cls) = map[status.uppercased()] ?? (status.isEmpty ? "미정" : status, "todo")
        return "<span class=\"st \(cls)\">\(htmlEscape(label))</span>"
    }

    // Coerce a JSON value that may arrive as a string or a number into a trimmed string
    // (coin/week come in either shape from the client or an AI caller). "" when absent.
    private static func numString(_ v: Any?) -> String {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespaces) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    // Folder-safe slug for a subtask title: path separators, colons, quotes and hashes
    // become '-', whitespace collapses to '-', repeats fold, edges trim, capped at 40.
    // Korean is preserved. Mirrors the constraints IssuePaths.taskDir enforces so the
    // "taskN-<slug>" folder is always creatable.
    private static func taskSlug(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "/" || ch == "\\" || ch == ":" || ch == "#" || ch == "\"" || ch.isNewline || ch == "\t" || ch == " " {
                out.append("-")
            } else { out.append(ch) }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return String(out.prefix(40))
    }

    // Sanitize a caller-supplied task FOLDER name (the rich task<N>_round<R>_<slug>_<W>w scheme
    // from the 검색→task 추가 flow). Keeps letters/digits/_/-, folds separators to "_", and
    // strips path-unsafe leads so it can never escape the tasks/ dir.
    private static func taskFolderSanitize(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" { out.append(ch) }
            else if ch == " " || ch == "." || ch == "/" || ch == "\\" || ch == ":" || ch == "#" { out.append("_") }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return String(out.prefix(60))
    }

    // Extract the leading "task<digits>" id from a folder name (task30_round29_… → "task30"),
    // used to write the _task.md anchor id when the folder was named by the rich scheme.
    private static func leadingTaskId(_ folder: String) -> String? {
        guard folder.lowercased().hasPrefix("task") else { return nil }
        var d = ""
        for ch in folder.dropFirst(4) { if ch.isNumber { d.append(ch) } else { break } }
        return d.isEmpty ? nil : "task\(d)"
    }

    // First integer immediately following `token` in `s` (e.g. token "round" in
    // "task5_round29_x" → 29). nil when the token is absent or not followed by digits.
    private static func firstIntAfter(_ s: String, token: String) -> Int? {
        guard let r = s.range(of: token) else { return nil }
        var d = ""
        for ch in s[r.upperBound...] { if ch.isNumber { d.append(ch) } else { break } }
        return Int(d)
    }

    // ISO-8601 week-of-year (KST) for the …_<W>w suffix.
    private static func isoWeek(of date: Date) -> Int {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return cal.component(.weekOfYear, from: date)
    }

    // ASCII snake_case fallback slug (used when claude is unavailable for the AI slug). Korean
    // titles yield "" here — the name then simply omits the slug segment.
    private static func asciiSlug(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) }
            else if ch == " " || ch == "-" || ch == "_" { out.append("_") }
        }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(out.prefix(24))
    }

    // Minimal one-shot `claude -p` text call (same spawn recipe as aiDedupVerdict) for small
    // synchronous asks like the task-name slug. Returns nil when claude is missing/errors.
    private func runClaudeText(_ prompt: String, timeout: TimeInterval = 45) -> String? {
        guard let claude = Self.resolveClaude() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "\(Self.shellQuote(claude)) -p --output-format text 2>/dev/null"]
        p.environment = Self.claudeEnv()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = nil
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        inPipe.fileHandleForWriting.write(Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        let s = String(decoding: outData, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    // AI half of the task name: a short english snake_case <slug> for the work + the TARGET
    // DATE the request refers to (for the ISO-week suffix). Best-effort — on any failure it
    // falls back to an ASCII slug of the goal title and today's date.
    private func aiTaskNameParts(goalTitle: String, parentSeq: Int, query: String) -> (slug: String, date: Date) {
        let today = Date()
        let kst = TimeZone(identifier: "Asia/Seoul") ?? .current
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = kst; df.dateFormat = "yyyy-MM-dd"
        let todayStr = df.string(from: today)
        let prompt = """
        You name subtask folders for a personal goal tracker. Given a parent goal and the \
        user's request, produce a SHORT english snake_case slug (2–4 words, lowercase ascii, \
        underscores only) capturing WHAT the recurring work is, and the TARGET DATE the request \
        refers to.

        PARENT GOAL: #\(parentSeq) \(goalTitle)
        USER REQUEST: \(query)
        TODAY: \(todayStr)

        Respond with ONLY one JSON object, no prose, no code fences:
        {"slug":"<snake_case>","targetDate":"YYYY-MM-DD"}
        Use TODAY when the request names no specific date.
        """
        guard let raw = runClaudeText(prompt, timeout: 45),
              let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let parsed = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any]
        else { return (Self.asciiSlug(goalTitle), today) }
        let slug = Self.taskFolderSanitize((parsed["slug"] as? String) ?? "").lowercased()
        var date = today
        if let ds = parsed["targetDate"] as? String, let d = df.date(from: ds) { date = d }
        return (slug.isEmpty ? Self.asciiSlug(goalTitle) : slug, date)
    }

    // Propose the rich subtask folder name for the 검색→task 추가 flow:
    //   task<N>_round<R>_<slug>_<W>w
    // Backend owns N (next task folder number), R (next recurring round = max existing round\d+
    // else task count), and W (ISO week of the target date); the AI supplies <slug> + the date.
    // Never creates anything — just returns a name the user can accept or edit before 생성.
    private func suggestTaskFolderName(parentSeq: Int, query: String) -> String {
        let goalTitle = reviewStore.goals.first(where: { $0.seq == parentSeq })?.text ?? ""
        var maxN = 0, maxRound = 0
        if let tdir = IssuePaths.tasksDir(seq: parentSeq),
           let entries = try? FileManager.default.contentsOfDirectory(atPath: tdir.path) {
            for name in entries where name.lowercased().hasPrefix("task") {
                var d = ""
                for ch in name.dropFirst(4) { if ch.isNumber { d.append(ch) } else { break } }
                if let n = Int(d) { maxN = max(maxN, n) }
                if let r = Self.firstIntAfter(name.lowercased(), token: "round") { maxRound = max(maxRound, r) }
            }
        }
        let taskN = maxN + 1
        let round = (maxRound > 0 ? maxRound : maxN) + 1
        let (slug, date) = aiTaskNameParts(goalTitle: goalTitle, parentSeq: parentSeq, query: query)
        let week = Self.isoWeek(of: date)
        var name = "task\(taskN)_round\(round)"
        if !slug.isEmpty { name += "_\(slug)" }
        name += "_\(week)w"
        return Self.taskFolderSanitize(name)
    }

    // MARK: 이관 (goal transfer)

    // POST /api/goal/transfer — retire a source goal into a destination goal (optionally one
    // of its tasks) by rewriting the source's goal-core.md to a canonical "[이관됨 → …]"
    // report. The whole point of a transfer is the destination LINK: it must jump straight to
    // goal-<targetSeq>[·<targetTask>] rather than only the parent goal, so the doc carries a
    // real markdown link (not a bare code path) and the same link is returned as "link".
    //
    // Body: seq (source, required), targetSeq (dest, required), and optional
    // targetTask (dest task folder), targetLabel (parenthetical goal name), reason (intro
    // line), related / relatedNote (a sibling "직접 연관" task), note ("한 줄" summary),
    // date (이관일, defaults to today), status (source goal status to set, e.g. "done").
    private func handleGoalTransfer(_ obj: [String: Any]) -> String {
        let seq = (obj["seq"] as? NSNumber)?.intValue ?? Int((obj["seq"] as? String) ?? "") ?? 0
        let targetSeq = (obj["targetSeq"] as? NSNumber)?.intValue
            ?? Int((obj["targetSeq"] as? String) ?? "") ?? 0
        guard seq > 0, targetSeq > 0 else { return "{\"ok\":false,\"error\":\"bad-request\"}" }
        if seq == targetSeq { return "{\"ok\":false,\"error\":\"self\"}" }
        func str(_ k: String) -> String {
            ((obj[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let targetTask = str("targetTask")
        // A task destination must actually exist, or the "direct link" would be a dead end —
        // the one thing this endpoint must get right.
        if !targetTask.isEmpty {
            let dir = IssuePaths.taskDir(seq: targetSeq, task: targetTask)
            guard let d = dir, FileManager.default.fileExists(atPath: d.path) else {
                return "{\"ok\":false,\"error\":\"target-task-not-found\"}"
            }
        }
        guard let coreURL = IssuePaths.coreURL(seq: seq) else {
            return "{\"ok\":false,\"error\":\"bad-source\"}"
        }
        // Default 이관일 = today (local). Callers may pass an explicit date.
        let date: String = {
            let d = str("date")
            if !d.isEmpty { return d }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
        }()
        let md = Self.transferCoreMarkdown(
            seq: seq, targetSeq: targetSeq, targetTask: targetTask,
            targetLabel: str("targetLabel"), reason: str("reason"),
            related: str("related"), relatedNote: str("relatedNote"),
            note: str("note"), date: date)
        do {
            try FileManager.default.createDirectory(
                at: coreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try md.write(to: coreURL, atomically: true, encoding: .utf8)
        } catch {
            return "{\"ok\":false,\"error\":\"write-failed\"}"
        }
        // The extracted direct link — clicking it lands straight on the destination page.
        let link = targetTask.isEmpty
            ? "/goal?n=\(targetSeq)"
            : "/goal?n=\(targetSeq)&t=\(Self.queryEncode(targetTask))"
        // Optionally close the source goal (only if a status was supplied) so a transfer can
        // also retire the source in one call without forcing it on the "100% same result" path.
        let status = str("status")
        if !status.isEmpty {
            DispatchQueue.main.sync {
                if let id = reviewStore.goals.first(where: { $0.seq == seq })?.id {
                    reviewStore.setStatus(id: id, status: status)
                }
            }
        }
        let taskJSON = targetTask.isEmpty ? "null" : jsonString(targetTask)
        return "{\"ok\":true,\"seq\":\(seq),\"targetSeq\":\(targetSeq),"
            + "\"targetTask\":\(taskJSON),\"link\":\(jsonString(link))}"
    }

    // Short "taskNN" label from a task folder name: "task29_round28_wallet_change_bug_28w"
    // → "task29". Falls back to the first segment when there is no numeric suffix.
    static func taskShortLabel(_ folder: String) -> String {
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard f.lowercased().hasPrefix("task") else {
            return String(f.prefix(while: { $0 != "_" && $0 != " " && $0 != "-" }))
        }
        var out = "task"
        for ch in f.dropFirst(4) { if ch.isNumber { out.append(ch) } else { break } }
        return out == "task" ? f : out
    }

    // Build the canonical 이관 goal-core.md. Mirrors the hand-written "[이관됨 → …]" report but
    // emits the destination as a real markdown link so it clicks straight through to the exact
    // subtask page (marked renders it on the client; linkifyGoals leaves link text alone).
    static func transferCoreMarkdown(seq: Int, targetSeq: Int, targetTask: String,
                                     targetLabel: String, reason: String,
                                     related: String, relatedNote: String,
                                     note: String, date: String) -> String {
        let goalLink = "/goal?n=\(targetSeq)"
        let hasTask = !targetTask.isEmpty
        let directLink = hasTask ? "\(goalLink)&t=\(queryEncode(targetTask))" : goalLink
        let destName = hasTask ? "goal-\(targetSeq) \(taskShortLabel(targetTask))" : "goal-\(targetSeq)"
        let labelPart = targetLabel.isEmpty ? "" : "(\(targetLabel))"
        let kind = hasTask ? "task" : "목표"

        var md = "# goal-\(seq) — 이관됨 → [\(destName)](\(directLink))\n\n"
        md += "이 목표는 **[goal-\(targetSeq)](\(goalLink))\(labelPart)** 산하 \(kind)로 이동했습니다.\n"
        if !reason.isEmpty { md += "\(reason)\n" }
        md += "\n"
        md += "- 이동 위치: [\(destName)](\(directLink))\n"
        if hasTask {
            md += "  - 핵심: `goal-core.md`\n"
            md += "  - 상세(4섹션): `goal-detail.md`\n"
        }
        if !related.isEmpty {
            let relLink = "\(goalLink)&t=\(queryEncode(related))"
            let relName = "goal-\(targetSeq) \(taskShortLabel(related))"
            let rn = relatedNote.isEmpty ? "" : " (\(relatedNote))"
            md += "- 직접 연관: [\(relName)](\(relLink))\(rn)\n"
        }
        md += "- 이관일: \(date)\n"
        if !note.isEmpty { md += "\n> 한 줄: \(note)\n" }
        return md
    }

    // Create a new 부분과제 folder (goal-NN/tasks/taskN-<slug>) and write its _task.md anchor.
    // The next task number is 1 + the largest leading number across existing task* folders,
    // so it never collides even when earlier tasks were archived. Returns the new folder
    // name, or nil for an invalid goal number or a filesystem failure.
    private func addSubtaskFolder(seq: Int, title: String, status: String,
                                  coin: String, week: String, outputs: String,
                                  explicitFolder: String? = nil) -> String? {
        guard let tasksDir = IssuePaths.tasksDir(seq: seq) else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        var maxN = 0
        if let entries = try? fm.contentsOfDirectory(atPath: tasksDir.path) {
            for name in entries where name.lowercased().hasPrefix("task") {
                var d = ""
                for ch in name.dropFirst(4) { if ch.isNumber { d.append(ch) } else { break } }
                if let n = Int(d) { maxN = max(maxN, n) }
            }
        }
        let n = maxN + 1
        // Folder name: an explicit caller-supplied name (the rich task<N>_round<R>_… scheme from
        // the 검색→task 추가 flow) wins; otherwise the legacy task<N>-<slug> default.
        var folder: String
        if let ex = explicitFolder.map({ Self.taskFolderSanitize($0) }), !ex.isEmpty {
            folder = ex
        } else {
            let slug = Self.taskSlug(title)
            folder = "task\(n)" + (slug.isEmpty ? "" : "-\(slug)")
        }
        // Never overwrite an existing folder — suffix -2, -3, … until the name is unique.
        if fm.fileExists(atPath: tasksDir.appendingPathComponent(folder).path) {
            var k = 2
            while fm.fileExists(atPath: tasksDir.appendingPathComponent("\(folder)-\(k)").path) { k += 1 }
            folder = "\(folder)-\(k)"
        }
        guard let dir = IssuePaths.taskDir(seq: seq, task: folder) else { return nil }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
        // Single-line the title so it can't break the frontmatter fences.
        let oneLine = title.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusVal = st.isEmpty ? "TODO" : st.uppercased()
        let anchorId = Self.leadingTaskId(folder) ?? "task\(n)"
        var md = "---\nid: \(anchorId)\ntitle: \(oneLine)\nstatus: \(statusVal)\n"
        if !coin.isEmpty { md += "coin: \(coin)\n" }
        if !week.isEmpty { md += "week: \(week)\n" }
        if !outputs.isEmpty { md += "outputs: \(outputs)\n" }
        md += "---\n"
        try? md.write(to: dir.appendingPathComponent("_task.md"), atomically: true, encoding: .utf8)
        return folder
    }

    // Compact subtask summary for /data.json: one JSON object per ACTIVE (non-archived)
    // tasks/<taskN> folder — {folder,id,title,status}. The dashboard 목록 renders these as
    // task rows when the 유형(type) filter includes 'task'. Goals without a tasks/ folder
    // return "" after a single failed directory read, so the per-poll cost stays tiny.
    private func subtaskSummaryJSON(seq: Int) -> String {
        guard let dir = IssuePaths.tasksDir(seq: seq),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles])
        else { return "" }
        struct Row { var name, id, title, status: String }
        var rows: [Row] = []
        for url in entries {
            let name = url.lastPathComponent
            // _session_isolation etc.; archived subtasks stay off the active dashboard list.
            if name.hasPrefix("_") || name.hasPrefix("archived") { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            var id = name, title = "", status = ""
            let anchor = url.appendingPathComponent("_task.md")
            if let data = try? Data(contentsOf: anchor) {
                let md = String(decoding: data, as: UTF8.self)
                id = taskField(md, "id") ?? name
                title = taskField(md, "title") ?? ""
                status = taskField(md, "status") ?? ""
            } else if let dash = name.firstIndex(of: "-") {
                // No anchor: split "task1-round1-kwt" into id "task1" + title "round1-kwt".
                id = String(name[name.startIndex..<dash])
                title = String(name[name.index(after: dash)...])
            }
            if status.uppercased() == "ARCHIVED" { continue }
            rows.append(Row(name: name, id: id, title: title, status: status))
        }
        // Same ordering as the goal-page table: leading task number, then name.
        func numKey(_ n: String) -> Int {
            var d = ""
            for ch in n { if ch.isNumber { d.append(ch) } else if !d.isEmpty { break } }
            return Int(d) ?? 9999
        }
        rows.sort { a, b in
            let an = numKey(a.name), bn = numKey(b.name)
            if an != bn { return an < bn }
            return a.name < b.name
        }
        return rows.map {
            "{\"folder\":\(jsonString($0.name)),\"id\":\(jsonString($0.id)),"
                + "\"title\":\(jsonString($0.title)),\"status\":\(jsonString($0.status))}"
        }.joined(separator: ",")
    }

    // Render the goal's tasks/ subfolders as a Jira-style 부분과제 table. Each child folder
    // is one subtask; a _task.md anchor (frontmatter id/title/status/coin/week/outputs)
    // supplies metadata, else the folder name is split into a short id + title. Returns ""
    // when the goal has no tasks/ folder or it holds no task subfolders, so the section
    // simply doesn't render for the vast majority of goals that don't use subtasks.
    private func renderSubtasks(seq: Int) -> String {
        guard let dir = IssuePaths.tasksDir(seq: seq) else { return "" }
        let fm = FileManager.default
        // Missing tasks/ folder is fine — the section still renders its shell so the
        // "+ 태스크 추가" control is available on every goal (0건 included).
        let entries = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        struct Row { var name, id, title, status, coin, week, outputs: String }
        var rows: [Row] = []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix("_") { continue }  // _session_isolation and other tooling
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }         // skip INDEX.md and stray files
            var id = name, title = "", status = "", coin = "", week = "", outputs = ""
            let anchor = url.appendingPathComponent("_task.md")
            let hasAnchor = fm.fileExists(atPath: anchor.path)
            if hasAnchor, let data = try? Data(contentsOf: anchor) {
                let md = String(decoding: data, as: UTF8.self)
                id = taskField(md, "id") ?? name
                title = taskField(md, "title") ?? ""
                status = taskField(md, "status") ?? ""
                coin = taskField(md, "coin") ?? ""
                week = taskField(md, "week") ?? ""
                outputs = taskField(md, "outputs") ?? ""
            }
            if !hasAnchor {
                // No anchor: split "task1-round1-kwt" into id "task1" + title "round1-kwt".
                if let dash = name.firstIndex(of: "-") {
                    id = String(name[name.startIndex..<dash])
                    title = String(name[name.index(after: dash)...])
                } else { id = name }
            }
            if name.hasPrefix("archived") && status.isEmpty { status = "ARCHIVED" }
            rows.append(Row(name: name, id: id, title: title, status: status,
                            coin: coin, week: week, outputs: outputs))
        }
        // Leading task number drives order (task1…task26); archived folders sink to the end.
        func numKey(_ n: String) -> Int {
            var d = ""
            for ch in n { if ch.isNumber { d.append(ch) } else if !d.isEmpty { break } }
            return Int(d) ?? 9999
        }
        rows.sort { a, b in
            let aa = a.name.hasPrefix("archived") ? 1 : 0, bb = b.name.hasPrefix("archived") ? 1 : 0
            if aa != bb { return aa < bb }
            let an = numKey(a.name), bn = numKey(b.name)
            if an != bn { return an < bn }
            return a.name < b.name
        }
        var body = ""
        var activeCount = 0
        for r in rows {
            // Archived subtasks are hidden by default; the 상태 filter reveals 보관/전체.
            let isArch = r.name.hasPrefix("archived") || r.status.uppercased() == "ARCHIVED"
            if !isArch { activeCount += 1 }
            let meta = [r.coin, r.week].filter { !$0.isEmpty && $0 != "-" }.joined(separator: " · ")
            let out = (r.outputs.isEmpty || r.outputs == "-") ? "" : "<code>\(htmlEscape(r.outputs))</code>"
            let shownTitle = r.title.isEmpty ? "—" : r.title
            let cls = isArch ? "subt-row arch" : "subt-row"
            let hidden = isArch ? " style=\"display:none\"" : ""
            // Each row's 태스크 id links to the subtask page (/goal?n=NN&t=<encoded folder>),
            // where the folder name (spaces/colons and all) is percent-encoded for the query.
            let href = "/goal?n=\(seq)&t=\(Self.queryEncode(r.name))"
            body += "<tr class=\"\(cls)\"\(hidden)>"
            body += "<td class=\"tid\"><a class=\"tlink\" href=\"\(htmlEscape(href))\">\(htmlEscape(r.id))</a></td>"
            body += "<td class=\"ttitle\">\(htmlEscape(shownTitle))</td>"
            body += "<td>\(subtaskStatusBadge(r.status))</td>"
            body += "<td class=\"tmeta\">\(htmlEscape(meta))</td>"
            body += "<td class=\"tout\">\(out)</td>"
            body += "</tr>"
        }
        // 상태 filter menu (mirrors the dashboard's Active/Archived/All control). All rows
        // ship in the HTML; the select just toggles row visibility client-side. The
        // "+ 태스크 추가" control opens an inline form that POSTs /api/goal/task — the same
        // endpoint an AI calls to file a task under this goal (e.g. a 주보상 패키지) instead
        // of creating a whole new goal.
        let tools = """
          <div class="subt-tools">
            <label class="subt-flt">상태 <select class="modesel" onchange="filterSubtasks(this.value)"><option value="active" selected>활성</option><option value="archived">보관</option><option value="all">전체</option></select></label>
            <button type="button" class="subt-addbtn" onclick="addSubtaskToggle()">+ 태스크 추가</button>
          </div>
          <div id="subtAddForm" class="subt-addform" style="display:none">
            <input id="subtAddTitle" type="text" placeholder="제목 (예: 주보상 패키지)" onkeydown="if(event.key==='Enter')submitSubtask()" />
            <select id="subtAddStatus" class="modesel">
              <option value="TODO" selected>대기</option>
              <option value="DOING">진행</option>
              <option value="DONE">완료</option>
              <option value="BLOCKED">막힘</option>
            </select>
            <input id="subtAddCoin" type="text" class="subt-addsm" placeholder="코인" />
            <input id="subtAddWeek" type="text" class="subt-addsm" placeholder="주차" />
            <input id="subtAddOut" type="text" placeholder="산출물" />
            <button id="subtAddBtn" type="button" class="subt-addgo" onclick="submitSubtask()">추가</button>
          </div>
        """
        // Empty goals still render the table shell (with a muted hint row) so the section
        // reads as an intentional place to add tasks, not a rendering gap.
        let tbody = rows.isEmpty
            ? "<tr class=\"subt-empty\"><td colspan=\"5\">아직 부분과제가 없습니다. “+ 태스크 추가”로 만들어 보세요.</td></tr>"
            : body
        let table = """
          <table class="subtasks">
            <thead><tr><th>태스크</th><th>제목</th><th>상태</th><th>코인·주차</th><th>산출물</th></tr></thead>
            <tbody>\(tbody)</tbody>
          </table>
        """
        let head = "<h2 class=\"atth\" onclick=\"toggleTasks()\">부분과제 <span id=\"subtCount\" class=\"subt-count\">\(activeCount)건</span> <span id=\"tasksToggle\" class=\"att-toggle\">▾ 접기</span></h2>"
        return head + "<div id=\"tasksWrap\">" + tools + table + "</div>"
    }

    private func goalMetaLine(_ g: ReviewStore.Goal) -> String {
        let labels = ["backlog": "대기", "in_progress": "진행", "waiting": "대기",
                      "stopped": "중지", "cancelled": "취소", "done": "완료"]
        let st = labels[g.status] ?? g.status
        let secs = g.trackedSeconds + (g.startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return "상태 \(htmlEscape(st)) · 가치 \(g.value) · 토큰 \(g.tokens)K · 작업 \(h)시간 \(m)분"
    }

    private func goalPageHTML(seq: Int, task: String = "", title: String, goalId: String,
                             meta: String, sessionLink: String, sessionSummary: String,
                             coreHTML: String, detailHTML: String, currentHTML: String,
                             attachments: String, subtasks: String = "",
                             backHref: String = "/", backLabel: String = "← 대시보드") -> String {
        // A subtask page renders the same interface scoped to one tasks/<task> folder. The
        // version-editor / messenger / CLI / session / attachment controls are gated on
        // having a writable scope: real goals (goalId set) or any subtask (task set).
        let isTask = !task.isEmpty
        let editable = !goalId.isEmpty || isTask
        let label = isTask ? "goal-\(seq)" : (IssuePaths.label(seq: seq) ?? "goal-\(seq)")
        // The header chip shows the goal label for a goal, or the subtask's id (its _task.md
        // id, else the leading "taskNN" piece of the folder) for a subtask.
        let numChip: String = {
            guard isTask else { return label }
            let anchor = IssuePaths.taskDir(seq: seq, task: task)?.appendingPathComponent("_task.md")
            if let a = anchor, let data = try? Data(contentsOf: a),
               let id = taskField(String(decoding: data, as: UTF8.self), "id"), !id.isEmpty { return id }
            if let dash = task.firstIndex(of: "-") { return String(task[task.startIndex..<dash]) }
            return task
        }()
        // Inline-edit controls for the 핵심 버전 (for a real goal or a subtask). The "수정"
        // button swaps the rendered display for a textarea loaded from goal-core.md;
        // 저장 writes it back via /api/goal/definition/save and reloads.
        let coreEditHead = !editable ? "" : """
          <div class="verhead">
            <button id="coreEditBtn" onclick="enterEdit()">수정</button>
            <div id="coreEditActions" class="editacts" style="display:none">
              <span id="coreDirtyChip" class="dirtychip" style="display:none">● 변경됨</span>
              <button class="save" onclick="saveCore()">저장</button>
              <button class="x" onclick="cancelEdit()">취소</button>
            </div>
          </div>
        """
        let coreEditor = !editable ? "" :
          "<textarea id=\"coreEditor\" class=\"vereditor\" style=\"display:none\" placeholder=\"핵심 버전 내용을 마크다운으로 작성하세요…\"></textarea>"
        // Double-click the rendered core version to drop into edit mode (goal or subtask).
        let coreDispAttr = !editable ? "" : " class=\"coredisp\" ondblclick=\"enterEdit()\" title=\"더블클릭하면 수정\""
        // The link-add input is goal-only (a subtask stores files in its own attachments/);
        // a subtask shows just the file picker.
        let linkInput = goalId.isEmpty ? "" : """
            <input type="text" id="lk" placeholder="https://… 링크 붙여넣기" onkeydown="if(event.key==='Enter')addLink()">
            <button onclick="addLink()">링크 추가</button>
        """
        let controls = !editable ? "" : """
          <div class="add">
            \(linkInput)
            <label class="filebtn">파일 첨부<input type="file" multiple style="display:none" onchange="addFiles(this)"></label>
          </div>
        """
        // Evidence add/remove. A real goal goes through ReviewStore (id-keyed); a subtask
        // writes into / removes from its own attachments/ folder (scope-keyed: seq+task).
        // Chat script is always present.
        let evScript = !editable ? "" : """
          <script>
          const GID=\(jsonString(goalId)); const EVTASK=\(jsonString(task));
          function post(p,b){return fetch(p,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});}
          function addLink(){const el=document.getElementById('lk');if(!el)return;const u=el.value.trim();if(!u)return;
            post('/api/goal/evidence/add',{id:GID,seq:\(seq),task:EVTASK,kind:'link',url:u}).then(()=>location.reload());}
          function addFiles(input){const fs=[...input.files];if(!fs.length)return;let done=0;
            fs.forEach(f=>{const r=new FileReader();r.onload=()=>{post('/api/goal/evidence/add',{id:GID,seq:\(seq),task:EVTASK,kind:'file',filename:f.name,data:r.result}).then(()=>{done++;if(done===fs.length)location.reload();});};r.readAsDataURL(f);});}
          function rm(eid){if(!confirm('이 첨부를 삭제할까요?'))return;post('/api/goal/evidence/remove',{id:GID,seq:\(seq),task:EVTASK,evidenceId:eid}).then(()=>location.reload());}
          </script>
        """
        // 헤더 CHAT/DETAIL 토글 — goal-add 세션 화면과 왕복하는 상시 내비게이션
        // (2026-07-19 CLI/GUI 버튼 제거 — CLI 미사용). CHAT=이 목표의 GUI 세션 뷰
        // (최신 연결 세션 이어가기), DETAIL=지금 이 화면(목표 페이지)이라 켜진 상태.
        // 부분과제 페이지는 세션 스코프가 달라 숨긴다.
        let uiSeg = isTask ? "" : """
          <div class="pseg" id="pgUiSeg"><button onclick="location.href='/goal-add?goal=\(seq)&ui=gui'" title="이 목표의 세션(채팅) 뷰로 전환합니다 — 최신 연결 세션을 이어갑니다">CHAT</button><button class="on" title="지금 이 화면 — 목표 페이지(DETAIL)">DETAIL</button></div>
          <script>try{localStorage.setItem('cm.lastTab.\(seq)','detail');}catch(e){}</script>
        """
        // 우측 메신저를 채팅 아이콘으로 여닫고(기본 접힘), 좌우 드래그로 폭을 조절한다.
        // 상태(열림/폭)는 localStorage에 저장해 페이지를 다시 열어도 유지된다.
        let chatPanelScript = """
          <script>
          (function(){
            var OPENK='cm.goalChat.open', WK='cm.goalChat.w';
            var MINW=300, body=document.body;
            function maxW(){ return Math.max(MINW, Math.min(760, window.innerWidth-360)); }
            function applyWidth(){
              var m=document.querySelector('.msgr'); if(!m) return;
              if(window.innerWidth<=1080){ m.style.width=''; return; }
              var w=parseInt(localStorage.getItem(WK)||'',10);
              if(!isNaN(w)){ m.style.width=Math.max(MINW,Math.min(maxW(),w))+'px'; }
            }
            function syncTool(){ var t=document.getElementById('chatTool');
              if(t) t.classList.toggle('on', !body.classList.contains('chat-collapsed')); }
            window.chatToggle=function(open){
              // 인자 없으면 현재 상태를 뒤집는다(상단 아이콘 토글).
              if(open===undefined){ open=body.classList.contains('chat-collapsed'); }
              try{ if(window.cmVT) cmVT.ev(open?'chatOpen':'chatClose'); }catch(e){}
              if(open){ body.classList.remove('chat-collapsed'); localStorage.setItem(OPENK,'1'); applyWidth(); }
              else{ body.classList.add('chat-collapsed'); localStorage.setItem(OPENK,'0'); }
              syncTool();
            };
            // 기본은 접힘 — 저장된 값이 '1'일 때만 열어 둔다.
            if(localStorage.getItem(OPENK)!=='1'){ body.classList.add('chat-collapsed'); }
            applyWidth(); syncTool();
            var rz=document.getElementById('msgrRz'), m=document.querySelector('.msgr'), dragging=false;
            if(rz && m){
              rz.addEventListener('pointerdown',function(e){
                if(window.innerWidth<=1080) return;
                dragging=true; rz.classList.add('drag');
                try{ rz.setPointerCapture(e.pointerId); }catch(_){}
                e.preventDefault();
              });
              rz.addEventListener('pointermove',function(e){
                if(!dragging) return;
                var w=Math.max(MINW,Math.min(maxW(), window.innerWidth-e.clientX));
                m.style.width=w+'px';
              });
              function end(){ if(!dragging) return; dragging=false; rz.classList.remove('drag');
                var w=parseInt(m.style.width,10); if(!isNaN(w)) localStorage.setItem(WK,String(w)); }
              rz.addEventListener('pointerup',end);
              rz.addEventListener('pointercancel',end);
            }
            window.addEventListener('resize',applyWidth);
          })();
          </script>
        """
        // Per-goal "목표 명확화" messenger: load history, send a turn (optimistic bubble +
        // pending placeholder while claude runs), reset. Keyed by SEQ; no template literals
        // so Swift never mistakes JS for string interpolation.
        let chatScript = """
          <script>
          const SEQ=\(seq);
          const TASK=\(jsonString(task));
          // GET query suffix carrying the scope: empty for a goal, &task=… for a subtask.
          const TQ=TASK?('&task='+encodeURIComponent(TASK)):'';
          let streaming=false, es=null, curBub=null, curText='', thinkBub=null, thinkText='', toolCards={}, lastMode='';
          function esc(s){ return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
          // Markdown: marked from CDN (lazy), with a small sanitizer; plain-text fallback offline.
          function loadMarked(){ if(window.marked) return; var s=document.createElement('script');
            s.src='https://cdn.jsdelivr.net/npm/marked/marked.min.js'; document.head.appendChild(s); }
          function sanitize(h){ return (h||'')
            .replace(/<\\/?(script|style|iframe|object|embed|link|meta|base)[^>]*>/gi,'')
            .replace(/ on[a-z]+\\s*=\\s*("[^"]*"|'[^']*'|[^\\s>]+)/gi,'')
            .replace(/javascript:/gi,''); }
          function md(text){ if(window.marked){ try{ return sanitize(window.marked.parse(text||'',{breaks:true})); }catch(e){} }
            return esc(text||'').replace(/\\n/g,'<br>'); }
          // Run cb once marked.js has loaded from the CDN, or after a short wait (fallback:
          // md() then degrades to plain text). Keeps the read view from flashing raw markdown.
          function whenMarked(cb,n){ if(window.marked){cb();return;} if((n||0)>60){cb();return;}
            setTimeout(function(){ whenMarked(cb,(n||0)+1); },50); }
          // Wrap every `goal-NN` reference inside an element's rendered text in a link to that
          // goal's page (/goal?n=NN). Walks text nodes only, skips text already inside an <a>,
          // and leaves "goalNN"/"agoal-1"/"goal-1a" alone (word boundaries).
          function linkifyGoals(root){
            var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null), nodes=[];
            while(w.nextNode()){ nodes.push(w.currentNode); }
            var re=/(^|[^A-Za-z0-9])goal-([0-9]+)(?![0-9A-Za-z])/gi;
            nodes.forEach(function(node){
              if(node.parentNode&&node.parentNode.closest&&node.parentNode.closest('a')) return;
              var t=node.nodeValue; if(!/goal-[0-9]/i.test(t)) return;
              var frag=document.createDocumentFragment(), last=0, m; re.lastIndex=0;
              while((m=re.exec(t))){
                var pre=m[1], num=m[2], full='goal-'+num, start=m.index+pre.length;
                frag.appendChild(document.createTextNode(t.slice(last,start)));
                var a=document.createElement('a'); a.className='goallink';
                a.href='/goal?n='+parseInt(num,10); a.title=full+' 페이지로 이동'; a.textContent=full;
                frag.appendChild(a); last=start+full.length;
              }
              frag.appendChild(document.createTextNode(t.slice(last)));
              node.parentNode.replaceChild(frag,node);
            });
          }
          // Turn each `.mdbody` block (raw markdown carried as its text) into a rendered
          // preview: parse with marked, then linkify goal references. The edit textarea is
          // unaffected — it still loads plain markdown from the API.
          function renderMdBodies(){
            var els=document.querySelectorAll('.mdbody:not(.rendered)');
            if(!els.length) return;
            whenMarked(function(){
              els.forEach(function(el){
                el.innerHTML=md(el.textContent); linkifyGoals(el); el.classList.add('rendered');
              });
            });
          }
          function bubble(role,text,pending,live){
            var w=document.createElement('div'); w.className='msg '+role+(pending?' pending':'');
            var b=document.createElement('div'); b.className='bub';
            if(role==='assistant'){ renderAssistant(b,text,live); } else { b.textContent=text; }
            w.appendChild(b); return w;
          }
          // 명확화 질문: 어시스턴트가 cm-question 블록으로 보낸 질문을 한 번에 하나씩
          // Claude 기본 다이얼로그형 카드로 보여주고, 모두 답하면 합쳐서 한 턴으로 전송한다.
          function extractQ(text){
            var re=/```cm-question\\s*([\\s\\S]*?)```/; var m=re.exec(text||'');
            if(!m) return {clean:(text||''), qs:null};
            var qs=null; try{ var o=JSON.parse(m[1]); qs=(o&&o.q)||null; }catch(e){ return {clean:text, qs:null}; }
            if(!qs||!qs.length) return {clean:text, qs:null};
            var clean=(text.slice(0,m.index)+text.slice(m.index+m[0].length)).trim();
            return {clean:clean, qs:qs};
          }
          function renderAssistant(b,text,live){
            var ex=extractQ(text);
            b.innerHTML = ex.clean ? md(ex.clean) : '';
            if(ex.qs) b.appendChild(buildQcard(ex.qs, live));
          }
          // 활성 카드의 키보드 핸들러는 항상 하나만 — 새 카드가 그릴 때 이전 것을 떼어낸다.
          var qKey=null;
          function setQKey(h){ if(qKey){ document.removeEventListener('keydown',qKey,true); } qKey=h; if(h){ document.addEventListener('keydown',h,true); } }
          function buildQcard(qs, live){
            var interactive = (live!==false);
            var answers=new Array(qs.length).fill(null), idx=0, sel=-1;
            var card=document.createElement('div'); card.className='qcard'+(interactive?'':' answered');
            function submit(){
              setQKey(null); card.classList.add('answered');
              var msg=qs.map(function(q,i){ return (i+1)+'. '+q.ask+' → '+(answers[i]||'(미응답)'); }).join('\\n');
              var box=document.getElementById('chatbody');
              box.appendChild(bubble('user',msg,false)); box.scrollTop=box.scrollHeight;
              lastMode=curMode(); openStream();
              fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,text:msg,mode:curMode(),model:'',allow:persistedAllow()})})
                .then(function(r){return r.json();}).then(function(d){ if(!d||!d.ok){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); } })
                .catch(function(){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); });
            }
            function advance(val){ answers[idx]=val; if(idx<qs.length-1){ idx++; draw(); } else { draw(); submit(); } }
            function confirmSel(){
              var fi=card.querySelector('.qfreein'); var fv=fi?fi.value.trim():'';
              if(fv){ advance(fv); return; }
              var opts=qs[idx].opts||[];
              if(sel>=0 && opts[sel]){ advance(opts[sel].label||('선택지 '+(sel+1))); }
            }
            function draw(){
              var q=qs[idx], opts=q.opts||[]; card.innerHTML='';
              sel=-1; for(var i=0;i<opts.length;i++){ if(opts[i].rec){ sel=i; break; } }
              if(sel<0 && opts.length) sel=0;
              var head=document.createElement('div'); head.className='qhead';
              head.innerHTML='<span class="qcount">'+(idx+1)+'/'+qs.length+'</span><span class="qtitle">'+esc(q.ask||'')+'</span>';
              var ctr=document.createElement('span'); ctr.className='qctrls';
              var col=document.createElement('button'); col.className='qicon'; col.textContent='⌄'; col.title='접기';
              var cls=document.createElement('button'); cls.className='qicon'; cls.textContent='×'; cls.title='닫기';
              ctr.appendChild(col); ctr.appendChild(cls); head.appendChild(ctr); card.appendChild(head);
              var body=document.createElement('div'); body.className='qbody'; card.appendChild(body);
              col.onclick=function(){ body.style.display=(body.style.display==='none')?'':'none'; };
              cls.onclick=function(){ setQKey(null); card.remove(); };
              function paint(){ var rs=body.querySelectorAll('.qopt'); for(var k=0;k<rs.length;k++){ rs[k].classList.toggle('sel', k===sel); } }
              opts.forEach(function(op,oi){
                var key=op.label||('선택지 '+(oi+1));
                var btn=document.createElement('button'); btn.className='qopt';
                var desc=op.why||''; if(op.rec){ desc=desc?(desc+' · 추천'):'추천'; }
                btn.innerHTML='<div class="qmain"><span class="qlabel">'+esc(key)+'</span>'+(desc?'<span class="qwhy">'+esc(desc)+'</span>':'')+'</div><span class="qnum">'+(oi+1)+'</span>';
                btn.onclick=function(){ sel=oi; var fi=card.querySelector('.qfreein'); if(fi) fi.value=''; paint(); };
                body.appendChild(btn);
              });
              var etc=document.createElement('button'); etc.className='qopt qetc';
              etc.innerHTML='<div class="qmain"><span class="qlabel">기타</span></div><span class="qnum">'+(opts.length+1)+'</span>';
              body.appendChild(etc);
              var fin=document.createElement('input'); fin.type='text'; fin.className='qfreein'; fin.placeholder='여기에 답변을 입력하세요';
              body.appendChild(fin);
              etc.onclick=function(){ sel=-1; paint(); fin.focus(); };
              fin.addEventListener('input',function(){ if(fin.value){ sel=-1; paint(); } });
              fin.addEventListener('keydown',function(e){ if(e.key==='Enter'){ e.preventDefault(); confirmSel(); } });
              var foot=document.createElement('div'); foot.className='qfoot';
              var skip=document.createElement('button'); skip.className='qskip'; skip.textContent='건너뛰기'; skip.onclick=function(){ advance(null); };
              var nb=document.createElement('button'); nb.className='qnextbtn'; nb.textContent=(idx<qs.length-1?'다음 ⏎':'완료 ⏎'); nb.onclick=function(){ confirmSel(); };
              foot.appendChild(skip); foot.appendChild(nb); card.appendChild(foot);
              paint();
              if(!interactive){ setQKey(null); return; }
              setQKey(function(e){
                var ae=document.activeElement, tag=ae?ae.tagName:'';
                if(tag==='INPUT'||tag==='TEXTAREA') return;
                if(e.key==='Enter'){ e.preventDefault(); confirmSel(); return; }
                var n=parseInt(e.key,10); if(isNaN(n)) return;
                if(n>=1 && n<=opts.length){ e.preventDefault(); sel=n-1; var fi=card.querySelector('.qfreein'); if(fi) fi.value=''; paint(); }
                else if(n===opts.length+1){ e.preventDefault(); sel=-1; paint(); fin.focus(); }
              });
            }
            draw(); return card;
          }
          // Allowlist key carries the scope so a subtask keeps its own per-folder allowlist.
          var ALLOWKEY='cmAllow:'+SEQ+(TASK?(':'+TASK):'');
          function persistedAllow(){ try{ return JSON.parse(localStorage.getItem(ALLOWKEY)||'[]'); }catch(e){ return []; } }
          function addPersistedAllow(tools){ var s=persistedAllow(); tools.forEach(function(t){ if(s.indexOf(t)<0) s.push(t); });
            try{ localStorage.setItem(ALLOWKEY, JSON.stringify(s)); }catch(e){} return s; }
          function curMode(){ var m=document.getElementById('modeSel'); return m?m.value:'bypassPermissions'; }
          function setStreaming(on){ streaming=on;
            var s=document.getElementById('btnSend'), st=document.getElementById('btnStop');
            if(s) s.style.display=on?'none':''; if(st) st.style.display=on?'':'none';
          }
          function openStream(){
            if(es) return;
            es=new EventSource('/api/goal/chat2/stream?seq='+SEQ+TQ);
            es.onmessage=function(ev){ try{ handleEvt(JSON.parse(ev.data)); }catch(e){} };
          }
          function handleEvt(o){
            var box=document.getElementById('chatbody');
            if(o.t==='start'){
              var ce=box.querySelector('.chatempty'); if(ce) ce.remove();
              curText=''; thinkText=''; thinkBub=null;
              curBub=bubble('assistant','',false); curBub.classList.add('streaming'); box.appendChild(curBub);
              setStreaming(true); box.scrollTop=box.scrollHeight;
            } else if(o.t==='delta'){
              // 턴 중 재접속(탭 이탈 후 복귀): start 를 놓쳤어도 델타를 버리지 않고
              // 스트리밍 말풍선을 만들어 이어서 보여준다 — 이전엔 턴이 끝날 때까지 침묵했다.
              if(!curBub){ curBub=bubble('assistant','',false); curBub.classList.add('streaming');
                box.appendChild(curBub); setStreaming(true); }
              curText+=o.text; var db=curBub.querySelector('.bub');
              var ci=curText.indexOf('```cm-question');
              if(ci>=0){ db.innerHTML=esc(curText.slice(0,ci))+'<span class="qhint">질문 준비 중…</span>'; }
              else { db.textContent=curText; }
              box.scrollTop=box.scrollHeight;
            } else if(o.t==='think'){
              if(!thinkBub){ thinkBub=document.createElement('div'); thinkBub.className='msg assistant thinkmsg';
                var b=document.createElement('div'); b.className='bub'; thinkBub.appendChild(b); box.appendChild(thinkBub); }
              thinkText+=o.text; thinkBub.querySelector('.bub').textContent='💭 '+thinkText; box.scrollTop=box.scrollHeight;
            } else if(o.t==='tool'){
              var arg=''; try{ if(o.input){ arg=o.input.command?('$ '+o.input.command):(o.input.file_path||(o.input.pattern||'')); if(!arg) arg=JSON.stringify(o.input); } }catch(e){}
              var card=document.createElement('div'); card.className='toolcard';
              var head=document.createElement('div'); head.className='th'; head.textContent='🔧 '+o.name+(arg?('  '+arg):'');
              var res=document.createElement('div'); res.className='tr'; res.style.display='none';
              head.onclick=function(){ res.style.display=(res.style.display==='none'&&res.textContent)?'block':'none'; };
              card.appendChild(head); card.appendChild(res); box.appendChild(card);
              if(o.id) toolCards[o.id]=res; box.scrollTop=box.scrollHeight;
            } else if(o.t==='toolresult'){
              var r=toolCards[o.id]; if(r){ r.textContent=o.text||''; if(o.isError) r.classList.add('err');
                var h=r.previousSibling; if(h&&o.text) h.classList.add('has'); }
            } else if(o.t==='done'){
              if(thinkBub){ thinkBub.remove(); thinkBub=null; }
              // 재접속으로 델타를 통째로 놓친 턴: 결과가 있으면 말풍선을 만들어 보여준다 —
              // 이전엔 새로고침 전까지 답변이 화면에 없었다.
              if(!curBub && (o.result||'')){ curBub=bubble('assistant','',false); box.appendChild(curBub); curText=''; }
              if(curBub){ curBub.classList.remove('streaming');
                var bb=curBub.querySelector('.bub'); renderAssistant(bb, curText||o.result||'', true);
                if(o.cost){ var cf=document.createElement('div'); cf.className='costline';
                  var cmm=['$'+(Math.round(o.cost*10000)/10000)];
                  if(o.tokens>0) cmm.push((o.tokens>=1000?(Math.round(o.tokens/100)/10)+'k':o.tokens)+' tokens');
                  cf.textContent=cmm.join(' · '); curBub.appendChild(cf); }
                // Plan mode: offer to execute the presented plan (resume in acceptEdits).
                if(lastMode==='plan' && !(o.denials && o.denials.length)){
                  var pb=document.createElement('button'); pb.className='planrun'; pb.textContent='이 계획대로 실행 ▶';
                  pb.onclick=function(){ pb.disabled=true; lastMode='acceptEdits'; openStream();
                    var box2=document.getElementById('chatbody'); box2.appendChild(bubble('user','(계획 승인 — 실행)',false)); box2.scrollTop=box2.scrollHeight;
                    fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,text:'위 계획을 승인합니다. 계획대로 실행하세요.',mode:'acceptEdits',modeOverride:true,allow:persistedAllow()})}).catch(function(){}); };
                  curBub.appendChild(pb);
                }
              }
              if(o.denials && o.denials.length){ renderPermission(o.denials); }
              setStreaming(false); curBub=null;
            } else if(o.t==='stopped'){
              if(curBub){ curBub.classList.remove('streaming'); }
              // 중단 가시화: user=중단, died=결과 없이 사라진 비정상 종료.
              box.appendChild(bubble('assistant',(o.reason==='died')?'⏹ 턴이 비정상 중단되었습니다 — 이어서 지시하면 계속됩니다':'⏹ 중단되었습니다',false));
              setStreaming(false); curBub=null;
            } else if(o.t==='error'){
              box.appendChild(bubble('assistant','⚠️ '+(o.message||'오류'),false)); setStreaming(false); curBub=null;
            }
          }
          // Manual mode: a turn ends with denied tools. Offer 허용/거부; 허용 resumes the
          // session with those tools allowed and nudges claude to continue (deny-replay).
          function renderPermission(denials){
            var box=document.getElementById('chatbody');
            var card=document.createElement('div'); card.className='permcard';
            var lines=denials.map(function(d){ var i=d.tool_input||{}; var a=i.command?('$ '+i.command):(i.file_path||''); return d.tool_name+(a?('  '+a):''); });
            card.innerHTML='<div class="pq">권한 요청</div><div class="pl">'+lines.map(function(n){return '<code>'+esc(n)+'</code>';}).join('<br>')+'</div>';
            var tools=denials.map(function(d){return d.tool_name;}).filter(function(v,i,a){return a.indexOf(v)===i;});
            function cont(allowList){ card.remove(); openStream();
              box.appendChild(bubble('user','(권한 허용)',false)); box.scrollTop=box.scrollHeight;
              fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,text:'권한을 허용했습니다. 방금 하려던 작업을 계속 진행하세요.',mode:curMode(),allow:allowList})}).catch(function(){});
            }
            var row=document.createElement('div'); row.className='prow';
            var allow=document.createElement('button'); allow.className='pa'; allow.textContent='허용하고 계속';
            allow.onclick=function(){ cont(persistedAllow().concat(tools)); };
            var always=document.createElement('button'); always.className='pa2'; always.textContent='항상 허용';
            always.onclick=function(){ cont(addPersistedAllow(tools)); };
            var deny=document.createElement('button'); deny.className='pd'; deny.textContent='거부';
            deny.onclick=function(){ card.remove(); };
            row.appendChild(allow); row.appendChild(always); row.appendChild(deny); card.appendChild(row);
            box.appendChild(card); box.scrollTop=box.scrollHeight;
          }
          // ── 세션 정보 탭: A안 메신저형 이어가기 ─────────────────────────────
          // 최근 연결 세션을 headless로 재개(claude -p --resume)해 이 자리에서 업무를
          // 잇는다. 컨벤션: AI는 플레인 텍스트(말풍선 없음), 도구는 요약 한 줄›드릴다운,
          // 작동 상태는 별 아이콘 애니메이션. 이벤트는 &sess=1 SSE로 분리 수신.
          var sessEs=null,sessCur=null,sessText='',sessTools=null,sessToolCount=0,sessToolCards={};
          // 상태줄 라이브 메트릭 (클로드 코드式 "3m 12s · 453 tokens"): 시작 시각과 서버가
          // stat 이벤트로 보내주는 output 토큰 누적. sessTick 이 1초마다 경과를 다시 그린다.
          var sessStart=0,sessTokens=0,sessLabel='',sessTick=null;
          function sessOpenStream(){
            if(sessEs) return;
            sessEs=new EventSource('/api/goal/chat2/stream?seq='+SEQ+TQ+'&sess=1');
            sessEs.onmessage=function(ev){ try{ sessEvt(JSON.parse(ev.data)); }catch(e){} };
          }
          function sessWorking(on,label){
            var st=document.getElementById('sessStat'); if(!st) return;
            st.classList.toggle('working',on);
            if(on){ if(label!=null) sessLabel=label; if(!sessStart) sessStart=Date.now(); }
            else { sessStart=0; sessTokens=0; sessLabel=''; }
            var paint=function(){
              var tx=document.getElementById('sessStxt'); if(!tx) return;
              if(!sessStart){ tx.textContent='대기 중 — 입력하면 최근 세션으로 이어집니다 (없으면 새 세션 시작)'; return; }
              var s=sessLabel||'작업 중…';
              var el=Math.floor((Date.now()-sessStart)/1000);
              if(el>=1) s+=' · '+(el>=60?Math.floor(el/60)+'분 ':'')+(el%60)+'초';
              if(sessTokens>0) s+=' · '+(sessTokens>=1000?(Math.round(sessTokens/100)/10)+'k':sessTokens)+' tokens';
              tx.textContent=s;
            };
            if(on){ if(!sessTick) sessTick=setInterval(paint,1000); }
            else if(sessTick){ clearInterval(sessTick); sessTick=null; }
            paint();
            var s=document.getElementById('sessSend'),x=document.getElementById('sessStopBtn');
            if(s) s.style.display=on?'none':''; if(x) x.style.display=on?'':'none';
          }
          function sessSay(){
            var ta=document.getElementById('sessIn'); if(!ta) return;
            var msg=ta.value.trim(); if(!msg) return;
            ta.value='';
            var live=document.getElementById('sessLive');
            var u=document.createElement('div'); u.className='su'; u.textContent=msg; live.appendChild(u);
            u.scrollIntoView({block:'nearest'});
            sessOpenStream(); sessWorking(true,'세션 재개 중…');
            fetch('/api/goal/session/say',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({seq:SEQ,task:TASK,text:msg,mode:'bypassPermissions',allow:persistedAllow()})})
              .then(function(r){return r.json();}).then(function(d){
                if(!d||!d.ok){ sessWorking(false);
                  var e=document.createElement('div'); e.className='sa';
                  e.textContent='⚠️ 전송 실패';
                  live.appendChild(e); }
                else if(d['new']){ sessWorking(true,'새 세션 시작 중…'); }
              }).catch(function(){ sessWorking(false); });
          }
          function sessStop(){
            fetch('/api/goal/session/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK})}).catch(function(){});
          }
          function sessEvt(o){
            var live=document.getElementById('sessLive'); if(!live) return;
            if(o.t==='start'){
              sessText=''; sessCur=null; sessTools=null; sessToolCount=0; sessToolCards={};
              sessStart=Date.now(); sessTokens=0;
              sessWorking(true,'작업 중…');
            } else if(o.t==='stat'){
              if(o.tokens) sessTokens=o.tokens;
              if(sessStart) sessWorking(true);
            } else if(o.t==='delta'){
              if(!sessCur){ sessCur=document.createElement('div'); sessCur.className='sa'; live.appendChild(sessCur); }
              sessText+=o.text; sessCur.textContent=sessText; sessCur.scrollIntoView({block:'nearest'});
            } else if(o.t==='tool'){
              if(!sessTools){
                var sum=document.createElement('div'); sum.className='stoolsum';
                var box=document.createElement('div'); box.className='stoolbox';
                sum.onclick=function(){ box.classList.toggle('open'); };
                live.appendChild(sum); live.appendChild(box);
                sessTools={sum:sum,box:box};
                sessCur=null; // 도구 뒤 텍스트는 새 문단으로
              }
              sessToolCount++;
              sessTools.sum.textContent='사용함 도구 '+sessToolCount+'개 ›';
              var arg=''; try{ if(o.input){ arg=o.input.command?('$ '+o.input.command):(o.input.file_path||o.input.pattern||''); } }catch(e){}
              var row=document.createElement('div'); row.className='strow'; row.textContent=o.name+(arg?('  '+arg):'');
              var det=document.createElement('div'); det.className='strdet';
              row.onclick=function(){ if(det.textContent) det.classList.toggle('open'); };
              sessTools.box.appendChild(row); sessTools.box.appendChild(det);
              if(o.id) sessToolCards[o.id]=det;
              sessWorking(true,'작업 중 — '+o.name);
            } else if(o.t==='toolresult'){
              var r=sessToolCards[o.id]; if(r) r.textContent=o.text||'';
            } else if(o.t==='done'){
              var fin=sessText||o.result||'';
              if(sessCur){ try{ sessCur.innerHTML=md(fin); }catch(e){ sessCur.textContent=fin; } }
              else if(fin){ var d2=document.createElement('div'); d2.className='sa';
                try{ d2.innerHTML=md(fin); }catch(e){ d2.textContent=fin; } live.appendChild(d2); }
              if(o.cost){ var c=document.createElement('div'); c.className='scost';
                var cm=['$'+(Math.round(o.cost*10000)/10000)];
                if(o.tokens>0) cm.push((o.tokens>=1000?(Math.round(o.tokens/100)/10)+'k':o.tokens)+' tokens');
                if(sessStart){ var ce=Math.floor((Date.now()-sessStart)/1000);
                  if(ce>=1) cm.push((ce>=60?Math.floor(ce/60)+'분 ':'')+(ce%60)+'초'); }
                c.textContent=cm.join(' · '); live.appendChild(c); }
              sessWorking(false); sessCur=null; sessTools=null;
              if(typeof loadSessions==='function') loadSessions(); // 이어진(포크된) 세션이 목록에 반영
            } else if(o.t==='stopped'){
              // 중단 가시화: user=중단 버튼, died=결과 없이 사라진 비정상 종료.
              var n2=document.createElement('div'); n2.className='sa';
              n2.textContent=(o.reason==='died')?'⏹ 턴이 비정상 중단되었습니다 — 이어서 지시하면 계속됩니다':'⏹ 중단되었습니다 — 이어서 지시하면 계속됩니다';
              live.appendChild(n2);
              sessWorking(false); sessCur=null; sessTools=null;
            } else if(o.t==='error'){
              var e2=document.createElement('div'); e2.className='sa'; e2.textContent='⚠️ '+(o.message||'오류');
              live.appendChild(e2); sessWorking(false); sessCur=null; sessTools=null;
            }
          }
          (function(){
            var ta=document.getElementById('sessIn'); if(!ta) return;
            ta.addEventListener('keydown',function(e){ if(e.key==='Enter'&&!e.shiftKey){ e.preventDefault(); sessSay(); } });
          })();
          // 페이지 진입 시 중단 여부 복원: 이 스코프의 sess 채널 턴이 아직 돌고 있으면
          // 스트림을 열어 이어서 수신하고, 직전 턴이 중단/비정상 종료로 끝났으면 상태줄에
          // 표시한다 — 떠나 있던 동안 무슨 일이 있었는지 알 수 있게 (/api/goal/chat2/state).
          (function(){
            var q='/api/goal/chat2/state?seq='+SEQ+(TASK?('&task='+encodeURIComponent(TASK)):'')+'&sess=1';
            fetch(q).then(function(r){return r.json();}).then(function(d){
              if(!d) return;
              if(d.running){
                sessOpenStream();
                // 경과·토큰을 서버 상태로 복원해 상태줄이 "3분 12초 · 453 tokens"처럼
                // 실제 진행량을 보여준다 (at=턴 시작 ms). 여러 턴이 돌면 개수도 표시.
                if(d.at) sessStart=d.at;
                if(d.tokens) sessTokens=d.tokens;
                var lab='작업 중'+(d.label?(' — '+d.label):'')+' · 진행 중인 턴을 이어서 수신합니다';
                if(d.totalRunning>1) lab+=' · 실행 중 작업 '+d.totalRunning+'개';
                sessWorking(true,lab); return;
              }
              if(d.state!=='stopped'&&d.state!=='died'&&d.state!=='error') return;
              var tx=document.getElementById('sessStxt'); if(!tx) return;
              var lab=(d.state==='stopped')?'중단되었습니다(사용자 중단)':(d.state==='died')?'비정상 종료되었습니다':'오류로 끝났습니다';
              tx.textContent='대기 중 — 직전 턴이 '+lab+' · 입력하면 이어집니다';
            }).catch(function(){});
          })();
          function showVer(v){
            document.getElementById('ver-core').style.display=(v==='core')?'':'none';
            document.getElementById('ver-detail').style.display=(v==='detail')?'':'none';
            document.getElementById('ver-session').style.display=(v==='session')?'':'none';
            document.getElementById('btnCore').classList.toggle('on',v==='core');
            document.getElementById('btnDetail').classList.toggle('on',v==='detail');
            document.getElementById('btnSession').classList.toggle('on',v==='session');
          }
          // 첨부 interface stays hidden until the heading is clicked — keeps the page calm.
          function toggleAtt(){
            var w=document.getElementById('attWrap'), t=document.getElementById('attToggle');
            var open=(w.style.display==='none'); w.style.display=open?'':'none';
            if(t) t.textContent=open?'▾ 접기':'▸ 펼치기';
          }
          // 부분과제 starts expanded (it's the Jira-style subtask list); the heading collapses it.
          function toggleTasks(){
            var w=document.getElementById('tasksWrap'), t=document.getElementById('tasksToggle');
            if(!w) return;
            var open=(w.style.display==='none'); w.style.display=open?'':'none';
            if(t) t.textContent=open?'▾ 접기':'▸ 펼치기';
          }
          // 상태 filter: active hides archived rows (default), archived shows only them, all shows everything.
          function filterSubtasks(v){
            var rows=document.querySelectorAll('#tasksWrap tr.subt-row'), shown=0;
            rows.forEach(function(r){
              var arch=r.classList.contains('arch');
              var vis=(v==='all')||(v==='archived'?arch:!arch);
              r.style.display=vis?'':'none'; if(vis) shown++;
            });
            var c=document.getElementById('subtCount'); if(c) c.textContent=shown+'건';
          }
          // 부분과제 추가: reveal the inline form and focus the title.
          function addSubtaskToggle(){
            var f=document.getElementById('subtAddForm'); if(!f) return;
            var open=(f.style.display==='none'); f.style.display=open?'':'none';
            if(open){ var t=document.getElementById('subtAddTitle'); if(t) t.focus(); }
          }
          // POST /api/goal/task — creates a tasks/<taskN> folder under this goal and reloads
          // to show it. The same endpoint the AI uses, so a task can be filed with or without
          // the user. 제목 is required; 상태/코인/주차/산출물 are optional metadata.
          function submitSubtask(){
            var titleEl=document.getElementById('subtAddTitle'); if(!titleEl) return;
            var title=titleEl.value.trim(); if(!title){ titleEl.focus(); return; }
            var g=function(id){ var e=document.getElementById(id); return e?e.value.trim():''; };
            var btn=document.getElementById('subtAddBtn'); if(btn) btn.disabled=true;
            fetch('/api/goal/task',{method:'POST',headers:{'Content-Type':'application/json'},
              body:JSON.stringify({seq:SEQ,title:title,status:g('subtAddStatus'),
                coin:g('subtAddCoin'),week:g('subtAddWeek'),outputs:g('subtAddOut')})})
              .then(function(r){return r.json();})
              .then(function(d){ if(d&&d.ok){ location.reload(); }
                else { if(btn) btn.disabled=false; alert('태스크 추가 실패'); } })
              .catch(function(){ if(btn) btn.disabled=false; });
          }
          function renderChat(d){
            var box=document.getElementById('chatbody'); box.innerHTML='';
            var msgs=(d&&d.messages)||[];
            if(!msgs.length){ var e=document.createElement('div'); e.className='chatempty';
              e.textContent='이 목표를 대화로 명확히 해보세요. 문제정의부터 점검합니다.'; box.appendChild(e); }
            msgs.forEach(function(m){ box.appendChild(bubble(m.role,m.text,false)); });
            box.scrollTop=box.scrollHeight;
          }
          function loadChat(){ fetch('/api/goal/chat?seq='+SEQ+TQ).then(function(r){return r.json();})
            .then(function(d){ renderChat(d); sendTeamKick(); }).catch(function(){}); }
          // 팀위임/계획/세션시작 hand-off: another page stashes the first-turn text in
          // sessionStorage and navigates here; fire it as the first chat2 turn. cmTeamKick
          // (rail 팀위임) runs with preset:'team' (the team-lead debate preamble); cmPlanKick
          // (rail 계획) with preset:'plan' (the planning-coach preamble); cmGoalKick
          // (목표 추가 페이지의 세션시작) is a plain work-kick carrying the composer's 작업
          // 모드. Runs after renderChat so the optimistic user bubble is never wiped by the
          // history load.
          function sendTeamKick(){
            if(TASK) return;
            var v=null, preset='team', mode='bypassPermissions';
            try{ var k='cmTeamKick:'+SEQ; v=sessionStorage.getItem(k); if(v) sessionStorage.removeItem(k); }catch(e){}
            if(!v){
              try{ var pk='cmPlanKick:'+SEQ; var p=sessionStorage.getItem(pk);
                if(p){ sessionStorage.removeItem(pk); v=p; preset='plan'; } }catch(e){}
            }
            if(!v){
              try{ var gk='cmGoalKick:'+SEQ; var g=sessionStorage.getItem(gk);
                if(g){ sessionStorage.removeItem(gk); var o=JSON.parse(g);
                  v=String(o.text||''); mode=o.mode||'bypassPermissions'; preset=''; } }catch(e){}
            }
            if(!v||streaming) return;
            var box=document.getElementById('chatbody');
            var ce=box.querySelector('.chatempty'); if(ce) ce.remove();
            box.appendChild(bubble('user',v,false)); box.scrollTop=box.scrollHeight;
            lastMode=mode; openStream();
            fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:'',text:v,mode:mode,model:'',allow:persistedAllow(),preset:preset})})
              .then(function(r){return r.json();}).then(function(d){ if(!d||!d.ok){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); } })
              .catch(function(){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); });
          }
          function sendChat(){
            var t=document.getElementById('ci'); var v=t.value.trim(); if(!v||streaming) return;
            t.value=''; t.style.height='auto';
            var box=document.getElementById('chatbody');
            var ce=box.querySelector('.chatempty'); if(ce) ce.remove();
            box.appendChild(bubble('user',v,false)); box.scrollTop=box.scrollHeight;
            lastMode=curMode(); openStream();
            fetch('/api/goal/chat2/say',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,text:v,mode:curMode(),model:'',allow:persistedAllow()})})
              .then(function(r){return r.json();}).then(function(d){ if(!d||!d.ok){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); } })
              .catch(function(){ box.appendChild(bubble('assistant','⚠️ 전송 실패',false)); });
          }
          function stopChat(){ fetch('/api/goal/chat2/stop',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK})}).catch(function(){}); }
          function resetChat(){ if(!confirm('이 목표의 대화를 새로 시작할까요?')) return;
            fetch('/api/goal/chat/reset',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK})})
              .then(function(r){return r.json();}).then(renderChat); }
          function openCLI(){ cliOpen(); }
          // Inline edit of the 핵심 버전: load raw markdown into the textarea, save it back.
          // Swap the rendered display for the textarea, size it to its content, focus it.
          // coreOrig snapshots the loaded text so we can tell whether the editor is dirty
          // (unsaved changes) — drives the ESC discard prompt and the "변경됨" highlight.
          var coreOrig='';
          function coreDirty(){ var ed=document.getElementById('coreEditor'); return !!ed && ed.value!==coreOrig; }
          // Reflect dirty state: accent the editor border + reveal the "변경됨" chip.
          function updateCoreDirty(){
            var ed=document.getElementById('coreEditor'); if(!ed) return;
            var dirty=coreDirty();
            ed.classList.toggle('dirty',dirty);
            var chip=document.getElementById('coreDirtyChip');
            if(chip) chip.style.display=dirty?'inline-flex':'none';
          }
          function showCoreEditor(){
            var ed=document.getElementById('coreEditor');
            document.getElementById('coreDisplay').style.display='none';
            ed.style.display='block';
            ed.style.height='auto'; ed.style.height=Math.max(300,ed.scrollHeight)+'px';
            document.getElementById('coreEditBtn').style.display='none';
            document.getElementById('coreEditActions').style.display='flex';
            coreOrig=ed.value; updateCoreDirty();
            ed.focus();
            return ed;
          }
          function enterEdit(){
            fetch('/api/goal/definition?seq='+SEQ+TQ+'&kind=core').then(function(r){return r.json();}).then(function(d){
              document.getElementById('coreEditor').value=(d&&d.text)||'';
              showCoreEditor();
            }).catch(function(){ alert('불러오기에 실패했습니다.'); });
          }
          // Locate the "## <label>" section in the markdown (matched like the server: a
          // line that starts with "## " whose title contains the label). Returns the text
          // to load plus the caret offset to drop the user at. If the section is missing,
          // append the heading; otherwise place the caret at the end of its body.
          function sectionCaret(text, label){
            var lines=text.split('\\n');
            var hi=-1;
            for(var i=0;i<lines.length;i++){
              if(lines[i].slice(0,3)==='## ' && lines[i].slice(3).indexOf(label)>=0){ hi=i; break; }
            }
            if(hi<0){
              var t=text.replace(/\\s+$/,'');
              var nt=(t.length?t+'\\n\\n':'')+'## '+label+'\\n';
              return {text:nt, caret:nt.length};
            }
            var end=lines.length;
            for(var j=hi+1;j<lines.length;j++){ if(lines[j].slice(0,3)==='## '){ end=j; break; } }
            var last=end-1;
            while(last>hi && lines[last].trim()===''){ last--; }
            return {text:text, caret:lines.slice(0,last+1).join('\\n').length};
          }
          // Click an empty section card -> open the editor with that heading inserted and
          // the caret under it, so the user types straight into the right place.
          function editSection(label){
            if(!label) return;
            fetch('/api/goal/definition?seq='+SEQ+TQ+'&kind=core').then(function(r){return r.json();}).then(function(d){
              var ed=document.getElementById('coreEditor');
              var r=sectionCaret((d&&d.text)||'', label);
              ed.value=r.text;
              showCoreEditor();
              ed.setSelectionRange(r.caret, r.caret);
            }).catch(function(){ alert('불러오기에 실패했습니다.'); });
          }
          // Close the editor. No changes → close straight away; dirty → confirm once
          // before discarding. Shared by the 취소 button and the ESC key.
          function cancelEdit(){
            if(coreDirty() && !confirm('변경사항을 저장하지 않았습니다. 버리고 닫을까요?')) return;
            document.getElementById('coreEditor').style.display='none';
            document.getElementById('coreDisplay').style.display='';
            document.getElementById('coreEditBtn').style.display='';
            document.getElementById('coreEditActions').style.display='none';
          }
          function saveCore(){
            var text=document.getElementById('coreEditor').value;
            fetch('/api/goal/definition/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,kind:'core',text:text})})
              .then(function(r){return r.json();}).then(function(d){ if(d&&d.ok){ location.reload(); } else { alert('저장에 실패했습니다: '+((d&&d.error)||'?')); } })
              .catch(function(){ alert('저장에 실패했습니다.'); });
          }
          document.addEventListener('DOMContentLoaded',function(){
            loadMarked(); renderMdBodies(); loadChat(); openStream();
            // 메신저 채널 턴이 돌고 있는 채로 돌아온 경우: 중지 버튼/스트리밍 상태를 복원해
            // "진행 중"임을 바로 보여준다 (이어지는 델타는 handleEvt 가 말풍선을 재생성).
            fetch('/api/goal/chat2/state?seq='+SEQ+(TASK?('&task='+encodeURIComponent(TASK)):''))
              .then(function(r){return r.json();})
              .then(function(d){ if(d&&d.running) setStreaming(true); }).catch(function(){});
            // Make each empty 핵심 버전 section card click-to-write (gated on the editor existing).
            var cd=document.getElementById('coreDisplay');
            var ced=document.getElementById('coreEditor');
            if(cd&&ced){
              cd.querySelectorAll('.seccard.secempty').forEach(function(card){
                card.addEventListener('click',function(){
                  var h=card.querySelector('h3'); editSection(h?h.textContent.trim():'');
                });
              });
              // Live-highlight unsaved changes; ESC closes (with a discard prompt if dirty).
              ced.addEventListener('input',updateCoreDirty);
              ced.addEventListener('keydown',function(e){ if(e.key==='Escape'){ e.preventDefault(); cancelEdit(); } });
            }
            var ms=document.getElementById('modeSel');
            if(ms){ var saved=localStorage.getItem('cmChatMode'); if(saved) ms.value=saved;
              ms.addEventListener('change',function(){ localStorage.setItem('cmChatMode',ms.value); }); }
            var ci=document.getElementById('ci');
            ci.addEventListener('keydown',function(e){ if(e.key==='Enter'&&!e.shiftKey){ e.preventDefault(); sendChat(); } });
            ci.addEventListener('input',function(){ ci.style.height='auto'; ci.style.height=Math.min(160,ci.scrollHeight)+'px'; });
          });
          </script>
        """
        // In-page CLI terminal: the shared web-terminal engine CMWebCLI (Sources/WebCLI,
        // WebCLITerminal.script()) drives xterm + the /api/goal/cli/* polling bridge; this
        // block is only the page adapter — overlay show/hide, state label, start payload.
        // xterm version bumps / IME handling / polling all live in the WebCLI target.
        let cliScript = WebCLITerminal.script() + """
          <script>
          (function(){
            var ctl=null;
            function setState(txt,cls){ var e=document.getElementById('cliState'); if(e){ e.textContent=txt; e.className='st'+(cls?(' '+cls):''); } }
            window.cliOpen=function(){
              try{ if(window.cmVT) cmVT.ev('cliOpen goal '+SEQ); }catch(e){}
              var ov=document.getElementById('cliOverlay'); ov.style.display='flex';
              if(!ctl){ ctl=CMWebCLI.create({termEl:document.getElementById('cliTerm'),onState:setState}); }
              else { ctl.reset(); }   // reconnect replays the PTY buffer from offset 0
              ctl.connect(function(cols,rows){
                return fetch('/api/goal/cli/start',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,cols:cols,rows:rows})});
              });
              ctl.focus();
            };
            // 닫기 = background, NOT kill. Stop polling + hide the overlay, but leave the PTY
            // running server-side so the session keeps working and can be reopened from the
            // left rail (which replays the buffer). Explicit termination is the rail's × .
            window.cliClose=function(){
              try{ if(window.cmVT) cmVT.ev('cliClose goal '+SEQ); }catch(e){}
              if(ctl) ctl.disconnect();
              var ov=document.getElementById('cliOverlay'); if(ov) ov.style.display='none';
            };
            window.addEventListener('resize',function(){ var ov=document.getElementById('cliOverlay'); if(ov&&ov.style.display!=='none'&&ctl) ctl.fit(); });
            document.addEventListener('keydown',function(e){ var ov=document.getElementById('cliOverlay'); if(e.key==='Escape'&&ov&&ov.style.display!=='none'){ cliClose(); } });
            // Navigating away no longer kills the session — it backgrounds it. No unload beacon.
            // Auto-open when arrived via the rail (/goal?n=NN&cli=1): reconnect to the live PTY.
            try{ if(new URLSearchParams(location.search).get('cli')==='1'){
              if(document.readyState==='loading'){ document.addEventListener('DOMContentLoaded', function(){ cliOpen(); }); }
              else { cliOpen(); }
            } }catch(e){}
          })();
          </script>
        """
        // 세션 목록 + "세션 연결" 피커: loads the goal's associated sessions (last-used time +
        // resume command), and a recent-session picker to attach more. Only present when the
        // goal exists (SEQ is real); reuses SEQ from chatScript.
        let sessScript = !editable ? "" : """
          <script>
          (function(){
            function rel(now,then){ if(!then) return '기록 없음'; var s=Math.max(0,now-then);
              if(s<60) return '방금'; var m=Math.floor(s/60); if(m<60) return m+'분 전';
              var h=Math.floor(m/60); if(h<24) return h+'시간 전'; var d=Math.floor(h/24); return d+'일 전'; }
            function esc(t){ var d=document.createElement('div'); d.textContent=(t==null?'':t); return d.innerHTML; }
            window.loadSessions=function(){
              fetch('/api/goal/sessions?seq='+SEQ+TQ).then(function(r){return r.json();}).then(function(d){
                var box=document.getElementById('sessList'); if(!box) return;
                var now=(d&&d.now)||0, list=(d&&d.sessions)||[];
                if(!list.length){ box.innerHTML='<span class="mut">연결된 세션이 없습니다. 아래 입력창에 지시하면 새 세션이 시작됩니다. (“+ 세션 연결”로 기존 세션 연결도 가능)</span>'; return; }
                box.innerHTML='';
                list.forEach(function(s){
                  var row=document.createElement('div'); row.className='sessitem'+(s.exists?'':' gone');
                  var head=document.createElement('div'); head.className='shead';
                  head.innerHTML='<span class="src">'+esc(s.source)+'</span><span class="stitle">'+esc(s.title)+'</span><span class="sage">'+(s.exists?rel(now,s.lastUsed):'파일 없음')+'</span>';
                  row.appendChild(head);
                  var act=document.createElement('div'); act.className='sact';
                  var resume=document.createElement('code'); resume.className='rcmd'; resume.textContent=s.resume; act.appendChild(resume);
                  var cp=document.createElement('button'); cp.className='mini'; cp.textContent='복사';
                  cp.onclick=function(){ (navigator.clipboard?navigator.clipboard.writeText(s.resume):Promise.reject()).then(function(){ cp.textContent='복사됨'; setTimeout(function(){cp.textContent='복사';},1200); }).catch(function(){}); };
                  act.appendChild(cp);
                  if(s.exists){ var tr=document.createElement('a'); tr.className='mini'; tr.href='/transcript?session='+encodeURIComponent(s.id); tr.target='_blank'; tr.rel='noopener'; tr.textContent='트랜스크립트'; act.appendChild(tr); }
                  if(s.removable){ var rm=document.createElement('button'); rm.className='mini x'; rm.textContent='해제'; rm.onclick=function(){ unlinkSession(s.id); }; act.appendChild(rm); }
                  row.appendChild(act); box.appendChild(row);
                });
              }).catch(function(){});
            };
            window.unlinkSession=function(id){
              fetch('/api/goal/session/unlink',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,sessionId:id})}).then(function(){ loadSessions(); });
            };
            window.openSessPicker=function(){
              var ov=document.getElementById('sessPicker'); ov.style.display='flex';
              var body=document.getElementById('pickBody'); body.innerHTML='<span class="mut">최근 세션 불러오는 중…</span>';
              fetch('/api/sessions/recent?seq='+SEQ+TQ).then(function(r){return r.json();}).then(function(d){
                var now=(d&&d.now)||0, list=(d&&d.sessions)||[];
                if(!list.length){ body.innerHTML='<span class="mut">최근 Claude 세션을 찾지 못했습니다.</span>'; return; }
                body.innerHTML='';
                list.forEach(function(s){
                  var lab=document.createElement('label'); lab.className='pickrow'+(s.linked?' linked':'');
                  var cb=document.createElement('input'); cb.type='checkbox'; cb.value=s.id; cb.disabled=!!s.linked; cb.checked=!!s.linked;
                  lab.appendChild(cb);
                  var meta=document.createElement('div'); meta.className='pmeta';
                  meta.innerHTML='<div class="ptitle">'+esc(s.title)+'</div><div class="page">'+rel(now,s.lastUsed)+(s.linked?' · 이미 연결됨':'')+'</div>';
                  lab.appendChild(meta); body.appendChild(lab);
                });
              }).catch(function(){ body.innerHTML='<span class="mut">불러오기에 실패했습니다.</span>'; });
            };
            window.closeSessPicker=function(){ var ov=document.getElementById('sessPicker'); if(ov) ov.style.display='none'; };
            window.confirmSessLink=function(){
              var body=document.getElementById('pickBody');
              var ids=[].slice.call(body.querySelectorAll('input[type=checkbox]')).filter(function(c){return c.checked && !c.disabled;}).map(function(c){return c.value;});
              if(!ids.length){ closeSessPicker(); return; }
              Promise.all(ids.map(function(id){ return fetch('/api/goal/session/link',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({seq:SEQ,task:TASK,sessionId:id})}); }))
                .then(function(){ closeSessPicker(); loadSessions(); });
            };
            document.addEventListener('DOMContentLoaded',function(){ loadSessions();
              document.addEventListener('keydown',function(e){ var ov=document.getElementById('sessPicker'); if(e.key==='Escape'&&ov&&ov.style.display!=='none'){ closeSessPicker(); } });
            });
          })();
          </script>
        """
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(label)) · \(htmlEscape(title))</title>
        <style>
          :root{--bg:#0e1116;--panel:#141821;--line:#222a36;--fg:#e6e9ef;--mut:#8a93a3;--accent:#5b8cff;--green:#9fe0a0}
          *{box-sizing:border-box}
          html,body{height:100%}
          body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;display:flex;flex-direction:column;height:100vh;overflow:hidden}
          /* This page loads in the app's fullSizeContentView WKWebView, so the header renders up
             under the transparent titlebar. The native TitlebarDragView (AppWindow.swift) covers the
             top ~28pt strip and swallows mouse-down there as a window-drag — everything past the 160px
             traffic-light exclusion, which (rail expanded) includes the back link. Pad the header top
             so the interactive '← 대시보드' link clears that band; the empty strip above it stays
             draggable. Matches DashboardContent's own top-strip offset. */
          header{position:relative;flex:none;background:rgba(14,17,22,.92);border-bottom:1px solid var(--line);padding:36px 76px 14px 20px}
          header a.back{color:var(--accent);text-decoration:none;font-size:12px}
          header h1{margin:6px 0 2px;font-size:17px}
          /* 긴 목표 프롬프트: 기본 2줄로 접고, 넘칠 때만 펼치기/줄이기 토글을 보여준다 */
          header h1.clamped{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden}
          header .titletgl{display:none;background:none;border:1px solid var(--line);color:var(--mut);border-radius:999px;padding:2px 10px;font-size:11px;cursor:pointer;margin:2px 0 6px}
          header .titletgl:hover{color:var(--fg);border-color:var(--accent)}
          header .num{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;border:1px solid var(--line);color:var(--accent);font-variant-numeric:tabular-nums;margin-right:6px}
          header .sub{color:var(--mut);font-size:12px}
          header .slink{margin-top:8px;display:flex;gap:8px;flex-wrap:wrap}
          header .slink a.chip{display:inline-flex;align-items:center;gap:4px;text-decoration:none;font-size:12px;color:var(--green);border:1px solid var(--line);border-radius:999px;padding:3px 11px;background:var(--panel)}
          header .slink a.chip:hover{border-color:var(--green)}
          .layout{flex:1;min-height:0;display:flex;align-items:stretch}
          .goalcol{flex:1;min-width:0;overflow-y:auto;padding:18px 20px 80px}
          .goalinner{max-width:880px;margin:0 auto}
          .verswitch{display:inline-flex;gap:4px;background:var(--panel);border:1px solid var(--line);border-radius:999px;padding:3px}
          .verswitch button{border:none;background:transparent;color:var(--mut);border-radius:999px;padding:5px 16px;font-size:13px;cursor:pointer}
          .verswitch button.on{background:var(--accent);color:#fff}
          .verbody{margin-top:10px}
          h2{font-size:13px;color:var(--mut);letter-spacing:.04em;text-transform:uppercase;margin:26px 0 8px;border-bottom:1px solid var(--line);padding-bottom:6px}
          .seccard{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:12px 0}
          .seccard h3{margin:0 0 4px;font-size:14px;color:var(--fg)}
          .sechint{color:var(--mut);font-size:12px;margin-bottom:10px}
          /* Empty section: just a dimmed title that brightens on hover; the guidance
             lives in the card's native tooltip, never inside the box as content. */
          .seccard.secempty{opacity:.42;padding:11px 16px;transition:opacity .15s;cursor:help}
          .seccard.secempty:hover{opacity:.9}
          .seccard.secempty h3{margin:0}
          /* In the editable 핵심 버전, an empty section is click-to-write: clicking it
             opens the editor with that "## 제목" heading inserted and the caret placed
             under it. The "＋ 작성" cue surfaces on hover so the action is discoverable. */
          #coreDisplay .seccard.secempty{cursor:pointer}
          #coreDisplay .seccard.secempty:hover{opacity:.95;border-color:var(--accent)}
          #coreDisplay .seccard.secempty h3::after{content:" ＋ 작성";color:var(--accent);font-size:12px;font-weight:400;opacity:0;transition:opacity .15s}
          #coreDisplay .seccard.secempty:hover h3::after{opacity:.85}
          /* Core display is double-clickable to edit; 수정 button only on hover. */
          .coredisp{cursor:text}
          #coreEditBtn{opacity:0;transition:opacity .15s}
          #ver-core:hover #coreEditBtn{opacity:1}
          /* 첨부: heading toggles the (default-hidden) attachment interface. */
          h2.atth{cursor:pointer;user-select:none;display:flex;align-items:center;gap:8px}
          h2.atth:hover{color:var(--fg)}
          h2.atth .att-toggle{font-size:11px;color:var(--accent);text-transform:none;letter-spacing:0}
          .hint{color:var(--mut);font-size:13px;margin:0}
          /* Read-view markdown preview. Raw markdown is carried as text and rendered on load;
             before render, keep whitespace so the brief pre-render state stays legible. */
          .mdbody{word-break:break-word;font:13.5px/1.75 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;color:var(--fg)}
          .mdbody:not(.rendered){white-space:pre-wrap;color:var(--mut)}
          .mdbody>*:first-child{margin-top:0}
          .mdbody>*:last-child{margin-bottom:0}
          .mdbody h1,.mdbody h2,.mdbody h3,.mdbody h4{margin:18px 0 8px;line-height:1.35;color:var(--fg);border:none;text-transform:none;letter-spacing:0}
          .mdbody h1{font-size:19px} .mdbody h2{font-size:16px;padding:0} .mdbody h3{font-size:14px} .mdbody h4{font-size:13px;color:var(--mut)}
          .mdbody p{margin:8px 0}
          .mdbody ul,.mdbody ol{margin:8px 0;padding-left:22px}
          .mdbody li{margin:3px 0}
          .mdbody li input[type=checkbox]{margin-right:6px;vertical-align:middle}
          /* Task-list items: drop the redundant bullet (the checkbox is the marker), and
             strike through + dim a checked item so "done" reads in a glance and the eye
             lands on what's left. */
          .mdbody li:has(input[type=checkbox]){list-style:none}
          .mdbody li:has(input[type=checkbox]:checked){color:var(--mut);text-decoration:line-through;text-decoration-color:var(--mut)}
          .mdbody a{color:var(--accent);text-decoration:none}
          .mdbody a:hover{text-decoration:underline}
          .mdbody strong{color:var(--fg);font-weight:650}
          .mdbody code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--green);background:#0d1016;border:1px solid var(--line);border-radius:5px;padding:1px 5px}
          .mdbody pre{background:#0d1016;border:1px solid var(--line);border-radius:8px;padding:12px 14px;overflow-x:auto;margin:10px 0}
          .mdbody pre code{background:none;border:none;padding:0;color:var(--fg)}
          .mdbody blockquote{margin:10px 0;padding:4px 14px;border-left:3px solid var(--line);color:var(--mut)}
          .mdbody hr{border:none;border-top:1px solid var(--line);margin:16px 0}
          .mdbody table{border-collapse:collapse;margin:10px 0;font-size:13px}
          .mdbody th,.mdbody td{border:1px solid var(--line);padding:6px 10px;text-align:left}
          .mdbody th{color:var(--mut);font-weight:500}
          .mdbody a.goallink{color:var(--accent);text-decoration:none;border-bottom:1px dashed var(--accent);font-variant-numeric:tabular-nums}
          .mdbody a.goallink:hover{border-bottom-style:solid}
          ul.atts{list-style:none;margin:0;padding:0}
          ul.atts li{display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;margin-bottom:6px;background:var(--panel)}
          ul.atts a{color:var(--fg);text-decoration:none;flex:1;word-break:break-all}
          ul.atts a:hover{color:var(--accent)}
          /* 부분과제: Jira-style subtask table read from the goal's tasks/ subfolders. */
          .subt-count{font-size:11px;color:var(--mut);text-transform:none;letter-spacing:0;font-variant-numeric:tabular-nums}
          .subt-tools{display:flex;align-items:center;gap:8px;margin:2px 0 8px}
          .subt-flt{display:inline-flex;align-items:center;gap:6px;color:var(--mut);font-size:12px}
          .subt-addbtn{margin-left:auto;background:transparent;border:1px solid var(--line);color:var(--accent);border-radius:7px;padding:5px 10px;font-size:12px;cursor:pointer}
          .subt-addbtn:hover{border-color:var(--accent)}
          .subt-addform{display:flex;flex-wrap:wrap;align-items:center;gap:6px;margin:0 0 10px}
          .subt-addform input{background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 8px;font-size:12px}
          .subt-addform input:focus{outline:none;border-color:var(--accent)}
          .subt-addform #subtAddTitle{flex:1;min-width:160px}
          .subt-addform .subt-addsm{width:64px}
          .subt-addform .subt-addgo{background:var(--accent);border:1px solid var(--accent);color:#0b0f17;border-radius:7px;padding:6px 12px;font-size:12px;font-weight:600;cursor:pointer}
          .subt-addform .subt-addgo:disabled{opacity:.5;cursor:default}
          table.subtasks .subt-empty td{color:var(--mut);text-align:center;padding:14px 10px}
          table.subtasks{width:100%;border-collapse:collapse;font-size:13px;margin:2px 0 6px}
          table.subtasks th{text-align:left;color:var(--mut);font-weight:500;font-size:11px;text-transform:uppercase;letter-spacing:.03em;padding:6px 10px;border-bottom:1px solid var(--line)}
          table.subtasks td{padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:middle}
          table.subtasks tbody tr:hover td{background:var(--panel)}
          table.subtasks .tid{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap}
          table.subtasks .tid a.tlink{color:var(--accent);text-decoration:none;border-bottom:1px dashed transparent}
          table.subtasks .tid a.tlink:hover{border-bottom-color:var(--accent)}
          table.subtasks .ttitle{color:var(--fg);word-break:break-word}
          table.subtasks .tmeta{color:var(--mut);white-space:nowrap}
          table.subtasks .tout code{color:var(--green)}
          .st{display:inline-block;font-size:11px;padding:1px 8px;border-radius:999px;border:1px solid var(--line);white-space:nowrap}
          .st.done{color:var(--green);border-color:rgba(159,224,160,.4)}
          .st.doing{color:var(--accent);border-color:rgba(91,140,255,.45)}
          .st.blocked{color:#e0a0a0;border-color:rgba(224,160,160,.45)}
          .st.todo{color:var(--mut)}
          .st.arch{color:var(--mut);opacity:.7}
          button,.filebtn{background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:6px 11px;font-size:13px;cursor:pointer}
          button:hover,.filebtn:hover{border-color:var(--accent)}
          button.x{padding:3px 9px;font-size:12px;color:var(--mut)}
          .add{display:flex;gap:8px;align-items:center;margin-top:12px;flex-wrap:wrap}
          .add input[type=text]{flex:1;min-width:220px;background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:7px 10px;font-size:13px}
          .empty{color:var(--mut);padding:14px 0}
          code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--mut)}
          .seccard.sess{background:#10141d;border-color:#2a3550}
          .seccard.sess h3{color:var(--accent)}
          .seccard.sess .srow{display:flex;gap:12px;padding:3px 0;font-size:13px}
          .seccard.sess .sk{color:var(--mut);min-width:84px;flex:none}
          .seccard.sess .sv{color:var(--fg)}
          .seccard.sess .sv.mut{color:var(--mut)}
          .seccard.sess .sv.mono{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
          .seccard.sess .slinks{display:flex;gap:8px;flex-wrap:wrap;margin-top:9px}
          .seccard.sess .slinks a.chip{display:inline-flex;align-items:center;gap:4px;text-decoration:none;font-size:12px;color:var(--green);border:1px solid var(--line);border-radius:999px;padding:3px 11px;background:var(--panel)}
          .seccard.sess .slinks a.chip:hover{border-color:var(--green)}
          .sesshead{display:flex;align-items:center;justify-content:space-between;margin:12px 0 6px;padding-top:10px;border-top:1px solid var(--line)}
          .sesshead .sklabel{color:var(--mut);font-size:12px}
          .sesshead button.lnk{background:transparent;border:1px solid var(--line);color:var(--accent);border-radius:7px;padding:4px 10px;font-size:12px}
          .sesshead button.lnk:hover{border-color:var(--accent)}
          .sesslist{display:flex;flex-direction:column;gap:8px}
          .sesslist .mut{color:var(--mut);font-size:13px}
          .sessitem{border:1px solid var(--line);border-radius:8px;padding:9px 11px;background:#0d1016}
          .sessitem.gone{opacity:.55}
          .sessitem .shead{display:flex;align-items:baseline;gap:8px}
          .sessitem .src{flex:none;font-size:11px;color:var(--green);border:1px solid var(--line);border-radius:999px;padding:1px 8px}
          .sessitem .stitle{flex:1;min-width:0;color:var(--fg);font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .sessitem .sage{flex:none;color:var(--mut);font-size:12px}
          .sessitem .sact{display:flex;align-items:center;gap:6px;margin-top:7px;flex-wrap:wrap}
          .sessitem .rcmd{flex:1;min-width:160px;font:11px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--mut);background:#0a0d12;border:1px solid var(--line);border-radius:6px;padding:4px 8px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .sessitem .mini{flex:none;background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:6px;padding:3px 9px;font-size:11px;text-decoration:none;cursor:pointer}
          .sessitem .mini:hover{border-color:var(--accent)}
          .sessitem .mini.x{color:var(--mut)}
          .pickov{position:fixed;inset:0;z-index:60;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.5)}
          .pickbox{width:min(560px,94vw);max-height:82vh;display:flex;flex-direction:column;background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden;box-shadow:0 18px 60px rgba(0,0,0,.5)}
          .pickhdr{display:flex;align-items:center;justify-content:space-between;padding:12px 15px;border-bottom:1px solid var(--line)}
          .pickhdr .t{font-weight:600}
          .pickhint{color:var(--mut);font-size:12px;padding:10px 15px 4px}
          .pickbody{flex:1;overflow-y:auto;padding:8px 12px 12px;display:flex;flex-direction:column;gap:6px}
          .pickrow{display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;cursor:pointer;background:#0d1016}
          .pickrow:hover{border-color:var(--accent)}
          .pickrow.linked{opacity:.6;cursor:default}
          .pickrow input{flex:none}
          .pickrow .pmeta{min-width:0}
          .pickrow .ptitle{font-size:13px;color:var(--fg);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .pickrow .page{font-size:11px;color:var(--mut);margin-top:2px}
          .pickfoot{display:flex;justify-content:flex-end;gap:8px;padding:11px 15px;border-top:1px solid var(--line)}
          .pickfoot button.save{background:var(--accent);color:#fff;border-color:var(--accent);font-weight:600}
          .verhead{display:flex;justify-content:flex-end;gap:8px;margin:10px 0 2px}
          .verhead .editacts{display:flex;align-items:center;gap:8px}
          .verhead button.save{background:var(--accent);color:#fff;border-color:var(--accent);font-weight:600}
          .verhead .dirtychip{display:inline-flex;align-items:center;font-size:12px;font-weight:600;color:#e0a53a;padding:3px 9px;border:1px solid #e0a53a55;border-radius:999px;background:#e0a53a1a}
          textarea.vereditor{width:100%;min-height:300px;resize:vertical;background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:14px;font:13px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace;margin-top:6px}
          textarea.vereditor:focus{outline:none;border-color:var(--accent)}
          textarea.vereditor.dirty{border-color:#e0a53a;box-shadow:0 0 0 1px #e0a53a55}
          textarea.vereditor.dirty:focus{border-color:#e0a53a}
          .curhdr{display:flex;align-items:baseline;justify-content:space-between;gap:10px;margin:6px 0 4px;padding-bottom:8px;border-bottom:1px solid var(--line)}
          .curhdr .ct{font-size:13px;color:var(--fg);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          .curhdr .cage{flex:none;color:var(--mut);font-size:12px}
          .curbody .msg{margin:12px 0;border:1px solid var(--line);border-radius:12px;overflow:hidden;background:#0d1016}
          .curbody .msg .who{font-size:11px;letter-spacing:.04em;text-transform:uppercase;color:var(--mut);padding:7px 13px;border-bottom:1px solid var(--line);background:#11161f}
          .curbody .msg .body{padding:11px 13px}
          /* 대화 컨벤션: AI는 말풍선 없이 플레인 텍스트, 사용자만 우측 버블 */
          .curbody .msg.assistant{border:none;background:transparent;overflow:visible}
          .curbody .msg.assistant .who{display:none}
          .curbody .msg.assistant .body{padding:2px 0;line-height:1.75}
          .curbody .msg.user{max-width:82%;margin-left:auto;background:rgba(91,140,255,.10);border-color:rgba(91,140,255,.30)}
          .curbody .msg.user .who{display:none}
          /* 세션 정보 탭: 이어가기 컴포저 + 라이브 스트림 */
          #sessLive .su{max-width:82%;margin:12px 0 12px auto;padding:9px 13px;border-radius:12px;background:rgba(91,140,255,.10);border:1px solid rgba(91,140,255,.30);white-space:pre-wrap;font-size:13px}
          #sessLive .sa{margin:12px 0;font-size:13.5px;line-height:1.75;white-space:pre-wrap;word-break:break-word}
          #sessLive .stoolsum{font-size:12px;color:var(--mut);margin:8px 0 2px;cursor:pointer;user-select:none}
          #sessLive .stoolsum:hover{color:var(--fg)}
          #sessLive .stoolbox{display:none;border:1px solid var(--line);border-radius:10px;padding:4px 6px;margin:4px 0 8px;background:#0d1016}
          #sessLive .stoolbox.open{display:block}
          #sessLive .strow{font-size:12px;color:var(--mut);padding:6px 7px;border-radius:6px;cursor:pointer;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
          #sessLive .strow:hover{background:#141a24;color:var(--fg)}
          #sessLive .strdet{display:none;margin:2px 7px 7px;padding:8px 10px;border-left:2px solid var(--line);font-family:ui-monospace,Menlo,monospace;font-size:11px;white-space:pre-wrap;color:var(--mut);max-height:260px;overflow-y:auto}
          #sessLive .strdet.open{display:block}
          #sessLive .scost{font-size:11px;color:var(--mut);margin:2px 0 6px}
          .sessstat{display:flex;align-items:center;gap:8px;font-size:12px;color:var(--mut);margin:12px 0 6px}
          .sessstat .sstar{display:inline-block;font-size:14px;line-height:1}
          .sessstat.working .sstar{color:#ff6b4a;animation:sessspin 1.6s linear infinite}
          .sessstat.working #sessStxt{color:#ff6b4a}
          @keyframes sessspin{0%{transform:rotate(0)}100%{transform:rotate(360deg)}}
          .sesscomposer{display:flex;gap:8px;align-items:flex-end;margin-bottom:14px}
          .sesscomposer textarea{flex:1;resize:none;padding:10px 12px;border-radius:11px;border:1px solid var(--line);background:#0d1016;color:var(--fg);font-size:13px;font-family:inherit;outline:none;line-height:1.5}
          .sesscomposer textarea:focus{border-color:#7c5cff}
          .sesscomposer button{padding:10px 16px;border-radius:11px;border:1px solid #7c5cff;background:#7c5cff;color:#fff;font-size:12.5px;cursor:pointer}
          .sesscomposer button#sessStopBtn{background:transparent;border-color:var(--line);color:var(--mut)}
          .curbody .msg.user .who{color:#9fc0ff}
          .curbody .msg.assistant .who{color:#8fe3c0}
          .curbody .text{white-space:pre-wrap;word-break:break-word}
          .curbody .text+.text,.curbody .text+details,.curbody details+.text,.curbody details+details{margin-top:10px}
          .curbody details{border:1px solid var(--line);border-radius:8px;background:#0f141c}
          .curbody details summary{cursor:pointer;padding:6px 10px;color:var(--mut);font-size:12px}
          .curbody details pre{margin:0;padding:10px 12px;border-top:1px solid var(--line);white-space:pre-wrap;word-break:break-word;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;color:#cdd4df;max-height:420px;overflow:auto}
          .curbody details.tool summary{color:#ffcf8f}
          .curbody details.result summary{color:#9fe0a0}
          .curbody details.think summary{color:#b6a8ff}
          .msgr{position:relative;width:380px;flex:none;display:flex;flex-direction:column;overflow:hidden;border-left:1px solid var(--line);background:var(--panel)}
          /* 좌우 드래그로 메신저 폭 조절 */
          .msgr-rz{position:absolute;left:0;top:0;bottom:0;width:8px;cursor:col-resize;z-index:7}
          .msgr-rz::before{content:'';position:absolute;left:0;top:0;bottom:0;width:2px;background:transparent;transition:background .12s}
          .msgr-rz:hover::before,.msgr-rz.drag::before{background:var(--accent)}
          /* 채팅 아이콘 토글: 접으면 메신저 숨김 + 목표 콘텐츠가 전체 폭 사용 */
          body.chat-collapsed .msgr{display:none}
          /* 열릴 때 옆에서 부드럽게 슬라이드 인 */
          body:not(.chat-collapsed) .msgr{animation:msgrSlide .18s ease-out}
          @keyframes msgrSlide{from{transform:translateX(14px);opacity:.35}to{transform:none;opacity:1}}
          /* 상단 헤더 우측(빈 공간)의 아이콘 툴바 — 첫 이미지의 툴바와 같은 UX */
          .pagetools{position:absolute;top:30px;right:18px;display:flex;gap:6px;z-index:8}
          /* CLI/GUI/대시보드 세그먼트 — goal-add 헤더 토글과 같은 모양. CLI/GUI 는 이 목표의
             세션 뷰(/goal-add?goal=N&ui=…)로 넘어가고, 대시보드(현재 화면)는 켜진 상태다. */
          .pagetools .pseg{display:inline-flex;border:1px solid var(--line);border-radius:8px;overflow:hidden}
          .pagetools .pseg button{background:transparent;border:none;color:var(--mut);padding:0 10px;height:30px;font-size:12px;cursor:pointer;border-right:1px solid var(--line)}
          .pagetools .pseg button:last-child{border-right:none}
          .pagetools .pseg button.on{background:var(--accent);color:#fff;font-weight:600;cursor:default}
          .pagetools .pseg button:hover:not(.on){color:var(--fg);background:#1d2230}
          .pagetools .ptool{width:34px;height:30px;display:flex;align-items:center;justify-content:center;padding:0;background:#1b2230;border:1px solid var(--line);border-radius:8px;color:var(--mut);font-size:16px;line-height:1;cursor:pointer}
          .pagetools .ptool:hover{border-color:var(--accent);color:var(--fg)}
          .pagetools .ptool.on{background:var(--accent);border-color:var(--accent);color:#fff}
          .msgrhdr{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:11px 14px;border-bottom:1px solid var(--line);font-size:13px;color:var(--mut)}
          .msgrhdr .t{color:var(--fg);font-weight:600}
          .msgrhdr .pwr{font-weight:500;font-size:11px;color:#f0c674;border:1px solid rgba(240,198,116,.4);border-radius:999px;padding:1px 7px;margin-left:4px;white-space:nowrap}
          .msgrhdr .hdrbtns{display:flex;gap:6px;align-items:center;flex:none}
          .modesel{background:#1b2230;border:1px solid var(--line);color:var(--fg);border-radius:7px;padding:5px 6px;font-size:12px;cursor:pointer}
          .modesel:hover{border-color:var(--accent)}
          .msg.streaming .bub::after{content:'▋';margin-left:1px;opacity:.6;animation:blink 1s steps(1) infinite}
          @keyframes blink{50%{opacity:0}}
          .msg.thinkmsg .bub{background:transparent;border:1px dashed var(--line);color:var(--mut);font-size:12px;font-style:italic}
          .toolcard{align-self:stretch;background:#0d1320;border:1px solid rgba(91,140,255,.3);border-radius:8px;overflow:hidden}
          .toolcard .th{padding:7px 10px;color:#bcd0ff;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all;cursor:default}
          .toolcard .th.has{cursor:pointer} .toolcard .th.has::after{content:' ▾';opacity:.6}
          .toolcard .tr{padding:8px 10px;border-top:1px solid var(--line);background:#0a0d14;color:var(--mut);font:11px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;word-break:break-all;max-height:240px;overflow:auto}
          .toolcard .tr.err{color:#e0a0a0}
          .costline{color:var(--mut);font-size:10px;margin-top:4px;text-align:right;font-variant-numeric:tabular-nums}
          .planrun{margin-top:8px;background:var(--accent);border:1px solid var(--accent);color:#fff;border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .planrun:disabled{opacity:.5;cursor:default}
          .msg.assistant .bub p{margin:0 0 8px} .msg.assistant .bub p:last-child{margin:0}
          .msg.assistant .bub pre.cb,.msg.assistant .bub pre{background:#0a0d14;border:1px solid var(--line);border-radius:7px;padding:10px;overflow:auto;margin:6px 0}
          .msg.assistant .bub code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:rgba(255,255,255,.06);padding:1px 4px;border-radius:4px}
          .msg.assistant .bub pre code{background:none;padding:0}
          .msg.assistant .bub ul,.msg.assistant .bub ol{margin:6px 0;padding-left:20px}
          .msg.assistant .bub h1,.msg.assistant .bub h2,.msg.assistant .bub h3{font-size:14px;margin:8px 0 4px}
          .msg.assistant .bub a{color:var(--accent)}
          .permcard{align-self:stretch;background:#1a1505;border:1px solid rgba(240,198,116,.45);border-radius:10px;padding:10px 12px}
          .permcard .pq{color:#f0c674;font-weight:600;font-size:12px;margin-bottom:6px}
          .permcard .pl code{display:inline-block;color:#e6e9ef;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
          .permcard .prow{display:flex;gap:8px;margin-top:10px}
          .permcard .pa{background:var(--accent);border:1px solid var(--accent);color:#fff;border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .permcard .pa2{background:#1b2230;border:1px solid var(--accent);color:var(--accent);border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .permcard .pd{background:#1b2230;border:1px solid var(--line);color:var(--mut);border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .qcard{align-self:stretch;display:flex;flex-direction:column;gap:10px;background:#0f131b;border:1px solid var(--line);border-radius:12px;padding:12px 13px}
          .qcard .qhead{display:flex;align-items:flex-start;gap:9px}
          .qcard .qcount{flex:none;background:rgba(240,198,116,.16);color:#f0c674;font-size:11px;font-weight:600;padding:2px 8px;border-radius:7px;line-height:1.6;font-variant-numeric:tabular-nums}
          .qcard .qtitle{flex:1;font-size:14px;font-weight:600;color:var(--fg);line-height:1.45;min-width:0}
          .qcard .qctrls{flex:none;display:flex;gap:4px}
          .qcard .qicon{background:transparent;border:1px solid var(--line);color:var(--mut);width:24px;height:24px;border-radius:7px;cursor:pointer;font-size:14px;line-height:1;display:flex;align-items:center;justify-content:center;padding:0}
          .qcard .qicon:hover{color:var(--fg);border-color:var(--accent)}
          .qcard .qbody{display:flex;flex-direction:column;gap:7px}
          .qcard .qopt{display:flex;align-items:flex-start;justify-content:space-between;gap:10px;width:100%;text-align:left;background:#11151f;border:1px solid var(--line);border-radius:9px;padding:9px 11px;cursor:pointer;color:var(--fg)}
          .qcard .qopt:hover{border-color:#3a4658}
          .qcard .qopt.sel{background:#1b212d;border-color:var(--accent)}
          .qcard .qopt .qmain{display:flex;flex-direction:column;gap:2px;min-width:0}
          .qcard .qopt .qlabel{font-size:13px;font-weight:600;color:var(--fg);line-height:1.4}
          .qcard .qopt .qwhy{font-size:11px;color:var(--mut);line-height:1.4}
          .qcard .qopt .qnum{flex:none;background:#0d1016;border:1px solid var(--line);color:var(--mut);font-size:11px;min-width:20px;height:20px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-variant-numeric:tabular-nums}
          .qcard .qopt.sel .qnum{color:var(--accent);border-color:var(--accent)}
          .qcard .qfreein{background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:8px 10px;font-size:13px;width:100%;box-sizing:border-box}
          .qcard .qfreein:focus{border-color:var(--accent);outline:none}
          .qcard .qfoot{display:flex;justify-content:flex-end;gap:8px;margin-top:1px}
          .qcard .qskip{background:transparent;border:1px solid var(--line);color:var(--mut);border-radius:7px;padding:6px 12px;font-size:13px;cursor:pointer}
          .qcard .qskip:hover{color:var(--fg)}
          .qcard .qnextbtn{background:var(--accent);border:1px solid var(--accent);color:#fff;border-radius:7px;padding:6px 14px;font-size:13px;cursor:pointer}
          .qcard.answered{opacity:.5;pointer-events:none}
          .qhint{color:var(--mut);font-style:italic}
          .cliov{position:absolute;inset:0;z-index:6;display:flex}
          .clibox{width:100%;height:100%;display:flex;flex-direction:column;background:#0c0f15;overflow:hidden;animation:cliSlide .18s ease-out}
          @keyframes cliSlide{from{opacity:0}to{opacity:1}}
          .clihdr{flex:none;display:flex;align-items:center;justify-content:space-between;gap:10px;padding:9px 13px;border-bottom:1px solid var(--line);background:var(--panel);font-size:13px;color:var(--fg)}
          .clihdr .st{color:var(--mut);font-size:12px;margin-left:8px}
          .clihdr .st.live{color:var(--green)}
          .clihdr .st.dead{color:#e06a6a}
          .cliterm{flex:1;min-height:0;padding:8px 6px 4px 10px;background:#0c0f15}
          .cliterm .xterm{height:100%}
          .cliterm .xterm-viewport{background:#0c0f15 !important;scrollbar-width:thin;scrollbar-color:#2a3340 #0c0f15}
          .cliterm .xterm-viewport::-webkit-scrollbar{width:10px}
          .cliterm .xterm-viewport::-webkit-scrollbar-track{background:#0c0f15}
          .cliterm .xterm-viewport::-webkit-scrollbar-thumb{background:#2a3340;border-radius:6px;border:2px solid #0c0f15}
          .msgrhdr button.cli{background:var(--accent);color:#fff;border-color:var(--accent);font-weight:600}
          .msgrhdr button.cli:hover{filter:brightness(1.08);border-color:var(--accent)}
          .msgrhdr button.cli:disabled{opacity:.6;cursor:default}
          .chatbody{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:12px}
          .chatempty{color:var(--mut);font-size:13px;text-align:center;margin:auto;padding:24px;line-height:1.7}
          .msg{display:flex;max-width:92%}
          .msg.user{align-self:flex-end}
          .msg.assistant{align-self:stretch;max-width:100%}
          .msg .bub{padding:8px 12px;border-radius:12px;font-size:13px;line-height:1.6;white-space:pre-wrap;word-break:break-word}
          .msg.user .bub{background:rgba(91,140,255,.16);border:1px solid rgba(91,140,255,.32)}
          /* AI 답변은 말풍선 없이 플레인 텍스트(사용자 말풍선만 유지) */
          .msg.assistant .bub{background:none;border:none;padding:2px 0}
          /* 마크다운 --- 로 생기는 가로 구분선(<hr>)을 채팅에서는 숨긴다 */
          .msg .bub hr{display:none}
          .msg.pending .bub{color:var(--mut)}
          .composer{border-top:1px solid var(--line);padding:10px 12px;display:flex;gap:8px;align-items:flex-end}
          .composer textarea{flex:1;resize:none;background:#0d1016;border:1px solid var(--line);color:var(--fg);border-radius:8px;padding:8px 10px;font:13px/1.5 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo",sans-serif;max-height:160px;min-height:38px}
          @media(max-width:1080px){
            body{height:auto;overflow:auto}
            .layout{flex-direction:column}
            .goalcol{overflow:visible}
            .msgr{width:auto;align-self:stretch;max-height:72vh;border-left:none;border-top:1px solid var(--line)}
          }
        </style></head>
        <body>
          \(SessionRail.html())
          <header>
            <a class="back" href="\(htmlEscape(backHref))">\(htmlEscape(backLabel))</a>
            <h1 id="pgTitle" class="clamped"><span class="num">\(htmlEscape(numChip))</span>\(htmlEscape(title))</h1>
            <button id="titleTgl" class="titletgl" onclick="titleToggle()">펼치기 ▾</button>
            <div class="sub">\(meta)</div>
            \(sessionLink)
            <div class="pagetools">\(uiSeg)<button class="ptool" id="chatTool" onclick="chatToggle()" title="채팅 패널 열기/닫기">💬</button></div>
          </header>
          <div class="layout">
            <div class="goalcol"><div class="goalinner">
              <div class="verswitch">
                <button id="btnCore" onclick="showVer('core')">핵심 버전</button>
                <button id="btnDetail" onclick="showVer('detail')">디테일 버전</button>
                <button id="btnSession" class="on" onclick="showVer('session')">세션 정보</button>
              </div>
              <div id="ver-core" class="verbody" style="display:none">\(coreEditHead)<div id="coreDisplay"\(coreDispAttr)>\(coreHTML)</div>\(coreEditor)</div>
              <div id="ver-detail" class="verbody" style="display:none">\(detailHTML)</div>
              <div id="ver-session" class="verbody">\(sessionSummary)<h2>최신 진행 내용</h2>\(currentHTML)<div id="sessLive"></div><div class="sessstat" id="sessStat"><span class="sstar">✳</span><span id="sessStxt">대기 중 — 입력하면 최근 세션으로 이어집니다 (없으면 새 세션 시작)</span></div><div class="sesscomposer"><textarea id="sessIn" rows="2" placeholder="이어서 지시하기… (Enter 전송 · ⇧Enter 줄바꿈)"></textarea><button id="sessSend" onclick="sessSay()">보내기</button><button id="sessStopBtn" onclick="sessStop()" style="display:none">중단</button></div></div>
              <h2 class="atth" onclick="toggleAtt()">첨부 <span id="attToggle" class="att-toggle">▸ 펼치기</span></h2>
              <div id="attWrap" style="display:none">
                \(attachments)
                \(controls)
              </div>
              \(subtasks)
            </div></div>
            <aside class="msgr">
              <div class="msgr-rz" id="msgrRz" title="크기 조정"></div>
              <div class="msgrhdr"><div class="hdrbtns"><select id="modeSel" class="modesel" title="권한 모드"><option value="default">수동</option><option value="acceptEdits">편집 자동</option><option value="plan">계획</option><option value="bypassPermissions">자동</option></select><button id="btnCli" class="cli" onclick="openCLI()" title="대화형 CLI 터미널 열기">CLI</button><button onclick="resetChat()" title="새 대화">새 대화</button><button class="x" onclick="chatToggle(false)" title="채팅 닫기">✕</button></div></div>
              <div id="chatbody" class="chatbody"></div>
              <div class="composer">
                <textarea id="ci" rows="1" placeholder="이 목표를 명확히 할 질문이나 정리를 적어 보세요…"></textarea>
                <button id="btnSend" onclick="sendChat()">보내기</button>
                <button id="btnStop" onclick="stopChat()" style="display:none">중단</button>
              </div>
              <div id="cliOverlay" class="cliov" style="display:none">
                <div class="clibox">
                  <div class="clihdr">
                    <span class="t">CLI · \(htmlEscape(isTask ? numChip : "goal-\(seq)")) <span id="cliState" class="st">연결 중…</span></span>
                    <button class="x" onclick="cliClose()" title="세션 종료 (Esc)">닫기 ✕</button>
                  </div>
                  <div id="cliTerm" class="cliterm"></div>
                </div>
              </div>
            </aside>
          </div>
          <div id="sessPicker" class="pickov" style="display:none">
            <div class="pickbox">
              <div class="pickhdr"><span class="t">세션 연결 · \(htmlEscape(isTask ? numChip : "goal-\(seq)"))</span><button class="x" onclick="closeSessPicker()" title="닫기 (Esc)">✕</button></div>
              <div class="pickhint">이 목표와 관련된 최근 Claude 세션을 골라 연결하세요. 마지막 사용 시간 순입니다.</div>
              <div id="pickBody" class="pickbody"></div>
              <div class="pickfoot"><button onclick="closeSessPicker()">취소</button><button class="save" onclick="confirmSessLink()">연결</button></div>
            </div>
          </div>
          <script>
          /* Long goal-prompt titles: clamp to 2 lines by default and show a
             펼치기/줄이기 toggle only when the title actually overflows. */
          (function(){
            var t=document.getElementById('pgTitle'),b=document.getElementById('titleTgl');
            if(!t||!b)return;
            function chk(){
              var clamped=t.classList.contains('clamped');
              b.style.display=(!clamped||t.scrollHeight>t.clientHeight+2)?'inline-block':'none';
            }
            window.titleToggle=function(){
              var clamped=t.classList.toggle('clamped');
              b.textContent=clamped?'펼치기 ▾':'줄이기 ▴';
              chk();
            };
            chk();
            window.addEventListener('resize',chk);
          })();
          </script>
          \(chatScript)
          \(cliScript)
          \(sessScript)
          \(evScript)
          \(chatPanelScript)
        </body></html>
        """
    }

    // Decode a browser FileReader payload: either a "data:<mime>;base64,…" URL or
    // bare base64. Unknown characters (stray whitespace/newlines) are ignored.
    private static func decodeDataURL(_ s: String) -> Data? {
        var b64 = s
        if s.hasPrefix("data:"), let comma = s.range(of: ",") {
            b64 = String(s[comma.upperBound...])
        }
        return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
    }

    // Percent-encode a value for use inside a URL query (spaces, colons, slashes, etc.).
    // Used to build subtask links whose folder name carries spaces and colons.
    private static func queryEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // Make an uploaded name safe to store as a path component.
    private static func sanitizeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:\u{0}").union(.newlines)
        let cleaned = name.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(120))
    }

    // Minimal extension -> MIME map for serving downloads inline-friendly.
    private static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "txt", "log", "md": return "text/plain; charset=utf-8"
        case "csv": return "text/csv; charset=utf-8"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    func quit() {
        AppLog.log("quit() — menu 종료 pressed -> dashboard.stop + NSApp.terminate")
        dashboard.stop()
        NSApp.terminate(nil)
    }
}
