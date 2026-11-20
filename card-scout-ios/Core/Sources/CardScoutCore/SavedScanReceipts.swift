import Foundation

// A paired development install can carry completed worker jobs alongside an existing library.
// Receipts use the same job revisions and merge rules as authenticated live polling.
struct SavedScanReceipt: Codable {
    let cardID: String
    let analysis: CardAnalysis
    let collection: CardCollection?
    let matches: [CardMatch]?
    let matchNotice: String?
}

extension DiskStore {
    func consumeSavedScanReceipts(in stored: Library) -> Library {
        guard let operation = stored.savedPhotoReanalysisOperationID, UUID(uuidString: operation) != nil else { return stored }
        let url = root.appendingPathComponent("recheck-receipts-" + operation + ".json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 8_000_000,
              let data = try? Data(contentsOf: url),
              let receipts = try? JSONDecoder().decode([String: SavedScanReceipt].self, from: data),
              receipts.count <= 200 else { return stored }

        var updated = stored
        var changed = false
        for i in updated.cards.indices {
            let card = updated.cards[i]
            guard card.photoRecheck == true, card.isAwaitingAnalysis, card.uploadedJobID == card.jobID,
                  let receipt = receipts[card.jobID], receipt.cardID == card.id else { continue }
            do {
                guard try updated.applyJobResult(cardID: card.id, jobID: card.jobID, status: "analyzed",
                                                 analysis: receipt.analysis, collection: receipt.collection, error: nil) else { continue }
                updated.cards[i].matchSuggestions = receipt.matches
                updated.cards[i].matchNotice = receipt.matchNotice
                changed = true
            } catch { continue }
        }
        if changed {
            do { try save(updated) } catch { return stored }
        }
        try? FileManager.default.removeItem(at: url)
        return updated
    }
}

private struct ReviewedFinish: Decodable {
    let cardID: String
    let previousJobID: String
    let variantID: String
    let collectionID: String
    let number: String
}

extension DiskStore {
    /// Record a photo review against the exact checklist, using the normal local correction path.
    public func applyReviewedFinishes(operation: UUID, in library: Library) throws -> Library {
        let file = root.appendingPathComponent("reviewed-finishes-" + operation.uuidString.lowercased() + ".json")
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (1...128_000).contains(size) else { throw StoreError.invalidResult }
        let rows = try JSONDecoder().decode([ReviewedFinish].self, from: Data(contentsOf: file))
        guard (1...200).contains(rows.count), Set(rows.map(\.cardID)).count == rows.count else { throw StoreError.invalidResult }
        var updated = library
        updated.restoreVerifiedChecklistRows()
        for row in rows {
            guard let i = updated.cards.firstIndex(where: { $0.id == row.cardID }) else { throw StoreError.missingCard }
            let card = updated.cards[i]
            if card.hasCurrentAnalysis, let exact = card.analysis, exact.identityConfirmed == true,
               exact.collectionID == row.collectionID, exact.cardNumber == row.number,
               let identity = exact.cardSightIdentity, (identity.parallelID ?? "base") == row.variantID { continue }
            guard card.hasCurrentAnalysis, card.jobID == row.previousJobID, let observed = card.openFinishIdentity,
                  observed.cardNumber == row.number, let identity = observed.cardSightIdentity,
                  let variant = observed.cardSightVariants?.first(where: { $0.id == row.variantID }),
                  let player = observed.player, !player.isEmpty, !row.number.isEmpty,
                  let year = observed.year, let name = observed.setName, let brand = observed.brand,
                  let subset = observed.subset, observed.knownIdentityConflict == nil
            else { throw StoreError.invalidResult }
            let parallel = variant.id == "base" ? nil : variant.name
            let providerID = identity.checklistID(variant: variant.id == "base" ? nil : variant.id)
            let index: Int
            if let existing = updated.collections.firstIndex(where: { $0.id == row.collectionID }) {
                index = existing
            } else {
                guard row.collectionID == providerID else { throw StoreError.invalidResult }
                index = updated.collections.count
                updated.collections.append(CardCollection(id: providerID, name: name, year: year, brand: brand,
                                                          subset: subset, parallel: parallel, cards: []))
            }
            let checklist = updated.collections[index]
            guard checklist.matchesEdition(observed, parallel: parallel),
                  !checklist.id.hasPrefix("cardsight-") || checklist.id == providerID else { throw StoreError.invalidResult }
            if let entry = checklist.cards.first(where: { $0.number == row.number }) {
                guard ChecklistCard.samePlayer(entry.player, player) else { throw StoreError.invalidResult }
            } else {
                guard checklist.id == providerID, !checklist.checklistComplete else { throw StoreError.invalidResult }
                updated.collections[index].cards.append(ChecklistCard(number: row.number, player: player,
                    team: observed.team ?? "", rookie: observed.rookie == true))
            }
            try updated.correctAssignment(cardID: card.id, collectionID: checklist.id, number: row.number)
            if updated.cards[i].previousPhotoAssignment == nil { updated.cards[i].previousPhotoAssignment = card.analysis }
            updated.cards[i].uploadedJobID = row.previousJobID
            updated.cards[i].proposedPhotoMatch = nil
            updated.cards[i].analysis?.assessmentSource = "photoReview"
            updated.cards[i].analysis?.finishPolicy = observed.finishPolicy
            updated.cards[i].analysis?.finishState = "verified"
            updated.cards[i].analysis?.licenseScope = observed.licenseScope
            updated.cards[i].analysis?.serialNumber = observed.serialNumber
            updated.cards[i].analysis?.needsReview = observed.licenseScope == nil || observed.licenseScope == "unknown"
            updated.cards[i].analysis?.rationale = ""
            updated.cards[i].analysis?.uncertainties = []
            var selected = identity
            selected.parallelID = variant.id == "base" ? nil : variant.id
            updated.cards[i].analysis?.cardSightIdentity = selected
            updated.cards[i].matchSuggestions = [CardMatch(collectionID: checklist.id, number: row.number)]
            updated.cards[i].matchNotice = nil
        }
        try save(updated)
        return updated
    }


}

extension OwnedCard {
    public var canRequestPrices: Bool {
        if analysis?.assessmentSource == "photoReview" {
            return uploadedJobID != nil && analysis?.cardSightIdentity?.slabbed == false &&
                analysis?.identityConfirmed == true && analysis?.knownIdentityConflict == nil
        }
        // A local checklist correction has no corresponding worker revision.
        return manualAssignment != true || uploadedJobID == jobID
    }

    public func acceptsPrices(from source: String, analysis incoming: CardAnalysis) -> Bool {
        guard let current = analysis, current.year == incoming.year, current.cardNumber == incoming.cardNumber,
              current.serialNumber == incoming.serialNumber else { return false }
        if current.assessmentSource == "photoReview" {
            return source == uploadedJobID && canRequestPrices && incoming.identityConfirmed == true &&
                current.cardSightIdentity == incoming.cardSightIdentity
        }
        return source == jobID && current.player == incoming.player && current.setName == incoming.setName &&
            current.subset == incoming.subset && current.parallel == incoming.parallel &&
            (current.cardSightIdentity == nil || current.cardSightIdentity == incoming.cardSightIdentity)
    }
}
