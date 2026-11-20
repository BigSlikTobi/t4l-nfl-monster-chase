import Foundation

/// Last displayed amounts only. Provider evidence stays transient.
public struct DashboardValueCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        let jobID: String
        let identity: String
        let value: CollectionCardValue
        let savedAt: Date
        let refreshAfter: Date
        var portfolioValue: PortfolioCardValue?
    }
    private struct SaleEntry: Codable, Sendable {
        let jobID: String
        let identity: String
        let quote: BinderQuote
        let expiresAt: Double
    }
    private var sales: [String: SaleEntry]?
    public var entries: [String: Entry] = [:]
    public init() {}

    private func identity(_ card: OwnedCard) -> String {
        guard let a = card.analysis else { return "" }
        return [a.collectionID, a.player, a.year.map(String.init), a.brand, a.setName,
                a.subset, a.parallel, a.cardNumber, a.serialNumber]
            .map { $0 ?? "" }.joined(separator: "\u{1f}")
    }
    private func matches(_ entry: Entry, _ card: OwnedCard) -> Bool {
        entry.value.isScoutEstimate == true &&
        card.hasCurrentAnalysis && card.analysis?.identityConfirmed == true &&
        card.analysis?.knownIdentityConflict == nil && entry.jobID == card.jobID && entry.identity == identity(card)
    }
    public func binderQuote(for card: OwnedCard, asOf: Date = Date()) -> BinderQuote? {
        card.marketValue(asOf: asOf, cached: cachedMarketValue(for: card, asOf: asOf))?.quote
    }

    public func collectionQuote(for card: OwnedCard, asOf: Date = Date()) -> BinderQuote? {
        card.personalCollectionValue?.quote ?? binderQuote(for: card, asOf: asOf)
    }

    private func cachedSaleValue(for card: OwnedCard, asOf: Date) -> CollectionCardValue? {
        guard card.hasCurrentAnalysis, let analysis = card.analysis, analysis.identityConfirmed == true,
              analysis.knownIdentityConflict == nil, let sale = sales?[card.id], sale.jobID == card.jobID,
              sale.identity == identity(card), sale.expiresAt > asOf.timeIntervalSince1970 else { return nil }
        return sale.quote.collectionValue(for: card, checkedAt: analysis.marketCheckedAt, cached: true)
    }

    private func cachedMarketValue(for card: OwnedCard, asOf: Date) -> CollectionCardValue? {
        value(for: card) ?? cachedSaleValue(for: card, asOf: asOf)
    }

    /// Apply a completed price check only to the physical card that was refreshed.
    public mutating func updatePrices(for card: OwnedCard, refreshAfter: Date, asOf: Date = Date()) {
        let value = card.marketValue(asOf: asOf, cached: nil) ?? card.unpricedBaseValue(asOf: asOf)
        updateSale(for: card, asOf: asOf)
        update(card: card, value: value, refreshAfter: refreshAfter, asOf: asOf,
               portfolioValue: value?.portfolioValue(for: card, asOf: asOf))
    }

    public mutating func updateSale(for card: OwnedCard, asOf: Date = Date()) {
        guard card.hasCurrentAnalysis, let a = card.analysis, a.identityConfirmed == true, a.knownIdentityConflict == nil,
              let summary = a.insights?.marketSummary(asOf: asOf), let quote = BinderQuote(sales: summary),
              let expiry = summary.references.compactMap(\.expiresAt).min() else {
            sales?.removeValue(forKey: card.id)
            return
        }
        if sales == nil { sales = [:] }
        let entry = SaleEntry(jobID: card.jobID, identity: identity(card), quote: quote, expiresAt: expiry)
        sales?[card.id] = entry
    }

    public func values(in library: Library, asOf: Date = Date()) -> [CollectionCardValue] {
        library.collectedCards.compactMap { cachedMarketValue(for: $0, asOf: asOf) }
    }
    public func value(for card: OwnedCard) -> CollectionCardValue? {
        guard let entry = entries[card.id], matches(entry, card) else { return nil }
        var value = entry.value; value.isCached = true
        return value
    }
    public func portfolioValues(in library: Library, asOf: Date = Date()) -> [PortfolioCardValue] {
        library.collectedCards.compactMap { card in
            if let entry = entries[card.id], matches(entry, card) {
                guard isFresh(card, asOf: asOf) else { return nil }
                return entry.portfolioValue.flatMap { $0.isScoutValue ? $0 : nil }
            }
            return cachedSaleValue(for: card, asOf: asOf)?.portfolioValue(for: card, asOf: asOf)
        }
    }
    public func pendingPriceChecks(in library: Library, limit: Int, loading: Set<String>,
                                   checked: Set<String>, retryAfter: [String: Date],
                                   asOf: Date = Date()) -> [OwnedCard] {
        guard limit > 0 else { return [] }
        var missing: [OwnedCard] = [], refresh: [OwnedCard] = []
        for card in library.collectedCards where card.hasCurrentAnalysis && card.canRequestPrices {
            guard !loading.contains(card.jobID),
                  !isFresh(card, asOf: asOf) else { continue }
            if let retry = retryAfter[card.jobID] {
                guard retry <= asOf else { continue }
            } else if checked.contains(card.jobID) {
                continue
            }
            if binderQuote(for: card, asOf: asOf) == nil {
                missing.append(card)
                if missing.count == limit { return missing }
            } else {
                refresh.append(card)
            }
        }
        return Array((missing + refresh).prefix(limit))
    }

    public func freshUntil(_ card: OwnedCard, asOf: Date = Date()) -> Date? {
        isFresh(card, asOf: asOf) ? entries[card.id]?.refreshAfter : nil
    }
    public func isFresh(_ card: OwnedCard, asOf: Date = Date()) -> Bool {
        guard let entry = entries[card.id], matches(entry, card) else { return false }
        return entry.savedAt <= asOf && entry.refreshAfter > asOf
    }
    public mutating func update(card: OwnedCard, value: CollectionCardValue?, refreshAfter: Date, asOf: Date = Date(), portfolioValue: PortfolioCardValue? = nil) {
        guard let value else { entries.removeValue(forKey: card.id); return }
        // The expiring allowance lives on the analysis. Preserve the last researched amount.
        guard !value.isUnpricedBase else { return }
        guard value.isScoutEstimate == true else { entries.removeValue(forKey: card.id); return }
        entries[card.id] = Entry(jobID: card.jobID, identity: identity(card), value: value,
            savedAt: asOf, refreshAfter: min(refreshAfter, asOf.addingTimeInterval(86400)), portfolioValue: portfolioValue)
    }
    public mutating func prune(in library: Library) {
        let recoverable = (library.removedCards ?? []).filter { $0.isScanDraft != true }
        let cards = Dictionary((library.collectedCards + recoverable).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sales = sales?.filter { id, sale in
            guard sale.expiresAt > Date().timeIntervalSince1970, let card = cards[id] else { return false }
            return card.jobID == sale.jobID && identity(card) == sale.identity
        }
        entries = entries.filter { id, entry in cards[id].map { matches(entry, $0) } == true }
    }
}

