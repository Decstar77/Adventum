package main

Camera :: struct {
	pos:  [2]f32,
	zoom: f32,
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
