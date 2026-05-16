class_name PlanetSeedKitchen

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")
# MineralInfluence is available globally via its class_name declaration.

# PlanetSeedKitchen.gd
# Deterministic planet seed + resource list derivation from three forge ingredients.
#
# SEED: product of three primes (one per resource). Same combo → same seed → same planet.
# RESOURCES: determined by the average tier of the three inputs.
#   Higher tier inputs → higher tier natural resources on the resulting planet.
#   Tier 4 resources are crafted-only and never appear naturally.
#   All planets always have Stone and Wood as base resources.

const RESOURCE_PRIMES: Dictionary = {
	"Stone":            2,
	"Wood":             3,
	"Neon Moss":        5,
	"Silica Dust":      7,
	"Copper":           11,
	"Azure Sap":        13,
	"Basalt Glass":     17,
	"Silver":           19,
	"Gold":             23,
	"Platinum":         29,
	"Prismatic Alloy":  31,
	"Nebula Core":      37,
	"Carbon Fiber":     41,
	"Organic Sludge":   43,
	"Living Resin":     47,
	"Primal Fruit":     53,
	"Diamond":          59,
	"Iron":             61,
	"Titanium":         67,
}

static func make_seed(r1: String, r2: String, r3: String) -> int:
	# Use explicit prime if registered, else hash the name to a stable odd number.
	var p1: int = RESOURCE_PRIMES.get(r1, (hash(r1) & 0x7FFFFFFF) | 1)
	var p2: int = RESOURCE_PRIMES.get(r2, (hash(r2) & 0x7FFFFFFF) | 1)
	var p3: int = RESOURCE_PRIMES.get(r3, (hash(r3) & 0x7FFFFFFF) | 1)
	return p1 * p2 * p3

# ─── PLANET RANKING ──────────────────────────────────────────────────────────
# Returns { label, color, score } where score is 0–100.
# Rank tiers: F → D → C → B → A → S → SS → ★ LEGENDARY
static func rank_planet(r1: String, r2: String, r3: String, seed_val: int, luck_variance: float = 0.0) -> Dictionary:
	var t1 := ResourceRegistry.get_tier(r1)
	var t2 := ResourceRegistry.get_tier(r2)
	var t3 := ResourceRegistry.get_tier(r3)

	# 1. Resource score  (0–60): average tier × 20 capped at 60
	var avg_tier: float = (t1 + t2 + t3) / 3.0
	var resource_score: float = clampf(avg_tier * 20.0, 0.0, 60.0)

	# 2. Rarity bonus (0–20): extra points for having Tier 4 or Tier 3 inputs
	var rarity_bonus: float = 0.0
	for t in [t1, t2, t3]:
		if t == 4: rarity_bonus += 7.0
		elif t == 3: rarity_bonus += 3.0
	rarity_bonus = minf(rarity_bonus, 20.0)

	# 3. Cosmic variance bonus (0–10): seed-derived exotic properties
	#    Oversized planet (seed % 11 == 0) = +4
	#    Rare palette roll (seed % 7 == 0)  = +3
	#    Unique orbit distance (seed % 5 == 0) = +2
	#    Crystalline terrain (seed % 3 == 0)   = +1
	var cosmic: float = 0.0
	if seed_val % 11 == 0: cosmic += 4.0
	if seed_val % 7  == 0: cosmic += 3.0
	if seed_val % 5  == 0: cosmic += 2.0
	if seed_val % 3  == 0: cosmic += 1.0
	cosmic = minf(cosmic, 10.0)

	# Luck-driven variance: deterministic per (seed, luck) so the same forge
	# always produces the same rank — can't be save-scummed by undocking.
	if luck_variance > 0.0:
		var lrng := RandomNumberGenerator.new()
		lrng.seed = seed_val
		cosmic += lrng.randf_range(-luck_variance, luck_variance)

	# 4. Synergy bonus (0–10): matched rank_synergy_tag across the trio.
	var synergy: float = _synergy_bonus(r1, r2, r3)

	var score: float = resource_score + rarity_bonus + cosmic + synergy

	# Map score → rank tier
	var label: String
	var color: Color
	if score >= 97:
		label = "★ LEGENDARY"; color = Color(1.0, 0.55, 0.05)   # fiery orange-gold
	elif score >= 85:
		label = "SS";          color = Color(0.95, 0.2,  0.9)    # neon magenta
	elif score >= 70:
		label = "S";           color = Color(0.35, 0.85, 1.0)    # electric blue
	elif score >= 55:
		label = "A";           color = Color(0.45, 1.0,  0.45)   # bright green
	elif score >= 40:
		label = "B";           color = Color(0.55, 0.55, 1.0)    # soft purple
	elif score >= 25:
		label = "C";           color = Color(0.85, 0.85, 0.85)   # light grey
	elif score >= 12:
		label = "D";           color = Color(0.6,  0.55, 0.45)   # tan/brown
	else:
		label = "F";           color = Color(0.5,  0.5,  0.5)    # mid grey

	return { "label": label, "color": color, "score": int(score) }

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

	# Early-game safety: on Tier-1-only trios the natural pool can miss the
	# specific Tier-1 minerals required by early upgrades. Guarantee at least
	# one of {Carbon Fiber, Silica Dust, Neon Moss} alongside Stone+Wood.
	if max_tier == 1:
		var early_specifics: Array[String] = ["Carbon Fiber", "Silica Dust", "Neon Moss"]
		var has_specific := false
		for s in early_specifics:
			if result.has(s):
				has_specific = true
				break
		if not has_specific:
			var pick: String = early_specifics[rng.randi_range(0, early_specifics.size() - 1)]
			result.append(pick)

	return result

