package game

import "core:math/rand"

// Hard grace period: nothing spawns (trickle or surge) before this many
// seconds, so the player has time to lay out their opening base. Tightened
// from 30s — the old window let an unchallenged player snowball 5+ farms
// before any pressure existed.
WAVE_GRACE_PERIOD    :: f32(15)
WAVE_FIRST_SURGE_AT  :: f32(90)

// Base seconds between surges (used as a coefficient — see waves_update).
// Cut from 90 because we now scale UP with composition, not down.
WAVE_SURGE_GAP       :: f32(60)
WAVE_SURGE_GAP_MIN   :: f32(45)
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

// Debug hook: schedule the next surge to fire on the very next waves_update
// tick. No-op while a surge is already active. Also pulls `elapsed` past the
// grace period so the early-return in waves_update can't swallow the trigger
// when the player presses this in the opening seconds of a run.
waves_force_next_surge :: proc(w: ^Wave_State) {
	if w.surge_active do return
	if w.elapsed < WAVE_GRACE_PERIOD do w.elapsed = WAVE_GRACE_PERIOD
	w.next_surge_at = w.elapsed
	w.trickle_acc = 0
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
surge_composition :: proc(index: i32) -> (crawlers, brutes, spitters, swarmers: i32) {
	// `index` is 0-based (first surge => 0). Every wave includes at least one
	// of each kind so the player actually sees the variety the game has — the
	// previous gating ("brutes from wave 2, spitters from wave 2") meant
	// players who died on wave 1 never saw them at all.
	crawlers = 8 + index * 2
	brutes   = 2 + index * 2
	spitters = 2 + index
	// Swarmers start at surge 1 (each splits into 2 crawlers, so we ramp slow
	// to avoid runaway populations from chained splits).
	if index >= 1 do swarmers = 1 + (index - 1) / 2
	return
}

// Total raw HP arriving in the surge with the given index. Used to scale the
// gap to the next surge so the player has proportionally more breathing room
// as composition grows — keeps "DPS required to clear" closer to constant
// instead of running away on a fixed-cadence schedule.
@(private="file")
surge_total_hp :: proc(index: i32) -> f32 {
	crawlers, brutes, spitters, swarmers := surge_composition(index)
	chp, _, _ := enemy_stats(.Crawler)
	bhp, _, _ := enemy_stats(.Brute)
	shp, _, _ := enemy_stats(.Spitter)
	whp, _, _ := enemy_stats(.Swarmer)
	return f32(crawlers) * chp + f32(brutes) * bhp + f32(spitters) * shp + f32(swarmers) * whp
}

// Pick the kind to spawn for a single trickle tick. Past the early game the
// trickle gets meaner — without this it floors at 1 crawler / 0.6s and stops
// being a threat once a single T1 turret is up. surge_index is the count of
// surges already fired, so this only kicks in after the player has *seen* the
// kind being mixed in.
@(private="file")
trickle_kind :: proc(surge_index: i32) -> Enemy_Kind {
	switch {
	case surge_index >= 3:
		// Hardened mix: crawlers still dominate but brutes/spitters/swarmers
		// bleed in.
		r := rand.float32()
		if r < 0.10 do return .Brute
		if r < 0.25 do return .Spitter
		if r < 0.35 do return .Swarmer
	case surge_index >= 1:
		// First taste of variety after the opening surge.
		r := rand.float32()
		if r < 0.15 do return .Spitter
		if r < 0.25 do return .Swarmer
	}
	return .Crawler
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
		enemy_spawn(world, trickle_kind(w.surge_index))
	}

	// Trigger a new surge.
	if !w.surge_active && w.elapsed >= w.next_surge_at {
		crawlers, brutes, spitters, swarmers := surge_composition(w.surge_index)
		clear(&w.surge.queue)
		// pop() removes the LAST element, so order the queue so crawlers spawn
		// first (drama: small things first, brutes follow).
		for _ in 0 ..< brutes   do append(&w.surge.queue, Enemy_Kind.Brute)
		for _ in 0 ..< swarmers do append(&w.surge.queue, Enemy_Kind.Swarmer)
		for _ in 0 ..< spitters do append(&w.surge.queue, Enemy_Kind.Spitter)
		for _ in 0 ..< crawlers do append(&w.surge.queue, Enemy_Kind.Crawler)
		w.surge.duration  = WAVE_SURGE_DURATION
		w.surge.time_left = WAVE_SURGE_DURATION
		w.surge.spawn_acc = 0
		w.surge_active    = true
		w.last_surge_num  = w.surge_index + 1
		w.banner_time     = WAVE_BANNER_DURATION
	}

	// Active surge: spawn-out staggered over the duration. The interval is
	// computed once from the *initial* queue length so pacing matches the
	// designed duration; we then keep popping at that cadence until the queue
	// fully drains. We deliberately do NOT end the surge on `time_left <= 0`
	// alone — float drift between `spawn_acc` and `time_left` (both fed by the
	// same dt but consumed differently) reliably left 1-2 items unspawned, and
	// since the queue's tail is brutes, brutes were the ones that vanished.
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
		if len(w.surge.queue) == 0 {
			w.surge_active   = false
			w.surge_index   += 1
			// Gap to the next surge scales with composition. The old rule
			// (90 / surge_index, floored at 30) shrunk to a 30s floor by
			// surge 3 and never recovered — surges arriving every 30s with
			// linearly-growing HP is a curve no realistic build rate beats.
			// Now: ratio = (next surge HP) / (first surge HP); larger surge
			// ⇒ proportionally more breathing room, with a hard floor so we
			// never sit forever between waves.
			//ratio := surge_total_hp(w.surge_index) / surge_total_hp(0)
			//gap   := WAVE_SURGE_GAP * ratio
			//if gap < WAVE_SURGE_GAP_MIN do gap = WAVE_SURGE_GAP_MIN
			w.next_surge_at  = w.elapsed + f32(max(90 / w.surge_index, 30))
		}
	}
}
