extends Node

# MusicDirector.gd
# Managed by THE COMPOSER.
# Procedural ambient synthwave music that reacts to gameplay state.
#
# ARCHITECTURE: Chord-driven procedural synth with dynamic FX chain
#   - Chord progression clock: 4–8 second chords that both voices follow
#   - Bass voice: melodic root notes with portamento, stereo pad, chord swell
#   - Arp voice: triadic note pool, accent patterns, stereo pan movement
#   - Audio FX chain: Reverb → LowPass (w/ sweep LFO) → Delay (tempo-synced) → Chorus
#   - All effects dynamically modulated by game state + internal LFOs
#
# PERFORMANCE BUDGET: <0.5ms/frame on A14-class mobile
#   - Game state polled at 4Hz
#   - 256-entry sine LUT (no trig in fill loop)
#   - 22050Hz on mobile, 44100Hz desktop
#   - LFOs computed once per buffer fill, not per-sample
#   - Max 1024 frames per fill call
#
# MUSICAL DESIGN: Five reactive states with shared harmonic structure
#   DEEP_SPACE  — glacial chords, sparse arp, pentatonic, massive reverb + delay
#   CRUISING    — speed opens filter + delay shortens, arp picks up
#   ATMOSPHERE  — Phrygian mode, wide stereo pad, deep echo, chorus shimmer
#   SURFACE     — Dorian mode, warm filter, rhythmic arp accents
#   COMBAT      — tense minor, fast chords, filter wide, delay tightens

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
var _combat_tension: float = 0.0

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
var _bass_phase_1: float = 0.0
var _bass_phase_2: float = 0.0
var _bass_phase_sub: float = 0.0
var _lfo_phase: float = 0.0          # slow volume breathing
var _filter_lfo_phase: float = 0.0   # slow filter sweep (separate rate)

# Arp oscillator
var _arp_phase: float = 0.0

# --- Current parameters (smoothly interpolated each frame) ---
var _bass_freq: float = 55.0
var _bass_freq_actual: float = 55.0
var _bass_detune: float = 1.003
var _bass_volume: float = 0.12
var _arp_volume: float = 0.02
var _filter_cutoff: float = 600.0
var _reverb_mix: float = 0.5

# --- Target parameters ---
var _target_bass_volume: float = 0.12
var _target_arp_volume: float = 0.02
var _target_filter_cutoff: float = 600.0
var _target_reverb_mix: float = 0.5

# =====================================================================
#  DYNAMIC FX PARAMETERS
# =====================================================================

# Filter sweep LFO: modulates cutoff ±30% around the target
var _filter_lfo_rate: float = 0.06     # Hz (~17 second cycle)
var _filter_lfo_depth: float = 0.3     # ±30% of cutoff

# Delay: tempo-synced echo
var _delay_time_ms: float = 500.0      # current delay time
var _target_delay_time: float = 500.0
var _delay_feedback: float = 0.25      # feedback amount (0–1)
var _target_delay_feedback: float = 0.25
var _delay_mix: float = 0.2           # wet level (dB mapped to linear later)
var _target_delay_mix: float = 0.2

# Chorus: subtle movement/shimmer
var _chorus_rate: float = 0.4          # Hz
var _target_chorus_rate: float = 0.4
var _chorus_depth: float = 2.0         # ms
var _target_chorus_depth: float = 2.0

# Stereo width for pad (0.0 = mono, 1.0 = full L/R osc separation)
var _stereo_width: float = 0.4
var _target_stereo_width: float = 0.4

# Chord swell: volume builds over each chord then dips at transition
var _swell_phase: float = 0.0         # 0.0 at chord start, 1.0 at end
var _swell_depth: float = 0.25        # how much volume variation (0–1)

# =====================================================================
#  CHORD PROGRESSION SYSTEM
# =====================================================================

var _chord_timer: float = 0.0
var _chord_duration: float = 6.0
var _chord_index: int = 0
var _chord_root_ratio: float = 1.0
var _arp_note_pool: Array = [1.0]

var _root_hz: float = 55.0
var _target_root_hz: float = 55.0

# =====================================================================
#  SCALES & PROGRESSIONS
# =====================================================================

