import SwiftUI
import CardScoutCore

private enum ClubhouseRoute: Identifiable {
    case gallery, inspector(String)
    var id: String {
        switch self { case .gallery: "gallery"; case .inspector(let id): "card-" + id }
    }
}

private func setLine(_ card: OwnedCard) -> String {
    [card.analysis?.year.map(String.init), card.analysis?.setName].compactMap { $0 }.joined(separator: " ")
}

private func editionLine(_ card: OwnedCard) -> String {
    let a = card.analysis
    return [a?.subset, a?.parallel, a?.cardNumber.map { "#" + $0 }, a?.serialNumber]
        .compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String]()) { parts, value in
            if !parts.contains(value) { parts.append(value) }
        }.joined(separator: " · ")
}

struct ClubhouseDisplayCase: View {
    let cards: [OwnedCard]
    @AppStorage("clubhouseFeaturedCardID") private var featuredID = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: String?
    @State private var route: ClubhouseRoute?

    private var index: Int {
        cards.firstIndex { $0.id == selectedID } ?? cards.firstIndex { $0.id == featuredID } ?? 0
    }
    private var active: OwnedCard? { cards.indices.contains(index) ? cards[index] : nil }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Image("ClubhouseDisplayCase").resizable().accessibilityHidden(true)
                LinearGradient(colors: [.black.opacity(0.24), .clear], startPoint: .leading, endPoint: .trailing)
                if let card = active {
                    Button { route = .inspector(card.id) } label: {
                        ZStack(alignment: .leading) {
                            let pieces = cardTitle(card).split(separator: " ", maxSplits: 1).map(String.init)
                            VStack(alignment: .leading, spacing: 4) {
                                if pieces.count == 2 {
                                    Text(verbatim: pieces[0].uppercased()).font(.caption.bold()).tracking(1.4)
                                }
                                Text(verbatim: (pieces.last ?? cardTitle(card)).uppercased())
                                    .font(.system(size: w * 0.093, weight: .black).width(.condensed).italic())
                                    .minimumScaleFactor(0.58).lineLimit(3)
                                Text(verbatim: setLine(card)).font(.caption.bold())
                                Text(verbatim: editionLine(card)).font(.caption2.monospaced())
                            }.foregroundStyle(.white).shadow(color: .black, radius: 2)
                                .frame(width: w * 0.46, alignment: .leading).position(x: w * 0.28, y: h * 0.58)
                            ShowcaseDeckSurface(card: card, back: false)
                                .padding(5).padding(.top, 5)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
                                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.65), lineWidth: 1.5) }
                                .overlay(alignment: .top) { Circle().fill(.gray.gradient).frame(width: 6, height: 6).padding(.top, 2) }
                                .frame(width: w * 0.42, height: h * 0.61)
                                .rotationEffect(.degrees(3)).shadow(color: .black.opacity(0.6), radius: 4, x: 3, y: 4)
                                .position(x: w * 0.72, y: h * 0.445)
                        }.frame(width: w, height: h).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(cardTitle(card)).accessibilityHint(tr("Kartendetails öffnen"))
                        .accessibilityIdentifier("clubhouse.hero.card")
                        .simultaneousGesture(DragGesture(minimumDistance: 32).onEnded { value in
                            let x = value.translation.width
                            if abs(x) > max(45, abs(value.translation.height) * 1.5) { step(x < 0 ? 1 : -1) }
                        })
                } else {
                    NavigationLink { ShowcasePickerView() } label: {
                        Label(tr("Karte auswählen"), systemImage: "plus.circle.fill").font(.headline)
                            .padding(12).background(.thinMaterial, in: Capsule())
                    }
                }
                VStack {
                    HStack {
                        Button { route = .gallery } label: {
                            Label(tr("Collectibles"), systemImage: "arrow.up.right").labelStyle(.titleAndIcon)
                                .font(.subheadline.bold()).frame(minHeight: 44)
                        }.accessibilityIdentifier("clubhouse.gallery")
                        Spacer()
                    }
                    Spacer()
                    if cards.count > 1 {
                        HStack {
                            Spacer()
                            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                                .accessibilityLabel(tr("Vorherige Karte"))
                            Text(verbatim: "\(index + 1) / \(cards.count)").font(.caption.monospacedDigit().bold())
                            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                                .accessibilityLabel(tr("Nächste Karte"))
                        }
                    }
                }.foregroundStyle(.white).padding(.horizontal, 12)
            }
        }.aspectRatio(1.04, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(Color.white.opacity(0.25)) }
        .onChange(of: featuredID) { _, id in selectedID = id }
        .sheet(item: $route) { entry in
            NavigationStack {
                Group {
                    switch entry {
                    case .gallery: ClubhouseGallery(feature: choose)
                    case .inspector(let id): ClubhouseInspector(cardID: id, feature: choose)
                    }
                }.toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { route = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(tr("Schließen"))
                    }
                }
            }.presentationDragIndicator(.visible)
        }
    }

    private func choose(_ id: String) { featuredID = id; selectedID = id; route = nil }
    private func step(_ direction: Int) {
        guard cards.count > 1 else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            selectedID = cards[(index + direction + cards.count) % cards.count].id
        }
    }
}

