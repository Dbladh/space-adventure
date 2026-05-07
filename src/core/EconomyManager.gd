extends Node

# EconomyManager.gd
# Managed by THE ARCHITECT.
# Centralized Authority for Universal Credits and Resource Inventories.

signal currency_changed(new_amount: int)
signal inventory_changed(resource_type: String, new_amount: int)

var credits: int = 0
var inventory: Dictionary = {
	"Copper": 0,
	"Silver": 0,
	"Gold": 0,
	"Platinum": 0,
	"Diamond": 0
}

# VALUE REGISTRY — THE ARCHITECT
const RESOURCE_VALUES: Dictionary = {
	"Copper": 10,
	"Silver": 50,
	"Gold": 250,
	"Platinum": 1000,
	"Diamond": 5000
}

const RESOURCE_TITLES: Array = ["Copper", "Silver", "Gold", "Platinum", "Diamond"]

func add_credits(amount: int) -> void:
	credits += amount
	emit_signal("currency_changed", credits)

func add_resource(type: String, amount: int = 1) -> void:
	# ACE: Resources now sit in inventory until manually sold at a station.
	# InventoryManager is the canonical store; this keeps legacy callers working.
	if Engine.has_meta("InventoryManager"):
		Engine.get_meta("InventoryManager").add(type, amount)
		print("--- ECONOMY: +", amount, "x ", type, " added to inventory ---")

func get_credits_formatted() -> String:
	return "$" + str(credits)
