import Metal
import Foundation
import CoreVideo

public struct TexturePack {
    let video: MTLTexture
    let depth: MTLTexture
}

public struct TextureInfo {
    var width: Int = 0
    var height: Int = 0
    var pixelFormat: MTLPixelFormat = .invalid
    var rowsBytes: Int = 0
}

/// Core Metal infrastructure: device, command queue, texture creation, shader compilation.
public class MetalPipeline {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let _syncQueue: DispatchQueue
    var library: MTLLibrary?

    public var syncQueue: DispatchQueue { _syncQueue }

    public init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device not available")
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue() ?? {
            fatalError("Failed to create command queue")
        }()
        self._syncQueue = DispatchQueue(
            label: "com.stereoplayer.metal",
            qos: .userInitiated
        )
        self.library = try? device.makeDefaultLibrary()
    }

    public convenience init(device: MTLDevice) {
        self.init(device: device, commandQueue: device.makeCommandQueue())
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue?) {
        self.device = device
        self.commandQueue = commandQueue ?? device.makeCommandQueue() ?? {
            fatalError("Failed to create command queue")
        }()
        self._syncQueue = DispatchQueue(
            label: "com.stereoplayer.metal",
            qos: .userInitiated
        )
        self.library = try? device.makeDefaultLibrary()
    }

    // MARK: - Texture Creation

    /// Create an MTLTexture from a CVPixelBuffer with explicit pixel format.
    public func createTexture(
        fromPixelBuffer pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.width = width
        desc.height = height
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create texture from CVPixelBuffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let dstBytesPerRow = texture.width * pixelFormat.pixelByteCount

            for y in 0..<height {
                let srcPtr = srcBase.advanced(by: y * srcBytesPerRow)
                let dstPtr = texture.contents().advanced(by: y * dstBytesPerRow)
                memcpy(dstPtr, srcPtr, Swift.min(srcBytesPerRow, dstBytesPerRow))
            }
        }

        return texture
    }

    /// Create a texture from pixel buffer, inferring pixel format from CV buffer.
    public func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer) -> MTLTexture {
        let cvFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let metalFormat: MTLPixelFormat
        switch cvFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            metalFormat = .yu12
        case kCVPixelFormatType_420YpCbCr8Planar:
            metalFormat = .rg11b10Float
        case kCVPixelFormatType_32BGRA:
            metalFormat = .bgra8Unorm
        case kCVPixelFormatType_32ARGB:
            metalFormat = .rgba8Unorm
        // kCVPixelFormatType_16Grey (0x33746369) not in Swift 6 enum; use constant
        case 0x33746369:
            metalFormat = .r16Unorm
        default:
            metalFormat = .rgba8Unorm
        }
        return createTexture(fromPixelBuffer: pixelBuffer, pixelFormat: metalFormat)
    }

    /// Create a 2D texture with specified dimensions.
    public func createTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create texture \(width)x\(height) \(pixelFormat)")
        }
        return texture
    }

    /// Create a memoryless texture (used for render targets).
    public func createMemorylessTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .memoryless
        guard let texture = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create memoryless texture \(width)x\(height)")
        }
        return texture
    }

    // MARK: - Shader Compilation

    /// Compile a Metal compute shader from the default library.
    public func compileComputeShader(named name: String) -> MTLComputePipelineState {
        guard let library = library else {
            fatalError("Metal library not loaded")
        }
        guard let funcRef = library.makeFunction(name: name) else {
            fatalError("Shader function '\(name)' not found in library")
        }
        do {
            return try device.makeComputePipelineState(function: funcRef)
        } catch {
            fatalError("Failed to compile compute shader '\(name)': \(error)")
        }
    }

    /// Compile a Metal render pipeline from HLSL-like source.
    @available(*, unavailable, message: "Runtime shader compilation not supported — use bundled .metal")
    public func compileRenderPipeline(vss: String, fss: String) -> MTLRenderPipelineState {
        fatalError("Unavailable")
    }

    // MARK: - Compute Dispatch

    /// Dispatch a compute pipeline with threadgroup sizing.
    public func dispatch(
        pipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer,
        threadgroups: Int,
        threadsPerGroup: MTLSize? = nil
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        encoder.setComputePipelineState(pipeline)
        let maxTotalThreads = pipeline.maxTotalThreadsPerThreadgroup
        let tpg = threadsPerGroup ?? MTLSize(
            width: Swift.min(256, maxTotalThreads),
            height: 1,
            depth: 1
        )
        let groupsPerGrid = MTLSize(
            width: Swift.max(1, (threadgroups + tpg.width - 1) / tpg.width),
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(groupsPerGrid, threadsPerThreadgroup: tpg)
        encoder.endEncoding()
    }

    /// Encode compute shader to a command buffer.
    @discardableResult
    public func dispatchCompute(
        pipeline: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer,
        threadgroups: Int,
        threadsPerGroup: MTLSize = MTLSize(width: 256, height: 1, depth: 1)
    ) -> MTLComputeCommandEncoder {
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        let groupsPerGrid = MTLSize(
            width: Swift.max(1, (threadgroups + threadsPerGroup.width - 1) / threadsPerGroup.width),
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(groupsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        return encoder
    }

    // MARK: - Render Pass

    public func encodeToRenderPass(
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        renderPipelineState: MTLRenderPipelineState
    ) -> MTLRenderCommandEncoder {
        let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        )!
        encoder.setRenderPipelineState(renderPipelineState)
        return encoder
    }

    // MARK: - Texture Operations

    /// Copy source texture to destination texture via blit command.
    public func copyTexture(src: MTLTexture, dst: MTLTexture) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: src, to: dst)
        blit.endEncoding()
        commandBuffer.commit()
    }

    /// Get texture info for logging/debugging.
    public func getTextureInfo(_ texture: MTLTexture) -> TextureInfo {
        var info = TextureInfo()
        info.width = texture.width
        info.height = texture.height
        info.pixelFormat = texture.pixelFormat
        info.rowsBytes = texture.bytesPerRow
        return info
    }

    // MARK: - Pipeline Orchestration

    /// Stage all textures, build dispatch list, execute through command buffers.
    public func pipelineDispatch(
        textures: [String: MTLTexture],
        computePipelines: [MTLComputePipelineState],
        renderPipelines: [MTLRenderPipelineState],
        renderPassDescriptors: [MTLRenderPassDescriptor]?
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        for pipeline in computePipelines {
            dispatch(
                pipeline: pipeline,
                commandBuffer: commandBuffer,
                threadgroups: 256
            )
        }

        if let renderPassDescriptors = renderPassDescriptors {
            for (i, desc) in renderPassDescriptors.enumerated() {
                guard i < renderPipelines.count else { break }
                _ = encodeToRenderPass(
                    renderPassDescriptor: desc,
                    commandBuffer: commandBuffer,
                    renderPipelineState: renderPipelines[i]
                )
            }
        }

        commandBuffer.commit()
    }

    /// Clean up texture resources at end of frame.
    public func releaseTextures(_ textures: [MTLTexture]) {
        for texture in textures {
            texture.release()
        }
    }

    /// Package video frame and depth map into a TexturePack.
    public func packageAll(
        videoFrame: CVPixelBuffer,
        depthMap: CVPixelBuffer
    ) -> TexturePack {
        let videoTexture = createTexture(fromPixelBuffer: videoFrame)
        let depthTexture = createTexture(fromPixelBuffer: depthMap, pixelFormat: .r32Float)
        return TexturePack(video: videoTexture, depth: depthTexture)
    }
}
