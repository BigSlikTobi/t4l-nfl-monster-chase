import SwiftUI
import CardScoutCore

struct RecentScanSet: Identifiable {
    let id: String
    let title: String
    let season: Int?
    let artwork: String
    var cards: [OwnedCard]

    static func groups(_ library: Library) -> [Self] {
        let catalog = Dictionary(library.collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: Self] = [:]
        var order: [String] = []
        for card in library.cards.sorted(by: { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }) {
            let a = card.analysis
            let entry = a?.collectionID.flatMap { catalog[$0] }
            let name = (entry?.name ?? a?.setName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let brand = entry?.brand ?? a?.brand ?? ""
            let year = entry?.year ?? a?.year
            let key = name.isEmpty ? "unassigned" : [brand.lowercased(), name.lowercased(), year.map(String.init) ?? ""].joined(separator: "|")
            if groups[key] == nil {
                let display = entry ?? CardCollection(id: key, name: name, year: year ?? 0, brand: brand, cards: [])
                let material = CollectionBinder.group([display]).first.map { BinderFinish($0).material } ?? "BinderUniversal"
                groups[key] = Self(id: key, title: name, season: year, artwork: material, cards: [])
                order.append(key)
            }
            groups[key]?.cards.append(card)
        }
        return order.compactMap { groups[$0] }
    }

    @MainActor var label: String { title.isEmpty ? tr("Finding set") : title }
}

extension ScanCheck {
    var labelKey: String {
        switch self {
        case .photo(.front): "Check front photo"
        case .photo(.back): "Check back photo"
        case .reading(let field): field.labelKey
        case .tilt: "Tilt the card slightly"
        case .finish: "Check the finish"
        case .checklist: "Match checklist entry"
        }
    }
    var symbol: String {
        switch self { case .photo, .tilt: "camera"; case .reading(.serial): "number"; case .reading: "text.magnifyingglass"; case .finish: "sparkles"; case .checklist: "rectangle.stack" }
    }
}
extension PrintedField {
    var labelKey: String {
        switch self { case .number: "Card number"; case .player: "Player name"; case .year: "Printed year"; case .serial: "Serial stamp" }
    }
}

private enum ScanFilter: String, CaseIterable {
    case all = "All", review = "To review", processing = "Processing"
    func includes(_ card: OwnedCard) -> Bool {
        switch self { case .all: true; case .review: !card.scanChecks.isEmpty; case .processing: card.awaitingBack != true && (card.isAwaitingAnalysis || card.state == "failed") }
    }
}

struct RecentScanEntry: View {
    let groups: [RecentScanSet]
    let reviewCount: Int
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if groups.count > 1 { Image(groups[1].artwork).resizable().scaledToFill().frame(width: 30, height: 38).clipShape(RoundedRectangle(cornerRadius: 4)).rotationEffect(.degrees(6)).offset(x: 13) }
                    Image(groups.first?.artwork ?? "BinderUniversal").resizable().scaledToFill().frame(width: 32, height: 42).clipShape(RoundedRectangle(cornerRadius: 5)).rotationEffect(.degrees(-5))
                }.frame(width: 49)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Recent scans")).font(.subheadline.bold())
                    if !groups.isEmpty { Text(verbatim: groups.prefix(2).map(\.label).joined(separator: " · ")).font(.caption).foregroundStyle(StudioStyle.muted).lineLimit(1) }
                }
                Spacer()
                if reviewCount > 0 { Text(tr("\(reviewCount) to review")).font(.caption2.bold()).foregroundStyle(Color.scoutGold) }
                Image(systemName: "chevron.right").font(.caption)
            }.padding(9).background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(StudioStyle.edge) }
        }.buttonStyle(.plain).accessibilityIdentifier("studio.recent")
    }
}

