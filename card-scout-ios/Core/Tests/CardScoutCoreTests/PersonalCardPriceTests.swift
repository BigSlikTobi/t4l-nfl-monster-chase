import XCTest
@testable import CardScoutCore

final class PersonalCardPriceTests: XCTestCase {
    func testDecimalInputAndInvalidValues() {
        for (text, cents) in [("12,34", 1234), ("12.3", 1230), (" 42 ", 4200), ("0", 0), ("0,00", 0)] {
            XCTAssertEqual(PersonalCardPrice.parseAmount(text), cents)
        }
        for text in ["", "-1", "1.234", "1,234.56", "NaN", "1000000.01"] {
            XCTAssertNil(PersonalCardPrice.parseAmount(text))
        }
    }

    func testPersonalEstimateOverridesBurnOnceWithoutChangingResearchOrHistory() throws {
        var analysis = CardAnalysis(recommendation: "Keep", marketCheckedAt: "2026-11-07", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
        analysis.identityConfirmed = true; analysis.marketLowCents = 1000; analysis.marketHighCents = 1000; analysis.currency = "EUR"
        let card = OwnedCard(state: "analyzed", analysis: analysis)
        var library = Library(); library.cards = [card]
        let history = library.portfolioValues()
        try library.setManualBurnValue(amountCents: 9999, currency: "EUR")
        try library.setPersonalPrice(cardID: card.id, amountCents: 2500, currency: "EUR")
        XCTAssertNil(library.currentManualBurnValue(currency: "EUR"))
        XCTAssertEqual(library.burnManualValues?["EUR"]?.amountCents, 9999)
        let stats = CollectionStatistics(library: library)
        XCTAssertEqual(stats.values.first?.lowCents, 2500)
        XCTAssertTrue(stats.values.first?.isPersonal == true)
        XCTAssertEqual(BurnCount(statistics: stats, currency: "EUR").valueLowCents, 2500)
        XCTAssertEqual(BurnCount(statistics: stats, currency: "EUR").pricedCards, 1)
        try library.setManualBurnValue(amountCents: 3000, currency: "EUR")
        XCTAssertEqual(library.currentManualBurnValue(currency: "EUR")?.amountCents, 3000)
        try library.setPersonalPrice(cardID: card.id, amountCents: 2500, currency: "USD")
        XCTAssertNil(library.currentManualBurnValue(currency: "EUR"))
        XCTAssertNil(BurnCount(statistics: CollectionStatistics(library: library), currency: "EUR").valueLowCents)
        XCTAssertEqual(library.portfolioValues().first?.currency, "USD")
        XCTAssertEqual(library.cards[0].analysis, analysis)
        try library.setPersonalPrice(cardID: card.id, amountCents: nil, currency: "EUR")
        XCTAssertEqual(BurnCount(statistics: CollectionStatistics(library: library), currency: "EUR").valueLowCents, 1000)
        XCTAssertEqual(library.portfolioValues(), history)
    }

    func testZeroPendingCardsCurrencyIsolationAndReanalysis() throws {
        var library = Library(); library.cards = [OwnedCard()]
        let id = library.cards[0].id
        try library.setPersonalPrice(cardID: id, amountCents: 0, currency: "USD")
        let stats = CollectionStatistics(library: library)
        XCTAssertEqual(stats.values.first?.lowCents, 0)
        XCTAssertEqual(BurnCount(statistics: stats, currency: "USD").valueLowCents, 0)
        XCTAssertNil(BurnCount(statistics: stats, currency: "EUR").valueLowCents)
        XCTAssertTrue(BurnCount(statistics: stats, currency: "USD").hasCompleteCoverage)
        try library.applyJobResult(cardID: id, jobID: id, status: "processing", analysis: nil, collection: nil, error: nil)
        XCTAssertEqual(library.cards[0].personalPrice?.amountCents, 0)
        XCTAssertThrowsError(try library.setPersonalPrice(cardID: id, amountCents: -1, currency: "USD"))
        XCTAssertThrowsError(try library.setPersonalPrice(cardID: id, amountCents: 10, currency: "XYZ"))
        XCTAssertThrowsError(try library.setPersonalPrice(cardID: "missing", amountCents: 10, currency: "EUR"))
    }

    func testBackwardDecodingDiskRoundTripAndPhotoPreservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        let photo = Data([1, 2, 3, 4])
        try disk.writePhoto(photo, name: "front.jpg")
        var library = Library(); library.cards = [OwnedCard(frontFile: "front.jpg")]
        let original = library.cards[0]
        let old = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        XCTAssertNil(old.cards[0].personalPrice)
        try library.setPersonalPrice(cardID: original.id, amountCents: 1234, currency: "GBP")
        try disk.save(library)
        var restored = try disk.load()
        XCTAssertEqual(restored.cards[0].personalPrice, library.cards[0].personalPrice)
        try restored.setPersonalPrice(cardID: original.id, amountCents: nil, currency: "GBP")
        XCTAssertEqual(restored.cards[0], original)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL("front.jpg")), photo)
    }
}
