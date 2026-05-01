package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

import "vendor:glfw"

main :: proc() {
	if !bool(glfw.Init()) {
		fmt.eprintln("failed to init GLFW")
		os.exit(1)
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, 0)

	window := glfw.CreateWindow(1280, 720, "Adventum", nil, nil)
	if window == nil {
		fmt.eprintln("failed to create window")
		os.exit(1)
	}
	defer glfw.DestroyWindow(window)

	r: Renderer
	if !renderer_init(&r, window) {
		fmt.eprintln("failed to init renderer")
		os.exit(1)
	}
	defer renderer_shutdown(&r)

	g: Graphics
	if !gfx_init(&g, &r) {
		fmt.eprintln("failed to init graphics")
		os.exit(1)
	}
	defer gfx_shutdown(&g)

	start := time.now()

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()

		t := f32(time.duration_seconds(time.since(start)))

		if !gfx_begin(&g) do continue

		draw_rect(&g, 60, 60, 200, 120, {0.85, 0.30, 0.30, 1})
		draw_rect(&g, 290, 60, 200, 120, {0.30, 0.85, 0.40, 1})

		draw_circle(&g, 620, 120, 60, {0.30, 0.60, 1.00, 1})
		draw_circle(&g, 760, 120, 40 + math.sin(t * 3) * 10, {1.00, 0.85, 0.30, 1})

		draw_line(&g, 80, 260, 1200, 260, 4, {1, 1, 1, 0.6})
		draw_line(&g, 80, 280, 80 + math.cos(t) * 400 + 400, 280 + math.sin(t) * 80, 12, {1.0, 0.4, 0.8, 1})

		draw_text(&g, 24, 48, "Hello, Adventum!")
		draw_text(&g, 24, 96, "shapes + text via Vulkan", {0.6, 0.9, 1.0, 1})
		draw_text(&g, 24, 360, "rect / circle / line / text", {1, 1, 0.7, 1})

		gfx_end(&g)
	}
}
