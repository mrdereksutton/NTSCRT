import XCTest
import Metal
import AVFoundation
import CoreMedia
import AudioToolbox
import ImageIO
import CrtAppBridge
@testable import CrtCore

final class EngineBugfixTests: XCTestCase {

    private static var libraryLoaded = false
    private var context: MetalContext!
    private var presetPath = ""
    private var tmp: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dylib = root.appendingPathComponent("Vendor/librashader/librashader.dylib")
        let preset = root.appendingPathComponent("Vendor/slang-shaders/crt/crtglow_gauss.slangp")
        guard FileManager.default.fileExists(atPath: dylib.path),
              FileManager.default.fileExists(atPath: preset.path) else {
            throw XCTSkip("librashader.dylib / slang-shaders not built in this checkout")
        }
        if !Self.libraryLoaded {
            try LRShaderChain.loadLibrary(dylib.path)
            Self.libraryLoaded = true
        }
        context = try MetalContext()
        presetPath = preset.path
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntscrt-bugfix-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: - storage mode & downscale bounds

    func testCpuStorageModeMatchesAppleSiliconCheck() throws {
        let expected: MTLStorageMode =
            (context.device.supportsFamily(.apple7) && !forceManagedStorage) ? .shared : .managed
        XCTAssertEqual(cpuStorageMode(for: context.device), expected)
        let staging = try XCTUnwrap(makeStagingTexture(device: context.device, width: 32, height: 32))
        XCTAssertEqual(staging.storageMode, expected)
    }

    func testPipelineClampsZeroDownscaleWithoutCrashing() throws {
        let pipeline = Pipeline(context: context)
        let chain = try LRShaderChain(presetPath: presetPath, commandQueue: context.queue)
        let src = try XCTUnwrap(makeStagingTexture(device: context.device, width: 64, height: 64))
        let dst = try XCTUnwrap(makeRenderTarget(device: context.device, width: 64, height: 64))
        let cb = try XCTUnwrap(context.queue.makeCommandBuffer())
        let zeroSpec = DownscaleSpec(width: 0, height: 0, method: .nearest)
        XCTAssertNoThrow(try pipeline.encode(into: cb, chain: chain,
                                             inputTexture: src, outputTexture: dst,
                                             downscale: zeroSpec, frameCount: 1))
        cb.commit()
        cb.waitUntilCompleted()
    }

    // MARK: - rotated portrait video (preferredTransform)

