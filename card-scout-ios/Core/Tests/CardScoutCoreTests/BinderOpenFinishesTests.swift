import XCTest
@testable import CardScoutCore

final class BinderOpenFinishesTests: XCTestCase {
    private func scan(_ player: String) -> OwnedCard {
        var analysis = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: true)
        analysis.year = 2025
        analysis.brand = "Topps"
        analysis.setName = "Topps Chrome"
        analysis.subset = "Base"
        analysis.player = player
        analysis.cardNumber = "297"
        analysis.cardSightIdentity = CardSightIdentity(cardID: UUID().uuidString, setID: UUID().uuidString)
        analysis.identityConfirmed = false
        analysis.finishPolicy = "chrome-football-2025-v1"
        analysis.finishState = "pending"
        return OwnedCard(state: "analyzed", analysis: analysis)
    }

    func testRecognizedCopiesAppearBeforeCatalogAndMoveToExactChecklistOnceConfirmed() throws {
        var library = Library()
        let first = scan("Zach Ertz")
        let second = scan("Zach Ertz")
        var draft = scan("draft")
        draft.isScanDraft = true
        var unrecognized = scan("unknown")
        unrecognized.analysis?.cardSightIdentity = nil
        library.cards = [first, second, draft, unrecognized]
        let open = try XCTUnwrap(library.binders.first)
        XCTAssertEqual(open.name, "Topps Chrome")
        XCTAssertTrue(open.collections.isEmpty)
        XCTAssertEqual(Set(open.openFinishCards(in: library).map(\.id)), [first.id, second.id])

        let base = CardCollection(id: "standard", name: "Topps Chrome", year: 2025, brand: "Topps", cards: [ChecklistCard(number: "297", player: "Zach Ertz", team: "")])
        var wave = base
        wave.id = "wave"
        wave.parallel = "Wave"
        library.collections = [base, wave]
        XCTAssertTrue(base.owned(for: "297", in: library.cards).isEmpty)
        XCTAssertTrue(wave.owned(for: "297", in: library.cards).isEmpty)
        library.cards[0].analysis?.identityConfirmed = true
        library.cards[0].analysis?.finishState = "verified"
        library.cards[0].analysis?.collectionID = wave.id
        let binder = try XCTUnwrap(library.binders.first)
        XCTAssertEqual(binder.openFinishCards(in: library).map(\.id), [second.id])
        XCTAssertEqual(Set(binder.cards(in: library).map(\.id)), [first.id, second.id])
        XCTAssertTrue(base.owned(for: "297", in: library.cards).isEmpty)
        XCTAssertEqual(wave.owned(for: "297", in: library.cards).map(\.id), [first.id])
    }

    func testSavedChoiceUsesRecognizedProductAndDoesNotCreditOldChecklist() throws {
        var library = Library()
        var card = scan("Bucky Irving")
        card.proposedPhotoMatch = card.analysis
        card.analysis?.setName = "Panini Select"
        card.analysis?.brand = "Panini"
        card.analysis?.collectionID = "select"
        card.analysis?.finishState = "savedChoice"
        library.collections = [CardCollection(id: "select", name: "Panini Select", year: 2025, brand: "Panini", cards: [])]
        library.cards = [card]
        let chrome = try XCTUnwrap(library.binders.first { $0.name == "Topps Chrome" })
        XCTAssertEqual(chrome.openFinishCards(in: library).map(\.id), [card.id])
        XCTAssertTrue(library.binders.first { $0.id != chrome.id }?.cards(in: library).isEmpty ?? true)
    }

    func testOpenFinishCanUseOneNewAngleWithoutChangingTheSavedPair() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = try DiskStore(root: folder)
        let front = Data([1]), back = Data([2]), angle = Data([3])
        var card = scan("Zach Ertz")
        card.frontFile = "front.jpg"
        card.backFile = "back.jpg"
        card.analysis?.cardSightVariants = [CardSightVariant(id: "base", name: "Base")]
        XCTAssertFalse(card.canCaptureFinishAngle)
        card.analysis?.cardSightVariants?.append(CardSightVariant(id: UUID().uuidString, name: "Wave"))
        XCTAssertFalse(card.canAddTilt)
        XCTAssertTrue(card.canCaptureFinishAngle)
        try disk.writePhoto(front, name: card.frontFile)
        try disk.writePhoto(back, name: "back.jpg")
        var library = Library()
        library.cards = [card]
        var queued = try disk.addTilt(angle, cardID: card.id, jobID: card.jobID, in: library)
        let updated = try XCTUnwrap(queued.cards.first)
        XCTAssertEqual(updated.id, card.id)
        XCTAssertEqual(updated.state, "queued")
        XCTAssertNotEqual(updated.jobID, card.jobID)
        XCTAssertEqual(queued.binders.first?.openFinishCards(in: queued).map(\.id), [card.id])
        XCTAssertFalse(updated.canCaptureFinishAngle)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL(updated.frontFile)), front)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL(XCTUnwrap(updated.backFile))), back)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL(XCTUnwrap(updated.tiltFile))), angle)

        let unrecognized = CardAnalysis(recommendation: "Keep", marketCheckedAt: "", marketSources: [],
                                        confidence: "low", conditionNotes: "", rationale: "", needsReview: true)
        XCTAssertTrue(try queued.applyJobResult(cardID: card.id, jobID: updated.jobID, status: "analyzed",
                                                analysis: unrecognized, collection: nil, error: nil))
        XCTAssertEqual(queued.binders.first?.openFinishCards(in: queued).map(\.id), [card.id])
        XCTAssertFalse(queued.cards[0].canCaptureFinishAngle)
    }

    func testReviewedFinishBatchIsAtomicAndKeepsEachPhysicalCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = try DiskStore(root: folder)
        let operation = UUID()
        let url = folder.appendingPathComponent("reviewed-finishes-" + operation.uuidString.lowercased() + ".json")
        let standard = CardCollection(id: "standard", name: "Topps Chrome", year: 2025, brand: "Topps",
                                      cards: [ChecklistCard(number: "297", player: "Zach Ertz", team: "")])
        var first = scan("Zach Ertz")
        first.analysis?.licenseScope = "nfl_and_nflpa"
        first.analysis?.cardSightVariants = [CardSightVariant(id: "base", name: "Base")]
        var protected = scan("Zach Ertz")
        protected.proposedPhotoMatch = first.analysis
        protected.analysis?.finishState = "savedChoice"
        protected.analysis?.collectionID = "old-choice"
        var library = Library()
        library.cards = [first, protected]
        library.collections = [standard]
        try disk.save(library)
        func write(secondJob: String) throws {
            let data = [[ "cardID": first.id, "previousJobID": first.jobID, "variantID": "base",
                          "collectionID": standard.id, "number": "297"],
                        [ "cardID": protected.id, "previousJobID": secondJob, "variantID": "base",
                          "collectionID": standard.id, "number": "297"]]
            try JSONEncoder().encode(data).write(to: url)
        }
        try write(secondJob: UUID().uuidString)
        XCTAssertThrowsError(try disk.applyReviewedFinishes(operation: operation, in: library))
        XCTAssertEqual(try disk.load().cards, library.cards)
        try write(secondJob: protected.jobID)
        let filed = try disk.applyReviewedFinishes(operation: operation, in: library)
        XCTAssertEqual(standard.owned(for: "297", in: filed.cards).map(\.id), [first.id, protected.id])
        XCTAssertEqual(filed.cards[1].previousPhotoAssignment?.collectionID, "old-choice")
        XCTAssertNil(filed.cards[1].proposedPhotoMatch)
        XCTAssertTrue(filed.cards.allSatisfy { $0.analysis?.finishState == "verified" && $0.openFinishIdentity == nil })
        XCTAssertEqual(filed.pendingAcknowledgments, library.pendingAcknowledgments)
        XCTAssertEqual(try disk.applyReviewedFinishes(operation: operation, in: filed).cards, filed.cards)
    }
    func testReviewedMissingRowSurvivesStaleSyncAndReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = try DiskStore(root: folder)
        let operation = UUID()
        let url = folder.appendingPathComponent("reviewed-finishes-" + operation.uuidString.lowercased() + ".json")
        var card = scan("Zach Ertz")
        let variant = CardSightVariant(id: UUID().uuidString, name: "RayWave Refractor")
        card.analysis?.cardSightVariants = [variant]
        let id = "cardsight-" + card.analysis!.cardSightIdentity!.setID + "-" + variant.id
        let receipt = [["cardID": card.id, "previousJobID": card.jobID, "variantID": variant.id,
                        "collectionID": id, "number": "297"]]
        try JSONEncoder().encode(receipt).write(to: url)
        var library = Library()
        library.cards = [card]
        var stale = CardCollection(id: id, name: "Topps Chrome", year: 2025, brand: "Topps",
                                   parallel: variant.name, cards: [ChecklistCard(number: "1", player: "Other", team: "")])
        for lists in [[], [stale]] {
            library.collections = lists
            var filed = try disk.applyReviewedFinishes(operation: operation, in: library)
            for _ in 0..<2 {
                filed.mergeChecklists([stale])
                try disk.save(filed)
                filed = try disk.load()
            }
            XCTAssertEqual(filed.collections.count, 1)
            XCTAssertEqual(filed.collections[0].cards.map(\.number).sorted(), ["1", "297"])
            XCTAssertEqual(filed.collections[0].owned(for: "297", in: filed.cards).map(\.id), [card.id])
            XCTAssertFalse(filed.collections[0].checklistComplete)
            // Recover a verified owned row lost to an older version.
            filed.collections = [stale]
            filed.mergeChecklists([stale])
            XCTAssertEqual(filed.collections[0].cards.count, 2)
        }
        stale.cards.append(ChecklistCard(number: "297", player: "Different Player", team: ""))
        library.collections = [stale]
        XCTAssertThrowsError(try disk.applyReviewedFinishes(operation: operation, in: library))
        stale.cards.removeLast()
        stale.parallel = "Refractor"
        library.collections = [stale]
        XCTAssertThrowsError(try disk.applyReviewedFinishes(operation: operation, in: library))
    }

}
