import Foundation

public struct BinderSpecial: Identifiable, Sendable {
    public enum Kind: Int, Sendable {
        case numbered, autograph, relic, shortPrint, caseHit, variation, parallel, insert
    }

    public let card: OwnedCard
    public let kind: Kind
    public let edition: String
    public let serial: String?
    public var id: String { card.id }

    init?(_ card: OwnedCard, checklist: CardCollection) {
        guard let a = card.analysis, a.identityConfirmed == true, a.knownIdentityConflict == nil,
              card.hasProvisionalAnalysis != true, a.collectionID == checklist.id else { return nil }
        let subset = Self.editionName(a.subset ?? checklist.subset)
        let parallel = Self.editionName(a.parallel ?? checklist.parallel)
        let label = [subset, parallel].joined(separator: " ").lowercased()
        let words = Set(label.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let serial = CollectionStatistics.serialLimit(a.serialNumber) != nil ? a.serialNumber : nil
        let namedParallel = !parallel.isEmpty
        let namedSubset = !subset.isEmpty
        let matchedSubset = namedSubset && subset.caseInsensitiveCompare(checklist.subset) == .orderedSame
        if serial != nil { kind = .numbered }
        else if !words.isDisjoint(with: ["auto", "autos", "autograph", "autographs", "signature", "signatures"]) { kind = .autograph }
        else if !words.isDisjoint(with: ["relic", "relics", "memorabilia", "patch", "patches", "material", "materials"]) { kind = .relic }
        else if !words.isDisjoint(with: ["ssp", "sp"]) || label.contains("short print") { kind = .shortPrint }
        else if label.contains("case hit") { kind = .caseHit }
        else if !words.isDisjoint(with: ["variation", "variations"]) { kind = .variation }
        else if namedParallel { kind = .parallel }
        else if matchedSubset && (a.insights?.rarityTier == "insert" || Self.isChecklistInsert(subset, in: checklist)) { kind = .insert }
        else { return nil }
        self.serial = serial
        self.card = card
        self.edition = [namedSubset ? subset : "", namedParallel && parallel.caseInsensitiveCompare(subset) != .orderedSame ? parallel : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func editionName(_ raw: String?) -> String {
        let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let plain = ["", "base", "base set", "base card", "base cards", "standard", "none", "normal", "regular", "n/a", "keine"]
        let uncertain = ["unknown", "unconfirmed", "uncertain", "unresolved", "possible", "possibly", "unverified", "unbekannt", "unklar", "offen", "nicht bestimmt"]
        guard !plain.contains(name.lowercased()), !name.contains("?"),
              !uncertain.contains(where: { name.localizedCaseInsensitiveContains($0) }) else { return "" }
        return name
    }

    // Older confirmed scans often have no insert tier. These names are specific
    // to the corresponding football release; ordinary rookie/prospect runs stay out.
    private static func isChecklistInsert(_ subset: String, in c: CardCollection) -> Bool {
        let names: Set<String>
        switch (c.year, c.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
        case (2026, "topps flagship"), (2026, "topps flagship football"):
            names = ["1991 topps football", "1991 topps rookies football", "2025 all topps team", "2025 greatest hits", "big ticket players", "greats of the game", "nfl stars", "topps profiles", "pressure cookers", "all kings"]
        case (2025, "topps chrome"), (2025, "topps chrome football"):
            names = ["1975 topps", "all-chrome team", "fanatical", "fortune 15", "future stars", "game genies", "helix", "kaiju", "legends of the gridiron", "let's go", "lightning leaders", "power players", "radiating rookies", "shadow etch", "tecmo", "ultra violet", "urban legends"]
        case (2026, "bowman"), (2026, "bowman football"):
            names = ["bowman verified", "gen next", "roy favorites", "rockstar rookies"]
        case (2025, "donruss optic"), (2025, "donruss optic football"):
            names = ["2015 retro", "best tuddys", "captain in charge", "diamond hands", "downtown", "first year fresh", "hidden potential", "my house!", "play action", "rookie phenoms", "rookie recruits"]
        default: return false
        }
        return names.contains(subset.lowercased())
    }
}

extension CollectionBinder {
    public func specials(in library: Library) -> [BinderSpecial] {
        let checklists = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return library.collectedCards.compactMap { card -> BinderSpecial? in
            guard let id = card.analysis?.collectionID, let collection = checklists[id] else { return nil }
            return BinderSpecial(card, checklist: collection)
        }.sorted { left, right in
            if left.kind != right.kind { return left.kind.rawValue < right.kind.rawValue }
            if left.kind == .numbered {
                let lhs = CollectionStatistics.serialLimit(left.serial) ?? Int.max
                let rhs = CollectionStatistics.serialLimit(right.serial) ?? Int.max
                if lhs != rhs { return lhs < rhs }
            }
            return left.card.createdAt == right.card.createdAt ? left.id < right.id : left.card.createdAt > right.card.createdAt
        }
    }
}
