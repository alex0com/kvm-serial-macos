import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import simd

/// Draws captured frames to a CAMetalLayer with no CPU copies: the
/// IOSurface-backed pixel buffer is wrapped as Metal textures and converted
/// from YCbCr in a fragment shader. Frames are presented straight from the
/// capture queue, without waiting for a display-link tick.
final class VideoRenderer: @unchecked Sendable {
    struct Stats {
        var framesPresented = 0
        /// Capture timestamp -> on-screen, in seconds, for the last frame.
        var lastFrameAge: Double = 0
        /// Capture timestamp -> frame handed to the renderer, in seconds.
        var lastDeliveryAge: Double = 0
        var videoSize = CGSize.zero
        var pixelFormat: FourCharCode = 0
    }

    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let biplanarPipeline: MTLRenderPipelineState
    private let packedPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    private let lock = NSLock()
    private var stats = Stats()
    private var drawableSize = CGSize.zero

    /// Called on the capture queue when the incoming frame size changes.
    var onVideoSizeChange: (@Sendable (CGSize) -> Void)?

    struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue()
        else { throw SetupError(description: "Metal is not available on this Mac.") }
        self.device = device
        commandQueue = queue
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)

        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "fullscreenQuad")
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        biplanarPipeline = try pipeline("biplanar")
        packedPipeline = try pipeline("packed")
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = false
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    var currentStats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Call from the main thread when the view's backing size changes.
    func setDrawableSize(_ size: CGSize) {
        lock.lock()
        drawableSize = size
        lock.unlock()
        layer.drawableSize = size
    }

    /// Render one frame. Called on the capture queue.
    func render(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let cache = textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let size = CGSize(width: width, height: height)

        let deliveryAge = CACurrentMediaTime() - timestamp.seconds
        lock.lock()
        stats.lastDeliveryAge = deliveryAge
        let target = drawableSize
        let sizeChanged = stats.videoSize != size
        stats.videoSize = size
        stats.pixelFormat = format
        lock.unlock()
        if sizeChanged { onVideoSizeChange?(size) }
        guard target.width > 0, target.height > 0 else { return }

        // Wrap the planes as textures (zero copy).
        var textures: [CVMetalTexture] = []
        func plane(_ index: Int, _ pixelFormat: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            var tex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil, pixelFormat, w, h, index, &tex)
            guard let tex else { return nil }
            textures.append(tex)
            return CVMetalTextureGetTexture(tex)
        }

        let pipeline: MTLRenderPipelineState
        let planes: [MTLTexture?]
        var fullRange = false
        switch format {
        case kCVPixelFormatType_422YpCbCr8_yuvs:  // Y0 Cb Y1 Cr
            pipeline = packedPipeline
            planes = [plane(0, .gbgr422, width, height)]
        case kCVPixelFormatType_422YpCbCr8:  // Cb Y0 Cr Y1
            pipeline = packedPipeline
            planes = [plane(0, .bgrg422, width, height)]
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            pipeline = biplanarPipeline
            fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            planes = [
                plane(0, .r8Unorm, width, height),
                plane(1, .rg8Unorm, width / 2, height / 2),
            ]
        default:
            return
        }
        guard planes.allSatisfy({ $0 != nil }) else { return }

        let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        let is601 = (matrix as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        var conversion = Self.conversion(bt601: is601, fullRange: fullRange)

        guard let drawable = layer.nextDrawable(),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let fit = aspectFit(size, in: CGSize(
            width: drawable.texture.width, height: drawable.texture.height))
        encoder.setViewport(MTLViewport(
            originX: fit.minX, originY: fit.minY, width: fit.width, height: fit.height,
            znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        for (i, texture) in planes.enumerated() {
            encoder.setFragmentTexture(texture, index: i)
        }
        encoder.setFragmentBytes(&conversion, length: MemoryLayout<Conversion>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        let captureSeconds = timestamp.seconds
        drawable.addPresentedHandler { [weak self] presented in
            guard let self, presented.presentedTime > 0 else { return }
            lock.lock()
            stats.framesPresented += 1
            stats.lastFrameAge = presented.presentedTime - captureSeconds
            lock.unlock()
        }
        // The CVMetalTextures must outlive the GPU work that samples them.
        nonisolated(unsafe) let retained = textures
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Colour conversion

    struct Conversion {
        var matrix: simd_float3x3
        var offset: SIMD3<Float>
    }

    /// rgb = matrix * (ycbcr - offset), with the range expansion folded into
    /// the matrix.
    static func conversion(bt601: Bool, fullRange: Bool) -> Conversion {
        let (kr, kb): (Float, Float) = bt601 ? (0.299, 0.114) : (0.2126, 0.0722)
        let kg = 1 - kr - kb
        let crR = 2 * (1 - kr)
        let cbB = 2 * (1 - kb)
        let cbG = -cbB * kb / kg
        let crG = -crR * kr / kg
        let yuv = simd_float3x3(columns: (
            SIMD3(1, 1, 1),  // Y
            SIMD3(0, cbG, cbB),  // Cb
            SIMD3(crR, crG, 0)  // Cr
        ))
        if fullRange {
            return Conversion(matrix: yuv, offset: SIMD3(0, 0.5, 0.5))
        }
        let range = simd_float3x3(diagonal: SIMD3(255 / 219, 255 / 224, 255 / 224))
        return Conversion(matrix: yuv * range, offset: SIMD3(16 / 255, 128 / 255, 128 / 255))
    }

    static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VOut { float4 position [[position]]; float2 uv; };
        struct Conversion { float3x3 matrix; float3 offset; };

        vertex VOut fullscreenQuad(uint vid [[vertex_id]]) {
            float2 uv = float2(vid & 1, vid >> 1);
            VOut out;
            out.position = float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1);
            out.uv = uv;
            return out;
        }

        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

        fragment float4 biplanar(VOut in [[stage_in]],
                                 texture2d<float> luma [[texture(0)]],
                                 texture2d<float> chroma [[texture(1)]],
                                 constant Conversion &c [[buffer(0)]]) {
            float3 ycc = float3(luma.sample(linearSampler, in.uv).r,
                                chroma.sample(linearSampler, in.uv).rg);
            return float4(saturate(c.matrix * (ycc - c.offset)), 1);
        }

        // 4:2:2 packed formats sampled as gbgr422/bgrg422: G = Y, B = Cb, R = Cr.
        fragment float4 packed(VOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant Conversion &c [[buffer(0)]]) {
            float4 p = tex.sample(linearSampler, in.uv);
            float3 ycc = float3(p.g, p.b, p.r);
            return float4(saturate(c.matrix * (ycc - c.offset)), 1);
        }
        """
}

/// Largest rect with `content`'s aspect ratio centred in `bounds`.
func aspectFit(_ content: CGSize, in bounds: CGSize) -> CGRect {
    guard content.width > 0, content.height > 0 else {
        return CGRect(origin: .zero, size: bounds)
    }
    let scale = min(bounds.width / content.width, bounds.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(
        x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
        width: size.width, height: size.height)
}
