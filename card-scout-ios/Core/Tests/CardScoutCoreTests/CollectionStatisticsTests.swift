import XCTest
@testable import CardScoutCore

final class CollectionStatisticsTests: XCTestCase {
    let today = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
    func reference(_ price: Int, match: String = "exact", currency: String = "USD", shipping: String = "excluded", date: String = "2026-10-10", item: String? = nil) -> MarketReference {
        MarketReference(provider: "SportsCardsPro", url: "https://www.sportscardspro.com/game/fixture", kind: "sold", grade: "raw", matchQuality: match,
            lowCents: price, highCents: price, currency: currency, saleDate: date, checkedAt: "2026-10-16", shipping: shipping, listingURL: item)
    }
    func card(_ id: String, refs: [MarketReference] = [], confirmed: Bool = true, serial: String? = nil) -> OwnedCard {
        var a = CardAnalysis(recommendation: "Keep", marketCheckedAt: "2026-10-16", marketSources: [], confidence: "high", conditionNotes: "", rationale: "", needsReview: !confirmed)
        a.player = "Player \(id)"; a.identityConfirmed = confirmed; a.collectionID = confirmed ? "fixture-set" : nil; a.cardNumber = id
        a.serialNumber = serial
        a.insights = CardInsights(rarityTier: serial == nil ? "base" : "numbered", rarityBullets: [], conditionStatus: "no_obvious_damage",
            conditionIssues: [], conditionLimitations: [], marketBullets: [], marketReferences: refs, sourceChecks: [], actionReason: "")
        return OwnedCard(id: id, createdAt: "2026-10-16T10:00:00Z", state: "analyzed", analysis: a)
    }
    func stats(cards: [OwnedCard] = [], purchases: [CardPurchase] = []) -> CollectionStatistics {
        var library = Library(); library.cards = cards; library.purchases = purchases
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return CollectionStatistics(library: library, asOf: today, calendar: calendar)
    }
    func testDecimalAmountsAreExactAndAmbiguousAmountsRejected() {
        XCTAssertEqual(CardPurchase.parseAmount("19,99"), 1999)
        XCTAssertEqual(CardPurchase.parseAmount("19.9"), 1990)
        XCTAssertEqual(CardPurchase.parseAmount(" 20 "), 2000)
        for invalid in ["-1", "1.999", "1,234.56", "0", "1e3", "€20", "1000001"] { XCTAssertNil(CardPurchase.parseAmount(invalid)) }
    }
    func testPurchaseTotalIsNotMultipliedByQuantityAndCurrenciesStaySeparate() {
        let euros = CardPurchase(title: "5 packs with shipping", amountCents: 2599, quantity: 5, purchasedOn: "2026-10-15")
        let dollars = CardPurchase(title: "Box", category: .box, amountCents: 12000, currency: "USD", purchasedOn: "2026-10-15")
        let snapshot = stats(purchases: [euros, dollars])
        XCTAssertEqual(snapshot.spending(currency: "EUR"), 2599)
        XCTAssertEqual(snapshot.spending(currency: "USD", category: .box), 12000)
        XCTAssertEqual(snapshot.spending(currency: "USD", category: .pack), 0)
    }
    func testInvalidOrFuturePurchasesAreNotCounted() {
        var purchase = CardPurchase(title: "Box", amountCents: 1000, purchasedOn: "2026-02-30")
        XCTAssertFalse(purchase.isValid)
        XCTAssertTrue(stats(purchases: [purchase]).purchases.isEmpty)
        purchase.purchasedOn = "2026-10-17"
        XCTAssertTrue(stats(purchases: [purchase]).purchases.isEmpty)
    }
    func testConfirmedMedianValuesAndMissingPricesStayDistinct() {
        let snapshot = stats(cards: [card("a", refs: [reference(100), reference(200), reference(900)]), card("b")])
        XCTAssertEqual(snapshot.confirmedValue(currency: "USD")?.low, 200)
        XCTAssertEqual(snapshot.pricedCards, 1)
        XCTAssertEqual(snapshot.totalCards, 2)
        XCTAssertNil(stats(cards: [card("b")]).confirmedValue(currency: "USD"))
    }
    func testUncertainVariantUsesMedianAsSeparateIndicatorOnly() {
        let snapshot = stats(cards: [card("pitts", refs: [reference(150, match: "near"), reference(179, match: "near"), reference(199, match: "near")], confirmed: false)])
        XCTAssertEqual(snapshot.values.first?.lowCents, 179)
        XCTAssertEqual(snapshot.values.first?.basis, "Median · 3 Vergleichsverkäufe")
        XCTAssertEqual(snapshot.indicativeCards, 1)
        XCTAssertEqual(snapshot.pricedCards, 0)
        XCTAssertNil(snapshot.confirmedValue(currency: "USD"))
    }
    private func verifiedUnpricedBase() -> OwnedCard {
        var base = card("base")
        base.analysis?.subset = "Base"
        base.analysis?.cardSightIdentity = CardSightIdentity(cardID: "base", setID: "set")
        base.analysis?.unpricedBaseExpiresAt = today.addingTimeInterval(600).timeIntervalSince1970
        return base
    }