const SCALE_SPACE := [1.0, 1.189, 1.335, 1.498, 1.782]
const PROG_SPACE := [0, 3, 4, 2]

const SCALE_ATMO := [1.0, 1.059, 1.189, 1.335, 1.498, 1.587, 1.782]
const PROG_ATMO := [0, 5, 3, 1]

const SCALE_SURFACE := [1.0, 1.122, 1.189, 1.335, 1.498, 1.682, 1.782]
const PROG_SURFACE := [0, 2, 3, 5]

const SCALE_COMBAT := [1.0, 1.122, 1.189, 1.335, 1.498, 1.587, 1.782]
const PROG_COMBAT := [0, 4, 3, 2]

const ROOT_SPACE   := 55.0
const ROOT_CRUISE  := 55.0
const ROOT_ATMO    := 65.41
const ROOT_SURFACE := 73.42
const ROOT_COMBAT  := 61.74

# =====================================================================
#  ARPEGGIATOR
# =====================================================================

var _arp_tempo: float = 40.0
var _arp_step_timer: float = 0.0
var _arp_step_index: int = 0
var _arp_current_freq: float = 220.0
var _arp_envelope: float = 0.0
var _arp_rest: bool = false
var _arp_direction: int = 1
var _arp_phrase_count: int = 0
var _arp_pan: float = 0.0            # -1.0 left, 0.0 center, 1.0 right
var _arp_accent: float = 0.85        # velocity for current note (accent pattern)

# Accent pattern: strong/weak/medium/weak — creates rhythmic feel without drums
const ACCENT_PATTERN := [0.85, 0.50, 0.70, 0.45, 0.80, 0.55, 0.65, 0.50]

# =====================================================================
#  SINE LOOKUP TABLE
# =====================================================================

var _sin_table: PackedFloat32Array

# =====================================================================
#  STATE POLLING
# =====================================================================

var _poll_accum: float = 0.0
const _POLL_INTERVAL: float = 0.25
var _player: Node3D = null

# =====================================================================
#  STINGER
# =====================================================================

var _stinger_phase: float = 0.0
var _stinger_freq: float = 440.0
var _stinger_env: float = 0.0
var _stinger_vol: float = 0.15

const _MAX_FILL_FRAMES := 1024

# =====================================================================
#  INIT
# =====================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("MusicDirector")
	_mobile = OS.get_name() == "iOS" or OS.has_feature("mobile")
	_sample_rate = 22050.0 if _mobile else 44100.0

	_sin_table.resize(256)
	for i in 256:
		_sin_table[i] = sin(float(i) / 256.0 * TAU)

	_setup_music_bus()

	# Bass/pad generator
	_drone_player = AudioStreamPlayer.new()
	_drone_player.bus = "Music"
	var drone_stream := AudioStreamGenerator.new()
	drone_stream.mix_rate = _sample_rate
	drone_stream.buffer_length = 0.15
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

	_advance_chord()

