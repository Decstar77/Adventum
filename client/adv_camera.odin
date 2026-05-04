package main

import "core:math"

Camera :: struct {
	pos:    [2]f32,
	target: [2]f32,
	zoom:   f32,
}

CAMERA_SMOOTH_RATE :: f32(18)

camera_update :: proc(cam: ^Camera, dt: f32) {
	t := 1 - math.exp(-CAMERA_SMOOTH_RATE * dt)
	cam.pos += (cam.target - cam.pos) * t
}

camera_screen_to_world :: proc(cam: ^Camera, p: [2]f32, sw, sh: f32) -> [2]f32 {
	return {
		(p.x - sw * 0.5) / cam.zoom + cam.pos.x,
		(p.y - sh * 0.5) / cam.zoom + cam.pos.y,
	}
}

camera_world_to_screen :: proc(cam: ^Camera, p: [2]f32, sw, sh: f32) -> [2]f32 {
	return {
		(p.x - cam.pos.x) * cam.zoom + sw * 0.5,
		(p.y - cam.pos.y) * cam.zoom + sh * 0.5,
	}
}
