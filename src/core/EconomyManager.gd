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

func add_resource(type: String, amount: int = 1) -> void:
	if inventory.has(type):
		inventory[type] += amount
		# For now, auto-sell resources for credits to keep it simple!
		var profit = amount * RESOURCE_VALUES[type]
		credits += profit
		emit_signal("inventory_changed", type, inventory[type])
		emit_signal("currency_changed", credits)
		print("--- ECONOMY: +", profit, " Credits (", type, ") ---")

func get_credits_formatted() -> String:
	return "$" + str(credits)
