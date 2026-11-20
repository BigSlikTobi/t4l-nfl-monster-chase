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

    func testCardScoutValueIsSharedByCollectionAndBurnCount() throws {
        var value = analysis([reference("ask", 900)])
        XCTAssertNil(value.insights?.marketSummary(asOf: now))
        XCTAssertNotNil(value.insights?.askingSummary(asOf: now))
        XCTAssertNil(value.cardScoutValue(asOf: now))
        value.insights?.scoutEstimate = estimate(600)
        var library = Library()
        library.cards = [OwnedCard(state: "analyzed", analysis: value)]
        XCTAssertEqual(library.portfolioValues(asOf: now).first?.comparisonKey, "scout-estimate|excluded")
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now))
        XCTAssertNil(library.cards[0].personalPrice)
        let statistics = CollectionStatistics(library: library, asOf: now)
        XCTAssertEqual(statistics.totalCards, 1)
        XCTAssertEqual(statistics.values.first?.basis, "Card Scout Value")
        let burn = BurnCount(statistics: statistics, currency: "USD")
        XCTAssertEqual(burn.valueLowCents, 600)
        XCTAssertEqual(burn.pricedCards, 1)
        XCTAssertTrue(burn.isIndicative)
        library.cards[0].analysis?.insights?.marketReferences.append(reference("sold", 200))
        XCTAssertEqual(library.portfolioValues(asOf: now).first?.lowCents, 600)
        library.cards[0].analysis?.insights?.marketReferences.append(reference("sold", 400))
        XCTAssertEqual(library.portfolioValues(asOf: now).first?.lowCents, 600)
        XCTAssertEqual(library.portfolioChange(currency: "USD", asOf: now)?.deltaCents, 0)
    }

    func testPreviouslyStoredSaleDoesNotBecomeCardScoutValueHistory() {
        var library = Library()
        library.cards = [OwnedCard(state: "analyzed", analysis: analysis([reference("sold", 200)]))]
        let old = PortfolioCardValue(cardID: library.cards[0].id, identityKey: "prior", comparisonKey: "sold|excluded",
            currency: "USD", lowCents: 200, highCents: 200)
        library.portfolioHistory = [PortfolioObservation(id: "prior", observedAt: now, totalCards: 1, values: [old])]
        XCTAssertNil(library.portfolioChange(currency: "USD", asOf: now))
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now))
        XCTAssertEqual(library.portfolioHistory?.last?.displayedValues.first?.comparisonKey, "exact-sale|excluded")
        XCTAssertTrue(library.portfolioHistory?[0].displayedValues.isEmpty == true)
        library.cards[0].analysis = analysis([reference("ask", 900)])
        library.cards[0].analysis?.insights?.scoutEstimate = estimate(600)
        XCTAssertNil(library.portfolioChange(currency: "USD", asOf: now))
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now.addingTimeInterval(30)))
        library.cards[0].analysis?.insights?.scoutEstimate = estimate(650)
        XCTAssertEqual(library.portfolioChange(currency: "USD", asOf: now.addingTimeInterval(60))?.deltaCents, 50)
    }

    func testExactSalesContributeOnceAcrossRankingBurnAndHistoryAfterRestart() throws {
        let sold = OwnedCard(id: "sale", state: "analyzed", analysis: analysis([
            reference("sold", 300), reference("sold", 350), reference("ask", 2000)]))
        var modeled = OwnedCard(id: "model", state: "analyzed", analysis: analysis([reference("sold", 2000)]))
        modeled.analysis?.insights?.scoutEstimate = estimate(280)
        let asks = OwnedCard(id: "asks", state: "analyzed", analysis: analysis([reference("ask", 9999)]))
        var library = Library()
        library.cards = [asks, modeled, sold]
        library.purchases = [CardPurchase(title: "Pack", amountCents: 1000, currency: "USD", purchasedOn: "2026-11-16")]
        var cache = DashboardValueCache()
        func checkValues() {
            let stats = CollectionStatistics(library: library, asOf: now, cachedValues: cache.values(in: library, asOf: now))
            XCTAssertEqual(stats.ranked(currency: "USD").map(\.cardID), ["sale", "model"])
            XCTAssertEqual(stats.values.first { $0.cardID == "sale" }?.saleQuote?.saleCount, 2)
            XCTAssertEqual(stats.estimatedCollectionValue(currency: "USD")?.low, 605)
            XCTAssertEqual(stats.portfolioValue(currency: "USD")?.low, 605)
            XCTAssertEqual(BurnCount(statistics: stats, currency: "USD").burnLowCents, 395)
            XCTAssertEqual(cache.collectionQuote(for: library.cards[2], asOf: now)?.amountCents, 325)
            let portfolio = library.portfolioValues(asOf: now, cachedValues: cache.portfolioValues(in: library, asOf: now))
            XCTAssertEqual(portfolio.map(\.lowCents), [280, 325])
        }
        checkValues()
        cache.updateSale(for: sold, asOf: now)
        cache = try JSONDecoder().decode(DashboardValueCache.self, from: JSONEncoder().encode(cache))
        library.cards[2].analysis?.insights = nil
        checkValues()
        let cached = cache.portfolioValues(in: library, asOf: now)
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now, cachedValues: cached))
        library.cards[2].analysis = analysis([reference("sold", 370)])
        XCTAssertEqual(library.portfolioChange(currency: "USD", asOf: now, cachedValues: cached)?.deltaCents, 45)
        library.cards[2].analysis = analysis([reference("sold", 370, shipping: "included")])
        XCTAssertEqual(library.portfolioChange(currency: "USD", asOf: now, cachedValues: cached)?.matchedCards, 1)
        try library.setPersonalPrice(cardID: "sale", amountCents: 100, currency: "USD", asOf: now)
        let stats = CollectionStatistics(library: library, asOf: now, cachedValues: cache.values(in: library, asOf: now))
        XCTAssertEqual(cache.collectionQuote(for: library.cards[2], asOf: now)?.amountCents, 100)
        XCTAssertEqual(cache.binderQuote(for: library.cards[2], asOf: now)?.amountCents, 370)
        XCTAssertEqual(stats.ranked(currency: "USD").map(\.lowCents), [280, 100])
        XCTAssertEqual(BurnCount(statistics: stats, currency: "USD").burnLowCents, 620)
        XCTAssertEqual(library.portfolioChange(currency: "USD", asOf: now, cachedValues: cached)?.deltaCents, 0)
        XCTAssertTrue(cache.portfolioValues(in: library, asOf: now.addingTimeInterval(3601)).isEmpty)
    }

    private func estimate(_ cents: Int) -> CardScoutValue {
        CardScoutValue(amountCents: cents, currency: "USD", shipping: "excluded", checkedAt: "2026-11-17",
            expiresAt: now.timeIntervalSince1970 + 3600)
    }

    func testOlderAskingOnlyDashboardValuesAreIgnored() {
        let card = OwnedCard(state: "analyzed", analysis: analysis([reference("ask", 900)]))
        var cache = DashboardValueCache()
        let oldValue = CollectionCardValue(cardID: card.id, currency: "USD", lowCents: 900, highCents: 900,
            isEstimate: false, basis: "Einzelangebot", checkedAt: "2026-11-17")
        cache.update(card: card, value: oldValue, refreshAfter: now.addingTimeInterval(60), asOf: now)
        XCTAssertNil(cache.value(for: card))
        XCTAssertFalse(cache.isFresh(card, asOf: now))
    }

    func testSoldOnlyHasNoInventedAskingPrice() {
        let card = analysis([reference("sold", 100), reference("sold", 2050)])
        let info = card.insights!
        XCTAssertNotNil(info.marketSummary(asOf: now))
        XCTAssertNil(info.askingSummary(asOf: now))
        XCTAssertNil(card.cardScoutValue(asOf: now))
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
        value.insights?.scoutEstimate = estimate(350)
        value.cardSightVariants = [CardSightVariant(id: "base", name: "Base", medianCents: 100,
            askingMedianCents: 500, soldCount: 1, askingCount: 1, askingCurrency: "USD", soldShipping: "excluded", askingShipping: "unknown", currency: "USD", expiresAt: now.timeIntervalSince1970 + 3600, scoutValue: estimate(350))]
        let expired = value.currentPricing(asOf: now.addingTimeInterval(3601))
        XCTAssertNil(expired.insights?.marketSummary(asOf: now.addingTimeInterval(3601)))
        XCTAssertNil(expired.insights?.askingSummary(asOf: now.addingTimeInterval(3601)))
        XCTAssertNil(expired.cardSightVariants?.first?.medianCents)
        XCTAssertNil(expired.cardSightVariants?.first?.askingMedianCents)
        XCTAssertNil(expired.cardSightVariants?.first?.soldCount)
        XCTAssertNil(expired.cardSightVariants?.first?.askingCount)
        XCTAssertNil(expired.cardSightVariants?.first?.askingCurrency)
        XCTAssertNil(expired.cardSightVariants?.first?.askingShipping)
        XCTAssertNil(expired.cardSightVariants?.first?.scoutValue)
        XCTAssertNil(expired.insights?.scoutEstimate)
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
        value.insights?.scoutEstimate = estimate(350)
        value.cardSightVariants = [CardSightVariant(id: "orange", name: "Orange", numberedTo: 25, medianCents: 100,
            askingMedianCents: 500, soldCount: 1, askingCount: 1, askingCurrency: "USD", soldShipping: "excluded", askingShipping: "unknown", currency: "USD", expiresAt: now.timeIntervalSince1970 + 3600, scoutValue: estimate(350))]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        try disk.writePhoto(Data([1, 2, 3]), name: "front.jpg")
        var library = Library()
        library.cards = [OwnedCard(id: "saved-card", state: "analyzed", frontFile: "front.jpg", analysis: value)]
        library.cards[0].personalPrice = PersonalCardPrice(amountCents: 700, currency: "EUR", recordedAt: "2026-11-17")
        var prior = library
        prior.cards[0].analysis?.insights?.scoutEstimate = nil
        prior.cards[0].analysis?.cardSightVariants?[0].scoutValue = nil
        try disk.save(prior)
        let libraryFile = root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: libraryFile)
        try disk.save(library)
        XCTAssertEqual(try Data(contentsOf: libraryFile), before)
        let restored = try disk.load()
        let clean = try XCTUnwrap(restored.cards[0].analysis)
        XCTAssertTrue(clean.insights!.marketReferences.isEmpty)
        XCTAssertNil(clean.cardSightVariants?.first?.medianCents)
        XCTAssertNil(clean.cardSightVariants?.first?.askingMedianCents)
        XCTAssertNil(clean.cardSightVariants?.first?.soldCount)
        XCTAssertNil(clean.cardSightVariants?.first?.askingCount)
        XCTAssertNil(clean.cardSightVariants?.first?.askingCurrency)
        XCTAssertNil(clean.cardSightVariants?.first?.askingShipping)
        XCTAssertNil(clean.cardSightVariants?.first?.scoutValue)
        XCTAssertNil(clean.insights?.scoutEstimate)
        XCTAssertEqual(clean.cardSightVariants?.first?.id, "orange")
        XCTAssertEqual(clean.cardSightVariants?.first?.numberedTo, 25)
        XCTAssertEqual(restored.cards[0].id, "saved-card")
        XCTAssertEqual(restored.cards[0].personalPrice, library.cards[0].personalPrice)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL("front.jpg")), Data([1, 2, 3]))
        XCTAssertEqual(library.cards[0].analysis?.insights?.marketReferences.count, 2)
    }
}
