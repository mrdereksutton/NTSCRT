import Foundation
import AppKit
import CrtCore

/// Value-type snapshot of the entire non-destructive look state, used by
/// `UndoManager`, `[A]/[B]` comparison slots, and dirty-state tracking.
struct LookSnapshot {
    let dictionary: [String: Any]
    let cropEnabled: Bool
    let crop: SourceCrop
    let activePresetName: String?
    let savedParamValues: [String: [String: Float]]
}

extension AppState {

    // MARK: - Snapshots & Undo / Redo

    func captureSnapshot() -> LookSnapshot {
        LookSnapshot(
            dictionary: lookDictionary(),
            cropEnabled: cropEnabled,
            crop: SourceCrop(ratio: cropRatio, x: cropX, y: cropY, scale: cropScale),
            activePresetName: activePresetName,
            savedParamValues: savedParamValues
        )
    }

    func commitBaselineSnapshot() {
        let snap = captureSnapshot()
        lastCommittedSnapshot = snap
        pendingUndoBefore = nil
        undoCoalesceTask?.cancel()
        undoCoalesceTask = nil
        isLookModified = false
    }

    /// Record a discrete undoable action immediately (`Reset Look`, `Load Preset`, etc.).
    func performUndoable(_ actionName: String, _ body: () throws -> Void) rethrows {
        if isRestoringSnapshot || suppressAutoKey {
            try body()
            return
        }
        flushPendingUndo()
        let before = lastCommittedSnapshot ?? captureSnapshot()
        try body()
        let after = captureSnapshot()
        registerUndoTransition(from: before, to: after, actionName: actionName)
        lastCommittedSnapshot = after
    }

