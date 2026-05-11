package main

// Audio backend for the win32 host. Wraps miniaudio (vendor:miniaudio).
//
// Two play paths:
//
//   - `audio_play`     — UI / non-spatial cues. Plays without attenuation or
//                        panning and respects the per-family cooldown gate
//                        (so a stuttering button click doesn't pile up).
//
//   - `audio_play_at`  — positional. Creates a managed `ma.sound`, sets its
//                        world-space position, configures linear attenuation
//                        with a bounded radius (so a far-off explosion is
//                        audible but quiet), and parks it in `active` for
//                        sweep-cleanup once playback finishes. Per-family
//                        cooldown is skipped here: each positional play is a
//                        distinct sound source with its own pan/level, and
//                        the game-side limit of K per family per frame
//                        already keeps the simultaneous-salvo case bounded.
//
// World→audio mapping is one hex pitch (HEX_SIZE * 1.5 ≈ 72 pixels) per audio
// unit, configured by `AUDIO_PIXELS_PER_UNIT`. Listener at the camera position,
// facing the default -Z (we map screen Y → audio Z so left/right pan tracks
// the X axis).

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:time"
import ma "vendor:miniaudio"

import "../game"

// Minimum gap between consecutive plays of the same family. Applies to both
// the spatial and non-spatial paths — spatial diversity (pan + attenuation)
// doesn't help when twenty copies of the same wav land in the same 50 ms.
@(private="file")
SOUND_MIN_INTERVAL := [game.Sound]time.Duration{
	.None             = 0,
	.Button_Hover     = 50  * time.Millisecond,
	.Button_Click     = 0,
	.Place_Building   = 0,
	.Building_Explode = 120 * time.Millisecond,
	.Turret_Shoot     = 110 * time.Millisecond,
	.Enemy_Attack     = 140 * time.Millisecond,
	.Enemy_Die        = 110 * time.Millisecond,
}

// Maximum concurrent *positional* voices per family. If this many copies are
// still playing, new positional plays of the same family are dropped. UI / non-
// spatial plays don't count toward this — they don't go through `a.active`.
@(private="file")
SOUND_MAX_VOICES := [game.Sound]i32{
	.None             = 0,
	.Button_Hover     = 0,
	.Button_Click     = 0,
	.Place_Building   = 2,
	.Building_Explode = 2,
	.Turret_Shoot     = 3,
	.Enemy_Attack     = 2,
	.Enemy_Die        = 2,
}

// Variants per family. Order matches `res/sounds/`; randomly sampled at play.
@(private="file")
SOUND_FILES := [game.Sound][]string{
	.None             = {},
	.Button_Hover     = {"res/sounds/button-hover.wav"},
	.Button_Click     = {"res/sounds/button-click.wav"},
	.Place_Building   = {"res/sounds/place_building_1.wav", "res/sounds/place_building_2.wav"},
	.Building_Explode = {"res/sounds/building-explode.wav"},
	.Turret_Shoot     = {
		"res/sounds/turret_shoot-01.wav",
		"res/sounds/turret_shoot-02.wav",
		"res/sounds/turret_shoot-03.wav",
	},
	.Enemy_Attack     = {
		"res/sounds/enemy-attack-01.wav",
		"res/sounds/enemy-attack-02.wav",
		"res/sounds/enemy-attack-03.wav",
		"res/sounds/enemy-attack-04.wav",
		"res/sounds/enemy-attack-05.wav",
	},
	.Enemy_Die        = {
		"res/sounds/enemy-die-01.wav",
		"res/sounds/enemy-die-02.wav",
		"res/sounds/enemy-die-03.wav",
	},
}

// Pixels per audio unit. One hex pitch (1.5 × HEX_SIZE = 72) is a reasonable
// "1 meter" — at the default linear rolloff that gives us a few-hex audible
// radius before max_distance silence kicks in.
AUDIO_PIXELS_PER_UNIT :: f32(72)
AUDIO_MIN_DISTANCE    :: f32(1)   // full volume within 1 unit (one hex)
AUDIO_MAX_DISTANCE    :: f32(14)  // silent past 14 units (~14 hexes ≈ off-screen by a comfortable margin)
AUDIO_ROLLOFF         :: f32(1.0)

// One in-flight positional voice. `kind` lets us count concurrents per family
// without re-walking the heap-allocated sound to ask miniaudio.
Active_Voice :: struct {
	sound: ^ma.sound,
	kind:  game.Sound,
}

Audio :: struct {
	engine:      ma.engine,
	ready:       bool,
	// Null-terminated paths to hand to miniaudio. Built once at init so
	// audio_play is allocation-free at the call site.
	cpaths:      [game.Sound][dynamic]cstring,
	last_played: [game.Sound]time.Tick,
	// In-flight positional voices. Each entry was allocated by `audio_play_at`;
	// we sweep these once per frame and uninit + free any that have reached
	// their end. Per-family count is the concurrent-voice cap input.
	active:      [dynamic]Active_Voice,
}

