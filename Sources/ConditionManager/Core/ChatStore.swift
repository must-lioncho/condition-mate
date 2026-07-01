import Foundation

// Persistent state for the dashboard's Claude chat panel (a Claude-Desktop-style
// composer). One active conversation: an ordered list of messages plus the Claude
// session id we resume so multi-turn context is preserved across sends. Attached
// images are copied to disk (attachments/) and referenced by filename; the dashboard
// fetches them back via /chat-img/<name>.
//
// This type is storage only — it never invokes Claude. AppDelegate orchestrates the
// `claude -p` call and feeds the reply back via appendAssistant (mirrors how
// ReviewStore stays pure while AppDelegate owns the process/HTTP side).
final class ChatStore {
    struct Message: Codable {
        var id: String
        var role: String            // "user" | "assistant"
        var text: String
        var images: [String] = []   // stored filenames (served via /chat-img/<name>)
        var createdAt: Date

        enum CodingKeys: String, CodingKey { case id, role, text, images, createdAt }
        init(id: String, role: String, text: String, images: [String] = [], createdAt: Date) {
            self.id = id; self.role = role; self.text = text; self.images = images; self.createdAt = createdAt
        }
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            role = try c.decodeIfPresent(String.self, forKey: .role) ?? "user"
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        }
    }

    // On-disk envelope: messages + the Claude resume id, persisted together.
    // cliSessionId is the interactive-CLI conversation's id (separate from the page
    // chat's sessionId) so closing the in-page terminal doesn't lose its transcript —
    // reopening resumes this exact session.
    private struct State: Codable {
        var sessionId: String = ""
        var cliSessionId: String = ""
        var messages: [Message] = []
        // Sessions manually attached via the "세션 연결" picker. For a subtask (which has
        // no lifecycle Goal in ReviewStore) this is the only place links are persisted, so
        // each subtask keeps its own connected-session list independent of the parent goal.
        var linkedSessions: [String] = []

        enum CodingKeys: String, CodingKey { case sessionId, cliSessionId, messages, linkedSessions }
        init() {}
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            cliSessionId = try c.decodeIfPresent(String.self, forKey: .cliSessionId) ?? ""
            messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
            linkedSessions = try c.decodeIfPresent([String].self, forKey: .linkedSessions) ?? []
        }
    }

    private let dir: URL
    private let imgDir: URL
    private let stateURL: URL
    private(set) var messages: [Message] = []
    private(set) var sessionId: String = ""
    private(set) var cliSessionId: String = ""
    private(set) var linkedSessions: [String] = []

    // Directory passed to `claude --add-dir` so the model may Read attached images.
    var attachmentsDir: URL { imgDir }

    // Default singleton conversation (the dashboard chat panel), stored under <data>/chat.
    convenience init() { self.init(dir: AppPaths.sub("chat")) }

    // Conversation rooted at an explicit directory. Used for per-goal "목표 명확화"
    // chats (one ChatStore per goal folder) so each goal keeps its own history and
    // Claude resume id, independent of the global dashboard chat.
    init(dir: URL) {
        self.dir = dir
        imgDir = dir.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("chat.json")
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: stateURL.path),
              let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        messages = s.messages
        sessionId = s.sessionId
        cliSessionId = s.cliSessionId
        linkedSessions = s.linkedSessions
    }
    private func save() {
        var s = State()
        s.sessionId = sessionId; s.cliSessionId = cliSessionId
        s.messages = messages; s.linkedSessions = linkedSessions
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }

    // Persist an uploaded image; returns the stored filename (uuid.<ext>). Falls back
    // to "png" when the extension is missing/unsafe.
    func saveImage(data: Data, ext: String) -> String? {
        let safe = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        let e = safe.isEmpty ? "png" : String(safe.prefix(5))
        let name = UUID().uuidString + "." + e
        do { try data.write(to: imgDir.appendingPathComponent(name), options: .atomic); return name }
        catch { return nil }
    }
    func imagePath(_ name: String) -> URL { imgDir.appendingPathComponent(name) }

    @discardableResult
    func appendUser(text: String, images: [String]) -> Message {
        let m = Message(id: UUID().uuidString, role: "user", text: text, images: images, createdAt: Date())
        messages.append(m); save(); return m
    }
    @discardableResult
    func appendAssistant(text: String) -> Message {
        let m = Message(id: UUID().uuidString, role: "assistant", text: text, images: [], createdAt: Date())
        messages.append(m); save(); return m
    }
    func setSession(_ id: String) {
        guard !id.isEmpty else { return }
        sessionId = id; save()
    }
    // Persist the interactive CLI's session id so reopening the in-page terminal resumes
    // this exact conversation instead of starting a fresh one.
    func setCliSession(_ id: String) {
        guard !id.isEmpty, id != cliSessionId else { return }
        cliSessionId = id; save()
    }
    // Attach/detach a manually-linked session (the subtask's "세션 연결" picker). Mirrors
    // ReviewStore.link/unlinkGoalSession, but scoped to this folder's own list.
    func addLinked(_ id: String) {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !linkedSessions.contains(t) else { return }
        linkedSessions.append(t); save()
    }
    func removeLinked(_ id: String) {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard linkedSessions.contains(t) else { return }
        linkedSessions.removeAll { $0 == t }; save()
    }
    // Start a fresh conversation: drop the resume id and message history, and remove
    // the stored image files (they belong only to the cleared conversation).
    func reset() {
        sessionId = ""; messages = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: imgDir.path) {
            for n in names { try? FileManager.default.removeItem(at: imgDir.appendingPathComponent(n)) }
        }
        save()
    }

    // Serve a stored image back to the dashboard: (bytes, mime, name) or nil for 404.
    func serveImage(name: String) -> (Data, String, String)? {
        // Reject path traversal — only a bare filename inside attachments/ is allowed.
        guard !name.contains("/"), !name.contains(".."),
              let data = try? Data(contentsOf: imgDir.appendingPathComponent(name)) else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        default: mime = "application/octet-stream"
        }
        return (data, mime, name)
    }
}
