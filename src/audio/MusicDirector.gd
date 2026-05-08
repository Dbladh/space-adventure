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
#  BEAT-SYNC API
#  Other systems (minerals, stars, asteroids, UI...) can subscribe to
#  these signals or read the *_intensity floats each frame to animate
#  in time with the music.
# =====================================================================

signal beat_pulse(velocity: float, step_index: int)   # every 16th-note step
signal kick_hit(velocity: float)                      # only when a kick fires

# Smoothly-decaying intensity floats (decay tracked in _process).
# Subscribers without a signal handler can just read these each frame.
var beat_intensity: float = 0.0       # peaks on every step, smaller on off-beats
var kick_intensity: float = 0.0       # peaks only on kick hits — strongest pulse

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
var _arp2_player: AudioStreamPlayer
var _arp2_playback: AudioStreamGeneratorPlayback
var _perc_player: AudioStreamPlayer
var _perc_playback: AudioStreamGeneratorPlayback

# =====================================================================
#  SFX PLAYERS
# =====================================================================

var _sfx_ship_fire: AudioStreamPlayer
var _sfx_ship_idle: AudioStreamPlayer    # constant low hum, always looping
var _sfx_ship_thruster: AudioStreamPlayer  # ship_thrusters.wav looped, normal movement
var _sfx_ship_boost: AudioStreamPlayer    # ship_boost.wav looped, warp/boost mode

var _sfx_explosion_small: AudioStreamPlayer
var _sfx_explosion_big: AudioStreamPlayer
var _sfx_item_collect: AudioStreamPlayer  # item collect/shard pickup

# Boost state tracking (for one-shot start sound)
var _was_boosting: bool = false

# Thruster fadeout state
var _thruster_fadeout_time: float = 0.0
var _thruster_target_volume: float = -48.0
var _thruster_target_pitch: float = 0.5
const THRUSTER_FADEOUT_DURATION: float = 0.3

# Boost fadeout state
var _boost_fadeout_time: float = 0.0
var _boost_target_volume: float = -48.0
var _boost_target_pitch: float = 0.5
const BOOST_FADEOUT_DURATION: float = 0.3

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

# Arp oscillators
var _arp_phase: float = 0.0
var _arp2_phase: float = 0.0

# Current parameters (smoothly interpolated)
var _bass_freq: float = 130.82
var _bass_freq_actual: float = 130.82
var _bass_detune: float = 1.003
var _bass_volume: float = 0.12
var _arp_volume: float = 0.02
var _filter_cutoff: float = 600.0
var _reverb_mix: float = 0.5
var _perc_volume: float = 0.0        # percussion master volume
var _growl_amount: float = 0.5       # 0 = clean sine bass; 1 = full saw + filter env + drive

# Atmospheric / ambient knobs.
# 0 = pure rhythmic (full sidechain + stabs + percussive arp);
# 1 = pure ambient (no pump, no stabs, legato wash + drone + big reverb).
var _ambient_factor: float = 0.0
var _target_ambient_factor: float = 0.0

# Arp note duration multiplier — sets how much each note overlaps the next.
# 0.78 = staccato (current default); 2.5 = heavy legato wash for ambient.
var _arp_legato_factor: float = 0.78

# Chord pad — sustained polyphonic chord layer (the foundation of ambient).
var _pad_volume: float = 0.0
var _target_pad_volume: float = 0.0

# Target parameters
var _target_bass_volume: float = 0.12
var _target_arp_volume: float = 0.02
var _target_filter_cutoff: float = 600.0
var _target_reverb_mix: float = 0.5
var _target_perc_volume: float = 0.0
var _target_growl_amount: float = 0.5
var _target_reverb_room: float = 0.80
var _target_reverb_predelay_ms: float = 12.0

# Bass filter envelope (per-pulse resonant LP) — Chamberlin SVF state.
var _bass_filter_z1: float = 0.0
var _bass_filter_z2: float = 0.0
var _bass_filter_env: float = 0.0
var _bass_filter_env_decay: float = 0.999
const _BASS_FILTER_MIN_HZ := 220.0
const _BASS_FILTER_MAX_HZ := 3800.0
const _BASS_FILTER_Q       := 0.7    # 1/Q in the SVF — lower = more resonant peak

# Slow growl LFO — modulates filter cutoff range, drive, and saturation depth
# over ~25 seconds so the bass timbre breathes across phrases instead of
# hitting identically every bar.
var _bass_growl_lfo_phase: float = 0.0
const _BASS_GROWL_LFO_HZ := 0.04   # ~25s period

# Slow stereo pan LFO for the arp voices — sweeps the lead arp from full
# left to full right and back over ~17 seconds. Arp2 uses the inverted
# value so the two voices are always panned opposite each other —
# stereo "conversation".
var _arp_pan_lfo_phase: float = 0.0
const _ARP_PAN_LFO_HZ := 0.058   # ~17s period

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

# Audio generation timing (for frame-rate independent audio)
var _last_audio_time: float = 0.0
const _MAX_AUDIO_CATCHUP: float = 0.1  # Max 100ms catchup per frame to prevent stutter
const _MAX_FILL_FRAMES: int = 4410    # 100ms at 44.1kHz

# =====================================================================
#  KEY & SCALE SYSTEM
#  Harmony decisions live in HarmonyEngine. ROOT_HZ stays here as a
#  cached mirror of the engine's current root so synthesis (arp, accents)
#  doesn't have to thread the engine reference through every call.
# =====================================================================

const ROOT_HZ := 65.41   # base; HarmonyEngine.current_root_hz tracks live value

# =====================================================================
#  CHORD PROGRESSION
# =====================================================================

var _chord_timer: float = 0.0
var _chord_duration: float = 6.0
var _chord_index: int = -1
var _chord_root_ratio: float = 1.0
var _arp_note_pool: Array = [1.0]

# Harmony engine — owns scale/mode/progression/voicing decisions.
var _harmony: HarmonyEngine = null

# Voice bank + melody engine — own timbre selection and (Phase C) arp logic.
var _voice_bank: VoiceBank = null
var _melody: MelodyEngine = null

# Rhythm bank — owns percussion patterns, fills, bass grooves.
var _rhythm: RhythmBank = null

# Persistent voice contexts (phases live across fill calls).
var _arp_voice_ctx: Dictionary = {
	"phase": 0.0, "phase2": 0.0, "phase3": 0.0, "lfo_phase": 0.0,
	"freq": 220.0, "env": 0.0, "vol": 0.0, "pan_l": 1.0, "pan_r": 1.0,
	"filt": 1.0, "sample_rate": 44100.0,
	"sin_table": null, "noise_table": null,
}
var _arp2_voice_ctx: Dictionary = {
	"phase": 0.0, "phase2": 0.0, "phase3": 0.0, "lfo_phase": 0.0,
	"freq": 440.0, "env": 0.0, "vol": 0.0, "pan_l": 1.4, "pan_r": 0.6,
	"filt": 1.0, "sample_rate": 44100.0,
	"sin_table": null, "noise_table": null,
}

# =====================================================================
#  ARPEGGIATOR
# =====================================================================

var _arp_tempo: float = 40.0
var _arp_current_freq: float = 220.0
var _arp_envelope: float = 0.0
var _arp_decay_rate: float = 2.5    # recomputed each step to fill 75% of the step duration
var _arp_rest: bool = false
var _arp_pan: float = 0.0
var _arp_accent: float = 0.85

var _arp2_current_freq: float = 440.0
var _arp2_envelope: float = 0.0
var _arp2_vol: float = 0.0
var _arp2_target_vol: float = 0.0
var _arp2_vol_lfo_phase: float = 0.0

# =====================================================================
#  PERCUSSION ENGINE
#  Synthesized drums: kick (sine sweep), snare (noise+tone), hi-hat (noise)
#  Patterns per state, with occasional fills for variation.
# =====================================================================

# Drum envelopes (triggered per hit, decay per sample)
var _kick_env: float = 0.0
var _kick_phase: float = 0.0
var _kick_sub_phase: float = 0.0     # separate sub-bass tracker for body weight
var _kick_decay: float = 0.998       # computed in _ready
var _snare_env: float = 0.0
var _snare_phase: float = 0.0
var _snare_decay: float = 0.999
var _hat_env: float = 0.0
var _hat_decay: float = 0.997
var _hat_p1: float = 0.0             # 3 inharmonic squares for metallic hat
var _hat_p2: float = 0.0
var _hat_p3: float = 0.0
# Open hi-hat — same metallic synth, much longer decay (~130ms vs 18ms).
# Used on off-beats for groove ("tss-tss-tssssh-tss" feel).
var _open_hat_env: float = 0.0
var _open_hat_decay: float = 0.998
var _open_hat_p1: float = 0.0
var _open_hat_p2: float = 0.0
var _open_hat_p3: float = 0.0
# Crash cymbal — bandpass-swept noise with a long ringing tail. Triggered
# every N bars on the downbeat to punctuate big section changes.
var _crash_env: float = 0.0
var _crash_decay: float = 0.999
var _crash_filter_z1: float = 0.0
var _crash_filter_z2: float = 0.0
var _crash_pan: float = 0.0
# Tom — single voice that takes a frequency parameter on trigger so the
# same synth slot covers hi/mid/lo toms in fills.
var _tom_env: float = 0.0
var _tom_phase: float = 0.0
var _tom_freq: float = 120.0
var _tom_decay: float = 0.998
var _tom_pan: float = 0.0
# Snare tail — short comb filter for "snare-in-a-room" ambience.
var _snare_tail_buf: PackedFloat32Array
var _snare_tail_idx: int = 0
var _noise_idx: int = 0

# Per-hit velocities (set when the step fires, applied in synth loop).
var _kick_vel: float = 1.0
var _snare_vel: float = 1.0
var _hat_vel: float = 1.0
var _open_hat_vel: float = 1.0
var _tom_vel: float = 1.0

# Per-drum volumes (relative to _perc_volume master)
const KICK_VOL  := 0.58       # boosted — kick should anchor the whole mix
const SNARE_VOL := 0.27
const HAT_VOL   := 0.14

# Sidechain ducking — kick attack triggers a bass/arp volume duck that
# decays over ~250ms. Single env shared across all duckable layers.
var _sidechain_env: float = 0.0
var _sidechain_decay: float = 0.999

# Percussion step tracking
var _perc_step_index: int = 7    # init to 7 so first advance lands on step 0 (downbeat)
var _perc_bar_count: int = 0          # track bars for fills

# Percussion patterns, fills, and bass grooves now live in RhythmBank.

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
var _master_step_counter: int = 0

# Per-step harmonic brightness: randomized each retrigger → each note has unique timbre.
var _bass_harm_level: float = 0.5

# Harmonic LFO: slow global timbral drift (~0.08 Hz, ~12s per cycle)
var _harmonic_lfo_phase: float = 0.0

# =====================================================================
#  AMBIENT ACCENT ENGINE
#  Occasional organic events layered over the procedural base:
#    1. STRING STAB  — 3 detuned voices, slow attack/release (2-4s)
#    2. AMBIENT DRONE — low root tone with slow vibrato (3-6s)
#    3. SHIMMER      — high-register bell tones, short decay (0.5-1.5s)
#  Fires every 8-22 seconds at random; type weighted by current state.
# =====================================================================

var _accent_player: AudioStreamPlayer
var _accent_playback: AudioStreamGeneratorPlayback

var _accent_type: int = 0        # 0=idle 1=strings 2=drone 3=shimmer
var _accent_stage: int = 0       # 0=attack 1=sustain 2=release
var _accent_env: float = 0.0     # amplitude 0..1
var _accent_atk_rate: float = 2.0
var _accent_rel_rate: float = 1.5
var _accent_sustain_t: float = 0.0
var _accent_timer: float = 5.0   # first accent fires ~5s in

