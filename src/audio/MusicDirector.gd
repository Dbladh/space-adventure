extends Node

# MusicDirector.gd
# Managed by THE COMPOSER.
# Procedural ambient synthwave music that reacts to gameplay state.
#
# ARCHITECTURE: Chord-driven procedural synth
#   - Chord progression clock: 4–8 second chords that both voices follow
#   - Bass voice: melodic root notes with portamento + detuned pad layer
#   - Arp voice: triadic note pool from current chord, soft saw-sine blend
#   - Audio bus effects (Reverb + LowPass) modulated by game state
#
# PERFORMANCE BUDGET: <0.5ms/frame on A14-class mobile
#   - Game state polled at 4Hz (music doesn't need 60Hz precision)
#   - 256-entry sine lookup table (no trig in fill loop)
#   - 22050Hz sample rate on mobile, 44100Hz desktop
#   - Per-buffer LFO (computed once, not per-sample)
#   - Max 1024 frames per fill call to cap worst-case spikes
#
# MUSICAL DESIGN: Five reactive states with shared harmonic structure
#   DEEP_SPACE  — very slow chords, sparse arp, pentatonic, heavy reverb
#   CRUISING    — speed drives filter + arp density, pad thickens
#   ATMOSPHERE  — Phrygian mode, wider pad, deeper reverb
#   SURFACE     — Dorian mode, warmer tone, moderate arp
#   COMBAT      — tense minor, faster chords, filter wide open

# =====================================================================
#  GAME STATE MACHINE
# =====================================================================

enum MusicState { DEEP_SPACE, CRUISING, ATMOSPHERE, SURFACE, COMBAT }

var current_state: int = MusicState.DEEP_SPACE

# =====================================================================
#  PLAYER STATE CACHE (refreshed at 4Hz)
# =====================================================================

var _ship_speed: float = 0.0
var _altitude: float = 300000.0
var _is_warping: bool = false
var _is_in_atmo: bool = false
var _is_on_surface: bool = false
var _combat_tension: float = 0.0   # 0.0 = peaceful, 1.0 = heavy combat

# =====================================================================
#  AUDIO NODES
# =====================================================================

var _drone_player: AudioStreamPlayer
var _drone_playback: AudioStreamGeneratorPlayback
var _arp_player: AudioStreamPlayer
var _arp_playback: AudioStreamGeneratorPlayback

# =====================================================================
#  SYNTH ENGINE
# =====================================================================

var _sample_rate: float = 44100.0
var _mobile: bool = false

# Bass/pad oscillator phases
var _bass_phase_1: float = 0.0     # main bass tone
var _bass_phase_2: float = 0.0     # detuned pad layer
var _bass_phase_sub: float = 0.0   # sub-octave foundation
var _lfo_phase: float = 0.0        # slow amplitude modulation

# Arp oscillator
var _arp_phase: float = 0.0

# --- Current parameters (smoothly interpolated each frame) ---
var _bass_freq: float = 55.0        # Hz — current bass pitch (portamento target)
var _bass_freq_actual: float = 55.0  # Hz — actual sounding pitch (glides toward _bass_freq)
var _bass_detune: float = 1.003     # ratio — pad layer = bass * detune
var _bass_volume: float = 0.12
var _arp_volume: float = 0.02
var _filter_cutoff: float = 600.0   # simulated LP cutoff
var _reverb_mix: float = 0.5

# --- Target parameters (set at 4Hz, lerped toward) ---
var _target_bass_volume: float = 0.12
var _target_arp_volume: float = 0.02
var _target_filter_cutoff: float = 600.0
var _target_reverb_mix: float = 0.5

# =====================================================================
#  CHORD PROGRESSION SYSTEM
#  Both bass and arp draw from the same chord — this is what makes
#  them sound "together" instead of two independent random generators.
# =====================================================================

var _chord_timer: float = 0.0       # seconds since last chord change
var _chord_duration: float = 6.0    # seconds per chord (slow, evolving)
var _chord_index: int = 0           # position in current progression
var _chord_root_ratio: float = 1.0  # current chord's root as scale ratio
var _arp_note_pool: Array = [1.0]   # triad built from current chord

