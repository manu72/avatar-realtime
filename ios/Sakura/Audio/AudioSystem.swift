import AVFoundation
import Accelerate
import os

/// One AVAudioEngine for the whole voice loop:
///   mic tap → AVAudioConverter → 16 kHz mono pcm16 chunks (~32+ ms) upstream
///   Gemini 24 kHz pcm16 chunks → AVAudioPlayerNode (gapless scheduleBuffer)
///   main-mixer tap → playback RMS for lip sync
///
/// Startup lifecycle (order matters on physical devices — a .playAndRecord
/// engine initialised before record permission resolves fails with
/// AVAudioSessionErrorCodeCannotStartPlaying, '!pla' / 561015905, because the
/// IO unit's input side comes up with a 0 Hz format):
///   1. record permission granted (caller resolves it; start() re-checks)
///   2. session category/mode set and session activated
///   3. full graph built — including touching inputNode — and formats verified
///   4. prepare() + start()
///   5. only then is the player node started / playback schedulable
///
/// Threading: taps deliver on AVFoundation's own background threads; all
/// bookkeeping and callbacks are funneled onto `workQueue`. Nothing here
/// parses JSON, touches the network, or blocks — callers do that on their
/// own queues from the callbacks.
final class AudioSystem {
    enum State: Equatable { case idle, starting, running, interrupted, failed }

    struct StartupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// ~32 ms of 16 kHz mono pcm16 plus its RMS (0…1). Called on workQueue.
    var onMicChunk: ((Data, Float) -> Void)?
    /// Fired when sustained mic voice cut playback locally (instant barge-in,
    /// same heuristic as the web client). Called on workQueue.
    var onLocalBargeIn: (() -> Void)?
    /// Fired when a runtime rebuild (route change / interruption recovery)
    /// fails and audio is dead until the next start(). Called on workQueue.
    var onRuntimeFailure: ((String) -> Void)?

    private let log = Logger(subsystem: "com.throwingeights.sakura", category: "audio")

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let workQueue = DispatchQueue(label: "sakura.audio")

    private var micConverter: AVAudioConverter?
    private var pendingMic = Data()
    private var voiceRun = 0                 // consecutive loud mic chunks while she speaks
    private var micTapInstalled = false
    private var micWanted = false            // survives rebuilds: re-install the tap
    private var nodesAttached = false
    private var observersInstalled = false
    private var pendingRebuild: DispatchWorkItem?   // workQueue only

    // playback bookkeeping — workQueue only
    private var queuedBuffers = 0
    private var generation = 0               // invalidates stale scheduleBuffer completions

    // cross-thread reads for UI / gating
    private let stateLock = NSLock()
    private var _state: State = .idle
    private var _isSpeaking = false
    private var _playbackLevel: Float = 0

    private(set) var state: State {
        get { stateLock.withLock { _state } }
        set { stateLock.withLock { _state = newValue } }
    }
    var isSpeaking: Bool { stateLock.withLock { _isSpeaking } }
    var playbackLevel: Float { stateLock.withLock { _playbackLevel } }
    var isMicRunning: Bool { stateLock.withLock { _state == .running } && micTapInstalled }

    // MARK: - Lifecycle

    /// Bring the whole duplex pipeline up, in the safe order. Throws a
    /// readable message at the first failing step; on any throw the state is
    /// `.failed` and nothing downstream (playback, mic) will run.
    func start() throws {
        state = .starting
        do {
            try startLocked()
            state = .running
        } catch {
            state = .failed
            engine.stop()
            throw error
        }
    }

    private func startLocked() throws {
        // 1. permission — must already be resolved; a .playAndRecord engine
        //    must never be initialised while permission is undetermined
        let permission = AVAudioApplication.shared.recordPermission
        log.info("record permission: \(String(describing: permission.rawValue))")
        guard permission == .granted else {
            throw StartupError(message: "Microphone access is not granted. Allow it in Settings ▸ Sakura.")
        }

        // 2. session configuration, then activation
        let session = AVAudioSession.sharedInstance()
        do {
            // .voiceChat tunes routing/EQ for VoIP; actual echo cancellation
            // is enabled separately below via setVoiceProcessingEnabled.
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            log.info("session category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
        } catch {
            log.error("setCategory failed: \(error.localizedDescription)")
            throw StartupError(message: "Audio session category failed: \(error.localizedDescription)")
        }
        do {
            try session.setActive(true)
            log.info("session activated; sampleRate=\(session.sampleRate) ioBuffer=\(session.ioBufferDuration)")
        } catch {
            log.error("setActive failed: \(error.localizedDescription)")
            throw StartupError(message: "Could not activate the audio session: \(error.localizedDescription)")
        }
        let route = session.currentRoute
        log.info("route in=\(route.inputs.map(\.portType.rawValue).joined(separator: ",")) out=\(route.outputs.map(\.portType.rawValue).joined(separator: ","))")

        // 2.5 acoustic echo cancellation. The .voiceChat session mode does
        // NOT apply AEC to AVAudioEngine's raw input tap — without this,
        // Sakura's speaker output loops into the mic and Gemini transcribes
        // her as the user. Enabling voice processing inserts Apple's VoIP
        // I/O unit (the one FaceTime uses), which subtracts the engine's own
        // playback from the capture. Must be set while the engine is stopped,
        // before formats are read (it can change the input format).
        if !engine.inputNode.isVoiceProcessingEnabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                log.info("voice processing (AEC) enabled")
            } catch {
                // engine still works without it, just echo-prone — not fatal
                log.error("voice processing enable failed: \(error.localizedDescription)")
            }
        }

