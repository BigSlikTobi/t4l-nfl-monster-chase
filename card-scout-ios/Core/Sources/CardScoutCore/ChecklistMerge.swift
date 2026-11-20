import Foundation

extension CardCollection {
    func matchesEdition(_ analysis: CardAnalysis, parallel selected: String?) -> Bool {
        year == analysis.year && brand == analysis.brand && name == analysis.setName &&
            subset == analysis.subset && parallel == selected
    }

    func merging(_ incoming: CardCollection) throws -> CardCollection {
        guard id == incoming.id, year == incoming.year, name == incoming.name, brand == incoming.brand,
              subset == incoming.subset, parallel == incoming.parallel else { throw StoreError.invalidResult }
        if checklistComplete && !incoming.checklistComplete { return self }

        var merged = incoming
        var indices: [String: Int] = [:]
        for (index, row) in merged.cards.enumerated() {
            guard indices.updateValue(index, forKey: row.number) == nil else { throw StoreError.invalidResult }
        }
        for old in cards {
            if let i = indices[old.number] {
                guard ChecklistCard.samePlayer(merged.cards[i].player, old.player) else { throw StoreError.invalidResult }
                if merged.cards[i].imageURL == nil { merged.cards[i].imageURL = old.imageURL }
                if merged.cards[i].referenceImage == nil, let reference = old.exactReference(in: self),
                   reference.matches(merged, entry: merged.cards[i]) { merged.cards[i].referenceImage = reference }
                if merged.cards[i].team.isEmpty { merged.cards[i].team = old.team }
            } else if !incoming.checklistComplete {
                indices[old.number] = merged.cards.count
                merged.cards.append(old)
            }
        }
        merged.sourceURL = merged.sourceURL ?? sourceURL
        merged.expectedCount = merged.expectedCount ?? expectedCount
        if merged.referenceExample == nil, let reference = validReferenceExample,
           let i = indices[reference.number], reference.matches(merged, entry: merged.cards[i]) {
            merged.referenceExample = reference
        }
        return merged
    }
}

extension ChecklistCard {
    static func samePlayer(_ first: String, _ second: String) -> Bool {
        func key(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        }
        let name = key(first)
        return !name.isEmpty && name == key(second)
    }
}

extension CardSightIdentity {
    func checklistID(variant: String?) -> String {
        "cardsight-" + setID + (variant.map { "-" + $0 } ?? "") +
            (variationOf == nil ? "" : "-variation-" + cardID)
    }
}

extension Library {
    /// A server snapshot can contain just the rows another scan discovered.
    public mutating func mergeChecklists(_ incoming: [CardCollection]) {
        for checklist in incoming {
            if let i = collections.firstIndex(where: { $0.id == checklist.id }) {
                if let merged = try? collections[i].merging(checklist) { collections[i] = merged }
            } else { collections.append(checklist) }
        }
        restoreVerifiedChecklistRows()
    }

    /// Repair rows lost by older syncs using the owned copy's exact final assignment.
    mutating func restoreVerifiedChecklistRows() {
        for card in cards where card.hasCurrentAnalysis && card.isScanDraft != true {
            guard let a = card.analysis, a.identityConfirmed == true, a.finishState == "verified",
                  a.knownIdentityConflict == nil, let id = a.collectionID,
                  let number = a.cardNumber, !number.isEmpty, let player = a.player, !player.isEmpty else { continue }
            let i: Int
            if let index = collections.firstIndex(where: { $0.id == id }) {
                i = index
            } else {
                guard let identity = a.cardSightIdentity, identity.checklistID(variant: identity.parallelID) == id,
                      let name = a.setName, let year = a.year, let brand = a.brand, let subset = a.subset else { continue }
                i = collections.count
                collections.append(CardCollection(id: id, name: name, year: year, brand: brand, subset: subset,
                                                  parallel: a.parallel, cards: []))
            }
            guard collections[i].matchesEdition(a, parallel: a.parallel),
                  !collections[i].cards.contains(where: { $0.number == number }) else { continue }
            collections[i].cards.append(ChecklistCard(number: number, player: player, team: a.team ?? "", rookie: a.rookie == true))
            collections[i].checklistComplete = false
        }
    }
}
