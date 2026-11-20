import SwiftUI
import CardScoutCore

struct ClubhouseHomeView: View {
    @Environment(AppStore.self) private var store
    @State private var editingPurchase: CardPurchase?
    @State private var selectedCurrency = ""
    var body: some View {
        let stats = store.dashboardStatistics
        let currencies = CardPurchase.currencies
        let currency = currencies.contains(selectedCurrency) ? selectedCurrency : preferredBurnCurrency(stats)
        let burn = store.burnCount(statistics: stats, currency: currency)
        VStack(spacing: 0) {
            CollectorHeader {
                ClubhouseWordmark()
            } actions: {
                Button { store.selectedTab = 3 } label: { CollectorToolIcon(name: "viewfinder") }
                    .accessibilityLabel(tr("Karte scannen"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    #if DEBUG
                    if PreviewData.enabled { Text(tr("DESIGN-VORSCHAU · DEMODATEN")).font(.caption2.monospaced()).foregroundStyle(Color.scoutMuted) }
                    #endif
                    ClubhouseDisplayCase(cards: store.library.collectibles)
                    BurnCountCard(burn: burn, addPurchase: {
                        editingPurchase = newCardPurchase(currency: currency)
                    }, changeCurrency: { selectedCurrency = $0 })
                }.padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 28)
            }.refreshable { await store.sync() }
        }.background(Color.scoutCanvas).toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editingPurchase) { PurchaseEditorView(purchase: $0) }
    }

}

private struct ClubhouseWordmark: View {
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        var prefix = AttributedString("T4L")
        prefix.foregroundColor = .scoutGold
        return Text(prefix + AttributedString(" BURN COUNT"))
            .font(.custom("T4LEndZone-BlackItalic", size: 31, relativeTo: .title2))
            .lineLimit(typeSize > .large ? nil : 1)
            .minimumScaleFactor(typeSize > .large ? 1 : 0.6)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("clubhouse.wordmark")
    }
}

func preferredBurnCurrency(_ stats: CollectionStatistics) -> String {
    let currencies = Array(Set(stats.spendingCurrencies + stats.values.filter { !$0.isUnpricedBase }.map(\.currency) + stats.personalValues.map(\.currency))).sorted()
    return currencies.first(where: { $0 == "EUR" }) ?? currencies.first(where: CardPurchase.currencies.contains) ?? "EUR"
}

@MainActor func newCardPurchase(currency: String) -> CardPurchase {
    CardPurchase(title: tr("Kartenkauf"), category: .pack, currency: currency, purchasedOn: PurchaseEditorView.dateString(Date()))
}

