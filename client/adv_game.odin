package main

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"

WORLD_SCALE :: f32(2) // pixel zoom for the world view
PLAYER_SPEED :: f32(80) // world pixels per second
PROP_COUNT :: 60
PROP_SPREAD :: f32(400) // half-extent of the scatter area, in world pixels

Prop :: struct {
	pos:    v2,
	img_id: ImageId,
}

Player :: struct {
	pos:    v2,
	img_id: ImageId,
}

player: Player
props: [dynamic]Prop

game_start :: proc() {
	player.pos = v2{0, 0}
	player.img_id = image_by_name("player_idle")

	shrub_ids := [2]ImageId{image_by_name("shrub001"), image_by_name("shrub002")}

	clear(&props)
	for i in 0 ..< PROP_COUNT {
		p: Prop
		p.pos = v2 {
			rand.float32_range(-PROP_SPREAD, PROP_SPREAD),
			rand.float32_range(-PROP_SPREAD, PROP_SPREAD),
		}
		p.img_id = shrub_ids[rand.int_max(2)]
		append(&props, p)
	}

	log_infof("scattered %d props", len(props))
}

game_update :: proc() {
	// movement input
	dir := v2{0, 0}
	if playerMoveLeft {dir.x -= 1}
	if playerMoveRight {dir.x += 1}
	if playerMoveDown {dir.y -= 1}
	if playerMoveUp {dir.y += 1}
	if dir.x != 0 || dir.y != 0 {
		dir = linalg.normalize(dir)
		player.pos += dir * PLAYER_SPEED * frame_dt
	}

	cameraPos = player.pos;

	// world camera
	w := f32(window_w)
	h := f32(window_h)
	draw_frame.projection = linalg.matrix_ortho3d_f32(-w / 2, w / 2, -h / 2, h / 2, -1, 1)
	draw_frame.projectionInv = linalg.inverse(draw_frame.projection)

	cam := Matrix4(1)
	cam *= xform_scale(v2{WORLD_SCALE, WORLD_SCALE})
	cam *= xform_translate(-cameraPos)
	draw_frame.camera_xform = cam
	draw_frame.cameraInv = linalg.inverse(cam)

	// y-sort drawables (lower y renders on top)
	Drawable :: struct {
		pos:    v2,
		img_id: ImageId,
	}
	draw_list: [dynamic]Drawable
	defer delete(draw_list)
	reserve(&draw_list, len(props) + 1)
	for prop in props {
		append(&draw_list, Drawable{pos = prop.pos, img_id = prop.img_id})
	}
	append(&draw_list, Drawable{pos = player.pos, img_id = player.img_id})

	slice.sort_by(draw_list[:], proc(a, b: Drawable) -> bool {
		return a.pos.y > b.pos.y
	})

	for d in draw_list {
		if d.img_id == IMAGE_NIL {continue}
		draw_sprite(d.pos, d.img_id, pivot = .bottom_center)
	}
}
