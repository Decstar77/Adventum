#version 450

layout(location = 0) in vec2 v_local;
layout(location = 1) in vec2 v_params;
layout(location = 2) in vec4 v_color;
layout(location = 3) flat in float v_type;

layout(location = 0) out vec4 out_color;

float sdf_box(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdf_circle(vec2 p, float r) {
    return length(p) - r;
}

float sdf_capsule(vec2 p, float half_len, float r) {
    p.x = max(abs(p.x) - half_len, 0.0);
    return length(p) - r;
}

void main() {
    float d;
    if (v_type < 0.5) {
        d = sdf_box(v_local, v_params);
    } else if (v_type < 1.5) {
        d = sdf_circle(v_local, v_params.x);
    } else {
        d = sdf_capsule(v_local, v_params.x, v_params.y);
    }

    float aa = fwidth(d) * 0.5;
    float a  = 1.0 - smoothstep(-aa, aa, d);
    if (a <= 0.0) discard;
    out_color = vec4(v_color.rgb, v_color.a * a);
}
