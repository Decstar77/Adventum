# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Requires the Odin compiler on PATH. The Win32 target additionally needs the Vulkan SDK (uses `%VULKAN_SDK%\Bin\glslc.exe`).

- `buildwin32.bat` — compiles the GLSL shaders under `client/shaders/` to `.spv`, then runs `odin build client/win32 -debug -out:build/client.exe`.
- `runwin32.bat` — runs `buildwin32.bat` then launches `build/client.exe`.
- `build_web.bat` — `odin build client/web -target:js_wasm32` into `build/web/client.wasm`, then copies `index.html`, `host.js`, and `res/` alongside it. Serve with `py -m http.server -d build/web 8000`.
- `compress_audio.bat` — regenerates `.ogg` siblings for `res/sounds/*.wav` (the web build strips the `.wav` originals and loads `.ogg`).

There is no test suite, no linter, and no separate shader-only target. If you change a `.vert`/`.frag`, re-run `buildwin32.bat` so the embedded `.spv` (loaded via `#load` in Odin) is regenerated *before* the Odin build step.

The `.vscode/tasks.json` and `launch.json` are stale .NET configs from an unrelated project — ignore them.

## Architecture

Four sibling Odin packages under `client/`:

- `client/common/` (`package common`) — the platform contract and shared infrastructure. Defines `Platform`, the `Sound` / `Key` / `Font_Size` enums, the immediate-mode `UI` layout layer, the `Camera` transform, and the hex grid math. Has no host or game dependencies.
- `client/game/` (`package game`) — pure gameplay: world simulation, combat, enemies, waves, fx, and the top-level `Game` struct / `game_update_and_render` entry point. Imports `../common`; never touches GLFW, Vulkan, miniaudio, or any Win32 API.
- `client/win32/` (`package main`) — Windows host: GLFW window + input, Vulkan render stack, miniaudio playback. Implements `common.Platform` and drives `game.game_update_and_render` once per frame.
- `client/web/` (`package main`) — browser host: same Platform contract implemented over HTML5 Canvas 2D (via foreign imports to `host.js`), HTMLAudioElement, and CrazyGames SDK persistence. Built as `-target:js_wasm32`.

`Platform` (in `client/common/platform.odin`) is the only seam between game and host. Game code only ever sees a `^common.Platform`; the host fills in per-frame state and capability function pointers. Use `p->draw_rect(...)` shorthand at call sites — it desugars to `p.draw_rect(p, ...)`.

### Win32 render stack

Each layer in `client/win32/` owns its own Vulkan pipeline and per-frame vertex buffers:

- `renderer.odin` — `Renderer`: instance, surface, device, swapchain, render pass, framebuffers, command pool/buffers, and `MAX_FRAMES_IN_FLIGHT == 2` sync objects. Exposes `renderer_begin_frame` / `renderer_end_frame`. All raw Vulkan plumbing lives here.
- `gfx.odin` — `Graphics`: aggregates `Background_Renderer`, `Shape_Renderer`, and `Text_Renderer`. `gfx_begin` calls `renderer_begin_frame` and stashes the command buffer; `gfx_end` calls each sub-renderer's `*_record` to record draws, then `renderer_end_frame`. Also tracks the active scissor stack and camera transform.
- `shapes.odin` — pushes shape vertices into a per-frame mapped vertex buffer; one shader (`shapes.vert/frag`) handles rect/circle/capsule via a `type` vertex attribute and a `Shape_PC` push constant.
- `text.odin` — bakes `res/fonts/SUSEMono-Regular.ttf` into per-size atlases (Small/Large) with `vendor:stb/truetype`. Quads go through `text.vert/frag`. Shader SPV blobs are embedded with `#load("../shaders/*.spv")`, so paths resolve at compile time, not runtime.
- `background.odin` — fog-of-war / world-lighting pass: writes a per-frame UBO of point lights (one per visible building) and the shader (`background.vert/frag`) draws soft halos in world space.
- `audio.odin` — miniaudio engine, sound cache, per-family voice caps and cooldowns, positional attenuation, music shuffle with crossfades.
- `main.odin` — owns the GLFW window (1280×720, `NO_API` since Vulkan owns presentation), the frame loop, and a manual frame pacer that sleeps to the primary monitor's refresh rate using `win.timeBeginPeriod(1)` for higher-resolution sleeps. Also constructs the `common.Platform` struct, wires in every function pointer, and calls `free_all(context.temp_allocator)` once per frame — anything using `tprintf`/`tprint` is valid only within the current frame.

Frame ordering invariant: every `p->draw_*` call must sit between `gfx_begin` and `gfx_end`. The shape, text, and background renderers buffer CPU-side state during the frame and only flush + record draws inside `gfx_end`, so draws issued after `gfx_end` silently disappear.

## Assets

`res/` holds runtime assets (fonts, sprites, sounds). The `.gitignore` excludes generated `atlas.png` / `font.png` (text atlas debug dumps) and `build/`. The web build mirrors `res/` into `build/web/res/` and strips source-only files (`.aseprite`, the `prototype/` sprite folder, and `.wav` originals once `.ogg` siblings exist).
