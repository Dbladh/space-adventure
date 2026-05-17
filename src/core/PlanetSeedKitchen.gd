class_name PlanetSeedKitchen

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")
# MineralInfluence is available globally via its class_name declaration.

# PlanetSeedKitchen.gd
# Deterministic planet seed + resource list derivation from three forge ingredients.
#
# SEED: product of three primes (one per resource). Same combo → same seed → same planet.
# RESOURCES: pinned to the planet's rank tier (F..SS). Each rank guarantees
#   a minimum count of each rarity (Green / Blue / Purple / Orange) and fills
#   remaining slots from a layered weighted pool that de-emphasises low tiers
#   on higher-rank planets. Stone + Wood are always guaranteed.

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
	"Verdant Spore":    71,
	"Chloro Crystal":   73,
	"Bloomstone":       79,
}

# ─── Per-rank guaranteed minimums (non-Stone/Wood) ───────────────────────────
# tier index → minimum count of that tier on the planet.
const GUARANTEES: Dictionary = {
	"F":           {1: 0, 2: 0, 3: 0, 4: 0, 5: 0},
	"D":           {1: 0, 2: 0, 3: 0, 4: 0, 5: 0},
	"C":           {1: 0, 2: 1, 3: 0, 4: 0, 5: 0},
	"B":           {1: 0, 2: 1, 3: 1, 4: 0, 5: 0},
	"A":           {1: 0, 2: 1, 3: 1, 4: 1, 5: 0},
	"S":           {1: 0, 2: 1, 3: 1, 4: 1, 5: 1},
	"SS":          {1: 0, 2: 1, 3: 1, 4: 2, 5: 2},
	"★ LEGENDARY": {1: 0, 2: 1, 3: 1, 4: 2, 5: 3},
}

# Weights for filling remaining slots after guarantees are met. The slot
# picks a tier first (weighted), then a name from that tier's pool.
const FILL_WEIGHTS: Dictionary = {
	"F":           {1: 1.0,  2: 0.0,  3: 0.0,  4: 0.0,  5: 0.0},
	"D":           {1: 1.0,  2: 0.0,  3: 0.0,  4: 0.0,  5: 0.0},
	"C":           {1: 0.7,  2: 0.6,  3: 0.0,  4: 0.0,  5: 0.0},
	"B":           {1: 0.5,  2: 0.6,  3: 0.5,  4: 0.0,  5: 0.0},
	"A":           {1: 0.3,  2: 0.5,  3: 0.6,  4: 0.4,  5: 0.0},
	"S":           {1: 0.2,  2: 0.4,  3: 0.5,  4: 0.5,  5: 0.3},
	"SS":          {1: 0.1,  2: 0.3,  3: 0.4,  4: 0.6,  5: 0.5},
	"★ LEGENDARY": {1: 0.05, 2: 0.2,  3: 0.3,  4: 0.7,  5: 0.7},
}

# Anchors the rank-score formula to the highest input tier — picking the rank
# tier from the *headline* rarity of the trio rather than the average. Spending
# even one Purple/Orange input pushes you firmly into A/S territory.
const _RANK_TIER_BASE: Dictionary = {1: 0, 2: 26, 3: 42, 4: 58, 5: 74}

