package game

import "core:math"

TURRET_RANGE_PIXELS  :: f32(280)
TURRET_FIRE_INTERVAL :: f32(0.9)
TURRET_DAMAGE        :: f32(8)
TURRET_ROT_SPEED     :: f32(8.0)            // radians/sec
TURRET_AIM_TOLERANCE :: f32(0.18)           // ~10 deg
TURRET_MUZZLE_OFFSET :: f32(15)
PROJECTILE_SPEED     :: f32(640)
PROJECTILE_LIFE      :: f32(2.0)
PROJECTILE_HIT_R     :: f32(12)

@(private="file")
approach_angle :: proc(current, target, max_step: f32) -> f32 {
	diff := target - current
	for diff >  math.PI do diff -= 2 * math.PI
	for diff < -math.PI do diff += 2 * math.PI
	if diff >  max_step do diff =  max_step
	if diff < -max_step do diff = -max_step
	return current + diff
}

@(private="file")
shortest_angle_diff :: proc(a, b: f32) -> f32 {
	d := b - a
	for d >  math.PI do d -= 2 * math.PI
	for d < -math.PI do d += 2 * math.PI
	return d
}

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

		origin := hex_to_pixel(coord)
		idx := nearest_enemy_in_range(w, origin, TURRET_RANGE_PIXELS)

		// Track the nearest in-range enemy with a smooth rotation. With no
		// target the barrel just holds its last bearing.
		target_angle := t.aim_angle
		has_target := idx >= 0
		if has_target {
			tp := w.enemies[idx].pos
			target_angle = math.atan2(tp.y - origin.y, tp.x - origin.x)
		}
		t.aim_angle = approach_angle(t.aim_angle, target_angle, TURRET_ROT_SPEED * dt)

		if t.cooldown > 0 {
			t.cooldown -= dt
			if t.cooldown < 0 do t.cooldown = 0
		}

		if t.energized && t.cooldown <= 0 && has_target {
			// Only fire once roughly aimed at the target.
			if abs(shortest_angle_diff(t.aim_angle, target_angle)) <= TURRET_AIM_TOLERANCE {
				dmg := turret_damage(t.tier)
				fire_bullet :: proc(w: ^World, origin: [2]f32, angle, dmg: f32) {
					dx := math.cos(angle)
					dy := math.sin(angle)
					muzzle := [2]f32{
						origin.x + dx * TURRET_MUZZLE_OFFSET,
						origin.y + dy * TURRET_MUZZLE_OFFSET,
					}
					append(&w.projectiles, Projectile{
						pos  = muzzle,
						vel  = {dx * PROJECTILE_SPEED, dy * PROJECTILE_SPEED},
						dmg  = dmg,
						life = PROJECTILE_LIFE,
					})
					fx_emit_muzzle(w, muzzle, angle)
				}
				fire_bullet(w, origin, t.aim_angle, dmg)
				// Tier-3 back gun: simultaneous shot in the opposite direction.
				if turret_has_back_gun(t.tier) {
					fire_bullet(w, origin, t.aim_angle + math.PI, dmg)
				}
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
		fx_emit_projectile_trail(w, p.pos)

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

		if hit {
			fx_emit_impact(w, p.pos, p.vel)
		}
		if hit || p.life <= 0 {
			unordered_remove(&w.projectiles, i)
		}
	}
}

sweep_dead_enemies :: proc(w: ^World) {
	for i := len(w.enemies) - 1; i >= 0; i -= 1 {
		if w.enemies[i].hp <= 0 {
			fx_emit_enemy_death(w, w.enemies[i].pos, w.enemies[i].kind)
			w.scrap += scrap_for_kind(w.enemies[i].kind)
			unordered_remove(&w.enemies, i)
		}
	}
}

projectiles_render :: proc(w: ^World, p: ^Platform) {
	color := [4]f32{0.886, 0.294, 0.290, 1}
	for proj in w.projectiles {
		p->draw_circle(proj.pos.x, proj.pos.y, 3.5, color)
	}
}
