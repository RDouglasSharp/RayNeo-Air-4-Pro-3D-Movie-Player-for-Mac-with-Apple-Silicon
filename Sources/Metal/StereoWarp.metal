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

// MARK: - Depth-Aware (Joint Bilinear) Color Sampling
//
// Why this exists: plain bilinear sampling blends the 4 nearest source pixels purely by
// fractional distance, with no idea where object boundaries are. Right at a silhouette edge
// (e.g. an arm against a background), those 4 taps can straddle the boundary — some are
// skin-tone, some are background — and the blend produces a soft, neither-one-nor-the-other
// halo that tracks the silhouette in the warped output. This is distinct from (and not fixed
// by) bilateral depth smoothing or the disparity gradient clamp: the depth map can be
// perfectly clean and the gradient perfectly smooth, and this color-bleed still happens,
// because it's the COLOR sample blending across a boundary, not the depth or disparity.
//
// The fix is the well-known "joint bilinear" / depth-aware upsampling trick: weight each of
// the 4 taps by how close ITS depth is to the depth at the pixel we're actually warping
// (centerDepth), in addition to the normal distance-based weight. A background tap near a
// foreground pixel gets weighted toward zero and effectively excluded from the blend, so the
// result stays solidly foreground-colored (or solidly background-colored) right up to the
// edge instead of smearing across it.
float4 depthAwareBilinearSample(
    texture2d<float, access::read> colorTex,
    texture2d<float, access::read> depthTex,
    float tw, float th,
    float u, float v,
    float centerDepth
) {
    float u0 = max(0.0f, min(u, tw - 1.0f));
    float v0 = max(0.0f, min(v, th - 1.0f));
    int x0 = (int)u0;
    int y0 = (int)v0;
    float fx = u0 - (float)x0;
    float fy = v0 - (float)y0;
    int x1 = min(x0 + 1, (int)tw - 1);
    int y1 = min(y0 + 1, (int)th - 1);

    uint2 p00 = uint2(x0, y0);
    uint2 p10 = uint2(x1, y0);
    uint2 p01 = uint2(x0, y1);
    uint2 p11 = uint2(x1, y1);

    float4 c00 = colorTex.read(p00);
    float4 c10 = colorTex.read(p10);
    float4 c01 = colorTex.read(p01);
    float4 c11 = colorTex.read(p11);

    float d00 = depthTex.read(p00).r;
    float d10 = depthTex.read(p10).r;
    float d01 = depthTex.read(p01).r;
    float d11 = depthTex.read(p11).r;

    // Range sigma tuned the same way as bilateralFilterDepth's — small relative to the 0..1
    // depth range, so a real silhouette edge (a large depth jump) gets a near-zero weight on
    // the wrong-side tap, while ordinary smooth depth gradients within an object still blend
    // normally and don't introduce banding.
    const float sigmaRange = 0.05f;

    float w00 = (1.0f - fx) * (1.0f - fy) * exp(-pow(d00 - centerDepth, 2.0f) / (2.0f * sigmaRange * sigmaRange));
    float w10 = fx         * (1.0f - fy) * exp(-pow(d10 - centerDepth, 2.0f) / (2.0f * sigmaRange * sigmaRange));
    float w01 = (1.0f - fx) * fy         * exp(-pow(d01 - centerDepth, 2.0f) / (2.0f * sigmaRange * sigmaRange));
    float w11 = fx         * fy         * exp(-pow(d11 - centerDepth, 2.0f) / (2.0f * sigmaRange * sigmaRange));

    float weightSum = w00 + w10 + w01 + w11;

    // If every tap got down-weighted near zero (e.g. center sits on a thin sliver between
    // two very different depths), fall back to nearest-tap color rather than producing a
    // black/garbage pixel from a near-zero weight sum.
    if (weightSum < 0.0001f) {
        return (fx < 0.5f) ? ((fy < 0.5f) ? c00 : c01) : ((fy < 0.5f) ? c10 : c11);
    }

    return (c00 * w00 + c10 * w10 + c01 * w01 + c11 * w11) / weightSum;
}

// MARK: - Edge-Aware Depth Smoothing (Bilateral Filter)

