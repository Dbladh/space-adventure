extends Node

# MusicDirector.gd
# Managed by THE COMPOSER.
# Procedural ambient synthwave music that reacts to gameplay state.
#
# ARCHITECTURE: Chord-driven procedural synth with percussion + dynamic FX
#   - ONE root note (C2, 65.41 Hz) across ALL states — always in key
#   - Major pentatonic for peaceful states (uplifting, adventurous)
#   - Dorian minor for combat (heroic tension, not ominous)
#   - Synthesized percussion: kick (sine sweep), snare (noise+tone), hi-hat (noise)
#   - 8-chord progressions per state to reduce repetition
#   - Audio FX chain: Reverb → LPF (swept) → Delay (tempo-synced) → Chorus → HPF
#
# PERFORMANCE BUDGET: <0.5ms/frame on A14-class mobile
#   - 256-entry sine LUT + 1024-entry noise LUT (no trig/rand in fill loop)
#   - 22050Hz on mobile, 44100Hz desktop
#   - State polled at 4Hz; LFOs computed once per buffer fill
#   - Max 1024 frames per fill call

# =====================================================================
#  GAME STATE MACHINE
# =====================================================================

enum MusicState { DEEP_SPACE, CRUISING, ATMOSPHERE, SURFACE, COMBAT }

var current_state: int = MusicState.DEEP_SPACE
var _prev_state: int = MusicState.DEEP_SPACE

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
var _perc_player: AudioStreamPlayer
var _perc_playback: AudioStreamGeneratorPlayback

# =====================================================================
#  SFX PLAYERS
# =====================================================================

var _sfx_ship_fire: AudioStreamPlayer
var _sfx_ship_boost: AudioStreamPlayer
var _sfx_ship_thrusters: AudioStreamPlayer
var _sfx_explosion_small: AudioStreamPlayer
var _sfx_explosion_big: AudioStreamPlayer

# =====================================================================
#  SYNTH ENGINE
# =====================================================================

var _sample_rate: float = 44100.0
var _mobile: bool = false

# Bass/pad oscillator phases
var _bass_phase_1: float = 0.0
var _bass_phase_2: float = 0.0
var _bass_phase_sub: float = 0.0
var _lfo_phase: float = 0.0
var _filter_lfo_phase: float = 0.0

# Arp oscillator
var _arp_phase: float = 0.0

# Current parameters (smoothly interpolated)
var _bass_freq: float = 130.82
var _bass_freq_actual: float = 130.82
var _bass_detune: float = 1.003
var _bass_volume: float = 0.12
var _arp_volume: float = 0.02
var _filter_cutoff: float = 600.0
var _reverb_mix: float = 0.5
var _perc_volume: float = 0.0        # percussion master volume

# Target parameters
var _target_bass_volume: float = 0.12
var _target_arp_volume: float = 0.02
var _target_filter_cutoff: float = 600.0
var _target_reverb_mix: float = 0.5
var _target_perc_volume: float = 0.0

# =====================================================================
#  DYNAMIC FX PARAMETERS
# =====================================================================

var _filter_lfo_rate: float = 0.06
var _filter_lfo_depth: float = 0.3

var _delay_time_ms: float = 500.0
var _target_delay_time: float = 500.0
var _delay_feedback: float = 0.25
var _target_delay_feedback: float = 0.25
var _delay_mix: float = 0.2
var _target_delay_mix: float = 0.2

var _chorus_rate: float = 0.4
var _target_chorus_rate: float = 0.4
var _chorus_depth: float = 2.0
var _target_chorus_depth: float = 2.0

var _stereo_width: float = 0.4
var _target_stereo_width: float = 0.4

var _swell_phase: float = 0.0
var _swell_depth: float = 0.25

# =====================================================================
#  KEY & SCALE SYSTEM
#  ONE root note for everything — mood comes from mode + FX, not key changes.
#  This guarantees bass and arp are always consonant.
# =====================================================================

# C2 — bright, uplifting center. All states share this root.
const ROOT_HZ := 65.41

# Major pentatonic: C D E G A — always sounds good, no dissonance
# Used for: DEEP_SPACE, CRUISING, ATMOSPHERE, SURFACE
const SCALE_MAJOR_PENT := [1.0, 1.122, 1.260, 1.498, 1.682]

# Dorian minor: C D Eb F G A Bb — heroic minor (raised 6th keeps it from being dark)
# Used for: COMBAT only
const SCALE_DORIAN := [1.0, 1.122, 1.189, 1.335, 1.498, 1.682, 1.782]

# 8-chord progressions (indices into scale) — longer = less repetitive
# Major pentatonic progressions (uplifting, adventurous)
const PROG_SPACE   := [0, 3, 4, 2, 0, 4, 3, 2]   # open, wandering
const PROG_CRUISE  := [0, 4, 3, 0, 2, 4, 3, 2]   # driving, forward momentum
const PROG_ATMO    := [0, 2, 4, 3, 0, 2, 3, 4]   # dreamy, mysterious
const PROG_SURFACE := [0, 3, 2, 4, 0, 3, 4, 2]   # warm, grounded

