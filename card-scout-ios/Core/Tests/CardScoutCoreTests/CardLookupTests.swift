import XCTest
@testable import CardScoutCore

final class CardLookupTests: XCTestCase {
    func fixture() -> Library {
        var library = ScanMatchTests().fixture()
        library.cards[0].state = "analyzed"
        library.cards[0].analysis?.collectionID = "optic"
        library.cards[0].analysis?.identityConfirmed = true
        library.cards[0].analysis?.confidence = "high"
        library.cards[0].analysis?.assessmentSource = "cardsight"
        library.cards[0].analysis?.cardSightIdentity = CardSightIdentity(
            cardID: "11111111-1111-4111-a111-111111111111", setID: "22222222-2222-4222-a222-222222222222")
        return library
    }

    func testVariantSelectionKeepsPhotosAndRejectsOldResults() throws {
        var library = fixture()
        library.cards[0].analysis?.cardSightVariants = [CardSightVariant(id: "base", name: "Base"), CardSightVariant(id: "orange", name: "Orange", confidence: "Medium", medianCents: 900, currency: "USD", expiresAt: Date().timeIntervalSince1970 + 3600)]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        try disk.writePhoto(Data([7, 8, 9]), name: library.cards[0].frontFile)
        let before = library.cards[0]
        try library.selectCardSightVariant(cardID: before.id, variantID: "orange")
        XCTAssertEqual(library.cards[0].id, before.id)
        XCTAssertEqual(library.cards[0].frontFile, before.frontFile)
        XCTAssertEqual(library.cards[0].backFile, before.backFile)
        XCTAssertEqual(library.cards[0].refreshOfJobID, before.jobID)
        XCTAssertEqual(library.cards[0].requestedVariantID, "orange")
        XCTAssertNotEqual(library.cards[0].jobID, before.jobID)
        XCTAssertEqual(library.cards[0].state, "queued")
        XCTAssertFalse(try library.applyJobResult(cardID: before.id, jobID: before.jobID, status: "analyzed", analysis: before.analysis, collection: nil, error: nil))
        XCTAssertThrowsError(try library.selectCardSightVariant(cardID: before.id, variantID: "unknown"))
        let durable = try XCTUnwrap(library.cards[0].analysis?.withoutTransientPricing())
        XCTAssertNil(durable.cardSightVariants?.last?.medianCents)
        XCTAssertEqual(durable.cardSightVariants?.last?.name, "Orange")
        let decoded = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(decoded.cards[0].requestedVariantID, "orange")
        try disk.save(library)
        XCTAssertEqual(try disk.load().cards[0].requestedVariantID, "orange")
        XCTAssertEqual(try Data(contentsOf: disk.photoURL(before.frontFile)), Data([7, 8, 9]))
        let restarted = try disk.reanalyze(cardID: before.id, in: library)
        XCTAssertNil(restarted.cards[0].requestedVariantID)
    }

    func testRejectedVariantRestoresOriginalAndCurrentOptionsAfterRestart() throws {
        var library = fixture()
        let id = library.cards[0].id
        library.cards[0].analysisJobID = UUID().uuidString
        library.cards[0].backFile = "saved-back.jpg"
        library.cards[0].notes = "From my first pack"
        library.cards[0].manualAssignment = true
        library.cards[0].requestedAnalysisVersion = 2
        try library.setPersonalPrice(cardID: id, amountCents: 1350, currency: "USD")
        let confirmed = CardSightVariant(id: "base", name: "Base")
        let stale = CardSightVariant(id: "orange", name: "Orange")
        library.cards[0].analysis?.cardSightVariants = [confirmed, stale]
        let before = library.cards[0]
        try library.selectCardSightVariant(cardID: id, variantID: stale.id)
        let rejected = library.cards[0].jobID
        library = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        var server = try XCTUnwrap(before.analysis)
        server.cardSightVariants = [confirmed]
        XCTAssertTrue(library.rejectCardSightVariant(cardID: id, jobID: rejected, previousAnalysis: server, error: "Rejected"))
        let restored = library.cards[0]
        XCTAssertEqual(restored.jobID, before.jobID)
        XCTAssertEqual(restored.uploadedJobID, before.jobID)
        XCTAssertTrue(restored.hasCurrentAnalysis)
        XCTAssertFalse(restored.isAwaitingAnalysis)
        XCTAssertNil(restored.requestedVariantID)
        XCTAssertNil(restored.refreshOfJobID)
        XCTAssertEqual(restored.error, "Rejected")
        XCTAssertEqual(restored.notes, before.notes)
        XCTAssertEqual(restored.frontFile, before.frontFile)
        XCTAssertEqual(restored.backFile, before.backFile)
        XCTAssertEqual(restored.personalPrice, before.personalPrice)
        XCTAssertEqual(restored.requestedAnalysisVersion, before.requestedAnalysisVersion)
        XCTAssertEqual(restored.manualAssignment, true)
        XCTAssertEqual(restored.analysis?.cardSightVariants, [confirmed])
        XCTAssertFalse(library.rejectCardSightVariant(cardID: id, jobID: rejected, previousAnalysis: nil, error: "Late"))
        XCTAssertFalse(try library.applyJobResult(cardID: id, jobID: rejected, status: "queued", analysis: nil, collection: nil, error: nil))
    }

