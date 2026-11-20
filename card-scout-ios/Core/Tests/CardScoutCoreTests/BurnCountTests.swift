import XCTest
@testable import CardScoutCore

final class BurnCountTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!

    func valueCard(_ amount: Int?, currency: String = "EUR") -> OwnedCard {
        var a = CardAnalysis(recommendation: "Keep", marketCheckedAt: "2026-11-01", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
        a.player = "Fixture"; a.identityConfirmed = true
        if let amount { a.setFixtureScoutValue(amount, currency: currency, asOf: now) }
        return OwnedCard(state: "analyzed", analysis: a)
    }
    func burn(cards: [OwnedCard], purchases: [CardPurchase], currency: String = "EUR") -> BurnCount {
        var library = Library(); library.cards = cards; library.purchases = purchases
        return BurnCount(statistics: CollectionStatistics(library: library, asOf: now), currency: currency)
    }
    func purchase(_ amount: Int, category: PurchaseCategory = .box, currency: String = "EUR", quantity: Int = 1) -> CardPurchase {
        CardPurchase(title: "Fixture", category: category, amountCents: amount, currency: currency, quantity: quantity, purchasedOn: "2026-11-01")
    }
    func testCombinedCurrencyTotalsUseTheSameCardsAndPurchasesInEitherCurrency() {
        var library = Library()
        library.cards = [valueCard(1000), valueCard(1500, currency: "USD"), valueCard(nil)]
        library.purchases = [purchase(2500), purchase(1200, currency: "USD"),
                             purchase(400, currency: "GBP"), purchase(500, category: .supplies)]
        let stats = CollectionStatistics(library: library, asOf: ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!)
        let rates: [String: Decimal] = ["USD": Decimal(12) / 10, "GBP": Decimal(8) / 10]
        let eur = BurnCount(statistics: stats, currency: "EUR", exchangeRates: rates)
        let usd = BurnCount(statistics: stats, currency: "USD", exchangeRates: rates)
        XCTAssertEqual(eur.spentCents, 4000)
        XCTAssertEqual(eur.valueLowCents, 2250)
        XCTAssertEqual(eur.valueHighCents, 2250)
        XCTAssertEqual(eur.burnLowCents, 1750)
        XCTAssertEqual(usd.spentCents, 4800)
        XCTAssertEqual(usd.valueLowCents, 2700)
        XCTAssertEqual(usd.valueHighCents, 2700)
        XCTAssertEqual(usd.burnLowCents, 2100)
        XCTAssertEqual(eur.pricedCards, 2)
        XCTAssertEqual(usd.pricedCards, 2)
        XCTAssertEqual(usd.purchaseCount, 3)
        XCTAssertEqual(usd.totalCards, 3)
        let noRates = BurnCount(statistics: stats, currency: "EUR", exchangeRates: [:])
        XCTAssertNil(noRates.spentCents)
        XCTAssertNil(noRates.valueLowCents)
        XCTAssertNil(noRates.burnLowCents)
        let manual = BurnCount(statistics: stats, currency: "EUR", manualValueCents: 3000,
                               manualValueCurrency: "USD", exchangeRates: rates)
        XCTAssertEqual(manual.valueLowCents, 2500)
    }

    func testMissingSpendingAndPricesNeverBecomeZeroOrShame() {
        let empty = burn(cards: [], purchases: [])
        XCTAssertNil(empty.spentCents); XCTAssertNil(empty.valueLowCents); XCTAssertNil(empty.burnHighCents)
        XCTAssertEqual(empty.mood, .curious)
        let noLedger = burn(cards: [valueCard(1000)], purchases: [])
        XCTAssertNil(noLedger.burnLowCents); XCTAssertEqual(noLedger.mood, .curious)
    }
    func testPartialCoverageShowsExplicitlyIndicativeBurn() {
        let partial = burn(cards: [valueCard(100), valueCard(nil)], purchases: [purchase(10000)])
        XCTAssertEqual(partial.spentCents, 10000); XCTAssertEqual(partial.pricedCards, 1)
        XCTAssertTrue(partial.canCompare); XCTAssertEqual(partial.burnHighCents, 9900)
        XCTAssertTrue(partial.isIndicative); XCTAssertFalse(partial.hasCompleteCoverage)
    }
    func testModeledCardValueProducesOneBurnAmount() {
        let summary = burn(cards: [valueCard(800)], purchases: [purchase(1000)])
        XCTAssertEqual(summary.burnLowCents, 200); XCTAssertEqual(summary.burnHighCents, 200)
        XCTAssertTrue(summary.isIndicative)
    }
    func testAboveCostShowsNegativeBurnAndProudMood() {
        let summary = burn(cards: [valueCard(1500)], purchases: [purchase(1000)])
        XCTAssertEqual(summary.burnLowCents, -500); XCTAssertEqual(summary.burnHighCents, -500)
        XCTAssertEqual(summary.mood, .proud)
    }
    func testProfitAndBreakEvenPreserveSignedDifference() {
        let profit = burn(cards: [valueCard(1500)], purchases: [purchase(1000)])
        XCTAssertEqual(profit.burnLowCents, -500)
        XCTAssertEqual(profit.burnHighCents, -500)
        let even = burn(cards: [valueCard(1000)], purchases: [purchase(1000)])
        XCTAssertEqual(even.burnLowCents, 0)
        XCTAssertEqual(even.burnHighCents, 0)
    }
    func testPerformanceUsesTheModeledPointValue() {
        XCTAssertEqual(burn(cards: [valueCard(1250)], purchases: [purchase(1000)]).performance, .excellent)
        XCTAssertEqual(burn(cards: [valueCard(1100)], purchases: [purchase(1000)]).performance, .ahead)
        XCTAssertEqual(burn(cards: [valueCard(750)], purchases: [purchase(1000)]).performance, .heavyBurn)
        XCTAssertEqual(burn(cards: [valueCard(900)], purchases: [purchase(1000)]).performance, .behind)
        XCTAssertEqual(burn(cards: [valueCard(1000)], purchases: [purchase(1000)]).performance, .breakEven)
        XCTAssertEqual(burn(cards: [valueCard(nil)], purchases: [purchase(1000)]).performance, .unknown)
        XCTAssertEqual(burn(cards: [valueCard(100), valueCard(nil)], purchases: [purchase(1000)]).performance, .heavyBurn)
        XCTAssertEqual(burn(cards: [valueCard(100)], purchases: [purchase(0)]).performance, .unknown)
    }
    func testDeficitUsesWholePurchaseOnceAndExcludesSuppliesAndOtherCurrency() {
        let summary = burn(cards: [valueCard(600)], purchases: [purchase(1000, quantity: 5), purchase(9000, category: .supplies), purchase(5000, category: .other), purchase(100000, currency: "USD")])
        XCTAssertEqual(summary.spentCents, 1000); XCTAssertEqual(summary.purchaseCount, 1)
        XCTAssertEqual(summary.burnLowCents, 400); XCTAssertEqual(summary.burnHighCents, 400)
        XCTAssertEqual(summary.mood, .roasted)
    }
    func testDifferentCurrencyValuesCannotOffsetSpending() {
        let summary = burn(cards: [valueCard(20000, currency: "USD")], purchases: [purchase(1000)])
        XCTAssertNil(summary.valueLowCents); XCTAssertNil(summary.burnLowCents); XCTAssertEqual(summary.mood, .curious)
    }
    func testExplicitManualEstimateEnablesComparisonButDoesNotChangeMarketHistory() throws {
        var library = Library(); library.cards = [valueCard(nil)]
        library.purchases = [purchase(1000)]
        try library.setManualBurnValue(amountCents: 500, currency: "EUR")
        let stats = CollectionStatistics(library: library)
        let summary = BurnCount(statistics: stats, currency: "EUR", manualValueCents: library.currentManualBurnValue(currency: "EUR")?.amountCents)
        XCTAssertTrue(summary.isManualValue); XCTAssertTrue(summary.canCompare)
        XCTAssertEqual(summary.burnHighCents, 500); XCTAssertEqual(summary.mood, .roasted)
        XCTAssertNil(stats.portfolioValue(currency: "EUR")); XCTAssertTrue(library.portfolioValues().isEmpty)
        XCTAssertFalse(library.recordPortfolioObservation())
        library.cards.append(valueCard(100))
        XCTAssertNil(library.currentManualBurnValue(currency: "EUR"))
    }
    func testManualValuePersistenceZeroAndRemoval() throws {
        var library = Library(); library.cards = [valueCard(100)]
        try library.setManualBurnValue(amountCents: 0, currency: "EUR")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root); try disk.save(library)
        var restored = try disk.load()
        XCTAssertEqual(restored.currentManualBurnValue(currency: "EUR")?.amountCents, 0)
        XCTAssertNil(restored.currentManualBurnValue(currency: "USD"))
        XCTAssertThrowsError(try restored.setManualBurnValue(amountCents: -1, currency: "EUR"))
        XCTAssertThrowsError(try restored.setManualBurnValue(amountCents: 100, currency: "BAD"))
        try restored.setManualBurnValue(amountCents: nil, currency: "EUR")
        XCTAssertNil(restored.currentManualBurnValue(currency: "EUR"))
    }

    func testEstimatesJoinKnownValuesWithoutMixingCurrenciesOrCountingUnknownCards() {
        var library = Library()
        let exact = valueCard(1000)
        let estimate = valueCard(nil)
        let unknown = valueCard(nil)
        library.cards = [exact, estimate, unknown, valueCard(99999, currency: "USD")]
        library.purchases = [purchase(2000)]
        let cached = CollectionCardValue(cardID: estimate.id, currency: "EUR", lowCents: 500, highCents: 500,
            isEstimate: true, basis: "Card Scout Value", checkedAt: "2026-11-07", isScoutEstimate: true)
        let stats = CollectionStatistics(library: library, asOf: now, cachedValues: [cached])
        XCTAssertEqual(stats.estimatedCollectionValue(currency: "EUR")?.low, 1500)
        XCTAssertEqual(stats.estimatedCollectionValue(currency: "EUR")?.high, 1500)
        XCTAssertEqual(stats.portfolioValue(currency: "EUR")?.low, 1500)
        let result = BurnCount(statistics: stats, currency: "EUR")
        XCTAssertEqual(result.valueLowCents, 1500); XCTAssertEqual(result.burnHighCents, 500)
        XCTAssertEqual(result.pricedCards, 2); XCTAssertTrue(result.includesModeledValues)
        XCTAssertTrue(result.isIndicative)
    }

}
