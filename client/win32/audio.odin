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
	.Emp              = 0,
	.Sell             = 0,
	.Repair           = 0,
	.Upgrade          = 0,
	.Flak_Cannon_Loop = 0,
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
	.Emp              = 0, // UI-style one-shot; no positional plays
	.Sell             = 0,
	.Repair           = 0,
	.Upgrade          = 0,
	.Flak_Cannon_Loop = 0, // managed via set_sound_loop, not the active-voice pool
}

// Per-family gain multiplier applied at play time. Source wavs were mixed at
// different levels, so this is the per-sound calibration knob — bump or cut
// here by ear rather than re-encoding the asset. 1.0 = unchanged.
@(private="file")
SOUND_GAIN := [game.Sound]f32{
	.None             = 1.0,
	.Button_Hover     = 0.3,
	.Button_Click     = 0.3,
	.Place_Building   = 3.0,
	.Building_Explode = 1.0,
	.Turret_Shoot     = 1.0,
	.Enemy_Attack     = 1.0,
	.Enemy_Die        = 1.0,
	.Emp              = 1.0,
	.Sell             = 1.0,
	.Repair           = 1.0,
	.Upgrade          = 1.0,
	.Flak_Cannon_Loop = 1.0,
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
		"res/sounds/blue_laser_1.wav",
		"res/sounds/blue_laser_2.wav",
		"res/sounds/blue_laser_3.wav",
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
	.Emp              = {"res/sounds/emp-sound.wav"},
	.Sell             = {"res/sounds/sell-sound.wav"},
	.Repair           = {"res/sounds/repair-sound.wav"},
	.Upgrade          = {"res/sounds/ugrade-sound.wav"},
	.Flak_Cannon_Loop = {"res/sounds/flack_cannon.wav"},
}

// Music tracks. miniaudio decodes mp3 natively, and we stream them from disk
// (the .STREAM flag) so a 3-minute track costs a small ring buffer rather than
// ~30 MB of decoded PCM.
@(private="file")
MUSIC_FILES := []string{
	"res/sounds/music-01.mp3",
	"res/sounds/music-02.mp3",
	"res/sounds/music-03.mp3",
}

// Crossfade duration between consecutive tracks. Also used as the lead time
// when scheduling the next track — we start the incoming track this many ms
// before the current one ends so the fades overlap exactly.
@(private="file")
MUSIC_CROSSFADE_MS :: u64(3000)

@(private="file")
MUSIC_DEFAULT_VOLUME :: f32(0.5)

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
	// Looped voices, one per family. Started/stopped on transition by
	// `audio_set_loop`; null entries mean "not currently playing".
	loops:       [game.Sound]^ma.sound,
	music:       Music,
}

// Background music with shuffled track order and crossfades on transition.
// During a crossfade both `current` and `incoming` are live and the older one
// is uninited once it finishes its fade-out; the rest of the time `incoming`
// is nil. `bag` holds the indices of tracks not yet played in this shuffle
// round; when it empties we refill and reshuffle, swapping the first two
// entries if the leading track would repeat the one we just finished.
Music :: struct {
	enabled:  bool,
	volume:   f32,
	cpaths:   [dynamic]cstring,
	bag:      [dynamic]int,
	last_idx: int,
	current:  ^ma.sound,
	incoming: ^ma.sound,
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
	for path in MUSIC_FILES {
		append(&a.music.cpaths, strings.clone_to_cstring(path))
	}
	a.music.volume   = MUSIC_DEFAULT_VOLUME
	a.music.last_idx = -1
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
	// Tear down any still-running looped voices.
	for s, kind in a.loops {
		if s == nil do continue
		ma.sound_uninit(s)
		free(s)
		a.loops[kind] = nil
	}
	if a.music.current != nil {
		ma.sound_uninit(a.music.current)
		free(a.music.current)
		a.music.current = nil
	}
	if a.music.incoming != nil {
		ma.sound_uninit(a.music.incoming)
		free(a.music.incoming)
		a.music.incoming = nil
	}
	for cs in a.music.cpaths do delete(cs)
	delete(a.music.cpaths)
	delete(a.music.bag)
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
	music_tick(a)
}

// Enable or disable the music shuffle. On enable the first track fades in;
// on disable the current track (and any in-progress incoming) fades out and
// is freed.
audio_set_music_enabled :: proc(a: ^Audio, on: bool) {
	if !a.ready do return
	if a.music.enabled == on do return
	a.music.enabled = on
	if !on {
		if a.music.current != nil {
			ma.sound_set_fade_in_milliseconds(a.music.current, -1, 0, MUSIC_CROSSFADE_MS)
			ma.sound_uninit(a.music.current) // miniaudio finishes the fade-out internally before freeing
			free(a.music.current)
			a.music.current = nil
		}
		if a.music.incoming != nil {
			ma.sound_uninit(a.music.incoming)
			free(a.music.incoming)
			a.music.incoming = nil
		}
	}
}

audio_set_music_volume :: proc(a: ^Audio, v: f32) {
	if !a.ready do return
	a.music.volume = v
	// Apply to whichever voice isn't currently inside an automated fade.
	// `set_volume` overrides the fade target; we only touch `current` here
	// because `incoming` is mid-fade-in and will land on its own target.
	if a.music.current != nil && a.music.incoming == nil {
		ma.sound_set_volume(a.music.current, v)
	}
}

// Pick the next track index from the shuffle bag, refilling when empty.
// Ensures the lead track of a fresh bag isn't the same one we just finished.
@(private="file")
music_pick :: proc(m: ^Music) -> (int, bool) {
	if len(m.cpaths) == 0 do return 0, false
	if len(m.bag) == 0 {
		for i in 0..<len(m.cpaths) do append(&m.bag, i)
		rand.shuffle(m.bag[:])
		if len(m.bag) > 1 && m.bag[len(m.bag)-1] == m.last_idx {
			m.bag[len(m.bag)-1], m.bag[0] = m.bag[0], m.bag[len(m.bag)-1]
		}
	}
	idx := pop(&m.bag)
	m.last_idx = idx
	return idx, true
}

