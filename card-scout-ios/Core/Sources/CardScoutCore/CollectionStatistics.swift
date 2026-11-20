import Foundation

public enum PurchaseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case card, pack, box, supplies, other
    public var id: String { rawValue }
    public var label: String {
        switch self { case .card: "Einzelkarten"; case .pack: "Packs"; case .box: "Boxen"; case .supplies: "Zubehör"; case .other: "Sonstiges" }
    }
    public var symbol: String {
        switch self { case .card: "rectangle.portrait"; case .pack: "gift"; case .box: "shippingbox"; case .supplies: "archivebox"; case .other: "bag" }
    }
}

public struct CardPurchase: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var category: PurchaseCategory
    /// Total paid for the whole purchase, including shipping/fees. Never multiply by quantity.
    public var amountCents: Int
    public var currency: String
    public var quantity: Int
    public var purchasedOn: String
    public var cardID: String?
    public init(id: String = UUID().uuidString.lowercased(), title: String, category: PurchaseCategory = .pack,
                amountCents: Int = 0, currency: String = "EUR", quantity: Int = 1, purchasedOn: String, cardID: String? = nil) {
        self.id = id; self.title = title; self.category = category; self.amountCents = amountCents
        self.currency = currency; self.quantity = quantity; self.purchasedOn = purchasedOn; self.cardID = cardID
    }
    public static let currencies = ["EUR", "USD", "GBP"]
    public var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              (1...100_000_000).contains(amountCents), (1...999).contains(quantity), Self.currencies.contains(currency) else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: purchasedOn) else { return false }
        return formatter.string(from: date) == purchasedOn
    }
    public static func parseAmount(_ text: String) -> Int? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard clean.range(of: "^[0-9]{1,7}(\\.[0-9]{1,2})?$", options: .regularExpression) != nil else { return nil }
        let parts = clean.split(separator: ".")
        guard let whole = Int(parts[0]) else { return nil }
        let fraction = parts.count == 2 ? Int(parts[1])! * (parts[1].count == 1 ? 10 : 1) : 0
        let cents = whole * 100 + fraction
        return (1...100_000_000).contains(cents) ? cents : nil
    }
}

public struct CollectionCardValue: Codable, Identifiable, Equatable, Sendable {
    public var id: String { cardID }
    public let cardID: String
    public let currency: String
    public let lowCents: Int
    public let highCents: Int
    public let isEstimate: Bool
    public let basis: String
    public let checkedAt: String
    public var isScoutEstimate: Bool? = nil
    public var isCached: Bool = false
    public var isPersonal: Bool = false
    var unpricedBaseExpiresAt: Double? = nil
    public var isUnpricedBase: Bool { unpricedBaseExpiresAt != nil }
    var saleQuote: BinderQuote? = nil
    public var isPortfolioEligible: Bool { isScoutEstimate == true || saleQuote != nil || isPersonal || isUnpricedBase }
    var quote: BinderQuote {
        saleQuote ?? BinderQuote(amountCents: lowCents, currency: currency, personal: isPersonal)
    }
    public var label: String {
        let low = Self.money(lowCents, currency: currency)
        let price = lowCents == highCents ? low : "\(low) – \(Self.money(highCents, currency: currency))"
        return isEstimate && !isUnpricedBase && isScoutEstimate != true ? "ca. \(price)" : price
    }
    public static func money(_ cents: Int, currency: String) -> String {
        (Double(cents) / 100).formatted(.currency(code: currency).locale(ScoutLocalization.locale).precision(.fractionLength(0...2)))
    }
}

extension OwnedCard {
    var personalCollectionValue: CollectionCardValue? {
        guard let price = personalPrice, price.isValid else { return nil }
        return CollectionCardValue(cardID: id, currency: price.currency, lowCents: price.amountCents,
            highCents: price.amountCents, isEstimate: true, basis: "Dein Preis", checkedAt: price.recordedAt, isPersonal: true)
    }

