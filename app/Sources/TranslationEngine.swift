import AVFoundation
import Foundation
#if os(macOS)
import CoreAudio
import CoreGraphics
#endif
import Combine
import Translation
import Speech

// MARK: - Language models

struct SourceLanguage: Identifiable, Hashable, Sendable {
    let id: String    // SpeechAnalyzer locale, e.g. "en-US"
    let name: String
}

struct TargetLanguage: Identifiable, Hashable, Sendable {
    let id: String    // Translation.framework locale, e.g. "zh-Hant"
    let name: String
    var isInstalled: Bool
    var needsDownload: Bool { !isInstalled }
}

/// One ASR final segment paired with its (eventually arriving) translation.
/// Original and translated text share this single id so out-of-order or
/// dropped translations never misalign the two subtitle windows.
struct SubtitleLine: Identifiable, Sendable {
    let id: Int
    let original: String
    var translated: String?   // nil = still translating
}

/// Raw scroll-view geometry (from `onScrollGeometryChange`), exposed via the
/// DEBUG-only debug API so scroll-to-bottom behavior can be verified without
/// screen capture. `atBottom` uses a small tolerance for layout rounding.
struct ScrollMetrics: Equatable, Codable {
    var offsetY: Double = 0
    var containerHeight: Double = 0
    var contentHeight: Double = 0
    // Tolerance covers TranslationTextView's trailing `.padding(.vertical, 12)`,
    // which is always "missing" from a strict measurement even when scrolled
    // all the way to the last line of actual text (confirmed empirically:
    // the gap stays pinned at exactly 12pt regardless of content length).
    var atBottom: Bool { offsetY + containerHeight >= contentHeight - 14 }
}

// MARK: - Engine

@available(macOS 26.4, *)
@MainActor
final class TranslationEngine: ObservableObject {
    static let shared = TranslationEngine()

    // MARK: Language state

    let sourceLanguages: [SourceLanguage] = {
        let display = Locale.current
        return SFSpeechRecognizer.supportedLocales()
            .compactMap { locale -> SourceLanguage? in
                guard let name = display.localizedString(forIdentifier: locale.identifier) else { return nil }
                return SourceLanguage(id: locale.identifier, name: name)
            }
            .sorted { $0.name < $1.name }
    }()

    @Published var selectedSrcID: String = UserDefaults.standard.string(forKey: "jasub.selectedSrcID") ?? "en-US"
    @Published var targetLanguages: [TargetLanguage] = []
    @Published var selectedTgtID: String = UserDefaults.standard.string(forKey: "jasub.selectedTgtID") ?? "zh-Hant"
    @Published var isLoadingTargets: Bool = true
    @Published var srcUsageCounts: [String: Int] = UserDefaults.standard.dictionary(forKey: "jasub.srcUsageCounts") as? [String: Int] ?? [:]
    @Published var tgtUsageCounts: [String: Int] = UserDefaults.standard.dictionary(forKey: "jasub.tgtUsageCounts") as? [String: Int] ?? [:]
    @Published var highFidelityTranslation: Bool = UserDefaults.standard.object(forKey: "jasub.highFidelityTranslation") as? Bool ?? false
    @Published var translationFallbackActive: Bool = false

    var selectedSrc: SourceLanguage? { sourceLanguages.first(where: { $0.id == selectedSrcID }) }
    var selectedTgt: TargetLanguage? { targetLanguages.first(where: { $0.id == selectedTgtID }) }

    // MARK: Audio state (macOS only)

    #if os(macOS)
    static let systemAudioID = "__system_audio__"

    @Published var selectedDevice: String = UserDefaults.standard.string(forKey: "jasub.selectedDevice") ?? ""
    @Published var inputDevices: [AudioDevice] = []
    #endif

    // MARK: Subtitle content