func _setup_music_bus() -> void:
	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		AudioServer.add_bus()
		bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_idx, "Music")
		AudioServer.set_bus_send(bus_idx, "Master")

	AudioServer.set_bus_volume_db(bus_idx, -8.0)

	# Clear any existing effects from prior runs (hot-reload safety)
	while AudioServer.get_bus_effect_count(bus_idx) > 0:
		AudioServer.remove_bus_effect(bus_idx, 0)

	# Effect 0: REVERB — spacey ambience, modulated per-state
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.88
	reverb.damping = 0.25
	reverb.spread = 0.9
	reverb.wet = 0.4
	reverb.dry = 0.6
	AudioServer.add_bus_effect(bus_idx, reverb)

	# Effect 1: LOW-PASS FILTER — tames harshness + swept by LFO
	var lpf := AudioEffectLowPassFilter.new()
	lpf.cutoff_hz = 2000.0
	lpf.resonance = 2.0
	AudioServer.add_bus_effect(bus_idx, lpf)

	# Effect 2: DELAY — tempo-synced echo, rhythmic repeats
	var delay := AudioEffectDelay.new()
	delay.dry = 0.85
	delay.tap1_active = true
	delay.tap1_delay_ms = 500.0
	delay.tap1_level_db = -12.0
	delay.tap1_pan = 0.2               # slight right
	delay.tap2_active = true
	delay.tap2_delay_ms = 250.0         # half-beat bounce
	delay.tap2_level_db = -18.0
	delay.tap2_pan = -0.2              # slight left — ping-pong feel
	delay.feedback_active = true
	delay.feedback_delay_ms = 500.0
	delay.feedback_level_db = -14.0
	delay.feedback_lowpass = 8000.0     # echoes get darker over time
	AudioServer.add_bus_effect(bus_idx, delay)

	# Effect 3: CHORUS — subtle width/shimmer on the pad
	var chorus := AudioEffectChorus.new()
	chorus.voice_count = 2
	chorus.set_voice_rate_hz(0, 0.4)
	chorus.set_voice_depth_ms(0, 2.5)
	chorus.set_voice_delay_ms(0, 8.0)
	chorus.set_voice_level_db(0, -6.0)
	chorus.set_voice_pan(0, -0.3)
	chorus.set_voice_cutoff_hz(0, 6000.0)
	chorus.set_voice_rate_hz(1, 0.55)   # slightly different rate = more motion
	chorus.set_voice_depth_ms(1, 1.8)
	chorus.set_voice_delay_ms(1, 12.0)
	chorus.set_voice_level_db(1, -8.0)
	chorus.set_voice_pan(1, 0.3)
	chorus.set_voice_cutoff_hz(1, 5000.0)
	chorus.dry = 0.85
	chorus.wet = 0.15
	AudioServer.add_bus_effect(bus_idx, chorus)

	# Effect 4: HIGH-PASS FILTER — clears mud, opens up in combat/cruising
	var hpf := AudioEffectHighPassFilter.new()
	hpf.cutoff_hz = 40.0               # very low default — just removes DC/rumble
	hpf.resonance = 0.5
	AudioServer.add_bus_effect(bus_idx, hpf)

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
	var ls := 1.5 * delta
	_bass_volume     = lerp(_bass_volume,     _target_bass_volume,     ls)
	_arp_volume      = lerp(_arp_volume,      _target_arp_volume,      ls)
	_filter_cutoff   = lerp(_filter_cutoff,   _target_filter_cutoff,   ls)
	_reverb_mix      = lerp(_reverb_mix,      _target_reverb_mix,      ls)
	_root_hz         = lerp(_root_hz,         _target_root_hz,         ls * 0.5)
	_delay_time_ms   = lerp(_delay_time_ms,   _target_delay_time,      ls)
	_delay_feedback  = lerp(_delay_feedback,  _target_delay_feedback,  ls)
	_delay_mix       = lerp(_delay_mix,       _target_delay_mix,       ls)
	_chorus_rate     = lerp(_chorus_rate,     _target_chorus_rate,     ls)
	_chorus_depth    = lerp(_chorus_depth,    _target_chorus_depth,    ls)
	_stereo_width    = lerp(_stereo_width,    _target_stereo_width,    ls)

	# Bass portamento: glide to target pitch over ~200ms
	_bass_freq_actual = lerp(_bass_freq_actual, _bass_freq, 5.0 * delta)

	# ── Filter sweep LFO ────────────────────────────────────────────
	# Separate from volume LFO — creates slow "breathing" filter movement
	_filter_lfo_phase = fmod(_filter_lfo_phase + _filter_lfo_rate * delta, 1.0)

	# ── Chord progression clock ──────────────────────────────────────
	_chord_timer += delta
	_swell_phase = clampf(_chord_timer / _chord_duration, 0.0, 1.0)
	if _chord_timer >= _chord_duration:
		_chord_timer -= _chord_duration
		_advance_chord()

	# ── Arpeggiator step clock (8th notes) ───────────────────────────
	_arp_step_timer += delta
	var step_dur := 60.0 / _arp_tempo / 2.0
	if _arp_step_timer >= step_dur:
		_arp_step_timer -= step_dur
		_advance_arp_step()

	# Decay envelopes
	_arp_envelope = maxf(_arp_envelope - delta * 2.5, 0.0)
	_stinger_env  = maxf(_stinger_env  - delta * 4.0, 0.0)

	# ── Update all audio bus effects ─────────────────────────────────
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

	# Bass target frequency (octave 2)
	_bass_freq = _root_hz * _chord_root_ratio * 2.0

	# Build arp note pool: triad from chord root
	var s_len := scale.size()
	var idx_3rd := (root_idx + 2) % s_len
	var idx_5th := (root_idx + 4) % s_len
	_arp_note_pool = [
		scale[root_idx],
		scale[idx_3rd],
		scale[idx_5th],
	]

	# Occasionally add octave root for wider range
	if randf() > 0.5:
		_arp_note_pool.append(scale[root_idx] * 2.0)

	# Reverse arp direction every other chord
	_arp_direction = 1 if _chord_index % 2 == 0 else -1

	# Sync delay time to current beat duration on chord changes
	_target_delay_time = 60000.0 / _arp_tempo   # ms per beat

	# Reset swell
	_swell_phase = 0.0

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

	_ship_speed = _player.velocity.length() if _player is CharacterBody3D else 0.0

	var alt_val = _player.get("true_altitude")
	_altitude = alt_val if alt_val != null else 300000.0

	_is_warping    = _player.get("mobile_boost") == true or Input.is_key_pressed(KEY_SHIFT)
	_is_in_atmo    = _altitude < 26000.0
	_is_on_surface = _altitude < 3000.0

	var enemies := get_tree().get_nodes_in_group("Enemy")
	var nearest := 999999.0
	for e in enemies:
		if is_instance_valid(e):
			nearest = minf(nearest, e.global_position.distance_to(_player.global_position))
	_combat_tension = clampf(1.0 - nearest / 5000.0, 0.0, 1.0)

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
#  Sets ALL musical + FX targets per state. Effects lerp toward them.
# =====================================================================

