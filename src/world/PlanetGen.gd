extends Node3D

# PlanetGen.gd (Aggressive Horizon Edition)
# Managed by THE ARCHITECT.

var PlanetChunkScript = load("res://src/world/PlanetChunk.gd")

@export var planet_radius: float = 100000.0
@export var terrain_strength: float = 5000.0
@export var max_lod: int = 18
@export var subdivision_bias: float = 1.8
# Each planet must get a unique seed so terrain is distinct per celestial body!
@export var planet_seed: int = 1234
# Phase 3 of LOD rewrite: when true, the new PlanetSurfaceStreamer owns all
# scatter (trees, rocks, grass, minerals).  Chunks render terrain only.  Set
# to false to fall back to the legacy per-chunk SurfacePropProxy pipeline
# (kept around as dead code under this flag for one release in case of regressions).
@export var streamer_enabled: bool = true
var surface_streamer: Node = null
# Resources available to mine on this planet. Set externally before chunks generate.
# Stone and Wood are always present; extras are tier-gated by how the planet was forged.
var planet_resources: Array[String] = ["Stone", "Wood", "Copper"]
# Forge-rank label (F / D / C / B / A / S / SS / ★ LEGENDARY). Set by
# SpaceStation after spawning so chunks/props can vary visuals (e.g. only rare
# A+ planets get glowing flora). Empty = unranked (default starter look).
var planet_rank: String = ""
# Combined per-mineral influence vector from MineralInfluence.combine().
# Set by SpaceStation before add_child(). Empty = neutral (default starter look).
# Fields: archetype, archetype_votes, terrain_mult, noise_freq_mult,
# noise_octaves_delta, noise_gain_delta, sea_level_delta, hue_shift,
# saturation_mult, value_delta, cloud_coverage_delta, cloud_alpha_delta,
# biolum_boost, ring_boost, glow_boost, ingredients.
var planet_profile: Dictionary = {}
var sea_level: float = -120.0

# ATMOSPHERIC IDENTITY
var sky_horizon_color: Color
var sky_zenith_color: Color

# PROCEDURAL PALETTE
var pal_grass_col: Color
var pal_mount_col: Color
var pal_forest_col: Color
var pal_forest_h: float
var pal_grass_secondary: Color
var pal_beach_col: Color
var pal_water_base: Color
var pal_water_light: Color
var pal_water_shore: Color
var archetype: String

var noise: FastNoiseLite
var mobile_perf: bool = false
var faces: Array[QuadTreeFace] = []
var player: Node3D

# TOPOGRAPHY VARIETY: Deterministic terrain style per planet
var terrain_mode: String = "VARIED" # FLAT, HILLY, MOUNTAINOUS, EXTREME
var noise_frequency: float = 600.0
var terrain_multiplier: float = 1.0
var has_bioluminescence: bool = false

# SHARED MATERIALS: Cached per planet to reduce Draw Calls and State Changes
var land_material: ShaderMaterial
var water_material: ShaderMaterial
var foliage_material: ShaderMaterial
var trunk_material: ShaderMaterial
var rock_material: ShaderMaterial
var grass_material: ShaderMaterial

# ACE MEMORY POOLING: Hibernation buffer for QuadTree nodes to prevent GC stutters
var chunk_pool: Array[MeshInstance3D] = []
var continent_pole: Vector3 = Vector3.UP # ACE: Deterministic anchor for the major island

# NMS OPTIMIZATION: Throttle chunk streaming to prevent CPU micro-stutters!
# One split per frame keeps mesh generation within frame budget.
var split_queue: Array[QuadTreeNode] = []
const MAX_SPLITS_PER_FRAME: int = 3
const PROXIMITY_CUTOFF: float = 8000000.0 # ACE: Increased for mission-critical persistence
var impostor: Node3D = null
var faces_hidden: bool = false
var _lod_face_idx: int = 0 # ACE PERFORMANCE: Load-balanced face updates

# ACE POOLING: Chunks that are still generating in the background go here
# instead of the main pool to avoid blocking the main thread.
var zombie_pool: Array[MeshInstance3D] = []
var finalize_queue: Array = []
var death_row: Array[Node] = []
var prop_spawn_queue: Array = [] # ACE: Throttled Prop batches
# ACE PHYSICS: Queue for trimesh collision generation to prevent spikes
var collision_queue: Array[MeshInstance3D] = []
const MAX_COLLISIONS_PER_FRAME: int = 4
var MAX_FINALIZE_PER_FRAME: int = 4
const MAX_DEATHS_PER_FRAME: int = 48
var _prewarm_count: int = 0
var _prewarm_target: int = 32

func _prewarm_one_chunk() -> void:
	var pc = PlanetChunkScript.new()
	pc.setup(self)
	pc.hide()
	zombie_pool.append(pc)
	add_child(pc)



const FACE_NORMALS: Array[Vector3] = [
	Vector3.FORWARD, Vector3.BACK,
	Vector3.LEFT, Vector3.RIGHT,
	Vector3.UP, Vector3.DOWN
]