# Dorian progression (heroic tension)
const PROG_COMBAT  := [0, 3, 4, 2, 0, 4, 5, 3]   # tense but driving

# =====================================================================
#  CHORD PROGRESSION
# =====================================================================

var _chord_timer: float = 0.0
var _chord_duration: float = 6.0
var _chord_index: int = -1
var _chord_root_ratio: float = 1.0
var _arp_note_pool: Array = [1.0]

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
var _arp_pan: float = 0.0
var _arp_accent: float = 0.85

const ACCENT_PATTERN := [0.85, 0.50, 0.70, 0.45, 0.80, 0.55, 0.65, 0.50]

# =====================================================================
#  PERCUSSION ENGINE
#  Synthesized drums: kick (sine sweep), snare (noise+tone), hi-hat (noise)
#  Patterns per state, with occasional fills for variation.
# =====================================================================

# Drum envelopes (triggered per hit, decay per sample)
var _kick_env: float = 0.0
var _kick_phase: float = 0.0
var _kick_decay: float = 0.998       # computed in _ready
var _snare_env: float = 0.0
var _snare_phase: float = 0.0
var _snare_decay: float = 0.999
var _hat_env: float = 0.0
var _hat_decay: float = 0.997
var _noise_idx: int = 0

# Per-drum volumes (relative to _perc_volume master)
const KICK_VOL  := 0.30
const SNARE_VOL := 0.14
const HAT_VOL   := 0.08

# Percussion step tracking
var _perc_step_timer: float = 0.0
var _perc_step_index: int = 0
var _perc_bar_count: int = 0          # track bars for fills

# Patterns: 8 steps per bar (8th notes). Each step is a bitfield:
# bit 0 (1) = kick, bit 1 (2) = snare, bit 2 (4) = hi-hat
# Combinations: 5 = kick+hat, 6 = snare+hat, 7 = all
const PATTERN_SPACE   := [1, 0, 0, 0, 0, 0, 0, 0]   # just a pulse on 1
const PATTERN_CRUISE  := [1, 0, 4, 0, 1, 0, 4, 0]   # kick 1+5, hat 3+7
const PATTERN_ATMO    := [0, 4, 0, 4, 0, 4, 0, 4]   # offbeat hats (ethereal)
const PATTERN_SURFACE := [5, 4, 6, 4, 5, 4, 6, 4]   # kick-hat-snare-hat (full groove)
const PATTERN_COMBAT  := [5, 2, 5, 4, 5, 2, 5, 4]   # driving kick, snare 2+6

# Fill patterns (every 4th bar for variation)
const FILL_A := [5, 2, 5, 2, 5, 6, 5, 7]   # building fill
const FILL_B := [1, 2, 4, 2, 1, 6, 2, 5]   # syncopated fill

# 16th-note bass groove velocity patterns. 0.0 = rest, positive = hit velocity.
# 16 steps per bar. Rests create breathing room and rhythmic personality.
# These drive the pulsing bass independently of the arp/perc patterns.
const BASS_GROOVE_SPACE   := [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.70, 0.0, 0.0, 0.0, 0.0, 0.55, 0.0, 0.0]
const BASS_GROOVE_CRUISE  := [1.0, 0.0, 0.55, 0.0, 0.0, 0.75, 0.0, 0.0, 0.90, 0.0, 0.55, 0.0, 0.70, 0.0, 0.50, 0.65]
const BASS_GROOVE_ATMO    := [1.0, 0.0, 0.0, 0.60, 0.0, 0.0, 0.75, 0.0, 0.85, 0.0, 0.0, 0.65, 0.0, 0.0, 0.70, 0.0]
const BASS_GROOVE_SURFACE := [1.0, 0.0, 0.65, 0.50, 0.80, 0.0, 0.70, 0.60, 0.90, 0.0, 0.65, 0.50, 0.75, 0.0, 0.60, 0.55]
const BASS_GROOVE_COMBAT  := [1.0, 0.65, 0.0, 0.75, 0.90, 0.0, 0.70, 0.80, 1.0, 0.60, 0.0, 0.75, 0.85, 0.0, 0.70, 0.65]

# =====================================================================
#  LOOKUP TABLES
# =====================================================================

var _sin_table: PackedFloat32Array      # 256 entries
var _noise_table: PackedFloat32Array    # 1024 entries (pre-computed random)

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

# =====================================================================
#  BASS PULSE ENGINE
#  Pulsating 16th-note bass with retriggered envelope + harmonic series.
#  The pulsing layer snaps to the chord root instantly (no portamento).
#  The sustained pad layer glides (portamento) for warmth.
#  Per-step harmonic brightness varies each retrigger for timbral movement.
# =====================================================================

var _bass_pulse_env: float = 0.0       # retriggered envelope (0..1)
var _bass_pulse_decay: float = 0.998   # per-sample decay (recomputed each retrigger)
var _bass_step_timer: float = 0.0      # synced to 16th-note grid

