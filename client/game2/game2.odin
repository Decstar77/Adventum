package game

import "core:math"
import "core:math/rand"
import "../common"

MAX_GUNS :: 5

Gun :: struct {
	pos:         [2]f32,
	vel:         [2]f32,
	angle:       f32,
	angular_vel: f32,
}

Game :: struct {
	pistol:       common.Texture,
	guns:         [MAX_GUNS]Gun,
	guns_spawned: bool,
}

game_init :: proc(g: ^Game, p: ^common.Platform) {
	g.pistol = p->load_texture("Guns/Pistols/Outlined/1Pistol01.png")
}

game_shutdown :: proc(g: ^Game) {}

game_update_and_render :: proc(g: ^Game, p: ^common.Platform) {
	p.master_volume   = 1
	p.gameplay_active = true

	SCALE        :: f32(2)
	DRAG         :: f32(1.4)   // exponential damping coefficient (per second)
	RECOIL_SPEED :: f32(950)   // pixels per second
	RECOIL_SPIN  :: f32(22)    // radians per second
	BOUNCE_DAMP  :: f32(0.65)  // energy kept on border bounce
	MARGIN       :: f32(80)    // spawn margin from screen edge

	raw_size := p->texture_size(g.pistol)
	gun_w := raw_size.x * SCALE if raw_size.x > 0 else f32(32)
	gun_h := raw_size.y * SCALE if raw_size.y > 0 else f32(32)
	hw := gun_w * 0.5
	hh := gun_h * 0.5

	if !g.guns_spawned && p.screen_w > 0 {
		for i in 0 ..< MAX_GUNS {
			g.guns[i] = Gun{
				pos   = {
					rand.float32_range(MARGIN, p.screen_w - MARGIN),
					rand.float32_range(MARGIN, p.screen_h - MARGIN),
				},
				angle = rand.float32_range(0, math.TAU),
			}
		}
		g.guns_spawned = true
	}

	for &gun in g.guns {
		// Click-to-fire: radius hit test against gun centre.
		d := p.mouse - gun.pos
		if p.mouse_left_pressed && d.x*d.x + d.y*d.y <= max(hw, hh) * max(hw, hh) {
			recoil_dir := rand.float32_range(0, math.TAU)
			gun.vel         = {math.cos(recoil_dir), math.sin(recoil_dir)} * RECOIL_SPEED
			gun.angular_vel  = rand.float32_range(-RECOIL_SPIN, RECOIL_SPIN)
		}

		// Physics — exponential velocity decay then integrate.
		decay           := math.exp(-DRAG * p.dt)
		gun.vel         *= decay
		gun.angular_vel *= decay
		gun.pos         += gun.vel * p.dt
		gun.angle       += gun.angular_vel * p.dt

		// Border bouncing.
		if gun.pos.x - hw < 0 {
			gun.pos.x = hw
			gun.vel.x = abs(gun.vel.x) * BOUNCE_DAMP
		} else if gun.pos.x + hw > p.screen_w {
			gun.pos.x = p.screen_w - hw
			gun.vel.x = -abs(gun.vel.x) * BOUNCE_DAMP
		}
		if gun.pos.y - hh < 0 {
			gun.pos.y = hh
			gun.vel.y = abs(gun.vel.y) * BOUNCE_DAMP
		} else if gun.pos.y + hh > p.screen_h {
			gun.pos.y = p.screen_h - hh
			gun.vel.y = -abs(gun.vel.y) * BOUNCE_DAMP
		}

		p->draw_texture_ex(g.pistol, gun.pos.x, gun.pos.y, gun_w, gun_h, gun.angle, {1, 1, 1, 1})
	}

	p->draw_text(20, 36, "click a gun to fire", {1, 1, 1, 1}, .Small)
}
