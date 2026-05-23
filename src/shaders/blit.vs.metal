#include <metal_stdlib>
using namespace metal;
struct vs_in {
  float4 position [[attribute(0)]];
  float2 texcoord0 [[attribute(1)]];
};
struct vs_out {
  float4 position [[position]];
  float2 uv;
};
vertex vs_out _main(vs_in in [[stage_in]]) {
  vs_out out;
  out.position = in.position;
  out.uv = in.texcoord0;
  return out;
}
