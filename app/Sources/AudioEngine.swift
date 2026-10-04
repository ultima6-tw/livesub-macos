@preconcurrency import AVFoundation
#if os(macOS)
import CoreAudio
#endif

// MARK: - System audio (macOS only)

#if os(macOS)

// clientData = Unmanaged-retained SystemAudioContext pointer
private func jasub_system_ioProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let raw = clientData else { return noErr }
    let ctx = Unmanaged<SystemAudioContext>.fromOpaque(raw).takeUnretainedValue()
    let byteCount = Int(inputData.pointee.mBuffers.mDataByteSize)
    let frameCount = byteCount / MemoryLayout<Float>.size
    guard frameCount > 0, let ptr = inputData.pointee.mBuffers.mData else { return noErr }
    let samples = Array(UnsafeBufferPointer(
        start: ptr.assumingMemoryBound(to: Float.self), count: frameCount))
    ctx.feed(samples)
    return noErr
}

// Bridges between the real-time IOProc thread and the async pipeline.
private final class SystemAudioContext: @unchecked Sendable {
    private let rawCont: AsyncStream<[Float]>.Continuation
    let task: Task<Void, Never>

    init(mainCont: AsyncStream<[Float]>.Continuation, nativeSampleRate: Double) {
        let (rawStream, rawCont) = AsyncStream<[Float]>.makeStream()
        self.rawCont = rawCont

        let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: nativeSampleRate, channels: 1, interleaved: false)!
        let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: srcFmt, to: dstFmt)!
        let chunkSize = Int(nativeSampleRate / 10)

        task = Task.detached {
            var pending: [Float] = []
            for await batch in rawStream {
                if Task.isCancelled { break }
                pending.append(contentsOf: batch)

                while pending.count >= chunkSize {
                    let chunk = Array(pending.prefix(chunkSize))
                    pending.removeFirst(chunkSize)

                    guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt,
                                                       frameCapacity: AVAudioFrameCount(chunkSize))
                    else { continue }
                    inBuf.frameLength = AVAudioFrameCount(chunkSize)
                    chunk.withUnsafeBufferPointer { p in
                        inBuf.floatChannelData![0].update(from: p.baseAddress!, count: chunkSize)
                    }

                    let outCapacity = AVAudioFrameCount(Double(chunkSize) * (16_000 / nativeSampleRate) + 32)
                    guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCapacity)
                    else { continue }

                    final class Once: @unchecked Sendable { var done = false }
                    let once = Once()
                    var convErr: NSError?
                    converter.convert(to: outBuf, error: &convErr) { _, status in
                        if once.done { status.pointee = .noDataNow; return nil }
                        once.done = true; status.pointee = .haveData; return inBuf
                    }

                    guard convErr == nil, outBuf.frameLength > 0,
                          let data = outBuf.floatChannelData else { continue }
                    mainCont.yield(Array(UnsafeBufferPointer(start: data[0],
                                                              count: Int(outBuf.frameLength))))
                }
            }
        }
    }

    func feed(_ samples: [Float]) { rawCont.yield(samples) }
    func finish() { task.cancel(); rawCont.finish() }
}

#endif // os(macOS)

// MARK: - Microphone capture delegate (macOS)

#if os(macOS)
/// Converts AVCaptureAudioDataOutput sample buffers to 16 kHz mono float32 for the ASR stream.
private final class MicCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<[Float]>.Continuation
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var srcFmt: AVAudioFormat?

    init(continuation: AsyncStream<[Float]>.Continuation) { self.continuation = continuation }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }

        var asbdCopy = asbd.pointee
        if srcFmt == nil || srcFmt!.streamDescription.pointee.mSampleRate != asbdCopy.mSampleRate
            || srcFmt!.channelCount != asbdCopy.mChannelsPerFrame {
            guard let f = AVAudioFormat(streamDescription: &asbdCopy), let c = AVAudioConverter(from: f, to: outFmt) else { return }
            srcFmt = f; converter = c
        }
        guard let srcFmt, let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return }

        let outCap = AVAudioFrameCount((Double(frames) * outFmt.sampleRate / srcFmt.sampleRate).rounded(.up)) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return }
        var err: NSError?
        var fed = false
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, outBuf.frameLength > 0, let ptr = outBuf.floatChannelData else { return }
        continuation.yield(Array(UnsafeBufferPointer(start: ptr[0], count: Int(outBuf.frameLength))))
    }
}
#endif

// MARK: - AudioEngine

final class AudioEngine {
    private var avEngine: AVAudioEngine?
    #if os(macOS)
    private var captureSession: AVCaptureSession?
    private var captureDelegate: MicCaptureDelegate?
    #endif
    private var fileReadTask: Task<Void, Never>?

    #if os(macOS)
    private var tapID: AudioObjectID = 0
    private var agDevID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var systemCtx: SystemAudioContext?
    private var systemCtxPtr: UnsafeMutableRawPointer?
    #endif

    // MARK: Microphone — macOS (with optional device selection)

