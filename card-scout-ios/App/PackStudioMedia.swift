import Foundation
import SwiftUI
@preconcurrency import AVFoundation
import AVKit
import CardScoutCore

struct PackTake: Identifiable, Codable {
    let id: UUID
    var name: String
    let created: Date
    let duration: Double
    let marks: [Double]
    let demo: Bool
    let ext: String

    static let sample = PackTake(id: UUID(uuidString: "B4690B88-FBAC-4BCC-B189-870939191A6A")!,
                                 name: "The first rip", created: .distantPast, duration: 9,
                                 marks: [3.6, 6.7], demo: true, ext: "mp4")
    static func cleanName(_ value: String) -> String {
        String(value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(64))
    }
    var exportName: String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let sanitized = name.components(separatedBy: unsafe).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return (sanitized.isEmpty ? "Pack opening" : sanitized) + "." + ext
    }
}

struct StudioExport: Identifiable {
    let id = UUID()
    let url: URL
}

struct StudioFilePicker: UIViewControllerRepresentable {
    let export: StudioExport
    let finished: () -> Void
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [export.url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

@MainActor @Observable final class PackTakeLibrary {
    private(set) var takes: [PackTake] = []
    private(set) var sample = PackTake.sample
    var error: String?
    private let root: URL

    init() {
        root = URL.applicationSupportDirectory.appending(path: "PackStudio", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for directory in files {
                let manifest = directory.appending(path: "take.json")
                guard let bytes = try? Data(contentsOf: manifest),
                      let take = try? JSONDecoder().decode(PackTake.self, from: bytes),
                      directory.lastPathComponent == take.id.uuidString,
                      ["mov","mp4"].contains(take.ext), take.duration.isFinite, take.duration > 0,
                      take.id != PackTake.sample.id, FileManager.default.fileExists(atPath: url(for: take).path) else { continue }
                takes.append(take)
            }
            takes.sort { $0.created > $1.created }
            if let sampleName = try? String(contentsOf: root.appending(path: "sample-title.txt"), encoding: .utf8),
               !PackTake.cleanName(sampleName).isEmpty { sample.name = PackTake.cleanName(sampleName) }
        } catch { self.error = "Videos unavailable" }
    }

    private func directory(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func url(for take: PackTake) -> URL {
        if take.id == PackTake.sample.id { return Bundle.main.url(forResource: "PackStudioDemo", withExtension: "mp4")! }
        return directory(take.id).appending(path: "video." + take.ext)
    }
    func saveRecording(_ temporary: URL, marks: [Double], demo: Bool) async throws -> PackTake {
        let duration = try await AVURLAsset(url: temporary).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let day = Date().formatted(.dateTime.weekday(.wide).locale(Locale(identifier: ScoutLocalization.language)))
        let number = String(format: "%02d", takes.filter { Calendar.current.isDateInToday($0.created) }.count + 1)
        let take = PackTake(id: UUID(), name: tr("\(day) pack rip \(number)"), created: Date(), duration: duration,
                            marks: marks.filter { $0 >= 0 && $0 < duration }, demo: demo, ext: temporary.pathExtension)
        let dir = directory(take.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: temporary, to: url(for: take))
            try write(take)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        takes.insert(take, at: 0)
        return take
    }
    func rename(_ take: PackTake, to name: String) throws -> PackTake {
        let clean = PackTake.cleanName(name)
        guard !clean.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        var renamed = take
        renamed.name = clean
        if take.id == PackTake.sample.id {
            try Data(clean.utf8).write(to: root.appending(path: "sample-title.txt"), options: .atomic)
            sample = renamed
        } else {
            try write(renamed)
            if let i = takes.firstIndex(where: { $0.id == take.id }) { takes[i] = renamed }
        }
        return renamed
    }
    private func write(_ take: PackTake) throws {
        try JSONEncoder().encode(take).write(to: directory(take.id).appending(path: "take.json"),
                                             options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func export(_ take: PackTake) throws -> StudioExport {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PackExport-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: take.exportName)
        do { try FileManager.default.linkItem(at: url(for: take), to: target) }
        catch { try FileManager.default.copyItem(at: url(for: take), to: target) }
        return StudioExport(url: target)
    }
}


func studioTime(_ seconds: Double) -> String {
    let whole = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%02d:%02d", whole / 60, whole % 60)
}

enum StudioMovieMedia {
    static func frame(_ url: URL, at seconds: Double, maxSize: CGFloat = 1800) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
    static func demoRecording(_ source: URL, duration: Double) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        let span = try await asset.load(.duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              span.seconds.isFinite, span.seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
        track.preferredTransform = try await video.load(.preferredTransform)
        let end = CMTime(seconds: max(0.3, min(60, duration)), preferredTimescale: 600)
        var cursor = CMTime.zero
        while cursor < end {
            let length = CMTimeMinimum(span, end - cursor)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: video, at: cursor)
            cursor = cursor + length
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.fileWriteUnknown) }
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        exporter.outputURL = url
        exporter.outputFileType = .mp4
        await exporter.export()
        guard exporter.status == .completed else { throw exporter.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}

struct StudioVideoSurface: UIViewRepresentable {
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var video: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    let player: AVPlayer
    func makeUIView(context: Context) -> Surface { let view = Surface(); view.video.videoGravity = .resizeAspect; return view }
    func updateUIView(_ view: Surface, context: Context) { view.video.player = player }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.video.player = nil }
}

struct StudioMoviePreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewSurface { let v = PreviewSurface(); v.preview.session = session; v.preview.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ view: PreviewSurface, context: Context) {
        if let connection = view.preview.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}

final class StudioMovieCamera: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "cardscout.packstudio.movie", qos: .userInitiated)
    private var configured = false
    private var audioInput: AVCaptureDeviceInput?
    var didStart: (@Sendable () -> Void)?
    var didFinish: (@Sendable (URL, Bool) -> Void)?

    func start(sound: Bool) async -> Bool {
        await withCheckedContinuation { continuation in queue.async { [self] in
            session.beginConfiguration()
            if !configured {
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input),
                      session.canAddOutput(movie) else { session.commitConfiguration(); continuation.resume(returning: false); return }
                if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                session.addInput(input)
                session.addOutput(movie)
                if let connection = movie.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                movie.maxRecordedDuration = CMTime(seconds: 60, preferredTimescale: 600)
                configured = true
            }
            if sound, audioInput == nil, let device = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input); audioInput = input
            } else if !sound, let input = audioInput { session.removeInput(input); audioInput = nil }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            continuation.resume(returning: session.isRunning)
        } }
    }
    func record(at url: URL) {
        queue.async { [self] in
            guard session.isRunning, !movie.isRecording else { didFinish?(url, false); return }
            movie.startRecording(to: url, recordingDelegate: self)
        }
    }
    func finish() { queue.async { [self] in if movie.isRecording { movie.stopRecording() } } }
    func stop() { queue.async { [self] in
        if movie.isRecording { movie.stopRecording() }
        if session.isRunning { session.stopRunning() }
    } }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) { didStart?() }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let success = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        didFinish?(fileURL, success)
    }
}

