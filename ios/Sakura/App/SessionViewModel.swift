import SwiftUI
import AVFoundation

/// Orchestrates the whole experience: Gemini Live connection, audio in/out,
/// transcript bubbles, lip sync, scene updates and memory capture. UI state
/// lives on the main actor; audio and networking stay on their own queues.
@MainActor
final class SessionViewModel: ObservableObject {
    enum Role { case you, her }
    enum StatusKind { case idle, ok, talk, error }

    struct Bubble: Identifiable {
        let id = UUID()
        let role: Role
        var text: String
    }

    @Published var statusText = "tap to start"
    @Published var statusKind: StatusKind = .idle
    @Published var bubbles: [Bubble] = []
    @Published var mouth: Mouth = .closed
    @Published var outfit = Outfit.all[0]
    @Published var backdrop = Backdrop.all[0]
    @Published var micLive = false
    @Published var sessionStarted = false
    @Published var apiKeyMissing = false

    let memory: MemoryStore

    private let audio = AudioSystem()
    private var client: GeminiLiveClient?
    private var turnBuffer = TurnBuffer()
    private var turnsRecorded = 0
    private var openBubble: [Role: UUID] = [:]
    private var mouthTimer: Timer?
    private var lastMouthSwap: TimeInterval = 0
    private var sceneTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var wantsSession = false   // user intent — drives auto-reconnect

    init(memory: MemoryStore = MemoryStore()) {
        self.memory = memory
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard !AppConfig.geminiAPIKey.isEmpty else {
            apiKeyMissing = true
            return
        }
        guard !sessionStarted else { return }
        wantsSession = true
        sessionStarted = true
        do {
            try audio.start()
        } catch {
            setStatus("audio failed: \(error.localizedDescription)", .error)
        }
        audio.onMicChunk = { [weak self] data, _ in
            self?.client?.sendAudioChunk(data)   // workQueue → URLSession; never blocks audio
        }
        startMouthTimer()
        connect()
    }

    private func connect() {
        setStatus("connecting…", .idle)
        let c = GeminiLiveClient()
        client = c
        c.onEvent = { [weak self] event in
            guard let self else { return }
            // hot path: voice chunks go straight to the player, no main-actor hop
            if case .audio(let pcm) = event {
                self.audio.enqueueVoice(pcm)
                return
            }
            Task { @MainActor in self.handle(event) }
        }
        Task {
            await memory.touchSession()
            let section = formatMemorySection(await memory.current)
            let instruction = Sakura.persona + (section.isEmpty ? "" : "\n\n" + section)
            c.connect(apiKey: AppConfig.geminiAPIKey, systemInstruction: instruction)
        }
    }

    /// Safe cleanup for backgrounding / teardown: closes the socket, stops the
    /// engine, persists tail turns, and kicks off memory extraction.
    func enterBackground() {
        guard sessionStarted else { return }
        reconnectTask?.cancel()
        sceneTask?.cancel()
        client?.disconnect()
        client = nil
        finalizeTurns()
        audio.stop()
        micLive = false
        setStatus("paused", .idle)
    }

    func enterForeground() {
        guard wantsSession, client == nil else { return }
        do { try audio.start() } catch {
            setStatus("audio failed: \(error.localizedDescription)", .error)
            return
        }
        connect()  // mic stays off until re-tapped, mirroring a fresh page load
    }

    // MARK: - Gemini events (main actor)

