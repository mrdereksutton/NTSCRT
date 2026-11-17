import Foundation
import Metal

/// Testing hook: `CRT_FORCE_MANAGED=1` exercises the discrete/Intel GPU path on
/// Apple Silicon machines (`.managed` is valid on all macOS GPUs).
public let forceManagedStorage =
    ProcessInfo.processInfo.environment["CRT_FORCE_MANAGED"] != nil

/// Storage mode for CPU-visible textures on macOS.
///
/// Intel integrated GPUs report `device.hasUnifiedMemory == true` yet do not
/// support Apple Silicon's coherent `.shared` texture round-trips in the same
/// way; checking `.apple7` selects `.shared` strictly on Apple Silicon (M1+)
/// and `.managed` (paired with `blit.synchronize(resource:)`) on all Intel GPUs.
public func cpuStorageMode(for device: MTLDevice) -> MTLStorageMode {
    (device.supportsFamily(.apple7) && !forceManagedStorage) ? .shared : .managed
}

/// Holds the single Metal device + command queue used by the entire app.
///
/// librashader's Metal runtime is not thread-safe; everything that touches a
/// chain — including the downscaler that runs in the same command buffer —
/// must funnel through this single queue.
public final class MetalContext {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let downscaler: Downscaler

    public init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "MetalContext", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        guard let q = dev.makeCommandQueue() else {
            throw NSError(domain: "MetalContext", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no command queue"])
        }
        self.device = dev
        self.queue = q
        self.downscaler = try Downscaler(device: dev)
    }
}
