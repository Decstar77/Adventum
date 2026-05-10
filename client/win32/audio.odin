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
import ma "vendor:miniaudio"

import "../game"

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
	engine:    ma.engine,
	ready:     bool,
	// We need null-terminated paths to hand to miniaudio. Build them once at
	// init so play_sound is allocation-free at the call site.
	cpaths:    [game.Sound][dynamic]cstring,
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
	idx := 0 if len(variants) == 1 else rand.int_max(len(variants))
	// Result is intentionally ignored: a missing file or a transient device
	// hiccup shouldn't take the game down.
	_ = ma.engine_play_sound(&a.engine, variants[idx], nil)
}
