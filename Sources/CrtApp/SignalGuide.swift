import Foundation
import CrtCore

enum SidebarMode: String, CaseIterable, Identifiable {
    case quick = "Quick"
    case allControls = "All Controls"
    var id: String { rawValue }
}

/// Four curated signal-chain starting points grounded in NTSCRT's craft guide,
/// so users immediately know which stages belong together.
enum EraRecipe: String, CaseIterable, Identifiable {
    case cleanCRT = "Clean CRT"
    case composite80s = "80s TV"
    case vhs90s = "90s VHS"
    case digital2000s = "2000s Web"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .cleanCRT: return "Crisp scanlines, no noise"
        case .composite80s: return "Warm composite + glow"
        case .vhs90s: return "Tape wear + VCR deck"
        case .digital2000s: return "Codec blocks, no analog"
        }
    }

    var icon: String {
        switch self {
        case .cleanCRT: return "arcade.stick.console"
        case .composite80s: return "tv"
        case .vhs90s: return "recordingtape"
        case .digital2000s: return "video.badge.waveform"
        }
    }

    var stagesCaption: String {
        switch self {
        case .cleanCRT: return "256px Chunky → CRT"
        case .composite80s: return "NTSC → 320px → CRT"
        case .vhs90s: return "NTSC → 320px → VCR → CRT"
        case .digital2000s: return "Digital Codec → 320px"
        }
    }
}

struct SignalAdvisory: Identifiable {
    let id: String
    let message: String
    let actionLabel: String
    let fix: (AppState) -> Void
}

extension AppState {

    // MARK: - Era Recipes

    var matchingEraRecipe: EraRecipe? {
        if digitalEnabled && !ntscEnabled && !vcrEnabled && !shaderEnabled {
            return .digital2000s
        }
        if !digitalEnabled && vcrEnabled && shaderEnabled {
            return .vhs90s
        }
        if !digitalEnabled && !vcrEnabled && !ntscEnabled && shaderEnabled {
            return .cleanCRT
        }
        if !digitalEnabled && !vcrEnabled && ntscEnabled && shaderEnabled && !isGlitchReceptionActive {
            return .composite80s
        }
        return nil
    }

    func applyEraRecipe(_ recipe: EraRecipe) {
        performUndoable("Apply \(recipe.rawValue) Starter") {
            withAutoKeySuppressed {
                stopTimelinePreview()
                timelineEnabled = false
                timelineKeys = []
                savedParamValues.removeAll()
                bypassAllStages = false

                // Start from clean receiver/VCR baseline
                var cleanGlitch = GlitchParam.defaultValues
                cleanGlitch[GlitchParam.vcrID] = 0
                glitchValues = cleanGlitch
                glitchEnabled = true

                switch recipe {
                case .cleanCRT:
                    digitalEnabled = false
                    digitalValues = DigitalParam.startingValues
                    digitalFormatApplied = false
                    ntscEnabled = false
                    downscaleEnabled = true
                    downscaleWidth = 256
                    downscalePreset = "SNES (256px)"
                    downscaleMethod = .nearest
                    shaderEnabled = true
                    if let hyllian = Presets.all.first(where: { $0.id == "hyllian" }) {
                        selectedPreset = hyllian
                    }
                    resetShader(allCachedShaders: false, recordUndo: false)

                case .composite80s:
                    digitalEnabled = false
                    digitalValues = DigitalParam.startingValues
                    digitalFormatApplied = false
                    ntscEnabled = true
                    ntscValues = ntscDefaults
                    pushNtscSettings()
                    downscaleEnabled = true
                    downscaleWidth = 320
                    downscalePreset = "VGA (320px)"
                    downscaleMethod = .nearest
                    shaderEnabled = true
                    if let glow = Presets.all.first(where: { $0.id == "glow_gauss" }) {
                        selectedPreset = glow
                    }
                    resetShader(allCachedShaders: false, recordUndo: false)

                case .vhs90s:
                    digitalEnabled = false
                    digitalValues = DigitalParam.startingValues
                    digitalFormatApplied = false
                    ntscEnabled = true
                    ntscValues = ntscDefaults
                    pushNtscSettings()
                    downscaleEnabled = true
                    downscaleWidth = 320
                    downscalePreset = "VGA (320px)"
                    downscaleMethod = .area
                    if let usedTape = VcrCondition.tapes.first(where: { $0.name == "Used" }) {
                        glitchValues = usedTape.applied(to: glitchValues, keys: VcrCondition.tapeKeys)
                    }
                    if let dirtyDeck = VcrCondition.decks.first(where: { $0.name == "Dirty heads" }) {
                        glitchValues = dirtyDeck.applied(to: glitchValues, keys: VcrCondition.deckKeys)
                    }
                    glitchValues[GlitchParam.vcrID] = 1
                    shaderEnabled = true
                    if let glow = Presets.all.first(where: { $0.id == "glow_gauss" }) {
                        selectedPreset = glow
                    }
                    resetShader(allCachedShaders: false, recordUndo: false)

                case .digital2000s:
                    ntscEnabled = false
                    glitchEnabled = false
                    shaderEnabled = false
                    if let webcam = DigitalFormat.byID["webcam"] ?? DigitalFormat.all.first {
                        applyDigitalFormat(webcam)
                    }
                    digitalEnabled = true
                }

                activePresetName = recipe.rawValue
                glitchRenderer?.restart()
                noteChainInputEdited()
                markChainDirty()
            }
        }
        isLookModified = false
    }