func _update_music_targets() -> void:
	match current_state:
		MusicState.DEEP_SPACE:
			_target_root_hz         = ROOT_SPACE
			_target_bass_volume     = 0.10
			_target_arp_volume      = 0.025
			_target_filter_cutoff   = 500.0
			_target_reverb_mix      = 0.55
			_arp_tempo              = 35.0
			_chord_duration         = 8.0
			_bass_detune            = 1.003
			# FX: massive delay, lots of chorus, wide stereo
			_target_delay_feedback  = 0.35
			_target_delay_mix       = 0.30
			_target_chorus_rate     = 0.3
			_target_chorus_depth    = 3.0
			_target_stereo_width    = 0.6
			_filter_lfo_rate        = 0.04     # very slow sweep (~25s cycle)
			_filter_lfo_depth       = 0.35
			_swell_depth            = 0.30

		MusicState.CRUISING:
			_target_root_hz         = ROOT_CRUISE
			_target_bass_volume     = 0.13
			_target_arp_volume      = 0.04
			var spd_t := clampf(_ship_speed / 5000.0, 0.0, 1.0)
			_target_filter_cutoff   = lerpf(700.0, 2200.0, spd_t)
			_target_reverb_mix      = 0.4
			_arp_tempo              = lerpf(45.0, 70.0, spd_t)
			_chord_duration         = lerpf(6.0, 4.0, spd_t)
			_bass_detune            = 1.005
			# FX: delay tightens with speed, chorus moderate
			_target_delay_feedback  = lerpf(0.30, 0.20, spd_t)
			_target_delay_mix       = lerpf(0.25, 0.18, spd_t)
			_target_chorus_rate     = lerpf(0.4, 0.6, spd_t)
			_target_chorus_depth    = lerpf(2.5, 1.5, spd_t)
			_target_stereo_width    = 0.5
			_filter_lfo_rate        = lerpf(0.06, 0.10, spd_t)  # faster sweep at speed
			_filter_lfo_depth       = 0.25
			_swell_depth            = 0.20

		MusicState.ATMOSPHERE:
			_target_root_hz         = ROOT_ATMO
			_target_bass_volume     = 0.14
			_target_arp_volume      = 0.035
			_target_filter_cutoff   = 1000.0
			_target_reverb_mix      = 0.6
			_arp_tempo              = 50.0
			_chord_duration         = 6.0
			_bass_detune            = 1.008
			# FX: deep echo, lush chorus, wide stereo for immersion
			_target_delay_feedback  = 0.32
			_target_delay_mix       = 0.28
			_target_chorus_rate     = 0.35
			_target_chorus_depth    = 3.5
			_target_stereo_width    = 0.65
			_filter_lfo_rate        = 0.05
			_filter_lfo_depth       = 0.30
			_swell_depth            = 0.25

		MusicState.SURFACE:
			_target_root_hz         = ROOT_SURFACE
			_target_bass_volume     = 0.12
			_target_arp_volume      = 0.045
			_target_filter_cutoff   = 1400.0
			_target_reverb_mix      = 0.45
			_arp_tempo              = 55.0
			_chord_duration         = 5.0
			_bass_detune            = 1.004
			# FX: moderate delay, gentle chorus, moderate width
			_target_delay_feedback  = 0.22
			_target_delay_mix       = 0.20
			_target_chorus_rate     = 0.45
			_target_chorus_depth    = 2.0
			_target_stereo_width    = 0.45
			_filter_lfo_rate        = 0.07
			_filter_lfo_depth       = 0.20
			_swell_depth            = 0.15

		MusicState.COMBAT:
			_target_root_hz         = ROOT_COMBAT
			_target_bass_volume     = 0.16
			_target_arp_volume      = 0.06
			_target_filter_cutoff   = lerpf(1600.0, 3000.0, _combat_tension)
			_target_reverb_mix      = 0.25
			_arp_tempo              = lerpf(60.0, 80.0, _combat_tension)
			_chord_duration         = lerpf(4.0, 2.5, _combat_tension)
			_bass_detune            = 1.01
			# FX: tight delay, minimal chorus, narrower stereo for focus
			_target_delay_feedback  = lerpf(0.18, 0.12, _combat_tension)
			_target_delay_mix       = lerpf(0.15, 0.10, _combat_tension)
			_target_chorus_rate     = 0.6
			_target_chorus_depth    = 1.0
			_target_stereo_width    = 0.3
			_filter_lfo_rate        = lerpf(0.08, 0.14, _combat_tension)  # faster in combat
			_filter_lfo_depth       = lerpf(0.15, 0.10, _combat_tension)
			_swell_depth            = 0.10

