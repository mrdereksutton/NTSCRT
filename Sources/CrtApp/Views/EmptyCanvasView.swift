import SwiftUI

/// Shown over the preview canvas when no image or video is loaded yet, turning
/// the blank black launch screen into an instant drop zone with built-in test cards.
struct EmptyCanvasView: View {
    @Environment(AppState.self) private var state
    let isDropTargeted: Bool
    let onOpenFile: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "tv.inset.filled")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .white.opacity(0.65))

            VStack(spacing: 5) {
                Text("Drop an Image or Video Anywhere")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("PNG, JPEG, HEIC, MP4, or MOV — or try a built-in test source below")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(spacing: 10) {
                Button {
                    onOpenFile()
                } label: {
                    Label("Open File…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    _ = state.pasteSourceFromClipboard()
                } label: {
                    Label("Paste (⌘V)", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if Paths.bundledTestAsset(named: "testpattern.png") != nil
                || Paths.bundledTestAsset(named: "game-frame.png") != nil {
                VStack(spacing: 8) {
                    Text("TRY A SAMPLE")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.white.opacity(0.4))

                    HStack(spacing: 8) {
                        if Paths.bundledTestAsset(named: "testpattern.png") != nil {
                            Button {
                                state.loadBundledSample("testpattern.png")
                            } label: {
                                Label("Broadcast Test Card", systemImage: "checkerboard.rectangle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        if Paths.bundledTestAsset(named: "game-frame.png") != nil {
                            Button {
                                state.loadBundledSample("game-frame.png")
                            } label: {
                                Label("16-Bit Pixel Art", systemImage: "gamecontroller")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.top, 4)
            }

            let recents = state.recentSourceURLs
            if !recents.isEmpty {
                VStack(spacing: 6) {
                    Text("RECENT")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.white.opacity(0.4))
                    HStack(spacing: 6) {
                        ForEach(recents.prefix(3), id: \.path) { url in
                            Button(url.lastPathComponent) {
                                state.sourceURL = url
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isDropTargeted ? Color.accentColor : .white.opacity(0.1),
                              lineWidth: isDropTargeted ? 2 : 1)
        )
        .environment(\.colorScheme, .dark)
    }
}
