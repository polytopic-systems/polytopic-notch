// The notch light picker's shaders (NotchLightMetal.swift). Shipped as a copied resource, not compiled by the build:
// NotchLightMetal reads this file from Bundle.module and compiles it at first use (MTLDevice.makeLibrary(source:)), so
// building the package needs no Metal toolchain. One full-screen triangle; the fragment shader draws the glowing bar,
// the spectrum rail with its notch marker, or a row of LEDs, by `mode`.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 size; float scale; float mode;
    float4 color;
    float hue; float level; float glow; float count;
    float lit; float ledKind; float saturation; float focused;
};

struct VOut { float4 position [[position]]; };

// 0 at the view's edges, 1 from `reach` inside them: glows fade out before the view clips them.
float edgeFade(float2 p, float2 size, float reach) {
    float2 q = min(p, size - p);
    return smoothstep(0.0, reach, q.x) * smoothstep(0.0, reach, q.y);
}

vertex VOut notchLightVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// Same formula as NotchRGB(hue:saturation:brightness:).
float3 hsb(float h, float s, float v) {
    float3 n = float3(5.0, 3.0, 1.0);
    float3 k = fmod(n + h / 60.0, 6.0);
    return v - v * s * max(0.0, min(min(k, 4.0 - k), 1.0));
}

// Distance to a capsule from a to b with radius r.
float capsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a, ba = b - a;
    float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * t) - r;
}

