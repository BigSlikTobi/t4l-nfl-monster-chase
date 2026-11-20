import SwiftUI
import PhotosUI
import CardScoutCore

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var tileWidth = 108.0
    @State private var adding = false
    @State private var showingRemovedCards = false
    @State private var finishingUnclear = false
    @State private var search = ""
    @State private var searchOpen = false
    @State private var inboxOpen = false
    @FocusState private var searching: Bool
    @State private var filter = "Binder"
    @State private var sort = "Neueste"
    @State private var selectedBinderID: String?
    private var pending: [OwnedCard] { store.library.cards.filter(\.isAwaitingAnalysis) }
    private var review: [OwnedCard] { store.library.cards.filter { !$0.isAwaitingAnalysis && collectorNeedsAttention($0) } }
    private var visible: [OwnedCard] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var cards = store.library.collectedCards.filter { card in
            if filter == "Favoriten" && card.isFavorite != true { return false }
            if filter == "Collectibles" && card.isCollectible != true { return false }
            if filter == "Offen" && !collectorNeedsAttention(card) { return false }
            let a = card.analysis
            return query.isEmpty || [card.title, a?.team, a?.year.map(String.init), a?.brand, a?.setName, a?.parallel, a?.cardNumber, card.storageLocation, card.notes]
                .compactMap { $0 }.joined(separator: " ").localizedStandardContains(query)
        }
        if sort == "Spieler" { cards.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        else if sort == "Wert" {
            cards.sort { left, right in
                let a = displayedPrice(left)
                let b = displayedPrice(right)
                // Prices in different currencies cannot be compared without an exchange rate.
                if a?.currency != b?.currency { return (a?.currency ?? "~") < (b?.currency ?? "~") }
                if a?.cents != b?.cents { return (a?.cents ?? -1) > (b?.cents ?? -1) }
                return left.createdAt > right.createdAt
            }
        } else { cards.sort { $0.createdAt > $1.createdAt } }
        return cards
    }
    private func displayedPrice(_ card: OwnedCard) -> (currency: String, cents: Double)? {
        if let value = store.dashboardValueCache.collectionQuote(for: card) {
            return (value.currency, Double(value.amountCents))
        }
        return nil
    }
    private let collectionFilters = ["Binder", "Alle", "Collectibles", "Favoriten", "Ordner", "Offen"]
    private var onBinderShelf: Bool { filter == "Binder" && search.isEmpty }

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            NavigationStack {
                ClubhouseHomeView()
            }.collectorTabSurface().tabItem {
                CollectorTabLabel(title: tr("Clubhaus"), icon: "house", selectedIcon: "house.fill", selected: store.selectedTab == 0)
            }.tag(0)
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !onBinderShelf {
                            #if DEBUG
                            if PreviewData.enabled { Text(tr("DESIGN-VORSCHAU · DEMODATEN")).font(.caption2.monospaced()).foregroundStyle(Color.scoutMuted) }
                            #endif
                            HStack {
                                Text(tr("\(store.library.collectedCards.count) Karten · \(store.library.binders.count) Binder")).font(.subheadline).foregroundStyle(Color.scoutMuted)
                                Spacer()
                                Menu {
                                    Picker(tr("Sortieren"), selection: $sort) { Text(tr("Neueste zuerst")).tag("Neueste"); Text(tr("Spieler A–Z")).tag("Spieler"); Text(tr("Preis · je Währung")).tag("Wert") }
                                } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }
                                    .accessibilityLabel(tr("Sammlung sortieren"))
                            }
                            nextSteps
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(collectionFilters, id: \.self) { value in
                                        Button { filter = value } label: { ScoutChip(trDisplay(value), selected: filter == value) }.buttonStyle(.plain)
                                    }
                                }
                            }.scrollIndicators(.hidden)
                        }
                        if filter == "Ordner" {
                            if (store.library.folders ?? []).isEmpty { Text(tr("Wähle nach dem Scan einen Ordner oder lege einen neuen an.")).foregroundStyle(Color.scoutMuted) }
                            ForEach(store.library.folders ?? []) { folder in
                                NavigationLink { FolderContentsView(folderID: folder.id) } label: {
                                    Label(tr("\(folder.name) · \(store.library.collectedCards.filter { folder.cardIDs.contains($0.id) }.count)"), systemImage: "folder")
                                        .padding(.vertical, 12)
                                }
                            }
                        } else if onBinderShelf {
                            let binders = store.library.binders
                            if binders.isEmpty {
                                ScoutEmptyState(symbol: "books.vertical", title: tr("Keine Binder"))
                                if store.library.collectedCards.isEmpty {
                                    Button { store.selectedTab = 3 } label: {
                                        Label(tr("Karten scannen"), systemImage: "viewfinder")
                                    }.buttonStyle(ScoutPrimaryButtonStyle())
                                } else {
                                    Button { filter = "Alle" } label: {
                                        Label(tr("Alle Karten zeigen"), systemImage: "rectangle.grid.2x2")
                                    }.buttonStyle(ScoutSecondaryButtonStyle())
                                }
                            } else {
                                BinderCarousel(binders: binders, selectedID: $selectedBinderID)
                            }
                        } else if visible.isEmpty {
                            ScoutEmptyState(symbol: filter == "Collectibles" ? "trophy" : filter == "Favoriten" ? "star" : "rectangle.stack", title: search.isEmpty ? (filter == "Collectibles" ? "Deine Collectibles." : filter == "Favoriten" ? "Deine Favoriten." : "Keine Karten") : "Keine Treffer.", message: search.isEmpty ? (filter == "Collectibles" ? "Markiere deine Lieblingsstücke mit der Trophäe in den Kartendetails." : "Scanne deine erste Karte oder wähle Fotos aus.") : nil)
                            if search.isEmpty && filter != "Collectibles" && filter != "Favoriten" { Button { store.selectedTab = 3 } label: { Label(tr("Karten scannen"), systemImage: "viewfinder") }.buttonStyle(ScoutPrimaryButtonStyle()) }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: filter == "Collectibles" ? max(tileWidth, 160) : tileWidth), spacing: 12, alignment: .top)], alignment: .leading, spacing: 24) {
                                ForEach(Array(visible.enumerated()), id: \.element.id) { index, card in
                                    NavigationLink(value: card.id) {
                                        if filter == "Collectibles" { ShowcaseCard(card: card, position: index + 1) }
                                        else { OwnedTile(card: card) }
                                    }.buttonStyle(.plain)
                                        .contextMenu {
                                            Button { store.toggleCollectible(card.id) } label: { Label(trDisplay(card.isCollectible == true ? "Aus Collectibles entfernen" : "Zu Collectibles hinzufügen"), systemImage: "trophy") }
                                            Button { store.toggleFavorite(card.id) } label: { Label(trDisplay(card.isFavorite == true ? "Favorit entfernen" : "Als Favorit merken"), systemImage: "star") }
                                        }
                                        .accessibilityAction(named: trDisplay(card.isFavorite == true ? "Favorit entfernen" : "Als Favorit merken")) { store.toggleFavorite(card.id) }
                                }
                            }
                        }
                        if !onBinderShelf && !review.isEmpty && filter != "Offen" {
                            Button { filter = "Offen" } label: {
                                HStack { Text(tr("\(review.count) Zuordnungen prüfen")); Spacer(); Image(systemName: "arrow.right") }
                                    .font(.subheadline).padding(.vertical, 16)
                            }.foregroundStyle(Color.scoutGold)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 28)
                }
                .background(Color.scoutCanvas)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) { collectionHeader }
                .navigationDestination(isPresented: $inboxOpen) {
                    ScrollView { nextStepActions.padding(20) }.navigationTitle(tr("Eingang"))
                }
                .navigationDestination(isPresented: $showingRemovedCards) { RemovedCardsView() }
                .navigationDestination(for: String.self) { CardDetailView(cardID: $0) }
                .refreshable { await store.sync() }
            }.collectorTabSurface().tabItem {
                CollectorTabLabel(title: tr("Sammlung"), icon: "rectangle.stack", selectedIcon: "rectangle.stack.fill", selected: store.selectedTab == 5)
            }.tag(5)
            NavigationStack { PackStudioView() }.collectorTabSurface().tabItem {
                CollectorTabLabel(title: tr("Scannen"), icon: "viewfinder", selectedIcon: "camera.viewfinder", selected: store.selectedTab == 3)
            }.tag(3)
            NavigationStack { CollectionStatisticsView().toolbar(.hidden, for: .navigationBar) }.collectorTabSurface().tabItem {
                CollectorTabLabel(title: tr("Insights"), icon: "chart.bar", selectedIcon: "chart.bar.fill", selected: store.selectedTab == 4)
            }.tag(4)
        }
        .modifier(CollectorTabBehavior())
        .tint(.scoutAccent)
        .sheet(isPresented: $adding) { AddCardView() }
        .sheet(isPresented: $store.showMarketRanking) {
            NavigationStack {
                HotListView().toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Fertig")) { store.showMarketRanking = false } } }
            }
        }
        .sheet(isPresented: $finishingUnclear) { UnclearCardQueueView() }
        .sheet(isPresented: $store.showSettings, onDismiss: { store.showConnectionSettings = false }) { ConnectionView() }
        .alert(tr("Bitte prüfen"), isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button(tr("OK")) { store.lastError = nil }
        } message: { Text(trDisplay(store.lastError ?? "")) }
    }

    private var collectionHeader: some View {
        VStack(spacing: 0) {
            CollectorHeader {
                Menu {
                    Picker(tr("Sammlung"), selection: $filter) {
                        ForEach(collectionFilters, id: \.self) { value in Text(trDisplay(value)).tag(value) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        CollectorHeading(text: onBinderShelf ? tr("Meine Binder") : tr("Sammlung"))
                        Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(Color.scoutMuted)
                    }.frame(minHeight: 44)
                }.accessibilityLabel(tr("Collection view")).accessibilityValue(trDisplay(filter))
                    .accessibilityIdentifier("shell.collection.filter")
            } actions: {
                Button {
                    if searchOpen { closeSearch() }
                    else { searchOpen = true; searching = true }
                } label: { CollectorToolIcon(name: searchOpen ? "xmark" : "magnifyingglass") }
                    .accessibilityLabel(searchOpen ? tr("Schließen") : tr("Search collection"))
                    .accessibilityIdentifier("shell.collection.search")
                Menu {
                    Button(tr("Eingang"), systemImage: "tray") { inboxOpen = true }
                    Button(tr("Entfernte Karten"), systemImage: "trash") { showingRemovedCards = true }
                    Divider()
                    Button(tr("Mehrere Karten scannen"), systemImage: "viewfinder") { store.selectedTab = 3 }
                    Button(tr("Vorder- und Rückseite"), systemImage: "rectangle.on.rectangle") { adding = true }
                } label: { CollectorToolIcon(name: "ellipsis") }
                    .accessibilityLabel(tr("Collection actions")).accessibilityIdentifier("shell.collection.actions")
            }
            if searchOpen {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.scoutMuted)
                    TextField(tr("Spieler, Set, Team oder Box"), text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($searching).submitLabel(.search).onSubmit { searching = false }
                    if !search.isEmpty {
                        Button { search = ""; searching = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.scoutMuted).frame(width: 44, height: 44)
                        }.accessibilityLabel(tr("Suche löschen"))
                    }
                }.padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.scoutCanvas)
            }
        }
    }

    private func closeSearch() {
        searching = false
        search = ""
        searchOpen = false
    }

    private var nextSteps: some View {
        DisclosureGroup { nextStepActions } label: {
            Label(tr("Eingang & nächste Schritte · \(pending.count + review.count + store.library.scanDrafts.count)"), systemImage: "tray")
                .font(.subheadline.weight(.medium))
        }
    }

    private var nextStepActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.library.scanDrafts.isEmpty {
                NavigationLink { ScanDraftsView() } label: {
                    Label(tr("\(store.library.scanDrafts.count) Scans vergleichen"), systemImage: "rectangle.stack.badge.plus")
                        .font(.headline).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
            if !pending.isEmpty { progressStrip }
            NavigationLink { ReviewQueueView() } label: {
                Label(tr("Nächste Schritte · Zuordnung & Preise"), systemImage: "checklist")
                    .font(.headline).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
            if store.library.unclearCardQueue?.currentID != nil || store.library.cards.contains(where: UnclearCardQueue.isEligible) {
                Button {
                    if store.startUnclearCardQueue() { finishingUnclear = true }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "rectangle.stack.badge.plus").font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trDisplay(store.library.unclearCardQueue?.currentID == nil ? "Offene Karten fertigstellen" : "Offene Karten fortsetzen")).font(.subheadline.weight(.semibold))
                            Text(tr("Fotos, Checkliste oder Variante prüfen · Karte für Karte")).font(.caption).foregroundStyle(Color.scoutMuted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }.padding(16).background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).foregroundStyle(Color.scoutAccent)
            }
        }.padding(.top, 12)
    }

    private var progressStrip: some View {
        NavigationLink { CardInboxView() } label: {
            HStack(spacing: 12) {
                if store.connected { ProgressView().controlSize(.small).tint(.scoutAccent) }
                else { Image(systemName: "tray").foregroundStyle(Color.scoutMuted) }
                VStack(alignment: .leading, spacing: 3) {
                    let known = pending.filter { $0.hasProvisionalAnalysis == true }.count
                    Text(trDisplay(store.connected ? "\(pending.count) Karten in Arbeit" : "\(pending.count) Karten gespeichert")).font(.subheadline.weight(.medium))
                    Text(trDisplay(!store.connected ? "Analyse startet mit deinem Mac oder Server." : known > 0 ? "\(known) vorläufig geprüft · Analyse läuft" : "Deine Fotos sind gespeichert.")).font(.caption).foregroundStyle(Color.scoutMuted)
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.scoutMuted)
            }.padding(14).background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

private func collectorNeedsAttention(_ card: OwnedCard) -> Bool {
    if card.automaticScan == true || card.analysis?.finishPolicy != nil {
        return card.isAwaitingAnalysis || card.state == "failed" || card.awaitingBack == true || card.canAddTilt
    }
    return card.isAwaitingAnalysis || ReviewIssue.identity(card) != nil || card.analysis?.collectionID == nil || (card.analysis?.needsReview == true && card.manualAssignment != true)
}

private func collectorStatus(_ card: OwnedCard) -> String {
    if card.hasCurrentAnalysis, card.automaticScan == true || card.analysis?.finishPolicy != nil {
        if card.canAddTilt { return "Tilt the card slightly" }
        return card.analysis?.identityConfirmed == true ? "In deiner Sammlung" : "Finish open"
    }
    return switch card.state {
    case "queued": "Analyse vorgemerkt"
    case "processing": "Wird erkannt"
    case "identified": card.analysis?.identityConfirmed == true ? "Erkannt · Preis folgt" : "Zuordnung prüfen · vorläufig"
    case "enriching": "Preis wird geprüft"
    case "failed": "Analyse erneut starten"
    default: card.analysis?.identityConfirmed != true ? "Zuordnung prüfen" : card.analysis?.needsReview == true ? "Bewertung prüfen" : "In deiner Sammlung"
    }
}

private struct CardInboxView: View {
    @Environment(AppStore.self) private var store
    @ScaledMetric(relativeTo: .body) private var tileWidth = 145.0
    private var cards: [OwnedCard] { store.library.cards.filter(collectorNeedsAttention).sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScoutSectionHeader(tr("Noch offen"), subtitle: tr("\(cards.count) \(trDisplay(cards.count == 1 ? "Karte" : "Karten"))"))
                if cards.isEmpty {
                    ScoutEmptyState(symbol: "checkmark.circle", title: tr("Alles einsortiert."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 16, alignment: .top)], spacing: 24) {
                        ForEach(cards) { card in NavigationLink { CardDetailView(cardID: card.id) } label: { OwnedTile(card: card) }.buttonStyle(.plain) }
                    }
                }
            }.padding(20)
        }.background(Color.scoutCanvas).navigationTitle(tr("Eingang")).navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.sync() }
    }
}

