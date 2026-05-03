extends Node

# MusicDirector.gd
# Managed by THE COMPOSER.
# Procedural ambient synthwave music that reacts to gameplay state.
#
# ARCHITECTURE: Hybrid synth
#   - AudioStreamGenerator drone (2 detuned sines + sub-bass) — the "pad"
#   - AudioStreamGenerator arp  (saw-sine blend w/ envelope) — the "melody"
#   - Audio bus effects (Reverb + LowPass) modulated by game state
#   - Optional: AudioStreamPlayer slots for authored Ogg loops (drop-in upgrade)
#
# PERFORMANCE BUDGET: <0.5ms/frame on A14-class mobile
#   - Game state polled at 4Hz (music doesn't need 60Hz precision)
#   - 256-entry sine lookup table (no trig in fill loop)
#   - 22050Hz sample rate on mobile, 44100Hz desktop
#   - Per-buffer LFO (computed once, not per-sample)
#   - Max 1024 frames per fill call to cap worst-case spikes
#
# MUSICAL DESIGN: Five reactive states
#   DEEP_SPACE  — slow, wide pad, pentatonic arp, heavy reverb
#   CRUISING    — speed drives filter + arp tempo, pad thickens
#   ATMOSPHERE  — Phrygian scale, more detune, deeper reverb
#   SURFACE     — Dorian mode, rhythmic arp, warmer tone
#   COMBAT      — tense root, fast arp, filter wide open, dry mix

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

# Drone oscillator phases
var _drone_phase_1: float = 0.0
var _drone_phase_2: float = 0.0
var _drone_phase_sub: float = 0.0
var _lfo_phase: float = 0.0

# Arp oscillator
var _arp_phase: float = 0.0

# --- Current parameters (smoothly interpolated each frame) ---
var _drone_freq: float = 55.0       # Hz (A1)
var _drone_detune: float = 1.003    # ratio — osc2 = freq * detune
var _drone_volume: float = 0.12
var _arp_volume: float = 0.03
var _filter_cutoff: float = 600.0   # simulated LP cutoff
var _reverb_mix: float = 0.5

# --- Target parameters (set at 4Hz, lerped toward) ---
var _target_drone_freq: float = 55.0
var _target_drone_volume: float = 0.12
var _target_arp_volume: float = 0.03
var _target_filter_cutoff: float = 600.0
var _target_reverb_mix: float = 0.5

# =====================================================================
#  ARPEGGIATOR
# =====================================================================

var _arp_tempo: float = 80.0       # BPM
var _arp_step_timer: float = 0.0
var _arp_step_index: int = 0
var _arp_current_freq: float = 220.0
var _arp_envelope: float = 0.0     # attack-decay (1.0 → 0.0)

# Pentatonic minor: root, m3, P4, P5, m7 — open, spacious
const SCALE_SPACE := [1.0, 1.189, 1.335, 1.498, 1.782]
# Phrygian: root, b2, m3, P4, P5, b6, m7 — dark, mysterious
const SCALE_ATMO  := [1.0, 1.059, 1.189, 1.335, 1.498, 1.587, 1.782]
# Dorian: root, M2, m3, P4, P5, M6, m7 — earthy, warm
const SCALE_SURFACE := [1.0, 1.122, 1.189, 1.335, 1.498, 1.682, 1.782]
# Minor: root, M2, m3, P4, P5, m6, m7 — tense
const SCALE_COMBAT := [1.0, 1.122, 1.189, 1.335, 1.498, 1.587, 1.782]

# Root notes per state (Hz)
const ROOT_SPACE   := 55.0    # A1 — deep, open
const ROOT_CRUISE  := 55.0    # A1 — same root, intensity changes
const ROOT_ATMO    := 65.41   # C2 — darker
const ROOT_SURFACE := 73.42   # D2 — earthy
const ROOT_COMBAT  := 61.74   # B1 — tense

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

	# Drone generator
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

