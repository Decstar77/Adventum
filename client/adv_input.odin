package main

import "vendor:glfw"

KEY_COUNT :: 350

Input :: struct {
	is_down:  [KEY_COUNT]bool,
	was_down: [KEY_COUNT]bool,
}

@(private="file") g_input: ^Input

input_init :: proc(in_: ^Input, window: glfw.WindowHandle) {
	g_input = in_
	glfw.SetKeyCallback(window, input_key_cb)
}

@(private="file")
input_key_cb :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if g_input == nil do return
	if key < 0 || key >= KEY_COUNT do return
	switch action {
	case glfw.PRESS:   g_input.is_down[key] = true
	case glfw.RELEASE: g_input.is_down[key] = false
	}
}

input_update :: proc(in_: ^Input) {
	in_.was_down = in_.is_down
}

input_is_down :: proc(in_: ^Input, key: i32) -> bool {
	if key < 0 || key >= KEY_COUNT do return false
	return in_.is_down[key]
}

input_just_pressed :: proc(in_: ^Input, key: i32) -> bool {
	if key < 0 || key >= KEY_COUNT do return false
	return in_.is_down[key] && !in_.was_down[key]
}
