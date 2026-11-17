import SwiftUI
import CrtCore

/// Non-blocking smart signal compatibility banners grounded in `MCPServer.guide`.
struct SignalAdvisoriesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let advisories = state.activeSignalAdvisories
        if !advisories.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(advisories) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.message)
                                .font(.caption)
                                .foregroundStyle(.primary.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                            Button(item.actionLabel) {
                                item.fix(state)
                            }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.orange.opacity(0.11))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.orange.opacity(0.24), lineWidth: 1)
                    )
                }
            }
        }
    }
}

/// Guided `Quick` mode: 4 compatible Era Starters + 5 curated Macro Dials +
/// inline CRT/Sampling/Format pickers, with 1-click jump to `All Controls`.
struct QuickControlsView: View {
    @Environment(AppState.self) private var state
    let onSwitchToAllControls: () -> Void

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 16) {
            eraSection
            Divider()
            macrosSection
            Divider()
            quickDigitalToggle
        }
    }

    // MARK: - Era Starters

    private var eraSection: some View {
        let activeEra = state.matchingEraRecipe
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Start from an Era")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Compatible stages")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(EraRecipe.allCases) { recipe in
                    let selected = activeEra == recipe
                    Button {
                        state.applyEraRecipe(recipe)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: recipe.icon)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                Text(recipe.rawValue)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Text(recipe.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(recipe.stagesCaption)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.85))
                                .lineLimit(1)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 5 Macro Dials

    private var macrosSection: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Quick Dials")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    onSwitchToAllControls()
                } label: {
                    HStack(spacing: 3) {
                        Text("All 150+ Controls")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            // 1. Resolution Crunch
            VStack(alignment: .leading, spacing: 4) {
                macroRow(
                    title: "Scanline Crunch",
                    detail: state.downscaleSummary,
                    value: Binding(get: { state.macroResolutionCrunch }, set: { state.macroResolutionCrunch = $0 }),
                    neutral: 0.5,
                    help: "Lower horizontal width makes CRT scanlines bolder and chunkier (128px bold ↔ 320px TV ↔ 640px fine)."
                )
                HStack {
                    Text("Sampling")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { state.downscaleMethod == .area ? DownscaleMethod.area : .nearest },
                        set: { state.downscaleMethod = $0 }
                    )) {
                        Text("Chunky").tag(DownscaleMethod.nearest)
                        Text("Smooth").tag(DownscaleMethod.area)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            // 2. Composite Bleed & Noise
            macroRow(
                title: "Composite Bleed & Noise",
                detail: state.ntscEnabled ? "\(Int((state.macroCompositeAmount * 100).rounded()))%" : "Off",
                value: Binding(get: { state.macroCompositeAmount }, set: { state.macroCompositeAmount = $0 }),
                neutral: 0.28,
                help: "Analog NTSC color bleed, dot crawl, luma smear, and composite snow. Set to 0% to bypass NTSC."
            )

            // 3. VHS Tape Wear
            VStack(alignment: .leading, spacing: 4) {
                macroRow(
                    title: "VHS Tape & Deck Wear",
                    detail: state.vcrSummary,
                    value: Binding(get: { state.macroTapeWear }, set: { state.macroTapeWear = $0 }),
                    neutral: 0,
                    help: "Records onto a physical VHS cassette: oxide dropouts, head dirt, transport flutter, and head-switching."
                )
                if state.vcrEnabled {
                    HStack {
                        Text("Cassette")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(VcrCondition.tapes) { c in
                                Button(c.name) { state.applyVcrCondition(c, keys: VcrCondition.tapeKeys) }
                            }
                        } label: {
                            Text(VcrCondition.matching(VcrCondition.tapes, keys: VcrCondition.tapeKeys, in: state.glitchSettings.values)?.name ?? "Custom")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
            }

            // 4. Broadcast Reception Glitch
            macroRow(
                title: "TV Reception Glitch",
                detail: state.isGlitchReceptionActive ? "\(Int((state.macroReceptionGlitch * 100).rounded()))%" : "Clean",
                value: Binding(get: { state.macroReceptionGlitch }, set: { state.macroReceptionGlitch = $0 }),
                neutral: 0,
                help: "Weak antenna snow, multipath ghosting, mains hum bars, and horizontal/vertical sync slip."
            )

            // 5. CRT Screen & Glow
            VStack(alignment: .leading, spacing: 4) {
                macroRow(
                    title: "CRT Phosphor & Glow",
                    detail: state.shaderSummary,
                    value: Binding(get: { state.macroCrtIntensity }, set: { state.macroCrtIntensity = $0 }),
                    neutral: 0.35,
                    help: "Phosphor halation, shadow mask strength, and subtle tube curvature. Set to 0% to bypass the CRT screen."
                )
                if state.shaderEnabled {
                    HStack {
                        Text("Tube style")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $state.selectedPreset) {
                            ForEach(Presets.all) { p in
                                Text(p.displayName.replacingOccurrences(of: "CRT ", with: "")).tag(p)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: - Early Digital Stage Quick Card

    private var quickDigitalToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Digital Camcorder / Codec")
                    .font(.callout.weight(.medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.digitalEnabled },
                    set: { state.setDigitalEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            if state.digitalEnabled {
                HStack {
                    Text("Format")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(DigitalFormat.all) { f in
                            Button(f.name) {
                                state.performUndoable("Apply \(f.name)") {
                                    state.applyDigitalFormat(f)
                                    state.setDigitalEnabled(true)
                                }
                            }
                        }
                    } label: {
                        Text(state.digitalFormat?.name ?? "Custom")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
    }

    private func macroRow(title: String,
                          detail: String,
                          value: Binding<Double>,
                          neutral: Double,
                          help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            PropertySlider(value: value, range: 0...1, neutral: neutral)
        }
        .help(help)
    }
}
