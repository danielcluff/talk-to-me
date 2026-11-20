import AVFoundation
import CTalk
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

    /// Record `seconds` of 16 kHz mono audio for a local recognizer, then
    /// hand it to the core (talk_answer_audio), which transcribes and answers.
    func record(seconds: Int, onDone: @escaping @MainActor (String?) -> Void) {
        stop()
        guard Self.micAuthorized() else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return }
        let collected = SampleBuffer()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let ch = out.floatChannelData?[0] {
                collected.append(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            stop()
            return
        }
        recording = true
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.stop()
                let samples = collected.take()
                let heard: String? = await Task.detached {
                    guard !samples.isEmpty else { return nil }
                    let reply = samples.withUnsafeBufferPointer { talk_answer_audio($0.baseAddress, $0.count, 16000) }
                    guard let reply else { return nil }
                    defer { talk_free(reply) }
                    return String(cString: reply)
                }.value
                onDone(heard)
            }
        }
    }

    private var recording = false

    func stop() {
        recording = false
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

/// Samples collected on the audio thread, read once on the main actor.
final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }
}
