import Foundation

/// A collector's own estimate. Never a market quote or purchase expense.
public struct PersonalCardPrice: Codable, Hashable, Sendable {
    public let amountCents: Int
    public let currency: String
    public let recordedAt: String
    public var isValid: Bool { (0...100_000_000).contains(amountCents) && CardPurchase.currencies.contains(currency) }

    public static func parseAmount(_ text: String) -> Int? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if clean.range(of: "^0{1,7}(\\.0{1,2})?$", options: .regularExpression) != nil { return 0 }
        return CardPurchase.parseAmount(clean)
    }
}

extension Library {
    public mutating func setPersonalPrice(cardID: String, amountCents: Int?, currency: String, asOf: Date = Date()) throws {
        guard let index = cards.firstIndex(where: { $0.id == cardID }),
              CardPurchase.currencies.contains(currency) else { throw StoreError.invalidResult }
        let price = amountCents.map { PersonalCardPrice(amountCents: $0, currency: currency,
            recordedAt: ISO8601DateFormatter().string(from: asOf)) }
        guard price?.isValid != false else { throw StoreError.invalidResult }
        cards[index].personalPrice = price
    }
}