struct ClubhouseGallery: View {
    @Environment(AppStore.self) private var store
    @AppStorage("clubhouseFeaturedCardID") private var featuredID = ""
    var feature: (String) -> Void
    private var cards: [OwnedCard] { store.library.collectibles }
    private var lead: OwnedCard? { cards.first { $0.id == featuredID } ?? cards.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                if let lead {
                    tile(lead, featured: true)
                    Divider().overlay(.white.opacity(0.45))
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                        ForEach(cards.filter { $0.id != lead.id }) { tile($0, featured: false) }
                    }
                } else {
                    ScoutEmptyState(symbol: "trophy", title: tr("Deine Collectibles."), message: tr("Markiere deine Lieblingsstücke mit der Trophäe in den Kartendetails."))
                }
                NavigationLink { ShowcasePickerView() } label: {
                    Label(tr("Karte auswählen"), systemImage: "plus").font(.subheadline.bold()).frame(minHeight: 44)
                }
            }.padding(.horizontal, 18).padding(.vertical, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Image("ClubhouseCardTray").resizable().ignoresSafeArea(edges: .bottom).accessibilityHidden(true) }
        .foregroundStyle(.white).navigationTitle(tr("Collectibles")).navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar).toolbarBackground(Color.scoutPhotoBackdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
    private func tile(_ card: OwnedCard, featured: Bool) -> some View {
        let layout = featured ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 7))
        return NavigationLink { ClubhouseInspector(cardID: card.id, feature: feature) } label: {
            layout {
                ShowcaseDeckSurface(card: card, back: false).aspectRatio(5 / 7, contentMode: .fit)
                    .frame(maxWidth: featured ? 142 : 125).padding(3).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .rotationEffect(.degrees(featured ? -3 : 0))
                VStack(alignment: .leading, spacing: 4) {
                    if featured { Label(tr("Im Clubhaus"), systemImage: "pin.fill").font(.caption2.bold()).foregroundStyle(.mint) }
                    Text(cardTitle(card)).font(featured ? .title2.bold().italic() : .subheadline.bold())
                    Text(verbatim: setLine(card)).font(.caption)
                    Text(verbatim: editionLine(card)).font(.caption2.monospaced())
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("clubhouse.tile." + card.id)
    }
}

struct ClubhouseInspector: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cardID: String
    var feature: (String) -> Void
    @State private var back = false
    var body: some View {
        if let card = store.library.cards.first(where: { $0.id == cardID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(cardTitle(card)).font(.title2.bold())
                    Text(verbatim: [setLine(card), editionLine(card)].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    if card.backFile != nil {
                        Button { back.toggle() } label: { inspectionTable(card) }
                            .buttonStyle(.plain).accessibilityLabel(tr("Karte umdrehen"))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: back)
                    } else {
                        inspectionTable(card).accessibilityLabel(tr("Vorderseite"))
                    }
                    HStack {
                        Picker(tr("Kartenseite"), selection: $back) {
                            Text(tr("Vorderseite")).tag(false)
                            if card.backFile != nil { Text(tr("Rückseite")).tag(true) }
                        }.pickerStyle(.segmented).frame(maxWidth: 210)
                        Spacer()
                        Button { store.toggleFavorite(card.id) } label: {
                            Image(systemName: card.isFavorite == true ? "heart.fill" : "heart").frame(width: 44, height: 44)
                        }.accessibilityLabel(trDisplay(card.isFavorite == true ? "Favorit entfernen" : "Als Favorit merken"))
                    }
                    Button { feature(card.id) } label: { Label(tr("Im Clubhaus zeigen"), systemImage: "pin.fill") }.buttonStyle(ScoutPrimaryButtonStyle())
                    NavigationLink { CardDetailView(cardID: card.id) } label: { Label(tr("Kartendetails öffnen"), systemImage: "arrow.up.right") }.buttonStyle(ScoutSecondaryButtonStyle())
                }.padding()
            }.background(Color.scoutCanvas).navigationBarTitleDisplayMode(.inline)
        }
    }
    private func inspectionTable(_ card: OwnedCard) -> some View {
        ShowcaseFlippingCard(card: card, flipped: back, light: .zero)
            .frame(maxWidth: .infinity).frame(height: 295).padding(14)
            .background(RadialGradient(colors: [Color(white: 0.56), Color(white: 0.14)], center: .center, startRadius: 2, endRadius: 250))
            .overlay { HStack { lamp; Spacer(); lamp }.padding(12).allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var lamp: some View { Capsule().fill(Color.mint.opacity(0.7)).frame(width: 2, height: 165).shadow(color: .mint, radius: 4) }
}