/// Smooths the depth map while preserving real depth discontinuities (object edges).
///
/// Why this exists: DepthAnythingV2's output is bilinearly upscaled from a 518x392 model
/// grid to full frame resolution (see DepthEstimator.swift), which leaves jagged, noisy
/// edges around object silhouettes — especially on lower-quality/compressed source video.
/// Feeding that noisy depth directly into stereoWarp causes two visible artifacts:
///   1. Stretching/smearing: adjacent pixels straddling a noisy edge get very different
///      disparities, distorting the warp geometry right at the boundary.
///   2. Bad hole fills: occlusion holes get patched from whichever side has noisy,
///      incorrect depth, mixing foreground/background fragments.
///
/// A plain Gaussian blur would soften real edges too (which we don't want — that's where
/// the 3D pop should be crisp). A bilateral filter instead only averages neighboring
/// depth samples that are spatially close AND have similar depth values, so flat regions
/// get smoothed (killing per-pixel noise) while genuine depth steps stay sharp.
kernel void bilateralFilterDepth(
    texture2d<float, access::read> depthIn,
    texture2d<float, access::write> depthOut,
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = depthIn.get_width();
    uint h = depthIn.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    float centerDepth = depthIn.read(gid).r;

    // Radius 3 (7x7 window) — wide enough to clean up model-upscale aliasing without
    // being so large it costs meaningful frame time on 1080p+ sources.
    const int radius = 3;
    // Spatial sigma: how much weight falls off with pixel distance.
    const float sigmaSpatial = 2.5f;
    // Range sigma: how much weight falls off with depth difference. Tuned relative to
    // depth being normalized 0..1 — small enough that real silhouette edges (which are
    // typically a large fraction of the depth range) are NOT smoothed across.
    const float sigmaRange = 0.06f;

    float weightSum = 0.0f;
    float valueSum = 0.0f;

    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 samplePos = int2(gid) + int2(dx, dy);
            if (samplePos.x < 0 || samplePos.x >= (int)w ||
                samplePos.y < 0 || samplePos.y >= (int)h) {
                continue;
            }
            float sampleDepth = depthIn.read(uint2(samplePos)).r;

            float spatialDist2 = float(dx * dx + dy * dy);
            float spatialWeight = exp(-spatialDist2 / (2.0f * sigmaSpatial * sigmaSpatial));

            float rangeDist = sampleDepth - centerDepth;
            float rangeWeight = exp(-(rangeDist * rangeDist) / (2.0f * sigmaRange * sigmaRange));

            float weight = spatialWeight * rangeWeight;
            weightSum += weight;
            valueSum += weight * sampleDepth;
        }
    }

    float result = (weightSum > 0.0001f) ? (valueSum / weightSum) : centerDepth;
    depthOut.write(float4(result, result, result, 1.0f), gid);
}

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

    // Map content-region pixel to source coordinates (CV space: row 0 = top)
    float cx = (float)gid.x - params.contentOffsetX;
    float cy = (float)gid.y - params.contentOffsetY;
    float srcX = (cx / params.contentWidth) * params.inputWidth;
    float srcY = (cy / params.contentHeight) * params.inputHeight;

    // Metal texture y=0 = bottom, CVPixelBuffer row 0 = top — flip Y for sampling
    float flipY = params.inputHeight - srcY;

    float depth = depthTexture.read(uint2((int)srcX, (int)flipY)).r;

    // Relative disparity w.r.t. anchor plane (fillMode param reused as anchorDepth, default 0.5).
    // Near objects (< anchor) shift; far objects (>= anchor) stay put.
    // This provides a stable horizon and shifts only what should pop out.
    float anchorDepth = params.fillMode;
    float nearDepth = 0.1f;

    // Smoothstep transition band around the anchor plane, instead of a hard if/else knee.
    // A hard cutoff means two adjacent pixels whose depth straddles anchorDepth can jump
    // from "full disparity" to "zero disparity" with nothing in between, which shows up as
    // a halo/double-edge around midground objects (e.g. the guitar in front of a performer).
    // The band width is a fraction of the anchor depth itself, so it scales with scene depth.
    float band = max(anchorDepth * 0.15f, 0.02f);
    float d = max(depth, nearDepth);
    float dClamped = max(d, nearDepth);
    float rawDisparity = params.baseline * params.focalLength
        * (1.0f / dClamped - 1.0f / anchorDepth) / params.focalLength;
    // t = 1 when d <= anchorDepth - band (full pop), 0 when d >= anchorDepth + band (flat),
    // smoothly interpolated in between.
    float t = 1.0f - smoothstep(anchorDepth - band, anchorDepth + band, d);
    float disparity = max(rawDisparity, 0.0f) * t;

    // HARD clamp — prevents ghosting from runaway warp at depth edges
    disparity = clamp(disparity, 0.0f, 16.0f);

    // Disparity GRADIENT clamp — the hard magnitude clamp above limits how far a pixel can
    // shift, but says nothing about how fast disparity changes between neighboring pixels.
    // At a noisy depth edge, two adjacent source pixels can land on very different disparities,
    // which still distorts the warp geometry itself even with depth-aware color sampling.
    // Limiting the per-pixel-step change in disparity caps how aggressively any single edge
    // can warp, trading a little depth accuracy at hard edges for a much cleaner boundary.
    float neighborSrcX = max(srcX - 1.0f, 0.0f);
    float neighborDepthRaw = depthTexture.read(uint2((int)neighborSrcX, (int)flipY)).r;
    float neighborD = max(neighborDepthRaw, nearDepth);
    float neighborRawDisparity = params.baseline * params.focalLength
        * (1.0f / neighborD - 1.0f / anchorDepth) / params.focalLength;
    float neighborT = 1.0f - smoothstep(anchorDepth - band, anchorDepth + band, neighborD);
    float neighborDisparity = clamp(max(neighborRawDisparity, 0.0f) * neighborT, 0.0f, 16.0f);

    const float maxDisparityStep = 1.5f; // max allowed change in disparity per source pixel
    float disparityDelta = disparity - neighborDisparity;
    disparityDelta = clamp(disparityDelta, -maxDisparityStep, maxDisparityStep);
    disparity = neighborDisparity + disparityDelta;

    // Backward warp: left eye camera shifted left from source,
    // so we sample from LEFT of current position (higher -X in source).
    // Right eye camera shifted right — sample from RIGHT of current position.
    float leftSrcX  = srcX - disparity;
    float rightSrcX = srcX + disparity;
    float warpY     = flipY;

    // Out-of-bounds source coords = occlusion hole → write alpha=0 for fillHoles
    bool leftOoc = (leftSrcX < 0.0f || leftSrcX >= params.inputWidth);
    bool rightOoc = (rightSrcX < 0.0f || rightSrcX >= params.inputWidth);

    float4 leftPixel;
    float4 rightPixel;

    if (leftOoc) {
        leftPixel = float4(0.0f, 0.0f, 0.0f, 0.0f);
    } else {
        // Depth-aware sample: center depth is taken at the WARPED source position (leftSrcX),
        // i.e. the depth of the thing actually being looked up, so the 4-tap weighting favors
        // taps that agree with what's being sampled rather than what's at the output pixel's
        // own (un-warped) location. This keeps the color sample from bleeding across a
        // silhouette edge even when disparity has shifted the lookup right up against one.
        float leftCenterDepth = depthTexture.read(uint2(
            (uint)clamp(leftSrcX, 0.0f, params.inputWidth - 1.0f),
            (uint)flipY
        )).r;
        leftPixel = depthAwareBilinearSample(
            sourceTexture, depthTexture,
            params.inputWidth, params.inputHeight,
            leftSrcX, warpY, leftCenterDepth
        );
        leftPixel.a = 1.0f;
    }

    if (rightOoc) {
        rightPixel = float4(0.0f, 0.0f, 0.0f, 0.0f);
    } else {
        float rightCenterDepth = depthTexture.read(uint2(
            (uint)clamp(rightSrcX, 0.0f, params.inputWidth - 1.0f),
            (uint)flipY
        )).r;
        rightPixel = depthAwareBilinearSample(
            sourceTexture, depthTexture,
            params.inputWidth, params.inputHeight,
            rightSrcX, warpY, rightCenterDepth
        );
        rightPixel.a = 1.0f;
    }

    leftEyeTexture.write(leftPixel, gid);
    rightEyeTexture.write(rightPixel, gid);
}

