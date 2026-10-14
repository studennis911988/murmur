import AVFoundation

/// A finished recording, resampled to 16 kHz mono.
struct Recording {
    let samples: [Float]
    let duration: TimeInterval
    /// Time spent above the voice threshold; near zero means nobody spoke.
    let voicedDuration: TimeInterval
}

enum AudioError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone is available."
        case .converterUnavailable: return "The microphone's audio format isn't supported."
        case .unreadableFile(let reason): return "Couldn't read the audio file: \(reason)"
        }
    }
}

/// Captures the default microphone. Native-format buffers go to streaming
/// recognizers as they arrive; a 16 kHz mono copy accumulates for engines
/// that transcribe the whole recording at the end.
final class AudioRecorder {
    static let sampleRate: Double = 16_000
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    static let voiceRMS: Float = 0.012

    /// Called on the audio thread.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Input level 0...1, on the main thread.
    var onLevel: ((Float) -> Void)?
    var onSilenceTimeout: (() -> Void)?
    var onNoAudio: (() -> Void)?
    /// The input device changed or stopped delivering audio (headset plugged
    /// in, AirPods connected); the engine won't recover on its own.
    var onInterrupted: (() -> Void)?
    var silenceTimeout: TimeInterval = 0

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var voicedFrames = 0
    // Touched only on the audio thread after start().
    private var startTime = Date.distantPast
    private var lastVoice: Date?
    private var firedSilence = false
    private var firedNoAudio = false
    // Guarded by `lock`.
    private var lastBufferAt: Date?
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Timer?

    func start() throws {
        // A fresh engine per recording picks up the current default input device.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInputDevice }
        guard let converter = AVAudioConverter(from: format, to: Self.targetFormat) else { throw AudioError.converterUnavailable }
        // Average all channels: on a multi-input interface the mic may not be channel 1.
        converter.downmix = true
        self.converter = converter
        samples.removeAll(keepingCapacity: true)
        voicedFrames = 0
        lastVoice = nil
        firedSilence = false
        firedNoAudio = false
        startTime = Date()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        lastBufferAt = nil
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.interrupt() }
        let started = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let last = self.lock.withLock { self.lastBufferAt }
            // Bluetooth headsets can take a few seconds to deliver the first buffer.
            let stalled = last.map { Date().timeIntervalSince($0) > 2.5 } ?? (Date().timeIntervalSince(started) > 6)
            if stalled { self.interrupt() }
        }
        Log.audio.info("recording from \(format.sampleRate) Hz × \(format.channelCount) ch")
    }

    private func interrupt() {
        teardownMonitoring()
        onInterrupted?()
    }

    private func teardownMonitoring() {
        watchdog?.invalidate()
        watchdog = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    func stop() -> Recording {
        teardownMonitoring()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        lock.lock()
        let captured = samples
        let voiced = voicedFrames
        samples = []
        lock.unlock()
        return Recording(
            samples: captured,
            duration: Double(captured.count) / Self.sampleRate,
            voicedDuration: Double(voiced) / Self.sampleRate
        )
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)
        guard let converter else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }

        let chunk = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        var sumSquares: Float = 0
        for value in chunk { sumSquares += value * value }
        let rms = (sumSquares / Float(chunk.count)).squareRoot()
        let voiced = rms > Self.voiceRMS

        lock.lock()
        samples.append(contentsOf: chunk)
        if voiced { voicedFrames += chunk.count }
        lastBufferAt = Date()
        lock.unlock()

        let now = Date()
        if voiced { lastVoice = now }
        let elapsed = now.timeIntervalSince(startTime)
        if silenceTimeout > 0, !firedSilence, elapsed > 2,
           now.timeIntervalSince(lastVoice ?? startTime) >= silenceTimeout {
            firedSilence = true
            DispatchQueue.main.async { [weak self] in self?.onSilenceTimeout?() }
        }
        if !firedNoAudio, lastVoice == nil, elapsed > 4 {
            firedNoAudio = true
            DispatchQueue.main.async { [weak self] in self?.onNoAudio?() }
        }
        let level = Self.normalizedLevel(rms)
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    static func normalizedLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return max(0, min(1, (decibels + 55) / 45))
    }
}

enum AudioFileLoader {
    /// Decodes any format AVFoundation reads (wav, m4a, mp3, aiff, caf, mp4
    /// audio) into 16 kHz mono samples.
    static func load(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioError.unreadableFile(error.localizedDescription)
        }
        let format = file.processingFormat
        let target = AudioRecorder.targetFormat
        guard let converter = AVAudioConverter(from: format, to: target) else { throw AudioError.converterUnavailable }
        let chunk: AVAudioFrameCount = 32_768
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw AudioError.converterUnavailable }
        let outCapacity = AVAudioFrameCount(Double(chunk) * target.sampleRate / format.sampleRate) + 1024

        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * target.sampleRate / format.sampleRate))
        var reachedEnd = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if reachedEnd {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: chunk)
                } catch {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .error { throw AudioError.unreadableFile(error?.localizedDescription ?? "conversion failed") }
            if status == .endOfStream { break }
        }
        return result
    }

    /// Splits 16 kHz mono samples into PCM buffers for recognizers that take
    /// buffers rather than a file.
    static func buffers(from samples: [Float], frames: Int = 16_000) -> [AVAudioPCMBuffer] {
        stride(from: 0, to: samples.count, by: frames).compactMap { start in
            let count = min(frames, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioRecorder.targetFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return nil }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + start, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            return buffer
        }
    }
}