# =====================================================================
#  AUDIO BUS EFFECT MODULATION
#  Updates all 5 bus effects every frame with current parameter values.
# =====================================================================

func _update_bus_effects() -> void:
	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		return
	var fx_count := AudioServer.get_bus_effect_count(bus_idx)

	# ── Effect 0: REVERB ─────────────────────────────────────────────
	if fx_count > 0:
		var fx := AudioServer.get_bus_effect(bus_idx, 0)
		if fx is AudioEffectReverb:
			fx.wet = _reverb_mix
			fx.dry = 1.0 - _reverb_mix * 0.5

	# ── Effect 1: LOW-PASS FILTER with sweep LFO ────────────────────
	if fx_count > 1:
		var fx := AudioServer.get_bus_effect(bus_idx, 1)
		if fx is AudioEffectLowPassFilter:
			# Sweep LFO modulates cutoff around the target value
			var sweep := _sin_lut(_filter_lfo_phase) * _filter_lfo_depth
			var swept_cutoff := _filter_cutoff * (1.0 + sweep)
			fx.cutoff_hz = clampf(swept_cutoff, 200.0, 16000.0)

	# ── Effect 2: DELAY (tempo-synced) ───────────────────────────────
	if fx_count > 2:
		var fx := AudioServer.get_bus_effect(bus_idx, 2)
		if fx is AudioEffectDelay:
			# Tap 1: full beat delay
			fx.tap1_delay_ms = clampf(_delay_time_ms, 100.0, 2000.0)
			fx.tap1_level_db = lerpf(-20.0, -8.0, _delay_mix)
			# Tap 2: half-beat (rhythmic bounce)
			fx.tap2_delay_ms = clampf(_delay_time_ms * 0.5, 50.0, 1000.0)
			fx.tap2_level_db = lerpf(-24.0, -14.0, _delay_mix)
			# Feedback: echoes that darken over time
			fx.feedback_delay_ms = clampf(_delay_time_ms * 0.75, 75.0, 1500.0)
			fx.feedback_level_db = lerpf(-20.0, -8.0, _delay_feedback)
			# Echoes get progressively darker (tape delay feel)
			fx.feedback_lowpass = lerpf(4000.0, 8000.0, _delay_mix)

	# ── Effect 3: CHORUS ─────────────────────────────────────────────
	if fx_count > 3:
		var fx := AudioServer.get_bus_effect(bus_idx, 3)
		if fx is AudioEffectChorus:
			fx.set_voice_rate_hz(0, _chorus_rate)
			fx.set_voice_depth_ms(0, _chorus_depth)
			if fx.voice_count > 1:
				fx.set_voice_rate_hz(1, _chorus_rate * 1.37)   # offset for movement
				fx.set_voice_depth_ms(1, _chorus_depth * 0.7)
			fx.wet = clampf(_chorus_depth / 10.0, 0.08, 0.25)

	# ── Effect 4: HIGH-PASS FILTER ───────────────────────────────────
	if fx_count > 4:
		var fx := AudioServer.get_bus_effect(bus_idx, 4)
		if fx is AudioEffectHighPassFilter:
			# Open up high-pass in combat/cruising to clear mud
			var hpf_target: float
			match current_state:
				MusicState.COMBAT:     hpf_target = lerpf(60.0, 120.0, _combat_tension)
				MusicState.CRUISING:   hpf_target = 55.0
				_:                     hpf_target = 35.0
			fx.cutoff_hz = hpf_target