# =====================================================================
#  RISER ENGINE — bandpass-swept noise that climbs in pitch + volume
#  during the bar before each drop. Routed through Music bus for reverb.
# =====================================================================

var _riser_player: AudioStreamPlayer
var _riser_playback: AudioStreamGeneratorPlayback
var _riser_active: bool = false
var _riser_progress: float = 0.0
var _riser_duration: float = 1.0
var _riser_filter_z1: float = 0.0
var _riser_filter_z2: float = 0.0
var _riser_noise_idx: int = 0
var _riser_pitch_phase: float = 0.0     # for the upward sine glissando
var _riser_pan_dir: float = 1.0         # ±1, randomized per trigger

# =====================================================================
#  CHORD STAB ENGINE — short polyphonic pluck on phrase downbeats.
#  Plays the active chord pool (root+3rd+5th+7th when present) with a
#  sharp pluck envelope. Adds rhythmic punctuation that the ear can
#  follow as section structure.
# =====================================================================

var _stab_player: AudioStreamPlayer
var _stab_playback: AudioStreamGeneratorPlayback
var _stab_env: float = 0.0
var _stab_decay: float = 0.999
var _stab_freqs: PackedFloat32Array
var _stab_phases: PackedFloat32Array
var _stab_voice_count: int = 0
var _stab_pan: float = 0.0          # per-trigger pan (-1..+1)

# =====================================================================
#  CHORD PAD ENGINE — sustained polyphonic chord layer (the ambient
#  foundation). Plays root/3rd/5th/7th continuously with portamento
#  glides between chord changes, slow attack on first chord, and
#  state-driven volume so it dominates ambient states and stays out of
#  the way during rhythmic ones.
# =====================================================================

var _pad_player: AudioStreamPlayer
var _pad_playback: AudioStreamGeneratorPlayback
var _pad_freqs: PackedFloat32Array         # current playing freqs (lerped)
var _pad_target_freqs: PackedFloat32Array  # next chord's freqs (target)
var _pad_phases: PackedFloat32Array
var _pad_voice_count: int = 0
var _pad_env: float = 0.0                  # 0..1 attack envelope
var _pad_target_env: float = 0.0
const _PAD_ATTACK_RATE: float = 0.7        # seconds-1 → ~1.4s attack
const _PAD_VOICES_MAX: int = 6

# =====================================================================
#  DRONE UNDERTONE — sustained sine at the key root (NOT the chord
#  root), gated by ambient_factor. Provides the constant tonic earth
#  that ambient music floats above.
# =====================================================================

var _drone_phase: float = 0.0

var _acc_p1: float = 0.0
var _acc_p2: float = 0.0
var _acc_p3: float = 0.0
var _acc_lfo_ph: float = 0.0
var _acc_freq1: float = 220.0
var _acc_freq2: float = 221.0
var _acc_freq3: float = 219.0
var _acc_vol: float = 0.0
var _acc_pan: float = 0.0

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

	# Electronic drum decays — tighter than acoustic for punchy digital feel
	_kick_decay  = pow(0.01, 1.0 / (0.090 * _sample_rate))  # 90ms — longer tail = more body
	_snare_decay = pow(0.01, 1.0 / (0.060 * _sample_rate))  # 60ms snare
	_hat_decay   = pow(0.01, 1.0 / (0.018 * _sample_rate))  # 18ms closed hat — crisp tick
	_open_hat_decay = pow(0.01, 1.0 / (0.130 * _sample_rate))  # 130ms open hat — sloshy ring
	_crash_decay = pow(0.01, 1.0 / (1.80 * _sample_rate))   # 1.8s crash — long ringing tail
	_tom_decay   = pow(0.01, 1.0 / (0.180 * _sample_rate))  # 180ms tom — pitched body

	# Snare tail comb filter — 80ms delay buffer.
	var snare_tail_samples: int = int(0.080 * _sample_rate)
	_snare_tail_buf.resize(snare_tail_samples)
	for i in snare_tail_samples:
		_snare_tail_buf[i] = 0.0

	# Sidechain envelope decays over ~220ms — long enough that bass stays
	# ducked through the kick body, short enough to recover before the next.
	_sidechain_decay = pow(0.01, 1.0 / (0.220 * _sample_rate))

	_setup_music_bus()

	# Bass/pad generator — goes to BassLine bus (DRY — no reverb, obvious punch)
	_drone_player = AudioStreamPlayer.new()
	_drone_player.bus = "BassLine"
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

	# Arp2 generator (Triangle, fast)
	_arp2_player = AudioStreamPlayer.new()
	_arp2_player.bus = "Music"
	var arp2_stream := AudioStreamGenerator.new()
	arp2_stream.mix_rate = _sample_rate
	arp2_stream.buffer_length = 0.15
	_arp2_player.stream = arp2_stream
	add_child(_arp2_player)
	_arp2_player.play()
	_arp2_playback = _arp2_player.get_stream_playback()

	# Percussion generator — goes to Perc bus (DRY — no reverb, electronic punch)
	_perc_player = AudioStreamPlayer.new()
	_perc_player.bus = "Perc"
	var perc_stream := AudioStreamGenerator.new()
	perc_stream.mix_rate = _sample_rate
	perc_stream.buffer_length = 0.15
	_perc_player.stream = perc_stream
	add_child(_perc_player)
	_perc_player.play()
	_perc_playback = _perc_player.get_stream_playback()

	# Accent generator — goes to Music bus so it gets reverb/delay treatment
	_accent_player = AudioStreamPlayer.new()
	_accent_player.bus = "Music"
	var accent_stream := AudioStreamGenerator.new()
	accent_stream.mix_rate = _sample_rate
	accent_stream.buffer_length = 0.20   # slightly longer buffer for smooth attack
	_accent_player.stream = accent_stream
	add_child(_accent_player)
	_accent_player.play()
	_accent_playback = _accent_player.get_stream_playback()

	# Riser generator — Music bus so reverb tail blends into the drop.
	_riser_player = AudioStreamPlayer.new()
	_riser_player.bus = "Music"
	var riser_stream := AudioStreamGenerator.new()
	riser_stream.mix_rate = _sample_rate
	riser_stream.buffer_length = 0.20
	_riser_player.stream = riser_stream
	add_child(_riser_player)
	_riser_player.play()
	_riser_playback = _riser_player.get_stream_playback()

	# Chord stab generator — Music bus for reverb space behind the pluck.
	_stab_player = AudioStreamPlayer.new()
	_stab_player.bus = "Music"
	var stab_stream := AudioStreamGenerator.new()
	stab_stream.mix_rate = _sample_rate
	stab_stream.buffer_length = 0.15
	_stab_player.stream = stab_stream
	add_child(_stab_player)
	_stab_player.play()
	_stab_playback = _stab_player.get_stream_playback()
	_stab_freqs.resize(8)
	_stab_phases.resize(8)
	_stab_decay = pow(0.01, 1.0 / (0.300 * _sample_rate))   # 300ms pluck

	# Chord pad generator — Music bus for full reverb wash.
	_pad_player = AudioStreamPlayer.new()
	_pad_player.bus = "Music"
	var pad_stream := AudioStreamGenerator.new()
	pad_stream.mix_rate = _sample_rate
	pad_stream.buffer_length = 0.20   # longer buffer = smoother sustained sound
	_pad_player.stream = pad_stream
	add_child(_pad_player)
	_pad_player.play()
	_pad_playback = _pad_player.get_stream_playback()
	_pad_freqs.resize(_PAD_VOICES_MAX)
	_pad_target_freqs.resize(_PAD_VOICES_MAX)
	_pad_phases.resize(_PAD_VOICES_MAX)

	# ── SFX players ─────────────────────────────────────────────────────
	# Weapon fire — oneshot, quieter than music so it doesn't overpower
	_sfx_ship_fire = AudioStreamPlayer.new()
	_sfx_ship_fire.bus = "Master"
	_sfx_ship_fire.stream = load("res://assets/resources/audio/ship_fire.wav")
	_sfx_ship_fire.volume_db = -14.0
	add_child(_sfx_ship_fire)

	# Idle hum — looping, very low-level ambient background at all times
	var idle_stream = load("res://assets/resources/audio/ship_idle.wav")
	print("[SFX] ship_idle.wav loaded: ", idle_stream)
	_sfx_ship_idle = AudioStreamPlayer.new()
	_sfx_ship_idle.bus = "Master"
	_sfx_ship_idle.stream = idle_stream
	_sfx_ship_idle.volume_db = -28.0   # barely audible ambient hum
	_sfx_ship_idle.stream_paused = false
	add_child(_sfx_ship_idle)
	print("[SFX] ship_idle: stream loaded, playing")
	_sfx_ship_idle.play()
	print("[SFX] ship_idle playing: ", _sfx_ship_idle.playing)

	# Thruster engine (normal movement) — uses ship_thrusters.wav, pitch+vol scale with speed
	var thruster_stream = load("res://assets/resources/audio/ship_thrusters.wav")
	_sfx_ship_thruster = AudioStreamPlayer.new()
	_sfx_ship_thruster.bus = "Master"
	_sfx_ship_thruster.stream = thruster_stream
	_sfx_ship_thruster.volume_db = -36.0
	_sfx_ship_thruster.pitch_scale = 0.8
	add_child(_sfx_ship_thruster)

	# Boost engine (warp mode) — uses ship_boost.wav, starts low and increases gradually with speed
	var boost_stream = load("res://assets/resources/audio/ship_boost.wav")
	_sfx_ship_boost = AudioStreamPlayer.new()
	_sfx_ship_boost.bus = "Master"
	_sfx_ship_boost.stream = boost_stream
	_sfx_ship_boost.volume_db = -56.0
	_sfx_ship_boost.pitch_scale = 0.4
	add_child(_sfx_ship_boost)


	# Explosions — proportionally louder than music to feel impactful
	_sfx_explosion_small = AudioStreamPlayer.new()
	_sfx_explosion_small.bus = "Master"
	_sfx_explosion_small.stream = load("res://assets/resources/audio/explosion_small.wav")
	_sfx_explosion_small.volume_db = -8.0
	add_child(_sfx_explosion_small)

	_sfx_explosion_big = AudioStreamPlayer.new()
	_sfx_explosion_big.bus = "Master"
	_sfx_explosion_big.stream = load("res://assets/resources/audio/explosion_big.mp3")
	_sfx_explosion_big.volume_db = -4.0
	add_child(_sfx_explosion_big)

	# Item collection — shard pickup sound
	_sfx_item_collect = AudioStreamPlayer.new()
	_sfx_item_collect.bus = "Master"
	_sfx_item_collect.stream = load("res://assets/resources/audio/item_collect.wav")
	_sfx_item_collect.volume_db = -10.0
	add_child(_sfx_item_collect)

	# Harmony engine owns scale/mode/progression/voicing decisions.
	_harmony = HarmonyEngine.new()
	_voice_bank = VoiceBank.new()
	_melody = MelodyEngine.new()
	_rhythm = RhythmBank.new()
	_rhythm.notify_bar_start(current_state, 0)

	# Wire shared LUTs + sample rate into voice contexts.
	_arp_voice_ctx["sin_table"] = _sin_table
	_arp_voice_ctx["noise_table"] = _noise_table
	_arp_voice_ctx["sample_rate"] = _sample_rate
	_arp2_voice_ctx["sin_table"] = _sin_table
	_arp2_voice_ctx["noise_table"] = _noise_table
	_arp2_voice_ctx["sample_rate"] = _sample_rate

	# Initialize bass frequency
	_bass_freq = ROOT_HZ * 2.0
	_bass_freq_actual = _bass_freq
	_advance_chord()

func _setup_aux_bus(bus_name: String, volume_db: float) -> void:
	# Creates a dry aux bus with no effects — used for bass and percussion.
	var bus_idx := AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		AudioServer.add_bus()
		bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_idx, bus_name)
		AudioServer.set_bus_send(bus_idx, "Master")
	AudioServer.set_bus_volume_db(bus_idx, volume_db)
	while AudioServer.get_bus_effect_count(bus_idx) > 0:
		AudioServer.remove_bus_effect(bus_idx, 0)