func _ready() -> void:
	self.add_to_group("Planet")
	self.add_to_group("World")
	print("--- ARCHITECT: Planet [%s] _ready. Parent: %s, Global Pos: %s ---" % [name, get_parent().name if get_parent() else "NONE", str(global_position)])
	mobile_perf = MobilePerf.is_mobile()
	# Mobile QuadTree caps: stop subdividing four levels short of desktop and
	# pull the subdivide-trigger radius in. Cuts worst-case chunk count
	# dramatically during atmosphere entry — the dominant freeze on iPhone 15.
	if mobile_perf:
		max_lod = 14
		subdivision_bias = 1.2
	noise = FastNoiseLite.new()
	_prewarm_target = 32
	# Always use the explicit planet_seed for terrain noise.
	# Main.gd sets unique values (1001, 2002...) before add_child() is called,
	# so _ready() always receives the correct distinct seed per body.
	# NOISE VARIETY: The Geologist
	var geo_rng = RandomNumberGenerator.new()
	geo_rng.seed = planet_seed + 555
	noise.seed = planet_seed
	
	# Randomize noise type for high variety
	var n_types = [FastNoiseLite.TYPE_PERLIN, FastNoiseLite.TYPE_SIMPLEX, FastNoiseLite.TYPE_VALUE]
	noise.noise_type = n_types[geo_rng.randi() % n_types.size()]
	
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 0.01
	noise.fractal_octaves = geo_rng.randi_range(3, 6)
	noise.fractal_lacunarity = geo_rng.randf_range(1.8, 2.4)
	noise.fractal_gain = geo_rng.randf_range(0.3, 0.6)

	# MINERAL INFLUENCE — noise tweaks. Frequency multiplier shifts feature scale,
	# octaves delta adds detail, gain delta changes roughness/persistence.
	var p_noise_freq_mult: float = float(planet_profile.get("noise_freq_mult", 1.0))
	var p_octaves_delta: int = int(planet_profile.get("noise_octaves_delta", 0))
	var p_gain_delta: float = float(planet_profile.get("noise_gain_delta", 0.0))
	noise.frequency = noise.frequency * p_noise_freq_mult
	noise.fractal_octaves = clampi(noise.fractal_octaves + p_octaves_delta, 2, 9)
	noise.fractal_gain = clampf(noise.fractal_gain + p_gain_delta, 0.2, 0.85)
	
	# PROCEDURAL ATMOSPHERE: Unique Sky per Planet!
	# The user requested specific vivid colors: Blue, Red, Orange, Yellow, Green.
	
	var rng = RandomNumberGenerator.new()
	rng.seed = (int(planet_radius) ^ int(terrain_strength * 100.0) ^ (planet_seed * 2654435761)) & 0x7FFFFFFF
	
	# Replicate the exact math used by PlanetChunk to determine the planet's grass color
	# Because we use the exact same formula and PRNG seed, this is 100% accurate per planet.
	var pal_forest_h = rng.randf()
	var grass_hue_offset = 0.5 + rng.randf_range(-0.15, 0.15)
	var grass_hue = fposmod(pal_forest_h + grass_hue_offset, 1.0)
	
	# Mapping allowed colors to hues: Red (0.0/1.0), Orange (0.08), Yellow (0.15), Green (0.33), Blue (0.6)
	var allowed_hues = [0.0, 0.08, 0.15, 0.33, 0.6]
	
	# DYNAMIC CHROMA SYNC: Force sky hue to be complementary (180deg shift) from the forest floor
	# This ensures the exosphere definitively contrasts against the dominant ground color.
	var complementary_hue = fposmod(pal_forest_h + 0.5, 1.0)
	
	# Select the closest allowed hue to the complementary target
	var base_hue = allowed_hues[0]
	var min_diff = 1.0
	for h in allowed_hues:
		var diff = abs(h - complementary_hue)
		if diff > 0.5: diff = 1.0 - diff
		if diff < min_diff:
			min_diff = diff
			base_hue = h
			
	# Horizon uses the dynamic, complementary planetary hue (e.g. Aqua, Yellow, Orange)
	# Increased saturation for a more vivid atmospheric look
	sky_horizon_color = Color.from_hsv(base_hue, 0.85, 1.0)
	
	# Zenith ALWAYS forces a deep blue to ensure every sky is a stunning sunset!
	sky_zenith_color = Color.from_hsv(0.62, 0.75, 0.35)
	
	# ARCHETYPE SYSTEM — THE COSMOLOGIST
	# Tier-gated archetype pools. Forge rank dictates visual band:
	#   F/D = drab rocky worlds (browns, greys, tans)
	#   C/B = vibrant living worlds (greens, yellows, oranges, purples, pinks)
	#   A/S/SS/★ = standout (lava, ice, iridescent, crystal, aurora, sky-isles)
	# Unranked planets (legacy/starter) draw from a wide variety pool that
	# excludes the deliberately-drab F/D archetypes and the rare SS+
	# exclusives.
	#
	# MINERAL INFLUENCE wins when a planet_profile supplies an archetype —
	# the ingredient trio's weighted vote is the player's explicit intent,
	# so respect it even if the tier pool doesn't list it.  Tier gating
	# only applies when no profile-driven archetype is available (legacy
	# / un-forged planets).
	var TIER_POOLS := {
		"F":           ["BARREN", "ASH", "MUDFLAT"],
		"D":           ["DESERT", "RUST", "BARREN", "ASH"],
		"C":           ["LUSH", "SAVANNA", "SULFUR", "CORAL"],
		"B":           ["JUNGLE", "CANDY", "TOXIC", "AMETHYST"],
		"A":           ["VOLCANIC", "FROZEN", "ALPINE", "OBSIDIAN", "ABYSS"],
		"S":           ["RADIATED", "CRYSTAL", "AURORA", "SKY_ISLES"],
		"SS":          ["IRIDESCENT", "SKY_ISLES", "CRYSTAL"],
		"★ LEGENDARY": ["IRIDESCENT", "SKY_ISLES", "CRYSTAL", "AURORA"],
	}
	const UNRANKED_POOL := [
		"LUSH", "DESERT", "FROZEN", "ALPINE", "VOLCANIC", "CANDY", "RADIATED", "ABYSS",
		"SAVANNA", "JUNGLE", "AMETHYST", "CORAL",
	]
	var pal_rng = RandomNumberGenerator.new()
	pal_rng.seed = hash(str(name) + str(planet_radius) + str(planet_seed)) & 0x7FFFFFFF
	var theme: String
	var profile_arch: String = String(planet_profile.get("archetype", "")) if planet_profile != null else ""
	if profile_arch != "":
		# Forged-with-minerals path: the trio's weighted vote wins.
		theme = profile_arch
	else:
		var pool: Array
		if planet_rank == "":
			pool = UNRANKED_POOL
		else:
			pool = TIER_POOLS.get(planet_rank, UNRANKED_POOL)
		theme = pool[pal_rng.randi() % pool.size()]
	self.archetype = theme
	
	# SEA LEVEL RANDOMIZATION: The Hydrologist
	var hydro_rng = RandomNumberGenerator.new()
	hydro_rng.seed = planet_seed + 123
	# Range from -250 (shallow/scattered) to -50 (deep/continental)
	sea_level = hydro_rng.randf_range(-250.0, -50.0)
	# MINERAL INFLUENCE — push sea level deeper or shallower. Negative delta = more water.
	sea_level = clampf(sea_level + float(planet_profile.get("sea_level_delta", 0.0)), -330.0, 30.0)
	
	# TOPOGRAPHY DIVERSIFICATION: The Cartographer
	# We randomize how 'aggressive' the terrain is based on a separate roll.
	# Tier biases the roll: F/D worlds skew flatter (drab feel), A/S/SS skew
	# toward MOUNTAINOUS/EXTREME (so legendary planets are visibly dramatic).
	var topo_rng = RandomNumberGenerator.new()
	topo_rng.seed = hash(str(planet_seed) + "topo") & 0x7FFFFFFF
	var topo_bias: float = _tier_topo_bias(planet_rank)
	var topo_roll: float = clampf(topo_rng.randf() + topo_bias, 0.0, 1.0)

	if topo_roll > 0.9:
		terrain_mode = "EXTREME"
		terrain_multiplier = 1.8
		noise_frequency = 800.0
	elif topo_roll > 0.65:
		terrain_mode = "MOUNTAINOUS"
		terrain_multiplier = 1.2
		noise_frequency = 600.0
	elif topo_roll > 0.3:
		terrain_mode = "HILLY"
		terrain_multiplier = 0.6
		noise_frequency = 400.0
	else:
		terrain_mode = "FLAT"
		terrain_multiplier = 0.25
		noise_frequency = 300.0

	# ACE: Global scale correction for small planets (100km range)
	# We scale strength linearly with radius to prevent the 'spikey' look.
	# Drama multiplier on top scales mountain HEIGHT directly with tier — an
	# S-tier MOUNTAINOUS planet will tower well over a C-tier MOUNTAINOUS one.
	var scale_fix = planet_radius / 180000.0
	var tier_drama: float = _tier_drama_scale(planet_rank)
	terrain_strength = 2800.0 * scale_fix * terrain_multiplier * tier_drama
	# MINERAL INFLUENCE — bold trio (e.g. 3× Basalt Glass) can further push
	# terrain past the rank-tier ceiling.
	terrain_strength *= float(planet_profile.get("terrain_mult", 1.0))

	# BIOLUMINESCENCE ROLL: The Exobiologist
	# Glow is archetype-driven so the player reads it as a tier signal:
	#   * S/SS exclusives glow always (CRYSTAL, AURORA, IRIDESCENT, SKY_ISLES, RADIATED)
	#   * Vibrant C/B types glow ~30% (CANDY, JUNGLE, CORAL, SULFUR)
	#   * Drab F/D worlds never glow (would muddle the "dead rock" read)
	#   * Anything else gets a 5% easter-egg chance.
	# MINERAL INFLUENCE adds biolum_boost on top of the archetype base, except
	# for never-glow archetypes where the dead-rock read is intentional.
	var always_bio := ["RADIATED", "CRYSTAL", "AURORA", "IRIDESCENT", "SKY_ISLES"]
	var often_bio := ["CANDY", "JUNGLE", "CORAL", "SULFUR"]
	var never_bio := ["BARREN", "ASH", "MUDFLAT", "DESERT", "RUST"]
	var biolum_boost: float = float(planet_profile.get("biolum_boost", 0.0))
	if archetype in always_bio:
		has_bioluminescence = true
	elif archetype in never_bio:
		has_bioluminescence = false
	elif archetype in often_bio:
		has_bioluminescence = hydro_rng.randf() < clampf(0.30 + biolum_boost, 0.0, 1.0)
	else:
		has_bioluminescence = hydro_rng.randf() < clampf(0.05 + biolum_boost, 0.0, 1.0)

	print("--- CARTOGRAPHER: Planet [%s] Type: [%s] Rank: [%s] Topo: [%s] Bio: [%s] ---" % [name, archetype, planet_rank, terrain_mode, str(has_bioluminescence)])

	# INITIALIZE SHARED MATERIALS: at the end so trait rolls (Bio / Archetype)
	# are baked in before shaders read them.
	_init_shared_materials()


	match theme:
		"LUSH":
			var h = pal_rng.randf_range(0.28, 0.42)
			pal_grass_col = Color.from_hsv(h, 0.65, 0.85)
			pal_mount_col = Color.from_hsv(pal_rng.randf_range(0.05, 0.15), 0.3, 0.5)
			pal_water_base = Color.from_hsv(0.55, 0.75, 0.8)
		"DESERT":
			var h = pal_rng.randf_range(0.02, 0.15)
			pal_grass_col = Color.from_hsv(h, 0.7, 0.9)
			pal_mount_col = Color.from_hsv(h, 0.4, 0.6)
			pal_water_base = Color.from_hsv(0.05, 0.9, 0.4) 
		"FROZEN":
			var h = pal_rng.randf_range(0.5, 0.65)
			pal_grass_col = Color.from_hsv(h, 0.15, 0.95)
			pal_mount_col = Color.from_hsv(h+0.1, 0.4, 0.6)
			pal_water_base = Color.from_hsv(0.6, 0.5, 0.9)
		"TOXIC":
			var h = pal_rng.randf_range(0.18, 0.28)
			pal_grass_col = Color.from_hsv(h, 0.85, 0.9)
			pal_mount_col = Color.from_hsv(0.8, 0.5, 0.4)
			pal_water_base = Color.from_hsv(h+0.2, 0.85, 0.7)
		"ALPINE":
			var h = pal_rng.randf_range(0.58, 0.62)
			pal_grass_col = Color.from_hsv(h, 0.15, 0.98) # Snow
			pal_mount_col = Color.from_hsv(h, 0.4, 0.45)  # Blue Grey Stone
			pal_water_base = Color.from_hsv(0.6, 0.8, 0.9) # Clear Blue Ice-Water
		"VOLCANIC":
			pal_grass_col = Color.from_hsv(0.0, 0.9, 0.5)
			pal_mount_col = Color.from_hsv(0, 0.0, 0.15)
			pal_water_base = Color.from_hsv(0.0, 1.0, 0.45) 
		"CANDY":
			var h = pal_rng.randf_range(0.85, 0.98)
			pal_grass_col = Color.from_hsv(h, 0.45, 0.95)
			pal_mount_col = Color.from_hsv(h, 0.25, 0.7)
			pal_water_base = Color.from_hsv(0.5, 0.4, 0.9)
		"RADIATED":
			var h = pal_rng.randf_range(0.65, 0.8)
			pal_grass_col = Color.from_hsv(h, 0.8, 0.9)
			pal_mount_col = Color.from_hsv(h, 0.3, 0.4)
			pal_water_base = Color.from_hsv(0.75, 1.0, 1.0)
		"ABYSS":
			pal_grass_col = Color.from_hsv(0.65, 0.8, 0.25)
			pal_mount_col = Color.from_hsv(0.7, 0.5, 0.1)
			pal_water_base = Color.from_hsv(0.65, 0.95, 0.2)
		# ── F-TIER drab rocky worlds ─────────────────────────────────
		"BARREN":
			var h = pal_rng.randf_range(0.0, 0.1)
			pal_grass_col = Color.from_hsv(h, 0.05, 0.55)   # cratered grey dust
			pal_mount_col = Color.from_hsv(0.0, 0.0, 0.4)   # bare rock
			pal_water_base = Color.from_hsv(0.6, 0.1, 0.3)  # dry seabed
		"ASH":
			var h = pal_rng.randf_range(0.02, 0.08)
			pal_grass_col = Color.from_hsv(h, 0.1, 0.28)    # charred soot
			pal_mount_col = Color.from_hsv(h, 0.05, 0.15)   # near-black basalt
			pal_water_base = Color.from_hsv(0.0, 0.0, 0.18) # black tar
		"MUDFLAT":
			var h = pal_rng.randf_range(0.06, 0.11)
			pal_grass_col = Color.from_hsv(h, 0.4, 0.45)    # brown sludge
			pal_mount_col = Color.from_hsv(h, 0.3, 0.3)     # wet rock
			pal_water_base = Color.from_hsv(h, 0.5, 0.35)   # silty water
		# ── D-TIER drab rocky worlds ─────────────────────────────────
		"RUST":
			var h = pal_rng.randf_range(0.02, 0.06)
			pal_grass_col = Color.from_hsv(h, 0.7, 0.55)    # iron-oxide red-brown
			pal_mount_col = Color.from_hsv(h, 0.5, 0.3)     # darker rust
			pal_water_base = Color.from_hsv(0.05, 0.85, 0.35) # blood-red brine
		# ── C-TIER vibrant worlds ────────────────────────────────────
		"SAVANNA":
			var h = pal_rng.randf_range(0.13, 0.16)
			pal_grass_col = Color.from_hsv(h, 0.55, 0.85)   # ochre grasslands
			pal_mount_col = Color.from_hsv(0.08, 0.4, 0.5)  # dry tan rock
			pal_water_base = Color.from_hsv(0.55, 0.6, 0.7) # warm shallow blue
		"SULFUR":
			pal_grass_col = Color.from_hsv(0.14, 0.95, 0.95)  # bright yellow
			pal_mount_col = Color.from_hsv(0.08, 0.7, 0.55)   # orange rock
			pal_water_base = Color.from_hsv(0.06, 0.95, 0.7)  # acid orange pools
		"CORAL":
			var h = pal_rng.randf_range(0.02, 0.06)
			pal_grass_col = Color.from_hsv(h, 0.7, 0.95)    # coral orange
			pal_mount_col = Color.from_hsv(h+0.02, 0.5, 0.55)
			pal_water_base = Color.from_hsv(0.48, 0.7, 0.85) # vivid teal
		# ── B-TIER vibrant worlds ────────────────────────────────────
		"JUNGLE":
			pal_grass_col = Color.from_hsv(0.32, 0.9, 0.7)    # saturated emerald
			pal_mount_col = Color.from_hsv(0.28, 0.45, 0.4)
			pal_water_base = Color.from_hsv(0.42, 0.85, 0.45) # deep green river
		"AMETHYST":
			var h = pal_rng.randf_range(0.74, 0.82)
			pal_grass_col = Color.from_hsv(h, 0.6, 0.7)
			pal_mount_col = Color.from_hsv(h, 0.7, 0.45)    # purple rock
			pal_water_base = Color.from_hsv(h+0.04, 0.7, 0.5) # violet sea
		# ── A-TIER show-stoppers ─────────────────────────────────────
		"OBSIDIAN":
			pal_grass_col = Color.from_hsv(0.0, 0.0, 0.08)    # black glass
			pal_mount_col = Color.from_hsv(0.0, 0.0, 0.04)
			pal_water_base = Color.from_hsv(0.02, 1.0, 0.6)   # crimson lava
		# ── S-TIER show-stoppers ─────────────────────────────────────
		"CRYSTAL":
			# Multi-hue saturated palette — emission uniform pulses on top.
			var h = pal_rng.randf_range(0.0, 1.0)
			pal_grass_col = Color.from_hsv(h, 0.85, 0.85)     # gem face
			pal_mount_col = Color.from_hsv(fposmod(h+0.5, 1.0), 0.85, 0.55)  # complementary cluster
			pal_water_base = Color.from_hsv(fposmod(h+0.25, 1.0), 0.7, 0.7)
		"AURORA":
			# ALPINE-like base — aurora ring overrides the sky tone.
			var h = pal_rng.randf_range(0.55, 0.65)
			pal_grass_col = Color.from_hsv(h, 0.2, 0.95)      # snow with cool tint
			pal_mount_col = Color.from_hsv(h, 0.5, 0.4)
			pal_water_base = Color.from_hsv(h, 0.7, 0.85)
		"SKY_ISLES":
			# Vibrant green/teal terrain that floating islands match.
			var h = pal_rng.randf_range(0.35, 0.45)
			pal_grass_col = Color.from_hsv(h, 0.75, 0.85)
			pal_mount_col = Color.from_hsv(h-0.02, 0.5, 0.5)
			pal_water_base = Color.from_hsv(h+0.05, 0.65, 0.85)
		# ── SS / ★ LEGENDARY show-stopper ────────────────────────────
		"IRIDESCENT":
			# Neutral mid-tone base — iridescence shader uniform paints rainbow on top.
			pal_grass_col = Color.from_hsv(0.5, 0.15, 0.65)
			pal_mount_col = Color.from_hsv(0.5, 0.1, 0.45)
			pal_water_base = Color.from_hsv(0.6, 0.4, 0.7)

	# GENERATE SECONDARY COLOR PALETTE
	# Using explicit derivations to ensure complementary colors
	pal_forest_col = pal_grass_col.darkened(0.2)
	pal_grass_secondary = pal_grass_col.lightened(0.12)
	pal_beach_col = pal_grass_col.lightened(0.25).lerp(pal_mount_col, 0.4)
	pal_water_light = pal_water_base.lightened(0.15)
	pal_water_shore = pal_water_base.lightened(0.3).lerp(pal_grass_col, 0.2)

	# MINERAL INFLUENCE — apply HSV shifts to every palette colour.
	# hue_shift wraps; saturation_mult scales; value_delta brightens/darkens.
	pal_grass_col       = _apply_palette_shift(pal_grass_col)
	pal_mount_col       = _apply_palette_shift(pal_mount_col)
	pal_water_base      = _apply_palette_shift(pal_water_base)
	pal_forest_col      = _apply_palette_shift(pal_forest_col)
	pal_grass_secondary = _apply_palette_shift(pal_grass_secondary)
	pal_beach_col       = _apply_palette_shift(pal_beach_col)
	pal_water_light     = _apply_palette_shift(pal_water_light)
	pal_water_shore     = _apply_palette_shift(pal_water_shore)

	base_hue = pal_grass_col.h
	self.pal_forest_h = base_hue # Seed for tree variety

	# INITIALIZE SHARED MATERIALS — must run AFTER the palette and archetype are
	# rolled so the land/water shaders pick up the right colours and the new
	# archetype-driven uniforms (iridescence, snow-spec, crystal emission, lava).
	_init_shared_materials()

	print("--- ARCHITECT: Planet [%s] Initialized. Theme: %s (Radius: %d) ---" % [name, theme, planet_radius])
	
	# MAJOR CONTINENT ARCHITECT: Every planet gets one iconic, massive landmass
	var c_rng = RandomNumberGenerator.new(); c_rng.seed = planet_seed + 999
	continent_pole = Vector3(c_rng.randf_range(-1,1), c_rng.randf_range(-1,1), c_rng.randf_range(-1,1)).normalized()
	
	for i in range(6):
		var face = QuadTreeFace.new(self, FACE_NORMALS[i])
		faces.append(face)
		add_child(face)

	# Stand up the cell streamer.  When streamer_enabled is true, chunks
	# render terrain only and the streamer owns scatter lifecycle atomically.
	if streamer_enabled:
		var streamer_script: GDScript = load("res://src/world/streaming/PlanetSurfaceStreamer.gd") as GDScript
		if streamer_script != null:
			surface_streamer = streamer_script.new()
			surface_streamer.name = "PlanetSurfaceStreamer"
			add_child(surface_streamer)
	# ACE: Inject majestic cloud belts and celestial rings — visible against the charcoal void
	_spawn_majestic_clouds_and_rings(rng, base_hue)
	# ACE: Scatter colossal Hero Landmarks as navigation anchors across the planet surface
	_spawn_hero_landmarks(rng)
	# S-tier exclusive: floating sky-islands ringing the planet.
	if archetype == "SKY_ISLES":
		_spawn_sky_isles(rng)
	# Per-planet POI beacon disabled — the off-axis pillar wasn't useful as a
	# navigation aid (it pointed at +Y pole, not the player) and rendered as
	# stray geometry through transparent water/lava surfaces. Stations keep
	# their POIMarker (spawned from Main.gd) since those are real landmarks
	# the player can dock at.
	# _spawn_poi_marker()
	# print("--- ARCHITECT: PLANET [%s] SYNCHRONIZED (terrain_seed=%d) ---" % [name, noise.seed])

# MINERAL INFLUENCE: apply hue/saturation/value shifts from the planet_profile.
# Hue wraps, saturation multiplies, value adds — all clamped to legal [0,1].
func _apply_palette_shift(c: Color) -> Color:
	var hue_shift: float = float(planet_profile.get("hue_shift", 0.0))
	var sat_mult: float = float(planet_profile.get("saturation_mult", 1.0))
	var val_delta: float = float(planet_profile.get("value_delta", 0.0))
	if is_equal_approx(hue_shift, 0.0) and is_equal_approx(sat_mult, 1.0) and is_equal_approx(val_delta, 0.0):
		return c
	var h: float = fposmod(c.h + hue_shift, 1.0)
	var s: float = clampf(c.s * sat_mult, 0.0, 1.0)
	var v: float = clampf(c.v + val_delta, 0.0, 1.0)
	return Color.from_hsv(h, s, v, c.a)

