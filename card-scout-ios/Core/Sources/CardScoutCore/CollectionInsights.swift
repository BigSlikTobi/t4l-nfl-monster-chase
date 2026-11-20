import Foundation

/// A native-currency view of the same values used by collection statistics.
public struct InsightValuation {
    public let currencies: [String]
    public let currency: String
    public let ranking: [CollectionCardValue]
    public let saved: PortfolioObservation?
    public let lowCents: Int?
    public let highCents: Int?

    public init(statistics: CollectionStatistics, history: [PortfolioObservation], selected: String) {
        let history = statistics.removedCardIDs.isEmpty ? history : history.map { observation in
            PortfolioObservation(id: observation.id, observedAt: observation.observedAt, totalCards: observation.totalCards,
                                 values: observation.values.filter { !statistics.removedCardIDs.contains($0.cardID) })
        }
        let priced = statistics.values.filter { !$0.isUnpricedBase }
        let currentCurrencies = Set(priced.map(\.currency))
        let historicCurrencies = history.reduce(into: Set<String>()) { result, observation in
            result.formUnion(observation.displayedValues.filter { $0.comparisonKey != "unpriced-base" }.map(\.currency))
        }
        let available = currentCurrencies.union(historicCurrencies).sorted()
        currencies = available
        let preferred = currentCurrencies.isEmpty ? historicCurrencies : currentCurrencies
        let code = available.contains(selected) ? selected : preferred.contains("EUR") ? "EUR" : preferred.sorted().first ?? "EUR"
        currency = code
        let rows = statistics.ranked(currency: code)
        ranking = rows
        let last = rows.isEmpty ? history.last { $0.values(currency: code).contains { $0.comparisonKey != "unpriced-base" } } : nil
        saved = last
        let amounts = last?.values(currency: code) ?? []
        lowCents = !rows.isEmpty ? rows.reduce(0) { $0 + $1.lowCents } : last.map { _ in amounts.reduce(0) { $0 + $1.lowCents } }
        highCents = !rows.isEmpty ? rows.reduce(0) { $0 + $1.highCents } : last.map { _ in amounts.reduce(0) { $0 + $1.highCents } }
    }
}

public struct ChecklistMilestone {
    public let checklist: CardCollection
    public let owned: Int
    public let total: Int
    public var remaining: Int { total - owned }
}

extension Library {
    public var closestChecklist: ChecklistMilestone? {
        var numbers: [String: Set<String>] = [:]
        for card in cards {
            if let set = card.ownedChecklistID, let number = card.analysis?.cardNumber {
                numbers[set, default: []].insert(number)
            }
        }
        return collections.compactMap { set -> ChecklistMilestone? in
            guard set.checklistComplete, let collected = numbers[set.id] else { return nil }
            let slots = Set(set.cards.map(\.number))
            guard !slots.isEmpty, set.expectedCount.map({ $0 == slots.count }) ?? true else { return nil }
            let owned = slots.intersection(collected).count
            guard owned > 0, owned < slots.count else { return nil }
            return ChecklistMilestone(checklist: set, owned: owned, total: slots.count)
        }.min {
            if $0.remaining != $1.remaining { return $0.remaining < $1.remaining }
            if $0.owned != $1.owned { return $0.owned > $1.owned }
            return $0.checklist.id < $1.checklist.id
        }
    }
}
