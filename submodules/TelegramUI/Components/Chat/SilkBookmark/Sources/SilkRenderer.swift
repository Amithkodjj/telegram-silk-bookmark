import Foundation
import Metal
import QuartzCore
import simd

private struct SilkUniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var silk: SIMD4<Float>
    var edge: SIMD4<Float>
    var clipState: SIMD4<Float>
    var clips: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

final class SilkRenderTargets {
    let color: MTLTexture?
    let depth: MTLTexture

    init?(device: MTLDevice, width: Int, height: Int, sampleCount: Int) {
        #if targetEnvironment(simulator)
        let storage: MTLStorageMode = .private
        #else
        let storage: MTLStorageMode = .memoryless
        #endif

        func make(_ format: MTLPixelFormat) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
            descriptor.sampleCount = sampleCount
            descriptor.usage = .renderTarget
            descriptor.storageMode = storage
            return device.makeTexture(descriptor: descriptor)
        }

        guard let depth = make(.depth32Float) else {
            return nil
        }
        self.depth = depth
        self.color = sampleCount > 1 ? make(.bgra8Unorm) : nil
    }
}

final class SilkRenderer {
    let device: MTLDevice
    let sampleCount: Int

    private let queue: MTLCommandQueue
    private let silkPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthIgnore: MTLDepthStencilState
    private let indexBuffer: MTLBuffer
    private let indexCount: Int

    private static var shared: SilkRenderer?
    private static var waiting: [(SilkRenderer) -> Void] = []
    private static var isLoading = false

    static func load(_ completion: @escaping (SilkRenderer) -> Void) {
        if let shared = SilkRenderer.shared {
            completion(shared)
            return
        }
        SilkRenderer.waiting.append(completion)
        if SilkRenderer.isLoading {
            return
        }
        SilkRenderer.isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let renderer = SilkRenderer()
            DispatchQueue.main.async {
                SilkRenderer.shared = renderer
                SilkRenderer.isLoading = false
                let callbacks = SilkRenderer.waiting
                SilkRenderer.waiting = []
                if let renderer {
                    callbacks.forEach { $0(renderer) }
                }
            }
        }
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let library = try? device.makeLibrary(source: silkShaders, options: nil) else {
            return nil
        }
        let sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1

        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.rasterSampleCount = sampleCount
            descriptor.depthAttachmentPixelFormat = .depth32Float
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        let writeDescriptor = MTLDepthStencilDescriptor()
        writeDescriptor.depthCompareFunction = .less
        writeDescriptor.isDepthWriteEnabled = true
        let ignoreDescriptor = MTLDepthStencilDescriptor()
        ignoreDescriptor.depthCompareFunction = .always
        ignoreDescriptor.isDepthWriteEnabled = false

        let indices = SilkCloth.indices()
        guard let silkPipeline = pipeline("silkVertex", "silkFragment"),
              let shadowPipeline = pipeline("shadowVertex", "shadowFragment"),
              let depthWrite = device.makeDepthStencilState(descriptor: writeDescriptor),
              let depthIgnore = device.makeDepthStencilState(descriptor: ignoreDescriptor),
              let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride, options: .storageModeShared) else {
            return nil
        }

        self.device = device
        self.queue = queue
        self.sampleCount = sampleCount
        self.silkPipeline = silkPipeline
        self.shadowPipeline = shadowPipeline
        self.depthWrite = depthWrite
        self.depthIgnore = depthIgnore
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
    }

    func draw(cloth: SilkCloth, layer: CAMetalLayer, targets: SilkRenderTargets, origin: SIMD2<Float>, size: SIMD2<Float>, vividness: Float, clips: [CGRect], clipAmount: Float) {
        guard let vertexBuffer = self.device.makeBuffer(length: SilkCloth.vertexCount * MemoryLayout<SilkVertex>.stride, options: .storageModeShared) else {
            return
        }
        cloth.fill(vertexBuffer.contents().bindMemory(to: SilkVertex.self, capacity: SilkCloth.vertexCount))

        guard let drawable = layer.nextDrawable(), let commandBuffer = self.queue.makeCommandBuffer() else {
            return
        }

        let pass = MTLRenderPassDescriptor()
        let colorAttachment = pass.colorAttachments[0]!
        if let color = targets.color {
            colorAttachment.texture = color
            colorAttachment.resolveTexture = drawable.texture
            colorAttachment.storeAction = .multisampleResolve
        } else {
            colorAttachment.texture = drawable.texture
            colorAttachment.storeAction = .store
        }
        colorAttachment.loadAction = .clear
        colorAttachment.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0)
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }

        let pale = SIMD4<Float>(0.88, 0.85, 0.80, 1.0)
        let crimson = SIMD4<Float>(0.72, 0.07, 0.17, 1.0)
        let paleEdge = SIMD4<Float>(0.97, 0.95, 0.91, 1.0)
        let gold = SIMD4<Float>(0.98, 0.78, 0.38, 1.0)
        var uniforms = SilkUniforms(
            origin: origin,
            size: size,
            silk: simd_mix(pale, crimson, SIMD4(repeating: vividness)),
            edge: simd_mix(paleEdge, gold, SIMD4(repeating: vividness)),
            clipState: SIMD4(clipAmount > 0.0 ? Float(min(clips.count, 6)) : 0.0, (1.0 - clipAmount) * (1.0 - clipAmount) * 140.0, 0.0, 0.0),
            clips: (.zero, .zero, .zero, .zero, .zero, .zero)
        )
        withUnsafeMutableBytes(of: &uniforms.clips) { bytes in
            let slots = bytes.bindMemory(to: SIMD4<Float>.self)
            for (i, rect) in clips.prefix(6).enumerated() {
                slots[i] = SIMD4(Float(rect.midX), Float(rect.midY), Float(rect.width * 0.5), Float(rect.height * 0.5))
            }
        }

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SilkUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SilkUniforms>.stride, index: 1)

        encoder.setRenderPipelineState(self.shadowPipeline)
        encoder.setDepthStencilState(self.depthIgnore)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: self.indexCount, indexType: .uint16, indexBuffer: self.indexBuffer, indexBufferOffset: 0)

        encoder.setRenderPipelineState(self.silkPipeline)
        encoder.setDepthStencilState(self.depthWrite)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: self.indexCount, indexType: .uint16, indexBuffer: self.indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }
}

