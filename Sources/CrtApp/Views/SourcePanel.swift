import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SourcePanel: View {
    @Environment(AppState.self) private var state
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StageHeader(
                stepNumber: nil,
                title: "Source",
                expanded: $expanded,
                summary: state.sourceURL?.lastPathComponent
            )

            if expanded {
            HStack {
                Button("Open…") { openMedia() }
                Menu("Samples") {
                    if Paths.bundledTestAsset(named: "testpattern.png") != nil {
                        Button("Broadcast Test Card") { state.loadBundledSample("testpattern.png") }
                    }
                    if Paths.bundledTestAsset(named: "game-frame.png") != nil {
                        Button("16-Bit Pixel Art") { state.loadBundledSample("game-frame.png") }
                    }
                    let recents = state.recentSourceURLs
                    if !recents.isEmpty {
                        Divider()
                        ForEach(recents, id: \.path) { url in
                            Button(url.lastPathComponent) { state.sourceURL = url }
                        }
                    }
                }
                .fixedSize()
                if state.sourceURL != nil {
                    Button("Clear", role: .destructive) {
                        state.sourceURL = nil
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let url = state.sourceURL {
                Text(url.lastPathComponent)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The file's own size — the Crop panel shows what's left of it.
                if state.hasSourcePicture, let size = state.sourcePixelSize {
                    let frames = state.videoSource.map { "  ·  \($0.totalFrames) frames" } ?? ""
                    Text("\(size.width) × \(size.height) px\(frames)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Drop an image (PNG/JPEG/HEIC) or video (MP4/MOV) here, or click Open.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let err = state.sourceError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.movie], isTargeted: nil) { providers in
            state.handleDroppedProviders(providers)
        }
    }

    private func openMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie, .png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.sourceURL = url
        }
    }
}