# =====================================================================
#  SINE LOOKUP
# =====================================================================

func _sin_lut(phase: float) -> float:
	var idx := int(phase * 256.0) & 255
	return _sin_table[idx]

# =====================================================================
#  BASS / PAD BUFFER FILL
#  Three layers + stereo width + chord swell
# =====================================================================

func _fill_bass_buffer() -> void:
	if not _drone_playback:
		return
	var frames := mini(_drone_playback.get_frames_available(), _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	# Volume LFO: slow breathing (computed once per buffer)
	var lfo := _sin_lut(_lfo_phase) * 0.25 + 0.75
	_lfo_phase = fmod(_lfo_phase + 0.12 * float(frames) / _sample_rate, 1.0)

	# Chord swell: volume builds gently over chord duration, dips at edges
	# Uses a sine curve: quiet at start, peaks at 60-70%, gentle at end
	var swell_env := 1.0 - _swell_depth + _swell_depth * sin(_swell_phase * PI)

	var vol   := _bass_volume * lfo * swell_env
	var freq1 := _bass_freq_actual
	var freq2 := _bass_freq_actual * _bass_detune
	var fsub  := _bass_freq_actual * 0.5
	var inv_r := 1.0 / _sample_rate

	var p1  := _bass_phase_1
	var p2  := _bass_phase_2
	var ps  := _bass_phase_sub
	var tbl := _sin_table
	var sw  := _stereo_width   # 0 = mono, 1 = full L/R separation

	for i in frames:
		var osc1 := tbl[int(p1 * 256.0) & 255]
		var osc2 := tbl[int(p2 * 256.0) & 255]
		var sub  := tbl[int(ps * 256.0) & 255]

		# Stereo separation: osc1 favours left, osc2 favours right
		# Sub stays centered (mono bass = solid foundation)
		var mono_mix := (osc1 * 0.35 + osc2 * 0.35 + sub * 0.30) * vol
		var left  := (osc1 * (0.35 + sw * 0.15) + osc2 * (0.35 - sw * 0.15) + sub * 0.30) * vol
		var right := (osc1 * (0.35 - sw * 0.15) + osc2 * (0.35 + sw * 0.15) + sub * 0.30) * vol

		# Mix in stinger if active (centered)
		if _stinger_env > 0.001:
			var st := tbl[int(_stinger_phase * 256.0) & 255] * _stinger_env * _stinger_vol
			left += st
			right += st
			_stinger_phase = fmod(_stinger_phase + _stinger_freq * inv_r, 1.0)

		p1 = fmod(p1 + freq1 * inv_r, 1.0)
		p2 = fmod(p2 + freq2 * inv_r, 1.0)
		ps = fmod(ps + fsub  * inv_r, 1.0)
		_drone_playback.push_frame(Vector2(left, right))

	_bass_phase_1   = p1
	_bass_phase_2   = p2
	_bass_phase_sub = ps

# =====================================================================
#  ARPEGGIATOR
#  Triadic note pool + accent pattern + stereo pan movement + ghost notes
# =====================================================================

func _advance_arp_step() -> void:
	_arp_phrase_count += 1

	# Ghost note: ~15% of "rest" slots play a very quiet note instead of silence
	# This keeps rhythmic continuity without filling every beat
	var is_ghost := false

	# ~30% chance of rest (or ghost note)
	if randf() < 0.30:
		if randf() < 0.15:
			is_ghost = true   # ghost note: very quiet
		else:
			_arp_rest = true
			_arp_envelope = 0.0
			return

	_arp_rest = false

	if _arp_note_pool.is_empty():
		return

	# Walk through note pool in current direction
	_arp_step_index += _arp_direction
	if _arp_step_index >= _arp_note_pool.size():
		_arp_step_index = 0
	elif _arp_step_index < 0:
		_arp_step_index = _arp_note_pool.size() - 1

	var ratio: float = _arp_note_pool[_arp_step_index]

	# Octave selection
	var octave := 3
	if randf() > 0.8:
		octave = 4
	elif randf() > 0.92:
		octave = 2

	_arp_current_freq = _root_hz * ratio * pow(2.0, float(octave - 1))

	# Accent pattern: gives rhythmic feel without drums
	var accent_idx := _arp_phrase_count % ACCENT_PATTERN.size()
	_arp_accent = ACCENT_PATTERN[accent_idx]

	# Ghost notes are 20% of normal volume
	if is_ghost:
		_arp_accent *= 0.20

	# Trigger envelope with accent velocity
	_arp_envelope = _arp_accent

	# Pan alternates: odd notes slightly left, even slightly right
	_arp_pan = 0.25 if _arp_phrase_count % 2 == 0 else -0.25

func _fill_arp_buffer() -> void:
	if not _arp_playback:
		return
	var frames := mini(_arp_playback.get_frames_available(), _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	var freq  := _arp_current_freq
	var inv_r := 1.0 / _sample_rate
	var vol   := _arp_volume * _arp_envelope
	var filt  := clampf(_filter_cutoff / 3000.0, 0.15, 1.0)
	var phase := _arp_phase
	var tbl   := _sin_table
	var pan   := _arp_pan   # -1.0 to 1.0

	# Silence during full rests
	if _arp_rest or vol < 0.0005:
		for i in frames:
			_arp_playback.push_frame(Vector2.ZERO)
		return

	# Pan to L/R volumes (constant-power panning)
	var pan_l := clampf(1.0 - pan, 0.0, 1.5)
	var pan_r := clampf(1.0 + pan, 0.0, 1.5)

	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)

		# Soft saw-sine blend: 25% saw for edge, 75% sine for warmth
		var saw  := phase * 2.0 - 1.0
		var sine := tbl[int(phase * 256.0) & 255]
		var s    := (saw * 0.25 + sine * 0.75) * vol * filt

		_arp_playback.push_frame(Vector2(s * pan_l, s * pan_r))

	_arp_phase = phase

# =====================================================================
#  PUBLIC API
# =====================================================================

func play_stinger(pitch_hz: float = 523.0, intensity: float = 0.8) -> void:
	_stinger_freq  = pitch_hz
	_stinger_env   = intensity
	_stinger_phase = 0.0

func play_mining_stinger(resource_type: String) -> void:
	var pitch: float
	match resource_type:
		"Copper":   pitch = 523.0
		"Silver":   pitch = 587.0
		"Gold":     pitch = 659.0
		"Platinum": pitch = 784.0
		"Diamond":  pitch = 1047.0
		_:          pitch = 523.0
	play_stinger(pitch, 0.7)

func get_state_name() -> String:
	match current_state:
		MusicState.DEEP_SPACE: return "DEEP SPACE"
		MusicState.CRUISING:   return "CRUISING"
		MusicState.ATMOSPHERE: return "ATMOSPHERE"
		MusicState.SURFACE:    return "SURFACE"
		MusicState.COMBAT:     return "COMBAT"
	return "UNKNOWN"
