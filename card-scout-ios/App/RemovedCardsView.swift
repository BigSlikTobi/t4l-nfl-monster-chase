import SwiftUI
import CardScoutCore

struct CardRemovalButton: View {
    @Environment(AppStore.self) private var store
    let card: OwnedCard
    var onRemoved: () -> Void = {}
    @State private var confirming = false

    var body: some View {
        Button(role: .destructive) { confirming = true } label: {
            Label(tr("Karte entfernen"), systemImage: "trash")
                .labelStyle(.iconOnly).foregroundStyle(Color.scoutRed)
                .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
        }
        .accessibilityIdentifier("card.remove." + card.id)
        .alert(tr("Karte entfernen?"), isPresented: $confirming) {
            Button(tr("Entfernen"), role: .destructive) {
                if store.removeCard(card.id) { onRemoved() }
            }
            Button(tr("Abbrechen"), role: .cancel) { }
        } message: {
            let details = [cardTitle(card), card.analysis?.cardNumber.map { "#" + $0 }, scanDate(card)]
                .compactMap { $0 }.joined(separator: " · ")
            Text(verbatim: details + "\n\n" + tr("Du kannst dieses Exemplar unter „Entfernte Karten“ wiederherstellen."))
        }
    }
}

struct RemovedCardsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                let removed = store.library.removedCards ?? []
                if removed.isEmpty {
                    ScoutEmptyState(symbol: "trash", title: tr("Keine entfernten Karten"))
                } else {
                    ForEach(removed) { card in
                        let layout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 10))
                        ScoutPanel(padding: 10) {
                            layout {
                                HStack(spacing: 10) {
                                    OwnedPhoto(name: card.frontFile, number: card.analysis?.cardNumber ?? "")
                                        .frame(width: 48, height: 66)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(cardTitle(card)).font(.headline)
                                        let details = [card.analysis?.cardNumber.map { "#" + $0 }, scanDate(card)]
                                            .compactMap { $0 }.joined(separator: " · ")
                                        if !details.isEmpty {
                                            Text(verbatim: details).font(.caption).foregroundStyle(Color.scoutMuted)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button(tr("Wiederherstellen")) { store.restoreCard(card.id) }
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.scoutAccent)
                                    .frame(minHeight: 44).buttonStyle(.plain)
                                    .accessibilityIdentifier("card.restore." + card.id)
                            }
                        }
                    }
                }
            }.frame(maxWidth: 560).padding(16).frame(maxWidth: .infinity)
        }
        .background(Color.scoutCanvas)
        .foregroundStyle(Color.scoutInk)
        .navigationTitle(tr("Entfernte Karten"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func scanDate(_ card: OwnedCard) -> String? {
    ISO8601DateFormatter().date(from: card.createdAt)?.scoutFormatted(date: .abbreviated, time: .shortened)
}
