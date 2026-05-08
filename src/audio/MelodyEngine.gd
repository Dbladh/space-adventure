class_name MelodyEngine
extends RefCounted

# MelodyEngine.gd
# Owns: arp pattern selection (9 patterns), motif sampling, phrase density curve,
# tension notes, wider note pool (chord tones + scale color), per-step accent +
# pan, and voice rotation at phrase boundaries.

# =====================================================================
#  PATTERN IDS
# =====================================================================

const PATTERN_UP            := 0
const PATTERN_DOWN          := 1
const PATTERN_UP_DOWN       := 2
const PATTERN_DOWN_UP       := 3
const PATTERN_BROKEN_THIRDS := 4
const PATTERN_SKIP_2        := 5
const PATTERN_RANDOM_WALK   := 6
const PATTERN_PEDAL_TONE    := 7
const PATTERN_MOTIF_REPEAT  := 8

const _PATTERN_COUNT := 9

# State-weighted pattern probabilities (each row sums to ~1.0).
var _PATTERN_WEIGHTS: Dictionary = {
	"DEEP_SPACE": [0.18, 0.18, 0.10, 0.10, 0.05, 0.05, 0.14, 0.13, 0.07],   # mostly directional, sparse
	"CRUISING":   [0.20, 0.10, 0.15, 0.10, 0.10, 0.08, 0.05, 0.05, 0.17],   # patterned + motifs
	"ATMOSPHERE": [0.13, 0.13, 0.10, 0.10, 0.05, 0.05, 0.20, 0.16, 0.08],   # random walk dreamy
	"SURFACE":    [0.12, 0.10, 0.18, 0.18, 0.08, 0.06, 0.04, 0.05, 0.19],   # bouncy + motif
	"COMBAT":     [0.18, 0.14, 0.10, 0.10, 0.10, 0.10, 0.06, 0.10, 0.12],   # punchy directional
}

# Rest probability per chord position within a 4-chord phrase.
# Sparse → dense → sparse — gives natural breathing.
const _PHRASE_DENSITY: Array = [0.30, 0.18, 0.10, 0.18]
const _PHRASE_LEN := 4

# Per-step accent envelope (mirrors the original ACCENT_PATTERN — kept here
# so MelodyEngine owns the rhythmic emphasis curve).
const _ACCENT_PATTERN: Array = [0.85, 0.50, 0.70, 0.45, 0.80, 0.55, 0.65, 0.50]

# =====================================================================
#  VOICE ROTATION POOLS (Phase B carry-over)
# =====================================================================

var _STATE_VOICE_POOL: Dictionary = {
	"DEEP_SPACE": [
		VoiceBank.VOICE_GLASS_PAD,
		VoiceBank.VOICE_SINE_FLUTE,
		VoiceBank.VOICE_BELL,
		VoiceBank.VOICE_CHIME,
		VoiceBank.VOICE_SOFT_PAD,
		VoiceBank.VOICE_DETUNED_TRI,
	],
	"CRUISING": [
		VoiceBank.VOICE_PLUCK_SAW,
		VoiceBank.VOICE_SUPERSAW,
		VoiceBank.VOICE_SQUARE_LEAD,
		VoiceBank.VOICE_MARIMBA,
		VoiceBank.VOICE_ORGAN,
		VoiceBank.VOICE_DETUNED_TRI,
	],
	"ATMOSPHERE": [
		VoiceBank.VOICE_BELL,
		VoiceBank.VOICE_GLASS_PAD,
		VoiceBank.VOICE_FM_BELL,
		VoiceBank.VOICE_SOFT_PAD,
		VoiceBank.VOICE_CHIME,
		VoiceBank.VOICE_SINE_FLUTE,
	],
	"SURFACE": [
		VoiceBank.VOICE_MARIMBA,
		VoiceBank.VOICE_PLUCK_SAW,
		VoiceBank.VOICE_ORGAN,
		VoiceBank.VOICE_SUPERSAW,
		VoiceBank.VOICE_BELL,
		VoiceBank.VOICE_DETUNED_TRI,
	],
	"COMBAT": [
		VoiceBank.VOICE_SQUARE_LEAD,
		VoiceBank.VOICE_SUPERSAW,
		VoiceBank.VOICE_FM_BELL,
		VoiceBank.VOICE_PLUCK_SAW,
		VoiceBank.VOICE_DETUNED_TRI,
		VoiceBank.VOICE_CHIME,
	],
}

