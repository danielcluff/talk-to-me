import AppKit
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, models, voices, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .voices: "Voices"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .voices: "person.wave.2"
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