struct BurnCountCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let burn: BurnCount
    let addPurchase: () -> Void
    var showDetailLink = true
    var changeCurrency: ((String) -> Void)?
    @State private var editingValue = false
    @State private var showingBalance = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if showDetailLink {
                    Button { showingBalance = true } label: {
                        HStack(spacing: 7) {
                            Text(trDisplay(burn.isIndicative ? "Burn Count · ca." : "Burn Count"))
                            Image(systemName: "arrow.up.right").font(.caption)
                        }.font(.headline.bold()).frame(minHeight: 44)
                    }.accessibilityLabel(tr("Burn Count und Ausgaben im Detail"))
                        .accessibilityIdentifier("clubhouse.balance")
                } else {
                    Text(trDisplay(burn.isIndicative ? "Burn Count · ca." : "Burn Count")).font(.headline.bold())
                }
                Spacer()
                if let changeCurrency {
                    Menu {
                        ForEach(CardPurchase.currencies, id: \.self) { value in Button(trDisplay(value)) { changeCurrency(value) } }
                    } label: {
                        HStack(spacing: 4) { Text(verbatim: burn.currency); Image(systemName: "chevron.down") }
                            .font(.caption.bold()).frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(tr("Burn Count Währung wählen"))
                }
            }
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if let low = burn.burnLowCents, let high = burn.burnHighCents {
                            AnimatedMoneyText(low: low, high: high, currency: burn.currency, color: resultColor, showsDirection: false)
                        } else { Text(trDisplay("—")) }
                    }.font(.system(.largeTitle, design: .rounded, weight: resultWeight)).foregroundStyle(resultColor)
                        .lineLimit(1).minimumScaleFactor(0.48)
                        .accessibilityLabel(tr("Burn Count: \(headline). \(resultDescription)"))
                    Text(tr("Bezahlt − Wert")).font(.caption).foregroundStyle(.white.opacity(0.75))
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize { BurnMascot(mood: burn.mood).frame(width: 86, height: 78) }
            }
            Divider().overlay(.white.opacity(0.25))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { paid; estimate; Spacer(minLength: 0); purchase }
                VStack(alignment: .leading, spacing: 7) { HStack { paid; Spacer(); estimate }; purchase }
            }
            if !showDetailLink {
                if let rate = store.burnExchangeRate {
                    Text(tr("EZB-Referenzkurs · \(rate.publishedOn)")).font(.caption2).foregroundStyle(.white.opacity(0.75))
                } else if store.burnExchangeRateUnavailable {
                    Text(tr("Wechselkurs nicht verfügbar")).font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
        }.padding(.horizontal, 17).padding(.vertical, 9).foregroundStyle(.white)
            .background { CardArena(color: Color(red: 0.11, green: 0.22, blue: 0.16)) }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.scoutEditorialGold.opacity(0.32)).allowsHitTesting(false) }
            .sheet(isPresented: $editingValue) { ManualBurnValueEditor(currency: burn.currency) }
            .sheet(isPresented: $showingBalance) {
                NavigationStack {
                    BurnCountDetailView(initialCurrency: burn.currency).toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button(tr("Schließen")) { showingBalance = false } }
                    }
                }.presentationDragIndicator(.visible)
            }
            .task(id: scenePhase) { if scenePhase == .active { store.refreshBurnExchangeRate() } }
    }
    private var paid: some View { burnMetric(tr("Bezahlt"), text: burn.spentCents.map(money) ?? "—") }
    private var estimate: some View {
        Button { editingValue = true } label: {
            HStack(spacing: 4) {
                burnMetric(trDisplay(burn.isManualValue ? "Eigene Schätzung" : "Geschätzter Kartenwert"), text: valueLabel)
                Image(systemName: "pencil").font(.caption2)
            }.frame(minHeight: 44)
        }.buttonStyle(.plain).disabled(burn.totalCards == 0)
            .accessibilityLabel(tr("Kartenwert bearbeiten")).accessibilityIdentifier("clubhouse.estimate")
    }
    private var purchase: some View {
        Button(action: addPurchase) {
            Label(tr("Kauf eintragen"), systemImage: "plus").font(.caption.bold()).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(.mint).accessibilityIdentifier("clubhouse.purchase")
    }
    private var resultColor: Color {
        switch burn.performance {
        case .excellent: Color(red: 0.38, green: 0.95, blue: 0.65)
        case .ahead: Color(red: 0.55, green: 0.88, blue: 0.68)
        case .behind: Color(red: 1, green: 0.70, blue: 0.36)
        case .heavyBurn: Color(red: 1, green: 0.48, blue: 0.43)
        case .breakEven, .uncertain: .scoutEditorialGold
        case .unknown: .white.opacity(0.65)
        }
    }
    private var resultWeight: Font.Weight {
        switch burn.performance {
        case .excellent, .heavyBurn: .black
        default: .bold
        }
    }
    private var resultDescription: String {
        switch burn.performance {
        case .excellent: tr("Stark im Plus")
        case .ahead: tr("Im Plus")
        case .behind: tr("Im Minus")
        case .heavyBurn: tr("Hoher Burn")
        case .breakEven: tr("Ausgeglichen")
        case .uncertain: tr("Gewinn oder Verlust noch offen")
        case .unknown: tr("Angaben fehlen")
        }
    }
    private var headline: String {
        guard let high = burn.burnHighCents, let low = burn.burnLowCents else { return "—" }
        if low == 0 && high == 0 { return money(0) }
        return low == high ? money(high) : "\(money(low)) – \(money(high))"
    }
    private var valueLabel: String {
        guard let low = burn.valueLowCents, let high = burn.valueHighCents else { return "—" }
        return low == high ? money(low) : "\(money(low))–\(money(high))"
    }
    private func burnMetric(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(trDisplay(title)).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            Text(trDisplay(text)).font(.subheadline.bold()).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func money(_ cents: Int) -> String { CollectionCardValue.money(cents, currency: burn.currency) }
}

struct BurnMascot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let mood: BurnMood
    @State private var tapped = false
    var body: some View {
        Group {
            if reduceMotion || scenePhase != .active { character }
            else {
                PhaseAnimator([false, true]) { floating in
                    character.offset(y: floating ? -4 : 3).rotationEffect(.degrees(floating ? 2 : -2))
                } animation: { _ in .easeInOut(duration: 2.2) }
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: mood.rawValue)
            .scaleEffect(tapped && !reduceMotion ? 1.12 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.45), value: tapped)
            .onTapGesture {
                tapped = true
                Task { try? await Task.sleep(for: .milliseconds(200)); tapped = false }
            }
            .accessibilityLabel(trDisplay(mood == .proud ? "Scout freut sich" : mood == .roasted ? "Scout schaut verlegen" : "Scout zählt nach"))
    }
    private var character: some View {
        Image("BurnMascot-\(mood.rawValue)").resizable().scaledToFit().id(mood.rawValue).transition(.opacity)
    }
}

