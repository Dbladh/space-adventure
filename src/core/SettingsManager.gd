extends Node

# SettingsManager.gd
#
# Persists user preferences (audio volume, mobile control prefs) to
# user://settings.cfg using ConfigFile.  Separate from SaveManager so these
# survive a NEW GAME wipe — preferences are user-scoped, save.json is
# game-scoped.
#
# Registered via Engine.set_meta("SettingsManager") so call sites can fetch
# without holding a node reference.

const SETTINGS_PATH := "user://settings.cfg"

# Volume curve: 0 = mute, 4 = full.  dB values picked so the four steps
# above mute are perceptually evenly spaced.
const VOLUME_LEVELS: Array[float] = [-80.0, -20.0, -10.0, -3.0, 0.0]
const DEFAULT_LEVEL: int = 4   # full volume by default

# Mobile control cyclers — mirror values defined in MobileControlsUI so the
# bridged signals stay numerically consistent.
const SENS_LEVELS: Array[float] = [0.6, 1.0, 1.6]
const DEAD_LEVELS: Array[float] = [0.8, 1.4, 2.4]

var _cfg: ConfigFile = null
var music_level: int = DEFAULT_LEVEL
var sfx_level:   int = DEFAULT_LEVEL
var gyro_paused: bool = false
var sens_idx:    int = 1
var dead_idx:    int = 1

signal music_volume_applied(level: int)
signal sfx_volume_applied(level: int)

func _ready() -> void:
	_cfg = ConfigFile.new()
	_load()
	# Apply audio settings now that buses exist (project.godot points
	# audio/buses/default_bus_layout at default_bus_layout.tres).
	_apply_music()
	_apply_sfx()

func _load() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var err := _cfg.load(SETTINGS_PATH)
	if err != OK:
		push_warning("SettingsManager: failed to load " + SETTINGS_PATH + " (err " + str(err) + ")")
		return
	music_level = clampi(int(_cfg.get_value("audio", "music_level", DEFAULT_LEVEL)), 0, VOLUME_LEVELS.size() - 1)
	sfx_level   = clampi(int(_cfg.get_value("audio", "sfx_level",   DEFAULT_LEVEL)), 0, VOLUME_LEVELS.size() - 1)
	gyro_paused = bool(_cfg.get_value("controls", "gyro_paused", false))
	sens_idx    = clampi(int(_cfg.get_value("controls", "sens_idx", 1)), 0, SENS_LEVELS.size() - 1)
	dead_idx    = clampi(int(_cfg.get_value("controls", "dead_idx", 1)), 0, DEAD_LEVELS.size() - 1)

func _save() -> void:
	_cfg.set_value("audio", "music_level", music_level)
	_cfg.set_value("audio", "sfx_level",   sfx_level)
	_cfg.set_value("controls", "gyro_paused", gyro_paused)
	_cfg.set_value("controls", "sens_idx", sens_idx)
	_cfg.set_value("controls", "dead_idx", dead_idx)
	_cfg.save(SETTINGS_PATH)

# MusicDirector splits music across three sibling buses (Music / BassLine /
# Perc), each sending to Master.  Apply the user's "music volume" to all
# three so the slider behaves like a single knob.
const _MUSIC_BUSES: Array[String] = ["Music", "BassLine", "Perc"]

func _apply_music() -> void:
	var db: float = VOLUME_LEVELS[music_level]
	var muted: bool = music_level == 0
	for bus_name in _MUSIC_BUSES:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx < 0: continue
		AudioServer.set_bus_volume_db(idx, db)
		AudioServer.set_bus_mute(idx, muted)
	emit_signal("music_volume_applied", music_level)

func _apply_sfx() -> void:
	var idx := AudioServer.get_bus_index("SFX")
	if idx < 0: return
	AudioServer.set_bus_volume_db(idx, VOLUME_LEVELS[sfx_level])
	AudioServer.set_bus_mute(idx, sfx_level == 0)
	emit_signal("sfx_volume_applied", sfx_level)

# ── Public setters (wired to PauseMenuUI signals via Main.gd) ──────────────

func set_music_volume(level: int) -> void:
	music_level = clampi(level, 0, VOLUME_LEVELS.size() - 1)
	_apply_music()
	_save()

func set_sfx_volume(level: int) -> void:
	sfx_level = clampi(level, 0, VOLUME_LEVELS.size() - 1)
	_apply_sfx()
	_save()

func set_gyro_paused(paused: bool) -> void:
	gyro_paused = paused
	_save()

func set_sens_idx(idx: int) -> void:
	sens_idx = clampi(idx, 0, SENS_LEVELS.size() - 1)
	_save()

func set_dead_idx(idx: int) -> void:
	dead_idx = clampi(idx, 0, DEAD_LEVELS.size() - 1)
	_save()
