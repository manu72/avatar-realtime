import XCTest
@testable import Sakura

final class TranscriptTests: XCTestCase {
    func testFragmentsConsolidateIntoOneTurn() {
        var buf = TurnBuffer()
        buf.append(role: "user", text: "hel")
        buf.append(role: "user", text: "lo the")
        buf.append(role: "user", text: "re")
        XCTAssertEqual(buf.flush("user"), "hello there")
        XCTAssertNil(buf.flush("user"), "flush must reset the buffer")
    }

    func testRolesAreIndependent() {
        var buf = TurnBuffer()
        buf.append(role: "user", text: "hi")
        buf.append(role: "sakura", text: "hey!")
        XCTAssertEqual(buf.flush("sakura"), "hey!")
        XCTAssertEqual(buf.flush("user"), "hi")
    }

    func testWhitespaceOnlyTurnsAreDropped() {
        var buf = TurnBuffer()
        buf.append(role: "sakura", text: "   \n ")
        XCTAssertNil(buf.flush("sakura"))
    }

    func testInterruptedTurnKeepsWhatWasSaid() {
        var buf = TurnBuffer()
        buf.append(role: "sakura", text: "I was about to say som")
        // interruption flushes sakura only — the user's in-flight turn survives
        buf.append(role: "user", text: "wait")
        XCTAssertEqual(buf.flush("sakura"), "I was about to say som")
        XCTAssertEqual(buf.flush("user"), "wait")
    }

    func testFlushAllReturnsRemainingTurnsInStableOrder() {
        var buf = TurnBuffer()
        buf.append(role: "sakura", text: "bye!")
        buf.append(role: "user", text: "see you")
        let turns = buf.flushAll()
        XCTAssertEqual(turns.map(\.role), ["user", "sakura"])
        XCTAssertEqual(turns.map(\.text), ["see you", "bye!"])
        XCTAssertTrue(buf.flushAll().isEmpty)
    }
}