struct BurnCountDetailView: View {
    @Environment(AppStore.self) private var store
    let initialCurrency: String
    @State private var selectedCurrency = ""
    @State private var editingPurchase: CardPurchase?
    @State private var editingValue = false
    var body: some View {
        let stats = store.dashboardStatistics
        let currencies = CardPurchase.currencies
        let currency = currencies.contains(selectedCurrency) ? selectedCurrency : initialCurrency
        let burn = store.burnCount(statistics: stats, currency: currency)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if currencies.count > 1 {
                    Picker(tr("Burn Count Währung wählen"), selection: Binding(get: { currency }, set: { selectedCurrency = $0 })) {
                        ForEach(currencies, id: \.self) { Text(trDisplay($0)).tag($0) }
                    }.pickerStyle(.segmented)
                }
                BurnCountCard(burn: burn, addPurchase: { editingPurchase = newCardPurchase(currency: currency) }, showDetailLink: false)
                Button { editingValue = true } label: {
                    Label(trDisplay(store.latestManualBurnValue == nil ? "Wert eintragen" : "Wert bearbeiten"), systemImage: "pencil.line")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(ScoutPrimaryButtonStyle()).disabled(store.library.collectedCards.isEmpty)
                if let value = store.latestManualBurnValue {
                    Text(tr("Stand: \(value.recordedAt.scoutFormatted(date: .abbreviated, time: .omitted)) · bei Bestandsänderung erneut bestätigen"))
                        .font(.caption).foregroundStyle(Color.scoutMuted)
                }
                Text(tr("So zählt der Burn Count")).font(.title3.bold())
                Text(tr("Karten, Packs und Boxen minus geschätzter Kartenwert. Versand und Gebühren inklusive; Zubehör ausgeschlossen."))
                    .font(.subheadline).foregroundStyle(Color.scoutMuted)
                Text(tr("Positiv: verbrannt. Negativ: Kartenwert über Ausgaben. Ohne vollständigen Kartenwert bleibt die Bilanz offen; du kannst eine eigene Schätzung eintragen."))
                    .font(.caption).foregroundStyle(Color.scoutMuted)
                NavigationLink { PurchaseLedgerView() } label: { Label(tr("Kaufbuch"), systemImage: "book.closed") }.buttonStyle(ScoutSecondaryButtonStyle())
                NavigationLink { InsightPortfolioDetail(section: .value, currency: currency) } label: { Label(tr("Wertentwicklung & Top-Karten"), systemImage: "chart.xyaxis.line") }.buttonStyle(ScoutSecondaryButtonStyle())
            }.padding(20)
        }.background(Color.scoutCanvas).navigationTitle(tr("Burn Count")).navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingPurchase) { PurchaseEditorView(purchase: $0) }
            .sheet(isPresented: $editingValue) { ManualBurnValueEditor(currency: currency) }
    }
}

