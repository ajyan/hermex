@preconcurrency import AVFoundation
import CryptoKit
import SwiftUI
import UIKit
import os

/// Where a server's story videos live on the phone: Application Support/Stories/<server key>/<date>.mov,
/// out of Photos and excluded from backups, one telling per day (a retake replaces it). Keyed by server, so a
/// second configured server never shows the first one's tellings.
struct StoryVideoStore {
    let server: URL
    /// How long a telling stays on the phone after its day. The Sunday pick keeps the best one on the Mac.
    /// Eight, so a review done the Monday after still finds last Monday's telling.
    static let keepDays = 8

    private var folder: URL {
        let key = SHA256.hash(data: Data(server.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Stories/\(key)", directoryHint: .isDirectory)
    }

    func url(for date: String) -> URL { folder.appending(path: "\(date).mov") }

    /// A day's telling and when it was last written (a retake keeps the path, so views key on both).
    struct Telling: Equatable {
        let url: URL
        let modified: Date
    }

    func video(for date: String) -> Telling? {
        let url = url(for: date)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate else { return nil }
        return Telling(url: url, modified: modified)
    }

    /// Moves a finished recording into place, replacing the day's earlier take, then deletes other tellings
    /// older than `keepDays`.
    func save(_ recording: URL, for date: String, today: Date = .now) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        var folderURL = folder
        try? folderURL.setResourceValues(noBackup)
        let target = url(for: date)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: recording)
        } else {
            try fm.moveItem(at: recording, to: target)
        }
        prune(today: today, keeping: date)
        return target
    }

    /// Holds a telling past `keepDays` while it is on its way to the Mac (a marker file beside it).
    func markKeeping(_ date: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appending(path: "\(date).keep").path, contents: nil)
    }

    func unmarkKeeping(_ date: String) {
        try? FileManager.default.removeItem(at: folder.appending(path: "\(date).keep"))
    }

    func isKeeping(_ date: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "\(date).keep").path)
    }

    /// Deletes tellings dated more than `keepDays` before `today`, never `keeping` (the day just saved or shown)
    /// and never one still on its way to the Mac, unless that upload has waited a month.
    func prune(today: Date = .now, keeping: String? = nil) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.keepDays, to: today) ?? today
        let giveUp = Calendar.current.date(byAdding: .day, value: -30, to: today) ?? today
        let names = DateFormatter()
        names.calendar = Calendar(identifier: .gregorian)
        names.locale = Locale(identifier: "en_US_POSIX")
        names.dateFormat = "yyyy-MM-dd"
        for file in files where file.pathExtension == "mov" || file.pathExtension == "keep" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name != keeping, let day = names.date(from: name), day < cutoff else { continue }
            if isKeeping(name), day >= giveUp { continue }
            try? fm.removeItem(at: file)
        }
    }
}

/// The front camera and mic for one telling: a portrait, mirrored (as he saw himself), 720p movie that stops
/// itself at `limit`. The session runs on its own queue; state lands on the main actor.
@MainActor @Observable
final class StoryRecorder: NSObject {
    enum Phase: Equatable { case starting, ready, recording, denied, failed(String) }

    /// The cap on a telling. One minute for now; two later.
    static let limit: TimeInterval = 60

    private(set) var phase: Phase = .starting
    /// When the movie actually began (`didStartRecordingTo`), so the countdown matches the file.
    private(set) var startedAt: Date?
    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private let output = AVCaptureMovieFileOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.hermex.story-recorder")
    @ObservationIgnored private var finished: ((URL?) -> Void)?
    /// Set when the screen closes: a take in progress is thrown away and setup never starts the camera.
    @ObservationIgnored private let closed = OSAllocatedUnfairLock(initialState: false)
    private var isClosed: Bool { closed.withLock { $0 } }

    /// The running session for the preview, once set up.
    var previewSession: AVCaptureSession? { phase == .starting ? nil : session }

    func start() async {
        guard await Self.allowed(.video), await Self.allowed(.audio) else { phase = .denied; return }
        guard !isClosed else { return }
        let session = AVCaptureSession(), output = output
        self.session = session
        let problem: String? = await withCheckedContinuation { done in
            queue.async {
                done.resume(returning: Self.configure(session, output))
            }
        }
        guard !isClosed else { return }
        if let problem { phase = .failed(problem); return }
        let closed = closed
        queue.async {
            // Re-checked on the queue: a close while setting up must not leave the camera running.
            if !closed.withLock({ $0 }) { session.startRunning() }
        }
        phase = .ready
    }

    nonisolated private static func configure(_ session: AVCaptureSession, _ output: AVCaptureMovieFileOutput) -> String? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let cameraIn = try? AVCaptureDeviceInput(device: camera), session.canAddInput(cameraIn)
        else { return "The front camera isn't available." }
        session.addInput(cameraIn)
        if let mic = AVCaptureDevice.default(for: .audio), let micIn = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        guard session.canAddOutput(output) else { return "Recording isn't available." }
        session.addOutput(output)
        output.maxRecordedDuration = CMTime(seconds: limit, preferredTimescale: 600)
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                // Mirroring can't be set while the system adjusts it.
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            if output.availableVideoCodecTypes.contains(.hevc) {
                output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
        }
        return nil
    }

    /// Starts recording to a temporary file; `done` gets the file when it stops (by `stop()` or the cap), or nil.
    func record(_ done: @escaping (URL?) -> Void) {
        guard phase == .ready else { return }
        finished = done
        phase = .recording
        let file = FileManager.default.temporaryDirectory.appending(path: "story-\(UUID().uuidString).mov")
        let output = output
        queue.async { output.startRecording(to: file, recordingDelegate: self) }
    }

    func stop() {
        let output = output
        queue.async { if output.isRecording { output.stopRecording() } }
    }

    /// The screen is closing: discard any take in progress and turn the camera off.
    func close() {
        closed.withLock { $0 = true }
        finished = nil
        let output = output, session = session
        queue.async {
            if output.isRecording { output.stopRecording() }
            session?.stopRunning()
        }
    }

    private static func allowed(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: media)
        default: false
        }
    }

    private func finish(_ file: URL?) {
        startedAt = nil
        if !isClosed { phase = .ready }
        guard let done = finished else {
            // Closed mid-take: nothing keeps it.
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        finished = nil
        done(file)
    }
}

