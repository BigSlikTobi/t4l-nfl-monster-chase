import SwiftUI
import CardScoutCore

/// Yearless jackets cover every season. The two dated jackets require an exact edition.
struct BinderFinish {
    let material: String
    let needsTitle: Bool
    let stitch: Color

    init(_ binder: CollectionBinder) {
        let season2025 = !binder.collections.isEmpty && binder.collections.allSatisfy { $0.year == 2025 }
        let opticNames = ["donruss optic", "panini donruss optic", "donruss optic football", "panini donruss optic football"]
        var title = false
        switch binder.product {
        case .absolute: material = "BinderAbsolute"; stitch = .blue
        case .bowman: material = "BinderBowman"; stitch = .blue
        case .chrome where season2025: material = "BinderChrome2025"; stitch = .red
        case .donruss where season2025 && binder.collections.allSatisfy({ opticNames.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }):
            material = "BinderOptic2025"; stitch = .mint
        case .donruss: material = "BinderFoil"; stitch = .mint; title = true
        case .chrome: material = "BinderMetal"; stitch = .red; title = true
        case .flagship: material = "BinderFlagship"; stitch = Color(red: 0.87, green: 0.48, blue: 0.39)
        case .heritage: material = "BinderHeritage"; stitch = .orange
        case .phoenix: material = "BinderPhoenix"; stitch = .orange
        case .resurgence: material = "BinderResurgence"; stitch = .cyan
        case .select: material = "BinderSelect"; stitch = Color(red: 0.91, green: 0.74, blue: 0.39)
        case .stadiumClub: material = "BinderStadiumClub"; stitch = .mint
        case nil: material = "BinderUniversal"; stitch = Color(white: 0.76); title = true
        }
        needsTitle = title
    }
}

struct BinderCover: View {
    let binder: CollectionBinder

    var body: some View {
        let finish = BinderFinish(binder)
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                Image(finish.material).resizable().scaledToFit()
                if finish.needsTitle {
                    Text(verbatim: binder.name.uppercased())
                        .font(.system(size: side * 0.115, weight: .black).width(.condensed).italic())
                        .tracking(-side * 0.002).lineLimit(3).minimumScaleFactor(0.27)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(LinearGradient(stops: [
                            .init(color: Color(white: 0.75), location: 0),
                            .init(color: .white, location: 0.40),
                            .init(color: Color(white: 0.70), location: 0.53),
                            .init(color: Color(white: 0.94), location: 0.78),
                            .init(color: Color(white: 0.68), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: .black.opacity(0.9), radius: 0.5, y: side * 0.004)
                        .frame(width: side * 0.66, height: side * 0.23)
                        .rotationEffect(.degrees(3.5))
                        .position(x: side * 0.475, y: side * 0.715)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(binder.name)
    }
}

struct BinderCarousel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var transition
    let binders: [CollectionBinder]
    @Binding var selectedID: String?

    private var selectedIndex: Int { binders.firstIndex { $0.id == selectedID } ?? 0 }
    private let sideInset: CGFloat = 32

    var body: some View {
        VStack(spacing: 12) {
            if binders.count > 1 {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(binders) { binder in
                            coverLink(binder)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, sideInset, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollPosition(id: $selectedID, anchor: .center)
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("binder.carousel")

                HStack(spacing: 12) {
                    pageButton("chevron.backward", label: tr("Vorherige Seite"), offset: -1)
                    Text(verbatim: "\(selectedIndex + 1) / \(binders.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.scoutMuted)
                        .accessibilityLabel(tr("Seite \(selectedIndex + 1) von \(binders.count)"))
                        .accessibilityIdentifier("binder.carousel.position")
                    pageButton("chevron.forward", label: tr("Nächste Seite"), offset: 1)
                }
            } else if let binder = binders.first {
                coverLink(binder)
            }
        }
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .onChange(of: binders.map(\.id), initial: true) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            selectedID = ids.first
        }
    }

    private func coverLink(_ binder: CollectionBinder) -> some View {
        let priceTag = BinderPriceTag(value: BinderValue(cards: binder.cards(in: store.library),
                                                       prices: store.dashboardValueCache))
        return NavigationLink {
            BinderContentsView(binderID: binder.id)
                .modifier(BinderNavigationDestination(id: binder.id, namespace: transition, reduceMotion: reduceMotion))
        } label: {
            BinderCover(binder: binder)
                .overlay(alignment: .topTrailing) { priceTag.padding(12) }
                .modifier(BinderNavigationSource(id: binder.id, namespace: transition, reduceMotion: reduceMotion))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(binder.name)
        .accessibilityValue(priceTag.spokenValue)
        .accessibilityHint(tr("Binder öffnen"))
        .accessibilityIdentifier("binder.cover." + binder.id)
    }

    private func pageButton(_ icon: String, label: String, offset: Int) -> some View {
        let target = selectedIndex + offset
        let enabled = binders.indices.contains(target)
        return Button {
            guard enabled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                selectedID = binders[target].id
            }
        } label: {
            CollectorToolIcon(name: icon)
                .foregroundStyle(enabled ? Color.scoutAccent : Color.scoutMuted)
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(offset < 0 ? "binder.carousel.previous" : "binder.carousel.next")
    }
}

struct BinderPriceTag: View {
    let value: BinderValue

    private var amounts: [String] {
        value.centsByCurrency.sorted { $0.key < $1.key }.map {
            CollectionCardValue.money($0.value, currency: $0.key)
        }
    }

    private var partialCoverage: String? {
        guard value.pricedCards > 0, value.pricedCards < value.ownedCards else { return nil }
        return tr("\(value.pricedCards)/\(value.ownedCards) bewertet")
    }

    var spokenValue: String {
        let prices = amounts
        if prices.isEmpty { return trDisplay(value.ownedCards == 0 ? "Keine Karten" : "Wert offen") }
        return (prices + [partialCoverage].compactMap { $0 }).joined(separator: ", ")
    }

    var body: some View {
        let prices = amounts
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "tag.fill").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(prices.isEmpty ? ["—"] : prices, id: \.self) { price in
                    Text(verbatim: price).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                }
                if let partialCoverage {
                    Text(verbatim: partialCoverage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
        }
        .font(.caption.weight(.heavy))
        .foregroundStyle(Color.scoutEditorialGold)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.scoutEditorialGold.opacity(0.5)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Wert"))
        .accessibilityValue(spokenValue)
    }
}

struct BinderNavigationSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.matchedTransitionSource(id: id, in: namespace)
        } else { content }
    }
}

struct BinderNavigationDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else { content }
    }
}