struct ShowcasePickerView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    var body: some View {
        let cards = store.library.collectedCards.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
        List {
            if cards.isEmpty { Text(tr("Scanne zuerst eine Karte für deine Sammlung.")).foregroundStyle(Color.scoutMuted) }
            ForEach(cards) { card in
                Button { store.toggleCollectible(card.id) } label: {
                    HStack(spacing: 14) {
                        OwnedPhoto(name: card.frontFile, maxPixel: 300, number: "").frame(width: 45, height: 64)
                        Text(cardTitle(card)).foregroundStyle(Color.scoutInk)
                        Spacer()
                        Image(systemName: card.isCollectible == true ? "trophy.fill" : "plus.circle").foregroundStyle(Color.scoutGold)
                    }
                }.accessibilityLabel(tr("\(card.title), \(trDisplay(card.isCollectible == true ? "aus Collectibles entfernen" : "zu Collectibles hinzufügen"))"))
            }
        }.toolbar(.visible, for: .navigationBar).navigationTitle(tr("Deine Lieblingsstücke")).searchable(text: $search, prompt: tr("Spieler suchen"))
    }
}


struct ManualBurnValueEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let currency: String
    @State private var amount = ""
    private var cents: Int? {
        let clean = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["0", "0,00", "0.00"].contains(clean) { return 0 }
        return CardPurchase.parseAmount(clean)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr("Dein geschätzter Gesamtwert · \(currency)")).font(.headline)
                    HStack {
                        TextField(tr("0,00"), text: $amount).keyboardType(.decimalPad)
                            .font(.system(.largeTitle, design: .monospaced, weight: .bold)).minimumScaleFactor(0.5)
                            .accessibilityLabel(tr("Eigener Kartenwert"))
                        Text(verbatim: currency).font(.headline.monospaced())
                    }.padding(18).foregroundStyle(.mint)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.mint.opacity(0.5)) }
                    if let cents, let spent = store.burnCount(statistics: store.dashboardStatistics, currency: currency).spentCents {
                        HStack {
                            Text(tr("Burn Count")).font(.subheadline)
                            Spacer()
                            Text(verbatim: CollectionCardValue.money(spent - cents, currency: currency)).font(.headline.monospacedDigit())
                        }
                    }
                    Button(tr("Schätzung speichern")) {
                        if let cents, store.saveManualBurnValue(cents, currency: currency) { dismiss() }
                    }.buttonStyle(ScoutPrimaryButtonStyle()).disabled(cents == nil)
                    if store.latestManualBurnValue != nil {
                        Button(tr("Wieder recherchierte Preise verwenden")) {
                            if store.saveManualBurnValue(nil, currency: currency) { dismiss() }
                        }.font(.subheadline)
                    }
                }.padding(22)
            }.frame(maxWidth: .infinity).foregroundStyle(.white)
                .background(LinearGradient(colors: [Color(red: 0.07, green: 0.15, blue: 0.12), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .navigationTitle(tr("Deine Schätzung")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Abbrechen")) { dismiss() } } }
                .onAppear {
                    let burn = store.burnCount(statistics: store.dashboardStatistics, currency: currency)
                    if burn.isManualValue, let cents = burn.valueLowCents {
                        amount = decimalInput(cents)
                    }
                }
        }.preferredColorScheme(.dark).presentationDragIndicator(.visible)
    }
}


/// Interpolates the actual amounts, so a large change counts through intermediate values.
/// The saved amount is the starting point; opening a screen never resets it to zero.
struct AnimatedMoneyText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let low: Int
    let high: Int
    let currency: String
    var color: Color = .white
    var showsDirection = true
    @State private var direction = 0
    var body: some View {
        CountingMoneyText(low: Double(low), high: Double(high), currency: currency)
            .monospacedDigit()
            .foregroundStyle(showsDirection && direction != 0 ? (direction > 0 ? Color.green : Color.orange) : color)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1), value: low)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1), value: high)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: direction)
            .onChange(of: low) { old, new in
                direction = reduceMotion || !showsDirection ? 0 : (new > old ? 1 : -1)
            }
            .onChange(of: currency) { direction = 0 }
            .task(id: low) {
                do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
                direction = 0
            }
            .accessibilityLabel(low == high ? CollectionCardValue.money(low, currency: currency) :
                "\(CollectionCardValue.money(low, currency: currency)) – \(CollectionCardValue.money(high, currency: currency))")
            .id(currency)
    }
}

private struct CountingMoneyText: View, Animatable {
    var low: Double
    var high: Double
    let currency: String
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(low, high) }
        set { low = newValue.first; high = newValue.second }
    }
    var body: some View {
        let first = CollectionCardValue.money(Int(low.rounded()), currency: currency)
        let last = CollectionCardValue.money(Int(high.rounded()), currency: currency)
        Text(low.rounded() == high.rounded() ? first : "\(first) – \(last)")
    }
}