struct RecentScansView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: String?
    @State private var filter: ScanFilter = .all
    @State private var queue: ReviewScope?
    @State private var direct: ReviewCardID?
    private var groups: [RecentScanSet] { RecentScanSet.groups(store.library) }

    var body: some View {
        let sets = groups
        let current = sets.first { $0.id == selected } ?? sets.first
        let pending = sets.flatMap(\.cards).filter { !$0.scanChecks.isEmpty }
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(tr("Recent scans").uppercased()).font(.system(.largeTitle, design: .default, weight: .black).width(.condensed)).italic()
                    Spacer()
                    Button { queue = ReviewScope(ids: pending.map(\.id)) } label: {
                        Label(tr("Review \(pending.count)"), systemImage: "rectangle.stack").font(.caption.bold())
                            .padding(.horizontal, 10).frame(minHeight: 44).background(StudioStyle.panel, in: Capsule())
                    }.accessibilityIdentifier("recent.queue")
                }
                if let current {
                    hero(current)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(sets) { group in
                                Button { selected = group.id; filter = .all } label: {
                                    HStack(spacing: 7) {
                                        Image(group.artwork).resizable().scaledToFill().frame(width: 25, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                                        Text(verbatim: [group.label, group.season.map(String.init)].compactMap { $0 }.joined(separator: " ")).font(.caption.bold())
                                    }.padding(.horizontal, 7).frame(minHeight: 44)
                                        .overlay(alignment: .bottom) { if group.id == current.id { Capsule().fill(StudioStyle.mint).frame(height: 2) } }
                                }.accessibilityAddTraits(group.id == current.id ? .isSelected : [])
                            }
                        }
                    }.scrollIndicators(.hidden)
                    Text(tr("Scanned cards")).font(.title3.bold()).padding(.top, 5)
                    HStack(spacing: 5) {
                        ForEach(ScanFilter.allCases, id: \.self) { item in
                            Button { filter = item } label: {
                                Text(verbatim: trDisplay(item.rawValue) + " " + String(current.cards.filter(item.includes).count))
                                    .font(.caption.bold()).padding(.horizontal, 9).frame(minHeight: 44)
                                    .background(filter == item ? StudioStyle.panel : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }.accessibilityAddTraits(filter == item ? .isSelected : [])
                        }
                    }
                    let cards = current.cards.filter(filter.includes)
                    if cards.isEmpty { Text(tr("No cards in this view.")).font(.subheadline).foregroundStyle(StudioStyle.muted) }
                    LazyVStack(spacing: 0) { ForEach(cards) { card in
                        Button { direct = ReviewCardID(id: card.id) } label: { ScanReviewRow(card: card, connected: store.connected) }.buttonStyle(.plain)
                        Divider()
                    } }
                } else { Label(tr("Noch keine Scans"), systemImage: "viewfinder").foregroundStyle(StudioStyle.muted).padding(.top, 30) }
            }.frame(maxWidth: 580, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(StudioStyle.room).foregroundStyle(.white).tint(StudioStyle.mint).buttonStyle(.plain)
        .sheet(item: $queue) { scope in ScanReviewQueue(ids: scope.ids) }
        .sheet(item: $direct) { selection in ScanReviewDetail(cardID: selection.id) }
    }

    private func hero(_ group: RecentScanSet) -> some View {
        let checks = group.cards.filter { !$0.scanChecks.isEmpty }
        return ZStack(alignment: .bottomLeading) {
            GeometryReader { g in
                Image(group.artwork).resizable().scaledToFill().frame(width: g.size.width * 0.73, height: g.size.height).clipped().frame(maxWidth: .infinity, alignment: .trailing)
            }
            LinearGradient(colors: [StudioStyle.room, StudioStyle.room.opacity(0.87), .clear], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                Text(group.label.uppercased()).font(.system(.largeTitle, design: .default, weight: .black).width(.condensed)).italic().lineLimit(2).minimumScaleFactor(0.68)
                if let season = group.season { Text(verbatim: String(season)).font(.caption.monospacedDigit()) }
                Button {
                    if !checks.isEmpty { queue = ReviewScope(ids: checks.map(\.id)) }
                    else if let card = group.cards.first { direct = ReviewCardID(id: card.id) }
                } label: { Label(checks.isEmpty ? tr("Latest card") : tr("Review cards"), systemImage: "arrow.right").font(.caption.bold()).padding(.horizontal, 12).frame(minHeight: 44)
                    .foregroundStyle(StudioStyle.room).background(StudioStyle.mint, in: RoundedRectangle(cornerRadius: 9)) }
            }.padding(16).frame(maxWidth: 232, alignment: .leading)
        }.frame(minHeight: 200).background(StudioStyle.panel).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(StudioStyle.edge) }
    }
}