    private func handle(_ event: GeminiLiveClient.Event) {
        switch event {
        case .setupComplete:
            setStatus("ready — talk to me!", .ok)
            client?.sendScene(outfit: outfit.clean, background: backdrop.clean, announce: false)

        case .interrupted:
            audio.stopPlayback()
            recordFlush("sakura")           // keep what she actually got to say
            openBubble[.her] = nil          // close the cut-off bubble

        case .turnComplete:
            recordFlush("user")
            recordFlush("sakura")
            openBubble = [:]

        case .userTranscript(let text):
            appendBubble(.you, text)
            turnBuffer.append(role: "user", text: text)

        case .modelTranscript(let text):
            appendBubble(.her, text)
            turnBuffer.append(role: "sakura", text: text)

        case .goAway:
            setStatus("reconnecting…", .idle)

        case .closed:
            guard wantsSession, client != nil else { return }
            client = nil
            finalizeTurns()
            setStatus("reconnecting…", .idle)
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled, self.wantsSession else { return }
                self.connect()
            }

        case .audio:
            break  // routed before the main-actor hop
        }
    }

    // MARK: - User input

    func sendText(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client else { return }
        audio.stopPlayback()  // typing interrupts her mid-sentence, like real conversation
        appendBubble(.you, text)
        openBubble[.you] = nil
        record(role: "user", text: text)  // typed turns are already complete
        client.sendText(text)
    }

    func toggleMic() {
        if audio.isMicRunning {
            audio.stopMic()
            micLive = false
            setStatus("ready — talk to me!", .ok)
            return
        }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                setStatus("mic blocked — allow it in Settings", .error)
                return
            }
            do {
                try audio.startMic()
                micLive = true
                setStatus("listening…", .ok)
            } catch {
                setStatus("mic failed: \(error.localizedDescription)", .error)
            }
        }
    }

    // MARK: - Scene (outfit / background)

    func setOutfit(_ o: Outfit) {
        outfit = o
        scheduleScene()
    }

    func setBackdrop(_ b: Backdrop) {
        backdrop = b
        scheduleScene()
    }

    /// Debounce rapid chip taps into one announced update (600 ms, like web).
    private func scheduleScene() {
        sceneTask?.cancel()
        sceneTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.client?.sendScene(outfit: self.outfit.clean,
                                   background: self.backdrop.clean, announce: true)
        }
    }

    // MARK: - Transcript bubbles

    private func appendBubble(_ role: Role, _ text: String) {
        if let id = openBubble[role], let idx = bubbles.firstIndex(where: { $0.id == id }) {
            bubbles[idx].text += text
        } else {
            let bubble = Bubble(role: role, text: text)
            openBubble[role] = bubble.id
            bubbles.append(bubble)
            if bubbles.count > 40 { bubbles.removeFirst(bubbles.count - 40) }
        }
    }

    // MARK: - Memory capture

    private func recordFlush(_ role: String) {
        if let text = turnBuffer.flush(role) {
            record(role: role, text: text)
        }
    }

    private func record(role: String, text: String) {
        turnsRecorded += 1
        let shouldExtract = turnsRecorded % MemoryLimits.updateTurnThreshold == 0
        Task {
            await memory.addTurn(role: role, text: text)
            if shouldExtract { await runExtraction() }
        }
    }

    private func finalizeTurns() {
        for (role, text) in turnBuffer.flushAll() {
            turnsRecorded += 1
            let r = role, t = text
            Task { await memory.addTurn(role: r, text: t) }
        }
        openBubble = [:]
        Task { await runExtraction() }
    }

    private func runExtraction() async {
        let key = AppConfig.geminiAPIKey
        guard !key.isEmpty else { return }
        let extractor = MemoryExtractor(apiKey: key)
        await memory.runExtraction { old, turns in
            try await extractor.extract(old: old, turns: turns)
        }
    }

    // MARK: - Lip sync (port of lipLoop in app.js)

    private func startMouthTimer() {
        mouthTimer?.invalidate()
        mouthTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMouth() }
        }
    }

    private func tickMouth() {
        let rms = audio.isSpeaking ? audio.playbackLevel : 0
        let talking = rms > 0.015
        if talking {
            setStatus("Sakura is speaking ♪", .talk)
        } else if statusKind == .talk {
            setStatus(micLive ? "listening…" : "ready — talk to me!", .ok)
        }

        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastMouthSwap >= 0.07 else { return }  // hold frames ≥70 ms
        let next: Mouth
        if rms < 0.015 { next = .closed }
        else if rms < 0.055 { next = .half }
        else { next = (mouth == .open && Double.random(in: 0..<1) < 0.35) ? .half : .open }
        if next != mouth {
            mouth = next
            lastMouthSwap = now
        }
    }

    private func setStatus(_ text: String, _ kind: StatusKind) {
        statusText = text
        statusKind = kind
    }
}