// Distance to a box centred at c with half size h and corner radius r.
float box(float2 p, float2 c, float2 h, float r) {
    float2 q = abs(p - c) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// The notch marker: square top, rounded bottom corners.
float notch(float2 p, float cx, float halfWidth, float top, float bottom, float r) {
    float2 c = float2(cx, (top + bottom) * 0.5);
    float2 h = float2(halfWidth, (bottom - top) * 0.5);
    float rounded = box(p, c, h, r);
    float square = box(p, c - float2(0.0, h.y * 0.5), float2(h.x, h.y * 0.5), 0.0);
    return min(rounded, square);
}

float3 bar(float2 p, constant Uniforms& u) {
    float s = u.scale;
    float2 c = u.size * 0.5;
    float halfLen = u.size.x * (0.4 + 0.34 * u.level) * 0.5 - 4.0 * s;
    float d = capsule(p, c - float2(halfLen, 0.0), c + float2(halfLen, 0.0), 4.0 * s);
    float3 light = u.color.rgb;
    float along = 1.0 - abs(p.x - c.x) / max(halfLen + 4.0 * s, 1.0);
    float core = 1.0 - smoothstep(-0.75, 0.75, d);
    // The tube is the brightest thing: full colour along most of it, running toward white in the middle like
    // an LED tube, dimming a little at the ends.
    float3 body = light * mix(0.9, 1.0, smoothstep(0.0, 0.5, along));
    float hot = smoothstep(0.0, 1.0, -d / (4.0 * s)) * 0.55 * smoothstep(0.1, 0.7, along);
    body = mix(body, float3(1.0), hot);
    float sigma = (3.0 + 8.0 * u.glow) * s;
    float bloom = exp(-max(d, 0.0) / sigma) * (0.3 + 0.4 * u.glow);
    float halo = exp(-max(d, 0.0) / (sigma * 2.5)) * 0.22 * u.glow;
    float fade = edgeFade(p, u.size, 18.0 * s);
    // max, not a sum: the glow meets the tube's edge without a seam.
    return max(body * core, light * (bloom + halo) * fade);
}

float3 rail(float2 p, constant Uniforms& u) {
    float s = u.scale;
    float2 size = u.size;
    float3 out = float3(0.0);
    // The spectrum, with a faint top sheen.
    float top = size.y - 18.0 * s;
    float d = box(p, float2(size.x * 0.5, top + 4.0 * s), float2(size.x * 0.5, 4.0 * s), 4.0 * s);
    float inRail = 1.0 - smoothstep(-0.75, 0.75, d);
    float3 spectrum = hsb(clamp(p.x / size.x, 0.0, 1.0) * 360.0, 1.0, 1.0);
    float sheen = 1.0 + 0.25 * (1.0 - smoothstep(0.0, 3.0 * s, p.y - top));
    out = mix(out, spectrum * sheen, inRail);

    float x = clamp(u.hue / 360.0 * size.x, 21.0 * s, size.x - 21.0 * s);
    // Stem from the marker down to the rail.
    float stem = 1.0 - smoothstep(-0.5, 0.5, box(p, float2(x, (23.0 * s + top + 4.0 * s) * 0.5), float2(0.75 * s, (top + 4.0 * s - 23.0 * s) * 0.5), 0.0));
    out = mix(out, float3(1.0), stem);
    // The notch: outline, black inside, the light's line glowing in it.
    float outer = notch(p, x, 20.0 * s, 2.0 * s, 23.0 * s, 6.0 * s);
    float inner = notch(p, x, 18.5 * s, 2.0 * s, 21.5 * s, 4.5 * s);
    float3 rim = mix(float3(0.85), float3(1.0), u.focused);
    out = mix(out, rim, 1.0 - smoothstep(-0.75, 0.75, outer));
    out = mix(out, float3(0.0), 1.0 - smoothstep(-0.75, 0.75, inner));
    float line = capsule(p, float2(x - 6.75 * s, 16.25 * s), float2(x + 6.75 * s, 16.25 * s), 1.25 * s);
    float lineCore = 1.0 - smoothstep(-0.6, 0.6, line);
    float lineGlow = exp(-max(line, 0.0) / (3.0 * s)) * 0.7 * step(inner, 0.0);
    out += u.color.rgb * lineGlow * (1.0 - lineCore);
    out = mix(out, u.color.rgb, lineCore);
    return out;
}

float3 leds(float2 p, constant Uniforms& u) {
    float s = u.scale;
    float gap = 4.0 * s;
    float w = (u.size.x - gap * (u.count - 1.0)) / u.count;
    float r = min(w, u.size.y) * 0.5;
    float3 out = float3(0.0);
    int first = max(0, int(floor((p.x - 8.0 * s) / (w + gap))));
    int last = min(int(u.count) - 1, int(floor((p.x + 8.0 * s) / (w + gap))));
    for (int i = first; i <= last; i++) {
        float n = float(i + 1);
        float3 c = u.ledKind < 0.5 ? hsb(u.hue, u.saturation, 0.2 + 0.8 * n / u.count)
                                   : hsb(u.hue, 1.0 - n / u.count, 1.0);
        bool on = n <= u.lit;
        float3 off = u.ledKind < 0.5 ? c * 0.12 : float3(0.08);
        float cx = float(i) * (w + gap) + w * 0.5;
        float2 a = float2(cx - max(w * 0.5 - r, 0.0), u.size.y * 0.5);
        float2 b = float2(cx + max(w * 0.5 - r, 0.0), u.size.y * 0.5);
        float d = capsule(p, a, b, r - 1.0 * s);
        float inside = 1.0 - smoothstep(-0.75, 0.75, d);
        // A lens highlight on the upper half of a lit LED.
        float lens = on ? (1.0 - smoothstep(0.0, r, p.y - (u.size.y * 0.5 - r * 0.6))) * 0.25 : 0.0;
        float3 face = on ? mix(c, float3(1.0), lens * inside) : off;
        out = mix(out, face, inside);
        if (on) { out += c * exp(-max(d, 0.0) / (2.0 * s)) * 0.45 * (1.0 - inside) * edgeFade(p, u.size, 3.0 * s); }
    }
    return out;
}

fragment float4 notchLightFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = in.position.xy;
    float3 c = u.mode < 0.5 ? bar(p, u) : (u.mode < 1.5 ? rail(p, u) : leds(p, u));
    return float4(min(c, 1.0), 1.0);
}
