import Foundation
import CoreML
import Vision
import Accelerate
import AVFoundation

/// Monocular depth estimation via Apple Depth Anything V2 (Core ML).
///
/// Uses apple/coreml-depth-anything-v2-small model.
/// Input: CVPixelBuffer resized to 392x518 (height x width), RGB
/// Output: CVPixelBuffer grayscale float16 depth map, 392x518
///
/// Reference implementation:
/// https://huggingface.co/spaces/apple/coreml-examples/tree/main/depth-anything-example
public final class DepthEstimator {
    private let model: MLModel
    let inputWidth: Int = 518
    let inputHeight: Int = 392
    let targetSize = CGSize(width: 518, height: 392)
    private var debugCount = 0

    public init() throws {
        guard let modelURL = Bundle.main.url(
            forResource: "DepthAnythingV2SmallF16",
            withExtension: "mlmodelc"
        ) else {
            throw NSError(
                domain: "DepthEstimator",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Model not found. Ensure DepthAnythingV2SmallF16.mlmodelc is in target resources."
                ]
            )
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine

        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    /// Estimate depth from a CVPixelBuffer image.
    ///
    /// - Parameter imageBuffer: Input RGB image buffer
    /// - Returns: Scaled depth disparity CVPixelBuffer (RGBA format)
    public func estimateDepth(from imageBuffer: CVPixelBuffer) -> CVPixelBuffer {
        // Output depth map matches the ORIGINAL video frame's dimensions, since that's
        // what the stereo warp shader samples 1:1 against the color frame.
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        let outputImageBuffer: CVPixelBuffer = {
            var outBuffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &outBuffer
            )
            return outBuffer!
        }()

        // The model has a FIXED input resolution (518x396) — resize the frame down to
        // that before feeding it in. Mismatched dims here silently corrupt the output
        // (model still "runs" but the result no longer has video-frame stride/shape).
        guard let resized = processVisionInput(image: imageBuffer) else {
            logDebug("DEPTH DEBUG: processVisionInput returned nil — falling back to black depth\n")
            return outputImageBuffer
        }

        // Model input "image" is declared as Image type — pass CIImage or CVPixelBuffer directly.
        let featureValue = MLFeatureValue(pixelBuffer: resized)
        guard let inputFeatures = try? MLDictionaryFeatureProvider(dictionary: ["image": featureValue]) else {
            logDebug("DEPTH FEATURES failed\n")
            return outputImageBuffer
        }
        guard let prediction = try? model.prediction(from: inputFeatures) else {
            logDebug("DEPTH PREDICTION failed\n")
            return outputImageBuffer
        }
        logDebug("DEPTH MODELOUTPUTS: \(Array(prediction.featureNames))\n")
        guard let fv_depth = prediction.featureValue(for: "depth") else {
            logDebug("DEPTH 'depth' key not found in prediction outputs\n")
            return outputImageBuffer
        }
        // The model outputs a grayscale float16 image
        guard let depthBuffer = fv_depth.imageBufferValue else {
            logDebug("DEPTH 'depth' output has no imageBufferValue (type=\(fv_depth.type))\n")
            return outputImageBuffer
        }
        let modelW = CVPixelBufferGetWidth(depthBuffer)
        let modelH = CVPixelBufferGetHeight(depthBuffer)
        logDebug("DEPTH OUTPUT: \(modelW)x\(modelH)\n")
        // Read depth values from grayscale float16 pixel buffer
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        let modelCount = modelW * modelH
        var smallDepth = [Float](repeating: 0, count: modelCount)
        guard let depthBase = CVPixelBufferGetBaseAddressOfPlane(depthBuffer, 0) else {
            CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)
            return outputImageBuffer
        }
        let depthBPR = CVPixelBufferGetBytesPerRowOfPlane(depthBuffer, 0)
        // Each pixel is 16-bit float (2 bytes). Read as UInt16 and convert to Float.
        for y in 0..<modelH {
            let row = depthBase.advanced(by: y * depthBPR)
            for x in 0..<modelW {
                let p = row.advanced(by: x * 2)
                let rawValue = p.loadUnaligned(as: UInt16.self)
                smallDepth[y * modelW + x] = Float(Float16(bitPattern: rawValue))
            }
        }
        CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly)

        if debugCount == 0 {
            let minVal = smallDepth.min() ?? 0
            let maxVal = smallDepth.max() ?? 0
            let nanCount = smallDepth.filter { !$0.isFinite }.count
            logDebug("DEPTH VALUES[0]: min=\(minVal) max=\(maxVal) nanCount=\(nanCount)/\(smallDepth.count)\n")
            debugCount += 1
        }

        let byteCount = width * height * 4
        var buffers = [UInt8](repeating: 0, count: byteCount)
        let scaleX = Float(modelW) / Float(width)
        let scaleY = Float(modelH) / Float(height)

        for y in 0..<height {
            // Map output row back into model-space, bilinearly
            let sy = (Float(y) + 0.5) * scaleY - 0.5
            let y0 = max(0, min(modelH - 1, Int(floor(sy))))
            let y1 = max(0, min(modelH - 1, y0 + 1))
            let fy = max(0, min(1, sy - Float(y0)))

            for x in 0..<width {
                let sx = (Float(x) + 0.5) * scaleX - 0.5
                let x0 = max(0, min(modelW - 1, Int(floor(sx))))
                let x1 = max(0, min(modelW - 1, x0 + 1))
                let fx = max(0, min(1, sx - Float(x0)))

                let v00 = smallDepth[y0 * modelW + x0]
                let v10 = smallDepth[y0 * modelW + x1]
                let v01 = smallDepth[y1 * modelW + x0]
                let v11 = smallDepth[y1 * modelW + x1]
                let v0 = v00 + (v10 - v00) * fx
                let v1 = v01 + (v11 - v01) * fx
                let v = v0 + (v1 - v0) * fy

                let idx = (y * width + x) * 4
                let byteVal = UInt8(max(0, min(255, v * 255.0)))
                buffers[idx]     = byteVal
                buffers[idx + 1] = byteVal
                buffers[idx + 2] = byteVal
                buffers[idx + 3] = 255
            }
        }

        CVPixelBufferLockBaseAddress(outputImageBuffer, [])
        if let outputBaseAddress = CVPixelBufferGetBaseAddress(outputImageBuffer) {
            let dstBPR = CVPixelBufferGetBytesPerRow(outputImageBuffer)
            if dstBPR == width * 4 {
                memcpy(outputBaseAddress, &buffers, byteCount)
            } else {
                // Respect actual row stride if CoreVideo padded rows
                buffers.withUnsafeBytes { src in
                    for y in 0..<height {
                        memcpy(
                            outputBaseAddress.advanced(by: y * dstBPR),
                            src.baseAddress!.advanced(by: y * width * 4),
                            width * 4
                        )
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(outputImageBuffer, [])

        return outputImageBuffer
    }

    // MARK: - Voxel Conversion

    /// Convert RGBA depth map to NV12 YUV expected by video encoder.
    public func convertRGBAtoYUV(pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var outPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            nil,
            &outPixelBuffer
        )
        guard status == kCVReturnSuccess, let output = outPixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let yBase = CVPixelBufferGetBaseAddress(output) else {
            return nil
        }

        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let yBytesPerRow = CVPixelBufferGetBytesPerRow(output)

        // Extract Y (luma) from RGBA: Y = 0.299*R + 0.587*G + 0.114*B
        for y in 0..<height {
            let srcRow = srcBase.advanced(by: y * srcBytesPerRow)
            let yRow = yBase.advanced(by: y * yBytesPerRow)
            for x in 0..<width {
                let p = srcRow.advanced(by: x * 4)
                let b = Float(p.loadUnaligned(as: UInt8.self))
                let g = Float(p.advanced(by: 1).loadUnaligned(as: UInt8.self))
                let r = Float(p.advanced(by: 2).loadUnaligned(as: UInt8.self))
                let yVal = r * 0.299 + g * 0.587 + b * 0.114
                yRow.advanced(by: x).storeBytes(of: UInt8(yVal), as: UInt8.self)
            }
        }

        // Fill CbCr plane with neutral values (no chroma for depth map)
        if let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(output, 1) {
            let cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
            let halfHeight = (height + 1) / 2
            for y in 0..<halfHeight {
                let row = cbcrBase.advanced(by: y * cbcrBytesPerRow)
                let halfWidth = (width + 1) / 2
                for x in 0..<halfWidth {
                    row.advanced(by: x * 2).storeBytes(of: UInt8(128), as: UInt8.self) // Cb
                    row.advanced(by: x * 2 + 1).storeBytes(of: UInt8(128), as: UInt8.self) // Cr
                }
            }
        }

        return output
    }

    // MARK: - Depth Map Utilities

    /// Generate a synthetic depth gradient (for testing without actual depth model).
    public static func generateDepthMap(
        width: Int,
        height: Int,
        focalLength: Float
    ) -> CVPixelBuffer {
        let depthBuffer: CVPixelBuffer = {
            // No IOSurface backing — this buffer is written by CPU from Metal
            var outBuffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &outBuffer
            )
            return outBuffer!
        }()

        CVPixelBufferLockBaseAddress(depthBuffer, [])
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else {
            CVPixelBufferUnlockBaseAddress(depthBuffer, [])
            return depthBuffer
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
        for y in 0..<height {
            let rowPtr = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let ptr = rowPtr.advanced(by: x * 4)
                // Normalize coordinates to depth range
                let normX = Float(x) / Float(width)
                let normY = Float(y) / Float(height)

                // Convert normalized → depth
                // 0 = infinity (far plane), 255 = near (2.5m)
                let depthRaw = normX * normY * focalLength
                let depth = UInt8(min(255, max(0, Int(depthRaw))))

                ptr.storeBytes(of: depth, as: UInt8.self)                     // R
                ptr.advanced(by: 1).storeBytes(of: UInt8(depth), as: UInt8.self) // G
                ptr.advanced(by: 2).storeBytes(of: UInt8(depth), as: UInt8.self) // B
                ptr.advanced(by: 3).storeBytes(of: UInt8(255), as: UInt8.self)   // A
            }
        }
        CVPixelBufferUnlockBaseAddress(depthBuffer, [])
        return depthBuffer
    }
}

