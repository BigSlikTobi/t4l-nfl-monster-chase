import CardScoutCore
import SwiftUI

struct CardDisplayCase: View {
    let card: OwnedCard
    @Binding var back: Bool
    let zoom: () -> Void
    let retake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: zoom) {
                GlassCardStage(photo: back ? card.backFile : card.frontFile)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("card.photo")
                .accessibilityLabel(tr("Karte vergrößern. \(trDisplay(back ? "Rückseite" : "Vorderseite")) von \(card.title)"))
            VStack(alignment: .leading, spacing: 4) {
                if let a = card.analysis {
                    let edition = [a.year.map(String.init), a.setName, a.cardNumber.map { "#" + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !edition.isEmpty {
                        Text(verbatim: edition).font(.subheadline.weight(.semibold)).foregroundStyle(StudioStyle.mint)
                    }
                }
                Text(verbatim: cardTitle(card)).font(.system(.largeTitle, weight: .black).width(.condensed))
                    .foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                if let a = card.analysis {
                    let finish = a.cardSightIdentity != nil && a.cardSightVariants?.isEmpty == false ? nil : a.parallel ?? a.subset
                    let line = [a.team, finish, a.serialNumber].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !line.isEmpty { Text(verbatim: line).font(.subheadline).foregroundStyle(StudioStyle.muted) }
                }
            }.padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 12)
            Divider().overlay(StudioStyle.edge)
            ViewThatFits(in: .horizontal) {
                HStack { sides; Spacer(minLength: 4); photoTools }
                VStack(alignment: .leading, spacing: 2) { sides; photoTools }
            }.padding(.horizontal, 12).padding(.vertical, 2)
        }.background(StudioStyle.room).clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(StudioStyle.edge).allowsHitTesting(false) }
    }

    @ViewBuilder private var sides: some View {
        if card.backFile != nil {
            HStack(spacing: 2) { sideButton(false); sideButton(true) }
        } else {
            Text(tr("Vorderseite")).font(.subheadline.weight(.semibold)).foregroundStyle(StudioStyle.muted)
        }
    }

    private func sideButton(_ isBack: Bool) -> some View {
        Button { back = isBack } label: {
            Text(trDisplay(isBack ? "Hinten" : "Vorne")).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(back == isBack ? StudioStyle.room : StudioStyle.muted)
                .background(back == isBack ? StudioStyle.mint : Color.clear, in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(back == isBack ? .isSelected : [])
    }

    private var photoTools: some View {
        HStack(spacing: 0) {
            Button(action: zoom) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel(tr("Dein Foto vergrößern"))
            retakeButton
        }.buttonStyle(.plain).foregroundStyle(StudioStyle.muted)
    }

    private var retakeButton: some View {
        Button(action: retake) {
            Image(systemName: "camera.rotate").font(.body.weight(.semibold))
                .foregroundStyle(StudioStyle.muted).frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(tr("Foto neu aufnehmen"))
    }
}

/// A single magnetic holder. All highlights sit behind the scan or on the perimeter.
private struct GlassCardStage: View {
    let photo: String?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Color.clear.aspectRatio(0.81, contentMode: .fit)
            .frame(maxHeight: verticalSizeClass == .compact ? 300 : 540)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        RadialGradient(colors: [Color(red: 0.17, green: 0.25, blue: 0.22),
                                                Color(red: 0.065, green: 0.095, blue: 0.083),
                                                Color(red: 0.023, green: 0.032, blue: 0.030)],
                                       center: UnitPoint(x: 0.27, y: 0.22),
                                       startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.85)
                        LocalCardPhoto(name: photo, maxPixel: 2000, cutout: true) { image, loading in
                            let ratio = image.map { $0.size.width / max(1, $0.size.height) } ?? 5.0 / 7.0
                            let lip = min(11, geo.size.width * 0.028)
                            let crown = lip * 2.8
                            let maxHeight = max(1, geo.size.height - 32 - crown - lip)
                            let width = max(1, min(geo.size.width * 0.9 - lip * 2, maxHeight * ratio))
                            let height = width / max(0.01, ratio)

                            VStack(spacing: 0) {
                                clasp.frame(height: crown)
                                ZStack {
                                    if let image {
                                        Image(uiImage: image).resizable().scaledToFit()
                                    } else if loading {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "photo").foregroundStyle(StudioStyle.muted)
                                    }
                                }.frame(width: width, height: height)
                                    .background(Color.black.opacity(0.55))
                                    .padding(1.5)
                                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Self.recess, lineWidth: 2) }
                            }.padding(.horizontal, lip).padding(.bottom, lip)
                                .background { holder }
                                .compositingGroup()
                                .shadow(color: .black.opacity(0.65), radius: 11, x: 2, y: 8)
                        }
                    }.frame(width: geo.size.width, height: geo.size.height)
                }
            }.clipped()
    }

    private static let recess = LinearGradient(colors: [.black.opacity(0.8), .white.opacity(0.24), .black.opacity(0.65), .white.opacity(0.75)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)

    private var holder: some View {
        let edge = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return ZStack {
            edge.fill(Color(red: 0.105, green: 0.16, blue: 0.145))
                .overlay { edge.strokeBorder(.white.opacity(0.27), lineWidth: 1) }
                .offset(x: 1.5, y: 3.5)
            edge.fill(LinearGradient(stops: [
                .init(color: .white.opacity(0.51), location: 0),
                .init(color: StudioStyle.mint.opacity(0.12), location: 0.16),
                .init(color: .white.opacity(0.28), location: 0.32),
                .init(color: .white.opacity(0.05), location: 0.36),
                .init(color: .white.opacity(0.10), location: 0.78),
                .init(color: .white.opacity(0.36), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing))
            edge.strokeBorder(LinearGradient(colors: [.white.opacity(0.92), .white.opacity(0.3), .black.opacity(0.42), .white.opacity(0.78)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.6)
            edge.inset(by: 3.5).strokeBorder(.white.opacity(0.23), lineWidth: 0.75)
        }.accessibilityHidden(true)
    }

    private var clasp: some View {
        Circle().fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.49), Color(white: 0.76), Color(white: 0.36)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay { Circle().inset(by: 2).strokeBorder(.white.opacity(0.36), lineWidth: 0.7) }
            .frame(width: 14, height: 14).padding(2)
            .background(Color.black.opacity(0.64), in: Circle())
            .overlay { Circle().strokeBorder(Self.recess, lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

struct CardValueStrip: View {
    @Environment(AppStore.self) private var store
    let card: OwnedCard
    let pricingPaused: Bool
    let edit: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScoutPanel(padding: 14) {
            ViewThatFits(in: .horizontal) {
                if !typeSize.isAccessibilitySize {
                    HStack(spacing: 12) { market; Spacer(minLength: 4); personal }
                }
                VStack(alignment: .leading, spacing: 8) { market; Divider(); personal }
            }
        }
    }

    private var market: some View {
        let quote = store.dashboardValueCache.binderQuote(for: card)
        return VStack(alignment: .leading, spacing: 4) {
            Text(trDisplay(quote?.basisLabel ?? "Card Scout Value")).font(.caption.bold()).foregroundStyle(Color.scoutMuted)
            if card.hasDisplayableAnalysis, card.hasProvisionalAnalysis != true, card.requestedVariantID == nil,
               let value = quote {
                Text(verbatim: value.valueLabel).font(.title.bold().monospacedDigit()).foregroundStyle(Color.scoutAccent)
                if value.saleCount != nil {
                    Text([value.saleDate, value.provider].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Color.scoutMuted)
                }
            } else {
                Text(trDisplay(pendingLabel))
                    .font(.headline).foregroundStyle(Color.scoutInk)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var pendingLabel: String {
        if card.hasProvisionalAnalysis == true { return pricingPaused ? "Preisprüfung pausiert" : "Preis folgt" }
        if card.manualAssignment == true && card.analysis?.insights == nil { return "Bewertung offen" }
        return "Preis noch offen"
    }

    private var personal: some View {
        Button(action: edit) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Dein Preis")).font(.caption.bold()).foregroundStyle(Color.scoutMuted)
                    if let price = card.personalPrice, price.isValid {
                        Text(verbatim: CollectionCardValue.money(price.amountCents, currency: price.currency)).font(.headline.monospacedDigit())
                    } else { Text(tr("Preis hinzufügen")).font(.subheadline.bold()) }
                }
                Image(systemName: "pencil").font(.subheadline.weight(.semibold))
            }.foregroundStyle(Color.scoutAccent).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("card.price")
    }
}