audio_init :: proc(a: ^Audio) -> bool {
	if res := ma.engine_init(nil, &a.engine); res != .SUCCESS {
		fmt.eprintfln("audio: engine_init failed (%v)", res)
		return false
	}
	for variants, sound in SOUND_FILES {
		for path in variants {
			append(&a.cpaths[sound], strings.clone_to_cstring(path))
		}
	}
	a.ready = true
	return true
}

audio_shutdown :: proc(a: ^Audio) {
	if !a.ready do return
	// Stop and free any still-playing positional instances before tearing down
	// the engine. miniaudio asserts if a sound outlives its engine.
	for v in a.active {
		ma.sound_uninit(v.sound)
		free(v.sound)
	}
	delete(a.active)
	ma.engine_uninit(&a.engine)
	for variants in &a.cpaths {
		for cs in variants do delete(cs)
		delete(variants)
	}
	a.ready = false
}

audio_set_master_volume :: proc(a: ^Audio, v: f32) {
	if !a.ready do return
	ma.engine_set_volume(&a.engine, v)
}

// Listener tracks the game's camera position. World pixels are scaled into
// audio units so distances make sense at our chosen falloff curve.
audio_set_listener :: proc(a: ^Audio, x_px, y_px: f32) {
	if !a.ready do return
	x := x_px / AUDIO_PIXELS_PER_UNIT
	z := y_px / AUDIO_PIXELS_PER_UNIT
	ma.engine_listener_set_position(&a.engine, 0, x, 0, z)
}

// Sweep finished positional sounds. Cheap — miniaudio's `sound_at_end` is a
// flag read, and the active list is typically a handful of entries.
audio_tick :: proc(a: ^Audio) {
	if !a.ready do return
	for i := len(a.active) - 1; i >= 0; i -= 1 {
		v := a.active[i]
		if bool(ma.sound_at_end(v.sound)) {
			ma.sound_uninit(v.sound)
			free(v.sound)
			unordered_remove(&a.active, i)
		}
	}
}

@(private="file")
voices_of :: proc(a: ^Audio, kind: game.Sound) -> i32 {
	n: i32 = 0
	for v in a.active do if v.kind == kind do n += 1
	return n
}

@(private="file")
pick_variant :: proc(variants: [dynamic]cstring) -> (cstring, bool) {
	if len(variants) == 0 do return nil, false
	idx := 0 if len(variants) == 1 else rand.int_max(len(variants))
	return variants[idx], true
}

// Non-spatial play. Honors the per-family cooldown table.
audio_play :: proc(a: ^Audio, sound: game.Sound) {
	if !a.ready do return
	path, ok := pick_variant(a.cpaths[sound])
	if !ok do return

	now := time.tick_now()
	min_iv := SOUND_MIN_INTERVAL[sound]
	if min_iv > 0 && time.tick_diff(a.last_played[sound], now) < min_iv do return
	a.last_played[sound] = now

	// MA_SOUND_FLAG_NO_SPATIALIZATION skips the panner entirely — UI sounds
	// should be dead-centre regardless of where the listener is.
	_ = ma.engine_play_sound(&a.engine, path, nil)
}

// Spatial play. The sound is positioned at (x_px, y_px) in world-pixel space,
// shares the engine's resource-manager cache for the underlying wav, and is
// freed once it finishes (via `audio_tick`). Gated by two limits so spam
// can't pile up: a per-family cooldown (no two plays of the same family
// within `SOUND_MIN_INTERVAL`) and a per-family concurrent-voice cap (no more
// than `SOUND_MAX_VOICES` copies ringing out at once).
audio_play_at :: proc(a: ^Audio, sound: game.Sound, x_px, y_px: f32) {
	if !a.ready do return
	path, ok := pick_variant(a.cpaths[sound])
	if !ok do return

	now := time.tick_now()
	min_iv := SOUND_MIN_INTERVAL[sound]
	if min_iv > 0 && time.tick_diff(a.last_played[sound], now) < min_iv do return

	max_voices := SOUND_MAX_VOICES[sound]
	if max_voices > 0 && voices_of(a, sound) >= max_voices do return

	s := new(ma.sound)
	flags := ma.sound_flags{.NO_PITCH}
	if res := ma.sound_init_from_file(&a.engine, path, flags, nil, nil, s); res != .SUCCESS {
		free(s)
		return
	}
	a.last_played[sound] = now
	// Linear falloff inside [min, max]; silent past max. World y maps to z so
	// the X axis remains the left/right panning axis.
	x := x_px / AUDIO_PIXELS_PER_UNIT
	z := y_px / AUDIO_PIXELS_PER_UNIT
	ma.sound_set_attenuation_model(s, .linear)
	ma.sound_set_min_distance(s, AUDIO_MIN_DISTANCE)
	ma.sound_set_max_distance(s, AUDIO_MAX_DISTANCE)
	ma.sound_set_rolloff(s, AUDIO_ROLLOFF)
	ma.sound_set_position(s, x, 0, z)
	if res := ma.sound_start(s); res != .SUCCESS {
		ma.sound_uninit(s)
		free(s)
		return
	}
	append(&a.active, Active_Voice{sound = s, kind = sound})
}