// MARK: - Vision Processing (Rescale + ROI)

extension DepthEstimator {
    /// Resize input image to depth model input dimensions (518x396).
    public func processVisionInput(image: CVPixelBuffer) -> CVPixelBuffer? {
        let srcWidth = CVPixelBufferGetWidth(image)
        let srcHeight = CVPixelBufferGetHeight(image)
        let dstWidth = inputWidth
        let dstHeight = inputHeight

        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            dstWidth,
            dstHeight,
            kCVPixelFormatType_32BGRA,
            nil,
            &outputBuffer
        )
        guard status == kCVReturnSuccess, let output = outputBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(image, [])
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(image, [])
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(image),
              let dstBase = CVPixelBufferGetBaseAddress(output) else {
            return nil
        }

        let srcBPR = CVPixelBufferGetBytesPerRow(image)
        let dstBPR = CVPixelBufferGetBytesPerRow(output)
        let scaleX = Float(srcWidth) / Float(dstWidth)
        let scaleY = Float(srcHeight) / Float(dstHeight)

        for y in 0..<dstHeight {
            let srcY = Int(Float(y) * scaleY)
            let srcRow = srcBase.advanced(by: srcY * srcBPR)
            let dstRow = dstBase.advanced(by: y * dstBPR)
            for x in 0..<dstWidth {
                let srcX = Int(Float(x) * scaleX)
                let srcPtr = srcRow.advanced(by: srcX * 4)
                let dstPtr = dstRow.advanced(by: x * 4)
                dstPtr.storeBytes(of: srcPtr.loadUnaligned(as: UInt32.self), as: UInt32.self)
            }
        }

        return output
    }
}
