class_name MineralInfluence

# MineralInfluence.gd
# Per-mineral influence vectors that twist procedural planet math.
# Each mineral pushes 3-5 signature knobs hard, leaving the rest neutral.
# Three minerals combine into a single PlanetProfile that PlanetGen consumes.
#
# Field semantics:
#   archetype_votes:        Dict[String -> float]  — weighted votes per archetype, summed
#   terrain_mult:           float (default 1.0)    — multiplies terrain_strength
#   noise_freq_mult:        float (default 1.0)    — multiplies noise_frequency
#   noise_octaves_delta:    int   (default 0)      — added to fractal_octaves
#   noise_gain_delta:       float (default 0.0)    — added to fractal_gain
#   sea_level_delta:        float (default 0.0)    — added to sea_level (neg = deeper water)
#   hue_shift:              float (default 0.0)    — palette hue rotation (wraps 0..1)
#   saturation_mult:        float (default 1.0)    — palette saturation multiplier
#   value_delta:            float (default 0.0)    — palette brightness delta
#   cloud_coverage_delta:   float (default 0.0)    — lowers cloud thresholds (more clouds)
#   cloud_alpha_delta:      float (default 0.0)    — added to cloud alpha_max
#   biolum_boost:           float (default 0.0)    — added to bioluminescence chance
#   ring_boost:             float (default 0.0)    — added to ring spawn chance
#   glow_boost:             float (default 0.0)    — adds emission to land shader
#   rank_synergy_tag:       String (default "")    — used for trio-synergy rank bonus

const VALID_ARCHETYPES: Array[String] = [
	"LUSH", "DESERT", "FROZEN", "ALPINE", "VOLCANIC", "CANDY", "RADIATED", "ABYSS"
]

