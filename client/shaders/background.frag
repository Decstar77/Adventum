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

float sd_seg(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
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

    // -------- World-space sample so the circuit pans/zooms with the camera --------
    vec2 world = (frag - pc.view_offset) / pc.view_scale;

    const float CELL = 64.0; // world units
    vec2  cell  = floor(world / CELL);
    vec2  local = (world - cell * CELL) / CELL - 0.5; // [-0.5, 0.5]

    // Cardinal connections — edge-shared hashes (consistent with neighbors).
    float eW = hash21(cell + vec2(-0.5, 0.0));
    float eE = hash21(cell + vec2( 0.5, 0.0));
    float eN = hash21(cell + vec2( 0.0,-0.5));
    float eS = hash21(cell + vec2( 0.0, 0.5));

    // Diagonal connections — corner-shared hashes.
    //   NE corner of (x,y) == SW corner of (x+1,y-1), etc.
    float eNE = hash21(cell + vec2( 0.5,-0.5));
    float eSE = hash21(cell + vec2( 0.5, 0.5));
    float eSW = hash21(cell + vec2(-0.5, 0.5));
    float eNW = hash21(cell + vec2(-0.5,-0.5));

    const float T  = 0.62; // cardinal probability gate
    const float TD = 0.86; // diagonals are rarer to keep things readable

    bool cW = eW > T,  cE = eE > T,  cN = eN > T,  cS = eS > T;
    bool dNE = eNE > TD, dSE = eSE > TD, dSW = eSW > TD, dNW = eNW > TD;

    float d = 1e9;
    if (cW)  d = min(d, sd_seg(local, vec2(0.0), vec2(-0.5,  0.0)));
    if (cE)  d = min(d, sd_seg(local, vec2(0.0), vec2( 0.5,  0.0)));
    if (cN)  d = min(d, sd_seg(local, vec2(0.0), vec2( 0.0, -0.5)));
    if (cS)  d = min(d, sd_seg(local, vec2(0.0), vec2( 0.0,  0.5)));
    if (dNE) d = min(d, sd_seg(local, vec2(0.0), vec2( 0.5, -0.5)));
    if (dSE) d = min(d, sd_seg(local, vec2(0.0), vec2( 0.5,  0.5)));
    if (dSW) d = min(d, sd_seg(local, vec2(0.0), vec2(-0.5,  0.5)));
    if (dNW) d = min(d, sd_seg(local, vec2(0.0), vec2(-0.5, -0.5)));

    int connections = int(cW) + int(cE) + int(cN) + int(cS)
                    + int(dNE) + int(dSE) + int(dSW) + int(dNW);

    // SDF is in cell-local units. Convert to pixels via cell-world->pixel scale
    // so line thickness stays constant on screen regardless of zoom.
    float d_px = d * CELL * pc.view_scale.x;

    // Thin, faint traces.
    float line_w = 0.4;
    float line_a = 1.0 - smoothstep(line_w, line_w + 1.0, d_px);
    float glow_a = (1.0 - smoothstep(0.0, 6.0, d_px)) * 0.10;

    vec3 trace_col = vec3(0.18, 0.58, 0.66);
    base += trace_col * (line_a * 0.18 + glow_a * 0.18);

    // -------- Nodes at busy intersections --------
    if (connections >= 3) {
        float r_px   = length(local) * CELL * pc.view_scale.x;
        float pulse  = 0.5 + 0.5 * sin(t * 1.1 + hash21(cell) * 6.2831);
        vec3  node_c = mix(vec3(0.32, 0.85, 0.95),
                           vec3(0.55, 1.00, 1.00), pulse);
        float core   = 1.0 - smoothstep(2.0, 3.4, r_px);
        float halo   = 1.0 - smoothstep(0.0, 12.0, r_px);
        base += node_c * core * (0.55 + 0.15 * pulse);
        base += node_c * halo * 0.05 * (0.6 + 0.4 * pulse);
    }

    // -------- Twinkling far-field sparkles (screen-locked, no parallax) --------
    {
        const float SCELL = 9.0;
        vec2 sg = floor(frag / SCELL);
        float sh = hash21(sg + 7.3);
        if (sh > 0.992) {
            vec2 jitter = vec2(hash21(sg + 11.1), hash21(sg + 23.7)) * (SCELL - 2.0) + 1.0;
            float dr = length((frag - sg * SCELL) - jitter);
            float tw = 0.5 + 0.5 * sin(t * 1.8 + sh * 47.0);
            float a  = (1.0 - smoothstep(0.0, 1.6, dr)) * tw;
            base += vec3(0.50, 0.78, 0.88) * a * 0.75;
        }
    }

    out_color = vec4(base, 1.0);
}