    // MARK: - Smart Signal Compatibility Advisories

    var activeSignalAdvisories: [SignalAdvisory] {
        var out: [SignalAdvisory] = []

        if digitalEnabled && (ntscEnabled || vcrEnabled || (glitchEnabled && isGlitchReceptionActive)) {
            out.append(SignalAdvisory(
                id: "digital-analog-stack",
                message: "Digital video is stacked onto analog TV/tape stages. Usually you want Digital on its own.",
                actionLabel: "Keep Digital Only"
            ) { s in
                s.performUndoable("Keep Digital Only") {
                    s.ntscEnabled = false
                    s.vcrEnabled = false
                    s.resetGlitch()
                    s.glitchEnabled = false
                }
            })
        }

        if ntscEnabled && shaderEnabled && selectedPreset.id == "sim" {
            out.append(SignalAdvisory(
                id: "double-composite",
                message: "CRT Sim runs its own composite pass, filtering NTSC twice.",
                actionLabel: "Turn Off NTSC"
            ) { s in
                s.ntscEnabled = false
            })
        }

        let retired = ntscDescriptors.filter { NtscSetting.retiredVHS.contains($0.name) && ntscBool($0.name) }
        if ntscEnabled && !retired.isEmpty {
            out.append(SignalAdvisory(
                id: "retired-vhs",
                message: "Legacy NTSC VHS filters are active (\(retired.map(\.label).joined(separator: ", "))). Use VCR instead.",
                actionLabel: "Switch to VCR"
            ) { s in
                s.performUndoable("Migrate Legacy VHS to VCR") {
                    for item in retired { s.setNtscValue(item.name, false) }
                    s.vcrEnabled = true
                }
            })
        }

        if shaderEnabled && hasSourcePicture && chainInputSize.height > 360 {
            out.append(SignalAdvisory(
                id: "high-line-count",
                message: "At \(chainInputSize.height) lines, CRT scanlines become faint or switch to 480i. Lower width for bold scanlines.",
                actionLabel: "Set 256px"
            ) { s in
                s.performUndoable("Set 256px Scanline Resolution") {
                    s.downscaleEnabled = true
                    s.downscaleWidth = 256
                    s.downscalePreset = "SNES (256px)"
                }
            })
        }

        return out
    }

