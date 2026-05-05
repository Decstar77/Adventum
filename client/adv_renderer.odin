package main

import "core:fmt"

import sg    "sokol/gfx"
import sapp  "sokol/app"
import sglue "sokol/glue"
import slog  "sokol/log"

// Thin wrapper around sokol_gfx setup. Window/event handling lives in sokol_app
// (see adv_main.odin). Sokol owns frame pacing via swap_interval, so the manual
// Win32 timeBeginPeriod sleeper is gone.

Renderer :: struct {
	clear_color: [4]f32,
	width:       i32,
	height:      i32,
}

renderer_init :: proc(r: ^Renderer) -> bool {
	r.clear_color = {0.01, 0.01, 0.02, 1.0}
	sg.setup({
		environment = sglue.environment(),
		logger      = {func = slog.func},
	})
	if !sg.isvalid() {
		fmt.eprintln("[renderer] sg.setup failed (sg.isvalid=false)")
		return false
	}
	renderer_update_size(r)
	fmt.printfln("[renderer] backend=%v initial_size=%dx%d dpi=%.2f",
		sg.query_backend(), r.width, r.height, sapp.dpi_scale())
	return true
}

renderer_update_size :: proc(r: ^Renderer) {
	r.width  = sapp.width()
	r.height = sapp.height()
}

renderer_shutdown :: proc(r: ^Renderer) {
	sg.shutdown()
}