    func testVerifiedEmptyBaseCountsAsZeroEURWithoutCreatingMarketEvidence() {
        let base = verifiedUnpricedBase()
        var library = Library(); library.cards = [base, card("unknown")]
        let stats = CollectionStatistics(library: library, asOf: today)
        XCTAssertEqual(stats.values.map(\.cardID), [base.id])
        XCTAssertTrue(stats.values[0].isUnpricedBase)
        XCTAssertEqual(stats.portfolioValue(currency: "EUR")?.low, 0)
        XCTAssertNil(stats.confirmedValue(currency: "EUR"))
        XCTAssertEqual(stats.pricedCards, 0); XCTAssertEqual(stats.indicativeCards, 0)
        XCTAssertNil(base.analysis?.marketSummary); XCTAssertNil(base.analysis?.askingSummary)
        let burn = BurnCount(statistics: stats, currency: "EUR")
        XCTAssertEqual(burn.pricedCards, 1); XCTAssertEqual(burn.totalCards, 2)
        XCTAssertEqual(burn.valueHighCents, 0)
        XCTAssertNil(BurnCount(statistics: stats, currency: "USD").valueHighCents)
        XCTAssertTrue(library.recordPortfolioObservation(asOf: today))
        XCTAssertNil(library.portfolioChange(currency: "EUR", asOf: today))
        let saved = library.portfolioValues(asOf: today)
        XCTAssertTrue(library.portfolioValues(asOf: today.addingTimeInterval(601), cachedValues: saved).isEmpty)
    }

    func testDollarAskingBaselineCountsEuroBaseZeroOnce() {
        var ask = reference(300)
        ask.kind = "ask"
        var priced = card("priced")
        priced.analysis?.insights?.marketReferences = [ask]
        var library = Library()
        library.cards = [priced, verifiedUnpricedBase(), card("unknown")]
        let burn = BurnCount(statistics: CollectionStatistics(library: library, asOf: today), currency: "USD")
        XCTAssertEqual(burn.valueLowCents, 300)
        XCTAssertEqual(burn.pricedCards, 2)
        XCTAssertEqual(burn.totalCards, 3)
    }

