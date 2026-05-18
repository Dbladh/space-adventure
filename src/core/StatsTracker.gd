extends Node

# StatsTracker.gd
# Lightweight counters that survive across the session.  Registered as
# Engine.set_meta("StatsTracker"); SaveManager pulls these into save.json
# and seeds them back on load.  Currently tracks: enemy kills + playtime.

signal stats_changed()

var enemy_kills: int = 0
var playtime_seconds: float = 0.0

func _ready() -> void:
	process_mode = PROCESS_MODE_PAUSABLE  # Don't accrue time while paused.

func _process(dt: float) -> void:
	playtime_seconds += dt

func add_kill() -> void:
	enemy_kills += 1
	stats_changed.emit()
	if Engine.has_meta("SaveManager"):
		Engine.get_meta("SaveManager")._mark_dirty()

func set_from_save(kills: int, secs: float) -> void:
	enemy_kills = max(0, kills)
	playtime_seconds = max(0.0, secs)
	stats_changed.emit()

func format_playtime() -> String:
	var total: int = int(playtime_seconds)
	var hours: int = total / 3600
	var minutes: int = (total % 3600) / 60
	return "%d:%02d" % [hours, minutes]
