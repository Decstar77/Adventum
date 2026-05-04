package main

import sapp "sokol/app"

KEY_COUNT :: 512  // matches sapp.MAX_KEYCODES

Input :: struct {
	is_down:  [KEY_COUNT]bool,
	was_down: [KEY_COUNT]bool,
}

input_init :: proc(in_: ^Input) {}

input_handle_event :: proc(in_: ^Input, ev: ^sapp.Event) {
	k := i32(ev.key_code)
	if k < 0 || k >= KEY_COUNT do return
	#partial switch ev.type {
	case .KEY_DOWN: in_.is_down[k] = true
	case .KEY_UP:   in_.is_down[k] = false
	}
}

input_update :: proc(in_: ^Input) {
	in_.was_down = in_.is_down
}

input_is_down :: proc(in_: ^Input, key: sapp.Keycode) -> bool {
	k := i32(key)
	if k < 0 || k >= KEY_COUNT do return false
	return in_.is_down[k]
}

input_just_pressed :: proc(in_: ^Input, key: sapp.Keycode) -> bool {
	k := i32(key)
	if k < 0 || k >= KEY_COUNT do return false
	return in_.is_down[k] && !in_.was_down[k]
}
