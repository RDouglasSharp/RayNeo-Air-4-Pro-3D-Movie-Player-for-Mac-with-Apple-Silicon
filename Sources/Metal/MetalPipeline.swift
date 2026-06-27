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
        self.library = Self.loadLibrary(device: device)
    }

    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        let fname = "StereoWarp"
        if let url = Bundle.main.url(forResource: fname, withExtension: "metal") {
            logDebug("METALLIB bundle URL: \(url.path)\n")
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                do {
                    let lib = try device.makeLibrary(source: source, options: nil)
                    logDebug("METALLIB source compile OK: \(lib.functionNames)\n")
                    return lib
                } catch {
                    logDebug("METALLIB source compile error: \(error.localizedDescription)\n")
                }
            } else {
                logDebug("METALLIB cannot read source\n")
            }
        } else {
            logDebug("METALLIB NOT IN BUNDLE: StereoWarp.metal missing from \(Bundle.main.bundlePath)\n")
        }

        if let lib = device.makeDefaultLibrary() {
            logDebug("METALLIB default OK: \(lib.functionNames)\n")
            return lib
        }
        logDebug("METALLIB exhausted — all paths failed\n")
        return nil
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
        self.library = Self.loadLibrary(device: device)
        logDebug("MetalPipeline.init () done, library=\(library != nil ? "OK" : "nil")\n")
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

        if pixelFormat == .invalid {
            logDebug("createTexture: INVALID pixel format, returning empty\n")
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            return device.makeTexture(descriptor: desc) ?? device.makeTexture(descriptor: desc)!
        }

        // IOSurface FIRST — CVPixelBufferGetIOSurface does NOT require locking
        if CVPixelBufferGetIOSurface(pixelBuffer) != nil {
            logDebug("createTexture: IOSurface detected, GPU path\n")
            return createTextureFromIOSurface(pixelBuffer: pixelBuffer, width: width, height: height, pixelFormat: pixelFormat)
        }

        // No IOSurface — CPU upload via locked replaceRegion.
        // The earlier crash (AGX nil pointer deref) came from calling replaceRegion
        // WITHOUT locking the pixel buffer first, so CVPixelBufferGetBaseAddress
        // could return null while the GPU/decoder still owned the memory.
        // Locking first makes this path safe; storageMode must be .shared/.managed
        // (NOT .private) since .private textures cannot be written from the CPU.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            logDebug("createTexture: no IOSurface AND null base address, returning empty w=\(width) h=\(height)\n")
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            return device.makeTexture(descriptor: desc)!
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create texture from CVPixelBuffer")
        }
        texture.replace(region:
            MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: baseAddress,
            bytesPerRow: bytesPerRow
        )
        logDebug("createTexture: no IOSurface, CPU replaceRegion OK w=\(width) h=\(height) bpr=\(bytesPerRow)\n")
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
        let isoW = IOSurfaceGetWidth(surface)
        let isoH = IOSurfaceGetHeight(surface)
        let isoBpr = IOSurfaceGetBytesPerRow(surface)
        logDebug("createTextureIOSurface: iso w=\(isoW) h=\(isoH) bpr=\(isoBpr) fmt=\(pixelFormat.rawValue)\n")

        // IOSurface-backed textures require .shared storage mode
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        // Metal API: create MTLTexture that references IOSurface directly (GPU→GPU path)
        if let sharedTexture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) {
            logDebug("createTextureIOSurface: SHARED OK w=\(width) h=\(height)\n")
            return sharedTexture
        }

        // Shared path failed — IOSurface is GPU-only and CPU cannot access it.
        // Return an empty texture to avoid crash from CPU-copy of GPU memory.
        logDebug("createTextureIOSurface: makeTexture+iosurface FAILED w=\(width) h=\(height)\n")

        let fallbackDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        if let empty = device.makeTexture(descriptor: fallbackDesc) {
            return empty
        }
        return device.makeTexture(descriptor: fallbackDesc)!
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
        logDebug("createTexture auto: cvFmt=\(cvFormat) metalFmt=\(metalFormat.rawValue)\n")
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

    /// Return bytes per pixel for a given Metal pixel format.
    func pixelBytesPerPixel(_ pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .bgra8Unorm, .rgba8Unorm:
            return 4
        case .r16Unorm, .r16Float:
            return 2
        case .r8Unorm, .r8Snorm:
            return 1
        default:
            return 4
        }
    }

    /// Package video frame and depth map into a TexturePack.
    public func packageAll(
        videoFrame: CVPixelBuffer,
        depthMap: CVPixelBuffer
    ) -> TexturePack {
        logDebug("pkgAll start: videoFmt=\(CVPixelBufferGetPixelFormatType(videoFrame)) depthFmt=\(CVPixelBufferGetPixelFormatType(depthMap))\n")
        let videoTexture = createTexture(fromPixelBuffer: videoFrame)
        logDebug("pkgAll video OK\n")
        let depthTexture = createTexture(fromPixelBuffer: depthMap)
        logDebug("pkgAll depth OK\n")
        return TexturePack(video: videoTexture, depth: depthTexture)
    }
}
