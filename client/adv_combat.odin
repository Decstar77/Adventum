package main

import "core:math"

TURRET_RANGE_PIXELS  :: f32(280)
TURRET_FIRE_INTERVAL :: f32(0.9)
TURRET_DAMAGE        :: f32(8)
PROJECTILE_SPEED     :: f32(640)
PROJECTILE_LIFE      :: f32(2.0)
PROJECTILE_HIT_R     :: f32(12)

Projectile :: struct {
	pos:  [2]f32,
	vel:  [2]f32,
	dmg:  f32,
	life: f32,
}

scrap_for_kind :: proc(kind: Enemy_Kind) -> i32 {
	switch kind {
	case .Crawler: return 1
	case .Brute:   return 4
	}
	return 0
}

@(private="file")
nearest_enemy_in_range :: proc(w: ^World, from: [2]f32, range: f32) -> int {
	best := -1
	best_d2 := range * range
	for e, i in w.enemies {
		dx := e.pos.x - from.x
		dy := e.pos.y - from.y
		d2 := dx * dx + dy * dy
		if d2 <= best_d2 {
			best_d2 = d2
			best = i
		}
	}
	return best
}

turrets_fire :: proc(w: ^World, dt: f32) {
	for coord, tile in w.tiles {
		if tile.kind != .Turret do continue
		t := tile
		if t.cooldown > 0 {
			t.cooldown -= dt
			if t.cooldown < 0 do t.cooldown = 0
		}
		if t.energized && t.cooldown <= 0 {
			origin := hex_to_pixel(coord)
			idx := nearest_enemy_in_range(w, origin, TURRET_RANGE_PIXELS)
			if idx >= 0 {
				target := w.enemies[idx].pos
				dx := target.x - origin.x
				dy := target.y - origin.y
				d := math.sqrt(dx * dx + dy * dy)
				if d < 0.001 do d = 0.001
				vel := [2]f32{dx / d * PROJECTILE_SPEED, dy / d * PROJECTILE_SPEED}
				append(&w.projectiles, Projectile{
					pos  = origin,
					vel  = vel,
					dmg  = TURRET_DAMAGE,
					life = PROJECTILE_LIFE,
				})
				t.cooldown = TURRET_FIRE_INTERVAL
			}
		}
		w.tiles[coord] = t
	}
}

projectiles_update :: proc(w: ^World, dt: f32) {
	hit_r2 := PROJECTILE_HIT_R * PROJECTILE_HIT_R
	for i := len(w.projectiles) - 1; i >= 0; i -= 1 {
		p := &w.projectiles[i]
		p.pos.x += p.vel.x * dt
		p.pos.y += p.vel.y * dt
		p.life -= dt

		hit := false
		for j in 0 ..< len(w.enemies) {
			e := &w.enemies[j]
			dx := e.pos.x - p.pos.x
			dy := e.pos.y - p.pos.y
			if dx * dx + dy * dy <= hit_r2 {
				e.hp -= p.dmg
				hit = true
				break
			}
		}

		if hit || p.life <= 0 {
			unordered_remove(&w.projectiles, i)
		}
	}
}

sweep_dead_enemies :: proc(w: ^World) {
	for i := len(w.enemies) - 1; i >= 0; i -= 1 {
		if w.enemies[i].hp <= 0 {
			w.scrap += scrap_for_kind(w.enemies[i].kind)
			unordered_remove(&w.enemies, i)
		}
	}
}

projectiles_render :: proc(w: ^World, g: ^Graphics) {
	color := [4]f32{0.886, 0.294, 0.290, 1}
	for p in w.projectiles {
		draw_circle(g, p.pos.x, p.pos.y, 3.5, color)
	}
}