extension StoryRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in self.startedAt = .now }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // Hitting the cap reports an error but the movie is complete.
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        if !ok { try? FileManager.default.removeItem(at: url) }
        Task { @MainActor in self.finish(ok ? url : nil) }
    }
}

/// The recording screen: always dark, like the call, in the card's paper. The question and the picked
/// technique stay on top, the front camera fills the middle with a framing hint, and a ring counts the minute
/// down under the stop button (ticking once a second only while recording). Saving replaces the day's
/// telling; closing mid-take discards it.
struct StoryRecordView: View {
    let question: String?
    let kindLabel: String
    let technique: DeckStoryTechnique?
    let paper: HermexPaper
    let store: StoryVideoStore
    let date: String
    /// Called with the saved telling.
    let saved: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recorder = StoryRecorder()
    @State private var saveFailed = false

    var body: some View {
        VStack(spacing: 12) {
            header
            preview
            controls
        }
        .padding(.horizontal, 16)
        .background(Color.hxCanvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await recorder.start() }
        .onDisappear { recorder.close() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    recorder.close()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .frame(width: 44, height: 44)
                        .adaptiveGlass(.regular, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Close without saving a new take"))
                Spacer()
                Text(verbatim: kindLabel).font(AppFont.caption()).foregroundStyle(.hxSecondary)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            if let question {
                Text(verbatim: question)
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let technique {
                HStack(spacing: 8) {
                    HXChip(paper: paper, label: technique.name)
                    if let how = technique.how {
                        Text(verbatim: how).font(AppFont.footnote()).foregroundStyle(.hxSecondary).lineLimit(2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HXRadius.xl, style: .continuous).fill(Color.hxSurface)
            switch recorder.phase {
            case .denied:
                HXFailedView(title: "Camera and microphone are off",
                             message: "Turn them on for Atlas in Settings to record your story.", style: .inline) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            case .failed(let message):
                HXFailedView(title: "Couldn't start the camera", message: message, style: .inline) {
                    recorder = StoryRecorder()
                    Task { await recorder.start() }
                }
            default:
                if let session = recorder.previewSession {
                    StoryCameraPreview(session: session)
                        .clipShape(RoundedRectangle(cornerRadius: HXRadius.xl, style: .continuous))
                }
                if recorder.phase != .recording {
                    VStack {
                        Text(verbatim: "Keep your hands in the frame")
                            .font(AppFont.caption()).foregroundStyle(Color.hxTextPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .adaptiveGlass(.regular, in: Capsule())
                            .padding(.top, 12)
                        Spacer()
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: HXRadius.xl, style: .continuous).strokeBorder(Color.hxSeparator, lineWidth: 0.5))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if recorder.phase == .recording {
                TimelineView(.periodic(from: recorder.startedAt ?? .now, by: 1)) { context in
                    recordButton(left: remaining(at: context.date))
                }
            } else {
                recordButton(left: StoryRecorder.limit)
            }
            Text(verbatim: "Stops by itself at 1:00. Tap to stop sooner.")
                .font(AppFont.caption())
                .foregroundStyle(.hxSecondary)
        }
        .padding(.bottom, 12)
    }

    private func recordButton(left: Double) -> some View {
        let recording = recorder.phase == .recording
        return VStack(spacing: 8) {
            Button { toggle() } label: {
                ZStack {
                    Circle().stroke(paper.edge, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: left / StoryRecorder.limit)
                        .stroke(paper.glow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if recording {
                        RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous).fill(paper.glow).frame(width: 28, height: 28)
                    } else {
                        Circle().fill(paper.glow).frame(width: 60, height: 60)
                    }
                }
                .frame(width: 84, height: 84)
            }
            .buttonStyle(.plain)
            .disabled(recorder.phase != .ready && !recording)
            .accessibilityLabel(Text(verbatim: recording ? "Stop recording, \(Int(left)) seconds left" : "Start recording"))
            Text(verbatim: recording ? "\(Self.clock(left)) left" : saveFailed ? "Couldn't save that take. Try again." : "1:00")
                .font(AppFont.footnote())
                .foregroundStyle(saveFailed ? Color.hxWarning : Color.hxTextPrimary)
                .monospacedDigit()
        }
    }

    private func remaining(at now: Date) -> Double {
        guard let started = recorder.startedAt else { return StoryRecorder.limit }
        return max(0, StoryRecorder.limit - now.timeIntervalSince(started).rounded())
    }

    private func toggle() {
        if recorder.phase == .recording { recorder.stop(); return }
        saveFailed = false
        recorder.record { file in
            guard let file else { saveFailed = true; return }
            do {
                saved(try store.save(file, for: date))
                dismiss()
            } catch {
                try? FileManager.default.removeItem(at: file)
                saveFailed = true
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The live front camera, filling its frame.
private struct StoryCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    static func dismantleUIView(_ view: PreviewView, coordinator: Void) {
        view.previewLayer.session = nil
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // swiftlint:disable:next force_cast
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
