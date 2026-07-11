import Foundation

/// Atomic JSON persistence for Sakura's memory, in Application Support.
/// An actor so session bookkeeping, turn capture and extraction can be called
/// from anywhere without racing; every mutation is written to disk atomically.
actor MemoryStore {
    private let fileURL: URL
    private var record: MemoryRecord
    private var extracting = false

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Pass a directory for tests; defaults to Application Support/Sakura.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sakura", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("memory.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? Self.decoder.decode(MemoryRecord.self, from: data) {
            record = loaded
        } else {
            record = MemoryRecord()
        }
    }

    var current: MemoryRecord { record }
    nonisolated var storageURL: URL { fileURL }

    /// New session: bump the counter (mirrors touch_user in the web app).
    func touchSession() {
        record.interactionCount += 1
        record.lastSeenAt = Date()
        save()
    }

    /// Buffer one completed transcript turn for later extraction.
    func addTurn(role: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record.pendingTurns.append(MemoryTurn(role: role, text: trimmed))
        if record.pendingTurns.count > MemoryLimits.maxPendingTurns {
            record.pendingTurns.removeFirst(record.pendingTurns.count - MemoryLimits.maxPendingTurns)
        }
        save()
    }

    /// Manual edit from the memory screen.
    func replaceDocument(_ doc: MemoryDocument) {
        record.memory = doc.bounded()
        record.updatedAt = Date()
        save()
    }

    /// Sakura forgets everything: fresh record, file removed.
    func clear() {
        record = MemoryRecord()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Fold pending turns into the document via `extract` (a Gemini text call
    /// in production, a stub in tests). Any failure leaves the record — and
    /// the pending turns — exactly as they were.
    @discardableResult
    func runExtraction(
        _ extract: (MemoryDocument, [MemoryTurn]) async throws -> MemoryDocument
    ) async -> Bool {
        guard !extracting else { return false }  // actor reentrancy guard
        let turns = Array(record.pendingTurns.prefix(MemoryLimits.maxTurnsPerExtraction))
        guard turns.count >= MemoryLimits.minTurnsForUpdate else { return false }
        extracting = true
        defer { extracting = false }

        let newDoc: MemoryDocument
        do {
            newDoc = try await extract(record.memory.bounded(), turns)
        } catch {
            return false
        }
        record.memory = newDoc.bounded()
        record.pendingTurns.removeFirst(min(turns.count, record.pendingTurns.count))
        record.updatedAt = Date()
        save()
        return true
    }

    private func save() {
        guard let data = try? Self.encoder.encode(record) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