# 16th-note step counter (0..15); initialized so first increment = step 0 (downbeat)
var _bass_step_count: int = 15

# Per-step harmonic brightness: randomized each retrigger → each note has unique timbre.
var _bass_harm_level: float = 0.5

# Harmonic LFO: slow global timbral drift (~0.08 Hz, ~12s per cycle)
var _harmonic_lfo_phase: float = 0.0

const _MAX_FILL_FRAMES := 1024

# =====================================================================
#  INIT
# =====================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group("MusicDirector")
	_mobile = OS.get_name() == "iOS" or OS.has_feature("mobile")
	_sample_rate = 22050.0 if _mobile else 44100.0

	# Sine LUT
	_sin_table.resize(256)
	for i in 256:
		_sin_table[i] = sin(float(i) / 256.0 * TAU)

	# Noise LUT (pre-computed random — avoids randf() in fill loop)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42   # deterministic for consistency
	_noise_table.resize(1024)
	for i in 1024:
		_noise_table[i] = rng.randf_range(-1.0, 1.0)

	# Compute per-sample decay rates for drum envelopes
	_kick_decay  = pow(0.01, 1.0 / (0.07 * _sample_rate))   # 70ms kick
	_snare_decay = pow(0.01, 1.0 / (0.10 * _sample_rate))   # 100ms snare
	_hat_decay   = pow(0.01, 1.0 / (0.03 * _sample_rate))   # 30ms hat (crisp)

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

	# Percussion generator
	_perc_player = AudioStreamPlayer.new()
	_perc_player.bus = "Music"
	var perc_stream := AudioStreamGenerator.new()
	perc_stream.mix_rate = _sample_rate
	perc_stream.buffer_length = 0.15
	_perc_player.stream = perc_stream
	add_child(_perc_player)
	_perc_player.play()
	_perc_playback = _perc_player.get_stream_playback()

	# SFX players (sampled audio effects for ship/combat)
	_sfx_ship_fire = AudioStreamPlayer.new()
	_sfx_ship_fire.bus = "Master"
	_sfx_ship_fire.stream = load("res://assets/resources/audio/ship_fire.wav")
	add_child(_sfx_ship_fire)

	_sfx_ship_boost = AudioStreamPlayer.new()
	_sfx_ship_boost.bus = "Master"
	_sfx_ship_boost.stream = load("res://assets/resources/audio/ship_boost.wav")
	add_child(_sfx_ship_boost)

	_sfx_ship_thrusters = AudioStreamPlayer.new()
	_sfx_ship_thrusters.bus = "Master"
	_sfx_ship_thrusters.stream = load("res://assets/resources/audio/ship_thrusters.wav")
	_sfx_ship_thrusters.volume_db = -6.0
	add_child(_sfx_ship_thrusters)

	_sfx_explosion_small = AudioStreamPlayer.new()
	_sfx_explosion_small.bus = "Master"
	_sfx_explosion_small.stream = load("res://assets/resources/audio/explosion_small.wav")
	add_child(_sfx_explosion_small)

	_sfx_explosion_big = AudioStreamPlayer.new()
	_sfx_explosion_big.bus = "Master"
	_sfx_explosion_big.stream = load("res://assets/resources/audio/explosion_big.mp3")
	add_child(_sfx_explosion_big)

	# Initialize bass frequency
	_bass_freq = ROOT_HZ * 2.0
	_bass_freq_actual = _bass_freq
	_advance_chord()