func get_terrain_height_at(pos: Vector3) -> float:
	var sphere_norm: Vector3 = (pos - global_position).normalized()
	# Macro frequency is per-planet topography (FLAT=300..EXTREME=800). Hardcoding 500
	# here placed hero landmarks at an estimated surface height that didn't match the
	# actual rendered terrain on 75% of planets.
	var macro_h: float = noise.get_noise_3dv(sphere_norm * noise_frequency)
	var micro_crag: float = noise.get_noise_3dv(sphere_norm * 15000.0) * 0.1
	var total_h: float = 0.0

	match archetype:
		"DESERT", "RUST":
			# MESAS & CANYONS: Sharp transitions between flat high-ground and flat low-ground
			var mesa = smoothstep(-0.1, 0.1, macro_h) * 2.0 - 1.0
			total_h = (mesa * 0.6 + micro_crag) * terrain_strength * 0.7
		"VOLCANIC", "ABYSS", "OBSIDIAN":
			# JAGGED RIDGES: Extreme peaks and deep, sharp ravines using 'Ridge Noise' (1.0 - abs(noise))
			var jagged = 1.0 - abs(macro_h * 1.5)
			total_h = (jagged * 2.0 - 0.8 + micro_crag * 2.5) * terrain_strength * 1.4
		"FROZEN":
			# GLACIAL PLAINS: Smooth, sweeping drifts punctuated by sudden, violent ice spikes
			var plains = macro_h * 0.4
			var spikes = max(0.0, noise.get_noise_3dv(sphere_norm * 2500.0) - 0.65) * 6.0
			total_h = (plains + spikes + micro_crag * 0.4) * terrain_strength
		"TOXIC", "RADIATED", "SULFUR":
			# POCKMARKED WASTELAND: Heavily cratered and unnatural, chaotic frequency
			var craters = abs(noise.get_noise_3dv(sphere_norm * 1200.0))
			var bubbling = noise.get_noise_3dv(sphere_norm * 3000.0) * 0.5
			total_h = (macro_h - craters * 1.8 + bubbling + micro_crag) * terrain_strength * 0.6
		"ALPINE", "AURORA", "CRYSTAL", "AMETHYST":
			# CRAGGY PEAKS: High-frequency ridge noise for dramatic vertical scale
			var ridge = 1.0 - abs(macro_h)
			total_h = (ridge * 2.5 - 0.8 + micro_crag * 1.5) * terrain_strength * 1.5
		"BARREN":
			# CRATERED MOON: Round impact basins on otherwise rolling rock.
			var craters = pow(abs(noise.get_noise_3dv(sphere_norm * 900.0)), 2.5)
			total_h = (macro_h * 0.6 - craters * 1.6 + micro_crag) * terrain_strength * 0.9
		"ASH":
			# DEAD VOLCANIC: Like VOLCANIC but compressed — burnt-out cones rather than tall ridges.
			var jagged = 1.0 - abs(macro_h * 1.2)
			total_h = (jagged * 1.4 - 0.5 + micro_crag * 1.5) * terrain_strength * 0.9
		"MUDFLAT":
			# WET SLUDGE PLAINS: nearly flat with shallow rolling bulges.
			total_h = (macro_h * 0.35 + micro_crag * 0.5) * terrain_strength * 0.45
		"SAVANNA":
			# Open rolling plains with the occasional broad rise.
			var roll = macro_h * 0.8
			var rises = max(0.0, noise.get_noise_3dv(sphere_norm * 1200.0) - 0.4) * 1.6
			total_h = (roll + rises + micro_crag * 0.6) * terrain_strength * 0.85
		"JUNGLE":
			# Deeply terraced river valleys cut between high mesas — the
			# classic "lost world" silhouette: more vertical than LUSH.
			total_h = (macro_h + micro_crag * 1.4) * terrain_strength * 1.25
			# tighter terracing on top of the base for tabletop mesas
			var h_frac = fposmod(total_h, 60.0) / 60.0
			total_h = (floor(total_h / 60.0) + smoothstep(0.10, 0.90, h_frac)) * 60.0
		"CORAL":
			# Submerged reefs and shallow shelves — most of the surface
			# sits just under sea level with isolated coral atolls poking up.
			var reef = max(0.0, noise.get_noise_3dv(sphere_norm * 1800.0) - 0.55) * 4.0
			total_h = (macro_h * 0.45 + reef + micro_crag) * terrain_strength * 0.7
		"SKY_ISLES":
			# Shattered hill country: sharp plateaus with deep rifts that
			# echo the floating islands above.
			var ridge = 1.0 - abs(macro_h)
			total_h = (ridge * 1.6 - 0.4 + micro_crag * 1.8) * terrain_strength * 1.2
		"IRIDESCENT":
			# Smooth oily dunes — minimal sharp features so the shader's
			# rainbow shimmer reads cleanly across broad surfaces.
			total_h = (macro_h * 0.7 + micro_crag * 0.3) * terrain_strength * 0.6
		_:
			# LUSH / CANDY / DEFAULT: The classic 'No Man's Sky' smooth terraced hills
			total_h = (macro_h + micro_crag) * terrain_strength
			var volcanic: float = noise.get_noise_3dv(sphere_norm * 25000.0)
			if volcanic > 0.45: total_h -= 1000.0
			# Stepped Terracing
			var h_frac = fposmod(total_h, 80.0) / 80.0
			total_h = (floor(total_h / 80.0) + smoothstep(0.15, 0.85, h_frac)) * 80.0

	return planet_radius + total_h

func _spawn_majestic_clouds_and_rings(rng: RandomNumberGenerator, base_hue: float) -> void:
	# 1. PUFFY CLOUD BELTS: Massive celestial sphere at 2.5km altitude (Hugging closer)
	var c_mesh = SphereMesh.new(); c_mesh.radius = planet_radius + 2500.0; c_mesh.height = c_mesh.radius * 2.0
	c_mesh.radial_segments = 64; c_mesh.rings = 32
	var c_shader = Shader.new(); c_shader.code = """shader_type spatial; render_mode unshaded, blend_mix, cull_disabled;
	// depth_draw_always removed: previously the cloud layer wrote depth even
	// for partially-transparent fragments, which caused alpha-blended cloud
	// pixels to occlude the terrain & ship behind them in the same frame.
	uniform vec3 sun_dir;
	uniform vec3 horizon_color;
	uniform float planet_r;
	// Per-planet variation knobs:
	//   cell_scale  — drives blob size. Smaller = more cells per planet
	//                 (small dense puffs); larger = fewer big blobs.
	//   thresh_lo   — smoothstep lower edge for coverage. Lower value
	//                 means more density passes the gate (overcast).
	//   thresh_hi   — smoothstep upper edge. We keep a 0.20 band width
	//                 so feather softness stays consistent across planets.
	//   alpha_max   — peak per-fragment alpha; thicker for very dense
	//                 worlds, thinner for hazy ones.
	uniform float cell_scale = 0.005;
	uniform float thresh_lo  = 0.55;
	uniform float thresh_hi  = 0.78;
	uniform float alpha_max  = 0.70;
	// Unique 3D offset per cloud layer so stacked shells don't sample the
	// same noise pattern. Without this, every shell renders identical clouds
	// and the stack reads as one slab instead of multiple altitudes.
	uniform vec3  layer_offset = vec3(0.0);
	// Per-layer wind: drift velocity of the noise sample position. Each
	// shell gets its own value so high cirrus and low cumulus move in
	// different directions and at different speeds — parallax through the
	// stack reads as real cloud motion. Default matches the legacy
	// hard-coded direction so the single-shell variant looks unchanged.
	uniform vec3  wind_velocity = vec3(0.6, 0.3, -0.2);
	// Domain warping: a slow low-freq fbm distorts the sample position so
	// the noise field itself deforms over time — clouds curl, tendrils
	// evolve, edges drift independently of the bulk wind translation.
	// Cost = 2 extra fbm() calls per density sample. Set to 0.0 to skip
	// (mobile path) — the GPU branches on a uniform, so it's effectively
	// a compile-time toggle.
	uniform float warp_amount    = 0.0;
	uniform float warp_time_rate = 0.04;
	varying vec3 v_local_pos;
	varying vec3 v_world_pos;
	varying vec3 v_normal;

	// Hash-based value noise. Old form was `fract(p.x*p.y*p.z*(p.x+p.y+p.z))`
	// — symmetric in (x,y,z) and near-zero along the x+y+z=0 plane, so cloud
	// cells aligned to octahedral diagonals and read as rhombuses on the
	// surface. Use IQ-style sin-dot hash with asymmetric coefficients.
	float hash3(vec3 p) {
		return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
	}
	float vnoise(vec3 p) {
		vec3 i = floor(p); vec3 f = fract(p);
		f = f * f * (3.0 - 2.0 * f);
		return mix(mix(mix(hash3(i + vec3(0,0,0)), hash3(i + vec3(1,0,0)), f.x),
		               mix(hash3(i + vec3(0,1,0)), hash3(i + vec3(1,1,0)), f.x), f.y),
		           mix(mix(hash3(i + vec3(0,0,1)), hash3(i + vec3(1,0,1)), f.x),
		               mix(hash3(i + vec3(0,1,1)), hash3(i + vec3(1,1,1)), f.x), f.y), f.z);
	}
	float fbm(vec3 p) {
		float v = 0.0; float a = 0.5;
		for (int i = 0; i < 5; i++) {
			v += a * vnoise(p);
			p = p * 2.13 + vec3(13.7, 5.1, 19.3);
			a *= 0.5;
		}
		return v; // 0..~1
	}

	// Multi-scale density combiner — produces small + medium + large puffs
	// in the same field. WEIGHTED SUM rather than MAX so peaks aren't
	// sharpened (MAX produces triangular spike-like silhouettes; weighted
	// sum stays soft and cotton-like). The layer_offset uniform shifts the
	// noise position per stacked shell so the layers aren't identical.
	float cloud_density(vec3 dir, float t, float c_scale) {
		vec3 base = dir * planet_r * c_scale + layer_offset;
		// Domain warping — a slow-moving low-freq fbm displaces the sample
		// position so the noise field itself evolves over time. The two fbm
		// taps form an x/y warp vector; the third component reuses their
		// difference so we don't pay for a third tap. Centred on 0.5 so the
		// warp is signed (push and pull) rather than always-positive drift.
		if (warp_amount > 0.0) {
			vec3 wq = base * 0.5 + vec3(t * warp_time_rate, t * warp_time_rate * 0.7, -t * warp_time_rate * 0.9);
			float wa = fbm(wq);
			float wb = fbm(wq + vec3(5.2, 1.3, 8.1));
			base += vec3(wa - 0.5, wb - 0.5, (wa - wb) * 0.5) * warp_amount;
		}
		// Per-octave wind variation via swizzle: each octave drifts in a
		// rotated direction so cross-currents read as natural turbulence
		// instead of a single rigid translation. Higher octaves move faster.
		vec3 wind_l = wind_velocity            * 0.6;
		vec3 wind_m = wind_velocity.yzx        * 1.0;
		vec3 wind_s = wind_velocity.zxy        * 1.4;
		vec3 lp_large = base * 0.35 + wind_l * t;
		vec3 lp_med   = base * 1.0  + wind_m * t + vec3(50.0);
		vec3 lp_small = base * 2.8  + wind_s * t + vec3(100.0);
		float d_large = fbm(lp_large);
		float d_med   = fbm(lp_med);
		float d_small = fbm(lp_small);
		return d_large * 0.50 + d_med * 0.35 + d_small * 0.15;
	}

	void vertex() {
		v_local_pos = VERTEX;
		v_normal = normalize(VERTEX);
		// VERTEX DISPLACEMENT: subtle bumps for parallax depth, NOT towers.
		// The previous bump_height (planet_r * cell_scale * 1200) worked out
		// to ~120km of displacement on small planets — that's why clouds
		// looked like triangular mountains. Cap at a fixed fraction (~12%)
		// of one cell's lateral surface size so bumps stay rounded and
		// proportional rather than dwarfing the puff.
		float vt = TIME * 0.015;
		float v_dens = cloud_density(v_normal, vt, cell_scale);
		float v_bump = smoothstep(thresh_lo - 0.05, thresh_hi + 0.05, v_dens);
		float lateral_cell_metres = 1.0 / max(cell_scale, 0.00001);
		float bump_height = lateral_cell_metres * 0.12;
		VERTEX += v_normal * v_bump * bump_height;
		v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}

	void fragment() {
		float t = TIME * 0.015;
		vec3 dir = normalize(v_local_pos);

		// Surface density at this fragment.
		float density = cloud_density(dir, t, cell_scale);
		// Edge fluff via micro-detail noise — pure variation (mean-centred).
		vec3 lp_micro = dir * planet_r * cell_scale * 8.0 + layer_offset
			+ vec3(t * 0.8, -t * 0.5, t * 0.3);
		density += fbm(lp_micro) * 0.08 - 0.04;

		// VOLUMETRIC RAYMARCHING: sample density at 4 points along the view
		// ray, going INTO the cloud sphere, and accumulate coverage. This
		// approximates flying through a volumetric cloud rather than a 2D
		// shell — fragments where view ray pierces deep cloud get higher
		// total coverage than fragments where it just grazes the silhouette.
		// The local-space camera position lets us march in local coords so
		// the noise sampling stays consistent with the rest of the shader.
		vec3 cam_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
		vec3 view_local = normalize(v_local_pos - cam_local);
		float march_step = max(planet_r * 0.0015, 200.0);
		float volumetric_density = density;
		for (int i = 1; i <= 3; i++) {
			vec3 sample_pos = v_local_pos + view_local * march_step * float(i);
			vec3 sample_dir = normalize(sample_pos);
			volumetric_density += cloud_density(sample_dir, t, cell_scale);
		}
		volumetric_density *= 0.25;  // average across 4 samples
		// Blend surface density with marched density — surface gives sharp
		// silhouette, marched gives interior thickness.
		density = mix(density, volumetric_density, 0.55);

		// Coverage smoothstep — slight lower-edge softening for wispy edges
		// without flooding the whole sphere with low-density haze. The
		// previous 0.50 lower-edge expansion was letting nearly every
		// fragment pass with some coverage, which is what painted the
		// planet white-on-everything.
		float thresh_feather = max(thresh_hi - thresh_lo, 0.001);
		float coverage = smoothstep(thresh_lo - thresh_feather * 0.15, thresh_hi, density);

		float cam_dist = length(CAMERA_POSITION_WORLD - v_world_pos);
		float proximity = smoothstep(50.0, 30000.0, cam_dist);
		coverage *= mix(1.0, 0.6, proximity);

		if (coverage < 0.01) discard;

		// SOFT self-shadow — much weaker than before. Heavy self-shadow
		// produces hard interior lines that look like geometric facets,
		// not cotton. We keep just enough to prevent total flatness.
		vec3 lp_shadow = dir * planet_r * cell_scale + sun_dir * (cell_scale * planet_r * 0.04);
		float shadow_density = fbm(lp_shadow + vec3(t, t * 0.5, -t * 0.3));
		float self_shadow = smoothstep(0.40, 0.80, shadow_density);

		float dot_nl = dot(v_normal, sun_dir);
		float terminator = smoothstep(-0.2, 0.25, dot_nl);

		// Gentle density-driven brightness — kept close to white throughout
		// so opaque clouds read as bright cumulus, not muddy/brown blobs.
		// Horizon tint capped at 8% even on shadow_color to prevent strongly
		// coloured atmospheres from turning the clouds orange/brown.
		float core = smoothstep(thresh_lo, thresh_hi + 0.20, density);
		vec3 lit_color    = mix(vec3(1.00), horizon_color, 0.05);
		vec3 edge_color   = mix(vec3(0.94, 0.95, 0.97), horizon_color, 0.10);
		vec3 shadow_color = mix(vec3(0.78, 0.80, 0.85), horizon_color, 0.08);
		vec3 cloud_color = mix(edge_color, lit_color, core);
		cloud_color = mix(cloud_color, shadow_color, self_shadow * 0.40);
		// Night-side darkening — only halve, not 70%, so the "shadow side"
		// reads as dim grey rather than near-black brown.
		cloud_color = mix(cloud_color * 0.50, cloud_color, terminator);

		ALBEDO = cloud_color;
		// Edge alpha pulled close to 1.0 so silhouettes are nearly as opaque
		// as the cloud cores — wispy silhouette comes from the noise field
		// itself, not from per-fragment alpha falloff.
		float edge_alpha = mix(0.85, 1.0, core);
		ALPHA = coverage * alpha_max * edge_alpha * mix(0.55, 1.0, terminator);

		// CELESTIAL HIBERNATION: Fully transparent if extremely distant
		if (cam_dist > 4000000.0) ALPHA = 0.0;
	}"""
	var c_inst = MeshInstance3D.new(); c_inst.mesh = c_mesh; c_inst.material_override = ShaderMaterial.new(); c_inst.material_override.shader = c_shader
	c_inst.material_override.render_priority = 5
	var sun_dir = Vector3(0.5, 0.5, 0.707).normalized()
	c_inst.material_override.set_shader_parameter("sun_dir", sun_dir)
	c_inst.material_override.set_shader_parameter("horizon_color", Vector3(sky_horizon_color.r, sky_horizon_color.g, sky_horizon_color.b))
	c_inst.material_override.set_shader_parameter("planet_r", planet_radius)

	# ── Per-planet cloud profile ─────────────────────────────────────
	# Pick blob size and coverage independently from the planet's RNG so
	# every world feels distinct. Cell scale tuned for ~3–5× larger puffs
	# than the original range. Lower values mean fewer/larger puffs (since
	# lp = dir * planet_r * cell_scale samples a smaller noise range across
	# the sphere). The previous 0.00020 floor produced so few cells per
	# planet that fbm output stayed near 0.5 and rarely crossed thresh_lo,
	# so worlds appeared cloudless. 0.0004 keeps ~40 cells per planet —
	# enough variation to consistently produce visible cloud masses.
	# Threshold ceiling lowered so even the sparsest worlds show some clouds.
	var cell_scale: float = rng.randf_range(0.00040, 0.00150)
	var thresh_lo: float  = rng.randf_range(0.42, 0.62)
	var thresh_hi: float  = thresh_lo + 0.20
	# Alpha range tuned for "almost no transparency" — clouds read clearly as
	# their own layer over the planet surface. Sparse worlds get the higher
	# end (0.95, near-solid puffs); overcast worlds get the lower end (0.85)
	# so the layer doesn't completely paint over the silhouette when many
	# puffs overlap. Edge translucency in the shader handles the wispy
	# silhouette feel — these uniforms control the core opacity.
	var alpha_max: float  = lerpf(0.95, 0.85, smoothstep(0.42, 0.62, thresh_lo))
	# MINERAL INFLUENCE — coverage_delta lowers both thresholds (more clouds);
	# alpha_delta thickens cloud cores. Clamped to legal smoothstep/alpha ranges.
	# Applied here so the per-layer stack below picks up the influenced values.
	var p_cov_delta: float = float(planet_profile.get("cloud_coverage_delta", 0.0))
	var p_alpha_delta: float = float(planet_profile.get("cloud_alpha_delta", 0.0))
	thresh_lo = clampf(thresh_lo - p_cov_delta, 0.05, 0.90)
	thresh_hi = clampf(thresh_hi - p_cov_delta, thresh_lo + 0.05, 0.99)
	alpha_max = clampf(alpha_max + p_alpha_delta, 0.0, 1.0)

	# CLOUD SHADOWS ON LAND — push the cloud-noise parameters onto the
	# shared land_material so triplanar_local.gdshader can sample the same
	# density field this planet's clouds use, and darken the surface
	# accordingly. Strength uniform is also conveyed so the cloud spawn
	# can dial it down per planet (e.g. 0 for cloudless worlds later).
	if land_material:
		land_material.set_shader_parameter("cloud_cell_scale", cell_scale)
		land_material.set_shader_parameter("cloud_thresh_lo", thresh_lo)
		land_material.set_shader_parameter("cloud_thresh_hi", thresh_hi)
		land_material.set_shader_parameter("cloud_strength", 0.40)
	c_inst.queue_free()  # discard initial layer; the stack below replaces it

	# Multi-shell stack — N cloud spheres at different altitudes, each
	# sampling the same cloud_density() but with a per-layer offset so the
	# layers aren't identical. Stacked together they read as cloud volume
	# rather than a single shell — flying past, the player sees clouds
	# at different heights cross at different angles and densities, which
	# is what produces the "thickness" feel.
	var sun_dir_local: Vector3 = sun_dir
	var horizon_vec: Vector3 = Vector3(sky_horizon_color.r, sky_horizon_color.g, sky_horizon_color.b)
	# Layer altitudes in metres above planet surface. Spread across ~7km
	# of vertical range so the cloud band has real thickness.
	var layer_altitudes: Array = [1500.0, 2800.0, 4200.0, 5800.0, 7500.0]
	# Per-layer relative cell scale and alpha — middle layers are densest,
	# outer layers (top/bottom) thin out so the band has soft edges in
	# altitude as well.
	var layer_scale_mul: Array = [1.10, 1.00, 0.95, 1.30, 2.20]
	var layer_alpha_mul: Array = [0.55, 0.85, 1.00, 0.75, 0.45]
	# Per-layer wind: each shell drifts in its own direction at its own speed.
	# Low layers (cumulus) move slowly with surface trade winds; high layers
	# (cirrus) zoom in opposite directions. Magnitudes are in noise-sample
	# units per second; ~0.6 matches the legacy single-direction default.
	var layer_winds: Array = [
		Vector3( 0.55,  0.20,  0.30),  # 1.5 km — low, slow, easterly drift
		Vector3( 0.45, -0.15, -0.40),  # 2.8 km
		Vector3(-0.35,  0.30, -0.55),  # 4.2 km — mid layer, sharper turn
		Vector3(-0.70,  0.10,  0.50),  # 5.8 km
		Vector3( 0.20, -0.50,  0.95),  # 7.5 km — high cirrus, fast, opposite
	]
	# Domain warping is the heaviest knob — costs +2 fbm per density sample.
	# Mobile keeps the simple translation; desktop gets evolving shapes.
	var warp_for_layer: float = 0.0 if mobile_perf else 0.55
	for layer_idx in range(layer_altitudes.size()):
		var alt: float = layer_altitudes[layer_idx]
		var scale_mul: float = layer_scale_mul[layer_idx]
		var alpha_mul: float = layer_alpha_mul[layer_idx]
		var lm = SphereMesh.new()
		lm.radius = planet_radius + alt
		lm.height = lm.radius * 2.0
		lm.radial_segments = 64; lm.rings = 32
		var li = MeshInstance3D.new()
		li.mesh = lm
		li.material_override = ShaderMaterial.new()
		li.material_override.shader = c_shader
		li.material_override.render_priority = 5 + layer_idx
		li.material_override.set_shader_parameter("sun_dir", sun_dir_local)
		li.material_override.set_shader_parameter("horizon_color", horizon_vec)
		li.material_override.set_shader_parameter("planet_r", planet_radius)
		li.material_override.set_shader_parameter("cell_scale", cell_scale * scale_mul)
		li.material_override.set_shader_parameter("thresh_lo", thresh_lo)
		li.material_override.set_shader_parameter("thresh_hi", thresh_hi)
		li.material_override.set_shader_parameter("alpha_max", alpha_max * alpha_mul)
		# Each layer gets a unique 3D offset so the noise sampled across
		# layers isn't identical — without this, all 5 shells would render
		# the exact same cloud pattern and the stack would look like one
		# thick shell instead of distinct vertical layers.
		var layer_seed_offset := Vector3(
			float(layer_idx) * 51.13,
			float(layer_idx) * 27.71 + 11.0,
			float(layer_idx) * 73.91 - 5.0
		)
		li.material_override.set_shader_parameter("layer_offset", layer_seed_offset)
		li.material_override.set_shader_parameter("wind_velocity", layer_winds[layer_idx])
		li.material_override.set_shader_parameter("warp_amount", warp_for_layer)
		li.visibility_range_end = PROXIMITY_CUTOFF
		li.visibility_range_end_margin = 100000.0
		li.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(li)
	
	# 2. PLANETARY RINGS (50% chance per planet, boosted by mineral influence)
	# MINERAL INFLUENCE — metallic/exotic tags push toward guaranteed rings.
	var ring_chance: float = clampf(0.5 + float(planet_profile.get("ring_boost", 0.0)), 0.0, 1.0)
	if rng.randf() < ring_chance:
		var r_mesh = TorusMesh.new()
		r_mesh.inner_radius = planet_radius * 1.5
		r_mesh.outer_radius = planet_radius * 2.8
		r_mesh.rings = 128; r_mesh.ring_segments = 4
		var r_shader = Shader.new(); r_shader.code = """shader_type spatial; render_mode unshaded, blend_mix, depth_draw_always, cull_disabled;
		uniform vec3 ring_col_a;
		varying vec3 v_local_pos;
		void vertex() { v_local_pos = VERTEX; }
		float hash(float n) { return fract(sin(n) * 43758.5453123); }
		void fragment() {
			float d = length(v_local_pos.xz);
			float radial_idx = floor(d * 0.0006); // ACE: Increased frequency for tighter rings
			float noise_val = hash(radial_idx);
			
			// Multi-frequency bands
			float mask = mix(0.2, 0.8, noise_val);
			mask *= 0.7 + 0.3 * sin(d * 0.0045); // Fine grooves (Scaled up)
			mask *= 0.8 + 0.2 * sin(d * 0.0001); // Broad variation (Scaled up)
			
			// Cassini-style gaps for realism
			float gaps = step(0.15, abs(sin(d * 0.000025 + noise_val)));
			mask *= gaps;
			
			// Procedural tone shifting per band
			vec3 final_col = ring_col_a * (0.85 + noise_val * 0.25);
			ALBEDO = final_col;
			ALPHA = clamp(mask * 0.6, 0.0, 0.85);
		}"""
		var r_inst = MeshInstance3D.new(); r_inst.mesh = r_mesh; r_inst.material_override = ShaderMaterial.new(); r_inst.material_override.shader = r_shader
		
		# Procedural Ring Palette: Derived from planet hue but desaturated and bright (ice/dust)
		var r_col = Color.from_hsv(base_hue, 0.25, 1.0).lerp(Color.WHITE, 0.3)
		r_inst.material_override.set_shader_parameter("ring_col_a", r_col)
		r_inst.rotation_degrees = Vector3(rng.randf_range(10.0, 35.0), rng.randf_range(0, 360), 0.0)
		r_inst.scale = Vector3(1.0, 0.015, 1.0)
		r_inst.visibility_range_end = PROXIMITY_CUTOFF; add_child(r_inst)

	# 3. POLAR AURORAS — generic version disabled (smoothstep gradient
	# quantized into visible latitude rings under the halftone post-process).
	# AURORA archetype gets a dedicated noise-driven curtain instead.
	if archetype == "AURORA":
		_spawn_aurora_curtain()

