import Foundation

/// Accumulates streaming transcript fragments and yields whole turns —
/// mirrors the `bufs`/`flush` pattern in server.py. A turn is persisted only
/// when it completes (or is interrupted, keeping what was actually said).
struct TurnBuffer {
    private var buffers: [String: String] = [:]

    mutating func append(role: String, text: String) {
        buffers[role, default: ""] += text
    }

    /// Returns the consolidated turn (trimmed) and resets it; nil when empty.
    mutating func flush(_ role: String) -> String? {
        let text = (buffers[role] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        buffers[role] = ""
        return text.isEmpty ? nil : text
    }

    /// Session teardown: whatever is left, in a stable order.
    mutating func flushAll() -> [(role: String, text: String)] {
        ["user", "sakura"].compactMap { role in
            flush(role).map { (role, $0) }
        }
    }
}