const INFLUENCES: Dictionary = {
	# ─── Tier 1 (Common) ─────────────────────────────────────────────
	"Stone": {
		"archetype_votes": {"DESERT": 0.4, "ALPINE": 0.4},
		"terrain_mult": 1.2,
		"rank_synergy_tag": "stone",
	},
	"Wood": {
		"archetype_votes": {"LUSH": 2.0},
		"biolum_boost": 0.15,
		"hue_shift": 0.04,
		"cloud_coverage_delta": 0.1,
		"saturation_mult": 1.05,
		"rank_synergy_tag": "organic",
	},
	"Neon Moss": {
		"archetype_votes": {"CANDY": 1.2, "RADIATED": 1.2},
		"biolum_boost": 0.55,
		"saturation_mult": 1.4,
		"value_delta": 0.10,
		"glow_boost": 0.15,
		"rank_synergy_tag": "luminous",
	},
	"Silica Dust": {
		"archetype_votes": {"DESERT": 2.0},
		"cloud_coverage_delta": -0.2,
		"saturation_mult": 0.7,
		"value_delta": 0.15,
		"noise_freq_mult": 1.4,
		"rank_synergy_tag": "mineral",
	},
	"Carbon Fiber": {
		"archetype_votes": {"ABYSS": 1.0, "VOLCANIC": 1.0},
		"value_delta": -0.25,
		"noise_octaves_delta": 2,
		"terrain_mult": 1.3,
		"saturation_mult": 0.8,
		"rank_synergy_tag": "dark",
	},
	"Organic Sludge": {
		"archetype_votes": {"ABYSS": 2.0},
		"value_delta": -0.20,
		"cloud_coverage_delta": 0.2,
		"cloud_alpha_delta": 0.10,
		"sea_level_delta": -50.0,
		"hue_shift": -0.08,
		"rank_synergy_tag": "organic",
	},
	# ─── Tier 2 (Uncommon) ───────────────────────────────────────────
	"Copper": {
		"archetype_votes": {"DESERT": 1.0, "VOLCANIC": 1.0},
		"hue_shift": 0.05,
		"saturation_mult": 1.3,
		"terrain_mult": 1.4,
		"ring_boost": 0.15,
		"glow_boost": 0.10,
		"rank_synergy_tag": "metallic",
	},
	"Azure Sap": {
		"archetype_votes": {"FROZEN": 1.2, "LUSH": 0.8},
		"hue_shift": -0.10,
		"sea_level_delta": -60.0,
		"cloud_coverage_delta": 0.15,
		"biolum_boost": 0.2,
		"saturation_mult": 1.15,
		"rank_synergy_tag": "organic",
	},
	"Basalt Glass": {
		"archetype_votes": {"VOLCANIC": 1.4, "ALPINE": 0.6},
		"terrain_mult": 1.7,
		"value_delta": -0.15,
		"noise_freq_mult": 1.5,
		"noise_gain_delta": 0.15,
		"rank_synergy_tag": "dark",
	},
	"Silver": {
		"archetype_votes": {"ALPINE": 1.4, "FROZEN": 1.0},
		"value_delta": 0.20,
		"saturation_mult": 0.85,
		"hue_shift": -0.05,
		"ring_boost": 0.20,
		"glow_boost": 0.10,
		"rank_synergy_tag": "metallic",
	},
	"Living Resin": {
		"archetype_votes": {"LUSH": 1.0, "CANDY": 1.0},
		"biolum_boost": 0.4,
		"hue_shift": 0.10,
		"sea_level_delta": -40.0,
		"saturation_mult": 1.2,
		"glow_boost": 0.15,
		"rank_synergy_tag": "luminous",
	},
	# ─── Tier 3 (Rare) ───────────────────────────────────────────────
	"Gold": {
		"archetype_votes": {"DESERT": 1.5, "VOLCANIC": 1.0},
		"hue_shift": 0.08,
		"saturation_mult": 1.5,
		"value_delta": 0.10,
		"glow_boost": 0.40,
		"ring_boost": 0.40,
		"rank_synergy_tag": "metallic",
	},
	"Platinum": {
		"archetype_votes": {"RADIATED": 1.2, "ALPINE": 1.0},
		"value_delta": 0.25,
		"saturation_mult": 1.3,
		"cloud_alpha_delta": 0.15,
		"glow_boost": 0.25,
		"ring_boost": 0.25,
		"rank_synergy_tag": "metallic",
	},
	"Primal Fruit": {
		"archetype_votes": {"CANDY": 2.0, "LUSH": 1.0},
		"biolum_boost": 0.65,
		"hue_shift": 0.20,
		"sea_level_delta": -50.0,
		"saturation_mult": 1.4,
		"glow_boost": 0.20,
		"rank_synergy_tag": "luminous",
	},
	# ─── Tier 4 (Crafted-only, extreme) ──────────────────────────────
	"Prismatic Alloy": {
		"archetype_votes": {
			"LUSH": 1.0, "DESERT": 1.0, "FROZEN": 1.0, "ALPINE": 1.0,
			"VOLCANIC": 1.0, "CANDY": 1.0, "RADIATED": 1.0, "ABYSS": 1.0
		},
		"saturation_mult": 1.6,
		"glow_boost": 0.60,
		"cloud_alpha_delta": 0.25,
		"ring_boost": 0.50,
		"biolum_boost": 0.50,
		"noise_octaves_delta": 2,
		"rank_synergy_tag": "exotic",
	},
	"Nebula Core": {
		"archetype_votes": {"RADIATED": 1.5, "ABYSS": 1.5, "CANDY": 1.0},
		"value_delta": -0.30,
		"glow_boost": 0.60,
		"cloud_alpha_delta": 0.30,
		"cloud_coverage_delta": 0.15,
		"ring_boost": 0.70,
		"biolum_boost": 0.85,
		"noise_octaves_delta": 3,
		"saturation_mult": 1.4,
		"rank_synergy_tag": "exotic",
	},
}

# Neutral defaults — applied when a mineral is missing fields or unknown.
const NEUTRAL_INFLUENCE: Dictionary = {
	"archetype_votes": {},
	"terrain_mult": 1.0,
	"noise_freq_mult": 1.0,
	"noise_octaves_delta": 0,
	"noise_gain_delta": 0.0,
	"sea_level_delta": 0.0,
	"hue_shift": 0.0,
	"saturation_mult": 1.0,
	"value_delta": 0.0,
	"cloud_coverage_delta": 0.0,
	"cloud_alpha_delta": 0.0,
	"biolum_boost": 0.0,
	"ring_boost": 0.0,
	"glow_boost": 0.0,
	"rank_synergy_tag": "",
}

static func get_influence(mineral_name: String) -> Dictionary:
	var entry: Dictionary = INFLUENCES.get(mineral_name, {})
	# Merge over neutral defaults so callers can rely on every field existing.
	var out: Dictionary = NEUTRAL_INFLUENCE.duplicate(true)
	for k in entry.keys():
		out[k] = entry[k]
	return out

