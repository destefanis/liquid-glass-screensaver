//
//  LiquidGlassShader.metal
//  liquid-glass-screensaver
//
//  The liquid glass shader composition: soft layer fills plus a
//  chain of full-screen effect passes (water caustics, 3D liquid
//  metal, progressive blur, skew, grain, fresnel).
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Vertex Structures

struct EffectVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct VertexIn {
    float2 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - Layer Properties

/// Per-layer data for the base gradient pass.  This composition
/// only uses solid-colour circle/rect fills, so the struct carries
/// just those fields (order must match the Swift-side struct).
struct LayerProperties {
    float4 color;
    float2 center;
    float radius;
    int shape;             // 0: hard circle, 1/2: rect, 3: soft circle
    float opacity;
    float width;
    float height;
    float softness;
    float squircleRadius;
    float rotation;
    float fillOpacity;
};
// MARK: - Grain Helpers

//
//
//  Common utility functions for grain effects
//


using namespace metal;

// Color space conversion helpers
inline float3 channel_mix(float3 a, float3 b, float3 w) {
    return float3(mix(a.r, b.r, w.r), mix(a.g, b.g, w.g), mix(a.b, b.b, w.b));
}

inline float gaussian(float z, float u, float o) {
    return (1.0 / (o * sqrt(2.0 * 3.1415))) * exp(-(((z - u) * (z - u)) / (2.0 * (o * o))));
}

inline float3 madd(float3 a, float3 b, float w) {
    return a + a * b * w;
}

inline float3 screen(float3 a, float3 b, float w) {
    return mix(a, float3(1.0) - (float3(1.0) - a) * (float3(1.0) - b), w);
}

inline float3 overlay(float3 a, float3 b, float w) {
    return mix(a, channel_mix(
        2.0 * a * b,
        float3(1.0) - 2.0 * (float3(1.0) - a) * (float3(1.0) - b),
        step(float3(0.5), a)
    ), w);
}

inline float3 soft_light(float3 a, float3 b, float w) {
    return mix(a, pow(a, pow(float3(2.0), 2.0 * (float3(0.5) - b))), w);
}





// MARK: - Shape Mask

/// Alpha mask for a layer shape at `uv`.  Soft circles use a
/// gaussian skirt at high softness so the glow fades without a
/// visible termination ring.
float calculateShapeMask(float2 uv, float2 center, int shape, float radius,
                         float width, float height, float aspect, float softness,
                         float squircleRadius, float2 resolution) {
    // Scale-aware edge width for antialiasing
    float baseEdgeWidth = 2.0 / min(resolution.x, resolution.y);
    float shapeSize = (shape == 1 || shape == 2) ? max(width, height) : radius;
    float scaleFactor = max(0.8, min(1.0, 0.5 / max(shapeSize, 0.001)));
    float edgeWidth = baseEdgeWidth * scaleFactor;

    if (shape == 0) {
        // Hard Circle
        float dist = length((uv - center) * float2(aspect, 1.0));
        return 1.0 - smoothstep(radius - edgeWidth, radius + edgeWidth, dist);
    }
    else if (shape == 1 || shape == 2) {
        // Rectangle (with optional rounded corners via squircleRadius)
        float2 pos = (uv - center) * float2(aspect, 1.0);
        float2 halfSize = float2(width * 0.5, height * 0.5);

        // Apply corner radius (0.0 = sharp corners, 1.0 = maximum roundness)
        // Corner radius is a percentage of the smaller dimension
        float maxCornerRadius = min(halfSize.x, halfSize.y);
        float cornerRadius = clamp(squircleRadius, 0.0, 1.0) * maxCornerRadius;

        // Signed distance to rounded rectangle
        float2 dist = abs(pos) - halfSize + cornerRadius;
        float rectDist = length(max(dist, 0.0)) + min(max(dist.x, dist.y), 0.0) - cornerRadius;

        return 1.0 - smoothstep(-edgeWidth, edgeWidth, rectDist);
    }
    else if (shape == 3) {
        // Soft Circle
        float dist = length((uv - center) * float2(aspect, 1.0));

        float innerEdge = radius - softness * radius * 0.5;
        float outerEdge = radius + softness * radius * 0.5;
        innerEdge = max(innerEdge, 0.0);

        // Legacy band profile — kept for low softness, where its crisp
        // termination is the point.
        float bandCov = 1.0 - smoothstep(innerEdge, outerEdge, dist);

        // Gaussian profile for high softness: same inner plateau and the
        // same 50% coverage at the nominal radius, but an airbrush skirt
        // that fades out asymptotically instead of terminating — a
        // smoothstep band always ends with an abrupt curvature change
        // that reads as a faint ring around the glow.
        float sigma = max(0.5 * softness * radius, 1e-5);
        float x = max(dist - innerEdge, 0.0) / sigma;
        float gaussCov = exp2(-x * x);
        // Finite support: fade the last sub-1% sliver of the tail to true
        // zero so 8-bit targets don't band across an endless skirt.
        gaussCov *= 1.0 - smoothstep(2.2, 3.0, x);

        // Crisp band at low softness, fully gaussian by ~0.35.
        return mix(bandCov, gaussCov, smoothstep(0.0, 0.35, softness));
    }

    return 0.0;
}
// MARK: - Procedural Grain Effect

//
//
//  Procedural grain effect with various blend modes
//


using namespace metal;

struct ProceduralGrainParams {
    float time;
    float2 resolution;
    float intensity;
    int blendMode;      // 0: Addition, 1: Screen, 2: Overlay, 3: Soft Light, 4: Lighten-Only
    float speed;
    float mean;         // What gray level noise should tend to
    float variance;     // Controls the contrast/variance of noise
};

fragment float4 procedural_grain_fragment(EffectVertexOut in [[stage_in]],
                                          texture2d<float> inputTexture [[texture(0)]],
                                          constant ProceduralGrainParams &params [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Flip Y to match UI coordinate system
    float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    
    float4 color = inputTexture.sample(textureSampler, uv);
    
    // Skip transparent pixels
    if (color.a <= 0.001) {
        return float4(0.0);
    }
    
    float t = params.time * params.speed;
    float seed = dot(uv, float2(13.0327, 77.928));
    float noise = fract(sin(seed) * 42192.7129 + t);
    noise = gaussian(noise, params.mean, params.variance * params.variance);
    
    float w = params.intensity;
    float3 grain = float3(noise) * (1.0 - color.rgb);
    
    if (params.blendMode == 0) {
        // Addition
        color.rgb += grain * w;
    } else if (params.blendMode == 1) {
        // Screen
        color.rgb = screen(color.rgb, grain, w);
    } else if (params.blendMode == 2) {
        // Overlay
        color.rgb = overlay(color.rgb, grain, w);
    } else if (params.blendMode == 3) {
        // Soft Light
        color.rgb = soft_light(color.rgb, grain, w);
    } else if (params.blendMode == 4) {
        // Lighten-Only
        color.rgb = max(color.rgb, grain * w);
    }
    
    return color;
}





// MARK: - 3D Liquid Metal Effect

//
//
//  3D Liquid Metal — the liquid metal stripe material (chromatic stripes,
//  edge contour warping, wave + glow clocks) applied to a raymarched SDF
//  sphere. The sphere's fresnel silhouette plays the role the mask edge
//  gradient plays in the 2D effect, so the stripes bend around the rim the
//  same way. A wobble term displaces the surface with animated waves so the
//  ball reads as liquid rather than rigid chrome.
//
//  Material math ported from paper-design/shaders (Apache-2.0),
//  `liquid-metal.ts`: https://github.com/paper-design/shaders
//  Helpers are `lm3d_`-prefixed (shared metallib).
//


using namespace metal;

constant float LM3D_PI = 3.14159265358979323846;
constant int   LM3D_MARCH_STEPS = 80;

struct LiquidMetal3DParams {
    float2 resolution;
    float  time;
    float  speed;
    float  posX;        // sphere centre offset, -1..1
    float  posY;
    float  size;        // shape radius scale (1 = default)
    float  wobble;      // liquid surface displacement (0 = rigid shape)
    float  spin;        // tumble speed of the shape (0 = static tilt)
    int    shape;       // 0 sphere, 1 pill, 2 cube, 3 torus, 4 gem, 5 blob
    float  refraction;  // how strongly the scene bends through the glass
    float  metalness;   // metal gleam over the glass (0 = pure glass ball)
    float  repetition;  // stripe density across the sphere
    float  softness;    // stripe transition softness (0..1)
    float  shiftRed;    // R-channel dispersion (-1..1)
    float  shiftBlue;   // B-channel dispersion (-1..1)
    float  distortion;  // noise distortion over the stripes (0..1)
    float  contour;     // silhouette-edge distortion strength (0..1)
    float  angle;       // pattern direction, degrees (0..360)
    float  contrast;    // ramp contrast: 1 = full metal, 0 = flat sheen
    float  shading;     // 3D light shading amount (0 = flat material)
    float  darkFade;    // dark gleams go transparent instead of painting dark
    float  waveSpeed;   // drift speed of the noise wave (the colour swoosh)
    float  waveStrength;// influence of the noise wave (0 = none, 1 = original)
    float  glowSpeed;   // sweep speed of the bright wash (the "backlight")
    float  glowStrength;// brightness of the wash (0 = none, 1 = original)
    float  opacity;
    int    colorMode;   // 0 = classic silver, 1 = gradient LUT (texture 1)
    int    paletteLock; // 1 = keep dispersion within the gradient palette
    float4 colorBack;
    float4 colorTint;
    float4 colorGlass;  // glass body colour (alpha = strength)
};

static inline float2 lm3d_rotate(float2 uv, float th) {
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

// GLSL-style sign-correct mod for the simplex lattice.
static inline float2 lm3d_mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static inline float3 lm3d_mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static inline float3 lm3d_permute(float3 x) { return lm3d_mod289(((x * 34.0) + 1.0) * x); }

static inline float lm3d_snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
                            -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = lm3d_mod289(i);
    float3 p = lm3d_permute(lm3d_permute(i.y + float3(0.0, i1.y, 1.0))
                            + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy),
                                dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

// One channel of the stripe colour ramp — identical to the 2D effect's,
// including the `glow` scale on the bright start of the wide gradient.
static inline float lm3d_getColorChanges(float c1, float c2, float stripe_p, float3 w,
                                         float blur, float bump, float tint,
                                         float tintAlpha, float glow) {
    float ch = mix(c2, c1, smoothstep(0.0, 2.0 * blur, stripe_p));

    float border = w[0];
    ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));

    bump = smoothstep(0.2, 0.8, bump);
    border = w[0] + 0.4 * (1.0 - bump) * w[1];
    ch = mix(ch, c1, smoothstep(border, border + 2.0 * blur, stripe_p));

    border = w[0] + 0.5 * (1.0 - bump) * w[1];
    ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));

    border = w[0] + w[1];
    ch = mix(ch, c1, smoothstep(border, border + 2.0 * blur, stripe_p));

    float gradient_t = (stripe_p - w[0] - w[1]) / w[2];
    float gradient = mix(mix(c2, c1, glow), c2, smoothstep(0.0, 1.0, gradient_t));
    ch = mix(ch, gradient, smoothstep(border, border + 0.5 * blur, stripe_p));

    ch = mix(ch, 1.0 - min(1.0, (1.0 - ch) / max(tint, 0.0001)), tintAlpha);
    return ch;
}