func _setup_music_bus() -> void:
	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		AudioServer.add_bus()
		bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_idx, "Music")
		AudioServer.set_bus_send(bus_idx, "Master")

	AudioServer.set_bus_volume_db(bus_idx, -8.0)

	# Clear existing effects (hot-reload safety)
	while AudioServer.get_bus_effect_count(bus_idx) > 0:
		AudioServer.remove_bus_effect(bus_idx, 0)

	# 0: REVERB
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.88
	reverb.damping = 0.25
	reverb.spread = 0.9
	reverb.wet = 0.4
	reverb.dry = 0.6
	AudioServer.add_bus_effect(bus_idx, reverb)

	# 1: LOW-PASS FILTER (swept by LFO)
	var lpf := AudioEffectLowPassFilter.new()
	lpf.cutoff_hz = 2000.0
	lpf.resonance = 1.5
	AudioServer.add_bus_effect(bus_idx, lpf)

	# 2: DELAY (tempo-synced)
	var delay := AudioEffectDelay.new()
	delay.dry = 0.85
	delay.tap1_active = true
	delay.tap1_delay_ms = 500.0
	delay.tap1_level_db = -12.0
	delay.tap1_pan = 0.2
	delay.tap2_active = true
	delay.tap2_delay_ms = 250.0
	delay.tap2_level_db = -18.0
	delay.tap2_pan = -0.2
	delay.feedback_active = true
	delay.feedback_delay_ms = 500.0
	delay.feedback_level_db = -14.0
	delay.feedback_lowpass = 8000.0
	AudioServer.add_bus_effect(bus_idx, delay)

	# 3: CHORUS
	var chorus := AudioEffectChorus.new()
	chorus.voice_count = 2
	chorus.set_voice_rate_hz(0, 0.4)
	chorus.set_voice_depth_ms(0, 2.5)
	chorus.set_voice_delay_ms(0, 8.0)
	chorus.set_voice_level_db(0, -6.0)
	chorus.set_voice_pan(0, -0.3)
	chorus.set_voice_cutoff_hz(0, 6000.0)
	chorus.set_voice_rate_hz(1, 0.55)
	chorus.set_voice_depth_ms(1, 1.8)
	chorus.set_voice_delay_ms(1, 12.0)
	chorus.set_voice_level_db(1, -8.0)
	chorus.set_voice_pan(1, 0.3)
	chorus.set_voice_cutoff_hz(1, 5000.0)
	chorus.dry = 0.85
	chorus.wet = 0.15
	AudioServer.add_bus_effect(bus_idx, chorus)

	# 4: HIGH-PASS FILTER
	var hpf := AudioEffectHighPassFilter.new()
	hpf.cutoff_hz = 40.0
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
	_delay_time_ms   = lerp(_delay_time_ms,   _target_delay_time,      ls)
	_delay_feedback  = lerp(_delay_feedback,  _target_delay_feedback,  ls)
	_delay_mix       = lerp(_delay_mix,       _target_delay_mix,       ls)
	_chorus_rate     = lerp(_chorus_rate,     _target_chorus_rate,     ls)
	_chorus_depth    = lerp(_chorus_depth,    _target_chorus_depth,    ls)
	_stereo_width    = lerp(_stereo_width,    _target_stereo_width,    ls)
	_perc_volume     = lerp(_perc_volume,     _target_perc_volume,     ls)

	# Bass portamento
	_bass_freq_actual = lerp(_bass_freq_actual, _bass_freq, 5.0 * delta)

	# Filter sweep LFO
	_filter_lfo_phase = fmod(_filter_lfo_phase + _filter_lfo_rate * delta, 1.0)

	# ── Chord progression clock ──────────────────────────────────────
	_chord_timer += delta
	_swell_phase = clampf(_chord_timer / _chord_duration, 0.0, 1.0)
	if _chord_timer >= _chord_duration:
		_chord_timer -= _chord_duration
		_advance_chord()

	# ── Arpeggiator step clock (8th notes) ───────────────────────────
	_arp_step_timer += delta
	var arp_step_dur := 60.0 / _arp_tempo / 2.0
	if _arp_step_timer >= arp_step_dur:
		_arp_step_timer -= arp_step_dur
		_advance_arp_step()

	# ── Percussion step clock (8th notes, same tempo as arp) ─────────
	_perc_step_timer += delta
	var perc_step_dur := 60.0 / _arp_tempo / 2.0
	if _perc_step_timer >= perc_step_dur:
		_perc_step_timer -= perc_step_dur
		_advance_perc_step()

	# ── Bass pulse step clock (16th notes — 2× denser than arp/perc) ────
	_bass_step_timer += delta
	var bass_step_dur := 60.0 / _arp_tempo / 4.0   # 16th notes
	if _bass_step_timer >= bass_step_dur:
		_bass_step_timer -= bass_step_dur
		_retrigger_bass_pulse()

	# Decay envelopes
	_arp_envelope = maxf(_arp_envelope - delta * 2.5, 0.0)
	_stinger_env  = maxf(_stinger_env  - delta * 4.0, 0.0)

	# ── Update bus effects ───────────────────────────────────────────
	_update_bus_effects()

	# ── Fill audio buffers ───────────────────────────────────────────
	_fill_bass_buffer()
	_fill_arp_buffer()
	_fill_perc_buffer()

# =====================================================================
#  CHORD PROGRESSION
# =====================================================================

func _get_scale() -> Array:
	if current_state == MusicState.COMBAT:
		return SCALE_DORIAN
	return SCALE_MAJOR_PENT

func _get_progression() -> Array:
	match current_state:
		MusicState.DEEP_SPACE: return PROG_SPACE
		MusicState.CRUISING:   return PROG_CRUISE
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

	# Bass target: chord root in octave 1 (C2 = 65 Hz — deep, full bass range).
	# Pulsing layer snaps here immediately; pad layer glides via portamento.
	_bass_freq = ROOT_HZ * _chord_root_ratio

	# Build arp triad from chord root within the scale
	var s_len := scale.size()
	var idx_3rd := (root_idx + 2) % s_len
	var idx_5th := (root_idx + 4) % s_len
	_arp_note_pool = [
		scale[root_idx],
		scale[idx_3rd],
		scale[idx_5th],
	]

	# Sometimes add octave root or a passing tone for variety
	var variety_roll := randf()
	if variety_roll > 0.6:
		_arp_note_pool.append(scale[root_idx] * 2.0)   # octave
	if variety_roll > 0.85:
		# Add a 4th (passing tone) for color
		var idx_4th := (root_idx + 3) % s_len
		_arp_note_pool.append(scale[idx_4th])

	_arp_direction = 1 if _chord_index % 2 == 0 else -1

	# Sync delay to beat
	_target_delay_time = 60000.0 / _arp_tempo

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

	_prev_state = current_state
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

	# Force chord reset on state change so we immediately lock to new scale
	if current_state != _prev_state:
		_chord_index = -1
		_chord_timer = _chord_duration   # triggers advance on next frame

