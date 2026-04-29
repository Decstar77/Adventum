package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:os"
import t "core:time"

import sapp "sokol/app"
import sg "sokol/gfx"
import sglue "sokol/glue"
import slog "sokol/log"

import stbi "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"


app_state: struct {
	pass_action: sg.Pass_Action,
	pip:         sg.Pipeline,
	bind:        sg.Bindings,
}

window_w :: 960
window_h :: 540
GuiScale :: 4

// window_w :: 1280
// window_h :: 720

playerMoveLeft := false
playerMoveRight := false
playerMoveUp := false
playerMoveDown := false
playerScrollLeft := false
playerScrollRight := false
playerScrollUp := false
playerScrollDown := false
playerMouseX: f32 = -1.0
playerMouseY: f32 = -1.0
playerMouseLeftDown := false
playerMouseLeftPrev := false
playerMouseRightDown := false
playerMouseRightPrev := false
playerIsDragging := false
playerStartDragSP := v2{}
playerEndDragSP := v2{}

F1Pressed := false
F2Pressed := false
F3Pressed := false
F4Pressed := false

cameraPos: v2 = {0, 0}

main :: proc() {
	sapp.run(
		{
			init_cb = atto_init,
			frame_cb = atto_frame,
			cleanup_cb = atto_cleanup,
			event_cb = atto_event,
			width = window_w,
			height = window_h,
			// fullscreen = true,
			window_title = "game1",
			icon = {sokol_default = true},
			logger = {func = slog.func},
			swap_interval = 1,
		},
	)
}

atto_event :: proc "c" (ev: ^sapp.Event) {
	using linalg, fmt
	context = runtime.default_context()

	if ev.type == .KEY_DOWN && (ev.key_code == .ENTER || ev.key_code == .KP_ENTER) {
		sapp.toggle_fullscreen()
	}

	if ev.type == .KEY_DOWN {
		#partial switch (ev.key_code) {
		case .ESCAPE:
			sapp.quit()
		case .W:
			playerMoveUp = true
		case .S:
			playerMoveDown = true
		case .A:
			playerMoveLeft = true
		case .D:
			playerMoveRight = true
		case .F1:
			F1Pressed = true
		case .F2:
			F2Pressed = true
		case .F3:
			F3Pressed = true
		case .F4:
			F4Pressed = true
		}
	}
	if ev.type == .KEY_UP {
		#partial switch (ev.key_code) {
		case .W:
			playerMoveUp = false
		case .S:
			playerMoveDown = false
		case .A:
			playerMoveLeft = false
		case .D:
			playerMoveRight = false
		case .F1:
			F1Pressed = false
		case .F2:
			F2Pressed = false
		case .F3:
			F3Pressed = false
		case .F4:
			F4Pressed = false
		}
	}

	if (ev.type == .MOUSE_MOVE) {
		playerMouseX = ev.mouse_x
		playerMouseY = ev.mouse_y
		// printf("Mouse position: %.1f, %.1f\n", playerMouseX, playerMouseY)
	}

	currentMouseSP := v2{playerMouseX, playerMouseY}

	if (ev.type == .MOUSE_DOWN) {
		if (ev.mouse_button == .LEFT) {
			playerMouseLeftDown = true
			playerStartDragSP = currentMouseSP
			playerEndDragSP = currentMouseSP
		}
		if (ev.mouse_button == .RIGHT) {
			playerMouseRightDown = true
		}
	}

	if (ev.type == .MOUSE_UP) {
		if (ev.mouse_button == .LEFT) {
			playerMouseLeftDown = false
			playerIsDragging = false
		}
		if (ev.mouse_button == .RIGHT) {
			playerMouseRightDown = false
		}
	}

	if (playerMouseLeftDown == true && playerStartDragSP != currentMouseSP) {
		playerIsDragging = true
		playerEndDragSP = currentMouseSP
	}

	playerScrollLeft = false
	playerScrollRight = false
	playerScrollUp = false
	playerScrollDown = false

	if (playerMouseX == 0) {
		playerScrollLeft = true
	}
	if (playerMouseX == sapp.widthf() - 1) {
		playerScrollRight = true
	}
	if (playerMouseY == 0) {
		playerScrollUp = true
	}
	if (playerMouseY == sapp.heightf() - 1) {
		playerScrollDown = true
	}
}

atto_init :: proc "c" () {
	using linalg, fmt
	context = runtime.default_context()

	init_time = t.now()
	sg.setup(
		{
			environment = sglue.environment(),
			logger = {func = slog.func},
			d3d11_shader_debugging = ODIN_DEBUG,
		},
	)

	init_audio()
	init_images()
	init_fonts()
	init_render()

	game_start()
}

atto_frame :: proc "c" () {
	using runtime, linalg
	context = runtime.default_context()

	game_update()

	playerMouseLeftPrev = playerMouseLeftDown
	playerMouseRightPrev = playerMouseRightDown

	audio_update()

	render_frame()
}

atto_cleanup :: proc "c" () {
	context = runtime.default_context()

	audio_shutdown()

	sg.shutdown()
}
