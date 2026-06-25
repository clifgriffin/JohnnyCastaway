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

// EngineRenderer.swift
//
// Core Metal renderer for JohnnyEngine output.
//
// Responsibilities:
//   1. Own the MTLDevice, MTLCommandQueue, and render pipeline state.
//   2. Upload the engine's 640×480 indexed framebuffer to an R8Uint texture
//      and its 16-entry palette to an RGBA8Unorm 16×1 texture.
//   3. Render a single textured quad (via triangle strip) to a CAMetalDrawable,
//      applying nearest-neighbour fractional-scaled letterboxing via the
//      `gameRect` uniform.  Fractional scale (rather than integer) is used so
//      the game fills the available area on every monitor regardless of pixel
//      dimensions — see `gameRect(for:)` for the trade-off discussion.
//
// Texture strategy:
//   Both textures use MTLStorageModeShared (unified memory on Apple Silicon).
//   CPU writes via replace(region:…) are immediately visible to the GPU in the
//   command buffer committed in the same frame — no explicit synchronisation
//   needed because the CPU write completes before makeCommandBuffer() is called.
//   This avoids double-buffering complexity at the cost of theoretically tearing
//   on Intel, which is acceptable for our ~25 Hz update rate.
//
// Letterboxing:
//   Integer scale k = floor(min(W/640, H/480)), minimum 1.
//   Game rect is centred in the drawable; remaining area is cleared to black.

import Metal
import QuartzCore
import JohnnyEngine

// MARK: - Error type

public enum RendererError: Error, CustomStringConvertible {
    case noCommandQueue
    case shaderCompilationFailed(String)
    case shaderFunctionNotFound(String)
    case textureCreationFailed
    case pipelineCreationFailed(String)

    public var description: String {
        switch self {
        case .noCommandQueue:                return "Failed to create MTLCommandQueue"
        case .shaderCompilationFailed(let m): return "Shader compilation failed: \(m)"
        case .shaderFunctionNotFound(let n):  return "Shader function not found: \(n)"
        case .textureCreationFailed:         return "Failed to create MTLTexture"
        case .pipelineCreationFailed(let m): return "Pipeline creation failed: \(m)"
        }
    }
}

// MARK: - Display style

/// How the resolved game image is presented to the screen.
///
/// `crisp` and `soft` share the same blit pipeline and differ only in the
/// sampler (nearest vs linear); `crt` uses the scanline/mask post-process
/// pipeline.  Raw values are persisted in ScreenSaverDefaults, so keep them
/// stable.
public enum DisplayStyle: Int, Sendable, CaseIterable {
    case crisp = 0   // nearest-neighbour — faithful sharp pixels (default)
    case soft  = 1   // bilinear smoothing
    case crt   = 2   // scanlines + shadow mask + vignette
}

// MARK: - Uniforms (matches Metal Uniforms struct — float4, 16 bytes, 16-byte aligned)

private struct Uniforms {
    /// (left, top, right, bottom) in Metal NDC [-1, 1].
    /// NDC +y = up; so top > bottom.
    var gameRect: SIMD4<Float>
}

/// Mirrors the Metal `CRTParams` struct (one uint, 16-byte aligned by Metal).
private struct CRTParams {
    var curvatureEnabled: UInt32
}

/// Full-screen NDC rect for the resolve pass (no letterbox): left, top, right, bottom.
private let fullScreenRect = SIMD4<Float>(-1, 1, 1, -1)

// MARK: - EngineRenderer

/// Pure Metal renderer: takes a Framebuffer + EnginePalette, draws to a drawable.
///
/// Not thread-safe. Call all methods from the same thread (typically the main
/// thread, driven by JohnnyMetalView's CADisplayLink).
public final class EngineRenderer {

    // ---------------------------------------------------------------
    // MARK: Metal state
    // ---------------------------------------------------------------

    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue

    // Pass 1: indexed framebuffer + palette LUT → offscreen RGBA.
    private let resolvePipeline: MTLRenderPipelineState
    // Pass 2: resolved RGBA → drawable.
    private let blitPipeline:    MTLRenderPipelineState   // Crisp / Soft
    private let crtPipeline:     MTLRenderPipelineState   // CRT