extension DiskStore {
    public func loadDashboardValues() -> DashboardValueCache {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("dashboard-values.json")),
              let cache = try? JSONDecoder().decode(DashboardValueCache.self, from: data) else { return DashboardValueCache() }
        return cache
    }
    public func saveDashboardValues(_ cache: DashboardValueCache) throws {
        try JSONEncoder().encode(cache).write(to: root.appendingPathComponent("dashboard-values.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A single card value that preserves its source.
public struct BinderQuote: Codable, Equatable, Sendable {
    public let amountCents: Int
    public let currency: String
    public let saleCount: Int?
    public let saleDate: String?
    public let provider: String?
    public let shipping: String?

    private var personal: Bool?
    init(amountCents: Int, currency: String, personal: Bool = false) {
        self.personal = personal ? true : nil
        self.amountCents = amountCents; self.currency = currency
        saleCount = nil; saleDate = nil; provider = nil; shipping = nil
    }
    init?(sales: RawMarketSummary) {
        guard !sales.isComparable, !sales.references.isEmpty, sales.references.allSatisfy({
            $0.kind == "sold" && $0.grade == "raw" && $0.matchQuality == "exact"
        }) else { return nil }
        amountCents = Int(sales.orderingValueCents.rounded())
        currency = sales.primary.currency
        saleCount = sales.references.count
        saleDate = sales.references.count == 1 ? sales.primary.saleDate : nil
        provider = Set(sales.references.map(\.provider)).count == 1 ? sales.primary.provider : nil
        shipping = sales.primary.shipping
    }
    func collectionValue(for card: OwnedCard, checkedAt: String, cached: Bool = false) -> CollectionCardValue {
        CollectionCardValue(cardID: card.id, currency: currency, lowCents: amountCents, highCents: amountCents,
            isEstimate: false, basis: basisLabel, checkedAt: checkedAt, isCached: cached, saleQuote: self)
    }
    public var valueLabel: String { CollectionCardValue.money(amountCents, currency: currency) }
    public var basisLabel: String {
        if personal == true { return "Dein Preis" }
        guard let saleCount else { return "Card Scout Value" }
        return saleCount == 1 ? "Verkauft für" : "Median · \(saleCount) Verkäufe"
    }
}