# Root note (Hz) — sets the tonal center for the entire piece
var _root_hz: float = 55.0          # A1
var _target_root_hz: float = 55.0

# =====================================================================
#  SCALES & PROGRESSIONS
#  Each state has a scale (note ratios) and a chord progression
#  (indices into that scale). The bass plays chord roots; the arp
#  picks from a triad built on that root.
# =====================================================================

# Pentatonic minor: root, m3, P4, P5, m7 — open, spacious
const SCALE_SPACE := [1.0, 1.189, 1.335, 1.498, 1.782]
# Chord progression: i → V → m7 → IV (indices into pentatonic)
const PROG_SPACE := [0, 3, 4, 2]

# Phrygian: root, b2, m3, P4, P5, b6, m7 — dark, mysterious
const SCALE_ATMO := [1.0, 1.059, 1.189, 1.335, 1.498, 1.587, 1.782]
# Progression: i → bVI → IV → bII
const PROG_ATMO := [0, 5, 3, 1]

# Dorian: root, M2, m3, P4, P5, M6, m7 — earthy, warm
const SCALE_SURFACE := [1.0, 1.122, 1.189, 1.335, 1.498, 1.682, 1.782]
# Progression: i → III → IV → VI
const PROG_SURFACE := [0, 2, 3, 5]

# Natural minor: root, M2, m3, P4, P5, m6, m7 — tense
const SCALE_COMBAT := [1.0, 1.122, 1.189, 1.335, 1.498, 1.587, 1.782]
# Progression: i → V → IV → III
const PROG_COMBAT := [0, 4, 3, 2]

# Root notes per state (Hz)
const ROOT_SPACE   := 55.0    # A1 — deep, open
const ROOT_CRUISE  := 55.0    # A1 — same root, intensity shifts
const ROOT_ATMO    := 65.41   # C2 — darker
const ROOT_SURFACE := 73.42   # D2 — earthy
const ROOT_COMBAT  := 61.74   # B1 — tense

# =====================================================================
#  ARPEGGIATOR
# =====================================================================

var _arp_tempo: float = 40.0       # BPM (much slower than before)
var _arp_step_timer: float = 0.0
var _arp_step_index: int = 0
var _arp_current_freq: float = 220.0
var _arp_envelope: float = 0.0     # attack-decay (1.0 → 0.0)
var _arp_rest: bool = false         # true = silence this step (breathing)
var _arp_direction: int = 1         # 1 = ascending, -1 = descending
var _arp_phrase_count: int = 0      # steps within current phrase

# =====================================================================
#  SINE LOOKUP TABLE (256 entries — avoids sin() in fill loop)
# =====================================================================

var _sin_table: PackedFloat32Array

# =====================================================================
#  STATE POLLING
# =====================================================================

var _poll_accum: float = 0.0
const _POLL_INTERVAL: float = 0.25  # 4Hz — musically sufficient
var _player: Node3D = null

# =====================================================================
#  STINGER (one-shot harmonic burst for mining / pickups)
# =====================================================================

var _stinger_phase: float = 0.0
var _stinger_freq: float = 440.0
var _stinger_env: float = 0.0       # decays to 0
var _stinger_vol: float = 0.15

# Max frames to fill per call — caps worst-case main-thread cost
const _MAX_FILL_FRAMES := 1024

# =====================================================================
#  INIT
# =====================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("MusicDirector")
	_mobile = OS.get_name() == "iOS" or OS.has_feature("mobile")
	_sample_rate = 22050.0 if _mobile else 44100.0

	# Build sine LUT
	_sin_table.resize(256)
	for i in 256:
		_sin_table[i] = sin(float(i) / 256.0 * TAU)

	# Setup audio bus first (nodes reference it)
	_setup_music_bus()

	# Bass/pad generator
	_drone_player = AudioStreamPlayer.new()
	_drone_player.bus = "Music"
	var drone_stream := AudioStreamGenerator.new()
	drone_stream.mix_rate = _sample_rate
	drone_stream.buffer_length = 0.15  # 150ms buffer — headroom for 30fps
	_drone_player.stream = drone_stream
	add_child(_drone_player)
	_drone_player.play()
	_drone_playback = _drone_player.get_stream_playback()

	# Arp generator
	_arp_player = AudioStreamPlayer.new()
	_arp_player.bus = "Music"
	var arp_stream := AudioStreamGenerator.new()
	arp_stream.mix_rate = _sample_rate
	arp_stream.buffer_length = 0.15
	_arp_player.stream = arp_stream
	add_child(_arp_player)
	_arp_player.play()
	_arp_playback = _arp_player.get_stream_playback()

	# Start first chord
	_advance_chord()