# Returns the cost dictionary for a given trio (e.g. ["Cu","Cu","Au"] → {"Copper":2,"Gold":1})
static func resource_cost(r1: String, r2: String, r3: String) -> Dictionary:
	var cost: Dictionary = {}
	for r in [r1, r2, r3]:
		cost[r] = cost.get(r, 0) + 1
	return cost

# Credit cost to forge a planet from this trio. Pure function of the minerals'
# tiers — predictable for the player and stable across seed/luck variance.
const FORGE_TIER_COST: Dictionary = {1: 1000, 2: 10000, 3: 80000, 4: 300000}

static func forge_credit_cost(r1: String, r2: String, r3: String) -> int:
	var total: int = 0
	for r in [r1, r2, r3]:
		var tier: int = ResourceRegistry.get_tier(r)
		total += int(FORGE_TIER_COST.get(tier, 1000))
	return total

# All 3 minerals share a tag → +10. Exactly 2 share → +4. Otherwise 0.
# Empty tags don't count as a match.
static func _synergy_bonus(r1: String, r2: String, r3: String) -> float:
	var t1 := MineralInfluence.get_synergy_tag(r1)
	var t2 := MineralInfluence.get_synergy_tag(r2)
	var t3 := MineralInfluence.get_synergy_tag(r3)
	var counts: Dictionary = {}
	for t in [t1, t2, t3]:
		if t == "": continue
		counts[t] = counts.get(t, 0) + 1
	var best := 0
	for k in counts.keys():
		if counts[k] > best: best = counts[k]
	if best >= 3: return 10.0
	if best == 2: return 4.0
	return 0.0

# Returns the full PlanetProfile dict for a forged planet:
# combined influence vector + resolved archetype string + ingredient list.
# This is what SpaceStation passes to PlanetGen via `planet_profile`.
static func derive_profile(r1: String, r2: String, r3: String, seed_val: int) -> Dictionary:
	var profile: Dictionary = MineralInfluence.combine(r1, r2, r3)
	profile["archetype"] = MineralInfluence.pick_archetype(profile, seed_val)
	return profile
