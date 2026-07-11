import Foundation

/// Size limits, ported from memory.py so both apps keep memory equally bounded.
enum MemoryLimits {
    static let maxFacts = 15
    static let maxPreferences = 10
    static let maxProjects = 8
    static let maxSummaryChars = 600
    static let maxItemChars = 200
    static let sectionMaxChars = 4000        // ~1k tokens injected into the system prompt
    static let updateTurnThreshold = 12      // extract every N recorded turns mid-session
    static let minTurnsForUpdate = 2
    static let maxTurnsPerExtraction = 80
    static let maxPendingTurns = 160         // hard cap on the stored turn backlog
}

/// The memory document itself. JSON keys are snake_case to stay byte-for-byte
/// compatible with the web app's document shape (the extraction prompt embeds
/// and expects exactly this JSON).
struct MemoryDocument: Codable, Equatable {
    struct Profile: Codable, Equatable {
        var preferredName: String?
        var facts: [String] = []
        var preferences: [String] = []
        var projects: [String] = []

        enum CodingKeys: String, CodingKey {
            case preferredName = "preferred_name", facts, preferences, projects
        }

        init(preferredName: String? = nil, facts: [String] = [],
             preferences: [String] = [], projects: [String] = []) {
            self.preferredName = preferredName
            self.facts = facts
            self.preferences = preferences
            self.projects = projects
        }

        // Lenient decoding: the extractor is an LLM; missing/null fields must
        // not throw the whole document away.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            preferredName = try? c.decodeIfPresent(String.self, forKey: .preferredName)
            facts = (try? c.decodeIfPresent([String].self, forKey: .facts)) ?? []
            preferences = (try? c.decodeIfPresent([String].self, forKey: .preferences)) ?? []
            projects = (try? c.decodeIfPresent([String].self, forKey: .projects)) ?? []
        }
    }

    var profile = Profile()
    var relationshipSummary = ""

    enum CodingKeys: String, CodingKey {
        case profile, relationshipSummary = "relationship_summary"
    }

    init(profile: Profile = Profile(), relationshipSummary: String = "") {
        self.profile = profile
        self.relationshipSummary = relationshipSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = (try? c.decodeIfPresent(Profile.self, forKey: .profile)) ?? Profile()
        relationshipSummary = (try? c.decodeIfPresent(String.self, forKey: .relationshipSummary)) ?? ""
    }

    var isEmpty: Bool {
        profile.preferredName == nil && profile.facts.isEmpty && profile.preferences.isEmpty
            && profile.projects.isEmpty && relationshipSummary.isEmpty
    }

    /// Port of bound_memory(): coerce into a valid, size-bounded document.
    func bounded() -> MemoryDocument {
        func clip(_ items: [String], _ max: Int) -> [String] {
            items.map { String($0.prefix(MemoryLimits.maxItemChars)) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(max).map { $0 }
        }
        var name: String?
        if let n = profile.preferredName, !n.isEmpty { name = String(n.prefix(80)) }
        return MemoryDocument(
            profile: Profile(
                preferredName: name,
                facts: clip(profile.facts, MemoryLimits.maxFacts),
                preferences: clip(profile.preferences, MemoryLimits.maxPreferences),
                projects: clip(profile.projects, MemoryLimits.maxProjects)
            ),
            relationshipSummary: String(relationshipSummary.prefix(MemoryLimits.maxSummaryChars))
        )
    }
}

struct MemoryTurn: Codable, Equatable {
    var role: String   // "user" | "sakura"
    var text: String
}

/// Everything persisted on disk: the document plus counters, timestamps and
/// the not-yet-extracted transcript turns (replaces the web app's SQLite
/// `users` + `turns` tables with one atomic JSON file).
struct MemoryRecord: Codable {
    var memory = MemoryDocument()
    var interactionCount = 0
    var firstSeenAt = Date()
    var lastSeenAt = Date()
    var updatedAt = Date()
    var pendingTurns: [MemoryTurn] = []
}

/// Port of format_memory_section(): plain-text block appended to the persona.
/// Returns "" when there is nothing worth injecting (true first meeting).
func formatMemorySection(_ record: MemoryRecord) -> String {
    let mem = record.memory.bounded()
    let p = mem.profile
    let pastChats = max(0, record.interactionCount - 1)
    if mem.isEmpty && pastChats == 0 { return "" }

    var lines = [
        "=== YOUR MEMORY OF THIS FRIEND (from past chats) ===",
        "These notes may be incomplete. NEVER invent details that are not written here —",
        "if something isn't in these notes you simply don't remember it; say so naturally.",
    ]
    if pastChats > 0 {
        let firstMet = ISO8601DateFormatter().string(from: record.firstSeenAt).prefix(10)
        lines.append("You have chatted \(pastChats) time(s) before (first met \(firstMet)). "
            + "Do NOT introduce yourself as if this were a first meeting.")
    }
    if let name = p.preferredName { lines.append("They like to be called: \(name)") }
    if !p.facts.isEmpty { lines.append("Facts they told you: " + p.facts.joined(separator: "; ")) }
    if !p.preferences.isEmpty { lines.append("Their preferences: " + p.preferences.joined(separator: "; ")) }
    if !p.projects.isEmpty { lines.append("Their projects / recurring topics: " + p.projects.joined(separator: "; ")) }
    if !mem.relationshipSummary.isEmpty { lines.append("Your relationship so far: " + mem.relationshipSummary) }
    lines.append("=== END MEMORY ===")
    return String(lines.joined(separator: "\n").prefix(MemoryLimits.sectionMaxChars))
}
