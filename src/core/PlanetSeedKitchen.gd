class_name PlanetSeedKitchen

# PlanetSeedKitchen.gd
# Deterministic planet seed derivation from three resource types.
# Each resource maps to a unique prime; the seed is the product.
# This guarantees the same resource combo always produces the same planet.
#
# 5 resources × 3 slots with repetition = 35 unique unordered combinations
# = 35 distinct forgeable worlds.

const RESOURCE_PRIMES: Dictionary = {
	"Copper":   2,
	"Silver":   3,
	"Gold":     5,
	"Platinum": 7,
	"Diamond":  11,
}

static func make_seed(r1: String, r2: String, r3: String) -> int:
	var p1: int = RESOURCE_PRIMES.get(r1, 2)
	var p2: int = RESOURCE_PRIMES.get(r2, 3)
	var p3: int = RESOURCE_PRIMES.get(r3, 5)
	return p1 * p2 * p3

# Returns the cost dictionary for a given trio, e.g. ["Copper","Copper","Gold"]
# → {"Copper": 2, "Gold": 1}
static func resource_cost(r1: String, r2: String, r3: String) -> Dictionary:
	var cost: Dictionary = {}
	for r in [r1, r2, r3]:
		cost[r] = cost.get(r, 0) + 1
	return cost
