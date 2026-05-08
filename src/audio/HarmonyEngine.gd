class_name HarmonyEngine
extends RefCounted

# HarmonyEngine.gd
# Owns key, scale, mode, progression, and chord voicing decisions.
# MusicDirector consumes the output via advance_chord().

# =====================================================================
#  ROOT
#  C2 base. current_root_hz is mutable so Phase E modulation can
#  shift the working key without touching the rest of the system.
# =====================================================================

const BASE_ROOT_HZ := 65.41
var current_root_hz: float = BASE_ROOT_HZ

# =====================================================================
#  MODES (12-TET ratios from root)
#  All modes share root, so swapping between them inside a state
#  shifts color but never breaks the bass/arp consonance.
# =====================================================================

var _MODES: Dictionary = {
	"major":          [1.0, 1.1225, 1.2599, 1.3348, 1.4983, 1.6818, 1.8877],
	"aeolian":        [1.0, 1.1225, 1.1892, 1.3348, 1.4983, 1.5874, 1.7818],
	"lydian":         [1.0, 1.1225, 1.2599, 1.4142, 1.4983, 1.6818, 1.8877],
	"mixolydian":     [1.0, 1.1225, 1.2599, 1.3348, 1.4983, 1.6818, 1.7818],
	"dorian":         [1.0, 1.1225, 1.1892, 1.3348, 1.4983, 1.6818, 1.7818],
	"phrygian":       [1.0, 1.0595, 1.1892, 1.3348, 1.4983, 1.5874, 1.7818],
	"phrygian_dom":   [1.0, 1.0595, 1.2599, 1.3348, 1.4983, 1.5874, 1.7818],
	"harmonic_minor": [1.0, 1.1225, 1.1892, 1.3348, 1.4983, 1.5874, 1.8877],
	"major_pent":     [1.0, 1.1225, 1.2599, 1.4983, 1.6818],
}

# =====================================================================
#  MODE BANK PER STATE
#  A state rotates through these modes — picked at progression start.
# =====================================================================

var _MODE_BANK: Dictionary = {
	"DEEP_SPACE": ["lydian", "major_pent", "mixolydian", "aeolian"],
	"CRUISING":   ["mixolydian", "major", "lydian"],
	"ATMOSPHERE": ["lydian", "phrygian", "aeolian"],
	"SURFACE":    ["major", "mixolydian", "dorian"],
	"COMBAT":     ["dorian", "phrygian_dom", "aeolian", "harmonic_minor"],
}

# =====================================================================
#  PROGRESSION LIBRARY PER STATE
#  Each progression is 16 chords = 4 functional 4-chord phrases concatenated.
#  Every 4-chord phrase ends on degree 0 (tonic) — the ear hears each phrase
#  as a complete musical sentence rather than a wandering arpeggio.
#  Most phrases follow T-S-D-T (I-IV-V-I or vi-IV-V-I), with occasional
#  plagal (IV-I) and jazz (ii-V-I) endings for color.
#  DEEP_SPACE uses indices 0-4 only so progressions stay valid under the
#  major-pentatonic mode (5-note scale).
# =====================================================================

