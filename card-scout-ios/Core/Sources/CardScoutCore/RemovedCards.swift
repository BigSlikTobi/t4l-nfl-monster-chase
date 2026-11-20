import Foundation

extension Library {
    public var removedCardIDs: Set<String> { Set((removedCards ?? []).map(\.id)) }

    public mutating func removeCard(_ id: String) throws {
        guard let index = cards.firstIndex(where: { $0.id == id }), !removedCardIDs.contains(id) else {
            throw StoreError.missingCard
        }
        let card = cards.remove(at: index)
        removedCards = [card] + (removedCards ?? [])
        // Keep folder membership attached to the saved copy. Folders only display active cards.
        unclearCardQueue?.reconcile(cards: cards)
        if card.isAwaitingAnalysis {
            if !(supersededJobIDs ?? []).contains(card.jobID) {
                supersededJobIDs = (supersededJobIDs ?? []) + [card.jobID]
            }
            pendingAcknowledgments?.removeAll { $0 == card.jobID }
        }
    }

    public mutating func restoreCard(_ id: String) throws {
        guard !cards.contains(where: { $0.id == id }),
              let index = removedCards?.firstIndex(where: { $0.id == id }),
              var card = removedCards?[index] else { throw StoreError.missingCard }
        guard card.awaitingBack != true || !cards.contains(where: { $0.awaitingBack == true }) else {
            throw StoreError.invalidResult
        }
        if card.isAwaitingAnalysis {
            // The cancelled revision may still be in flight. Resume with a fresh job ID.
            card.analysisJobID = UUID().uuidString.lowercased()
            card.uploadedJobID = nil
            card.state = "queued"
            card.error = nil
        }
        let destination = cards.firstIndex { ($0.createdAt, $0.id) < (card.createdAt, card.id) } ?? cards.endIndex
        cards.insert(card, at: destination)
        removedCards?.remove(at: index)
        if removedCards?.isEmpty == true { removedCards = nil }
    }
}
