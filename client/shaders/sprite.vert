#version 450

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

layout(push_constant) uniform PC {
    vec2 screen;
    vec2 view_scale;
    vec2 view_offset;
} pc;

void main() {
    vec2 screen_pos = in_pos * pc.view_scale + pc.view_offset;
    vec2 ndc = (screen_pos / pc.screen) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = in_uv;
    v_color = in_color;
}
