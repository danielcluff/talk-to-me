import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, models, voices, sources, dictionary, history, shortcuts, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .voices: "Voices"
        case .sources: "Sources"
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
        NavigationSplitView {
            List(SettingsPage.allCases, selection: Binding(get: { selection.page }, set: { if let p = $0 { selection.page = p } })) { page in
                Label(page.title, systemImage: page.icon)
                    .tag(page)
                    .padding(.vertical, 3)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle) // the page list always stays visible
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selection.page {
                    case .general: GeneralPage()
                    case .models: ModelsPage()
                    case .voices: VoicesPage()
                    case .sources: SourcesPage()
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
            .navigationTitle(selection.page.title)
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

    var body: some View {
        PageHeader(title: "Models", subtitle: "Voice models run on this Mac. Nothing is downloaded until you choose to.")
        ForEach(core.models) { m in
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.name).font(.title3.weight(.semibold))
                    if m.recommended { Badge(text: "Recommended") }
                    if m.active { Badge(text: "Active", color: .green) }
                    Spacer()
                    Text(megabytes(m.size)).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(m.description).foregroundStyle(.secondary)
                Text("English").font(.caption).foregroundStyle(.secondary)
                actions(m)
            }
        }
        if let err = core.lastError {
            Text(err).foregroundStyle(.red).font(.callout)
        }
        Spacer()
            .alert(item: $confirmDelete) { m in
                Alert(title: Text("Delete \(m.name)?"),
                      message: Text("This removes \(megabytes(m.size)) of model files. You can download it again later."),
                      primaryButton: .destructive(Text("Delete")) { core.deleteModel(m.id) },
                      secondaryButton: .cancel())
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
                if m.active {
                    Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Use This Model") { core.activate(m.id) }
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

    private var items: [JobInfo] {
        core.jobs.filter { $0.state != "queued" && $0.state != "playing" }
    }

    var body: some View {
        Group { content }
            .task { await core.refreshJobs() }
    }

    @ViewBuilder private var content: some View {
        PageHeader(title: "History", subtitle: "The last 50 things Talk to Me read. Replay one or copy its text.")
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
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        PageHeader(title: "Permissions", subtitle: "Only needed for the Read Selection hotkey.")
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
        Text("A development build is signed ad hoc, so macOS may ask again after each rebuild. Signed releases keep the permission.")
            .font(.callout).foregroundStyle(.secondary)
            .onReceive(timer) { _ in
                accessibility = Permissions.accessibilityGranted()
                finder = Permissions.finderAutomation(ask: false)
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
            Text("Speech runs on this Mac with llama.cpp and Metal. Text never leaves the machine.")
                .foregroundStyle(.secondary)
            Text("Models: Kokoro-82M (Apache 2.0), tiny-voca. Markdown: md4c (MIT).")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