func _setup_music_bus() -> void:
	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		AudioServer.add_bus()
		bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_idx, "Music")
		AudioServer.set_bus_send(bus_idx, "Master")

	AudioServer.set_bus_volume_db(bus_idx, -8.0)

	# Reverb — large room, lots of tail for the spacey feel
	if AudioServer.get_bus_effect_count(bus_idx) == 0:
		var reverb := AudioEffectReverb.new()
		reverb.room_size = 0.88
		reverb.damping = 0.25
		reverb.spread = 0.9
		reverb.wet = 0.4
		reverb.dry = 0.6
		AudioServer.add_bus_effect(bus_idx, reverb)

	# Low-pass filter — tames harshness, modulated by game state
	if AudioServer.get_bus_effect_count(bus_idx) < 2:
		var lpf := AudioEffectLowPassFilter.new()
		lpf.cutoff_hz = 2000.0
		lpf.resonance = 1.5
		AudioServer.add_bus_effect(bus_idx, lpf)

# =====================================================================
#  MAIN LOOP
# =====================================================================

func _process(delta: float) -> void:
	# ── 4Hz state poll ───────────────────────────────────────────────
	_poll_accum += delta
	if _poll_accum >= _POLL_INTERVAL:
		_poll_accum = 0.0
		_poll_game_state()
		_update_music_targets()

	# ── Smooth parameter interpolation ───────────────────────────────
	var ls := 1.5 * delta   # slower lerp = smoother transitions
	_bass_volume   = lerp(_bass_volume,   _target_bass_volume,   ls)
	_arp_volume    = lerp(_arp_volume,    _target_arp_volume,    ls)
	_filter_cutoff = lerp(_filter_cutoff, _target_filter_cutoff, ls)
	_reverb_mix    = lerp(_reverb_mix,    _target_reverb_mix,    ls)
	_root_hz       = lerp(_root_hz,       _target_root_hz,       ls * 0.5)

	# Bass portamento: glide to target pitch over ~200ms
	_bass_freq_actual = lerp(_bass_freq_actual, _bass_freq, 5.0 * delta)

	# ── Chord progression clock ──────────────────────────────────────
	_chord_timer += delta
	if _chord_timer >= _chord_duration:
		_chord_timer -= _chord_duration
		_advance_chord()

	# ── Arpeggiator step clock (8th notes, not 16ths) ────────────────
	_arp_step_timer += delta
	var step_dur := 60.0 / _arp_tempo / 2.0   # 8th-note resolution (was /4.0 for 16ths)
	if _arp_step_timer >= step_dur:
		_arp_step_timer -= step_dur
		_advance_arp_step()

	# Decay envelopes — slower decay = notes ring longer
	_arp_envelope = maxf(_arp_envelope - delta * 2.5, 0.0)   # was 6.0
	_stinger_env  = maxf(_stinger_env  - delta * 4.0, 0.0)

	# ── Update audio bus effects ─────────────────────────────────────
	_update_bus_effects()

	# ── Fill audio buffers ───────────────────────────────────────────
	_fill_bass_buffer()
	_fill_arp_buffer()

# =====================================================================
#  CHORD PROGRESSION
# =====================================================================

func _get_scale() -> Array:
	match current_state:
		MusicState.ATMOSPHERE: return SCALE_ATMO
		MusicState.SURFACE:    return SCALE_SURFACE
		MusicState.COMBAT:     return SCALE_COMBAT
		_:                     return SCALE_SPACE

