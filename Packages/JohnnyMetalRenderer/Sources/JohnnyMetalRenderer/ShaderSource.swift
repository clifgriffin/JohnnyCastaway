// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Peter Smith
//
// This file is part of the Johnny Castaway macOS screensaver, a derivative
// work of 'Johnny Reborn' (jc_reborn) by Jeremie Guillaume.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file or <https://www.gnu.org/licenses/>.

// ShaderSource.swift
//
// Metal shader source compiled at runtime via MTLDevice.makeLibrary(source:options:).
// Compiling from source avoids the need for a pre-built .metallib in the
// SwiftPM package, while giving both the debug app and the .saver access to
// the same shaders. Compilation takes ~10–20 ms at init time — acceptable for
// a screensaver.
//
// Two-pass pipeline (see EngineRenderer.swift):
//   Pass 1 — resolve:  vertexShader (full-screen) + fragmentShader.
//                      R8Uint framebuffer index → 16×1 RGBA palette LUT →
//                      offscreen rgba8Unorm 640×480 "resolved" texture.
//   Pass 2 — display style:  vertexShader (letterboxed game rect) + one of
//                      blitFragment (Crisp/Soft) or crtFragment (CRT), sampling
//                      the resolved texture through a nearest/linear sampler.
//
// Splitting into two passes is what makes Soft (bilinear) and CRT possible:
// you cannot meaningfully filter an *integer* palette-index texture, so pass 1
// expands indices to real colours first, and pass 2 filters/post-processes the
// resulting RGBA image.
//
// Resolve-pass design notes:
//   - Palette indices 0–15 map to RGBA8 entries in the 16×1 palette texture.
//   - Index 0xFF (transparency sentinel, see Framebuffer.swift) is mapped to
//     black (0,0,0,1). By the time the composed framebuffer reaches the
//     renderer the background should have filled every pixel, so this branch
//     is rarely taken in practice.
//   - Integer-format textures (R8Uint) require access::read and pixel-space
//     coordinates; normalised UV coordinates from the interpolator are
//     multiplied by (640, 480) and clamped before the read.

internal let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------
// Shared types
// -----------------------------------------------------------------------

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// Game area corners in Metal NDC: (left, top, right, bottom).
/// NDC x ∈ [-1, 1]: -1 = left, +1 = right.
/// NDC y ∈ [-1, 1]: -1 = bottom, +1 = top.
struct Uniforms {
    float4 gameRect;
};

// -----------------------------------------------------------------------
// Vertex shader — fullscreen triangle strip with integer-scale letterbox
// -----------------------------------------------------------------------

/// Emit a quad as a triangle strip (4 vertices, no vertex buffer).
///
/// Vertex layout by vertexID (triangle strip topology):
///   0 = top-left,  1 = top-right
///   2 = bottom-left, 3 = bottom-right
///
/// UV (0,0) = top-left of image; (1,1) = bottom-right (standard texture space).
vertex VertexOut vertexShader(
    uint vertexID [[vertex_id]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    // Decompose vertex ID into UV via bit manipulation:
    //   u = bit 0 of vertexID (0 = left, 1 = right)
    //   v = bit 1 of vertexID (0 = top,  1 = bottom)
    float u = float(vertexID & 1u);
    float v = float((vertexID >> 1u) & 1u);

    // Map UV to NDC using the letterbox rect.
    // gameRect.x = NDC left,  gameRect.z = NDC right
    // gameRect.y = NDC top,   gameRect.w = NDC bottom
    float ndcX = mix(uniforms.gameRect.x, uniforms.gameRect.z, u);
    float ndcY = mix(uniforms.gameRect.y, uniforms.gameRect.w, v);

    VertexOut out;
    out.position = float4(ndcX, ndcY, 0.0, 1.0);
    out.texCoord = float2(u, v);
    return out;
}

// -----------------------------------------------------------------------
// Fragment shader — palette LUT lookup
// -----------------------------------------------------------------------

/// Map each fragment's UV to a source pixel index, look it up in the
/// 16-entry RGBA palette, and output the colour.
fragment float4 fragmentShader(
    VertexOut in [[stage_in]],
    texture2d<uint, access::read> framebuffer [[texture(0)]],
    texture2d<float, access::read> palette    [[texture(1)]]
) {
    // Integer pixel coordinate within the 640×480 source framebuffer.
    // Clamped to [0,639] × [0,479] to guard against floating-point edge values.
    uint2 px = min(uint2(in.texCoord * float2(640.0, 480.0)), uint2(639, 479));

    uint  idx  = framebuffer.read(px).r;

    // 0xFF is the transparency sentinel; map it to black rather than an
    // out-of-bounds palette read.
    if (idx >= 16u) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    return palette.read(uint2(idx, 0u));
}

// -----------------------------------------------------------------------
// Pass 2 — display-style fragments (sample the resolved RGBA texture)
// -----------------------------------------------------------------------

/// Crisp / Soft: straight texture lookup.  The bound sampler decides the
/// look — nearest = Crisp (sharp integer-ish pixels), linear = Soft (bilinear).
fragment float4 blitFragment(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> resolved [[texture(0)]],
    sampler                          samp     [[sampler(0)]]
) {
    return resolved.sample(samp, in.texCoord);
}

// CRT post-process tuning constants ("Moderate retro").  Scanline gaps and the
// shadow mask are tied to the 640×480 source grid (not the device resolution)
// so the look is the same on every monitor and reads as a low-res CRT.
constant float CRT_PI            = 3.14159265359;
constant float CRT_SCAN_DEPTH    = 0.18;   // how dark the gaps between rows get
constant float CRT_MASK_DEPTH    = 0.12;   // aperture-grille tint strength
constant float CRT_VIGNETTE      = 0.25;   // edge darkening
constant float CRT_CURVE_AMOUNT  = 0.045;  // barrel-distortion strength (toggle)
constant float CRT_BRIGHTEN      = 1.08;   // compensate for the darkening above

struct CRTParams {
    uint curvatureEnabled;
};

/// Barrel-distort UVs about the centre to mimic a curved tube.
static float2 crtCurve(float2 uv) {
    float2 cc = uv - 0.5;
    float  r2 = dot(cc, cc);
    return 0.5 + cc * (1.0 + r2 * CRT_CURVE_AMOUNT * 4.0);
}

fragment float4 crtFragment(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> resolved [[texture(0)]],
    sampler                          samp     [[sampler(0)]],
    constant CRTParams              &params   [[buffer(0)]]
) {
    float2 uv = in.texCoord;

    if (params.curvatureEnabled != 0u) {
        uv = crtCurve(uv);
        // Outside the warped image → black bezel (gives the rounded corners).
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    float3 color = resolved.sample(samp, uv).rgb;

    // Scanlines: one soft dark gap per source row (480 rows).
    float scan = sin(uv.y * 480.0 * CRT_PI);
    color *= 1.0 - CRT_SCAN_DEPTH * scan * scan;

    // Aperture mask: cycle an R/G/B tint across source columns (640 cols).
    uint  col  = uint(uv.x * 640.0) % 3u;
    float3 mask = float3(1.0 - CRT_MASK_DEPTH);
    mask[col] = 1.0;
    color *= mask;

    // Mild vignette toward the edges.
    float2 vc  = uv - 0.5;
    color *= 1.0 - dot(vc, vc) * CRT_VIGNETTE;

    color *= CRT_BRIGHTEN;
    return float4(clamp(color, 0.0, 1.0), 1.0);
}
"""