    /// Coalesce rapid slider/toggle edits (280 ms window) into a single Undo step
    /// with zero allocation during the drag itself.
    func noteUserEditForUndo(_ actionName: String = "Adjust Look") {
        guard !isRestoringSnapshot, !suppressAutoKey, !timelinePlaying else { return }
        isLookModified = true
        if pendingUndoBefore == nil {
            pendingUndoBefore = lastCommittedSnapshot ?? captureSnapshot()
        }
        undoCoalesceTask?.cancel()
        undoCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            self?.flushPendingUndo(actionName: actionName)
        }
    }

    func flushPendingUndo(actionName: String = "Adjust Look") {
        undoCoalesceTask?.cancel()
        undoCoalesceTask = nil
        guard let before = pendingUndoBefore else { return }
        pendingUndoBefore = nil
        let after = captureSnapshot()
        registerUndoTransition(from: before, to: after, actionName: actionName)
        lastCommittedSnapshot = after
    }

    private func registerUndoTransition(from before: LookSnapshot,
                                        to after: LookSnapshot,
                                        actionName: String) {
        lookUndoManager.registerUndo(withTarget: self) { target in
            target.restoreSnapshot(before, registeringInverseTo: after, actionName: actionName)
        }
        lookUndoManager.setActionName(actionName)
    }

    func restoreSnapshot(_ snapshot: LookSnapshot,
                         registeringInverseTo inverse: LookSnapshot? = nil,
                         actionName: String = "Adjust Look") {
        flushPendingUndo()
        isRestoringSnapshot = true
        defer { isRestoringSnapshot = false }

        withAutoKeySuppressed {
            savedParamValues = snapshot.savedParamValues
            setCrop(snapshot.crop)
            cropEnabled = snapshot.cropEnabled
            try? applyLookDictionary(snapshot.dictionary, resetCropIfAbsent: false)
            activePresetName = snapshot.activePresetName
        }
        lastCommittedSnapshot = snapshot

        if let inverse {
            lookUndoManager.registerUndo(withTarget: self) { target in
                target.restoreSnapshot(inverse, registeringInverseTo: snapshot, actionName: actionName)
            }
            lookUndoManager.setActionName(actionName)
        }
    }

    func undoLook() {
        flushPendingUndo()
        guard lookUndoManager.canUndo else { return }
        lookUndoManager.undo()
    }

    func redoLook() {
        flushPendingUndo()
        guard lookUndoManager.canRedo else { return }
        lookUndoManager.redo()
    }

    // MARK: - A / B Snapshot Comparison Slots

    func selectOrStoreComparisonSlot(_ slot: ComparisonSlot, overwrite: Bool = false) {
        flushPendingUndo()
        switch slot {
        case .a:
            if overwrite || slotASnapshot == nil {
                slotASnapshot = captureSnapshot()
                activeComparisonSlot = .a
                return
            }
            if activeComparisonSlot == .b {
                slotBSnapshot = captureSnapshot()
            }
            if let snap = slotASnapshot {
                performUndoable("Switch to Slot A") {
                    isRestoringSnapshot = true
                    defer { isRestoringSnapshot = false }
                    restoreSnapshot(snap)
                }
                activeComparisonSlot = .a
            }
        case .b:
            if overwrite || slotBSnapshot == nil {
                if slotASnapshot == nil { slotASnapshot = captureSnapshot() }
                slotBSnapshot = captureSnapshot()
                activeComparisonSlot = .b
                return
            }
            if activeComparisonSlot == .a {
                slotASnapshot = captureSnapshot()
            }
            if let snap = slotBSnapshot {
                performUndoable("Switch to Slot B") {
                    isRestoringSnapshot = true
                    defer { isRestoringSnapshot = false }
                    restoreSnapshot(snap)
                }
                activeComparisonSlot = .b
            }
        }
    }

    // MARK: - Global & Stage Resets

    /// Full clean-slate reset across every stage, crop, cached shader state,
    /// timeline, and view zoom/compare.
    func resetAll() {
        performUndoable("Reset Look") {
            withAutoKeySuppressed {
                stopTimelinePreview()
                bypassAllStages = false

                // 1. Crop
                setCrop(SourceCrop(ratio: .square, x: 0.5, y: 0.5, scale: 1))
                cropEnabled = false

                // 2. Digital video
                digitalEnabled = false
                digitalValues = DigitalParam.startingValues
                digitalFormatApplied = false

                // 3. NTSC (clean house defaults, zero retired VHS flags)
                ntscEnabled = true
                ntscValues = ntscDefaults
                pushNtscSettings()

                // 4. Downscale
                downscaleEnabled = true
                downscaleWidth = 320
                downscalePreset = "VGA (320px)"
                downscaleMethod = .nearest

                // 5. VCR & Glitch
                var cleanGlitch = GlitchParam.defaultValues
                cleanGlitch[GlitchParam.vcrID] = 0
                glitchValues = cleanGlitch
                glitchEnabled = true
                glitchRenderer?.restart()

                // 6. CRT Shader (clear all stashed per-preset tweaks too)
                savedParamValues.removeAll()
                shaderEnabled = true
                let defaultShader = Presets.all.first { $0.id == "glow_gauss" } ?? Presets.all[0]
                if selectedPreset != defaultShader {
                    selectedPreset = defaultShader
                } else {
                    resetShader(allCachedShaders: true, recordUndo: false)
                }

                // 7. Timeline & View
                timelineEnabled = false
                timelineKeys = []
                timelineDuration = 5.0
                timelineFPS = 30
                scrubTimeline(to: 0)
                resetView()
                compareEnabled = false

                activePresetName = nil
                lookDescription = nil
                activeComparisonSlot = nil
                noteChainInputEdited()
                markChainDirty()
            }
        }
        isLookModified = false
    }

    func resetCrop() {
        performUndoable("Reset Crop") {
            setCrop(SourceCrop(ratio: .square, x: 0.5, y: 0.5, scale: 1))
            cropEnabled = false
        }
    }

    func resetDownscale() {
        performUndoable("Reset Downscale") {
            downscaleEnabled = true
            downscaleWidth = 320
            downscalePreset = "VGA (320px)"
            downscaleMethod = .nearest
        }
    }

    func resetDigital() {
        performUndoable("Reset Digital Video") {
            if let f = digitalFormat {
                applyDigitalFormat(f)
            } else {
                digitalValues = DigitalParam.startingValues
                digitalFormatApplied = false
                autoKeyIfParked()
                noteChainInputEdited()
                markChainDirty()
            }
        }
    }

    func resetShader(allCachedShaders: Bool = false, recordUndo: Bool = true) {
        let work = {
            if allCachedShaders {
                self.savedParamValues.removeAll()
            } else {
                self.savedParamValues.removeValue(forKey: self.selectedPreset.id)
            }
            var values: [String: Float] = [:]
            for p in self.paramDescriptors {
                values[p.name] = Self.appShaderDefaults[self.selectedPreset.id]?[p.name] ?? p.initial
            }
            self.setAllParams(values)
        }
        if recordUndo {
            performUndoable("Reset CRT Shader", work)
        } else {
            work()
        }
    }

    func clearTimelineKeys() {
        performUndoable("Clear Keyframes") {
            stopTimelinePreview()
            timelineKeys = []
            scrubTimeline(to: 0)
        }
    }

    /// Copy the first keyframe onto `t = 1` so animations loop seamlessly without a jump.
    func closeTimelineLoop() {
        guard !timelineKeys.isEmpty else { return }
        performUndoable("Make Seamless Loop") {
            var keys = timelineKeys
            if keys[0].t > 1e-6 {
                var start = keys[0]
                start.id = UUID()
                start.t = 0
                keys.insert(start, at: 0)
            }
            if let idx = keys.firstIndex(where: { $0.t > 1 - 1e-6 }) {
                keys.remove(at: idx)
            }
            var end = keys[0]
            end.id = UUID()
            end.t = 1
            keys.append(end)
            timelineKeys = keys.sorted { $0.t < $1.t }
            scrubTimeline(to: 0)
        }
    }

    // MARK: - Stage Modification Summaries (for Calm Headers & Dots)

    var isCropModified: Bool {
        cropEnabled
    }

    var isDownscaleModified: Bool {
        !downscaleEnabled || downscaleWidth != 320 || downscaleMethod != .nearest
    }

    var isDigitalModified: Bool {
        digitalEnabled
    }

    var isNtscModified: Bool {
        if !ntscEnabled { return true }
        for (k, defVal) in ntscDefaults where k != "version" {
            if let b = defVal as? Bool, ntscBool(k) != b { return true }
            else if let n = defVal as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                if abs(ntscNumber(k) - n.doubleValue) > 1e-4 { return true }
            }
        }
        return false
    }

    var isVcrModified: Bool {
        if vcrEnabled { return true }
        let s = glitchSettings
        return GlitchParam.controls(in: .tape).contains { p in p.kind != .seed && abs(s[p.id] - p.defaultValue) > 1e-4 }
            || GlitchParam.controls(in: .deck).contains { p in abs(s[p.id] - p.defaultValue) > 1e-4 }
    }

    var isGlitchReceptionActive: Bool {
        let s = glitchSettings
        return GlitchParam.controls(in: .reception).contains { p in
            abs(s[p.id] - p.defaultValue) > 1e-4
        }
    }

    var isShaderModified: Bool {
        if !shaderEnabled || selectedPreset.id != "glow_gauss" { return true }
        for p in paramDescriptors {
            let cur = paramValues[p.name] ?? p.initial
            if abs(cur - shaderDefault(p)) > 1e-4 { return true }
        }
        return false
    }

    // MARK: - Concise Collapsed Stage Summaries

    var cropSummary: String {
        cropEnabled ? cropRatio.label : "Off"
    }

    var downscaleSummary: String {
        guard downscaleEnabled else { return "Off" }
        let mode = downscaleMethod == .nearest ? "Chunky" : (downscaleMethod == .area ? "Smooth" : downscaleMethod.displayName)
        return "\(downscaleWidth)px · \(mode)"
    }

    var digitalSummary: String {
        guard digitalEnabled else { return "Off" }
        return digitalFormat?.name ?? "Custom"
    }

    var vcrSummary: String {
        guard vcrEnabled else { return "Off" }
        let tape = VcrCondition.matching(VcrCondition.tapes, keys: VcrCondition.tapeKeys, in: glitchSettings.values)?.name ?? "Custom"
        return tape
    }

    var glitchSummary: String {
        guard glitchEnabled else { return "Off" }
        return isGlitchReceptionActive ? "Active" : "Clean"
    }

    var shaderSummary: String {
        guard shaderEnabled else { return "Off" }
        return selectedPreset.displayName.replacingOccurrences(of: "CRT ", with: "")
    }
}