func _spawn_aurora_curtain() -> void:
	# Wide animated curtain spanning most of the planet, broken up by noise
	# so the halftone post-process doesn't quantize it into visible rings.
	# Colours pulled from the iconic green/violet aurora gradient — independent
	# of the planet palette so AURORA reads consistently across worlds.
	var a_mesh = SphereMesh.new()
	a_mesh.radius = planet_radius + 5500.0
	a_mesh.height = a_mesh.radius * 2.0
	a_mesh.radial_segments = 64
	a_mesh.rings = 32
	var a_shader = Shader.new()
	a_shader.code = """shader_type spatial; render_mode unshaded, blend_add, depth_draw_always, cull_disabled;
	uniform vec3 aura_lo  : source_color = vec3(0.10, 0.85, 0.55);
	uniform vec3 aura_hi  : source_color = vec3(0.55, 0.20, 0.95);
	varying vec3 v_local_pos;
	void vertex() { v_local_pos = VERTEX; }
	float hash3(vec3 p) {
		return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
	}
	float vnoise(vec3 p) {
		vec3 i = floor(p); vec3 f = fract(p);
		f = f * f * (3.0 - 2.0 * f);
		return mix(mix(mix(hash3(i + vec3(0,0,0)), hash3(i + vec3(1,0,0)), f.x),
		               mix(hash3(i + vec3(0,1,0)), hash3(i + vec3(1,1,0)), f.x), f.y),
		           mix(mix(hash3(i + vec3(0,0,1)), hash3(i + vec3(1,0,1)), f.x),
		               mix(hash3(i + vec3(0,1,1)), hash3(i + vec3(1,1,1)), f.x), f.y), f.z);
	}
	void fragment() {
		vec3 dir = normalize(v_local_pos);
		// Wide latitude band centred on equator and the poles — three bands
		// total, broken up by drifting noise so they read as ribbons not rings.
		float lat = abs(dir.y);
		float band_a = smoothstep(0.0, 0.35, 1.0 - lat);
		float band_b = smoothstep(0.40, 0.85, lat);
		float band = max(band_a, band_b);
		float ribbon = vnoise(dir * 6.0 + vec3(TIME * 0.05, 0.0, TIME * 0.03));
		float ribbon2 = vnoise(dir * 14.0 + vec3(0.0, TIME * 0.08, 0.0));
		float curtain = smoothstep(0.45, 0.85, ribbon * 0.7 + ribbon2 * 0.3);
		float a = band * curtain;
		if (a <= 0.01) { discard; }
		vec3 col = mix(aura_lo, aura_hi, ribbon);
		ALBEDO = col;
		ALPHA = a * 0.55;
	}"""
	var a_inst = MeshInstance3D.new()
	a_inst.mesh = a_mesh
	a_inst.material_override = ShaderMaterial.new()
	a_inst.material_override.shader = a_shader
	a_inst.material_override.render_priority = 7
	a_inst.visibility_range_end = PROXIMITY_CUTOFF
	add_child(a_inst)