var _ARP2_PAIR: Dictionary = {
	VoiceBank.VOICE_PLUCK_SAW:   VoiceBank.VOICE_GLASS_PAD,
	VoiceBank.VOICE_BELL:        VoiceBank.VOICE_SINE_FLUTE,
	VoiceBank.VOICE_FM_BELL:     VoiceBank.VOICE_SOFT_PAD,
	VoiceBank.VOICE_SUPERSAW:    VoiceBank.VOICE_SINE_FLUTE,
	VoiceBank.VOICE_SQUARE_LEAD: VoiceBank.VOICE_SOFT_PAD,
	VoiceBank.VOICE_SINE_FLUTE:  VoiceBank.VOICE_MARIMBA,
	VoiceBank.VOICE_MARIMBA:     VoiceBank.VOICE_GLASS_PAD,
	VoiceBank.VOICE_SOFT_PAD:    VoiceBank.VOICE_PLUCK_SAW,
	VoiceBank.VOICE_GLASS_PAD:   VoiceBank.VOICE_BELL,
	VoiceBank.VOICE_DETUNED_TRI: VoiceBank.VOICE_CHIME,
	VoiceBank.VOICE_CHIME:       VoiceBank.VOICE_ORGAN,
	VoiceBank.VOICE_ORGAN:       VoiceBank.VOICE_CHIME,
}

# =====================================================================
#  RUNTIME STATE
# =====================================================================

var _arp1_voice: int = VoiceBank.VOICE_PLUCK_SAW
var _arp2_voice: int = VoiceBank.VOICE_DETUNED_TRI

var _current_chord_pool: Array = [1.0]
var _current_scale: Array = [1.0]
var _current_pattern: int = PATTERN_UP

# Position within the current 4-chord phrase (0..3) — drives density curve
# and triggers voice/pattern rolls at boundaries.
var _chord_pos_in_phrase: int = 0

# Pattern stepping state (resets per chord).
var _step_idx: int = 0
var _step_counter: int = 0          # raw step count, monotonic across chords
var _last_ratio: float = 1.0

# Motif state.
var _motif_seq: Array = []
var _motif_pos: int = 0

# Section motif development — the seed motif is sampled as chord-pool
# INDICES (not absolute ratios). When MOTIF_REPEAT pattern fires, the
# system locks in for 4 chords and applies a different musical
# transformation each chord: identity → transposed → retrograde →
# inverted-retrograde. This is how composers develop a theme.
var _section_motif_indices: Array = []
var _motif_phrase_remaining: int = 0   # chords left in current motif phrase
var _motif_chord_pos: int = 0          # 0..3 within the motif phrase

# Arp2 counter-melody state — walks the chord pool in reverse so it
# answers Arp1 instead of doubling it.
var _arp2_idx: int = 0

# Counterpoint state — Arp2 reads what Arp1 just played to enforce
# contrary motion and avoid unison/octave doubling.
var _last_arp1_ratio: float = 1.0
var _last_arp1_motion: int = 0    # -1 down, 0 same, +1 up
var _last_arp2_ratio: float = 1.0

# Secondary-dominant flag — true when current chord is a borrowed V/x.
# During secondary doms, we restrict arp1 to chord tones only (skip scale
# substitution + tension notes) since the scale and the borrowed chord
# don't share enough common tones to mix freely.
var _is_secondary_dom: bool = false

# Tension-note resolution — when next_step plays a chromatic neighbor,
# this flag forces the *following* step to a chord tone so the dissonance
# resolves immediately instead of dangling.
var _resolve_next: bool = false

# =====================================================================
#  PUBLIC API
# =====================================================================

func notify_chord_change(chord_idx: int, _total_chords: int, state: int, chord_pool: Array, scale: Array, is_secondary_dom: bool = false) -> void:
	# Phrase boundary detection: progression-restart OR every _PHRASE_LEN chords.
	var new_phrase: bool = chord_idx == 0 or _chord_pos_in_phrase >= _PHRASE_LEN - 1
	if new_phrase:
		_chord_pos_in_phrase = 0
		_roll_voices(state)
	else:
		_chord_pos_in_phrase += 1

	# Motif state resets at progression start so each progression can
	# introduce a fresh theme.
	if chord_idx == 0:
		_motif_phrase_remaining = 0
		_section_motif_indices = []

	_current_chord_pool = chord_pool
	_current_scale = scale
	_step_idx = 0
	_arp2_idx = 0
	_is_secondary_dom = is_secondary_dom
	_resolve_next = false   # any pending tension auto-cancels at chord boundary

	if not chord_pool.is_empty():
		_last_ratio = float(chord_pool[0])

	# Pattern selection with motif locking. If a motif phrase is in flight,
	# keep MOTIF_REPEAT active; otherwise pick a fresh pattern (which may
	# itself trigger a new motif phrase).
	if _motif_phrase_remaining > 0:
		_current_pattern = PATTERN_MOTIF_REPEAT
		_motif_chord_pos += 1
		_motif_phrase_remaining -= 1
	else:
		_current_pattern = _pick_pattern(state)
		if _current_pattern == PATTERN_MOTIF_REPEAT:
			_section_motif_indices = _sample_motif_indices()
			_motif_chord_pos = 0
			_motif_phrase_remaining = _PHRASE_LEN - 1   # 3 more chords after this one

	if _current_pattern == PATTERN_MOTIF_REPEAT:
		_apply_motif_transformation()
		_motif_pos = 0

