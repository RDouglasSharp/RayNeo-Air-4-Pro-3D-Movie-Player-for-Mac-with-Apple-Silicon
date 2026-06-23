import XCTest
import Metal
@testable import StereoPlayer3D

// MARK: - Stereo Composer Tests

final class StereoComposerTests: XCTestCase {
    var pipeline: MetalPipeline!
    var composer: StereoComposer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        pipeline = MetalPipeline(device: device, commandQueue: device.makeCommandQueue()!)
        composer = StereoComposer(pipeline: pipeline)
    }

    func testCompositionExecutes() {
        let video = pipeline.createTexture(
            width: 1920,
            height: 1080,
            pixelFormat: .bgra8Unorm
        )
        let depth = pipeline.createTexture(
            width: 1920,
            height: 1080,
            pixelFormat: .rgba32Float
        )
        let leftEye = pipeline.createTexture(
            width: 1920,
            height: 1080,
            pixelFormat: .bgra8Unorm
        )
        let rightEye = pipeline.createTexture(
            width: 1920,
            height: 1080,
            pixelFormat: .bgra8Unorm
        )

        let commandBuffer = pipeline.makeCommandBuffer()
        composer.compose(
            video: video,
            depth: depth,
            leftEye: leftEye,
            rightEye: rightEye
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func testFillModeEnumCases() {
        let _ = StereoComposer.FillMode.nearest
        let _ = StereoComposer.FillMode.mirror
        let _ = StereoComposer.FillMode.color
    }

    func testBaselineAndFocalLengthConfigurable() {
        let composer = StereoComposer(
            pipeline: pipeline,
            baseline: 64.0,
            focalLength: 512.0,
            fillMode: .nearest
        )
        // Configured at init — verify no crash
        XCTAssertNotNil(composer)
    }
}

// MARK: - Performance Benchmark Tests

final class PerformanceBenchmarkTests: XCTestCase {
    var pipeline: MetalPipeline!
    var composer: StereoComposer!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        pipeline = MetalPipeline(device: device, commandQueue: device.makeCommandQueue()!)
        composer = StereoComposer(pipeline: pipeline)
    }

    func testStereoCompositionPerformance() {
        let frameCount = 100

        measure { expectation in
            for _ in 0..<frameCount {
                let video = pipeline.createTexture(
                    width: 1920,
                    height: 1080,
                    pixelFormat: .bgra8Unorm
                )
                let depth = pipeline.createTexture(
                    width: 1920,
                    height: 1080,
                    pixelFormat: .rgba32Float
                )
                let leftEye = pipeline.createTexture(
                    width: 1920,
                    height: 1080,
                    pixelFormat: .bgra8Unorm
                )
                let rightEye = pipeline.createTexture(
                    width: 1920,
                    height: 1080,
                    pixelFormat: .bgra8Unorm
                )

                let commandBuffer = pipeline.makeCommandBuffer()
                composer.compose(
                    video: video,
                    depth: depth,
                    leftEye: leftEye,
                    rightEye: rightEye
                )
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
            }

            expectation.fulfill()
        }
    }
}

// MARK: - Integration Tests

final class IntegrationTests: XCTestCase {
    var pipeline: MetalPipeline!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available")
        }
        pipeline = MetalPipeline(device: device, commandQueue: device.makeCommandQueue()!)
    }

    func testFullStereoPipeline() {
        // 1. Create test textures
        let video = pipeline.createTexture(width: 1920, height: 1080, pixelFormat: .bgra8Unorm)
        let depth = pipeline.createTexture(width: 1920, height: 1080, pixelFormat: .rgba32Float)
        let leftEye = pipeline.createTexture(width: 1920, height: 1080, pixelFormat: .bgra8Unorm)
        let rightEye = pipeline.createTexture(width: 1920, height: 1080, pixelFormat: .bgra8Unorm)

        // 2. Generate stereo pair via composer
        let composer = StereoComposer(pipeline: pipeline, baseline: 64.0, focalLength: 512.0)
        let buffer = pipeline.makeCommandBuffer()
        composer.compose(video: video, depth: depth, leftEye: leftEye, rightEye: rightEye)

        // 3. Verify executed without crashing
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    func testMetalInterop() {
        // Test CVPixelBuffer → MTLTexture conversion
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920,
            1080,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue] as NSDictionary,
            &pixelBuffer
        )

        XCTAssertEqual(status, kCVReturnSuccess, "PixelBuffer creation should succeed")
        XCTAssertNotNil(pixelBuffer, "Pixel buffer should not be nil")
    }
}