var _PROG_BANK: Dictionary = {
	# Indices 0-4 only — pentatonic-safe.
	# In pentatonic: 0=I, 2=iii, 3=V (the perfect 5th in absolute pitch), 4=vi.
	# In 7-note modes: 0=I, 2=iii, 3=IV, 4=V, etc.
	"DEEP_SPACE": [
		[0,3,4,0, 0,2,4,0, 4,3,4,0, 0,4,3,0],   # cadence exploration
		[0,4,3,0, 0,3,4,0, 0,2,3,0, 4,3,4,0],   # plagal/authentic mix
		[0,2,4,0, 0,3,2,0, 0,4,2,0, 4,3,4,0],   # mediant-led
		[0,3,4,0, 0,4,3,0, 0,2,4,0, 0,3,4,0],   # repetitive meditation
	],
	# 7-note modes — full functional palette (incl. vi=5, ii=1).
	"CRUISING": [
		[0,3,4,0, 0,4,3,0, 5,3,4,0, 0,3,4,0],   # I-IV-V-I bookended
		[0,5,3,0, 5,3,4,0, 0,4,3,0, 0,3,4,0],   # vi-led + four chords
		[0,4,3,0, 0,5,3,0, 5,1,4,0, 0,3,4,0],   # plagal + jazz ii-V-I
		[0,3,4,0, 0,1,4,0, 5,3,4,0, 0,5,4,0],   # ii-V-I jazz integration
		[5,3,4,0, 0,3,4,0, 0,5,3,0, 5,1,4,0],   # vi-driven, lands on ii-V-I
	],
	"ATMOSPHERE": [
		[0,5,3,0, 0,2,3,0, 5,3,4,0, 0,5,3,0],   # vi/iii color, plagal
		[0,1,3,0, 0,5,3,0, 5,1,4,0, 0,3,4,0],   # ii flavor + jazz cadence
		[5,3,4,0, 0,5,3,0, 5,1,4,0, 0,5,3,0],   # vi-grounded
		[0,2,5,0, 0,5,3,0, 5,3,4,0, 0,5,3,0],   # mediant + vi return
	],
	"SURFACE": [
		[0,3,4,0, 0,3,4,0, 5,3,4,0, 0,3,4,0],   # solid I-IV-V repeated
		[0,4,5,0, 0,3,4,0, 5,1,4,0, 0,3,4,0],   # I-V-vi-I "four chords"
		[0,5,3,0, 0,3,4,0, 5,3,4,0, 0,3,4,0],   # vi-led + standard
		[0,3,4,0, 0,5,3,0, 0,4,3,0, 0,3,4,0],   # cadence variety
	],
	# Combat states use minor/Dorian/Phrygian-Dom/Harmonic-Minor — same
	# scale degrees, but the auditory result is darker / heroic.
	"COMBAT": [
		[0,3,4,0, 0,5,4,0, 5,3,4,0, 0,3,4,0],   # i-iv-V-i heroic
		[0,5,4,0, 0,3,4,0, 5,1,4,0, 0,3,4,0],   # i-VI-V-i
		[5,3,4,0, 0,5,4,0, 0,4,3,0, 0,3,4,0],   # urgent vi-led
		[0,1,4,0, 0,5,4,0, 5,3,4,0, 0,3,4,0],   # ii°-V-i mix
	],
}

# =====================================================================
#  RUNTIME STATE
# =====================================================================

var _current_progression: Array = []
var _current_progression_id: int = 0
var _current_scale: Array = []
var _current_mode_id: int = 0
var _current_chord_index: int = -1

# Voice leading — store the core 3 voices (root/3rd/5th ratios) from the
# previous chord so the next chord can permute + octave-shift its notes
# to minimize total melodic motion. Reset whenever mode or root changes
# since ratios are key-relative.
var _previous_voices: Array = []

# Hardcoded permutations of 3 voices — used by voice leading.
const _PERMS_3: Array = [
	[0, 1, 2], [0, 2, 1], [1, 0, 2],
	[1, 2, 0], [2, 0, 1], [2, 1, 0],
]

# Modulation state — root drifts by friendly intervals at progression boundaries.
# Cohesion guard: drift is bounded to ±1 octave from BASE_ROOT_HZ; if it goes
# further, the next modulation halves/doubles to bring it back into range.
const _MOD_INTERVALS: Array = [
	1.4983,   # perfect 5th up
	1.3348,   # perfect 4th up
	0.6674,   # perfect 4th down (= P5 down)
	1.1892,   # minor 3rd up
	1.2599,   # major 3rd up
]
const _MOD_PROBABILITY: float = 0.30
const _MOD_MIN_RATIO: float = 0.5
const _MOD_MAX_RATIO: float = 2.0

# Secondary dominant: 5% chance per (non-first) chord. Substitutes the
# regular chord with the V/x chord of the originally-scheduled root.
const _SECONDARY_DOM_CHANCE: float = 0.05

# Outputs (read by MusicDirector after advance_chord)
var chord_root_ratio: float = 1.0
var arp_note_pool: Array = [1.0]
var bass_freq_hz: float = BASE_ROOT_HZ
var current_mode_name: String = ""
var current_progression_size: int = 16

# =====================================================================
#  PUBLIC API
# =====================================================================

func notify_state_change(_state: int) -> void:
	# Force fresh progression+mode pick on the next advance_chord.
	_current_chord_index = -1
	_previous_voices = []   # voice leading restarts at state boundary