        // 3. full graph before prepare/start — touch inputNode NOW so the IO
        //    unit is built full-duplex once, with a real input format
        if !nodesAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            installLevelTap()
            nodesAttached = true
        }
        if !observersInstalled {
            observeNotifications()
            observersInstalled = true
        }
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        log.info("input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
        log.info("output format: \(outputFormat.sampleRate) Hz, \(outputFormat.channelCount) ch")
        log.info("player → mixer at \(self.playbackFormat.sampleRate) Hz mono (mixer resamples to hardware)")
        guard inputFormat.sampleRate > 0, outputFormat.sampleRate > 0 else {
            throw StartupError(message: "Audio hardware reported a 0 Hz format — no usable route. Disconnect Bluetooth audio and retry.")
        }

        // 4. prepare + start
        engine.prepare()
        do {
            try engine.start()
            log.info("engine started")
        } catch {
            log.error("engine start failed: \(error.localizedDescription)")
            throw StartupError(message: "Audio engine failed to start: \(error.localizedDescription)")
        }

        // 5. only now is the player allowed to run
        player.play()
        if micWanted { try installMicTap() }
    }

    func stop() {
        micWanted = false
        workQueue.async { self.pendingRebuild?.cancel(); self.pendingRebuild = nil }
        removeMicTap()
        stopPlayback()
        engine.stop()
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("audio stopped, session deactivated")
    }

    /// Recovery entry point for every disturbance (route change, interruption
    /// ended, engine config change). Debounced, and it only acts when the
    /// engine has actually stopped — our own setCategory/setActive during a
    /// rebuild posts a `.categoryChange` route event, and reacting to that
    /// echo unconditionally would rebuild forever.
    private func scheduleRebuild(reason: String) {
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.stateLock.withLock({ self._state == .running || self._state == .interrupted }) else { return }
            guard !self.engine.isRunning else {
                self.log.info("engine still running after \(reason) — no rebuild needed")
                return
            }
            self.rebuild(reason: reason)
        }
        pendingRebuild = item
        workQueue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Tear the engine down to a clean graph and bring it back with the same
    /// lifecycle as a cold start. workQueue only, via scheduleRebuild.
    private func rebuild(reason: String) {
        log.info("rebuilding engine (\(reason))")
        removeMicTap()
        generation += 1
        queuedBuffers = 0
        player.stop()
        setSpeaking(false)
        engine.stop()
        engine.reset()
        do {
            try startLocked()
            state = .running
            log.info("rebuild ok")
        } catch {
            state = .failed
            log.error("rebuild failed: \(error.localizedDescription)")
            onRuntimeFailure?(error.localizedDescription)
        }
    }

    // MARK: - Microphone

    /// Permission must already be granted (start() enforces it for the
    /// engine; the view model resolves it before calling anything here).
    func startMic() throws {
        micWanted = true
        guard state == .running else {
            throw StartupError(message: "Audio engine isn't running — start the session first.")
        }
        try installMicTap()
    }

    func stopMic() {
        micWanted = false
        removeMicTap()
    }

    private func installMicTap() throws {
        guard !micTapInstalled else { return }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw StartupError(message: "Microphone route has no valid format.")
        }
        log.info("mic tap: \(hwFormat.sampleRate) Hz \(hwFormat.channelCount) ch → 16000 Hz mono pcm16")
        micConverter = AVAudioConverter(from: hwFormat, to: captureFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            self?.convertAndShip(buffer)
        }
        micTapInstalled = true
    }

    private func removeMicTap() {
        guard micTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        micConverter = nil
        micTapInstalled = false
        workQueue.async { self.pendingMic.removeAll(); self.voiceRun = 0 }
    }

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

    /// Thread-safe; called straight from the WebSocket receive path. Chunks
    /// arriving while the engine isn't running are dropped — playback must
    /// never begin before engine readiness.
    func enqueueVoice(_ pcm16: Data) {
        guard state == .running else { return }
        workQueue.async { self.schedule(pcm16) }
    }

    func stopPlayback() {
        workQueue.async { self.stopPlaybackLocked() }
    }

    private func schedule(_ data: Data) {
        guard state == .running, engine.isRunning else { return }
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
        if !player.isPlaying { player.play() }
    }

    /// workQueue only.
    private func stopPlaybackLocked() {
        generation += 1
        queuedBuffers = 0
        player.stop()  // drops every scheduled buffer
        setSpeaking(false)
        stateLock.withLock { _playbackLevel = 0 }
        if state == .running, engine.isRunning { player.play() }  // re-arm for the next reply
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
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            self.log.info("route change: \(raw)")
            self.scheduleRebuild(reason: "route change \(raw)")
        }
        // Apple's actual "your graph is invalid" signal — fires when a route/
        // hardware change stops the engine (e.g. sample-rate or channel-count
        // change). The route-change notification alone doesn't imply that.
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.log.info("engine configuration change")
            self.scheduleRebuild(reason: "engine config change")
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.log.info("interruption began")
                if self.state == .running { self.state = .interrupted }
                self.workQueue.async { self.stopPlaybackLocked() }
            case .ended:
                self.log.info("interruption ended")
                self.scheduleRebuild(reason: "interruption ended")
            @unknown default:
                break
            }
        }
    }
}