struct PhotoCard: View {
    var image: UIImage?
    var number: String
    var owned: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(owned ? Color.scoutSurface : Color.scoutElevated)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(4).saturation(owned ? 1 : 0).opacity(owned ? 1 : 0.3)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.portrait").font(.system(size: 30, weight: .ultraLight))
                    if !number.isEmpty { Text(tr("#\(number)")).font(.system(.title3, design: .rounded).weight(.medium)).lineLimit(2) }
                }.padding(8).foregroundStyle(Color.scoutMuted.opacity(owned ? 0.6 : 0.4))
            }
        }
        .aspectRatio(5 / 7, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.scoutLine.opacity(owned ? 0.65 : 0.35)))
        .accessibilityHidden(true)
    }
}

struct OwnedTile: View {
    @Environment(AppStore.self) private var store
    var card: OwnedCard
    var photoHeight: CGFloat? = nil
    private var needsAttention: Bool { collectorNeedsAttention(card) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            OwnedPhoto(name: card.frontFile, number: card.analysis?.cardNumber ?? "")
                .frame(height: photoHeight)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if card.isCollectible == true { Image(systemName: "trophy.fill").font(.system(size: 9)).foregroundStyle(Color.scoutGold).accessibilityLabel(tr("Collectible")) }
                if card.isFavorite == true { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.scoutAccent).accessibilityLabel(tr("Favorit")) }
                Text(cardTitle(card)).font(.caption.weight(.semibold)).foregroundStyle(Color.scoutInk).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let a = card.analysis {
                Text(trDisplay([a.cardNumber.map { "#" + $0 }, a.parallel ?? a.subset, a.rookie == true ? "RC" : nil].compactMap { $0 }.joined(separator: " · ")))
                    .font(.caption).foregroundStyle(Color.scoutMuted).lineLimit(2)
            }
            if let value = store.dashboardValueCache.collectionQuote(for: card) {
                Text(value.valueLabel).font(.subheadline.weight(.bold)).foregroundStyle(Color.scoutAccent)
                Text(trDisplay(value.basisLabel)).font(.caption2).foregroundStyle(Color.scoutMuted).lineLimit(2)
            }
            if needsAttention { Text(trDisplay(collectorStatus(card))).font(.caption2).foregroundStyle(Color.scoutMuted).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityHint(tr("Kartendetails öffnen"))
    }
}

