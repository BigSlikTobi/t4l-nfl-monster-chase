import SwiftUI
import Charts
import CardScoutCore

enum PortfolioDashboardSection { case value, moves }

@MainActor func comparisonCaption(_ change: PortfolioChange) -> String {
    let since = change.from.scoutFormatted(date: .abbreviated, time: .omitted)
    return change.matchedCards == 1 ? tr("1 comparable card · since \(since)") : tr("\(change.matchedCards) gleiche Karten · seit \(since)")
}

struct PortfolioDashboardContent: View {
    var section: PortfolioDashboardSection = .value
    @Environment(AppStore.self) private var store
    @State private var selectedCurrency: String

    init(section: PortfolioDashboardSection = .value, currency: String = "") {
        self.section = section
        _selectedCurrency = State(initialValue: currency)
    }
    var body: some View {
        let snapshot = store.dashboardStatistics
        let view = InsightValuation(statistics: snapshot, history: store.library.portfolioHistory ?? [], selected: selectedCurrency)
        let currency = view.currency
        let currencies = view.currencies
        VStack(alignment: .leading, spacing: 26) {
            if section == .value && currencies.count > 1 {
                Picker(tr("Währung · ohne Umrechnung"), selection: Binding(get: { currency }, set: { selectedCurrency = $0 })) {
                    ForEach(currencies, id: \.self) { Text(trDisplay($0)).tag($0) }
                }.pickerStyle(.segmented)
            }
            if section == .value {
                valueHistory(currency: currency)
                leaders(view)
            } else { recommendations }
        }
    }

    private func valueHistory(currency: String) -> some View {
        let observations = (store.library.portfolioHistory ?? []).filter { $0.values(currency: currency).contains { $0.comparisonKey != "unpriced-base" } }
        let change = store.library.portfolioChange(currency: currency, cachedValues: store.dashboardValueCache.portfolioValues(in: store.library))
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("Price movement")).font(.system(.title2, weight: .heavy).width(.condensed))
                Spacer(minLength: 0)
                Image(systemName: "chart.xyaxis.line").foregroundStyle(Color.scoutGold)
            }
            if let last = observations.last, let change, change.largestMove != nil || change.from < last.observedAt {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(trDisplay((change.deltaCents > 0 ? "+" : "") + money(Int(change.deltaCents.rounded()), currency)))
                        .font(.system(.title, design: .rounded, weight: .black))
                        .foregroundStyle(change.deltaCents < 0 ? Color.scoutRed : Color.scoutAccent)
                    if let percentage = change.percentage {
                        Text(trDisplay(percentage.formatted(.percent.precision(.fractionLength(1)))))
                            .font(.subheadline.bold()).foregroundStyle(Color.scoutMuted)
                    }
                }
                Text(comparisonCaption(change))
                    .font(.caption).foregroundStyle(Color.scoutMuted)
                Text(tr("Gleiche Karten · Spannenmitte · ohne neue Karten"))
                    .font(.caption2).foregroundStyle(Color.scoutMuted)
            } else {
                Text(trDisplay(observations.count >= 2 ? "Aktuelle Vergleichspreise fehlen." : observations.isEmpty ? "Noch kein Verlauf" : "Startwert gespeichert"))
                    .font(.headline)
                Text(trDisplay(observations.count >= 2 ? "Deine bisherigen Wertstände bleiben erhalten. Für die aktuelle Veränderung brauchen wir passende Preise derselben Karten." : "Verlauf ab der nächsten Bewertung."))
                    .font(.subheadline).foregroundStyle(Color.scoutMuted)
            }
            if let first = observations.first, let last = observations.last, first.observedAt < last.observedAt {
                let sameDay = Calendar.current.isDate(first.observedAt, inSameDayAs: last.observedAt)
                Chart(observations) { point in
                    LineMark(x: .value(tr("Stand"), point.observedAt), y: .value(currency, point.midpoint(currency: currency) / 100))
                        .foregroundStyle(Color.scoutAccent).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    PointMark(x: .value(tr("Stand"), point.observedAt), y: .value(currency, point.midpoint(currency: currency) / 100))
                        .foregroundStyle(Color.scoutEditorialGold).symbolSize(18)
                }.frame(height: 140).chartXAxis {
                    AxisMarks(values: [first.observedAt, last.observedAt]) {
                        AxisValueLabel(format: sameDay ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                    }
                }.chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .accessibilityLabel(tr("Erfasster bewerteter Bestand in \(currency), einschließlich neuer und entfernter Karten"))
                Text(tr("Bestandswert · \(currency) · inklusive Zu-/Abgängen"))
                    .font(.caption2).foregroundStyle(Color.scoutMuted)
            }
        }.padding(18).background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func leaders(_ view: InsightValuation) -> some View {
        let ranking = view.ranking.prefix(5)
        return VStack(alignment: .leading, spacing: 14) {
            Text(tr("Deine wertvollsten Karten")).font(.system(.title2, design: .rounded, weight: .heavy))
            if ranking.isEmpty {
                Text(tr("Noch keine Preise")).font(.subheadline).foregroundStyle(Color.scoutMuted)
            }
            ForEach(Array(ranking.enumerated()), id: \.element.cardID) { index, value in
                if let card = store.library.cards.first(where: { $0.id == value.cardID }) {
                    NavigationLink { CardDetailView(cardID: card.id) } label: {
                        HStack(spacing: 12) {
                            Text(trDisplay(String(format: "%02d", index + 1))).font(.system(.title3, design: .rounded, weight: .black))
                                .foregroundStyle(index == 0 ? Color.scoutGold : Color.scoutMuted).frame(width: 28)
                            OwnedPhoto(name: card.frontFile, maxPixel: 350, number: "").frame(width: 48, height: 68)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(cardTitle(card)).font(.subheadline.bold()).foregroundStyle(Color.scoutInk)
                                Text(trDisplay(card.analysis?.parallel ?? card.analysis?.subset ?? "Ungegradet")).font(.caption2).foregroundStyle(Color.scoutMuted)
                                Text(trDisplay(value.basis)).font(.caption2).foregroundStyle(Color.scoutMuted)
                            }
                            Spacer(minLength: 0)
                            Text(trDisplay(value.label)).font(.subheadline.bold()).foregroundStyle(Color.scoutAccent)
                                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        }.padding(12).background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(CollectorPressStyle())
                }
            }
        }
    }

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: 14) {

            Text(tr("Empfehlungen")).font(.system(.title2, design: .rounded, weight: .heavy))
            ForEach(["Grade", "Keep", "Sell"], id: \.self) { action in
                let cards = store.library.recommendedCards(action)
                NavigationLink { RecommendationListView(action: action) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: action == "Grade" ? "seal.fill" : action == "Keep" ? "shield.fill" : "arrow.up.right")
                            .font(.title2).foregroundStyle(action == "Grade" ? Color.scoutGold : Color.scoutAccent).frame(width: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trDisplay(action == "Grade" ? "Grading-Kandidaten" : action == "Keep" ? "Behalten" : "Verkaufen"))
                                .font(.headline).foregroundStyle(Color.scoutInk)
                        }
                        Spacer(minLength: 0)
                        Text(tr("\(cards.count)")).font(.system(.title2, design: .rounded, weight: .black)).foregroundStyle(Color.scoutInk)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.scoutMuted)
                    }.padding(16).background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(action == "Grade" ? Color.scoutEditorialGold.opacity(0.45) : .clear))
                }.buttonStyle(CollectorPressStyle())
            }
            let grade = store.library.recommendedCards("Grade")
            ForEach(Array(grade.prefix(2))) { card in
                NavigationLink { CardDetailView(cardID: card.id) } label: { RecommendationCardRow(card: card) }.buttonStyle(.plain)
            }
            if grade.isEmpty {
                Text(tr("Keine bestätigten Grading-Kandidaten"))
                    .font(.caption).foregroundStyle(Color.scoutMuted)
            }
            Text(tr("Foto-Einschätzung · Grading-Kosten und Zustand prüfen"))
                .font(.caption2).foregroundStyle(Color.scoutMuted)
        }
    }
    private func money(_ cents: Int, _ currency: String) -> String { CollectionCardValue.money(cents, currency: currency) }

}

