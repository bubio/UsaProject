Texture2D<float4> tex : register(t0);
SamplerState smp : register(s0);
struct fs_in {
  float2 uv : TEXCOORD0;
};
float4 main(fs_in inp) : SV_Target0 {
  return tex.Sample(smp, inp.uv);
}