    func marketValue(asOf: Date, cached: CollectionCardValue?) -> CollectionCardValue? {
        guard hasCurrentAnalysis, let analysis, analysis.identityConfirmed == true,
              analysis.knownIdentityConflict == nil else { return nil }
        if let model = analysis.cardScoutValue(asOf: asOf) {
            return CollectionCardValue(cardID: id, currency: model.currency, lowCents: model.amountCents,
                highCents: model.amountCents, isEstimate: true, basis: "Card Scout Value",
                checkedAt: model.checkedAt, isScoutEstimate: true)
        }
        if cached?.isScoutEstimate == true { return cached }
        if let summary = analysis.insights?.marketSummary(asOf: asOf), let quote = BinderQuote(sales: summary) {
            return quote.collectionValue(for: self, checkedAt: summary.primary.checkedAt)
        }
        return cached?.saleQuote == nil ? nil : cached
    }

    public func unpricedBaseValue(asOf: Date = Date()) -> CollectionCardValue? {
        guard hasCurrentAnalysis, let analysis, analysis.hasUnpricedBaseAllowance(asOf: asOf) else { return nil }
        return CollectionCardValue(cardID: id, currency: "EUR", lowCents: 0, highCents: 0,
            isEstimate: true, basis: "Sammlungswert · Basiskarte", checkedAt: analysis.marketCheckedAt,
            unpricedBaseExpiresAt: analysis.unpricedBaseExpiresAt)
    }
}

public struct CollectionGrowthPoint: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let count: Int
}