@MainActor @Observable final class PackRecorder {
    let camera = StudioMovieCamera()
    let library = PackTakeLibrary()
    var ready = false
    var working = false
    var started: Date?
    var marks: [Double] = []
    var latest: PackTake?
    var message: String?
    var demoPlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var practicing = false

    init() {
        camera.didStart = { [weak self] in Task { @MainActor in self?.started = Date(); self?.working = false } }
        camera.didFinish = { [weak self] file, success in Task { @MainActor in
            guard let self else { return }
            self.started = nil; self.working = true
            if success { await self.keep(file, demo: false) }
            else { self.working = false; self.message = "Video recording failed. Please try again." }
        } }
    }
    var elapsed: Double { started.map { max(0, min(60, Date().timeIntervalSince($0))) } ?? 0 }
    func mark() {
        guard started != nil else { return }
        let stamp = elapsed
        if marks.last.map({ stamp - $0 < 0.25 }) != true { marks.append(stamp); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
    func record(demo: Bool) {
        guard started == nil, !working, demo || ready else { return }
        marks = []; message = nil; practicing = demo
        if demo {
            let item = AVPlayerItem(url: library.url(for: library.sample))
            let queue = AVQueuePlayer(); queue.isMuted = true
            looper = AVPlayerLooper(player: queue, templateItem: item); demoPlayer = queue
            queue.play(); started = Date()
        } else {
            working = true
            camera.record(at: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov"))
        }
    }
    func finish() {
        guard let started, !working else { return }
        working = true
        if practicing {
            let length = Date().timeIntervalSince(started)
            self.started = nil
            demoPlayer?.pause(); demoPlayer = nil; looper = nil
            Task {
                do {
                    let file = try await StudioMovieMedia.demoRecording(library.url(for: library.sample), duration: length)
                    await keep(file, demo: true)
                } catch { working = false; message = "Video recording failed. Please try again." }
            }
        } else { camera.finish() }
    }
    func leaveCamera() {
        if started != nil { finish() }
        ready = false
        camera.stop()
    }
    private func keep(_ file: URL, demo: Bool) async {
        defer { working = false }
        do {
            latest = try await library.saveRecording(file, marks: marks, demo: demo)
            try? FileManager.default.removeItem(at: file)
        } catch { message = "Video could not be saved. Check available storage." }
    }
}
