import Foundation
import AVFoundation
import CoreVideo

// MARK: - FFmpeg C Constants

let AV_NOPTS_VALUE = Int64.min
let AVERROR_EOF = -12
let AVERROR_EAGAIN = -11
let AVSEEK_FLAG_BACKWARD = 1

// Pixel format constants
let AV_PIX_FMT_YUV420P = 0
let AV_PIX_FMT_YUVJ420P = 7
let AV_PIX_FMT_NV12 = 23
let AV_PIX_FMT_P010 = 9
let AV_PIX_FMT_NONE = -1
let AV_PIX_FMT_BGR0 = 47
let AV_PIX_FMT_BGRA = 26

let AV_CODEC_ID_NONE = 0
let AV_CODEC_ID_H264 = 27
let AV_CODEC_ID_HEVC = 1314472139
let AV_CODEC_ID_MPEG4 = 13
let AV_CODEC_ID_VP8 = 208
let AV_CODEC_ID_VP9 = 317
let AV_CODEC_ID_AV1 = 3774326387

// AVMediaType constants
let AVMEDIA_TYPE_VIDEO = 1
let AVMEDIA_TYPE_AUDIO = 0

// Sws flags
let SWS_BILINEAR = 2

// MARK: - FFmpeg C Types

public struct AVRational {
    public var num: Int32
    public var den: Int32
    public init(num: Int32 = 0, den: Int32 = 0) { self.num = num; self.den = den }
}

public enum AVCodecID: Int32 {
    case none = 0
    case h264 = 27
    case hevc = 1314472139
    case mpeg4 = 13
    case vp8 = 208
    case vp9 = 317
    case av1 = -520171097
}

// AVPacket simplified (matches FFmpeg 8.x layout)
public struct AVPacket {
    public var data: UnsafeMutablePointer<UInt8>?
    var pts: Int64
    var dts: Int64
    public var buffer: OpaquePointer?
    public var sideData: UnsafeMutableRawPointer?
    public var sideDataElements: CInt
    public var duration: Int64
    public var streamIndex: CInt
    public var flags: CUnsignedInt
    public var formatData: OpaquePointer?

    public init() {
        self.data = nil
        self.pts = 0
        self.dts = 0
        self.buffer = nil
        self.sideData = nil
        self.sideDataElements = 0
        self.duration = 0
        self.streamIndex = 0
        self.flags = 0
        self.formatData = nil
    }
}

// MARK: - C Function Declarations

@_silgen_name("avformat_alloc_context")
func avformat_alloc_context() -> OpaquePointer?

@_silgen_name("avformat_open_input")
func avformat_open_input(_ pContext: UnsafeMutablePointer<OpaquePointer?>?, _ filename: UnsafePointer<CChar>?, _ fmt: OpaquePointer?, _ opts: OpaquePointer?) -> Int32

@_silgen_name("avformat_find_stream_info")
func avformat_find_stream_info(_ s: OpaquePointer?, _ opts: OpaquePointer?) -> Int32

@_silgen_name("avformat_close_input")
func avformat_close_input(_ pbContext: UnsafeMutablePointer<OpaquePointer?>?)

@_silgen_name("avformat_get_streams")
func avformat_get_streams(_ s: OpaquePointer?) -> UnsafeMutablePointer<OpaquePointer?>?

@_silgen_name("avformat_get_nb_streams")
func avformat_get_nb_streams(_ s: OpaquePointer?) -> CInt

@_silgen_name("av_format_get_duration")
func av_format_get_duration(_ s: OpaquePointer?) -> Int64

@_silgen_name("av_stream_get_codecpar")
func av_stream_get_codecpar(_ s: OpaquePointer?) -> OpaquePointer?

@_silgen_name("av_stream_get_r_frame_rate")
func av_stream_get_r_frame_rate(_ s: OpaquePointer?) -> AVRational

@_silgen_name("av_stream_get_height")
func av_stream_get_height(_ s: OpaquePointer?) -> Int

@_silgen_name("av_stream_get_width")
func av_stream_get_width(_ s: OpaquePointer?) -> Int

@_silgen_name("avcodec_find_decoder")
func avcodec_find_decoder(_ id: AVCodecID) -> OpaquePointer?

@_silgen_name("avcodec_context_alloc")
func avcodec_context_alloc(_ id: AVCodecID) -> OpaquePointer?

@_silgen_name("avcodec_open2")
func avcodec_open2(_ avctx: OpaquePointer?, _ codec: OpaquePointer?, _ options: OpaquePointer?) -> Int32

