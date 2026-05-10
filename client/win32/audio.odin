package main

// Audio backend for the win32 host. Wraps miniaudio (vendor:miniaudio) with a
// tiny family-of-variants layer: each `game.Sound` maps to one or more `.wav`
// files under `res/sounds/`, and a play call picks one variant uniformly at
// random. Playback is fire-and-forget via `engine_play_sound`; miniaudio's
// built-in resource manager caches the decoded audio so repeated plays don't
// re-decode the file.
//
// `audio_set_master_volume` is called once per frame from the platform shim
// and forwarded to the engine's master volume bus, so the pause-menu slider
// updates take effect immediately.

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:time"
import ma "vendor:miniaudio"

import "../game"

// Minimum gap between consecutive plays of the same family. Catches rapid
// re-fires that the per-frame coalescer in `game_update_and_render` can't
// see — e.g. one turret salvo per tick, two ticks landing in adjacent frames.
// Buttons and place are 0 ms so the response stays snappy.
@(private="file")
SOUND_MIN_INTERVAL := [game.Sound]time.Duration{
	.None             = 0,
	.Button_Hover     = 50  * time.Millisecond,
	.Button_Click     = 0,
	.Place_Building   = 0,
	.Building_Explode = 60  * time.Millisecond,
	.Turret_Shoot     = 60  * time.Millisecond,
	.Enemy_Attack     = 80  * time.Millisecond,
	.Enemy_Die        = 60  * time.Millisecond,
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

Audio :: struct {
	engine:      ma.engine,
	ready:       bool,
	// We need null-terminated paths to hand to miniaudio. Build them once at
	// init so play_sound is allocation-free at the call site.
	cpaths:      [game.Sound][dynamic]cstring,
	last_played: [game.Sound]time.Tick,
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

audio_play :: proc(a: ^Audio, sound: game.Sound) {
	if !a.ready do return
	variants := a.cpaths[sound]
	if len(variants) == 0 do return

	// Per-family cooldown gate. Drop the call if the last play of this family
	// was too recent — keeps adjacent-frame stacking from re-introducing the
	// "wall of shots" the per-frame coalescer just suppressed.
	now := time.tick_now()
	min_iv := SOUND_MIN_INTERVAL[sound]
	if min_iv > 0 && time.tick_diff(a.last_played[sound], now) < min_iv do return
	a.last_played[sound] = now

	idx := 0 if len(variants) == 1 else rand.int_max(len(variants))
	// Result is intentionally ignored: a missing file or a transient device
	// hiccup shouldn't take the game down.
	_ = ma.engine_play_sound(&a.engine, variants[idx], nil)
}