struct CollectionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let collectionID: String
    let finish: BinderFinish
    let specialIDs: Set<String>
    @State private var requestedPocket: String?
    @State private var highlightedPocket: String?
    @SceneStorage private var savedPage: Int
    @State private var filteredPage = 0
    @State private var search = ""
    @State private var filter = "Alle"
    @State private var forward = true
    @State private var showingInfo = false
    @State private var missing: ChecklistCard?
    @State private var showingCopies: ChecklistCard?
    @State private var inspectingReference: CardReferenceImage?

    init(collectionID: String, finish: BinderFinish, specialIDs: Set<String>, showMissing: Bool = false,
         requestedPocket: String? = nil) {
        _filter = State(initialValue: showMissing ? "Fehlen" : "Alle")
        _requestedPocket = State(initialValue: requestedPocket)
        self.collectionID = collectionID
        self.finish = finish
        self.specialIDs = specialIDs
        _savedPage = SceneStorage(wrappedValue: 0, "binder.page." + collectionID)
    }

    private var locating: Bool { filter != "Alle" || !search.isEmpty }

    var body: some View {
        if let collection = store.library.collections.first(where: { $0.id == collectionID }) {
            let inventory = collection.ownedCards(in: store.library.cards)
            let owned = collection.ownedCount(in: inventory)
            let filtered = collection.cards.filter { entry in
                let have = !collection.owned(for: entry.number, in: inventory).isEmpty
                return (filter == "Alle" || (filter == "Besitze ich" ? have : !have)) && entry.matchesBinderSearch(search)
            }
            let pages = max(1, (filtered.count + 3) / 4)
            let page = min(max(0, locating ? filteredPage : savedPage), pages - 1)
            let entries = filtered.dropFirst(page * 4).prefix(4)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 12) {
                        Picker(tr("Karten"), selection: $filter) {
                            Text(tr("Alle")).tag("Alle")
                            Text(tr("Meine · \(owned)")).tag("Besitze ich")
                            Text(tr("Fehlen · \(max(collection.cards.count - owned, 0))")).tag("Fehlen")
                        }.pickerStyle(.segmented)
                        VStack(spacing: 5) {
                            BinderDivider(collection: collection, finish: finish)
                            BinderPriceTag(value: BinderValue(cards: inventory, prices: store.dashboardValueCache))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            if !collection.checklistComplete {
                                Text(tr("Teilcheckliste")).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                            }
                            if entries.isEmpty {
                                ScoutEmptyState(symbol: "magnifyingglass", title: tr("Keine Karten gefunden."))
                            } else {
                                ZStack(alignment: .topLeading) {
                                    pocketPage(entries, collection: collection, inventory: inventory)
                                        .id(page)
                                        .transition(pageTransition)
                                }
                                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
                                        guard abs(drag.translation.width) > max(48, abs(drag.translation.height) * 1.6) else { return }
                                        turn(to: page + (drag.translation.width < 0 ? 1 : -1), from: page, pages: pages)
                                    })
                            }
                        }
                        .padding(7)
                        .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.055)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).inset(by: 3)
                                .strokeBorder(finish.stitch.opacity(0.65), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                                .allowsHitTesting(false)
                        }
                        .environment(\.colorScheme, .dark)
                        .shadow(color: .black.opacity(0.22), radius: 4, x: 1, y: 3)
                        if pages > 1 {
                            HStack {
                                pageButton("chevron.left", label: tr("Vorherige Seite"), disabled: page == 0) {
                                    turn(to: page - 1, from: page, pages: pages)
                                }
                                Spacer()
                                Text(tr("Seite \(page + 1) von \(pages)")).font(.caption.weight(.semibold)).monospacedDigit()
                                    .accessibilityIdentifier("binder.page")
                                Spacer()
                                pageButton("chevron.right", label: tr("Nächste Seite"), disabled: page == pages - 1) {
                                    turn(to: page + 1, from: page, pages: pages)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 540).padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                }
                .task(id: highlightedPocket) {
                    if let highlightedPocket {
                        scroll.scrollTo(highlightedPocket, anchor: .center)
                    }
                }
            }
            .background(Color.scoutCanvas).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: tr("Spieler, Team oder Nummer"))
            .onChange(of: search) { _, _ in
                filteredPage = 0
                highlightedPocket = nil
            }
            .onChange(of: filter) { _, _ in
                filteredPage = 0
                highlightedPocket = nil
            }
            .task(id: requestedPocket) {
                guard let number = requestedPocket,
                      let index = collection.cards.firstIndex(where: { $0.number == number }) else { return }
                search = ""
                filter = "Alle"
                savedPage = index / 4
                highlightedPocket = number
                requestedPocket = nil
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingInfo = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel(tr("Checkliste"))
                }
            }
            .sheet(isPresented: $showingInfo) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            collectionHeader(collection, owned: owned)
                            if let product = store.library.chaseCatalog?.products.first(where: { $0.matches(collection) }) {
                                NavigationLink { HotListView(initialProductID: product.id) } label: {
                                    Label(tr("Wertvollste Karten"), systemImage: "chart.bar.xaxis")
                                }
                            }
                            if let source = collection.sourceURL, let url = URL(string: source) {
                                Link(destination: url) { Label(tr("Checkliste ansehen"), systemImage: "arrow.up.right.square") }
                            }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }.navigationTitle(collection.name).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Fertig")) { showingInfo = false } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(item: $missing) { entry in missingSheet(entry, collection: collection) }
            .navigationDestination(item: $showingCopies) { entry in
                BinderPocketCopies(collection: collection, entry: entry)
            }
        } else { ScoutEmptyState(symbol: "books.vertical", title: tr("Binder nicht verfügbar.")) }
    }

    private func pocketPage(_ entries: ArraySlice<ChecklistCard>, collection: CardCollection, inventory: [OwnedCard]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 6) {
            ForEach(entries) { entry in
                let copies = collection.owned(for: entry.number, in: inventory)
                Group {
                    if let card = copies.first(where: { specialIDs.contains($0.id) }) ?? copies.first {
                        if copies.count > 1 {
                            Button { showingCopies = entry } label: { ownedPocket(entry, card: card, copies: copies.count) }
                        } else {
                            NavigationLink { CardDetailView(cardID: card.id) } label: { ownedPocket(entry, card: card, copies: 1) }
                        }
                    } else {
                        Button { missing = entry } label: {
                            ChecklistTile(entry: entry, image: nil, copies: 0, stitch: finish.stitch, reference: entry.exactReference(in: collection))
                        }
                    }
                }
                .buttonStyle(.plain)
                .overlay {
                    if highlightedPocket == entry.number {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.scoutAccent, lineWidth: 2)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .id(entry.number)
                .accessibilityIdentifier("binder.pocket." + entry.number)
                .accessibilityAddTraits(highlightedPocket == entry.number ? .isSelected : [])
            }
        }
        .padding(5)
        .background(Color(white: 0.105), in: RoundedRectangle(cornerRadius: 6))
    }

    private func ownedPocket(_ entry: ChecklistCard, card: OwnedCard, copies: Int) -> some View {
        LocalCardPhoto(name: card.frontFile) { image, _ in
            ChecklistTile(entry: entry, image: image, copies: copies, stitch: finish.stitch,
                          isSpecial: specialIDs.contains(card.id), value: store.dashboardValueCache.collectionQuote(for: card))
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let folded = AnyTransition.modifier(active: FoldedPocketSheet(angle: -86), identity: FoldedPocketSheet(angle: 0))
        return .asymmetric(insertion: forward ? .opacity : folded, removal: forward ? folded : .opacity)
    }

    private func turn(to target: Int, from current: Int, pages: Int) {
        guard (0..<pages).contains(target), target != current else { return }
        forward = target > current
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
            highlightedPocket = nil
            if locating { filteredPage = target } else { savedPage = target }
        }
    }

    private func pageButton(_ icon: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 44, height: 44) }
            .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.3 : 1)
            .accessibilityLabel(label)
    }

    private func collectionHeader(_ collection: CardCollection, owned: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ScoutEyebrow(tr("\(collection.year) · \(collection.brand)"))
            Text(trDisplay(collection.parallel ?? collection.subset)).font(.largeTitle.weight(.bold))
            HStack(alignment: .firstTextBaseline) {
                Text(tr("\(owned)")).font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                Text(trDisplay(collection.checklistComplete ? "von \(collection.cards.count) gesammelt" : "gesammelt")).font(.subheadline).foregroundStyle(Color.scoutMuted)
                Spacer(minLength: 0)
            }.accessibilityElement(children: .combine)
            Text(tr("\(collection.cards.filter { $0.exactReference(in: collection) != nil }.count) von \(collection.cards.count) mit exaktem Referenzfoto"))
                .font(.caption).foregroundStyle(Color.scoutMuted)
            if let example = collection.validReferenceExample {
                NavigationLink { ReferenceComparisonView(reference: example, variantExample: true) } label: {
                    Label(tr("Variantenbeispiel ansehen"), systemImage: "photo.on.rectangle.angled").font(.subheadline.weight(.semibold))
                }.foregroundStyle(Color.scoutAccent)
            }
            if collection.checklistComplete {
                ProgressView(value: Double(owned), total: Double(max(collection.cards.count, 1))).tint(.scoutAccent)
                HStack {
                    Text(trDisplay((Double(owned) / Double(max(collection.cards.count, 1))).formatted(.percent.precision(.fractionLength(0...1))) + " komplett"))
                    Spacer()
                    Text(tr("\(max(collection.cards.count - owned, 0)) fehlen"))
                }.font(.caption.weight(.medium)).foregroundStyle(Color.scoutMuted)
            } else {
                Label(tr("Checkliste noch nicht vollständig"), systemImage: "circle.dotted").font(.caption).foregroundStyle(Color.scoutGold)
            }
        }
    }

    private func missingSheet(_ entry: ChecklistCard, collection: CardCollection) -> some View {
        let isHunting = store.library.hunts.contains { $0.id == collection.id + ":" + entry.number }
        return NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let exact = entry.exactReference(in: collection) {
                        Button { inspectingReference = exact } label: { ReferenceImageView(url: exact.frontURL).frame(height: 300) }.buttonStyle(.plain)
                        if let source = URL(string: exact.sourceURL) { Link(tr("Bildquelle ansehen"), destination: source).font(.caption) }
                    }
                    else { PhotoCard(image: nil, number: entry.number, owned: false).frame(height: 240) }
                    VStack(spacing: 6) {
                        ScoutEyebrow(tr("FEHLT IN DEINEM BINDER"))
                        Text(entry.player).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(tr("#\(entry.number) · \(entry.team)")).font(.subheadline).foregroundStyle(Color.scoutMuted).multilineTextAlignment(.center)
                        Text(tr("\(String(collection.year)) \(collection.name) · \(collection.parallel ?? collection.subset)")).font(.caption).foregroundStyle(Color.scoutMuted).multilineTextAlignment(.center)
                    }
                    Button {
                        store.addHunt(entry, collection: collection)
                        missing = nil
                    } label: { Label(trDisplay(isHunting ? "Schon im Lookout" : "Zum Lookout hinzufügen"), systemImage: isHunting ? "checkmark" : "scope").frame(maxWidth: .infinity) }
                        .buttonStyle(ScoutPrimaryButtonStyle()).disabled(isHunting)
                }.padding(24)
            }.background(Color.scoutCanvas).navigationTitle(tr("Fehlende Karte")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Fertig")) { missing = nil } } }
        }.presentationDetents([.large]).sheet(item: $inspectingReference) { ReferenceComparisonSheet(reference: $0) }
    }
}

