#version 450
layout(location=0) in vec4 position;
layout(location=1) in vec2 texcoord0;
out vec2 uv;
void main() {
  gl_Position = position;
  uv = texcoord0;
}