func advance_chord(state: int) -> Dictionary:
	var sname := _state_name(state)

	# Pick fresh progression + mode at progression boundaries (or first call).
	# Modulation may also kick in here.
	if _current_chord_index < 0 or _current_chord_index + 1 >= _current_progression.size():
		_pick_progression(sname)
		_pick_mode(sname)
		_maybe_modulate()
		_current_chord_index = 0
	else:
		_current_chord_index += 1

	current_progression_size = _current_progression.size()

	var s_len: int = _current_scale.size()
	var root_idx: int = int(_current_progression[_current_chord_index]) % s_len

	# Cadence enforcement: every 4th chord (last of each 4-chord phrase)
	# resolves to the tonic regardless of what the progression specifies.
	# This is the single biggest "music theory, not random" rule — listeners
	# hear each phrase as a complete musical sentence ending on home.
	var is_cadence: bool = (_current_chord_index % 4) == 3
	if is_cadence:
		root_idx = 0

	# Secondary dominant: substitute V/x for the scheduled chord.
	# Skipped on the first chord of a progression so phrases start on tonic,
	# AND skipped on cadence chords so the resolution isn't disrupted.
	var secondary_dom: bool = (_current_chord_index > 0
		and not is_cadence
		and randf() < _SECONDARY_DOM_CHANCE)

	if secondary_dom:
		# V of scheduled chord = scheduled_root * perfect 5th (1.4983).
		var scheduled := float(_current_scale[root_idx])
		chord_root_ratio = scheduled * 1.4983
	else:
		chord_root_ratio = _current_scale[root_idx]
	bass_freq_hz = current_root_hz * chord_root_ratio

	# Base chord pool. Secondary dominants are built directly from the chord
	# root (not from scale degrees) since they're borrowed from outside the mode.
	var pool: Array
	if secondary_dom:
		# Dominant 7th: root, major 3rd, perfect 5th, minor 7th.
		pool = [
			chord_root_ratio,
			chord_root_ratio * 1.2599,
			chord_root_ratio * 1.4983,
			chord_root_ratio * 1.7818,
		]
	else:
		var idx_3rd := (root_idx + 2) % s_len
		var idx_5th := (root_idx + 4) % s_len
		pool = [
			_current_scale[root_idx],
			_current_scale[idx_3rd],
			_current_scale[idx_5th],
		]
		# Voice leading: permute + octave-shift the core 3 notes so each
		# voice moves the smallest distance from the previous chord. This is
		# the difference between "random chords in a key" and "music that
		# breathes." Skipped on the first chord (no previous voices yet) and
		# during secondary dominants (their voicing is intentionally outside
		# the diatonic scale).
		if _previous_voices.size() >= 3:
			var led := _voice_lead([pool[0], pool[1], pool[2]], _previous_voices)
			pool[0] = led[0]
			pool[1] = led[1]
			pool[2] = led[2]

	# Voicing pipeline only runs for diatonic chords. Secondary dominants are
	# already a fully-spelled dom7 — running scale-degree-based extensions on
	# them would mix two harmonic worlds and clash.
	if not secondary_dom:
		var w := _voicing_weights(sname)

		# 7th
		if randf() < float(w["seventh"]):
			var idx_7th := (root_idx + 6) % s_len
			pool.append(_current_scale[idx_7th])

		# 9th (one octave above the 2nd degree)
		if randf() < float(w["ninth"]):
			var idx_9th := (root_idx + 1) % s_len
			pool.append(_current_scale[idx_9th] * 2.0)

		# sus2 / sus4 — replace 3rd with 2nd or 4th degree
		var sus_roll := randf()
		var sus2_p := float(w["sus2"])
		var sus4_p := float(w["sus4"])
		if sus_roll < sus2_p:
			var idx_2nd := (root_idx + 1) % s_len
			pool[1] = _current_scale[idx_2nd]
		elif sus_roll < sus2_p + sus4_p:
			var idx_4th := (root_idx + 3) % s_len
			pool[1] = _current_scale[idx_4th]

		# Octave root color tone — uses the voice-led root so it sits above
		# the actual root voice rather than fighting it.
		if randf() < 0.40:
			pool.append(float(pool[0]) * 2.0)

		# Random inversion is no longer needed — voice leading already chooses
		# octave shifts that minimize movement, which is essentially picking
		# the optimal inversion automatically.

	arp_note_pool = pool

	# Save the core 3 voices for next chord's voice leading. Skipped during
	# secondary dominants since their voicing is special.
	if not secondary_dom and pool.size() >= 3:
		_previous_voices = [float(pool[0]), float(pool[1]), float(pool[2])]

	return {
		"chord_root_ratio": chord_root_ratio,
		"arp_note_pool": arp_note_pool,
		"bass_freq_hz": bass_freq_hz,
		"mode_name": current_mode_name,
		"chord_index": _current_chord_index,
		"progression_size": current_progression_size,
		"progression_id": _current_progression_id,
		"current_scale": _current_scale,
		"current_root_hz": current_root_hz,
		"is_secondary_dom": secondary_dom,
	}

# =====================================================================
#  INTERNALS
# =====================================================================

func _state_name(state: int) -> String:
	match state:
		0: return "DEEP_SPACE"
		1: return "CRUISING"
		2: return "ATMOSPHERE"
		3: return "SURFACE"
		4: return "COMBAT"
	return "DEEP_SPACE"

