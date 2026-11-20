import SwiftUI
import CardScoutCore

struct BinderCardSearch: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Bool
    @State private var query = ""
    let binder: CollectionBinder
    let specials: [BinderSpecial]
    let choose: (BinderShelfRoute) -> Void

    var body: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = search.isEmpty ? [] : matches(search)

        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.scoutMuted).accessibilityHidden(true)
                    TextField(tr("Spieler, Team oder Nummer"), text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus)
                        .accessibilityIdentifier("binder.searchField")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.scoutMuted)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Suche löschen"))
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.scoutLine) }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                if !results.isEmpty {
                    List(results) { result in
                        Button { choose(result.route) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: result.title).font(.headline)
                                Text(verbatim: result.subtitle).font(.subheadline)
                                    .foregroundStyle(Color.scoutMuted)
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .foregroundStyle(Color.scoutInk)
                        .accessibilityIdentifier("binder.searchResult." + result.identifier)
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.interactively)
                } else if !search.isEmpty {
                    ScoutEmptyState(symbol: "magnifyingglass", title: tr("Keine Karten gefunden."))
                }
                if results.isEmpty { Spacer(minLength: 0) }
            }
            .background(Color.scoutCanvas)
            .navigationTitle(tr("Karte finden"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Fertig")) { dismiss() }
                }
            }
            .task { focus = true }
        }
    }

    private struct Result: Identifiable {
        let route: BinderShelfRoute
        let identifier: String
        let title: String
        let subtitle: String

        var id: BinderShelfRoute { route }
    }

    private func matches(_ search: String) -> [Result] {
        var numbers: [Result] = []
        var text: [Result] = []
        var open: [Result] = []
        for card in binder.openFinishCards(in: store.library) {
            guard let identity = card.openFinishIdentity else { continue }
            let number = identity.cardNumber ?? ""
            let player = identity.player ?? card.title
            let metadata = [player, identity.team ?? "", number].joined(separator: " ")
            guard ChecklistCard.matchesBinderNumber(search, number: number)
                || metadata.localizedCaseInsensitiveContains(search) else { continue }
            let title = number.isEmpty ? player : "\(player) · #\(number)"
            let subtitle = [identity.subset, tr("Finish open")].compactMap { $0 }.joined(separator: " · ")
            open.append(Result(route: .ownedCard(card.id), identifier: "open." + card.id,
                               title: title, subtitle: subtitle))
        }
        for collection in binder.collections {
            let label = "\(collection.year) · \(binderShelfTitle(collection, in: binder))"
            for entry in collection.cards where entry.matchesBinderSearch(search) {
                let result = Result(route: .checklist(collection.id, pocket: entry.number),
                                    identifier: collection.id + "." + entry.number,
                                    title: "\(entry.player) · #\(entry.number)", subtitle: label)
                if entry.matchesBinderNumber(search) { numbers.append(result) }
                else { text.append(result) }
            }
        }
        for special in specials {
            let card = special.card
            let number = card.analysis?.cardNumber ?? ""
            let exact = ChecklistCard.matchesBinderNumber(search, number: number)
            let player = cardTitle(card)
            let metadata = [player, card.analysis?.team ?? "", number, special.edition].joined(separator: " ")
            guard exact || metadata.localizedCaseInsensitiveContains(search) else { continue }
            let title = number.isEmpty ? player : "\(player) · #\(number)"
            let label = [tr("Besondere Karten"), special.edition].filter { !$0.isEmpty }.joined(separator: " · ")
            let result = Result(route: .ownedCard(special.id), identifier: "special." + special.id,
                                title: title, subtitle: label)
            if exact { numbers.append(result) }
            else { text.append(result) }
        }
        return open + numbers + text
    }
}
