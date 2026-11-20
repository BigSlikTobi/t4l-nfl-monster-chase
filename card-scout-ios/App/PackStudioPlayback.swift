import SwiftUI
import AVKit
import CardScoutCore

enum StudioStyle {
    static let room = Color(red: 0.055, green: 0.082, blue: 0.065)
    static let panel = Color(red: 0.105, green: 0.143, blue: 0.118)
    static let mint = Color(red: 0.68, green: 0.89, blue: 0.73)
    static let muted = Color(red: 0.72, green: 0.77, blue: 0.73)
    static let edge = Color.white.opacity(0.19)
}

struct StudioBadge: View {
    let title: String
    var icon: String?
    var dot: Color?
    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let icon { Image(systemName: icon) }
            Text(verbatim: title.uppercased()).lineLimit(1)
        }.font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(0.7)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(.black.opacity(0.69), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(StudioStyle.edge) }
    }
}

struct StudioPrimary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.bold()).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 46).padding(.horizontal, 6)
            .foregroundStyle(StudioStyle.room).background(StudioStyle.mint.opacity(configuration.isPressed ? 0.76 : 1),
                                                         in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StudioCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(16, rect.width / 6)
        var path = Path()
        for (x, y, dx, dy) in [(rect.minX, rect.minY, arm, arm), (rect.maxX, rect.minY, -arm, arm),
                                (rect.minX, rect.maxY, arm, -arm), (rect.maxX, rect.maxY, -arm, -arm)] {
            path.move(to: CGPoint(x: x + dx, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy))
        }
        return path
    }
}

struct StudioFrameCrop: Equatable {
    var center = CGPoint(x: 0.5, y: 0.5)
    var width: CGFloat = 0.67
    func rect(in size: CGSize) -> CGRect {
        let w = min(size.width * width, size.height / 1.4)
        let h = w * 1.4
        return CGRect(x: min(max(0, center.x * size.width - w / 2), size.width - w),
                      y: min(max(0, center.y * size.height - h / 2), size.height - h), width: w, height: h)
    }
}

private struct MovieFullscreen: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