func _setup_music_bus() -> void:
	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		AudioServer.add_bus()
		bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_idx, "Music")
		AudioServer.set_bus_send(bus_idx, "Master")

	AudioServer.set_bus_volume_db(bus_idx, -8.0)

	# Reverb
	if AudioServer.get_bus_effect_count(bus_idx) == 0:
		var reverb := AudioEffectReverb.new()
		reverb.room_size = 0.85
		reverb.damping = 0.3
		reverb.spread = 0.8
		reverb.wet = 0.4
		reverb.dry = 0.6
		AudioServer.add_bus_effect(bus_idx, reverb)

	# Low-pass filter
	if AudioServer.get_bus_effect_count(bus_idx) < 2:
		var lpf := AudioEffectLowPassFilter.new()
		lpf.cutoff_hz = 2000.0
		lpf.resonance = 2.0
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

	# ── Smooth parameter interpolation (cheap — just 6 lerps) ────────
	var ls := 2.0 * delta
	_drone_freq    = lerp(_drone_freq,    _target_drone_freq,    ls)
	_drone_volume  = lerp(_drone_volume,  _target_drone_volume,  ls)
	_arp_volume    = lerp(_arp_volume,    _target_arp_volume,    ls)
	_filter_cutoff = lerp(_filter_cutoff, _target_filter_cutoff, ls)
	_reverb_mix    = lerp(_reverb_mix,    _target_reverb_mix,    ls)

	# ── Arpeggiator step clock ───────────────────────────────────────
	_arp_step_timer += delta
	var step_dur := 60.0 / _arp_tempo / 4.0   # 16th-note resolution
	if _arp_step_timer >= step_dur:
		_arp_step_timer -= step_dur
		_advance_arp_step()

	# Decay envelopes
	_arp_envelope = maxf(_arp_envelope - delta * 6.0, 0.0)
	_stinger_env  = maxf(_stinger_env  - delta * 5.0, 0.0)

	# ── Update audio bus effects ─────────────────────────────────────
	_update_bus_effects()

	# ── Fill audio buffers ───────────────────────────────────────────
	_fill_drone_buffer()
	_fill_arp_buffer()

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
			_target_drone_freq    = ROOT_SPACE
			_target_drone_volume  = 0.12
			_target_arp_volume    = 0.03
			_target_filter_cutoff = 600.0
			_target_reverb_mix    = 0.5
			_arp_tempo            = 80.0
			_drone_detune         = 1.003

		MusicState.CRUISING:
			_target_drone_freq    = ROOT_CRUISE
			_target_drone_volume  = 0.15
			_target_arp_volume    = 0.06
			# Speed drives filter: 800 Hz at rest → 3000 Hz at warp
			_target_filter_cutoff = lerpf(800.0, 3000.0, clampf(_ship_speed / 5000.0, 0.0, 1.0))
			_target_reverb_mix    = 0.35
			_arp_tempo            = lerpf(100.0, 160.0, clampf(_ship_speed / 5000.0, 0.0, 1.0))
			_drone_detune         = 1.005

		MusicState.ATMOSPHERE:
			_target_drone_freq    = ROOT_ATMO
			_target_drone_volume  = 0.18
			_target_arp_volume    = 0.05
			_target_filter_cutoff = 1200.0
			_target_reverb_mix    = 0.6
			_arp_tempo            = 110.0
			_drone_detune         = 1.008   # wider pad in atmosphere

		MusicState.SURFACE:
			_target_drone_freq    = ROOT_SURFACE
			_target_drone_volume  = 0.14
			_target_arp_volume    = 0.07
			_target_filter_cutoff = 1800.0
			_target_reverb_mix    = 0.45
			_arp_tempo            = 120.0
			_drone_detune         = 1.004

		MusicState.COMBAT:
			_target_drone_freq    = ROOT_COMBAT
			_target_drone_volume  = 0.20
			_target_arp_volume    = 0.10
			_target_filter_cutoff = lerpf(2000.0, 4000.0, _combat_tension)
			_target_reverb_mix    = 0.2
			_arp_tempo            = lerpf(140.0, 180.0, _combat_tension)
			_drone_detune         = 1.01

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
	# phase is 0.0–1.0 representing one full cycle
	var idx := int(phase * 256.0) & 255
	return _sin_table[idx]

