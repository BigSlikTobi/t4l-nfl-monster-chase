import Foundation

/// Product names on the shelf are presentation aliases. Checklists keep their exact IDs.
public enum BinderProduct: String, Sendable {
    case absolute = "Panini Absolute Football"
    case bowman = "Bowman Football"
    case chrome = "Topps Chrome"
    case donruss = "Donruss"
    case flagship = "Topps Flagship Football"
    case heritage = "Topps Heritage Football"
    case phoenix = "Panini Phoenix Football"
    case resurgence = "Topps Resurgence"
    case select = "Panini Select"
    case stadiumClub = "Topps Stadium Club"

    fileprivate static func resolve(name: String, manufacturer: String, year: Int) -> Self? {
        var words = name.lowercased().split { !$0.isLetter && !$0.isNumber }[...]
        let season = Substring(String(year))
        if words.first == season { words = words.dropFirst() }
        if words.last == season { words = words.dropLast() }
        var brand = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let prefix = words.first, prefix == "topps" || prefix == "panini" {
            brand = String(prefix)
            words = words.dropFirst()
        }
        // The existing Bowman and Donruss binders span their paper and coated editions.
        if words.first == "bowman" { return .bowman }
        if words.first == "donruss" { return .donruss }

        if words.last == "football" { words = words.dropLast() }
        switch (brand, words.joined(separator: " ")) {
        case ("topps", "flagship"): return .flagship
        case ("topps", "chrome"): return .chrome
        case ("topps", "stadium club"): return .stadiumClub
        case ("topps", "heritage"): return .heritage
        case ("topps", "resurgence"): return .resurgence
        case ("panini", "select"): return .select
        case ("panini", "phoenix"): return .phoenix
        case ("panini", "absolute"): return .absolute
        default: return nil
        }
    }
}

public struct CollectionBinder: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let product: BinderProduct?
    public let collections: [CardCollection]

    public func cards(in library: Library) -> [OwnedCard] {
        let ids = Set(collections.map(\.id))
        return library.cards.filter { $0.ownedChecklistID.map(ids.contains) == true || $0.openFinishBinder?.id == id }
    }

    public static func group(_ collections: [CardCollection], containing ownedIDs: Set<String>? = nil) -> [CollectionBinder] {
        let groups = Dictionary(grouping: collections) { item in
            forRelease(name: item.name, brand: item.brand, year: item.year).id
        }
        return groups.compactMap { key, values -> CollectionBinder? in
            if let ownedIDs, !values.contains(where: { ownedIDs.contains($0.id) }) { return nil }
            let sorted = values.sorted {
                if $0.year != $1.year { return $0.year > $1.year }
                if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                let lhs = $0.parallel ?? $0.subset, rhs = $1.parallel ?? $1.subset
                if lhs != rhs { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
                return $0.id < $1.id
            }
            let first = sorted[0]
            let binder = forRelease(name: first.name, brand: first.brand, year: first.year)
            return CollectionBinder(id: key, name: binder.name, product: binder.product, collections: sorted)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    fileprivate static func forRelease(name: String, brand: String, year: Int) -> CollectionBinder {
        let product = BinderProduct.resolve(name: name, manufacturer: brand, year: year)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = product?.rawValue ?? (cleanName.isEmpty ? brand : cleanName)
        let manufacturer = brand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = product?.rawValue.lowercased() ?? "set.\(manufacturer.utf8.count).\(manufacturer).\(display.lowercased())"
        return CollectionBinder(id: key, name: display, product: product, collections: [])
    }
}

/// Sum the values shown on owned cards, keeping each currency separate.
public struct BinderValue: Sendable {
    public let centsByCurrency: [String: Int]
    public let pricedCards: Int
    public let ownedCards: Int

    public init(cards: [OwnedCard], prices: DashboardValueCache, asOf: Date = Date()) {
        let quotes = cards.compactMap { prices.collectionQuote(for: $0, asOf: asOf) }
        centsByCurrency = quotes.reduce(into: [:]) { totals, quote in
            totals[quote.currency, default: 0] += quote.amountCents
        }
        pricedCards = quotes.count
        ownedCards = cards.count
    }
}

extension CardCollection {
    public func ownedCards(in inventory: [OwnedCard]) -> [OwnedCard] {
        inventory.filter { $0.ownedChecklistID == id }
    }
}

extension ChecklistCard {
    public func matchesBinderSearch(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "\(number) \(player) \(team)".localizedCaseInsensitiveContains(query) || matchesBinderNumber(query)
    }

    public func matchesBinderNumber(_ search: String) -> Bool {
        Self.matchesBinderNumber(search, number: number)
    }

    public static func matchesBinderNumber(_ search: String, number: String) -> Bool {
        // Search accepts common ways of typing a card number. Ownership still uses the exact checklist number.
        func compactNumber(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let unprefixed = trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...]
            return String(unprefixed.filter { !$0.isWhitespace && !"-‐‑‒–—−".contains($0) })
        }
        let compactQuery = compactNumber(search)
        return !compactQuery.isEmpty && compactQuery.caseInsensitiveCompare(compactNumber(number)) == .orderedSame
    }
}

extension OwnedCard {
    var ownedChecklistID: String? {
        guard isScanDraft != true, analysis?.identityConfirmed == true else { return nil }
        return analysis?.collectionID
    }
}

extension OwnedCard {
    public var canCaptureFinishAngle: Bool {
        if canAddTilt { return true }
        guard hasCurrentAnalysis, tiltFile == nil, backFile != nil, !frontFile.isEmpty,
              let identity = openFinishIdentity, identity.finishState == "pending" else { return false }
        return Set((identity.cardSightVariants ?? []).map(\.id)).count > 1
    }

    public var openFinishIdentity: CardAnalysis? {
        guard isScanDraft != true, hasDisplayableAnalysis, analysis?.identityConfirmed != true else { return nil }
        let result = analysis?.finishState == "savedChoice" ? proposedPhotoMatch : analysis
        guard let result, result.identityConfirmed == false, result.finishPolicy != nil,
              result.finishState == "pending" || result.finishState == "tilt",
              result.cardSightIdentity != nil, result.year != nil,
              let brand = result.brand, !brand.isEmpty, let name = result.setName, !name.isEmpty else { return nil }
        return result
    }

    fileprivate var openFinishBinder: CollectionBinder? {
        guard let identity = openFinishIdentity, let year = identity.year,
              let name = identity.setName, let brand = identity.brand else { return nil }
        return CollectionBinder.forRelease(name: name, brand: brand, year: year)
    }
}

extension CollectionBinder {
    public func openFinishCards(in library: Library) -> [OwnedCard] {
        library.cards.filter { $0.openFinishBinder?.id == id }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }
}

extension Library {
    public var ownedChecklistIDs: Set<String> { Set(cards.compactMap(\.ownedChecklistID)) }

    public var binders: [CollectionBinder] {
        let open = Dictionary(cards.compactMap(\.openFinishBinder).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let owned = ownedChecklistIDs
        let visible = CollectionBinder.group(collections).filter { binder in
            open[binder.id] != nil || binder.collections.contains { owned.contains($0.id) }
        }
        let visibleIDs = Set(visible.map(\.id))
        let extra = open.values.filter { !visibleIDs.contains($0.id) }
        guard !extra.isEmpty else { return visible }
        return (visible + extra).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public var collectibles: [OwnedCard] {
        collectedCards.filter { $0.isCollectible == true }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }
}
