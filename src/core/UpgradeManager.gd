extends Node

# UpgradeManager.gd
# Tracks the player's purchasable stat upgrades. Registered in
# Engine.set_meta("UpgradeManager") so call sites can apply multipliers
# without holding a node reference.

signal upgrade_changed(track: String, new_level: int)
signal upgrade_purchase_failed(track: String, reason: String)

const TRACKS: Array[String] = ["attack", "health", "luck", "forge_slots", "movement"]

const MAX_LEVEL: Dictionary = {
	"attack":      5,
	"health":      5,
	"luck":        5,
	"forge_slots": 7,
	"movement":    3,
}

const DISPLAY_NAME: Dictionary = {
	"attack":      "ATTACK POWER",
	"health":      "HULL INTEGRITY",
	"luck":        "LUCK",
	"forge_slots": "FORGE SLOTS",
	"movement":    "WARP DRIVE",
}

# Effect tables — index = level. Length must be MAX_LEVEL[track] + 1.
const ATTACK_MULT: Array[float] = [1.0, 1.25, 1.6, 2.0, 2.6, 3.5]
const HEALTH_BONUS: Array[int] = [0, 250, 600, 1100, 1800, 3000]
const LUCK_DROP_BIAS: Array[float] = [0.0, 0.05, 0.10, 0.18, 0.28, 0.40]
const LUCK_FORGE_VARIANCE: Array[float] = [0.0, 2.0, 4.0, 7.0, 11.0, 16.0]
const FORGE_SLOTS_TABLE: Array[int] = [1, 2, 3, 4, 5, 6, 7, 8]
const SPEED_MULT: Array[float] = [1.0, 1.35, 1.8, 2.4]

# Cost table — COSTS[track][level_index] = {credits:int, mats:{name:count}}.
# level_index 0 is the cost to go from L0 -> L1, etc.
const COSTS: Dictionary = {
	"attack": [
		{"credits": 500,   "mats": {"Copper": 10}},
		{"credits": 2000,  "mats": {"Copper": 25, "Silver": 5}},
		{"credits": 8000,  "mats": {"Silver": 15, "Gold": 3}},
		{"credits": 20000, "mats": {"Gold": 10, "Platinum": 3}},
		{"credits": 50000, "mats": {"Platinum": 8, "Nebula Core": 1}},
	],
	"health": [
		{"credits": 400,   "mats": {"Carbon Fiber": 15}},
		{"credits": 1800,  "mats": {"Living Resin": 8, "Copper": 10}},
		{"credits": 7000,  "mats": {"Azure Sap": 12, "Silver": 6}},
		{"credits": 18000, "mats": {"Primal Fruit": 5, "Gold": 8}},
		{"credits": 45000, "mats": {"Platinum": 6, "Prismatic Alloy": 1}},
	],
	"luck": [
		{"credits": 1000,  "mats": {"Neon Moss": 20}},
		{"credits": 4000,  "mats": {"Basalt Glass": 10, "Silver": 5}},
		{"credits": 12000, "mats": {"Azure Sap": 15, "Gold": 5}},
		{"credits": 30000, "mats": {"Aether Crystal": 3, "Platinum": 4}},
		{"credits": 80000, "mats": {"Nebula Core": 2, "Prismatic Alloy": 1}},
	],
	"forge_slots": [
		{"credits": 2500,   "mats": {"Stone": 40, "Silica Dust": 20}},
		{"credits": 8000,   "mats": {"Copper": 30, "Basalt Glass": 15}},
		{"credits": 20000,  "mats": {"Silver": 25, "Living Resin": 10}},
		{"credits": 45000,  "mats": {"Gold": 15, "Platinum": 5}},
		{"credits": 90000,  "mats": {"Platinum": 15, "Aether Crystal": 3}},
		{"credits": 160000, "mats": {"Aether Crystal": 5, "Prismatic Alloy": 2}},
		{"credits": 300000, "mats": {"Nebula Core": 3, "Prismatic Alloy": 3}},
	],
	"movement": [
		{"credits": 5000,   "mats": {"Silica Dust": 30, "Copper": 15}},
		{"credits": 25000,  "mats": {"Basalt Glass": 20, "Gold": 5}},
		{"credits": 100000, "mats": {"Prismatic Alloy": 2, "Nebula Core": 1}},
	],
}

var levels: Dictionary = {
	"attack": 0,
	"health": 0,
	"luck": 0,
	"forge_slots": 0,
	"movement": 0,
}

func get_level(track: String) -> int:
	return int(levels.get(track, 0))

func get_max_level(track: String) -> int:
	return int(MAX_LEVEL.get(track, 0))

func is_maxed(track: String) -> bool:
	return get_level(track) >= get_max_level(track)

func get_attack_multiplier() -> float:
	return ATTACK_MULT[get_level("attack")]

func get_max_health_bonus() -> int:
	return HEALTH_BONUS[get_level("health")]

func get_luck_drop_bias() -> float:
	return LUCK_DROP_BIAS[get_level("luck")]

func get_luck_forge_variance() -> float:
	return LUCK_FORGE_VARIANCE[get_level("luck")]

func get_forge_slots() -> int:
	return FORGE_SLOTS_TABLE[get_level("forge_slots")]

func get_speed_multiplier() -> float:
	return SPEED_MULT[get_level("movement")]

func next_cost(track: String) -> Dictionary:
	if is_maxed(track):
		return {}
	var idx := get_level(track)
	var table: Array = COSTS.get(track, [])
	if idx >= table.size():
		return {}
	return table[idx]

func can_afford(track: String) -> bool:
	var cost: Dictionary = next_cost(track)
	if cost.is_empty():
		return false
	var econ = Engine.get_meta("EconomyManager") if Engine.has_meta("EconomyManager") else null
	if econ == null or int(econ.credits) < int(cost.credits):
		return false
	var inv = Engine.get_meta("InventoryManager") if Engine.has_meta("InventoryManager") else null
	if inv == null:
		return false
	for mat_name in cost.mats.keys():
		if inv.get_amount(mat_name) < int(cost.mats[mat_name]):
			return false
	return true

func try_purchase(track: String) -> bool:
	if not levels.has(track):
		emit_signal("upgrade_purchase_failed", track, "unknown_track")
		return false
	if is_maxed(track):
		emit_signal("upgrade_purchase_failed", track, "maxed")
		return false
	if not can_afford(track):
		emit_signal("upgrade_purchase_failed", track, "insufficient")
		return false
	var cost: Dictionary = next_cost(track)
	var econ = Engine.get_meta("EconomyManager")
	var inv = Engine.get_meta("InventoryManager")
	# Consume.
	econ.credits -= int(cost.credits)
	econ.emit_signal("currency_changed", econ.credits)
	for mat_name in cost.mats.keys():
		inv.consume(mat_name, int(cost.mats[mat_name]))
	# Bump level.
	levels[track] = get_level(track) + 1
	emit_signal("upgrade_changed", track, levels[track])
	return true