    // MARK: - 5 Curated Macro Dials (0...1)

    /// 0 = 640px sharp, 0.5 = 320px TV, 1.0 = 128px bold chunky scanlines.
    var macroResolutionCrunch: Double {
        get {
            guard downscaleEnabled else { return 0 }
            let clamped = min(640, max(128, Double(downscaleWidth)))
            // Piecewise linear so 0.5 lands squarely on 320px.
            if clamped >= 320 {
                return 0.5 * (640 - clamped) / (640 - 320)
            } else {
                return 0.5 + 0.5 * (320 - clamped) / (320 - 128)
            }
        }
        set {
            let u = min(1, max(0, newValue))
            if u <= 0.01 {
                downscaleEnabled = true
                downscaleWidth = 640
                downscalePreset = "VGA² (640px)"
                return
            }
            downscaleEnabled = true
            let rawWidth: Double = u <= 0.5
                ? 640 - (u / 0.5) * (640 - 320)
                : 320 - ((u - 0.5) / 0.5) * (320 - 128)
            let snapped = max(128, min(640, 16 * Int((rawWidth / 16).rounded())))
            downscaleWidth = snapped
            if snapped == 256 { downscalePreset = "SNES (256px)" }
            else if snapped == 320 { downscalePreset = "VGA (320px)" }
            else if snapped == 384 { downscalePreset = "Arcade (384px)" }
            else if snapped == 640 { downscalePreset = "VGA² (640px)" }
            else { downscalePreset = "Custom" }
        }
    }

    /// 0 = NTSC off, 0.3 = mild house composite, 1.0 = heavy composite bleed & chroma noise.
    var macroCompositeAmount: Double {
        get {
            guard ntscEnabled else { return 0 }
            let bw = ntscNumber("bandwidth_scale")
            return min(1, max(0.02, bw / 1.1))
        }
        set {
            let u = min(1, max(0, newValue))
            if u <= 0.01 {
                ntscEnabled = false
                return
            }
            if !ntscEnabled { ntscEnabled = true }
            noteUserEditForUndo("Adjust Composite Macro")
            var vals = ntscValues
            vals["bandwidth_scale"] = 0.05 + 1.05 * u
            vals["vertical_scale"] = 0.05 + 0.95 * u
            vals["composite_noise_intensity"] = 0.35 * u
            vals["chroma_noise_intensity"] = 0.32 * u
            vals["luma_smear"] = min(1.0, 0.2 + 0.8 * u)
            vals["chroma_phase_noise_intensity"] = 0.12 * u
            ntscValues = vals
            pushNtscSettings()
            autoKeyIfParked()
            noteChainInputEdited()
            markChainDirty()
        }
    }

    /// 0 = VCR off, > 0 = physical VHS tape wear, dropouts, head dirt, and flutter.
    var macroTapeWear: Double {
        get {
            guard vcrEnabled else { return 0 }
            let s = glitchSettings
            let wear = s["tape_wear"]
            let dirt = s["head_dirt"]
            return min(1, max(0.08, max(wear / 0.85, dirt / 0.55)))
        }
        set {
            let u = min(1, max(0, newValue))
            if u <= 0.01 {
                vcrEnabled = false
                return
            }
            var vals = glitchValues
            vals[GlitchParam.vcrID] = 1
            let amt = max(0, (u - 0.08) / 0.92)
            vals["tape_wear"] = 0.85 * amt
            vals["tape_dropouts"] = 0.55 * amt
            vals["tape_scratches"] = 0.40 * amt
            vals["tape_creases"] = amt > 0.35 ? 0.45 * ((amt - 0.35) / 0.65) : 0
            vals["tape_edge_damage"] = amt > 0.5 ? 0.40 * ((amt - 0.5) / 0.5) : 0
            vals["head_dirt"] = 0.50 * amt
            vals["head_wear"] = 0.45 * amt
            vals["transport_flutter"] = 0.45 * amt
            vals["head_switch"] = 2.4 * amt
            glitchValues = vals
            glitchEdited()
        }
    }