func _spawn_sky_isles(rng: RandomNumberGenerator) -> void:
	# S-tier SKY_ISLES exclusive: floating islands in stable orbits above
	# the planet. Each isle is a StaticBody3D so the player ship can land
	# on it; the hull is built at world-scale (no parent node scaling) so
	# the planet's own tree/rock meshes can be reused at their natural size.
	# The whole flotilla parents under a single rotating Node3D so we get
	# orbital animation with one transform.
	var orbit := Node3D.new()
	orbit.name = "SkyIsleOrbit"
	add_child(orbit)
	orbit.set_script(preload("res://src/world/SkyIsleOrbit.gd"))

	# Single shared hull material — vertex-colour drives biome look so we
	# don't create thousands of unique materials. Trees, trunks, and rocks
	# reuse the planet's own materials (planet.foliage_material etc.) so
	# the isles are visually a chip off the planet they orbit.
	var hull_mat := StandardMaterial3D.new()
	hull_mat.vertex_color_use_as_albedo = true
	hull_mat.roughness = 0.92
	hull_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	# Pull the planet's actual tree / trunk / rock meshes. Built lazily
	# by PlanetChunk on first chunk-gen; isles spawn before any chunk runs
	# so we use a scratch chunk to populate the cache here.
	var prop_meshes: Dictionary = _ensure_isle_prop_meshes()

	# Tier scales the flotilla — SS/legendary worlds blanket the sky.
	var count_mult: float = _tier_drama_scale(planet_rank)
	var count: int = int(rng.randi_range(8, 24) * count_mult)
	var altitude_min: float = planet_radius * 0.08
	var altitude_max: float = planet_radius * 0.18
	for i in range(count):
		var lat: float = rng.randf_range(-1.0, 1.0)
		var lon: float = rng.randf_range(0.0, TAU)
		var sphere_dir := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon)).normalized()
		var altitude: float = rng.randf_range(altitude_min, altitude_max)
		var pos: Vector3 = sphere_dir * (planet_radius + altitude)

		# Per-isle parameters. Radius in world units (no node scaling — we
		# need props to render at their natural sizes).
		var radius: float = rng.randf_range(2000.0, 5500.0) * count_mult
		var height: float = radius * 0.55
		var has_basin: bool = rng.randf() < 0.35

		# StaticBody3D so the ship can land on the hull.
		var isle := StaticBody3D.new()
		isle.collision_layer = 1   # World layer — same as planet terrain
		isle.collision_mask = 0    # static body, doesn't query
		isle.position = pos
		var up: Vector3 = sphere_dir
		var fwd: Vector3 = up.cross(Vector3.RIGHT).normalized()
		if fwd.length_squared() < 0.01:
			fwd = up.cross(Vector3.FORWARD).normalized()
		isle.transform.basis = Basis(fwd.cross(up).normalized(), up, -fwd)
		orbit.add_child(isle)

		# Pre-compute the isle's top-rim Y so the hull builder, water basin,
		# and prop scatter all agree on where the surface is.  The procedural
		# hull picks a randomized top_h per isle; if the scatter functions
		# used a hardcoded 0.20*height (the old value) trees and rocks would
		# float above the surface or sink below it on every isle whose
		# top_h drifted away from 0.20.
		var top_h: float = height * rng.randf_range(0.15, 0.28)

		# Hull: tiered cliff + grass top + tapered rocky underside.
		var hull_mesh: ArrayMesh = _build_sky_isle_mesh(rng, has_basin, radius, height, top_h)
		var hull := MeshInstance3D.new()
		hull.mesh = hull_mesh
		hull.material_override = hull_mat
		hull.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hull.visibility_range_end = PROXIMITY_CUTOFF * 0.4
		hull.visibility_range_end_margin = 50000.0
		isle.add_child(hull)

		# Convex collision derived from hull vertices — close enough for
		# landing/docking and far cheaper than a trimesh.
		var coll := CollisionShape3D.new()
		coll.shape = hull_mesh.create_convex_shape()
		isle.add_child(coll)

		# Optional water basin sunk slightly into the top dome — uses the
		# planet's own water material so colour + lava state match.
		# Basin radius and Y offset (relative to the actual top rim) are
		# randomized so basins on different isles read as different bodies
		# of water.
		if has_basin and water_material:
			var basin_radius: float = radius * rng.randf_range(0.40, 0.65)
			var basin_drop: float = top_h * rng.randf_range(0.10, 0.30)
			var water := MeshInstance3D.new()
			water.mesh = _build_isle_water_disc(basin_radius, rng)
			water.material_override = water_material
			water.position = Vector3(0, top_h - basin_drop, 0)
			water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			isle.add_child(water)

		# Plant the planet's own trees + rocks on top.  Pass the actual
		# top-rim Y so props sit on the real surface, not a hardcoded value.
		_scatter_isle_props(isle, rng, has_basin, radius, height, top_h, prop_meshes)

		# Aether Crystal — sky-isle exclusive rare mineral.  1-3 deposits per
		# isle, placed near the top surface but away from the centre/basin.
		_scatter_isle_aether_crystals(isle, rng, has_basin, radius, height, top_h)

func _ensure_isle_prop_meshes() -> Dictionary:
	# Returns { fol_h, trk_h, rock } — the planet's own foliage / trunk /
	# rock meshes for this archetype. PlanetChunk caches these statically
	# in `_c_fol_h_by_arch` etc. but the cache is only populated when a
	# chunk's _spawn_tree_lods runs. Isles spawn during PlanetGen._ready
	# (before any chunk renders), so we instantiate a scratch PlanetChunk
	# here just to drive the per-archetype cache build.
	var fol: ArrayMesh = null
	var trk: ArrayMesh = null
	var rock: ArrayMesh = null
	if PlanetChunkScript:
		var fol_cache: Dictionary = PlanetChunkScript.get("_c_fol_h_by_arch")
		var trk_cache: Dictionary = PlanetChunkScript.get("_c_trk_h_by_arch")
		if fol_cache != null and fol_cache.has(archetype):
			fol = fol_cache[archetype]
		if trk_cache != null and trk_cache.has(archetype):
			trk = trk_cache[archetype]
		rock = PlanetChunkScript.get("_c_r")
		if fol == null or trk == null or rock == null:
			# Scratch chunk just to call the (instance-method) builders.
			# Discarded after the meshes are cached statically.
			var scratch: Node = PlanetChunkScript.new()
			scratch.set("archetype", archetype)
			scratch.set("pal_grass_col", pal_grass_col)
			scratch.set("pal_mount_col", pal_mount_col)
			scratch.set("pal_forest_h", pal_forest_h)
			if fol == null: fol = scratch.call("_build_varied_foliage", true, 4)
			if trk == null: trk = scratch.call("_build_botw_trunk", true)
			if rock == null: rock = scratch.call("_build_faceted_rock_mesh", 12)
			# Persist into the static caches so subsequent chunks reuse them.
			if fol_cache != null: fol_cache[archetype] = fol
			if trk_cache != null: trk_cache[archetype] = trk
			PlanetChunkScript.set("_c_r", rock)
			scratch.queue_free()
	return {"fol_h": fol, "trk_h": trk, "rock": rock}

func _build_sky_isle_mesh(rng: RandomNumberGenerator, has_basin: bool, radius: float, height: float, top_h: float) -> ArrayMesh:
	# Mesh built directly in WORLD units (no parent scaling) so the planet's
	# tree/rock meshes — which are also world-sized — sit on top at the
	# correct relative size.  `top_h` (Y of the outer rim) is supplied by the
	# caller so prop scatter functions can place trees/rocks at the matching
	# height; the rest of the silhouette is procedurally derived here.
	#
	# Procedural variation per isle:
	#   - Side count (silhouette resolution) varies 18..30.
	#   - Tier count varies 3..6 — fewer tiers feels squat, more feels tall.
	#   - Each tier's y-position and inset (rfrac) is randomized within a band
	#     so no two isles share the exact silhouette.
	#   - Per-spoke radial noise (two stacked sin harmonics + per-spoke jitter)
	#     gives every spoke a unique outline rather than a regular polygon.
	#   - A "lean" vector tilts the whole shape slightly so isles aren't axially
	#     symmetric, which sells the floating-rock look.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var sides: int = rng.randi_range(18, 30)
	var tier_count: int = rng.randi_range(3, 6)
	var dome_h: float = (height * rng.randf_range(0.06, 0.14)) if not has_basin else (height * rng.randf_range(0.03, 0.07))
	var bottom_y: float = -height

	var grass_col: Color = pal_grass_col
	var grass_dim: Color = pal_grass_col.darkened(0.18)
	var dirt_col: Color = pal_mount_col.lerp(pal_grass_col, 0.18).darkened(0.05)
	var rock_palette: Array = [
		pal_mount_col.darkened(0.05),
		pal_mount_col.darkened(0.18),
		pal_mount_col.darkened(0.28),
		pal_mount_col.darkened(0.40),
	]
	var rock_dark: Color = pal_mount_col.darkened(0.35)

	# Build per-tier specs procedurally so each isle has a unique silhouette.
	# The top tier is always grass_dim at top_h with the full base radius;
	# subsequent tiers descend monotonically in y and step inward in rfrac.
	var tier_specs: Array = [{"y": top_h, "rfrac": 1.0, "color": grass_dim}]
	tier_specs.append({"y": top_h * rng.randf_range(0.25, 0.55), "rfrac": rng.randf_range(0.93, 0.98), "color": dirt_col})
	var remaining: int = tier_count - 1
	for t in range(remaining):
		var prog: float = float(t + 1) / float(remaining + 1)
		# y descends from ~-0.05*height to ~-0.6*height with jitter.
		var y_norm: float = lerp(-0.05, -0.60, prog) + rng.randf_range(-0.04, 0.04)
		var rfrac: float = lerp(0.92, 0.55, prog) + rng.randf_range(-0.06, 0.04)
		rfrac = clamp(rfrac, 0.40, 0.96)
		tier_specs.append({
			"y": height * y_norm,
			"rfrac": rfrac,
			"color": rock_palette[t % rock_palette.size()],
		})

	# Asymmetric "lean" — drift each tier's center off-axis to make isles
	# look chunky/uneven instead of pure rotational solids.
	var lean_amp: float = radius * rng.randf_range(0.0, 0.08)
	var lean_ang: float = rng.randf() * TAU
	var lean_dir: Vector3 = Vector3(cos(lean_ang), 0.0, sin(lean_ang))

	# Two stacked sin harmonics (different periods + phases) drive per-spoke
	# radial noise.  Combined amplitude ~12%.
	var harm_a_period: float = rng.randf_range(2.0, 4.0)
	var harm_a_phase: float = rng.randf() * TAU
	var harm_a_amp: float = rng.randf_range(0.04, 0.09)
	var harm_b_period: float = rng.randf_range(5.0, 9.0)
	var harm_b_phase: float = rng.randf() * TAU
	var harm_b_amp: float = rng.randf_range(0.02, 0.05)

	# Build per-tier rings with the procedural deformations.
	var rings: Array = []
	for spec_i in range(tier_specs.size()):
		var spec: Dictionary = tier_specs[spec_i]
		var ring: PackedVector3Array = PackedVector3Array()
		# Lean amount tapers from 0 at the top to full at the bottom so the
		# isle leans like a hanging stalactite.
		var lean_t: float = float(spec_i) / float(tier_specs.size() - 1)
		var lean_off: Vector3 = lean_dir * (lean_amp * lean_t)
		for i in range(sides):
			var a: float = float(i) / sides * TAU
			var harm: float = sin(a * harm_a_period + harm_a_phase) * harm_a_amp \
							+ sin(a * harm_b_period + harm_b_phase) * harm_b_amp \
							+ rng.randf_range(-0.02, 0.02)
			var r: float = max(0.30, spec.rfrac + harm) * radius
			ring.append(Vector3(cos(a) * r + lean_off.x, spec.y, sin(a) * r + lean_off.z))
		rings.append(ring)

	var top_edge: PackedVector3Array = rings[0]
	var top_centre := Vector3(0, top_h + dome_h, 0)

	# Top fan (grass dome).
	for i in range(sides):
		var i_next: int = (i + 1) % sides
		var v0: Vector3 = top_edge[i]
		var v1: Vector3 = top_edge[i_next]
		st.set_color(grass_col); st.add_vertex(top_centre)
		st.set_color(grass_dim); st.add_vertex(v1)
		st.set_color(grass_dim); st.add_vertex(v0)

	# Tier walls — each pair of consecutive rings forms a tapered band of
	# quads. Bottom ring of each pair gets the next tier's colour so the
	# step where a tier ends is visible.
	for tier in range(rings.size() - 1):
		var upper: PackedVector3Array = rings[tier]
		var lower: PackedVector3Array = rings[tier + 1]
		var upper_col: Color = tier_specs[tier].color
		var lower_col: Color = tier_specs[tier + 1].color
		# Horizontal step: connect upper ring outer to lower ring outer at
		# upper's Y level so the tier reads as a flat shelf before dropping.
		# (Build the shelf as a triangle strip from upper to a "shelf" ring
		# that has lower's radius but upper's Y.)
		var shelf: PackedVector3Array = PackedVector3Array()
		for i in range(sides):
			var lo: Vector3 = lower[i]
			shelf.append(Vector3(lo.x, upper[i].y, lo.z))
		# Shelf top — between upper ring and shelf ring (flat horizontal band).
		for i in range(sides):
			var i_next: int = (i + 1) % sides
			var u0: Vector3 = upper[i]
			var u1: Vector3 = upper[i_next]
			var s0: Vector3 = shelf[i]
			var s1: Vector3 = shelf[i_next]
			st.set_color(upper_col); st.add_vertex(u0)
			st.set_color(upper_col); st.add_vertex(u1)
			st.set_color(upper_col); st.add_vertex(s1)
			st.set_color(upper_col); st.add_vertex(u0)
			st.set_color(upper_col); st.add_vertex(s1)
			st.set_color(upper_col); st.add_vertex(s0)
		# Vertical drop — shelf ring down to lower ring.
		for i in range(sides):
			var i_next: int = (i + 1) % sides
			var s0: Vector3 = shelf[i]
			var s1: Vector3 = shelf[i_next]
			var l0: Vector3 = lower[i]
			var l1: Vector3 = lower[i_next]
			st.set_color(upper_col); st.add_vertex(s0)
			st.set_color(upper_col); st.add_vertex(s1)
			st.set_color(lower_col); st.add_vertex(l1)
			st.set_color(upper_col); st.add_vertex(s0)
			st.set_color(lower_col); st.add_vertex(l1)
			st.set_color(lower_col); st.add_vertex(l0)

	# Underside cone — tapered point from the lowest ring to the tip.
	# Tip follows the same horizontal lean as the bottom ring so the cone
	# isn't visually disconnected from the leaning silhouette above.
	var tip := Vector3(lean_dir.x * lean_amp, bottom_y, lean_dir.z * lean_amp)
	var bottom_ring: PackedVector3Array = rings[rings.size() - 1]
	for i in range(sides):
		var i_next: int = (i + 1) % sides
		var b0: Vector3 = bottom_ring[i]
		var b1: Vector3 = bottom_ring[i_next]
		st.set_color(rock_dark); st.add_vertex(tip)
		st.set_color(rock_dark); st.add_vertex(b0)
		st.set_color(rock_dark); st.add_vertex(b1)

	st.generate_normals(false)
	st.generate_tangents()
	return st.commit()

func _build_isle_water_disc(disc_radius: float, rng: RandomNumberGenerator) -> ArrayMesh:
	# Procedural water basin — irregular outline driven by two sin harmonics
	# plus per-spoke jitter so no two basins share the same shoreline.  Also
	# offset slightly from the centre of the dome so the basin doesn't always
	# sit perfectly centred.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides: int = rng.randi_range(20, 32)

	# Per-basin harmonics for the shoreline outline.
	var h_a_period: float = rng.randf_range(2.0, 4.0)
	var h_a_phase: float = rng.randf() * TAU
	var h_a_amp: float = rng.randf_range(0.08, 0.18)
	var h_b_period: float = rng.randf_range(5.0, 8.0)
	var h_b_phase: float = rng.randf() * TAU
	var h_b_amp: float = rng.randf_range(0.03, 0.08)

	# Off-centre nudge — keeps the basin from always being perfectly axial.
	var off_ang: float = rng.randf() * TAU
	var off_r: float = disc_radius * rng.randf_range(0.0, 0.15)
	var off_x: float = cos(off_ang) * off_r
	var off_z: float = sin(off_ang) * off_r

	# Pre-compute outline radii so the fan reuses the same edge vertices on
	# both sides of each triangle (no seam from independently-jittered edges).
	var ring: Array = []
	for i in range(sides):
		var a: float = float(i) / sides * TAU
		var harm: float = sin(a * h_a_period + h_a_phase) * h_a_amp \
						+ sin(a * h_b_period + h_b_phase) * h_b_amp \
						+ rng.randf_range(-0.02, 0.02)
		var r: float = max(disc_radius * 0.55, disc_radius * (1.0 + harm))
		ring.append(Vector3(cos(a) * r + off_x, 0, sin(a) * r + off_z))

	var centre := Vector3(off_x, 0, off_z)
	for i in range(sides):
		var i_next: int = (i + 1) % sides
		st.add_vertex(centre)
		st.add_vertex(ring[i])
		st.add_vertex(ring[i_next])
	st.generate_normals(false)
	st.generate_tangents()
	return st.commit()

