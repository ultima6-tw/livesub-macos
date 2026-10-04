import AVFoundation
import CoreAudio
import Combine

/// Timestamps for one sentence, used to measure how long the listener waits for the translation.
struct LatencyTrace: Sendable {
    let firstPartialAt: Date?   // first partial of this sentence ≈ when the speaker started
    let finalAt: Date           // ASR final (sentence end as seen by ASR)
    let translatedAt: Date      // translation finished
}

/// Reads translations aloud through headphones.
/// Hard rule: only speaks while the default output device is a headphone-type device
/// (Bluetooth / USB / built-in headphone jack). Speakers, HDMI, AirPlay etc. stay silent.
@MainActor
final class SpeechOutputManager: NSObject, ObservableObject {
    static let shared = SpeechOutputManager()

    private static let enabledKey = "jasub.speakToHeadphones"
    private static let maxQueue = 1
    private static let headphoneDataSource: UInt32 = 0x6864706E   // 'hdpn'

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: SpeechOutputManager.enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { stopAll() }
        }
    }
    @Published private(set) var headphonesConnected = false
    /// "last 1234 ms · avg 1500 ms after sentence end (translate 300 · TTS 200)"
    @Published private(set) var latencyInfo = ""

    private struct Item { let utterance: AVSpeechUtterance; let trace: LatencyTrace }
    private let synthesizer = AVSpeechSynthesizer()
    private var pending: [Item] = []
    private var inFlight: [ObjectIdentifier: LatencyTrace] = [:]
    private var recentAfterEnd: [Double] = []

    private var dataSourceDevice: AudioObjectID = 0
    private var dataSourceListener: AudioObjectPropertyListenerBlock?

    private override init() {
        super.init()
        synthesizer.delegate = self
        headphonesConnected = Self.outputIsHeadphones()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.routeChanged() }
        }
        installDataSourceListener()
    }

    // MARK: Speaking

    func speak(_ text: String, languageID: String, trace: LatencyTrace) {
        guard isEnabled, Self.outputIsHeadphones() else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: languageID)
        pending.append(Item(utterance: utterance, trace: trace))
        while pending.count > Self.maxQueue {
            let dropped = pending.removeFirst()
            DiagnosticLog.shared.log("[TTS] dropped (queue>\(Self.maxQueue)): \(dropped.utterance.speechString.prefix(30))")
        }
        drain()
    }

    func stopAll() {
        pending.removeAll()
        inFlight.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func drain() {
        guard !synthesizer.isSpeaking, Self.outputIsHeadphones(), !pending.isEmpty else { return }
        let item = pending.removeFirst()
        inFlight[ObjectIdentifier(item.utterance)] = item.trace
        synthesizer.speak(item.utterance)
    }

    // MARK: Latency

    fileprivate func recordStart(_ id: ObjectIdentifier) {
        guard let t = inFlight[id] else { return }
        let now = Date()
        func ms(_ a: Date, _ b: Date) -> Int { Int((b.timeIntervalSince(a) * 1000).rounded()) }
        let afterEnd = ms(t.finalAt, now)
        let translate = ms(t.finalAt, t.translatedAt)
        let tts = ms(t.translatedAt, now)
        let sentence = t.firstPartialAt.map { ms($0, t.finalAt) }
        let fromStart = t.firstPartialAt.map { ms($0, now) }
        recentAfterEnd.append(Double(afterEnd))
        if recentAfterEnd.count > 20 { recentAfterEnd.removeFirst() }
        let avg = Int((recentAfterEnd.reduce(0, +) / Double(recentAfterEnd.count)).rounded())
        latencyInfo = "last \(afterEnd) ms · avg \(avg) ms after sentence end (translate \(translate) · TTS \(tts))"
        DiagnosticLog.shared.log("[TTS] start: afterEnd=\(afterEnd)ms translate=\(translate)ms tts=\(tts)ms "
            + "sentence=\(sentence.map(String.init) ?? "n/a")ms fromFirstPartial=\(fromStart.map(String.init) ?? "n/a")ms")
    }

    // MARK: Route handling

    private func routeChanged() {
        headphonesConnected = Self.outputIsHeadphones()
        DiagnosticLog.shared.log("[TTS] output route changed — headphones=\(headphonesConnected)")
        if !headphonesConnected { stopAll() }   // unplugged / switched to speaker: stop at once
        installDataSourceListener()
    }

    /// Built-in output switches speaker↔headphone jack via its data source, not the default device.
    private func installDataSourceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if let old = dataSourceListener, dataSourceDevice != 0 {
            AudioObjectRemovePropertyListenerBlock(dataSourceDevice, &addr, .main, old)
        }
        dataSourceListener = nil
        dataSourceDevice = 0
        guard let dev = Self.defaultOutputDevice() else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.routeChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(dev, &addr, .main, block) == noErr {
            dataSourceDevice = dev
            dataSourceListener = block
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return (st == noErr && dev != 0) ? dev : nil
    }

    private static func uint32Property(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                       scope: AudioObjectPropertyScope) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Whitelist only: anything unknown (speaker, HDMI, AirPlay, virtual…) counts as "not headphones".
    static func outputIsHeadphones() -> Bool {
        guard let dev = defaultOutputDevice(),
              let transport = uint32Property(dev, kAudioDevicePropertyTransportType,
                                             scope: kAudioObjectPropertyScopeGlobal) else { return false }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            return uint32Property(dev, kAudioDevicePropertyDataSource,
                                  scope: kAudioObjectPropertyScopeOutput) == headphoneDataSource
        default:
            return false
        }
    }

    // MARK: Voice selection

    /// Empty string = Automatic (system default voice for the language).
    static func voiceDefaultsKey(for languageID: String) -> String { "jasub.ttsVoice.\(mapLanguage(languageID))" }

    private static func mapLanguage(_ languageID: String) -> String {
        switch languageID {
        case "zh-Hant": return "zh-TW"
        case "zh-Hans": return "zh-CN"
        default: return languageID
        }
    }

    struct VoiceOption: Identifiable {
        let id: String      // AVSpeechSynthesisVoice.identifier
        let label: String   // "Name · Premium"
    }

    /// Installed voices matching the target language (exact locale first, else same base language).
    static func voiceOptions(for languageID: String) -> [VoiceOption] {
        let mapped = mapLanguage(languageID)
        let all = AVSpeechSynthesisVoice.speechVoices()
        var matches = all.filter { $0.language == mapped }
        if matches.isEmpty { matches = all.filter { $0.language.hasPrefix(String(mapped.prefix(2))) } }
        return matches
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { v in
                let q: String
                switch v.quality {
                case .premium: q = "Premium"
                case .enhanced: q = "Enhanced"
                default: q = "Default"
                }
                return VoiceOption(id: v.identifier, label: "\(v.name) · \(q)")
            }
    }

    static func selectedVoiceID(for languageID: String) -> String {
        UserDefaults.standard.string(forKey: voiceDefaultsKey(for: languageID)) ?? ""
    }

    static func setSelectedVoiceID(_ id: String, for languageID: String) {
        UserDefaults.standard.set(id, forKey: voiceDefaultsKey(for: languageID))
    }

    /// Speaks a short sample with the voice currently chosen for `languageID` (ignores headphone gate; user-initiated).
    func preview(languageID: String) {
        synthesizer.stopSpeaking(at: .immediate)
        pending.removeAll()
        let u = AVSpeechUtterance(string: Self.sampleText(for: languageID))
        u.voice = Self.voice(for: languageID)
        synthesizer.speak(u)
    }

    private static func sampleText(for languageID: String) -> String {
        switch mapLanguage(languageID).prefix(2) {
        case "zh": return "這是語音試聽，您可以聽聽看這個聲音。"
        case "ja": return "これは音声のテストです。"
        case "ko": return "음성 미리듣기입니다."
        default: return "This is a voice preview."
        }
    }

    private static func voice(for languageID: String) -> AVSpeechSynthesisVoice? {
        let saved = selectedVoiceID(for: languageID)
        if !saved.isEmpty, let v = AVSpeechSynthesisVoice(identifier: saved) { return v }   // missing → Automatic
        let mapped = mapLanguage(languageID)
        if let exact = AVSpeechSynthesisVoice(language: mapped) { return exact }
        let base = String(mapped.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(base) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }
}

extension SpeechOutputManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.recordStart(id) }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in
            self.inFlight[id] = nil
            self.drain()
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.inFlight[id] = nil }
    }
}
