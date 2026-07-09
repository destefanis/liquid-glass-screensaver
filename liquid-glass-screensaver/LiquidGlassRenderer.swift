//
//  LiquidGlassRenderer.swift
//  liquid-glass-screensaver
//
//  Multi-pass Metal renderer for the liquid glass composition.
//  All effect parameter values are baked in below.
//

import Metal
import MetalKit
import simd

// MARK: - Effect Parameter Structures
// (must match the Metal shader struct layouts)


/// Progressive Blur — full Metal struct layout. Rendered as a
/// 3-pass separable blur (H→V→H); `pass` is set per draw call.
struct ProgressiveBlurParams {
    var center: SIMD2<Float>
    var amount: Float
    var samples: Int32
    var opacity: Float
    var rotation: Float
    var falloffPower: Float
    var resolution: SIMD2<Float>
    var pass: Int32
}

/// Fresnel — stored fields match the Metal FresnelParams layout
/// (verified against GPU pipeline reflection).  `falloffCurve`,
/// `glowMode`, `innerRadius`, `areaLightSize`, `lightHeight`, and
/// `opacity` aren't part of the baked data, so the init fills in
/// sensible defaults.
struct FresnelParams {
    var fresnelType: Int32
    var center: SIMD2<Float>
    var radius: Float
    var angle: Float
    var scale: Float
    var power: Float
    var intensity: Float
    var softness: Float
    var invert: Bool
    var falloffCurve: Int32
    var glowMode: Int32
    var innerRadius: Float
    var areaLightSize: Float
    var lightHeight: Float
    var useGradient: Bool
    var fresnelColor: SIMD3<Float>
    var innerColor: SIMD3<Float>
    var outerColor: SIMD3<Float>
    var gradientPower: Float
    var blendMode: Int32
    var chromaticAberration: Float
    var resolution: SIMD2<Float>
    var opacity: Float

    init(fresnelType: Int32, center: SIMD2<Float>, radius: Float,
         angle: Float, scale: Float, power: Float, intensity: Float,
         softness: Float, invert: Bool, useGradient: Bool,
         fresnelColor: SIMD3<Float>, innerColor: SIMD3<Float>,
         outerColor: SIMD3<Float>, gradientPower: Float,
         blendMode: Int32, chromaticAberration: Float,
         resolution: SIMD2<Float>) {
        self.fresnelType = fresnelType
        self.center = center
        self.radius = radius
        self.angle = angle
        self.scale = scale
        self.power = power
        self.intensity = intensity
        self.softness = softness
        self.invert = invert
        self.falloffCurve = 0
        self.glowMode = 0
        self.innerRadius = 0.0
        self.areaLightSize = 0.0
        self.lightHeight = 0.0
        self.useGradient = useGradient
        self.fresnelColor = fresnelColor
        self.innerColor = innerColor
        self.outerColor = outerColor
        self.gradientPower = gradientPower
        self.blendMode = blendMode
        self.chromaticAberration = chromaticAberration
        self.resolution = resolution
        self.opacity = 1.0
    }
}


struct ProceduralGrainParams {
    var time: Float
    var resolution: SIMD2<Float>
    var intensity: Float
    var blendMode: Int32
    var speed: Float
    var mean: Float
    var variance: Float
}



/// Water — stored fields match the Metal WaterParams layout; the
/// custom init accepts model-order arguments and maps them into
/// GPU order.
struct WaterParams {
    var resolution: SIMD2<Float>
    var time: Float
    var speed: Float
    var size: Float
    var highlights: Float
    var layering: Float
    var edges: Float
    var caustic: Float
    var waves: Float
    var opacity: Float
    var colorBack: SIMD4<Float>
    var colorHighlight: SIMD4<Float>

    init(size: Float, highlights: Float, layering: Float, edges: Float,
         caustic: Float, waves: Float, speed: Float,
         colorBack: [Float], colorHighlight: [Float], opacity: Float,
         time: Float, resolution: SIMD2<Float>) {
        self.resolution = resolution
        self.time = time
        self.speed = speed
        self.size = size
        self.highlights = highlights
        self.layering = layering
        self.edges = edges
        self.caustic = caustic
        self.waves = waves
        self.opacity = opacity
        self.colorBack = SIMD4<Float>(colorBack[0], colorBack[1], colorBack[2], colorBack[3])
        self.colorHighlight = SIMD4<Float>(colorHighlight[0], colorHighlight[1], colorHighlight[2], colorHighlight[3])
    }
}

