package main

import "core:fmt"
import "core:os"

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

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
		renderer_set_text_color(&r, {1, 1, 1, 1})
		renderer_draw_text(&r, 24, 48, "Hello, Adventum!")
		renderer_set_text_color(&r, {0.6, 0.9, 1.0, 1})
		renderer_draw_text(&r, 24, 96, "Vulkan + stb_truetype")
		renderer_draw(&r)
	}
}