@_silgen_name("avcodec_parameters_to_context")
func avcodec_parameters_to_context(_ dec: OpaquePointer?, _ par: OpaquePointer?) -> Int32

@_silgen_name("avcodec_free_context")
func avcodec_free_context(_ p0: UnsafeMutablePointer<OpaquePointer?>?)

@_silgen_name("avcodec_free_frame")
func avcodec_free_frame(_ p0: UnsafeMutablePointer<OpaquePointer?>?)

@_silgen_name("avcodec_alloc_frame")
func avcodec_alloc_frame() -> OpaquePointer?

@_silgen_name("av_read_frame")
func av_read_frame(_ s: OpaquePointer?, _ packet: UnsafeMutablePointer<AVPacket>) -> Int32

@_silgen_name("av_init_packet")
func av_init_packet(_ pkt: UnsafeMutablePointer<AVPacket>) -> Int32

@_silgen_name("av_packet_unref")
func av_packet_unref(_ pkt: UnsafeMutablePointer<AVPacket>)

@_silgen_name("avcodec_send_packet")
func avcodec_send_packet(_ avctx: OpaquePointer?, _ avpkt: UnsafeMutablePointer<AVPacket>) -> Int32

@_silgen_name("avcodec_receive_frame")
func avcodec_receive_frame(_ avctx: OpaquePointer?, _ frame: OpaquePointer?) -> Int32

@_silgen_name("sws_getContext")
func sws_getContext(_ srcW: CInt, _ srcH: CInt, _ srcFormat: Int32, _ dstW: CInt, _ dstH: CInt, _ dstFormat: Int32, _ flags: CInt, _ srcFilter: UnsafeMutablePointer<UInt8>?, _ dstFilter: UnsafeMutablePointer<UInt8>?, _ param: UnsafeMutablePointer<Double>?) -> OpaquePointer?

@_silgen_name("sws_scale")
func sws_scale(_ c: OpaquePointer?, _ srcSlice: UnsafePointer<UnsafePointer<UInt8>?>?, _ srcStride: UnsafePointer<CInt>?, _ srcSliceY: CInt, _ numSlices: CInt, _ dst: UnsafePointer<UnsafeMutablePointer<UInt8>?>?, _ dstStride: UnsafePointer<CInt>?) -> CInt

@_silgen_name("sws_freeContext")
func sws_freeContext(_ c: OpaquePointer?)

@_silgen_name("av_seek_frame")
func av_seek_frame(_ s: OpaquePointer?, _ streamIndex: CInt, _ timestamp: Int64, _ flags: CInt) -> Int32

@_silgen_name("avcodec_flush_buffers")
func avcodec_flush_buffers(_ avctx: OpaquePointer?) -> Int32

@_silgen_name("av_strerror")
func av_strerror(_ err: Int32, _ errbuf: UnsafeMutablePointer<Int8>, _ errbufSize: Int64) -> OpaquePointer?

@_silgen_name("av_log_set_level")
func av_log_set_level(_ level: Int32)

@_silgen_name("avformat_network_init")
func avformat_network_init()

@_silgen_name("av_frame_get_width")
func av_frame_get_width(_ frame: OpaquePointer?) -> Int

@_silgen_name("av_frame_get_height")
func av_frame_get_height(_ frame: OpaquePointer?) -> Int

@_silgen_name("av_frame_get_format")
func av_frame_get_format(_ frame: OpaquePointer?) -> CInt

@_silgen_name("av_frame_get_data")
func av_frame_get_data(_ frame: OpaquePointer?) -> UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?

@_silgen_name("av_frame_get_linesize")
func av_frame_get_linesize(_ frame: OpaquePointer?) -> UnsafeMutablePointer<CInt>?

@_silgen_name("av_buffer_ref")
func av_buffer_ref(_ buf: OpaquePointer?) -> OpaquePointer?

@_silgen_name("av_frame_get_pkt_duration")
func av_frame_get_pkt_duration(_ frame: OpaquePointer?) -> Int64

@_silgen_name("av_frame_get_best_effort_timestamp")
func av_frame_get_best_effort_timestamp(_ frame: OpaquePointer?) -> Int64

// MARK: - FFmpeg Decoder

public class FFmpegDecoder: VideoDecoderProtocol {
    private var formatContext: OpaquePointer?
    private var codecContext: OpaquePointer?
    private var frame: OpaquePointer?
    private var swsContext: OpaquePointer?
    private var videoStreamIndex: CInt = -1

    public private(set) var videoWidth: Int = 0
    public private(set) var videoHeight: Int = 0
    public private(set) var frameRate: Double = 30.0
    public private(set) var duration: Double = 0

