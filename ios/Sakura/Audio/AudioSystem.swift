import AVFoundation
import Accelerate

/// One AVAudioEngine for the whole voice loop:
///   mic tap → AVAudioConverter → 16 kHz mono pcm16 chunks (~32+ ms) upstream
///   Gemini 24 kHz pcm16 chunks → AVAudioPlayerNode (gapless scheduleBuffer)
///   main-mixer tap → playback RMS for lip sync
///
/// Threading: taps deliver on AVFoundation's own background threads; all
/// bookkeeping and callbacks are funneled onto `workQueue`. Nothing here
/// parses JSON, touches the network, or blocks — callers do that on their
/// own queues from the callbacks.
final class AudioSystem {
    /// ~32 ms of 16 kHz mono pcm16 plus its RMS (0…1). Called on workQueue.
    var onMicChunk: ((Data, Float) -> Void)?
    /// Fired when sustained mic voice cut playback locally (instant barge-in,
    /// same heuristic as the web client). Called on workQueue.
    var onLocalBargeIn: (() -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let workQueue = DispatchQueue(label: "sakura.audio")

    private var micConverter: AVAudioConverter?
    private var pendingMic = Data()
    private var voiceRun = 0                 // consecutive loud mic chunks while she speaks
    private var micRunning = false
    private var engineConfigured = false

    // playback bookkeeping — workQueue only
    private var queuedBuffers = 0
    private var generation = 0               // invalidates stale scheduleBuffer completions

    // cross-thread reads for UI / gating
    private let stateLock = NSLock()
    private var _isSpeaking = false
    private var _playbackLevel: Float = 0

    var isSpeaking: Bool { stateLock.withLock { _isSpeaking } }
    var playbackLevel: Float { stateLock.withLock { _playbackLevel } }

    // MARK: - Lifecycle

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // .voiceChat enables echo cancellation — required so Sakura's own voice
        // doesn't stream back up the mic and trip barge-in.
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        if !engineConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            installLevelTap()
            observeNotifications()
            engineConfigured = true
        }
        engine.prepare()
        try engine.start()
        player.play()
    }

    func stop() {
        stopMic()
        stopPlayback()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Microphone

    func startMic() throws {
        guard !micRunning else { return }
        if !engine.isRunning { try engine.start() }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        micConverter = AVAudioConverter(from: hwFormat, to: captureFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            self?.convertAndShip(buffer)
        }
        micRunning = true
    }

    func stopMic() {
        guard micRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        micConverter = nil
        micRunning = false
        workQueue.async { self.pendingMic.removeAll(); self.voiceRun = 0 }
    }

    var isMicRunning: Bool { micRunning }

    /// Tap thread (not the render thread): resample to 16 kHz pcm16, then hop
    /// to workQueue for accumulation and shipping.
    private func convertAndShip(_ buffer: AVAudioPCMBuffer) {
        guard let converter = micConverter else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard convErr == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: samples, count: Int(out.frameLength) * 2)
        workQueue.async { self.accumulate(data) }
    }

    private func accumulate(_ data: Data) {
        pendingMic.append(data)
        guard pendingMic.count >= 1024 else { return }  // ≥512 samples ≈ 32 ms, matches web
        let chunk = pendingMic
        pendingMic = Data()
        let rms = Self.rmsInt16(chunk)
        onMicChunk?(chunk, rms)

        // local instant-mute: ~3 consecutive loud chunks (~100 ms of voice)
        // while she is speaking cuts playback without waiting for Gemini's
        // interrupted signal to round-trip.
        if isSpeaking {
            // ponytail: fixed RMS threshold; adaptive ambient-noise floor if it misfires
            voiceRun = rms > 0.04 ? voiceRun + 1 : 0
            if voiceRun >= 3 {
                voiceRun = 0
                stopPlaybackLocked()
                onLocalBargeIn?()
            }
        } else {
            voiceRun = 0
        }
    }

    private static func rmsInt16(_ data: Data) -> Float {
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            guard !s.isEmpty else { return 0 }
            var sum: Float = 0
            for v in s { let f = Float(v) / 32768; sum += f * f }
            return sqrtf(sum / Float(s.count))
        }
    }

    // MARK: - Playback

    /// Thread-safe; called straight from the WebSocket receive path.
    func enqueueVoice(_ pcm16: Data) {
        workQueue.async { self.schedule(pcm16) }
    }

    func stopPlayback() {
        workQueue.async { self.stopPlaybackLocked() }
    }

    private func schedule(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let i16 = raw.bindMemory(to: Int16.self)
            let out = buf.floatChannelData![0]
            for i in 0..<frames { out[i] = Float(i16[i]) / 32768 }
        }
        queuedBuffers += 1
        setSpeaking(true)
        let gen = generation
        player.scheduleBuffer(buf) { [weak self] in
            self?.workQueue.async {
                guard let self, gen == self.generation else { return }
                self.queuedBuffers -= 1
                if self.queuedBuffers <= 0 { self.setSpeaking(false) }
            }
        }
        if engine.isRunning, !player.isPlaying { player.play() }
    }

    /// workQueue only.
    private func stopPlaybackLocked() {
        generation += 1
        queuedBuffers = 0
        player.stop()  // drops every scheduled buffer
        setSpeaking(false)
        stateLock.withLock { _playbackLevel = 0 }
        if engine.isRunning { player.play() }  // re-arm for the next reply
    }

    private func setSpeaking(_ value: Bool) {
        stateLock.withLock { _isSpeaking = value }
    }

    // MARK: - Lip-sync level

    private func installLevelTap() {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
            self.stateLock.withLock { self._playbackLevel = rms }
        }
    }

    // MARK: - Session events

    private func observeNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.workQueue.async { self?.restartEngineIfNeeded() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                self?.workQueue.async { self?.restartEngineIfNeeded() }
            }
        }
    }

    private func restartEngineIfNeeded() {
        guard engineConfigured, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        player.play()
    }
}
