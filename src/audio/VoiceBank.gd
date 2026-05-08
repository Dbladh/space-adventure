class_name VoiceBank
extends RefCounted

# VoiceBank.gd
# 12 synth voice presets used by the arp engines.
# Each voice has its own oscillator combination + envelope shape.
# fill() is the single entry point — dispatches to the chosen voice's
# inner loop, which keeps the hot path tight (no per-sample dict lookups).

const VOICE_PLUCK_SAW   := 0
const VOICE_BELL        := 1
const VOICE_FM_BELL     := 2
const VOICE_SUPERSAW    := 3
const VOICE_SQUARE_LEAD := 4
const VOICE_SINE_FLUTE  := 5
const VOICE_MARIMBA     := 6
const VOICE_SOFT_PAD    := 7
const VOICE_GLASS_PAD   := 8
const VOICE_DETUNED_TRI := 9
const VOICE_CHIME       := 10
const VOICE_ORGAN       := 11

const VOICE_COUNT := 12

const _NAMES := [
	"PluckSaw", "Bell", "FMBell", "Supersaw", "SquareLead", "SineFlute",
	"Marimba", "SoftPad", "GlassPad", "DetunedTri", "Chime", "Organ"
]

func name_of(voice_id: int) -> String:
	if voice_id < 0 or voice_id >= VOICE_COUNT:
		return "Unknown"
	return _NAMES[voice_id]

# Per-voice envelope shape: maps the master 0..1 envelope into a voice-appropriate curve.
# Pluck/lead voices stay linear; bell/chime use sqrt for long tails; pads use ease-out.
func _shape_env(voice_id: int, env: float) -> float:
	match voice_id:
		VOICE_BELL, VOICE_FM_BELL, VOICE_CHIME:
			return sqrt(env)
		VOICE_SINE_FLUTE, VOICE_SOFT_PAD, VOICE_GLASS_PAD:
			return env * (2.0 - env)
		VOICE_MARIMBA:
			return env * env
	return env

# ctx fields (mutated where noted):
#   freq, env, vol, pan_l, pan_r, sample_rate, filt        — read each call
#   sin_table, noise_table                                  — references
#   phase, phase2, phase3, lfo_phase                        — persistent (mutated)
func fill(voice_id: int, playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int) -> void:
	var shaped_env := _shape_env(voice_id, float(ctx["env"]))
	var vol := float(ctx["vol"]) * shaped_env
	if vol < 0.0005:
		for i in frames:
			playback.push_frame(Vector2.ZERO)
		return

	match voice_id:
		VOICE_PLUCK_SAW:    _fill_pluck_saw(playback, ctx, frames, vol)
		VOICE_BELL:         _fill_bell(playback, ctx, frames, vol)
		VOICE_FM_BELL:      _fill_fm_bell(playback, ctx, frames, vol)
		VOICE_SUPERSAW:     _fill_supersaw(playback, ctx, frames, vol)
		VOICE_SQUARE_LEAD:  _fill_square_lead(playback, ctx, frames, vol)
		VOICE_SINE_FLUTE:   _fill_sine_flute(playback, ctx, frames, vol)
		VOICE_MARIMBA:      _fill_marimba(playback, ctx, frames, vol)
		VOICE_SOFT_PAD:     _fill_soft_pad(playback, ctx, frames, vol)
		VOICE_GLASS_PAD:    _fill_glass_pad(playback, ctx, frames, vol)
		VOICE_DETUNED_TRI:  _fill_detuned_tri(playback, ctx, frames, vol)
		VOICE_CHIME:        _fill_chime(playback, ctx, frames, vol)
		VOICE_ORGAN:        _fill_organ(playback, ctx, frames, vol)
		_:                  _fill_pluck_saw(playback, ctx, frames, vol)

# =====================================================================
#  VOICE FILLERS
#  Each pulls phase state from ctx, runs a tight loop, writes back.
# =====================================================================

func _fill_pluck_saw(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var tbl: PackedFloat32Array = ctx["sin_table"]
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	var filt := float(ctx.get("filt", 1.0))
	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)
		var saw  := phase * 2.0 - 1.0
		var sine := tbl[int(phase * 256.0) & 255]
		var s    := (saw * 0.25 + sine * 0.75) * vol * filt
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase

func _fill_bell(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var tbl: PackedFloat32Array = ctx["sin_table"]
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)
		var s1 := tbl[int(phase * 256.0) & 255]
		var s2 := tbl[int(phase * 512.0) & 255]   # 2nd harmonic via phase trick
		var s  := (s1 * 0.7 + s2 * 0.3) * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase

