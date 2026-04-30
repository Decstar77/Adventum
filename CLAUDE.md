# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Adventum is an Odin game project using the Sokol graphics framework (sokol-gfx via D3D11/WGSL) and FMOD for audio. There are two Odin packages: `client/` (the actual game, currently the only active code) and `server/` (skeleton, empty `package main`). A texture atlas (`atlas.png`) and bitmap font (`font.png`) are generated/baked at runtime from `res/sprites/` and `res/fonts/`.

## Build & Run

Windows-only toolchain. Both scripts must be run from the repo root because they depend on relative paths:

- `build.bat` — Compiles GLSL → Odin via `sokol-shdc` (HLSL5 + WGSL backends), then `odin build client -debug -out:build/client.exe`.
- `run.bat` — Runs `build.bat` then launches `build/client.exe`. Pauses on build failure.

The shader pipeline is non-obvious: editing `client/shader.glsl` requires re-running `build.bat` because it regenerates `client/shader.odin` (a committed, generated file — do not hand-edit). The `sokol-shdc.exe` binary lives at the repo root.

There is no test suite, no linter config, and no CI.

## Runtime requirements

- `fmod.dll` / `fmodL.dll` must be alongside the executable — they're at the repo root and the exe is in `build/`, so launching from anywhere other than via `run.bat` (which `cd`s implicitly via the `call`) may fail to load FMOD. The game looks for assets via relative paths like `res/sounds/...`, so cwd must be the repo root.
- Sound files are loaded by enum-name convention: each `SoundId` enum variant in `adv_sounds.odin` maps to `res/sounds/<variant_name>.wav`. Adding a sound = add an enum value + drop the matching `.wav` in.

## Architecture

Single-package client (`package main` across all `client/*.odin` files — Odin merges them). Entry point is `adv_main.odin:main` which hands control to `sapp.run` with these callbacks:

- `atto_init` — sets up sokol-gfx, then calls `init_audio` → `init_images` → `init_fonts` → `init_render` → `game_start`. Order matters: rendering depends on the atlas built by `init_images` and the font baked by `init_fonts`.
- `atto_event` — translates sokol input events into module-level `playerMove*` / `playerMouse*` / `Fn Pressed` globals. Input state is global, not passed through.
- `atto_frame` — calls `game_update` then `audio_update` then `render_frame`. Mouse "prev" state is latched here for edge detection.
- `atto_cleanup` — shuts down audio + sokol.

`adv_game.odin` (`game_start` / `game_update`) is the gameplay hook surface and is currently empty — this is where new game logic goes.

### Rendering

`adv_render.odin` is a single-pass quad batcher:
- All draws push into `draw_frame.quads` (cap `MAX_QUADS = 524288`); `render_frame` uploads the whole batch in one `sg.update_buffer` call and issues one draw.
- Vertex format includes `tex_index` (u8) so multiple atlas textures can be sampled in one batch — the shader picks based on this index.
- Coordinate spaces: `projection` + `camera_xform` are stored on `Draw_Frame`; helpers like `draw_rect_projected` / `draw_quad_projected` take an explicit `world_to_clip` so callers control space. Screen-space UI vs world-space gameplay both go through the same batch.
- `init_images` rect-packs every PNG under `res/sprites/` into `atlas.png` at startup using `stb_rect_pack`; `init_fonts` bakes `font.png` from TTFs in `res/fonts/` using `stb_truetype`. These two PNGs are gitignored — they're build artifacts of the runtime, not source assets.

### Generated / committed-but-derived files

- `client/shader.odin` — generated from `shader.glsl` by `sokol-shdc`. Edit the GLSL.
- `atlas.png`, `font.png` — generated at runtime startup, gitignored.
- `build/`, `.vs/`, `.vscode/`, `.claude/` — gitignored.

### Conventions worth knowing

- `v2` / `v4` / `Matrix4` are project-local aliases (defined in `adv_render.odin`); prefer them over `[2]f32` etc. for consistency.
- Generic helpers like `contains` / `find` live in `adv_util.odin` — check there before adding new ones.
- The `server/` directory is a placeholder; networking on the client side (`adv_network.odin`) is also currently empty.
