import XCTest
@testable import CardScoutCore

final class DashboardValueCacheTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_794_000_000)
    func fixture() -> (Library, CollectionCardValue) {
        var library = Library()
        var a = CardAnalysis(recommendation: "Keep", marketCheckedAt: "2026-11-07", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
        a.player = "Fixture"; a.identityConfirmed = true
        a.setFixtureScoutValue(100, asOf: now)
        library.cards = [OwnedCard(id: "a", state: "analyzed", analysis: a)]
        return (library, CollectionStatistics(library: library, asOf: now).values[0])
    }
    func testReviewedPricesRequireSourceAndExactCatalogEdition() {
        let (library, _) = fixture()
        var card = library.cards[0]
        card.analysis?.assessmentSource = "photoReview"
        card.uploadedJobID = UUID().uuidString.lowercased()
        card.analysisJobID = UUID().uuidString.lowercased()
        card.analysis?.cardSightIdentity = CardSightIdentity(cardID: "card", setID: "set", parallelID: "finish")
        var incoming = card.analysis!
        XCTAssertTrue(card.canRequestPrices)
        XCTAssertTrue(card.acceptsPrices(from: card.uploadedJobID!, analysis: incoming))
        XCTAssertFalse(card.acceptsPrices(from: card.jobID, analysis: incoming))
        incoming.cardSightIdentity?.parallelID = nil
        XCTAssertFalse(card.acceptsPrices(from: card.uploadedJobID!, analysis: incoming))
    }

    func testMissingPricesGetSlotsBeforeCachedCardsAndRespectRetryTimes() {
        var (library, value) = fixture()
        var cache = DashboardValueCache()
        cache.update(card: library.cards[0], value: value, refreshAfter: now.addingTimeInterval(60), asOf: now)
        var missing = library.cards[0]
        missing.id = "new"
        missing.analysisJobID = "new-job"
        missing.analysis?.insights = nil
        library.cards.append(missing)
        func pending(_ at: Date, loading: Set<String> = [], retry: [String: Date] = [:]) -> [String] {
            cache.pendingPriceChecks(in: library, limit: 1, loading: loading, checked: [],
                                     retryAfter: retry, asOf: at).map(\.id)
        }
        XCTAssertEqual(pending(now), ["new"])
        XCTAssertEqual(pending(now.addingTimeInterval(65)), ["new"])
        XCTAssertEqual(pending(now, loading: [missing.jobID]), [])
        XCTAssertEqual(pending(now, retry: [missing.jobID: now.addingTimeInterval(20)]), [])
        XCTAssertEqual(pending(now, retry: [missing.jobID: now]), ["new"])
    }

    func testExactSaleSurvivesRestartAsSaleOnlyAndExpires() throws {
        let (library, _) = fixture()
        var card = library.cards[0]
        let day = String(ISO8601DateFormatter().string(from: now).prefix(10))
        var evidence = CardInsights.pricingOnly
        evidence.marketReferences = [MarketReference(provider: "CardSight", url: "https://example.com",
            kind: "sold", grade: "raw", matchQuality: "exact", lowCents: 280, highCents: 280,
            currency: "USD", saleDate: day, checkedAt: day, shipping: "unknown", expiresAt: now.timeIntervalSince1970 + 60)]
        card.analysis?.insights = evidence
        var cache = DashboardValueCache()
        cache.updateSale(for: card, asOf: now)
        card.analysis?.insights = nil
        cache = try JSONDecoder().decode(DashboardValueCache.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(cache.binderQuote(for: card, asOf: now)?.amountCents, 280)
        XCTAssertEqual(cache.binderQuote(for: card, asOf: now)?.saleCount, 1)
        XCTAssertNil(cache.value(for: card))
        XCTAssertNil(cache.binderQuote(for: card, asOf: now.addingTimeInterval(61)))
        card.analysisJobID = UUID().uuidString
        XCTAssertNil(cache.binderQuote(for: card, asOf: now))
    }

    func testCacheSurvivesRestartWithoutProviderEvidenceAndExpiresOnlyForRefresh() throws {
        var (library, value) = fixture()
        var cache = DashboardValueCache()
        cache.update(card: library.cards[0], value: value, refreshAfter: now.addingTimeInterval(100000), asOf: now)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        try disk.saveDashboardValues(cache)
        cache = disk.loadDashboardValues()
        XCTAssertTrue(cache.isFresh(library.cards[0], asOf: now.addingTimeInterval(10)))
        XCTAssertFalse(cache.isFresh(library.cards[0], asOf: now.addingTimeInterval(86401)))
        library.cards[0].analysis?.insights?.scoutEstimate = nil
        let stats = CollectionStatistics(library: library, asOf: now, cachedValues: cache.values(in: library))
        XCTAssertEqual(stats.values.first?.lowCents, 100)
        XCTAssertTrue(stats.values.first!.isCached)
        XCTAssertEqual(stats.portfolioValue(currency: "EUR")?.low, 100)
        let bytes = try String(contentsOf: root.appendingPathComponent("dashboard-values.json"), encoding: .utf8)
        XCTAssertFalse(bytes.contains("marketReferences")); XCTAssertFalse(bytes.contains("marketSources"))
    }
    func testRetakesIdentityCorrectionsAndRemovalsInvalidateCache() {
        let (original, value) = fixture()
        var cache = DashboardValueCache()
        cache.update(card: original.cards[0], value: value, refreshAfter: now.addingTimeInterval(60), asOf: now)
        var library = original
        library.cards[0].analysis?.parallel = "Gold"
        XCTAssertTrue(cache.values(in: library).isEmpty)
        library = original; library.cards[0].analysisJobID = UUID().uuidString
        XCTAssertTrue(cache.values(in: library).isEmpty)
        library = original; library.cards.removeAll()
        cache.prune(in: library)
        XCTAssertTrue(cache.entries.isEmpty)
    }
    func testFreshPricesReplaceCachedAmountAndAuthoritativeEmptyResultRemovesIt() {
        var (library, value) = fixture()
        var cache = DashboardValueCache()
        cache.update(card: library.cards[0], value: value, refreshAfter: now.addingTimeInterval(60), asOf: now)
        library.cards[0].analysis?.setFixtureScoutValue(300, asOf: now)
        var stats = CollectionStatistics(library: library, asOf: now, cachedValues: cache.values(in: library))
        XCTAssertEqual(stats.values.count, 1); XCTAssertEqual(stats.values[0].lowCents, 300)
        XCTAssertFalse(stats.values[0].isCached)
        value = CollectionCardValue(cardID: value.cardID, currency: value.currency, lowCents: 400, highCents: 400, isEstimate: true, basis: "Card Scout Value", checkedAt: "2026-11-07", isScoutEstimate: true)
        cache.update(card: library.cards[0], value: value, refreshAfter: now.addingTimeInterval(60), asOf: now)
        library.cards[0].analysis?.insights?.scoutEstimate = nil
        stats = CollectionStatistics(library: library, asOf: now, cachedValues: cache.values(in: library))
        XCTAssertEqual(stats.values.first?.lowCents, 400)
        cache.update(card: library.cards[0], value: nil, refreshAfter: now, asOf: now)
        XCTAssertTrue(cache.values(in: library).isEmpty)
    }
    func testFreshCacheKeepsHistoryAndBurnCountAvailableAfterRestart() throws {
        var (library, value) = fixture()
        let baseline = library.portfolioValues(asOf: now)
        var cache = DashboardValueCache()
        cache.update(card: library.cards[0], value: value, refreshAfter: now.addingTimeInterval(60), asOf: now,
                     portfolioValue: baseline[0])
        library.cards[0].analysis?.insights?.scoutEstimate = nil
        let cached = cache.portfolioValues(in: library, asOf: now)
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now, cachedValues: cached))
        XCTAssertEqual(library.portfolioHistory?.last?.values.first?.lowCents, 100)
        library.purchases = [CardPurchase(title: "Box", amountCents: 1000, purchasedOn: "2026-01-01")]
        let stats = CollectionStatistics(library: library, asOf: now, cachedValues: cache.values(in: library))
        let burn = BurnCount(statistics: stats, currency: "EUR")
        XCTAssertEqual(burn.burnLowCents, 900)
        XCTAssertEqual(burn.burnHighCents, 900)
        XCTAssertTrue(cache.portfolioValues(in: library, asOf: now.addingTimeInterval(61)).isEmpty)
    }

}