func _setup_music_bus() -> void:
	# Dry buses for bass (no reverb smear) and percussion (no reverb wash)
	_setup_aux_bus("BassLine", -4.0)   # slightly hotter than music
	_setup_aux_bus("Perc", -3.0)       # drums hit harder when dry

	# Heavy bus compression on Perc — squashes peaks more aggressively for
	# the "wall of drums" feel. Lower threshold + higher ratio + more makeup
	# gain pushes the whole mix forward without crushing transients.
	var perc_bus := AudioServer.get_bus_index("Perc")
	if perc_bus != -1:
		var perc_comp := AudioEffectCompressor.new()
		perc_comp.threshold = -20.0     # was -16: lower = more compression engaged
		perc_comp.ratio = 6.0           # was 4: harder ratio
		perc_comp.attack_us = 4000.0    # 4ms — still fast enough to catch transients
		perc_comp.release_ms = 90.0
		perc_comp.gain = 6.5            # was 4: more makeup gain
		AudioServer.add_bus_effect(perc_bus, perc_comp)

		# Saturation — adds harmonic density and "thickness". Drums sound
		# bigger because the saturation generates upper harmonics that fool
		# the ear into perceiving more low-end weight (the "exciter" effect).
		var perc_drive := AudioEffectDistortion.new()
		perc_drive.mode = AudioEffectDistortion.MODE_OVERDRIVE
		perc_drive.drive = 0.22
		perc_drive.pre_gain = 1.5
		perc_drive.post_gain = -3.5
		AudioServer.add_bus_effect(perc_bus, perc_drive)

		# Drum room reverb — short small-room reverb (~120ms tail) damps
		# highs so cymbals don't smear. Gives drums physical space without
		# making them sound washed-out.
		var perc_room := AudioEffectReverb.new()
		perc_room.room_size = 0.35
		perc_room.damping = 0.70           # high damping keeps it tight
		perc_room.spread = 0.75
		perc_room.predelay_msec = 8.0
		perc_room.predelay_feedback = 0.18
		perc_room.wet = 0.14               # subtle — drums stay punchy
		perc_room.dry = 0.92
		AudioServer.add_bus_effect(perc_bus, perc_room)

	# Bus-level overdrive on BassLine — adds tube-style fatness on top of the
	# per-sample saturation. Mild settings so it warms without crushing.
	var bass_bus := AudioServer.get_bus_index("BassLine")
	if bass_bus != -1:
		var bass_drive := AudioEffectDistortion.new()
		bass_drive.mode = AudioEffectDistortion.MODE_OVERDRIVE
		bass_drive.drive = 0.25
		bass_drive.pre_gain = 2.0
		bass_drive.post_gain = -4.0
		AudioServer.add_bus_effect(bass_bus, bass_drive)

		# Reverb on bass — bigger room and more wet so the space is audible.
		# Damping is high so it doesn't smear the punch; predelay keeps the
		# transient clear.
		var bass_verb := AudioEffectReverb.new()
		bass_verb.room_size = 0.70
		bass_verb.damping = 0.45
		bass_verb.spread = 0.7
		bass_verb.predelay_msec = 18.0
		bass_verb.predelay_feedback = 0.25
		bass_verb.wet = 0.32
		bass_verb.dry = 0.85
		AudioServer.add_bus_effect(bass_bus, bass_verb)

		# Tempo-synced delay for groove + space. Modest wet so the dry hits
		# stay punchy but each pulse leaves an echo that sits behind the next.
		var bass_delay := AudioEffectDelay.new()
		bass_delay.dry = 0.88
		bass_delay.tap1_active = true
		bass_delay.tap1_delay_ms = 375.0           # updated per-frame to track tempo
		bass_delay.tap1_level_db = -10.0
		bass_delay.tap1_pan = -0.15
		bass_delay.tap2_active = true
		bass_delay.tap2_delay_ms = 250.0
		bass_delay.tap2_level_db = -16.0
		bass_delay.tap2_pan = 0.15
		bass_delay.feedback_active = true
		bass_delay.feedback_delay_ms = 375.0
		bass_delay.feedback_level_db = -14.0
		bass_delay.feedback_lowpass = 1200.0       # darker echoes — keeps low end clean
		AudioServer.add_bus_effect(bass_bus, bass_delay)

	var bus_idx := AudioServer.get_bus_index("Music")
	if bus_idx == -1:
		AudioServer.add_bus()
		bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_idx, "Music")
		AudioServer.set_bus_send(bus_idx, "Master")

	AudioServer.set_bus_volume_db(bus_idx, 4.0)

	# Clear existing effects (hot-reload safety)
	while AudioServer.get_bus_effect_count(bus_idx) > 0:
		AudioServer.remove_bus_effect(bus_idx, 0)

	# 0: REVERB — reduced wet so pads breathe without drowning
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.80
	reverb.damping = 0.35
	reverb.spread = 0.9
	reverb.wet = 0.25   # was 0.40 — less wash on pads/arp
	reverb.dry = 0.75
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
	_growl_amount    = lerp(_growl_amount,    _target_growl_amount,    ls)
	_ambient_factor  = lerp(_ambient_factor,  _target_ambient_factor,  ls)
	_pad_volume      = lerp(_pad_volume,      _target_pad_volume,      ls)

	# Bass portamento
	_bass_freq_actual = lerp(_bass_freq_actual, _bass_freq, 5.0 * delta)

	# Filter sweep LFO
	_filter_lfo_phase = fmod(_filter_lfo_phase + _filter_lfo_rate * delta, 1.0)

	# Slow arp stereo pan LFO — drives the L↔R sweep on arp1 and arp2.
	_arp_pan_lfo_phase = fmod(_arp_pan_lfo_phase + _ARP_PAN_LFO_HZ * delta, 1.0)

	# ── Chord progression clock ──────────────────────────────────────
	_chord_timer += delta
	_swell_phase = clampf(_chord_timer / _chord_duration, 0.0, 1.0)
	if _chord_timer >= _chord_duration:
		_chord_timer -= _chord_duration
		_advance_chord()

	# ── Master Step Clock (16th notes) with microtiming swing ──────
	# Drives Bass, Arp, Arp2, and Percussion from a single synchronized
	# counter. Subtle swing pushes odd-indexed (off-beat) 16th notes back
	# in time so consecutive 16ths take (1+swing)*base then (1-swing)*base
	# instead of two equal durations. Net duration per pair = 2*base, but
	# the off-beat lands ~10% later than grid — that's the difference
	# between robotic and groovy.
	const _SWING: float = 0.08
	_bass_step_timer += delta
	var step_dur_base: float = 60.0 / _arp_tempo / 4.0
	while true:
		# Determine the duration BEFORE the next step to fire. Next step
		# index = _master_step_counter (we increment after firing).
		var next_odd: bool = (_master_step_counter % 2) == 1
		var step_dur: float
		if next_odd:
			step_dur = step_dur_base * (1.0 + _SWING)   # off-beat: long gap
		else:
			step_dur = step_dur_base * (1.0 - _SWING)   # on-beat: short gap
		if _bass_step_timer < step_dur:
			break
		_bass_step_timer -= step_dur

		# 16th note triggers (Bass, Arp2, Perc).
		_retrigger_bass_pulse()
		_advance_arp2_step()
		_advance_perc_step()

		# 8th note triggers (Arp lead voice) — every 2nd 16th-note step.
		_master_step_counter += 1
		if _master_step_counter % 2 == 0:
			_advance_arp_step()

	# Decay envelopes — arp uses tempo-proportional rate so notes fill ~75% of each step
	_arp_envelope = maxf(_arp_envelope - delta * _arp_decay_rate, 0.0)
	_arp2_envelope = maxf(_arp2_envelope - delta * (_arp_decay_rate * 2.0), 0.0)
	_stinger_env  = maxf(_stinger_env  - delta * 4.0, 0.0)

	# Sidechain envelope decays exponentially; trigger happens in _advance_perc_step.
	# Use frame-time-proportional decay for stability across framerates.
	if _sidechain_env > 0.001:
		var sc_factor: float = pow(_sidechain_decay, delta * _sample_rate)
		_sidechain_env *= sc_factor

	# Beat intensity envelopes for animation subscribers. Linear decay so
	# the pulse is sharp and visible — exponential would feel mushy on
	# visual elements.
	beat_intensity = maxf(beat_intensity - delta * 4.0, 0.0)
	kick_intensity = maxf(kick_intensity - delta * 3.0, 0.0)

	# Fading LFO for Arp2
	_arp2_vol_lfo_phase = fmod(_arp2_vol_lfo_phase + delta * 0.03, 1.0)
	var arp2_lfo_val = sin(_arp2_vol_lfo_phase * TAU) * 0.5 + 0.5
	_arp2_target_vol = arp2_lfo_val * arp2_lfo_val * _arp_volume * 0.6  # Lower volume
	_arp2_vol = lerp(_arp2_vol, _arp2_target_vol, 2.0 * delta)

	# ── Ambient accent timer ─────────────────────────────────────────
	if _accent_type == 0:
		_accent_timer -= delta
		if _accent_timer <= 0.0:
			_fire_accent()
	else:
		match _accent_stage:
			0:   # attack
				_accent_env += _accent_atk_rate * delta
				if _accent_env >= 1.0:
					_accent_env = 1.0
					_accent_stage = 1
			1:   # sustain
				_accent_sustain_t -= delta
				if _accent_sustain_t <= 0.0:
					_accent_stage = 2
			2:   # release
				_accent_env -= _accent_rel_rate * delta
				if _accent_env <= 0.0:
					_accent_env = 0.0
					_accent_type = 0
					_accent_timer = randf_range(3.0, 9.0) # More frequent accents

	# ── Update bus effects ───────────────────────────────────────────
	_update_bus_effects()

	# ── Fill audio buffers (time-based to be frame-rate independent) ──
	# Calculate how much audio time has passed and needs to be generated
	var current_time := Time.get_ticks_msec() / 1000.0
	var time_since_last_fill := current_time - _last_audio_time

	# Cap catchup to prevent stutter on long freezes
	time_since_last_fill = minf(time_since_last_fill, _MAX_AUDIO_CATCHUP)

	if time_since_last_fill > 0.0:
		_last_audio_time = current_time
		var frames := int(time_since_last_fill * _sample_rate)
		_fill_bass_buffer(frames)
		_fill_arp_buffer(frames)
		_fill_arp2_buffer(frames)
		_fill_perc_buffer(frames)
		_fill_accent_buffer(frames)
		_fill_riser_buffer(frames)
		_fill_stab_buffer(frames)
		_fill_pad_buffer(frames)

# =====================================================================
#  CHORD PROGRESSION
# =====================================================================

func _advance_chord() -> void:
	var info := _harmony.advance_chord(current_state)

	_chord_index = (_chord_index + 1)
	_chord_root_ratio = float(info["chord_root_ratio"])
	_arp_note_pool = info["arp_note_pool"]
	_bass_freq = float(info["bass_freq_hz"])

	# Sync delay to beat
	_target_delay_time = 60000.0 / _arp_tempo

	_swell_phase = 0.0

	# Voice rotation + pattern + motif decisions at chord boundaries.
	if _melody:
		var scale: Array = info.get("current_scale", [])
		var is_sec_dom: bool = bool(info.get("is_secondary_dom", false))
		_melody.notify_chord_change(int(info["chord_index"]), int(info["progression_size"]), current_state, _arp_note_pool, scale, is_sec_dom)

	# Chord stab on every 4th chord (phrase downbeat) — punctuates structure.
	# Only fires when there's a meaningful chord pool.
	var chord_idx: int = int(info["chord_index"])
	if chord_idx % 4 == 0 and _arp_note_pool.size() >= 3:
		_trigger_chord_stab()

	# Update sustained chord pad targets — voices will glide to these via
	# portamento in the pad fill loop.
	_update_chord_pad_targets()

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
		if _harmony:
			_harmony.notify_state_change(current_state)