    #if os(macOS)
    /// Uses AVCaptureSession so the chosen device is honoured. AVAudioEngine rebinds its inputNode
    /// to the Default Device Aggregate inside start(), which silently overrides the selected mic
    /// when the system default input is Bluetooth (see NOTES.md 2026-10-04).
    func start(deviceID: AudioDeviceID?, continuation: AsyncStream<[Float]>.Continuation) throws {
        DiagnosticLog.shared.log("[MIC] requested=\(Self.describeDevice(deviceID)) systemDefaultInput=\(Self.describeDevice(Self.defaultInputDeviceID()))")
        let device: AVCaptureDevice
        if let deviceID {
            guard let uid = Self.deviceUID(deviceID), let d = AVCaptureDevice(uniqueID: uid) else {
                throw AudioEngineError.deviceSetFailed(-1)
            }
            device = d
        } else {
            guard let d = AVCaptureDevice.default(for: .audio) else { throw AudioEngineError.deviceSetFailed(-1) }
            device = d
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw AudioEngineError.deviceSetFailed(-2) }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw AudioEngineError.deviceSetFailed(-3)
        }
        session.addInput(input)
        session.addOutput(output)
        let delegate = MicCaptureDelegate(continuation: continuation)
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "tw.ultima6.jasub.miccapture"))
        session.startRunning()
        captureSession = session
        captureDelegate = delegate
        DiagnosticLog.shared.log("[MIC] capture session started: device=\(device.localizedName) uid=\(device.uniqueID) running=\(session.isRunning)")
    }

    // MARK: Mic diagnostics

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func currentDevice(of audioUnit: AudioUnit) -> AudioDeviceID {
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev, &size)
        return dev
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }

    private static func describeDevice(_ id: AudioDeviceID?) -> String {
        guard let id, id != 0 else { return "none" }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let ok = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr
        return "\(ok ? (ref?.takeRetainedValue() as String? ?? "?") : "?")(\(id))"
    }
    #else
    // MARK: Microphone — iOS (always default mic, no device selection)
    func start(continuation: AsyncStream<[Float]>.Continuation) throws {
        let session = AVAudioSession.sharedInstance()
        // .default enables iOS beamforming, AGC and noise reduction —
        // better than .measurement for far-field meeting capture
        try session.setCategory(.record, mode: .default)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        try startAVEngine(AVAudioEngine(), continuation: continuation)
    }

    // MARK: File import — iOS
    func startFromFile(
        _ url: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        continuation: AsyncStream<[Float]>.Continuation
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        let srcFmt = file.processingFormat
        let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
            throw AudioEngineError.noConverter
        }
        let chunkFrames = AVAudioFrameCount(srcFmt.sampleRate * 0.1)

        fileReadTask = Task.detached {
            var read: AVAudioFramePosition = 0
            defer { continuation.finish() }
            while !Task.isCancelled {
                guard let buf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: chunkFrames) else { break }
                do { try file.read(into: buf) } catch { break }
                guard buf.frameLength > 0 else { break }

                read += AVAudioFramePosition(buf.frameLength)
                if total > 0 { onProgress(Double(read) / Double(total)) }

                let outCap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / srcFmt.sampleRate + 32)
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else { continue }

                final class Once: @unchecked Sendable { var done = false }
                let once = Once()
                var convErr: NSError?
                converter.convert(to: outBuf, error: &convErr) { _, status in
                    if once.done { status.pointee = .noDataNow; return nil }
                    once.done = true; status.pointee = .haveData; return buf
                }
                guard convErr == nil, outBuf.frameLength > 0,
                      let data = outBuf.floatChannelData else { continue }
                continuation.yield(Array(UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength))))
            }
        }
    }
    #endif

    // MARK: Shared mic implementation

    private func startAVEngine(_ engine: AVAudioEngine,
                               continuation: AsyncStream<[Float]>.Continuation) throws {
        let inputNode = engine.inputNode
        let nativeFmt = inputNode.inputFormat(forBus: 0)
        let outFmt    = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000, channels: 1, interleaved: false)!

        guard nativeFmt.sampleRate > 0, nativeFmt.channelCount > 0 else {
            throw AudioEngineError.invalidInputFormat(sampleRate: nativeFmt.sampleRate,
                                                      channels: Int(nativeFmt.channelCount))
        }
        guard let converter = AVAudioConverter(from: nativeFmt, to: outFmt) else {
            throw AudioEngineError.noConverter
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFmt) { buffer, _ in
            let ratio    = outFmt.sampleRate / nativeFmt.sampleRate
            let outCount = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCount) else { return }
            var err: NSError?
            converter.convert(to: outBuf, error: &err) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, let ptr = outBuf.floatChannelData else { return }
            continuation.yield(Array(UnsafeBufferPointer(start: ptr[0], count: Int(outBuf.frameLength))))
        }

        engine.prepare()
        try engine.start()
        self.avEngine = engine
    }

    // MARK: System audio (macOS only)

    #if os(macOS)
    func startSystemAudio(continuation: AsyncStream<[Float]>.Continuation) throws {
        let tapDesc = CATapDescription()
        tapDesc.isMono      = true
        tapDesc.isPrivate   = true
        tapDesc.muteBehavior = .unmuted
        tapDesc.isExclusive = true

        var localTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &localTapID)
        guard tapStatus == noErr, localTapID != 0 else {
            throw AudioEngineError.tapFailed(tapStatus)
        }
        tapID = localTapID

        let agUID = UUID().uuidString
        let agDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:          "JaSubTap",
            kAudioAggregateDeviceUIDKey as String:           agUID,
            kAudioAggregateDeviceIsPrivateKey as String:     true,
            kAudioAggregateDeviceTapAutoStartKey as String:  false,
            kAudioAggregateDeviceSubDeviceListKey as String: [] as [Any],
            kAudioAggregateDeviceTapListKey as String:       [["uid": tapDesc.uuid.uuidString]]
        ]

        var localAgDevID: AudioDeviceID = 0
        let agStatus = AudioHardwareCreateAggregateDevice(agDesc as CFDictionary, &localAgDevID)
        guard agStatus == noErr, localAgDevID != 0 else {
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw AudioEngineError.aggregateFailed(agStatus)
        }
        agDevID = localAgDevID

        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        var nativeRate = 48_000.0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(agDevID, &rateAddr, 0, nil, &rateSize, &nativeRate)

        let ctx    = SystemAudioContext(mainCont: continuation, nativeSampleRate: nativeRate)
        systemCtx  = ctx
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        systemCtxPtr = ctxPtr

        var localProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(agDevID, jasub_system_ioProc, ctxPtr, &localProcID)
        guard createStatus == noErr else {
            ctx.finish()
            Unmanaged<SystemAudioContext>.fromOpaque(ctxPtr).release()
            systemCtx = nil; systemCtxPtr = nil
            AudioHardwareDestroyAggregateDevice(agDevID); agDevID = 0
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw AudioEngineError.procFailed(createStatus)
        }
        ioProcID = localProcID

        let startStatus = AudioDeviceStart(agDevID, localProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(agDevID, localProcID!)
            ctx.finish()
            Unmanaged<SystemAudioContext>.fromOpaque(ctxPtr).release()
            systemCtx = nil; systemCtxPtr = nil
            AudioHardwareDestroyAggregateDevice(agDevID); agDevID = 0
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw AudioEngineError.startFailed(startStatus)
        }
    }
    #endif

    // MARK: Stop

    func stop() {
        avEngine?.inputNode.removeTap(onBus: 0)
        avEngine?.stop()
        avEngine = nil

        #if os(macOS)
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate = nil
        #endif

        fileReadTask?.cancel()
        fileReadTask = nil

        #if os(macOS)
        if agDevID != 0 {
            if let procID = ioProcID {
                AudioDeviceStop(agDevID, procID)
                AudioDeviceDestroyIOProcID(agDevID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(agDevID)
            agDevID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        systemCtx?.finish()
        systemCtx = nil
        if let ptr = systemCtxPtr {
            Unmanaged<SystemAudioContext>.fromOpaque(ptr).release()
            systemCtxPtr = nil
        }
        #else
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }
}

// MARK: - Errors

enum AudioEngineError: Error {
    case deviceSetFailed(OSStatus)
    case invalidInputFormat(sampleRate: Double, channels: Int)
    case noConverter
    case tapFailed(OSStatus)
    case aggregateFailed(OSStatus)
    case procFailed(OSStatus)
    case startFailed(OSStatus)
}

extension AudioEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .deviceSetFailed(let s):
            return String(format: NSLocalizedString("error.deviceSetFailed",
                value: "Failed to set audio input device (OSStatus %d). Please select a different device.",
                comment: ""), s)
        case .invalidInputFormat(let sr, let ch):
            return String(format: NSLocalizedString("error.invalidInputFormat",
                value: "The selected device does not support audio input (sampleRate=%.0f channels=%d). Please select a different input device.",
                comment: ""), sr, ch)
        case .noConverter:
            return NSLocalizedString("error.noConverter",
                value: "Failed to create audio format converter. Please select a different input device.",
                comment: "")
        case .tapFailed(let s):
            return String(format: NSLocalizedString("error.tapFailed",
                value: "System audio capture failed (OSStatus %d). Please ensure Screen Recording permission is enabled.\n\nUpgrading? Remove the JaSub entry from Screen Recording, relaunch JaSub, grant permission when prompted, then relaunch once more when macOS asks you to.",
                comment: ""), s)
        case .aggregateFailed(let s):
            return String(format: NSLocalizedString("error.aggregateFailed",
                value: "System audio device creation failed (OSStatus %d).",
                comment: ""), s)
        case .procFailed(let s):
            return String(format: NSLocalizedString("error.procFailed",
                value: "Audio IOProc creation failed (OSStatus %d).",
                comment: ""), s)
        case .startFailed(let s):
            return String(format: NSLocalizedString("error.startFailed",
                value: "Audio device start failed (OSStatus %d).",
                comment: ""), s)
        }
    }
}