    @Published var isRunning: Bool = false
    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0
    @Published var startError: String? = nil
    @Published var startupStatus: String? = nil
    @Published var isASRSilent: Bool = false
    @Published var allowUserScroll: Bool = UserDefaults.standard.object(forKey: "jasub.allowUserScroll") as? Bool ?? false {
        didSet { UserDefaults.standard.set(allowUserScroll, forKey: "jasub.allowUserScroll") }
    }
    @Published var showOriginal: Bool = UserDefaults.standard.object(forKey: "jasub.showOriginal") as? Bool ?? true
    @Published var showTranslation: Bool = UserDefaults.standard.object(forKey: "jasub.showTranslation") as? Bool ?? true
    @Published var saveTranscript: Bool = false {
        didSet { UserDefaults.standard.set(saveTranscript, forKey: "jasub.saveTranscript") }
    }
    @Published var diagnosticLogging: Bool = false {
        didSet {
            UserDefaults.standard.set(diagnosticLogging, forKey: "jasub.diagnosticLogging")
            DiagnosticLog.shared.isEnabled = diagnosticLogging
        }
    }
    @Published var translationFontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "jasub.translationFontSize")
        return saved >= 12 ? CGFloat(saved) : 20
    }()
    @Published var terminologyGlossaryText: String = UserDefaults.standard.string(forKey: "jasub.terminologyGlossaryText") ?? "" {
        didSet {
            UserDefaults.standard.set(terminologyGlossaryText, forKey: "jasub.terminologyGlossaryText")
            terminologyCorrector.glossary = terminologyGlossaryText.components(separatedBy: .newlines)
        }
    }
    @Published var originalPartial: String = ""
    @Published var originalScrollMetrics = ScrollMetrics()
    @Published var translationScrollMetrics = ScrollMetrics()
    @Published var subtitleLines: [SubtitleLine] = []

    // MARK: Private

    private static let allTargetIDs: [String] = [
        "zh-TW", "zh-HK", "zh-CN", "en-US", "ja-JP", "ko-KR",
        "fr-FR", "de-DE", "es-ES", "pt-BR", "it-IT",
        "ar-AE", "ru-RU", "nl-NL", "pl-PL", "th-TH", "tr-TR", "uk-UA", "vi-VN", "id-ID",
    ]

    private static func systemDefaultTargetLanguage() -> String {
        for preferred in Locale.preferredLanguages {
            let locale = Locale(identifier: preferred)
            guard let langCode = locale.language.languageCode?.identifier else { continue }
            let region = locale.region?.identifier ?? ""
            let script = locale.language.script?.identifier ?? ""
            if langCode == "zh" {
                if region == "HK" { return "zh-HK" }
                if script == "Hant" || region == "TW" || region == "MO" { return "zh-TW" }
                return "zh-CN"
            }
            let candidate = "\(langCode)-\(region)"
            if allTargetIDs.contains(candidate) { return candidate }
            if let match = allTargetIDs.first(where: { $0.hasPrefix(langCode + "-") }) { return match }
        }
        return "zh-Hant"
    }

    private var importFileURL: URL?
    private var cancellables = Set<AnyCancellable>()
    private var lastASRActivity: Date = .distantPast
    private var silenceTimer: Timer?
    private var nextLineID = 0

    // MARK: Pipeline

    private var audioEngine: AudioEngine?
    private var asrManager: ASRManager?
    private var translatorManager: TranslatorManager?
    private var sampleStreamContinuation: AsyncStream<[Float]>.Continuation?
    private var pipelineTask: Task<Void, Never>?
    private var hallucinationFilter = HallucinationFilter()
    private var terminologyCorrector = TerminologyCorrector(
        glossary: (UserDefaults.standard.string(forKey: "jasub.terminologyGlossaryText") ?? "")
            .components(separatedBy: .newlines)
    )

    // MARK: Logging

    @Published var currentLogURL: URL? = nil
    private var logFileHandle: FileHandle?

    // MARK: Init

    private init() {
        #if os(macOS)
        refreshDevices()
        #endif

        if UserDefaults.standard.string(forKey: "jasub.selectedTgtID") == nil {
            selectedTgtID = Self.systemDefaultTargetLanguage()
        }

        saveTranscript = UserDefaults.standard.bool(forKey: "jasub.saveTranscript")

        let savedDiagnostic = UserDefaults.standard.bool(forKey: "jasub.diagnosticLogging")
        diagnosticLogging = savedDiagnostic
        DiagnosticLog.shared.isEnabled = savedDiagnostic

        $showOriginal
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "jasub.showOriginal") }
            .store(in: &cancellables)

        $showTranslation
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "jasub.showTranslation") }
            .store(in: &cancellables)

        $translationFontSize
            .dropFirst()
            .sink { size in UserDefaults.standard.set(Double(size), forKey: "jasub.translationFontSize") }
            .store(in: &cancellables)

        $selectedSrcID
            .dropFirst()
            .sink { [weak self] srcID in
                UserDefaults.standard.set(srcID, forKey: "jasub.selectedSrcID")
                guard let self else { return }
                Task { await self.refreshTargets(for: srcID) }
            }
            .store(in: &cancellables)

        $selectedTgtID
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "jasub.selectedTgtID") }
            .store(in: &cancellables)

        $selectedDevice
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "jasub.selectedDevice") }
            .store(in: &cancellables)

        $highFidelityTranslation
            .dropFirst()
            .sink { [weak self] value in
                UserDefaults.standard.set(value, forKey: "jasub.highFidelityTranslation")
                if !value { self?.translationFallbackActive = false }
            }
            .store(in: &cancellables)

        Task { await refreshTargets(for: selectedSrcID) }
    }

    // MARK: Target language refresh

    func refreshTargets(for srcID: String) async {
        isLoadingTargets = true
        defer { isLoadingTargets = false }

        let availability = LanguageAvailability()
        let srcLang = Locale.Language(identifier: srcID)
        let srcBase = String(srcID.prefix(2))

        let display = Locale.current
        var targets: [TargetLanguage] = []
        for tgtID in Self.allTargetIDs {
            let tgtBase = String(tgtID.prefix(2))
            if srcBase == tgtBase && srcBase != "zh" { continue }
            if srcID == tgtID { continue }

            let tgtLang = Locale.Language(identifier: tgtID)
            let status = await availability.status(from: srcLang, to: tgtLang)
            guard status != .unsupported else { continue }

            let name = display.localizedString(forIdentifier: tgtID) ?? tgtID
            targets.append(TargetLanguage(
                id: tgtID, name: name,
                isInstalled: status == .installed
            ))
        }

        // Simulator / no-model fallback: LanguageAvailability returns .unsupported for everything
        if targets.isEmpty {
            for tgtID in Self.allTargetIDs {
                let tgtBase = String(tgtID.prefix(2))
                if srcBase == tgtBase && srcBase != "zh" { continue }
                if srcID == tgtID { continue }
                let name = display.localizedString(forIdentifier: tgtID) ?? tgtID
                targets.append(TargetLanguage(id: tgtID, name: name, isInstalled: false))
            }
        }

        targetLanguages = targets.sorted {
            if $0.isInstalled != $1.isInstalled { return $0.isInstalled }
            return $0.name < $1.name
        }

        if !targets.contains(where: { $0.id == selectedTgtID }) {
            selectedTgtID = targets.first(where: { $0.isInstalled })?.id ?? targets.first?.id ?? ""
        }
    }

    // MARK: Audio device enumeration (macOS only)

    #if os(macOS)
    struct AudioDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        var isDefault: Bool = false
    }

    func refreshDevices() {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize
        ) == noErr else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return }

        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID: AudioDeviceID = 0
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &defaultSize, &defaultID
        )

        var result: [AudioDevice] = []
        for id in deviceIDs {
            var channelAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var channelSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &channelAddr, 0, nil, &channelSize) == noErr,
                  channelSize >= MemoryLayout<AudioBufferList>.size else { continue }

            // Read the actual AudioBufferList and count input channels.
            // channelSize > 0 alone is insufficient — output-only devices (e.g. eqMac speaker)
            // return a non-zero property size but with mNumberChannels = 0.
            let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(channelSize))
            defer { abl.deallocate() }
            var ablSize = channelSize
            guard AudioObjectGetPropertyData(id, &channelAddr, 0, nil, &ablSize, abl) == noErr else { continue }
            let totalChannels = UnsafeMutableAudioBufferListPointer(abl)
                .reduce(0) { $0 + Int($1.mNumberChannels) }
            guard totalChannels > 0 else { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(
                id, &nameAddr, 0, nil, &nameSize, &nameRef
            ) == noErr, let name = nameRef?.takeRetainedValue() as String? else { continue }

            result.append(AudioDevice(id: id, name: name, isDefault: id == defaultID))
        }

        inputDevices = result.sorted { $0.isDefault && !$1.isDefault }
        if selectedDevice.isEmpty || (!result.contains(where: { $0.name == selectedDevice }) && selectedDevice != Self.systemAudioID) {
            selectedDevice = result.first(where: { $0.isDefault })?.name ?? result.first?.name ?? ""
        }
    }
    #endif

    // MARK: Start / Stop

    func importFromFile(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        importFileURL = url
        start(fileURL: url)
    }

    func start(fileURL: URL? = nil) {
        guard !isRunning else { return }
        startError = nil
        srcUsageCounts[selectedSrcID, default: 0] += 1
        tgtUsageCounts[selectedTgtID, default: 0] += 1
        UserDefaults.standard.set(srcUsageCounts, forKey: "jasub.srcUsageCounts")
        UserDefaults.standard.set(tgtUsageCounts, forKey: "jasub.tgtUsageCounts")

        // Check 1: macOS 26.4+
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        guard osVer.majorVersion > 26 || (osVer.majorVersion == 26 && osVer.minorVersion >= 4) else {
            DiagnosticLog.shared.log("[FAIL] macOS version \(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion) — requires 26.4+")
            startError = String(format: NSLocalizedString("error.macOSVersion",
                value: "JaSub requires macOS 26.4 or later (current: %@).",
                comment: ""), "\(osVer.majorVersion).\(osVer.minorVersion)")
            return
        }

        isRunning = true
        isImporting = fileURL != nil
        importProgress = 0
        isASRSilent = false
        lastASRActivity = .now
        originalPartial = ""
        subtitleLines = []
        nextLineID = 0
        hallucinationFilter = HallucinationFilter()
        if saveTranscript { startSessionLog() }
        #if os(macOS)
        let deviceLabel = selectedDevice == Self.systemAudioID ? "system-audio" : (selectedDevice.isEmpty ? "default" : selectedDevice)
        #else
        let deviceLabel = "mic"
        #endif
        DiagnosticLog.shared.sessionHeader(
            osVersion: "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)",
            src: selectedSrcID, tgt: selectedTgtID, device: deviceLabel
        )
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.isASRSilent = Date.now.timeIntervalSince(self.lastASRActivity) > 4.0
            }
        }

        let srcLocaleID = selectedSrcID
        let tgtID       = selectedTgtID
        let translSrc   = translationSrcCode(for: srcLocaleID)
        let capturedHighFidelity: Bool = highFidelityTranslation

        #if os(macOS)
        let isSystemAudio = selectedDevice == Self.systemAudioID
        let deviceID = isSystemAudio ? nil : inputDevices.first(where: { $0.name == selectedDevice })?.id

        if isSystemAudio && !CGPreflightScreenCaptureAccess() {
            DiagnosticLog.shared.log("[FAIL] screen recording permission not granted")
            CGRequestScreenCaptureAccess()
            isRunning = false
            startError = NSLocalizedString("error.screenCapture",
                value: "JaSub requires Screen Recording permission to capture system audio. Please grant it in System Settings → Privacy & Security → Screen Recording, then click Start again.\n\nUpgrading? Remove the JaSub entry from Screen Recording, relaunch JaSub, grant permission when prompted, then relaunch once more when macOS asks you to.",
                comment: "")
            return
        }
        #endif

        let (sampleStream, continuation) = AsyncStream<[Float]>.makeStream()
        sampleStreamContinuation = continuation

        let engine     = AudioEngine()
        audioEngine    = engine
        let asr        = ASRManager()
        asrManager     = asr
        let translator = TranslatorManager()
        translatorManager = translator

        let capturedFileURL = fileURL
        pipelineTask = Task { [weak self] in

            // Check 2: Microphone permission (macOS, mic input only)
            #if os(macOS)
            if !isSystemAudio {
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                switch micStatus {
                case .notDetermined:
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    if !granted {
                        DiagnosticLog.shared.log("[FAIL] mic permission denied by user")
                        Task { @MainActor [weak self] in
                            self?.isRunning = false
                            self?.startupStatus = nil
                            self?.startError = NSLocalizedString("error.micPermissionDenied",
                                value: "JaSub requires microphone access. Please enable it in System Settings → Privacy & Security → Microphone, then try again.",
                                comment: "")
                        }
                        return
                    }
                    DiagnosticLog.shared.log("[OK] mic permission granted")
                case .denied, .restricted:
                    DiagnosticLog.shared.log("[FAIL] mic permission denied/restricted (status=\(micStatus.rawValue))")
                    Task { @MainActor [weak self] in
                        self?.isRunning = false
                        self?.startupStatus = nil
                        self?.startError = NSLocalizedString("error.micPermissionRestricted",
                            value: "Microphone access was denied. Please allow JaSub in System Settings → Privacy & Security → Microphone, then try again.",
                            comment: "")
                    }
                    return
                default:
                    DiagnosticLog.shared.log("[OK] mic permission already authorized")
                }
            }
            #endif

            // Check 3: Translation language pack
            // Check 4: ASR model
            let tgtInstalled = await MainActor.run { self?.selectedTgt?.isInstalled ?? true }
            let srcLocale = Locale(identifier: srcLocaleID)
            let asrInstalled = await SpeechTranscriber.installedLocales.contains(srcLocale)
            DiagnosticLog.shared.log("[CHECK] tgtInstalled=\(tgtInstalled) asrInstalled=\(asrInstalled)")

            var statusParts: [String] = []
            if !asrInstalled {
                statusParts.append(NSLocalizedString("startup.asrModelMissing",
                    value: "Speech model will download on first use",
                    comment: ""))
            }
            if !tgtInstalled {
                statusParts.append(NSLocalizedString("startup.translationPackMissing",
                    value: "Translation pack not installed — Apple Intelligence will be used (slower)",
                    comment: ""))
            }
            let initialStatus = statusParts.isEmpty
                ? NSLocalizedString("startup.preparingTranslation", value: "Preparing translation engine…", comment: "")
                : statusParts.joined(separator: " · ") + "…"
            await MainActor.run { self?.startupStatus = initialStatus }

            await translator.prepare()

            await asr.setOnPartial { [weak self] text in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastASRActivity = .now
                    self.isASRSilent = false
                    self.originalPartial = self.terminologyCorrector.correct(text)
                }
            }

            await asr.setOnFinal { [weak self] rawText in
                Task {
                    let line: (id: Int, text: String)? = await MainActor.run { () -> (id: Int, text: String)? in
                        guard let self else { return nil }
                        self.lastASRActivity = .now
                        self.isASRSilent = false
                        let text = self.terminologyCorrector.correct(rawText)
                        guard !self.hallucinationFilter.isHallucination(text) else { return nil }
                        if self.hallucinationFilter.isDuplicateAndRecord(text) { return nil }
                        self.originalPartial = ""
                        let id = self.nextLineID
                        self.nextLineID += 1
                        self.subtitleLines.append(SubtitleLine(id: id, original: text, translated: nil))
                        if self.subtitleLines.count > 20 { self.subtitleLines.removeFirst() }
                        self.logFileHandle?.seekToEndOfFile()
                        if let data = (text + "\n").data(using: .utf8) {
                            self.logFileHandle?.write(data)
                        }
                        return (id, text)
                    }
                    guard let (lineID, text) = line else { return }

                    let strategy: TranslationSession.Strategy = capturedHighFidelity ? .highFidelity : .lowLatency
                    let (translated, usedFallback) = await translator.translate(text, from: translSrc, to: tgtID, strategy: strategy)
                    let overridden = await MainActor.run { [weak self] in
                        self?.terminologyCorrector.applyTranslationOverrides(to: translated) ?? translated
                    }
                    let result = overridden.isEmpty ? "⚠️ \(text)" : overridden
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard let idx = self.subtitleLines.firstIndex(where: { $0.id == lineID }) else { return }
                        self.subtitleLines[idx].translated = result
                        if capturedHighFidelity {
                            self.translationFallbackActive = usedFallback
                        }
                    }
                }
            }

            await MainActor.run { self?.startupStatus = NSLocalizedString("startup.startingAudio", value: "Starting audio capture…", comment: "") }
            do {
                #if os(macOS)
                if isSystemAudio {
                    try engine.startSystemAudio(continuation: continuation)
                } else {
                    try engine.start(deviceID: deviceID, continuation: continuation)
                }
                #else
                if let url = capturedFileURL {
                    try engine.startFromFile(url, onProgress: { [weak self] p in
                        Task { @MainActor [weak self] in self?.importProgress = p }
                    }, continuation: continuation)
                } else {
                    try engine.start(continuation: continuation)
                }
                #endif
            } catch {
                DiagnosticLog.shared.log("[FAIL] audio engine: \(error)")
                Task { @MainActor [weak self] in
                    self?.isRunning = false
                    self?.startupStatus = nil
                    self?.startError = error.localizedDescription
                }
                return
            }
            DiagnosticLog.shared.log("[OK] audio engine started")

            do {
                try await asr.start(
                    sampleStream: sampleStream,
                    locale: Locale(identifier: srcLocaleID),
                    onStatus: { [weak self] msg in
                        Task { @MainActor [weak self] in self?.startupStatus = msg }
                    }
                )
            } catch {
                DiagnosticLog.shared.log("[FAIL] ASR: \(error)")
                Task { @MainActor [weak self] in
                    self?.isRunning = false
                    self?.startupStatus = nil
                    self?.startError = error.localizedDescription
                }
                return
            }
            DiagnosticLog.shared.log("[OK] ASR started — pipeline running")
            await MainActor.run { self?.startupStatus = nil }

            // File import finished — auto-stop and save transcript
            if capturedFileURL != nil {
                await MainActor.run { self?.stop() }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        DiagnosticLog.shared.log("[STOP] session ended by user")
        isRunning = false
        startupStatus = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        isASRSilent = false

        audioEngine?.stop()
        audioEngine = nil

        sampleStreamContinuation?.finish()
        sampleStreamContinuation = nil

        pipelineTask?.cancel()
        pipelineTask = nil

        let asr = asrManager
        asrManager        = nil
        translatorManager = nil
        Task { await asr?.stop() }

        logFileHandle?.closeFile()
        logFileHandle = nil
        currentLogURL = nil

        importFileURL?.stopAccessingSecurityScopedResource()
        importFileURL = nil
        isImporting = false
        importProgress = 0
    }

    // MARK: Logging

    private func startSessionLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("JaSub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm"
        let url = dir.appendingPathComponent("\(fmt.string(from: .now)).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logFileHandle = try? FileHandle(forWritingTo: url)
        currentLogURL = url
    }

    // MARK: Helpers

    private func translationSrcCode(for asrLocaleID: String) -> String {
        asrLocaleID  // ASR locales (e.g. "en-US", "ja-JP") are already valid Translation identifiers
    }
}