    private var isPlaying = false
    private var packetQueue: [AVPacket] = []

    public init() {
        avformat_network_init()
        av_log_set_level(0) // AV_LOG_PANIC
    }

    deinit {
        close()
    }

    public func loadVideo(at url: URL) throws {
        close()

        var formatCtx: OpaquePointer? = nil
        let path = url.absoluteString.replacingOccurrences(of: "file://", with: "")
        let cPath = path.cString(using: .utf8)!

        guard avformat_open_input(&formatCtx, cPath, nil, nil) >= 0 else {
            throw NSError(domain: "FFmpegDecoder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open video: \(path)"])
        }

        guard avformat_find_stream_info(formatCtx, nil) >= 0 else {
            avformat_close_input(&formatCtx)
            throw NSError(domain: "FFmpegDecoder", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not find stream info"])
        }

        formatContext = formatCtx

        // Get duration
        let durationTicks = av_format_get_duration(formatCtx)
        if durationTicks > 0 {
            duration = Double(durationTicks) / 1_000_000.0
        }

        // Find video stream
        let nbStreams = avformat_get_nb_streams(formatCtx)
        guard let streams = avformat_get_streams(formatCtx) else {
            throw NSError(domain: "FFmpegDecoder", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "No streams found"])
        }

        for i in 0..<nbStreams {
            let stream = streams.advanced(by: Int(i)).pointee
            // Check if this is a video stream by looking at codecpar
            if av_stream_get_codecpar(stream) != nil {
                let width = av_stream_get_width(stream)
                let height = av_stream_get_height(stream)
                if width > 0 || height > 0 {
                    videoStreamIndex = CInt(i)
                    videoWidth = width
                    videoHeight = height

                    let r = av_stream_get_r_frame_rate(stream)
                    if r.num > 0 && r.den > 0 {
                        frameRate = Double(r.num) / Double(r.den)
                    }

                    // Open codec
                    guard let codecpar = av_stream_get_codecpar(stream) else { break }

                    // We can't easily get the codec ID from codecpar without more C bindings
                    // Try H.264 by default, then fall back
                    openDecoder(codecId: AVCodecID.h264, codecpar: codecpar)
                    if codecContext == nil {
                        // Try other codecs
                        for tryId in [AVCodecID.hevc, AVCodecID.mpeg4, AVCodecID.vp9, AVCodecID.vp8] {
                            openDecoder(codecId: tryId, codecpar: codecpar)
                            if codecContext != nil { break }
                        }
                    }

                    guard codecContext != nil else { break }

                    break
                }
            }
        }

