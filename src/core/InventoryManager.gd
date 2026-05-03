extends Node

# InventoryManager.gd
# Tracks resource stacks collected by the player.
# Registered in Engine.set_meta("InventoryManager") so any script can reach it
# without relying on a fixed scene-tree path.

signal inventory_changed(resource_type: String, new_amount: int)

const RESOURCE_NAMES: Array[String] = ["Copper", "Silver", "Gold", "Platinum", "Diamond"]

var _stacks: Dictionary = {}

func _ready() -> void:
	for r in RESOURCE_NAMES:
		_stacks[r] = 0

func add(resource_type: String, amount: int = 1) -> void:
	if not _stacks.has(resource_type):
		_stacks[resource_type] = 0
	_stacks[resource_type] += amount
	emit_signal("inventory_changed", resource_type, _stacks[resource_type])

func get_amount(resource_type: String) -> int:
	return _stacks.get(resource_type, 0)

func consume(resource_type: String, amount: int) -> bool:
	if get_amount(resource_type) < amount:
		return false
	_stacks[resource_type] -= amount
	emit_signal("inventory_changed", resource_type, _stacks[resource_type])
	return true

func get_all() -> Dictionary:
	return _stacks.duplicate()