func _get_progression() -> Array:
	match current_state:
		MusicState.ATMOSPHERE: return PROG_ATMO
		MusicState.SURFACE:    return PROG_SURFACE
		MusicState.COMBAT:     return PROG_COMBAT
		_:                     return PROG_SPACE

func _advance_chord() -> void:
	var prog := _get_progression()
	var scale := _get_scale()

	_chord_index = (_chord_index + 1) % prog.size()
	var root_idx: int = prog[_chord_index]
	_chord_root_ratio = scale[root_idx]

	# Update bass target frequency: root note in octave 1-2
	# Octave 2 keeps it warm and present without muddying the sub range
	_bass_freq = _root_hz * _chord_root_ratio * 2.0   # octave 2

	# Build arp note pool: triad from chord root (root, 3rd, 5th within scale)
	# This is what locks arp + bass together harmonically.
	var s_len := scale.size()
	var idx_3rd := (root_idx + 2) % s_len   # skip one scale step = ~3rd
	var idx_5th := (root_idx + 4) % s_len   # skip three scale steps = ~5th
	_arp_note_pool = [
		scale[root_idx],
		scale[idx_3rd],
		scale[idx_5th],
	]

	# Occasionally add the octave of the root for wider range
	if randf() > 0.5:
		_arp_note_pool.append(scale[root_idx] * 2.0)

	# Reverse arp direction every other chord for melodic variety
	if _chord_index % 2 == 0:
		_arp_direction = 1
	else:
		_arp_direction = -1

# =====================================================================
#  GAME STATE POLLING (4Hz)
# =====================================================================

func _poll_game_state() -> void:
	if not _player or not is_instance_valid(_player):
		var players := get_tree().get_nodes_in_group("Player")
		if players.size() > 0:
			_player = players[0]
		if not _player:
			return

	# Read player state
	_ship_speed = _player.velocity.length() if _player is CharacterBody3D else 0.0

	var alt_val = _player.get("true_altitude")
	_altitude = alt_val if alt_val != null else 300000.0

	_is_warping    = _player.get("mobile_boost") == true or Input.is_key_pressed(KEY_SHIFT)
	_is_in_atmo    = _altitude < 26000.0
	_is_on_surface = _altitude < 3000.0

	# Combat tension: nearest enemy proximity (5 km = full tension)
	var enemies := get_tree().get_nodes_in_group("Enemy")
	var nearest := 999999.0
	for e in enemies:
		if is_instance_valid(e):
			nearest = minf(nearest, e.global_position.distance_to(_player.global_position))
	_combat_tension = clampf(1.0 - nearest / 5000.0, 0.0, 1.0)

	# Determine music state (priority: combat > surface > atmo > cruising > deep space)
	var new_state: int
	if _combat_tension > 0.3:
		new_state = MusicState.COMBAT
	elif _is_on_surface:
		new_state = MusicState.SURFACE
	elif _is_in_atmo:
		new_state = MusicState.ATMOSPHERE
	elif _ship_speed > 500.0 or _is_warping:
		new_state = MusicState.CRUISING
	else:
		new_state = MusicState.DEEP_SPACE

	current_state = new_state

# =====================================================================
#  TARGET PARAMETER CALCULATION
# =====================================================================