    private let nearestSampler:  MTLSamplerState          // Crisp
    private let linearSampler:   MTLSamplerState          // Soft + CRT

    // R8Uint 640×480 — one byte per pixel, value = palette index (0..15 or 0xFF)
    private let framebufferTexture: MTLTexture

    // RGBA8Unorm 16×1 — one RGBA entry per palette colour
    private let paletteTexture: MTLTexture

    // RGBA8Unorm 640×480 — pass-1 output; pass 2 samples this.
    private let resolvedTexture: MTLTexture

    // ---------------------------------------------------------------
    // MARK: Public configuration
    // ---------------------------------------------------------------

    /// How frames are presented.  Defaults to `.crisp` (faithful).
    /// Safe to change between frames; takes effect on the next `render`.
    public var displayStyle: DisplayStyle = .crisp

    /// Whether CRT mode applies barrel curvature.  Only consulted when
    /// `displayStyle == .crt`.
    public var crtCurvatureEnabled: Bool = false

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public init(device: MTLDevice) throws {
        self.device = device

        // Command queue
        guard let cq = device.makeCommandQueue() else {
            throw RendererError.noCommandQueue
        }
        self.commandQueue = cq

        // Compile shaders from embedded source
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
        } catch {
            throw RendererError.shaderCompilationFailed(error.localizedDescription)
        }

        // Pass 1 (resolve): vertexShader + palette-LUT fragment → rgba8Unorm.
        // Pass 2 (style): vertexShader + blit/crt fragment → bgra8Unorm drawable.
        self.resolvePipeline = try Self.makePipeline(
            device: device, library: library,
            vertex: "vertexShader", fragment: "fragmentShader",
            pixelFormat: .rgba8Unorm, label: "JohnnyResolve")
        self.blitPipeline = try Self.makePipeline(
            device: device, library: library,
            vertex: "vertexShader", fragment: "blitFragment",
            pixelFormat: .bgra8Unorm, label: "JohnnyBlit")
        self.crtPipeline = try Self.makePipeline(
            device: device, library: library,
            vertex: "vertexShader", fragment: "crtFragment",
            pixelFormat: .bgra8Unorm, label: "JohnnyCRT")

        // Samplers: nearest = Crisp (sharp), linear = Soft + CRT base sampling.
        let nearestDesc = MTLSamplerDescriptor()
        nearestDesc.minFilter = .nearest
        nearestDesc.magFilter = .nearest
        nearestDesc.sAddressMode = .clampToEdge
        nearestDesc.tAddressMode = .clampToEdge
        let linearDesc = MTLSamplerDescriptor()
        linearDesc.minFilter = .linear
        linearDesc.magFilter = .linear
        linearDesc.sAddressMode = .clampToEdge
        linearDesc.tAddressMode = .clampToEdge
        guard let nearest = device.makeSamplerState(descriptor: nearestDesc),
              let linear  = device.makeSamplerState(descriptor: linearDesc) else {
            throw RendererError.pipelineCreationFailed("sampler state creation failed")
        }
        self.nearestSampler = nearest
        self.linearSampler  = linear