# Total non-Stone/Wood extras targeted per planet rank.
const TARGET_EXTRAS: Dictionary = {
	"F":           2,
	"D":           3,
	"C":           4,
	"B":           5,
	"A":           6,
	"S":           7,
	"SS":          8,
	"★ LEGENDARY": 9,
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

	# 1. Resource score (0–74): driven by the HIGHEST input tier. A single
	#    high-tier input "carries" the planet's headline rarity — so spending
	#    a Purple or Orange in the forge guarantees you reach A/S rank.
	var max_tier: int = maxi(maxi(t1, t2), t3)
	var resource_score: float = float(_RANK_TIER_BASE.get(max_tier, 0))

	# 2. Rarity bonus (0–10): extra points for stacking multiple inputs at the
	#    max tier — three-of-a-kind trios get the full bonus.
	var count_at_max: int = 0
	for t in [t1, t2, t3]:
		if t == max_tier: count_at_max += 1
	var rarity_bonus: float = float((count_at_max - 1) * 5)

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

# Returns the full resource list for a forged planet — Stone+Wood plus
# rank-driven extras. Higher-rank planets are guaranteed minimums of higher
# rarities (Green/Blue/Purple/Orange) and bias the remaining slots toward
# top tiers. Luck adds bonus rolls of the planet's top rarity.
static func resources_for_planet(r1: String, r2: String, r3: String) -> Array[String]:
	var result: Array[String] = ["Stone", "Wood"]

	var seed_val := make_seed(r1, r2, r3)
	var rank_dict := rank_planet(r1, r2, r3, seed_val, 0.0)
	var rank_label: String = String(rank_dict.get("label", "F"))

	var luck_bias: float = 0.0
	if Engine.has_meta("UpgradeManager"):
		luck_bias = float(Engine.get_meta("UpgradeManager").get_luck_drop_bias())

	var extras := natural_pool_for_rank(rank_label, seed_val, luck_bias)
	for e in extras:
		if not result.has(e):
			result.append(e)

	# Early-game safety: on F/D planets the natural pool can miss the
	# specific Tier-1 minerals required by early upgrades. Guarantee at least
	# one of {Carbon Fiber, Silica Dust, Neon Moss} alongside Stone+Wood.
	if rank_label == "F" or rank_label == "D":
		var early_specifics: Array[String] = ["Carbon Fiber", "Silica Dust", "Neon Moss"]
		var has_specific := false
		for s in early_specifics:
			if result.has(s):
				has_specific = true
				break
		if not has_specific:
			var rng := RandomNumberGenerator.new()
			rng.seed = seed_val
			var pick: String = early_specifics[rng.randi_range(0, early_specifics.size() - 1)]
			result.append(pick)

	return result

# Build the extras list (non-Stone/Wood) for a planet of the given rank.
# Deterministic per seed; luck adds bonus rolls and biases the top tier on A+.
static func natural_pool_for_rank(rank: String, seed_val: int, luck_bias: float) -> Array[String]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var guarantees: Dictionary = GUARANTEES.get(rank, GUARANTEES["F"])
	var weights: Dictionary = FILL_WEIGHTS.get(rank, FILL_WEIGHTS["F"])
	var target: int = int(TARGET_EXTRAS.get(rank, 2))

	var result: Array[String] = []
	var used: Dictionary = {}

	# 1. Honour guaranteed minimums per tier — seeded-shuffle within tier pool.
	for tier in [2, 3, 4, 5]:
		var min_n: int = int(guarantees.get(tier, 0))
		if min_n <= 0:
			continue
		var tier_pool := _pool_of_tier(tier)
		_seeded_shuffle(tier_pool, rng)
		var added: int = 0
		for n in tier_pool:
			if added >= min_n:
				break
			if not used.has(n):
				result.append(n); used[n] = true
				added += 1

	# 2. Luck-driven bonus roll: on A+ planets, each luck step rolls a chance
	#    for one bonus draw of the planet's top tier(s).
	if luck_bias > 0.0 and (rank == "A" or rank == "S" or rank == "SS" or rank == "★ LEGENDARY"):
		var top_tier: int = 5
		if rank == "A":
			top_tier = 4
		if rng.randf() < luck_bias:
			var bonus_pool := _pool_of_tier(top_tier)
			_seeded_shuffle(bonus_pool, rng)
			for n in bonus_pool:
				if not used.has(n):
					result.append(n); used[n] = true
					break

	# 3. Fill remaining slots from the layered weighted pool until target is hit.
	#    Luck bias multiplies the top non-zero tier's weight by (1 + luck_bias).
	var top_present: int = 0
	for t in [5, 4, 3, 2, 1]:
		if float(weights.get(t, 0.0)) > 0.0:
			top_present = t
			break
	var biased_weights: Dictionary = weights.duplicate(true)
	if top_present > 0 and luck_bias > 0.0:
		biased_weights[top_present] = float(weights.get(top_present, 0.0)) * (1.0 + luck_bias)

	var safety: int = 32
	while result.size() < target and safety > 0:
		safety -= 1
		var t := _weighted_tier_pick(biased_weights, rng)
		if t <= 0:
			break
		var candidates := _pool_of_tier(t)
		var remaining: Array[String] = []
		for n in candidates:
			if not used.has(n):
				remaining.append(n)
		if remaining.is_empty():
			# Exhausted this tier — zero its weight and retry.
			biased_weights[t] = 0.0
			continue
		var pick: String = remaining[rng.randi() % remaining.size()]
		result.append(pick); used[pick] = true

	return result

# All non-Stone/Wood resources of the given tier, excluding sky-only entries.
static func _pool_of_tier(tier: int) -> Array[String]:
	var out: Array[String] = []
	for r in ResourceRegistry.RESOURCES:
		if int(r.tier) != tier: continue
		if r.get("sky_only", false): continue
		if r.name == "Stone" or r.name == "Wood": continue
		out.append(r.name)
	return out

# Pick a tier from weights {tier_int: weight_float}. Returns 0 if all zero.
static func _weighted_tier_pick(weights: Dictionary, rng: RandomNumberGenerator) -> int:
	var total: float = 0.0
	for k in weights.keys():
		total += float(weights[k])
	if total <= 0.0:
		return 0
	var roll: float = rng.randf() * total
	var cum: float = 0.0
	for k in weights.keys():
		cum += float(weights[k])
		if roll <= cum:
			return int(k)
	return int(weights.keys()[weights.size() - 1])

static func _seeded_shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp

# Returns the cost dictionary for a given trio (e.g. ["Cu","Cu","Au"] → {"Copper":2,"Gold":1})
static func resource_cost(r1: String, r2: String, r3: String) -> Dictionary:
	var cost: Dictionary = {}
	for r in [r1, r2, r3]:
		cost[r] = cost.get(r, 0) + 1
	return cost

# Credit cost to forge a planet from this trio. Pure function of the minerals'
# tiers — predictable for the player and stable across seed/luck variance.
const FORGE_TIER_COST: Dictionary = {1: 1000, 2: 5000, 3: 25000, 4: 80000, 5: 300000}

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
