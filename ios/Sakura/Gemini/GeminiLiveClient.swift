import Foundation

/// Direct WebSocket connection to the Gemini Live API — no relay server.
///
/// Endpoint: wss://generativelanguage.googleapis.com/ws/
///           google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent
/// Auth: API key as `key` query parameter. Recoverable from the binary —
/// local-testing only, never a production pattern.
///
/// Events fire on URLSession's internal queue. The one hot path — `.audio` —
/// must go straight to the audio player; everything else can hop to the main
/// actor. `SessionViewModel` does that split.
final class GeminiLiveClient {
    enum Event {
        case setupComplete
        case audio(Data)               // 24 kHz mono pcm16, already base64-decoded
        case interrupted
        case turnComplete
        case userTranscript(String)
        case modelTranscript(String)
        case goAway
        case closed(Error?)
    }

    var onEvent: ((Event) -> Void)?

    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private let urlSession = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var closedReported = false
    private var pingTimer: Timer?

    func connect(apiKey: String, systemInstruction: String) {
        var comps = URLComponents(string: Self.endpoint)!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        closedReported = false
        let t = urlSession.webSocketTask(with: comps.url!)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()
        send(ClientMessage(setup: .sakura(systemInstruction: systemInstruction)))
        receiveLoop()
        startPings()
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        closedReported = true  // deliberate close: don't surface as an error
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: - Sending

    func sendAudioChunk(_ pcm16: Data) {
        send(ClientMessage(realtimeInput: .init(
            audio: .init(data: pcm16.base64EncodedString(), mimeType: "audio/pcm;rate=16000")
        )))
    }

    func sendText(_ text: String) {
        send(ClientMessage(clientContent: .init(turns: [.user(text)], turnComplete: true)))
    }

    /// Same wording as the web server's scene handler so behaviour matches.
    func sendScene(outfit: String, background: String, announce: Bool) {
        var note = "[Scene update: you are wearing your \(outfit) outfit "
            + "and you are at this location: \(background).]"
        if announce {
            note += " React with one short, cheerful in-character line about your new look or surroundings."
        }
        send(ClientMessage(clientContent: .init(turns: [.user(note)], turnComplete: announce)))
    }

    private func send(_ message: ClientMessage) {
        guard let task, let data = try? encoder.encode(message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error { self?.reportClosed(error) }
        }
    }

    // MARK: - Receiving

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.reportClosed(error)
            case .success(let message):
                switch message {
                case .data(let data): self.handle(data)
                case .string(let text): self.handle(Data(text.utf8))
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    private func handle(_ data: Data) {
        guard let msg = try? decoder.decode(ServerMessage.self, from: data) else { return }
        if msg.setupComplete != nil { onEvent?(.setupComplete) }
        if msg.goAway != nil { onEvent?(.goAway) }
        guard let sc = msg.serverContent else { return }
        for part in sc.modelTurn?.parts ?? [] {
            if let b64 = part.inlineData?.data, let audio = Data(base64Encoded: b64) {
                onEvent?(.audio(audio))
            }
        }
        if sc.interrupted == true { onEvent?(.interrupted) }
        if let t = sc.inputTranscription?.text, !t.isEmpty { onEvent?(.userTranscript(t)) }
        if let t = sc.outputTranscription?.text, !t.isEmpty { onEvent?(.modelTranscript(t)) }
        if sc.turnComplete == true { onEvent?(.turnComplete) }
    }

    private func reportClosed(_ error: Error?) {
        guard !closedReported else { return }
        closedReported = true
        pingTimer?.invalidate()
        pingTimer = nil
        onEvent?(.closed(error))
    }

    private func startPings() {
        pingTimer?.invalidate()
        // keep NATs/proxies from dropping the socket during long silences
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.task?.sendPing { error in
                if let error { self?.reportClosed(error) }
            }
        }
    }
}
