import XCTest
@testable import CardScoutCore

final class PortfolioTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!
    func card(_ id: String, price: Int = 1000, currency: String = "EUR", action: String = "Grade") -> OwnedCard {
        var analysis = CardAnalysis(recommendation: action, marketCheckedAt: "2026-11-01", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: false)
        analysis.player = "Player"; analysis.identityConfirmed = true; analysis.cardNumber = id; analysis.setName = "Fixture"
        let reference = MarketReference(provider: "Fixture", url: "https://example.invalid/guide", kind: "guide", grade: "raw", matchQuality: "exact", lowCents: price, highCents: price,
            currency: currency, checkedAt: "2026-11-01", shipping: "not_applicable")
        analysis.insights = CardInsights(rarityTier: "base", rarityBullets: [], conditionStatus: "no_obvious_damage", conditionIssues: [], conditionLimitations: [], marketBullets: [], marketReferences: [reference], sourceChecks: [], actionReason: "Check condition and costs.")
        analysis.setFixtureScoutValue(price, currency: currency, asOf: now, validFor: 7200)
        return OwnedCard(id: id, state: "analyzed", analysis: analysis)
    }
    func testNewCardsAreNotMarketGainsAndCurrenciesNeverMix() {
        var library = Library(); library.cards = [card("a"), card("usd", price: 9000, currency: "USD")]
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now))
        library.cards[0] = card("a", price: 1200)
        library.cards.append(card("new", price: 100000))
        let change = library.portfolioChange(currency: "EUR", asOf: now.addingTimeInterval(3600))
        XCTAssertEqual(change?.matchedCards, 1)
        XCTAssertEqual(change?.deltaCents, 200)
        XCTAssertEqual(change?.largestMove?.cardID, "a")
        XCTAssertEqual(change?.largestMove?.deltaCents, 200)
        XCTAssertEqual(change?.percentage ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(library.portfolioChange(currency: "USD", asOf: now)?.deltaCents, 0)
        XCTAssertNil(library.portfolioChange(currency: "GBP", asOf: now))
    }
    func testInsightsSeparatesCurrenciesAndDatesHistoricalValues() throws {
        var library = Library()
        library.cards = [card("personal"), card("market", price: 1500), card("usd", price: 8000, currency: "USD")]
        try library.setPersonalPrice(cardID: "personal", amountCents: 2400, currency: "EUR", asOf: now)
        library.recordPortfolioObservation(asOf: now)
        var stats = CollectionStatistics(library: library, asOf: now)
        let eur = InsightValuation(statistics: stats, history: library.portfolioHistory ?? [], selected: "")
        XCTAssertEqual(eur.currency, "EUR")
        XCTAssertEqual(eur.ranking.map(\.cardID), ["personal", "market"])
        XCTAssertEqual(eur.lowCents, 3900)
        XCTAssertNil(eur.saved)
        library.cards.removeLast()
        stats = CollectionStatistics(library: library, asOf: now)
        let historic = InsightValuation(statistics: stats, history: library.portfolioHistory ?? [], selected: "USD")
        XCTAssertEqual(historic.saved?.observedAt, now)
        XCTAssertEqual(historic.lowCents, 8000)
        XCTAssertTrue(historic.ranking.isEmpty)
        let empty = InsightValuation(statistics: CollectionStatistics(library: Library()), history: [], selected: "EUR")
        XCTAssertNil(empty.lowCents)
    }

    func testLargestMoveUsesAbsoluteChangeAndExcludesPersonalEdits() throws {
        var library = Library()
        library.cards = [card("a"), card("b"), card("personal")]
        library.recordPortfolioObservation(asOf: now)
        library.cards[0] = card("a", price: 1250)
        library.cards[1] = card("b", price: 450)
        try library.setPersonalPrice(cardID: "personal", amountCents: 25000, currency: "EUR", asOf: now)
        let move = library.portfolioChange(currency: "EUR", asOf: now)?.largestMove
        XCTAssertEqual(move?.cardID, "b")
        XCTAssertEqual(move?.deltaCents, -550)
    }

    func testMissingPricesCorrectionsAndBasisChangesCannotBecomeLosses() {
        var library = Library(); library.cards = [card("a"), card("b")]
        library.recordPortfolioObservation(asOf: now)
        library.cards.removeLast()
        XCTAssertEqual(library.portfolioChange(currency: "EUR", asOf: now)?.deltaCents, 0)
        library.cards[0].analysis?.parallel = "Corrected variant"
        XCTAssertNil(library.portfolioChange(currency: "EUR", asOf: now))
        library.cards = [card("a")]; library.cards[0].analysis?.setFixtureScoutValue(1000, shipping: "included", asOf: now)
        XCTAssertNil(library.portfolioChange(currency: "EUR", asOf: now))
        library.cards[0].analysis?.insights?.scoutEstimate = nil
        XCTAssertNil(library.portfolioChange(currency: "EUR", asOf: now))
        XCTAssertFalse(library.recordPortfolioObservation(asOf: now.addingTimeInterval(1)))
        XCTAssertEqual(library.portfolioHistory?.count, 1)
    }
    func testIntradayUpdatesPreserveBaselineAndSnapshotsPersistWithoutProviderEvidence() throws {
        var library = Library(); library.cards = [card("a")]
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now))
        XCTAssertFalse(library.recordPortfolioObservation(asOf: now))
        for index in 1...4 {
            library.cards = [card("a", price: 1000 + index * 100)]
            library.recordPortfolioObservation(asOf: now.addingTimeInterval(Double(index * 60)))
        }
        XCTAssertEqual(library.portfolioHistory?.count, 2)
        XCTAssertEqual(library.portfolioHistory?.first?.values.first?.lowCents, 1000)
        XCTAssertEqual(library.portfolioHistory?.last?.values.first?.lowCents, 1400)
        let tomorrow = now.addingTimeInterval(86400)
        library.cards[0].analysis?.setFixtureScoutValue(1400, asOf: tomorrow)
        XCTAssertTrue(library.recordPortfolioObservation(asOf: tomorrow))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root); try disk.save(library)
        XCTAssertEqual(try disk.load().portfolioHistory, library.portfolioHistory)
        let bytes = try JSONEncoder().encode(library.portfolioHistory)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("example.invalid"))
    }
    func testExpiredProviderSnapshotRemainsHistoricalWithoutBecomingCurrentPrice() throws {
        var library = Library(); var value = card("a")
        value.analysis?.insights?.marketReferences[0].provider = "Slabline"
        value.analysis?.insights?.marketReferences[0].expiresAt = now.timeIntervalSince1970 + 60
        value.analysis?.setFixtureScoutValue(1000, asOf: now, validFor: 60)
        library.cards = [value]
        XCTAssertTrue(library.recordPortfolioObservation(asOf: now))
        XCTAssertTrue(library.portfolioValues(asOf: now.addingTimeInterval(120)).isEmpty)
        XCTAssertNil(library.portfolioChange(currency: "EUR", asOf: now.addingTimeInterval(120)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root); try disk.save(library)
        let restored = try disk.load()
        XCTAssertEqual(restored.portfolioHistory?.first?.values.first?.lowCents, 1000)
        XCTAssertTrue(restored.cards[0].analysis!.insights!.marketReferences.isEmpty)
        let bytes = try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8)
        XCTAssertFalse(bytes.contains("Slabline")); XCTAssertFalse(bytes.contains("example.invalid"))
    }

    func testEmptyAndOldLibrariesDoNotInventZeroHistory() throws {
        var library = Library(); XCTAssertFalse(library.recordPortfolioObservation(asOf: now))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as! [String: Any]
        object.removeValue(forKey: "portfolioHistory")
        XCTAssertNil(try JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: object)).portfolioHistory)
    }
    func testOnlyExplicitSupportedRecommendationsArePromoted() {
        var library = Library(); let good = card("good")
        var damaged = card("damaged"); damaged.analysis?.insights?.conditionStatus = "visible_damage"
        var uncertain = card("uncertain"); uncertain.analysis?.identityConfirmed = false
        var needsReview = card("review"); needsReview.analysis?.needsReview = true
        var pending = card("pending"); pending.state = "enriching"
        var cleared = card("cleared"); cleared.analysis?.insights = nil
        var draft = card("draft"); draft.isScanDraft = true
        library.cards = [good, damaged, uncertain, needsReview, pending, cleared, draft, card("keep", action: "Keep"), card("sell", action: "Sell")]
        XCTAssertEqual(library.recommendedCards("Grade").map(\.id), ["good"])
        XCTAssertEqual(library.recommendedCards("Keep").map(\.id), ["keep"])
        XCTAssertEqual(library.recommendedCards("Sell").map(\.id), ["sell"])
        XCTAssertTrue(library.recommendedCards("Bulk").isEmpty)
    }
    func testRawEvidenceCannotChangeTheModeledPortfolioValue() {
        var library = Library(); var value = card("a")
        value.analysis?.insights?.marketReferences[0].highCents = 2000
        library.cards = [value]; library.recordPortfolioObservation(asOf: now)
        value.analysis?.insights?.marketReferences[0].lowCents = 2000
        value.analysis?.insights?.marketReferences[0].highCents = 3000
        library.cards = [value]
        XCTAssertEqual(library.portfolioChange(currency: "EUR", asOf: now)?.deltaCents, 0)
        library.cards[0].analysis?.identityConfirmed = false
        XCTAssertTrue(library.portfolioValues(asOf: now).isEmpty)
    }
}