        guard videoStreamIndex >= 0 else {
            throw NSError(domain: "FFmpegDecoder", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "No video stream found"])
        }

        guard codecContext != nil else {
            throw NSError(domain: "FFmpegDecoder", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open decoder"])
        }

        frame = avcodec_alloc_frame()
    }

    private func openDecoder(codecId: AVCodecID, codecpar: OpaquePointer) {
        guard let decoder = avcodec_find_decoder(codecId) else { return }
        guard let ctx = avcodec_context_alloc(codecId) else { return }

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            var tmp: OpaquePointer? = ctx
            avcodec_free_context(&tmp)
            return
        }

        guard avcodec_open2(ctx, decoder, nil) >= 0 else {
            var tmp: OpaquePointer? = ctx
            avcodec_free_context(&tmp)
            return
        }

        codecContext = ctx
    }

    public func decodeNextFrame() throws -> CVBuffer? {
        guard let formatCtx = formatContext, let cctx = codecContext, let f = frame else { return nil }

        // Try to get next frame
        var pkt = AVPacket()

        while av_read_frame(formatCtx, &pkt) >= 0 {
            defer { av_packet_unref(&pkt) }
            guard pkt.streamIndex == videoStreamIndex else { continue }

            let sendResult = avcodec_send_packet(cctx, &pkt)
            guard sendResult >= 0 else { continue }

            // With a single packet, we should get at most one frame
            let recvResult = avcodec_receive_frame(cctx, f)
            guard recvResult == 0 else { continue }

            // Convert frame to CVPixelBuffer
            return convertToPixelBuffer(frame: f)
        }

        // Return remaining frames from decoder buffer
        let recvResult = avcodec_receive_frame(cctx, f)
        if recvResult == 0 {
            return convertToPixelBuffer(frame: f)
        }

        return nil
    }

    private func convertToPixelBuffer(frame avFrame: OpaquePointer) -> CVBuffer? {
        let w = av_frame_get_width(avFrame)
        let h = av_frame_get_height(avFrame)
        let fmt = av_frame_get_format(avFrame)

        let srcData = av_frame_get_data(avFrame)
        let srcLinesize = av_frame_get_linesize(avFrame)

        guard let srcData = srcData, let srcLinesize = srcLinesize else { return nil }
        guard w > 0 && h > 0 else { return nil }

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            w,
            h,
            kCVPixelFormatType_32BGRA,
            pixelBufferAttributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pxbuf = pixelBuffer else { return nil }

        // Set up swscale context for YUV -> BGRA
        var swsCtx = swsContext
        if swsCtx == nil {
            swsCtx = sws_getContext(
                CInt(w), CInt(h), Int32(fmt),
                CInt(w), CInt(h), Int32(AV_PIX_FMT_BGRA),
                CInt(SWS_BILINEAR), nil, nil, nil
            )
            swsContext = swsCtx
        }

        guard let ctx = swsCtx else { return nil }

        CVPixelBufferLockBaseAddress(pxbuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pxbuf, .readOnly) }

        guard let dstData = CVPixelBufferGetBaseAddress(pxbuf) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(pxbuf)

        let srcPtrs = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: 4)
        let srcStrides = UnsafeMutablePointer<CInt>.allocate(capacity: 4)
        defer {
            srcPtrs.deallocate()
            srcStrides.deallocate()
        }

        srcPtrs.pointee = srcData[0].map { UnsafePointer<UInt8>($0) }
        srcPtrs.advanced(by: 1).pointee = srcData[1].map { UnsafePointer<UInt8>($0) }
        srcPtrs.advanced(by: 2).pointee = srcData[2].map { UnsafePointer<UInt8>($0) }
        srcPtrs.advanced(by: 3).pointee = nil

        srcStrides.pointee = srcLinesize[0]
        srcStrides.advanced(by: 1).pointee = srcLinesize[1]
        srcStrides.advanced(by: 2).pointee = srcLinesize[2]
        srcStrides.advanced(by: 3).pointee = 0

        var dstPtrs: [UnsafeMutablePointer<UInt8>?] = [
            UnsafeMutablePointer<UInt8>(OpaquePointer(dstData)),
            nil, nil, nil
        ]
        var dstStrides: [CInt] = [
            CInt(dstStride), 0, 0, 0
        ]

        let rows = dstPtrs.withUnsafeMutableBufferPointer { dstPtrBuf in
            let dstData: UnsafePointer<UnsafeMutablePointer<UInt8>?>? = dstPtrBuf.baseAddress.map { UnsafePointer($0) }
            dstStrides.withUnsafeMutableBufferPointer { dstStrideBuf in
                let dstLinesize: UnsafePointer<CInt>? = dstStrideBuf.baseAddress.map { UnsafePointer($0) }
                sws_scale(ctx, srcPtrs, srcStrides, 0, CInt(h), dstData, dstLinesize)
            }
        }

        return rows > 0 ? pxbuf : nil
    }

    public func seek(to timestamp: Double) throws {
        guard let formatCtx = formatContext else { return }

        let ts = Int64(timestamp * Double(avformat_get_nb_streams(formatCtx)))
        let result = av_seek_frame(formatCtx, videoStreamIndex, ts, CInt(AVSEEK_FLAG_BACKWARD))

        guard result >= 0 else {
            throw NSError(domain: "FFmpegDecoder", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Seek failed"])
        }

        if let cctx = codecContext {
            _ = avcodec_flush_buffers(cctx)
        }
    }

    public func stop() {
        close()
    }

    public func start() {
        isPlaying = true
    }

    public func pause() {
        isPlaying = false
    }

    public func reset() {
        isPlaying = false
        close()
    }

    /// Convenience wrapper used by the render loop.
    public func decodeFrame() -> CVPixelBuffer? {
        do {
            return try decodeNextFrame()
        } catch {
            return nil
        }
    }

    private func close() {
        if let ctx = codecContext {
            var tmp: OpaquePointer? = ctx
            avcodec_free_context(&tmp)
            codecContext = nil
        }

        if let f = frame {
            var tmp: OpaquePointer? = f
            avcodec_free_frame(&tmp)
            frame = nil
        }

        sws_freeContext(swsContext)
        swsContext = nil

        if let ctx = formatContext {
            var tmp: OpaquePointer? = ctx
            avformat_close_input(&tmp)
            formatContext = nil
        }

        videoStreamIndex = -1
        isPlaying = false
    }
}