func _scatter_isle_aether_crystals(isle: Node3D, rng: RandomNumberGenerator, has_basin: bool,
		radius: float, _height: float, top_h: float) -> void:
	# Spawn 1-3 Aether Crystal deposits on the top surface of a sky-isle.
	# Sky-isle exclusive — never appears on planet surfaces (filtered out by
	# ResourceRegistry.natural_pool).  Uses the standard MineableResource
	# pipeline so mining/HUD/loot handling needs no special-casing.
	var m_script: Resource = load("res://src/world/MineableResource.gd")
	if m_script == null:
		return
	var count: int = rng.randi_range(1, 3)
	var top_y: float = top_h
	# Stay away from the basin centre; orbit the outer half of the disc.
	var inner_min: float = (radius * 0.62) if has_basin else (radius * 0.20)
	var outer_max: float = radius * 0.82
	for _i in range(count):
		var ang: float = rng.randf() * TAU
		var rad: float = rng.randf_range(inner_min, outer_max)
		var pos := Vector3(cos(ang) * rad, top_y, sin(ang) * rad)
		var res := StaticBody3D.new()
		res.set_script(m_script)
		res.set("resource_type", "Aether Crystal")
		# Always glows — they're the centrepiece of the isle.
		res.set("glows", true)
		var rot := Transform3D(Basis(), pos).rotated_local(Vector3.UP, rng.randf() * TAU)
		res.transform = rot
		isle.add_child(res)

func _scatter_isle_props(isle: Node3D, rng: RandomNumberGenerator, has_basin: bool,
		radius: float, _height: float, top_h: float, prop_meshes: Dictionary) -> void:
	# Plant the planet's actual trees + rocks on top of the isle. We reuse
	# planet.foliage_material / planet.trunk_material / PlanetChunk's static
	# rock material so the isle props are visually identical to the ones on
	# the surface below.
	#
	# Positions are in isle-local coordinates (the StaticBody3D parent has
	# no scaling, so these are world units offset from the isle's centre).
	var top_y: float = top_h  # matches the actual top-rim Y used by the hull builder
	var inner_min: float = (radius * 0.62) if has_basin else 0.0
	var outer_max: float = radius * 0.85

	var tree_count: int = rng.randi_range(8, 18)
	var rock_count: int = rng.randi_range(6, 14)

	var fol_mesh: ArrayMesh = prop_meshes.get("fol_h")
	var trk_mesh: ArrayMesh = prop_meshes.get("trk_h")
	var rock_mesh: ArrayMesh = prop_meshes.get("rock")

	# ── Trees ──────────────────────────────────────────────────────────
	# Some archetypes (BARREN, ASH, MUDFLAT, DESERT, RUST) don't have
	# "real" trees on the surface — skip the tree pass for those so the
	# isles match.
	var skip_trees: bool = archetype in ["BARREN", "ASH", "MUDFLAT", "DESERT", "RUST", "OBSIDIAN"]
	if not skip_trees and fol_mesh != null and trk_mesh != null and tree_count > 0:
		var t_xforms: Array[Transform3D] = []
		for _i in range(tree_count):
			var ang: float = rng.randf() * TAU
			var rad: float = rng.randf_range(inner_min, outer_max)
			var pos := Vector3(cos(ang) * rad, top_y, sin(ang) * rad)
			var xf := Transform3D(Basis(), pos)
			xf = xf.rotated_local(Vector3.UP, rng.randf() * TAU)
			t_xforms.append(xf)

		# Foliage MultiMesh
		var mm_f := MultiMesh.new()
		mm_f.transform_format = MultiMesh.TRANSFORM_3D
		mm_f.use_colors = true
		mm_f.mesh = fol_mesh
		mm_f.instance_count = tree_count
		# Trunk MultiMesh
		var mm_t := MultiMesh.new()
		mm_t.transform_format = MultiMesh.TRANSFORM_3D
		mm_t.use_colors = true
		mm_t.mesh = trk_mesh
		mm_t.instance_count = tree_count
		for i in range(tree_count):
			var pos: Vector3 = t_xforms[i].origin
			var t_hue: float = fposmod(pal_forest_h + 0.5 + fposmod(pos.x * 0.012, 0.3) - 0.15, 1.0)
			var t_col := Color.from_hsv(t_hue, 0.85, 0.92)
			mm_f.set_instance_transform(i, t_xforms[i])
			mm_f.set_instance_color(i, t_col)
			mm_t.set_instance_transform(i, t_xforms[i])
			# Trunk colour variation matches PlanetChunk: brown / tan / birch.
			var trk_seed: int = int(abs(pos.x * 133.0 + pos.z * 77.0)) % 3
			var tr_c := Color(0.35, 0.25, 0.15)
			if trk_seed == 1: tr_c = Color(0.55, 0.45, 0.35)
			elif trk_seed == 2: tr_c = Color(0.85, 0.85, 0.8)
			mm_t.set_instance_color(i, tr_c)

		var mmi_f := MultiMeshInstance3D.new()
		mmi_f.multimesh = mm_f
		if foliage_material:
			mmi_f.material_override = foliage_material
		mmi_f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		isle.add_child(mmi_f)

		var mmi_t := MultiMeshInstance3D.new()
		mmi_t.multimesh = mm_t
		if trunk_material:
			mmi_t.material_override = trunk_material
		mmi_t.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		isle.add_child(mmi_t)

	# ── Rocks ──────────────────────────────────────────────────────────
	if rock_mesh != null and rock_count > 0:
		var r_xforms: Array[Transform3D] = []
		for _i in range(rock_count):
			var ang: float = rng.randf() * TAU
			var rad: float = rng.randf_range(max(inner_min, radius * 0.45), radius * 0.92)
			var pos := Vector3(cos(ang) * rad, top_y, sin(ang) * rad)
			var b := Basis().rotated(Vector3.UP, rng.randf() * TAU)
			b = b.scaled(Vector3(rng.randf_range(0.8, 1.6), rng.randf_range(0.6, 1.3), rng.randf_range(0.8, 1.6)))
			r_xforms.append(Transform3D(b, pos))

		var mm_r := MultiMesh.new()
		mm_r.transform_format = MultiMesh.TRANSFORM_3D
		mm_r.use_colors = true
		mm_r.mesh = rock_mesh
		mm_r.instance_count = rock_count
		for i in range(rock_count):
			var h_v := hash(r_xforms[i].origin)
			var g: float = 0.34 + fposmod(float(h_v % 100) / 100.0, 0.32)
			mm_r.set_instance_transform(i, r_xforms[i])
			mm_r.set_instance_color(i, Color(g * 1.05, g * 0.95, g * 0.85, 1.0))

		var mmi_r := MultiMeshInstance3D.new()
		mmi_r.multimesh = mm_r
		# Static rock material from PlanetChunk — matches what the surface uses.
		if PlanetChunkScript and PlanetChunkScript.has_method("_get_rock_mat"):
			mmi_r.material_override = PlanetChunkScript.call("_get_rock_mat")
		mmi_r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		isle.add_child(mmi_r)

# ---------------------------------------------------------------------------
# TIER DRAMA HELPERS — drive how exaggerated terrain features get.
# ---------------------------------------------------------------------------
func _tier_drama_scale(rank: String) -> float:
	# Multiplier applied to terrain_strength. 1.0 = baseline (C / unranked).
	match rank:
		"F":           return 0.7
		"D":           return 0.85
		"C":           return 1.0
		"B":           return 1.2
		"A":           return 1.5
		"S":           return 1.85
		"SS":          return 2.2
		"★ LEGENDARY": return 2.6
		_:             return 1.0

func _tier_topo_bias(rank: String) -> float:
	# Additive offset to topo_roll (clamped 0..1 after). Positive shifts the
	# distribution toward MOUNTAINOUS / EXTREME; negative pushes toward FLAT.
	match rank:
		"F":           return -0.30
		"D":           return -0.15
		"C":           return 0.0
		"B":           return 0.15
		"A":           return 0.30
		"S":           return 0.45
		"SS":          return 0.55
		"★ LEGENDARY": return 0.65
		_:             return 0.0

func _tier_landmark_count(rank: String, rng: RandomNumberGenerator) -> int:
	# Higher tiers get more colossal landmarks — read at a glance as "this
	# planet is loaded with hero geometry."
	match rank:
		"F":           return rng.randi_range(2, 3)
		"D":           return rng.randi_range(3, 4)
		"C":           return rng.randi_range(4, 6)
		"B":           return rng.randi_range(5, 8)
		"A":           return rng.randi_range(7, 11)
		"S":           return rng.randi_range(10, 14)
		"SS":          return rng.randi_range(12, 16)
		"★ LEGENDARY": return rng.randi_range(14, 20)
		_:             return rng.randi_range(4, 6)

func _spawn_hero_landmarks(rng: RandomNumberGenerator) -> void:
	var num: int = _tier_landmark_count(planet_rank, rng)
	# Drama scale also enlarges individual landmarks at higher tiers.
	var size_scale: float = _tier_drama_scale(planet_rank)
	# Rock color derived from the planet palette — dark, slightly desaturated
	var rock_col: Color = pal_mount_col.darkened(0.15)
	var accent_col: Color = pal_grass_col.lightened(0.1)

	for i in range(num):
		# SPHERICAL PLACEMENT: Random lat/lon, avoiding poles (lat ±70°)
		var lat: float = rng.randf_range(-1.2, 1.2)        # radians, equatorial band
		var lon: float = rng.randf_range(0.0, TAU)
		var sphere_dir := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon)).normalized()

		# Place base just above the estimated terrain so landmarks root on the ground
		var approx_terrain_h: float = get_terrain_height_at(sphere_dir * planet_radius)
		var base_radius: float = max(approx_terrain_h, planet_radius + 80.0)
		var base_pos: Vector3 = sphere_dir * base_radius

		# Orientation: Y-axis points outward from the planet centre (gravity up)
		var up: Vector3 = sphere_dir
		var fwd: Vector3 = up.cross(Vector3.RIGHT).normalized()
		if fwd.length_squared() < 0.01:
			fwd = up.cross(Vector3.FORWARD).normalized()
		var basis := Basis(fwd.cross(up).normalized(), up, -fwd)

		# Three landmark archetypes: tapered spire, stone arch, and a
		# Hallelujah-Mountain style floating island with stalactite tip.
		var landmark_type: int = rng.randi() % 3
		match landmark_type:
			0: _build_spire(base_pos, basis, rng, rock_col, accent_col, size_scale)
			1: _build_arch(base_pos, basis, rng, rock_col, size_scale)
			2: _build_floating_island(base_pos, basis, rng, rock_col, accent_col, size_scale)

