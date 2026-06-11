// App-layer HSV-smooth filter (replaces NP2kai's core videofilter). See
// blit_hsv.fs.glsl for the algorithm notes; this is the D3D11/HLSL port.
Texture2D<float4> tex : register(t0);
SamplerState smp : register(s0);
struct fs_in {
  float2 uv : TEXCOORD0;
};

static const float dHtol = 30.0;
static const float dStol = 30.0 / 255.0;
static const float dVtol = 90.0 / 255.0;

// H in [0,360), S and V in [0,1].
float3 rgb2hsv(float3 c) {
  float mx = max(c.r, max(c.g, c.b));
  float mn = min(c.r, min(c.g, c.b));
  float d = mx - mn;
  float h = 0.0;
  if (d > 0.0) {
    if (mx == c.r) h = fmod((c.g - c.b) / d, 6.0);
    else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
    else h = (c.r - c.g) / d + 4.0;
    h *= 60.0;
    if (h < 0.0) h += 360.0;
  }
  float s = (mx <= 0.0) ? 0.0 : d / mx;
  return float3(h, s, mx);
}

float3 hsv2rgb(float3 c) {
  float h = c.x, s = c.y, v = c.z;
  float cc = v * s;
  float x = cc * (1.0 - abs(fmod(h / 60.0, 2.0) - 1.0));
  float m = v - cc;
  float3 rgb;
  if (h < 60.0) rgb = float3(cc, x, 0.0);
  else if (h < 120.0) rgb = float3(x, cc, 0.0);
  else if (h < 180.0) rgb = float3(0.0, cc, x);
  else if (h < 240.0) rgb = float3(0.0, x, cc);
  else if (h < 300.0) rgb = float3(x, 0.0, cc);
  else rgb = float3(cc, 0.0, x);
  return rgb + m;
}

float4 main(fs_in inp) : SV_Target0 {
  float tw, th;
  tex.GetDimensions(tw, th);
  float2 texel = float2(1.0 / tw, 1.0 / th);
  float3 C = rgb2hsv(tex.Sample(smp, inp.uv).rgb);
  float sumH = 0.0, sumS = 0.0, sumV = 0.0, count = 0.0;
  [unroll] for (int dy = -1; dy <= 1; dy++) {
    [unroll] for (int dx = -1; dx <= 1; dx++) {
      float3 D = rgb2hsv(tex.Sample(smp, inp.uv + float2(dx, dy) * texel).rgb);
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
  float H = fmod(sumH / count, 360.0);
  if (H < 0.0) H += 360.0;
  return float4(hsv2rgb(float3(H, sumS / count, sumV / count)), 1.0);
}