// MARK: - Fill Hole Kernel

/// Fills occlusion holes (alpha=0) left by the stereo warp.
///
/// The naive version of this (search radially, take the nearest opaque pixel) frequently
/// patches a hole with a fragment of the WRONG depth layer — e.g. a hole that's uncovered
/// background gets filled with nearby foreground color, which reads as a torn/smeared edge
/// right at the object boundary (this is what's visible around arms/instrument edges).
///
/// Two improvements over nearest-any-opaque-pixel:
///   1. Directional search: occlusion holes from horizontal stereo disparity are themselves
///      horizontal, so candidates are searched along the row (left and right) before falling
///      back to a small 2D radius, rather than spiraling outward in all directions from pixel
///      one. This finds plausible background fill faster and avoids grabbing a diagonal
///      neighbor that's actually still part of the foreground object.
///   2. Depth-aware preference: among same-row candidates, prefer the one whose depth is
///      closest to the hole's own surrounding depth — i.e. plausible background — rather than
///      simply the first opaque pixel encountered, which avoids accidentally pulling in
///      foreground color from just past the object's far edge.
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
    if (pixel.a >= 0.01f) {
        return;
    }

    // contentOffsetX/contentWidth let us map gid back to source-space depth lookup,
    // matching the mapping used in stereoWarp.
    float cx = (float)gid.x - params.contentOffsetX;
    float srcX = (params.contentWidth > 0.0f) ? (cx / params.contentWidth) * params.inputWidth : cx;
    float cy = (float)gid.y - params.contentOffsetY;
    float srcY = (params.contentHeight > 0.0f) ? (cy / params.contentHeight) * params.inputHeight : cy;
    float flipY = params.inputHeight - srcY;
    float holeDepth = depthTexture.read(uint2(
        (uint)clamp(srcX, 0.0f, params.inputWidth - 1.0f),
        (uint)clamp(flipY, 0.0f, params.inputHeight - 1.0f)
    )).r;

    const int maxHorizontalSearch = 48;
    const int verticalFallbackRadius = 4;

    float4 best;
    float bestScore = -1.0f;
    int found = 0;

    // Primary pass: walk outward along the row in both directions, but weight candidates
    // further from the hole as more likely to be "true" background, and prefer depth values
    // farther away (larger depth = farther in this map's convention) since a true occlusion
    // hole is, by definition, background that the foreground was occluding.
    for (int dx = 1; dx <= maxHorizontalSearch; dx++) {
        for (int sign = -1; sign <= 1; sign += 2) {
            int2 checkPos = int2(gid) + int2(sign * dx, 0);
            if (checkPos.x < 0 || checkPos.x >= (int)params.outputWidth ||
                checkPos.y < 0 || checkPos.y >= (int)params.outputHeight) {
                continue;
            }
            float4 check = eyeTexture.read(uint2(checkPos));
            if (check.a < 0.01f) {
                continue;
            }
            float checkSrcX = ((float)checkPos.x - params.contentOffsetX) / max(params.contentWidth, 1.0f) * params.inputWidth;
            float checkDepth = depthTexture.read(uint2(
                (uint)clamp(checkSrcX, 0.0f, params.inputWidth - 1.0f),
                (uint)clamp(flipY, 0.0f, params.inputHeight - 1.0f)
            )).r;
            // Score: prefer candidates whose depth is close to (or farther than) the hole's
            // surrounding depth — i.e. plausible background — and which are close by.
            float depthPlausibility = 1.0f - clamp(abs(checkDepth - holeDepth) * 2.0f, 0.0f, 1.0f);
            float proximity = 1.0f - (float(dx) / float(maxHorizontalSearch));
            float score = depthPlausibility * 0.7f + proximity * 0.3f;
            if (score > bestScore) {
                bestScore = score;
                best = check;
                found = 1;
            }
        }
        // Early-out once we have a confidently good match — avoids walking the full 48px
        // search window every time, since most holes are thin (a few px wide).
        if (found && bestScore > 0.85f) {
            break;
        }
    }

    // Fallback: thin vertical seams or holes at frame edges where horizontal search found
    // nothing usable — small radial search as a last resort.
    if (!found) {
        for (int dy = -verticalFallbackRadius; dy <= verticalFallbackRadius && !found; dy++) {
            for (int dx = -verticalFallbackRadius; dx <= verticalFallbackRadius; dx++) {
                int2 checkPos = int2(gid) + int2(dx, dy);
                if (checkPos.x < 0 || checkPos.x >= (int)params.outputWidth ||
                    checkPos.y < 0 || checkPos.y >= (int)params.outputHeight) {
                    continue;
                }
                float4 check = eyeTexture.read(uint2(checkPos));
                if (check.a >= 0.01f) {
                    best = check;
                    found = 1;
                    break;
                }
            }
        }
    }

    if (found) {
        eyeTexture.write(best, gid);
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