    /// 0 = clean receiver lock, > 0 = snowy antenna, multipath ghosting, hum, and sync strain.
    var macroReceptionGlitch: Double {
        get {
            guard glitchEnabled else { return 0 }
            let s = glitchSettings
            let snow = 1.0 - s["signal_strength"]
            let sync = max(abs(s["vertical_hold"]), abs(s["horizontal_hold"]))
            let ghost = abs(s["ghost_level"])
            return min(1, max(snow / 0.72, max(sync / 0.75, ghost / 0.6)))
        }
        set {
            let u = min(1, max(0, newValue))
            if u <= 0.01 {
                resetGlitch()
                return
            }
            if !glitchEnabled { glitchEnabled = true }
            var vals = glitchValues
            vals["signal_strength"] = max(0.28, 1.0 - 0.72 * u)
            vals["ghost_level"] = 0.50 * u
            vals["hum"] = 0.35 * u
            vals["horizontal_hold"] = 0.55 * u * u
            vals["vertical_hold"] = u > 0.65 ? 0.65 * ((u - 0.65) / 0.35) : 0
            glitchValues = vals
            glitchEdited()
        }
    }

    /// 0 = CRT shader off, > 0 = scales bloom, halation, mask strength, and subtle tube warp.
    var macroCrtIntensity: Double {
        get {
            guard shaderEnabled else { return 0 }
            switch selectedPreset.id {
            case "glow_gauss", "glow_lanczos":
                return min(1, max(0.05, Double(paramValues["BLOOM_STRENGTH"] ?? 0.1) / 0.45))
            case "aperture":
                return min(1, max(0.05, Double(paramValues["MASK_STRENGTH"] ?? 0.35)))
            case "easymode":
                return min(1, max(0.05, Double(paramValues["SCANLINE_STRENGTH"] ?? 0.5)))
            case "hyllian":
                return min(1, max(0.05, Double(paramValues["SCANLINES_STRENGTH"] ?? 0.72)))
            case "royale":
                return min(1, max(0.05, Double(paramValues["halation_weight"] ?? 0.1) / 0.35))
            case "sim":
                return min(1, max(0.05, Double(paramValues["Tuning_Mask_Opacity"] ?? 0.5)))
            default:
                return 0.35
            }
        }
        set {
            let u = min(1, max(0, newValue))
            if u <= 0.01 {
                shaderEnabled = false
                return
            }
            if !shaderEnabled { shaderEnabled = true }
            let f = Float(u)
            switch selectedPreset.id {
            case "glow_gauss", "glow_lanczos":
                setParam("BLOOM_STRENGTH", 0.45 * f)
                setParam("maskDark", max(0.3, 1.0 - 0.55 * f))
                setParam("warpX", 0.06 * f)
                setParam("warpY", 0.08 * f)
            case "aperture":
                setParam("MASK_STRENGTH", 0.85 * f)
                setParam("GLOW_HALATION", 0.45 * f)
            case "easymode":
                setParam("SCANLINE_STRENGTH", min(1.0, 0.15 + 0.85 * f))
                setParam("MASK_STRENGTH", 0.75 * f)
            case "hyllian":
                setParam("SCANLINES_STRENGTH", min(1.0, 0.2 + 0.8 * f))
                setParam("GLOW_STRENGTH", 0.35 * f)
            case "royale":
                setParam("halation_weight", 0.35 * f)
                setParam("diffusion_weight", 0.35 * f)
                setParam("border_size", 0.03 * f)
            case "sim":
                setParam("Tuning_Mask_Opacity", min(1.0, 0.15 + 0.85 * f))
                setParam("BloomScalar", 0.45 * f)
                setParam("Tuning_Barrel", 0.22 * f)
            default:
                break
            }
        }
    }
}
