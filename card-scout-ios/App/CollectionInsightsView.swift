import CardScoutCore
import SwiftUI

struct CollectionStatisticsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedCurrency = ""
    @State private var review: ReviewSelection?
    private struct ReviewSelection: Identifiable { let id = UUID(); let cards: [String] }

    var body: some View {
        let library = store.library
        let stats = store.dashboardStatistics
        let history = library.portfolioHistory ?? []
        let value = InsightValuation(statistics: stats, history: history, selected: selectedCurrency)
        let code = value.currency
        let pending = library.cards.filter { !$0.scanChecks.isEmpty }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        let closest = library.closestChecklist
        let change = library.portfolioChange(currency: code, cachedValues: store.dashboardValueCache.portfolioValues(in: library))
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                valueHero(value, stats: stats)
                balance(store.burnCount(statistics: stats, currency: code), priced: stats.pricedCards)
                if !pending.isEmpty || closest != nil {
                    VStack(alignment: .leading, spacing: 9) {
                        sectionTitle(tr("Next up"))
                        if !pending.isEmpty {
                            Button { review = ReviewSelection(cards: pending.map(\.id)) } label: {
                                HStack(spacing: 12) {
                                    icon("viewfinder", tint: .scoutGold)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tr("Review scans")).font(.headline)
                                        Text(reviewSummary(pending)).font(.caption).foregroundStyle(Color.scoutMuted)
                                    }
                                    Spacer()
                                    Text(verbatim: String(pending.count)).font(.headline.monospacedDigit()).foregroundStyle(Color.scoutGold)
                                    chevron
                                }.padding(13).insightSurface()
                            }.buttonStyle(.plain).accessibilityIdentifier("insights.review")
                        }
                        if let milestone = closest, let binder = library.binders.first(where: { $0.collections.contains { $0.id == milestone.checklist.id } }) {
                            checklist(milestone, binder: binder)
                        }
                    }
                }
                movement(change: change, history: history, currency: code)
                VStack(alignment: .leading, spacing: 9) {
                    sectionTitle(tr("Entdecken"))
                    VStack(spacing: 0) {
                        NavigationLink { InsightPortfolioDetail(section: .moves, currency: code) } label: { door(tr("Empfehlungen"), "rectangle.stack.badge.person.crop") }
                        Divider()
                        NavigationLink { HotListView() } label: { door(tr("Chase-Ranglisten"), "sparkles") }
                        Divider()
                        NavigationLink { HuntListView() } label: { door(tr("Dein Lookout"), "scope") }
                    }.insightSurface().buttonStyle(.plain)
                }
            }.frame(maxWidth: 590).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 26)
                .frame(maxWidth: .infinity)
        }.background(Color.scoutCanvas).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                CollectorHeader {
                    CollectorHeading(text: tr("Insights"))
                } actions: {
                    NavigationLink { PurchaseLedgerView() } label: { CollectorToolIcon(name: "book.closed") }
                        .accessibilityLabel(tr("Kaufbuch")).accessibilityIdentifier("insights.ledger")
                }
            }
            .sheet(item: $review) { item in ScanReviewQueue(ids: item.cards) }
    }

    private func valueHero(_ value: InsightValuation, stats: CollectionStatistics) -> some View {
        let featured = value.ranking.first.flatMap { first in store.library.cards.first { $0.id == first.cardID } }
        let fallback = featured == nil ? store.library.collectedCards.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } : nil
        let card = featured ?? fallback
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(trDisplay(value.saved == nil || stats.totalCards == 0 ? "Geschätzter Kartenwert" : "LETZTER ERFASSTER WERT"), systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(StudioStyle.mint)
                Spacer(minLength: 6)
                if value.currencies.count > 1 {
                    Menu {
                        Picker(tr("Währung · ohne Umrechnung"), selection: Binding(get: { value.currency }, set: { selectedCurrency = $0 })) {
                            ForEach(value.currencies, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 5) { Text(verbatim: value.currency); Image(systemName: "chevron.down") }
                            .font(.caption.monospaced().bold()).padding(.horizontal, 10).frame(minHeight: 44)
                    }.accessibilityLabel(tr("Währung · ohne Umrechnung")).accessibilityValue(value.currency).accessibilityIdentifier("insights.currency")
                } else if value.lowCents != nil {
                    Text(verbatim: value.currency).font(.caption.monospaced().bold()).frame(minHeight: 44)
                }
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            layout {
                VStack(alignment: .leading, spacing: 7) {
                    if stats.totalCards > 0, let low = value.lowCents, let high = value.highCents {
                        AnimatedMoneyText(low: low, high: high, currency: value.currency)
                            .font(.system(.largeTitle, weight: .black).width(.condensed)).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                        if let saved = value.saved {
                            Text(tr("Stand \(saved.observedAt.scoutFormatted(date: .abbreviated, time: .omitted)) · \(saved.values(currency: value.currency).filter { $0.comparisonKey != "unpriced-base" }.count) Karten"))
                                .font(.caption).foregroundStyle(StudioStyle.muted)
                        } else {
                            Text(tr("\(value.ranking.count) of \(stats.totalCards) cards valued in \(value.currency)"))
                                .font(.subheadline).foregroundStyle(StudioStyle.muted)
                        }
                    } else if stats.totalCards == 0 {
                        Text(tr("No collected cards yet")).font(.title2.bold())
                        Button { store.selectedTab = 3 } label: { Label(tr("Scan a card"), systemImage: "viewfinder").font(.subheadline.bold()).frame(minHeight: 44) }
                            .foregroundStyle(StudioStyle.mint)
                    } else {
                        Text(tr("Wert noch offen")).font(.system(.title, weight: .bold))
                        Text(tr("\(stats.totalCards) Karten")).font(.subheadline).foregroundStyle(StudioStyle.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let card {
                    NavigationLink { CardDetailView(cardID: card.id) } label: {
                        ShowcaseDeckSurface(card: card, back: false).frame(width: 85, height: 116)
                            .padding(4).background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.42)) }
                            .rotationEffect(.degrees(5)).shadow(color: .black.opacity(0.5), radius: 6, y: 4)
                            .padding(.horizontal, 5)
                    }.buttonStyle(.plain).accessibilityLabel(cardTitle(card))
                }
            }.padding(.vertical, 10)
            if let card {
                Divider().overlay(.white.opacity(0.26)).padding(.top, 6)
                NavigationLink { CardDetailView(cardID: card.id) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: featured == nil ? "rectangle.portrait" : "trophy.fill").foregroundStyle(Color.scoutEditorialGold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trDisplay(featured == nil ? "Latest card" : "Top card")).font(.caption).foregroundStyle(StudioStyle.muted)
                            Text(verbatim: cardTitle(card)).font(.headline)
                        }
                        Spacer(minLength: 4)
                        if featured != nil, let first = value.ranking.first { Text(verbatim: first.label).font(.subheadline.bold().monospacedDigit()) }
                        Image(systemName: "chevron.right").font(.caption.bold())
                    }.frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("insights.spotlight")
            }
        }.padding(.horizontal, 17).padding(.vertical, 9).foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(colors: [Color(red: 0.105, green: 0.22, blue: 0.17), StudioStyle.room, Color(white: 0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .topTrailing) {
                        StudioCorners().stroke(StudioStyle.mint.opacity(0.17), lineWidth: 1)
                            .frame(width: 107, height: 119).padding(16).accessibilityHidden(true)
                    }
            }.clipShape(RoundedRectangle(cornerRadius: 19))
            .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(StudioStyle.edge).allowsHitTesting(false) }
    }

    private func balance(_ burn: BurnCount, priced: Int) -> some View {
        let amount = burn.isManualValue || priced > 0 ? burn.burnLowCents : nil
        return NavigationLink { BurnCountDetailView(initialCurrency: burn.currency) } label: {
            HStack(spacing: 12) {
                icon("flame.fill", tint: .scoutGold)
                VStack(alignment: .leading, spacing: 3) {
                    Text(trDisplay(burn.isIndicative ? "Burn Count · ca." : "Burn Count")).font(.headline)
                    if let paid = burn.spentCents {
                        Text(tr("Paid \(CollectionCardValue.money(paid, currency: burn.currency))")).font(.caption).foregroundStyle(Color.scoutMuted)
                    } else { Text(trDisplay(burn.purchaseCount == 0 ? "Kauf eintragen" : "Exchange rate unavailable")).font(.caption).foregroundStyle(Color.scoutMuted) }
                }
                Spacer(minLength: 4)
                if let amount, let high = burn.burnHighCents {
                    AnimatedMoneyText(low: amount, high: high, currency: burn.currency, color: .scoutGold, showsDirection: false).font(.headline.monospacedDigit()).foregroundStyle(Color.scoutGold)
                } else { Text(verbatim: "—").foregroundStyle(Color.scoutMuted) }
                chevron
            }.padding(13).insightSurface()
        }.buttonStyle(.plain).accessibilityIdentifier("insights.burn")
    }

    private func checklist(_ result: ChecklistMilestone, binder: CollectionBinder) -> some View {
        let set = result.checklist
        return NavigationLink {
            CollectionView(collectionID: set.id, finish: BinderFinish(binder),
                           specialIDs: Set(binder.specials(in: store.library).map(\.id)), showMissing: true)
                .navigationTitle(tr("Missing cards")).navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 12) {
                BinderCover(binder: binder).frame(width: 58, height: 69)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Closest to completion")).font(.caption.bold()).foregroundStyle(Color.scoutMuted)
                    Text(verbatim: [String(set.year), set.name, set.parallel ?? set.subset].joined(separator: " · ")).font(.subheadline.bold())
                    ProgressView(value: Double(result.owned), total: Double(result.total)).tint(Color.scoutAccent).accessibilityHidden(true)
                    Text(tr("\(result.owned)/\(result.total) collected · \(result.remaining) missing")).font(.caption.monospacedDigit()).foregroundStyle(Color.scoutMuted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                chevron
            }.padding(12).insightSurface()
        }.buttonStyle(.plain).accessibilityIdentifier("insights.checklist")
    }

    private func movement(change: PortfolioChange?, history: [PortfolioObservation], currency: String) -> some View {
        let last = history.last { $0.values(currency: currency).contains { $0.comparisonKey != "unpriced-base" } }
        let comparable = change.flatMap { move in (move.largestMove != nil || last.map { move.from < $0.observedAt } == true) ? move : nil }
        return VStack(alignment: .leading, spacing: 0) {
            NavigationLink { InsightPortfolioDetail(section: .value, currency: currency) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Label(tr("Price movement"), systemImage: "chart.xyaxis.line").font(.headline); Spacer(); chevron }
                    if let change = comparable {
                        Text(verbatim: signedMoney(change.deltaCents, currency))
                            .font(.system(.title, weight: .bold).monospacedDigit()).foregroundStyle(change.deltaCents < 0 ? Color.scoutRed : Color.scoutAccent)
                        Text(comparisonCaption(change)).font(.caption).foregroundStyle(Color.scoutMuted)
                    } else {
                        Text(trDisplay(last == nil ? "Noch kein Verlauf" : "Awaiting comparable prices")).font(.subheadline).foregroundStyle(Color.scoutMuted)
                    }
                    Text(tr("Value history & top cards")).font(.caption.bold()).foregroundStyle(Color.scoutAccent)
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.accessibilityIdentifier("insights.history")
            if let mover = comparable?.largestMove, let card = store.library.cards.first(where: { $0.id == mover.cardID }) {
                Divider()
                NavigationLink { CardDetailView(cardID: card.id) } label: {
                    HStack(spacing: 10) {
                        OwnedPhoto(name: card.frontFile, maxPixel: 180).frame(width: 32, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("Largest price move")).font(.caption).foregroundStyle(Color.scoutMuted)
                            Text(verbatim: cardTitle(card)).font(.subheadline.bold())
                        }
                        Spacer(minLength: 4)
                        Text(verbatim: signedMoney(mover.deltaCents, currency)).font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(mover.deltaCents < 0 ? Color.scoutRed : Color.scoutAccent)
                        chevron
                    }.padding(12).contentShape(Rectangle())
                }.accessibilityIdentifier("insights.mover")
            }
        }.buttonStyle(.plain).insightSurface()
    }

    private func signedMoney(_ cents: Double, _ currency: String) -> String {
        (cents > 0 ? "+" : "") + CollectionCardValue.money(Int(cents.rounded()), currency: currency)
    }

    private func reviewSummary(_ cards: [OwnedCard]) -> String {
        let checks = cards.flatMap(\.scanChecks)
        if let first = checks.first, checks.allSatisfy({ $0.labelKey == first.labelKey }) {
            return trDisplay(first.labelKey)
        }
        return tr("\(checks.count) open checks")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(verbatim: title).font(.system(.title2, weight: .heavy).width(.condensed)).accessibilityAddTraits(.isHeader)
    }
    private var chevron: some View { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.scoutMuted) }
    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name).font(.headline).foregroundStyle(tint).frame(width: 38, height: 38)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
    private func door(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.scoutAccent).frame(width: 24)
            Text(verbatim: text).font(.subheadline.bold()); Spacer(); chevron
        }.frame(minHeight: 48).padding(.horizontal, 14).contentShape(Rectangle())
    }
}

private extension View {
    func insightSurface() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.scoutLine.opacity(0.72)).allowsHitTesting(false) }
    }
}

struct InsightPortfolioDetail: View {
    let section: PortfolioDashboardSection
    let currency: String
    var body: some View {
        ScrollView {
            PortfolioDashboardContent(section: section, currency: currency).frame(maxWidth: 590).padding(16).frame(maxWidth: .infinity)
        }.background(Color.scoutCanvas).navigationTitle(trDisplay(section == .value ? "Value history & top cards" : "Empfehlungen"))
            .navigationBarTitleDisplayMode(.inline)
    }
}