func _update_music_targets() -> void:
	match current_state:
		MusicState.DEEP_SPACE:
			_target_root_hz       = ROOT_SPACE
			_target_bass_volume   = 0.10
			_target_arp_volume    = 0.025
			_target_filter_cutoff = 500.0
			_target_reverb_mix    = 0.55
			_arp_tempo            = 35.0       # very sparse — one note every ~0.86s
			_chord_duration       = 8.0        # 8 seconds per chord — glacial
			_bass_detune          = 1.003

		MusicState.CRUISING:
			_target_root_hz       = ROOT_CRUISE
			_target_bass_volume   = 0.13
			_target_arp_volume    = 0.04
			# Speed drives filter open
			var spd_t := clampf(_ship_speed / 5000.0, 0.0, 1.0)
			_target_filter_cutoff = lerpf(700.0, 2200.0, spd_t)
			_target_reverb_mix    = 0.4
			_arp_tempo            = lerpf(45.0, 70.0, spd_t)
			_chord_duration       = lerpf(6.0, 4.0, spd_t)
			_bass_detune          = 1.005

		MusicState.ATMOSPHERE:
			_target_root_hz       = ROOT_ATMO
			_target_bass_volume   = 0.14
			_target_arp_volume    = 0.035
			_target_filter_cutoff = 1000.0
			_target_reverb_mix    = 0.6
			_arp_tempo            = 50.0
			_chord_duration       = 6.0
			_bass_detune          = 1.008      # wider pad in atmosphere

		MusicState.SURFACE:
			_target_root_hz       = ROOT_SURFACE
			_target_bass_volume   = 0.12
			_target_arp_volume    = 0.045
			_target_filter_cutoff = 1400.0
			_target_reverb_mix    = 0.45
			_arp_tempo            = 55.0
			_chord_duration       = 5.0
			_bass_detune          = 1.004

		MusicState.COMBAT:
			_target_root_hz       = ROOT_COMBAT
			_target_bass_volume   = 0.16
			_target_arp_volume    = 0.06
			_target_filter_cutoff = lerpf(1600.0, 3000.0, _combat_tension)
			_target_reverb_mix    = 0.25
			_arp_tempo            = lerpf(60.0, 80.0, _combat_tension)
			_chord_duration       = lerpf(4.0, 2.5, _combat_tension)
			_bass_detune          = 1.01

# =====================================================================
#  AUDIO BUS EFFECT MODULATION
# =====================================================================

func _update_bus_effects() -> void:
	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		return

	# Reverb wet/dry
	if AudioServer.get_bus_effect_count(bus_idx) > 0:
		var fx := AudioServer.get_bus_effect(bus_idx, 0)
		if fx is AudioEffectReverb:
			fx.wet = _reverb_mix
			fx.dry = 1.0 - _reverb_mix * 0.5

	# Low-pass filter cutoff
	if AudioServer.get_bus_effect_count(bus_idx) > 1:
		var fx := AudioServer.get_bus_effect(bus_idx, 1)
		if fx is AudioEffectLowPassFilter:
			fx.cutoff_hz = _filter_cutoff

# =====================================================================
#  SINE LOOKUP
# =====================================================================

func _sin_lut(phase: float) -> float:
	var idx := int(phase * 256.0) & 255
	return _sin_table[idx]

# =====================================================================
#  BASS / PAD BUFFER FILL
#  Three layers that all follow the chord root:
#    1. Main bass tone (pure sine at chord root)
#    2. Detuned pad (sine slightly sharp — creates the "wide" pad feel)
#    3. Sub-bass (octave below — felt more than heard)
#  All three move together when the chord changes via portamento.
# =====================================================================

