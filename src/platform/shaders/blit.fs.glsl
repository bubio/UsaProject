#version 450
precision mediump float;
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
in vec2 uv;
out vec4 frag_color;
void main() {
  frag_color = texture(sampler2D(tex, smp), uv);
}
