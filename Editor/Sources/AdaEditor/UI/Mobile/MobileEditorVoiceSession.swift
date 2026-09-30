#if os(iOS)
import AVFAudio
import Foundation
import NaturalLanguage
import Observation
import UIKit

@MainActor
@Observable
final class MobileEditorVoiceSession: NSObject, AVSpeechSynthesizerDelegate {
    let dictation = MobileEditorPromptDictation()
    private(set) var isSpeaking = false
    private(set) var errorMessage: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var backgroundObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func listen(initialText: String, onTranscript: @escaping @MainActor (String) -> Void) {
        stopSpeaking()
        errorMessage = nil
        dictation.start(initialText: initialText, onTranscript: onTranscript)
    }

    func speak(_ text: String) {
        dictation.stop()
        stopSpeaking()
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try audio.setActive(true)
            let utterance = AVSpeechUtterance(string: text)
            // Let the system choose a voice appropriate to the response language.
            utterance.voice = AVSpeechSynthesisVoice(language: language(for: text))
            isSpeaking = true
            synthesizer.speak(utterance)
            backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
        } catch {
            errorMessage = error.localizedDescription
            stopSpeaking()
        }
    }

    func stop() {
        dictation.stop()
        stopSpeaking()
    }

    private func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        finishSpeaking()
    }

    private func finishSpeaking() {
        guard isSpeaking else {
            return
        }
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        backgroundObserver = nil
        interruptionObserver = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synthesizer.isSpeaking else {
                return
            }
            self.finishSpeaking()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synthesizer.isSpeaking else {
                return
            }
            self.finishSpeaking()
        }
    }

    private func language(for text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? AVSpeechSynthesisVoice.currentLanguageCode()
    }
}
#endif
