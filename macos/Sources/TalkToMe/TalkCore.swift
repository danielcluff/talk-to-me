import CTalk
import Foundation
import SwiftUI

// MARK: - API types (same JSON as the HTTP API, see docs/PLAN.md §3)

struct PlayerState: Decodable, Equatable {
    var state: String = "idle"          // idle | playing | paused
    var job: Int? = nil
    var app: String = ""
    var label: String = ""
    var index: Int = 0
    var count: Int = 0
    var queued: Int = 0
    var model: String = ""
    var model_state: String = "unloaded" // unloaded | loading | loaded | failed
    var model_error: String = ""
}

struct DownloadState: Decodable, Equatable {
    var done: Int64
    var total: Int64
    var active: Bool
    var error: String
}

struct ModelInfo: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
    var recommended: Bool
    var size: Int64
    var installed: Bool
    var active: Bool
    var loaded: Bool
    var download: DownloadState?
}

struct VoiceInfo: Decodable, Identifiable, Equatable {
    var name: String
    var accent: String
    var gender: String
    var `default`: Bool
    var id: String { name }

    /// "af_heart" → "Heart", "M2" → "M2"
    var displayName: String {
        guard let us = name.firstIndex(of: "_") else { return name }
        return name[name.index(after: us)...].capitalized
    }
}

struct JobInfo: Decodable, Identifiable, Equatable {
    var id: Int
    var app: String
    var label: String
    var preview: String
    var chunks: Int
    var state: String
    var index: Int?
}

struct Settings: Codable, Equatable {
    var model: String = "kokoro"
    var voice: String = ""
    var speed: Double = 1.0
    var port: Int = 9932
    var idle_unload_minutes: Int = 15
    var code_blocks: String = "announce"
    var tables: String = "announce"
    var dedupe_seconds: Int = 30
    var sources: [String: SourceSetting] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "kokoro"
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9932
        idle_unload_minutes = try c.decodeIfPresent(Int.self, forKey: .idle_unload_minutes) ?? 15
        code_blocks = try c.decodeIfPresent(String.self, forKey: .code_blocks) ?? "announce"
        tables = try c.decodeIfPresent(String.self, forKey: .tables) ?? "announce"
        dedupe_seconds = try c.decodeIfPresent(Int.self, forKey: .dedupe_seconds) ?? 30
        sources = try c.decodeIfPresent([String: SourceSetting].self, forKey: .sources) ?? [:]
    }
}

struct SourceSetting: Codable, Equatable {
    var enabled: Bool = true
    var voice: String = ""
    var announce: Bool = false
}

/// Agents Talk to Me integrates with: settings key (source app) and the
/// `talktome install` target.
struct Integration: Identifiable {
    let app: String
    let target: String
    let name: String
    let detail: String
    var id: String { app }

    static let all = [
        Integration(app: "claude-code", target: "claude", name: "Claude Code",
                    detail: "A plugin speaks each reply when a turn ends and adds a speak tool."),
        Integration(app: "codex", target: "codex", name: "Codex",
                    detail: "Uses Codex's notify setting; an existing notify program keeps running."),
        Integration(app: "opencode", target: "opencode", name: "OpenCode",
                    detail: "A plugin speaks the reply when a session goes idle."),
        Integration(app: "herdr", target: "herdr", name: "herdr",
                    detail: "A status bar with pause and stop; says when other agents finish."),
    ]
}

struct IntegrationStatus: Decodable { var installed: Bool; var present: Bool }

private struct ModelList: Decodable { var models: [ModelInfo] }
private struct VoiceList: Decodable { var model: String; var voices: [VoiceInfo] }
private struct JobList: Decodable { var jobs: [JobInfo] }
private struct APIError: Decodable { var error: String }
private struct CoreEvent: Decodable { var type: String; var state: String? }

// MARK: - Store

/// All app state comes from libtalk; this class only mirrors it for SwiftUI.
@MainActor
final class TalkCore: ObservableObject {
    static let shared = TalkCore()

    @Published var player = PlayerState()
    @Published var models: [ModelInfo] = []
    @Published var voices: [VoiceInfo] = []
    @Published var jobs: [JobInfo] = []
    @Published var settings = Settings()
    @Published var startError: String?
    @Published var lastError: String?

    private var downloadPoll: Timer?

    var hasInstalledModel: Bool { models.contains { $0.installed } }
    var activeModel: ModelInfo? { models.first { $0.active } }
    var isSpeaking: Bool { player.state == "playing" }

    func start() {
        let user = Unmanaged.passUnretained(self).toOpaque()
        let rc = talk_start(nil, { user, json in
            guard let user, let json else { return }
            let data = Data(bytes: json, count: strlen(json))
            let core = Unmanaged<TalkCore>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { core.handleEvent(data) }
        }, user)
        switch Int32(rc) {
        case Int32(TALK_OK): break
        case Int32(TALK_ERR_PORT): startError = "Another app holds the Talk to Me port. Quit it and relaunch."
        default: startError = "Talk to Me could not start (error \(rc))."
        }
        Task { await refreshAll() }
    }

    // MARK: calls

