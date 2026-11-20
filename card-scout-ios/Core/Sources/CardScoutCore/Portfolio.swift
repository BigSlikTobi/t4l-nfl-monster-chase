import Foundation

/// User-requested local valuation history. Stores derived owned-card amounts only,
/// never provider responses, comparable listings, source URLs or photos.
public struct PortfolioCardValue: Codable, Equatable, Sendable {
    public let cardID: String
    public let identityKey: String
    public let comparisonKey: String
    public let currency: String
    public let lowCents: Int
    public let highCents: Int
    public var midpointCents: Double { (Double(lowCents) + Double(highCents)) / 2 }
    var isMarketValue: Bool { isScoutValue || comparisonKey.hasPrefix("exact-sale|") }
    var isScoutValue: Bool { comparisonKey.hasPrefix("scout-estimate|") }
}

public struct PortfolioObservation: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let observedAt: Date
    public let totalCards: Int
    public let values: [PortfolioCardValue]
    public var displayedValues: [PortfolioCardValue] {
        values.filter { $0.isMarketValue || ["personal", "unpriced-base"].contains($0.comparisonKey) }
    }
    public func values(currency: String) -> [PortfolioCardValue] { displayedValues.filter { $0.currency == currency } }
    public func midpoint(currency: String) -> Double { values(currency: currency).reduce(0) { $0 + $1.midpointCents } }
}

public struct PortfolioCardMove: Sendable {
    public let cardID: String
    public let deltaCents: Double
}

public struct PortfolioChange: Sendable {
    public let largestMove: PortfolioCardMove?
    public let from: Date
    public let matchedCards: Int
    public let previousCents: Double
    public let currentCents: Double
    public var deltaCents: Double { currentCents - previousCents }
    public var percentage: Double? { previousCents > 0 ? deltaCents / previousCents : nil }
}

extension OwnedCard {
    var portfolioIdentityKey: String? {
        guard let a = analysis else { return nil }
        return [a.collectionID, a.player, a.year.map(String.init), a.brand, a.setName, a.subset, a.parallel, a.cardNumber, a.serialNumber]
            .map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: "\u{1f}")
    }
}

extension CollectionCardValue {
    func portfolioValue(for card: OwnedCard, asOf: Date) -> PortfolioCardValue? {
        let key: String
        if isPersonal { key = "personal" }
        else if isUnpricedBase { key = "unpriced-base" }
        else if let quote = saleQuote { key = "exact-sale|" + (quote.shipping ?? "unknown") }
        else if isScoutEstimate == true, let model = card.analysis?.cardScoutValue(asOf: asOf) { key = "scout-estimate|" + model.shipping }
        else { return nil }
        guard let identity = isPersonal ? card.id : card.portfolioIdentityKey else { return nil }
        return PortfolioCardValue(cardID: card.id, identityKey: identity, comparisonKey: key, currency: currency,
            lowCents: lowCents, highCents: highCents)
    }
}

extension Library {
    public func portfolioValues(asOf: Date = Date(), cachedValues: [PortfolioCardValue] = []) -> [PortfolioCardValue] {
        let cards = Dictionary(collectedCards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cached = Dictionary(cachedValues.filter { value in
            guard let card = cards[value.cardID], card.hasCurrentAnalysis, card.analysis?.identityConfirmed == true,
                  card.analysis?.knownIdentityConflict == nil else { return false }
            return value.isMarketValue && value.identityKey == card.portfolioIdentityKey
        }.map { ($0.cardID, $0) }, uniquingKeysWith: { first, _ in first })
        var result = cached
        for price in CollectionStatistics(library: self, asOf: asOf).values {
            guard let card = cards[price.cardID] else { continue }
            if let stored = cached[card.id], price.isUnpricedBase || (price.saleQuote != nil && stored.isScoutValue) { continue }
            if let current = price.portfolioValue(for: card, asOf: asOf) { result[card.id] = current }
        }
        return result.values.sorted { $0.cardID < $1.cardID }
    }

    /// Keep the initial baseline, then at most two observations per UTC day.
    /// An empty/failed price load is never recorded as a zero-value portfolio.
    @discardableResult public mutating func recordPortfolioObservation(asOf: Date = Date(), cachedValues: [PortfolioCardValue] = []) -> Bool {
        let values = portfolioValues(asOf: asOf, cachedValues: cachedValues)
        guard !values.isEmpty else { return false }
        var history = portfolioHistory ?? []
        guard history.last.map({ $0.observedAt <= asOf }) ?? true else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        if let last = history.last, calendar.isDate(last.observedAt, inSameDayAs: asOf),
           last.values == values, last.totalCards == collectedCards.count { return false }
        let observation = PortfolioObservation(id: UUID().uuidString.lowercased(), observedAt: asOf, totalCards: collectedCards.count, values: values)
        if history.count >= 2, calendar.isDate(history[history.count - 2].observedAt, inSameDayAs: asOf) {
            history[history.count - 1] = observation
        } else { history.append(observation) }
        // Bounded local storage; the chart explicitly names its earliest retained date.
        if history.count > 730 { history.removeFirst(history.count - 730) }
        portfolioHistory = history
        return true
    }

    /// Compare only identical owned cards, currency and valuation/shipping basis.
    /// Additions, removals, corrected identities and missing prices cannot create a gain.
    public func portfolioChange(currency: String, asOf: Date = Date(), cachedValues: [PortfolioCardValue] = []) -> PortfolioChange? {
        let current = portfolioValues(asOf: asOf, cachedValues: cachedValues).filter { $0.currency == currency }
        let comparable = current.filter(\.isMarketValue)
        for observation in portfolioHistory ?? [] where observation.observedAt <= asOf {
            let old = Dictionary(grouping: observation.values(currency: currency), by: \.cardID)
            let pairs = comparable.compactMap { value -> (PortfolioCardValue, PortfolioCardValue)? in
                old[value.cardID]?.first { $0.identityKey == value.identityKey && $0.comparisonKey == value.comparisonKey }
                    .map { ($0, value) }
            }
            if !pairs.isEmpty {
                var mover: PortfolioCardMove?
                for (old, latest) in pairs {
                    let delta = latest.midpointCents - old.midpointCents
                    if abs(delta) > abs(mover?.deltaCents ?? 0) {
                        mover = PortfolioCardMove(cardID: latest.cardID, deltaCents: delta)
                    }
                }
                return PortfolioChange(largestMove: mover, from: observation.observedAt, matchedCards: pairs.count,
                    previousCents: pairs.reduce(0) { $0 + $1.0.midpointCents }, currentCents: pairs.reduce(0) { $0 + $1.1.midpointCents })
            }
        }
        return nil
    }

    public func recommendedCards(_ action: String) -> [OwnedCard] {
        collectedCards.filter { card in
            guard card.hasCurrentAnalysis, let a = card.analysis, a.identityConfirmed == true,
                  a.confidence == "high", !a.needsReview, a.knownIdentityConflict == nil,
                  let insights = a.insights, !insights.actionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  a.recommendation == action else { return false }
            return action != "Grade" || insights.conditionStatus == "no_obvious_damage"
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
    }
}

extension CollectionStatistics {
    public func portfolioValue(currency: String) -> (low: Int, high: Int)? {
        let matching = values.filter { $0.isPortfolioEligible && $0.currency == currency }
        guard !matching.isEmpty else { return nil }
        return (matching.reduce(0) { $0 + $1.lowCents }, matching.reduce(0) { $0 + $1.highCents })
    }
}
