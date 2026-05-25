struct vs_in {
  float4 position : POSITION;
  float2 texcoord0 : TEXCOORD0;
};
struct vs_out {
  float2 uv : TEXCOORD0;
  float4 position : SV_Position;
};
vs_out main(vs_in inp) {
  vs_out outp;
  outp.position = inp.position;
  outp.uv = inp.texcoord0;
  return outp;
}
