import CoreGraphics
import DiskCore
import Metal

/// Draws a laid-out treemap on the GPU.
///
/// Each tile is one instanced quad; the fragment shader evaluates the cushion surface at every
/// pixel. Colours come from a palette indexed by kind, so recolouring costs nothing and needs no
/// new layout. The shader is compiled at launch from source, which needs nothing but the
/// system's own Metal framework.
public final class TreemapRenderer: @unchecked Sendable {
    public enum Failure: Error {
        case noDevice
        case noCommandQueue
        case cannotAllocate
    }

    /// How light falls on the cushions.
    public struct Shading: Sendable {
        public var ambient: Float = 0.20
        public var diffuse: Float = 0.80
        /// Direction towards the light: up and to the left, and mostly facing the screen.
        public var light = SIMD3<Float>(-0.1, -0.2, 1)
        /// Overall brightness. Above 1, the tops of the cushions go past full colour.
        public var gain: Float = 1.35
        /// How much of the light past full colour turns into white.
        public var spill: Float = 0.70

        public init() {}
    }

    /// GPU-side copies of what a frame needs.
    public final class Scene: @unchecked Sendable {
        let tiles: MTLBuffer?
        let tileCount: Int
        public let width: Int
        public let height: Int

        init(tiles: MTLBuffer?, tileCount: Int, width: Int, height: Int) {
            self.tiles = tiles
            self.tileCount = tileCount
            self.width = width
            self.height = height
        }
    }

    /// Scales and shifts a whole scene, in pixels of the target, and fades it. Zoom animations
    /// use this to move a finished picture around at no cost.
    public struct Placement: Sendable {
        public var scale = SIMD2<Float>(1, 1)
        public var offset = SIMD2<Float>(0, 0)
        public var opacity: Float = 1

        public init() {}
    }

    private struct Uniforms {
        var viewport: SIMD2<Float>
        var scale: SIMD2<Float>
        var offset: SIMD2<Float>
        var opacity: Float
        var ambient: Float
        var light: SIMD3<Float>
        var diffuse: Float
        var gain: Float
        var spill: Float
        var paletteCount: UInt32
    }

    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    public var shading = Shading()

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    public init(pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        guard let queue = device.makeCommandQueue() else { throw Failure.noCommandQueue }
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "tileVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "tileFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        // Plain alpha blending, used while cross-fading between two scenes.
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.device = device
        self.pixelFormat = pixelFormat
        self.queue = queue
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? {
        queue.makeCommandBuffer()
    }

    public func makeScene(_ layout: TreemapLayout) -> Scene {
        let buffer = layout.tiles.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
        return Scene(tiles: buffer, tileCount: layout.tiles.count, width: layout.width, height: layout.height)
    }

    public func makePaletteBuffer(_ colors: [SIMD4<Float>]) -> MTLBuffer? {
        colors.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }

    /// Records drawing `layers`, bottom to top, into `target`, which is cleared to `background`.
    public func encode(
        _ layers: [(scene: Scene, placement: Placement)],
        palette: MTLBuffer,
        into commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        background: MTLClearColor
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = background

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(palette, offset: 0, index: 1)
        let light = simd_normalize_safe(shading.light)
        for (scene, placement) in layers {
            guard let tiles = scene.tiles, scene.tileCount > 0 else { continue }
            var uniforms = Uniforms(
                viewport: SIMD2(Float(target.width), Float(target.height)),
                scale: placement.scale,
                offset: placement.offset,
                opacity: placement.opacity,
                ambient: shading.ambient,
                light: light,
                diffuse: shading.diffuse,
                gain: shading.gain,
                spill: shading.spill,
                paletteCount: UInt32(palette.length / MemoryLayout<SIMD4<Float>>.stride)
            )
            encoder.setVertexBuffer(tiles, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: scene.tileCount)
        }
        encoder.endEncoding()
    }

    /// Renders off screen, for exporting and for tests.
    public func makeImage(_ layout: TreemapLayout, colors: [SIMD4<Float>]) throws -> CGImage {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: layout.width, height: layout.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard
            let texture = device.makeTexture(descriptor: descriptor),
            let palette = makePaletteBuffer(colors),
            let commandBuffer = makeCommandBuffer()
        else { throw Failure.cannotAllocate }

        encode(
            [(makeScene(layout), Placement())],
            palette: palette,
            into: commandBuffer,
            target: texture,
            background: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let rowBytes = layout.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * layout.height)
        texture.getBytes(
            &pixels, bytesPerRow: rowBytes,
            from: MTLRegionMake2D(0, 0, layout.width, layout.height), mipmapLevel: 0
        )
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: layout.width, height: layout.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: rowBytes, space: space, bitmapInfo: info, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        else { throw Failure.cannotAllocate }
        return image
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Tile {
        float4 rect;      // left, top, right, bottom in pixels
        float4 cushion;   // s1x, s2x, s1y, s2y, relative to the top left corner
        uint kind;
        uint padding;
    };

    struct Uniforms {
        float2 viewport;
        float2 scale;
        float2 offset;
        float opacity;
        float ambient;
        float3 light;
        float diffuse;
        float gain;
        float spill;
        uint paletteCount;
    };

    struct Fragment {
        float4 position [[position]];
        float2 local;
        float4 cushion [[flat]];
        float3 color [[flat]];
    };

    vertex Fragment tileVertex(uint corner [[vertex_id]],
                               uint instance [[instance_id]],
                               const device Tile *tiles [[buffer(0)]],
                               const device float4 *palette [[buffer(1)]],
                               constant Uniforms &uniforms [[buffer(2)]]) {
        Tile tile = tiles[instance];
        float2 unit = float2(corner & 1, corner >> 1);
        float2 size = tile.rect.zw - tile.rect.xy;
        float2 pixel = (tile.rect.xy + unit * size) * uniforms.scale + uniforms.offset;

        Fragment out;
        out.position = float4(pixel.x / uniforms.viewport.x * 2 - 1,
                              1 - pixel.y / uniforms.viewport.y * 2, 0, 1);
        out.local = unit * size;
        out.cushion = tile.cushion;
        // Kinds found by a refresh can get here just before the palette that includes them.
        out.color = palette[min(tile.kind, uniforms.paletteCount - 1)].rgb;
        return out;
    }

    fragment float4 tileFragment(Fragment in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]]) {
        // The surface normal comes straight from the derivative of the cushion's parabolas.
        float nx = -(2 * in.cushion.y * in.local.x + in.cushion.x);
        float ny = -(2 * in.cushion.w * in.local.y + in.cushion.z);
        float3 light = uniforms.light;
        float cosine = (nx * light.x + ny * light.y + light.z) * rsqrt(nx * nx + ny * ny + 1);
        float intensity = uniforms.ambient + uniforms.diffuse * max(cosine, 0.0);

        // A channel pushed past full brightness spills into the others, so the tops of the
        // cushions wash out towards white like a glossy highlight.
        float3 color = in.color * intensity * uniforms.gain;
        float excess = max(max(color.r, max(color.g, color.b)) - 1.0, 0.0);
        color = min(color + excess * uniforms.spill, 1.0);
        return float4(color, uniforms.opacity);
    }
    """
}

private func simd_normalize_safe(_ vector: SIMD3<Float>) -> SIMD3<Float> {
    let length = (vector * vector).sum().squareRoot()
    return length > 0 ? vector / length : SIMD3(0, 0, 1)
}