/// Skew — the Metal struct wants a precomputed rotation matrix,
/// plane normal, shear tangents and aspect ratio; this init takes
/// raw Euler angles and does that CPU precomputation
/// (R = Rx·Ry·Rz, normal = column 2).
struct SkewParams {
    var rotation: simd_float3x3
    var planeNormal: SIMD3<Float>
    var shearTanX: Float
    var shearTanY: Float
    var shearDet: Float
    var aspect: Float
    var isIdentity: Bool
    var center: SIMD2<Float>
    var perspective: Float
    var opacity: Float
    var hideBackface: Bool

    init(rotationX: Float, rotationY: Float, rotationZ: Float,
         perspective: Float, center: [Float], opacity: Float,
         skewX: Float, skewY: Float, hideBackface: Bool,
         resolution: SIMD2<Float>) {
        let cx = cos(rotationX), sx = sin(rotationX)
        let cy = cos(rotationY), sy = sin(rotationY)
        let cz = cos(rotationZ), sz = sin(rotationZ)
        let Rx = simd_float3x3(columns: (
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, cx, sx),
            SIMD3<Float>(0, -sx, cx)
        ))
        let Ry = simd_float3x3(columns: (
            SIMD3<Float>(cy, 0, -sy),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(sy, 0, cy)
        ))
        let Rz = simd_float3x3(columns: (
            SIMD3<Float>(cz, sz, 0),
            SIMD3<Float>(-sz, cz, 0),
            SIMD3<Float>(0, 0, 1)
        ))
        let rot = Rx * Ry * Rz
        let tanX = tan(skewX)
        let tanY = tan(skewY)
        self.rotation = rot
        self.planeNormal = rot.columns.2
        self.shearTanX = tanX
        self.shearTanY = tanY
        self.shearDet = 1.0 - tanX * tanY
        self.aspect = resolution.y > 0 ? max(resolution.x / resolution.y, 0.0001) : 1.0
        self.isIdentity = (rotationX == 0 && rotationY == 0 && rotationZ == 0
                           && skewX == 0 && skewY == 0)
        self.center = SIMD2<Float>(center[0], center[1])
        self.perspective = perspective
        self.opacity = opacity
        self.hideBackface = hideBackface
    }
}

/// 3D Liquid Metal — stored fields match the Metal struct layout.
/// `delay` is CPU-side: it offsets the shared clock so several
/// layers can run the same animation out of phase. `stops` is the
/// CPU-side gradient data; the LUT texture built from it is bound
/// separately at texture(1) in the render loop.
struct LiquidMetal3DParams {
    var resolution: SIMD2<Float>
    var time: Float
    var speed: Float
    var posX: Float
    var posY: Float
    var size: Float
    var wobble: Float
    var spin: Float
    var shape: Int32
    var refraction: Float
    var metalness: Float
    var repetition: Float
    var softness: Float
    var shiftRed: Float
    var shiftBlue: Float
    var distortion: Float
    var contour: Float
    var angle: Float
    var contrast: Float
    var shading: Float
    var darkFade: Float
    var waveSpeed: Float
    var waveStrength: Float
    var glowSpeed: Float
    var glowStrength: Float
    var opacity: Float
    var colorMode: Int32
    var paletteLock: Int32
    var colorBack: SIMD4<Float>
    var colorTint: SIMD4<Float>
    var colorGlass: SIMD4<Float>

