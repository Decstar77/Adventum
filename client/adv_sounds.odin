package main

import "core:fmt"
import "core:math/rand"
import "core:strings"

import fmod "fmod/core"

PLAY_SOUNDS :: true

fmodSystem: ^fmod.SYSTEM

music1: ^fmod.SOUND
music2: ^fmod.SOUND

sounds: [128]^fmod.SOUND

SoundId :: enum {
	nil,
	scout_sir_1,
}

play_sound :: proc(soundId: SoundId, volume: f32 = 0.1) {
	if (PLAY_SOUNDS == false) {
		return
	}

	assert(soundId != nil)
	channel: ^fmod.CHANNEL
	fmod.System_PlaySound(fmodSystem, sounds[soundId], nil, false, &channel)
	fmod.Channel_SetVolume(channel, volume)
}

play_sound_rand :: proc(sounds: []SoundId, volume: f32 = 0.1) {
	sound := rand.choice(sounds[:])
	play_sound(sound, volume)
}

init_audio :: proc() {
	fmod.System_Create(&fmodSystem, fmod.VERSION)
	fmod.System_Init(fmodSystem, 100, fmod.INIT_NORMAL, nil)
	// fmod.System_Set3DSettings(fmodAudio, 1.0, DISTANCEFACTOR, 1.0)

	soundDir := "res/sounds/"

	for name, id in SoundId {
		if (id == 0) {continue}
		path := fmt.tprint(soundDir, name, ".wav", sep = "")
		// fmt.println(path)
		cpath := strings.clone_to_cstring(path)
		fmod.System_CreateSound(fmodSystem, cpath, fmod.MODE_2D, nil, &sounds[id])
	}


	fmod.System_CreateSound(
		fmodSystem,
		"res/sounds/music_battle_1.ogg",
		fmod.MODE_2D,
		nil,
		&music1,
	)
	fmod.System_CreateSound(
		fmodSystem,
		"res/sounds/music_battle_2.ogg",
		fmod.MODE_2D,
		nil,
		&music2,
	)

	channel: ^fmod.CHANNEL
	fmod.System_PlaySound(fmodSystem, music2, nil, false, &channel)
	fmod.Channel_SetVolume(channel, 0.05)

	// channel1: ^fmod.CHANNEL
	// channel2: ^fmod.CHANNEL
	// fmod.System_PlaySound(fmodSystem, sound2, nil, false, &channel2)
}

audio_update :: proc() {
	fmod.System_Update(fmodSystem)
}

audio_shutdown :: proc() {
	fmod.System_Close(fmodSystem)
	fmod.System_Release(fmodSystem)
}