struct BinderContentsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var shelfTransition
    @State private var destination: BinderShelfRoute?
    @State private var searchDestination: BinderShelfRoute?
    @State private var searching = false
    @State private var lifted = false
    @State private var opened = false
    let binderID: String

    var body: some View {
        if let binder = store.library.binders.first(where: { $0.id == binderID }) {
            if binder.collections.isEmpty {
                BinderOpenFinishes(binder: binder)
            } else {
                let specials = binder.specials(in: store.library)
                BinderShelf(binder: binder, specials: specials, transition: shelfTransition,
                            open: { destination = $0 }, find: { searching = true })
                    .background(Color.scoutCanvas)
                    .navigationTitle(binder.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(item: $destination) { route in
                        switch route {
                        case let .checklist(id, number):
                            if let collection = binder.collections.first(where: { $0.id == id }) {
                                CollectionView(collectionID: id, finish: BinderFinish(binder),
                                               specialIDs: Set(specials.map(\.id)), requestedPocket: number)
                                    .navigationTitle(binderShelfTitle(collection, in: binder))
                                    .modifier(BinderNavigationDestination(id: route.coverID, namespace: shelfTransition,
                                                                          reduceMotion: reduceMotion || number != nil))
                            }
                        case .specials:
                            BinderSpecialsGallery(entries: specials)
                                .background(Color.scoutCanvas)
                                .navigationTitle(tr("Besondere Karten"))
                                .navigationBarTitleDisplayMode(.inline)
                                .modifier(BinderNavigationDestination(id: route.coverID, namespace: shelfTransition,
                                                                      reduceMotion: reduceMotion))
                        case let .ownedCard(id):
                            CardDetailView(cardID: id)
                        }
                    }
                    .sheet(isPresented: $searching, onDismiss: openSearchResult) {
                        BinderCardSearch(binder: binder, specials: specials) { route in
                            searchDestination = route
                            searching = false
                        }
                    }
                    .overlay(alignment: .top) {
                        if !opened && !reduceMotion {
                            BinderCover(binder: binder)
                                .rotation3DEffect(.degrees(lifted ? -100 : 0), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.55)
                                .opacity(lifted ? 0 : 1)
                                .frame(maxWidth: 470)
                                .padding(.horizontal, 14)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .task {
                        guard !opened else { return }
                        if !reduceMotion {
                            withAnimation(.easeInOut(duration: 0.52)) { lifted = true }
                            try? await Task.sleep(for: .milliseconds(520))
                        }
                        opened = true
                    }
            }
        } else {
            ScoutEmptyState(symbol: "books.vertical", title: tr("Binder nicht verfügbar."))
        }
    }

    private func openSearchResult() {
        if let searchDestination {
            destination = searchDestination
            self.searchDestination = nil
        }
    }
}

func binderVariant(_ collection: CardCollection) -> String {
    [collection.subset, collection.parallel ?? ""].reduce(into: [String]()) { parts, value in
        if !value.isEmpty && !parts.contains(where: { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }) {
            parts.append(value)
        }
    }.joined(separator: " · ")
}

/// Crops the helmet artwork from the same native asset used on the jacket.
struct BinderDivider: View {
    let collection: CardCollection
    let finish: BinderFinish
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\(collection.year)  /  \(collection.brand.uppercased())")
                    .font(.caption2.bold().monospaced()).tracking(1)
                Text(collection.name.uppercased()).font(.system(.title, design: .default, weight: .black).width(.condensed).italic())
                    .lineLimit(2).minimumScaleFactor(0.7)
                Text(binderVariant(collection)).font(.caption.weight(.semibold))
            }.foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .trailing) {
            GeometryReader { geo in
                Image(finish.material).resizable()
                    .frame(width: geo.size.width * 1.10, height: geo.size.width * 1.10)
                    .offset(x: geo.size.width * 0.20, y: -geo.size.width * 0.22)
                LinearGradient(colors: [Color(white: 0.06), Color(white: 0.06).opacity(0.83), .clear], startPoint: .leading, endPoint: .trailing)
            }.clipped().allowsHitTesting(false).accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyBinderPocket: View {
    let number: String
    let stitch: Color
    var body: some View {
        ZStack {
            Color(white: 0.08)
            GeometryReader { frame in
                let width = frame.size.width
                Ellipse().strokeBorder(stitch.opacity(0.13), lineWidth: 3)
                    .frame(width: width * 0.8, height: width * 1.55)
                    .rotationEffect(.degrees(-34)).offset(x: -width * 0.08, y: -width * 0.1)
            }
            VStack(spacing: 6) {
                Image(systemName: "scope").font(.footnote).foregroundStyle(stitch)
                Text(verbatim: "#" + number).font(.system(.title2, design: .default, weight: .heavy).italic())
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .aspectRatio(5.0 / 7.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.30), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])) }
        .accessibilityHidden(true)
    }
}

struct FoldedPocketSheet: Animatable, ViewModifier {
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.6)
    }
}
