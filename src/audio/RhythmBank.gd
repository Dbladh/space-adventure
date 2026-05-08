class_name RhythmBank
extends RefCounted

# RhythmBank.gd
# Owns percussion patterns, bass grooves, fills, hi-hat ornaments, and
# drop/riser scheduling. Patterns are now 16 steps per bar (16th notes)
# for finer rhythmic resolution and per-step velocity.

# =====================================================================
#  PERCUSSION PATTERNS (16 steps per bar)
#  bit 0 (1)  = kick
#  bit 1 (2)  = snare
#  bit 2 (4)  = closed hi-hat (crisp 18ms tick)
#  bit 3 (8)  = open hi-hat   (sloshy 130ms ring)
#  Common combos: 5 = kick+chat, 6 = snare+chat, 7 = all-three,
#                 9 = kick+ohat, 10 = snare+ohat
#  Open hat on the "and" of beats is the classic house/EDM groove —
#  the closed-closed-closed-OPEN pattern that defines dance music.
# =====================================================================

var _PERC_PATTERNS: Dictionary = {
	"DEEP_SPACE": [
		[1,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0],   # bare downbeat
		[1,0,0,0, 0,0,0,0, 1,0,0,0, 0,0,0,0],   # double pulse
		[1,0,0,0, 0,0,8,0, 0,0,0,0, 0,8,0,0],   # pulse + sparse open hat (sloshy)
		[1,0,0,0, 4,0,0,0, 0,0,0,0, 4,0,0,0],   # pulse + half-time closed hat
	],
	"CRUISING": [
		[1,0,4,0, 1,0,8,0, 1,0,4,0, 1,0,8,0],   # 4-on-floor with open on "and of 2 & 4"
		[1,0,4,4, 1,0,4,8, 1,0,4,4, 1,0,4,8],   # 16th hats, open on every "a"
		[5,0,4,0, 1,0,8,4, 5,0,4,0, 1,4,4,8],   # stuttering with open accents
		[1,4,4,0, 4,0,4,8, 1,0,4,4, 4,0,8,0],   # syncopated open
	],
	"ATMOSPHERE": [
		[0,0,8,0, 0,0,4,0, 0,0,8,0, 0,0,4,0],   # off-beat hats alternating open/closed
		[4,0,0,8, 0,0,4,0, 4,0,0,8, 0,0,4,0],   # syncopated mix
		[0,0,4,8, 4,0,0,4, 0,0,4,8, 4,0,0,4],   # busy off-beats
		[0,8,0,0, 4,0,0,8, 0,8,0,0, 4,0,0,8],   # sparse with open ringing
	],
	"SURFACE": [
		[1,0,4,0, 6,0,8,0, 1,0,4,0, 6,0,8,0],   # standard groove + open on "and of 2 & 4"
		[1,0,4,4, 6,4,4,8, 1,0,4,4, 6,4,4,8],   # busy + open on the "a"
		[5,4,6,4, 5,4,6,8, 5,4,6,4, 5,4,6,8],   # full-on with open ring
		[1,4,4,0, 6,0,4,8, 1,0,4,4, 6,4,4,8],   # syncopated + open accents
	],
	"COMBAT": [
		[1,0,4,4, 6,0,4,8, 1,0,4,4, 6,0,4,8],   # double-time + open on "a"
		[5,4,6,4, 5,4,7,8, 5,4,6,4, 5,4,7,8],   # heavy + open accents
		[5,0,5,0, 6,4,5,8, 5,0,5,0, 6,4,5,8],   # double kick + open
		[7,4,6,4, 5,4,7,8, 5,4,6,4, 5,4,7,8],   # frenetic + open
	],
}

# =====================================================================
#  PER-STEP VELOCITY (16 steps)
#  Downbeats loud, off-beats progressively softer — gives natural feel.
# =====================================================================

const STEP_VEL: Array = [
	1.00, 0.55, 0.72, 0.55,    # beat 1: 1 e + a
	0.88, 0.55, 0.72, 0.55,    # beat 2
	0.95, 0.55, 0.72, 0.55,    # beat 3
	0.88, 0.55, 0.72, 0.55,    # beat 4
]

# =====================================================================
#  BASS GROOVES (16 steps per bar — unchanged structure)
# =====================================================================

