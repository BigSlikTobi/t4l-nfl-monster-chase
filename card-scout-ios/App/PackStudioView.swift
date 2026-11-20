import SwiftUI
import PhotosUI
import CardScoutCore
@preconcurrency import AVFoundation

private enum StudioSheet: String, Identifiable {
    case source, takes, tray, advanced, recent
    var id: String { rawValue }
}

struct PackStudioView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @State private var recorder = PackRecorder()
    @State private var camera = CaptureCamera(automatic: false)
    @State private var modeCard = false
    @State private var demo = AVCaptureDevice.authorizationStatus(for: .video) != .authorized || !Self.hasRearCamera
    @AppStorage("packStudioMicrophone") private var sound = false
    @State private var reviewing: PackTake?
    @State private var returnTake: PackTake?
    @State private var sheet: StudioSheet?
    @State private var back: CapturePhoto?
    @State private var retakeFront = false
    @State private var confirming = false
    @State private var demoFront: Data?
    @State private var demoBack = false
    @State private var demoGrab = false
    @State private var revision = UUID()
    @State private var backRevision = UUID()
    @State private var matchID: String?
    @AppStorage("packStudioPhotoSource") private var photosOnly = false
    @State private var pickingPhoto = false
    @State private var incomingPhoto: PhotosPickerItem?
    @State private var importing = false
    @State private var message: String?
    private static var hasRearCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }
    private var pair: OwnedCard? { store.pendingCapturePair }
    private var frontPresent: Bool { pair != nil || demoFront != nil }
    private var capturingBack: Bool { frontPresent && !retakeFront }
    private var busy: Bool { recorder.working || camera.saving || importing }
    private var recording: Bool { recorder.started != nil }
    private var drafts: [OwnedCard] { store.library.cards.filter { $0.isScanDraft == true } }
    private var wantCamera: Bool {
        store.selectedTab == 3 && phase == .active && !store.showSettings && reviewing == nil && sheet == nil && !confirming && matchID == nil
    }
    private var configuration: String { [String(wantCamera), String(modeCard), String(demo), String(sound), String(photosOnly)].joined(separator: "-") }

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 0) {
                brand
                if let reviewing {
                    PackStudioPlayback(take: reviewing, library: recorder.library, back: { self.reviewing = nil },
                                       didRename: { self.reviewing = $0 }, scan: {
                        returnTake = reviewing; self.reviewing = nil; modeCard = true
                        if !reviewing.demo { demo = false }; message = nil
                    }, useFrame: { frame in
                        if frontPresent { throw StoreError.invalidResult }
                        if reviewing.demo { demoGrab = true; demoFront = frame.front; revision = UUID(); demo = true }
                        else { _ = try store.beginCapturePair(frame); demo = false }
                        returnTake = reviewing; self.reviewing = nil; modeCard = true; confirming = true
                    }).id(reviewing.id)
                } else if confirming {
                    confirmCard
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            let available = max(225, viewport.size.height - 196)
                            captureStage.frame(width: min(viewport.size.width - 24, available * 9/16))
                            if !recording { modes }
                            RecentScanEntry(groups: RecentScanSet.groups(store.library), reviewCount: store.library.cards.filter { !$0.scanChecks.isEmpty }.count) { sheet = .recent }
                                .disabled(recording || busy)
                            if !recorder.library.takes.isEmpty && !recording && !modeCard {
                                Button { sheet = .takes } label: { Label(tr("Your videos"), systemImage: "film.stack").frame(minHeight: 44) }
                            }
                            if modeCard && capturingBack && !recording { capturedFrontRow }
                            if let returnTake, !recording, !busy {
                                Button { reviewing = returnTake; self.returnTake = nil } label: { Label(tr("Back to video"), systemImage: "arrow.left") }
                                    .font(.subheadline).frame(minHeight: 44)
                            }
                            if let error = message ?? camera.error ?? recorder.message ?? recorder.library.error {
                                Text(trDisplay(error)).font(.footnote).foregroundStyle(StudioStyle.mint)
                            }
                        }.padding(.horizontal, 12).padding(.bottom, 14).frame(maxWidth: .infinity)
                    }.scrollIndicators(.hidden)
                }
            }
        }
        .foregroundStyle(.white).tint(StudioStyle.mint).background(StudioStyle.room.ignoresSafeArea())
        .environment(\.colorScheme, .dark).toolbar(.hidden, for: .navigationBar)
        .onAppear { if pair != nil { modeCard = true; demo = false } }
        .task(id: configuration) { await configureCamera() }
        .onDisappear { camera.stop(); recorder.leaveCamera() }
        .onChange(of: recorder.latest?.id) { _, _ in if let latest = recorder.latest { reviewing = latest } }
        .task(id: recorder.started) {
            guard recorder.started != nil else { return }
            do { try await Task.sleep(for: .seconds(max(0, 60 - recorder.elapsed))) } catch { return }
            recorder.finish()
        }
        .sheet(item: $sheet) { item in
            NavigationStack {
                Group {
                    switch item {
                    case .source: sourceMenu
                    case .takes: takesList
                    case .tray: tray
                    case .advanced: FastScanView()
                    case .recent: RecentScansView()
                    }
                }.toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(tr("Schließen")) { sheet = nil } }
                }
            }.presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $incomingPhoto, matching: .images)
        .onChange(of: incomingPhoto) { _, item in if let item { Task { await importPhoto(item) } } }
        .sheet(isPresented: Binding(get: { matchID != nil }, set: { if !$0 { matchID = nil } })) {
            NavigationStack { if let matchID { ScanMatchView(cardID: matchID, onNext: { self.matchID = nil }).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Später")) { self.matchID = nil } }
            } } }
        }
    }
    private var brand: some View {
        CollectorHeader(settingsEnabled: !recording && !busy) {
            CollectorHeading(text: tr("Capture"))
        } actions: {
            Button { sheet = .tray } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tray")
                    Text(verbatim: String(drafts.count)).monospacedDigit()
                }.font(.subheadline.weight(.semibold)).fixedSize()
                    .padding(.horizontal, 12).frame(minHeight: 34)
                    .background(Color.scoutElevated, in: Capsule()).frame(minHeight: 44)
            }.accessibilityLabel(tr("Tray")).accessibilityValue(String(drafts.count))
                .accessibilityIdentifier("studio.tray").disabled(recording || busy)
        }
    }
    private var captureStage: some View {
        Color.black.aspectRatio(9.0/16, contentMode: .fit)
            .overlay { GeometryReader { geo in
                ZStack {
                    if demo {
                        if let player = recorder.demoPlayer { StudioVideoSurface(player: player) }
                        else if modeCard && capturingBack { StudioDemoCardBack(generic: demoGrab).frame(width: geo.size.width * 0.72) }
                        else { Image(modeCard ? "PackStudioSampleFront" : "PackStudioCover").resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped() }
                    } else if modeCard && photosOnly {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 40, weight: .light)).foregroundStyle(StudioStyle.muted)
                    } else if modeCard && camera.ready {
                        CameraPreview(session: camera.driver.session, frame: camera.detectedFrame, imageSize: camera.imageSize) { camera.driver.focus(at: $0) }
                    } else if !modeCard && recorder.ready {
                        StudioMoviePreview(session: recorder.camera.session)
                    } else {
                        Image(systemName: "camera").font(.system(size: 40, weight: .light)).foregroundStyle(StudioStyle.muted)
                    }
                    if modeCard {
                        StudioCorners().stroke(StudioStyle.mint, lineWidth: 2)
                            .frame(width: geo.size.width * 0.73, height: geo.size.width * 0.73 * 1.4).allowsHitTesting(false)
                    } else {
                        StudioCorners().stroke(StudioStyle.mint.opacity(0.55), lineWidth: 1)
                            .frame(width: geo.size.width * 0.83, height: geo.size.height * 0.60).allowsHitTesting(false)
                    }
                    LinearGradient(colors: [.black.opacity(0.25), .clear, .clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                }
            } }
            .overlay(alignment: .top) {
                HStack {
                    Button { sheet = .source } label: {
                        StudioBadge(title: recording ? tr("REC") : demo ? tr("Demo feed") : modeCard && photosOnly ? tr("Mediathek") : tr("Kamera"), dot: recording ? .red : StudioStyle.mint)
                    }.disabled(recording || busy).accessibilityLabel(tr("Camera source"))
                    Spacer()
                    StudioBadge(title: modeCard ? (capturingBack ? tr("Back side") : tr("Front")) : "9:16", icon: modeCard ? nil : "rectangle.portrait")
                }.padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if !demo && !recording && !busy {
                    if !modeCard {
                        Button { Task { await toggleMic() } } label: { Image(systemName: sound ? "mic.fill" : "mic.slash").frame(width: 44, height: 44).background(.black.opacity(0.66), in: Circle()) }
                            .padding(.top, 47).padding(.trailing, 8).accessibilityLabel(sound ? tr("Mute microphone") : tr("Enable microphone"))
                    } else if camera.torchAvailable {
                        Button { camera.driver.setTorch(!camera.torchOn) } label: { Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill").frame(width: 44, height: 44).background(.black.opacity(0.66), in: Circle()) }
                            .padding(.top, 47).padding(.trailing, 8).accessibilityLabel(tr("Handy-Lampe einschalten"))
                    }
                }
            }
            .overlay(alignment: .bottom) { dock }
            .clipShape(RoundedRectangle(cornerRadius: 16)).overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(StudioStyle.edge) }
    }
    private var dock: some View {
        VStack(spacing: 4) {
            if let started = recorder.started {
                TimelineView(.periodic(from: started, by: 0.2)) { context in StudioBadge(title: studioTime(context.date.timeIntervalSince(started)), dot: .red) }
            }
            HStack(alignment: .bottom, spacing: 0) {
                Group {
                    if recording { Color.clear.frame(width: 48, height: 44) }
                    else if modeCard && capturingBack {
                        dockAction("arrow.counterclockwise", tr("Retake front")) { retakeFront = true }
                    } else {
                        Button { reviewing = recorder.library.takes.first ?? recorder.library.sample } label: {
                            VStack(spacing: 4) {
                                if let take = recorder.library.takes.first { StudioTakeThumb(take: take, library: recorder.library).frame(width: 34, height: 46) }
                                else { Image("PackStudioCover").resizable().scaledToFill().frame(width: 34, height: 46).clipped().clipShape(RoundedRectangle(cornerRadius: 5)) }
                                Text(recorder.library.takes.isEmpty ? tr("Demo take") : tr("Last take")).font(.caption2.bold())
                            }
                        }.disabled(busy)
                    }
                }.frame(maxWidth: .infinity)
                Button {
                    if modeCard { takePhoto() }
                    else if recording { recorder.finish() }
                    else { recorder.record(demo: demo) }
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 3).frame(width: 62, height: 62)
                            if recording { RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 23, height: 23) }
                            else { Circle().fill(modeCard ? Color.white : Color(red: 0.99, green: 0.28, blue: 0.23)).frame(width: 50, height: 50) }
                            if busy { ProgressView().tint(.black) }
                        }
                        Text(modeCard ? (capturingBack ? tr("Capture back") : tr("Capture front")) : (recording ? tr("Stop") : tr("Record"))).font(.caption.bold())
                    }
                }.disabled(busy || (!demo && !(modeCard ? (photosOnly || camera.ready) : recorder.ready)))
                    .accessibilityIdentifier("studio.shutter").frame(maxWidth: .infinity)
                Group {
                    if recording { dockAction("bookmark", tr("Mark pull") + (recorder.marks.isEmpty ? "" : " · " + String(recorder.marks.count))) { recorder.mark() } }
                    else { dockAction("camera", tr("Source")) { sheet = .source } }
                }.disabled(busy).frame(maxWidth: .infinity)
            }
        }.padding(.bottom, 14)
    }
    private func dockAction(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 4) {
            Image(systemName: symbol).frame(width: 44, height: 44).background(.black.opacity(0.55), in: Circle()).overlay { Circle().strokeBorder(StudioStyle.edge) }
            Text(verbatim: label).font(.caption2.bold()).lineLimit(2)
        } }
    }
    private var modes: some View {
        HStack(spacing: 3) {
            modeButton(false, tr("Pack video"), "video")
            modeButton(true, tr("Card scan"), "viewfinder")
        }.frame(maxWidth: 450).padding(4).background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(StudioStyle.edge) }.disabled(busy)
    }
    private func modeButton(_ card: Bool, _ label: String, _ symbol: String) -> some View {
        Button { modeCard = card; if card && pair != nil { demo = false }; message = nil; camera.error = nil } label: {
            Label(label, systemImage: symbol).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 42)
                .background(card == modeCard ? Color(red: 0.19, green: 0.27, blue: 0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.accessibilityAddTraits(modeCard == card ? .isSelected : []).accessibilityIdentifier(card ? "studio.cardscan" : "studio.packvideo")
    }
    private var capturedFrontRow: some View {
        HStack {
            frontPhoto.frame(width: 39, height: 54)
            Text(tr("Vorderseite")).font(.caption.bold())
            Spacer()
            if pair?.captureMode != ScanCaptureMode.stack.rawValue {
                Button(tr("Ohne Rückseite weiter")) { confirming = true }.font(.subheadline.weight(.semibold))
            }
        }.frame(maxWidth: 450).padding(.horizontal, 4)
    }
    @ViewBuilder private var frontPhoto: some View {
        if let demoFront {
            draftPhoto(demoFront, revision: revision, side: tr("Vorderseite"))
        } else if let pair { OwnedPhoto(name: pair.frontFile, maxPixel: 850, original: true) }
    }
    private func draftPhoto(_ bytes: Data, revision: UUID, side: String) -> some View {
        StableImage(request: .preview(bytes, revision: revision)) { photo, loading in
            ZStack {
                Color.black.opacity(0.3)
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFit().accessibilityLabel(side)
                        .accessibilityIdentifier("studio.review.loadedPhoto")
                } else if loading { ProgressView().tint(StudioStyle.mint) }
                else { Image(systemName: "photo").foregroundStyle(StudioStyle.muted) }
            }
        }
    }
    private var confirmCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                frontPhoto.frame(height: 265).frame(maxWidth: .infinity)
                Text(tr("Review card")).font(.system(size: 30, weight: .black)).fontWidth(.condensed).italic()
                HStack(alignment: .top, spacing: 12) {
                    sideTile(tr("Vorderseite"), retake: { confirming = false; back = nil; demoBack = false; retakeFront = true }) { frontPhoto }
                    sideTile(tr("Rückseite"), retake: { confirming = false; back = nil; demoBack = false; retakeFront = false }) {
                        if demoBack { StudioDemoCardBack(generic: demoGrab) }
                        else if let back { draftPhoto(back.front, revision: backRevision, side: tr("Rückseite")) }
                        else { Image(systemName: "plus.viewfinder").font(.title2).foregroundStyle(StudioStyle.muted) }
                    }
                }
                Button { analyze() } label: { Label(tr("Analyze card"), systemImage: "viewfinder") }
                    .buttonStyle(StudioPrimary()).accessibilityIdentifier("studio.analyze")
                if let message { Text(trDisplay(message)).font(.footnote).foregroundStyle(StudioStyle.mint) }
            }.padding(16)
        }
    }
    private func sideTile<V: View>(_ title: String, retake: @escaping () -> Void, @ViewBuilder image: () -> V) -> some View {
        Button(action: retake) { VStack(alignment: .leading, spacing: 5) {
            image().frame(height: 86).frame(maxWidth: .infinity).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Label(title, systemImage: "camera.rotate").font(.caption)
        } }.buttonStyle(.plain)
    }
    private var sourceMenu: some View {
        List {
            Button { guard !frontPresent || demoFront == nil else { message = "Finish the demo card before switching sources."; sheet = nil; return }; demo = false; photosOnly = false; sheet = nil } label: { Label(tr("Device camera"), systemImage: "camera") }
            if pair == nil {
                Button { demo = true; sheet = nil } label: { Label(tr("Demo feed"), systemImage: "play.rectangle") }
            }
            if modeCard && demoFront == nil {
                let photosTitle = tr("Mediathek")
                PhotosPicker(selection: $incomingPhoto, matching: .images) { Label(photosTitle, systemImage: "photo.on.rectangle") }
            }
            Button { sheet = .advanced } label: { Label(tr("Stack scan & imports"), systemImage: "rectangle.stack") }
        }.navigationTitle(tr("Camera source")).navigationBarTitleDisplayMode(.inline)
    }
    private var takesList: some View {
        List(recorder.library.takes + [recorder.library.sample]) { take in
            Button { reviewing = take; sheet = nil } label: {
                HStack(spacing: 12) {
                    StudioTakeThumb(take: take, library: recorder.library).frame(width: 41, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: take.name).font(.headline)
                        Text(verbatim: studioTime(take.duration) + " · " + (take.demo ? tr("Demo footage") : tr("Pack video"))).font(.caption).foregroundStyle(StudioStyle.muted)
                    }
                    Spacer(); Image(systemName: "play.fill")
                }
            }
        }.navigationTitle(tr("Your videos")).navigationBarTitleDisplayMode(.inline)
    }
    private var tray: some View {
        List {
            if drafts.isEmpty { Text(tr("Noch keine Scans")).foregroundStyle(.secondary) }
            ForEach(drafts) { card in
                Button {
                    sheet = nil
                    if card.awaitingBack == true { modeCard = true; demo = false; reviewing = nil; confirming = false }
                    else { matchID = card.id }
                } label: {
                    HStack { OwnedPhoto(name: card.frontFile, maxPixel: 180, original: true).frame(width: 38, height: 52)
                        VStack(alignment: .leading) { Text(cardTitle(card)).font(.headline)
                            Text(trDisplay(card.awaitingBack == true ? "Rückseite fehlt" : card.isAwaitingAnalysis ? "In Arbeit" : "Treffer prüfen")).font(.caption) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }
                }
            }
        }.navigationTitle(tr("Tray")).navigationBarTitleDisplayMode(.inline)
    }
    private func configureCamera() async {
        camera.stop()
        recorder.leaveCamera()
        guard wantCamera else { return }
        if modeCard, let pair, let session = pair.captureSessionID { store.captureSessionID = session }
        guard !demo else { return }
        if modeCard {
            if photosOnly { return }
            guard Self.hasRearCamera else { message = "Camera unavailable. Choose a photo or the demo feed."; return }
            camera.save = { photo in
                guard wantCamera && modeCard && !demo else { throw StoreError.invalidResult }
                try receive(photo)
            }
            await camera.start()
        } else {
            guard Self.hasRearCamera else { message = "Camera unavailable. Choose a photo or the demo feed."; return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            guard granted else { message = "Kamerazugriff in den iPhone-Einstellungen erlauben."; return }
            if sound {
                let microphone = await AVCaptureDevice.requestAccess(for: .audio)
                guard !Task.isCancelled else { return }
                if !microphone { sound = false; return }
            }
            let ready = await recorder.camera.start(sound: sound)
            guard !Task.isCancelled else { return }
            recorder.ready = ready
            message = ready ? nil : "Kamera nicht verfügbar."
        }
    }
    private func toggleMic() async {
        if sound { sound = false; return }
        if await AVCaptureDevice.requestAccess(for: .audio) { sound = true; message = nil }
        else { message = "Allow microphone access in Settings to record sound." }
    }
    private func takePhoto() {
        message = nil
        if !demo { if photosOnly { pickingPhoto = true } else { camera.capture() }; return }
        if capturingBack { demoBack = true; confirming = true }
        else if let data = UIImage(named: "PackStudioSampleFront")?.jpegData(compressionQuality: 0.94) {
            demoGrab = false; demoFront = data; revision = UUID(); retakeFront = false
        }
    }
    private func receive(_ photo: CapturePhoto) throws {
        if retakeFront, let pair {
            try store.replacePendingFront(pair.id, with: photo); retakeFront = false
        } else if pair != nil {
            back = photo; backRevision = UUID(); confirming = true
        } else { _ = try store.beginCapturePair(photo); retakeFront = false }
        message = nil
    }
    private func importPhoto(_ item: PhotosPickerItem) async {
        guard !importing else { return }
        importing = true
        defer { incomingPhoto = nil; importing = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let photo = await Task.detached(priority: .userInitiated, operation: { capturePhoto(data) }).value else { throw StoreError.missingFront }
            guard demoFront == nil else { throw StoreError.invalidResult }
            demo = false; photosOnly = true
            try receive(photo); sheet = nil
        } catch { message = "Foto konnte nicht gelesen werden."; sheet = nil }
    }
    private func analyze() {
        if demoFront != nil {
            message = "Demo card. Scan or import your own card for analysis."
            confirming = false; demoFront = nil; demoBack = false; back = nil; modeCard = true; retakeFront = false
            return
        }
        guard let pair else { return }
        do {
            try store.finishCapturePair(pair.id, back: back?.front, text: back?.text)
            back = nil; confirming = false; retakeFront = false; modeCard = true; message = nil
            message = "Analyzing card · See Recent scans"
        } catch { message = "Fotos konnten nicht gespeichert werden. Bitte erneut versuchen." }
    }
}

private struct StudioTakeThumb: View {
    let take: PackTake
    let library: PackTakeLibrary
    @State private var frame: UIImage?
    var body: some View {
        GeometryReader { g in
            Group {
                if let frame { Image(uiImage: frame).resizable().scaledToFill() }
                else if take.demo { Image("PackStudioCover").resizable().scaledToFill() }
                else { Color.black.overlay { Image(systemName: "play.rectangle") } }
            }.frame(width: g.size.width, height: g.size.height).clipped()
        }.clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: take.id) {
            frame = nil
            if !take.demo, let cg = try? await StudioMovieMedia.frame(library.url(for: take), at: 0, maxSize: 180) { frame = UIImage(cgImage: cg) }
        }
    }
}

private struct StudioDemoCardBack: View {
    let generic: Bool
    var body: some View {
        Color(red: 0.88, green: 0.86, blue: 0.72).aspectRatio(5.0 / 7, contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    artwork.frame(width: 240, height: 336)
                        .scaleEffect(min(g.size.width / 240, g.size.height / 336))
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                }
            }.clipped().accessibilityLabel(tr("Rückseite"))
    }
    private var artwork: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: "Tackle4Loss\nBURNCOUNT Football").font(.system(size: 15, weight: .heavy).italic())
                .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(StudioStyle.panel)
            Text(verbatim: generic ? "BURNCOUNT" : "RIVER HAYES").font(.system(size: 24, weight: .black))
            if !generic { Text(verbatim: "QUARTERBACK   ·   #11").font(.system(size: 11, design: .monospaced)) }
            ForEach(0..<4, id: \.self) { _ in Rectangle().fill(.black.opacity(0.2)).frame(height: 1) }
            Spacer(minLength: 0)
            Text(verbatim: "DEMO  /  CARD BACK").font(.system(size: 8, design: .monospaced))
        }.padding(12).foregroundStyle(StudioStyle.room)
    }
}
