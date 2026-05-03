#version 450

// Fullscreen triangle. No vertex buffer; positions are derived from gl_VertexIndex.
//   index 0 -> (-1,-1)   index 1 -> ( 3,-1)   index 2 -> (-1, 3)
// covers the [-1,1] viewport with a single triangle.
void main() {
    vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