# =====================================================================
#  TARGET PARAMETER CALCULATION
# =====================================================================

func _update_music_targets() -> void:
	match current_state:
		MusicState.DEEP_SPACE:
			_target_bass_volume     = 0.13      # quieter — no need to dominate while idle
			_target_arp_volume      = 0.004     # drastically lower
			_target_perc_volume     = 0.02      # drastically lower
			_target_filter_cutoff   = 250.0     # extreme muffled
			_target_reverb_mix      = 0.95      # massive reverb
			_arp_tempo              = 35.0      # slower
			_chord_duration         = 8.0
			_bass_detune            = 1.003
			_target_delay_feedback  = 0.35
			_target_delay_mix       = 0.30
			_target_chorus_rate     = 0.3
			_target_chorus_depth    = 3.0
			_target_stereo_width    = 0.75
			_filter_lfo_rate        = 0.04
			_filter_lfo_depth       = 0.35
			_swell_depth            = 0.45
			_target_growl_amount    = 0.10      # mostly clean — keep ambient feel
			_target_ambient_factor  = 0.95      # near-pure ambient
			_arp_legato_factor      = 2.5       # heavy legato — notes wash together
			_target_pad_volume      = 0.040     # subtle pad — was overwhelming when idle
			_target_reverb_room     = 0.92
			_target_reverb_predelay_ms = 30.0

		MusicState.CRUISING:
			var spd_t := clampf(_ship_speed / 5000.0, 0.0, 1.0)
			_target_bass_volume     = 0.23
			_target_arp_volume      = 0.04
			_target_perc_volume     = lerpf(0.30, 0.42, spd_t)
			_target_filter_cutoff   = lerpf(1200.0, 3000.0, spd_t)
			_target_reverb_mix      = 0.62      # was 0.50 — more wet
			_arp_tempo              = lerpf(50.0, 75.0, spd_t)
			_chord_duration         = lerpf(6.0, 4.0, spd_t)
			_bass_detune            = 1.005
			_target_delay_feedback  = lerpf(0.34, 0.24, spd_t)
			_target_delay_mix       = lerpf(0.28, 0.22, spd_t)
			_target_chorus_rate     = lerpf(0.4, 0.6, spd_t)
			_target_chorus_depth    = lerpf(3.5, 2.5, spd_t)
			_target_stereo_width    = 0.75
			_filter_lfo_rate        = lerpf(0.06, 0.10, spd_t)
			_filter_lfo_depth       = 0.25
			_swell_depth            = 0.40
			_target_growl_amount    = lerpf(0.40, 0.65, spd_t)   # less aggressive — softer growl
			_target_ambient_factor  = 0.45                       # more ambient texture; pump still present
			_arp_legato_factor      = 1.5                        # arp notes overlap more
			_target_pad_volume      = 0.085                      # chord pad now an audible layer
			_target_reverb_room     = 0.84
			_target_reverb_predelay_ms = 18.0

		MusicState.ATMOSPHERE:
			_target_bass_volume     = 0.20
			_target_arp_volume      = 0.040
			_target_perc_volume     = 0.30      # soft offbeat hats — ethereal but audible
			_target_filter_cutoff   = 1500.0
			_target_reverb_mix      = 0.70
			_arp_tempo              = 70.0
			_chord_duration         = 5.0
			_bass_detune            = 1.008
			_target_delay_feedback  = 0.32
			_target_delay_mix       = 0.28
			_target_chorus_rate     = 0.35
			_target_chorus_depth    = 3.5
			_target_stereo_width    = 0.80
			_filter_lfo_rate        = 0.05
			_filter_lfo_depth       = 0.30
			_swell_depth            = 0.40
			_target_growl_amount    = 0.25      # subtle warmth, stays dreamy
			_target_ambient_factor  = 0.75      # mostly ambient
			_arp_legato_factor      = 2.0       # legato wash
			_target_pad_volume      = 0.055     # was 0.085 — pad scaled back too
			_target_reverb_room     = 0.85
			_target_reverb_predelay_ms = 22.0

		MusicState.SURFACE:
			_target_bass_volume     = 0.26
			_target_arp_volume      = 0.075
			_target_perc_volume     = 0.55      # was 0.65 — slightly less prominent
			_target_filter_cutoff   = 3000.0
			_target_reverb_mix      = 0.66      # was 0.55 — more wet
			_arp_tempo              = 90.0
			_chord_duration         = 4.0
			_bass_detune            = 1.004
			_target_delay_feedback  = 0.26
			_target_delay_mix       = 0.24
			_target_chorus_rate     = 0.45
			_target_chorus_depth    = 2.5
			_target_stereo_width    = 0.75
			_filter_lfo_rate        = 0.07
			_filter_lfo_depth       = 0.20
			_swell_depth            = 0.35
			_target_growl_amount    = 0.55      # was 0.75 — less heavy
			_target_ambient_factor  = 0.40      # rhythmic backbone with strong ambient layer
			_arp_legato_factor      = 1.4       # flowing arp instead of staccato
			_target_pad_volume      = 0.085
			_target_reverb_room     = 0.82
			_target_reverb_predelay_ms = 16.0

		MusicState.COMBAT:
			_target_bass_volume     = 0.30
			_target_arp_volume      = 0.075
			_target_perc_volume     = lerpf(0.55, 0.70, _combat_tension)
			_target_filter_cutoff   = lerpf(2200.0, 4500.0, _combat_tension)
			_target_reverb_mix      = 0.35
			_arp_tempo              = lerpf(85.0, 115.0, _combat_tension)
			_chord_duration         = lerpf(3.0, 2.0, _combat_tension)
			_bass_detune            = 1.01
			_target_delay_feedback  = lerpf(0.18, 0.12, _combat_tension)
			_target_delay_mix       = lerpf(0.15, 0.10, _combat_tension)
			_target_chorus_rate     = 0.6
			_target_chorus_depth    = 1.0
			_target_stereo_width    = 0.50
			_filter_lfo_rate        = lerpf(0.08, 0.14, _combat_tension)
			_filter_lfo_depth       = lerpf(0.15, 0.10, _combat_tension)
			_swell_depth            = 0.30
			_target_growl_amount    = lerpf(0.85, 1.00, _combat_tension)   # full snarl
			_target_ambient_factor  = 0.0       # pure rhythmic
			_arp_legato_factor      = 0.6       # tighter than default — more punchy
			_target_pad_volume      = 0.06
			_target_reverb_room     = 0.65
			_target_reverb_predelay_ms = 5.0

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
			# Room size + predelay swing toward "vast cavern" in ambient
			# states and "tight room" in combat. Smoothly tracks targets.
			fx.room_size = clampf(_target_reverb_room, 0.4, 0.98)
			fx.predelay_msec = clampf(_target_reverb_predelay_ms, 0.0, 100.0)

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

	# Sync the BassLine delay to current tempo so echoes land on the beat.
	var bass_bus_idx := AudioServer.get_bus_index("BassLine")
	if bass_bus_idx != -1:
		var bass_fx_count := AudioServer.get_bus_effect_count(bass_bus_idx)
		# Effect order on BassLine: 0 = overdrive, 1 = reverb, 2 = delay
		if bass_fx_count > 2:
			var bdelay := AudioServer.get_bus_effect(bass_bus_idx, 2)
			if bdelay is AudioEffectDelay:
				var dt: float = clampf(_delay_time_ms * 0.75, 100.0, 1500.0)
				bdelay.tap1_delay_ms = dt
				bdelay.tap2_delay_ms = dt * 0.5
				bdelay.feedback_delay_ms = dt

# =====================================================================
#  SINE / NOISE LOOKUP
# =====================================================================

func _sin_lut(phase: float) -> float:
	return _sin_table[int(phase * 256.0) & 255]

# =====================================================================
#  BASS PULSE RETRIGGER
# =====================================================================

func _retrigger_bass_pulse() -> void:
	_bass_step_count = (_bass_step_count + 1) % 16

	# Look up velocity from the rhythm bank's current bass groove.
	var vel: float = _rhythm.get_bass_groove_step(_bass_step_count) if _rhythm else 0.0
	if vel < 0.05:
		return   # rest step — leave envelope decaying, no retrigger

	# Per-step harmonic brightness: gives each note a unique timbre
	_bass_harm_level = randf_range(0.25, 1.0)

	_bass_pulse_env = vel
	# Decay fills 65% of the 16th-note step — short gap ensures rhythmic definition
	var step_dur := 60.0 / _arp_tempo / 4.0
	_bass_pulse_decay = pow(0.01, 1.0 / (step_dur * 0.65 * _sample_rate))

	# Filter envelope: opens to ~1.0 on attack, decays to a low cutoff over a
	# slightly longer window than the amplitude env. This is what produces the
	# classic "wub" / growl on each retrigger.
	_bass_filter_env = 1.0
	var fenv_dur: float = step_dur * 0.85
	_bass_filter_env_decay = pow(0.05, 1.0 / (fenv_dur * _sample_rate))

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