    func testVariantRollbackIgnoresSupersededRevisionAndMismatchedPriorIdentity() throws {
        var library = fixture()
        let id = library.cards[0].id
        library.cards[0].analysis?.cardSightVariants = [CardSightVariant(id: "orange", name: "Orange")]
        let saved = library.cards[0].analysis
        try library.selectCardSightVariant(cardID: id, variantID: "orange")
        let pending = library.cards[0]
        var newer = library
        newer.cards[0].analysisJobID = UUID().uuidString
        XCTAssertFalse(newer.rejectCardSightVariant(cardID: id, jobID: pending.jobID, previousAnalysis: nil, error: "Late"))
        XCTAssertEqual(newer.cards[0].requestedVariantID, "orange")
        var wrong = try XCTUnwrap(saved)
        wrong.cardNumber = "148"
        XCTAssertTrue(library.rejectCardSightVariant(cardID: id, jobID: pending.jobID, previousAnalysis: wrong, error: "Rejected"))
        XCTAssertEqual(library.cards[0].jobID, id)
        XCTAssertEqual(library.cards[0].analysis, saved)
    }

    func testAcceptingIdentifiedScanDoesNotCreateAnotherJob() throws {
        var library = fixture()
        let before = library.cards[0]
        try library.collectScan(cardID: before.id, match: CardMatch(collectionID: "optic", number: "257"), folderID: nil)
        XCTAssertEqual(library.cards[0].id, before.id)
        XCTAssertEqual(library.cards[0].jobID, before.jobID)
        XCTAssertEqual(library.cards[0].analysis, before.analysis)
        XCTAssertEqual(library.cards[0].frontFile, before.frontFile)
        XCTAssertEqual(library.cards[0].state, "analyzed")
        XCTAssertEqual(library.collectedCards.count, 1)
    }

    func testCorrectionDropsOldProviderIdentityAndPrices() throws {
        var library = fixture()
        let before = library.cards[0]
        try library.collectScan(cardID: before.id, match: CardMatch(collectionID: "scope", number: "257"), folderID: nil)
        XCTAssertNotEqual(library.cards[0].jobID, before.jobID)
        XCTAssertNil(library.cards[0].analysis?.cardSightIdentity)
        XCTAssertNil(library.cards[0].analysis?.assessmentSource)
        XCTAssertEqual(library.cards[0].analysis?.parallel, "Orange Scope")
    }

    func testExistingLibraryAndPhotosSurviveProviderMetadataRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        try disk.writePhoto(Data([7, 8, 9]), name: "saved-front.jpg")
        let old = try disk.addCaptures([CapturePhoto(front: Data([1, 2, 3]), back: Data([4, 5, 6]))], sessionID: "lookup", to: fixture())
        try disk.save(old)
        let before = try disk.load()
        let front = try Data(contentsOf: disk.photoURL(before.cards[0].frontFile))
        let back = try Data(contentsOf: disk.photoURL(try XCTUnwrap(before.cards[0].backFile)))
        let export = ProcessInfo.processInfo.environment["CARD_LOOKUP_PRESERVATION_ROOT"].map { URL(fileURLWithPath: $0) }
        if let export {
            try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root, to: export.appendingPathComponent("before"))
        }
        try disk.save(before)
        let after = try disk.load()
        if let export { try FileManager.default.copyItem(at: root, to: export.appendingPathComponent("after")) }
        XCTAssertEqual(after.cards, before.cards)
        XCTAssertEqual(after.collections, before.collections)
        XCTAssertEqual(after.cards.last?.analysis?.cardSightIdentity, before.cards.last?.analysis?.cardSightIdentity)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL(after.cards[0].frontFile)), front)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL(try XCTUnwrap(after.cards[0].backFile))), back)
    }

    func testOldAnalysisDecodesWithoutProviderFields() throws {
        var a = try XCTUnwrap(fixture().cards[0].analysis)
        a.cardSightIdentity = nil; a.assessmentSource = nil
        let decoded = try JSONDecoder().decode(CardAnalysis.self, from: JSONEncoder().encode(a))
        XCTAssertNil(decoded.cardSightIdentity)
        XCTAssertNil(decoded.assessmentSource)
        XCTAssertEqual(decoded.player, a.player)
    }

    func testAuctionMedianIsShownInsteadOfRangeMidpoint() throws {
        let a = try XCTUnwrap(fixture().cards[0].analysis)
        let identity = try XCTUnwrap(a.cardSightIdentity)
        XCTAssertNotEqual(identity.cardID, fixture().cards[0].id)
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let references = [100, 100, 100, 800].map { amount in
            MarketReference(provider: "CardSight", url: "https://www.ebay.com/itm/123456789012", kind: "sold", grade: "raw",
                matchQuality: "exact", lowCents: amount, highCents: amount, currency: "USD", saleDate: String(date),
                checkedAt: String(date), shipping: "unknown", expiresAt: Date().timeIntervalSince1970 + 3600)
        }
        let summary = RawMarketSummary(references: references)
        XCTAssertEqual(summary.orderingValueCents, 100)
    }
}
