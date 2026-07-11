import Foundation

/// Background memory extraction: one fast Gemini text request with JSON
/// output, run after meaningful turns or at session end — never in the voice
/// path. Prompt ported verbatim from memory.py.
struct MemoryExtractor {
    var apiKey: String
    var model = Gemini.memoryModel

    enum ExtractionError: Error { case badResponse, emptyText }

    func extract(old: MemoryDocument, turns: [MemoryTurn]) async throws -> MemoryDocument {
        let prompt = Self.prompt(old: old, turns: turns)
        var request = URLRequest(url: URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExtractionError.badResponse
        }
        struct Reply: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { var text: String? }
                    var parts: [Part]?
                }
                var content: Content?
            }
            var candidates: [Candidate]?
        }
        let text = try JSONDecoder().decode(Reply.self, from: data)
            .candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```json") { body = String(body.dropFirst(7)) }
        if body.hasPrefix("```") { body = String(body.dropFirst(3)) }
        if body.hasSuffix("```") { body = String(body.dropLast(3)) }
        guard let jsonData = body.data(using: .utf8), !body.isEmpty else {
            throw ExtractionError.emptyText
        }
        return try JSONDecoder().decode(MemoryDocument.self, from: jsonData)
    }

    static func prompt(old: MemoryDocument, turns: [MemoryTurn]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let oldJSON = String(decoding: (try? encoder.encode(old)) ?? Data("{}".utf8), as: UTF8.self)
        let convo = turns.map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        return """
        You maintain the long-term memory document that a voice companion called Sakura
        keeps about one specific user. Merge the new conversation turns into the memory.

        Return ONLY a JSON object, no other text, with exactly this shape:
        {"profile": {"preferred_name": <string or null>, "facts": [<strings>], "preferences": [<strings>], "projects": [<strings>]}, "relationship_summary": <string>}

        KEEP only:
        - facts the user explicitly stated about themselves
        - durable preferences
        - recurring projects, people or topics likely to matter in later chats
        - commitments or unresolved threads worth following up on

        DO NOT keep:
        - guesses or inferred personal attributes
        - claims Sakura made that the user did not confirm
        - transient small talk, duplicates, or details contradicted by newer statements (keep the newest)
        - sensitive information that is not clearly useful for future conversation

        Limits: at most \(MemoryLimits.maxFacts) facts, \(MemoryLimits.maxPreferences) preferences, \(MemoryLimits.maxProjects) projects, each under 25 words.
        relationship_summary: under \(MemoryLimits.maxSummaryChars / 6) words, written as Sakura's own brief diary-style notes.
        Output the COMPLETE replacement memory — restate old items you are keeping.

        CURRENT MEMORY:
        \(oldJSON)

        NEW CONVERSATION TURNS:
        \(convo)
        """
    }
}