    /// libtalk call on a background thread (some routes wait, e.g. a model load).
    nonisolated func call(_ method: String, _ path: String, body: Data? = nil) async -> (Int, Data) {
        await Task.detached {
            var status: Int32 = 0
            let bodyString = body.flatMap { String(data: $0, encoding: .utf8) }
            let out: UnsafeMutablePointer<CChar>? = bodyString.map { b in
                b.withCString { talk_call(method, path, $0, &status) }
            } ?? talk_call(method, path, nil, &status)
            guard let out else { return (500, Data()) }
            defer { talk_free(out) }
            return (Int(status), Data(bytes: out, count: strlen(out)))
        }.value
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async -> T? {
        let (status, data) = await call("GET", path)
        guard status < 300 else { report(data); return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, _ json: [String: Any] = [:]) async -> Bool {
        let body = try? JSONSerialization.data(withJSONObject: json)
        let (status, data) = await call(method, path, body: body)
        if status >= 300 { report(data); return false }
        return true
    }

    private func report(_ data: Data) {
        lastError = (try? JSONDecoder().decode(APIError.self, from: data))?.error ?? "Request failed"
    }

    // MARK: refresh

    func refreshAll() async {
        await refreshPlayer()
        await refreshModels()
        await refreshSettings()
        await refreshJobs()
    }

    func refreshPlayer() async {
        if let p = await get("/v1/player", as: PlayerState.self) { player = p }
    }

    func refreshModels() async {
        if let m = await get("/v1/models", as: ModelList.self) { models = m.models }
        let downloading = models.contains { $0.download?.active == true }
        if downloading && downloadPoll == nil {
            downloadPoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in await TalkCore.shared.refreshModels() }
            }
        } else if !downloading, let t = downloadPoll {
            t.invalidate()
            downloadPoll = nil
        }
    }

    func refreshSettings() async {
        if let s = await get("/v1/settings", as: Settings.self) { settings = s }
    }

    func refreshJobs() async {
        if let j = await get("/v1/jobs", as: JobList.self) { jobs = j.jobs }
    }

    /// Loads the active model if needed (can take a second).
    func refreshVoices() async {
        guard activeModel?.installed == true else { voices = []; return }
        if let v = await get("/v1/voices", as: VoiceList.self) { voices = v.voices }
    }

    private func handleEvent(_ data: Data) {
        guard let e = try? JSONDecoder().decode(CoreEvent.self, from: data) else { return }
        Task {
            switch e.type {
            case "model_state":
                await refreshPlayer()
                await refreshModels()
            case "job_queued", "job_finished":
                await refreshPlayer()
                await refreshJobs()
            default:
                await refreshPlayer()
            }
        }
    }

    // MARK: actions

    func command(_ cmd: String) { Task { await send("POST", "/v1/player/\(cmd)"); await refreshPlayer() } }

    func speak(_ text: String, voice: String? = nil, app: String = "menu", label: String = "", policy: String = "interrupt") {
        var body: [String: Any] = ["text": text, "policy": policy, "source": ["app": app, "label": label]]
        if let voice { body["voice"] = voice }
        Task { await send("POST", "/v1/speak", body) }
    }

    func speakFile(_ url: URL, policy: String = "interrupt") {
        Task { await send("POST", "/v1/speak/file", ["path": url.path, "policy": policy, "source": ["app": "file", "label": url.lastPathComponent]]) }
    }

    func removeJob(_ id: Int) { Task { await send("DELETE", "/v1/jobs/\(id)"); await refreshJobs() } }

    func download(_ id: String) { Task { await send("POST", "/v1/models/\(id)/download"); await refreshModels() } }
    func cancelDownload(_ id: String) { Task { await send("POST", "/v1/models/\(id)/cancel") } }
    func deleteModel(_ id: String) { Task { await send("DELETE", "/v1/models/\(id)"); await refreshModels() } }

    func activate(_ id: String) {
        Task {
            await send("POST", "/v1/models/\(id)/activate")
            await refreshSettings()
            await refreshModels()
            await refreshVoices()
        }
    }

    func update(_ patch: [String: Any]) {
        Task {
            await send("PATCH", "/v1/settings", patch)
            await refreshSettings()
            if patch["voice"] != nil || patch["model"] != nil { await refreshVoices() }
        }
    }

    // MARK: integrations (run the bundled talktome CLI)

    @Published var integrations: [String: IntegrationStatus] = [:]
    @Published var integrationMessage: String?

    private nonisolated func runCLI(_ args: [String]) async -> (Int32, String) {
        await Task.detached {
            guard let url = Bundle.main.url(forResource: "talktome", withExtension: nil) else { return (127, "talktome is not in the app bundle") }
            let p = Process()
            p.executableURL = url
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (127, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
    }

    func refreshIntegrations() async {
        let (_, out) = await runCLI(["integrations", "--json"])
        if let data = out.data(using: .utf8),
           let s = try? JSONDecoder().decode([String: IntegrationStatus].self, from: data) {
            integrations = s
        }
    }

    func setIntegration(_ i: Integration, installed: Bool) {
        Task {
            let (code, out) = await runCLI([installed ? "install" : "uninstall", i.target])
            integrationMessage = code == 0
                ? out.trimmingCharacters(in: .whitespacesAndNewlines)
                : "\(i.name): \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
            await refreshIntegrations()
        }
    }

    func source(_ app: String) -> SourceSetting { settings.sources[app] ?? SourceSetting() }

    func updateSource(_ app: String, _ patch: [String: Any]) {
        update(["sources": [app: patch]])
    }

    func previewVoice(_ v: VoiceInfo) {
        speak("Hi, I'm \(v.displayName). This is how I sound when I read to you.", voice: v.name, app: "preview")
    }
}