// Polynomial smooth minimum — merges the blob's metaballs.
static inline float lm3d_smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Gentle tumble (yaw + pitch) — orients the non-sphere shapes so they read
// as 3D, and spins them when the Spin knob is up.
static inline float3 lm3d_tumble(float3 p, float t) {
    float cy = cos(t);
    float sy = sin(t);
    p.xz = float2(cy * p.x - sy * p.z, sy * p.x + cy * p.z);
    float cx = cos(t * 0.7);
    float sx = sin(t * 0.7);
    p.yz = float2(cx * p.y - sx * p.z, sx * p.y + cx * p.z);
    return p;
}

// Shape SDF with two octaves of travelling sine displacement — the liquid
// wobble. Frequencies scale with 1/R so the wobble look is size-independent.
// The tumble rotates only the SDF: the material keeps flowing in view space
// while the shape turns beneath the glass.
static inline float lm3d_map(float3 p, float R, int shape, float wobble,
                             float tw, float spinT) {
    float3 q = (shape == 0) ? p : lm3d_tumble(p, spinT);

    float d;
    switch (shape) {
        case 1: {   // pill — capsule along x
            float3 a = q - float3(clamp(q.x, -0.5 * R, 0.5 * R), 0.0, 0.0);
            d = length(a) - 0.58 * R;
            break;
        }
        case 2: {   // cube — rounded box
            float3 dd = abs(q) - float3(0.58 * R);
            d = length(max(dd, 0.0)) + min(max(dd.x, max(dd.y, dd.z)), 0.0) - 0.16 * R;
            break;
        }
        case 3: {   // torus — facing the camera, tilted by the tumble
            float2 t2 = float2(length(q.xy) - 0.66 * R, q.z);
            d = length(t2) - 0.3 * R;
            break;
        }
        case 4: {   // gem — rounded octahedron (approximate SDF)
            d = (abs(q.x) + abs(q.y) + abs(q.z) - 1.05 * R) * 0.57735 - 0.04 * R;
            break;
        }
        case 5: {   // blob — three metaballs orbiting into each other
            float3 c1 = 0.42 * R * float3(sin(tw * 0.70), cos(tw * 0.90), 0.6 * sin(tw * 0.50));
            float3 c2 = 0.42 * R * float3(sin(tw * 0.55 + 2.1), cos(tw * 0.65 + 4.2), 0.6 * cos(tw * 0.45));
            float3 c3 = 0.42 * R * float3(cos(tw * 0.80 + 1.3), sin(tw * 0.60 + 3.1), 0.6 * sin(tw * 0.75 + 5.0));
            float k = 0.38 * R;
            d = lm3d_smin(length(q - c1) - 0.5 * R, length(q - c2) - 0.44 * R, k);
            d = lm3d_smin(d, length(q - c3) - 0.4 * R, k);
            break;
        }
        default:    // sphere
            d = length(q) - R;
            break;
    }

    if (wobble > 0.001) {
        float3 qw = q * (5.0 / R);
        float w = sin(qw.x + 1.6 * tw) * sin(qw.y * 1.27 - 1.2 * tw) * sin(qw.z * 0.93 + 0.8 * tw);
        w += 0.55 * sin(qw.y * 2.1 + 2.0 * tw) * sin(qw.z * 1.63 - 1.4 * tw);
        d -= wobble * R * 0.09 * w;
    }
    return d;
}

static inline float3 lm3d_normal(float3 p, float R, int shape, float wobble,
                                 float tw, float spinT) {
    float e = max(0.0015, R * 0.004);
    return normalize(float3(
        lm3d_map(p + float3(e, 0, 0), R, shape, wobble, tw, spinT) - lm3d_map(p - float3(e, 0, 0), R, shape, wobble, tw, spinT),
        lm3d_map(p + float3(0, e, 0), R, shape, wobble, tw, spinT) - lm3d_map(p - float3(0, e, 0), R, shape, wobble, tw, spinT),
        lm3d_map(p + float3(0, 0, e), R, shape, wobble, tw, spinT) - lm3d_map(p - float3(0, 0, e), R, shape, wobble, tw, spinT)));
}

