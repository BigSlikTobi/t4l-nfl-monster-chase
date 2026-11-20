import SwiftUI
import CardScoutCore

enum BinderShelfRoute: Hashable {
    case checklist(String, pocket: String? = nil)
    case specials
    case ownedCard(String)

    var coverID: String {
        switch self {
        case let .checklist(id, _): "checklist." + id
        case .specials: "specials"
        case let .ownedCard(id): "card." + id
        }
    }
}

func binderShelfTitle(_ collection: CardCollection, in binder: CollectionBinder) -> String {
    let variant = binderVariant(collection)
    guard !variant.isEmpty else { return collection.name }
    let sharedName = binder.collections.contains {
        $0.year == collection.year && $0.name != collection.name && binderVariant($0) == variant
    }
    return sharedName ? [collection.name, variant].joined(separator: " · ") : variant
}

struct BinderShelf: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let binder: CollectionBinder
    let specials: [BinderSpecial]
    let transition: Namespace.ID
    let open: (BinderShelfRoute) -> Void
    let find: () -> Void

    var body: some View {
        GeometryReader { frame in
            shelf(compact: frame.size.height < 500 && !typeSize.isAccessibilitySize)
        }
    }

    private func shelf(compact: Bool) -> some View {
        let years = Set(binder.collections.map(\.year)).sorted(by: >)
        let art = binder.product == .bowman ? "BinderBowmanHelmet" : BinderFinish(binder).material
        let cards = binder.cards(in: store.library)
        let tag = priceTag(for: cards)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let first = binder.collections.first, years.count == 1 {
                    ViewThatFits(in: .horizontal) {
                        HStack { season(first.year, brand: first.brand); tag; Spacer(minLength: 8); findButton }
                        VStack(alignment: .leading, spacing: 4) {
                            season(first.year, brand: first.brand)
                            valueAndSearch(tag)
                        }
                    }
                } else {
                    valueAndSearch(tag)
                }
                BinderOpenFinishShelf(binder: binder)
                VStack(alignment: .leading, spacing: 16) {
                    if years.count > 1 {
                        specialsCover(art: art, compact: compact)
                    }
                    ForEach(years, id: \.self) { year in
                        let checklists = orderedChecklists(year: year)
                        VStack(alignment: .leading, spacing: 8) {
                            if years.count > 1 {
                                season(year)
                                    .foregroundStyle(.white.opacity(0.83))
                            }
                            coverGrid {
                                if years.count == 1 {
                                    ForEach(checklists.prefix(4)) { checklistCover($0, cards: cards, art: art, compact: compact) }
                                    specialsCover(art: art, compact: compact)
                                    ForEach(checklists.dropFirst(4)) { checklistCover($0, cards: cards, art: art, compact: compact) }
                                } else {
                                    ForEach(checklists) { checklistCover($0, cards: cards, art: art, compact: compact) }
                                }
                            }
                        }
                    }
                }
                .padding(compact ? 10 : 12)
                .background {
                    RoundedRectangle(cornerRadius: 15).fill(
                        LinearGradient(colors: [shelfColor(0x28352E), shelfColor(0x0D120F)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.16))
                    RoundedRectangle(cornerRadius: 11).inset(by: 4)
                        .strokeBorder(shelfColor(0x9CAEA0).opacity(0.60), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                }
                .shadow(color: .black.opacity(0.23), radius: 5, y: 3)
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("binder.shelf")
    }

    private func season(_ year: Int, brand: String? = nil) -> some View {
        Text(verbatim: [String(year), brand?.uppercased()].compactMap { $0 }.joined(separator: " · "))
            .font(.subheadline.weight(.heavy).monospacedDigit())
            .tracking(1)
            .accessibilityAddTraits(.isHeader)
    }

    private var findButton: some View {
        Button(action: find) {
            Label(tr("Karte finden"), systemImage: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.scoutAccent)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.scoutLine) }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("binder.findCard")
    }

    private func valueAndSearch(_ tag: BinderPriceTag) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { tag; Spacer(minLength: 8); findButton }
            VStack(alignment: .leading, spacing: 4) { tag; findButton }
        }
    }

    private func coverGrid(@ViewBuilder content: () -> some View) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9, alignment: .top),
                                 count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 9, content: content)
    }

    private func priceTag(for cards: [OwnedCard]) -> BinderPriceTag {
        BinderPriceTag(value: BinderValue(cards: cards, prices: store.dashboardValueCache))
    }

    private func checklistCover(_ collection: CardCollection, cards: [OwnedCard], art: String, compact: Bool) -> some View {
        let design = BinderShelfDesign(collection: collection, product: binder.product)
        return cover(route: .checklist(collection.id), title: binderShelfTitle(collection, in: binder),
                     material: design.material, league: design.league, art: art, compact: compact,
                     priceTag: priceTag(for: collection.ownedCards(in: cards)))
    }

    private func specialsCover(art: String, compact: Bool) -> some View {
        cover(route: .specials, title: tr("Besondere Karten"), material: .specials,
              art: art, compact: compact, count: specials.count, priceTag: priceTag(for: specials.map(\.card)))
    }

    private func cover(route: BinderShelfRoute, title: String, material: BinderShelfMaterial,
                       league: BinderLeague? = nil, art: String, compact: Bool, count: Int? = nil,
                       priceTag: BinderPriceTag) -> some View {
        Button { open(route) } label: {
            BinderShelfJacket(title: title, material: material, league: league, art: art, compact: compact,
                              count: count, priceTag: priceTag)
                .modifier(BinderNavigationSource(id: route.coverID, namespace: transition, reduceMotion: reduceMotion))
        }
        .buttonStyle(BinderShelfPressStyle())
        .accessibilityLabel(title)
        .accessibilityValue([league?.name ?? count.map(String.init), priceTag.spokenValue]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("binder.subbinder." + route.coverID)
    }

    private func orderedChecklists(year: Int) -> [CardCollection] {
        let checklists = binder.collections.filter { $0.year == year }
        guard binder.product == .bowman else { return checklists }
        let names = ["Base", "Paper Prospects", "Chrome Base", "Chrome Prospects"]
        let featured = names.compactMap { name in
            checklists.first { $0.subset == name && ($0.parallel ?? "").isEmpty }
        }
        let featuredIDs = Set(featured.map(\.id))
        return featured + checklists.filter { !featuredIDs.contains($0.id) }
    }
}

