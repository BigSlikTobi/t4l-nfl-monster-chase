import XCTest
@testable import CardScoutCore

final class BatchReanalysisTests: XCTestCase {
    private var root: URL!
    private var disk: DiskStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        disk = try DiskStore(root: root)
        try disk.writePhoto(Data([1, 2, 3]), name: "front.jpg")
        try disk.writePhoto(Data([4, 5]), name: "back.jpg")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func card(confirmed: Bool = false) -> OwnedCard {
        var a = CardAnalysis(recommendation: "Keep", marketCheckedAt: "2026-10-16", marketSources: [], confidence: confirmed ? "high" : "medium", conditionNotes: "", rationale: "", needsReview: !confirmed)
        a.identityConfirmed = confirmed
        return OwnedCard(state: "analyzed", frontFile: "front.jpg", backFile: "back.jpg", analysis: a)
    }
    func testAutomaticRecheckFilesNewEditionAndPreservesOriginalChoiceAndPhoto() throws {
        var library = Library()
        var before = card(confirmed: true)
        before.analysis?.collectionID = "silver"
        before.manualAssignment = true
        before.isScanDraft = true
        library.cards = [before, card()]
        let operation = UUID().uuidString
        var run = try disk.recheckPhotos(ids: [before.id], operation: operation, in: library)
        let jobID = run.cards[0].jobID
        XCTAssertEqual(try disk.recheckPhotos(ids: [before.id], operation: operation, in: run).cards, run.cards)
        XCTAssertEqual(library.cards[1], run.cards[1])
        var match = try XCTUnwrap(before.analysis)
        match.parallel = "Hot Pink X-Fractor"
        match.collectionID = "pink"
        match.finishState = "verified"
        for status in ["identified", "analyzed"] {
            XCTAssertTrue(try run.applyJobResult(cardID: before.id, jobID: jobID, status: status, analysis: match, collection: nil, error: nil))
        }
        XCTAssertEqual(run.cards[0].analysis?.parallel, match.parallel)
        XCTAssertEqual(run.cards[0].previousPhotoAssignment, before.analysis)
        XCTAssertEqual(run.cards[0].isScanDraft, false)
        XCTAssertEqual(run.cards[0].frontFile, before.frontFile)
        XCTAssertFalse(try run.applyJobResult(cardID: before.id, jobID: before.jobID, status: "analyzed", analysis: before.analysis, collection: nil, error: nil))
    }

