import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import CrtCore

extension AppState {

    private static let recentSourcesKey = "ntscrt.recentSourcePaths"

    var recentSourceURLs: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentSourcesKey) ?? []
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func recordRecentSource(_ url: URL) {
        // Ignore temp clipboard paste files in recents.
        if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentSourcesKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > 8 { paths = Array(paths.prefix(8)) }
        UserDefaults.standard.set(paths, forKey: Self.recentSourcesKey)
    }

    func loadBundledSample(_ filename: String) {
        guard let url = Paths.bundledTestAsset(named: filename) else { return }
        sourceURL = url
    }

    // MARK: - Clipboard Paste (`⌘V`) & Copy Frame (`⌘C`)

    @discardableResult
    func pasteSourceFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let first = urls.first {
            sourceURL = first
            return true
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = images.first,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("ntscrt-pasted-\(Int(Date().timeIntervalSince1970)).png")
            do {
                try png.write(to: out)
                sourceURL = out
                return true
            } catch {
                return false
            }
        }
        return false
    }

    func copyRenderedFrameToClipboard() {
        guard hasSourcePicture else { return }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntscrt-copy-\(UUID().uuidString).png")
        exportPNG(to: out, size: exportVideoSize) { ok in
            defer { try? FileManager.default.removeItem(at: out) }
            guard ok, let img = NSImage(contentsOf: out) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
        }
    }

    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                if let url {
                    DispatchQueue.main.async { self?.sourceURL = url }
                }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { [weak self] obj, _ in
                guard let img = obj as? NSImage,
                      let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ntscrt-dropped-\(UUID().uuidString).png")
                if (try? png.write(to: out)) != nil {
                    DispatchQueue.main.async { self?.sourceURL = out }
                }
            }
            return true
        }
        return false
    }

    // MARK: - Synchronized Preview Audio (`AVPlayer` audio-only track)

    static let isHeadlessTestRun: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env.keys.contains { $0.hasPrefix("CRT_") && $0 != "CRT_PRESETS" && $0 != "CRT_LIBRASHADER" && $0 != "CRT_NTSCRS" }
    }()

    @MainActor
    func setUpPreviewAudio(for vs: VideoSource) async {
        tearDownPreviewAudio()
        guard !Self.isHeadlessTestRun else { return }
        let audioTracks = (try? await vs.asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else { return }

        let item = AVPlayerItem(asset: vs.asset)
        // Disable video tracks on AVPlayerItem so AVPlayer decodes audio ONLY,
        // avoiding duplicate H.264/ProRes video decode alongside PlaybackPipeline.
        let player = AVPlayer(playerItem: item)
        player.isMuted = previewAudioMuted
        player.actionAtItemEnd = .pause
        previewAudioPlayer = player
        hasVideoAudioTrack = true

        Task { @MainActor [weak self] in
            // Once item tracks populate, disable video decoding on the audio player.
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, self.previewAudioPlayer === player else { return }
            for track in item.tracks where track.assetTrack?.mediaType == .video {
                track.isEnabled = false
            }
        }
    }

    func tearDownPreviewAudio() {
        previewAudioPlayer?.pause()
        previewAudioPlayer = nil
        hasVideoAudioTrack = false
    }

    func syncPreviewAudioPlay(atFrame frame: Int) {
        guard let player = previewAudioPlayer, let vs = videoSource else { return }
        player.isMuted = previewAudioMuted
        let secs = Double(frame) / Double(max(1, vs.frameRate))
        let target = CMTime(seconds: secs, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            if self.videoPlaying { player.play() }
        }
    }

    func syncPreviewAudioPause() {
        previewAudioPlayer?.pause()
    }

    func syncPreviewAudioSeek(toFrame frame: Int) {
        guard let player = previewAudioPlayer, let vs = videoSource else { return }
        let secs = Double(frame) / Double(max(1, vs.frameRate))
        let target = CMTime(seconds: secs, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Timeline Keyboard Navigation

    func stepToAdjacentKeyframe(forward: Bool) {
        guard timelineEnabled, !timelineKeys.isEmpty else { return }
        let sorted = timelineKeys.sorted { $0.t < $1.t }
        let eps = 0.005
        if forward {
            if let next = sorted.first(where: { $0.t > playheadT + eps }) {
                scrubTimeline(to: next.t)
            } else if let first = sorted.first {
                scrubTimeline(to: first.t)
            }
        } else {
            if let prev = sorted.last(where: { $0.t < playheadT - eps }) {
                scrubTimeline(to: prev.t)
            } else if let last = sorted.last {
                scrubTimeline(to: last.t)
            }
        }
    }
}
