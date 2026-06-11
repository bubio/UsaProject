#version 330
// App-layer HSV-smooth filter (replaces NP2kai's core videofilter). For each
// output texel it averages the 3x3 neighbourhood in HSV space, keeping only
// neighbours within a hue/saturation/value tolerance of the centre — a faithful
// GPU port of VideoFilter_HSVSmooth (preset radius=15 -> 3x3, dH=30, dS=30,
// dV=90, weight type 0). Running it on the GPU keeps the emulator core
// unmodified and is effectively free versus the CPU implementation.
uniform sampler2D tex_smp;
in vec2 uv;
out vec4 frag_color;

const float dHtol = 30.0;
const float dStol = 30.0 / 255.0;
const float dVtol = 90.0 / 255.0;

// H in [0,360), S and V in [0,1].
vec3 rgb2hsv(vec3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float d = mx - mn;
    float h = 0.0;
    if (d > 0.0) {
        if (mx == c.r) h = mod((c.g - c.b) / d, 6.0);
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else h = (c.r - c.g) / d + 4.0;
        h *= 60.0;
        if (h < 0.0) h += 360.0;
    }
    float s = (mx <= 0.0) ? 0.0 : d / mx;
    return vec3(h, s, mx);
}

vec3 hsv2rgb(vec3 c) {
    float h = c.x, s = c.y, v = c.z;
    float cc = v * s;
    float x = cc * (1.0 - abs(mod(h / 60.0, 2.0) - 1.0));
    float m = v - cc;
    vec3 rgb;
    if (h < 60.0) rgb = vec3(cc, x, 0.0);
    else if (h < 120.0) rgb = vec3(x, cc, 0.0);
    else if (h < 180.0) rgb = vec3(0.0, cc, x);
    else if (h < 240.0) rgb = vec3(0.0, x, cc);
    else if (h < 300.0) rgb = vec3(x, 0.0, cc);
    else rgb = vec3(cc, 0.0, x);
    return rgb + m;
}

void main() {
    vec2 texel = 1.0 / vec2(textureSize(tex_smp, 0));
    vec3 C = rgb2hsv(texture(tex_smp, uv).rgb);
    float sumH = 0.0, sumS = 0.0, sumV = 0.0, count = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            vec3 D = rgb2hsv(texture(tex_smp, uv + vec2(float(dx), float(dy)) * texel).rgb);
            float dH = D.x - C.x;
            if (dH > 180.0) dH -= 360.0;
            else if (dH < -180.0) dH += 360.0;
            if (D.y <= 0.0) dH = 0.0;
            float dS = D.y - C.y;
            float dV = D.z - C.z;
            bool ok = true;
            if (D.z > 0.0 && abs(dH) > dHtol) ok = false;
            if (D.z > 0.0 && abs(dS) > dStol) ok = false;
            if (abs(dV) > dVtol) ok = false;
            if (ok) {
                sumH += C.x + dH;
                sumS += C.y + dS;
                sumV += C.z + dV;
                count += 1.0;
            }
        }
    }
    float H = mod(sumH / count, 360.0);
    if (H < 0.0) H += 360.0;
    frag_color = vec4(hsv2rgb(vec3(H, sumS / count, sumV / count)), 1.0);
}