    func testTiltIsOneExtraFileAndRequiresAnOpticalDecision() throws {
        var library = Library()
        var original = card()
        original.automaticScan = true
        original.analysis?.finishState = "pending"
        XCTAssertNil(ReviewIssue.identity(original))
        library.cards = [original]
        XCTAssertThrowsError(try disk.addTilt(Data([9]), cardID: original.id, jobID: original.jobID, in: library))
        library.cards[0].analysis?.finishState = "tilt"
        var run = try disk.addTilt(Data([9]), cardID: original.id, jobID: original.jobID, in: library)
        let newJob = run.cards[0].jobID
        XCTAssertEqual(run.cards[0].backFile, original.backFile)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL(original.frontFile)), Data([1, 2, 3]))
        XCTAssertTrue(try run.applyJobResult(cardID: original.id, jobID: newJob, status: "analyzed", analysis: library.cards[0].analysis, collection: nil, error: nil))
        XCTAssertFalse(run.cards[0].canAddTilt)
        XCTAssertThrowsError(try disk.addTilt(Data([8]), cardID: original.id, jobID: newJob, in: run))
    }

    func testSavedReceiptsApplyOfflineOnlyToMatchingUploadedRevisions() throws {
        var library = Library()
        library.cards = [card(), card()]
        let operation = UUID().uuidString
        library = try disk.recheckPhotos(ids: Set(library.cards.map(\.id)), operation: operation, in: library)
        for i in library.cards.indices { library.cards[i].uploadedJobID = library.cards[i].jobID }
        try disk.save(library)
        let current = library.cards[0]
        let other = library.cards[1]
        let receipt = SavedScanReceipt(cardID: current.id, analysis: try XCTUnwrap(current.analysis),
                                       collection: nil, matches: nil, matchNotice: nil)
        let bundle = [current.jobID: receipt, other.jobID: receipt]
        let url = root.appendingPathComponent("recheck-receipts-" + operation + ".json")
        try JSONEncoder().encode(bundle).write(to: url, options: .atomic)
        let saved = try disk.load()
        XCTAssertTrue(saved.cards[0].hasCurrentAnalysis)
        XCTAssertEqual(saved.cards[1], other)
        XCTAssertEqual(try disk.load().cards, saved.cards)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBatchKeepsCollectionAndPhotosAndDoesNotRepeat() throws {
        var library = Library(); library.cards = [card(), card(), card(confirmed: true)]
        try disk.save(library)
        let jobs = Set(library.cards.map(\.jobID))
        let updated = try disk.reanalyzeUnclear(jobIDs: jobs, in: library)
        XCTAssertEqual(updated.cards.map(\.id), library.cards.map(\.id))
        XCTAssertEqual(updated.cards[2], library.cards[2])
        for index in 0..<2 {
            XCTAssertEqual(updated.cards[index].state, "queued")
            XCTAssertNotEqual(updated.cards[index].jobID, library.cards[index].jobID)
            XCTAssertEqual(updated.cards[index].frontFile, library.cards[index].frontFile)
            XCTAssertEqual(updated.cards[index].backFile, library.cards[index].backFile)
            XCTAssertEqual(updated.cards[index].analysis, library.cards[index].analysis)
            XCTAssertNil(updated.cards[index].refreshOfJobID)
            XCTAssertEqual(updated.cards[index].fastPipeline, false)
        }
        XCTAssertEqual(try disk.load().cards, updated.cards)
        XCTAssertEqual(try disk.reanalyzeUnclear(jobIDs: jobs, in: updated).cards, updated.cards)
        var completed = updated
        completed.cards[0].state = "analyzed"
        XCTAssertEqual(try disk.reanalyzeUnclear(jobIDs: jobs, in: completed).cards, completed.cards)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL("front.jpg")), Data([1, 2, 3]))
    }
    func testMissingPhotoAbortsWholeBatchWithoutChangingSavedCollection() throws {
        var library = Library(); library.cards = [card(), card()]
        library.cards[1].backFile = "missing.jpg"
        try disk.save(library)
        XCTAssertThrowsError(try disk.reanalyzeUnclear(jobIDs: Set(library.cards.map(\.jobID)), in: library))
        XCTAssertEqual(try disk.load().cards, library.cards)
    }
    func testNamedCollegeLicenseReviewRechecksPhotosEvenWithConfirmedIdentity() throws {
        var library = Library(); library.cards = [card(confirmed: true), card(confirmed: true), card(confirmed: true)]
        for index in 0..<2 {
            library.cards[index].analysis?.licenseScope = "unlicensed"
            library.cards[index].analysis?.needsReview = true
        }
        library.cards[1].manualAssignment = true
        let jobs = Set(library.cards.map(\.jobID))
        let updated = try disk.reanalyzeUnclear(jobIDs: jobs, in: library)
        XCTAssertNotEqual(updated.cards[0].jobID, library.cards[0].jobID)
        XCTAssertEqual(updated.cards[0].analysis, library.cards[0].analysis)
        XCTAssertNil(updated.cards[0].refreshOfJobID)
        XCTAssertEqual(updated.cards[0].fastPipeline, false)
        XCTAssertEqual(updated.cards[1], library.cards[1])
        XCTAssertEqual(updated.cards[2], library.cards[2])
        XCTAssertEqual(try disk.reanalyzeUnclear(jobIDs: jobs, in: updated).cards, updated.cards)
    }
    func testOnlyNamedCompletedUnclearCardsAreQueued() throws {
        var library = Library(); library.cards = [card(), card(), card()]
        library.cards[1].state = "processing"
        let updated = try disk.reanalyzeUnclear(jobIDs: Set(library.cards.prefix(2).map(\.jobID)), in: library)
        XCTAssertNotEqual(updated.cards[0].jobID, library.cards[0].jobID)
        XCTAssertEqual(updated.cards[1], library.cards[1])
        XCTAssertEqual(updated.cards[2], library.cards[2])
        XCTAssertThrowsError(try disk.reanalyzeUnclear(jobIDs: Set((0..<201).map(String.init)), in: library))
    }
    func testNamedFailedCardCanRecoverWithSavedPhotosAndOldJobIsSuperseded() throws {
        var library = Library(); library.cards = [card()]
        library.cards[0].state = "failed"
        let oldJob = library.cards[0].jobID
        let updated = try disk.reanalyzeUnclear(jobIDs: [oldJob], in: library)
        XCTAssertEqual(updated.cards[0].state, "queued")
        XCTAssertEqual(updated.cards[0].frontFile, library.cards[0].frontFile)
        XCTAssertEqual(updated.cards[0].backFile, library.cards[0].backFile)
        XCTAssertTrue(updated.supersededJobIDs!.contains(oldJob))
        XCTAssertEqual(try disk.reanalyzeUnclear(jobIDs: [oldJob], in: updated).cards, updated.cards)
    }
    func testAllSavedPassIncludesConfirmedAndFailedCardsWithoutChangingManualChoices() throws {
        var library = Library(); library.cards = [card(confirmed: true), card(), card()]
        library.cards[0].manualAssignment = true
        library.cards[1].state = "failed"
        let operation = UUID().uuidString.lowercased()
        let updated = try disk.reanalyzeAllSaved(operationID: operation, in: library)
        XCTAssertEqual(updated.cards.map(\.id), library.cards.map(\.id))
        XCTAssertEqual(updated.cards.map(\.frontFile), library.cards.map(\.frontFile))
        XCTAssertEqual(updated.cards[0].manualAssignment, true)
        XCTAssertEqual(updated.cards[0].fastPipeline, false)
        XCTAssertEqual(updated.cards[1].fastPipeline, true)
        XCTAssertTrue(updated.cards.allSatisfy { $0.state == "queued" && $0.refreshOfJobID == nil })
        let repeated = try disk.reanalyzeAllSaved(operationID: operation, in: updated)
        XCTAssertEqual(repeated.cards, updated.cards)
        XCTAssertEqual(try disk.load().savedPhotoReanalysisOperationID, operation)
    }
    func testFreshPriceRunClearsOldPricesAndKeepsManualIdentity() throws {
        var library = Library()
        library.cards = [card(confirmed: true)]
        library.cards[0].manualAssignment = true
        library.cards[0].analysis?.cardNumber = "123"
        library.cards[0].analysis?.marketLowCents = 350
        library.cards[0].analysis?.unpricedBaseExpiresAt = Date().addingTimeInterval(1000).timeIntervalSince1970
        try library.setPersonalPrice(cardID: library.cards[0].id, amountCents: 999, currency: "EUR")
        let operation = UUID().uuidString
        let next = try disk.reanalyzeAllSaved(operationID: operation, in: library, clearCurrentPrices: true)
        let saved = try XCTUnwrap(next.cards.first)
        XCTAssertNil(saved.analysis?.marketLowCents)
        XCTAssertNil(saved.analysis?.unpricedBaseExpiresAt)
        XCTAssertNil(saved.personalPrice)
        XCTAssertNil(saved.refreshOfJobID)
        XCTAssertFalse(saved.hasDisplayableAnalysis)
        XCTAssertEqual(saved.analysis?.cardNumber, "123")
        XCTAssertEqual(saved.manualAssignment, true)
        XCTAssertEqual(try disk.reanalyzeAllSaved(operationID: operation, in: next, clearCurrentPrices: true).cards, next.cards)
    }
    func testAllSavedPassIsAtomicWhenAPhotoIsMissing() throws {
        var library = Library(); library.cards = [card(), card()]
        library.cards[1].frontFile = "missing.jpg"
        try disk.save(library)
        XCTAssertThrowsError(try disk.reanalyzeAllSaved(operationID: UUID().uuidString, in: library))
        XCTAssertEqual(try disk.load().cards, library.cards)
        XCTAssertNil(try disk.load().savedPhotoReanalysisOperationID)
    }
}