private let silkShaders = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float3 position;
    float3 normal;
    float3 tangent;
    float2 uv;
};

struct Uniforms {
    float2 origin;
    float2 size;
    float4 silk;
    float4 edge;
    float4 clipState;
    float4 clips[6];
};

struct Out {
    float4 position [[position]];
    float3 normal;
    float3 tangent;
    float2 uv;
    float height;
    float2 world;
};

static float clipDistance(float2 p, constant Uniforms &u) {
    float best = 1000.0;
    for (int i = 0; i < int(u.clipState.x); i++) {
        float radius = min(15.0, min(u.clips[i].z, u.clips[i].w));
        float2 q = abs(p - u.clips[i].xy) - (u.clips[i].zw - float2(radius));
        best = min(best, length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius);
    }
    return best;
}

static float4 place(float2 xy, float z, constant Uniforms &u) {
    float2 p = (xy - u.origin) / u.size;
    return float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.5 - z / 400.0, 1.0);
}

vertex Out silkVertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Vertex v = vertices[id];
    Out out;
    out.position = place(v.position.xy, v.position.z, u);
    out.normal = v.normal;
    out.tangent = v.tangent;
    out.uv = v.uv;
    out.height = v.position.z;
    out.world = v.position.xy;
    return out;
}

fragment float4 silkFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float distance = clipDistance(in.world, u);
    float coverage = u.clipState.x > 0.0 ? smoothstep(-0.6, 0.6, distance + u.clipState.y) : 1.0;
    if (coverage <= 0.0) {
        discard_fragment();
    }
    float3 n = normalize(in.normal);
    bool back = n.z < 0.0;
    if (back) {
        n = -n;
    }
    float3 t = normalize(in.tangent);
    float3 l = normalize(float3(-0.42, -0.62, 0.66));
    float3 h = normalize(l + float3(0.0, 0.0, 1.0));
    float wrap = saturate(dot(n, l) * 0.62 + 0.38);
    float th = dot(t, h);
    float band = pow(saturate(1.0 - th * th), 52.0);
    float across = abs(in.uv.x - 0.5) * 2.0;
    float threads = 0.5 + 0.5 * sin(in.uv.x * 150.0);

    float3 color = u.silk.rgb * (0.46 + 0.72 * wrap);
    color += mix(u.silk.rgb, float3(1.0), 0.55) * band * 0.42;
    color *= 0.975 + 0.05 * threads;

    float rim = smoothstep(0.82, 0.88, across);
    float3 rimColor = u.edge.rgb * (0.55 + 0.75 * wrap) + u.edge.rgb * band * 0.35;
    color = mix(color, rimColor, rim);
    if (back) {
        color *= 0.72;
    }
    if (u.clipState.x > 0.0) {
        color *= mix(0.62, 1.0, smoothstep(0.0, 8.0, distance + u.clipState.y));
    }
    return float4(color * coverage, coverage);
}

vertex Out shadowVertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Vertex v = vertices[id];
    float z = max(v.position.z, 0.0);
    float2 side = float2(v.tangent.y, -v.tangent.x);
    float spread = 1.5 + z * 0.22;
    float2 xy = v.position.xy + float2(0.4, 1.0) * (1.2 + z * 0.55) + side * (v.uv.x - 0.5) * 2.0 * spread;
    Out out;
    out.position = place(xy, 0.0, u);
    out.normal = v.normal;
    out.tangent = v.tangent;
    out.uv = v.uv;
    out.height = z;
    out.world = xy;
    return out;
}

fragment float4 shadowFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float across = abs(in.uv.x - 0.5) * 2.0;
    float alpha = (1.0 - smoothstep(0.35, 1.0, across)) * 0.26 / (1.0 + in.height * 0.02);
    if (u.clipState.x > 0.0) {
        alpha *= smoothstep(-0.6, 0.6, clipDistance(in.world, u) + u.clipState.y);
    }
    return float4(0.0, 0.0, 0.0, alpha);
}
"""
