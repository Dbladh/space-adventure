extends Node3D

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")

# AsteroidMineComponent.gd
# Mining interface for asteroids. Spawns loot when destroyed and notifies the
# owning belt via the `asteroid_destroyed` signal so the belt can recycle the
# slot/node into its pool. Group membership is managed by the belt on the
# parent StaticBody3D, not here, to keep targeting tied to actual hit range.

signal asteroid_destroyed(asteroid: Node)

var asteroid_parent: Node3D = null
var _health: int = 4
var destroyed: bool = false

const DROP_WEIGHTS: Dictionary = {
	1: 0.60,
	2: 0.25,
	3: 0.12,
	4: 0.03,
}

func _ready() -> void:
	if get_parent() is Node3D:
		asteroid_parent = get_parent()

func take_damage(_amount: float) -> void:
	if destroyed: return
	_health -= 1
	if _health <= 0:
		_on_health_depleted()

func _on_health_depleted() -> void:
	_on_destroyed()

func _on_destroyed() -> void:
	if destroyed: return
	destroyed = true

	if not asteroid_parent:
		return

	var gem_script = load("res://src/world/LootGem.gd")
	if gem_script:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var count_stone: int = rng.randi_range(4, 8)
		var count_rare: int = rng.randi_range(0, 2)

		var resource_types: Array[String] = []
		for i in range(count_stone):
			resource_types.append("Stone")
		for i in range(count_rare):
			resource_types.append(_pick_weighted_resource(rng))

		var spawn_origin = asteroid_parent.global_position
		for resource_type in resource_types:
			var gem := Node3D.new()
			gem.set_script(gem_script)
			gem.set("resource_type", resource_type)
			gem.set("value", ResourceRegistry.get_value(resource_type))
			gem.set("col", ResourceRegistry.get_color(resource_type))
			gem.set("planet", null)
			gem.set("surface_dist", 0.0)
			get_tree().root.add_child(gem)
			gem.global_position = spawn_origin + Vector3(randf_range(-100.0, 100.0), randf_range(-100.0, 100.0), randf_range(-100.0, 100.0))
	else:
		push_error("Failed to load LootGem script")

	asteroid_destroyed.emit(asteroid_parent)

func _pick_weighted_resource(rng: RandomNumberGenerator) -> String:
	var tiers = [1, 2, 3]
	var tier_pools: Dictionary = {}
	var total_weight: float = 0.0

	for tier in tiers:
		var t_pool = ResourceRegistry.natural_pool(tier)
		if not t_pool.is_empty():
			var weight = DROP_WEIGHTS.get(tier, 0.1)
			tier_pools[tier] = {"pool": t_pool, "weight": weight}
			total_weight += weight

	if tier_pools.is_empty():
		return "Stone"

	var rand_val = rng.randf() * total_weight
	var cumulative = 0.0
	var chosen_tier = 1

	for tier in tier_pools.keys():
		cumulative += tier_pools[tier]["weight"]
		if rand_val <= cumulative:
			chosen_tier = tier
			break

	var pool = tier_pools[chosen_tier]["pool"]
	return pool[rng.randi() % pool.size()]