        // Framebuffer texture: R8Uint 640×480
        let fbDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width:  Framebuffer.width,
            height: Framebuffer.height,
            mipmapped: false
        )
        fbDesc.usage       = [.shaderRead]
        fbDesc.storageMode = .shared
        guard let fbTex = device.makeTexture(descriptor: fbDesc) else {
            throw RendererError.textureCreationFailed
        }
        self.framebufferTexture = fbTex

        // Palette texture: RGBA8Unorm 16×1
        let palDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width:  16,
            height: 1,
            mipmapped: false
        )
        palDesc.usage       = [.shaderRead]
        palDesc.storageMode = .shared
        guard let palTex = device.makeTexture(descriptor: palDesc) else {
            throw RendererError.textureCreationFailed
        }
        self.paletteTexture = palTex

        // Resolved colour texture: RGBA8Unorm 640×480 — pass-1 render target,
        // pass-2 sampler source.  Private storage: GPU-only, never read by CPU.
        let resolvedDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width:  Framebuffer.width,
            height: Framebuffer.height,
            mipmapped: false
        )
        resolvedDesc.usage       = [.renderTarget, .shaderRead]
        resolvedDesc.storageMode = .private
        guard let resolvedTex = device.makeTexture(descriptor: resolvedDesc) else {
            throw RendererError.textureCreationFailed
        }
        self.resolvedTexture = resolvedTex
    }

    /// Build a render pipeline from named vertex/fragment functions in `library`.
    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        pixelFormat: MTLPixelFormat,
        label: String
    ) throws -> MTLRenderPipelineState {
        guard let vertFn = library.makeFunction(name: vertex) else {
            throw RendererError.shaderFunctionNotFound(vertex)
        }
        guard let fragFn = library.makeFunction(name: fragment) else {
            throw RendererError.shaderFunctionNotFound(fragment)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label                           = label
        desc.vertexFunction                  = vertFn
        desc.fragmentFunction                = fragFn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RendererError.pipelineCreationFailed(error.localizedDescription)
        }
    }

    // ---------------------------------------------------------------
    // MARK: Upload
    // ---------------------------------------------------------------

    /// Upload the engine's current framebuffer and palette to GPU textures.
    ///
    /// Call once per engine tick (before `render`). The upload completes
    /// synchronously on the CPU; the GPU sees the new data in the command
    /// buffer committed by the subsequent `render` call.
    public func update(framebuffer: Framebuffer, palette: EnginePalette) {
        // Framebuffer: raw indexed pixels → R8Uint texture
        framebuffer.pixels.withUnsafeBytes { ptr in
            framebufferTexture.replace(
                region:      MTLRegionMake2D(0, 0, Framebuffer.width, Framebuffer.height),
                mipmapLevel: 0,
                withBytes:   ptr.baseAddress!,
                bytesPerRow: Framebuffer.width   // 1 byte per pixel, no padding
            )
        }

        // Palette: [RGBA …] × 16 → RGBA8Unorm texture
        var paletteBytes = [UInt8]()
        paletteBytes.reserveCapacity(16 * 4)
        for c in palette.colors {
            paletteBytes.append(c.r)
            paletteBytes.append(c.g)
            paletteBytes.append(c.b)
            paletteBytes.append(c.a)
        }
        paletteBytes.withUnsafeBytes { ptr in
            paletteTexture.replace(
                region:      MTLRegionMake2D(0, 0, 16, 1),
                mipmapLevel: 0,
                withBytes:   ptr.baseAddress!,
                bytesPerRow: 16 * 4              // 4 bytes per entry
            )
        }
    }

    // ---------------------------------------------------------------
    // MARK: Render
    // ---------------------------------------------------------------

    /// Encode and submit a render pass to the given drawable.
    ///
    /// Clears the drawable to black, then draws the game quad with integer
    /// scaling and letterboxing. Call `update` before each call to `render`
    /// when the engine has ticked; call `render` every display frame to
    /// present smoothly at native refresh rate.
    public func render(to drawable: CAMetalDrawable, drawableSize: CGSize) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encodeFrame(into: drawable.texture, drawableSize: drawableSize, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Encode the two-pass frame (resolve + style) into `output` on the given
    /// command buffer, without presenting.  `render(to:)` targets the
    /// drawable's texture; offscreen tests target a readable texture.  `output`
    /// must be `bgra8Unorm` (matches the pass-2 pipelines).
    func encodeFrame(into output: MTLTexture, drawableSize: CGSize, commandBuffer: MTLCommandBuffer) {
        let clearBlack = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // ---- Pass 1: resolve indexed framebuffer → RGBA (full-screen) -------
        let resolveDesc = MTLRenderPassDescriptor()
        resolveDesc.colorAttachments[0].texture     = resolvedTexture
        resolveDesc.colorAttachments[0].loadAction  = .clear
        resolveDesc.colorAttachments[0].clearColor  = clearBlack
        resolveDesc.colorAttachments[0].storeAction = .store

        guard let resolveEnc = commandBuffer.makeRenderCommandEncoder(descriptor: resolveDesc) else {
            return
        }
        resolveEnc.setRenderPipelineState(resolvePipeline)
        var fullRect = Uniforms(gameRect: fullScreenRect)
        resolveEnc.setVertexBytes(&fullRect, length: MemoryLayout<Uniforms>.stride, index: 0)
        resolveEnc.setFragmentTexture(framebufferTexture, index: 0)
        resolveEnc.setFragmentTexture(paletteTexture,     index: 1)
        resolveEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        resolveEnc.endEncoding()

        // ---- Pass 2: present resolved texture with the selected style -------
        let styleDesc = MTLRenderPassDescriptor()
        styleDesc.colorAttachments[0].texture     = output
        styleDesc.colorAttachments[0].loadAction  = .clear
        styleDesc.colorAttachments[0].clearColor  = clearBlack   // letterbox bars
        styleDesc.colorAttachments[0].storeAction = .store

        guard let styleEnc = commandBuffer.makeRenderCommandEncoder(descriptor: styleDesc) else {
            return
        }

        switch displayStyle {
        case .crisp:
            styleEnc.setRenderPipelineState(blitPipeline)
            styleEnc.setFragmentSamplerState(nearestSampler, index: 0)
        case .soft:
            styleEnc.setRenderPipelineState(blitPipeline)
            styleEnc.setFragmentSamplerState(linearSampler, index: 0)
        case .crt:
            styleEnc.setRenderPipelineState(crtPipeline)
            styleEnc.setFragmentSamplerState(linearSampler, index: 0)
            var crt = CRTParams(curvatureEnabled: crtCurvatureEnabled ? 1 : 0)
            styleEnc.setFragmentBytes(&crt, length: MemoryLayout<CRTParams>.stride, index: 0)
        }

        var letterbox = Uniforms(gameRect: Self.gameRect(for: drawableSize))
        styleEnc.setVertexBytes(&letterbox, length: MemoryLayout<Uniforms>.stride, index: 0)
        styleEnc.setFragmentTexture(resolvedTexture, index: 0)
        styleEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        styleEnc.endEncoding()
    }

    // ---------------------------------------------------------------
    // MARK: Letterbox geometry (public for unit testing)
    // ---------------------------------------------------------------

    /// Compute the NDC game rectangle for a drawable of the given size.
    ///
    /// Returns `SIMD4<Float>(left, top, right, bottom)` in Metal NDC
    /// (x ∈ [-1,1], y ∈ [-1,1] with +y upward).
    ///
    /// Scale: `k = min(W/640, H/480)`, fractional permitted so the
    /// game fills the available area on every monitor regardless of
    /// its pixel dimensions.  At non-integer scales the shader's
    /// `texture.read()` introduces minor row/column unevenness (some
    /// source pixels span N screen pixels, neighbours span N+1) — for
    /// the cartoon content that's a worthwhile trade for a true
    /// full-screen presentation.  Previously this floored to integer,
    /// which left visible bars on every monitor whose height wasn't a
    /// clean multiple of 480 (e.g. 88.9% fill on a 4K external).
    /// The game area is centred; the surrounding margin is cleared to
    /// black by the render pass clear colour.
    public static func gameRect(for drawableSize: CGSize) -> SIMD4<Float> {
        let dw = Double(drawableSize.width)
        let dh = Double(drawableSize.height)

        // Fractional scale that maxes-out the limiting axis.  Tiny
        // drawables (< 640×480) shrink proportionally rather than
        // overflowing the display.
        let k  = min(dw / 640.0, dh / 480.0)
        let gw = 640.0 * k
        let gh = 480.0 * k

        // Pixel-space offset of the game rect's top-left corner
        let ox = (dw - gw) / 2.0
        let oy = (dh - gh) / 2.0

        // Convert to NDC (x: [-1,1] left-to-right; y: [1,-1] top-to-bottom)
        let left   = Float(ox / dw * 2.0 - 1.0)
        let right  = Float((ox + gw) / dw * 2.0 - 1.0)
        let top    = Float(1.0 - oy / dh * 2.0)
        let bottom = Float(1.0 - (oy + gh) / dh * 2.0)

        return SIMD4<Float>(left, top, right, bottom)
    }
}
