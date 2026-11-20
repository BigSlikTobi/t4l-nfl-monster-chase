import CardScoutCore
import SwiftUI
import UIKit

struct ConnectionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("scoutAppearance") private var appearance = ScoutAppearance.system.rawValue
    @AppStorage("scoutLanguage") private var language = "system"

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    CollectorMark()
                    CollectorHeading(text: tr("Einstellungen"))
                    Spacer()
                    Button { dismiss() } label: { CollectorToolIcon(name: "xmark") }
                        .accessibilityLabel(tr("Fertig")).accessibilityIdentifier("settings.done")
                }.padding(.horizontal, 15).padding(.vertical, 7)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tr("Darstellung")).font(.headline).accessibilityAddTraits(.isHeader)
                            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                            layout { ForEach(ScoutAppearance.allCases) { mode in appearanceChoice(mode) } }
                        }
                        Menu {
                            Picker(tr("Sprache"), selection: $language) {
                                Text(tr("Wie iPhone")).tag("system")
                                Text(verbatim: "Deutsch").tag("de")
                                Text(verbatim: "English").tag("en")
                            }
                        } label: {
                            HStack(spacing: 12) {
                                settingsIcon("globe")
                                Text(tr("Sprache")).font(.headline)
                                Spacer(minLength: 4)
                                Text(verbatim: language == "system" ? tr("Wie iPhone") : language == "de" ? "Deutsch" : "English")
                                    .font(.subheadline).foregroundStyle(Color.scoutMuted)
                                Image(systemName: "chevron.up.chevron.down").font(.caption2.bold())
                            }.settingsSurface()
                        }.accessibilityIdentifier("settings.language")
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tr("Connection")).font(.headline).accessibilityAddTraits(.isHeader)
                            Button { store.showConnectionSettings = true } label: {
                                HStack(spacing: 12) {
                                    settingsIcon("desktopcomputer")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tr("Mac or server")).font(.headline)
                                        Text(connectionSummary(store)).font(.subheadline).foregroundStyle(Color.scoutMuted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Color.scoutMuted)
                                }.settingsSurface()
                            }.accessibilityIdentifier("settings.connection")
                        }
                    }.frame(maxWidth: 540).padding(16).frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(Color.scoutInk).buttonStyle(.plain).background(Color.scoutCanvas)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $store.showConnectionSettings) { ConnectionSettingsDetail() }
        }
        .preferredColorScheme((ScoutAppearance(rawValue: appearance) ?? .system).colorScheme)
        .tint(.scoutAccent)
        .presentationDetents(typeSize.isAccessibilitySize || store.showConnectionSettings ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func appearanceChoice(_ mode: ScoutAppearance) -> some View {
        let chosen = appearance == mode.rawValue
        let layout = typeSize.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 9))
        return Button { appearance = mode.rawValue } label: {
            layout {
                HStack(spacing: 0) {
                    if mode != .dark { themeSample(dark: false) }
                    if mode != .light { themeSample(dark: true) }
                }.frame(maxWidth: typeSize.isAccessibilitySize ? 64 : .infinity)
                    .frame(height: 42).clipShape(RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                HStack(spacing: 3) {
                    Text(trDisplay(mode.title)).font(.subheadline.bold())
                    Spacer(minLength: 1)
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen ? Color.scoutAccent : Color.scoutMuted).accessibilityHidden(true)
                }
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(chosen ? Color.scoutElevated : Color.scoutSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(chosen ? Color.scoutAccent : Color.scoutLine, lineWidth: chosen ? 1.5 : 0.75) }
        }.accessibilityLabel(trDisplay(mode.title)).accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityIdentifier("clubhouse.appearance." + mode.rawValue)
    }

    private func themeSample(dark: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            (dark ? Color(red: 0.09, green: 0.14, blue: 0.11) : Color(red: 0.89, green: 0.92, blue: 0.88))
            RoundedRectangle(cornerRadius: 2).fill(dark ? Color.mint.opacity(0.7) : Color.scoutButtonFill)
                .frame(width: 13, height: 18).rotationEffect(.degrees(10)).padding(6)
        }
    }

    private func settingsIcon(_ name: String) -> some View {
        Image(systemName: name).font(.headline).foregroundStyle(Color.scoutAccent)
            .frame(width: 35, height: 35).background(Color.scoutElevated, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor private func connectionSummary(_ store: AppStore) -> String {
    guard store.pairing != nil else { return tr("Noch kein Mac oder Server gekoppelt") }
    return trDisplay(store.connected ? "Verbunden" : "Offline")
}

private extension View {
    func settingsSurface() -> some View {
        padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.scoutSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.scoutLine.opacity(0.7), lineWidth: 0.75) }
            .contentShape(Rectangle())
    }
}

private struct ConnectionSettingsDetail: View {
    @Environment(AppStore.self) private var store
    @State private var code = ""
    @State private var scanning = false
    @State private var invalid = false

    var body: some View {
        Form {
            if let candidate = store.pairingCandidate {
                Section(tr("Diese Verbindung verwenden?")) {
                    Text(verbatim: URL(string: candidate.baseURL)?.host ?? "Mac").privacySensitive()
                    Button(tr("Verbinden")) { store.confirmPairing() }.fontWeight(.semibold)
                    Button(tr("Abbrechen"), role: .cancel) { store.pairingCandidate = nil }
                }.listRowBackground(Color.scoutSurface)
            }
            Section {
                Label(connectionSummary(store), systemImage: store.connected ? "checkmark.circle" : "desktopcomputer")
                    .font(.headline)
                if let pairing = store.pairing {
                    Text(verbatim: URL(string: pairing.baseURL)?.host ?? "Mac").font(.subheadline).privacySensitive()
                    Button { Task { await store.sync() } } label: {
                        HStack { Label(tr("Verbindung prüfen"), systemImage: "arrow.clockwise"); Spacer(); if store.syncing { ProgressView() } }
                    }.disabled(store.syncing)
                }
                if let message = store.connectionError {
                    Label(trDisplay(message), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Color.scoutGold)
                }
            }.listRowBackground(Color.scoutSurface)
            if store.pairingCandidate == nil {
                Section(tr("Mac oder Server verbinden")) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { scanning = true } label: { Label(tr("Verbindungscode scannen"), systemImage: "qrcode.viewfinder") }
                    }
                    TextField(tr("Verbindungslink einfügen"), text: $code, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .onChange(of: code) { _, _ in invalid = false }
                    if invalid { Text(tr("Dieser Verbindungscode ist ungültig.")).font(.footnote).foregroundStyle(Color.scoutRed) }
                    Button(tr("Code öffnen")) {
                        guard let url = URL(string: code.trimmingCharacters(in: .whitespacesAndNewlines)) else { invalid = true; return }
                        if store.receivePairing(url, reportError: false) { code = "" } else { invalid = true }
                    }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.listRowBackground(Color.scoutSurface)
            }
        }.scrollContentBackground(.hidden).background(Color.scoutCanvas)
            .navigationTitle(tr("Connection")).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .sheet(isPresented: $scanning) { QRScanner { value in
                scanning = false
                if let url = URL(string: value) { store.receivePairing(url) }
            } }
    }
}