public struct CollectionStatistics: Sendable {
    let removedCardIDs: Set<String>
    public let totalCards: Int
    public let analyzedCards: Int
    public let rookieCards: Int
    public let numberedCards: Int
    public let favorites: Int
    public let duplicateExtras: Int
    public let distinctPlayers: Int
    public let purchases: [CardPurchase]
    public let values: [CollectionCardValue]
    public let personalValues: [CollectionCardValue]
    public let specialCardID: String?
    public let specialReason: String?
    public let growth: [CollectionGrowthPoint]
    public var pricedCards: Int { values.filter { !$0.isUnpricedBase }.count }
    public var indicativeCards: Int { values.filter { $0.isEstimate && !$0.isUnpricedBase }.count }
    public var nextMilestone: Int { [10, 25, 50, 100, 250, 500, 1000].first { $0 > totalCards } ?? ((totalCards / 1000) + 1) * 1000 }
    public var spendingCurrencies: [String] { Array(Set(purchases.map(\.currency))).sorted() }
    public var valueCurrencies: [String] { Array(Set(values.map(\.currency))).sorted() }
    public func spending(currency: String, category: PurchaseCategory? = nil) -> Int {
        purchases.filter { $0.currency == currency && (category == nil || $0.category == category) }.reduce(0) { $0 + $1.amountCents }
    }
    public func confirmedValue(currency: String) -> (low: Int, high: Int)? {
        let matching = values.filter { !$0.isEstimate && $0.currency == currency }
        guard !matching.isEmpty else { return nil }
        return (matching.reduce(0) { $0 + $1.lowCents }, matching.reduce(0) { $0 + $1.highCents })
    }
    /// Sum the effective values and explicit collection allowances.
    public func estimatedCollectionValue(currency: String) -> (low: Int, high: Int)? {
        let matching = values.filter { $0.currency == currency }
        guard !matching.isEmpty else { return nil }
        return (matching.reduce(0) { $0 + $1.lowCents }, matching.reduce(0) { $0 + $1.highCents })
    }
    public func ranked(currency: String) -> [CollectionCardValue] {
        values.filter { $0.currency == currency && !$0.isUnpricedBase }.sorted {
            if $0.lowCents != $1.lowCents { return $0.lowCents > $1.lowCents }
            return $0.cardID < $1.cardID
        }
    }
    public init(library: Library, asOf: Date = Date(), calendar: Calendar = .current, cachedValues: [CollectionCardValue] = [], includePersonal: Bool = true) {
        let cards = library.collectedCards
        removedCardIDs = library.removedCardIDs
        let analyzed = cards.filter(\.hasCurrentAnalysis)
        let readable = analyzed.filter { $0.analysis?.player != nil && $0.analysis?.confidence != "low" }
        totalCards = cards.count; analyzedCards = analyzed.count
        rookieCards = readable.filter { $0.analysis?.rookie == true }.count
        numberedCards = readable.filter { Self.serialLimit($0.analysis?.serialNumber) != nil }.count
        favorites = cards.filter { $0.isFavorite == true }.count
        distinctPlayers = Set(readable.compactMap { $0.analysis?.player?.lowercased() }).count
        let duplicates = Dictionary(grouping: analyzed.filter { $0.analysis?.identityConfirmed == true && $0.analysis?.collectionID != nil && $0.analysis?.cardNumber != nil }) {
            [$0.analysis!.collectionID!, $0.analysis!.cardNumber!, $0.analysis!.parallel ?? ""].joined(separator: "|")
        }
        duplicateExtras = duplicates.values.reduce(0) { $0 + max(0, $1.count - 1) }
        let purchaseDate = DateFormatter(); purchaseDate.locale = Locale(identifier: "en_US_POSIX")
        purchaseDate.timeZone = calendar.timeZone; purchaseDate.dateFormat = "yyyy-MM-dd"
        purchases = (library.purchases ?? []).filter { $0.isValid && $0.purchasedOn <= purchaseDate.string(from: asOf) }.sorted {
            $0.purchasedOn == $1.purchasedOn ? $0.id > $1.id : $0.purchasedOn > $1.purchasedOn
        }
        personalValues = cards.compactMap(\.personalCollectionValue)
        let cached = Dictionary(cachedValues.map { ($0.cardID, $0) }, uniquingKeysWith: { first, _ in first })
        let accounted = analyzed.compactMap { card in
            card.marketValue(asOf: asOf, cached: cached[card.id]) ?? card.unpricedBaseValue(asOf: asOf)
        }
        let personalIDs = Set(personalValues.map(\.cardID))
        values = includePersonal ? personalValues + accounted.filter { !personalIDs.contains($0.cardID) } : accounted
        let special = readable.compactMap { card -> (OwnedCard, Int, String)? in
            if let limit = Self.serialLimit(card.analysis?.serialNumber) {
                return (card, limit, limit == 1 ? "Sichtbar nummeriert: 1/1" : "Sichtbar nummeriert: \(card.analysis!.serialNumber!)")
            }
            guard card.analysis?.identityConfirmed == true else { return nil }
            if let parallel = card.analysis?.parallel, !parallel.isEmpty { return (card, 2_000_000, "Bestätigte Variante: \(parallel)") }
            if card.analysis?.insights?.rarityTier == "insert" { return (card, 3_000_000, "Bestätigtes Insert") }
            if card.analysis?.rookie == true { return (card, 4_000_000, "Rookie-Karte") }
            return nil
        }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }.first
        specialCardID = special?.0.id; specialReason = special?.2
        let dateReader = ISO8601DateFormatter()
        let preciseReader = ISO8601DateFormatter(); preciseReader.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let captureDates = cards.compactMap { dateReader.date(from: $0.createdAt) ?? preciseReader.date(from: $0.createdAt) }
        let today = calendar.startOfDay(for: asOf)
        growth = (-13...0).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return CollectionGrowthPoint(date: day, count: captureDates.filter { $0 < end && $0 <= asOf }.count)
        }
    }
    public static func serialLimit(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.replacingOccurrences(of: " ", with: "").split(separator: "/")
        guard parts.count == 2, let number = Int(parts[0]), let limit = Int(parts[1]),
              number >= 1, number <= limit, limit <= 1_000_000 else { return nil }
        return limit
    }
}