    /// Write a raw 128×64 landscape buffer tagged with a 90° CW portrait
    /// transform (`displaySize` = 64×128), plus a short sine-wave audio track.
    private func makeRotatedPortraitVideo(withAudio: Bool = false) async throws -> URL {
        let url = tmp.appendingPathComponent("portrait-rotated.mov")
        let rawW = 128, rawH = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422,
            AVVideoWidthKey: rawW,
            AVVideoHeightKey: rawH,
        ])
        // 90° clockwise QuickTime portrait matrix: (x, y) -> (rawH - y, x)
        vIn.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(rawH), ty: 0)
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: rawW,
                kCVPixelBufferHeightKey as String: rawH,
            ]
        )
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            aIn = input
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Raw top-left (x < 64, y < 32) = pure RED.
        // Under 90° CW rotation, raw top-left lands in UPRIGHT TOP-RIGHT!
        // Raw bottom-left (x < 64, y >= 32) = pure GREEN -> lands in UPRIGHT TOP-LEFT!
        for i in 0..<4 {
            while !vIn.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            var pbOpt: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOpt)
            let pb = try XCTUnwrap(pbOpt)
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let rb = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<rawH {
                for x in 0..<rawW {
                    let o = y * rb + x * 4
                    if x < rawW / 2 && y < rawH / 2 {
                        // Red (BGRA)
                        base[o] = 0; base[o + 1] = 0; base[o + 2] = 240; base[o + 3] = 255
                    } else if x < rawW / 2 && y >= rawH / 2 {
                        // Green (BGRA)
                        base[o] = 0; base[o + 1] = 240; base[o + 2] = 0; base[o + 3] = 255
                    } else {
                        // Blue (BGRA)
                        base[o] = 240; base[o + 1] = 0; base[o + 2] = 0; base[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 12)))
        }
        vIn.markAsFinished()

        if let aIn {
            let frames = 16_000 // ~0.33 s at 48 kHz
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            var desc: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &desc)
            var block: CMBlockBuffer?
            let byteLen = frames * 4
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteLen,
                                               blockAllocator: nil, customBlockSource: nil,
                                               offsetToData: 0, dataLength: byteLen,
                                               flags: kCMBlockBufferAssureMemoryNowFlag,
                                               blockBufferOut: &block)
            var samples = [Int16](repeating: 0, count: frames * 2)
            for s in 0..<frames {
                let v = Int16(sin(2.0 * .pi * 440.0 * Double(s) / 48_000.0) * 12_000)
                samples[s * 2] = v
                samples[s * 2 + 1] = v
            }
            samples.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!,
                                                  offsetIntoDestination: 0, dataLength: byteLen)
            }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: desc!,
                sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
                sampleBufferOut: &sb)
            while !aIn.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertTrue(aIn.append(sb!))
            aIn.markAsFinished()
        }

        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func sampleRGB(_ tex: MTLTexture, fx: Double, fy: Double) throws -> (r: Int, g: Int, b: Int) {
        let staging = try XCTUnwrap(makeStagingTexture(device: context.device, width: tex.width, height: tex.height))
        let cb = try XCTUnwrap(context.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: tex, to: staging)
        if staging.storageMode == .managed { blit.synchronize(resource: staging) }
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let cg = try makeCGImage(from: staging)
        return sampleRGB(cg, fx: fx, fy: fy)
    }

    private func sampleRGB(_ cg: CGImage, fx: Double, fy: Double) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: cg.width, height: cg.height,
                      bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let x = min(cg.width - 1, max(0, Int(fx * Double(cg.width))))
        let y = min(cg.height - 1, max(0, Int(fy * Double(cg.height))))
        let o = (y * cg.width + x) * 4
        return (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))
    }

    func testSequentialReaderRotatesPortraitVideoToMatchImageGenerator() async throws {
        let url = try await makeRotatedPortraitVideo()
        let vs = try await VideoSource(url: url, device: context.device)
        XCTAssertTrue(vs.needsPreferredTransform)
        XCTAssertEqual(vs.displaySize, CGSize(width: 64, height: 128))
        XCTAssertEqual(vs.effectivePixelSize().width, 64)
        XCTAssertEqual(vs.effectivePixelSize().height, 128)

        let seekTex = try await vs.frame(atIndex: 0)
        let seqReader = try vs.makeSequentialReader()
        let seqFrame = try XCTUnwrap(seqReader.nextFrame())

        XCTAssertEqual(seqFrame.texture.width, 64)
        XCTAssertEqual(seqFrame.texture.height, 128)
        XCTAssertEqual(seekTex.width, 64)
        XCTAssertEqual(seekTex.height, 128)

        // Upright top-left (0.25, 0.20) must be GREEN; upright top-right (0.75, 0.20) must be RED;
        // upright bottom half (0.50, 0.75) must be BLUE — matching AVAssetImageGenerator.
        let seekTL = try sampleRGB(seekTex, fx: 0.25, fy: 0.20)
        let seqTL = try sampleRGB(seqFrame.texture, fx: 0.25, fy: 0.20)
        XCTAssertGreaterThan(seekTL.g, 180)
        XCTAssertGreaterThan(seqTL.g, 180)

        let seekTR = try sampleRGB(seekTex, fx: 0.75, fy: 0.20)
        let seqTR = try sampleRGB(seqFrame.texture, fx: 0.75, fy: 0.20)
        XCTAssertGreaterThan(seekTR.r, 180)
        XCTAssertGreaterThan(seqTR.r, 180)

        let seqBottom = try sampleRGB(seqFrame.texture, fx: 0.50, fy: 0.75)
        XCTAssertGreaterThan(seqBottom.b, 180)
    }

    func testProResExportKeepsUprightOrientationRec709AndLPCMAudio() async throws {
        let srcURL = try await makeRotatedPortraitVideo(withAudio: true)
        let vs = try await VideoSource(url: srcURL, device: context.device)
        let outURL = tmp.appendingPathComponent("exported-prores.mov")

        let settings = Mp4Exporter.Settings(
            outputURL: outURL,
            outputWidth: 128,
            outputHeight: 256,
            downscale: nil,
            presetPath: presetPath,
            shaderEnabled: false,
            glitch: nil,
            digital: nil,
            codec: .prores422
        )
        try await Mp4Exporter(context: context).export(
            source: vs, paramValues: [:], settings: settings, progress: { _ in }
        )

        let outAsset = AVURLAsset(url: outURL)
        let vTracks = try await outAsset.loadTracks(withMediaType: .video)
        let vTrack = try XCTUnwrap(vTracks.first)
        let size = try await vTrack.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 128, height: 256))

        // Verify audio track is uncompressed Linear PCM at 48 kHz for ProRes.
        let aTracks = try await outAsset.loadTracks(withMediaType: .audio)
        let aTrack = try XCTUnwrap(aTracks.first)
        let descriptions = try await aTrack.load(.formatDescriptions)
        let firstDesc = try XCTUnwrap(descriptions.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(firstDesc)?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(asbd.mSampleRate, 48_000, accuracy: 1.0)

        // Verify exported frame pixels stayed upright (top-left green, top-right red).
        let gen = AVAssetImageGenerator(asset: outAsset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let frame = try await gen.image(at: .zero).image
        XCTAssertGreaterThan(sampleRGB(frame, fx: 0.25, fy: 0.20).g, 180)
        XCTAssertGreaterThan(sampleRGB(frame, fx: 0.75, fy: 0.20).r, 180)
    }
}