struct PackStudioPlayback: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let take: PackTake
    let library: PackTakeLibrary
    let back: () -> Void
    let didRename: (PackTake) -> Void
    let scan: () -> Void
    let useFrame: (CapturePhoto) throws -> Void
    @State private var player = AVPlayer()
    @State private var observer: Any?
    @State private var position = 0.0
    @State private var playing = false
    @State private var cropping = false
    @State private var crop = StudioFrameCrop()
    @State private var dragOrigin: StudioFrameCrop?
    @State private var thumbnails: [UIImage] = []
    @State private var filmSize = CGSize(width: 9, height: 16)
    @State private var naming = false
    @State private var title = ""
    @State private var full = false
    @State private var busy = false
    @State private var export: StudioExport?
    @State private var exportedDirectory: URL?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if cropping {
                    preview.frame(maxWidth: 216).frame(maxWidth: .infinity)
                    backButton
                    titleText(tr("Frame grab"))
                } else if typeSize.isAccessibilitySize {
                    preview.frame(maxWidth: 180).frame(maxWidth: .infinity)
                    videoHeader
                } else {
                    HStack(spacing: 16) {
                        preview.containerRelativeFrame(.horizontal) { width, _ in min(196, width * 0.415) }
                        videoHeader
                    }
                }
                Divider()
                timeline
                if cropping {
                    Text(tr("Crop size")).font(.caption.bold())
                    Slider(value: $crop.width, in: 0.28...0.94).accessibilityLabel(tr("Crop size"))
                    Button { extract() } label: {
                        Label(tr("Use as card front"), systemImage: "crop")
                    }.buttonStyle(StudioPrimary()).disabled(busy)
                } else {
                    Divider()
                    Text(tr("Add cards from this pack")).font(.headline)
                    actionRow(tr("Grab a video frame"), "crop", tr("Save a front from a moment in your clip.")) {
                        player.pause(); playing = false
                        if position < 0.05, let mark = take.marks.first { seek(mark) }
                        cropping = true
                    }
                    actionRow(tr("Scan front & back"), "viewfinder", tr("Take two stills with a card guide."), scan)
                }
                if let message { Text(trDisplay(message)).font(.footnote).foregroundStyle(StudioStyle.mint).accessibilityAddTraits(.isStaticText) }
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }
        .tint(StudioStyle.mint)
        .task(id: take.id) { await prepare() }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer); self.observer = nil }
        }
        .sheet(isPresented: $full) {
            ZStack(alignment: .topTrailing) {
                MovieFullscreen(player: player).ignoresSafeArea()
                Button { full = false } label: { Image(systemName: "xmark.circle.fill").font(.title).padding() }
                    .accessibilityLabel(tr("Schließen"))
            }.presentationDragIndicator(.visible)
        }
        .sheet(item: $export, onDismiss: {
            if let exportedDirectory { try? FileManager.default.removeItem(at: exportedDirectory); self.exportedDirectory = nil }
        }) { StudioFilePicker(export: $0) { export = nil } }
        .alert(tr("Name this video"), isPresented: $naming) {
            TextField(tr("Video name"), text: $title).submitLabel(.done)
            Button(tr("Abbrechen"), role: .cancel) {}
            Button(tr("Save name")) {
                do { didRename(try library.rename(take, to: title)) }
                catch { message = "Video name could not be saved." }
            }.disabled(PackTake.cleanName(title).isEmpty)
        }
    }
    private var backButton: some View {
        Button { if cropping { cropping = false } else { back() } } label: {
            Label(tr("Zurück"), systemImage: "arrow.left").font(.caption.weight(.semibold)).frame(minHeight: 36)
        }
    }
    private func titleText(_ title: String) -> some View {
        Text(verbatim: title).font(.system(size: 30, weight: .black)).fontWidth(.condensed).italic()
            .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
    }
    private var videoHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            backButton
            HStack(spacing: 3) {
                titleText(take.name)
                Button { title = take.name; naming = true } label: {
                    Image(systemName: "pencil").frame(width: 44, height: 44).overlay { Circle().strokeBorder(StudioStyle.edge) }
                }.accessibilityLabel(tr("Rename video"))
            }
            Text(verbatim: [take.demo ? tr("Demo footage") : tr("Pack video"), studioTime(take.duration), "9:16"].joined(separator: " · "))
                .font(.caption).foregroundStyle(StudioStyle.muted)
            Button {
                do {
                    let item = try library.export(take)
                    exportedDirectory = item.url.deletingLastPathComponent()
                    export = item
                } catch { message = "Video could not be exported." }
            } label: { Label(tr("Download video"), systemImage: "square.and.arrow.down") }.buttonStyle(StudioPrimary())
        }
    }
    private var preview: some View {
        Color.black.aspectRatio(9.0/16.0, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let videoRect = AVMakeRect(aspectRatio: filmSize, insideRect: CGRect(origin: .zero, size: geo.size))
                    ZStack {
                        StudioVideoSurface(player: player)
                        if cropping {
                            let rect = crop.rect(in: videoRect.size).offsetBy(dx: videoRect.minX, dy: videoRect.minY)
                            Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(rect) }
                                .fill(.black.opacity(0.49), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                            StudioCorners().stroke(StudioStyle.mint, lineWidth: 2).frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                            Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                let original = dragOrigin ?? crop
                                dragOrigin = original
                                let start = original.rect(in: videoRect.size)
                                let cx = (start.midX + value.translation.width) / max(1, videoRect.width)
                                let cy = (start.midY + value.translation.height) / max(1, videoRect.height)
                                crop.center = CGPoint(x: max(0, min(1, cx)), y: max(0, min(1, cy)))
                            }.onEnded { _ in dragOrigin = nil })
                            .accessibilityLabel(tr("Crop position"))
                            .accessibilityAction(named: tr("Move left")) { crop.center.x = max(0, crop.center.x - 0.05) }
                            .accessibilityAction(named: tr("Move right")) { crop.center.x = min(1, crop.center.x + 0.05) }
                            .accessibilityAction(named: tr("Move up")) { crop.center.y = max(0, crop.center.y - 0.05) }
                            .accessibilityAction(named: tr("Move down")) { crop.center.y = min(1, crop.center.y + 0.05) }
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) { StudioBadge(title: cropping ? tr("Frame grab") : tr("Playback"), icon: cropping ? "crop" : "play.rectangle").padding(7).allowsHitTesting(false) }
            .overlay(alignment: .bottom) {
                if !cropping { VStack(spacing: 4) {
                    Text(verbatim: studioTime(position) + " / " + studioTime(take.duration)).font(.caption2.monospacedDigit())
                    HStack(spacing: 12) {
                        Button { togglePlayback() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.accessibilityLabel(playing ? tr("Pause") : tr("Play"))
                        Button { full = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44) }.accessibilityLabel(tr("Fullscreen"))
                    }
                }.padding(3).background(.black.opacity(0.63), in: RoundedRectangle(cornerRadius: 10)).padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(StudioStyle.edge) }
    }
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cropping ? tr("Frame") : tr("Timeline")).font(.headline)
            HStack { Text(verbatim: studioTime(position)); Spacer(); Text(verbatim: studioTime(take.duration)) }
                .font(.caption2.monospacedDigit()).foregroundStyle(StudioStyle.muted)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    StudioStyle.panel
                    HStack(spacing: 1) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image).resizable().scaledToFill().frame(width: (w - 5) / 6, height: 46).clipped()
                        }
                    }
                    Capsule().fill(StudioStyle.mint).frame(width: 4).offset(x: (w - 4) * min(1, position / take.duration))
                }.clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { seek(take.duration * $0.location.x / max(1, w)) })
                    .accessibilityElement(children: .ignore).accessibilityLabel(tr("Clip position")).accessibilityValue(studioTime(position))
                    .accessibilityAdjustableAction { direction in seek(position + (direction == .increment ? 0.25 : -0.25)) }
            }.frame(height: 46)
            if !take.marks.isEmpty { ScrollView(.horizontal) {
                HStack { ForEach(Array(take.marks.enumerated()), id: \.offset) { _, mark in
                    Button { seek(mark) } label: { Label(studioTime(mark), systemImage: "diamond.fill").font(.caption.monospacedDigit()).padding(.horizontal, 10).frame(minHeight: 44) }
                        .background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 7))
                } }
            }.scrollIndicators(.hidden) }
        }
    }
    private func actionRow(_ name: String, _ symbol: String, _ detail: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 38, height: 38).background(StudioStyle.panel, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) { Text(verbatim: name).font(.subheadline.bold()); Text(verbatim: detail).font(.caption).foregroundStyle(StudioStyle.muted) }
            Spacer(); Image(systemName: "chevron.right").font(.caption)
        }.frame(minHeight: 48).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
    private func prepare() async {
        let url = library.url(for: take)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if let observer { player.removeTimeObserver(observer) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { time in
            Task { @MainActor in
                if player.timeControlStatus == .playing { position = min(take.duration, max(0, time.seconds)) }
                if time.seconds >= take.duration - 0.05 { playing = false }
            }
        }
        thumbnails = []
        for fraction in [0.02,0.18,0.36,0.54,0.73,0.93] {
            guard !Task.isCancelled else { return }
            if let cg = try? await StudioMovieMedia.frame(url, at: fraction * take.duration, maxSize: 190) {
                filmSize = CGSize(width: cg.width, height: cg.height)
                thumbnails.append(UIImage(cgImage: cg))
            }
        }
    }
    private func seek(_ seconds: Double) {
        player.pause(); playing = false
        position = max(0, min(take.duration - min(0.045, take.duration / 2), seconds))
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func togglePlayback() {
        if playing { player.pause(); playing = false }
        else { if position >= take.duration - 0.15 { seek(0) }; player.play(); playing = true }
    }
    private func extract() {
        guard !busy else { return }
        busy = true; message = nil
        let url = library.url(for: take), seconds = position, box = crop
        Task {
            defer { busy = false }
            do {
                let cg = try await StudioMovieMedia.frame(url, at: seconds)
                let photo = await Task.detached(priority: .userInitiated) { () -> CapturePhoto? in
                    let rect = box.rect(in: CGSize(width: cg.width, height: cg.height))
                    guard let cut = cg.cropping(to: rect.integral), let data = UIImage(cgImage: cut).jpegData(compressionQuality: 0.96) else { return nil }
                    return capturePhoto(data)
                }.value
                guard let photo else { throw CocoaError(.fileReadCorruptFile) }
                try useFrame(photo)
            } catch StoreError.invalidResult { message = "Finish your current card before grabbing another front." }
            catch { message = "Frame could not be saved. Try another frame." }
        }
    }
}