func _fill_bass_buffer() -> void:
	if not _drone_playback:
		return
	var frames := mini(_drone_playback.get_frames_available(), _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	# LFO computed once per buffer (0.12 Hz — very slow breathing)
	var lfo := _sin_lut(_lfo_phase) * 0.25 + 0.75   # range 0.5–1.0
	_lfo_phase = fmod(_lfo_phase + 0.12 * float(frames) / _sample_rate, 1.0)

	var vol   := _bass_volume * lfo
	var freq1 := _bass_freq_actual
	var freq2 := _bass_freq_actual * _bass_detune
	var fsub  := _bass_freq_actual * 0.5
	var inv_r := 1.0 / _sample_rate

	var p1  := _bass_phase_1
	var p2  := _bass_phase_2
	var ps  := _bass_phase_sub
	var tbl := _sin_table

	for i in frames:
		# Main bass (sine) + detuned pad (sine) + sub (sine)
		# All pure sines = warm, not harsh. The detune creates slow beating = "pad"
		var s := (tbl[int(p1 * 256.0) & 255] * 0.38
				+ tbl[int(p2 * 256.0) & 255] * 0.32
				+ tbl[int(ps * 256.0) & 255] * 0.30) * vol

		# Mix in stinger if active
		if _stinger_env > 0.001:
			s += tbl[int(_stinger_phase * 256.0) & 255] * _stinger_env * _stinger_vol
			_stinger_phase = fmod(_stinger_phase + _stinger_freq * inv_r, 1.0)

		p1 = fmod(p1 + freq1 * inv_r, 1.0)
		p2 = fmod(p2 + freq2 * inv_r, 1.0)
		ps = fmod(ps + fsub  * inv_r, 1.0)
		_drone_playback.push_frame(Vector2(s, s))

	_bass_phase_1   = p1
	_bass_phase_2   = p2
	_bass_phase_sub = ps

# =====================================================================
#  ARPEGGIATOR
#  Picks notes from the current chord's triad pool.
#  Alternates direction each chord. ~30% of steps are rests for space.
# =====================================================================

func _advance_arp_step() -> void:
	_arp_phrase_count += 1

	# ~30% chance of rest — gives the arp breathing room
	if randf() < 0.30:
		_arp_rest = true
		_arp_envelope = 0.0
		return

	_arp_rest = false

	if _arp_note_pool.is_empty():
		return

	# Walk through the note pool in current direction
	_arp_step_index += _arp_direction
	if _arp_step_index >= _arp_note_pool.size():
		_arp_step_index = 0
	elif _arp_step_index < 0:
		_arp_step_index = _arp_note_pool.size() - 1

	var ratio: float = _arp_note_pool[_arp_step_index]

	# Octave selection: mostly octave 3, sometimes 4 for sparkle
	var octave := 3
	if randf() > 0.8:
		octave = 4
	elif randf() > 0.9:
		octave = 2   # rare low note for variety

	_arp_current_freq = _root_hz * ratio * pow(2.0, float(octave - 1))

	# Gentle attack: envelope starts at 0.85 not 1.0 to avoid click
	_arp_envelope = 0.85

func _fill_arp_buffer() -> void:
	if not _arp_playback:
		return
	var frames := mini(_arp_playback.get_frames_available(), _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	var freq  := _arp_current_freq
	var inv_r := 1.0 / _sample_rate
	var vol   := _arp_volume * _arp_envelope
	# Filter attenuation: soften harmonics proportional to cutoff
	var filt  := clampf(_filter_cutoff / 3000.0, 0.15, 1.0)
	var phase := _arp_phase
	var tbl   := _sin_table

	# Skip fill entirely during rests (saves CPU)
	if _arp_rest or vol < 0.001:
		for i in frames:
			_arp_playback.push_frame(Vector2.ZERO)
		return

	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)

		# Soft saw-sine blend: 25% saw for subtle edge, 75% sine for warmth
		# (was 60/40 — much harsher)
		var saw  := phase * 2.0 - 1.0
		var sine := tbl[int(phase * 256.0) & 255]
		var s    := (saw * 0.25 + sine * 0.75) * vol * filt

		_arp_playback.push_frame(Vector2(s, s))

	_arp_phase = phase

# =====================================================================
#  PUBLIC API — called by other systems
# =====================================================================

# Trigger a harmonic stinger (mining pickup, loot collect, etc.)
# pitch_hz: 440 = A4, 523 = C5, etc.   intensity: 0.0–1.0
func play_stinger(pitch_hz: float = 523.0, intensity: float = 0.8) -> void:
	_stinger_freq  = pitch_hz
	_stinger_env   = intensity
	_stinger_phase = 0.0

# Mining stinger: plays a rising harmonic burst tuned to the resource
func play_mining_stinger(resource_type: String) -> void:
	var pitch: float
	match resource_type:
		"Copper":   pitch = 523.0    # C5
		"Silver":   pitch = 587.0    # D5
		"Gold":     pitch = 659.0    # E5
		"Platinum": pitch = 784.0    # G5
		"Diamond":  pitch = 1047.0   # C6 (octave higher)
		_:          pitch = 523.0
	play_stinger(pitch, 0.7)

# Get current state name (for debug HUD)
func get_state_name() -> String:
	match current_state:
		MusicState.DEEP_SPACE: return "DEEP SPACE"
		MusicState.CRUISING:   return "CRUISING"
		MusicState.ATMOSPHERE: return "ATMOSPHERE"
		MusicState.SURFACE:    return "SURFACE"
		MusicState.COMBAT:     return "COMBAT"
	return "UNKNOWN"
