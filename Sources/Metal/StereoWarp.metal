#include <metal_stdlib>
using namespace metal;

// MARK: - Stereo Warp Compute Kernel

struct StereoWarpParams {
    float inputWidth;
    float inputHeight;
    float outputWidth;
    float outputHeight;
    float baseline;
    float focalLength;
    float fillMode;
    float contentOffsetX;
    float contentOffsetY;
    float contentWidth;
    float contentHeight;
};

kernel void stereoWarp(
    texture2d<float, access::read> sourceTexture,
    texture2d<float, access::read> depthTexture,
    texture2d<float, access::write> leftEyeTexture,
    texture2d<float, access::write> rightEyeTexture,
    constant StereoWarpParams& params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= (uint)params.outputWidth || gid.y >= (uint)params.outputHeight) {
        return;
    }

    // Letterbox/pillarbox: output pixels outside content region are black
    if ((float)gid.x < params.contentOffsetX ||
        (float)gid.x >= (params.contentOffsetX + params.contentWidth) ||
        (float)gid.y < params.contentOffsetY ||
        (float)gid.y >= (params.contentOffsetY + params.contentHeight)) {
        leftEyeTexture.write(float4(0.0f), gid);
        rightEyeTexture.write(float4(0.0f), gid);
        return;
    }

    // Map content-region pixel to source UV coordinates
    float cx = (float)gid.x - params.contentOffsetX;
    float cy = (float)gid.y - params.contentOffsetY;
    float srcX = (cx / params.contentWidth) * params.inputWidth;
    float srcY = (cy / params.contentHeight) * params.inputHeight;

    float depth = depthTexture.read(uint2((int)srcX, (int)srcY)).r;
    float disparity = params.baseline * params.focalLength / max(depth * params.focalLength, 1.0f);

    float leftSrcX = srcX + disparity * 0.5f;
    float rightSrcX = srcX - disparity * 0.5f;

    constexpr sampler clampSampler(mag_filter::linear, min_filter::linear,
                                    coord::normalized, address::clamp_to_edge);

    float4 leftPixel = sampleLevel(
        sourceTexture, clampSampler,
        float2(leftSrcX / params.inputWidth, srcY / params.inputHeight),
        0.0f
    );

    float4 rightPixel = sampleLevel(
        sourceTexture, clampSampler,
        float2(rightSrcX / params.inputWidth, srcY / params.inputHeight),
        0.0f
    );

    leftEyeTexture.write(leftPixel, gid);
    rightEyeTexture.write(rightPixel, gid);
}

// MARK: - Fill Hole Kernel

kernel void fillHoles(
    texture2d<float, access::read_write> eyeTexture,
    texture2d<float, access::read> depthTexture,
    constant StereoWarpParams& params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= (uint)params.outputWidth || gid.y >= (uint)params.outputHeight) {
        return;
    }

    float4 pixel = eyeTexture.read(gid);
    if (pixel.a < 0.01f) {
        float4 nearest;
        int found = 0;

        for (int dx = -16; dx <= 16; dx++) {
            for (int dy = -16; dy <= 16; dy++) {
                int2 checkPos = int2(gid.x + dx, gid.y + dy);
                if (checkPos.x >= 0 && checkPos.x < (int)params.outputWidth &&
                    checkPos.y >= 0 && checkPos.y < (int)params.outputHeight) {
                    float4 check = eyeTexture.read(checkPos);
                    if (check.a >= 0.01f) {
                        nearest = check;
                        found = 1;
                        break;
                    }
                }
            }
            if (found) break;
        }

        if (found) {
            eyeTexture.write(nearest, gid);
        }
    }
}

// MARK: - Vertex Shader for SBS Rendering

struct SBSVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex SBSVertexOut SBSVertex(
    uint vertexID [[vertex_id]]
) {
    SBSVertexOut out;
    float2 quad[4] = {
        float2(-1.0f, -1.0f),
        float2( 1.0f, -1.0f),
        float2(-1.0f,  1.0f),
        float2( 1.0f,  1.0f)
    };
    out.position = float4(quad[vertexID], 0.0f, 1.0f);
    out.texCoord = quad[vertexID] * 0.5f + 0.5f;
    return out;
}

// MARK: - Fragment Shader for SBS Rendering

fragment float4 SBSFragment(
    SBSVertexOut input [[stage_in]],
    texture2d<float> leftEyeTexture [[texture(0)]],
    texture2d<float> rightEyeTexture [[texture(1)]]
) {
    float texX = input.texCoord.x;
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear);
    float4 color;
    if (texX < 0.5f) {
        color = leftEyeTexture.sample(linearSampler, float2(texX * 2.0f, input.texCoord.y));
    } else {
        color = rightEyeTexture.sample(linearSampler, float2((texX - 0.5f) * 2.0f, input.texCoord.y));
    }
    return color;
}