func _maybe_modulate() -> void:
	# Roll for modulation each progression boundary.
	if randf() >= _MOD_PROBABILITY:
		return
	var ratio: float = _MOD_INTERVALS[randi() % _MOD_INTERVALS.size()]
	var new_root: float = current_root_hz * ratio

	# Drift correction: if we're outside the ±1-octave band around base,
	# fold back by halving / doubling so bass stays in usable register.
	var rel: float = new_root / BASE_ROOT_HZ
	while rel > _MOD_MAX_RATIO:
		new_root *= 0.5
		rel = new_root / BASE_ROOT_HZ
	while rel < _MOD_MIN_RATIO:
		new_root *= 2.0
		rel = new_root / BASE_ROOT_HZ

	current_root_hz = new_root
	_previous_voices = []   # absolute pitches all shifted; reset VL

func _pick_progression(state_name: String) -> void:
	var bank: Array = _PROG_BANK[state_name]
	var pick: int = randi() % bank.size()
	if bank.size() > 1 and pick == _current_progression_id:
		pick = (pick + 1) % bank.size()
	_current_progression_id = pick
	_current_progression = bank[pick]

func _pick_mode(state_name: String) -> void:
	var bank: Array = _MODE_BANK[state_name]
	var pick: int = randi() % bank.size()
	if bank.size() > 1 and pick == _current_mode_id:
		pick = (pick + 1) % bank.size()
	_current_mode_id = pick
	var key: String = bank[pick]
	_current_scale = _MODES[key]
	current_mode_name = key
	_previous_voices = []   # mode change → ratios mean different intervals; reset VL

# Voice leading: assign each of `prev_core`'s 3 voices a note from `new_core`
# (with optional ±octave shift) such that the total log-pitch movement is
# minimized. Returns a 3-element array in voice order [v0, v1, v2].
#
# Why log-pitch: musical "distance" is logarithmic — an octave is the same
# perceived gap regardless of register. abs(log(a/b)) measures that gap.
#
# Why permute: the same chord can be voiced in different orderings. F major
# after C major sounds smoothest as [C, F, A] (kept C + step-up F + step-up
# A) rather than [F, A, C] (all voices jump). Trying all 6 perms picks the
# smoothest one.
func _voice_lead(new_core: Array, prev_core: Array) -> Array:
	if new_core.size() < 3 or prev_core.size() < 3:
		return new_core
	var best_assignment: Array = [float(new_core[0]), float(new_core[1]), float(new_core[2])]
	var best_cost: float = INF
	for perm in _PERMS_3:
		var assignment: Array = [0.0, 0.0, 0.0]
		var cost: float = 0.0
		for vi in 3:
			var pool_idx: int = int(perm[vi])
			var target: float = float(new_core[pool_idx])
			var prev: float = float(prev_core[vi])
			# Try the note at its default position, an octave up, and an
			# octave down — pick whichever lands closest to prev.
			var best_pitch: float = target
			var best_d: float = abs(log(target / prev))
			var t2: float = target * 2.0
			if t2 <= 4.5 and abs(log(t2 / prev)) < best_d:
				best_pitch = t2
				best_d = abs(log(t2 / prev))
			var t05: float = target * 0.5
			if t05 >= 0.4 and abs(log(t05 / prev)) < best_d:
				best_pitch = t05
				best_d = abs(log(t05 / prev))
			assignment[vi] = best_pitch
			cost += best_d
		if cost < best_cost:
			best_cost = cost
			best_assignment = assignment
	return best_assignment

func _voicing_weights(state_name: String) -> Dictionary:
	match state_name:
		"DEEP_SPACE":
			return {"seventh": 0.30, "ninth": 0.20, "sus2": 0.06, "sus4": 0.06, "inversion": 0.18}
		"CRUISING":
			return {"seventh": 0.30, "ninth": 0.10, "sus2": 0.05, "sus4": 0.05, "inversion": 0.12}
		"ATMOSPHERE":
			return {"seventh": 0.35, "ninth": 0.22, "sus2": 0.08, "sus4": 0.08, "inversion": 0.20}
		"SURFACE":
			return {"seventh": 0.18, "ninth": 0.07, "sus2": 0.04, "sus4": 0.06, "inversion": 0.10}
		"COMBAT":
			return {"seventh": 0.22, "ninth": 0.05, "sus2": 0.03, "sus4": 0.06, "inversion": 0.18}
	return {"seventh": 0.20, "ninth": 0.10, "sus2": 0.05, "sus4": 0.05, "inversion": 0.15}
