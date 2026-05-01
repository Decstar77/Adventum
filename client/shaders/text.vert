#version 450

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;

layout(location = 0) out vec2 v_uv;

layout(push_constant) uniform PC {
    vec2 screen;
    vec4 color;
} pc;

void main() {
    vec2 ndc = (in_pos / pc.screen) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = in_uv;
}