# ---------------------------------------------------------------------------
# SPIRE — a tapered hexagonal monolith, stacked in 8 rings that narrow toward
# the peak, giving natural "geological column" silhouette from any angle.
# ---------------------------------------------------------------------------
func _build_spire(base: Vector3, basis: Basis, rng: RandomNumberGenerator, col: Color, accent: Color, size_scale: float = 1.0) -> void:
	var height: float = rng.randf_range(600.0, 1500.0) * size_scale
	var base_r: float = rng.randf_range(80.0, 180.0) * size_scale
	var sides: int = 6  # Hexagonal — looks natural and low-poly simultaneously
	var rings: int = 8

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var prev_verts: PackedVector3Array = PackedVector3Array()
	for ring in range(rings + 1):
		var t: float = float(ring) / float(rings)
		# Taper: starts wide, narrows aggressively toward tip (power curve)
		var ring_r: float = base_r * pow(1.0 - t, 1.6)
		var ring_h: float = height * t
		# Slight twist as it rises — organic irregular look
		var twist: float = t * 0.4

		var ring_verts := PackedVector3Array()
		for s in range(sides):
			var angle: float = (float(s) / float(sides)) * TAU + twist
			var local_v := Vector3(cos(angle) * ring_r, ring_h, sin(angle) * ring_r)
			ring_verts.append(base + basis * local_v)
		prev_verts = ring_verts

		if ring == 0:
			continue

		# Get previous ring — rebuild it the same way
		var t_prev: float = float(ring - 1) / float(rings)
		var pr: float = base_r * pow(1.0 - t_prev, 1.6)
		var ph: float = height * t_prev
		var pt: float = t_prev * 0.4
		var prev_ring := PackedVector3Array()
		for s in range(sides):
			var angle: float = (float(s) / float(sides)) * TAU + pt
			prev_ring.append(base + basis * Vector3(cos(angle) * pr, ph, sin(angle) * pr))

		# Stitch quad strip between this ring and the previous ring
		var use_col: Color = accent if ring % 2 == 0 else col
		for s in range(sides):
			var ns: int = (s + 1) % sides
			_add_tri_flat(st, prev_ring[s],  ring_verts[s],   prev_ring[ns],  use_col)
			_add_tri_flat(st, ring_verts[s], ring_verts[ns],  prev_ring[ns],  use_col)

	# Cap the tip with a single triangle fan
	var tip: Vector3 = base + basis * Vector3(0, height, 0)
	var t_last: float = float(rings - 1) / float(rings)
	var lr: float = base_r * pow(1.0 - t_last, 1.6)
	var lh: float = height * t_last
	var lt: float = t_last * 0.4
	for s in range(sides):
		var ns: int = (s + 1) % sides
		var a0: float = (float(s)  / float(sides)) * TAU + lt
		var a1: float = (float(ns) / float(sides)) * TAU + lt
		_add_tri_flat(st, base + basis * Vector3(cos(a0)*lr, lh, sin(a0)*lr),
					  tip, base + basis * Vector3(cos(a1)*lr, lh, sin(a1)*lr), accent)

	st.generate_normals(false)  # MANDATORY flat shading per project rules
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _landmark_material(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.custom_aabb = AABB(Vector3(-2000,-100,-2000), Vector3(4000,2000,4000))
	add_child(mi)

# ---------------------------------------------------------------------------
# ARCH — two rectangular columns bridged by a curved 8-segment stone span.
# Creates the classic "natural arch" navigation landmark silhouette.
# ---------------------------------------------------------------------------
func _build_arch(base: Vector3, basis: Basis, rng: RandomNumberGenerator, col: Color, size_scale: float = 1.0) -> void:
	var pillar_h: float = rng.randf_range(350.0, 650.0) * size_scale
	var pillar_w: float = rng.randf_range(50.0, 90.0) * size_scale
	var span: float = rng.randf_range(280.0, 480.0) * size_scale  # Gap between pillar centers
	var arch_segs: int = 8

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Helper: build a simple tapered box pillar
	var _add_pillar := func(offset_x: float) -> void:
		var corners := [
			Vector3(-pillar_w*0.5, 0, -pillar_w*0.5),
			Vector3( pillar_w*0.5, 0, -pillar_w*0.5),
			Vector3( pillar_w*0.5, 0,  pillar_w*0.5),
			Vector3(-pillar_w*0.5, 0,  pillar_w*0.5),
		]
		var top_scale: float = 0.75  # Pillar narrows slightly at top
		var top_corners := [
			Vector3(-pillar_w*0.5*top_scale, pillar_h, -pillar_w*0.5*top_scale),
			Vector3( pillar_w*0.5*top_scale, pillar_h, -pillar_w*0.5*top_scale),
			Vector3( pillar_w*0.5*top_scale, pillar_h,  pillar_w*0.5*top_scale),
			Vector3(-pillar_w*0.5*top_scale, pillar_h,  pillar_w*0.5*top_scale),
		]
		for f in range(4):
			var fn: int = (f + 1) % 4
			var b0: Vector3 = base + basis * (corners[f]  + Vector3(offset_x, 0, 0))
			var b1: Vector3 = base + basis * (corners[fn] + Vector3(offset_x, 0, 0))
			var t0: Vector3 = base + basis * (top_corners[f]  + Vector3(offset_x, 0, 0))
			var t1: Vector3 = base + basis * (top_corners[fn] + Vector3(offset_x, 0, 0))
			_add_tri_flat(st, b0, t0, b1, col)
			_add_tri_flat(st, t0, t1, b1, col)
	_add_pillar.call(-span * 0.5)
	_add_pillar.call( span * 0.5)

	# Build the curved arch span as a series of quad segments
	var arch_r: float = span * 0.55  # Radius of curvature
	var arch_w: float = pillar_w * 0.7
	for seg in range(arch_segs):
		var t0: float = float(seg)       / float(arch_segs)
		var t1: float = float(seg + 1)   / float(arch_segs)
		var a0: float = PI * t0  # 0 = left foot, PI = right foot
		var a1: float = PI * t1
		# Arch inner and outer radius
		var inner := arch_r - arch_w * 0.5
		var outer := arch_r + arch_w * 0.5
		# Arch lives in the XY plane of the basis, centered above the gap
		var c0i := base + basis * Vector3(-cos(a0) * inner, pillar_h + sin(a0) * inner, 0)
		var c0o := base + basis * Vector3(-cos(a0) * outer, pillar_h + sin(a0) * outer, 0)
		var c1i := base + basis * Vector3(-cos(a1) * inner, pillar_h + sin(a1) * inner, 0)
		var c1o := base + basis * Vector3(-cos(a1) * outer, pillar_h + sin(a1) * outer, 0)
		# Face: front (towards -Z in local space)
		var depth_v := basis * Vector3(0, 0, arch_w * 0.5)
		_add_tri_flat(st, c0i,           c1i,           c0o,           col)
		_add_tri_flat(st, c1i,           c1o,           c0o,           col)
		_add_tri_flat(st, c0i + depth_v, c0o + depth_v, c1i + depth_v, col)
		_add_tri_flat(st, c1i + depth_v, c0o + depth_v, c1o + depth_v, col)

	st.generate_normals(false)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _landmark_material(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.custom_aabb = AABB(Vector3(-800, -100, -800), Vector3(1600, 1200, 1600))
	add_child(mi)

# ---------------------------------------------------------------------------
# FLOATING ISLAND — Hallelujah-Mountain style: dome-topped grass plateau atop
# a tapered rocky stalactite that hangs deep below.  Multi-ring revolution
# geometry with per-vertex jitter + a slight off-axis tilt so the silhouette
# reads as a real 3D landmass from every viewing angle (orbit included),
# not a flat disc.
# ---------------------------------------------------------------------------
func _build_floating_island(base: Vector3, basis: Basis, rng: RandomNumberGenerator, col: Color, accent: Color, size_scale: float = 1.0) -> void:
	var r: float = rng.randf_range(220.0, 380.0) * size_scale
	var float_alt: float = rng.randf_range(1200.0, 2400.0) * sqrt(size_scale)  # higher tier = larger and slightly higher
	var sides: int = 12

	# Random off-axis tilt (±15°) so the top isn't always perfectly aligned
	# with the surface normal — eliminates the "flat octagon from above" look.
	var tilt_axis_angle := rng.randf() * TAU
	var horizontal_axis: Vector3 = (basis.x * cos(tilt_axis_angle) + basis.z * sin(tilt_axis_angle)).normalized()
	var tilt_amount: float = rng.randf_range(-0.26, 0.26)  # ±15°
	var tb: Basis = basis.rotated(horizontal_axis, tilt_amount)

	var centre: Vector3 = base + basis * Vector3(0, float_alt, 0)

	# Latitude rings: y / radius / colour.  Each ring is built per-side with
	# small radius/y jitter for organic irregularity.  Top apex is a slight
	# bump above the plateau; bottom apex is a deep stalactite point.
	var rock_dark: Color = col.darkened(0.25)
	var rock_deep: Color = col.darkened(0.45)
	var rings: Array = [
		# y_factor (× r), radius_factor (× r), colour
		[ 0.18, 0.00, accent],                          # top apex (dome bump)
		[ 0.14, 0.45, accent],                          # plateau ring
		[ 0.04, 0.85, accent.lerp(col, 0.55)],          # transition (grass → rock)
		[-0.12, 1.00, col],                             # widest middle (rock)
		[-0.45, 0.65, col],                             # tapering rock
		[-0.85, 0.30, rock_dark],                       # narrow rock
		[-1.30, 0.00, rock_deep],                       # bottom apex (deep stalactite)
	]

	# Build vertex grid: rings × sides.  Per-vertex jitter for organic look.
	var verts := []
	verts.resize(rings.size())
	for ring_i in range(rings.size()):
		var ring_y: float = rings[ring_i][0] * r
		var ring_r: float = rings[ring_i][1] * r
		var per_side := PackedVector3Array()
		for s in range(sides):
			var ang := float(s) / float(sides) * TAU
			# Jitter — radius ±10%, y ±3% — only on intermediate rings (not apex).
			var rj: float = 1.0
			var yj: float = 0.0
			if ring_r > 0.001:
				rj = 1.0 + sin(ang * 2.7 + float(ring_i) * 1.3) * 0.10 \
						+ rng.randf_range(-0.05, 0.05)
				yj = sin(ang * 3.1 + float(ring_i) * 0.7) * 0.03 * r
			var lp := Vector3(cos(ang) * ring_r * rj, ring_y + yj, sin(ang) * ring_r * rj)
			per_side.append(centre + tb * lp)
		verts[ring_i] = per_side

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Top apex fan: triangle from apex0 (which is at radius=0 so single point)
	# down to the ring below.
	var top_apex: Vector3 = (verts[0] as PackedVector3Array)[0]  # all sides collapse to the same point at r=0
	var ring_1 := verts[1] as PackedVector3Array
	for s in range(sides):
		var ns := (s + 1) % sides
		_add_tri_flat(st, top_apex, ring_1[s], ring_1[ns], rings[1][2])

	# Quad strips between consecutive non-apex rings.  Colour blends across
	# the seam so the grass→rock transition feels continuous.
	for ring_i in range(1, rings.size() - 2):
		var rl := verts[ring_i] as PackedVector3Array
		var rh := verts[ring_i + 1] as PackedVector3Array
		var c_top: Color = rings[ring_i][2]
		var c_bot: Color = rings[ring_i + 1][2]
		var c_mid: Color = c_top.lerp(c_bot, 0.5)
		for s in range(sides):
			var ns := (s + 1) % sides
			_add_tri_flat(st, rl[s], rh[s], rl[ns], c_mid)
			_add_tri_flat(st, rl[ns], rh[s], rh[ns], c_mid)

	# Bottom apex fan from last non-apex ring down to the stalactite tip.
	var last_ring_i := rings.size() - 2  # second-to-last (just above the apex)
	var last_ring := verts[last_ring_i] as PackedVector3Array
	var bot_apex: Vector3 = (verts[rings.size() - 1] as PackedVector3Array)[0]
	for s in range(sides):
		var ns := (s + 1) % sides
		_add_tri_flat(st, last_ring[ns], last_ring[s], bot_apex, rings[rings.size() - 1][2])

	st.generate_normals(false)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _landmark_material(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# AABB sized to encompass tilted island + deep stalactite; ~2× radius
	# horizontally, full vertical span from top bump to deep apex.
	var ext: float = r * 1.4
	mi.custom_aabb = AABB(Vector3(-ext, -r * 1.5, -ext), Vector3(ext * 2.0, r * 2.0, ext * 2.0))
	add_child(mi)

# Shared unshaded-style material for all landmarks — uses the terrain rock colour
func _spawn_poi_marker() -> void:
	var marker_script = load("res://src/ui/POIMarker.gd")
	if not marker_script: return
	var display_name = name.replace("Planet_", "")
	# Place label well above the atmosphere (planet_radius + 40% headroom)
	var height = planet_radius * 1.4
	# Tint the beacon using the planet's grass/surface palette color
	var col = pal_grass_col.lerp(Color.WHITE, 0.5)
	var marker := Node3D.new()
	marker.set_script(marker_script)
	# Pass planet_radius so the marker can position its cylinder above the
	# surface (preventing the hex-prism cylinder from poking through water/
	# lava at the surface intersection).
	marker.call_deferred("setup", display_name, "planet", height, col, planet_radius)
	add_child(marker)

func _landmark_material(col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX  # Flat per-face shading
	mat.roughness = 0.92
	mat.metallic = 0.0
	return mat

# Flat-shaded triangle helper: all 3 verts share same face normal (computed from geometry)
func _add_tri_flat(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	# Per-project rules: flat shading via manual face-normal on every triangle
	var face_n: Vector3 = (b - a).cross(c - a).normalized()
	st.set_color(col)
	st.set_normal(face_n); st.add_vertex(a)
	st.set_normal(face_n); st.add_vertex(b)
	st.set_normal(face_n); st.add_vertex(c)

func _process(_delta: float) -> void:
	# ACE: Staggered Pool Pre-warm logic — must run at TOP to bypass hibernation returns
	if _prewarm_count < _prewarm_target:
		_prewarm_one_chunk()
		_prewarm_count += 1

	if not player:
		var players = get_tree().get_nodes_in_group("Player")
		if players.size() > 0: player = players[0]
		return
	
	# CELESTIAL DISTANCE LOD: Hibernation Mode
	var dist_to_player = player.global_position.distance_to(global_position)
	
	# FRUSTUM HIBERNATION: Disabled if inside the planetary sphere of influence
	# Reference: ship position/forward (not camera) so SpringArm jitter and
	# rapid camera swings don't flip planet faces in/out of view.
	var should_hibernate = false
	var safety_dist = planet_radius * 12.0 # ACE: Drastically increased to prevent 'White Sphere' syndrome
	if dist_to_player > safety_dist:
		var to_planet = (global_position - player.global_position).normalized()
		var ship_fwd = -player.global_transform.basis.z
		var dot = ship_fwd.dot(to_planet)

		# ACE HYSTERESIS: Wider margins to ensure horizons don't pop
		if faces_hidden: should_hibernate = dot < -0.3 # Show earlier
		else: should_hibernate = dot < -0.8 # Hide later
	
	var should_hide_faces = should_hibernate
	if faces_hidden != should_hide_faces:
		for face in faces: face.visible = !should_hide_faces
		_ensure_impostor_active(should_hide_faces)
		faces_hidden = should_hide_faces
	
	# MEMORY RECLAMATION (Reaper): Push nodes to Death Row only when strictly out of range.
	if dist_to_player > PROXIMITY_CUTOFF:
		if not faces_hidden:
			for face in faces: 
				if face.root_node: face.root_node.dispose()
			_ensure_impostor_active(true)
			faces_hidden = true
			split_queue.clear()
		return # Hibernating!
	else:
		if faces_hidden:
			for face in faces: 
				face.visible = true
				# ACE RECONSTRUCTION: Re-init root nodes upon re-entry.
				if face.root_node: face.root_node.ensure_chunk()
			_ensure_impostor_active(false)
			faces_hidden = false
			# ACE SEAMLESS HANDOVER: Trigger immediate regeneration to minimize pop
			for face in faces: if face.root_node: face.root_node.ensure_chunk()
	
	# ACE PERFORMANCE HARDENING: Frame-Slice the QuadTree update
	# Instead of checking all 6 faces every frame, we cycle through them.
	_lod_face_idx = (_lod_face_idx + 1) % faces.size()
	
	var face_to_update = faces[_lod_face_idx]
	if face_to_update.visible and dist_to_player < planet_radius * 2.5:
		face_to_update.update_lod(player.global_position)
	
	# High-performance splitting: one mesh commit per frame
	for i in range(min(split_queue.size(), MAX_SPLITS_PER_FRAME)):
		var node = split_queue.pop_back()
		if node: node.execute_split()
	
	# ACE RECLAMATION: Process Zombie Pool
	var z_batch = min(zombie_pool.size(), 6 if mobile_perf else 10) # ACE: Limit zombie checks per frame
	for i in range(z_batch):
		var z = zombie_pool.pop_back()
		if z.is_busy():
			zombie_pool.append(z)
		else:
			chunk_pool.append(z)
	
	# ACE FINALIZATION: Predictable Generation Cycles
	# STRICT BUDGET: Spaced out to prevent frame spikes on mobile.
	# Atmosphere-entry boost: when the player is below 26 km AND the queue
	# has built up (>5), allow 2× drain rate for that frame only. Drains
	# the entry backlog twice as fast without raising steady-state cost.
	var _entry_boost: bool = mobile_perf and player != null and finalize_queue.size() > 5 \
		and player.get("true_altitude") != null and float(player.get("true_altitude")) < 26000.0
	if (OS.get_name() == "iOS" or OS.get_name() == "Android"):
		MAX_FINALIZE_PER_FRAME = 2 if _entry_boost else 1
	else:
		MAX_FINALIZE_PER_FRAME = 8
	for i in range(min(finalize_queue.size(), MAX_FINALIZE_PER_FRAME)):
		var chunk = finalize_queue.pop_front()
		if is_instance_valid(chunk):
			chunk._finalize_generation_on_main()

	# ACE PROP THROTTLE: Spread node instantiation across multiple frames
	# Tightened for M1 — 2 tasks per frame to ensure buttery flight.
	var prop_batch = (2 if _entry_boost else 1) if mobile_perf else 2
	for i in range(min(prop_spawn_queue.size(), prop_batch)):
		var task = prop_spawn_queue.pop_front()
		var node = task[0]
		var method = task[1]
		var data = task[2]
		if is_instance_valid(node) and node.has_method(method):
			node.call(method, data)

	# ACE REAPER: Asynchronous destruction of nodes
	var death_budget = 2 if mobile_perf else 6 
	for i in range(min(death_row.size(), death_budget)):
		var d = death_row.pop_back()
		if is_instance_valid(d): d.queue_free() # ACE: Always queue_free() for main-thread safety
	
	for i in range(min(collision_queue.size(), MAX_COLLISIONS_PER_FRAME)):
		var c = collision_queue.pop_back()
		if is_instance_valid(c):
			# ACE PERMANENT FIX: Use the background-baked Collision Shape
			# Instead of create_trimesh_collision() (which is a sync main-thread choke)
			if "_collision_shape" in c and c._collision_shape:
				var body = StaticBody3D.new()
				c.add_child(body)
				var shape_node = CollisionShape3D.new()
				shape_node.shape = c._collision_shape
				body.add_child(shape_node)
				
func _prewarm_procedural_pool(count: int) -> void:
	for i in range(count):
		var c = PlanetChunkScript.new()
		chunk_pool.append(c)

func queue_chunk_for_finalization(chunk: Node) -> void:
	# ACE: Thread-safe handover to the main finalization queue
	if not finalize_queue.has(chunk):
		finalize_queue.append(chunk)
		collision_queue.append(chunk) # ACE: Ensure collision is baked after mesh is ready

func get_terrain_elevation(sn: Vector3) -> float:
	if not noise: return 0.0
	# ACE: Master Elevation Formula (STRICT SYNC with PlanetChunk)
	# Macro frequency is per-planet (FLAT=300, HILLY=400, MOUNTAINOUS=600, EXTREME=800)
	# — must match PlanetChunk.get_terrain_elevation or callers (Player anti-clip floor,
	# parked-ship landing snap) see a different surface than the rendered terrain.
	var macro_h: float = noise.get_noise_3dv(sn * noise_frequency)
	var micro_crag: float = noise.get_noise_3dv(sn * 15000.0) * 0.1
	var local_geo: float = 0.0

	match archetype:
		"DESERT":
			var mesa = smoothstep(-0.1, 0.1, macro_h) * 2.0 - 1.0 
			local_geo = (mesa * 0.6 + micro_crag) * terrain_strength * 0.7
		"VOLCANIC", "ABYSS":
			var jagged = 1.0 - abs(macro_h * 1.5) 
			local_geo = (jagged * 2.0 - 0.8 + micro_crag * 2.5) * terrain_strength * 1.4
		"FROZEN":
			var plains = macro_h * 0.4
			var spikes = max(0.0, noise.get_noise_3dv(sn * 2500.0) - 0.65) * 6.0
			local_geo = (plains + spikes + micro_crag * 0.4) * terrain_strength
		"TOXIC", "RADIATED":
			var craters = abs(noise.get_noise_3dv(sn * 1200.0))
			var bubbling = noise.get_noise_3dv(sn * 3000.0) * 0.5
			local_geo = (macro_h - craters * 1.8 + bubbling + micro_crag) * terrain_strength * 0.6
		"ALPINE":
			var ridge = 1.0 - abs(macro_h)
			local_geo = (ridge * 2.5 - 0.8 + micro_crag * 1.5) * terrain_strength * 1.5
		_:
			local_geo = (macro_h + micro_crag) * terrain_strength
			var volcanic: float = noise.get_noise_3dv(sn * 25000.0)
			if volcanic > 0.45: local_geo -= 1000.0
			var terrace_height = 80.0
			var h_frac = fposmod(local_geo, terrace_height) / terrace_height
			var layer_step = floor(local_geo / terrace_height) + smoothstep(0.15, 0.85, h_frac)
			local_geo = layer_step * terrace_height
	
	# STRICT SYNC with PlanetChunk's continent mask (noise.frequency = 0.01,
	# so multipliers ~200-1100 produce continent-scale variation across faces).
	var c_n: float = noise.get_noise_3dv(sn * 220.0)
	c_n += noise.get_noise_3dv(sn * 520.0) * 0.55
	c_n += noise.get_noise_3dv(sn * 1100.0) * 0.25
	var cont_mask: float = smoothstep(-0.18, 0.18, c_n + 0.05)
	var S_LVL: float = sea_level
	var abyss_depth: float = S_LVL - 400.0
	
	var elev = lerp(abyss_depth, local_geo + (S_LVL + 50.0), cont_mask)
	return elev

func _ensure_impostor_active(active: bool) -> void:
	# DEBUG: impostor permanently hidden — testing whether the visible repeating
	# circle/diamond pattern across planet surfaces is the impostor's noise()
	# level-set rendering (which uses unit-direction-space frequencies and
	# would produce distinct cell patterns regardless of planet size). The
	# impostor is normally only meant to render at very far distances, but
	# at small planet radii the QuadTree may rarely subdivide chunks and the
	# impostor could be the dominant visible layer. Restore by removing the
	# `active = false` line below once confirmed.
	active = false
	if active:
		if not impostor:
			var script = load("res://src/world/PlanetImpostor.gd")
			impostor = Node3D.new(); impostor.set_script(script)
			impostor.set("planet_radius", planet_radius)
			# Pass the ACTUAL terrain palette colors (not sky!) so impostor matches what you see up close
			impostor.set("planet_color", pal_grass_col)
			impostor.set("planet_color_b", pal_mount_col)
			impostor.set("water_col", pal_water_base) # ACE ATMOSPHERIC SYNC
			impostor.set("horizon_col", sky_horizon_color) # ACE: Atmospheric Sync
			impostor.set("continent_pole", continent_pole) # ACE SYNC
			add_child(impostor); impostor.global_position = global_position
		impostor.visible = true
	elif impostor:
		impostor.visible = false

class QuadTreeFace extends Node3D:
	var planet: Node3D
	var normal: Vector3
	var root_node: QuadTreeNode
	var x_axis: Vector3
	var y_axis: Vector3
	func _init(p_planet: Node3D, p_normal: Vector3) -> void:
		planet = p_planet
		normal = p_normal
		if abs(normal.y) > 0.999: x_axis = Vector3.RIGHT
		else: x_axis = Vector3.UP.cross(normal).normalized()
		y_axis = normal.cross(x_axis).normalized()
	func _ready() -> void:
		root_node = QuadTreeNode.new(self, null, Vector2.ZERO, 1.0, 0)
		root_node.ensure_chunk()
	func update_lod(player_pos: Vector3) -> void:
		root_node.update(player_pos)

class QuadTreeNode:
	var face: QuadTreeFace
	var parent: QuadTreeNode
	var local_offset: Vector2
	var scale: float
	var lod: int
	var children: Array[QuadTreeNode] = []
	var chunk: MeshInstance3D = null
	
	func _init(p_face: QuadTreeFace, p_parent: QuadTreeNode, p_offset: Vector2, p_scale: float, p_lod: int) -> void:
		face = p_face
		parent = p_parent
		local_offset = p_offset
		scale = p_scale
		lod = p_lod
		
	func update(player_pos: Vector3) -> void:
		var face_pos: Vector3 = face.normal + (local_offset.x * face.x_axis) + (local_offset.y * face.y_axis)
		var center_norm: Vector3 = face_pos.normalized()
		var center_pos: Vector3 = face.planet.global_position + center_norm * face.planet.planet_radius
		var dist: float = player_pos.distance_to(center_pos)

		# AGGRESSIVE HORIZON: Subdivide at 3.5x the scale distance
		# (Per-prop spawn hysteresis is handled in PlanetChunk.gd; the QuadTree
		# itself stays on the original threshold since subdividing has paired
		# split/merge handshakes that already prevent visible gaps when timing
		# is correct — adding chunk-level hysteresis introduced rectangular
		# holes at LOD transitions and is not needed for prop stability.)
		var threshold: float = face.planet.planet_radius * (scale * 3.5) * face.planet.subdivision_bias
		if dist < threshold and lod < face.planet.max_lod:
			if children.is_empty():
				if not face.planet.split_queue.has(self): face.planet.split_queue.append(self)
			else:
				for child in children: child.update(player_pos)
		else:
			if not children.is_empty(): merge()
			else: ensure_chunk()
			
	func execute_split() -> void:
		if not children.is_empty(): return
		var step: float = scale * 0.5 
		children.append(QuadTreeNode.new(face, self, local_offset + Vector2(-step, -step), step, lod + 1))
		children.append(QuadTreeNode.new(face, self, local_offset + Vector2(step, -step), step, lod + 1))
		children.append(QuadTreeNode.new(face, self, local_offset + Vector2(-step, step), step, lod + 1))
		children.append(QuadTreeNode.new(face, self, local_offset + Vector2(step, step), step, lod + 1))
		# CRITICAL: We wait for ALL 4 children to be Ready before removing parent!
		# This eliminates the 'black squares' holes during subdivision.
		_ready_children = 0
		for child in children:
			child.ensure_chunk()
			if child.chunk and child.chunk.has_signal("generation_completed"):
				if not child.chunk.generation_completed.is_connected(_on_child_gen_done):
					child.chunk.generation_completed.connect(_on_child_gen_done, CONNECT_ONE_SHOT)
	
	func _on_child_gen_done() -> void:
		_ready_children += 1
		if _ready_children >= 4:
			remove_chunk() # Now safe to remove parent as children are visible

	func merge() -> void:
		if children.is_empty(): return
		# CRITICAL: Wait for the parent to be ready before killing high-detail children!
		ensure_chunk()
		if chunk and chunk.has_signal("generation_completed"):
			if not chunk.generation_completed.is_connected(_on_parent_ready_for_merge):
				chunk.generation_completed.connect(_on_parent_ready_for_merge, CONNECT_ONE_SHOT)

	func _on_parent_ready_for_merge() -> void:
		if children.is_empty(): return
		for child in children: child.dispose()
		children.clear()

	var _ready_children: int = 0
	
	func ensure_chunk() -> void:
		if chunk: return
		
		# ACE MEMORY LEAK FIX: Removed the 'not children.is_empty' abort.
		if face.planet.chunk_pool.is_empty():
			chunk = face.planet.PlanetChunkScript.new()
			face.add_child(chunk)
		else:
			chunk = face.planet.chunk_pool.pop_back()
			if chunk.get_parent():
				if chunk.get_parent() != face:
					chunk.reparent(face)
			else:
				face.add_child(chunk)
			
		chunk.face = face
		chunk.planet = face.planet
		chunk.noise = face.planet.noise
		chunk.radius = face.planet.planet_radius
		chunk.terrain_strength = face.planet.terrain_strength
		chunk.face_normal = face.normal
		chunk.x_axis = face.x_axis
		chunk.y_axis = face.y_axis
		chunk.offset = local_offset
		chunk.scale_factor = scale
		if scale > 0.05:   chunk.resolution = 16
		elif scale > 0.01: chunk.resolution = 24
		else:              chunk.resolution = 32
		var planet_mobile_perf: bool = bool(face.planet.get("mobile_perf")) if face.planet else false
		if planet_mobile_perf:
			# Halved from 12/18/24. ~55% fewer verts per chunk; collision
			# baking shrinks the same fraction so the queue drains faster.
			if scale > 0.05:   chunk.resolution = 8
			elif scale > 0.01: chunk.resolution = 12
			else:              chunk.resolution = 16
		chunk.planet_seed = face.planet.planet_seed
		chunk.archetype = face.planet.archetype
		
		# PALETTE INJECTION
		chunk.pal_grass_col = face.planet.pal_grass_col
		chunk.pal_mount_col = face.planet.pal_mount_col
		chunk.pal_forest_col = face.planet.pal_forest_col
		chunk.pal_forest_h = face.planet.pal_forest_h
		chunk.pal_grass_secondary = face.planet.pal_grass_secondary
		chunk.pal_beach_col = face.planet.pal_beach_col
		chunk.pal_water_base = face.planet.pal_water_base
		chunk.pal_water_light = face.planet.pal_water_light
		chunk.pal_water_shore = face.planet.pal_water_shore
		chunk.continent_pole = face.planet.continent_pole
		
		var p = face.planet.player
		chunk.scatter_grass = (p != null and not p.get("in_ship"))
		chunk.start_generation()
		
	func remove_chunk() -> void:
		if chunk: 
			# Push back to pool instead of destroying memory
			chunk.sleep_and_reset()
			if chunk.is_busy():
				face.planet.zombie_pool.append(chunk)
			else:
				face.planet.chunk_pool.append(chunk)
			chunk = null
			
	func dispose() -> void:
		if lod == 0: return # ACE: Base chunks never die
		remove_chunk()
		for child in children: child.dispose()
		children.clear()

func _init_shared_materials() -> void:
	land_material = ShaderMaterial.new()
	land_material.shader = load("res://src/world/triplanar_local.gdshader")
	land_material.set_shader_parameter("planet_radius", planet_radius)
	land_material.set_shader_parameter("texture_scale", 1.0)
	# Wire the procedurally-rolled palette into the biome-aware land shader so
	# every chunk renders with the planet's actual archetype colour.
	land_material.set_shader_parameter("sea_level", sea_level)
	land_material.set_shader_parameter("col_beach",  pal_beach_col)
	land_material.set_shader_parameter("col_grass",  pal_grass_col)
	land_material.set_shader_parameter("col_forest", pal_grass_secondary)
	land_material.set_shader_parameter("col_rock",   pal_mount_col)
	# Tint snow slightly toward the rock colour so ice caps don't bleach pure
	# white (and so they read distinctly between archetypes).
	land_material.set_shader_parameter("col_snow",
		Color(0.92, 0.94, 0.98).lerp(pal_mount_col, 0.15))

	# Archetype-driven FX uniforms. The shader treats 0.0 as "off" and only
	# costs branches when active, so non-FX archetypes pay nothing here.
	var iridescence: float = 0.55 if archetype == "IRIDESCENT" else 0.0
	var snow_spec: float = 0.0
	if archetype == "FROZEN" or archetype == "ALPINE" or archetype == "AURORA":
		snow_spec = 1.0
	var crystal_em: float = 1.4 if archetype == "CRYSTAL" else 0.0
	land_material.set_shader_parameter("iridescence_strength", iridescence)
	land_material.set_shader_parameter("snow_specular", snow_spec)
	land_material.set_shader_parameter("crystal_emission", crystal_em)

	# MINERAL INFLUENCE — metallic/exotic minerals add surface emission glow
	# on top of the archetype FX above. Stacks with crystal_emission.
	land_material.set_shader_parameter("mineral_glow",
		float(planet_profile.get("glow_boost", 0.0)))


	water_material = ShaderMaterial.new()
	var w_shader = load("res://src/world/water.gdshader")
	if w_shader:
		water_material.shader = w_shader
		water_material.set_shader_parameter("radius", planet_radius)
		# OBSIDIAN: black-glass world with crimson lava lakes — same lava path
		# as VOLCANIC. Set on the shared material so chunks pick it up via the
		# pal_water_base override below in PlanetChunk.
		if archetype == "OBSIDIAN" or archetype == "VOLCANIC":
			water_material.set_shader_parameter("is_lava", true)
		# Mobile: skip the high-frequency detail FBM in waves and the
		# shimmer FBM (single value_noise instead). ~6 hash() ops saved
		# per ocean fragment.
		water_material.set_shader_parameter("mobile_simple", mobile_perf)
	
	# FOLIAGE MATERIALS
	foliage_material = ShaderMaterial.new()
	foliage_material.shader = load("res://src/shaders/foliage_toon.gdshader")
	foliage_material.set_shader_parameter("shadow_strength", 0.6)
	foliage_material.set_shader_parameter("wind_speed", 0.7)
	foliage_material.set_shader_parameter("wind_strength", 0.4)
	foliage_material.set_shader_parameter("leaf_texture", load("res://assets/textures/tree_leaves_texture.png"))
	foliage_material.set_shader_parameter("normal_map", load("res://assets/textures/tree_leaves_texture_normal.png"))
	foliage_material.set_shader_parameter("biolum_intensity", 1.0 if has_bioluminescence else 0.0)
	# Mobile cheap path: simpler light(), shorter dither fade range.
	foliage_material.set_shader_parameter("mobile_simple", mobile_perf)
	
	trunk_material = ShaderMaterial.new()
	trunk_material.shader = load("res://src/shaders/trunk_toon.gdshader")
	trunk_material.set_shader_parameter("albedo", Color(0.35, 0.25, 0.15))
	trunk_material.set_shader_parameter("bark_texture", load("res://assets/textures/tree_trunk_texture.png"))
	trunk_material.set_shader_parameter("normal_map", load("res://assets/textures/tree_trunk_texture_normal.png"))
	
	rock_material = ShaderMaterial.new()
	rock_material.shader = load("res://src/shaders/hatch_toon.gdshader")
	rock_material.set_shader_parameter("shadow_strength", 0.9)
	rock_material.set_shader_parameter("biolum_intensity", 1.0 if has_bioluminescence else 0.0)
	
	grass_material = ShaderMaterial.new()
	grass_material.shader = PlanetChunkScript._get_grass_shader()
