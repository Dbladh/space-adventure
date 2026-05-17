class_name ResourceRegistry

# ResourceRegistry.gd — single source of truth for all resource data.
# Matches the Space Game Resource & Crafting Ledger exactly.
# 5-tier rarity: Grey → Green → Blue → Purple → Orange. Orange (T5) is
# mineable on S/SS planets at low rates; lower tiers are increasingly common.

const RESOURCES: Array[Dictionary] = [
	# Tier 1 — Common (Grey)
	{name="Stone",           tier=1, rtype="Mineral",   value=15,   abbrev="St", color=Color(0.55, 0.52, 0.48)},
	{name="Wood",            tier=1, rtype="Organic",   value=15,   abbrev="Wd", color=Color(0.42, 0.26, 0.10)},
	{name="Neon Moss",       tier=1, rtype="Organic",   value=15,   abbrev="NM", color=Color(0.10, 0.90, 0.25)},
	{name="Silica Dust",     tier=1, rtype="Mineral",   value=15,   abbrev="Si", color=Color(0.88, 0.82, 0.62)},
	{name="Carbon Fiber",    tier=1, rtype="Organic",   value=20,   abbrev="CF", color=Color(0.20, 0.20, 0.22)},
	{name="Organic Sludge",  tier=1, rtype="Organic",   value=10,   abbrev="Sl", color=Color(0.35, 0.45, 0.15)},
	# Tier 2 — Uncommon (Green)
	{name="Verdant Spore",   tier=2, rtype="Organic",   value=25,   abbrev="Vs", color=Color(0.50, 0.95, 0.40)},
	{name="Chloro Crystal",  tier=2, rtype="Mineral",   value=30,   abbrev="Cc", color=Color(0.35, 0.85, 0.45)},
	{name="Bloomstone",      tier=2, rtype="Mineral",   value=28,   abbrev="Bs", color=Color(0.55, 0.85, 0.35)},
	# Tier 3 — Rare (Blue)
	{name="Copper",          tier=3, rtype="Metallic",  value=35,   abbrev="Cu", color=Color(0.72, 0.33, 0.15)},
	{name="Azure Sap",       tier=3, rtype="Liquid",    value=65,   abbrev="AS", color=Color(0.10, 0.48, 0.92)},
	{name="Basalt Glass",    tier=3, rtype="Mineral",   value=70,   abbrev="BG", color=Color(0.12, 0.10, 0.18)},
	{name="Silver",          tier=3, rtype="Metallic",  value=100,  abbrev="Ag", color=Color(0.75, 0.75, 0.82)},
	{name="Living Resin",    tier=3, rtype="Organic",   value=90,   abbrev="LR", color=Color(0.95, 0.65, 0.10)},
	# Tier 4 — Epic (Purple)
	{name="Gold",            tier=4, rtype="Metallic",  value=250,  abbrev="Au", color=Color(1.00, 0.70, 0.00)},
	{name="Platinum",        tier=4, rtype="Metallic",  value=500,  abbrev="Pt", color=Color(0.82, 0.88, 0.95)},
	{name="Primal Fruit",    tier=4, rtype="Organic",   value=450,  abbrev="PF", color=Color(1.00, 0.20, 0.40)},
	# Sky-isle exclusive — only spawns on floating islands of SKY_ISLES
	# archetypes. Excluded from the natural surface pool below.
	{name="Aether Crystal",  tier=4, rtype="Mineral",   value=700,  abbrev="Ae", color=Color(0.45, 0.85, 1.00), sky_only=true},
	# Tier 5 — Legendary (Orange) — mineable on S/SS planets at low rates
	{name="Prismatic Alloy", tier=5, rtype="Synthetic", value=1200, abbrev="PA", color=Color(0.80, 0.40, 1.00)},
	{name="Nebula Core",     tier=5, rtype="Synthetic", value=2500, abbrev="NC", color=Color(0.25, 0.80, 1.00)},
]

# Populated on first access
static var _by_name: Dictionary = {}

static func _ensure_index() -> void:
	if not _by_name.is_empty(): return
	for r in RESOURCES:
		_by_name[r.name] = r

static func get_data(res_name: String) -> Dictionary:
	_ensure_index()
	return _by_name.get(res_name, {})

static func get_tier(res_name: String) -> int:
	return get_data(res_name).get("tier", 1)

static func get_value(res_name: String) -> int:
	return get_data(res_name).get("value", 5)

# Per-tier buy markup applied on top of sell value. Sell prices stay low so the
# player can't easily farm credits by re-buying; buy prices are an expensive
# emergency safety valve for missing minerals.
const TIER_BUY_MARKUP: Dictionary = {1: 150, 2: 125, 3: 100, 4: 80, 5: 100}

static func get_buy_price(res_name: String) -> int:
	var data := get_data(res_name)
	var tier: int = int(data.get("tier", 1))
	var value: int = int(data.get("value", 5))
	return value * int(TIER_BUY_MARKUP.get(tier, 100))

static func get_color(res_name: String) -> Color:
	return get_data(res_name).get("color", Color.WHITE)

static func get_abbrev(res_name: String) -> String:
	return get_data(res_name).get("abbrev", "??")

static func all_names() -> Array[String]:
	var result: Array[String] = []
	for r in RESOURCES:
		result.append(r.name)
	return result

# All resources that can appear naturally on planets up to max_tier.
# Always excludes Stone and Wood (those are guaranteed separately) and
# sky-only biome exclusives. All tiers 1–5 can appear naturally; the
# planet-rank-driven selector in PlanetSeedKitchen decides composition.
static func natural_pool(max_tier: int) -> Array[String]:
	var result: Array[String] = []
	for r in RESOURCES:
		if r.name == "Stone" or r.name == "Wood": continue
		if r.get("sky_only", false): continue
		if r.tier <= max_tier:
			result.append(r.name)
	return result
