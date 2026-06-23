import Metal
import Foundation
import CoreVideo
import Darwin

func logDebug(_ msg: String) {
    if let fp = fopen("/tmp/stereo_debug.log", "a") {
        fputs(msg, fp)
        fflush(fp)
        fclose(fp)
    }
}

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
    /// Handles both CPU-accessible and IOSurface-backed (GPU-only) pixel buffers.
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

        if desc.pixelFormat == .invalid {
            return device.makeTexture(descriptor: desc)!
        }

        guard let texture = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create texture from CVPixelBuffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            logDebug("createTexture: nil base addr pixelFormat=\(pixelFormat.rawValue) w=\(width) h=\(height)\n")
            // Try IOSurface fallback for GPU-only pixel buffers
            return createTextureFromIOSurface(pixelBuffer: pixelBuffer, width: width, height: height, pixelFormat: pixelFormat)
        }
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstBytesPerRow = texture.width * 4
        if srcBytesPerRow < texture.width * 4 {
            logDebug("createTexture: srcBytesPerRow \(srcBytesPerRow) < dst \(dstBytesPerRow)\n")
            return texture
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0,
            withBytes: srcBase,
            bytesPerRow: srcBytesPerRow
        )

        return texture
    }

    /// Create an MTLTexture directly from an IOSurface (GPU→GPU shared memory path).
    private func createTextureFromIOSurface(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> MTLTexture {
        guard let surfaceUnmanaged = CVPixelBufferGetIOSurface(pixelBuffer) else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            return device.makeTexture(descriptor: desc)!
        }
        let surface = surfaceUnmanaged.takeUnretainedValue()

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .private

        // Metal API: create MTLTexture that references IOSurface directly
        if let sharedTexture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) {
            logDebug("createTextureIOSurface: shared w=\(width) h=\(height)\n")
            return sharedTexture
        }

        // Fallback: create texture and copy from IOSurface memory
        guard let texture = device.makeTexture(descriptor: desc) else {
            return device.makeTexture(
                descriptor: MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: pixelFormat,
                    width: width,
                    height: height,
                    mipmapped: false
                )
            )!
        }

        guard UnsafeMutableRawPointer(IOSurfaceGetBaseAddress(surface)) != nil else {
            logDebug("createTextureIOSurface: IOSurfaceGetBaseAddress=nil w=\(width) h=\(height)\n")
            return texture
        }
        let base = UnsafeMutableRawPointer(IOSurfaceGetBaseAddress(surface))!
        let bpr = IOSurfaceGetBytesPerRow(surface)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: base,
            bytesPerRow: bpr
        )
        logDebug("createTextureIOSurface: copy w=\(width) h=\(height) bpr=\(bpr)\n")
        return texture
    }

    /// Create a texture from pixel buffer, inferring pixel format from CV buffer.
    public func createTexture(fromPixelBuffer pixelBuffer: CVPixelBuffer) -> MTLTexture {
        let cvFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let metalFormat: MTLPixelFormat
        switch cvFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            metalFormat = .invalid
        case kCVPixelFormatType_420YpCbCr8Planar:
            metalFormat = .invalid
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
        switch texture.pixelFormat {
        case .bgra8Unorm, .rgba8Unorm:
            info.rowsBytes = texture.width * 4
        default:
            info.rowsBytes = texture.width * 4
        }
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
    // releaseTextures: ARC handles MTLTexture cleanup automatically in Swift 6
    public func releaseTextures(_ textures: [MTLTexture]) {
        // ARC-managed; no manual release needed
        _ = textures
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
