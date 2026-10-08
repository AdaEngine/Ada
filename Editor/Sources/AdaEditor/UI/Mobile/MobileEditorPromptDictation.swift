#if os(iOS)
import AVFAudio
import Foundation
import Observation
import Speech
import UIKit

@Observable
@MainActor
final class MobileEditorPromptDictation {
    private(set) var isStarting = false
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0
    private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var audioSink: MobileEditorDictationAudioSink?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var startTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var hasAudioTap = false
    private var hasAudioSession = false
    private var interruptionObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    func start(initialText: String = "", onTranscript: @escaping @MainActor (String) -> Void) {
        stop()
        errorMessage = nil
        isStarting = true
        let id = sessionID
        startTask = Task { @MainActor [weak self] in
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status)
                }
            }
            guard let self, !Task.isCancelled, self.sessionID == id else {
                return
            }
            guard authorization == .authorized else {
                self.fail("Allow Speech Recognition in Settings to dictate a prompt.")
                return
            }
            let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled, self.sessionID == id else {
                return
            }
            guard microphoneAllowed else {
                self.fail("Allow Microphone access in Settings to dictate a prompt.")
                return
            }
            do {
                try self.beginRecognition(id: id) { transcript in
                    onTranscript(initialText.isEmpty ? transcript : initialText + " " + transcript)
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        sessionID = UUID()
        startTask?.cancel()
        startTask = nil
        audioEngine.stop()
        if hasAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }
        audioSink?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        audioSink = nil
        recognizer = nil
        if hasAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            hasAudioSession = false
        }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        interruptionObserver = nil
        backgroundObserver = nil
        isStarting = false
        isRecording = false
        audioLevel = 0
    }

    private func beginRecognition(id: UUID, onTranscript: @escaping @MainActor (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: .autoupdatingCurrent), recognizer.isAvailable else {
            fail("Speech recognition is unavailable. Try again later.")
            return
        }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true)
        hasAudioSession = true

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("The microphone is unavailable on this device.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.recognizer = recognizer
        let sink = MobileEditorDictationAudioSink(request: request)
        audioSink = sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            let level = sink.append(buffer)
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else {
                    return
                }
                self.audioLevel = level
            }
        }
        hasAudioTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else {
                    return
                }
                if let transcript { onTranscript(transcript) }
                if let errorMessage {
                    self.fail(errorMessage)
                } else if isFinal {
                    self.stop()
                }
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        isStarting = false
        isRecording = true
        interruptionObserver = stopOnNotification(AVAudioSession.interruptionNotification)
        backgroundObserver = stopOnNotification(UIApplication.willResignActiveNotification)
    }

    private func stopOnNotification(_ name: Notification.Name) -> NSObjectProtocol {
        let id = sessionID
        return NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else {
                    return
                }
                self.stop()
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        errorMessage = message
    }
}

/// Speech receives buffers on the audio queue. The lock serializes all app-side
/// request mutations with MainActor teardown; buffers never cross a task boundary.
private final class MobileEditorDictationAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) -> Float {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
        // AVAudioEngine keeps this channel memory alive for the tap callback.
        guard let samples = unsafe buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return 0
        }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += unsafe samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return rms.isFinite ? min(max(rms * 8, 0), 1) : 0
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = nil
    }
}
#endif