# =====================================================================
#  TARGET PARAMETER CALCULATION
# =====================================================================

func _update_music_targets() -> void:
	match current_state:
		MusicState.DEEP_SPACE:
			_target_bass_volume     = 0.12
			_target_arp_volume      = 0.025
			_target_perc_volume     = 0.30      # sparse kick — audible but distant
			_target_filter_cutoff   = 500.0
			_target_reverb_mix      = 0.55
			_arp_tempo              = 35.0
			_chord_duration         = 8.0
			_bass_detune            = 1.003
			_target_delay_feedback  = 0.35
			_target_delay_mix       = 0.30
			_target_chorus_rate     = 0.3
			_target_chorus_depth    = 3.0
			_target_stereo_width    = 0.6
			_filter_lfo_rate        = 0.04
			_filter_lfo_depth       = 0.35
			_swell_depth            = 0.30

		MusicState.CRUISING:
			var spd_t := clampf(_ship_speed / 5000.0, 0.0, 1.0)
			_target_bass_volume     = 0.15
			_target_arp_volume      = 0.04
			_target_perc_volume     = lerpf(0.30, 0.40, spd_t)
			_target_filter_cutoff   = lerpf(700.0, 2200.0, spd_t)
			_target_reverb_mix      = 0.4
			_arp_tempo              = lerpf(45.0, 70.0, spd_t)
			_chord_duration         = lerpf(6.0, 4.0, spd_t)
			_bass_detune            = 1.005
			_target_delay_feedback  = lerpf(0.30, 0.20, spd_t)
			_target_delay_mix       = lerpf(0.25, 0.18, spd_t)
			_target_chorus_rate     = lerpf(0.4, 0.6, spd_t)
			_target_chorus_depth    = lerpf(2.5, 1.5, spd_t)
			_target_stereo_width    = 0.5
			_filter_lfo_rate        = lerpf(0.06, 0.10, spd_t)
			_filter_lfo_depth       = 0.25
			_swell_depth            = 0.20

		MusicState.ATMOSPHERE:
			_target_bass_volume     = 0.16
			_target_arp_volume      = 0.035
			_target_perc_volume     = 0.28      # soft offbeat hats — ethereal but audible
			_target_filter_cutoff   = 1000.0
			_target_reverb_mix      = 0.6
			_arp_tempo              = 50.0
			_chord_duration         = 6.0
			_bass_detune            = 1.008
			_target_delay_feedback  = 0.32
			_target_delay_mix       = 0.28
			_target_chorus_rate     = 0.35
			_target_chorus_depth    = 3.5
			_target_stereo_width    = 0.65
			_filter_lfo_rate        = 0.05
			_filter_lfo_depth       = 0.30
			_swell_depth            = 0.25

		MusicState.SURFACE:
			_target_bass_volume     = 0.15
			_target_arp_volume      = 0.045
			_target_perc_volume     = 0.40      # proper groove — full and punchy
			_target_filter_cutoff   = 1400.0
			_target_reverb_mix      = 0.45
			_arp_tempo              = 55.0
			_chord_duration         = 5.0
			_bass_detune            = 1.004
			_target_delay_feedback  = 0.22
			_target_delay_mix       = 0.20
			_target_chorus_rate     = 0.45
			_target_chorus_depth    = 2.0
			_target_stereo_width    = 0.45
			_filter_lfo_rate        = 0.07
			_filter_lfo_depth       = 0.20
			_swell_depth            = 0.15

		MusicState.COMBAT:
			_target_bass_volume     = 0.18
			_target_arp_volume      = 0.06
			_target_perc_volume     = lerpf(0.42, 0.55, _combat_tension)
			_target_filter_cutoff   = lerpf(1600.0, 3000.0, _combat_tension)
			_target_reverb_mix      = 0.25
			_arp_tempo              = lerpf(60.0, 80.0, _combat_tension)
			_chord_duration         = lerpf(4.0, 2.5, _combat_tension)
			_bass_detune            = 1.01
			_target_delay_feedback  = lerpf(0.18, 0.12, _combat_tension)
			_target_delay_mix       = lerpf(0.15, 0.10, _combat_tension)
			_target_chorus_rate     = 0.6
			_target_chorus_depth    = 1.0
			_target_stereo_width    = 0.3
			_filter_lfo_rate        = lerpf(0.08, 0.14, _combat_tension)
			_filter_lfo_depth       = lerpf(0.15, 0.10, _combat_tension)
			_swell_depth            = 0.10

# =====================================================================
#  AUDIO BUS EFFECT MODULATION
# =====================================================================