func get_arp1_voice() -> int:
	return _arp1_voice

func get_arp2_voice() -> int:
	return _arp2_voice

# Counter-melody for Arp2. Called once per 16th note. Returns is_rest=true
# when the counter voice should stay silent so it doesn't double Arp1's
# rapid stepping. The walker traverses the chord pool in reverse so when
# Arp1 climbs, Arp2 descends — call-and-response.
func next_arp2_step(master_step: int) -> Dictionary:
	if _current_chord_pool.is_empty():
		return {"is_rest": true}

	var step_in_bar: int = master_step % 16
	var fire: bool = false
	var accent: float = 0.7
	match step_in_bar:
		0:
			fire = true
			accent = 0.95            # phrase downbeat — strongest
		4:
			fire = true
			accent = 0.65            # beat 2
		8:
			fire = true
			accent = 0.85            # beat 3
		12:
			fire = true
			accent = 0.65            # beat 4
		14:
			fire = randf() < 0.30    # 'and of 4' fill — occasional
			accent = 0.55
		_:
			fire = false

	if not fire:
		return {"is_rest": true}

	var pool: Array = _current_chord_pool
	var n: int = pool.size()
	# Default: walk chord pool in reverse so when Arp1 climbs Arp2 descends.
	var idx: int = (n - 1 - (_arp2_idx % n))
	if idx < 0:
		idx += n
	_arp2_idx = (_arp2_idx + 1) % n

	# Counterpoint rule 1: avoid unison/octave doubling with Arp1's last note
	# (compared in normalized [1.0, 2.0) ratio space — same pitch class).
	if n > 1:
		var arp1_norm: float = _normalize_ratio(_last_arp1_ratio)
		var cand_norm: float = _normalize_ratio(float(pool[idx]))
		if abs(cand_norm - arp1_norm) / maxf(arp1_norm, 0.01) < 0.05:
			# Pick a different chord tone. Walk forward until we find one
			# that's not pitch-class-equivalent to Arp1's recent note.
			for offset in range(1, n):
				var alt: int = (idx + offset) % n
				var alt_norm: float = _normalize_ratio(float(pool[alt]))
				if abs(alt_norm - arp1_norm) / maxf(arp1_norm, 0.01) >= 0.05:
					idx = alt
					break

	# Counterpoint rule 2: contrary motion. If Arp1 just moved up, Arp2
	# should move down (relative to its own previous note), and vice versa.
	# Reinforces the "two voices in conversation" feel.
	if _last_arp1_motion != 0 and n >= 3 and _last_arp2_ratio > 0.0:
		var current: float = float(pool[idx])
		var same_direction: bool = (
			(current > _last_arp2_ratio and _last_arp1_motion > 0) or
			(current < _last_arp2_ratio and _last_arp1_motion < 0)
		)
		if same_direction:
			# Try alternates that move contrary to Arp1.
			for offset in range(1, n):
				var alt: int = (idx + offset) % n
				var alt_val: float = float(pool[alt])
				var contrary: bool = (
					(alt_val < _last_arp2_ratio and _last_arp1_motion > 0) or
					(alt_val > _last_arp2_ratio and _last_arp1_motion < 0)
				)
				if contrary:
					idx = alt
					break

	var ratio: float = float(pool[idx])
	_last_arp2_ratio = ratio

	return {
		"is_rest": false,
		"ratio": ratio,
		"octave": 4,                 # one octave above lead arp's typical
		"accent": accent,
	}

# Normalize a ratio into the [1.0, 2.0) range so two pitches can be
# compared by pitch class (octave-agnostic).
func _normalize_ratio(r: float) -> float:
	if r <= 0.0:
		return 1.0
	while r >= 2.0:
		r *= 0.5
	while r < 1.0:
		r *= 2.0
	return r

