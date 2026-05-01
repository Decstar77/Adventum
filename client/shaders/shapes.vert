#version 450

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_local;
layout(location = 2) in vec2 in_params;
layout(location = 3) in vec4 in_color;
layout(location = 4) in float in_type;

layout(location = 0) out vec2 v_local;
layout(location = 1) out vec2 v_params;
layout(location = 2) out vec4 v_color;
layout(location = 3) flat out float v_type;

layout(push_constant) uniform PC {
    vec2 screen;
} pc;

void main() {
    vec2 ndc = (in_pos / pc.screen) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_local  = in_local;
    v_params = in_params;
    v_color  = in_color;
    v_type   = in_type;
}
