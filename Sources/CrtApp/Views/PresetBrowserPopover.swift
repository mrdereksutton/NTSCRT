import SwiftUI
import AppKit

/// Categorized, searchable Preset Browser replacing the 38-item flat text menu,
/// with animated-loop badges, stage pills, favorites, and managed My Presets.
struct PresetBrowserPopover: View {
    @Environment(AppState.self) private var state
    let onDismiss: () -> Void
    let onImportFile: () -> Void
    let onExportFile: () -> Void

    @State private var searchText = ""
    @State private var selectedCategory: PresetCategory = .all
    @State private var newPresetName = ""
    @State private var userPresets: [BuiltInPreset] = BuiltInPreset.discoverUserPresets()
    @State private var favoriteNames: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "ntscrt.favoritePresets") ?? []
    )
    private let builtInPresets = BuiltInPreset.discover()

    private var filteredPresets: [BuiltInPreset] {
        let all = userPresets + builtInPresets
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { p in
            guard p.matches(category: selectedCategory) else { return false }
            guard !q.isEmpty else { return true }
            if p.displayTitle.lowercased().contains(q) { return true }
            if let d = p.description?.lowercased(), d.contains(q) { return true }
            return p.stageBadges.contains { $0.lowercased().contains(q) }
        }
        .sorted { a, b in
            let favA = favoriteNames.contains(a.name)
            let favB = favoriteNames.contains(b.name)
            if favA != favB { return favA && !favB }
            if a.isUserPreset != b.isUserPreset { return a.isUserPreset && !b.isUserPreset }
            return a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header + Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search \(builtInPresets.count + userPresets.count) presets, stages, or moods…",
                          text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

            // Category Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(PresetCategory.allCases) { cat in
                        let selected = selectedCategory == cat
                        Button {
                            selectedCategory = cat
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: cat.symbol)
                                    .font(.system(size: 10))
                                Text(cat.rawValue)
                                    .font(.caption.weight(selected ? .semibold : .regular))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Preset List
            ScrollView {
                if filteredPresets.isEmpty {
                    VStack(spacing: 6) {
                        Text(selectedCategory == .user ? "No saved presets in My Presets yet." : "No presets match \"\(searchText)\".")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if selectedCategory == .user {
                            Text("Type a name below to save your current look for 1-click reuse.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredPresets) { preset in
                            presetRow(preset)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(height: 320)

            Divider()

            // Quick Save to My Presets
            HStack(spacing: 6) {
                TextField("Save current look to My Presets…", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { saveToUserLibrary() }
                Button("Save") {
                    saveToUserLibrary()
                }
                .controlSize(.small)
                .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Bottom Actions
            HStack {
                Button("Import File…") {
                    onDismiss()
                    onImportFile()
                }
                .controlSize(.small)
                .buttonStyle(.borderless)

                Button("Export File…") {
                    onDismiss()
                    onExportFile()
                }
                .controlSize(.small)
                .buttonStyle(.borderless)

                Spacer()

                Button("Reset to Clean Default") {
                    state.resetAll()
                    onDismiss()
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(width: 410)
    }

    private func presetRow(_ preset: BuiltInPreset) -> some View {
        let isCurrent = state.activePresetName == preset.displayTitle || state.activePresetName == preset.name
        let isFav = favoriteNames.contains(preset.name)

        return HStack(alignment: .top, spacing: 8) {
            Button {
                try? state.loadLook(from: preset.url, named: preset.displayTitle)
                onDismiss()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(preset.displayTitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if preset.isUserPreset {
                            Text("USER")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        }

                        if let dur = preset.durationSeconds, preset.isAnimated {
                            HStack(spacing: 2) {
                                Image(systemName: "film")
                                Text(String(format: "%.0fs", dur))
                            }
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                        }

                        Spacer(minLength: 4)

                        HStack(spacing: 3) {
                            ForEach(preset.stageBadges, id: \.self) { badge in
                                Text(badge)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }

                    if let desc = preset.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleFavorite(preset.name)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(isFav ? .yellow : .secondary.opacity(0.5))
                    .padding(.top, 2)
            }
            .buttonStyle(.plain)
            .help(isFav ? "Remove from Favorites" : "Pin to top of Preset Browser")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isCurrent ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035))
        )
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([preset.url])
            }
            if preset.isUserPreset {
                Divider()
                Button("Delete Preset", role: .destructive) {
                    try? FileManager.default.removeItem(at: preset.url)
                    userPresets = BuiltInPreset.discoverUserPresets()
                }
            }
        }
    }

    private func toggleFavorite(_ name: String) {
        if favoriteNames.contains(name) {
            favoriteNames.remove(name)
        } else {
            favoriteNames.insert(name)
        }
        UserDefaults.standard.set(Array(favoriteNames).sorted(), forKey: "ntscrt.favoritePresets")
    }

    private func saveToUserLibrary() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !trimmed.isEmpty else { return }
        let url = Paths.userPresetsFolder().appendingPathComponent("\(trimmed).json")
        if (try? state.saveLook(to: url)) != nil {
            state.activePresetName = trimmed
            state.isLookModified = false
            newPresetName = ""
            userPresets = BuiltInPreset.discoverUserPresets()
            selectedCategory = .user
        }
    }
}
