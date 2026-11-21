import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, models, voices, sources, briefing, dictionary, history, shortcuts, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .voices: "Voices"
        case .sources: "Sources"
        case .briefing: "Briefing"
        case .dictionary: "Dictionary"
        case .history: "History"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .voices: "person.wave.2"
        case .sources: "app.connected.to.app.below.fill"
        case .briefing: "text.bubble"
        case .dictionary: "character.book.closed"
        case .history: "clock.arrow.circlepath"
        case .shortcuts: "keyboard"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

/// The Settings window, managed with AppKit so a menu bar (LSUIElement) app
/// can open and focus it from anywhere, including at first launch.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let selection = PageSelection()

    func show(_ page: SettingsPage) {
        selection.page = page
        if window == nil {
            let root = SettingsView()
                .environmentObject(TalkCore.shared)
                .environmentObject(selection)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "Talk to Me"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: root)
            w.setContentSize(NSSize(width: 860, height: 600))
            w.minSize = NSSize(width: 720, height: 480)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class PageSelection: ObservableObject {
    @Published var page: SettingsPage = .general
}

struct SettingsView: View {
    @EnvironmentObject var core: TalkCore
    @EnvironmentObject var selection: PageSelection

    var body: some View {
        // A fixed sidebar and a subtle line instead of NavigationSplitView,
        // whose divider is high-contrast and can be dragged.
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: Binding(get: { selection.page }, set: { if let p = $0 { selection.page = p } })) { page in
                Label(page.title, systemImage: page.icon)
                    .tag(page)
                    .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .frame(width: 210)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selection.page {
                    case .general: GeneralPage()
                    case .models: ModelsPage()
                    case .voices: VoicesPage()
                    case .sources: SourcesPage()
                    case .briefing: BriefingPage()
                    case .dictionary: DictionaryPage()
                    case .history: HistoryPage()
                    case .shortcuts: ShortcutsPage()
                    case .permissions: PermissionsPage()
                    case .about: AboutPage()
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .task { await core.refreshAll() }
    }
}

// MARK: - Building blocks

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

struct Badge: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

// MARK: - General

struct GeneralPage: View {
    @EnvironmentObject var core: TalkCore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cliMessage: String?

    var body: some View {
        PageHeader(title: "General", subtitle: "How Talk to Me reads and runs.")

        SectionTitle(text: "Reading")
        Card {
            HStack {
                Text("Speed")
                Slider(value: Binding(get: { core.settings.speed }, set: { core.settings.speed = $0 }),
                       in: 0.5...2.0, step: 0.1) { editing in
                    if !editing { core.update(["speed": core.settings.speed]) }
                }
                Text(String(format: "%.1f×", core.settings.speed)).monospacedDigit().frame(width: 40)
            }
            Picker("Code blocks", selection: Binding(get: { core.settings.code_blocks }, set: { core.update(["code_blocks": $0]) })) {
                Text("Say \u{201C}code block\u{201D}").tag("announce")
                Text("Skip silently").tag("skip")
                Text("Read them").tag("read")
            }
            Picker("Tables", selection: Binding(get: { core.settings.tables }, set: { core.update(["tables": $0]) })) {
                Text("Say how many rows").tag("announce")
                Text("Skip silently").tag("skip")
                Text("Read them").tag("read")
            }
        }

        SectionTitle(text: "App")
        Card {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        core.lastError = "Launch at login: \(error.localizedDescription)"
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Stepper("Unload the model after \(core.settings.idle_unload_minutes) idle minutes",
                    value: Binding(get: { core.settings.idle_unload_minutes }, set: { core.update(["idle_unload_minutes": $0]) }),
                    in: 1...240)
        }

        SectionTitle(text: "Command line")
        Card {
            Text("The talktome command reads files and piped text, and controls playback from a terminal or an agent hook.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Install talktome in ~/.local/bin") { installCLI() }
                if let cliMessage { Text(cliMessage).font(.callout).foregroundStyle(.secondary) }
            }
            Text("API: http://127.0.0.1:\(core.settings.port)").font(.callout.monospaced()).foregroundStyle(.secondary)
        }

        if let err = core.lastError {
            Text(err).foregroundStyle(.red).font(.callout)
        }
    }

    private func installCLI() {
        guard let src = Bundle.main.url(forResource: "talktome", withExtension: nil) else {
            cliMessage = "talktome is not in this app bundle"
            return
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let dst = dir.appendingPathComponent("talktome")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
            cliMessage = "Linked \(dst.path)"
        } catch {
            cliMessage = error.localizedDescription
        }
    }
}

// MARK: - Models

struct ModelsPage: View {
    @EnvironmentObject var core: TalkCore
    @State private var confirmDelete: ModelInfo?

    private let groups: [(kind: String, title: String, detail: String)] = [
        ("voice", "Voices", "The voice that reads to you. One is in use at a time."),
        ("summary", "Summaries", "Optional. Local models for Briefing, if you'd rather not use Codex, Claude Code or OpenCode. Loaded only while summarizing."),
        ("listening", "Listening", "Optional. Local speech recognition for answering briefings. Apple's built-in recognizer needs no download."),
    ]

    var body: some View {
        PageHeader(title: "Models", subtitle: "Models run on this Mac. Nothing is downloaded until you choose to.")
        ForEach(groups, id: \.kind) { g in
            SectionTitle(text: g.title)
            Text(g.detail).font(.callout).foregroundStyle(.secondary)
            ForEach(core.models.filter { $0.kind == g.kind }) { m in card(m) }
        }
        let total = core.models.reduce(Int64(0)) { $0 + $1.disk_bytes }
        HStack {
            Text("Models use \(megabytes(total)) on disk.").foregroundStyle(.secondary)
            Spacer()
            if let root = core.models.first?.dir {
                Button("Show Models Folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: root).deletingLastPathComponent())
                }
            }
        }
        if let err = core.lastError {
            Text(err).foregroundStyle(.red).font(.callout)
        }
        Spacer()
            .alert(item: $confirmDelete) { m in
                Alert(title: Text("Delete \(m.name)?"),
                      message: Text(deleteMessage(m)),
                      primaryButton: .destructive(Text("Delete")) { core.deleteModel(m.id) },
                      secondaryButton: .cancel())
            }
    }

    private func deleteMessage(_ m: ModelInfo) -> String {
        var msg = "This removes \(megabytes(max(m.disk_bytes, m.size))) of files from \(m.dir). You can download it again later."
        if m.active {
            switch m.kind {
            case "voice": msg += " It's the voice in use; Talk to Me switches to another installed voice."
            case "summary": msg += " It's your briefing summarizer; briefings are turned off."
            default: msg += " It's your recognizer; answering switches to Apple's."
            }
        }
        return msg
    }

    private func useLabel(_ m: ModelInfo) -> String {
        switch m.kind {
        case "summary": return "Use for Briefings"
        case "listening": return "Use for Listening"
        default: return "Use This Voice"
        }
    }

    private func card(_ m: ModelInfo) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(m.name).font(.title3.weight(.semibold))
                if m.recommended { Badge(text: "Recommended") }
                if m.active { Badge(text: "In use", color: .green) }
                Spacer()
                Text(megabytes(m.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(m.description).foregroundStyle(.secondary)
            actions(m)
            if m.installed || m.disk_bytes > 0 {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(m.dir).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(megabytes(m.disk_bytes)) on disk").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.dir)])
                    }
                    .controlSize(.small)
                }
                if m.partial_bytes > 0 && m.download?.active != true {
                    HStack {
                        Label("Unfinished download: \(megabytes(m.partial_bytes))", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Remove") { core.cleanPartials(m.id) }.controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder private func actions(_ m: ModelInfo) -> some View {
        if let d = m.download, d.active {
            HStack {
                ProgressView(value: Double(d.done), total: Double(max(d.total, 1)))
                Text("\(megabytes(d.done)) of \(megabytes(d.total))").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { core.cancelDownload(m.id) }
            }
        } else if m.installed {
            HStack {
                if !m.active {
                    Button(useLabel(m)) { core.activate(m.id) }
                }
                Spacer()
                Button("Delete…", role: .destructive) { confirmDelete = m }
            }
        } else {
            HStack {
                Button(m.recommended ? "Download (Recommended)" : "Download") { core.download(m.id) }
                    .buttonStyle(.borderedProminent)
                if let d = m.download, !d.error.isEmpty {
                    Text("Last attempt failed: \(d.error)").foregroundStyle(.red).font(.callout)
                }
            }
        }
    }
}

// MARK: - Voices

struct VoicesPage: View {
    @EnvironmentObject var core: TalkCore
    @State private var loading = false
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        Group { content }
            .task(id: core.activeModel?.id) {
                loading = true
                await core.refreshVoices()
                loading = false
            }
    }

    @ViewBuilder private var content: some View {
        PageHeader(title: "Voices", subtitle: "Pick the default voice. ▶ plays a short sample.")
        if core.activeModel?.installed != true {
            Card {
                Text("Download a model first.").foregroundStyle(.secondary)
                Button("Go to Models") { SettingsWindow.shared.show(.models) }
            }
        } else if loading && core.voices.isEmpty {
            ProgressView("Loading \(core.activeModel?.name ?? "model")…")
        } else {
            Card {
                HStack {
                    Text("Speed")
                    Slider(value: Binding(get: { core.settings.speed }, set: { core.settings.speed = $0 }), in: 0.5...2.0, step: 0.1) { editing in
                        if !editing { core.update(["speed": core.settings.speed]) }
                    }
                    Text(String(format: "%.1f×", core.settings.speed)).monospacedDigit().frame(width: 40)
                }
            }
            ForEach(groups, id: \.0) { title, voices in
                SectionTitle(text: title)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(voices) { v in voiceCard(v) }
                }
            }
        }
    }

    private var groups: [(String, [VoiceInfo])] {
        let order = [("American · Female", "US", "female"), ("American · Male", "US", "male"),
                     ("British · Female", "UK", "female"), ("British · Male", "UK", "male")]
        var out = order.compactMap { title, accent, gender -> (String, [VoiceInfo])? in
            let vs = core.voices.filter { $0.accent == accent && $0.gender == gender }
            return vs.isEmpty ? nil : (title, vs)
        }
        let rest = core.voices.filter { v in !order.contains { $0.1 == v.accent && $0.2 == v.gender } }
        if !rest.isEmpty { out.append(("Voices", rest)) }
        return out
    }

    private func voiceCard(_ v: VoiceInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(v.displayName).font(.headline)
                Text(v.name).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button { core.previewVoice(v) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .help("Play a sample")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(v.default ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: v.default ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { core.update(["voice": v.name]) }
        .help(v.default ? "Default voice" : "Click to make this the default")
    }
}

// MARK: - Sources

struct SourcesPage: View {
    @EnvironmentObject var core: TalkCore

    var body: some View {
        Group { content }
            .task {
                await core.refreshIntegrations()
                await core.refreshPaired()
                if core.voices.isEmpty { await core.refreshVoices() }
            }
    }

    @ViewBuilder private var content: some View {
        PageHeader(title: "Sources", subtitle: "Agents that speak their replies. Give each its own voice to tell them apart by ear.")
        ForEach(Integration.all) { i in card(i) }
        browserCard
        if let msg = core.integrationMessage {
            Text(msg).font(.callout).foregroundStyle(.secondary)
        }
        Text("Install writes to the agent's own config (Codex keeps a backup of config.toml). Restart open agent sessions afterwards.")
            .font(.callout).foregroundStyle(.secondary)
    }

    /// The unpacked extension lives at a stable path (Chrome ties an unpacked
    /// extension's identity, and so its pairing, to the folder). The copy is
    /// refreshed from the app bundle each time it's revealed.
    private var browserExtensionURL: URL? {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("integrations/browser") else { return nil }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TalkToMe/browser-extension")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: support.path) {
                // replace the files in place so the folder (and Chrome's ID) stays
                for item in try fm.contentsOfDirectory(atPath: support.path) {
                    try fm.removeItem(at: support.appendingPathComponent(item))
                }
                for item in try fm.contentsOfDirectory(atPath: bundled.path) {
                    try fm.copyItem(at: bundled.appendingPathComponent(item), to: support.appendingPathComponent(item))
                }
            } else {
                try fm.copyItem(at: bundled, to: support)
            }
            return support
        } catch {
            return bundled
        }
    }

    private var browserCard: some View {
        let src = core.source("browser")
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Browser").font(.title3.weight(.semibold))
                if !core.pairedOrigins.isEmpty { Badge(text: "Paired", color: .green) }
                Spacer()
                Button("Show Extension Folder") {
                    if let url = browserExtensionURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            Text("Reads pages, selections and ChatGPT or Claude replies through the same queue, highlighting each sentence as it's spoken.")
                .foregroundStyle(.secondary)
            Text("Install: open chrome://extensions (or Brave, Edge, Arc), turn on Developer mode, click Load unpacked and pick the folder that opens (~/Library/Application Support/TalkToMe/browser-extension). Then open the extension's popup and click Connect; Talk to Me asks you to allow it. After an app update, click Show Extension Folder again and reload the extension.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(core.pairedOrigins, id: \.self) { origin in
                HStack {
                    Text(origin).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { core.forgetPaired(origin) }
                }
            }
            Divider()
            Toggle("Read its replies aloud", isOn: Binding(get: { src.enabled }, set: { core.updateSource("browser", ["enabled": $0]) }))
            Toggle("Say its name first", isOn: Binding(get: { src.announce }, set: { core.updateSource("browser", ["announce": $0]) }))
            Picker("Voice", selection: Binding(get: { src.voice }, set: { core.updateSource("browser", ["voice": $0]) })) {
                Text("Default voice").tag("")
                ForEach(core.voices) { v in
                    Text("\(v.displayName) (\(v.accent) \(v.gender))").tag(v.name)
                }
            }
        }
    }

    private func card(_ i: Integration) -> some View {
        let status = core.integrations[i.target]
        let src = core.source(i.app)
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Text(i.name).font(.title3.weight(.semibold))
                if status?.installed == true { Badge(text: "Installed", color: .green) }
                Spacer()
                if status?.installed == true {
                    Button("Remove") { core.setIntegration(i, installed: false) }
                } else if status?.present == false {
                    Text("Not found on this Mac").foregroundStyle(.secondary)
                } else {
                    Button("Install") { core.setIntegration(i, installed: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(i.detail).foregroundStyle(.secondary)
            Divider()
            Toggle("Read its replies aloud", isOn: Binding(get: { src.enabled }, set: { core.updateSource(i.app, ["enabled": $0]) }))
            if core.settings.briefing.enabled && i.app != "herdr" {
                Toggle("Brief me: summarize long replies and offer the full report",
                       isOn: Binding(get: { src.brief }, set: { core.updateSource(i.app, ["brief": $0]) }))
                    .disabled(!src.enabled)
            }
            Toggle("Say its name first (\u{201C}\(i.name.components(separatedBy: " ").first ?? i.name), in my-project.\u{201D})",
                   isOn: Binding(get: { src.announce }, set: { core.updateSource(i.app, ["announce": $0]) }))
            Picker("Voice", selection: Binding(get: { src.voice }, set: { core.updateSource(i.app, ["voice": $0]) })) {
                Text("Default voice").tag("")
                ForEach(core.voices) { v in
                    Text("\(v.displayName) (\(v.accent) \(v.gender))").tag(v.name)
                }
            }
            .disabled(!src.enabled)
        }
    }
}

// MARK: - Briefing

struct BriefingPage: View {
    @EnvironmentObject var core: TalkCore
    @State private var model = ""
    @State private var yesWords = ""
    @State private var noWords = ""

    private var b: BriefingSettings { core.settings.briefing }

    private let backends: [(id: String, name: String, hint: String, cloud: String?)] = [
        ("codex", "Codex", "e.g. gpt-6-luna (fast and light). Empty uses your Codex default.", "OpenAI"),
        ("claude", "Claude Code", "e.g. haiku or sonnet. Empty uses your Claude Code default.", "Anthropic"),
        ("opencode", "OpenCode", "provider/model, e.g. ollama/qwen2.5-coder:7b. Empty uses your OpenCode default.", "your OpenCode provider"),
        ("ollama", "Ollama", "a model you've pulled, e.g. qwen3:4b.", nil),
        ("local", "Local model", "a summary model downloaded on the Models page.", nil),
    ]

    var body: some View {
        Group { content }
            .onAppear {
                model = b.model
                yesWords = b.yes_words.joined(separator: ", ")
                noWords = b.no_words.joined(separator: ", ")
            }
    }

    @ViewBuilder private var content: some View {
        PageHeader(title: "Briefing", subtitle: "Hear a short summary of each agent's report, then answer whether you want the whole thing.")

        Card {
            Toggle("Brief me on agent replies", isOn: Binding(get: { b.enabled }, set: { core.updateBriefing(["enabled": $0]) }))
                .font(.headline)
            Text("When Claude Code, Codex or OpenCode finishes a long reply, a summarizer you pick writes one to three sentences. Talk to Me reads them and asks \u{201C}Want the full report?\u{201D} Say yes or no, or press \u{2325}\u{21E7}R for yes. Files, selections and browser reads are always read in full.")
                .foregroundStyle(.secondary)
        }

        SectionTitle(text: "Summarizer")
        Card {
            Picker("Use", selection: Binding(get: { b.backend }, set: { core.updateBriefing(["backend": $0]) })) {
                ForEach(backends, id: \.id) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.segmented)
            let current = backends.first { $0.id == b.backend } ?? backends[0]
            if b.backend == "local" {
                let installed = core.models.filter { $0.kind == "summary" && $0.installed }
                if installed.isEmpty {
                    HStack {
                        Text("No summary model downloaded yet.").foregroundStyle(.secondary)
                        Button("Go to Models") { SettingsWindow.shared.show(.models) }
                    }
                } else {
                    Picker("Model", selection: Binding(get: { b.model }, set: { core.updateBriefing(["model": $0]) })) {
                        if !installed.contains(where: { $0.id == b.model }) { Text("Choose a model").tag(b.model) }
                        ForEach(installed) { Text($0.name).tag($0.id) }
                    }
                }
            } else {
                HStack {
                    TextField("Model", text: $model)
                        .onSubmit { core.updateBriefing(["model": model]) }
                    Button("Save") { core.updateBriefing(["model": model]) }
                }
            }
            Text(current.hint).font(.callout).foregroundStyle(.secondary)
            if b.backend == "ollama" {
                TextField("Ollama URL", text: Binding(get: { b.ollama_url }, set: { core.updateBriefing(["ollama_url": $0]) }))
            }
            if let cloud = current.cloud {
                Label("Reports are sent to \(cloud) to be summarized.", systemImage: "network")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Label("Reports stay on this Mac.", systemImage: "lock")
                    .font(.callout).foregroundStyle(.green)
            }
            HStack {
                Stepper("Brief replies longer than \(b.min_words) words", value: Binding(get: { b.min_words }, set: { core.updateBriefing(["min_words": $0]) }), in: 20...400, step: 10)
            }
            Stepper("Give up after \(b.timeout_seconds) seconds and read the first paragraph", value: Binding(get: { b.timeout_seconds }, set: { core.updateBriefing(["timeout_seconds": $0]) }), in: 5...120, step: 5)
            HStack {
                Button("Test with a Sample Report") { core.testBriefing() }
                    .buttonStyle(.borderedProminent)
                Text("Summarizes a made-up report and reads the briefing, question included.").font(.callout).foregroundStyle(.secondary)
            }
        }

        SectionTitle(text: "Answering")
        Card {
            Toggle("Listen for \u{201C}yes\u{201D} or \u{201C}no\u{201D} after the question", isOn: Binding(get: { b.listen }, set: { core.updateBriefing(["listen": $0]) }))
            HStack {
                Text("Listen for")
                Slider(value: Binding(get: { Double(b.listen_seconds) }, set: { core.updateBriefing(["listen_seconds": Int($0)]) }), in: 2...8, step: 1)
                Text("\(b.listen_seconds) s").monospacedDigit().frame(width: 32)
            }
            Picker("Recognizer", selection: Binding(get: { b.recognizer }, set: { core.updateBriefing(["recognizer": $0]) })) {
                Text("Apple, on this Mac (no download)").tag("apple")
                ForEach(core.models.filter { $0.kind == "listening" && $0.installed }) { m in
                    Text("\(m.name) (local)").tag(m.id)
                }
            }
            Text("Local recognizers are downloaded on the Models page, under Listening.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Yes words")
                TextField("", text: $yesWords).onSubmit { saveWords() }
            }
            HStack {
                Text("No words")
                TextField("", text: $noWords).onSubmit { saveWords() }
            }
            Text("Silence, or anything else, counts as no answer: the report stays in Read Last Full Report and History.")
                .font(.callout).foregroundStyle(.secondary)
            if !(Listener.speechAuthorized() && Listener.micAuthorized()) {
                Button("Allow Microphone and Speech Recognition…") {
                    Listener.requestPermissions { _ in }
                }
            }
        }
        if let err = core.lastError {
            Text(err).foregroundStyle(.red).font(.callout)
        }
    }

    private func saveWords() {
        func split(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        core.updateBriefing(["yes_words": split(yesWords), "no_words": split(noWords)])
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @EnvironmentObject var core: TalkCore
    @State private var from = ""
    @State private var to = ""
    @State private var caseSensitive = false

    var body: some View {
        PageHeader(title: "Dictionary", subtitle: "Teach the voice how to say names, acronyms and jargon. Whole words only; code blocks aren't affected.")
        Card {
            HStack {
                TextField("Written as (kubectl)", text: $from)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Say it as (cube control)", text: $to)
                Toggle("Aa", isOn: $caseSensitive)
                    .toggleStyle(.button)
                    .help("Match upper and lower case exactly")
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty || to.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onSubmit { add() }
        }
        if core.settings.dictionary.isEmpty {
            Text("No entries yet.").foregroundStyle(.secondary)
        } else {
            Card {
                ForEach(Array(core.settings.dictionary.enumerated()), id: \.offset) { i, e in
                    if i > 0 { Divider() }
                    HStack {
                        Text(e.from).font(.body.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(e.to)
                        if e.case_sensitive { Badge(text: "Aa", color: .secondary) }
                        Spacer()
                        Button { core.speak("\(e.from).", app: "preview") } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.plain)
                            .help("Hear it")
                        Button { remove(i) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .help("Remove")
                    }
                }
            }
        }
    }

    private func add() {
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else { return }
        var list = core.settings.dictionary.filter { $0.from.lowercased() != f.lowercased() }
        list.append(DictionaryEntry(from: f, to: t, case_sensitive: caseSensitive))
        core.setDictionary(list)
        from = ""
        to = ""
        caseSensitive = false
    }

    private func remove(_ i: Int) {
        var list = core.settings.dictionary
        list.remove(at: i)
        core.setDictionary(list)
    }
}

// MARK: - History

struct HistoryPage: View {
    @EnvironmentObject var core: TalkCore
    @State private var confirmClear = false

    private var items: [JobInfo] {
        core.jobs.filter { $0.state != "queued" && $0.state != "playing" }
    }

    var body: some View {
        Group { content }
            .task { await core.refreshJobs() }
    }

    @ViewBuilder private var content: some View {
        HStack(alignment: .top) {
            PageHeader(title: "History", subtitle: "The last 50 things Talk to Me read, kept as text (no audio) across restarts. Replay one or copy its text.")
            Spacer()
            Button("Clear History…", role: .destructive) { confirmClear = true }
                .disabled(items.isEmpty)
        }
        .alert("Clear history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { core.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the text of all \(items.count) items. It can't be undone.")
        }
        if items.isEmpty {
            Text("Nothing yet.").foregroundStyle(.secondary)
        } else {
            Card {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, job in
                    if i > 0 { Divider() }
                    row(job)
                }
            }
        }
    }

    private func row(_ job: JobInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text([appName(job.app), job.label].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.headline)
                    if job.state != "done" { Badge(text: job.state.capitalized, color: .secondary) }
                    Spacer()
                    if let at = job.finishedAt {
                        Text(at, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(job.preview).foregroundStyle(.secondary).lineLimit(2)
                Text("\(job.chunks) sentence\(job.chunks == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary)
            }
            VStack(spacing: 8) {
                Button { core.replay(job.id) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .help("Read it again")
                Button { core.copyText(job.id) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .help("Copy the text")
            }
            .disabled(job.has_text == false)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shortcuts

struct ShortcutsPage: View {
    var body: some View {
        PageHeader(title: "Shortcuts", subtitle: "Global hotkeys work in every app. Click a shortcut to change it; press Delete to clear it.")
        Card {
            row("Read selection", .readSelection,
                "Selected text in any app, or the selected .md and .txt files in Finder.")
            Divider()
            row("Pause / resume", .togglePause, nil)
            Divider()
            row("Stop and clear the queue", .stopSpeaking, nil)
            Divider()
            row("Skip to the next item", .skipItem, nil)
            Divider()
            row("Read clipboard", .readClipboard, nil)
        }
        Text("Read selection needs Accessibility permission, and Finder files need Automation permission. See Permissions.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func row(_ title: String, _ name: KeyboardShortcuts.Name, _ detail: String?) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }
}

// MARK: - Permissions

struct PermissionsPage: View {
    @State private var accessibility = Permissions.accessibilityGranted()
    @State private var finder = Permissions.finderAutomation(ask: false)
    @State private var speech = Listener.speechAuthorized() && Listener.micAuthorized()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        PageHeader(title: "Permissions", subtitle: "Only needed for Read Selection and for answering briefings by voice.")
        Card {
            permissionRow(
                title: "Accessibility",
                detail: "Reads the selected text in other apps, or copies it with ⌘C when an app doesn't share it.",
                granted: accessibility,
                action: {
                    _ = Permissions.accessibilityGranted(prompt: true)
                    Permissions.openSystemSettings("Privacy_Accessibility")
                })
            Divider()
            permissionRow(
                title: "Automation: Finder",
                detail: finder == .finderNotRunning ? "Finder isn't running." : "Reads which files are selected in Finder.",
                granted: finder == .granted,
                action: {
                    if Permissions.finderAutomation(ask: true) != .granted {
                        Permissions.openSystemSettings("Privacy_Automation")
                    }
                    finder = Permissions.finderAutomation(ask: false)
                })
        }
        Card {
            permissionRow(
                title: "Microphone and Speech Recognition",
                detail: "Hears \u{201C}yes\u{201D} or \u{201C}no\u{201D} after a briefing asks whether you want the full report. Recognition runs on this Mac.",
                granted: speech,
                action: {
                    Listener.requestPermissions { _ in speech = Listener.speechAuthorized() && Listener.micAuthorized() }
                })
        }
        Text("A development build is signed ad hoc, so macOS may ask again after each rebuild. Signed releases keep the permission.")
            .font(.callout).foregroundStyle(.secondary)
            .onReceive(timer) { _ in
                accessibility = Permissions.accessibilityGranted()
                finder = Permissions.finderAutomation(ask: false)
                speech = Listener.speechAuthorized() && Listener.micAuthorized()
            }
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Grant…", action: action)
            }
        }
    }
}

// MARK: - About

struct AboutPage: View {
    var body: some View {
        PageHeader(title: "Talk to Me", subtitle: "Local text-to-speech for your apps and agents.")
        Card {
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
            Text("Speech runs on this Mac with llama.cpp and Metal, and listening uses on-device recognition. Text stays on this Mac, with one exception: when Briefings are on and use Codex, Claude Code, OpenCode or an Ollama server on another machine, agent replies are sent to that service to be summarized. A local summary model keeps everything here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Models: Kokoro-82M (Apache 2.0), tiny-voca. Markdown: md4c (MIT).")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
