#include <metal_stdlib>
using namespace metal;

// MARK: - Stereo Warp Compute Kernel

struct StereoWarpParams {
    int inputWidth;
    int inputHeight;
    int outputWidth;
    int outputHeight;
    float baseline;
    float focalLength;
    int fillMode;
};

kernel void stereoWarp(
    texture2d<float, access::read> sourceTexture,
    texture2d<float, access::read> depthTexture,
    texture2d<float, access::write> leftEyeTexture,
    texture2d<float, access::write> rightEyeTexture,
    constant StereoWarpParams& params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.outputWidth || gid.y >= params.outputHeight) {
        return;
    }

    // Calculate source coordinates
    float srcX = float(gid.x) / float(params.outputWidth) * float(params.inputWidth);
    float srcY = float(gid.y) / float(params.outputHeight) * float(params.inputHeight);

    // Get depth value from depth texture
    float depth = depthTexture.read(uint2(int(srcX), int(srcY))).r;

    // Calculate disparity based on depth
    float disparity = params.baseline * params.focalLength / max(depth * params.focalLength, 1.0f);

    // Left eye: shift right by disparity
    float leftX = srcX + disparity * 0.5f;
    // Right eye: shift left by disparity
    float rightX = srcX - disparity * 0.5f;

    float srcYf = srcY;

    // Sample source image with clamping
    constexpr sampler clampSampler(mag_filter::linear, min_filter::linear,
                                    coord::normalized, address::clamp_to_edge);
    float4 leftPixel = sampleLevel(
        sourceTexture,
        clampSampler,
        float2(leftX / float(params.inputWidth), srcYf / float(params.inputHeight)),
        0.0f
    );

    float4 rightPixel = sampleLevel(
        sourceTexture,
        clampSampler,
        float2(rightX / float(params.inputWidth), srcYf / float(params.inputHeight)),
        0.0f
    );

    // Write to output textures
    leftEyeTexture.write(leftPixel, uint2(gid.x, gid.y));
    rightEyeTexture.write(rightPixel, uint2(gid.x, gid.y));
}

// MARK: - Fill Hole Kernel

kernel void fillHoles(
    texture2d<float, access::read_write> eyeTexture,
    texture2d<float, access::read> depthTexture,
    constant StereoWarpParams& params [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.outputWidth || gid.y >= params.outputHeight) {
        return;
    }

    float4 pixel = eyeTexture.read(uint2(gid.x, gid.y));
    if (pixel.a < 0.01f) {  // Transparent/unmapped pixel
        // Search nearest valid pixel in 4 directions
        float4 nearest;
        int found = 0;

        for (int dx = -16; dx <= 16; dx++) {
            for (int dy = -16; dy <= 16; dy++) {
                int2 checkPos = int2(gid.x + dx, gid.y + dy);
                if (checkPos.x >= 0 && checkPos.x < params.outputWidth &&
                    checkPos.y >= 0 && checkPos.y < params.outputHeight) {
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
            eyeTexture.write(nearest, uint2(gid.x, gid.y));
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
    
    // Full screen quad vertices
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
    // Select texture based on X coordinate
    float texX = input.texCoord.x;
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear);
    float4 color;
    if (texX < 0.5f) {
        // Left eye
        float2 lv = float2(texX * 2.0f, input.texCoord.y);
        color = leftEyeTexture.sample(linearSampler, lv);
    } else {
        // Right eye
        float2 rv = float2((texX - 0.5f) * 2.0f, input.texCoord.y);
        color = rightEyeTexture.sample(linearSampler, rv);
    }
    
    return color;
}
