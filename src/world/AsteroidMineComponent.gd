extends Node3D

# AsteroidMineComponent.gd
# Mining interface for asteroids. Spawns loot when destroyed.
# Attached as a child of asteroid nodes and handles damage/destruction.

var asteroid_parent: Node3D = null
var _health: int = 3  # Asteroids need more hits than rocks
var destroyed: bool = false

# Tier-weighted drop probabilities (higher tier = lower chance)
const DROP_WEIGHTS: Dictionary = {
	1: 0.60,  # Tier 1 (Stone) — 60% chance
	2: 0.25,  # Tier 2 (Copper, etc) — 25% chance
	3: 0.12,  # Tier 3 (Gold, Platinum) — 12% chance
	4: 0.03,  # Tier 4 (Crafted only, very rare) — 3% chance
}

func _ready() -> void:
	add_to_group("Mineable")
	add_to_group("Targets")
	add_to_group("Destructible")
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
	destroyed = true

	if asteroid_parent:
		# Spawn 1-3 loot gems with weighted rarity
		var gem_script = load("res://src/world/LootGem.gd")
		if gem_script:
			var rng := RandomNumberGenerator.new()
			rng.randomize()
			var count: int = rng.randi_range(1, 3)

			# First gem is always Stone (guaranteed), then add weighted rare drops
			var resource_types: Array[String] = ["Stone"]
			for i in range(count - 1):
				resource_types.append(_pick_weighted_resource(rng))

			for resource_type in resource_types:
				var gem := Node3D.new()
				gem.set_script(gem_script)
				gem.set("resource_type", resource_type)
				gem.set("value", ResourceRegistry.get_value(resource_type))
				gem.set("col", ResourceRegistry.get_color(resource_type))
				gem.set("planet", null)  # Asteroids don't have a "down" direction
				gem.set("surface_dist", 0.0)
				get_tree().root.add_child(gem)
				gem.global_position = asteroid_parent.global_position + Vector3(randf_range(-50.0, 50.0), randf_range(-50.0, 50.0), randf_range(-50.0, 50.0))

		# Destroy the asteroid itself
		if asteroid_parent:
			# Mark for removal — the AsteroidBelt will handle cleanup
			asteroid_parent.queue_free()

# Pick a resource based on tier weights and natural pool availability
func _pick_weighted_resource(rng: RandomNumberGenerator) -> String:
	var tiers = [1, 2, 3]  # Available tiers for asteroid drops
	var tier_pools: Dictionary = {}
	var total_weight: float = 0.0

	# Build weighted tier list based on available pools
	for tier in tiers:
		var pool = ResourceRegistry.natural_pool(tier)
		if not pool.is_empty():
			var weight = DROP_WEIGHTS.get(tier, 0.1)
			tier_pools[tier] = {"pool": pool, "weight": weight}
			total_weight += weight

	if tier_pools.is_empty():
		return "Stone"

	# Pick a tier based on weighted probabilities
	var rand_val = rng.randf() * total_weight
	var cumulative = 0.0
	var chosen_tier = 1

	for tier in tier_pools.keys():
		cumulative += tier_pools[tier]["weight"]
		if rand_val <= cumulative:
			chosen_tier = tier
			break

	# Pick a random resource from the chosen tier
	var pool = tier_pools[chosen_tier]["pool"]
	return pool[rng.randi() % pool.size()]
