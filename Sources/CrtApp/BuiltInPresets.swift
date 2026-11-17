import Foundation
import CrtCore

enum PresetCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case vhs = "VHS & Tape"
    case glitch = "TV Glitch"
    case digital = "Digital & Web"
    case cleanCrt = "Clean CRT"
    case animated = "Animated"
    case user = "My Presets"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .vhs: return "recordingtape"
        case .glitch: return "antenna.radiowaves.left.and.right"
        case .digital: return "video.badge.waveform"
        case .cleanCrt: return "tv"
        case .animated: return "film.stack"
        case .user: return "person.crop.square"
        }
    }
}

/// A look preset shipped with the app or saved into the user's Presets library.
struct BuiltInPreset: Identifiable, Hashable {
    /// Raw filename stem (kept exact for CLI/MCP `LookSettings.lookURL`).
    let name: String
    let url: URL
    let description: String?
    let isUserPreset: Bool
    let isAnimated: Bool
    let durationSeconds: Double?
    let primaryCategory: PresetCategory
    let stageBadges: [String]

    var id: String { url.path }

    /// Clean display title (capitalizes leading lowercase stems while keeping exact `name` for CLI).
    var displayTitle: String {
        guard let first = name.first, first.isLowercase else { return name }
        return first.uppercased() + name.dropFirst()
    }

    func matches(category: PresetCategory) -> Bool {
        switch category {
        case .all: return true
        case .user: return isUserPreset
        case .animated: return isAnimated
        default: return primaryCategory == category
        }
    }

    init(name: String, url: URL, isUserPreset: Bool = false) {
        self.name = name
        self.url = url
        self.isUserPreset = isUserPreset

        guard let data = FileManager.default.contents(atPath: url.path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.description = nil
            self.isAnimated = false
            self.durationSeconds = nil
            self.primaryCategory = .cleanCrt
            self.stageBadges = ["CRT"]
            return
        }

        self.description = dict["description"] as? String

        let timeline = dict["timeline"] as? [String: Any]
        let keys = (timeline?["keys"] as? [[String: Any]]) ?? []
        self.isAnimated = !keys.isEmpty
        self.durationSeconds = self.isAnimated ? (timeline?["duration"] as? Double ?? 5.0) : nil

        let digitalOn = ((dict["digital"] as? [String: Any])?["enabled"] as? Bool) ?? false
        let ntscOn = ((dict["ntsc"] as? [String: Any])?["enabled"] as? Bool) ?? true
        let shaderDict = dict["shader"] as? [String: Any]
        let shaderOn = (shaderDict?["enabled"] as? Bool) ?? true

        let glitchDict = dict["glitch"] as? [String: Any]
        let glitchOn = (glitchDict?["enabled"] as? Bool) ?? true
        let rawGlitch = (glitchDict?["values"] as? [String: Double]) ?? [:]
        let migratedGlitch = GlitchSettings.migrated(rawGlitch)
        let keyGlitches = keys.compactMap { $0["glitch"] as? [String: Double] }.map(GlitchSettings.migrated)
        let vcrOn = ([migratedGlitch] + keyGlitches).contains { ($0[GlitchParam.vcrID] ?? 0) >= 0.5 }

        let receptionEdited = ([migratedGlitch] + keyGlitches).contains { vals in
            GlitchParam.controls(in: .reception).contains { p in
                guard let v = vals[p.id] else { return false }
                return abs(v - p.defaultValue) > 1e-4
            }
        }

        let lower = name.lowercased()
        let vhsByName = lower.contains("vhs") || lower.contains("vcr") || lower.contains("tracking")
        let glitchByName = lower.contains("glitch") || lower.contains("static")
            || lower.contains("freak") || lower.contains("blip") || lower.contains("wavy")
            || lower.contains("obliterated")

        var badges: [String] = []
        if digitalOn { badges.append("Digital") }
        if ntscOn { badges.append("NTSC") }
        if vcrOn || vhsByName { badges.append("VHS") }
        if (glitchOn && receptionEdited) || glitchByName { badges.append("Glitch") }
        if shaderOn { badges.append("CRT") }
        self.stageBadges = badges

        if digitalOn {
            self.primaryCategory = .digital
        } else if vcrOn || vhsByName {
            self.primaryCategory = .vhs
        } else if (glitchOn && receptionEdited) || glitchByName {
            self.primaryCategory = .glitch
        } else {
            self.primaryCategory = .cleanCrt
        }
    }

    static func discover() -> [BuiltInPreset] {
        guard let root = Paths.lookPresetsRoot(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }

        return items
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { BuiltInPreset(name: $0.deletingPathExtension().lastPathComponent, url: $0, isUserPreset: false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func discoverUserPresets() -> [BuiltInPreset] {
        let root = Paths.userPresetsFolder()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }

        return items
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { BuiltInPreset(name: $0.deletingPathExtension().lastPathComponent, url: $0, isUserPreset: true) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
