import XCTest
@testable import CardScoutCore

final class ScanReviewTests: XCTestCase {
    private func fixture() -> Library {
        var a = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [], confidence: "low", conditionNotes: "", rationale: "", needsReview: true)
        a.player = "Fixture Player"; a.year = 2025; a.setName = "Chrome"; a.brand = "Topps"; a.identityConfirmed = false
        a.uncertainties = ["Card number unclear", "Serial stamp is unreadable"]
        var library = Library()
        library.cards = [OwnedCard(id: "fixture", state: "analyzed", frontFile: "front", backFile: "back", analysis: a)]
        return library
    }
    func testPartialReadingsSurviveRelaunchWithoutConfirmingOrQueuingIdentity() throws {
        var library = fixture()
        let before = library.cards[0]
        XCTAssertTrue(before.scanChecks.contains(.reading(.number)))
        XCTAssertTrue(before.scanChecks.contains(.reading(.serial)))
        try library.recordReading(.number, raw: "#RC-04", cardID: before.id, jobID: before.jobID, reopen: false)
        let restored = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library)).cards[0]
        XCTAssertFalse(restored.scanChecks.contains(.reading(.number)))
        XCTAssertTrue(restored.scanChecks.contains(.reading(.serial)))
        XCTAssertEqual(restored.analysis, before.analysis); XCTAssertEqual(restored.jobID, before.jobID)
        XCTAssertEqual(restored.printedReadings?["number"], "RC-04")
        XCTAssertTrue(restored.analysisTextWithReadings?.contains("RC-04") == true)
        XCTAssertNil(PrintedField.serial.normalized("100/99")); XCTAssertNil(PrintedField.serial.normalized("0/99"))
        XCTAssertEqual(PrintedField.serial.normalized("018 / 099"), "018/099")
    }
    func testReopenRequiresExplicitDecisionAndRejectsStaleRevisions() throws {
        var library = fixture()
        library.cards[0].analysis?.cardNumber = "15"; library.cards[0].isScanDraft = true
        let old = library.cards[0]
        XCTAssertThrowsError(try library.recordReading(.number, raw: "5", cardID: old.id, jobID: old.jobID, reopen: false))
        try library.recordReading(.number, raw: "5", cardID: old.id, jobID: old.jobID, reopen: true)
        let card = library.cards[0]
        XCTAssertEqual(card.state, "unidentified"); XCTAssertEqual(card.isScanDraft, true)
        XCTAssertEqual(card.frontFile, old.frontFile); XCTAssertEqual(card.backFile, old.backFile)
        XCTAssertNotEqual(card.jobID, old.jobID); XCTAssertEqual(card.scanChecks, [])
        XCTAssertTrue(library.supersededJobIDs?.contains(old.jobID) == true)
        XCTAssertThrowsError(try library.declineScanMatch(cardID: old.id, jobID: old.jobID))
    }
    func testLaterWorkerResultCannotConfirmAContradictoryReading() throws {
        var library = fixture()
        let card = library.cards[0]
        try library.recordReading(.number, raw: "15", cardID: card.id, jobID: card.jobID, reopen: false)
        library.cards[0].captureText = String(repeating: "A", count: 2_000)
        XCTAssertEqual(library.cards[0].analysisTextWithReadings?.count, 2_000)
        var returned = try XCTUnwrap(card.analysis)
        returned.cardNumber = "55"; returned.collectionID = "other"; returned.identityConfirmed = true
        returned.marketLowCents = 500
        XCTAssertTrue(try library.applyJobResult(cardID: card.id, jobID: card.jobID, status: "analyzed", analysis: returned, collection: nil, error: nil))
        XCTAssertEqual(library.cards[0].analysis?.identityConfirmed, false)
        XCTAssertNil(library.cards[0].analysis?.marketLowCents)
        XCTAssertNil(library.cards[0].analysis?.collectionID)
    }
    func testProcessingAndCatalogGapsDoNotDemandPhotoChecks() {
        var c = fixture().cards[0]
        c.state = "processing"; XCTAssertTrue(c.scanChecks.isEmpty)
        c.state = "failed"; XCTAssertTrue(c.scanChecks.isEmpty)
        c.state = "unidentified"; c.matchNotice = "catalog_missing"; XCTAssertTrue(c.scanChecks.isEmpty)
        c.awaitingBack = true; XCTAssertEqual(c.scanChecks, [.photo(.back)])
    }
    func testPrintedNumberFiltersChecklistRowsWhenTheWorkerSuggestionDisagrees() throws {
        var library = fixture()
        let entries = ["4","228"].map { ChecklistCard(number: $0, player: "Fixture Player", team: "Demo") }
        library.collections = [CardCollection(id: "set", name: "Demo", year: 2025, brand: "Demo", cards: entries)]
        library.cards[0].matchSuggestions = [.init(collectionID: "set", number: "228")]
        let card = library.cards[0]
        try library.recordReading(.number, raw: "4", cardID: card.id, jobID: card.jobID, reopen: false)
        XCTAssertEqual(library.reviewMatches(for: library.cards[0]).map(\.number), ["4"])
    }
}
