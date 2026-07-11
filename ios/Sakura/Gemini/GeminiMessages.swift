import Foundation

/// Codable mirrors of the Gemini Live WebSocket protocol
/// (v1beta BidiGenerateContent). Only the fields Sakura uses.

struct EmptyObject: Codable {}

struct TextContent: Codable {
    var role: String?
    var parts: [Part]
    struct Part: Codable { var text: String }

    static func user(_ text: String) -> TextContent {
        TextContent(role: "user", parts: [Part(text: text)])
    }
}

// MARK: - Client → server

struct ClientMessage: Encodable {
    var setup: Setup?
    var realtimeInput: RealtimeInput?
    var clientContent: ClientContent?
    var toolResponse: ToolResponse?

    struct Setup: Encodable {
        var model: String
        var generationConfig: GenerationConfig
        var systemInstruction: TextContent
        var realtimeInputConfig: RealtimeInputConfig
        var inputAudioTranscription = EmptyObject()
        var outputAudioTranscription = EmptyObject()
        var contextWindowCompression: ContextWindowCompression
        var tools: [Tool]

        struct GenerationConfig: Encodable {
            var responseModalities: [String]
            var speechConfig: SpeechConfig
        }
        struct SpeechConfig: Encodable {
            var voiceConfig: VoiceConfig
            struct VoiceConfig: Encodable {
                var prebuiltVoiceConfig: Prebuilt
                struct Prebuilt: Encodable { var voiceName: String }
            }
        }
        struct RealtimeInputConfig: Encodable {
            var automaticActivityDetection: Detection
            struct Detection: Encodable {
                var startOfSpeechSensitivity: String
                var prefixPaddingMs: Int
            }
        }
        struct ContextWindowCompression: Encodable {
            var triggerTokens: Int
            var slidingWindow: SlidingWindow
            struct SlidingWindow: Encodable { var targetTokens: Int }
        }
        struct Tool: Encodable {
            var functionDeclarations: [FunctionDeclaration]
            struct FunctionDeclaration: Encodable {
                var name: String
                var description: String
                var parameters: Schema
            }
            struct Schema: Encodable {
                var type = "OBJECT"
                var properties: [String: Property]
                var required: [String]
                struct Property: Encodable {
                    var type = "STRING"
                    var `enum`: [String]
                }
            }
        }

        /// Mirrors build_config() in server.py: audio out, per-character voice,
        /// eager barge-in VAD, both transcriptions, context compression.
        static func make(for character: Character, systemInstruction: String) -> Setup {
            Setup(
                model: Gemini.liveModel,
                generationConfig: GenerationConfig(
                    responseModalities: ["AUDIO"],
                    speechConfig: SpeechConfig(
                        voiceConfig: .init(prebuiltVoiceConfig: .init(voiceName: character.voiceName))
                    )
                ),
                systemInstruction: TextContent(role: nil, parts: [.init(text: systemInstruction)]),
                realtimeInputConfig: RealtimeInputConfig(
                    automaticActivityDetection: .init(
                        startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
                        prefixPaddingMs: 100
                    )
                ),
                contextWindowCompression: ContextWindowCompression(
                    triggerTokens: 104_857,
                    slidingWindow: .init(targetTokens: 52_428)
                ),
                // enum values come from the real wardrobe, so the model can
                // never request an outfit or place the app doesn't have
                tools: [Tool(functionDeclarations: [
                    .init(name: "set_outfit",
                          description: "Change the outfit you are wearing. Call only after the user has clearly agreed to the change.",
                          parameters: .init(properties: ["outfit": .init(enum: character.outfits.map(\.clean))],
                                            required: ["outfit"])),
                    .init(name: "set_background",
                          description: "Move the scene to a different location ('Sakura' is a cherry-blossom garden). Call only after the user has clearly agreed to go there.",
                          parameters: .init(properties: ["background": .init(enum: Backdrop.all.map(\.clean))],
                                            required: ["background"])),
                ])]
            )
        }
    }

    struct RealtimeInput: Encodable {
        var audio: Blob
        struct Blob: Encodable {
            var data: String      // base64 pcm16
            var mimeType: String  // "audio/pcm;rate=16000"
        }
    }

    struct ClientContent: Encodable {
        var turns: [TextContent]
        var turnComplete: Bool
    }

    struct ToolResponse: Encodable {
        var functionResponses: [FunctionResponse]
        struct FunctionResponse: Encodable {
            var id: String?
            var name: String
            var response: [String: String]
        }
    }
}

// MARK: - Server → client

struct ServerMessage: Decodable {
    var setupComplete: EmptyObject?
    var serverContent: ServerContent?
    var toolCall: ToolCall?
    var goAway: GoAway?

    struct ServerContent: Decodable {
        var modelTurn: ModelTurn?
        var interrupted: Bool?
        var turnComplete: Bool?
        var generationComplete: Bool?
        var inputTranscription: Transcription?
        var outputTranscription: Transcription?
    }
    struct ModelTurn: Decodable { var parts: [Part]? }
    struct Part: Decodable {
        var text: String?
        var inlineData: InlineData?
        struct InlineData: Decodable {
            var mimeType: String?
            var data: String?  // base64 pcm16 @ 24 kHz
        }
    }
    struct Transcription: Decodable { var text: String? }
    struct GoAway: Decodable { var timeLeft: String? }

    struct ToolCall: Decodable {
        var functionCalls: [FunctionCall]?
        // our tools only declare STRING enum params, so [String: String] args
        // decode everything Gemini can legally send for them
        struct FunctionCall: Decodable {
            var id: String?
            var name: String?
            var args: [String: String]?
        }
    }
}
