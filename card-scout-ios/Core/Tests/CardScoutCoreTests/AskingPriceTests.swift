import XCTest
@testable import CardScoutCore

final class AskingPriceTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!

    func reference(_ kind: String, _ cents: Int, currency: String = "USD", shipping: String = "excluded") -> MarketReference {
        MarketReference(provider: "CardSight", url: "https://example.invalid/\(kind)/\(cents)", kind: kind,
            grade: "raw", matchQuality: "exact", lowCents: cents, highCents: cents, currency: currency,
            saleDate: kind == "sold" ? "2026-11-16" : nil, checkedAt: "2026-11-17", shipping: shipping,
            expiresAt: now.timeIntervalSince1970 + 3600)
    }

    func analysis(_ references: [MarketReference]) -> CardAnalysis {
        var result = CardAnalysis(recommendation: "Keep", marketCheckedAt: "2026-11-17", marketSources: [],
            confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
        result.identityConfirmed = true; result.player = "Fixture Player"
        result.insights = CardInsights(rarityTier: "base", rarityBullets: [], conditionStatus: "unknown",
            conditionIssues: [], conditionLimitations: [], marketBullets: [], marketReferences: references,
            sourceChecks: [], actionReason: "")
        return result
    }

    func testSalesAndListingsHaveIndependentMediansAndCounts() throws {
        let info = try XCTUnwrap(analysis([reference("sold", 100), reference("sold", 300),
            reference("ask", 900), reference("ask", 1100), reference("ask", 5000)]).insights)
        XCTAssertEqual(info.marketSummary(asOf: now)?.orderingValueCents, 200)
        XCTAssertEqual(info.marketSummary(asOf: now)?.references.count, 2)
        XCTAssertEqual(info.askingSummary(asOf: now)?.orderingValueCents, 1100)
        XCTAssertEqual(info.askingSummary(asOf: now)?.references.count, 3)
        XCTAssertEqual(info.askingSummary(asOf: now)?.basisLabel, "Median · 3 Angebote")
        XCTAssertEqual(info.askingSummary(asOf: now)?.dateLabel, "Stand: 2026-11-17")
        XCTAssertEqual(reference("ask", 900).kindLabel, "Angebot")
    }

    func testAskIsThePortfolioBaselineAndSalesRemainSeparate() throws {
        let value = analysis([reference("ask", 900)])
        XCTAssertNil(value.insights?.marketSummary(asOf: now))
        XCTAssertNotNil(value.insights?.askingSummary(asOf: now))
        var library = Library()
        library.cards = [OwnedCard(state: "analyzed", analysis: value)]
        XCTAssertEqual(library.portfolioValues(asOf: now).first?.comparisonKey, "ask|excluded")
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now))
        XCTAssertNil(library.cards[0].personalPrice)
        let statistics = CollectionStatistics(library: library, asOf: now)
        XCTAssertEqual(statistics.totalCards, 1)
        XCTAssertEqual(statistics.values.first?.basis, "Einzelangebot")
        let burn = BurnCount(statistics: statistics, currency: "USD")
        XCTAssertEqual(burn.valueLowCents, 900)
        XCTAssertEqual(burn.pricedCards, 1)
        library.cards[0].analysis = analysis([reference("sold", 200), reference("ask", 900)])
        XCTAssertEqual(library.portfolioValues(asOf: now).first?.lowCents, 900)
        library.cards[0].analysis = analysis([reference("sold", 200)])
        XCTAssertEqual(library.portfolioValues(asOf: now).first?.lowCents, 200)
        XCTAssertNil(library.portfolioChange(currency: "USD", asOf: now))
    }

    func testSwitchFromSoldToAskingStartsANewComparisonBaseline() {
        var library = Library()
        library.cards = [OwnedCard(state: "analyzed", analysis: analysis([reference("sold", 200)]))]
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now))
        library.cards[0].analysis = analysis([reference("ask", 900)])
        XCTAssertNil(library.portfolioChange(currency: "USD", asOf: now))
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now.addingTimeInterval(30)))
        library.cards[0].analysis = analysis([reference("ask", 950)])
        XCTAssertEqual(library.portfolioChange(currency: "USD", asOf: now.addingTimeInterval(60))?.deltaCents, 50)
    }

    func testSoldOnlyHasNoInventedAskingPrice() {
        let info = analysis([reference("sold", 100)]).insights!
        XCTAssertNotNil(info.marketSummary(asOf: now))
        XCTAssertNil(info.askingSummary(asOf: now))
    }

    func testAsksNeverMixCurrenciesOrShippingOrUseNonExactOrGradedEvidence() throws {
        var graded = reference("ask", 500000); graded.grade = "PSA 10"
        var near = reference("ask", 80000); near.matchQuality = "near"
        var invalid = reference("ask", 0)
        invalid.highCents = 500
        let refs = [reference("ask", 100), reference("ask", 300),
            reference("ask", 10000, currency: "EUR"), reference("ask", 9000, shipping: "included"), graded, near, invalid]
        let summary = try XCTUnwrap(analysis(refs).insights?.askingSummary(asOf: now))
        XCTAssertEqual(summary.orderingValueCents, 200)
        XCTAssertEqual(summary.references.count, 2)
        XCTAssertEqual(summary.primary.currency, "USD")
        XCTAssertEqual(summary.primary.shipping, "excluded")
        // Ties are deterministic regardless of provider ordering.
        let tied = [reference("ask", 100, currency: "EUR"), reference("ask", 10000)]
        XCTAssertEqual(analysis(tied).insights?.askingSummary(asOf: now)?.primary.currency,
                       analysis(tied.reversed()).insights?.askingSummary(asOf: now)?.primary.currency)
    }

    func testBothGroupsAndVariantPricesExpireTogether() throws {
        var value = analysis([reference("sold", 100), reference("ask", 500)])
        value.cardSightVariants = [CardSightVariant(id: "base", name: "Base", medianCents: 100,
            askingMedianCents: 500, soldCount: 1, askingCount: 1, askingCurrency: "USD", soldShipping: "excluded", askingShipping: "unknown", currency: "USD", expiresAt: now.timeIntervalSince1970 + 3600)]
        let expired = value.currentPricing(asOf: now.addingTimeInterval(3601))
        XCTAssertNil(expired.insights?.marketSummary(asOf: now.addingTimeInterval(3601)))
        XCTAssertNil(expired.insights?.askingSummary(asOf: now.addingTimeInterval(3601)))
        XCTAssertNil(expired.cardSightVariants?.first?.medianCents)
        XCTAssertNil(expired.cardSightVariants?.first?.askingMedianCents)
        XCTAssertNil(expired.cardSightVariants?.first?.soldCount)
        XCTAssertNil(expired.cardSightVariants?.first?.askingCount)
        XCTAssertNil(expired.cardSightVariants?.first?.askingCurrency)
        XCTAssertNil(expired.cardSightVariants?.first?.askingShipping)
    }

    func testOlderVariantJSONDecodesWithoutAskingFields() throws {
        let old = Data(#"{"id":"base","name":"Base","medianCents":100,"currency":"USD"}"#.utf8)
        let variant = try JSONDecoder().decode(CardSightVariant.self, from: old)
        XCTAssertEqual(variant.medianCents, 100)
        XCTAssertNil(variant.askingMedianCents)
        XCTAssertNil(variant.soldCount)
        XCTAssertNil(variant.askingCount)
    }

    func testDiskStripsBothPricesButPreservesVariantIdentityAndPhotos() throws {
        var value = analysis([reference("sold", 100), reference("ask", 500)])
        value.cardSightVariants = [CardSightVariant(id: "orange", name: "Orange", numberedTo: 25, medianCents: 100,
            askingMedianCents: 500, soldCount: 1, askingCount: 1, askingCurrency: "USD", soldShipping: "excluded", askingShipping: "unknown", currency: "USD", expiresAt: now.timeIntervalSince1970 + 3600)]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        try disk.writePhoto(Data([1, 2, 3]), name: "front.jpg")
        var library = Library()
        library.cards = [OwnedCard(id: "saved-card", state: "analyzed", frontFile: "front.jpg", analysis: value)]
        library.cards[0].personalPrice = PersonalCardPrice(amountCents: 700, currency: "EUR", recordedAt: "2026-11-17")
        try disk.save(library)
        let restored = try disk.load()
        let clean = try XCTUnwrap(restored.cards[0].analysis)
        XCTAssertTrue(clean.insights!.marketReferences.isEmpty)
        XCTAssertNil(clean.cardSightVariants?.first?.medianCents)
        XCTAssertNil(clean.cardSightVariants?.first?.askingMedianCents)
        XCTAssertNil(clean.cardSightVariants?.first?.soldCount)
        XCTAssertNil(clean.cardSightVariants?.first?.askingCount)
        XCTAssertNil(clean.cardSightVariants?.first?.askingCurrency)
        XCTAssertNil(clean.cardSightVariants?.first?.askingShipping)
        XCTAssertEqual(clean.cardSightVariants?.first?.id, "orange")
        XCTAssertEqual(clean.cardSightVariants?.first?.numberedTo, 25)
        XCTAssertEqual(restored.cards[0].id, "saved-card")
        XCTAssertEqual(restored.cards[0].personalPrice, library.cards[0].personalPrice)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL("front.jpg")), Data([1, 2, 3]))
        XCTAssertEqual(library.cards[0].analysis?.insights?.marketReferences.count, 2)
    }
}