# Returns next melodic step. Mutates internal state — caller should call once
# per arp 8th-note tick.
func next_step() -> Dictionary:
	_step_counter += 1

	if _current_chord_pool.is_empty():
		return {"ratio": 1.0, "accent": 0.0, "is_rest": true, "octave": 3, "pan": 0.0}

	# Phrase-density rest probability.
	var density_idx: int = _chord_pos_in_phrase
	if density_idx >= _PHRASE_DENSITY.size():
		density_idx = 0
	var rest_p: float = float(_PHRASE_DENSITY[density_idx])

	var is_ghost: bool = false
	if randf() < rest_p:
		# 15% of skips become ghost notes (whisper-quiet); rest are full rests.
		if randf() < 0.15:
			is_ghost = true
		else:
			return {"ratio": _last_ratio, "accent": 0.0, "is_rest": true, "octave": 3, "pan": 0.0}

	# Step the current pattern.
	var ratio: float = _step_pattern()

	if _resolve_next:
		# Force resolution to a chord tone — pick the closest pool ratio to
		# the just-played tension note (resolves down by step in most cases).
		_resolve_next = false
		var pool: Array = _current_chord_pool
		if not pool.is_empty():
			var best: float = float(pool[0])
			var best_d: float = abs(_last_ratio - best)
			for i in range(1, pool.size()):
				var d: float = abs(_last_ratio - float(pool[i]))
				if d < best_d:
					best = float(pool[i])
					best_d = d
			ratio = best
	elif _is_secondary_dom:
		# Secondary dominants borrow notes outside the mode. Stick to chord
		# tones only — skipping scale substitution and tension notes prevents
		# the dom7 from clashing with diatonic neighbors.
		pass
	else:
		# Wider note pool: 12% chance to substitute with a non-chord scale tone.
		# (Lower than before — too frequent substitution sounded unmoored.)
		if randf() < 0.12 and _current_scale.size() > 0:
			ratio = float(_current_scale[randi() % _current_scale.size()])

		# Tension note: 4% chance of a chromatic upper neighbor — flagged to
		# resolve to a chord tone on the very next step.
		if randf() < 0.04:
			ratio *= 1.0595   # +1 semitone
			_resolve_next = true

	# Track motion direction for Arp2 counterpoint. Compare new ratio to the
	# previous one in normalized space (octave-agnostic).
	var prev_norm: float = _normalize_ratio(_last_arp1_ratio)
	var cur_norm: float = _normalize_ratio(ratio)
	if cur_norm > prev_norm * 1.04:
		_last_arp1_motion = 1
	elif cur_norm < prev_norm * 0.96:
		_last_arp1_motion = -1
	else:
		_last_arp1_motion = 0
	_last_arp1_ratio = ratio
	_last_ratio = ratio

	# Octave selection (matches original arp distribution).
	var octave: int = 3
	var oct_roll: float = randf()
	if oct_roll > 0.92:
		octave = 2
	elif oct_roll > 0.80:
		octave = 4

	# Per-step accent.
	var accent: float = float(_ACCENT_PATTERN[_step_counter % _ACCENT_PATTERN.size()])
	if is_ghost:
		accent *= 0.20

	# Stereo pan alternates per step.
	var pan: float = 0.25 if _step_counter % 2 == 0 else -0.25

	return {
		"ratio": ratio,
		"accent": accent,
		"is_rest": false,
		"octave": octave,
		"pan": pan,
	}

# =====================================================================
#  INTERNALS
# =====================================================================

