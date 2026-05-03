#version 450

layout(location = 0) out vec4 out_color;

layout(push_constant) uniform PC {
    vec2  screen;
    vec2  view_scale;   // world->screen (camera zoom)
    vec2  view_offset;  // world->screen translation
    float time;
    float _pad;
} pc;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

void main() {
    vec2 frag    = gl_FragCoord.xy;
    vec2 uv      = frag / pc.screen;
    float aspect = pc.screen.x / pc.screen.y;
    float t      = pc.time;

    // -------- Base: dark teal radial fade with a slow drift --------
    vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
    float vign = smoothstep(0.0, 1.05, length(c));
    vec3 base = mix(vec3(0.045, 0.115, 0.135),
                    vec3(0.005, 0.020, 0.030), vign);
    base += vec3(0.0, 0.006, 0.010) *
            (0.5 + 0.5 * sin(t * 0.18 + uv.y * 2.6 + uv.x * 1.3));

    // -------- World-space glowing nodes (pan/zoom with the camera) --------
    vec2 world = (frag - pc.view_offset) / pc.view_scale;
    const float CELL = 96.0; // world units between candidate node sites
    vec2 cell  = floor(world / CELL);
    vec2 local = (world - cell * CELL) / CELL - 0.5;

    // float h = hash21(cell + 5.1);
    // if (h > 0.78) {
    //     // Jitter the node so it doesn't sit dead-centre in its grid.
    //     vec2 jitter = (vec2(hash21(cell + 17.3), hash21(cell + 29.7)) - 0.5) * 0.7;
    //     float r_px  = length(local - jitter) * CELL * pc.view_scale.x;
    //     float pulse = 0.5 + 0.5 * sin(t * 1.0 + h * 6.2831);
    //     vec3  ncol  = mix(vec3(0.32, 0.85, 0.95),
    //                       vec3(0.55, 1.00, 1.00), pulse);
    //     float core  = 1.0 - smoothstep(1.6, 2.8, r_px);
    //     float halo  = 1.0 - smoothstep(0.0, 14.0, r_px);
    //     base += ncol * core * (0.55 + 0.15 * pulse);
    //     base += ncol * halo * 0.06 * (0.6 + 0.4 * pulse);
    // }

    // -------- Twinkling far-field sparkles (screen-locked, no parallax) --------
    // {
    //     const float SCELL = 9.0;
    //     vec2 sg = floor(frag / SCELL);
    //     float sh = hash21(sg + 7.3);
    //     if (sh > 0.992) {
    //         vec2 jitter = vec2(hash21(sg + 11.1), hash21(sg + 23.7)) * (SCELL - 2.0) + 1.0;
    //         float dr = length((frag - sg * SCELL) - jitter);
    //         float tw = 0.5 + 0.5 * sin(t * 1.8 + sh * 47.0);
    //         float a  = (1.0 - smoothstep(0.0, 1.6, dr)) * tw;
    //         base += vec3(0.50, 0.78, 0.88) * a * 0.75;
    //     }
    // }

    out_color = vec4(base, 1.0);
}
