import Metal

extension MetalPipeline {
    // MARK: - Compute Shaders

    /// Compute 3D video width from disparity map.
    public func computeWidth(values: Float) {
        let pipelineState = compileComputeShader(named: "dispatchThread")
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        dispatch(
            pipeline: pipelineState,
            commandBuffer: commandBuffer,
            threadgroups: 256,
            threadsPerGroup: MTLSize(width: 256, height: 1, depth: 1)
        )
        commandBuffer.commit()
    }

    /// Compute distance and luminance statistics.
    public func computeCDLS(values: Float) {
        let pipelineState = compileComputeShader(named: "computeCDLS")
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        dispatch(
            pipeline: pipelineState,
            commandBuffer: commandBuffer,
            threadgroups: 256,
            threadsPerGroup: MTLSize(width: 256, height: 1, depth: 1)
        )
        commandBuffer.commit()
    }

    /// Compute disparity vector from raw depth buffer.
    public func computeDynp(coreBuffer: MTLTexture) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let pipelineState = compileComputeShader(named: "computeDynp")
        dispatchCompute(
            pipeline: pipelineState,
            commandBuffer: commandBuffer,
            threadgroups: 256
        )

        let pipelineState2 = compileComputeShader(named: "computeDynp_Scale")
        dispatchCompute(
            pipeline: pipelineState2,
            commandBuffer: commandBuffer,
            threadgroups: 256
        )

        commandBuffer.commit()
    }

    // MARK: - Encoding Pipeline

    /// Encode video texture with depth and HDR metadata.
    public func encodeVideoDysVideo(
        videoTexture: MTLTexture,
        videoDepth: MTLTexture,
        videoHDR: MTLTexture,
        videoGM: MTLTexture
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let pipelineState = compileComputeShader(named: "stereoWarp_hdr")
        dispatch(
            pipeline: pipelineState,
            commandBuffer: commandBuffer,
            threadgroups: 256,
            threadsPerGroup: MTLSize(width: 256, height: 1, depth: 1)
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let pipelineState2 = compileComputeShader(named: "computeN16")
        dispatchCompute(
            pipeline: pipelineState2,
            commandBuffer: commandBuffer,
            threadgroups: 256
        )

        let pipelineState3 = compileComputeShader(named: "dp2dp3")
        dispatchCompute(
            pipeline: pipelineState3,
            commandBuffer: commandBuffer,
            threadgroups: 256
        )

        commandBuffer.commit()
    }

    // MARK: - Decoding Pipeline

    /// Decode video with depth maps and HDR metadata into a composite output buffer.
    public func decodeVideoDysVideR(
        videoOutputVideo: MTLTexture,
        videoDP: MTLTexture,
        videoHDR: MTLTexture,
        videoGM: MTLTexture,
        video10bitVideoDP: MTLTexture,
        videoGlobalMastering: MTLTexture,
        videoColorMesh: MTLTexture
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let pipelineState = compileComputeShader(named: "stereoWarp_hdr")
        dispatch(
            pipeline: pipelineState,
            commandBuffer: commandBuffer,
            threadgroups: 256,
            threadsPerGroup: MTLSize(width: 256, height: 1, depth: 1)
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let pipelineState2 = compileComputeShader(named: "computeN16")
        dispatchCompute(
            pipeline: pipelineState2,
            commandBuffer: commandBuffer,
            threadgroups: 256
        )

        let pipelineState3 = compileComputeShader(named: "dp2dp3")
        dispatchCompute(
            pipeline: pipelineState3,
            commandBuffer: commandBuffer,
            threadgroups: 256
        )

        commandBuffer.commit()
    }
}