func _step_pattern() -> float:
	var pool: Array = _current_chord_pool
	var n: int = pool.size()
	if n == 0:
		return 1.0

	match _current_pattern:
		PATTERN_UP:
			var r: float = float(pool[_step_idx % n])
			_step_idx = (_step_idx + 1) % n
			return r
		PATTERN_DOWN:
			var idx: int = _step_idx % n
			var r: float = float(pool[(n - 1 - idx) % n])
			_step_idx = (_step_idx + 1) % n
			return r
		PATTERN_UP_DOWN:
			var period: int = max(2 * n - 2, 1)
			var pos: int = _step_idx % period
			var actual: int = pos if pos < n else (period - pos)
			actual = clamp(actual, 0, n - 1)
			_step_idx = (_step_idx + 1) % period
			return float(pool[actual])
		PATTERN_DOWN_UP:
			var period: int = max(2 * n - 2, 1)
			var pos: int = _step_idx % period
			var actual: int = pos if pos < n else (period - pos)
			actual = clamp(actual, 0, n - 1)
			_step_idx = (_step_idx + 1) % period
			return float(pool[(n - 1 - actual) % n])
		PATTERN_BROKEN_THIRDS:
			var seq: Array = [0, 2, 1, 3]
			var seq_pos: int = _step_idx % seq.size()
			var idx: int = int(seq[seq_pos]) % n
			_step_idx = (_step_idx + 1) % seq.size()
			return float(pool[idx])
		PATTERN_SKIP_2:
			var idx: int = (_step_idx * 2) % n
			_step_idx = (_step_idx + 1) % n
			return float(pool[idx])
		PATTERN_RANDOM_WALK:
			var d: int = -1 if randf() < 0.5 else 1
			_step_idx = ((_step_idx + d) % n + n) % n
			return float(pool[_step_idx])
		PATTERN_PEDAL_TONE:
			# Alternate root with other notes — gives a "drone + melody" feel.
			if _step_idx % 2 == 0:
				_step_idx += 1
				return float(pool[0])
			var alt_idx: int = ((_step_idx >> 1) + 1) % n
			_step_idx += 1
			return float(pool[alt_idx])
		PATTERN_MOTIF_REPEAT:
			# Motif sequence is built by _apply_motif_transformation() at chord
			# boundaries. If somehow empty (race on first chord), fall back
			# to the chord root rather than re-sampling here.
			if _motif_seq.is_empty():
				return float(pool[0])
			var r: float = float(_motif_seq[_motif_pos % _motif_seq.size()])
			_motif_pos = (_motif_pos + 1) % _motif_seq.size()
			return r
	return float(pool[0])

func _pick_pattern(state: int) -> int:
	var sname: String = _state_name(state)
	var weights: Array = _PATTERN_WEIGHTS.get(sname, _PATTERN_WEIGHTS["DEEP_SPACE"])
	var roll: float = randf()
	var acc: float = 0.0
	for i in weights.size():
		acc += float(weights[i])
		if roll <= acc:
			return i
	return PATTERN_UP

# Sample the seed motif as chord-pool *indices* (not ratios). Indices let
# the same shape transpose across chord changes automatically.
func _sample_motif_indices() -> Array:
	var n: int = _current_chord_pool.size()
	if n == 0:
		return [0]
	var motif_len: int = 3 if randf() < 0.5 else 4
	var seed: Array = []
	for i in motif_len:
		seed.append(randi() % n)
	return seed

# Build _motif_seq for the current chord by applying the appropriate
# transformation to the seed indices, then mapping them through the
# current chord's pool. Each chord in the motif phrase gets a different
# transformation:
#   chord 0: identity     (theme introduction)
#   chord 1: identity     (transposed automatically via new chord pool)
#   chord 2: retrograde   (theme played backwards)
#   chord 3: inv-retro    (mirrored + reversed — most "developed" form)
func _apply_motif_transformation() -> void:
	_motif_seq = []
	_motif_pos = 0
	if _section_motif_indices.is_empty():
		return
	var n: int = _current_chord_pool.size()
	if n == 0:
		return
	var transformed: Array = _section_motif_indices.duplicate()
	match _motif_chord_pos:
		2:
			transformed.reverse()
		3:
			# Mirror around the center of the chord pool, then reverse.
			var center: float = float(n - 1) * 0.5
			for i in transformed.size():
				var idx: int = int(transformed[i])
				transformed[i] = clampi(int(round(2.0 * center - idx)), 0, n - 1)
			transformed.reverse()
	for idx in transformed:
		_motif_seq.append(float(_current_chord_pool[int(idx) % n]))

func _roll_voices(state: int) -> void:
	var sname: String = _state_name(state)
	var pool: Array = _STATE_VOICE_POOL.get(sname, _STATE_VOICE_POOL["DEEP_SPACE"])
	var pick: int = int(pool[randi() % pool.size()])
	if pool.size() > 1 and pick == _arp1_voice:
		var idx: int = pool.find(pick)
		pick = int(pool[(idx + 1) % pool.size()])
	_arp1_voice = pick
	_arp2_voice = int(_ARP2_PAIR.get(pick, VoiceBank.VOICE_DETUNED_TRI))

func _state_name(state: int) -> String:
	match state:
		0: return "DEEP_SPACE"
		1: return "CRUISING"
		2: return "ATMOSPHERE"
		3: return "SURFACE"
		4: return "COMBAT"
	return "DEEP_SPACE"