private struct BinderShelfDesign {
    let material: BinderShelfMaterial
    let league: BinderLeague?

    init(collection: CardCollection, product: BinderProduct?) {
        if product == .bowman {
            switch collection.subset.lowercased() {
            case "base": material = .paper; league = .nfl
            case "paper prospects": material = .prospects; league = .college
            case "chrome base": material = .chrome; league = .nfl
            case "chrome prospects": material = .chromeProspects; league = .college
            default: material = .paper; league = nil
            }
        } else {
            material = (product == .chrome || collection.name.localizedCaseInsensitiveContains("optic")) ? .chrome : .paper
            league = nil
        }
    }
}

private enum BinderShelfMaterial {
    case paper, prospects, chrome, chromeProspects, specials

    var colors: (light: Color, dark: Color, trim: Color) {
        switch self {
        case .paper: (shelfColor(0x2D5844), shelfColor(0x071D15), shelfColor(0xB8EDCC))
        case .prospects: (shelfColor(0x936E40), shelfColor(0x382311), shelfColor(0xF8DBA7))
        case .chrome: (shelfColor(0x718480), shelfColor(0x121B1D), shelfColor(0xF0F8F3))
        case .chromeProspects: (shelfColor(0x446B94), shelfColor(0x142039), shelfColor(0xD7E9FF))
        case .specials: (shelfColor(0xD8AA4C), shelfColor(0x4C290E), shelfColor(0xFFE4A0))
        }
    }

    var artOpacity: Double {
        switch self {
        case .paper, .prospects: 0.58
        case .chrome, .chromeProspects: 0.76
        case .specials: 0.30
        }
    }

    var isFoil: Bool { self == .chrome || self == .chromeProspects || self == .specials }
}

private enum BinderLeague {
    case nfl, college

    var name: String { self == .nfl ? "NFL" : "College" }
    var symbol: String { self == .nfl ? "football.fill" : "graduationcap.fill" }
    var tint: Color { self == .nfl ? shelfColor(0xAFF6C8) : shelfColor(0xE9DAFF) }
    var ground: Color { self == .nfl ? shelfColor(0x12372C) : shelfColor(0x342651) }
}

