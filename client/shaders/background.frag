#version 450

layout(location = 0) out vec4 out_color;

#define MAX_FOG_LIGHTS 256

layout(push_constant) uniform PC {
    vec2  screen;
    vec2  view_scale;   // world->screen (camera zoom)
    vec2  view_offset;  // world->screen translation
    float time;
    int   light_count;
    float light_radius;   // world-space radius of full visibility around each light
    float light_falloff;  // additional world-space soft falloff distance
} pc;

// Each light stores its world-space xy in .xy. zw are reserved (radius/intensity later).
layout(set = 0, binding = 0) uniform Lights {
    vec4 pos[MAX_FOG_LIGHTS];
} lights;

void main() {
    vec2 frag    = gl_FragCoord.xy;
    vec2 uv      = frag / pc.screen;
    float t      = pc.time;

    // Lit base: a slow drift on the same dark teal we used to vignette toward.
    vec3 lit  = vec3(0.045, 0.115, 0.135);
    lit += vec3(0.0, 0.006, 0.010) *
           (0.5 + 0.5 * sin(t * 0.18 + uv.y * 2.6 + uv.x * 1.3));
    vec3 dark = vec3(0.003, 0.008, 0.012);

    // Reverse the camera affine (matches the world-space transform applied to
    // shapes): world = (frag - offset) / scale. So when the camera pans, the
    // glow stays anchored to its world-space anchor.
    vec2 world = (frag - pc.view_offset) / pc.view_scale;

    // Fog of war: the lit region is the union of disks around each light. We
    // collapse that to "distance to the nearest light" and smoothstep it.
    float min_d = 1e9;
    int n = pc.light_count;
    if (n > MAX_FOG_LIGHTS) n = MAX_FOG_LIGHTS;
    for (int i = 0; i < n; ++i) {
        vec2 p = lights.pos[i].xy;
        float d = distance(world, p);
        if (d < min_d) min_d = d;
    }

    float r0 = pc.light_radius;
    float r1 = r0 + max(pc.light_falloff, 1.0);
    float fade = (n == 0) ? 1.0 : smoothstep(r0, r1, min_d);

    vec3 col = mix(lit, dark, fade);
    out_color = vec4(col, 1.0);
}
