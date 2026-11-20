import SwiftUI

struct CollectorMark: View {
    var size: CGFloat = 34

    var body: some View {
        Image("ScoutFlameLogo").resizable().scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct CollectorHeading: View {
    let text: String

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(.title2, weight: .black).width(.condensed)).italic()
            .multilineTextAlignment(.leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct CollectorToolIcon: View {
    let name: String

    var body: some View {
        Image(systemName: name).font(.system(.body, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(Color.scoutElevated, in: Circle())
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}

struct CollectorHeader<Heading: View, Actions: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    var settingsEnabled = true
    @ViewBuilder let heading: () -> Heading
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))
        layout {
            HStack(spacing: 9) {
                CollectorMark()
                heading()
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 1) {
                actions()
                Button {
                    store.showConnectionSettings = store.pairingCandidate != nil
                    store.showSettings = true
                } label: { CollectorToolIcon(name: "gearshape") }
                    .accessibilityLabel(tr("Einstellungen")).accessibilityIdentifier("shell.settings")
                    .disabled(!settingsEnabled)
            }.frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
        }.padding(.horizontal, 12).padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.scoutInk).buttonStyle(.plain)
            .background(Color.scoutCanvas)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.scoutLine.opacity(0.55)).frame(height: 0.5).allowsHitTesting(false) }
    }
}

struct CollectorTabLabel: View {
    let title: String
    let icon: String
    let selectedIcon: String
    let selected: Bool

    var body: some View {
        Label(title, systemImage: selected ? selectedIcon : icon)
            .environment(\.symbolVariants, .none)
    }
}

extension View {
    func collectorTabSurface() -> some View {
        toolbarBackground(Color.scoutCanvas, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}

struct CollectorTabBehavior: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}