var _BASS_GROOVES: Dictionary = {
	"DEEP_SPACE": [
		[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
		[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
		[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0],
	],
	"CRUISING": [
		[1.0, 0.7, 0.9, 0.7, 1.0, 0.7, 0.9, 0.7, 1.0, 0.7, 0.9, 0.7, 1.0, 0.7, 0.9, 0.7],
		[1.0, 0.6, 1.0, 0.6, 0.9, 0.6, 1.0, 0.6, 1.0, 0.6, 1.0, 0.6, 0.9, 0.6, 1.0, 0.6],
		[1.0, 0.0, 0.8, 0.7, 1.0, 0.0, 0.8, 0.7, 1.0, 0.0, 0.8, 0.7, 1.0, 0.0, 0.8, 0.7],
		[0.8, 0.6, 1.0, 0.6, 0.8, 0.6, 1.0, 0.6, 0.9, 0.6, 1.0, 0.6, 0.9, 0.6, 1.0, 0.6],
	],
	"ATMOSPHERE": [
		[1.0, 0.6, 0.7, 0.5, 1.0, 0.6, 0.7, 0.5, 1.0, 0.6, 0.7, 0.5, 1.0, 0.6, 0.7, 0.5],
		[1.0, 0.0, 0.7, 0.0, 1.0, 0.0, 0.7, 0.0, 1.0, 0.0, 0.7, 0.0, 1.0, 0.0, 0.7, 0.0],
		[0.8, 0.5, 0.0, 0.5, 0.8, 0.5, 0.0, 0.5, 0.8, 0.5, 0.0, 0.5, 0.8, 0.5, 0.0, 0.5],
	],
	"SURFACE": [
		[1.0, 0.8, 0.9, 0.7, 1.0, 0.8, 0.9, 0.7, 1.0, 0.8, 0.9, 0.7, 1.0, 0.8, 0.9, 0.7],
		[1.0, 0.0, 0.9, 0.7, 1.0, 0.0, 0.9, 0.7, 1.0, 0.0, 0.9, 0.7, 1.0, 0.0, 0.9, 0.7],
		[1.0, 0.7, 0.9, 0.7, 0.9, 0.7, 1.0, 0.7, 1.0, 0.7, 0.9, 0.7, 1.0, 0.7, 0.8, 0.7],
		[0.9, 0.7, 1.0, 0.7, 1.0, 0.7, 0.9, 0.7, 0.9, 0.7, 1.0, 0.7, 1.0, 0.7, 0.9, 0.7],
	],
	"COMBAT": [
		[1.0, 0.8, 1.0, 0.8, 1.0, 0.8, 1.0, 0.8, 1.0, 0.8, 1.0, 0.8, 1.0, 0.8, 1.0, 0.8],
		[1.0, 0.0, 1.0, 0.8, 1.0, 0.8, 0.9, 0.0, 1.0, 0.0, 1.0, 0.8, 1.0, 0.8, 0.9, 0.0],
		[1.0, 0.9, 1.0, 0.9, 0.8, 0.9, 1.0, 0.9, 1.0, 0.9, 1.0, 0.9, 0.8, 0.9, 1.0, 0.9],
		[1.0, 0.0, 0.0, 0.8, 1.0, 0.0, 0.9, 0.8, 1.0, 0.0, 0.0, 0.8, 1.0, 0.0, 0.9, 0.8],
	],
}

# =====================================================================
#  FILLS (16 steps each)
#  Tom bits: 32 = hi tom, 64 = mid tom, 128 = lo tom.
#  Real drum-fill character now — descending tom rolls with kick/snare
#  punctuation on the climax.
# =====================================================================

var _FILLS: Array = [
	# Classic descending tom roll: hi-hi mid-mid lo-lo + crashing kick+snare
	[0,0,0,0,    32,0,32,0,    64,0,64,0,    128,0,1,7],
	# Triplet-feel tom run with snare lead-in
	[2,0,32,32,  64,64,2,0,    32,32,64,64,  128,128,1,3],
	# Snare ramp with tom accents
	[5,0,32,0,   2,0,64,0,     5,0,128,0,    2,32,1,7],
	# Aggressive: dense toms doubling kick on every step
	[1,32,32,32, 64,64,64,64,  128,128,128,128, 1,2,7,7],
]

# =====================================================================
#  DROP / RISER SCHEDULING
#  Every DROP_CYCLE bars, the music breaks down for 1 bar (perc + bass
#  go silent). The bar BEFORE the drop is the riser bar — used by
#  MusicDirector to trigger a noise-sweep buildup.
# =====================================================================

const DROP_CYCLE: int = 16   # bars between drop events
const DROP_BAR_OFFSET: int = 0    # which bar in the cycle is the drop
const RISER_BAR_OFFSET: int = 15  # bar before drop (the climax build)

# Drops are only triggered in rhythmic states — DEEP_SPACE/ATMOSPHERE keep
# their ambient feel.
var _DROP_STATES: Array = [1, 3, 4]   # CRUISING, SURFACE, COMBAT

# =====================================================================
#  RUNTIME STATE
# =====================================================================

var _perc_pattern_id: int = 0
var _perc_bars_left: int = 0
var _bass_groove_id: int = 0
var _bass_bars_left: int = 0

var _current_perc_pattern: Array = []
var _current_bass_groove: Array = []
var _hat_run_active: bool = false
var _drop_active: bool = false
var _riser_active: bool = false

func _init() -> void:
	# Sensible defaults so callers can read patterns before first notify.
	_current_perc_pattern = _PERC_PATTERNS["DEEP_SPACE"][0]
	_current_bass_groove = _BASS_GROOVES["DEEP_SPACE"][0]

# =====================================================================
#  PUBLIC API
# =====================================================================

func notify_bar_start(state: int, bar_idx: int) -> void:
	var sname := _state_name(state)

	# Drop/riser scheduling — only for rhythmic states.
	var rhythmic: bool = state in _DROP_STATES
	var cycle_pos: int = bar_idx % DROP_CYCLE
	_drop_active = rhythmic and cycle_pos == DROP_BAR_OFFSET and bar_idx > 0
	_riser_active = rhythmic and cycle_pos == RISER_BAR_OFFSET

	# Hi-hat ornament: 12% chance per bar to lay down constant hats over
	# whatever the base pattern is doing. Skipped on fill bars to keep
	# fills crisp.
	_hat_run_active = randf() < 0.12

	# Drop bars are silent — return an empty pattern.
	if _drop_active:
		_current_perc_pattern = [0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0]
		_hat_run_active = false
	# Fill bar selection: every 4th bar, optionally substitute a fill.
	elif bar_idx % 4 == 3:
		# 20% chance to skip the fill (keep base pattern) — adds variety.
		if randf() < 0.20:
			_current_perc_pattern = _normal_perc_pattern_for(state)
		else:
			_current_perc_pattern = _FILLS[randi() % _FILLS.size()]
			_hat_run_active = false   # fill carries its own hat figure
	else:
		_perc_bars_left -= 1
		if _perc_bars_left <= 0:
			_roll_perc_pattern(sname)
			_perc_bars_left = randi_range(2, 4)
		_current_perc_pattern = _normal_perc_pattern_for(state)

	# Bass groove rotation (independent rotation cadence — feels less locked).
	_bass_bars_left -= 1
	if _bass_bars_left <= 0:
		_roll_bass_groove(sname)
		_bass_bars_left = randi_range(2, 4)
	_current_bass_groove = _BASS_GROOVES[sname][_bass_groove_id % _BASS_GROOVES[sname].size()]

func get_perc_step(step_idx: int) -> int:
	if _current_perc_pattern.is_empty():
		return 0
	var s: int = int(_current_perc_pattern[step_idx % _current_perc_pattern.size()])
	if _hat_run_active:
		s |= 4   # OR in the hi-hat bit
	return s

func get_bass_groove_step(step_idx: int) -> float:
	if _current_bass_groove.is_empty():
		return 0.0
	# During drops, bass goes silent too (gives the reset its full weight).
	if _drop_active:
		return 0.0
	return float(_current_bass_groove[step_idx % _current_bass_groove.size()])

func is_drop_active() -> bool:
	return _drop_active

func is_riser_active() -> bool:
	return _riser_active

# =====================================================================
#  INTERNALS
# =====================================================================

func _normal_perc_pattern_for(state: int) -> Array:
	var sname := _state_name(state)
	var bank: Array = _PERC_PATTERNS[sname]
	return bank[_perc_pattern_id % bank.size()]

func _roll_perc_pattern(state_name: String) -> void:
	var bank: Array = _PERC_PATTERNS[state_name]
	var pick: int = randi() % bank.size()
	if bank.size() > 1 and pick == _perc_pattern_id:
		pick = (pick + 1) % bank.size()
	_perc_pattern_id = pick

func _roll_bass_groove(state_name: String) -> void:
	var bank: Array = _BASS_GROOVES[state_name]
	var pick: int = randi() % bank.size()
	if bank.size() > 1 and pick == _bass_groove_id:
		pick = (pick + 1) % bank.size()
	_bass_groove_id = pick

func _state_name(state: int) -> String:
	match state:
		0: return "DEEP_SPACE"
		1: return "CRUISING"
		2: return "ATMOSPHERE"
		3: return "SURFACE"
		4: return "COMBAT"
	return "DEEP_SPACE"
