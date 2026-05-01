#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_atlas;

layout(push_constant) uniform PC {
    vec2 screen;
    vec4 color;
} pc;

void main() {
    float a = texture(u_atlas, v_uv).r;
    out_color = vec4(pc.color.rgb, pc.color.a * a);
}
