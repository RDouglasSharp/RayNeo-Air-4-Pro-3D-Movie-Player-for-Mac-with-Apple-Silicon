import XCTest
import Metal
@testable import StereoPlayer3D

// MARK: - Metal Pipeline Tests

final class MetalPipelineTests: XCTestCase {
    var pipeline: MetalPipeline!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is not available")
        }
        pipeline = MetalPipeline(device: device)
    }

    override func tearDownWithError() throws {
        pipeline = nil
    }

    func testPipelineInitialization() {
        XCTAssertNotNil(pipeline, "MetalPipeline should initialize")
        XCTAssertNotNil(pipeline.device, "Device should be set")
        XCTAssertNotNil(pipeline.commandQueue, "CommandQueue should be set")
    }

    func testTextureCreation() {
        let texture = pipeline.createTexture(
            width: 1920,
            height: 1080,
            pixelFormat: .bgra8Unorm
        )
        XCTAssertNotNil(texture, "Texture should be created")
        XCTAssertEqual(texture.width, 1920)
        XCTAssertEqual(texture.height, 1080)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
    }

    func testCommandBufferCreation() {
        guard let commandBuffer = pipeline.commandQueue?.makeCommandBuffer() else {
            throw XCTSkip("CommandQueue not available")
        }
        XCTAssertNotNil(commandBuffer, "CommandBuffer should be created")
        commandBuffer.commit()
    }
}

// MARK: - FFmpeg Decoder Tests

final class FFmpegDecoderTests: XCTestCase {
    var decoder: FFmpegDecoder!

    override func setUpWithError() throws {
        decoder = FFmpegDecoder()
    }

    override func tearDownWithError() throws {
        decoder?.close()
        decoder = nil
    }

    func testDecoderInitialization() {
        XCTAssertNotNil(decoder, "FFmpegDecoder should initialize")
        XCTAssertEqual(decoder.videoWidth, 0)
        XCTAssertEqual(decoder.videoHeight, 0)
    }

    func testOpenVideo() {
        guard let url = Bundle.module.url(
            forResource: "testvideo_4x4",
            withExtension: "mp4",
            subdirectory: "Test Resources"
        ) else {
            throw XCTSkip("Test video not found")
        }

        try decoder.loadVideo(at: url)
        decoder.start()
        XCTAssertGreaterThan(decoder.videoWidth, 0, "Width should be set")
        XCTAssertGreaterThan(decoder.videoHeight, 0, "Height should be set")
    }

    func testDecoderProperties() {
        guard let url = Bundle.module.url(
            forResource: "test_video_1920x1080_30fps",
            withExtension: "mkv",
            subdirectory: "TestResources"
        ) else {
            throw XCTSkip("Test video not found")
        }

        try decoder.loadVideo(at: url)
        decoder.start()
        XCTAssertEqual(decoder.videoWidth, 1920)
        XCTAssertEqual(decoder.videoHeight, 1080)
        XCTAssertEqual(decoder.frameRate, 30.0, accuracy: 0.1)
        XCTAssertGreaterThan(decoder.duration, 0)
    }
}
