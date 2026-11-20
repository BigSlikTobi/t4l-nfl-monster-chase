import XCTest
@testable import CardScoutCore

final class RemovedCardsTests: XCTestCase {
    func testOneDuplicateCanBeRemovedAndRestoredAcrossReloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        let checklist = CardCollection(id: "paper", name: "Bowman", year: 2026, brand: "Topps", subset: "Paper Prospects",
                                       cards: [ChecklistCard(number: "BPP-118", player: "Bo Jackson", team: "Ohio State")])
        var analysis = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [], confidence: "high",
                                    conditionNotes: "", rationale: "", needsReview: false)
        analysis.collectionID = checklist.id
        analysis.player = "Bo Jackson"
        analysis.cardNumber = "BPP-118"
        analysis.identityConfirmed = true
        let retained = OwnedCard(id: "first", state: "analyzed", frontFile: "first.jpg", analysis: analysis)
        var duplicate = OwnedCard(id: "second", state: "analyzed", frontFile: "second.jpg", backFile: "second-back.jpg", analysis: analysis)
        duplicate.notes = "Second scan"
        duplicate.isFavorite = true
        var library = Library()
        library.cards = [duplicate, retained]
        library.collections = [checklist]
        let folder = CardFolder(name: "Bowman", cardIDs: [duplicate.id])
        library.folders = [folder]
        try library.setPersonalPrice(cardID: duplicate.id, amountCents: 125, currency: "USD")
        duplicate = try XCTUnwrap(library.cards.first)
        for photo in [retained.frontFile, duplicate.frontFile, try XCTUnwrap(duplicate.backFile)] {
            try disk.writePhoto(Data(photo.utf8), name: photo)
        }
        XCTAssertTrue(library.recordPortfolioObservation())

        try library.removeCard(duplicate.id)
        XCTAssertThrowsError(try library.removeCard(duplicate.id))
        try disk.save(library)
        library = try disk.load()
        XCTAssertEqual(library.cards, [retained])
        XCTAssertEqual(library.removedCards, [duplicate])
        XCTAssertEqual(library.folders, [folder])
        XCTAssertEqual(checklist.owned(for: "BPP-118", in: library.cards), [retained])
        XCTAssertEqual(checklist.ownedCount(in: library.cards), 1)
        let stats = CollectionStatistics(library: library)
        XCTAssertEqual(stats.duplicateExtras, 0)
        XCTAssertTrue(stats.values.isEmpty)
        XCTAssertNotNil(library.portfolioHistory?.last?.values.first)
        XCTAssertNil(InsightValuation(statistics: stats, history: library.portfolioHistory ?? [], selected: "USD").lowCents)

        try library.restoreCard(duplicate.id)
        XCTAssertThrowsError(try library.restoreCard(duplicate.id))
        try disk.save(library)
        library = try disk.load()
        XCTAssertNil(library.removedCards)
        XCTAssertEqual(library.cards, [duplicate, retained])
        XCTAssertEqual(checklist.owned(for: "BPP-118", in: library.cards).count, 2)
        XCTAssertEqual(CollectionStatistics(library: library).values.first?.lowCents, 125)
        for photo in [retained.frontFile, duplicate.frontFile, try XCTUnwrap(duplicate.backFile)] {
            XCTAssertEqual(try Data(contentsOf: disk.photoURL(photo)), Data(photo.utf8))
        }
    }

    func testRestoringAnInFlightScanResumesWithAFreshRevision() throws {
        var library = Library()
        let pending = OwnedCard(state: "processing", frontFile: "front.jpg", backFile: "back.jpg")
        library.cards = [pending]
        try library.removeCard(pending.id)
        XCTAssertEqual(library.supersededJobIDs, [pending.jobID])
        XCTAssertFalse(try library.applyJobResult(cardID: pending.id, jobID: pending.jobID, status: "failed", analysis: nil, collection: nil, error: nil))
        try library.restoreCard(pending.id)
        let restored = try XCTUnwrap(library.cards.first)
        XCTAssertEqual(restored.id, pending.id)
        XCTAssertEqual(restored.frontFile, pending.frontFile)
        XCTAssertEqual(restored.backFile, pending.backFile)
        XCTAssertEqual(restored.state, "queued")
        XCTAssertNotEqual(restored.jobID, pending.jobID)
        XCTAssertFalse(try library.applyJobResult(cardID: pending.id, jobID: pending.jobID, status: "failed", analysis: nil, collection: nil, error: nil))
    }

    func testRestoringAFrontOnlyPairWaitsForTheCurrentPair() throws {
        var library = Library()
        var original = OwnedCard(state: "awaiting_back", frontFile: "original.jpg")
        original.awaitingBack = true
        library.cards = [original]
        try library.removeCard(original.id)
        var next = OwnedCard(state: "awaiting_back", frontFile: "next.jpg")
        next.awaitingBack = true
        library.cards = [next]
        XCTAssertThrowsError(try library.restoreCard(original.id))
        XCTAssertEqual(library.cards, [next])
        XCTAssertEqual(library.removedCards, [original])
    }
}