private struct BinderShelfPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.09 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct BinderShelfJacket: View {
    @ScaledMetric(relativeTo: .headline) private var jacketHeight = 142.0
    @ScaledMetric(relativeTo: .headline) private var compactHeight = 102.0
    let title: String
    let material: BinderShelfMaterial
    let league: BinderLeague?
    let art: String
    let compact: Bool
    let count: Int?
    let priceTag: BinderPriceTag
    private let jacket = UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5,
                                                 bottomTrailingRadius: 11, topTrailingRadius: 11)

    var body: some View {
        let colors = material.colors
        VStack(alignment: .leading, spacing: 0) {
            if let league {
                BinderLeagueBadge(league: league)
            } else if let count {
                Label(String(count), systemImage: "sparkles")
                    .font(.caption.weight(.heavy).monospacedDigit())
                    .foregroundStyle(colors.trim)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(shelfColor(0x45280D), in: Capsule())
            }
            Spacer(minLength: compact ? 8 : 19)
            Text(verbatim: title)
                .font(.system(compact ? .headline : .title3, design: .default, weight: .black).width(.condensed).italic())
                .textCase(.uppercase)
                .foregroundStyle(colors.trim)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            HStack(alignment: .bottom, spacing: 4) {
                priceTag
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(colors.trim.opacity(0.86))
            }.padding(.top, 4)
        }
        .padding(.top, compact ? 8 : 12).padding(.bottom, compact ? 6 : 9)
        .padding(.leading, 15).padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: compact ? compactHeight : jacketHeight, alignment: .leading)
        .background { materialSurface }
        .clipShape(jacket)
        .overlay {
            jacket.strokeBorder(colors.trim.opacity(0.48))
            jacket.inset(by: 4).strokeBorder(colors.trim.opacity(0.20))
        }
        .shadow(color: .black.opacity(0.65), radius: 3, y: 3)
        .contentShape(jacket)
        .accessibilityElement(children: .ignore)
    }

    private var materialSurface: some View {
        let colors = material.colors
        return GeometryReader { frame in
            ZStack(alignment: .top) {
                LinearGradient(colors: [colors.light, colors.dark], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(art)
                    .resizable().scaledToFill()
                    .frame(width: frame.size.width, height: frame.size.height)
                    .clipped()
                    .saturation(material == .specials ? 0 : 0.28)
                    .blendMode(.luminosity)
                    .opacity(material.artOpacity)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.15),
                    .init(color: colors.dark.opacity(0.64), location: 0.54),
                    .init(color: colors.dark, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                if material.isFoil {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.16),
                        .init(color: colors.trim.opacity(0.34), location: 0.27),
                        .init(color: .clear, location: 0.39),
                        .init(color: colors.trim.opacity(0.14), location: 0.53),
                        .init(color: .clear, location: 0.65)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .blendMode(.screen)
                }
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.61), colors.light, .black.opacity(0.54)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 8)
                    Rectangle().fill(colors.trim.opacity(0.25)).frame(width: 1)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct BinderLeagueBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shine = false
    let league: BinderLeague

    var body: some View {
        let badge = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 8,
                                           bottomTrailingRadius: 4, topTrailingRadius: 8)
        Label(league.name, systemImage: league.symbol)
            .font(.caption2.weight(.heavy))
            .textCase(.uppercase)
            .tracking(0.35)
            .foregroundStyle(league.tint)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background {
                badge.fill(league.ground)
                    .overlay {
                        if !reduceMotion {
                            GeometryReader { frame in
                                Rectangle()
                                    .fill(LinearGradient(colors: [.clear, league.tint.opacity(0.35), .clear],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: frame.size.width * 0.48, height: frame.size.height * 2)
                                    .rotationEffect(.degrees(23))
                                    .position(x: frame.size.width * (shine ? 1.5 : -0.5), y: frame.size.height / 2)
                            }.clipShape(badge)
                        }
                    }
            }
            .overlay { badge.strokeBorder(league.tint.opacity(0.66)) }
            .rotationEffect(.degrees(league == .nfl ? -4 : 3))
            .shadow(color: .black.opacity(0.63), radius: 2, y: 2)
            .accessibilityHidden(true)
            .onAppear {
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.78).delay(0.17)) { shine = true }
                }
            }
    }
}

private func shelfColor(_ rgb: UInt32) -> Color {
    Color(red: Double((rgb >> 16) & 255) / 255,
          green: Double((rgb >> 8) & 255) / 255,
          blue: Double(rgb & 255) / 255)
}