private struct ReviewScope: Identifiable { let id = UUID(); let ids: [String] }
struct ReviewCardID: Identifiable { let id: String }

struct ScanReviewRow: View {
    let card: OwnedCard
    let connected: Bool
    var queue = false

    static func status(_ card: OwnedCard, connected: Bool) -> String {
        if card.state == "failed" { return "Retry analysis" }
        if card.isAwaitingAnalysis { return connected ? "Matching card" : "Waiting for connection" }
        if card.analysis?.identityConfirmed == true { return "Identified" }
        if card.analysis?.finishState != nil { return "Finish open" }
        return "Checklist match open"
    }
    var body: some View {
        let checks = card.scanChecks
        return HStack(spacing: 12) {
            OwnedPhoto(name: card.frontFile, maxPixel: 180, original: true).frame(width: 48, height: 67)
            VStack(alignment: .leading, spacing: 4) {
                Text(cardTitle(card)).font(.headline)
                let meta = [card.analysis?.setName, card.analysis?.cardNumber.map { "#" + $0 }].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty { Text(verbatim: meta).font(.caption).foregroundStyle(StudioStyle.muted).lineLimit(1) }
                if let first = checks.first {
                    let label = queue ? checks.map { trDisplay($0.labelKey) }.joined(separator: " · ") : trDisplay(first.labelKey) + (checks.count > 1 ? "  +" + String(checks.count - 1) : "")
                    Label(label, systemImage: first.symbol).font(.caption.weight(.semibold)).foregroundStyle(Color.scoutGold)
                } else { Text(trDisplay(Self.status(card, connected: connected))).font(.caption).foregroundStyle(StudioStyle.mint) }
            }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(StudioStyle.muted).font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
    }
}

struct ScanReviewQueue: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    @State private var current: ReviewCardID?
    @State private var remaining: [String] = []
    private var pending: [OwnedCard] {
        let byID = Dictionary(store.library.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.filter { !$0.scanChecks.isEmpty }
    }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 5) {
                let cards = pending
                if cards.isEmpty {
                    Label(tr("All caught up"), systemImage: "checkmark.circle").padding(.top)
                } else {
                    Text(tr("\(cards.count) cards · \(cards.reduce(0) { $0 + $1.scanChecks.count }) checks")).font(.subheadline).foregroundStyle(StudioStyle.muted)
                    ForEach(cards) { card in
                        Divider()
                        Button {
                            let order = cards.map(\.id)
                            let index = order.firstIndex(of: card.id) ?? 0
                            remaining = Array(order.dropFirst(index + 1)) + Array(order.prefix(index))
                            current = ReviewCardID(id: card.id)
                        } label: { ScanReviewRow(card: card, connected: store.connected, queue: true) }.buttonStyle(.plain)
                    }
                }
            }.padding(18).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity) }
            .background(StudioStyle.room).navigationTitle(tr("Review cards"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Schließen")) { dismiss() } } }
            .sheet(item: $current) { selected in ScanReviewDetail(cardID: selected.id, advance: {
                let available = Set(pending.map(\.id))
                remaining.removeAll { !available.contains($0) }
                current = remaining.isEmpty ? nil : ReviewCardID(id: remaining.removeFirst())
            }).id(selected.id) }
        }.preferredColorScheme(.dark).tint(StudioStyle.mint).presentationDragIndicator(.visible)
    }
}
