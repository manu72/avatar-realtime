import XCTest
@testable import Sakura

final class MemoryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sakura-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleDoc() -> MemoryDocument {
        MemoryDocument(
            profile: .init(preferredName: "Manu",
                           facts: ["lives in Sydney"],
                           preferences: ["likes short replies"],
                           projects: ["avatar app"]),
            relationshipSummary: "We talk about code."
        )
    }

    // MARK: Codable

    func testDocumentRoundTripUsesSnakeCaseKeys() throws {
        let data = try JSONEncoder().encode(sampleDoc())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"preferred_name\""))
        XCTAssertTrue(json.contains("\"relationship_summary\""))
        let back = try JSONDecoder().decode(MemoryDocument.self, from: data)
        XCTAssertEqual(back, sampleDoc())
    }

    func testDecodingTolerantOfMissingAndNullFields() throws {
        let json = #"{"profile": {"preferred_name": null, "facts": ["x"]}}"#
        let doc = try JSONDecoder().decode(MemoryDocument.self, from: Data(json.utf8))
        XCTAssertNil(doc.profile.preferredName)
        XCTAssertEqual(doc.profile.facts, ["x"])
        XCTAssertEqual(doc.relationshipSummary, "")
    }

    // MARK: Bounding

    func testBoundedClipsListsAndLengths() {
        var doc = MemoryDocument()
        doc.profile.facts = (0..<40).map { "fact \($0) " + String(repeating: "x", count: 300) }
        doc.profile.preferredName = String(repeating: "n", count: 500)
        doc.relationshipSummary = String(repeating: "s", count: 5000)
        let bounded = doc.bounded()
        XCTAssertEqual(bounded.profile.facts.count, MemoryLimits.maxFacts)
        XCTAssertEqual(bounded.profile.facts[0].count, MemoryLimits.maxItemChars)
        XCTAssertEqual(bounded.profile.preferredName?.count, 80)
        XCTAssertEqual(bounded.relationshipSummary.count, MemoryLimits.maxSummaryChars)
    }

    // MARK: Store: file creation, atomic replacement, clearing

    func testStoreCreatesFileOnFirstSave() async throws {
        let store = MemoryStore(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
        await store.touchSession()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    func testStorePersistsAcrossInstances() async throws {
        let store = MemoryStore(directory: dir)
        await store.touchSession()
        await store.replaceDocument(sampleDoc())

        let reopened = MemoryStore(directory: dir)
        let record = await reopened.current
        XCTAssertEqual(record.interactionCount, 1)
        XCTAssertEqual(record.memory, sampleDoc())
    }

    func testReplaceDocumentAtomicallySwapsContent() async throws {
        let store = MemoryStore(directory: dir)
        await store.replaceDocument(sampleDoc())
        var second = sampleDoc()
        second.profile.preferredName = "Someone Else"
        await store.replaceDocument(second)

        let onDisk = try Data(contentsOf: store.storageURL)
        let record = try {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return try d.decode(MemoryRecord.self, from: onDisk)
        }()
        XCTAssertEqual(record.memory.profile.preferredName, "Someone Else")
    }

    func testClearForgetsEverythingAndRemovesFile() async throws {
        let store = MemoryStore(directory: dir)
        await store.touchSession()
        await store.addTurn(role: "user", text: "hi")
        await store.clear()

        let record = await store.current
        XCTAssertEqual(record.interactionCount, 0)
        XCTAssertTrue(record.pendingTurns.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageURL.path))
    }

    // MARK: Extraction

    func testFailedExtractionPreservesOldRecordAndTurns() async throws {
        let store = MemoryStore(directory: dir)
        await store.replaceDocument(sampleDoc())
        await store.addTurn(role: "user", text: "my dog is called Mochi")
        await store.addTurn(role: "sakura", text: "cute!")

        struct Boom: Error {}
        let ok = await store.runExtraction { _, _ in throw Boom() }
        XCTAssertFalse(ok)

        let record = await store.current
        XCTAssertEqual(record.memory, sampleDoc())
        XCTAssertEqual(record.pendingTurns.count, 2)
    }

    func testSuccessfulExtractionReplacesMemoryAndConsumesTurns() async throws {
        let store = MemoryStore(directory: dir)
        await store.addTurn(role: "user", text: "call me Manu")
        await store.addTurn(role: "sakura", text: "okay, Manu!")

        var newDoc = MemoryDocument()
        newDoc.profile.preferredName = "Manu"
        let ok = await store.runExtraction { old, turns in
            XCTAssertTrue(old.isEmpty)
            XCTAssertEqual(turns.count, 2)
            return newDoc
        }
        XCTAssertTrue(ok)

        let record = await store.current
        XCTAssertEqual(record.memory.profile.preferredName, "Manu")
        XCTAssertTrue(record.pendingTurns.isEmpty)
    }

    func testExtractionSkippedBelowMinimumTurns() async throws {
        let store = MemoryStore(directory: dir)
        await store.addTurn(role: "user", text: "hi")
        let ok = await store.runExtraction { _, _ in
            XCTFail("extractor should not run for a single turn")
            return MemoryDocument()
        }
        XCTAssertFalse(ok)
    }

    func testTurnBacklogIsBounded() async throws {
        let store = MemoryStore(directory: dir)
        for i in 0..<(MemoryLimits.maxPendingTurns + 25) {
            await store.addTurn(role: "user", text: "turn \(i)")
        }
        let record = await store.current
        XCTAssertEqual(record.pendingTurns.count, MemoryLimits.maxPendingTurns)
        XCTAssertEqual(record.pendingTurns.last?.text, "turn \(MemoryLimits.maxPendingTurns + 24)")
    }

    // MARK: Formatting

    func testFormatMemorySectionEmptyForFirstMeeting() {
        var record = MemoryRecord()
        record.interactionCount = 1
        XCTAssertEqual(formatMemorySection(record), "")
    }

    func testFormatMemorySectionIncludesContentAndIsBounded() {
        var record = MemoryRecord()
        record.interactionCount = 3
        record.memory = sampleDoc()
        record.memory.relationshipSummary = String(repeating: "long note ", count: 800)
        let section = formatMemorySection(record)
        XCTAssertTrue(section.contains("They like to be called: Manu"))
        XCTAssertTrue(section.contains("chatted 2 time(s) before"))
        XCTAssertTrue(section.contains("lives in Sydney"))
        XCTAssertLessThanOrEqual(section.count, MemoryLimits.sectionMaxChars)
    }

    func testExtractorPromptEmbedsMemoryAndTurns() {
        let prompt = MemoryExtractor.prompt(
            old: sampleDoc(),
            turns: [MemoryTurn(role: "user", text: "I got a cat")]
        )
        XCTAssertTrue(prompt.contains("\"preferred_name\""))
        XCTAssertTrue(prompt.contains("user: I got a cat"))
        XCTAssertTrue(prompt.contains("at most \(MemoryLimits.maxFacts) facts"))
    }
}