# Combine three mineral influences into a single PlanetProfile.
# - archetype_votes: summed per archetype
# - all *_mult fields: multiplied
# - all *_delta and *_boost fields: summed
# - hue_shift: summed then wrapped at apply-time
# - rank_synergy_tag: not in profile (used separately by rank calc)
static func combine(r1: String, r2: String, r3: String) -> Dictionary:
	var inf := [get_influence(r1), get_influence(r2), get_influence(r3)]
	var profile: Dictionary = {
		"archetype_votes": {},
		"terrain_mult": 1.0,
		"noise_freq_mult": 1.0,
		"noise_octaves_delta": 0,
		"noise_gain_delta": 0.0,
		"sea_level_delta": 0.0,
		"hue_shift": 0.0,
		"saturation_mult": 1.0,
		"value_delta": 0.0,
		"cloud_coverage_delta": 0.0,
		"cloud_alpha_delta": 0.0,
		"biolum_boost": 0.0,
		"ring_boost": 0.0,
		"glow_boost": 0.0,
		"archetype": "",        # resolved by pick_archetype
		"ingredients": [r1, r2, r3],
	}

	for i in inf:
		var votes: Dictionary = i["archetype_votes"]
		for k in votes.keys():
			profile["archetype_votes"][k] = profile["archetype_votes"].get(k, 0.0) + float(votes[k])
		profile["terrain_mult"] *= float(i["terrain_mult"])
		profile["noise_freq_mult"] *= float(i["noise_freq_mult"])
		profile["saturation_mult"] *= float(i["saturation_mult"])
		profile["noise_octaves_delta"] += int(i["noise_octaves_delta"])
		profile["noise_gain_delta"] += float(i["noise_gain_delta"])
		profile["sea_level_delta"] += float(i["sea_level_delta"])
		profile["hue_shift"] += float(i["hue_shift"])
		profile["value_delta"] += float(i["value_delta"])
		profile["cloud_coverage_delta"] += float(i["cloud_coverage_delta"])
		profile["cloud_alpha_delta"] += float(i["cloud_alpha_delta"])
		profile["biolum_boost"] += float(i["biolum_boost"])
		profile["ring_boost"] += float(i["ring_boost"])
		profile["glow_boost"] += float(i["glow_boost"])

	# Clamp combined fields to plausible engine ranges so stacked extremes stay sane.
	profile["terrain_mult"] = clampf(profile["terrain_mult"], 0.3, 4.5)
	profile["noise_freq_mult"] = clampf(profile["noise_freq_mult"], 0.4, 3.0)
	profile["noise_octaves_delta"] = clampi(profile["noise_octaves_delta"], -3, 6)
	profile["noise_gain_delta"] = clampf(profile["noise_gain_delta"], -0.3, 0.45)
	profile["sea_level_delta"] = clampf(profile["sea_level_delta"], -200.0, 200.0)
	profile["hue_shift"] = fposmod(profile["hue_shift"], 1.0)
	profile["saturation_mult"] = clampf(profile["saturation_mult"], 0.3, 2.5)
	profile["value_delta"] = clampf(profile["value_delta"], -0.6, 0.6)
	profile["cloud_coverage_delta"] = clampf(profile["cloud_coverage_delta"], -0.4, 0.4)
	profile["cloud_alpha_delta"] = clampf(profile["cloud_alpha_delta"], -0.5, 0.6)
	profile["biolum_boost"] = clampf(profile["biolum_boost"], -0.5, 1.5)
	profile["ring_boost"] = clampf(profile["ring_boost"], 0.0, 1.5)
	profile["glow_boost"] = clampf(profile["glow_boost"], 0.0, 1.5)
	return profile

# Deterministic archetype pick based on summed votes. Seed used only for ties.
static func pick_archetype(profile: Dictionary, seed_val: int) -> String:
	var votes: Dictionary = profile.get("archetype_votes", {})
	if votes.is_empty():
		# All three minerals were neutral — fall back to seeded hash.
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_val & 0x7FFFFFFF
		return VALID_ARCHETYPES[rng.randi() % VALID_ARCHETYPES.size()]

	var top_score: float = -INF
	var top_archetypes: Array[String] = []
	for arch in VALID_ARCHETYPES:
		var v: float = float(votes.get(arch, 0.0))
		if v > top_score:
			top_score = v
			top_archetypes = [arch]
		elif is_equal_approx(v, top_score):
			top_archetypes.append(arch)

	if top_archetypes.size() == 1 or top_score <= 0.0:
		if top_score <= 0.0:
			# No archetype scored positive — degrade to seeded fallback.
			var rng := RandomNumberGenerator.new()
			rng.seed = seed_val & 0x7FFFFFFF
			return VALID_ARCHETYPES[rng.randi() % VALID_ARCHETYPES.size()]
		return top_archetypes[0]

	# Deterministic tie-break via seed.
	var tie_rng := RandomNumberGenerator.new()
	tie_rng.seed = seed_val & 0x7FFFFFFF
	return top_archetypes[tie_rng.randi() % top_archetypes.size()]

# Returns the rank_synergy_tag string for a mineral (empty if none).
static func get_synergy_tag(mineral_name: String) -> String:
	var entry: Dictionary = INFLUENCES.get(mineral_name, {})
	return String(entry.get("rank_synergy_tag", ""))