func _update_bus_effects() -> void:
	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		return
	var fx_count := AudioServer.get_bus_effect_count(bus_idx)

	if fx_count > 0:
		var fx := AudioServer.get_bus_effect(bus_idx, 0)
		if fx is AudioEffectReverb:
			fx.wet = _reverb_mix
			fx.dry = 1.0 - _reverb_mix * 0.5

	if fx_count > 1:
		var fx := AudioServer.get_bus_effect(bus_idx, 1)
		if fx is AudioEffectLowPassFilter:
			var sweep := _sin_lut(_filter_lfo_phase) * _filter_lfo_depth
			fx.cutoff_hz = clampf(_filter_cutoff * (1.0 + sweep), 200.0, 16000.0)

	if fx_count > 2:
		var fx := AudioServer.get_bus_effect(bus_idx, 2)
		if fx is AudioEffectDelay:
			fx.tap1_delay_ms = clampf(_delay_time_ms, 100.0, 2000.0)
			fx.tap1_level_db = lerpf(-20.0, -8.0, _delay_mix)
			fx.tap2_delay_ms = clampf(_delay_time_ms * 0.5, 50.0, 1000.0)
			fx.tap2_level_db = lerpf(-24.0, -14.0, _delay_mix)
			fx.feedback_delay_ms = clampf(_delay_time_ms * 0.75, 75.0, 1500.0)
			fx.feedback_level_db = lerpf(-20.0, -8.0, _delay_feedback)
			fx.feedback_lowpass = lerpf(4000.0, 8000.0, _delay_mix)

	if fx_count > 3:
		var fx := AudioServer.get_bus_effect(bus_idx, 3)
		if fx is AudioEffectChorus:
			fx.set_voice_rate_hz(0, _chorus_rate)
			fx.set_voice_depth_ms(0, _chorus_depth)
			if fx.voice_count > 1:
				fx.set_voice_rate_hz(1, _chorus_rate * 1.37)
				fx.set_voice_depth_ms(1, _chorus_depth * 0.7)
			fx.wet = clampf(_chorus_depth / 10.0, 0.08, 0.25)

	if fx_count > 4:
		var fx := AudioServer.get_bus_effect(bus_idx, 4)
		if fx is AudioEffectHighPassFilter:
			var hpf_target: float
			match current_state:
				MusicState.COMBAT:   hpf_target = lerpf(60.0, 120.0, _combat_tension)
				MusicState.CRUISING: hpf_target = 55.0
				_:                   hpf_target = 35.0
			fx.cutoff_hz = hpf_target

# =====================================================================
#  SINE / NOISE LOOKUP
# =====================================================================

func _sin_lut(phase: float) -> float:
	return _sin_table[int(phase * 256.0) & 255]

# =====================================================================
#  BASS PULSE RETRIGGER
# =====================================================================

func _get_bass_groove() -> Array:
	match current_state:
		MusicState.DEEP_SPACE: return BASS_GROOVE_SPACE
		MusicState.CRUISING:   return BASS_GROOVE_CRUISE
		MusicState.ATMOSPHERE: return BASS_GROOVE_ATMO
		MusicState.SURFACE:    return BASS_GROOVE_SURFACE
		MusicState.COMBAT:     return BASS_GROOVE_COMBAT
		_:                     return BASS_GROOVE_SPACE

func _retrigger_bass_pulse() -> void:
	_bass_step_count = (_bass_step_count + 1) % 16

	# Look up velocity from the current state's groove pattern
	var pattern := _get_bass_groove()
	var vel: float = pattern[_bass_step_count]
	if vel < 0.05:
		return   # rest step — leave envelope decaying, no retrigger

	# Per-step harmonic brightness: gives each note a unique timbre
	_bass_harm_level = randf_range(0.25, 1.0)

	_bass_pulse_env = vel
	# Decay fills 65% of the 16th-note step — short gap ensures rhythmic definition
	var step_dur := 60.0 / _arp_tempo / 4.0
	_bass_pulse_decay = pow(0.01, 1.0 / (step_dur * 0.65 * _sample_rate))

# =====================================================================
#  BASS / PAD BUFFER FILL
#  Three layers:
#    1. PULSING BASS — fundamental + 2nd/3rd harmonics, retriggered envelope
#       per 8th note. Centered for punch. Harmonics use wave-equation
#       insight: 2nd harmonic = tbl[phase*512], 3rd = tbl[phase*768],
#       no extra phase accumulators needed.
#    2. SUSTAINED PAD — detuned oscillator, continuous with breathing LFO,
#       stereo-spread for atmosphere.
#    3. SUB — half-frequency sine, continuous, centered for warmth.
# =====================================================================