    func testEmptyBaseExpiresAndConflictingOrPendingVariantsStayUnknown() {
        let base = verifiedUnpricedBase()
        XCTAssertNil(base.unpricedBaseValue(asOf: today.addingTimeInterval(600)))
        let mutations: [(inout CardAnalysis) -> Void] = [
            { $0.unpricedBaseExpiresAt = nil }, { $0.unpricedBaseExpiresAt = .infinity },
            { $0.unpricedBaseExpiresAt = self.today.addingTimeInterval(90_000).timeIntervalSince1970 },
            { $0.serialNumber = "1/5" }, { $0.identityConfirmed = false },
            { $0.subset = "Insert" }, { $0.parallel = "Silver" }, { $0.cardSightIdentity?.slabbed = true },
            { $0.cardSightIdentity?.parallelID = "silver" }, { $0.clearAssessmentAfterCorrection() }
        ]
        for mutate in mutations {
            var changed = base
            mutate(&changed.analysis!)
            XCTAssertNil(changed.unpricedBaseValue(asOf: today))
        }
        var pending = base; pending.state = "queued"
        XCTAssertNil(pending.unpricedBaseValue(asOf: today))
        var chromeRookie = base
        chromeRookie.analysis?.rookie = true; chromeRookie.analysis?.subset = "Chrome Base"
        XCTAssertTrue(chromeRookie.unpricedBaseValue(asOf: today)?.isUnpricedBase == true)
        var ask = reference(500); ask.kind = "ask"
        var listed = base; listed.analysis?.insights?.marketReferences = [ask]
        XCTAssertNil(listed.unpricedBaseValue(asOf: today))
        XCTAssertEqual(stats(cards: [listed]).values.first?.lowCents, 500)
    }

    func testResearchCachedValuesAndManualPricesTakePriorityOverBaseZero() throws {
        let base = verifiedUnpricedBase()
        var priced = base
        priced.analysis?.insights?.marketReferences = [reference(500, currency: "USD")]
        let amount = try XCTUnwrap(stats(cards: [priced]).values.first)
        XCTAssertEqual(amount.lowCents, 500)
        var library = Library(); library.cards = [base]
        var cache = DashboardValueCache()
        cache.update(card: base, value: amount, refreshAfter: today.addingTimeInterval(600), asOf: today)
        cache.update(card: base, value: base.unpricedBaseValue(asOf: today), refreshAfter: today.addingTimeInterval(600), asOf: today)
        XCTAssertEqual(CollectionStatistics(library: library, asOf: today, cachedValues: cache.values(in: library)).values.first?.currency, "USD")
        try library.setPersonalPrice(cardID: base.id, amountCents: 150, currency: "GBP")
        let stats = CollectionStatistics(library: library, asOf: today, cachedValues: cache.values(in: library))
        XCTAssertEqual(stats.values.count, 1); XCTAssertEqual(stats.values.first?.lowCents, 150)
        XCTAssertEqual(stats.values.first?.currency, "GBP")
    }

