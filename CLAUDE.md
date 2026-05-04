# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Windows for native; emscripten for the web. Requires the Odin compiler on PATH. No Vulkan SDK or shader-compile step — sokol_gfx is fed GLSL string constants from `adv_shaders.odin`.

- `build.bat` — `odin build client -debug -out:build/client.exe -define:SOKOL_USE_GL=true`. The `-define:SOKOL_USE_GL=true` flag selects the GL clibs in `client/sokol/**/*.lib` (matched at link time by the bindings' `when` blocks) and is the same flag the Odin code reads to pick GLCORE vs GLES3 shader sources at runtime. There is no test suite or linter.
- `build_web.bat` — wasm/web build via emscripten. **Requires the sokol wasm clibs**, which aren't checked in: run upstream sokol-odin's `build_clibs_emcc.sh` once under emsdk to produce `sokol/{app,gfx,glue,log}/sokol_*_wasm_gl_*.a`. Until then this script will fail at the link step.
- `run_all.bat` — runs `build.bat` then launches `build/client.exe`.

The `.vscode/tasks.json` and `launch.json` are stale .NET configs from an unrelated project — ignore them.

## Architecture

Single-package Odin client (`package main`, all files in `client/`) targeting sokol_gfx (GL backend) via the bindings vendored under `client/sokol/`. Sokol_app owns the window, event loop, and frame pacing, replacing GLFW + the previous manual Win32 timeBeginPeriod sleeper. There is no server code yet despite the `client/` naming. FMOD bindings used to live under `client/fmod/` but were removed (won't run in the browser anyway); audio is currently unimplemented.

The render stack is a layered pipeline. Each layer owns its own sg.Pipeline + sg.Shader; vertex data is uploaded once per frame into a `STREAM` `sg.Buffer` via `sg.update_buffer`:

- `adv_renderer.odin` — minimal `Renderer` struct: clear color, current width/height. `renderer_init` calls `sg.setup` with `sglue.environment()`. Frame pacing comes from sokol's `swap_interval = 1` (vsync); there is no manual sleeper.
- `adv_gfx.odin` — `Graphics` aggregates a `Background_Renderer`, `Shape_Renderer`, and `Text_Renderer`. `gfx_begin` updates `Renderer.width/height` from sapp and resets the scissor stack; `gfx_end` opens one swapchain pass (`sg.begin_pass` with `sglue.swapchain()`), then calls each sub-renderer's `*_record` (which uploads its vertex buffer and issues draws), then `sg.end_pass` + `sg.commit`. Public draw API: `draw_rect`, `draw_circle`, `draw_line`, `draw_text`.
- `adv_shaders.odin` — GLSL shader sources as `cstring` constants, with separate GLCORE (`#version 410 core`) and GLES3 (`#version 300 es`) variants per stage. `select_shader_source` picks the right one based on `sg.query_backend()`. Sokol's GL backend does **not** use UBOs — uniform blocks are flattened to individual `uniform` vars and described via `Glsl_Shader_Uniform` entries on `Shader_Desc`. Uniform structs on the Odin side are padded to std140 layout.
- `adv_shapes.odin` — pushes shape vertices into a CPU `[dynamic]Shape_Vert` and batches by (scissor, view_scale, view_offset). One shader handles rect/circle/capsule via a `type` vertex attribute. Order matters in `shapes_record`: `apply_pipeline` → `apply_bindings` → `apply_uniforms` → `draw`.
- `adv_text.odin` — bakes `res/fonts/SUSEMono-Regular.ttf` into a 1024×1024 atlas (one per `Font_Size`) with `vendor:stb/truetype`, uploaded via `sg.make_image` with `pixel_format = .R8`. Quads batched by (scissor, font). One sampler shared across atlases.
- `adv_background.odin` — fullscreen triangle synthesised from `gl_VertexID`. **Does not call `sg.apply_bindings`** because the pipeline declares zero vertex inputs and zero images: sokol's `required_bindings_and_uniforms` bitmask check would otherwise flag a mismatch (calling apply_bindings unconditionally sets a bit the pipeline never required).
- `adv_ui.odin` — immediate-mode UI state. Receives sokol events via `ui_handle_event` (mouse pos/buttons, scroll). Edge state (`mouse_was_down`, `rmb_was_down`) is snapshotted at the **end** of each `frame_cb`, so events arriving between frames flip `is_down` and the next frame sees `just_pressed = is_down && !was_down`.
- `adv_input.odin` — keyboard state indexed by `sapp.Keycode`. Same end-of-frame snapshot pattern as UI.
- `adv_main.odin` — sokol_app callbacks. App state lives in a file-scoped `g_app: App` plus `g_ctx: runtime.Context` (callbacks are `proc "c"` and need `context = g_ctx`). `frame_cb` runs game logic, then `gfx_begin → draws → gfx_end`, then snapshots input/UI edge state, then `free_all(context.temp_allocator)` — anything using `tprintf`/`tprint` is valid only within the current frame.

Frame ordering invariant: every `draw_*` call must sit between `gfx_begin` and `gfx_end`. The sub-renderers buffer CPU-side vertices during the frame and only upload + draw inside `gfx_end`, so issuing draws after `gfx_end` silently disappears.

## Assets

`res/` holds runtime assets (fonts, sprites). The `.gitignore` excludes generated `atlas.png` / `font.png` (text atlas debug dumps), `src.exe`/`src.pdb`, and `build/`. The web build uses emscripten's `--preload-file res` to bundle assets into the wasm package.