func _fill_bass_buffer(frames_hint: int = 0) -> void:
	if not _drone_playback:
		return
	# Use hint if provided (time-based), otherwise use available space
	var frames := frames_hint if frames_hint > 0 else _drone_playback.get_frames_available()
	frames = mini(frames, _drone_playback.get_frames_available())
	frames = mini(frames, _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	# Harmonic LFO: global timbral drift (~0.08 Hz, ~12s cycle)
	_harmonic_lfo_phase = fmod(_harmonic_lfo_phase + 0.08 * float(frames) / _sample_rate, 1.0)
	var harm_lfo := _sin_lut(_harmonic_lfo_phase) * 0.25 + 0.75  # 0.5..1.0
	# Floor at 0.45 so 2nd harmonic (130 Hz) is ALWAYS audible on all speakers
	var harm_mix := clampf(harm_lfo * _bass_harm_level, 0.45, 1.0)

	# Pad breathing LFO (continuous, slow)
	var pad_lfo := _sin_lut(_lfo_phase) * 0.25 + 0.75
	_lfo_phase = fmod(_lfo_phase + 0.12 * float(frames) / _sample_rate, 1.0)

	# Per-chord intensity swell. _swell_phase ramps 0→1 across each chord.
	# Quadratic curve makes the build accelerate, peaking right at the chord's
	# end before the next chord resets it — gives the bass a "growing toward
	# the downbeat" feel instead of pulsing identically every step.
	var swell_curve: float = _swell_phase * _swell_phase
	# Floor at (1 - depth) at chord start, peaks at 1.0 + 0.20*depth at end.
	var swell_env: float = (1.0 - _swell_depth) + _swell_depth * (1.20 * swell_curve)

	# Sidechain duck — kick attack pulls the bass down ~35% then recovers
	# over ~220ms. Creates the classic pumping motion that makes the kick
	# punch through and the bass groove feel alive.
	# Ambient gate: in atmospheric states the pump is anti-ambient, so it
	# attenuates toward zero as ambient_factor → 1.
	var rhythmic: float = 1.0 - _ambient_factor
	var sidechain_duck: float = 1.0 - _sidechain_env * 0.35 * rhythmic
	# Drop attenuation — silences the continuous pad/sub layers during drop
	# bars (the pulsing layer is already silent because the groove returns 0).
	var drop_attn: float = 0.12 if _rhythm and _rhythm.is_drop_active() else 1.0
	var vol   := _bass_volume * swell_env * sidechain_duck * drop_attn
	# PULSING BASS uses _bass_freq directly — snaps to chord root, no portamento.
	# PAD and SUB use _bass_freq_actual — glides smoothly (portamento) for warmth.
	# Pulse layer is one octave below the chord root (C1 instead of C2) for a
	# noticeably deeper, gut-rumbling sound. The pad keeps the C2 register so
	# we don't lose mid-bass body.
	const _BASS_PULSE_OCTAVE := 0.5
	var freq_pulse := _bass_freq * _BASS_PULSE_OCTAVE
	var freq_pad   := _bass_freq_actual * _bass_detune
	var freq_sub   := _bass_freq_actual * 0.5
	# Drone runs at the *key* root (not chord root) — the constant tonic
	# anchor. Locked to current_root_hz so it doesn't move with chord
	# changes. Volume gated by ambient_factor.
	var freq_drone: float = (_harmony.current_root_hz if _harmony else ROOT_HZ) * 0.5
	var drone_vol: float = _ambient_factor * 0.18 * _bass_volume
	var inv_r := 1.0 / _sample_rate

	var p1  := _bass_phase_1
	var p2  := _bass_phase_2
	var ps  := _bass_phase_sub
	var tbl := _sin_table
	var sw  := _stereo_width
	var bpe := _bass_pulse_env
	var bpd := _bass_pulse_decay

	# Slow growl LFO: bipolar -1..+1, advances once per buffer (cheap).
	_bass_growl_lfo_phase = fmod(
		_bass_growl_lfo_phase + _BASS_GROWL_LFO_HZ * float(frames) * inv_r, 1.0)
	var lfo_val := tbl[int(_bass_growl_lfo_phase * 256.0) & 255]   # -1..+1

	# Per-chord intensity boost: scales drive, filter depth, and cutoff up
	# in lockstep with the swell so the bass actually gets *brighter and meaner*
	# toward the end of the chord, not just louder.
	# At chord start: 0.55× of full intensity; at chord end: 1.10× of full.
	var swell_intensity: float = 0.55 + 0.55 * swell_curve

	# Growl-gated coefficients (computed once per buffer, applied per sample).
	# Combined modulators: state-based growl × per-chord swell × slow LFO drift.
	var growl: float = _growl_amount
	var saw_mix: float = growl * swell_intensity                          # saw content grows toward end
	var sine_mix: float = 1.0 - 0.4 * growl * swell_intensity             # less sine when fully wound up
	var drive: float = lerpf(1.4, 3.6, growl) * swell_intensity * (1.0 + lfo_val * 0.10)
	var filter_depth: float = growl * swell_intensity * (1.0 + lfo_val * 0.15)
	var max_cutoff: float = _BASS_FILTER_MAX_HZ * swell_intensity * (1.0 + lfo_val * 0.18)

	# Filter state (Chamberlin SVF — 2-pole LP with resonance).
	var z1: float = _bass_filter_z1
	var z2: float = _bass_filter_z2
	var fenv: float = _bass_filter_env
	var fdec: float = _bass_filter_env_decay
	var inv_sr := inv_r   # alias for readability in filter math

	for i in frames:
		# ── LAYER 1: PULSING BASS ──
		# Saw + sine blend on the fundamental — saw gives inherent harmonic richness,
		# sine keeps low-end weight at low growl values.
		var saw1 := p1 * 2.0 - 1.0
		var sin1 := tbl[int(p1 * 256.0) & 255]
		var fund := sin1 * sine_mix + saw1 * saw_mix
		# 2nd / 3rd harmonics via phase trick (added on top of saw's natural
		# harmonics). Levels boosted vs. before — at C1 the fundamental drops
		# below most laptop/phone speakers, so the audible weight comes from
		# harmonics 2 (64 Hz) and 3 (96 Hz).
		var harm2 := tbl[int(p1 * 512.0) & 255]
		var harm3 := tbl[int(p1 * 768.0) & 255]
		var bass_raw := fund + harm2 * (0.65 * harm_mix) + harm3 * (0.45 * harm_mix)
		var pulse_pre := bass_raw * bpe * 0.78   # +25% — lower frequencies need more amplitude

		# Per-pulse resonant LP filter — produces the "wub/growl" character.
		# Cutoff sweeps from MAX (open) toward MIN (closed) as fenv decays.
		# max_cutoff drifts slowly with the LFO so each pulse sits at a
		# slightly different "open" point.
		var cutoff: float = lerpf(_BASS_FILTER_MIN_HZ, max_cutoff, fenv)
		var fcoef: float = clampf(2.0 * PI * cutoff * inv_sr, 0.0, 0.95)
		var hp_out: float = pulse_pre - z1 - _BASS_FILTER_Q * z2
		var bp_out: float = z2 + fcoef * hp_out
		var lp_out: float = z1 + fcoef * bp_out
		z1 = lp_out
		z2 = bp_out
		# Blend filtered vs raw by growl amount so DEEP_SPACE keeps the open sound.
		var pulse_s: float = lerpf(pulse_pre, lp_out, filter_depth)

		# Saturation: 3rd-order soft clipper, more aggressive than the previous sine.
		# At low growl it's basically transparent; at high growl it adds odd harmonics.
		var clipped: float = clampf(pulse_s * drive, -1.0, 1.0)
		pulse_s = clipped * (1.5 - 0.5 * clipped * clipped)

		fenv *= fdec

		# ── LAYER 2: SUSTAINED PAD — detuned, continuous, portamento glide ──
		var pad := tbl[int(p2 * 256.0) & 255] * pad_lfo * 0.20

		# ── LAYER 3: SUB — half-freq sine, continuous, centered for weight ──
		var sub := tbl[int(ps * 256.0) & 255] * 0.24

		# ── LAYER 4: DRONE — sustained tonic, gated by ambient_factor ──
		# Plays at the key root regardless of chord; gives ambient states
		# their constant earth.
		var drone: float = tbl[int(_drone_phase * 256.0) & 255] * drone_vol

		# Mix: pulse + sub centered for punch; pad stereo-spread for spatial width.
		# Drone is centered (mono) — anchor doesn't need stereo motion.
		var center := (pulse_s + sub) * vol + drone

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
		_drone_phase = fmod(_drone_phase + freq_drone * inv_r, 1.0)
		bpe *= bpd
		_drone_playback.push_frame(Vector2(left, right))

	_bass_phase_1     = p1
	_bass_phase_2     = p2
	_bass_phase_sub   = ps
	_bass_pulse_env   = bpe
	_bass_filter_z1   = z1
	_bass_filter_z2   = z2
	_bass_filter_env  = fenv

# =====================================================================
#  ARPEGGIATOR
# =====================================================================

func _advance_arp_step() -> void:
	# Tempo-proportional decay: notes fill (legato_factor * step_dur) seconds.
	# 0.78 = staccato (default rhythmic feel); 2.5 = heavy legato wash for
	# ambient states where consecutive notes overlap into a flowing texture.
	var step_dur := 60.0 / _arp_tempo / 2.0
	_arp_decay_rate = 1.0 / (step_dur * _arp_legato_factor)

	if not _melody:
		_arp_rest = true
		_arp_envelope = 0.0
		return

	var step := _melody.next_step()
	if bool(step.get("is_rest", true)):
		_arp_rest = true
		_arp_envelope = 0.0
		return

	_arp_rest = false
	var ratio: float = float(step["ratio"])
	var octave: int = int(step["octave"])
	var root_hz: float = _harmony.current_root_hz if _harmony else ROOT_HZ
	_arp_current_freq = root_hz * ratio * pow(2.0, float(octave - 1))
	_arp_accent = float(step["accent"])
	_arp_envelope = 1.0
	_arp_pan = float(step["pan"])

func _fill_arp_buffer(frames_hint: int = 0) -> void:
	if not _arp_playback or not _voice_bank:
		return
	var frames := frames_hint if frames_hint > 0 else _arp_playback.get_frames_available()
	frames = mini(frames, _arp_playback.get_frames_available())
	frames = mini(frames, _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	if _arp_rest:
		for i in frames:
			_arp_playback.push_frame(Vector2.ZERO)
		return

	# Light sidechain duck on the arp — keeps it punchy with the kick without
	# burying the lead voice. Attenuated by ambient_factor so ambient states
	# don't pump the lead voice.
	var arp_duck: float = 1.0 - _sidechain_env * 0.18 * (1.0 - _ambient_factor)

	# Slow stereo pan: 17-second cycle sweeping ±0.55, plus a small per-step
	# alternation (±0.10) for movement on top of the slow drift. Total range
	# stays inside ±0.65 so the signal never disappears from one channel.
	var slow_pan: float = sin(_arp_pan_lfo_phase * TAU) * 0.55
	var arp1_pan: float = clampf(slow_pan + _arp_pan * 0.4, -0.7, 0.7)

	_arp_voice_ctx["freq"] = _arp_current_freq
	_arp_voice_ctx["env"]  = _arp_envelope
	_arp_voice_ctx["vol"]  = _arp_volume * _arp_accent * arp_duck
	_arp_voice_ctx["pan_l"] = clampf(1.0 - arp1_pan, 0.0, 1.6)
	_arp_voice_ctx["pan_r"] = clampf(1.0 + arp1_pan, 0.0, 1.6)
	_arp_voice_ctx["filt"]  = clampf(_filter_cutoff / 3000.0, 0.15, 1.0)

	var voice_id: int = VoiceBank.VOICE_PLUCK_SAW
	if _melody:
		voice_id = _melody.get_arp1_voice()
	_voice_bank.fill(voice_id, _arp_playback, _arp_voice_ctx, frames)
	_arp_phase = float(_arp_voice_ctx["phase"])

func _advance_arp2_step() -> void:
	if not _melody:
		return
	var step := _melody.next_arp2_step(_master_step_counter)
	# is_rest=true → leave envelope decaying; the counter voice is sparse so
	# most 16th-notes simply pass without a retrigger.
	if bool(step.get("is_rest", true)):
		return
	var ratio: float = float(step["ratio"])
	var octave: int = int(step["octave"])
	var root_hz: float = _harmony.current_root_hz if _harmony else ROOT_HZ
	_arp2_current_freq = root_hz * ratio * pow(2.0, float(octave - 1))
	_arp2_envelope = float(step.get("accent", 0.8))

func _fill_arp2_buffer(frames_hint: int = 0) -> void:
	if not _arp2_playback or not _voice_bank:
		return
	var frames := frames_hint if frames_hint > 0 else _arp2_playback.get_frames_available()
	frames = mini(frames, _arp2_playback.get_frames_available())
	frames = mini(frames, _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	var arp2_duck: float = 1.0 - _sidechain_env * 0.18 * (1.0 - _ambient_factor)

	# Counter-pan: arp2 sweeps in the OPPOSITE direction to arp1 so the two
	# voices are always on opposite sides of the stereo field. Wider sweep
	# than arp1 because arp2 is the more transparent voice.
	var arp2_pan: float = -sin(_arp_pan_lfo_phase * TAU) * 0.65

	_arp2_voice_ctx["freq"] = _arp2_current_freq
	_arp2_voice_ctx["env"]  = _arp2_envelope
	_arp2_voice_ctx["vol"]  = _arp2_vol * arp2_duck
	_arp2_voice_ctx["pan_l"] = clampf(1.0 - arp2_pan, 0.0, 1.7)
	_arp2_voice_ctx["pan_r"] = clampf(1.0 + arp2_pan, 0.0, 1.7)
	_arp2_voice_ctx["filt"]  = 1.0

	var voice_id: int = VoiceBank.VOICE_DETUNED_TRI
	if _melody:
		voice_id = _melody.get_arp2_voice()
	_voice_bank.fill(voice_id, _arp2_playback, _arp2_voice_ctx, frames)
	_arp2_phase = float(_arp2_voice_ctx["phase"])

# =====================================================================
#  PERCUSSION ENGINE
#  Kick: sine pitch sweep 150→40 Hz (70ms)
#  Snare: noise + 200Hz tone (100ms)
#  Hi-hat: noise burst (30ms, crisp)
# =====================================================================

func _advance_perc_step() -> void:
	_perc_step_index = (_perc_step_index + 1) % 16
	if _perc_step_index == 0:
		_perc_bar_count += 1
		if _rhythm:
			_rhythm.notify_bar_start(current_state, _perc_bar_count)
			# Trigger riser at the start of the riser bar (1 bar before drop).
			if _rhythm.is_riser_active():
				_trigger_riser()
		# Crash cymbal every 8 bars on the downbeat — punctuates section
		# boundaries beyond what the chord stab marks. Skipped on bar 0.
		# Doesn't fire in heavily-ambient states (gated by ambient_factor
		# at synthesis time).
		if _perc_bar_count > 0 and (_perc_bar_count % 8) == 0:
			_trigger_crash()

	var step: int = _rhythm.get_perc_step(_perc_step_index) if _rhythm else 0

	# Slight humanization: 10% chance to drop a non-kick hit
	if randf() < 0.10 and step > 1:
		step = step & 1   # keep kick, drop snare/hat

	# Per-step velocity — downbeats hit harder than off-beats. Then ±8%
	# random jitter per hit so the drums never sound identical bar to bar.
	var step_vel: float = float(RhythmBank.STEP_VEL[_perc_step_index]) * randf_range(0.92, 1.08)

	# Emit beat pulse for animation subscribers. Strength = step_vel so
	# downbeats pulse harder than off-beats.
	beat_intensity = maxf(beat_intensity, step_vel)
	beat_pulse.emit(step_vel, _perc_step_index)

	# Trigger drums based on bitfield, capturing velocity for the synth loop.
	# Bits: 1=kick, 2=snare, 4=closed hat, 8=open hat.
	if step & 1:   # kick
		_kick_env = 1.0
		_kick_phase = 0.0
		_kick_sub_phase = 0.0
		_kick_vel = step_vel
		# Sidechain trigger: kick attack ducks bass/arp volumes.
		_sidechain_env = 1.0
		# Beat-sync: kick pulse is the strongest visual sync event.
		kick_intensity = step_vel
		kick_hit.emit(step_vel)
	if step & 2:   # snare
		_snare_env = 1.0
		_snare_phase = 0.0
		_snare_vel = step_vel
	if step & 4:   # closed hat
		_hat_env = 1.0
		_hat_vel = step_vel
	if step & 8:   # open hat — kills any closed hat ringing on this step
		_open_hat_env = 1.0
		_open_hat_vel = step_vel
		_hat_env = 0.0   # mute closed hat so they don't fight
	# Tom — single voice, freq picked by which bit fires. Higher bits =
	# lower-pitched toms (think drum-kit numbering: hi/mid/lo).
	if step & 32:           # hi tom (180 Hz)
		_tom_env = 1.0
		_tom_phase = 0.0
		_tom_freq = 180.0
		_tom_pan = 0.30     # hi tom right
		_tom_vel = step_vel
	elif step & 64:         # mid tom (115 Hz)
		_tom_env = 1.0
		_tom_phase = 0.0
		_tom_freq = 115.0
		_tom_pan = 0.0      # mid tom center
		_tom_vel = step_vel
	elif step & 128:        # lo tom (75 Hz)
		_tom_env = 1.0
		_tom_phase = 0.0
		_tom_freq = 75.0
		_tom_pan = -0.30    # lo tom left
		_tom_vel = step_vel

func _fill_perc_buffer(frames_hint: int = 0) -> void:
	if not _perc_playback:
		return
	var frames := frames_hint if frames_hint > 0 else _perc_playback.get_frames_available()
	frames = mini(frames, _perc_playback.get_frames_available())
	frames = mini(frames, _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	var inv_r := 1.0 / _sample_rate
	var vol := _perc_volume
	var tbl := _sin_table
	var ntbl := _noise_table

	var ke := _kick_env
	var kp := _kick_phase
	var ksp := _kick_sub_phase
	var kd := _kick_decay
	var se := _snare_env
	var sp := _snare_phase
	var sd := _snare_decay
	var he := _hat_env
	var hd := _hat_decay
	var hp1 := _hat_p1
	var hp2 := _hat_p2
	var hp3 := _hat_p3
	var ohe := _open_hat_env
	var ohd := _open_hat_decay
	var ohp1 := _open_hat_p1
	var ohp2 := _open_hat_p2
	var ohp3 := _open_hat_p3
	var ce := _crash_env
	var cd := _crash_decay
	var cz1 := _crash_filter_z1
	var cz2 := _crash_filter_z2
	var te := _tom_env
	var tomp := _tom_phase
	var tomf := _tom_freq
	var tomd := _tom_decay
	var stail_idx := _snare_tail_idx
	var stail_n := _snare_tail_buf.size()
	var ni := _noise_idx

	# Captured velocities (multiplied into each layer's amplitude).
	var kvel := _kick_vel
	var svel := _snare_vel
	var hvel := _hat_vel
	var ohvel := _open_hat_vel
	var tvel := _tom_vel
	# Crash volume gated by ambient_factor — fades out in ambient states
	# where the long tail would smear.
	var crash_vol: float = 0.32 * (1.0 - _ambient_factor * 0.85)
	var crash_pan_l: float = clampf(1.0 - _crash_pan, 0.0, 1.6)
	var crash_pan_r: float = clampf(1.0 + _crash_pan, 0.0, 1.6)
	var tom_pan_l: float = clampf(1.0 - _tom_pan, 0.0, 1.5)
	var tom_pan_r: float = clampf(1.0 + _tom_pan, 0.0, 1.5)

	# Per-drum stereo placement. Wider than typical for a procedural drum
	# kit so the mix feels three-dimensional. Kick stays dead center for
	# punch + mono compatibility; everything else is pushed wider than the
	# standard ±0.2 to give the kit physical "kit width".
	const _KICK_PAN_L: float  = 1.00
	const _KICK_PAN_R: float  = 1.00
	const _SNARE_PAN_L: float = 1.30   # was 1.18 — wider left
	const _SNARE_PAN_R: float = 0.70
	const _HAT_PAN_L: float   = 0.65   # was 0.78 — wider right
	const _HAT_PAN_R: float   = 1.35
	# Open hat goes even wider — when it rings, it fills the side.
	const _OHAT_PAN_L: float  = 0.55
	const _OHAT_PAN_R: float  = 1.45

	# Early out if nothing is playing
	if (ke < 0.001 and se < 0.001 and he < 0.001 and ohe < 0.001
			and ce < 0.001 and te < 0.001 and vol < 0.001):
		for i in frames:
			_perc_playback.push_frame(Vector2.ZERO)
		_kick_env = ke
		_snare_env = se
		_hat_env = he
		_open_hat_env = ohe
		_crash_env = ce
		_tom_env = te
		return

	for i in frames:
		var kick_s: float = 0.0
		var snare_s: float = 0.0
		var hat_s: float = 0.0
		var ohat_s: float = 0.0

		# KICK: modern 3-layer — body sweep + sustained sub + filtered click.
		# Tuned for "big" — sub layer boosted to 0.78 (was 0.55), pitch sweep
		# starts deeper (38 Hz floor) for more thump, click intensified for
		# attack cut-through.
		if ke > 0.001:
			var ke_curve: float = ke * ke
			var kick_freq: float = 38.0 + 210.0 * ke_curve
			kp = fmod(kp + kick_freq * inv_r, 1.0)
			var kick_body: float = tbl[int(kp * 256.0) & 255] * ke
			# Sub layer: ~46 Hz, slower decay envelope (pow 0.35 = longer tail).
			ksp = fmod(ksp + 46.0 * inv_r, 1.0)
			var kick_sub: float = tbl[int(ksp * 256.0) & 255] * pow(ke, 0.35) * 0.78
			# Bigger click for attack snap.
			var click_amp: float = maxf(ke - 0.91, 0.0) * 19.0
			var click_n: float = (ntbl[ni & 1023] + ntbl[(ni + 1) & 1023]) * 0.5
			ni = (ni + 2) & 1023
			kick_s = (kick_body + kick_sub + click_n * click_amp) * KICK_VOL * kvel
			ke *= kd

		# SNARE: pitch-swept tonal layer + 1st-difference (high-passed) noise.
		if se > 0.001:
			var snap: float = pow(se, 0.5)
			var snare_freq: float = 180.0 + 80.0 * se
			sp = fmod(sp + snare_freq * inv_r, 1.0)
			var snare_tone: float = tbl[int(sp * 256.0) & 255] * 0.18
			var snare_tone2: float = tbl[int(sp * 512.0) & 255] * 0.10
			var n1: float = ntbl[ni & 1023]
			var n2: float = ntbl[(ni + 1) & 1023]
			var snare_noise: float = (n1 - n2) * 0.62
			ni = (ni + 2) & 1023
			snare_s = (snare_tone + snare_tone2 + snare_noise) * snap * SNARE_VOL * svel
			se *= sd

		# Snare tail — 80ms comb filter with feedback. Adds a "snare-in-a-
		# room" ambience without needing a separate reverb bus. Always runs
		# even when snare_env is decayed so trailing echoes ring out.
		if stail_n > 0:
			var tail_sample: float = _snare_tail_buf[stail_idx]
			_snare_tail_buf[stail_idx] = snare_s + tail_sample * 0.42
			stail_idx = (stail_idx + 1) % stail_n
			snare_s += tail_sample * 0.28

		# CLOSED HAT: 3 inharmonic squares + HP-filtered noise. Tight 18ms decay.
		if he > 0.001:
			hp1 = fmod(hp1 + 1234.0 * inv_r, 1.0)
			hp2 = fmod(hp2 + 1734.0 * inv_r, 1.0)
			hp3 = fmod(hp3 + 2150.0 * inv_r, 1.0)
			var sq1: float = -1.0 if hp1 < 0.5 else 1.0
			var sq2: float = -1.0 if hp2 < 0.5 else 1.0
			var sq3: float = -1.0 if hp3 < 0.5 else 1.0
			var n1: float = ntbl[ni & 1023]
			var n2: float = ntbl[(ni + 1) & 1023]
			var hp_noise: float = (n1 - n2) * 0.55
			ni = (ni + 2) & 1023
			var hat_mix: float = (sq1 + sq2 + sq3) * 0.18 + hp_noise * 0.55
			hat_s = hat_mix * he * HAT_VOL * hvel
			he *= hd

		# OPEN HAT: same architecture but slightly different freqs (sounds
		# distinct from closed) + much longer 130ms decay + extra noise air.
		# This is what gives EDM/house its groove on the off-beats.
		if ohe > 0.001:
			ohp1 = fmod(ohp1 + 980.0 * inv_r, 1.0)
			ohp2 = fmod(ohp2 + 1450.0 * inv_r, 1.0)
			ohp3 = fmod(ohp3 + 1980.0 * inv_r, 1.0)
			var osq1: float = -1.0 if ohp1 < 0.5 else 1.0
			var osq2: float = -1.0 if ohp2 < 0.5 else 1.0
			var osq3: float = -1.0 if ohp3 < 0.5 else 1.0
			var on1: float = ntbl[ni & 1023]
			var on2: float = ntbl[(ni + 1) & 1023]
			var ohp_noise: float = (on1 - on2) * 0.65
			ni = (ni + 2) & 1023
			var ohat_mix: float = (osq1 + osq2 + osq3) * 0.16 + ohp_noise * 0.62
			ohat_s = ohat_mix * ohe * HAT_VOL * 1.15 * ohvel
			ohe *= ohd

		# TOM: pitched body (slight upward sweep) + filtered click attack.
		# Single voice, freq comes from the trigger (75/115/180 Hz).
		var tom_s: float = 0.0
		if te > 0.001:
			# Tiny upward pitch sweep (10%) on attack — gives toms their "boing".
			tomp = fmod(tomp + tomf * (1.0 + (1.0 - te) * 0.10) * inv_r, 1.0)
			var tom_body: float = tbl[int(tomp * 256.0) & 255] * te
			var tclick_amp: float = maxf(te - 0.93, 0.0) * 8.0
			var tclick: float = ntbl[ni & 1023] * tclick_amp
			ni = (ni + 1) & 1023
			tom_s = (tom_body + tclick) * 0.42 * tvel
			te *= tomd

		# CRASH: bandpass-swept noise that rings out for ~1.8s. Filter cutoff
		# opens up over the first 100ms then holds while the envelope decays,
		# producing the classic "psshhhh..." cymbal wash.
		var crash_s: float = 0.0
		if ce > 0.001:
			# Sweep: cutoff lerps from 800 Hz to 6 kHz over the first 100ms
			# (when env > 0.97 of attack), then holds at 6 kHz.
			var sweep_t: float = clampf((1.0 - ce) * 6.0, 0.0, 1.0)
			var ccut: float = lerpf(800.0, 6000.0, sweep_t)
			var fcoef: float = clampf(2.0 * PI * ccut * inv_r, 0.0, 0.95)
			var cn: float = ntbl[ni & 1023]
			ni = (ni + 1) & 1023
			var chp: float = cn - cz1 - 0.6 * cz2
			var cbp: float = cz2 + fcoef * chp
			var clp: float = cz1 + fcoef * cbp
			cz1 = clp
			cz2 = cbp
			crash_s = cbp * ce * crash_vol
			ce *= cd

		# Per-drum panning, then mix to stereo.
		var left: float = (
			kick_s  * _KICK_PAN_L
			+ snare_s * _SNARE_PAN_L
			+ hat_s   * _HAT_PAN_L
			+ ohat_s  * _OHAT_PAN_L
			+ tom_s   * tom_pan_l
			+ crash_s * crash_pan_l
		)
		var right: float = (
			kick_s  * _KICK_PAN_R
			+ snare_s * _SNARE_PAN_R
			+ hat_s   * _HAT_PAN_R
			+ ohat_s  * _OHAT_PAN_R
			+ tom_s   * tom_pan_r
			+ crash_s * crash_pan_r
		)

		# Soft-clip per channel for analog saturation feel (compressor on
		# the bus does the heavy lifting, this just smooths overshoots).
		left  = clampf(left  * 1.4, -1.0, 1.0) * vol
		right = clampf(right * 1.4, -1.0, 1.0) * vol
		_perc_playback.push_frame(Vector2(left, right))

	_kick_env       = ke
	_kick_phase     = kp
	_kick_sub_phase = ksp
	_snare_env      = se
	_snare_phase    = sp
	_hat_env        = he
	_hat_p1         = hp1
	_hat_p2         = hp2
	_hat_p3         = hp3
	_open_hat_env   = ohe
	_open_hat_p1   = ohp1
	_open_hat_p2   = ohp2
	_open_hat_p3   = ohp3
	_crash_env      = ce
	_crash_filter_z1 = cz1
	_crash_filter_z2 = cz2
	_tom_env        = te
	_tom_phase      = tomp
	_snare_tail_idx = stail_idx
	_noise_idx      = ni

# =====================================================================
#  AMBIENT ACCENT ENGINE
# =====================================================================

func _fire_accent() -> void:
	# Pick accent type weighted by current music state
	var roll := randf()
	match current_state:
		MusicState.DEEP_SPACE:
			# Mostly drones and telemetry — vast, empty sci-fi feel
			_accent_type = 2 if roll < 0.40 else (4 if roll < 0.75 else 1)
		MusicState.CRUISING:
			# Mostly strings and telemetry — forward motion, tech sparkle
			_accent_type = 1 if roll < 0.45 else (4 if roll < 0.75 else 3)
		MusicState.ATMOSPHERE:
			# Even mix — dreamy and layered
			_accent_type = 1 if roll < 0.35 else (2 if roll < 0.70 else 3)
		MusicState.SURFACE:
			# Shimmers and strings — warm, alive
			_accent_type = 3 if roll < 0.45 else (1 if roll < 0.80 else 4)
		MusicState.COMBAT:
			# Shimmers and Telemetry
			_accent_type = 3 if roll < 0.60 else (4 if roll < 0.85 else 1)
		_:
			_accent_type = 1

	# Base frequency: two octaves above chord root (sits in the high register,
	# well clear of the bass and arp)
	var base := _bass_freq * 4.0

	match _accent_type:
		1:  # STRINGS: 3 detuned unison/octave voices, full sound
			_acc_freq1 = base
			_acc_freq2 = base * 1.0028   # +5 cents
			_acc_freq3 = base * 0.4986   # an octave down, detuned
			_acc_vol   = 0.022           # quieter — sits underneath the music
			_accent_atk_rate   = 1.0 / 0.8     # 800ms attack
			_accent_sustain_t  = randf_range(3.0, 5.0)
			_accent_rel_rate   = 1.0 / 1.5     # 1.5s release
		2:  # DRONE: single low root with slow vibrato
			_acc_freq1 = ROOT_HZ * _chord_root_ratio   # same octave as bass root
			_acc_freq2 = 0.0
			_acc_freq3 = 0.0
			_acc_vol   = 0.015
			_accent_atk_rate   = 1.0 / 0.90    # 900ms attack
			_accent_sustain_t  = randf_range(2.0, 5.0)
			_accent_rel_rate   = 1.0 / 1.20    # 1.2s release
		3:  # SHIMMER: two high bell partials
			_acc_freq1 = base * 2.0             # 4 octaves above bass
			_acc_freq2 = _acc_freq1 * 1.498     # perfect 5th above
			_acc_freq3 = 0.0
			_acc_vol   = 0.010
			_accent_atk_rate   = 1.0 / 0.04    # 40ms sharp attack
			_accent_sustain_t  = randf_range(0.0, 0.25)
			_accent_rel_rate   = 1.0 / 0.55    # 550ms bell decay
		4:  # TELEMETRY: sci-fi computer/scanner sounds — dialed way down
			_acc_freq1 = base * 1.5
			_acc_freq2 = 0.0
			_acc_freq3 = 0.0
			_acc_vol   = 0.012
			_accent_atk_rate   = 1.0 / 0.1     # 100ms attack
			_accent_sustain_t  = randf_range(1.0, 2.5)
			_accent_rel_rate   = 1.0 / 0.8     # 800ms decay

	_acc_pan   = randf_range(-0.45, 0.45)
	_accent_stage = 0
	_accent_env   = 0.0
	_acc_p1 = 0.0
	_acc_p2 = 0.0
	_acc_p3 = 0.0
	_acc_lfo_ph = 0.0

func _fill_accent_buffer(frames_hint: int = 0) -> void:
	if not _accent_playback:
		return
	var frames := frames_hint if frames_hint > 0 else _accent_playback.get_frames_available()
	frames = mini(frames, _accent_playback.get_frames_available())
	frames = mini(frames, _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	if _accent_type == 0 or _accent_env < 0.001:
		for i in frames:
			_accent_playback.push_frame(Vector2.ZERO)
		return

	var inv_r  := 1.0 / _sample_rate
	var tbl    := _sin_table
	var vol    := _acc_vol * _accent_env
	var pan_l  := clampf(1.0 - _acc_pan, 0.0, 1.5)
	var pan_r  := clampf(1.0 + _acc_pan, 0.0, 1.5)
	var p1 := _acc_p1
	var p2 := _acc_p2
	var p3 := _acc_p3
	var lpph := _acc_lfo_ph

	match _accent_type:
		1:  # STRINGS — 3 detuned voices, saw + sine for warmth
			var f1 := _acc_freq1;  var f2 := _acc_freq2;  var f3 := _acc_freq3
			for i in frames:
				var saw1 := p1 * 2.0 - 1.0
				var sin1 := tbl[int(p1 * 256.0) & 255]
				var sin2 := tbl[int(p2 * 256.0) & 255]
				var sin3 := tbl[int(p3 * 256.0) & 255]
				# Blend: centre voice is saw+sine for texture; side voices pure sine
				var s := ((saw1 * 0.35 + sin1 * 0.65) + sin2 + sin3) * 0.333 * vol
				_accent_playback.push_frame(Vector2(s * pan_l, s * pan_r))
				p1 = fmod(p1 + f1 * inv_r, 1.0)
				p2 = fmod(p2 + f2 * inv_r, 1.0)
				p3 = fmod(p3 + f3 * inv_r, 1.0)

		2:  # DRONE — single sine with gentle vibrato (0.25 Hz, ±1.5%)
			var f1 := _acc_freq1
			for i in frames:
				var vibrato := tbl[int(lpph * 256.0) & 255] * 0.015
				lpph = fmod(lpph + 0.25 * inv_r, 1.0)
				p1 = fmod(p1 + f1 * (1.0 + vibrato) * inv_r, 1.0)
				var s := tbl[int(p1 * 256.0) & 255] * vol
				_accent_playback.push_frame(Vector2(s * pan_l, s * pan_r))

		3:  # SHIMMER — two bell partials, fundamental + perfect 5th
			var f1 := _acc_freq1;  var f2 := _acc_freq2
			for i in frames:
				var sin1 := tbl[int(p1 * 256.0) & 255]
				var sin2 := tbl[int(p2 * 256.0) & 255] * 0.45  # quieter 5th partial
				var s := (sin1 + sin2) * vol
				_accent_playback.push_frame(Vector2(s * pan_l, s * pan_r))
				p1 = fmod(p1 + f1 * inv_r, 1.0)
				p2 = fmod(p2 + f2 * inv_r, 1.0)
				
		4:  # TELEMETRY — fast sci-fi scanner / FM sweep
			var f1 := _acc_freq1
			for i in frames:
				var fm = sin(lpph * TAU) * 2.0
				var freq = f1 * (1.0 + fm)
				lpph = fmod(lpph + 4.0 * inv_r, 1.0) # fast 4Hz modulation
				p1 = fmod(p1 + freq * inv_r, 1.0)
				var s := tbl[int(p1 * 256.0) & 255] * vol
				_accent_playback.push_frame(Vector2(s * pan_l, s * pan_r))

		_:
			for i in frames:
				_accent_playback.push_frame(Vector2.ZERO)

	_acc_p1 = p1
	_acc_p2 = p2
	_acc_p3 = p3
	_acc_lfo_ph = lpph

# =====================================================================
#  RISER ENGINE
#  Triggered at the start of the bar that precedes a drop. Synthesizes a
#  bandpass-swept noise burst rising in pitch + volume across one bar.
# =====================================================================

func _trigger_crash() -> void:
	_crash_env = 1.0
	_crash_filter_z1 = 0.0
	_crash_filter_z2 = 0.0
	# Random pan within ±0.4 so crashes don't always land in the same spot.
	_crash_pan = randf_range(-0.40, 0.40)

func _trigger_riser() -> void:
	_riser_active = true
	_riser_progress = 0.0
	# One bar of duration: 16 sixteenth-notes at current tempo.
	_riser_duration = (60.0 / _arp_tempo) * 4.0
	_riser_filter_z1 = 0.0
	_riser_filter_z2 = 0.0
	_riser_pitch_phase = 0.0
	# Pan direction randomized per trigger — sweep starts on one side and
	# crosses to the other over the bar.
	_riser_pan_dir = 1.0 if randf() < 0.5 else -1.0

func _fill_riser_buffer(frames_hint: int = 0) -> void:
	if not _riser_playback:
		return
	var frames := frames_hint if frames_hint > 0 else _riser_playback.get_frames_available()
	frames = mini(frames, _riser_playback.get_frames_available())
	frames = mini(frames, _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	if not _riser_active:
		for i in frames:
			_riser_playback.push_frame(Vector2.ZERO)
		return

	var inv_r := 1.0 / _sample_rate
	var ntbl := _noise_table
	var tbl := _sin_table
	var prog := _riser_progress
	var prog_step: float = inv_r / maxf(_riser_duration, 0.05)
	var z1 := _riser_filter_z1
	var z2 := _riser_filter_z2
	var ni := _riser_noise_idx
	var pp := _riser_pitch_phase

	for i in frames:
		# Quadratic volume ramp — stays low at start, climaxes at the end.
		var amp: float = prog * prog * 0.28
		# Cutoff sweeps 220 Hz → 7 kHz; bandpass-shaped noise gives the
		# classic "white-noise climbing" riser sound.
		var cutoff: float = lerpf(220.0, 7000.0, prog)
		var fcoef: float = clampf(2.0 * PI * cutoff * inv_r, 0.0, 0.95)
		var n: float = ntbl[ni & 1023]
		ni = (ni + 1) & 1023
		var hp: float = n - z1 - 0.7 * z2
		var bp: float = z2 + fcoef * hp
		var lp: float = z1 + fcoef * bp
		z1 = lp
		z2 = bp
		# Add a sine glissando overtone (climbs from 220 Hz to 1.4 kHz)
		# layered on top — gives the riser a tonal pitch component.
		var sine_freq: float = lerpf(220.0, 1400.0, prog * prog)
		pp = fmod(pp + sine_freq * inv_r, 1.0)
		var glide: float = tbl[int(pp * 256.0) & 255] * 0.10 * prog
		var s: float = (bp + glide) * amp
		# Pan sweeps from -0.55 * dir to +0.55 * dir across the riser bar
		# so the buildup feels like it's moving across the stereo field.
		var rpan: float = (prog * 2.0 - 1.0) * 0.55 * _riser_pan_dir
		var pl: float = clampf(1.0 - rpan, 0.0, 1.6)
		var pr: float = clampf(1.0 + rpan, 0.0, 1.6)
		_riser_playback.push_frame(Vector2(s * pl, s * pr))
		prog += prog_step
		if prog >= 1.0:
			prog = 1.0
			_riser_active = false

	_riser_progress = prog
	_riser_filter_z1 = z1
	_riser_filter_z2 = z2
	_riser_noise_idx = ni
	_riser_pitch_phase = pp

# =====================================================================
#  CHORD STAB ENGINE
#  Triggered on every 4th chord (phrase downbeat). Plays the active chord
#  pool simultaneously with a sharp pluck envelope.
# =====================================================================

func _trigger_chord_stab() -> void:
	if _arp_note_pool.is_empty():
		return
	var root_hz: float = _harmony.current_root_hz if _harmony else ROOT_HZ
	# Use up to 4 of the chord notes (root + 3rd + 5th + 7th when present),
	# pitched up to octave 3 so they sit above the bass.
	var count: int = mini(_arp_note_pool.size(), _stab_freqs.size())
	for i in count:
		_stab_freqs[i] = root_hz * float(_arp_note_pool[i]) * 2.0   # octave 3
		_stab_phases[i] = 0.0
	_stab_voice_count = count
	_stab_env = 1.0
	# Random pan per stab so consecutive stabs feel like they "land" in
	# different parts of the stereo field rather than a fixed center.
	_stab_pan = randf_range(-0.55, 0.55)

func _fill_stab_buffer(frames_hint: int = 0) -> void:
	if not _stab_playback:
		return
	var frames := frames_hint if frames_hint > 0 else _stab_playback.get_frames_available()
	frames = mini(frames, _stab_playback.get_frames_available())
	frames = mini(frames, _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	var env := _stab_env
	if env < 0.001 or _stab_voice_count <= 0:
		for i in frames:
			_stab_playback.push_frame(Vector2.ZERO)
		_stab_env = env
		return

	var inv_r := 1.0 / _sample_rate
	var dec := _stab_decay
	var tbl := _sin_table
	var n := _stab_voice_count
	var inv_n: float = 1.0 / float(n)
	# Stabs are rhythmic punctuation — fade them out in ambient states so
	# they don't break the wash.
	var stab_vol: float = 0.085 * (1.0 - _ambient_factor * 0.92)
	var pan_l: float = clampf(1.0 - _stab_pan, 0.0, 1.6)
	var pan_r: float = clampf(1.0 + _stab_pan, 0.0, 1.6)

	for i in frames:
		var sample: float = 0.0
		for v in n:
			var ph: float = _stab_phases[v]
			ph = fmod(ph + _stab_freqs[v] * inv_r, 1.0)
			_stab_phases[v] = ph
			# Saw + sine blend — pluck-like timbre with body.
			var saw: float = ph * 2.0 - 1.0
			var sine: float = tbl[int(ph * 256.0) & 255]
			sample += saw * 0.30 + sine * 0.70
		# pow(env, 0.7) shapes the envelope to have a sharper attack.
		var shaped: float = pow(env, 0.7)
		var s: float = sample * inv_n * shaped * stab_vol
		_stab_playback.push_frame(Vector2(s * pan_l, s * pan_r))
		env *= dec

	_stab_env = env

# =====================================================================
#  CHORD PAD ENGINE
#  Sustained polyphonic chord layer — the foundation of ambient texture.
#  Voices glide between chords via portamento; first chord ramps up via
#  slow attack envelope; volume gated by per-state _pad_volume.
# =====================================================================

func _update_chord_pad_targets() -> void:
	if _arp_note_pool.is_empty():
		return
	var root_hz: float = _harmony.current_root_hz if _harmony else ROOT_HZ
	# Use up to _PAD_VOICES_MAX of the chord-pool notes, pitched to octave 2
	# (mid-bass register, sits above the bass pulse and below the arp lead).
	var count: int = mini(_arp_note_pool.size(), _PAD_VOICES_MAX)
	for i in count:
		_pad_target_freqs[i] = root_hz * float(_arp_note_pool[i]) * 2.0
		# On first activation, snap current to target so we don't glide
		# from 0 Hz on initial play.
		if _pad_voice_count == 0 or _pad_freqs[i] <= 0.0:
			_pad_freqs[i] = _pad_target_freqs[i]
	# Zero-out unused voices so they fade silent.
	for i in range(count, _PAD_VOICES_MAX):
		_pad_target_freqs[i] = 0.0
	_pad_voice_count = count
	_pad_target_env = 1.0   # bring envelope to sustain when first chord arrives

func _fill_pad_buffer(frames_hint: int = 0) -> void:
	if not _pad_playback:
		return
	var frames := frames_hint if frames_hint > 0 else _pad_playback.get_frames_available()
	frames = mini(frames, _pad_playback.get_frames_available())
	frames = mini(frames, _MAX_FILL_FRAMES)
	if frames <= 0:
		return

	# Envelope tracks toward target (slow attack, never releases unless
	# state target volume drops to zero — the volume gate handles that).
	var dt: float = float(frames) / _sample_rate
	var env_step: float = _PAD_ATTACK_RATE * dt
	if _pad_env < _pad_target_env:
		_pad_env = minf(_pad_env + env_step, _pad_target_env)
	elif _pad_env > _pad_target_env:
		_pad_env = maxf(_pad_env - env_step, _pad_target_env)

	var vol: float = _pad_volume * _pad_env
	if vol < 0.0005 or _pad_voice_count <= 0:
		for i in frames:
			_pad_playback.push_frame(Vector2.ZERO)
		return

	var inv_r := 1.0 / _sample_rate
	var tbl := _sin_table
	var n := _pad_voice_count
	var inv_n: float = 1.0 / float(n)

	# Portamento: voices glide toward their target freqs over ~150ms.
	var glide: float = clampf(8.0 * dt, 0.0, 1.0)
	for i in n:
		_pad_freqs[i] = lerpf(_pad_freqs[i], _pad_target_freqs[i], glide)

	# Stereo spread: spread voices across the field so chord feels wide.
	for i in frames:
		var sample_l: float = 0.0
		var sample_r: float = 0.0
		for v in n:
			var f: float = _pad_freqs[v]
			if f <= 0.0:
				continue
			var ph: float = _pad_phases[v]
			ph = fmod(ph + f * inv_r, 1.0)
			_pad_phases[v] = ph
			# Triangle + sine blend — soft, slowly evolving timbre.
			var sine: float = tbl[int(ph * 256.0) & 255]
			var tri: float = 1.0 - abs(fmod(ph + 0.25, 1.0) * 4.0 - 2.0)
			var s: float = (sine * 0.55 + tri * 0.45)
			# Pan voices alternately L/R so the chord opens up stereo-wise.
			if v % 2 == 0:
				sample_l += s * 1.10
				sample_r += s * 0.90
			else:
				sample_l += s * 0.90
				sample_r += s * 1.10
		var amp: float = vol * inv_n
		_pad_playback.push_frame(Vector2(sample_l * amp, sample_r * amp))

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

func update_thruster_audio(speed: float, is_boosting: bool) -> void:
	if not _sfx_ship_thruster or not _sfx_ship_boost:
		return

	# Normalise speed: 0 = slow cruise (~100 u/s), 1 = full warp (~6000+ u/s)
	var t := clampf((speed - 60.0) / 5940.0, 0.0, 1.0)

	# THRUSTER: always plays when moving (independent of boost)
	_thruster_fadeout_time = 0.0
	_thruster_target_pitch = lerpf(0.8, 1.4, t)
	_thruster_target_volume = lerpf(-36.0, -20.0, t)

	if speed > 100.0:
		if not _sfx_ship_thruster.playing:
			_sfx_ship_thruster.play()
		_sfx_ship_thruster.pitch_scale = _thruster_target_pitch
		_sfx_ship_thruster.volume_db = _thruster_target_volume
	elif _sfx_ship_thruster.playing:
		# Fade out when moving slowly
		_thruster_fadeout_time += get_physics_process_delta_time()
		var fade_progress := clampf(_thruster_fadeout_time / THRUSTER_FADEOUT_DURATION, 0.0, 1.0)
		_sfx_ship_thruster.pitch_scale = lerpf(_thruster_target_pitch, 0.4, fade_progress)
		_sfx_ship_thruster.volume_db = lerpf(_thruster_target_volume, -80.0, fade_progress)
		if fade_progress >= 1.0:
			_sfx_ship_thruster.stop()

	# BOOST: layers on top of thrusters when active
	if is_boosting:
		_was_boosting = true
		_boost_fadeout_time = 0.0

		# Gradual boost increase: much slower acceleration of pitch/volume
		# Starts near silent at -56dB, increases to -32dB
		var boost_progress = pow(t, 1.5)  # slower curve for more gradual ramp
		_boost_target_pitch = lerpf(0.4, 1.8, boost_progress)
		_boost_target_volume = lerpf(-56.0, -32.0, boost_progress)

		if not _sfx_ship_boost.playing:
			_sfx_ship_boost.play()

		_sfx_ship_boost.pitch_scale = _boost_target_pitch
		_sfx_ship_boost.volume_db = _boost_target_volume
	else:
		# Reset boost state for next activation
		_was_boosting = false

		# Fade out boost when not boosting
		if _sfx_ship_boost.playing:
			_boost_fadeout_time += get_physics_process_delta_time()
			var fade_progress := clampf(_boost_fadeout_time / BOOST_FADEOUT_DURATION, 0.0, 1.0)
			_sfx_ship_boost.pitch_scale = lerpf(_boost_target_pitch, 0.3, fade_progress)
			_sfx_ship_boost.volume_db = lerpf(_boost_target_volume, -80.0, fade_progress)
			if fade_progress >= 1.0:
				_sfx_ship_boost.stop()

func play_explosion(is_big: bool = false) -> void:
	var sfx = _sfx_explosion_big if is_big else _sfx_explosion_small
	if sfx:
		sfx.stop()
		sfx.play()

func play_item_collect() -> void:
	if _sfx_item_collect:
		_sfx_item_collect.stop()
		_sfx_item_collect.play()
