import Foundation

public enum BurnPerformance: Sendable { case unknown, uncertain, breakEven, ahead, excellent, behind, heavyBurn }

public enum BurnMood: String, Sendable { case curious, proud, roasted }

/// A playful hobby comparison, not a realized loss or investment return.
public struct BurnCount: Sendable {
    public let isManualValue: Bool
    public let currency: String
    public let spentCents: Int?
    public let valueLowCents: Int?
    public let valueHighCents: Int?
    public let pricedCards: Int
    public let totalCards: Int
    public let purchaseCount: Int
    public let includesModeledValues: Bool
    public var isIndicative: Bool { !isManualValue && (!hasCompleteCoverage || includesModeledValues) }
    public var hasCompleteCoverage: Bool { totalCards > 0 && (isManualValue || pricedCards == totalCards) }
    public var canCompare: Bool { spentCents != nil && valueLowCents != nil }
    public var burnLowCents: Int? {
        guard canCompare, let spentCents, let valueHighCents else { return nil }
        return spentCents - valueHighCents
    }
    public var burnHighCents: Int? {
        guard canCompare, let spentCents, let valueLowCents else { return nil }
        return spentCents - valueLowCents
    }
    /// Classify the displayed estimate. Ranges must clear a threshold in full.
    public var performance: BurnPerformance {
        guard let low = burnLowCents, let high = burnHighCents, let spentCents else { return .unknown }
        if low == 0 && high == 0 { return .breakEven }
        if low <= 0 && high >= 0 { return .uncertain }
        if high < 0 {
            return spentCents > 0 && Double(-high) / Double(spentCents) >= 0.25 ? .excellent : .ahead
        }
        return spentCents > 0 && Double(low) / Double(spentCents) >= 0.25 ? .heavyBurn : .behind
    }
    public var mood: BurnMood {
        guard canCompare, let spentCents, let valueLowCents, let valueHighCents else { return .curious }
        if valueLowCents >= spentCents { return .proud }
        if valueHighCents < spentCents { return .roasted }
        return .curious
    }
    public init(statistics: CollectionStatistics, currency: String, manualValueCents: Int? = nil,
                manualValueCurrency: String? = nil, exchangeRates: [String: Decimal]? = nil) {
        let manual = manualValueCents.flatMap { (0...100_000_000).contains($0) ? $0 : nil }
        isManualValue = manual != nil
        self.currency = currency
        // Card/pack/box totals include fees once; supplies and other costs stay in the ledger.
        let purchases = statistics.purchases.filter {
            [.card, .pack, .box].contains($0.category) && (exchangeRates != nil || $0.currency == currency)
        }
        purchaseCount = purchases.count
        let personalIDs = Set(statistics.personalValues.map(\.cardID))
        let effectiveValues = statistics.values.filter { !personalIDs.contains($0.cardID) } + statistics.personalValues
        let values = effectiveValues.filter { exchangeRates != nil || $0.currency == currency }

        if let exchangeRates {
            spentCents = Self.total(purchases.map { ($0.amountCents, $0.currency) }, in: currency, rates: exchangeRates)
            let manualAmounts = manual.map { [($0, manualValueCurrency ?? currency)] }
            let high = Self.total(manualAmounts ?? values.map { ($0.highCents, $0.currency) }, in: currency, rates: exchangeRates)
            valueHighCents = high
            valueLowCents = high.flatMap { _ in
                Self.total(manualAmounts ?? values.map { ($0.lowCents, $0.currency) }, in: currency, rates: exchangeRates)
            }
            pricedCards = values.count
        } else {
            spentCents = purchases.isEmpty ? nil : purchases.reduce(0) { $0 + $1.amountCents }
            let hasOnlyBaseZeros = values.allSatisfy(\.isUnpricedBase)
            let pricedElsewhere = effectiveValues.contains { $0.currency != currency && $0.highCents > 0 }
            let showValue = !values.isEmpty && !(hasOnlyBaseZeros && pricedElsewhere)
            valueLowCents = manual ?? (showValue ? values.reduce(0) { $0 + $1.lowCents } : nil)
            valueHighCents = manual ?? (showValue ? values.reduce(0) { $0 + $1.highCents } : nil)
            let otherBaseZeros = effectiveValues.filter { $0.isUnpricedBase && $0.currency != currency }
            pricedCards = values.count + (values.isEmpty ? 0 : otherBaseZeros.count)
        }
        includesModeledValues = values.contains { $0.isScoutEstimate == true }
        totalCards = statistics.totalCards
    }

    /// Rates are units of each currency per EUR. Sum first and round only the displayed total.
    private static func total(_ amounts: [(cents: Int, currency: String)], in target: String,
                              rates: [String: Decimal]) -> Int? {
        guard !amounts.isEmpty else { return nil }
        var subtotals: [String: Decimal] = [:]
        for amount in amounts {
            subtotals[amount.currency, default: 0] += Decimal(amount.cents)
        }
        var total: Decimal = 0
        for (source, cents) in subtotals.sorted(by: { $0.key < $1.key }) {
            if source == target || cents == 0 {
                total += cents
            } else {
                guard let from = source == "EUR" ? 1 : rates[source], from > 0,
                      let to = target == "EUR" ? 1 : rates[target], to > 0 else { return nil }
                total += cents * to / from
            }
        }
        var rounded: Decimal = 0
        NSDecimalRound(&rounded, &total, 0, .plain)
        return Int(NSDecimalNumber(decimal: rounded).stringValue)
    }

}


public struct ManualBurnValue: Codable, Equatable, Sendable {
    public let amountCents: Int
    public let currency: String
    public let recordedAt: Date
    public let cardIDs: [String]
    public var personalPrices: [String: PersonalCardPrice]? = nil
}

extension Library {
    public func currentManualBurnValue(currency: String) -> ManualBurnValue? {
        guard let value = burnManualValues?[currency], value.currency == currency,
              (0...100_000_000).contains(value.amountCents),
              value.cardIDs == collectedCards.map(\.id).sorted(),
              (value.personalPrices ?? [:]) == personalPriceSnapshot else { return nil }
        return value
    }
    private var personalPriceSnapshot: [String: PersonalCardPrice] {
        Dictionary(uniqueKeysWithValues: collectedCards.compactMap { card in
            card.personalPrice.map { (card.id, $0) }
        })
    }
    public mutating func setManualBurnValue(amountCents: Int?, currency: String, asOf: Date = Date()) throws {
        guard CardPurchase.currencies.contains(currency) else { throw StoreError.invalidResult }
        if let amountCents {
            guard (0...100_000_000).contains(amountCents), !collectedCards.isEmpty else { throw StoreError.invalidResult }
            var values = burnManualValues ?? [:]
            var value = ManualBurnValue(amountCents: amountCents, currency: currency, recordedAt: asOf, cardIDs: collectedCards.map(\.id).sorted())
            value.personalPrices = personalPriceSnapshot
            values[currency] = value
            burnManualValues = values
        } else { burnManualValues?.removeValue(forKey: currency) }
    }
}