// Start a new music voice fading in 0 → music.volume over `fade_ms`.
@(private="file")
music_start :: proc(a: ^Audio, fade_ms: u64) -> ^ma.sound {
	idx, ok := music_pick(&a.music)
	if !ok do return nil
	s := new(ma.sound)
	flags := ma.sound_flags{.STREAM, .NO_PITCH, .NO_SPATIALIZATION}
	if res := ma.sound_init_from_file(&a.engine, a.music.cpaths[idx], flags, nil, nil, s); res != .SUCCESS {
		free(s)
		return nil
	}
	ma.sound_set_volume(s, a.music.volume)
	ma.sound_set_fade_in_milliseconds(s, 0, a.music.volume, fade_ms)
	if res := ma.sound_start(s); res != .SUCCESS {
		ma.sound_uninit(s)
		free(s)
		return nil
	}
	return s
}

@(private="file")
music_tick :: proc(a: ^Audio) {
	m := &a.music
	if !m.enabled do return

	// Promote a finished outgoing track once its crossfade has elapsed and
	// playback has actually stopped. `sound_is_playing` flips false on its
	// own when the stream hits EOF.
	if m.incoming != nil && m.current != nil && !bool(ma.sound_is_playing(m.current)) {
		ma.sound_uninit(m.current)
		free(m.current)
		m.current = m.incoming
		m.incoming = nil
	}

	// Cold start: no track yet, just begin one.
	if m.current == nil {
		m.current = music_start(a, MUSIC_CROSSFADE_MS)
		return
	}

	// Already crossfading — nothing more to schedule until it resolves.
	if m.incoming != nil do return

	// Schedule the next track when the current one is within one crossfade
	// of finishing. Streams can briefly report length == 0 while the header
	// is still being read — skip until we have a real duration.
	cursor: f32
	length: f32
	if ma.sound_get_cursor_in_seconds(m.current, &cursor) != .SUCCESS do return
	if ma.sound_get_length_in_seconds(m.current, &length) != .SUCCESS do return
	if length <= 0 do return

	remaining_ms := u64(max(0, (length - cursor)) * 1000)
	if remaining_ms <= MUSIC_CROSSFADE_MS {
		ma.sound_set_fade_in_milliseconds(m.current, -1, 0, MUSIC_CROSSFADE_MS)
		m.incoming = music_start(a, MUSIC_CROSSFADE_MS)
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

// Start or stop a single looped, spatial voice for `sound`. Idempotent on
// both edges so the game can drive this from a per-frame "is anything still
// firing?" bool without tracking transitions. Position is in world pixels
// (same space as `audio_play_at`) and re-applied every call while the loop is
// active, so the emitter can drift as the game's centroid moves without
// restarting the sound.
audio_set_loop :: proc(a: ^Audio, sound: game.Sound, active: bool, x_px, y_px: f32) {
	if !a.ready do return
	playing := a.loops[sound] != nil
	if !active {
		if !playing do return
		s := a.loops[sound]
		ma.sound_uninit(s)
		free(s)
		a.loops[sound] = nil
		return
	}
	x := x_px / AUDIO_PIXELS_PER_UNIT
	z := y_px / AUDIO_PIXELS_PER_UNIT
	if !playing {
		path, ok := pick_variant(a.cpaths[sound])
		if !ok do return
		s := new(ma.sound)
		flags := ma.sound_flags{.NO_PITCH}
		if res := ma.sound_init_from_file(&a.engine, path, flags, nil, nil, s); res != .SUCCESS {
			free(s)
			return
		}
		ma.sound_set_looping(s, true)
		// Same linear-falloff envelope as the one-shot positional path, so a
		// looped emitter has the same audible radius as a fired-once sound at
		// the same spot.
		ma.sound_set_attenuation_model(s, .linear)
		ma.sound_set_min_distance(s, AUDIO_MIN_DISTANCE)
		ma.sound_set_max_distance(s, AUDIO_MAX_DISTANCE)
		ma.sound_set_rolloff(s, AUDIO_ROLLOFF)
		ma.sound_set_position(s, x, 0, z)
		ma.sound_set_volume(s, SOUND_GAIN[sound])
		if res := ma.sound_start(s); res != .SUCCESS {
			ma.sound_uninit(s)
			free(s)
			return
		}
		a.loops[sound] = s
	} else {
		ma.sound_set_position(a.loops[sound], x, 0, z)
	}
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

	// Managed sound (rather than engine_play_sound) so we can apply the per-
	// family gain via sound_set_volume. NO_SPATIALIZATION skips the panner —
	// UI sounds should be dead-centre regardless of where the listener is.
	s := new(ma.sound)
	flags := ma.sound_flags{.NO_PITCH, .NO_SPATIALIZATION}
	if res := ma.sound_init_from_file(&a.engine, path, flags, nil, nil, s); res != .SUCCESS {
		free(s)
		return
	}
	ma.sound_set_volume(s, SOUND_GAIN[sound])
	if res := ma.sound_start(s); res != .SUCCESS {
		ma.sound_uninit(s)
		free(s)
		return
	}
	append(&a.active, Active_Voice{sound = s, kind = sound})
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
	ma.sound_set_volume(s, SOUND_GAIN[sound])
	if res := ma.sound_start(s); res != .SUCCESS {
		ma.sound_uninit(s)
		free(s)
		return
	}
	append(&a.active, Active_Voice{sound = s, kind = sound})
}
