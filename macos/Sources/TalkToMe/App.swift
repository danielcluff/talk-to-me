import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TalkToMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var core = TalkCore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(core)
        } label: {
            // the waveform is the icon; it pulses while speaking and is
            // dimmed when no model is installed
            Image(nsImage: MenuBarIcon.image)
                .symbolEffect(.variableColor.iterative, isActive: core.isSpeaking)
                .opacity(core.hasInstalledModel || core.models.isEmpty ? 1 : 0.5)
        }
        .menuBarExtraStyle(.menu)
    }
}

enum MenuBarIcon {
    /// Larger than the default menu bar symbol size; a template image so it
    /// follows the menu bar's light/dark appearance.
    static let image: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Talk to Me")!
            .withSymbolConfiguration(config)!
        img.isTemplate = true
        return img
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let core = TalkCore.shared
            core.start()
            await core.refreshAll()
            // first run: no model yet → open Settings on the Models page
            if !core.hasInstalledModel {
                SettingsWindow.shared.show(.models)
            }
        }
    }
}

// MARK: - Menu

struct MenuContent: View {
    @EnvironmentObject var core: TalkCore

    var body: some View {
        statusLine
        if let err = core.startError {
            Text(err)
        }
        if !core.hasInstalledModel, let rec = core.models.first(where: { $0.recommended }) {
            Button("Download \(rec.name) (\(megabytes(rec.size)))…") { SettingsWindow.shared.show(.models) }
        }
        Divider()

        if core.player.state == "paused" {
            Button("Resume") { core.command("resume") }
        } else {
            Button("Pause") { core.command("pause") }
                .disabled(core.player.state == "idle")
        }
        Button("Stop") { core.command("stop") }
            .disabled(core.player.state == "idle" && core.player.queued == 0)
        Button("Skip to Next Item") { core.command("skip") }
            .disabled(core.player.state == "idle")
        Divider()

        Button("Read Clipboard") {
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                core.speak(text, app: "clipboard")
            }
        }
        Button("Open File…") { openFile() }
        Divider()

        queueMenu
        Divider()

        Button("Settings…") { SettingsWindow.shared.show(.general) }
            .keyboardShortcut(",")
        Button("Quit Talk to Me") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder private var statusLine: some View {
        let p = core.player
        switch p.state {
        case "playing", "paused":
            let who = [appName(p.app), p.label].filter { !$0.isEmpty }.joined(separator: " · ")
            Text("\(p.state == "playing" ? "Speaking" : "Paused"): \(who) (\(min(p.index + 1, p.count))/\(p.count))")
        default:
            if p.model_state == "loading" {
                Text("Loading voice model…")
            } else if p.model_state == "failed" {
                Text("Model error: \(p.model_error)")
            } else {
                Text("Idle")
            }
        }
    }

    @ViewBuilder private var queueMenu: some View {
        let queued = core.jobs.filter { $0.state == "queued" }
        Menu("Queue (\(queued.count))") {
            if queued.isEmpty {
                Text("Nothing queued")
            }
            ForEach(queued) { job in
                Button("✕  \(appName(job.app)): \(String(job.preview.prefix(50)))") { core.removeJob(job.id) }
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            core.speakFile(url)
        }
    }
}

func appName(_ app: String) -> String {
    switch app {
    case "claude-code": return "Claude"
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    case "cli": return "Terminal"
    case "file": return "File"
    case "menu", "clipboard": return "Clipboard"
    case "preview": return "Preview"
    default: return app
    }
}

func megabytes(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000
        ? String(format: "%.1f GB", Double(bytes) / 1e9)
        : String(format: "%.0f MB", Double(bytes) / 1e6)
}
