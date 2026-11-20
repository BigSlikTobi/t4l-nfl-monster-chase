import SwiftUI
import CardScoutCore

struct BinderSpecialsGallery: View {
    let entries: [BinderSpecial]
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                BinderPriceTag(value: BinderValue(cards: entries.map(\.card), prices: store.dashboardValueCache))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if let first = entries.first {
                    sleeve(first, featured: true)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(entries.dropFirst()) { entry in sleeve(entry, featured: false) }
                    }
                } else {
                    ScoutEmptyState(symbol: "sparkles", title: tr("Noch keine besonderen Karten."))
                        .padding(.horizontal, 16).padding(.top, 60)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: 540)
        }.frame(maxWidth: .infinity)
    }

    private func sleeve(_ entry: BinderSpecial, featured: Bool) -> some View {
        let style = finish(entry.kind)
        let landscape = featured && !typeSize.isAccessibilitySize
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        return NavigationLink { CardDetailView(cardID: entry.id) } label: {
            layout {
                OwnedPhoto(name: entry.card.frontFile, maxPixel: featured ? 950 : 550, number: entry.card.analysis?.cardNumber ?? "")
                    .aspectRatio(5.0 / 7.0, contentMode: .fit)
                    .padding(4)
                    .background(LinearGradient(colors: [.white.opacity(0.29), .white.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.25)) }
                    .frame(maxWidth: landscape ? 160 : .infinity)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Label(style.label, systemImage: style.symbol).font(.caption.weight(.bold)).foregroundStyle(style.color)
                    Text(cardTitle(entry.card))
                        .font(featured ? .system(.title2, design: .default, weight: .black).width(.condensed) : .headline)
                        .foregroundStyle(.white)
                    if !entry.edition.isEmpty {
                        Text(verbatim: entry.edition).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                    }
                    let identity = [entry.card.analysis?.year.map(String.init), entry.card.analysis?.setName, entry.card.analysis?.cardNumber.map { "#" + $0 }]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !identity.isEmpty { Text(verbatim: identity).font(.caption).foregroundStyle(.white.opacity(0.74)) }
                    if let serial = entry.serial {
                        Text(verbatim: serial).font(.headline.monospaced().bold()).foregroundStyle(style.color)
                    }
                    if let value = store.dashboardValueCache.collectionQuote(for: entry.card) {
                        Text(value.valueLabel).font(.subheadline.weight(.bold)).foregroundStyle(Color.scoutAccent)
                        Text(trDisplay(value.basisLabel)).font(.caption2).foregroundStyle(Color.scoutMuted).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(featured ? 14 : 10).frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [style.color.opacity(0.17), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 12))
                }
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(LinearGradient(colors: [style.color.opacity(0.65), .white.opacity(0.10), style.color.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)) }
                .contentShape(Rectangle())
                .environment(\.colorScheme, .dark)
        }.buttonStyle(.plain).accessibilityIdentifier("binder.special.card." + entry.id)
    }

    private func finish(_ kind: BinderSpecial.Kind) -> (label: String, symbol: String, color: Color) {
        let gold = Color(red: 0.98, green: 0.81, blue: 0.50)
        switch kind {
        case .numbered: return (tr("Nummeriert"), "number", gold)
        case .autograph: return (tr("Autogramm"), "signature", gold)
        case .relic: return (tr("Relic"), "square.grid.3x3.fill", gold)
        case .shortPrint: return (tr("Short Print"), "rectangle.portrait.on.rectangle.portrait", gold)
        case .caseHit: return (tr("Case Hit"), "star.circle", gold)
        case .variation: return (tr("Variation"), "rectangle.on.rectangle.angled", .cyan)
        case .parallel: return (tr("Parallel"), "square.2.layers.3d", .mint)
        case .insert: return (tr("Insert"), "sparkles", Color(red: 0.78, green: 0.75, blue: 1))
        }
    }
}