private struct BinderPocketCopies: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let collection: CardCollection
    let entry: ChecklistCard

    var body: some View {
        let cards = collection.owned(for: entry.number, in: store.library.collectedCards).sorted {
            ($0.createdAt, $0.id) > ($1.createdAt, $1.id)
        }
        List(Array(cards.enumerated()), id: \.element.id) { index, card in
            HStack {
                NavigationLink { CardDetailView(cardID: card.id) } label: {
                    HStack(spacing: 12) {
                        OwnedPhoto(name: card.frontFile, number: entry.number).frame(width: 48, height: 66)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Exemplar \(index + 1)")).font(.headline)
                            if let scanned = ISO8601DateFormatter().date(from: card.createdAt) {
                                Text(verbatim: scanned.scoutFormatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Color.scoutMuted)
                            }
                        }
                    }
                }
                CardRemovalButton(card: card).buttonStyle(.borderless)
            }
        }
        .navigationTitle(entry.player)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: cards.isEmpty) { _, empty in if empty { dismiss() } }
    }
}

struct ChecklistTile: View {
    @Environment(\.horizontalSizeClass) private var widthClass
    @ScaledMetric(relativeTo: .body) private var photoHeight: CGFloat = 152
    let entry: ChecklistCard
    let image: UIImage?
    let copies: Int
    let stitch: Color
    var isSpecial = false
    var value: BinderQuote? = nil
    var reference: CardReferenceImage? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let reference, copies == 0 {
                    ReferenceImageView(url: reference.frontURL).aspectRatio(5.0 / 7.0, contentMode: .fit)
                } else if copies == 0 {
                    EmptyBinderPocket(number: entry.number, stitch: stitch)
                } else {
                    PhotoCard(image: image, number: entry.number, owned: true)
                }
            }
            .aspectRatio(5.0 / 7.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: widthClass == .regular ? 220 : min(photoHeight, 200))
            .overlay(alignment: .topLeading) {
                if isSpecial {
                    Image(systemName: "sparkles").font(.caption.bold()).foregroundStyle(.yellow)
                        .padding(5).background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 5))
                        .padding(4).accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if copies > 0 {
                    Group {
                        if copies == 1 { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                        else { Text(tr("×\(copies)")).font(.caption.bold()) }
                    }.foregroundStyle(Color.white).frame(minWidth: 27, minHeight: 27).background(Color.scoutButtonFill, in: Capsule()).padding(8)
                }
            }
            Text(entry.player).font(.subheadline.weight(.semibold)).foregroundStyle(copies > 0 ? Color.white : Color(white: 0.78)).lineLimit(2)
            Text(tr("#\(entry.number)\(entry.rookie ? " · RC" : "")\(trDisplay(copies == 0 ? " · Fehlt" : ""))")).font(.caption).foregroundStyle(Color.scoutMuted)
            if let value {
                Text(value.valueLabel).font(.subheadline.weight(.bold)).foregroundStyle(Color.scoutAccent)
                Text(trDisplay(value.basisLabel)).font(.caption2).foregroundStyle(Color.scoutMuted).lineLimit(2)
            }
        }.padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LinearGradient(colors: [Color(white: 0.21), Color(white: 0.115), Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(LinearGradient(colors: [.white.opacity(0.58), .white.opacity(0.09), .white.opacity(0.31)], startPoint: .topLeading, endPoint: .bottomTrailing)) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([entry.player, "#" + entry.number, copies > 0 ? tr("\(copies) vorhanden") : tr("Fehlt"), isSpecial ? tr("Besondere Karte") : nil, value.map { $0.valueLabel }, value.map { trDisplay($0.basisLabel) }].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(trDisplay(copies > 1 ? "Exemplare ansehen" : copies == 1 ? "Kartendetails öffnen" : "Karte im Lookout vormerken"))
    }
}

struct CardDetailView: View {
    @Environment(AppStore.self) private var store
    let cardID: String
    var body: some View {
        if store.library.cards.first(where: { $0.id == cardID })?.isScanDraft == true { ScanMatchView(cardID: cardID) }
        else { CollectedCardDetailView(cardID: cardID) }
    }
}

private struct CollectedCardDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let cardID: String
    @State private var back = false
    @State private var correcting = false
    @State private var reviewingIdentity = false
    @State private var retaking = false
    @State private var photoExpanded = false
    @State private var editingMetadata = false
    @State private var editingPrice = false
    var body: some View {
        if let card = store.library.cards.first(where: { $0.id == cardID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CardDisplayCase(card: card, back: $back, zoom: { photoExpanded = true }, retake: { retaking = true })
                    CardValueStrip(card: card, pricingPaused: !store.connected || card.state == "failed", edit: { editingPrice = true })
                    if card.hasDisplayableAnalysis, let analysis = card.analysis {
                        if !card.hasCurrentAnalysis { statusPanel(card, previous: true) }
                        FinishFollowUp(card: card)
                        if card.automaticScan != true && card.analysis?.finishPolicy == nil {
                            CardVariantPicker(card: card)
                        } else if !(card.analysis?.cardSightVariants ?? []).isEmpty {
                            DisclosureGroup(tr("Edit finish")) { CardVariantPicker(card: card) }
                        }
                        ScoutPanel(padding: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                if analysis.identityConfirmed != true && card.automaticScan != true && analysis.finishPolicy == nil {
                                    Button { reviewingIdentity = true } label: { action("Zuordnung prüfen", "rectangle.and.pencil.and.ellipsis") }
                                    Divider()
                                }
                                if let set = store.library.collections.first(where: { $0.id == analysis.collectionID }) {
                                    if let exact = set.cards.first(where: { $0.number == analysis.cardNumber && $0.player == analysis.player })?.exactReference(in: set) {
                                        NavigationLink { ReferenceComparisonView(reference: exact, cardID: card.id) } label: { action("Mit Referenzfoto vergleichen", "photo.on.rectangle.angled") }
                                        Divider()
                                    } else if let example = set.validReferenceExample {
                                        NavigationLink { ReferenceComparisonView(reference: example, cardID: card.id, variantExample: true) } label: { action("Variantenbeispiel vergleichen", "photo.on.rectangle.angled") }
                                        Divider()
                                    }
                                }
                                collectible(card)
                            }
                        }.buttonStyle(.plain)
                        AnalysisCardsView(analysis: analysis, provisional: card.hasProvisionalAnalysis == true, assessmentCleared: card.manualAssignment == true && analysis.insights == nil)
                    } else {
                        statusPanel(card, previous: false)
                        ScoutPanel(padding: 0) { collectible(card) }.buttonStyle(.plain)
                    }
                    ScoutPanel(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Button { editingMetadata = true } label: { action("Aufbewahrung & Notizen", "archivebox") }
                            if let location = card.storageLocation, !location.isEmpty { Text(verbatim: location).font(.subheadline).padding([.horizontal, .bottom], 14) }
                            if let notes = card.notes, !notes.isEmpty { Text(verbatim: notes).font(.subheadline).foregroundStyle(Color.scoutMuted).padding([.horizontal, .bottom], 14) }
                            if card.hasDisplayableAnalysis {
                                Divider()
                                Button { correcting = true } label: { action("Zuordnung korrigieren", "pencil") }
                                Divider()
                                Button { store.reanalyze(card.id) } label: { action("Neu bewerten", "arrow.clockwise", disclosure: false) }.disabled(card.isAwaitingAnalysis)
                            }
                        }
                    }.buttonStyle(.plain)
                }.frame(maxWidth: 560).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
            }.background(Color.scoutCanvas).navigationTitle(tr("Deine Karte")).navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .tabBar)
                .task(id: card.jobID) { await store.loadCardPrices(card.id) }
                .sheet(isPresented: $correcting) { CorrectCardView(cardID: card.id) }
                .sheet(isPresented: $reviewingIdentity) { IdentityReviewView(cardID: card.id) }
                .sheet(isPresented: $retaking) { AddCardView(cardID: card.id).tint(.scoutAccent) }
                .sheet(isPresented: $editingPrice) { PersonalPriceEditorView(cardID: card.id, price: card.personalPrice) }
                .sheet(isPresented: $editingMetadata) { CardMetadataView(cardID: card.id) }
                .fullScreenCover(isPresented: $photoExpanded) { CardPhotoViewer(cardID: card.id, initialBack: back, useCutout: true) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { store.toggleFavorite(card.id) } label: { Image(systemName: card.isFavorite == true ? "star.fill" : "star").frame(width: 44, height: 44) }
                            .accessibilityLabel(trDisplay(card.isFavorite == true ? "Favorit entfernen" : "Als Favorit merken"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        CardRemovalButton(card: card) { dismiss() }
                    }
                }
        } else {
            ScoutEmptyState(symbol: "rectangle.portrait.slash", title: tr("Karte nicht verfügbar.")).background(Color.scoutCanvas)
        }
    }

    private func collectible(_ card: OwnedCard) -> some View {
        Button { store.toggleCollectible(card.id) } label: {
            action(card.isCollectible == true ? "In deinen Collectibles" : "Zu Collectibles hinzufügen",
                   card.isCollectible == true ? "trophy.fill" : "trophy", disclosure: false)
        }.accessibilityAddTraits(card.isCollectible == true ? .isSelected : [])
    }

    private func action(_ title: String, _ symbol: String, disclosure: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.scoutAccent).frame(width: 24)
            Text(trDisplay(title)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.scoutInk).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if disclosure { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.scoutMuted) }
        }.padding(.horizontal, 14).padding(.vertical, 6).frame(minHeight: 48).contentShape(Rectangle())
    }

    private func statusPanel(_ card: OwnedCard, previous: Bool) -> some View {
        ScoutPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if card.isAwaitingAnalysis { ProgressView().tint(.scoutAccent) }
                    else { Image(systemName: "exclamationmark.circle").foregroundStyle(Color.scoutGold) }
                    Text(trDisplay(collectorStatus(card))).font(.headline)
                }
                if previous && card.hasProvisionalAnalysis != true { Text(tr("Bisherige Bewertung")).font(.caption).foregroundStyle(Color.scoutMuted) }
                if card.state == "queued" && !store.connected {
                    Text(tr("Gespeichert. Die Analyse startet, sobald dein Mac oder Server verbunden ist.")).font(.subheadline).foregroundStyle(Color.scoutMuted)
                    Button(tr("Verbindung öffnen")) { store.openConnectionSettings() }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
                if let error = card.error { Text(trDisplay(error)).font(.subheadline).foregroundStyle(Color.scoutMuted) }
                if card.state == "unidentified" {
                    Text(tr("Ohne Zuordnung gespeichert. Ergänze Fotos oder lass nach der Karte suchen.")).font(.subheadline)
                    Button(tr("Karte erkennen lassen")) { store.reanalyze(card.id) }.buttonStyle(ScoutPrimaryButtonStyle())
                }
                if card.state == "failed" {
                    Button(tr("Erneut analysieren")) { store.retry(card.id) }.buttonStyle(ScoutPrimaryButtonStyle())
                }
            }
        }
    }
}

