import SwiftUI
import CardScoutCore

struct BinderOpenFinishShelf: View {
    @Environment(AppStore.self) private var store
    @ScaledMetric(relativeTo: .caption) private var captionHeight = 34.0
    let binder: CollectionBinder

    var body: some View {
        let cards = binder.openFinishCards(in: store.library)
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(tr("Finish open · \(cards.count)"))
                        .font(.subheadline.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    NavigationLink {
                        BinderOpenFinishes(binder: binder)
                    } label: {
                        Label(tr("Alle Karten zeigen"), systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.scoutAccent)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("binder.openFinishes")
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 9) {
                        ForEach(cards) { card in
                            NavigationLink {
                                CardDetailView(cardID: card.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    OwnedPhoto(name: card.frontFile, number: card.openFinishIdentity?.cardNumber ?? "")
                                        .frame(width: 82, height: 114)
                                        .accessibilityHidden(true)
                                    Text(verbatim: card.openFinishIdentity?.player ?? card.title)
                                        .font(.caption.weight(.semibold)).lineLimit(2)
                                }
                                .frame(width: 82, alignment: .leading)
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("binder.openFinishTile." + card.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 118 + captionHeight)
            }
            .foregroundStyle(Color.scoutInk)
            .padding(.horizontal, 10).padding(.bottom, 8)
            .background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct BinderOpenFinishes: View {
    @Environment(AppStore.self) private var store
    let binder: CollectionBinder

    var body: some View {
        let cards = binder.openFinishCards(in: store.library)
        List {
            BinderPriceTag(value: BinderValue(cards: cards, prices: store.dashboardValueCache))
                .frame(maxWidth: .infinity, alignment: .trailing)
            ForEach(cards) { card in
                if let identity = card.openFinishIdentity {
                    NavigationLink {
                        CardDetailView(cardID: card.id)
                    } label: {
                        HStack(spacing: 12) {
                            OwnedPhoto(name: card.frontFile, number: identity.cardNumber ?? "")
                                .frame(width: 48, height: 66)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: identity.player ?? card.title).font(.headline)
                                Text(verbatim: [identity.year.map(String.init), identity.subset, identity.cardNumber.map { "#" + $0 }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Color.scoutMuted)
                            }
                        }
                    }
                    .accessibilityIdentifier("binder.openFinish." + card.id)
                }
            }
        }
        .navigationTitle(tr("Finish open"))
    }
}
