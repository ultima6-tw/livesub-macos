@preconcurrency import AVFoundation
import Speech

/// Wraps SpeechAnalyzer + SpeechTranscriber (or DictationTranscriber when a
/// content domain supplies contextual strings).
/// Feed 16 kHz mono float32 samples via the sampleStream; receive
/// transcription results through onPartial / onFinal callbacks.
@available(macOS 26.0, iOS 26.0, *)
actor ASRManager {

    var onPartial: @Sendable (String) -> Void = { _ in }
    var onFinal:   @Sendable (String) -> Void = { _ in }

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerTask: Task<Void, Error>?
    private var resultsTask:  Task<Void, Error>?
    private var forwardTask:  Task<Void, Never>?

    // Converter from 16 kHz → analyzerFormat (nil if same)
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!

    func setOnPartial(_ cb: @escaping @Sendable (String) -> Void) { onPartial = cb }
    func setOnFinal(_ cb: @escaping @Sendable (String) -> Void)   { onFinal   = cb }

    /// Upper bound on contextual strings per Apple's AnalysisContext docs
    /// ("total number of phrases across all tags must not exceed 100").
    static let maxContextualStrings = 100

    /// Starts recognition and returns a short label of the engine actually used.
    /// With `contextualStrings` non-empty (a content domain is selected) uses
    /// DictationTranscriber biased with those terms — SpeechTranscriber ignores
    /// contextual strings. Falls back to SpeechTranscriber if the locale isn't
    /// supported by DictationTranscriber.
    func start(sampleStream: AsyncStream<[Float]>, locale: Locale,
               contextualStrings: [String] = [],
               onStatus: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let onPartial = self.onPartial
        let onFinal   = self.onFinal

        var dictationLocale: Locale?
        if !contextualStrings.isEmpty {
            dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        }

        let module: any SpeechModule
        let installedLocales: [Locale]
        let engineLabel: String
        let resultsReader: @Sendable () async throws -> Void
        var context: AnalysisContext?

        if let dictationLocale {
            let transcriber = DictationTranscriber(locale: dictationLocale, preset: .progressiveLongDictation)
            module = transcriber
            installedLocales = await DictationTranscriber.installedLocales
            let terms = Array(contextualStrings.prefix(Self.maxContextualStrings))
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = terms
            context = ctx
            engineLabel = "DictationTranscriber (\(terms.count) terms)"
            resultsReader = {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 2 else { continue }
                    if result.isFinal { onFinal(text) } else { onPartial(text) }
                }
            }
        } else {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            module = transcriber
            installedLocales = await SpeechTranscriber.installedLocales
            engineLabel = contextualStrings.isEmpty
                ? "SpeechTranscriber"
                : "SpeechTranscriber (DictationTranscriber unsupported for \(locale.identifier))"
            resultsReader = {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.count >= 2 else { continue }
                    if result.isFinal { onFinal(text) } else { onPartial(text) }
                }
            }
        }
        let modules: [any SpeechModule] = [module]

        // Download ASR model if not installed
        if !installedLocales.contains(dictationLocale ?? locale) {
            onStatus?(NSLocalizedString("startup.downloadingASR", value: "Downloading speech recognition model, please wait…", comment: ""))
            if let req = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await req.downloadAndInstall()
            }
        }
        onStatus?(NSLocalizedString("startup.initializingASR", value: "Initializing speech recognition engine…", comment: ""))

        let analyzer = SpeechAnalyzer(modules: modules)
        if let context {
            try await analyzer.setContext(context)
        }

        guard let aFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw NSError(domain: "ASR", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible audio format"])
        }
        analyzerFormat = aFmt
        converter = aFmt == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: aFmt)

        let (analyzerStream, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = analyzerContinuation

        // 1. Results reader
        resultsTask = Task { try await resultsReader() }

        // 2. Analyzer (blocks until analyzerStream ends)
        analyzerTask = Task {
            try await analyzer.start(inputSequence: analyzerStream)
        }

        // 3. Forward 16 kHz samples → AnalyzerInput
        let conv     = converter
        let aFmtCopy = aFmt
        let ifmt     = inputFormat

        forwardTask = Task {
            for await samples in sampleStream {
                let frames = samples.count
                guard let pcm = AVAudioPCMBuffer(pcmFormat: ifmt,
                                                  frameCapacity: AVAudioFrameCount(frames)) else { continue }
                pcm.frameLength = AVAudioFrameCount(frames)
                samples.withUnsafeBufferPointer { src in
                    if let dst = pcm.floatChannelData?[0], let base = src.baseAddress {
                        memcpy(dst, base, frames * MemoryLayout<Float>.size)
                    }
                }

                let bufferToYield: AVAudioPCMBuffer
                if let conv {
                    let ratio    = aFmtCopy.sampleRate / 16_000.0
                    let outCount = AVAudioFrameCount((Double(frames) * ratio).rounded(.up))
                    guard let out = AVAudioPCMBuffer(pcmFormat: aFmtCopy, frameCapacity: outCount) else { continue }
                    var convErr: NSError?
                    conv.convert(to: out, error: &convErr) { _, status in
                        status.pointee = .haveData
                        return pcm
                    }
                    guard convErr == nil else { continue }
                    bufferToYield = out
                } else {
                    bufferToYield = pcm
                }

                analyzerContinuation.yield(AnalyzerInput(buffer: bufferToYield))
            }
            analyzerContinuation.finish()
        }
        return engineLabel
    }

    func stop() async {
        forwardTask?.cancel()
        inputContinuation?.finish()
        analyzerTask?.cancel()
        resultsTask?.cancel()
        forwardTask = nil
        inputContinuation = nil
        analyzerTask = nil
        resultsTask = nil
        converter = nil
        analyzerFormat = nil
    }
}
