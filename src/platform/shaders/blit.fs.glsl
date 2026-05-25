#version 330
uniform sampler2D tex_smp;
in vec2 uv;
out vec4 frag_color;
void main() {
  frag_color = texture(tex_smp, uv);
}
