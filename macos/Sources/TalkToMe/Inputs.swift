import AppKit
import ApplicationServices
import KeyboardShortcuts

// MARK: - Hotkeys

extension KeyboardShortcuts.Name {
    // Defaults avoid Space and the browser extension's keys (see docs/PLAN.md §5).
    static let readSelection = Self("readSelection", initial: .init(.r, modifiers: [.option, .shift]))
    static let togglePause = Self("togglePause", initial: .init(.p, modifiers: [.option, .shift]))
    static let stopSpeaking = Self("stopSpeaking", initial: .init(.x, modifiers: [.option, .shift]))
    static let readClipboard = Self("readClipboard")
    static let skipItem = Self("skipItem")
    static let readLastReport = Self("readLastReport")
}

@MainActor
enum Hotkeys {
    static func install() {
        KeyboardShortcuts.onKeyUp(for: .readSelection) { Inputs.readSelection() }
        KeyboardShortcuts.onKeyUp(for: .togglePause) { TalkCore.shared.command("toggle") }
        KeyboardShortcuts.onKeyUp(for: .stopSpeaking) { TalkCore.shared.command("stop") }
        KeyboardShortcuts.onKeyUp(for: .readClipboard) { Inputs.readClipboard() }
        KeyboardShortcuts.onKeyUp(for: .skipItem) { TalkCore.shared.command("skip") }
        KeyboardShortcuts.onKeyUp(for: .readLastReport) { TalkCore.shared.readLastReport() }
    }
}

// MARK: - Reading what the user points at

@MainActor
enum Inputs {
    static let readableExtensions: Set<String> = ["md", "markdown", "txt", "text"]

    /// The Read Selection hotkey: selected .md/.txt files when Finder is in
    /// front, otherwise the selected text of the focused app.
    static func readSelection() {
        // during "Want the full report?" the hotkey means yes
        if TalkCore.shared.awaitingAnswer {
            TalkCore.shared.answer(true)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == "com.apple.finder" {
            let files = finderSelection()
            if !files.isEmpty {
                readFiles(files)
                return
            }
        }
        if let text = selectedText(), !text.isEmpty {
            TalkCore.shared.speak(text, app: "selection", label: front?.localizedName ?? "")
        } else {
            NSSound.beep()
        }
    }

    static func readClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            TalkCore.shared.speak(text, app: "clipboard")
        }
    }

    /// First file interrupts what is playing; the rest queue behind it.
    static func readFiles(_ urls: [URL]) {
        let readable = urls.filter { readableExtensions.contains($0.pathExtension.lowercased()) }
        if readable.isEmpty {
            TalkCore.shared.lastError = "Only .md and .txt files can be read."
            NSSound.beep()
            return
        }
        for (i, url) in readable.enumerated() {
            TalkCore.shared.speakFile(url, policy: i == 0 ? "interrupt" : "queue")
        }
    }

    // MARK: Finder

    /// Selected items in the frontmost Finder window (Automation permission).
    static func finderSelection() -> [URL] {
        let source = """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            if let error { TalkCore.shared.lastError = "Finder: \(error[NSAppleScript.errorMessage] ?? error)" }
            return []
        }
        return result.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    // MARK: Selected text

    /// Selected text of the focused element via Accessibility, falling back to
    /// a synthetic ⌘C (with the clipboard saved and restored) for apps that
    /// don't expose AXSelectedText (Electron apps, terminals, some web views).
    static func selectedText() -> String? {
        guard Permissions.accessibilityGranted(prompt: true) else { return nil }
        if let text = axSelectedText(), !text.isEmpty { return text }
        return copySelection()
    }

    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copySelection() -> String? {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        let before = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8 // ANSI "c"
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyC, keyDown: false)
        // only ⌘, even though ⌥⇧ may still be held from the hotkey
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // wait up to 300 ms for the app to put the selection on the clipboard
        let deadline = Date().addingTimeInterval(0.3)
        while pb.changeCount == before && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let text = pb.changeCount != before ? pb.string(forType: .string) : nil
        restorePasteboard(pb, saved)
        return text
    }

    private static func savePasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

// MARK: - Services (right-click → Services / Quick Actions)

/// Registered through NSServices in Info.plist.
final class ServiceProvider: NSObject {
    @objc func readText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else { return }
        Task { @MainActor in TalkCore.shared.speak(text, app: "service") }
    }

    @objc func readFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Task { @MainActor in Inputs.readFiles(urls) }
    }
}

// MARK: - Permissions

enum Permissions {
    static func accessibilityGranted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    enum Automation { case granted, denied, notAsked, finderNotRunning }

    /// Automation permission for Finder; `ask` shows the system prompt.
    static func finderAutomation(ask: Bool) -> Automation {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .finderNotRunning
        default: return .notAsked
        }
    }

    static func openSystemSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