struct RecommendationCardRow: View {
    @Environment(AppStore.self) private var store
    let card: OwnedCard
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            OwnedPhoto(name: card.frontFile, maxPixel: 400, number: "").frame(width: 64, height: 90)
            VStack(alignment: .leading, spacing: 7) {
                Text(cardTitle(card)).font(.headline).foregroundStyle(Color.scoutInk)
                Text(card.analysis?.insights?.actionReason ?? card.analysis?.rationale ?? "")
                    .font(.subheadline).foregroundStyle(Color.scoutMuted).fixedSize(horizontal: false, vertical: true)
                Text(store.dashboardValueCache.collectionQuote(for: card)?.valueLabel ?? tr("Rohwert offen"))
                    .font(.caption.bold()).foregroundStyle(Color.scoutAccent)
                if card.analysis?.recommendation == "Grade" {
                    Text(tr("Foto-Check: keine klaren Schäden sichtbar · keine Grading-Note"))
                        .font(.caption2).foregroundStyle(Color.scoutGold)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct RecommendationListView: View {
    @Environment(AppStore.self) private var store
    let action: String
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if store.library.recommendedCards(action).isEmpty {
                    ScoutEmptyState(symbol: "checklist", title: tr("Noch keine bestätigte Empfehlung."), message: tr("Zuordnung, Analyse und Begründung müssen vollständig vorliegen."))
                }
                ForEach(store.library.recommendedCards(action)) { card in
                    NavigationLink { CardDetailView(cardID: card.id) } label: { RecommendationCardRow(card: card) }.buttonStyle(.plain)
                }
            }.padding(20)
        }.background(Color.scoutCanvas)
            .navigationTitle(trDisplay(action == "Grade" ? "Grading prüfen" : action == "Keep" ? "Behalten" : "Verkaufen"))
    }
}
