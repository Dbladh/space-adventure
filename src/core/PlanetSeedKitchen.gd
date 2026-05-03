class_name PlanetSeedKitchen

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")

# PlanetSeedKitchen.gd
# Deterministic planet seed + resource list derivation from three forge ingredients.
#
# SEED: product of three primes (one per resource). Same combo → same seed → same planet.
# RESOURCES: determined by the average tier of the three inputs.
#   Higher tier inputs → higher tier natural resources on the resulting planet.
#   Tier 4 resources are crafted-only and never appear naturally.
#   All planets always have Stone and Wood as base resources.

const RESOURCE_PRIMES: Dictionary = {
	"Stone":          2,
	"Wood":           3,
	"Neon Moss":      5,
	"Silica Dust":    7,
	"Copper":         11,
	"Azure Sap":      13,
	"Basalt Glass":   17,
	"Silver":         19,
	"Gold":           23,
	"Platinum":       29,
	"Prismatic Alloy":31,
	"Nebula Core":    37,
}

static func make_seed(r1: String, r2: String, r3: String) -> int:
	var p1: int = RESOURCE_PRIMES.get(r1, 2)
	var p2: int = RESOURCE_PRIMES.get(r2, 3)
	var p3: int = RESOURCE_PRIMES.get(r3, 5)
	return p1 * p2 * p3

# Returns the full resource list for a forged planet — always Stone+Wood plus
# 2-4 extras drawn deterministically from the pool unlocked by the forge tier.
static func resources_for_planet(r1: String, r2: String, r3: String) -> Array[String]:
	var result: Array[String] = ["Stone", "Wood"]

	var t1 := ResourceRegistry.get_tier(r1)
	var t2 := ResourceRegistry.get_tier(r2)
	var t3 := ResourceRegistry.get_tier(r3)
	# Ceiling of average — generous: one Tier 3 in a Tier 1 mix unlocks Tier 2 pool
	var max_tier: int = ceili((t1 + t2 + t3) / 3.0)

	var pool: Array[String] = ResourceRegistry.natural_pool(max_tier)
	if pool.is_empty():
		return result

	# Deterministic shuffle using planet seed
	var seed_val := make_seed(r1, r2, r3)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var shuffled := pool.duplicate()
	for i in range(shuffled.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = shuffled[i]; shuffled[i] = shuffled[j]; shuffled[j] = tmp

	# Number of extras scales with max_tier: T1→2, T2→3, T3→4
	var count := 1 + max_tier
	for i in range(min(count, shuffled.size())):
		result.append(shuffled[i])

	return result

# Returns the cost dictionary for a given trio (e.g. ["Cu","Cu","Au"] → {"Copper":2,"Gold":1})
static func resource_cost(r1: String, r2: String, r3: String) -> Dictionary:
	var cost: Dictionary = {}
	for r in [r1, r2, r3]:
		cost[r] = cost.get(r, 0) + 1
	return cost