    func testBaseAllowanceRoundTripsAndDoesNotMaskLaterMarketChanges() throws {
        var base = verifiedUnpricedBase()
        var library = Library(); library.cards = [base]
        XCTAssertTrue(library.recordPortfolioObservation(asOf: today))
        library.cards[0].analysis?.insights?.marketReferences = [reference(500, currency: "EUR")]
        let later = today.addingTimeInterval(60)
        XCTAssertNil(library.portfolioChange(currency: "EUR", asOf: later))
        XCTAssertTrue(library.recordPortfolioObservation(asOf: later))
        library.cards[0].analysis?.insights?.marketReferences = [reference(600, currency: "EUR")]
        XCTAssertEqual(library.portfolioChange(currency: "EUR", asOf: today.addingTimeInterval(120))?.deltaCents, 100)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try DiskStore(root: directory)
        let photo = Data([2, 3, 5])
        base.frontFile = "base.jpg"
        try disk.writePhoto(photo, name: base.frontFile)
        let now = Date()
        base.analysis?.unpricedBaseExpiresAt = now.addingTimeInterval(600).timeIntervalSince1970
        library.cards = [base]
        try disk.save(library)
        let restored = try disk.load()
        XCTAssertEqual(restored.cards, library.cards)
        XCTAssertTrue(restored.cards[0].unpricedBaseValue(asOf: now)?.isUnpricedBase == true)
        XCTAssertEqual(try Data(contentsOf: disk.photoURL(base.frontFile)), photo)
    }
    func testDuplicateSaleAcrossProvidersIsCountedOnce() {
        let a = reference(100, match: "near", item: "https://www.ebay.com/itm/123456789012?tracking=x")
        var same = a; same.provider = "eBay"; same.listingURL = "https://www.ebay.de/itm/123456789012"
        let b = reference(300, match: "near", item: "https://www.ebay.com/itm/123456789013")
        XCTAssertEqual(stats(cards: [card("a", refs: [a, same, b], confirmed: false)]).values.first?.lowCents, 200)
    }
    func testUncertainVariantMedianResistsOneExpensiveSale() {
        let refs = [100, 100, 100, 800].enumerated().map { index, amount in
            reference(amount, match: "near", item: "https://www.ebay.com/itm/12345678901\(index)")
        }
        let snapshot = stats(cards: [card("a", refs: refs, confirmed: false)])
        XCTAssertEqual(snapshot.values.first?.lowCents, 100)
        XCTAssertEqual(snapshot.values.first?.highCents, 100)
        XCTAssertEqual(snapshot.values.first?.basis, "Median · 4 Vergleichsverkäufe")
        XCTAssertNil(snapshot.confirmedValue(currency: "USD"))
    }
    func testEstimatesNeverMixShippingCurrencyGradeOrProxyMatches() {
        var graded = reference(90000, match: "near"); graded.grade = "PSA 10"
        let refs = [reference(100, match: "near"), reference(200, match: "near"), reference(5000, match: "near", currency: "EUR"),
                    reference(9000, match: "near", shipping: "included"), reference(10000, match: "proxy"), graded]
        let value = stats(cards: [card("a", refs: refs, confirmed: false)]).values.first
        XCTAssertEqual(value?.currency, "USD"); XCTAssertEqual(value?.lowCents, 150)
    }
    func testPendingAndLowConfidenceCardsDoNotInventPricesOrHighlights() {
        var pending = card("a", refs: [reference(1000)], serial: "1/1"); pending.state = "enriching"
        var low = card("b", refs: [reference(5000)], confirmed: false, serial: "1/1"); low.analysis?.confidence = "low"
        let snapshot = stats(cards: [pending, low])
        XCTAssertTrue(snapshot.values.isEmpty)
        XCTAssertNil(snapshot.specialCardID)
    }
    func testSmallestVisibleNumberingWinsAndCopiesCountAsExtras() {
        var extra = card("duplicate"); extra.analysis?.cardNumber = "a"
        let snapshot = stats(cards: [card("a", serial: "05/99"), card("b", serial: "2/10"), extra])
        XCTAssertEqual(snapshot.specialCardID, "b")
        XCTAssertEqual(snapshot.duplicateExtras, 1)
        XCTAssertEqual(snapshot.numberedCards, 2)
        for bad in ["/99", "0/99", "100/99", "maybe 1/1", "unknown"] { XCTAssertNil(CollectionStatistics.serialLimit(bad)) }
    }
    func testGrowthCountsFractionalTimestampsAndExcludesFutureCaptures() {
        var a = card("a"); a.createdAt = "2026-10-15T23:00:00.123Z"
        var future = card("future"); future.createdAt = "2026-10-17T10:00:00Z"
        let snapshot = stats(cards: [a, future])
        XCTAssertEqual(snapshot.growth.count, 14)
        XCTAssertEqual(snapshot.growth.last?.count, 1)
    }
    func testLedgerPersistsAndOldLibrariesStillDecode() throws {
        let old = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(Library()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "purchases")
        XCTAssertNil(try JSONDecoder().decode(Library.self, from: JSONSerialization.data(withJSONObject: object)).purchases)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try DiskStore(root: root)
        var library = old
        library.purchases = [CardPurchase(title: "Pack", amountCents: 1499, purchasedOn: "2026-10-16")]
        try disk.save(library)
        XCTAssertEqual(try disk.load().purchases, library.purchases)
    }
}
