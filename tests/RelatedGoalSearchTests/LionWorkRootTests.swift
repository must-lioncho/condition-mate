import Testing
import Foundation
@testable import ConditionMate

// `WorkQueueStore.lionWorkRoot` 의 소유 관계 시험 (SPEC DASH-15).
//
// 이 파일이 있는 이유는 이 판정이 **읽어서 맞아 보이는 것으로는 부족한** 종류이기 때문이다.
// 앞선 판은 큐 경로 문자열에서 `/organization/` 앞을 잘라 루트를 만들었고, 그 코드도 읽으면
// 맞아 보였다. 틀린 것은 코드가 아니라 전제였다 — 큐가 `<root>/queue` 로 옮겨지면서 그 조각이
// 사라졌고, 아무도 실행해 보지 않아 카드 166 장 중 67 장(40%)의 산출물 링크가 없는 경로로
// 풀리는 것을 며칠 못 봤다. 그래서 여기서는 네 갈래를 전부 **실제로 호출해서** 값을 본다.
//
// `.serialized` 가 필요하다. 이 시험들은 프로세스 전역인 것 둘 — `Settings.shared.queueFolder`
// 와 `CM_LION_WORK_DIR` 환경변수 — 을 바꿨다 되돌린다. swift-testing 의 기본은 병렬이고,
// 병렬이면 한 시험이 되돌리는 사이에 다른 시험이 읽는다.
//
// `Settings.shared` 는 UserDefaults 가 아니라 `<CM_DATA_DIR|~/.condition-mate>/settings.json` 에
// **진짜로 쓴다.** 그래서 큐 폴더를 만지는 시험 넷은 `CM_DATA_DIR` 로 격리됐을 때만 돈다
// (`isolated` 조건). 2026-09-07 에 격리 없이 돌렸다가, 도는 앱과 시험 프로세스가 같은
// settings.json 을 각자 통째로 덮어쓰면서 `cm.queueFolder` 가 날아갔다 — `defer` 로 되돌려도
// 되돌리는 쪽이 진 판이 있다. `scripts/run-unit-tests.sh` 가 임시 폴더를 잡아 준다.
// 되돌리기(`defer`)는 격리된 store 안에서도 그대로 한다 — 시험끼리 서로 오염시키지 않는다.
@Suite(.serialized) struct LionWorkRootTests {

    private static let expectedRoot = "/Users/lioncho/Work/lion_work"

    // `Settings` 를 만지는 시험이 돌아도 되는 조건. 거짓이면 그 시험들은 `skipped` 로 **보이게**
    // 빠진다 — 조용히 통과하지 않는다.
    static let isolated = AppPaths.isCustom

    // 큐 폴더를 잠깐 `queue` 로 바꿔 `lionWorkRoot` 를 실제로 부르고, 원래 값으로 되돌린다.
    private func rootPath(withQueue queue: String) -> String {
        let saved = Settings.shared.queueFolder
        defer { Settings.shared.queueFolder = saved }
        Settings.shared.queueFolder = queue
        #expect(WorkQueueStore.root.path == queue, "큐 폴더 자체가 안 잡히면 아래 판정이 무의미하다")
        return WorkQueueStore.lionWorkRoot.path
    }

    // 주변 환경이 `CM_LION_WORK_DIR` 를 들고 있으면 2·3 단계 시험이 통째로 무의미해진다.
    private func withoutEnv<T>(_ body: () throws -> T) rethrows -> T {
        let saved = ProcessInfo.processInfo.environment["CM_LION_WORK_DIR"]
        unsetenv("CM_LION_WORK_DIR")
        defer { if let s = saved { setenv("CM_LION_WORK_DIR", s, 1) } }
        return try body()
    }

    // (a) 오늘의 배치. `<root>/queue` — 경로 문자열에 `/organization/` 이 한 번도 안 나온다.
    @Test(.enabled(if: LionWorkRootTests.isolated,
          "CM_DATA_DIR 로 격리되지 않았다 — 사용자의 실제 settings.json 에 쓰지 않는다"))
    func currentQueueLayoutResolvesToLionWork() {
        withoutEnv {
            #expect(rootPath(withQueue: "/Users/lioncho/Work/lion_work/queue") == Self.expectedRoot)
        }
    }