# =====================================================================
#  DRONE BUFFER FILL
# =====================================================================

func _fill_drone_buffer() -> void:
	if not _drone_playback:
		return
	var frames := mini(_drone_playback.get_frames_available(), _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	# LFO computed once per buffer (0.15 Hz — imperceptible change within 1024 samples)
	var lfo := _sin_lut(_lfo_phase) * 0.3 + 0.7   # range 0.4–1.0
	_lfo_phase = fmod(_lfo_phase + 0.15 * float(frames) / _sample_rate, 1.0)

	var vol   := _drone_volume * lfo
	var freq1 := _drone_freq
	var freq2 := _drone_freq * _drone_detune
	var fsub  := _drone_freq * 0.5
	var inv_r := 1.0 / _sample_rate

	# Local copies for tight loop (avoids repeated self. lookups)
	var p1 := _drone_phase_1
	var p2 := _drone_phase_2
	var ps := _drone_phase_sub
	var tbl := _sin_table

	for i in frames:
		var s := (tbl[int(p1 * 256.0) & 255] * 0.35
				+ tbl[int(p2 * 256.0) & 255] * 0.35
				+ tbl[int(ps * 256.0) & 255] * 0.3) * vol

		# Mix in stinger if active
		if _stinger_env > 0.001:
			s += tbl[int(_stinger_phase * 256.0) & 255] * _stinger_env * _stinger_vol
			_stinger_phase = fmod(_stinger_phase + _stinger_freq * inv_r, 1.0)

		p1 = fmod(p1 + freq1 * inv_r, 1.0)
		p2 = fmod(p2 + freq2 * inv_r, 1.0)
		ps = fmod(ps + fsub  * inv_r, 1.0)
		_drone_playback.push_frame(Vector2(s, s))

	_drone_phase_1  = p1
	_drone_phase_2  = p2
	_drone_phase_sub = ps

# =====================================================================
#  ARPEGGIATOR
# =====================================================================

func _get_scale() -> Array:
	match current_state:
		MusicState.ATMOSPHERE: return SCALE_ATMO
		MusicState.SURFACE:    return SCALE_SURFACE
		MusicState.COMBAT:     return SCALE_COMBAT
		_:                     return SCALE_SPACE

func _advance_arp_step() -> void:
	var scale := _get_scale()
	_arp_step_index = (_arp_step_index + 1) % scale.size()

	# Octave selection: mostly 2–3, occasional jump to 4 for sparkle
	var octave := 2
	if _arp_step_index == 0 and randf() > 0.7:
		octave = 3
	elif randf() > 0.88:
		octave = 4

	_arp_current_freq = _drone_freq * scale[_arp_step_index] * pow(2.0, float(octave - 1))

	# Retrigger envelope
	_arp_envelope = 1.0

func _fill_arp_buffer() -> void:
	if not _arp_playback:
		return
	var frames := mini(_arp_playback.get_frames_available(), _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	var freq  := _arp_current_freq
	var inv_r := 1.0 / _sample_rate
	var vol   := _arp_volume * _arp_envelope
	# Filter attenuation: soften harsh harmonics proportional to cutoff
	var filt  := clampf(_filter_cutoff / 4000.0, 0.1, 1.0)
	var phase := _arp_phase
	var tbl   := _sin_table

	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)

		# Saw-sine blend: 60% saw for synthwave edge, 40% sine for warmth
		var saw  := phase * 2.0 - 1.0
		var sine := tbl[int(phase * 256.0) & 255]
		var s    := (saw * 0.6 + sine * 0.4) * vol * filt

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
