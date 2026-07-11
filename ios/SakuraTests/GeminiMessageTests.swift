import XCTest
@testable import Sakura

final class GeminiMessageTests: XCTestCase {
    // MARK: Server → client parsing

    func testParsesSetupComplete() throws {
        let msg = try decode(#"{"setupComplete": {}}"#)
        XCTAssertNotNil(msg.setupComplete)
        XCTAssertNil(msg.serverContent)
    }

    func testParsesAudioChunk() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let json = """
        {"serverContent": {"modelTurn": {"parts": [
            {"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": "\(pcm.base64EncodedString())"}}
        ]}}}
        """
        let msg = try decode(json)
        let b64 = msg.serverContent?.modelTurn?.parts?.first?.inlineData?.data
        XCTAssertEqual(Data(base64Encoded: b64 ?? ""), pcm)
    }

    func testParsesInterruptionAndTurnComplete() throws {
        let msg = try decode(#"{"serverContent": {"interrupted": true, "turnComplete": true}}"#)
        XCTAssertEqual(msg.serverContent?.interrupted, true)
        XCTAssertEqual(msg.serverContent?.turnComplete, true)
    }

    func testParsesTranscriptions() throws {
        let msg = try decode(
            #"{"serverContent": {"inputTranscription": {"text": "hello"}, "outputTranscription": {"text": "hi!"}}}"#)
        XCTAssertEqual(msg.serverContent?.inputTranscription?.text, "hello")
        XCTAssertEqual(msg.serverContent?.outputTranscription?.text, "hi!")
    }

    func testParsesGoAway() throws {
        let msg = try decode(#"{"goAway": {"timeLeft": "10s"}}"#)
        XCTAssertNotNil(msg.goAway)
    }

    func testUnknownFieldsAreIgnored() throws {
        let msg = try decode(#"{"serverContent": {"someFutureField": {"x": 1}, "turnComplete": true}}"#)
        XCTAssertEqual(msg.serverContent?.turnComplete, true)
    }

    private func decode(_ json: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
    }

    // MARK: Client → server encoding

    func testSetupMessageMirrorsWebServerConfig() throws {
        let setup = ClientMessage.Setup.sakura(systemInstruction: "You are Sakura.")
        let data = try JSONEncoder().encode(ClientMessage(setup: setup))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let s = try XCTUnwrap(obj["setup"] as? [String: Any])

        XCTAssertEqual(s["model"] as? String, "models/gemini-3.1-flash-live-preview")
        let gen = try XCTUnwrap(s["generationConfig"] as? [String: Any])
        XCTAssertEqual(gen["responseModalities"] as? [String], ["AUDIO"])
        let voice = ((gen["speechConfig"] as? [String: Any])?["voiceConfig"] as? [String: Any])?[
            "prebuiltVoiceConfig"] as? [String: Any]
        XCTAssertEqual(voice?["voiceName"] as? String, "Leda")

        let vad = (s["realtimeInputConfig"] as? [String: Any])?["automaticActivityDetection"] as? [String: Any]
        XCTAssertEqual(vad?["startOfSpeechSensitivity"] as? String, "START_SENSITIVITY_HIGH")
        XCTAssertEqual(vad?["prefixPaddingMs"] as? Int, 100)

        XCTAssertNotNil(s["inputAudioTranscription"])
        XCTAssertNotNil(s["outputAudioTranscription"])
        let cwc = try XCTUnwrap(s["contextWindowCompression"] as? [String: Any])
        XCTAssertEqual(cwc["triggerTokens"] as? Int, 104857)
        XCTAssertEqual((cwc["slidingWindow"] as? [String: Any])?["targetTokens"] as? Int, 52428)

        let instruction = (s["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
        XCTAssertEqual(instruction?.first?["text"] as? String, "You are Sakura.")
    }

    func testRealtimeAudioMessageEncoding() throws {
        let pcm = Data([0, 1, 2, 3])
        let msg = ClientMessage(realtimeInput: .init(
            audio: .init(data: pcm.base64EncodedString(), mimeType: "audio/pcm;rate=16000")))
        let json = String(decoding: try JSONEncoder().encode(msg), as: UTF8.self)
        XCTAssertTrue(json.contains("\"mimeType\":\"audio\\/pcm;rate=16000\"")
                      || json.contains("\"mimeType\":\"audio/pcm;rate=16000\""))
        XCTAssertTrue(json.contains(pcm.base64EncodedString()))
        XCTAssertFalse(json.contains("setup"), "audio messages must contain exactly one top-level field")
    }

    func testTextMessageEncoding() throws {
        let msg = ClientMessage(clientContent: .init(turns: [.user("hello")], turnComplete: true))
        let data = try JSONEncoder().encode(msg)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cc = try XCTUnwrap(obj["clientContent"] as? [String: Any])
        XCTAssertEqual(cc["turnComplete"] as? Bool, true)
        let turn = (cc["turns"] as? [[String: Any]])?.first
        XCTAssertEqual(turn?["role"] as? String, "user")
    }
}
