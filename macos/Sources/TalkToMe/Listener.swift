import AVFoundation
import Foundation
import Speech

/// Listens for "yes" or "no" during a briefing's answer window, with Apple's
/// on-device speech recognition. The microphone opens only for the window,
/// which starts after the question has been spoken, so it never hears the
/// app's own voice.
@MainActor
final class Listener {
    static let shared = Listener()

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var answered = false

    var isListening: Bool { task != nil }

    static func speechAuthorized() -> Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static func micAuthorized() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestPermissions(_ done: @escaping @MainActor (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                Task { @MainActor in done(status == .authorized && mic) }
            }
        }
    }

    /// Start listening for up to `seconds`; calls `onAnswer(true/false)` on a
    /// match. Silence or anything else ends without an answer.
    func listen(seconds: Int, yes: [String], no: [String], onAnswer: @escaping @MainActor (Bool) -> Void) {
        stop()
        guard Self.speechAuthorized(), Self.micAuthorized(),
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.contextualStrings = yes + no
        req.taskHint = .confirmation
        request = req
        answered = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            stop()
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let result else { return }
            let heard = result.bestTranscription.formattedString
            Task { @MainActor in
                guard let self, !self.answered else { return }
                if let verdict = Self.match(heard, yes: yes, no: no) {
                    self.answered = true
                    self.stop()
                    onAnswer(verdict)
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    /// Whole-word match; "no" words win when both appear ("no, don't read it").
    static func match(_ heard: String, yes: [String], no: [String]) -> Bool? {
        let text = " " + heard.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
        func has(_ phrase: String) -> Bool {
            let p = phrase.lowercased().trimmingCharacters(in: .whitespaces)
            return !p.isEmpty && text.contains(" \(p) ")
        }
        if no.contains(where: has) { return false }
        if yes.contains(where: has) { return true }
        return nil
    }
}
