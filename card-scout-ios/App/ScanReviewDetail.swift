import SwiftUI
import CardScoutCore

struct ScanReviewDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let cardID: String
    var advance: (() -> Void)? = nil
    @State private var back = false
    @State private var zoom = false
    @State private var photoSide: CardPhotoSide?
    @State private var optionalField: PrintedField?
    @State private var reading = ""
    @State private var conflict = false
    @State private var chosen: String?
    @State private var manualChecklist = false
    @State private var query = ""
    @State private var options: [ChecklistOption] = []
    @State private var loadedKey: MatchKey?
    @State private var failure: String?
    @State private var selectionRevision = ""
    private var card: OwnedCard? { store.library.cards.first { $0.id == cardID } }
    private func active(_ card: OwnedCard) -> ScanCheck? {
        if let optionalField { return .reading(optionalField) }
        if manualChecklist { return .checklist }
        return card.scanChecks.first
    }

    var body: some View {
        NavigationStack {
            if let card {
                let check = active(card)
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        Text(trDisplay(check?.labelKey ?? ScanReviewRow.status(card, connected: store.connected))).font(.title.bold())
                        Text(verbatim: [cardTitle(card), card.analysis?.year.map(String.init), card.analysis?.setName,
                                        card.analysis?.cardNumber.map { "#" + $0 }].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(StudioStyle.muted).font(.subheadline)
                        inspector(card)
                        switch check {
                        case .photo(let side):
                            Text(trDisplay(side == .back ? "Capture the whole back, including the number and year." : "Capture the whole front with the player name in focus.")).font(.subheadline)
                            Button { photoSide = side } label: { Label(trDisplay(side == .back ? "Add back photo" : "Retake front photo"), systemImage: "camera") }.buttonStyle(StudioPrimary())
                        case .reading(let field): readingControls(card, field: field)
                        case .tilt: FinishFollowUp(card: card)
                        case .finish: finishControls(card)
                        case .checklist: checklistControls(card)
                        case nil: summary(card)
                        }
                        if let failure { Text(trDisplay(failure)).font(.footnote).foregroundStyle(Color.scoutGold) }
                        if check != nil {
                            Button(tr("Keep open")) { leave() }.frame(maxWidth: .infinity, minHeight: 44)
                            if optionalField == nil, !manualChecklist, card.scanChecks.count > 1 {
                                Divider()
                                Text(tr("Next · \(trDisplay(card.scanChecks[1].labelKey))")).font(.caption).foregroundStyle(StudioStyle.muted)
                            }
                        }
                    }.frame(maxWidth: 520).padding(18).frame(maxWidth: .infinity)
                }.background(StudioStyle.room)
                .onChange(of: check, initial: true) { _, next in prepare(card, next) }
                .onChange(of: card.jobID) { _, _ in prepare(card, active(card)) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(tr("Schließen")) { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { CardRemovalButton(card: card, onRemoved: leave) }
                }
                .sheet(item: $photoSide) { side in AddCardView(cardID: cardID, side: side, onSaved: { if advance != nil { leave() } }) }
                .fullScreenCover(isPresented: $zoom) { CardPhotoViewer(cardID: cardID, initialBack: back, showOriginal: true) }
                .alert(tr("Reopen the checklist match?"), isPresented: $conflict) {
                    Button(tr("Use my reading and reopen")) {
                        if case .reading(let field) = active(card) { record(card, field: field, reopen: true) }
                    }
                    Button(tr("Abbrechen"), role: .cancel) { }
                } message: { Text(tr("Your reading differs from the suggested identity. The exact match will stay open.")) }
            } else { Text(tr("Karte nicht gefunden.")) }
        }.preferredColorScheme(.dark).tint(StudioStyle.mint).presentationDragIndicator(.visible)
    }

    private func inspector(_ card: OwnedCard) -> some View {
        VStack(spacing: 5) {
            Button { zoom = true } label: {
                OwnedPhoto(name: back ? card.backFile : card.frontFile, maxPixel: 1100, original: true)
                    .frame(maxWidth: .infinity).frame(height: 182)
                    .overlay(alignment: .topTrailing) { Image(systemName: "plus.magnifyingglass").padding(9) }
            }.buttonStyle(.plain).accessibilityLabel(tr("Dein Foto vergrößern"))
            if card.backFile != nil {
                Picker(tr("Card side"), selection: $back) { Text(tr("Vorderseite")).tag(false); Text(tr("Rückseite")).tag(true) }
                    .pickerStyle(.segmented).frame(maxWidth: 195)
            }
        }.padding(9).background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func readingControls(_ card: OwnedCard, field: PrintedField) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let serial = field == .serial
            Text(trDisplay(serial ? "Enter the stamped copy number and print run." : "Enter the detail as it appears on the physical card.")).font(.subheadline)
            TextField(trDisplay(serial ? "Copy / print run" : field.labelKey), text: $reading)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled().accessibilityIdentifier("review.reading")
            Button(tr("Save reading")) {
                guard let value = field.normalized(reading) else { return }
                if card.conflictsWithReading(field, value: value) { conflict = true }
                else { record(card, field: field, reopen: false) }
            }.buttonStyle(StudioPrimary()).disabled(field.normalized(reading) == nil)
        }
    }
    private func finishControls(_ card: OwnedCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let refractor = card.reviewVariants.contains { $0.name.localizedCaseInsensitiveContains("Refractor") }
            Text(trDisplay(refractor ? "Check the back for “Refractor” and compare the finish in hand." : "Tilt the card in the light and compare its finish.")).font(.subheadline)
            ForEach(card.reviewVariants) { variant in
                option(variant.id, variant.name, variant.numberedTo.map { "/" + String($0) } ?? "")
            }
            Button(tr("Confirm finish")) {
                guard let chosen, selectionRevision == card.jobID, card.reviewVariants.contains(where: { $0.id == chosen }) else { return }
                store.selectVariant(card.id, variantID: chosen)
                if self.card?.state == "queued" { if advance != nil { leave() } }
                else { failure = store.lastError }
            }.buttonStyle(StudioPrimary()).disabled(chosen == nil)
            reject(card)
        }
    }
    private struct MatchKey: Equatable {
        let job: String; let query: String; let readings: [String:String]; let suggestions: [CardMatch]; let collectionCount: Int
    }
    private struct ChecklistOption: Identifiable, Sendable {
        let match: CardMatch; let name: String; let detail: String
        var id: String { match.id }
    }
    private func checklistControls(_ card: OwnedCard) -> some View {
        let key = MatchKey(job: card.jobID, query: query, readings: card.printedReadings ?? [:], suggestions: card.matchSuggestions ?? [], collectionCount: store.library.collections.count)
        return VStack(alignment: .leading, spacing: 6) {
            Text(tr("Compare the printed number, year and design.")).font(.subheadline)
            TextField(tr("Search checklist"), text: $query).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            if loadedKey != key { ProgressView() }
            else if options.isEmpty { Text(tr("No matching checklist entries.")).font(.subheadline).foregroundStyle(StudioStyle.muted) }
            else {
                ForEach(options) { item in option(item.id, item.name, item.detail) }
                Button(tr("Confirm entry")) {
                    guard selectionRevision == card.jobID, let item = options.first(where: { $0.id == chosen }) else { return }
                    let match = item.match
                    let success = card.isScanDraft == true
                        ? store.collectScan(card.id, match: match, folderID: nil, newFolderName: nil)
                        : store.correctAssignment(card.id, collectionID: match.collectionID, number: match.number)
                    if success { manualChecklist = false; leave() } else { failure = store.lastError }
                }.buttonStyle(StudioPrimary()).disabled(chosen == nil || loadedKey != key)
            }
            reject(card)
        }.task(id: key) {
            chosen = nil
            if !key.query.isEmpty { try? await Task.sleep(for: .milliseconds(180)); if Task.isCancelled { return } }
            let library = store.library
            let results = await Task.detached(priority: .userInitiated) {
                library.reviewMatches(for: card, query: key.query).compactMap { match -> ChecklistOption? in
                    guard let set = library.collections.first(where: { $0.id == match.collectionID }),
                          let entry = set.cards.first(where: { $0.number == match.number }) else { return nil }
                    return ChecklistOption(match: match, name: entry.player, detail: ["#" + entry.number, String(set.year), set.name, set.subset, set.parallel].compactMap { $0 }.joined(separator: " · "))
                }
            }.value
            if !Task.isCancelled { options = results; loadedKey = key }
        }
    }
    private func option(_ id: String, _ name: String, _ caption: String) -> some View {
        Button { chosen = id } label: {
            HStack {
                Image(systemName: chosen == id ? "checkmark.circle.fill" : "circle").foregroundStyle(StudioStyle.mint)
                VStack(alignment: .leading) { Text(verbatim: name).font(.subheadline.bold())
                    if !caption.isEmpty { Text(verbatim: caption).font(.caption).foregroundStyle(StudioStyle.muted) } }
                Spacer()
            }.padding(10).frame(minHeight: 44).background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(chosen == id ? .isSelected : [])
    }
    private func reject(_ card: OwnedCard) -> some View {
        Button(tr("None of these match")) {
            if store.saveReviewChange({ try $0.declineScanMatch(cardID: card.id, jobID: selectionRevision) }) {
                manualChecklist = false
                if advance != nil { leave() }
            } else { failure = store.lastError }
        }.frame(maxWidth: .infinity, minHeight: 44)
    }
    @ViewBuilder private func summary(_ card: OwnedCard) -> some View {
        if card.state == "failed" {
            Button(tr("Retry analysis")) { store.reanalyze(card.id) }.buttonStyle(StudioPrimary())
        } else if card.isAwaitingAnalysis {
            Label(trDisplay(store.connected ? "Matching card" : "Waiting for connection"), systemImage: "clock").foregroundStyle(StudioStyle.muted)
        } else {
            ForEach(PrintedField.allCases) { field in
                if let value = card.printedReadings?[field.rawValue] { LabeledContent(trDisplay(field.labelKey), value: value) }
            }
            if card.canCaptureFinishAngle || card.proposedPhotoMatch != nil { FinishFollowUp(card: card) }
            if card.analysis?.identityConfirmed != true && card.automaticScan != true && card.analysis?.finishPolicy == nil {
                Menu(tr("Record a printed detail")) {
                    ForEach(PrintedField.allCases) { field in Button(trDisplay(field.labelKey)) { optionalField = field } }
                }.frame(minHeight: 44)
                Button(tr("Search checklist")) { manualChecklist = true }.buttonStyle(StudioPrimary())
            }
            if card.isScanDraft == true {
                NavigationLink { ScanMatchView(cardID: card.id) } label: { Text(tr("Zur Sammlung hinzufügen")) }
                    .buttonStyle(StudioPrimary())
            } else if card.hasCurrentAnalysis {
                NavigationLink { CardDetailView(cardID: card.id) } label: { Text(tr("Karte ansehen")) }.buttonStyle(StudioPrimary())
            }
        }
    }
    private func prepare(_ card: OwnedCard, _ check: ScanCheck?) {
        chosen = nil; query = ""; loadedKey = nil; options = []; failure = nil; selectionRevision = card.jobID
        switch check {
        case .reading(let field): reading = card.printedReadings?[field.rawValue] ?? ""; back = field != .player && card.backFile != nil
        case .finish: back = card.backFile != nil && card.reviewVariants.contains { $0.name.localizedCaseInsensitiveContains("Refractor") }
        case .checklist: back = card.backFile != nil
        default: back = false
        }
    }
    private func record(_ card: OwnedCard, field: PrintedField, reopen: Bool) {
        guard store.saveReviewChange({ try $0.recordReading(field, raw: reading, cardID: cardID, jobID: selectionRevision, reopen: reopen) }) else { failure = store.lastError; return }
        optionalField = nil
        if self.card?.scanChecks.isEmpty == true, advance != nil { leave() }
    }
    private func leave() { if let advance { advance() } else { dismiss() } }
}
