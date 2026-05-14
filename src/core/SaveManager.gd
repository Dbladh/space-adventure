extends Node

# SaveManager.gd
# JSON-backed persistence for credits, inventory, and upgrade levels.
# Registered in Engine.set_meta("SaveManager"). Auto-saves on a debounce
# after currency/inventory mutations; upgrade purchases save immediately.

const SAVE_PATH := "user://save.json"
const SCHEMA_VERSION := 1
const DEBOUNCE_SECS := 1.5
const SpaceStationGD := preload("res://src/world/SpaceStation.gd")

var _dirty: bool = false
var _debounce_t: float = 0.0
var _wired: bool = false

func _ready() -> void:
	_wire_signals()

func _wire_signals() -> void:
	if _wired:
		return
	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		if not econ.is_connected("currency_changed", _on_currency_changed):
			econ.currency_changed.connect(_on_currency_changed)
	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		if not inv.is_connected("inventory_changed", _on_inventory_changed):
			inv.inventory_changed.connect(_on_inventory_changed)
	if Engine.has_meta("UpgradeManager"):
		var up = Engine.get_meta("UpgradeManager")
		if not up.is_connected("upgrade_changed", _on_upgrade_changed):
			up.upgrade_changed.connect(_on_upgrade_changed)
	_wired = true

func _on_currency_changed(_n: int) -> void:
	_mark_dirty()

func _on_inventory_changed(_t: String, _n: int) -> void:
	_mark_dirty()

func _on_upgrade_changed(_t: String, _l: int) -> void:
	save_now()

func _mark_dirty() -> void:
	_dirty = true
	_debounce_t = 0.0

func _process(dt: float) -> void:
	if not _dirty:
		return
	_debounce_t += dt
	if _debounce_t >= DEBOUNCE_SECS:
		save_now()

func save_now() -> void:
	_dirty = false
	_debounce_t = 0.0
	var data: Dictionary = {
		"version": SCHEMA_VERSION,
		"credits": 0,
		"inventory": {},
		"upgrades": {},
		"planets": [],
	}
	if Engine.has_meta("EconomyManager"):
		data["credits"] = int(Engine.get_meta("EconomyManager").credits)
	if Engine.has_meta("InventoryManager"):
		data["inventory"] = Engine.get_meta("InventoryManager").get_all()
	if Engine.has_meta("UpgradeManager"):
		data["upgrades"] = Engine.get_meta("UpgradeManager").levels.duplicate()
	data["planets"] = SpaceStationGD.active_planets_for_save()
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("SaveManager: failed to open " + SAVE_PATH + " for write")
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

func load_if_exists() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		print("--- SAVE: no save file present, starting fresh ---")
		return false
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		push_warning("SaveManager: failed to open " + SAVE_PATH + " for read")
		return false
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_back_up_corrupt_file("invalid_json")
		return false
	if int(parsed.get("version", 0)) != SCHEMA_VERSION:
		_back_up_corrupt_file("version_mismatch")
		return false

	# Restore credits.
	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		econ.credits = int(parsed.get("credits", 0))
		econ.emit_signal("currency_changed", econ.credits)

	# Restore inventory.
	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		var src_inv: Dictionary = parsed.get("inventory", {})
		for k in src_inv.keys():
			inv._stacks[k] = int(src_inv[k])
			inv.emit_signal("inventory_changed", k, inv._stacks[k])

	# Restore upgrades.
	if Engine.has_meta("UpgradeManager"):
		var up = Engine.get_meta("UpgradeManager")
		var src_up: Dictionary = parsed.get("upgrades", {})
		for t in src_up.keys():
			if up.levels.has(t):
				up.levels[t] = clampi(int(src_up[t]), 0, up.get_max_level(t))
				up.emit_signal("upgrade_changed", t, up.levels[t])

	# Restore forged-planet descriptors. Nodes are NOT spawned here —
	# Main.gd calls SpaceStation._rehydrate_active_planets() once world_root
	# is in the tree.
	var planets_data = parsed.get("planets", [])
	if typeof(planets_data) == TYPE_ARRAY:
		SpaceStationGD.load_active_planets_from_save(planets_data)

	print("--- SAVE: loaded ", SAVE_PATH, " ---")
	return true

func _back_up_corrupt_file(reason: String) -> void:
	var stamp := str(Time.get_unix_time_from_system())
	var bak := SAVE_PATH + ".bak." + stamp
	var d := DirAccess.open("user://")
	if d != null:
		d.rename(SAVE_PATH.replace("user://", ""), bak.replace("user://", ""))
	push_warning("SaveManager: backed up bad save (" + reason + ") -> " + bak)
