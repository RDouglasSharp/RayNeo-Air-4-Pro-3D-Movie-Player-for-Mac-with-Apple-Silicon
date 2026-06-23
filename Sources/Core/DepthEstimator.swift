import Foundation
import CoreML
import Vision
import Accelerate
import AVFoundation

/// Monocular depth estimation via Apple Depth Anything V2 (Core ML).
///
/// Uses apple/coreml-depth-anything-v2-small model.
/// Input: 518x396 grayscale image
/// Output: Scaled disparity depth map as CVPixelBuffer
///
/// Reference implementation:
/// https://huggingface.co/spaces/apple/coreml-examples/tree/main/depth-anything-example
public final class DepthEstimator {
    private let model: MLModel
    let inputWidth: Int = 518
    let inputHeight: Int = 396
    let targetSize = CGSize(width: 518, height: 396)

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
        // New core buffer for output depth map (RGBA32, original image dimensions)
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

        // Create MLMultiArray input from pixel buffer (shape: [1, 3, height, width], type: Float32)
        let inputShape: [NSNumber] = [
            NSNumber(value: 1), NSNumber(value: 3),
            NSNumber(value: height), NSNumber(value: width)
        ]
        guard let inputArray = try? MLMultiArray(shape: inputShape, dataType: .float32) else {
            return outputImageBuffer
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) else {
            CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)
            return outputImageBuffer
        }
        let srcBPR = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)

        for y in 0..<height {
            let row = srcBase.advanced(by: y * srcBPR)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                let b: Float = Float(p.loadUnaligned(as: UInt8.self)) / 255.0
                let g: Float = Float(p.advanced(by: 1).loadUnaligned(as: UInt8.self)) / 255.0
                let r: Float = Float(p.advanced(by: 2).loadUnaligned(as: UInt8.self)) / 255.0
                let yIdx = NSNumber(value: y)
                let xIdx = NSNumber(value: x)
                inputArray[[0, 0, yIdx, xIdx]] = NSNumber(value: r)
                inputArray[[0, 1, yIdx, xIdx]] = NSNumber(value: g)
                inputArray[[0, 2, yIdx, xIdx]] = NSNumber(value: b)
            }
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)

        guard let featureValue = try? MLFeatureValue(multiArray: inputArray),
              let inputFeatures = try? MLDictionaryFeatureProvider(dictionary: ["image": featureValue]) else {
            return outputImageBuffer
        }
        guard let prediction = try? model.prediction(from: inputFeatures),
              let multiArray = prediction.featureValue(for: "depth")?.multiArrayValue else {
            return outputImageBuffer
        }

        let byteCount: Int = height * width * 4
        var buffers = [UInt8](repeating: 0, count: byteCount)
        let count = multiArray.count
        for i in 0..<min(count, byteCount / MemoryLayout<Double>.size) {
            let v = multiArray[i].doubleValue
            buffers[i * 4]    = UInt8(max(0, min(255, v * 255.0)))
            buffers[i * 4 + 1] = buffers[i * 4]
            buffers[i * 4 + 2] = buffers[i * 4]
            buffers[i * 4 + 3] = 255
        }

        CVPixelBufferLockBaseAddress(outputImageBuffer, [])
        if let outputBaseAddress = CVPixelBufferGetBaseAddress(outputImageBuffer) {
            memcpy(outputBaseAddress, &buffers, byteCount)
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
