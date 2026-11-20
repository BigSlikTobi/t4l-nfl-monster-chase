import SwiftUI
import CardScoutCore

struct AnalysisCardsView: View {
    let analysis: CardAnalysis
    var provisional = false
    var assessmentCleared = false
    private var a: CardAnalysis { analysis.currentPricing() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if a.identityConfirmed == true && ["unknown", "unlicensed"].contains(a.licenseScope ?? "unknown") {
                Label(tr("Lizenz prüfen"), systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.scoutGold)
            }

            if !["cardsight", "photoReview"].contains(a.assessmentSource ?? "") || !a.rarityFacts.isEmpty { InsightPanel(title: tr("Variante"), icon: "rectangle.stack", tint: .scoutGold, badge: a.discoveryRarity) {
                if a.rarityFacts.isEmpty {
                    Text(tr("Variante noch offen")).font(.subheadline).foregroundStyle(Color.scoutMuted)
                } else {
                    InsightBullets(items: a.rarityFacts)
                }
            }.id("rarity") }

            if !["cardsight", "photoReview"].contains(a.assessmentSource ?? "") { InsightPanel(title: tr("Zustand"), icon: "viewfinder", tint: a.insights?.conditionStatus == "visible_damage" ? .scoutGold : .scoutAccent) {
                if let info = a.insights {
                    Text(trDisplay(info.conditionLabel)).font(.headline)
                    InsightBullets(items: info.conditionIssues)
                    Text(tr("Foto-Check · keine Benotung")).font(.caption).foregroundStyle(Color.scoutMuted)
                    if !info.conditionLimitations.isEmpty {
                        DisclosureGroup {
                            InsightBullets(items: info.conditionLimitations).padding(.top, 10)
                        } label: {
                            Label(tr("Foto-Details"), systemImage: "info.circle").font(.subheadline)
                        }.tint(Color.scoutMuted)
                    }
                } else {
                    Text(tr("Foto-Check noch offen")).font(.subheadline).foregroundStyle(Color.scoutMuted)
                }
            }.id("condition") }

            if !provisional && !assessmentCleared && !["cardsight", "photoReview"].contains(a.assessmentSource ?? "") { ScoutPanel {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: recommendationSymbol)
                        .font(.title2).foregroundStyle(Color.scoutAccent)
                        .frame(width: 46, height: 46)
                        .background(Color.scoutAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(trDisplay(a.actionLabel)).font(.title3.weight(.bold))
                        if let info = a.insights, !info.actionReason.isEmpty {
                            DisclosureGroup(tr("Begründung")) {
                                Text(info.actionReason).font(.subheadline).foregroundStyle(Color.scoutMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.font(.caption)
                        }
                    }
                }
            } }

            ScoutPanel {
                DisclosureGroup {
                    cardData.padding(.top, 16)
                } label: {
                    Label(tr("Kartendaten & Quellen"), systemImage: "rectangle.and.text.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                }.tint(Color.scoutMuted)
            }
        }
    }

    private var cardData: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(trDisplay([a.year.map(String.init), a.setName, a.cardNumber.map { "#" + $0 }].compactMap { $0 }.joined(separator: " · ")))
                .font(.subheadline.weight(.semibold))
            if let team = a.team { Text(trDisplay(team)).font(.caption).foregroundStyle(Color.scoutMuted) }
            LabeledContent(tr("Hersteller"), value: trDisplay(a.brand ?? "Offen"))
            LabeledContent(tr("Variante"), value: trDisplay(a.parallel ?? a.subset ?? "Offen"))
            LabeledContent(tr("Rookie"), value: trDisplay(a.rookie.map { $0 ? "Ja" : "Nein" } ?? "Offen"))
            LabeledContent(tr("Nummerierung"), value: trDisplay(a.serialNumber ?? "Keine erkennbar"))
            LabeledContent(tr("Lizenz"), value: trDisplay(["nfl_and_nflpa": "NFL + NFLPA", "nfl": "NFL", "nflpa": "NFLPA", "college": "College", "unlicensed": "Nicht lizenziert"][a.licenseScope ?? ""] ?? "Offen"))
            if let info = a.insights {
                ForEach(info.sourceChecks, id: \.provider) { check in
                    if let value = check.url, let url = URL(string: value) {
                        Link(destination: url) { Label(trDisplay(check.provider), systemImage: "arrow.up.right").padding(.vertical, 4) }
                    }
                }
            }
            if let uncertainties = a.uncertainties, !uncertainties.isEmpty {
                Text(tr("Noch offen")).font(.caption.weight(.semibold)).foregroundStyle(Color.scoutGold)
                InsightBullets(items: uncertainties)
            }
            if a.insights == nil {
                DisclosureGroup(tr("Bisherige Einschätzung")) {
                    InsightBullets(items: legacyBullets(a.conditionNotes + "\n" + a.rationale)).padding(.top, 10)
                }
                ForEach(Array(a.marketSources.enumerated()), id: \.offset) { _, source in
                    if let url = URL(string: source.url) { Link(trDisplay(source.title), destination: url) }
                }
            }
        }.font(.subheadline)
    }

    private var recommendationSymbol: String {
        switch a.recommendation {
        case "Sell": "arrow.up.right.circle"
        case "Grade": "checkmark.seal"
        case "Bulk": "square.stack.3d.up"
        default: "bookmark"
        }
    }

    private func legacyBullets(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\n", with: ". ").components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

private struct InsightPanel<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    var badge: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScoutPanel {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) {
                        panelTitle
                        Spacer(minLength: 4)
                        if let badge { badgeView(badge) }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        panelTitle
                        if let badge { badgeView(badge) }
                    }
                }
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var panelTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            Text(trDisplay(title)).foregroundStyle(Color.scoutMuted)
        }.font(.subheadline.weight(.semibold)).fixedSize()
    }

    private func badgeView(_ title: String) -> some View {
        Text(trDisplay(title)).font(.caption.weight(.semibold))
            .foregroundStyle(tint).padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.10), in: Capsule()).fixedSize(horizontal: true, vertical: false)
    }
}

private struct InsightBullets: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 9) {
                    Circle().fill(Color.scoutMuted.opacity(0.6)).frame(width: 4, height: 4).padding(.top, 8).accessibilityHidden(true)
                    Text((try? AttributedString(markdown: item)) ?? AttributedString(item))
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(Color.scoutMuted).accessibilityElement(children: .combine)
            }
        }
    }
}