func _fill_fm_bell(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var phase2 := float(ctx.get("phase2", 0.0))
	var tbl: PackedFloat32Array = ctx["sin_table"]
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	var mod_freq := freq * 3.0
	var mod_index := 0.7   # phase modulation depth in fractional cycles
	for i in frames:
		phase2 = fmod(phase2 + mod_freq * inv_r, 1.0)
		var modv := tbl[int(phase2 * 256.0) & 255] * mod_index
		var p := fmod(phase + modv, 1.0)
		if p < 0.0:
			p += 1.0
		var s := tbl[int(p * 256.0) & 255] * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
		phase = fmod(phase + freq * inv_r, 1.0)
	ctx["phase"] = phase
	ctx["phase2"] = phase2

func _fill_supersaw(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var phase2 := float(ctx.get("phase2", 0.0))
	var phase3 := float(ctx.get("phase3", 0.0))
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	var f1 := freq * 0.995
	var f2 := freq
	var f3 := freq * 1.005
	for i in frames:
		var saw1 := phase  * 2.0 - 1.0
		var saw2 := phase2 * 2.0 - 1.0
		var saw3 := phase3 * 2.0 - 1.0
		var s := (saw1 + saw2 + saw3) * 0.30 * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
		phase  = fmod(phase  + f1 * inv_r, 1.0)
		phase2 = fmod(phase2 + f2 * inv_r, 1.0)
		phase3 = fmod(phase3 + f3 * inv_r, 1.0)
	ctx["phase"] = phase
	ctx["phase2"] = phase2
	ctx["phase3"] = phase3

func _fill_square_lead(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	var filt := float(ctx.get("filt", 1.0))
	var duty := 0.3
	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)
		var sq := -1.0 if phase < duty else 1.0
		var s := sq * 0.45 * vol * filt
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase

func _fill_sine_flute(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var lfo := float(ctx.get("lfo_phase", 0.0))
	var tbl: PackedFloat32Array = ctx["sin_table"]
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	for i in frames:
		lfo = fmod(lfo + 6.0 * inv_r, 1.0)
		var vib := tbl[int(lfo * 256.0) & 255] * 0.015
		phase = fmod(phase + freq * (1.0 + vib) * inv_r, 1.0)
		var s := tbl[int(phase * 256.0) & 255] * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase
	ctx["lfo_phase"] = lfo

func _fill_marimba(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var tbl: PackedFloat32Array = ctx["sin_table"]
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)
		var fund := tbl[int(phase * 256.0) & 255]
		var h4   := tbl[int(phase * 1024.0) & 255]
		var h8   := tbl[int(phase * 2048.0) & 255]
		var s := (fund * 0.6 + h4 * 0.3 + h8 * 0.1) * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase

func _fill_soft_pad(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var phase2 := float(ctx.get("phase2", 0.0))
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	var f1 := freq
	var f2 := freq * 1.005
	for i in frames:
		phase  = fmod(phase  + f1 * inv_r, 1.0)
		phase2 = fmod(phase2 + f2 * inv_r, 1.0)
		var t1 := 1.0 - absf(fmod(phase  + 0.25, 1.0) * 4.0 - 2.0)
		var t2 := 1.0 - absf(fmod(phase2 + 0.25, 1.0) * 4.0 - 2.0)
		var s := (t1 * 0.6 + t2 * 0.4) * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase
	ctx["phase2"] = phase2

func _fill_glass_pad(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var phase2 := float(ctx.get("phase2", 0.0))
	var phase3 := float(ctx.get("phase3", 0.0))
	var tbl: PackedFloat32Array = ctx["sin_table"]
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	var f1 := freq
	var f2 := freq * 3.01
	var f3 := freq * 5.02
	for i in frames:
		phase  = fmod(phase  + f1 * inv_r, 1.0)
		phase2 = fmod(phase2 + f2 * inv_r, 1.0)
		phase3 = fmod(phase3 + f3 * inv_r, 1.0)
		var s1 := tbl[int(phase  * 256.0) & 255]
		var s2 := tbl[int(phase2 * 256.0) & 255] * 0.40
		var s3 := tbl[int(phase3 * 256.0) & 255] * 0.20
		var s  := (s1 + s2 + s3) * 0.5 * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase
	ctx["phase2"] = phase2
	ctx["phase3"] = phase3

func _fill_detuned_tri(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var phase2 := float(ctx.get("phase2", 0.0))
	var phase3 := float(ctx.get("phase3", 0.0))
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	var f1 := freq * 0.996
	var f2 := freq
	var f3 := freq * 1.004
	for i in frames:
		phase  = fmod(phase  + f1 * inv_r, 1.0)
		phase2 = fmod(phase2 + f2 * inv_r, 1.0)
		phase3 = fmod(phase3 + f3 * inv_r, 1.0)
		var t1 := 1.0 - absf(fmod(phase  + 0.25, 1.0) * 4.0 - 2.0)
		var t2 := 1.0 - absf(fmod(phase2 + 0.25, 1.0) * 4.0 - 2.0)
		var t3 := 1.0 - absf(fmod(phase3 + 0.25, 1.0) * 4.0 - 2.0)
		var s := (t1 + t2 + t3) * 0.30 * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase
	ctx["phase2"] = phase2
	ctx["phase3"] = phase3

func _fill_chime(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var phase2 := float(ctx.get("phase2", 0.0))
	var tbl: PackedFloat32Array = ctx["sin_table"]
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	var f1 := freq
	var f2 := freq * 2.76    # inharmonic partial → bell-like timbre
	for i in frames:
		phase  = fmod(phase  + f1 * inv_r, 1.0)
		phase2 = fmod(phase2 + f2 * inv_r, 1.0)
		var s1 := tbl[int(phase  * 256.0) & 255]
		var s2 := tbl[int(phase2 * 256.0) & 255] * 0.45
		var s  := (s1 + s2) * 0.6 * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase
	ctx["phase2"] = phase2

func _fill_organ(playback: AudioStreamGeneratorPlayback, ctx: Dictionary, frames: int, vol: float) -> void:
	var freq := float(ctx["freq"])
	var inv_r := 1.0 / float(ctx["sample_rate"])
	var phase := float(ctx["phase"])
	var tbl: PackedFloat32Array = ctx["sin_table"]
	var pan_l := float(ctx["pan_l"])
	var pan_r := float(ctx["pan_r"])
	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)
		var s1 := tbl[int(phase * 256.0) & 255]
		var s2 := tbl[int(phase * 512.0) & 255] * 0.5
		var s3 := tbl[int(phase * 768.0) & 255] * 0.33
		var s  := (s1 + s2 + s3) * 0.55 * vol
		playback.push_frame(Vector2(s * pan_l, s * pan_r))
	ctx["phase"] = phase
