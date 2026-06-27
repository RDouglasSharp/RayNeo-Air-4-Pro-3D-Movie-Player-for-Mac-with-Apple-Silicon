import Metal
import AVFoundation

/// Stereo 3D composition: takes fused video + depth map, produces left/right eye SBS.
///
/// Always outputs 1920x1080 per-eye viewframes. Source video is contain-fitted within
/// each eye viewport with equal letterbox or pillarbox bands on the constrained axis.
public class StereoComposer {
    let pipeline: MetalPipeline
    var leftTexture: MTLTexture?
    var rightTexture: MTLTexture?

    var baseline: Float
    var focalLength: Float
    var fillMode: FillMode

    public enum FillMode {
        case nearest
        case mirror
        case color
    }

    public init(
        pipeline: MetalPipeline,
        baseline: Float = 16.0,
        focalLength: Float = 512.0,
        fillMode: FillMode = .nearest
    ) {
        self.pipeline = pipeline
        self.baseline = baseline
        self.focalLength = focalLength
        self.fillMode = fillMode
    }

    /// Perform stereo composition: generate left & right eye views.
    ///
    /// Each eye outputs a 1920x1080 texture. The source video is scaled to fit within
    /// the 1920x1080 viewport using contain-fit (aspect ratio preserved), with black
    /// bars on the constrained axis (letterbox for wide video, pillarbox for tall video).
    ///
    /// - Parameters:
    ///   - video: Original RGB video frame
    ///   - depth: Corresponding depth map (HWC layout)
    /// - Returns: Pair of 1920x1080 textures (leftEye, rightEye)
    @discardableResult
    public func compose(
        video: MTLTexture,
        depth: MTLTexture
    ) -> (leftEye: MTLTexture, rightEye: MTLTexture) {
        let videoWidth = video.width
        let videoHeight = video.height
        let eyeW = 1920
        let eyeH = 1080

        // Compute contain-fit (letterbox/pillarbox) parameters
        let videoAspect = Float(videoWidth) / Float(videoHeight)
        let eyeAspect = Float(eyeW) / Float(eyeH)

        let (contentOffsetX, contentOffsetY, contentWidth, contentHeight): (Float, Float, Float, Float)
        if videoAspect > eyeAspect {
            // Video wider than 16:9 — constrain by width, letterbox top/bottom
            contentWidth = Float(eyeW)
            contentHeight = Float(eyeW) / videoAspect
            contentOffsetX = 0
            contentOffsetY = (Float(eyeH) - contentHeight) / 2
        } else {
            // Video taller than or equal to 16:9 — constrain by height, pillarbox left/right
            contentHeight = Float(eyeH)
            contentWidth = Float(eyeH) * videoAspect
            contentOffsetX = (Float(eyeW) - contentWidth) / 2
            contentOffsetY = 0
        }

        let leftEye = pipeline.createTexture(width: eyeW, height: eyeH, pixelFormat: .bgra8Unorm)
        let rightEye = pipeline.createTexture(width: eyeW, height: eyeH, pixelFormat: .bgra8Unorm)

        let commandBuffer = self.pipeline.commandQueue.makeCommandBuffer()!
        guard
            let library = pipeline.library,
            let metalFunc = library.makeFunction(name: "stereoWarp"),
            let computePipeline = try? pipeline.device.makeComputePipelineState(function: metalFunc)
        else {
            logDebug("COMPOSE FAIL: library=\(pipeline.library != nil), func=\(pipeline.library?.makeFunction(name: "stereoWarp") != nil)\n")
            self.leftTexture = leftEye
            self.rightTexture = rightEye
            return (leftEye, rightEye)
        }

        logDebug("COMPOSE warp shader OK\n")

        // Edge-aware depth smoothing pass: run bilateralFilterDepth on the raw depth texture
        // BEFORE the stereo warp samples it. This is what removes the noisy-edge artifacts
        // around object silhouettes (e.g. arms, instrument necks) that show up as torn/
        // smeared pixels in the warped output — see StereoWarp.metal for the full rationale.
        // Falls back to the raw (unsmoothed) depth texture if the shader function is missing
        // for any reason, so a partial bundle/library issue degrades quality rather than
        // breaking playback entirely.
        var smoothedDepth = depth
        if let bilateralFunc = library.makeFunction(name: "bilateralFilterDepth"),
           let bilateralPipeline = try? pipeline.device.makeComputePipelineState(function: bilateralFunc) {
            let filteredDepth = pipeline.createTexture(
                width: depth.width,
                height: depth.height,
                pixelFormat: depth.pixelFormat
            )
            if let bilateralEncoder = commandBuffer.makeComputeCommandEncoder() {
                bilateralEncoder.setComputePipelineState(bilateralPipeline)
                bilateralEncoder.setTexture(depth, index: 0)
                bilateralEncoder.setTexture(filteredDepth, index: 1)
                let depthThreadgroups = MTLSize(
                    width: (depth.width + 7) / 8,
                    height: (depth.height + 7) / 8,
                    depth: 1
                )
                let depthThreadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
                bilateralEncoder.dispatchThreadgroups(depthThreadgroups, threadsPerThreadgroup: depthThreadGroupSize)
                bilateralEncoder.endEncoding()
                smoothedDepth = filteredDepth
            } else {
                logDebug("COMPOSE bilateral encoder creation failed — using raw depth\n")
            }
        } else {
            logDebug("COMPOSE bilateralFilterDepth function not found — using raw depth\n")
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            self.leftTexture = leftEye
            self.rightTexture = rightEye
            return (leftEye, rightEye)
        }

        encoder.setComputePipelineState(computePipeline)
        encoder.setTexture(video, index: 0)
        encoder.setTexture(smoothedDepth, index: 1)
        encoder.setTexture(leftEye, index: 2)
        encoder.setTexture(rightEye, index: 3)

        let anchorDepth: Float = 0.5
        let params: [Float] = [
            Float(videoWidth), Float(videoHeight),
            Float(eyeW), Float(eyeH),
            baseline, focalLength,
            anchorDepth,
            contentOffsetX, contentOffsetY,
            contentWidth, contentHeight
        ]
        params.withUnsafeBytes { ptr in
            encoder.setBytes(ptr.baseAddress!, length: MemoryLayout<Float>.stride * 11, index: 4)
        }

        let threadgroups = MTLSize(
            width: (eyeW + 7) / 8,
            height: (eyeH + 7) / 8,
            depth: 1
        )
        let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        // Fill occlusion holes (alpha=0) left by out-of-bounds stereo warp
        if let fillFunc = library.makeFunction(name: "fillHoles"),
           let fillPipeline = try? pipeline.device.makeComputePipelineState(function: fillFunc),
           let fillEncoder = commandBuffer.makeComputeCommandEncoder() {
            fillEncoder.setComputePipelineState(fillPipeline)
            fillEncoder.setTexture(leftEye, index: 0)
            fillEncoder.setTexture(smoothedDepth, index: 1)
            params.withUnsafeBytes { ptr in
                fillEncoder.setBytes(ptr.baseAddress!, length: MemoryLayout<Float>.stride * 11, index: 4)
            }
            fillEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadGroupSize)
            fillEncoder.endEncoding()
        }