struct CorrectCardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let cardID: String
    @State private var setID = ""
    @State private var number = ""
    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Kartenset & Nummer")) {
                    Text(tr("Nur speichern, wenn Jahrgang, Set, Variante und Kartennummer sicher übereinstimmen. Diese Auswahl bestätigt die Identität."))
                        .font(.footnote).foregroundStyle(Color.scoutMuted)
                    Picker(tr("Kartenset"), selection: $setID) {
                        Text(tr("Wählen")).tag("")
                        ForEach(store.library.collections) { Text(tr("\(String($0.year)) \($0.name) · \($0.parallel ?? $0.subset)")).tag($0.id) }
                    }
                    TextField(tr("Kartennummer"), text: $number).textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                if let set = store.library.collections.first(where: { $0.id == setID }), let entry = set.cards.first(where: { $0.number.localizedCaseInsensitiveCompare(number.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) {
                    Section(tr("Deine Zuordnung")) {
                        Text(entry.player).font(.headline)
                        Text(trDisplay(entry.team)).foregroundStyle(Color.scoutMuted)
                        Button(tr("Zuordnung speichern")) {
                            if store.correctAssignment(cardID, collectionID: set.id, number: entry.number) { dismiss() }
                        }
                    }
                } else if !setID.isEmpty && !number.isEmpty {
                    Section { Label(tr("Diese Nummer fehlt in der aktuellen Checkliste."), systemImage: "magnifyingglass").font(.subheadline).foregroundStyle(Color.scoutMuted) }
                }
            }
            .scrollContentBackground(.hidden).background(Color.scoutCanvas)
            .navigationTitle(tr("Zuordnung")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Schließen")) { dismiss() } } }
            .onAppear {
                if let a = store.library.cards.first(where: { $0.id == cardID })?.analysis { setID = a.collectionID ?? ""; number = a.cardNumber ?? "" }
            }
        }
    }
}