    // (b) 옛 배치. 이 폴더는 **디스크에 없다** — 그래도 위로 올라가다 보면 같은 루트가 나온다.
    // 존재하지 않는 조상은 표식이 없는 것으로 취급되고 걸음이 계속된다.
    @Test(.enabled(if: LionWorkRootTests.isolated,
          "CM_DATA_DIR 로 격리되지 않았다 — 사용자의 실제 settings.json 에 쓰지 않는다"))
    func legacyQueueLayoutResolvesToTheSameRoot() {
        let legacy = "/Users/lioncho/Work/lion_work/organization/lion/lion-work-queue"
        #expect(FileManager.default.fileExists(atPath: legacy) == false,
                "옛 경로가 되살아났다면 이 시험의 전제가 바뀐 것이다")
        withoutEnv {
            #expect(rootPath(withQueue: legacy) == Self.expectedRoot)
        }
    }

    // (c) 핵심. 조상 어디에도 `organization/` 이 없는 임의 폴더를 골라도 루트가 **따라가지
    // 않는다.** 앞선 판이 여기서 큐 폴더 자신을 돌려줬고 그것이 이번에 고친 결함이다.
    @Test(.enabled(if: LionWorkRootTests.isolated,
          "CM_DATA_DIR 로 격리되지 않았다 — 사용자의 실제 settings.json 에 쓰지 않는다"))
    func arbitraryQueueFolderDoesNotDragTheRootWithIt() throws {
        let tmp = "/tmp/cm-lionworkroot-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let got = withoutEnv { rootPath(withQueue: tmp) }
        #expect(got == Self.expectedRoot)
        #expect(got != tmp, "루트가 큐 폴더 자신으로 떨어졌다 — 고친 결함의 재발이다")
        #expect(got == WorkQueueStore.defaultLionWorkRootPath)
    }

    // (d) 환경변수가 셋 모두를 이긴다. 큐 폴더는 (c) 와 같은 임의 폴더로 두고 확인한다 —
    // 2 단계와 3 단계 중 어느 쪽이 이겼는지와 헷갈리지 않게 둘 다 아닌 값을 쓴다.
    @Test(.enabled(if: LionWorkRootTests.isolated,
          "CM_DATA_DIR 로 격리되지 않았다 — 사용자의 실제 settings.json 에 쓰지 않는다"))
    func envOverrideBeatsEverything() throws {
        let tmp = "/tmp/cm-lionworkroot-\(UUID().uuidString)"
        let envRoot = "/tmp/cm-lionworkroot-env-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let saved = ProcessInfo.processInfo.environment["CM_LION_WORK_DIR"]
        setenv("CM_LION_WORK_DIR", envRoot, 1)
        defer { if let s = saved { setenv("CM_LION_WORK_DIR", s, 1) } else { unsetenv("CM_LION_WORK_DIR") } }

        let got = rootPath(withQueue: tmp)
        #expect(got == envRoot)
        #expect(got != Self.expectedRoot)
        #expect(got != tmp)

        // 그리고 큐가 오늘의 배치일 때도 환경변수가 이긴다 — (a) 를 이기는지까지 본다.
        #expect(rootPath(withQueue: "/Users/lioncho/Work/lion_work/queue") == envRoot)
    }

    // 캐시가 큐 경로를 **키로** 잡고 있는지. `static let` 한 번 계산이면 이 시험이 진다 —
    // 사용자가 도는 중에 선택기로 큐 폴더를 바꾸는 것이 바로 이 경로다.
    @Test(.enabled(if: LionWorkRootTests.isolated,
          "CM_DATA_DIR 로 격리되지 않았다 — 사용자의 실제 settings.json 에 쓰지 않는다"))
    func memoizationIsKeyedOnTheQueuePathNotComputedOnce() throws {
        let tmp = "/tmp/cm-lionworkroot-\(UUID().uuidString)"
        let inside = tmp + "/nest/queue"
        try FileManager.default.createDirectory(atPath: tmp + "/nest/organization",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: inside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        withoutEnv {
            // 같은 값을 두 번 물어도 같다(캐시 적중이 값을 바꾸지 않는다).
            #expect(rootPath(withQueue: "/Users/lioncho/Work/lion_work/queue") == Self.expectedRoot)
            #expect(rootPath(withQueue: "/Users/lioncho/Work/lion_work/queue") == Self.expectedRoot)

            // 큐를 바꾸면 값도 같이 바뀐다 — 캐시가 굳지 않는다.
            let moved = rootPath(withQueue: inside)
            #expect(moved == tmp + "/nest")
            #expect(moved != Self.expectedRoot)

            // 되돌리면 다시 원래 값이다.
            #expect(rootPath(withQueue: "/Users/lioncho/Work/lion_work/queue") == Self.expectedRoot)
        }
    }

    // 2 단계는 `organization/` 이 **디렉터리로 실제 존재하는지**를 본다. 같은 이름의 파일은
    // 표식이 아니다 — 문자열만 봤다면 여기서 갈렸을 것이다.
    @Test func markerMustBeADirectoryNotAFile() throws {
        let tmp = "/tmp/cm-lionworkroot-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp + "/queue",
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp + "/organization", contents: Data())
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(WorkQueueStore.resolveLionWorkRootPath(forQueuePath: tmp + "/queue")
                == WorkQueueStore.defaultLionWorkRootPath)
    }

    // 걸음이 `/` 에서 멈춘다. 안 멈추면 무한 루프이고 이 시험이 끝나지 않는다.
    @Test func walkTerminatesAtFilesystemRoot() {
        #expect(WorkQueueStore.resolveLionWorkRootPath(forQueuePath: "/")
                == WorkQueueStore.defaultLionWorkRootPath)
        #expect(WorkQueueStore.resolveLionWorkRootPath(forQueuePath: "")
                == WorkQueueStore.defaultLionWorkRootPath)
    }

    // 워크스페이스 루트 상수는 큐 기본값에서 잘라 만든 것이 아니다. 두 값이 오늘 부모-자식
    // 관계인 것은 맞지만, 그것은 오늘의 배치일 뿐이고 이 항목이 끊은 의존이 아니다.
    @Test func rootConstantIsItsOwnValue() {
        #expect(WorkQueueStore.defaultLionWorkRootPath == Self.expectedRoot)
        #expect(WorkQueueStore.defaultRootPath == "/Users/lioncho/Work/lion_work/queue")
    }
}
