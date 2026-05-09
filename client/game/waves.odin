package game

// Hard grace period: nothing spawns (trickle or surge) before this many
// seconds, so the player has time to lay out their opening base.
WAVE_GRACE_PERIOD    :: f32(30)
WAVE_FIRST_SURGE_AT  :: f32(90)
WAVE_SURGE_GAP       :: f32(90)
WAVE_SURGE_DURATION  :: f32(4)
WAVE_BANNER_DURATION :: f32(3)

TRICKLE_BASE_INTERVAL :: f32(8.0)
TRICKLE_RAMP_PER_SEC  :: f32(0.04)
TRICKLE_MIN_INTERVAL  :: f32(0.6)

Active_Surge :: struct {
	duration:  f32,
	time_left: f32,
	spawn_acc: f32,
	queue:     [dynamic]Enemy_Kind,
}

Wave_State :: struct {
	elapsed:        f32,
	trickle_acc:    f32,
	next_surge_at:  f32,
	surge_index:    i32, // count of surges fired
	surge:          Active_Surge,
	surge_active:   bool,
	banner_time:    f32,
	last_surge_num: i32, // 1-based label for the SURGE banner
}

waves_init :: proc(w: ^Wave_State) {
	w.next_surge_at = WAVE_FIRST_SURGE_AT
}

waves_shutdown :: proc(w: ^Wave_State) {
	delete(w.surge.queue)
}

waves_time_to_next_surge :: proc(w: ^Wave_State) -> f32 {
	if w.surge_active do return 0
	t := w.next_surge_at - w.elapsed
	if t < 0 do t = 0
	return t
}

@(private="file")
trickle_interval :: proc(t: f32) -> f32 {
	iv := TRICKLE_BASE_INTERVAL - TRICKLE_RAMP_PER_SEC * t
	if iv < TRICKLE_MIN_INTERVAL do iv = TRICKLE_MIN_INTERVAL
	return iv
}

@(private="file")
surge_composition :: proc(index: i32) -> (crawlers, brutes, spitters: i32) {
	crawlers = 8 + index * 2
	if index >= 1 {
		brutes = 2 + index * 2
	}
	// Spitters debut on the second surge and ramp slowly — they harass at
	// stand-off range and pair well with the contact-melee fodder.
	if index >= 1 {
		spitters = 2 + index
	}
	return
}

waves_update :: proc(world: ^World, w: ^Wave_State, dt: f32) {
	w.elapsed += dt
	if w.banner_time > 0 do w.banner_time -= dt

	// Honor the grace period: no trickle and no surge before WAVE_GRACE_PERIOD.
	// Surge timing already lives at WAVE_FIRST_SURGE_AT >> grace, so this only
	// really gates the trickle in practice — but the early-return keeps the
	// invariant in one place.
	if w.elapsed < WAVE_GRACE_PERIOD {
		// Drain the trickle accumulator so the moment grace ends we don't dump
		// 30 seconds' worth of crawlers in one frame.
		w.trickle_acc = 0
		return
	}

	// Continuous trickle (always running once grace ends, ramps with elapsed time).
	w.trickle_acc += dt
	iv := trickle_interval(w.elapsed)
	for w.trickle_acc >= iv {
		w.trickle_acc -= iv
		enemy_spawn(world, .Crawler)
	}

	// Trigger a new surge.
	if !w.surge_active && w.elapsed >= w.next_surge_at {
		crawlers, brutes, spitters := surge_composition(w.surge_index)
		clear(&w.surge.queue)
		// pop() removes the LAST element, so order the queue so crawlers spawn
		// first (drama: small things first, brutes follow).
		for _ in 0 ..< brutes   do append(&w.surge.queue, Enemy_Kind.Brute)
		for _ in 0 ..< spitters do append(&w.surge.queue, Enemy_Kind.Spitter)
		for _ in 0 ..< crawlers do append(&w.surge.queue, Enemy_Kind.Crawler)
		w.surge.duration  = WAVE_SURGE_DURATION
		w.surge.time_left = WAVE_SURGE_DURATION
		w.surge.spawn_acc = 0
		w.surge_active    = true
		w.last_surge_num  = w.surge_index + 1
		w.banner_time     = WAVE_BANNER_DURATION
	}

	// Active surge: spawn-out staggered over the duration.
	if w.surge_active {
		w.surge.time_left -= dt
		total := i32(len(w.surge.queue))
		if total > 0 {
			interval := w.surge.duration / f32(total)
			if interval < 0.05 do interval = 0.05
			w.surge.spawn_acc += dt
			for w.surge.spawn_acc >= interval && len(w.surge.queue) > 0 {
				w.surge.spawn_acc -= interval
				kind := pop(&w.surge.queue)
				enemy_spawn(world, kind)
			}
		}
		if w.surge.time_left <= 0 || len(w.surge.queue) == 0 {
			w.surge_active   = false
			w.surge_index   += 1
			w.next_surge_at  = w.elapsed + WAVE_SURGE_GAP
		}
	}
}