struct HuntListView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    private var hunting: [HuntCard] { matching.filter { $0.status != "found" } }
    private var found: [HuntCard] { matching.filter { $0.status == "found" } }
    private var matching: [HuntCard] {
        store.library.hunts.filter { search.isEmpty || "\($0.label) \($0.productName) \($0.player ?? "")".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {

                    HStack(spacing: 12) {
                        ScoutChip(tr("\(store.library.hunts.filter { $0.status != "found" }.count) gesucht"), systemImage: "scope", selected: true)
                        ScoutChip(tr("\(store.library.hunts.filter { $0.status == "found" }.count) gefunden"), systemImage: "checkmark")
                    }
                }
                if store.library.hunts.isEmpty {
                    ScoutEmptyState(symbol: "scope", title: tr("Keine Wunschkarten"), message: tr(""))
                    NavigationLink { HotListView() } label: { Label(tr("Rangliste entdecken"), systemImage: "arrow.up.right").frame(maxWidth: .infinity) }.buttonStyle(ScoutPrimaryButtonStyle())
                } else if matching.isEmpty {
                    ScoutEmptyState(symbol: "magnifyingglass", title: tr("Kein Treffer."), message: tr("Suche nach Spieler oder Sammlung."))
                } else {
                    if !hunting.isEmpty { huntSection("Auf der Suche", cards: hunting) }
                    if !found.isEmpty { huntSection("Gefunden", cards: found) }
                }
            }.padding(20).padding(.bottom, 16)
        }.background(Color.scoutCanvas).navigationTitle(tr("Lookout")).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: tr("Spieler oder Sammlung"))
    }
    private func huntSection(_ title: String, cards: [HuntCard]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ScoutSectionHeader(trDisplay(title), trailing: tr("\(cards.count)"))
            LazyVStack(spacing: 12) {
                ForEach(cards) { hunt in
                    ScoutPanel(padding: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            Group {
                                if let url = hunt.imageURL { CachedPhoto(url: url) }
                                else { PhotoCard(image: nil, number: "", owned: true) }
                            }.frame(width: 68, height: 95)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(hunt.label).font(.subheadline.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                                Text(hunt.productName).font(.caption).foregroundStyle(Color.scoutMuted)
                                if let source = hunt.sourceURL, let url = URL(string: source) {
                                    Link(destination: url) { Label(tr("Quelle"), systemImage: "arrow.up.right").font(.caption.weight(.medium)).frame(minHeight: 44) }.foregroundStyle(Color.scoutAccent)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                store.commit { library in
                                    if let index = library.hunts.firstIndex(where: { $0.id == hunt.id }) { library.hunts[index].status = hunt.status == "found" ? "hunting" : "found" }
                                }
                            } label: {
                                Image(systemName: hunt.status == "found" ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(hunt.status == "found" ? Color.scoutAccent : Color.scoutMuted)
                                    .frame(width: 44, height: 44)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(trDisplay(hunt.status == "found" ? "\(hunt.label) wieder als gesucht markieren" : "\(hunt.label) als gefunden markieren"))
                        }
                    }
                }
            }
        }
    }
}
