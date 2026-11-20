import CardScoutCore
import SwiftUI

struct CardVariantPicker: View {
    let card: OwnedCard
    private struct Choice: Identifiable {
        let id: String
        let options: [CardSightVariant]
        let confirmedID: String?
    }
    @State private var choice: Choice?
    private var options: [CardSightVariant] { card.analysis?.currentPricing().cardSightVariants ?? [] }
    private var confirmedID: String? {
        guard card.requestedVariantID == nil, card.analysis?.identityConfirmed == true else { return nil }
        return card.analysis?.cardSightIdentity?.parallelID ?? "base"
    }

    var body: some View {
        if card.analysis?.cardSightIdentity != nil, !options.isEmpty {
            let selected = options.first { $0.id == (card.requestedVariantID ?? confirmedID) }
            Button { choice = Choice(id: card.jobID, options: options, confirmedID: confirmedID) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.3.layers.3d").foregroundStyle(Color.scoutAccent)
                        .frame(width: 36, height: 36).background(Color.scoutElevated, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr("Variante")).font(.caption.weight(.semibold)).foregroundStyle(Color.scoutMuted)
                        Text(selected?.name ?? tr("Variante wählen")).font(.headline).foregroundStyle(Color.scoutInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if card.requestedVariantID != nil { ProgressView() }
                    else { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.scoutMuted) }
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain).background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.scoutLine.opacity(0.7)).allowsHitTesting(false) }
                .disabled(!card.hasCurrentAnalysis || card.requestedVariantID != nil)
                .accessibilityIdentifier("card.variants")
                .sheet(item: $choice) { opened in
                    VariantSheet(cardID: card.id, jobID: opened.id, title: cardTitle(card), options: opened.options, confirmedID: opened.confirmedID)
                        .presentationDragIndicator(.visible)
                }
        }
    }
}

private struct VariantSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let cardID: String
    let jobID: String
    let title: String
    let options: [CardSightVariant]
    let confirmedID: String?
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var picked: String?
    @State private var failed = false

    private var results: [CardSightVariant] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let priority = ["High": 2, "Medium": 1]
        return options.filter { term.isEmpty || $0.name.localizedStandardContains(term) }.sorted {
            let left = $0.id == confirmedID ? 3 : priority[$0.confidence ?? ""] ?? 0
            let right = $1.id == confirmedID ? 3 : priority[$1.confidence ?? ""] ?? 0
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left > right
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                List {
                    if options.contains(where: { $0.name.localizedCaseInsensitiveContains("refractor") }) {
                        Label(tr("Prüfe, ob „Refractor“ auf deiner Karte steht."), systemImage: "light.max")
                            .font(.subheadline).foregroundStyle(Color.scoutGold)
                    }
                    Section {
                        ForEach(results) { option in
                            Button { searching = false; picked = option.id; failed = false } label: { row(option) }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits((picked ?? confirmedID) == option.id ? .isSelected : [])
                        }
                        if results.isEmpty { Text(tr("Keine Treffer.")).foregroundStyle(Color.scoutMuted) }
                    } header: { Text(verbatim: title).textCase(nil) }
                }.listStyle(.insetGrouped).scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
            }.background(Color.scoutCanvas)
                .navigationTitle(tr("Variante wählen")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(tr("Schließen")) { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    if let picked, let variant = options.first(where: { $0.id == picked }), picked != confirmedID {
                        VStack(alignment: .leading, spacing: 6) {
                            if failed { Text(tr("Zuordnung konnte nicht gespeichert werden.")).font(.footnote).foregroundStyle(Color.scoutGold) }
                            Button {
                                guard let latest = store.library.cards.first(where: { $0.id == cardID }), latest.jobID == jobID,
                                      latest.hasCurrentAnalysis, latest.requestedVariantID == nil,
                                      store.selectVariant(cardID, variantID: picked) else { failed = true; return }
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark")
                                    Text(tr("Use variant")).bold()
                                    Spacer()
                                    Text(verbatim: variant.name).font(.subheadline).multilineTextAlignment(.trailing)
                                }
                            }.buttonStyle(StudioPrimary()).accessibilityIdentifier("variant.apply")
                        }.padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
                    }
                }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.scoutMuted)
            TextField(tr("Variante suchen"), text: $query).focused($searching).submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { searching = false }.accessibilityIdentifier("variant.search")
            if !query.isEmpty {
                Button { query = ""; searching = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.scoutMuted)
                        .frame(width: 44, height: 44)
                }.accessibilityLabel(tr("Suche löschen")).accessibilityIdentifier("variant.clear")
            }
        }.padding(.leading, 12).padding(.trailing, 4).frame(minHeight: 46)
            .background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.scoutLine).allowsHitTesting(false) }
            .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func row(_ option: CardSightVariant) -> some View {
        let selected = option.id == (picked ?? confirmedID)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: option.name).font(.body.weight(.semibold)).foregroundStyle(Color.scoutInk)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                let details = [option.numberedTo.map { "/\($0)" }, option.id == confirmedID ? tr("Current variant") :
                                (["High", "Medium"].contains(option.confidence ?? "") ? tr("Vorschlag") : nil), option.scoutValue?.valueLabel]
                let caption = details.compactMap { $0 }.joined(separator: " · ")
                if !caption.isEmpty { Text(verbatim: caption).font(.subheadline).foregroundStyle(Color.scoutMuted) }
            }
            Spacer(minLength: 4)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.scoutAccent : Color.scoutMuted).accessibilityHidden(true)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
}