fragment float4 liquid_metal_3d_fragment(EffectVertexOut in [[stage_in]],
                                         texture2d<float> inputTexture [[texture(0)]],
                                         texture2d<float> gradLUT [[texture(1)]],
                                         constant LiquidMetal3DParams &params [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    constexpr sampler lutSampler(coord::normalized,
                                 address::clamp_to_edge,
                                 filter::linear);

    float2 baseUV = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    float  ratio = params.resolution.x / max(params.resolution.y, 1.0);
    float4 originalInput = inputTexture.sample(s, baseUV);

    const float firstFrameOffset = 2.8;
    float t = 0.3 * (params.time * params.speed + firstFrameOffset);
    float tWave = 0.3 * (params.time * params.speed * params.waveSpeed + firstFrameOffset);
    float tGlow = 0.3 * (params.time * params.speed * params.glowSpeed + firstFrameOffset);
    float tWobble = 0.6 * params.time * params.speed + 3.0;
    // Base tilt so static shapes still show a corner/edge; Spin tumbles.
    float spinT = 0.55 + 0.4 * params.time * params.speed * params.spin;

    // ── Camera & sphere ──────────────────────────────────────────────────
    // Screen coords centred on the sphere, isotropic, y up. Shifting the
    // coords (not the sphere) keeps the ball face-on wherever it sits.
    float2 sc = baseUV - 0.5;
    if (ratio > 1.0) { sc.x *= ratio; } else { sc.y /= ratio; }
    sc -= float2(params.posX, params.posY) * 0.5;

    float R = 0.62 * max(params.size, 0.01);
    float3 ro = float3(0.0, 0.0, 2.4);
    float3 rd = normalize(float3(sc, -1.0));

    // Bounding-sphere entry point → march only the interesting segment.
    // (Wide enough for every shape's extent plus the wobble.)
    float Rb = R * ((params.shape == 0) ? 1.15 : 1.5);
    float b = dot(ro, rd);
    float c = dot(ro, ro) - Rb * Rb;
    float h = b * b - c;

    float coverage = 0.0;
    float3 P = float3(0.0);
    bool hit = false;
    // ~1.5px in world units at the sphere's depth plane, for silhouette AA.
    float aa = 3.6 / max(params.resolution.y, 1.0);

    if (h > 0.0) {
        float dist = max(-b - sqrt(h), 0.0);
        float distEnd = -b + sqrt(h);
        float minD = 1e5;
        float3 pMin = ro + rd * dist;
        for (int i = 0; i < LM3D_MARCH_STEPS; ++i) {
            float3 p = ro + rd * dist;
            float d = lm3d_map(p, R, params.shape, params.wobble, tWobble, spinT);
            if (d < minD) { minD = d; pMin = p; }
            if (d < 0.0012) { hit = true; P = p; break; }
            dist += max(d * 0.6, 0.0015);
            if (dist > distEnd) break;
        }
        if (hit) {
            coverage = 1.0;
        } else {
            coverage = 1.0 - smoothstep(0.0, aa, minD);
            P = pMin;   // AA fringe shades from the closest-approach point
        }
    }

    // ── Glass sphere wearing the liquid metal material ───────────────────
    // The ball is glass: the layers below refract through it (with a touch
    // of chromatic dispersion), and the stripe material rides on top as
    // fresnel-weighted gleams — bright bands and the wash show as metal,
    // dark parts of the cycle stay transparent glass.
    float3 sphereRGB = float3(0.0);
    float sphereA = 0.0;

    if (coverage > 0.001) {
        float3 N = lm3d_normal(P, R, params.shape, params.wobble, tWobble, spinT);
        float3 V = -rd;
        float ndv = clamp(dot(N, V), 0.0, 1.0);

        // Fresnel silhouette = the 2D effect's mask-edge gradient.
        float fres = pow(1.0 - ndv, 1.4);
        float edge = fres * smoothstep(0.0, 0.4, params.contour);

        // Sphere-local surface uv, y DOWN (the bump/lighting math of the
        // ported material expects y=0 at the top).
        float3 pl = P / R;
        float2 uv = float2(0.5 + 0.5 * pl.x, 0.5 - 0.5 * pl.y);

        float cycleWidth = params.repetition;

        // Stripe-direction rotation (about the sphere centre).
        float2 rotatedUV = uv - float2(0.5);
        float angle = (-params.angle + 70.0) * LM3D_PI / 180.0;
        float cosA = cos(angle);
        float sinA = sin(angle);
        rotatedUV = float2(rotatedUV.x * cosA - rotatedUV.y * sinA,
                           rotatedUV.x * sinA + rotatedUV.y * cosA) + float2(0.5);

        float diagBLtoTR = rotatedUV.x - rotatedUV.y;
        float diagTLtoBR = rotatedUV.x + rotatedUV.y;

        float3 color1 = float3(0.98, 0.98, 1.0);
        float3 color2 = float3(0.1, 0.1, 0.1 + 0.1 * smoothstep(0.7, 1.3, diagTLtoBR));

        float2 grad_uv = uv - 0.5;

        float dist2 = length(grad_uv + float2(0.0, 0.2 * diagBLtoTR));
        grad_uv = lm3d_rotate(grad_uv, (0.25 - 0.2 * diagBLtoTR) * LM3D_PI);
        float direction = grad_uv.x;

        float bump = pow(1.8 * dist2, 1.2);
        bump = 1.0 - bump;
        bump *= pow(clamp(uv.y, 0.0, 1.0), 0.3);

        float thin_strip_1_ratio = 0.12 / cycleWidth * (1.0 - 0.4 * bump);
        float thin_strip_2_ratio = 0.07 / cycleWidth * (1.0 + 0.4 * bump);
        float wide_strip_ratio = (1.0 - thin_strip_1_ratio - thin_strip_2_ratio);

        float thin_strip_1_width = cycleWidth * thin_strip_1_ratio;
        float thin_strip_2_width = cycleWidth * thin_strip_2_ratio;

        // The noise wave (the colour swoosh), on its own clock.
        float noise = lm3d_snoise(uv - tWave) * params.waveStrength;

        edge += (1.0 - edge) * params.distortion * noise;

        direction += diagBLtoTR;
        direction -= 2.0 * noise * diagBLtoTR * (smoothstep(0.0, 1.0, edge) * (1.0 - smoothstep(0.0, 1.0, edge)));
        direction *= mix(1.0, 1.0 - edge, smoothstep(0.5, 1.0, params.contour));
        direction -= 1.7 * edge * smoothstep(0.5, 1.0, params.contour);
        direction += 0.2 * pow(params.contour, 4.0) * (1.0 - smoothstep(0.0, 1.0, edge));

        bump *= clamp(pow(clamp(uv.y, 0.0, 1.0), 0.1), 0.3, 1.0);
        direction *= (0.1 + (1.1 - edge) * bump);

        direction *= (0.4 + 0.6 * (1.0 - smoothstep(0.5, 1.0, edge)));
        direction += 0.18 * (smoothstep(0.1, 0.2, uv.y) * (1.0 - smoothstep(0.2, 0.4, uv.y)));
        direction += 0.03 * (smoothstep(0.1, 0.2, 1.0 - uv.y) * (1.0 - smoothstep(0.2, 0.4, 1.0 - uv.y)));

        direction *= (0.5 + 0.5 * pow(clamp(uv.y, 0.0, 1.0), 2.0));
        direction *= cycleWidth;
        // Bands on the material clock, the bright wash on its own.
        float directionGlow = direction - tGlow;
        direction -= t;

        float colorDispersion = (1.0 - bump);
        colorDispersion = clamp(colorDispersion, 0.0, 1.0);
        float dispersionRed = colorDispersion;
        dispersionRed += 0.03 * bump * noise;
        dispersionRed += 5.0 * (smoothstep(-0.1, 0.2, uv.y) * (1.0 - smoothstep(0.1, 0.5, uv.y)))
                       * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 1.0, bump)));
        dispersionRed -= diagBLtoTR;

        float dispersionBlue = colorDispersion;
        dispersionBlue *= 1.3;
        dispersionBlue += (smoothstep(0.0, 0.4, uv.y) * (1.0 - smoothstep(0.1, 0.8, uv.y)))
                        * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 0.8, bump)));
        dispersionBlue -= 0.2 * edge;

        dispersionRed *= (params.shiftRed / 20.0);
        dispersionBlue *= (params.shiftBlue / 20.0);

        float softness = 0.05 * params.softness;
        float blur = softness + 0.5 * smoothstep(1.0, 10.0, params.repetition) * smoothstep(0.0, 1.0, edge);
        float rExtraBlur = softness * (0.05 + 0.1 * (params.shiftRed / 20.0) * bump);
        float gExtraBlur = softness * 0.05 / max(0.001, abs(1.0 - diagBLtoTR));

        float3 w = float3(thin_strip_1_width, thin_strip_2_width, wide_strip_ratio);
        w[1] -= 0.02 * smoothstep(0.0, 1.0, edge + bump);
        float stripe_r = fract(direction + dispersionRed);
        float stripe_g = fract(direction);
        float stripe_b = fract(direction - dispersionBlue);
        float blurR = blur + fwidth(stripe_r) + rExtraBlur;
        float blurG = blur + fwidth(stripe_g) + gExtraBlur;
        float blurB = blur + fwidth(stripe_b);

        float glowStripe_r = fract(directionGlow + dispersionRed);
        float glowStripe_g = fract(directionGlow);
        float glowStripe_b = fract(directionGlow - dispersionBlue);
        float glowBlurR = blur + fwidth(glowStripe_r) + rExtraBlur;
        float glowBlurG = blur + fwidth(glowStripe_g) + gExtraBlur;
        float glowBlurB = blur + fwidth(glowStripe_b);

        // Normalised ramp, bands + isolated wash (see the 2D effect): at
        // Glow Speed/Strength = 1 the sum reconstructs the original ramp.
        float tR = lm3d_getColorChanges(1.0, 0.0, stripe_r, w, blurR, bump, 1.0, 0.0, 0.0)
                 + params.glowStrength
                 * (lm3d_getColorChanges(1.0, 0.0, glowStripe_r, w, glowBlurR, bump, 1.0, 0.0, 1.0)
                  - lm3d_getColorChanges(1.0, 0.0, glowStripe_r, w, glowBlurR, bump, 1.0, 0.0, 0.0));
        float tG = lm3d_getColorChanges(1.0, 0.0, stripe_g, w, blurG, bump, 1.0, 0.0, 0.0)
                 + params.glowStrength
                 * (lm3d_getColorChanges(1.0, 0.0, glowStripe_g, w, glowBlurG, bump, 1.0, 0.0, 1.0)
                  - lm3d_getColorChanges(1.0, 0.0, glowStripe_g, w, glowBlurG, bump, 1.0, 0.0, 0.0));
        float tB = lm3d_getColorChanges(1.0, 0.0, stripe_b, w, blurB, bump, 1.0, 0.0, 0.0)
                 + params.glowStrength
                 * (lm3d_getColorChanges(1.0, 0.0, glowStripe_b, w, glowBlurB, bump, 1.0, 0.0, 1.0)
                  - lm3d_getColorChanges(1.0, 0.0, glowStripe_b, w, glowBlurB, bump, 1.0, 0.0, 0.0));
        tR = clamp(tR, 0.0, 1.0);
        tG = clamp(tG, 0.0, 1.0);
        tB = clamp(tB, 0.0, 1.0);

        // Contrast: compress the ramp toward its midpoint.
        tR = mix(0.5, tR, params.contrast);
        tG = mix(0.5, tG, params.contrast);
        tB = mix(0.5, tB, params.contrast);

        float3 color;
        float lutA = 1.0;
        if (params.colorMode == 1) {
            // Chromatic dispersion samples R and B at shifted ramp
            // positions. Small shifts = the intended iridescent fringe.
            // But recombining channels from DIFFERENT gradient stops can
            // manufacture muddy dark colours that exist nowhere in the
            // user's palette (worst at stripe-cycle seams, where the
            // channels wrap at different spots). Palette Lock keeps the
            // fringe only while the positions are near-identical and
            // falls back to the coherent single-position colour as they
            // diverge; toggled off, the raw dispersion look returns.
            float4 base = gradLUT.sample(lutSampler, float2(tG, 0.5));
            float3 dispersed = float3(gradLUT.sample(lutSampler, float2(tR, 0.5)).r,
                                      base.g,
                                      gradLUT.sample(lutSampler, float2(tB, 0.5)).b);
            if (params.paletteLock != 0) {
                float spread = max(abs(tR - tG), abs(tB - tG));
                float coherence = 1.0 - smoothstep(0.08, 0.3, spread);
                color = mix(base.rgb, dispersed, coherence);
            } else {
                color = dispersed;
            }
            lutA = base.a;
        } else {
            color = float3(mix(color2.r, color1.r, tR),
                           mix(color2.g, color1.g, tG),
                           mix(color2.b, color1.b, tB));
        }

        // Tint dyes the gleams directly (multiply; alpha = strength). The
        // 2D effect uses colour burn, but burn keeps highlights white and
        // the gleams here ARE the highlights — multiply actually colours
        // them. White tint = no-op, as before.
        color = mix(color, color * params.colorTint.rgb, params.colorTint.a);

        // Diffuse shading on the metal component (Shading knob; 0 keeps
        // the flat material of the 2D effect).
        float3 L = normalize(float3(-0.4, 0.55, 0.75));
        float diff = clamp(dot(N, L), 0.0, 1.0);
        color = mix(color, color * (0.55 + 0.45 * diff), params.shading);

        // ── Glass: refract the layers below through the surface ─────────
        // The bend is strongest at the rim (refract barely deviates where
        // the surface faces the camera), so the centre stays readable and
        // the silhouette visibly lenses — including over wobble bulges.
        float ior = mix(1.05, 1.9, params.refraction);
        float3 rrR = refract(rd, N, 1.0 / (ior + 0.025));
        float3 rrG = refract(rd, N, 1.0 / ior);
        float3 rrB = refract(rd, N, 1.0 / max(ior - 0.025, 1.001));
        float2 toUV = (ratio > 1.0) ? float2(1.0 / ratio, 1.0) : float2(1.0, ratio);
        float2 uvGl_r = clamp(baseUV + (rrR.xy - rd.xy) * 1.5 * R * toUV, 0.0, 1.0);
        float2 uvGl_g = clamp(baseUV + (rrG.xy - rd.xy) * 1.5 * R * toUV, 0.0, 1.0);
        float2 uvGl_b = clamp(baseUV + (rrB.xy - rd.xy) * 1.5 * R * toUV, 0.0, 1.0);
        float3 glassRGB = float3(inputTexture.sample(s, uvGl_r).r,
                                 inputTexture.sample(s, uvGl_g).g,
                                 inputTexture.sample(s, uvGl_b).b);
        float glassA = inputTexture.sample(s, uvGl_g).a;
        // Faint fresnel rim brightening so the glass reads even over
        // uniform backgrounds.
        glassRGB += 0.06 * fres;

        // Coloured glass: absorb the refracted scene through the tint and
        // give the body a faint self-colour (strongest at the rim) so the
        // ball still reads over thin or transparent backgrounds.
        float4 cg = params.colorGlass;
        glassRGB = mix(glassRGB, glassRGB * cg.rgb, cg.a);
        glassRGB += cg.rgb * cg.a * (0.10 + 0.25 * fres);
        glassA = mix(glassA, 1.0, 0.35 * cg.a);

        // Gleam weights: a steep curve on the ramp so the dark parts of
        // the cycle drop to pure transparent glass while the waves/bands
        // saturate to full colour fast. Fresnel multiplies (rim boost on
        // gleams that are already there) rather than adding haze of its
        // own. Gradient stop transparency (lutA) thins the gleam.
        float3 tCurve = pow(max(float3(tR, tG, tB), 0.0), float3(1.6));
        float3 wV = clamp(params.metalness * 2.2 * tCurve * (1.0 + 0.5 * fres), 0.0, 1.0) * lutA;

        // Dark Fade: a brightness THRESHOLD on gleam coverage, not a
        // scale — colours brighter than the cutoff paint at full strength,
        // while genuinely dark ones (the ramp's shadow side / the
        // gradient's lowest stops) dissolve to clear glass with a smooth
        // knee. This removes the dark rim streaks entirely without
        // dimming mid or bright colours. Channel max keeps saturated
        // colours (pure red/blue) counted as bright.
        if (params.darkFade > 0.001) {
            float gleamLum = max(color.r, max(color.g, color.b));
            wV *= smoothstep(0.0, params.darkFade, gleamLum);
        }

        float wR = wV.x;
        float wG = wV.y;
        float wB = wV.z;

        sphereRGB = float3(mix(glassRGB.r, color.r, wR),
                           mix(glassRGB.g, color.g, wG),
                           mix(glassRGB.b, color.b, wB));

        // Specular sparkle on top of glass and metal alike.
        float spec = pow(clamp(dot(reflect(-L, N), V), 0.0, 1.0), 48.0);
        sphereRGB += params.shading * 0.5 * spec;

        float wMax = max(wR, max(wG, wB));
        sphereA = mix(glassA, 1.0, wMax);
    }

    // Outside the sphere: back colour over the layer below (alpha 0 passes
    // the scene straight through). Inside: the glass content.
    float3 outsideRGB = params.colorBack.rgb * params.colorBack.a
                      + originalInput.rgb * (1.0 - params.colorBack.a);
    float  outsideA   = params.colorBack.a + originalInput.a * (1.0 - params.colorBack.a);

    float3 comp  = mix(outsideRGB, sphereRGB, coverage);
    float  compA = mix(outsideA,  sphereA,  coverage);

    // Colour-banding fix from the source (blue-noise-ish dither).
    comp += 1.0 / 256.0 * (fract(sin(dot(0.014 * in.position.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Fade the whole effect back to the input by layer opacity.
    float3 outRGB = mix(originalInput.rgb, comp, params.opacity);
    float  outA   = mix(originalInput.a, compA, params.opacity);
    return float4(clamp(outRGB, 0.0, 1.0), outA);
}



// MARK: - Fresnel Effect

//
//
//  Fresnel lighting effect with multiple types and blend modes
//


using namespace metal;

struct FresnelParams {
    // Type and positioning (0=radial, 1=edge-based, 2=directional)
    int fresnelType;
    float2 center;              // Center point for radial fresnel
    float radius;               // Radius for radial fresnel
    float angle;                // Angle for directional fresnel (in radians)
    float scale;                // Scale of the fresnel effect
    
    // Fresnel properties
    float power;                // Fresnel falloff power (higher = sharper edge)
    float intensity;            // Overall intensity
    float softness;             // Edge softness
    bool invert;                // Invert the fresnel effect
    
    // Falloff curve (0=power, 1=gaussian, 2=inverse square)
    int falloffCurve;
    
    // Glow mode (0=outer, 1=inner, 2=ring/border)
    int glowMode;
    float innerRadius;          // Inner radius for ring mode
    
    // Light simulation
    float areaLightSize;        // Size of light source (larger = softer edges)
    float lightHeight;          // Z offset for rim lighting simulation
    
    // Color settings
    bool useGradient;           // Use gradient instead of single color
    float3 fresnelColor;        // Single color mode
    float3 innerColor;          // Inner gradient color
    float3 outerColor;          // Outer gradient color
    float gradientPower;        // Power curve for gradient transition
    
    // Blend mode (0=add, 1=multiply, 2=overlay, 3=screen, 4=colorDodge, 5=linearBurn)
    int blendMode;
    
    // Chromatic aberration
    float chromaticAberration;  // Amount of chromatic aberration (0 = none)
    
    float2 resolution;          // Canvas resolution for aspect ratio correction
    float opacity;              // Effect opacity (0-1)
};

// Apply falloff curve to a normalized value
float applyFalloffCurve(float value, float power, int curveType, float softness) {
    if (curveType == 1) {
        // Gaussian falloff - smooth bell curve
        float sigma = max(softness, 0.1) * 0.5;
        float invValue = 1.0 - value;  // Convert to distance-like value
        return exp(-(invValue * invValue) / (2.0 * sigma * sigma));
    } else if (curveType == 2) {
        // Inverse square falloff - physically accurate light decay
        float dist = 1.0 - value;
        return 1.0 / (1.0 + dist * dist * power * 10.0);
    } else {
        // Power falloff (default) - exponential curve
        return pow(value, power);
    }
}

// Apply light height simulation (rim lighting effect)
float applyLightHeight(float fresnel, float2 uv, float2 center, float lightHeight) {
    if (lightHeight <= 0.0) {
        return fresnel;
    }
    
    // Simulate light positioned above the surface
    float2 dir = uv - center;
    float horizontalDist = length(dir);
    
    // Calculate angle of incidence based on light height
    // Higher light = more even illumination across the surface
    float3 lightDir = normalize(float3(dir, lightHeight));
    float3 surfaceNormal = float3(0.0, 0.0, 1.0);
    float nDotL = max(dot(surfaceNormal, lightDir), 0.0);
    
    // Blend between original fresnel and height-adjusted version
    float heightInfluence = lightHeight / (lightHeight + 1.0);
    return fresnel * mix(1.0, nDotL, heightInfluence * 0.5);
}

// Apply area light softening
float applyAreaLightSize(float fresnel, float areaLightSize) {
    if (areaLightSize <= 0.0) {
        return fresnel;
    }
    
    // Larger area light = softer penumbra transition
    float penumbra = areaLightSize * 0.15;
    return smoothstep(0.0 - penumbra, 0.0 + penumbra, fresnel - 0.5 + penumbra) * 
           smoothstep(1.0 + penumbra, 1.0 - penumbra, fresnel + 0.5 - penumbra);
}

// Calculate radial fresnel from center point
float calculateRadialFresnel(float2 uv, float2 center, float radius, float innerRadius, 
                             float power, float2 resolution, int falloffCurve, 
                             int glowMode, float softness, float areaLightSize, float lightHeight) {
    float aspectRatio = resolution.x / resolution.y;
    float2 adjustedUv = uv * float2(aspectRatio, 1.0);
    float2 adjustedCenter = center * float2(aspectRatio, 1.0);
    
    float dist = distance(adjustedUv, adjustedCenter);
    float normalizedDist = dist / max(radius, 0.001);
    
    float fresnel = 0.0;
    
    if (glowMode == 1) {
        // Inner glow - strongest at edges, fades toward center
        fresnel = normalizedDist;
        fresnel = clamp(fresnel, 0.0, 1.0);
        fresnel = applyFalloffCurve(fresnel, power, falloffCurve, softness);
    } else if (glowMode == 2) {
        // Ring/Border mode - band of light between inner and outer radius
        float adjustedInnerRadius = innerRadius * (radius / max(radius, 0.001));
        float innerNormalizedDist = dist / max(radius, 0.001);
        
        // Create ring mask
        float outerFalloff = 1.0 - smoothstep(1.0 - softness, 1.0, innerNormalizedDist);
        float innerFalloff = smoothstep(adjustedInnerRadius - softness * 0.5, adjustedInnerRadius + softness * 0.5, innerNormalizedDist);
        
        fresnel = outerFalloff * innerFalloff;
        fresnel = applyFalloffCurve(fresnel, power * 0.5, falloffCurve, softness);
    } else {
        // Outer glow (default) - strongest at center, fades outward
        fresnel = 1.0 - normalizedDist;
        fresnel = clamp(fresnel, 0.0, 1.0);
        fresnel = applyFalloffCurve(fresnel, power, falloffCurve, softness);
    }
    
    // Apply light simulation effects
    fresnel = applyAreaLightSize(fresnel, areaLightSize);
    fresnel = applyLightHeight(fresnel, uv, center, lightHeight);
    
    return fresnel;
}

// Calculate edge-based fresnel (stronger at canvas edges)
float calculateEdgeFresnel(float2 uv, float scale, float innerRadius, float power, 
                           int falloffCurve, int glowMode, float softness, 
                           float areaLightSize, float lightHeight) {
    // Distance from edges
    float edgeX = min(uv.x, 1.0 - uv.x);
    float edgeY = min(uv.y, 1.0 - uv.y);
    float edgeDist = min(edgeX, edgeY);
    
    // Normalize by scale
    edgeDist = edgeDist / (scale * 0.5);
    edgeDist = clamp(edgeDist, 0.0, 1.0);
    
    float fresnel = 0.0;
    
    if (glowMode == 1) {
        // Inner glow - stronger toward center
        fresnel = edgeDist;
        fresnel = applyFalloffCurve(fresnel, power, falloffCurve, softness);
    } else if (glowMode == 2) {
        // Ring/Border mode - band at specific distance from edge
        float outerBound = 1.0;
        float innerBound = innerRadius;
        
        float outerFalloff = smoothstep(outerBound, outerBound - softness, edgeDist);
        float innerFalloff = smoothstep(innerBound - softness * 0.5, innerBound + softness * 0.5, edgeDist);
        
        fresnel = outerFalloff * innerFalloff;
        fresnel = applyFalloffCurve(fresnel, power * 0.5, falloffCurve, softness);
    } else {
        // Outer glow (default) - edges are strong
        fresnel = 1.0 - edgeDist;
        fresnel = applyFalloffCurve(fresnel, power, falloffCurve, softness);
    }
    
    // Apply area light softening
    fresnel = applyAreaLightSize(fresnel, areaLightSize);
    
    // For edge mode, apply a simplified height effect based on edge proximity
    if (lightHeight > 0.0) {
        float heightInfluence = lightHeight / (lightHeight + 1.0);
        float edgeAngle = 1.0 - edgeDist;  // Simulate angle at edges
        fresnel *= mix(1.0, 0.5 + edgeAngle * 0.5, heightInfluence * 0.3);
    }
    
    return fresnel;
}

// Calculate directional fresnel (based on angle)
float calculateDirectionalFresnel(float2 uv, float2 center, float angle, float scale, 
                                  float innerRadius, float power, int falloffCurve, 
                                  int glowMode, float softness, float areaLightSize, 
                                  float lightHeight) {
    float2 dir = uv - center;
    
    // Calculate angle from center
    float currentAngle = atan2(dir.y, dir.x);
    
    // Normalize angle difference
    float angleDiff = abs(currentAngle - angle);
    angleDiff = min(angleDiff, 2.0 * M_PI_F - angleDiff); // Handle wrap-around
    
    // Convert to 0-1 range (0 = aligned with angle, 1 = opposite)
    float normalizedAngle = angleDiff / M_PI_F;
    
    // Distance from center
    float dist = length(dir) / (scale * 0.5);
    dist = clamp(dist, 0.0, 1.0);
    
    float fresnel = 0.0;
    
    if (glowMode == 1) {
        // Inner glow - light comes from opposite direction
        float angleComponent = normalizedAngle;
        float distComponent = dist;
        fresnel = angleComponent * distComponent;
        fresnel = applyFalloffCurve(fresnel, power, falloffCurve, softness);
    } else if (glowMode == 2) {
        // Ring/Border mode - band at specific distance in the light direction
        float angleComponent = 1.0 - normalizedAngle;
        
        float outerFalloff = smoothstep(1.0, 1.0 - softness, dist);
        float innerFalloff = smoothstep(innerRadius - softness * 0.5, innerRadius + softness * 0.5, dist);
        
        fresnel = outerFalloff * innerFalloff * angleComponent;
        fresnel = applyFalloffCurve(fresnel, power * 0.5, falloffCurve, softness);
    } else {
        // Outer glow (default) - combine angle and distance
        float angleComponent = 1.0 - normalizedAngle;
        float distComponent = 1.0 - dist;
        fresnel = angleComponent * distComponent;
        fresnel = applyFalloffCurve(fresnel, power, falloffCurve, softness);
    }
    
    // Apply light simulation effects
    fresnel = applyAreaLightSize(fresnel, areaLightSize);
    
    // Apply height effect for directional light
    if (lightHeight > 0.0) {
        float heightInfluence = lightHeight / (lightHeight + 1.0);
        // Higher light softens the directional falloff
        fresnel = mix(fresnel, fresnel * (0.7 + 0.3 * (1.0 - normalizedAngle)), heightInfluence * 0.4);
    }
    
    return fresnel;
}

// Blend modes for fresnel application
float3 applyBlendMode(float3 base, float3 fresnel, float fresnelStrength, int mode) {
    float3 result = base;
    
    if (mode == 0) {
        // Add mode
        result = base + fresnel * fresnelStrength;
    } else if (mode == 1) {
        // Multiply mode
        result = base * mix(float3(1.0), fresnel, fresnelStrength);
    } else if (mode == 2) {
        // Overlay mode
        float3 multiply = base * fresnel * 2.0;
        float3 screen = 1.0 - 2.0 * (1.0 - base) * (1.0 - fresnel);
        float baseLuminance = dot(base, float3(0.333));
        result = mix(multiply, screen, step(0.5, baseLuminance));
        result = mix(base, result, fresnelStrength);
    } else if (mode == 3) {
        // Screen mode
        result = 1.0 - (1.0 - base) * (1.0 - fresnel * fresnelStrength);
    } else if (mode == 4) {
        // Color Dodge mode
        float3 dodge = base / (1.0 - clamp(fresnel * fresnelStrength, 0.0, 0.999));
        result = mix(base, dodge, fresnelStrength);
    } else if (mode == 5) {
        // Linear Burn mode
        float3 burn = base + fresnel * fresnelStrength - float3(1.0);
        result = max(burn, float3(0.0));
    }
    
    return result;
}

fragment float4 fresnel_fragment(EffectVertexOut in [[stage_in]],
                                texture2d<float> inputTexture [[texture(0)]],
                                constant FresnelParams &params [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    // Flip Y coordinate to match UI expectations
    float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    
    // Sample the input texture with chromatic aberration if enabled
    float3 finalColor;
    float alpha;
    
    if (params.chromaticAberration > 0.0) {
        // Calculate offset direction (from center outward)
        float2 center = float2(0.5, 0.5);
        float2 direction = normalize(uv - center);
        float distanceFromCenter = length(uv - center);
        
        // Scale aberration by distance from center (stronger at edges)
        float aberrationScale = distanceFromCenter * params.chromaticAberration * 0.01;
        
        // Sample each channel with offset
        float2 redUV = uv + direction * aberrationScale;
        float2 greenUV = uv;
        float2 blueUV = uv - direction * aberrationScale;
        
        // Sample RGB channels separately
        float r = inputTexture.sample(textureSampler, redUV).r;
        float g = inputTexture.sample(textureSampler, greenUV).g;
        float b = inputTexture.sample(textureSampler, blueUV).b;
        
        finalColor = float3(r, g, b);
        alpha = inputTexture.sample(textureSampler, uv).a;
    } else {
        // No chromatic aberration
        float4 baseTexture = inputTexture.sample(textureSampler, uv);
        finalColor = baseTexture.rgb;
        alpha = baseTexture.a;
    }
    
    // Calculate fresnel based on type
    float fresnelMask = 0.0;
    
    if (params.fresnelType == 0) {
        // Radial fresnel
        fresnelMask = calculateRadialFresnel(uv, params.center, params.radius, params.innerRadius,
                                             params.power, params.resolution, params.falloffCurve,
                                             params.glowMode, params.softness, params.areaLightSize,
                                             params.lightHeight);
    } else if (params.fresnelType == 1) {
        // Edge-based fresnel
        fresnelMask = calculateEdgeFresnel(uv, params.scale, params.innerRadius, params.power,
                                           params.falloffCurve, params.glowMode, params.softness,
                                           params.areaLightSize, params.lightHeight);
    } else {
        // Directional fresnel
        fresnelMask = calculateDirectionalFresnel(uv, params.center, params.angle, params.scale,
                                                  params.innerRadius, params.power, params.falloffCurve,
                                                  params.glowMode, params.softness, params.areaLightSize,
                                                  params.lightHeight);
    }
    
    // Apply invert if needed
    if (params.invert) {
        fresnelMask = 1.0 - fresnelMask;
    }
    
    // Apply intensity (softness is now handled within the calculation functions)
    fresnelMask *= params.intensity;
    
    // Calculate fresnel color (gradient or solid)
    float3 fresnelColor;
    if (params.useGradient) {
        // Create gradient from inner to outer
        float gradientT = pow(fresnelMask, params.gradientPower);
        fresnelColor = mix(params.innerColor, params.outerColor, gradientT);
    } else {
        fresnelColor = params.fresnelColor;
    }
    
    // Apply fresnel effect using blend mode
    float3 effectColor = applyBlendMode(finalColor, fresnelColor, fresnelMask, params.blendMode);
    
    // Blend with original texture based on opacity
    finalColor = mix(finalColor, effectColor, params.opacity);
    
    return float4(finalColor, alpha);
}




// MARK: - Progressive Blur Effect

//
//
//  Progressive directional blur with spatial masking
//


using namespace metal;

// MARK: - Configuration

struct ProgressiveBlurParams {
    float2 center;
    float amount;
    int samples;
    float opacity;
    float rotation;
    float falloffPower;
    float2 resolution;
    int pass;
};

// Pre-computed rotation data
struct BlurRotationData {
    float2x2 rotMatrix;
    float2 transformedCenter;
    float aspectRatio;
};

// MARK: - Blur Constants

// Kernel configuration
constant int kProgressiveBlurKernelSize = 36;
constant int kProgressiveBlurKernelHalf = 18;

// Strength multipliers (tuned for visual quality)
constant float kDirectionalStrength = 5.88;      // Directional pass intensity
constant float kCompositeStrength = 10.78;       // Final composite intensity
constant float kOffsetScale = 0.00102;           // Blur sample spacing
constant float kMinBlurThreshold = 0.00012;      // Skip blur below this

// 36-tap Gaussian kernel weights (sigma ≈ 6.5)
constant float kGaussianKernel[36] = {
    0.00089724, 0.00147893, 0.00231856, 0.00354479, 0.00526318, 0.00756241,
    0.01057834, 0.01437692, 0.01898347, 0.02439518, 0.03047826, 0.03702159,
    0.04374628, 0.05027493, 0.05618724, 0.06107438, 0.06456729, 0.06638841,
    0.06638841, 0.06456729, 0.06107438, 0.05618724, 0.05027493, 0.04374628,
    0.03702159, 0.03047826, 0.02439518, 0.01898347, 0.01437692, 0.01057834,
    0.00756241, 0.00526318, 0.00354479, 0.00231856, 0.00147893, 0.00089724
};

// MARK: - Utility Functions

// Quadratic ease-in-out curve
inline float quadraticEase(float t) {
    float belowMid = step(t, 0.5);
    float rising = 2.0 * t * t;
    float falling = t * (4.0 - 2.0 * t) - 1.0;
    return mix(falling, rising, belowMid);
}

// Dither noise for banding reduction
inline float ditherNoise(float2 coord) {
    return fract(sin(dot(coord, float2(13.0327, 77.928))) * 42192.7129);
}

// Gaussian weight accessor
inline float gaussianWeight(int tap) {
    return kGaussianKernel[tap];
}

// MARK: - Rotation Setup

inline BlurRotationData setupRotation(constant ProgressiveBlurParams &params) {
    BlurRotationData data;
    
    float angle = params.rotation * 2.0 * M_PI_F;
    float s = sin(angle);
    float c = cos(angle);
    data.rotMatrix = transpose(float2x2(c, -s, s, c));
    
    float2 centerFlipped = float2(params.center.x, 1.0 - params.center.y);
    float2 pos = 0.5 + (centerFlipped - 0.5);
    data.transformedCenter = data.rotMatrix * pos;
    data.aspectRatio = params.resolution.x / params.resolution.y;
    
    return data;
}

// MARK: - Directional Blur Pass

float4 applyDirectionalBlur(float2 uv,
                            bool verticalPass,
                            texture2d<float> inputTexture,
                            constant ProgressiveBlurParams &params,
                            BlurRotationData rotData) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    
    float2 rotatedUV = rotData.rotMatrix * uv;
    
    // Calculate directional falloff mask
    float easedDist = quadraticEase(rotData.transformedCenter.y - rotatedUV.y);
    float directionalMask = step(rotatedUV.y, rotData.transformedCenter.y);
    float blurAmount = params.amount * kDirectionalStrength * easedDist * directionalMask;
    
    if (blurAmount < kMinBlurThreshold) {
        return inputTexture.sample(texSampler, uv);
    }
    
    float4 result = inputTexture.sample(texSampler, uv) * gaussianWeight(0);
    
    float2 blurDirection = verticalPass ? float2(0.0, rotData.aspectRatio) : float2(1.0, 0.0);
    float sampleSpacing = blurAmount * kOffsetScale;
    
    for (int i = 1; i < kProgressiveBlurKernelSize; i++) {
        float sampleOffset = float(i - kProgressiveBlurKernelHalf) * sampleSpacing;
        float2 offsetUV = uv + blurDirection * sampleOffset;
        result += inputTexture.sample(texSampler, offsetUV) * gaussianWeight(i);
    }
    
    // Apply dithering
    float2 pixelCoord = uv * params.resolution;
    float dither = (ditherNoise(pixelCoord) - 0.5) / 255.0;
    result.rgb += dither;
    
    return result;
}

// MARK: - Composite Pass

float4 applyComposite(float2 uv,
                      texture2d<float> blurredTexture,
                      texture2d<float> originalTexture,
                      constant ProgressiveBlurParams &params,
                      BlurRotationData rotData) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    
    float4 original = originalTexture.sample(texSampler, uv);
    float4 blurred = blurredTexture.sample(texSampler, uv);
    
    // Dither the blurred result
    float2 pixelCoord = uv * params.resolution;
    float dither = (ditherNoise(pixelCoord) - 0.5) / 255.0;
    blurred.rgb += dither;
    
    float2 rotatedUV = rotData.rotMatrix * uv;
    
    // Calculate blend mask
    float easedDist = quadraticEase(rotData.transformedCenter.y - rotatedUV.y);
    float directionalMask = step(rotatedUV.y, rotData.transformedCenter.y);
    float blendFactor = params.amount * kCompositeStrength * easedDist * directionalMask;
    
    return mix(blurred, original, smoothstep(1.0, 0.0, blendFactor));
}

// MARK: - Fragment Shader

fragment float4 progressive_blur_fragment(EffectVertexOut in [[stage_in]],
                                          texture2d<float> inputTexture [[texture(0)]],
                                          texture2d<float> bgTexture [[texture(1)]],
                                          constant ProgressiveBlurParams &params [[buffer(0)]]) {
    float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    BlurRotationData rotData = setupRotation(params);
    
    if (params.pass == 0) {
        return applyDirectionalBlur(uv, false, inputTexture, params, rotData);
    } else if (params.pass == 1) {
        return applyDirectionalBlur(uv, true, inputTexture, params, rotData);
    } else if (params.pass == 2) {
        return applyDirectionalBlur(uv, false, inputTexture, params, rotData);
    }
    
    return float4(0.0);
}



// MARK: - Skew Effect

//
//
//  3D transform effect: rotates the input content around its centre in 3-space
//  (pitch / yaw / roll) with a perspective divide, then samples with inverse
//  UV mapping.  Nesting this as a child effect on a shape scopes the tilt
//  to just that shape's silhouette.
//
//  Mechanics
//  ---------
//  Conceptually a virtual plane sits at z = 0 in camera space and the input
//  texture paints it.  The plane is rotated by `R = Rx · Ry · Rz` about the
//  pivot, the camera sits at (0, 0, -perspective) looking along +z, and for
//  every output fragment we cast a ray from camera through the fragment,
//  intersect it with the rotated plane, and sample the input at the hit
//  point.  Aspect correction keeps rotations circular on non-square canvases.
//
//  Performance
//  -----------
//  The rotation matrix, plane normal, tan(shear) values and their
//  determinant are all *uniform across the pass* — they depend only on
//  the user-facing params.  Computing them per-fragment meant 8
//  transcendental calls per pixel (6 sin/cos + 2 tan), which added up to
//  ~16M trig ops per effect pass at 1080p and made stacked Skew layers
//  tank to sub-20 FPS.  The CPU-side encoder precomputes all of it into
//  this struct; the shader just reads.  Cost per fragment is now ALU-
//  only (a matrix multiply + ray-plane intersect + shear inverse) plus
//  the texture sample.
//


using namespace metal;

/// GPU-side params for the Skew effect.  Populated in `SkewEffect.encode()`
/// on the CPU from the user-facing `SkewParams` Swift struct.
///
/// Layout matters: must match the Swift `SkewGPUParams` struct bit-for-bit.
/// `float3x3` pads each column to 16 bytes; keep fields grouped to avoid
/// surprise alignment holes.
struct SkewParams {
    // ── Precomputed per-pass uniforms ─────────────────────────────
    float3x3 rotation;       // R = Rx · Ry · Rz (pitch/yaw/roll composed)
    float3   planeNormal;    // third column of `rotation` (R · [0,0,1])
    float    shearTanX;      // tan(skewX)
    float    shearTanY;      // tan(skewY)
    float    shearDet;       // 1 − tanX·tanY — 0 when degenerate (both skews near 45°)
    float    aspect;         // resolution.x / resolution.y, for rotation math
    bool     isIdentity;     // true when all angles+shears are zero → pure passthrough

    // ── User-facing controls (also drive the precomputed fields) ──
    float2   center;         // pivot in UV space
    float    perspective;    // camera distance; small = dramatic foreshortening
    float    opacity;        // 0 = input passes through, 1 = full effect
    bool     hideBackface;   // discard fragments where the plane faces away
};

fragment float4 skew_fragment(EffectVertexOut in [[stage_in]],
                               texture2d<float> inputTexture [[texture(0)]],
                               constant SkewParams &params [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear,
                                     address::clamp_to_edge);

    float2 uv = in.texCoord;

    // Fast pass-through when the effect is an identity transform.  The
    // flag is computed on the CPU from the raw angles so the shader just
    // reads one bool.
    if (params.isIdentity) {
        return inputTexture.sample(textureSampler, uv);
    }

    // CPU already caught the shear-degenerate case (shearDet ≈ 0) and set
    // params appropriately; we still guard here so a near-zero divisor
    // can't blow up arithmetic if floating-point drift occurred.
    if (abs(params.shearDet) < 1e-4) {
        return float4(0.0);
    }

    // Aspect-corrected offset from the pivot.  Plane "lives" in this space
    // so rotations look circular on non-square canvases.
    float2 p = (uv - params.center) * float2(params.aspect, 1.0);

    // Backface hide — precomputed normal lets us short-circuit without any
    // per-fragment matrix work.  (N.z < 0 means the plane's forward face
    // points away from the camera.)
    if (params.hideBackface && params.planeNormal.z < 0.0) {
        return float4(0.0);
    }

    // Camera ray: camera at (0, 0, -persp) looking +z, passing through
    // (p.x, p.y, 0).
    float persp = max(params.perspective, 0.1);
    float3 rayOrigin = float3(0.0, 0.0, -persp);
    float3 rayDir    = float3(p.x, p.y, persp);

    // Ray–plane intersection with plane through origin, normal = planeNormal.
    float denom = dot(params.planeNormal, rayDir);
    if (abs(denom) < 1e-5) {
        return float4(0.0);  // ray grazes plane
    }
    float t = -dot(params.planeNormal, rayOrigin) / denom;
    if (t < 0.0) {
        return float4(0.0);  // hit is behind camera
    }
    float3 hit = rayOrigin + t * rayDir;

    // Inverse rotation (transpose, since rotations are orthonormal).
    float2 sheared = (transpose(params.rotation) * hit).xy;

    // Inverse 2D shear.  Forward shear S = |1  a; b  1| with a = tanX, b = tanY.
    // Inverse S⁻¹ = (1/det) · | 1  -a; -b  1|.  det precomputed on CPU.
    float2 unsheared = float2(sheared.x - params.shearTanX * sheared.y,
                               sheared.y - params.shearTanY * sheared.x) / params.shearDet;

    // Back to UV space.
    float2 uvIn = unsheared / float2(params.aspect, 1.0) + params.center;

    if (any(uvIn < 0.0) || any(uvIn > 1.0)) {
        return float4(0.0);
    }

    float4 sampled = inputTexture.sample(textureSampler, uvIn);

    if (params.opacity >= 0.999) return sampled;
    float4 passthrough = inputTexture.sample(textureSampler, uv);
    return mix(passthrough, sampled, params.opacity);
}



// MARK: - Water Effect

//
//
//  Water-surface distortion with animated caustic realism — refracts the
//  layer below through layered caustic noise + simplex waves, with an
//  optional caustic-shaped highlight tint.
//
//  Ported from paper-design/shaders (Apache-2.0), `water.ts`:
//  https://github.com/paper-design/shaders
//  The "image" is our input texture (the layer below) filling the canvas.
//  Helpers are `water_`-prefixed (shared metallib — the un-prefixed
//  snoise/permute would collide with other noise effects).
//


using namespace metal;

struct WaterParams {
    float2 resolution;
    float  time;       // seconds since effect started
    float  speed;      // animation speed multiplier
    float  size;       // pattern scale (0.01..7)
    float  highlights; // caustic-shaped highlight tint (0..1)
    float  layering;   // strength of the 2nd caustic layer (0..1)
    float  edges;      // caustic distortion on the image edges (0..1)
    float  caustic;    // caustic distortion power (0..1)
    float  waves;      // simplex-wave distortion (0..1)
    float  opacity;    // 0 = pass-through, 1 = full effect
    float4 colorBack;
    float4 colorHighlight;
};

// GLSL-style mod (sign-correct) for the simplex lattice math.
static inline float2 water_mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static inline float3 water_mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static inline float3 water_permute(float3 x) { return water_mod289(((x * 34.0) + 1.0) * x); }

static inline float water_snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439,
                            -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = water_mod289(i);
    float3 p = water_permute(water_permute(i.y + float3(0.0, i1.y, 1.0))
                             + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy),
                                dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

static inline float water_uvFrame(float2 uv) {
    float aax = 2.0 * fwidth(uv.x);
    float aay = 2.0 * fwidth(uv.y);
    float left   = smoothstep(0.0, aax, uv.x);
    float right  = 1.0 - smoothstep(1.0 - aax, 1.0, uv.x);
    float bottom = smoothstep(0.0, aay, uv.y);
    float top    = 1.0 - smoothstep(1.0 - aay, 1.0, uv.y);
    return left * right * bottom * top;
}

static inline float2x2 water_rotate2D(float r) {
    return float2x2(float2(cos(r), sin(r)), float2(-sin(r), cos(r)));
}

// Layered rotating trig noise — the caustic web.
static inline float water_causticNoise(float2 uv, float t, float scale) {
    float2 n = float2(0.1);
    float2 N = float2(0.1);
    float2x2 m = water_rotate2D(0.5);
    for (int j = 0; j < 6; j++) {
        uv = uv * m;
        n = n * m;
        float2 q = uv * scale + float(j) + n
                 + (0.5 + 0.5 * float(j)) * (fmod(float(j), 2.0) - 1.0) * t;
        n += sin(q);
        N += cos(q) / scale;
        scale *= 1.1;
    }
    return (N.x + N.y + 1.0);
}

fragment float4 water_fragment(EffectVertexOut in [[stage_in]],
                               texture2d<float> inputTexture [[texture(0)]],
                               constant WaterParams &params [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);

    float2 baseUV = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    float  aspect = params.resolution.x / max(params.resolution.y, 1.0);
    float4 originalInput = inputTexture.sample(s, baseUV);

    float2 imageUV = baseUV;
    float2 patternUV = baseUV - 0.5;
    patternUV = (patternUV * float2(aspect, 1.0));
    patternUV /= (0.01 + 0.09 * params.size);

    float t = params.time * params.speed;

    float wavesNoise = water_snoise((0.3 + 0.1 * sin(t)) * 0.1 * patternUV + float2(0.0, 0.4 * t));

    float causticNoise = water_causticNoise(patternUV + params.waves * float2(1.0, -1.0) * wavesNoise, 2.0 * t, 1.5);
    causticNoise += params.layering * water_causticNoise(patternUV + 2.0 * params.waves * float2(1.0, -1.0) * wavesNoise, 1.5 * t, 2.0);
    causticNoise = causticNoise * causticNoise;

    float edgesDistortion = smoothstep(0.0, 0.1, imageUV.x);
    edgesDistortion *= smoothstep(0.0, 0.1, imageUV.y);
    edgesDistortion *= (smoothstep(1.0, 1.1, imageUV.x) + (1.0 - smoothstep(0.8, 0.95, imageUV.x)));
    edgesDistortion *= (1.0 - smoothstep(0.9, 1.0, imageUV.y));
    edgesDistortion = mix(edgesDistortion, 1.0, params.edges);

    float causticNoiseDistortion = 0.02 * causticNoise * edgesDistortion;
    float wavesDistortion = 0.1 * params.waves * wavesNoise;

    imageUV += float2(wavesDistortion, -wavesDistortion);
    imageUV += (params.caustic * causticNoiseDistortion);

    float frame = water_uvFrame(imageUV);

    float4 image = inputTexture.sample(s, imageUV);
    float4 backColor = params.colorBack;
    backColor.rgb *= backColor.a;

    float3 color = mix(backColor.rgb, image.rgb, image.a * frame);
    float opacity = backColor.a + image.a * frame;

    causticNoise = max(-0.2, causticNoise);

    float highlight = 0.025 * params.highlights * causticNoise;
    highlight *= params.colorHighlight.a;
    color = mix(color, params.colorHighlight.rgb, 0.05 * params.highlights * causticNoise);
    opacity += highlight;

    color += highlight * (0.5 + 0.5 * wavesNoise);
    opacity += highlight * (0.5 + 0.5 * wavesNoise);

    opacity = clamp(opacity, 0.0, 1.0);

    // Composite over the layer below (transparent back shows through),
    // then fade the whole effect back to the input by layer opacity.
    float3 comp = color + originalInput.rgb * (1.0 - opacity);
    float  compA = opacity + originalInput.a * (1.0 - opacity);
    float3 outRGB = mix(originalInput.rgb, comp, params.opacity);
    float  outA   = mix(originalInput.a, compA, params.opacity);
    return float4(clamp(outRGB, 0.0, 1.0), outA);
}




// MARK: - Vertex Shader

vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
    const float2 positions[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
    };
    
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = positions[vertexID] * 0.5 + 0.5;
    return out;
}

// MARK: - Rotation helper
//
// Inlined from the editor's Shaders.metal so the export
// doesn't depend on it.  Rotation is applied in
// aspect-corrected space so circles stay circles at any angle.
static float2 rotateUVAroundCenter(float2 uv, float2 center, float angle, float aspect) {
    if (angle == 0.0) return uv;
    float2 p = (uv - center) * float2(aspect, 1.0);
    float c = cos(angle), s = sin(angle);
    float2 pRot = float2(c * p.x - s * p.y, s * p.x + c * p.y);
    return center + pRot / float2(aspect, 1.0);
}


// MARK: - Layer Fragment Shader

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              constant float2 &resolution [[buffer(0)]],
                              constant LayerProperties *layers [[buffer(1)]],
                              constant int &layerCount [[buffer(2)]]) {
    float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    float aspect = resolution.x / resolution.y;

    float3 finalColor = float3(0.0);
    float totalAlpha = 0.0;

    for (int i = 0; i < layerCount; i++) {
        LayerProperties layer = layers[i];

        // Layer-local UV (rotation is applied about the layer centre).
        float2 layerUV = rotateUVAroundCenter(uv, layer.center, layer.rotation, aspect);

        float shapeMask = calculateShapeMask(layerUV, layer.center, layer.shape, layer.radius,
                                             layer.width, layer.height, aspect, layer.softness,
                                             layer.squircleRadius, resolution);

        // Solid colour fill; fillOpacity dims the fill and layer
        // opacity is applied at composite time.
        float4 layerColor = layer.color;
        float4 shapeColorWithAlpha = float4(layerColor.rgb,
                                           layerColor.a * shapeMask * layer.fillOpacity);

        // Composite this layer's premultiplied output over the
        // accumulated background.
        float finalMask = shapeColorWithAlpha.a * layer.opacity;
        float3 sourceColor = shapeColorWithAlpha.rgb * finalMask;
        finalColor = sourceColor + finalColor * (1.0 - finalMask);
        totalAlpha = finalMask + totalAlpha * (1.0 - finalMask);
    }

    return float4(finalColor, totalAlpha);
}
// MARK: - Effect Vertex Shader

vertex EffectVertexOut effect_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
        float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
    };
    
    EffectVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = positions[vertexID] * 0.5 + 0.5;
    return out;
}

// MARK: - Passthrough Shader (for copying final texture to screen)

fragment float4 passthrough_fragment(EffectVertexOut in [[stage_in]],
                                      texture2d<float> inputTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    // No Y-flip needed - ping-pong textures are already in correct coordinate space
    return inputTexture.sample(textureSampler, in.texCoord);
}