        if let fillFunc2 = library.makeFunction(name: "fillHoles"),
           let fillPipeline2 = try? pipeline.device.makeComputePipelineState(function: fillFunc2),
           let fillEncoderR = commandBuffer.makeComputeCommandEncoder() {
            fillEncoderR.setComputePipelineState(fillPipeline2)
            fillEncoderR.setTexture(rightEye, index: 0)
            fillEncoderR.setTexture(smoothedDepth, index: 1)
            params.withUnsafeBytes { ptr in
                fillEncoderR.setBytes(ptr.baseAddress!, length: MemoryLayout<Float>.stride * 11, index: 4)
            }
            fillEncoderR.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadGroupSize)
            fillEncoderR.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        self.leftTexture = leftEye
        self.rightTexture = rightEye

        return (leftEye, rightEye)
    }

    /// Generate a hue-based depth scale visualization.
    public func generateHueRepresentation(
        depth: MTLTexture,
        width: Int,
        height: Int
    ) -> MTLTexture {
        var hueMap: [UInt8] = [UInt8](repeating: 0, count: width * height * 4)

        let hueScale = Float(width * height) * 0.025
        let thetaGrad = Float(width) * 0.025
        let _ = thetaGrad

        for i in 0..<(width * height) {
            let hueF = Float(i) * hueScale
            let hueUInt = UInt8(hueF.magnitude)
            let r = UInt8(hueUInt / 124 % 255)
            let g = UInt8(255 - r)
            let b = UInt8(hueUInt * 2 % 255)

            let idx = i * 4
            hueMap[idx] = r
            hueMap[idx + 1] = g
            hueMap[idx + 2] = b
            hueMap[idx + 3] = 255
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )

        guard let hueTexture = pipeline.device.makeTexture(descriptor: textureDescriptor) else {
            fatalError("Failed to create hue visualization texture")
        }

        let bytesPerRow = width * 4
        hueMap.withUnsafeBytes { ptr in
            hueTexture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return hueTexture
    }

    /// Apply depth feathering around depth map edges.
    ///
    /// - Deprecated: This CPU implementation was a no-op stub (it only memcpy'd the buffer
    ///   unchanged) and was never called anywhere in `compose()`. Edge-aware depth smoothing
    ///   is now done properly on the GPU via the `bilateralFilterDepth` Metal kernel
    ///   (see StereoWarp.metal), which runs automatically as part of `compose()` before the
    ///   stereo warp samples the depth map. This method is kept only for public-API source
    ///   compatibility and should not be used — it does nothing useful.
    @available(*, deprecated, message: "No-op; depth smoothing now runs on GPU inside compose() via bilateralFilterDepth")
    public func applyDepthFeathering(depthMap: CVPixelBuffer) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        var feathered: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &feathered
        )
        guard status == kCVReturnSuccess, let result = feathered else {
            return depthMap
        }

        CVPixelBufferLockBaseAddress(depthMap, [])
        CVPixelBufferLockBaseAddress(result, [])

        if let sourceBaseAddress = CVPixelBufferGetBaseAddress(depthMap),
           let destBaseAddress = CVPixelBufferGetBaseAddress(result) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
            for y in 0..<height {
                let src = sourceBaseAddress.advanced(by: y * bytesPerRow)
                let dst = destBaseAddress.advanced(by: y * bytesPerRow)
                memcpy(dst, src, bytesPerRow)
            }
        }

        CVPixelBufferUnlockBaseAddress(depthMap, [])
        CVPixelBufferUnlockBaseAddress(result, [])

        return result
    }

    // MARK: - SBS Cleanup

    /// Release held textures at end of frame.
    public func releaseTextures() {
        leftTexture = nil
        rightTexture = nil
    }
}
