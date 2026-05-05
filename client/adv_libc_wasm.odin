#+build wasm32, wasm64p32
package main

// vendor:libc provides C-callable shims (cos, sin, exp, fmod, sqrtf, ...)
// that prebuilt wasm objects like stb_truetype_wasm.o reference. Importing
// it explicitly ensures those exports are present in our .o when linking
// under -build-mode:obj (the @(require) hint inside stb's wasm shim does
// not propagate through obj mode).
@(require) import _ "vendor:libc"
