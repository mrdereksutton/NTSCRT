import Foundation
import AVFoundation
import Metal
import CoreVideo

/// Reads frames from a video file and exposes them as MTLTextures.
///
/// Two modes:
///   - Random access (scrubbing in the UI) via `frame(at:)` — uses
///     `AVAssetImageGenerator` so we can jump to arbitrary times cheaply.
///   - Sequential (export) via `makeSequentialReader()` — returns an iterator
///     wrapping `AVAssetReader` for max throughput on linear playback.
public final class VideoSource {

    public let url: URL
    public let asset: AVAsset
    public let videoTrack: AVAssetTrack
    public let durationSeconds: Double
    public let frameRate: Float
    public let pixelSize: CGSize
    public let preferredTransform: CGAffineTransform
    public let totalFrames: Int

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let imageGenerator: AVAssetImageGenerator

    public enum Error: Swift.Error, LocalizedError {
        case noVideoTrack
        case textureCacheCreate(CVReturn)
        case readerSetup(String)
        case decodeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "No video track in this file."
            case .textureCacheCreate(let r): return "CVMetalTextureCacheCreate failed (\(r))."
            case .readerSetup(let s): return "AVAssetReader setup failed: \(s)."
            case .decodeFailed(let s): return "decode failed: \(s)."
            }
        }
    }

    public init(url: URL, device: MTLDevice) async throws {
        self.url = url
        self.device = device
        let asset = AVURLAsset(url: url)
        self.asset = asset

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw Error.noVideoTrack }
        self.videoTrack = track

        let (duration, fps, size, transform) = try await (
            asset.load(.duration),
            track.load(.nominalFrameRate),
            track.load(.naturalSize),
            track.load(.preferredTransform)
        )
        self.durationSeconds = CMTimeGetSeconds(duration)
        self.frameRate = fps > 0 ? fps : 30
        self.pixelSize = size
        self.preferredTransform = transform
        self.totalFrames = max(1, Int((self.durationSeconds * Double(self.frameRate)).rounded()))

        var cache: CVMetalTextureCache?
        let r = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard r == kCVReturnSuccess, let cache else {
            throw Error.textureCacheCreate(r)
        }
        self.textureCache = cache

        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.appliesPreferredTrackTransform = true
        self.imageGenerator = gen
    }

    /// Decode the frame nearest to `time` and return it as an MTLTexture,
    /// cropped if asked.
    public func frame(at time: CMTime, crop: SourceCrop? = nil) async throws -> MTLTexture {
        // AVAssetImageGenerator produces a CGImage we then upload via MTKTextureLoader.
        // For fewer copies we could attach a custom output, but for scrubbing this is fine.
        let cgImage = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Swift.Error>) in
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let image, result == .succeeded {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: Error.decodeFailed("AVAssetImageGenerator returned \(result.rawValue)"))
                }
            }
        }
        // CGImage crops in its own pixel space: top row first, like the
        // rest of the pipeline.
        if let crop {
            let r = crop.rect(width: cgImage.width, height: cgImage.height)
            if (r.width, r.height) != (cgImage.width, cgImage.height),
               let cropped = cgImage.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) {
                return try cgImageToTexture(cropped)
            }
        }
        return try cgImageToTexture(cgImage)
    }

    /// A frame as a CGImage, whole (for showing what a crop leaves out).
    public func cgImage(atIndex index: Int) async throws -> CGImage {
        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate.rounded()))
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Swift.Error>) in
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let image, result == .succeeded {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: Error.decodeFailed("AVAssetImageGenerator returned \(result.rawValue)"))
                }
            }
        }
    }

    public func frame(atIndex index: Int, crop: SourceCrop? = nil) async throws -> MTLTexture {
        let t = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate.rounded()))
        return try await frame(at: t, crop: crop)
    }

    private func cgImageToTexture(_ cg: CGImage) throws -> MTLTexture {
        let w = cg.width, h = cg.height
        let bpr = w * 4
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: h * bpr)
        let bm: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs, bitmapInfo: bm) else {
            throw Error.decodeFailed("CGContext")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
        )
        d.usage = [.shaderRead]
        d.storageMode = cpuStorageMode(for: device)
        guard let tex = device.makeTexture(descriptor: d) else {
            throw Error.decodeFailed("makeTexture")
        }
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: bpr)
        }
        return tex
    }

    // MARK: - sequential reader for export

    public final class SequentialReader {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let device: MTLDevice
        let textureCache: CVMetalTextureCache
        let preferredTransform: CGAffineTransform
        /// Frames come out cropped to this, copied into `ring` — a frame's
        /// texture holds until `cropDepth` frames later. Uncropped frames are
        /// the decoder's own buffers, zero-copy.
        let crop: SourceCrop?
        private let ring: CropRing?
        private var uprightPool: CVPixelBufferPool?
        private var uprightPoolSize = (width: 0, height: 0)
        /// More frames than any consumer holds at once (playback: queue +
        /// on screen + previous + the two being processed).
        public static let cropDepth = 12

        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput,
             device: MTLDevice, textureCache: CVMetalTextureCache,
             preferredTransform: CGAffineTransform, crop: SourceCrop?) {
            self.reader = reader
            self.output = output
            self.device = device
            self.textureCache = textureCache
            self.preferredTransform = preferredTransform
            self.crop = crop
            self.ring = crop.map { _ in CropRing(device: device, depth: Self.cropDepth) }
            reader.startReading()
        }

        public struct Frame {
            public let texture: MTLTexture
            public let presentationTime: CMTime
            // Hold the underlying CVPixelBuffer alive until the texture is consumed.
            let _retain: CVPixelBuffer
            /// The cropped copy's memory, when the reader crops.
            let cropped: (buffer: MTLBuffer, rowBytes: Int)?

            /// The frame's pixels in CPU memory (BGRA, top row first), as
            /// `texture` shows them.
            func withPixels<T>(_ body: (UnsafeRawPointer, _ width: Int, _ height: Int, _ rowBytes: Int) -> T) -> T? {
                if let cropped {
                    return body(cropped.buffer.contents(), texture.width, texture.height, cropped.rowBytes)
                }
                CVPixelBufferLockBaseAddress(_retain, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(_retain, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(_retain) else { return nil }
                return body(base, CVPixelBufferGetWidth(_retain), CVPixelBufferGetHeight(_retain),
                            CVPixelBufferGetBytesPerRow(_retain))
            }
        }

        public func nextFrame() -> Frame? {
            guard let sb = output.copyNextSampleBuffer(),
                  let rawPB = CMSampleBufferGetImageBuffer(sb) else { return nil }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let pb: CVPixelBuffer
            if preferredTransform == .identity {
                pb = rawPB
            } else {
                guard let rotated = uprightPixelBuffer(from: rawPB) else { return nil }
                pb = rotated
            }
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            if let crop, let ring, crop.crops(width: w, height: h) {
                guard let slot = ring.copy(crop, from: pb) else { return nil }
                return Frame(texture: slot.texture, presentationTime: pts, _retain: pb,
                             cropped: (slot.buffer, slot.rowBytes))
            }

            var cvtex: CVMetalTexture?
            let r = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pb, nil,
                .bgra8Unorm, w, h, 0, &cvtex
            )
            guard r == kCVReturnSuccess, let cvtex,
                  let mtl = CVMetalTextureGetTexture(cvtex) else {
                return nil
            }
            return Frame(texture: mtl, presentationTime: pts, _retain: pb, cropped: nil)
        }

        private func makePoolBuffer(width: Int, height: Int) -> CVPixelBuffer? {
            if uprightPool == nil || uprightPoolSize != (width, height) {
                var pool: CVPixelBufferPool?
                let poolAttrs: [String: Any] = [
                    kCVPixelBufferPoolMinimumBufferCountKey as String: Self.cropDepth,
                ]
                let pbAttrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                ]
                guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary,
                                              pbAttrs as CFDictionary, &pool) == kCVReturnSuccess,
                      let pool else { return nil }
                uprightPool = pool
                uprightPoolSize = (width, height)
            }
            guard let pool = uprightPool else { return nil }
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess else {
                return nil
            }
            return out
        }

        private func uprightPixelBuffer(from rawPB: CVPixelBuffer) -> CVPixelBuffer? {
            let srcW = CVPixelBufferGetWidth(rawPB)
            let srcH = CVPixelBufferGetHeight(rawPB)
            guard srcW > 0, srcH > 0 else { return nil }
            let rawRect = CGRect(x: 0, y: 0, width: srcW, height: srcH)
            let transformed = rawRect.applying(preferredTransform)
            let dstW = max(1, Int(abs(transformed.width).rounded()))
            let dstH = max(1, Int(abs(transformed.height).rounded()))
            guard let dstPB = makePoolBuffer(width: dstW, height: dstH) else { return nil }

            let forward = preferredTransform.concatenating(
                CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY)
            )
            let inv = forward.inverted()

            CVPixelBufferLockBaseAddress(rawPB, .readOnly)
            CVPixelBufferLockBaseAddress(dstPB, [])
            defer {
                CVPixelBufferUnlockBaseAddress(dstPB, [])
                CVPixelBufferUnlockBaseAddress(rawPB, .readOnly)
            }
            guard let srcBase = CVPixelBufferGetBaseAddress(rawPB),
                  let dstBase = CVPixelBufferGetBaseAddress(dstPB) else { return nil }
            let srcRowBytes = CVPixelBufferGetBytesPerRow(rawPB)
            let dstRowBytes = CVPixelBufferGetBytesPerRow(dstPB)

            let stepX = Double(inv.a)
            let stepY = Double(inv.b)
            let maxSX = srcW - 1
            let maxSY = srcH - 1

            for dy in 0..<dstH {
                let py = Double(dy) + 0.5
                var sx = 0.5 * Double(inv.a) + py * Double(inv.c) + Double(inv.tx)
                var sy = 0.5 * Double(inv.b) + py * Double(inv.d) + Double(inv.ty)
                let dstRow = dstBase.advanced(by: dy * dstRowBytes).assumingMemoryBound(to: UInt32.self)
                for dx in 0..<dstW {
                    let ix = min(maxSX, max(0, Int(sx.rounded(.down))))
                    let iy = min(maxSY, max(0, Int(sy.rounded(.down))))
                    dstRow[dx] = srcBase.advanced(by: iy * srcRowBytes + ix * 4)
                        .assumingMemoryBound(to: UInt32.self).pointee
                    sx += stepX
                    sy += stepY
                }
            }
            return dstPB
        }
    }

    /// True when frames carry a non-identity track rotation/flip.
    public var needsPreferredTransform: Bool {
        preferredTransform != .identity
    }

    /// The frame size as displayed: the track's rotation applied.
    public var displaySize: CGSize {
        let r = CGRect(origin: .zero, size: pixelSize).applying(preferredTransform)
        return CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
    }

    /// Upright pixel dimensions after applying optional `crop`.
    public func effectivePixelSize(crop: SourceCrop? = nil) -> (width: Int, height: Int) {
        let w = max(1, Int(displaySize.width.rounded()))
        let h = max(1, Int(displaySize.height.rounded()))
        if let crop {
            let r = crop.rect(width: w, height: h)
            return (r.width, r.height)
        }
        return (w, h)
    }

    /// Sequential reader positioned at a frame — the playback path.
    ///
    /// Decoding successive frames by seeking to each one re-decodes from the
    /// preceding keyframe every time: measured 47 ms/frame on a 1176×1764
    /// h264 clip versus 2.8 ms sequentially, which alone overruns a 24 fps
    /// frame budget.
    public func makeSequentialReader(startingAtFrame index: Int, crop: SourceCrop? = nil) throws -> SequentialReader {
        try makeSequentialReader(startFrame: index, crop: crop)
    }

    public func makeSequentialReader(crop: SourceCrop? = nil) throws -> SequentialReader {
        try makeSequentialReader(startFrame: 0, crop: crop)
    }

    private func makeSequentialReader(startFrame: Int, crop: SourceCrop?) throws -> SequentialReader {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw Error.readerSetup("\(error)") }
        // Must be set before reading starts (SequentialReader's init starts it).
        if startFrame > 0 {
            let start = CMTime(value: CMTimeValue(startFrame),
                               timescale: CMTimeScale(frameRate.rounded()))
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw Error.readerSetup("reader cannot add output")
        }
        reader.add(output)
        return SequentialReader(reader: reader, output: output,
                                device: device, textureCache: textureCache,
                                preferredTransform: preferredTransform, crop: crop)
    }
}
