# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Windows-only. Requires the Odin compiler on PATH and the Vulkan SDK (the build uses `%VULKAN_SDK%\Bin\glslc.exe`).

- `build.bat` — compiles the four GLSL shaders under `client/shaders/` to `.spv`, then runs `odin build client -debug -out:build/client.exe`.
- `run_all.bat` — runs `build.bat` then launches `build/client.exe`.

There is no test suite, no linter, and no separate shader-only target. If you change a `.vert`/`.frag`, re-run `build.bat` so the embedded `.spv` (loaded via `#load` in Odin) is regenerated *before* the Odin build step.

The `.vscode/tasks.json` and `launch.json` are stale .NET configs from an unrelated project — ignore them.

## Architecture

Single-package Odin client (`package main`, all files in `client/`) targeting Vulkan via `vendor:vulkan` and GLFW via `vendor:glfw`. There is no server code yet despite the `client/` naming, and no top-level Odin module other than the client. FMOD bindings live under `client/fmod/` but are not yet wired into `main`.

The render stack is a layered pipeline, each layer owning its own Vulkan pipeline + per-frame vertex buffers:

- `adv_renderer.odin` — `Renderer` struct: instance, surface, device, swapchain, render pass, framebuffers, command pool/buffers, and `MAX_FRAMES_IN_FLIGHT == 2` sync objects. Exposes `renderer_begin_frame` / `renderer_end_frame` which acquire the swapchain image and submit. All Vulkan plumbing lives here.
- `adv_gfx.odin` — `Graphics` aggregates a `Shape_Renderer` and `Text_Renderer`. `gfx_begin` calls `renderer_begin_frame` and stashes the command buffer; `gfx_end` calls each sub-renderer's `*_record` (which records draw commands into the active command buffer) then `renderer_end_frame`. Public draw API: `draw_rect`, `draw_circle`, `draw_line`, `draw_text`.
- `adv_shapes.odin` — pushes shape vertices into a per-frame mapped vertex buffer; one shader (`shapes.vert/frag`) handles rect/circle/capsule via a `type` vertex attribute and a `Shape_PC` push constant carrying screen size.
- `adv_text.odin` — bakes `res/fonts/SUSEMono-Regular.ttf` into a 512×512 atlas with `vendor:stb/truetype` at `FONT_PIXEL_SIZE = 32`, glyphs `FONT_FIRST_CHAR..` for `FONT_NUM_CHARS` chars. Quads go through `text.vert/frag`. Shader SPV blobs are embedded with `#load("shaders/*.spv")`, so shader paths are resolved relative to the source file at compile time, not at runtime.
- `adv_ui.odin` — immediate-mode UI state (mouse pos + edge-detected click). `ui_button` draws via `Graphics` and returns true on release-inside.
- `adv_main.odin` — owns the GLFW window (1280×720, non-resizable, `NO_API` since Vulkan owns presentation), the frame loop, and a manual frame pacer that sleeps to the primary monitor's refresh rate using `win.timeBeginPeriod(1)` for higher-resolution sleeps. Calls `free_all(context.temp_allocator)` once per frame — anything using `tprintf`/`tprint` is valid only within the current frame.

Frame ordering invariant: every `draw_*` call must sit between `gfx_begin` and `gfx_end`. The shape and text renderers buffer CPU-side vertices during the frame and only flush + record draws inside `gfx_end`, so issuing draws after `gfx_end` silently disappears.

## Assets

`res/` holds runtime assets (fonts, sprites). The `.gitignore` excludes generated `atlas.png` / `font.png` (text atlas debug dumps), `src.exe`/`src.pdb`, and `build/`.