func _fill_bass_buffer() -> void:
	if not _drone_playback:
		return
	var frames := mini(_drone_playback.get_frames_available(), _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	# Harmonic LFO: global timbral drift (~0.08 Hz, ~12s cycle)
	_harmonic_lfo_phase = fmod(_harmonic_lfo_phase + 0.08 * float(frames) / _sample_rate, 1.0)
	var harm_lfo := _sin_lut(_harmonic_lfo_phase) * 0.3 + 0.5   # 0.2..0.8
	# Combine slow LFO with per-step brightness (set each retrigger) for timbral movement
	var harm_mix := clampf(harm_lfo * _bass_harm_level, 0.0, 1.0)

	# Pad breathing LFO (continuous, slow)
	var pad_lfo := _sin_lut(_lfo_phase) * 0.25 + 0.75
	_lfo_phase = fmod(_lfo_phase + 0.12 * float(frames) / _sample_rate, 1.0)

	var swell_env := 1.0 - _swell_depth + _swell_depth * sin(_swell_phase * PI)

	var vol   := _bass_volume * swell_env
	# PULSING BASS uses _bass_freq directly — snaps to chord root, no portamento.
	# PAD and SUB use _bass_freq_actual — glides smoothly (portamento) for warmth.
	var freq_pulse := _bass_freq
	var freq_pad   := _bass_freq_actual * _bass_detune
	var freq_sub   := _bass_freq_actual * 0.5
	var inv_r := 1.0 / _sample_rate

	var p1  := _bass_phase_1
	var p2  := _bass_phase_2
	var ps  := _bass_phase_sub
	var tbl := _sin_table
	var sw  := _stereo_width
	var bpe := _bass_pulse_env
	var bpd := _bass_pulse_decay

	for i in frames:
		# ── LAYER 1: PULSING BASS — snaps to chord root, retriggered per 16th note ──
		var osc1 := tbl[int(p1 * 256.0) & 255]
		# 2nd harmonic (octave above): phase × 2, amplitude 1/2 (wave equation 1/n)
		var harm2 := tbl[int(p1 * 512.0) & 255]
		# 3rd harmonic (octave + fifth): phase × 3, amplitude 1/3
		var harm3 := tbl[int(p1 * 768.0) & 255]
		# Blend: fundamental always present, harmonics scaled by per-step brightness
		var bass_raw := osc1 + harm2 * (0.50 * harm_mix) + harm3 * (0.33 * harm_mix)
		var pulse_s  := bass_raw * bpe * 0.44   # envelope shapes attack/decay

		# ── LAYER 2: SUSTAINED PAD — detuned, continuous, portamento glide ──
		var pad := tbl[int(p2 * 256.0) & 255] * pad_lfo * 0.20

		# ── LAYER 3: SUB — half-freq sine, continuous, centered for weight ──
		var sub := tbl[int(ps * 256.0) & 255] * 0.24

		# Mix: pulse + sub centered for punch; pad stereo-spread for spatial width
		var center := (pulse_s + sub) * vol
		var left  := center + pad * (0.5 + sw * 0.28) * vol
		var right := center + pad * (0.5 - sw * 0.28) * vol

		# Stinger overlay
		if _stinger_env > 0.001:
			var st := tbl[int(_stinger_phase * 256.0) & 255] * _stinger_env * _stinger_vol
			left += st
			right += st
			_stinger_phase = fmod(_stinger_phase + _stinger_freq * inv_r, 1.0)

		p1 = fmod(p1 + freq_pulse * inv_r, 1.0)
		p2 = fmod(p2 + freq_pad   * inv_r, 1.0)
		ps = fmod(ps + freq_sub   * inv_r, 1.0)
		bpe *= bpd
		_drone_playback.push_frame(Vector2(left, right))

	_bass_phase_1   = p1
	_bass_phase_2   = p2
	_bass_phase_sub = ps
	_bass_pulse_env = bpe

# =====================================================================
#  ARPEGGIATOR
# =====================================================================

func _advance_arp_step() -> void:
	_arp_phrase_count += 1

	var is_ghost := false
	if randf() < 0.28:
		if randf() < 0.15:
			is_ghost = true
		else:
			_arp_rest = true
			_arp_envelope = 0.0
			return

	_arp_rest = false

	if _arp_note_pool.is_empty():
		return

	_arp_step_index += _arp_direction
	if _arp_step_index >= _arp_note_pool.size():
		_arp_step_index = 0
	elif _arp_step_index < 0:
		_arp_step_index = _arp_note_pool.size() - 1

	var ratio: float = _arp_note_pool[_arp_step_index]

	var octave := 3
	if randf() > 0.8:
		octave = 4
	elif randf() > 0.92:
		octave = 2

	_arp_current_freq = ROOT_HZ * ratio * pow(2.0, float(octave - 1))

	var accent_idx := _arp_phrase_count % ACCENT_PATTERN.size()
	_arp_accent = ACCENT_PATTERN[accent_idx]

	if is_ghost:
		_arp_accent *= 0.20

	_arp_envelope = _arp_accent
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
	var pan   := _arp_pan

	if _arp_rest or vol < 0.0005:
		for i in frames:
			_arp_playback.push_frame(Vector2.ZERO)
		return

	var pan_l := clampf(1.0 - pan, 0.0, 1.5)
	var pan_r := clampf(1.0 + pan, 0.0, 1.5)

	for i in frames:
		phase = fmod(phase + freq * inv_r, 1.0)

		var saw  := phase * 2.0 - 1.0
		var sine := tbl[int(phase * 256.0) & 255]
		var s    := (saw * 0.25 + sine * 0.75) * vol * filt

		_arp_playback.push_frame(Vector2(s * pan_l, s * pan_r))

	_arp_phase = phase

# =====================================================================
#  PERCUSSION ENGINE
#  Kick: sine pitch sweep 150→40 Hz (70ms)
#  Snare: noise + 200Hz tone (100ms)
#  Hi-hat: noise burst (30ms, crisp)
# =====================================================================

func _get_perc_pattern() -> Array:
	match current_state:
		MusicState.DEEP_SPACE: return PATTERN_SPACE
		MusicState.CRUISING:   return PATTERN_CRUISE
		MusicState.ATMOSPHERE: return PATTERN_ATMO
		MusicState.SURFACE:    return PATTERN_SURFACE
		MusicState.COMBAT:     return PATTERN_COMBAT
		_:                     return PATTERN_SPACE

func _advance_perc_step() -> void:
	_perc_step_index = (_perc_step_index + 1) % 8
	if _perc_step_index == 0:
		_perc_bar_count += 1

	# Pick pattern: use a fill every 4th bar for variation
	var pattern: Array
	if _perc_bar_count % 4 == 3 and _perc_step_index >= 4:
		# Last 4 steps of every 4th bar = fill
		pattern = FILL_A if _perc_bar_count % 8 < 4 else FILL_B
	else:
		pattern = _get_perc_pattern()

	var step: int = pattern[_perc_step_index]

	# Slight humanization: 10% chance to drop a non-kick hit
	if randf() < 0.10 and step > 1:
		step = step & 1   # keep kick, drop snare/hat

	# Trigger drums based on bitfield
	if step & 1:   # kick
		_kick_env = 1.0
		_kick_phase = 0.0
	if step & 2:   # snare
		_snare_env = 1.0
		_snare_phase = 0.0
	if step & 4:   # hi-hat
		_hat_env = 1.0

func _fill_perc_buffer() -> void:
	if not _perc_playback:
		return
	var frames := mini(_perc_playback.get_frames_available(), _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	var inv_r := 1.0 / _sample_rate
	var vol := _perc_volume
	var tbl := _sin_table
	var ntbl := _noise_table

	var ke := _kick_env
	var kp := _kick_phase
	var kd := _kick_decay
	var se := _snare_env
	var sp := _snare_phase
	var sd := _snare_decay
	var he := _hat_env
	var hd := _hat_decay
	var ni := _noise_idx

	# Early out if nothing is playing
	if ke < 0.001 and se < 0.001 and he < 0.001 and vol < 0.001:
		for i in frames:
			_perc_playback.push_frame(Vector2.ZERO)
		_kick_env = ke
		_snare_env = se
		_hat_env = he
		return

	for i in frames:
		var s := 0.0

		# KICK: sine with pitch sweep (150Hz → 40Hz as envelope decays)
		if ke > 0.001:
			var kick_freq := 40.0 + 110.0 * ke   # sweeps down
			kp = fmod(kp + kick_freq * inv_r, 1.0)
			s += tbl[int(kp * 256.0) & 255] * ke * KICK_VOL
			ke *= kd

		# SNARE: noise (60%) + 200Hz sine (40%), medium decay
		if se > 0.001:
			var snare_tone := tbl[int(sp * 256.0) & 255] * 0.4
			var snare_noise := ntbl[ni & 1023] * 0.6
			s += (snare_tone + snare_noise) * se * SNARE_VOL
			sp = fmod(sp + 200.0 * inv_r, 1.0)
			se *= sd
			ni = (ni + 1) & 1023

		# HI-HAT: pure noise, very fast decay (crisp)
		if he > 0.001:
			s += ntbl[ni & 1023] * he * HAT_VOL
			he *= hd
			ni = (ni + 1) & 1023

		s *= vol
		# Slight stereo spread on perc (hat slightly right, snare slightly left)
		_perc_playback.push_frame(Vector2(s * 1.05, s * 0.95))

	_kick_env  = ke
	_kick_phase = kp
	_snare_env = se
	_snare_phase = sp
	_hat_env   = he
	_noise_idx = ni

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

# =====================================================================
#  SFX PLAYBACK
# =====================================================================

func play_fire() -> void:
	if _sfx_ship_fire:
		_sfx_ship_fire.stop()
		_sfx_ship_fire.play()

func play_boost() -> void:
	if _sfx_ship_boost:
		_sfx_ship_boost.stop()
		_sfx_ship_boost.play()

func play_thrusters_loop() -> void:
	if _sfx_ship_thrusters and not _sfx_ship_thrusters.playing:
		_sfx_ship_thrusters.play()

func stop_thrusters() -> void:
	if _sfx_ship_thrusters:
		_sfx_ship_thrusters.stop()

func play_explosion(is_big: bool = false) -> void:
	var sfx = _sfx_explosion_big if is_big else _sfx_explosion_small
	if sfx:
		sfx.stop()
		sfx.play()
