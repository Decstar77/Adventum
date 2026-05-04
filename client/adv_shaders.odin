package main

import sg "sokol/gfx"

// All shaders are GLSL only. We provide GLCORE (#version 410) and GLES3 (#version 300 es)
// variants for desktop GL and the WebGL2 / wasm backends; bodies are kept identical.
// Sokol's GL backend does not use UBOs — uniform blocks are flattened to individual
// uniforms set via glUniformXXX, described via Glsl_Shader_Uniform on the Shader_Desc.

select_shader_source :: proc(glcore, gles3: cstring) -> cstring {
	if sg.query_backend() == .GLES3 do return gles3
	return glcore
}

// ---------- shapes ----------

SHAPES_VS_GLCORE :: cstring(
`#version 410 core
in vec2  in_pos;
in vec2  in_local;
in vec2  in_params;
in vec4  in_color;
in float in_type;

out vec2  v_local;
out vec2  v_params;
out vec4  v_color;
flat out float v_type;

uniform vec2 screen;
uniform vec2 view_scale;
uniform vec2 view_offset;

void main() {
    vec2 screen_pos = in_pos * view_scale + view_offset;
    vec2 ndc = (screen_pos / screen) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_local  = in_local;
    v_params = in_params;
    v_color  = in_color;
    v_type   = in_type;
}
`)

SHAPES_FS_GLCORE :: cstring(
`#version 410 core
in vec2  v_local;
in vec2  v_params;
in vec4  v_color;
flat in float v_type;

out vec4 frag_color;

float sdf_box(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
float sdf_circle(vec2 p, float r) { return length(p) - r; }
float sdf_capsule(vec2 p, float half_len, float r) {
    p.x = max(abs(p.x) - half_len, 0.0);
    return length(p) - r;
}

void main() {
    float d;
    if (v_type < 0.5)        d = sdf_box(v_local, v_params);
    else if (v_type < 1.5)   d = sdf_circle(v_local, v_params.x);
    else                     d = sdf_capsule(v_local, v_params.x, v_params.y);

    float aa = fwidth(d) * 0.5;
    float a  = 1.0 - smoothstep(-aa, aa, d);
    if (a <= 0.0) discard;
    frag_color = vec4(v_color.rgb, v_color.a * a);
}
`)

SHAPES_VS_GLES3 :: cstring(
`#version 300 es
precision highp float;
in vec2  in_pos;
in vec2  in_local;
in vec2  in_params;
in vec4  in_color;
in float in_type;

out vec2  v_local;
out vec2  v_params;
out vec4  v_color;
flat out float v_type;

uniform vec2 screen;
uniform vec2 view_scale;
uniform vec2 view_offset;

void main() {
    vec2 screen_pos = in_pos * view_scale + view_offset;
    vec2 ndc = (screen_pos / screen) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_local  = in_local;
    v_params = in_params;
    v_color  = in_color;
    v_type   = in_type;
}
`)

SHAPES_FS_GLES3 :: cstring(
`#version 300 es
precision highp float;
in vec2  v_local;
in vec2  v_params;
in vec4  v_color;
flat in float v_type;

out vec4 frag_color;

float sdf_box(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
float sdf_circle(vec2 p, float r) { return length(p) - r; }
float sdf_capsule(vec2 p, float half_len, float r) {
    p.x = max(abs(p.x) - half_len, 0.0);
    return length(p) - r;
}

void main() {
    float d;
    if (v_type < 0.5)        d = sdf_box(v_local, v_params);
    else if (v_type < 1.5)   d = sdf_circle(v_local, v_params.x);
    else                     d = sdf_capsule(v_local, v_params.x, v_params.y);

    float aa = fwidth(d) * 0.5;
    float a  = 1.0 - smoothstep(-aa, aa, d);
    if (a <= 0.0) discard;
    frag_color = vec4(v_color.rgb, v_color.a * a);
}
`)

// ---------- text ----------

TEXT_VS_GLCORE :: cstring(
`#version 410 core
in vec2 in_pos;
in vec2 in_uv;
in vec4 in_color;

out vec2 v_uv;
out vec4 v_color;

uniform vec2 screen;

void main() {
    vec2 ndc = (in_pos / screen) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = in_uv;
    v_color = in_color;
}
`)

TEXT_FS_GLCORE :: cstring(
`#version 410 core
in vec2 v_uv;
in vec4 v_color;
out vec4 frag_color;
uniform sampler2D u_atlas;
void main() {
    float a = texture(u_atlas, v_uv).r;
    frag_color = vec4(v_color.rgb, v_color.a * a);
}
`)

TEXT_VS_GLES3 :: cstring(
`#version 300 es
precision highp float;
in vec2 in_pos;
in vec2 in_uv;
in vec4 in_color;

out vec2 v_uv;
out vec4 v_color;

uniform vec2 screen;

void main() {
    vec2 ndc = (in_pos / screen) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = in_uv;
    v_color = in_color;
}
`)

TEXT_FS_GLES3 :: cstring(
`#version 300 es
precision mediump float;
in vec2 v_uv;
in vec4 v_color;
out vec4 frag_color;
uniform sampler2D u_atlas;
void main() {
    float a = texture(u_atlas, v_uv).r;
    frag_color = vec4(v_color.rgb, v_color.a * a);
}
`)

// ---------- background ----------
// Fullscreen triangle synthesised from gl_VertexID. No vertex buffer required.

BG_VS_GLCORE :: cstring(
`#version 410 core
out vec2 v_uv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    v_uv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
`)

BG_FS_GLCORE :: cstring(
`#version 410 core
in  vec2 v_uv;
out vec4 frag_color;

uniform vec2  screen;
uniform vec2  view_scale;
uniform vec2  view_offset;
uniform float time;

void main() {
    vec2 frag    = gl_FragCoord.xy;
    vec2 uv      = frag / screen;
    float aspect = screen.x / screen.y;
    float t      = time;

    vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
    float vign = smoothstep(0.0, 1.05, length(c));
    vec3 base = mix(vec3(0.045, 0.115, 0.135),
                    vec3(0.005, 0.020, 0.030), vign);
    base += vec3(0.0, 0.006, 0.010) *
            (0.5 + 0.5 * sin(t * 0.18 + uv.y * 2.6 + uv.x * 1.3));

    frag_color = vec4(base, 1.0);
}
`)

BG_VS_GLES3 :: cstring(
`#version 300 es
precision highp float;
out vec2 v_uv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    v_uv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
`)

BG_FS_GLES3 :: cstring(
`#version 300 es
precision highp float;
in  vec2 v_uv;
out vec4 frag_color;

uniform vec2  screen;
uniform vec2  view_scale;
uniform vec2  view_offset;
uniform float time;

void main() {
    vec2 frag    = gl_FragCoord.xy;
    vec2 uv      = frag / screen;
    float aspect = screen.x / screen.y;
    float t      = time;

    vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
    float vign = smoothstep(0.0, 1.05, length(c));
    vec3 base = mix(vec3(0.045, 0.115, 0.135),
                    vec3(0.005, 0.020, 0.030), vign);
    base += vec3(0.0, 0.006, 0.010) *
            (0.5 + 0.5 * sin(t * 0.18 + uv.y * 2.6 + uv.x * 1.3));

    frag_color = vec4(base, 1.0);
}
`)