    init(posX: Float, posY: Float, size: Float, wobble: Float,
         shape: Int32, spin: Float, refraction: Float, metalness: Float,
         repetition: Float, softness: Float, shiftRed: Float, shiftBlue: Float,
         distortion: Float, contour: Float, angle: Float, contrast: Float,
         shading: Float, darkFade: Float, waveSpeed: Float, waveStrength: Float,
         glowSpeed: Float, glowStrength: Float, speed: Float, delay: Float,
         colorMode: Int32, paletteLock: Int32, stops: [[Float]],
         colorBack: [Float], colorTint: [Float], colorGlass: [Float],
         opacity: Float, time: Float, resolution: SIMD2<Float>) {
        self.resolution = resolution
        self.time = time - delay
        self.speed = speed
        self.posX = posX
        self.posY = posY
        self.size = size
        self.wobble = wobble
        self.spin = spin
        self.shape = shape
        self.refraction = refraction
        self.metalness = metalness
        self.repetition = repetition
        self.softness = softness
        self.shiftRed = shiftRed
        self.shiftBlue = shiftBlue
        self.distortion = distortion
        self.contour = contour
        self.angle = angle
        self.contrast = contrast
        self.shading = shading
        self.darkFade = darkFade
        self.waveSpeed = waveSpeed
        self.waveStrength = waveStrength
        self.glowSpeed = glowSpeed
        self.glowStrength = glowStrength
        self.opacity = opacity
        self.colorMode = colorMode
        self.paletteLock = paletteLock
        self.colorBack = SIMD4<Float>(colorBack[0], colorBack[1], colorBack[2], colorBack[3])
        self.colorTint = SIMD4<Float>(colorTint[0], colorTint[1], colorTint[2], colorTint[3])
        self.colorGlass = SIMD4<Float>(colorGlass[0], colorGlass[1], colorGlass[2], colorGlass[3])
        _ = stops   // consumed by the LUT builder, not the GPU struct
    }
}

// MARK: - Layer Structures

/// Per-layer data for the base gradient pass — solid-colour
/// circle/rect fills only.  Field order must match the Metal
/// `LayerProperties` struct.
struct MetalLayerProperties {
    var color: SIMD4<Float>
    var center: SIMD2<Float>
    var radius: Float
    var shape: Int32
    var opacity: Float
    var width: Float
    var height: Float
    var softness: Float
    var squircleRadius: Float
    var rotation: Float
    var fillOpacity: Float
}

// MARK: - Renderer

class LiquidGlassRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var startTime: CFAbsoluteTime = 0

    /// User-adjustable multiplier (0–1) on the baked fresnel glow
    /// intensity.  0 disables the pass, 1 is the full baked look.
    var fresnelIntensityScale: Float = 0.5

    /// The renderer eases between light and dark palettes so system
    /// appearance changes never snap mid-animation.
    var darkMode: Bool {
        get { themeTargetLevel >= 0.5 }
        set { setDarkMode(newValue, animated: false) }
    }

    private let themeTransitionDuration: Float = 1.4
    private var themeLevel: Float = 0.0
    private var themeStartLevel: Float = 0.0
    private var themeTargetLevel: Float = 0.0
    private var themeTransitionStart: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    // Canvas configuration (baked from export)
    let canvasSize = CGSize(width: 1920.0, height: 1080.0)
    let resolutionScale: CGFloat = 1.0

    // Pipeline states
    var gradientPipelineState: MTLRenderPipelineState?
    var fresnelPipelineState: MTLRenderPipelineState?
    var liquidMetal3DPipelineState: MTLRenderPipelineState?
    var proceduralGrainPipelineState: MTLRenderPipelineState?
    var progressiveBlurPipelineState: MTLRenderPipelineState?
    var skewPipelineState: MTLRenderPipelineState?
    var waterPipelineState: MTLRenderPipelineState?
    var passthroughPipelineState: MTLRenderPipelineState?

    // Background colors
    private let lightBackground = SIMD4<Float>(0.8666667, 0.8666667, 0.8666667, 1.0)
    private let lightLayerBackground = SIMD4<Float>(0.8412972, 0.8412972, 0.8412972, 1.0)
    private let darkBackground = SIMD4<Float>(0.0, 0.0, 0.0, 1.0)
    private let darkLayerBackground = SIMD4<Float>(0.0, 0.0, 0.0, 1.0)

    // Ping-pong textures for multi-pass effects
    var pingTexture: MTLTexture?
    var pongTexture: MTLTexture?
    var currentSize: CGSize = .zero

    // MARK: - Baked Layer Data

    let layerCount = 2

    func getMetalLayers() -> [MetalLayerProperties] {
        return [
            MetalLayerProperties(
                color: themeMix(lightLayerBackground, darkLayerBackground),
                center: SIMD2<Float>(0.5, 0.5),
                radius: 0.25,
                shape: 1,
                opacity: 1.0,
                width: 1.7834822,
                height: 1.0056978,
                softness: 1.0,
                squircleRadius: 0.0,
                rotation: 0.0,
                fillOpacity: 1.0
            ),
            MetalLayerProperties(
                color: SIMD4<Float>(0.26666668, 0.03137255, 0.16078433, 1.0),
                center: SIMD2<Float>(0.5, 0.5),
                radius: 0.25,
                shape: 3,
                opacity: 0.0,
                width: 0.868,
                height: 0.868,
                softness: 1.0,
                squircleRadius: 0.5,
                rotation: 0.0,
                fillOpacity: 1.0
            ),
        ]
    }

    func setDarkMode(_ enabled: Bool, animated: Bool = true) {
        let now = CFAbsoluteTimeGetCurrent()
        updateThemeProgress(at: now)

        themeStartLevel = animated ? themeLevel : (enabled ? 1.0 : 0.0)
        themeTargetLevel = enabled ? 1.0 : 0.0
        themeTransitionStart = now

        if !animated {
            themeLevel = themeTargetLevel
        }
    }

    private func updateThemeProgress(at currentTime: CFAbsoluteTime) {
        let elapsed = Float(currentTime - themeTransitionStart)
        let progress = min(max(elapsed / themeTransitionDuration, 0.0), 1.0)
        let eased = progress * progress * (3.0 - 2.0 * progress)
        themeLevel = themeStartLevel + (themeTargetLevel - themeStartLevel) * eased
    }

    private func themeMix(_ light: SIMD4<Float>, _ dark: SIMD4<Float>) -> SIMD4<Float> {
        light + (dark - light) * themeLevel
    }

    private func themeMix(_ light: Float, _ dark: Float) -> Float {
        light + (dark - light) * themeLevel
    }

    private var currentBackground: SIMD4<Float> {
        themeMix(lightBackground, darkBackground)
    }

    private var currentClearColor: MTLClearColor {
        let color = currentBackground
        return MTLClearColor(red: Double(color.x),
                             green: Double(color.y),
                             blue: Double(color.z),
                             alpha: Double(color.w))
    }

    // MARK: - Initialization
    
    init?(metalView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        super.init()
        
        metalView.device = device
        metalView.delegate = self
        metalView.clearColor = currentClearColor
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = false
        
        startTime = CFAbsoluteTimeGetCurrent()
        
        buildPipelines()
        let renderSize = CGSize(width: canvasSize.width * resolutionScale,
                              height: canvasSize.height * resolutionScale)
        createTextures(size: renderSize)
    }
        // MARK: - Pipeline Building
    
    private func buildPipelines() {
        // Inside a .saver bundle the "default" library must be loaded from
        // this bundle, not the host process (legacyScreenSaver) main bundle.
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: LiquidGlassRenderer.self)) else {
            print("Failed to create Metal library")
            return
        }
                // Gradient pipeline
        if let vertexFunc = library.makeFunction(name: "vertex_main"),
           let fragmentFunc = library.makeFunction(name: "fragment_main") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            
            gradientPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
                // fresnel pipeline
        if let vertexFunc = library.makeFunction(name: "effect_vertex"),
           let fragmentFunc = library.makeFunction(name: "fresnel_fragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            fresnelPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
                // liquidMetal3D pipeline
        if let vertexFunc = library.makeFunction(name: "effect_vertex"),
           let fragmentFunc = library.makeFunction(name: "liquid_metal_3d_fragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            liquidMetal3DPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
                // proceduralGrain pipeline
        if let vertexFunc = library.makeFunction(name: "effect_vertex"),
           let fragmentFunc = library.makeFunction(name: "procedural_grain_fragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            proceduralGrainPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
                // progressiveBlur pipeline
        if let vertexFunc = library.makeFunction(name: "effect_vertex"),
           let fragmentFunc = library.makeFunction(name: "progressive_blur_fragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            progressiveBlurPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
                // skew pipeline
        if let vertexFunc = library.makeFunction(name: "effect_vertex"),
           let fragmentFunc = library.makeFunction(name: "skew_fragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            skewPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
                // water pipeline
        if let vertexFunc = library.makeFunction(name: "effect_vertex"),
           let fragmentFunc = library.makeFunction(name: "water_fragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            waterPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
                // Passthrough pipeline (for copying final texture to screen)
        if let vertexFunc = library.makeFunction(name: "effect_vertex"),
           let fragmentFunc = library.makeFunction(name: "passthrough_fragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            passthroughPipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
            }
    // MARK: - Texture Management

    private func createTextures(size: CGSize) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]

        pingTexture = device.makeTexture(descriptor: descriptor)
        pongTexture = device.makeTexture(descriptor: descriptor)
        currentSize = size
    }

    // MARK: - Gradient LUT (Liquid Metal gradient mode)

    private var gradientLUTCache: [String: MTLTexture] = [:]

    /// Bake gradient stops (each [r, g, b, a, position]) into a
    /// 256×1 lookup texture. Cached, so calling per frame is free.
    private func gradientLUT(stops: [[Float]]) -> MTLTexture? {
        guard !stops.isEmpty else { return nil }
        let key = stops.description
        if let cached = gradientLUTCache[key] { return cached }

        func color(_ s: [Float]) -> SIMD4<Float> {
            SIMD4<Float>(s[0], s[1], s[2], s[3])
        }
        func sample(_ position: Float) -> SIMD4<Float> {
            let pos = min(max(position, 0), 1)
            if pos <= stops[0][4] { return color(stops[0]) }
            if pos >= stops[stops.count - 1][4] { return color(stops[stops.count - 1]) }
            for i in 0..<(stops.count - 1) {
                let a = stops[i], b = stops[i + 1]
                if pos >= a[4] && pos <= b[4] {
                    let t = b[4] > a[4] ? (pos - a[4]) / (b[4] - a[4]) : 0
                    return color(a) + (color(b) - color(a)) * t
                }
            }
            return color(stops[stops.count - 1])
        }

        let width = 256
        var pixels = [Float](repeating: 0, count: width * 4)
        for i in 0..<width {
            let c = sample(Float(i) / Float(width - 1))
            pixels[i * 4 + 0] = c.x
            pixels[i * 4 + 1] = c.y
            pixels[i * 4 + 2] = c.z
            pixels[i * 4 + 3] = c.w
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, 1),
                        mipmapLevel: 0,
                        withBytes: pixels,
                        bytesPerRow: width * 4 * MemoryLayout<Float>.size)
        gradientLUTCache[key] = texture
        return texture
    }
    // MARK: - MTKViewDelegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        let currentTime = CFAbsoluteTimeGetCurrent()
        updateThemeProgress(at: currentTime)
        view.clearColor = currentClearColor

        let time = Float(currentTime - startTime)
        let renderSize = CGSize(width: canvasSize.width * resolutionScale,
                               height: canvasSize.height * resolutionScale)
                // Create or verify ping-pong textures
        if currentSize != renderSize {
            createTextures(size: renderSize)
        }
        
        guard let pingTexture = pingTexture,
              let pongTexture = pongTexture else {
            return
        }
        
        // Create render pass descriptors for ping-pong textures
        let pingPassDescriptor = MTLRenderPassDescriptor()
        pingPassDescriptor.colorAttachments[0].texture = pingTexture
        pingPassDescriptor.colorAttachments[0].loadAction = .clear
        pingPassDescriptor.colorAttachments[0].clearColor = currentClearColor
        pingPassDescriptor.colorAttachments[0].storeAction = .store
        
        let pongPassDescriptor = MTLRenderPassDescriptor()
        pongPassDescriptor.colorAttachments[0].texture = pongTexture
        pongPassDescriptor.colorAttachments[0].loadAction = .dontCare
        pongPassDescriptor.colorAttachments[0].storeAction = .store
                // Step 1: Render gradients to ping texture
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pingPassDescriptor),
           let pipeline = gradientPipelineState {
            encoder.setRenderPipelineState(pipeline)
            
            var metalLayers = getMetalLayers()
            var resolution = SIMD2<Float>(Float(renderSize.width), Float(renderSize.height))

            encoder.setFragmentBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentBytes(&metalLayers, length: MemoryLayout<MetalLayerProperties>.stride * metalLayers.count, index: 1)

            var count = Int32(layerCount)
            encoder.setFragmentBytes(&count, length: MemoryLayout<Int32>.stride, index: 2)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        }
                // Step 2: Apply effects with ping-pong rendering
        var isReadingFromPing = true
                // Water effect
        if let pipeline = waterPipelineState {
            let inputTexture = isReadingFromPing ? pingTexture : pongTexture
            let outputDescriptor = isReadingFromPing ? pongPassDescriptor : pingPassDescriptor
            outputDescriptor.colorAttachments[0].loadAction = .dontCare

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputDescriptor) {
                encoder.setRenderPipelineState(pipeline)
                var waterParams = WaterParams(
    size: 1.28,
    highlights: 0.07,
    layering: 0.88,
    edges: 0.96,
    caustic: 0.0,
    waves: 0.0,
    speed: 0.39999998,
    colorBack: [0.0, 0.0, 0.0, 0.0],
    colorHighlight: [1.0, 1.0, 1.0, 1.0],
    opacity: 1.0
,
                    time: time,
                    resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height))
                )
                    encoder.setFragmentBytes(&waterParams, length: MemoryLayout<WaterParams>.stride, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()

                isReadingFromPing.toggle()
            }
        }
        // 3D Liquid Metal effect
        if let pipeline = liquidMetal3DPipelineState {
            let inputTexture = isReadingFromPing ? pingTexture : pongTexture
            let outputDescriptor = isReadingFromPing ? pongPassDescriptor : pingPassDescriptor
            outputDescriptor.colorAttachments[0].loadAction = .dontCare

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputDescriptor) {
                encoder.setRenderPipelineState(pipeline)
                var liquidMetal3DParams = LiquidMetal3DParams(
    posX: 0.0,
    posY: 0.0,
    size: 0.8,
    wobble: 0.0,
    shape: 0,
    spin: 0.59,
    refraction: 0.099999994,
    metalness: 1.0,
    repetition: 0.3,
    softness: 1.0,
    shiftRed: 0.13,
    shiftBlue: 0.13,
    distortion: 0.1,
    contour: 0.29,
    angle: 154.0,
    contrast: 1.0,
    shading: 0.0,
    darkFade: 0.0,
    waveSpeed: 1.0,
    waveStrength: 1.0,
    glowSpeed: 1.0,
    glowStrength: 1.0,
    speed: 0.344,  // baked 0.43, dialed down 20%
    delay: 1.0,
    colorMode: 1,
    paletteLock: 1,
    stops: [],
    colorBack: [0.667, 0.667, 0.675, 0.0],
    colorTint: [1.0, 1.0, 1.0, 1.0],
    colorGlass: [1.0, 1.0, 1.0, 0.0],
    opacity: 1.0
,
                    time: time,
                    resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height))
                )
                    encoder.setFragmentBytes(&liquidMetal3DParams, length: MemoryLayout<LiquidMetal3DParams>.stride, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 0)
                        encoder.setFragmentTexture(gradientLUT(stops: [[0.023529412, 0.39607835, 0.73725504, 1.0, 0.0], [0.29411754, 0.007843138, 0.15294115, 1.0, 0.25], [0.02745098, 0.41960785, 0.92156863, 1.0, 0.5], [0.47058824, 0.73333335, 0.69411767, 1.0, 0.75], [0.8745098, 0.8392157, 0.81960785, 1.0, 1.0]]) ?? inputTexture, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()

                isReadingFromPing.toggle()
            }
        }
        // 3D Liquid Metal effect
        if let pipeline = liquidMetal3DPipelineState {
            let inputTexture = isReadingFromPing ? pingTexture : pongTexture
            let outputDescriptor = isReadingFromPing ? pongPassDescriptor : pingPassDescriptor
            outputDescriptor.colorAttachments[0].loadAction = .dontCare

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputDescriptor) {
                encoder.setRenderPipelineState(pipeline)
                var liquidMetal3DParams = LiquidMetal3DParams(
    posX: 0.7,
    posY: 0.0,
    size: 0.8,
    wobble: 0.0,
    shape: 0,
    spin: 0.59,
    refraction: 0.099999994,
    metalness: 1.0,
    repetition: 0.3,
    softness: 1.0,
    shiftRed: 0.13,
    shiftBlue: 0.13,
    distortion: 0.1,
    contour: 0.29,
    angle: 154.0,
    contrast: 1.0,
    shading: 0.0,
    darkFade: 0.0,
    waveSpeed: 1.0,
    waveStrength: 1.0,
    glowSpeed: 1.0,
    glowStrength: 1.0,
    speed: 0.344,  // baked 0.43, dialed down 20%
    delay: 1.8000001,
    colorMode: 1,
    paletteLock: 1,
    stops: [],
    colorBack: [0.667, 0.667, 0.675, 0.0],
    colorTint: [1.0, 1.0, 1.0, 1.0],
    colorGlass: [1.0, 1.0, 1.0, 0.0],
    opacity: 1.0
,
                    time: time,
                    resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height))
                )
                    encoder.setFragmentBytes(&liquidMetal3DParams, length: MemoryLayout<LiquidMetal3DParams>.stride, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 0)
                        encoder.setFragmentTexture(gradientLUT(stops: [[0.023529412, 0.39607844, 0.7372549, 1.0, 0.0], [0.29411766, 0.007843138, 0.15294118, 1.0, 0.25], [0.02745098, 0.41960785, 0.92156863, 1.0, 0.5], [0.47058824, 0.73333335, 0.69411767, 1.0, 0.75], [0.8745098, 0.8392157, 0.81960785, 1.0, 1.0]]) ?? inputTexture, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()

                isReadingFromPing.toggle()
            }
        }
        // 3D Liquid Metal effect
        if let pipeline = liquidMetal3DPipelineState {
            let inputTexture = isReadingFromPing ? pingTexture : pongTexture
            let outputDescriptor = isReadingFromPing ? pongPassDescriptor : pingPassDescriptor
            outputDescriptor.colorAttachments[0].loadAction = .dontCare

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputDescriptor) {
                encoder.setRenderPipelineState(pipeline)
                var liquidMetal3DParams = LiquidMetal3DParams(
    posX: -0.7,
    posY: 0.0,
    size: 0.8,
    wobble: 0.0,
    shape: 0,
    spin: 0.59,
    refraction: 0.08,
    metalness: 1.0,
    repetition: 0.3,
    softness: 1.0,
    shiftRed: -0.13,
    shiftBlue: -0.17,
    distortion: 0.1,
    contour: 0.29,
    angle: 154.0,
    contrast: 1.0,
    shading: 0.0,
    darkFade: 0.0,
    waveSpeed: 1.0,
    waveStrength: 1.0,
    glowSpeed: 1.0,
    glowStrength: 1.0,
    speed: 0.344,  // baked 0.43, dialed down 20%
    delay: 0.0,
    colorMode: 1,
    paletteLock: 0,
    stops: [],
    colorBack: [0.667, 0.667, 0.675, 0.0],
    colorTint: [1.0, 1.0, 1.0, 1.0],
    colorGlass: [1.0, 1.0, 1.0, 0.0],
    opacity: 1.0
,
                    time: time,
                    resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height))
                )
                    encoder.setFragmentBytes(&liquidMetal3DParams, length: MemoryLayout<LiquidMetal3DParams>.stride, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 0)
                        encoder.setFragmentTexture(gradientLUT(stops: [[0.023529412, 0.39607844, 0.7372549, 1.0, 0.0], [0.29411766, 0.007843138, 0.15294118, 1.0, 0.25], [0.02745098, 0.41960785, 0.92156863, 1.0, 0.5], [0.47058824, 0.73333335, 0.69411767, 1.0, 0.75], [0.8745098, 0.8392157, 0.81960785, 1.0, 1.0]]) ?? inputTexture, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()

                isReadingFromPing.toggle()
            }
        }
        // Progressive Blur effect (3 passes: H→V→H)
        if let pipeline = progressiveBlurPipelineState {
            for pass in 0..<3 {
                let inputTexture = isReadingFromPing ? pingTexture : pongTexture
                let outputDescriptor = isReadingFromPing ? pongPassDescriptor : pingPassDescriptor
                outputDescriptor.colorAttachments[0].loadAction = .dontCare

                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputDescriptor) else {
                    continue
                }

                encoder.setRenderPipelineState(pipeline)

                // The blur's falloff direction sweeps a full clockwise
                // revolution per minute (rotation is normalized: 1.0 =
                // 360° in the shader).  sin/cos are continuous across
                // the wrap, so the loop is seamless.
                let blurRotation = (0.44444445 - time / 60.0)
                    .truncatingRemainder(dividingBy: 1.0)
                var progressiveBlurParams = ProgressiveBlurParams(
                    center: SIMD2<Float>(0.5, 0.5),
                    amount: 1.99,
                    samples: 16,
                    opacity: 1.0,
                    rotation: blurRotation,
                    falloffPower: 2.0,
                    resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height)),
                    pass: Int32(pass)
                )

                encoder.setFragmentBytes(&progressiveBlurParams, length: MemoryLayout<ProgressiveBlurParams>.stride, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()

                isReadingFromPing.toggle()
            }
        }
        // Skew effect
        if let pipeline = skewPipelineState {
            let inputTexture = isReadingFromPing ? pingTexture : pongTexture
            let outputDescriptor = isReadingFromPing ? pongPassDescriptor : pingPassDescriptor
            outputDescriptor.colorAttachments[0].loadAction = .dontCare

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputDescriptor) {
                encoder.setRenderPipelineState(pipeline)
                var skewParams = SkewParams(
    rotationX: 0.0,
    rotationY: 0.0,
    rotationZ: 0.0,
    perspective: 2.5,
    center: [0.5, 0.5],
    opacity: 1.0,
    skewX: 0.0,
    skewY: 0.0,
    hideBackface: false
,
                    resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height))
                )
                    encoder.setFragmentBytes(&skewParams, length: MemoryLayout<SkewParams>.stride, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()

                isReadingFromPing.toggle()
            }
        }
        // Procedural Grain effect
        if let pipeline = proceduralGrainPipelineState {
            let inputTexture = isReadingFromPing ? pingTexture : pongTexture
            let outputDescriptor = isReadingFromPing ? pongPassDescriptor : pingPassDescriptor
            outputDescriptor.colorAttachments[0].loadAction = .dontCare

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputDescriptor) {
                encoder.setRenderPipelineState(pipeline)
                var proceduralGrainParams = ProceduralGrainParams(
    time: time,
    resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height)),
    intensity: 0.14,
    blendMode: 2,
    speed: 1.72,
    mean: 0.19,
    variance: 0.6
)
                    encoder.setFragmentBytes(&proceduralGrainParams, length: MemoryLayout<ProceduralGrainParams>.stride, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()

                isReadingFromPing.toggle()
            }
        }
        // Fresnel effect — intensity is user-adjustable (see
        // fresnelIntensityScale); the pass is skipped entirely at zero.
        if let pipeline = fresnelPipelineState, fresnelIntensityScale > 0.005 {
            let inputTexture = isReadingFromPing ? pingTexture : pongTexture
            let outputDescriptor = isReadingFromPing ? pongPassDescriptor : pingPassDescriptor
            outputDescriptor.colorAttachments[0].loadAction = .dontCare

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputDescriptor) {
                encoder.setRenderPipelineState(pipeline)
                var fresnelParams = FresnelParams(
    fresnelType: 0,
    center: SIMD2<Float>(0.5, 0.5),
    radius: 2.0,
    angle: 0.0,
    scale: 1.0,
    power: 5.79,
    intensity: 0.75 * fresnelIntensityScale,
    softness: 0.0,
    invert: false,
    useGradient: true,
    fresnelColor: SIMD3<Float>(1.0, 1.0, 1.0),
    innerColor: SIMD3<Float>(0.0, 0.5, 1.0),
    outerColor: SIMD3<Float>(1.0, 0.5, 0.0),
    gradientPower: 1.0,
    blendMode: 0,
    chromaticAberration: 0.0
,
                    resolution: SIMD2<Float>(Float(renderSize.width), Float(renderSize.height))
                )
                    encoder.setFragmentBytes(&fresnelParams, length: MemoryLayout<FresnelParams>.stride, index: 0)
                encoder.setFragmentTexture(inputTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()

                isReadingFromPing.toggle()
            }
        }
        
        // Step 3: Copy final result to screen
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let pipeline = passthroughPipelineState else {
            return
        }
        
        encoder.setRenderPipelineState(pipeline)
        let finalTexture = isReadingFromPing ? pingTexture : pongTexture
        encoder.setFragmentTexture(finalTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
                // Present
        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

}
